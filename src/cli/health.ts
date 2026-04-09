// src/cli/health.ts
// CLI diagnostic: DB health check and error diagnosis

import { homedir } from 'node:os';
import { resolve } from 'node:path';
import type BetterSqlite3 from 'better-sqlite3';
import { Database } from '../core/db.js';
import { parseDuration } from './utils.js';

export interface HealthResult {
  dbSizeBytes: number;
  tables: Record<string, number>;
}

export interface DiagnoseResult {
  errorCount: number;
  errorsByModule: Record<string, number>;
  slowTraces: Array<{ name: string; durationMs: number; startTs: string }>;
  recentErrors: Array<{ ts: string; module: string; message: string }>;
}

export function queryHealth(db: BetterSqlite3.Database): HealthResult {
  const pageCount =
    (db.pragma('page_count') as Array<{ page_count: number }>)[0]?.page_count ??
    0;
  const pageSize =
    (db.pragma('page_size') as Array<{ page_size: number }>)[0]?.page_size ?? 0;
  const dbSizeBytes = pageCount * pageSize;

  const tableNames = [
    'logs',
    'traces',
    'metrics',
    'metrics_hourly',
    'sessions',
  ];
  const tables: Record<string, number> = {};
  for (const name of tableNames) {
    try {
      const row = db.prepare(`SELECT COUNT(*) as cnt FROM ${name}`).get() as
        | { cnt: number }
        | undefined;
      tables[name] = row?.cnt ?? 0;
    } catch {
      tables[name] = 0;
    }
  }

  return { dbSizeBytes, tables };
}

export function diagnose(
  db: BetterSqlite3.Database,
  opts: { since?: string },
): DiagnoseResult {
  const sinceClause = opts.since ? 'AND ts >= ?' : '';
  const sinceParams = opts.since ? [opts.since] : [];

  // Total error count
  const countRow = db
    .prepare(
      `SELECT COUNT(*) as cnt FROM logs WHERE level = 'error' ${sinceClause}`,
    )
    .get(...sinceParams) as { cnt: number };
  const errorCount = countRow.cnt;

  // Errors grouped by module
  const moduleRows = db
    .prepare(
      `SELECT module, COUNT(*) as cnt FROM logs WHERE level = 'error' ${sinceClause} GROUP BY module ORDER BY cnt DESC`,
    )
    .all(...sinceParams) as Array<{ module: string; cnt: number }>;
  const errorsByModule: Record<string, number> = {};
  for (const row of moduleRows) {
    errorsByModule[row.module] = row.cnt;
  }

  // Slow traces (top 10 by duration)
  const slowSinceClause = opts.since ? 'WHERE start_ts >= ?' : '';
  const slowRows = db
    .prepare(
      `SELECT name, duration_ms, start_ts FROM traces ${slowSinceClause} ORDER BY duration_ms DESC LIMIT 10`,
    )
    .all(...sinceParams) as Array<{
    name: string;
    duration_ms: number;
    start_ts: string;
  }>;
  const slowTraces = slowRows.map((r) => ({
    name: r.name,
    durationMs: r.duration_ms,
    startTs: r.start_ts,
  }));

  // Recent errors (last 10)
  const recentRows = db
    .prepare(
      `SELECT ts, module, message FROM logs WHERE level = 'error' ${sinceClause} ORDER BY ts DESC LIMIT 10`,
    )
    .all(...sinceParams) as Array<{
    ts: string;
    module: string;
    message: string;
  }>;

  return { errorCount, errorsByModule, slowTraces, recentErrors: recentRows };
}

function formatHealth(result: HealthResult): string {
  const lines = ['=== DB Health ==='];
  const sizeMB = (result.dbSizeBytes / (1024 * 1024)).toFixed(2);
  lines.push(`Database size: ${result.dbSizeBytes} bytes (${sizeMB} MB)`);
  lines.push('');
  lines.push('Table row counts:');
  for (const [name, count] of Object.entries(result.tables)) {
    lines.push(`  ${name}: ${count}`);
  }
  return lines.join('\n');
}

function formatDiagnose(result: DiagnoseResult): string {
  const lines = ['=== Diagnosis ==='];
  lines.push(`Total errors: ${result.errorCount}`);

  if (Object.keys(result.errorsByModule).length > 0) {
    lines.push('');
    lines.push('Errors by module:');
    for (const [mod, count] of Object.entries(result.errorsByModule)) {
      lines.push(`  ${mod}: ${count}`);
    }
  }

  if (result.slowTraces.length > 0) {
    lines.push('');
    lines.push('Slowest traces:');
    for (const t of result.slowTraces) {
      lines.push(`  ${t.name}: ${t.durationMs}ms (${t.startTs})`);
    }
  }

  if (result.recentErrors.length > 0) {
    lines.push('');
    lines.push('Recent errors:');
    for (const e of result.recentErrors) {
      lines.push(`  [${e.ts}] [${e.module}] ${e.message}`);
    }
  }

  return lines.join('\n');
}

function parseArgs(args: string[]): { since?: string; json?: boolean } {
  const opts: { since?: string; json?: boolean } = {};
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = args[i + 1];
    if (arg === '--since' && next) {
      opts.since = next;
      i++;
    } else if (arg === '--last' && next) {
      opts.since = parseDuration(next);
      i++;
    } else if (arg === '--json') {
      opts.json = true;
    }
  }
  return opts;
}

export function main(subcommand: string, args: string[]): void {
  const opts = parseArgs(args);
  const dbPath = resolve(homedir(), '.engram', 'index.sqlite');
  const db = new Database(dbPath);
  try {
    if (subcommand === 'diagnose') {
      const result = diagnose(db.raw, { since: opts.since });
      console.log(
        opts.json ? JSON.stringify(result, null, 2) : formatDiagnose(result),
      );
    } else {
      const result = queryHealth(db.raw);
      console.log(
        opts.json ? JSON.stringify(result, null, 2) : formatHealth(result),
      );
    }
  } finally {
    db.close();
  }
}
