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
