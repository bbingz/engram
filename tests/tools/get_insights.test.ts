// tests/tools/get_insights.test.ts
import { describe, it, expect } from 'vitest'
import { Database } from '../../src/core/db.js'
import { handleGetInsights } from '../../src/tools/get_insights.js'
import type { FileSettings } from '../../src/core/config.js'

const emptyConfig: FileSettings = {}

function makeDb(): Database {
  return new Database(':memory:')
}

describe('handleGetInsights', () => {
  it('returns formatted text content', async () => {
    const db = makeDb()
    const now = new Date()
    const since = new Date(now.getTime() - 3 * 24 * 60 * 60 * 1000).toISOString()

    // Insert session + cost data to trigger at least one suggestion
    db.getRawDb().prepare(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count,
        user_message_count, assistant_message_count, tool_message_count, system_message_count,
        file_path, size_bytes, tier)
      VALUES ('s1', 'claude-code', ?, '/test', 'test', 'claude-opus-4-6', 5,
              2, 2, 1, 0, '/test/s1.jsonl', 1000, 'normal')
    `).run(since)
    db.upsertSessionCost('s1', 'claude-opus-4-6', 100000, 10000, 0, 0, 5.00)

    const result = await handleGetInsights(db, emptyConfig, {})
    expect(result.content).toHaveLength(1)
    expect(result.content[0].type).toBe('text')
    expect(result.content[0].text).toContain('## Cost Insights')
    expect(typeof result.content[0].text).toBe('string')
  })

  it('handles empty data gracefully', async () => {
    const db = makeDb()
    const result = await handleGetInsights(db, emptyConfig, {})
    expect(result.content).toHaveLength(1)
    expect(result.content[0].type).toBe('text')
    expect(result.content[0].text).toContain('## Cost Insights')
    expect(result.content[0].text).toContain('No cost optimization suggestions')
  })
})
