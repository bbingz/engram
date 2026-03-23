// tests/core/error-serializer.test.ts
import { describe, it, expect } from 'vitest'
import { serializeError } from '../../src/core/error-serializer.js'

describe('serializeError', () => {
  it('serializes Error instances with stack', () => {
    const err = new Error('fail')
    const result = serializeError(err)
    expect(result.name).toBe('Error')
    expect(result.message).toBe('fail')
    expect(result.stack).toContain('fail')
  })

  it('serializes TypeError', () => {
    const err = new TypeError('bad type')
    const result = serializeError(err)
    expect(result.name).toBe('TypeError')
  })

  it('serializes Error with code property', () => {
    const err = Object.assign(new Error('enoent'), { code: 'ENOENT' })
    const result = serializeError(err)
    expect(result.code).toBe('ENOENT')
  })

  it('serializes string errors', () => {
    const result = serializeError('something broke')
    expect(result.name).toBe('UnknownError')
    expect(result.message).toBe('something broke')
    expect(result.stack).toBeUndefined()
  })

  it('serializes null/undefined', () => {
    expect(serializeError(null).message).toBe('null')
    expect(serializeError(undefined).message).toBe('undefined')
  })
})
