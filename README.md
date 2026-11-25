# retcon

[![CI](https://github.com/lwm-luminx/retcon/actions/workflows/ci.yml/badge.svg)](https://github.com/lwm-luminx/retcon/actions/workflows/ci.yml)
[![Gem](https://img.shields.io/gem/v/retcon.svg)](https://rubygems.org/gems/retcon)

**Retroactive continuity for Active Record:** change the past without breaking the story.

retcon adds a VCS-style layer to Active Record on PostgreSQL, so many people can edit shared records with full
attribution, and damage (bad deletes, misinformation, bad actors) can be repaired without losing the good work that
came after it.

**Guide:** <https://lwm-luminx.github.io/retcon/>

```ruby
class Venue < ApplicationRecord
  include Retcon::Model
end

Retcon.as(current_user) { venue.update!(name: 'The Eagle') }           # an attributed, applied changeset

proposal = Retcon.propose(actor: member) { |p| p.update(venue, phone: '555-0100') }
proposal.apply!(committer: reviewer)                                     # or reject!, withdraw!, amend!

Retcon.revert_actor(vandal, actor: staff)                                # drops their changes, keeps later work
Retcon::Redaction.field(venue, :phone, actor: staff, reason: 'privacy')  # scrubs a value from history
```

## How it works

- **History is the source of truth.** Each versioned table gets a history table of immutable field-level versions,
  each in a changeset with an actor, a base version and a place in one global order.
- **Live tables stay fast.** They are a projection of history, written in the same transaction, so reads don't
  change and any live row can be rebuilt from history.
- **Changesets group changes.** A direct edit is an applied changeset; a proposal is an unapplied one, reviewed before
  it applies, like a pull request. A policy you write decides who commits and who proposes.
- **Field-level conflicts.** A stale edit or proposal conflicts only on fields someone else changed since its base.
  Array fields can merge instead.
- **Tombstones, not lost rows.** Deleted rows leave the live table, and come back with their id and history.
- **Repair.** Reverting an actor's changes drops them and keeps later changes; only same-field overlaps go to review.
  Reverts are changesets too, so they can be undone.
- **Drift is caught.** Writes made outside retcon (`update_all`, SQL, the console) are found by a trigger and recorded
  before anything builds on them.
- **Redaction.** Scrub a value from every version, pseudonymize an editor, or run a deletion request. Salted
  commitments keep history verifiable after the value is gone.
- **Edges.** Graph edges (subject, predicate, object) are versioned rows that revive by triple, and removed edges
  leave the live table, so [graph_query](https://github.com/lwm-luminx/graph_query) walks only live ones.

## Install

```ruby
gem 'retcon'
```

```ruby
class InstallRetcon < ActiveRecord::Migration[8.0]
  include Retcon::Schema

  def change
    create_retcon_tables
    version_table :venues
  end
end
```

Requires Ruby 3.3+, Active Record 7.1+ and PostgreSQL 15+. See
[Getting started](https://lwm-luminx.github.io/retcon/#getting-started).

## Development

The specs need a PostgreSQL database:

```sh
createdb retcon_test
RETCON_DATABASE_URL=postgres:///retcon_test bundle exec rspec
bundle exec rubocop
bin/build-docs site   # the guide, from docs/*.md (needs pandoc)
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
