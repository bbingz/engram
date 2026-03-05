// tests/tools/search.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { handleSearch } from '../../src/tools/search.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('search', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession({ id: 's1', source: 'codex', startTime: '2026-01-01T10:00:00Z', cwd: '/p', messageCount: 5, userMessageCount: 2, assistantMessageCount: 0, systemMessageCount: 0, filePath: '/f1', sizeBytes: 100 })
    db.indexSessionContent('s1', [
      { role: 'user', content: '帮我修复 SSL certificate error in nginx' },
    ])
    db.upsertSession({ id: 's2', source: 'claude-code', startTime: '2026-01-02T10:00:00Z', cwd: '/p', messageCount: 3, userMessageCount: 1, assistantMessageCount: 0, systemMessageCount: 0, filePath: '/f2', sizeBytes: 50 })
    db.indexSessionContent('s2', [
      { role: 'user', content: '添加用户注册功能' },
    ])
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('finds session by keyword', async () => {
    const result = await handleSearch(db, { query: 'SSL' })
    expect(result.results.length).toBeGreaterThan(0)
    expect(result.results[0].session!.id).toBe('s1')
  })

  it('returns empty array for no match', async () => {
    const result = await handleSearch(db, { query: 'kubernetes' })
    expect(result.results).toHaveLength(0)
  })
})
