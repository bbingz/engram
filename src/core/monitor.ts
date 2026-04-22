import { randomUUID } from 'node:crypto';
import { getLocalTimeRange } from '../utils/time.js';
import type { MonitorConfig } from './config.js';
import type { Database } from './db.js';
import { runAllHealthChecks } from './health-rules.js';

export interface MonitorAlert {
  id: string;
  category:
    | 'cost_threshold'
    | 'cost_budget'
    | 'long_session'
    | 'high_error_rate'
    | 'unpushed_commits';
  severity: 'info' | 'warning' | 'critical';
  title: string;
  detail: string;
  timestamp: string;
  dismissed: boolean;
}

export class BackgroundMonitor {
  private alerts: MonitorAlert[] = [];
  private interval: ReturnType<typeof setInterval> | null = null;
  private startupTimeout: ReturnType<typeof setTimeout> | null = null;
  private db: Database;
  private config: MonitorConfig;
  private onAlert?: (alert: MonitorAlert) => void;
  private nowProvider: () => Date;
  private timeZone: string;
  private liveMonitor?: {
    getSessions(): Array<{
      startedAt: string;
      filePath: string;
      source: string;
      project?: string;
    }>;
  };

  constructor(
    db: Database,
    config: MonitorConfig,
    onAlert?: (alert: MonitorAlert) => void,
    liveMonitor?: BackgroundMonitor['liveMonitor'],
    nowProvider: () => Date = () => new Date(),
    timeZone: string = Intl.DateTimeFormat().resolvedOptions().timeZone,
  ) {
    this.db = db;
    this.config = config;
    this.onAlert = onAlert;
    this.liveMonitor = liveMonitor;
    this.nowProvider = nowProvider;
    this.timeZone = timeZone;
  }

  start(intervalMs = 600_000): void {
    if (this.interval) return;
    this.interval = setInterval(() => this.check().catch(() => {}), intervalMs); // intentional: periodic check, errors handled within check()
    // Run initial check after a short delay (don't block startup)
    this.startupTimeout = setTimeout(() => {
      this.startupTimeout = null;
      this.check().catch(() => {}); // intentional: startup check, errors handled within check()
    }, 10_000);
  }

  stop(): void {
    if (this.startupTimeout) {
      clearTimeout(this.startupTimeout);
      this.startupTimeout = null;
    }
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
  }

  isRunning(): boolean {
    return this.interval !== null;
  }

  getAlerts(): MonitorAlert[] {
    return [...this.alerts];
  }

  dismissAlert(id: string): void {
    const alert = this.alerts.find((a) => a.id === id);
    if (alert) alert.dismissed = true;
  }

  async check(): Promise<void> {
    const now = this.nowProvider();
    const range = getLocalTimeRange(now, this.timeZone);

    // Evict dismissed alerts older than 24h before running checks
    const oneDayAgo = Date.now() - 24 * 60 * 60 * 1000;
    this.alerts = this.alerts.filter(
      (a) => !(a.dismissed && new Date(a.timestamp).getTime() < oneDayAgo),
    );

    await this.checkDailyCost(now, range);
    await this.checkCostBudget(now, range);
    await this.checkUnpushedCommits();
    this.checkLongSessions();
    await this.checkHealthRules();

    // Cap at 100 most recent AFTER all checks complete,
    // so new alerts from this cycle are included in the cap
    if (this.alerts.length > 100) {
      this.alerts = this.alerts.slice(-100);
    }
  }

  private isSameLocalDay(timestamp: string, localDate: string): boolean {
    return (
      getLocalTimeRange(new Date(timestamp), this.timeZone).localDate ===
      localDate
    );
  }

  private isSameLocalMonth(timestamp: string, localMonth: string): boolean {
    return (
      getLocalTimeRange(new Date(timestamp), this.timeZone).localMonth ===
      localMonth
    );
  }

  private async checkDailyCost(
    now: Date,
    range: ReturnType<typeof getLocalTimeRange>,
  ): Promise<void> {
    const budget = this.config.dailyCostBudget ?? 20;
    try {
      const row = this.db
        .getRawDb()
        .prepare(`
        SELECT COALESCE(SUM(c.cost_usd), 0) as totalCost
        FROM session_costs c
        JOIN sessions s ON c.session_id = s.id
        WHERE datetime(s.start_time) >= datetime(?) AND datetime(s.start_time) < datetime(?)
      `)
        .get(range.startUtcIso, range.endUtcIso) as
        | { totalCost: number }
        | undefined;

      const totalCost = row?.totalCost ?? 0;
      if (totalCost > budget) {
        // Only alert if we haven't already alerted for this threshold today
        const existingToday = this.alerts.find(
          (a) =>
            a.category === 'cost_threshold' &&
            this.isSameLocalDay(a.timestamp, range.localDate),
        );
        if (!existingToday) {
          const alert: MonitorAlert = {
            id: randomUUID(),
            category: 'cost_threshold',
            severity: totalCost > budget * 2 ? 'critical' : 'warning',
            title: `Daily cost exceeded $${budget}`,
            detail: `Current daily spend: $${totalCost.toFixed(2)} (budget: $${budget})`,
            timestamp: now.toISOString(),
            dismissed: false,
          };
          this.alerts.push(alert);
          this.onAlert?.(alert);
        }
      }
    } catch {
      /* intentional: session_costs table may not exist yet */
    }
  }

  private async checkCostBudget(
    now: Date,
    range: ReturnType<typeof getLocalTimeRange>,
  ): Promise<void> {
    const dailyBudget = this.config.dailyCostBudget;
    const monthlyBudget = this.config.monthlyCostBudget;
    if (!dailyBudget && !monthlyBudget) return;

    try {
      if (dailyBudget) {
        const row = this.db
          .getRawDb()
          .prepare(`
          SELECT COALESCE(SUM(c.cost_usd), 0) as totalCost
          FROM session_costs c
          JOIN sessions s ON c.session_id = s.id
          WHERE datetime(s.start_time) >= datetime(?) AND datetime(s.start_time) < datetime(?)
        `)
          .get(range.startUtcIso, range.endUtcIso) as
          | { totalCost: number }
          | undefined;
        const totalCost = row?.totalCost ?? 0;
        const pct = Math.round((totalCost / dailyBudget) * 100);

        if (pct >= 80) {
          const existing = this.alerts.find(
            (a) =>
              a.category === 'cost_budget' &&
              a.detail.includes('Daily') &&
              this.isSameLocalDay(a.timestamp, range.localDate),
          );
          if (!existing) {
            const alert: MonitorAlert = {
              id: randomUUID(),
              category: 'cost_budget',
              severity: pct >= 100 ? 'critical' : 'warning',
              title:
                pct >= 100
                  ? `Daily cost $${totalCost.toFixed(2)} exceeds budget $${dailyBudget.toFixed(2)}`
                  : `Daily cost approaching budget (${pct}%)`,
              detail: `Daily spend: $${totalCost.toFixed(2)} of $${dailyBudget.toFixed(2)} budget (${pct}%)`,
              timestamp: now.toISOString(),
              dismissed: false,
            };
            this.alerts.push(alert);
            this.onAlert?.(alert);
          }
        }
      }

      if (monthlyBudget) {
        const row = this.db
          .getRawDb()
          .prepare(`
          SELECT COALESCE(SUM(c.cost_usd), 0) as totalCost
          FROM session_costs c
          JOIN sessions s ON c.session_id = s.id
          WHERE datetime(s.start_time) >= datetime(?) AND datetime(s.start_time) < datetime(?)
        `)
          .get(range.monthStartUtcIso, range.nextMonthStartUtcIso) as
          | { totalCost: number }
          | undefined;
        const totalCost = row?.totalCost ?? 0;
        const pct = Math.round((totalCost / monthlyBudget) * 100);

        if (pct >= 80) {
          const existing = this.alerts.find(
            (a) =>
              a.category === 'cost_budget' &&
              a.detail.includes('Monthly') &&
              this.isSameLocalMonth(a.timestamp, range.localMonth),
          );
          if (!existing) {
            const alert: MonitorAlert = {
              id: randomUUID(),
              category: 'cost_budget',
              severity: pct >= 100 ? 'critical' : 'warning',
              title:
                pct >= 100
                  ? `Monthly cost $${totalCost.toFixed(2)} exceeds budget $${monthlyBudget.toFixed(2)}`
                  : `Monthly cost approaching budget (${pct}%)`,
              detail: `Monthly spend: $${totalCost.toFixed(2)} of $${monthlyBudget.toFixed(2)} budget (${pct}%)`,
              timestamp: now.toISOString(),
              dismissed: false,
            };
            this.alerts.push(alert);
            this.onAlert?.(alert);
          }
        }
      }
    } catch {
      /* intentional: session_costs table may not exist yet */
    }
  }

  private async checkUnpushedCommits(): Promise<void> {
    try {
      const rows = this.db
        .getRawDb()
        .prepare(`
        SELECT name, path, unpushed_count FROM git_repos
        WHERE unpushed_count > 10
      `)
        .all() as Array<{ name: string; path: string; unpushed_count: number }>;

      for (const row of rows) {
        const existingForRepo = this.alerts.find(
          (a) =>
            a.category === 'unpushed_commits' &&
            a.detail.includes(row.path) &&
            !a.dismissed,
        );
        if (!existingForRepo) {
          const alert: MonitorAlert = {
            id: randomUUID(),
            category: 'unpushed_commits',
            severity: 'warning',
            title: `${row.name}: ${row.unpushed_count} unpushed commits`,
            detail: `Repository at ${row.path} has ${row.unpushed_count} unpushed commits`,
            timestamp: new Date().toISOString(),
            dismissed: false,
          };
          this.alerts.push(alert);
          this.onAlert?.(alert);
        }
      }
    } catch {
      /* intentional: git_repos table may not exist yet */
    }
  }

  private async checkHealthRules(): Promise<void> {
    try {
      const healthResult = await runAllHealthChecks(this.db, {
        scope: 'global',
      });
      for (const issue of healthResult.issues) {
        if (issue.severity === 'error') {
          const existing = this.alerts.find(
            (a) =>
              a.category === 'high_error_rate' &&
              a.title === issue.message &&
              !a.dismissed,
          );
          if (!existing) {
            const alert: MonitorAlert = {
              id: randomUUID(),
              category: 'high_error_rate',
              severity: 'warning',
              title: issue.message,
              detail:
                issue.detail ?? issue.action ?? `Health check: ${issue.kind}`,
              timestamp: new Date().toISOString(),
              dismissed: false,
            };
            this.alerts.push(alert);
            this.onAlert?.(alert);
          }
        }
      }
    } catch {
      /* best-effort */
    }
  }

  private checkLongSessions(): void {
    if (!this.liveMonitor) return;
    const thresholdMs = (this.config.longSessionMinutes ?? 180) * 60 * 1000;
    const now = Date.now();

    for (const session of this.liveMonitor.getSessions()) {
      if (!session.startedAt) continue;
      const startMs = new Date(session.startedAt).getTime();
      if (Number.isNaN(startMs)) continue;
      const durationMs = now - startMs;
      if (durationMs < thresholdMs) continue;

      const durationHours =
        Math.round((durationMs / (60 * 60 * 1000)) * 10) / 10;
      const label = session.project || session.source;

      // Skip if we already have an undismissed alert for this session file
      const existing = this.alerts.find(
        (a) =>
          a.category === 'long_session' &&
          a.detail.includes(session.filePath) &&
          !a.dismissed,
      );
      if (existing) continue;

      const alert: MonitorAlert = {
        id: randomUUID(),
        category: 'long_session',
        severity: durationMs > thresholdMs * 2 ? 'critical' : 'warning',
        title: `${label}: session running ${durationHours}h`,
        detail: `Session at ${session.filePath} has been active for ${durationHours} hours`,
        timestamp: new Date().toISOString(),
        dismissed: false,
      };
      this.alerts.push(alert);
      this.onAlert?.(alert);
    }
  }
}
