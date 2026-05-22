// src/tools/get_session.ts

import type { SessionAdapter } from '../adapters/types.js';
import type { Database } from '../core/db.js';
import type { Logger } from '../core/logger.js';

const PAGE_SIZE = 50;

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
};

export async function handleGetSession(
  db: Database,
  adapter: SessionAdapter,
  params: { id: string; page?: number; roles?: string[] },
  opts?: { log?: Logger },
) {
  opts?.log?.info('get_session invoked', { id: params.id, page: params.page });
  const session = db.getSession(params.id);
  if (!session) throw new Error(`Session not found: ${params.id}`);

  const page = Math.max(1, params.page ?? 1);
  const offset = (page - 1) * PAGE_SIZE;

  // Stream-and-window: only keep the messages that belong to the requested
  // page. Large sessions (10k+ messages) previously buffered everything just
  // to slice a 50-row window, which inflated memory for the MCP host.
  const messages: { role: string; content: string; timestamp?: string }[] = [];
  let matched = 0;
  for await (const msg of adapter.streamMessages(session.filePath)) {
    if (params.roles && !params.roles.includes(msg.role)) continue;
    if (matched >= offset && messages.length < PAGE_SIZE) {
      messages.push({
        role: msg.role,
        content: msg.content,
        timestamp: msg.timestamp,
      });
    }
    matched++;
  }

  const totalPages = Math.max(1, Math.ceil(matched / PAGE_SIZE));
  return { session, messages, totalPages, currentPage: page };
}
