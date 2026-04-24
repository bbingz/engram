# Swift Single Stack MCP, CLI, and Project Ops Draft

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the remaining Node-owned MCP, CLI, daemon-client, and project-operation behavior with Swift service-backed implementations while preserving user-visible parity and single-writer safety.

**Architecture:** Keep `macos/EngramMCP` as the only shipped MCP server, but route every write-capable or long-running tool through `EngramServiceClient` instead of daemon HTTP or direct local writes. Replace `DaemonClient` and `macos/EngramCLI` with typed Swift service-client calls, port project move/archive/undo/recover compensation semantics into Swift, then prove Node MCP and Node CLI are deletion-ready through parity tests and packaging gates.

**Tech Stack:** Swift 5.9, XCTest, GRDB, service-unit IPC only through Unix-domain socket or XPC, Swift ArgumentParser, XcodeGen, TypeScript Node 20 reference fixtures, Vitest during parity migration.

---

## Scope Boundaries

This draft covers implementation planning unit 9 and unit 10 from the spec, plus the MCP/CLI/project-ops parts of unit 11 and deletion-readiness gates for unit 13.

This draft assumes earlier units have already created a shared Swift database/core layer and a running `EngramService` IPC boundary. If those units are not landed, implement them first. Do not expose Swift mutating MCP tools before `EngramMCP` can reach the shared writer process through `EngramServiceClient`.

This draft does not delete Node runtime files immediately. It makes deletion mechanically safe by moving every behavior behind Swift parity tests, typed service commands, and package inspection gates.

## Reference Files Already Inspected

- `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`
- `macos/EngramMCP/Core/MCPConfig.swift`
- `macos/EngramMCP/Core/MCPDatabase.swift`
- `macos/EngramMCP/Core/MCPFileTools.swift`
- `macos/EngramMCP/Core/MCPInsightsTool.swift`
- `macos/EngramMCP/Core/MCPStdioServer.swift`
- `macos/EngramMCP/Core/MCPToolRegistry.swift`
- `macos/EngramMCP/Core/MCPTranscriptTools.swift`
- `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- `macos/Shared/Networking/DaemonHTTPClientCore.swift`
- `macos/Engram/Core/DaemonClient.swift`
- `macos/Engram/Core/IndexerProcess.swift`
- `macos/Engram/Core/AppEnvironment.swift`
- `macos/EngramCLI/main.swift`
- `macos/project.yml`
- `src/index.ts`
- `src/web.ts`
- `src/core/daemon-client.ts`
- `src/tools/project.ts`
- `src/tools/export.ts`
- `src/tools/handoff.ts`
- `src/tools/link_sessions.ts`
- `src/tools/lint_config.ts`
- `src/tools/live_sessions.ts`
- `src/tools/project_timeline.ts`
- `src/tools/generate_summary.ts`
- `src/tools/save_insight.ts`
- `src/tools/get_memory.ts`
- `src/tools/get_insights.ts`
- `src/core/project-move/archive.ts`
- `src/core/project-move/batch.ts`
- `src/core/project-move/fs-ops.ts`
- `src/core/project-move/gemini-projects-json.ts`
- `src/core/project-move/git-dirty.ts`
- `src/core/project-move/lock.ts`
- `src/core/project-move/orchestrator.ts`
- `src/core/project-move/recover.ts`
- `src/core/project-move/retry-policy.ts`
- `src/core/project-move/sources.ts`
- `src/core/project-move/undo.ts`
- `src/cli/*.ts`

## File Map

Create these shared Swift service-boundary files:

- `macos/Shared/Service/EngramServiceClient.swift` — typed async client used by app, MCP helper, and CLI
- `macos/Shared/Service/EngramServiceProtocol.swift` — protocol that allows IPC and in-process test doubles to share one API
- `macos/Shared/Service/EngramServiceModels.swift` — request/response models for all mapped daemon endpoints and MCP service tools
- `macos/Shared/Service/EngramServiceError.swift` — service-unavailable, validation, retry-policy, and typed project-operation error envelope
- `macos/Shared/Service/EngramServiceTransport.swift` — transport abstraction; wraps the IPC transport created by the service unit
- `macos/Shared/Service/MockEngramServiceClient.swift` — deterministic app/MCP/CLI test double

Create these Swift project-operation parity files in service-only/write targets:

- `macos/EngramService/ProjectMove/ProjectMoveOrchestrator.swift` — Swift port of `src/core/project-move/orchestrator.ts`
- `macos/EngramService/ProjectMove/ProjectMoveFileOps.swift` — safe directory move, EXDEV fallback, symlink and partial-copy behavior
- `macos/EngramService/ProjectMove/ProjectMoveSources.swift` — source roots and project-dir encoders for claude-code, codex, gemini-cli, opencode, antigravity, copilot, iflow
- `macos/EngramService/ProjectMove/ProjectMoveJSONPatcher.swift` — atomic JSON/JSONL path replacement with concurrent-modification detection
- `macos/EngramService/ProjectMove/GeminiProjectsJSON.swift` — `~/.gemini/projects.json` plan/apply/reverse behavior
- `macos/EngramService/ProjectMove/ProjectMoveArchive.swift` — archive category normalization and target suggestion
- `macos/EngramService/ProjectMove/ProjectMoveBatch.swift` — YAML batch model and sequential runner
- `macos/EngramService/ProjectMove/ProjectMoveLock.swift` — advisory lock with stale PID handling
- `macos/EngramService/ProjectMove/ProjectMoveRecovery.swift` — stuck migration diagnosis and filesystem probing
- `macos/EngramService/ProjectMove/ProjectMoveErrors.swift` — `LockBusyError`, `DirCollisionError`, `SharedEncodingCollisionError`, `UndoNotAllowedError`, `UndoStaleError`, `InvalidUtf8Error`, retry policy mapping
- `macos/EngramService/ProjectMove/ProjectMoveFailureInjection.swift` — test-only seam compiled for tests to inject failure after each pipeline step

Modify these MCP files:

- `macos/EngramMCP/Core/MCPConfig.swift` — load service IPC endpoint and strict service requirement; keep daemon HTTP env only during dual-run parity tests
- `macos/EngramMCP/Core/MCPToolRegistry.swift` — route service-backed tools through `EngramServiceClient`
- `macos/EngramMCP/Core/MCPDatabase.swift` — remove remaining tool implementations that write or depend on live monitor/service state
- `macos/EngramMCP/Core/MCPFileTools.swift` — delete or narrow to pure read-only helpers after `link_sessions`, `lint_config`, and `project_review` move behind service
- `macos/EngramMCP/Core/MCPTranscriptTools.swift` — keep read-only transcript reads; move `export` and adapter-backed handoff paths to service
- `macos/EngramMCPTests/EngramMCPExecutableTests.swift` — full MCP tool contract parity and service-routing tests

Modify these app files:

- `macos/Engram/Core/DaemonClient.swift` — replace with compatibility facade over `EngramServiceClient`, then delete in the cutover task
- `macos/Shared/Networking/DaemonHTTPClientCore.swift` — mark as Node-daemon compatibility only, then delete after all callers are gone
- `macos/Engram/Core/IndexerProcess.swift` — replace Node stdout event ownership with service event subscription compatibility
- `macos/Engram/Core/AppEnvironment.swift` — replace daemon-port settings with service endpoint/test-double configuration
- `macos/Engram/App.swift` — inject `EngramServiceClient` and stop constructing `DaemonClient`
- `macos/Engram/MenuBarController.swift` — inject `EngramServiceClient`
- `macos/Engram/Core/EngramLogger.swift` — route log forwarding through service, not `/api/log`
- `macos/Engram/Views/**/*.swift` — replace generic URL/daemon endpoint calls with typed service-client methods

Modify these CLI and build files:

- `macos/EngramCLI/main.swift` — replace `/tmp/engram.sock` MCP bridge with Swift ArgumentParser commands
- `macos/project.yml` — add shared service/project-move sources to `Engram`, `EngramMCP`, `EngramCLI`, and tests; remove Node bundle script only in final deletion task
- `README.md` — replace Node MCP examples with Swift helper examples after parity gates pass
- `package.json` — keep until Stage 5 deletion; remove Node CLI/MCP bin only when Swift CLI replacement/deprecation is complete
- `src/index.ts`, `src/web.ts`, `src/tools/*.ts`, `src/cli/*.ts`, `src/core/project-move/*` — reference-only during parity; delete only in the final Node deletion task

Create or modify these tests and fixtures:

- `macos/EngramTests/EngramServiceClientMappingTests.swift`
- `macos/EngramTests/ProjectMoveCompensationTests.swift`
- `macos/EngramTests/ProjectMoveParityTests.swift`
- `macos/EngramTests/EngramCLITests.swift`
- `macos/EngramTests/DaemonClientRemovalTests.swift`
- `macos/EngramTests/NodeDeletionReadinessTests.swift`
- `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- `scripts/gen-mcp-contract-fixtures.ts`
- `tests/fixtures/mcp-golden/*.json`
- `tests/fixtures/project-move/**`
- `tests/fixtures/service-client/**`

## Complete DaemonClient To ServiceClient Mapping

The implementation must replace every raw daemon HTTP affordance with a typed `EngramServiceClient` method. Generic `fetch`, `post`, `postRaw`, and `delete` methods are not allowed in final app code because they hide unmapped Node endpoint dependencies.

| Current caller or endpoint | Current source | Swift service-client method | Final owner | Notes |
| --- | --- | --- | --- | --- |
| `DaemonClient.fetch<T>(_:)` | `DaemonClient.swift` | Delete generic method | N/A | Replace all call sites with typed methods before deletion |
| `DaemonClient.post<T>(_:)` | `DaemonClient.swift` | Delete generic method | N/A | Replace all call sites with typed methods before deletion |
| `DaemonClient.postRaw(_:)` | `DaemonClient.swift` | Delete generic method | N/A | No final raw endpoint posting |
| `DaemonClient.delete(_:)` | `DaemonClient.swift` | Delete generic method | N/A | Replace with typed deletion commands |
| `GET /api/status` | `src/web.ts` | `status()` | Service | Dashboard/service-ready model |
| `GET /api/sessions` | `src/web.ts` | `listSessions(_:)` | Core read or Service | UI may use Core read facade; service client keeps parity for former HTTP consumers |
| `GET /api/sessions/:id` | `src/web.ts` | `getSession(id:)` | Core read or Service | Preserve `Session` decoding shape |
| `POST /api/sessions/:id/link` | `DaemonClient.linkSession` | `linkSession(sessionID:parentID:)` | Service write | Must serialize through writer |
| `DELETE /api/sessions/:id/link` | `DaemonClient.unlinkSession` | `unlinkSession(sessionID:)` | Service write | Must serialize through writer |
| `POST /api/sessions/:id/confirm-suggestion` | `DaemonClient.confirmSuggestion` | `confirmSuggestedParent(sessionID:)` | Service write | Preserve `{ok,error?}` shape |
| `DELETE /api/sessions/:id/suggestion` | `DaemonClient.dismissSuggestion` | `dismissSuggestedParent(sessionID:suggestedParentID:)` | Service write | Preserve stale-suggestion conflict |
| `GET /api/sessions/:id/children` | `src/web.ts` | `childSessions(parentID:limit:offset:)` | Core read or Service | Used by session tree views |
| `GET /api/sessions/:id/timeline` | `SessionReplayView` | `replayTimeline(sessionID:limit:offset:)` | Service | Requires adapters; not direct DB-only |
| `POST /api/session/:id/resume` | `ResumeDialog`, Node CLI | `resumeCommand(sessionID:)` | Service | Swift CLI `resume` also uses this |
| `GET /api/search/status` | `SearchPageView`, `PopoverView`, `SearchView` | `searchStatus()` | Service | Preserve model, embedded count, progress |
| `GET /api/search` | `SearchPageView`, `GlobalSearchOverlay`, `CommandPaletteView` | `search(_:)` | Core read or Service | Replace direct `URLSession` calls |
| `GET /api/search/semantic` | `src/web.ts` | `semanticSearch(_:)` or deleted | Service | If deleted, document replacement by `search(mode:.semantic)` |
| `GET /api/stats` | `src/web.ts` | `stats(_:)` | Core read or Service | Preserve `exclude_noise` option for UI |
| `GET /api/costs` | `src/web.ts` | `costs(_:)` | Core read or Service | Must match MCP `get_costs` result model |
| `GET /api/costs/sessions` | `src/web.ts` | `costSessions(limit:)` | Core read or Service | Needed for dashboard parity if UI consumes it |
| `GET /api/file-activity` | `src/web.ts` | `fileActivity(_:)` | Core read or Service | Must match MCP `file_activity` fields |
| `GET /api/tool-analytics` | `src/web.ts` | `toolAnalytics(_:)` | Core read or Service | Must match MCP `tool_analytics` fields |
| `GET /api/usage` | `src/web.ts` | `usageSnapshots()` | Service | Comes from live usage collector |
| `GET /api/repos` | `src/web.ts` | `gitRepos()` | Core read or Service | Preserve UI table shape |
| `GET /api/project-aliases` | `src/web.ts` | `listProjectAliases()` | Core read or Service | Read-only allowed direct through Core |
| `POST /api/project-aliases` | `src/index.ts` | `addProjectAlias(alias:canonical:actor:)` | Service write | Used by MCP `manage_project_alias` |
| `DELETE /api/project-aliases` | `src/index.ts` | `removeProjectAlias(alias:canonical:actor:)` | Service write | Used by MCP `manage_project_alias` |
| `GET /api/project/migrations` | `DaemonClient.listProjectMigrations` | `listProjectMigrations(state:limit:since:)` | Core read or Service | Preserve state filter behavior |
| `GET /api/project/cwds` | `DaemonClient.projectCwds` | `projectCwds(project:)` | Core read or Service | Drives rename/archive sheets |
| `POST /api/project/move` | `DaemonClient.projectMove`, MCP | `projectMove(_:)` | Service write | Must fail closed when service unavailable |
| `POST /api/project/undo` | `DaemonClient.projectUndo`, MCP | `projectUndo(_:)` | Service write | Must preserve stale checks |
| `POST /api/project/archive` | `DaemonClient.projectArchive`, MCP | `projectArchive(_:)` | Service write | Preserve CJK and English category aliases |
| `POST /api/project/move-batch` | MCP | `projectMoveBatch(_:)` | Service write | Sequential and lock-protected |
| `POST /api/summary` | `generate_summary`, Session views | `generateSummary(sessionID:actor:)` | Service write | Updates DB summary and audit |
| `POST /api/insight` | `save_insight` | `saveInsight(_:)` | Service write | Text-only fallback and vector dual-write parity |
| `POST /api/handoff` | `SessionDetailView`, MCP | `handoff(_:)` | Service | Adapter-backed; not raw DB-only |
| `POST /api/link-sessions` | MCP | `linkSessions(targetDir:)` | Service filesystem write | Creates symlinks; not direct MCP write |
| `POST /api/session/:id/generate-title` | `src/web.ts` | `generateTitle(sessionID:)` | Service write | Preserve configured title provider behavior |
| `POST /api/titles/regenerate-all` | `AISettingsSection` | `regenerateAllTitles()` | Service job | Return started/total/message |
| `GET /api/health/sources` | `src/web.ts` | `sourceHealth()` | Service | Uses filesystem/source paths |
| `GET /health` | `PopoverView` direct URL | `health()` or deleted UI link | Service or deleted | Non-API daemon health URL must not leave a localhost link behind |
| `GET /api/sources` | `SourcePulseView` | `sources()` | Core read or Service | Preserve source stats |
| `GET /api/skills` | `SkillsView` | `skills()` | Service filesystem read | Reads Claude plugin/settings files |
| `GET /api/memory` | `MemoryView` | `memoryFiles()` | Service filesystem read | Reads Claude memory files |
| `GET /api/hooks` | `HooksView` | `hooks()` | Service filesystem read | Reads Claude settings files |
| `GET /api/hygiene` | `DaemonClient.fetchHygieneChecks` | `hygiene(force:)` | Service | Runs health checks; preserve score/issues |
| `GET /api/live` | `SourcePulseView`, menu bar | `liveSessions()` | Service | Uses live monitor and DB enrichment |
| `GET /api/monitor/alerts` | `src/web.ts` | `monitorAlerts()` | Service | Preserve undismissed/total fields |
| `POST /api/monitor/alerts/:id/dismiss` | `src/web.ts` | `dismissMonitorAlert(id:)` | Service write | Alert state mutation |
| `POST /api/lint` | `src/web.ts` | `lintConfig(cwd:)` | Service filesystem read | Same validator as MCP `lint_config` |
| `POST /api/log` | `EngramLogger` | `recordLog(_:)` | Service write | Do not use HTTP post after cutover |
| `GET /api/ai/audit` | `src/web.ts` | `aiAudit(_:)` | Service or documented deletion | Must not silently disappear if UI/docs expose it |
| `GET /api/ai/audit/:id` | `src/web.ts` | `aiAuditRecord(id:)` | Service or documented deletion | Preserve auth sensitivity if retained |
| `GET /api/ai/stats` | `src/web.ts` | `aiAuditStats(_:)` | Service or documented deletion | Required if audit UI remains |
| `GET /api/sync/status` | `NetworkSettingsSection` | `syncStatus()` | Service or documented deletion | Preserve sync settings behavior if retained |
| `GET /api/sync/sessions` | `src/web.ts` | `syncSessions(_:)` | Service or documented deletion | Peer sync compatibility decision required |
| `POST /api/sync/trigger` | `NetworkSettingsSection` | `triggerSync(peer:)` | Service job | Replace direct URL call |
| `POST /api/dev/mock` | `src/web.ts` | No production protocol method | Omit from production `EngramServiceProtocol`; allow only `#if DEBUG` or test-only `MockEngramServiceClient` behavior | Production route must be unavailable and tested as 404/unsupported if accidentally addressed |
| `DELETE /api/dev/mock` | `src/web.ts` | No production protocol method | Omit from production `EngramServiceProtocol`; allow only `#if DEBUG` or test-only `MockEngramServiceClient` behavior | Production route must be unavailable and tested as 404/unsupported if accidentally addressed |

Acceptance gate for this mapping: `rg 'DaemonClient|DaemonHTTPClientCore|/api/|http://127\\.0\\.0\\.1|http://localhost|ENGRAM_MCP_DAEMON_BASE_URL|daemonPort|node dist/index\\.js|dist/index\\.js|dist/daemon\\.js' macos README.md CLAUDE.md docs --glob '!docs/archive/**' --glob '!docs/superpowers/**'` returns only documented historical references and tests explicitly named as Node-reference golden fixtures.

## Task 1: Add Typed Service Client And Mapping Tests

**Files:**

- Create: `macos/Shared/Service/EngramServiceClient.swift`
- Create: `macos/Shared/Service/EngramServiceProtocol.swift`
- Create: `macos/Shared/Service/EngramServiceModels.swift`
- Create: `macos/Shared/Service/EngramServiceError.swift`
- Create: `macos/Shared/Service/EngramServiceTransport.swift`
- Create: `macos/Shared/Service/MockEngramServiceClient.swift`
- Create: `macos/EngramTests/EngramServiceClientMappingTests.swift`
- Modify: `macos/project.yml`

Steps:

- [ ] Write failing tests in `EngramServiceClientMappingTests` that assert every row in the mapping table has a typed `EngramServiceProtocol` method.
- [ ] Add a test that fails if app code still calls generic `DaemonClient.fetch`, `DaemonClient.post`, `DaemonClient.postRaw`, or `DaemonClient.delete`.
- [ ] Add a test that fails if app code constructs raw localhost `/api/*` URLs outside test fixtures.
- [ ] Define request and response models in `EngramServiceModels.swift` for project migrations, project move results, lint results, live sessions, hygiene results, replay timeline, handoff, session linking, insights, title generation, sync, audit, skills, hooks, memory files, usage, and monitor alerts.
- [ ] Define `EngramServiceError` with fields equivalent to Node `{error:{name,message,retry_policy,details?}}`, including `sourceId`, `oldDir`, `newDir`, `sharingCwds`, `migrationId`, `state`, and lock-holder details.
- [ ] Implement transport-neutral client methods in `EngramServiceClient.swift`; do not expose a method that accepts an arbitrary path string.
- [ ] Add `MockEngramServiceClient` canned responses for all models so app/MCP/CLI tests do not need a running service.
- [ ] Update `macos/project.yml` so `Shared/Service` is compiled into `Engram`, `EngramMCP`, `EngramCLI`, and unit tests.
- [ ] Do not delete `DaemonClient.swift` or `DaemonHTTPClientCore.swift` in Stage 4 until Stage 3 app acceptance is complete and source scans prove every `@Environment(DaemonClient.self)`, `DaemonHTTPClientCore`, and raw daemon HTTP UI usage has been replaced.

Verification:

- `cd macos && xcodegen generate`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/EngramServiceClientMappingTests`
- `rg 'func (fetch|post|postRaw|delete)<' macos/Engram macos/Shared` must find no final service-client API.

## Task 2: Route Swift MCP Through Service For Mutating And Operational Tools

**Files:**

- Modify: `macos/EngramMCP/Core/MCPConfig.swift`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramMCP/Core/MCPFileTools.swift`
- Modify: `macos/EngramMCP/Core/MCPTranscriptTools.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Modify: `scripts/gen-mcp-contract-fixtures.ts`
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

Direct read-only MCP tools that may remain `EngramCore` backed:

- `list_sessions`
- `get_session`
- `search`
- `get_context` when `include_environment=false` is pure read-only `EngramCoreRead` mode; it must not contact the service and must omit live environment fields rather than pretending they are degraded. Default `include_environment=true` must be service-backed or hybrid because it reads live monitor state, alerts, health checks, and config lint results.
- `get_memory`
- `get_costs`
- `get_insights`
- `stats`
- `tool_analytics`
- `file_activity`
- `project_timeline`
- `project_list_migrations`
- `manage_project_alias` for `list`

Read-after-write consistency rule: direct `EngramCoreRead` tools such as `get_memory` and `get_insights` may remain local only if service write acknowledgements refresh or invalidate reader pools before the next direct read. If this cannot be proven with tests after `save_insight`, route those reads through service too.

`get_context` environment contract:

- `include_environment=false`: return read-only context from `EngramCoreRead`, omit `environment`, and do not contact service.
- `include_environment=true` and service unavailable: return typed service-unavailable MCP JSON; do not return partial context.
- `include_environment=true` and service reachable: return `environment.status = "ok"` when all environment providers succeed.
- `include_environment=true` and service reachable but a provider fails: return `environment.status = "degraded"`, include `environment.warnings[]` with provider, code, and message fields, and cover this shape with `tests/fixtures/mcp-golden/get_context.engram.degraded.json`.
- `environment.status = "unavailable"` is reserved for service responses where the service is reachable but a specific environment subsystem is intentionally disabled; missing service itself remains a typed MCP error.

Steps:

- [ ] Add failing MCP executable tests that run each service-backed tool with the service endpoint unavailable and assert a typed service-unavailable MCP error.
- [ ] Add `get_context` tests for all three modes: `include_environment=false` reads local `EngramCoreRead`, does not contact service, and omits live environment fields; `include_environment=true` with no service returns typed service-unavailable JSON and no partial context; reachable service with one failing environment provider returns a degraded environment payload with warnings.
- [ ] Assert those unavailable-service tests do not change the fixture database and do not create filesystem artifacts such as export files, symlinks, archive directories, or project-move lock files.
- [ ] Add mock-service happy-path tests for every service-backed tool and verify request actor values are `mcp` except `project_move_batch`, which must preserve per-operation `batch` actor semantics.
- [ ] Update `MCPConfig` to read the service endpoint from the service unit's final environment variable. During dual-run only, allow `ENGRAM_MCP_DAEMON_BASE_URL` for Node-reference tests, but put that behind an explicit test-only or compatibility flag.
- [ ] Replace direct `DaemonHTTPClientCore` construction in `MCPToolRegistry` with `EngramServiceClient`.
- [ ] Preserve ordered JSON output for golden-tested tools, including `project_archive` converting service `suggestion` into MCP `archive`, `project_move` adding `resolved` when `~` expands, and `save_insight` retaining `duplicateWarning` and `warning`.
- [ ] Move `link_sessions`, `export`, `handoff`, `lint_config`, `live_sessions`, `project_review`, and `project_recover` out of in-process MCP helpers when they write files, read live service state, or probe broad filesystem state.
- [ ] Keep read-only transcript access for `get_session` local only if it does not mutate state and has adapter parity from earlier units.
- [ ] Extend `scripts/gen-mcp-contract-fixtures.ts` so Node and Swift goldens cover every public MCP tool, every service-backed happy path, and service-unavailable errors.

Verification:

- `npm run generate:mcp-contract-fixtures`
- `cd macos && xcodegen generate`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- `rg 'DaemonHTTPClientCore|ENGRAM_MCP_DAEMON_BASE_URL|handleProjectMove\\(|handleSaveInsight\\(|handleLinkSessions\\(' macos/EngramMCP --glob '!**/*Tests*'` must return no production direct-write routing.

## Task 3: Port Project Move, Archive, Undo, Batch, Review, And Recover Parity

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
- Create: `macos/EngramTests/ProjectMoveCompensationTests.swift`
- Create: `macos/EngramTests/ProjectMoveParityTests.swift`
- Modify: `macos/project.yml`
- Reference: `src/core/project-move/*`

Required parity behavior:

- `project_move` canonicalizes paths before validation, rejects empty paths, rejects `src == dst`, rejects destination inside source, rejects source inside destination, and expands `~`.
- Git dirty detection handles `.git` directories and `.git` files, returns `untrackedOnly`, and blocks unless `force` is true.
- Dry-run returns the same `PipelineResult` shape as committed moves with `state: dry-run`, real per-source scan counts, `renamedDirs`, `skippedDirs`, `perSource`, `git`, and `manifest`.
- Locking uses one advisory lock under `~/.engram/.project-move.lock`, detects stale holders by PID, and releases on every success or failure path.
- Physical moves preserve symlinks, mode bits, timestamps, and support cross-volume copy-then-delete with partial-copy cleanup.
- Cross-volume copy-then-delete must handle source-delete failure explicitly: if `src` is still intact after copy, remove the duplicate `dst`; if source integrity is uncertain, report duplicate-tree recovery state without claiming rollback success.
- Per-source directory rename plans cover `claude-code`, `gemini-cli`, and `iflow`, with `codex`, `opencode`, `antigravity`, and `copilot` as content-scan-only roots.
- Gemini basename collisions and `projects.json` shared-cwd hijacks throw before any filesystem mutation.
- `projects.json` update planning, atomic apply, and snapshot reverse match the TypeScript implementation.
- JSON/JSONL patching is atomic, UTF-8 safe, and detects concurrent modification rather than committing partial path replacements.
- `markMigrationFsDone` happens only after filesystem work completes and before DB commit.
- DB commit updates `sessions`, `session_local_state`, aliases, affected session IDs, and migration log details in one transaction.
- Compensation reverses file patches, Gemini `projects.json`, per-source dir renames, and the physical move in LIFO order.
- `project_archive` accepts `历史脚本`, `空项目`, `归档完成`, `historical-scripts`, `empty-project`, and `archived-done`, but stores canonical CJK category directories.
- Archive dry-run must not create `_archive/<category>/` directories.
- Batch archive dry-run with `archive:true` must also create no `_archive/<category>/` directories and no parent directories; if Node currently creates them, mark that as an intentional Swift safety fix with fixture coverage.
- `project_undo` only accepts committed migrations, validates the current `newPath` and affected session cwd ownership, then records a new migration with `rolledBackOf`.
- `project_recover` remains diagnostic only and must not modify filesystem or database state.

Failure-injection tests:

- [ ] Inject failure after lock acquisition but before `migration_log` start; assert no stale migration row and lock released.
- [ ] Inject failure after `startMigration` and before physical move; assert source exists, destination absent, migration failed, lock released.
- [ ] Inject failure after physical move; assert destination moved back to source, migration failed, lock released.
- [ ] Inject failure after cross-volume copy succeeds but source delete fails; assert intact source leads to duplicate destination cleanup, otherwise recover reports duplicate-tree state.
- [ ] Inject failure after first per-source dir rename; assert renamed dirs restored, physical move reverted, migration failed.
- [ ] Inject failure after Gemini `projects.json` apply; assert original file contents restored byte-for-byte.
- [ ] Inject SIGTERM after Gemini `projects.json` apply but before Gemini tmp directory rename; assert recovery restores `projects.json` first and reports the tmp directory rename as not yet applied.
- [ ] Inject failure after one JSON/JSONL file patch; assert patched file restored and all unpatched files untouched.
- [ ] Inject `InvalidUtf8Error` from a matched session file; assert the whole pipeline aborts and compensates.
- [ ] Inject concurrent modification during patch; assert the whole pipeline aborts and compensates.
- [ ] Inject failure after `markMigrationFsDone` and before DB commit; assert filesystem compensation completes and recover reports a failed migration with useful recommendation.
- [ ] Inject failure during DB apply; assert sessions and aliases remain unchanged or transaction rolls back, filesystem compensation completes, and lock releases.
- [ ] Inject compensation failure for a reverse patch; assert failure report includes `patchFailed` and does not claim success.
- [ ] Inject compensation failure for source-dir restore; assert failure report includes `dirRestoreErrors`.
- [ ] Inject compensation failure for physical move-back; assert failure report includes `moveRevertError`.
- [ ] Run the same injection matrix for archive and undo paths because both wrap the same orchestrator with different `archived` and `rolledBackOf` metadata.
- [ ] Kill the service with SIGINT/SIGTERM/crash after lock acquisition, after `startMigration`, after physical move, and after `markMigrationFsDone`; assert stale lock handling, migration state, and `project_recover` recommendations are correct.
- [ ] Add a SIGKILL-specific case after `markMigrationFsDone` and before DB commit; assert recovery reports exact `migration_state`, `lock_state`, filesystem duplicate/restored state, and the safe next action without claiming success.

Parity tests:

- [ ] Build fixtures with all seven source roots: claude-code encoded cwd, codex date tree, gemini tmp basename tree, iflow lossy encoded path, opencode data root, antigravity data root, and copilot session-state root.
- [ ] Compare Swift dry-run `PipelineResult` against Node dry-run fixture output for file counts, occurrence counts, `renamedDirs`, `skippedDirs`, `perSource`, `git`, and `manifest`.
- [ ] Compare Swift committed move output against Node output with UUIDs and timestamps normalized.
- [ ] Compare Swift archive suggestions against Node for CJK and English category inputs.
- [ ] Compare Swift recover recommendations against Node for `fs_pending`, `fs_done`, `failed`, and `committed` rows.
- [ ] Compare Swift retry-policy mapping against `src/core/project-move/retry-policy.ts` for all named errors.

Verification:

- `cd macos && xcodegen generate`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/ProjectMoveCompensationTests`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/ProjectMoveParityTests`
- `npm test -- src/core/project-move` remains required until Node deletion, so Swift output can continue to be compared to the reference.

## Task 4: Port Session Linking, Suggestions, Export, Handoff, Timeline, Lint, Hygiene, And Live Sessions

**Files:**

- Create: `macos/Shared/Operations/SessionLinkingService.swift`
- Create: `macos/Shared/Operations/TranscriptExportService.swift`
- Create: `macos/Shared/Operations/HandoffService.swift`
- Create: `macos/Shared/Operations/ReplayTimelineService.swift`
- Create: `macos/Shared/Operations/ConfigLintService.swift`
- Create: `macos/Shared/Operations/HygieneService.swift`
- Create: `macos/Shared/Operations/LiveSessionsService.swift`
- Create: `macos/EngramTests/SessionOperationsParityTests.swift`
- Modify: `macos/project.yml`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Reference: `src/tools/link_sessions.ts`
- Reference: `src/tools/export.ts`
- Reference: `src/tools/handoff.ts`
- Reference: `src/tools/lint_config.ts`
- Reference: `src/tools/live_sessions.ts`
- Reference: `src/web.ts`

Steps:

- [ ] Port session parent-link commands into service methods: link, unlink, confirm suggestion, dismiss suggestion, child-session reads, and stale-suggestion conflicts.
- [ ] Add service-command tests proving link/unlink/confirm/dismiss mutate only through the service writer and preserve Node response shapes.
- [ ] Port `link_sessions` symlink creation with absolute-target validation, alias resolution, source subdirectories, existing symlink replacement, skipped count, errors, and `truncated` behavior at 10,000 sessions.
- [ ] Port `export` through service because it writes to `~/codex-exports`; preserve Markdown and JSON output names, message streaming via adapters, and output path response fields.
- [ ] Port `handoff` through service because it uses adapters to read last user messages; preserve `markdown` and `plain` formatting, cost rows, recent-session ordering, alias fallback, and empty-project text.
- [ ] Port replay timeline through service because it streams adapter messages; preserve limit, offset, `hasMore`, `durationToNextMs`, token fields, tool-call type, and adapter-missing errors.
- [ ] Port `lint_config` to Swift with the same config candidates, backtick reference extraction, path-traversal guard, npm script checks, similar-file suggestions, health-rule aggregation, and score model.
- [ ] Port hygiene checks behind service, including `force` behavior and global scope parity.
- [ ] Port `live_sessions` to service monitor state, including filtering subagents/global dash projects, DB enrichment with generated title/summary/project/model, tier/agent-role filtering, and dedupe by source plus project/cwd/filePath.
- [ ] Add MCP golden tests for all these tools in both happy and representative error cases.

Verification:

- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/SessionOperationsParityTests`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- `npm run generate:mcp-contract-fixtures`

## Task 5: Replace Swift App `DaemonClient` With `EngramServiceClient`

**Files:**

- Modify: `macos/Engram/Core/DaemonClient.swift`
- Modify: `macos/Shared/Networking/DaemonHTTPClientCore.swift`
- Modify: `macos/Engram/Core/AppEnvironment.swift`
- Modify: `macos/Engram/Core/IndexerProcess.swift`
- Modify: `macos/Engram/Core/EngramLogger.swift`
- Modify: `macos/Engram/App.swift`
- Modify: `macos/Engram/MenuBarController.swift`
- Modify: `macos/Engram/Views/SessionListView.swift`
- Modify: `macos/Engram/Views/SessionDetailView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift`
- Modify: `macos/Engram/Views/Pages/*.swift`
- Modify: `macos/Engram/Views/Projects/*.swift`
- Modify: `macos/Engram/Views/Replay/SessionReplayView.swift`
- Modify: `macos/Engram/Views/Resume/ResumeDialog.swift`
- Modify: `macos/Engram/Views/Settings/*.swift`
- Create: `macos/EngramTests/DaemonClientRemovalTests.swift`
- Modify: `macos/Engram/TestSupport/MockDaemonFixtures.swift` or replace with `MockEngramServiceFixtures.swift`

Steps:

- [ ] Add failing `DaemonClientRemovalTests` that scan Swift source and fail on raw `/api/`, localhost URL construction, `DaemonClient` environment injection, and `DaemonHTTPClientCore` usage outside compatibility tests.
- [ ] Introduce `EngramServiceClient` into `App.swift` and the environment tree while keeping `DaemonClient` as a thin compatibility facade for one transition commit only.
- [ ] Replace every `@Environment(DaemonClient.self)` with `@Environment(EngramServiceClient.self)` or a protocol-typed wrapper.
- [ ] Replace all direct project calls: migrations, cwds, move, archive, undo.
- [ ] Replace session linking and suggestion calls in session list, home, timeline, details, and pages.
- [ ] Replace generic fetch calls for skills, sources, memory, hooks, live sessions, hygiene, replay timeline, and handoff.
- [ ] Replace direct `URLSession` search/status/sync/title/summary/resume/log calls with typed service-client methods.
- [ ] Replace `IndexerProcess` process-launch state with a service event adapter that preserves existing UI-facing fields: status, total sessions, today parent sessions, port/service endpoint, usage data, last summary session ID.
- [ ] Delete `DaemonClient.swift` and `DaemonHTTPClientCore.swift` only after the scan test passes and app tests use service fixtures.

Verification:

- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/DaemonClientRemovalTests`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- `rg 'DaemonClient|DaemonHTTPClientCore|http://127\\.0\\.0\\.1|http://localhost|/api/' macos/Engram macos/Shared --glob '!**/*Tests*'` must return no app production dependencies on Node daemon HTTP.

## Task 6: Replace Or Deprecate Node CLI With Swift CLI

**Files:**

- Modify: `macos/EngramCLI/main.swift`
- Create: `macos/EngramCLI/Commands/MCPCommand.swift`
- Create: `macos/EngramCLI/Commands/ProjectCommand.swift`
- Create: `macos/EngramCLI/Commands/HealthCommand.swift`
- Create: `macos/EngramCLI/Commands/LogsCommand.swift`
- Create: `macos/EngramCLI/Commands/TracesCommand.swift`
- Create: `macos/EngramCLI/Commands/ResumeCommand.swift`
- Create: `macos/EngramCLI/Commands/DeprecatedCommand.swift`
- Create: `macos/EngramTests/EngramCLITests.swift`
- Create: `docs/swift-single-stack/cli-replacement-table.md`
- Modify: `macos/project.yml`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Reference: `src/cli/index.ts`
- Reference: `src/cli/project.ts`
- Reference: `src/cli/health.ts`
- Reference: `src/cli/logs.ts`
- Reference: `src/cli/traces.ts`
- Reference: `src/cli/resume.ts`

Required CLI behavior:

- `engram mcp` runs the Swift stdio MCP helper or the same MCP server code path without using `/tmp/engram.sock`.
- `engram project move <src> <dst>` supports `--yes`, `--dry-run`, `--force`, `--note`, and displays dry-run source breakdown, skipped dirs, scan issues, git dirty warning, migration ID, and residual review summary.
- `engram project archive <src>` supports `--to`, `--yes`, `--dry-run`, `--force`, and `--note`.
- `engram project review <old> <new>` supports text and markdown output.
- `engram project undo <migration-id>` supports `--force`.
- `engram project list` supports `--since`.
- `engram project recover` supports `--since` and `--include-committed`.
- `engram project move-batch <yaml-file>` supports `--force` and preserves batch schema v1 behavior.
- `engram health` and `engram diagnose` read Swift observability repositories and support `--since`, `--last`, and `--json`.
- `engram logs` supports `--level`, `--module`, `--trace-id`, `--since`, `--last`, `--limit`, and `--json`.
- `engram traces` supports `--slow`, `--name`, `--trace-id`, `--since`, `--last`, `--limit`, and `--json`.
- `engram --resume` and `engram -r` become `engram resume` or remain as aliases, but use `EngramServiceClient.resumeCommand`.
- Any Node CLI subcommand that is intentionally removed must have an explicit deprecation message, docs entry, and test asserting the message.

Steps:

- [ ] Replace the current Unix socket HTTP bridge in `main.swift`; no final CLI command may POST JSON-RPC to `MCPServer.swift`.
- [ ] Add ArgumentParser command tree and service-client injection.
- [ ] Implement project commands on top of `EngramServiceClient`, not direct project-move files, so CLI writes share the same serialized writer as MCP and app.
- [ ] Preserve friendly error rendering by mapping `retry_policy` to safe, conditional, wait, and never hints.
- [ ] Add CLI fixture tests that compare Swift output against Node CLI output with ANSI stripped and UUIDs/timestamps normalized.
- [ ] Create `docs/swift-single-stack/cli-replacement-table.md` with one row per current Node CLI command, link it from README and CLAUDE, and require it before Stage 4 CLI work is accepted.
- [ ] Update README and CLAUDE terminal workflow docs to use Swift CLI commands and record any intentionally deprecated Node-only commands.
- [ ] Remove `src/cli/*.ts` only in the final deletion task after Swift CLI tests pass and docs no longer reference Node CLI entry points.

Verification:

- `xcodebuild build -project macos/Engram.xcodeproj -scheme EngramCLI -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/EngramCLITests`
- `rg 'dist/cli|src/cli|node .*engram|/tmp/engram.sock|MCPServer' README.md macos/EngramCLI macos/project.yml --glob '!docs/archive/**'` must return only explicit deprecation notes or deleted-history references before Node deletion.

## Task 7: Expand MCP Full-Parity And Dual-Run Gates

**Files:**

- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Modify: `scripts/gen-mcp-contract-fixtures.ts`
- Create: `scripts/compare-node-swift-mcp.ts`
- Create: `tests/fixtures/mcp-golden/service-unavailable/*.json`
- Modify: `tests/fixtures/mcp-golden/*.json`
- Modify: `src/index.ts` only to add reference fixture generation hooks before deletion

Steps:

- [ ] Ensure `tools/list` still exposes the same 26 public tools until a documented removal exists.
- [ ] Add golden tests for every public tool, not just representative reads and selected writes.
- [ ] Add error-shape tests for missing required params, invalid enum values, service unavailable, lock busy, stale undo, invalid UTF-8, concurrent modification, path collision, stale suggestion, missing session, missing adapter, and export/write permission errors.
- [ ] Add dual-run harness that calls Node MCP and Swift MCP against the same fixture DB and fixture home, with only one writer active at a time.
- [ ] Normalize fields that are intentionally nondeterministic: UUIDs, timestamps, temp directory suffixes, trace IDs, and absolute fixture roots.
- [ ] Fail the dual-run harness on any unapproved JSON difference.
- [ ] Maintain a small allowlist for intentional Swift-only improvements. Each allowlist entry must name the tool, field path, reason, and deletion date.
- [ ] Add tests proving service-backed Swift MCP fails closed when service IPC is unavailable and does not fall back to direct database or filesystem writes.

Verification:

- `npm run build`
- `npm run generate:mcp-contract-fixtures`
- `npx tsx scripts/compare-node-swift-mcp.ts --fixture-db tests/fixtures/mcp-contract.sqlite`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

## Task 8: Add Node MCP And Runtime Deletion Readiness Gates

**Files:**

- Create: `scripts/check-node-deletion-readiness.sh`
- Create: `macos/EngramTests/NodeDeletionReadinessTests.swift`
- Modify: `macos/project.yml`
- Modify: `README.md`
- Modify: `package.json`
- Delete in final cutover only: `src/index.ts`
- Delete in final cutover only: `src/web.ts`
- Delete in final cutover only: `src/tools/*.ts`
- Delete in final cutover only: `src/cli/*.ts`
- Delete in final cutover only: `macos/Engram/Core/MCPServer.swift`
- Delete in final cutover only: `macos/Engram/Core/MCPTools.swift`
- Delete in final cutover only: Node bundle scripts and build phases that copy `dist/`, `node_modules`, `daemon.js`, `index.js`, or `web.js`

Readiness gates:

- `Engram.app` launches, indexes, watches, reports status, and serves UI data with Node daemon disabled.
- Swift MCP is the only documented MCP server.
- Swift CLI replaces or explicitly deprecates every Node CLI workflow.
- App production code has no `Process` launch path for `node`, `npm`, `daemon.js`, `dist/index.js`, or `src/index.ts`.
- `macos/project.yml` has no prebuild script named `Bundle Node.js Daemon`.
- Packaged `.app` contains no `Resources/node`, `node_modules`, `daemon.js`, `index.js`, `web.js`, `dist/`, or copied npm package tree.
- README and config examples do not use `node dist/index.js`.
- `package.json` no longer exposes `dist/index.js` or `dist/cli/index.js` as shipped product entry points after deletion.

Steps:

- [ ] Add `check-node-deletion-readiness.sh` with source scans, Xcode project scans, README scans, and app-bundle scans.
- [ ] Add `NodeDeletionReadinessTests` that executes equivalent scans from XCTest for CI visibility.
- [ ] Add an Xcode build artifact inspection step that fails if Node runtime files exist in the final `.app`.
- [ ] Before deleting Node, run dual-run parity and capture a final set of historical fixtures generated from Node.
- [ ] Delete Node MCP, Node web daemon, Node CLI, old app-local MCP bridge, and Node bundle scripts only in one final cutover task after all gates pass.
- [ ] After deletion, remove npm tests from shipped-product CI and keep only archived reference fixture generation scripts if explicitly needed.

Verification:

- `bash scripts/check-node-deletion-readiness.sh`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramTests/NodeDeletionReadinessTests`
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- `find macos/build -path '*Engram.app*' \\( -name node_modules -o -name node -o -name daemon.js -o -name index.js -o -name web.js -o -name dist \\) -print` must print nothing for the inspected release app.

## Execution Order

1. Add service-client models and mapping tests.
2. Route Swift MCP service-backed tools and prove fail-closed behavior.
3. Port project move/archive/undo/batch/recover/review with failure injection.
4. Port session/file/adapter-backed operational tools.
5. Replace app `DaemonClient` and direct HTTP URL callers.
6. Replace or explicitly deprecate Node CLI workflows with Swift CLI commands.
7. Expand full MCP parity and dual-run harness.
8. Add deletion-readiness scans and only then perform Node deletion in the final cutover unit.

## Acceptance Gates

- Swift MCP and Node MCP return equivalent JSON for all public tools on shared fixtures, except documented allowlisted improvements.
- Every Swift MCP mutating or filesystem-writing tool returns a typed service-unavailable error when service IPC is unavailable and performs no local write.
- `EngramServiceClient` has a typed method for every current `DaemonClient` capability and former app `/api/*` dependency.
- `DaemonClient.swift` and `DaemonHTTPClientCore.swift` have no production callers and are deleted before final cutover.
- Project move compensation tests prove original filesystem hashes, migration rows, aliases, session cwd values, source directories, `projects.json`, and lock files are restored or reported precisely for every injected failure point.
- Swift CLI either implements or explicitly deprecates every Node CLI command before `src/cli/*.ts` is deleted.
- App, MCP, and CLI writes all route to one shared service writer.
- Packaged app and docs contain no Node runtime or Node MCP configuration after final cutover.

## Final Verification Suite

Run these before claiming this implementation unit complete:

- `npm run build`
- `npm test`
- `npm run lint`
- `npm run generate:mcp-contract-fixtures`
- `cd macos && xcodegen generate`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- `xcodebuild build -project macos/Engram.xcodeproj -scheme EngramCLI -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- `npx tsx scripts/compare-node-swift-mcp.ts --fixture-db tests/fixtures/mcp-contract.sqlite`
- `bash scripts/check-node-deletion-readiness.sh`
- `rg 'DaemonClient|DaemonHTTPClientCore|ENGRAM_MCP_DAEMON_BASE_URL|/tmp/engram.sock|node dist/index\\.js|dist/cli|Bundle Node.js Daemon|Resources/node' macos README.md docs --glob '!docs/archive/**'`

During Stages 1-4, failures in `npm` checks block deletion but do not necessarily block Swift implementation commits if the failing tests are unrelated pre-existing reference failures. Document any such failure with the exact command and first failing test.

## Remaining Risks

- Some `src/web.ts` endpoints may be unused in the current Swift UI but still represent user or developer workflows; each must be either mapped or explicitly deprecated before Node deletion.
- Project move behavior mutates user files and AI session stores; do not rely on happy-path parity alone. Failure injection is mandatory.
- Swift filesystem, process, and glob behavior differs from Node on APFS, especially case-only renames, symlinks, `.git` worktree files, and permission errors.
- Live sessions and hygiene depend on service-owned monitors; MCP should never fake live state from a read-only helper once the service exists.
- The final Node deletion task must include generated Xcode project and app-bundle inspection, not just source deletion.
