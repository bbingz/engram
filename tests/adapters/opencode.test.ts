// tests/adapters/opencode.test.ts
import { describe, it, expect } from 'vitest'
import { OpenCodeAdapter } from '../../src/adapters/opencode.js'

describe('OpenCodeAdapter', () => {
  it('name is opencode', () => {
    const adapter = new OpenCodeAdapter()
    expect(adapter.name).toBe('opencode')
  })

  it('detect returns false if storage dir not found', async () => {
    const adapter = new OpenCodeAdapter('/nonexistent/path')
    expect(await adapter.detect()).toBe(false)
  })

  it('listSessionFiles yields nothing for nonexistent path', async () => {
    const adapter = new OpenCodeAdapter('/nonexistent/path')
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) {
      files.push(f)
    }
    expect(files).toHaveLength(0)
  })
})
