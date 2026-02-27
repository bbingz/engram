// src/tools/stats.ts
import type { Database } from '../core/db.js'

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
  params: { since?: string; until?: string; group_by?: string }
) {
  const groupBy = params.group_by ?? 'source'
  const sessions = db.listSessions({ since: params.since, until: params.until, limit: 10000 })

  const groups: Record<string, { sessionCount: number; messageCount: number; userMessageCount: number }> = {}

  for (const s of sessions) {
    let key: string
    if (groupBy === 'source') key = s.source
    else if (groupBy === 'project') key = s.project ?? '(unknown)'
    else if (groupBy === 'day') key = s.startTime.slice(0, 10)
    else if (groupBy === 'week') {
      const d = new Date(s.startTime)
      d.setDate(d.getDate() - d.getDay())
      key = d.toISOString().slice(0, 10)
    } else key = s.source

    if (!groups[key]) groups[key] = { sessionCount: 0, messageCount: 0, userMessageCount: 0 }
    groups[key].sessionCount++
    groups[key].messageCount += s.messageCount
    groups[key].userMessageCount += s.userMessageCount
  }

  return {
    groupBy,
    groups: Object.entries(groups)
      .map(([key, val]) => ({ key, ...val }))
      .sort((a, b) => b.sessionCount - a.sessionCount),
    totalSessions: sessions.length,
  }
}
