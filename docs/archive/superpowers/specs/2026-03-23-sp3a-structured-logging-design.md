# SP3a: Structured Logging + Request ID + Tracing Expansion

**Date**: 2026-03-23
**Status**: Implemented
**Scope**: Gaps #1 (JSON stdout), #2 (request_id), #4 (tracing incomplete), #8 (PII filtering) from observability gap analysis

## Decisions

| Decision | Choice |
|----------|--------|
| Log output | Dual-write: SQLite (UI) + stderr JSON (external aggregation) |
| Output channel | stderr (stdout reserved for daemon events / MCP JSON-RPC) |
| request_id scope | Comprehensive: MCP tools, Web API, indexer, watcher, scheduler |
| Propagation model | AsyncLocalStorage (Node.js native, implicit propagation) |
| PII filtering | Write-layer auto-intercept (field-level regex) |
| JSON format | Flat metadata + nested `data` field |
| Enablement | Always-on; log level controlled by `settings.observability.logLevel` |
| MCP server stderr | Enabled (MCP SDK's StdioServerTransport uses stdout only; stderr is free) |

## 1. Request Context — AsyncLocalStorage

### New file: `src/core/request-context.ts`

```typescript
import { AsyncLocalStorage } from 'node:async_hooks'

interface RequestContext {
  requestId: string    // Correlation ID across entire request chain
  spanId?: string      // Current span (optional, for tracing)
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

### Entry point integration (3 sites)

**1) MCP tool call** (`src/index.ts`):
```typescript
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const requestId = randomUUID()
  return runWithContext({ requestId, source: 'mcp' }, async () => {
    // existing handler logic unchanged
  })
})
```

**2) HTTP request** (`src/web.ts`, replaces existing trace middleware):
```typescript
app.use('*', async (c, next) => {
  const requestId = c.req.header('x-trace-id') || randomUUID()
  c.set('traceId', requestId)
  c.header('X-Trace-Id', requestId)
  return runWithContext({ requestId, source: 'http' }, () => next())
})
```

**3a) Indexer** — context set **per-file** inside `Indexer.indexAll()` (not at daemon call site):

The existing `indexAll()` iterates adapters → files. Each file gets its own ALS context so that `request_id` is useful for filtering (one adapter may have hundreds of files):

```typescript
// Inside Indexer.indexAll():
for (const adapter of this.adapters) {
  if (opts?.sources && !opts.sources.has(adapter.name)) continue
  if (!await adapter.detect()) continue

  for await (const filePath of adapter.listSessionFiles()) {
    await runWithContext({ requestId: randomUUID(), source: 'indexer' }, async () => {
      // existing per-file processing (parseSessionInfo, streamMessages, etc.)
    })
  }
}
```

Per-file granularity means searching by `request_id` returns logs for exactly one session file — not hundreds of unrelated files from the same adapter.

`Indexer` already imports from `./tracer.js`; add import of `runWithContext` from `./request-context.js`.

Daemon call sites (`indexer.indexAll()`, `indexer.indexFile()`) remain unchanged.

**3b) Watcher** — context set inside `handleChange` in `src/core/watcher.ts`:

```typescript
// In startWatcher(), wrap handleChange body:
import { runWithContext } from './request-context.js'  // NEW import

const handleChange = async (filePath: string) => {
  await runWithContext({ requestId: randomUUID(), source: 'watcher' }, async () => {
    // existing body: find adapter, call indexer.indexFile()
  })
}
```

`indexer.indexFile()` already has an internal span (`indexer.indexFile`); the ALS context ensures that span auto-inherits the watcher's requestId.

**3c) Scheduled tasks** (`src/daemon.ts`) — wrap each execution:

```typescript
// rescan, rollup, rotation — each gets its own context
runWithContext({ requestId: randomUUID(), source: 'scheduler' }, () => rescan(...))
runWithContext({ requestId: randomUUID(), source: 'scheduler' }, () => rollup(...))
```

## 2. Logger Changes — stderr JSON + ALS Auto-Correlation

### Changes to `src/core/logger.ts`

**2.1 ALS auto-fill in log():**

The internal `log()` function (a closure inside `createLogger()`) reads requestId from ALS when the closure-captured `opts.traceId` is not set. Here `opts` refers to the `LoggerOpts` captured by the `createLogger()` closure, including any `traceId`/`spanId` set via `child()`:

```typescript
// Inside createLogger() closure:
function log(level, message, data?, err?) {
  if (!shouldLog(level)) return
  const ctx = getRequestContext()
  const entry: LogEntry = {
    level, module, message, source: 'daemon',
    traceId: opts.traceId ?? ctx?.requestId,       // child() traceId > ALS > undefined
    spanId: opts.spanId ?? ctx?.spanId,
    requestSource: ctx?.source,                     // Capture ALS source once, avoid re-reading in emitStderr
    data,
    error: err ? serializeError(err) : undefined,
  }
  const clean = sanitizeLogEntry(entry)    // Single sanitization pass
  writer?.write(clean)                     // SQLite
  if (stderrJson) {
    emitStderr(clean)                      // stderr JSON
  }
}
```

`child()` explicit traceId takes precedence over ALS (backward compatible).

The `LogEntry` interface gains one new optional field: `requestSource?: string` (captures `RequestContext.source` at log-time so `emitStderr` doesn't need to re-read ALS — safe even if emitted outside the original ALS scope).

**2.2 stderr JSON output (always-on in both daemon and MCP modes):**

New `stderrJson` option in `LoggerOpts`, defaulting to `true`:

```typescript
interface LoggerOpts {
  writer?: LogWriter
  level?: LogLevel
  rateLimitPerMin?: number
  traceId?: string
  spanId?: string
  stderrJson?: boolean  // NEW: default true (all callers get stderr JSON unless explicitly disabled)
}
```

Verified: MCP SDK's `StdioServerTransport` reads from stdin and writes to stdout only — it does not use stderr. Both daemon and MCP server can safely write structured JSON to stderr.

- `src/daemon.ts`: `createLogger('daemon', { ..., stderrJson: true })` (explicit)
- `src/index.ts`: `createLogger('mcp', { stderrJson: true })` (explicit — no LogWriter but stderr still useful for external aggregation)

**2.3 emitStderr() implementation:**

```typescript
function emitStderr(entry: LogEntry): void {
  const output: Record<string, unknown> = {
    ts: entry.ts ?? new Date().toISOString(),
    level: entry.level,
    module: entry.module,
    request_id: entry.traceId ?? undefined,          // Correlation ID
    request_source: entry.requestSource ?? undefined, // From LogEntry, not ALS (captured once in log())
    span_id: entry.spanId ?? undefined,
    source: entry.source,                             // Process origin: daemon/app
    message: entry.message,
  }
  if (entry.data) output.data = entry.data           // Nested, not flattened
  if (entry.error) output.error = entry.error         // Nested, fixed structure
  process.stderr.write(JSON.stringify(output) + '\n') // Already sanitized by caller
}
```

Key design choices:
- `data` stays **nested** (avoids field name conflicts, ELK/Datadog handle nested JSON fine)
- `traceId` renamed to `request_id` in output (external convention)
- `error` stays nested (`{name, message, stack, code}`)
- `sanitize()` applied before serialization (see Section 4)

**2.4 Remove `ENGRAM_LOG_LEVEL` conditional:**

Delete the `// Also write to stderr in dev mode` block that checks `process.env.ENGRAM_LOG_LEVEL` (currently at the end of the `log()` closure). Replaced by the always-on `stderrJson` mechanism.

**2.5 Reserved field set (stderr output):**

| Field | Type | Description |
|-------|------|-------------|
| `ts` | string | ISO 8601 |
| `level` | string | debug/info/warn/error |
| `module` | string | Source module |
| `request_id` | string? | ALS correlation ID |
| `request_source` | string? | Request origin: `mcp` / `http` / `indexer` / `watcher` / `scheduler` (from ALS `RequestContext.source`) |
| `span_id` | string? | Current span |
| `source` | string | Process origin: `daemon` / `app` (from `LogEntry.source` — distinct from `request_source`) |
| `message` | string | Log message |
| `data` | object? | Structured business data (nested) |
| `error` | object? | `{name, message, stack, code}` (nested) |

## 3. Tracing Expansion

### 3.1 Tracer reads ALS

`Tracer.startSpan()` falls back to ALS requestId when no explicit traceId/parentSpan:

The existing inline opts type is extracted as a named export for reuse:

```typescript
export type SpanOpts = {
  parentSpan?: Span
  traceId?: string
  attributes?: Record<string, unknown>
}

startSpan(name: string, module: string, opts?: SpanOpts): Span {
  const ctx = getRequestContext()
  const traceId = opts?.traceId ?? opts?.parentSpan?.traceId ?? ctx?.requestId ?? randomUUID()
  // rest unchanged
}
```

Same request → all spans auto-correlated. No parameter threading needed.

### 3.2 `withSpan` helper

New utility to eliminate try/catch boilerplate:

```typescript
// Added to src/core/tracer.ts
export async function withSpan<T>(
  tracer: Tracer,
  name: string,
  module: string,
  fn: (span: Span) => Promise<T>,
  opts?: SpanOpts
): Promise<T> {
  const span = tracer.startSpan(name, module, opts)
  try {
    const result = await fn(span)
    span.end()
    return result
  } catch (err) {
    span.setError(err as Error)  // setError already ends the span
    throw err
  }
}
```

Note: `span.end()` is NOT called after `setError()` — the existing `setError()` implementation sets `ended = true` and writes to DB. Calling `end()` after would be a no-op but is misleading.

Synchronous variant for DB queries and other sync operations:

```typescript
export function withSpanSync<T>(
  tracer: Tracer,
  name: string,
  module: string,
  fn: (span: Span) => T,
  opts?: SpanOpts
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

### 3.3 Modules to instrument

| Module | Span name pattern | Attributes |
|--------|-------------------|------------|
| **MCP tool handlers** (`src/index.ts`) | `tool.{name}` | tool name, params summary |
| **Web API routes** (`src/web.ts`) | `http.{method}.{path}` | method, path, status code |
| **Indexer** (`src/core/indexer.ts`) | `indexer.adapter` → `indexer.file` | adapter name, file path, batch size |
| **Adapter ops** (`src/adapters/*.ts`) | `adapter.{name}.parse`, `adapter.{name}.stream` | adapter name, file path |
| **Watcher** (`src/core/watcher.ts`) | `watcher.change` | event type, file path |
| **DB queries** (critical path) | `db.{operation}` | query type |
| **Viking bridge** (`src/core/viking-bridge.ts`) | `viking.find`, `viking.push`, `viking.embed` | endpoint, result count |
| **Scheduled tasks** (`src/daemon.ts`) | `scheduler.{task}` | task name |

### 3.4 MCP tool handler example

```typescript
// Before:
if (name === 'get_context') {
  result = await handleGetContext(db, args, { log })
}

// After:
if (name === 'get_context') {
  result = await withSpan(tracer, 'tool.get_context', 'mcp', async (span) => {
    span.setAttribute('cwd', a.cwd)
    return handleGetContext(db, a as {...}, { log, tracer })
  })
}
```

### 3.5 Web API tracing middleware

New middleware after request context middleware:

```typescript
app.use('*', async (c, next) => {
  if (!opts?.tracer) return next()
  // Truncate to 3 segments — consistent with existing metrics middleware (web.ts line 150)
  const pathPrefix = c.req.path.split('/').slice(0, 3).join('/')
  await withSpan(opts.tracer, `http.${c.req.method}.${pathPrefix}`, 'http', async (span) => {
    await next()
    span.setAttribute('status', c.res.status)
  })
})
```

### 3.6 Indexer granularity

ALS context per file, with the existing `indexer.indexSession` span inside:

```
for adapter in adapters:
  for file in adapter.listSessionFiles():
    runWithContext({ source: 'indexer' })       // per file — unique request_id
      └── existing indexer.indexSession span    // already in code (indexer.ts line 228)
           ├── adapter.parse (if instrumented)
           └── adapter.stream (if instrumented)
```

Each file gets its own `request_id`, so filtering by `request_id` in logs returns exactly the logs for processing one session file.

**Note on root span**: The existing `indexer.indexAll` span (indexer.ts line 200) is created **before** any per-file `runWithContext` call. At that point there is no ALS context, so the root span falls back to `randomUUID()` for its own traceId. This means the root span and per-file spans intentionally **do not** share a traceId — the root span tracks total `indexAll()` duration independently, while each file span has its own correlation chain. This is by design, not a bug.

### 3.7 Existing search.ts tracing

Unchanged. The existing `search` → `search.fts` / `search.vector` / `search.viking` hierarchy continues to work. The only difference: `traceId` now comes from ALS instead of being manually generated, so search spans automatically correlate with the parent MCP tool call or HTTP request.

## 4. PII Auto-Filtering

### New file: `src/core/sanitizer.ts`

**4.1 Field-level recursive sanitization:**

```typescript
const PII_PATTERNS: Array<{ name: string; regex: RegExp; replacement: string }> = [
  // API keys
  { name: 'openai_key',    regex: /sk-[a-zA-Z0-9]{20,}/g,             replacement: 'sk-***' },
  { name: 'anthropic_key', regex: /sk-ant-[a-zA-Z0-9-]{20,}/g,        replacement: 'sk-ant-***' },
  { name: 'bearer_token',  regex: /Bearer\s+[a-zA-Z0-9._\-]{10,}/gi,  replacement: 'Bearer ***' },
  // Generic secrets: capture the key label, redact the value
  // - Upper bound {128} prevents matching absurdly long hex (e.g. file contents)
  // - Separator restricted to [:=] (not spaces) to avoid "cache key: <commit hash>" false positives
  { name: 'hex_secret',    regex: /((?:key|token|secret|password|apikey)[:=]\s*)[a-f0-9]{32,128}/gi, replacement: '$1***' },
  // Email
  { name: 'email',         regex: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g, replacement: '***@***.***' },
]

export function sanitize(obj: Record<string, unknown>): Record<string, unknown> {
  return sanitizeValue(obj) as Record<string, unknown>
}

function sanitizeValue(value: unknown): unknown {
  if (typeof value === 'string') {
    return applyPatterns(value)
  }
  if (Array.isArray(value)) {
    return value.map(sanitizeValue)
  }
  if (value && typeof value === 'object') {
    const result: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(value)) {
      result[k] = sanitizeValue(v)
    }
    return result
  }
  return value
}

function applyPatterns(str: string): string {
  let result = str
  for (const { regex, replacement } of PII_PATTERNS) {
    regex.lastIndex = 0  // Reset stateful /g regex
    result = result.replace(regex, replacement)
  }
  return result
}
```

Key design choices vs. initial proposal:
- **Field-level recursion** instead of whole-JSON-string regex — avoids false positives from JSON structural characters and cross-field matches
- **Captures group** in hex_secret pattern — `$1` correctly references the key label
- **Regex `lastIndex` reset** — `/g` flag makes RegExp stateful; must reset between calls

**4.2 Call site:**

Sanitization happens **once** in the `log()` closure, before dispatching to either output path:

```typescript
const clean = sanitizeLogEntry(entry)    // Single pass
writer?.write(clean)                     // SQLite — already clean
if (stderrJson) emitStderr(clean)        // stderr — already clean
```

`sanitizeLogEntry()` helper applies PII patterns to the string fields of a `LogEntry`:

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

Both output paths sanitized — PII never reaches either SQLite or external aggregation.

**4.3 What is NOT filtered:**

- `traces` table `attributes` — developer-set, no user input
- Daemon stdout events — structured events, no free-form text
- Session content in sessions table — not part of logging pipeline
- Object **keys** (only values are sanitized) — keys are developer-controlled strings (`module`, `level`, etc.), not user input. If a future caller puts PII in a key name, sanitize would miss it. This is an accepted limitation; the risk is low since keys come from code, not user data.
- The `module` field — currently always hardcoded strings like `'daemon'`, `'mcp'`, `'search'`. Not user-controlled, so not sanitized.

**4.4 Not configurable (intentional):**

Fixed pattern set in v1. Extensible later via `settings.observability.piiPatterns` if needed. The fixed set covers the most common leaks (API keys, bearer tokens, emails).

## 5. Test Strategy

### 5.1 New: `tests/core/request-context.test.ts`

- `runWithContext()` → `getRequestId()` returns set value
- Nested `runWithContext()` → inner overrides outer
- Async propagation: `setTimeout`, `Promise.all`, `await` chains preserve context
- No context → `getRequestId()` returns undefined

### 5.2 New: `tests/core/sanitizer.test.ts`

- Each PII pattern independently: OpenAI key, Anthropic key, Bearer token, hex secret, email
- Mixed: single log entry with multiple sensitive values
- No sensitive data → unchanged output
- Nested objects: sensitive values at arbitrary depth
- Edge cases: empty object, long strings, special chars
- False positive check: npm scopes (`@types/node`), file paths with `@`, hex strings < 32 chars, git commit hashes after "cache key:" (space separator, not `[:=]`), `password file hash: sha256=abcdef...` with prefix mismatch

### 5.3 Extended: `tests/core/logger.test.ts`

- stderr JSON format: flat metadata + nested data/error
- ALS request_id auto-populates in log entry
- `child()` explicit traceId overrides ALS
- PII sanitization on both SQLite and stderr paths
- `stderrJson: false` → no stderr output (MCP mode)
- Log level filtering: info config → debug not emitted to stderr

### 5.4 Extended: `tests/core/tracer.test.ts`

- `startSpan()` with no args inherits requestId from ALS
- `withSpan()` success → status ok, duration recorded
- `withSpan()` exception → status error, error in attributes, exception re-thrown
- `withSpan()` does NOT call `end()` after `setError()` (no double-write)
- Multiple spans in same ALS context share traceId

### 5.5 New: `tests/integration/request-tracing.test.ts`

- Simulate MCP tool call → verify logs + traces tables have matching trace_id
- Simulate HTTP request → verify x-trace-id roundtrip + logs/traces correlation
- Verify stderr output contains request_id and is PII-sanitized
- Cross-module correlation: tool call → DB query → adapter → all share request_id

### 5.6 Not tested (no changes):

- Daemon stdout event protocol (unchanged)
- Swift side (no changes in this SP)
- Individual tool handler span coverage (covered by integration pattern tests)

## 6. Files Changed

### New files
| File | Purpose |
|------|---------|
| `src/core/request-context.ts` | AsyncLocalStorage context management |
| `src/core/sanitizer.ts` | PII auto-filtering |
| `tests/core/request-context.test.ts` | ALS propagation tests |
| `tests/core/sanitizer.test.ts` | PII pattern tests |
| `tests/integration/request-tracing.test.ts` | End-to-end correlation tests |

### Modified files
| File | Changes |
|------|---------|
| `src/core/logger.ts` | ALS auto-fill, stderr JSON output, sanitize calls, `stderrJson` option, remove `ENGRAM_LOG_LEVEL` branch |
| `src/core/tracer.ts` | ALS fallback in `startSpan()`, export `withSpan()` helper |
| `src/index.ts` | Wrap tool handler in `runWithContext()`, wrap each tool in `withSpan()`, enable `stderrJson: true` |
| `src/web.ts` | Extend `createApp()` opts with `tracer?: Tracer`; replace trace middleware with `runWithContext()`; add tracing middleware |
| `src/daemon.ts` | Pass `tracer` to `createApp()`; wrap scheduler tasks in `runWithContext()`; pass `stderrJson: true` to logger |
| `src/core/indexer.ts` | Import `runWithContext`; wrap per-file processing in `indexAll()` with ALS context; existing tracer usage unchanged |
| `src/core/watcher.ts` | Import `runWithContext` from `request-context.js`; wrap `handleChange` body in ALS context |
| `src/tools/*.ts` | Accept tracer in deps, existing search.ts unchanged |
| `tests/core/logger.test.ts` | Extended with stderr/ALS/PII tests |
| `tests/core/tracer.test.ts` | Extended with ALS/withSpan tests |

## 7. Performance Budget

Each log call now does: `sanitizeLogEntry()` (recursive traverse + 5 regex) + `JSON.stringify()` + `process.stderr.write()`.

**Budget**: sanitize + stderr write < 0.1ms per call.

**Mitigation for high-frequency scenarios** (indexer batch processing ~5-10 logs/file × hundreds of files):
- Debug-level logs skip sanitize + stderr when `logLevel` is `info` or higher (the `shouldLog()` guard fires before any work)
- Rate limiting already caps debug at 100/min per module
- `AsyncLocalStorage.run()` overhead is ~1μs per call (Node.js benchmark) — negligible

**Validation**: add a benchmark test in `tests/core/logger.test.ts` that measures 1000 log calls with sanitize + stderr and asserts < 100μs average per call.

## 8. Out of Scope

- **SP3b**: Metrics expansion + alerting rules (systematic metrics, thresholds, dashboard alerts)
- **SP3d**: AI visual verification (Claude Vision for screenshot regression)
- **SP3e**: Test coverage expansion (adapter edge cases, error paths)
- Swift-side changes (no changes to IndexerProcess, EngramLogger, or UI)
- Configurable PII patterns (fixed set in v1)
- Cross-process trace propagation (daemon ↔ MCP server share DB, but no explicit ID forwarding between processes)
