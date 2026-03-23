# SP3d: AI Visual Verification for Screenshot Regression

**Date**: 2026-03-23
**Status**: Draft
**Scope**: Gap #6 — integrate VLM to triage screenshot regression failures

## Decisions

| Decision | Choice |
|----------|--------|
| VLM provider | Configurable: Kimi-k2.5 via Dashscope (default), Claude Vision optional |
| When to run | Failed screenshots + passed-but-near-threshold (SSIM < 0.98 or pixel_diff > 0.1%) |
| Output format | `ai_triage` field in comparison-report.json: verdict/confidence/reason/model/duration_ms |
| Execution | Serial (rate limit safe), 30s timeout per screenshot |
| CI impact | PR comment gains AI Verdict column; exit code still based on metrics, not AI |
| Dependencies | No new npm packages — uses raw `fetch()` like existing `ai-client.ts` |

## 1. AiTriage Output Format

Fills the existing `ai_triage: null` field in `ComparisonResult`:

```typescript
interface AiTriage {
  verdict: 'regression' | 'acceptable' | 'uncertain'
  confidence: number      // 0-1
  reason: string          // One sentence explanation
  model: string           // 'kimi-k2.5' | 'claude-sonnet-4-6' etc.
  duration_ms: number     // API call latency
}
```

- `regression` — Real visual difference, needs fixing
- `acceptable` — Rendering noise (font anti-aliasing, subpixel shift, etc.)
- `uncertain` — AI can't determine, human review needed

## 2. VLM Provider

### New file: `scripts/ai-triage.ts`

```typescript
interface VlmProvider {
  analyze(images: { baseline: Buffer; actual: Buffer; diff: Buffer | null },
          metrics: { ssim: number; pixel_diff_percent: number; phash_distance: number }
  ): Promise<AiTriage>
}
```

### KimiProvider (default)

Uses Dashscope OpenAI-compatible API with image support:

```typescript
// POST https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions
{
  model: 'kimi-k2.5',
  messages: [{
    role: 'user',
    content: [
      { type: 'text', text: TRIAGE_PROMPT },
      { type: 'image_url', image_url: { url: `data:image/png;base64,${baselineB64}` } },
      { type: 'image_url', image_url: { url: `data:image/png;base64,${actualB64}` } },
      { type: 'image_url', image_url: { url: `data:image/png;base64,${diffB64}` } },
    ]
  }],
  max_tokens: 200,
  temperature: 0,
}
```

Env var: `DASHSCOPE_API_KEY` (required for Kimi)

### ClaudeProvider (optional)

Uses Anthropic Messages API with image support:

```typescript
// POST https://api.anthropic.com/v1/messages
{
  model: 'claude-sonnet-4-6-20250514',
  max_tokens: 200,
  messages: [{
    role: 'user',
    content: [
      { type: 'text', text: TRIAGE_PROMPT },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: baselineB64 } },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: actualB64 } },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: diffB64 } },
    ]
  }]
}
```

Env var: `ANTHROPIC_API_KEY` (required for Claude)

Required headers for Anthropic: `{ 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' }` (consistent with existing `ai-client.ts` line 162).

### Provider selection

```typescript
const provider = process.env.AI_TRIAGE_PROVIDER ?? 'kimi'
// 'kimi' → KimiProvider
// 'claude' → ClaudeProvider
```

No API key → skip AI triage entirely, `ai_triage` stays `null`.

## 3. Triage Prompt

```
You are comparing two screenshots of a macOS desktop application (Engram).
- Image 1: baseline (the expected appearance)
- Image 2: actual (the current build)
- Image 3: pixel diff (differences highlighted in red)

Comparison metrics:
- SSIM: {ssim} (1.0 = identical, threshold: 0.95)
- Pixel diff: {pixel_diff_percent}% (threshold: 0.5%)
- Perceptual hash distance: {phash_distance} (threshold: 8)

Determine if this is:
- "regression": A real visual bug that needs fixing (layout shift, missing element, wrong color, broken rendering)
- "acceptable": A harmless rendering difference (font anti-aliasing, subpixel shift, shadow variation, timing-dependent content like timestamps)
- "uncertain": Cannot determine confidently

Respond ONLY with JSON (no markdown, no explanation outside JSON):
{"verdict": "regression|acceptable|uncertain", "confidence": 0.0-1.0, "reason": "one sentence"}
```

## 4. Integration into screenshot-compare.ts

After the existing comparison loop, add an AI triage pass:

```typescript
// After all comparisons are done:
const needsTriage = results.filter(r =>
  r.status === 'failed' ||
  (r.status === 'passed' && (r.metrics.ssim < 0.98 || r.metrics.pixel_diff_percent > 0.1))
)

if (needsTriage.length > 0 && provider) {
  for (const result of needsTriage) {  // Serial — rate limit safe
    try {
      const baseline = readFileSync(result.paths.baseline)
      const actual = readFileSync(result.paths.actual)
      const diff = result.paths.diff ? readFileSync(result.paths.diff) : null
      result.ai_triage = await provider.analyze({ baseline, actual, diff }, result.metrics)
    } catch (err) {
      result.ai_triage = {
        verdict: 'uncertain',
        confidence: 0,
        reason: `API error: ${String(err).slice(0, 200)}`,
        model: provider.model,
        duration_ms: 0,
      }
    }
  }
}
```

**Near-threshold criteria** (for passed screenshots):
- SSIM < 0.98 (pass threshold is 0.95, but 0.95-0.98 is "borderline")
- pixel_diff_percent > 0.1% (pass threshold is 0.5%, but >0.1% is notable)

Either condition triggers triage for passed screenshots.

## 5. CI PR Comment Enhancement

Modify `.github/workflows/test.yml` PR comment section to include AI verdict:

```markdown
📸 **Screenshot Regression**: N failure(s)
| Screen | SSIM | Pixel Diff | AI | Status |
|--------|------|------------|-----|--------|
| name   | 0.92 | 1.2%       | ✅ acceptable (0.95) | ❌ |
```

AI column format:
- `✅ acceptable (0.95)` — AI says OK with 0.95 confidence
- `❌ regression (0.88)` — AI confirms regression
- `⚠️ uncertain (0.40)` — AI unsure
- `—` — AI triage not run (no API key or not triggered)

**Exit code unchanged**: still based on metric thresholds, not AI verdict. AI is advisory only.

## 6. Error Handling

| Scenario | Behavior |
|----------|----------|
| No API key | Skip AI triage, `ai_triage` stays `null` |
| API timeout (>30s) | `verdict: 'uncertain', reason: 'timeout'`. Use `AbortSignal.timeout(30_000)` in fetch options (Node 18+) |
| API error (4xx/5xx) | `verdict: 'uncertain', reason: 'API error: ...'` |
| Invalid JSON response | `verdict: 'uncertain', reason: 'invalid response'` |
| Diff image missing (status=new) | Skip triage for this screenshot |
| Diff buffer null (size_mismatch) | Send only 2 images, adjust prompt: "No diff image available (size mismatch between baseline and actual)" |

## 7. Test Strategy

### New: `tests/scripts/ai-triage.test.ts`

- **VLM response parsing**: mock fetch → valid JSON response → correct AiTriage struct
- **Error handling**: mock fetch 500 → verdict 'uncertain'
- **Timeout**: mock slow fetch → verdict 'uncertain' with 'timeout' reason
- **No API key**: provider returns null, triage skipped
- **Near-threshold detection**: SSIM 0.97/passed → needs triage; SSIM 0.99/passed → skip
- **Provider selection**: env var kimi → KimiProvider; env var claude → ClaudeProvider

### No integration test with real VLM (too slow, needs API key)

## 8. Files Changed

| File | Changes |
|------|---------|
| `scripts/ai-triage.ts` | New: VlmProvider interface, KimiProvider, ClaudeProvider, triage prompt |
| `scripts/screenshot-compare.ts` | Modify: change `ai_triage: null` type to `AiTriage \| null`, add AI triage pass after comparisons, import provider |
| `.github/workflows/test.yml` | Modify: PR comment adds AI Verdict column |
| `tests/scripts/ai-triage.test.ts` | New: triage tests with mocked fetch |

## 9. Out of Scope

- Swift UI for AI triage results (JSON report only)
- Auto-accept based on AI verdict (metrics still decide pass/fail)
- Image resizing/compression before sending to VLM (send original PNGs)
- Caching VLM responses across runs
