// tests/tools/get_session.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { handleGetSession } from '../../src/tools/get_session.js'
import { Database } from '../../src/core/db.js'
import { CodexAdapter } from '../../src/adapters/codex.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(__dirname, '../fixtures/codex/sample.jsonl')

describe('get_session', () => {
  let db: Database
  let tmpDir: string

  beforeEach(async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'get-session-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    const adapter = new CodexAdapter()
    const info = await adapter.parseSessionInfo(FIXTURE)
    if (info) db.upsertSession(info)
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('returns session with messages', async () => {
    const adapter = new CodexAdapter()
    const result = await handleGetSession(db, adapter, { id: 'codex-session-001', page: 1 })
    expect(result.session).not.toBeNull()
    expect(result.messages.length).toBeGreaterThan(0)
    expect(result.totalPages).toBeGreaterThanOrEqual(1)
  })

  it('throws for unknown session id', async () => {
    const adapter = new CodexAdapter()
    await expect(handleGetSession(db, adapter, { id: 'nonexistent' }))
      .rejects.toThrow('Session not found')
  })
})
