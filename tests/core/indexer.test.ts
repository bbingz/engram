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

  function makeSessionFile(dir: string, id: string, cwd: string, content: string, extraMessages = 0): string {
    const filePath = join(dir, `rollout-${id}.jsonl`)
    const lines = [
      JSON.stringify({ timestamp: '2026-01-15T10:00:00.000Z', type: 'session_meta', payload: { id, timestamp: '2026-01-15T10:00:00.000Z', cwd, model_provider: 'openai' } }),
      JSON.stringify({ timestamp: '2026-01-15T10:00:01.000Z', type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: content }] } }),
    ]
    // Add extra assistant+user message pairs to reach desired message count
    for (let i = 0; i < extraMessages; i++) {
      const role = i % 2 === 0 ? 'assistant' : 'user'
      const contentType = role === 'user' ? 'input_text' : 'output_text'
      lines.push(JSON.stringify({
        timestamp: `2026-01-15T10:${String(i + 2).padStart(2, '0')}:00.000Z`,
        type: 'response_item',
        payload: { type: 'message', role, content: [{ type: contentType, text: `msg ${i}` }] },
      }))
    }
    writeFileSync(filePath, lines.join('\n'))
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

  it('routes local session indexing through durable jobs', async () => {
    // Need ≥2 messages so tier is not 'skip' (skip tier suppresses job dispatch)
    makeSessionFile(sessionsDir, 'test-001b', '/Users/test', '修复登录 bug', 1)
    const codexAdapter = new CodexAdapter(join(tmpDir, 'sessions'))
    const indexer = new Indexer(db, [codexAdapter], { authoritativeNode: 'local' })

    const count = await indexer.indexAll()

    expect(count).toBe(1)
    expect(db.listIndexJobs('test-001b').map(j => j.jobKind).sort()).toEqual(['embedding', 'fts'])
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

  it('enqueues durable jobs for searchable content', async () => {
    // Need ≥2 messages so tier is not 'skip' (skip tier suppresses job dispatch)
    makeSessionFile(sessionsDir, 'test-003', '/Users/test', '帮我修复 SSL 证书错误', 1)
    const codexAdapter = new CodexAdapter(join(tmpDir, 'sessions'))
    const indexer = new Indexer(db, [codexAdapter], { authoritativeNode: 'local' })
    await indexer.indexAll()

    expect(db.listIndexJobs('test-003').map(j => j.jobKind).sort()).toEqual(['embedding', 'fts'])
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

  it('computes tier and upgrades on re-index', async () => {
    // Helper to build a multi-message codex session file
    function makeMultiMessageFile(dir: string, id: string, cwd: string, msgCount: number): string {
      const filePath = join(dir, `rollout-${id}.jsonl`)
      const lines = [
        JSON.stringify({ timestamp: '2026-01-15T10:00:00.000Z', type: 'session_meta', payload: { id, timestamp: '2026-01-15T10:00:00.000Z', cwd, model_provider: 'openai' } }),
      ]
      for (let i = 0; i < msgCount; i++) {
        const role = i % 2 === 0 ? 'user' : 'assistant'
        const contentType = role === 'user' ? 'input_text' : 'output_text'
        lines.push(JSON.stringify({
          timestamp: `2026-01-15T10:${String(i + 1).padStart(2, '0')}:00.000Z`,
          type: 'response_item',
          payload: { type: 'message', role, content: [{ type: contentType, text: `message ${i}` }] },
        }))
      }
      writeFileSync(filePath, lines.join('\n'))
      return filePath
    }

    const codexAdapter = new CodexAdapter(join(tmpDir, 'sessions'))
    const indexer = new Indexer(db, [codexAdapter])

    // 1 message → messageCount=1, tier should be 'skip'
    const filePath = makeMultiMessageFile(sessionsDir, 'tier-001', '/Users/test', 1)
    const result1 = await indexer.indexFile(codexAdapter, filePath)
    expect(result1.indexed).toBe(true)
    expect(result1.tier).toBe('skip')
    const snap1 = db.getAuthoritativeSnapshot('tier-001')
    expect(snap1?.tier).toBe('skip')

    // Overwrite with 15 messages (8 user + 7 assistant) + project from cwd
    // messageCount=15 >= 10, and project resolves from cwd → premium
    makeMultiMessageFile(sessionsDir, 'tier-001', '/Users/test/my-project', 15)
    const result2 = await indexer.indexFile(codexAdapter, filePath)
    expect(result2.indexed).toBe(true)
    expect(result2.tier).toBe('premium')
    const snap2 = db.getAuthoritativeSnapshot('tier-001')
    expect(snap2?.tier).toBe('premium')
  })
})
