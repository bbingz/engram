# Swift Single Stack Stage 0/1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` before implementing this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Goal

Freeze the canonical Node baseline and establish the Swift core database foundation without changing product behavior or deleting Node runtime code.

**Architecture:** Stage 0 creates the immutable evidence package that later stages depend on: runtime inventory, file disposition, app write inventory, DB/fixture inventory, Node behavior snapshots, runtime scripts, stage gates, and performance baseline. Stage 1 then validates that baseline in read-only mode, creates read/write Swift core boundaries, and proves Swift can read and migrate the existing SQLite schema while Node remains the reference implementation.

**Tech Stack:** Swift 5.9+, GRDB, SQLite WAL, XcodeGen, XCTest, TypeScript/Node 20 reference harness, Vitest, `rtk`, `tsx`, macOS app and Swift stdio MCP targets.

**Source Spec:** `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`

**Parent Plan:** `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md`

**Stage 1 DB Draft:** `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-core-db.md`

---

## Review-locked corrections

These corrections override any later wording in this document:

- `--compare-only` must be read-only for every committed input artifact, not only the baseline JSON. It must run DB open, migration, indexing, and MCP measurements against temporary copies of fixture DBs and fixture corpora, then verify checksums for `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`, `tests/fixtures/mcp-contract.sqlite`, and every committed fixture file it reads.
- Baseline validation must reject non-numeric, non-finite, zero, negative, or string metric values. It must verify `iterationCount` equals the CLI argument, p95 values are greater than or equal to matching p50 values, `gitCommit` is non-empty, and `fixtureDbPath` / `fixtureCorpusPath` exist.
- Swift FTS mismatch handling must match Node observable behavior from `src/core/db/migration.ts`: clear `sessions_fts`, set `sessions.size_bytes = 0`, delete `session_embeddings` when present, delete `vec_sessions` when present, and set `metadata.fts_version = "3"`. Do not clear `session_chunks` or `vec_chunks` as part of FTS policy unless a separate reviewed Node parity fixture proves Node does so.
- Base schema compatibility and lazy vector schema compatibility are separate gates. Node base migration emission must not be forced to include vector tables created lazily by `src/core/vector-store.ts`; a separate vector-store fixture must cover lazy `vec0` tables after the Node vector store initializes them.
- Module-boundary checks must include `EngramCLI` as well as app and MCP targets. Direct-write scans must also catch raw GRDB write paths under app, MCP, CLI, and app/MCP-importable shared code.
- Baseline capture must use deterministic fixture paths created or verified by Stage 0 before capture begins. Do not point to `tests/fixtures/mcp-contract.sqlite` unless this stage has already created/validated it; otherwise record the exact canonical fixture DB and corpus paths in `docs/swift-single-stack/performance-baseline.md` and reuse those same paths for compare-only.
- The capture script may use separate metric iteration counts internally. `iterationCount` records the requested default, while launch/indexing metrics may record lower per-metric sample counts in metadata to avoid misleading cold-start p95 values from warmed caches.

## Scope

This plan covers only Stage 0 and Stage 1.

Stage 0 must create a mandatory frozen baseline before Swift DB behavior changes:

- Canonical performance baseline at `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`.
- Runtime inventory for Node, npm, bundled resources, daemon entrypoints, MCP paths, CLI paths, docs references, generated Xcode references, runtime scripts, DB schema/seeds/export fixtures, and Node behavior snapshots.
- File disposition table for every Node/TypeScript path.
- App write inventory mapping each current app/MCP write to a future `EngramServiceClient` command or explicit removal decision.
- Stage gate checklist with exact verification commands and rollback points.

Stage 1 may only create Swift read/write core foundations and validation harnesses:

- `EngramCoreRead`, `EngramCoreWrite`, and `EngramCoreTests` targets.
- SQLite open policy with WAL, `busy_timeout = 30000`, and `foreign_keys = ON`.
- Schema manifest and introspection against the Node reference.
- Swift migration runner for empty, current, partial, and historical schemas.
- FTS rebuild policy matching Node `FTS_VERSION = "3"`.
- Vector rebuild strategy and sqlite-vec decision record.
- Node/Swift schema compatibility harness.
- Read-only baseline validation using `--compare-only`.

Out of scope for this plan:

- Adapter ports.
- Indexer and watcher replacement.
- Swift service IPC.
- Mutating MCP or CLI tool cutover.
- Project move/archive/undo Swift implementation.
- App daemon replacement.
- Node deletion.
- Packaging cleanup.

## Prerequisites

- [ ] Read `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`.
- [ ] Read `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md`.
- [ ] Read `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-core-db.md`.
- [ ] Read `docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-implementation-index.md`.
- [ ] Confirm the working tree does not contain unrelated edits to files this plan will touch. Do not revert unrelated edits.
- [ ] Use `macos/project.yml` as the Xcode project source of truth. Regenerate `macos/Engram.xcodeproj/project.pbxproj` with XcodeGen after target graph edits; do not hand-edit generated project files.
- [ ] Do not start Stage 1 until every Stage 0 acceptance gate in this document passes.

## Files To Create Or Modify

Stage 0 files:

- Create: `docs/swift-single-stack/inventory.md`
- Create: `docs/swift-single-stack/file-disposition.md`
- Create: `docs/swift-single-stack/app-write-inventory.md`
- Create: `docs/swift-single-stack/baseline-inventory.md`
- Create: `docs/swift-single-stack/node-behavior-snapshots.md`
- Create: `docs/swift-single-stack/performance-baseline.md`
- Create: `docs/swift-single-stack/stage-gates.md`
- Create: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`
- Create: `scripts/perf/capture-node-baseline.ts`
- Create: `scripts/measure-swift-single-stack-baseline.sh`

Stage 1 files:

- Modify: `macos/project.yml`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`
- Create: `macos/EngramCoreRead/Database/EngramDatabaseReader.swift`
- Create: `macos/EngramCoreRead/Database/SQLiteConnectionPolicy.swift`
- Create: `macos/EngramCoreRead/Database/Schema/SchemaManifest.swift`
- Create: `macos/EngramCoreRead/Database/Schema/SchemaIntrospection.swift`
- Create: `macos/EngramCoreRead/Repositories/SessionReadRepository.swift`
- Create: `macos/EngramCoreRead/Repositories/MetadataReadRepository.swift`
- Create: `macos/EngramCoreRead/Models/DatabaseRecords.swift`
- Create: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`
- Create: `macos/EngramCoreWrite/Database/EngramMigrationRunner.swift`
- Create: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Create: `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift`
- Create: `macos/EngramCoreWrite/Database/VectorRebuildPolicy.swift`
- Create: `macos/EngramCoreWrite/Database/SQLiteVecSupport.swift`
- Create: `macos/EngramCoreWrite/Database/SchemaCompatibilityVerifier.swift`
- Create: `macos/EngramCoreTests/Database/ModuleBoundaryTests.swift`
- Create: `macos/EngramCoreTests/Database/SQLiteConnectionPolicyTests.swift`
- Create: `macos/EngramCoreTests/Database/MigrationRunnerTests.swift`
- Create: `macos/EngramCoreTests/Database/HistoricalSchemaFixtureTests.swift`
- Create: `macos/EngramCoreTests/Database/FTSRebuildPolicyTests.swift`
- Create: `macos/EngramCoreTests/Database/VectorRebuildPolicyTests.swift`
- Create: `macos/EngramCoreTests/Database/SchemaCompatibilityTests.swift`
- Create: `scripts/check-swift-module-boundaries.sh`
- Create: `scripts/db/emit-current-schema.ts`
- Create: `scripts/db/check-swift-schema-compat.ts`
- Create: `tests/fixtures/db/historical/README.md`
- Create: `tests/fixtures/db/historical/v0-minimal-sessions.sql`
- Create: `tests/fixtures/db/historical/v1-current-node.sql`
- Create: `tests/fixtures/db/historical/v1-partial-metadata.sql`
- Create: `tests/fixtures/db/historical/v1-old-fts-version.sql`
- Create: `tests/fixtures/db/historical/v1-vector-dimension-mismatch.sql`
- Create: `docs/superpowers/decisions/2026-04-23-swift-sqlite-vec.md`

Stage 1 may modify app/MCP database facades only after core boundary and policy tests pass:

- Modify: `macos/Engram/Core/Database.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramTests/DatabaseManagerTests.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`

Files that must not be deleted or rewritten in Stage 0/1:

- `src/index.ts`
- `src/daemon.ts`
- `src/web.ts`
- `src/core/db/*.ts`
- `src/core/vector-store.ts`
- `src/tools/search.ts`
- `src/tools/get_context.ts`
- `macos/Engram/Core/DaemonClient.swift`
- `macos/Engram/Core/IndexerProcess.swift`
- `macos/Engram/Core/MCPServer.swift`
- `macos/Engram/Core/MCPTools.swift`

## Phased Tasks

### Phase 0.1: Freeze Runtime And Reference Inventory

**Purpose:** Make every Node/runtime reference visible before any Swift foundation work starts.

**Files:**

- Create: `docs/swift-single-stack/inventory.md`
- Create: `docs/swift-single-stack/file-disposition.md`
- Create: `docs/swift-single-stack/baseline-inventory.md`
- Read: `README.md`
- Read: `CLAUDE.md`
- Read: `package.json`
- Read: `macos/project.yml`
- Read for verification only: `macos/Engram.xcodeproj/project.pbxproj`
- Read: `macos/Engram/App.swift`
- Read: `macos/Engram/Core/DaemonClient.swift`
- Read: `macos/Engram/Core/IndexerProcess.swift`
- Read: `macos/Engram/Core/MCPServer.swift`
- Read: `macos/Engram/Core/MCPTools.swift`
- Read: `macos/EngramMCP`
- Read: `macos/EngramCLI`
- Read: `src`
- Read: `scripts`
- Read: `tests/fixtures`
- Read: `test-fixtures`

- [ ] Create `docs/swift-single-stack/inventory.md` with sections named `Runtime References`, `Build References`, `MCP References`, `CLI References`, `Docs References`, `Generated Xcode References`, `Runtime Scripts`, `DB Schema Seeds Export Fixtures`, and `Node Behavior Snapshots`.
- [ ] Create `docs/swift-single-stack/file-disposition.md` with one row for every file under `src/`, every Node-related script under `scripts/`, every fixture generator, every package/build config file, and every app bundle Node reference. Columns: `path`, `kind`, `ships in product`, `current owner`, `final action`, `replacement owner`, `stage`, `verification command`.
- [ ] Use only these `final action` values in `file-disposition.md`: `delete`, `archive fixture`, `keep non-shipped dev tool`, `replace with Swift`.
- [ ] Create `docs/swift-single-stack/baseline-inventory.md` with these required sections: `DB schema fixtures`, `DB seed fixtures`, `DB export fixtures`, `Node behavior snapshots`, `runtime scripts`, `app write inventory`, `performance baseline`.
- [ ] Run:

```bash
rtk rg -n "node|npm|dist/|node_modules|Resources/node|daemon.js|dist/index.js|src/index.ts|src/daemon.ts" README.md CLAUDE.md package.json macos scripts docs
```

Expected: exits `0` if references are found, or exits `1` only when no references are found. In Stage 0, references are expected. Copy the full output into `docs/swift-single-stack/inventory.md` under `Initial Node Reference Scan`.

Failure handling: if the command errors for missing paths, correct the path list to existing repo paths and rerun. Do not delete references to make the scan cleaner.

- [ ] Run:

```bash
rtk rg --files src scripts macos docs tests test-fixtures
```

Expected: exits `0` and prints the file list used to build `file-disposition.md`.

Failure handling: if a listed root is absent, record the absent root in `docs/swift-single-stack/inventory.md` and continue with existing roots.

- [ ] Run:

```bash
rtk rg -n "src/core/db|mcp-contract|generate:mcp-contract|generate:fixtures|export|seed|fixture|sqlite|\\.sqlite" package.json src scripts tests test-fixtures docs
```

Expected: exits `0` when fixture, schema, seed, export, and SQLite references are present. Copy relevant output into `docs/swift-single-stack/baseline-inventory.md`.

Failure handling: if a class of fixture is missing, record `not present in current repo scan` with the exact scan command and exit code. Do not leave an empty section.

Acceptance:

- [ ] `inventory.md` lists every Node, npm, bundle, daemon, MCP, CLI, docs, generated project, runtime script, DB fixture, seed, export fixture, and behavior snapshot reference found by the scans.
- [ ] `file-disposition.md` has no blank `final action` cells.
- [ ] `baseline-inventory.md` identifies the canonical source of DB schema fixtures, seed fixtures, export fixtures, Node behavior snapshots, runtime scripts, app write inventory, and performance baseline.
- [ ] No source code is changed in Phase 0.1.

### Phase 0.2: Inventory Current App And MCP Writes

**Purpose:** Prevent Stage 1 from accidentally normalizing direct app/MCP writes before the service writer exists.

**Files:**

- Create: `docs/swift-single-stack/app-write-inventory.md`
- Modify: `docs/swift-single-stack/baseline-inventory.md`
- Read: `macos/Engram/Core/Database.swift`
- Read: `macos/Engram`
- Read: `macos/Shared`
- Read: `macos/EngramMCP`
- Read: `macos/EngramCLI`

- [ ] Create `docs/swift-single-stack/app-write-inventory.md` with columns: `path`, `symbol or owner`, `current write mechanism`, `current data touched`, `final service command`, `response DTO`, `stage to replace`, `removal decision`, `verification command`.
- [ ] Run:

```bash
rtk rg -n "writerPool|\\.write\\s*\\{|DatabasePool\\(path:|DatabaseQueue\\(|execute\\(sql:|\\.insert\\(|\\.update\\(|\\.delete\\(|DELETE FROM|UPDATE [A-Za-z_]+|INSERT INTO" macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI
```

Expected: exits `0` and prints current write-capable callsites, or exits `1` if a searched directory has no matches. Stage 0 expects matches in the app compatibility DB layer.

Failure handling: if the command exits `2` due to invalid regex or missing root, fix the command and rerun. Do not classify a command error as no writes.

- [ ] For each write-capable callsite, classify the future route as one of:

```text
EngramServiceClient.updateSessionLocalState
EngramServiceClient.updateSessionVisibility
EngramServiceClient.updateProjectAlias
EngramServiceClient.saveInsight
EngramServiceClient.linkSessions
EngramServiceClient.confirmSuggestion
EngramServiceClient.deleteSuggestion
EngramServiceClient.runProjectMove
EngramServiceClient.runProjectArchive
EngramServiceClient.runProjectUndo
EngramServiceClient.runProjectRecover
removed with documented user-facing replacement
```

- [ ] If a current write does not match the service command list above, add a concrete command name using `EngramServiceClient.<verbNoun>` and record the response DTO fields required by current UI or MCP callers.
- [ ] Update `docs/swift-single-stack/baseline-inventory.md` section `app write inventory` with a link to `docs/swift-single-stack/app-write-inventory.md` and the scan command.

Acceptance:

- [ ] Every write-capable app/MCP/CLI callsite has a service command mapping or an explicit removal decision.
- [ ] `app-write-inventory.md` has no blank `final service command`, `stage to replace`, or `verification command` cells.
- [ ] Stage 1 workers can decide whether a DB facade change is read-only by checking this inventory.

### Phase 0.3: Implement Baseline Capture Script With Forced Update Semantics

**Purpose:** Create the canonical Node baseline once and make later runs read-only by default.

**Files:**

- Create: `scripts/perf/capture-node-baseline.ts`
- Create: `scripts/measure-swift-single-stack-baseline.sh`
- Create: `docs/swift-single-stack/performance-baseline.md`
- Create: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`

- [ ] Implement `scripts/perf/capture-node-baseline.ts` with these CLI modes:

```text
--out <path>
--compare-only <path>
--force-baseline-update
--fixture-db <path>
--fixture-root <path>
--session-fixture-root <path>
--iterations <number>
--reason <text>
```

- [ ] In `--out` mode, write the output JSON only when the target file does not exist.
- [ ] In `--out` mode with an existing target file, fail non-zero and print `Baseline exists; use --compare-only or --force-baseline-update with --reason`.
- [ ] In `--compare-only` mode, read the target baseline, validate required keys, copy fixture DBs and fixture corpora into a temporary directory, run current measurements only against those copies, print a comparison summary, and never write the baseline file or committed fixture inputs.
- [ ] In `--force-baseline-update` mode, require `--reason`; write the target file only when the reason is non-empty. This mode is for reviewed Stage 0 capture defects, not normal Stage 1 validation.
- [ ] Make the script fail non-zero if any canonical key is missing from either a newly captured baseline or a compared baseline.
- [ ] Make the script fail non-zero if any metric value is `null`, non-numeric, non-finite, zero, negative, or a string; if any p95 value is lower than its matching p50; if `iterationCount` differs from `--iterations`; if `gitCommit` is empty; or if `fixtureDbPath` / `fixtureCorpusPath` do not exist.
- [ ] Record checksums for the baseline JSON, `tests/fixtures/mcp-contract.sqlite`, and all committed fixture files read by measurement before and after `--compare-only`; any checksum change is a script defect.
- [ ] The canonical JSON must include these keys:

```text
coldAppLaunchToDaemonReadyMs
coldDbOpenMs
idleRssMB
initialFixtureIndexingMs
incrementalIndexingMs
mcpSearchP50Ms
mcpSearchP95Ms
mcpGetContextP50Ms
mcpGetContextP95Ms
gitCommit
macOSVersion
cpuArchitecture
nodeVersion
fixtureDbPath
fixtureCorpusPath
iterationCount
capturedAt
captureMode
```

- [ ] Implement `scripts/measure-swift-single-stack-baseline.sh` as a wrapper that builds Node, calls the TypeScript capture script, and records the command line used.
- [ ] Run:

```bash
rtk npm run build
```

Expected: exits `0`; Node reference is built for baseline capture.

Failure handling: fix only build issues owned by the baseline script work. If unrelated Node tests or build files are already broken, record the exact failure in `docs/swift-single-stack/performance-baseline.md` and stop Stage 0 acceptance.

- [ ] Run the initial capture:

```bash
rtk npx tsx scripts/perf/capture-node-baseline.ts \
  --fixture-db tests/fixtures/mcp-contract.sqlite \
  --fixture-root tests/fixtures \
  --session-fixture-root test-fixtures/sessions \
  --iterations 50 \
  --out docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Expected: exits `0`, creates `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`, and prints all canonical metric names.

Failure handling: if the fixture root or fixture DB path does not exist, create or select a deterministic repo-owned fixture path in Stage 0, update `performance-baseline.md` with the exact substituted path, and rerun. Do not generate synthetic metrics and do not use user home data.

- [ ] Run the read-only compare immediately after capture:

```bash
rtk npx tsx scripts/perf/capture-node-baseline.ts \
  --fixture-db tests/fixtures/mcp-contract.sqlite \
  --fixture-root tests/fixtures \
  --session-fixture-root test-fixtures/sessions \
  --iterations 50 \
  --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Expected: exits `0`, prints comparison output, leaves the baseline file checksum unchanged, and leaves committed fixture DB/corpus checksums unchanged.

Failure handling: if checksum changes, fix the script before accepting Stage 0. `--compare-only` must be read-only.

- [ ] Record the raw commands, machine metadata, JSON path, fixture paths, and checksum in `docs/swift-single-stack/performance-baseline.md`.

Acceptance:

- [ ] The baseline JSON exists, contains every canonical key, and passes numeric/range/schema validation.
- [ ] Re-running with `--compare-only` does not alter the baseline file or committed fixture DB/corpus inputs.
- [ ] Re-running with `--out` against an existing baseline fails non-zero.
- [ ] `--force-baseline-update` is the only path that can overwrite the canonical file, and it requires `--reason`.

### Phase 0.4: Capture Node Behavior Snapshots

**Purpose:** Preserve behavior references for DB, MCP, and runtime checks before Swift ports begin.

**Files:**

- Create: `docs/swift-single-stack/node-behavior-snapshots.md`
- Modify: `docs/swift-single-stack/baseline-inventory.md`
- Read: `src/core/db/database.ts`
- Read: `src/core/db/migration.ts`
- Read: `src/core/vector-store.ts`
- Read: `src/tools/search.ts`
- Read: `src/tools/get_context.ts`
- Read: `src/web.ts`
- Read: `tests/fixtures/mcp-contract.sqlite`

- [ ] Create `docs/swift-single-stack/node-behavior-snapshots.md` with sections: `DB open policy`, `Migration side effects`, `FTS version behavior`, `Vector metadata behavior`, `MCP search snapshot`, `MCP get_context snapshot`, `Daemon ready/status snapshot`, `Export fixture behavior`.
- [ ] Run:

```bash
rtk npm test -- tests/core/db-migration.test.ts tests/core/db.test.ts tests/core/vector-store.test.ts tests/tools/search.test.ts tests/tools/get_context.test.ts
```

Expected: exits `0`; these tests are the Stage 0 behavior reference for Stage 1 DB and read behavior.

Failure handling: if tests fail, record exact failing test names and stderr in `node-behavior-snapshots.md`, and do not mark Stage 0 accepted until failures are resolved or classified as pre-existing by the stage owner.

- [ ] Run:

```bash
rtk npx tsx scripts/db/emit-current-schema.ts --out /tmp/engram-node-schema.json
```

Expected: exits `0` only after Phase 1.4 creates the script. Before that script exists, record `pending Stage 1 schema emission script` in `node-behavior-snapshots.md` and rely on the Stage 0 Node tests above.

Failure handling: do not create the schema emission script in Stage 0 unless it is already part of the baseline script work. The Stage 1 task owns this script.

- [ ] Update `baseline-inventory.md` section `Node behavior snapshots` with the Node test command and the snapshot document path.

Acceptance:

- [ ] The behavior snapshot document records exact Node reference commands and outputs used by Stage 1.
- [ ] Missing Stage 1-owned scripts are named as Stage 1-owned, not silently replaced by Stage 0 ad hoc tooling.

### Phase 0.5: Create Stage Gate Checklist

**Purpose:** Make the Stage 0 to Stage 1 boundary explicit and prevent premature deletion later.

**Files:**

- Create: `docs/swift-single-stack/stage-gates.md`
- Read: `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`
- Read: `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md`

- [ ] Create `docs/swift-single-stack/stage-gates.md` with sections `Stage 0`, `Stage 1`, `Stage 2`, `Stage 3`, `Stage 4`, `Stage 5`, `Global abort rules`.
- [ ] Copy every exit gate from the source spec into a checkbox under the matching stage.
- [ ] Add exact verification commands to each gate, not prose-only criteria.
- [ ] Add Stage 0 gate commands:

```bash
rtk sh -lc 'test -f docs/swift-single-stack/inventory.md'
rtk sh -lc 'test -f docs/swift-single-stack/file-disposition.md'
rtk sh -lc 'test -f docs/swift-single-stack/app-write-inventory.md'
rtk sh -lc 'test -f docs/swift-single-stack/baseline-inventory.md'
rtk sh -lc 'test -f docs/swift-single-stack/performance-baseline.md'
rtk sh -lc 'test -f docs/performance/baselines/2026-04-23-node-runtime-baseline.json'
rtk npx tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 50 --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Expected: all commands exit `0`; compare-only leaves the canonical baseline unchanged.

Failure handling: repair the missing Stage 0 artifact. Do not proceed to Stage 1.

- [ ] Add Stage 1 gate commands:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
rtk npm test
rtk npm run lint
rtk npx tsx scripts/db/check-swift-schema-compat.ts --db tests/fixtures/mcp-contract.sqlite
rtk npx tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 50 --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Expected: all commands exit `0`; Node remains the reference and the baseline remains unchanged.

Failure handling: if baseline validation fails because required keys are missing, return to Stage 0. Do not add missing keys during Stage 1.

Acceptance:

- [ ] `stage-gates.md` has concrete commands for every Stage 0 and Stage 1 gate.
- [ ] Later stage gates state that Node deletion is forbidden before Stage 5.

### Phase 1.1: Validate Stage 0 Baseline In Read-Only Mode

**Purpose:** Ensure Stage 1 cannot silently repair or overwrite Stage 0 evidence.

**Files:**

- Read: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`
- Read: `docs/swift-single-stack/performance-baseline.md`
- Read: `docs/swift-single-stack/app-write-inventory.md`
- Read: `scripts/perf/capture-node-baseline.ts`
- Modify only if documenting command output: `docs/swift-single-stack/stage-gates.md`

- [ ] Run:

```bash
rtk sh -lc 'shasum -a 256 docs/performance/baselines/2026-04-23-node-runtime-baseline.json'
```

Expected: exits `0` and prints the baseline checksum.

Failure handling: if the file is missing, stop Stage 1 and return to Stage 0.

- [ ] Run:

```bash
rtk npx tsx scripts/perf/capture-node-baseline.ts \
  --fixture-db tests/fixtures/mcp-contract.sqlite \
  --fixture-root tests/fixtures \
  --session-fixture-root test-fixtures/sessions \
  --iterations 50 \
  --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Expected: exits `0`, validates every canonical key, prints comparison output, and performs no write.

Failure handling: if any canonical key is missing, Stage 1 fails. Do not add the missing key in Stage 1. Record the failure in `stage-gates.md` and return to Stage 0. If the script tries to write in `--compare-only`, fix the script behavior before any Swift DB change.

- [ ] Run:

```bash
rtk sh -lc 'shasum -a 256 docs/performance/baselines/2026-04-23-node-runtime-baseline.json'
```

Expected: checksum matches the checksum from the first command.

Failure handling: restore the baseline from the pre-command version, fix compare-only behavior, and rerun Phase 1.1.

- [ ] Verify `--force-baseline-update` remains explicit:

```bash
rtk npx tsx scripts/perf/capture-node-baseline.ts \
  --fixture-db tests/fixtures/mcp-contract.sqlite \
  --fixture-root tests/fixtures \
  --session-fixture-root test-fixtures/sessions \
  --iterations 1 \
  --out docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Expected: exits non-zero and prints the existing-baseline refusal message.

Failure handling: fix the script before Stage 1 continues.

Acceptance:

- [ ] Stage 1 has proven the canonical baseline exists and is read-only under `--compare-only`.
- [ ] Stage 1 has not changed `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`.
- [ ] `docs/swift-single-stack/app-write-inventory.md` exists and maps every direct write.

### Phase 1.2: Create Swift Core Module Boundaries

**Purpose:** Establish read/write separation before adding migration or write-capable Swift DB code.

**Files:**

- Modify: `macos/project.yml`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`
- Create: `macos/EngramCoreRead/Database/EngramDatabaseReader.swift`
- Create: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`
- Create: `macos/EngramCoreTests/Database/ModuleBoundaryTests.swift`
- Create: `scripts/check-swift-module-boundaries.sh`

- [ ] Add target `EngramCoreRead` in `macos/project.yml` as a macOS framework depending on `GRDB`.
- [ ] Add target `EngramCoreWrite` in `macos/project.yml` as a macOS framework depending on `EngramCoreRead` and `GRDB`.
- [ ] Add target `EngramCoreTests` in `macos/project.yml` depending on `EngramCoreRead` and `EngramCoreWrite`.
- [ ] Do not add `EngramCoreWrite` as a dependency of `Engram`, `EngramMCP`, `EngramCLI`, or app-importable `macos/Shared` code.
- [ ] Add `scripts/check-swift-module-boundaries.sh` that runs `xcodegen dump --spec macos/project.yml --type json`, fails if `Engram`, `EngramMCP`, or `EngramCLI` depends on `EngramCoreWrite`, and fails if source files under `macos/Engram`, `macos/EngramMCP`, `macos/EngramCLI`, or app-importable `macos/Shared` contain `import EngramCoreWrite`.
- [ ] Add `scripts/check-app-mcp-cli-direct-writes.sh` that fails on new app/MCP/CLI/shared raw write paths: `DatabasePool(path:)`, `DatabaseQueue(`, `.write {`, `execute(sql:)`, `.insert(`, `.update(`, `.delete(`, `INSERT INTO`, `UPDATE <table>`, or `DELETE FROM` outside test fixtures and Stage 0 inventory examples.
- [ ] Add `ModuleBoundaryTests.swift` that invokes the boundary script through `Process` and fails on non-zero exit.
- [ ] Run:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
```

Expected: exits `0` and regenerates `macos/Engram.xcodeproj/project.pbxproj`.

Failure handling: fix `macos/project.yml`; do not hand-edit `.pbxproj`.

- [ ] Run:

```bash
rtk sh scripts/check-swift-module-boundaries.sh
```

Expected: exits `0`; output confirms app, MCP, and CLI do not depend on or import `EngramCoreWrite`.

Failure handling: remove illegal target dependencies or imports before continuing.

- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/ModuleBoundaryTests
```

Expected: exits `0`.

Failure handling: fix the target graph or test script; do not weaken the boundary.

Acceptance:

- [ ] `EngramCoreRead` compiles without importing `EngramCoreWrite`.
- [ ] `EngramCoreWrite` imports `EngramCoreRead`.
- [ ] App, MCP, and CLI targets cannot import the write module.
- [ ] Direct-write scan proves Stage 1 introduced no new app/MCP/CLI/shared raw GRDB write path.

### Phase 1.3: Enforce SQLite Connection Policy

**Purpose:** Make all Swift DB opens conform to the Node safety baseline.

**Files:**

- Create: `macos/EngramCoreRead/Database/SQLiteConnectionPolicy.swift`
- Modify: `macos/EngramCoreRead/Database/EngramDatabaseReader.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`
- Create: `macos/EngramCoreTests/Database/SQLiteConnectionPolicyTests.swift`
- Read: `src/core/db/database.ts`
- Read: `macos/Engram/Core/Database.swift`
- Read: `macos/EngramMCP/Core/MCPDatabase.swift`

- [ ] Implement one shared Swift connection policy that sets or verifies:

```text
PRAGMA journal_mode = WAL
PRAGMA busy_timeout = 30000
PRAGMA foreign_keys = ON
```

- [ ] Writer opens must enable WAL and verify the returned journal mode is `wal`.
- [ ] Reader opens must verify the database is already WAL and must not silently convert a non-WAL database as a side effect of a read-only open.
- [ ] Both reader and writer opens must fail with typed policy errors if `busy_timeout` reads back lower than `5000`.
- [ ] Both reader and writer opens must use `DatabasePool`; do not add ad hoc writer `DatabaseQueue` paths.
- [ ] Add tests for writer PRAGMAs, reader PRAGMAs, concurrent reader while writer is open, non-WAL read-only failure, and typed busy-timeout failure.
- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/SQLiteConnectionPolicyTests
```

Expected: exits `0`.

Failure handling: fix policy implementation or tests before adding migrations.

Acceptance:

- [ ] Every new Swift core open path uses `SQLiteConnectionPolicy`.
- [ ] Tests prove WAL, `busy_timeout = 30000`, and `foreign_keys = ON`.
- [ ] Tests fail when the read-back busy timeout is below `5000`.

### Phase 1.4: Port Schema Manifest And Node Schema Emission

**Purpose:** Make Swift schema assumptions explicit and comparable to Node.

**Files:**

- Create: `macos/EngramCoreRead/Database/Schema/SchemaManifest.swift`
- Create: `macos/EngramCoreRead/Database/Schema/SchemaIntrospection.swift`
- Create: `macos/EngramCoreTests/Database/SchemaCompatibilityTests.swift`
- Create: `scripts/db/emit-current-schema.ts`
- Read: `src/core/db/migration.ts`
- Read: `src/core/db/types.ts`
- Read: `src/core/db/session-repo.ts`
- Read: `src/core/db/metrics-repo.ts`
- Read: `src/core/db/migration-log-repo.ts`
- Read: `macos/Engram/Models/Session.swift`
- Read: `macos/Engram/Models/GitRepo.swift`

- [ ] Add Swift constants for `SCHEMA_VERSION = 1` and `FTS_VERSION = "3"`.
- [ ] Add manifest entries for base tables, indexes, triggers, metadata keys, and FTS tables named in the core DB draft.
- [ ] Include at minimum these base tables in the base manifest: `sessions`, `sessions_fts`, `sync_state`, `metadata`, `project_aliases`, `session_local_state`, `session_index_jobs`, `migration_log`, `usage_snapshots`, `git_repos`, `session_costs`, `session_tools`, `session_files`, `logs`, `traces`, `metrics`, `metrics_hourly`, `alerts`, `ai_audit_log`, `insights`, `insights_fts`, `session_embeddings`, `session_chunks`, and `memory_insights`.
- [ ] Add a separate lazy vector manifest for tables created by `src/core/vector-store.ts`: `vec_sessions`, `vec_chunks`, and `vec_insights`.
- [ ] Implement `scripts/db/emit-current-schema.ts` so it opens a temporary database through the current TypeScript database reference and emits deterministic base-schema JSON with tables, columns, indexes, triggers, virtual table declarations, and metadata keys.
- [ ] Implement `scripts/db/emit-current-vector-schema.ts` or an equivalent mode that initializes the Node vector store before emitting lazy vector schema JSON. Do not force lazy vector tables into the base schema dump.
- [ ] Run:

```bash
rtk npx tsx scripts/db/emit-current-schema.ts --out /tmp/engram-node-schema.json
```

Expected: exits `0` and writes deterministic JSON.

Failure handling: fix the script or Node reference import path. Do not hard-code a fabricated schema dump.

- [ ] Run:

```bash
rtk npm test -- tests/core/db-migration.test.ts tests/core/db.test.ts
```

Expected: exits `0`; Node schema behavior remains unchanged.

Failure handling: fix only issues introduced by schema emission work.

- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/SchemaCompatibilityTests
```

Expected: exits `0`.

Failure handling: update the Swift manifest to match Node, or fix introspection if the manifest is correct.

Acceptance:

- [ ] Swift schema manifest covers every required Node table, index, trigger, metadata key, FTS table, and vector table.
- [ ] The Node schema emission script is deterministic.
- [ ] Schema compatibility tests compare Swift assumptions against Node-created schema.

### Phase 1.5: Implement Swift Migration Runner And Historical Fixtures

**Purpose:** Prove Swift can create and upgrade compatible databases without data loss.

**Files:**

- Create: `macos/EngramCoreWrite/Database/EngramMigrationRunner.swift`
- Create: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`
- Create: `macos/EngramCoreTests/Database/MigrationRunnerTests.swift`
- Create: `macos/EngramCoreTests/Database/HistoricalSchemaFixtureTests.swift`
- Create: `tests/fixtures/db/historical/README.md`
- Create: `tests/fixtures/db/historical/v0-minimal-sessions.sql`
- Create: `tests/fixtures/db/historical/v1-current-node.sql`
- Create: `tests/fixtures/db/historical/v1-partial-metadata.sql`
- Create: `tests/fixtures/db/historical/v1-old-fts-version.sql`
- Create: `tests/fixtures/db/historical/v1-vector-dimension-mismatch.sql`
- Read: `src/core/db/migration.ts`
- Read: `tests/core/db-migration.test.ts`

- [ ] Implement an idempotent migration runner that creates a fresh current schema with `metadata.schema_version = "1"`.
- [ ] Preserve Node legacy migrations for existing `sessions` tables and `sync_state.last_sync_session_id`.
- [ ] Do not drop legacy columns in Stage 1.
- [ ] Store historical fixtures as deterministic SQL unless virtual table or extension behavior requires a binary `.sqlite` fixture.
- [ ] In `tests/fixtures/db/historical/README.md`, document for each fixture: fixture name, generation command, source commit, schema version, row-count summary, expected destructive side effects, expected post-migration metadata, vector/FTS state, and Node readability requirement.
- [ ] Add tests for fresh DB creation, minimal historical `sessions` migration, partial metadata migration, current Node schema idempotency, repeated migration runs, row preservation, and read access through `EngramCoreRead`.
- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/MigrationRunnerTests
```

Expected: exits `0`.

Failure handling: fix migrations before adding more fixtures.

- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/HistoricalSchemaFixtureTests
```

Expected: exits `0`.

Failure handling: if a fixture loses user data, fix the migration or explicitly document the destructive behavior with backup and rollback guidance before acceptance.

- [ ] Run:

```bash
rtk npm test -- tests/core/db-migration.test.ts
```

Expected: exits `0`; Node migration reference still passes.

Failure handling: do not change Node migration behavior to match Swift. Swift must match Node during Stage 1.

Acceptance:

- [ ] Swift can create a fresh DB readable by Node.
- [ ] Swift can migrate empty, fully migrated, partially migrated, and historical production-style schema fixtures.
- [ ] Migration is idempotent across at least three consecutive opens.
- [ ] No rows are lost from `sessions`, `session_local_state`, `project_aliases`, `migration_log`, `insights`, `memory_insights`, or `session_costs` unless the test explicitly names the destructive behavior.

### Phase 1.6: Port FTS Version Policy

**Purpose:** Match Node FTS rebuild side effects before adapter/indexer ports depend on them.

**Files:**

- Create: `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Create: `macos/EngramCoreTests/Database/FTSRebuildPolicyTests.swift`
- Read: `src/core/db/migration.ts`
- Read: `src/core/db/fts-repo.ts`
- Read: `tests/fixtures/db/historical/v1-old-fts-version.sql`

- [ ] Implement expected `metadata.fts_version = "3"`.
- [ ] On missing or mismatched FTS version, match Node observable behavior: delete `sessions_fts`, set `sessions.size_bytes = 0`, delete `session_embeddings` when present, delete `vec_sessions` when present, and store `metadata.fts_version = "3"`.
- [ ] Do not clear `session_chunks`, `vec_chunks`, `insights`, or `insights_fts` in Stage 1 FTS policy unless a Node-derived fixture proves the Node reference clears the same data.
- [ ] Do not clear `insights` or `insights_fts` in Stage 1.
- [ ] Add tests for missing FTS version, old FTS version, current FTS version, vector tables absent, vector tables present, and repeated policy runs.
- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/FTSRebuildPolicyTests
```

Expected: exits `0`.

Failure handling: fix Swift policy to match Node side effects. Do not mutate Node tests to accept Swift drift.

- [ ] Run:

```bash
rtk npm test -- tests/core/db.test.ts tests/tools/search.test.ts tests/tools/get_context.test.ts
```

Expected: exits `0`.

Failure handling: Node reference behavior must remain stable.

Acceptance:

- [ ] Swift FTS version behavior is compatible with Node `FTS_VERSION = "3"`.
- [ ] Stage 1 does not silently delete insight text or insight FTS data.

### Phase 1.7: Decide sqlite-vec Strategy And Port Vector Rebuild Policy

**Purpose:** Prevent semantic-vector parity claims without a tested Swift vector strategy.

**Files:**

- Create: `docs/superpowers/decisions/2026-04-23-swift-sqlite-vec.md`
- Create: `macos/EngramCoreWrite/Database/SQLiteVecSupport.swift`
- Create: `macos/EngramCoreWrite/Database/VectorRebuildPolicy.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Create: `macos/EngramCoreTests/Database/VectorRebuildPolicyTests.swift`
- Modify if vendoring is selected: `macos/project.yml`
- Regenerate if `macos/project.yml` changes: `macos/Engram.xcodeproj/project.pbxproj`
- Read: `src/core/vector-store.ts`
- Read: `src/core/embeddings.ts`
- Read: `tests/core/vector-store.test.ts`

- [ ] Write the decision record before vector code depends on it. It must name exactly one active strategy and one rejected alternative.
- [ ] Preferred active strategy: vendor a macOS-compatible sqlite-vec dynamic library under `macos/Vendor/sqlite-vec/` and load it from Swift before any `vec0` table is created or queried.
- [ ] If vendoring is rejected, the active strategy must describe how existing `vec0` data is intentionally rebuilt or replaced without claiming semantic-vector parity.
- [ ] Implement a capability probe using `SELECT vec_version()` or an equivalent sqlite-vec probe when sqlite-vec is available.
- [ ] Implement vector metadata compatibility for `vec_dimension = "768"` and `vec_model`.
- [ ] On dimension mismatch or stored model `__pending_rebuild__`, drop `vec_sessions`, `vec_chunks`, and `vec_insights` when present; delete `session_embeddings` and `session_chunks`; preserve `memory_insights`.
- [ ] Add tests for fresh vector schema, dimension mismatch, model pending rebuild, compatible no-op, sqlite-vec unavailable typed diagnostic, and `memory_insights` preservation.
- [ ] If `macos/project.yml` changes, run:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
```

Expected: exits `0`.

Failure handling: fix target/resource configuration; do not hand-edit `.pbxproj`.

- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/VectorRebuildPolicyTests
```

Expected: exits `0`.

Failure handling: if sqlite-vec cannot be loaded, tests must still fail closed with a typed vector-unavailable diagnostic and the decision record must state that semantic-vector parity is blocked.

- [ ] Run:

```bash
rtk npm test -- tests/core/vector-store.test.ts tests/core/embeddings.test.ts
```

Expected: exits `0`.

Failure handling: Node vector behavior remains the reference.

Acceptance:

- [ ] `docs/superpowers/decisions/2026-04-23-swift-sqlite-vec.md` names one active strategy.
- [ ] Swift either loads sqlite-vec and proves compatible vector tables, or blocks semantic-vector parity with explicit tests and docs.
- [ ] Automatic vector migration never mixes models or dimensions and never deletes text-only curated memory rows.

### Phase 1.8: Add Node/Swift Schema Compatibility Harness

**Purpose:** Prove Swift-created and Swift-migrated databases remain readable by Node through Stage 4.

**Files:**

- Create: `scripts/db/check-swift-schema-compat.ts`
- Create: `macos/EngramCoreWrite/Database/SchemaCompatibilityVerifier.swift`
- Modify: `macos/EngramCoreTests/Database/SchemaCompatibilityTests.swift`
- Read: `src/core/db/database.ts`
- Read: `src/core/db/*.ts`
- Read: `tests/core/db.test.ts`
- Read: `tests/fixtures/mcp-contract.sqlite`

- [ ] Implement `scripts/db/check-swift-schema-compat.ts` with `--db <path>`.
- [ ] The script must open the supplied DB through the current Node database reference.
- [ ] The script must fail if Node migrations throw.
- [ ] The script must run representative reads for session list, metadata, FTS search, stats, costs, project aliases, migration logs, insights fallback, and vector table capability when vector tables are present.
- [ ] The script must print deterministic row counts and metadata values.
- [ ] Add Swift tests that create temporary DBs through the Swift migration runner, call the Node compatibility script through `Process`, and fail on non-zero exit.
- [ ] Add Swift tests that copy `tests/fixtures/mcp-contract.sqlite`, migrate the copy, and run Node compatibility on the copy.
- [ ] Run:

```bash
rtk npx tsx scripts/db/check-swift-schema-compat.ts --db tests/fixtures/mcp-contract.sqlite
```

Expected: exits `0` and prints deterministic summary output.

Failure handling: if Node cannot read an unchanged fixture, stop and repair the harness or fixture path before testing Swift migrations.

- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/SchemaCompatibilityTests
```

Expected: exits `0`.

Failure handling: fix Swift migration compatibility. Do not relax Node compatibility until Stage 5.

- [ ] Run:

```bash
rtk npm test -- tests/core/db.test.ts tests/core/db-migration.test.ts tests/tools/search.test.ts tests/tools/get_context.test.ts
```

Expected: exits `0`.

Failure handling: keep Node tests passing because Node is still the reference.

Acceptance:

- [ ] Node can open every database migrated by the Swift migration runner.
- [ ] Swift can read every retained historical fixture after migration.
- [ ] Schema changes remain forward-compatible with current Node through Stage 4.

### Phase 1.9: Replace App And MCP DB Opens With Read Facades Only

**Purpose:** Let app and Swift MCP use read-only core facades without exposing writes.

**Files:**

- Modify: `macos/project.yml`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`
- Modify: `macos/Engram/Core/Database.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramTests/DatabaseManagerTests.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Read: `docs/swift-single-stack/app-write-inventory.md`

- [ ] Depend `Engram` and `EngramMCP` on `EngramCoreRead` only.
- [ ] Do not depend `Engram`, `EngramMCP`, or app-importable `macos/Shared` on `EngramCoreWrite`.
- [ ] Route read-only app queries through `EngramCoreRead` facades without changing user-visible query results.
- [ ] Route read-only Swift MCP queries through `EngramCoreRead` facades without changing MCP JSON contract outputs.
- [ ] Do not port or enable write-capable app/MCP operations in Stage 1. Keep every write listed in `app-write-inventory.md` assigned to Stage 3 or Stage 4 service commands.
- [ ] Run:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
```

Expected: exits `0`.

Failure handling: fix `macos/project.yml`; do not hand-edit generated project files.

- [ ] Run:

```bash
rtk sh scripts/check-swift-module-boundaries.sh
```

Expected: exits `0`; no app/MCP write-module imports or dependencies.

Failure handling: remove illegal dependency or import.

- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/DatabaseManagerTests
```

Expected: exits `0`.

Failure handling: preserve existing app read results; do not introduce write-module dependencies.

- [ ] Run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
```

Expected: exits `0`; Swift MCP contract remains stable.

Failure handling: update read facade mapping or tests only when they prove existing behavior was already wrong.

Acceptance:

- [ ] App and MCP build while depending on `EngramCoreRead` only.
- [ ] Existing Swift MCP golden tests remain stable.
- [ ] No new app or MCP write path is introduced.

## Verification

Run focused commands after each phase, then run this full Stage 0/1 verification set before marking Stage 1 complete:

```bash
rtk sh -lc 'test -f docs/swift-single-stack/inventory.md'
rtk sh -lc 'test -f docs/swift-single-stack/file-disposition.md'
rtk sh -lc 'test -f docs/swift-single-stack/app-write-inventory.md'
rtk sh -lc 'test -f docs/swift-single-stack/baseline-inventory.md'
rtk sh -lc 'test -f docs/swift-single-stack/node-behavior-snapshots.md'
rtk sh -lc 'test -f docs/swift-single-stack/performance-baseline.md'
rtk sh -lc 'test -f docs/swift-single-stack/stage-gates.md'
rtk sh -lc 'test -f docs/performance/baselines/2026-04-23-node-runtime-baseline.json'
```

Expected: every file-existence check exits `0`.

```bash
rtk npx tsx scripts/perf/capture-node-baseline.ts \
  --fixture-db tests/fixtures/mcp-contract.sqlite \
  --fixture-root tests/fixtures \
  --session-fixture-root test-fixtures/sessions \
  --iterations 50 \
  --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Expected: exits `0`, validates canonical keys, prints comparison output, and leaves the baseline file unchanged.

```bash
rtk sh -lc 'cd macos && xcodegen generate'
```

Expected: exits `0`.

```bash
rtk sh scripts/check-swift-module-boundaries.sh
```

Expected: exits `0`; app and MCP cannot import `EngramCoreWrite`.

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS'
```

Expected: exits `0`.

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
```

Expected: exits `0`.

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/DatabaseManagerTests
```

Expected: exits `0`.

```bash
rtk npx tsx scripts/db/check-swift-schema-compat.ts --db tests/fixtures/mcp-contract.sqlite
```

Expected: exits `0` and prints deterministic row-count and metadata summary.

```bash
rtk npm test -- tests/core/db-migration.test.ts tests/core/db.test.ts tests/core/vector-store.test.ts tests/core/embeddings.test.ts tests/tools/search.test.ts tests/tools/get_context.test.ts
```

Expected: exits `0`; Node remains the reference.

```bash
rtk npm test
```

Expected: exits `0`.

```bash
rtk npm run lint
```

Expected: exits `0`.

If a full-suite command fails after focused commands passed, record the exact failing test or lint rule in `docs/swift-single-stack/stage-gates.md`, fix the failure if it is caused by Stage 0/1 work, and rerun the focused command plus the failed full-suite command.

## Acceptance Gates

Stage 0 acceptance gates:

- [ ] `docs/swift-single-stack/inventory.md` lists every Node, npm, `dist`, `node_modules`, `Resources/node`, daemon, MCP, CLI, docs, generated Xcode, runtime script, DB fixture, seed, export fixture, and Node behavior snapshot reference found by the inventory scans.
- [ ] `docs/swift-single-stack/file-disposition.md` gives every Node/TypeScript/runtime-script file one final action: `delete`, `archive fixture`, `keep non-shipped dev tool`, or `replace with Swift`.
- [ ] `docs/swift-single-stack/app-write-inventory.md` maps every current app/MCP/CLI direct write to a future service command or explicit removal decision.
- [ ] `docs/swift-single-stack/baseline-inventory.md` explicitly inventories DB schema fixtures, DB seed fixtures, DB export fixtures, Node behavior snapshots, runtime scripts, app write inventory, and performance baseline.
- [ ] `docs/swift-single-stack/node-behavior-snapshots.md` records Node reference commands and behavior areas for DB, FTS, vector, MCP search, MCP get_context, daemon status, and export fixture behavior.
- [ ] `docs/performance/baselines/2026-04-23-node-runtime-baseline.json` exists and contains every canonical metric and metadata key listed in Phase 0.3.
- [ ] `scripts/perf/capture-node-baseline.ts` supports `--compare-only` and `--force-baseline-update` semantics exactly as described.
- [ ] `--compare-only` leaves the canonical baseline checksum unchanged.
- [ ] `docs/swift-single-stack/stage-gates.md` has concrete commands for every Stage 0 and Stage 1 gate.

Stage 1 acceptance gates:

- [ ] Stage 1 baseline validation uses `--compare-only` and does not change `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`.
- [ ] `EngramCoreRead`, `EngramCoreWrite`, and `EngramCoreTests` exist in `macos/project.yml` and generated Xcode project output.
- [ ] App and MCP targets do not depend on or import `EngramCoreWrite`.
- [ ] SQLite policy tests prove WAL, `busy_timeout = 30000`, `foreign_keys = ON`, and failure when read-back busy timeout is below `5000`.
- [ ] Swift schema manifest and Node schema emission agree on required tables, columns, indexes, triggers, metadata keys, FTS tables, and vector tables.
- [ ] Swift migrations pass for empty, current Node, partial metadata, old FTS version, and vector-dimension mismatch fixtures.
- [ ] Swift migration tests prove idempotency and no unreviewed data loss.
- [ ] FTS version mismatch produces Node-compatible rebuild side effects.
- [ ] Vector model or dimension mismatch produces a rebuild signal, clears incompatible vector state, and preserves `memory_insights`.
- [ ] sqlite-vec strategy is documented and tested, or semantic-vector parity is explicitly blocked.
- [ ] Node can read Swift-created and Swift-migrated DBs through `scripts/db/check-swift-schema-compat.ts`.
- [ ] Existing Swift MCP tests pass.
- [ ] Existing npm tests and lint pass.
- [ ] No Node runtime behavior is removed.

## Rollback And Abort Guidance

Abort Stage 0 when:

- A required inventory section cannot be populated from scans.
- The canonical baseline cannot be captured from real Node behavior.
- `--compare-only` writes to the baseline file.
- The baseline JSON misses a canonical key.
- App write inventory has an unmapped write.

Stage 0 rollback:

- Revert only Stage 0-created docs/scripts/baseline files from the current branch.
- Do not touch existing Node runtime files, app files, or generated project files unless Stage 0 changed them.
- Recapture the baseline only after the capture command can prove it uses real fixtures and real Node runtime behavior.

Abort Stage 1 when:

- `docs/performance/baselines/2026-04-23-node-runtime-baseline.json` is missing or invalid.
- A Stage 1 command needs to overwrite the canonical baseline without `--force-baseline-update --reason`.
- App or MCP can import `EngramCoreWrite`.
- A Swift migration makes the current Node database reference unable to open the DB.
- WAL or busy-timeout policy cannot be verified.
- FTS or vector rebuild policy destroys data not named in tests.
- Any Stage 1 task requires deleting Node runtime code.

Stage 1 rollback:

- Keep Node as the runtime reference.
- Revert Stage 1 Swift core target additions and generated project changes together if target graph or build failures cannot be repaired quickly.
- Revert Swift migration behavior before touching Node migration behavior.
- Restore the Stage 0 baseline from git if any command changed it.
- Use `--force-baseline-update --reason "<reviewed Stage 0 defect>"` only when the baseline script or captured key was proven defective during Stage 0 evidence review.

## Self-review Checklist

- [ ] The plan includes Goal, Scope, Prerequisites, Files to create/modify, Phased tasks, Verification, Acceptance gates, Rollback/abort guidance, and Self-review checklist.
- [ ] Stage 0 is mandatory and blocks Stage 1 until baseline, inventories, behavior snapshots, scripts, and gates exist.
- [ ] The canonical baseline path is exactly `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`.
- [ ] Stage 1 baseline validation is read-only and uses `--compare-only`.
- [ ] Silent baseline overwrite is forbidden; overwrite requires `--force-baseline-update --reason`.
- [ ] Inventory explicitly covers DB schema fixtures, DB seed fixtures, DB export fixtures, Node behavior snapshots, runtime scripts, app write inventory, and performance baseline.
- [ ] Every task names concrete file paths.
- [ ] Every task includes commands, expected output, and failure handling.
- [ ] Stage 1 does not delete or rewrite Node runtime code.
- [ ] App and MCP are forbidden from importing `EngramCoreWrite`.
- [ ] SQLite policy states WAL, `busy_timeout = 30000`, `foreign_keys = ON`, and test failure below `5000`.
- [ ] FTS behavior references Node `FTS_VERSION = "3"`.
- [ ] Vector behavior prevents mixed model/dimension state and preserves `memory_insights`.
- [ ] No task asks an implementation worker to make an unbounded design choice without a named acceptance gate.
