import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { SyncEngine } from '../../src/core/sync.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('SyncEngine', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'sync-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('pulls new sessions from a peer', async () => {
    const mockSessions = [
      { id: 'remote-1', source: 'codex', startTime: '2026-01-01T10:00:00Z', cwd: '/p', project: 'proj', messageCount: 5, userMessageCount: 2, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, summary: 'Remote session', filePath: '/remote/f1', sizeBytes: 100 },
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessionCount: 1, nodeName: 'mac-mini', timestamp: new Date().toISOString() }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessions: mockSessions }) })

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://10.0.10.100:3457' })

    expect(result.pulled).toBe(1)
    expect(db.getSession('remote-1')).not.toBeNull()
  })

  it('skips sessions that already exist with same or more messages', async () => {
    db.upsertSession({
      id: 'remote-1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', messageCount: 5, userMessageCount: 2, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0,
      filePath: '/f1', sizeBytes: 100,
    })

    const mockSessions = [
      { id: 'remote-1', source: 'codex', startTime: '2026-01-01T10:00:00Z', cwd: '/p', messageCount: 5, userMessageCount: 2, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, summary: 'Already here', filePath: '/f1', sizeBytes: 100 },
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessionCount: 1, nodeName: 'mac-mini', timestamp: new Date().toISOString() }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessions: mockSessions }) })

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://10.0.10.100:3457' })

    expect(result.pulled).toBe(0)
    expect(result.skipped).toBe(1)
  })

  it('updates existing session when remote has more messages', async () => {
    db.upsertSession({
      id: 'remote-1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', messageCount: 5, userMessageCount: 2, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0,
      filePath: 'sync://mac-mini//f1', sizeBytes: 100,
    })

    const mockSessions = [
      { id: 'remote-1', source: 'codex', startTime: '2026-01-01T10:00:00Z', cwd: '/p', messageCount: 50, userMessageCount: 25, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, summary: 'Updated', filePath: '/f1', sizeBytes: 5000 },
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessionCount: 1, nodeName: 'mac-mini', timestamp: new Date().toISOString() }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessions: mockSessions }) })

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://10.0.10.100:3457' })

    expect(result.pulled).toBe(1)
    const updated = db.getSession('remote-1')!
    expect(updated.messageCount).toBe(50)
    expect(updated.filePath).toBe('sync://mac-mini//f1') // preserved existing filePath
  })

  it('handles unreachable peer gracefully', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('Network error'))

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://10.0.10.100:3457' })

    expect(result.error).toBeTruthy()
    expect(result.pulled).toBe(0)
  })
})
