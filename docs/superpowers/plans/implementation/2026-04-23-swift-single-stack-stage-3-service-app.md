# Swift Single Stack Stage 3 Service App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Node daemon and app daemon integration with a Swift `EngramService` process, real local IPC, a single writer gate, and app UI flows backed by `EngramServiceClient`.

**Architecture:** Stage 3 introduces a standalone Swift service helper reached over a Unix-domain socket at `$HOME/.engram/run/engram-service.sock`, with test overrides through `ENGRAM_SERVICE_SOCKET` and `--service-socket`. `ServiceWriterGate` owns exactly one process-level `EngramDatabaseWriter`; app, MCP, CLI, and shared code must not instantiate write-capable core objects or service server objects. Stage 4 MCP/CLI mutation work is blocked until the real IPC gate proves external clients can reach the shared writer and fail closed when the service is unavailable.

**Tech Stack:** Swift 5.9+, GRDB, XcodeGen, XCTest, Foundation/Darwin Unix-domain sockets, async/await, existing Swift `EngramCoreRead`/`EngramCoreWrite` modules from Stages 1-2.

---

## Review-locked corrections

- Stage 3 must not delete retained compatibility shim files. Grep and source-scan gates check production callers, target membership, and startup/runtime call paths; they must exclude the retained shim files only as inert files until Stage 4/5 owns deletion.
- Stage 3 may cut over default app runtime only for app-used flows that are implemented with parity. A production user-visible app flow must not be replaced by `unsupported`; unported Stage 4-owned operations stay behind the Node rollback path or an explicit non-default flag until Stage 4 ports them.
- Stage 3 must deliver `macos/EngramTests/EngramServiceIPCTests.swift` as the umbrella real-IPC proof consumed by Stage 4, even if lower-level transport tests remain split across `UnixSocketTransportTests`, `ServiceWriterGateTests`, and lifecycle tests.
- Socket overrides through `ENGRAM_SERVICE_SOCKET` or `--service-socket` are test/development-only unless the parent directory is owned by the current user, non-symlinked, mode `0700`, and not group/world writable.
- `InProcessEngramServiceTransport` is compile-time test-only by default. If a development runtime flag is retained, enabling it must disable all mutating MCP/CLI tools and must be rejected by production builds.
- Read-after-write tests must perform a committed service write, then read through the actual app/MCP read facade that would be used in production, proving the facade observes the returned `database_generation` or routes through service.
- MCP/CLI fail-closed classification must cover every mutating and operational command, not only the two example tools. Stage 3 tests may use representative commands, but the classification inventory must be complete before Stage 4 starts.
- Settings and user-facing MCP setup docs remain Stage 4/5-owned unless this stage changes visible app UI copy. Do not publish partial Swift MCP setup instructions from Stage 3 that still rely on unported Stage 4 behavior.

## Goal

Stage 3 makes the macOS app run against Swift service infrastructure instead of `node daemon.js`, `IndexerProcess`, raw daemon HTTP, or the app-local `MCPServer` bridge.

The stage is complete only when:

- The app can launch in production service mode without starting Node.
- `EngramService` runs as a standalone helper process and exposes status, event stream, read commands, and write-intent commands over the chosen production IPC.
- The real IPC gate passes before Stage 4 starts.
- Exactly one `EngramDatabaseWriter` exists inside the service process, owned by `ServiceWriterGate`.
- Production app writes go through `EngramServiceClient`; no direct core writers leak into `macos/Engram`, `macos/EngramMCP`, `macos/EngramCLI`, or app/MCP/CLI-importable `macos/Shared`.

## Scope

In scope:

- Add shared service DTOs, errors, client protocol, concrete socket client, status store, and mock client.
- Add the `EngramService` helper target, lifecycle, command handler, event broker, background job coordinator, and service-owned writer gate.
- Add Unix-domain socket IPC with permission checks, lock ownership, request/response framing, event subscription, timeouts, and typed errors.
- Replace app startup and UI environment injection from `IndexerProcess`/`DaemonClient` to `EngramServiceClient`/`EngramServiceStatusStore`.
- Replace production app daemon HTTP usage with typed service client methods where Stage 3 app UI requires them.
- Keep `DaemonClient.swift` and `DaemonHTTPClientCore.swift` only as migration shims until Stage 4 removes them.
- Add integration and scan tests proving no app/MCP/shared second-writer path exists after service cutover.
- Preserve Node packaging, Node source, and npm reference tests for rollback and Stage 4/5 parity.

Out of scope:

- Do not delete Node runtime source, `dist`, `node_modules`, `Resources/node`, Node bundle scripts, or npm tests.
- Do not port full MCP/CLI mutating behavior in Stage 3. Stage 3 only adds the IPC gate and fail-closed behavior needed to unblock Stage 4.
- Do not delete `DaemonClient.swift`, `DaemonHTTPClientCore.swift`, `IndexerProcess.swift`, `MCPServer.swift`, or `MCPTools.swift` unless a later Stage 4/5 plan explicitly owns deletion after scan gates pass.
- Do not add an in-process writer fallback for MCP or CLI. In-process service transport is test-only and app smoke-only.

## Prerequisites

- [ ] Read `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`.
- [ ] Read `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md`.
- [ ] Read `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-service-ipc-app.md`.
- [ ] Confirm Stage 1 acceptance passed: `EngramCoreRead`, `EngramCoreWrite`, migration runner, SQLite WAL/busy-timeout policy, and module-boundary tests exist.
- [ ] Confirm Stage 2 acceptance passed: Swift adapters, indexing parity, watcher semantics, parent detection, startup backfills, and production write code placement are available.
- [ ] Confirm `docs/swift-single-stack/app-write-inventory.md` exists and every app-side write has a service-command mapping or removal decision.
- [ ] Confirm `docs/performance/baselines/2026-04-23-node-runtime-baseline.json` exists. Stage 3 reads this artifact only; it must not overwrite baseline values.
- [ ] Run `git status --short`.
  Expected: record unrelated existing changes before starting and do not modify or revert them.
  Failure handling: if files planned for this stage already have unrelated changes, inspect them and preserve those changes while applying Stage 3 edits.

## Files to create/modify

Create:

- `docs/swift-single-stack/daemon-client-map.md`: app/UI endpoint-to-service mapping owned by Stage 3 and extended by Stage 4.
- `macos/Shared/Service/EngramServiceModels.swift`: request, response, event, status, command, and usage DTOs.
- `macos/Shared/Service/EngramServiceError.swift`: typed error envelopes including `serviceUnavailable`.
- `macos/Shared/Service/EngramServiceProtocol.swift`: app/MCP/CLI-safe client protocol.
- `macos/Shared/Service/EngramServiceClient.swift`: async transport-backed client.
- `macos/Shared/Service/EngramServiceTransport.swift`: transport abstraction, framing metadata, timeout options, stream protocol.
- `macos/Shared/Service/UnixSocketEngramServiceTransport.swift`: production socket client.
- `macos/Shared/Service/InProcessEngramServiceTransport.swift`: test and pre-cutover app smoke transport only.
- `macos/Shared/Service/MockEngramServiceClient.swift`: deterministic tests and previews.
- `macos/Shared/Service/EngramServiceStatusStore.swift`: observable UI status store replacing `IndexerProcess` state.
- `macos/Shared/Settings/EngramFileSettings.swift`: service-side settings reader for existing Engram settings JSON and keychain sentinels.
- `macos/Shared/AI/SummaryProvider.swift`: Swift summary provider behavior used by service jobs.
- `macos/Shared/AI/TitleProvider.swift`: Swift title provider behavior used by service commands/jobs.
- `macos/Shared/AI/EmbeddingProvider.swift`: Swift embedding status/provider behavior used by service jobs.
- `macos/EngramService/main.swift`: helper entrypoint and signal handling.
- `macos/EngramService/Core/EngramService.swift`: lifecycle, startup, scan/watch orchestration, graceful shutdown.
- `macos/EngramService/Core/EngramServiceCommandHandler.swift`: typed command dispatch.
- `macos/EngramService/Core/ServiceWriterGate.swift`: lock, writer ownership, single-writer serialization.
- `macos/EngramService/Core/ServiceEventBroker.swift`: service event fan-out.
- `macos/EngramService/Core/ServiceBackgroundJobs.swift`: timers for indexing, rescans, usage, health, sync, retention, WAL checkpoint, AI queues.
- `macos/EngramService/IPC/UnixSocketServiceServer.swift`: production socket server.
- `macos/scripts/copy-service-helper.sh`: bundle copy script for the service helper.
- `macos/EngramTests/EngramServiceClientTests.swift`
- `macos/EngramTests/UnixSocketTransportTests.swift`
- `macos/EngramTests/ServiceWriterGateTests.swift`
- `macos/EngramTests/EngramServiceStatusStoreTests.swift`
- `macos/EngramTests/ServiceCommandContractTests.swift`
- `macos/EngramTests/ServiceProviderTests.swift`
- `macos/EngramTests/ServiceSourceScanTests.swift`
- `macos/EngramTests/ServiceLifecycleIntegrationTests.swift`
- `macos/EngramTests/EngramServiceIPCTests.swift`
- `macos/EngramMCPTests/ServiceUnavailableMutatingToolTests.swift`
- `macos/EngramMCPTests/ServiceForwardingMutatingToolTests.swift`
- `tests/fixtures/service-ipc/status-event.jsonl`
- `tests/fixtures/service-ipc/service-ready-event.json`
- `tests/fixtures/service-ipc/service-error.json`
- `tests/fixtures/service-ipc/project-move-dry-run-request.json`
- `tests/fixtures/service-ipc/save-insight-request.json`

Modify:

- `macos/project.yml`: add `EngramService` target, shared service source inclusion, helper copy script, and test target dependencies. Regenerate `macos/Engram.xcodeproj/project.pbxproj` with XcodeGen only.
- `macos/Engram/App.swift`: service bootstrap, app lifecycle, removal of production Node launch and app-local MCP bridge startup.
- `macos/Engram/Core/AppEnvironment.swift`: service mode, socket path, helper path, test-only in-process allowance, removal of production Node/port assumptions.
- `macos/Engram/MenuBarController.swift`: inject service client and status store.
- `macos/Engram/Core/EngramLogger.swift`: stop raw HTTP log posting; use service command or local OSLog before service is reachable.
- App views currently using `DaemonClient`, `IndexerProcess`, or raw daemon URLs:
  - `macos/Engram/Views/PopoverView.swift`
  - `macos/Engram/Views/SearchView.swift`
  - `macos/Engram/Views/Pages/SearchPageView.swift`
  - `macos/Engram/Views/CommandPaletteView.swift`
  - `macos/Engram/Views/GlobalSearchOverlay.swift`
  - `macos/Engram/Views/SessionDetailView.swift`
  - `macos/Engram/Views/Replay/SessionReplayView.swift`
  - `macos/Engram/Views/Resume/ResumeDialog.swift`
  - `macos/Engram/Views/Pages/HygieneView.swift`
  - `macos/Engram/Views/Pages/SourcePulseView.swift`
  - `macos/Engram/Views/Pages/SkillsView.swift`
  - `macos/Engram/Views/Pages/MemoryView.swift`
  - `macos/Engram/Views/Pages/HooksView.swift`
  - `macos/Engram/Views/Pages/ProjectsView.swift`
  - `macos/Engram/Views/Pages/SessionsPageView.swift`
  - `macos/Engram/Views/Pages/TimelinePageView.swift`
  - `macos/Engram/Views/Pages/HomeView.swift`
  - `macos/Engram/Views/Projects/RenameSheet.swift`
  - `macos/Engram/Views/Projects/ArchiveSheet.swift`
  - `macos/Engram/Views/Projects/UndoSheet.swift`
  - `macos/Engram/Views/Settings/GeneralSettingsSection.swift`
  - `macos/Engram/Views/Settings/SourcesSettingsSection.swift`
  - `macos/Engram/Views/Settings/NetworkSettingsSection.swift`
  - `macos/Engram/Views/Settings/AISettingsSection.swift`
- `macos/EngramMCP/main.swift`: configure socket client and typed service-unavailable behavior for future service-backed tools.
- `macos/EngramMCP/Core/MCPToolRegistry.swift`: add service-client injection points and fail-closed tests for mutating tools. Do not enable full Stage 4 mutation rewrite here.
- `macos/EngramCLI/main.swift`: add service-client construction path for future Stage 4 retained write commands; do not enable direct local writer fallback.

Do not modify in Stage 3:

- `src/**`
- `package.json`
- `package-lock.json`
- Node bundle scripts except app helper copy additions in `macos/scripts/`
- README/CLAUDE shipped-runtime Node deletion copy, except settings snippets explicitly changed by app UI files above
- Any file outside this list without updating this plan first

## Phased tasks

### Phase 1: Inventory current app daemon usage and lock the map

**Files:**

- Create: `docs/swift-single-stack/daemon-client-map.md`
- Read: `macos/Engram/Core/DaemonClient.swift`
- Read: `macos/Shared/Networking/DaemonHTTPClientCore.swift`
- Read: `src/web.ts`
- Read: `macos/Engram/Core/IndexerProcess.swift`

- [ ] Generate endpoint/call-site inventory.

Run:

```bash
rtk rg -n "DaemonClient|DaemonHTTPClientCore|IndexerProcess|http://127\\.0\\.0\\.1|localhost:|/api/|/health|ENGRAM_MCP_DAEMON_BASE_URL" macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI
```

Expected: lists all current app/shared/MCP/CLI daemon dependencies.

Failure handling: if the command returns no matches before migration work starts, inspect the branch because the code has already moved and this plan must be reconciled before continuing.

- [ ] Create `docs/swift-single-stack/daemon-client-map.md` with one row per endpoint or call family:

```markdown
# DaemonClient to EngramServiceClient Map

| Current owner | Current path or method | Current response model | Stage 3 service method | Stage 3 caller | Stage 4 owner | Decision |
| --- | --- | --- | --- | --- | --- | --- |
| App search UI | `DaemonClient.search(...)` or `/api/search` | existing search response DTO | `EngramServiceClient.search(_:)` | app | Stage 4 extends MCP mapping | service command |
| App status UI | `IndexerProcess.Status` and daemon events | `DaemonEvent` fields | `EngramServiceStatusStore.apply(_:)` | app | none | service event |
```

Required decisions for every row: `service command`, `read repository`, `Stage 4 MCP/CLI`, or `removed with documented deprecation`.

- [ ] Verify the map includes these former daemon capabilities: live sessions, source info, skills, memory, hooks, hygiene, lint, handoff, replay timeline, parent link/suggestion management, project migrations, project CWDs, project move/archive/undo, search, embedding status, summary generation, title regenerate-all, sync trigger, resume command, save insight, link sessions, log forwarding, `/health`.

Run:

```bash
rtk rg -n "live|source|skills|memory|hooks|hygiene|lint|handoff|replay|parent|project|search|embedding|summary|title|sync|resume|insight|link|log|health" docs/swift-single-stack/daemon-client-map.md
```

Expected: every listed capability appears in the map with a Stage 3 or Stage 4 owner.

Failure handling: add missing rows before writing service DTOs.

### Phase 2: Define app/MCP/CLI-safe service contract first

**Files:**

- Create: `macos/Shared/Service/EngramServiceModels.swift`
- Create: `macos/Shared/Service/EngramServiceError.swift`
- Create: `macos/Shared/Service/EngramServiceProtocol.swift`
- Create: `macos/Shared/Service/EngramServiceClient.swift`
- Create: `macos/Shared/Service/EngramServiceTransport.swift`
- Create: `macos/Shared/Service/MockEngramServiceClient.swift`
- Create: `macos/EngramTests/EngramServiceClientTests.swift`
- Create fixtures under `tests/fixtures/service-ipc/`

- [ ] Define `EngramServiceStatus` with these exact cases: `stopped`, `starting`, `running(total:todayParents:)`, `degraded(message:)`, `error(message:)`.
- [ ] Define `EngramServiceEvent` so it can decode every UI-consumed `DaemonEvent` field: `event`, `indexed`, `total`, `todayParents`, `message`, `sessionId`, `summary`, `port`, `host`, `action`, `removed`, and `usage`.
- [ ] Define `EngramServiceUsageItem` matching existing usage UI fields: source/provider name, metric name, current value, limit if present, reset time if present, and status.
- [ ] Define request/response envelopes with request id, command name, payload, success result, and error envelope. Preserve current JSON field names from `DaemonClient.swift`, `DaemonHTTPClientCore.swift`, and `src/web.ts` using `CodingKeys`.
- [ ] Define `EngramServiceError` with at least: `serviceUnavailable`, `transportClosed`, `invalidRequest`, `unauthorized`, `writerBusy`, `commandFailed(name:message:retryPolicy:details:)`, `unsupportedProvider`.
- [ ] Add client methods for every Stage 3 app-facing row in `docs/swift-single-stack/daemon-client-map.md`. Stage 4-owned rows may have DTOs now, but they must either return `unsupported` in the service or stay uncalled by production app code.
- [ ] Add `MockEngramServiceClient` with deterministic responses for previews/tests and no database writes.
- [ ] Write `EngramServiceClientTests` with a fake transport proving:
  - request ids are unique and preserved in responses;
  - typed responses decode;
  - structured errors preserve `name`, `message`, `retry_policy`, and `details`;
  - concurrent requests resolve to the matching request id;
  - event-stream cancellation closes the subscription;
  - `serviceUnavailable` is returned when the transport reports missing endpoint.

Run:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/EngramServiceClientTests
```

Expected: XcodeGen exits `0`; the targeted test class passes.

Failure handling: fix contract or test target wiring before adding service runtime files. Do not compensate by adding direct DB access in the client.

### Phase 3: Implement Unix socket transport and typed service-unavailable behavior

**Files:**

- Create: `macos/Shared/Service/UnixSocketEngramServiceTransport.swift`
- Create: `macos/EngramService/IPC/UnixSocketServiceServer.swift`
- Create: `macos/EngramTests/UnixSocketTransportTests.swift`

- [ ] Use Unix-domain socket IPC for Stage 3. The default socket path is `$HOME/.engram/run/engram-service.sock`, where `$HOME` is resolved from the effective user that owns the app/helper process. Do not rely on shell `~` expansion inside the helper.
- [ ] Support overrides through `ENGRAM_SERVICE_SOCKET` and `--service-socket` for tests and helper launch only. Refuse production overrides unless the resolved socket parent directory is owned by the current user, is not a symlink, has mode `0700`, and is not group/world writable.
- [ ] Create `$HOME/.engram/run` with mode `0700`. Refuse startup if the directory is symlinked, owned by another user, group-writable, or world-writable.
- [ ] Use deterministic length-prefixed JSON frames. Each frame contains `request_id`, `kind`, `command`, and `payload`.
- [ ] Implement command timeout, connect timeout, clean close, malformed frame response, large response framing, and explicit event stream subscription/cancellation.
- [ ] Convert missing socket, connect refusal, and timed-out initial connect into `EngramServiceError.serviceUnavailable`.
- [ ] Add tests for:
  - missing socket returns `serviceUnavailable`;
  - bad runtime directory permissions fail startup;
  - malformed frame returns `invalidRequest` and server stays alive;
  - large response crosses frame boundary and decodes once;
  - two concurrent read commands resolve independently;
  - event stream cancellation stops server-side subscription.

Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/UnixSocketTransportTests
```

Expected: targeted transport tests pass.

Failure handling: do not proceed to writer gate while missing endpoint errors are ambiguous. Stage 4 depends on a typed `serviceUnavailable` error shape.

### Phase 4: Add `ServiceWriterGate` with exactly one writer

**Files:**

- Create: `macos/EngramService/Core/ServiceWriterGate.swift`
- Create: `macos/EngramTests/ServiceWriterGateTests.swift`
- Modify only if needed for test injection: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`

- [ ] Implement `ServiceWriterGate` as the only owner of `EngramDatabaseWriter` in the service process.
- [ ] Acquire exclusive process lock at `$HOME/.engram/run/engram-service.lock` before constructing the writer.
- [ ] Remove a stale socket only after the process lock is acquired and a connection probe proves no live service owns the socket.
- [ ] Construct exactly one `EngramDatabaseWriter` after lock acquisition. Store it privately inside `ServiceWriterGate`.
- [ ] Expose write execution as a serialized async method on the gate, for example `performWriteCommand(name:operation:)`, so command handlers cannot retain or create writer instances.
- [ ] Add a runtime guard or test-only factory counter that fails if a second writer is constructed inside `EngramService`.
- [ ] Add tests proving:
  - first gate acquires lock and constructs one writer;
  - second gate in another process or simulated process fails with `writerBusy`;
  - concurrent write commands execute serially;
  - app/MCP/shared source scan fails if `EngramCoreWrite` is imported outside service-only targets.

Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ServiceWriterGateTests
```

Expected: lock, single-writer, and serialization tests pass.

Failure handling: if a test needs a second writer to pass, the design is wrong. Rewrite the handler dependency flow so only `ServiceWriterGate` holds the writer.

### Phase 5: Add `EngramService` helper target and lifecycle

**Files:**

- Create: `macos/EngramService/main.swift`
- Create: `macos/EngramService/Core/EngramService.swift`
- Create: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Create: `macos/EngramService/Core/ServiceEventBroker.swift`
- Create: `macos/EngramService/Core/ServiceBackgroundJobs.swift`
- Modify: `macos/project.yml`
- Create: `macos/scripts/copy-service-helper.sh`
- Create: `macos/EngramTests/ServiceCommandContractTests.swift`
- Create: `macos/EngramTests/ServiceLifecycleIntegrationTests.swift`

- [ ] Add `EngramService` tool target to `macos/project.yml`. It may include `EngramService`, `EngramCoreRead`, `EngramCoreWrite`, and service-only code. It must not compile into `EngramMCP` or `EngramCLI`.
- [ ] Add `macos/scripts/copy-service-helper.sh` and wire it into the `Engram` scheme so the app bundle can launch the helper. Keep it separate from MCP helper copying.
- [ ] Do not remove any Node build or packaging phase in this stage.
- [ ] Implement service startup sequence:
  - parse `--service-socket`, `--engram-home`, `--database-path`, and `--foreground`;
  - read settings;
  - resolve database path;
  - acquire `ServiceWriterGate`;
  - open/migrate DB through Swift core;
  - publish `starting`;
  - run initial maintenance;
  - start socket server;
  - publish `ready` and `running(total:todayParents:)`.
- [ ] Define `todayParents` as the count of parent-tier sessions whose canonical session timestamp falls within the user's current local calendar day and whose parent-link fields do not mark them as child/subagent sessions. Add a fixture test that compares this count to the legacy `IndexerProcess`/Node ready-event value.
- [ ] Implement lifecycle shutdown:
  - stop accepting new commands;
  - cancel event subscriptions;
  - stop background timers;
  - release process lock;
  - remove socket only if this process owns it.
- [ ] Implement daemon-compatible events: `ready`, `indexed`, `rescan`, `sync_complete`, `watcher_indexed`, `summary_generated`, `error`, `warning`, `wal_checkpoint`, `ai_audit`, `usage`, `alert`.
- [ ] Implement command handling for Stage 3 app flows. Commands not ported yet may return `EngramServiceError.commandFailed(name:"unsupported", message:..., retryPolicy:"none", details:...)` or `unsupportedProvider` only for non-production Stage 4-owned endpoints that production app code does not call in default runtime. They must not call Node, HTTP, or direct local writers.
- [ ] Implement read-after-write consistency:
  - every write command returns after commit only;
  - after commit, service increments a monotonic `database_generation`;
  - response envelope includes `database_generation`;
  - `EngramServiceClient` notifies `EngramServiceStatusStore` and read facades to refresh/invalidate reader snapshots before UI/MCP read-after-write flows report current data;
  - if a direct `EngramCoreRead` flow cannot observe the committed generation, route that read through a service command.
- [ ] Add subprocess integration tests launching `EngramService` with temporary `ENGRAM_HOME`, fixture database, and socket path. Test must connect over socket, receive `ready`, call `status`, call one read command, call one dry-run write-intent command, assert `database_generation` behavior, read back through the production app/MCP read facade, and terminate cleanly.

Run:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramService build -destination 'platform=macOS'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ServiceCommandContractTests -only-testing:EngramTests/ServiceLifecycleIntegrationTests -only-testing:EngramTests/EngramServiceIPCTests
```

Expected: project regenerates, service target builds, lifecycle/contract tests pass.

Failure handling: if helper launch cannot be made reliable, keep the app on Node for runtime but do not move to Stage 4. Real IPC gate remains blocked.

### Phase 6: Preserve provider behavior in service-owned jobs

**Files:**

- Create: `macos/Shared/Settings/EngramFileSettings.swift`
- Create: `macos/Shared/AI/SummaryProvider.swift`
- Create: `macos/Shared/AI/TitleProvider.swift`
- Create: `macos/Shared/AI/EmbeddingProvider.swift`
- Modify: `macos/EngramService/Core/ServiceBackgroundJobs.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Create: `macos/EngramTests/ServiceProviderTests.swift`

- [ ] Port settings reads from `src/core/config.ts`: `~/.engram/settings.json`, `@keychain` sentinel overlay for `aiApiKey` and `titleApiKey`, legacy `aiProvider` to `aiProtocol`, legacy noise toggles to `noiseFilter`, and both `titleBaseURL` and `titleBaseUrl`.
- [ ] Port summary provider behavior: OpenAI, Anthropic, Gemini request/response parsing; default Chinese prompt; `{{language}}`, `{{maxSentences}}`, `{{style}}`; blank-line stripping; preset/custom generation config; sample-first/sample-last truncation.
- [ ] Port title provider behavior: providers `ollama`, `openai`, `dashscope`, `custom`; Ollama `/api/generate`; OpenAI-compatible `/v1/chat/completions`; max tokens `50`; temperature `0.3`; six-message prompt sampling; response cleanup; 30-character cap; audit records.
- [ ] Port auto-summary scheduling behavior: per-session cooldown, minimum message threshold, summary freshness threshold, cleanup on shutdown, `summary_generated` and `summary_error` events.
- [ ] Implement embedding provider behavior for Ollama `/api/embed` and OpenAI `text-embedding-3-small` with configured dimension. L2-normalize truncated Ollama vectors.
- [ ] Explicitly return `unsupportedProvider("transformers")` for Transformers.js unless a native Swift local model implementation and fixtures are implemented in this phase. Do not launch Node or Transformers.js.
- [ ] Add provider tests with injected HTTP fixtures for success and failure paths, embedding dimension truncation, OpenAI embedding parsing, Transformers unsupported status, and audit recording.

Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ServiceProviderTests
npm test -- tests/core/ai-client.test.ts tests/core/auto-summary.test.ts tests/core/title-generator.test.ts tests/core/embeddings.test.ts
```

Expected: Swift provider tests pass; Node reference tests still pass.

Failure handling: if Swift cannot preserve a provider behavior, return a typed unsupported/degraded service response and record the intentional narrowing in `docs/swift-single-stack/daemon-client-map.md`. Do not silently fall back to Node.

### Phase 7: Replace app startup and status injection

**Files:**

- Modify: `macos/Engram/App.swift`
- Modify: `macos/Engram/Core/AppEnvironment.swift`
- Modify: `macos/Engram/MenuBarController.swift`
- Create: `macos/Shared/Service/EngramServiceStatusStore.swift`
- Create: `macos/Shared/Service/InProcessEngramServiceTransport.swift`
- Replace or add: `macos/EngramTests/EngramServiceStatusStoreTests.swift`

- [ ] In `AppDelegate`, stop constructing `IndexerProcess` and `DaemonClient` for production runtime. Construct `EngramServiceStatusStore` and `EngramServiceClient`.
- [ ] Stop starting app-local `MCPServer`/`MCPTools` from `Engram.app` production launch.
- [ ] Stop resolving `nodejsPath`, locating bundled `node/daemon.js`, and calling `indexer.start(nodePath:scriptPath:)` in production launch.
- [ ] Launch or connect to `EngramService` helper in production. Use `InProcessEngramServiceTransport` only in test targets by default. If a development `--service-in-process` flag is retained, it must disable all mutating MCP/CLI tools and fail a production-build source scan.
- [ ] Subscribe once to service events during app launch.
- [ ] Update `EngramServiceStatusStore` with fields equivalent to current `IndexerProcess` UI state: status, total sessions, today parent sessions, last summary session id, usage data, endpoint health, embedding status, last event time.
- [ ] On application termination, close event subscriptions and terminate only app-owned helper processes. Do not kill an externally owned shared service that MCP/CLI clients may be using.
- [ ] Add app test hooks `--fixture-home`, `--assert-service-ready`, and `--exit-after-ready` for Stage 5 clean-checkout verification. These hooks must use a temporary home only and must not expose mutating MCP tools through in-process transport.
- [ ] Add status store tests decoding legacy event fixtures and proving display strings and `isRunning` semantics match old `IndexerProcess.Status` expectations.

Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/EngramServiceStatusStoreTests
rtk rg "IndexerProcess\\(|indexer\\.start|nodejsPath|nodeJsPath|daemon\\.js|MCPServer\\(" macos/Engram --glob '!**/*Tests*'
```

Expected: tests pass; `rg` returns no production app startup references to Node daemon launch or app-local MCP bridge.

Failure handling: app may retain compatibility shims as unused files, but production launch must not call them after this phase.

### Phase 8: Replace app UI daemon HTTP and direct status usage

**Files:**

- Modify all app view files listed in "Files to create/modify".
- Modify: `macos/Engram/Core/EngramLogger.swift`
- Replace test fixtures as needed: `macos/Engram/TestSupport/MockDaemonFixtures.swift`
- Add or update app/view tests that currently depend on `DaemonClient`.

- [ ] Replace every `@Environment(DaemonClient.self)` with `@Environment(EngramServiceClient.self)` or a protocol existential compatible with `MockEngramServiceClient`.
- [ ] Replace every `@Environment(IndexerProcess.self)` with `@Environment(EngramServiceStatusStore.self)`.
- [ ] Replace direct search URLs in search views and command palette with `serviceClient.search(...)`.
- [ ] Replace embedding status URLs with `serviceClient.embeddingStatus()`.
- [ ] Replace summary, title, handoff, replay, resume, parent link/suggestion, sync, live sessions, source pulse, skills, memory, hooks, hygiene, monitor alerts, and log forwarding app calls with typed service client methods from the map when Stage 3 implements the backing command. Project rename/archive/undo/cwd/migration operations remain Node-backed rollback or disabled behind a non-default flag until Stage 4 ports them; do not ship a default production app flow that surfaces `unsupported`.
- [ ] Preserve dry-run-first UI semantics for project rename/archive/undo even when the backing command is service-backed.
- [ ] Keep local FTS fallback only as read-only fallback that cannot mutate and does not claim semantic/vector availability.
- [ ] Keep `DaemonClient.swift` and `DaemonHTTPClientCore.swift` only if no production callers remain and Stage 4 is scheduled to delete them.

Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramUITests/PopoverSmokeTests -only-testing:EngramUITests/SearchSmokeTests -only-testing:EngramUITests/SettingsSmokeTests
rtk rg "DaemonClient|IndexerProcess|http://127\\.0\\.0\\.1|localhost:|/api/search|/api/summary|/api/project|ENGRAM_MCP_DAEMON_BASE_URL" macos/Engram macos/Shared --glob '!macos/Engram/Core/DaemonClient.swift' --glob '!macos/Shared/Networking/DaemonHTTPClientCore.swift'
```

Expected: unit and UI smoke tests pass; `rg` returns no production caller outside explicitly excluded compatibility shim files.

Failure handling: do not delete compatibility shims to make scans pass. Replace call sites first.

### Phase 9: Add MCP/CLI real IPC gate without enabling Stage 4 mutations

**Files:**

- Modify: `macos/EngramMCP/main.swift`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Modify: `macos/EngramCLI/main.swift`
- Create: `macos/EngramMCPTests/ServiceUnavailableMutatingToolTests.swift`
- Create: `macos/EngramMCPTests/ServiceForwardingMutatingToolTests.swift`

- [ ] Configure `EngramMCP` with `UnixSocketEngramServiceTransport` from settings/env. It must never instantiate `EngramService`, `InProcessEngramServiceTransport`, `ServiceWriterGate`, or `EngramDatabaseWriter`.
- [ ] Classify every MCP tool and CLI command as `readOnly`, `mutating`, `longRunningRead`, or `operational`. In Stage 3, add the complete inventory and the tests needed by Stage 4.
- [ ] For every mutating and operational MCP/CLI entry in the classification inventory, missing service socket must return typed service-unavailable MCP/CLI JSON and perform no DB/filesystem mutation. Stage 3 must at minimum execute representative tests for `save_insight`, dry-run `project_move`, and one CLI write command.
- [ ] Add tests proving `save_insight`, dry-run `project_move`, and one CLI write command fail closed with no service socket and row counts, migration logs, and filesystem roots remain unchanged.
- [ ] Add tests proving a fake socket service receives exact request payloads for `save_insight` and dry-run `project_move`.
- [ ] Configure `EngramCLI` service client construction for Stage 4 retained write commands, but do not enable direct local writer fallback.

Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS' -only-testing:EngramMCPTests/ServiceUnavailableMutatingToolTests -only-testing:EngramMCPTests/ServiceForwardingMutatingToolTests
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_move","arguments":{"src":"/tmp/a","dst":"/tmp/b","dry_run":true}}}' | ./macos/build/EngramMCP
```

Expected: targeted MCP tests pass. The direct command with no service running returns typed `serviceUnavailable` and performs no filesystem/database mutation. Adjust the executable path to the actual built helper path recorded by Xcode if `./macos/build/EngramMCP` is not the build output.

Failure handling: if `EngramMCP` can mutate without the socket, stop and remove that fallback before Stage 4 starts.

### Phase 10: Add source-scan tests and pre-commit grep gate

**Files:**

- Create: `macos/EngramTests/ServiceSourceScanTests.swift`
- Modify existing repo hook/lint config only if one exists; otherwise add a script documented in `docs/swift-single-stack/daemon-client-map.md` and wire it to the closest existing lint entry.

- [ ] Add scan tests that fail on production app/MCP/CLI/shared references to:
  - `import EngramCoreWrite` outside `macos/EngramService` and explicit tests;
  - `ServiceWriterGate` outside `macos/EngramService` and tests;
  - `EngramDatabaseWriter(` outside service-only code and tests;
  - `writerPool`;
  - app-side `.write {`;
  - app-side `DatabasePool(path:)`;
  - raw GRDB DML in `macos/Engram`;
  - `DaemonClient.fetch<`, `DaemonClient.post<`, `postRaw`, raw `delete`;
  - `ENGRAM_MCP_DAEMON_BASE_URL`;
  - `http://127.0.0.1`, `localhost:`;
  - `IndexerProcess(`, `indexer.start`, `nodejsPath`, `nodeJsPath`, `daemon.js`, `MCPServer(` in production app startup.
- [ ] Add a plain command gate:

```bash
rtk rg "IndexerProcess\\(|indexer\\.start|nodejsPath|nodeJsPath|daemon\\.js|MCPServer\\(|writerPool|DatabasePool\\(path:|\\.write \\{|fetch<|postRaw|post<|ENGRAM_MCP_DAEMON_BASE_URL|http://127\\.0\\.0\\.1|localhost:" macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI --glob '!macos/Engram/Core/DaemonClient.swift' --glob '!macos/Shared/Networking/DaemonHTTPClientCore.swift' --glob '!macos/Engram/Core/IndexerProcess.swift' --glob '!macos/Engram/Core/MCPServer.swift' --glob '!macos/Engram/Core/MCPTools.swift' --glob '!**/*Tests*'
```

Expected after service cutover: no production call-site output. Retained shim files may still contain legacy symbols only if they are excluded from production target membership or have no production callers proven by `ServiceSourceScanTests`.

- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ServiceSourceScanTests
```

Expected: scan tests pass.

Failure handling: do not whitelist production paths except the two explicitly named compatibility shims. Move service-only code out of shared/app/MCP targets instead.

### Phase 11: Settings and UI copy updates for service runtime

**Files:**

- Modify: `macos/Engram/Views/Settings/GeneralSettingsSection.swift`
- Modify: `macos/Engram/Views/Settings/SourcesSettingsSection.swift`
- Modify: `macos/Engram/Views/Settings/NetworkSettingsSection.swift`
- Modify: `macos/Engram/Views/Settings/AISettingsSection.swift`
- Modify: `macos/Engram/Views/PopoverView.swift`
- Modify: `macos/EngramUITests/Tests/SmokeTests/SettingsSmokeTests.swift` if identifiers or text snapshots intentionally change.

- [ ] Replace infrastructure display from Node path/HTTP port to service status, socket path, helper path/version, database path, last event time, and ownership state.
- [ ] Do not publish new MCP setup snippets in Stage 3. Record the required Swift `EngramMCP` helper invocation and service IPC requirement as a Stage 4/5 docs handoff note, and do not show `node dist/index.js` as primary setup.
- [ ] Replace `mcpStrictSingleWriter` toggle/copy with non-toggle status text: `MCP writes require EngramService IPC`.
- [ ] Route Network sync trigger through `EngramServiceClient`.
- [ ] Route AI title regenerate-all through `EngramServiceClient`.
- [ ] Preserve accessibility identifiers where possible. If an identifier changes, update UI tests in the same phase.

Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramUITests/SettingsSmokeTests -only-testing:EngramUITests/PopoverSmokeTests
```

Expected: settings and popover smoke tests pass with service-backed status.

Failure handling: if UI tests fail only because copy changed intentionally, update expected strings and keep accessibility identifiers stable where possible.

### Phase 12: Stage 3 final verification

**Files:**

- No new files unless recording existing test output in an already owned verification document for this migration.

- [ ] Run full Stage 3 verification command set:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramService build -destination 'platform=macOS'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramUITests/PopoverSmokeTests -only-testing:EngramUITests/SearchSmokeTests -only-testing:EngramUITests/SettingsSmokeTests
rtk npm test
rtk rg "IndexerProcess\\(|indexer\\.start|nodejsPath|nodeJsPath|daemon\\.js|MCPServer\\(|writerPool|DatabasePool\\(path:|\\.write \\{|fetch<|postRaw|post<|ENGRAM_MCP_DAEMON_BASE_URL|http://127\\.0\\.0\\.1|localhost:" macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI --glob '!macos/Engram/Core/DaemonClient.swift' --glob '!macos/Shared/Networking/DaemonHTTPClientCore.swift' --glob '!macos/Engram/Core/IndexerProcess.swift' --glob '!macos/Engram/Core/MCPServer.swift' --glob '!macos/Engram/Core/MCPTools.swift' --glob '!**/*Tests*'
```

Expected:

- XcodeGen exits `0`.
- `EngramService` builds.
- `Engram` tests pass.
- `EngramMCPTests` pass.
- UI smoke tests pass.
- npm tests pass because Node remains the reference through Stage 4.
- Final `rg` command returns no production call-site dependencies except excluded inert compatibility shim files.

Failure handling:

- Build/test failure: fix Stage 3 code or test wiring before claiming completion.
- npm failure: do not dismiss it as unrelated unless a known pre-existing failure is documented before the Stage 3 branch. Node remains reference.
- `rg` output: replace remaining call sites or move service-only code out of app/MCP/shared production targets.
- App cannot launch without Node: keep Node rollback path intact, disable service cutover flag, and do not open Stage 4.

## Verification

Use the smallest targeted command after each phase and the full command set in Phase 12 before marking Stage 3 complete.

Required targeted commands:

- `rtk sh -lc 'cd macos && xcodegen generate'`
- `rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramService build -destination 'platform=macOS'`
- `rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/EngramServiceClientTests`
- `rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/UnixSocketTransportTests`
- `rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ServiceWriterGateTests`
- `rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ServiceLifecycleIntegrationTests`
- `rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/EngramServiceIPCTests`
- `rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'`
- `rtk npm test`

Required manual or subprocess smoke checks:

- Launch `EngramService` in foreground with a temporary home and fixture DB.
- Connect two independent client processes over the socket.
- Submit two concurrent dry-run/write-intent commands.
- Verify both commands are serialized through `ServiceWriterGate`.
- Kill the service with SIGTERM and verify it closes subscriptions and releases the lock.
- Start a second service while the first owns the lock and verify `writerBusy`.

Expected smoke output:

- First service emits `starting` then `ready`.
- First client receives status with database path, total sessions, and active source roots.
- Second client can subscribe to events without opening a writer.
- Concurrent write-intent commands return ordered acknowledgements with monotonically increasing `database_generation`.
- Second service cannot acquire `$HOME/.engram/run/engram-service.lock`.
- Missing socket returns typed `serviceUnavailable`.

## Acceptance gates

- [ ] Service IPC gate: standalone `EngramService` starts, acquires writer lock, constructs exactly one `EngramDatabaseWriter` owned by `ServiceWriterGate`, opens fixture DB, emits `ready`, serves `status`, accepts two concurrent external client connections through Unix socket production transport, serializes write-intent commands through one writer authority, and shuts down cleanly.
- [ ] Single-writer gate: a second `EngramService` process cannot acquire the writer lock; source scans prove `EngramMCP`, `EngramCLI`, `macos/Engram`, and app/MCP/CLI-importable `macos/Shared` cannot instantiate `EngramDatabaseWriter`, `ServiceWriterGate`, or `InProcessEngramServiceTransport` for production mutation paths.
- [ ] Real IPC before Stage 4 gate: Stage 4 MCP/CLI rewrite cannot start until the service IPC gate passes. In-process transport is acceptable only in tests and pre-cutover app smoke paths.
- [ ] App gate: production app launches without `node daemon.js`, without `IndexerProcess.start`, without app-local `MCPServer`, and without raw daemon HTTP in production app code.
- [ ] App writes gate: all production app writes route through `EngramServiceClient`; direct core writers do not leak into app, MCP, CLI, or shared production targets.
- [ ] Read-after-write gate: service write acknowledgements include committed generation and refresh/invalidate direct read pools before UI/MCP read-after-write flows claim current state; otherwise those reads route through service.
- [ ] Concrete read-after-write gate: a service-backed committed write is followed by at least one production app read facade and one production MCP read facade that observe the returned `database_generation`.
- [ ] Service unavailable gate: missing socket/helper returns typed `serviceUnavailable`; MCP/CLI mutating flows fail closed and leave DB/filesystem unchanged.
- [ ] UI compatibility gate: popover, search, settings, projects, session detail, replay, live badge, usage/status views pass fixture or smoke coverage through service path.
- [ ] AI/provider gate: summary, title, and embedding provider tests cover supported providers and explicitly report Transformers unsupported unless a native Swift backend lands with tests.
- [ ] Node retention gate: Stage 3 does not delete Node source, Node packaging, npm tests, or reference artifacts. Node remains rollback/reference runtime through Stage 4.

## Rollback/abort guidance

- Abort Stage 3 immediately if `ServiceWriterGate` cannot prove exactly one `EngramDatabaseWriter` in the service process.
- Abort Stage 3 if `EngramMCP` or `EngramCLI` can perform a mutating operation without a reachable real service socket.
- Abort Stage 3 if production app startup still invokes `node`, `daemon.js`, `IndexerProcess.start`, or app-local `MCPServer` after the service cutover phase.
- Abort Stage 3 if source scans show `EngramCoreWrite`, `EngramDatabaseWriter`, service server files, or writer gate files compiled into app/MCP/CLI/shared production targets.
- Abort Stage 3 if a write acknowledgement can be observed by service but a subsequent app/MCP read can return stale data without a documented generation refresh or service-backed read path.
- Roll back before Stage 5 by re-enabling the pre-existing Node daemon launch path and leaving Node MCP examples intact. Do not delete rollback artifacts in Stage 3.
- If IPC reliability fails, keep `EngramService` behind a development flag and do not let Stage 4 route MCP/CLI mutations to Swift.
- If provider parity fails, return typed unsupported/degraded errors for the affected provider and keep Node reference tests intact. Do not add Node provider fallback to Swift service.

## Self-review Checklist

- [ ] The plan starts from the three required source documents and does not contradict their Stage 3/Stage 4 boundary.
- [ ] Every file path to create or modify is explicit.
- [ ] The chosen IPC is Unix-domain socket, with XPC deferred rather than left as an implementation fork.
- [ ] The real IPC gate is a Stage 4 blocker.
- [ ] The plan states exactly one `EngramDatabaseWriter`, owned by `ServiceWriterGate`.
- [ ] The plan forbids direct core writers in app, MCP, CLI, and shared production targets.
- [ ] The app writes only through `EngramServiceClient`.
- [ ] `serviceUnavailable` is typed and tested for missing socket/helper.
- [ ] Read-after-write consistency is specified with committed generation and reader refresh/invalidation.
- [ ] Daemon lifecycle includes startup, ready event, background jobs, graceful shutdown, lock release, and external-service ownership.
- [ ] Integration tests include standalone service process, two external clients, writer serialization, second service lock failure, and clean shutdown.
- [ ] Verification commands include XcodeGen, service build, app tests, MCP tests, UI smoke tests, npm reference tests, and grep gates.
- [ ] Node deletion and packaging cleanup are explicitly deferred to Stage 5.
- [ ] No task asks a worker to implement unspecified behavior without exact failure handling.
