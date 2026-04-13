// src/core/db/fts-repo.ts — FTS indexing and search
import type BetterSqlite3 from 'better-sqlite3';
import type { FtsSearchResult, SearchFilters } from './types.js';

/** Detect CJK characters that break SQLite's byte-level trigram tokenizer */
const CJK_REGEX = /[\u2E80-\u9FFF\uF900-\uFAFF\uFE30-\uFE4F]/;
export function containsCJK(text: string): boolean {
  return CJK_REGEX.test(text);
}

export function indexSessionContent(
  db: BetterSqlite3.Database,
  sessionId: string,
  messages: { role: string; content: string }[],
  summary?: string,
): void {
  const deleteStmt = db.prepare(
    'DELETE FROM sessions_fts WHERE session_id = ?',
  );
  const insertStmt = db.prepare(
    'INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)',
  );

  const transaction = db.transaction(() => {
    deleteStmt.run(sessionId);
    for (const msg of messages) {
      if (
        (msg.role === 'user' || msg.role === 'assistant') &&
        msg.content.trim()
      ) {
        insertStmt.run(sessionId, msg.content);
      }
    }
    if (summary?.trim()) {
      insertStmt.run(sessionId, summary);
    }
  });
  transaction();
}

export function searchSessions(
  db: BetterSqlite3.Database,
  query: string,
  limit: number,
  filters: SearchFilters | undefined,
  resolveAliases: (projects: string[]) => string[],
): FtsSearchResult[] {
  // SQLite trigram tokenizer operates on byte-level trigrams which breaks CJK
  // characters (3 bytes each in UTF-8). Fall back to LIKE for CJK queries.
  if (containsCJK(query)) {
    return searchSessionsLike(db, query, limit, filters, resolveAliases);
  }

  const doSearch = (q: string): FtsSearchResult[] => {
    const conditions: string[] = [
      'sessions_fts MATCH @query',
      's.hidden_at IS NULL',
    ];
    const params: Record<string, unknown> = { query: q, limit };

    if (filters?.source) {
      conditions.push('s.source = @source');
      params.source = filters.source;
    }
    if (filters?.project) {
      const expanded = resolveAliases([filters.project]);
      if (expanded.length === 1) {
        conditions.push('s.project LIKE @project');
        params.project = `%${expanded[0]}%`;
      } else {
        const clauses = expanded.map((p, i) => {
          params[`proj${i}`] = `%${p}%`;
          return `s.project LIKE @proj${i}`;
        });
        conditions.push(`(${clauses.join(' OR ')})`);
      }
    }
    if (filters?.since) {
      conditions.push('s.start_time >= @since');
      params.since = filters.since;
    }

    const where = conditions.join(' AND ');
    return db
      .prepare(`
      SELECT
        f.session_id AS sessionId,
        snippet(sessions_fts, 1, '<mark>', '</mark>', '…', 32) AS snippet,
        f.rank
      FROM sessions_fts f
      JOIN sessions s ON s.id = f.session_id
      WHERE ${where}
      ORDER BY f.rank
      LIMIT @limit
    `)
      .all(params) as FtsSearchResult[];
  };

  try {
    return doSearch(query);
  } catch {
    const escaped = `"${query.replace(/"/g, '""')}"`;
    return doSearch(escaped);
  }
}

/**
 * LIKE-based fallback for CJK queries where the trigram tokenizer fails.
 * Scans sessions_fts content column with LIKE '%query%' and builds snippets in JS.
 */
function searchSessionsLike(
  db: BetterSqlite3.Database,
  query: string,
  limit: number,
  filters: SearchFilters | undefined,
  resolveAliases: (projects: string[]) => string[],
): FtsSearchResult[] {
  const conditions: string[] = [
    'f.content LIKE @pattern',
    's.hidden_at IS NULL',
  ];
  const params: Record<string, unknown> = { pattern: `%${query}%`, limit };

  if (filters?.source) {
    conditions.push('s.source = @source');
    params.source = filters.source;
  }
  if (filters?.project) {
    const expanded = resolveAliases([filters.project]);
    if (expanded.length === 1) {
      conditions.push('s.project LIKE @project');
      params.project = `%${expanded[0]}%`;
    } else {
      const clauses = expanded.map((p, i) => {
        params[`proj${i}`] = `%${p}%`;
        return `s.project LIKE @proj${i}`;
      });
      conditions.push(`(${clauses.join(' OR ')})`);
    }
  }
  if (filters?.since) {
    conditions.push('s.start_time >= @since');
    params.since = filters.since;
  }

  const where = conditions.join(' AND ');
  // Group by session_id so each session appears once; pick the first matching row's content for snippet
  const rows = db
    .prepare(`
    SELECT
      f.session_id AS sessionId,
      SUBSTR(f.content, MAX(1, INSTR(f.content, @query) - 40), 100) AS context,
      f.rowid
    FROM sessions_fts f
    JOIN sessions s ON s.id = f.session_id
    WHERE ${where}
    GROUP BY f.session_id
    ORDER BY s.start_time DESC
    LIMIT @limit
  `)
    .all({ ...params, query }) as {
    sessionId: string;
    context: string;
    rowid: number;
  }[];

  return rows.map((r, i) => {
    // Build a snippet with <mark> highlighting
    const snippet = r.context.replace(
      new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'),
      '<mark>$&</mark>',
    );
    return {
      sessionId: r.sessionId,
      snippet: `…${snippet}…`,
      rank: -(rows.length - i),
    };
  });
}

export function getFtsContent(
  db: BetterSqlite3.Database,
  sessionId: string,
): string[] {
  const rows = db
    .prepare('SELECT content FROM sessions_fts WHERE session_id = ?')
    .all(sessionId) as { content: string }[];
  return rows.map((r) => r.content);
}

export function replaceFtsContent(
  db: BetterSqlite3.Database,
  sessionId: string,
  contents: string[],
): void {
  const deleteStmt = db.prepare(
    'DELETE FROM sessions_fts WHERE session_id = ?',
  );
  const insertStmt = db.prepare(
    'INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)',
  );
  const tx = db.transaction(() => {
    deleteStmt.run(sessionId);
    for (const content of contents) {
      if (content.trim()) insertStmt.run(sessionId, content);
    }
  });
  tx();
}
