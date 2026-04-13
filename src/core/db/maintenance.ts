// src/core/db/maintenance.ts — post-migration backfills and DB maintenance
import type BetterSqlite3 from 'better-sqlite3';
import { computeQualityScore } from '../session-scoring.js';

export function runPostMigrationBackfill(db: BetterSqlite3.Database): void {
  // Incremental: only backfill sessions not yet in session_local_state
  // and sessions missing authoritative_node. Safe to run every startup.
  db.prepare(`
    INSERT INTO session_local_state (session_id, hidden_at, custom_name, local_readable_path)
    SELECT id, hidden_at, custom_name, file_path
    FROM sessions
    WHERE id NOT IN (SELECT session_id FROM session_local_state)
  `).run();

  db.prepare(`
    UPDATE sessions
    SET
      authoritative_node = COALESCE(authoritative_node, origin, 'local'),
      source_locator = COALESCE(source_locator, file_path),
      sync_version = COALESCE(sync_version, 0),
      snapshot_hash = COALESCE(snapshot_hash, '')
    WHERE authoritative_node IS NULL OR authoritative_node = ''
  `).run();

  // Only does work when there are unmigrated rows — effectively O(0) on subsequent starts
}

export function backfillTiers(db: BetterSqlite3.Database): void {
  db.exec(`
    UPDATE sessions SET tier = CASE
      WHEN agent_role IS NOT NULL THEN 'skip'
      WHEN file_path LIKE '%/subagents/%' THEN 'skip'
      WHEN message_count <= 1 THEN 'skip'
      WHEN message_count >= 20 THEN 'premium'
      WHEN message_count >= 10 AND project IS NOT NULL THEN 'premium'
      WHEN (julianday(end_time) - julianday(start_time)) * 1440 > 30 THEN 'premium'
      WHEN summary LIKE '%/usage%' THEN 'lite'
      WHEN summary LIKE '%Generate a short, clear title%' THEN 'lite'
      ELSE 'normal'
    END
    WHERE tier IS NULL
  `);
}

export function backfillScores(db: BetterSqlite3.Database): number {
  const rows = db
    .prepare(`
    SELECT id, user_message_count, assistant_message_count, tool_message_count, system_message_count,
           start_time, end_time, project
    FROM sessions
    WHERE (quality_score IS NULL OR quality_score = 0)
      AND tier != 'skip'
      AND (user_message_count > 0 OR assistant_message_count > 0)
  `)
    .all() as {
    id: string;
    user_message_count: number;
    assistant_message_count: number;
    tool_message_count: number;
    system_message_count: number;
    start_time: string;
    end_time: string | null;
    project: string | null;
  }[];

  if (rows.length === 0) return 0;

  const updateStmt = db.prepare(
    'UPDATE sessions SET quality_score = ? WHERE id = ?',
  );
  const transaction = db.transaction(() => {
    for (const row of rows) {
      const score = computeQualityScore({
        userCount: row.user_message_count,
        assistantCount: row.assistant_message_count,
        toolCount: row.tool_message_count,
        systemCount: row.system_message_count,
        startTime: row.start_time,
        endTime: row.end_time,
        project: row.project,
      });
      updateStmt.run(score, row.id);
    }
  });
  transaction();
  return rows.length;
}

export function optimizeFts(db: BetterSqlite3.Database): void {
  db.exec("INSERT INTO sessions_fts(sessions_fts) VALUES('optimize')");
  db.exec("INSERT INTO insights_fts(insights_fts) VALUES('optimize')");
}

export function vacuumIfNeeded(
  db: BetterSqlite3.Database,
  thresholdPct: number,
): boolean {
  const pageCount =
    (db.pragma('page_count') as { page_count: number }[])[0]?.page_count ?? 0;
  const freeCount =
    (db.pragma('freelist_count') as { freelist_count: number }[])[0]
      ?.freelist_count ?? 0;
  if (pageCount === 0) return false;
  const fragPct = (freeCount / pageCount) * 100;
  if (fragPct > thresholdPct) {
    db.exec('VACUUM');
    return true;
  }
  return false;
}

export function deduplicateFilePaths(db: BetterSqlite3.Database): number {
  const result = db
    .prepare(`
    DELETE FROM sessions WHERE rowid NOT IN (
      SELECT MAX(rowid) FROM sessions GROUP BY file_path
    ) AND file_path IS NOT NULL AND file_path != ''
  `)
    .run();
  return result.changes;
}
