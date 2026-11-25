# Changelog

## 0.1.0 (unreleased)

The first working release.

- Field-level history tables (`version_table`), with live tables kept as a projection in the same transaction.
- Changesets with actors (records, named systems, agents acting on behalf of someone) and a global order of application.
- Per-field conflict checks against the loaded or explicit base version: raise, or skip and report.
- Proposals: update, create and destroy recorded against base versions; apply, reject, withdraw, amend. `Retcon.edit`
  with a commit/propose/deny policy. `:set_union` merges for array fields.
- Reverts of changesets or of everything an actor authored, keeping later work and sending same-field overlaps to a
  review proposal. Revive and rebuild single records.
- Drift: a trigger marks rows written outside retcon; catch-up on write, sweeps, full digest sweeps, deletes outside
  retcon, genesis for pre-retcon rows. `Retcon.bypass` and `Retcon::Bulk.upsert`.
- Redaction of field values with salted commitments, editor pseudonyms, and deletion requests (`erase`).
- Versioned edges (`Retcon::Edge`) that revive by triple.
- Schema versions with upcasters (`rename_field`, `upcast`).
- ActiveSupport::Notifications events and the guide at https://lwm-luminx.github.io/retcon/.

## 0.0.1 (2026-11-25)

Reserves the name. No functionality yet; the design is in review.
