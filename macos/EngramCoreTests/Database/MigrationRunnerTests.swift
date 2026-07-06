import EngramCoreRead
import EngramCoreWrite
import GRDB
import Darwin
import XCTest

final class MigrationRunnerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-migrations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testCreatesFreshCurrentSchema() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("fresh.sqlite"))
        try writer.migrate()

        let snapshot = try writer.read { db in
            try SchemaIntrospection.snapshot(db)
        }

        XCTAssertTrue(SchemaManifest.baseTables.isSubset(of: snapshot.tableNames))
        XCTAssertTrue(SchemaManifest.requiredMetadataKeys.isSubset(of: snapshot.metadataKeys))

        let sessionIndexes = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        XCTAssertTrue(sessionIndexes.contains("idx_sessions_project"))
        XCTAssertTrue(sessionIndexes.contains("idx_sessions_last_accessed"))
        // Partial index backing the visible-session COUNT refreshed on the status poll.
        XCTAssertTrue(sessionIndexes.contains("idx_sessions_visible"))
        XCTAssertTrue(sessionIndexes.contains("idx_metrics_ts"))
        XCTAssertTrue(sessionIndexes.contains("idx_migration_log_state_started"))

        let sessionColumns = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sessions') ORDER BY cid")
        }
        XCTAssertTrue(sessionColumns.contains("last_accessed_at"))
        XCTAssertTrue(sessionColumns.contains("access_count"))
        // Human-driven signal columns (additive, nullable).
        XCTAssertTrue(sessionColumns.contains("instruction_count"))
        XCTAssertTrue(sessionColumns.contains("human_turn_count"))
        XCTAssertTrue(sessionColumns.contains("instruction_summary"))

        let metricsSql = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'metrics'")
        }
        XCTAssertTrue(metricsSql?.contains("CHECK (type IN ('counter', 'gauge', 'histogram'))") ?? false)

        let insightsFtsSql = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'insights_fts'")
        }
        XCTAssertTrue(insightsFtsSql?.contains("tokenize='trigram case_sensitive 0'") ?? false)

        let memoryInsightColumns = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('memory_insights') ORDER BY cid")
        }
        XCTAssertEqual(memoryInsightColumns, [
            "id",
            "content",
            "wing",
            "room",
            "source_session_id",
            "importance",
            "model",
            "created_at",
            "deleted_at",
        ])

        let sessionToolColumns = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('session_tools') ORDER BY cid")
        }
        XCTAssertEqual(sessionToolColumns, ["session_id", "tool_name", "call_count"])

        let workBeatColumns = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('session_work_beats') ORDER BY cid")
        }
        XCTAssertEqual(workBeatColumns, [
            "session_id",
            "beat_index",
            "action_date",
            "action_timestamp",
            "work_key",
            "work_title",
            "human_intent",
            "assistant_outcome",
            "kind",
            "status",
            "operation_events",
            "confidence",
        ])
        XCTAssertTrue(sessionIndexes.contains("idx_session_work_beats_date"))
        XCTAssertTrue(sessionIndexes.contains("idx_session_work_beats_work"))

        let workItemTitleColumns = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('work_item_titles') ORDER BY cid")
        }
        XCTAssertEqual(workItemTitleColumns, [
            "project",
            "work_key",
            "title",
            "intent_hash",
            "model",
            "updated_at",
        ])
        let workItemTitlePK = try writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('work_item_titles') WHERE pk > 0 ORDER BY pk"
            )
        }
        XCTAssertEqual(workItemTitlePK, ["project", "work_key"])

        let observabilityColumns = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('logs') ORDER BY cid")
        }
        XCTAssertEqual(observabilityColumns, [
            "id",
            "ts",
            "level",
            "module",
            "trace_id",
            "span_id",
            "message",
            "data",
            "error_name",
            "error_message",
            "error_stack",
            "source",
        ])
    }

    func testMigrationIsIdempotentAcrossRepeatedRuns() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("idempotent.sqlite"))

        try writer.migrate()
        try writer.migrate()
        try writer.migrate()

        let metadata = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'schema_version'")
        }
        XCTAssertEqual(metadata, "1")
    }

    func testCreatesRemoteOffloadSchema() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("offload.sqlite"))
        try writer.migrate()

        // sessions.offload_state column exists and defaults to 'local'.
        let sessionColumns = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sessions') ORDER BY cid")
        }
        XCTAssertTrue(sessionColumns.contains("offload_state"))

        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, file_path)
                VALUES ('s-offload', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/s.jsonl');
            """)
        }
        let defaultState = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT offload_state FROM sessions WHERE id = 's-offload'")
        }
        XCTAssertEqual(defaultState, "local")

        // The three offload tables are present, kept out of baseTables on purpose.
        let tableNames = try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        XCTAssertTrue(
            SchemaManifest.remoteOffloadTables.isSubset(of: tableNames),
            "missing offload tables: \(SchemaManifest.remoteOffloadTables.subtracting(tableNames).sorted())"
        )
        XCTAssertTrue(SchemaManifest.baseTables.isDisjoint(with: SchemaManifest.remoteOffloadTables))

        let indexes = try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        }
        XCTAssertTrue(indexes.contains("idx_sessions_offload_state"))
        XCTAssertTrue(indexes.contains("idx_offload_queue_status"))
        XCTAssertTrue(indexes.contains("idx_rehydrate_queue_status"))
        XCTAssertTrue(indexes.contains("idx_sync_ledger_session"))

        // The status CHECK constraint accepts a documented state and rejects others.
        try writer.write { db in
            try db.execute(sql: "INSERT INTO offload_queue(id, session_id, status) VALUES ('q1', 's-offload', 'pending')")
        }
        XCTAssertThrowsError(try writer.write { db in
            try db.execute(sql: "INSERT INTO offload_queue(id, session_id, status) VALUES ('q2', 's-offload', 'bogus')")
        })
    }

    func testRemoteOffloadSchemaIsIdempotent() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("offload-idempotent.sqlite"))
        try writer.migrate()
        try writer.migrate()
        try writer.migrate()

        let tableNames = try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        XCTAssertTrue(SchemaManifest.remoteOffloadTables.isSubset(of: tableNames))

        let columnCount = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM pragma_table_info('sessions') WHERE name = 'offload_state'"
            ) ?? 0
        }
        XCTAssertEqual(columnCount, 1, "offload_state must be added exactly once")
    }

    func testLegacySessionsBackfillOffloadStateToLocal() throws {
        let path = databasePath("legacy-offload.sqlite")
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  start_time TEXT NOT NULL,
                  cwd TEXT NOT NULL DEFAULT '',
                  file_path TEXT NOT NULL
                );
                INSERT INTO sessions(id, source, start_time, cwd, file_path)
                VALUES ('legacy-off', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/p', '/tmp/s.jsonl');
            """)
        }

        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()

        let state = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT offload_state FROM sessions WHERE id = 'legacy-off'")
        }
        XCTAssertEqual(state, "local", "ALTER ADD COLUMN ... DEFAULT 'local' must backfill existing rows")
    }

    func testInsightsLifecycleColumnsAddedOnMigration() throws {
        let path = databasePath("legacy-insights.sqlite")
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE insights (
                  id TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  wing TEXT,
                  room TEXT,
                  source_session_id TEXT,
                  importance INTEGER DEFAULT 5,
                  has_embedding INTEGER DEFAULT 0,
                  created_at TEXT DEFAULT (datetime('now'))
                );
                INSERT INTO insights(id, content, importance) VALUES ('legacy-ins', 'remember this', 7);
            """)
        }

        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()

        try writer.read { db in
            let columns = Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('insights')"))
            XCTAssertTrue(
                columns.isSuperset(of: ["insight_type", "superseded_by", "last_accessed_at", "access_count"]),
                "\(columns)"
            )
            // Existing rows backfill with safe defaults.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT insight_type FROM insights WHERE id = 'legacy-ins'"), "semantic")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT access_count FROM insights WHERE id = 'legacy-ins'"), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'legacy-ins'"))
        }
    }

    func testSemanticMemoryTablesCreated() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("semantic-tables.sqlite"))
        try writer.migrate()
        try writer.read { db in
            for table in ["insight_embeddings", "semantic_chunks", "embedding_meta"] {
                XCTAssertNotNil(
                    try Int.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", arguments: [table]),
                    "missing table \(table)"
                )
            }
            XCTAssertNotNil(
                try Int.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_semantic_chunks_session'")
            )
        }
    }

    func testMinedRulesTablesAreNotCreatedForNewDatabases() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("mined-rules.sqlite"))
        try writer.migrate()
        try writer.read { db in
            XCTAssertNil(
                try Int.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='mined_rules'")
            )
            XCTAssertNil(
                try Int.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='mined_rules_fts'")
            )
            XCTAssertNil(
                try Int.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_mined_rules_project'")
            )
        }
    }

    func testAuxMigrationSkippedWhenStoredVersionMatches() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("aux-skip.sqlite"))
        try writer.migrate()

        // First migrate records swift_aux_schema_version. Replace session_tools
        // with a legacy `count` shape that would normally trigger a v2 rebuild,
        // then re-run migrate. Because the stored aux version already matches,
        // migrateAuxTablesToV2 short-circuits and leaves the legacy table alone.
        try writer.write { db in
            try db.execute(sql: """
                DROP TABLE session_tools;
                CREATE TABLE session_tools (
                  session_id TEXT NOT NULL,
                  tool_name TEXT NOT NULL,
                  count INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (session_id, tool_name)
                );
            """)
        }

        try writer.migrate()

        try writer.read { db in
            // Legacy `count` column survives because the aux migration was skipped.
            XCTAssertNotNil(try Int.fetchOne(db, sql: "SELECT 1 FROM pragma_table_info('session_tools') WHERE name = 'count'"))
            XCTAssertNil(try Int.fetchOne(db, sql: "SELECT 1 FROM pragma_table_info('session_tools') WHERE name = 'call_count'"))
        }
    }

    func testWriterCreatesDatabaseWithUserOnlyPermissions() throws {
        let path = databasePath("secure.sqlite")
        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()

        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o077, 0)
    }

    func testWriterRepairsLegacyLooseDatabasePermissions() throws {
        let path = databasePath("loose.sqlite")
        FileManager.default.createFile(atPath: path, contents: Data())
        chmod(path, 0o644)

        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()

        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o077, 0)
    }

    func testPreservesExistingSessionRows() throws {
        let path = databasePath("legacy.sqlite")
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  start_time TEXT NOT NULL,
                  cwd TEXT NOT NULL DEFAULT '',
                  file_path TEXT NOT NULL
                );
                INSERT INTO sessions(id, source, start_time, cwd, file_path)
                VALUES ('legacy-1', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/project', '/tmp/session.jsonl');
            """)
        }

        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()

        let rowCount = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE id = 'legacy-1'") ?? 0
        }
        XCTAssertEqual(rowCount, 1)

        let indexedAtColumn = try writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(sessions)")
                .first { ($0["name"] as String) == "indexed_at" }
        }
        XCTAssertNotNil(indexedAtColumn)
        let indexedAt = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT indexed_at FROM sessions WHERE id = 'legacy-1'")
        }
        XCTAssertNotEqual(indexedAt, "")
    }

    func testMigratesLegacyAuxiliaryTablesToCurrentWritableSchema() throws {
        let path = databasePath("legacy-aux.sqlite")
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try seedLegacyAuxiliarySchema(db)
        }

        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()

        try writer.write { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT call_count FROM session_tools WHERE session_id = 'legacy-1'"), 2)
            XCTAssertNil(try Int.fetchOne(db, sql: "SELECT 1 FROM pragma_table_info('session_tools') WHERE name = 'count'"))
            try db.execute(sql: "INSERT INTO session_tools(session_id, tool_name, call_count) VALUES ('legacy-1', 'Edit', 1)")

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT action FROM session_files WHERE session_id = 'legacy-1' AND file_path = '/tmp/file.txt'"),
                "unknown"
            )
            try db.execute(sql: "INSERT INTO session_files(session_id, file_path, action) VALUES ('legacy-1', '/tmp/new.txt', 'read')")

            try db.execute(sql: """
                INSERT INTO logs(level, module, trace_id, span_id, message, error_name, source)
                VALUES ('error', 'ui', 'trace-2', 'span-2', 'failed', 'TestError', 'app')
            """)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT source FROM logs WHERE span_id = 'span-2'"), "app")

            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT module FROM traces WHERE span_id = 'span-1'"), "worker")
            try db.execute(sql: """
                INSERT INTO traces(trace_id, span_id, name, module, start_ts, source)
                VALUES ('trace-2', 'span-new', 'new', 'service', '2026-01-01T00:00:00.000Z', 'daemon')
            """)

            try db.execute(sql: """
                INSERT INTO metrics_hourly(name, type, hour, count, sum, min, max, tags)
                VALUES ('latency', 'histogram', '2026-01-01T00', 1, 2, 2, 2, '{}')
            """)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT type FROM metrics_hourly WHERE name = 'requests'"), "counter")

            try db.execute(sql: """
                INSERT INTO alerts(rule, severity, message)
                VALUES ('cpu', 'warning', 'warn')
            """)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT severity FROM alerts WHERE rule = 'disk'"), "warning")

            try db.execute(sql: """
                INSERT INTO ai_audit_log(caller, operation, prompt_tokens, completion_tokens)
                VALUES ('test', 'complete', 3, 4)
            """)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT total_tokens FROM ai_audit_log WHERE caller = 'legacy'"), 3)

            try db.execute(sql: """
                INSERT INTO git_repos(path, name, session_count, probed_at)
                VALUES ('/repo/new', 'new', 1, '2026-01-01T00:00:00.000Z')
            """)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT probed_at FROM git_repos WHERE path = '/repo'"), "2026-01-01T00:00:00.000Z")

            try db.execute(sql: "INSERT INTO session_costs(session_id, computed_at) VALUES ('legacy-2', NULL)")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT computed_at FROM session_costs WHERE session_id = 'legacy-2'"))

            XCTAssertNotNil(try Int.fetchOne(db, sql: "SELECT 1 FROM pragma_table_info('usage_snapshots') WHERE name = 'limit_value'"))
            XCTAssertNotNil(try Int.fetchOne(db, sql: "SELECT 1 FROM pragma_table_info('usage_snapshots') WHERE name = 'status'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT metric FROM usage_snapshots WHERE source = 'codex'"), "5h token share")

            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT content FROM insights WHERE id = 'active'"), "keep")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT content FROM insights WHERE id = 'deleted'"))
            XCTAssertNil(try Int.fetchOne(db, sql: "SELECT 1 FROM pragma_table_info('insights') WHERE name = 'deleted_at'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT content FROM insights_fts WHERE insight_id = 'deleted'"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'swift_aux_schema_version'"),
                "4"
            )
            // Lifecycle columns are added even when the v2 rebuild path runs first.
            XCTAssertNotNil(try Int.fetchOne(db, sql: "SELECT 1 FROM pragma_table_info('insights') WHERE name = 'superseded_by'"))
        }
    }

    func testMigrationDropsOrphanedAuxRowsInsteadOfFailing() throws {
        let path = databasePath("orphan-aux.sqlite")
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try seedLegacyAuxiliarySchema(db)
            // Aux rows whose session_id has NO matching sessions row. The v2
            // tables declare session_id REFERENCES sessions(id) with
            // foreign_keys=ON, so copying these would raise "FOREIGN KEY
            // constraint failed" and abort the whole migration -> the service
            // exits 70 on every boot with no automatic recovery.
            try db.execute(sql: "INSERT INTO session_tools(session_id, tool_name, count) VALUES ('ghost', 'Read', 9)")
            try db.execute(sql: "INSERT INTO session_files(session_id, file_path, action, count) VALUES ('ghost', '/tmp/x.txt', 'read', 1)")
            try db.execute(sql: "INSERT INTO session_costs(session_id, model, computed_at) VALUES ('ghost', 'gpt', '2026-01-01T00:00:00.000Z')")
        }

        let writer = try EngramDatabaseWriter(path: path)
        // Must NOT throw: orphaned aux rows are filtered out during the rebuild.
        try writer.migrate()

        try writer.write { db in
            XCTAssertNil(
                try Int.fetchOne(db, sql: "SELECT call_count FROM session_tools WHERE session_id = 'ghost'"),
                "orphaned tool row must be dropped, not migrated"
            )
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT action FROM session_files WHERE session_id = 'ghost'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT computed_at FROM session_costs WHERE session_id = 'ghost'"))
            // Legitimate rows are still migrated to the v2 schema.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT call_count FROM session_tools WHERE session_id = 'legacy-1'"), 2)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT computed_at FROM session_costs WHERE session_id = 'legacy-1'"),
                "2026-01-01T00:00:00.000Z"
            )
        }
    }

    private func databasePath(_ name: String) -> String {
        tempDir.appendingPathComponent(name).path
    }

    private func seedLegacyAuxiliarySchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              start_time TEXT NOT NULL,
              cwd TEXT NOT NULL DEFAULT '',
              file_path TEXT NOT NULL
            );
            INSERT INTO sessions(id, source, start_time, cwd, file_path)
            VALUES
              ('legacy-1', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/project', '/tmp/session.jsonl'),
              ('legacy-2', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/project', '/tmp/session-2.jsonl');

            CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO metadata(key, value) VALUES ('schema_version', '1');

            CREATE TABLE session_tools (
              session_id TEXT NOT NULL,
              tool_name TEXT NOT NULL,
              count INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (session_id, tool_name)
            );
            INSERT INTO session_tools(session_id, tool_name, count) VALUES ('legacy-1', 'Read', 2);

            CREATE TABLE session_files (
              session_id TEXT NOT NULL,
              file_path TEXT NOT NULL,
              action TEXT,
              count INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (session_id, file_path, action)
            );
            INSERT INTO session_files(session_id, file_path, action, count) VALUES ('legacy-1', '/tmp/file.txt', NULL, 3);

            CREATE TABLE logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL,
              level TEXT NOT NULL CHECK (level IN ('debug','info','warn','error')),
              module TEXT NOT NULL,
              message TEXT NOT NULL,
              data TEXT,
              trace_id TEXT,
              request_id TEXT,
              request_source TEXT,
              source TEXT NOT NULL DEFAULT 'daemon'
            );
            INSERT INTO logs(ts, level, module, message, trace_id, request_id, source)
            VALUES ('2026-01-01T00:00:00.000Z', 'info', 'legacy', 'hello', 'trace-1', 'req-1', 'daemon');

            CREATE TABLE traces (
              trace_id TEXT NOT NULL,
              span_id TEXT PRIMARY KEY,
              parent_span_id TEXT,
              name TEXT NOT NULL,
              kind TEXT NOT NULL,
              start_ts TEXT NOT NULL,
              end_ts TEXT,
              duration_ms REAL,
              attributes TEXT,
              status TEXT
            );
            INSERT INTO traces(trace_id, span_id, name, kind, start_ts, duration_ms)
            VALUES ('trace-1', 'span-1', 'legacy-span', 'worker', '2026-01-01T00:00:00.000Z', 1.5);

            CREATE TABLE metrics_hourly (
              name TEXT NOT NULL,
              hour TEXT NOT NULL,
              count INTEGER NOT NULL DEFAULT 0,
              sum REAL NOT NULL DEFAULT 0,
              min REAL,
              max REAL,
              p50 REAL,
              p95 REAL,
              p99 REAL,
              PRIMARY KEY (name, hour)
            );
            INSERT INTO metrics_hourly(name, hour, count, sum, min, max, p50, p95, p99)
            VALUES ('requests', '2026-01-01T00', 2, 4, NULL, NULL, 2, 3, 4);

            CREATE TABLE alerts (
              id TEXT PRIMARY KEY,
              rule TEXT NOT NULL,
              severity TEXT NOT NULL,
              message TEXT NOT NULL,
              data TEXT,
              ts TEXT NOT NULL,
              resolved_at TEXT
            );
            INSERT INTO alerts(id, rule, severity, message, data, ts)
            VALUES ('alert-1', 'disk', 'low', 'legacy alert', '{}', '2026-01-01T00:00:00.000Z');

            CREATE TABLE ai_audit_log (
              id TEXT PRIMARY KEY,
              ts TEXT NOT NULL,
              caller TEXT NOT NULL,
              model TEXT,
              request TEXT,
              response TEXT,
              input_tokens INTEGER DEFAULT 0,
              output_tokens INTEGER DEFAULT 0,
              cost_usd REAL DEFAULT 0,
              session_id TEXT,
              trace_id TEXT,
              error TEXT
            );
            INSERT INTO ai_audit_log(id, ts, caller, model, request, response, input_tokens, output_tokens)
            VALUES ('audit-1', '2026-01-01T00:00:00.000Z', 'legacy', 'gpt', '{}', '{}', 1, 2);

            CREATE TABLE git_repos (
              path TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              branch TEXT,
              dirty_count INTEGER DEFAULT 0,
              untracked_count INTEGER DEFAULT 0,
              unpushed_count INTEGER DEFAULT 0,
              last_commit_hash TEXT,
              last_commit_msg TEXT,
              last_commit_at TEXT,
              updated_at TEXT NOT NULL
            );
            INSERT INTO git_repos(path, name, branch, updated_at)
            VALUES ('/repo', 'repo', 'main', '2026-01-01T00:00:00.000Z');

            CREATE TABLE session_costs (
              session_id TEXT PRIMARY KEY,
              model TEXT,
              input_tokens INTEGER DEFAULT 0,
              output_tokens INTEGER DEFAULT 0,
              cache_read_tokens INTEGER DEFAULT 0,
              cache_creation_tokens INTEGER DEFAULT 0,
              cost_usd REAL DEFAULT 0,
              computed_at TEXT NOT NULL
            );
            INSERT INTO session_costs(session_id, model, computed_at)
            VALUES ('legacy-1', 'gpt', '2026-01-01T00:00:00.000Z');

            CREATE TABLE usage_snapshots (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source TEXT NOT NULL,
              metric TEXT NOT NULL,
              value REAL NOT NULL,
              unit TEXT DEFAULT '%',
              reset_at TEXT,
              collected_at TEXT NOT NULL
            );
            INSERT INTO usage_snapshots(source, metric, value, unit, reset_at, collected_at)
            VALUES ('codex', '5h token share', 42.5, '%', NULL, '2026-01-01T00:00:00.000Z');

            CREATE TABLE insights (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              wing TEXT,
              room TEXT,
              source_session_id TEXT,
              importance INTEGER DEFAULT 5,
              has_embedding INTEGER DEFAULT 0,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              deleted_at TEXT
            );
            CREATE VIRTUAL TABLE insights_fts USING fts5(insight_id UNINDEXED, content);
            INSERT INTO insights(id, content, deleted_at) VALUES ('active', 'keep', NULL), ('deleted', 'drop', '2026-01-01T00:00:00.000Z');
            INSERT INTO insights_fts(insight_id, content) VALUES ('active', 'keep'), ('deleted', 'drop');
        """)
    }
}
