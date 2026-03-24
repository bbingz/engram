// tests/core/cost-advisor.test.ts
import { describe, it, expect, beforeEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import { getCostSuggestions } from '../../src/core/cost-advisor.js'
import type { FileSettings } from '../../src/core/config.js'

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeDb(): Database {
  return new Database(':memory:')
}

function insertSession(
  db: Database,
  opts: {
    id: string
    model?: string
    startTime?: string
    project?: string
    messageCount?: number
  },
): void {
  const {
    id,
    model = 'claude-sonnet-4-6',
    startTime = new Date().toISOString(),
    project = 'test-project',
    messageCount = 10,
  } = opts
  db.getRawDb().prepare(`
    INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count,
      assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier)
    VALUES (?, 'claude-code', ?, '/test', ?, ?, ?, 3, 5, 1, 1, '/test/' || ? || '.jsonl', 1000, 'normal')
  `).run(id, startTime, project, model, messageCount, id)
}

function insertCost(
  db: Database,
  sessionId: string,
  model: string,
  input: number,
  output: number,
  cacheRead: number,
  cacheCreate: number,
  costUsd: number,
): void {
  db.upsertSessionCost(sessionId, model, input, output, cacheRead, cacheCreate, costUsd)
}

const emptyConfig: FileSettings = {}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('getCostSuggestions', () => {
  it('returns empty suggestions and zero summary for empty data', () => {
    const db = makeDb()
    const result = getCostSuggestions(db, emptyConfig)
    expect(result.suggestions).toHaveLength(0)
    expect(result.summary.totalSpent).toBe(0)
    expect(result.summary.projectedMonthly).toBe(0)
    expect(result.summary.potentialSavings).toBe(0)
  })

  it('detects opus overuse when opus is >70% of total and has short sessions', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    insertSession(db, { id: 's1', model: 'claude-opus-4-6', messageCount: 10, startTime: since })
    insertSession(db, { id: 's2', model: 'claude-opus-4-6', messageCount: 8, startTime: since })
    insertSession(db, { id: 's3', model: 'claude-sonnet-4-6', messageCount: 5, startTime: since })

    // Opus costs: 8.00, Sonnet cost: 0.50
    insertCost(db, 's1', 'claude-opus-4-6', 50000, 5000, 0, 0, 4.00)
    insertCost(db, 's2', 'claude-opus-4-6', 50000, 5000, 0, 0, 4.00)
    insertCost(db, 's3', 'claude-sonnet-4-6', 50000, 5000, 0, 0, 0.50)

    const result = getCostSuggestions(db, emptyConfig)
    const opusRule = result.suggestions.find(s => s.rule === 'opus-overuse')
    expect(opusRule).toBeDefined()
    expect(opusRule!.severity).toBe('high')
    expect(opusRule!.savings).toBeDefined()
  })

  it('detects low cache rate for Anthropic models', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    insertSession(db, { id: 's1', model: 'claude-sonnet-4-6', startTime: since })

    // Low cache: 5% cache read (5000 / (95000 + 5000))
    insertCost(db, 's1', 'claude-sonnet-4-6', 95000, 5000, 5000, 0, 0.50)

    const result = getCostSuggestions(db, emptyConfig)
    const cacheRule = result.suggestions.find(s => s.rule === 'low-cache-rate')
    expect(cacheRule).toBeDefined()
    expect(cacheRule!.severity).toBe('medium')
  })

  it('does not flag low cache rate for non-Anthropic models', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    insertSession(db, { id: 's1', model: 'gpt-4o', startTime: since })
    // Low cache but non-Anthropic model
    insertCost(db, 's1', 'gpt-4o', 95000, 5000, 0, 0, 1.00)

    const result = getCostSuggestions(db, emptyConfig)
    const cacheRule = result.suggestions.find(s => s.rule === 'low-cache-rate')
    // No Anthropic sessions → no cache rate rule
    expect(cacheRule).toBeUndefined()
  })

  it('detects over-budget when daily avg exceeds configured budget', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    insertSession(db, { id: 's1', model: 'claude-sonnet-4-6', startTime: since })
    insertCost(db, 's1', 'claude-sonnet-4-6', 1000000, 100000, 0, 0, 100.00) // $100 over 7 days = $14.28/day

    const config: FileSettings = { costAlerts: { dailyBudget: 5 } }
    const result = getCostSuggestions(db, config)
    const budgetRule = result.suggestions.find(s => s.rule === 'over-budget')
    expect(budgetRule).toBeDefined()
    expect(budgetRule!.severity).toBe('high')
  })

  it('skips over-budget rule when no budget configured', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    insertSession(db, { id: 's1', model: 'claude-sonnet-4-6', startTime: since })
    insertCost(db, 's1', 'claude-sonnet-4-6', 1000000, 100000, 0, 0, 100.00)

    const result = getCostSuggestions(db, emptyConfig)
    const budgetRule = result.suggestions.find(s => s.rule === 'over-budget')
    expect(budgetRule).toBeUndefined()
  })

  it('detects project hotspot when single project >50% of total', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    insertSession(db, { id: 's1', model: 'claude-sonnet-4-6', project: 'big-project', startTime: since })
    insertSession(db, { id: 's2', model: 'claude-sonnet-4-6', project: 'small-project', startTime: since })

    insertCost(db, 's1', 'claude-sonnet-4-6', 500000, 50000, 0, 0, 8.00)
    insertCost(db, 's2', 'claude-sonnet-4-6', 50000, 5000, 0, 0, 1.00)

    const result = getCostSuggestions(db, emptyConfig)
    const hotspotRule = result.suggestions.find(s => s.rule === 'project-hotspot')
    expect(hotspotRule).toBeDefined()
    expect(hotspotRule!.detail).toContain('big-project')
  })

  it('ranks models by cost-per-session efficiency', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    insertSession(db, { id: 's1', model: 'claude-opus-4-6', startTime: since })
    insertSession(db, { id: 's2', model: 'claude-sonnet-4-6', startTime: since })
    insertSession(db, { id: 's3', model: 'claude-sonnet-4-6', startTime: since })

    insertCost(db, 's1', 'claude-opus-4-6', 100000, 10000, 0, 0, 10.00) // $10/session
    insertCost(db, 's2', 'claude-sonnet-4-6', 100000, 10000, 0, 0, 0.50) // $0.25/session
    insertCost(db, 's3', 'claude-sonnet-4-6', 100000, 10000, 0, 0, 0.50)

    const result = getCostSuggestions(db, emptyConfig)
    const effRule = result.suggestions.find(s => s.rule === 'model-efficiency')
    expect(effRule).toBeDefined()
    // Opus is most expensive
    expect(effRule!.detail).toContain('claude-opus-4-6')
  })

  it('computes summary with projected monthly', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    insertSession(db, { id: 's1', model: 'claude-sonnet-4-6', startTime: since })
    insertCost(db, 's1', 'claude-sonnet-4-6', 100000, 10000, 0, 0, 7.00) // $7 over 7 days → $30/month

    const result = getCostSuggestions(db, emptyConfig)
    expect(result.summary.totalSpent).toBeCloseTo(7.0, 1)
    expect(result.summary.projectedMonthly).toBeCloseTo(30.0, 0)
  })

  it('detects expensive sessions (>$5 and >200K tokens)', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    insertSession(db, { id: 's1', model: 'claude-sonnet-4-6', startTime: since })
    // $6 cost, 300K total tokens
    insertCost(db, 's1', 'claude-sonnet-4-6', 200000, 100000, 0, 0, 6.00)

    const result = getCostSuggestions(db, emptyConfig)
    const expRule = result.suggestions.find(s => s.rule === 'expensive-sessions')
    expect(expRule).toBeDefined()
    expect(expRule!.severity).toBe('medium')
  })

  it('detects week-over-week spike', () => {
    const db = makeDb()
    const now = new Date()

    // Last week: sessions 8-14 days ago
    for (let i = 0; i < 3; i++) {
      const d = new Date(now)
      d.setDate(d.getDate() - (8 + i))
      const id = `last-${i}`
      insertSession(db, { id, model: 'claude-sonnet-4-6', startTime: d.toISOString() })
      insertCost(db, id, 'claude-sonnet-4-6', 100000, 10000, 0, 0, 1.00) // $3 last week
    }

    // This week: much more expensive
    for (let i = 0; i < 3; i++) {
      const d = new Date(now)
      d.setDate(d.getDate() - i)
      const id = `this-${i}`
      insertSession(db, { id, model: 'claude-sonnet-4-6', startTime: d.toISOString() })
      insertCost(db, id, 'claude-sonnet-4-6', 1000000, 100000, 0, 0, 10.00) // $30 this week
    }

    const result = getCostSuggestions(db, emptyConfig)
    const spikeRule = result.suggestions.find(s => s.rule === 'wow-spike')
    expect(spikeRule).toBeDefined()
    expect(spikeRule!.severity).toBe('high')
  })

  it('detects output imbalance excluding heavy edit sessions', () => {
    const db = makeDb()
    const since = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()

    // Session with high output/input but no heavy editing
    insertSession(db, { id: 's1', model: 'claude-sonnet-4-6', startTime: since })
    insertCost(db, 's1', 'claude-sonnet-4-6', 10000, 50000, 0, 0, 1.00) // ratio = 5x

    // Session with high ratio but heavy edit usage — should be excluded
    insertSession(db, { id: 's2', model: 'claude-sonnet-4-6', startTime: since })
    insertCost(db, 's2', 'claude-sonnet-4-6', 10000, 50000, 0, 0, 1.00)
    db.getRawDb().prepare(`
      INSERT INTO session_tools (session_id, tool_name, call_count) VALUES (?, 'Write', 15)
    `).run('s2')

    const result = getCostSuggestions(db, emptyConfig)
    const imbalanceRule = result.suggestions.find(s => s.rule === 'output-imbalance')
    expect(imbalanceRule).toBeDefined()
    // s1 should be flagged, s2 excluded
    expect(imbalanceRule!.topItems?.find(i => i.label === 'Sessions affected')?.value).toBe(1)
  })
})
