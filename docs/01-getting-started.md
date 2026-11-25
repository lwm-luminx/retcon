# Getting started

retcon keeps a full, field-level history of the Active Record models you choose, on PostgreSQL. Every save is
attributed to someone and grouped into a **changeset**. Changes can also be **proposed** and applied later after
review, like a pull request. When something goes wrong (a bad delete, a vandal, a privacy request), you repair it with
a new changeset instead of restoring a backup, and the good work that came after it stays.

Your live tables don't move and don't get slower. They become a **projection** of history: written in the same
transaction as the history rows, and rebuildable from them at any time.

## Install

```ruby
# Gemfile
gem 'retcon'
```

retcon needs Ruby 3.3+, Active Record 7.1+ and PostgreSQL 15+ through the `pg` adapter.

## Create the tables

One migration creates retcon's shared tables, and one call per table versions it:

```ruby
class InstallRetcon < ActiveRecord::Migration[8.0]
  include Retcon::Schema

  def change
    create_retcon_tables   # retcon_actors, retcon_changesets and the retcon_seq sequence
    version_table :venues  # retcon_venues, three columns on venues, and a trigger
    version_table :events
  end
end
```

`version_table` creates the history table `retcon_venues`, adds `retcon_seq`, `retcon_digest` and `retcon_dirty` to
`venues`, and installs a trigger that marks rows written outside retcon (see [Drift and bulk writes](#drift)).

## Version a model

```ruby
class Venue < ApplicationRecord
  include Retcon::Model
end
```

That's all a model needs. Every column is versioned except the primary key, timestamps, `lock_version`, counter caches
(`*_count`) and retcon's own columns. [Models](#models) covers choosing fields.

Rows that existed before retcon have no history yet. Give them a starting point once, after the migration:

```ruby
Venue.retcon_genesis!   # one "Genesis" changeset per batch of 500 rows
```

## Make attributed changes

Wrap changes in `Retcon.as` to say who made them:

```ruby
Retcon.as(current_user) do
  venue.update!(name: 'The Eagle', phone: '555-0100')
end
```

Saves work exactly as before: validations and callbacks run, and `save` still returns `true` or `false`. retcon adds
a changeset with the user as its author, a version row for each changed field, and the record's new `retcon_seq`.

Group several saves into one changeset with a message:

```ruby
Retcon.changeset(actor: current_user, message: 'New season') do
  venue.update!(hours: { 'tue' => '4pm-2am' })
  venue.events.create!(name: 'Drag Bingo')
end
```

## Read history

```ruby
venue.retcon_versions          # every version row, oldest first
venue.retcon_heads['phone']    # the current version of a field: seq, value, row_id (blame)
Retcon::Changeset.last.author  # who made the last change
Retcon::Changeset.last.changes # {[Venue, id] => {'name' => 'The Eagle', ...}}
Venue.retcon_state(venue.id)   # the record as history says it is
```

## Where to go next

- [Changesets and actors](#changesets-and-actors): attribution, agents, events.
- [Conflicts](#conflicts): what happens when two people edit the same record.
- [Proposals](#proposals): changes that wait for review.
- [Reverts](#reverts): undoing an actor's changes without losing later work.
- [Redaction](#redaction): removing what history must not keep.
