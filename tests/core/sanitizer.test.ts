import { describe, it, expect } from 'vitest'
import { sanitize, applyPatterns } from '../../src/core/sanitizer.js'

describe('applyPatterns', () => {
  it('redacts OpenAI API key', () => {
    expect(applyPatterns('key is sk-abcdefghijklmnopqrstuvwx')).toBe('key is sk-***')
  })

  it('redacts OpenAI sk-proj-* key format', () => {
    expect(applyPatterns('sk-proj-abc12345678901234567')).toBe('sk-***')
  })

  it('redacts Anthropic API key', () => {
    expect(applyPatterns('sk-ant-api03-abcdefghijklmnopqrstuvwx')).toBe('sk-ant-***')
  })

  it('redacts Bearer token', () => {
    expect(applyPatterns('Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc')).toBe('Authorization: Bearer ***')
  })

  it('redacts hex secret after key= separator', () => {
    const hex32 = 'a'.repeat(32)
    expect(applyPatterns(`apikey=${hex32}`)).toBe('apikey=***')
  })

  it('redacts email addresses', () => {
    expect(applyPatterns('contact user@example.com for help')).toBe('contact ***@***.*** for help')
  })

  it('returns unchanged string with no sensitive data', () => {
    const safe = 'indexed 42 sessions in 123ms'
    expect(applyPatterns(safe)).toBe(safe)
  })

  // False positive checks
  it('does NOT redact npm scopes like @types/node', () => {
    expect(applyPatterns('import @types/node')).toBe('import @types/node')
  })

  it('does NOT redact short hex strings (< 32 chars)', () => {
    expect(applyPatterns('key=abcdef1234')).toBe('key=abcdef1234')
  })

  it('does NOT redact git commit hash after space separator', () => {
    const hash = 'a1b2c3d4e5f6'.repeat(3) // 36 hex chars
    expect(applyPatterns(`cache key ${hash}`)).toBe(`cache key ${hash}`)
  })

  it('handles multiple sensitive values in one string', () => {
    const input = 'key=aaaa' + 'a'.repeat(28) + ' user@test.com sk-abcdefghijklmnopqrstuvwx'
    const result = applyPatterns(input)
    expect(result).toContain('key=***')
    expect(result).toContain('***@***.***')
    expect(result).toContain('sk-***')
  })
})

describe('sanitize', () => {
  it('recursively sanitizes nested objects', () => {
    const obj = {
      message: 'hello',
      data: { secret: 'key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', nested: { email: 'a@b.com' } },
    }
    const result = sanitize(obj)
    expect((result.data as any).secret).toBe('key=***')
    expect((result.data as any).nested.email).toBe('***@***.***')
  })

  it('sanitizes arrays', () => {
    const obj = { list: ['sk-abcdefghijklmnopqrstuvwx', 'safe'] }
    const result = sanitize(obj)
    expect((result.list as string[])[0]).toBe('sk-***')
    expect((result.list as string[])[1]).toBe('safe')
  })

  it('preserves non-string values', () => {
    const obj = { count: 42, flag: true, nil: null }
    expect(sanitize(obj)).toEqual({ count: 42, flag: true, nil: null })
  })

  it('returns empty object unchanged', () => {
    expect(sanitize({})).toEqual({})
  })
})
