# Edges

Relationships between records (an episode recorded at an event, a person hosting a night) are often rows in a link
table whose identity is the triple **subject, predicate, object**. `Retcon::Edge` versions them like any record and
adds two rules: linking the same triple again revives the row it had, and removed edges leave the live table.

```ruby
class EntityLink < ApplicationRecord
  include Retcon::Edge

  retcon_triple subject: %i[item_type item_id], predicate: :predicate, object: %i[target_type target_id]
end
```

A polymorphic end is `[type_column, id_column]`; a plain end is one id column. Give the table a unique index on the
triple. `discriminator:` names one more identifying column, for a triple that may appear more than once (two slots
on the same night, say).

## Linking and unlinking

```ruby
EntityLink.link!(episode, :recorded_at, event, status: 'linked')   # creates, updates or revives
EntityLink.unlink!(episode, :recorded_at, event)                   # tombstones; nil when there was no edge
```

`link!` updates a live edge in place, writing a version only for attributes that changed. If the triple was linked
before and removed, it revives that row, keeping its id and its whole history, instead of starting a new one. It
finds the old row through the tombstone snapshots, with a jsonb containment query on the history table's GIN index.

## Walking the graph

Removed edges leave the live table, so anything that reads the live table, including
[graph_query](https://lwm-luminx.github.io/graph_query/), walks only live edges with no extra filter:

```ruby
class MediaEpisode < ApplicationRecord
  graph_edge :recorded_at, to: Event, through: EntityLink, source: :item_id, target: :target_id,
                           where: { item_type: 'MediaEpisode', predicate: 'recorded_at', target_type: 'Event' }
end
```

graph_query sees only the links that exist now. Who linked or unlinked an edge, and when, is in its history like any other record.
