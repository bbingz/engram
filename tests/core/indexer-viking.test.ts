import { describe, it, expect, vi, afterEach } from 'vitest'
import { mkdtempSync, writeFileSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { Database } from '../../src/core/db.js'
import { Indexer } from '../../src/core/indexer.js'
import type { VikingBridge } from '../../src/core/viking-bridge.js'

function makeSessionInfo(overrides: Record<string, unknown>) {
  return {
    source: 'codex', startTime: '2026-03-16T00:00:00Z',
    messageCount: 2, userMessageCount: 1, assistantMessageCount: 1,
    toolMessageCount: 0, systemMessageCount: 0, sizeBytes: 100, cwd: '/tmp',
    ...overrides,
  }
}

describe('Indexer with Viking', () => {
  let db: Database
  let tmpDir: string

  afterEach(() => { db?.close(); if (tmpDir) rmSync(tmpDir, { recursive: true }) })

  it('calls viking.pushSession (not addResource) after indexing a premium session', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'indexer-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      pushSession: vi.fn().mockResolvedValue(undefined),
    } as unknown as VikingBridge

    const filePath = join(tmpDir, 'session.jsonl')
    const adapter = {
      name: 'codex',
      detect: () => Promise.resolve(true),
      listSessionFiles: async function* () { yield filePath },
      parseSessionInfo: () => Promise.resolve(makeSessionInfo({ id: 'test-session-1', filePath, messageCount: 20, userMessageCount: 10, assistantMessageCount: 10 })),
      streamMessages: async function* () {
        yield { role: 'user', content: 'Hello' }
        yield { role: 'assistant', content: 'Hi there' }
      },
    }
    writeFileSync(filePath, '{}')
    const indexer = new Indexer(db, [adapter as any], { viking: mockViking, vikingAutoPush: true })
    await indexer.indexAll()
    await new Promise(r => setTimeout(r, 50))
    expect(mockViking.pushSession).toHaveBeenCalledWith(
      expect.stringMatching(/^codex::.+::test-session-1$/),
      expect.arrayContaining([
        expect.objectContaining({ role: 'user', content: 'Hello' }),
      ])
    )
  })

  it('does not fail if viking.pushSession throws', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'indexer-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      pushSession: vi.fn().mockRejectedValue(new Error('server down')),
    } as unknown as VikingBridge

    const filePath = join(tmpDir, 'session.jsonl')
    const adapter = {
      name: 'codex',
      detect: () => Promise.resolve(true),
      listSessionFiles: async function* () { yield filePath },
      parseSessionInfo: () => Promise.resolve(makeSessionInfo({
        id: 'test-session-2', filePath, messageCount: 1, userMessageCount: 1, assistantMessageCount: 0, sizeBytes: 50,
      })),
      streamMessages: async function* () { yield { role: 'user', content: 'test' } },
    }
    writeFileSync(filePath, '{}')
    const indexer = new Indexer(db, [adapter as any], { viking: mockViking, vikingAutoPush: true })
    const count = await indexer.indexAll()
    expect(count).toBe(1)
    expect(db.getSession('test-session-2')).not.toBeNull()
  })
})
