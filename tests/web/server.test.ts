import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { createApp } from '../../src/web.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

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
})
