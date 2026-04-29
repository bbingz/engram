# Swift Single Stack Core DB Implementation Plan Draft

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the Swift-owned core database stack for Engram while preserving compatibility with existing Node-created SQLite databases through Stage 5.

**Architecture:** Split Swift database access into explicit read and write modules: `EngramCoreRead` owns safe read repositories and schema models, while `EngramCoreWrite` owns migrations, write transactions, FTS/vector rebuild policy, and sqlite-vec loading. The macOS app and Swift MCP helper may depend on `EngramCoreRead`; only the future service writer target may depend on `EngramCoreWrite`. Node remains the reference during this stage, so every Swift migration must be readable by the current TypeScript implementation.

**Tech Stack:** Swift 5.9, GRDB 6, SQLite WAL, FTS5 trigram tokenizer, sqlite-vec `vec0`, XCTest, TypeScript Node 20 reference tests, Vitest, XcodeGen.

---

## Scope

This draft covers implementation planning unit 1 and unit 2 from the spec:

- `EngramCore` database and migration skeleton.
- SQLite connection policy, FTS/vector rebuild policy, migration fixtures, sqlite-vec strategy, canonical baseline validation, and schema compatibility gates.

This draft does not port adapters, indexing, service IPC, mutating MCP tools, app integration, CLI replacement, packaging, or Node deletion. Those must remain separate plans so each unit leaves the repo buildable and testable.

## Current Repo Facts

- Node currently owns schema creation and migration in `src/core/db/migration.ts`.
- Node opens SQLite through `src/core/db/database.ts`, sets `journal_mode = WAL`, `busy_timeout = 30000`, and `foreign_keys = ON`, then runs migrations and backfills.
- Swift app reads and performs several local writes through `macos/Engram/Core/Database.swift`; this is a compatibility wrapper, not a final single-writer design.
- Swift MCP reads through `macos/EngramMCP/Core/MCPDatabase.swift` using a read-only `DatabaseQueue`, without centralized PRAGMA verification.
- Node FTS version is `FTS_VERSION = '3'`; version mismatch clears `sessions_fts`, resets `sessions.size_bytes` to `0`, deletes `session_embeddings` and `vec_sessions` when present, and stores `metadata.fts_version = '3'`.
- Node vector tables are created by `src/core/vector-store.ts`, not by the base migration. The vector path tracks `metadata.vec_dimension`, `metadata.vec_model`, `session_embeddings`, `session_chunks`, `memory_insights`, `vec_sessions`, `vec_chunks`, and `vec_insights`.
- Existing fixtures live in both `tests/fixtures` and `test-fixtures`; Swift MCP tests already consume `tests/fixtures/mcp-contract.sqlite` and golden MCP JSON files.
- `package.json` exposes `npm run build`, `npm test`, `npm run lint`, `npm run generate:fixtures`, and `npm run generate:mcp-contract-fixtures`.
- `macos/project.yml` is the XcodeGen source of truth; `macos/Engram.xcodeproj/project.pbxproj` is generated and must be updated when targets change.

## File Map

- Modify: `macos/project.yml` to add `EngramCoreRead`, `EngramCoreWrite`, and `EngramCoreTests` targets and wire dependencies.
- Modify: `macos/Engram.xcodeproj/project.pbxproj` only by regenerating it with XcodeGen after `macos/project.yml` changes.
- Create: `macos/EngramCoreRead/Database/EngramDatabaseReader.swift` for opening read pools and exposing read transactions.
- Create: `macos/EngramCoreRead/Database/SQLiteConnectionPolicy.swift` for shared PRAGMA configuration and verification.
- Create: `macos/EngramCoreRead/Database/Schema/SchemaManifest.swift` for table, column, index, trigger, metadata-key, and version constants copied from the Node reference.
- Create: `macos/EngramCoreRead/Database/Schema/SchemaIntrospection.swift` for schema snapshots used by tests and compatibility checks.
- Create: `macos/EngramCoreRead/Repositories/SessionReadRepository.swift` for read-only session queries needed by Stage 1 compatibility tests.
- Create: `macos/EngramCoreRead/Repositories/MetadataReadRepository.swift` for metadata reads used by migration, FTS, and vector tests.
- Create: `macos/EngramCoreRead/Models/DatabaseRecords.swift` for GRDB records shared by read repositories and tests.
- Create: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift` for the single write-capable pool wrapper used by tests now and `EngramService` later.
- Create: `macos/EngramCoreWrite/Database/EngramMigrationRunner.swift` for idempotent Swift migrations equivalent to `src/core/db/migration.ts`.
- Create: `macos/EngramCoreWrite/Database/EngramMigrations.swift` for ordered migration steps and post-migration backfills.
- Create: `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift` for `fts_version` policy and rebuild triggers.
- Create: `macos/EngramCoreWrite/Database/VectorRebuildPolicy.swift` for vector dimension/model compatibility and rebuild triggers.
- Create: `macos/EngramCoreWrite/Database/SQLiteVecSupport.swift` for sqlite-vec loading, capability probing, and fail-closed diagnostics.
- Create: `macos/EngramCoreWrite/Database/SchemaCompatibilityVerifier.swift` for Node/Swift schema compatibility checks used by tests.
- Create: `macos/EngramCoreTests/Database/SQLiteConnectionPolicyTests.swift`.
- Create: `macos/EngramCoreTests/Database/MigrationRunnerTests.swift`.
- Create: `macos/EngramCoreTests/Database/HistoricalSchemaFixtureTests.swift`.
- Create: `macos/EngramCoreTests/Database/FTSRebuildPolicyTests.swift`.
- Create: `macos/EngramCoreTests/Database/VectorRebuildPolicyTests.swift`.
- Create: `macos/EngramCoreTests/Database/SchemaCompatibilityTests.swift`.
- Create: `macos/EngramCoreTests/Database/ModuleBoundaryTests.swift`.
- Create: `scripts/check-swift-module-boundaries.sh` for pre-test source scans that fail on app/MCP write-module imports or target dependency leaks.
- Create: `tests/fixtures/db/historical/README.md` describing each historical fixture and its provenance.
- Create: `tests/fixtures/db/historical/v0-minimal-sessions.sql`.
- Create: `tests/fixtures/db/historical/v1-current-node.sql`.
- Create: `tests/fixtures/db/historical/v1-partial-metadata.sql`.
- Create: `tests/fixtures/db/historical/v1-old-fts-version.sql`.
- Create: `tests/fixtures/db/historical/v1-vector-dimension-mismatch.sql`.
- Create: `scripts/db/emit-current-schema.ts` to dump the current Node schema into a deterministic JSON or SQL artifact for review.
- Create: `scripts/db/check-swift-schema-compat.ts` to open a Swift-migrated database with the current TypeScript `Database` class and verify read compatibility.
- Read: `scripts/perf/capture-node-baseline.ts` created by Stage 0 for canonical Node performance baselines.
- Read: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json` as the committed canonical Stage 0 baseline output.
- Create: `docs/superpowers/decisions/2026-04-23-swift-sqlite-vec.md` recording the sqlite-vec strategy decision.
- Modify later, not in this stage unless tests require wrappers: `macos/Engram/Core/Database.swift` to become a thin compatibility facade over `EngramCoreRead`.
- Modify later, not in this stage unless tests require wrappers: `macos/EngramMCP/Core/MCPDatabase.swift` to consume `EngramCoreRead` for read-only database access.

## Task 1: Verify Canonical Node Baseline Before Swift DB Work

**Files:**
- Read: `scripts/perf/capture-node-baseline.ts`
- Read: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`
- Read: `docs/swift-single-stack/performance-baseline.md`
- Read reference: `package.json`
- Read reference: `src/core/db/database.ts`
- Read reference: `src/core/indexer.ts`
- Read reference: `src/tools/search.ts`
- Read reference: `src/tools/get_context.ts`
- Read fixture: `tests/fixtures/mcp-contract.sqlite`
- Read fixture root: `tests/fixtures`
- Read fixture root: `test-fixtures`

- [ ] Verify the Stage 0 baseline script and canonical JSON exist before changing Swift database behavior.
- [ ] Measure cold Node database open plus migration on a copied fixture DB.
- [ ] Measure idle RSS for the Node daemon after ready state with no active indexing.
- [ ] Measure fixture indexing time on a deterministic copied fixture corpus.
- [ ] Measure incremental indexing latency after one new session fixture appears.
- [ ] Measure MCP `search` p50/p95 against `tests/fixtures/mcp-contract.sqlite`.
- [ ] Measure MCP `get_context` p50/p95 against `tests/fixtures/mcp-contract.sqlite`.
- [ ] Store machine metadata in the baseline JSON: date, git commit, Node version, macOS version, CPU architecture, fixture DB path, fixture corpus path, iteration count.
- [ ] Re-run baseline capture only in compare/validation mode from a clean build of the current Node reference; the script must be read-only in Stage 1 and refuse to write the canonical file unless an explicit `--force-baseline-update` flag is passed for a reviewed Stage 0 defect:

```bash
npm run build
npx tsx scripts/perf/capture-node-baseline.ts \
  --fixture-db tests/fixtures/mcp-contract.sqlite \
  --fixture-root tests/fixtures \
  --session-fixture-root test-fixtures/sessions \
  --iterations 50 \
  --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

- [ ] Acceptance gate: the baseline JSON contains cold app launch, cold DB open, idle RSS, initial indexing, incremental indexing, `search` p50/p95, and `get_context` p50/p95 fields.
- [ ] Acceptance gate: if any canonical baseline key is missing, Stage 1 fails and returns to Stage 0; do not add missing fields or change committed numeric values inside Stage 1.
- [ ] Acceptance gate: a Stage 1 compare run leaves the baseline file checksum unchanged; baseline defect fixes require a PR comment or commit message naming the incorrect key and must use `--force-baseline-update`.
- [ ] Acceptance gate: every later Stage 1 PR that affects DB open, migration, FTS, vector tables, or schema compatibility links back to this baseline file.

## Task 2: Create Explicit Swift Read/Write Module Boundaries

**Files:**
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
- Create: `macos/EngramCoreTests/Database/ModuleBoundaryTests.swift`
- Create: `scripts/check-swift-module-boundaries.sh`

- [ ] Add `EngramCoreRead` as a macOS framework target depending on `GRDB`.
- [ ] Add `EngramCoreWrite` as a macOS framework target depending on `EngramCoreRead` and `GRDB`.
- [ ] Add `EngramCoreTests` as a unit-test target depending on both core modules.
- [ ] Do not add `EngramCoreWrite` as a dependency of `Engram` or `EngramMCP` in this task.
- [ ] Add a boundary test that inspects the generated XcodeGen model, not ad hoc YAML parsing. Preferred mechanism: run `xcodegen dump --spec macos/project.yml --type json` in `scripts/check-swift-module-boundaries.sh`, decode the JSON, and fail if the `Engram` target depends on `EngramCoreWrite`.
- [ ] Add the same generated-model boundary check for `EngramMCP` depending on `EngramCoreWrite`.
- [ ] Add a source scan test that fails if files under `macos/Engram/` or `macos/EngramMCP/` contain `import EngramCoreWrite`.
- [ ] Add `scripts/check-swift-module-boundaries.sh` and run it before Swift build/test commands; it must fail on `EngramCoreWrite` imports in `macos/Engram`, `macos/EngramMCP`, app-importable `macos/Shared`, or target dependencies from `Engram`/`EngramMCP` to `EngramCoreWrite`.
- [ ] Keep current `DatabaseManager` and `MCPDatabase` behavior unchanged in this task; this task creates import boundaries only.
- [ ] Regenerate the Xcode project after the target graph changes:

```bash
cd macos
xcodegen generate
```

- [ ] Verify the target graph builds:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS'
xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
```

- [ ] Acceptance gate: `EngramCoreRead` can compile without importing `EngramCoreWrite`.
- [ ] Acceptance gate: `EngramCoreWrite` can compile while importing `EngramCoreRead`.
- [ ] Acceptance gate: app and MCP targets are prevented from importing write APIs by project dependencies, source-scan script, and test coverage.

## Task 3: Enforce SQLite Connection Policy

**Files:**
- Create: `macos/EngramCoreRead/Database/SQLiteConnectionPolicy.swift`
- Modify: `macos/EngramCoreRead/Database/EngramDatabaseReader.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`
- Create: `macos/EngramCoreTests/Database/SQLiteConnectionPolicyTests.swift`
- Read reference: `src/core/db/database.ts`
- Read reference: `macos/Engram/Core/Database.swift`
- Read reference: `macos/EngramMCP/Core/MCPDatabase.swift`

- [ ] Centralize SQLite PRAGMA setup so read and write opens cannot bypass it.
- [ ] Match the current Node policy by setting `busy_timeout = 30000` for all Swift connections.
- [ ] Set and verify `foreign_keys = ON` for all Swift connections, including read pools, so the shared open policy matches Node and future read paths cannot hide constraint drift.
- [ ] Ensure the write-capable pool sets `journal_mode = WAL` and verifies the result is `wal`.
- [ ] Ensure read-only opens verify that the database is already in WAL mode and set `busy_timeout = 30000`.
- [ ] Fail with a typed database policy error when WAL cannot be enabled or verified.
- [ ] Fail with a typed database policy error when `busy_timeout` reads back lower than `5000`.
- [ ] Use `DatabasePool` for `EngramDatabaseReader` and `EngramDatabaseWriter`; do not introduce ad hoc `DatabaseQueue` writer connections.
- [ ] Add tests that open a temporary database through `EngramDatabaseWriter` and verify `PRAGMA journal_mode`, `PRAGMA busy_timeout`, and `PRAGMA foreign_keys`.
- [ ] Add tests that open the same WAL database through `EngramDatabaseReader` and verify read operations work while writer is open and `PRAGMA foreign_keys` reads back `1`.
- [ ] Add a regression test that attempts to open a non-WAL database read-only and receives the typed policy error.
- [ ] Verify:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/SQLiteConnectionPolicyTests
```

- [ ] Acceptance gate: no Swift core database open path exists outside `SQLiteConnectionPolicy`.
- [ ] Acceptance gate: `busy_timeout` is at least `30000` on new Swift read and write connections.
- [ ] Acceptance gate: WAL is enabled by the writer and verified by readers.

## Task 4: Port Base Schema Manifest From Node

**Files:**
- Create: `macos/EngramCoreRead/Database/Schema/SchemaManifest.swift`
- Create: `macos/EngramCoreRead/Database/Schema/SchemaIntrospection.swift`
- Create: `macos/EngramCoreTests/Database/SchemaCompatibilityTests.swift`
- Create: `scripts/db/emit-current-schema.ts`
- Read reference: `src/core/db/migration.ts`
- Read reference: `src/core/db/types.ts`
- Read reference: `src/core/db/session-repo.ts`
- Read reference: `src/core/db/metrics-repo.ts`
- Read reference: `src/core/db/migration-log-repo.ts`
- Read reference: `macos/Engram/Models/Session.swift`
- Read reference: `macos/Engram/Models/GitRepo.swift`

- [ ] Add Swift constants for `SCHEMA_VERSION = 1` and `FTS_VERSION = "3"`.
- [ ] Add manifest entries for all Node-created base tables: `sessions`, `sessions_fts`, `sync_state`, `metadata`, `project_aliases`, `session_local_state`, `session_index_jobs`, `migration_log`, `usage_snapshots`, `git_repos`, `session_costs`, `session_tools`, `session_files`, `logs`, `traces`, `metrics`, `metrics_hourly`, `alerts`, `ai_audit_log`, `insights`, and `insights_fts`.
- [ ] Add manifest entries for base indexes and triggers created by `src/core/db/migration.ts`, including `trg_sessions_parent_cascade`.
- [ ] Add manifest entries for metadata keys used by Stage 1: `schema_version`, `fts_version`, `vec_dimension`, `vec_model`, and `detection_version`.
- [ ] Add manifest entries for lazy vector schema created outside the base migration: `session_embeddings`, `session_chunks`, `memory_insights`, `vec_sessions`, `vec_chunks`, `vec_insights`, and their metadata compatibility keys.
- [ ] Add schema introspection helpers that list table names, column names, indexes, triggers, virtual table declarations, and metadata values from a live database.
- [ ] Add a Node schema emission script that opens a temporary database through the current TypeScript `Database` class and emits deterministic schema JSON.
- [ ] Add a Swift test that opens a Node-created temporary database and proves `SchemaManifest` covers every table, index, trigger, and required column.
- [ ] Add a Swift test that proves `Session` and `GitRepo` GRDB record assumptions match the migrated schema.
- [ ] Run the Node schema dump for review:

```bash
npx tsx scripts/db/emit-current-schema.ts --out /tmp/engram-node-schema.json
```

- [ ] Verify:

```bash
npm test -- tests/core/db-migration.test.ts tests/core/db.test.ts
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/SchemaCompatibilityTests
```

- [ ] Acceptance gate: Swift schema manifest and Node schema dump agree on all required tables, columns, indexes, triggers, virtual tables, and version metadata.
- [ ] Acceptance gate: every future schema-changing Swift migration must update `SchemaManifest.swift` in the same commit.

## Task 5: Implement Swift Migration Runner Skeleton

**Files:**
- Create: `macos/EngramCoreWrite/Database/EngramMigrationRunner.swift`
- Create: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift`
- Create: `macos/EngramCoreTests/Database/MigrationRunnerTests.swift`
- Read reference: `src/core/db/migration.ts`
- Read reference: `src/core/db/database.ts`
- Read reference: `tests/core/db-migration.test.ts`

- [ ] Build the migration runner as an idempotent operation executed inside the write-capable core path.
- [ ] Preserve the Node schema version number during Stage 1: `schema_version = "1"`.
- [ ] Create the same base tables and indexes as the Node migration for a fresh database.
- [ ] Add the same legacy `ALTER TABLE sessions ADD COLUMN` behavior for existing `sessions` tables.
- [ ] Add the same `sync_state.last_sync_session_id` migration for existing `sync_state` tables.
- [ ] Preserve the current non-destructive behavior for removed external semantic search columns: do not attempt to drop old columns in this stage.
- [ ] Add tests for fresh database creation.
- [ ] Add tests for existing minimal `sessions` table migration.
- [ ] Add tests for repeated migration runs.
- [ ] Add tests that repeated runs do not duplicate rows, duplicate indexes, duplicate triggers, or violate constraints.
- [ ] Add tests that migration preserves pre-existing session rows and local state rows.
- [ ] Do not run post-migration behavioral backfills in this task except the ones already run by `src/core/db/database.ts` during construction; add separate tasks for backfill parity if the fixture tests expose gaps.
- [ ] Verify:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/MigrationRunnerTests
npm test -- tests/core/db-migration.test.ts
```

- [ ] Acceptance gate: Swift can create a fresh schema that the current Node `Database` class opens without running destructive changes.
- [ ] Acceptance gate: Swift can migrate a minimal historical `sessions` table without data loss.
- [ ] Acceptance gate: migrations are idempotent across at least three consecutive opens.

## Task 6: Add Historical Migration Fixtures

**Files:**
- Create: `tests/fixtures/db/historical/README.md`
- Create: `tests/fixtures/db/historical/v0-minimal-sessions.sql`
- Create: `tests/fixtures/db/historical/v1-current-node.sql`
- Create: `tests/fixtures/db/historical/v1-partial-metadata.sql`
- Create: `tests/fixtures/db/historical/v1-old-fts-version.sql`
- Create: `tests/fixtures/db/historical/v1-vector-dimension-mismatch.sql`
- Create: `macos/EngramCoreTests/Database/HistoricalSchemaFixtureTests.swift`
- Modify: `scripts/db/emit-current-schema.ts`
- Read reference: `tests/core/db-migration.test.ts`
- Read reference: `tests/fixtures/mcp-contract.sqlite`

- [ ] Store historical fixtures as deterministic SQL where possible so diffs remain reviewable.
- [ ] Use binary `.sqlite` fixtures only when a virtual table or extension behavior cannot be represented safely as SQL.
- [ ] Document fixture provenance in `tests/fixtures/db/historical/README.md`, including which Node migration behavior each fixture exercises.
- [ ] Each fixture entry must include: fixture name, original source or generation command, source commit, schema version, row-count summary by table, expected destructive side effects, expected post-migration metadata, vector/FTS state, and whether Node must still open the migrated result during Stages 1-4.
- [ ] Include a minimal pre-current schema with only the original core `sessions` columns.
- [ ] Include a fully current Node schema emitted by `scripts/db/emit-current-schema.ts`.
- [ ] Include a partially migrated schema missing newer columns but containing user data.
- [ ] Include a schema with `metadata.fts_version` missing or lower than `"3"` and populated `sessions_fts` rows.
- [ ] Include a schema with vector metadata dimension mismatch and populated vector metadata tables.
- [ ] Add Swift fixture tests that restore each fixture to a temporary `.sqlite` file before migration.
- [ ] Add Swift fixture tests that run the Swift migration twice per fixture.
- [ ] Add Swift fixture tests that compare row counts before and after migration for all user-data tables.
- [ ] Add Swift fixture tests that assert the migrated database is readable through `EngramCoreRead`.
- [ ] Add a Node compatibility command for every Swift-migrated fixture:

```bash
npx tsx scripts/db/check-swift-schema-compat.ts --db /tmp/path-to-swift-migrated-fixture.sqlite
```

- [ ] Verify:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/HistoricalSchemaFixtureTests
npm test -- tests/core/db-migration.test.ts
```

- [ ] Acceptance gate: empty, fully migrated, partially migrated, and historical production-style schema fixtures migrate to the current schema.
- [ ] Acceptance gate: no fixture loses rows from `sessions`, `session_local_state`, `project_aliases`, `migration_log`, `insights`, `memory_insights`, or `session_costs` unless a test explicitly names the destructive behavior.
- [ ] Acceptance gate: no destructive migration is introduced in Stage 1 without a backup and rollback plan documented in this draft or its successor.

## Task 7: Sync GRDB Record Assumptions With Migrated Schema

**Files:**
- Create: `macos/EngramCoreRead/Models/DatabaseRecords.swift`
- Create: `macos/EngramCoreRead/Repositories/SessionReadRepository.swift`
- Create: `macos/EngramCoreRead/Repositories/MetadataReadRepository.swift`
- Create: `macos/EngramCoreTests/Database/SchemaCompatibilityTests.swift`
- Read reference: `macos/Engram/Models/Session.swift`
- Read reference: `macos/Engram/Models/GitRepo.swift`
- Read reference: `macos/Engram/Core/Database.swift`
- Read reference: `macos/EngramMCP/Core/MCPDatabase.swift`
- Read reference: `src/core/db/session-repo.ts`

- [ ] Move only schema-compatible record definitions into `EngramCoreRead`; do not move app view models or UI formatting.
- [ ] Ensure GRDB records can decode all current nullable and non-nullable columns created by the Swift migration runner.
- [ ] Preserve Node read semantics that hide `hidden_at` rows and hide orphan rows unless a caller requests administrative inclusion.
- [ ] Preserve current tier filtering semantics: `hide-skip` excludes `tier = 'skip'`; `hide-noise` excludes `skip` and `lite`; `all` includes every tier.
- [ ] Preserve CJK search detection rules in the read repository only as read behavior; FTS rebuild remains write-module behavior.
- [ ] Add tests that fetch representative rows from every historical fixture after Swift migration.
- [ ] Add tests that fetch rows from `tests/fixtures/mcp-contract.sqlite` without running Swift migrations.
- [ ] Add tests that prove `EngramCoreRead` can read a database migrated by `EngramCoreWrite`.
- [ ] Verify:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/SchemaCompatibilityTests
xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/DatabaseManagerTests
xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
```

- [ ] Acceptance gate: GRDB schema definitions read a database migrated by the Swift migration runner.
- [ ] Acceptance gate: current app and MCP test suites still pass before any facade replacement.

## Task 8: Port FTS Version And Rebuild Policy

**Files:**
- Create: `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Create: `macos/EngramCoreTests/Database/FTSRebuildPolicyTests.swift`
- Read reference: `src/core/db/migration.ts`
- Read reference: `src/core/db/fts-repo.ts`
- Read reference: `macos/Engram/Core/Database.swift`
- Read fixture: `tests/fixtures/db/historical/v1-old-fts-version.sql`

- [ ] Implement Swift policy for `metadata.fts_version` with expected value `"3"`.
- [ ] On missing or mismatched FTS version, match Node behavior exactly: delete all `sessions_fts` rows.
- [ ] On missing or mismatched FTS version, match Node behavior exactly: update all `sessions.size_bytes` values to `0`.
- [ ] On missing or mismatched FTS version, delete `session_embeddings` rows if the table exists.
- [ ] On missing or mismatched FTS version, delete `vec_sessions` rows if the table exists.
- [ ] On missing or mismatched FTS version, also delete `session_chunks` rows and `vec_chunks` rows when those tables exist, because chunk vectors are derived from FTS text and can otherwise dominate semantic search with stale data.
- [ ] On missing or mismatched FTS version, store `metadata.fts_version = "3"`.
- [ ] Do not add an insights FTS destructive reset in this task because the Node reference does not currently do that.
- [ ] Add tests for missing `metadata.fts_version`.
- [ ] Add tests for old `metadata.fts_version`.
- [ ] Add tests for current `metadata.fts_version`.
- [ ] Add tests where vector tables are absent and policy still succeeds.
- [ ] Add tests where vector tables are present and the Node-compatible cleanup occurs.
- [ ] Add tests that repeated policy runs do not keep resetting already-current data.
- [ ] Verify:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/FTSRebuildPolicyTests
npm test -- tests/core/db.test.ts tests/tools/search.test.ts tests/tools/get_context.test.ts
```

- [ ] Acceptance gate: Swift FTS version behavior is byte-for-byte compatible with the current Node migration side effects on affected tables.
- [ ] Acceptance gate: FTS rebuild policy does not silently delete `insights` or `insights_fts` data in Stage 1.

## Task 9: Decide And Implement sqlite-vec Strategy For Swift

**Files:**
- Create: `docs/superpowers/decisions/2026-04-23-swift-sqlite-vec.md`
- Create: `macos/EngramCoreWrite/Database/SQLiteVecSupport.swift`
- Create: `macos/EngramCoreTests/Database/VectorRebuildPolicyTests.swift`
- Modify: `macos/project.yml`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`
- Read reference: `src/core/vector-store.ts`
- Read reference: `tests/core/vector-store.test.ts`
- Read reference: `package.json`

- [ ] Record the sqlite-vec decision before vector migration code depends on it; Stage 2 cannot claim semantic search/vector parity until this decision doc names an active strategy and the capability test passes or an approved replacement is tested.
- [ ] Use the vendored native-extension strategy unless implementation discovery proves it cannot be shipped on the supported macOS target.
- [ ] Preferred strategy: vendor a macOS-compatible sqlite-vec dynamic library under `macos/Vendor/sqlite-vec/` and load it from Swift through SQLite extension loading before any `vec0` table is created or queried.
- [ ] Preferred strategy acceptance: `SQLiteVecSupport` can run `SELECT vec_version()` or an equivalent sqlite-vec capability probe from a GRDB connection.
- [ ] Preferred strategy acceptance: the extension supports existing `vec0` declarations for `vec_sessions`, `vec_chunks`, and `vec_insights` with `float[768]`.
- [ ] Preferred strategy acceptance: packaged app and helper can locate the extension through bundle resources without referencing `node_modules`.
- [ ] Fallback strategy: if vendoring sqlite-vec is rejected, document the replacement index design and add parity tests proving existing `vec0` data is either migrated or intentionally rebuilt without user-visible semantic-search loss.
- [ ] Do not claim vector parity if Swift cannot load sqlite-vec or an approved replacement.
- [ ] Add a capability test that skips semantic-vector behavior only when sqlite-vec is deliberately unavailable and records the reason.
- [ ] Add a failure-mode test that proves sqlite-vec unavailable does not crash base DB migration and produces a typed vector-unavailable diagnostic.
- [ ] Verify:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/VectorRebuildPolicyTests
npm test -- tests/core/vector-store.test.ts tests/tools/search.test.ts tests/tools/get_context.test.ts
```

- [ ] Acceptance gate: the decision doc names exactly one active strategy and one rejected alternative.
- [ ] Acceptance gate: Swift vector support either loads sqlite-vec and creates compatible `vec0` tables, or blocks semantic-vector parity claims with explicit tests and docs.

## Task 10: Port Vector Model And Dimension Rebuild Policy

**Files:**
- Create: `macos/EngramCoreWrite/Database/VectorRebuildPolicy.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Modify: `macos/EngramCoreWrite/Database/SQLiteVecSupport.swift`
- Create: `macos/EngramCoreTests/Database/VectorRebuildPolicyTests.swift`
- Read reference: `src/core/vector-store.ts`
- Read reference: `src/core/embeddings.ts`
- Read reference: `src/core/embedding-indexer.ts`
- Read fixture: `tests/fixtures/db/historical/v1-vector-dimension-mismatch.sql`

- [ ] Match Node vector dimension default: `768`.
- [ ] Match Node metadata keys: `vec_dimension` and `vec_model`.
- [ ] Create vector metadata tables compatible with Node: `session_embeddings`, `session_chunks`, and `memory_insights`.
- [ ] Create vector virtual tables compatible with Node when sqlite-vec is available: `vec_sessions`, `vec_chunks`, and `vec_insights`.
- [ ] On stored dimension mismatch, drop `vec_sessions`, `vec_chunks`, and `vec_insights`.
- [ ] On stored dimension mismatch, delete `session_embeddings` and `session_chunks`.
- [ ] On stored model value `__pending_rebuild__`, drop `vec_sessions`, `vec_chunks`, and `vec_insights`.
- [ ] On stored model value `__pending_rebuild__`, delete `session_embeddings` and `session_chunks`.
- [ ] On service startup, compare configured embedding provider, model, and dimension from Swift settings/providers against stored `metadata.vec_model` and `metadata.vec_dimension`; if provider/model/dimension changed, write a rebuild marker and enqueue vector rebuild before semantic search is advertised.
- [ ] Preserve `memory_insights` rows during automatic dimension/model migration to match Node constructor behavior.
- [ ] Do not implement the Node `dropAndRebuild()` destructive behavior in automatic migrations because that deletes `memory_insights`; reserve that for an explicit future service maintenance command.
- [ ] Store `metadata.vec_dimension = "768"` after a successful vector schema migration.
- [ ] Add tests for fresh vector schema creation.
- [ ] Add tests for dimension mismatch rebuild.
- [ ] Add tests for `__pending_rebuild__` model rebuild.
- [ ] Add tests for compatible dimension/model no-op.
- [ ] Add tests for configured provider/model/dimension startup mismatch producing a rebuild marker and preventing mixed-vector semantic search.
- [ ] Add tests proving `memory_insights` survives automatic migration.
- [ ] Add tests proving `session_embeddings` and `session_chunks` are cleared on rebuild.
- [ ] Verify:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/VectorRebuildPolicyTests
npm test -- tests/core/vector-store.test.ts tests/core/embeddings.test.ts
```

- [ ] Acceptance gate: model or dimension changes trigger a rebuild signal and clear incompatible vector state.
- [ ] Acceptance gate: automatic migration never silently mixes vectors from different models or dimensions.
- [ ] Acceptance gate: automatic migration does not destroy text-only curated memory rows.

## Task 11: Add Node/Swift Schema Compatibility Harness

**Files:**
- Create: `scripts/db/check-swift-schema-compat.ts`
- Create: `macos/EngramCoreTests/Database/SchemaCompatibilityTests.swift`
- Modify: `macos/EngramCoreWrite/Database/SchemaCompatibilityVerifier.swift`
- Read reference: `src/core/db/database.ts`
- Read reference: `src/core/db/*.ts`
- Read reference: `tests/core/db.test.ts`
- Read fixture: `tests/fixtures/mcp-contract.sqlite`

- [ ] Add a TypeScript compatibility script that opens a supplied database path through the current Node `Database` class.
- [ ] The compatibility script must fail if Node migrations throw on a Swift-migrated database.
- [ ] The compatibility script must fail if required Node repositories cannot run representative reads: session list, metadata reads, FTS search, stats group-by, costs summary, project aliases, migration log list, insights FTS fallback.
- [ ] The compatibility script must instantiate Node `SqliteVecStore`, run a sqlite-vec capability probe, and read or search `vec_sessions`, `vec_chunks`, and `vec_insights` when vector tables are present.
- [ ] The compatibility script must print a deterministic summary of row counts and metadata values.
- [ ] Add Swift tests that create temporary databases through the Swift migration runner and then call the compatibility script through `Process`.
- [ ] Add Swift tests that open `tests/fixtures/mcp-contract.sqlite` through `EngramCoreRead` without mutating it.
- [ ] Add Swift tests that copy `tests/fixtures/mcp-contract.sqlite`, run Swift migrations on the copy, and then run the Node compatibility script.
- [ ] Verify:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS' -only-testing:EngramCoreTests/SchemaCompatibilityTests
npx tsx scripts/db/check-swift-schema-compat.ts --db tests/fixtures/mcp-contract.sqlite
npm test -- tests/core/db.test.ts tests/core/db-migration.test.ts tests/tools/search.test.ts tests/tools/get_context.test.ts
```

- [ ] Acceptance gate: Node can open every database migrated by the Swift migration runner until Stage 5.
- [ ] Acceptance gate: Swift can read every retained historical production schema fixture after migration.
- [ ] Acceptance gate: schema changes remain forward-compatible with current Node until the final Node deletion stage.

## Task 12: Replace App And MCP DB Opens With Read Facades Only

**Files:**
- Modify: `macos/Engram/Core/Database.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/project.yml`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`
- Modify: `macos/EngramTests/DatabaseManagerTests.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Read reference: `macos/Engram/Core/Database.swift`
- Read reference: `macos/EngramMCP/Core/MCPDatabase.swift`

- [ ] Depend `Engram` and `EngramMCP` on `EngramCoreRead` only.
- [ ] Route read-only Swift app queries through `EngramCoreRead` facades without changing user-visible query results.
- [ ] Route read-only Swift MCP queries through `EngramCoreRead` facades without changing JSON contract results.
- [ ] Do not preserve app-side direct writes after service writer cutover. Inventory current `DatabaseManager` write methods for favorites, hide, rename, project updates, summaries, and local state, then create a Stage 3/4 checklist to move each behind `EngramServiceClient`.
- [ ] Add source-scan tests that fail once service cutover starts if `macos/Engram` contains `writerPool`, app-side `.write {`, app-side `DatabasePool(path:)`, raw GRDB DML, or `import EngramCoreWrite`.
- [ ] Ensure `MCPDatabase` does not create a write-capable connection.
- [ ] Keep `MCPDatabase` fail-closed for any write path that still routes through daemon HTTP or future service IPC.
- [ ] Verify:

```bash
cd macos
xcodegen generate
cd ..
xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/DatabaseManagerTests
xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
```

- [ ] Acceptance gate: app and MCP build without importing `EngramCoreWrite`.
- [ ] Acceptance gate: existing Swift MCP golden tests remain byte-stable.
- [ ] Acceptance gate: no new app or MCP write path is introduced in this stage.

## Task 13: Final Verification And Acceptance Gates

**Files:**
- Read all changed files from prior tasks.
- Read reference: `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`
- Read reference: `package.json`
- Read reference: `macos/project.yml`

- [ ] Run the Node reference tests that remain required during Stages 1-4:

```bash
npm test -- tests/core/db-migration.test.ts tests/core/db.test.ts tests/core/vector-store.test.ts tests/core/embeddings.test.ts tests/tools/search.test.ts tests/tools/get_context.test.ts
```

- [ ] Run the full Node test suite if focused tests pass:

```bash
npm test
```

- [ ] Run TypeScript lint after focused tests:

```bash
npm run lint
```

- [ ] Run Swift core tests:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS'
```

- [ ] Run existing Swift app DB tests:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/DatabaseManagerTests
```

- [ ] Run existing Swift MCP executable tests:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
```

- [ ] Run schema compatibility script against representative databases:

```bash
npx tsx scripts/db/check-swift-schema-compat.ts --db tests/fixtures/mcp-contract.sqlite
npx tsx scripts/db/check-swift-schema-compat.ts --db /tmp/engram-swift-migrated-empty.sqlite
npx tsx scripts/db/check-swift-schema-compat.ts --db /tmp/engram-swift-migrated-historical.sqlite
```

- [ ] Compare baseline performance against the canonical Stage 0 Node baseline when Swift migration code is exercised in tests:

```bash
npx tsx scripts/perf/capture-node-baseline.ts \
  --fixture-db tests/fixtures/mcp-contract.sqlite \
  --fixture-root tests/fixtures \
  --session-fixture-root test-fixtures/sessions \
  --iterations 50 \
  --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

- [ ] Acceptance gate: existing Swift MCP tests pass.
- [ ] Acceptance gate: existing npm tests pass or any pre-existing failure is documented with the exact failing test and error.
- [ ] Acceptance gate: Swift database tests prove read parity for core entities.
- [ ] Acceptance gate: Swift migration tests pass from every retained historical schema fixture to the current schema.
- [ ] Acceptance gate: GRDB schema definitions read a database migrated by the Swift migration runner.
- [ ] Acceptance gate: WAL is enforced and Swift opens set `busy_timeout = 30000`; tests fail if the value reads back below `5000`.
- [ ] Acceptance gate: FTS version mismatch and vector model/dimension mismatch produce the expected rebuild side effects.
- [ ] Acceptance gate: sqlite-vec strategy is recorded and covered by capability tests.
- [ ] Acceptance gate: no source file under `macos/Engram/` or `macos/EngramMCP/` imports `EngramCoreWrite`.
- [ ] Acceptance gate: no Node runtime behavior is removed in this stage.

## Risk Controls

- Keep all Swift migration behavior compatible with the current Node `Database` class until Stage 5.
- Treat `tests/fixtures/mcp-contract.sqlite` as read-only input in tests; copy it before migration.
- Do not delete or rewrite `src/core/db/*.ts` during this stage.
- Do not delete `DatabaseManager` or `MCPDatabase` during this stage; replace their internals only after `EngramCoreRead` tests pass.
- Do not expose Swift mutating MCP tools in this stage.
- Do not claim semantic-vector parity unless sqlite-vec or an approved replacement is loaded and tested in Swift.
- Preserve TypeScript comments that explain non-obvious database behavior when porting them into Swift, including existing CJK tokenizer and path-boundary explanations.

## Handoff Notes

- Implement tasks in order; Task 1 must pass before behavior changes so performance comparisons still point at the canonical Stage 0 baseline.
- The highest-risk early invariant is the module boundary: `Engram` and `EngramMCP` must never import `EngramCoreWrite`.
- The highest-risk DB invariant is compatibility: a Swift-migrated database must still open through the current Node `Database` class until Node deletion.
- The highest-risk data-loss invariant is rebuild policy: automatic vector rebuild may clear vector state, but it must not delete text-only curated memory rows.
