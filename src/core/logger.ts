// src/core/logger.ts
import type BetterSqlite3 from 'better-sqlite3';
import { type SerializedError, serializeError } from './error-serializer.js';
import type { MetricsCollector } from './metrics.js';
import { getRequestContext } from './request-context.js';
import { applyPatterns, sanitize } from './sanitizer.js';

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

interface LogEntry {
  ts?: string;
  level: LogLevel;
  module: string;
  traceId?: string;
  spanId?: string;
  message: string;
  data?: Record<string, unknown>;
  error?: SerializedError;
  source: 'daemon' | 'app';
  requestSource?: string;
}

export interface Logger {
  debug(message: string, data?: Record<string, unknown>): void;
  info(message: string, data?: Record<string, unknown>): void;
  warn(message: string, data?: Record<string, unknown>, err?: unknown): void;
  error(message: string, data?: Record<string, unknown>, err?: unknown): void;
  child(extra: { traceId?: string; spanId?: string }): Logger;
}

export class LogWriter {
  private insertStmt: BetterSqlite3.Statement;

  constructor(private db: BetterSqlite3.Database) {
    this.insertStmt = db.prepare(`
      INSERT INTO logs (ts, level, module, trace_id, span_id, message, data, error_name, error_message, error_stack, source)
      VALUES (@ts, @level, @module, @traceId, @spanId, @message, @data, @errorName, @errorMessage, @errorStack, @source)
    `);
  }

  write(entry: LogEntry): void {
    this.insertStmt.run({
      ts: entry.ts ?? new Date().toISOString(),
      level: entry.level,
      module: entry.module,
      traceId: entry.traceId ?? null,
      spanId: entry.spanId ?? null,
      message: entry.message,
      data: entry.data ? JSON.stringify(entry.data) : null,
      errorName: entry.error?.name ?? null,
      errorMessage: entry.error?.message ?? null,
      errorStack: entry.error?.stack ?? null,
      source: entry.source,
    });
  }

  rotate(retentionDays: number): void {
    const cutoff = new Date(
      Date.now() - retentionDays * 86400000,
    ).toISOString();
    this.db.prepare('DELETE FROM logs WHERE ts < ?').run(cutoff);
  }

  enforceMaxRows(maxRows: number): void {
    const count = (
      this.db.prepare('SELECT COUNT(*) as c FROM logs').get() as {
        c: number;
      }
    ).c;
    if (count > maxRows) {
      this.db
        .prepare(
          `DELETE FROM logs WHERE id IN (SELECT id FROM logs ORDER BY ts ASC LIMIT ?)`,
        )
        .run(count - maxRows);
    }
  }
}

function sanitizeLogEntry(entry: LogEntry): LogEntry {
  return {
    ...entry,
    message: applyPatterns(entry.message),
    data: entry.data
      ? (sanitize(entry.data) as Record<string, unknown>)
      : undefined,
    error: entry.error
      ? {
          ...entry.error,
          message: applyPatterns(entry.error.message ?? ''),
          stack: entry.error.stack
            ? applyPatterns(entry.error.stack)
            : undefined,
        }
      : undefined,
  };
}

function emitStderr(entry: LogEntry): void {
  const output: Record<string, unknown> = {
    ts: entry.ts ?? new Date().toISOString(),
    level: entry.level,
    module: entry.module,
    request_id: entry.traceId ?? undefined,
    request_source: entry.requestSource ?? undefined,
    span_id: entry.spanId ?? undefined,
    source: entry.source,
    message: entry.message,
  };
  if (entry.data) output.data = entry.data;
  if (entry.error) output.error = entry.error;
  process.stderr.write(`${JSON.stringify(output)}\n`);
}

interface LoggerOpts {
  writer?: LogWriter;
  level?: LogLevel;
  rateLimitPerMin?: number;
  traceId?: string;
  spanId?: string;
  stderrJson?: boolean;
  metrics?: MetricsCollector;
}

export function createLogger(module: string, opts: LoggerOpts = {}): Logger {
  const minLevel = LEVEL_ORDER[opts.level ?? 'info'];
  const writer = opts.writer;
  const rateLimit = opts.rateLimitPerMin ?? 100;
  let debugCount = 0;
  let debugWindowStart = Date.now();
  let suppressed = 0;
  const stderrJson = opts.stderrJson ?? true;
  const metrics = opts.metrics;

  function shouldLog(level: LogLevel): boolean {
    if (LEVEL_ORDER[level] < minLevel) return false;
    if (level === 'debug') {
      const now = Date.now();
      if (now - debugWindowStart > 60000) {
        if (suppressed > 0 && writer) {
          writer.write({
            level: 'info',
            module,
            message: `[${module}] ${suppressed} debug messages suppressed in last 60s`,
            source: 'daemon',
          });
        }
        debugCount = 0;
        suppressed = 0;
        debugWindowStart = now;
      }
      debugCount++;
      if (debugCount > rateLimit) {
        suppressed++;
        return false;
      }
    }
    return true;
  }

  function log(
    level: LogLevel,
    message: string,
    data?: Record<string, unknown>,
    err?: unknown,
  ): void {
    if (!shouldLog(level)) return;
    const ctx = getRequestContext();
    const entry: LogEntry = {
      ts: new Date().toISOString(),
      level,
      module,
      message,
      source: 'daemon',
      traceId: opts.traceId ?? ctx?.requestId,
      spanId: opts.spanId ?? ctx?.spanId,
      requestSource: ctx?.source,
      data,
      error: err ? serializeError(err) : undefined,
    };
    const clean = sanitizeLogEntry(entry);
    writer?.write(clean);
    if (stderrJson) {
      emitStderr(clean);
    }
    if (level === 'error' && metrics) {
      metrics.counter('error.count', 1, { module });
    }
  }

  return {
    debug: (msg, data) => log('debug', msg, data),
    info: (msg, data) => log('info', msg, data),
    warn: (msg, data, err) => log('warn', msg, data, err),
    error: (msg, data, err) => log('error', msg, data, err),
    child: (extra) => createLogger(module, { ...opts, ...extra }),
  };
}
