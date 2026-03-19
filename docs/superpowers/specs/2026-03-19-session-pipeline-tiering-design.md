# Session Pipeline Tiering — Design Spec

**Date:** 2026-03-19
**Problem:** Engram treats all sessions equally across the processing pipeline. A 10,000-message core project session and a 1-message `/usage` query both go through the same parse → merge → FTS → embedding → Viking push → auto-summary pipeline. This wastes API tokens, embedding compute, and VLM generation on low-value sessions while providing no benefit.
**Solution:** Introduce a `SessionTier` model that classifies every session into one of four tiers. Each tier gates how deep the session travels through the processing pipeline. The tier is computed as a pure function, persisted in the sessions table, and reused by both the processing pipeline and UI noise filtering.
**Principle:** Compute tier every time a session is processed (no caching, no stale state). The cheapest operations (parse + merge) always run. Expensive operations (Viking, auto-summary) only run for high-value sessions.

---

## 0. Goals And Non-Goals

### Goals

- No wasted API tokens or VLM compute on sessions that provide no search or retrieval value.
- A single `computeTier()` function as the sole source of truth for session classification.
- Tier-driven processing: each pipeline stage checks tier at its gate.
- Unified noise filtering: UI visibility driven by the same tier column, replacing the current 5-condition SQL filter and 3 settings toggles.
- Tier upgrades are automatic: a session that grows from 1 message to 50 messages will be reclassified on its next processing pass.

### Non-Goals

- Do not introduce per-user or per-node tier configuration (all nodes use the same `computeTier()` logic).
- Do not add priority queuing to the job runner (jobs are dispatched or not; no reordering).
- Do not change the existing index job runner's recovery or retry mechanics.

---

## 1. Tier Model

### 1a. Enum

```typescript
type SessionTier = 'skip' | 'lite' | 'normal' | 'premium'
```

### 1b. Processing depth per tier

| Stage | skip | lite | normal | premium |
|-------|------|------|--------|---------|
| DB upsert (parse + merge) | yes | yes | yes | yes |
| FTS job enqueue | no | yes | yes | yes |
| Embedding job enqueue | no | no | yes | yes |
| Viking push | no | no | no | yes |
| Auto-summary trigger | no | no | no | yes |

### 1c. Input signals

```typescript
interface TierInput {
  messageCount: number
  agentRole: string | null
  filePath: string        // file_path or source_locator — used for /subagents/ check
  project: string | null
  summary: string | null
  startTime: string | null
  endTime: string | null
  source: string
}
```

**Where each field comes from:**

- Local indexing path: `agentRole` from `SessionInfo` (adapter parse), all other fields from `SessionInfo`.
- Sync path: `agentRole` from the remote snapshot's `agentRole` field (must be added to sync export), `filePath` from `sourceLocator` (remote file path, preserves `/subagents/` pattern). If `sourceLocator` is a sync URI without path info, `agentRole` is the primary agent detection signal.
- Snapshot pipeline: `agentRole` must be added to `AuthoritativeSessionSnapshot` and threaded through `buildLocalAuthoritativeSnapshot()` and `upsertAuthoritativeSnapshot()`.

### 1d. Classification rules

Evaluated in order. First match wins.

1. **skip**: `agentRole != null` OR `filePath` contains `/subagents/` OR `messageCount <= 1`
2. **premium**: `messageCount >= 20` OR (`messageCount >= 10` AND `project != null`) OR session duration > 30 minutes
3. **lite**: summary matches noise patterns (`/usage`, `Generate a short, clear title`)
4. **normal**: everything else

Session duration is computed as `(endTime - startTime)` in minutes. If either timestamp is missing, duration is treated as 0.

Note: The original draft had `messageCount <= 5 AND project == null` as a lite condition. This was removed because short sessions without a project (e.g., a 3-message debugging session) are still useful for search and embedding. The lite tier is now reserved for sessions whose summary explicitly indicates noise.

### 1e. Pure function contract

`computeTier(input: TierInput): SessionTier` — no side effects, no DB access, no I/O. Deterministic given the same input.

---

## 2. Pipeline Gates

### 2a. Tier computation site

`computeTier()` is called by the **indexer** (local path) and **sync engine** (remote path), NOT by the session writer. The tier is set on the snapshot before the writer receives it:

- **Local**: `indexer.ts:buildLocalAuthoritativeSnapshot()` calls `computeTier()` with fields from `SessionInfo`. The resulting tier is set on the `AuthoritativeSessionSnapshot`.
- **Sync**: `sync.ts:pullFromPeer()` calls `computeTier()` after `normalizeRemoteSnapshot()`, sets tier on the snapshot.
- **Writer**: `session-writer.ts:writeAuthoritativeSnapshot()` receives a snapshot with tier already set. It persists the tier column and uses it to gate job dispatch.

This avoids the problem of the writer needing external context (like `SessionInfo.agentRole`) that isn't available inside the merge transaction.

### 2b. Session writer gate

Job enqueue logic changes from:

```
if search_text_changed → enqueue FTS
if embedding_text_changed → enqueue embedding
```

To:

```
if tier != 'skip' AND search_text_changed → enqueue FTS
if tier IN ('normal', 'premium') AND embedding_text_changed → enqueue embedding
```

### 2c. Viking push gate

`indexer.ts` gates `pushToViking()` on the tier returned from snapshot building:

```
if tier != 'premium' → skip Viking push
```

The tier is available because `buildLocalAuthoritativeSnapshot()` returns it as part of the snapshot (or as a separate return value alongside the snapshot).

### 2d. Auto-summary gate

`daemon.ts` onIndexed callback needs the tier to gate auto-summary. The `indexFile()` return value is extended to include the computed tier:

```typescript
// indexer.ts
indexFile() returns { sessionId, tier, ... }

// daemon.ts onIndexed callback
onIndexed: (sessionId, messageCount, tier) => {
  if (tier === 'premium') {
    getAutoSummary()?.onSessionIndexed(sessionId, messageCount)
  }
  indexJobRunner.runRecoverableJobs().catch(() => {})
}
```

### 2e. Tier upgrade behavior

Every `indexFile()` / `indexAll()` / `pullFromPeer()` call recomputes tier from current session state. If a session upgrades (e.g., skip → normal), the writer:

1. Updates the `tier` column.
2. Enqueues newly applicable jobs (FTS, embedding) as normal.
3. Viking push triggers if the new tier is premium.

No "backfill" or "catch-up" mechanism needed — the standard pipeline handles upgrades naturally because every change triggers a full re-evaluation.

---

## 3. UI Noise Filtering

### 3a. Current state (to be replaced)

Three layers of noise filtering exist today:

1. **SQL**: `buildNoiseFilters()` in `db.ts` produces 5 SQL conditions controlled by 3 boolean settings. Used by `applyFilters()` (drives `listSessions`, `countSessions`) and `statsGroupBy()` (drives `/api/stats`).
2. **JS**: `isNoiseSession()` in `db.ts` is a parallel TypeScript implementation used by `search.ts` for in-memory filtering of search results.
3. **Swift**: `Database.swift` has 6 separate methods with hardcoded `agent_role IS NULL AND file_path NOT LIKE '%/subagents/%' AND message_count > 1` conditions (lines ~99, 178, 215, 457, 509, 560). There is no `NOISE_FILTER_SQL` constant — the SQL is inlined in each method.

All three layers must be updated.

### 3b. New model

Replace with a single `noiseFilter` setting and tier-based SQL:

| Setting value | SQL filter | Meaning |
|---------------|-----------|---------|
| `all` | no tier filter | Show everything including skip |
| `hide-skip` (default) | `WHERE tier != 'skip'` | Hide agents and 1-message sessions |
| `hide-noise` | `WHERE tier NOT IN ('skip', 'lite')` | Cleanest view: only normal + premium |

**All three layers converge:**

1. `buildNoiseFilters()` replaced with `buildTierFilter(noiseFilter)` returning a single `WHERE tier ...` clause.
2. `isNoiseSession()` replaced with `isSkippedTier(session)` checking `session.tier === 'skip'` (or `'lite'` depending on setting). Used by `search.ts`.
3. Swift `Database.swift`: all 6 hardcoded agent/noise conditions replaced with `AND tier != 'skip'` (or parameterized by the `noiseFilter` setting).

### 3c. Settings migration

Old toggles map to new setting on first read:

- If no old toggle fields exist in settings file (undefined = default) → `hide-skip`
- If all three old toggles are explicitly `true` → `hide-skip`
- If any old toggle is explicitly `false` → `all` (user wanted to see more, preserve that intent)
- Old toggle fields are ignored after migration.

### 3d. Swift side changes

- All 6 hardcoded noise filter SQL fragments in `Database.swift` replaced with `tier`-based predicate.
- `PopoverView.swift` inline noise filter SQL (lines ~200-215) replaced with tier check.
- Settings UI: 3 toggles → 1 picker (all / hide agents & noise / clean view).

---

## 4. Sync Path

### 4a. Local sessions

`indexer.ts` calls `computeTier()` inside `buildLocalAuthoritativeSnapshot()`. Tier is part of the snapshot, written by session-writer.

### 4b. Remote sessions

`sync.ts:pullFromPeer()` calls `computeTier()` after `normalizeRemoteSnapshot()`, before `writer.writeAuthoritativeSnapshot()`. Each node computes tier locally — tier is a processing strategy, not a data attribute.

### 4c. Export

`/api/sync/sessions` does NOT include `tier` in the export payload. Each peer computes its own tier.

The export DOES include `agentRole` (newly added) so that peers can classify agent sessions correctly even if their `sourceLocator` doesn't contain `/subagents/`.

---

## 5. Schema Migration

### 5a. Column addition

```sql
ALTER TABLE sessions ADD COLUMN tier TEXT
```

Guarded by `PRAGMA table_info(sessions)` check (existing pattern in `db.ts:migrate()`).

### 5b. Data backfill

```sql
UPDATE sessions SET tier = CASE
  WHEN agent_role IS NOT NULL THEN 'skip'
  WHEN file_path LIKE '%/subagents/%' THEN 'skip'
  WHEN message_count <= 1 THEN 'skip'
  WHEN message_count >= 20 THEN 'premium'
  WHEN message_count >= 10 AND project IS NOT NULL THEN 'premium'
  WHEN (julianday(end_time) - julianday(start_time)) * 1440 > 30 THEN 'premium'
  WHEN summary LIKE '%/usage%' THEN 'lite'
  WHEN summary LIKE '%Generate a short, clear title%' THEN 'lite'
  ELSE 'normal'
END
WHERE tier IS NULL
```

Note: `julianday(NULL)` returns NULL in SQLite, and `NULL > 30` evaluates to false, so sessions with missing timestamps correctly skip the premium duration check (treated as 0 duration).

Idempotent: `WHERE tier IS NULL` ensures it only touches unclassified rows.

### 5c. Index

```sql
CREATE INDEX IF NOT EXISTS idx_sessions_tier ON sessions(tier)
```

### 5d. Performance

~2500 sessions, single UPDATE + index creation: ~50ms at startup. No async or batching needed.

---

## 6. Testing

### 6a. Unit tests — `session-tier.test.ts`

`computeTier()` pure function, exhaustive branch coverage:

- agent session → skip
- subagent path → skip
- messageCount 0 and 1 → skip
- messageCount 25, no project → premium
- messageCount 15 + project → premium
- 40-minute session → premium
- `/usage` summary → lite
- auto-summary noise pattern → lite
- messageCount 3, no project, clean summary → normal (not lite — short sessions are still valuable)
- messageCount 8, with project → normal
- Boundary values: messageCount exactly 1, 2, 10, 20
- Missing timestamps → duration treated as 0

### 6b. Integration tests — `session-writer.test.ts`

Tier drives job enqueue:

- skip tier → 0 index jobs
- lite tier → FTS job only
- normal tier → FTS + embedding jobs
- premium tier → FTS + embedding jobs (Viking/summary gated externally)

### 6c. Migration tests — `db.test.ts`

- Backfill produces correct tier values for representative sessions
- `listSessions` with tier filter returns correct results

### 6d. Upgrade tests — `indexer.test.ts`

- Session starts at messageCount=1 (skip), grows to messageCount=10 + project (premium)
- Verify tier column updated and FTS + embedding jobs enqueued on upgrade

### 6e. Out of scope

- Viking push and auto-summary tier gates are single-line `if` checks, covered implicitly by existing tests.
- No end-to-end crash recovery tests (covered by data-correctness spec).

---

## 7. File Changes Summary

| File | Change |
|------|--------|
| `src/core/session-tier.ts` | **New.** `SessionTier` type, `TierInput` interface, `computeTier()` function, noise pattern constants. |
| `src/core/session-snapshot.ts` | Add `tier` and `agentRole` fields to `AuthoritativeSessionSnapshot`. |
| `src/core/session-writer.ts` | Gate FTS/embedding job dispatch on tier from the incoming snapshot. |
| `src/core/indexer.ts` | Call `computeTier()` in `buildLocalAuthoritativeSnapshot()`. Gate `pushToViking()` on tier. Extend `indexFile()` return to include tier. |
| `src/core/sync.ts` | Call `computeTier()` after `normalizeRemoteSnapshot()`. |
| `src/core/db.ts` | Add `tier` column migration + backfill + index. Add `agentRole` to `upsertAuthoritativeSnapshot()`. Replace `buildNoiseFilters()` and `isNoiseSession()` with tier-based filtering. Update `statsGroupBy()`. |
| `src/core/config.ts` | Replace 3 noise toggles with `noiseFilter` setting. Add migration for old toggles (handle undefined = default). |
| `src/daemon.ts` | Gate auto-summary trigger on tier (from `indexFile()` return value). |
| `src/web.ts` | Update `listSessions` API to accept tier filter parameter. Include `agentRole` in sync export. |
| `src/tools/search.ts` | Replace `isNoiseSession()` call with tier-based check. |
| `tests/core/session-tier.test.ts` | **New.** Exhaustive `computeTier()` tests. |
| `tests/core/session-writer.test.ts` | Add tier-gated job enqueue tests. |
| `tests/core/db.test.ts` | Add migration backfill and tier filter tests. |
| `tests/core/indexer.test.ts` | Add tier upgrade test. |
| `macos/Engram/Core/Database.swift` | Replace 6 hardcoded agent/noise SQL fragments with `tier`-based predicate. |
| `macos/Engram/Views/PopoverView.swift` | Replace inline noise filter SQL with tier check. |
| `macos/Engram/Views/SettingsView.swift` | Replace 3 noise toggles with 1 picker. |

---

## 8. Scope Boundary

This spec covers only the tiering model and its integration into the existing pipeline. It does NOT cover:

- Custom per-node tier thresholds or user-configurable tier rules.
- Job runner priority ordering (jobs are dispatched or not, no reordering).
- Changes to the data-correctness merge semantics (tier is orthogonal to merge).
- Remote transcript retrieval or Web UI changes beyond noise filtering.
