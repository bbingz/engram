// src/core/db/insight-repo.ts — text-only insight storage with FTS
import type BetterSqlite3 from 'better-sqlite3';
import { containsCJK } from './fts-repo.js';

export const DEFAULT_IMPORTANCE = 5;

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
  const upsertStmt = db.prepare(`
    INSERT INTO insights (id, content, wing, room, importance, source_session_id)
    VALUES (@id, @content, @wing, @room, @importance, @sourceSessionId)
    ON CONFLICT(id) DO UPDATE SET
      content = excluded.content,
      wing = excluded.wing,
      room = excluded.room,
      importance = excluded.importance
  `);
  const deleteFts = db.prepare('DELETE FROM insights_fts WHERE insight_id = ?');
  const insertFts = db.prepare(
    'INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)',
  );
  const tx = db.transaction(() => {
    upsertStmt.run({
      id,
      content,
      wing: wing ?? null,
      room: room ?? null,
      importance: importance ?? DEFAULT_IMPORTANCE,
      sourceSessionId: sourceSessionId ?? null,
    });
    deleteFts.run(id);
    insertFts.run(id, content);
  });
  tx();
}

function normalizeForDedup(text: string): string {
  return text.toLowerCase().replace(/\s+/g, ' ').trim();
}

export function findDuplicateInsight(
  db: BetterSqlite3.Database,
  content: string,
  wing?: string,
): InsightRow | null {
  const normalized = normalizeForDedup(content);
  const rows = wing
    ? (db
        .prepare(
          'SELECT * FROM insights WHERE wing = ? ORDER BY created_at DESC LIMIT 200',
        )
        .all(wing) as InsightRow[])
    : (db
        .prepare(
          'SELECT * FROM insights WHERE wing IS NULL ORDER BY created_at DESC LIMIT 200',
        )
        .all() as InsightRow[]);

  for (const row of rows) {
    if (normalizeForDedup(row.content) === normalized) {
      return row;
    }
  }
  return null;
}

export function searchInsightsFts(
  db: BetterSqlite3.Database,
  query: string,
  limit = 10,
): InsightRow[] {
  // CJK characters break trigram tokenizer — fall back to LIKE
  if (containsCJK(query)) {
    return db
      .prepare(
        'SELECT * FROM insights WHERE content LIKE @pattern ORDER BY created_at DESC LIMIT @limit',
      )
      .all({ pattern: `%${query}%`, limit }) as InsightRow[];
  }

  const doSearch = (q: string): InsightRow[] =>
    db
      .prepare(`
      SELECT i.*
      FROM insights_fts f
      JOIN insights i ON i.id = f.insight_id
      WHERE insights_fts MATCH @query
      ORDER BY f.rank
      LIMIT @limit
    `)
      .all({ query: q, limit }) as InsightRow[];

  try {
    return doSearch(query);
  } catch {
    const escaped = `"${query.replace(/"/g, '""')}"`;
    return doSearch(escaped);
  }
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

export function deleteInsightText(
  db: BetterSqlite3.Database,
  id: string,
): boolean {
  const deleteFts = db.prepare('DELETE FROM insights_fts WHERE insight_id = ?');
  const deleteInsight = db.prepare('DELETE FROM insights WHERE id = ?');
  const tx = db.transaction(() => {
    deleteFts.run(id);
    const result = deleteInsight.run(id);
    return result.changes > 0;
  });
  return tx();
}
