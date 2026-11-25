# Changesets and actors

## Changesets

A changeset is one logical change: version rows across any number of records and tables, with an author, a message
and, once someone applies or decides it, a committer. Changesets are never deleted. Reverts and redactions are
changesets too, so they can be inspected and undone like anything else.

| Column | Meaning |
| --- | --- |
| `kind` | `edit`, `proposal`, `genesis`, `catch_up`, `import`, `revert`, `redaction` |
| `state` | `applied`, `proposed`, `rejected`, `withdrawn`, `amended` |
| `author` / `committer` | who wrote it, and who applied or decided it |
| `applied_seq` | its place in retcon's global order of application |
| `parent` | the changeset this one amends, or the revert a review proposal came from |
| `scope` | the tenant or audience it belongs to (see [Models](#models)) |
| `message`, `metadata` | free text, and a jsonb hash for your own keys |

Every save outside `Retcon.changeset` gets a changeset of its own. Inside one, every save joins it, nested blocks
included, and the whole block runs in one database transaction:

```ruby
changeset = Retcon.changeset(actor: staff, message: 'Merge duplicate venues', metadata: { 'ticket' => 'OPS-12' }) do
  keep.update!(phone: dupe.phone)
  dupe.destroy!
end
changeset.records   # [[Venue, keep.id], [Venue, dupe.id]]
changeset.versions  # the version rows, in write order
changeset.changes   # {[Venue, keep.id] => {'phone' => '555-0100'}}
```

A block that changes nothing leaves no changeset and returns nil.

### Global order

`applied_seq` comes from one PostgreSQL sequence, `retcon_seq`, shared by every versioned table. Every version row of
an applied changeset carries the same `seq`, and the live row's `retcon_seq` is the seq of the last changeset that
wrote it. That is what conflicts are checked against, and what lets reverts and rebuilds replay history in order.

## Actors

History stores actor ids, never names or emails. An actor stands for a record, or is named:

```ruby
Retcon.as(current_user) { ... }                         # a record: a User, a device grant, an API client
Retcon.as(Retcon::Actor.named('import', 'facebook')) { ... }
Retcon.as('nightly-cleanup') { ... }                     # a String names a system actor
```

`Retcon::Actor.resolve` turns any of these into an `Actor` row, creating it the first time. Record actors are of kind
`user` unless you map the class:

```ruby
Retcon::Actor.kinds = { 'VenueDeviceGrant' => 'device' }
```

`actor.record` finds the record again; `actor.label` is how to show it (its pseudonym once redacted).

### Agents

When software acts for a person (an assistant, a moderation bot acting on a report), attribute the change to both:

```ruby
Retcon.as(glam_bot, on_behalf_of: host) { event.update!(status: 'cancelled') }
```

The changeset's author is an `agent` actor that points at the person it acted for (`on_behalf_of`). Reverting the
agent's changes, or the person's, finds them either way.

### Unattributed saves

Saves with no actor set are attributed to `Retcon::Actor.system` ("unattributed"), so nothing breaks while you add
`Retcon.as` around your write paths. Turn that off once they're covered:

```ruby
Retcon.allow_unattributed = false   # saves with no actor raise Retcon::Error
```

A common place for `Retcon.as` is a controller `around_action`, or the GraphQL context for mutations.

## Events

retcon publishes through `ActiveSupport::Notifications` as `<name>.retcon`, with the changeset in the payload:

| Event | When |
| --- | --- |
| `proposal_opened` | a proposal (or an amended one) is opened |
| `changeset_applied` | a proposal is applied |
| `proposal_rejected` | a proposal is rejected |
| `revert_conflict` | a revert left same-field overlaps in a review proposal |
| `redacted` | a redaction is written |

```ruby
Retcon.on(:proposal_opened) { |changeset| ReviewQueue.route(changeset) }
```

This is how you route proposals to reviewers, for example to a moderation host or a staff queue.
