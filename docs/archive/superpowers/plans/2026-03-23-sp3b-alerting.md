# SP3b-Alerting: Performance Alert Rules — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 6 metrics-based performance alert rules with DB persistence and cooldown dedup, complementing the existing BackgroundMonitor's cost/session/git alerts.

**Architecture:** New `AlertRuleEngine` class with pre-compiled SQL statements, querying `metrics` (realtime) and `metrics_hourly` (latency p95) tables. Alerts persisted to new `alerts` table. 10-minute check interval in daemon, with `metrics.flush()` before each check to ensure data visibility.

**Tech Stack:** better-sqlite3, Vitest, existing MetricsCollector + daemon timer infrastructure

**Spec:** `docs/superpowers/specs/2026-03-23-sp3b-alerting-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `src/core/alert-rules.ts` | New: AlertRuleEngine + 6 rules + cooldown + createDefaultRules() |
| `src/core/db.ts` | Modify: add `alerts` table migration |
| `src/daemon.ts` | Modify: create AlertRuleEngine, 10min timer, shutdown cleanup |
| `tests/core/alert-rules.test.ts` | New: rule tests, cooldown, persistence |

---

### Task 1: alerts Table + AlertRuleEngine + All 6 Rules

**Files:**
- Modify: `src/core/db.ts`
- Create: `src/core/alert-rules.ts`
- Create: `tests/core/alert-rules.test.ts`

- [ ] **Step 1: Add alerts table migration to db.ts**

In `src/core/db.ts`, in the `migrate()` method, add after the existing `metrics_hourly` table creation (search for `CREATE INDEX IF NOT EXISTS idx_metrics_hourly_name`):

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

Use the same idempotent `CREATE TABLE IF NOT EXISTS` pattern as all other tables.

- [ ] **Step 2: Write failing tests**

Create `tests/core/alert-rules.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import { MetricsCollector } from '../../src/core/metrics.js'
import { AlertRuleEngine } from '../../src/core/alert-rules.js'

describe('AlertRuleEngine', () => {
  let db: Database
  let metricsCollector: MetricsCollector

  beforeEach(() => {
    db = new Database(':memory:')
    metricsCollector = new MetricsCollector(db.raw, { flushIntervalMs: 0 })
  })
  afterEach(() => { db.close() })

  function seedMetric(name: string, value: number, ts?: string) {
    const timestamp = ts ?? new Date().toISOString()
    db.raw.prepare("INSERT INTO metrics (name, type, value, ts) VALUES (?, 'counter', ?, ?)").run(name, value, timestamp)
  }

  function seedGauge(name: string, value: number, ts?: string) {
    const timestamp = ts ?? new Date().toISOString()
    db.raw.prepare("INSERT INTO metrics (name, type, value, ts) VALUES (?, 'gauge', ?, ?)").run(name, value, timestamp)
  }

  function seedHourly(name: string, p95: number, hour?: string) {
    const h = hour ?? new Date().toISOString().slice(0, 13)
    db.raw.prepare("INSERT INTO metrics_hourly (name, type, hour, count, sum, min, max, p95) VALUES (?, 'histogram', ?, 100, ?, 0, ?, ?)").run(name, h, p95 * 100, p95 * 2, p95)
  }

  describe('error_rate rule', () => {
    it('triggers warning when > 10 errors in 10min', () => {
      for (let i = 0; i < 11; i++) seedMetric('error.count', 1)
      const engine = new AlertRuleEngine(db.raw)
      const alerts = engine.check()
      expect(alerts).toHaveLength(1)
      expect(alerts[0].rule).toBe('error_rate')
      expect(alerts[0].severity).toBe('warning')
    })

    it('triggers critical when > 50 errors in 10min', () => {
      seedMetric('error.count', 51)
      const engine = new AlertRuleEngine(db.raw)
      const alerts = engine.check()
      expect(alerts[0].severity).toBe('critical')
    })

    it('does not trigger when <= 10 errors', () => {
      for (let i = 0; i < 10; i++) seedMetric('error.count', 1)
      const engine = new AlertRuleEngine(db.raw)
      expect(engine.check()).toHaveLength(0)
    })

    it('ignores metrics outside 10min window', () => {
      const old = new Date(Date.now() - 15 * 60000).toISOString()
      for (let i = 0; i < 20; i++) seedMetric('error.count', 1, old)
      const engine = new AlertRuleEngine(db.raw)
      expect(engine.check()).toHaveLength(0)
    })
  })

  describe('http_error_rate rule', () => {
    it('triggers warning when > 20 HTTP errors in 10min', () => {
      seedMetric('http.error_count', 21)
      const engine = new AlertRuleEngine(db.raw)
      const alerts = engine.check()
      const httpAlert = alerts.find(a => a.rule === 'http_error_rate')
      expect(httpAlert).toBeDefined()
      expect(httpAlert!.severity).toBe('warning')
    })
  })

  describe('search_latency rule', () => {
    it('triggers warning when p95 > 5000ms', () => {
      seedHourly('search.duration_ms', 6000)
      const engine = new AlertRuleEngine(db.raw)
      const alerts = engine.check()
      const a = alerts.find(a => a.rule === 'search_latency')
      expect(a).toBeDefined()
      expect(a!.severity).toBe('warning')
    })

    it('triggers critical when p95 > 15000ms', () => {
      seedHourly('search.duration_ms', 16000)
      const engine = new AlertRuleEngine(db.raw)
      const alerts = engine.check()
      const a = alerts.find(a => a.rule === 'search_latency')
      expect(a!.severity).toBe('critical')
    })

    it('no alert when no hourly data', () => {
      const engine = new AlertRuleEngine(db.raw)
      expect(engine.check().filter(a => a.rule === 'search_latency')).toHaveLength(0)
    })
  })

  describe('db_query_latency rule', () => {
    it('triggers warning when p95 > 500ms', () => {
      seedHourly('db.query_ms', 600)
      const engine = new AlertRuleEngine(db.raw)
      const a = engine.check().find(a => a.rule === 'db_query_latency')
      expect(a).toBeDefined()
      expect(a!.severity).toBe('warning')
    })
  })

  describe('memory_leak rule', () => {
    it('triggers warning when heap grows > 100MB in 3h', () => {
      const threeHoursAgo = new Date(Date.now() - 3 * 3600000 - 60000).toISOString()
      seedGauge('process.heap_mb', 200, threeHoursAgo)
      seedGauge('process.heap_mb', 350)
      const engine = new AlertRuleEngine(db.raw)
      const a = engine.check().find(a => a.rule === 'memory_leak')
      expect(a).toBeDefined()
      expect(a!.severity).toBe('warning')
    })

    it('no alert when daemon < 3h old (no old data)', () => {
      seedGauge('process.heap_mb', 350)
      const engine = new AlertRuleEngine(db.raw)
      expect(engine.check().filter(a => a.rule === 'memory_leak')).toHaveLength(0)
    })
  })

  describe('high_memory rule', () => {
    it('triggers critical when RSS > 1024MB', () => {
      seedGauge('process.rss_mb', 1100)
      const engine = new AlertRuleEngine(db.raw)
      const a = engine.check().find(a => a.rule === 'high_memory')
      expect(a).toBeDefined()
      expect(a!.severity).toBe('critical')
    })
  })

  describe('cooldown', () => {
    it('does not fire same rule twice within cooldown', () => {
      seedMetric('error.count', 51)
      const engine = new AlertRuleEngine(db.raw)
      expect(engine.check()).toHaveLength(1)
      expect(engine.check()).toHaveLength(0)  // cooldown active
    })
  })

  describe('persistence', () => {
    it('writes alert to alerts table', () => {
      seedMetric('error.count', 51)
      const engine = new AlertRuleEngine(db.raw)
      engine.check()
      const row = db.raw.prepare("SELECT * FROM alerts WHERE rule = 'error_rate'").get() as any
      expect(row).toBeDefined()
      expect(row.severity).toBe('critical')
      expect(row.value).toBe(51)
      expect(row.threshold).toBe(50)
    })
  })

  describe('no data', () => {
    it('returns empty when no metrics exist', () => {
      const engine = new AlertRuleEngine(db.raw)
      expect(engine.check()).toHaveLength(0)
    })
  })
})
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npx vitest run tests/core/alert-rules.test.ts`
Expected: FAIL — `AlertRuleEngine` module not found

- [ ] **Step 4: Implement alert-rules.ts**

Create `src/core/alert-rules.ts`:

```typescript
// src/core/alert-rules.ts
import type BetterSqlite3 from 'better-sqlite3'

export interface AlertRule {
  name: string
  cooldownMs: number
  check(): AlertResult | null
}

export interface AlertResult {
  severity: 'warning' | 'critical'
  message: string
  value: number
  threshold: number
}

export class AlertRuleEngine {
  private lastFired = new Map<string, number>()
  private rules: AlertRule[]
  private insertStmt: BetterSqlite3.Statement

  constructor(private db: BetterSqlite3.Database) {
    this.insertStmt = db.prepare(`
      INSERT INTO alerts (rule, severity, message, value, threshold)
      VALUES (@rule, @severity, @message, @value, @threshold)
    `)
    this.rules = this.createDefaultRules()
  }

  check(): Array<{ rule: string; severity: string; message: string; value: number; threshold: number }> {
    const fired: Array<{ rule: string; severity: string; message: string; value: number; threshold: number }> = []
    const now = Date.now()

    for (const rule of this.rules) {
      const last = this.lastFired.get(rule.name) ?? 0
      if (now - last < rule.cooldownMs) continue

      const result = rule.check()
      if (!result) continue

      this.insertStmt.run({
        rule: rule.name,
        severity: result.severity,
        message: result.message,
        value: result.value,
        threshold: result.threshold,
      })

      this.lastFired.set(rule.name, now)
      fired.push({ rule: rule.name, severity: result.severity, message: result.message, value: result.value, threshold: result.threshold })
    }
    return fired
  }

  private createDefaultRules(): AlertRule[] {
    const db = this.db

    // Pre-compile all SQL statements
    const errorCountStmt = db.prepare("SELECT COALESCE(SUM(value), 0) as total FROM metrics WHERE name = 'error.count' AND ts > ?")
    const httpErrorStmt = db.prepare("SELECT COALESCE(SUM(value), 0) as total FROM metrics WHERE name = 'http.error_count' AND ts > ?")
    const searchLatencyStmt = db.prepare("SELECT p95 FROM metrics_hourly WHERE name = 'search.duration_ms' AND type = 'histogram' ORDER BY hour DESC LIMIT 1")
    const dbLatencyStmt = db.prepare("SELECT p95 FROM metrics_hourly WHERE name = 'db.query_ms' AND type = 'histogram' ORDER BY hour DESC LIMIT 1")
    const heapLatestStmt = db.prepare("SELECT value FROM metrics WHERE name = 'process.heap_mb' ORDER BY ts DESC LIMIT 1")
    const heapOldStmt = db.prepare("SELECT value FROM metrics WHERE name = 'process.heap_mb' AND ts <= ? ORDER BY ts DESC LIMIT 1")
    const rssStmt = db.prepare("SELECT value FROM metrics WHERE name = 'process.rss_mb' ORDER BY ts DESC LIMIT 1")

    return [
      {
        name: 'error_rate',
        cooldownMs: 3600000,
        check() {
          const cutoff = new Date(Date.now() - 10 * 60000).toISOString()
          const row = errorCountStmt.get(cutoff) as { total: number }
          if (row.total > 50) return { severity: 'critical', message: `${row.total} errors in last 10min`, value: row.total, threshold: 50 }
          if (row.total > 10) return { severity: 'warning', message: `${row.total} errors in last 10min`, value: row.total, threshold: 10 }
          return null
        },
      },
      {
        name: 'http_error_rate',
        cooldownMs: 3600000,
        check() {
          const cutoff = new Date(Date.now() - 10 * 60000).toISOString()
          const row = httpErrorStmt.get(cutoff) as { total: number }
          if (row.total > 20) return { severity: 'warning', message: `${row.total} HTTP errors in last 10min`, value: row.total, threshold: 20 }
          return null
        },
      },
      {
        name: 'search_latency',
        cooldownMs: 3600000,
        check() {
          const row = searchLatencyStmt.get() as { p95: number } | undefined
          if (!row) return null
          if (row.p95 > 15000) return { severity: 'critical', message: `Search p95 ${Math.round(row.p95)}ms (last hour)`, value: row.p95, threshold: 15000 }
          if (row.p95 > 5000) return { severity: 'warning', message: `Search p95 ${Math.round(row.p95)}ms (last hour)`, value: row.p95, threshold: 5000 }
          return null
        },
      },
      {
        name: 'db_query_latency',
        cooldownMs: 3600000,
        check() {
          const row = dbLatencyStmt.get() as { p95: number } | undefined
          if (!row) return null
          if (row.p95 > 2000) return { severity: 'critical', message: `DB query p95 ${Math.round(row.p95)}ms (last hour)`, value: row.p95, threshold: 2000 }
          if (row.p95 > 500) return { severity: 'warning', message: `DB query p95 ${Math.round(row.p95)}ms (last hour)`, value: row.p95, threshold: 500 }
          return null
        },
      },
      {
        name: 'memory_leak',
        cooldownMs: 10800000,
        check() {
          const latest = heapLatestStmt.get() as { value: number } | undefined
          if (!latest) return null
          const threeHoursAgo = new Date(Date.now() - 3 * 3600000).toISOString()
          const old = heapOldStmt.get(threeHoursAgo) as { value: number } | undefined
          if (!old) return null
          const growth = latest.value - old.value
          if (growth > 100) return { severity: 'warning', message: `Heap grew ${Math.round(growth)}MB in 3h (${Math.round(old.value)}→${Math.round(latest.value)}MB)`, value: growth, threshold: 100 }
          return null
        },
      },
      {
        name: 'high_memory',
        cooldownMs: 3600000,
        check() {
          const row = rssStmt.get() as { value: number } | undefined
          if (!row) return null
          if (row.value > 1024) return { severity: 'critical', message: `RSS memory ${Math.round(row.value)}MB exceeds 1GB`, value: row.value, threshold: 1024 }
          return null
        },
      },
    ]
  }
}
```

Note: `AlertRule.check()` is a closure that captures the pre-compiled statements. The interface differs slightly from the spec (no `db` param) because statements are pre-compiled in the constructor — cleaner and avoids re-preparing SQL on every check.

- [ ] **Step 5: Run tests to verify they pass**

Run: `npx vitest run tests/core/alert-rules.test.ts`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add src/core/db.ts src/core/alert-rules.ts tests/core/alert-rules.test.ts
git commit -m "feat(alerting): add AlertRuleEngine with 6 performance rules + alerts table"
```

---

### Task 2: Daemon Integration

**Files:**
- Modify: `src/daemon.ts`

- [ ] **Step 1: Add import**

Add at top of `src/daemon.ts`:
```typescript
import { AlertRuleEngine } from './core/alert-rules.js'
```

- [ ] **Step 2: Create AlertRuleEngine after BackgroundMonitor**

Search for `backgroundMonitor.start(600_000 * POWER_MULTIPLIER)`. Add after:

```typescript
const alertEngine = new AlertRuleEngine(db.raw)
```

- [ ] **Step 3: Add 10-minute alert check timer**

Add after the `alertEngine` creation:

```typescript
const alertCheckTimer = setInterval(() => {
  runWithContext({ requestId: randomUUID(), source: 'scheduler' }, () => {
    metrics.flush()
    const alerts = alertEngine.check()
    for (const alert of alerts) {
      emit({ event: 'alert', alert })
    }
  })
}, 600_000 * POWER_MULTIPLIER)
```

- [ ] **Step 4: Add to shutdown cleanup**

Search for `clearInterval(uptimeTimer)` in the `shutdown()` function. Add after it:

```typescript
clearInterval(alertCheckTimer)
```

- [ ] **Step 5: Build and verify**

Run: `npm run build && npm test`
Expected: Build clean, all tests pass

- [ ] **Step 6: Commit**

```bash
git add src/daemon.ts
git commit -m "feat(alerting): wire AlertRuleEngine into daemon 10min timer"
```

---

### Task 3: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `npm test`
Expected: All tests pass

- [ ] **Step 2: Build check**

Run: `npm run build`
Expected: Clean build

- [ ] **Step 3: Verify alerts table exists**

```bash
node -e "const D = require('./dist/core/db.js').Database; const db = new D(':memory:'); const cols = db.raw.pragma('table_info(alerts)').map(c => c.name); console.log(cols); db.close()"
```
Expected: `['id', 'ts', 'rule', 'severity', 'message', 'value', 'threshold', 'dismissed_at', 'resolved_at']`

- [ ] **Step 4: Mark spec as implemented**

```bash
sed -i '' 's/^**Status**: Draft/**Status**: Implemented/' docs/superpowers/specs/2026-03-23-sp3b-alerting-design.md
git add docs/superpowers/specs/2026-03-23-sp3b-alerting-design.md
git commit -m "docs: mark SP3b-alerting spec as implemented"
```
