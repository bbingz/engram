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
  filePath: string
  project: string | null
  summary: string | null
  startTime: string | null
  endTime: string | null
  source: string
}
```

### 1d. Classification rules

Evaluated in order. First match wins.

1. **skip**: `agentRole != null` OR `filePath` contains `/subagents/` OR `messageCount <= 1`
2. **premium**: `messageCount >= 20` OR (`messageCount >= 10` AND `project != null`) OR session duration > 30 minutes
3. **lite**: (`messageCount <= 5` AND `project == null`) OR summary matches noise patterns (`/usage`, `Generate a short, clear title`)
4. **normal**: everything else

Session duration is computed as `(endTime - startTime)` in minutes. If either timestamp is missing, duration is treated as 0.

### 1e. Pure function contract

`computeTier(input: TierInput): SessionTier` — no side effects, no DB access, no I/O. Deterministic given the same input.

---

## 2. Pipeline Gates

### 2a. Session writer gate

`session-writer.ts` calls `computeTier()` before writing. The tier value is included in the snapshot and persisted to the `tier` column.

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

### 2b. Viking push gate

`indexer.ts:pushToViking()` adds a tier check at the top:

```
if tier != 'premium' → return early
```

### 2c. Auto-summary gate

`daemon.ts` onSessionIndexed callback adds a tier check:

```
if tier != 'premium' → do not schedule summary
```

### 2d. Tier upgrade behavior

Every `indexFile()` / `indexAll()` / `pullFromPeer()` call recomputes tier from current session state. If a session upgrades (e.g., skip → normal), the writer:

1. Updates the `tier` column.
2. Enqueues newly applicable jobs (FTS, embedding) as normal.
3. Viking push triggers if the new tier is premium.

No "backfill" or "catch-up" mechanism needed — the standard pipeline handles upgrades naturally because every change triggers a full re-evaluation.

---

## 3. UI Noise Filtering

### 3a. Current state (to be replaced)

`buildNoiseFilters()` in `db.ts` produces 5 SQL conditions controlled by 3 boolean settings (`hideUsageSessions`, `hideEmptySessions`, `hideAutoSummary`).

### 3b. New model

Replace with a single `noiseFilter` setting and tier-based SQL:

| Setting value | SQL filter | Meaning |
|---------------|-----------|---------|
| `all` | no tier filter | Show everything including skip |
| `hide-skip` (default) | `WHERE tier != 'skip'` | Hide agents and 1-message sessions |
| `hide-noise` | `WHERE tier NOT IN ('skip', 'lite')` | Cleanest view: only normal + premium |

### 3c. Settings migration

Old toggles map to new setting on first read:

- If all three old toggles are `true` (default) → `hide-skip`
- If any old toggle is `false` → `all` (user wanted to see more, preserve that intent)
- Old toggle fields are ignored after migration.

### 3d. Swift side changes

- `NOISE_FILTER_SQL` in PopoverView / SessionListView replaced with `tier`-based predicate.
- Settings UI: 3 toggles → 1 picker (all / hide agents & noise / clean view).

---

## 4. Sync Path

### 4a. Local sessions

`indexer.ts` calls `computeTier()` inside `buildLocalAuthoritativeSnapshot()`. Tier is part of the snapshot, written by session-writer.

### 4b. Remote sessions

`sync.ts:pullFromPeer()` calls `computeTier()` after `normalizeRemoteSnapshot()`, before `writer.writeAuthoritativeSnapshot()`. Each node computes tier locally — tier is a processing strategy, not a data attribute.

### 4c. Export

`/api/sync/sessions` does NOT include `tier` in the export payload. Each peer computes its own tier.

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
  WHEN message_count <= 5 AND project IS NULL THEN 'lite'
  WHEN summary LIKE '%/usage%' THEN 'lite'
  WHEN summary LIKE '%Generate a short, clear title%' THEN 'lite'
  ELSE 'normal'
END
WHERE tier IS NULL
```

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
- messageCount 3, no project → lite
- `/usage` summary → lite
- auto-summary noise pattern → lite
- messageCount 8, with project → normal
- Boundary values: messageCount exactly 1, 2, 5, 10, 20
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
| `src/core/session-writer.ts` | Import and call `computeTier()`. Gate FTS/embedding job dispatch on tier. |
| `src/core/session-snapshot.ts` | Add `tier` field to `AuthoritativeSessionSnapshot`. |
| `src/core/indexer.ts` | Pass tier input to snapshot builder. Gate `pushToViking()` on tier. |
| `src/core/sync.ts` | Call `computeTier()` after normalizing remote snapshot. |
| `src/core/db.ts` | Add `tier` column migration + backfill + index. Replace `buildNoiseFilters()` with tier-based filtering. |
| `src/core/config.ts` | Replace 3 noise toggles with `noiseFilter` setting. Add migration for old toggles. |
| `src/daemon.ts` | Gate auto-summary trigger on tier. |
| `src/web.ts` | Update `listSessions` API to accept tier filter parameter. |
| `tests/core/session-tier.test.ts` | **New.** Exhaustive `computeTier()` tests. |
| `tests/core/session-writer.test.ts` | Add tier-gated job enqueue tests. |
| `tests/core/db.test.ts` | Add migration backfill and tier filter tests. |
| `tests/core/indexer.test.ts` | Add tier upgrade test. |
| `macos/Engram/Core/Database.swift` | Update `NOISE_FILTER_SQL` to use `tier` column. |
| `macos/Engram/Views/SettingsView.swift` | Replace 3 noise toggles with 1 picker. |

---

## 8. Scope Boundary

This spec covers only the tiering model and its integration into the existing pipeline. It does NOT cover:

- Custom per-node tier thresholds or user-configurable tier rules.
- Job runner priority ordering (jobs are dispatched or not, no reordering).
- Changes to the data-correctness merge semantics (tier is orthogonal to merge).
- Remote transcript retrieval or Web UI changes beyond noise filtering.
