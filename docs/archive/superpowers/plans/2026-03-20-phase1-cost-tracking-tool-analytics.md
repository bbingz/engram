# Phase 1: Cost Tracking + Tool Analytics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract token usage and tool call data during session indexing, store in DB, expose via MCP tools and Web API.

**Architecture:** Extend the indexer pipeline to extract `message.usage` (tokens) and `tool_use` content blocks during `streamMessages()`. Store in two new tables (`session_costs`, `session_tools`) independent of the snapshot write path. Expose via `get_costs` and `tool_analytics` MCP tools + `/api/costs` and `/api/tool-analytics` web endpoints.

**Tech Stack:** TypeScript, SQLite (better-sqlite3), Vitest, Hono

**Spec:** `docs/superpowers/specs/2026-03-20-readout-inspired-features-design.md` — Phase 1 section

---

**Note:** Line numbers in this plan are approximate reference points from the time of writing. Earlier tasks modify files, causing line numbers to drift. Use function/method names to locate insertion points.

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `src/core/pricing.ts` | Model pricing table + `computeCost()` function |
| `src/tools/get_costs.ts` | MCP tool: cost summary by model/source/project/day |
| `src/tools/tool_analytics.ts` | MCP tool: tool usage frequency and patterns |
| `tests/core/pricing.test.ts` | Unit tests for pricing computation |
| `tests/tools/get_costs.test.ts` | Integration tests for cost tool |
| `tests/tools/tool_analytics.test.ts` | Integration tests for tool analytics |
| `tests/fixtures/claude-code/session-with-usage.jsonl` | Fixture with `message.usage` and `tool_use` data |

### Modified Files
| File | Changes |
|------|---------|
| `src/adapters/types.ts:34-38` | Add `TokenUsage` interface, `usage` field on `Message` |
| `src/adapters/claude-code.ts:155-180,222-246` | Extract `usage` and `toolCalls` in `streamMessages()` |
| `src/core/db.ts:81-102` | Add `session_costs` and `session_tools` table migrations |
| `src/core/indexer.ts:148-175` | Accumulate tokens/tools during indexing, write to new tables |
| `src/index.ts:73-163` | Register `get_costs` and `tool_analytics` tools |
| `src/web.ts:253+` | Add `/api/costs` and `/api/tool-analytics` endpoints |
| `src/daemon.ts:70-99` | Add `backfillCosts()` and `backfillToolAnalytics()` calls on startup |

---

### Task 1: Add TokenUsage to Message Interface

**Files:**
- Modify: `src/adapters/types.ts:28-38`

- [ ] **Step 1: Add TokenUsage interface and usage field**

In `src/adapters/types.ts`, add `TokenUsage` interface before `Message` and add `usage` field:

```typescript
// After ToolCall interface (line 32):
export interface TokenUsage {
  inputTokens: number
  outputTokens: number
  cacheReadTokens?: number
  cacheCreationTokens?: number
}

// Add to Message interface:
export interface Message {
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp?: string
  toolCalls?: ToolCall[]
  usage?: TokenUsage
}
```

- [ ] **Step 2: Verify build**

Run: `npm run build`
Expected: Clean compile, no errors. `usage` and `toolCalls` are optional so existing code is unaffected.

- [ ] **Step 3: Run existing tests**

Run: `npm test`
Expected: All existing tests pass (no behavior change, only type additions).

- [ ] **Step 4: Commit**

```bash
git add src/adapters/types.ts
git commit -m "feat: add TokenUsage interface to Message type"
```

---

### Task 2: Create Test Fixture with Usage Data

**Files:**
- Create: `tests/fixtures/claude-code/session-with-usage.jsonl`

- [ ] **Step 1: Create fixture file**

Create a minimal Claude Code JSONL session file that contains:
- 1 system message (session header with cwd, sessionId, version)
- 1 user message
- 1 assistant message with `message.usage` (input_tokens, output_tokens, cache fields) and `message.content` array containing a `text` block + a `tool_use` block
- 1 assistant message with `message.usage` and `message.content` containing a `text` block + another `tool_use` block

The fixture must match the exact format observed in real Claude Code session files:
```jsonl
{"type":"system","subtype":"init","content":"Session started","timestamp":"2026-03-20T10:00:00.000Z","sessionId":"test-usage-session","cwd":"/test/project","version":"2.1.63","uuid":"uuid-1","parentUuid":null,"isSidechain":false,"userType":"external","level":"info","isMeta":true}
{"type":"user","message":{"role":"user","content":"Fix the auth bug"},"timestamp":"2026-03-20T10:00:01.000Z","sessionId":"test-usage-session","cwd":"/test/project","version":"2.1.63","uuid":"uuid-2","parentUuid":null,"isSidechain":false,"userType":"external"}
{"type":"assistant","message":{"id":"msg-1","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"Let me read the file."},{"type":"tool_use","id":"tu-1","name":"Read","input":{"file_path":"src/auth.ts"}}],"stop_reason":"tool_use","usage":{"input_tokens":1500,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_read_input_tokens":500}},"timestamp":"2026-03-20T10:00:02.000Z","sessionId":"test-usage-session","cwd":"/test/project","version":"2.1.63","uuid":"uuid-3","parentUuid":null,"isSidechain":false,"userType":"external","requestId":"req-1"}
{"type":"assistant","message":{"id":"msg-2","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"I'll fix the bug now."},{"type":"tool_use","id":"tu-2","name":"Edit","input":{"file_path":"src/auth.ts","old_string":"broken","new_string":"fixed"}}],"stop_reason":"tool_use","usage":{"input_tokens":2000,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":1800}},"timestamp":"2026-03-20T10:00:05.000Z","sessionId":"test-usage-session","cwd":"/test/project","version":"2.1.63","uuid":"uuid-4","parentUuid":null,"isSidechain":false,"userType":"external","requestId":"req-2"}
```

- [ ] **Step 2: Verify fixture is valid JSON**

Run: `node -e "const fs=require('fs'); fs.readFileSync('tests/fixtures/claude-code/session-with-usage.jsonl','utf8').split('\\n').filter(Boolean).forEach(l => JSON.parse(l)); console.log('Valid')"`
Expected: "Valid"

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/claude-code/session-with-usage.jsonl
git commit -m "test: add Claude Code fixture with usage and tool_use data"
```

---

### Task 3: Extract Usage and ToolCalls in Claude Code Adapter

**Files:**
- Modify: `src/adapters/claude-code.ts:155-180,222-246`
- Test: `tests/adapters/claude-code.test.ts`

- [ ] **Step 1: Write failing tests**

Add tests to `tests/adapters/claude-code.test.ts`:

```typescript
// At the end of the existing describe block:

describe('streamMessages with usage data', () => {
  const USAGE_FIXTURE = resolve(__dirname, '../fixtures/claude-code/session-with-usage.jsonl')

  it('extracts token usage from assistant messages', async () => {
    const messages: Message[] = []
    for await (const msg of adapter.streamMessages(USAGE_FIXTURE)) {
      messages.push(msg)
    }
    const assistantMsgs = messages.filter(m => m.role === 'assistant')
    expect(assistantMsgs.length).toBeGreaterThanOrEqual(2)

    // First assistant message should have usage
    const first = assistantMsgs[0]
    expect(first.usage).toBeDefined()
    expect(first.usage!.inputTokens).toBe(1500)
    expect(first.usage!.outputTokens).toBe(50)
    expect(first.usage!.cacheCreationTokens).toBe(1000)
    expect(first.usage!.cacheReadTokens).toBe(500)

    // Second assistant message
    const second = assistantMsgs[1]
    expect(second.usage).toBeDefined()
    expect(second.usage!.inputTokens).toBe(2000)
    expect(second.usage!.outputTokens).toBe(100)
  })

  it('extracts toolCalls from assistant messages', async () => {
    const messages: Message[] = []
    for await (const msg of adapter.streamMessages(USAGE_FIXTURE)) {
      messages.push(msg)
    }
    const assistantMsgs = messages.filter(m => m.role === 'assistant')

    const first = assistantMsgs[0]
    expect(first.toolCalls).toBeDefined()
    expect(first.toolCalls!.length).toBe(1)
    expect(first.toolCalls![0].name).toBe('Read')

    const second = assistantMsgs[1]
    expect(second.toolCalls).toBeDefined()
    expect(second.toolCalls![0].name).toBe('Edit')
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/adapters/claude-code.test.ts`
Expected: FAIL — `usage` is undefined, `toolCalls` is undefined.

- [ ] **Step 3: Implement usage extraction in streamMessages()**

In `src/adapters/claude-code.ts`, modify the `streamMessages()` method. Where it currently yields messages (around line 173-177), add extraction of `usage` from `raw.message.usage` and `toolCalls` from content array:

The current yield site (around line 172-178) computes values inline:
```typescript
yield {
  role: type as 'user' | 'assistant',
  content: this.extractContent(msg?.content),
  timestamp: obj.timestamp as string | undefined,
}
```

Refactor to capture locals, then add extraction:
```typescript
// Replace the inline yield with:
const role = type as 'user' | 'assistant'
const content = this.extractContent(msg?.content)
const timestamp = obj.timestamp as string | undefined

// Extract usage from message object (obj.message is already `msg`)
let usage: TokenUsage | undefined
let toolCalls: ToolCall[] | undefined

if (msg && typeof msg === 'object') {
  // Extract usage
  const rawUsage = (msg as any).usage
  if (rawUsage && typeof rawUsage === 'object') {
    usage = {
      inputTokens: rawUsage.input_tokens ?? 0,
      outputTokens: rawUsage.output_tokens ?? 0,
      cacheReadTokens: rawUsage.cache_read_input_tokens,
      cacheCreationTokens: rawUsage.cache_creation_input_tokens,
    }
  }

  // Extract toolCalls from content array
  const rawContent = (msg as any).content
  if (Array.isArray(rawContent)) {
    const calls = rawContent
      .filter((c: any) => c.type === 'tool_use' && c.name)
      .map((c: any) => ({
        name: c.name as string,
        input: c.input ? JSON.stringify(c.input).slice(0, 500) : undefined,
      }))
    if (calls.length > 0) toolCalls = calls
  }
}

yield { role, content, timestamp, usage, toolCalls }
```

Note: `obj` is the parsed JSONL line, `msg` is `obj.message as Record<string, unknown>` (from ~line 172). Variable names must match the existing code.

Import `TokenUsage` and `ToolCall` from `types.ts` at the top of the file.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/adapters/claude-code.test.ts`
Expected: All tests pass including the new ones.

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `npm test`
Expected: All tests pass. Existing tests unaffected because `usage` and `toolCalls` are optional.

- [ ] **Step 6: Commit**

```bash
git add src/adapters/claude-code.ts tests/adapters/claude-code.test.ts
git commit -m "feat: extract token usage and tool calls in Claude Code adapter"
```

---

### Task 4: Create Pricing Module

**Files:**
- Create: `src/core/pricing.ts`
- Create: `tests/core/pricing.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/core/pricing.test.ts`:

```typescript
import { describe, it, expect } from 'vitest'
import { computeCost, getModelPrice } from '../../src/core/pricing.js'

describe('pricing', () => {
  describe('getModelPrice', () => {
    it('returns exact match', () => {
      const price = getModelPrice('claude-sonnet-4-6')
      expect(price).toBeDefined()
      expect(price!.input).toBe(3)
      expect(price!.output).toBe(15)
    })

    it('matches versioned model by prefix', () => {
      const price = getModelPrice('claude-sonnet-4-5-20250929')
      expect(price).toBeDefined()
      expect(price!.input).toBe(3)
    })

    it('returns undefined for unknown model', () => {
      expect(getModelPrice('totally-unknown-model')).toBeUndefined()
    })

    it('uses custom pricing override', () => {
      const custom = { 'my-model': { input: 99, output: 99, cacheRead: 9, cacheWrite: 9 } }
      const price = getModelPrice('my-model', custom)
      expect(price).toBeDefined()
      expect(price!.input).toBe(99)
    })
  })

  describe('computeCost', () => {
    it('computes cost for known model', () => {
      // claude-sonnet-4-6: input=3, output=15, cacheRead=0.3, cacheWrite=3.75 per 1M
      const cost = computeCost('claude-sonnet-4-6', 1_000_000, 100_000, 500_000, 200_000)
      // input: 3.0, output: 1.5, cacheRead: 0.15, cacheWrite: 0.75 = 5.4
      expect(cost).toBeCloseTo(5.4, 1)
    })

    it('returns 0 for unknown model', () => {
      expect(computeCost('unknown-model', 1000, 500, 0, 0)).toBe(0)
    })

    it('handles zero tokens', () => {
      expect(computeCost('claude-sonnet-4-6', 0, 0, 0, 0)).toBe(0)
    })
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/core/pricing.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement pricing module**

Create `src/core/pricing.ts`:

```typescript
export interface ModelPrice {
  input: number     // USD per 1M input tokens
  output: number    // USD per 1M output tokens
  cacheRead: number // USD per 1M cache-read tokens
  cacheWrite: number // USD per 1M cache-creation tokens
}

export const MODEL_PRICING: Record<string, ModelPrice> = {
  'claude-opus-4-6':     { input: 15,   output: 75,  cacheRead: 1.5,   cacheWrite: 18.75 },
  'claude-sonnet-4-6':   { input: 3,    output: 15,  cacheRead: 0.3,   cacheWrite: 3.75 },
  'claude-sonnet-4-5':   { input: 3,    output: 15,  cacheRead: 0.3,   cacheWrite: 3.75 },
  'claude-haiku-4-5':    { input: 0.8,  output: 4,   cacheRead: 0.08,  cacheWrite: 1 },
  'gpt-4o':              { input: 2.5,  output: 10,  cacheRead: 1.25,  cacheWrite: 2.5 },
  'gpt-4o-mini':         { input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0.15 },
  'gpt-4.1':             { input: 2,    output: 8,   cacheRead: 0.5,   cacheWrite: 2 },
  'o3-mini':             { input: 1.1,  output: 4.4, cacheRead: 0.55,  cacheWrite: 1.1 },
  'o4-mini':             { input: 1.1,  output: 4.4, cacheRead: 0.55,  cacheWrite: 1.1 },
  'gemini-2.0-flash':    { input: 0.1,  output: 0.4, cacheRead: 0.025, cacheWrite: 0.1 },
  'gemini-2.5-pro':      { input: 1.25, output: 10,  cacheRead: 0.31,  cacheWrite: 1.25 },
}

/**
 * Find pricing for a model. Tries exact match first, then prefix match.
 * Custom pricing takes precedence.
 */
export function getModelPrice(model: string, customPricing?: Record<string, ModelPrice>): ModelPrice | undefined {
  // Custom pricing first
  if (customPricing?.[model]) return customPricing[model]

  // Exact match
  if (MODEL_PRICING[model]) return MODEL_PRICING[model]

  // Prefix match (e.g. 'claude-sonnet-4-5-20250929' → 'claude-sonnet-4-5')
  for (const [key, price] of Object.entries(MODEL_PRICING)) {
    if (model.startsWith(key)) return price
  }

  // Custom pricing prefix match
  if (customPricing) {
    for (const [key, price] of Object.entries(customPricing)) {
      if (model.startsWith(key)) return price
    }
  }

  return undefined
}

/**
 * Compute cost in USD for a session's token usage.
 * Returns 0 for unknown models (logs warning).
 */
export function computeCost(
  model: string,
  inputTokens: number,
  outputTokens: number,
  cacheReadTokens: number,
  cacheCreationTokens: number,
  customPricing?: Record<string, ModelPrice>,
): number {
  const price = getModelPrice(model, customPricing)
  if (!price) return 0

  const M = 1_000_000
  return (
    (inputTokens / M) * price.input +
    (outputTokens / M) * price.output +
    (cacheReadTokens / M) * price.cacheRead +
    (cacheCreationTokens / M) * price.cacheWrite
  )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/core/pricing.test.ts`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add src/core/pricing.ts tests/core/pricing.test.ts
git commit -m "feat: add model pricing table and cost computation"
```

---

### Task 5: DB Migration — session_costs + session_tools Tables

**Files:**
- Modify: `src/core/db.ts:81-102` (migration section)
- Test: Verified by Task 6+ integration tests

- [ ] **Step 1: Add session_costs table creation**

In `src/core/db.ts`, inside the `migrate()` method, after the existing `CREATE TABLE IF NOT EXISTS` blocks (around line 220, after usage_snapshots), add:

```typescript
// session_costs — token usage and cost per session (separate from snapshot write path)
this.db.exec(`
  CREATE TABLE IF NOT EXISTS session_costs (
    session_id TEXT PRIMARY KEY,
    model TEXT,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cache_read_tokens INTEGER DEFAULT 0,
    cache_creation_tokens INTEGER DEFAULT 0,
    cost_usd REAL DEFAULT 0,
    computed_at TEXT,
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
  )
`)
```

- [ ] **Step 2: Add session_tools table creation**

Immediately after session_costs:

```typescript
// session_tools — tool call counts per session
this.db.exec(`
  CREATE TABLE IF NOT EXISTS session_tools (
    session_id TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    call_count INTEGER DEFAULT 0,
    PRIMARY KEY (session_id, tool_name),
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
  )
`)
this.db.exec('CREATE INDEX IF NOT EXISTS idx_session_tools_name ON session_tools(tool_name)')
```

- [ ] **Step 3: Add DB helper methods**

Add methods to the Database class for reading/writing costs and tools:

```typescript
upsertSessionCost(sessionId: string, model: string, inputTokens: number, outputTokens: number, cacheReadTokens: number, cacheCreationTokens: number, costUsd: number): void {
  this.db.prepare(`
    INSERT OR REPLACE INTO session_costs (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, computed_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
  `).run(sessionId, model, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, costUsd)
}

upsertSessionTools(sessionId: string, tools: Map<string, number>): void {
  const stmt = this.db.prepare(`INSERT OR REPLACE INTO session_tools (session_id, tool_name, call_count) VALUES (?, ?, ?)`)
  const runMany = this.db.transaction((items: [string, string, number][]) => {
    for (const item of items) stmt.run(...item)
  })
  runMany([...tools.entries()].map(([name, count]) => [sessionId, name, count]))
}

getCostsSummary(params: { groupBy?: string; since?: string; until?: string }): any[] {
  let groupCol: string
  switch (params.groupBy) {
    case 'source': groupCol = 's.source'; break
    case 'project': groupCol = 's.project'; break
    case 'day': groupCol = "date(s.start_time)"; break
    default: groupCol = 'c.model'; break
  }
  let sql = `SELECT ${groupCol} as key, SUM(c.input_tokens) as inputTokens, SUM(c.output_tokens) as outputTokens, SUM(c.cost_usd) as costUsd, COUNT(*) as sessionCount FROM session_costs c JOIN sessions s ON c.session_id = s.id WHERE 1=1`
  const binds: any[] = []
  if (params.since) { sql += ' AND s.start_time >= ?'; binds.push(params.since) }
  if (params.until) { sql += ' AND s.start_time < ?'; binds.push(params.until) }
  sql += ` GROUP BY ${groupCol} ORDER BY costUsd DESC`
  return this.db.prepare(sql).all(...binds) as any[]
}

getToolAnalytics(params: { project?: string; since?: string; groupBy?: string }): any[] {
  let sql = `SELECT t.tool_name as name, SUM(t.call_count) as callCount, COUNT(DISTINCT t.session_id) as sessionCount FROM session_tools t JOIN sessions s ON t.session_id = s.id WHERE 1=1`
  const binds: any[] = []
  if (params.project) { sql += ' AND s.project LIKE ?'; binds.push(`%${params.project}%`) }
  if (params.since) { sql += ' AND s.start_time >= ?'; binds.push(params.since) }
  sql += ' GROUP BY t.tool_name ORDER BY callCount DESC'
  return this.db.prepare(sql).all(...binds) as any[]
}

sessionsWithoutCosts(limit = 100): string[] {
  return (this.db.prepare(`SELECT s.id FROM sessions s LEFT JOIN session_costs c ON s.id = c.session_id WHERE c.session_id IS NULL AND (s.tier IS NULL OR s.tier != 'skip') LIMIT ?`).all(limit) as { id: string }[]).map(r => r.id)
}

sessionsWithoutTools(limit = 100): string[] {
  return (this.db.prepare(`SELECT s.id FROM sessions s LEFT JOIN session_tools t ON s.id = t.session_id WHERE t.session_id IS NULL AND (s.tier IS NULL OR s.tier != 'skip') LIMIT ?`).all(limit) as { id: string }[]).map(r => r.id)
}
```

- [ ] **Step 4: Verify build**

Run: `npm run build`
Expected: Clean compile.

- [ ] **Step 5: Run existing tests**

Run: `npm test`
Expected: All 278+ tests pass (migration runs on test DBs, new tables created but unused).

- [ ] **Step 6: Commit**

```bash
git add src/core/db.ts
git commit -m "feat: add session_costs and session_tools tables with query helpers"
```

---

### Task 6: Update Indexer to Accumulate Tokens and Tools

**Files:**
- Modify: `src/core/indexer.ts:148-175` (message accumulation loop)

- [ ] **Step 1: Import pricing module**

At the top of `src/core/indexer.ts`:
```typescript
import { computeCost } from './pricing.js'
import type { TokenUsage, ToolCall } from '../adapters/types.js'
```

- [ ] **Step 2: Add token/tool accumulation in indexFile()**

In `indexFile()` (lines ~204-240) and `indexAll()` (lines ~148-175), where messages are streamed and accumulated, add:

```typescript
// Before the message loop, initialize accumulators:
let totalInputTokens = 0
let totalOutputTokens = 0
let totalCacheReadTokens = 0
let totalCacheCreationTokens = 0
const toolCounts = new Map<string, number>()
let sessionModel = ''

// Inside the message loop, after existing processing:
if (msg.usage) {
  totalInputTokens += msg.usage.inputTokens
  totalOutputTokens += msg.usage.outputTokens
  totalCacheReadTokens += msg.usage.cacheReadTokens ?? 0
  totalCacheCreationTokens += msg.usage.cacheCreationTokens ?? 0
}
if (msg.toolCalls) {
  for (const tc of msg.toolCalls) {
    toolCounts.set(tc.name, (toolCounts.get(tc.name) || 0) + 1)
  }
}

// After the message loop, after writing the snapshot:
// Write cost data (only if we have token data)
if (totalInputTokens > 0 || totalOutputTokens > 0) {
  const model = info.model || sessionModel || ''
  const cost = computeCost(model, totalInputTokens, totalOutputTokens, totalCacheReadTokens, totalCacheCreationTokens)
  this.db.upsertSessionCost(info.id, model, totalInputTokens, totalOutputTokens, totalCacheReadTokens, totalCacheCreationTokens, cost)
}

// Write tool data
if (toolCounts.size > 0) {
  this.db.upsertSessionTools(info.id, toolCounts)
}
```

Apply this pattern to both `indexFile()` and the inner loop of `indexAll()`. Extract a helper method if needed to avoid duplication:

```typescript
private writeExtractedData(sessionId: string, model: string, inputTokens: number, outputTokens: number, cacheReadTokens: number, cacheCreationTokens: number, toolCounts: Map<string, number>): void {
  if (inputTokens > 0 || outputTokens > 0) {
    const cost = computeCost(model, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)
    this.db.upsertSessionCost(sessionId, model, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, cost)
  }
  if (toolCounts.size > 0) {
    this.db.upsertSessionTools(sessionId, toolCounts)
  }
}
```

- [ ] **Step 3: Add backfill methods**

Add to `Indexer` class:

```typescript
async backfillCosts(): Promise<number> {
  const ids = this.db.sessionsWithoutCosts()
  let count = 0
  for (const id of ids) {
    const session = this.db.getSession(id)
    if (!session?.filePath) continue
    const adapter = this.adapters.find(a => a.name === session.source)
    if (!adapter) continue
    try {
      let inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, cacheCreationTokens = 0
      const toolCounts = new Map<string, number>()
      for await (const msg of adapter.streamMessages(session.filePath)) {
        if (msg.usage) {
          inputTokens += msg.usage.inputTokens
          outputTokens += msg.usage.outputTokens
          cacheReadTokens += msg.usage.cacheReadTokens ?? 0
          cacheCreationTokens += msg.usage.cacheCreationTokens ?? 0
        }
        if (msg.toolCalls) {
          for (const tc of msg.toolCalls) {
            toolCounts.set(tc.name, (toolCounts.get(tc.name) || 0) + 1)
          }
        }
      }
      this.writeExtractedData(id, session.model || '', inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, toolCounts)
      count++
    } catch { /* skip failed sessions */ }
  }
  return count
}
```

Uses `this.adapters` (passed via constructor) — no new imports needed.

Note: `backfillCosts()` handles BOTH costs and tools in one pass (the streaming loop extracts both). There is no separate `backfillToolAnalytics()` — the `sessionsWithoutCosts()` query drives the backfill, and both `session_costs` and `session_tools` are written for each session.

- [ ] **Step 4: Verify build**

Run: `npm run build`
Expected: Clean compile.

- [ ] **Step 5: Commit**

```bash
git add src/core/indexer.ts
git commit -m "feat: accumulate token usage and tool calls during indexing"
```

---

### Task 7: Create get_costs MCP Tool

**Files:**
- Create: `src/tools/get_costs.ts`
- Create: `tests/tools/get_costs.test.ts`

- [ ] **Step 1: Write failing test**

Create `tests/tools/get_costs.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { resolve } from 'path'
import { Database } from '../../src/core/db.js'

describe('get_costs', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
    // Insert a test session
    db.getRawDb().exec(`INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('s1', 'claude-code', '2026-03-20T10:00:00Z', '/test', 'test-project', 'claude-sonnet-4-6', 10, 3, 5, 1, 1, '/test/s1.jsonl', 1000, 'normal')`)
    db.getRawDb().exec(`INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('s2', 'claude-code', '2026-03-20T11:00:00Z', '/test', 'test-project', 'claude-opus-4-6', 20, 8, 10, 1, 1, '/test/s2.jsonl', 2000, 'normal')`)
    // Insert cost data
    db.upsertSessionCost('s1', 'claude-sonnet-4-6', 100000, 5000, 50000, 10000, 0.42)
    db.upsertSessionCost('s2', 'claude-opus-4-6', 200000, 10000, 100000, 20000, 4.65)
  })

  it('returns cost summary grouped by model', () => {
    const result = db.getCostsSummary({ groupBy: 'model' })
    expect(result.length).toBe(2)
    expect(result[0].key).toBe('claude-opus-4-6') // higher cost first
    expect(result[0].costUsd).toBeCloseTo(4.65, 1)
  })

  it('returns cost summary grouped by project', () => {
    const result = db.getCostsSummary({ groupBy: 'project' })
    expect(result.length).toBe(1)
    expect(result[0].key).toBe('test-project')
    expect(result[0].sessionCount).toBe(2)
  })

  it('filters by since', () => {
    const result = db.getCostsSummary({ since: '2026-03-20T10:30:00Z' })
    expect(result.length).toBe(1) // only s2
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/tools/get_costs.test.ts`
Expected: FAIL (or pass if DB helpers already work — then we're ahead).

- [ ] **Step 3: Create the MCP tool handler**

Create `src/tools/get_costs.ts`:

```typescript
import type { Database } from '../core/db.js'

export const getCostsTool = {
  name: 'get_costs',
  description: 'Get token usage costs across sessions, grouped by model, source, project, or day.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      group_by: { type: 'string', enum: ['model', 'source', 'project', 'day'], description: 'Group dimension (default: model)' },
      since: { type: 'string', description: 'Start time (ISO 8601)' },
      until: { type: 'string', description: 'End time (ISO 8601)' },
    },
    additionalProperties: false,
  },
}

export function handleGetCosts(db: Database, params: { group_by?: string; since?: string; until?: string }) {
  const breakdown = db.getCostsSummary({
    groupBy: params.group_by,
    since: params.since,
    until: params.until,
  })

  const totalCostUsd = breakdown.reduce((sum: number, r: any) => sum + (r.costUsd || 0), 0)
  const totalInputTokens = breakdown.reduce((sum: number, r: any) => sum + (r.inputTokens || 0), 0)
  const totalOutputTokens = breakdown.reduce((sum: number, r: any) => sum + (r.outputTokens || 0), 0)

  return {
    totalCostUsd: Math.round(totalCostUsd * 100) / 100,
    totalInputTokens,
    totalOutputTokens,
    breakdown,
  }
}
```

- [ ] **Step 4: Run tests**

Run: `npm test -- tests/tools/get_costs.test.ts`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add src/tools/get_costs.ts tests/tools/get_costs.test.ts
git commit -m "feat: add get_costs MCP tool for token usage cost tracking"
```

---

### Task 8: Create tool_analytics MCP Tool

**Files:**
- Create: `src/tools/tool_analytics.ts`
- Create: `tests/tools/tool_analytics.test.ts`

- [ ] **Step 1: Write failing test**

Create `tests/tools/tool_analytics.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'

describe('tool_analytics', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
    // Insert test sessions
    db.getRawDb().exec(`INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('s1', 'claude-code', '2026-03-20T10:00:00Z', '/test', 'my-project', 'claude-sonnet-4-6', 10, 3, 5, 1, 1, '/test/s1.jsonl', 1000, 'normal')`)
    // Insert tool data
    db.upsertSessionTools('s1', new Map([['Read', 15], ['Edit', 8], ['Bash', 12], ['Write', 3]]))
  })

  it('returns tool usage sorted by call count', () => {
    const result = db.getToolAnalytics({})
    expect(result.length).toBe(4)
    expect(result[0].name).toBe('Read')
    expect(result[0].callCount).toBe(15)
    expect(result[1].name).toBe('Bash')
  })

  it('filters by project', () => {
    const result = db.getToolAnalytics({ project: 'my-project' })
    expect(result.length).toBe(4)
  })

  it('filters by project with no match', () => {
    const result = db.getToolAnalytics({ project: 'nonexistent' })
    expect(result.length).toBe(0)
  })
})
```

- [ ] **Step 2: Run test to verify**

Run: `npm test -- tests/tools/tool_analytics.test.ts`
Expected: Pass (DB helpers from Task 5 should work).

- [ ] **Step 3: Create the MCP tool handler**

Create `src/tools/tool_analytics.ts`:

```typescript
import type { Database } from '../core/db.js'

export const toolAnalyticsTool = {
  name: 'tool_analytics',
  description: 'Analyze which tools (Read, Edit, Bash, etc.) are used most across sessions.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      project: { type: 'string', description: 'Filter by project name (partial match)' },
      since: { type: 'string', description: 'Start time (ISO 8601)' },
      group_by: { type: 'string', enum: ['tool', 'session', 'project'], description: 'Group dimension (default: tool)' },
    },
    additionalProperties: false,
  },
}

export function handleToolAnalytics(db: Database, params: { project?: string; since?: string; group_by?: string }) {
  const tools = db.getToolAnalytics({
    project: params.project,
    since: params.since,
    groupBy: params.group_by,
  })

  const totalCalls = tools.reduce((sum: number, t: any) => sum + (t.callCount || 0), 0)
  const uniqueTools = tools.length

  return { tools, totalCalls, uniqueTools }
}
```

- [ ] **Step 4: Run tests**

Run: `npm test -- tests/tools/tool_analytics.test.ts`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add src/tools/tool_analytics.ts tests/tools/tool_analytics.test.ts
git commit -m "feat: add tool_analytics MCP tool for tool usage analysis"
```

---

### Task 9: Register Tools in MCP Server + Add Web API Endpoints

**Files:**
- Modify: `src/index.ts:73-163`
- Modify: `src/web.ts:253+`
- Modify: `src/daemon.ts:70-99`

- [ ] **Step 1: Register MCP tools in index.ts**

In `src/index.ts`, import the new tools:
```typescript
import { getCostsTool, handleGetCosts } from './tools/get_costs.js'
import { toolAnalyticsTool, handleToolAnalytics } from './tools/tool_analytics.js'
```

Add to the `allTools` array (around line 73-85):
```typescript
getCostsTool,
toolAnalyticsTool,
```

Add to the if-else chain in CallToolRequestSchema handler (around line 106-157):
```typescript
} else if (name === 'get_costs') {
  result = handleGetCosts(db, a as any)
} else if (name === 'tool_analytics') {
  result = handleToolAnalytics(db, a as any)
}
```

- [ ] **Step 2: Add Web API endpoints in web.ts**

In `src/web.ts`, after the stats endpoint, add:

```typescript
// Cost tracking API
app.get('/api/costs', (c) => {
  const group_by = c.req.query('group_by')
  const since = c.req.query('since')
  const until = c.req.query('until')
  const result = handleGetCosts(db, { group_by, since, until })
  return c.json(result)
})

app.get('/api/costs/sessions', (c) => {
  const limit = parseInt(c.req.query('limit') || '20')
  const rows = db.getRawDb().prepare(`
    SELECT c.*, s.source, s.project, s.start_time, s.summary
    FROM session_costs c JOIN sessions s ON c.session_id = s.id
    ORDER BY c.cost_usd DESC LIMIT ?
  `).all(limit)
  return c.json({ sessions: rows })
})

// Tool analytics API
app.get('/api/tool-analytics', (c) => {
  const project = c.req.query('project')
  const since = c.req.query('since')
  const result = handleToolAnalytics(db, { project, since })
  return c.json(result)
})
```

Import `handleGetCosts` and `handleToolAnalytics` at the top.

- [ ] **Step 3: Add backfill calls in daemon.ts**

In `src/daemon.ts`, after the existing backfill calls (around line 70-99, after `indexer.backfillCounts()`):

```typescript
const costBackfilled = await indexer.backfillCosts()
if (costBackfilled > 0) emit({ event: 'backfill', type: 'costs', count: costBackfilled })
```

- [ ] **Step 4: Build and verify**

Run: `npm run build`
Expected: Clean compile.

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass (new + existing).

- [ ] **Step 6: Commit**

```bash
git add src/index.ts src/web.ts src/daemon.ts
git commit -m "feat: register get_costs and tool_analytics in MCP server and Web API"
```

---

### Task 10: Integration Test — End-to-End Indexing with Costs

**Files:**
- Create: `tests/integration/cost-indexing.test.ts`

- [ ] **Step 1: Write integration test**

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { resolve } from 'path'
import { Database } from '../../src/core/db.js'
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js'

const FIXTURE = resolve(__dirname, '../fixtures/claude-code/session-with-usage.jsonl')

describe('cost indexing integration', () => {
  let db: Database
  const adapter = new ClaudeCodeAdapter()

  beforeAll(async () => {
    db = new Database(':memory:')

    // Parse and index the fixture
    const info = await adapter.parseSessionInfo(FIXTURE)
    expect(info).toBeDefined()

    // Insert session
    db.getRawDb().prepare(`INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
      info!.id, info!.source, info!.startTime, info!.cwd, info!.project || '', info!.model || '', info!.messageCount, info!.userMessageCount, info!.assistantMessageCount, info!.toolMessageCount, info!.systemMessageCount, FIXTURE, info!.sizeBytes, 'normal'
    )

    // Stream messages and accumulate
    let inputTokens = 0, outputTokens = 0, cacheRead = 0, cacheCreate = 0
    const toolCounts = new Map<string, number>()
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      if (msg.usage) {
        inputTokens += msg.usage.inputTokens
        outputTokens += msg.usage.outputTokens
        cacheRead += msg.usage.cacheReadTokens ?? 0
        cacheCreate += msg.usage.cacheCreationTokens ?? 0
      }
      if (msg.toolCalls) {
        for (const tc of msg.toolCalls) {
          toolCounts.set(tc.name, (toolCounts.get(tc.name) || 0) + 1)
        }
      }
    }

    // Write extracted data
    if (inputTokens > 0) {
      const { computeCost } = await import('../../src/core/pricing.js')
      const cost = computeCost(info!.model || '', inputTokens, outputTokens, cacheRead, cacheCreate)
      db.upsertSessionCost(info!.id, info!.model || '', inputTokens, outputTokens, cacheRead, cacheCreate, cost)
    }
    if (toolCounts.size > 0) {
      db.upsertSessionTools(info!.id, toolCounts)
    }
  })

  it('stores token costs in session_costs', () => {
    const costs = db.getCostsSummary({})
    expect(costs.length).toBe(1)
    expect(costs[0].inputTokens).toBe(3500)  // 1500 + 2000
    expect(costs[0].outputTokens).toBe(150)   // 50 + 100
    expect(costs[0].costUsd).toBeGreaterThan(0)
  })

  it('stores tool calls in session_tools', () => {
    const tools = db.getToolAnalytics({})
    expect(tools.length).toBe(2) // Read + Edit
    const readTool = tools.find((t: any) => t.name === 'Read')
    expect(readTool).toBeDefined()
    expect(readTool.callCount).toBe(1)
    const editTool = tools.find((t: any) => t.name === 'Edit')
    expect(editTool).toBeDefined()
    expect(editTool.callCount).toBe(1)
  })
})
```

- [ ] **Step 2: Run integration test**

Run: `npm test -- tests/integration/cost-indexing.test.ts`
Expected: All pass.

- [ ] **Step 3: Run full test suite**

Run: `npm test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/cost-indexing.test.ts
git commit -m "test: add end-to-end integration test for cost and tool indexing"
```

---

## Verification Checklist

After all tasks complete:

- [ ] `npm test` — all tests pass (all existing + ~15 new)
- [ ] `npm run build` — clean compile
- [ ] New MCP tools appear in `ListToolsRequestSchema` response: `get_costs`, `tool_analytics`
- [ ] `GET /api/costs?group_by=model` returns cost breakdown
- [ ] `GET /api/costs/sessions?limit=5` returns top sessions by cost
- [ ] `GET /api/tool-analytics` returns tool usage frequency
- [ ] Existing sessions backfilled on first daemon startup after migration
- [ ] Fixture `session-with-usage.jsonl` validates with `JSON.parse` on every line
