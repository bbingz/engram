// tests/core/alert-rules.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import { AlertRuleEngine } from '../../src/core/alert-rules.js'

describe('AlertRuleEngine', () => {
  let db: Database
  let raw: import('better-sqlite3').Database
  let engine: AlertRuleEngine

  beforeEach(() => {
    db = new Database(':memory:')
    raw = db.raw
    engine = new AlertRuleEngine(raw)
  })

  afterEach(() => {
    db.close()
  })

  // ── helpers ──────────────────────────────────────────────────────────────

  function seedMetric(name: string, value: number, ts?: string): void {
    const ts_ = ts ?? new Date().toISOString()
    raw.prepare(
      "INSERT INTO metrics (name, type, value, ts) VALUES (?, 'counter', ?, ?)"
    ).run(name, value, ts_)
  }

  function seedGauge(name: string, value: number, ts?: string): void {
    const ts_ = ts ?? new Date().toISOString()
    raw.prepare(
      "INSERT INTO metrics (name, type, value, ts) VALUES (?, 'gauge', ?, ?)"
    ).run(name, value, ts_)
  }

  function seedHourly(name: string, p95: number, hour?: string): void {
    const hour_ = hour ?? new Date().toISOString().slice(0, 13)
    raw.prepare(`
      INSERT OR REPLACE INTO metrics_hourly (name, type, hour, count, sum, min, max, p95)
      VALUES (?, 'histogram', ?, 1, ?, ?, ?, ?)
    `).run(name, hour_, p95, p95, p95, p95)
  }

  // ── no data ───────────────────────────────────────────────────────────────

  it('returns empty array when no metrics data', () => {
    const alerts = engine.check()
    expect(alerts).toEqual([])
  })

  // ── error_rate ────────────────────────────────────────────────────────────

  it('error_rate: no alert at or below threshold', () => {
    for (let i = 0; i < 10; i++) seedMetric('error.count', 1)
    const alerts = engine.check()
    expect(alerts.find(a => a.rule === 'error_rate')).toBeUndefined()
  })

  it('error_rate: warning at >10 errors in 10min', () => {
    for (let i = 0; i < 11; i++) seedMetric('error.count', 1)
    const alerts = engine.check()
    const a = alerts.find(a => a.rule === 'error_rate')
    expect(a).toBeDefined()
    expect(a!.severity).toBe('warning')
  })

  it('error_rate: critical at >50 errors in 10min', () => {
    for (let i = 0; i < 51; i++) seedMetric('error.count', 1)
    const alerts = engine.check()
    const a = alerts.find(a => a.rule === 'error_rate')
    expect(a).toBeDefined()
    expect(a!.severity).toBe('critical')
  })

  it('error_rate: ignores metrics older than 10 minutes', () => {
    const old = new Date(Date.now() - 15 * 60 * 1000).toISOString()
    for (let i = 0; i < 100; i++) seedMetric('error.count', 1, old)
    const alerts = engine.check()
    expect(alerts.find(a => a.rule === 'error_rate')).toBeUndefined()
  })

  // ── http_error_rate ───────────────────────────────────────────────────────

  it('http_error_rate: warning at >20', () => {
    for (let i = 0; i < 21; i++) seedMetric('http.error_count', 1)
    const alerts = engine.check()
    const a = alerts.find(a => a.rule === 'http_error_rate')
    expect(a).toBeDefined()
    expect(a!.severity).toBe('warning')
  })

  it('http_error_rate: no alert at or below threshold', () => {
    for (let i = 0; i < 20; i++) seedMetric('http.error_count', 1)
    const alerts = engine.check()
    expect(alerts.find(a => a.rule === 'http_error_rate')).toBeUndefined()
  })

  // ── search_latency ────────────────────────────────────────────────────────

  it('search_latency: no alert without data', () => {
    const alerts = engine.check()
    expect(alerts.find(a => a.rule === 'search_latency')).toBeUndefined()
  })

  it('search_latency: warning when p95 >5000ms', () => {
    seedHourly('search.duration_ms', 6000)
    const alerts = engine.check()
    const a = alerts.find(a => a.rule === 'search_latency')
    expect(a).toBeDefined()
    expect(a!.severity).toBe('warning')
  })

  it('search_latency: critical when p95 >15000ms', () => {
    seedHourly('search.duration_ms', 16000)
    const alerts = engine.check()
    const a = alerts.find(a => a.rule === 'search_latency')
    expect(a).toBeDefined()
    expect(a!.severity).toBe('critical')
  })

  // ── db_query_latency ──────────────────────────────────────────────────────

  it('db_query_latency: warning when p95 >500ms', () => {
    seedHourly('db.query_ms', 600)
    const alerts = engine.check()
    const a = alerts.find(a => a.rule === 'db_query_latency')
    expect(a).toBeDefined()
    expect(a!.severity).toBe('warning')
  })

  it('db_query_latency: no alert when p95 within threshold', () => {
    seedHourly('db.query_ms', 400)
    const alerts = engine.check()
    expect(alerts.find(a => a.rule === 'db_query_latency')).toBeUndefined()
  })

  // ── memory_leak ───────────────────────────────────────────────────────────

  it('memory_leak: warning when heap grows >100MB in 3h', () => {
    const now = new Date()
    const threeHoursAgo = new Date(now.getTime() - 3 * 3600 * 1000 - 60000).toISOString()
    seedGauge('process.heap_mb', 200, threeHoursAgo)
    seedGauge('process.heap_mb', 350, now.toISOString())
    const alerts = engine.check()
    const a = alerts.find(a => a.rule === 'memory_leak')
    expect(a).toBeDefined()
    expect(a!.severity).toBe('warning')
  })

  it('memory_leak: no alert when daemon running <3h', () => {
    // Only recent data — no old gauge to compare against
    seedGauge('process.heap_mb', 500)
    const alerts = engine.check()
    expect(alerts.find(a => a.rule === 'memory_leak')).toBeUndefined()
  })

  it('memory_leak: no alert when growth <=100MB', () => {
    const now = new Date()
    const old = new Date(now.getTime() - 4 * 3600 * 1000).toISOString()
    seedGauge('process.heap_mb', 200, old)
    seedGauge('process.heap_mb', 250, now.toISOString())
    const alerts = engine.check()
    expect(alerts.find(a => a.rule === 'memory_leak')).toBeUndefined()
  })

  // ── high_memory ───────────────────────────────────────────────────────────

  it('high_memory: critical when RSS >1024MB', () => {
    seedGauge('process.rss_mb', 1100)
    const alerts = engine.check()
    const a = alerts.find(a => a.rule === 'high_memory')
    expect(a).toBeDefined()
    expect(a!.severity).toBe('critical')
  })

  it('high_memory: no alert when RSS within threshold', () => {
    seedGauge('process.rss_mb', 900)
    const alerts = engine.check()
    expect(alerts.find(a => a.rule === 'high_memory')).toBeUndefined()
  })

  // ── cooldown ──────────────────────────────────────────────────────────────

  it('cooldown: second check within cooldown returns no duplicate alerts', () => {
    for (let i = 0; i < 20; i++) seedMetric('error.count', 1)
    const first = engine.check()
    expect(first.find(a => a.rule === 'error_rate')).toBeDefined()
    // Second check immediately — should be suppressed by cooldown
    const second = engine.check()
    expect(second.find(a => a.rule === 'error_rate')).toBeUndefined()
  })

  // ── persistence ───────────────────────────────────────────────────────────

  it('persistence: alerts are written to alerts table with correct fields', () => {
    for (let i = 0; i < 20; i++) seedMetric('error.count', 1)
    engine.check()
    const rows = raw.prepare("SELECT * FROM alerts WHERE rule = 'error_rate'").all() as any[]
    expect(rows.length).toBe(1)
    expect(rows[0].rule).toBe('error_rate')
    expect(['warning', 'critical']).toContain(rows[0].severity)
    expect(typeof rows[0].message).toBe('string')
    expect(rows[0].message.length).toBeGreaterThan(0)
    expect(typeof rows[0].value).toBe('number')
    expect(typeof rows[0].threshold).toBe('number')
    expect(rows[0].ts).toBeTruthy()
  })
})
