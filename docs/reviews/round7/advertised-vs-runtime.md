# Round 7 — Advertised vs Runtime Reconciliation Matrix

Date: 2026-05-22. Scope: Swift product runtime only (`macos/`). Read-only review.
Confirms and extends round-6 §5 (C1/H2/H3) and §9 (M2/M3).

Method: every claim was traced from its source (CLAUDE.md / Settings UI control /
MCP tool schema) to the Swift code path that should honor it. Evidence is
`file:line` in the non-`build/` product tree. `build/` artifacts ignored.

Legend for "Actual runtime": **implemented** (real end-to-end work) ·
**degraded** (silently/announced falls back to a weaker mode) · **stub**
(returns constants / fixed message) · **dead** (defined but no caller/handler).

---

## A. Semantic search / vectors / embeddings

| Capability | Source of claim | Actual runtime | Evidence | Recommendation | Effort |
|---|---|---|---|---|---|
| Hybrid search (FTS5+vec+RRF) | CLAUDE.md "Local Semantic Search … Hybrid search: FTS5 (trigram) + sqlite-vec + RRF"; MCP `search` desc "Full-text and semantic search"; `mode` enum `hybrid/keyword/semantic` | **degraded** — both search paths are keyword/FTS-only. Service path logs "mode '…' requested but unsupported … falling back to keyword" and sets a warning; MCP path appends "Embedding provider unavailable — results are keyword-only (FTS)." | `EngramService/Core/EngramServiceReadProvider.swift:311-376` (esp. 313-328); `EngramMCP/Core/MCPDatabase.swift:514-611` (607-609) | **Document limitation** now (rename to "keyword search w/ optional semantic", drop `hybrid`/`semantic` from default), or **implement** vec+embeddings (large). | doc: S; impl: XL |
| RRF fusion | CLAUDE.md "RRF fusion" | **stub / no-op** — `1.0 / Double(60 + rank)` computed over a SINGLE keyword result list; fusing one list does nothing (round-6 C1 confirmed). | `EngramMCP/Core/MCPDatabase.swift:570-588` | **Remove claim** until ≥2 ranked lists exist. | doc: S |
| sqlite-vec extension | CLAUDE.md "sqlite-vec (vector embeddings)" | **stub** — `SQLiteVecSupport.probe()` (env-path form) hard-returns `isAvailable:false, reason:"sqlite-vec extension loading is not implemented yet"`. The `probe(db)` form would work IF the extension were loaded, but no code loads it. | `EngramCoreWrite/Database/SQLiteVecSupport.swift:17-32` (line 30 quote); no loader caller anywhere | **Document limitation** (vector tables never created/queried in product). | doc: S |
| Embedding provider: Ollama | Settings UI "Embeddings → Provider: Ollama"; default `embeddingProvider="ollama"`, `ollamaUrl` | **dead control** — value persisted to `settings.json["embedding"]` but no Swift code constructs an Ollama embedding client or reads `embeddingProvider`/`ollamaUrl` outside the two Settings views. | UI: `Engram/Views/Settings/AISettingsSection.swift:106-146,455-470`; dup in `Engram/Views/SettingsView.swift:181-259,464-473`; consumer grep returns only Settings files | **Remove UI** (or gate behind a "coming soon" disabled state). | doc/UI: M |
| Embedding provider: OpenAI | Settings UI "Embeddings → OpenAI" | **dead control** — same as above. | `AISettingsSection.swift:106-112` | **Remove UI**. | UI: S |
| Embedding provider: Transformers | Settings UI "Embeddings → Transformers" | **dead control** — same; no Transformers.js in Swift product at all. | `AISettingsSection.swift:109` | **Remove UI** (option references a Node-only path that does not exist in the app). | UI: S |
| Embedding dimension / model fields | Settings UI "Embedding Model", "Dimension"; caption "These settings power semantic search and memory" | **dead control + false caption** — persisted, never read by runtime. Caption claims they "power semantic search" — untrue. | `AISettingsSection.swift:123-143` (caption 141-143) | **Remove UI + caption** or replace caption with honest "no effect until semantic search ships". | UI: S |
| `embeddingStatus` service command | Wired command + Settings status surface | **degraded-to-zero** — handler counts `session_embeddings`, but nothing ever writes that table, so it always returns `available:false, embeddedCount:0, progress:0`. | `EngramService/Core/EngramServiceReadProvider.swift:421-448`; `EngramServiceCommandHandler.swift:83-87` | **Document** as always-zero until embeddings exist. | doc: S |
| `save_insight` vector write (dual-write) | CLAUDE.md "save_insight: … with embedding → dual-write (vector + text)"; `memory_insights` table | **degraded (text-only always)** — always inserts into `insights` + `insights_fts` only, returns warning "Saved without embedding". No `memory_insights`/vector write path in the service. | `EngramServiceCommandHandler.swift:675-744` (warning 742) | **Document limitation** (matches degradation-UX text); remove "dual-write" promise. | doc: S |

**End-to-end semantic-search confirmation (mandate item 5):** Settings persists
`embedding.provider` → NO Swift code constructs an embedding client, loads
sqlite-vec, or writes vectors. Quoted stub sites:
`SQLiteVecSupport.swift:30` `"sqlite-vec extension loading is not implemented yet"`;
`EngramServiceReadProvider.swift:313-321` keyword-only + warning string;
`EngramServiceCommandHandler.swift:742` `"Saved without embedding"`. Absence
confirmed end to end.

---

## B. Agent session linking

| Capability | Source of claim | Actual runtime | Evidence | Recommendation | Effort |
|---|---|---|---|---|---|
| Layer-3 manual link (set arbitrary parent) | CLAUDE.md "Layer 3 (manual): … POST /api/sessions/:id/link"; `EngramServiceLinkRequest` | **dead** — request struct defined, but NO client method, NO `case "link"` in the command switch, NO caller. | model `Shared/Service/EngramServiceModels.swift:673-676`; no `"link"` case in `EngramServiceCommandHandler.swift` switch (lines 35-280); no client method in `EngramServiceClient.swift` | **Remove dead model** or **implement** if manual linking is desired. | rm: S; impl: M |
| Layer-3 manual unlink | CLAUDE.md "DELETE /api/sessions/:id/link"; `EngramServiceUnlinkRequest` | **dead** — same; no handler/client/caller. | `EngramServiceModels.swift:678-680` | **Remove** or **implement**. | rm: S |
| Confirm suggestion | CLAUDE.md "POST /api/sessions/:id/confirm-suggestion" | **implemented** — handler sets `parent_session_id`, `link_source='manual'`; client method + UI callers exist. | handler `EngramServiceCommandHandler.swift:134-143,393-430` (sets `link_source='manual'` 422); UI `SessionDetailView.swift:437`, `SessionListView.swift:402-408` | None. | — |
| Dismiss suggestion | CLAUDE.md "DELETE /api/sessions/:id/suggestion" | **implemented** — handler + client + UI callers. | `EngramServiceCommandHandler.swift:144-153,432-…`; UI `SessionDetailView.swift:445`, `SessionListView.swift:410-417` | None. | — |

Net: the *suggestion* half of Layer-3 is real; the *arbitrary manual
link/unlink* half (the part that lets a user attach any child to any parent, or
force-detach with `link_source='manual'`) is dead. CLAUDE.md describes both as
present. (Confirms round-6 H3.)

---

## C. Sources / ingestion (17 sources)

`SourceName` enum lists 17 (`SessionAdapter.swift:3-21`). Factory builds them via
`SessionAdapterFactory.defaultAdapters()` (minimax + lobsterai are
`ClaudeCodeDerivedSourceAdapter`s).

| Source | Claim | Actual runtime | Evidence | Recommendation |
|---|---|---|---|---|
| windsurf | CLAUDE.md "17 sources" / MCP `source` enum | **degraded-to-zero on a clean machine** — adapter built `enableLiveSync:false`; `listSessionLocators()` calls `await sync()` (gated by `enableLiveSync`, so no-op) then reads `cacheDir`. The `.jsonl` cache is only ever produced by the disabled `sync()`. Indexes only pre-existing caches; on a fresh machine = 0 sessions. | factory `SessionAdapterFactory.swift:20,64`; gate `WindsurfAdapter.swift:129-132,203-208` | **Document limitation** (Windsurf live sync disabled) or **implement** by enabling sync. |
| antigravity | same | **degraded-to-zero** — identical pattern; `enableLiveSync:false`, sync gated. | factory `SessionAdapterFactory.swift:21,65`; `AntigravityAdapter.swift:128` | same as Windsurf. |
| codex, claude-code, copilot, gemini-cli, opencode, iflow, qwen, qoder, kimi, minimax, lobsterai, commandcode, cline, cursor, vscode | "17 sources" | **implemented** — file-backed adapters, no `enableLiveSync` gate; ingest from on-disk session files. (minimax/lobsterai via Claude Code derived adapter.) | `SessionAdapterFactory.swift:4-22` | None (modulo round-6 quality findings: Cline regex F3, etc.). |

Confirms round-6 H2: 2 of 17 sources (windsurf, antigravity) ingest zero on a
real machine unless a cache already exists. The CLAUDE.md "17 sources" headline
overstates working ingestion to 15.

---

## D. MCP tools (every tool in MCPToolRegistry, mandate item 3)

Registry: `EngramMCP/Core/MCPToolRegistry.swift:53-732`; dispatch `:754-1109`.

| Tool | Wired end-to-end? | Notes / Evidence |
|---|---|---|
| `list_sessions` | **implemented** | `MCPDatabase.listSessions` (`:755-765`). |
| `stats` | **implemented** | `MCPDatabase.stats` (`:766-774`). |
| `get_costs` | **implemented** | `MCPDatabase.getCosts` (`:775-782`). |
| `tool_analytics` | **implemented** | `MCPDatabase.getToolAnalytics` (`:783-790`). |
| `file_activity` | **implemented** | `MCPDatabase.getFileActivity` (`:791-798`). |
| `project_timeline` | **implemented** | `MCPDatabase.projectTimeline` (`:799-806`). |
| `project_list_migrations` | **implemented** | `MCPDatabase.listMigrations` (`:807-813`). |
| `live_sessions` | **stub (MCP mode)** | Returns `sessions:[], count:0, note:"Live session monitor not available (MCP server mode)"` regardless (`:814-821`). Tool desc promises live detection. **Document** the MCP-mode limitation. |
| `get_memory` | **implemented** | `MCPDatabase.getMemory` (`:822-825`). FTS over `insights` (keyword fallback, expected w/o embeddings). |
| `search` | **degraded** | keyword-only + warning (see §A). |
| `get_context` | **implemented** | `MCPDatabase.getContext` (`:837-847`). Keyword/recency only (no semantic re-rank). |
| `get_insights` | **partial stub** | Reads real total cost from DB but the "suggestions" line is a hardcoded constant `"No cost optimization suggestions … Spending looks healthy!"` — the advertised "actionable suggestions with savings estimates" are never produced. `MCPInsightsTool.swift:9-15`. **Document** or **implement** real suggestions. |
| `lint_config` | **implemented** | `MCPFileTools.lintConfig` (`:855-856`). |
| `link_sessions` | **implemented** | service `linkSessions` handler (`EngramServiceCommandHandler.swift:260-263,1105`); MCP `:857-871`. (Note: this is symlink creation, unrelated to parent-linking §B.) |
| `project_review` | **implemented** | `MCPFileTools.projectReview` (`:872-878`). |
| `get_session` | **implemented** | `MCPTranscriptTools.getSession` (`:879-887`). |
| `export` | **implemented** | service `exportSession` (`:888-904`). |
| `handoff` | **implemented** | service-side handoff over real DB rows (`EngramServiceCommandHandler.swift:604-643`); MCP `:905-913`. |
| `generate_summary` | **degraded (extractive, not AI)** | Service `nativeSummary` builds a metadata string `"<title>\n\nSource: … Project: … Started: … Messages: N."` — ignores ALL AI provider/prompt settings. `EngramServiceCommandHandler.swift:645-672,1298-1305`. Tool desc "Generate an AI summary" is misleading. **Document** as templated/extractive or **implement** real LLM call. |
| `save_insight` | **degraded (text-only)** | see §A; `:936-954`. |
| `delete_insight` | **implemented** | service `deleteInsight` deletes from `insights`+`insights_fts` (`:955-977`). |
| `hide_session` | **implemented** | service `setSessionHidden` (`:978-998`). |
| `project_move` | **implemented** | real `ProjectMoveOrchestrator` (`EngramServiceCommandHandler.swift:880-…`); MCP `:1024-1049`. (Security caveat: round-6 sec-C2 path confinement.) |
| `project_archive` | **implemented** | orchestrator w/ archived flag (`:1050-1068`). |
| `project_undo` | **implemented** | `UndoMigration.prepareReverseRequest` + orchestrator reverse run — real FS reversal (`EngramServiceCommandHandler.swift:940-967`). |
| `project_move_batch` | **implemented** | sequential orchestrator (`:1084-1099`). |
| `project_recover` | **advisory-only (by design)** | `MCPDatabase.projectRecover` reads migration_log + FS probes, returns recommendations; modifies nothing (matches schema/desc). `:1100-1106`. **OK** but note round-6 M2: there is no actual recover *action*, only diagnosis. |
| `manage_project_alias` | **implemented** | list via DB; add/remove via service (`:999-1023`). |

No MCP tool returns a fabricated success for a destructive op; the stubs/degrades
are `live_sessions`, `get_insights` (suggestions), `generate_summary`,
`save_insight`, `search`.

---

## E. Settings UI — persisted-but-never-consumed (dead controls, mandate item 4)

All written via `mutateEngramSettings`; consumption traced by grep across
service/write/indexer (excluding the Settings views themselves).

| Control | Persisted key | Consumed at runtime? | Evidence |
|---|---|---|---|
| AI Provider Protocol / Base URL / API Key / Model | `aiProtocol`,`aiBaseURL`,`aiApiKey`,`aiModel` | **NO** — `generate_summary` uses extractive `nativeSummary`, never an AI call. Keys stored (Keychain/JSON) but never read by any generator. | save `AISettingsSection.swift:383-431`; no runtime consumer (grep) |
| Summary Prompt (language/sentences/style/custom) | `summaryLanguage`,`summaryMaxSentences`,`summaryStyle`,`summaryPrompt` | **NO** — `nativeSummary` ignores all of these. | `AISettingsSection.swift:402-405`; `EngramServiceCommandHandler.swift:1298-1305` |
| Generation (preset/maxTokens/temp/sampling/truncate) | `summaryPreset`,… | **NO** — no LLM call to apply them. | `AISettingsSection.swift:407-423` |
| Auto Summary (toggle/cooldown/min-msgs/refresh) | `autoSummary`,… | **NO** — no auto-summary scheduler reads these in the Swift service (grep returns only Settings). | `AISettingsSection.swift:425-429` |
| Embeddings (provider/model/dimension/ollamaUrl) | `embedding.*`,`ollamaModel`,`embeddingDimension`,`ollamaUrl` | **NO** — see §A. Also duplicated in `SettingsView.swift:181-259`. | `AISettingsSection.swift:455-470`; `SettingsView.swift:464-473` |
| Title Generation (provider/url/model/apiKey/auto) | `titleProvider`,`titleBaseURL`,`titleModel`,`titleApiKey`,`titleAutoGenerate` | **NO at generation time** — `regenerateAllTitles` uses extractive `nativeTitle`, ignoring provider/model/key. Only the UI "Test Connection" button hits the URL live; "Regenerate All" runs the extractive path. | save `AISettingsSection.swift:433-453`; `EngramServiceCommandHandler.swift:858-877`; test btn `AISettingsSection.swift:317-336` |

Dead-control summary: the **entire AI Summary + Title Generation + Embeddings**
section of Settings is persisted but inert. "Test Connection" is the only live
behavior (and it tests a provider the runtime never actually calls). This is the
single largest advertised-but-inert UI surface, larger than round-6 captured.

---

## F. Other advertised features

| Capability | Source | Actual runtime | Evidence | Recommendation | Effort |
|---|---|---|---|---|---|
| "JSON" transcript tab | UI Picker (Session/Text/JSON) | **stub (identical to Text)** — `.text` and `.json` cases both render `RawMessageRow(message: msg)`; byte-identical. | `Engram/Views/SessionDetailView.swift:223-232` | **Implement** real JSON rendering or **remove** the JSON tab. | impl: S; rm: XS |
| Summary feature UI entry | round-6 ui-M3 | **dead UI path** — `generateSummary()` + `isSummarizing`/`currentSummary`/`summaryError` exist but NO button/view references them; only reachable via MCP. | `SessionDetailView.swift:20-22,551-569`; no caller (grep) | **Remove dead state** or **add** the button. (Note even if added, output is extractive — see §D.) | rm: S |
| `hygiene` command | round-6 L3; service command | **stub** — returns hardcoded `score:100` (or 80) with an always-empty `issues` array. | `EngramServiceCommandHandler.swift:593-602` | **Implement** real checks or **remove** the command. | impl: M |
| `triggerSync` command | service command | **stub** — returns `ok:false, error:"Sync is not implemented in the Swift service"`. | `EngramServiceCommandHandler.swift:579-591` | **Remove** command + any UI affordance, or **implement**. | rm: S |
| project_recover "recover" verb | tool name implies recovery | **diagnose-only** — advisory recommendations, modifies nothing (matches its own desc, but the *name* over-promises). | `MCPDatabase.projectRecover` (`:1100-1106`) | **Document** that recover = diagnose; round-6 M2 crash-window remains. | doc: S |
| Web UI "removed from product path" | CLAUDE.md "EngramWebUIServer … removed from the product path" | **FALSE — still present** — `EngramWebUIServer.swift` exists and is referenced by `EngramServiceRunner`. (Confirms round-6 sec-C1; out of this matrix's primary scope but the doc claim is wrong.) | `EngramService/Core/EngramWebUIServer.swift`; `EngramServiceRunner.swift` | **Fix doc** (it is NOT removed) AND apply round-6 sec-C1 hardening. | doc: S; sec: L |

---

## G. Honest-fix priorities (consolidated)

**Cheapest high-value (docs/UI removal, < 1 day total):**
1. Remove the 3 embedding-provider pickers + dimension/model fields + the false
   "powers semantic search" caption (`AISettingsSection.swift:104-146`,
   `SettingsView.swift:181-259`).
2. Remove the JSON transcript tab (or merge with Text) —
   `SessionDetailView.swift:223-232` + the Picker option.
3. Remove dead `generateSummary` UI state (or wire a button + relabel as
   "metadata summary").
4. Remove dead `EngramServiceLinkRequest`/`UnlinkRequest` models.
5. Rewrite CLAUDE.md "Local Semantic Search" + "17 sources" + "web removed"
   sections to match runtime (keyword-only; 15 ingesting sources; web present).
6. Drop `hybrid`/`semantic` from `search` default and `triggerSync`/`hygiene`
   command surface (or label as not-implemented).

**Relabel, don't remove (the feature works but is misdescribed):**
7. `generate_summary` desc "AI summary" → "templated/extractive summary".
8. `get_insights` — produce real suggestions or drop "actionable suggestions
   with savings estimates" from the desc.
9. `live_sessions` MCP-mode note is already honest; keep.

**Implement (real work, only if the capability is wanted):**
10. sqlite-vec loading + a Swift embedding client (Ollama first) → unlock
    semantic search, real RRF, `save_insight` dual-write, `embeddingStatus`.
11. Real LLM summary/title path consuming the AI provider settings.
12. Manual link/unlink Layer-3 handler + client + UI.
13. Windsurf/Antigravity: flip `enableLiveSync:true` (verify the discovery path)
    or remove from the advertised source count.

---

## H. Cross-check against round-6

- §5 C1 (semantic/RRF inert): **CONFIRMED** end-to-end (§A).
- §5 H2 (Windsurf/Antigravity zero-ingest): **CONFIRMED** mechanism (§C).
- §5 H3 (Layer-3 link/unlink dead): **CONFIRMED**; suggestion half is live (§B).
- §5 L3 (hygiene=100, triggerSync not impl): **CONFIRMED** (§F).
- §9 M2 (JSON tab == Text): **CONFIRMED** (§F).
- §9 M3 (summary no UI entry): **CONFIRMED** (§F).
- **NEW this round:** the *entire* AI-summary/title/embedding Settings block is
  dead-control (§E) — broader than round-6's "3 embedding providers"; plus
  `generate_summary`/`regenerateAllTitles` are extractive (not AI) despite
  "AI summary" naming, and `get_insights` suggestions are a constant string.
- **Doc error:** CLAUDE.md "web removed from product path" is factually wrong
  (§F) — `EngramWebUIServer` is wired into `EngramServiceRunner`.
