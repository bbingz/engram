import { describe, it, expect } from 'vitest'
import { KimiAdapter } from '../../src/adapters/kimi.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_ROOT = join(__dirname, '../fixtures/kimi')
const FIXTURE_SESSIONS = join(FIXTURE_ROOT, 'sessions')
const FIXTURE_KIMI_JSON = join(FIXTURE_ROOT, 'kimi.json')
const FIXTURE_CONTEXT = join(FIXTURE_SESSIONS, 'ws-001/sess-001/context.jsonl')

describe('KimiAdapter', () => {
  const adapter = new KimiAdapter(FIXTURE_SESSIONS, FIXTURE_KIMI_JSON)

  it('name is kimi', () => {
    expect(adapter.name).toBe('kimi')
  })

  it('listSessionFiles yields context.jsonl paths', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    expect(files).toHaveLength(1)
    expect(files[0]).toContain('context.jsonl')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE_CONTEXT)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('sess-001')
    expect(info!.source).toBe('kimi')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('帮我排查内存泄漏')
  })

  it('streamMessages skips checkpoints', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE_CONTEXT)) messages.push(msg)
    expect(messages.every(m => m.role === 'user' || m.role === 'assistant')).toBe(true)
    expect(messages[0].content).toBe('帮我排查内存泄漏')
    expect(messages[1].role).toBe('assistant')
  })
})
