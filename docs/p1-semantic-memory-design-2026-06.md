# P1 Implementation Design — Semantic Memory + Lifecycle + MCP Depth + Corpus Mining

> Scope: relaunch roadmap items **c/d/e/f** (`docs/competitive-relaunch-2026-06.md`).
> Constraint from product owner: **use cheap ONLINE models, no local LLM** for
> anything needing an embedding or a generation model. All AI features stay
> **opt-in** (no key configured ⇒ current keyword-only behavior, local-first
> default preserved, zero new telemetry).

- **c** — Swift semantic memory: pure-Swift vector search + online embeddings + RRF hybrid fusion
- **d** — Memory lifecycle: decay / supersession / typing + rank by importance
- **e** — Deepen MCP surface: annotations + outputSchema + resources + prompts
- **f** — Mine the 17-source corpus into reusable skills/rules/runbooks (online LLM)

## Status as of 2026-07-09 (plan-completion audit)

| Plan item | Status |
|-----------|--------|
| F1 Online AI client + circuit breaker / cost telemetry | **partial** (client exists; guardrails missing) → wave-6 **task 9** |
| F2 sqlite-vec native target | **parked-see-roadmap** (superseded by pure-Swift brute-force cosine; revisit only if measured need) |
| F3 migration (embedding_meta, chunks, insight lifecycle cols, mined_rules) | **partial** (semantic_chunks / embedding_meta / insight lifecycle cols landed; mined_rules surface removed 2026-07-06) |
| c.1 Chunker + EmbeddingClient + VectorMath | **done** (2026-06-26) |
| c.2 VectorSearch.knn + RankFusion.rrf + schema | **done** (2026-06-26) |
| c.3 Embedding settings + hybrid read + backfill wiring | **done** (service search semantic/hybrid; insight/session backfill) |
| c.4 MCP `search` semantic/hybrid when embeddings usable | **not_done** → wave-6 **task 10** (today keyword-only schema/runtime) |
| d Ranking (decay · importance · access; exclude superseded) | **done** (read-side) |
| d Access tracking via service writer | **done** |
| d Supersession on save (text match; cosine > 0.92 deferred) | **partial** (text match; cosine supersession **parked-see-roadmap**) |
| d Typing: `save_insight` type | **done** |
| d Typing: `get_memory` optional type filter | **not_done** → wave-6 **task 7** |
| e Tool annotations | **done** (2026-06-26) |
| e `outputSchema` + `structuredContent` on read tools | **partial** (`structuredContent` landed; `outputSchema` deferred never fulfilled) → wave-6 **task 8** |
| e resources + prompts capabilities | **done** (2026-06-26; rule resources removed with corpus cut) |
| f Corpus mining / `get_rules` | **parked-see-roadmap** (product surface deleted feature-cut item 3, 2026-07-06) |

## Status update (2026-06-26, Codex)

> Superseded note (2026-07-06): feature-cut item 3 removed the corpus rule-mining
> product surface (`get_rules`, `engram://rule/{id}`, `get_context` rule
> folding, background miner, and fresh `mined_rules` schema). The sections below
> remain historical design notes, not current product behavior, where they
> describe corpus mining.

Claude landed e, d read-side, and c.1/c.2/c.3 read/backfill foundation. Codex reviewed that work and
completed the remaining live P1 runtime surface:

- c runner wiring: `EngramServiceRunner` schedules session and insight embedding backfills after
  initial/periodic FTS drains, with network embedding outside the writer gate and short gated
  read/write phases.
- c search: Swift service `search` now supports configured `semantic`/`hybrid` retrieval from
  `semantic_chunks`, with keyword fallback when embeddings are unavailable.
- d write side: `save_insight` supports optional `type`, same-scope supersession, and
  `get_memory` best-effort access recording through the service writer path.
- f: `mined_rules` + FTS schema, `get_rules`, `engram://rule/{id}`, `get_context` rule folding, and
  opt-in service corpus mining are implemented and locally verified.
- Local verification passed full `EngramMCPTests` 101/101, full `EngramCoreTests` 496/496, full
  `EngramServiceCore` 254 tests with 1 expected live-offload skip, main `Engram` Debug build,
  `npm run check:fixtures`, and `git diff --check`. Remote CI, `EngramUITests`, and full TS
  lint/typecheck/coverage were not run.

## Grounding (verified file:line)

- MCP write path: `save_insight` tool → `serviceClient.saveInsight(...)`
  (`MCPToolRegistry.swift:928-931`) → service
  `EngramServiceCommandHandler.saveInsight(_:writer:)` (`:1298`). **All writes go
  through the service writer gate.** MCP reads use `MCPDatabase` (GRDB read pool).
- `getMemory(query:)` (`MCPDatabase.swift:441`): FTS keyword match, else recency
  fallback — **ignores `importance`** entirely. This is the d gap.
- Insights schema (`EngramMigrations.swift:350`): `insights` (+`insights_fts`),
  `memory_insights` (vector), columns incl. `importance INTEGER DEFAULT 5`,
  `has_embedding`, `source_session_id`, `wing`, `room`, `created_at`.
- Swift product sqlite-vec probe / rebuild policy scaffolding has been removed;
  future sqlite-vec work needs a fresh runtime implementation with callers and
  tests.
- MCP capabilities advertise **tools only** (`MCPStdioServer.swift:121-123`);
  `MCPToolDefinition` (`MCPToolRegistry.swift:3`) has name/description/inputSchema
  only. `ToolCategory{readOnly,mutating,operational,longRunningRead}`
  (`:26-40`) already exists — **derive annotations from it**.
- TS reference to port: `src/core/embeddings.ts` (OpenAI `text-embedding-3-small`
  + `dimensions` + L2-normalize), `src/core/chunker.ts` (message-boundary-first +
  sliding window), `src/core/vector-store.ts`, `src/core/db/insight-repo.ts`.

## Shared foundation (build first)

### F1 — Online AI client (`macos/EngramCoreWrite/AI/`)
New Swift module, pure `URLSession`, OpenAI-compatible, reusing existing settings.

- `EmbeddingClient`: `POST {baseURL}/embeddings` `{model, input, dimensions}` →
  parse `data[0].embedding` → `Float32Array` → L2-normalize. Default model
  `text-embedding-3-small`, dim `1536` (configurable). Batches inputs.
- `CompletionClient`: `POST {baseURL}/chat/completions` `{model, messages,
  response_format}` for f's extraction. Default model from existing `aiModel`
  (README default `gpt-4o-mini`).
- Config (extend settings + Keychain, mirror `aiApiKey`):
  `embeddingProvider` (default `openai`), `embeddingBaseURL` (default
  `https://api.openai.com/v1`, OpenAI-compatible so DeepSeek/SiliconFlow/etc.
  work), `embeddingModel`, `embeddingDimension`, `embeddingApiKey`
  (falls back to `aiApiKey`). **Opt-in**: nil key ⇒ clients return `nil` ⇒ all
  callers degrade to keyword (today's behavior).
- Cost/audit: record embed/generate token usage into existing cost path where
  available; respect timeouts + a circuit-breaker (mirror TS `ollamaDown`).

### F2 — sqlite-vec target (superseded)
Superseded on 2026-06-26: implementation pivoted to pure-Swift brute-force cosine KNN over Float32
BLOBs. No sqlite-vec target, C amalgamation, `sqlite3_auto_extension`, dylib, or notarization work is
required for the shipped P1 semantic-memory slice.

### F3 — One idempotent migration (`EngramMigrations.swift`, next version)
- `embedding_meta(provider, model, dimension, updated_at)` — drives a future
  vector rebuild implementation (wipe+rebuild vec tables when model/dim
  changes).
- `session_chunks(id, session_id, chunk_index, text, token_estimate, created_at)`
  `+ session_chunks_fts` `+ vec_session_chunks` (vec0, `embedding float[dim]`).
- `vec_insights` (vec0) paired with existing `memory_insights`.
- insights lifecycle columns (idempotent `ADD COLUMN`):
  `insight_type TEXT` (`episodic|semantic|procedural`, default `semantic`),
  `superseded_by TEXT NULL`, `last_accessed_at TEXT NULL`,
  `access_count INTEGER NOT NULL DEFAULT 0`.
- `mined_rules(id, rule_type, title, body, evidence_session_ids, confidence,
  source_project, model, created_at)` `+ mined_rules_fts`.

## c — Semantic memory (pure-Swift vectors + online embeddings + RRF)

1. **Chunker** (`SessionChunker.swift`): port `chunker.ts` — message-boundary
   accumulation to ~800 chars, sliding window (200 overlap) for oversized.
2. **Embedding job** (service writer): on index of a `normal`/`premium` session
   whose embedding text changed (tier already gates this), chunk → embed batch →
   upsert `session_chunks` + `vec_session_chunks`. Same for insights on save.
   Skipped entirely when no embedding key (keyword-only).
3. **VectorStore** (`VectorStore.swift`, read): vec0 KNN
   `SELECT ... FROM vec_session_chunks WHERE embedding MATCH ? ORDER BY distance
   LIMIT k`; map chunks→sessions.
4. **RRF fusion**: `searchSessions(mode:"semantic"|"hybrid")`, `getMemory`,
   `getContext` run FTS + vector, fuse by Reciprocal Rank Fusion
   (`score = Σ 1/(K + rank_i)`, K=60). Falls back to pure keyword when embeddings
   unavailable (keeps the existing warning contract). MCP `search` schema
   re-enables `semantic`/`hybrid` **only** when `embedding_meta` shows a usable
   provider.

## d — Memory lifecycle

- **Ranking** (`getMemory`, read): replace recency-only ordering with
  `final = retrieval_score · recencyDecay(age) · importanceBoost(importance) ·
  accessBoost(access_count)`; `recencyDecay = exp(-ageDays / HALF_LIFE)`
  (HALF_LIFE≈30d), `importanceBoost = 0.6 + 0.4·importance/5`. **Excludes rows
  where `superseded_by IS NOT NULL`.** Hybrid retrieval from c when available,
  FTS otherwise.
- **Access tracking**: `getMemory` returns ids; service bumps
  `access_count`/`last_accessed_at` (best-effort, async) so reinforced memories
  rank up.
- **Supersession** (service `saveInsight`): on save, find same-`wing` near-dupe
  (normalized-text match now; embedding cosine > 0.92 once embeddings exist). If
  found, set old `superseded_by = newId` instead of silent dedup — preserves
  provenance/version chain.
- **Typing**: `save_insight` accepts optional `type`
  (`episodic|semantic|procedural`); default `semantic`. `get_memory` accepts an
  optional `type` filter. Procedural/semantic decay slower than episodic
  (per-type HALF_LIFE).

## e — Deepen MCP surface (no external deps — landed first)

1. **Tool annotations**: extend `MCPToolDefinition` with optional `title` +
   `annotations` derived from `ToolCategory`:
   - readOnly ⇒ `readOnlyHint:true`, `openWorldHint:false`
   - mutating/operational ⇒ `destructiveHint:true` (`project_undo`,
     `project_recover` ⇒ `idempotentHint:true`), `openWorldHint:false`
   Emit in `tools/list`. Clients auto-approve reads, gate `project_move` etc.
2. **outputSchema + structuredContent**: add `outputSchema` to read tools
   (`get_context`, `get_costs`, `stats`, `tool_analytics`, `file_activity`,
   `search`, `list_sessions`) and include `structuredContent` alongside the
   existing text content so agents chain typed JSON.
3. **resources** capability + `resources/list` + `resources/read` in
   `MCPStdioServer`: expose recent sessions (`engram://session/{id}`), saved
   insights (`engram://insight/{id}`), mined rules (`engram://rule/{id}`) →
   appear in Claude Code `@`-mention autocomplete.
4. **prompts** capability + `prompts/list` + `prompts/get`:
   `engram:catch-up` (args: cwd → pre-fills `get_context`), `engram:handoff`
   (args: project) → native slash commands in Claude Code.

## f — Corpus mining → reusable skills/rules/runbooks (online LLM)

1. **Beat selection**: pick high-value sessions (quality_score band high, has
   Edit/Write tool activity, recent) not yet mined.
2. **Extraction** (`CorpusMiner`, service idle job): feed a compact session
   digest to `CompletionClient` with a structured `response_format` asking for
   `{rule_type, title, body, evidence_session_ids, confidence}[]` from
   "you asked X → agent did Y → it worked" beats. Cheap online model.
3. **Storage**: upsert into `mined_rules` (+FTS) via service writer; dedup by
   normalized title; keep evidence session ids for provenance.
4. **Surface**: new MCP tool `get_rules` (+ resource `engram://rule/{id}`) and
   fold top rules into `get_context` for the cwd's project. Runs only when a
   completion key is configured.

## Sequencing & verification

Land in verified increments (each builds + has Swift tests):
1. **e** (no deps) — annotations/resources/prompts. ✅ **DONE 2026-06-26** (EngramMCPTests 97/97).
   `outputSchema` rolled into step 3.
2. **F3 migration + d (read side)** — lifecycle columns + importance/decay ranking + superseded
   exclusion. ✅ **DONE 2026-06-26** (EngramMCPTests 97/97, EngramCoreTests 483/483). Service-side
   supersession-on-save + access-count bump deferred to step 3's service-writer pass.
3. **c** — semantic memory. **PIVOT: no sqlite-vec** — pure-Swift brute-force cosine KNN over
   Float32 BLOBs (no native dep, fully testable; F2 sqlite-vec target dropped). OpenAI-compatible
   embedding client (provider confirmed).
   - **c.1** ✅ **DONE 2026-06-26** — `Shared/EngramCore/AI/`: `OpenAICompatibleEmbeddingClient`,
     `SessionChunker`, `VectorMath` (SemanticMemoryUnitTests).
   - **c.2** ✅ **DONE 2026-06-26** — `VectorSearch.knn` + `RankFusion.rrf` (pure, tested); schema
     `insight_embeddings` / `semantic_chunks` / `embedding_meta` (EngramCoreTests 494/494).
   - **c.3** — config reader + hybrid read + write backfill.
     - ✅ **DONE 2026-06-26**: `EmbeddingSettings` reader; `get_memory` hybrid (async, KNN+RRF, e2e via
       localhost mock server, degrades on failure); `InsightEmbeddingBackfill` write job (unit-tested
       with injected provider). EngramMCPTests 99/99, EngramCoreTests 495/495.
    - ✅ **DONE 2026-06-26 (Codex)**: `EngramServiceRunner` wires insight and session embedding
      backfills as gated background jobs (short read/write phases, embedding outside the gate);
      service `search` supports configured semantic/hybrid mode over `semantic_chunks`; d's deferred
      supersession/access writes are implemented.
4. **f** — miner + `get_rules`. ✅ **DONE 2026-06-26**, superseded by feature-cut item 3 on 2026-07-06 — `mined_rules`/FTS schema, MCP `get_rules`,
   rule resources, `get_context` rule folding, and opt-in service corpus mining. The miner filters
   high-quality edit sessions, runs completion outside the writer gate, merges evidence for same-title
   rule updates, and skips already-mined sessions.

Provider decision (2026-06-26): **OpenAI-compatible**, configurable `embeddingBaseURL` (works with
SiliconFlow/DashScope/DeepSeek/OpenAI), default embedding `text-embedding-3-small`, mining reuses
`aiModel`; all opt-in.

Tests: `MCPToolRegistryTests` (annotations/outputSchema shapes, resources/prompts
list+read), `InsightLifecycleTests` (decay ordering, supersession, type filter),
`SessionChunkerTests` + `VectorStoreTests` (KNN + RRF on a seeded vec table),
`EmbeddingClientTests`/`CompletionClientTests` (mocked URLProtocol), `CorpusMinerTests`
(mocked completion). Adapter/parity gates unaffected.
