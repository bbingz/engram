import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'
import { handleHandoff } from '../../src/tools/handoff.js'

describe('handoff', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
    // Insert test sessions for "my-project"
    db.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier, summary)
      VALUES ('s1', 'claude-code', '2026-03-20T10:00:00Z', '/home/user/my-project', 'my-project', 'claude-sonnet-4-6', 20, 8, 10, 1, 1, '/test/s1.jsonl', 5000, 'normal', 'Fixed authentication bug in login flow')
    `)
    db.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier, summary)
      VALUES ('s2', 'claude-code', '2026-03-20T08:00:00Z', '/home/user/my-project', 'my-project', 'claude-sonnet-4-6', 15, 5, 8, 1, 1, '/test/s2.jsonl', 3000, 'normal', 'Refactored database connection pooling')
    `)
    // Insert cost data for s1
    db.upsertSessionCost('s1', 'claude-sonnet-4-6', 100000, 5000, 50000, 10000, 0.42)
  })

  it('generates a brief for a known project', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project' })
    expect(result.sessionCount).toBe(2)
    expect(result.brief).toContain('my-project')
    expect(result.brief).toContain('Fixed authentication bug')
  })

  it('includes cost data when available', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project' })
    expect(result.brief).toContain('$0.42')
  })

  it('returns empty brief for unknown project', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/unknown-project' })
    expect(result.sessionCount).toBe(0)
    expect(result.brief).toContain('No recent sessions')
  })

  it('uses specific sessionId when provided', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project', sessionId: 's2' })
    expect(result.sessionCount).toBe(1)
    expect(result.brief).toContain('Refactored database')
  })

  it('generates plain format', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project', format: 'plain' })
    expect(result.brief).not.toContain('##')
    expect(result.brief).not.toContain('**')
  })

  it('includes model info in brief', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project' })
    expect(result.brief).toContain('claude-sonnet-4-6')
  })

  it('includes session count in brief', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project' })
    expect(result.brief).toContain('(2)')
  })

  it('includes suggested prompt for markdown format', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project', format: 'markdown' })
    expect(result.brief).toContain('Suggested prompt')
  })

  it('plain format omits suggested prompt', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project', format: 'plain' })
    expect(result.brief).not.toContain('Suggested prompt')
  })
})
