# SP3a: Structured Logging + Request ID + Tracing Expansion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add JSON structured logging to stderr, propagate request_id via AsyncLocalStorage across all entry points, expand tracing to all modules, and auto-filter PII from log output.

**Architecture:** AsyncLocalStorage provides implicit request context propagation. Logger dual-writes to SQLite (UI) + stderr JSON (external aggregation). PII sanitizer runs once per log entry before dispatch. Tracer auto-inherits requestId from ALS. All changes are additive — existing behavior preserved.

**Tech Stack:** Node.js AsyncLocalStorage, Vitest, existing better-sqlite3 + Hono stack

**Spec:** `docs/superpowers/specs/2026-03-23-sp3a-structured-logging-design.md`

---

## File Map

### New files
| File | Responsibility |
|------|---------------|
| `src/core/request-context.ts` | AsyncLocalStorage wrapper: `runWithContext()`, `getRequestContext()`, `getRequestId()` |
| `src/core/sanitizer.ts` | PII auto-filtering: `sanitize()`, `applyPatterns()`, `sanitizeLogEntry()` |
| `tests/core/request-context.test.ts` | ALS propagation tests |
| `tests/core/sanitizer.test.ts` | PII pattern matching + false positive tests |
| `tests/integration/request-tracing.test.ts` | End-to-end request correlation tests |

### Modified files
| File | Changes |
|------|---------|
| `src/core/logger.ts` | Add `requestSource` to LogEntry, `stderrJson` to LoggerOpts, ALS auto-fill, `emitStderr()`, remove `ENGRAM_LOG_LEVEL` block |
| `src/core/tracer.ts` | Extract `SpanOpts` type, ALS fallback in `startSpan()`, add `withSpan()` + `withSpanSync()` |
| `src/index.ts` | Wrap handler in `runWithContext()`, wrap each tool in `withSpan()`, add `stderrJson: true` |
| `src/web.ts` | Add `tracer` to `createApp()` opts, replace trace middleware with `runWithContext()`, add tracing middleware |
| `src/daemon.ts` | Pass `tracer` to `createApp()`, wrap scheduler in `runWithContext()`, add `stderrJson: true` |
| `src/core/indexer.ts` | Import `runWithContext`, wrap per-file in `indexAll()` |
| `src/core/watcher.ts` | Import `runWithContext`, wrap `handleChange` |

---

### Task 1: Request Context (AsyncLocalStorage)

**Files:**
- Create: `src/core/request-context.ts`
- Test: `tests/core/request-context.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// tests/core/request-context.test.ts
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/core/request-context.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement request-context.ts**

```typescript
// src/core/request-context.ts
import { AsyncLocalStorage } from 'node:async_hooks'

export interface RequestContext {
  requestId: string
  spanId?: string
  source: 'mcp' | 'http' | 'indexer' | 'watcher' | 'scheduler'
}

const als = new AsyncLocalStorage<RequestContext>()

export function runWithContext<T>(ctx: RequestContext, fn: () => T): T {
  return als.run(ctx, fn)
}

export function getRequestContext(): RequestContext | undefined {
  return als.getStore()
}

export function getRequestId(): string | undefined {
  return als.getStore()?.requestId
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/core/request-context.test.ts`
Expected: 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/request-context.ts tests/core/request-context.test.ts
git commit -m "feat(observability): add AsyncLocalStorage request context"
```

---

### Task 2: PII Sanitizer

**Files:**
- Create: `src/core/sanitizer.ts`
- Test: `tests/core/sanitizer.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// tests/core/sanitizer.test.ts
import { describe, it, expect } from 'vitest'
import { sanitize, applyPatterns } from '../../src/core/sanitizer.js'

describe('applyPatterns', () => {
  it('redacts OpenAI API key', () => {
    expect(applyPatterns('key is sk-abcdefghijklmnopqrstuvwx')).toBe('key is sk-***')
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/core/sanitizer.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement sanitizer.ts**

```typescript
// src/core/sanitizer.ts
export const PII_PATTERNS: Array<{ name: string; regex: RegExp; replacement: string }> = [
  { name: 'openai_key',    regex: /sk-[a-zA-Z0-9]{20,}/g,             replacement: 'sk-***' },
  { name: 'anthropic_key', regex: /sk-ant-[a-zA-Z0-9-]{20,}/g,        replacement: 'sk-ant-***' },
  { name: 'bearer_token',  regex: /Bearer\s+[a-zA-Z0-9._\-]{10,}/gi,  replacement: 'Bearer ***' },
  { name: 'hex_secret',    regex: /((?:key|token|secret|password|apikey)[:=]\s*)[a-f0-9]{32,128}/gi, replacement: '$1***' },
  { name: 'email',         regex: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g, replacement: '***@***.***' },
]

export function sanitize(obj: Record<string, unknown>): Record<string, unknown> {
  return sanitizeValue(obj) as Record<string, unknown>
}

function sanitizeValue(value: unknown): unknown {
  if (typeof value === 'string') return applyPatterns(value)
  if (Array.isArray(value)) return value.map(sanitizeValue)
  if (value && typeof value === 'object') {
    const result: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(value)) {
      result[k] = sanitizeValue(v)
    }
    return result
  }
  return value
}

export function applyPatterns(str: string): string {
  let result = str
  for (const { regex, replacement } of PII_PATTERNS) {
    regex.lastIndex = 0
    result = result.replace(regex, replacement)
  }
  return result
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/core/sanitizer.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/sanitizer.ts tests/core/sanitizer.test.ts
git commit -m "feat(observability): add PII sanitizer with field-level regex"
```

---

### Task 3: Logger — ALS Integration + stderr JSON + PII Filtering

**Files:**
- Modify: `src/core/logger.ts`
- Test: `tests/core/logger.test.ts` (extend existing)

- [ ] **Step 1: Write failing tests for new logger behavior**

Append to `tests/core/logger.test.ts`. First update the import at line 2 to add `vi`:

```typescript
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
```

Then append the new test blocks:

```typescript
import { runWithContext } from '../../src/core/request-context.js'

describe('logger ALS integration', () => {
  let db: Database
  let writer: LogWriter
  beforeEach(() => { db = new Database(':memory:'); writer = new LogWriter(db.raw) })
  afterEach(() => { db.close() })

  it('auto-fills traceId from ALS request context', () => {
    const log = createLogger('test', { writer, level: 'info' })
    runWithContext({ requestId: 'req-abc', source: 'mcp' }, () => {
      log.info('hello')
    })
    const row = db.raw.prepare('SELECT trace_id FROM logs').get() as any
    expect(row.trace_id).toBe('req-abc')
  })

  it('child() explicit traceId overrides ALS', () => {
    const log = createLogger('test', { writer, level: 'info' })
    runWithContext({ requestId: 'als-id', source: 'http' }, () => {
      const child = log.child({ traceId: 'explicit-id' })
      child.info('from child')
    })
    const row = db.raw.prepare('SELECT trace_id FROM logs').get() as any
    expect(row.trace_id).toBe('explicit-id')
  })

  it('writes nothing to ALS when no context', () => {
    const log = createLogger('test', { writer, level: 'info' })
    log.info('no context')
    const row = db.raw.prepare('SELECT trace_id FROM logs').get() as any
    expect(row.trace_id).toBeNull()
  })
})

describe('logger stderr JSON', () => {
  let db: Database
  let writer: LogWriter
  let stderrOutput: string[]

  beforeEach(() => {
    db = new Database(':memory:')
    writer = new LogWriter(db.raw)
    stderrOutput = []
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: any) => {
      stderrOutput.push(chunk.toString())
      return true
    })
  })
  afterEach(() => {
    db.close()
    vi.restoreAllMocks()
  })

  it('emits JSON to stderr when stderrJson is true', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: true })
    log.info('test message', { count: 42 })
    expect(stderrOutput).toHaveLength(1)
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.level).toBe('info')
    expect(parsed.module).toBe('test')
    expect(parsed.message).toBe('test message')
    expect(parsed.data).toEqual({ count: 42 })
  })

  it('does NOT emit to stderr when stderrJson is false', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: false })
    log.info('quiet')
    expect(stderrOutput).toHaveLength(0)
  })

  it('includes request_id and request_source from ALS', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: true })
    runWithContext({ requestId: 'req-xyz', source: 'indexer' }, () => {
      log.info('with context')
    })
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.request_id).toBe('req-xyz')
    expect(parsed.request_source).toBe('indexer')
  })

  it('sanitizes PII in stderr output', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: true })
    log.info('key is sk-abcdefghijklmnopqrstuvwx')
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.message).toBe('key is sk-***')
  })

  it('sanitizes PII in SQLite output', () => {
    const log = createLogger('test', { writer, level: 'info' })
    log.info('email user@example.com')
    const row = db.raw.prepare('SELECT message FROM logs').get() as any
    expect(row.message).toBe('email ***@***.***')
  })

  it('does not emit debug to stderr when level is info', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: true })
    log.debug('should be skipped')
    expect(stderrOutput).toHaveLength(0)
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/core/logger.test.ts`
Expected: FAIL — new test cases reference features not yet implemented

- [ ] **Step 3: Modify logger.ts**

Changes to `src/core/logger.ts`:

1. Add imports at top:
```typescript
import { getRequestContext } from './request-context.js'
import { sanitize, applyPatterns } from './sanitizer.js'
```

2. Add `requestSource` to `LogEntry` interface — search for `source: 'daemon' | 'app'` in the interface, add after it:
```typescript
requestSource?: string
```

3. Add `stderrJson` to `LoggerOpts` interface — search for `spanId?: string` in `LoggerOpts`, add after it:
```typescript
stderrJson?: boolean
```

4. Add `sanitizeLogEntry` function — place it after the `LogWriter` class closing brace, before the `LoggerOpts` interface:
```typescript
function sanitizeLogEntry(entry: LogEntry): LogEntry {
  return {
    ...entry,
    message: applyPatterns(entry.message),
    data: entry.data ? sanitize(entry.data) as Record<string, unknown> : undefined,
    error: entry.error ? {
      ...entry.error,
      message: applyPatterns(entry.error.message ?? ''),
      stack: entry.error.stack ? applyPatterns(entry.error.stack) : undefined,
    } : undefined,
  }
}
```

5. Add `emitStderr` function (after `sanitizeLogEntry`):
```typescript
function emitStderr(entry: LogEntry): void {
  const output: Record<string, unknown> = {
    ts: entry.ts ?? new Date().toISOString(),
    level: entry.level,
    module: entry.module,
    request_id: entry.traceId ?? undefined,
    request_source: entry.requestSource ?? undefined,
    span_id: entry.spanId ?? undefined,
    source: entry.source,
    message: entry.message,
  }
  if (entry.data) output.data = entry.data
  if (entry.error) output.error = entry.error
  process.stderr.write(JSON.stringify(output) + '\n')
}
```

6. In `createLogger()`, capture `stderrJson`:
```typescript
const stderrJson = opts.stderrJson ?? true
```

7. Replace the `log()` function body — search for `function log(level: LogLevel` to locate it, replace the entire function:
```typescript
function log(level: LogLevel, message: string, data?: Record<string, unknown>, err?: unknown): void {
  if (!shouldLog(level)) return
  const ctx = getRequestContext()
  const entry: LogEntry = {
    level, module, message, source: 'daemon',
    traceId: opts.traceId ?? ctx?.requestId,
    spanId: opts.spanId ?? ctx?.spanId,
    requestSource: ctx?.source,
    data,
    error: err ? serializeError(err) : undefined,
  }
  const clean = sanitizeLogEntry(entry)
  writer?.write(clean)
  if (stderrJson) {
    emitStderr(clean)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/core/logger.test.ts`
Expected: All PASS (old + new tests)

- [ ] **Step 5: Commit**

```bash
git add src/core/logger.ts tests/core/logger.test.ts
git commit -m "feat(observability): add ALS auto-fill, stderr JSON, PII filtering to logger"
```

---

### Task 4: Tracer — ALS Fallback + withSpan Helpers

**Files:**
- Modify: `src/core/tracer.ts`
- Test: `tests/core/tracer.test.ts` (extend existing)

- [ ] **Step 1: Write failing tests**

Append to `tests/core/tracer.test.ts`:

```typescript
import { runWithContext } from '../../src/core/request-context.js'
import { withSpan, withSpanSync } from '../../src/core/tracer.js'

describe('Tracer ALS integration', () => {
  let db: Database
  let writer: TraceWriter
  let tracer: Tracer
  beforeEach(() => { db = new Database(':memory:'); writer = new TraceWriter(db.raw); tracer = new Tracer(writer) })
  afterEach(() => { db.close() })

  it('inherits traceId from ALS when no explicit opts', () => {
    runWithContext({ requestId: 'als-trace', source: 'mcp' }, () => {
      const span = tracer.startSpan('test.op', 'test')
      expect(span.traceId).toBe('als-trace')
      span.end()
    })
  })

  it('explicit traceId overrides ALS', () => {
    runWithContext({ requestId: 'als-id', source: 'http' }, () => {
      const span = tracer.startSpan('test.op', 'test', { traceId: 'explicit' })
      expect(span.traceId).toBe('explicit')
      span.end()
    })
  })

  it('multiple spans in same ALS context share traceId', () => {
    runWithContext({ requestId: 'shared', source: 'indexer' }, () => {
      const s1 = tracer.startSpan('op1', 'test')
      const s2 = tracer.startSpan('op2', 'test')
      expect(s1.traceId).toBe('shared')
      expect(s2.traceId).toBe('shared')
      s1.end()
      s2.end()
    })
  })
})

describe('withSpan', () => {
  let db: Database
  let writer: TraceWriter
  let tracer: Tracer
  beforeEach(() => { db = new Database(':memory:'); writer = new TraceWriter(db.raw); tracer = new Tracer(writer) })
  afterEach(() => { db.close() })

  it('records successful span with duration', async () => {
    const result = await withSpan(tracer, 'test.ok', 'test', async (span) => {
      span.setAttribute('key', 'val')
      return 42
    })
    expect(result).toBe(42)
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(row.status).toBe('ok')
    expect(row.duration_ms).toBeGreaterThanOrEqual(0)
    expect(JSON.parse(row.attributes).key).toBe('val')
  })

  it('records error span and re-throws', async () => {
    await expect(
      withSpan(tracer, 'test.fail', 'test', async () => { throw new Error('boom') })
    ).rejects.toThrow('boom')
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(row.status).toBe('error')
  })

  it('does not double-write span on error', async () => {
    await expect(
      withSpan(tracer, 'test.fail', 'test', async () => { throw new Error('x') })
    ).rejects.toThrow()
    const rows = db.raw.prepare('SELECT * FROM traces').all()
    expect(rows).toHaveLength(1)
  })
})

describe('withSpanSync', () => {
  let db: Database
  let writer: TraceWriter
  let tracer: Tracer
  beforeEach(() => { db = new Database(':memory:'); writer = new TraceWriter(db.raw); tracer = new Tracer(writer) })
  afterEach(() => { db.close() })

  it('records successful sync span', () => {
    const result = withSpanSync(tracer, 'sync.ok', 'test', (span) => {
      span.setAttribute('rows', 10)
      return 'done'
    })
    expect(result).toBe('done')
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(row.status).toBe('ok')
  })

  it('records error sync span and re-throws', () => {
    expect(() =>
      withSpanSync(tracer, 'sync.fail', 'test', () => { throw new Error('sync boom') })
    ).toThrow('sync boom')
    const row = db.raw.prepare('SELECT * FROM traces').get() as any
    expect(row.status).toBe('error')
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/core/tracer.test.ts`
Expected: FAIL — `withSpan` and `withSpanSync` not exported

- [ ] **Step 3: Modify tracer.ts**

Changes to `src/core/tracer.ts`:

1. Add import at top:
```typescript
import { getRequestContext } from './request-context.js'
```

2. Extract and export `SpanOpts` type (before `Tracer` class):
```typescript
export type SpanOpts = {
  parentSpan?: Span
  traceId?: string
  attributes?: Record<string, unknown>
}
```

3. In `Tracer.startSpan()`, replace the inline opts type with `SpanOpts` and add ALS fallback. Change line 63:
```typescript
// Before:
const traceId = opts?.traceId ?? opts?.parentSpan?.traceId ?? randomUUID()
// After:
const ctx = getRequestContext()
const traceId = opts?.traceId ?? opts?.parentSpan?.traceId ?? ctx?.requestId ?? randomUUID()
```

4. Add `withSpan` and `withSpanSync` after the `Tracer` class:

```typescript
export async function withSpan<T>(
  tracer: Tracer, name: string, module: string,
  fn: (span: Span) => Promise<T>, opts?: SpanOpts
): Promise<T> {
  const span = tracer.startSpan(name, module, opts)
  try {
    const result = await fn(span)
    span.end()
    return result
  } catch (err) {
    span.setError(err as Error)
    throw err
  }
}

export function withSpanSync<T>(
  tracer: Tracer, name: string, module: string,
  fn: (span: Span) => T, opts?: SpanOpts
): T {
  const span = tracer.startSpan(name, module, opts)
  try {
    const result = fn(span)
    span.end()
    return result
  } catch (err) {
    span.setError(err as Error)
    throw err
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/core/tracer.test.ts`
Expected: All PASS (old + new tests)

- [ ] **Step 5: Commit**

```bash
git add src/core/tracer.ts tests/core/tracer.test.ts
git commit -m "feat(observability): add ALS fallback + withSpan/withSpanSync to tracer"
```

---

### Task 5: MCP Server — runWithContext + withSpan for All Tools

**Files:**
- Modify: `src/index.ts`

- [ ] **Step 1: Add imports**

Add at top of `src/index.ts`:
```typescript
import { randomUUID } from 'crypto'
import { runWithContext } from './core/request-context.js'
import { withSpan } from './core/tracer.js'
```

- [ ] **Step 2: Enable stderrJson on MCP logger**

Change line 39:
```typescript
// Before:
const log = createLogger('mcp')
// After:
const log = createLogger('mcp', { stderrJson: true })
```

- [ ] **Step 3: Wrap handler in runWithContext + add span per tool call (surgical edits)**

This step modifies the existing handler incrementally — do NOT replace the entire block. Make these changes:

**3a)** Wrap the handler body in `runWithContext`. After `heartbeat()` on line 128, before the existing `try`:

```typescript
// Add after: heartbeat()
const requestId = randomUUID()
return runWithContext({ requestId, source: 'mcp' }, async () => {
  // ... existing try/catch block stays here, indented one level deeper
})
// Close the runWithContext at the end of the handler, after the catch block
```

**3b)** Add a tool-level span that wraps the entire `try` block (inside `runWithContext`). Use manual span management (not `withSpan`) to distinguish validation errors from real failures:

```typescript
// Inside runWithContext, replace the existing try/catch with:
const span = tracer.startSpan(`tool.${name}`, 'mcp')
try {
  let result: unknown

  // ... all existing if/else branches stay as-is, no changes to individual tools ...

  span.end()  // status: ok
  return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] }
} catch (err) {
  span.setError(err as Error)  // Real system error → error span
  return { content: [{ type: 'text', text: `Error: ${String(err)}` }], isError: true }
}
```

**3c)** For the existing early-return validation errors (e.g., `if (!session) return { ..., isError: true }`), these are NOT thrown — they return normally. The span will end as `status: 'ok'` because the code path reaches `span.end()` before the early return. To handle this correctly, add `span.end()` before each early return. For example:

```typescript
// Before:
if (!session) return { content: [{ type: 'text', text: `Session not found: ${a.id}` }], isError: true }

// After:
if (!session) { span.setAttribute('tool_error', 'session_not_found'); span.end(); return { content: [{ type: 'text', text: `Session not found: ${a.id}` }], isError: true } }
```

Apply the same pattern to all early-return validation errors in the handler (there are ~6 of them: session not found ×2, unsupported source ×2, cwd required, old_project/new_project required ×2, unknown action).

**Why not `withSpan`:** `withSpan` calls `setError()` on any thrown exception. Validation errors (like "session not found") are normal business logic, not system failures. Recording them as error spans pollutes the error signal. Using manual span management lets us end validation-error spans as `status: 'ok'` with a `tool_error` attribute for filtering, while real exceptions get `status: 'error'`.

- [ ] **Step 4: Build and run existing tests**

Run: `npm run build && npm test`
Expected: Build succeeds, all existing tests pass

- [ ] **Step 5: Commit**

```bash
git add src/index.ts
git commit -m "feat(observability): add runWithContext + withSpan to MCP tool handlers"
```

---

### Task 6: Web API — runWithContext + Tracing Middleware

**Files:**
- Modify: `src/web.ts`

- [ ] **Step 1: Add imports and extend createApp opts**

Add import at top of `src/web.ts`:
```typescript
import { runWithContext } from './core/request-context.js'
import { withSpan, type Tracer } from './core/tracer.js'
```

Add `tracer` to `createApp()` options interface (after `metrics?: MetricsCollector` at line 84):
```typescript
tracer?: Tracer
```

- [ ] **Step 2: Replace trace propagation middleware with runWithContext**

Replace lines 136-142 (the existing trace middleware):
```typescript
// Before:
app.use('*', async (c, next) => {
  const traceId = c.req.header('x-trace-id') ?? randomUUID()
  c.set('traceId', traceId)
  c.header('X-Trace-Id', traceId)
  await next()
})

// After:
app.use('*', async (c, next) => {
  const requestId = c.req.header('x-trace-id') ?? randomUUID()
  c.set('traceId', requestId)
  c.header('X-Trace-Id', requestId)
  return runWithContext({ requestId, source: 'http' }, () => next())
})
```

- [ ] **Step 3: Add tracing middleware after request context middleware**

Insert after the updated trace middleware (before metrics middleware):
```typescript
// Request tracing — creates a span for every HTTP request
if (opts?.tracer) {
  const tracerRef = opts.tracer
  app.use('*', async (c, next) => {
    const pathPrefix = c.req.path.split('/').slice(0, 3).join('/')
    await withSpan(tracerRef, `http.${c.req.method}.${pathPrefix}`, 'http', async (span) => {
      await next()
      span.setAttribute('status', c.res.status)
    })
  })
}
```

- [ ] **Step 4: Build and verify**

Run: `npm run build && npm test`
Expected: Build succeeds, all tests pass

- [ ] **Step 5: Commit**

```bash
git add src/web.ts
git commit -m "feat(observability): add runWithContext + tracing middleware to web API"
```

---

### Task 7: Daemon — Pass Tracer + Scheduler Context + stderrJson

**Files:**
- Modify: `src/daemon.ts`

- [ ] **Step 1: Add imports**

Add at top of `src/daemon.ts`:
```typescript
import { runWithContext } from './core/request-context.js'
import { randomUUID } from 'crypto'
```

(`randomUUID` may already be imported — check first.)

- [ ] **Step 2: Enable stderrJson on daemon logger**

Change line 58:
```typescript
// Before:
const log = createLogger('daemon', { writer: logWriter, level: settings.observability?.logLevel ?? 'info' })
// After:
const log = createLogger('daemon', { writer: logWriter, level: settings.observability?.logLevel ?? 'info', stderrJson: true })
```

- [ ] **Step 3: Pass tracer to createApp**

Change `createApp()` call (around line 333), add `tracer`:
```typescript
const app = createApp(db, {
  vectorStore: vecDeps?.vectorStore,
  embeddingClient: vecDeps?.embeddingClient,
  syncEngine,
  syncPeers,
  settings,
  adapters,
  viking: vikingBridge,
  usageCollector,
  titleGenerator,
  liveMonitor,
  backgroundMonitor,
  logWriter,
  metrics,
  tracer,    // NEW
})
```

- [ ] **Step 4: Wrap rescan timer in runWithContext**

Change the `rescanTimer` setInterval callback (lines 285-298):
```typescript
const rescanTimer = setInterval(async () => {
  await runWithContext({ requestId: randomUUID(), source: 'scheduler' }, async () => {
    try {
      const indexed = nonWatchable.size > 0
        ? await indexer.indexAll({ sources: nonWatchable })
        : 0
      if (indexed > 0) {
        const total = db.countSessions()
        emit({ event: 'rescan', indexed, total })
        indexJobRunner.runRecoverableJobs().catch(() => {})
      }
    } catch (err) {
      log.warn('periodic rescan failed', {}, err)
    }
  })
}, RESCAN_INTERVAL)
```

- [ ] **Step 5: Wrap log rotation timer in runWithContext**

Change the `logRotationTimer` callback (lines 367-377):
```typescript
const logRotationTimer = setInterval(() => {
  runWithContext({ requestId: randomUUID(), source: 'scheduler' }, () => {
    const retentionDays = settings.observability?.logRetentionDays ?? 7
    logWriter.rotate(retentionDays)
    logWriter.enforceMaxRows(100_000)
    db.raw.prepare("DELETE FROM traces WHERE start_ts < ?").run(
      new Date(Date.now() - retentionDays * 86400000).toISOString()
    )
    db.raw.prepare("DELETE FROM metrics WHERE ts < ?").run(
      new Date(Date.now() - 24 * 3600000).toISOString()
    )
  })
}, 3600000)
```

- [ ] **Step 6: Build and verify**

Run: `npm run build && npm test`
Expected: All pass

- [ ] **Step 7: Commit**

```bash
git add src/daemon.ts
git commit -m "feat(observability): add stderrJson, tracer passthrough, scheduler context to daemon"
```

---

### Task 8: Indexer + Watcher — Per-File ALS Context

**Files:**
- Modify: `src/core/indexer.ts`
- Modify: `src/core/watcher.ts`

- [ ] **Step 1: Add import to indexer.ts**

In `src/core/indexer.ts`, add `randomUUID` to the existing crypto import on line 2:
```typescript
import { createHash, randomUUID } from 'crypto'
```

Add new import:
```typescript
import { runWithContext } from './request-context.js'
```

- [ ] **Step 2: Wrap per-file processing in indexAll() with runWithContext**

In `indexAll()` method (around line 208), wrap the per-file try block:

```typescript
// Before:
for await (const filePath of adapter.listSessionFiles()) {
  try {
    // ... file processing ...
  } catch (err) {
    this.log?.warn('skipping unprocessable file', { filePath }, err)
  }
}

// After:
for await (const filePath of adapter.listSessionFiles()) {
  await runWithContext({ requestId: randomUUID(), source: 'indexer' }, async () => {
    try {
      // ... file processing (unchanged) ...
    } catch (err) {
      this.log?.warn('skipping unprocessable file', { filePath }, err)
    }
  })
}
```

- [ ] **Step 3: indexFile() — no changes needed**

`indexFile()` does NOT get its own `runWithContext` — it inherits from the caller. When called from the watcher (`source: 'watcher'`), it shares the watcher's requestId. When called from `indexAll()` (`source: 'indexer'`), it shares the per-file requestId. The existing `indexer.indexFile` span inside the method will auto-inherit traceId from ALS.

- [ ] **Step 4: Add import to watcher.ts and wrap handleChange**

Add at top of `src/core/watcher.ts`:
```typescript
import { runWithContext } from './request-context.js'
import { randomUUID } from 'crypto'
```

Wrap `handleChange` body (lines 55-65):
```typescript
const handleChange = async (filePath: string) => {
  await runWithContext({ requestId: randomUUID(), source: 'watcher' }, async () => {
    for (const [watchPath, adapter] of Object.entries(watchMap)) {
      if (filePath.startsWith(watchPath)) {
        const result = await indexer.indexFile(adapter, filePath)
        if (result.indexed && result.sessionId) {
          opts?.onIndexed?.(result.sessionId, result.messageCount ?? 0, result.tier ?? 'normal')
        }
        break
      }
    }
  })
}
```

- [ ] **Step 5: Build and verify**

Run: `npm run build && npm test`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add src/core/indexer.ts src/core/watcher.ts
git commit -m "feat(observability): add per-file ALS context to indexer and watcher"
```

---

### Task 9: Integration Test — End-to-End Request Correlation

**Files:**
- Create: `tests/integration/request-tracing.test.ts`

- [ ] **Step 1: Write integration tests**

```typescript
// tests/integration/request-tracing.test.ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { Database } from '../../src/core/db.js'
import { LogWriter, createLogger } from '../../src/core/logger.js'
import { TraceWriter, Tracer, withSpan } from '../../src/core/tracer.js'
import { runWithContext, getRequestId } from '../../src/core/request-context.js'

describe('end-to-end request tracing', () => {
  let db: Database
  let logWriter: LogWriter
  let tracer: Tracer
  let stderrOutput: string[]

  beforeEach(() => {
    db = new Database(':memory:')
    logWriter = new LogWriter(db.raw)
    const traceWriter = new TraceWriter(db.raw)
    tracer = new Tracer(traceWriter)
    stderrOutput = []
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: any) => {
      stderrOutput.push(chunk.toString())
      return true
    })
  })
  afterEach(() => { db.close(); vi.restoreAllMocks() })

  it('correlates logs and traces within an MCP tool call', async () => {
    const log = createLogger('test', { writer: logWriter, level: 'info', stderrJson: true })

    await runWithContext({ requestId: 'mcp-req-1', source: 'mcp' }, async () => {
      log.info('tool invoked', { tool: 'search' })
      await withSpan(tracer, 'tool.search', 'mcp', async (span) => {
        span.setAttribute('query', 'test')
        log.info('search started')
      })
    })

    // Verify logs have matching trace_id
    const logs = db.raw.prepare('SELECT trace_id FROM logs').all() as any[]
    expect(logs).toHaveLength(2)
    expect(logs[0].trace_id).toBe('mcp-req-1')
    expect(logs[1].trace_id).toBe('mcp-req-1')

    // Verify trace has matching trace_id
    const traces = db.raw.prepare('SELECT trace_id FROM traces').all() as any[]
    expect(traces).toHaveLength(1)
    expect(traces[0].trace_id).toBe('mcp-req-1')

    // Verify stderr output
    expect(stderrOutput).toHaveLength(2)
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.request_id).toBe('mcp-req-1')
    expect(parsed.request_source).toBe('mcp')
  })

  it('PII is sanitized in both SQLite and stderr', async () => {
    const log = createLogger('test', { writer: logWriter, level: 'info', stderrJson: true })

    runWithContext({ requestId: 'pii-test', source: 'http' }, () => {
      log.info('user email: user@secret.com, key: sk-abcdefghijklmnopqrstuvwx')
    })

    // SQLite sanitized
    const row = db.raw.prepare('SELECT message FROM logs').get() as any
    expect(row.message).toContain('***@***.***')
    expect(row.message).toContain('sk-***')
    expect(row.message).not.toContain('user@secret.com')

    // stderr sanitized
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.message).toContain('***@***.***')
    expect(parsed.message).toContain('sk-***')
  })

  it('separate ALS contexts get different request_ids', async () => {
    const log = createLogger('test', { writer: logWriter, level: 'info' })

    await runWithContext({ requestId: 'req-A', source: 'indexer' }, async () => {
      log.info('file 1')
    })
    await runWithContext({ requestId: 'req-B', source: 'indexer' }, async () => {
      log.info('file 2')
    })

    const logs = db.raw.prepare('SELECT trace_id FROM logs ORDER BY id').all() as any[]
    expect(logs[0].trace_id).toBe('req-A')
    expect(logs[1].trace_id).toBe('req-B')
  })
})
```

- [ ] **Step 2: Run tests**

Run: `npx vitest run tests/integration/request-tracing.test.ts`
Expected: All PASS

- [ ] **Step 3: Commit**

```bash
git add tests/integration/request-tracing.test.ts
git commit -m "test(observability): add end-to-end request correlation integration tests"
```

---

### Deferred to follow-up

The following items from spec Section 3.3 are **not included** in this plan — they are mechanical once the foundation is in place and can be added incrementally:

- **Adapter-level spans** (`adapter.{name}.parse`, `adapter.{name}.stream` in `src/adapters/*.ts`)
- **DB query spans** (`db.{operation}` for critical-path queries)
- **Viking bridge spans** (`viking.find`, `viking.push`, `viking.embed`)

These follow the same `withSpan`/`withSpanSync` pattern established in Tasks 4-8.

---

### Task 10: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `npm test`
Expected: All tests pass (existing + new)

- [ ] **Step 2: Build check**

Run: `npm run build`
Expected: Clean build, no TypeScript errors

- [ ] **Step 3: Add performance benchmark test**

Append to `tests/core/logger.test.ts`:

```typescript
describe('logger performance', () => {
  it('sanitize + stderr write averages < 100μs per call', () => {
    const db = new Database(':memory:')
    const writer = new LogWriter(db.raw)
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockReturnValue(true)
    const log = createLogger('perf', { writer, level: 'info', stderrJson: true })

    const start = performance.now()
    for (let i = 0; i < 1000; i++) {
      log.info(`message ${i}`, { count: i, path: '/api/sessions' })
    }
    const elapsed = performance.now() - start
    const avgUs = (elapsed / 1000) * 1000  // ms to μs

    expect(avgUs).toBeLessThan(process.env.CI ? 500 : 100)
    stderrSpy.mockRestore()
    db.close()
  })
})
```

Run: `npx vitest run tests/core/logger.test.ts`
Expected: PASS

- [ ] **Step 4: Manual smoke test — daemon mode**

Run: `node dist/daemon.js 2>stderr.jsonl`
(stderr JSON is always-on — no env var needed)
Wait 5 seconds, then Ctrl+C. Check:
```bash
head -5 stderr.jsonl | jq .
```
Expected: Each line is valid JSON with `ts`, `level`, `module`, `message`, `request_id` (may be null for daemon startup logs before any ALS context).

- [ ] **Step 5: Commit benchmark test**

```bash
git add tests/core/logger.test.ts
git commit -m "test(observability): add performance benchmark for logger sanitize + stderr"
```

- [ ] **Step 6: Commit any fixes from smoke testing**

If fixes needed, commit them individually.

- [ ] **Step 7: Final commit — mark spec as implemented**

Update spec status from "Draft" to "Implemented":
```bash
sed -i '' 's/^**Status**: Draft/**Status**: Implemented/' docs/superpowers/specs/2026-03-23-sp3a-structured-logging-design.md
git add docs/superpowers/specs/2026-03-23-sp3a-structured-logging-design.md
git commit -m "docs: mark SP3a spec as implemented"
```
