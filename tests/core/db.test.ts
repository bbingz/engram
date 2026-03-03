// tests/core/db.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
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
})
