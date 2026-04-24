# Swift Single Stack Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Node from the shipped Engram app and MCP runtime by replacing Node-owned daemon, MCP, indexing, project operations, and packaging paths with Swift equivalents while preserving full parity.

**Architecture:** Swift becomes the only shipped runtime. `EngramCoreRead` is shared by app and MCP for reads, `EngramCoreWrite` is reachable only by `EngramService`, and every write-capable app/MCP/CLI operation goes through `EngramServiceClient` to a single writer process over real IPC. Node remains only as the reference implementation during migration and is deleted after parity, packaging, clean-checkout, and performance gates pass.

**Tech Stack:** Swift 5.9+, GRDB, SQLite WAL, XcodeGen, macOS app/helper targets, Swift stdio MCP helper, Swift service IPC with Unix-domain socket preferred unless packaging proves XPC safer, existing TypeScript/Node code only as reference during Stages 1-4.

**Source Spec:** `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`

---

## Non-Negotiable Rules

- [ ] No stage may delete Node code before its Swift replacement has fixture parity and an explicit rollback path.
- [ ] No mutating Swift app, MCP, or CLI command may write SQLite directly; it must go through `EngramServiceClient`.
- [ ] `EngramMCP` must fail closed when service IPC is unavailable for mutating tools.
- [ ] `EngramCoreWrite` must not be importable by app UI or MCP targets.
- [ ] All SQLite connections must verify `PRAGMA journal_mode = WAL`; Swift opens must set `PRAGMA busy_timeout = 30000` to match current Node behavior and tests must fail if it reads back below `5000`.
- [ ] `macos/project.yml` is the Xcode project source of truth; modify it first and regenerate `macos/Engram.xcodeproj` with XcodeGen instead of hand-editing generated `.pbxproj` files.
- [ ] Real service IPC is required before any Swift MCP or CLI mutating command is enabled; in-process transport is allowed only for tests and pre-cutover app smoke paths.
- [ ] Write-capable indexing, project-operation, migration, and service-server code must live in `EngramCoreWrite` or service-only targets, never in app/MCP-importable `macos/Shared` source trees.
- [ ] Every stage must leave the repository buildable and testable.
- [ ] Every implementation task must add or update tests before deleting the old implementation.
- [ ] Node tests remain required until the final cutover stage because Node is the reference implementation.
- [ ] The final shipped app must build and run from a clean checkout without `npm install`.

## Verification Command Set

Run the smallest relevant subset while implementing a task, and run the full set at stage gates.

```bash
rtk sh -lc 'cd macos && xcodegen generate'
```

Expected after any `macos/project.yml` change: exits `0` and regenerates Xcode project/schemes.

```bash
rtk npm run lint
```

Expected: exits `0` with Biome reporting no errors.

```bash
rtk npm test
```

Expected before Stage 5: exits `0`; Node reference tests continue to pass.

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
```

Expected: exits `0`; Swift MCP executable tests pass.

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS'
```

Expected: exits `0`; app/unit tests pass.

```bash
rtk rg -n "Resources/node|node_modules|node dist/index.js|dist/index.js|src/index.ts|src/daemon.ts|npm run build|/usr/local/bin/node|/opt/homebrew/bin/node" README.md CLAUDE.md package.json macos scripts docs
```

Expected at final cutover: no shipped runtime or user-facing docs reference Node app/MCP runtime. Historical fixture generator references may remain only if explicitly documented as non-shipped compatibility tooling.

## Canonical Artifacts

- Baseline JSON: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`
- Baseline human log: `docs/swift-single-stack/performance-baseline.md`
- Cutover performance JSON: `docs/performance/swift-single-stack-stage5.json`
- Cutover verification log: `docs/verification/swift-single-stack-cutover.md`

Stage 0 owns creation of the canonical baseline JSON. Later stages may read it, compare against it, or append explicitly named supplemental outputs, but must not recapture or overwrite it under a different meaning. If the checked-in baseline is missing any canonical schema key, Stage 1 must fail and return to Stage 0 rather than silently adding fields or changing committed numeric values.

The baseline JSON schema must include: `coldAppLaunchToDaemonReadyMs`, `coldDbOpenMs`, `idleRssMB`, `initialFixtureIndexingMs`, `incrementalIndexingMs`, `mcpSearchP50Ms`, `mcpSearchP95Ms`, `mcpGetContextP50Ms`, `mcpGetContextP95Ms`, `gitCommit`, `macOSVersion`, `cpuArchitecture`, `nodeVersion`, `fixtureDbPath`, `fixtureCorpusPath`, and `iterationCount`. Stage 1 and Stage 5 scripts must refuse to run if any key is missing.

## Code Map

Build-system glossary:

- Source of truth: `macos/project.yml`.
- Generated artifact: `macos/Engram.xcodeproj/project.pbxproj`; inspect it for verification, but do not edit it directly.
- Regeneration command: `cd macos && xcodegen generate`.

Current Node-owned runtime:

- `src/index.ts`: Node stdio MCP server.
- `src/daemon.ts`: Node daemon entrypoint.
- `src/web.ts`: Hono HTTP API currently used by Swift `DaemonClient`.
- `src/core/bootstrap.ts`: Node service bootstrap and long-running loops.
- `src/core/db/*`: schema, repositories, maintenance, sync, FTS, insights, sessions, migrations.
- `src/core/indexer.ts`, `src/core/watcher.ts`, `src/core/index-job-runner.ts`: indexing and file watching.
- `src/core/project-move/*`: project move/archive/undo/recover orchestration and compensation.
- `src/core/parent-detection.ts`, `src/core/session-tier.ts`: parent/subagent detection and backfills.
- `src/core/embeddings.ts`, `src/core/vector-store.ts`, `src/core/ai-client.ts`, `src/core/auto-summary.ts`, `src/core/title-generator.ts`: embeddings, vector, summary/title generation.
- `src/adapters/*`: source adapters.
- `src/tools/*`: Node MCP tool implementations.
- `src/cli/*`: Node terminal CLI.

Current Swift runtime:

- `macos/Engram/App.swift`: app startup, Node daemon launch, old app-local MCP bridge startup.
- `macos/Engram/Core/Database.swift`: GRDB app read/write facade.
- `macos/Engram/Core/IndexerProcess.swift`: launches Node daemon and parses stdout events.
- `macos/Engram/Core/DaemonClient.swift`: HTTP client for `/api/*` daemon endpoints.
- `macos/Engram/Core/MCPServer.swift` and `macos/Engram/Core/MCPTools.swift`: old app-local bridge to delete after Swift stdio MCP is sole path.
- `macos/EngramMCP/Core/*`: Swift stdio MCP helper and current read-oriented DB implementation.
- `macos/EngramCLI/main.swift`: current Swift CLI bridge target to replace or delete intentionally.
- `macos/project.yml`: XcodeGen source of truth; contains target graph and build scripts that must be audited for Node copy/build references.
- `macos/Engram.xcodeproj/project.pbxproj`: generated from `macos/project.yml`; inspect for verification but do not hand-edit.

## Normative Subplans

The following draft plans are normative subplans. A stateless worker implementing a stage must read the matching draft before editing code and preserve its file ownership, test matrix, and acceptance gates.

- `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-core-db.md`: Stage 1 core DB, migrations, WAL policy, schema compatibility, FTS/vector, sqlite-vec.
- `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-adapters-indexing.md`: Stage 2 adapters, parser limits, Node goldens, indexing, watcher semantics, parent detection, startup backfills.
- `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-service-ipc-app.md`: Stage 3 Swift service, real IPC, single-writer gate, app startup/status/UI replacement, AI provider behavior.
- `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-mcp-cli-project-ops.md`: Stage 4 MCP routing, CLI replacement/deprecation, `DaemonClient` mapping, project move/archive/undo/recover compensation.
- `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-cutover-verification.md`: Stage 5 dual-run parity, packaging cleanup, Node deletion, docs cleanup, clean-checkout verification.

## Stage 0: Baseline, Inventory, and Safety Rails

Purpose: make the migration measurable before code starts moving.

Stage 0 is mandatory. Stage 1 cannot start until Stage 0 acceptance passes, because later DB, service, and deletion gates depend on its canonical baseline, inventories, and rollback checklist.

**Detailed task order:**

- [ ] Inventory all Node references with classification: runtime, build-time, reference-only, docs-only, generated artifact.
- [ ] Inventory all current app-side database writes and map each final write path to a service command or explicit removal decision.
- [ ] Create `docs/swift-single-stack/file-disposition.md` as the canonical final-state table for every Node/TypeScript file: `delete`, `archive fixture`, `keep non-shipped dev tool`, or `replace with Swift`.
- [ ] Use `macos/project.yml` as the build-system source; inspect generated Xcode project only to verify no generated Node phase remains after regeneration.
- [ ] Capture the current Node-backed performance baseline before Swift changes into `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`: cold app launch to daemon-ready, cold DB open, idle RSS, fixture indexing, incremental indexing, MCP `search`, and MCP `get_context`.
- [ ] Create stage gates from the design spec so deletion cannot start until DB, adapter, service IPC, MCP/CLI/project ops, packaging, performance, and clean-checkout gates are checked off.
- [ ] Record rollback points: Node reference remains intact through Stage 4, Swift service can be disabled before Stage 5, and project-operation mutations require dry-run plus compensation tests before live writes.

**Stage 0 acceptance:**

- [ ] `docs/swift-single-stack/inventory.md` lists every `node`, `npm`, `dist`, `node_modules`, `Resources/node`, `daemon.js`, `dist/index.js`, `src/index.ts`, and `src/daemon.ts` reference with final action.
- [ ] `docs/swift-single-stack/file-disposition.md` resolves every `keep as non-shipped dev tool` versus `archive fixture` decision so later stages do not classify the same file differently.
- [ ] `docs/swift-single-stack/app-write-inventory.md` lists every current `DatabaseManager` write, raw GRDB write, app-side `DatabasePool(path:)`, and existing write-capable app/MCP code path with a final service-command mapping or removal decision.
- [ ] `docs/performance/baselines/2026-04-23-node-runtime-baseline.json` contains every key from the canonical baseline schema, and `docs/swift-single-stack/performance-baseline.md` links to it with raw command output and machine/date metadata.
- [ ] `scripts/perf/capture-node-baseline.ts` and `scripts/measure-swift-single-stack-baseline.sh` exist and can be rerun without changing the checked-in baseline unless explicitly requested.
- [ ] `docs/swift-single-stack/stage-gates.md` has one checkbox per spec exit gate and exact verification commands.

### Task 0.1: Capture Runtime Inventory

**Files:**
- Create: `docs/swift-single-stack/inventory.md`
- Create: `docs/swift-single-stack/file-disposition.md`
- Read: `README.md`
- Read: `CLAUDE.md`
- Read: `package.json`
- Read: `macos/project.yml`
- Read for verification only: `macos/Engram.xcodeproj/project.pbxproj`
- Read: `macos/Engram/App.swift`
- Read: `macos/Engram/Core/DaemonClient.swift`
- Read: `src/web.ts`
- Read: `src/index.ts`
- Read: `src/daemon.ts`

- [ ] List every shipped Node entrypoint, Xcode Node build phase, app bundle Node resource, MCP config example, CLI entrypoint, and Swift app callsite that references Node.
- [ ] Record whether each item is runtime, build-time, reference-only, docs-only, or generated artifact.
- [ ] Mark each item with one final action: `replace with Swift`, `delete`, `archive fixture`, or `keep non-shipped dev tool`.
- [ ] Add the same final action to `docs/swift-single-stack/file-disposition.md`; later stages must update this file instead of inventing a second disposition list.
- [ ] Run: `rtk rg -n "node|npm|dist/|node_modules|Resources/node|daemon.js|dist/index.js|src/index.ts|src/daemon.ts" README.md CLAUDE.md package.json macos scripts docs`
- [ ] Paste the command output into `docs/swift-single-stack/inventory.md` under "Initial Node References".

**Acceptance:**
- A stateless worker can open `docs/swift-single-stack/inventory.md` and know every Node reference that must be handled before final cutover.
- No deletion is performed in this task.

### Task 0.2: Capture Performance Baselines

**Files:**
- Create: `docs/swift-single-stack/performance-baseline.md`
- Create: `scripts/perf/capture-node-baseline.ts`
- Create: `scripts/measure-swift-single-stack-baseline.sh`

- [ ] Add a shell script that records cold app launch to daemon/service-ready, cold DB open, idle RSS, initial fixture indexing time, incremental indexing latency, MCP `search` latency, and MCP `get_context` latency.
- [ ] Add the Node baseline capture script and make the shell script call it for canonical JSON output. The script must support read-only comparison mode and must refuse to overwrite an existing canonical baseline unless passed an explicit `--force-baseline-update` flag for a reviewed Stage 0 defect.
- [ ] Use the current Node-backed app as the baseline target.
- [ ] Store raw command output and machine/date metadata in `docs/swift-single-stack/performance-baseline.md`.
- [ ] Run the script once and commit the measured baseline JSON at `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`.

**Acceptance:**
- Stage 5 can compare against concrete numbers instead of subjective "not slower" claims.
- Stage 5 is blocked if thresholds from the spec are exceeded.

### Task 0.3: Create Stage Gate Checklist

**Files:**
- Create: `docs/swift-single-stack/stage-gates.md`
- Read: `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`

- [ ] Convert every spec exit gate into a checkbox.
- [ ] Add the exact verification commands for each gate.
- [ ] Add owner notes for Node-reference gates that disappear only after Stage 5.

**Acceptance:**
- The migration has one checklist that prevents accidental Node deletion before parity is proven.

### Task 0.4: Inventory App-Side Writes

**Files:**
- Create: `docs/swift-single-stack/app-write-inventory.md`
- Read: `macos/Engram/Core/Database.swift`
- Read: `macos/Engram`
- Read: `macos/Shared`
- Read: `macos/EngramMCP`
- Read: `macos/EngramCLI`

- [ ] Search for current write-capable code: `writerPool`, `.write {`, `DatabasePool(path:)`, raw GRDB DML (`insert`, `update`, `delete`, `execute(sql:)`), and current `DatabaseManager` mutation methods.
- [ ] For each app/UI write, record the owner view/model, current SQL or repository method, final `EngramServiceClient` command, expected response DTO, and Stage 3 or Stage 4 replacement task.
- [ ] Mark removed workflows explicitly as `removed` with the user-facing doc section that will explain the removal.
- [ ] Add a source-scan gate to `docs/swift-single-stack/stage-gates.md` so new app/MCP direct writes cannot be introduced during the migration.

**Acceptance:**
- Stage 1 cannot be accepted unless this inventory exists and every current app-side write has a service-command mapping or removal decision.
- Stage 3 cannot cut the app over to Swift service unless the scan gate proves no production app/MCP target imports or instantiates write-capable database code.

## Stage 1: Swift Core, SQLite Policy, and Migrations

Purpose: establish Swift-owned database foundations while Node remains the source of truth.

**Primary draft:** `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-core-db.md`

**Detailed task order:**

- [ ] Verify the Stage 0 canonical Node runtime baseline exists before changing Swift DB behavior; do not recapture or overwrite `docs/performance/baselines/2026-04-23-node-runtime-baseline.json` in Stage 1 except to fix an explicitly reviewed baseline-capture defect.
- [ ] Verify `docs/swift-single-stack/app-write-inventory.md` exists and has a final service-command mapping or removal decision for every current app-side write.
- [ ] Modify `macos/project.yml` to add `EngramCoreRead`, `EngramCoreWrite`, and `EngramCoreTests`; regenerate with `cd macos && xcodegen generate`.
- [ ] Create `macos/EngramCoreRead/Database/EngramDatabaseReader.swift`, `SQLiteConnectionPolicy.swift`, `Schema/SchemaManifest.swift`, `Schema/SchemaIntrospection.swift`, `Repositories/SessionReadRepository.swift`, `Repositories/MetadataReadRepository.swift`, and `Models/DatabaseRecords.swift`.
- [ ] Create `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`, `EngramMigrationRunner.swift`, `EngramMigrations.swift`, `FTSRebuildPolicy.swift`, `VectorRebuildPolicy.swift`, `SQLiteVecSupport.swift`, and `SchemaCompatibilityVerifier.swift`.
- [ ] Add `macos/EngramCoreTests/Database/ModuleBoundaryTests.swift` that reads `macos/project.yml` and fails if `Engram` or `EngramMCP` depends on `EngramCoreWrite`, or if app/MCP sources import `EngramCoreWrite`.
- [ ] Match Node SQLite policy from `src/core/db/database.ts`: write opens enable WAL, `busy_timeout = 30000`, `foreign_keys = ON`; read opens verify WAL and set `busy_timeout = 30000`; typed errors are required for WAL/busy-timeout failures.
- [ ] Port the base schema manifest from Node into Swift constants and add schema introspection tests that compare tables, indexes, triggers, metadata keys, and current schema version against a Node-generated artifact from `scripts/db/emit-current-schema.ts`.
- [ ] Implement Swift migrations for empty DB creation and retained historical upgrades; add historical fixtures under `tests/fixtures/db/historical/` for minimal sessions, current Node schema, partial metadata, old FTS version, and vector-dimension mismatch.
- [ ] Add `scripts/db/check-swift-schema-compat.ts` so a Swift-created/migrated DB can be opened by the current TypeScript database reference during Stages 1-4.
- [ ] Port FTS version policy from Node (`FTS_VERSION = '3'`) so version mismatch clears/rebuilds FTS state and resets dependent metadata in the same observable way.
- [ ] Record sqlite-vec strategy in `docs/superpowers/decisions/2026-04-23-swift-sqlite-vec.md`; preferred implementation vendors a macOS-compatible sqlite-vec dynamic library under `macos/Vendor/sqlite-vec/` and proves `vec_version()` or an equivalent capability probe works.
- [ ] Block semantic-vector parity claims unless Swift either loads sqlite-vec and creates compatible `vec0` tables (`vec_sessions`, `vec_chunks`, `vec_insights`) or documents and tests an approved replacement/rebuild path.
- [ ] Replace app/MCP database opens with read facades only after boundary and policy tests pass; do not expose write APIs outside the future service writer.

**Stage 1 acceptance:**

- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS'` passes.
- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'` passes after MCP read-facade adoption.
- [ ] `npm test` passes because Node remains the reference.
- [ ] `scripts/db/check-swift-schema-compat.ts` confirms Node can read a Swift-created/current DB.
- [ ] WAL, `busy_timeout = 30000`, `foreign_keys = ON`, migration idempotency, historical upgrades, FTS rebuild triggers, and vector strategy are covered by Swift tests.
- [ ] `docs/swift-single-stack/app-write-inventory.md` is complete, and module-boundary tests fail if `Engram`, `EngramMCP`, or app-importable `macos/Shared` code imports `EngramCoreWrite`.

### Task 1.1: Define Core Module Boundaries

**Files:**
- Modify: `macos/project.yml`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`
- Create: `macos/EngramCoreRead/Database/EngramDatabaseReader.swift`
- Create: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`
- Test: `macos/EngramCoreTests/Database/ModuleBoundaryTests.swift`

- [ ] Add separate `EngramCoreRead` and `EngramCoreWrite` Swift targets in `macos/project.yml`.
- [ ] Define `EngramCoreRead` as the public app/MCP readable surface.
- [ ] Define `EngramCoreWrite` as service-only API surface.
- [ ] Add boundary tests that fail if app/MCP targets depend on or import `EngramCoreWrite`.
- [ ] Do not move existing `DatabaseManager` behavior yet; introduce the boundary first.

**Acceptance:**
- Read/write boundaries are explicit before any write code is ported.
- App and MCP cannot accidentally adopt direct write APIs as the migration grows.

### Task 1.2: Enforce SQLite Open Policy

**Files:**
- Create: `macos/EngramCoreRead/Database/SQLiteConnectionPolicy.swift`
- Modify: `macos/EngramCoreRead/Database/EngramDatabaseReader.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`
- Modify: `macos/Engram/Core/Database.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Test: `macos/EngramCoreTests/Database/SQLiteConnectionPolicyTests.swift`
- Test: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`

- [ ] Centralize GRDB configuration so all Swift SQLite connections verify WAL mode and set `busy_timeout = 30000`.
- [ ] Replace duplicate open logic in app and MCP with the shared policy where possible.
- [ ] Add tests that open a temporary database and assert `PRAGMA journal_mode`, `PRAGMA busy_timeout`, and `PRAGMA foreign_keys`.
- [ ] Add a regression test that a read connection does not create an ad hoc writer.

**Acceptance:**
- Every Swift SQLite entrypoint has the same connection policy.
- The single-writer design has a database-level safety baseline before service migration starts.

### Task 1.3: Port Migration Runner Skeleton

**Files:**
- Create: `macos/EngramCoreWrite/Database/EngramMigrationRunner.swift`
- Create: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Create: `macos/EngramCoreRead/Database/Schema/SchemaManifest.swift`
- Test: `macos/EngramCoreTests/Database/MigrationRunnerTests.swift`
- Test: `macos/EngramCoreTests/Database/HistoricalSchemaFixtureTests.swift`
- Fixture: `tests/fixtures/db/historical/*.sqlite`
- Reference: `src/core/db/migration.ts`

- [ ] Implement a Swift migration runner that can create an empty database at the current schema.
- [ ] Add historical fixture databases for empty, current Node, partial metadata, old FTS version, and vector-dimension mismatch states.
- [ ] Test empty DB migration, fully migrated DB idempotency, and partial/historical upgrade.
- [ ] Add a test that running the migration twice does not duplicate rows or violate constraints.
- [ ] Keep Node migration code untouched.

**Acceptance:**
- Swift can own schema creation and upgrade without deleting Node migration code.
- Historical user DB upgrade risk is covered before Stage 5.

### Task 1.4: Port FTS and Vector Rebuild Policy

**Files:**
- Create: `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift`
- Create: `macos/EngramCoreWrite/Database/VectorRebuildPolicy.swift`
- Create: `macos/EngramCoreWrite/Database/SQLiteVecSupport.swift`
- Create: `docs/superpowers/decisions/2026-04-23-swift-sqlite-vec.md`
- Test: `macos/EngramCoreTests/Database/FTSRebuildPolicyTests.swift`
- Test: `macos/EngramCoreTests/Database/VectorRebuildPolicyTests.swift`
- Reference: `src/core/db/fts-repo.ts`
- Reference: `src/core/vector-store.ts`
- Reference: `src/core/embeddings.ts`

- [ ] Document whether Swift will vendor/load `sqlite-vec` or replace it with another vector strategy.
- [ ] Port version/dimension/model-change detection as policy objects before implementing full vector indexing.
- [ ] Add tests proving an FTS version bump schedules a full FTS rebuild.
- [ ] Add tests proving embedding model or dimension changes schedule vector table rebuild.

**Acceptance:**
- Search rebuild behavior is planned and testable before adapters/indexing start depending on it.

## Stage 2: Adapters, Parser Fixtures, and Indexing Parity

Purpose: make Swift able to parse and index every supported source with fixture parity.

Stage 2 is blocked until Stage 1 acceptance passes, including `SchemaManifest`, metadata keys such as parent detection version, read/write module boundaries, and sqlite-vec strategy decision.

**Primary draft:** `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-adapters-indexing.md`

**Detailed task order:**

- [ ] Generate Node reference adapter goldens before Swift adapter changes with `scripts/gen-adapter-parity-fixtures.ts`; cover success and failure outputs for every source.
- [ ] Define shared Swift adapter contracts in `macos/Shared/EngramCore/Adapters/`: `SessionAdapter.swift`, `AdapterRegistry.swift`, `ParserLimits.swift`, `StreamingLineReader.swift`, and `JSONValue.swift`.
- [ ] Model parser failure categories exactly: `fileMissing`, `fileTooLarge`, `invalidUtf8`, `truncatedJSON`, `truncatedJSONL`, `malformedJSON`, `malformedToolCall`, `messageLimitExceeded`, `lineTooLarge`, `fileModifiedDuringParse`, `sqliteUnreadable`, `grpcUnavailable`, and `unsupportedVirtualLocator`.
- [ ] Enforce parser limits through tests: max file size, max line size, max messages, invalid UTF-8, truncated JSON/JSONL, malformed tool calls, file mutation during parse, and watcher retry after stabilization.
- [ ] Port JSONL filesystem adapters first: Codex, Claude Code, iFlow, Qwen, and Copilot.
- [ ] Port whole-file and multi-file adapters next: Gemini CLI, Kimi, Cline, and VS Code; Gemini must include `.engram.json` sidecar parent-link fixtures.
- [ ] Port SQLite and virtual-locator adapters: OpenCode and Cursor, with unreadable SQLite and unsupported locator failure fixtures.
- [ ] Port Antigravity and Windsurf cache adapters, preserving source-specific session IDs, timestamps, token usage, tool calls, and project/CWD mapping.
- [ ] For Antigravity, include live Cascade `.pb` directory scanning for trajectories not returned by recent `GetAllCascadeTrajectories` responses, so older conversations are not silently missed.
- [ ] Implement Cascade/Windsurf strategy in `macos/Shared/EngramCore/Adapters/Cascade/CascadeClient.swift` and `CascadeDiscovery.swift`; use ConnectRPC JSON first, gate live tests with `ENGRAM_LIVE_CASCADE_TEST=1`, and add generated SwiftProtobuf/gRPC only if JSON parity cannot cover live data.
- [ ] Port parent detection into `ParentDetection.swift` with the current detection version, dispatch patterns, temporal decay, CWD classification, scoring, sidecar links, orphan handling, stale reset, Codex originator backfill, and suggested-parent reconciliation.
- [ ] Port parsing/orchestration pieces in app/MCP-safe code: `SwiftIndexer.swift`, `SessionTier.swift`, `ParentDetection.swift`, and read-only/test fixture helpers. Stage 2 write-capable indexing pieces such as `SessionSnapshotWriter.swift` and `SessionBatchUpsert.swift` must live in `EngramCoreWrite`; Stage 3 service server/orchestrator code lives in `EngramService`. Stage 2 parity may use test-only `IndexingWriteSink` doubles that are compiled only into test targets and cannot survive in production targets.
- [ ] Preserve batch behavior with distinct limits: watcher path drain may coalesce up to `500` changed paths, while DB transaction writes use the Node-derived session batch size captured in `tests/fixtures/adapter-parity/batch-sizes.json` and defaulting to `100` unless that fixture records a different current Node value.
- [ ] Add explicit non-watchable source rescan parity: define the source set, 10-minute interval, `rescan` event payload, and post-rescan recoverable index-job trigger.
- [ ] Implement startup backfill ordering and events so UI-compatible events remain deterministic for subagent tier downgrade, parent link backfill, stale detection reset, Codex originator backfill, suggested parent backfill, FTS/vector rebuild scheduling, and watcher start.
- [ ] Implement watcher semantics in `SessionWatcher.swift` and `WatchPathRules.swift`: watch the same roots as `src/core/watcher.ts`, prefer FSEvents, do not follow symlinks, use 2s write stability, 500ms polling where needed, max changed-path drain size 500, skip project-move temp roots, and ignore `.gemini/tmp/<proj>/tool-outputs/`, `.vite-temp/`, `.engram-tmp-`, `.engram-move-tmp-`, `node_modules`, and `.DS_Store`.
- [ ] Add watcher tests for debounce interval, duplicate-event suppression, rename handling, directory rename handling, symlink target changes, permission revocation, unlink orphan hook, rapid append/delete cycles, and project-move skip semantics.
- [ ] Wire Swift adapters into the current UI parser only after adapter fixture parity and watcher/indexer tests pass.

**Stage 2 acceptance:**

- [ ] `scripts/check-adapter-parity-fixtures.ts` passes against Node goldens and Swift output.
- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests` passes.
- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/IndexerParityTests` passes.
- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ParentDetectionParityTests` passes.
- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/WatcherSemanticsTests` passes.
- [ ] Every supported source has success, malformed, deep-nesting, and large/limit fixtures; no adapter is complete without Node-vs-Swift normalized output comparison.
- [ ] No Stage 2 test-only `IndexingWriteSink` double is compiled into `Engram`, `EngramMCP`, `EngramCLI`, or `EngramService`; production indexing writes only through `EngramCoreWrite` or later service-owned code.

### Task 2.1: Build Adapter Fixture Harness

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/SessionSourceAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/NormalizedSessionSnapshot.swift`
- Create: `macos/EngramTests/AdapterFixtureHarnessTests.swift`
- Create: `tests/fixtures/adapters/`
- Reference: `src/adapters/types.ts`

- [ ] Define a Swift normalized snapshot model matching the Node adapter output.
- [ ] Add fixture loader helpers that can compare Swift JSON output to Node-generated expected JSON.
- [ ] Include success and failure fixture structure for each source.
- [ ] Add malformed fixture classes: invalid UTF-8, truncated JSON/JSONL, deeply nested records, malformed tool args, file mutation during parse, large file marker, and 10k-message marker.

**Acceptance:**
- New adapter ports all use the same parity harness.
- Failure classification is part of parity, not an afterthought.

### Task 2.2: Port First Adapter End-to-End

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`
- Test: `macos/EngramTests/CodexAdapterParityTests.swift`
- Reference: `src/adapters/codex.ts`
- Reference: `macos/Engram/Core/StreamingJSONLReader.swift`

- [ ] Write failing parity tests from controlled Codex fixtures.
- [ ] Port only enough adapter behavior to satisfy those fixtures.
- [ ] Add malformed fixture tests for Codex.
- [ ] Compare normalized Swift output to Node-generated expected output.

**Acceptance:**
- One adapter demonstrates the full TDD porting pattern for remaining adapters.

### Task 2.3: Port Remaining Adapters in Batches

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/Sources/<Source>Adapter.swift`
- Test: `macos/EngramTests/<Source>AdapterParityTests.swift`
- Reference: `src/adapters/*.ts`
- Reference: `src/adapters/grpc/cascade-client.ts`

- [ ] Batch 1: Claude Code, Gemini CLI, OpenCode.
- [ ] Batch 2: Qwen, Kimi, iFlow, Cline.
- [ ] Batch 3: Cursor, VS Code, Windsurf/Cascade, Antigravity, Copilot.
- [ ] For Windsurf/Cascade, decide and document Swift gRPC/protobuf strategy before porting.
- [ ] For Gemini, include `.engram.json` sidecar parent-link fixture tests.

**Acceptance:**
- Each adapter has success and malformed fixture parity.
- No adapter is marked complete without Node-vs-Swift expected output comparison.

### Task 2.4: Port Parent Detection and Backfills

**Files:**
- Create: `macos/Shared/EngramCore/Indexing/ParentDetection.swift`
- Create: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Test: `macos/EngramTests/ParentDetectionParityTests.swift`
- Reference: `src/core/parent-detection.ts`
- Reference: `src/core/session-tier.ts`
- Reference: `src/core/db/maintenance.ts`

- [ ] Port dispatch patterns, temporal decay, CWD classification, scoring, and orphan handling.
- [ ] Port startup backfills: subagent tier downgrade, parent link backfill, stale detection reset, Codex originator backfill, suggested parent backfill.
- [ ] Add fixtures for sidecar parent links, heuristic scoring, orphan cascade, and stale detection reset.

**Acceptance:**
- Parent/subagent behavior does not regress when Swift indexer replaces Node indexer.

## Stage 3: Swift Service, IPC, and App Integration

Purpose: replace the Node daemon's long-running behavior without exposing Swift mutating MCP yet.

**Primary draft:** `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-service-ipc-app.md`

**Detailed task order:**

- [ ] Create the exhaustive `docs/swift-single-stack/daemon-client-map.md` before DTO/UI replacement. Stage 3 owns app/UI endpoint mapping; Stage 4 extends and locks it for MCP/CLI/project ops.
- [ ] Define the service contract before runtime code in app/MCP-safe shared files only: `EngramServiceProtocol.swift`, `EngramServiceClient.swift`, `EngramServiceModels.swift`, `EngramServiceError.swift`, `EngramServiceTransport.swift`, and `MockEngramServiceClient.swift`.
- [ ] Keep service server, writer gate, background jobs, and project-operation writer code out of app/MCP-importable `macos/Shared`; place them under `macos/EngramService` or explicit service-only/write targets.
- [ ] Preserve current JSON field names and response shapes from `macos/Engram/Core/DaemonClient.swift`, `macos/Shared/Networking/DaemonHTTPClientCore.swift`, and `src/web.ts`; use `CodingKeys` for snake_case/lowerCamel differences.
- [ ] Cover every former daemon capability in typed DTOs: live sessions, source info, skills, memory, hooks, hygiene, lint, handoff, replay timeline, parent link/suggestion management, project migrations, project CWDs, project move/archive/undo, search, embedding status, summary generation, title regenerate-all, sync trigger, resume command, save insight, link sessions, and log forwarding.
- [ ] Implement real IPC before mutating cutover: `macos/EngramService/IPC/UnixSocketServiceServer.swift` plus shared request/response envelopes. XPC is allowed only if documented packaging constraints require it.
- [ ] Add `ServiceWriterGate.swift` so all write-capable commands execute serially through one `EngramDatabaseWriter`; tests must prove two clients cannot create parallel write authorities.
- [ ] Add service-unavailable behavior: missing socket/helper returns typed service error; MCP/CLI never fall back to local SQLite writes.
- [ ] Add `EngramService` target to `macos/project.yml`, regenerate with XcodeGen, and ensure the `Engram` scheme builds/copies the helper without removing Node packaging until Stage 5 gates.
- [ ] Implement service lifecycle in `macos/EngramService/Core/EngramService.swift`: startup scan, watcher/rescan loop, maintenance timers, event broker, background jobs, and graceful shutdown.
- [ ] Emit UI-compatible events: `ready`, `indexed`, `rescan`, `sync_complete`, `watcher_indexed`, `summary_generated`, `error`, `warning`, `wal_checkpoint`, `ai_audit`, `usage`, and `alert`.
- [ ] Move daemon background jobs behind explicit service timers: initial scan, watcher changes, non-watchable source rescans, recoverable index jobs, sync, usage collection, health checks, git probe, log/metrics retention, WAL checkpoint, auto-summary, and title regeneration.
- [ ] Preserve AI behavior in Swift providers: `SummaryProvider.swift`, `TitleProvider.swift`, and `EmbeddingProvider.swift`; do not silently replace Node `transformers` behavior unless a native Swift implementation with fixtures exists.
- [ ] Replace app startup in `macos/Engram/App.swift` so `AppDelegate` owns Swift service state, `EngramServiceStatusStore`, and `EngramServiceClient`, not `IndexerProcess`, `DaemonClient`, or app-local `MCPServer`.
- [ ] Replace UI environment injection in views currently using `@Environment(DaemonClient.self)`, `IndexerProcess`, or raw `http://127.0.0.1` `/api/*` URLs: `HygieneView.swift`, `SourcePulseView.swift`, `SkillsView.swift`, `MemoryView.swift`, `HooksView.swift`, `ProjectsView.swift`, `SessionsPageView.swift`, `TimelinePageView.swift`, and `HomeView.swift`.
- [ ] Keep `DaemonClient.swift` and `DaemonHTTPClientCore.swift` only as migration compatibility shims until scans prove production UI no longer uses them.
- [ ] Add source-scan tests that fail on second-writer app code after service cutover: `writerPool`, app-side `.write {`, app-side `DatabasePool(path:)`, raw GRDB DML in `macos/Engram`, app/MCP imports of `EngramCoreWrite`, and new generic daemon access (`DaemonClient.fetch<`, `DaemonClient.post<`, `postRaw`, raw `delete`, `ENGRAM_MCP_DAEMON_BASE_URL`, `http://127.0.0.1`, `localhost:`).
- [ ] Add the same writer/daemon scan as a plain `rg` command in the repo pre-commit hook or lint-staged config during Stage 3, so new daemon/write regressions fail before CI.
- [ ] Update settings copy so Node path and daemon HTTP settings are not presented as the primary runtime once the service path is enabled; MCP config guidance must point to Swift stdio helper and service IPC.
- [ ] Remove Node runtime from app flow only after parity gates show app launch, status, search, project views, session detail, replay, live badge, and settings flows are service-backed.

**Stage 3 acceptance:**

- [ ] `xcodegen generate --spec macos/project.yml` passes after target changes.
- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS'` passes.
- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'` passes with mutating tools still Node-backed or fail-closed.
- [ ] Real IPC gate passes: a standalone `EngramService` process accepts two concurrent client connections through the chosen production transport and serializes their write commands through one writer authority. Stage 4 cannot start until this gate passes.
- [ ] `rg "IndexerProcess|DaemonClient|DaemonHTTPClientCore|nodejsPath|nodeJsPath|daemon\\.js|MCPServer\\(|writerPool|DatabasePool\\(path:|\\.write \\{|fetch<|postRaw|post<|ENGRAM_MCP_DAEMON_BASE_URL|http://127\\.0\\.0\\.1|localhost:" macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI --glob '!macos/Engram/Core/DaemonClient.swift' --glob '!macos/Shared/Networking/DaemonHTTPClientCore.swift'` returns no production app dependency, new generic daemon caller, or second-writer path after service cutover. Stage 4 owns deleting the two compatibility shim files after call-site scans pass.
- [ ] App launches without `node daemon.js`, without app-local `MCPServer`, and without raw daemon HTTP in production code.

### Task 3.1: Introduce Service Types and Event Model

**Files:**
- Create: `macos/EngramService/EngramService.swift`
- Create: `macos/EngramService/EngramServiceEvent.swift`
- Create: `macos/EngramService/EngramServiceStatus.swift`
- Create: `macos/EngramService/EngramServiceClient.swift`
- Test: `macos/EngramTests/EngramServiceEventTests.swift`
- Reference: `macos/Engram/Core/IndexerProcess.swift`

- [ ] Define event/status models covering every current `DaemonEvent` field used by UI.
- [ ] Add conversion tests from fixture daemon JSON events into Swift service events.
- [ ] Keep `IndexerProcess` in place until UI parity is proven.

**Acceptance:**
- UI-facing status can be driven by Swift service without losing fields.

### Task 3.2: Implement In-App Service Smoke Path

**Files:**
- Modify: `macos/Engram/App.swift`
- Modify: `macos/Engram/Core/AppEnvironment.swift`
- Create: `macos/EngramTests/EngramServiceSmokeTests.swift`

- [ ] Add an internal setting/build flag to run Swift service instead of Node daemon in development/test.
- [ ] Ensure mutating MCP tools remain on Node or fail closed at this point.
- [ ] Smoke test app startup with Node daemon disabled and Swift service enabled.

**Acceptance:**
- The app can run a Swift service path before any Node deletion.

### Task 3.3: Add Real IPC Transport Before Mutating Cutover

**Files:**
- Create: `macos/EngramService/IPC/EngramServiceTransport.swift`
- Create: `macos/EngramService/IPC/UnixSocketEngramServiceTransport.swift` or `macos/EngramService/IPC/XPCEngramServiceTransport.swift`
- Test: `macos/EngramTests/EngramServiceIPCTests.swift`

- [ ] Pick XPC or Unix-domain socket based on launch ownership and packaging constraints.
- [ ] Implement request/response envelope types for service commands.
- [ ] Add a test proving two clients submit write commands that are serialized by one writer authority.
- [ ] Add a test proving a missing IPC endpoint returns service-unavailable, not local write fallback.

**Acceptance:**
- Stage 4 can safely route mutating MCP/CLI commands to one shared writer.

## Stage 4: MCP, CLI, DaemonClient Replacement, and Project Ops

Purpose: move operational and mutating behavior to Swift service commands.

**Primary draft:** `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-mcp-cli-project-ops.md`

**Detailed task order:**

- [ ] Consume and complete `docs/swift-single-stack/daemon-client-map.md` from Stage 3, adding every MCP/CLI/project-ops capability and every non-API daemon URL such as `/health`; implement a typed `EngramServiceClient` method or explicit deletion decision for each.
- [ ] Delete generic app affordances from final code: no final `DaemonClient.fetch<T>`, `post<T>`, `postRaw`, raw `delete`, raw `/api/*`, `http://127.0.0.1`, `localhost`, `ENGRAM_MCP_DAEMON_BASE_URL`, daemon port, or hidden Node endpoint strings in production.
- [ ] Add `macos/EngramTests/EngramServiceClientMappingTests.swift` and `DaemonClientRemovalTests.swift` that scan app/shared source and fail on unmapped daemon HTTP usage.
- [ ] Route these MCP tools through service because they write, mutate files, use live service state, or run long operations: `generate_summary`, `save_insight`, `manage_project_alias` add/remove, `link_sessions`, `export`, `handoff`, `lint_config`, `live_sessions`, `project_move`, `project_archive`, `project_undo`, `project_move_batch`, `project_recover`, and `project_review`.
- [ ] Keep these MCP tools directly `EngramCoreRead` backed only if they remain pure read-only: `list_sessions`, `get_session`, `search`, `get_memory`, `get_costs`, `get_insights`, `stats`, `tool_analytics`, `file_activity`, `project_timeline`, `project_list_migrations`, and `manage_project_alias` list. For read-after-write flows such as `save_insight` followed by `get_memory`/`get_insights`, the service write acknowledgement must refresh or invalidate reader pools before direct reads are considered current; otherwise mark those reads service-backed too.
- [ ] Split `get_context`: `include_environment=false` is a pure read-only mode that uses `EngramCoreRead`, does not contact the service, and omits live environment fields rather than pretending they are degraded. Default `include_environment=true` must use service or hybrid service data for live monitor, alerts, health checks, and config lint. If the service is unavailable, `include_environment=true` returns typed service-unavailable JSON and performs no partial local fallback; if the service is reachable but a sub-provider fails, return `environment.status = "degraded"` with `environment.warnings[]` and cover the shape with `tests/fixtures/mcp-golden/get_context.engram.degraded.json`.
- [ ] Add MCP fail-closed tests: when service IPC is unavailable, every service-backed MCP tool returns typed service-unavailable JSON and performs no local SQLite or filesystem mutation.
- [ ] Preserve Node MCP JSON response shape until deletion by expanding `tests/fixtures/mcp-golden/*.json` and `scripts/gen-mcp-contract-fixtures.ts`; dual-run parity must compare Swift stdio MCP with Node stdio MCP on the same fixture DB.
- [ ] Port project operations into service-only `macos/EngramService/ProjectMove/`: `ProjectMoveOrchestrator.swift`, `ProjectMoveFileOps.swift`, `ProjectMoveSources.swift`, `ProjectMoveJSONPatcher.swift`, `GeminiProjectsJSON.swift`, `ProjectMoveArchive.swift`, `ProjectMoveBatch.swift`, `ProjectMoveLock.swift`, `ProjectMoveRecovery.swift`, `ProjectMoveErrors.swift`, and `ProjectMoveFailureInjection.swift`.
- [ ] Project move/archive/undo/recover parity must preserve dry-run planning, file locking, git dirty checks, CJK and English archive category aliases, source-directory encoders, JSON/JSONL path patching, `~/.gemini/projects.json` plan/apply/reverse, migration log state transitions, stale undo checks, recovery diagnostics, and alias creation/removal behavior.
- [ ] Add failure-injection tests for project move/archive/undo/batch/recover at these points: after lock acquisition, after `startMigration`, after physical move, after cross-volume copy succeeds but source delete fails, after first per-source directory rename, after Gemini `projects.json` apply, after Gemini `projects.json` apply but before Gemini tmp directory rename, after JSON/JSONL patch, `InvalidUtf8Error`, concurrent modification, after `markMigrationFsDone` before DB commit, during DB apply, reverse patch compensation failure, source-dir restore failure, physical move-back failure, archive category collision, undo stale overlay, batch archive dry-run directory side-effect, batch stop-on-error, batch continue mode, recover pending filesystem state, and recover committed/stale state.
- [ ] For every project-operation failure injection, assert the exact restored or reported state: filesystem hashes, migration rows, aliases, session `cwd` values, source directories, `projects.json`, lock files, and structured recovery recommendation.
- [ ] Add process-interruption tests for project operations: SIGINT/SIGTERM/crash after lock acquisition, after `startMigration`, after physical move, and after `markMigrationFsDone`; recovery must report lock stale state, migration state, and safe next action.
- [ ] Port session linking, suggestions, export, handoff, timeline, lint, hygiene, and live sessions into service-backed Swift flows where they depend on adapters, filesystem, health checks, or background service state.
- [ ] Replace app `DaemonClient` with `EngramServiceClient`: introduce a temporary compatibility facade for one transition commit only, replace every `@Environment(DaemonClient.self)`, then delete `DaemonClient.swift` and `DaemonHTTPClientCore.swift` once scan tests pass.
- [ ] Replace or deprecate Node CLI commands with Swift ArgumentParser commands in `macos/EngramCLI/main.swift`; retained write-capable commands use `EngramServiceClient`, retained read-only commands use `EngramCoreRead`, and removed workflows must be documented in `docs/swift-single-stack/cli-replacement-table.md`, README, and CLAUDE before Stage 4.4 merges.
- [ ] Required Swift CLI coverage includes service status, list/get/search/context read flows, project move/archive/undo/review/recover/batch, link sessions, export, handoff, lint config, live sessions, generate summary, save insight, and any retained resume/title/sync commands.
- [ ] Add Node MCP/runtime deletion readiness gates before Stage 5: no production `DaemonClient`, no production daemon HTTP, no Node MCP config default, no app-local MCP bridge, and no `Bundle Node.js Daemon` dependency left in active runtime paths.

**Stage 4 acceptance:**

- [ ] `EngramServiceClient` has typed methods for every former daemon capability retained by app, MCP, or CLI.
- [ ] `EngramMCP` is the only shipped MCP server path, and all mutating/operational MCP tools use service IPC.
- [ ] `DaemonClient.swift` and `DaemonHTTPClientCore.swift` have no production callers and are deleted before final cutover.
- [ ] Project operations pass happy-path parity and mandatory failure-injection compensation tests.
- [ ] Swift CLI either replaces each Node CLI workflow or documents intentional deprecation before `src/cli/*` deletion.
- [ ] `docs/swift-single-stack/cli-replacement-table.md`, README, and CLAUDE include a command-by-command CLI replacement/deprecation table before any `EngramCLI` target or `src/cli/*` deletion.
- [ ] `rg 'DaemonClient|DaemonHTTPClientCore|ENGRAM_MCP_DAEMON_BASE_URL|/tmp/engram.sock|node dist/index\\.js|dist/cli|Bundle Node.js Daemon|Resources/node' macos README.md docs --glob '!docs/archive/**'` returns only explicit parity-fixture or historical references.

### Task 4.1: Create DaemonClient-to-ServiceClient Map

**Files:**
- Create: `docs/swift-single-stack/daemon-client-map.md`
- Modify: `macos/EngramService/EngramServiceClient.swift`
- Reference: `macos/Engram/Core/DaemonClient.swift`
- Reference: `src/web.ts`

- [ ] Enumerate every `DaemonClient` method.
- [ ] Enumerate every `/api/*` endpoint used by the app.
- [ ] Mark each as `service command`, `read repository`, `MCP/CLI command`, or `deleted with documented deprecation`.
- [ ] Add typed Swift response models for retained commands.

**Acceptance:**
- There is no vague "replace DaemonClient later" gap.

### Task 4.2: Port Project Move, Archive, Undo, Recover

**Files:**
- Create: `macos/EngramService/ProjectOps/ProjectMoveService.swift`
- Create: `macos/EngramService/ProjectOps/ProjectMoveLock.swift`
- Create: `macos/EngramService/ProjectOps/GeminiProjectsJSON.swift`
- Test: `macos/EngramTests/ProjectMoveServiceTests.swift`
- Reference: `src/core/project-move/*`

- [ ] Port dry-run planning before real mutation.
- [ ] Port file locking.
- [ ] Port git dirty checks.
- [ ] Port source directory rename planning.
- [ ] Port JSONL patch planning and reversal.
- [ ] Port `~/.gemini/projects.json` planning, apply, and reverse.
- [ ] Add failure injection for each step and verify compensation restores filesystem and DB state.

**Acceptance:**
- Project operations are at least as safe as Node before Node project tools are removed.

### Task 4.3: Route Swift MCP Mutations Through Service

**Files:**
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Create: `macos/EngramMCP/Core/MCPServiceClient.swift`
- Test: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Reference: `src/index.ts`
- Reference: `src/tools/*.ts`

- [ ] Expand golden tests for every public MCP tool.
- [ ] Route mutating and long-running tools through `EngramServiceClient`.
- [ ] Add fail-closed tests for missing service IPC.
- [ ] Preserve JSON response shape parity with Node MCP until deletion.

**Acceptance:**
- Swift stdio MCP can replace Node stdio MCP without creating an independent writer.

### Task 4.4: Replace or Deprecate CLI Workflows

**Files:**
- Modify or delete intentionally: `macos/EngramCLI/main.swift`
- Create: `macos/EngramCLITests/EngramCLITests.swift`
- Reference: `src/cli/*.ts`
- Docs: `README.md`
- Docs: `docs/swift-single-stack/cli-replacement-table.md`

- [ ] Inventory current CLI commands.
- [ ] Decide per command: Swift CLI replacement, MCP replacement, app UI replacement, or documented deprecation.
- [ ] Create `docs/swift-single-stack/cli-replacement-table.md` and link it from README and CLAUDE before this task is marked complete.
- [ ] Route retained write-capable commands through `EngramServiceClient`.
- [ ] Add tests for retained CLI commands independent of MCP stdio.

**Acceptance:**
- Node CLI deletion does not silently remove workflows.

## Stage 5: Cutover, Packaging, and Node Deletion

Purpose: remove Node only after parity is proven.

**Primary draft:** `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-cutover-verification.md`

**Detailed task order:**

- [ ] Freeze Node reference artifacts before deletion: MCP goldens, adapter goldens, project-operation fixtures, schema artifacts, and performance baseline outputs. After this point, Node is a historical reference artifact, not a shipped runtime.
- [ ] Add `scripts/run-mcp-dual-parity.sh`, `scripts/run-service-dual-parity.sh`, `scripts/measure-swift-cutover-performance.sh`, and `scripts/verify-swift-only-cutover.sh`.
- [ ] Add `docs/performance/swift-single-stack-stage5.json` recording cold launch/service-ready time, idle RSS, initial indexing time, incremental indexing latency, MCP `search`, MCP `get_context`, and comparison to `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`.
- [ ] Add `docs/verification/swift-single-stack-cutover.md` recording parity runs, grep gates, app bundle inspection, clean-checkout command output, retained historical references, and every accepted deletion.
- [ ] Add `scripts/verify-clean-checkout-no-npm.sh` that clones/checks out the current branch into a temporary directory, skips `npm install`, runs XcodeGen/Xcode build/test for Swift targets, launches the app with temporary `ENGRAM_HOME`, and runs Swift MCP `initialize` plus `tools/list`.
- [ ] Run `scripts/run-mcp-dual-parity.sh`, `scripts/run-service-dual-parity.sh`, `scripts/measure-swift-cutover-performance.sh`, and `scripts/verify-clean-checkout-no-npm.sh`; deletion cannot begin until all four pass against the frozen artifacts.
- [ ] Create a deletion checkpoint branch or commit marker after parity/performance gates pass and before removing Node files; rollback during Stage 5 is a git revert to this checkpoint, not an ad hoc partial file restore.
- [ ] Remove Xcode Node packaging only through `macos/project.yml`: remove the `Bundle Node.js Daemon` prebuild script, remove `macos/scripts/build-node-bundle.sh` references, remove `Resources/node`, and regenerate `macos/Engram.xcodeproj` with XcodeGen.
- [ ] Remove app runtime Node launch and old app-local MCP bridge: delete `IndexerProcess`, `DaemonClient`, `DaemonHTTPClientCore`, `MCPServer`, and `MCPTools` only after no Swift production source references them.
- [ ] Update Settings UI, onboarding copy, README, CLAUDE, and MCP config examples so the Swift stdio MCP helper and Swift service are the only app/MCP runtime paths.
- [ ] Convert or archive Node fixture tooling: keep only deterministic compatibility fixture generators explicitly documented as non-shipped dev tools; remove runtime dependencies such as `@hono/node-server`, `hono`, `@modelcontextprotocol/sdk`, `better-sqlite3`, `chokidar`, `sqlite-vec`, and `openai` unless an archived script explicitly needs them.
- [ ] Run dual-run parity gates before deleting Node source: MCP output parity, service command parity, indexing row-count/checksum parity, adapter normalized-output parity, project-operation dry-run/compensation parity, and UI event count/state parity.
- [ ] Delete Node runtime in small dependency-ordered groups only after gates pass: `src/index.ts`, `src/daemon.ts`, `src/web.ts`, `src/tools/*`, `src/adapters/*`, app/daemon/MCP-only `src/core/*`, and `src/cli/*` when Swift replacement/deprecation is complete.
- [ ] Update `package.json` only after Node source deletion: remove shipped runtime `main`/`bin` entries and Node runtime scripts; retain or move fixture-generation scripts under an explicit archived/dev-tools namespace if still needed.
- [ ] Add swift-only grep gates covering shipped runtime files and user-facing shipped docs: `README.md`, `CLAUDE.md`, `package.json`, `package-lock.json`, `biome.json`, `.github/workflows`, root `scripts/`, `macos/project.yml`, `macos/Engram`, `macos/EngramMCP`, `macos/Shared`, `macos/scripts`, and generated Xcode project for `build-node-bundle`, `node-bundle.stamp`, `Bundle Node.js Daemon`, `Resources/node`, `node_modules`, `npm run build`, `dist/index.js`, `src/index.ts`, `src/daemon.ts`, `nodejsPath`, `nodeJsPath`, `daemon.js`, `MCPServer(`, `DaemonClient`, and raw daemon HTTP URLs. Do not include `docs/superpowers/**` in shipped-runtime no-reference gates; historical planning docs may mention Node when explicitly labeled non-runtime.
- [ ] Verify the freshly built app bundle from a dedicated `-derivedDataPath` contains no `Contents/Resources/node`, no `daemon.js`, no `dist`, no `node_modules`, no Node MCP server, and no app-local MCP HTTP bridge.
- [ ] Perform clean-checkout verification in a temporary directory from the current branch without copying `node_modules`, `dist`, DerivedData, or local build artifacts; build, test, launch the app with a temporary `ENGRAM_HOME`, assert Swift service-ready, and run Swift MCP stdio `initialize` plus `tools/list` from scratch without `npm install`.
- [ ] Run README command audit from the clean checkout and record which documented setup commands still work without Node.

**Stage 5 acceptance:**

- [ ] `scripts/run-mcp-dual-parity.sh` and `scripts/run-service-dual-parity.sh` pass before Node deletion begins.
- [ ] `scripts/measure-swift-cutover-performance.sh` exits `0` only when Swift meets the spec thresholds; any threshold failure blocks deletion.
- [ ] `scripts/verify-swift-only-cutover.sh` passes after deletion.
- [ ] `xcodegen generate --spec macos/project.yml` passes.
- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS'` passes.
- [ ] `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'` passes.
- [ ] Clean checkout builds, tests, launches the macOS app, reaches Swift service-ready, and runs Swift MCP helper `initialize`/`tools/list` without `npm install`.
- [ ] Swift stdio MCP is the only MCP server path; the app does not start `MCPServer`, `MCPTools`, `DaemonClient`, `IndexerProcess`, `node`, or `daemon.js`.
- [ ] User-facing docs no longer instruct installing Node for Engram app/MCP runtime.

### Task 5.1: Dual-Run Parity Gate

**Files:**
- Create: `scripts/verify-swift-node-parity.sh`
- Create: `docs/swift-single-stack/parity-results.md`
- Test fixtures: `tests/fixtures/mcp-contract.sqlite`
- Test fixtures: `tests/fixtures/mcp-golden/*`

- [ ] Run Node and Swift reference paths in controlled parity mode.
- [ ] Ensure only one writer is active at a time.
- [ ] Compare MCP outputs, indexing counts, event counts, and row checksums.
- [ ] Record results and failures.

**Acceptance:**
- Zero unexplained divergence before Stage 5 deletion starts.

### Task 5.2: Remove Node Packaging and Build Phases

**Files:**
- Modify: `macos/project.yml`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`
- Remove or archive: Node bundle scripts
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] Remove Xcode build phases invoking `npm`, `node`, `dist`, `node_modules`, or `Resources/node`.
- [ ] Remove app startup references to `nodejsPath`, bundled `daemon.js`, and `Resources/node`.
- [ ] Update docs so MCP examples use the Swift helper only.
- [ ] Run final grep gate for Node shipped-runtime references.

**Acceptance:**
- A clean app build produces no `Contents/Resources/node`.
- User-facing docs no longer install/configure Node for Engram app/MCP runtime.

### Task 5.3: Delete Node Runtime Code

**Files:**
- Delete only after `scripts/run-mcp-dual-parity.sh`, `scripts/run-service-dual-parity.sh`, `scripts/measure-swift-cutover-performance.sh`, and clean-checkout preflight pass: `src/index.ts`
- Delete only after `scripts/run-mcp-dual-parity.sh`, `scripts/run-service-dual-parity.sh`, `scripts/measure-swift-cutover-performance.sh`, and clean-checkout preflight pass: `src/daemon.ts`
- Delete only after `scripts/run-mcp-dual-parity.sh`, `scripts/run-service-dual-parity.sh`, `scripts/measure-swift-cutover-performance.sh`, and clean-checkout preflight pass: `src/web.ts`
- Delete only after `scripts/run-mcp-dual-parity.sh`, `scripts/run-service-dual-parity.sh`, `scripts/measure-swift-cutover-performance.sh`, and clean-checkout preflight pass: `src/tools/*`
- Delete only after `scripts/run-mcp-dual-parity.sh`, `scripts/run-service-dual-parity.sh`, `scripts/measure-swift-cutover-performance.sh`, and clean-checkout preflight pass: `src/adapters/*`
- Delete only after `scripts/run-mcp-dual-parity.sh`, `scripts/run-service-dual-parity.sh`, `scripts/measure-swift-cutover-performance.sh`, and clean-checkout preflight pass: `src/core/*` runtime modules that are app/daemon/MCP-only
- Delete only after Swift CLI replacement/deprecation is documented and `scripts/run-service-dual-parity.sh` plus clean-checkout preflight pass: `src/cli/*`
- Delete only after scan tests prove no production source references them and `scripts/verify-swift-only-cutover.sh` exists: `macos/Engram/Core/MCPServer.swift`
- Delete only after scan tests prove no production source references them and `scripts/verify-swift-only-cutover.sh` exists: `macos/Engram/Core/MCPTools.swift`
- Delete only after `EngramServiceClient` mapping tests cover every retained endpoint and `scripts/verify-swift-only-cutover.sh` exists: `macos/Engram/Core/DaemonClient.swift`
- Delete only after app launch and service-ready tests pass without Node and `scripts/verify-swift-only-cutover.sh` exists: `macos/Engram/Core/IndexerProcess.swift`

- [ ] Delete in small commits grouped by dependency graph.
- [ ] After each deletion group, run `scripts/verify-swift-only-cutover.sh`, build and test Swift targets, and record the result in `docs/verification/swift-single-stack-cutover.md`.
- [ ] Keep Node-generated golden fixtures as historical compatibility data only if not required for shipped runtime.
- [ ] Remove npm tests from final shipped-runtime verification only after Node source deletion is complete.

**Acceptance:**
- Clean checkout builds and runs the macOS app without `npm install`.
- Swift MCP is the only MCP server path.
- No duplicate MCP bridge remains.
