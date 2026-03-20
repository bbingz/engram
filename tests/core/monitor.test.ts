import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'
import { BackgroundMonitor, type MonitorAlert } from '../../src/core/monitor.js'
import type { MonitorConfig } from '../../src/core/config.js'

describe('BackgroundMonitor', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
  })

  it('creates alerts when daily cost exceeds budget', async () => {
    // Insert a session with high cost
    db.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier)
      VALUES ('cost-s1', 'claude-code', datetime('now'), '/test', 'test', 'claude-opus-4-6', 100, 30, 50, 10, 10, '/test/s1.jsonl', 5000, 'premium')
    `)
    db.getRawDb().exec(`
      INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cost_usd, computed_at)
      VALUES ('cost-s1', 'claude-opus-4-6', 5000000, 500000, 25.50, datetime('now'))
    `)

    const config: MonitorConfig = {
      enabled: true,
      dailyCostBudget: 20,
    }
    const alerts: MonitorAlert[] = []
    const monitor = new BackgroundMonitor(db, config, (alert) => alerts.push(alert))
    await monitor.check()

    const costAlerts = alerts.filter(a => a.category === 'cost_threshold')
    expect(costAlerts.length).toBe(1)
    expect(costAlerts[0].severity).toBe('warning')
    expect(costAlerts[0].title).toContain('$20')
  })

  it('does not alert when cost is within budget', async () => {
    const freshDb = new Database(':memory:')
    freshDb.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier)
      VALUES ('low-s1', 'claude-code', datetime('now'), '/test', 'test', 'claude-sonnet-4-6', 10, 3, 5, 1, 1, '/test/low.jsonl', 500, 'normal')
    `)
    freshDb.getRawDb().exec(`
      INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cost_usd, computed_at)
      VALUES ('low-s1', 'claude-sonnet-4-6', 100000, 5000, 0.42, datetime('now'))
    `)

    const config: MonitorConfig = { enabled: true, dailyCostBudget: 20 }
    const alerts: MonitorAlert[] = []
    const monitor = new BackgroundMonitor(freshDb, config, (alert) => alerts.push(alert))
    await monitor.check()

    const costAlerts = alerts.filter(a => a.category === 'cost_threshold')
    expect(costAlerts.length).toBe(0)
  })

  it('stores and retrieves alerts', async () => {
    const config: MonitorConfig = { enabled: true, dailyCostBudget: 1 }
    const monitor = new BackgroundMonitor(db, config)
    await monitor.check()
    const alerts = monitor.getAlerts()
    expect(alerts.length).toBeGreaterThan(0)
  })

  it('dismisses alert by id', async () => {
    const config: MonitorConfig = { enabled: true, dailyCostBudget: 1 }
    const monitor = new BackgroundMonitor(db, config)
    await monitor.check()
    const alerts = monitor.getAlerts()
    const firstId = alerts[0].id
    monitor.dismissAlert(firstId)
    const after = monitor.getAlerts()
    const dismissed = after.find(a => a.id === firstId)
    expect(dismissed?.dismissed).toBe(true)
  })

  it('start/stop controls check interval', () => {
    const config: MonitorConfig = { enabled: true }
    const monitor = new BackgroundMonitor(db, config)
    monitor.start(600_000) // very long interval
    expect(monitor.isRunning()).toBe(true)
    monitor.stop()
    expect(monitor.isRunning()).toBe(false)
  })
})
