# Schema evolution

History outlives your schema. A column renamed today still has years of versions under its old name. retcon stamps
every version row with the model's **schema version** and reads old rows through **upcasters**, so history never has
to be rewritten when a column changes.

## Versions and upcasters

Bump `schema_version` in the same deploy as the migration, and say how older rows read:

```ruby
class Venue < ApplicationRecord
  include Retcon::Model

  versioned do
    schema_version 3
    rename_field :hours_text, :hours, before: 2     # rows written under version 1
    upcast(before: 3) do |field, value|             # rows written under versions 1 and 2
      next [] if field == 'legacy_rating'           # dropped
      next [['city', value['city']], ['region', value['region']]] if field == 'location'   # split

      [[field, value]]
    end
  end
end
```

An upcaster takes `(field, value)` and returns `[[field, value], ...]`: one pair to keep or rename, none to drop,
several to split. Upcasters run in order of `before:`, and only on rows written under an older version, so a row
from version 1 goes through both of the upcasters above.

Heads, state, conflict checks and rebuilds all read through upcasters. The rows themselves keep what was
written, and `row.raw_value` returns it.

## Changing columns

- **Adding a versioned column:** nothing to do. Existing records have no versions for it until it changes. If the
  migration backfills it with SQL, the trigger marks those rows dirty and `Venue.retcon_sweep!` records the values.
- **Removing a column:** add an upcaster that drops it, or `ignore` it first and remove it later.
- **Renaming:** `rename_field` with the new schema version.
- **Changing a type:** history keeps JSON values; an upcaster can convert old ones.

## Live columns

`version_table` adds three columns to the live table. Keep them out of your forms and serializers:

| Column | Holds |
| --- | --- |
| `retcon_seq` | the seq of the last changeset that wrote the row: its base version |
| `retcon_digest` | a digest of the versioned fields as retcon last wrote them |
| `retcon_dirty` | set by the trigger when the row is written outside retcon |
