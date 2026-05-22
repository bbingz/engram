// src/tools/export.ts

import { once } from 'node:events';
import { createWriteStream } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { SessionAdapter } from '../adapters/types.js';
import type { Database } from '../core/db.js';
import type { Logger } from '../core/logger.js';
import { toLocalDate, toLocalDateTime } from '../utils/time.js';

export const exportTool = {
  name: 'export',
  description:
    '将单个会话导出为 Markdown 或 JSON 文件，保存到 ~/codex-exports/ 目录。',
  inputSchema: {
    type: 'object' as const,
    required: ['id'],
    properties: {
      id: { type: 'string', description: '会话 ID' },
      format: {
        type: 'string',
        enum: ['markdown', 'json'],
        description: '默认 markdown',
      },
    },
    additionalProperties: false,
  },
};

export async function handleExport(
  db: Database,
  adapter: SessionAdapter,
  params: { id: string; format?: string },
  opts?: { log?: Logger },
) {
  opts?.log?.info('export invoked', { id: params.id, format: params.format });
  const session = db.getSession(params.id);
  if (!session) throw new Error(`Session not found: ${params.id}`);

  const format = params.format ?? 'markdown';

  const outputDir = join(homedir(), 'codex-exports');
  await mkdir(outputDir, { recursive: true });

  const safeId = session.id.slice(0, 8);
  const filename = `${session.source}-${safeId}-${toLocalDate(session.startTime)}.${format === 'json' ? 'json' : 'md'}`;
  const outputPath = join(outputDir, filename);

  // Stream messages straight to disk instead of buffering the entire session
  // in memory first. A 100k-message session would otherwise allocate ~100MB+
  // before a single byte hit the file, risking OOM on the host.
  const stream = createWriteStream(outputPath, { encoding: 'utf8' });
  const write = async (chunk: string): Promise<void> => {
    if (!stream.write(chunk)) {
      // Respect backpressure so a slow disk can't let the pending-write
      // buffer grow unbounded.
      await once(stream, 'drain');
    }
  };

  let messageCount = 0;
  try {
    if (format === 'json') {
      // Build the JSON document incrementally so the messages array is never
      // fully materialized in memory.
      await write(`{\n  "session": ${JSON.stringify(session, null, 2)},\n`);
      await write('  "messages": [');
      for await (const msg of adapter.streamMessages(session.filePath)) {
        await write(messageCount === 0 ? '\n' : ',\n');
        await write(
          `    ${JSON.stringify({
            role: msg.role,
            content: msg.content,
            timestamp: msg.timestamp,
          })}`,
        );
        messageCount++;
      }
      await write(messageCount === 0 ? ']\n}\n' : '\n  ]\n}\n');
    } else {
      await write(
        [
          `# Session: ${session.id}`,
          '',
          `**Source:** ${session.source}`,
          `**Date:** ${toLocalDateTime(session.startTime)}`,
          `**Project:** ${session.project ?? session.cwd}`,
          `**Messages:** ${session.messageCount}`,
          '',
          '---',
          '',
          '',
        ].join('\n'),
      );
      for await (const msg of adapter.streamMessages(session.filePath)) {
        await write(
          `### ${msg.role === 'user' ? '👤 User' : '🤖 Assistant'}\n\n${msg.content}\n\n---\n\n`,
        );
        messageCount++;
      }
    }
  } finally {
    stream.end();
    await once(stream, 'finish');
  }

  return { outputPath, format, messageCount };
}
