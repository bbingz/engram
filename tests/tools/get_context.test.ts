// tests/tools/get_context.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { handleGetContext } from '../../src/tools/get_context.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('get_context', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'get-context-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession({ id: 's1', source: 'codex', startTime: '2026-01-20T10:00:00Z', cwd: '/Users/test/myapp', project: 'myapp', summary: '修复了认证 bug', messageCount: 20, userMessageCount: 10, filePath: '/f1', sizeBytes: 100 })
    db.upsertSession({ id: 's2', source: 'claude-code', startTime: '2026-01-21T10:00:00Z', cwd: '/Users/test/myapp', project: 'myapp', summary: '添加了注册功能', messageCount: 15, userMessageCount: 7, filePath: '/f2', sizeBytes: 80 })
    db.upsertSession({ id: 's3', source: 'gemini-cli', startTime: '2026-01-15T10:00:00Z', cwd: '/Users/test/other', project: 'other', summary: '完全不相关的项目', messageCount: 5, userMessageCount: 2, filePath: '/f3', sizeBytes: 30 })
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('returns context for matching project', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp' })
    expect(result.sessions.length).toBeGreaterThan(0)
    expect(result.sessions.every(s => s.project === 'myapp')).toBe(true)
  })

  it('does not include unrelated project', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp' })
    expect(result.sessions.every(s => s.project !== 'other')).toBe(true)
  })

  it('respects max_tokens budget', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp', max_tokens: 10 })
    // 10 tokens = 40 chars 预算极小，contextText 应该很短
    expect(result.contextText.length).toBeLessThan(300)
  })

  it('contextText is non-empty when matching sessions exist', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp' })
    expect(result.contextText.length).toBeGreaterThan(0)
  })
})
