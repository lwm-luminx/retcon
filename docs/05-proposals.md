# Proposals

A proposal is a changeset that hasn't been applied: updates, creates and destroys recorded against base versions,
reviewed, then applied or rejected. It touches no live table until it is applied, so readers never see it.

## Opening one

```ruby
proposal = Retcon.propose(actor: member, message: 'New hours') do |p|
  p.update(venue, hours: 'Tue-Sun 4pm-2am')
  p.create(Event, venue_id: venue.id, name: 'Drag Bingo')
  p.destroy(old_event)
end
proposal.state      # 'proposed'
proposal.changes    # the diff to show a reviewer
```

- `p.update(record, fields)` proposes new values. Its base is the version the record was loaded at, or pass
  `base: seq` (or `{field => seq}`) for the version the proposer saw.
- `p.create(Model, attributes)` proposes a new record. Its id is chosen now (a UUID, or the next value of the table's
  sequence), so other parts of the same proposal can refer to it. It returns the unsaved record.
- `p.destroy(record)` proposes deleting it.

Only versioned fields can be proposed. A proposal that changes nothing raises `ArgumentError`.

## Reviewing

```ruby
proposal.apply!(committer: reviewer)
proposal.reject!(by: reviewer, reason: 'Hours are wrong')
proposal.withdraw!                           # the author takes it back
amended = proposal.amend!(by: reviewer) do |p|
  p.update(venue, hours: 'Tue-Sun 5pm-2am')  # replaces the original's value for this field
end
```

`apply!` runs in one transaction: it locks the proposal, locks and catches up each record, checks every field
against its base, writes the live rows, and marks the version rows applied with a fresh seq. Live rows are validated
(an invalid result raises `Retcon::Invalid`), and model callbacks don't run (see `Retcon.replaying?` in
[Models](#models)).

If fields conflict, `apply!` raises `Retcon::Conflict` and applies nothing. To apply the rest:

```ruby
result = proposal.apply!(committer: reviewer, on_conflict: :skip)
result[:conflicts]   # [FieldConflict]; also kept in the changeset's metadata as 'skipped'
```

Skipped fields stay in the applied changeset unapplied, so history shows what was proposed and not taken.

`amend!` keeps the author, makes the reviewer the committer, points the new proposal's `parent` at the original and
marks the original `amended`.

## Policy: commit, propose or deny

`Retcon.edit` sends an edit through a policy you define. Trusted editors commit directly, others open a proposal:

```ruby
Retcon.policy = lambda do |actor, record, changes|
  next :deny if actor.record&.banned?
  next :commit if actor.record&.staff? || record.try(:owner_id) == actor.record&.id

  :propose
end

Retcon.edit(venue, { phone: '555-0100' }, actor: current_user, base: params[:retcon_seq].to_i)
```

`changes` is `{field => [from, to]}`. The policy returns `:commit` (an applied changeset), `:propose` (a proposal;
the record is left unchanged) or `:deny` (raises `Retcon::Denied`). Trust tiers, matching rules and rate limits all
fit here.

## Routing reviews

Subscribe to `proposal_opened` to send proposals where they belong:

```ruby
Retcon.on(:proposal_opened) do |proposal|
  ModerationQueue.enqueue(proposal, scope: proposal.scope)
end
```

## Proposed rows in history

A proposal's version rows sit in the history tables with `applied` false and no seq. Heads, state and rebuilds only
count applied rows, so an open proposal never changes what history says a record is.
