// tests/core/indexer.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Indexer } from '../../src/core/indexer.js'
import { Database } from '../../src/core/db.js'
import { CodexAdapter } from '../../src/adapters/codex.js'
import type { SessionAdapter, SessionInfo, Message } from '../../src/adapters/types.js'
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

function makeBaseSessionInfo(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 'mock-session-001',
    source: 'codex',
    filePath: '/fake/path.jsonl',
    startTime: '2026-01-01T00:00:00.000Z',
    cwd: '/fake/cwd',
    messageCount: 2,
    userMessageCount: 1,
    assistantMessageCount: 1,
    toolMessageCount: 0,
    systemMessageCount: 0,
    sizeBytes: 100,
    ...overrides,
  }
}

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

  describe('error path tests', () => {
    it('skips file when parseSessionInfo throws, continues indexing others', async () => {
      const goodPath = '/fake/good.jsonl'
      const badPath = '/fake/bad.jsonl'

      const adapter: SessionAdapter = {
        name: 'codex',
        async detect() { return true },
        async *listSessionFiles() {
          yield badPath
          yield goodPath
        },
        async parseSessionInfo(filePath: string) {
          if (filePath === badPath) throw new Error('parse error')
          return makeBaseSessionInfo({ id: 'good-001', filePath })
        },
        async *streamMessages(_filePath: string): AsyncGenerator<Message> {
          yield { role: 'user', content: 'hello' }
          yield { role: 'assistant', content: 'world' }
        },
      }

      const indexer = new Indexer(db, [adapter])
      const count = await indexer.indexAll()

      // Only the good file should be indexed
      expect(count).toBe(1)
      const sessions = db.listSessions()
      expect(sessions).toHaveLength(1)
      expect(sessions[0].id).toBe('good-001')
    })

    it('skips file when streamMessages throws mid-stream', async () => {
      const filePath = '/fake/stream-error.jsonl'

      const adapter: SessionAdapter = {
        name: 'codex',
        async detect() { return true },
        async *listSessionFiles() { yield filePath },
        async parseSessionInfo(fp: string) {
          return makeBaseSessionInfo({ id: 'stream-err-001', filePath: fp })
        },
        async *streamMessages(_filePath: string): AsyncGenerator<Message> {
          yield { role: 'user', content: 'first message' }
          throw new Error('stream failed mid-way')
        },
      }

      const indexer = new Indexer(db, [adapter])
      const count = await indexer.indexAll()

      // The error during streaming should cause the file to be skipped
      expect(count).toBe(0)
    })

    it('skips adapter entirely when detect() returns false', async () => {
      const adapter: SessionAdapter = {
        name: 'codex',
        async detect() { return false },
        async *listSessionFiles(): AsyncGenerator<string> {
          yield '/fake/should-not-be-listed.jsonl'
        },
        async parseSessionInfo(filePath: string) {
          return makeBaseSessionInfo({ filePath })
        },
        async *streamMessages(_filePath: string): AsyncGenerator<Message> {
          yield { role: 'user', content: 'hello' }
        },
      }

      const indexer = new Indexer(db, [adapter])
      const count = await indexer.indexAll()

      expect(count).toBe(0)
      expect(db.listSessions()).toHaveLength(0)
    })

    it('returns { indexed: false } when indexFile is called with nonexistent file path', async () => {
      const adapter: SessionAdapter = {
        name: 'codex',
        async detect() { return true },
        async *listSessionFiles(): AsyncGenerator<string> { /* empty */ },
        async parseSessionInfo(_filePath: string) {
          // Return null to simulate adapter unable to parse missing file
          return null
        },
        async *streamMessages(_filePath: string): AsyncGenerator<Message> { /* empty */ },
      }

      const indexer = new Indexer(db, [adapter])
      const result = await indexer.indexFile(adapter, '/nonexistent/path/fake.jsonl')

      expect(result.indexed).toBe(false)
      expect(result.sessionId).toBeUndefined()
    })

    it('indexAll with mix of good and bad files counts only successful indexes', async () => {
      const paths = [
        { path: '/fake/good-a.jsonl', id: 'mix-good-a', shouldFail: false },
        { path: '/fake/bad-b.jsonl',  id: 'mix-bad-b',  shouldFail: true },
        { path: '/fake/good-c.jsonl', id: 'mix-good-c', shouldFail: false },
        { path: '/fake/bad-d.jsonl',  id: 'mix-bad-d',  shouldFail: true },
        { path: '/fake/good-e.jsonl', id: 'mix-good-e', shouldFail: false },
      ]

      const adapter: SessionAdapter = {
        name: 'codex',
        async detect() { return true },
        async *listSessionFiles() {
          for (const p of paths) yield p.path
        },
        async parseSessionInfo(filePath: string) {
          const entry = paths.find(p => p.path === filePath)!
          if (entry.shouldFail) throw new Error(`parse error for ${filePath}`)
          return makeBaseSessionInfo({ id: entry.id, filePath, sizeBytes: 100 + paths.indexOf(entry) })
        },
        async *streamMessages(_filePath: string): AsyncGenerator<Message> {
          yield { role: 'user', content: 'hello' }
          yield { role: 'assistant', content: 'world' }
        },
      }

      const indexer = new Indexer(db, [adapter])
      const count = await indexer.indexAll()

      // Only 3 good files indexed, 2 bad files skipped
      expect(count).toBe(3)
      const sessions = db.listSessions()
      const ids = sessions.map(s => s.id).sort()
      expect(ids).toEqual(['mix-good-a', 'mix-good-c', 'mix-good-e'].sort())
    })
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
