import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'

describe('tool_analytics', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
    // Insert test sessions
    db.getRawDb().exec(`INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('s1', 'claude-code', '2026-03-20T10:00:00Z', '/test', 'my-project', 'claude-sonnet-4-6', 10, 3, 5, 1, 1, '/test/s1.jsonl', 1000, 'normal')`)
    // Insert tool data
    db.upsertSessionTools('s1', new Map([['Read', 15], ['Edit', 8], ['Bash', 12], ['Write', 3]]))
  })

  it('returns tool usage sorted by call count', () => {
    const result = db.getToolAnalytics({})
    expect(result.length).toBe(4)
    expect(result[0].name).toBe('Read')
    expect(result[0].callCount).toBe(15)
    expect(result[1].name).toBe('Bash')
  })

  it('filters by project', () => {
    const result = db.getToolAnalytics({ project: 'my-project' })
    expect(result.length).toBe(4)
  })

  it('filters by project with no match', () => {
    const result = db.getToolAnalytics({ project: 'nonexistent' })
    expect(result.length).toBe(0)
  })
})
