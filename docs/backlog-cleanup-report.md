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

After owner decisions and follow-through on 2026-05-24, `docs/TODO.md` and
`docs/followups.md` have no open items.

## Cleanup counts

| Action | Count | Notes |
|---|---:|---|
| Migrated into `docs/roadmap.md` | 5 | Real usage probes; semantic search/embeddings; manual link-unlink and extra source ingest; live session monitor; cost optimization insights. |
| Completed TODO items | 9 | Signing config, MCP claims, service degraded status SLA, TypeScript route split, Swift CLI resume, smart dirty-worktree policy, oversized JSONL streaming, and live-update SSE. |
| Migrated into `docs/TODO.md` after owner confirmation | 4 | All four were completed in the follow-through pass. |
| Migrated into `docs/followups.md` | 5 | All five were completed or covered by targeted verification in the follow-through pass. |
| Closed follow-up items | 9 | Runtime checks, schema intent, session-classification refactor evidence, NFC/NFD reference-search fix, UI smoke, `fs_done` recover probe, large-data batch smoke, archive boundary corpus, and UndoSheet/CAS verification. |
| Deleted historical backlog files | 27 | Removed stale `tasks/`, `plans/`, root review/progress/handoff files, and non-archive superpowers plan files. |
| Removed code comment backlog markers | 3 | Cleared project-move smart-stash, oversized JSONL streaming, and live SSE comments after classification. |
| Rewrote stale documentation references | 6 | Removed obsolete MCP stdio semaphore limitation, stale changelog TODO wording, and live references to deleted historical files. |

## Completed TODO evidence

| Item | Resolution | Evidence |
|---|---|---|
| Pin test target signing team | `EngramTests` now pins the same `DEVELOPMENT_TEAM` as the host app in `macos/project.yml`; `xcodegen generate` refreshed `Engram.xcodeproj`. | `AppSearchServiceCutoverScanTests.testEngramAppHostedTestsPinSameDevelopmentTeamAsHostApp`; selected `xcodebuild test -scheme Engram` passed without command-line `DEVELOPMENT_TEAM`. |
| Make `get_insights` honest or actionable | MCP description/output no longer promises computed savings suggestions. | `MCPToolRegistry.swift`, `MCPInsightsTool.swift`; `testMcpToolDescriptionsDoNotPromiseUnavailableCapabilities`, `testMcpInsightsOutputDoesNotClaimSuggestionsWereComputed`. |
| Resolve `live_sessions` MCP contract | MCP description states live monitoring is unavailable in MCP mode. | `MCPToolRegistry.swift`; `testMcpToolDescriptionsDoNotPromiseUnavailableCapabilities`. |
| Add service-side degraded status SLA | Service status now tracks scan failure and stale successful scan age via `ServiceStatusMonitor`. | `EngramServiceIPCTests.testStatusCommandReportsDegradedAfterIndexFailure`, `testStatusCommandReportsDegradedWhenLastSuccessfulScanIsStale`. |
| Split TypeScript web routes | Project migration HTTP routes moved from `src/web.ts` to `src/web/routes/project-migrations.ts`; `src/web.ts` reduced from 1678 to 1393 lines. | `tests/web/route-modules.test.ts`, `tests/web/project-api.test.ts`, `tests/web/daemon-http-contract.test.ts`. |
| Add Swift CLI resume command | `EngramCLI resume <session-id>` and legacy `--resume` route through `EngramServiceClient.resumeCommand`, with shell and JSON output modes. | `EngramCLIResumeCommandTests`; `xcodebuild build -scheme EngramCLI`. |
| Add smart dirty-worktree policy | Project moves now allow untracked-only git state without `force` while tracked modifications, including whitespace-only edits, remain force-gated. | `OrchestratorTests.testUntrackedOnlyGitStateProceedsWithoutForce`, `testWhitespaceOnlyTrackedGitStateRequiresForce`; TypeScript orchestrator integration twins. |
| Add streaming patch support for oversized JSONL | JSONL patching streams files above the previous 128 MiB in-memory cap through a temp file, with stronger dev/inode/size/mtime CAS and directory fsync. Default source walking no longer skips large files. | `JsonlPatchTests.testPatchFileStreamsFilesLargerThanOldInMemoryCap`; `SessionSourcesTests.testWalkDoesNotApplyOld128MiBCapByDefault`; TypeScript twin tests. |
| Add SSE transport for live updates | `/api/live/events` emits an SSE `live` event while `/api/live` remains the polling fallback and both share one payload builder. | `tests/web/server.test.ts` `GET /api/live/events returns SSE live session event using the same payload shape`; `/api/live` fallback test. |

## Follow-up classification evidence

| Item | Resolution | Evidence |
|---|---|---|
| Verify Gemini cross-validation omissions | Closed as verified/covered. App Sandbox is not enabled (`Engram.entitlements` is empty), service is a helper child process with health monitoring/backoff, large JSONL reads use `StreamingJSONLReader`, and UI refresh strategy is event/poll based. | `macos/Engram/Engram.entitlements`, `EngramServiceLauncher.swift`, `StreamingJSONLReader.swift`, `ServiceEventRoutingTests`. |
| Decide Swift CLI resume scope | Promoted to confirmed TODO after owner decision. | `docs/TODO.md`. |
| Confirm `insights.deleted_at` intent | Closed as intentional legacy migration support: v2 insight migration filters old `deleted_at` rows out and removes their FTS entries; current `insights` table no longer carries `deleted_at`. | `EngramMigrations.migrateInsightsToV2`; `MigrationRunnerTests` legacy deleted insight migration coverage. |
| Smoke test ProjectsView | Closed with app-hosted UI smoke coverage for the global undo entry and row-level migration context menu. | `ProjectsTests.testProjectMigrationControlsAreReachable`; `ProjectsScreen` undo control identifier. |
| Exercise project rename committed flow | Covered by the same Projects UI smoke plus existing service/core committed project-move tests. | `ProjectsTests.testProjectMigrationControlsAreReachable`; project-move service/core tests. |
| Cover `project_recover` fs_done path end-to-end | Closed with a real filesystem `fs_done` diagnostic probe using absent old path and present new path. | `RecoverMigrationsTests.testFsDoneDiagnosisUsesRealFilesystemProbe`. |
| Run batch moves on larger real data | Closed with sparse >128 MiB JSONL batch smoke through the Swift batch runner and project-move pipeline. | `BatchTests.testRunPatchesLargeJsonlSessionFile`. |
| Expand archive heuristic samples | Closed with additional hidden-file-only boundary coverage on top of existing empty, README-only, date-prefix, git-dir, git-file worktree, force, and ambiguous cases. | `ArchiveTests.testHiddenFilesOnlyDirectorySuggestsEmptyProject`; existing archive tests. |
| Consolidate session classification logic | Closed as roadmap-level refactor already documented in the 2026-05-22 closeout; no open TODO until behavior changes are specified. | `docs/reviews/2026-05-22-remediation-closeout.md`; `SessionTierTests`; adapter parity tests. |
| Improve UndoSheet keyboard and CAS precision | Closed: `UndoSheet` now supports arrow-key selection/focus and row identifiers; JSONL patch CAS compares device, inode, size, and nanosecond mtime in Swift plus dev/ino/size/mtime in TypeScript. | `UndoSheet.swift`; `JsonlPatch.swift`; `jsonl-patch.ts`. |
| Normalize project-move reference search | Fixed: `findReferencingFiles` now searches NFC and NFD needles in TypeScript and Swift, with tests for both caller/file normalization directions. | `tests/core/project-move/sources.test.ts`; `SessionSourcesTests`. |
| Add smart dirty-worktree handling | Promoted to confirmed TODO after owner decision; untracked-only becomes the safe path, tracked changes remain force-gated. | `docs/TODO.md`. |
| Stream oversized JSONL patching | Promoted to confirmed TODO after owner decision. | `docs/TODO.md`. |
| Add live-session SSE endpoint | Promoted to confirmed TODO after owner decision. | `docs/TODO.md`. |

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

None.

## Verification

Commands run during cleanup:

```bash
xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests/AppSearchServiceCutoverScanTests/testEngramAppHostedTestsPinSameDevelopmentTeamAsHostApp -only-testing:EngramTests/AppSearchServiceCutoverScanTests/testMcpToolDescriptionsDoNotPromiseUnavailableCapabilities -only-testing:EngramTests/AppSearchServiceCutoverScanTests/testMcpInsightsOutputDoesNotClaimSuggestionsWereComputed
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testStatusCommandReportsDegradedAfterIndexFailure -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testStatusCommandReportsDegradedWhenLastSuccessfulScanIsStale
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS'
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/SessionSourcesTests/testFindMatchesNfdPathTextWhenCallerPassesNfcNeedle
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests/EngramCLIResumeCommandTests -only-testing:EngramUITests/ProjectsTests/testProjectMigrationControlsAreReachable
xcodebuild build -project macos/Engram.xcodeproj -scheme EngramCLI -destination 'platform=macOS'
npm run build
npm run lint
npm test -- tests/core/project-move/sources.test.ts tests/web/route-modules.test.ts tests/web/project-api.test.ts tests/web/daemon-http-contract.test.ts
npm test -- tests/core/project-move/jsonl-patch.test.ts tests/core/project-move/orchestrator.integration.test.ts tests/core/project-move/sources.test.ts tests/web/server.test.ts
git grep -n -I -E 'TODO|FIXME|XXX|HACK' -- . ':!docs/**' ':!macos/build/**' ':!node_modules/**' ':!package-lock.json' ':!package.json'
find . -path './.git' -prune -o -path './node_modules' -prune -o -path './macos/build' -prune -o -path './docs/archive' -prune -o -path './.claude' -prune -o -type f \( -iname '*todo*.md' -o -iname '*roadmap*.md' -o -iname '*followup*.md' -o -iname '*follow-up*.md' -o -iname '*backlog*.md' -o -iname '*plan*.md' -o -iname '*issues*.md' \) -print | sort
```

Results:

- Selected app-hosted Engram tests passed after signing fix.
- EngramCoreTests passed: 293 tests.
- EngramServiceCore passed after fixing the full-suite status regression: 72 tests.
- Selected app-hosted Engram tests passed after signing fix: 3 tests.
- Swift CLI resume command tests passed: 4 tests.
- Projects UI migration-control smoke passed: 1 UI test.
- EngramCLI build passed.
- TypeScript build passed.
- Biome lint passed: 268 files checked.
- Web/project route and project-move source scan regression tests passed: 50 tests.
- Project-move streaming/dirty/source and live SSE TypeScript regressions passed:
  153 tests.
- No code `TODO` / `FIXME` / `XXX` / `HACK` markers remain outside docs, build
  output, node modules, lockfiles, and package metadata.
- Non-archive backlog-style Markdown filenames are limited to
  `docs/backlog-audit-2026-05-24.md`, `docs/backlog-cleanup-report.md`,
  `docs/followups.md`, `docs/roadmap.md`, and `docs/TODO.md`.
