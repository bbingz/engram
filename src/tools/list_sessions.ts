// src/tools/list_sessions.ts
import type { Database, ListSessionsOptions } from '../core/db.js'
import type { SourceName } from '../adapters/types.js'

export const listSessionsTool = {
  name: 'list_sessions',
  description: '列出 AI 编程助手的历史会话。支持按工具来源、项目、时间范围过滤。',
  inputSchema: {
    type: 'object' as const,
    properties: {
      source: {
        type: 'string',
        enum: ['codex', 'claude-code', 'gemini-cli', 'opencode'],
        description: '过滤特定工具的会话',
      },
      project: { type: 'string', description: '过滤特定项目（部分匹配）' },
      since: { type: 'string', description: '开始时间（ISO 8601）' },
      until: { type: 'string', description: '结束时间（ISO 8601）' },
      limit: { type: 'number', description: '最多返回条数，默认 20，最大 100' },
      offset: { type: 'number', description: '分页偏移量' },
    },
    additionalProperties: false,
  },
}

export async function handleListSessions(
  db: Database,
  params: {
    source?: SourceName
    project?: string
    since?: string
    until?: string
    limit?: number
    offset?: number
  }
) {
  const opts: ListSessionsOptions = {
    source: params.source,
    project: params.project,
    since: params.since,
    until: params.until,
    limit: Math.min(params.limit ?? 20, 100),
    offset: params.offset ?? 0,
  }

  const sessions = db.listSessions(opts)

  return {
    sessions: sessions.map(s => ({
      id: s.id,
      source: s.source,
      startTime: s.startTime,
      endTime: s.endTime,
      cwd: s.cwd,
      project: s.project,
      model: s.model,
      messageCount: s.messageCount,
      userMessageCount: s.userMessageCount,
      summary: s.summary,
    })),
    total: sessions.length,
  }
}
