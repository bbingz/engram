# Three-Way Review Shortcomings — Design Spec (v2)

**Date**: 2026-04-13
**Branch**: TBD (will be created from `main`)
**Reviewers**: Claude + Codex + Gemini (3-way, 2 rounds)
**Origin**: Independent 10-dimension project evaluation (consensus score: 7.9/10)

---

## Context

Three independent AI reviewers evaluated the Engram codebase. The design spec v1 was then reviewed by all three and received **2 FAIL** verdicts with multiple BLOCKERs. This v2 incorporates all corrections.

### Key v1 → v2 Changes

| Issue | v1 (wrong) | v2 (corrected) |
|-------|-----------|----------------|
| ESM resolution | `db.js` auto-resolves to `db/index.js` | **No.** Keep `src/core/db.ts` as shim re-exporting from `db/` modules |
| Knip type count | ~20 unused exported types | **54** unused exported types |
| Knip "unused files" | Delete if zero imports | 4 files include `daemon.ts` — **entrypoint false positives**, not dead code |
| db.ts split scope | CRUD/FTS/metrics/jobs only | **Missing**: sync cursors, local state, project aliases, observability, maintenance, score backfills |
| Coverage threshold | "needs to be added" | **Already exists** (lines: 75, branches: 65, functions: 70) and already failing (67.4%) |
| "No network calls" | Unless embedding configured | **Wrong.** Sync, AI summaries, title generation also make network calls |
| index.ts toolRegistry | "Leave to next round" | **Already exists** at line 192 |
| save_insight without embedding | Graceful save | **Currently hard-fails** with thrown Error — needs contract change |
| Phase 3/5 ordering | Test fallback, then add warnings | **Warning logic must exist before tests target it** |

---

## Phase 1: Dead Code Cleanup + Type Safety (P2)

### Goal
Eliminate knip findings, tighten Biome rules, clean start for Phase 2.

### 1.1 Unused Exported Types (54)

Three buckets:

**Bucket A — Delete** (truly dead, no test/runtime reference):
- Grep each type across `src/` and `tests/`; if zero hits outside its own definition, delete

**Bucket B — Test-only exports** (knip doesn't scan `tests/`):
- Types referenced in test files → keep, add to knip `ignoreExportsUsedInFile` or `entry` config

**Bucket C — Public API surface** (intentional exports for MCP consumers):
- Types like `SearchResult`, `NoiseFilter`, `EmbeddingProvider` → keep, add knip ignore annotation

### 1.2 Unused Files (4) — Entrypoint False Positives

Knip reports:
- `src/daemon.ts` — **real runtime entrypoint** (launched by macOS app). Add to knip `entry` config
- `src/core/git-probe.ts` — verify if used by daemon or scripts. If unused, delete
- `src/adapters/claude-usage-probe.ts` — verify usage. If unused, delete
- `src/adapters/codex-usage-probe.ts` — verify usage. If unused, delete

Strategy: `grep -r` each filename across codebase + check `package.json` scripts + check macOS build scripts. Do NOT blindly delete.

### 1.3 Unused Dependencies

- Remove `js-yaml` — confirmed zero imports in `src/`
- Remove `@types/js-yaml` — dev dependency of above

### 1.4 Biome Rule Changes

```jsonc
"suspicious": {
  "noExplicitAny": "warn",  // was "off" → warn first
  "noControlCharactersInRegex": "off",  // keep
  "noAssignInExpressions": "off"  // keep
},
"style": {
  "noNonNullAssertion": "off"  // keep (too risky to change now)
}
```

Fix quick-win `any` usages. Leave complex ones with `// biome-ignore lint/suspicious/noExplicitAny: <reason>`.

### 1.5 Knip Configuration

The CI knip job already exists in `.github/workflows/test.yml` (line 26) and exits non-zero on findings. After cleanup, verify CI passes.

### 1.6 Coverage Threshold — Temporary Lower

Current state: coverage 67.4% < threshold 75% → `test:coverage` **already failing**. To unblock CI during Phases 1-2:

```ts
// vitest.config.ts — temporarily lower while we build coverage
thresholds: {
  lines: 65,       // was 75 → temp lower
  branches: 60,    // was 65 → temp lower
  functions: 70,   // keep
}
```

Phase 3 will raise these back (and higher).

### Verification
- `npm run lint` — 0 issues (including new `noExplicitAny` warnings addressed)
- `npx knip` — 0 findings
- `npm test` — all tests pass
- `npm run test:coverage` — passes (with temporarily lowered thresholds)

---

## Phase 2: db.ts Module Split (P0)

### Goal
Split 1845-line `db.ts` into domain modules. External interface unchanged.

### ESM Compatibility Strategy

**BLOCKER from v1**: Node16 ESM does NOT resolve `../core/db.js` to `../core/db/index.js`.

**Solution**: Keep `src/core/db.ts` as a thin **shim file** that re-exports everything from internal modules. All existing `import { ... } from '../core/db.js'` paths remain valid. Zero import changes needed.

```ts
// src/core/db.ts (shim — ~30 lines)
export { Database } from './db/database.js';
export { runMigrations, SCHEMA_VERSION, FTS_VERSION } from './db/migration.js';
export { buildTierFilter, isTierHidden } from './db/session-repo.js';
export type { ListSessionsOptions, FtsMatch, FtsSearchResult, StatsGroup, NoiseFilter, SearchFilters } from './db/types.js';
// ... all other re-exports
```

### Directory Structure

```
src/core/
  db.ts               (~30 lines)  — shim: re-exports everything, preserves import path
  db/
    types.ts           (~120 lines) — all shared interfaces and type aliases
    migration.ts       (~200 lines) — migrate(), DDL, SCHEMA_VERSION, FTS_VERSION
    session-repo.ts    (~400 lines) — session CRUD, list, messages, tier filter functions
    fts-repo.ts        (~200 lines) — FTS index/deindex/reindex, search, CJK detection
    metrics-repo.ts    (~150 lines) — stats queries, cost queries, AI audit queries
    index-job-repo.ts  (~150 lines) — job queue CRUD, status transitions
    sync-repo.ts       (~150 lines) — sync cursors, snapshots, local state
    maintenance.ts     (~150 lines) — VACUUM, FTS optimize, dedup, score backfills
    alias-repo.ts      (~100 lines) — project alias CRUD
    database.ts        (~250 lines) — Database facade class, delegates to repos
```

### Full Responsibility Map (v1 was incomplete)

| Responsibility | v1 coverage | v2 target file |
|---------------|:-----------:|----------------|
| Schema migration + DDL | Yes | `migration.ts` |
| Session CRUD + list | Yes | `session-repo.ts` |
| Tier filtering (`buildTierFilter`, `isTierHidden`) | Partial | `session-repo.ts` |
| FTS index/search/CJK | Yes | `fts-repo.ts` |
| Stats/cost/AI audit queries | Yes | `metrics-repo.ts` |
| Index job queue | Yes | `index-job-repo.ts` |
| Sync cursors + snapshots + local state | **Missing** | `sync-repo.ts` |
| VACUUM, FTS optimize, dedup, score backfills | **Missing** | `maintenance.ts` |
| Project alias CRUD | **Missing** | `alias-repo.ts` |
| Shared types/interfaces | Implicit | `types.ts` |
| Database facade | Yes | `database.ts` |

### Architecture

```
Callers import from '../core/db.js' (unchanged)
            │
            ▼
    src/core/db.ts (shim — re-exports)
            │
            ▼
    src/core/db/database.ts (facade)
      ├── session-repo.ts
      ├── fts-repo.ts
      ├── metrics-repo.ts
      ├── index-job-repo.ts
      ├── sync-repo.ts
      ├── maintenance.ts
      ├── alias-repo.ts
      └── migration.ts
            │
    All repos receive raw BetterSqlite3.Database
    No circular dependency on Database facade
```

### Key Constraints

1. **Shim preserves import path** — `src/core/db.ts` re-exports all values AND types
2. **Re-exports include values** (`buildTierFilter`, `isTierHidden`, `containsCJK`, `SCHEMA_VERSION`) — not just types
3. **Repos receive raw `BetterSqlite3.Database`** — no dependency on facade
4. **Database class public API unchanged** — all method signatures preserved
5. **No behavior changes** — pure structural refactor
6. **No file > 500 lines** after split

### Verification
- `npm test` — all tests pass (zero test file changes expected)
- `npm run build` — 0 errors
- `npm run lint` — 0 issues
- `wc -l src/core/db.ts` — ~30 lines (shim only)
- `wc -l src/core/db/*.ts` — no file > 500 lines

---

## Phase 3: Test Coverage 67% → 75%+ (P1)

### Goal
Line coverage ≥ 75%, branch ≥ 70%, functions ≥ 80%.

### Prerequisite: Testability Extraction

`daemon.ts` and `index.ts` are top-level executables with immediate side effects. They cannot be smoke-tested directly. Before writing tests:

1. **Extract `createDaemon()` factory** from `daemon.ts` — accepts config/deps, returns handle. Top-level code becomes `createDaemon(loadConfig()).start()`.
2. **Extract `createMcpServer()` factory** from `index.ts` — accepts config/deps/transport, returns server. Top-level code becomes `createMcpServer(loadConfig()).connect()`.

This enables testing without process-level side effects.

### 3.1 search.ts (branch 32% → 70%+)

New test cases:
- `mode: 'semantic'` with mock vectorStore + embed function
- `mode: 'keyword'` explicit keyword-only path
- `mode: 'hybrid'` with both backends → RRF fusion verification
- UUID direct lookup (valid UUID, non-existent UUID)
- No vectorStore/embed provided → FTS-only fallback **+ warning field** (coordinate with Phase 5)
- CJK query → FTS trigram path
- Insight results merged into response
- `limit` capping at 50
- Empty query / short query handling

### 3.2 daemon.ts (0% → smoke tests via factory)

- `createDaemon()` with mock DB → returns handle with expected methods
- `handle.start()` → emits `ready` event
- `handle.stop()` → cleans up watcher
- Indexer progress events

### 3.3 index.ts (0% → MCP server tests via factory)

- `createMcpServer()` → registers 19 tools
- `toolRegistry.get('unknown')` → undefined
- `ServerInfo.instructions` contains embedding status
- Note: input validation is handled by MCP SDK, not local code — don't test what we don't own

### 3.4 Existing Test Expansion

**save_insight.ts** additions:
- No embedding deps provided → error (current behavior) OR graceful save (if Phase 5 changes contract)
- Duplicate insight → semantic dedup
- Text exceeding max length → truncation
- `importance` boundary values (0, 1, 5, 10)

**chunker.ts** additions:
- Empty message array → empty chunks
- Single message exceeding chunk size → split at boundary
- CJK content chunking
- Message boundary alignment

### 3.5 Coverage Thresholds — Raise Back

After tests are written, restore and raise thresholds:

```ts
// vitest.config.ts
thresholds: {
  lines: 75,       // restore from temp 65
  branches: 70,    // raise from temp 60
  functions: 80,   // raise from 70
}
```

### 3.6 Flaky Test Fix

`hygiene.test.ts` timestamp race → `vi.useFakeTimers()` or ±2s tolerance.

### Phase 3 ↔ Phase 5 Coordination

Tests for warning/degradation paths (search fallback warning, save_insight graceful save) **must be written after Phase 5 implements the warning logic**. Execution order within the branch:
1. Phase 5 code changes (add warnings)
2. Phase 3 tests (test the warnings)

### Verification
- `npm run test:coverage` — passes raised thresholds
- No flaky tests on 3 consecutive runs

---

## Phase 4: Documentation Fix + Additions (P3)

### Goal
Fix drift, fill gaps.

### 4.1 README.md Corrections

- Test count: "278 tests" → current count (from `npm test` output)
- Verify adapter count, tool count, source count match code
- Cross-check all metrics with live codebase

### 4.2 SECURITY.md / PRIVACY.md

Files exist (2.2K / 2.6K). Actions:
- Remove any stale Viking/external service references
- Update network behavior description: data is local by default, but **sync, AI summaries, title generation, and embedding providers** can make network calls when configured
- Do NOT claim "no network calls" — that's factually wrong

### 4.3 MCP Tool API Reference

New file: `docs/mcp-tools.md`

Generated from code — for each of 19 tools:
- Name, description, parameters, example response, notes

### 4.4 Root Directory Cleanup

- `brainstorm-rag-web-sync.md` → `docs/archive/` or delete

### 4.5 CONTRIBUTING.md

Short guide (~50 lines): prerequisites, setup, dev workflow, commit conventions, pointer to CLAUDE.md.

### Verification
- All doc references match actual code state

---

## Phase 5: Semantic Search Degradation UX (P4)

### Goal
Users know when semantic search is unavailable.

**IMPORTANT**: Phase 5 code changes are implemented BEFORE Phase 3 tests that target warning paths.

### 5.1 search.ts Warning

When `mode: 'hybrid'` or `mode: 'semantic'` but embed unavailable/fails:
```ts
return {
  results,
  query: params.query,
  searchModes, // will only contain 'keyword'
  warning: 'Embedding provider unavailable — results are keyword-only (FTS)',
};
```

`warning` field already exists in the return type — just needs to be populated on this path.

### 5.2 get_context.ts Warning

Current return shape: `{ contextText, sessionCount, sessionIds }`. Need to add `warning?` field:

```ts
// get_context.ts return type change
interface GetContextResult {
  contextText: string;
  sessionCount: number;
  sessionIds: string[];
  warning?: string;  // NEW
}
```

When insight injection skipped: `warning: 'No embedding provider configured — context uses keyword match only'`

Note: `index.ts` tool handler serializes this to MCP text content — ensure `warning` is included in output.

### 5.3 save_insight.ts — Contract Decision

**Current behavior**: `handleSaveInsight` throws `Error('Insight storage requires embedding support...')` when no `vecStore` or `embedder`.

**Design decision**: Change to graceful degradation.
- Save insight text + metadata to a new `insights` table in SQLite (not `vec_insights` which requires embeddings)
- FTS-index the text so keyword search finds it
- Return `{ saved: true, warning: 'Insight saved without embedding — semantic search will not find it until an embedding provider is configured' }`
- When embedding becomes available, background job can backfill vectors

This requires:
1. New `insights` table in `migration.ts` (text, wing, room, importance, created_at)
2. FTS entry for insight content
3. `save_insight.ts` dual path: with embedding → full save; without → text-only save

### 5.4 ServerInfo.instructions Dynamic Status

`index.ts` already builds `instructions` string. Add embedding status line:
- `"Embedding: ollama (nomic-embed-text, 768d)"` — when provider active
- `"Embedding: not configured — semantic search disabled"` — when no provider

### 5.5 Flaky Test Fix

`hygiene.test.ts` timestamp race → `vi.useFakeTimers()` or ±2s tolerance.

### Verification
- All warning paths have corresponding tests (written in Phase 3, after this phase)
- `npm test` — all pass, no flaky
- Manual: start MCP server without Ollama → `search` tool returns warning

---

## Execution Order (Revised)

```
Phase 1 (cleanup) ──→ Phase 2 (split db.ts) ──→ Phase 5 (warnings) ──→ Phase 3 (tests) 
                                                                              │
Phase 4 (docs) ─────────────────────────── independent, parallel with any ────┘
```

| Phase | Content | Est. Files | Depends On |
|:-----:|---------|:----------:|:----------:|
| 1 | Dead code cleanup + type safety + temp lower coverage gate | ~15 | — |
| 2 | db.ts → db/ module split (shim + 10 modules) | ~20 | Phase 1 |
| 5* | Degradation warnings + save_insight contract change | ~5 | — |
| 3 | Coverage 67% → 75%+ (tests target warning paths) | ~12 | Phase 2, 5 |
| 4 | Documentation fix + additions | ~6 | — (parallel) |

*Phase 5 moved before Phase 3 to resolve ordering conflict.

## Success Criteria

- `npm test` — all pass, no flaky
- `npm run test:coverage` — ≥ 75% lines, ≥ 70% branches, ≥ 80% functions
- `npm run lint` — 0 issues (with `noExplicitAny: warn`)
- `npx knip` — 0 findings
- `npm audit` — 0 vulnerabilities
- `src/core/db.ts` is a ~30-line shim; all logic in `src/core/db/*.ts`, no file > 500 lines
- All docs match code reality
- Semantic search degradation clearly communicated via `warning` field
