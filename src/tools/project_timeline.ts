// src/tools/project_timeline.ts
import type { Database } from '../core/db.js'
import type { Logger } from '../core/logger.js'
import { toLocalDateTime } from '../utils/time.js'

export const projectTimelineTool = {
  name: 'project_timeline',
  description: '查看某个项目跨工具的操作时间线，了解在不同 AI 助手里分别做了什么。',
  inputSchema: {
    type: 'object' as const,
    required: ['project'],
    properties: {
      project: { type: 'string', description: '项目名或路径片段' },
      since: { type: 'string' },
      until: { type: 'string' },
    },
    additionalProperties: false,
  },
}

export async function handleProjectTimeline(
  db: Database,
  params: { project: string; since?: string; until?: string },
  opts?: { log?: Logger }
) {
  opts?.log?.info('project_timeline invoked', { project: params.project })
  const sessions = db.listSessions({
    project: params.project,
    since: params.since,
    until: params.until,
    limit: 200,
  })

  const timeline = sessions
    .map(s => ({
      time: toLocalDateTime(s.startTime),
      source: s.source,
      summary: s.summary ?? '（无摘要）',
      sessionId: s.id,
      messageCount: s.messageCount,
    }))
    .sort((a, b) => a.time.localeCompare(b.time))

  return { project: params.project, timeline, total: timeline.length }
}
