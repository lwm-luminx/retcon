# retcon

[![CI](https://github.com/lwm-luminx/retcon/actions/workflows/ci.yml/badge.svg)](https://github.com/lwm-luminx/retcon/actions/workflows/ci.yml)
[![Gem](https://img.shields.io/gem/v/retcon.svg)](https://rubygems.org/gems/retcon)

**Retroactive continuity for Active Record:** change the past without breaking the story.

retcon adds a VCS-style layer to Active Record so many people can edit shared records with full attribution, and
damage (bad deletes, misinformation, bad actors) can be repaired without losing the good work that came after it.

> **Status: 0.0.1 reserves the name.** Nothing is implemented yet. The design is in review; the first working release
> follows once it is approved.

## The idea

- **History is the source of truth.** Each versioned table has a history table of immutable field-level versions:
  value, actor, changeset, schema version and base version.
- **Live tables stay fast.** They are a projection of history, written in the same transaction, so reads don't change
  and any live row can be rebuilt from history.
- **Changesets group changes.** A direct edit is an applied changeset; a proposal is an unapplied changeset against a
  base version, reviewed before it applies (like a pull request).
- **Field-level conflicts.** A stale edit or proposal conflicts only on fields that changed since its base.
- **Tombstones, not deletes.** Removed rows and edges come back with their history.
- **Repair.** Reverting an actor's changes drops them and keeps later changes; only same-field overlaps go to review.
  Reverts are changesets too, so they can be undone.
- **Redaction.** Scrub a value from every version it appears in, or pseudonymize an editor, with salted per-field
  commitments so history still verifies.
- **Policy is yours.** Trust tiers, review routing and matching rules plug in as adapters.

Graph edges (subject, predicate, object) are versioned rows too, and walk with
[graph_query](https://github.com/lwm-luminx/graph_query).

## License

MIT. See [LICENSE.txt](LICENSE.txt).
