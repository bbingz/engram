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
| Usage (PR5) | Real probe data flow unconfirmed | **INVESTIGATED — not a defect** (see below) |
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

## PR5 usage probes — investigation result

Not a defect. `usage_snapshots` is created by migration but never written, the
runtime uses `NoopStartupUsageCollector`, and no `"usage"` service event carries
real data. The UI already degrades correctly: `PopoverUsageSection` is gated on
`!usageData.isEmpty`, so it renders nothing rather than empty/fake bars. Wiring
real Claude-OAuth / Codex-tmux probes is **net-new feature work** (external
integrations), deliberately deferred — not a bug in the current surface.

## Open roadmap

### Real usage probes

- **Module:** `macos/EngramCoreWrite/Indexing`, `macos/Engram/Views`
- **Type:** roadmap
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** Claude-OAuth and Codex-tmux collectors write real rows into
  `usage_snapshots`; the popover usage section renders only when real data is
  present; tests cover the no-data and data-present paths.
- **Related files:** `macos/EngramCoreWrite/Indexing/StartupComposition.swift`,
  `macos/EngramService/Core/EngramServiceRunner.swift`
- **Status:** open

### Semantic search and embeddings

- **Module:** search, memory, embeddings
- **Type:** roadmap
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** Swift runtime either implements vector-backed semantic search
  with a tested embedding provider or keeps the feature fully absent from UI,
  docs, and MCP descriptions.
- **Related files:** `macos/EngramMCP/Core/MCPDatabase.swift`,
  `macos/Engram/Views/Pages/SearchPageView.swift`
- **Status:** open

### Manual link/unlink and extra source ingest

- **Module:** session linking and adapters
- **Type:** roadmap
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** manual parent link/unlink has service commands, UI affordance,
  and tests; Windsurf and Antigravity ingest either has real live/cache coverage
  or remains explicitly out of scope.
- **Related files:** `macos/EngramService/Core/EngramServiceCommandHandler.swift`,
  `macos/EngramCoreWrite/Indexing`
- **Status:** open

### Live session monitor

- **Module:** MCP / runtime monitoring
- **Type:** roadmap
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** `live_sessions` returns real active-session observations from
  the Swift runtime, or the tool remains explicitly documented as unavailable in
  MCP mode.
- **Related files:** `macos/EngramMCP/Core/MCPToolRegistry.swift`,
  `macos/EngramMCP/Core/MCPSessionTools.swift`
- **Status:** open

### Cost optimization insights

- **Module:** MCP / insights
- **Type:** roadmap
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** `get_insights` computes tested optimization suggestions from
  real spend/session data, or continues to report only the current spend summary
  without promising suggestions.
- **Related files:** `macos/EngramMCP/Core/MCPInsightsTool.swift`,
  `macos/EngramMCP/Core/MCPToolRegistry.swift`
- **Status:** open
