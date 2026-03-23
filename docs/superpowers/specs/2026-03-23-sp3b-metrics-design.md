# SP3b: Systematic Metrics Collection

**Date**: 2026-03-23
**Status**: Implemented
**Scope**: Gap #5 (metrics not systematic) from observability gap analysis. Alerting deferred to a separate spec.

## Decisions

| Decision | Choice |
|----------|--------|
| Scope | Metrics collection only; alerting rules deferred |
| Process health | Memory + CPU, sampled every 60s |
| DB query timing | Proxy-based wrapper on `raw.prepare()`, auto-times all queries |
| Metrics vs Traces | Dual-write: metrics for trends/rollup, traces for single-call drill-down |
| Swift UI | No changes; new metrics auto-appear in existing PerformanceView |
| Approach | Direct metrics calls in each module, no intermediate abstraction |

## 1. New Metrics

12 new metrics across 6 areas:

### DB Queries
| Metric | Type | Tags | Sampling | Description |
|--------|------|------|----------|-------------|
| `db.query_ms` | histogram | `{method: 'run'\|'get'\|'all'}` | 10% | Per-statement execution time |

Note: `db.query_count` is NOT needed — the `metrics_hourly` rollup's `count` field on the histogram already provides QPS data.

### Search Sub-Queries
| Metric | Type | Tags | Sampling | Description |
|--------|------|------|----------|-------------|
| `search.fts_ms` | histogram | — | 100% | FTS sub-query latency |
| `search.vector_ms` | histogram | — | 100% | Vector search sub-query latency |
| `search.viking_ms` | histogram | — | 100% | Viking find sub-query latency |

### Indexer Adapter Breakdown
| Metric | Type | Tags | Sampling | Description |
|--------|------|------|----------|-------------|
| `indexer.adapter_parse_ms` | histogram | `{source}` | 100% | `parseSessionInfo()` latency |
| `indexer.adapter_stream_ms` | histogram | `{source}` | 100% | `streamMessages()` full iteration latency |

Note: `adapter.detect()` is excluded — it's just `existsSync()` for most adapters (microsecond-level). Recording it would produce high-volume low-value noise (13 adapters × every indexAll call).

### HTTP Errors
| Metric | Type | Tags | Sampling | Description |
|--------|------|------|----------|-------------|
| `http.error_count` | counter | `{status, path}` | 100% | HTTP 4xx/5xx response count |

### Process Health
| Metric | Type | Tags | Sampling | Description |
|--------|------|------|----------|-------------|
| `process.heap_mb` | gauge | — | 100% | `process.memoryUsage().heapUsed` in MB |
| `process.rss_mb` | gauge | — | 100% | `process.memoryUsage().rss` in MB |
| `process.cpu_user_ms` | gauge | — | 100% | Cumulative user CPU in ms |
| `process.cpu_system_ms` | gauge | — | 100% | Cumulative system CPU in ms |

### Error Tracking
| Metric | Type | Tags | Sampling | Description |
|--------|------|------|----------|-------------|
| `error.count` | counter | `{module}` | 100% | Incremented on every `logger.error()` call |

**Total**: 12 new metrics. Existing 12 unchanged (`http.requests`, `http.duration_ms`, `daemon.uptime_s`, `indexer.session_duration_ms`, `indexer.sessions_indexed`, `viking.circuit_breaker_opens`, `viking.push_duration_ms`, `viking.pushes`, `viking.find_duration_ms`, `viking.queries`, `search.duration_ms`, `search.queries`).

## 2. DB Query Auto-Timing

### Proxy-based wrapper on `Database`

`better-sqlite3` Statement objects are native C++ bindings — direct property assignment (`stmt.run = wrapped`) is unreliable on native objects. Use `Proxy` to intercept `run/get/all` at the JS layer.

#### New method on `Database` class: `setMetrics(metrics)`

```typescript
// In src/core/db.ts
private metrics?: MetricsCollector

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
          const result = (target as any)[prop].apply(target, args)  // explicit this binding for native C++ methods
          metrics.histogram('db.query_ms', performance.now() - start, { method: prop as string })
          return result
        }
      }
      return (target as any)[prop]
    }
  }) as BetterSqlite3.Statement
}
```

#### Activation

- `src/daemon.ts`: call `db.setMetrics(metrics)` after creating both `db` and `metrics`
- `src/index.ts` (MCP server): no `setMetrics` call — MCP mode has no MetricsCollector, zero overhead
- Sampling: daemon.ts currently has `sampleRates: { 'db.query_duration_ms': 0.1 }`. Rename the key to `'db.query_ms': 0.1` to match the new metric name

#### `performance.now()` availability

`performance.now()` is globally available in Node 16+ — no import needed. All timing in this spec uses `performance.now()` for sub-ms precision (not `Date.now()`).

#### Why Proxy, not direct assignment

`better-sqlite3` Statement's `run/get/all` are native C++ methods on the prototype. They may be non-configurable or non-writable properties. `Proxy` operates at the JS meta-object level and works regardless of the target's property descriptors.

#### What about `LogWriter`, `TraceWriter`, `MetricsCollector` themselves?

These use `db.prepare()` internally and will get timed automatically once `setMetrics()` is called. This is intentional — observability writes are DB operations too. The 10% sampling prevents self-referential overhead explosion.

## 3. Search Sub-Query Timing

### Implementation in `src/tools/search.ts`

`SearchDeps` already has `metrics?: MetricsCollector` (line 15). No interface change needed.

Add timing around each parallel sub-query:

```typescript
// FTS
const ftsStart = performance.now()
// ... existing FTS query ...
deps.metrics?.histogram('search.fts_ms', performance.now() - ftsStart)

// Vector
const vecStart = performance.now()
// ... existing vector query ...
deps.metrics?.histogram('search.vector_ms', performance.now() - vecStart)

// Viking
const vikStart = performance.now()
// ... existing Viking find ...
deps.metrics?.histogram('search.viking_ms', performance.now() - vikStart)
```

These run in `Promise.all` — each timer measures its own branch independently, not wall-clock time.

Use `performance.now()` (not `Date.now()`) for sub-ms precision. Node 16+ provides `performance` globally — no import needed.

Existing `search.duration_ms` (total) and `search.queries` (count) remain unchanged.

## 4. Indexer Adapter Breakdown

### Implementation in `src/core/indexer.ts`

`Indexer` already has `this.metrics` field (constructor accepts `metrics?: MetricsCollector`).

Two timing points in `indexAll()` and `indexFile()`:

```typescript
// 1) adapter.parseSessionInfo() — in per-file processing
const parseStart = performance.now()
const info = await adapter.parseSessionInfo(filePath)
this.metrics?.histogram('indexer.adapter_parse_ms', performance.now() - parseStart, { source: adapter.name })

// 2) adapter.streamMessages() — wrapping the for-await loop
const streamStart = performance.now()
for await (const msg of adapter.streamMessages(filePath)) {
  // ... existing accumulation unchanged ...
}
this.metrics?.histogram('indexer.adapter_stream_ms', performance.now() - streamStart, { source: adapter.name })
```

`indexFile()` gets the same parse + stream timing (no detect — adapter is already known).

Note: in `indexAll()`, two dedup checks (`isIndexed()`) run before parse/stream. Files that pass dedup are skipped — their parse/stream metrics are not recorded. This is correct: deduped files do no parsing work. When analyzing data, metric counts for parse/stream will be lower than `listSessionFiles()` yields.

## 5. HTTP Error Count

### Implementation in `src/web.ts`

In the existing metrics middleware (after `await next()`):

```typescript
if (c.res.status >= 400) {
  metricsRef.counter('http.error_count', 1, {
    status: String(c.res.status),
    path: c.req.path.split('/').slice(0, 3).join('/')
  })
}
```

Path truncation to 3 segments is consistent with existing `http.requests` counter and SP3a tracing middleware.

## 6. Process Health

### Implementation in `src/daemon.ts`

Added to the existing 60s uptime timer:

```typescript
const uptimeTimer = setInterval(() => {
  metrics.gauge('daemon.uptime_s', Math.floor((Date.now() - daemonStartTime) / 1000))

  // Process health
  const mem = process.memoryUsage()
  metrics.gauge('process.heap_mb', Math.round(mem.heapUsed / 1048576 * 10) / 10)
  metrics.gauge('process.rss_mb', Math.round(mem.rss / 1048576 * 10) / 10)
  const cpu = process.cpuUsage()
  metrics.gauge('process.cpu_user_ms', Math.round(cpu.user / 1000))
  metrics.gauge('process.cpu_system_ms', Math.round(cpu.system / 1000))
}, 60000)
```

Notes:
- `cpuUsage()` returns cumulative microseconds since process start. Stored as cumulative ms. Trend analysis via `metrics_hourly` rollup sees the growth rate.
- Memory values rounded to 1 decimal place (0.1 MB precision).

## 7. Error Count via Logger

### Implementation in `src/core/logger.ts`

Extend `LoggerOpts` with `metrics?: MetricsCollector`. In the `log()` closure, after sanitize + write:

```typescript
if (level === 'error' && metrics) {
  metrics.counter('error.count', 1, { module })
}
```

Where `metrics` is captured from `opts.metrics` in the `createLogger()` closure, like `stderrJson` and `writer`.

`child()` implementation (`createLogger(module, { ...opts, ...extra })`) automatically inherits the `metrics` instance. This works because `extra` is typed as `{ traceId?: string; spanId?: string }` — it cannot contain `metrics`, so `...opts` (which has `metrics`) is never overridden by `...extra`.

#### Activation

- `src/daemon.ts`: `createLogger('daemon', { writer: logWriter, ..., metrics })`
- `src/index.ts`: MCP server has no MetricsCollector, so `metrics` is undefined — no overhead

## 8. Test Strategy

### Extended: `tests/core/metrics.test.ts`

- `setMetrics()` enables auto-timing: `prepare().run()` records `db.query_ms` histogram
- `prepare().get()` and `prepare().all()` also timed
- Without `setMetrics()`: prepare returns unwrapped statement, no metrics recorded
- Sampling respects `sampleRates` config (10% for `db.query_ms`)
- Proxy correctly forwards all other Statement properties (`bind`, `columns`, etc.)

### Extended: `tests/tools/search.test.ts`

- With metrics in SearchDeps: `search.fts_ms`, `search.vector_ms`, `search.viking_ms` recorded
- Without metrics: no error, graceful no-op

### Extended: `tests/core/logger.test.ts`

- Logger with metrics: `log.error()` increments `error.count` counter with `{module}` tag
- Logger without metrics: `log.error()` works normally, no counter
- Child logger inherits metrics from parent

### Not new test files — all extend existing.

## 9. Files Changed

### Modified files
| File | Changes |
|------|---------|
| `src/core/db.ts` | Add `metrics` field, `setMetrics()`, `wrapStatement()` with Proxy |
| `src/core/logger.ts` | Add `metrics` to `LoggerOpts`, `error.count` counter in `log()` |
| `src/tools/search.ts` | Add 3 sub-query timing calls (interface already has `metrics`) |
| `src/core/indexer.ts` | Add detect/parse/stream timing calls (already has `this.metrics`) |
| `src/web.ts` | Add `http.error_count` counter in metrics middleware |
| `src/daemon.ts` | Add `db.setMetrics(metrics)`, process health gauges in uptime timer, pass `metrics` to logger, **rename sampleRates key** from `'db.query_duration_ms'` to `'db.query_ms'` |
| `src/index.ts` | No change — MCP mode has no MetricsCollector; SearchDeps.metrics stays undefined |
| `tests/core/metrics.test.ts` | DB Proxy wrapper tests |
| `tests/tools/search.test.ts` | Sub-query timing tests |
| `tests/core/logger.test.ts` | Error count tests |

### No new files.

## 10. Out of Scope

- **Alerting rules / thresholds** — deferred to SP3b-alerting (needs metrics data first)
- **Swift UI changes** — new metrics auto-appear in existing PerformanceView
- **Prometheus export / `/api/metrics` endpoint** — not needed for local desktop app
- **Per-endpoint HTTP latency breakdown** — existing `http.duration_ms` + path tag is sufficient
- **Viking push failure rate / retry counts** — Viking bridge already has circuit breaker + push/find metrics
