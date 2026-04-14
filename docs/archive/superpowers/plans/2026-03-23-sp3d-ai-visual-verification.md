# SP3d: AI Visual Verification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate VLM (Kimi-k2.5 / Claude Vision) to triage screenshot regression failures, filling the existing `ai_triage: null` field in comparison-report.json.

**Architecture:** New `scripts/ai-triage.ts` module with VlmProvider abstraction (KimiProvider + ClaudeProvider). Called from `screenshot-compare.ts` after the comparison loop. Serial execution per screenshot. PR comment enhanced with AI verdict column.

**Tech Stack:** Node.js `fetch()` with `AbortSignal.timeout()`, Dashscope OpenAI-compatible API, Anthropic Messages API, Vitest

**Spec:** `docs/superpowers/specs/2026-03-23-sp3d-ai-visual-verification-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `scripts/ai-triage.ts` | New: AiTriage interface, VlmProvider, KimiProvider, ClaudeProvider, provider factory |
| `scripts/screenshot-compare.ts` | Modify: update `ai_triage` type, add triage pass after comparisons |
| `.github/workflows/test.yml` | Modify: PR comment adds AI Verdict column |
| `tests/scripts/ai-triage.test.ts` | New: VLM response parsing, error handling, provider selection tests |

---

### Task 1: AI Triage Module

**Files:**
- Create: `scripts/ai-triage.ts`
- Create: `tests/scripts/ai-triage.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/scripts/` directory and `tests/scripts/ai-triage.test.ts`:

```typescript
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/scripts/ai-triage.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement ai-triage.ts**

Create `scripts/ai-triage.ts`:

```typescript
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/scripts/ai-triage.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/ai-triage.ts tests/scripts/ai-triage.test.ts
git commit -m "feat(visual): add AI triage module with Kimi + Claude VLM providers"
```

---

### Task 2: Integrate into screenshot-compare.ts

**Files:**
- Modify: `scripts/screenshot-compare.ts`

- [ ] **Step 1: Update ComparisonResult type**

In `scripts/screenshot-compare.ts`, search for `ai_triage: null;` in the `ComparisonResult` interface (line 55). Change to:

```typescript
ai_triage: AiTriage | null;
```

Add import at top (after existing imports):

```typescript
import { createTriageProvider, needsTriage, type AiTriage } from './ai-triage.js';
```

- [ ] **Step 2: Add AI triage pass after comparison loop**

In the `main()` function, after the report JSON is written (search for `fs.writeFileSync(reportPath`), add the AI triage pass BEFORE the report is written. Actually, move the `writeFileSync` after the triage pass. Restructure:

```typescript
// After the comparison loop (line 304) and before writing the report:

// AI triage pass — serial, only for failed or near-threshold results
const provider = createTriageProvider()
if (provider) {
  const triageTargets = results.filter(r => needsTriage(r))
  if (triageTargets.length > 0) {
    console.log(`\nAI Triage: ${triageTargets.length} screenshot(s) to analyze with ${provider.model}...`)
    for (const result of triageTargets) {
      try {
        const baseline = fs.readFileSync(result.paths.baseline)
        const actual = fs.readFileSync(result.paths.actual)
        const diff = result.paths.diff ? fs.readFileSync(result.paths.diff) : null
        result.ai_triage = await provider.analyze({ baseline, actual, diff }, result.metrics)
        const icon = result.ai_triage.verdict === 'acceptable' ? '✅' : result.ai_triage.verdict === 'regression' ? '❌' : '⚠️'
        console.log(`  ${icon} ${result.name}: ${result.ai_triage.verdict} (${result.ai_triage.confidence.toFixed(2)}) — ${result.ai_triage.reason}`)
      } catch (err) {
        console.log(`  ⚠️ ${result.name}: triage error — ${String(err).slice(0, 100)}`)
      }
    }
  }
}

// Then write the report (existing line, now after triage)
const report: ComparisonReport = { summary, results, thresholds: { ... } }
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n')
```

Note: The triage pass must happen BEFORE `writeFileSync` so the `ai_triage` field is populated in the JSON. The existing code writes the report right after the loop — move the `writeFileSync` after the triage pass.

- [ ] **Step 3: Build and verify**

Run: `npm run build && npm test`
Expected: Build clean, all tests pass

- [ ] **Step 4: Commit**

```bash
git add scripts/screenshot-compare.ts
git commit -m "feat(visual): integrate AI triage into screenshot comparison pipeline"
```

---

### Task 3: CI PR Comment Enhancement

**Files:**
- Modify: `.github/workflows/test.yml`

- [ ] **Step 1: Update PR comment template**

In `.github/workflows/test.yml`, find the PR comment script (search for `📸 **Screenshot Regression**`). Replace the table generation:

```javascript
// Replace existing table generation (lines 172-176) with:
let body = `📸 **Screenshot Regression**: ${failures.length} failure(s)\n\n`;
body += `| Screen | SSIM | Pixel Diff | AI | Status |\n|--------|------|------------|-----|--------|\n`;
for (const f of failures) {
  let aiCol = '—';
  if (f.ai_triage) {
    const icon = f.ai_triage.verdict === 'acceptable' ? '✅' : f.ai_triage.verdict === 'regression' ? '❌' : '⚠️';
    aiCol = `${icon} ${f.ai_triage.verdict} (${f.ai_triage.confidence.toFixed(2)})`;
  }
  body += `| ${f.name} | ${f.metrics.ssim.toFixed(3)} | ${f.metrics.pixel_diff_percent.toFixed(2)}% | ${aiCol} | ❌ |\n`;
}
```

- [ ] **Step 2: Add DASHSCOPE_API_KEY secret to CI env**

In the `ui-test-smoke` job, add the env var for the screenshot comparison step. Search for `SCREENSHOTS_DIR:` and add after:

```yaml
env:
  SCREENSHOTS_DIR: ${{ runner.temp }}/screenshots
  DASHSCOPE_API_KEY: ${{ secrets.DASHSCOPE_API_KEY }}
```

If `DASHSCOPE_API_KEY` is not set as a GitHub secret, AI triage will gracefully skip (provider returns null).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "feat(visual): add AI verdict column to CI PR comment"
```

---

### Task 4: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `npm test`
Expected: All tests pass

- [ ] **Step 2: Build check**

Run: `npm run build`
Expected: Clean build

- [ ] **Step 3: Verify AI triage integration locally**

```bash
DASHSCOPE_API_KEY=test npx tsx scripts/screenshot-compare.ts 2>&1 || true
```
Expected: Script runs, AI triage skips or errors gracefully (no baseline changes, so comparison may exit early). Key verification: no crash, `ai_triage` field in output is either `null` or an `AiTriage` object.

- [ ] **Step 4: Mark spec as implemented**

```bash
sed -i '' 's/^**Status**: Draft/**Status**: Implemented/' docs/superpowers/specs/2026-03-23-sp3d-ai-visual-verification-design.md
git add docs/superpowers/specs/2026-03-23-sp3d-ai-visual-verification-design.md
git commit -m "docs: mark SP3d spec as implemented"
```
