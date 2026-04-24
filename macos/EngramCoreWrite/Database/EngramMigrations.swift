import Foundation
import GRDB

enum EngramMigrations {
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
    }

    static func writeSchemaMetadata(_ db: GRDB.Database) throws {
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('schema_version', '1')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
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
}
