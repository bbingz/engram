import { describe, it, expect, beforeAll, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import { populateMockData, clearMockData } from '../../src/core/mock-data.js'

describe('mock-data', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
  })

  afterEach(() => {
    clearMockData(db)
  })

  it('populates 50 mock sessions', async () => {
    const stats = await populateMockData(db)
    expect(stats.sessions).toBe(50)
    expect(stats.costUsd).toBeGreaterThan(0)
    expect(stats.tools).toBeGreaterThan(0)
  })

  it('mock sessions have __mock__ prefix in file_path', async () => {
    await populateMockData(db)
    const rows = db.getRawDb().prepare(
      "SELECT COUNT(*) as count FROM sessions WHERE file_path LIKE '__mock__%'"
    ).get() as { count: number }
    expect(rows.count).toBe(50)
  })

  it('mock sessions span multiple sources', async () => {
    await populateMockData(db)
    const sources = db.getRawDb().prepare(
      "SELECT DISTINCT source FROM sessions WHERE file_path LIKE '__mock__%'"
    ).all() as { source: string }[]
    expect(sources.length).toBeGreaterThanOrEqual(3)
  })

  it('mock sessions have cost data in session_costs', async () => {
    await populateMockData(db)
    const costs = db.getRawDb().prepare(`
      SELECT COUNT(*) as count FROM session_costs c
      JOIN sessions s ON c.session_id = s.id
      WHERE s.file_path LIKE '__mock__%'
    `).get() as { count: number }
    expect(costs.count).toBe(50)
  })

  it('mock sessions have tool data in session_tools', async () => {
    await populateMockData(db)
    const tools = db.getRawDb().prepare(`
      SELECT COUNT(DISTINCT t.session_id) as count FROM session_tools t
      JOIN sessions s ON t.session_id = s.id
      WHERE s.file_path LIKE '__mock__%'
    `).get() as { count: number }
    expect(tools.count).toBe(50)
  })

  it('clearMockData removes all mock sessions', async () => {
    await populateMockData(db)
    const cleared = clearMockData(db)
    expect(cleared).toBe(50)

    const remaining = db.getRawDb().prepare(
      "SELECT COUNT(*) as count FROM sessions WHERE file_path LIKE '__mock__%'"
    ).get() as { count: number }
    expect(remaining.count).toBe(0)
  })

  it('clearMockData cascades to session_costs and session_tools', async () => {
    await populateMockData(db)
    clearMockData(db)

    const costs = db.getRawDb().prepare(`
      SELECT COUNT(*) as count FROM session_costs c
      WHERE NOT EXISTS (SELECT 1 FROM sessions s WHERE s.id = c.session_id)
    `).get() as { count: number }
    expect(costs.count).toBe(0)
  })

  it('does not affect non-mock sessions', async () => {
    // Insert a real session first
    db.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier)
      VALUES ('real-1', 'claude-code', datetime('now'), '/real', 'real-project', 'claude-sonnet-4-6', 10, 3, 5, 1, 1, '/real/session.jsonl', 1000, 'normal')
    `)

    await populateMockData(db)
    clearMockData(db)

    const realSession = db.getSession('real-1')
    expect(realSession).toBeDefined()
    expect(realSession!.filePath).toBe('/real/session.jsonl')
  })

  it('mock sessions use 5 fictional projects', async () => {
    await populateMockData(db)
    const projects = db.getRawDb().prepare(
      "SELECT DISTINCT project FROM sessions WHERE file_path LIKE '__mock__%'"
    ).all() as { project: string }[]
    expect(projects.length).toBe(5)
  })

  it('mock sessions have diverse tiers', async () => {
    await populateMockData(db)
    const tiers = db.getRawDb().prepare(
      "SELECT DISTINCT tier FROM sessions WHERE file_path LIKE '__mock__%'"
    ).all() as { tier: string }[]
    expect(tiers.length).toBeGreaterThanOrEqual(3)
  })
})
