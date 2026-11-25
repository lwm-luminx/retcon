# Internals

## Tables

`create_retcon_tables` makes:

- the sequence `retcon_seq`, retcon's global order of application;
- `retcon_actors`: kind, the record an actor stands for (`ref_type`, `ref_id`), a name, `on_behalf_of_id` for
  agents, and the pseudonym and `redacted_at` once redacted;
- `retcon_changesets`: kind, state, author, committer, parent, scope, message, metadata, `applied_seq`, and when it
  was applied and decided.

`version_table :venues` makes `retcon_venues`, with one row per field change or lifecycle step:

| Column | Holds |
| --- | --- |
| `changeset_id` | the changeset the row belongs to |
| `record_id` | the live row's id, in the live table's key type |
| `op` | `set`, or a lifecycle step: `create`, `tombstone`, `revive` |
| `field`, `value` | for `set`: the field and `{"v": value}`; for a tombstone, the row as it was |
| `salt`, `commitment` | for `set`: the salted SHA-256 commitment that survives redaction |
| `applied`, `seq` | whether the changeset is applied, and its seq |
| `base_seq` | the version the change was made against |
| `schema_version` | the model's schema version when written |
| `redacted_by_id` | the redaction changeset that scrubbed the value |

History rows are inserted, never updated or deleted, except when a proposal is applied (`applied`, `seq`) and when
redaction scrubs a value and salt.

## One transaction

A save writes the changeset, the live row and the history rows in one transaction, in that order:

1. lock the live row and catch up drift;
2. check conflicts against the base;
3. take the changeset's seq (on its first write), set the live row's `retcon_seq`, digest and dirty flag, and save;
4. write the history rows for the fields that changed.

If anything raises, the transaction rolls back and neither history nor the live row changes. A catch-up that happens
inside an open changeset renumbers that changeset after itself, so history orders the catch-up first.

## Replaying

When retcon writes live rows from history (applying, reverting, reviving, rebuilding), it runs validations with
`Retcon.replaying?` true and writes with SQL, so callbacks don't fire for changes that are old or were reviewed.
Subscribe to `changeset_applied` for side effects that should follow these writes.

## Cost

A save of N changed fields adds one changeset insert (per changeset, not per record), one multi-row history insert,
one row lock and one `DISTINCT ON` query for the record's field heads. Reads of live tables are unchanged.
