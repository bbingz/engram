# Three-Way Review Shortcomings — Design Spec

**Date**: 2026-04-13
**Branch**: TBD (will be created from `main`)
**Reviewers**: Claude + Codex + Gemini (3-way)
**Origin**: Independent 10-dimension project evaluation by 3 AI reviewers (consensus score: 7.9/10)

---

## Context

Three independent AI reviewers evaluated the Engram codebase across 10 dimensions. Consensus weaknesses:

1. `db.ts` at 1845 lines is a God Object (all 3 flagged)
2. `noExplicitAny: off` weakens type safety (all 3 flagged)
3. Line coverage at 67.4% falls short of professional standards (all 3 flagged)
4. ~20 unused exported types from knip (all 3 flagged)
5. Documentation drift and missing docs (2 of 3 flagged)
6. Silent semantic search degradation when Ollama unavailable (1 flagged)

This spec addresses all findings in 5 phases, ordered: clean → restructure → test → document → polish.

---

## Phase 1: Dead Code Cleanup + Type Safety (P2)

### Goal
Eliminate knip findings, tighten Biome rules, clean start for Phase 2.

### 1.1 Unused Exported Types (~20)

Strategy per type:
- **Delete** if truly unused (no test or runtime reference)
- **Keep + `// knip:ignore`** if part of public API surface (intentional export for consumers)
- **Keep** if referenced by test files (knip doesn't scan `tests/`)

Known targets from knip output:
```
ModelPrice, RequestContext, ResumeCommand, ResumeError, ResumeResult,
SyncResult, TitleGeneratorConfig, SpanData, Span, SpanOpts, WatcherOptions,
MemoryInsight, GetMemoryDeps, HandoffParams, LinkResult, LintIssue,
HealthIssue, SaveInsightDeps, SaveInsightResult, SearchResult
```

### 1.2 Unused Files

Verify each file reported by knip. Expected Viking remnants — confirm zero imports then delete.

### 1.3 Unused Dependencies

Check `js-yaml` and `@types/js-yaml` for actual imports. Remove if unused.

### 1.4 Biome Rule Changes

```jsonc
// biome.json
"suspicious": {
  "noExplicitAny": "warn",  // was "off" → warn first, error later
  "noControlCharactersInRegex": "off",  // keep (intentional regex patterns)
  "noAssignInExpressions": "off"  // keep (used in streaming parsers)
},
"style": {
  "noNonNullAssertion": "off"  // keep (too many changes, high risk)
}
```

Fix all `any` usages that are quick wins (< 5 min each). Leave complex ones as `// biome-ignore` with justification.

### 1.5 CI Knip Gate

Ensure `.github/workflows/test.yml` knip job uses `npx knip` (exits non-zero on findings). Verify it blocks merge.

### Verification
- `npm run lint` — 0 issues
- `npx knip` — 0 findings (or all explicitly ignored)
- `npm test` — 690 tests pass

---

## Phase 2: db.ts Module Split (P0)

### Goal
Split 1845-line `db.ts` into domain modules. External interface unchanged.

### Directory Structure

```
src/core/db/
  index.ts        (~200 lines) — Database facade class, re-exports all types
  migration.ts    (~150 lines) — migrate(), DDL, SCHEMA_VERSION, FTS_VERSION
  session-repo.ts (~400 lines) — session CRUD, list, messages, tier filtering
  fts-repo.ts     (~200 lines) — FTS index/deindex, search, CJK detection
  metrics-repo.ts (~150 lines) — stats, cost queries, AI audit queries
  index-job-repo.ts (~150 lines) — job queue CRUD
  types.ts        (~100 lines) — shared interfaces (ListSessionsOptions, FtsMatch, etc.)
```

### Architecture

```
┌─────────────────────────────────────────┐
│           Database (facade)             │
│  Holds BetterSqlite3.Database instance  │
│  Delegates to repo modules              │
├──────┬──────┬──────┬──────┬─────────────┤
│ Sess │ FTS  │ Metr │ Jobs │  Migration  │
│ Repo │ Repo │ Repo │ Repo │             │
└──────┴──────┴──────┴──────┴─────────────┘
         ▲ All repos receive raw db instance
         │ No circular dependency on Database
```

### Key Constraints

1. **Repos are plain functions/classes** that receive `BetterSqlite3.Database` — no dependency on the `Database` facade
2. **Database class public API unchanged** — all existing method signatures preserved
3. **Import path preserved** — `src/core/db.ts` → `src/core/db/index.ts`, Node16 module resolution handles `import from '../core/db.js'` automatically
4. **Re-export all types** from `db/index.ts` to maintain backward compatibility
5. **No behavior changes** — pure structural refactor

### Verification
- `npm test` — 690 tests pass (zero test file changes expected)
- `npm run lint` — 0 issues
- `npm run build` — 0 errors
- `grep -r "from.*core/db" src/ tests/` — all imports still resolve

---

## Phase 3: Test Coverage 67% → 75%+ (P1)

### Goal
Line coverage ≥ 75%, branch ≥ 70%, functions ≥ 80%. Focus on zero-coverage files and low-coverage critical paths.

### 3.1 search.ts (branch 32% → 70%+)

New test cases:
- `mode: 'semantic'` with mock vectorStore + embed function
- `mode: 'keyword'` explicit keyword-only path
- `mode: 'hybrid'` with both backends returning results → RRF fusion verification
- UUID direct lookup (valid UUID, non-existent UUID)
- No vectorStore/embed provided → graceful fallback to FTS-only
- CJK query → FTS trigram path
- Insight results merged into response
- `limit` capping at 50
- Empty query / short query handling

### 3.2 daemon.ts (0% → smoke tests)

- Daemon startup with mock DB → emits `ready` event JSON line
- Indexer progress → emits `indexed` event
- SIGTERM → graceful shutdown (watcher cleanup)
- Stderr logging format

### 3.3 index.ts (0% → tool routing)

- 19 tools registered in `allTools`
- Unknown tool name → error response
- `ServerInfo.instructions` contains expected content
- Tool input validation (missing required params)

### 3.4 Existing Test Expansion

**save_insight.ts** additions:
- Duplicate insight (same content) → semantic dedup
- Empty embedding (provider returns null) → saves text, skips vector
- Text exceeding max length → truncation behavior
- `importance` boundary values (0, 1, 5, 10)

**chunker.ts** additions:
- Empty message array → empty chunks
- Single message exceeding chunk size → split at boundary
- CJK content chunking
- Message boundary alignment verification

### 3.5 Coverage Threshold Configuration

```ts
// vitest.config.ts
coverage: {
  thresholds: {
    lines: 75,
    branches: 70,
    functions: 80,
  }
}
```

CI `npm run test:coverage` will exit non-zero if below thresholds.

### 3.6 Flaky Test Fix

`hygiene.test.ts` timestamp race → either `vi.useFakeTimers()` or relax assertion to ±2s tolerance.

### Verification
- `npm run test:coverage` — passes threshold gate
- No flaky tests on 3 consecutive runs

---

## Phase 4: Documentation Fix + Additions (P3)

### Goal
Fix drift, fill gaps. Humans and AI can onboard from docs alone.

### 4.1 README.md Corrections

- Test count: 278 → current count
- Verify adapter count, tool count, source count match code
- Update any other stale metrics

### 4.2 SECURITY.md / PRIVACY.md

- Check `docs/SECURITY.md` and `docs/PRIVACY.md` current state
- If content was stripped during Viking removal, restore with local-only architecture description
- Remove any Viking/external service references
- Document: all data local, no network calls unless embedding provider configured

### 4.3 MCP Tool API Reference

New file: `docs/mcp-tools.md`

Generated from code — for each of the 19 tools:
- Tool name
- Description (from `description` field)
- Parameters (from `inputSchema`)
- Example response shape
- Notes (rate limits, defaults, edge cases)

### 4.4 Root Directory Cleanup

- `brainstorm-rag-web-sync.md` → `docs/archive/` or delete (confirm with git log if it has value)

### 4.5 CONTRIBUTING.md

Short guide (~50 lines):
- Prerequisites: Node 20+, macOS 14+, Xcode 16+, xcodegen
- Setup: `npm install && npm run build`
- Dev: `npm run dev`, `npm test`, `npm run lint`
- Swift: `cd macos && xcodegen generate && xcodebuild ...`
- Commit convention: conventional commits
- Pre-commit: husky + biome auto-enforced
- Pointer to CLAUDE.md for architecture details

### Verification
- All doc references match actual code state
- `npx knip` still clean (new md files don't affect)

---

## Phase 5: Semantic Search Degradation UX + Extras (P4)

### Goal
Users know when semantic search is unavailable. Fix known flaky test.

### 5.1 search.ts Warning

When `mode: 'hybrid'` or `mode: 'semantic'` but embed function unavailable or fails:
```ts
return {
  results,
  query: params.query,
  searchModes, // will only contain 'keyword'
  warning: 'Embedding provider unavailable — results are keyword-only (FTS)',
};
```

### 5.2 get_context.ts Warning

When insight injection skipped due to missing embeddings:
```ts
// Add to response
warning: 'No embedding provider configured — context based on keyword match only'
```

### 5.3 save_insight.ts Graceful Save

When embedding generation fails:
- Still save insight to DB (text + metadata)
- FTS indexes the text (keyword searchable)
- Return:
```ts
{
  saved: true,
  warning: 'Insight saved without embedding — semantic search will not find it until an embedding provider is configured'
}
```

### 5.4 ServerInfo.instructions Dynamic Status

In `src/index.ts`, the `instructions` field dynamically reports:
- Provider configured: `"Embedding: ollama (nomic-embed-text, 768d)"`
- No provider: `"Embedding: not configured — semantic search disabled"`

### 5.5 Flaky Test Fix

`hygiene.test.ts` — timestamp race condition:
- Use `vi.useFakeTimers()` to control time, or
- Relax assertion precision to ±2 seconds

### 5.6 Scope Boundary (NOT in this round)

- `index.ts` monolithic routing → tool registry (next round)
- `web.ts` route splitting (next round)

### Verification
- All warning paths covered by new tests from Phase 3
- `npm test` — all pass, no flaky
- Manual: start MCP server without Ollama → `search` returns warning

---

## Execution Summary

| Phase | Content | Est. Files | Depends On |
|:-----:|---------|:----------:|:----------:|
| 1 | Dead code cleanup + type safety | ~15 | — |
| 2 | db.ts → db/ module split | ~20 | Phase 1 |
| 3 | Coverage 67% → 75%+ | ~12 | Phase 2 |
| 4 | Documentation fix + additions | ~6 | — |
| 5 | Degradation UX + flaky fix | ~5 | — |

Phases 4 and 5 are independent of 1-3 and can be parallelized.

## Success Criteria

- `npm test` — all pass, no flaky
- `npm run test:coverage` — ≥ 75% lines, ≥ 70% branches, ≥ 80% functions
- `npm run lint` — 0 issues
- `npx knip` — 0 findings
- `npm audit` — 0 vulnerabilities
- db.ts replaced by db/ directory, no single file > 500 lines
- All docs match code reality
- Semantic search degradation clearly communicated to users
