# Session Pipeline Tiering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify every session into one of four tiers (skip/lite/normal/premium) and gate each pipeline stage on the tier, so expensive operations only run on high-value sessions.

**Architecture:** A pure `computeTier()` function in a new `session-tier.ts` module is the sole source of truth. The indexer and sync engine call it before writing snapshots. The session writer uses the tier to gate job dispatch. UI noise filtering is replaced by tier-based SQL queries.

**Tech Stack:** TypeScript (strict, ES2022), Vitest, SQLite (better-sqlite3), SwiftUI (macOS 14+)

**Spec:** `docs/superpowers/specs/2026-03-19-session-pipeline-tiering-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/core/session-tier.ts` | Create | `SessionTier` type, `TierInput` interface, `computeTier()` pure function, `NOISE_PATTERNS` constant |
| `src/core/session-snapshot.ts` | Modify | Add `tier` and `agentRole` fields to `AuthoritativeSessionSnapshot` |
| `src/core/session-writer.ts` | Modify | Gate FTS/embedding job dispatch on `snapshot.tier` |
| `src/core/indexer.ts` | Modify | Call `computeTier()` in `buildLocalAuthoritativeSnapshot()`, gate `pushToViking()`, extend `indexFile()` return type to include `tier` |
| `src/core/watcher.ts` | Modify | Extend `WatcherOptions.onIndexed` to include `tier` parameter |
| `src/core/sync.ts` | Modify | Call `computeTier()` after `normalizeRemoteSnapshot()`, add `agentRole` to normalized snapshot |
| `src/core/db.ts` | Modify | Migration (tier column + backfill + index), add `agentRole`+`tier` to `upsertAuthoritativeSnapshot()`, replace `buildNoiseFilters()`/`isNoiseSession()` with tier-based filtering |
| `src/core/config.ts` | Modify | Replace 3 noise toggles with `noiseFilter` setting, add migration logic |
| `src/daemon.ts` | Modify | Gate auto-summary on tier, update `onIndexed` callback, replace `db.noiseSettings` with tier-based setting |
| `src/index.ts` | Modify | Replace `db.noiseSettings` with tier-based setting |
| `src/web.ts` | Modify | Add `agentRole` to sync export, accept tier filter on list API |
| `src/tools/search.ts` | Modify | Replace `isNoiseSession()` with tier-based check |
| `tests/core/session-tier.test.ts` | Create | Exhaustive `computeTier()` branch coverage |
| `tests/core/session-writer.test.ts` | Modify | Add tier-gated job enqueue tests |
| `tests/core/db.test.ts` | Modify | Add migration backfill and tier filter tests |
| `tests/core/indexer.test.ts` | Modify | Add tier upgrade test |
| `macos/Engram/Core/Database.swift` | Modify | Replace 6 hardcoded noise filter SQL with `tier`-based predicate |
| `macos/Engram/Views/PopoverView.swift` | Modify | Replace inline noise filter with tier check |
| `macos/Engram/Views/SettingsView.swift` | Modify | Replace 3 noise toggles with 1 picker |

---

### Task 1: `computeTier()` pure function + tests

**Files:**
- Create: `src/core/session-tier.ts`
- Create: `tests/core/session-tier.test.ts`

- [ ] **Step 1: Write the test file**

```typescript
// tests/core/session-tier.test.ts
import { describe, it, expect } from 'vitest'
import { computeTier, type TierInput } from '../../src/core/session-tier.js'

function input(overrides: Partial<TierInput> = {}): TierInput {
  return {
    messageCount: 10,
    agentRole: null,
    filePath: '/home/user/.claude/projects/abc/session.jsonl',
    project: 'my-project',
    summary: 'Fixed login bug',
    startTime: '2026-03-19T10:00:00Z',
    endTime: '2026-03-19T10:20:00Z',
    source: 'claude-code',
    ...overrides,
  }
}

describe('computeTier', () => {
  // --- skip ---
  it('agent session → skip', () => {
    expect(computeTier(input({ agentRole: 'subagent' }))).toBe('skip')
  })
  it('subagent path → skip', () => {
    expect(computeTier(input({ agentRole: null, filePath: '/home/.claude/projects/abc/subagents/agent-1.jsonl' }))).toBe('skip')
  })
  it('messageCount 0 → skip', () => {
    expect(computeTier(input({ messageCount: 0 }))).toBe('skip')
  })
  it('messageCount 1 → skip', () => {
    expect(computeTier(input({ messageCount: 1 }))).toBe('skip')
  })

  // --- premium ---
  it('messageCount 20 → premium', () => {
    expect(computeTier(input({ messageCount: 20 }))).toBe('premium')
  })
  it('messageCount 25, no project → premium', () => {
    expect(computeTier(input({ messageCount: 25, project: null }))).toBe('premium')
  })
  it('messageCount 10 + project → premium', () => {
    expect(computeTier(input({ messageCount: 10, project: 'engram' }))).toBe('premium')
  })
  it('messageCount 15 + project → premium', () => {
    expect(computeTier(input({ messageCount: 15, project: 'engram' }))).toBe('premium')
  })
  it('40-minute session → premium', () => {
    expect(computeTier(input({
      messageCount: 5, project: null,
      startTime: '2026-03-19T10:00:00Z',
      endTime: '2026-03-19T10:40:00Z',
    }))).toBe('premium')
  })
  it('exactly 30min session → normal (not premium)', () => {
    expect(computeTier(input({
      messageCount: 5, project: null,
      startTime: '2026-03-19T10:00:00Z',
      endTime: '2026-03-19T10:30:00Z',
    }))).toBe('normal')
  })

  // --- lite ---
  it('/usage summary → lite', () => {
    expect(computeTier(input({ messageCount: 5, project: null, summary: '\n/usage\n' }))).toBe('lite')
  })
  it('auto-summary noise pattern → lite', () => {
    expect(computeTier(input({ messageCount: 5, project: null, summary: 'Generate a short, clear title for this conversation' }))).toBe('lite')
  })

  // --- normal ---
  it('messageCount 3, no project, clean summary → normal', () => {
    expect(computeTier(input({ messageCount: 3, project: null, summary: 'Debug session' }))).toBe('normal')
  })
  it('messageCount 8 + project → normal (below premium threshold)', () => {
    expect(computeTier(input({ messageCount: 8, project: 'engram' }))).toBe('normal')
  })
  it('messageCount 2, no summary → normal', () => {
    expect(computeTier(input({ messageCount: 2, project: null, summary: null }))).toBe('normal')
  })

  // --- edge cases ---
  it('skip takes priority over premium (agent with 50 messages)', () => {
    expect(computeTier(input({ agentRole: 'subagent', messageCount: 50 }))).toBe('skip')
  })
  it('premium takes priority over lite (/usage with 25 messages)', () => {
    expect(computeTier(input({ messageCount: 25, summary: '/usage' }))).toBe('premium')
  })
  it('missing timestamps → duration 0, no premium from duration', () => {
    expect(computeTier(input({ messageCount: 5, project: null, startTime: null, endTime: null, summary: 'ok' }))).toBe('normal')
  })
  it('missing endTime → duration 0', () => {
    expect(computeTier(input({ messageCount: 5, project: null, endTime: null, summary: 'ok' }))).toBe('normal')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/session-tier.test.ts`
Expected: FAIL — module `../../src/core/session-tier.js` not found

- [ ] **Step 3: Write the implementation**

```typescript
// src/core/session-tier.ts
export type SessionTier = 'skip' | 'lite' | 'normal' | 'premium'

export interface TierInput {
  messageCount: number
  agentRole: string | null
  filePath: string
  project: string | null
  summary: string | null
  startTime: string | null
  endTime: string | null
  source: string
}

const NOISE_PATTERNS = ['/usage', 'Generate a short, clear title']

function durationMinutes(startTime: string | null, endTime: string | null): number {
  if (!startTime || !endTime) return 0
  const start = new Date(startTime).getTime()
  const end = new Date(endTime).getTime()
  if (Number.isNaN(start) || Number.isNaN(end)) return 0
  return (end - start) / 60_000
}

export function computeTier(input: TierInput): SessionTier {
  // 1. skip
  if (input.agentRole != null) return 'skip'
  if (input.filePath.includes('/subagents/')) return 'skip'
  if (input.messageCount <= 1) return 'skip'

  // 2. premium
  if (input.messageCount >= 20) return 'premium'
  if (input.messageCount >= 10 && input.project != null) return 'premium'
  if (durationMinutes(input.startTime, input.endTime) > 30) return 'premium'

  // 3. lite
  if (input.summary && NOISE_PATTERNS.some(p => input.summary!.includes(p))) return 'lite'

  // 4. normal
  return 'normal'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/session-tier.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/session-tier.ts tests/core/session-tier.test.ts
git commit -m "feat: add computeTier() pure function with exhaustive tests"
```

---

### Task 2: Add `tier` and `agentRole` to snapshot type + DB migration

**Files:**
- Modify: `src/core/session-snapshot.ts:3-25` (add fields to `AuthoritativeSessionSnapshot`)
- Modify: `src/core/db.ts` (migration, upsert, backfill)
- Modify: `tests/core/db.test.ts`

- [ ] **Step 1: Write the migration/backfill test**

Add to `tests/core/db.test.ts`:

```typescript
describe('tier migration', () => {
  it('backfills tier column for existing sessions', () => {
    // Insert sessions covering all tiers
    db.upsertSession({ id: 'agent-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 10, userMessageCount: 5, assistantMessageCount: 5, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f', sizeBytes: 100, agentRole: 'subagent' })
    db.upsertSession({ id: 'skip-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 1, userMessageCount: 1, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f2', sizeBytes: 100 })
    db.upsertSession({ id: 'premium-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 25, userMessageCount: 15, assistantMessageCount: 10, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f3', sizeBytes: 100, project: 'engram' })
    db.upsertSession({ id: 'lite-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 5, userMessageCount: 3, assistantMessageCount: 2, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f4', sizeBytes: 100, summary: '/usage check' })
    db.upsertSession({ id: 'normal-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 8, userMessageCount: 4, assistantMessageCount: 4, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f5', sizeBytes: 100, project: 'test', summary: 'Fix bug' })

    // Run backfill (already ran in constructor, but these were inserted after)
    db.backfillTiers()

    const raw = db.getRawDb()
    expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('agent-1')).toHaveProperty('tier', 'skip')
    expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('skip-1')).toHaveProperty('tier', 'skip')
    expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('premium-1')).toHaveProperty('tier', 'premium')
    expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('lite-1')).toHaveProperty('tier', 'lite')
    expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('normal-1')).toHaveProperty('tier', 'normal')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/db.test.ts -t "tier migration"`
Expected: FAIL — `backfillTiers` not found / tier column doesn't exist

- [ ] **Step 3: Add `tier` and `agentRole` to `AuthoritativeSessionSnapshot`**

In `src/core/session-snapshot.ts`, add to the interface:

```typescript
  tier?: SessionTier       // computed by computeTier(), persisted to DB
  agentRole?: string | null // threaded from SessionInfo for tier computation and sync export
```

Add import at top: `import type { SessionTier } from './session-tier.js'`

- [ ] **Step 4: Add DB migration + backfill + upsert changes**

In `src/core/db.ts`:

**4a. CREATE TABLE** — add `tier TEXT` to the `CREATE TABLE IF NOT EXISTS sessions` statement (line ~124-151). This ensures fresh databases have the column.

**4b. ALTER TABLE migration** — inside the existing `if (cols.length > 0)` block, add:

```typescript
if (!colNames.has('tier')) {
  raw.exec('ALTER TABLE sessions ADD COLUMN tier TEXT')
  raw.exec('CREATE INDEX IF NOT EXISTS idx_sessions_tier ON sessions(tier)')
}
```

**4c. Backfill method** — add a public `backfillTiers()` method:

```typescript
backfillTiers(): void {
  this.db.exec(`
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
  `)
}
```

Call `this.backfillTiers()` at the end of `migrate()`.

**4d. upsertAuthoritativeSnapshot()** — add `tier` and `agent_role` to the INSERT column list, VALUES placeholders, and ON CONFLICT UPDATE SET clause. Map from `snapshot.tier ?? 'normal'` and `snapshot.agentRole ?? null`.

**4e. Row mappers** — update both `rowToAuthoritativeSnapshot()` (line ~942) and `rowToSession()` (line ~916) to include `tier` from the DB row. Also update `rowToAuthoritativeSnapshot()` to map `agent_role` → `agentRole`.

**4f. SessionInfo type** — add `tier?: string` to `SessionInfo` in `src/adapters/types.ts` so that `search.ts` and other consumers can access it from `getSession()` results.

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run tests/core/db.test.ts -t "tier migration"`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `npx vitest run`
Expected: All existing tests still pass (no regressions)

- [ ] **Step 7: Commit**

```bash
git add src/core/session-snapshot.ts src/core/db.ts tests/core/db.test.ts
git commit -m "feat: add tier/agentRole to snapshot, DB migration with backfill"
```

---

### Task 3: Gate job dispatch in session writer

**Files:**
- Modify: `src/core/session-writer.ts:26-31`
- Modify: `tests/core/session-writer.test.ts`

- [ ] **Step 1: Write the tier-gated job enqueue tests**

Add to `tests/core/session-writer.test.ts`:

```typescript
describe('tier-gated job dispatch', () => {
  // Construct snapshots inline following the existing test patterns in this file.
  // Each snapshot needs a unique id, a distinct summary (to trigger search_text_changed),
  // and the tier field set.

  it('skip tier → 0 index jobs', () => {
    // Build a snapshot with tier: 'skip'. Write it.
    // Verify db.listIndexJobs returns 0 jobs for this session.
  })

  it('lite tier → FTS job only', () => {
    // Build a snapshot with tier: 'lite'. Write it.
    // Verify only an 'fts' job is created.
  })

  it('normal tier → FTS + embedding jobs', () => {
    // Build a snapshot with tier: 'normal'. Write it.
    // Verify both 'fts' and 'embedding' jobs are created.
  })

  it('premium tier → FTS + embedding jobs', () => {
    // Build a snapshot with tier: 'premium'. Write it.
    // Verify both 'fts' and 'embedding' jobs are created.
  })
})
```

Note: Follow the existing snapshot construction pattern in the test file (inline objects, not a helper). Add the `tier` field to each snapshot.

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/session-writer.test.ts -t "tier-gated"`
Expected: FAIL — skip tier still produces jobs

- [ ] **Step 3: Implement the gate in session-writer.ts**

Replace the job enqueue block (lines 26-31) with:

```typescript
const tier = mergeResult.merged.tier ?? 'normal'
const jobKinds: IndexJobKind[] = []
if (tier !== 'skip' && mergeResult.changeSet.flags.has('search_text_changed')) jobKinds.push('fts')
if ((tier === 'normal' || tier === 'premium') && mergeResult.changeSet.flags.has('embedding_text_changed')) jobKinds.push('embedding')
if (jobKinds.length > 0) {
  this.db.insertIndexJobs(snapshot.id, snapshot.syncVersion, jobKinds)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/session-writer.test.ts`
Expected: All tests PASS (including existing ones)

- [ ] **Step 5: Commit**

```bash
git add src/core/session-writer.ts tests/core/session-writer.test.ts
git commit -m "feat: gate FTS/embedding job dispatch on session tier"
```

---

### Task 4: Indexer — compute tier + gate Viking push + return tier

**Files:**
- Modify: `src/core/indexer.ts`
- Modify: `tests/core/indexer.test.ts`

- [ ] **Step 1: Write tier upgrade test**

Add to `tests/core/indexer.test.ts`:

```typescript
it('tier upgrades from skip to premium on message growth', async () => {
  // First index: 1 message → skip
  // Second index: 15 messages + project → premium
  // Verify tier column updated and jobs enqueued
  // (Use existing test fixtures or mock adapter to control message counts)
})
```

Adapt to the existing test patterns in the file — read the file first to understand the fixture/mock setup.

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/indexer.test.ts -t "tier upgrades"`
Expected: FAIL

- [ ] **Step 3: Implement tier computation in indexer**

In `src/core/indexer.ts`:

1. Add import: `import { computeTier, type SessionTier } from './session-tier.js'`

2. In `buildLocalAuthoritativeSnapshot()`, after building the snapshot object, compute and add tier:

```typescript
const tier = computeTier({
  messageCount: info.messageCount,
  agentRole: info.agentRole ?? null,
  filePath,
  project: info.project ?? null,
  summary: info.summary ?? null,
  startTime: info.startTime,
  endTime: info.endTime ?? null,
  source: info.source,
})

return {
  ...snapshot,  // existing spread
  tier,
  agentRole: info.agentRole ?? null,
}
```

3. Gate `pushToViking()` in both `indexAll()` and `indexFile()`:

```typescript
// In indexAll(), after writer.writeAuthoritativeSnapshot():
if (snapshot.tier === 'premium') {
  this.pushToViking(info, messages)
}

// In indexFile(), similarly:
if (snapshot.tier === 'premium') {
  this.pushToViking(info, messages)
}
```

4. Extend `indexFile()` return type to include `tier`:

```typescript
async indexFile(...): Promise<{ indexed: boolean; sessionId?: string; messageCount?: number; tier?: SessionTier }> {
  // ...
  return { indexed: true, sessionId: info.id, messageCount: info.messageCount ?? messages.length, tier: snapshot.tier }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/indexer.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/indexer.ts tests/core/indexer.test.ts
git commit -m "feat: compute tier in indexer, gate Viking push on premium"
```

---

### Task 5: Watcher + daemon — thread tier through callback, gate auto-summary

**Files:**
- Modify: `src/core/watcher.ts:8-9,51-52`
- Modify: `src/daemon.ts:155-161`

- [ ] **Step 1: Update watcher callback signature**

In `src/core/watcher.ts`:

```typescript
import type { SessionTier } from './session-tier.js'

export interface WatcherOptions {
  onIndexed?: (sessionId: string, messageCount: number, tier: SessionTier) => void
}
```

Update `handleChange` to pass tier:

```typescript
const result = await indexer.indexFile(adapter, filePath)
if (result.indexed && result.sessionId) {
  opts?.onIndexed?.(result.sessionId, result.messageCount ?? 0, result.tier ?? 'normal')
}
```

- [ ] **Step 2: Update daemon callback to use tier**

In `src/daemon.ts`, update the `onIndexed` callback:

```typescript
const watcher = startWatcher(adapters, indexer, {
  onIndexed: (sessionId, messageCount, tier) => {
    emit({ event: 'watcher_indexed', total: db.countSessions() })
    if (tier === 'premium') {
      getAutoSummary()?.onSessionIndexed(sessionId, messageCount)
    }
    indexJobRunner.runRecoverableJobs().catch(() => {})
  },
})
```

- [ ] **Step 3: Run full test suite**

Run: `npx vitest run`
Expected: All tests PASS (watcher tests may need the new parameter)

- [ ] **Step 4: Commit**

```bash
git add src/core/watcher.ts src/daemon.ts
git commit -m "feat: thread tier through watcher callback, gate auto-summary on premium"
```

---

### Task 6: Sync path — compute tier for remote sessions

**Files:**
- Modify: `src/core/sync.ts`
- Modify: `tests/core/sync.test.ts`

- [ ] **Step 1: Write test for tier on synced session**

Add to `tests/core/sync.test.ts`:

```typescript
it('computes tier for synced sessions', async () => {
  // Mock a peer returning a session with 25 messages
  // After sync, verify the session has tier = 'premium' in DB
})
```

Adapt to existing mock/fixture patterns in the file.

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/sync.test.ts -t "computes tier"`
Expected: FAIL

- [ ] **Step 3: Implement tier computation in sync**

In `src/core/sync.ts`:

1. Add import: `import { computeTier } from './session-tier.js'`

2. In `pullFromPeer()`, after `normalizeRemoteSnapshot()`, compute and set tier:

```typescript
const snapshot = this.normalizeRemoteSnapshot(peer.name, session)
snapshot.tier = computeTier({
  messageCount: snapshot.messageCount,
  agentRole: snapshot.agentRole ?? null,
  filePath: snapshot.sourceLocator,
  project: snapshot.project ?? null,
  summary: snapshot.summary ?? null,
  startTime: snapshot.startTime,
  endTime: snapshot.endTime ?? null,
  source: snapshot.source,
})
```

3. In `normalizeRemoteSnapshot()`, thread `agentRole`:

```typescript
return {
  ...existing fields,
  agentRole: 'agentRole' in raw ? (raw as any).agentRole ?? null : null,
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/sync.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/sync.ts tests/core/sync.test.ts
git commit -m "feat: compute tier for synced sessions, thread agentRole"
```

---

### Task 7: Replace noise filtering with tier-based filtering

**Files:**
- Modify: `src/core/db.ts:46-82,96,798,881`
- Modify: `src/core/config.ts:76-79`
- Modify: `src/daemon.ts:24-29`
- Modify: `src/index.ts:42-46`
- Modify: `src/tools/search.ts:2,150`
- Modify: `src/web.ts` (sync export)
- Modify: `tests/core/db.test.ts:206-221`

- [ ] **Step 1: Update config.ts**

Replace the 3 noise toggles with:

```typescript
// ── Noise filtering ──────────────────────────────────────────────
noiseFilter?: 'all' | 'hide-skip' | 'hide-noise';  // default: 'hide-skip'
// Legacy (ignored if noiseFilter is set):
hideUsageSessions?: boolean;
hideEmptySessions?: boolean;
hideAutoSummary?: boolean;
```

Add a migration helper at the bottom of `readFileSettings()`:

```typescript
// Migrate legacy noise toggles to noiseFilter
if (raw.noiseFilter === undefined) {
  const hasExplicitFalse = raw.hideUsageSessions === false || raw.hideEmptySessions === false || raw.hideAutoSummary === false
  raw.noiseFilter = hasExplicitFalse ? 'all' : 'hide-skip'
}
```

- [ ] **Step 2: Replace `buildNoiseFilters()` and `isNoiseSession()` in db.ts**

Replace the noise filter section (lines 46-82) with:

```typescript
export type NoiseFilter = 'all' | 'hide-skip' | 'hide-noise'

export function buildTierFilter(filter: NoiseFilter = 'hide-skip'): string[] {
  if (filter === 'all') return []
  if (filter === 'hide-noise') return ["tier NOT IN ('skip', 'lite')"]
  return ["tier != 'skip'"]  // hide-skip (default)
}

export function isTierHidden(tier: string | null | undefined, filter: NoiseFilter = 'hide-skip'): boolean {
  if (filter === 'all') return false
  if (filter === 'hide-noise') return tier === 'skip' || tier === 'lite'
  return tier === 'skip'
}
```

Replace `noiseSettings: NoiseFilterSettings` on the Database class with:

```typescript
noiseFilter: NoiseFilter = 'hide-skip'
```

Update `applyFilters()` (line ~881) and `statsGroupBy()` (line ~798) to use `buildTierFilter(this.noiseFilter)` instead of `buildNoiseFilters(this.noiseSettings)`.

- [ ] **Step 3: Update daemon.ts and index.ts**

In `src/daemon.ts`, replace lines 24-29:

```typescript
db.noiseFilter = settings.noiseFilter ?? 'hide-skip'
```

Same pattern in `src/index.ts`.

- [ ] **Step 4: Update search.ts**

Replace import and usage:

```typescript
import { isTierHidden, type Database, type SearchFilters } from '../core/db.js'
// ...
if (params.agents === 'hide' && isTierHidden(session.tier, db.noiseFilter)) continue
```

Note: `session` returned from DB must now include `tier`. Check `getSession()` return type.

- [ ] **Step 5: Add `agentRole` to sync export in web.ts**

In `src/web.ts`, ensure the `/api/sync/sessions` endpoint includes `agentRole` in the response. If using `listSessionsAfterCursor()` which returns `AuthoritativeSessionSnapshot`, the `agentRole` field is already on the type after Task 2. Verify `rowToAuthoritativeSnapshot()` in db.ts maps `agent_role` → `agentRole`.

- [ ] **Step 6: Update db.test.ts noise filter tests**

Replace the `isNoiseSession` tests with tier-based equivalents:

```typescript
describe('tier-based filtering', () => {
  it('isTierHidden with hide-skip', () => {
    expect(isTierHidden('skip', 'hide-skip')).toBe(true)
    expect(isTierHidden('lite', 'hide-skip')).toBe(false)
    expect(isTierHidden('normal', 'hide-skip')).toBe(false)
  })
  it('isTierHidden with hide-noise', () => {
    expect(isTierHidden('skip', 'hide-noise')).toBe(true)
    expect(isTierHidden('lite', 'hide-noise')).toBe(true)
    expect(isTierHidden('normal', 'hide-noise')).toBe(false)
  })
  it('isTierHidden with all', () => {
    expect(isTierHidden('skip', 'all')).toBe(false)
  })
})
```

- [ ] **Step 7: Run full test suite**

Run: `npm run build && npx vitest run`
Expected: All tests PASS

- [ ] **Step 8: Commit**

```bash
git add src/core/db.ts src/core/config.ts src/daemon.ts src/index.ts src/tools/search.ts src/web.ts tests/core/db.test.ts
git commit -m "feat: replace noise filtering with tier-based filtering"
```

---

### Task 8: Swift UI — replace noise filters with tier-based queries

**Files:**
- Modify: `macos/Engram/Core/Database.swift` (6 locations)
- Modify: `macos/Engram/Views/PopoverView.swift`
- Modify: `macos/Engram/Views/SettingsView.swift`

- [ ] **Step 1: Update Database.swift**

Find all 6 occurrences of the hardcoded noise filter:

```swift
AND agent_role IS NULL AND file_path NOT LIKE '%/subagents/%' AND message_count > 1
```

Replace each with:

```swift
AND tier != 'skip'
```

These are in: `listSessions`, `listSessionsForProject`, `countSessions`, `listSessionsChronologically`, `listGroups`, `listSessionsInGroup`.

- [ ] **Step 2: Update PopoverView.swift**

Replace the inline noise filter SQL (lines ~200-215, built from `readNoiseSettings()`) with tier-based filtering. The setting read should map to the new `noiseFilter` field from settings.json.

- [ ] **Step 3: Update SettingsView.swift**

Replace the 3 toggle switches (`hideUsageSessions`, `hideEmptySessions`, `hideAutoSummary`) with a single Picker:

```swift
Picker("Noise Filter", selection: $noiseFilter) {
    Text("Show All").tag("all")
    Text("Hide Agents & Noise").tag("hide-skip")
    Text("Clean View").tag("hide-noise")
}
```

- [ ] **Step 4: Build and verify**

Run: `cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add macos/Engram/Core/Database.swift macos/Engram/Views/PopoverView.swift macos/Engram/Views/SettingsView.swift
git commit -m "feat(macos): replace noise filter toggles with tier-based filtering"
```

---

### Task 9: Final verification

- [ ] **Step 1: Run full TypeScript test suite**

Run: `npm run build && npx vitest run`
Expected: All tests PASS

- [ ] **Step 2: Build macOS app**

Run: `cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: Build succeeds

- [ ] **Step 3: Manual smoke test**

Start the daemon and verify:
1. Existing sessions have tier values after migration
2. New session changes trigger correct tier computation
3. Skip-tier sessions don't appear in default view
4. Premium-tier sessions trigger auto-summary (if configured)

Run: `node dist/daemon.js`
Check stdout JSON lines for `event: 'ready'` with correct total.

- [ ] **Step 4: Commit any remaining fixes**

```bash
git add -A && git commit -m "fix: address issues from final verification"
```
