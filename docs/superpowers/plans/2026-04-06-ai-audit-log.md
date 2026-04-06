# AI Audit Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full observability for all external AI API calls — request/response audit logging with token tracking, Viking observer proxy, and query API.

**Architecture:** New `AiAuditWriter` + `AiAuditQuery` classes record all outgoing AI calls to a dedicated `ai_audit_log` SQLite table. Each AI caller (VikingBridge, TitleGenerator, summarizeConversation, EmbeddingClient) gets an injected `audit` instance and records entries at call boundaries. Web API endpoints expose query/stats, and Viking's observer endpoints are proxied through VikingBridge.

**Tech Stack:** TypeScript, SQLite (better-sqlite3), Hono (web framework), Vitest (testing)

**Spec:** `docs/superpowers/specs/2026-04-06-ai-audit-log-design.md`

---

## Task 1: Foundation — Config, DB Migration, AiAuditWriter + AiAuditQuery

**Files:**
- Modify: `src/core/config.ts:28-33,49-129` (add AiAuditConfig + FileSettings field)
- Modify: `src/core/db.ts:125-434` (add ai_audit_log table in migrate())
- Create: `src/core/ai-audit.ts`
- Create: `tests/core/ai-audit.test.ts`

### Step 1: Add AiAuditConfig to config.ts

- [ ] Add the `AiAuditConfig` interface and `aiAudit` field to `FileSettings`.

In `src/core/config.ts`, after `VikingSettings` (line 33), add:

```typescript
export interface AiAuditConfig {
  enabled: boolean
  retentionDays: number
  maxBodySize: number
  logBodies: boolean
}

export const DEFAULT_AI_AUDIT_CONFIG: AiAuditConfig = {
  enabled: true,
  retentionDays: 30,
  maxBodySize: 10000,
  logBodies: false,
}
```

In the `FileSettings` interface (before the closing `}`), add:

```typescript
  // ── AI Audit ──────────────────────────────────────────────────────
  aiAudit?: Partial<AiAuditConfig>
```

### Step 2: Add ai_audit_log table to db.ts migrate()

- [ ] In `src/core/db.ts`, inside `migrate()`, after the last table creation block (alerts table, ~line 429), add:

```typescript
    // ── AI Audit Log ────────────────────────────────────────────────
    if (!colSet(this.db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='ai_audit_log'").get())) {
      this.db.exec(`
        CREATE TABLE ai_audit_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
          trace_id TEXT,
          caller TEXT NOT NULL,
          operation TEXT NOT NULL,
          request_source TEXT,
          method TEXT,
          url TEXT,
          status_code INTEGER,
          duration_ms INTEGER,
          model TEXT,
          provider TEXT,
          prompt_tokens INTEGER,
          completion_tokens INTEGER,
          total_tokens INTEGER,
          request_body TEXT,
          response_body TEXT,
          error TEXT,
          session_id TEXT,
          meta TEXT
        )
      `)
      this.db.exec('CREATE INDEX idx_ai_audit_ts ON ai_audit_log(ts)')
      this.db.exec('CREATE INDEX idx_ai_audit_caller ON ai_audit_log(caller, ts)')
      this.db.exec('CREATE INDEX idx_ai_audit_model ON ai_audit_log(model, ts)')
      this.db.exec('CREATE INDEX idx_ai_audit_session ON ai_audit_log(session_id)')
      this.db.exec('CREATE INDEX idx_ai_audit_trace ON ai_audit_log(trace_id)')
    }
```

Note: Check the existing pattern in `migrate()` for how table existence is tested. It may use `PRAGMA table_info` or `SELECT name FROM sqlite_master`. Follow the same pattern.

- [ ] Run `npm run build` to verify compilation.

### Step 3: Write AiAuditWriter tests

- [ ] Create `tests/core/ai-audit.test.ts` with tests for:

```typescript
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import Database from 'better-sqlite3'
import { AiAuditWriter, AiAuditQuery, type AiAuditRecord } from '../../src/core/ai-audit.js'
import { DEFAULT_AI_AUDIT_CONFIG } from '../../src/core/config.js'

describe('AiAuditWriter', () => {
  let db: Database.Database
  let writer: AiAuditWriter

  beforeEach(() => {
    db = new Database(':memory:')
    // Create the table (normally done by db.ts migrate)
    db.exec(`CREATE TABLE ai_audit_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
      trace_id TEXT, caller TEXT NOT NULL, operation TEXT NOT NULL,
      request_source TEXT, method TEXT, url TEXT, status_code INTEGER,
      duration_ms INTEGER, model TEXT, provider TEXT,
      prompt_tokens INTEGER, completion_tokens INTEGER, total_tokens INTEGER,
      request_body TEXT, response_body TEXT, error TEXT, session_id TEXT, meta TEXT
    )`)
    writer = new AiAuditWriter(db, DEFAULT_AI_AUDIT_CONFIG)
  })

  afterEach(() => db.close())

  it('records a basic entry and returns the inserted id', () => {
    const id = writer.record({
      caller: 'title', operation: 'generate', durationMs: 100,
      model: 'qwen2.5:3b', provider: 'ollama',
    })
    expect(id).toBeGreaterThan(0)
    const row = db.prepare('SELECT * FROM ai_audit_log WHERE id = ?').get(id) as any
    expect(row.caller).toBe('title')
    expect(row.model).toBe('qwen2.5:3b')
    expect(row.duration_ms).toBe(100)
  })

  it('records token counts', () => {
    const id = writer.record({
      caller: 'summary', operation: 'summarize', durationMs: 500,
      promptTokens: 1000, completionTokens: 200, totalTokens: 1200,
    })
    const row = db.prepare('SELECT * FROM ai_audit_log WHERE id = ?').get(id) as any
    expect(row.prompt_tokens).toBe(1000)
    expect(row.completion_tokens).toBe(200)
    expect(row.total_tokens).toBe(1200)
  })

  it('does not store bodies when logBodies is false', () => {
    const id = writer.record({
      caller: 'title', operation: 'generate', durationMs: 100,
      requestBody: { prompt: 'hello' }, responseBody: { text: 'world' },
    })
    const row = db.prepare('SELECT * FROM ai_audit_log WHERE id = ?').get(id) as any
    expect(row.request_body).toBeNull()
    expect(row.response_body).toBeNull()
  })

  it('stores bodies when logBodies is true', () => {
    const w = new AiAuditWriter(db, { ...DEFAULT_AI_AUDIT_CONFIG, logBodies: true })
    const id = w.record({
      caller: 'title', operation: 'generate', durationMs: 100,
      requestBody: { prompt: 'hello' }, responseBody: { text: 'world' },
    })
    const row = db.prepare('SELECT * FROM ai_audit_log WHERE id = ?').get(id) as any
    expect(row.request_body).toContain('hello')
    expect(row.response_body).toContain('world')
  })

  it('truncates bodies to maxBodySize', () => {
    const w = new AiAuditWriter(db, { ...DEFAULT_AI_AUDIT_CONFIG, logBodies: true, maxBodySize: 20 })
    const id = w.record({
      caller: 'title', operation: 'generate', durationMs: 100,
      requestBody: 'a'.repeat(100),
    })
    const row = db.prepare('SELECT * FROM ai_audit_log WHERE id = ?').get(id) as any
    expect(row.request_body.length).toBeLessThanOrEqual(25) // 20 + truncation marker
  })

  it('sanitizes URLs (strips API keys)', () => {
    const id = writer.record({
      caller: 'summary', operation: 'summarize', durationMs: 100,
      url: 'https://api.example.com/v1?key=sk-abc123def456',
    })
    const row = db.prepare('SELECT * FROM ai_audit_log WHERE id = ?').get(id) as any
    expect(row.url).not.toContain('sk-abc123def456')
  })

  it('never throws on record failure', () => {
    db.close() // break the DB
    expect(() => writer.record({
      caller: 'title', operation: 'generate', durationMs: 100,
    })).not.toThrow()
    expect(writer.record({ caller: 'title', operation: 'generate', durationMs: 100 })).toBe(-1)
  })

  it('emits entry event after recording', () => {
    const handler = vi.fn()
    writer.on('entry', handler)
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 })
    expect(handler).toHaveBeenCalledWith(expect.objectContaining({ caller: 'title' }))
  })

  it('skips recording when disabled', () => {
    const w = new AiAuditWriter(db, { ...DEFAULT_AI_AUDIT_CONFIG, enabled: false })
    const id = w.record({ caller: 'title', operation: 'generate', durationMs: 100 })
    expect(id).toBe(-1)
    const count = db.prepare('SELECT COUNT(*) as c FROM ai_audit_log').get() as any
    expect(count.c).toBe(0)
  })

  it('stores meta as JSON', () => {
    const id = writer.record({
      caller: 'viking', operation: 'pushSession', durationMs: 5000,
      meta: { messageCount: 50 },
    })
    const row = db.prepare('SELECT * FROM ai_audit_log WHERE id = ?').get(id) as any
    expect(JSON.parse(row.meta)).toEqual({ messageCount: 50 })
  })

  it('cleanup deletes old records', () => {
    // Insert a record with old timestamp
    db.prepare(`INSERT INTO ai_audit_log (ts, caller, operation, duration_ms)
      VALUES (datetime('now', '-60 days'), 'title', 'generate', 100)`).run()
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 })
    expect(writer.cleanup(30)).toBe(1)
    const count = db.prepare('SELECT COUNT(*) as c FROM ai_audit_log').get() as any
    expect(count.c).toBe(1) // only the recent one remains
  })
})
```

- [ ] Run: `npx vitest run tests/core/ai-audit.test.ts` �� Expected: FAIL (module not found)

### Step 4: Write AiAuditQuery tests

- [ ] Add to the same test file:

```typescript
describe('AiAuditQuery', () => {
  let db: Database.Database
  let writer: AiAuditWriter
  let query: AiAuditQuery

  beforeEach(() => {
    db = new Database(':memory:')
    db.exec(`CREATE TABLE ai_audit_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
      trace_id TEXT, caller TEXT NOT NULL, operation TEXT NOT NULL,
      request_source TEXT, method TEXT, url TEXT, status_code INTEGER,
      duration_ms INTEGER, model TEXT, provider TEXT,
      prompt_tokens INTEGER, completion_tokens INTEGER, total_tokens INTEGER,
      request_body TEXT, response_body TEXT, error TEXT, session_id TEXT, meta TEXT
    )`)
    writer = new AiAuditWriter(db, DEFAULT_AI_AUDIT_CONFIG)
    query = new AiAuditQuery(db)
  })

  afterEach(() => db.close())

  it('list returns paginated records', () => {
    for (let i = 0; i < 10; i++) {
      writer.record({ caller: 'title', operation: 'generate', durationMs: 100 + i })
    }
    const result = query.list({ limit: 3, offset: 0 })
    expect(result.records).toHaveLength(3)
    expect(result.total).toBe(10)
  })

  it('list filters by caller', () => {
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 })
    writer.record({ caller: 'viking', operation: 'find', durationMs: 200 })
    const result = query.list({ caller: 'viking' })
    expect(result.records).toHaveLength(1)
    expect(result.records[0].caller).toBe('viking')
  })

  it('list filters by hasError', () => {
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 })
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100, error: 'timeout' })
    const result = query.list({ hasError: true })
    expect(result.records).toHaveLength(1)
    expect(result.records[0].error).toBe('timeout')
  })

  it('list from parameter is exclusive', () => {
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 })
    // Small delay to ensure different timestamps
    const { records } = query.list({})
    const ts = records[0].ts
    const result = query.list({ from: ts })
    expect(result.records).toHaveLength(0) // from is exclusive, so same ts excluded
  })

  it('get returns single record', () => {
    const id = writer.record({ caller: 'title', operation: 'generate', durationMs: 100 })
    const record = query.get(id)
    expect(record).not.toBeNull()
    expect(record!.caller).toBe('title')
  })

  it('get returns null for missing id', () => {
    expect(query.get(9999)).toBeNull()
  })

  it('stats returns aggregated data', () => {
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100, model: 'qwen', promptTokens: 500, completionTokens: 100, totalTokens: 600 })
    writer.record({ caller: 'viking', operation: 'find', durationMs: 200 })
    writer.record({ caller: 'title', operation: 'generate', durationMs: 300, model: 'qwen', error: 'fail' })

    const s = query.stats()
    expect(s.totals.requests).toBe(3)
    expect(s.totals.errors).toBe(1)
    expect(s.totals.promptTokens).toBe(500)
    expect(s.byCaller.title.requests).toBe(2)
    expect(s.byCaller.viking.requests).toBe(1)
    expect(s.byModel.qwen).toBeDefined()
  })
})
```

### Step 5: Implement AiAuditWriter

- [ ] Create `src/core/ai-audit.ts`:

```typescript
// src/core/ai-audit.ts
import { EventEmitter } from 'events'
import type Database from 'better-sqlite3'
import type { AiAuditConfig } from './config.js'
import { applyPatterns } from './sanitizer.js'
import { getRequestContext } from './request-context.js'

export interface AiAuditRecord {
  id?: number
  ts?: string
  traceId?: string
  caller: string
  operation: string
  requestSource?: string
  method?: string
  url?: string
  statusCode?: number
  model?: string
  provider?: string
  promptTokens?: number
  completionTokens?: number
  totalTokens?: number
  requestBody?: unknown
  responseBody?: unknown
  durationMs: number
  error?: string
  sessionId?: string
  meta?: Record<string, unknown>
}

function stringify(value: unknown): string | null {
  if (value == null) return null
  if (typeof value === 'string') return value
  try { return JSON.stringify(value) } catch { return null }
}

function truncate(str: string | null, max: number): string | null {
  if (!str || str.length <= max) return str
  return str.slice(0, max) + '...[truncated]'
}

export class AiAuditWriter extends EventEmitter {
  private stmt: Database.Statement | null = null

  constructor(private db: Database.Database, private config: AiAuditConfig) {
    super()
    try {
      this.stmt = db.prepare(`
        INSERT INTO ai_audit_log (trace_id, caller, operation, request_source,
          method, url, status_code, duration_ms, model, provider,
          prompt_tokens, completion_tokens, total_tokens,
          request_body, response_body, error, session_id, meta)
        VALUES (@traceId, @caller, @operation, @requestSource,
          @method, @url, @statusCode, @durationMs, @model, @provider,
          @promptTokens, @completionTokens, @totalTokens,
          @requestBody, @responseBody, @error, @sessionId, @meta)
      `)
    } catch { /* table may not exist yet in tests */ }
  }

  record(entry: AiAuditRecord): number {
    if (!this.config.enabled) return -1
    try {
      const ctx = getRequestContext()
      const traceId = entry.traceId || ctx?.requestId || null
      const requestSource = entry.requestSource || ctx?.source || null

      let requestBody: string | null = null
      let responseBody: string | null = null
      if (this.config.logBodies) {
        requestBody = truncate(applyPatterns(stringify(entry.requestBody) || ''), this.config.maxBodySize)
        responseBody = truncate(applyPatterns(stringify(entry.responseBody) || ''), this.config.maxBodySize)
      }

      const url = entry.url ? applyPatterns(entry.url) : null

      const result = this.stmt!.run({
        traceId,
        caller: entry.caller,
        operation: entry.operation,
        requestSource,
        method: entry.method || null,
        url,
        statusCode: entry.statusCode ?? null,
        durationMs: entry.durationMs,
        model: entry.model || null,
        provider: entry.provider || null,
        promptTokens: entry.promptTokens ?? null,
        completionTokens: entry.completionTokens ?? null,
        totalTokens: entry.totalTokens ?? null,
        requestBody,
        responseBody,
        error: entry.error || null,
        sessionId: entry.sessionId || null,
        meta: entry.meta ? JSON.stringify(entry.meta) : null,
      })

      const id = Number(result.lastInsertRowid)
      this.emit('entry', { id, ...entry, traceId, requestSource })
      return id
    } catch {
      return -1
    }
  }

  cleanup(retentionDays: number): number {
    try {
      const result = this.db.prepare(
        `DELETE FROM ai_audit_log WHERE ts < datetime('now', '-' || ? || ' days')`
      ).run(retentionDays)
      return result.changes
    } catch { return 0 }
  }
}

export class AiAuditQuery {
  constructor(private db: Database.Database) {}

  list(filters: {
    caller?: string; model?: string; sessionId?: string
    from?: string; to?: string; hasError?: boolean
    limit?: number; offset?: number
  } = {}): { records: AiAuditRecord[]; total: number } {
    const conditions: string[] = []
    const params: Record<string, unknown> = {}

    if (filters.caller) { conditions.push('caller = @caller'); params.caller = filters.caller }
    if (filters.model) { conditions.push('model = @model'); params.model = filters.model }
    if (filters.sessionId) { conditions.push('session_id = @sessionId'); params.sessionId = filters.sessionId }
    if (filters.from) { conditions.push('ts > @from'); params.from = filters.from }
    if (filters.to) { conditions.push('ts <= @to'); params.to = filters.to }
    if (filters.hasError === true) conditions.push('error IS NOT NULL')
    if (filters.hasError === false) conditions.push('error IS NULL')

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : ''
    const limit = filters.limit ?? 50
    const offset = filters.offset ?? 0

    const rows = this.db.prepare(
      `SELECT * FROM ai_audit_log ${where} ORDER BY ts DESC LIMIT @limit OFFSET @offset`
    ).all({ ...params, limit, offset }) as any[]

    const countRow = this.db.prepare(
      `SELECT COUNT(*) as c FROM ai_audit_log ${where}`
    ).get(params) as any

    return {
      records: rows.map(r => this.rowToRecord(r)),
      total: countRow?.c ?? 0,
    }
  }

  get(id: number): AiAuditRecord | null {
    const row = this.db.prepare('SELECT * FROM ai_audit_log WHERE id = ?').get(id) as any
    return row ? this.rowToRecord(row) : null
  }

  stats(timeRange?: { from?: string; to?: string }): {
    timeRange: { from: string; to: string }
    totals: { requests: number; errors: number; promptTokens: number; completionTokens: number; avgDurationMs: number }
    byCaller: Record<string, { requests: number; errors: number; promptTokens: number; completionTokens: number }>
    byModel: Record<string, { requests: number; promptTokens: number; completionTokens: number }>
    hourly: { hour: string; requests: number; tokens: number }[]
  } {
    const from = timeRange?.from || new Date(Date.now() - 86400000).toISOString()
    const to = timeRange?.to || new Date().toISOString()
    const where = 'WHERE ts > @from AND ts <= @to'
    const params = { from, to }

    const totalsRow = this.db.prepare(`
      SELECT COUNT(*) as requests,
        SUM(CASE WHEN error IS NOT NULL THEN 1 ELSE 0 END) as errors,
        COALESCE(SUM(prompt_tokens), 0) as promptTokens,
        COALESCE(SUM(completion_tokens), 0) as completionTokens,
        COALESCE(AVG(duration_ms), 0) as avgDurationMs
      FROM ai_audit_log ${where}
    `).get(params) as any

    const callerRows = this.db.prepare(`
      SELECT caller,
        COUNT(*) as requests,
        SUM(CASE WHEN error IS NOT NULL THEN 1 ELSE 0 END) as errors,
        COALESCE(SUM(prompt_tokens), 0) as promptTokens,
        COALESCE(SUM(completion_tokens), 0) as completionTokens
      FROM ai_audit_log ${where} GROUP BY caller
    `).all(params) as any[]

    const modelRows = this.db.prepare(`
      SELECT model,
        COUNT(*) as requests,
        COALESCE(SUM(prompt_tokens), 0) as promptTokens,
        COALESCE(SUM(completion_tokens), 0) as completionTokens
      FROM ai_audit_log ${where} AND model IS NOT NULL GROUP BY model
    `).all(params) as any[]

    const hourlyRows = this.db.prepare(`
      SELECT strftime('%Y-%m-%dT%H:00', ts) as hour,
        COUNT(*) as requests,
        COALESCE(SUM(COALESCE(prompt_tokens, 0) + COALESCE(completion_tokens, 0)), 0) as tokens
      FROM ai_audit_log ${where} GROUP BY hour ORDER BY hour
    `).all(params) as any[]

    const byCaller: Record<string, any> = {}
    for (const r of callerRows) byCaller[r.caller] = { requests: r.requests, errors: r.errors, promptTokens: r.promptTokens, completionTokens: r.completionTokens }

    const byModel: Record<string, any> = {}
    for (const r of modelRows) if (r.model) byModel[r.model] = { requests: r.requests, promptTokens: r.promptTokens, completionTokens: r.completionTokens }

    return {
      timeRange: { from, to },
      totals: {
        requests: totalsRow.requests,
        errors: totalsRow.errors,
        promptTokens: totalsRow.promptTokens,
        completionTokens: totalsRow.completionTokens,
        avgDurationMs: Math.round(totalsRow.avgDurationMs),
      },
      byCaller,
      byModel,
      hourly: hourlyRows.map(r => ({ hour: r.hour, requests: r.requests, tokens: r.tokens })),
    }
  }

  private rowToRecord(r: any): AiAuditRecord {
    return {
      id: r.id,
      ts: r.ts,
      traceId: r.trace_id,
      caller: r.caller,
      operation: r.operation,
      requestSource: r.request_source,
      method: r.method,
      url: r.url,
      statusCode: r.status_code,
      durationMs: r.duration_ms,
      model: r.model,
      provider: r.provider,
      promptTokens: r.prompt_tokens,
      completionTokens: r.completion_tokens,
      totalTokens: r.total_tokens,
      requestBody: r.request_body,
      responseBody: r.response_body,
      error: r.error,
      sessionId: r.session_id,
      meta: r.meta ? JSON.parse(r.meta) : null,
    }
  }
}
```

- [ ] Run: `npx vitest run tests/core/ai-audit.test.ts` — Expected: ALL PASS
- [ ] Run: `npm run build` — Expected: clean
- [ ] Commit: `feat(ai-audit): add AiAuditWriter + AiAuditQuery with schema migration`

---

## Task 2: VikingBridge Audit Integration

**Files:**
- Modify: `src/core/viking-bridge.ts`
- Modify: `tests/core/viking-bridge.test.ts`

### Step 1: Add audit to VikingBridge constructor

- [ ] In `src/core/viking-bridge.ts`, add `AiAuditWriter` import and constructor param.

Add to constructor options type:
```typescript
import type { AiAuditWriter } from './ai-audit.js'

// In constructor opts:
constructor(url: string, apiKey: string, opts?: {
  agentId?: string; maxRequestsPerHour?: number;
  audit?: AiAuditWriter;   // ← new
  log?: Logger; metrics?: MetricsCollector; tracer?: Tracer
})
```

Store as `private audit?: AiAuditWriter` and assign in constructor: `this.audit = opts?.audit`.

### Step 2: Add _suppressAudit flag and audit to post()

- [ ] Add instance flag: `private _suppressAudit = false`

- [ ] In `post()`, after the successful `return res.json()` or error throw, do NOT add per-call audit here. Instead, the public methods will call audit themselves. The `post()` method stays as-is — each public method wraps its own audit call.

### Step 3: Audit the public methods

- [ ] For each public method (`find`, `grep`, `abstract`, `overview`, `read`, `ls`, `addResource`, `deleteResources`, `isAvailable`, `findMemories`), wrap the existing logic:

Pattern for each method (example with `find`):

```typescript
async find(query: string, targetUri?: string): Promise<VikingSearchResult[]> {
  const start = Date.now()
  // ... existing find logic ...
  // After getting results (or catching error):
  this.audit?.record({
    caller: 'viking', operation: 'find', provider: 'viking',
    method: 'POST', url: `${this.api}/search/find`,
    statusCode: res.ok ? 200 : res.status,
    durationMs: Date.now() - start,
    requestBody: body,
    responseBody: data,
    error: res.ok ? undefined : `${res.status}`,
  })
  return results
}
```

Apply this pattern to all Viking public methods. Each method records its own audit entry with the appropriate `operation` name matching the method name.

### Step 4: pushSession summary audit

- [ ] Modify `pushSession()` to suppress per-call audit and record a single summary:

```typescript
async pushSession(sessionId: string, messages: { role: string; content: string }[]): Promise<void> {
  await this.acquirePushSlot()
  const pushStart = Date.now()
  this._suppressAudit = true  // suppress per-message audit
  try {
    // ... existing create + message loop + commit logic ...
    this.audit?.record({
      caller: 'viking', operation: 'pushSession', provider: 'viking',
      durationMs: Date.now() - pushStart,
      sessionId,
      meta: { messageCount: messages.length },
    })
  } catch (err) {
    this.audit?.record({
      caller: 'viking', operation: 'pushSession', provider: 'viking',
      durationMs: Date.now() - pushStart,
      sessionId,
      error: err instanceof Error ? err.message : String(err),
      meta: { messageCount: messages.length },
    })
    throw err
  } finally {
    this._suppressAudit = false
    this.releasePushSlot()
  }
}
```

### Step 5: Add 5 observer proxy methods

- [ ] Add methods to VikingBridge:

```typescript
private async getObserver(path: string): Promise<Record<string, unknown> | null> {
  try {
    const res = await vikingFetch(`${this.api}/observer/${path}`, {
      method: 'GET', headers: this.headers, signal: AbortSignal.timeout(5000),
    })
    if (!res.ok) return null
    const data = await res.json()
    return (data?.result ?? data) as Record<string, unknown>
  } catch { return null }
}

async observerSystem(): Promise<Record<string, unknown> | null> { return this.getObserver('system') }
async observerQueue(): Promise<Record<string, unknown> | null> { return this.getObserver('queue') }
async observerVlm(): Promise<Record<string, unknown> | null> { return this.getObserver('vlm') }
async observerVikingdb(): Promise<Record<string, unknown> | null> { return this.getObserver('vikingdb') }
async observerTransaction(): Promise<Record<string, unknown> | null> { return this.getObserver('transaction') }
```

### Step 6: Write tests

- [ ] Add to `tests/core/viking-bridge.test.ts`:

```typescript
describe('audit integration', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('records audit entry for find()', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) }
    const bridge = new VikingBridge('http://localhost:1933', 'key', { audit: audit as any })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ status: 'ok', result: { resources: [] } }),
    }))
    await bridge.find('test query')
    expect(audit.record).toHaveBeenCalledWith(expect.objectContaining({
      caller: 'viking', operation: 'find',
    }))
  })

  it('records pushSession summary (not per-message)', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) }
    const bridge = new VikingBridge('http://localhost:1933', 'key', { audit: audit as any })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }),
    }))
    await bridge.pushSession('test-id', [{ role: 'user', content: 'hi' }])
    // Should only record ONE audit entry (summary), not per-message
    const pushCalls = audit.record.mock.calls.filter((c: any) => c[0].operation === 'pushSession')
    expect(pushCalls).toHaveLength(1)
    expect(pushCalls[0][0].meta.messageCount).toBe(1)
  })
})
```

- [ ] Run: `npx vitest run tests/core/viking-bridge.test.ts` — Expected: ALL PASS
- [ ] Run: `npm run build && npm test` — Expected: ALL PASS
- [ ] Commit: `feat(ai-audit): add audit logging to VikingBridge + observer proxy methods`

---

## Task 3: TitleGenerator Audit Integration

**Files:**
- Modify: `src/core/title-generator.ts`
- Modify: `tests/core/title-generator.test.ts`

### Step 1: Add audit to TitleGenerator

- [ ] In `src/core/title-generator.ts`, import `AiAuditWriter` and add to the config type + constructor.

Store: `private audit?: AiAuditWriter`

### Step 2: Extract tokens and audit in generate()

- [ ] In the `callLLM()` method (or `generate()`), after parsing the response JSON (~line 50):

For Ollama responses, extract: `json.prompt_eval_count`, `json.eval_count`
For OpenAI responses, extract: `json.usage?.prompt_tokens`, `json.usage?.completion_tokens`

Record the audit entry:

```typescript
this.audit?.record({
  caller: 'title',
  operation: 'generate',
  method: 'POST',
  url,
  statusCode: res.status,
  model: this.config.model,
  provider: this.config.provider,
  promptTokens,
  completionTokens,
  totalTokens: (promptTokens ?? 0) + (completionTokens ?? 0) || undefined,
  durationMs: Date.now() - start,
  requestBody: { prompt },
  responseBody: { text: result },
  error: res.ok ? undefined : `${res.status}`,
})
```

### Step 3: Test token extraction

- [ ] In `tests/core/title-generator.test.ts`, add:

```typescript
describe('audit integration', () => {
  it('records audit with Ollama token counts', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) }
    const gen = new TitleGenerator({
      provider: 'ollama', baseUrl: 'http://localhost:11434',
      model: 'qwen2.5:3b', autoGenerate: true, audit: audit as any,
    })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        response: 'Test Title',
        prompt_eval_count: 100, eval_count: 20,
      }),
    }))
    await gen.generate([{ role: 'user', content: 'hello' }])
    expect(audit.record).toHaveBeenCalledWith(expect.objectContaining({
      caller: 'title', promptTokens: 100, completionTokens: 20,
    }))
  })

  it('records audit with OpenAI token counts', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) }
    const gen = new TitleGenerator({
      provider: 'openai', baseUrl: 'http://localhost:8080',
      model: 'gpt-4o-mini', autoGenerate: true, audit: audit as any,
    })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        choices: [{ message: { content: 'Test Title' } }],
        usage: { prompt_tokens: 200, completion_tokens: 30 },
      }),
    }))
    await gen.generate([{ role: 'user', content: 'hello' }])
    expect(audit.record).toHaveBeenCalledWith(expect.objectContaining({
      caller: 'title', promptTokens: 200, completionTokens: 30,
    }))
  })
})
```

- [ ] Run: `npx vitest run tests/core/title-generator.test.ts` — Expected: ALL PASS
- [ ] Commit: `feat(ai-audit): add audit + token extraction to TitleGenerator`

---

## Task 4: summarizeConversation Audit Integration

**Files:**
- Modify: `src/core/ai-client.ts`
- Modify: `tests/core/ai-client.test.ts`
- Modify: `src/tools/generate_summary.ts` (update call site)

### Step 1: Add opts parameter to summarizeConversation

- [ ] Change signature from:
```typescript
export async function summarizeConversation(messages: ConversationMessage[], settings: FileSettings): Promise<string>
```
to:
```typescript
export async function summarizeConversation(
  messages: ConversationMessage[],
  settings: FileSettings,
  opts?: { audit?: AiAuditWriter; sessionId?: string }
): Promise<string>
```

### Step 2: Extract tokens per protocol and audit

- [ ] After the `const data = await response.json()` line (~line 187), extract tokens based on protocol:

```typescript
// Token extraction per protocol
let promptTokens: number | undefined
let completionTokens: number | undefined
if (protocol === 'openai') {
  promptTokens = data.usage?.prompt_tokens
  completionTokens = data.usage?.completion_tokens
} else if (protocol === 'anthropic') {
  promptTokens = data.usage?.input_tokens
  completionTokens = data.usage?.output_tokens
} else if (protocol === 'gemini') {
  promptTokens = data.usageMetadata?.promptTokenCount
  completionTokens = data.usageMetadata?.candidatesTokenCount
}

opts?.audit?.record({
  caller: 'summary',
  operation: 'summarize',
  method: 'POST',
  url,
  statusCode: response.status,
  model,
  provider: protocol,
  promptTokens,
  completionTokens,
  totalTokens: (promptTokens ?? 0) + (completionTokens ?? 0) || undefined,
  durationMs: Date.now() - start,
  requestBody: body,
  responseBody: data,
  sessionId: opts?.sessionId,
})
```

Add `const start = Date.now()` at the beginning of the function.

### Step 3: Update call sites

- [ ] In `src/tools/generate_summary.ts`, pass opts through (the tool handler likely has access to sessionId).
- [ ] In `src/daemon.ts` AutoSummaryManager callback, pass audit.
- [ ] In `src/web.ts` if there's a direct call, pass audit.

These changes are minimal — just adding the third argument where the function is called.

### Step 4: Test token extraction

- [ ] In `tests/core/ai-client.test.ts`, add tests for each protocol:

```typescript
describe('audit integration', () => {
  it('records OpenAI tokens', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        choices: [{ message: { content: 'Summary text' } }],
        usage: { prompt_tokens: 1000, completion_tokens: 150 },
      }),
    }))
    await summarizeConversation(
      [{ role: 'user', content: 'hello' }],
      { aiProtocol: 'openai', aiApiKey: 'test', aiModel: 'gpt-4o-mini' } as any,
      { audit: audit as any, sessionId: 'sess-1' },
    )
    expect(audit.record).toHaveBeenCalledWith(expect.objectContaining({
      caller: 'summary', promptTokens: 1000, completionTokens: 150, sessionId: 'sess-1',
    }))
  })

  // Similar tests for Anthropic and Gemini protocols
})
```

- [ ] Run: `npx vitest run tests/core/ai-client.test.ts` — Expected: ALL PASS
- [ ] Commit: `feat(ai-audit): add audit + token extraction to summarizeConversation`

---

## Task 5: EmbeddingClient Audit Integration

**Files:**
- Modify: `src/core/embeddings.ts`
- Modify: `tests/core/embeddings.test.ts`

### Step 1: Add audit to createEmbeddingClient opts

- [ ] Add `audit?: AiAuditWriter` to the options type of `createEmbeddingClient()` (line 16).

### Step 2: Audit the Ollama embed path

- [ ] After the Ollama fetch response (~line 33), extract tokens and audit:

```typescript
const promptTokens = data.prompt_eval_count ?? undefined
audit?.record({
  caller: 'embedding', operation: 'embed', method: 'POST',
  url: `${ollamaUrl}/api/embed`,
  statusCode: 200, model: ollamaModel, provider: 'ollama',
  promptTokens, durationMs: Date.now() - start,
  meta: { dimension },
})
```

### Step 3: Audit the OpenAI SDK embed path

- [ ] After the OpenAI SDK response (~line 60), extract tokens:

```typescript
const promptTokens = res.usage?.prompt_tokens ?? undefined
audit?.record({
  caller: 'embedding', operation: 'embed',
  model: 'text-embedding-3-small', provider: 'openai',
  promptTokens, durationMs: Date.now() - start,
  meta: { dimension },
})
```

Note: `method`, `url`, `statusCode` are null for SDK path.

### Step 4: Test

- [ ] In `tests/core/embeddings.test.ts`, add:

```typescript
describe('audit integration', () => {
  it('records audit for Ollama embed', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) }
    // ... mock Ollama fetch, create client with audit, call embed ...
    expect(audit.record).toHaveBeenCalledWith(expect.objectContaining({
      caller: 'embedding', provider: 'ollama',
    }))
  })
})
```

- [ ] Run: `npx vitest run tests/core/embeddings.test.ts` — Expected: ALL PASS
- [ ] Commit: `feat(ai-audit): add audit + token extraction to EmbeddingClient`

---

## Task 6: Web API Endpoints

**Files:**
- Modify: `src/web.ts`
- Modify or create: `tests/web/ai-audit-api.test.ts`

### Step 1: Add audit opts to createApp

- [ ] In `src/web.ts`, add to `createApp` opts type (~line 74):

```typescript
audit?: AiAuditWriter
auditQuery?: AiAuditQuery
```

Import `AiAuditWriter`, `AiAuditQuery` from `./core/ai-audit.js`.

### Step 2: Add GET auth middleware for /api/ai/*

- [ ] After the existing bearer auth middleware (~line 192), add:

```typescript
// Bearer auth for /api/ai/* GET endpoints (audit data may contain sensitive content)
app.use('/api/ai/*', async (c, next) => {
  if (bearerToken) {
    const auth = c.req.header('authorization')
    if (auth !== `Bearer ${bearerToken}`) {
      return c.json({ error: 'Unauthorized' }, 401)
    }
  }
  await next()
})
```

### Step 3: Add /api/ai/audit list endpoint

- [ ] Add route:

```typescript
app.get('/api/ai/audit', (c) => {
  if (!opts?.auditQuery) return c.json({ error: 'Audit not configured' }, 501)
  const q = c.req.query()
  const result = opts.auditQuery.list({
    caller: q.caller || undefined,
    model: q.model || undefined,
    sessionId: q.sessionId || undefined,
    from: q.from || undefined,
    to: q.to || undefined,
    hasError: q.hasError === 'true' ? true : q.hasError === 'false' ? false : undefined,
    limit: q.limit ? parseInt(q.limit, 10) : undefined,
    offset: q.offset ? parseInt(q.offset, 10) : undefined,
  })
  return c.json(result)
})
```

### Step 4: Add /api/ai/audit/:id endpoint

```typescript
app.get('/api/ai/audit/:id', (c) => {
  if (!opts?.auditQuery) return c.json({ error: 'Audit not configured' }, 501)
  const record = opts.auditQuery.get(parseInt(c.req.param('id'), 10))
  if (!record) return c.json({ error: 'not found' }, 404)
  return c.json(record)
})
```

### Step 5: Add /api/ai/stats endpoint

```typescript
app.get('/api/ai/stats', (c) => {
  if (!opts?.auditQuery) return c.json({ error: 'Audit not configured' }, 501)
  const q = c.req.query()
  return c.json(opts.auditQuery.stats({
    from: q.from || undefined,
    to: q.to || undefined,
  }))
})
```

### Step 6: Add Viking observer proxy routes

```typescript
app.get('/api/viking/observer', async (c) => {
  if (!opts?.viking) return c.json({ error: 'Viking not configured' }, 501)
  return c.json(await opts.viking.observerSystem())
})
app.get('/api/viking/observer/queue', async (c) => {
  if (!opts?.viking) return c.json({ error: 'Viking not configured' }, 501)
  return c.json(await opts.viking.observerQueue())
})
app.get('/api/viking/observer/vlm', async (c) => {
  if (!opts?.viking) return c.json({ error: 'Viking not configured' }, 501)
  return c.json(await opts.viking.observerVlm())
})
app.get('/api/viking/observer/vikingdb', async (c) => {
  if (!opts?.viking) return c.json({ error: 'Viking not configured' }, 501)
  return c.json(await opts.viking.observerVikingdb())
})
app.get('/api/viking/observer/transaction', async (c) => {
  if (!opts?.viking) return c.json({ error: 'Viking not configured' }, 501)
  return c.json(await opts.viking.observerTransaction())
})
```

### Step 7: Replace raw Viking observer fetch in health endpoint

- [ ] In the health data function (~line 820-835), replace the raw `fetch()` calls with:

```typescript
if (available) {
  const queueData = await opts.viking.observerQueue()
  const vlmData = await opts.viking.observerVlm()
  viking = { available: true, queue: queueData, vlm: vlmData }
}
```

### Step 8: Test

- [ ] Create `tests/web/ai-audit-api.test.ts` with tests for:
  - GET /api/ai/audit returns paginated results
  - GET /api/ai/audit/:id returns single record
  - GET /api/ai/stats returns aggregated stats
  - GET /api/ai/audit requires bearer token when configured
  - GET /api/viking/observer returns 501 when Viking not configured

- [ ] Run: `npm test` — Expected: ALL PASS
- [ ] Commit: `feat(ai-audit): add /api/ai/* endpoints + Viking observer proxy routes`

---

## Task 7: Wiring — daemon.ts, index.ts, bootstrap.ts

**Files:**
- Modify: `src/core/bootstrap.ts`
- Modify: `src/daemon.ts`
- Modify: `src/index.ts`

### Step 1: Update bootstrap.ts initViking

- [ ] Pass `audit` through to VikingBridge:

```typescript
export function initViking(settings: FileSettings, opts?: {
  audit?: AiAuditWriter;  // ← new
  log?: Logger; metrics?: MetricsCollector; tracer?: Tracer
}): VikingBridge | null {
  if (settings.viking?.enabled && settings.viking.url && settings.viking.apiKey) {
    return new VikingBridge(settings.viking.url, settings.viking.apiKey, {
      agentId: settings.viking.agentId,
      maxRequestsPerHour: settings.viking.maxRequestsPerHour,
      audit: opts?.audit,   // ← new
      ...opts,
    })
  }
  return null
}
```

### Step 2: Wire up daemon.ts

- [ ] In `src/daemon.ts`, after Database creation, before initViking:

```typescript
import { AiAuditWriter, AiAuditQuery } from './core/ai-audit.js'
import { DEFAULT_AI_AUDIT_CONFIG } from './core/config.js'

// Resolve audit config
const auditConfig = { ...DEFAULT_AI_AUDIT_CONFIG, ...settings.aiAudit }
const audit = new AiAuditWriter(db.getRawDb(), auditConfig)
const auditQuery = new AiAuditQuery(db.getRawDb())

// Audit startup cleanup
audit.cleanup(auditConfig.retentionDays)
```

- [ ] Pass `audit` to all callers:

```typescript
const vikingBridge = initViking(settings, { audit, log, metrics, tracer })
const titleGenerator = new TitleGenerator({ ...titleConfig, audit })
// For EmbeddingClient — pass audit to createEmbeddingClient opts
// For AutoSummaryManager — pass audit in the onTrigger callback
// For createApp — pass audit, auditQuery
```

- [ ] Hook audit cleanup into the hourly maintenance loop (~line 386):

```typescript
// Inside the existing hourly timer callback, add:
audit.cleanup(auditConfig.retentionDays)
```

- [ ] Hook daemon stdout events:

```typescript
audit.on('entry', (entry: any) => {
  emit({
    event: 'ai_audit',
    id: entry.id,
    caller: entry.caller,
    operation: entry.operation,
    model: entry.model,
    durationMs: entry.durationMs,
    promptTokens: entry.promptTokens,
  })
})
```

### Step 3: Wire up index.ts (MCP mode)

- [ ] Similar to daemon but simpler — no hourly cleanup, no stdout events:

```typescript
const auditConfig = { ...DEFAULT_AI_AUDIT_CONFIG, ...fileSettings.aiAudit }
const audit = new AiAuditWriter(db.getRawDb(), auditConfig)
```

Pass to initViking and EmbeddingClient.

### Step 4: Run full test suite

- [ ] Run: `npm run build && npm test` — Expected: ALL PASS (687+ tests)
- [ ] Commit: `feat(ai-audit): wire audit into daemon, MCP server, and bootstrap`

---

## Verification Checklist

After all tasks are complete:

- [ ] `npm run build` — clean compilation
- [ ] `npm test` — all tests pass (687+ existing + new audit tests)
- [ ] Start daemon manually: `npm run dev` — verify no crash, check stderr for audit-related logs
- [ ] If Viking is configured: trigger a title generation or search, then query `GET /api/ai/audit` to verify records appear
- [ ] Check `GET /api/ai/stats` returns sensible aggregated data
- [ ] Check `GET /api/viking/observer` returns Viking status (if Viking available)
- [ ] Verify bearer auth: `curl localhost:3035/api/ai/audit` should return 401 if token configured
