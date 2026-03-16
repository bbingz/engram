import { describe, it, expect, vi, afterEach } from 'vitest'
import { mkdtempSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { Database } from '../../src/core/db.js'
import { handleSearch } from '../../src/tools/search.js'
import type { VikingBridge, VikingSearchResult } from '../../src/core/viking-bridge.js'

function makeSession(overrides: Record<string, unknown>) {
  return {
    source: 'claude-code', startTime: '2026-03-16T00:00:00Z',
    messageCount: 5, userMessageCount: 3, assistantMessageCount: 2,
    toolMessageCount: 0, systemMessageCount: 0, sizeBytes: 100, cwd: '/tmp',
    ...overrides,
  } as any
}

describe('handleSearch with Viking', () => {
  let db: Database
  let tmpDir: string
  afterEach(() => { db?.close(); if (tmpDir) rmSync(tmpDir, { recursive: true }) })

  it('uses Viking find results when available', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession(makeSession({ id: 'session-1', filePath: '/tmp/s1' }))
    const vikingResults: VikingSearchResult[] = [
      { uri: 'viking://sessions/claude-code/engram/session-1', score: 0.95, snippet: 'SSL fix found' },
    ]
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      find: vi.fn().mockResolvedValue(vikingResults),
      grep: vi.fn().mockResolvedValue([]),
    } as unknown as VikingBridge
    const result = await handleSearch(db, { query: 'SSL error' }, { viking: mockViking })
    expect(result.results).toHaveLength(1)
    expect(result.results[0].session.id).toBe('session-1')
    expect(result.searchModes).toContain('viking-semantic')
  })

  it('falls back to FTS when Viking is not provided', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession(makeSession({ id: 'session-2', filePath: '/tmp/s2' }))
    db.indexSessionContent('session-2', [{ role: 'user', content: 'SSL certificate error' }])
    const result = await handleSearch(db, { query: 'SSL certificate' }, {})
    expect(result.searchModes).toContain('keyword')
  })

  it('falls back to FTS when Viking find() throws', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession(makeSession({ id: 'session-3', filePath: '/tmp/s3' }))
    db.indexSessionContent('session-3', [{ role: 'user', content: 'SSL cert renewal' }])
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      find: vi.fn().mockRejectedValue(new Error('timeout')),
      grep: vi.fn().mockRejectedValue(new Error('timeout')),
    } as unknown as VikingBridge
    const result = await handleSearch(db, { query: 'SSL cert' }, { viking: mockViking })
    expect(result.searchModes).toContain('keyword')
    expect(result.results.length).toBeGreaterThan(0)
  })
})
