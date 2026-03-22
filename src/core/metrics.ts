// src/core/metrics.ts
import type BetterSqlite3 from 'better-sqlite3'

export type MetricType = 'counter' | 'gauge' | 'histogram'

interface MetricEntry {
  name: string
  type: MetricType
  value: number
  tags?: Record<string, string>
  ts: string
}

interface MetricsOpts {
  flushIntervalMs?: number
  maxBufferSize?: number
  sampleRates?: Record<string, number>
}

export class MetricsCollector {
  private buffer: MetricEntry[] = []
  private insertStmt: BetterSqlite3.Statement
  private flushTimer: ReturnType<typeof setInterval> | null = null
  private maxBufferSize: number
  private sampleRates: Record<string, number>

  constructor(private db: BetterSqlite3.Database, opts: MetricsOpts = {}) {
    this.insertStmt = db.prepare(`
      INSERT INTO metrics (name, type, value, tags, ts)
      VALUES (@name, @type, @value, @tags, @ts)
    `)
    this.maxBufferSize = opts.maxBufferSize ?? 1000
    this.sampleRates = opts.sampleRates ?? {}

    const intervalMs = opts.flushIntervalMs ?? 5000
    if (intervalMs > 0) {
      this.flushTimer = setInterval(() => this.flush(), intervalMs)
    }
  }

  private shouldSample(name: string): boolean {
    const rate = this.sampleRates[name]
    if (rate === undefined) return true // default: sample everything
    if (rate <= 0) return false
    if (rate >= 1) return true
    return Math.random() < rate
  }

  counter(name: string, value: number, tags?: Record<string, string>): void {
    this.record(name, 'counter', value, tags)
  }

  gauge(name: string, value: number, tags?: Record<string, string>): void {
    this.record(name, 'gauge', value, tags)
  }

  histogram(name: string, value: number, tags?: Record<string, string>): void {
    this.record(name, 'histogram', value, tags)
  }

  private record(name: string, type: MetricType, value: number, tags?: Record<string, string>): void {
    if (!this.shouldSample(name)) return
    this.buffer.push({
      name,
      type,
      value,
      tags,
      ts: new Date().toISOString(),
    })
    if (this.buffer.length >= this.maxBufferSize) {
      this.flush()
    }
  }

  flush(): void {
    if (this.buffer.length === 0) return
    const entries = this.buffer.splice(0)
    const insertMany = this.db.transaction((items: MetricEntry[]) => {
      for (const entry of items) {
        this.insertStmt.run({
          name: entry.name,
          type: entry.type,
          value: entry.value,
          tags: entry.tags ? JSON.stringify(entry.tags) : null,
          ts: entry.ts,
        })
      }
    })
    insertMany(entries)
  }

  rollup(): void {
    // Aggregate raw metrics into hourly summaries
    // Group by name, type, and hour (substr(ts, 1, 13) gives 'YYYY-MM-DDTHH')
    const rows = this.db.prepare(`
      SELECT
        name,
        type,
        substr(ts, 1, 13) as hour,
        COUNT(*) as count,
        SUM(value) as sum,
        MIN(value) as min,
        MAX(value) as max,
        tags
      FROM metrics
      GROUP BY name, type, substr(ts, 1, 13), tags
    `).all() as any[]

    if (rows.length === 0) return

    const insertRollup = this.db.prepare(`
      INSERT INTO metrics_hourly (name, type, hour, count, sum, min, max, p95, tags)
      VALUES (@name, @type, @hour, @count, @sum, @min, @max, @p95, @tags)
    `)

    const transaction = this.db.transaction((rollupRows: any[]) => {
      for (const row of rollupRows) {
        // Compute p95 for this name+hour+tags group
        const values = this.db.prepare(
          `SELECT value FROM metrics WHERE name = ? AND substr(ts, 1, 13) = ? ORDER BY value`
        ).all(row.name, row.hour) as { value: number }[]

        const p95Index = Math.floor(values.length * 0.95)
        const p95 = values.length > 0 ? values[Math.min(p95Index, values.length - 1)].value : null

        insertRollup.run({
          name: row.name,
          type: row.type,
          hour: row.hour,
          count: row.count,
          sum: row.sum,
          min: row.min,
          max: row.max,
          p95,
          tags: row.tags,
        })
      }
    })

    transaction(rows)
  }

  rotate(hours: number): void {
    const cutoff = new Date(Date.now() - hours * 3600000).toISOString()
    this.db.prepare('DELETE FROM metrics WHERE ts < ?').run(cutoff)
  }

  destroy(): void {
    if (this.flushTimer) {
      clearInterval(this.flushTimer)
      this.flushTimer = null
    }
    this.flush()
  }
}
