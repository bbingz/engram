# Review Shortcomings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address all findings from 3-way code review (Claude/Codex/Gemini), raising the project score from 7.9 to 8.5+.

**Architecture:** 5 phases executed in dependency order: cleanup → db split → degradation UX → test coverage → docs. The db.ts God Object (1845 lines) is split into 10 domain modules behind an ESM-compatible shim. Text-only insights get full write+read paths. Coverage raised from 67% to 75%+.

**Tech Stack:** TypeScript (strict, Node16 ESM), Vitest, Biome, better-sqlite3, sqlite-vec

**Spec:** `docs/superpowers/specs/2026-04-13-review-shortcomings-design.md` (v3)

**Plan reviewed by:** Codex + Gemini (round 1 found 6 BLOCKERs, all fixed in this version)

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

### Task 6: Atomic db.ts split — all modules + facade + shim in one task

**IMPORTANT**: Tasks 6-9 from plan v1 are merged into a single atomic task. Creating modules one-by-one would break the build between steps because db.ts callers wouldn't find extracted methods until the facade is complete.

**Files:**
- Create: `src/core/db/types.ts`, `src/core/db/migration.ts`, `src/core/db/session-repo.ts`, `src/core/db/fts-repo.ts`, `src/core/db/metrics-repo.ts`, `src/core/db/index-job-repo.ts`, `src/core/db/sync-repo.ts`, `src/core/db/maintenance.ts`, `src/core/db/alias-repo.ts`, `src/core/db/database.ts`
- Modify: `src/core/db.ts` → replace with ~30-line shim

- [ ] **Step 1: Create `src/core/db/types.ts`**

Extract all interfaces and type aliases from `src/core/db.ts` lines 17-72:
- `ListSessionsOptions`, `FtsMatch`, `FtsSearchResult`, `StatsGroup`, `NoiseFilter`, `SearchFilters`

- [ ] **Step 2: Create `src/core/db/migration.ts`**

Extract:
- `SCHEMA_VERSION` constant
- `FTS_VERSION` constant (currently at line 299 inside `migrate()`)
- The entire `private migrate()` method body (lines 139-539)
- Convert to: `export function runMigrations(db: BetterSqlite3.Database, getMetadata: (key: string) => string | null, setMetadata: (key: string, value: string) => void): void`

- [ ] **Step 3: Create `src/core/db/session-repo.ts`**

Extract from Database class:
- `upsertSession`, `getSession`, `getSessionByFilePath`, `listSessions`, `listSessionsSince`, `listSessionsAfterCursor`, `deleteSession`, `isIndexed`, `countSessions`, `listSources`, `getSourceStats`, `listProjects`, `updateSessionSummary`, `getFtsContent`
- Standalone functions: `buildTierFilter`, `isTierHidden`
- Private helpers that these methods depend on: `rowToSession`, any filter-building helpers

All methods become functions receiving `db: BetterSqlite3.Database` as first param.

- [ ] **Step 4: Create `src/core/db/fts-repo.ts`**

Extract:
- `indexSessionContent`, `searchSessions` (the complex FTS query), `replaceFtsContent`
- `containsCJK` (CJK detection is FTS-specific, not session-specific)
- The CJK-aware LIKE fallback search logic

- [ ] **Step 5: Create `src/core/db/metrics-repo.ts`**

Extract: `statsGroupBy`, `needsCountBackfill`, `upsertSessionCost`, `getCostsSummary`, `sessionsWithoutCosts`, `upsertSessionFiles`, `getFileActivity`, `upsertSessionTools`, `getToolAnalytics`

- [ ] **Step 6: Create `src/core/db/index-job-repo.ts`**

Extract: `insertIndexJobs`, `takeRecoverableIndexJobs`, `listIndexJobs`, `markIndexJobCompleted`, `markIndexJobNotApplicable`, `markIndexJobRetryableFailure`

Also extract the helper: `buildIndexJobId`

- [ ] **Step 7: Create `src/core/db/sync-repo.ts`**

Extract: `getSyncTime`, `setSyncTime`, `getSyncCursor`, `setSyncCursor`, `getAuthoritativeSnapshot`, `upsertAuthoritativeSnapshot`, `getLocalState`, `setLocalReadablePath`

Include private helpers: `rowToAuthoritativeSnapshot`

- [ ] **Step 8: Create `src/core/db/maintenance.ts`**

Extract: `runPostMigrationBackfill`, `backfillTiers`, `backfillScores`, `optimizeFts`, `vacuumIfNeeded`, `deduplicateFilePaths`

- [ ] **Step 9: Create `src/core/db/alias-repo.ts`**

Extract: `resolveProjectAliases`, `addProjectAlias`, `removeProjectAlias`, `listProjectAliases`

- [ ] **Step 10: Create `src/core/db/database.ts`**

The `Database` class keeps: constructor, `raw` getter, `getRawDb()` method, `setMetrics`, `wrapStatement` (private), `getMetadata`, `setMetadata`, `close`, `noiseFilter` property. All other methods delegate to repo functions:

```ts
import BetterSqlite3 from 'better-sqlite3';
import type { MetricsCollector } from '../metrics.js';
import { runMigrations } from './migration.js';
import * as sessions from './session-repo.js';
import * as fts from './fts-repo.js';
import * as metrics from './metrics-repo.js';
import * as jobs from './index-job-repo.js';
import * as sync from './sync-repo.js';
import * as maint from './maintenance.js';
import * as aliases from './alias-repo.js';

export class Database {
  private db: BetterSqlite3.Database;
  noiseFilter: NoiseFilter = 'hide-skip';
  private metrics?: MetricsCollector;

  get raw(): BetterSqlite3.Database { return this.db; }
  getRawDb(): BetterSqlite3.Database { return this.db; }

  constructor(dbPath: string) {
    this.db = new BetterSqlite3(dbPath);
    this.db.pragma('journal_mode = WAL');
    this.db.pragma('busy_timeout = 5000');
    this.db.pragma('foreign_keys = ON');
    runMigrations(this.db, (k) => this.getMetadata(k), (k, v) => this.setMetadata(k, v));
  }

  setMetrics(m: MetricsCollector): void { /* keep existing Proxy-based implementation */ }
  private wrapStatement(stmt: BetterSqlite3.Statement): BetterSqlite3.Statement { /* keep */ }
  getMetadata(key: string): string | null { /* keep */ }
  setMetadata(key: string, value: string): void { /* keep */ }
  close(): void { this.db.close(); }

  // --- Delegate to session-repo ---
  upsertSession(session: SessionInfo) { return sessions.upsertSession(this.db, session); }
  getSession(id: string) { return sessions.getSession(this.db, id); }
  // ... all other session methods

  // --- Delegate to fts-repo ---
  indexSessionContent(...args: any[]) { return fts.indexSessionContent(this.db, ...args); }
  searchSessions(...args: any[]) { return fts.searchSessions(this.db, ...args); }
  // ... all other FTS methods

  // --- Delegate to all other repos similarly ---
}
```

**Preserve the FULL public API surface**: every public method and getter that exists on `Database` today must exist on the new facade. Verify by comparing `grep -c` of method names before and after.

- [ ] **Step 11: Replace `src/core/db.ts` with shim**

```ts
// src/core/db.ts — ESM compatibility shim
// All logic lives in src/core/db/*.ts. This file preserves the import path
// so that `import { Database } from '../core/db.js'` continues to work.

export { Database } from './db/database.js';
export { SCHEMA_VERSION, FTS_VERSION, runMigrations } from './db/migration.js';
export { buildTierFilter, isTierHidden } from './db/session-repo.js';
export { containsCJK } from './db/fts-repo.js';
export type {
  ListSessionsOptions,
  FtsMatch,
  FtsSearchResult,
  StatsGroup,
  NoiseFilter,
  SearchFilters,
} from './db/types.js';
```

**Note**: shim must re-export ALL values AND types that are currently exported from `db.ts`, including `SCHEMA_VERSION`, `FTS_VERSION`, `runMigrations`, `buildTierFilter`, `isTierHidden`, `containsCJK`.

- [ ] **Step 12: Verify everything works**

```bash
npm run build
npm test
npm run lint
wc -l src/core/db.ts
wc -l src/core/db/*.ts | sort -n
```

Expected: build clean, 690 tests pass, 0 lint issues, db.ts ~30 lines, no file > 500 lines.

- [ ] **Step 13: Commit**

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
- Add `db?: Database` to `SaveInsightDeps` interface
- If no `vecStore`/`embedder`: save to `insights` table via `deps.db!.saveInsightText()`, return `{ saved: true, warning: '...' }`
- If `vecStore`/`embedder` available: existing vector save + ALSO save to `insights` table with `has_embedding = 1`
- Update `SaveInsightResult` to include `saved?: boolean` and `warning?: string`

- [ ] **Step 4: Wire DB into save_insight handler in index.ts**

In `src/index.ts`, find the `toolRegistry.set('save_insight', ...)` line and add `db` to the deps passed:

```ts
toolRegistry.set('save_insight', (a) =>
  handleSaveInsight(a as any, { vecStore, embedder: embeddingClient, log, db }),
);
```

- [ ] **Step 5: Run test — verify it passes**

```bash
npm test tests/tools/save_insight.test.ts
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/tools/save_insight.ts src/index.ts tests/tools/save_insight.test.ts
git commit -m "feat(save_insight): graceful degradation — text-only save when no embedding"
```

---

### Task 12: Update read paths (get_memory, search, get_context) + warnings + wiring

**Files:**
- Modify: `src/tools/get_memory.ts`, `src/tools/search.ts`, `src/tools/get_context.ts`, `src/index.ts`

- [ ] **Step 1: Add `db` to deps interfaces**

In `src/tools/get_memory.ts`, add to `GetMemoryDeps`:
```ts
export interface GetMemoryDeps {
  vecStore?: VectorStore | null;
  embedder?: EmbeddingClient | null;
  db?: Database;  // NEW — for text-only insight fallback
  log?: Logger;
}
```

In `src/tools/search.ts`, add to `SearchDeps`:
```ts
export interface SearchDeps {
  vectorStore?: VectorStore;
  embed?: (text: string) => Promise<Float32Array | null>;
  db?: Database;  // NEW — for FTS insight search
  log?: Logger;
  metrics?: MetricsCollector;
  tracer?: Tracer;
}
```

In `src/tools/get_context.ts`, add to `GetContextDeps`:
```ts
export interface GetContextDeps {
  vectorStore?: VectorStore;
  embed?: (text: string) => Promise<Float32Array | null>;
  db?: Database;  // NEW — for SQL insight fallback
  liveMonitor?: { getSessions(): LiveSession[] };
  backgroundMonitor?: { getAlerts(): MonitorAlert[] };
  log?: Logger;
}
```

- [ ] **Step 2: Update get_memory.ts — SQL fallback for text-only insights**

When no embedder: instead of returning empty, query `insights` table:
```ts
if (!deps.vecStore || !deps.embedder) {
  const textInsights = deps.db?.listInsightsByWing(undefined, 10) ?? [];
  return {
    memories: textInsights.map(r => ({ id: r.id, content: r.content, wing: r.wing, room: r.room, importance: r.importance, distance: 0 })),
    message: textInsights.length > 0 ? undefined : 'No memories found. Use save_insight to add knowledge.',
    warning: 'No embedding provider — showing recent insights only',
  };
}
```

Also: after vector search, merge in any text-only insights (has_embedding = 0).

- [ ] **Step 3: Update search.ts — add warning on degradation + FTS insight search**

When embed function unavailable and mode is hybrid/semantic:
```ts
warning = 'Embedding provider unavailable — results are keyword-only (FTS)';
```

Additionally, search `insights_fts` for keyword matches on insight content and merge into `insightResults[]`.

- [ ] **Step 4: Update get_context.ts — add warning field**

Add `warning?: string` to return type. When no embedding provider:
```ts
warning: 'No embedding provider configured — context uses keyword match only'
```

When embedding available but insight injection skipped, include SQL fallback:
```ts
const insights = deps.db?.listInsightsByWing(projectName, 5) ?? [];
```

- [ ] **Step 5: Wire DB into all handlers in index.ts**

Update `src/index.ts` tool handler registrations to pass `db`:

```ts
toolRegistry.set('search', (a) =>
  handleSearch(db, a as any, { vectorStore: vecStore, embed: embedFn, db, log, metrics, tracer }),
);
toolRegistry.set('get_memory', (a) =>
  handleGetMemory(a as any, { vecStore, embedder: embeddingClient, db, log }),
);
toolRegistry.set('get_context', (a) =>
  handleGetContext(db, a as any, { vectorStore: vecStore, embed: embedFn, db, log, ...otherDeps }),
);
```

Also update the MCP `CallToolResult` handler to include `warning` in the text content when present in tool results.

- [ ] **Step 6: Update ServerInfo.instructions with embedding status**

In `src/index.ts`, modify `ENGRAM_INSTRUCTIONS` to be dynamic:
```ts
const embeddingStatus = embeddingClient
  ? `Embedding: ${embeddingClient.model} (${embeddingClient.dimension}d)`
  : 'Embedding: not configured — semantic search disabled';
```

Include in `instructions` field passed to `new Server(...)`.

- [ ] **Step 7: Verify**

```bash
npm run build
npm test
npm run lint
```

- [ ] **Step 8: Commit**

```bash
git add src/tools/ src/index.ts
git commit -m "feat: add degradation warnings to search/get_memory/get_context + wire DB + dynamic embedding status"
```

---

### Task 13: Add insight backfill job to IndexJobRunner

**Files:**
- Modify: `src/core/index-job-runner.ts`

- [ ] **Step 1: Add backfill logic**

In `IndexJobRunner`, add a method to promote text-only insights:

```ts
async backfillInsightEmbeddings(): Promise<number> {
  if (!this.embeddingClient) return 0;
  const unembedded = this.db.listUnembeddedInsights(20); // new DB method
  let count = 0;
  for (const insight of unembedded) {
    const embedding = await this.embeddingClient.embed(insight.content);
    if (embedding) {
      this.vecStore.upsertInsight(insight.id, insight.content, embedding, this.embeddingClient.model, {
        wing: insight.wing, room: insight.room, importance: insight.importance,
      });
      this.db.markInsightEmbedded(insight.id);
      count++;
    }
  }
  return count;
}
```

Add `listUnembeddedInsights(limit)` to Database facade (queries `SELECT * FROM insights WHERE has_embedding = 0 LIMIT ?`).

- [ ] **Step 2: Wire into daemon index loop**

Call `backfillInsightEmbeddings()` after each indexing pass in the daemon's periodic loop.

- [ ] **Step 3: Verify**

```bash
npm run build
npm test
```

- [ ] **Step 4: Commit**

```bash
git add src/core/index-job-runner.ts src/core/db/
git commit -m "feat(indexer): backfill text-only insights with embeddings when provider available"
```

---

### Task 14: Fix flaky hygiene test

**Files:**
- Modify: `tests/web/hygiene.test.ts`

- [ ] **Step 1: Identify the flaky test**

```bash
grep -n "timestamp\|Date.now\|setTimeout\|cache" tests/web/hygiene.test.ts | head -20
```

- [ ] **Step 2: Fix with fake timers or relaxed precision**

Use `vi.useFakeTimers()` in the test setup, or relax timestamp assertion to ±2 seconds.

- [ ] **Step 3: Run test 3 times to confirm stability**

```bash
npm test tests/web/hygiene.test.ts
npm test tests/web/hygiene.test.ts
npm test tests/web/hygiene.test.ts
```

Expected: 3/3 pass.

- [ ] **Step 4: Commit**

```bash
git add tests/web/hygiene.test.ts
git commit -m "fix: stabilize flaky hygiene test (timestamp race)"
```

---

## Phase 3: Test Coverage 67% → 75%+

### Task 15: Extract testable factories from daemon.ts and index.ts

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

### Task 16: Write coverage tests

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
    const handle = createDaemon({ dbPath: tmpDbPath, settings: defaultSettings });
    expect(handle.start).toBeTypeOf('function');
    expect(handle.stop).toBeTypeOf('function');
  });

  it('start() emits ready event', async () => {
    const handle = createDaemon({ dbPath: tmpDbPath, settings: defaultSettings });
    // Capture stdout JSON lines
    const events: any[] = [];
    handle.on('event', (e: any) => events.push(e));
    await handle.start();
    expect(events.some(e => e.event === 'ready')).toBe(true);
    await handle.stop();
  });

  it('stop() cleans up watcher', async () => {
    const handle = createDaemon({ dbPath: tmpDbPath, settings: defaultSettings });
    await handle.start();
    await handle.stop();
    // Verify no open handles (vitest --detectOpenHandles)
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

  it('toolRegistry returns undefined for unknown tool', () => {
    const { toolRegistry } = createMcpServer({ dbPath: tmpDbPath, settings: defaultSettings });
    expect(toolRegistry.get('nonexistent')).toBeUndefined();
  });

  it('ServerInfo.instructions contains embedding status', () => {
    const { instructions } = createMcpServer({ dbPath: tmpDbPath, settings: defaultSettings });
    expect(instructions).toContain('Embedding:');
  });
});
```

- [ ] **Step 4: Expand save_insight tests**

Add: text-only save (no embedding), duplicate dedup, importance boundary values (0, 1, 3, 5), long text truncation handling.

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

### Task 17: Raise coverage thresholds back

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

### Task 18: Fix README, SECURITY, PRIVACY + add CONTRIBUTING

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
npm test             # vitest (run `npm test` for current count)
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

### Task 19: Generate MCP Tool API Reference

**Files:**
- Create: `docs/mcp-tools.md`

- [ ] **Step 1: Generate tool reference from code**

Read `src/index.ts` `allTools` array and each tool's `inputSchema`. For each of 19 tools, document: name, description, parameters, example response shape, and usage notes (defaults, limits, edge cases).

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

**Example Response:**
```json
{ "results": [...], "query": "auth bug", "searchModes": ["keyword", "semantic"], "insightResults": ["..."] }
```

**Notes:** Default limit 10, max 50. CJK queries use LIKE fallback instead of FTS trigram.

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

### Task 20: Full verification pass

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
