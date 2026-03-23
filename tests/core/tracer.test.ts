// tests/core/tracer.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import { Tracer, TraceWriter } from '../../src/core/tracer.js'
import { runWithContext } from '../../src/core/request-context.js'
import { withSpan, withSpanSync } from '../../src/core/tracer.js'

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

describe('Tracer ALS integration', () => {
  let db: Database
  let writer: TraceWriter
  let tracer: Tracer
  beforeEach(() => { db = new Database(':memory:'); writer = new TraceWriter(db.raw); tracer = new Tracer(writer) })
  afterEach(() => { db.close() })

  it('inherits traceId from ALS when no explicit opts', () => {
    runWithContext({ requestId: 'als-trace', source: 'mcp' }, () => {
      const span = tracer.startSpan('test.op', 'test')
      expect(span.traceId).toBe('als-trace')
      span.end()
    })
  })

  it('explicit traceId overrides ALS', () => {
    runWithContext({ requestId: 'als-id', source: 'http' }, () => {
      const span = tracer.startSpan('test.op', 'test', { traceId: 'explicit' })
      expect(span.traceId).toBe('explicit')
      span.end()
    })
  })

  it('multiple spans in same ALS context share traceId', () => {
    runWithContext({ requestId: 'shared', source: 'indexer' }, () => {
      const s1 = tracer.startSpan('op1', 'test')
      const s2 = tracer.startSpan('op2', 'test')
      expect(s1.traceId).toBe('shared')
      expect(s2.traceId).toBe('shared')
      s1.end()
      s2.end()
    })
  })
})

describe('withSpan', () => {
  let db: Database
  let writer: TraceWriter
  let tracer: Tracer
  beforeEach(() => { db = new Database(':memory:'); writer = new TraceWriter(db.raw); tracer = new Tracer(writer) })
  afterEach(() => { db.close() })

  it('records successful span with duration', async () => {
    const result = await withSpan(tracer, 'test.ok', 'test', async (span) => {
      span.setAttribute('key', 'val')
      return 42
    })
    expect(result).toBe(42)
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(row.status).toBe('ok')
    expect(row.duration_ms).toBeGreaterThanOrEqual(0)
    expect(JSON.parse(row.attributes).key).toBe('val')
  })

  it('records error span and re-throws', async () => {
    await expect(
      withSpan(tracer, 'test.fail', 'test', async () => { throw new Error('boom') })
    ).rejects.toThrow('boom')
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(row.status).toBe('error')
  })

  it('does not double-write span on error', async () => {
    await expect(
      withSpan(tracer, 'test.fail', 'test', async () => { throw new Error('x') })
    ).rejects.toThrow()
    const rows = db.raw.prepare('SELECT * FROM traces').all()
    expect(rows).toHaveLength(1)
  })
})

describe('withSpanSync', () => {
  let db: Database
  let writer: TraceWriter
  let tracer: Tracer
  beforeEach(() => { db = new Database(':memory:'); writer = new TraceWriter(db.raw); tracer = new Tracer(writer) })
  afterEach(() => { db.close() })

  it('records successful sync span', () => {
    const result = withSpanSync(tracer, 'sync.ok', 'test', (span) => {
      span.setAttribute('rows', 10)
      return 'done'
    })
    expect(result).toBe('done')
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(row.status).toBe('ok')
  })

  it('records error sync span and re-throws', () => {
    expect(() =>
      withSpanSync(tracer, 'sync.fail', 'test', () => { throw new Error('sync boom') })
    ).toThrow('sync boom')
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(row.status).toBe('error')
  })
})
