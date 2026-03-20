import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'

describe('get_costs', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
    // Insert test sessions
    db.getRawDb().exec(`INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('s1', 'claude-code', '2026-03-20T10:00:00Z', '/test', 'test-project', 'claude-sonnet-4-6', 10, 3, 5, 1, 1, '/test/s1.jsonl', 1000, 'normal')`)
    db.getRawDb().exec(`INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('s2', 'claude-code', '2026-03-20T11:00:00Z', '/test', 'test-project', 'claude-opus-4-6', 20, 8, 10, 1, 1, '/test/s2.jsonl', 2000, 'normal')`)
    // Insert cost data
    db.upsertSessionCost('s1', 'claude-sonnet-4-6', 100000, 5000, 50000, 10000, 0.42)
    db.upsertSessionCost('s2', 'claude-opus-4-6', 200000, 10000, 100000, 20000, 4.65)
  })

  it('returns cost summary grouped by model', () => {
    const result = db.getCostsSummary({ groupBy: 'model' })
    expect(result.length).toBe(2)
    expect(result[0].key).toBe('claude-opus-4-6') // higher cost first
    expect(result[0].costUsd).toBeCloseTo(4.65, 1)
  })

  it('returns cost summary grouped by project', () => {
    const result = db.getCostsSummary({ groupBy: 'project' })
    expect(result.length).toBe(1)
    expect(result[0].key).toBe('test-project')
    expect(result[0].sessionCount).toBe(2)
  })

  it('filters by since', () => {
    const result = db.getCostsSummary({ since: '2026-03-20T10:30:00Z' })
    expect(result.length).toBe(1) // only s2
  })
})
