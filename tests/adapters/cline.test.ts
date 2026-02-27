import { describe, it, expect } from 'vitest'
import { ClineAdapter } from '../../src/adapters/cline.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_TASKS = join(__dirname, '../fixtures/cline/tasks')
const FIXTURE_FILE = join(FIXTURE_TASKS, '1770000000000/ui_messages.json')

describe('ClineAdapter', () => {
  const adapter = new ClineAdapter(FIXTURE_TASKS)

  it('name is cline', () => {
    expect(adapter.name).toBe('cline')
  })

  it('listSessionFiles yields ui_messages.json paths', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    expect(files).toHaveLength(1)
    expect(files[0]).toContain('ui_messages.json')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE_FILE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('1770000000000')
    expect(info!.source).toBe('cline')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.summary).toBe('帮我写单元测试')
    expect(info!.userMessageCount).toBe(2)
  })

  it('streamMessages yields user and assistant', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE_FILE)) messages.push(msg)
    expect(messages.some(m => m.role === 'user')).toBe(true)
    expect(messages.some(m => m.role === 'assistant')).toBe(true)
    expect(messages[0].content).toBe('帮我写单元测试')
  })
})
