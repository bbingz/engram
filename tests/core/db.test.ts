// tests/core/db.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database, isNoiseSession } from '../../src/core/db.js'
import type { SessionInfo } from '../../src/adapters/types.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('Database', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'coding-memory-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

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
    assistantMessageCount: 0,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: '帮我修复登录 bug',
    filePath: '/Users/test/.codex/sessions/2026/01/01/rollout-123.jsonl',
    sizeBytes: 50000,
  }

  it('upserts and retrieves a session', () => {
    db.upsertSession(mockSession)
    const result = db.getSession('session-001')
    expect(result).not.toBeNull()
    expect(result!.id).toBe('session-001')
    expect(result!.source).toBe('codex')
    expect(result!.cwd).toBe('/Users/test/project')
  })

  it('lists sessions with source filter', () => {
    db.upsertSession(mockSession)
    db.upsertSession({ ...mockSession, id: 'session-002', source: 'claude-code' })

    const codexOnly = db.listSessions({ source: 'codex' })
    expect(codexOnly).toHaveLength(1)
    expect(codexOnly[0].source).toBe('codex')
  })

  it('lists sessions with time filter', () => {
    db.upsertSession(mockSession)
    db.upsertSession({ ...mockSession, id: 'session-003', startTime: '2025-06-01T00:00:00.000Z' })

    const recent = db.listSessions({ since: '2026-01-01T00:00:00.000Z' })
    expect(recent).toHaveLength(1)
    expect(recent[0].id).toBe('session-001')
  })

  it('indexes and searches FTS content', () => {
    db.upsertSession(mockSession)
    db.indexSessionContent('session-001', [
      { role: 'user', content: '帮我修复 SSL 证书错误' },
      { role: 'assistant', content: '你需要更新证书配置' },
    ])

    const results = db.searchSessions('SSL 证书')
    expect(results.length).toBeGreaterThan(0)
    expect(results[0].sessionId).toBe('session-001')
  })

  it('deletes a session', () => {
    db.upsertSession(mockSession)
    db.deleteSession('session-001')
    expect(db.getSession('session-001')).toBeNull()
  })

  it('checks if file is already indexed', () => {
    db.upsertSession(mockSession)
    expect(db.isIndexed(mockSession.filePath, mockSession.sizeBytes)).toBe(true)
    expect(db.isIndexed(mockSession.filePath, 99999)).toBe(false)
  })

  it('preserves origin field on upsert', () => {
    db.upsertSession({ ...mockSession, id: 'origin-test', origin: 'mac-mini' })
    const result = db.getSession('origin-test')
    expect(result).not.toBeNull()
    expect(result!.origin).toBe('mac-mini')
  })

  it('defaults origin to local', () => {
    db.upsertSession(mockSession)
    const result = db.getSession('session-001')
    expect(result!.origin).toBe('local')
  })

  it('listSessionsSince returns sessions indexed after a given time', () => {
    db.upsertSession(mockSession)
    const yesterday = new Date(Date.now() - 86400000).toISOString()
    const results = db.listSessionsSince(yesterday, 100)
    expect(results).toHaveLength(1)
    expect(results[0].id).toBe('session-001')

    const tomorrow = new Date(Date.now() + 86400000).toISOString()
    const resultsEmpty = db.listSessionsSince(tomorrow, 100)
    expect(resultsEmpty).toHaveLength(0)
  })

  it('creates session_local_state and session_index_jobs tables', () => {
    const tables = db.getRawDb()
      .prepare("SELECT name FROM sqlite_master WHERE type='table'")
      .all() as { name: string }[]
    const names = new Set(tables.map(t => t.name))
    expect(names.has('session_local_state')).toBe(true)
    expect(names.has('session_index_jobs')).toBe(true)
  })

  it('adds authoritative snapshot columns to sessions', () => {
    const columns = db.getRawDb()
      .prepare("PRAGMA table_info(sessions)")
      .all() as { name: string }[]
    const names = new Set(columns.map(c => c.name))
    expect(names.has('authoritative_node')).toBe(true)
    expect(names.has('source_locator')).toBe(true)
    expect(names.has('sync_version')).toBe(true)
    expect(names.has('snapshot_hash')).toBe(true)
  })

  it('backfills local_readable_path from legacy file_path without losing machine-local readability', () => {
    db.getRawDb().exec(`
      INSERT INTO sessions (
        id, source, start_time, cwd, message_count, user_message_count,
        assistant_message_count, tool_message_count, system_message_count,
        file_path, size_bytes
      ) VALUES (
        'legacy-1', 'codex', '2026-03-18T12:00:00Z', '/repo', 2, 1, 1, 0, 0,
        '/Users/test/.codex/sessions/legacy.jsonl', 100
      )
    `)

    db.runPostMigrationBackfill()

    expect(db.getLocalState('legacy-1')?.localReadablePath).toBe('/Users/test/.codex/sessions/legacy.jsonl')
    expect(db.getAuthoritativeSnapshot('legacy-1')?.sourceLocator).toBe('/Users/test/.codex/sessions/legacy.jsonl')
  })

  it('stores sync cursor as indexed_at + session_id tuple', () => {
    db.setSyncCursor('peer-a', { indexedAt: '2026-03-18T12:00:00Z', sessionId: 'sess-123' })
    expect(db.getSyncCursor('peer-a')).toEqual({
      indexedAt: '2026-03-18T12:00:00Z',
      sessionId: 'sess-123',
    })
  })

  it('upserts and reads authoritative snapshots with revision metadata', () => {
    db.upsertAuthoritativeSnapshot({
      id: 'sess-1',
      source: 'codex',
      authoritativeNode: 'node-a',
      syncVersion: 2,
      snapshotHash: 'hash-2',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: '/remote/sess-1.jsonl',
      startTime: '2026-03-18T11:00:00Z',
      cwd: '/repo',
      messageCount: 4,
      userMessageCount: 2,
      assistantMessageCount: 2,
      toolMessageCount: 0,
      systemMessageCount: 0,
    } as any)

    expect(db.getAuthoritativeSnapshot('sess-1')?.syncVersion).toBe(2)
  })

  it('creates durable jobs from a change set', () => {
    db.upsertAuthoritativeSnapshot({
      id: 'sess-1',
      source: 'codex',
      authoritativeNode: 'node-a',
      syncVersion: 2,
      snapshotHash: 'hash-2',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: '/remote/sess-1.jsonl',
      startTime: '2026-03-18T11:00:00Z',
      cwd: '/repo',
      messageCount: 4,
      userMessageCount: 2,
      assistantMessageCount: 2,
      toolMessageCount: 0,
      systemMessageCount: 0,
    } as any)

    db.insertIndexJobs('sess-1', 2, ['fts', 'embedding'])
    expect(db.listIndexJobs('sess-1').map(j => j.jobKind).sort()).toEqual(['embedding', 'fts'])
  })

  // --- isNoiseSession ---

  it('isNoiseSession identifies agent sessions', () => {
    expect(isNoiseSession({ agentRole: 'subagent', filePath: '/f', messageCount: 10 })).toBe(true)
    expect(isNoiseSession({ filePath: '/subagents/agent-1.jsonl', messageCount: 10 })).toBe(true)
  })

  it('isNoiseSession identifies empty and /usage sessions', () => {
    expect(isNoiseSession({ filePath: '/f', messageCount: 0 })).toBe(true)
    expect(isNoiseSession({ filePath: '/f', messageCount: 1 })).toBe(true)
    expect(isNoiseSession({ filePath: '/f', messageCount: 5, summary: '\n/usage\n' })).toBe(true)
  })

  it('isNoiseSession returns false for normal sessions', () => {
    expect(isNoiseSession({ filePath: '/f', messageCount: 10, summary: 'Fix login bug' })).toBe(false)
    expect(isNoiseSession({ filePath: '/f', messageCount: 2 })).toBe(false)
  })

  // --- Project aliases ---

  it('resolveProjectAliases returns input when no aliases exist', () => {
    expect(db.resolveProjectAliases(['myapp'])).toEqual(['myapp'])
  })

  it('resolveProjectAliases expands aliases bidirectionally', () => {
    db.addProjectAlias('wechat-decrypt', 'wechat-decrypt-bing')
    const fromOld = db.resolveProjectAliases(['wechat-decrypt'])
    expect(fromOld).toContain('wechat-decrypt')
    expect(fromOld).toContain('wechat-decrypt-bing')

    const fromNew = db.resolveProjectAliases(['wechat-decrypt-bing'])
    expect(fromNew).toContain('wechat-decrypt')
    expect(fromNew).toContain('wechat-decrypt-bing')
  })

  it('resolveProjectAliases deduplicates', () => {
    db.addProjectAlias('a', 'b')
    const result = db.resolveProjectAliases(['a', 'b'])
    expect(result).toHaveLength(2)
    expect(new Set(result).size).toBe(2)
  })

  it('addProjectAlias is idempotent', () => {
    db.addProjectAlias('x', 'y')
    db.addProjectAlias('x', 'y') // duplicate — should not throw
    expect(db.listProjectAliases()).toHaveLength(1)
  })

  it('removeProjectAlias deletes alias', () => {
    db.addProjectAlias('a', 'b')
    expect(db.listProjectAliases()).toHaveLength(1)
    db.removeProjectAlias('a', 'b')
    expect(db.listProjectAliases()).toHaveLength(0)
    expect(db.resolveProjectAliases(['a'])).toEqual(['a'])
  })

  // DB maintenance methods

  it('optimizeFts runs without error', () => {
    db.upsertSession(mockSession)
    db.indexSessionContent('session-001', [{ role: 'user', content: 'hello world' }])
    expect(() => db.optimizeFts()).not.toThrow()
  })

  it('vacuumIfNeeded returns false on clean db', () => {
    // Fresh DB has no fragmentation
    expect(db.vacuumIfNeeded(15)).toBe(false)
  })

  it('deduplicateFilePaths removes duplicates', () => {
    db.upsertSession(mockSession)
    // Insert a second row with same file_path but different id
    db.upsertSession({ ...mockSession, id: 'session-002' })
    expect(db.countSessions()).toBe(2)
    const removed = db.deduplicateFilePaths()
    expect(removed).toBe(1)
    expect(db.countSessions()).toBe(1)
  })
})
