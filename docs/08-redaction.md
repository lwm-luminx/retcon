# Redaction

Some things history must not keep: a phone number posted by mistake, a privacy or right-to-be-forgotten request, a
takedown. Redaction is the one place retcon changes history rows, and it changes them only to delete a value.

## Commitments

Every version row holds its value, a random salt, and a **commitment**: SHA-256 over the salt and the value's
canonical JSON. Redaction deletes the value and the salt and keeps the commitment. History still verifies (each row
proves a value existed, and which changeset wrote it), but the value is gone, and because the salt is gone too, a short
value like a phone number can't be guessed back by hashing candidates.

```ruby
row.verified?   # the commitment matches the value (true once redacted: nothing left to check)
```

## Scrubbing a field

```ruby
Retcon::Redaction.field(venue, :phone, actor: staff, reason: 'privacy request')
```

This scrubs the field from every version of the record, applied or proposed, and removes it from the record's
tombstone snapshots. Options:

- `value:` scrub only versions holding this value, leaving the field's other history alone.
- `remedy:` the live value afterwards (nil by default), written as a new version so a rebuild lands on it. Pass
  `Retcon::Redaction::KEEP` to leave the live value alone when it is already clean.

```ruby
Retcon::Redaction.field(venue, :phone, actor: staff, reason: 'posted by mistake', value: '555-0100',
                                       remedy: Retcon::Redaction::KEEP)
```

Every redaction is a changeset of kind `redaction` recording who, when, why and which version rows, never what was
removed. It fires the `redacted` event.

## Pseudonymizing an editor

```ruby
Retcon::Redaction.editor(user, by: staff, reason: 'account deleted')
```

History stores actor ids, so this rewrites one actor row: their identity is replaced with a stable pseudonym such as
`editor-3f9a1c2b`. Their edits stay, grouped under the pseudonym, so they can still be audited and reverted.

## Deletion requests

```ruby
result = Retcon::Redaction.erase(user, by: deletion_job, reason: 'deletion request')
```

For an automated personal deletion request, `erase` does three things in one transaction:

1. reverts everything the person authored (see [Reverts](#reverts));
2. scrubs every value they wrote from history;
3. pseudonymizes them.

Later edits by other people to the same fields are not touched: they come back in `result[:review]` as a proposal,
because a deletion request can't wipe other people's work. The result is `{ revert:, review:, flagged:, redaction: }`.
