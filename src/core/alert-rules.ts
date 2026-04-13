// src/core/alert-rules.ts
import type BetterSqlite3 from 'better-sqlite3';

interface AlertResult {
  severity: 'warning' | 'critical';
  message: string;
  value: number;
  threshold: number;
}

interface AlertRule {
  name: string;
  cooldownMs: number;
  check(): AlertResult | null;
}

interface FiredAlert extends AlertResult {
  rule: string;
}

export class AlertRuleEngine {
  private cooldowns = new Map<string, number>();
  private insertAlert: BetterSqlite3.Statement;
  private rules: AlertRule[];

  constructor(private db: BetterSqlite3.Database) {
    this.insertAlert = db.prepare(`
      INSERT INTO alerts (rule, severity, message, value, threshold)
      VALUES (@rule, @severity, @message, @value, @threshold)
    `);

    this.rules = this.createDefaultRules();
  }

  check(): FiredAlert[] {
    const now = Date.now();
    const fired: FiredAlert[] = [];

    for (const rule of this.rules) {
      const lastFired = this.cooldowns.get(rule.name) ?? 0;
      if (now - lastFired < rule.cooldownMs) continue;

      const result = rule.check();
      if (!result) continue;

      this.cooldowns.set(rule.name, now);
      this.insertAlert.run({
        rule: rule.name,
        severity: result.severity,
        message: result.message,
        value: result.value,
        threshold: result.threshold,
      });
      fired.push({ rule: rule.name, ...result });
    }

    return fired;
  }

  private createDefaultRules(): AlertRule[] {
    const db = this.db;

    // Pre-compile all SQL statements
    // Note: stored ts is ISO 8601 (e.g. "2026-03-23T10:30:00.000Z"). SQLite's datetime() returns
    // "2026-03-23 10:30:00" which sorts differently. Use strftime('%Y-%m-%dT%H:%M:%SZ','now',...)
    // to produce a comparable ISO string for WHERE comparisons.
    const stmtErrorRate = db.prepare(`
      SELECT COALESCE(SUM(value), 0) as total
      FROM metrics
      WHERE name = 'error.count'
        AND ts >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-10 minutes')
    `);

    const stmtHttpErrorRate = db.prepare(`
      SELECT COALESCE(SUM(value), 0) as total
      FROM metrics
      WHERE name = 'http.error_count'
        AND ts >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-10 minutes')
    `);

    const stmtSearchLatency = db.prepare(`
      SELECT p95
      FROM metrics_hourly
      WHERE name = 'search.duration_ms'
        AND p95 IS NOT NULL
      ORDER BY hour DESC LIMIT 1
    `);

    const stmtDbQueryLatency = db.prepare(`
      SELECT p95
      FROM metrics_hourly
      WHERE name = 'db.query_ms'
        AND p95 IS NOT NULL
      ORDER BY hour DESC LIMIT 1
    `);

    // Latest heap value
    const stmtHeapLatest = db.prepare(`
      SELECT value FROM metrics
      WHERE name = 'process.heap_mb' AND type = 'gauge'
      ORDER BY ts DESC LIMIT 1
    `);

    // Heap value from ~3h ago — find latest gauge older than 150min (2.5h)
    const stmtHeapOld = db.prepare(`
      SELECT value FROM metrics
      WHERE name = 'process.heap_mb' AND type = 'gauge'
        AND ts <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-150 minutes')
      ORDER BY ts DESC LIMIT 1
    `);

    const stmtRss = db.prepare(`
      SELECT value FROM metrics
      WHERE name = 'process.rss_mb' AND type = 'gauge'
      ORDER BY ts DESC LIMIT 1
    `);

    return [
      {
        name: 'error_rate',
        cooldownMs: 60 * 60 * 1000, // 1h
        check(): AlertResult | null {
          const row = stmtErrorRate.get() as { total: number };
          const total = row?.total ?? 0;
          if (total > 50) {
            return {
              severity: 'critical',
              message: `Error rate critical: ${total} errors in last 10min`,
              value: total,
              threshold: 50,
            };
          }
          if (total > 10) {
            return {
              severity: 'warning',
              message: `Error rate elevated: ${total} errors in last 10min`,
              value: total,
              threshold: 10,
            };
          }
          return null;
        },
      },
      {
        name: 'http_error_rate',
        cooldownMs: 60 * 60 * 1000,
        check(): AlertResult | null {
          const row = stmtHttpErrorRate.get() as { total: number };
          const total = row?.total ?? 0;
          if (total > 20) {
            return {
              severity: 'warning',
              message: `HTTP error rate elevated: ${total} errors in last 10min`,
              value: total,
              threshold: 20,
            };
          }
          return null;
        },
      },
      {
        name: 'search_latency',
        cooldownMs: 60 * 60 * 1000,
        check(): AlertResult | null {
          const row = stmtSearchLatency.get() as { p95: number } | undefined;
          if (!row) return null;
          const p95 = row.p95;
          if (p95 > 15000) {
            return {
              severity: 'critical',
              message: `Search p95 latency critical: ${p95}ms`,
              value: p95,
              threshold: 15000,
            };
          }
          if (p95 > 5000) {
            return {
              severity: 'warning',
              message: `Search p95 latency elevated: ${p95}ms`,
              value: p95,
              threshold: 5000,
            };
          }
          return null;
        },
      },
      {
        name: 'db_query_latency',
        cooldownMs: 60 * 60 * 1000,
        check(): AlertResult | null {
          const row = stmtDbQueryLatency.get() as { p95: number } | undefined;
          if (!row) return null;
          const p95 = row.p95;
          if (p95 > 2000) {
            return {
              severity: 'critical',
              message: `DB query p95 latency critical: ${p95}ms`,
              value: p95,
              threshold: 2000,
            };
          }
          if (p95 > 500) {
            return {
              severity: 'warning',
              message: `DB query p95 latency elevated: ${p95}ms`,
              value: p95,
              threshold: 500,
            };
          }
          return null;
        },
      },
      {
        name: 'memory_leak',
        cooldownMs: 3 * 60 * 60 * 1000, // 3h
        check(): AlertResult | null {
          const latest = stmtHeapLatest.get() as { value: number } | undefined;
          const old = stmtHeapOld.get() as { value: number } | undefined;
          if (!latest || !old) return null;
          const growth = latest.value - old.value;
          if (growth > 100) {
            return {
              severity: 'warning',
              message: `Heap growing: +${growth.toFixed(1)}MB over ~3h`,
              value: growth,
              threshold: 100,
            };
          }
          return null;
        },
      },
      {
        name: 'high_memory',
        cooldownMs: 60 * 60 * 1000,
        check(): AlertResult | null {
          const row = stmtRss.get() as { value: number } | undefined;
          if (!row) return null;
          const rss = row.value;
          if (rss > 1024) {
            return {
              severity: 'critical',
              message: `RSS memory critical: ${rss}MB`,
              value: rss,
              threshold: 1024,
            };
          }
          return null;
        },
      },
    ];
  }
}
