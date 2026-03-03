import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { createApp } from '../../src/web.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import type { SessionInfo } from '../../src/adapters/types.js'

const mockSession: SessionInfo = {
  id: 'session-001',
  source: 'codex',
  startTime: '2026-01-01T10:00:00.000Z',
  endTime: '2026-01-01T11:00:00.000Z',
  cwd: '/Users/test/project',
  project: 'my-project',
  model: 'gpt-4o',
  messageCount: 20,
  userMessageCount: 10,
  summary: 'Fix login bug',
  filePath: '/Users/test/.codex/sessions/rollout-123.jsonl',
  sizeBytes: 50000,
}

describe('Web Server', () => {
  let db: Database
  let tmpDir: string
  let app: ReturnType<typeof createApp>

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-web-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    app = createApp(db)
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('GET /api/sync/status returns node info', async () => {
    const res = await app.request('/api/sync/status')
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toHaveProperty('sessionCount')
    expect(body).toHaveProperty('nodeName')
  })

  it('GET /api/sessions returns session list', async () => {
    db.upsertSession(mockSession)
    db.upsertSession({ ...mockSession, id: 'session-002', source: 'claude-code' })
    const res = await app.request('/api/sessions')
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.sessions).toHaveLength(2)
  })

  it('GET /api/sessions supports source filter', async () => {
    db.upsertSession(mockSession)
    db.upsertSession({ ...mockSession, id: 'session-002', source: 'claude-code' })
    const res = await app.request('/api/sessions?source=codex')
    const body = await res.json()
    expect(body.sessions).toHaveLength(1)
    expect(body.sessions[0].source).toBe('codex')
  })

  it('GET /api/sessions/:id returns single session', async () => {
    db.upsertSession(mockSession)
    const res = await app.request('/api/sessions/session-001')
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.id).toBe('session-001')
  })

  it('GET /api/sessions/:id returns 404 for missing session', async () => {
    const res = await app.request('/api/sessions/nonexistent')
    expect(res.status).toBe(404)
  })

  it('GET /api/search returns FTS5 results', async () => {
    db.upsertSession(mockSession)
    db.indexSessionContent('session-001', [
      { role: 'user', content: 'Fix the SSL certificate error in nginx config' },
    ])
    const res = await app.request('/api/search?q=SSL')
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.results.length).toBeGreaterThan(0)
  })

  it('GET /api/search returns warning for short query', async () => {
    const res = await app.request('/api/search?q=ab')
    const body = await res.json()
    expect(body.warning).toBeTruthy()
  })

  it('GET /api/stats returns grouped statistics', async () => {
    db.upsertSession(mockSession)
    db.upsertSession({ ...mockSession, id: 'session-002', source: 'claude-code' })
    const res = await app.request('/api/stats')
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.groups.length).toBeGreaterThan(0)
    expect(body.totalSessions).toBe(2)
  })

  it('GET /api/sync/sessions returns sessions since timestamp', async () => {
    db.upsertSession(mockSession)
    const yesterday = new Date(Date.now() - 86400000).toISOString()
    const res = await app.request(`/api/sync/sessions?since=${yesterday}`)
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.sessions).toHaveLength(1)
  })

  it('GET /api/sync/sessions requires since parameter', async () => {
    const res = await app.request('/api/sync/sessions')
    expect(res.status).toBe(400)
  })
})
