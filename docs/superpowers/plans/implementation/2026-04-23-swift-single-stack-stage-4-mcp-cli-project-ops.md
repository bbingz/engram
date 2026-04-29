# Swift Single Stack Stage 4 MCP CLI Project Ops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` before implementing this plan. Steps use checkbox (`- [ ]`) syntax for tracking. Do not implement Stage 4 in the same worker that edits this plan unless explicitly assigned.

**Goal:** Move MCP mutating/operational tools, CLI workflows, app daemon-client usage, and project operations onto Swift service-backed implementations without introducing a second SQLite writer.

**Architecture:** Stage 4 is blocked until Stage 3 proves a real shared service IPC transport with a single writer authority. MCP direct read tools may use `EngramCoreRead`; mutating tools, filesystem-writing tools, live-service tools, project operations, and write-capable CLI commands must call `EngramServiceClient` over service IPC and fail closed when the service endpoint is unavailable.

**Tech Stack:** Swift 5.9+, XCTest, GRDB, `EngramCoreRead`, `EngramCoreWrite` only inside service/write targets, `EngramServiceClient`, production service IPC from Stage 3, Swift ArgumentParser, XcodeGen, Node/TypeScript only as reference fixtures during Stage 4.

**Source Documents:**
- `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`
- `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md`
- `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-mcp-cli-project-ops.md`

---

## Review-locked corrections

- Stage 4 acceptance requires both MCP JSON parity and Node daemon vs Swift service dual-run parity. The service parity gate must compare indexing events, DB row counts/checksums, migration/project-operation side effects, and read-after-write freshness on the same fixture roots.
- Read-after-write coverage must be a matrix, not a single `save_insight` example. Required pairs include `save_insight -> get_memory/get_insights`, `project_move -> project_list_migrations/project_timeline/list_sessions/search/get_session`, `link_sessions -> get_session`, and summary/title writes followed by their public reads.
- `docs/swift-single-stack/daemon-client-map.md` must inventory every route from `src/web.ts`, including AI audit/sync, monitor/dev, and log forwarding routes, not only app-visible `/api/*` calls.
- Stage 4 does not delete `DaemonClient.swift`, `DaemonHTTPClientCore.swift`, Node packaging, or `Bundle Node.js Daemon`. It proves no production callers remain and records those files as Stage 5 deletion targets.
- The CLI replacement table must include the bare `engram` default MCP command from `package.json` and `src/cli/index.ts`, not only named subcommands.
- Do not introduce `environment.status` values beyond the source spec and parent plan. Missing service IPC remains a typed MCP error, not an `environment` payload.
- Stage 4 verification evidence must be recorded in `docs/verification/swift-single-stack-stage4.md`, which becomes the Stage 5 prerequisite log.
- Project-operation crash-window tests must define concrete filesystem assertions for every injected failure: pre/post file tree hashes, file counts, directory existence, source/destination path ownership, migration row state, alias state, and structured recovery recommendation.

## Goal

Stage 4 makes Swift the owner of the remaining Node-owned MCP, CLI, daemon-client, and project-operation behavior while preserving user-visible contract parity and single-writer safety.

The stage is successful when:

- Swift MCP can replace Node MCP for the full public tool suite on shared fixtures.
- All MCP mutating and operational tools route through `EngramServiceClient` to the shared service process.
- Direct MCP reads use `EngramCoreRead` only where they are pure read-only and have read-after-write freshness coverage.
- Swift CLI either replaces each Node CLI workflow or documents intentional deprecation before Node CLI deletion.
- Project move/archive/undo/recover/review behavior preserves Node compensation, crash-window diagnostics, and Gemini `projects.json` semantics.
- App production code no longer depends on raw daemon HTTP or generic `DaemonClient` affordances.

## Scope

In scope:

- Finish the daemon-client-to-service-client map for app, MCP, CLI, and project operations.
- Add typed `EngramServiceClient` protocol methods and DTOs for every retained daemon/MCP/CLI capability.
- Route service-backed MCP tools through service IPC.
- Preserve pure read-only MCP tools on `EngramCoreRead` where safe.
- Define and test the `get_context` environment contract.
- Port project move/archive/undo/batch/review/recover into service-only Swift code.
- Port session-linking, suggestion, export, handoff, timeline, lint, hygiene, live-session, summary, insight, memory, stats, costs, file-activity, and project-timeline behavior as required by MCP/app/CLI parity.
- Replace app `DaemonClient` and `DaemonHTTPClientCore` callers with typed service calls.
- Replace or explicitly deprecate Node CLI commands with Swift CLI commands and documentation.
- Expand MCP golden, service-unavailable, error-shape, and dual-run parity tests.
- Add Stage 5 deletion-readiness scans, but do not delete Node runtime, Node packaging, or compatibility shim files in Stage 4.

Out of scope:

- Deleting Node MCP, Node web daemon, Node CLI, Node adapters, Node runtime dependencies, or app bundle Node resources. Those are Stage 5 actions after dual-run parity and packaging gates.
- Changing SQLite schema except where a Stage 4 service command needs already-approved Stage 1-3 schema surfaces.
- Adding any direct writer to `EngramMCP`, `EngramCLI`, app UI, or app-importable shared code.
- Keeping Node daemon HTTP as a production fallback after a Swift service command exists.

## Prerequisites

- [ ] Stage 0, Stage 1, Stage 2, and Stage 3 acceptance gates from `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md` have passed.
- [ ] Stage 3 real IPC gate has passed: a standalone `EngramService` process accepts two concurrent clients through the production transport and serializes write commands through one writer authority.
- [ ] `EngramServiceClient` and service IPC have typed service-unavailable errors from Stage 3; mutating MCP/CLI must not instantiate an in-process writer fallback.
- [ ] `EngramCoreRead` and `EngramCoreWrite` module boundaries exist, and app/MCP/CLI targets cannot import `EngramCoreWrite`.
- [ ] Stage 2 adapter/indexing parity exists for transcript reads and replay/handoff/export paths that depend on adapters.
- [ ] Node MCP and Node CLI remain available as reference implementations until Stage 5 deletion.

Run these prerequisite checks before any Stage 4 code change:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
```

Expected output: command exits `0`; `macos/Engram.xcodeproj` regenerates without XcodeGen errors.

Failure handling: stop Stage 4, fix the Stage 3 project configuration in the Stage 3 branch or handoff, and do not edit Stage 4 files.

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/EngramServiceIPCTests
```

Expected output: command exits `0`; the test proving two IPC clients share one serialized writer passes.

Failure handling: Stage 4 is blocked. Do not enable any Swift MCP/CLI mutating command.

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected output: command exits `0`; existing Swift MCP tests pass with mutating tools still Node-backed or fail-closed.

Failure handling: fix the Stage 3 MCP/service boundary before Stage 4 routing work.

```bash
rtk npm test
```

Expected output: command exits `0`; Node reference tests pass.

Failure handling: if failure is unrelated and pre-existing, record exact failing test in Stage 4 verification notes and do not delete Node reference files. If failure affects MCP/project operations, block Stage 4 parity work until fixed.

## Files to Create or Modify

This plan is the only file created by the planning worker:

- Created: `docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-4-mcp-cli-project-ops.md`

Implementation workers may create or modify these files during Stage 4:

- Create or complete: `docs/swift-single-stack/daemon-client-map.md`
- Create: `docs/swift-single-stack/cli-replacement-table.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `macos/project.yml`
- Regenerate after project changes: `macos/Engram.xcodeproj/project.pbxproj`
- Modify: `macos/Shared/Service/EngramServiceProtocol.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/EngramServiceError.swift`
- Modify: `macos/Shared/Service/EngramServiceTransport.swift`
- Modify: `macos/Shared/Service/MockEngramServiceClient.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveOrchestrator.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveFileOps.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveSources.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveJSONPatcher.swift`
- Create: `macos/EngramService/ProjectMove/GeminiProjectsJSON.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveArchive.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveBatch.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveLock.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveRecovery.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveErrors.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveFailureInjection.swift`
- Create or modify: `macos/EngramService/Operations/SessionLinkingService.swift`
- Create or modify: `macos/EngramService/Operations/TranscriptExportService.swift`
- Create or modify: `macos/EngramService/Operations/HandoffService.swift`
- Create or modify: `macos/EngramService/Operations/ReplayTimelineService.swift`
- Create or modify: `macos/EngramService/Operations/ConfigLintService.swift`
- Create or modify: `macos/EngramService/Operations/HygieneService.swift`
- Create or modify: `macos/EngramService/Operations/LiveSessionsService.swift`
- Create or modify: `macos/EngramService/Operations/InsightService.swift`
- Create or modify: `macos/EngramService/Operations/SummaryService.swift`
- Modify: `macos/EngramMCP/Core/MCPConfig.swift`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramMCP/Core/MCPFileTools.swift`
- Modify: `macos/EngramMCP/Core/MCPTranscriptTools.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Modify: `macos/Engram/Core/DaemonClient.swift`, then delete only after scan tests prove zero production callers.
- Modify: `macos/Shared/Networking/DaemonHTTPClientCore.swift`, then delete only after scan tests prove zero production callers.
- Modify: `macos/Engram/Core/AppEnvironment.swift`
- Modify: `macos/Engram/Core/IndexerProcess.swift`
- Modify: `macos/Engram/Core/EngramLogger.swift`
- Modify: `macos/Engram/App.swift`
- Modify: `macos/Engram/MenuBarController.swift`
- Modify: `macos/Engram/Views/**/*.swift`
- Modify: `macos/EngramCLI/main.swift`
- Create: `macos/EngramCLI/Commands/MCPCommand.swift`
- Create: `macos/EngramCLI/Commands/ProjectCommand.swift`
- Create: `macos/EngramCLI/Commands/HealthCommand.swift`
- Create: `macos/EngramCLI/Commands/LogsCommand.swift`
- Create: `macos/EngramCLI/Commands/TracesCommand.swift`
- Create: `macos/EngramCLI/Commands/ResumeCommand.swift`
- Create: `macos/EngramCLI/Commands/DeprecatedCommand.swift`
- Create or modify: `macos/EngramTests/EngramServiceClientMappingTests.swift`
- Create or modify: `macos/EngramTests/DaemonClientRemovalTests.swift`
- Create or modify: `macos/EngramTests/ProjectMoveCompensationTests.swift`
- Create or modify: `macos/EngramTests/ProjectMoveParityTests.swift`
- Create or modify: `macos/EngramTests/SessionOperationsParityTests.swift`
- Create or modify: `macos/EngramTests/EngramCLITests.swift`
- Create or modify: `macos/EngramTests/NodeDeletionReadinessTests.swift`
- Modify: `scripts/gen-mcp-contract-fixtures.ts`
- Create: `scripts/compare-node-swift-mcp.ts`
- Create: `scripts/check-node-deletion-readiness.sh`
- Modify or create fixtures under: `tests/fixtures/mcp-golden/`
- Create: `tests/fixtures/mcp-golden/get_context.engram.degraded.json`
- Create: `tests/fixtures/mcp-golden/service-unavailable/*.json`
- Create or modify fixtures under: `tests/fixtures/project-move/**`
- Create or modify fixtures under: `tests/fixtures/service-client/**`

Reference-only files during Stage 4:

- `src/index.ts`
- `src/web.ts`
- `src/tools/*.ts`
- `src/cli/*.ts`
- `src/core/project-move/*.ts`

Do not modify reference-only files except for deterministic fixture-generation hooks explicitly covered by the MCP parity task. Do not delete reference-only files in Stage 4.

## Phased Tasks

### Phase 1: Lock the Stage 3 Gate and Complete Service Mapping

**Purpose:** Prevent Stage 4 from starting without real IPC and make every retained daemon/MCP/CLI behavior explicit.

**Files:**
- Create or complete: `docs/swift-single-stack/daemon-client-map.md`
- Modify: `macos/Shared/Service/EngramServiceProtocol.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/EngramServiceError.swift`
- Modify: `macos/Shared/Service/MockEngramServiceClient.swift`
- Create or modify: `macos/EngramTests/EngramServiceClientMappingTests.swift`
- Modify: `macos/project.yml`

Steps:

- [ ] Add a top section to `docs/swift-single-stack/daemon-client-map.md` named `Stage 4 Blocker` with the exact Stage 3 IPC command and a recorded passing result. The text must state: `Stage 4 is blocked until EngramService real IPC serializes two concurrent write clients through one writer authority.`
- [ ] Enumerate every current `DaemonClient` method, every `DaemonHTTPClientCore` use, every route in `src/web.ts`, every app `/api/*` or `/health` daemon URL, every MCP tool, every Node CLI command, and the bare `engram` default MCP command.
- [ ] For each row, assign exactly one disposition: `EngramCoreRead`, `EngramServiceClient`, `Swift CLI deprecated`, `Stage 5 deletion after parity`, or `test-only Node reference`.
- [ ] Add typed protocol methods and DTOs for every `EngramServiceClient` row. Do not add a generic `request(path:)`, `fetch<T>`, `post<T>`, `postRaw`, or `delete` replacement.
- [ ] Define service error envelopes with `name`, `message`, `retryPolicy`, and `details`; project-operation details must include `sourceId`, `oldDir`, `newDir`, `sharingCwds`, `migrationId`, `state`, and lock-holder fields when applicable.
- [ ] Add `MockEngramServiceClient` fixtures for every retained method so MCP, app, and CLI tests can run without starting a real service except in IPC-specific tests.
- [ ] Add scan tests in `EngramServiceClientMappingTests` that fail when production app/shared code contains unmapped daemon HTTP strings or generic daemon affordances.

Command:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
```

Expected output: exits `0`.

Failure handling: fix `macos/project.yml`; do not hand-edit generated Xcode project files.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/EngramServiceClientMappingTests
```

Expected output: exits `0`; tests confirm every mapping row has a typed service-client method or explicit non-service disposition.

Failure handling: add missing mappings or DTOs before routing MCP/app/CLI callers.

Command:

```bash
rg 'func (fetch|post|postRaw|delete)<|ENGRAM_MCP_DAEMON_BASE_URL|http://127\.0\.0\.1|http://localhost|/api/' macos/Engram macos/Shared --glob '!**/*Tests*'
```

Expected output: no production matches after Phase 5 completes. During Phase 1, remaining matches must be listed in `docs/swift-single-stack/daemon-client-map.md` with the exact future phase that removes them.

Failure handling: if an unlisted match appears, stop and map it before implementation continues.

### Phase 2: Route Swift MCP Through Service or EngramCoreRead

**Purpose:** Make `macos/EngramMCP` the service-safe Swift MCP implementation without creating a second writer.

**Files:**
- Modify: `macos/EngramMCP/Core/MCPConfig.swift`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramMCP/Core/MCPFileTools.swift`
- Modify: `macos/EngramMCP/Core/MCPTranscriptTools.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Modify: `scripts/gen-mcp-contract-fixtures.ts`
- Create: `tests/fixtures/mcp-golden/get_context.engram.degraded.json`
- Create: `tests/fixtures/mcp-golden/service-unavailable/*.json`
- Modify: `tests/fixtures/mcp-golden/*.json`

Service-backed MCP tools:

- `generate_summary`
- `save_insight`
- `manage_project_alias` for `add` and `remove`
- `link_sessions`
- `export`
- `handoff`
- `lint_config`
- `live_sessions`
- `project_move`
- `project_archive`
- `project_undo`
- `project_move_batch`
- `project_recover`
- `project_review`
- Any `get_context` call with `include_environment=true`

Direct read-only MCP tools that may remain `EngramCoreRead` backed:

- `list_sessions`
- `get_session`
- `search`
- `get_context` with `include_environment=false`
- `get_memory`
- `get_costs`
- `get_insights`
- `stats`
- `tool_analytics`
- `file_activity`
- `project_timeline`
- `project_list_migrations`
- `manage_project_alias` for `list`

Read-after-write rule:

- `get_memory` and `get_insights` may stay on `EngramCoreRead` only if tests prove that a preceding `save_insight` service acknowledgement refreshes or invalidates reader pools before the next read.
- If read-after-write freshness cannot be proven, route the affected read tool through `EngramServiceClient`.

`get_context` contract:

- `include_environment=false`: use only `EngramCoreRead`; do not contact the service; omit `environment`; do not return fake degraded state.
- `include_environment=true`: use service or hybrid service data for live sessions, alerts, health checks, config lint, and environment metadata.
- `include_environment=true` with missing service IPC: return a typed MCP service-unavailable error; return no partial local context.
- `include_environment=true` with reachable service and all providers healthy: return `environment.status = "ok"`.
- `include_environment=true` with reachable service and a failed sub-provider: return `environment.status = "degraded"` and `environment.warnings[]`, where each warning includes `provider`, `code`, and `message`.
- The degraded fixture path is exactly `tests/fixtures/mcp-golden/get_context.engram.degraded.json`.

Steps:

- [ ] Update `MCPConfig` to read the Stage 3 service IPC endpoint from the production service configuration. `ENGRAM_MCP_DAEMON_BASE_URL` may exist only behind a test-only Node-reference fixture mode.
- [ ] Add MCP executable tests that start Swift MCP with no service endpoint and call every service-backed tool. Assert a typed service-unavailable MCP error and no database/filesystem side effects.
- [ ] Add `get_context` tests for the three required modes: pure read no service, missing service typed error, and reachable service with degraded environment warnings.
- [ ] Replace direct `DaemonHTTPClientCore` or local write helper use inside MCP tool handlers with `EngramServiceClient`.
- [ ] Keep read-only transcript and database access local only through `EngramCoreRead` facades.
- [ ] Preserve ordered JSON output for golden-tested tools, including `project_archive.archive`, `project_move.resolved` for `~` expansion, and `save_insight.warning` or `duplicateWarning` fields.
- [ ] Extend `scripts/gen-mcp-contract-fixtures.ts` so Node and Swift fixtures cover every public tool, happy paths, validation errors, service-unavailable errors, and the degraded `get_context` fixture.

Command:

```bash
rtk npm run generate:mcp-contract-fixtures
```

Expected output: exits `0`; fixtures under `tests/fixtures/mcp-golden/` are regenerated deterministically.

Failure handling: if the generator cannot produce a Node reference fixture, keep the Node implementation unchanged and fix the generator or fixture data before changing Swift output.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected output: exits `0`; MCP executable tests pass, including service-unavailable and `get_context` contract tests.

Failure handling: if a service-backed tool mutates local state while the service is unavailable, revert that tool's routing change and reimplement it through `EngramServiceClient`.

Command:

```bash
rg 'DaemonHTTPClientCore|ENGRAM_MCP_DAEMON_BASE_URL|handleProjectMove\(|handleSaveInsight\(|handleLinkSessions\(' macos/EngramMCP --glob '!**/*Tests*'
```

Expected output: no production matches after Phase 2, except test-only compatibility flags explicitly guarded in `MCPConfig`.

Failure handling: leave the tool disabled/fail-closed until the direct route is removed.

### Phase 3: Port Project Move, Archive, Undo, Batch, Review, and Recover

**Purpose:** Move high-risk project operations into service-only Swift code with Node parity and stronger failure diagnostics.

**Files:**
- Create: `macos/EngramService/ProjectMove/ProjectMoveOrchestrator.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveFileOps.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveSources.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveJSONPatcher.swift`
- Create: `macos/EngramService/ProjectMove/GeminiProjectsJSON.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveArchive.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveBatch.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveLock.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveRecovery.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveErrors.swift`
- Create: `macos/EngramService/ProjectMove/ProjectMoveFailureInjection.swift`
- Create or modify: `macos/EngramTests/ProjectMoveCompensationTests.swift`
- Create or modify: `macos/EngramTests/ProjectMoveParityTests.swift`
- Modify: `macos/project.yml`
- Reference only: `src/core/project-move/*.ts`

Required project operation behavior:

- `project_move` canonicalizes paths before validation, expands `~`, rejects empty paths, rejects `src == dst`, rejects destination inside source, and rejects source inside destination.
- Git dirty checks handle `.git` directories and `.git` files, return `untrackedOnly`, and block unless `force` is true.
- Dry-run performs read-only source scans and returns real counts, `renamedDirs`, `skippedDirs`, `perSource`, `git`, `manifest`, and `state: dry-run`; dry-run must not create archive directories or temp files.
- Locking uses one advisory lock under the configured Engram home equivalent of `~/.engram/.project-move.lock`, detects stale holders by PID, and releases on success, failure, and handled cancellation paths.
- Physical moves preserve symlinks, mode bits, timestamps, and support cross-volume copy-then-delete with partial-copy cleanup.
- If cross-volume copy succeeds but source deletion fails, remove duplicate destination only when source integrity is confirmed; otherwise return a duplicate-tree recovery state without claiming rollback success.
- Per-source directory rename plans cover `claude-code`, `gemini-cli`, and `iflow`; `codex`, `opencode`, `antigravity`, and `copilot` are content-scan-only roots unless Stage 2 parity has already proven grouped directories.
- JSON/JSONL patching is atomic, UTF-8 safe, and detects concurrent modification.
- `markMigrationFsDone` happens only after filesystem work completes and before DB commit.
- DB commit updates sessions, session local state, aliases, affected session IDs, and migration log details in one transaction.
- Compensation reverses JSON patches, Gemini `projects.json`, per-source directory renames, and the physical move in LIFO order.
- `project_archive` accepts the existing localized aliases plus `historical-scripts`, `empty-project`, and `archived-done`, and stores the same canonical category directories as the Node reference.
- `project_undo` accepts only committed migrations, validates the current `newPath`, validates affected session CWD ownership, and records a new migration with `rolledBackOf`.
- `project_recover` and `project_review` are diagnostic/reporting operations. `project_recover` must not modify filesystem or database state.

Gemini `projects.json` requirements:

- Support both wrapped format `{ "projects": { "<cwd>": "<basename>" } }` and legacy top-level map `{ "<cwd>": "<basename>" }`.
- Preserve the detected wrapper layout when writing.
- Serialize with 2-space indentation and one trailing newline.
- Preserve existing map insertion order exactly as Node does; do not sort keys unless the Node reference changes.
- On apply, delete the old CWD entry if present, then append the new CWD entry so the new entry appears at the end of the map in JSON order.
- On reverse, restore captured `originalText` byte-for-byte when the file existed before the operation.
- If the file did not exist before the operation, remove the inserted entry; if the remaining map is empty, unlink `projects.json` rather than leaving an empty file.
- Run the basename collision probe before filesystem mutation. Conflicts are other CWDs whose stored basename equals the target basename and whose CWD differs from the source CWD.
- Atomic writes use temp-file-plus-rename semantics and must leave no partial JSON on crash.

Mandatory crash windows and failure injections:

- [ ] Failure after lock acquisition before `migration_log` start: no migration row, lock released.
- [ ] Failure after `startMigration` before physical move: source exists, destination absent, migration failed, lock released.
- [ ] Failure after physical move: destination moved back to source, migration failed, lock released.
- [ ] Failure after cross-volume copy succeeds but source delete fails: intact source removes duplicate destination; uncertain source returns duplicate-tree recovery state.
- [ ] Failure after first per-source directory rename: renamed dirs restored, physical move reverted, migration failed.
- [ ] Failure after Gemini `projects.json` apply: original text restored byte-for-byte.
- [ ] SIGTERM after Gemini `projects.json` apply but before Gemini tmp directory rename: recovery reports `projects.json` restored first and tmp directory rename not applied.
- [ ] Failure after one JSON/JSONL file patch: patched file restored and unpatched files untouched.
- [ ] `InvalidUtf8Error` from matched session file: entire pipeline aborts and compensates.
- [ ] Concurrent modification during patch: entire pipeline aborts and compensates.
- [ ] Failure after `markMigrationFsDone` before DB commit: filesystem compensation completes and recover reports failed migration with safe next action.
- [ ] Failure during DB apply: DB transaction rolls back, filesystem compensation completes, lock releases.
- [ ] Reverse patch compensation failure: report includes `patchFailed` and does not claim success.
- [ ] Source-dir restore failure: report includes `dirRestoreErrors`.
- [ ] Physical move-back failure: report includes `moveRevertError`.
- [ ] Archive category collision: aborts before archive directory side effects.
- [ ] Undo stale overlay: throws typed stale error and leaves filesystem/database unchanged.
- [ ] Batch archive dry-run: creates no `_archive/<category>/` directories or parent directories.
- [ ] Batch stop-on-error and continue modes: preserve schema v1 behavior and report per-operation state.
- [ ] Recover pending filesystem state: returns path probes, temp artifacts, and recommendation without mutation.
- [ ] Recover committed/stale state: reports anomaly or OK based on old/new path probes without mutation.
- [ ] SIGINT, SIGTERM, and simulated crash after lock acquisition, after `startMigration`, after physical move, and after `markMigrationFsDone`: stale lock handling, migration state, and `project_recover` recommendation match fixtures.
- [ ] SIGKILL-specific case after `markMigrationFsDone` before DB commit: recovery reports exact `migration_state`, `lock_state`, filesystem duplicate/restored state, and safe next action without claiming success.

Steps:

- [ ] Create service-only project move files under `macos/EngramService/ProjectMove/`; do not put write-capable project ops in `macos/Shared` or MCP targets.
- [ ] Port error types first and add retry-policy parity tests against `src/core/project-move/retry-policy.ts`.
- [ ] Port dry-run planning and source-root discovery with fixtures covering Claude Code encoded CWD, Codex date tree, Gemini tmp basename tree, iFlow lossy encoded path, OpenCode data root, Antigravity data root, and Copilot session-state root.
- [ ] Port locking and physical move logic with EXDEV, symlink, mode, timestamp, and partial-copy cleanup tests.
- [ ] Port Gemini `projects.json` plan/apply/reverse before implementing the full orchestrator, and add ordering/layout/reverse tests.
- [ ] Port JSON/JSONL patching with UTF-8 and concurrent modification tests.
- [ ] Port orchestrator, archive, undo, batch, review, and recover service commands with failure-injection seams compiled only into tests.
- [ ] Add service-client methods and MCP/CLI request DTOs for project operations only after service tests pass.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/ProjectMoveCompensationTests
```

Expected output: exits `0`; every mandatory failure-injection and crash-window test passes.

Failure handling: do not expose Swift `project_move`, `project_archive`, `project_undo`, `project_move_batch`, `project_review`, or `project_recover` in MCP/CLI until the failing injection is fixed.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/ProjectMoveParityTests
```

Expected output: exits `0`; Swift dry-run, committed move, archive suggestions, recover recommendations, and retry-policy mappings match Node fixtures with UUIDs/timestamps normalized.

Failure handling: keep Node project tools as the reference and record the exact divergence in the parity fixture output.

Command:

```bash
rtk npm test -- src/core/project-move
```

Expected output: exits `0`; Node reference project-move behavior still passes.

Failure handling: Stage 4 may continue only if the failure is unrelated and documented. Do not delete Node project-move code.

### Phase 4: Port Session, Insight, Export, Handoff, Timeline, Lint, Hygiene, and Live Operations

**Purpose:** Move non-project operational behavior that writes, probes filesystem state, depends on adapters, or uses live monitor/service state to Swift service commands.

**Files:**
- Create or modify: `macos/EngramService/Operations/SessionLinkingService.swift`
- Create or modify: `macos/EngramService/Operations/TranscriptExportService.swift`
- Create or modify: `macos/EngramService/Operations/HandoffService.swift`
- Create or modify: `macos/EngramService/Operations/ReplayTimelineService.swift`
- Create or modify: `macos/EngramService/Operations/ConfigLintService.swift`
- Create or modify: `macos/EngramService/Operations/HygieneService.swift`
- Create or modify: `macos/EngramService/Operations/LiveSessionsService.swift`
- Create or modify: `macos/EngramService/Operations/InsightService.swift`
- Create or modify: `macos/EngramService/Operations/SummaryService.swift`
- Create or modify: `macos/EngramTests/SessionOperationsParityTests.swift`
- Modify: `macos/Shared/Service/EngramServiceProtocol.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Reference only: `src/tools/link_sessions.ts`
- Reference only: `src/tools/export.ts`
- Reference only: `src/tools/handoff.ts`
- Reference only: `src/tools/lint_config.ts`
- Reference only: `src/tools/live_sessions.ts`
- Reference only: `src/tools/generate_summary.ts`
- Reference only: `src/tools/save_insight.ts`
- Reference only: `src/tools/get_memory.ts`
- Reference only: `src/tools/get_insights.ts`
- Reference only: `src/web.ts`

Required behavior:

- Session linking supports link, unlink, confirm suggestion, dismiss suggestion, child-session reads, stale-suggestion conflicts, and actor/audit fields.
- `link_sessions` creates symlinks through the service, validates absolute target directories, resolves project aliases, handles source subdirectories, replaces existing symlinks safely, reports skipped/errors, and truncates at 10,000 sessions.
- `export` writes Markdown or JSON to `~/codex-exports` through the service, preserves output names, message ordering, adapter-backed transcript streaming, and response path fields.
- `handoff` uses adapters to read recent user messages, preserves `markdown` and `plain` output formats, cost rows, recent-session ordering, alias fallback, and empty-project text.
- Replay timeline preserves `limit`, `offset`, `hasMore`, `durationToNextMs`, token fields, tool-call type, and adapter-missing errors.
- `lint_config` preserves config candidates, backtick reference extraction, path-traversal guard, npm script checks, similar-file suggestions, health-rule aggregation, and score model.
- Hygiene checks preserve `force` behavior and global scope parity.
- `live_sessions` reads service monitor state, filters subagents/global dash projects, enriches from DB with generated title/summary/project/model, supports tier/agent-role filtering, and dedupes by source plus project/cwd/filePath.
- `save_insight` preserves text-only fallback with warning, dual-write when embeddings are available, startup reconciliation between `insights` and `memory_insights`, and FTS fallback for `search`, `get_context`, and `get_memory`.
- `generate_summary` preserves configured provider request/response/error behavior and DB summary update semantics.
- Read-only `get_costs`, `get_insights`, `stats`, `tool_analytics`, `file_activity`, and `project_timeline` may use `EngramCoreRead` only when parity and read-after-write freshness tests pass.

Steps:

- [ ] Write failing parity tests for each service operation using Node-generated fixtures.
- [ ] Implement minimal Swift operation code in service-only targets; route writes through the Stage 3 writer gate.
- [ ] Add service-unavailable tests for MCP calls to these operations.
- [ ] Add read-after-write matrix tests for `save_insight -> get_memory/get_insights`, `project_move -> project_list_migrations/project_timeline/list_sessions/search/get_session`, `link_sessions -> get_session`, and summary/title writes followed by their public read paths.
- [ ] Update MCP registry to call the service for operation-backed tools.
- [ ] Update fixture generator and MCP goldens for happy paths and representative errors.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/SessionOperationsParityTests
```

Expected output: exits `0`; service operations match Node fixture behavior.

Failure handling: keep the failing operation on Node reference or fail-closed in Swift MCP; do not claim Stage 4 parity for that tool.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected output: exits `0`; MCP goldens pass for operation-backed tools.

Failure handling: inspect the first JSON diff; change Swift output only when Node parity or an approved allowlisted improvement requires it.

### Phase 5: Replace App DaemonClient and Raw HTTP Usage

**Purpose:** Remove app production dependency on Node daemon HTTP and generic daemon client methods.

**Files:**
- Modify: `macos/Engram/Core/DaemonClient.swift`
- Modify: `macos/Shared/Networking/DaemonHTTPClientCore.swift`
- Modify: `macos/Engram/Core/AppEnvironment.swift`
- Modify: `macos/Engram/Core/IndexerProcess.swift`
- Modify: `macos/Engram/Core/EngramLogger.swift`
- Modify: `macos/Engram/App.swift`
- Modify: `macos/Engram/MenuBarController.swift`
- Modify: `macos/Engram/Views/**/*.swift`
- Create or modify: `macos/EngramTests/DaemonClientRemovalTests.swift`
- Modify or replace: `macos/Engram/TestSupport/MockDaemonFixtures.swift`

Steps:

- [ ] Add `DaemonClientRemovalTests` that fail on production `DaemonClient` environment injection, `DaemonHTTPClientCore`, raw `/api/`, `http://127.0.0.1`, `http://localhost`, generic fetch/post/delete methods, and daemon port settings.
- [ ] Introduce `EngramServiceClient` into app environment injection while keeping `DaemonClient` only as a short-lived compatibility facade.
- [ ] Replace every `@Environment(DaemonClient.self)` with `@Environment(EngramServiceClient.self)` or a protocol-typed wrapper.
- [ ] Replace project move/archive/undo/migrations/CWD calls with typed service-client methods.
- [ ] Replace session linking, suggestions, summary, title, resume, sync, search status, skills, sources, memory, hooks, hygiene, replay, live sessions, handoff, and log forwarding calls with typed service-client or `EngramCoreRead` methods according to the mapping table.
- [ ] Replace `IndexerProcess` process-launch state with a service event adapter preserving UI fields: status, total sessions, today parent sessions, service endpoint, usage data, and last summary session ID.
- [ ] Prove `macos/Engram/Core/DaemonClient.swift` and `macos/Shared/Networking/DaemonHTTPClientCore.swift` have no production callers, no target-required imports, and are recorded as Stage 5 deletion targets. Do not delete them in Stage 4.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/DaemonClientRemovalTests
```

Expected output: exits `0`; no app production dependency remains on daemon HTTP or generic daemon client APIs.

Failure handling: keep the compatibility facade and continue replacing the listed call sites. Do not delete shim files while any production caller remains.

Command:

```bash
rg 'DaemonClient|DaemonHTTPClientCore|http://127\.0\.0\.1|http://localhost|/api/' macos/Engram macos/Shared --glob '!**/*Tests*'
```

Expected output: no matches after Phase 5. Matches inside explicitly deleted files are acceptable only before the deletion step and must disappear before Phase 5 acceptance.

Failure handling: map each match to a typed service call or `EngramCoreRead` query and rerun tests.

### Phase 6: Replace or Deprecate Node CLI Workflows

**Purpose:** Make terminal workflows Swift-owned or explicitly documented before Node CLI deletion.

**Files:**
- Modify: `macos/EngramCLI/main.swift`
- Create: `macos/EngramCLI/Commands/MCPCommand.swift`
- Create: `macos/EngramCLI/Commands/ProjectCommand.swift`
- Create: `macos/EngramCLI/Commands/HealthCommand.swift`
- Create: `macos/EngramCLI/Commands/LogsCommand.swift`
- Create: `macos/EngramCLI/Commands/TracesCommand.swift`
- Create: `macos/EngramCLI/Commands/ResumeCommand.swift`
- Create: `macos/EngramCLI/Commands/DeprecatedCommand.swift`
- Create or modify: `macos/EngramTests/EngramCLITests.swift`
- Create: `docs/swift-single-stack/cli-replacement-table.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `macos/project.yml`
- Reference only: `src/cli/index.ts`
- Reference only: `src/cli/project.ts`
- Reference only: `src/cli/health.ts`
- Reference only: `src/cli/logs.ts`
- Reference only: `src/cli/traces.ts`
- Reference only: `src/cli/resume.ts`

Required CLI replacement table:

- File path: `docs/swift-single-stack/cli-replacement-table.md`
- Columns: `Node command`, `Swift command`, `Disposition`, `Service/Core owner`, `Parity fixture`, `Deletion gate`.
- Each current Node CLI command must have one row.
- `Disposition` values are exactly `replaced`, `deprecated`, or `merged into MCP`.
- README and CLAUDE must link to this table before Phase 6 is accepted.

Required Swift CLI behavior:

- `engram mcp` runs the Swift stdio MCP helper or the same Swift MCP server code path; it must not use `/tmp/engram.sock` or the old app-local `MCPServer`.
- `engram project move <src> <dst>` supports `--yes`, `--dry-run`, `--force`, and `--note`; write path uses `EngramServiceClient.projectMove`.
- `engram project archive <src>` supports `--to`, `--yes`, `--dry-run`, `--force`, and `--note`.
- `engram project review <old> <new>` supports text and markdown output.
- `engram project undo <migration-id>` supports `--force`.
- `engram project list` supports `--since`.
- `engram project recover` supports `--since` and `--include-committed`.
- `engram project move-batch <yaml-file>` supports `--force` and preserves batch schema v1 behavior.
- `engram health` and `engram diagnose` read Swift observability repositories and support `--since`, `--last`, and `--json`.
- `engram logs` supports `--level`, `--module`, `--trace-id`, `--since`, `--last`, `--limit`, and `--json`.
- `engram traces` supports `--slow`, `--name`, `--trace-id`, `--since`, `--last`, `--limit`, and `--json`.
- `engram --resume` and `engram -r` become `engram resume` or remain aliases; both use `EngramServiceClient.resumeCommand`.
- Removed Node-only workflows must print a deterministic deprecation message, have a row in the replacement table, and have a CLI test asserting the message.

Steps:

- [ ] Inventory Node CLI commands from `src/cli/*.ts` into `docs/swift-single-stack/cli-replacement-table.md`.
- [ ] Add README and CLAUDE links to `docs/swift-single-stack/cli-replacement-table.md`.
- [ ] Replace the current Unix socket HTTP bridge in `macos/EngramCLI/main.swift`.
- [ ] Add Swift ArgumentParser command tree with dependency injection for `EngramServiceClient` and `EngramCoreRead`.
- [ ] Route write-capable commands through service IPC; route pure reads through `EngramCoreRead` only when listed in the mapping table.
- [ ] Preserve friendly error rendering by mapping `retryPolicy` to safe, conditional, wait, and never hints.
- [ ] Add CLI fixture tests comparing Swift output against Node CLI output with ANSI stripped and UUIDs/timestamps normalized.
- [ ] Keep `src/cli/*.ts` until Stage 5 deletion gates pass.

Command:

```bash
rtk xcodebuild build -project macos/Engram.xcodeproj -scheme EngramCLI -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected output: exits `0`; Swift CLI target builds.

Failure handling: fix `macos/project.yml` or command source inclusion before updating docs to claim replacement.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/EngramCLITests
```

Expected output: exits `0`; retained commands and deprecation messages match fixtures.

Failure handling: do not remove Node CLI references from docs until replacement/deprecation tests pass.

Command:

```bash
rg 'dist/cli|src/cli|node .*engram|/tmp/engram.sock|MCPServer' README.md CLAUDE.md macos/EngramCLI macos/project.yml --glob '!docs/archive/**'
```

Expected output: only explicit replacement-table links or deprecation notes remain.

Failure handling: update README/CLAUDE/CLI implementation before Phase 6 acceptance.

### Phase 7: Expand MCP Full-Parity and Dual-Run Gates

**Purpose:** Prove Swift MCP and Node MCP contract equivalence before Stage 5 deletion.

**Files:**
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Modify: `scripts/gen-mcp-contract-fixtures.ts`
- Create: `scripts/compare-node-swift-mcp.ts`
- Create: `tests/fixtures/mcp-golden/service-unavailable/*.json`
- Modify: `tests/fixtures/mcp-golden/*.json`
- Reference-only fixture hooks if necessary: `src/index.ts`

Steps:

- [ ] Assert `tools/list` exposes the same public tool names as Node MCP unless an intentional removal is documented in the mapping table.
- [ ] Add golden tests for every public MCP tool, including validation errors and representative service errors.
- [ ] Add error-shape tests for missing required params, invalid enum values, service unavailable, lock busy, stale undo, invalid UTF-8, concurrent modification, path collision, stale suggestion, missing session, missing adapter, and export/write permission errors.
- [ ] Implement `scripts/compare-node-swift-mcp.ts` to call Node MCP and Swift MCP against the same fixture DB and fixture home while only one writer is active at a time.
- [ ] Implement or run the Stage 5-owned `scripts/run-service-dual-parity.sh` in pre-deletion mode to compare Node daemon/indexing side effects with Swift service side effects: indexing event counts, sessions/index_jobs row counts, selected table checksums, project-operation migration rows, and read-after-write matrix outputs.
- [ ] Normalize only approved nondeterministic fields: UUIDs, timestamps, temp directory suffixes, trace IDs, and absolute fixture roots.
- [ ] Maintain a small allowlist for intentional Swift-only improvements. Each allowlist entry must name the tool, field path, reason, and deletion date.
- [ ] Fail the dual-run harness on any unapproved JSON difference.

Command:

```bash
rtk npm run build
```

Expected output: exits `0`; Node reference MCP builds.

Failure handling: fix Node reference build or record unrelated pre-existing failure; do not delete Node MCP.

Command:

```bash
rtk npm run generate:mcp-contract-fixtures
```

Expected output: exits `0`; fixtures are regenerated.

Failure handling: no MCP parity claim until fixture generation passes.

Command:

```bash
rtk npx tsx scripts/compare-node-swift-mcp.ts --fixture-db tests/fixtures/mcp-contract.sqlite
```

Expected output: exits `0`; reports zero unapproved JSON differences.

Failure handling: fix Swift parity, update fixture generation, or add a reviewed allowlist entry with deletion date.

Command:

```bash
rtk bash scripts/run-service-dual-parity.sh --pre-deletion --fixture-db tests/fixtures/mcp-contract.sqlite
```

Expected output: exits `0`; reports zero unapproved DB checksum, indexing event, project-operation side-effect, or read-after-write matrix differences.

Failure handling: fix Swift service/project-operation parity before Stage 5 readiness. Do not narrow the parity harness to JSON-only MCP output.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected output: exits `0`; Swift MCP executable tests pass.

Failure handling: fix the first failing tool contract before enabling Stage 5 deletion readiness.

### Phase 8: Add Node MCP and Runtime Deletion Readiness Gates

**Purpose:** Make Stage 5 deletion mechanically safe without deleting Node in Stage 4.

**Files:**
- Create: `scripts/check-node-deletion-readiness.sh`
- Create or modify: `macos/EngramTests/NodeDeletionReadinessTests.swift`
- Modify: `macos/project.yml`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify after Stage 5 only: `package.json`

Readiness gates:

- App launches, indexes, watches, reports status, and serves UI data with Node daemon disabled.
- Swift MCP is the only documented MCP server path.
- Swift CLI replaces or explicitly deprecates every Node CLI workflow.
- App production code has no `Process` launch path for `node`, `npm`, `daemon.js`, `dist/index.js`, or `src/index.ts`.
- `macos/project.yml` has no active runtime dependency on `Bundle Node.js Daemon`; removal of the build phase itself happens in Stage 5 after parity.
- `Bundle Node.js Daemon`, `Resources/node`, and Node bundle scripts are classified as Stage 5 deletion targets, not required to disappear in Stage 4.
- Packaged app inspection can detect `Resources/node`, `node_modules`, `daemon.js`, `index.js`, `web.js`, `dist/`, or copied npm package trees.
- README and config examples do not instruct users to run `node dist/index.js` for shipped app/MCP runtime.
- `package.json` shipped runtime entries are listed for Stage 5 deletion after Node source deletion, not changed prematurely in Stage 4.

Steps:

- [ ] Add `scripts/check-node-deletion-readiness.sh` with source scans, Xcode project scans, README/CLAUDE scans, and app-bundle scans.
- [ ] Add `NodeDeletionReadinessTests` that run equivalent scans from XCTest for CI visibility.
- [ ] Add an Xcode build artifact inspection step that fails if Node runtime files exist in the final inspected `.app`.
- [ ] Run dual-run parity before any Stage 5 deletion handoff.
- [ ] Record remaining Node references as `historical reference`, `fixture generator`, or `Stage 5 deletion target`; no unmapped production reference may remain.
- [ ] Write the full Stage 4 evidence log to `docs/verification/swift-single-stack-stage4.md`, including command, date, commit, fixture DB path, service socket path, and first failing diff if any gate fails.

Command:

```bash
rtk bash scripts/check-node-deletion-readiness.sh
```

Expected output: exits `0`; reports only allowed historical/fixture references and no production runtime blockers.

Failure handling: map and remove production references before Stage 5 begins.

Command:

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/NodeDeletionReadinessTests
```

Expected output: exits `0`; XCTest scan gates pass.

Failure handling: do not begin Node deletion.

## Verification

Run the focused command for each phase while implementing. Before claiming Stage 4 complete, run the full suite:

```bash
rtk npm run build
```

Expected output: exits `0`; Node reference builds.

Failure handling: document the first failing build error and block Stage 5 deletion.

```bash
rtk npm test
```

Expected output: exits `0`; Node reference tests pass.

Failure handling: if unrelated and pre-existing, record exact failing test; if related to MCP, CLI, project operations, or fixtures, fix before Stage 4 acceptance.

```bash
rtk npm run lint
```

Expected output: exits `0`; lint passes.

Failure handling: fix lint before handoff.

```bash
rtk npm run generate:mcp-contract-fixtures
```

Expected output: exits `0`; all MCP golden fixtures are current.

Failure handling: regenerate or fix fixture generator before MCP parity claims.

```bash
rtk sh -lc 'cd macos && xcodegen generate'
```

Expected output: exits `0`; project regenerates.

Failure handling: fix `macos/project.yml` and rerun.

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected output: exits `0`; app/service/CLI-related tests pass.

Failure handling: fix first failing Stage 4 test before acceptance.

```bash
rtk xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected output: exits `0`; Swift MCP executable tests pass.

Failure handling: fix MCP routing or JSON contract.

```bash
rtk xcodebuild build -project macos/Engram.xcodeproj -scheme EngramCLI -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected output: exits `0`; Swift CLI builds.

Failure handling: fix Swift CLI target or project configuration.

```bash
rtk npx tsx scripts/compare-node-swift-mcp.ts --fixture-db tests/fixtures/mcp-contract.sqlite
```

Expected output: exits `0`; no unapproved Node-vs-Swift MCP JSON differences.

Failure handling: fix parity or add a reviewed allowlist entry with reason and deletion date.

```bash
rtk bash scripts/run-service-dual-parity.sh --pre-deletion --fixture-db tests/fixtures/mcp-contract.sqlite
```

Expected output: exits `0`; no unapproved Node-daemon-vs-Swift-service side-effect, DB checksum, indexing event, or read-after-write matrix differences.

Failure handling: fix service parity before Stage 5 readiness.

```bash
rtk bash scripts/check-node-deletion-readiness.sh
```

Expected output: exits `0`; Stage 5 deletion readiness scan passes without deleting Node.

Failure handling: remove or classify remaining production references.

```bash
rg 'DaemonClient|DaemonHTTPClientCore|ENGRAM_MCP_DAEMON_BASE_URL|/tmp/engram.sock|node dist/index\.js|dist/cli|Bundle Node.js Daemon|Resources/node' macos README.md CLAUDE.md docs --glob '!docs/archive/**' --glob '!docs/superpowers/**'
```

Expected output: no unmapped production runtime references; `Bundle Node.js Daemon`, `Resources/node`, and compatibility shims may appear only as explicit Stage 5 deletion targets linked from `docs/verification/swift-single-stack-stage4.md`.

Failure handling: replace production usage with Swift service/MCP/CLI paths or document as intentional deprecation before Stage 4 acceptance.

## Acceptance Gates

- [ ] Stage 3 real IPC gate has recorded passing evidence before Stage 4 code changes.
- [ ] `EngramServiceClient` has typed methods for every retained app, MCP, CLI, and daemon capability.
- [ ] No final production code exposes generic daemon HTTP methods such as `fetch<T>`, `post<T>`, `postRaw`, or raw `delete`.
- [ ] `EngramMCP` is the only shipped MCP implementation path planned for Stage 5, and all mutating/operational MCP tools route through service IPC.
- [ ] Pure read-only MCP tools use only `EngramCoreRead`, never `EngramCoreWrite`.
- [ ] `get_context include_environment=false` is pure `EngramCoreRead` and omits `environment`.
- [ ] `get_context include_environment=true` returns typed service-unavailable MCP error when service IPC is unavailable.
- [ ] Reachable service with partial environment-provider failure returns `environment.status = "degraded"` and `environment.warnings[]`, covered by `tests/fixtures/mcp-golden/get_context.engram.degraded.json`.
- [ ] Every service-backed MCP tool returns typed service-unavailable JSON and performs no SQLite/filesystem mutation when service IPC is unavailable.
- [ ] Read-after-write matrix tests pass for insight, project move, session-linking, summary, and title write/read pairs.
- [ ] Project move/archive/undo/batch/review/recover parity tests pass.
- [ ] Project operation crash-window tests prove filesystem hashes, migration rows, aliases, session CWD values, source directories, Gemini `projects.json`, lock files, and structured recovery recommendations are restored or precisely reported.
- [ ] Gemini `projects.json` wrapper layout, insertion order, apply ordering, reverse behavior, and collision detection match Node reference fixtures.
- [ ] Session linking, suggestions, export, handoff, replay timeline, lint, hygiene, live sessions, summary, and insight service-command tests pass.
- [ ] `DaemonClient.swift` and `DaemonHTTPClientCore.swift` have no production callers and are listed as Stage 5 deletion targets, but remain available as inert compatibility/reference files until Stage 5.
- [ ] `docs/swift-single-stack/cli-replacement-table.md` exists and is linked from README and CLAUDE.
- [ ] Swift CLI replaces or explicitly deprecates every Node CLI command before `src/cli/*.ts` becomes eligible for Stage 5 deletion.
- [ ] Swift CLI replacement covers the bare `engram` default MCP command as well as named subcommands before `src/cli/*.ts` becomes eligible for Stage 5 deletion.
- [ ] Node MCP and Swift MCP return equivalent JSON for all public tools on shared fixtures, except reviewed allowlisted improvements.
- [ ] Node daemon and Swift service side effects match for indexing events, DB row counts/checksums, project-operation migration rows, and read-after-write matrix outputs.
- [ ] `docs/verification/swift-single-stack-stage4.md` contains the Stage 4 evidence log consumed by Stage 5 prerequisites.
- [ ] `scripts/check-node-deletion-readiness.sh` and `NodeDeletionReadinessTests` pass as Stage 5 preflight gates.
- [ ] No Stage 4 commit deletes Node runtime source, Node packaging, or Node dependencies unless the deletion is one of the two no-caller compatibility shim files named in this plan.

## Rollback/Abort Guidance

- If Stage 3 real IPC serialization fails, abort Stage 4. Keep Swift mutating MCP/CLI disabled or fail-closed.
- If a service-backed MCP tool writes locally when the service is unavailable, revert that tool routing and block Stage 4 acceptance until fail-closed tests pass.
- If `get_context include_environment=true` returns partial local context when the service is missing, revert the fallback and return typed service-unavailable MCP JSON.
- If project operation compensation fails to restore or precisely report a mandatory crash window, keep the Node project tool path as reference and do not expose the Swift service command in MCP/CLI.
- If Gemini `projects.json` ordering or reverse behavior diverges from Node fixtures, block project-operation acceptance because adapter CWD resolution can silently corrupt session attribution.
- If app `DaemonClient` replacement leaves raw `/api/*` or localhost production references, keep the compatibility shim and continue replacement; do not delete shim files.
- If Swift CLI cannot replace a Node workflow, document deprecation in `docs/swift-single-stack/cli-replacement-table.md`, README, and CLAUDE, then add a deterministic deprecation-message test.
- If Node-vs-Swift MCP dual-run finds an unapproved JSON diff, block Stage 5 deletion. Fix Swift parity or add a reviewed allowlist entry with deletion date.
- If npm reference tests fail in MCP/project-operation areas, block Stage 4 parity claims because Node reference output is not trustworthy.
- Rollback before Stage 5 is to keep Node daemon/MCP/CLI reference paths intact and revert Stage 4 Swift routing changes. Do not create hidden Node fallback paths inside final Swift service code.

## Self-review Checklist

- [ ] The plan states that Stage 4 is blocked until Stage 3 real IPC gate passes.
- [ ] Every mutating MCP tool and project operation is service-backed, not direct SQLite or filesystem mutation from MCP.
- [ ] Direct MCP read tools are limited to pure `EngramCoreRead` use.
- [ ] `get_context` has all required contracts: pure read for `include_environment=false`, service/hybrid for `true`, typed service-unavailable for missing service, degraded warnings for partial provider failure, and the exact degraded fixture path.
- [ ] The CLI replacement table path is exact: `docs/swift-single-stack/cli-replacement-table.md`.
- [ ] README and CLAUDE linking requirements are explicit.
- [ ] Project operation crash windows are enumerated, including SIGINT/SIGTERM/crash and SIGKILL after `markMigrationFsDone`.
- [ ] Gemini `projects.json` ordering, wrapper preservation, append behavior, atomic write, reverse, unlink-empty, and collision probe semantics are explicit.
- [ ] Every phase lists exact file paths, commands, expected output, and failure handling.
- [ ] The plan does not instruct Stage 4 workers to delete Node runtime or packaging.
- [ ] The plan contains no unresolved planning markers or empty implementation guidance.
- [ ] The final verification suite includes npm reference checks, Swift tests, MCP parity, CLI build, and deletion-readiness scans.
