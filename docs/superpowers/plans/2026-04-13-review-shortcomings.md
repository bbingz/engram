# Review Shortcomings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address all findings from 3-way code review (Claude/Codex/Gemini), raising the project score from 7.9 to 8.5+.

**Architecture:** 5 phases executed in dependency order: cleanup → db split → degradation UX → test coverage → docs. The db.ts God Object (1845 lines) is split into 10 domain modules behind an ESM-compatible shim. Text-only insights get full write+read paths. Coverage raised from 67% to 75%+.

**Tech Stack:** TypeScript (strict, Node16 ESM), Vitest, Biome, better-sqlite3, sqlite-vec

**Spec:** `docs/superpowers/specs/2026-04-13-review-shortcomings-design.md` (v3)

---

## Phase 1: Dead Code Cleanup + Type Safety

### Task 1: Resolve knip unused files (4)

**Files:**
- Modify: `knip.json` (create if needed, or `package.json` knip config)
- Possibly delete: `src/core/git-probe.ts`, `src/adapters/claude-usage-probe.ts`, `src/adapters/codex-usage-probe.ts`

- [ ] **Step 1: Verify which "unused files" are real entrypoints**

```bash
# daemon.ts is launched by macOS app — confirmed entrypoint
grep -r "daemon" macos/scripts/build-node-bundle.sh
# Probe files are imported by daemon.ts
grep -r "git-probe\|claude-usage-probe\|codex-usage-probe" src/daemon.ts
```

Expected: `daemon.ts` imports all 3 probe files. All 4 files are false positives.

- [ ] **Step 2: Create knip config to register daemon.ts as entrypoint**

Create `knip.json` at project root:

```json
{
  "$schema": "https://unpkg.com/knip@6/schema.json",
  "entry": [
    "src/index.ts",
    "src/daemon.ts"
  ],
  "project": ["src/**/*.ts"],
  "ignore": ["src/types/**"],
  "ignoreDependencies": []
}
```

- [ ] **Step 3: Run knip to verify unused files resolved**

```bash
npx knip 2>&1 | grep "Unused files"
```

Expected: "Unused files" section gone (0 findings in that category).

- [ ] **Step 4: Commit**

```bash
git add knip.json
git commit -m "chore: add knip config — register daemon.ts as entrypoint"
```

---

### Task 2: Resolve knip unused exports (14 functions/constants)

**Files:**
- Modify: `src/tools/handoff.ts`, `src/tools/lint_config.ts`, `src/utils/time.ts`, `src/adapters/antigravity.ts`, `src/core/bootstrap.ts`, `src/core/config.ts`, `src/core/db.ts`, `src/core/resume-coordinator.ts`, `src/core/sanitizer.ts`, `src/core/watcher.ts`

- [ ] **Step 1: Triage each unused export**

Run for each:
```bash
# For each export, check if used in tests or other files
grep -rn "formatDuration" src/ tests/ --include="*.ts"
grep -rn "formatRelativeTime" src/ tests/ --include="*.ts"
grep -rn "toLocalWeekStart" src/ tests/ --include="*.ts"
grep -rn "parseMarkdownToMessages" src/ tests/ --include="*.ts"
grep -rn "ENGRAM_DIR" src/ tests/ --include="*.ts"
grep -rn "writeFileSettings" src/ tests/ --include="*.ts"
grep -rn "buildTierFilter" src/ tests/ --include="*.ts"
grep -rn "detectTool" src/ tests/ --include="*.ts"
grep -rn "PII_PATTERNS" src/ tests/ --include="*.ts"
grep -rn "getWatchEntries" src/ tests/ --include="*.ts"
grep -rn "checkStaleBranches" src/ tests/ --include="*.ts"
grep -rn "checkLargeUncommitted" src/ tests/ --include="*.ts"
grep -rn "checkZombieProcesses" src/ tests/ --include="*.ts"
grep -rn "runHealthChecks" src/ tests/ --include="*.ts"
```

- [ ] **Step 2: Un-export functions only used internally in their own module**

For lint_config functions (`checkStaleBranches`, `checkLargeUncommitted`, `checkZombieProcesses`, `runHealthChecks`) — if only called within `lint_config.ts` itself, remove `export` keyword.

For `formatDuration`, `formatRelativeTime` in `handoff.ts` — if only used internally, remove `export`.

For `toLocalWeekStart` in `time.ts` — if unused everywhere, delete the function.

For `parseMarkdownToMessages` in `antigravity.ts` — if unused outside its file, remove `export`.

- [ ] **Step 3: Add knip ignoreExports for legitimate public API**

For exports used in tests or intentionally public (e.g., `buildTierFilter`, `PII_PATTERNS`, `ENGRAM_DIR`), update `knip.json`:

```json
{
  "entry": ["src/index.ts", "src/daemon.ts"],
  "project": ["src/**/*.ts"],
  "ignore": ["src/types/**"],
  "ignoreExportsUsedInFile": true
}
```

Or add inline `// knip:ignore` comments where needed.

- [ ] **Step 4: Run knip, verify 0 unused exports**

```bash
npx knip 2>&1 | grep "Unused exports"
```

Expected: 0 unused exports.

- [ ] **Step 5: Run tests to ensure nothing broke**

```bash
npm test
```

Expected: 690 tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: resolve 14 knip unused exports — un-export internals, configure ignores"
```

---

### Task 3: Resolve knip unused exported types (54)

**Files:**
- Modify: multiple files across `src/core/`, `src/tools/`, `src/adapters/`

- [ ] **Step 1: Categorize all 54 unused types**

```bash
npx knip 2>&1 | grep -A 100 "Unused exported types"
```

For each type, grep across `src/` AND `tests/`:
```bash
# Example for first few
grep -rn "AiAuditRecord" src/ tests/ --include="*.ts" | grep -v "export interface"
grep -rn "AlertResult" src/ tests/ --include="*.ts" | grep -v "export interface"
```

Types used in tests → add to knip test entry pattern.
Types truly unused → remove `export` keyword (keep as module-private if used internally) or delete if dead.
Types that are public API → add knip ignore.

- [ ] **Step 2: Update knip config to include test files**

```json
{
  "entry": ["src/index.ts", "src/daemon.ts", "tests/**/*.test.ts"],
  "project": ["src/**/*.ts"]
}
```

- [ ] **Step 3: Batch remove `export` from truly unused types**

For each type with zero references outside its own file, change `export interface Foo` to `interface Foo` or delete entirely.

- [ ] **Step 4: Verify**

```bash
npx knip 2>&1 | grep "Unused exported types"
npm test
npm run lint
```

Expected: 0 unused exported types, 690 tests pass, 0 lint issues.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: resolve 54 knip unused exported types"
```

---

### Task 4: Remove unused dependencies + tighten Biome

**Files:**
- Modify: `package.json`, `biome.json`
- Modify: multiple `src/` files (fix `any` warnings)

- [ ] **Step 1: Remove unused deps**

```bash
npm uninstall js-yaml @types/js-yaml
```

- [ ] **Step 2: Verify no breakage**

```bash
npm run build
npm test
```

- [ ] **Step 3: Update biome.json — enable noExplicitAny as warn**

In `biome.json`, change:
```json
"noExplicitAny": "warn"
```

- [ ] **Step 4: Run lint to see warnings**

```bash
npm run lint 2>&1 | head -50
```

- [ ] **Step 5: Fix quick-win any usages**

For each warning, if the fix is obvious (e.g., `any` → `unknown`, or a specific type), fix it. For complex ones, add:
```ts
// biome-ignore lint/suspicious/noExplicitAny: <reason>
```

- [ ] **Step 6: Verify all clean**

```bash
npm run lint
npx knip
npm test
```

Expected: 0 lint issues, 0 knip findings, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: remove unused deps (js-yaml), enable noExplicitAny warn, fix any types"
```

---

### Task 5: Temporarily lower coverage thresholds

**Files:**
- Modify: `vitest.config.ts`

- [ ] **Step 1: Lower thresholds to unblock CI**

In `vitest.config.ts`, change:
```ts
thresholds: {
  lines: 65,
  branches: 60,
  functions: 70,
}
```

- [ ] **Step 2: Verify coverage passes**

```bash
npm run test:coverage 2>&1 | tail -10
```

Expected: No threshold errors.

- [ ] **Step 3: Commit**

```bash
git add vitest.config.ts
git commit -m "chore: temporarily lower coverage thresholds (will restore in Phase 3)"
```

---

## Phase 2: db.ts Module Split

### Task 6: Create db/ directory with types.ts and migration.ts

**Files:**
- Create: `src/core/db/types.ts`
- Create: `src/core/db/migration.ts`

- [ ] **Step 1: Create `src/core/db/types.ts`**

Extract all interfaces and type aliases from `src/core/db.ts` lines 17-72:
- `ListSessionsOptions`, `FtsMatch`, `FtsSearchResult`, `StatsGroup`, `NoiseFilter`, `SearchFilters`

- [ ] **Step 2: Create `src/core/db/migration.ts`**

Extract:
- `SCHEMA_VERSION` constant
- The entire `private migrate()` method body from the `Database` class (lines 139-539)
- `FTS_VERSION` constant
- Convert to a standalone function: `export function runMigrations(db: BetterSqlite3.Database, getMetadata: ..., setMetadata: ...)`

- [ ] **Step 3: Verify build**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add src/core/db/
git commit -m "refactor(db): extract types.ts and migration.ts"
```

---

### Task 7: Extract session-repo.ts and fts-repo.ts

**Files:**
- Create: `src/core/db/session-repo.ts`
- Create: `src/core/db/fts-repo.ts`

- [ ] **Step 1: Create `src/core/db/session-repo.ts`**

Extract from Database class:
- `upsertSession`, `getSession`, `getSessionByFilePath`, `listSessions`, `listSessionsSince`, `listSessionsAfterCursor`, `deleteSession`, `isIndexed`, `countSessions`, `listSources`, `getSourceStats`, `listProjects`, `updateSessionSummary`, `getFtsContent`
- Standalone functions: `buildTierFilter`, `isTierHidden`, `containsCJK`

All methods become functions receiving `db: BetterSqlite3.Database` as first param.

- [ ] **Step 2: Create `src/core/db/fts-repo.ts`**

Extract:
- `indexSessionContent`, `searchSessions` (the complex FTS query), `replaceFtsContent`
- The CJK-aware search logic

- [ ] **Step 3: Verify build**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add src/core/db/
git commit -m "refactor(db): extract session-repo.ts and fts-repo.ts"
```

---

### Task 8: Extract remaining repos (metrics, jobs, sync, maintenance, aliases)

**Files:**
- Create: `src/core/db/metrics-repo.ts`
- Create: `src/core/db/index-job-repo.ts`
- Create: `src/core/db/sync-repo.ts`
- Create: `src/core/db/maintenance.ts`
- Create: `src/core/db/alias-repo.ts`

- [ ] **Step 1: Create `src/core/db/metrics-repo.ts`**

Extract: `statsGroupBy`, `needsCountBackfill`, `upsertSessionCost`, `getCostsSummary`, `sessionsWithoutCosts`, `upsertSessionFiles`, `getFileActivity`, `upsertSessionTools`, `getToolAnalytics`

- [ ] **Step 2: Create `src/core/db/index-job-repo.ts`**

Extract: `insertIndexJobs`, `takeRecoverableIndexJobs`, `listIndexJobs`, `markIndexJobCompleted`, `markIndexJobNotApplicable`, `markIndexJobRetryableFailure`

Also extract the helper: `buildIndexJobId`

- [ ] **Step 3: Create `src/core/db/sync-repo.ts`**

Extract: `getSyncTime`, `setSyncTime`, `getSyncCursor`, `setSyncCursor`, `getAuthoritativeSnapshot`, `upsertAuthoritativeSnapshot`, `getLocalState`, `setLocalReadablePath`

- [ ] **Step 4: Create `src/core/db/maintenance.ts`**

Extract: `runPostMigrationBackfill`, `backfillTiers`, `backfillScores`, `optimizeFts`, `vacuumIfNeeded`, `deduplicateFilePaths`

- [ ] **Step 5: Create `src/core/db/alias-repo.ts`**

Extract: `resolveProjectAliases`, `addProjectAlias`, `removeProjectAlias`, `listProjectAliases`

- [ ] **Step 6: Verify build**

```bash
npm run build
```

- [ ] **Step 7: Commit**

```bash
git add src/core/db/
git commit -m "refactor(db): extract metrics, jobs, sync, maintenance, alias repos"
```

---

### Task 9: Create Database facade and db.ts shim

**Files:**
- Create: `src/core/db/database.ts`
- Modify: `src/core/db.ts` → replace 1845 lines with ~30-line shim

- [ ] **Step 1: Create `src/core/db/database.ts`**

The `Database` class keeps its constructor, `raw` getter, `setMetrics`, `wrapStatement`, `getMetadata`, `setMetadata`, `close`, and `noiseFilter` property. All other methods delegate to the extracted repo functions:

```ts
import BetterSqlite3 from 'better-sqlite3';
import type { MetricsCollector } from '../metrics.js';
import { runMigrations } from './migration.js';
import * as sessions from './session-repo.js';
import * as fts from './fts-repo.js';
// ... other repo imports

export class Database {
  private db: BetterSqlite3.Database;
  noiseFilter: NoiseFilter = 'hide-skip';
  private metrics?: MetricsCollector;

  get raw(): BetterSqlite3.Database { return this.db; }

  constructor(dbPath: string) {
    this.db = new BetterSqlite3(dbPath);
    this.db.pragma('journal_mode = WAL');
    this.db.pragma('busy_timeout = 5000');
    this.db.pragma('foreign_keys = ON');
    runMigrations(this.db, (k) => this.getMetadata(k), (k, v) => this.setMetadata(k, v));
  }

  // Delegate methods
  upsertSession(session: SessionInfo) { return sessions.upsertSession(this.db, session); }
  getSession(id: string) { return sessions.getSession(this.db, id); }
  // ... all other delegations
}
```

- [ ] **Step 2: Replace `src/core/db.ts` with shim**

```ts
// src/core/db.ts — ESM compatibility shim
// All logic lives in src/core/db/*.ts. This file preserves the import path
// so that `import { Database } from '../core/db.js'` continues to work.

export { Database } from './db/database.js';
export { SCHEMA_VERSION } from './db/migration.js';
export { buildTierFilter, isTierHidden, containsCJK } from './db/session-repo.js';
export type {
  ListSessionsOptions,
  FtsMatch,
  FtsSearchResult,
  StatsGroup,
  NoiseFilter,
  SearchFilters,
} from './db/types.js';
```

- [ ] **Step 3: Verify everything works**

```bash
npm run build
npm test
npm run lint
wc -l src/core/db.ts
wc -l src/core/db/*.ts | sort -n
```

Expected: build clean, 690 tests pass, 0 lint issues, db.ts ~30 lines, no file > 500 lines.

- [ ] **Step 4: Commit**

```bash
git add src/core/db.ts src/core/db/
git commit -m "refactor(db): replace 1845-line God Object with facade + 10 domain modules"
```

---

## Phase 5 (before Phase 3): Semantic Search Degradation UX

### Task 10: Add insights table + FTS

**Files:**
- Modify: `src/core/db/migration.ts`

- [ ] **Step 1: Add insights table DDL to migration**

Add to `runMigrations()`:
```sql
CREATE TABLE IF NOT EXISTS insights (
  id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  wing TEXT,
  room TEXT,
  source_session_id TEXT,
  importance INTEGER DEFAULT 5,
  has_embedding INTEGER DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_insights_wing ON insights(wing);

CREATE VIRTUAL TABLE IF NOT EXISTS insights_fts USING fts5(
  insight_id UNINDEXED,
  content,
  tokenize='trigram case_sensitive 0'
);
```

- [ ] **Step 2: Add DB helper methods for insights**

Add to Database facade: `saveInsightText(id, content, wing, room, importance, sourceSessionId)`, `searchInsightsFts(query, limit)`, `listInsightsByWing(wing, limit)`, `markInsightEmbedded(id)`

- [ ] **Step 3: Verify migration runs**

```bash
npm run build
npm test
```

- [ ] **Step 4: Commit**

```bash
git add src/core/db/
git commit -m "feat(db): add insights table with FTS for text-only insight storage"
```

---

### Task 11: Rewrite save_insight.ts for graceful degradation

**Files:**
- Modify: `src/tools/save_insight.ts`

- [ ] **Step 1: Write failing test for text-only save path**

In `tests/tools/save_insight.test.ts`, add:
```ts
it('saves text-only insight when no embedding deps', async () => {
  const result = await handleSaveInsight(
    { content: 'test insight', wing: 'project-x' },
    { db, log: mockLog },  // no vecStore, no embedder
  );
  expect(result.saved).toBe(true);
  expect(result.warning).toContain('without embedding');
});
```

- [ ] **Step 2: Run test — verify it fails**

```bash
npm test tests/tools/save_insight.test.ts
```

Expected: FAIL (currently throws Error).

- [ ] **Step 3: Implement dual-mode save**

Modify `handleSaveInsight` in `src/tools/save_insight.ts`:
- Add `db: Database` to `SaveInsightDeps`
- If no `vecStore`/`embedder`: save to `insights` table via `db.saveInsightText()`, return `{ saved: true, warning: '...' }`
- If `vecStore`/`embedder` available: existing vector save + ALSO save to `insights` table with `has_embedding = 1`

- [ ] **Step 4: Run test — verify it passes**

```bash
npm test tests/tools/save_insight.test.ts
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tools/save_insight.ts tests/tools/save_insight.test.ts
git commit -m "feat(save_insight): graceful degradation — text-only save when no embedding"
```

---

### Task 12: Update read paths (get_memory, search, get_context) + warnings

**Files:**
- Modify: `src/tools/get_memory.ts`, `src/tools/search.ts`, `src/tools/get_context.ts`

- [ ] **Step 1: Update get_memory.ts — SQL fallback for text-only insights**

When no embedder: instead of returning empty, query `insights` table:
```ts
if (!deps.vecStore || !deps.embedder) {
  // Fallback: SQL query on insights table
  const textInsights = deps.db?.listInsightsByWing(undefined, 10) ?? [];
  return {
    memories: textInsights.map(r => ({ id: r.id, content: r.content, wing: r.wing, room: r.room, importance: r.importance, distance: 0 })),
    message: textInsights.length > 0 ? undefined : 'No memories found...',
    warning: 'No embedding provider — showing recent insights only',
  };
}
```

Also: after vector search, merge in any text-only insights (has_embedding = 0).

- [ ] **Step 2: Update search.ts — add warning on degradation + FTS insight search**

When embed function unavailable and mode is hybrid/semantic:
```ts
warning = 'Embedding provider unavailable — results are keyword-only (FTS)';
```

Additionally, search `insights_fts` for keyword matches on insight content and merge into `insightResults[]`.

- [ ] **Step 3: Update get_context.ts — add warning field**

Add `warning?: string` to return type. When no embedding provider:
```ts
warning: 'No embedding provider configured — context uses keyword match only'
```

When embedding available but insight injection skipped, include SQL fallback:
```ts
const insights = deps.db?.listInsightsByWing(projectName, 5) ?? [];
```

- [ ] **Step 4: Update index.ts tool handler to pass warning through**

Ensure the MCP `CallToolResult` includes warning in the text content when present.

- [ ] **Step 5: Update ServerInfo.instructions with embedding status**

In `src/index.ts`, modify `ENGRAM_INSTRUCTIONS` to be dynamic:
```ts
const embeddingStatus = embeddingClient
  ? `Embedding: ${embeddingClient.model} (${embeddingClient.dimension}d)`
  : 'Embedding: not configured — semantic search disabled';
```

Include in `instructions` field.

- [ ] **Step 6: Verify**

```bash
npm run build
npm test
npm run lint
```

- [ ] **Step 7: Commit**

```bash
git add src/tools/ src/index.ts
git commit -m "feat: add degradation warnings to search/get_memory/get_context + dynamic embedding status"
```

---

### Task 13: Fix flaky hygiene test

**Files:**
- Modify: `tests/core/hygiene.test.ts` (or wherever the flaky test is)

- [ ] **Step 1: Identify the flaky test**

```bash
grep -n "timestamp\|Date.now\|setTimeout" tests/core/hygiene.test.ts | head -20
```

- [ ] **Step 2: Fix with fake timers or relaxed precision**

Use `vi.useFakeTimers()` in the test setup, or relax timestamp assertion to ±2 seconds.

- [ ] **Step 3: Run test 3 times to confirm stability**

```bash
npm test tests/core/hygiene.test.ts
npm test tests/core/hygiene.test.ts
npm test tests/core/hygiene.test.ts
```

Expected: 3/3 pass.

- [ ] **Step 4: Commit**

```bash
git add tests/core/hygiene.test.ts
git commit -m "fix: stabilize flaky hygiene test (timestamp race)"
```

---

## Phase 3: Test Coverage 67% → 75%+

### Task 14: Extract testable factories from daemon.ts and index.ts

**Files:**
- Modify: `src/daemon.ts`
- Modify: `src/index.ts`

- [ ] **Step 1: Extract `createDaemon()` factory from daemon.ts**

Move the body of daemon.ts into:
```ts
export interface DaemonHandle {
  start(): Promise<void>;
  stop(): Promise<void>;
}

export function createDaemon(config: { dbPath: string; settings: FileSettings }): DaemonHandle {
  // ... existing daemon setup logic
}
```

Top-level becomes:
```ts
const handle = createDaemon({ dbPath, settings: readFileSettings() });
handle.start();
```

- [ ] **Step 2: Extract `createMcpServer()` factory from index.ts**

Move tool registration and server setup into:
```ts
export function createMcpServer(config: { dbPath: string; settings: FileSettings }) {
  // ... existing server setup
  return { server, toolRegistry, allTools };
}
```

- [ ] **Step 3: Verify**

```bash
npm run build
npm test
```

- [ ] **Step 4: Commit**

```bash
git add src/daemon.ts src/index.ts
git commit -m "refactor: extract createDaemon/createMcpServer factories for testability"
```

---

### Task 15: Write coverage tests

**Files:**
- Create/Modify: `tests/tools/search.test.ts` (expand)
- Create: `tests/daemon.test.ts`
- Create: `tests/index.test.ts`
- Modify: `tests/tools/save_insight.test.ts` (expand)
- Modify: `tests/core/chunker.test.ts` (expand)

- [ ] **Step 1: Expand search.ts tests**

Add test cases for:
- `mode: 'semantic'` with mock vectorStore + embed
- `mode: 'keyword'` explicit
- `mode: 'hybrid'` RRF fusion
- UUID direct lookup (hit + miss)
- No vectorStore → FTS-only + warning
- CJK query path
- Insight results merged
- `limit` capping at 50
- Short query handling

- [ ] **Step 2: Write daemon factory tests**

```ts
import { createDaemon } from '../src/daemon.js';

describe('createDaemon', () => {
  it('returns handle with start/stop methods', () => {
    // Use temp DB path
    const handle = createDaemon({ dbPath: tmpDbPath, settings: defaultSettings });
    expect(handle.start).toBeTypeOf('function');
    expect(handle.stop).toBeTypeOf('function');
  });
});
```

- [ ] **Step 3: Write MCP server factory tests**

```ts
import { createMcpServer } from '../src/index.js';

describe('createMcpServer', () => {
  it('registers 19 tools', () => {
    const { allTools } = createMcpServer({ dbPath: tmpDbPath, settings: defaultSettings });
    expect(allTools).toHaveLength(19);
  });

  it('toolRegistry has no unknown tool', () => {
    const { toolRegistry } = createMcpServer({ dbPath: tmpDbPath, settings: defaultSettings });
    expect(toolRegistry.get('nonexistent')).toBeUndefined();
  });
});
```

- [ ] **Step 4: Expand save_insight tests**

Add: text-only save, duplicate dedup, importance boundary (0, 5), long text handling.

- [ ] **Step 5: Expand chunker tests**

Add: empty array, single oversized message, CJK content, boundary alignment.

- [ ] **Step 6: Run coverage check**

```bash
npm run test:coverage 2>&1 | grep -E "lines|branches|functions"
```

- [ ] **Step 7: Commit**

```bash
git add tests/
git commit -m "test: expand coverage — search modes, daemon/index factories, insight edge cases"
```

---

### Task 16: Raise coverage thresholds back

**Files:**
- Modify: `vitest.config.ts`

- [ ] **Step 1: Restore and raise thresholds**

```ts
thresholds: {
  lines: 75,
  branches: 70,
  functions: 80,
}
```

- [ ] **Step 2: Verify coverage passes**

```bash
npm run test:coverage 2>&1 | tail -15
```

Expected: All thresholds met.

- [ ] **Step 3: Commit**

```bash
git add vitest.config.ts
git commit -m "chore: restore coverage thresholds — 75% lines, 70% branches, 80% functions"
```

---

## Phase 4: Documentation (parallel with above)

### Task 17: Fix README, SECURITY, PRIVACY + add CONTRIBUTING

**Files:**
- Modify: `README.md`
- Modify: `docs/SECURITY.md`
- Modify: `docs/PRIVACY.md`
- Create: `CONTRIBUTING.md`
- Move: `brainstorm-rag-web-sync.md` → `docs/archive/`

- [ ] **Step 1: Fix README.md**

- Update test count to match `npm test` output
- Update Node version requirement to `>=20`
- Verify adapter count, tool count, source count match code
- Cross-check all other metrics

- [ ] **Step 2: Update SECURITY.md and PRIVACY.md**

- Remove any stale Viking references
- Update network behavior: "Data is local by default. Network calls are made by: peer sync, AI summaries, title generation, and embedding providers — all optional and user-configured."

- [ ] **Step 3: Create CONTRIBUTING.md**

```markdown
# Contributing to Engram

## Prerequisites
- Node.js >= 20
- macOS 14+ (for Swift app)
- Xcode 16+ with xcodegen (`brew install xcodegen`)

## Setup
npm install && npm run build

## Development
npm run dev          # run without compile (tsx)
npm test             # vitest (690+ tests, ~5s)
npm run lint         # biome check
npm run lint:fix     # biome auto-fix

## Swift App
cd macos && xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build

## Commit Convention
We use conventional commits: feat(), fix(), chore(), refactor(), test(), docs()

## Pre-commit
Husky + lint-staged runs biome check on staged .ts files automatically.

## Architecture
See CLAUDE.md for detailed architecture, patterns, and conventions.
```

- [ ] **Step 4: Move brainstorm file**

```bash
mkdir -p docs/archive
git mv brainstorm-rag-web-sync.md docs/archive/
```

- [ ] **Step 5: Commit**

```bash
git add README.md docs/ CONTRIBUTING.md
git commit -m "docs: fix README drift, update security/privacy, add CONTRIBUTING.md"
```

---

### Task 18: Generate MCP Tool API Reference

**Files:**
- Create: `docs/mcp-tools.md`

- [ ] **Step 1: Generate tool reference from code**

Read `src/index.ts` `allTools` array and each tool's `inputSchema`. For each of 19 tools, document: name, description, parameters, example usage.

- [ ] **Step 2: Write `docs/mcp-tools.md`**

Format:
```markdown
# Engram MCP Tools Reference

## search
Full-text and semantic search across all session content.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| query | string | yes | Search keywords (min 2 chars for semantic, 3 for keyword) |
| source | string | no | Filter by source (e.g., claude-code, cursor) |
| ... | | | |

---
## get_context
...
```

- [ ] **Step 3: Commit**

```bash
git add docs/mcp-tools.md
git commit -m "docs: add MCP tool API reference (19 tools)"
```

---

## Final Verification

### Task 19: Full verification pass

- [ ] **Step 1: Run all checks**

```bash
npm run build
npm test
npm run test:coverage
npm run lint
npx knip
npm audit
```

- [ ] **Step 2: Verify file sizes**

```bash
wc -l src/core/db.ts
wc -l src/core/db/*.ts | sort -n
```

Expected: db.ts ~30 lines, no file > 500 lines.

- [ ] **Step 3: Verify doc accuracy**

Spot-check README test count, adapter count, tool count against live code.

- [ ] **Step 4: Final commit if any fixups needed**

```bash
git add -A
git commit -m "chore: final verification pass — all checks green"
```
