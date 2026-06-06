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

type GenerateSummaryStatus =
  | 'not_found'
  | 'not_configured'
  | 'unsupported_source'
  | 'empty'
  | 'empty_response';

function statusResult(
  status: GenerateSummaryStatus,
  sessionId: string,
  message: string,
) {
  return {
    content: [{ type: 'text' as const, text: message }],
    structuredContent: { status, sessionId, message },
  };
}

function errorResult(message: string) {
  return {
    content: [{ type: 'text' as const, text: message }],
    isError: true,
    structuredContent: { error: { message } },
  };
}

function errorMessageFromBody(body: unknown): string | null {
  if (
    typeof body === 'object' &&
    body !== null &&
    'error' in body &&
    typeof (body as { error?: unknown }).error === 'string'
  ) {
    return (body as { error: string }).error;
  }
  return null;
}

export function generateSummaryStatusFromHttpError(
  httpStatus: number,
  body: unknown,
  sessionId: string,
) {
  const message = errorMessageFromBody(body);
  if (!message) return null;

  if (httpStatus === 404 && /^Session not found:/i.test(message)) {
    return statusResult('not_found', sessionId, message);
  }
  if (/API key not configured/i.test(message)) {
    return statusResult('not_configured', sessionId, message);
  }
  if (/^No adapter (available )?for source:/i.test(message)) {
    return statusResult('unsupported_source', sessionId, message);
  }
  if (/^No messages (found )?in session$/i.test(message)) {
    return statusResult('empty', sessionId, message);
  }
  if (/^Empty response from AI$/i.test(message)) {
    return statusResult('empty_response', sessionId, message);
  }

  return null;
}

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
    return statusResult(
      'not_found',
      sessionId,
      `Session not found: ${sessionId}`,
    );
  }

  // Get settings for AI configuration
  const settings = readFileSettings();

  if (!settings.aiApiKey) {
    return statusResult(
      'not_configured',
      sessionId,
      'API key not configured. Please set aiApiKey in Settings.',
    );
  }

  // Get adapter to read messages
  const adapter = getAdapter(session.source);
  if (!adapter) {
    return statusResult(
      'unsupported_source',
      sessionId,
      `No adapter available for source: ${session.source}`,
    );
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
    return errorResult(`Failed to read session messages: ${error}`);
  }

  if (messages.length === 0) {
    return statusResult('empty', sessionId, 'No messages found in session');
  }

  // Generate summary
  try {
    const summary = await summarizeConversation(messages, settings, {
      audit: opts?.audit,
      sessionId,
    });

    if (!summary) {
      return statusResult(
        'empty_response',
        sessionId,
        'Failed to generate summary: empty response from AI',
      );
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
    return errorResult(`Failed to generate summary: ${errorMessage}`);
  }
}
