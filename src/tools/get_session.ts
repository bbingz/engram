// src/tools/get_session.ts
import type { Database } from '../core/db.js'
import type { SessionAdapter } from '../adapters/types.js'

const PAGE_SIZE = 50

export const getSessionTool = {
  name: 'get_session',
  description: '读取单个会话的完整对话内容。大会话支持分页（每页 50 条消息）。',
  inputSchema: {
    type: 'object' as const,
    required: ['id'],
    properties: {
      id: { type: 'string', description: '会话 ID' },
      page: { type: 'number', description: '页码，从 1 开始，默认 1' },
      roles: {
        type: 'array',
        items: { type: 'string', enum: ['user', 'assistant'] },
        description: '只返回指定角色的消息，默认返回全部',
      },
    },
    additionalProperties: false,
  },
}

export async function handleGetSession(
  db: Database,
  adapter: SessionAdapter,
  params: { id: string; page?: number; roles?: string[] }
) {
  const session = db.getSession(params.id)
  if (!session) throw new Error(`Session not found: ${params.id}`)

  const page = params.page ?? 1
  const offset = (page - 1) * PAGE_SIZE

  const allMessages: { role: string; content: string; timestamp?: string }[] = []
  for await (const msg of adapter.streamMessages(session.filePath)) {
    if (!params.roles || params.roles.includes(msg.role)) {
      allMessages.push({ role: msg.role, content: msg.content, timestamp: msg.timestamp })
    }
  }

  const totalPages = Math.max(1, Math.ceil(allMessages.length / PAGE_SIZE))
  const messages = allMessages.slice(offset, offset + PAGE_SIZE)

  return { session, messages, totalPages, currentPage: page }
}
