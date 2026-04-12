# Viking Removal & Local Semantic Search — Implementation Plan

**Date**: 2026-04-12 (revised after Codex + Gemini review round 1)
**Branch**: `feat/local-semantic-search`
**Reviewers**: Claude + Codex + Gemini (3-way review, 2 rounds)
**Scope**: Personal project, no production users. Data migration from Viking is NOT required.

## Background

3 independent AI reviewers (Claude, Codex, Gemini) unanimously recommended removing OpenViking — an external semantic search engine that adds 1,336+ lines, touches 33.5% of the TS codebase, and introduces 15+ failure/skip states. The local stack (FTS5 trigram + sqlite-vec + Ollama) is already partially built. MemPal (github.com/ZhangHanDong/mempal) validates this approach: sqlite-vec + FTS5 + RRF works in production.

## Principle: Build Before Remove

Both Codex and Gemini flagged the original plan's ordering as dangerous. Removing Viking before its replacement is ready would cause a functional regression (get_memory, get_context.detail become non-functional). The revised plan strictly builds the replacement first.

---

## Phase 1: Fix Foundations (no Viking changes)

### 1.1 Fix embeddings.ts L2 normalization bug
**File**: `src/core/embeddings.ts:74-75`
**Bug**: `raw.slice(0, dimension)` truncates the vector without L2 re-normalization, destroying cosine similarity geometry.
**Fix**:
```typescript
const vec = raw.length > dimension ? raw.slice(0, dimension) : raw;
const arr = new Float32Array(vec);
// L2 normalize after truncation
const norm = Math.sqrt(arr.reduce((sum, v) => sum + v * v, 0));
if (norm > 0) for (let i = 0; i < arr.length; i++) arr[i] /= norm;
return arr;
```
**Tests**: Add unit test in `tests/core/embeddings.test.ts` verifying L2 norm ≈ 1.0 after truncation.

### 1.2 Add text chunking for embeddings
**File**: New `src/core/chunker.ts`
**Why**: Current vector-store maps 1 vector per session. Sessions are too long for a single embedding (nomic-embed-text context = 8192 tokens). Chunks improve retrieval precision.
**Design** (message-boundary-first, per Codex review):
- Primary split: on message boundaries (each `Message` from adapter is a natural boundary)
- Secondary split: only for individual messages exceeding 800 chars, use sliding window (800 chars, 200 char overlap)
- Return `{ text: string, sessionId: string, chunkIndex: number }[]`
- Import `Message` type from `src/adapters/types.ts`
**Tests**: Unit tests with fixture sessions covering both short-message and long-message cases.

### 1.3 Extend vector-store.ts for chunks + insights
**File**: `src/core/vector-store.ts`
**Changes**:
- Add `vec_chunks` virtual table (sqlite-vec `vec0` only supports PK + vector):
  ```sql
  CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
    chunk_id TEXT PRIMARY KEY,
    embedding float[N]
  );
  ```
- Add `session_chunks` metadata table (separate from vec0, per Gemini review):
  ```sql
  CREATE TABLE IF NOT EXISTS session_chunks (
    chunk_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    text TEXT NOT NULL,
    model TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_chunks_session ON session_chunks(session_id);
  ```
- Add `insights` table (NOTE: name chosen to avoid collision with existing `get_insights` cost tool):
  ```sql
  CREATE TABLE IF NOT EXISTS memory_insights (
    id TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    wing TEXT,
    room TEXT,
    source_session_id TEXT,
    importance INTEGER DEFAULT 3,
    model TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    deleted_at TEXT
  );
  ```
- Add `vec_insights` virtual table:
  ```sql
  CREATE VIRTUAL TABLE IF NOT EXISTS vec_insights USING vec0(
    insight_id TEXT PRIMARY KEY,
    embedding float[N]
  );
  ```
- **Model tracking** (per Gemini review): Store model name in `metadata` table alongside dimension.
  On init, check both model + dimension; if either changed, drop vec tables + clear metadata rows + mark all sessions for re-index.
  ```typescript
  // metadata keys: 'vec_dimension', 'vec_model'
  ```
- New methods: `upsertChunks()`, `searchChunks()`, `upsertInsight()`, `searchInsights()`, `dropAndRebuild()`
- Keep existing `upsert()/search()` for session-level ranking during transition
**Tests**: Full CRUD tests for chunk and insight paths, model-change rebuild test.

### 1.4 Embedding provider strategy
**File**: `src/core/embeddings.ts`, `src/core/config.ts`, `package.json`
**Why**: Ollama requires external daemon. Users without Ollama get zero semantic search.
**Design** (revised per Codex review):
- Keep Ollama as **default** provider (avoids destroying existing 768-dim indexes for current users)
- Add **opt-in** `@huggingface/transformers` support (NOT `@xenova/transformers` — that's deprecated)
  - Model: `Xenova/all-MiniLM-L6-v2` (384-dim) or configurable
  - Package: `@huggingface/transformers` as **optional** dependency (not in `dependencies`, in `optionalDependencies`)
  - Config: `env.localModelPath` + `env.allowRemoteModels = false` for offline use
  - **Startup**: Lazy-load on first `embed()` call via dynamic `import()`
- Add `embedding` section to `FileSettings` in `config.ts`:
  ```typescript
  embedding?: {
    provider?: 'ollama' | 'openai' | 'transformers';  // default: 'ollama'
    model?: string;      // override model name
    dimension?: number;   // override dimension
  }
  ```
- Fallback chain: configured provider → OpenAI (if key set) → null
- **No 'auto' mode** — explicit provider selection avoids silent model switches and index corruption
- **Size note**: `@huggingface/transformers` is ~48MB unpacked + model download ~90MB (quantized). Document this in settings.
**Tests**: Mock-based unit tests for provider selection logic. No real model download in CI.

---

## Phase 2: Build Replacement Features (Viking still present, but replacements ready)

### 2.1 Add save_insight MCP tool (active memory write)
**File**: New `src/tools/save_insight.ts`
**Design**:
- Input: `{ content: string, wing?: string, room?: string, importance?: 0-5 }`
- Embeds content, stores in `memory_insights` + `vec_insights` tables
- Semantic dedup: warn if cosine similarity > 0.85 to existing insight (don't block)
- Returns: `{ id, content, wing, room, importance, duplicate_warning? }`
- **Naming**: Tool name `save_insight`, table `memory_insights` — avoids collision with existing `get_insights` cost analytics tool
**Register**: Add to MCP server tool list in `src/index.ts`
**Tests**: Full test including dedup warning.

### 2.2 Rewrite search.ts — local-only hybrid path
**File**: `src/tools/search.ts`
**Changes**:
- Current signature uses `deps` object, NOT `settings` directly (per Codex review). Viking is accessed via `deps.viking`.
- Replace 3-way parallel (FTS + vec + Viking) with 2-way: FTS + local vec chunks
- Add insights search: query `vec_insights` in parallel
- RRF merge: FTS (k=60) + vec_chunks (k=60), same formula
- Return `insightResults` field (replaces `vikingMemories`)
- **Transition**: Keep Viking path behind `if (deps.viking)` check (already works since viking is optional in deps)
**Tests**: Update existing search tests, add new chunk-based search tests.

### 2.3 Rewrite get_context.ts — local memories
**File**: `src/tools/get_context.ts`
**Changes**:
- Replace Viking memory injection (lines 103-145) with local insights query via `vecStore.searchInsights()`
- `[memory]` prefix lines now come from local insights
- `detail` parameter: currently gates Viking path AND environment verbosity (per Codex review). After rewrite, `detail` only controls environment section depth. Memory injection is always-on when insights exist.
**Tests**: Rename `get_context-viking.test.ts` → `get_context-insights.test.ts`, update assertions.

### 2.4 Rewrite get_memory.ts — local insights
**File**: `src/tools/get_memory.ts`
**Changes**:
- Replace `viking.findMemories()` with local `vecStore.searchInsights()`
- Replace `VikingMemory` return type with local `MemoryInsight` type
- Return helpful message if no insights exist yet (guide user to `save_insight`)
**Tests**: Update `tests/tools/get_memory.test.ts` (currently imports VikingBridge — per Codex review).

### 2.5 Add ServerInfo.instructions self-describing protocol
**File**: `src/index.ts`
**Why**: MemPal's best idea — embed behavioral instructions in MCP initialize response so any client auto-learns how to use Engram.
**Content**: ~500 chars describing key tools (search, get_context, save_insight, get_memory) + behavioral rules
**Tests**: Integration test verifying instructions are present in server capabilities.

### 2.6 Wire up chunk-based indexing in IndexJobRunner
**File**: `src/core/index-job-runner.ts` (NOT `embedding-indexer.ts` — per Codex review, IndexJobRunner is the actual runtime path)
**Changes**:
- After embedding a session, also chunk it via `chunker.ts` and store chunks via `vecStore.upsertChunks()`
- Keep session-level embedding for fast session-level ranking
- Add backfill: on startup, if `session_chunks` table is empty but `session_embeddings` has rows, re-chunk existing embedded sessions
**Tests**: Verify chunk creation during indexing, verify backfill logic.

---

## Phase 3: Remove Viking (all replacements verified working)

### 3.1 Delete Viking-only files
- `src/core/viking-bridge.ts` (851 lines)
- `src/core/viking-filter.ts` (~100 lines)
- `tests/core/viking-bridge.test.ts`
- `tests/core/viking-filter.test.ts`
- `tests/core/indexer-viking.test.ts`
- `tests/tools/search-viking.test.ts`
- `tests/tools/get_context-viking.test.ts`
- `tests/tools/get_memory.test.ts` (if fully rewritten in Phase 2.4, delete old version)

### 3.2 Clean up TypeScript integration points
- `src/core/bootstrap.ts`: Remove `initViking()` factory (~22 lines)
- `src/core/indexer.ts`: Remove `pushToViking()` logic, Viking cooldown/dedup
- `src/index.ts`: Remove Viking initialization and parameter threading
- `src/daemon.ts`: Remove Viking initialization
- `src/core/config.ts`: Remove `VikingSettings` interface, `vikingApiKey` keychain/env logic
- `src/web.ts`: Remove 7 `/api/viking/*` routes (~87 lines) + `vikingAvailable` from `/api/status`
- `src/web/views.ts`: Remove Viking status rendering in health page
- `tests/web/ai-audit-api.test.ts`: Remove Viking-related test assertions (per Codex review)

### 3.3 Database migration
- Drop `viking_pushed_at` and `viking_pushed_msg_count` columns (idempotent migration in `db.ts`)
- Remove `markVikingPushed()`, `listPremiumSessions()` Viking-specific DB methods
- Keep `tier` column and tiering logic (still useful for indexing priority)

### 3.4 Swift / macOS cleanup (per Codex review — full file list)
- `macos/Engram/Views/Settings/NetworkSettingsSection.swift`: Remove Viking settings (enabled/url/apiKey)
- `macos/Engram/Views/Settings/SettingsIO.swift`: Remove Viking key persistence
- `macos/Engram/Views/Pages/SearchPageView.swift`: Remove Viking memory display
- `macos/Engram/Core/IndexerProcess.swift`: Remove Viking config forwarding to daemon
- `macos/EngramUITests/Tests/FullTests/SettingsTests.swift`: Update/remove Viking settings tests

### 3.5 Config cleanup
- `src/core/config.ts`: Remove `VikingSettings` type, remove from `FileSettings`
- `~/.engram/settings.json`: Viking keys become ignored (no crash on unknown keys)

---

## Phase 4: CI & Quality

### 4.1 Update CI workflow
**File**: `.github/workflows/test.yml`
**Changes**:
- Add explicit `lint` job:
  ```yaml
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: 'npm' }
      - run: npm ci
      - run: npm run lint
  ```
- Add `knip` dead code check job:
  ```yaml
  dead-code:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    needs: [typescript]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: 'npm' }
      - run: npm ci
      - run: npm run build
      - run: npx knip
  ```
- **No model cache step needed** — Transformers.js is opt-in, not used in CI tests

### 4.2 Verify all tests pass
- `npm run build` — zero TS errors
- `npm test` — all tests pass (count may drop due to removed Viking tests, but no regressions in remaining)
- `npm run lint` — biome clean
- `npm run knip` — no dead exports/imports from Viking remnants
- `grep -r 'viking' src/` — zero hits (excluding comments explaining removal)

### 4.3 Update CLAUDE.md
- Remove Viking/OpenViking references from architecture section
- Remove `viking-bridge.ts` from file tree
- Update tool count (add `save_insight`, keep others)
- Document `memory_insights` table in DB section
- Document chunking and local embedding strategy
- Update "What NOT To Do" section (remove Viking-specific warnings)

### 4.4 Update project memory
- Update `memory/project_openviking.md` → mark as historical/removed
- Update `memory/MEMORY.md` index

---

## Complete File Inventory

### Files to CREATE
| File | Phase |
|------|-------|
| `src/core/chunker.ts` | 1.2 |
| `src/tools/save_insight.ts` | 2.1 |
| `tests/core/chunker.test.ts` | 1.2 |
| `tests/core/embeddings.test.ts` (or extend existing) | 1.1 |
| `tests/tools/save_insight.test.ts` | 2.1 |
| `tests/tools/get_context-insights.test.ts` | 2.3 |

### Files to MODIFY
| File | Phase | What |
|------|-------|------|
| `src/core/embeddings.ts` | 1.1, 1.4 | L2 fix + provider strategy |
| `src/core/vector-store.ts` | 1.3 | Chunks + insights tables + model tracking |
| `src/core/config.ts` | 1.4, 3.5 | Add embedding config, remove Viking config |
| `src/core/index-job-runner.ts` | 2.6 | Chunk-based indexing + backfill |
| `src/tools/search.ts` | 2.2 | Local-only hybrid search |
| `src/tools/get_context.ts` | 2.3 | Local insights injection |
| `src/tools/get_memory.ts` | 2.4 | Local insights backend |
| `src/index.ts` | 2.1, 2.5, 3.2 | Register save_insight, add instructions, remove Viking |
| `src/daemon.ts` | 3.2 | Remove Viking init |
| `src/core/bootstrap.ts` | 3.2 | Remove initViking() |
| `src/core/indexer.ts` | 3.2 | Remove pushToViking |
| `src/core/db.ts` | 3.3 | Drop Viking columns |
| `src/web.ts` | 3.2 | Remove Viking routes + status |
| `src/web/views.ts` | 3.2 | Remove Viking health rendering |
| `package.json` | 1.4 | Add @huggingface/transformers to optionalDeps |
| `.github/workflows/test.yml` | 4.1 | Add lint + knip jobs |
| `CLAUDE.md` | 4.3 | Remove Viking docs, add new features |
| `tests/tools/get_memory.test.ts` | 2.4 | Rewrite for local insights |
| `tests/web/ai-audit-api.test.ts` | 3.2 | Remove Viking assertions |
| `macos/Engram/Views/Settings/NetworkSettingsSection.swift` | 3.4 | Remove Viking UI |
| `macos/Engram/Views/Settings/SettingsIO.swift` | 3.4 | Remove Viking persistence |
| `macos/Engram/Views/Pages/SearchPageView.swift` | 3.4 | Remove Viking memory display |
| `macos/Engram/Core/IndexerProcess.swift` | 3.4 | Remove Viking config forwarding |
| `macos/EngramUITests/Tests/FullTests/SettingsTests.swift` | 3.4 | Update settings tests |
| `memory/project_openviking.md` | 4.4 | Mark as historical/removed |
| `memory/MEMORY.md` | 4.4 | Update index |

### Files to NOTE (external, not in repo)
| File | Phase | What |
|------|-------|------|
| `~/.engram/settings.json` | 3.5 | Viking keys become ignored (no crash) |

### Files to DELETE
| File | Phase |
|------|-------|
| `src/core/viking-bridge.ts` | 3.1 |
| `src/core/viking-filter.ts` | 3.1 |
| `tests/core/viking-bridge.test.ts` | 3.1 |
| `tests/core/viking-filter.test.ts` | 3.1 |
| `tests/core/indexer-viking.test.ts` | 3.1 |
| `tests/tools/search-viking.test.ts` | 3.1 |
| `tests/tools/get_context-viking.test.ts` | 3.1 |

---

## Verification Checklist

Before marking complete:
- [ ] `npm run build` — 0 errors
- [ ] `npm test` — all pass, no regressions
- [ ] `npm run lint` — clean
- [ ] `npm run knip` — no dead code from Viking removal
- [ ] `grep -r 'viking-bridge' src/` — zero hits
- [ ] `search` tool works without Viking (FTS + local vec chunks)
- [ ] `get_context` tool works without Viking (local insights)
- [ ] `get_memory` tool works with local insights
- [ ] `save_insight` tool creates and retrieves insights
- [ ] CI workflow runs successfully (lint + knip + tests)
- [ ] No `viking` imports remain in src/
- [ ] Swift builds successfully after cleanup
- [ ] `xcodegen generate` succeeds (no missing file references)

## Risk Mitigation

1. **Feature flag**: Viking stays behind `deps.viking` check during Phase 2. Only fully removed in Phase 3 after local path is verified.
2. **Incremental commits**: Each sub-task = 1 atomic commit. Easy to bisect if something breaks.
3. **Test-first**: New local paths have tests before Viking removal.
4. **No data migration needed**: Personal project, no production users. Existing Viking data is disposable. Local vectors will be rebuilt from scratch with new model/dimension.
5. **Model change = full rebuild**: When embedding model or dimension changes, `vector-store.ts` drops all vec tables and re-indexes from source sessions. This is acceptable for the current scale (~500 sessions).
6. **sqlite-vec failure**: If `sqlite-vec` fails to load, semantic search degrades to FTS-only. This is the same behavior as today when Viking is down. Log a warning but don't crash.
7. **Keychain/config cleanup**: `config.ts` currently reads `vikingApiKey` from keychain/env (`ENGRAM_KEYCHAIN_vikingApiKey`). Phase 3.5 must remove this logic from `readFileSettings()`. The env var and any keychain entry become harmless orphans — no crash, no leak. Swift `SettingsIO.swift` Viking key persistence is cleaned in Phase 3.4. Legacy `~/.engram/settings.json` files with `viking.*` keys are silently ignored (TypeScript reads only known keys).
