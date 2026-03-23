/**
 * AI triage for screenshot regression — sends images to VLM for analysis.
 * Supports Kimi-k2.5 (Dashscope) and Claude Vision (Anthropic).
 */

export interface AiTriage {
  verdict: 'regression' | 'acceptable' | 'uncertain'
  confidence: number
  reason: string
  model: string
  duration_ms: number
}

export interface VlmProvider {
  model: string
  analyze(
    images: { baseline: Buffer; actual: Buffer; diff: Buffer | null },
    metrics: { ssim: number; pixel_diff_percent: number; phash_distance: number }
  ): Promise<AiTriage>
}

const TRIAGE_PROMPT = `You are comparing two screenshots of a macOS desktop application (Engram).
- Image 1: baseline (the expected appearance)
- Image 2: actual (the current build)

Comparison metrics:
- SSIM: {ssim} (1.0 = identical, threshold: 0.95)
- Pixel diff: {pixel_diff_percent}% (threshold: 0.5%)
- Perceptual hash distance: {phash_distance} (threshold: 8)

Determine if this is:
- "regression": A real visual bug that needs fixing (layout shift, missing element, wrong color, broken rendering)
- "acceptable": A harmless rendering difference (font anti-aliasing, subpixel shift, shadow variation, timing-dependent content)
- "uncertain": Cannot determine confidently

Respond ONLY with JSON (no markdown): {"verdict": "regression|acceptable|uncertain", "confidence": 0.0-1.0, "reason": "one sentence"}`

const TRIAGE_PROMPT_WITH_DIFF = TRIAGE_PROMPT.replace(
  '- Image 2: actual (the current build)',
  '- Image 2: actual (the current build)\n- Image 3: pixel diff (differences highlighted in red)'
)

function buildPrompt(metrics: { ssim: number; pixel_diff_percent: number; phash_distance: number }, hasDiff: boolean): string {
  const template = hasDiff ? TRIAGE_PROMPT_WITH_DIFF : TRIAGE_PROMPT
  return template
    .replace('{ssim}', String(metrics.ssim))
    .replace('{pixel_diff_percent}', String(metrics.pixel_diff_percent))
    .replace('{phash_distance}', String(metrics.phash_distance))
}

function parseVlmResponse(text: string): { verdict: AiTriage['verdict']; confidence: number; reason: string } {
  // Try to extract JSON from response (may have markdown wrapping)
  const jsonMatch = text.match(/\{[\s\S]*\}/)
  if (!jsonMatch) throw new Error('invalid response: no JSON found')
  const parsed = JSON.parse(jsonMatch[0])
  if (!['regression', 'acceptable', 'uncertain'].includes(parsed.verdict)) {
    throw new Error(`invalid response: unknown verdict '${parsed.verdict}'`)
  }
  return {
    verdict: parsed.verdict,
    confidence: Math.max(0, Math.min(1, Number(parsed.confidence) || 0)),
    reason: String(parsed.reason || '').slice(0, 500),
  }
}

function makeUncertain(model: string, reason: string, durationMs: number): AiTriage {
  return { verdict: 'uncertain', confidence: 0, reason, model, duration_ms: durationMs }
}

class KimiProvider implements VlmProvider {
  model = 'kimi-k2.5'
  private apiKey: string
  constructor(apiKey: string) { this.apiKey = apiKey }

  async analyze(images: { baseline: Buffer; actual: Buffer; diff: Buffer | null }, metrics: { ssim: number; pixel_diff_percent: number; phash_distance: number }): Promise<AiTriage> {
    const start = performance.now()
    const prompt = buildPrompt(metrics, !!images.diff)
    const content: any[] = [{ type: 'text', text: prompt }]
    content.push({ type: 'image_url', image_url: { url: `data:image/png;base64,${images.baseline.toString('base64')}` } })
    content.push({ type: 'image_url', image_url: { url: `data:image/png;base64,${images.actual.toString('base64')}` } })
    if (images.diff) {
      content.push({ type: 'image_url', image_url: { url: `data:image/png;base64,${images.diff.toString('base64')}` } })
    }

    try {
      const resp = await fetch('https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.apiKey}` },
        body: JSON.stringify({ model: this.model, messages: [{ role: 'user', content }], max_tokens: 200, temperature: 0 }),
        signal: AbortSignal.timeout(30_000),
      })
      const elapsed = performance.now() - start
      if (!resp.ok) return makeUncertain(this.model, `API error: ${resp.status}`, elapsed)
      const data = await resp.json()
      const text = data.choices?.[0]?.message?.content ?? ''
      const parsed = parseVlmResponse(text)
      return { ...parsed, model: this.model, duration_ms: Math.round(elapsed) }
    } catch (err: any) {
      const elapsed = performance.now() - start
      if (err.name === 'TimeoutError') return makeUncertain(this.model, 'timeout', Math.round(elapsed))
      return makeUncertain(this.model, `API error: ${String(err).slice(0, 200)}`, Math.round(elapsed))
    }
  }
}

class ClaudeProvider implements VlmProvider {
  model = 'claude-sonnet-4-6-20250514'
  private apiKey: string
  constructor(apiKey: string) { this.apiKey = apiKey }

  async analyze(images: { baseline: Buffer; actual: Buffer; diff: Buffer | null }, metrics: { ssim: number; pixel_diff_percent: number; phash_distance: number }): Promise<AiTriage> {
    const start = performance.now()
    const prompt = buildPrompt(metrics, !!images.diff)
    const content: any[] = [{ type: 'text', text: prompt }]
    content.push({ type: 'image', source: { type: 'base64', media_type: 'image/png', data: images.baseline.toString('base64') } })
    content.push({ type: 'image', source: { type: 'base64', media_type: 'image/png', data: images.actual.toString('base64') } })
    if (images.diff) {
      content.push({ type: 'image', source: { type: 'base64', media_type: 'image/png', data: images.diff.toString('base64') } })
    }

    try {
      const resp = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-api-key': this.apiKey, 'anthropic-version': '2023-06-01' },
        body: JSON.stringify({ model: this.model, max_tokens: 200, messages: [{ role: 'user', content }] }),
        signal: AbortSignal.timeout(30_000),
      })
      const elapsed = performance.now() - start
      if (!resp.ok) return makeUncertain(this.model, `API error: ${resp.status}`, elapsed)
      const data = await resp.json()
      const text = data.content?.[0]?.text ?? ''
      const parsed = parseVlmResponse(text)
      return { ...parsed, model: this.model, duration_ms: Math.round(elapsed) }
    } catch (err: any) {
      const elapsed = performance.now() - start
      if (err.name === 'TimeoutError') return makeUncertain(this.model, 'timeout', Math.round(elapsed))
      return makeUncertain(this.model, `API error: ${String(err).slice(0, 200)}`, Math.round(elapsed))
    }
  }
}

export function createTriageProvider(): VlmProvider | null {
  const providerName = process.env.AI_TRIAGE_PROVIDER ?? 'kimi'
  if (providerName === 'claude') {
    const key = process.env.ANTHROPIC_API_KEY
    return key ? new ClaudeProvider(key) : null
  }
  // Default: kimi
  const key = process.env.DASHSCOPE_API_KEY
  return key ? new KimiProvider(key) : null
}

export function needsTriage(result: { status: string; metrics: { ssim: number; pixel_diff_percent: number } }): boolean {
  if (result.status === 'failed') return true
  if (result.status !== 'passed') return false  // 'new' or 'size_mismatch' → skip
  return result.metrics.ssim < 0.98 || result.metrics.pixel_diff_percent > 0.1
}
