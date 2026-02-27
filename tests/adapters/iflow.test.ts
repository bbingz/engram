import { describe, it, expect } from 'vitest'
import { IflowAdapter } from '../../src/adapters/iflow.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(__dirname, '../fixtures/iflow/sample.jsonl')

describe('IflowAdapter', () => {
  const adapter = new IflowAdapter()

  it('name is iflow', () => {
    expect(adapter.name).toBe('iflow')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('session-iflow-001')
    expect(info!.source).toBe('iflow')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.startTime).toBe('2026-01-20T09:00:00.000Z')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('帮我优化数据库查询')
  })

  it('streamMessages yields user and assistant', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg)
    }
    expect(messages.length).toBeGreaterThanOrEqual(2)
    expect(messages[0].role).toBe('user')
    expect(messages[0].content).toBe('帮我优化数据库查询')
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
