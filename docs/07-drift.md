# Drift and bulk writes

Not every write goes through a model save. `update_all`, `insert_all`, `update_column`, raw SQL and console fixes all
write live rows without history. retcon finds them and records them before anything builds on them, attributed to
`Retcon::Actor.untracked`, so history never silently disagrees with the live table.

## How drift is found

`version_table` installs a trigger on the live table that sets `retcon_dirty` on any insert or update retcon didn't
make. retcon's own writes set the `retcon.writing` setting for the transaction, so the trigger leaves them alone.

Drift is caught three ways:

- **On write.** Before every update and destroy, retcon locks the row and, if it is dirty, writes a `catch_up`
  changeset with what changed. Your edit then goes in after it, in order.
- **Sweeps.** `Venue.retcon_sweep!` catches up every dirty row in batches, and records rows deleted outside retcon
  (history says they exist, the live table has none) as tombstones. Run it from a scheduled job.
- **Full sweeps.** `Venue.retcon_sweep!(full: true)` also compares every row's digest of its versioned fields with the
  one retcon wrote. That catches writes made with the trigger disabled. It reads the whole table, so run it rarely.

Rows with no history at all are pre-retcon data and get `genesis` changesets instead.

```ruby
Venue.retcon_sweep!                          # => number of rows caught up
venue.retcon_drifted?                        # one row
```

## Skipping history on purpose

```ruby
Retcon.bypass { Venue.where(audience_id: old).update_all(audience_id: new) }
```

Writes in a bypass block skip history, but the trigger still marks the rows dirty, so the next sweep records them as
untracked changes. Use bypass for migrations and repairs where attribution doesn't matter.

## Bulk writes with attribution

Imports and syncs that would use `upsert_all` can keep attribution with `Retcon::Bulk.upsert`:

```ruby
Retcon::Bulk.upsert(Venue, rows, unique_by: :external_key, actor: Retcon::Actor.named('import', 'facebook'))
```

Rows are matched to live rows by `unique_by` (one column or several). New rows are created, matched rows get only the
fields that differ, and everything lands in one changeset of kind `import`. Like `upsert_all`, validations and
callbacks don't run. It returns the changeset, or nil when nothing changed.
