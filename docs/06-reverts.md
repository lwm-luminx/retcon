# Reverts

A revert undoes changesets the way an interactive rebase drops commits, without rewriting history: one new changeset
of kind `revert` puts back what the dropped changesets replaced, and later work by others stays.

```ruby
Retcon.revert(changeset, actor: staff)
changeset.revert!(actor: staff)                                  # the same
Retcon.revert_actor(vandal, actor: staff)                        # everything they authored
Retcon.revert_actor(vandal, actor: staff, since: 2.days.ago, scope: audience.id.to_s)
```

`revert_actor` takes every applied changeset the actor authored, leaving out their own reverts and redactions.

## What a revert does

For each field the dropped changesets set:

- if a dropped changeset wrote the field's current value, the field goes back to the newest value written by a
  changeset that isn't dropped (nil when there is none);
- if someone else changed it afterwards, their value stays, and restoring the earlier value goes into a **review
  proposal** instead. This is a same-field overlap: a person decides.

Records the dropped changesets created are deleted (tombstoned). Records they deleted are revived, with their id and
history. Fields nobody else touched are restored directly.

```ruby
result = Retcon.revert_actor(vandal, actor: staff)
result.revert    # the applied revert changeset, or nil when there was nothing to undo
result.review    # a proposal with the overlaps, or nil; its parent is the revert
result.flagged   # [Actor] reviewers who applied the vandal's proposals
```

`flagged` lists committers who applied a dropped changeset someone else authored. They approved the damage, so
whoever cleans up may want to look at what else they approved.

The review proposal fires `revert_conflict` as well as `proposal_opened`, so it can be routed like any proposal.

## Undoing a revert

A revert is a changeset, so it can be reverted. That puts the dropped changes back, with the same rules about later
work.

## Reviving one record

To bring back a single deleted record without reverting anything else:

```ruby
Venue.retcon_revive!(venue_id, actor: staff)
```

It reinserts the row with its id, every column from the tombstone snapshot and each field's newest version, as a
changeset of its own (or in the open one). Reviving a record that is live raises `Retcon::Error`.

## Rebuilding

Because live rows are a projection, any row can be rewritten from history:

```ruby
Venue.retcon_rebuild!(venue_id)   # inserts, updates or deletes the live row to match history
Retcon.verify(Venue, sample: 500) # [[id, field, live, history], ...] for rows that disagree; empty when they agree
```
