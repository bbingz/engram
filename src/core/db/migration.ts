// src/core/db/migration.ts — schema creation and migrations
import type BetterSqlite3 from 'better-sqlite3';

export const SCHEMA_VERSION = 1;
const FTS_VERSION = '3';

export function runMigrations(
  db: BetterSqlite3.Database,
  getMetadata: (key: string) => string | null,
  setMetadata: (key: string, value: string) => void,
): void {
  // Add columns to existing sessions table if needed
  const cols = db.prepare('PRAGMA table_info(sessions)').all() as {
    name: string;
  }[];
  if (cols.length > 0) {
    const colNames = new Set(cols.map((c) => c.name));
    if (!colNames.has('agent_role'))
      db.exec('ALTER TABLE sessions ADD COLUMN agent_role TEXT');
    if (!colNames.has('hidden_at'))
      db.exec('ALTER TABLE sessions ADD COLUMN hidden_at TEXT');
    if (!colNames.has('custom_name'))
      db.exec('ALTER TABLE sessions ADD COLUMN custom_name TEXT');
    if (!colNames.has('origin'))
      db.exec("ALTER TABLE sessions ADD COLUMN origin TEXT DEFAULT 'local'");
    if (!colNames.has('assistant_message_count'))
      db.exec(
        'ALTER TABLE sessions ADD COLUMN assistant_message_count INTEGER NOT NULL DEFAULT 0',
      );
    if (!colNames.has('system_message_count'))
      db.exec(
        'ALTER TABLE sessions ADD COLUMN system_message_count INTEGER NOT NULL DEFAULT 0',
      );
    if (!colNames.has('tool_message_count'))
      db.exec(
        'ALTER TABLE sessions ADD COLUMN tool_message_count INTEGER NOT NULL DEFAULT 0',
      );
    if (!colNames.has('summary_message_count'))
      db.exec('ALTER TABLE sessions ADD COLUMN summary_message_count INTEGER');
    if (!colNames.has('authoritative_node'))
      db.exec('ALTER TABLE sessions ADD COLUMN authoritative_node TEXT');
    if (!colNames.has('source_locator'))
      db.exec('ALTER TABLE sessions ADD COLUMN source_locator TEXT');
    if (!colNames.has('sync_version'))
      db.exec(
        'ALTER TABLE sessions ADD COLUMN sync_version INTEGER NOT NULL DEFAULT 0',
      );
    if (!colNames.has('snapshot_hash'))
      db.exec('ALTER TABLE sessions ADD COLUMN snapshot_hash TEXT');
    if (!colNames.has('tier')) {
      db.exec('ALTER TABLE sessions ADD COLUMN tier TEXT');
      db.exec('CREATE INDEX IF NOT EXISTS idx_sessions_tier ON sessions(tier)');
    }
    if (!colNames.has('quality_score')) {
      db.exec(
        'ALTER TABLE sessions ADD COLUMN quality_score INTEGER DEFAULT 0',
      );
    }
    // Drop Viking columns if they exist (removed in local-semantic-search migration)
    // SQLite doesn't support DROP COLUMN before 3.35.0; columns are left harmless
  }

  db.exec(`
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
      quality_score INTEGER DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
    CREATE INDEX IF NOT EXISTS idx_sessions_start_time ON sessions(start_time);
    CREATE INDEX IF NOT EXISTS idx_sessions_cwd ON sessions(cwd);
    CREATE INDEX IF NOT EXISTS idx_sessions_file_path ON sessions(file_path);
    CREATE INDEX IF NOT EXISTS idx_sessions_agent_role ON sessions(agent_role);
    CREATE INDEX IF NOT EXISTS idx_sessions_tier ON sessions(tier);

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
  `);

  const syncCols = db.prepare('PRAGMA table_info(sync_state)').all() as {
    name: string;
  }[];
  const syncColNames = new Set(syncCols.map((c) => c.name));
  if (syncCols.length > 0 && !syncColNames.has('last_sync_session_id')) {
    db.exec('ALTER TABLE sync_state ADD COLUMN last_sync_session_id TEXT');
  }

  // Migration: FTS version reset forces re-index of all sessions
  const ftsVersion = getMetadata('fts_version');
  if (ftsVersion !== FTS_VERSION) {
    db.exec('DELETE FROM sessions_fts');
    db.exec('UPDATE sessions SET size_bytes = 0');
    try {
      db.exec('DELETE FROM session_embeddings');
    } catch {
      /* table may not exist yet */
    }
    try {
      db.exec('DELETE FROM vec_sessions');
    } catch {
      /* table may not exist yet */
    }
    setMetadata('fts_version', FTS_VERSION);
  }

  setMetadata('schema_version', String(SCHEMA_VERSION));

  db.exec(`
    CREATE TABLE IF NOT EXISTS usage_snapshots (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      source TEXT NOT NULL,
      metric TEXT NOT NULL,
      value REAL NOT NULL,
      unit TEXT DEFAULT '%',
      reset_at TEXT,
      collected_at TEXT NOT NULL
    )
  `);
  db.exec(
    `CREATE INDEX IF NOT EXISTS idx_usage_latest ON usage_snapshots(source, metric, collected_at DESC)`,
  );

  db.exec(`
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
    )
  `);

  // session_costs — token usage and cost per session (separate from snapshot write path)
  db.exec(`
    CREATE TABLE IF NOT EXISTS session_costs (
      session_id TEXT PRIMARY KEY,
      model TEXT,
      input_tokens INTEGER DEFAULT 0,
      output_tokens INTEGER DEFAULT 0,
      cache_read_tokens INTEGER DEFAULT 0,
      cache_creation_tokens INTEGER DEFAULT 0,
      cost_usd REAL DEFAULT 0,
      computed_at TEXT,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    )
  `);

  // session_tools — tool call counts per session
  db.exec(`
    CREATE TABLE IF NOT EXISTS session_tools (
      session_id TEXT NOT NULL,
      tool_name TEXT NOT NULL,
      call_count INTEGER DEFAULT 0,
      PRIMARY KEY (session_id, tool_name),
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    )
  `);
  db.exec(
    'CREATE INDEX IF NOT EXISTS idx_session_tools_name ON session_tools(tool_name)',
  );

  // session_files — file paths touched per session
  db.exec(`
    CREATE TABLE IF NOT EXISTS session_files (
      session_id TEXT NOT NULL,
      file_path TEXT NOT NULL,
      action TEXT NOT NULL,
      count INTEGER DEFAULT 1,
      PRIMARY KEY (session_id, file_path, action),
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    )
  `);
  db.exec(
    'CREATE INDEX IF NOT EXISTS idx_session_files_path ON session_files(file_path)',
  );

  const sessionCols = db.pragma('table_info(sessions)') as {
    name: string;
  }[];
  if (!sessionCols.some((c) => c.name === 'generated_title')) {
    db.exec('ALTER TABLE sessions ADD COLUMN generated_title TEXT');
  }

  // Migrate idx_logs_level → idx_logs_level_ts (compound index for level+ts queries)
  try {
    const logIndexes = db.prepare('PRAGMA index_list(logs)').all() as {
      name: string;
    }[];
    const hasOldIndex = logIndexes.some((i) => i.name === 'idx_logs_level');
    const hasNewIndex = logIndexes.some((i) => i.name === 'idx_logs_level_ts');
    if (hasOldIndex && !hasNewIndex) {
      db.exec('DROP INDEX IF EXISTS idx_logs_level');
      db.exec(
        'CREATE INDEX IF NOT EXISTS idx_logs_level_ts ON logs(level, ts)',
      );
    }
  } catch {
    /* logs table may not exist yet — handled below */
  }

  // Observability tables
  db.exec(`
    CREATE TABLE IF NOT EXISTS logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
      level TEXT NOT NULL CHECK (level IN ('debug', 'info', 'warn', 'error')),
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
      type TEXT NOT NULL CHECK (type IN ('counter', 'gauge', 'histogram')),
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
  `);

  // ── AI Audit Log ────────────────────────────────────────────────
  db.exec(`
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
    )
  `);
  db.exec('CREATE INDEX IF NOT EXISTS idx_ai_audit_ts ON ai_audit_log(ts)');
  db.exec(
    'CREATE INDEX IF NOT EXISTS idx_ai_audit_caller ON ai_audit_log(caller, ts)',
  );
  db.exec(
    'CREATE INDEX IF NOT EXISTS idx_ai_audit_model ON ai_audit_log(model, ts)',
  );
  db.exec(
    'CREATE INDEX IF NOT EXISTS idx_ai_audit_session ON ai_audit_log(session_id)',
  );
  db.exec(
    'CREATE INDEX IF NOT EXISTS idx_ai_audit_trace ON ai_audit_log(trace_id)',
  );

  // ── Insights (text-only backing store for save_insight) ──────────
  db.exec(`
    CREATE TABLE IF NOT EXISTS insights (
      id TEXT PRIMARY KEY,
      content TEXT NOT NULL,
      wing TEXT,
      room TEXT,
      source_session_id TEXT,
      importance INTEGER DEFAULT 5,
      has_embedding INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (datetime('now'))
    )
  `);
  db.exec('CREATE INDEX IF NOT EXISTS idx_insights_wing ON insights(wing)');
  db.exec(`
    CREATE VIRTUAL TABLE IF NOT EXISTS insights_fts USING fts5(
      insight_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    )
  `);
}
