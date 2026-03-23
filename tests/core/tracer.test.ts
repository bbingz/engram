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
