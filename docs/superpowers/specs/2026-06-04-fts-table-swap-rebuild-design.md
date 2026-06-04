# FTS Table-Swap Rebuild Design

## Context

The TypeScript database migration currently handles `fts_version` changes by
keeping existing `sessions_fts` rows live and marking sessions for reindexing.
That avoids an empty-search window, but it does not build a replacement FTS table
or atomically swap it into place after the rebuild completes.

Swift CoreWrite already has this behavior in
`macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift`. The TypeScript stack
should use the same operational model for `sessions_fts` so both writers handle
future tokenizer/schema changes consistently.

## Goal

Add a TypeScript `sessions_fts` online rebuild policy that keeps the active FTS
table serving search during a rebuild, dual-writes refreshed content into a
shadow table, and atomically swaps the shadow table into place once recoverable
FTS jobs are complete.

## Non-Goals

- Do not redesign the Swift implementation.
- Do not add `insights_fts` table-swap rebuild support in this PR.
- Do not change search ranking, filtering, tokenizer choice, or CJK fallback
  behavior.
- Do not add a background scheduler. The existing recoverable index job runner
  remains the completion driver.

## Architecture

Add `src/core/db/fts-rebuild-policy.ts` as the TypeScript counterpart to Swift's
`FTSRebuildPolicy`. This file owns and exports the TypeScript expected FTS
version so migration and finalization cannot drift.

The policy owns these fixed names:

- active table: `sessions_fts`
- rebuild table: `sessions_fts_rebuild`
- old table during swap: `sessions_fts_old`
- version metadata: `fts_version`
- pending metadata: `fts_rebuild_version`

No public API accepts arbitrary table names.

## Migration Behavior

When `runMigrations` sees `metadata.fts_version !== FTS_VERSION`:

1. If the database has no sessions, drop any stale rebuild table, set
   `fts_version = FTS_VERSION`, clear `fts_rebuild_version`, and finish.
2. Otherwise, ensure `sessions_fts_rebuild` exists with the expected FTS schema.
   If `fts_rebuild_version` is not the expected version, or the rebuild table is
   missing, drop and recreate the rebuild table.
3. Only when the rebuild table was newly created or recreated, copy all rows from
   the active `sessions_fts` into `sessions_fts_rebuild`:
   `INSERT INTO sessions_fts_rebuild(session_id, content) SELECT session_id, content FROM sessions_fts`.
   This makes the shadow table complete before any job replay happens. Reopened
   jobs can refresh rows, but they are not required to populate the shadow table.
   If `fts_rebuild_version` already matches and `sessions_fts_rebuild` already
   exists, do not copy again; pending rebuilds must be idempotent across process
   restarts.
4. Set `sessions.size_bytes = 0` so normal file indexing still refreshes stale
   FTS content after the schema/tokenizer version change.
5. Clear session-level vector tables when present: `session_embeddings` and
   `vec_sessions`.
6. Set `metadata.fts_rebuild_version = FTS_VERSION`.
7. Reopen completed FTS jobs by setting completed `session_index_jobs` rows with
   `job_kind = 'fts'` back to `pending`, with `retry_count = 0` and
   `last_error = NULL`.
8. Attempt finalization. If no recoverable FTS jobs are pending, the migration
   can swap immediately. If recoverable FTS jobs remain, leave the pending
   metadata and shadow table for subsequent job-runner passes to finish.
9. Do not delete or empty the active `sessions_fts` before the swap. Existing
   search continues using the active table.

## Dual Write Behavior

All TypeScript FTS content replacement goes through the rebuild policy.

When no rebuild is pending:

- delete and insert content only in `sessions_fts`

When a rebuild is pending:

- delete and insert content in `sessions_fts`
- delete and insert the same content in `sessions_fts_rebuild`

This applies to `Database.replaceFtsContent` and `Database.indexSessionContent`,
because both rewrite session FTS content.

## Delete Behavior

All TypeScript FTS deletion paths must delete from both active and rebuild
tables when a rebuild is pending.

This applies to:

- `Database.deleteIndexArtifacts`
- `session-repo.deleteSession`
- maintenance cleanup that removes subagent rows from `sessions_fts`

Without dual deletion, a session hidden from active search during a pending
rebuild could be resurrected when `sessions_fts_rebuild` is swapped into place.

## Finalization Behavior

Migration and `IndexJobRunner` both ask the policy to finalize.
`IndexJobRunner` calls finalization after each recoverable FTS job finishes or is
marked no longer applicable.

Finalization does nothing unless all are true:

- `metadata.fts_rebuild_version === FTS_VERSION`
- `sessions_fts_rebuild` exists
- there are no recoverable FTS jobs:
  `job_kind = 'fts' AND status IN ('pending', 'failed_retryable')`

When ready, finalization runs in one transaction:

1. Drop stale `sessions_fts_old` if present.
2. Rename active `sessions_fts` to `sessions_fts_old` if it exists.
3. Rename `sessions_fts_rebuild` to `sessions_fts`.
4. Drop `sessions_fts_old`.
5. Set `fts_version = FTS_VERSION`.
6. Delete `fts_rebuild_version`.

If any step fails, the transaction rolls back and the active table remains the
source of truth.

## Error Handling

- Missing optional vector tables are ignored during migration cleanup.
- Missing `session_index_jobs` means finalization can proceed once the rebuild
  table exists.
- SQL errors from table creation, rename, or FTS writes propagate to callers.
- Search continues to read only from active `sessions_fts`; it never reads from
  the rebuild table.
- Existing active FTS content is copied into the rebuild table before job replay,
  so the rebuild does not depend on the current TypeScript `IndexJobRunner`
  being able to reconstruct full user/assistant transcript content from jobs.

## Testing Requirements

Use TDD. Required TypeScript coverage:

1. Migration starts a pending rebuild without emptying active FTS:
   - create a legacy DB with `fts_version = '2'`, one session, active
     `sessions_fts` content, and a completed FTS job
   - opening `Database` creates `sessions_fts_rebuild`
   - `sessions_fts_rebuild` contains a copied row for existing active FTS content
   - active `sessions_fts` content remains readable
   - completed FTS job becomes pending
   - `fts_rebuild_version = '3'`
   - `fts_version` remains old until finalize
2. Empty DB migration marks the current version without creating a pending
   rebuild.
3. Pending rebuild dual-writes `replaceFtsContent` into both active and rebuild
   tables.
4. Pending rebuild dual-writes `indexSessionContent` into both active and rebuild
   tables.
5. Pending rebuild deletes from both active and rebuild tables for
   `deleteIndexArtifacts`, `deleteSession`, and subagent maintenance cleanup.
6. Finalization is blocked while recoverable FTS jobs remain.
7. Finalization swaps the rebuild table into place and updates metadata when
   recoverable FTS jobs are gone.
8. Reopened legacy jobs that only mark completed do not empty or degrade the
   rebuilt table because copied active FTS rows survive final swap.
9. `IndexJobRunner` finalizes after the last FTS job completes.
10. Reopening the same pending rebuild twice does not duplicate rows in
    `sessions_fts_rebuild` or in the final swapped `sessions_fts`.

## Verification

Local verification for the PR must include:

- targeted migration / FTS rebuild tests
- targeted index job runner tests
- `npm run lint`
- `npm run typecheck:test`
- `npm run build`
- `npm test`

CI must pass before merge.
