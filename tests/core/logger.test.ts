// tests/core/logger.test.ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import BetterSqlite3 from 'better-sqlite3'
import { Database } from '../../src/core/db.js'
import { createLogger, type LogWriter as LogWriterType } from '../../src/core/logger.js'
import { LogWriter } from '../../src/core/logger.js'

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
  let writer: LogWriterType
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
  let writer: LogWriterType
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
  let writer: LogWriterType
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

import { runWithContext } from '../../src/core/request-context.js'

describe('logger ALS integration', () => {
  let db: Database
  let writer: LogWriterType
  beforeEach(() => { db = new Database(':memory:'); writer = new LogWriter(db.raw) })
  afterEach(() => { db.close() })

  it('auto-fills traceId from ALS request context', () => {
    const log = createLogger('test', { writer, level: 'info' })
    runWithContext({ requestId: 'req-abc', source: 'mcp' }, () => {
      log.info('hello')
    })
    const row = db.raw.prepare('SELECT trace_id FROM logs').get() as any
    expect(row.trace_id).toBe('req-abc')
  })

  it('child() explicit traceId overrides ALS', () => {
    const log = createLogger('test', { writer, level: 'info' })
    runWithContext({ requestId: 'als-id', source: 'http' }, () => {
      const child = log.child({ traceId: 'explicit-id' })
      child.info('from child')
    })
    const row = db.raw.prepare('SELECT trace_id FROM logs').get() as any
    expect(row.trace_id).toBe('explicit-id')
  })

  it('writes nothing to ALS when no context', () => {
    const log = createLogger('test', { writer, level: 'info' })
    log.info('no context')
    const row = db.raw.prepare('SELECT trace_id FROM logs').get() as any
    expect(row.trace_id).toBeNull()
  })
})

describe('logger stderr JSON', () => {
  let db: Database
  let writer: LogWriterType
  let stderrOutput: string[]

  beforeEach(() => {
    db = new Database(':memory:')
    writer = new LogWriter(db.raw)
    stderrOutput = []
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: any) => {
      stderrOutput.push(chunk.toString())
      return true
    })
  })
  afterEach(() => {
    db.close()
    vi.restoreAllMocks()
  })

  it('emits JSON to stderr when stderrJson is true', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: true })
    log.info('test message', { count: 42 })
    expect(stderrOutput).toHaveLength(1)
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.level).toBe('info')
    expect(parsed.module).toBe('test')
    expect(parsed.message).toBe('test message')
    expect(parsed.data).toEqual({ count: 42 })
  })

  it('does NOT emit to stderr when stderrJson is false', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: false })
    log.info('quiet')
    expect(stderrOutput).toHaveLength(0)
  })

  it('includes request_id and request_source from ALS', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: true })
    runWithContext({ requestId: 'req-xyz', source: 'indexer' }, () => {
      log.info('with context')
    })
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.request_id).toBe('req-xyz')
    expect(parsed.request_source).toBe('indexer')
  })

  it('sanitizes PII in stderr output', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: true })
    log.info('key is sk-abcdefghijklmnopqrstuvwx')
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.message).toBe('key is sk-***')
  })

  it('sanitizes PII in SQLite output', () => {
    const log = createLogger('test', { writer, level: 'info' })
    log.info('email user@example.com')
    const row = db.raw.prepare('SELECT message FROM logs').get() as any
    expect(row.message).toBe('email ***@***.***')
  })

  it('does not emit debug to stderr when level is info', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: true })
    log.debug('should be skipped')
    expect(stderrOutput).toHaveLength(0)
  })
})

describe('logger performance', () => {
  it('sanitize + stderr write averages < 100μs per call', () => {
    const db = new Database(':memory:')
    const writer = new LogWriter(db.raw)
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockReturnValue(true)
    const log = createLogger('perf', { writer, level: 'info', stderrJson: true })

    const start = performance.now()
    for (let i = 0; i < 1000; i++) {
      log.info(`message ${i}`, { count: i, path: '/api/sessions' })
    }
    const elapsed = performance.now() - start
    const avgUs = (elapsed / 1000) * 1000  // ms to μs

    expect(avgUs).toBeLessThan(process.env.CI ? 500 : 100)
    stderrSpy.mockRestore()
    db.close()
  })
})
