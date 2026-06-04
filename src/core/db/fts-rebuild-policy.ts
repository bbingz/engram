import type BetterSqlite3 from 'better-sqlite3';

export const FTS_VERSION = '3';

const REBUILD_VERSION_KEY = 'fts_rebuild_version';
const ACTIVE_TABLE = 'sessions_fts';
const REBUILD_TABLE = 'sessions_fts_rebuild';
const OLD_TABLE = 'sessions_fts_old';

type MetadataAccess = {
  getMetadata: (key: string) => string | null;
  setMetadata: (key: string, value: string) => void;
};

export function applyFtsRebuildPolicy(
  db: BetterSqlite3.Database,
  metadata: MetadataAccess,
): void {
  const current = metadata.getMetadata('fts_version');
  if (current === FTS_VERSION) return;

  const tx = db.transaction(() => {
    if (sessionCount(db) === 0) {
      db.exec(`DROP TABLE IF EXISTS ${REBUILD_TABLE}`);
      metadata.setMetadata('fts_version', FTS_VERSION);
      deleteMetadata(db, REBUILD_VERSION_KEY);
      return;
    }

    const pending = metadata.getMetadata(REBUILD_VERSION_KEY);
    const rebuildMissing = !tableExists(db, REBUILD_TABLE);
    const needsFreshRebuild = pending !== FTS_VERSION || rebuildMissing;
    if (needsFreshRebuild) {
      db.exec(`DROP TABLE IF EXISTS ${REBUILD_TABLE}`);
      createSessionsFtsTable(db, REBUILD_TABLE);
      if (tableExists(db, ACTIVE_TABLE)) {
        db.exec(`
          INSERT INTO ${REBUILD_TABLE}(session_id, content)
          SELECT session_id, content FROM ${ACTIVE_TABLE}
        `);
      }
    }

    db.exec('UPDATE sessions SET size_bytes = 0');
    deleteIfExists(db, 'session_embeddings');
    deleteIfExists(db, 'vec_sessions');
    metadata.setMetadata(REBUILD_VERSION_KEY, FTS_VERSION);
    reopenCompletedFtsJobs(db);
    finalizeFtsRebuildIfReady(db, metadata);
  });
  tx();
}

export function createSessionsFtsTable(
  db: BetterSqlite3.Database,
  table: typeof ACTIVE_TABLE | typeof REBUILD_TABLE,
  options: { ifNotExists?: boolean } = {},
): void {
  const existsClause = options.ifNotExists ? 'IF NOT EXISTS ' : '';
  db.exec(`
    CREATE VIRTUAL TABLE ${existsClause}${table} USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    )
  `);
}

export function finalizeFtsRebuildIfReady(
  db: BetterSqlite3.Database,
  metadata: MetadataAccess,
): boolean {
  if (metadata.getMetadata(REBUILD_VERSION_KEY) !== FTS_VERSION) return false;
  if (!tableExists(db, REBUILD_TABLE)) return false;
  if (recoverableFtsJobCount(db) > 0) return false;

  const tx = db.transaction(() => {
    db.exec(`DROP TABLE IF EXISTS ${OLD_TABLE}`);
    if (tableExists(db, ACTIVE_TABLE)) {
      db.exec(`ALTER TABLE ${ACTIVE_TABLE} RENAME TO ${OLD_TABLE}`);
    }
    db.exec(`ALTER TABLE ${REBUILD_TABLE} RENAME TO ${ACTIVE_TABLE}`);
    db.exec(`DROP TABLE IF EXISTS ${OLD_TABLE}`);
    metadata.setMetadata('fts_version', FTS_VERSION);
    deleteMetadata(db, REBUILD_VERSION_KEY);
  });
  tx();
  return true;
}

function reopenCompletedFtsJobs(db: BetterSqlite3.Database): void {
  if (!tableExists(db, 'session_index_jobs')) return;
  db.exec(`
    UPDATE session_index_jobs
    SET status = 'pending',
        retry_count = 0,
        last_error = NULL,
        updated_at = datetime('now')
    WHERE job_kind = 'fts' AND status = 'completed'
  `);
}

function recoverableFtsJobCount(db: BetterSqlite3.Database): number {
  if (!tableExists(db, 'session_index_jobs')) return 0;
  const row = db
    .prepare(`
      SELECT COUNT(*) AS count FROM session_index_jobs
      WHERE job_kind = 'fts' AND status IN ('pending', 'failed_retryable')
    `)
    .get() as { count: number };
  return row.count;
}

function sessionCount(db: BetterSqlite3.Database): number {
  if (!tableExists(db, 'sessions')) return 0;
  const row = db.prepare('SELECT COUNT(*) AS count FROM sessions').get() as {
    count: number;
  };
  return row.count;
}

function deleteIfExists(db: BetterSqlite3.Database, table: string): void {
  if (tableExists(db, table)) db.exec(`DELETE FROM ${table}`);
}

function deleteMetadata(db: BetterSqlite3.Database, key: string): void {
  if (tableExists(db, 'metadata')) {
    db.prepare('DELETE FROM metadata WHERE key = ?').run(key);
  }
}

function tableExists(db: BetterSqlite3.Database, table: string): boolean {
  return (
    db
      .prepare(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
      )
      .get(table) !== undefined
  );
}
