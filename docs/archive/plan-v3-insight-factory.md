# Implementation Plan v3.1: Insight Hardening + Factory Extraction

**Date**: 2026-04-13 (revised after Codex + Gemini 3-way review)
**Scope**: 2 workstreams, 10 tasks
**Branch**: `insight-hardening-factory`

## Review Findings Applied

Codex (10F/2P) + Gemini (5F/7P) identified:
- A2: exact-match dedup too brittle → use normalized text comparison
- A3: wrong line refs, hardcoded `?? 3` in insight-repo.ts:44 + vector-store.ts:437
- A4: `upsertInsight` already accepts `sourceSessionId` — just not passed by save_insight
- A5: database.ts facade shouldn't depend on vector-store → handle in tool/service layer
- B1: `bootstrap.ts` already centralizes shared init → extend, don't duplicate
- B2: tool registry already Map-based → **DROPPED** (already done)
- B5: entry point target sizes too aggressive → realistic targets

---

## Workstream A: Insight Pipeline Hardening (7 tasks)

### A1. Input Validation for save_insight

**File**: `src/tools/save_insight.ts`

**Changes** — add validation at line 67 (before `const id = randomUUID()`):
```typescript
const trimmed = params.content.trim();
if (!trimmed) return error('Content cannot be empty');
if (trimmed.length < 10) return error('Content too short (min 10 chars)');
if (trimmed.length > 50_000) return error('Content too long (max 50KB)');
params.content = trimmed;  // use trimmed version downstream
```
- Also trim `wing` and `room`, max 200 chars each

**Tests**: empty, whitespace-only, <10 chars, >50KB, normal — 5 cases

### A2. Text-Only Insight Dedup via Normalized Comparison

**File**: `src/tools/save_insight.ts` (text-only path, lines 76-98)
**File**: `src/core/db/insight-repo.ts`

**Changes**:
1. In `insight-repo.ts`, add:
   ```typescript
   export function findDuplicateInsight(
     db: BetterSqlite3.Database,
     content: string,
     wing?: string,
   ): InsightRow | null
   ```
   - Normalize: lowercase, collapse whitespace, trim
   - Query: `SELECT * FROM insights WHERE wing IS @wing` then compare normalized content in JS
   - Scope: same `wing` only (different wings = different context)
2. In `save_insight.ts` text-only path: call before save, return warning if found

**Tests**: same content twice → dedup; different casing → dedup; different wing → both saved

### A3. Fix importance Default Alignment

**Files**: `src/core/db/insight-repo.ts:44`, `src/core/vector-store.ts:437`, `src/tools/save_insight.ts:30,73`

**Problem**: Three places hardcode default importance:
- `insight-repo.ts:44` → `importance ?? 3`
- `vector-store.ts:437` → `opts?.importance ?? 3`
- `save_insight.ts:30` → schema description says "default: 3"
- `migration.ts:406` → schema says `DEFAULT 5`

**Changes**:
- Schema is authoritative: align all to `5`
- `insight-repo.ts:44` → `importance ?? 5`
- `vector-store.ts:437` → `opts?.importance ?? 5`
- `save_insight.ts:73` → `params.importance ?? 5`
- `save_insight.ts:30` → update description to "default: 5"
- Export `DEFAULT_IMPORTANCE = 5` from `insight-repo.ts`, import elsewhere

**Tests**: Update existing tests that assert on default=3 → expect 5

### A4. Pass sourceSessionId to Both Stores

**File**: `src/tools/save_insight.ts` (lines 82-88 and 136-146)

**Problem**: `upsertInsight` at vector-store.ts:55 already accepts `sourceSessionId`, but `handleSaveInsight` never passes it. The MCP schema also lacks this field.

**Changes**:
1. Add optional `source_session_id` to `handleSaveInsight` params interface
2. Pass it through to `vecStore.upsertInsight(...)` opts (line 141-145)
3. Pass it through to `db.saveInsightText(...)` (lines 82-88 and 150-156)
4. In `index.ts` toolRegistry.set for `save_insight`: pass session context if available from request

**Tests**: Save with sourceSessionId → verify in both tables

### A5. Fix Delete Asymmetry (Service-Layer Pattern)

**Problem**: `vecStore.deleteInsight()` only deletes from `memory_insights` + `vec_insights`. No deletion from `insights` table.

**File**: `src/core/db/insight-repo.ts` — add `deleteInsightText()`
**File**: `src/tools/save_insight.ts` or new `src/tools/delete_insight.ts` — coordinate both deletes

**Changes** (NOT in database.ts facade — avoid coupling):
1. Add to `insight-repo.ts`:
   ```typescript
   export function deleteInsightText(db: BetterSqlite3.Database, id: string): void
   ```
   Deletes from `insights` + `insights_fts`
2. Any delete operation (future tool or daemon) calls both:
   - `insightRepo.deleteInsightText(db, id)`
   - `vecStore?.deleteInsight(id)` (if available)

**Tests**: Delete → verify both tables empty

### A6. Insight Reconciliation in Daemon Maintenance

**File**: `src/core/db/maintenance.ts`

**Changes** — add `reconcileInsights(db, vecStore?)`:
- `has_embedding=1` but no `memory_insights` row → set `has_embedding=0`
- `memory_insights` row with no `insights` row → soft-delete
- Call from daemon startup maintenance (after VACUUM/optimize)
- Log reconciliation counts

**Tests**: Create divergent state → reconcile → verify

### A7. Integration Test for Insight Lifecycle

**File**: `tests/tools/save_insight.test.ts`

- Save → retrieve → delete → verify both stores empty
- Save with embedding → fallback to FTS retrieval
- Dedup in both modes

---

## Workstream B: Factory Extraction for Testability (3 tasks)

> **B2 (tool registry) DROPPED** — already Map-based at index.ts:193

### B1. Extend bootstrap.ts + Extract MCP Init

**File**: `src/core/bootstrap.ts` (extend existing)
**File**: `src/index.ts`

**Problem**: `bootstrap.ts` already has `createAdapters()` and `initVectorDeps()`. Index.ts still has ~50 lines of inline db/tracer/settings/indexer init.

**Changes**:
```typescript
// Add to bootstrap.ts:
export interface MCPDeps {
  db: Database;
  adapters: SessionAdapter[];
  adapterMap: Map<string, SessionAdapter>;
  tracer: Tracer;
  settings: FileSettings;
  indexer: Indexer;
  audit: AiAuditWriter;
  vecDeps: VectorDeps | null;
  indexJobRunner: IndexJobRunner;
}

export async function createMCPDeps(opts?: { dbPath?: string }): Promise<MCPDeps>
```
- Move index.ts lines 50-99 into `createMCPDeps()`
- index.ts becomes: `const deps = await createMCPDeps(); /* register tools, connect transport */`

**Tests**: `tests/core/bootstrap.test.ts` — `createMCPDeps({ dbPath: ':memory:' })` returns valid deps

### B3. Extract Daemon Core + Indexing Factories

**File**: `src/core/bootstrap.ts` (extend)
**File**: `src/daemon.ts`

**Changes**:
```typescript
export interface DaemonCoreDeps extends MCPDeps {
  log: Logger;
  metrics: MetricsCollector;
  auditQuery: AiAuditQuery;
}

export async function createDaemonDeps(opts?: { dbPath?: string }): Promise<DaemonCoreDeps>
```
- Move daemon.ts lines 60-96 (db, adapters, settings, observability, audit) into factory
- daemon.ts keeps: timers, watcher, web server, shutdown — these are orchestration, not initialization

**Tests**: `createDaemonDeps({ dbPath: ':memory:' })` returns valid deps

### B4. Extract Shutdown Handler

**File**: `src/core/bootstrap.ts` (add)

**Changes**:
```typescript
export interface ShutdownResources {
  timers: NodeJS.Timeout[];
  watcher?: { close: () => void };
  webServer?: { close: () => void };
  db: Database;
  metrics?: MetricsCollector;
  liveMonitor?: { stop: () => void };
  backgroundMonitor?: { stop: () => void };
  usageCollector?: { shutdown: () => Promise<void> };
  autoSummary?: { shutdown: () => void };
}

export function createShutdownHandler(resources: ShutdownResources): () => Promise<void>
```

**Tests**: Mock resources → call shutdown → verify all cleared

---

## Execution Order

1. **A1** (validation) — standalone
2. **A3** (importance alignment) — standalone
3. **A4** (sourceSessionId) — standalone
4. **A2** (text-only dedup) — after A1
5. **A5** (delete fix) — standalone
6. **A6** (reconciliation) — after A5
7. **A7** (integration tests) — after A1-A6
8. **B1** (extend bootstrap + MCP factory) — standalone
9. **B3** (daemon factory) — after B1
10. **B4** (shutdown handler) — after B3

## Success Criteria

- [ ] `npm test` passes with ≥ 780 tests
- [ ] `npm run lint` clean
- [ ] `npm run build` clean
- [ ] MCP `save_insight` rejects empty/long content
- [ ] Default importance = 5 everywhere
- [ ] Text-only dedup prevents identical saves
- [ ] Both tables consistent on save and delete
