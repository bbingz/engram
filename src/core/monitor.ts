import { randomUUID } from 'crypto'
import type { Database } from './db.js'
import type { MonitorConfig } from './config.js'

export interface MonitorAlert {
  id: string
  category: 'cost_threshold' | 'long_session' | 'high_error_rate' | 'unpushed_commits'
  severity: 'info' | 'warning' | 'critical'
  title: string
  detail: string
  timestamp: string
  dismissed: boolean
}

export class BackgroundMonitor {
  private alerts: MonitorAlert[] = []
  private interval: ReturnType<typeof setInterval> | null = null
  private startupTimeout: ReturnType<typeof setTimeout> | null = null
  private db: Database
  private config: MonitorConfig
  private onAlert?: (alert: MonitorAlert) => void
  private liveMonitor?: { getSessions(): Array<{ startedAt: string; filePath: string; source: string; project?: string }> }

  constructor(db: Database, config: MonitorConfig, onAlert?: (alert: MonitorAlert) => void, liveMonitor?: BackgroundMonitor['liveMonitor']) {
    this.db = db
    this.config = config
    this.onAlert = onAlert
    this.liveMonitor = liveMonitor
  }

  start(intervalMs = 600_000): void {
    if (this.interval) return
    this.interval = setInterval(() => this.check().catch(() => {}), intervalMs)
    // Run initial check after a short delay (don't block startup)
    this.startupTimeout = setTimeout(() => {
      this.startupTimeout = null
      this.check().catch(() => {})
    }, 10_000)
  }

  stop(): void {
    if (this.startupTimeout) {
      clearTimeout(this.startupTimeout)
      this.startupTimeout = null
    }
    if (this.interval) {
      clearInterval(this.interval)
      this.interval = null
    }
  }

  isRunning(): boolean {
    return this.interval !== null
  }

  getAlerts(): MonitorAlert[] {
    return [...this.alerts]
  }

  dismissAlert(id: string): void {
    const alert = this.alerts.find(a => a.id === id)
    if (alert) alert.dismissed = true
  }

  async check(): Promise<void> {
    // Evict: prune dismissed alerts older than 24h, then cap at 100 most recent
    const oneDayAgo = Date.now() - 24 * 60 * 60 * 1000
    this.alerts = this.alerts.filter(
      a => !(a.dismissed && new Date(a.timestamp).getTime() < oneDayAgo)
    )
    if (this.alerts.length > 100) {
      this.alerts = this.alerts.slice(-100)
    }

    await this.checkDailyCost()
    await this.checkUnpushedCommits()
    this.checkLongSessions()
  }

  private async checkDailyCost(): Promise<void> {
    const budget = this.config.dailyCostBudget ?? 20
    try {
      const row = this.db.getRawDb().prepare(`
        SELECT COALESCE(SUM(c.cost_usd), 0) as totalCost
        FROM session_costs c
        JOIN sessions s ON c.session_id = s.id
        WHERE date(s.start_time) = date('now')
      `).get() as { totalCost: number } | undefined

      const totalCost = row?.totalCost ?? 0
      if (totalCost > budget) {
        // Only alert if we haven't already alerted for this threshold today
        const existingToday = this.alerts.find(
          a => a.category === 'cost_threshold' && a.timestamp.startsWith(new Date().toISOString().slice(0, 10))
        )
        if (!existingToday) {
          const alert: MonitorAlert = {
            id: randomUUID(),
            category: 'cost_threshold',
            severity: totalCost > budget * 2 ? 'critical' : 'warning',
            title: `Daily cost exceeded $${budget}`,
            detail: `Current daily spend: $${totalCost.toFixed(2)} (budget: $${budget})`,
            timestamp: new Date().toISOString(),
            dismissed: false,
          }
          this.alerts.push(alert)
          this.onAlert?.(alert)
        }
      }
    } catch { /* session_costs table may not exist yet */ }
  }

  private async checkUnpushedCommits(): Promise<void> {
    try {
      const rows = this.db.getRawDb().prepare(`
        SELECT name, path, unpushed_count FROM git_repos
        WHERE unpushed_count > 10
      `).all() as Array<{ name: string; path: string; unpushed_count: number }>

      for (const row of rows) {
        const existingForRepo = this.alerts.find(
          a => a.category === 'unpushed_commits' && a.detail.includes(row.path) && !a.dismissed
        )
        if (!existingForRepo) {
          const alert: MonitorAlert = {
            id: randomUUID(),
            category: 'unpushed_commits',
            severity: 'warning',
            title: `${row.name}: ${row.unpushed_count} unpushed commits`,
            detail: `Repository at ${row.path} has ${row.unpushed_count} unpushed commits`,
            timestamp: new Date().toISOString(),
            dismissed: false,
          }
          this.alerts.push(alert)
          this.onAlert?.(alert)
        }
      }
    } catch { /* git_repos table may not exist yet */ }
  }

  private checkLongSessions(): void {
    if (!this.liveMonitor) return
    const thresholdMs = (this.config.longSessionMinutes ?? 180) * 60 * 1000
    const now = Date.now()

    for (const session of this.liveMonitor.getSessions()) {
      if (!session.startedAt) continue
      const startMs = new Date(session.startedAt).getTime()
      if (isNaN(startMs)) continue
      const durationMs = now - startMs
      if (durationMs < thresholdMs) continue

      const durationHours = Math.round(durationMs / (60 * 60 * 1000) * 10) / 10
      const label = session.project || session.source

      // Skip if we already have an undismissed alert for this session file
      const existing = this.alerts.find(
        a => a.category === 'long_session' && a.detail.includes(session.filePath) && !a.dismissed
      )
      if (existing) continue

      const alert: MonitorAlert = {
        id: randomUUID(),
        category: 'long_session',
        severity: durationMs > thresholdMs * 2 ? 'critical' : 'warning',
        title: `${label}: session running ${durationHours}h`,
        detail: `Session at ${session.filePath} has been active for ${durationHours} hours`,
        timestamp: new Date().toISOString(),
        dismissed: false,
      }
      this.alerts.push(alert)
      this.onAlert?.(alert)
    }
  }
}
