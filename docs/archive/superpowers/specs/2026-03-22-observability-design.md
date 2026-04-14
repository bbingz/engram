# Engram Observability System Design

**Date**: 2026-03-22
**Status**: Draft
**Scope**: TypeScript daemon + macOS SwiftUI app

## Problem

Engram has grown to 25+ source files in TypeScript and 86 Swift files. Current observability is ad-hoc: 24 scattered console calls, no centralized logger, 296 try/catch blocks that mostly swallow errors silently, no performance metrics, no request correlation. When bugs occur, developers must manually reproduce and guess at root causes.

## Goals

1. Centralized, structured logging across both TS and Swift
2. Request correlation (traceId) across daemon ↔ Swift boundary
3. Performance instrumentation on critical paths
4. Built-in Observability UI page in Engram main window
5. CLI diagnostic tool for AI-assisted debugging (dev only)
6. Eliminate silent error swallowing

## Non-Goals

- External log aggregation (Datadog, Splunk) — deferred
- User-facing log export/upload — deferred
- OpenTelemetry SDK integration — deferred (but interface-compatible for future)
- Alerting/paging system — Engram is a local app

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                  Engram App (Swift)                   │
│  ┌───────────┐  ┌──────────────────────────────┐     │
│  │ os_log    │  │ Observability Page            │     │
│  │ (local)   │  │ (logs, traces, metrics)       │     │
│  └───────────┘  └──────────┬───────────────────┘     │
│                            │ reads (GRDB read pool)  │
│                            ▼                         │
│  ┌─────────────────────────────────────────────────┐ │
│  │        SQLite: logs / traces / metrics          │ │
│  │        (WAL mode, single writer: daemon)        │ │
│  └─────────────────────────────────────────────────┘ │
│        ▲                         ▲                   │
│        │ writes                  │ reads             │
│  ┌─────┴──────────────────┐      │                   │
│  │  Daemon (TypeScript)   │      │                   │
│  │  ┌────────┐ ┌────────┐ │      │                   │
│  │  │ Logger │ │ Tracer │ │      │                   │
│  │  │  +buf  │ │        │ │      │                   │
│  │  └────────┘ └────────┘ │      │                   │
│  │  ┌────────────────────┐│      │                   │
│  │  │ Metrics (in-mem    ││      │                   │
│  │  │  buffer, 5s flush) ││      │                   │
│  │  └────────────────────┘│      │                   │
│  └────────────────────────┘      │                   │
└──────────────────────────────────┘                   │
         ▲                                             │
         │ CLI queries (read-only, WAL snapshot) ───────┘
    ┌────┴────┐
    │engram   │
    │logs/    │
    │traces/  │
    │health   │
    └─────────┘
```

### SQLite Concurrency Model

**Single writer: daemon only.** All observability data (logs, traces, metrics) is written exclusively by the daemon process. This avoids multi-process write contention entirely.

- **Swift app**: Writes only to `os_log` (local Console.app). Does NOT write to SQLite observability tables. Swift's `EngramLogger` is a read-through wrapper — it logs to `os_log` for local debugging but does not persist to the shared SQLite. If Swift-side log persistence is needed later, Swift sends log events to daemon via existing HTTP API (`POST /api/log`), and daemon writes them with `source: 'app'`.
- **Daemon (TS)**: Sole writer to `logs`, `traces`, `metrics`, `metrics_hourly` tables.
- **CLI**: Read-only. Opens SQLite in `SQLITE_OPEN_READONLY` mode. WAL mode ensures readers never block the writer and always see a consistent snapshot.
- **DB is already in WAL mode** (`PRAGMA journal_mode=WAL` set in existing `db.ts:migrate()`).

**CLI during rotation**: When daemon runs log rotation (`DELETE FROM logs WHERE ts < ?`), CLI may briefly see stale data mid-deletion. This is acceptable — CLI queries are diagnostic, not transactional. No mitigation needed.

---

## Layer 1: Unified Logger

### TypeScript Logger (`src/core/logger.ts`)

A lightweight, zero-dependency logger. No pino/winston — matches the project's minimal dependency approach.

```typescript
interface LogEntry {
  ts: string;          // ISO 8601
  level: 'debug' | 'info' | 'warn' | 'error';
  module: string;      // e.g. 'indexer', 'viking', 'search', 'adapter.claude'
  traceId?: string;    // correlation ID
  spanId?: string;     // current span
  message: string;
  data?: Record<string, unknown>;  // structured payload
  error?: {
    name: string;
    message: string;
    stack?: string;
    code?: string;
  };
}
```

**API**:
```typescript
const log = createLogger('indexer');

log.info('session indexed', { sessionId, messageCount: 42 });
log.error('parse failed', { filePath }, err);
log.debug('skipping stale file', { path, age: '3d' });
```

**Output targets** (configurable):
- SQLite `logs` table (primary, always on)
- stderr (dev mode, controlled by `ENGRAM_LOG_LEVEL` env var)
- daemon event stream (error/warn only, for Swift to display)

**Log levels**:
- `debug`: Verbose, dev only. Off by default.
- `info`: Normal operations (session indexed, search completed).
- `warn`: Recoverable issues (Viking timeout, fallback to FTS).
- `error`: Failures requiring attention (DB error, adapter crash).

**Debug log rate limiting**: When `debug` level is enabled, high-frequency modules (`watcher`, `adapter.*`) are rate-limited to **max 100 entries/minute** per module. Excess entries are dropped with a periodic summary log: `"[watcher] 342 debug messages suppressed in last 60s"`. This prevents runaway log volume when debug is left on during heavy file-watching or adapter scanning. Rate limiting does NOT apply to `info`/`warn`/`error` levels.

**Configuration** (`~/.engram/settings.json`):
```json
{
  "observability": {
    "logLevel": "info",
    "logRetentionDays": 7,
    "traceEnabled": true,
    "metricsEnabled": true
  }
}
```

### Swift Logger (`macos/Engram/Core/EngramLogger.swift`)

Wraps `os_log` with consistent interface. Does NOT write to SQLite (daemon is sole writer — see Concurrency Model above).

```swift
enum LogModule: String {
    case daemon, database, ui, mcp, indexer
}

struct EngramLogger {
    static func info(_ message: String, module: LogModule, data: [String: Sendable]? = nil)
    static func warn(_ message: String, module: LogModule, data: [String: Sendable]? = nil)
    static func error(_ message: String, module: LogModule, error: Error? = nil)
    static func debug(_ message: String, module: LogModule, data: [String: Sendable]? = nil)
}
```

- Writes to `os_log` (Console.app) with subsystem `com.engram.app` and per-module category
- Optionally forwards error/warn to daemon via `POST /api/log` for SQLite persistence (fire-and-forget, non-blocking)
- **Anti-loop guard**: If the `POST /api/log` call itself fails, the failure is logged ONLY to `os_log`, never re-forwarded. Internally, EngramLogger tracks a `isForwarding` flag to break the cycle. Errors with module `.daemon` (log forwarding infrastructure) are never forwarded.
- Uses `Codable` structs for `data` parameter (not `[String: Any]`) to ensure clean JSON serialization

### SQLite Schema

```sql
CREATE TABLE IF NOT EXISTS logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    level TEXT NOT NULL CHECK (level IN ('debug', 'info', 'warn', 'error')),
    module TEXT NOT NULL,
    trace_id TEXT,
    span_id TEXT,
    message TEXT NOT NULL,
    data TEXT,          -- JSON
    error_name TEXT,
    error_message TEXT,
    error_stack TEXT,
    source TEXT NOT NULL CHECK (source IN ('daemon', 'app'))
);

CREATE INDEX idx_logs_ts ON logs(ts);
CREATE INDEX idx_logs_level ON logs(level);
CREATE INDEX idx_logs_module ON logs(module);
CREATE INDEX idx_logs_trace_id ON logs(trace_id);
CREATE INDEX idx_logs_source_ts ON logs(source, ts);
```

**Auto-rotation**:
- **On startup**: Daemon deletes logs older than `logRetentionDays` (default 7). Same pattern as existing DB maintenance.
- **Periodic**: Every 1 hour at **:00**, daemon checks and deletes expired logs/traces/metrics. Necessary because daemon may run continuously for days (e.g., Mac Mini with `pmset` always-on).
- **Size cap**: If `logs` table exceeds 100K rows, oldest rows are trimmed regardless of age. Prevents runaway growth if debug logging is accidentally left on.

---

## Layer 2: Correlation ID + Traces

### Trace Model

```typescript
interface Span {
  traceId: string;     // UUID, propagated across daemon↔Swift
  spanId: string;      // UUID, unique per operation
  parentSpanId?: string;
  name: string;        // e.g. 'indexer.indexSession', 'search.fts'
  module: string;
  startTs: string;
  endTs?: string;
  durationMs?: number;
  status: 'ok' | 'error';
  attributes?: Record<string, unknown>;
}
```

**API**:
```typescript
const span = tracer.startSpan('indexer.indexSession', { sessionId });
try {
  // ... work ...
  span.end();
} catch (err) {
  span.error(err);
}
```

**Critical paths to instrument**:
1. `indexer.indexSession` — per-session indexing (file read → parse → DB write → FTS → embedding)
2. `search.execute` — search request (FTS query → Viking query → merge → rank)
3. `tool.*` — each MCP tool invocation
4. `viking.push` / `viking.find` — external API calls
5. `watcher.onChange` — file change → re-index trigger
6. `daemon.startup` — full startup sequence
7. `autoSummary.generate` — AI summary generation

**Propagation**: Daemon sets `traceId` in JSON event stream. Swift reads it and associates UI operations with the same trace.

### SQLite Schema

```sql
CREATE TABLE IF NOT EXISTS traces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trace_id TEXT NOT NULL,
    span_id TEXT NOT NULL,
    parent_span_id TEXT,
    name TEXT NOT NULL,
    module TEXT NOT NULL,
    start_ts TEXT NOT NULL,
    end_ts TEXT,
    duration_ms INTEGER,
    status TEXT NOT NULL DEFAULT 'ok',
    attributes TEXT,    -- JSON
    source TEXT NOT NULL CHECK (source IN ('daemon', 'app'))
);

-- span_id index is non-unique: if a bug produces duplicate UUIDs,
-- INSERT OR IGNORE silently drops the dupe instead of crashing the trace writer.
-- Tracer uses INSERT OR IGNORE for all span writes.
CREATE INDEX idx_traces_span_id ON traces(span_id);
CREATE INDEX idx_traces_trace_id ON traces(trace_id);
CREATE INDEX idx_traces_name ON traces(name);
CREATE INDEX idx_traces_start_ts ON traces(start_ts);
CREATE INDEX idx_traces_duration ON traces(duration_ms);
```

---

## Layer 3: Performance Metrics

### Metrics Model

```typescript
interface Metric {
  name: string;        // e.g. 'indexer.sessions_indexed'
  type: 'counter' | 'gauge' | 'histogram';
  value: number;
  tags?: Record<string, string>;
  ts: string;
}
```

**Key metrics to collect**:

| Metric | Type | Description |
|--------|------|-------------|
| `indexer.sessions_indexed` | counter | Total sessions indexed |
| `indexer.duration_ms` | histogram | Per-session indexing time |
| `search.fts_duration_ms` | histogram | FTS query latency |
| `search.viking_duration_ms` | histogram | Viking query latency |
| `search.results_count` | histogram | Results per search |
| `tool.invocations` | counter | MCP tool calls (tagged by tool name) |
| `tool.errors` | counter | MCP tool errors |
| `tool.duration_ms` | histogram | Tool execution time |
| `db.query_duration_ms` | histogram | DB query latency |
| `viking.circuit_breaker` | gauge | 0=closed, 1=open |
| `watcher.events` | counter | File change events |
| `daemon.uptime_s` | gauge | Daemon uptime |
| `daemon.memory_mb` | gauge | Process memory usage |

**Storage model**:

- **Counter/gauge**: One row per observation. Counters are monotonically incremented; gauges are point-in-time snapshots.
- **Histogram**: Each timing sample gets its own row (e.g., one row per `indexer.duration_ms` observation). Percentiles (p50/p95/p99) are computed at query time via SQL `NTILE()` or sorted offset, not pre-aggregated. This keeps writes simple and avoids losing distribution data.

**Write buffering** (critical for high-frequency metrics like `db.query_duration_ms`):
- All metrics are collected into an **in-memory buffer** (array), NOT written to SQLite individually.
- Buffer flushes to SQLite every **5 seconds** via `INSERT INTO metrics VALUES (...)` batch (single transaction, ~100-500 rows).
- Buffer also flushes when it reaches **1000 entries** (safety cap).
- High-frequency metrics (`db.query_duration_ms`) are **sampled at 10%** — only 1 in 10 observations is buffered. Other metrics (counters, gauges, low-frequency histograms) record every observation.
- Sampling is configured per metric name in `metricsConfig` to avoid over-writing during UI refresh storms.

```sql
CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('counter', 'gauge', 'histogram')),
    value REAL NOT NULL,
    tags TEXT,           -- JSON
    ts TEXT NOT NULL
);

CREATE INDEX idx_metrics_name_ts ON metrics(name, ts);
CREATE INDEX idx_metrics_name_type ON metrics(name, type);
```

**Retention and rollup**:
- Raw rows retained for 24 hours (sufficient for real-time dashboards and exact percentile queries).
- Hourly rollup job aggregates raw rows into hourly summaries: `{ name, hour, count, sum, min, max, p95 }`. Stored in `metrics_hourly` table. Retained 7 days.
- Rollup runs every hour at **:05** (5 minutes after log rotation at :00, to avoid overlapping write-heavy operations in the same transaction window).

**p95 composability caveat**: Hourly p95 values in `metrics_hourly` are pre-computed from raw data and **cannot be accurately re-aggregated** into daily/weekly p95 (percentiles are not composable). This is an accepted trade-off:
- For 24h view: use raw rows → exact percentiles.
- For 7-day view: display hourly p95 as a trend line (each point is that hour's p95). This is the standard approach for local observability tools.
- If exact multi-day percentiles are needed in the future, extend raw retention or add t-digest/DDSketch compact representations to `metrics_hourly`.

```sql
CREATE TABLE IF NOT EXISTS metrics_hourly (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    hour TEXT NOT NULL,          -- '2026-03-22T14'
    count INTEGER NOT NULL,
    sum REAL NOT NULL,
    min REAL NOT NULL,
    max REAL NOT NULL,
    p95 REAL,
    tags TEXT                    -- JSON
);

CREATE INDEX idx_metrics_hourly_name ON metrics_hourly(name, hour);
```

---

## Layer 4: Observability UI Page

New page in Engram main window sidebar. Placed in the **Monitor** section of the `Screen` enum (alongside Sessions, Timeline, Activity). Add `case observability` to `Screen.swift` with appropriate icon and section assignment.

### Sections

**4.1 Live Log Stream**
- Real-time scrolling log view (tail -f style)
- Filters: level picker, module picker, text search, time range
- Color-coded by level (debug=gray, info=default, warn=yellow, error=red)
- Click a log entry → expand to show full data/error/stack
- Click traceId → jump to trace detail

**4.2 Error Dashboard**
- Error count by module (bar chart, last 24h)
- Recent errors list with dedup (group by message)
- Error rate trend (sparkline)

**4.3 Performance Dashboard**
- Key latency charts: indexing time, search time, tool execution time
- p50/p95/p99 over time
- Slow operations list (> configurable threshold)

**4.4 Trace Explorer**
- List of recent traces (filterable by name, status, duration)
- Trace detail: waterfall/flame view of spans
- Click span → show attributes, duration, child spans

**4.5 System Health**
- Daemon status (running/stopped, uptime, memory)
- DB size, WAL size
- Viking status (connected/circuit-breaker/disabled)
- Source status (reuse existing `/api/health/sources` data)

### Data Flow & Refresh

Swift reads from `logs`, `traces`, `metrics` tables via read-only GRDB pool. Daemon is the sole writer (see Concurrency Model).

**Refresh mechanism**:
- **Live Log Stream**: Uses GRDB `ValueObservation` on the `logs` table, same pattern as existing session list observation. Automatically triggers SwiftUI updates when daemon inserts new logs. Efficient — GRDB uses SQLite's `sqlite3_update_hook` under the hood, no polling.
- **Error Dashboard / Performance Dashboard**: Polled every **30 seconds** via a timer. These are aggregate queries (COUNT, AVG, percentiles) that don't need real-time updates.
- **Trace Explorer**: On-demand query when user navigates to a trace. No background polling.
- **System Health**: Polled every **10 seconds** (lightweight — single row queries for uptime, memory, Viking status).

**Performance guard**: `ValueObservation` on `logs` uses `.removeDuplicates()` and a debounce of 500ms to avoid re-rendering on every single log insert during burst writes.

---

## Layer 5: CLI Diagnostic Tool

Extend existing `engram` CLI (`src/cli/index.ts`). Currently the CLI only handles `--resume` flag. Add a proper subcommand dispatcher: positional first argument selects the subcommand (`logs`, `traces`, `health`, `diagnose`). Falls through to existing `--resume` / MCP server behavior when no subcommand matches. Uses `process.argv` parsing (no external arg parser — keep zero-dependency).

```bash
# Log queries
engram logs                          # last 100 logs
engram logs --level error            # errors only
engram logs --module indexer         # filter by module
engram logs --last 1h                # time range
engram logs --trace abc123           # by correlation ID
engram logs --json                   # raw JSON output (for AI parsing)

# Trace queries
engram traces                        # recent traces
engram traces --slow 500ms           # slow operations
engram traces --name 'search.*'      # by span name pattern
engram traces --id abc123            # full trace detail

# Health
engram health                        # component status overview
engram health --metrics              # current metric values
engram health --errors               # error summary last 24h

# Diagnostic dump (for bug reports)
engram diagnose                      # last 24h of logs/traces/metrics + config + versions
engram diagnose --last 1h            # custom time range
engram diagnose --full               # all retained data (up to 7 days, can be large)
engram diagnose --output report.json # specify output file (default: stdout JSON)
```

**`engram diagnose` defaults**: Outputs last **24 hours** of data by default (not full 7 days). This keeps output manageable (~1-5MB). Use `--full` for complete retained data (may be 20-50MB). Output format is JSON by default; `--output` writes to file.

**Implementation**: CLI reads directly from `~/.engram/index.sqlite`. No daemon required. Pure SQLite queries.

---

## Layer 6: Error Treatment

### Phase 1: Audit and Replace

1. Grep all `.catch(() => {})` and `.catch((_) => {})` — replace with `log.warn()` or `log.error()`
2. Replace all `String(err)` with error serializer:
   ```typescript
   function serializeError(err: unknown): { name: string; message: string; stack?: string; code?: string } {
     if (err instanceof Error) {
       return { name: err.name, message: err.message, stack: err.stack, code: (err as any).code };
     }
     return { name: 'UnknownError', message: String(err) };
   }
   ```
3. Add error context to adapter failures (which adapter, which file, which session)

### Phase 2: Error Classification

Tag errors by category for dashboard grouping:
- `io` — file read/write failures
- `parse` — session/message parsing errors
- `db` — SQLite errors
- `network` — Viking/API call failures
- `config` — invalid configuration
- `adapter` — adapter-specific failures

---

## Migration Strategy

1. Add `logs`, `traces`, `metrics`, `metrics_hourly` tables via existing idempotent migration pattern in `src/core/db.ts`
2. Logger creation is additive — existing code continues to work during gradual adoption
3. Instrument critical paths first (indexer, search, tools), then expand
4. Swift logger uses os_log only; daemon is sole SQLite writer (no multi-process write conflicts)
5. Swift reads observability tables via existing read-only GRDB pool
6. Add `POST /api/log` endpoint for Swift→daemon log forwarding (error/warn only)
7. UI page is a new sidebar entry — no existing UI changes

## File Changes Summary

**New files**:
- `src/core/logger.ts` — Logger factory + log writer
- `src/core/tracer.ts` — Span/trace implementation
- `src/core/metrics.ts` — Metrics collector
- `src/core/error-serializer.ts` — Error serialization utility
- `src/cli/logs.ts` — CLI log query commands
- `src/cli/traces.ts` — CLI trace query commands
- `src/cli/health.ts` — CLI health commands
- `macos/Engram/Core/EngramLogger.swift` — Swift logger wrapper
- `macos/Engram/Views/Pages/ObservabilityView.swift` — Main observability page
- `macos/Engram/Views/Observability/LogStreamView.swift` — Live log viewer
- `macos/Engram/Views/Observability/ErrorDashboardView.swift` — Error stats
- `macos/Engram/Views/Observability/PerformanceView.swift` — Latency charts
- `macos/Engram/Views/Observability/TraceExplorerView.swift` — Trace viewer
- `macos/Engram/Views/Observability/SystemHealthView.swift` — Health overview

**Modified files**:
- `src/core/db.ts` — Add migration for logs/traces/metrics tables
- `src/core/indexer.ts` — Add logger + tracer instrumentation
- `src/core/viking-bridge.ts` — Add logger + tracer
- `src/tools/*.ts` — Add logger + tool execution tracing
- `src/daemon.ts` — Initialize logger, tracer, metrics; add maintenance
- `src/web.ts` — Add request logging middleware
- `macos/Engram/Models/Screen.swift` — Add `case observability` to Screen enum, place in Monitor section
- `macos/Engram/Views/MainWindowView.swift` — Add Observability sidebar item
- `macos/Engram/Core/IndexerProcess.swift` — Replace ad-hoc logging with EngramLogger
- `macos/project.yml` — Add new Swift files

## Testing

- Unit tests for logger (output format, level filtering, rotation)
- Unit tests for tracer (span lifecycle, nesting, propagation)
- Unit tests for metrics (aggregation, bucketing)
- Integration test: log → SQLite → CLI query
- UI snapshot tests for Observability page (covered by testing spec)
