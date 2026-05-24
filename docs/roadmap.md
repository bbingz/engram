# Engram Roadmap

Canonical product-level pending-work list. Engineering tasks live in
`docs/TODO.md`; verification and low-priority follow-ups live in
`docs/followups.md`.

**2026-05-23 update:** every open item below was driven to resolution via TDD
against the **Swift product** (`macos/`). New Swift tests + a fixture-generator
parity update accompany each behavior change. TypeScript under `src/` remains
dev/reference only.

## Status table

| Area | Item | Verdict |
|------|------|---------|
| Workspace | `git_repos` never populated — Repos page dormant | **DONE** — `RepoDiscovery` populates it; wired into the service recent-scan |
| Indexing | Auto-generate title on new-session index (`generated_title` was NULL) | **DONE** — `SessionSnapshotWriter` derives it at index time |
| Search | `SearchView` semantic mode = false promise (no sqlite-vec) | **DONE** — `SearchMode.availableModes` restricts to keyword unless embeddings available |
| Search | `GlobalSearchOverlay` hardcoded "hybrid" | **DONE** — now requests keyword |
| Transcript | No "Copy entire conversation" in message context menu | **DONE** — added, backed by `TranscriptText.conversationText` |
| Transcript | Tool rows showed generic `TOOLS #N` | **DONE** — `ColorBarMessageView.displayLabel` surfaces `TOOL: <name>` |
| Session list | No column-visibility toggle UI | **DONE** — `columnsMenu` bound to `ColumnVisibilityStore` |
| Session list | `selectedProject` / `sortOrder` not persisted | **DONE** — persisted via `@AppStorage` + restore on appear |
| Perf | Service-layer `ISO8601DateFormatter` per-call | **DONE** — shared statics in `SwiftIndexer` + `EngramServiceCommandHandler` |
| Usage (PR5) | Real probe data flow unconfirmed | **DONE** — startup writes real 7-day usage shares for tracked CLI sources |
| Search | Semantic search still advertised in MCP | **DONE** — MCP search schema and runtime are keyword-only unless vector support exists |
| Session links | Manual parent link/unlink missing | **DONE** — service IPC + detail-view affordances support manual link/unlink |
| Runtime monitor | `live_sessions` returned unavailable | **DONE** — Swift service and MCP scan active local CLI session files |
| Insights | Cost optimization suggestions not computed | **DONE** — MCP insights derive actionable suggestions from spend distribution |
| Repo hygiene | `.superpowers/` committed by accident | **DONE** — untracked + gitignored (2026-05-23) |

## Verification (2026-05-23)

- New Swift tests, all green: `RepoDiscoveryTests` (3), `IndexAutoTitleTests` (3),
  `SearchModeTests` (2), `TranscriptLabelAndCopyTests` (4),
  `SessionListPersistenceTests` (2).
- Regression: full `EngramCoreTests` and `EngramServiceCore` suites pass;
  `EngramService` builds. App tests run under the developer signing identity
  (team `J25GS8J4XM` applied to host + test bundle).
- Indexer-parity fixture `tests/fixtures/indexer-parity/expected-db-checksums.json`
  updated for the new `generated_title`; `scripts/gen-indexer-parity-fixtures.ts`
  mirrors the Swift title derivation so the fixture stays regen-stable
  (`tests/scripts/stage2-fixture-generators.test.ts` still passes).

## PR5 usage probes — implementation result

Implemented in the Swift runtime. `WriterStartupUsageCollector` now computes
real 7-day cost-share snapshots from indexed `session_costs` for tracked CLI
providers (`claude-code`, `codex`, `gemini-cli`, `antigravity`, `opencode`),
writes `usage_snapshots`, and emits service usage events. The UI still degrades
correctly because `PopoverUsageSection` remains gated on real usage data.

## Open roadmap

No open roadmap items as of 2026-05-24.

## Closed on 2026-05-24

### Real usage probes

- **Module:** `macos/EngramCoreWrite/Indexing`, `macos/EngramService/Core`
- **Status:** done
- **Acceptance evidence:** `StartupUsageCollectorTests` covers tracked CLI
  usage rows and `usage_snapshots` persistence; `EngramServiceRunner` emits real
  usage service events.
- **Related files:** `macos/EngramCoreWrite/Indexing/StartupUsageCollector.swift`,
  `macos/EngramService/Core/EngramServiceRunner.swift`

### Semantic search and embeddings

- **Module:** MCP search
- **Status:** done
- **Acceptance evidence:** MCP search schema exposes only `keyword`; unsupported
  semantic/hybrid requests degrade with an explicit keyword-only warning.
- **Related files:** `macos/EngramMCP/Core/MCPToolRegistry.swift`,
  `macos/EngramMCP/Core/MCPDatabase.swift`

### Manual link/unlink and extra source ingest

- **Module:** session linking and adapters
- **Status:** done
- **Acceptance evidence:** service IPC supports manual parent link/unlink;
  session detail UI exposes confirm/dismiss/unlink actions; live-source coverage
  includes Codex, Claude Code, Gemini CLI, Antigravity, and OpenCode paths.
- **Related files:** `macos/EngramService/Core/EngramServiceCommandHandler.swift`,
  `macos/Shared/Service/EngramServiceClient.swift`,
  `macos/Engram/Views/SessionDetailView.swift`

### Live session monitor

- **Module:** MCP / runtime monitoring
- **Status:** done
- **Acceptance evidence:** Swift service and MCP `live_sessions` scan recent
  session artifacts with active/idle/recent activity levels; tests cover the
  service scanner and deterministic MCP empty-home behavior.
- **Related files:** `macos/EngramService/Core/EngramServiceReadProvider.swift`,
  `macos/EngramMCP/Core/MCPLiveSessionScanner.swift`,
  `macos/EngramMCP/Core/MCPToolRegistry.swift`

### Cost optimization insights

- **Module:** MCP / insights
- **Status:** done
- **Acceptance evidence:** `get_insights` computes model/source concentration
  and projected monthly spend suggestions from `session_costs`; golden tests
  cover the no-suggestion baseline.
- **Related files:** `macos/EngramMCP/Core/MCPInsightsTool.swift`,
  `macos/EngramMCP/Core/MCPDatabase.swift`
