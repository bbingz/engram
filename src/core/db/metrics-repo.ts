// src/core/db/metrics-repo.ts — stats, costs, files, tools
import type BetterSqlite3 from 'better-sqlite3';
import { buildOrphanFilter, buildTierFilter } from './session-repo.js';
import type {
  CostSummaryRow,
  FileActivityRow,
  NoiseFilter,
  StatsGroup,
  ToolAnalyticsRow,
} from './types.js';

export function statsGroupBy(
  db: BetterSqlite3.Database,
  groupBy: string,
  since: string | undefined,
  until: string | undefined,
  opts: { excludeNoise?: boolean } | undefined,
  noiseFilter: NoiseFilter,
): StatsGroup[] {
  let groupExpr: string;
  if (groupBy === 'project') groupExpr = "COALESCE(project, '(unknown)')";
  else if (groupBy === 'origin' || groupBy === 'node')
    groupExpr =
      "COALESCE(NULLIF(origin, ''), NULLIF(authoritative_node, ''), 'local')";
  else if (groupBy === 'day') groupExpr = "date(start_time, 'localtime')";
  else if (groupBy === 'week')
    groupExpr = "date(start_time, 'localtime', 'weekday 0', '-6 days')";
  else groupExpr = 'source';

  const conditions: string[] = ['hidden_at IS NULL'];
  const params: Record<string, unknown> = {};
  if (since) {
    conditions.push('start_time >= @since');
    params.since = since;
  }
  if (until) {
    conditions.push('start_time <= @until');
    params.until = until;
  }
  if (opts?.excludeNoise) {
    conditions.push(...buildTierFilter(noiseFilter));
  }
  conditions.push(...buildOrphanFilter());
  const where = `WHERE ${conditions.join(' AND ')}`;

  // Exclude skip/lite sessions from user message count even when showing all sessions
  const userMsgExpr = opts?.excludeNoise
    ? 'SUM(user_message_count)'
    : "SUM(CASE WHEN tier IS NOT NULL AND tier IN ('skip', 'lite') THEN 0 ELSE user_message_count END)";

  return db
    .prepare(`
    SELECT ${groupExpr} as key,
      COUNT(*) as sessionCount,
      SUM(message_count) as messageCount,
      ${userMsgExpr} as userMessageCount,
      SUM(assistant_message_count) as assistantMessageCount,
      SUM(tool_message_count) as toolMessageCount
    FROM sessions ${where}
    GROUP BY ${groupExpr}
    ORDER BY sessionCount DESC
  `)
    .all(params) as StatsGroup[];
}

export function needsCountBackfill(db: BetterSqlite3.Database): string[] {
  const rows = db
    .prepare(
      'SELECT id FROM sessions WHERE assistant_message_count = 0 AND message_count > 0 AND hidden_at IS NULL',
    )
    .all() as { id: string }[];
  return rows.map((r) => r.id);
}

export function upsertSessionCost(
  db: BetterSqlite3.Database,
  sessionId: string,
  model: string,
  inputTokens: number,
  outputTokens: number,
  cacheReadTokens: number,
  cacheCreationTokens: number,
  costUsd: number,
): void {
  db.prepare(`
    INSERT OR REPLACE INTO session_costs (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, computed_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
  `).run(
    sessionId,
    model,
    inputTokens,
    outputTokens,
    cacheReadTokens,
    cacheCreationTokens,
    costUsd,
  );
}

export function getCostsSummary(
  db: BetterSqlite3.Database,
  params: {
    groupBy?: string;
    since?: string;
    until?: string;
  },
): CostSummaryRow[] {
  let groupCol: string;
  switch (params.groupBy) {
    case 'source':
      groupCol = 's.source';
      break;
    case 'project':
      groupCol = 's.project';
      break;
    case 'day':
      groupCol = 'date(s.start_time)';
      break;
    default:
      groupCol = 'c.model';
      break;
  }
  let sql = `SELECT ${groupCol} as key, SUM(c.input_tokens) as inputTokens, SUM(c.output_tokens) as outputTokens, SUM(c.cache_read_tokens) as cacheReadTokens, SUM(c.cache_creation_tokens) as cacheCreationTokens, SUM(c.cost_usd) as costUsd, COUNT(*) as sessionCount FROM session_costs c JOIN sessions s ON c.session_id = s.id WHERE 1=1`;
  const binds: string[] = [];
  if (params.since) {
    sql += ' AND s.start_time >= ?';
    binds.push(params.since);
  }
  if (params.until) {
    sql += ' AND s.start_time < ?';
    binds.push(params.until);
  }
  sql += ` GROUP BY ${groupCol} ORDER BY costUsd DESC`;
  return db.prepare(sql).all(...binds) as CostSummaryRow[];
}

export function sessionsWithoutCosts(
  db: BetterSqlite3.Database,
  limit = 100,
): string[] {
  return (
    db
      .prepare(
        `SELECT s.id FROM sessions s LEFT JOIN session_costs c ON s.id = c.session_id WHERE c.session_id IS NULL AND (s.tier IS NULL OR s.tier != 'skip') LIMIT ?`,
      )
      .all(limit) as { id: string }[]
  ).map((r) => r.id);
}

export function upsertSessionFiles(
  db: BetterSqlite3.Database,
  sessionId: string,
  files: Map<string, { action: string; count: number }>,
): void {
  const stmt = db.prepare(
    `INSERT OR REPLACE INTO session_files (session_id, file_path, action, count) VALUES (?, ?, ?, ?)`,
  );
  const runMany = db.transaction(
    (items: [string, string, string, number][]) => {
      for (const item of items) stmt.run(...item);
    },
  );
  runMany(
    [...files.entries()].map(([key, { action, count }]) => {
      const path = key.includes('\0') ? key.split('\0')[0] : key;
      return [sessionId, path, action, count];
    }),
  );
}

export function getFileActivity(
  db: BetterSqlite3.Database,
  params: {
    project?: string;
    since?: string;
    limit?: number;
  },
): FileActivityRow[] {
  const conditions: string[] = [];
  const binds: (string | number)[] = [];
  if (params.project) {
    conditions.push('s.project = ?');
    binds.push(params.project);
  }
  if (params.since) {
    conditions.push('s.start_time >= ?');
    binds.push(params.since);
  }
  const where =
    conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  const limit = params.limit ?? 50;
  return db
    .prepare(`
    SELECT sf.file_path, sf.action, SUM(sf.count) as total_count,
           COUNT(DISTINCT sf.session_id) as session_count
    FROM session_files sf
    JOIN sessions s ON s.id = sf.session_id
    ${where}
    GROUP BY sf.file_path, sf.action
    ORDER BY total_count DESC
    LIMIT ?
  `)
    .all(...binds, limit) as FileActivityRow[];
}

export function upsertSessionTools(
  db: BetterSqlite3.Database,
  sessionId: string,
  tools: Map<string, number>,
): void {
  const stmt = db.prepare(
    `INSERT OR REPLACE INTO session_tools (session_id, tool_name, call_count) VALUES (?, ?, ?)`,
  );
  const runMany = db.transaction((items: [string, string, number][]) => {
    for (const item of items) stmt.run(...item);
  });
  runMany(
    [...tools.entries()].map(([name, count]) => [sessionId, name, count]),
  );
}

export function getToolAnalytics(
  db: BetterSqlite3.Database,
  params: {
    project?: string;
    since?: string;
    groupBy?: string;
  },
): ToolAnalyticsRow[] {
  let selectCols: string;
  let groupCol: string;
  switch (params.groupBy) {
    case 'session':
      selectCols =
        't.session_id as key, s.summary as label, SUM(t.call_count) as callCount, COUNT(DISTINCT t.tool_name) as toolCount';
      groupCol = 't.session_id';
      break;
    case 'project':
      selectCols =
        's.project as key, SUM(t.call_count) as callCount, COUNT(DISTINCT t.tool_name) as toolCount, COUNT(DISTINCT t.session_id) as sessionCount';
      groupCol = 's.project';
      break;
    default: // 'tool'
      selectCols =
        't.tool_name as key, SUM(t.call_count) as callCount, COUNT(DISTINCT t.session_id) as sessionCount';
      groupCol = 't.tool_name';
      break;
  }
  let sql = `SELECT ${selectCols} FROM session_tools t JOIN sessions s ON t.session_id = s.id WHERE 1=1`;
  const binds: string[] = [];
  if (params.project) {
    const escaped = params.project.replace(/[%_\\]/g, '\\$&');
    sql += " AND s.project LIKE ? ESCAPE '\\'";
    binds.push(`%${escaped}%`);
  }
  if (params.since) {
    sql += ' AND s.start_time >= ?';
    binds.push(params.since);
  }
  sql += ` GROUP BY ${groupCol} ORDER BY callCount DESC`;
  return db.prepare(sql).all(...binds) as ToolAnalyticsRow[];
}
