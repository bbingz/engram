import { describe, it, expect } from 'vitest'
import { runWithContext, getRequestContext, getRequestId } from '../../src/core/request-context.js'

describe('request-context', () => {
  it('returns undefined when no context is set', () => {
    expect(getRequestContext()).toBeUndefined()
    expect(getRequestId()).toBeUndefined()
  })

  it('provides context within runWithContext', () => {
    runWithContext({ requestId: 'req-1', source: 'mcp' }, () => {
      expect(getRequestId()).toBe('req-1')
      expect(getRequestContext()?.source).toBe('mcp')
    })
  })

  it('nested context overrides outer', () => {
    runWithContext({ requestId: 'outer', source: 'http' }, () => {
      expect(getRequestId()).toBe('outer')
      runWithContext({ requestId: 'inner', source: 'mcp' }, () => {
        expect(getRequestId()).toBe('inner')
      })
      expect(getRequestId()).toBe('outer')
    })
  })

  it('propagates through async/await', async () => {
    await runWithContext({ requestId: 'async-1', source: 'indexer' }, async () => {
      await new Promise(r => setTimeout(r, 10))
      expect(getRequestId()).toBe('async-1')
    })
  })

  it('propagates through Promise.all', async () => {
    await runWithContext({ requestId: 'parallel', source: 'watcher' }, async () => {
      const results = await Promise.all([
        Promise.resolve(getRequestId()),
        new Promise<string | undefined>(r => setTimeout(() => r(getRequestId()), 5)),
      ])
      expect(results).toEqual(['parallel', 'parallel'])
    })
  })

  it('context is not visible outside runWithContext', () => {
    runWithContext({ requestId: 'scoped', source: 'scheduler' }, () => {})
    expect(getRequestId()).toBeUndefined()
  })
})
