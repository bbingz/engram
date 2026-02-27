// tests/adapters/windsurf.test.ts
import { describe, it, expect } from 'vitest'
import { WindsurfAdapter } from '../../src/adapters/windsurf.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_CACHE = join(__dirname, '../fixtures/windsurf/cache')

describe('WindsurfAdapter (cache mode)', () => {
  const adapter = new WindsurfAdapter('/nonexistent/daemon', FIXTURE_CACHE)

  it('name is windsurf', () => expect(adapter.name).toBe('windsurf'))

  it('listSessionFiles yields cache JSONL files', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    expect(files.some(f => f.endsWith('conv-w01.jsonl'))).toBe(true)
  })

  it('parseSessionInfo reads from cache', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-w01.jsonl')
    const info = await adapter.parseSessionInfo(filePath)
    expect(info).not.toBeNull()
    expect(info!.source).toBe('windsurf')
    expect(info!.id).toBe('conv-w01')
  })

  it('streamMessages yields messages', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-w01.jsonl')
    const msgs: { role: string }[] = []
    for await (const m of adapter.streamMessages(filePath)) msgs.push(m)
    expect(msgs).toHaveLength(2)
  })
})
