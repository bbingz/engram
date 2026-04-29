# Data Correctness And Indexing Closure — Design Spec

**Date:** 2026-03-18  
**Problem:** Engram currently has correctness gaps in sync pagination, session metadata convergence, and semantic indexing freshness. The system often works, but it cannot prove that it never skips sessions, never leaves indexes stale, or always preserves the right ownership boundary between syncable fields and local-only fields.  
**Solution:** Keep snapshot-based synchronization, but upgrade it to a strictly ordered sync protocol, versioned merge semantics, and a durable indexing pipeline.  
**Principle:** Correctness over minimal change. One-time migrations and protocol upgrades are acceptable. Nodes do not need to converge to a single global canonical record for every field; local-only state is explicitly allowed, but syncable state must be lossless, replay-safe, and observable.

---

## 0. Goals And Non-Goals

### Goals

- No silent session loss during sync pagination.
- No reliance on process restart to make semantic search correct again.
- One canonical write path for all session snapshots, regardless of source.
- Explicit ownership split between sync-managed fields and local-only fields.
- Idempotent replay: reprocessing the same page, session, or indexing task is safe.
- Observable progress: the system can explain whether a session is unprocessed, merged, pending index, or fully indexed.

### Non-Goals

- Do not redesign this into event sourcing.
- Do not solve remote transcript fetching in this subproject.
- Do not redesign Web UI flows in this subproject.
- Do not require every node to store exactly the same local UI state.

---

## 1. Core Architecture

The new architecture is:

`ingestion -> snapshot merge -> durable index queue -> async index workers`

All ingestion paths must use the same session merge entry point:

- local watcher updates
- periodic rescan updates
- sync pull updates

No path may directly write a session row and separately decide whether to update FTS or embeddings. That split is the root cause of stale semantic search and uneven metadata correction.

### Required units

1. `SessionSnapshotWriter`
Accepts a normalized snapshot and performs a single merge transaction.

2. `SessionMergeEngine`
Compares incoming snapshot fields against the current sync-managed snapshot, applies merge rules, and produces a `change set`.

3. `IndexJobStore`
Persists required FTS and embedding work derived from the `change set`.

4. `IndexWorkers`
Consume persisted jobs and mark them completed or retryable-failed.

This keeps responsibilities clear:

- ingestion discovers data
- merge decides truth for syncable fields
- queue records unfinished index work
- workers close the indexing loop

---

## 2. Data Model

The current single-table session model is not sufficient for strict correctness because it mixes sync-managed data and machine-local state.

### 2a. `sessions`

This table remains the primary session snapshot table, but it is narrowed conceptually to sync-managed fields:

- session identity: `id`, `source`
- authoritative owner: `authoritative_node`
- source metadata: `cwd`, `project`, `model`
- counts: `message_count`, `user_message_count`, `assistant_message_count`, `tool_message_count`, `system_message_count`
- sync-visible summary: `summary`, `summary_message_count`
- peer-scoped source locator: `source_locator`
- origin metadata: `origin`
- revision/order fields: `sync_version`, `snapshot_hash`, composite sync ordering fields

### 2b. `session_local_state`

New table for local-only state that must never be overwritten by sync:

- hidden flags
- custom display name
- `local_readable_path`
- future UI-only annotations
- any machine-local overrides

This removes ambiguity. If a field is in `session_local_state`, sync does not own it.

### 2c. `session_index_jobs`

New durable queue table. Each row represents one unfinished indexing obligation.

Minimum fields:

- job id
- session id
- job kind: `fts` or `embedding`
- target revision marker
- status: `pending`, `running`, `failed_retryable`, `completed`
- retry count
- last error
- created at / updated at

The queue exists so that “session merged successfully” and “all derived indexes updated successfully” are no longer conflated.

### 2d. `sync_state`

Replace timestamp-only cursor semantics with a composite cursor:

- last synced `indexed_at`
- last synced `session_id`

Cursor ordering is lexicographic on `(indexed_at, id)`.

---

## 3. Sync Protocol

Timestamp-only pagination is not acceptable because multiple sessions can share the same timestamp value.

### 3a. Ordering rule

Export session pages ordered by:

1. `indexed_at ASC`
2. `id ASC`

### 3b. Cursor rule

The next page cursor is the last fully processed tuple:

- `cursor_indexed_at`
- `cursor_id`

Fetch condition:

- rows where `indexed_at > cursor_indexed_at`
- or `indexed_at = cursor_indexed_at AND id > cursor_id`

This guarantees stable pagination even when many sessions share the same second-level timestamp.

### 3c. Page commit rule

A sync page is only acknowledged after:

- the page is fetched successfully
- every row in the page has been merged successfully
- all resulting index jobs have been persisted successfully

Only then may the peer cursor advance.

If the process dies before that point, the whole page is replayed. Replays are safe because merge is idempotent.

### 3d. Sync v2 protocol summary

| Concern | Rule |
|---------|------|
| export order | `(indexed_at ASC, id ASC)` |
| cursor shape | `(cursor_indexed_at, cursor_id)` |
| page inclusion | `indexed_at > cursor_indexed_at OR (indexed_at = cursor_indexed_at AND id > cursor_id)` |
| page commit | advance cursor only after full page merge + durable job persistence |
| replay behavior | re-read from last committed cursor; merge handles duplicates idempotently |

---

## 4. Merge Semantics

Strict correctness requires explicit merge rules. “Message count did not increase” is not enough.

### 4a. Field ownership

Fields are split into two groups:

- **sync-managed fields**: source metadata, counts, summary, origin, sync ordering markers
- **local-only fields**: UI and machine-local state

Remote updates may only affect sync-managed fields. For every session, exactly one node is the authoritative producer of sync-managed state: the node identified by `authoritative_node`. Replica nodes may store and enrich local-only state, but they do not invent or overwrite authoritative sync-managed fields.

### 4b. Revision model

Each sync-managed snapshot must include a monotonic remote revision signal. This does not need to be globally meaningful across all nodes; it only needs to let one peer say “this snapshot supersedes the prior snapshot I sent.”

The required design is:

- the authoritative node stores a per-session integer `sync_version`
- `sync_version` increments whenever the authoritative node changes any sync-managed field payload
- the authoritative node also stores `snapshot_hash`, computed from the exported sync-managed payload
- sync export includes: `authoritative_node`, `sync_version`, `snapshot_hash`, `indexed_at`, `id`

This defines the advancement event precisely: **a sync-managed payload change at the authoritative node**. Metadata-only corrections such as project rename, summary refresh, model correction, or count correction must increment `sync_version` if they change exported sync-managed payload.

### 4c. Merge behavior

Incoming snapshot merge must be:

- idempotent
- deterministic
- field-aware

Rules:

1. If the incoming `authoritative_node` differs from the stored authoritative owner for the same session, reject the merge as invalid.
2. If the incoming `sync_version` is older than the stored authoritative revision, ignore it.
3. If the incoming `sync_version` is equal and `snapshot_hash` is equal, no-op.
4. If the incoming `sync_version` is newer, overwrite sync-managed fields.
4. Local-only fields remain untouched.
5. Empty or missing values do not erase populated values unless deletion semantics are explicitly defined.

### 4d. Change set

Every successful merge produces a `change set`, such as:

- summary changed
- project changed
- counts changed
- transcript-derived content changed

The `change set` drives indexing.

---

## 5. Index Closure

The system must stop treating embeddings as a best-effort side effect that is only repaired at startup.

### 5a. Dispatch rules

After merge:

- if locally available searchable text changed, enqueue `fts`
- if locally available embedding-eligible text changed, enqueue `embedding`
- if only local-only state changed, enqueue nothing

“Locally available” is intentional. This subproject does not introduce remote transcript retrieval. Therefore:

- authoritative/local sessions with readable transcript content may enqueue both `fts` and `embedding`
- metadata-only replicas may enqueue `fts` from summary and other sync-managed textual fields
- metadata-only replicas must mark `embedding` as `not_applicable`, not `pending`

### 5b. Worker rules

Workers operate on persisted jobs, not on in-memory callbacks.

Properties:

- safe to retry
- safe to resume after crash
- job completion tied to target revision marker

This means an old embedding job cannot incorrectly mark a newer session revision as complete.

### 5c. Startup recovery

On startup:

- recover `pending` and `failed_retryable` jobs first
- do not rely on full-table reindex to regain correctness

Full reindex remains an administrative repair tool, not the normal correctness mechanism.

### 5d. Persisted state meanings

| State | Meaning |
|-------|---------|
| `merged` | latest authoritative snapshot has been merged locally |
| `pending_index` | merged, but at least one applicable index job is unfinished |
| `fully_indexed` | merged, and all applicable index jobs are completed |
| `failed_retryable` | merged, but at least one applicable index job failed and is awaiting retry |

`not_applicable` is a job-level outcome, not a session-level state.

---

## 6. Failure Handling

Strict correctness depends on making failures explicit.

### 6a. Pre-merge failure

Examples:

- peer request failed
- session file unreadable
- parse failed

Behavior:

- do not merge partial data
- do not enqueue jobs
- do not advance sync cursor

### 6b. Post-merge, pre-index failure

Behavior:

- merged snapshot remains committed
- unfinished index work stays visible in `session_index_jobs`
- session is considered merged but not fully indexed

### 6c. Mid-page sync failure

Behavior:

- do not advance page cursor
- replay the page from the last committed composite cursor
- depend on idempotent merge to avoid duplication

The rule is simple: **no cursor advance before durable local persistence**.

---

## 7. Migration

One-time migration is acceptable and preferred.

### Required migration steps

1. Add new sync ordering / revision fields.
2. Create `session_local_state`.
3. Create `session_index_jobs`.
4. Upgrade sync cursor storage to composite cursor.
5. Backfill local-state rows from current local-only columns.
6. Split existing machine-sensitive `file_path` into `source_locator` and `local_readable_path`.
7. Seed indexing jobs for any sessions whose current index state cannot be proven complete.

### Protocol upgrade

Introduce a new sync API contract rather than patching the old timestamp-only one in place. A clean break is safer than keeping ambiguous semantics.

---

## 8. Testing And Acceptance

This subproject is only complete if behavior is provably improved, not merely if unit tests stay green.

### Acceptance cases

1. Sync more than one page of sessions sharing the same `indexed_at` and verify nothing is lost.
2. Interrupt sync mid-page and verify replay does not skip or duplicate.
3. Update summary/project/model without increasing message count and verify the newer snapshot wins.
4. Ingest a new authoritative/local session via watcher/rescan and verify both FTS and embedding eventually reflect it.
5. Ingest a metadata-only sync replica and verify it reaches a valid closed state without a fake pending embedding job.
6. Crash after merge but before embedding completion; restart and verify the pending job is recovered.
7. Verify local-only fields survive remote merge untouched.

### Test layers

- unit tests for cursor comparison, merge rules, change-set generation
- integration tests for watcher/rescan/sync all entering the same merge path
- recovery tests for pending index jobs
- migration tests to prove old DBs become valid new DBs

### Explicit regressions to ban

The new design must make these impossible:

- timestamp-only sync pagination
- “message count unchanged means skip everything”
- embedding freshness depending on process restart
- remote merge overwriting local-only state

---

## 9. Recommended Scope Boundary

This spec intentionally stops at the correctness substrate.

It does **not** define:

- remote transcript retrieval behavior
- Web UI status and failure messaging
- README / schema wording cleanup

Those belong in follow-up subprojects once the correctness substrate is stable.

---

## 10. Recommendation

Proceed with **snapshot sync + versioned metadata + durable index queue**.

This is the smallest design that still satisfies the chosen constraints:

- strict correctness
- one-time migration allowed
- local-only state preserved
- no need for full event sourcing

Anything lighter falls back to “eventual repair by restart or reconciliation,” which does not meet the bar for this subproject.
