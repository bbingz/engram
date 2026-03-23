# SP3b-Alerting: Performance Alert Rules

**Date**: 2026-03-23
**Status**: Draft
**Scope**: Gap #3 (no alerting rules) from observability gap analysis. Builds on SP3b metrics data.

## Decisions

| Decision | Choice |
|----------|--------|
| Data source | Mixed: realtime `metrics` for error rates (10min window), `metrics_hourly` for latency p95 |
| Persistence | New `alerts` table in SQLite |
| Rules | 6 performance rules (error rate, HTTP errors, search latency, DB latency, memory leak, high memory) |
| Dedup | Cooldown period (1h default, 3h for memory_leak) |
| Swift UI | No changes in V1 — alerts written to DB + emitted via stdout event |
| BackgroundMonitor | Unchanged — its cost/session/git alerts stay in-memory. Known inconsistency, acceptable for V1 |

## 1. `alerts` Table

New table in `src/core/db.ts` migration:

```sql
CREATE TABLE IF NOT EXISTS alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
  rule TEXT NOT NULL,
  severity TEXT NOT NULL CHECK (severity IN ('warning','critical')),
  message TEXT NOT NULL,
  value REAL,
  threshold REAL,
  dismissed_at TEXT,
  resolved_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_alerts_ts ON alerts(ts);
CREATE INDEX IF NOT EXISTS idx_alerts_rule ON alerts(rule, ts);
```

`dismissed_at` and `resolved_at` are V2 placeholders — not used in V1. No dismiss mechanism or API in this spec.

## 2. AlertRuleEngine

New file `src/core/alert-rules.ts`. Separate from BackgroundMonitor (which handles cost/session/git alerts in-memory).

### Interface

```typescript
export interface AlertRule {
  name: string
  cooldownMs: number
  check(db: BetterSqlite3.Database): AlertResult | null
}

export interface AlertResult {
  severity: 'warning' | 'critical'
  message: string
  value: number
  threshold: number
}

export class AlertRuleEngine {
  private lastFired = new Map<string, number>()  // rule name → timestamp
  private rules: AlertRule[]
  private insertStmt: BetterSqlite3.Statement

  constructor(private db: BetterSqlite3.Database) {
    this.rules = createDefaultRules()
    this.insertStmt = db.prepare(`
      INSERT INTO alerts (rule, severity, message, value, threshold)
      VALUES (@rule, @severity, @message, @value, @threshold)
    `)
  }

  check(): Array<{ rule: string; severity: string; message: string }> {
    const fired: Array<{ rule: string; severity: string; message: string }> = []
    const now = Date.now()

    for (const rule of this.rules) {
      // Cooldown check
      const last = this.lastFired.get(rule.name) ?? 0
      if (now - last < rule.cooldownMs) continue

      const result = rule.check(this.db)
      if (!result) continue

      // Record to DB
      this.insertStmt.run({
        rule: rule.name,
        severity: result.severity,
        message: result.message,
        value: result.value,
        threshold: result.threshold,
      })

      // Update cooldown
      this.lastFired.set(rule.name, now)

      fired.push({ rule: rule.name, severity: result.severity, message: result.message })
    }
    return fired
  }
}
```

Cooldown is in-memory. Daemon restart resets cooldown — acceptable (re-check on restart is correct behavior if condition persists).

### Known inconsistency with BackgroundMonitor

BackgroundMonitor's alerts (cost, long session, unpushed commits) remain in-memory with FIFO cap. AlertRuleEngine's alerts go to the `alerts` table. Both emit `{ event: 'alert', alert }` via daemon stdout for Swift to consume. This is intentional:

- BackgroundMonitor has complex interactive dismiss/FIFO logic tied to Swift UI
- Migrating it to DB is scope creep and risks breaking existing Swift behavior
- Both alert systems share the same stdout event channel — Swift doesn't need to distinguish the storage backend

## 3. Alert Rules

### 3.1 Error Rate (realtime)

```typescript
{
  name: 'error_rate',
  cooldownMs: 3600000,  // 1h
  check(db) {
    const cutoff = new Date(Date.now() - 10 * 60000).toISOString()
    const row = db.prepare(
      "SELECT COALESCE(SUM(value), 0) as total FROM metrics WHERE name = 'error.count' AND ts > ?"
    ).get(cutoff) as { total: number }
    if (row.total > 50) return { severity: 'critical', message: `${row.total} errors in last 10min`, value: row.total, threshold: 50 }
    if (row.total > 10) return { severity: 'warning', message: `${row.total} errors in last 10min`, value: row.total, threshold: 10 }
    return null
  }
}
```

### 3.2 HTTP Error Rate (realtime)

```typescript
{
  name: 'http_error_rate',
  cooldownMs: 3600000,
  check(db) {
    const cutoff = new Date(Date.now() - 10 * 60000).toISOString()
    const row = db.prepare(
      "SELECT COALESCE(SUM(value), 0) as total FROM metrics WHERE name = 'http.error_count' AND ts > ?"
    ).get(cutoff) as { total: number }
    if (row.total > 20) return { severity: 'warning', message: `${row.total} HTTP errors in last 10min`, value: row.total, threshold: 20 }
    return null
  }
}
```

### 3.3 Search Latency (hourly)

```typescript
{
  name: 'search_latency',
  cooldownMs: 3600000,
  check(db) {
    const row = db.prepare(
      "SELECT p95 FROM metrics_hourly WHERE name = 'search.duration_ms' AND type = 'histogram' ORDER BY hour DESC LIMIT 1"
    ).get() as { p95: number } | undefined
    if (!row) return null
    if (row.p95 > 15000) return { severity: 'critical', message: `Search p95 ${Math.round(row.p95)}ms (last hour)`, value: row.p95, threshold: 15000 }
    if (row.p95 > 5000) return { severity: 'warning', message: `Search p95 ${Math.round(row.p95)}ms (last hour)`, value: row.p95, threshold: 5000 }
    return null
  }
}
```

### 3.4 DB Query Latency (hourly)

```typescript
{
  name: 'db_query_latency',
  cooldownMs: 3600000,
  check(db) {
    const row = db.prepare(
      "SELECT p95 FROM metrics_hourly WHERE name = 'db.query_ms' AND type = 'histogram' ORDER BY hour DESC LIMIT 1"
    ).get() as { p95: number } | undefined
    if (!row) return null
    if (row.p95 > 2000) return { severity: 'critical', message: `DB query p95 ${Math.round(row.p95)}ms (last hour)`, value: row.p95, threshold: 2000 }
    if (row.p95 > 500) return { severity: 'warning', message: `DB query p95 ${Math.round(row.p95)}ms (last hour)`, value: row.p95, threshold: 500 }
    return null
  }
}
```

### 3.5 Memory Leak (3h trend)

```typescript
{
  name: 'memory_leak',
  cooldownMs: 10800000,  // 3h
  check(db) {
    const threeHoursAgo = new Date(Date.now() - 3 * 3600000).toISOString()

    // Get latest heap value
    const latest = db.prepare(
      "SELECT value FROM metrics WHERE name = 'process.heap_mb' ORDER BY ts DESC LIMIT 1"
    ).get() as { value: number } | undefined
    if (!latest) return null

    // Get value from ~3h ago
    const old = db.prepare(
      "SELECT value FROM metrics WHERE name = 'process.heap_mb' AND ts <= ? ORDER BY ts DESC LIMIT 1"
    ).get(threeHoursAgo) as { value: number } | undefined
    if (!old) return null  // Daemon < 3h old → skip

    const growth = latest.value - old.value
    if (growth > 100) return { severity: 'warning', message: `Heap grew ${Math.round(growth)}MB in 3h (${Math.round(old.value)}→${Math.round(latest.value)}MB)`, value: growth, threshold: 100 }
    return null
  }
}
```

### 3.6 High Memory (instant)

```typescript
{
  name: 'high_memory',
  cooldownMs: 3600000,
  check(db) {
    const row = db.prepare(
      "SELECT value FROM metrics WHERE name = 'process.rss_mb' ORDER BY ts DESC LIMIT 1"
    ).get() as { value: number } | undefined
    if (!row) return null
    if (row.value > 1024) return { severity: 'critical', message: `RSS memory ${Math.round(row.value)}MB exceeds 1GB`, value: row.value, threshold: 1024 }
    return null
  }
}
```

## 4. Daemon Integration

In `src/daemon.ts`, create AlertRuleEngine and add to the existing 10-minute BackgroundMonitor timer:

```typescript
const alertEngine = new AlertRuleEngine(db.raw)

// In the existing backgroundMonitor interval or a new 10-min interval:
const alertCheckTimer = setInterval(() => {
  runWithContext({ requestId: randomUUID(), source: 'scheduler' }, () => {
    metrics.flush()  // Ensure buffered metrics are written before checking
    const alerts = alertEngine.check()
    for (const alert of alerts) {
      emit({ event: 'alert', alert })
    }
  })
}, 600_000 * POWER_MULTIPLIER)  // 10 min (20 on battery)
```

Note: `metrics.flush()` ensures buffered entries are visible to alert queries. Without it, up to 5 seconds of data could be in the buffer.

Note: `search_latency` and `db_query_latency` rules query `metrics_hourly`, which is populated by the hourly rollup timer (5min delay + 1h interval). These rules are effectively inactive until the first rollup completes (~65min after daemon start). This is acceptable — no false positives, just delayed detection.

Note: `db.query_ms` is sampled at 10% (`sampleRates` in daemon.ts). The `db_query_latency` rule's p95 is computed from this sample. Thresholds may need empirical tuning once real data is available.

Add `clearInterval(alertCheckTimer)` to the daemon's shutdown handler alongside other timer cleanups.

## 5. Test Strategy

### New: `tests/core/alert-rules.test.ts`

**Error rate rules:**
- Seed `error.count` metrics → check triggers warning at >10, critical at >50
- No metrics → check returns empty (no alert)
- Metrics outside 10min window → not counted

**Latency rules:**
- Seed `metrics_hourly` with high p95 → triggers warning/critical
- No hourly data → no alert

**Memory rules:**
- Seed `process.heap_mb` at two timestamps 3h apart → 100MB growth triggers warning
- Daemon < 3h (no old data) → no alert
- Seed `process.rss_mb` > 1024 → triggers critical

**Cooldown:**
- First check → fires alert
- Immediate second check → no duplicate (cooldown active)
- After cooldown expires → fires again

**DB persistence:**
- After check(), verify row exists in `alerts` table with correct rule/severity/value/threshold

## 6. Files Changed

| File | Changes |
|------|---------|
| `src/core/alert-rules.ts` | New: AlertRuleEngine + 6 rules + cooldown logic |
| `src/core/db.ts` | New: `alerts` table migration |
| `src/daemon.ts` | Create AlertRuleEngine, 10min timer, emit alerts |
| `tests/core/alert-rules.test.ts` | New: rule tests + cooldown + persistence |

## 7. Out of Scope

- **Configurable thresholds** — hardcoded in V1, configurable via settings.json in future
- **Alert dismiss mechanism** — `dismissed_at` column exists but no API/UI to set it
- **BackgroundMonitor migration** — cost/session/git alerts stay in-memory
- **Swift UI for alert history** — new `alerts` table can be queried but no UI in V1
- **Alert grouping/aggregation** — cooldown is sufficient for V1
- **Webhook/email delivery** — desktop app, stdout event is sufficient
