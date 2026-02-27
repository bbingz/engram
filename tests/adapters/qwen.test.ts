import { describe, it, expect } from 'vitest'
import { QwenAdapter } from '../../src/adapters/qwen.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(__dirname, '../fixtures/qwen/sample.jsonl')

describe('QwenAdapter', () => {
  const adapter = new QwenAdapter()

  it('name is qwen', () => {
    expect(adapter.name).toBe('qwen')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('qwen-session-001')
    expect(info!.source).toBe('qwen')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('帮我重构这个模块')
  })

  it('streamMessages normalizes model role to assistant', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg)
    }
    expect(messages[0].role).toBe('user')
    expect(messages[1].role).toBe('assistant')
  })

  it('streamMessages respects limit', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE, { limit: 1 })) {
      messages.push(msg)
    }
    expect(messages).toHaveLength(1)
  })
})
