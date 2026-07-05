// src/tools/get_session.ts

import type { SessionAdapter } from '../adapters/types.js';
import type { Database } from '../core/db.js';
import type { Logger } from '../core/logger.js';
import { isDefaultVisibleTranscriptMessage } from '../core/transcript-visibility.js';

const PAGE_SIZE = 50;

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
    if (!isDefaultVisibleTranscriptMessage(msg, session.source)) continue;
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
