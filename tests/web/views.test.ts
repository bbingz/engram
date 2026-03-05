import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { createApp } from '../../src/web.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('Web Views', () => {
  let db: Database
  let tmpDir: string
  let app: ReturnType<typeof createApp>

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-views-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    app = createApp(db)
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('GET / returns HTML with Engram layout', async () => {
    const res = await app.request('/')
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toContain('text/html')
    const html = await res.text()
    expect(html).toContain('Engram')
    expect(html).toContain('IBM Plex Sans')
  })

  it('GET /search returns HTML search page', async () => {
    const res = await app.request('/search')
    expect(res.status).toBe(200)
    const html = await res.text()
    expect(html).toContain('search')
  })

  it('GET /session/:id returns HTML detail', async () => {
    db.upsertSession({
      id: 'sess-1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', project: 'proj', messageCount: 5, userMessageCount: 2,
      summary: 'Test session', filePath: '/f1', sizeBytes: 100,
    })
    const res = await app.request('/session/sess-1')
    expect(res.status).toBe(200)
    const html = await res.text()
    expect(html).toContain('Test session')
    expect(html).toContain('Codex')
  })

  it('GET /session/:id returns 404 for missing session', async () => {
    const res = await app.request('/session/nonexistent')
    expect(res.status).toBe(404)
  })

  it('escapes XSS payloads in session summary and project', async () => {
    db.upsertSession({
      id: 'xss-1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', project: '<img onerror=alert(1)>', messageCount: 1, userMessageCount: 1,
      summary: '</title><script>alert("xss")</script>', filePath: '/f1', sizeBytes: 100,
    })

    // Session list page
    const listRes = await app.request('/')
    const listHtml = await listRes.text()
    expect(listHtml).not.toContain('<script>alert')
    expect(listHtml).toContain('&lt;script&gt;')

    // Session detail page
    const detailRes = await app.request('/session/xss-1')
    const detailHtml = await detailRes.text()
    expect(detailHtml).not.toContain('<script>alert')
    expect(detailHtml).toContain('&lt;script&gt;')
    // Title should also be escaped
    expect(detailHtml).toContain('<title>&lt;/title&gt;&lt;script&gt;')
  })
})
