# Node Behavior Snapshots

Stage0 source of truth is the current Node MCP/runtime implementation plus checked-in golden fixtures.

## Regeneration Commands

These rewrite fixtures and should be run only when intentionally updating reference output:

```bash
rtk npm run generate:mcp-contract-fixtures
rtk npm run generate:fixtures
rtk npm run check:fixtures
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

`generate:mcp-contract-fixtures` runs with `TZ=UTC` through `package.json`.

## MCP Surface

Node registers 26 public MCP tools from `src/index.ts`: `list_sessions`, `get_session`, `search`, `project_timeline`, `stats`, `get_context`, `export`, `generate_summary`, `manage_project_alias`, `link_sessions`, `get_memory`, `save_insight`, `get_costs`, `tool_analytics`, `handoff`, `live_sessions`, `lint_config`, `get_insights`, `file_activity`, `project_move`, `project_archive`, `project_undo`, `project_move_batch`, `project_list_migrations`, `project_recover`, `project_review`.

Golden tool-name parity lives in `tests/fixtures/mcp-golden/tools.json`.

## Write-Capable Tools

| Tool | Node behavior to preserve or replace |
|---|---|
| `generate_summary` | Daemon route updates summary; direct fallback writes `sessions.summary` |
| `manage_project_alias` | `list` is read-only; `add`/`remove` mutate aliases through daemon or direct DB fallback |
| `save_insight` | Writes insight text and optionally vector state |
| `link_sessions` | Creates symlink tree under requested target |
| `export` | Writes transcript under `$HOME/codex-exports` |
| `project_move` | Moves directories, patches session files, updates DB, creates aliases |
| `project_archive` | Moves directories into archive buckets and updates migration log |
| `project_undo` | Reverses committed moves |
| `project_move_batch` | Runs move/archive operations from YAML |

Read-only/diagnostic project tools are `project_list_migrations`, `project_recover`, and `project_review`.

Current Node single-writer behavior: mutating tools prefer daemon HTTP and fall back to direct writes only when daemon is unreachable and `mcpStrictSingleWriter` is not enabled. Swift target behavior should remove direct fallback and fail closed when service IPC is unavailable.

## Golden Coverage

Current goldens cover:

- Protocol/tool shape: `initialize.result.json`, `tools.json`.
- Read tools: stats, list/search/context/costs/analytics/file activity/timeline/memory/lint/review/session/handoff/recover.
- Write-capable tools with mocked daemon HTTP or deterministic setup: `save_insight`, alias add/remove, `generate_summary`, dry-run project ops, undo fixture, batch dry-run.
- Filesystem-output tools: `link_sessions.engram`, `export.transcript`.

Swift executable tests use `ENGRAM_MCP_DB_PATH=tests/fixtures/mcp-contract.sqlite` and per-test `HOME` overrides for runtime fixtures.

## Search And Context Behavior

- UUID search performs direct session lookup and returns `searchModes: ["id"]`.
- Keyword FTS runs when `mode !== "semantic"` and query length is at least 3.
- Semantic/vector runs only when `mode !== "keyword"`, query length is at least 2, and both vector store plus embedder exist.
- Hybrid merges FTS and vector scores with reciprocal-rank fusion; `matchType` is `keyword`, `semantic`, or `both`.
- Without vector deps, hybrid calls fall back to keyword-only when possible and warn that embeddings are unavailable.
- Short semantic query fixture uses query `ab`, no vector deps, `searchModes: []`, and the keyword length warning.
- CJK FTS falls back to `LIKE`.
- `get_context` resolves project aliases from `cwd` basename, falls back to full `cwd`, supports `sort_by: "score"`, and uses vector insights first with FTS insight fallback for task length >= 3.
- `include_environment: false` returns only context/memory/session text; `include_environment: true` currently appends best-effort environment text rather than a typed degraded service state.

## Indexing And Watcher Behavior

- `SessionSnapshotWriter` queues FTS when `search_text_changed` and tier is not `skip`.
- It queues embedding when `embedding_text_changed` and tier is `normal` or `premium`.
- `IndexJobRunner` processes up to 50 recoverable jobs and orders FTS before embedding.
- FTS jobs preserve existing full-message FTS content and only fall back to summary/project/model when no FTS rows exist.
- Embedding jobs remain pending without provider, become `not_applicable` with no readable text, and write session plus chunk vectors when provider exists.
- Watched sources: `codex`, `claude-code`, `gemini-cli`, `antigravity`, `iflow`, `qwen`, `kimi`, `cline`, plus derived `lobsterai` and `minimax`.
- Watcher uses `ignoreInitial: true`, `followSymlinks: false`, `awaitWriteFinish` with 2000 ms stability, and skips paths during pending project moves.
- Non-watchable rescan interval is `10 * 60 * 1000 * POWER_MULTIPLIER`; battery doubles it. Rescan emits `{ event: "rescan", indexed, total, todayParents }` only when `indexed > 0`.

## Snapshot Gaps

- No golden set for every validation/error path.
- No service-unavailable golden directory for mutating tools.
- No typed degraded `get_context` fixture.
- No vector-enabled semantic search golden.
- `mcp-contract.sqlite` has no `session_index_jobs` rows.
- Non-watchable rescan and watcher semantics are code-inspected, not MCP-golden-backed.
