import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import { createApp } from '../../src/web.js'
import type { SessionInfo } from '../../src/adapters/types.js'

const mockSession: SessionInfo = {
  id: 'api-test-session-001',
  source: 'codex',
  startTime: '2026-01-01T10:00:00.000Z',
  endTime: '2026-01-01T11:00:00.000Z',
  cwd: '/Users/test/project',
  project: 'my-project',
  model: 'gpt-4o',
  messageCount: 20,
  userMessageCount: 10,
  assistantMessageCount: 8,
  toolMessageCount: 2,
  systemMessageCount: 0,
  summary: 'Fix login bug',
  filePath: '/Users/test/.codex/sessions/rollout-123.jsonl',
  sizeBytes: 50000,
}

describe('Web API', () => {
  let db: Database
  let app: ReturnType<typeof createApp>

  beforeEach(() => {
    db = new Database(':memory:')
    app = createApp(db)
  })

  afterEach(() => {
    db.close()
  })

  // 1. GET /health returns 200
  it('GET /health returns 200', async () => {
    const res = await app.request('/health')
    expect(res.status).toBe(200)
  })

  // 2. POST /api/log with valid body → 200
  it('POST /api/log with valid body returns 200', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({ level: 'info', module: 'test', message: 'hello world' }),
      headers: { 'Content-Type': 'application/json' },
    })
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.ok).toBe(true)
  })

  // 3. POST /api/log with invalid level → 400
  it('POST /api/log with invalid level returns 400', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({ level: 'critical', module: 'test', message: 'bad level' }),
      headers: { 'Content-Type': 'application/json' },
    })
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.ok).toBe(false)
  })

  // 4. POST /api/log with malformed JSON → 400
  it('POST /api/log with malformed JSON returns 400', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: '{not valid json',
      headers: { 'Content-Type': 'application/json' },
    })
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.ok).toBe(false)
  })

  // 5. POST /api/log with missing fields → 400
  it('POST /api/log with missing fields returns 400', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({ level: 'info' }),
      headers: { 'Content-Type': 'application/json' },
    })
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.ok).toBe(false)
  })

  // 6. OPTIONS preflight → returns 204 for localhost origin (CORS accepted)
  it('OPTIONS preflight returns 204 for localhost origin', async () => {
    const res = await app.request('/api/sessions', {
      method: 'OPTIONS',
      headers: { 'Origin': 'http://localhost:3457' },
    })
    // CORS preflight should return 204 (not rejected)
    expect(res.status).toBe(204)
  })

  // 6b. CORS rejects non-localhost origin
  it('CORS rejects non-localhost origin', async () => {
    const res = await app.request('/api/sessions', {
      method: 'GET',
      headers: { 'Origin': 'https://evil.example.com' },
    })
    expect(res.status).toBe(403)
  })

  // 7. GET /api/sessions → returns list
  it('GET /api/sessions returns session list', async () => {
    db.upsertSession(mockSession)
    const res = await app.request('/api/sessions')
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.sessions).toBeDefined()
    expect(Array.isArray(body.sessions)).toBe(true)
  })

  // 8. GET /api/sessions/:id → 404 for nonexistent
  it('GET /api/sessions/:id returns 404 for nonexistent session', async () => {
    const res = await app.request('/api/sessions/does-not-exist-xyz')
    expect(res.status).toBe(404)
  })

  // 9. X-Trace-Id header propagated in response
  it('X-Trace-Id header propagated in response', async () => {
    const traceId = 'test-trace-abc-123'
    const res = await app.request('/api/sessions', {
      headers: { 'X-Trace-Id': traceId },
    })
    expect(res.headers.get('X-Trace-Id')).toBe(traceId)
  })

  // 10. Unknown route → 404
  it('unknown route returns 404', async () => {
    const res = await app.request('/api/this-route-does-not-exist-ever')
    expect(res.status).toBe(404)
  })
})

describe('Web API — bearer token auth', () => {
  let db: Database
  let protectedApp: ReturnType<typeof createApp>

  beforeEach(() => {
    db = new Database(':memory:')
    protectedApp = createApp(db, { settings: { httpBearerToken: 'test-secret' } })
  })

  afterEach(() => {
    db.close()
  })

  // 11. POST /api/log without token → 401
  it('POST /api/log without bearer token returns 401', async () => {
    const res = await protectedApp.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({ level: 'info', module: 'test', message: 'hello' }),
      headers: { 'Content-Type': 'application/json' },
    })
    expect(res.status).toBe(401)
  })

  // 12. POST /api/log with wrong token → 401
  it('POST /api/log with wrong bearer token returns 401', async () => {
    const res = await protectedApp.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({ level: 'info', module: 'test', message: 'hello' }),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer wrong-token',
      },
    })
    expect(res.status).toBe(401)
  })
})
