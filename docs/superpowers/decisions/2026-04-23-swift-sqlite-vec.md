# Swift sqlite-vec Strategy

Date: 2026-04-23

## Decision

Swift does not claim semantic-vector parity until a macOS-compatible `sqlite-vec` extension is vendored and loaded by the Swift SQLite stack, or a separately reviewed native replacement is implemented with parity tests.

The active Stage 1 strategy is fail-closed:

- `EngramCoreWrite` exposes `SQLiteVecSupport.probe()` so callers can produce a typed unavailable diagnostic instead of silently advertising semantic vector search.
- `VectorRebuildPolicy` owns vector metadata compatibility for `vec_dimension` and `vec_model`.
- Dimension mismatch, model mismatch, or `__pending_rebuild__` clears derived vector state: `vec_sessions`, `vec_chunks`, `vec_insights`, `session_embeddings`, and `session_chunks`.
- `memory_insights` is preserved during automatic compatibility cleanup because it is user-curated memory text plus metadata, not only derived vector state.

## Accepted Constraints

- Stage 1 may keep Node as the vector behavior reference, but Swift runtime code must not depend on Node.
- Base database migration remains independent from `sqlite-vec`; lazy vector tables are handled separately because Node creates them in `src/core/vector-store.ts`.
- Existing `vec0` virtual tables may require the `sqlite-vec` module to be loaded before they can be dropped or rebuilt. Until Swift can load the extension, semantic-vector behavior remains blocked rather than degraded silently.

## Rejected Alternatives

- Claiming parity by replacing `vec0` with plain SQLite tables in Swift was rejected because it would preserve table names while changing query semantics.
- Automatically deleting `memory_insights` during migration was rejected because Node's automatic vector migration preserves it; destructive deletion is reserved for an explicit maintenance command.
