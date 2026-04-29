# Swift Single Stack Design

Date: 2026-04-23
Status: polycli-reviewed spec, implementation plan merged

## Goal

Engram should become a Swift-only, macOS-only product. The final shipped app must not require Node.js, launch a Node daemon, bundle `dist/` or `node_modules`, or expose duplicate MCP implementations.

The migration must preserve full user-visible parity before removing Node. The target is not "hide Node better"; the target is to delete Node from the app architecture after Swift proves it owns the same behavior.

## Non-Goals

- Keep Linux or Windows runtime parity.
- Keep the old Node stdio MCP server as a fallback after the cutover.
- Keep the app-local HTTP MCP bridge after clients use Swift stdio MCP.
- Rewrite the Swift UI visual layer.
- Change the SQLite file location or intentionally break existing databases.
- Replace external AI CLI formats; Engram still reads their existing session files.

## Current Architecture

Engram currently has three MCP-related paths and one Node-owned background runtime:

- `src/index.ts` implements the Node stdio MCP server.
- `macos/EngramMCP` implements the new Swift stdio MCP helper.
- `macos/Engram/Core/MCPServer.swift` and `MCPTools.swift` implement the older app-local MCP bridge.
- `macos/Engram/Core/IndexerProcess.swift` launches `node daemon.js`, parses stdout events, and exposes daemon status to the Swift UI.

Node still owns substantial product behavior:

- schema migration and repository logic under `src/core/db*`;
- session adapters under `src/adapters/*`;
- indexing, watching, scoring, summaries, embeddings, usage probes, health rules, and project move orchestration under `src/core/*`;
- HTTP daemon endpoints used by `macos/Engram/Core/DaemonClient.swift`;
- bundle production through the app's Node resources.

Recent Swift MCP parity work closed stdio tool behavior gaps, but it did not remove the Node daemon or Node bundle.

## Chosen Approach

Use a service-replacement migration.

This keeps the current product shape while changing the implementation owner: replace the Node daemon with a Swift background service, move shared logic into a Swift core module, route the app and Swift MCP through that shared core/service boundary, then delete the Node runtime and old bridge.

The service boundary is a correctness boundary, not just an abstraction boundary. Before any mutating MCP tool is cut over, `EngramServiceClient` must reach one shared writer process through IPC. An app-local in-process service is acceptable only for early app smoke tests that do not expose mutating MCP tools.

Rejected alternatives:

- Direct app-to-database only: simpler at first, but it recreates multi-writer risk when the app, MCP helper, and background jobs mutate SQLite independently.
- Full XPC-only redesign: strong long-term isolation, but it is too much surface area for the first Node-removal pass. The first pass should use a thin service boundary with a concrete local IPC transport, either XPC or a Unix-domain socket, so it can be hardened later without rewriting core logic.

## Target Architecture

### `EngramCore`

`EngramCore` is the shared Swift domain layer. It owns database access, migrations, queries, parsing, scoring, search, and project/session domain operations.

Responsibilities:

- open and migrate the existing SQLite database;
- expose typed read repositories for sessions, messages, metrics, insights, costs, parent links, aliases, sync state, index jobs, and migration logs;
- implement read APIs used by Swift UI and Swift MCP tools;
- implement write primitives behind explicit transactions, but expose them only to `EngramService`;
- parse all supported AI session sources currently represented by `src/adapters/*`;
- provide deterministic adapters with golden fixtures for each source;
- provide FTS and vector-search abstractions without forcing every caller to know SQLite details;
- normalize error types for UI, MCP, and service clients.

Key rules:

- App UI and MCP helpers may import `EngramCoreRead`.
- Only `EngramService` may import or call `EngramCoreWrite`.
- All SQLite connections must set and verify `PRAGMA journal_mode = WAL` and `PRAGMA busy_timeout >= 5000`.
- `DatabasePool` is preferred for read concurrency; direct ad hoc writer connections are forbidden.
- App UI, MCP tools, and the background service must not duplicate SQL business logic.

### `EngramService`

`EngramService` replaces the Node daemon. It is the single owner of continuous background work and every write-capable operation.

Responsibilities:

- run startup migration and maintenance;
- run initial indexing and incremental rescans;
- watch supported session roots;
- update index jobs and emit status events;
- run summary/title generation where already supported;
- run embeddings and vector backfill where configured;
- run usage probes and health checks;
- expose project move/archive/undo/recover operations as serialized service commands;
- provide an event stream compatible with the Swift UI's current status model.

The service must have one process-level writer authority. The app may host this authority in early Stage 3 only while MCP mutations remain on Node. Before Stage 4 exposes Swift mutating MCP tools, `EngramServiceClient` must connect to the shared writer through local IPC. `EngramMCP` must never instantiate an independent writer service for mutating tools.

The first IPC transport should be whichever is fastest to make robust in this repo: XPC if packaging and launch ownership are clear, otherwise a Unix-domain socket with strict local filesystem permissions. The service API must not depend on the transport choice.

### `EngramServiceClient`

`EngramServiceClient` is the boundary used by the Swift UI and Swift MCP helper for operations that should not write SQLite directly.

Responsibilities:

- expose async command methods for every current `DaemonClient` capability, including project move/archive/undo/recover, hygiene checks, live sessions, session linking, suggestion confirmation/deletion, handoff, timeline replay, summaries, backfills, settings-dependent AI operations, and maintenance;
- expose an async event stream for indexing, usage, health, and background progress;
- convert service/domain errors into UI and MCP-safe payloads;
- make no assumptions in callers about whether the service is in-process, XPC, Unix-socket, or helper-based;
- preserve typed response models currently returned by `DaemonClient`, including project migration logs, lint results, live session payloads, hygiene results, and replay payloads.

### `EngramMCP`

`macos/EngramMCP` remains the only MCP server shipped for Engram.

Responsibilities:

- speak MCP over stdio;
- use `EngramCore` directly for read-only tools;
- use `EngramServiceClient` for mutating or long-running tools;
- fail closed if the service IPC endpoint is unavailable for mutating tools instead of opening a second writer;
- retain full contract parity with the current Node MCP server until the Node server is deleted;
- keep golden contract tests for initialize, search, context, project move, archive, export, stats, costs, insights, memory, sessions, and timeline tools.

After cutover, `src/index.ts` is removed and all README MCP examples point to the Swift stdio helper.

### `Engram.app`

The macOS app becomes Swift-only.

Responsibilities:

- open the menu bar UI and settings;
- initialize `EngramCore`;
- start or connect to `EngramService`;
- show service status through the existing popover and observability views;
- stop launching `node daemon.js`;
- stop starting the old `MCPServer`/`MCPTools` bridge;
- stop shipping `Resources/node`.

The app keeps `DatabaseManager` only as a compatibility wrapper during migration. The final state should either rename it into `EngramCore` repositories or make it a thin facade over them.

### `EngramCLI`

Engram should keep terminal workflows only if they are reimplemented in Swift. Node CLI deletion must not silently remove user-facing commands.

Responsibilities:

- provide Swift replacements for current documented terminal commands, or explicitly document removed commands before Stage 5;
- route write-capable commands through `EngramServiceClient`;
- share argument validation and response models with MCP/service code where practical;
- be verified independently from MCP stdio so CLI users do not depend on MCP clients.

## Data Flow

### Startup

1. `Engram.app` loads settings and database path.
2. `EngramCore` opens SQLite and runs Swift-owned migrations.
3. `EngramService` starts or connects to the serialized writer authority.
4. `EngramService` emits a `ready` event with database path, total sessions, and active source roots.
5. UI subscribes to service events and reads initial dashboard data from `EngramCore`.

### Indexing

1. `EngramService` scans configured AI session roots.
2. Source adapters parse raw files into normalized session snapshots.
3. `EngramCore` upserts sessions, messages, metrics, parent links, and source metadata in one transaction per batch.
4. `EngramService` updates index-job rows and emits progress events.
5. UI and MCP reads see committed state only.

### MCP Read Tool

1. MCP client calls Swift stdio helper.
2. `MCPToolRegistry` validates arguments.
3. Read-only tools call `EngramCore` repositories directly.
4. Results are encoded with stable JSON ordering where golden tests require it.

### MCP Mutating Tool

1. MCP client calls Swift stdio helper.
2. `MCPToolRegistry` validates arguments and request identity.
3. The tool submits a command through `EngramServiceClient`.
4. `EngramService` serializes the command, uses `EngramCore` write APIs, records migration/job logs, and returns a typed result.
5. If the shared service is not reachable, the MCP helper returns a typed service-unavailable error and does not perform a local write.

## Migration Strategy

The migration is intentionally staged. Node remains available until each stage has parity evidence. Deletion happens only after full parity gates pass.

### Stage 0: Mandatory Baseline and Inventory

Create the artifacts that make later work measurable and safe.

Deliverables:

- Canonical Node baseline at `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`.
- Runtime inventory of every Node, npm, bundled resource, daemon, MCP, CLI, and docs reference.
- File disposition table describing whether each Node/TypeScript file is deleted, archived as fixture history, retained as a non-shipped dev tool, or replaced by Swift.
- App-write inventory mapping each current app-side database write to a service command or explicit removal decision.
- Stage gate checklist with exact verification commands and rollback points.

Exit gate:

- Stage 0 artifacts exist and have no unresolved placeholder disposition.
- Stage 1 cannot start until this exit gate passes.

### Stage 1: Swift Core Extraction

Create reusable Swift core boundaries while preserving current behavior.

Deliverables:

- Swift repository interfaces mapped to the existing SQLite schema.
- Swift migration runner equivalent to Node migrations.
- Golden DB fixture tests proving Swift reads existing Node-created databases.
- Golden DB fixture tests for empty, fully migrated, partially migrated, and historical production schemas.
- Validation that the Stage 0 baseline exists and contains Node-backed cold launch, cold DB open, idle RSS, fixture indexing, incremental indexing, and MCP `search`/`get_context` p50/p95.
- FTS version tracking and rebuild triggers equivalent to the Node `FTS_VERSION` behavior.
- Vector table rebuild behavior for embedding model or dimension changes.
- A concrete `sqlite-vec` strategy: vendor and load a Swift-compatible native extension, or document a replacement vector index with parity tests.
- No product behavior removal.

Exit gate:

- Existing Swift MCP tests pass.
- Existing npm tests pass.
- Swift database tests prove read parity for core entities.
- Swift migration tests pass from every retained historical schema fixture to the current schema.
- GRDB schema definitions read a database migrated by the Swift migration runner.

### Stage 2: Adapter and Indexing Parity

Port the session adapter layer from TypeScript to Swift.

Deliverables:

- Swift adapters for Codex, Claude Code, Gemini CLI, OpenCode, iFlow, Qwen, Kimi, Cline, Cursor, VS Code, Windsurf, Antigravity, and Copilot.
- Fixture-based adapter tests comparing normalized snapshots against Node-generated expected output.
- Swift indexer that can fill the same SQLite tables from fixture roots.
- Parent-detection logic ported from the Node implementation, including scoring, dispatch patterns, temporal decay, CWD classification, and orphan handling.
- Startup backfills ported explicitly: subagent tier downgrade, parent link backfill, stale detection reset, Codex originator backfill, and suggested parent backfill.
- Gemini sidecar handling for `{sessionId}.engram.json` parent session linkage.
- Windsurf/Cascade gRPC and Protocol Buffers strategy, including Swift gRPC client choice and `.proto` build integration if the source remains supported.

Exit gate:

- For every supported source, Swift indexing produces the same session/message/metric/project rows as the Node indexer on controlled fixtures.
- For every supported source, malformed fixtures cover invalid UTF-8, truncated JSON/JSONL, deeply nested records, malformed tool-call arguments, files larger than 100 MB, sessions with more than 10,000 messages, and file modification during parse.
- Adapter tests compare failure classification as well as successful output.

### Stage 3: Service Replacement

Introduce `EngramService` and move background runtime behavior into Swift.

Deliverables:

- Swift startup service with event stream compatible with `IndexerProcess.Status`.
- Swift file watcher and rescan loop.
- Swift index job runner.
- Swift maintenance tasks, including FTS/vector rebuild triggers and parent/insight reconciliation.
- Explicit `EngramService.Status` and `EngramService.Event` types that cover every current `DaemonEvent` field consumed by the UI: `event`, `indexed`, `total`, `todayParents`, `message`, `sessionId`, `summary`, `port`, `host`, `action`, `removed`, and usage payloads.
- File watcher semantics documented and tested: debounce interval, maximum batch size, rename handling, symlink target changes, directory renames, permission revocation, rapid append/delete cycles, and duplicate-event suppression.
- Embedding provider strategy ported or explicitly narrowed, covering Ollama, OpenAI, and Transformers.js behavior from settings.
- AI summary/title HTTP client behavior ported for configured providers, including request/response/error handling.
- UI integration that no longer depends on Node stdout JSON events in development builds.

Exit gate:

- App can run with Node daemon disabled and still index, watch, report counts, and update usage/status views in a fixture-backed and local smoke test.
- UI views that currently read `indexer.*` or `daemonClient.*` have fixture or smoke coverage through the Swift service path.

### Stage 4: MCP and Mutating Operation Parity

Move mutating and operational MCP tools to Swift service commands.

Deliverables:

- Swift implementations for save insight, link sessions, project move, archive, recover, review, undo, export, summary generation, memory, costs, insights, stats, file activity, timeline, and lint config behavior.
- Golden MCP contract tests expanded to every public tool.
- Error-shape parity tests for common failure modes.
- 1:1 map of every `DaemonClient` method and Node HTTP endpoint to an `EngramServiceClient` command or explicit deletion decision.
- Response model parity for project moves, migration logs, lint results, live sessions, hygiene checks, handoff, timeline replay, and session linking.
- Full project move/archive/undo compensation logic ported, including lock acquisition/release, git dirty checks, directory rename plans, reverse patches, reverse physical moves, `projects.json` updates, collision errors, and concurrent modification detection.
- Failure-injection tests for project move/archive/undo that simulate failure at each step and prove rollback restores original filesystem and database state.
- Insight degradation behavior ported: text-only fallback with warning, dual-write when embeddings are available, startup reconciliation between `insights` and `memory_insights`, and FTS fallback for search/get_context/get_memory.
- Session linking and suggestion confirmation/deletion paths replaced by Swift service commands and MCP/CLI/UI affordances, or explicitly documented as removed before Stage 5.
- Swift service IPC transport implemented for mutating MCP/CLI commands.

Exit gate:

- Node MCP and Swift MCP return equivalent JSON for the full tool suite on shared fixtures, except where the spec explicitly documents an intentional Swift-only improvement.
- Node daemon and Swift service can dual-run in a controlled parity mode against the same fixture corpus, with all writes directed to a single active writer at a time, and produce matching MCP outputs, indexing event counts, and database row checksums.
- Swift MCP mutating tools fail closed when the shared service endpoint is unavailable.

### Stage 5: Cutover and Node Deletion

Delete Node runtime only after all parity gates pass.

Deliverables:

- Remove app Node launch code from `App.swift` and `IndexerProcess.swift`.
- Remove `DaemonClient` HTTP dependency or replace it with `EngramServiceClient`.
- Remove old `MCPServer.swift`, `MCPTools.swift`, and `EngramCLI` bridge only after scan tests and CLI replacement/deprecation documentation exist.
- Remove `src/index.ts`, `src/daemon.ts`, `src/web.ts`, Node core runtime code, TypeScript MCP tools, Node bundle script, Node dependencies, and Node README instructions.
- Remove `src/cli/*.ts` only after Swift CLI replacement or documented CLI deprecation is complete.
- Remove all Xcode project references and build phases that invoke `npm`, `node`, `dist/`, `node_modules`, `Resources/node`, or app bundle Node copy steps.
- Update app packaging so no `Resources/node` directory is produced.
- Update docs to configure Swift stdio MCP only.

Exit gate:

- Clean checkout can build, test, and run the macOS app without `npm install`.
- Packaged app contains no Node runtime resources.
- MCP clients can use the Swift helper only.
- `xcodebuild -showBuildSettings` and final `.app` bundle inspection show no Node copy/build phase or `Resources/node` output.
- README and all MCP config examples use Swift stdio helper paths, not `node dist/index.js`.

## Compatibility and Rollback

Before Stage 5, rollback is to re-enable Node daemon launch and Node MCP examples. Swift service stages should be guarded by an internal setting or build flag until parity gates pass.

After Stage 5, rollback is a git revert of the deletion commit. Do not keep runtime fallback code in the product after cutover; dual implementations are exactly what this project is trying to remove.

Database compatibility rules:

- Swift migrations must be forward-compatible with existing user databases.
- Stage 1 must include migration idempotency tests.
- Any schema changes must be readable by both Node and Swift until Stage 5.
- Stage 5 may remove Node migration code only after Swift migration tests cover upgrade from all retained historical production schemas.
- Every Swift migration commit must update GRDB schema assumptions in the same commit.
- Migration tests must prove repeated runs do not create duplicate rows, constraint violations, or destructive data loss.
- Any destructive migration must be explicitly named in the implementation plan with backup and rollback behavior.
- Until Stage 5, schema changes must be readable by the current Node reference implementation.

## Testing and Verification

Required verification layers:

- Swift unit tests for repositories, migrations, adapters, parser edge cases, and service command serialization.
- Swift MCP executable tests for every public MCP tool.
- Golden fixture tests comparing Node and Swift outputs during migration.
- Dual-run parity tests before deletion, using Node as the reference while only one writer is active at a time.
- UI smoke tests for app launch, popover status, indexing status, settings, and key dashboard reads.
- Packaging test proving the app bundle has no `Resources/node`, `node_modules`, `daemon.js`, `index.js`, or `web.js`.
- Packaging test proving no binary, script, Xcode build phase, or launch path references `EngramCLI` unless a Swift replacement target is intentionally kept.
- CLI documentation check proving README and CLAUDE include a command-by-command replacement/deprecation table before `EngramCLI` or `src/cli/*` deletion.
- Documentation check proving README MCP examples use the Swift helper and no longer require Node for app use.
- Review pass for domain-comment preservation: TypeScript comments that explain non-obvious behavior, including existing Chinese comments, must be preserved as equivalent Swift comments.

During Stages 1-4, npm tests remain part of verification because Node is still the reference implementation. After Stage 5, npm tests are removed or moved to archived reference fixtures; they must not be required for the shipped product.

## Performance Expectations

The main expected performance gains come from removing process hops and bundled Node startup, not from assuming Swift SQL is automatically faster.

Expected wins:

- fewer long-lived app processes;
- lower idle memory by removing Node daemon and Hono HTTP server;
- faster app startup after removing daemon spawn and Node module load;
- less IPC overhead for UI-to-service operations;
- simpler packaging and codesigning.

Performance gates:

- measure cold app launch to service-ready before and after cutover;
- measure cold DB open and migration on a copied fixture database;
- measure idle RSS with app open but not indexing;
- measure initial indexing time on a representative fixture corpus;
- measure incremental indexing latency after one new session file appears;
- measure MCP `search` and `get_context` latency on the contract fixture DB.

Stage 0 must capture the canonical Node baseline before migration work changes the measurement target; Stage 1 and later stages only read and validate that artifact unless an explicitly reviewed baseline-capture defect requires correction. Stage 5 is blocked by these regressions unless a later spec explicitly accepts them:

- cold launch to service-ready greater than 120% of baseline;
- idle RSS greater than baseline by more than 50 MB;
- initial indexing greater than 120% of baseline on the standard fixture corpus;
- incremental indexing greater than 150% of baseline;
- MCP `search` or `get_context` p50 greater than 120% of baseline or p95 greater than 150% of baseline.

The migration is successful if simplification is achieved while staying within these gates. Equal indexing speed is acceptable; measurable regressions past the thresholds block Node deletion.

## Deletion List

Delete or archive after parity gates pass:

- `src/index.ts`
- `src/daemon.ts`
- `src/web.ts`
- TypeScript runtime modules under `src/core/*` that only exist for the app/daemon/MCP backend
- TypeScript MCP tool modules under `src/tools/*`
- TypeScript adapters under `src/adapters/*` after Swift adapter parity is complete
- `src/cli/*.ts` after Swift CLI replacement or documented deprecation is complete
- Node bundle scripts and Xcode build phases that copy `dist/` and `node_modules`
- README and config examples that use `node dist/index.js`
- `macos/Engram/Core/MCPServer.swift`
- `macos/Engram/Core/MCPTools.swift`, specifically the app-local HTTP bridge helper, not the `macos/EngramMCP` stdio implementation
- `macos/EngramCLI` target only after terminal command replacement/deprecation is complete
- `macos/Engram/Core/DaemonClient.swift` after it is replaced by `EngramServiceClient`
- `macos/Engram/Core/IndexerProcess.swift` after its UI-facing state is replaced by Swift service state

Keep:

- `macos/EngramMCP` as the single MCP server.
- A Swift CLI target if terminal workflows are retained.
- SQLite database file format and user data.
- Fixtures generated from the former Node implementation as historical compatibility goldens.
- TypeScript-only development utilities only if they are clearly outside the shipped product and not required for app/MCP runtime.

## Implementation Planning Units

The implementation plan should be split into these independently reviewable units:

1. `EngramCore` database/migration skeleton.
2. SQLite connection policy, FTS/vector rebuild policy, and migration fixtures.
3. Repository parity for read-only dashboard and MCP data.
4. Adapter fixture harness and first source adapter.
5. Remaining source adapters, parent detection, and source-specific sidecars/gRPC.
6. Swift indexer and batch upsert path.
7. Swift service event stream and app integration behind a flag.
8. Swift service IPC transport and single-writer enforcement.
9. Mutating service commands for project/session/memory tools.
10. DaemonClient and CLI replacement mapping.
11. Full MCP golden parity suite and dual-run parity harness.
12. Packaging/docs cutover.
13. Node deletion.

Each unit must leave the repo buildable and testable. No unit should combine "port a subsystem" with "delete the old subsystem"; deletion waits for the final cutover unit.

## Open Risks

- The TypeScript codebase contains broad behavior beyond MCP reads; missing one operational path could create a silent feature regression.
- Some adapters rely on Node filesystem/glob/readline behavior; Swift ports need byte-level fixture coverage for malformed and large files.
- Embeddings and AI summaries depend on provider selection, HTTP behavior, and optional local model/vector infrastructure that must be mapped explicitly.
- `sqlite-vec` currently comes through the Node/npm ecosystem; Swift must vendor/load it or replace it before vector parity is claimed.
- Windsurf/Cascade may require Swift gRPC and Protocol Buffers support.
- File watching behavior differs between Node and Swift; debouncing and duplicate-event handling need real macOS tests.
- Project move/archive operations are high-risk because they mutate user files and AI session history; Swift must preserve dry-run, locking, compensation, recovery, and `projects.json` semantics before Node deletion.
- The current app may have UI assumptions tied to `IndexerProcess` event names; service events need compatibility tests.
- Existing build archives already contain Node resources; cleanup must include generated build outputs and packaging scripts, not just source files.
- Terminal CLI workflows may be real user workflows; deletion requires replacement or explicit deprecation.

## PolyCLI Review Questions

The multi-way review should challenge this spec on:

- Whether the service boundary is enough to avoid multi-writer SQLite corruption.
- Which Node-owned behavior is missing from the migration stages.
- Whether the cutover gates are strong enough to safely delete Node.
- Which parts should be split into separate specs before implementation.
- Whether any deleted path is still needed for current users or developer workflows.
- Whether the performance expectations are measurable and realistic.

## PolyCLI Review Results Incorporated

Review was run through the local polycli companion on 2026-04-23 with these jobs:

- `qwen`: `pa-d3cc2002`, completed with findings.
- `opencode`: `pa-e1bc7fcd`, completed with findings.
- `gemini`: `pa-5f47ad11`, produced findings but the wrapper marked the job failed after a local skill-conflict error.
- `kimi`: `pa-2757251c`, timed out while reading/analyzing the repo and did not produce final findings.
- `minimax`: `pa-9832cf09`, timed out during tool use and did not produce final findings.

Incorporated review changes:

- Strengthened single-writer design: all writes must flow through `EngramService`; mutating MCP must use IPC and fail closed if the shared service is unavailable.
- Split read/write core access conceptually so app/MCP cannot accidentally bypass service serialization.
- Added SQLite WAL and `busy_timeout` requirements.
- Added exhaustive `DaemonClient` to `EngramServiceClient` mapping as a required migration unit.
- Added project move compensation, locking, and `projects.json` parity gates.
- Added adapter malformed/large fixture requirements.
- Added parent-detection, insight reconciliation, FTS/vector rebuild, sqlite-vec, embeddings, AI summary, Windsurf gRPC, and Gemini sidecar requirements.
- Added explicit file watcher semantics and UI event compatibility gates.
- Added Swift CLI replacement/deprecation requirement before deleting Node CLI paths.
- Added historical schema migration gates, dual-run parity, packaging/Xcode build-phase deletion checks, and concrete performance thresholds.
