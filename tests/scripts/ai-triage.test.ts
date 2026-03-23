import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { createTriageProvider, type AiTriage } from '../../scripts/ai-triage.js'

describe('createTriageProvider', () => {
  const originalEnv = { ...process.env }
  afterEach(() => { process.env = { ...originalEnv } })

  it('returns null when no API key', () => {
    delete process.env.DASHSCOPE_API_KEY
    delete process.env.ANTHROPIC_API_KEY
    const provider = createTriageProvider()
    expect(provider).toBeNull()
  })

  it('creates kimi provider by default with DASHSCOPE_API_KEY', () => {
    process.env.DASHSCOPE_API_KEY = 'test-key'
    delete process.env.AI_TRIAGE_PROVIDER
    const provider = createTriageProvider()
    expect(provider).not.toBeNull()
    expect(provider!.model).toBe('kimi-k2.5')
  })

  it('creates claude provider when AI_TRIAGE_PROVIDER=claude', () => {
    process.env.AI_TRIAGE_PROVIDER = 'claude'
    process.env.ANTHROPIC_API_KEY = 'test-key'
    const provider = createTriageProvider()
    expect(provider).not.toBeNull()
    expect(provider!.model).toContain('claude')
  })
})

describe('VlmProvider.analyze', () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('parses valid VLM JSON response', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({
        choices: [{ message: { content: '{"verdict": "acceptable", "confidence": 0.95, "reason": "Font anti-aliasing difference"}' } }]
      })
    })

    process.env.DASHSCOPE_API_KEY = 'test-key'
    const provider = createTriageProvider()!
    const result = await provider.analyze(
      { baseline: Buffer.from('png'), actual: Buffer.from('png'), diff: Buffer.from('png') },
      { ssim: 0.93, pixel_diff_percent: 1.2, phash_distance: 5 }
    )
    expect(result.verdict).toBe('acceptable')
    expect(result.confidence).toBe(0.95)
    expect(result.reason).toBe('Font anti-aliasing difference')
    expect(result.model).toBe('kimi-k2.5')
    expect(result.duration_ms).toBeGreaterThanOrEqual(0)
  })

  it('returns uncertain on API error', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
      text: () => Promise.resolve('Internal Server Error')
    })

    process.env.DASHSCOPE_API_KEY = 'test-key'
    const provider = createTriageProvider()!
    const result = await provider.analyze(
      { baseline: Buffer.from('png'), actual: Buffer.from('png'), diff: null },
      { ssim: 0.90, pixel_diff_percent: 2, phash_distance: 10 }
    )
    expect(result.verdict).toBe('uncertain')
    expect(result.confidence).toBe(0)
    expect(result.reason).toContain('API error')
  })

  it('returns uncertain on invalid JSON in response', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({
        choices: [{ message: { content: 'not valid json' } }]
      })
    })

    process.env.DASHSCOPE_API_KEY = 'test-key'
    const provider = createTriageProvider()!
    const result = await provider.analyze(
      { baseline: Buffer.from('png'), actual: Buffer.from('png'), diff: Buffer.from('png') },
      { ssim: 0.92, pixel_diff_percent: 1.5, phash_distance: 6 }
    )
    expect(result.verdict).toBe('uncertain')
    expect(result.reason).toContain('invalid response')
  })

  it('handles null diff buffer (size_mismatch)', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({
        choices: [{ message: { content: '{"verdict": "regression", "confidence": 0.9, "reason": "Size mismatch indicates layout change"}' } }]
      })
    })

    process.env.DASHSCOPE_API_KEY = 'test-key'
    const provider = createTriageProvider()!
    const result = await provider.analyze(
      { baseline: Buffer.from('png'), actual: Buffer.from('png'), diff: null },
      { ssim: 0, pixel_diff_percent: 100, phash_distance: 64 }
    )
    expect(result.verdict).toBe('regression')
    // Verify only 2 images sent (no diff)
    const fetchCall = (globalThis.fetch as any).mock.calls[0]
    const body = JSON.parse(fetchCall[1].body)
    const imageBlocks = body.messages[0].content.filter((b: any) => b.type === 'image_url')
    expect(imageBlocks).toHaveLength(2)
  })
})

describe('needsTriage', () => {
  it('returns true for failed status', async () => {
    const { needsTriage } = await import('../../scripts/ai-triage.js')
    expect(needsTriage({ status: 'failed', metrics: { ssim: 0.90, pixel_diff_percent: 2, phash_distance: 10 } } as any)).toBe(true)
  })

  it('returns true for passed with low SSIM', async () => {
    const { needsTriage } = await import('../../scripts/ai-triage.js')
    expect(needsTriage({ status: 'passed', metrics: { ssim: 0.97, pixel_diff_percent: 0.05, phash_distance: 1 } } as any)).toBe(true)
  })

  it('returns false for passed with good metrics', async () => {
    const { needsTriage } = await import('../../scripts/ai-triage.js')
    expect(needsTriage({ status: 'passed', metrics: { ssim: 0.99, pixel_diff_percent: 0.05, phash_distance: 1 } } as any)).toBe(false)
  })

  it('returns false for new status', async () => {
    const { needsTriage } = await import('../../scripts/ai-triage.js')
    expect(needsTriage({ status: 'new', metrics: { ssim: 0, pixel_diff_percent: 0, phash_distance: 0 } } as any)).toBe(false)
  })
})
