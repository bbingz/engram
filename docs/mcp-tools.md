# Engram MCP Tools Reference

> Auto-generated from tool definitions in `src/index.ts` and `src/tools/`.
>
> **Total tools: 19** | Protocol: MCP (Model Context Protocol) | Server name: `engram`

---

## list_sessions

List historical AI coding assistant sessions. Supports filtering by tool source, project, and time range.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| source | string | no | Filter by tool source. Enum: `codex`, `claude-code`, `gemini-cli`, `opencode`, `iflow`, `qwen`, `kimi`, `cline`, `cursor`, `vscode`, `antigravity`, `windsurf` |
| project | string | no | Filter by project name (partial match) |
| since | string | no | Start time (ISO 8601) |
| until | string | no | End time (ISO 8601) |
| limit | number | no | Max results to return. Default 20, max 100 |
| offset | number | no | Pagination offset. Default 0 |

**Notes:** Returns session metadata (id, source, startTime, endTime, cwd, project, model, messageCount, userMessageCount, summary). Results respect the server's `noiseFilter` setting (tier-based filtering). Limit is clamped to 100 even if a higher value is passed.

---

## get_session

Read the full conversation content of a single session. Supports pagination for large sessions (50 messages per page).

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| id | string | **yes** | Session ID |
| page | number | no | Page number, starting from 1. Default 1 |
| roles | string[] | no | Only return messages from specified roles. Enum per item: `user`, `assistant`. Default: all roles |

**Notes:** Page size is fixed at 50 messages. Response includes `totalPages` and `currentPage` for navigation. Returns an error if the session ID is not found or the source adapter is unsupported.

---

## search

Full-text and semantic search across all session content. Supports Chinese and English.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| query | string | **yes** | Search keywords (at least 2 characters for semantic, 3 for keyword) |
| source | string | no | Filter by tool source. Same enum as `list_sessions` |
| project | string | no | Filter by project name |
| since | string | no | Start time (ISO 8601) |
| limit | number | no | Max results. Default 10, max 50 |
| mode | string | no | Search mode. Enum: `hybrid`, `keyword`, `semantic`. Default `hybrid` |

**Notes:** Uses Reciprocal Rank Fusion (RRF) to merge FTS5 keyword results with sqlite-vec semantic results. If the query is a UUID, performs direct session ID lookup. Keyword search requires 3+ characters; semantic search requires 2+ characters and an active embedding provider. When embeddings are unavailable, falls back to keyword-only with a warning. Also searches the insights store and returns matching curated memories in `insightResults`.

---

## get_context

Auto-extract relevant historical session context for the current working directory. Call at the start of a new task to get project history.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| cwd | string | **yes** | Current working directory (absolute path) |
| task | string | no | Current task description (enables semantic search for relevant sessions) |
| max_tokens | number | no | Token budget. Default 4000 (~16,000 characters) |
| detail | string | no | Detail level. Enum: `abstract` (~100 tokens, cost+alerts only), `overview` (~2K tokens), `full` (default) |
| sort_by | string | no | Sort order. Enum: `recency` (default, reverse chronological), `score` (by quality score) |
| include_environment | boolean | no | Include live environment data (active sessions, today's cost, tool usage, alerts). Default `true` |

**Notes:** Project name is derived from `basename(cwd)`. Respects project aliases. When `task` is provided and embeddings are available, boosts semantically relevant sessions. Includes curated insights (from `save_insight`) when available. The environment section progressively drops lower-priority data (config status, file hotspots, git repos, recent errors) if it exceeds 30% of the token budget. `abstract` mode only shows cost and alerts.

---

## project_timeline

View a project's cross-tool operation timeline. Understand what was done in different AI assistants.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| project | string | **yes** | Project name or path fragment |
| since | string | no | Start time (ISO 8601) |
| until | string | no | End time (ISO 8601) |

**Notes:** Returns up to 200 sessions sorted chronologically. Each entry includes time, source tool, summary, session ID, and message count.

---

## stats

Get usage statistics: session counts, message counts, grouped by various dimensions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| since | string | no | Start time (ISO 8601) |
| until | string | no | End time (ISO 8601) |
| group_by | string | no | Grouping dimension. Enum: `source`, `project`, `day`, `week`. Default `source` |

**Notes:** Each group includes sessionCount, messageCount, userMessageCount, assistantMessageCount, and toolMessageCount. Also returns totalSessions across all groups.

---

## export

Export a single session as a Markdown or JSON file, saved to `~/codex-exports/`.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| id | string | **yes** | Session ID |
| format | string | no | Output format. Enum: `markdown`, `json`. Default `markdown` |

**Notes:** Output filename format: `{source}-{id_prefix}-{date}.{ext}`. Creates the `~/codex-exports/` directory if it doesn't exist. Returns the output file path, format, and message count.

---

## generate_summary

Generate an AI summary for a conversation session.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| sessionId | string | **yes** | The session ID to summarize |

**Notes:** Requires `aiApiKey` to be configured in `~/.engram/settings.json`. Uses the configured AI protocol (default: OpenAI-compatible). Updates the session's summary in the database after generation. Returns an error if no API key is configured, the session is not found, or the adapter is unavailable.

---

## manage_project_alias

Link two project names so sessions from one appear in queries for the other. Use when a project directory has been moved or renamed.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| action | string | **yes** | Action to perform. Enum: `add`, `remove`, `list` |
| old_project | string | no | Old project name (required for `add`/`remove`) |
| new_project | string | no | New project name (required for `add`/`remove`) |

**Notes:** The `list` action requires no additional parameters. For `add` and `remove`, both `old_project` and `new_project` are required. Aliases are bidirectional for query resolution -- searching for either name returns sessions from both.

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

**Notes:** Returns up to 10 matching insights with id, content, wing, room, importance, and distance (similarity). When embeddings are available, performs semantic vector search. Falls back to FTS keyword search, then to listing recent insights. If no memories exist, suggests using `save_insight`.

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

**Notes:** Performs semantic deduplication: warns if a similar insight already exists (cosine similarity > 85%). Saves both as a vector embedding (for semantic search) and as text (for FTS keyword search). If no embedding provider is configured, saves as text-only with a warning. Importance is clamped to 0-5 range by schema validation.

---

## get_costs

Get token usage costs across sessions, grouped by various dimensions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| group_by | string | no | Group dimension. Enum: `model`, `source`, `project`, `day`. Default `model` |
| since | string | no | Start time (ISO 8601) |
| until | string | no | End time (ISO 8601) |

**Notes:** Returns totalCostUsd (rounded to 2 decimal places), totalInputTokens, totalOutputTokens, and a detailed breakdown array.

---

## tool_analytics

Analyze which tools (Read, Edit, Bash, etc.) are used most across sessions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| project | string | no | Filter by project name (partial match) |
| since | string | no | Start time (ISO 8601) |
| group_by | string | no | Group dimension. Enum: `tool`, `session`, `project`. Default `tool` |

**Notes:** Returns the tools array with usage data, totalCalls across all groups, and groupCount.

---

## handoff

Generate a handoff brief for a project -- summarizes recent sessions to help resume work.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| cwd | string | **yes** | Project directory (absolute path) |
| sessionId | string | no | Specific session to handoff (if omitted, uses the 10 most recent) |
| format | string | no | Output format. Enum: `markdown`, `plain`. Default `markdown` |

**Notes:** Project name derived from `basename(cwd)`. Includes cost data per session when available. Reads the last user message from the most recent session to generate a suggested continuation prompt. Includes relative time indicators (e.g. "2h ago") and session duration.

---

## live_sessions

List currently active coding sessions detected by file activity.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| *(none)* | | | This tool takes no parameters |

**Notes:** In MCP server mode, the live session monitor is not available and returns an empty list with a note. Full functionality is available in daemon mode.

---

## lint_config

Lint CLAUDE.md and similar config files: verify file references exist, npm scripts are valid, and detect stale instructions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| cwd | string | **yes** | Project root directory |

**Notes:** Scans `CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md`, `.cursorrules`, and `.github/copilot-instructions.md`. Checks that backtick-wrapped file references actually exist on disk. Validates npm script references against `package.json`. Suggests similar filenames for missing references. Score: 100 - (errors x 10) - (warnings x 3) - (info x 1), minimum 0. Skips references inside fenced code blocks.

---

## get_insights

Get actionable cost optimization suggestions with savings estimates.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| since | string | no | ISO timestamp for start of analysis window. Default: 7 days ago |

**Notes:** Returns a formatted report with period summary (total spent, projected monthly), potential savings, and prioritized suggestions (high/medium/low severity). Each suggestion includes a title, detail, savings estimate, and top contributing items.

---

## file_activity

Show most frequently edited/read files across sessions for a project. Helps understand project activity patterns.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| project | string | no | Filter by project name |
| since | string | no | ISO 8601 date filter |
| limit | number | no | Max results. Default 50 |

**Notes:** Returns file paths with edit/read counts aggregated across sessions.
