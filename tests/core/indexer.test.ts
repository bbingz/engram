// tests/core/indexer.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Indexer } from '../../src/core/indexer.js'
import { Database } from '../../src/core/db.js'
import { CodexAdapter } from '../../src/adapters/codex.js'
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('Indexer', () => {
  let db: Database
  let tmpDir: string
  let sessionsDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'indexer-test-'))
    sessionsDir = join(tmpDir, 'sessions', '2026', '01', '15')
    mkdirSync(sessionsDir, { recursive: true })
    db = new Database(join(tmpDir, 'index.sqlite'))
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  function makeSessionFile(dir: string, id: string, cwd: string, content: string): string {
    const filePath = join(dir, `rollout-${id}.jsonl`)
    writeFileSync(filePath, [
      JSON.stringify({ timestamp: '2026-01-15T10:00:00.000Z', type: 'session_meta', payload: { id, timestamp: '2026-01-15T10:00:00.000Z', cwd, model_provider: 'openai' } }),
      JSON.stringify({ timestamp: '2026-01-15T10:00:01.000Z', type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: content }] } }),
    ].join('\n'))
    return filePath
  }

  it('indexes a session file and stores it in db', async () => {
    makeSessionFile(sessionsDir, 'test-001', '/Users/test', '修复登录 bug')
    const codexAdapter = new CodexAdapter(join(tmpDir, 'sessions'))
    const indexer = new Indexer(db, [codexAdapter])

    const count = await indexer.indexAll()

    expect(count).toBe(1)
    const sessions = db.listSessions()
    expect(sessions).toHaveLength(1)
    expect(sessions[0].id).toBe('test-001')
  })

  it('skips already-indexed files with same size', async () => {
    makeSessionFile(sessionsDir, 'test-002', '/Users/test', 'hello')
    const codexAdapter = new CodexAdapter(join(tmpDir, 'sessions'))
    const indexer = new Indexer(db, [codexAdapter])

    const firstRun = await indexer.indexAll()
    const secondRun = await indexer.indexAll()

    expect(firstRun).toBe(1)
    expect(secondRun).toBe(0) // 第二次跳过
  })

  it('indexes content for full-text search', async () => {
    makeSessionFile(sessionsDir, 'test-003', '/Users/test', '帮我修复 SSL 证书错误')
    const codexAdapter = new CodexAdapter(join(tmpDir, 'sessions'))
    const indexer = new Indexer(db, [codexAdapter])
    await indexer.indexAll()

    const results = db.searchSessions('SSL')
    expect(results.length).toBeGreaterThan(0)
  })

  it('indexAll with sources filter skips unmatched adapters', async () => {
    makeSessionFile(sessionsDir, 'test-004', '/Users/test', 'filtered test')
    const codexAdapter = new CodexAdapter(join(tmpDir, 'sessions'))
    const indexer = new Indexer(db, [codexAdapter])

    // Filter for a source that doesn't match — should skip codex
    const count = await indexer.indexAll({ sources: new Set(['claude-code']) })
    expect(count).toBe(0)

    // Now with matching source
    const count2 = await indexer.indexAll({ sources: new Set(['codex']) })
    expect(count2).toBe(1)
  })
})
