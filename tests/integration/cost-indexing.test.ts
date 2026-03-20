import { describe, it, expect, beforeAll } from 'vitest'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'
import { Database } from '../../src/core/db.js'
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = resolve(__dirname, '../fixtures/claude-code/session-with-usage.jsonl')

describe('cost indexing integration', () => {
  let db: Database
  const adapter = new ClaudeCodeAdapter()

  beforeAll(async () => {
    db = new Database(':memory:')

    // Parse and index the fixture
    const info = await adapter.parseSessionInfo(FIXTURE)
    expect(info).toBeDefined()

    // Insert session
    db.getRawDb().prepare(`INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
      info!.id, info!.source, info!.startTime, info!.cwd, info!.project || '', info!.model || '', info!.messageCount, info!.userMessageCount, info!.assistantMessageCount, info!.toolMessageCount, info!.systemMessageCount, FIXTURE, info!.sizeBytes, 'normal'
    )

    // Stream messages and accumulate
    let inputTokens = 0, outputTokens = 0, cacheRead = 0, cacheCreate = 0
    const toolCounts = new Map<string, number>()
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      if (msg.usage) {
        inputTokens += msg.usage.inputTokens
        outputTokens += msg.usage.outputTokens
        cacheRead += msg.usage.cacheReadTokens ?? 0
        cacheCreate += msg.usage.cacheCreationTokens ?? 0
      }
      if (msg.toolCalls) {
        for (const tc of msg.toolCalls) {
          toolCounts.set(tc.name, (toolCounts.get(tc.name) || 0) + 1)
        }
      }
    }

    // Write extracted data
    if (inputTokens > 0) {
      const { computeCost } = await import('../../src/core/pricing.js')
      const cost = computeCost(info!.model || '', inputTokens, outputTokens, cacheRead, cacheCreate)
      db.upsertSessionCost(info!.id, info!.model || '', inputTokens, outputTokens, cacheRead, cacheCreate, cost)
    }
    if (toolCounts.size > 0) {
      db.upsertSessionTools(info!.id, toolCounts)
    }
  })

  it('stores token costs in session_costs', () => {
    const costs = db.getCostsSummary({})
    expect(costs.length).toBe(1)
    expect(costs[0].inputTokens).toBe(3500)  // 1500 + 2000
    expect(costs[0].outputTokens).toBe(150)   // 50 + 100
    expect(costs[0].costUsd).toBeGreaterThan(0)
  })

  it('stores tool calls in session_tools', () => {
    const tools = db.getToolAnalytics({})
    expect(tools.length).toBe(2) // Read + Edit
    const readTool = tools.find((t: any) => t.name === 'Read')
    expect(readTool).toBeDefined()
    expect(readTool.callCount).toBe(1)
    const editTool = tools.find((t: any) => t.name === 'Edit')
    expect(editTool).toBeDefined()
    expect(editTool.callCount).toBe(1)
  })

  it('computes cost correctly for claude-sonnet-4-6', () => {
    const costs = db.getCostsSummary({})
    // claude-sonnet-4-6: input=$3/M, output=$15/M, cacheRead=$0.3/M, cacheWrite=$3.75/M
    // input: 3500/1M * 3 = 0.0105
    // output: 150/1M * 15 = 0.00225
    // cacheRead: 2300/1M * 0.3 = 0.00069
    // cacheWrite: 1000/1M * 3.75 = 0.00375
    // total = 0.01719
    expect(costs[0].costUsd).toBeCloseTo(0.017, 2)
  })
})
