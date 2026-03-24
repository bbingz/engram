// tests/tools/get_context.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { handleGetContext } from '../../src/tools/get_context.js'
import { Database } from '../../src/core/db.js'
import type { VectorStore, VectorSearchResult } from '../../src/core/vector-store.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('get_context', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'get-context-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession({ id: 's1', source: 'codex', startTime: '2026-01-20T10:00:00Z', cwd: '/Users/test/myapp', project: 'myapp', summary: '修复了认证 bug', messageCount: 20, userMessageCount: 10, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f1', sizeBytes: 100 })
    db.upsertSession({ id: 's2', source: 'claude-code', startTime: '2026-01-21T10:00:00Z', cwd: '/Users/test/myapp', project: 'myapp', summary: '添加了注册功能', messageCount: 15, userMessageCount: 7, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f2', sizeBytes: 80 })
    db.upsertSession({ id: 's3', source: 'gemini-cli', startTime: '2026-01-15T10:00:00Z', cwd: '/Users/test/other', project: 'other', summary: '完全不相关的项目', messageCount: 5, userMessageCount: 2, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f3', sizeBytes: 30 })
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('returns context for matching project', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp' })
    expect(result.sessionCount).toBeGreaterThan(0)
    expect(result.sessionIds).toContain('s1')
    expect(result.sessionIds).toContain('s2')
    expect(result.sessionIds).not.toContain('s3')
  })

  it('does not include unrelated project in contextText', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp' })
    expect(result.contextText).not.toContain('完全不相关的项目')
  })

  it('respects max_tokens budget', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp', max_tokens: 10 })
    // 10 tokens = 40 chars — very small budget, contextText should be short
    expect(result.contextText.length).toBeLessThan(300)
  })

  it('contextText is non-empty when matching sessions exist', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp' })
    expect(result.contextText.length).toBeGreaterThan(0)
    expect(result.contextText).toContain('修复了认证 bug')
  })

  it('returns only sessionIds, not full session objects', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp' })
    // Should not have full session objects — just ids
    expect(result).not.toHaveProperty('sessions')
    expect(result.sessionIds).toBeInstanceOf(Array)
    expect(result.sessionIds.every((id: string) => typeof id === 'string')).toBe(true)
  })

  it('uses vector search when deps provided and task is given', async () => {
    db.upsertSession({ id: 's4', source: 'codex', startTime: '2026-01-22T10:00:00Z', cwd: '/Users/test/myapp', project: 'myapp', summary: 'Configured OAuth auth flow', messageCount: 10, userMessageCount: 5, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/f4', sizeBytes: 50 })

    const mockVectorStore: VectorStore = {
      upsert: () => {},
      delete: () => {},
      count: () => 2,
      search: (): VectorSearchResult[] => [
        { sessionId: 's4', distance: 0.1 },
        { sessionId: 's1', distance: 0.3 },
      ],
    }
    const mockEmbed = async () => new Float32Array(768).fill(0.1)

    const result = await handleGetContext(db, { cwd: '/Users/test/myapp', task: 'Fix auth issue' }, { vectorStore: mockVectorStore, embed: mockEmbed })
    expect(result.sessionIds).toContain('s4')
  })

  describe('environment data — new blocks', () => {
    it('includes git repos with dirty/unpushed changes in environment', async () => {
      // Seed a dirty git repo
      db.raw.prepare(
        `INSERT INTO git_repos (path, name, branch, dirty_count, unpushed_count) VALUES (?, ?, ?, ?, ?)`
      ).run('/Users/test/myapp', 'myapp', 'main', 3, 1)

      const result = await handleGetContext(db, { cwd: '/Users/test/myapp', include_environment: true })
      expect(result.contextText).toContain('Git repos with changes')
      expect(result.contextText).toContain('myapp')
      expect(result.contextText).toContain('3 dirty')
    })

    it('does not include clean git repos in environment', async () => {
      // Seed a clean git repo (dirty_count=0, unpushed_count=0)
      db.raw.prepare(
        `INSERT INTO git_repos (path, name, branch, dirty_count, unpushed_count) VALUES (?, ?, ?, ?, ?)`
      ).run('/Users/test/myapp', 'myapp', 'main', 0, 0)

      const result = await handleGetContext(db, { cwd: '/Users/test/myapp', include_environment: true })
      expect(result.contextText).not.toContain('Git repos with changes')
    })

    it('includes file hotspots (7 days) in environment', async () => {
      // Add a recent session (within last 7 days) and seed session_files with an edit
      const recentTs = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
      db.upsertSession({ id: 'sRecent', source: 'codex', startTime: recentTs, cwd: '/Users/test/myapp', project: 'myapp', summary: 'recent session', messageCount: 5, userMessageCount: 2, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/fRecent', sizeBytes: 50 })
      db.raw.prepare(
        `INSERT INTO session_files (session_id, file_path, action, count) VALUES (?, ?, ?, ?)`
      ).run('sRecent', '/Users/test/myapp/src/auth.ts', 'Edit', 5)

      const result = await handleGetContext(db, { cwd: '/Users/test/myapp', include_environment: true })
      expect(result.contextText).toContain('File hotspots')
      expect(result.contextText).toContain('auth.ts')
    })

    it('includes cost suggestions when session_costs has expensive sessions', async () => {
      // Seed two sessions with high cost (>$5) and many tokens (>200K) to trigger expensive-sessions rule
      const recentTs = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
      db.upsertSession({ id: 'sCost1', source: 'claude-code', startTime: recentTs, cwd: '/Users/test/myapp', project: 'myapp', summary: 'expensive session', messageCount: 50, userMessageCount: 20, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/fCost1', sizeBytes: 1000 })
      db.upsertSession({ id: 'sCost2', source: 'claude-code', startTime: recentTs, cwd: '/Users/test/myapp', project: 'myapp', summary: 'another expensive session', messageCount: 60, userMessageCount: 25, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/fCost2', sizeBytes: 1200 })

      // Insert session_costs rows with cost >$5 and tokens >200K
      db.raw.prepare(
        `INSERT OR REPLACE INTO session_costs (session_id, model, cost_usd, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens) VALUES (?, ?, ?, ?, ?, ?, ?)`
      ).run('sCost1', 'claude-opus-4-5', 6.50, 100000, 150000, 0, 0)
      db.raw.prepare(
        `INSERT OR REPLACE INTO session_costs (session_id, model, cost_usd, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens) VALUES (?, ?, ?, ?, ?, ?, ?)`
      ).run('sCost2', 'claude-opus-4-5', 7.20, 120000, 180000, 0, 0)

      const result = await handleGetContext(db, { cwd: '/Users/test/myapp', include_environment: true })
      expect(result.contextText).toContain('Cost suggestions')
    })

    it('abstract detail level excludes new blocks (only costToday + alerts visible)', async () => {
      // Seed dirty git repo and file hotspots (with recent session so hotspots would appear in non-abstract mode)
      const recentTs = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
      db.upsertSession({ id: 'sAbstractRecent', source: 'codex', startTime: recentTs, cwd: '/Users/test/myapp', project: 'myapp', summary: 'recent', messageCount: 5, userMessageCount: 2, assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0, filePath: '/fAbsR', sizeBytes: 50 })
      db.raw.prepare(
        `INSERT INTO git_repos (path, name, branch, dirty_count, unpushed_count) VALUES (?, ?, ?, ?, ?)`
      ).run('/Users/test/myapp', 'myapp', 'main', 2, 0)
      db.raw.prepare(
        `INSERT INTO session_files (session_id, file_path, action, count) VALUES (?, ?, ?, ?)`
      ).run('sAbstractRecent', '/Users/test/myapp/src/auth.ts', 'Edit', 3)

      const result = await handleGetContext(db, { cwd: '/Users/test/myapp', detail: 'abstract', include_environment: true })
      expect(result.contextText).not.toContain('Git repos with changes')
      expect(result.contextText).not.toContain('File hotspots')
      expect(result.contextText).not.toContain('Recent errors')
      expect(result.contextText).not.toContain('Config status')
    })
  })
})
