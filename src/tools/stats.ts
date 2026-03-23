// src/tools/stats.ts
import type { Database } from '../core/db.js'
import type { Logger } from '../core/logger.js'

export const statsTool = {
  name: 'stats',
  description: '统计各工具的会话数量、消息数等用量数据。',
  inputSchema: {
    type: 'object' as const,
    properties: {
      since: { type: 'string' },
      until: { type: 'string' },
      group_by: {
        type: 'string',
        enum: ['source', 'project', 'day', 'week'],
        description: '按维度分组，默认 source',
      },
    },
    additionalProperties: false,
  },
}

export async function handleStats(
  db: Database,
  params: { since?: string; until?: string; group_by?: string; exclude_noise?: boolean },
  opts?: { log?: Logger }
) {
  opts?.log?.info('stats invoked', { groupBy: params.group_by, since: params.since })
  const groupBy = params.group_by ?? 'source'
  const groups = db.statsGroupBy(groupBy, params.since, params.until, { excludeNoise: params.exclude_noise })
  const totalSessions = groups.reduce((sum, g) => sum + g.sessionCount, 0)

  return { groupBy, groups, totalSessions }
}
