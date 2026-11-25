# Models

Include `Retcon::Model` in any Active Record model whose table was versioned with `version_table`. Settings go in a
`versioned` block:

```ruby
class Venue < ApplicationRecord
  include Retcon::Model

  versioned do
    ignore :view_count, :search_vector
    merge :tags, :set_union
    scope(&:audience_id)
  end
end
```

## Versioned fields

By default every column is versioned except:

- the primary key and retcon's own columns (`retcon_seq`, `retcon_digest`, `retcon_dirty`);
- `created_at`, `updated_at` and `lock_version`;
- counter caches: any column ending in `_count`.

`ignore` leaves more out. `only` names the versioned fields outright instead:

```ruby
versioned do
  only :name, :address, :phone
end
```

`Venue.retcon_config.tracked_fields` lists the result. A save that changes only untracked fields writes no history and
no changeset, so view counters and search vectors cost nothing.

Fields keep their types through history. Values are stored as JSON: strings, numbers, booleans, arrays and `jsonb`
as they are; dates, times and decimals as strings; anything else through `as_json`. They are cast back through the
attribute's type when read.

## Scope

`scope` gives every changeset about a record a scope string, such as the tenant or audience it belongs to. Reverts
and reviews can then be limited to it:

```ruby
versioned do
  scope { |venue| venue.audience_id }
end

Retcon::Changeset.where(scope: audience.id.to_s)
Retcon.revert_actor(vandal, actor: staff, scope: audience.id.to_s)
```

A changeset takes the scope of the first record it writes, unless `Retcon.changeset(scope:)` sets one.

## Merge strategies

When a proposal changes a field that someone else changed after the proposal's base, it conflicts. A merge strategy
can settle that instead:

- `:replace` (the default): it conflicts.
- `:set_union`: for array fields, the result keeps every element either side has. Two people tagging the same venue
  both get their tags.

```ruby
versioned do
  merge :tags, :set_union
end
```

The merged value is written as one more version in the applied changeset, after the proposed one.

## Schema versions

`schema_version`, `rename_field` and `upcast` keep old history readable when columns change. See
[Schema evolution](#schema-evolution).

## Associations and callbacks

Saves and destroys are wrapped whole, so autosaved associations and `dependent: :destroy` children join the same
changeset as their parent. Your callbacks run on ordinary saves. When retcon writes live rows itself (applying a
proposal, reverting, rebuilding), it validates the record but skips callbacks. Check `Retcon.replaying?` in a callback
that has side effects you never want to repeat, such as sending a notification:

```ruby
after_save :notify_followers, unless: -> { Retcon.replaying? }
```

## Instance and class methods

| Method | Returns |
| --- | --- |
| `record.retcon_versions` | every version row of the record, oldest first, proposals included |
| `record.retcon_heads` | `{field => Head}` with the newest applied version of each field |
| `record.retcon_drifted?` | whether the live row was written outside retcon |
| `record.retcon_base = seq` | the base version the next save is checked against |
| `record.retcon_on_conflict = :skip` | leave conflicting fields out of the next save |
| `record.retcon_conflicts` | the fields the last save left out |
| `Model.retcon_state(id)` | `{'exists', 'seq', 'attributes'}` as history says, or nil |
| `Model.retcon_revive!(id, actor:)` | brings a deleted record back with its id |
| `Model.retcon_rebuild!(id)` | rewrites the live row from history |
| `Model.retcon_sweep!` | catches up rows written outside retcon |
| `Model.retcon_genesis!` | gives pre-retcon rows their first history |
