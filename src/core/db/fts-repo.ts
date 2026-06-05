// src/core/db/fts-repo.ts — FTS indexing and search
import type BetterSqlite3 from 'better-sqlite3';
import { replaceFtsContentForRebuild } from './fts-rebuild-policy.js';
import type { FtsSearchResult, SearchFilters } from './types.js';

/** Detect CJK characters that break SQLite's byte-level trigram tokenizer */
const CJK_REGEX = /[\u2E80-\u9FFF\uF900-\uFAFF\uFE30-\uFE4F]/;
export function containsCJK(text: string): boolean {
  return CJK_REGEX.test(text);
}

/**
 * Escape `%`, `_`, and `\` in user input destined for `LIKE @pattern ESCAPE '\\'`.
 * Without this, a literal user query like "50%" silently widens into "anything
 * starting with 50" and "_" matches every single character.
 */
export function escapeLikePattern(value: string): string {
  return value.replace(/[\\%_]/g, '\\$&');
}

export function indexSessionContent(
  db: BetterSqlite3.Database,
  sessionId: string,
  messages: { role: string; content: string }[],
  summary?: string,
): void {
  const contents: string[] = [];
  for (const msg of messages) {
    if (
      (msg.role === 'user' || msg.role === 'assistant') &&
      msg.content.trim()
    ) {
      contents.push(msg.content);
    }
  }
  if (summary?.trim()) contents.push(summary);
  replaceFtsContentForRebuild(db, sessionId, contents);
}

export function searchSessions(
  db: BetterSqlite3.Database,
  query: string,
  limit: number,
  filters: SearchFilters | undefined,
  resolveAliases: (projects: string[]) => string[],
): FtsSearchResult[] {
  if (!query.trim()) return [];

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
      // Exact-match the resolved project names. The previous LIKE '%name%'
      // shape silently matched "engram-tools" when the user asked for
      // "engram", which made cross-project search results misleading.
      if (expanded.length === 1) {
        conditions.push('s.project = @project');
        params.project = expanded[0];
      } else {
        const clauses = expanded.map((p, i) => {
          params[`proj${i}`] = p;
          return `s.project = @proj${i}`;
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
  } catch (err) {
    // Only swallow FTS5 syntax errors and retry with the query as a quoted
    // phrase. DB lock / I/O / corruption errors must propagate; otherwise we
    // misattribute infrastructure failures to a "weird query" and return
    // misleading results.
    if (!isFtsSyntaxError(err)) throw err;
    const escaped = `"${query.replace(/"/g, '""')}"`;
    return doSearch(escaped);
  }
}

export function isFtsSyntaxError(err: unknown): boolean {
  if (err === null || typeof err !== 'object') return false;
  const message =
    'message' in err &&
    typeof (err as { message?: unknown }).message === 'string'
      ? (err as { message: string }).message.toLowerCase()
      : '';
  // FTS5 surfaces syntax problems via these strings; everything else (busy,
  // locked, malformed, I/O) means "do not retry — propagate".
  return (
    message.includes('fts5: syntax error') ||
    message.includes('unterminated string') ||
    message.includes('no such column') ||
    message.includes('syntax error') ||
    message.includes('parse error')
  );
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
  // Escape user-supplied LIKE wildcards so "%/_" in the query are treated as
  // literal characters rather than wildcards. Project filters likewise must
  // be escaped because they take user-supplied project names.
  const conditions: string[] = [
    "f.content LIKE @pattern ESCAPE '\\'",
    's.hidden_at IS NULL',
  ];
  const params: Record<string, unknown> = {
    pattern: `%${escapeLikePattern(query)}%`,
    limit,
  };

  if (filters?.source) {
    conditions.push('s.source = @source');
    params.source = filters.source;
  }
  if (filters?.project) {
    const expanded = resolveAliases([filters.project]);
    // Exact-match resolved project names (see fts-repo doSearch); avoid the
    // %name% silent partial match that surprised cross-project searches.
    if (expanded.length === 1) {
      conditions.push('s.project = @project');
      params.project = expanded[0];
    } else {
      const clauses = expanded.map((p, i) => {
        params[`proj${i}`] = p;
        return `s.project = @proj${i}`;
      });
      conditions.push(`(${clauses.join(' OR ')})`);
    }
  }
  if (filters?.since) {
    conditions.push('s.start_time >= @since');
    params.since = filters.since;
  }

  const where = conditions.join(' AND ');
  // Use a subquery to pick one representative row per session so the outer
  // SELECT does not depend on non-grouped columns (f.content, f.rowid) which
  // produce undefined results in non-strict SQLite and errors under strict.
  const rows = db
    .prepare(`
    SELECT
      f.session_id AS sessionId,
      SUBSTR(f.content, MAX(1, INSTR(f.content, @query) - 40), 100) AS context,
      f.rowid
    FROM sessions_fts f
    JOIN sessions s ON s.id = f.session_id
    WHERE ${where}
      AND f.rowid = (
        SELECT MIN(f2.rowid) FROM sessions_fts f2
        WHERE f2.session_id = f.session_id
          AND f2.content LIKE @pattern ESCAPE '\\'
      )
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
  replaceFtsContentForRebuild(db, sessionId, contents);
}
