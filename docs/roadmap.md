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
| Session list | No column-visibility toggle UI | **REMOVED** — implementation deleted with unreachable legacy `SessionListView` in `322f5095` (2026-06-12 audit remediation); obsolete for card-based `SessionsPageView` (no columns); guarded by `testUnreachableLegacySessionListViewIsRemoved` |
| Session list | `selectedProject` / `sortOrder` not persisted | **REGRESSED** — persistence deleted with `SessionListView` in `322f5095`; reopened as wave-6 task 3 (persist `SessionsPageView` filters; sort is hardcoded `.updatedDesc`, so `sortOrder` no longer applies) |
| Perf | Service-layer `ISO8601DateFormatter` per-call | **DONE** — shared statics in `SwiftIndexer` + `EngramServiceCommandHandler` |
| Usage (PR5) | Real probe data flow unconfirmed | **DONE** — startup writes real 7-day usage shares for tracked CLI sources |
| Search | Semantic search still advertised in MCP | **DONE** — MCP search schema and runtime are keyword-only unless vector support exists |
| Session links | Manual parent link/unlink missing | **DONE** — service IPC + detail-view affordances support manual link/unlink |
| Runtime monitor | `live_sessions` returned unavailable | **DONE** — Swift service/app IPC scan active local CLI session files; MCP mode keeps an explicit unavailable contract |
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

No open roadmap product items as of 2026-05-24. See the decision-pending
table below for items parked by the 2026-07-09 plan-completion audit.

## Decision pending (2026-07-09 plan-completion audit)

Large product-decision items the audit confirmed **not done** and deliberately
**not** implemented in wave 6. Each needs an explicit product decision before
scheduling.

| Item | Source | Audit status | Size estimate | Decision needed |
|------|--------|--------------|---------------|-----------------|
| Lifecycle 3.1 multi-factor value score (+ P0-6 measurement-script prerequisite) | `docs/engram-lifecycle-upgrade-plan.md` §3.1 | not_done | L (2–3d + measurement) | Whether to evolve `quality_score` formula and expose bands in GUI |
| Lifecycle 3.4 BM25/CJK ranking + faceting | `docs/engram-lifecycle-upgrade-plan.md` §3.4 | not_done | L (3–4d) | Whether human search ranking upgrade is next after MCP semantic |
| Lifecycle 3.5 tool-result normalization + structured summary job | `docs/engram-lifecycle-upgrade-plan.md` §3.5 | not_done | XL (~15 adapters + summary job) | Accept adapter regression surface vs keep lossy tool results |
| P0.5 value-band badge on session cards + `value_override` | `docs/engram-lifecycle-upgrade-plan.md` §3.1 / P0.5 | not_done | M (~1d after score parity) | Whether to show quality bands before multi-factor scoring |
| Insight supersession via embedding cosine > 0.92 | `docs/p1-semantic-memory-design-2026-06.md` §d | partial (text match only) | M | Whether cosine supersession is required once embeddings are common |
| P2 auto insight extraction | `docs/engram-lifecycle-upgrade-plan.md` §3.5; p1 design | not_done | L | Opt-in LLM mining of finished sessions into `insights` |
| F2 sqlite-vec native target | `docs/p1-semantic-memory-design-2026-06.md` F2 | not_done / superseded by brute-force | XL (native dep + notarization) | Revisit only if brute-force KNN becomes a measured bottleneck |
| F3/f corpus mining (`mined_rules`) | p1 design §f; removed feature-cut item 3 | not_done (surface deleted 2026-07-06) | L | Whether to reintroduce rule mining after feature-cut |
| Competitive-relaunch P0 (Claude Code plugin; Homebrew/Sparkle distribution) | `docs/competitive-relaunch-2026-06.md` | not_done | XL | Distribution / plugin strategy for relaunch |
| `ai_audit_log` desensitization design | lifecycle §3.5 P0; no Swift writer today | not_done | M (design) then L | Design body redaction **before** any Swift audit-log writer lands (wave-6 task 9 descope) |
| Provider-branch valuable-missing features (Grok/Pi adapters, session taxonomy filter, runtime capability gates) | `docs/reviews/provider-audit-branch-reconciliation-2026-07.md` | not_done | L each | Branch `codex-provider-audit-remediation` deleted local+origin 2026-07-09 after three-model adjudication; recovery path is archive tag `archive/codex-provider-audit-remediation` (`285453d7`) + the reconciliation doc |
| Sources-sync-3 nav consolidation | `docs/reviews/alignment-design-2026-06-14.md` ~:836,:896 | not_done (explicitly deferred) | M | Whether Sources/Settings nav consolidation is still wanted |

## Closed on 2026-06-20

### Remote session offload (self-hosted)

- **Module:** `macos/EngramRemoteServer`, `macos/EngramCoreWrite/RemoteSync`,
  `macos/EngramService/Core` (`RemoteSyncCoordinator`)
- **Status:** done (opt-in, default OFF)
- **Acceptance evidence:** offloads regenerable artifacts (`sessions_fts` +
  summary, AES-GCM encrypted) of cold/archived sessions to a self-hosted
  `engram-remote` server, keeping a keyword shadow and rehydrating on access; raw
  transcripts never move. `EngramRemoteServerCoreTests`, `RemoteOffloadTests`,
  `RemoteSyncCoordinatorTests` (incl. the gated
  `testLiveOffloadRehydrateAgainstDeployedServer`) pass; deployed to a Tailscale
  host behind an nginx TLS proxy and exercised end-to-end (5 offloads + rehydrate)
  through the running app.
- **Operations:** `docs/remote-offload.md`. The live app must reach the server
  over a **Tailscale IP** — the background helper is blocked from the LAN by macOS
  Local Network Privacy.
- **Related files:** `macos/EngramRemoteServer/Core/*`,
  `macos/EngramCoreWrite/RemoteSync/*`,
  `macos/EngramService/Core/RemoteSyncCoordinator.swift`,
  `macos/EngramService/Core/EngramServiceCommandHandler+RemoteSync.swift`

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
- **Acceptance evidence:** Swift service/app IPC live-session scanning reports
  recent session artifacts with active/idle/recent activity levels. MCP mode
  intentionally returns an explicit unavailable result so clients do not mistake
  the tool for a live monitor.
- **Related files:** `macos/EngramService/Core/EngramServiceReadProvider.swift`,
  `macos/Shared/Service/EngramServiceClient.swift`,
  `macos/EngramMCP/Core/MCPToolRegistry.swift`

### Cost optimization insights

- **Module:** MCP / insights
- **Status:** done
- **Acceptance evidence:** `get_insights` computes model/source concentration
  and projected monthly spend suggestions from `session_costs`; golden tests
  cover the no-suggestion baseline.
- **Related files:** `macos/EngramMCP/Core/MCPInsightsTool.swift`,
  `macos/EngramMCP/Core/MCPDatabase.swift`

## Closed on 2026-06-15

### UX flow alignment — wire the macOS UI to the service backend (20 WP, PR #74)

- **Module:** `macos/Engram/Views`, `macos/Engram/Models/Screen.swift`,
  `macos/EngramService/Core`
- **Status:** done
- **Acceptance evidence:** a 28-surface UI/UX flow review (144 findings) drove a
  20-work-package alignment so isolated surfaces walk end-to-end. Sidebar is
  grouped (OVERVIEW / MONITOR / WORKSPACE / CONFIG) with a `⌘K` command palette;
  Observability is gated behind `showDeveloperTools` (default off); Hygiene,
  Repos/Work Graph, Skills/Agents/Memory/Hooks, and Sources pages read live
  service data. Two adversarial review rounds (Claude + Codex). CI green incl.
  `swift-unit` and `ui-test-full` (UI tests reach Observability via
  `-showDeveloperTools YES`).

### GRDB linked once as a shared dynamic framework (PR #75)

- **Module:** `macos/project.yml`, `macos/scripts/copy-service-helper.sh`
- **Status:** done
- **Acceptance evidence:** `EngramService` crash-looped on a GRDB
  `SchedulingWatchdog` wrong-thread SIGTRAP because the static `GRDB` product was
  embedded into all three frameworks the process loads (three watchdog
  registries). Switched every target to the dynamic `GRDB-dynamic` product (one
  shared copy). `EngramServiceCoreTests` 177/177 locally with zero thread-crashes
  (these could not run on the author's host before); live service ran >2 min with
  zero new crash reports.
