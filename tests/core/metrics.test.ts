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
