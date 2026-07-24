# Engram MCP Tools Reference

> Current product runtime is Swift `EngramMCP`; TypeScript tool definitions are retained as development/reference material.
>
> **Total tools: 27** | Protocol: MCP (Model Context Protocol) | Server name: `engram`
>
> Removed: the former corpus rule-mining surface (`get_rules` and `engram://rule/{id}` resources) is no longer exposed. Existing `mined_rules` rows in installed databases are left inert; fresh Swift product databases no longer create the mined-rule tables.

---

## structuredContent and outputSchema

Successful tool results that carry machine-readable payloads include MCP
`structuredContent` alongside the usual `content[].text` mirror. Read tools that
emit structured payloads also declare an `outputSchema` in `tools/list` so
clients can type-check the JSON without guessing.

| Tool | Root shape | Always present | Optional fields |
|------|------------|----------------|-----------------|
| `list_sessions` | object | `sessions[]`, `total` | — |
| `stats` | object | `groupBy`, `groups[]`, `indexJobs`, `totalSessions` | — |
| `get_costs` | object | `totalCostUsd`, `totalInputTokens`, `totalOutputTokens`, unpriced* counts, `breakdown[]` | — |
| `tool_analytics` | object | `tools[]`, `totalCalls`, `groupCount` | per-row `sessionCount` / `toolCount` / `label` depend on `group_by` |
| `file_activity` | object | `files[]`, `totalFiles` | — |
| `project_timeline` | object | `project`, `timeline[]`, `total` | — |
| `project_list_migrations` | object | `migrations[]` | nullable `finishedAt` / `rolledBackOf` / `auditNote` / `error`; `detail` object or null |
| `live_sessions` | object | `sessions[]`, `count`, `note` | MCP mode always returns empty sessions + unavailable note |
| `get_memory` | object | `memories[]` (each item includes returned `type`) | top-level `type` when a type filter is requested; `warning`, `message`, or `retrieval` depending on path |
| `search` | object | `results[]`, `query`, `searchModes[]` | `warning`, `insightResults[]` |
| `get_insights` | object | `content[]` (`type`/`text` items) | — |
| `project_review` | object | `own[]`, `other[]` | `truncated.{own,other}` when caps apply |
| `get_session` | object | `session`, `messages[]`, `totalPages`, `currentPage`, `redacted` | `totalKnownComplete`, `truncated`, `truncatedAt` |
| `handoff` | object | `brief`, `sessionCount` | — |
| `project_recover` | object | `diagnostics[]` with nested `fs` | nullable `finishedAt` / `error` / `fs.probeError` |

Tools that do **not** declare `outputSchema`:

- `get_context` — text-only result (no `structuredContent`)
- `generate_summary` — text + `metadata` only (no `structuredContent`)
- Mutating / operational tools (`save_insight`, `export`, `project_move`, …) — they may still emit `structuredContent`, but schemas are reserved for read tools in this wave

Error results may include `structuredContent` with `code` / `message` (and related fields for `serviceUnavailable`); those error envelopes are not covered by tool `outputSchema`.

---

## Choosing a read tool

| Goal | Use | Notes |
|------|-----|-------|
| Find sessions by words or phrases | `search` | Keyword SQLite FTS by default. When `SessionVectorSearchAvailability` reports usable session embeddings (`embedding_meta` + matching `semantic_chunks`), `tools/list` also advertises `semantic` and `hybrid`. Unavailable semantic/hybrid requests return `isError` with code `searchModeUnavailable` (never silent keyword fallback). Keyword results exclude hidden, orphaned, `skip`, and `lite` rows. |
| Start work in a repo and recover relevant history | `get_context` | Best first call for a current working directory. It combines recent project sessions, saved insights, and optional environment data within the requested token budget. |
| Retrieve durable memories or preferences | `get_memory` | Uses insight lookup. When no embedding provider is available, it falls back to keyword/recency ranking and says so in the response warning. |
| Read one transcript | `get_session` | Use when you already have a session id. It paginates at 50 messages per page; increment `page` to read later messages. A `transcriptTooLarge` error means the source hit the full-JSON size guard, and pagination may not bypass that guard. |
| Browse metadata without transcript bodies | `list_sessions` | Use filters for source, project, and date windows. Returns session metadata only and is cheaper than transcript reads. |
| Count usage or inspect aggregate activity | `stats` | Use for session/message counts by source, project, day, or week. For spend, use `get_costs`; for tool calls, use `tool_analytics`. |

---

## Error codes and recovery

| Code | Emitted by | Meaning | Recovery action |
|------|------------|---------|-----------------|
| `searchFailed` | `search` | Keyword lookup failed (generic message) or a usable-mode semantic request failed mid-flight (embed/provider/candidates). | Retry once. For semantic failures, check embedding provider/env and that `semantic_chunks` match `embedding_meta`. |
| `searchModeUnavailable` | `search` | `mode` was `semantic`, `hybrid`, or `both` but `SessionVectorSearchAvailability` says session vectors are not usable (or metadata is missing). | Use `mode: "keyword"`, or configure embeddings and wait for session chunk backfill until `tools/list` advertises semantic/hybrid. |
| `transcriptTooLarge` | `get_session`, `export` | The transcript file exceeds `ENGRAM_MAX_FULL_JSON_TRANSCRIPT_BYTES`, or 10 MiB by default; guarded sources can fail before pagination can help. Export preserves the same structured code through service IPC. | Reduce the source transcript below the configured limit or restart MCP with a higher `ENGRAM_MAX_FULL_JSON_TRANSCRIPT_BYTES`, then retry. |
| `serviceUnavailable` | `save_insight`, `delete_insight`, `hide_session`, `export`, `generate_summary`, `link_sessions`, mutating `manage_project_alias`, `project_move`, `project_archive`, `project_undo`, and `project_move_batch` | Mutating, operational, and long-running read tools fail closed when the EngramService socket is unavailable. Read-only tools continue to work. | Launch Engram.app or otherwise start EngramService, then retry. For `delete_insight` and `hide_session`, `dry_run: true` remains read-only. For `manage_project_alias`, `action: "list"` remains read-only. For project move/archive/undo/batch, even dry-runs require the service. |
| `cancelled` | Any in-flight `tools/call` cancelled by the MCP client | The client sent `notifications/cancelled` for that request id. | Re-run the tool only if the work is still needed; for operational tools, inspect state first with `project_list_migrations` or `project_recover`. |
| No structured code (`invalidArguments`) | Schema validation and required-argument checks | Invalid or missing parameter. The MCP result is an error but `structuredContent.code` is omitted. | Fix the parameter name, type, enum value, range, or required field from the message and retry. |
| No structured code (service error flattening) | Any uncaught `EngramServiceError` escaping a handler | The stdio bridge flattens the service error message; service error name, code, and retry policy do not reach the MCP wire. | Treat the text as authoritative, check service status/logs if needed, and retry only when the underlying condition is resolved. |
---

## list_sessions

List historical AI coding assistant sessions. Supports filtering by tool source, project, and time range.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| source | string | no | Filter by tool source. Enum: `codex`, `claude-code`, `copilot`, `gemini-cli`, `opencode`, `iflow`, `qwen`, `qoder`, `kimi`, `minimax`, `lobsterai`, `commandcode`, `cline`, `cursor`, `vscode`, `antigravity`, `windsurf` |
| project | string | no | Filter by exact project name or configured alias |
| since | string | no | Start time (ISO 8601) |
| until | string | no | End time (ISO 8601) |
| limit | number | no | Max results to return. Default 20, max 100 |
| offset | number | no | Pagination offset. Default 0 |
| include_all | boolean | no | Include single-turn and automated sessions in addition to human-driven sessions. Default `false` |

**Notes:** Returns session metadata (id, source, startTime, endTime, cwd, project, model, messageCount, userMessageCount, summary). By default, results are limited to human-driven sessions with a clear human instruction. Set `include_all: true` to include single-turn and automated sessions. Limit is clamped to 100 even if a higher value is passed. **Output:** `structuredContent` is `{ sessions, total }`; declared via `outputSchema` in `tools/list`.

---

## get_session

Read the full conversation content of a single session. Supports pagination for large sessions (50 messages per page).

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| id | string | **yes** | Session ID |
| page | number | no | Page number, starting from 1. Default 1 |
| roles | string[] | no | Only return messages from specified roles. Enum per item: `user`, `assistant`. Default (omit or empty): visible **user/assistant** messages only — never tool/system or “all roles”. |
| include_raw | boolean | no | When `true`, return unredacted message content (local-only opt-in). Default `false`: secrets are redacted with the same policy as `export`. Response includes `redacted: true/false`. |

**Notes:** Page size is fixed at 50 messages. Response includes `totalPages`, `currentPage`, and `redacted` for navigation and redaction state. Returns an error if the session ID is not found or the source adapter is unsupported. **Output:** `structuredContent` is `{ session, messages, totalPages, currentPage, redacted }` plus optional truncation flags; declared via `outputSchema`.

---

## search

Full-text keyword search across session content; optional semantic / hybrid when session embeddings are usable. Supports Chinese and English.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| query | string | **yes** | Search keywords; queries shorter than 3 characters use LIKE fallback |
| source | string | no | Filter by tool source. Same enum as `list_sessions` |
| project | string | no | Filter by exact project name or configured alias |
| since | string | no | Activity-time lower bound using end time when present, otherwise start time (ISO 8601) |
| limit | number | no | Max results. Default 10, max 50 |
| mode | string | no | Search mode. Enum from `tools/list`: always `keyword`; adds `semantic` and `hybrid` only when session vectors are usable. Default `keyword` |

**Notes:** Keyword path uses SQLite FTS. UUID-shaped queries do direct session ID lookup. Queries shorter than 3 characters use a session LIKE fallback. Semantic mode embeds the query (online provider via `EmbeddingSettings`) and runs brute-force cosine KNN over `semantic_chunks` filtered to `embedding_meta` model/dim (never mix models); tiers `skip` and `lite` are excluded like the app/service search path. Hybrid fuses keyword + semantic session id lists with RRF via shared constants in `SessionSemanticSearchPolicy` (`rrfK = 60`, same KNN shortlist / candidate-cap formulas as `EngramServiceReadProvider`). MCP multi-term keyword search uses per-token CTEs joined at session scope, `since` uses `COALESCE(end_time, start_time)` across keyword/LIKE/semantic paths, and project filters resolve configured aliases before exact matching. **Ranking parity scope (honest contract):** MCP and service share the fusion constants and both fuse as `[keywordIds, semanticIds]`; they are **not** guaranteed to return identical session order for every query. One known search-surface delta remains: MCP applies `orphan_status IS NULL`, while service search does not filter orphan status. Side-by-side parity tests cover single-token, unfiltered, non-orphan fixtures where keyword id lists already match. When semantic/hybrid is not usable, those modes return `isError` + `searchModeUnavailable` instead of keyword results. Keyword mode also searches insights FTS and may return matching curated memories in `insightResults`. **Output:** `structuredContent` is `{ results, query, searchModes }` with optional `warning` / `insightResults`; declared via `outputSchema`.

---

## get_context

Auto-extract relevant historical session context for the current working directory. Call at the start of a new task to get project history.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| cwd | string | **yes** | Current working directory (absolute path) |
| task | string | no | Current task description (used for related memory/context lookup) |
| max_tokens | number | no | Token budget. Default 4000 (~16,000 characters) |
| detail | string | no | Detail level. Enum: `abstract` (~100 tokens, cost+alerts only), `overview` (~2K tokens), `full` (default) |
| sort_by | string | no | Sort order. Enum: `recency` (default, reverse chronological), `score` (by quality score) |
| include_environment | boolean | no | Include live environment data (active sessions, today's cost, tool usage, alerts). Default `true` |

**Notes:** Project name is derived from `basename(cwd)`. Respects project aliases. When `task` is provided, matching saved insights are pulled with FTS keyword lookup before recent session summaries. Includes curated insights (from `save_insight`) when available. The environment section progressively drops lower-priority data (config status, file hotspots, git repos, recent errors) if it exceeds 30% of the token budget. `abstract` mode only shows cost and alerts. **Output:** text-only (`content[].text`); no `structuredContent` / `outputSchema`.

---

## project_timeline

View a project's cross-tool operation timeline. Understand what was done in different AI assistants.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| project | string | **yes** | Project name or path fragment |
| since | string | no | Start time (ISO 8601) |
| until | string | no | End time (ISO 8601) |

**Notes:** Returns up to 200 sessions sorted chronologically. Each entry includes time, source tool, summary, session ID, and message count. **Output:** `structuredContent` is `{ project, timeline, total }`; declared via `outputSchema`.

---

## stats

Get usage statistics: session counts, message counts, grouped by various dimensions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| since | string | no | Start time (ISO 8601) |
| until | string | no | End time (ISO 8601) |
| group_by | string | no | Grouping dimension. Enum: `source`, `project`, `day`, `week`. Default `source` |

**Notes:** Each group includes sessionCount, messageCount, userMessageCount, assistantMessageCount, and toolMessageCount. Also returns totalSessions across all groups and an indexJobs object keyed by raw session_index_jobs status strings. **Output:** `structuredContent` is `{ groupBy, groups, indexJobs, totalSessions }`; declared via `outputSchema`.

---

## export

Export a single session as a Markdown or JSON file, saved to `~/.engram/exports/`.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| id | string | **yes** | Session ID |
| format | string | no | Output format. Enum: `markdown`, `json`. Default `markdown` |

**Notes:** Output filename format: `{source}-{id_prefix}-{date}.{ext}`. Creates the `~/.engram/exports/` directory if it doesn't exist. Returns the output file path, format, and message count.

---

## generate_summary

Generate an AI summary for a conversation session.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| sessionId | string | **yes** | The session ID to summarize |

**Notes:** Requires `aiApiKey` to be configured in `~/.engram/settings.json`. Uses the configured AI protocol (default: OpenAI-compatible). Updates the session's summary in the database after generation. Returns an error if no API key is configured, the session is not found, or the adapter is unavailable. **Output:** text + `metadata.sessionId` only; no `structuredContent` / `outputSchema`.

---

## manage_project_alias

Link two project names so sessions from one appear in queries for the other. Use when a project directory has been moved or renamed.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| action | string | **yes** | Action to perform. Enum: `add`, `remove`, `list` |
| old_project | string | no | Old project name (required for `add`/`remove`). Absolute or multi-segment paths collapse to basename. |
| new_project | string | no | New project name (required for `add`/`remove`). Absolute or multi-segment paths collapse to basename. |

**Notes:** The `list` action requires no additional parameters and is read-only (no service required). For `add` and `remove`, both `old_project` and `new_project` are required and go through EngramService. Inputs are normalized to basename keys so they match `sessions.project` and aliases written by `project_move`; empty keys and self-keys (`old` and `new` resolve equal) are rejected. Each mutating call also rewrites any pre-existing path-shaped rows in `project_aliases` to basenames (self-keys after rewrite are dropped; collisions use `INSERT OR IGNORE`). Response includes `changed` (0/1 for add presence, delete count for remove). Aliases are bidirectional for query resolution — searching for either name returns sessions from both. Use this only for directories moved manually outside Engram. Do not call it after `project_move`; that tool already creates the alias automatically.

---

## link_sessions

Create symlinks to all AI session files for a project in `<targetDir>/conversation_log/<source>/`.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| targetDir | string | **yes** | Project directory (absolute path). Project name is derived from basename |

**Notes:** Must be an absolute path. Creates the directory structure automatically. Skips existing symlinks pointing to the same target. Replaces symlinks pointing to different targets. Respects project aliases. Query limit of 10,000 sessions; if reached, response includes `truncated: true`.

---

## get_memory

Retrieve curated insights and memories from past sessions. Use `save_insight` to add new memories.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| query | string | **yes** | What to remember (e.g. "user's coding preferences") |
| type | string | no | Optional insight type filter. Enum: `episodic`, `semantic`, `procedural`. Applied on both keyword/FTS and hybrid semantic paths. Invalid values return an error. Missing/NULL stored types are treated as `semantic`. |

**Notes:** Returns up to 10 matching insights with id, content, wing, room, importance, distance placeholder, and `type` (missing/NULL stored types surface as `semantic`). When a `type` filter is requested, the same value is echoed at the top level of `structuredContent`. The Swift product path uses insight FTS keyword search (and hybrid semantic retrieval when embeddings are usable), then falls back to recent insights. If no memories exist, suggests using `save_insight`. **Output:** `structuredContent` is `{ memories }` plus optional `type` / `warning` / `message` / `retrieval`; declared via `outputSchema`.

---

## save_insight

Save an important insight, decision, or lesson learned for future retrieval. Use this to preserve knowledge that should persist across sessions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| content | string | **yes** | The insight or knowledge to save |
| wing | string | no | Project or domain name |
| room | string | no | Sub-area within the project |
| importance | number | no | Importance level 0-5. Default 5 |
| type | string | no | Memory type. Enum: `semantic`, `episodic`, `procedural`. Default `semantic` |
| source_session_id | string | no | Session ID that generated this insight |

**Notes:** Trims `content`; it must be 10-50,000 characters after trimming. `wing` and `room` are trimmed and capped at 200 characters; `source_session_id` is capped at 500 characters. `importance` defaults to 5, must be finite, is rounded to an integer, and must be within 0-5. `type` defaults to `semantic` and must be one of `episodic`, `semantic`, or `procedural`. Duplicate detection lowercases and whitespace-collapses content, then compares against up to 200 recent non-superseded insights in the same wing/room. A duplicate is not rejected: the new row is inserted, the older row is marked `superseded_by`, and the MCP response includes a duplicate warning but not the superseded row id. Current Swift product saves text-only and returns a warning that keyword search is available immediately.

---

## delete_insight

Delete a saved insight by id. Normal calls are routed through EngramService; dry-run only validates input.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| id | string | **yes** | Insight id to delete |
| dry_run | boolean | no | Validate and show intent without deleting. Default `false` |

**Notes:** With `dry_run: true`, returns the normalized id and `deleted: false` without mutating data. Empty ids are rejected.

---

## hide_session

Hide or unhide a session by id. Normal calls are routed through EngramService; dry-run only validates input.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| session_id | string | **yes** | Session id to hide or unhide |
| hidden | boolean | no | `true` hides the session; `false` restores it. Default `true` |
| dry_run | boolean | no | Validate and show intent without changing the session. Default `false` |

**Notes:** Returns `session_id`, the requested `hidden` state, and whether the call was a dry-run.

---

## get_costs

Get token usage costs across sessions, grouped by various dimensions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| group_by | string | no | Group dimension. Enum: `model`, `source`, `project`, `day`. Default `model` |
| since | string | no | Start time (ISO 8601) |
| until | string | no | End time (ISO 8601) |

**Notes:** Returns totalCostUsd (rounded to 2 decimal places), totalInputTokens, totalOutputTokens, unpriced disclosure counts (`unpricedUnattributedSessions` / `unpricedNoPriceSessions` and matching token sums — attribution defect vs pricing-table gap), and a detailed breakdown array. Unpriced fields are always emitted (properties only, not required). **Output:** `structuredContent` matches that envelope; declared via `outputSchema`.

---

## tool_analytics

Analyze which tools (Read, Edit, Bash, etc.) are used most across sessions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| project | string | no | Filter by project name (partial match) |
| since | string | no | Start time (ISO 8601) |
| group_by | string | no | Group dimension. Enum: `tool`, `session`, `project`. Default `tool` |

**Notes:** Returns the tools array with usage data, totalCalls across all groups, and groupCount. **Output:** `structuredContent` is `{ tools, totalCalls, groupCount }`; declared via `outputSchema`.

---

## handoff

Generate a handoff brief for a project -- summarizes recent sessions to help resume work.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| cwd | string | **yes** | Project directory (absolute path) |
| sessionId | string | no | Specific session to handoff (if omitted, uses the 10 most recent) |
| format | string | no | Output format. Enum: `markdown`, `plain`. Default `markdown` |

**Notes:** Project name derived from `basename(cwd)`. Includes cost data per session when available. Reads the last user message from the most recent session to generate a suggested continuation prompt. Includes relative time indicators (e.g. "2h ago") and session duration. **Output:** `structuredContent` is `{ brief, sessionCount }`; declared via `outputSchema`.

---

## live_sessions

Report MCP-mode live session monitoring status.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| *(none)* | | | This tool takes no parameters |

**Notes:** In MCP server mode, this tool intentionally returns an explicit unavailable result with an empty list and note. The macOS app/service IPC path has its own local live-session scanner for UI/service use; that scanner is not exposed through this MCP tool. **Output:** `structuredContent` is `{ sessions, count, note }`; declared via `outputSchema`.

---

## get_insights

Get actionable cost optimization suggestions with savings estimates.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| since | string | no | ISO timestamp for start of analysis window. Default: 7 days ago |

**Notes:** Returns a formatted report with period summary (total spent, projected monthly), potential savings, and prioritized suggestions (high/medium/low severity). Projected monthly divides by the **real** `since`→now window (not a hardcoded 7 days) and is **withheld** when the window is under 3 days (`too short to project`). Each suggestion includes a title, detail, savings estimate, and top contributing items. **Output:** `structuredContent` is `{ content: [{ type, text }] }`; declared via `outputSchema`.

---

## file_activity

Show most frequently edited/read files across sessions for a project. Helps understand project activity patterns.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| project | string | no | Filter by project name |
| since | string | no | ISO 8601 date filter |
| limit | number | no | Max results. Default 50 |

**Notes:** Returns file paths with edit/read counts aggregated across sessions. **Output:** `structuredContent` is `{ files, totalFiles }`; declared via `outputSchema`.

---

## project_move

Move a project directory while keeping AI session history reachable.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| src | string | **yes** | Absolute source path |
| dst | string | **yes** | Absolute destination path |
| dry_run | boolean | no | Plan only; no side effects |
| force | boolean | no | Bypass git-dirty warning on source |
| note | string | no | Audit note stored in migration log |

**Notes:** Cannot run concurrently with other `project_*` tools; execute project operations sequentially. Native Swift service pipeline. It moves the directory, patches known AI session path references, updates Engram DB state, and creates a project alias. The operation is compensating/transactional and records migration-log state.

---

## project_archive

Archive a project by moving it under `_archive/` with an inferred or specified category.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| src | string | **yes** | Absolute source path |
| to | string | no | Archive category or alias |
| dry_run | boolean | no | Plan only; no side effects |
| force | boolean | no | Bypass git-dirty warning |
| note | string | no | Audit note stored in migration log |

**Notes:** Cannot run concurrently with other `project_*` tools; execute project operations sequentially. Uses the same native Swift migration pipeline as `project_move`.

---

## project_undo

Reverse a committed project-move migration.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| migration_id | string | **yes** | Migration id returned by a previous project move/archive |
| force | boolean | no | Bypass git-dirty warning on the current destination |

**Notes:** Cannot run concurrently with other `project_*` tools; execute project operations sequentially. Prepares a reverse request from the migration log, then runs the native Swift migration pipeline.

---

## project_move_batch

Run multiple project move/archive operations sequentially from an inline JSON document.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| yaml | string | **yes** | Inline JSON document; field name is retained for IPC compatibility |
| dry_run | boolean | no | Force all operations to run as dry-run |
| force | boolean | no | Bypass git-dirty warning on every operation |

**Notes:** Cannot run concurrently with other `project_*` tools; execute project operations sequentially. JSON-only batch runner. `stopOnError` defaults to true in the batch document.

---

## project_list_migrations

List recent project-move migrations with state, paths, counts, and timestamps.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| since | string | no | ISO timestamp; only rows started after this time |
| limit | number | no | Max rows to return |

**Notes:** **Output:** `structuredContent` is `{ migrations }`, where `migrations` is an array of migration log rows; declared via `outputSchema`.

---

## project_recover

Diagnose stuck or failed migrations.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| since | string | no | ISO timestamp filter |
| include_committed | boolean | no | Also inspect committed migrations |

**Notes:** Advisory only; does not modify files or DB state. **Output:** `structuredContent` is `{ diagnostics }`, where `diagnostics` is an array of diagnosis objects (`migrationId`, `fs`, `recommendation`, …); declared via `outputSchema`.

---

## project_review

Scan AI session roots for residual references to an old project path. The tools/list description reports the live root count from the same scanner list used at runtime (not a hardcoded number).

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| old_path | string | **yes** | Absolute old path |
| new_path | string | **yes** | Absolute new path |
| max_items | number | no | Cap returned own/other arrays. Default 100 |

**Notes:** Classifies hits into `own` and `other` so migration leftovers are separated from unrelated historical mentions. **Output:** `structuredContent` is `{ own, other }` with optional `truncated`; declared via `outputSchema`.
