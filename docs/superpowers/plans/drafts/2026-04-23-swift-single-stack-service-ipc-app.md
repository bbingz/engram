# Swift Single Stack Service, IPC, and App Integration Plan Draft

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Node daemon, HTTP `DaemonClient`, app-local MCP bridge, and `IndexerProcess` stdout parsing with a Swift `EngramService` single-writer process, a transport-neutral `EngramServiceClient`, and Swift UI/MCP flows that use real IPC before any mutating MCP/CLI cutover.

**Architecture:** Put shared DTOs, service client protocols, and IPC transport code under `macos/Shared` so `Engram.app`, `EngramMCP`, and `EngramCLI` use the same boundary. Add a new `EngramService` helper target as the only process allowed to open write-capable database/core objects; the app may use an in-process service only for early non-mutating smoke tests, but mutating MCP/CLI tools must fail closed unless they reach the shared writer over real IPC. Use a Unix-domain socket first because the repo already has helper tool targets and no XPC scaffolding; keep the service API independent of that transport.

**Tech Stack:** Swift 5.9, GRDB, Unix-domain sockets over Foundation/Darwin, async/await, XCTest, XcodeGen, existing TypeScript fixtures as parity references.

---

## Inspected Context

- `macos/Engram/App.swift` currently constructs `DatabaseManager`, `IndexerProcess`, and `DaemonClient`, starts `MCPServer/MCPTools`, resolves a Node binary, and launches bundled `Resources/node/daemon.js`.
- `macos/Engram/Core/IndexerProcess.swift` owns daemon process lifecycle, stdout JSONL parsing, restart backoff, `Status`, `UsageItem`, `totalSessions`, `todayParentSessions`, `port`, and event fields consumed by the UI.
- `macos/Engram/Core/DaemonClient.swift` plus `macos/Shared/Networking/DaemonHTTPClientCore.swift` wrap localhost HTTP `/api/*` endpoints and define response DTOs used by live sessions, hygiene, handoff, replay, parent links, and project migration UI.
- `MenuBarController`, `PopoverView`, `SearchView`, `SearchPageView`, `SessionDetailView`, `ResumeDialog`, `CommandPaletteView`, `GlobalSearchOverlay`, settings sections, and multiple page views either read `IndexerProcess` state or call the Node HTTP API directly.
- `src/daemon.ts` is more than an indexer: it owns startup WAL checkpointing, initial scan, watcher events, auto-summary, usage probes, live monitor, health monitor, alert rules, periodic rescans, sync, git probes, log/metrics retention, WAL checkpoints, and the Hono web server.
- `src/web.ts` defines the HTTP compatibility surface that the Swift UI currently depends on, including search/status, project move/archive/undo, parent link management, summary/title generation, handoff, timeline replay, sync trigger, live sessions, hygiene, skills, memory, hooks, and log forwarding.
- `src/core/bootstrap.ts`, `auto-summary.ts`, `title-generator.ts`, `ai-client.ts`, `embeddings.ts`, and `config.ts` define provider behavior that must be ported or deliberately narrowed: OpenAI/Anthropic/Gemini summaries, Ollama/OpenAI/Dashscope/custom titles, Ollama/OpenAI/Transformers embeddings, Keychain sentinel overlay, explicit no-fallback embedding model policy, and AI audit recording.

## File Map

- Create: `macos/EngramService/main.swift` — helper entrypoint, argument parsing, startup, signal handling.
- Create: `macos/EngramService/Core/EngramService.swift` — service lifecycle, startup scan, watcher/rescan loop, maintenance timers, event publishing.
- Create: `macos/EngramService/Core/EngramServiceCommandHandler.swift` — typed command dispatch; the only place service IPC mutates the database.
- Create: `macos/EngramService/Core/ServiceWriterGate.swift` — process lock, socket ownership checks, single-writer enforcement.
- Create: `macos/EngramService/Core/ServiceEventBroker.swift` — fan-out for status/events to app and test clients.
- Create: `macos/EngramService/Core/ServiceBackgroundJobs.swift` — usage probes, health checks, sync trigger, WAL checkpoint, title/summary queues.
- Create: `macos/EngramService/IPC/UnixSocketServiceServer.swift` — JSON-lines or length-prefixed local socket server with 0700 runtime dir and 0600 socket semantics.
- Create: `macos/Shared/Service/EngramServiceDTOs.swift` — all service request, response, event, status, and error DTOs shared by app/MCP/CLI.
- Create: `macos/Shared/Service/EngramServiceClient.swift` — transport-neutral async client protocol and concrete client used by callers.
- Create: `macos/Shared/Service/EngramServiceTransport.swift` — transport protocol plus framing, request id, cancellation, timeout, and stream abstractions.
- Create: `macos/Shared/Service/UnixSocketEngramServiceTransport.swift` — socket client implementation.
- Create: `macos/Shared/Service/InProcessEngramServiceTransport.swift` — test and pre-cutover app-only transport; explicitly unavailable to `EngramMCP` and `EngramCLI` mutating tools.
- Create: `macos/Shared/Service/EngramServiceStatusStore.swift` — `@Observable` UI state replacing `IndexerProcess`.
- Create: `macos/Shared/AI/SummaryProvider.swift` — Swift equivalent of `src/core/ai-client.ts`.
- Create: `macos/Shared/AI/TitleProvider.swift` — Swift equivalent of `src/core/title-generator.ts`.
- Create: `macos/Shared/AI/EmbeddingProvider.swift` — Swift Ollama/OpenAI embedding clients plus explicit Transformers handling.
- Create: `macos/Shared/Settings/EngramFileSettings.swift` — typed settings reader/writer that normalizes existing JSON keys and Keychain sentinels.
- Modify: `macos/project.yml` — add `EngramService` target, shared DTO/client source inclusion, helper copy script, and test target dependencies; do not remove Node prebuild or packaging until Stage 5.
- Modify: `macos/scripts/copy-mcp-helper.sh` or add `macos/scripts/copy-service-helper.sh` — copy `EngramService` into the app bundle when app starts the helper.
- Modify: `macos/Engram/App.swift` — replace `IndexerProcess`, `DaemonClient`, Node launch, and app-local `MCPServer` startup with service bootstrap/client/status store.
- Modify: `macos/Engram/Core/AppEnvironment.swift` — add service mode, socket path, helper path, test in-process allowance, and remove Node/port assumptions from production defaults.
- Modify: `macos/Engram/MenuBarController.swift` — inject `EngramServiceClient` and `EngramServiceStatusStore`; update badge/live-session polling.
- Modify: `macos/Engram/Views/PopoverView.swift` — use status store and service client for web/MCP/service/embedding indicators.
- Modify: `macos/Engram/Views/SearchView.swift` and `macos/Engram/Views/Pages/SearchPageView.swift` — replace direct `/api/search` and `/api/search/status` HTTP calls.
- Modify: `macos/Engram/Views/CommandPaletteView.swift` and `macos/Engram/Views/GlobalSearchOverlay.swift` — replace direct HTTP search.
- Modify: `macos/Engram/Views/SessionDetailView.swift` and `macos/Engram/Views/Replay/SessionReplayView.swift` — replace summary, handoff, replay, and parent-suggestion calls.
- Modify: `macos/Engram/Views/Resume/ResumeDialog.swift` — replace `/api/session/:id/resume`.
- Modify: `macos/Engram/Views/Pages/HygieneView.swift`, `SourcePulseView.swift`, `SkillsView.swift`, `MemoryView.swift`, `HooksView.swift`, `ProjectsView.swift`, `SessionsPageView.swift`, `TimelinePageView.swift`, `HomeView.swift` — replace `DaemonClient` environment usage.
- Modify: `macos/Engram/Views/Projects/RenameSheet.swift`, `ArchiveSheet.swift`, `UndoSheet.swift` — route project operations through service client.
- Modify: `macos/Engram/Views/Settings/GeneralSettingsSection.swift` — replace HTTP port/Node path/status infrastructure UI with service status/socket/helper UI.
- Modify: `macos/Engram/Views/Settings/SourcesSettingsSection.swift` — replace Node MCP setup snippets with Swift `EngramMCP` helper snippets.
- Modify: `macos/Engram/Views/Settings/NetworkSettingsSection.swift` — remove soft `mcpStrictSingleWriter` wording after real IPC lands; route sync trigger through service client.
- Modify: `macos/Engram/Views/Settings/AISettingsSection.swift` — route title regenerate-all through service client; normalize `titleBaseURL`/`titleBaseUrl`.
- Modify: `macos/Engram/Core/EngramLogger.swift` — stop posting to `/api/log`; use service log command or local OSLog until service is reachable.
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift` — inject `EngramServiceClient` for mutating/long-running tools; fail closed on unavailable service.
- Modify: `macos/EngramMCP/main.swift` — configure socket client from environment/settings; do not instantiate a writer service.
- Modify: `macos/EngramCLI/main.swift` — route write-capable commands through service IPC before deleting Node CLI behavior.
- Replace tests: `macos/EngramTests/IndexerProcessTests.swift` with `EngramServiceStatusStoreTests.swift`.
- Replace tests: `macos/EngramTests/DaemonClientTests.swift` with `EngramServiceClientTests.swift`.
- Add tests: `macos/EngramTests/UnixSocketTransportTests.swift`, `ServiceWriterGateTests.swift`, `ServiceCommandContractTests.swift`, `ServiceProviderTests.swift`.
- Add tests: `macos/EngramMCPTests/ServiceUnavailableMutatingToolTests.swift` and `ServiceForwardingMutatingToolTests.swift`.
- Add fixtures: `tests/fixtures/service-ipc/*.jsonl` for service request/event/response contracts.

## Hard Cutover Rules

- App-local in-process service is allowed only for Stage 3 app smoke tests where Swift MCP mutating tools and Swift CLI mutating commands are still disabled or still on Node.
- Before any Swift MCP mutating tool is enabled, `EngramMCP` must use `EngramServiceClient` over a real Unix-domain socket connected to the shared `EngramService` writer process.
- Before any Swift CLI mutating command is enabled, `EngramCLI` must use the same real IPC path and must fail closed if unavailable.
- Stage 4 is blocked until the real IPC gate proves two concurrent external clients can submit write commands through the production transport and the service serializes them through exactly one writer authority.
- The service process must construct exactly one `EngramDatabaseWriter`; `ServiceWriterGate` owns that instance, and command handlers receive write access only by entering the gate. Add a runtime assertion or dependency-injection test that fails if a second writer is constructed inside `EngramService`.
- After a service write acknowledgement, service/client code must invalidate or refresh any direct `EngramCoreRead` reader pools before read-after-write MCP/UI flows are considered current. If that consistency cannot be guaranteed for a read tool, route that read through service instead of direct `EngramCoreRead`.
- `EngramMCP` and `EngramCLI` must never import `EngramService` implementation files, instantiate `InProcessEngramServiceTransport`, open a write-capable `DatabasePool`, or execute direct project/insight/session mutation SQL.
- App, MCP, and CLI may compile shared DTO/client/transport protocol files, but must not compile service server, writer gate, background job, or project-operation writer implementations from app/MCP-importable `macos/Shared`.
- Delete or ignore `mcpStrictSingleWriter` only after the hard single-writer policy is enforced in code; do not keep a user toggle that reintroduces direct-write fallback.

## Task 1: Define Shared Service Contract Before Implementing Runtime

**Files:**
- Create: `macos/Shared/Service/EngramServiceDTOs.swift`
- Create: `macos/Shared/Service/EngramServiceClient.swift`
- Create: `macos/Shared/Service/EngramServiceTransport.swift`
- Add tests: `macos/EngramTests/EngramServiceClientTests.swift`
- Add fixtures: `tests/fixtures/service-ipc/status-event.jsonl`, `project-move-request.json`, `service-error.json`

- [ ] Define `EngramServiceStatus` with equivalents for current `IndexerProcess.Status`: `stopped`, `starting`, `running(total:)`, `degraded(message:)`, `error(message:)`.
- [ ] Define `EngramServiceEvent` fields covering every current `DaemonEvent` field consumed by UI: `event`, `indexed`, `total`, `todayParents`, `message`, `sessionId`, `summary`, `port`, `host`, `action`, `removed`, plus `usage` payloads matching `IndexerProcess.UsageItem`.
- [ ] Define typed request/response DTOs for the current `DaemonClient` surface: live sessions, source info, skills, memory, hooks, hygiene, lint, handoff, replay timeline, parent link/suggestion management, project migrations, project cwds, project move/archive/undo, search, embedding status, summary generation, title regenerate-all, sync trigger, resume command, save insight, link sessions, and log forwarding.
- [ ] Create or consume `docs/swift-single-stack/daemon-client-map.md` before replacing UI calls; the map must include every `/api/*` endpoint, non-API `/health` link, current `DaemonClient` method, final `EngramServiceClient` method, and explicit deletion decision.
- [ ] Preserve current JSON field names from `DaemonClient.swift` and `src/web.ts`; use Swift property coding keys only where the Node JSON uses snake_case or lower camel-case that differs from Swift naming.
- [ ] Define `EngramServiceError` with at least: `serviceUnavailable`, `transportClosed`, `invalidRequest`, `unauthorized`, `writerBusy`, `commandFailed(name:message:retryPolicy:details:)`, and `unsupportedProvider`.
- [ ] Add client tests with a fake transport proving request ids are attached, typed responses decode, structured error envelopes preserve `name/message/retry_policy/details`, concurrent requests resolve independently, and event stream cancellation closes the transport subscription.
- [ ] Verify:
  - `xcodegen generate --spec macos/project.yml`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/EngramServiceClientTests`

## Task 2: Implement Real IPC Transport and Single-Writer Gate

**Files:**
- Create: `macos/Shared/Service/UnixSocketEngramServiceTransport.swift`
- Create: `macos/EngramService/IPC/UnixSocketServiceServer.swift`
- Create: `macos/EngramService/Core/ServiceWriterGate.swift`
- Add tests: `macos/EngramTests/UnixSocketTransportTests.swift`, `macos/EngramTests/ServiceWriterGateTests.swift`

- [ ] Use a Unix-domain socket path under `~/.engram/run/engram-service.sock` by default, overridable by `ENGRAM_SERVICE_SOCKET` and `--service-socket` for tests.
- [ ] Ensure `~/.engram/run` is created with owner-only permissions and reject startup if the runtime directory is world/group writable.
- [ ] Acquire an exclusive process lock at `~/.engram/run/engram-service.lock` before opening write-capable database/core resources.
- [ ] On startup, remove a stale socket only after the lock is acquired and a connection probe proves no live service owns it.
- [ ] The server accepts local clients only, frames requests deterministically, supports request/response and event subscription messages, and rejects malformed frames with a typed `invalidRequest` response without crashing.
- [ ] The client transport supports connect timeout, per-command timeout, clean close, and event stream reconnect only when the caller explicitly starts a new stream.
- [ ] Add tests for permission refusal, stale socket cleanup, second writer lock failure, malformed frame handling, large response framing, concurrent read commands, serialized write commands, and event stream cancellation.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/UnixSocketTransportTests -only-testing:EngramTests/ServiceWriterGateTests`

## Task 3: Add `EngramService` Helper Runtime

**Files:**
- Create: `macos/EngramService/main.swift`
- Create: `macos/EngramService/Core/EngramService.swift`
- Create: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Create: `macos/EngramService/Core/ServiceEventBroker.swift`
- Create: `macos/EngramService/Core/ServiceBackgroundJobs.swift`
- Modify: `macos/project.yml`
- Add or modify: `macos/scripts/copy-service-helper.sh`
- Add tests: `macos/EngramTests/ServiceCommandContractTests.swift`

- [ ] Add an `EngramService` tool target to `macos/project.yml` that includes `EngramService` and `Shared`, depends on GRDB, and is built by the `Engram` scheme.
- [ ] Add a post-build script that copies the `EngramService` helper into the app bundle; keep this separate from MCP helper copying.
- [ ] Implement service startup sequence: read settings, resolve database path, acquire writer gate, open/migrate database through the Swift core boundary, publish `starting`, run initial maintenance, publish `ready/running`.
- [ ] Emit compatibility events for current UI expectations: `ready`, `indexed`, `rescan`, `sync_complete`, `watcher_indexed`, `summary_generated`, `error`, `warning`, `wal_checkpoint`, `ai_audit`, `usage`, and `alert`.
- [ ] Move background jobs behind explicit service-owned timers: initial scan, watcher changes, non-watchable source rescans, recoverable index jobs, sync, usage collection, health checks, git probe, log/metrics retention, WAL checkpoint, auto-summary, and title regeneration.
- [ ] Ensure all mutating commands are handled through one serialized service command actor or queue; read commands may run concurrently against read pools.
- [ ] Commands that are not ported yet must return `unsupported` with a named error; they must not silently fall back to Node, HTTP, or direct DB writes.
- [ ] Add subprocess tests that launch `EngramService` with fixture home/data dirs, connect over the socket, receive `ready`, call `status`, call at least one read command, call one dry-run project command, and terminate cleanly.
- [ ] Verify:
  - `xcodegen generate --spec macos/project.yml`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme EngramService build -destination 'platform=macOS'`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ServiceCommandContractTests`

## Task 4: Preserve AI Summary, Title, and Embedding Behavior

**Files:**
- Create: `macos/Shared/Settings/EngramFileSettings.swift`
- Create: `macos/Shared/AI/SummaryProvider.swift`
- Create: `macos/Shared/AI/TitleProvider.swift`
- Create: `macos/Shared/AI/EmbeddingProvider.swift`
- Modify: `macos/EngramService/Core/ServiceBackgroundJobs.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Add tests: `macos/EngramTests/ServiceProviderTests.swift`

- [ ] Port settings reads from `src/core/config.ts`: `~/.engram/settings.json`, `@keychain` sentinel overlay for `aiApiKey` and `titleApiKey`, legacy `aiProvider` to `aiProtocol`, legacy noise toggles to `noiseFilter`, and both `titleBaseURL` and `titleBaseUrl` spellings.
- [ ] Port summary prompt behavior from `src/core/ai-client.ts`: default Chinese prompt, `{{language}}`, `{{maxSentences}}`, `{{style}}`, blank-line stripping, preset/custom generation config, sample-first/sample-last truncation, and provider-specific request/response parsing for OpenAI, Anthropic, and Gemini.
- [ ] Port title behavior from `src/core/title-generator.ts`: provider enum `ollama/openai/dashscope/custom`, Ollama `/api/generate`, OpenAI-compatible `/v1/chat/completions`, max tokens 50, temperature 0.3, six-message prompt sampling, response cleanup, 30-character cap, and audit recording.
- [ ] Port auto-summary behavior from `src/core/auto-summary.ts`: per-session cooldown timers, minimum message threshold, summary freshness threshold, cleanup on shutdown, and `summary_generated` or `summary_error` events.
- [ ] Implement embedding providers with an explicit no-fallback policy: Ollama `/api/embed`, OpenAI `text-embedding-3-small` with configured dimension, L2-normalize truncated Ollama vectors, and record model/dimension in status.
- [ ] Explicitly narrow `transformers` for the first Swift-only pass unless a native local model implementation is added in the same task: return `unsupportedProvider("transformers")`, mark semantic search unavailable, keep existing vectors readable only when the model/dimension metadata matches, and do not launch Node or load Transformers.js.
- [ ] Add provider tests using custom `URLProtocol` or injected HTTP transport fixtures for successful OpenAI/Anthropic/Gemini summaries, failed HTTP responses, Ollama title success, OpenAI-compatible title success, Ollama embedding dimension truncation, OpenAI embedding parsing, Transformers unsupported status, and audit records.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ServiceProviderTests`

## Task 5: Replace App Startup, Status, and Environment Injection

**Files:**
- Modify: `macos/Engram/App.swift`
- Modify: `macos/Engram/Core/AppEnvironment.swift`
- Create: `macos/Shared/Service/EngramServiceStatusStore.swift`
- Create: `macos/Shared/Service/InProcessEngramServiceTransport.swift`
- Replace tests: `macos/EngramTests/IndexerProcessTests.swift` with `macos/EngramTests/EngramServiceStatusStoreTests.swift`

- [ ] In `AppDelegate`, stop constructing `IndexerProcess` and `DaemonClient`; construct `EngramServiceStatusStore` and `EngramServiceClient` instead.
- [ ] Stop starting `MCPServer/MCPTools` from the app; after this task the shipped app-local HTTP MCP bridge is no longer started by `Engram.app`.
- [ ] Stop resolving `nodejsPath`, stop locating `Bundle.main` `node/daemon.js`, and stop calling `indexer.start(nodePath:scriptPath:)`.
- [ ] Start or connect to the `EngramService` helper in production. Use in-process transport only when `AppEnvironment` is test/development and an explicit `--service-in-process` or equivalent test flag is present.
- [ ] Subscribe to service events once during app launch and update `EngramServiceStatusStore` fields equivalent to current `IndexerProcess` fields: status, total sessions, today parent sessions, last summary session id, usage data, service endpoint health, and embedding status.
- [ ] Update `Settings` scene, popover standalone window, menu bar controller, and main window environment injection to pass `DatabaseManager` only for read compatibility plus service client/status store for all service state and commands.
- [ ] Ensure `applicationWillTerminate` asks the service client to close event subscriptions and stops only app-owned helper processes; it must not kill an externally owned shared service that MCP clients may be using.
- [ ] Add status-store tests that decode legacy event fixtures and prove display strings and `isRunning` semantics match the old `IndexerProcess.Status` where UI snapshots expect them.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/EngramServiceStatusStoreTests`
  - `rg "IndexerProcess\\(|indexer\\.start|nodejsPath|daemon\\.js|MCPServer\\(" macos/Engram`
  - Expected `rg`: no production app startup references remain; settings migration references may remain only where explicitly handled.

## Task 6: Replace `DaemonClient` and Direct HTTP Usage in UI Flows

**Files:**
- Modify: all UI files listed in the File Map that currently use `DaemonClient`, `IndexerProcess`, or direct `http://127.0.0.1` `/api/*` URLs.
- Replace tests: `macos/EngramTests/DaemonClientTests.swift` with `EngramServiceClientTests.swift`.
- Modify fixtures: `macos/Engram/TestSupport/MockDaemonFixtures.swift` into service mock fixtures or delete after callers migrate.

- [ ] Replace `@Environment(DaemonClient.self)` with `@Environment(EngramServiceClient.self)` or a testable service-client protocol in every view.
- [ ] Replace `@Environment(IndexerProcess.self)` with `@Environment(EngramServiceStatusStore.self)` in every view.
- [ ] Replace direct search URLs in `SearchView`, `SearchPageView`, `CommandPaletteView`, and `GlobalSearchOverlay` with `serviceClient.search(...)`; preserve local FTS fallback only as a read-only fallback that cannot mutate and does not claim semantic availability.
- [ ] Replace embedding status URLs in `PopoverView`, `SearchView`, and `SearchPageView` with `serviceClient.embeddingStatus()`.
- [ ] Replace `SessionDetailView` summary and handoff calls with `serviceClient.generateSummary(sessionId:)` and `serviceClient.handoff(...)`.
- [ ] Replace `ResumeDialog` resume call with `serviceClient.resumeCommand(sessionId:)`.
- [ ] Replace parent link/suggestion calls in session list, session detail, home, sessions, and timeline views with service client methods.
- [ ] Replace project rename/archive/undo/cwds/migrations calls in `ProjectsView`, `RenameSheet`, `ArchiveSheet`, and `UndoSheet` with service client methods; preserve dry-run-first UI semantics.
- [ ] Replace `NetworkSettingsSection.triggerSync()` with `serviceClient.triggerSync(peer:)`.
- [ ] Replace `AISettingsSection` title regenerate-all button with `serviceClient.regenerateAllTitles()`. Keep provider test connection as direct provider call only if it does not mutate Engram DB.
- [ ] Replace live sessions, source pulse, skills, memory, hooks, hygiene, replay timeline, monitor alerts, and app log forwarding with service-client calls.
- [ ] Delete or quarantine `DaemonClient.swift` and `DaemonHTTPClientCore.swift` only after `rg "DaemonClient|DaemonHTTPClientCore|/api/|http://127.0.0.1|localhost:|writerPool|DatabasePool\\(path:|\\.write \\{" macos/Engram` shows no production UI dependency or second-writer path. Keep tests or compatibility shims only under clearly named migration tests.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramUITests/PopoverSmokeTests -only-testing:EngramUITests/SearchSmokeTests -only-testing:EngramUITests/SettingsSmokeTests`
  - `rg "DaemonClient|IndexerProcess|http://127\\.0\\.0\\.1|localhost:|/api/search|/api/summary|/api/project" macos/Engram`

## Task 7: Gate MCP and CLI Mutating Cutover on Real IPC

**Files:**
- Modify: `macos/EngramMCP/main.swift`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Modify: `macos/EngramCLI/main.swift`
- Add tests: `macos/EngramMCPTests/ServiceUnavailableMutatingToolTests.swift`
- Add tests: `macos/EngramMCPTests/ServiceForwardingMutatingToolTests.swift`

- [ ] Classify every MCP tool as read-only, mutating, long-running read, or operational. Read-only tools may continue using read-only database/core access; mutating and operational tools must use `EngramServiceClient`.
- [ ] Mutating MCP tools include at least: `save_insight`, `link_sessions`, `project_move`, `project_archive`, `project_move_batch`, `project_undo`, `manage_project_alias` add/remove, summary generation, and any future write to sessions, insights, aliases, migration logs, or filesystem state.
- [ ] `EngramMCP` startup must create a Unix-socket service client. If unavailable, read-only tools can still run only if they do not need service state; mutating tools return a typed service-unavailable MCP error and perform no local write.
- [ ] Remove any direct-write fallback controlled by `mcpStrictSingleWriter`; the new behavior is strict always.
- [ ] `EngramCLI` write-capable commands must follow the same rule. Do not enable Swift CLI mutation until the IPC service smoke test passes in CI/local verification.
- [ ] Add MCP tests proving `save_insight` and `project_move` fail closed when the socket is missing, and proving a fake service receives the exact request payload when the socket is available.
- [ ] Add a database no-op assertion for unavailable-service mutating tests: row counts and migration logs must remain unchanged.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'`
  - `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_move","arguments":{"src":"/tmp/a","dst":"/tmp/b","dry_run":true}}}' | <built-EngramMCP-helper>` with no service running
  - Expected direct command result: typed service-unavailable error and no filesystem/database mutation.

## Task 8: UI Compatibility and Settings Copy Updates

**Files:**
- Modify: `macos/Engram/Views/Settings/GeneralSettingsSection.swift`
- Modify: `macos/Engram/Views/Settings/SourcesSettingsSection.swift`
- Modify: `macos/Engram/Views/Settings/NetworkSettingsSection.swift`
- Modify: `macos/Engram/Views/Usage/PopoverUsageSection.swift`
- Modify: `macos/EngramUITests/Tests/SmokeTests/SettingsSmokeTests.swift`
- Modify baselines only if intentional visual text changes require it.

- [ ] Replace General > Infrastructure fields with service status, socket path, helper version/build, database path, and last event time.
- [ ] Remove Node.js path and MCP script path from production settings UI once `EngramMCP` snippets point to the Swift helper.
- [ ] Replace MCP setup snippets to use the bundled or installed `EngramMCP` executable directly, not `node ~/.engram/dist/index.js`.
- [ ] Replace Network > MCP strict single-writer text with a non-toggle status line such as `MCP writes require EngramService IPC`; do not expose a setting that can disable this.
- [ ] Preserve existing accessibility identifiers for settings sections and popover status where possible; if identifiers change, update UI tests in the same task.
- [ ] Keep `PopoverUsageSection` rendering unchanged by mapping service usage events into the same source/metric/value/resetAt shape.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramUITests/SettingsSmokeTests -only-testing:EngramUITests/PopoverSmokeTests`

## Task 9: Disable Node Launch In App Flow After Parity Gates

**Files:**
- Modify: `macos/Engram/App.swift`
- Modify: `macos/Engram/Core/AppEnvironment.swift`
- Modify docs that describe temporary development flags for the app service path.

- [ ] Stop launching `node daemon.js` from the app production path only after the app smoke test passes with Swift service enabled.
- [ ] Keep the Node bundle script, `dist`, `node_modules`, and `Resources/node` packaging untouched until Stage 5 cutover gates pass; Node remains the rollback/reference runtime through Stage 4.
- [ ] Keep TypeScript tests and sources in the repo until the broader Swift parity/deletion plan removes them.
- [ ] Add a production app assertion that no runtime launch path invokes Node while preserving the packaged Node reference until Stage 5.
- [ ] Verify:
  - `rg "nodejsPath|daemon\\.js|IndexerProcess|MCPServer\\(" macos/Engram --glob '!**/*Tests*'`
  - Expected: no production app launch path for Node or app-local MCP bridge after app service cutover.

## Acceptance Gates

- Service IPC gate: a standalone `EngramService` process starts, acquires the writer lock, constructs exactly one `EngramDatabaseWriter` owned by `ServiceWriterGate`, opens the fixture DB, emits `ready`, serves a status request, accepts two concurrent external client connections through the production transport, serializes their dry-run/write-intent commands through one writer authority, and shuts down cleanly.
- Single-writer gate: a second `EngramService` process cannot acquire the writer lock; `EngramMCP` and `EngramCLI` cannot instantiate in-process writer service code.
- Mutating MCP gate: with no service socket, `save_insight` and `project_move` return typed service-unavailable errors and leave DB/filesystem unchanged; with a fake service socket, they forward exact payloads.
- App gate: app launches without `node daemon.js`, without app-local `MCPServer`, and without `DaemonClient`; popover, search, settings, projects, session detail, replay, and live badge flows use service client/status store.
- UI compatibility gate: existing accessibility identifiers and smoke tests pass or are intentionally updated in the same commit.
- AI gate: summary/title provider tests cover success and failure for supported providers; embedding status is accurate for Ollama/OpenAI and explicit for Transformers unsupported/narrowed behavior.
- Search/embedding gate: semantic search is never reported available unless the configured provider, model, dimension, and vector store are usable by Swift without Node.
- Packaging/deletion gate is deferred to Stage 5; Stage 3 may disable Node launch in the app but must not remove Node packaging, scripts, or reference artifacts.

## Concrete Verification Commands

- `xcodegen generate --spec macos/project.yml`
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramService build -destination 'platform=macOS'`
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS'`
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'`
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramUITests/PopoverSmokeTests -only-testing:EngramUITests/SearchSmokeTests -only-testing:EngramUITests/SettingsSmokeTests`
- `npm test -- tests/core/ai-client.test.ts tests/core/auto-summary.test.ts tests/core/title-generator.test.ts tests/core/embeddings.test.ts tests/web/daemon-http-contract.test.ts`
- `rg "IndexerProcess|DaemonClient|DaemonHTTPClientCore|nodejsPath|daemon\\.js|MCPServer\\(" macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI`
- `rg "http://127\\.0\\.0\\.1|localhost:|/api/search|/api/summary|/api/project|mcpStrictSingleWriter" macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI`
- Stage 5 owns bundle artifact deletion checks; Stage 3 verification checks app launch paths only and must not fail because rollback Node resources are still packaged.

## Residual Risks

- The plan assumes the broader Swift core/adapters/indexer parity work exists or is implemented in adjacent plan sections; `EngramService` cannot become production writer until Swift core write APIs match Node behavior.
- Unix-domain socket IPC is the fastest robust path, but a later XPC hardening pass may still be needed for launch ownership, service restart policy, and client identity.
- Transformers.js cannot remain in a Swift-only shipped app. This draft explicitly narrows it unless a native local embedding backend is added before cutover.
- Some UI views currently mix direct DB reads with HTTP/service reads. During migration, keep direct DB access read-only and remove it only after equivalent core repositories exist.
