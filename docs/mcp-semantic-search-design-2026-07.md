# Design Doc: MCP `search` semantic / hybrid (in-process)

- **Status**: Accepted
- **Owner**: Codex (wave-6 task 10)
- **Date**: 2026-07-09
- **Related**: `docs/p1-semantic-memory-design-2026-06.md` c.4; service
  `EngramServiceReadProvider.search`; MCP `get_memory` hybrid path;
  CHANGELOG 2026-07-09

## Problem

MCP `search` advertises and runs **keyword-only**. Agents that pass
`mode: "semantic"` or `"hybrid"` get keyword FTS with a soft warning
(`MCPDatabase.searchSessions`), so the tools/list enum hardcodes
`["keyword"]` while runtime still accepts other modes for legacy clients.

P1 plan item **c.4** required MCP `search` semantic/hybrid when embeddings
are usable. The service read path already supports that
(`EngramServiceReadProvider.semanticSearch` over `semantic_chunks` +
`VectorSearch.knn` + `RankFusion.rrf`). MCP must offer the same capability
without lying in the schema and without silent mode downgrade.

## Goals / Non-goals

**Goals**

- In-process MCP read path: brute-force cosine KNN over `semantic_chunks`
  plus optional RRF hybrid fusion with FTS keyword rankings — same family
  as `get_memory`’s `semanticMemory` and the service session search path.
- **Availability gate** named `SessionVectorSearchAvailability`: semantic
  and hybrid are advertised in `tools/list` and accepted at runtime **only**
  when embedding metadata says stored vectors are usable.
- Unavailable mode requests return **`isError`** with structured code
  `searchModeUnavailable` — never silent keyword fallback.
- Hybrid ranking parity with the service on the same fixture DB (shared
  KNN top-K formula and RRF `k`).
- Never mix embedding models/dimensions; exclude `skip` from normal reads
  and exclude `lite` from search (match product tier rules).
- Docs, goldens, p1 c.4 status, CHANGELOG.

**Non-goals**

- Rerouting MCP `search` through the EngramService Unix socket.
- Changing app UI search mode pills (already gated separately).
- Changing `get_memory` degradation policy (task 7 / insight path).
- sqlite-vec or other ANN indexes.
- Service-side silent fallback policy (service may still warn+keyword for
  app callers; MCP does not).

## Current state

| Surface | Behavior |
|---------|----------|
| `MCPToolRegistry` search schema | `mode` enum `["keyword"]` only |
| `MCPDatabase.searchSessions` | FTS keyword; non-keyword → warning + keyword results |
| `MCPDatabase.getMemory` / `semanticMemory` | Optional hybrid over **insight** embeddings when provider + rows exist |
| `EngramServiceReadProvider.search` | keyword always; semantic/hybrid over **session** `semantic_chunks` when provider embeds query; else warning + keyword |
| `embedding_meta` | Single-row model/dimension ledger written by embedding backfill |
| `semantic_chunks` | Session chunk text + Float32 BLOB embeddings |

Anchors (origin/main-era layout at design time):
`MCPDatabase.searchSessions`, `EngramServiceReadProvider.semanticSearch`,
`VectorSearch.knn`, `RankFusion.rrf` (`k` default 60).

## Proposed design

### 1. In-process MCPDatabase semantic path (chosen)

MCP already opens a **read-only** GRDB queue on `ENGRAM_MCP_DB_PATH` /
`~/.engram/index.sqlite`. Session semantic search stays there:

1. Load `EmbeddingSettings` (env / settings.json) for the **query** embed.
2. `OpenAICompatibleEmbeddingClient.embed([query])` → query vector.
3. Load candidates from `semantic_chunks` JOIN `sessions` with:
   - `embedding IS NOT NULL`
   - `model` + `dim` match `embedding_meta` (never mix models)
   - `hidden_at IS NULL`, `orphan_status IS NULL` (MCP list/search hygiene)
   - `(tier IS NULL OR tier NOT IN ('skip', 'lite'))` — **skip** excluded;
     **lite** FTS-only / not search-eligible (same as service keyword +
     semantic SQL)
   - optional source/project/since filters (same as keyword path)
4. `VectorSearch.knn(query, candidates, topK: SessionSemanticSearchPolicy.knnTopK(limit:))`
5. Collapse chunk hits to unique session IDs (first/highest-score chunk
   supplies snippet + score).
6. **semantic**: return those sessions with `matchType: "semantic"`,
   `searchModes: ["semantic"]`.
7. **hybrid** / **both**: run keyword FTS ranking, then
   `RankFusion.rrf([keywordIds, semanticIds], k: SessionSemanticSearchPolicy.rrfK)`,
   take top `limit`, prefer semantic item payload when both sides hit.
   `searchModes: ["keyword", "semantic"]`.

Keyword-only path is unchanged (UUID short-circuit, min length 3, insight
side results, scores `1/(60+rank)`).

### 2. Availability mechanism: `SessionVectorSearchAvailability`

Probe (read-only SQLite):

- `embedding_meta` row `id=1` has non-empty `model` and positive `dimension`.
- At least one `semantic_chunks` row with `embedding IS NOT NULL`,
  `model = embedding_meta.model`, `dim = embedding_meta.dimension`.

`isUsable == true` ⇔ vectors are safe to search under a single model/dim.

**tools/list:** search `mode` enum is
`["keyword"]` when `!isUsable`, else
`["keyword","semantic","hybrid"]`. Description text follows the enum.

**Runtime:** if requested mode ∈ {`semantic`,`hybrid`,`both`} and
`!SessionVectorSearchAvailability.probe(...).isUsable` →
`toolError(..., code: "searchModeUnavailable")`. No keyword body.

If vectors are usable but query embedding fails (no API key, HTTP error,
empty vector, zero candidates after filters), also `isError` for the
requested semantic mode — still no silent keyword fallback.

### 3. Hybrid parity / coupling with service

Shared constants live in `SessionSemanticSearchPolicy` (Shared EngramCore):

| Constant | Value | Coupled to |
|----------|-------|------------|
| `rrfK` | `60` | `RankFusion.rrf` default; service hybrid fusion |
| `knnTopK(limit)` | `max(limit * 4, limit)` | `EngramServiceReadProvider.semanticSearch` |
| `candidateCap(requestLimit)` | `max(200, min(requestLimit * 20, 2000))` | service `semanticChunkCandidates` LIMIT |

MCP hybrid must produce the same **session-id order** as the service read
path on an identical fixture DB, identical query embedding, and identical
filters (tests seed one model/dim and a static embed provider / mock HTTP).

Documented intentional deltas (not ranking parity):

- MCP still filters `orphan_status IS NULL` on keyword/semantic SQL (service
  historically omits orphan filter on search).
- MCP unavailable semantic mode is hard-error; service app path may still
  degrade with a warning for UI callers.

### 4. Never mix models; tier rules

- Candidate load always constrains `sc.model` + `sc.dim` to `embedding_meta`.
- Query embed uses `EmbeddingSettings` dimension; if it disagrees with
  metadata dimension, mode fails closed (`searchModeUnavailable` /
  search failure) rather than decoding mismatched BLOBs.
- Tier: `skip` never surfaces; `lite` excluded from keyword and vector
  search SQL exactly like the app/service search path.

## Invariants affected

- **3. Tier Visibility** — preserved: search continues to exclude `skip`
  and `lite`. Semantic path uses the same tier SQL predicate as keyword.
- **1. Single-Writer Discipline** — preserved: MCP remains read-only GRDB;
  no new writer; query embedding is network-only.

No new invariant required; availability is a schema/runtime contract.

## Alternatives considered

1. **Reroute MCP `search` through EngramService socket** — Rejected.
   - MCP read tools are designed to work when the service is down
     (mutating tools alone fail closed). Forcing a socket would make
     search unusable offline / before the app starts.
   - Extra IPC hop, DTO mapping, and capability-token dependency for a
     pure read that already has DB access.
   - Service search still soft-falls-back for app UX; MCP needs a stricter
     agent-facing contract — mixing policies on one IPC path is messy.
   - Duplicates the in-process pattern already used by `get_memory`
     hybrid (`semanticMemory`), which is the proven MCP approach.

2. **Always advertise semantic/hybrid and fail only at runtime** —
   Rejected: tools/list would again over-promise; agents would pick modes
   that always error on most installs.

3. **Silent keyword fallback with warning (status quo / service app)** —
   Rejected for MCP: agents treat soft warnings as success and never
   learn the mode was ignored.

## Test plan

- `testSearchSchemaDoesNotAdvertiseUnavailableSemanticModes` — fixture
  without usable vectors → enum `["keyword"]` only.
- Mode advertised when usable — seed `embedding_meta` + `semantic_chunks`,
  assert tools/list enum includes semantic/hybrid.
- Unavailable hybrid/semantic → `isError` + `searchModeUnavailable`
  (update goldens formerly keyword-only hybrid warning).
- Hybrid parity test
  (`testSearchHybridParityMatchesServiceRankingConstants` / fixture
  session order) — same KNN list + RRF fusion as service policy.
- Keyword regression golden `search.keyword.json` unchanged.
- Short query / UUID paths remain keyword-safe.

## Rollout

- Ship with EngramMCP rebuild (bundled helper). No schema migration;
  uses existing `embedding_meta` / `semantic_chunks`.
- Clients that still send hybrid without vectors now get `isError`
  instead of keyword results — intentional contract tightening; document
  in `docs/mcp-tools.md`.
- Revert: remove dynamic enum + semantic branch; restore keyword-only
  warning path and goldens.

## Risks and open questions

- **Provider latency**: first semantic query embeds online; agents may
  timeout if the embedding API is slow — same class of risk as
  `get_memory` hybrid.
- **Service soft-fallback vs MCP hard-error**: intentional product split;
  do not “fix” by aligning them without a separate design.
- **orphan_status filter delta**: if parity tests include orphaned
  sessions, MCP and service can diverge — fixtures must keep orphans out
  of the ranking set.
