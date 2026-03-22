import type { Database } from '../core/db.js'
import type { Logger } from '../core/logger.js'

export const getCostsTool = {
  name: 'get_costs',
  description: 'Get token usage costs across sessions, grouped by model, source, project, or day.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      group_by: { type: 'string', enum: ['model', 'source', 'project', 'day'], description: 'Group dimension (default: model)' },
      since: { type: 'string', description: 'Start time (ISO 8601)' },
      until: { type: 'string', description: 'End time (ISO 8601)' },
    },
    additionalProperties: false,
  },
}

export function handleGetCosts(db: Database, params: { group_by?: string; since?: string; until?: string }, opts?: { log?: Logger }) {
  opts?.log?.info('get_costs invoked', { groupBy: params.group_by, since: params.since })
  const breakdown = db.getCostsSummary({
    groupBy: params.group_by,
    since: params.since,
    until: params.until,
  })

  const totalCostUsd = breakdown.reduce((sum: number, r: any) => sum + (r.costUsd || 0), 0)
  const totalInputTokens = breakdown.reduce((sum: number, r: any) => sum + (r.inputTokens || 0), 0)
  const totalOutputTokens = breakdown.reduce((sum: number, r: any) => sum + (r.outputTokens || 0), 0)

  return {
    totalCostUsd: Math.round(totalCostUsd * 100) / 100,
    totalInputTokens,
    totalOutputTokens,
    breakdown,
  }
}
