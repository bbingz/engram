# SP3b: Systematic Metrics Collection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 12 new metrics across DB queries, search sub-queries, indexer adapter breakdown, HTTP errors, process health, and error tracking — filling the observability gap for systematic metrics collection.

**Architecture:** Direct `metrics.histogram/counter/gauge` calls at each instrumentation point. DB auto-timing via Proxy on `better-sqlite3` Statement. No new abstractions — extends existing `MetricsCollector` infrastructure.

**Tech Stack:** Node.js `performance.now()`, `Proxy`, existing `MetricsCollector` + Vitest

**Spec:** `docs/superpowers/specs/2026-03-23-sp3b-metrics-design.md`

---

## File Map

### Modified files
| File | Responsibility |
|------|---------------|
| `src/core/db.ts` | Add `setMetrics()` + Proxy-based `wrapStatement()` for DB auto-timing |
| `src/core/logger.ts` | Add `metrics` to `LoggerOpts`, `error.count` counter on error level |
| `src/tools/search.ts` | Add FTS/vector/Viking sub-query timing |
| `src/core/indexer.ts` | Add parse/stream adapter timing |
| `src/web.ts` | Add `http.error_count` counter |
| `src/daemon.ts` | Call `db.setMetrics()`, add process health gauges, pass metrics to logger, rename sampleRates key |
| `tests/core/metrics.test.ts` | DB Proxy wrapper tests |
| `tests/tools/search.test.ts` | Sub-query timing tests |
| `tests/core/logger.test.ts` | Error count tests |

---

### Task 1: DB Query Auto-Timing via Proxy

**Files:**
- Modify: `src/core/db.ts`
- Test: `tests/core/metrics.test.ts` (extend existing)

- [ ] **Step 1: Write failing tests**

Append to `tests/core/metrics.test.ts`:

```typescript
import { Database } from '../../src/core/db.js'

describe('DB query auto-timing', () => {
  let db: Database
  let metricsDb: Database
  let collector: MetricsCollector

  beforeEach(() => {
    db = new Database(':memory:')
    metricsDb = new Database(':memory:')
    collector = new MetricsCollector(metricsDb.raw, { flushIntervalMs: 0 })
  })
  afterEach(() => { db.close(); metricsDb.close() })

  it('records db.query_ms histogram after setMetrics', () => {
    db.setMetrics(collector)
    db.raw.prepare('SELECT 1').get()
    collector.flush()
    const rows = metricsDb.raw.prepare("SELECT * FROM metrics WHERE name = 'db.query_ms'").all() as any[]
    expect(rows.length).toBeGreaterThan(0)
    expect(rows[0].type).toBe('histogram')
    expect(JSON.parse(rows[0].tags).method).toBe('get')
  })

  it('times run() method', () => {
    db.setMetrics(collector)
    db.raw.prepare("INSERT INTO logs (level, module, message, source) VALUES ('info', 'test', 'hello', 'daemon')").run()
    collector.flush()
    const rows = metricsDb.raw.prepare("SELECT * FROM metrics WHERE name = 'db.query_ms'").all() as any[]
    expect(rows.length).toBeGreaterThan(0)
    expect(JSON.parse(rows[0].tags).method).toBe('run')
  })

  it('times all() method', () => {
    db.setMetrics(collector)
    db.raw.prepare('SELECT * FROM sessions LIMIT 1').all()
    collector.flush()
    const rows = metricsDb.raw.prepare("SELECT * FROM metrics WHERE name = 'db.query_ms'").all() as any[]
    expect(rows.length).toBeGreaterThan(0)
    expect(JSON.parse(rows[0].tags).method).toBe('all')
  })

  it('does not record metrics without setMetrics', () => {
    db.raw.prepare('SELECT 1').get()
    // No collector to flush — just verify no error
    expect(true).toBe(true)
  })

  it('forwards non-timed properties unchanged', () => {
    db.setMetrics(collector)
    const stmt = db.raw.prepare('SELECT 1 as val')
    // .columns() should still work via Proxy passthrough
    const cols = stmt.columns()
    expect(cols[0].name).toBe('val')
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/core/metrics.test.ts`
Expected: FAIL — `db.setMetrics is not a function`

- [ ] **Step 3: Implement setMetrics + wrapStatement in db.ts**

Add import at top of `src/core/db.ts`:
```typescript
import type { MetricsCollector } from './metrics.js'
```

Add `metrics` field to `Database` class — after `noiseFilter` declaration (search for `noiseFilter: NoiseFilter`):
```typescript
private metrics?: MetricsCollector
```

Add `setMetrics()` method and `wrapStatement()` private method — place after the `constructor` (search for the closing `}` of `constructor`, before `private migrate()`):

```typescript
setMetrics(metrics: MetricsCollector): void {
  this.metrics = metrics
  const self = this
  const originalPrepare = this.db.prepare.bind(this.db)
  this.db.prepare = ((sql: string) => {
    const stmt = originalPrepare(sql)
    return self.wrapStatement(stmt)
  }) as typeof this.db.prepare
}

private wrapStatement(stmt: BetterSqlite3.Statement): BetterSqlite3.Statement {
  if (!this.metrics) return stmt
  const metrics = this.metrics
  return new Proxy(stmt, {
    get(target, prop) {
      if (prop === 'run' || prop === 'get' || prop === 'all') {
        return (...args: any[]) => {
          const start = performance.now()
          const result = (target as any)[prop].apply(target, args)
          metrics.histogram('db.query_ms', performance.now() - start, { method: prop as string })
          return result
        }
      }
      return (target as any)[prop]
    }
  }) as BetterSqlite3.Statement
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/core/metrics.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/db.ts tests/core/metrics.test.ts
git commit -m "feat(metrics): add Proxy-based DB query auto-timing"
```

---

### Task 2: Error Count via Logger

**Files:**
- Modify: `src/core/logger.ts`
- Test: `tests/core/logger.test.ts` (extend existing)

- [ ] **Step 1: Write failing tests**

Append to `tests/core/logger.test.ts`:

```typescript
import { MetricsCollector } from '../../src/core/metrics.js'

describe('logger error count', () => {
  let db: Database
  let writer: LogWriter
  let metricsDb: Database
  let collector: MetricsCollector

  beforeEach(() => {
    db = new Database(':memory:')
    writer = new LogWriter(db.raw)
    metricsDb = new Database(':memory:')
    collector = new MetricsCollector(metricsDb.raw, { flushIntervalMs: 0 })
  })
  afterEach(() => { db.close(); metricsDb.close() })

  it('increments error.count on log.error()', () => {
    const log = createLogger('mymod', { writer, level: 'info', stderrJson: false, metrics: collector })
    log.error('something broke', {}, new Error('boom'))
    collector.flush()
    const rows = metricsDb.raw.prepare("SELECT * FROM metrics WHERE name = 'error.count'").all() as any[]
    expect(rows).toHaveLength(1)
    expect(rows[0].type).toBe('counter')
    expect(JSON.parse(rows[0].tags).module).toBe('mymod')
  })

  it('does not increment on info/warn', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: false, metrics: collector })
    log.info('hello')
    log.warn('careful')
    collector.flush()
    const rows = metricsDb.raw.prepare("SELECT * FROM metrics WHERE name = 'error.count'").all() as any[]
    expect(rows).toHaveLength(0)
  })

  it('works without metrics (no error)', () => {
    const log = createLogger('test', { writer, level: 'info', stderrJson: false })
    log.error('no collector')
    // Just verify no crash
    const row = db.raw.prepare('SELECT message FROM logs').get() as any
    expect(row.message).toContain('no collector')
  })

  it('child logger inherits metrics from parent', () => {
    const log = createLogger('parent', { writer, level: 'info', stderrJson: false, metrics: collector })
    const child = log.child({ traceId: 'child-trace' })
    child.error('child error')
    collector.flush()
    const rows = metricsDb.raw.prepare("SELECT * FROM metrics WHERE name = 'error.count'").all() as any[]
    expect(rows).toHaveLength(1)
    expect(JSON.parse(rows[0].tags).module).toBe('parent')
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/core/logger.test.ts`
Expected: FAIL — `metrics` not in LoggerOpts

- [ ] **Step 3: Modify logger.ts**

Add import at top of `src/core/logger.ts` (after existing imports):
```typescript
import type { MetricsCollector } from './metrics.js'
```

Add `metrics` to `LoggerOpts` — search for `stderrJson?: boolean`, add after:
```typescript
metrics?: MetricsCollector
```

In `createLogger()`, capture metrics — search for `const stderrJson = opts.stderrJson ?? true`, add after:
```typescript
const metrics = opts.metrics
```

In the `log()` function, after the `if (stderrJson)` block (search for the closing `}` of `if (stderrJson) {`), add:
```typescript
if (level === 'error' && metrics) {
  metrics.counter('error.count', 1, { module })
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/core/logger.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/logger.ts tests/core/logger.test.ts
git commit -m "feat(metrics): add error.count counter to logger"
```

---

### Task 3: Search Sub-Query Timing

**Files:**
- Modify: `src/tools/search.ts`
- Test: `tests/tools/search.test.ts` (extend existing)

- [ ] **Step 1: Write failing test**

Append to `tests/tools/search.test.ts`. The test needs a mock MetricsCollector that captures calls. Check how existing tests set up `SearchDeps` and follow the same pattern:

```typescript
describe('search sub-query metrics', () => {
  let db: Database
  let metricsDb: Database
  let collector: MetricsCollector

  beforeEach(() => {
    db = new Database(':memory:')
    metricsDb = new Database(':memory:')
    collector = new MetricsCollector(metricsDb.raw, { flushIntervalMs: 0 })
    // Seed a session so FTS has something to search
    db.raw.prepare(`INSERT INTO sessions (id, source, file_path, start_time, message_count, size_bytes, tier)
      VALUES ('s1', 'claude-code', '/tmp/test.jsonl', '2026-01-01T00:00:00Z', 1, 100, 'normal')`).run()
    db.raw.prepare(`INSERT INTO sessions_fts (rowid, content) VALUES (1, 'test search content')`).run()
  })
  afterEach(() => { db.close(); metricsDb.close() })

  it('records search.fts_ms when FTS runs', async () => {
    await handleSearch(db, { query: 'test search content' }, { metrics: collector })
    collector.flush()
    const rows = metricsDb.raw.prepare("SELECT * FROM metrics WHERE name = 'search.fts_ms'").all() as any[]
    expect(rows.length).toBeGreaterThan(0)
    expect(rows[0].type).toBe('histogram')
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/tools/search.test.ts`
Expected: FAIL — no `search.fts_ms` metric recorded

- [ ] **Step 3: Add timing to search.ts**

In `src/tools/search.ts`, add timing to each of the 3 parallel sub-queries inside `Promise.all`. Make surgical edits:

**FTS block** (search for `if (mode !== 'semantic' && params.query.length >= 3)`):
Add `const ftsStart = performance.now()` as the first line inside the `if` block, and `deps.metrics?.histogram('search.fts_ms', performance.now() - ftsStart)` right before `ftsSpan?.end()`.

**Vector block** (search for `if (mode !== 'keyword' && params.query.length >= 2`):
Add `const vecStart = performance.now()` as the first line inside the `if` block, and `deps.metrics?.histogram('search.vector_ms', performance.now() - vecStart)` right before `vecSpan?.setAttribute('resultCount'`.

**Viking block** (search for `if (deps.viking && vikingAvailable)`):
Add `const vikStart = performance.now()` as the first line inside the `if` block, and `deps.metrics?.histogram('search.viking_ms', performance.now() - vikStart)` right before `vikingSpan?.setAttribute('resultCount'`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/tools/search.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add src/tools/search.ts tests/tools/search.test.ts
git commit -m "feat(metrics): add FTS/vector/Viking sub-query timing to search"
```

---

### Task 4: Indexer Adapter Parse + Stream Timing

**Files:**
- Modify: `src/core/indexer.ts`

- [ ] **Step 1: Add parse timing to indexAll()**

In `src/core/indexer.ts`, in the `indexAll()` method, search for `const info = await adapter.parseSessionInfo(filePath)` (around line 222). Wrap it with timing:

```typescript
// Before:
const info = await adapter.parseSessionInfo(filePath)

// After:
const parseStart = performance.now()
const info = await adapter.parseSessionInfo(filePath)
if (info) this.metrics?.histogram('indexer.adapter_parse_ms', performance.now() - parseStart, { source: adapter.name })
```

Note: only record if `info` is not null — if parseSessionInfo returns null, we return early anyway.

- [ ] **Step 2: Add stream timing to indexAll()**

Search for `for await (const msg of adapter.streamMessages(filePath))` in `indexAll()` (around line 244). Wrap the loop:

```typescript
// Before:
for await (const msg of adapter.streamMessages(filePath)) {
  // ...
}

// After:
const streamStart = performance.now()
for await (const msg of adapter.streamMessages(filePath)) {
  // ... existing accumulation unchanged ...
}
this.metrics?.histogram('indexer.adapter_stream_ms', performance.now() - streamStart, { source: adapter.name })
```

- [ ] **Step 3: Add same timing to indexFile()**

In `indexFile()`, apply the same pattern:

Search for `const info = await adapter.parseSessionInfo(filePath)` in `indexFile()` (around line 364). Wrap:
```typescript
const parseStart = performance.now()
const info = await adapter.parseSessionInfo(filePath)
if (info) this.metrics?.histogram('indexer.adapter_parse_ms', performance.now() - parseStart, { source: adapter.name })
```

Search for `for await (const msg of adapter.streamMessages(filePath))` in `indexFile()` (around line 377). Wrap:
```typescript
const streamStart = performance.now()
for await (const msg of adapter.streamMessages(filePath)) {
  // ... existing accumulation unchanged ...
}
this.metrics?.histogram('indexer.adapter_stream_ms', performance.now() - streamStart, { source: adapter.name })
```

- [ ] **Step 4: Build and run tests**

Run: `npm run build && npm test`
Expected: Build clean, all tests pass

- [ ] **Step 5: Commit**

```bash
git add src/core/indexer.ts
git commit -m "feat(metrics): add adapter parse/stream timing to indexer"
```

---

### Task 5: HTTP Error Count + Process Health + Daemon Wiring

**Files:**
- Modify: `src/web.ts`
- Modify: `src/daemon.ts`

- [ ] **Step 1: Add http.error_count to web.ts**

In `src/web.ts`, in the metrics middleware (search for `metricsRef.histogram('http.duration_ms'`), add after the histogram line:

```typescript
if (c.res.status >= 400) {
  metricsRef.counter('http.error_count', 1, {
    status: String(c.res.status),
    path: c.req.path.split('/').slice(0, 3).join('/')
  })
}
```

- [ ] **Step 2: Add process health gauges to daemon.ts**

In `src/daemon.ts`, find the uptime timer (search for `metrics.gauge('daemon.uptime_s'`). Add process health after the uptime gauge line:

```typescript
// Process health
const mem = process.memoryUsage()
metrics.gauge('process.heap_mb', Math.round(mem.heapUsed / 1048576 * 10) / 10)
metrics.gauge('process.rss_mb', Math.round(mem.rss / 1048576 * 10) / 10)
const cpu = process.cpuUsage()
metrics.gauge('process.cpu_user_ms', Math.round(cpu.user / 1000))
metrics.gauge('process.cpu_system_ms', Math.round(cpu.system / 1000))
```

- [ ] **Step 3: Call db.setMetrics() in daemon.ts**

Search for `const log = createLogger('daemon'` in daemon.ts. Add right before it:

```typescript
db.setMetrics(metrics)
```

- [ ] **Step 4: Rename sampleRates key**

Search for `'db.query_duration_ms': 0.1` in daemon.ts (around line 57). Change to:

```typescript
'db.query_ms': 0.1
```

- [ ] **Step 5: Pass metrics to logger**

Change the `createLogger` call (search for `createLogger('daemon', {`). Add `metrics`:

```typescript
const log = createLogger('daemon', { writer: logWriter, level: settings.observability?.logLevel ?? 'info', stderrJson: true, metrics })
```

- [ ] **Step 6: Build and run tests**

Run: `npm run build && npm test`
Expected: Build clean, all tests pass

- [ ] **Step 7: Commit**

```bash
git add src/web.ts src/daemon.ts
git commit -m "feat(metrics): add HTTP error count, process health, daemon wiring"
```

---

### Task 6: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `npm test`
Expected: All tests pass

- [ ] **Step 2: Build check**

Run: `npm run build`
Expected: Clean build, no TypeScript errors

- [ ] **Step 3: Verify new metric names in code**

Run a quick grep to confirm all 12 new metrics are present:

```bash
grep -rn "db\.query_ms\|search\.fts_ms\|search\.vector_ms\|search\.viking_ms\|indexer\.adapter_parse_ms\|indexer\.adapter_stream_ms\|http\.error_count\|process\.heap_mb\|process\.rss_mb\|process\.cpu_user_ms\|process\.cpu_system_ms\|error\.count" src/
```

Expected: All 12 metric names found in expected files.

- [ ] **Step 4: Mark spec as implemented**

```bash
sed -i '' 's/^**Status**: Draft/**Status**: Implemented/' docs/superpowers/specs/2026-03-23-sp3b-metrics-design.md
git add docs/superpowers/specs/2026-03-23-sp3b-metrics-design.md
git commit -m "docs: mark SP3b spec as implemented"
```
