# Baseline Inventory

Stage0 baseline inventory from checked-in fixtures and current tests.

## Fixture Generation

```bash
rtk npm run generate:mcp-contract-fixtures
rtk npm run generate:fixtures
rtk npm run check:fixtures
```

`generate:mcp-contract-fixtures` rewrites:

- `tests/fixtures/mcp-contract.sqlite`
- `tests/fixtures/mcp-golden/`
- `tests/fixtures/mcp-runtime/`

Swift MCP parity verification:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Contract DB

Fixture DB: `tests/fixtures/mcp-contract.sqlite`.

Observed inventory from current checked-in fixture:

- Size: about 648 KB.
- Sessions: 25.
- FTS rows: 72 across 24 sessions.
- Insights: 11.
- Insight FTS rows: 11.
- Insight embeddings: all `has_embedding = 0`.
- Migration log rows: 3.
- Session index jobs: 0.

Coverage by source: `claude-code`, `codex`, `cursor`, `gemini-cli`, `iflow`, `windsurf`.

Coverage gaps relative to tool schema: no MCP-contract DB sessions for `opencode`, `qwen`, `kimi`, `cline`, `vscode`, `antigravity`, or `copilot`.

## Golden Files

Directory: `tests/fixtures/mcp-golden`.

Current JSON fixture count: 34.

Core files: `initialize.result.json`, `tools.json`, `stats.source.json`, `search.keyword.json`, `search.hybrid.keyword_only.json`, `search.semantic.short_query.json`, `get_context.engram.json`, `get_context.engram.with_memory.json`, `get_context.engram.abstract_environment.json`, `get_insights.empty.json`, `get_session.transcript.json`, `list_sessions.engram.json`, `get_costs.project.json`, `tool_analytics.tool.json`, `file_activity.engram.json`, `project_timeline.engram.json`, `project_list_migrations.recent.json`, `live_sessions.unavailable.json`, `get_memory.keyword.json`, `lint_config.fixture.json`, `export.transcript.json`, `handoff.empty.json`, `link_sessions.engram.json`, alias add/list/remove fixtures, `save_insight.text_only.json`, `project_review.fixture.json`, `project_recover.fixture.json`, `generate_summary.fixture.json`, and project dry-run/undo/batch fixtures.

Normalization rules:

- Random UUIDs in write-tool responses become `<generated-uuid>`.
- Timestamps come from fixed fixture rows.
- Contract tests must use `tests/fixtures/mcp-contract.sqlite`, never `~/.engram/index.sqlite`.

## Runtime Fixtures

Directory: `tests/fixtures/mcp-runtime`.

Coverage includes lint project files, link target, project-review home, transcript fixture, export home, write-home project operation fixtures, and `mcp-write.sqlite` copied from the contract DB during write-golden generation.

Adapter fixtures under `tests/fixtures` cover Antigravity, Claude Code, Codex, Copilot, Cursor, Gemini, iFlow, Kimi, Qwen, VS Code, and Windsurf sample/drift data.

## Performance Baseline

Node direct-tool baseline:

```bash
rtk ./node_modules/.bin/tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 50 --out docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Output: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`.

The capture script copies fixture DB/root to a temporary directory before measurement and validates canonical keys, numeric ranges, positive metrics, iteration count, and percentile ordering.

Compare-only command:

```bash
rtk ./node_modules/.bin/tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 50 --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

## Baseline Gaps

- No service-unavailable fixture directory.
- No vector-enabled semantic happy-path golden.
- No index-job rows in the contract DB.
- Watcher and non-watchable rescan behavior are not represented by MCP goldens.
- Validation/error coverage is incomplete across the public MCP surface.
