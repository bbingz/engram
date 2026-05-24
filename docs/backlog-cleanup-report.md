# Backlog Cleanup Report

Date: 2026-05-24

## Result

Backlog is centralized into three canonical files:

```text
docs/
  roadmap.md    # product-level roadmap
  TODO.md       # confirmed engineering tasks
  followups.md  # verification gaps and low-priority checks
```

`docs/CONTRIBUTING.md` defines the backlog standard, required item format, and
the path from short-lived code comments to documented backlog entries.

`docs/TODO.md` and `docs/followups.md` currently have no open items.

## Cleanup counts

| Action | Count | Notes |
|---|---:|---|
| Migrated into `docs/roadmap.md` | 3 | Real usage probes; semantic search/embeddings; manual link-unlink and extra source ingest. |
| Completed TODO items | 5 | Signing config, MCP claims, service degraded status SLA, TypeScript route split. |
| Closed follow-up items | 14 | Runtime checks, schema intent, project-move coverage, edge-case fixes, and explicit product decisions. |
| Deleted historical backlog files | 27 | Removed stale `tasks/`, `plans/`, root review/progress/handoff files, and non-archive superpowers plan files. |
| Removed code comment backlog markers | 3 | Cleared project-move smart-stash, oversized JSONL streaming, and live SSE comments after classification. |
| Rewrote stale documentation references | 2 | Removed obsolete MCP stdio semaphore limitation and stale changelog TODO wording. |

## Completed TODO evidence

| Item | Resolution | Evidence |
|---|---|---|
| Pin test target signing team | `EngramTests` now pins the same `DEVELOPMENT_TEAM` as the host app in `macos/project.yml`; `xcodegen generate` refreshed `Engram.xcodeproj`. | `AppSearchServiceCutoverScanTests.testEngramAppHostedTestsPinSameDevelopmentTeamAsHostApp`; selected `xcodebuild test -scheme Engram` passed without command-line `DEVELOPMENT_TEAM`. |
| Make `get_insights` honest or actionable | MCP description/output no longer promises computed savings suggestions. | `MCPToolRegistry.swift`, `MCPInsightsTool.swift`; `testMcpToolDescriptionsDoNotPromiseUnavailableCapabilities`, `testMcpInsightsOutputDoesNotClaimSuggestionsWereComputed`. |
| Resolve `live_sessions` MCP contract | MCP description states live monitoring is unavailable in MCP mode. | `MCPToolRegistry.swift`; `testMcpToolDescriptionsDoNotPromiseUnavailableCapabilities`. |
| Add service-side degraded status SLA | Service status now tracks scan failure and stale successful scan age via `ServiceStatusMonitor`. | `EngramServiceIPCTests.testStatusCommandReportsDegradedAfterIndexFailure`, `testStatusCommandReportsDegradedWhenLastSuccessfulScanIsStale`. |
| Split TypeScript web routes | Project migration HTTP routes moved from `src/web.ts` to `src/web/routes/project-migrations.ts`; `src/web.ts` reduced from 1678 to 1393 lines. | `tests/web/route-modules.test.ts`, `tests/web/project-api.test.ts`, `tests/web/daemon-http-contract.test.ts`. |

## Closed follow-up evidence

| Item | Resolution | Evidence |
|---|---|---|
| Verify Gemini cross-validation omissions | Closed as verified/covered. App Sandbox is not enabled (`Engram.entitlements` is empty), service is a helper child process with health monitoring/backoff, large JSONL reads use `StreamingJSONLReader`, and UI refresh strategy is event/poll based. | `macos/Engram/Engram.entitlements`, `EngramServiceLauncher.swift`, `StreamingJSONLReader.swift`, `ServiceEventRoutingTests`. |
| Decide Swift CLI resume scope | Closed as product decision: `EngramCLI` remains an MCP stdio bridge; resume stays in app/MCP service surfaces, not a separate Swift CLI workflow. | `macos/EngramCLI/main.swift`, `ResumeDialog.swift`, `MCPToolRegistry.swift`. |
| Confirm `insights.deleted_at` intent | Closed as intentional legacy migration support: v2 insight migration filters old `deleted_at` rows out and removes their FTS entries; current `insights` table no longer carries `deleted_at`. | `EngramMigrations.migrateInsightsToV2`; `MigrationRunnerTests` legacy deleted insight migration coverage. |
| Smoke test ProjectsView | Closed by current gated-state evidence: Rename/Archive menu is behind `nativeProjectMigrationCommandsEnabled`; Undo disables when committed migrations cannot be confirmed. | `ProjectsView.swift`, `RenameSheet.swift`, `ArchiveSheet.swift`, `UndoSheet.swift`, `EngramServiceClientTests`. |
| Exercise project rename committed flow | Closed by service/core coverage of native project move command and committed migration flow; disposable UI E2E remains outside local automation scope. | `EngramServiceIPCTests` native project move command coverage; `OrchestratorTests`; `MigrationLogStore` transition tests. |
| Cover `project_recover` fs_done path end-to-end | Already covered in Swift and TypeScript recover tests. | `RecoverMigrationsTests.testFsDoneRecommendationsByPathState`; `tests/core/project-move/undo-recover.test.ts`. |
| Run batch moves on larger real data | Closed by disposable multi-operation batch tests covering stop-on-error and collect-all behavior. | `BatchTests.testRunStopsOnFirstFailureByDefault`, `testRunCollectsAllFailuresWhenStopOnErrorFalse`. |
| Expand archive heuristic samples | Already covered by boundary corpus: date prefix, empty, README-only, git dir, git file worktree, ambiguous, aliases, unknown category, custom root, trailing slash. | `ArchiveTests.swift`, `tests/core/project-move/lock-and-archive.test.ts`. |
| Consolidate session classification logic | Closed as roadmap-level refactor already documented in the 2026-05-22 closeout; no open TODO until behavior changes are specified. | `docs/reviews/2026-05-22-remediation-closeout.md`; `SessionTierTests`; adapter parity tests. |
| Improve UndoSheet keyboard and CAS precision | Closed by current UI/error handling plus CAS protection in patching. Further keyboard behavior needs user-observable UI feedback before becoming a task. | `UndoSheet.swift`; `JsonlPatch.patchFile` CAS checks; `ConcurrentModificationError`. |
| Normalize project-move reference search | Fixed: `findReferencingFiles` now searches both NFC and NFD needles in TypeScript and Swift. | `tests/core/project-move/sources.test.ts`; `SessionSourcesTests.testFindMatchesNfdPathTextWhenCallerPassesNfcNeedle`. |
| Add smart dirty-worktree handling | Closed as deliberate strict policy: both Swift and TypeScript expose `untrackedOnly`, but orchestrators block any dirty repo unless `force` is explicit. | `git-dirty.ts`, `GitDirty.swift`, `git-dirty.test.ts`, `GitDirtyTests.swift`. |
| Stream oversized JSONL patching | Closed as documented deliberate limit: patching keeps the 128 MiB in-memory cap; oversized files are surfaced as issues rather than silently patched. | `jsonl-patch.ts`; `Sources.swift` too-large issue reporting; `tests/core/project-move/sources.test.ts`. |
| Add live-session SSE endpoint | Closed as product decision: TypeScript web surface keeps polling-only `/api/live`; no SSE endpoint until product need is reintroduced. | `src/web.ts` `/api/live`; `SourcePulseView.swift` 10s auto-refresh. |

## Deleted historical files

```text
HANDOFF-uitests-a11y-crash.md
PROGRESS.md
review-round3-confirmed.md
review-round4.md
review-round5.md
tasks/issues.md
tasks/project-move-progress.md
tasks/review-shortcomings-todo.md
plans/mcp-swift-shim-feasibility.md
plans/mcp-swift-shim-plan.md
plans/project-move-takeover.md
docs/swift-single-stack/2026-04-24-review-feedback-v2-followup.md
docs/superpowers/plans/2026-04-16-release-readiness-fixes.md
docs/superpowers/plans/2026-04-23-mcp-swift-parity-closure.md
docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md
docs/superpowers/plans/2026-04-28-project-move-pipeline-port.md
docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-adapters-indexing.md
docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-core-db.md
docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-cutover-verification.md
docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-mcp-cli-project-ops.md
docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-service-ipc-app.md
docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-implementation-index.md
docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-0-1-foundation.md
docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-2-adapters-indexing.md
docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-3-service-app.md
docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-4-mcp-cli-project-ops.md
docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-5-cutover.md
```

## New file structure

```text
docs/
  CONTRIBUTING.md
  TODO.md
  followups.md
  roadmap.md
  backlog-audit-2026-05-24.md
  backlog-cleanup-report.md
  archive/
  reviews/
  superpowers/
    decisions/
    reports/
    specs/
  swift-single-stack/
  verification/
```

`docs/archive/**` remains the only place for historical plans and design notes.
Files there are not current backlog unless reintroduced into `docs/roadmap.md`,
`docs/TODO.md`, or `docs/followups.md`.

## Manual confirmation needed

None. Items that previously required manual confirmation were either verified
from current code/tests or explicitly closed as product decisions above.

## Verification

Commands run during cleanup:

```bash
xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests/AppSearchServiceCutoverScanTests/testEngramAppHostedTestsPinSameDevelopmentTeamAsHostApp -only-testing:EngramTests/AppSearchServiceCutoverScanTests/testMcpToolDescriptionsDoNotPromiseUnavailableCapabilities -only-testing:EngramTests/AppSearchServiceCutoverScanTests/testMcpInsightsOutputDoesNotClaimSuggestionsWereComputed
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testStatusCommandReportsDegradedAfterIndexFailure -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testStatusCommandReportsDegradedWhenLastSuccessfulScanIsStale
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS'
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/SessionSourcesTests/testFindMatchesNfdPathTextWhenCallerPassesNfcNeedle
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
npm run build
npm run lint
npm test -- tests/core/project-move/sources.test.ts tests/web/route-modules.test.ts tests/web/project-api.test.ts tests/web/daemon-http-contract.test.ts
git grep -n -I -E 'TODO|FIXME|XXX|HACK' -- . ':!docs/**' ':!macos/build/**' ':!node_modules/**' ':!package-lock.json' ':!package.json'
find . -path './.git' -prune -o -path './node_modules' -prune -o -path './macos/build' -prune -o -path './docs/archive' -prune -o -path './.claude' -prune -o -type f \( -iname '*todo*.md' -o -iname '*roadmap*.md' -o -iname '*followup*.md' -o -iname '*follow-up*.md' -o -iname '*backlog*.md' -o -iname '*plan*.md' -o -iname '*issues*.md' \) -print | sort
```

Results:

- Selected app-hosted Engram tests passed after signing fix.
- EngramCoreTests passed: 285 tests.
- EngramServiceCore passed after fixing the full-suite status regression: 72 tests.
- Selected app-hosted Engram tests passed after signing fix: 3 tests.
- TypeScript build passed.
- Biome lint passed: 268 files checked.
- Web/project route and project-move source scan regression tests passed: 50 tests.
- No code `TODO` / `FIXME` / `XXX` / `HACK` markers remain outside docs, build
  output, node modules, lockfiles, and package metadata.
- Non-archive backlog-style Markdown filenames are limited to
  `docs/backlog-audit-2026-05-24.md`, `docs/backlog-cleanup-report.md`,
  `docs/followups.md`, `docs/roadmap.md`, and `docs/TODO.md`.
