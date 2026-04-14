# Observability System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add centralized structured logging, request tracing, performance metrics, CLI diagnostics, and an in-app Observability page to Engram.

**Architecture:** Daemon-only SQLite writes (single writer). TypeScript logger/tracer/metrics modules with in-memory buffering. Swift reads via GRDB. CLI reads via read-only SQLite. New Observability page in Monitor section.

**Tech Stack:** TypeScript (zero-dependency logger), Swift/SwiftUI (os_log + GRDB), SQLite WAL mode, Hono middleware.

**Spec:** `docs/superpowers/specs/2026-03-22-observability-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `src/core/logger.ts` | Logger factory, LogEntry type, SQLite log writer, debug rate limiter |
| `src/core/tracer.ts` | Span/trace lifecycle, tracer factory, SQLite trace writer |
| `src/core/metrics.ts` | Metric types, in-memory buffer, batch flusher, sampling config |
| `src/core/error-serializer.ts` | `serializeError()` utility |
| `src/cli/logs.ts` | `engram logs` subcommand handler |
| `src/cli/traces.ts` | `engram traces` subcommand handler |
| `src/cli/health.ts` | `engram health` and `engram diagnose` handlers |
| `macos/Engram/Core/EngramLogger.swift` | Swift os_log wrapper with optional daemon forwarding |
| `macos/Engram/Views/Pages/ObservabilityView.swift` | Container page with tab sections |
| `macos/Engram/Views/Observability/LogStreamView.swift` | Live log tail with filters |
| `macos/Engram/Views/Observability/ErrorDashboardView.swift` | Error stats and trends |
| `macos/Engram/Views/Observability/PerformanceView.swift` | Latency charts and slow ops |
| `macos/Engram/Views/Observability/TraceExplorerView.swift` | Trace list + waterfall detail |
| `macos/Engram/Views/Observability/SystemHealthView.swift` | Daemon/DB/Viking status |

### Modified Files
| File | Change |
|------|--------|
| `src/core/db.ts` | Add `logs`, `traces`, `metrics`, `metrics_hourly` table migrations |
| `src/daemon.ts` | Init logger/tracer/metrics, add hourly maintenance, add `POST /api/log` |
| `src/web.ts` | Add `POST /api/log` route, request logging middleware |
| `src/core/indexer.ts` | Instrument `indexAll()` with logger + tracer spans |
| `src/core/viking-bridge.ts` | Instrument `push()`/`find()` with logger + tracer |
| `src/tools/search.ts` | Add search tracing (FTS + Viking durations) |
| `src/tools/*.ts` | Add logger to all 16 tool handlers |
| `src/cli/index.ts` | Add subcommand dispatcher for `logs`/`traces`/`health`/`diagnose` |
| `macos/Engram/Models/Screen.swift` | Add `case observability` in Monitor section |
| `macos/Engram/Core/IndexerProcess.swift` | Replace ad-hoc logging with EngramLogger |
| `macos/project.yml` | Add new Swift source files |

### Test Files
| File | Tests |
|------|-------|
| `tests/core/logger.test.ts` | Log creation, level filtering, rate limiting, SQLite write, rotation |
| `tests/core/tracer.test.ts` | Span lifecycle, nesting, INSERT OR IGNORE, propagation |
| `tests/core/metrics.test.ts` | Buffer flush, sampling, rollup, batch insert |
| `tests/core/error-serializer.test.ts` | Error instances, strings, unknown types |
| `tests/cli/logs.test.ts` | CLI arg parsing, SQLite queries, JSON output |
| `tests/cli/traces.test.ts` | Slow query, name filter, trace detail |
| `tests/cli/health.test.ts` | Health output, diagnose time range |

---

## Task 1: SQLite Schema — Observability Tables

**Files:**
- Modify: `src/core/db.ts` (add to `migrate()`)
- Test: `tests/core/logger.test.ts` (schema validation)

- [ ] **Step 1: Write schema test**

```typescript
// tests/core/logger.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import BetterSqlite3 from 'better-sqlite3'
import { Database } from '../../src/core/db.js'

describe('observability schema', () => {
  let db: Database
  beforeEach(() => { db = new Database(':memory:') })
  afterEach(() => { db.close() })

  it('creates logs table with correct columns', () => {
    const cols = db.raw.pragma('table_info(logs)').map((c: any) => c.name)
    expect(cols).toContain('ts')
    expect(cols).toContain('level')
    expect(cols).toContain('module')
    expect(cols).toContain('trace_id')
    expect(cols).toContain('source')
    expect(cols).toContain('error_stack')
  })

  it('creates traces table with span_id index', () => {
    const cols = db.raw.pragma('table_info(traces)').map((c: any) => c.name)
    expect(cols).toContain('trace_id')
    expect(cols).toContain('span_id')
    expect(cols).toContain('duration_ms')
    expect(cols).toContain('status')
  })

  it('creates metrics and metrics_hourly tables', () => {
    const metricsCols = db.raw.pragma('table_info(metrics)').map((c: any) => c.name)
    expect(metricsCols).toContain('name')
    expect(metricsCols).toContain('type')
    expect(metricsCols).toContain('value')
    const hourlyCols = db.raw.pragma('table_info(metrics_hourly)').map((c: any) => c.name)
    expect(hourlyCols).toContain('p95')
    expect(hourlyCols).toContain('hour')
  })

  it('enforces level check constraint on logs', () => {
    expect(() => {
      db.raw.prepare("INSERT INTO logs (level, module, message, source) VALUES ('invalid', 'test', 'msg', 'daemon')").run()
    }).toThrow()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/core/logger.test.ts`
Expected: FAIL — `logs` table does not exist.

- [ ] **Step 3: Add migrations to db.ts**

In `src/core/db.ts`, inside `migrate()`, after existing table creations, add:

```typescript
// Observability tables
db.exec(`
  CREATE TABLE IF NOT EXISTS logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    level TEXT NOT NULL CHECK (level IN ('debug', 'info', 'warn', 'error')),
    module TEXT NOT NULL,
    trace_id TEXT,
    span_id TEXT,
    message TEXT NOT NULL,
    data TEXT,
    error_name TEXT,
    error_message TEXT,
    error_stack TEXT,
    source TEXT NOT NULL CHECK (source IN ('daemon', 'app'))
  );
  CREATE INDEX IF NOT EXISTS idx_logs_ts ON logs(ts);
  CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);
  CREATE INDEX IF NOT EXISTS idx_logs_module ON logs(module);
  CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON logs(trace_id);
  CREATE INDEX IF NOT EXISTS idx_logs_source_ts ON logs(source, ts);

  CREATE TABLE IF NOT EXISTS traces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trace_id TEXT NOT NULL,
    span_id TEXT NOT NULL,
    parent_span_id TEXT,
    name TEXT NOT NULL,
    module TEXT NOT NULL,
    start_ts TEXT NOT NULL,
    end_ts TEXT,
    duration_ms INTEGER,
    status TEXT NOT NULL DEFAULT 'ok',
    attributes TEXT,
    source TEXT NOT NULL CHECK (source IN ('daemon', 'app'))
  );
  CREATE INDEX IF NOT EXISTS idx_traces_span_id ON traces(span_id);
  CREATE INDEX IF NOT EXISTS idx_traces_trace_id ON traces(trace_id);
  CREATE INDEX IF NOT EXISTS idx_traces_name ON traces(name);
  CREATE INDEX IF NOT EXISTS idx_traces_start_ts ON traces(start_ts);
  CREATE INDEX IF NOT EXISTS idx_traces_duration ON traces(duration_ms);

  CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('counter', 'gauge', 'histogram')),
    value REAL NOT NULL,
    tags TEXT,
    ts TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_metrics_name_ts ON metrics(name, ts);
  CREATE INDEX IF NOT EXISTS idx_metrics_name_type ON metrics(name, type);

  CREATE TABLE IF NOT EXISTS metrics_hourly (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    hour TEXT NOT NULL,
    count INTEGER NOT NULL,
    sum REAL NOT NULL,
    min REAL NOT NULL,
    max REAL NOT NULL,
    p95 REAL,
    tags TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_metrics_hourly_name ON metrics_hourly(name, hour);
`)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- tests/core/logger.test.ts`
Expected: PASS

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `npm test`
Expected: All 427+ tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/core/db.ts tests/core/logger.test.ts
git commit -m "feat(observability): add logs/traces/metrics SQLite schema"
```

---

## Task 2: Error Serializer

**Files:**
- Create: `src/core/error-serializer.ts`
- Test: `tests/core/error-serializer.test.ts`

- [ ] **Step 1: Write tests**

```typescript
// tests/core/error-serializer.test.ts
import { describe, it, expect } from 'vitest'
import { serializeError } from '../../src/core/error-serializer.js'

describe('serializeError', () => {
  it('serializes Error instances with stack', () => {
    const err = new Error('fail')
    const result = serializeError(err)
    expect(result.name).toBe('Error')
    expect(result.message).toBe('fail')
    expect(result.stack).toContain('fail')
  })

  it('serializes TypeError', () => {
    const err = new TypeError('bad type')
    const result = serializeError(err)
    expect(result.name).toBe('TypeError')
  })

  it('serializes Error with code property', () => {
    const err = Object.assign(new Error('enoent'), { code: 'ENOENT' })
    const result = serializeError(err)
    expect(result.code).toBe('ENOENT')
  })

  it('serializes string errors', () => {
    const result = serializeError('something broke')
    expect(result.name).toBe('UnknownError')
    expect(result.message).toBe('something broke')
    expect(result.stack).toBeUndefined()
  })

  it('serializes null/undefined', () => {
    expect(serializeError(null).message).toBe('null')
    expect(serializeError(undefined).message).toBe('undefined')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/core/error-serializer.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```typescript
// src/core/error-serializer.ts
export interface SerializedError {
  name: string
  message: string
  stack?: string
  code?: string
}

export function serializeError(err: unknown): SerializedError {
  if (err instanceof Error) {
    return {
      name: err.name,
      message: err.message,
      stack: err.stack,
      code: (err as any).code,
    }
  }
  return { name: 'UnknownError', message: String(err) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- tests/core/error-serializer.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/error-serializer.ts tests/core/error-serializer.test.ts
git commit -m "feat(observability): add error serializer utility"
```

---

## Task 3: Logger Core

**Files:**
- Create: `src/core/logger.ts`
- Test: `tests/core/logger.test.ts` (extend from Task 1)

- [ ] **Step 1: Write logger tests**

Add to `tests/core/logger.test.ts`:

```typescript
import { createLogger, type LogWriter } from '../../src/core/logger.js'

describe('createLogger', () => {
  it('creates logger with module name', () => {
    const log = createLogger('indexer')
    expect(log).toBeDefined()
    expect(log.info).toBeTypeOf('function')
    expect(log.error).toBeTypeOf('function')
    expect(log.warn).toBeTypeOf('function')
    expect(log.debug).toBeTypeOf('function')
  })
})

describe('log writing', () => {
  let db: Database
  let writer: LogWriter
  beforeEach(() => {
    db = new Database(':memory:')
    writer = new LogWriter(db.raw)
  })
  afterEach(() => { db.close() })

  it('writes info log to SQLite', () => {
    writer.write({ level: 'info', module: 'test', message: 'hello', source: 'daemon' })
    const rows = db.raw.prepare('SELECT * FROM logs').all() as any[]
    expect(rows).toHaveLength(1)
    expect(rows[0].level).toBe('info')
    expect(rows[0].module).toBe('test')
    expect(rows[0].message).toBe('hello')
  })

  it('writes error with serialized error data', () => {
    writer.write({
      level: 'error', module: 'test', message: 'fail', source: 'daemon',
      error: { name: 'Error', message: 'oops', stack: 'at line 1' },
    })
    const row = db.raw.prepare('SELECT * FROM logs').get() as any
    expect(row.error_name).toBe('Error')
    expect(row.error_message).toBe('oops')
    expect(row.error_stack).toBe('at line 1')
  })

  it('writes structured data as JSON', () => {
    writer.write({
      level: 'info', module: 'test', message: 'indexed', source: 'daemon',
      data: { sessionId: 'abc', count: 42 },
    })
    const row = db.raw.prepare('SELECT * FROM logs').get() as any
    expect(JSON.parse(row.data)).toEqual({ sessionId: 'abc', count: 42 })
  })

  it('respects level filtering', () => {
    const log = createLogger('test', { writer, level: 'warn' })
    log.info('should be skipped')
    log.warn('should appear')
    const rows = db.raw.prepare('SELECT * FROM logs').all()
    expect(rows).toHaveLength(1)
  })
})

describe('debug rate limiting', () => {
  let db: Database
  let writer: LogWriter
  beforeEach(() => {
    db = new Database(':memory:')
    writer = new LogWriter(db.raw)
  })
  afterEach(() => { db.close() })

  it('throttles debug logs beyond 100/min per module', () => {
    const log = createLogger('watcher', { writer, level: 'debug', rateLimitPerMin: 5 })
    for (let i = 0; i < 10; i++) log.debug(`msg ${i}`)
    const rows = db.raw.prepare('SELECT * FROM logs').all()
    // Should have 5 regular + 1 suppression summary = 6 max
    expect(rows.length).toBeLessThanOrEqual(6)
  })
})

describe('log rotation', () => {
  let db: Database
  let writer: LogWriter
  beforeEach(() => {
    db = new Database(':memory:')
    writer = new LogWriter(db.raw)
  })
  afterEach(() => { db.close() })

  it('deletes logs older than retention days', () => {
    // Insert old log
    db.raw.prepare(
      "INSERT INTO logs (ts, level, module, message, source) VALUES ('2020-01-01T00:00:00.000', 'info', 'test', 'old', 'daemon')"
    ).run()
    writer.write({ level: 'info', module: 'test', message: 'new', source: 'daemon' })
    writer.rotate(7)
    const rows = db.raw.prepare('SELECT * FROM logs').all()
    expect(rows).toHaveLength(1)
  })

  it('enforces max row cap', () => {
    for (let i = 0; i < 20; i++) {
      writer.write({ level: 'info', module: 'test', message: `msg ${i}`, source: 'daemon' })
    }
    writer.enforceMaxRows(10)
    const rows = db.raw.prepare('SELECT * FROM logs').all()
    expect(rows).toHaveLength(10)
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/core/logger.test.ts`
Expected: FAIL — `logger.ts` not found.

- [ ] **Step 3: Implement logger**

```typescript
// src/core/logger.ts
import type BetterSqlite3 from 'better-sqlite3'
import { serializeError, type SerializedError } from './error-serializer.js'

export type LogLevel = 'debug' | 'info' | 'warn' | 'error'

const LEVEL_ORDER: Record<LogLevel, number> = { debug: 0, info: 1, warn: 2, error: 3 }

export interface LogEntry {
  ts?: string
  level: LogLevel
  module: string
  traceId?: string
  spanId?: string
  message: string
  data?: Record<string, unknown>
  error?: SerializedError
  source: 'daemon' | 'app'
}

export interface Logger {
  debug(message: string, data?: Record<string, unknown>): void
  info(message: string, data?: Record<string, unknown>): void
  warn(message: string, data?: Record<string, unknown>): void
  error(message: string, data?: Record<string, unknown>, err?: unknown): void
  child(extra: { traceId?: string; spanId?: string }): Logger
}

export class LogWriter {
  private insertStmt: BetterSqlite3.Statement

  constructor(private db: BetterSqlite3.Database) {
    this.insertStmt = db.prepare(`
      INSERT INTO logs (ts, level, module, trace_id, span_id, message, data, error_name, error_message, error_stack, source)
      VALUES (@ts, @level, @module, @traceId, @spanId, @message, @data, @errorName, @errorMessage, @errorStack, @source)
    `)
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
    })
  }

  rotate(retentionDays: number): void {
    const cutoff = new Date(Date.now() - retentionDays * 86400000).toISOString()
    this.db.prepare('DELETE FROM logs WHERE ts < ?').run(cutoff)
  }

  enforceMaxRows(maxRows: number): void {
    const count = (this.db.prepare('SELECT COUNT(*) as c FROM logs').get() as any).c
    if (count > maxRows) {
      this.db.prepare(
        `DELETE FROM logs WHERE id IN (SELECT id FROM logs ORDER BY ts ASC LIMIT ?)`
      ).run(count - maxRows)
    }
  }
}

interface LoggerOpts {
  writer?: LogWriter
  level?: LogLevel
  rateLimitPerMin?: number
  traceId?: string
  spanId?: string
}

export function createLogger(module: string, opts: LoggerOpts = {}): Logger {
  const minLevel = LEVEL_ORDER[opts.level ?? 'info']
  const writer = opts.writer
  const rateLimit = opts.rateLimitPerMin ?? 100
  let debugCount = 0
  let debugWindowStart = Date.now()
  let suppressed = 0

  function shouldLog(level: LogLevel): boolean {
    if (LEVEL_ORDER[level] < minLevel) return false
    if (level === 'debug') {
      const now = Date.now()
      if (now - debugWindowStart > 60000) {
        if (suppressed > 0 && writer) {
          writer.write({ level: 'info', module, message: `[${module}] ${suppressed} debug messages suppressed in last 60s`, source: 'daemon' })
        }
        debugCount = 0
        suppressed = 0
        debugWindowStart = now
      }
      debugCount++
      if (debugCount > rateLimit) {
        suppressed++
        return false
      }
    }
    return true
  }

  function log(level: LogLevel, message: string, data?: Record<string, unknown>, err?: unknown): void {
    if (!shouldLog(level)) return
    const entry: LogEntry = {
      level, module, message, source: 'daemon',
      traceId: opts.traceId,
      spanId: opts.spanId,
      data,
      error: err ? serializeError(err) : undefined,
    }
    writer?.write(entry)
    // Also write to stderr in dev mode
    if (process.env.ENGRAM_LOG_LEVEL) {
      process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), level, module, message }) + '\n')
    }
  }

  return {
    debug: (msg, data) => log('debug', msg, data),
    info: (msg, data) => log('info', msg, data),
    warn: (msg, data) => log('warn', msg, data),
    error: (msg, data, err) => log('error', msg, data, err),
    child: (extra) => createLogger(module, { ...opts, ...extra }),
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/core/logger.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/logger.ts tests/core/logger.test.ts
git commit -m "feat(observability): add structured logger with rate limiting and rotation"
```

---

## Task 4: Tracer Core

**Files:**
- Create: `src/core/tracer.ts`
- Test: `tests/core/tracer.test.ts`

- [ ] **Step 1: Write tracer tests**

```typescript
// tests/core/tracer.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import { Tracer, TraceWriter } from '../../src/core/tracer.js'

describe('Tracer', () => {
  let db: Database
  let writer: TraceWriter
  let tracer: Tracer

  beforeEach(() => {
    db = new Database(':memory:')
    writer = new TraceWriter(db.raw)
    tracer = new Tracer(writer)
  })
  afterEach(() => { db.close() })

  it('creates a span with traceId and spanId', () => {
    const span = tracer.startSpan('indexer.indexSession', 'indexer')
    expect(span.traceId).toBeTruthy()
    expect(span.spanId).toBeTruthy()
    expect(span.name).toBe('indexer.indexSession')
  })

  it('writes completed span to SQLite', () => {
    const span = tracer.startSpan('test.op', 'test')
    span.end()
    const rows = db.raw.prepare('SELECT * FROM traces').all() as any[]
    expect(rows).toHaveLength(1)
    expect(rows[0].name).toBe('test.op')
    expect(rows[0].status).toBe('ok')
    expect(rows[0].duration_ms).toBeGreaterThanOrEqual(0)
  })

  it('records error status on span', () => {
    const span = tracer.startSpan('test.fail', 'test')
    span.setError(new Error('boom'))
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(row.status).toBe('error')
    expect(JSON.parse(row.attributes).error).toBe('boom')
  })

  it('supports nested spans with parent', () => {
    const parent = tracer.startSpan('parent.op', 'test')
    const child = tracer.startSpan('child.op', 'test', { parentSpan: parent })
    child.end()
    parent.end()
    const rows = db.raw.prepare('SELECT * FROM traces ORDER BY id').all() as any[]
    expect(rows).toHaveLength(2)
    expect(rows[0].parent_span_id).toBe(parent.spanId)
    expect(rows[0].trace_id).toBe(parent.traceId)
  })

  it('uses INSERT OR IGNORE for duplicate spanIds', () => {
    const span = tracer.startSpan('test.dup', 'test')
    span.end()
    // Manually insert same spanId — should not throw
    expect(() => {
      writer.write({
        traceId: span.traceId, spanId: span.spanId,
        name: 'test.dup2', module: 'test', startTs: new Date().toISOString(),
        status: 'ok', source: 'daemon',
      })
    }).not.toThrow()
  })

  it('sets attributes on span', () => {
    const span = tracer.startSpan('test.attrs', 'test', { attributes: { sessionId: 'abc' } })
    span.end()
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(JSON.parse(row.attributes).sessionId).toBe('abc')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/core/tracer.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement tracer**

```typescript
// src/core/tracer.ts
import { randomUUID } from 'crypto'
import type BetterSqlite3 from 'better-sqlite3'

export interface SpanData {
  traceId: string
  spanId: string
  parentSpanId?: string
  name: string
  module: string
  startTs: string
  endTs?: string
  durationMs?: number
  status: 'ok' | 'error'
  attributes?: Record<string, unknown>
  source: 'daemon' | 'app'
}

export class TraceWriter {
  private insertStmt: BetterSqlite3.Statement

  constructor(private db: BetterSqlite3.Database) {
    this.insertStmt = db.prepare(`
      INSERT OR IGNORE INTO traces (trace_id, span_id, parent_span_id, name, module, start_ts, end_ts, duration_ms, status, attributes, source)
      VALUES (@traceId, @spanId, @parentSpanId, @name, @module, @startTs, @endTs, @durationMs, @status, @attributes, @source)
    `)
  }

  write(span: SpanData): void {
    this.insertStmt.run({
      traceId: span.traceId,
      spanId: span.spanId,
      parentSpanId: span.parentSpanId ?? null,
      name: span.name,
      module: span.module,
      startTs: span.startTs,
      endTs: span.endTs ?? null,
      durationMs: span.durationMs ?? null,
      status: span.status,
      attributes: span.attributes ? JSON.stringify(span.attributes) : null,
      source: span.source,
    })
  }
}

export interface Span {
  traceId: string
  spanId: string
  name: string
  end(): void
  setError(err: unknown): void
  setAttribute(key: string, value: unknown): void
}

export class Tracer {
  constructor(private writer: TraceWriter) {}

  startSpan(name: string, module: string, opts?: {
    parentSpan?: Span
    traceId?: string
    attributes?: Record<string, unknown>
  }): Span {
    const traceId = opts?.traceId ?? opts?.parentSpan?.traceId ?? randomUUID()
    const spanId = randomUUID()
    const parentSpanId = opts?.parentSpan?.spanId
    const startTs = new Date().toISOString()
    const startTime = Date.now()
    const attributes: Record<string, unknown> = { ...opts?.attributes }
    let ended = false

    const span: Span = {
      traceId,
      spanId,
      name,
      end: () => {
        if (ended) return
        ended = true
        this.writer.write({
          traceId, spanId, parentSpanId, name, module, startTs,
          endTs: new Date().toISOString(),
          durationMs: Date.now() - startTime,
          status: 'ok',
          attributes: Object.keys(attributes).length > 0 ? attributes : undefined,
          source: 'daemon',
        })
      },
      setError: (err: unknown) => {
        if (ended) return
        ended = true
        attributes.error = err instanceof Error ? err.message : String(err)
        this.writer.write({
          traceId, spanId, parentSpanId, name, module, startTs,
          endTs: new Date().toISOString(),
          durationMs: Date.now() - startTime,
          status: 'error',
          attributes,
          source: 'daemon',
        })
      },
      setAttribute: (key, value) => { attributes[key] = value },
    }
    return span
  }
}
```

- [ ] **Step 4: Run tests**

Run: `npm test -- tests/core/tracer.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/tracer.ts tests/core/tracer.test.ts
git commit -m "feat(observability): add span tracer with INSERT OR IGNORE"
```

---

## Task 5: Metrics Collector

**Files:**
- Create: `src/core/metrics.ts`
- Test: `tests/core/metrics.test.ts`

- [ ] **Step 1: Write metrics tests**

```typescript
// tests/core/metrics.test.ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { Database } from '../../src/core/db.js'
import { MetricsCollector } from '../../src/core/metrics.js'

describe('MetricsCollector', () => {
  let db: Database
  let metrics: MetricsCollector

  beforeEach(() => {
    db = new Database(':memory:')
    metrics = new MetricsCollector(db.raw, { flushIntervalMs: 0 }) // immediate flush for tests
  })
  afterEach(() => { db.close() })

  it('records counter metric', () => {
    metrics.counter('tool.invocations', 1, { tool: 'search' })
    metrics.flush()
    const rows = db.raw.prepare('SELECT * FROM metrics').all() as any[]
    expect(rows).toHaveLength(1)
    expect(rows[0].name).toBe('tool.invocations')
    expect(rows[0].type).toBe('counter')
    expect(rows[0].value).toBe(1)
    expect(JSON.parse(rows[0].tags)).toEqual({ tool: 'search' })
  })

  it('records gauge metric', () => {
    metrics.gauge('daemon.memory_mb', 128)
    metrics.flush()
    const row = db.raw.prepare('SELECT * FROM metrics').get() as any
    expect(row.type).toBe('gauge')
    expect(row.value).toBe(128)
  })

  it('records histogram metric', () => {
    metrics.histogram('search.fts_duration_ms', 42)
    metrics.flush()
    const row = db.raw.prepare('SELECT * FROM metrics').get() as any
    expect(row.type).toBe('histogram')
    expect(row.value).toBe(42)
  })

  it('buffers and batch flushes', () => {
    for (let i = 0; i < 10; i++) metrics.counter('test.count', 1)
    // Not flushed yet (no auto-flush in test mode)
    expect(db.raw.prepare('SELECT COUNT(*) as c FROM metrics').get() as any).toEqual({ c: 0 })
    metrics.flush()
    expect((db.raw.prepare('SELECT COUNT(*) as c FROM metrics').get() as any).c).toBe(10)
  })

  it('samples high-frequency metrics', () => {
    const sampled = new MetricsCollector(db.raw, { flushIntervalMs: 0, sampleRates: { 'db.query_duration_ms': 0.0 } })
    for (let i = 0; i < 100; i++) sampled.histogram('db.query_duration_ms', i)
    sampled.flush()
    // 0% sample rate = no rows
    expect((db.raw.prepare('SELECT COUNT(*) as c FROM metrics').get() as any).c).toBe(0)
  })

  it('flushes when buffer reaches max size', () => {
    const autoFlush = new MetricsCollector(db.raw, { flushIntervalMs: 0, maxBufferSize: 5 })
    for (let i = 0; i < 6; i++) autoFlush.counter('test', 1)
    // Should have auto-flushed at 5
    expect((db.raw.prepare('SELECT COUNT(*) as c FROM metrics').get() as any).c).toBeGreaterThanOrEqual(5)
  })
})

describe('metrics rollup', () => {
  let db: Database
  let metrics: MetricsCollector

  beforeEach(() => {
    db = new Database(':memory:')
    metrics = new MetricsCollector(db.raw, { flushIntervalMs: 0 })
  })
  afterEach(() => { db.close() })

  it('rolls up raw metrics into hourly summaries', () => {
    // Insert raw histogram data for a specific hour
    const hour = '2026-03-22T14'
    for (const v of [10, 20, 30, 40, 50]) {
      db.raw.prepare(
        "INSERT INTO metrics (name, type, value, ts) VALUES ('test.duration', 'histogram', ?, ?)"
      ).run(v, `${hour}:30:00.000`)
    }
    metrics.rollup()
    const row = db.raw.prepare('SELECT * FROM metrics_hourly').get() as any
    expect(row.name).toBe('test.duration')
    expect(row.count).toBe(5)
    expect(row.min).toBe(10)
    expect(row.max).toBe(50)
    expect(row.sum).toBe(150)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/core/metrics.test.ts`

- [ ] **Step 3: Implement metrics collector**

Create `src/core/metrics.ts` with:
- `MetricsCollector` class: `counter()`, `gauge()`, `histogram()` methods
- In-memory buffer array, `flush()` writes batch via prepared transaction
- `maxBufferSize` (default 1000) triggers auto-flush
- `sampleRates` map: per-metric sampling (default 1.0, `db.query_duration_ms` = 0.1)
- `rollup()` method: aggregate raw rows into `metrics_hourly` (group by name + `substr(ts, 1, 13)` as hour — e.g., `'2026-03-22T14'`). Use consistent hour extraction: `substr(ts, 1, 13)` matches the test's `${hour}:30:00.000` pattern
- `rotate(hours: number)` method: delete raw rows older than N hours

- [ ] **Step 4: Run tests**

Run: `npm test -- tests/core/metrics.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/metrics.ts tests/core/metrics.test.ts
git commit -m "feat(observability): add metrics collector with buffering and sampling"
```

---

## Task 6: CLI Subcommand Dispatcher

**Files:**
- Modify: `src/cli/index.ts`
- Create: `src/cli/logs.ts`, `src/cli/traces.ts`, `src/cli/health.ts`
- Test: `tests/cli/logs.test.ts`, `tests/cli/traces.test.ts`, `tests/cli/health.test.ts`

- [ ] **Step 1: Write CLI tests**

```typescript
// tests/cli/logs.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import BetterSqlite3 from 'better-sqlite3'
import { Database } from '../../src/core/db.js'
import { queryLogs } from '../../src/cli/logs.js'

describe('queryLogs', () => {
  let db: Database
  beforeEach(() => {
    db = new Database(':memory:')
    // Insert test logs
    const stmt = db.raw.prepare(
      "INSERT INTO logs (ts, level, module, message, source) VALUES (?, ?, ?, ?, 'daemon')"
    )
    stmt.run('2026-03-22T10:00:00.000', 'info', 'indexer', 'indexed session')
    stmt.run('2026-03-22T11:00:00.000', 'error', 'viking', 'timeout')
    stmt.run('2026-03-22T12:00:00.000', 'debug', 'watcher', 'file changed')
  })
  afterEach(() => { db.close() })

  it('returns all logs by default', () => {
    const result = queryLogs(db.raw, {})
    expect(result).toHaveLength(3)
  })

  it('filters by level', () => {
    const result = queryLogs(db.raw, { level: 'error' })
    expect(result).toHaveLength(1)
    expect(result[0].module).toBe('viking')
  })

  it('filters by module', () => {
    const result = queryLogs(db.raw, { module: 'indexer' })
    expect(result).toHaveLength(1)
  })

  it('respects limit', () => {
    const result = queryLogs(db.raw, { limit: 2 })
    expect(result).toHaveLength(2)
  })
})
```

- [ ] **Step 2: Run to verify fail**

Run: `npm test -- tests/cli/logs.test.ts`

- [ ] **Step 3: Implement `src/cli/logs.ts`**

Export `queryLogs(db, filters)` function that builds SQL WHERE clauses from filters (`level`, `module`, `traceId`, `since`, `limit`) and returns log rows. Also export `formatLogs(rows, json: boolean)` for CLI output.

- [ ] **Step 4: Implement `src/cli/traces.ts`**

Export `queryTraces(db, filters)` with filters: `slow` (min duration), `name` (pattern), `traceId`. Export `formatTraces()`.

- [ ] **Step 5: Implement `src/cli/health.ts`**

Export `queryHealth(db)` (returns DB size, row counts, daemon PID if running). Export `diagnose(db, opts)` with `last` time range filter.

- [ ] **Step 6: Update `src/cli/index.ts` dispatcher**

```typescript
#!/usr/bin/env node
const args = process.argv.slice(2)
const subcommand = args[0]

if (subcommand === 'logs') {
  import('./logs.js').then(m => m.main(args.slice(1)))
} else if (subcommand === 'traces') {
  import('./traces.js').then(m => m.main(args.slice(1)))
} else if (subcommand === 'health' || subcommand === 'diagnose') {
  import('./health.js').then(m => m.main(subcommand, args.slice(1)))
} else if (args.includes('--resume') || args.includes('-r')) {
  import('./resume.js')
} else {
  import('../index.js')
}
```

- [ ] **Step 7: Run all CLI tests**

Run: `npm test -- tests/cli/`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add src/cli/ tests/cli/
git commit -m "feat(observability): add CLI log/trace/health diagnostic commands"
```

---

## Task 7: Daemon Integration — Init + Maintenance + POST /api/log

**Files:**
- Modify: `src/daemon.ts`
- Modify: `src/web.ts`

- [ ] **Step 1: Add logger/tracer/metrics initialization to daemon.ts**

At the top of the main daemon function, after `Database` creation:

```typescript
import { createLogger, LogWriter } from './core/logger.js'
import { Tracer, TraceWriter } from './core/tracer.js'
import { MetricsCollector } from './core/metrics.js'

// Initialize observability
const logWriter = new LogWriter(db.raw)
const traceWriter = new TraceWriter(db.raw)
const metrics = new MetricsCollector(db.raw, {
  flushIntervalMs: 5000,
  sampleRates: { 'db.query_duration_ms': 0.1 },
})
const tracer = new Tracer(traceWriter)
const log = createLogger('daemon', { writer: logWriter, level: settings.observability?.logLevel ?? 'info' })

log.info('daemon starting', { version: pkg.version })
```

- [ ] **Step 2: Add hourly maintenance timers**

```typescript
// Log rotation at :00
setInterval(() => {
  const retentionDays = settings.observability?.logRetentionDays ?? 7
  logWriter.rotate(retentionDays)
  logWriter.enforceMaxRows(100_000)
  // Also rotate traces and raw metrics
  db.raw.prepare("DELETE FROM traces WHERE start_ts < ?").run(
    new Date(Date.now() - retentionDays * 86400000).toISOString()
  )
  db.raw.prepare("DELETE FROM metrics WHERE ts < ?").run(
    new Date(Date.now() - 24 * 3600000).toISOString()
  )
}, 3600000) // every hour (NOTE: starts from daemon boot time, not aligned to :00.
            // For clock-aligned rotation, compute delay to next :00 with
            // `setTimeout(() => setInterval(...), msToNextHour())`. Not critical — correctness
            // is the same, only timing aesthetics differ. Can improve later.)

// Metrics rollup offset by 5 min from rotation
setTimeout(() => {
  setInterval(() => { metrics.rollup() }, 3600000)
}, 300000) // same caveat: not aligned to :05, just 5 min after rotation start
```

- [ ] **Step 3: Add POST /api/log route to web.ts**

In `src/web.ts`, inside `createApp()`, add:

```typescript
// Observability: accept log forwarding from Swift app
app.post('/api/log', async (c) => {
  const body = await c.req.json()
  if (opts?.logWriter && body.level && body.module && body.message) {
    opts.logWriter.write({
      level: body.level,
      module: body.module,
      message: body.message,
      data: body.data,
      error: body.error,
      source: 'app',
    })
  }
  return c.json({ ok: true })
})
```

Add `logWriter?: LogWriter` to `createApp()` opts type.

- [ ] **Step 4: Pass logWriter to createApp in daemon.ts**

```typescript
const app = createApp(db, { ...existingOpts, logWriter })
```

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/daemon.ts src/web.ts
git commit -m "feat(observability): integrate logger/tracer/metrics into daemon and web server"
```

---

## Task 8: Instrument Critical Paths

**Files:**
- Modify: `src/core/indexer.ts`
- Modify: `src/core/viking-bridge.ts`
- Modify: `src/tools/search.ts` (and other tools)

- [ ] **Step 1: Instrument indexer**

In `src/core/indexer.ts`, add logger and tracer as constructor options. Wrap `indexAll()` and per-session indexing in spans:

```typescript
const span = this.tracer?.startSpan('indexer.indexSession', 'indexer', {
  attributes: { sessionId, source: adapter.name },
})
try {
  // ... existing indexing logic ...
  span?.end()
} catch (err) {
  span?.setError(err)
  this.log?.error('index failed', { sessionId }, err)
}
```

- [ ] **Step 2: Instrument viking-bridge**

Wrap `push()` and `find()` in spans. Add logger for circuit breaker state changes:

```typescript
this.log?.warn('viking circuit breaker opened', { failCount })
```

- [ ] **Step 3: Instrument search tool**

In `handleSearch()`, wrap FTS and Viking queries in spans:

```typescript
const ftsSpan = tracer?.startSpan('search.fts', 'search', { parentSpan: searchSpan })
// ... FTS query ...
ftsSpan?.end()
```

- [ ] **Step 4: Add logger to remaining tools**

For each tool in `src/tools/*.ts`, add a simple `log.info('tool invoked', { params })` at entry and `log.error()` on catch. Use `createLogger('tool.<name>')`.

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass. (Logger/tracer are optional deps, existing tests don't provide them.)

- [ ] **Step 6: Commit**

```bash
git add src/core/indexer.ts src/core/viking-bridge.ts src/tools/
git commit -m "feat(observability): instrument indexer, viking, and tools with tracing"
```

---

## Task 9: Error Treatment — Replace Silent Catches

**Files:**
- Modify: Multiple files across `src/`

- [ ] **Step 1: Find all silent catches**

Run: `grep -rn '\.catch\s*(\s*(\(\)\s*=>|(_\w*)\s*=>)\s*{\s*}\s*)' src/`

- [ ] **Step 2: Replace each silent catch with structured logging**

For each match, replace `.catch(() => {})` with:
```typescript
.catch(err => log.warn('operation failed silently', { context: 'what it was doing' }, err))
```

Or where the error is truly expected (e.g., optional feature check), use:
```typescript
.catch(() => {}) // intentional: feature detection, failure is expected
```

Add a comment to distinguish intentional from accidental silent catches.

- [ ] **Step 3: Replace String(err) with serializeError**

Run: `grep -rn 'String(err)' src/`

Replace with `serializeError(err)` where the result feeds into logging or error reporting. Leave `String(err)` where it's used for user-facing messages (e.g., MCP tool error responses).

- [ ] **Step 4: Run full test suite**

Run: `npm test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/
git commit -m "fix(observability): replace silent error catches with structured logging"
```

---

## Task 10: Swift EngramLogger

**Files:**
- Create: `macos/Engram/Core/EngramLogger.swift`
- Modify: `macos/Engram/Core/IndexerProcess.swift`
- Modify: `macos/project.yml`

- [ ] **Step 1: Create EngramLogger.swift**

```swift
import Foundation
import os

enum LogModule: String {
    case daemon, database, ui, mcp, indexer, network
}

struct EngramLogger {
    private static let subsystem = "com.engram.app"
    private static var loggers: [LogModule: os.Logger] = [:]
    /// Extra safety net: the primary anti-loop defense is the module != .daemon/.network guard below.
    /// This flag guards against hypothetical synchronous recursion only (unlikely in practice).
    private static var isForwarding = false

    private static func logger(for module: LogModule) -> os.Logger {
        if let cached = loggers[module] { return cached }
        let l = os.Logger(subsystem: subsystem, category: module.rawValue)
        loggers[module] = l
        return l
    }

    static func info(_ message: String, module: LogModule) {
        logger(for: module).info("\(message, privacy: .public)")
    }

    static func warn(_ message: String, module: LogModule) {
        logger(for: module).warning("\(message, privacy: .public)")
        forwardToDaemon(level: "warn", module: module, message: message)
    }

    static func error(_ message: String, module: LogModule, error: Error? = nil) {
        let msg = error.map { "\(message): \($0.localizedDescription)" } ?? message
        logger(for: module).error("\(msg, privacy: .public)")
        forwardToDaemon(level: "error", module: module, message: msg)
    }

    static func debug(_ message: String, module: LogModule) {
        logger(for: module).debug("\(message, privacy: .public)")
    }

    // MARK: - Daemon Forwarding (fire-and-forget)

    private static func forwardToDaemon(level: String, module: LogModule, message: String) {
        // Anti-loop: don't forward daemon/network module errors (which include forwarding failures)
        guard !isForwarding, module != .daemon, module != .network else { return }
        isForwarding = true
        defer { isForwarding = false }

        Task.detached {
            guard let url = URL(string: "http://localhost:3456/api/log") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 2
            let body: [String: Any] = ["level": level, "module": module.rawValue, "message": message]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
```

- [ ] **Step 2: Replace ad-hoc logging in IndexerProcess.swift**

Replace `Self.logger.error(...)` calls with `EngramLogger.error(...)`. Remove the private `logger` property since `EngramLogger` is the centralized wrapper.

- [ ] **Step 3: Update project.yml** (if needed — xcodegen auto-detects new files in `Engram/` dir)

Run: `cd macos && xcodegen generate`

- [ ] **Step 4: Build to verify compilation**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`

- [ ] **Step 5: Commit**

```bash
git add macos/Engram/Core/EngramLogger.swift macos/Engram/Core/IndexerProcess.swift
git commit -m "feat(observability): add Swift EngramLogger with daemon forwarding"
```

---

## Task 11: Screen Enum + Observability UI Page

**Files:**
- Modify: `macos/Engram/Models/Screen.swift`
- Create: `macos/Engram/Views/Pages/ObservabilityView.swift`
- Create: `macos/Engram/Views/Observability/LogStreamView.swift`
- Create: `macos/Engram/Views/Observability/ErrorDashboardView.swift`
- Create: `macos/Engram/Views/Observability/PerformanceView.swift`
- Create: `macos/Engram/Views/Observability/TraceExplorerView.swift`
- Create: `macos/Engram/Views/Observability/SystemHealthView.swift`

- [ ] **Step 1: Add `case observability` to Screen.swift**

Add `case observability` after `case activity`. Update `title` → `"Observability"`, `icon` → `"gauge.open.with.lines.needle.33percent"`. Add to `Section.monitor.screens` array.

- [ ] **Step 2: Create ObservabilityView.swift**

Container view with tab picker (Logs, Errors, Performance, Traces, Health) that switches between sub-views. Uses GRDB `ValueObservation` for log stream, timer-based polling for dashboards.

- [ ] **Step 3: Create LogStreamView.swift**

List of log entries with level/module/time-range filters. Color-coded by level. Expandable rows showing full data/error JSON. Uses `ValueObservation` on `logs` table with 500ms debounce.

- [ ] **Step 4: Create ErrorDashboardView.swift**

Error count by module (bar chart using SwiftUI Charts), recent errors list, error rate sparkline. Refreshes every 30 seconds.

- [ ] **Step 5: Create PerformanceView.swift**

Latency charts for indexing/search/tool execution. p50/p95 values. Slow operations list. Queries `metrics` (last 24h) and `metrics_hourly` (7-day trend). Refreshes every 30 seconds.

- [ ] **Step 6: Create TraceExplorerView.swift**

Trace list with name/duration/status filters. Tap trace → waterfall view showing nested spans with timing bars. On-demand queries, no polling.

- [ ] **Step 7: Create SystemHealthView.swift**

Daemon status, DB file size, WAL size, Viking status, source health (reuse existing `/api/health/sources` data via DaemonClient). Refreshes every 10 seconds.

- [ ] **Step 8: Run xcodegen and build**

```bash
cd macos && xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```

- [ ] **Step 9: Commit**

```bash
git add macos/Engram/Models/Screen.swift macos/Engram/Views/Pages/ObservabilityView.swift macos/Engram/Views/Observability/
git commit -m "feat(observability): add Observability page with logs, errors, performance, traces, health views"
```

---

## Task 12: Final Integration Test

- [ ] **Step 1: Manual smoke test**

1. Run `npm run build && npm run dev` (daemon mode)
2. Verify logs appear in `~/.engram/index.sqlite` `logs` table
3. Run `engram logs --last 5m` and verify output
4. Run `engram health` and verify daemon status
5. Open Engram app → Observability page → verify log stream appears

- [ ] **Step 2: Run full test suite**

Run: `npm test`
Expected: All tests pass including new observability tests.

- [ ] **Step 3: Final commit**

```bash
git commit -m "feat(observability): complete observability system — logger, tracer, metrics, CLI, UI"
```
