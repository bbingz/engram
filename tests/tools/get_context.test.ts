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
})
