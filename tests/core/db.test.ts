// tests/core/db.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database, isTierHidden, containsCJK, SCHEMA_VERSION } from '../../src/core/db.js'
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

  it('searches pure Chinese queries via LIKE fallback', () => {
    db.upsertSession(mockSession)
    db.indexSessionContent('session-001', [
      { role: 'user', content: '帮我修复登录页面的bug' },
      { role: 'assistant', content: '已经修复了认证逻辑的问题' },
    ])

    // Pure Chinese query — trigram tokenizer can't handle this, needs LIKE fallback
    const results = db.searchSessions('修复')
    expect(results.length).toBeGreaterThan(0)
    expect(results[0].sessionId).toBe('session-001')
    expect(results[0].snippet).toContain('修复')
  })

  it('searches Chinese with filters', () => {
    db.upsertSession(mockSession)
    db.upsertSession({ ...mockSession, id: 'session-002', source: 'claude-code', filePath: '/f2', project: 'other' })
    db.indexSessionContent('session-001', [{ role: 'user', content: '修复数据库连接问题' }])
    db.indexSessionContent('session-002', [{ role: 'user', content: '修复网络请求超时' }])

    const filtered = db.searchSessions('修复', 20, { source: 'codex' })
    expect(filtered).toHaveLength(1)
    expect(filtered[0].sessionId).toBe('session-001')
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

  // --- containsCJK ---

  describe('containsCJK', () => {
    it('detects Chinese characters', () => {
      expect(containsCJK('修复')).toBe(true)
      expect(containsCJK('SSL 证书')).toBe(true)
      expect(containsCJK('hello 世界')).toBe(true)
    })
    it('returns false for pure ASCII', () => {
      expect(containsCJK('hello world')).toBe(false)
      expect(containsCJK('SSL certificate')).toBe(false)
    })
    it('detects Japanese and Korean', () => {
      expect(containsCJK('テスト')).toBe(true)  // katakana (in CJK range)
      expect(containsCJK('漢字')).toBe(true)
    })
  })

  // --- tier-based filtering ---

  describe('tier-based filtering', () => {
    it('isTierHidden with hide-skip', () => {
      expect(isTierHidden('skip', 'hide-skip')).toBe(true)
      expect(isTierHidden('lite', 'hide-skip')).toBe(false)
      expect(isTierHidden('normal', 'hide-skip')).toBe(false)
      expect(isTierHidden('premium', 'hide-skip')).toBe(false)
    })
    it('isTierHidden with hide-noise', () => {
      expect(isTierHidden('skip', 'hide-noise')).toBe(true)
      expect(isTierHidden('lite', 'hide-noise')).toBe(true)
      expect(isTierHidden('normal', 'hide-noise')).toBe(false)
      expect(isTierHidden('premium', 'hide-noise')).toBe(false)
    })
    it('isTierHidden with all', () => {
      expect(isTierHidden('skip', 'all')).toBe(false)
      expect(isTierHidden('lite', 'all')).toBe(false)
    })
    it('isTierHidden with null/undefined tier', () => {
      expect(isTierHidden(null, 'hide-skip')).toBe(false)
      expect(isTierHidden(undefined, 'hide-skip')).toBe(false)
    })
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

  describe('tier migration', () => {
    it('backfills tier column for existing sessions', () => {
      db.upsertSession({ id: 'agent-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 10, userMessageCount: 5, assistantMessageCount: 5, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f', sizeBytes: 100, agentRole: 'subagent' })
      db.upsertSession({ id: 'skip-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 1, userMessageCount: 1, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f2', sizeBytes: 100 })
      db.upsertSession({ id: 'premium-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 25, userMessageCount: 15, assistantMessageCount: 10, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f3', sizeBytes: 100, project: 'engram' })
      db.upsertSession({ id: 'lite-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 5, userMessageCount: 3, assistantMessageCount: 2, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f4', sizeBytes: 100, summary: '/usage check' })
      db.upsertSession({ id: 'normal-1', source: 'claude-code', startTime: '2026-01-01T00:00:00Z', cwd: '/tmp', messageCount: 8, userMessageCount: 4, assistantMessageCount: 4, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f5', sizeBytes: 100, project: 'test', summary: 'Fix bug' })

      // backfillTiers already ran in constructor, but these were inserted after
      db.backfillTiers()

      const raw = db.getRawDb()
      expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('agent-1')).toHaveProperty('tier', 'skip')
      expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('skip-1')).toHaveProperty('tier', 'skip')
      expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('premium-1')).toHaveProperty('tier', 'premium')
      expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('lite-1')).toHaveProperty('tier', 'lite')
      expect(raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('normal-1')).toHaveProperty('tier', 'normal')
    })
  })

  it('SCHEMA_VERSION matches metadata table value', () => {
    const raw = db.getRawDb()
    const row = raw.prepare("SELECT value FROM metadata WHERE key = 'schema_version'").get() as { value: string }
    expect(row).not.toBeNull()
    expect(Number(row.value)).toBe(SCHEMA_VERSION)
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
