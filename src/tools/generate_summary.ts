// src/tools/generate_summary.ts

import type { AiAuditWriter } from '../core/ai-audit.js';
import { summarizeConversation } from '../core/ai-client.js';
import { getAdapter } from '../core/bootstrap.js';
import { readFileSettings } from '../core/config.js';
import type { Database } from '../core/db.js';
import type { Logger } from '../core/logger.js';
import { loadBoundedMessages } from './message-loader.js';

export const generateSummaryTool = {
  name: 'generate_summary',
  description: 'Generate an AI summary for a conversation session',
  inputSchema: {
    type: 'object' as const,
    properties: {
      sessionId: {
        type: 'string',
        description: 'The session ID to summarize',
      },
    },
    required: ['sessionId'],
    additionalProperties: false,
  },
};

export async function handleGenerateSummary(
  db: Database,
  params: {
    sessionId: string;
  },
  opts?: { log?: Logger; audit?: AiAuditWriter },
) {
  opts?.log?.info('generate_summary invoked', { sessionId: params.sessionId });
  const { sessionId } = params;

  // Get session info from DB
  const session = db.getSession(sessionId);
  if (!session) {
    return {
      content: [
        { type: 'text' as const, text: `Session not found: ${sessionId}` },
      ],
      isError: true,
    };
  }

  // Get settings for AI configuration
  const settings = readFileSettings();

  if (!settings.aiApiKey) {
    return {
      content: [
        {
          type: 'text' as const,
          text: 'API key not configured. Please set aiApiKey in Settings.',
        },
      ],
      isError: true,
    };
  }

  // Get adapter to read messages
  const adapter = getAdapter(session.source);
  if (!adapter) {
    return {
      content: [
        {
          type: 'text' as const,
          text: `No adapter available for source: ${session.source}`,
        },
      ],
      isError: true,
    };
  }

  // Read messages from session file with a bounded sliding window so a
  // pathologically large session can't OOM the host (summary only needs the
  // head+tail sample anyway — see loadBoundedMessages).
  let messages: Array<{ role: string; content: string }>;
  let totalSeen: number;
  try {
    const loaded = await loadBoundedMessages(
      adapter.streamMessages(session.filePath),
    );
    messages = loaded.messages;
    totalSeen = loaded.totalSeen;
  } catch (error) {
    return {
      content: [
        {
          type: 'text' as const,
          text: `Failed to read session messages: ${error}`,
        },
      ],
      isError: true,
    };
  }

  if (messages.length === 0) {
    return {
      content: [
        { type: 'text' as const, text: 'No messages found in session' },
      ],
      isError: true,
    };
  }

  // Generate summary
  try {
    const summary = await summarizeConversation(messages, settings, {
      audit: opts?.audit,
      sessionId,
    });

    if (!summary) {
      return {
        content: [
          {
            type: 'text' as const,
            text: 'Failed to generate summary: empty response from AI',
          },
        ],
        isError: true,
      };
    }

    // Persist the true message count (totalSeen), not the bounded sample size.
    db.updateSessionSummary(sessionId, summary, totalSeen);

    return {
      content: [{ type: 'text' as const, text: summary }],
      metadata: {
        sessionId,
        messageCount: totalSeen,
        protocol: settings.aiProtocol || 'openai',
      },
    };
  } catch (error) {
    opts?.log?.error('generate_summary failed', { sessionId }, error);
    const errorMessage = error instanceof Error ? error.message : String(error);
    return {
      content: [
        {
          type: 'text' as const,
          text: `Failed to generate summary: ${errorMessage}`,
        },
      ],
      isError: true,
    };
  }
}
