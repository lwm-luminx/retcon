# Reference

## Retcon

| Method | Does |
| --- | --- |
| `Retcon.as(actor, on_behalf_of: nil) { }` | attributes every change in the block |
| `Retcon.actor` | the current actor, or nil |
| `Retcon.changeset(actor:, message:, scope:, kind:, metadata:) { }` | one applied changeset, one transaction; returns it |
| `Retcon.propose(actor:, message:, scope:, metadata:) { \|p\| }` | opens a proposal; returns it |
| `Retcon.edit(record, attributes, actor:, message:, base:)` | commits, proposes or denies through the policy |
| `Retcon.policy = ->(actor, record, changes) { }` | returns `:commit`, `:propose` or `:deny` |
| `Retcon.revert(changesets, actor:, message:)` | returns a `Revert::Result` |
| `Retcon.revert_actor(actor, actor:, since:, scope:, message:)` | reverts what an actor authored |
| `Retcon.bypass { }` | writes skip history (and are swept later) |
| `Retcon.verify(model, sample: 100)` | live rows that disagree with history |
| `Retcon.replaying?` | true while retcon writes live rows from history |
| `Retcon.on(event) { \|changeset\| }` | subscribes to an event |
| `Retcon.allow_unattributed = false` | saves with no actor raise |

## Retcon::Changeset

`versions`, `records`, `changes`, `apply!(committer:, on_conflict: :raise)`, `reject!(by:, reason:)`,
`withdraw!(by:)`, `amend!(by:, message:) { |p| }`, `revert!(actor:, message:)`. Scopes: `applied`, `proposed`.

## Retcon::Proposal::Builder

`update(record, fields, base: nil)`, `create(model, attributes)`, `destroy(record)`.

## Retcon::Actor

`Actor.resolve(thing, on_behalf_of: nil)`, `Actor.named(kind, name)`, `Actor.system`, `Actor.untracked`,
`Actor.kinds = {}`, `#record`, `#label`, `#redacted?`, `#pseudonymize!`.

## Retcon::Redaction

`field(record, field, actor:, reason:, value: KEEP, remedy: nil)`, `editor(actor, by:, reason:)`,
`erase(actor, by:, reason:)`.

## Retcon::Bulk

`upsert(model, rows, unique_by:, actor:, message: nil)`.

## Retcon::Edge

`retcon_triple(subject:, predicate:, object:, discriminator: nil)`, `link!(subject, predicate, object, attributes)`,
`unlink!(subject, predicate, object)`, `retcon_identity(subject, predicate, object)`.

## Retcon::Schema (migrations)

`create_retcon_tables`, `version_table(table, id_type: nil)`, `add_retcon_dirty_trigger(table)`.

## Errors

| Error | Raised when |
| --- | --- |
| `Retcon::Conflict` | fields changed since the base; `#conflicts` lists `FieldConflict`s |
| `Retcon::Invalid` | a record would be invalid after applying history to it; `#record` |
| `Retcon::InvalidState` | a changeset can't move to the state asked for |
| `Retcon::Denied` | the policy refused an edit |
| `Retcon::NotVersioned` | a model or table isn't set up for retcon |
| `Retcon::Error` | the base class, and other misuse |

`Retcon::FieldConflict` has `model`, `record_id`, `field`, `base_seq`, `head_seq`, `current` and `proposed`.
