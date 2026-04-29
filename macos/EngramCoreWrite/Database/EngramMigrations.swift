import Foundation
import GRDB

enum EngramMigrations {
    private static let auxSchemaVersion = "2"

    static func createOrUpdateBaseSchema(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sessions (
              id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              start_time TEXT NOT NULL,
              end_time TEXT,
              cwd TEXT NOT NULL DEFAULT '',
              project TEXT,
              model TEXT,
              message_count INTEGER NOT NULL DEFAULT 0,
              user_message_count INTEGER NOT NULL DEFAULT 0,
              assistant_message_count INTEGER NOT NULL DEFAULT 0,
              tool_message_count INTEGER NOT NULL DEFAULT 0,
              system_message_count INTEGER NOT NULL DEFAULT 0,
              summary TEXT,
              summary_message_count INTEGER,
              file_path TEXT NOT NULL,
              size_bytes INTEGER NOT NULL DEFAULT 0,
              indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
              agent_role TEXT,
              hidden_at TEXT,
              custom_name TEXT,
              origin TEXT DEFAULT 'local',
              authoritative_node TEXT,
              source_locator TEXT,
              sync_version INTEGER NOT NULL DEFAULT 0,
              snapshot_hash TEXT,
              tier TEXT,
              generated_title TEXT,
              quality_score INTEGER DEFAULT 0,
              parent_session_id TEXT,
              suggested_parent_id TEXT,
              link_source TEXT,
              link_checked_at TEXT,
              orphan_status TEXT,
              orphan_since TEXT,
              orphan_reason TEXT
            );
        """)

        try addSessionColumnsIfNeeded(db)

        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
            CREATE INDEX IF NOT EXISTS idx_sessions_start_time ON sessions(start_time);
            CREATE INDEX IF NOT EXISTS idx_sessions_cwd ON sessions(cwd);
            CREATE INDEX IF NOT EXISTS idx_sessions_file_path ON sessions(file_path);
            CREATE INDEX IF NOT EXISTS idx_sessions_agent_role ON sessions(agent_role);
            CREATE INDEX IF NOT EXISTS idx_sessions_tier ON sessions(tier);
            CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id, start_time DESC);
            CREATE INDEX IF NOT EXISTS idx_sessions_suggested_parent ON sessions(suggested_parent_id, start_time DESC);
            CREATE INDEX IF NOT EXISTS idx_sessions_orphan_status ON sessions(orphan_status);

            CREATE TRIGGER IF NOT EXISTS trg_sessions_parent_cascade
            AFTER DELETE ON sessions
            BEGIN
              UPDATE sessions SET parent_session_id = NULL, link_source = NULL, tier = NULL
                WHERE parent_session_id = OLD.id;
              UPDATE sessions SET suggested_parent_id = NULL
                WHERE suggested_parent_id = OLD.id;
            END;

            CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
              session_id UNINDEXED,
              content,
              tokenize='trigram case_sensitive 0'
            );

            CREATE TABLE IF NOT EXISTS sync_state (
              peer_name TEXT PRIMARY KEY,
              last_sync_time TEXT NOT NULL,
              last_sync_session_id TEXT
            );

            CREATE TABLE IF NOT EXISTS metadata (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS project_aliases (
              alias TEXT NOT NULL,
              canonical TEXT NOT NULL,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              PRIMARY KEY (alias, canonical)
            );

            CREATE TABLE IF NOT EXISTS session_local_state (
              session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
              hidden_at TEXT,
              custom_name TEXT,
              local_readable_path TEXT
            );

            CREATE TABLE IF NOT EXISTS session_index_jobs (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              job_kind TEXT NOT NULL,
              target_sync_version INTEGER NOT NULL,
              status TEXT NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_session_index_jobs_status ON session_index_jobs(status);
            CREATE INDEX IF NOT EXISTS idx_session_index_jobs_session_id ON session_index_jobs(session_id);

            CREATE TABLE IF NOT EXISTS migration_log (
              id TEXT PRIMARY KEY,
              old_path TEXT NOT NULL,
              new_path TEXT NOT NULL,
              old_basename TEXT NOT NULL,
              new_basename TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'fs_pending',
              files_patched INTEGER NOT NULL DEFAULT 0,
              occurrences INTEGER NOT NULL DEFAULT 0,
              sessions_updated INTEGER NOT NULL DEFAULT 0,
              alias_created INTEGER NOT NULL DEFAULT 0,
              cc_dir_renamed INTEGER NOT NULL DEFAULT 0,
              started_at TEXT NOT NULL,
              finished_at TEXT,
              dry_run INTEGER NOT NULL DEFAULT 0,
              rolled_back_of TEXT,
              audit_note TEXT,
              archived INTEGER NOT NULL DEFAULT 0,
              actor TEXT NOT NULL DEFAULT 'cli',
              detail TEXT,
              error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_migration_log_started_at ON migration_log(started_at DESC);
            CREATE INDEX IF NOT EXISTS idx_migration_log_paths ON migration_log(old_path, new_path);
            CREATE INDEX IF NOT EXISTS idx_migration_log_state ON migration_log(state);

            CREATE TABLE IF NOT EXISTS usage_snapshots (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source TEXT NOT NULL,
              metric TEXT NOT NULL,
              value REAL NOT NULL,
              unit TEXT DEFAULT '%',
              reset_at TEXT,
              collected_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_usage_latest ON usage_snapshots(source, metric, collected_at DESC);

            CREATE TABLE IF NOT EXISTS git_repos (
              path TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              branch TEXT,
              dirty_count INTEGER DEFAULT 0,
              untracked_count INTEGER DEFAULT 0,
              unpushed_count INTEGER DEFAULT 0,
              last_commit_hash TEXT,
              last_commit_msg TEXT,
              last_commit_at TEXT,
              session_count INTEGER DEFAULT 0,
              probed_at TEXT
            );

            CREATE TABLE IF NOT EXISTS session_costs (
              session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
              model TEXT,
              input_tokens INTEGER DEFAULT 0,
              output_tokens INTEGER DEFAULT 0,
              cache_read_tokens INTEGER DEFAULT 0,
              cache_creation_tokens INTEGER DEFAULT 0,
              cost_usd REAL DEFAULT 0,
              computed_at TEXT
            );

            CREATE TABLE IF NOT EXISTS session_tools (
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              tool_name TEXT NOT NULL,
              call_count INTEGER DEFAULT 0,
              PRIMARY KEY (session_id, tool_name)
            );
            CREATE INDEX IF NOT EXISTS idx_session_tools_name ON session_tools(tool_name);

            CREATE TABLE IF NOT EXISTS session_files (
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              file_path TEXT NOT NULL,
              action TEXT NOT NULL,
              count INTEGER DEFAULT 1,
              PRIMARY KEY (session_id, file_path, action)
            );
            CREATE INDEX IF NOT EXISTS idx_session_files_path ON session_files(file_path);

            CREATE TABLE IF NOT EXISTS logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
              level TEXT NOT NULL CHECK (level IN ('debug','info','warn','error')),
              module TEXT NOT NULL,
              trace_id TEXT,
              span_id TEXT,
              message TEXT NOT NULL,
              data TEXT,
              error_name TEXT,
              error_message TEXT,
              error_stack TEXT,
              source TEXT NOT NULL CHECK (source IN ('daemon', 'app'))
            );
            CREATE INDEX IF NOT EXISTS idx_logs_ts ON logs(ts);
            CREATE INDEX IF NOT EXISTS idx_logs_level_ts ON logs(level, ts);
            CREATE INDEX IF NOT EXISTS idx_logs_module ON logs(module);
            CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON logs(trace_id);
            CREATE INDEX IF NOT EXISTS idx_logs_source_ts ON logs(source, ts);

            CREATE TABLE IF NOT EXISTS traces (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              trace_id TEXT NOT NULL,
              span_id TEXT NOT NULL UNIQUE,
              parent_span_id TEXT,
              name TEXT NOT NULL,
              module TEXT NOT NULL,
              start_ts TEXT NOT NULL,
              end_ts TEXT,
              duration_ms INTEGER,
              status TEXT NOT NULL DEFAULT 'ok',
              attributes TEXT,
              source TEXT NOT NULL CHECK (source IN ('daemon', 'app'))
            );
            CREATE INDEX IF NOT EXISTS idx_traces_span_id ON traces(span_id);
            CREATE INDEX IF NOT EXISTS idx_traces_trace_id ON traces(trace_id);
            CREATE INDEX IF NOT EXISTS idx_traces_name ON traces(name);
            CREATE INDEX IF NOT EXISTS idx_traces_start_ts ON traces(start_ts);
            CREATE INDEX IF NOT EXISTS idx_traces_duration ON traces(duration_ms);

            CREATE TABLE IF NOT EXISTS metrics (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              type TEXT NOT NULL,
              value REAL NOT NULL,
              tags TEXT,
              ts TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_metrics_name_ts ON metrics(name, ts);
            CREATE INDEX IF NOT EXISTS idx_metrics_name_type ON metrics(name, type);

            CREATE TABLE IF NOT EXISTS metrics_hourly (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              type TEXT NOT NULL,
              hour TEXT NOT NULL,
              count INTEGER NOT NULL,
              sum REAL NOT NULL,
              min REAL NOT NULL,
              max REAL NOT NULL,
              p95 REAL,
              tags TEXT,
              UNIQUE(name, type, hour, tags)
            );
            CREATE INDEX IF NOT EXISTS idx_metrics_hourly_name ON metrics_hourly(name, hour);

            CREATE TABLE IF NOT EXISTS alerts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
              rule TEXT NOT NULL,
              severity TEXT NOT NULL CHECK (severity IN ('warning','critical')),
              message TEXT NOT NULL,
              value REAL,
              threshold REAL,
              dismissed_at TEXT,
              resolved_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_alerts_ts ON alerts(ts);
            CREATE INDEX IF NOT EXISTS idx_alerts_rule ON alerts(rule, ts);

            CREATE TABLE IF NOT EXISTS ai_audit_log (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
              trace_id TEXT,
              caller TEXT NOT NULL,
              operation TEXT NOT NULL,
              request_source TEXT,
              method TEXT,
              url TEXT,
              status_code INTEGER,
              duration_ms INTEGER,
              model TEXT,
              provider TEXT,
              prompt_tokens INTEGER,
              completion_tokens INTEGER,
              total_tokens INTEGER,
              request_body TEXT,
              response_body TEXT,
              error TEXT,
              session_id TEXT,
              meta TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_ai_audit_ts ON ai_audit_log(ts);
            CREATE INDEX IF NOT EXISTS idx_ai_audit_caller ON ai_audit_log(caller, ts);
            CREATE INDEX IF NOT EXISTS idx_ai_audit_model ON ai_audit_log(model, ts);
            CREATE INDEX IF NOT EXISTS idx_ai_audit_session ON ai_audit_log(session_id);
            CREATE INDEX IF NOT EXISTS idx_ai_audit_trace ON ai_audit_log(trace_id);

            CREATE TABLE IF NOT EXISTS insights (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              wing TEXT,
              room TEXT,
              source_session_id TEXT,
              importance INTEGER DEFAULT 5,
              has_embedding INTEGER DEFAULT 0,
              created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_insights_wing ON insights(wing);
            CREATE VIRTUAL TABLE IF NOT EXISTS insights_fts USING fts5(
              insight_id UNINDEXED,
              content
            );

            CREATE TABLE IF NOT EXISTS memory_insights (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              wing TEXT,
              room TEXT,
              source_session_id TEXT,
              importance INTEGER DEFAULT 5,
              model TEXT NOT NULL DEFAULT 'unknown',
              created_at TEXT DEFAULT (datetime('now')),
              deleted_at TEXT
            );
        """)
        try migrateAuxTablesToV2(db)
    }

    static func writeSchemaMetadata(_ db: GRDB.Database) throws {
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('schema_version', '1')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
    }

    private static func migrateAuxTablesToV2(_ db: GRDB.Database) throws {
        try migrateSessionToolsToV2(db)
        try migrateSessionFilesToV2(db)
        try migrateLogsToV2(db)
        try migrateTracesToV2(db)
        try migrateMetricsHourlyToV2(db)
        try migrateAlertsToV2(db)
        try migrateAIAuditLogToV2(db)
        try migrateGitReposToV2(db)
        try migrateSessionCostsToV2(db)
        try migrateInsightsToV2(db)
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('swift_aux_schema_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [auxSchemaVersion]
        )
    }

    private static func addSessionColumnsIfNeeded(_ db: GRDB.Database) throws {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions)")
        let existing = Set(rows.map { $0["name"] as String })
        let columns: [(String, String)] = [
            ("end_time", "TEXT"),
            ("project", "TEXT"),
            ("model", "TEXT"),
            ("message_count", "INTEGER NOT NULL DEFAULT 0"),
            ("user_message_count", "INTEGER NOT NULL DEFAULT 0"),
            ("assistant_message_count", "INTEGER NOT NULL DEFAULT 0"),
            ("tool_message_count", "INTEGER NOT NULL DEFAULT 0"),
            ("system_message_count", "INTEGER NOT NULL DEFAULT 0"),
            ("summary", "TEXT"),
            ("summary_message_count", "INTEGER"),
            ("size_bytes", "INTEGER NOT NULL DEFAULT 0"),
            ("indexed_at", "TEXT NOT NULL DEFAULT ''"),
            ("agent_role", "TEXT"),
            ("hidden_at", "TEXT"),
            ("custom_name", "TEXT"),
            ("origin", "TEXT DEFAULT 'local'"),
            ("authoritative_node", "TEXT"),
            ("source_locator", "TEXT"),
            ("sync_version", "INTEGER NOT NULL DEFAULT 0"),
            ("snapshot_hash", "TEXT"),
            ("tier", "TEXT"),
            ("generated_title", "TEXT"),
            ("quality_score", "INTEGER DEFAULT 0"),
            ("parent_session_id", "TEXT"),
            ("suggested_parent_id", "TEXT"),
            ("link_source", "TEXT"),
            ("link_checked_at", "TEXT"),
            ("orphan_status", "TEXT"),
            ("orphan_since", "TEXT"),
            ("orphan_reason", "TEXT"),
        ]
        for (name, definition) in columns where !existing.contains(name) {
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN \(name) \(definition)")
        }
    }

    private static func migrateSessionToolsToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "session_tools") else { return }
        let columns = try tableColumns(db, "session_tools")
        guard columns["call_count"] == nil || columns["count"] != nil else { return }
        let countExpr = columns["call_count"] != nil ? "COALESCE(call_count, 0)" :
            (columns["count"] != nil ? "COALESCE(count, 0)" : "0")

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_session_tools_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_session_tools_v2 (
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              tool_name TEXT NOT NULL,
              call_count INTEGER DEFAULT 0,
              PRIMARY KEY (session_id, tool_name)
            )
        """)
        try db.execute(sql: """
            INSERT OR REPLACE INTO __engram_session_tools_v2(session_id, tool_name, call_count)
            SELECT session_id, tool_name, \(countExpr)
            FROM session_tools
            WHERE session_id IS NOT NULL AND tool_name IS NOT NULL
        """)
        try replaceTable(db, old: "session_tools", replacement: "__engram_session_tools_v2")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_session_tools_name ON session_tools(tool_name)")
    }

    private static func migrateSessionFilesToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "session_files") else { return }
        let columns = try tableColumns(db, "session_files")
        guard columns["action"]?.notnull != 1 || normalizeDefault(columns["count"]?.defaultValue) != "1" else { return }
        let countExpr = columns["count"] != nil ? "COALESCE(count, 1)" : "1"

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_session_files_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_session_files_v2 (
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              file_path TEXT NOT NULL,
              action TEXT NOT NULL,
              count INTEGER DEFAULT 1,
              PRIMARY KEY (session_id, file_path, action)
            )
        """)
        try db.execute(sql: """
            INSERT OR REPLACE INTO __engram_session_files_v2(session_id, file_path, action, count)
            SELECT session_id, file_path, COALESCE(action, 'unknown'), SUM(\(countExpr))
            FROM session_files
            WHERE session_id IS NOT NULL AND file_path IS NOT NULL
            GROUP BY session_id, file_path, COALESCE(action, 'unknown')
        """)
        try replaceTable(db, old: "session_files", replacement: "__engram_session_files_v2")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_session_files_path ON session_files(file_path)")
    }

    private static func migrateLogsToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "logs") else { return }
        let columns = try tableColumns(db, "logs")
        let needsMigration = ["span_id", "error_name", "error_message", "error_stack"].contains { columns[$0] == nil } ||
            columns["request_id"] != nil ||
            columns["request_source"] != nil ||
            columns["source"]?.notnull != 1
        guard needsMigration else { return }

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_logs_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_logs_v2 (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
              level TEXT NOT NULL CHECK (level IN ('debug','info','warn','error')),
              module TEXT NOT NULL,
              trace_id TEXT,
              span_id TEXT,
              message TEXT NOT NULL,
              data TEXT,
              error_name TEXT,
              error_message TEXT,
              error_stack TEXT,
              source TEXT NOT NULL CHECK (source IN ('daemon', 'app'))
            )
        """)
        try db.execute(sql: """
            INSERT INTO __engram_logs_v2(
              id, ts, level, module, trace_id, span_id, message, data,
              error_name, error_message, error_stack, source
            )
            SELECT
              \(columnExpr(columns, "id", fallback: "NULL")),
              COALESCE(\(columnExpr(columns, "ts", fallback: "NULL")), strftime('%Y-%m-%dT%H:%M:%f', 'now')),
              CASE WHEN \(columnExpr(columns, "level", fallback: "'info'")) IN ('debug','info','warn','error')
                THEN \(columnExpr(columns, "level", fallback: "'info'")) ELSE 'info' END,
              COALESCE(\(columnExpr(columns, "module", fallback: "NULL")), 'unknown'),
              \(columnExpr(columns, "trace_id", fallback: "NULL")),
              \(columnExpr(columns, "span_id", fallback: "NULL")),
              COALESCE(\(columnExpr(columns, "message", fallback: "NULL")), ''),
              \(columnExpr(columns, "data", fallback: "NULL")),
              \(columnExpr(columns, "error_name", fallback: "NULL")),
              \(columnExpr(columns, "error_message", fallback: "NULL")),
              \(columnExpr(columns, "error_stack", fallback: "NULL")),
              CASE WHEN \(columnExpr(columns, "source", fallback: "'daemon'")) IN ('daemon','app')
                THEN \(columnExpr(columns, "source", fallback: "'daemon'")) ELSE 'daemon' END
            FROM logs
        """)
        try replaceTable(db, old: "logs", replacement: "__engram_logs_v2")
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_logs_ts ON logs(ts);
            CREATE INDEX IF NOT EXISTS idx_logs_level_ts ON logs(level, ts);
            CREATE INDEX IF NOT EXISTS idx_logs_module ON logs(module);
            CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON logs(trace_id);
            CREATE INDEX IF NOT EXISTS idx_logs_source_ts ON logs(source, ts);
        """)
    }

    private static func migrateTracesToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "traces") else { return }
        let columns = try tableColumns(db, "traces")
        let needsMigration = columns["id"] == nil || columns["module"] == nil || columns["kind"] != nil ||
            columns["source"] == nil || columns["status"]?.notnull != 1
        guard needsMigration else { return }

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_traces_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_traces_v2 (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              trace_id TEXT NOT NULL,
              span_id TEXT NOT NULL UNIQUE,
              parent_span_id TEXT,
              name TEXT NOT NULL,
              module TEXT NOT NULL,
              start_ts TEXT NOT NULL,
              end_ts TEXT,
              duration_ms INTEGER,
              status TEXT NOT NULL DEFAULT 'ok',
              attributes TEXT,
              source TEXT NOT NULL CHECK (source IN ('daemon', 'app'))
            )
        """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO __engram_traces_v2(
              trace_id, span_id, parent_span_id, name, module, start_ts, end_ts,
              duration_ms, status, attributes, source
            )
            SELECT
              COALESCE(\(columnExpr(columns, "trace_id", fallback: "NULL")), ''),
              COALESCE(\(columnExpr(columns, "span_id", fallback: "NULL")), lower(hex(randomblob(16)))),
              \(columnExpr(columns, "parent_span_id", fallback: "NULL")),
              COALESCE(\(columnExpr(columns, "name", fallback: "NULL")), 'unknown'),
              COALESCE(\(columnExpr(columns, "module", fallback: columnExpr(columns, "kind", fallback: "NULL"))), 'unknown'),
              COALESCE(\(columnExpr(columns, "start_ts", fallback: "NULL")), strftime('%Y-%m-%dT%H:%M:%f', 'now')),
              \(columnExpr(columns, "end_ts", fallback: "NULL")),
              CAST(\(columnExpr(columns, "duration_ms", fallback: "NULL")) AS INTEGER),
              COALESCE(\(columnExpr(columns, "status", fallback: "NULL")), 'ok'),
              \(columnExpr(columns, "attributes", fallback: "NULL")),
              CASE WHEN \(columnExpr(columns, "source", fallback: "'daemon'")) IN ('daemon','app')
                THEN \(columnExpr(columns, "source", fallback: "'daemon'")) ELSE 'daemon' END
            FROM traces
        """)
        try replaceTable(db, old: "traces", replacement: "__engram_traces_v2")
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_traces_span_id ON traces(span_id);
            CREATE INDEX IF NOT EXISTS idx_traces_trace_id ON traces(trace_id);
            CREATE INDEX IF NOT EXISTS idx_traces_name ON traces(name);
            CREATE INDEX IF NOT EXISTS idx_traces_start_ts ON traces(start_ts);
            CREATE INDEX IF NOT EXISTS idx_traces_duration ON traces(duration_ms);
        """)
    }

    private static func migrateMetricsHourlyToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "metrics_hourly") else { return }
        let columns = try tableColumns(db, "metrics_hourly")
        let hasLegacyPercentiles = columns["p50"] != nil || columns["p99"] != nil
        let hasV2Identity = columns["id"] != nil && columns["type"] != nil && columns["tags"] != nil
        let hasV2Bounds = columns["min"]?.notnull == 1 && columns["max"]?.notnull == 1
        let needsMigration = !hasV2Identity || !hasV2Bounds || hasLegacyPercentiles
        guard needsMigration else { return }

        let typeExpr = columnExpr(columns, "type", fallback: "NULL")
        let countExpr = columnExpr(columns, "count", fallback: "NULL")
        let sumExpr = columnExpr(columns, "sum", fallback: "NULL")
        let minExpr = columnExpr(columns, "min", fallback: "NULL")
        let maxExpr = columnExpr(columns, "max", fallback: "NULL")
        let p95Expr = columnExpr(columns, "p95", fallback: "NULL")
        let tagsExpr = columnExpr(columns, "tags", fallback: "NULL")

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_metrics_hourly_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_metrics_hourly_v2 (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              type TEXT NOT NULL,
              hour TEXT NOT NULL,
              count INTEGER NOT NULL,
              sum REAL NOT NULL,
              min REAL NOT NULL,
              max REAL NOT NULL,
              p95 REAL,
              tags TEXT,
              UNIQUE(name, type, hour, tags)
            )
        """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO __engram_metrics_hourly_v2(name, type, hour, count, sum, min, max, p95, tags)
            SELECT
              name,
              COALESCE(\(typeExpr), 'counter'),
              hour,
              COALESCE(\(countExpr), 0),
              COALESCE(\(sumExpr), 0),
              COALESCE(\(minExpr), 0),
              COALESCE(\(maxExpr), 0),
              \(p95Expr),
              \(tagsExpr)
            FROM metrics_hourly
            WHERE name IS NOT NULL AND hour IS NOT NULL
        """)
        try replaceTable(db, old: "metrics_hourly", replacement: "__engram_metrics_hourly_v2")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_metrics_hourly_name ON metrics_hourly(name, hour)")
    }

    private static func migrateAlertsToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "alerts") else { return }
        let columns = try tableColumns(db, "alerts")
        let needsMigration = columns["id"]?.type.uppercased().contains("INTEGER") != true ||
            columns["data"] != nil || columns["value"] == nil || columns["threshold"] == nil ||
            columns["dismissed_at"] == nil
        guard needsMigration else { return }

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_alerts_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_alerts_v2 (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
              rule TEXT NOT NULL,
              severity TEXT NOT NULL CHECK (severity IN ('warning','critical')),
              message TEXT NOT NULL,
              value REAL,
              threshold REAL,
              dismissed_at TEXT,
              resolved_at TEXT
            )
        """)
        try db.execute(sql: """
            INSERT INTO __engram_alerts_v2(ts, rule, severity, message, value, threshold, dismissed_at, resolved_at)
            SELECT
              COALESCE(\(columnExpr(columns, "ts", fallback: "NULL")), strftime('%Y-%m-%dT%H:%M:%f','now')),
              COALESCE(\(columnExpr(columns, "rule", fallback: "NULL")), 'unknown'),
              CASE
                WHEN \(columnExpr(columns, "severity", fallback: "'warning'")) IN ('critical', 'error', 'high') THEN 'critical'
                ELSE 'warning'
              END,
              COALESCE(\(columnExpr(columns, "message", fallback: "NULL")), ''),
              \(columnExpr(columns, "value", fallback: "NULL")),
              \(columnExpr(columns, "threshold", fallback: "NULL")),
              \(columnExpr(columns, "dismissed_at", fallback: "NULL")),
              \(columnExpr(columns, "resolved_at", fallback: "NULL"))
            FROM alerts
        """)
        try replaceTable(db, old: "alerts", replacement: "__engram_alerts_v2")
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_alerts_ts ON alerts(ts);
            CREATE INDEX IF NOT EXISTS idx_alerts_rule ON alerts(rule, ts);
        """)
    }

    private static func migrateAIAuditLogToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "ai_audit_log") else { return }
        let columns = try tableColumns(db, "ai_audit_log")
        let needsMigration = columns["id"]?.type.uppercased().contains("INTEGER") != true ||
            columns["request"] != nil || columns["response"] != nil || columns["operation"] == nil ||
            columns["request_body"] == nil || columns["prompt_tokens"] == nil
        guard needsMigration else { return }

        let promptExpr = columnExpr(columns, "prompt_tokens", fallback: columnExpr(columns, "input_tokens", fallback: "NULL"))
        let completionExpr = columnExpr(columns, "completion_tokens", fallback: columnExpr(columns, "output_tokens", fallback: "NULL"))

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_ai_audit_log_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_ai_audit_log_v2 (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
              trace_id TEXT,
              caller TEXT NOT NULL,
              operation TEXT NOT NULL,
              request_source TEXT,
              method TEXT,
              url TEXT,
              status_code INTEGER,
              duration_ms INTEGER,
              model TEXT,
              provider TEXT,
              prompt_tokens INTEGER,
              completion_tokens INTEGER,
              total_tokens INTEGER,
              request_body TEXT,
              response_body TEXT,
              error TEXT,
              session_id TEXT,
              meta TEXT
            )
        """)
        try db.execute(sql: """
            INSERT INTO __engram_ai_audit_log_v2(
              ts, trace_id, caller, operation, request_source, method, url, status_code,
              duration_ms, model, provider, prompt_tokens, completion_tokens, total_tokens,
              request_body, response_body, error, session_id, meta
            )
            SELECT
              COALESCE(\(columnExpr(columns, "ts", fallback: "NULL")), strftime('%Y-%m-%dT%H:%M:%f','now')),
              \(columnExpr(columns, "trace_id", fallback: "NULL")),
              COALESCE(\(columnExpr(columns, "caller", fallback: "NULL")), 'unknown'),
              COALESCE(\(columnExpr(columns, "operation", fallback: "NULL")), 'unknown'),
              \(columnExpr(columns, "request_source", fallback: "NULL")),
              \(columnExpr(columns, "method", fallback: "NULL")),
              \(columnExpr(columns, "url", fallback: "NULL")),
              \(columnExpr(columns, "status_code", fallback: "NULL")),
              \(columnExpr(columns, "duration_ms", fallback: "NULL")),
              \(columnExpr(columns, "model", fallback: "NULL")),
              \(columnExpr(columns, "provider", fallback: "NULL")),
              \(promptExpr),
              \(completionExpr),
              CASE
                WHEN \(promptExpr) IS NULL AND \(completionExpr) IS NULL THEN \(columnExpr(columns, "total_tokens", fallback: "NULL"))
                ELSE COALESCE(\(promptExpr), 0) + COALESCE(\(completionExpr), 0)
              END,
              \(columnExpr(columns, "request_body", fallback: columnExpr(columns, "request", fallback: "NULL"))),
              \(columnExpr(columns, "response_body", fallback: columnExpr(columns, "response", fallback: "NULL"))),
              \(columnExpr(columns, "error", fallback: "NULL")),
              \(columnExpr(columns, "session_id", fallback: "NULL")),
              \(columnExpr(columns, "meta", fallback: "NULL"))
            FROM ai_audit_log
        """)
        try replaceTable(db, old: "ai_audit_log", replacement: "__engram_ai_audit_log_v2")
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_ai_audit_ts ON ai_audit_log(ts);
            CREATE INDEX IF NOT EXISTS idx_ai_audit_caller ON ai_audit_log(caller, ts);
            CREATE INDEX IF NOT EXISTS idx_ai_audit_model ON ai_audit_log(model, ts);
            CREATE INDEX IF NOT EXISTS idx_ai_audit_session ON ai_audit_log(session_id);
            CREATE INDEX IF NOT EXISTS idx_ai_audit_trace ON ai_audit_log(trace_id);
        """)
    }

    private static func migrateGitReposToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "git_repos") else { return }
        let columns = try tableColumns(db, "git_repos")
        let needsMigration = columns["updated_at"] != nil || columns["session_count"] == nil || columns["probed_at"] == nil
        guard needsMigration else { return }

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_git_repos_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_git_repos_v2 (
              path TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              branch TEXT,
              dirty_count INTEGER DEFAULT 0,
              untracked_count INTEGER DEFAULT 0,
              unpushed_count INTEGER DEFAULT 0,
              last_commit_hash TEXT,
              last_commit_msg TEXT,
              last_commit_at TEXT,
              session_count INTEGER DEFAULT 0,
              probed_at TEXT
            )
        """)
        try db.execute(sql: """
            INSERT OR REPLACE INTO __engram_git_repos_v2(
              path, name, branch, dirty_count, untracked_count, unpushed_count,
              last_commit_hash, last_commit_msg, last_commit_at, session_count, probed_at
            )
            SELECT
              path,
              COALESCE(\(columnExpr(columns, "name", fallback: "NULL")), path),
              \(columnExpr(columns, "branch", fallback: "NULL")),
              COALESCE(\(columnExpr(columns, "dirty_count", fallback: "NULL")), 0),
              COALESCE(\(columnExpr(columns, "untracked_count", fallback: "NULL")), 0),
              COALESCE(\(columnExpr(columns, "unpushed_count", fallback: "NULL")), 0),
              \(columnExpr(columns, "last_commit_hash", fallback: "NULL")),
              \(columnExpr(columns, "last_commit_msg", fallback: "NULL")),
              \(columnExpr(columns, "last_commit_at", fallback: "NULL")),
              COALESCE(\(columnExpr(columns, "session_count", fallback: "NULL")), 0),
              \(columnExpr(columns, "probed_at", fallback: columnExpr(columns, "updated_at", fallback: "NULL")))
            FROM git_repos
            WHERE path IS NOT NULL
        """)
        try replaceTable(db, old: "git_repos", replacement: "__engram_git_repos_v2")
    }

    private static func migrateSessionCostsToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "session_costs") else { return }
        let columns = try tableColumns(db, "session_costs")
        guard columns["computed_at"]?.notnull == 1 else { return }

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_session_costs_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_session_costs_v2 (
              session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
              model TEXT,
              input_tokens INTEGER DEFAULT 0,
              output_tokens INTEGER DEFAULT 0,
              cache_read_tokens INTEGER DEFAULT 0,
              cache_creation_tokens INTEGER DEFAULT 0,
              cost_usd REAL DEFAULT 0,
              computed_at TEXT
            )
        """)
        try db.execute(sql: """
            INSERT OR REPLACE INTO __engram_session_costs_v2(
              session_id, model, input_tokens, output_tokens, cache_read_tokens,
              cache_creation_tokens, cost_usd, computed_at
            )
            SELECT
              session_id,
              \(columnExpr(columns, "model", fallback: "NULL")),
              COALESCE(\(columnExpr(columns, "input_tokens", fallback: "NULL")), 0),
              COALESCE(\(columnExpr(columns, "output_tokens", fallback: "NULL")), 0),
              COALESCE(\(columnExpr(columns, "cache_read_tokens", fallback: "NULL")), 0),
              COALESCE(\(columnExpr(columns, "cache_creation_tokens", fallback: "NULL")), 0),
              COALESCE(\(columnExpr(columns, "cost_usd", fallback: "NULL")), 0),
              \(columnExpr(columns, "computed_at", fallback: "NULL"))
            FROM session_costs
            WHERE session_id IS NOT NULL
        """)
        try replaceTable(db, old: "session_costs", replacement: "__engram_session_costs_v2")
    }

    private static func migrateInsightsToV2(_ db: GRDB.Database) throws {
        guard try tableExists(db, "insights") else { return }
        let columns = try tableColumns(db, "insights")
        guard columns["deleted_at"] != nil || columns["created_at"]?.notnull == 1 else { return }

        if columns["deleted_at"] != nil, try tableExists(db, "insights_fts") {
            try db.execute(sql: """
                DELETE FROM insights_fts
                WHERE insight_id IN (SELECT id FROM insights WHERE deleted_at IS NOT NULL)
            """)
        }

        try db.execute(sql: "DROP TABLE IF EXISTS __engram_insights_v2")
        try db.execute(sql: """
            CREATE TABLE __engram_insights_v2 (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              wing TEXT,
              room TEXT,
              source_session_id TEXT,
              importance INTEGER DEFAULT 5,
              has_embedding INTEGER DEFAULT 0,
              created_at TEXT DEFAULT (datetime('now'))
            )
        """)
        try db.execute(sql: """
            INSERT OR REPLACE INTO __engram_insights_v2(
              id, content, wing, room, source_session_id, importance, has_embedding, created_at
            )
            SELECT
              id,
              content,
              \(columnExpr(columns, "wing", fallback: "NULL")),
              \(columnExpr(columns, "room", fallback: "NULL")),
              \(columnExpr(columns, "source_session_id", fallback: "NULL")),
              COALESCE(\(columnExpr(columns, "importance", fallback: "NULL")), 5),
              COALESCE(\(columnExpr(columns, "has_embedding", fallback: "NULL")), 0),
              \(columnExpr(columns, "created_at", fallback: "NULL"))
            FROM insights
            WHERE id IS NOT NULL
              AND content IS NOT NULL
              AND \(columnExpr(columns, "deleted_at", fallback: "NULL")) IS NULL
        """)
        try replaceTable(db, old: "insights", replacement: "__engram_insights_v2")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_insights_wing ON insights(wing)")
    }

    private struct ColumnInfo {
        var type: String
        var notnull: Int
        var defaultValue: String?
    }

    private static func tableExists(_ db: GRDB.Database, _ table: String) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ? LIMIT 1",
            arguments: [table]
        ) != nil
    }

    private static func tableColumns(_ db: GRDB.Database, _ table: String) throws -> [String: ColumnInfo] {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        var columns: [String: ColumnInfo] = [:]
        for row in rows {
            let name: String = row["name"]
            columns[name] = ColumnInfo(
                type: row["type"] as String,
                notnull: row["notnull"] as Int,
                defaultValue: row["dflt_value"] as String?
            )
        }
        return columns
    }

    private static func replaceTable(_ db: GRDB.Database, old: String, replacement: String) throws {
        try db.execute(sql: "DROP TABLE \(old)")
        try db.execute(sql: "ALTER TABLE \(replacement) RENAME TO \(old)")
    }

    private static func columnExpr(_ columns: [String: ColumnInfo], _ name: String, fallback: String) -> String {
        columns[name] == nil ? fallback : name
    }

    private static func normalizeDefault(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
