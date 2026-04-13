// src/core/db/insight-repo.ts — text-only insight storage with FTS
import type BetterSqlite3 from 'better-sqlite3';

export interface InsightRow {
  id: string;
  content: string;
  wing: string | null;
  room: string | null;
  source_session_id: string | null;
  importance: number;
  has_embedding: number;
  created_at: string;
}

export function saveInsightText(
  db: BetterSqlite3.Database,
  id: string,
  content: string,
  wing?: string,
  room?: string,
  importance?: number,
  sourceSessionId?: string,
): void {
  db.prepare(`
    INSERT INTO insights (id, content, wing, room, importance, source_session_id)
    VALUES (@id, @content, @wing, @room, @importance, @sourceSessionId)
    ON CONFLICT(id) DO UPDATE SET
      content = excluded.content,
      wing = excluded.wing,
      room = excluded.room,
      importance = excluded.importance
  `).run({
    id,
    content,
    wing: wing ?? null,
    room: room ?? null,
    importance: importance ?? 5,
    sourceSessionId: sourceSessionId ?? null,
  });

  // Upsert FTS content
  db.prepare('DELETE FROM insights_fts WHERE insight_id = ?').run(id);
  db.prepare(
    'INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)',
  ).run(id, content);
}

export function searchInsightsFts(
  db: BetterSqlite3.Database,
  query: string,
  limit = 10,
): InsightRow[] {
  return db
    .prepare(`
    SELECT i.*
    FROM insights_fts f
    JOIN insights i ON i.id = f.insight_id
    WHERE insights_fts MATCH @query
    ORDER BY f.rank
    LIMIT @limit
  `)
    .all({ query, limit }) as InsightRow[];
}

export function listInsightsByWing(
  db: BetterSqlite3.Database,
  wing: string | undefined,
  limit = 10,
): InsightRow[] {
  if (wing) {
    return db
      .prepare(
        'SELECT * FROM insights WHERE wing = ? ORDER BY created_at DESC LIMIT ?',
      )
      .all(wing, limit) as InsightRow[];
  }
  return db
    .prepare('SELECT * FROM insights ORDER BY created_at DESC LIMIT ?')
    .all(limit) as InsightRow[];
}

export function markInsightEmbedded(
  db: BetterSqlite3.Database,
  id: string,
): void {
  db.prepare('UPDATE insights SET has_embedding = 1 WHERE id = ?').run(id);
}

export function listUnembeddedInsights(
  db: BetterSqlite3.Database,
  limit = 20,
): InsightRow[] {
  return db
    .prepare(
      'SELECT * FROM insights WHERE has_embedding = 0 ORDER BY created_at ASC LIMIT ?',
    )
    .all(limit) as InsightRow[];
}
