# Conflicts

Two people open the same venue. One fixes the phone number, the other the hours. Both save. With retcon both changes
stay: conflicts are checked **per field**, and only when someone else changed that same field to a different value
after the version you started from.

## The base version

Every live row carries `retcon_seq`, the seq of the last changeset that wrote it. A record remembers the
`retcon_seq` it was loaded with; that is its **base**. On save, retcon:

1. locks the live row (`SELECT ... FOR UPDATE`) for the rest of the transaction;
2. catches up any change written outside retcon since (see [Drift](#drift));
3. compares each changed field's newest version with the base.

A field conflicts when its newest version is newer than the base, came from someone else's change, and holds a value
different from the one being saved.

```ruby
mine = Venue.find(id)      # base: seq 41
theirs = Venue.find(id)
Retcon.as(bob) { theirs.update!(phone: '555-0199') }   # seq 42

Retcon.as(alice) { mine.update!(hours: '4pm-2am') }    # fine: hours didn't move
Retcon.as(alice) { mine.update!(phone: '555-0100') }   # Retcon::Conflict: phone changed at seq 42
```

Saving the value that's already there never conflicts.

## Web forms: an explicit base

A record loaded inside the request that saves it has a base from moments ago. For an edit form, the base that matters
is the one the person saw when the form was rendered. Put the record's `retcon_seq` in the form and give it back:

```ruby
# the form: hidden_field :retcon_seq
venue.retcon_base = params[:venue][:retcon_seq].to_i
venue.update!(venue_params)
```

`retcon_base` also takes `{field => seq}` for clients that track versions per field. It applies to the next save
only.

## Handling a conflict

By default a conflict raises `Retcon::Conflict` and nothing is saved:

```ruby
rescue Retcon::Conflict => e
  e.conflicts.each do |c|
    c.field     # 'phone'
    c.current   # what is there now: '555-0199'
    c.proposed  # what this save wanted: '555-0100'
    c.base_seq  # the version the edit started from
    c.head_seq  # the version that moved it
  end
```

Show the person both values and let them choose. Or save what you can and report the rest:

```ruby
venue.retcon_on_conflict = :skip
venue.update!(phone: '555-0100', hours: '4pm-2am')
venue.retcon_conflicts   # [FieldConflict(phone)]: hours saved, phone left as it was
```

Skipped fields are put back to their database value on the record.

## Proposals

Proposals record their base when they're opened and are checked when they're applied, days later perhaps. The same
rules apply, plus [merge strategies](#models) for fields like tags. See [Proposals](#proposals).
