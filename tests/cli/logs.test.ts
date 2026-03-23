import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import { queryLogs } from '../../src/cli/logs.js'
import { parseDuration } from '../../src/cli/utils.js'

describe('queryLogs', () => {
  let db: Database
  beforeEach(() => {
    db = new Database(':memory:')
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

describe('parseDuration', () => {
  it('parses minutes', () => {
    const result = parseDuration('30m')
    const diff = Date.now() - new Date(result).getTime()
    expect(diff).toBeGreaterThan(29 * 60000)
    expect(diff).toBeLessThan(31 * 60000)
  })

  it('parses hours', () => {
    const result = parseDuration('1h')
    const diff = Date.now() - new Date(result).getTime()
    expect(diff).toBeGreaterThan(59 * 60000)
    expect(diff).toBeLessThan(61 * 60000)
  })

  it('parses days', () => {
    const result = parseDuration('7d')
    const diff = Date.now() - new Date(result).getTime()
    expect(diff).toBeGreaterThan(6.9 * 86400000)
    expect(diff).toBeLessThan(7.1 * 86400000)
  })

  it('throws on invalid format', () => {
    expect(() => parseDuration('abc')).toThrow()
    expect(() => parseDuration('1x')).toThrow()
  })
})
