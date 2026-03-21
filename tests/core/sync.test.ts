import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { SyncEngine } from '../../src/core/sync.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import type { AuthoritativeSessionSnapshot } from '../../src/core/session-snapshot.js'

function jsonOk(body: unknown) {
  return {
    ok: true,
    json: async () => body,
  }
}

function validSnapshot(
  id: string,
  indexedAt = '2026-03-18T12:00:00Z',
  overrides: Partial<AuthoritativeSessionSnapshot> = {},
): AuthoritativeSessionSnapshot {
  return {
    id,
    source: 'codex',
    authoritativeNode: 'peer-a',
    syncVersion: 1,
    snapshotHash: `hash-${id}`,
    indexedAt,
    sourceLocator: `sync://peer-a/${id}.jsonl`,
    startTime: indexedAt,
    cwd: '/repo',
    messageCount: 2,
    userMessageCount: 1,
    assistantMessageCount: 1,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: `summary-${id}`,
    ...overrides,
  }
}

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

  it('skips sessions that already exist with the same authoritative revision', async () => {
    db.upsertAuthoritativeSnapshot(validSnapshot('remote-1', '2026-01-01T10:00:00Z', {
      sourceLocator: '/f1',
      summary: 'Already here',
    }))

    const mockSessions = [
      validSnapshot('remote-1', '2026-01-01T10:00:00Z', {
        sourceLocator: '/f1',
        summary: 'Already here',
      }),
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessionCount: 1, nodeName: 'mac-mini', timestamp: new Date().toISOString() }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessions: mockSessions }) })

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://10.0.10.100:3457' })

    expect(result.pulled).toBe(0)
    expect(result.skipped).toBe(1)
  })

  it('updates existing session when remote has a newer authoritative revision', async () => {
    db.upsertAuthoritativeSnapshot(validSnapshot('remote-1', '2026-01-01T10:00:00Z', {
      sourceLocator: 'sync://mac-mini//f1',
      summary: 'Old summary',
    }))

    const mockSessions = [
      validSnapshot('remote-1', '2026-01-01T10:05:00Z', {
        syncVersion: 2,
        snapshotHash: 'hash-remote-1-v2',
        sourceLocator: '/f1',
        messageCount: 50,
        userMessageCount: 25,
        summary: 'Updated',
      }),
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessionCount: 1, nodeName: 'mac-mini', timestamp: new Date().toISOString() }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessions: mockSessions }) })

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://10.0.10.100:3457' })

    expect(result.pulled).toBe(1)
    const updated = db.getAuthoritativeSnapshot('remote-1')!
    expect(updated.messageCount).toBe(50)
    expect(updated.indexedAt).toBe('2026-01-01T10:05:00Z')
  })

  it('handles unreachable peer gracefully', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('Network error'))

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://10.0.10.100:3457' })

    expect(result.error).toBeTruthy()
    expect(result.pulled).toBe(0)
  })

  it('does not skip sessions that share the page-boundary indexed_at timestamp', async () => {
    const sharedTs = '2026-03-18T12:00:00Z'
    const page1 = Array.from({ length: 100 }, (_, i) =>
      validSnapshot(`sess-${String(i).padStart(3, '0')}`, sharedTs))
    const page2 = [validSnapshot('sess-100', sharedTs)]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce(jsonOk({ sessionCount: 101, nodeName: 'peer-a', timestamp: sharedTs }))
      .mockResolvedValueOnce(jsonOk({ sessions: page1 }))
      .mockResolvedValueOnce(jsonOk({ sessions: page2 }))
      .mockResolvedValueOnce(jsonOk({ sessions: [] }))

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'peer-a', url: 'http://peer-a:3457' })

    expect(result.pulled).toBe(101)
    expect(mockFetch.mock.calls[2][0]).toContain(`cursor_indexed_at=${encodeURIComponent(sharedTs)}`)
    expect(mockFetch.mock.calls[2][0]).toContain('cursor_id=sess-099')
  })

  it('pulls newer metadata even when messageCount is unchanged', async () => {
    db.upsertAuthoritativeSnapshot(validSnapshot('sess-1', '2026-03-18T12:00:00Z'))

    const mockFetch = vi.fn()
      .mockResolvedValueOnce(jsonOk({ sessionCount: 1, nodeName: 'peer-a', timestamp: new Date().toISOString() }))
      .mockResolvedValueOnce(jsonOk({
        sessions: [validSnapshot('sess-1', '2026-03-18T12:05:00Z', {
          syncVersion: 2,
          snapshotHash: 'hash-sess-1-v2',
        })],
      }))
      .mockResolvedValueOnce(jsonOk({ sessions: [] }))

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    await engine.pullFromPeer({ name: 'peer-a', url: 'http://peer-a:3457' })

    expect(db.getAuthoritativeSnapshot('sess-1')?.indexedAt).toBe('2026-03-18T12:05:00Z')
  })

  it('does not advance cursor when a row merge fails mid-page', async () => {
    const mockFetch = vi.fn()
      .mockResolvedValueOnce(jsonOk({ sessionCount: 2, nodeName: 'peer-a', timestamp: new Date().toISOString() }))
      .mockResolvedValueOnce(jsonOk({
        sessions: [validSnapshot('sess-1'), validSnapshot('sess-2')],
      }))

    const writer = {
      writeAuthoritativeSnapshot: vi.fn()
        .mockReturnValueOnce({ action: 'merge', changeSet: { flags: new Set() } })
        .mockImplementationOnce(() => { throw new Error('merge failed') }),
    }

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch, writer as any)
    const result = await engine.pullFromPeer({ name: 'peer-a', url: 'http://peer-a:3457' })

    expect(result.error).toContain('merge failed')
    expect(result.pulled).toBe(0)
    expect(db.getSyncCursor('peer-a')).toBeNull()
  })

  it('preserves agentRole through sync roundtrip', async () => {
    const mockSessions = [
      validSnapshot('agent-sess-1', '2026-03-19T10:00:00Z', {
        source: 'claude-code',
        agentRole: 'code-review',
        messageCount: 5,
        userMessageCount: 2,
        assistantMessageCount: 3,
      } as Partial<AuthoritativeSessionSnapshot>),
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce(jsonOk({ sessionCount: 1, nodeName: 'peer-a', timestamp: new Date().toISOString() }))
      .mockResolvedValueOnce(jsonOk({ sessions: mockSessions }))
      .mockResolvedValueOnce(jsonOk({ sessions: [] }))

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'peer-a', url: 'http://peer-a:3457' })

    expect(result.pulled).toBe(1)
    const stored = db.getAuthoritativeSnapshot('agent-sess-1')
    expect(stored?.agentRole).toBe('code-review')
    expect(stored?.tier).toBe('skip') // agent sessions → skip tier
  })

  it('defaults agentRole to null when missing from remote', async () => {
    const mockSessions = [
      validSnapshot('normal-sess-1', '2026-03-19T10:00:00Z', {
        messageCount: 10,
        userMessageCount: 5,
        assistantMessageCount: 5,
      }),
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce(jsonOk({ sessionCount: 1, nodeName: 'peer-a', timestamp: new Date().toISOString() }))
      .mockResolvedValueOnce(jsonOk({ sessions: mockSessions }))
      .mockResolvedValueOnce(jsonOk({ sessions: [] }))

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    await engine.pullFromPeer({ name: 'peer-a', url: 'http://peer-a:3457' })

    const stored = db.getAuthoritativeSnapshot('normal-sess-1')
    expect(stored?.agentRole).toBeUndefined()
  })

  it('exports agentRole in sync session list', async () => {
    db.upsertAuthoritativeSnapshot(validSnapshot('local-agent-1', '2026-03-19T10:00:00Z', {
      source: 'claude-code',
      agentRole: 'refactor',
    } as Partial<AuthoritativeSessionSnapshot>))

    const exported = db.listSessionsAfterCursor(null, 10)
    const agentSession = exported.find(s => s.id === 'local-agent-1')
    expect(agentSession).toBeDefined()
    expect(agentSession!.agentRole).toBe('refactor')
  })

  it('computes tier for synced sessions', async () => {
    const mockSessions = [
      validSnapshot('sess-premium', '2026-03-18T12:00:00Z', {
        messageCount: 25,
        userMessageCount: 13,
        assistantMessageCount: 12,
      }),
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce(jsonOk({ sessionCount: 1, nodeName: 'peer-a', timestamp: new Date().toISOString() }))
      .mockResolvedValueOnce(jsonOk({ sessions: mockSessions }))
      .mockResolvedValueOnce(jsonOk({ sessions: [] }))

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'peer-a', url: 'http://peer-a:3457' })

    expect(result.pulled).toBe(1)
    const stored = db.getAuthoritativeSnapshot('sess-premium')
    expect(stored?.tier).toBe('premium')
  })
})
