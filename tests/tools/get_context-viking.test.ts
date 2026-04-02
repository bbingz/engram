import { describe, it, expect, vi, afterEach } from 'vitest'
import { mkdtempSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { Database } from '../../src/core/db.js'
import { handleGetContext } from '../../src/tools/get_context.js'
import type { VikingBridge } from '../../src/core/viking-bridge.js'

function makeSession(overrides: Record<string, unknown>) {
  return {
    source: 'claude-code', startTime: '2026-03-16T00:00:00Z',
    messageCount: 5, userMessageCount: 3, assistantMessageCount: 2,
    toolMessageCount: 0, systemMessageCount: 0, sizeBytes: 100, cwd: '/tmp',
    ...overrides,
  } as any
}

describe('handleGetContext with Viking', () => {
  let db: Database
  let tmpDir: string
  afterEach(() => { db?.close(); if (tmpDir) rmSync(tmpDir, { recursive: true }) })

  it('uses Viking find() memory snippets directly for context', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'ctx-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession(makeSession({ id: 'session-1', filePath: '/tmp/s1', project: 'myproject', summary: 'Fixed auth bug' }))
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      find: vi.fn().mockResolvedValue([
        { uri: 'viking://user/default/memories/pref-1', score: 0.9, snippet: 'User prefers TypeScript strict mode' },
        { uri: 'viking://agent/default/memories/pattern-1', score: 0.8, snippet: 'Auth module uses JWT with bcrypt' },
      ]),
    } as unknown as VikingBridge
    const result = await handleGetContext(db,
      { cwd: '/projects/myproject', task: 'fix auth', detail: 'overview' },
      { viking: mockViking }
    )
    expect(result.contextText).toContain('User prefers TypeScript strict mode')
    expect(result.contextText).toContain('Auth module uses JWT with bcrypt')
    expect(result.contextText).toContain('[memory]')
  })

  it('includes local session summaries alongside Viking memories', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'ctx-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession(makeSession({ id: 'session-1', filePath: '/tmp/s1', project: 'myproject', summary: 'Migrated auth to JWT' }))
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      find: vi.fn().mockResolvedValue([
        { uri: 'viking://user/default/memories/pref-1', score: 0.9, snippet: 'Prefers async/await' },
      ]),
    } as unknown as VikingBridge
    const result = await handleGetContext(db,
      { cwd: '/projects/myproject', task: 'update auth', detail: 'overview' },
      { viking: mockViking }
    )
    expect(result.contextText).toContain('Prefers async/await')
    expect(result.contextText).toContain('Migrated auth to JWT')
  })

  it('falls back to summary-based context without Viking', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'ctx-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession(makeSession({ id: 'session-2', filePath: '/tmp/s2', project: 'myproject', summary: 'Fixed auth bug' }))
    const result = await handleGetContext(db, { cwd: '/projects/myproject' }, {})
    expect(result.contextText).toContain('Fixed auth bug')
  })
})
