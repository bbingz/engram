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

`docs/TODO.md` has no open confirmed engineering tasks. `docs/followups.md`
keeps non-blocking verification and product-confirmation gaps open rather than
closing them without matching UI/E2E or real-data evidence.

## Cleanup counts

| Action | Count | Notes |
|---|---:|---|
| Migrated into `docs/roadmap.md` | 5 | Real usage probes; semantic search/embeddings; manual link-unlink and extra source ingest; live session monitor; cost optimization insights. |
| Completed TODO items | 5 | Signing config, MCP claims, service degraded status SLA, TypeScript route split. |
| Migrated into `docs/followups.md` | 9 | UI/manual smoke, project-move E2E, real-data/boundary coverage, CLI and policy confirmations. |
| Closed follow-up items | 4 | Runtime checks, schema intent, session-classification refactor evidence, and NFC/NFD reference-search fix. |
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

## Follow-up classification evidence

| Item | Resolution | Evidence |
|---|---|---|
| Verify Gemini cross-validation omissions | Closed as verified/covered. App Sandbox is not enabled (`Engram.entitlements` is empty), service is a helper child process with health monitoring/backoff, large JSONL reads use `StreamingJSONLReader`, and UI refresh strategy is event/poll based. | `macos/Engram/Engram.entitlements`, `EngramServiceLauncher.swift`, `StreamingJSONLReader.swift`, `ServiceEventRoutingTests`. |
| Decide Swift CLI resume scope | Reopened as product-confirmation follow-up. | `docs/followups.md`. |
| Confirm `insights.deleted_at` intent | Closed as intentional legacy migration support: v2 insight migration filters old `deleted_at` rows out and removes their FTS entries; current `insights` table no longer carries `deleted_at`. | `EngramMigrations.migrateInsightsToV2`; `MigrationRunnerTests` legacy deleted insight migration coverage. |
| Smoke test ProjectsView | Reopened as UI smoke follow-up because current service/core tests do not exercise the committed GUI flow. | `docs/followups.md`. |
| Exercise project rename committed flow | Reopened as UI smoke follow-up; service/core coverage is useful but not equivalent to disposable app flow verification. | `docs/followups.md`. |
| Cover `project_recover` fs_done path end-to-end | Reopened as E2E follow-up; unit coverage exists, but the audit asked for actual filesystem/database recovery evidence. | `docs/followups.md`. |
| Run batch moves on larger real data | Reopened as real-data smoke follow-up; existing unit tests do not prove large-corpus behavior. | `docs/followups.md`. |
| Expand archive heuristic samples | Reopened as boundary-corpus follow-up. | `docs/followups.md`. |
| Consolidate session classification logic | Closed as roadmap-level refactor already documented in the 2026-05-22 closeout; no open TODO until behavior changes are specified. | `docs/reviews/2026-05-22-remediation-closeout.md`; `SessionTierTests`; adapter parity tests. |
| Improve UndoSheet keyboard and CAS precision | Reopened as follow-up; CAS code exists, but keyboard behavior and mtime precision still need explicit verification/decision. | `docs/followups.md`. |
| Normalize project-move reference search | Fixed: `findReferencingFiles` now searches NFC and NFD needles in TypeScript and Swift, with tests for both caller/file normalization directions. | `tests/core/project-move/sources.test.ts`; `SessionSourcesTests`. |
| Add smart dirty-worktree handling | Reopened as policy follow-up rather than hidden behind strict force-gating. | `docs/followups.md`. |
| Stream oversized JSONL patching | Reopened as policy follow-up rather than hidden behind the current 128 MiB cap. | `docs/followups.md`. |
| Add live-session SSE endpoint | Reopened as product-confirmation follow-up for polling versus SSE. | `docs/followups.md`. |

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

The remaining manual/product-confirmation items are listed in
`docs/followups.md`. They are not release blockers for the current cleanup
commit, but they should not be reported as completed.

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
