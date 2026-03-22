// src/core/usage-collector.ts
import type { UsageProbe, UsageSnapshot } from './usage-probe.js'
import type BetterSqlite3 from 'better-sqlite3'

export class UsageCollector {
  private probes: UsageProbe[] = []
  private timers: Map<string, ReturnType<typeof setInterval>> = new Map()
  private db: BetterSqlite3.Database
  private emit: (event: string, data: unknown) => void

  constructor(db: BetterSqlite3.Database, emit: (event: string, data: unknown) => void) {
    this.db = db
    this.emit = emit
  }

  register(probe: UsageProbe) {
    this.probes.push(probe)
  }

  start() {
    for (const probe of this.probes) {
      // Run immediately, then on interval
      this.runProbe(probe)
      const timer = setInterval(() => this.runProbe(probe), probe.interval)
      this.timers.set(probe.source, timer)
    }
  }

  stop() {
    for (const timer of this.timers.values()) {
      clearInterval(timer)
    }
    this.timers.clear()
  }

  private cleanup() {
    this.db.prepare(`DELETE FROM usage_snapshots WHERE collected_at < datetime('now', '-7 days')`).run()
  }

  private async runProbe(probe: UsageProbe) {
    try {
      this.cleanup()
      const snapshots = await probe.probe()
      this.storeSnapshots(snapshots)
      this.emit('usage', snapshots)
    } catch (err) {
      console.error(`[usage-collector] ${probe.source} probe failed:`, err) // stderr → os_log in daemon mode
    }
  }

  private storeSnapshots(snapshots: UsageSnapshot[]) {
    const insert = this.db.prepare(`
      INSERT INTO usage_snapshots (source, metric, value, reset_at, collected_at)
      VALUES (?, ?, ?, ?, ?)
    `)
    const tx = this.db.transaction((snaps: UsageSnapshot[]) => {
      for (const s of snaps) {
        insert.run(s.source, s.metric, s.value, s.resetAt ?? null, s.collectedAt)
      }
    })
    tx(snapshots)
  }

  getLatest(): UsageSnapshot[] {
    const rows = this.db.prepare(`
      SELECT source, metric, value, reset_at as resetAt, collected_at as collectedAt
      FROM usage_snapshots
      WHERE (source, metric, collected_at) IN (
        SELECT source, metric, MAX(collected_at)
        FROM usage_snapshots
        GROUP BY source, metric
      )
      ORDER BY source, metric
    `).all() as UsageSnapshot[]
    return rows
  }
}
