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
    const needsFreshRebuild =
      pending !== FTS_VERSION ||
      !tableMatchesSessionsFtsSchema(db, REBUILD_TABLE);
    if (needsFreshRebuild) {
      recreateRebuildTable(db);
    }

    deleteIfExists(db, 'session_embeddings');
    deleteIfExists(db, 'vec_sessions');
    metadata.setMetadata(REBUILD_VERSION_KEY, FTS_VERSION);
    if (needsFreshRebuild) {
      reopenCompletedFtsJobs(db);
    }
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
  if (!tableMatchesSessionsFtsSchema(db, REBUILD_TABLE)) {
    recreateRebuildTable(db);
  }
  if (recoverableFtsJobCount(db) > 0) return false;

  const tx = db.transaction(() => {
    // H01 parity: terminal or never-replayed jobs can still have searchable
    // content in the live table. Preserve those rows before swapping shadows.
    copyMissingLiveFtsRowsIntoRebuild(db);
    if (eligibleSessionsMissingRebuildContent(db) > 0) return false;

    db.exec(`DROP TABLE IF EXISTS ${OLD_TABLE}`);
    if (tableExists(db, ACTIVE_TABLE)) {
      db.exec(`ALTER TABLE ${ACTIVE_TABLE} RENAME TO ${OLD_TABLE}`);
    }
    db.exec(`ALTER TABLE ${REBUILD_TABLE} RENAME TO ${ACTIVE_TABLE}`);
    db.exec(`DROP TABLE IF EXISTS ${OLD_TABLE}`);
    metadata.setMetadata('fts_version', FTS_VERSION);
    deleteMetadata(db, REBUILD_VERSION_KEY);
    return true;
  });
  return tx();
}

export function replaceFtsContentForRebuild(
  db: BetterSqlite3.Database,
  sessionId: string,
  contents: string[],
): void {
  const tx = db.transaction(() => {
    replaceFtsContentInTable(db, ACTIVE_TABLE, sessionId, contents);
    if (rebuildIsPending(db) && tableExists(db, REBUILD_TABLE)) {
      replaceFtsContentInTable(db, REBUILD_TABLE, sessionId, contents);
    }
  });
  tx();
}

export function deleteFtsContentForRebuild(
  db: BetterSqlite3.Database,
  sessionId: string,
): void {
  const tx = db.transaction(() => {
    deleteFtsContentInTable(db, ACTIVE_TABLE, sessionId);
    if (rebuildIsPending(db) && tableExists(db, REBUILD_TABLE)) {
      deleteFtsContentInTable(db, REBUILD_TABLE, sessionId);
    }
  });
  tx();
}

export function deleteSubagentFtsForRebuild(db: BetterSqlite3.Database): void {
  const tx = db.transaction(() => {
    db.exec(
      "DELETE FROM sessions_fts WHERE session_id IN (SELECT id FROM sessions WHERE agent_role = 'subagent')",
    );
    if (rebuildIsPending(db) && tableExists(db, REBUILD_TABLE)) {
      db.exec(
        "DELETE FROM sessions_fts_rebuild WHERE session_id IN (SELECT id FROM sessions WHERE agent_role = 'subagent')",
      );
    }
  });
  tx();
}

function replaceFtsContentInTable(
  db: BetterSqlite3.Database,
  table: typeof ACTIVE_TABLE | typeof REBUILD_TABLE,
  sessionId: string,
  contents: string[],
): void {
  deleteFtsContentInTable(db, table, sessionId);
  const insert = db.prepare(
    `INSERT INTO ${table}(session_id, content) VALUES (?, ?)`,
  );
  for (const content of contents) {
    if (content.trim()) insert.run(sessionId, content);
  }
}

function deleteFtsContentInTable(
  db: BetterSqlite3.Database,
  table: typeof ACTIVE_TABLE | typeof REBUILD_TABLE,
  sessionId: string,
): void {
  db.prepare(`DELETE FROM ${table} WHERE session_id = ?`).run(sessionId);
}

function rebuildIsPending(db: BetterSqlite3.Database): boolean {
  if (!tableExists(db, 'metadata')) return false;
  return (
    db
      .prepare('SELECT value FROM metadata WHERE key = ?')
      .pluck()
      .get(REBUILD_VERSION_KEY) === FTS_VERSION
  );
}

function recreateRebuildTable(db: BetterSqlite3.Database): void {
  db.exec(`DROP TABLE IF EXISTS ${REBUILD_TABLE}`);
  createSessionsFtsTable(db, REBUILD_TABLE);
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

function eligibleSessionSqlPredicate(alias = 's'): string {
  return `
    COALESCE(${alias}.tier, 'normal') != 'skip'
    AND ${alias}.hidden_at IS NULL
    AND ${alias}.orphan_status IS NULL
  `;
}

function copyMissingLiveFtsRowsIntoRebuild(db: BetterSqlite3.Database): void {
  if (
    !tableExists(db, ACTIVE_TABLE) ||
    !tableExists(db, REBUILD_TABLE) ||
    !tableExists(db, 'sessions')
  ) {
    return;
  }
  db.exec(`
    INSERT INTO ${REBUILD_TABLE}(session_id, content)
    SELECT live.session_id, live.content
    FROM ${ACTIVE_TABLE} AS live
    INNER JOIN sessions AS s ON s.id = live.session_id
    WHERE ${eligibleSessionSqlPredicate()}
      AND NOT EXISTS (
        SELECT 1 FROM ${REBUILD_TABLE} AS shadow
        WHERE shadow.session_id = live.session_id
      )
  `);
}

function eligibleSessionsMissingRebuildContent(
  db: BetterSqlite3.Database,
): number {
  if (
    !tableExists(db, 'sessions') ||
    !tableExists(db, ACTIVE_TABLE) ||
    !tableExists(db, REBUILD_TABLE)
  ) {
    return 0;
  }
  const row = db
    .prepare(`
      SELECT COUNT(*) AS count
      FROM sessions AS s
      WHERE ${eligibleSessionSqlPredicate()}
        AND EXISTS (
          SELECT 1 FROM ${ACTIVE_TABLE} AS live
          WHERE live.session_id = s.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM ${REBUILD_TABLE} AS shadow
          WHERE shadow.session_id = s.id
        )
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

function tableMatchesSessionsFtsSchema(
  db: BetterSqlite3.Database,
  table: typeof ACTIVE_TABLE | typeof REBUILD_TABLE,
): boolean {
  const sql = db
    .prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name = ?")
    .pluck()
    .get(table);
  if (typeof sql !== 'string') return false;
  const normalized = sql.toLowerCase().replace(/\s+/g, ' ');
  return (
    normalized.includes('create virtual table') &&
    normalized.includes('using fts5') &&
    normalized.includes('session_id unindexed') &&
    normalized.includes('content') &&
    normalized.includes("tokenize='trigram case_sensitive 0'")
  );
}
