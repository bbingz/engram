// src/tools/generate_summary.ts
import type { Database } from '../core/db.js';
import { getAdapter } from '../core/bootstrap.js';
import { summarizeConversation, type SummarizeOptions } from '../core/ai-client.js';
import { readFileSettings } from '../core/config.js';

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
  }
) {
  const { sessionId } = params;

  // Get session info from DB
  const session = db.getSession(sessionId);
  if (!session) {
    return {
      content: [{ type: 'text' as const, text: `Session not found: ${sessionId}` }],
      isError: true,
    };
  }

  // Get settings for AI configuration
  const settings = readFileSettings();
  const provider = settings.aiProvider || 'openai';
  const apiKey = provider === 'openai' ? settings.openaiApiKey : settings.anthropicApiKey;
  const model = provider === 'openai' ? settings.openaiModel : settings.anthropicModel;

  if (!apiKey) {
    return {
      content: [{ type: 'text' as const, text: `API key not configured for ${provider}. Please set it in Settings.` }],
      isError: true,
    };
  }

  // Get adapter to read messages
  const adapter = getAdapter(session.source);
  if (!adapter) {
    return {
      content: [{ type: 'text' as const, text: `No adapter available for source: ${session.source}` }],
      isError: true,
    };
  }

  // Read messages from session file
  const messages: Array<{ role: string; content: string }> = [];
  try {
    for await (const msg of adapter.streamMessages(session.filePath)) {
      messages.push({
        role: msg.role,
        content: msg.content,
      });
    }
  } catch (error) {
    return {
      content: [{ type: 'text' as const, text: `Failed to read session messages: ${error}` }],
      isError: true,
    };
  }

  if (messages.length === 0) {
    return {
      content: [{ type: 'text' as const, text: 'No messages found in session' }],
      isError: true,
    };
  }

  // Generate summary
  try {
    const options: SummarizeOptions = {
      provider: provider as 'openai' | 'anthropic',
      apiKey,
      model: model || (provider === 'openai' ? 'gpt-4o-mini' : 'claude-3-haiku-20240307'),
      maxTokens: 200,
    };

    const summary = await summarizeConversation(messages, options);

    if (!summary) {
      return {
        content: [{ type: 'text' as const, text: 'Failed to generate summary: empty response from AI' }],
        isError: true,
      };
    }

    // Update database with summary
    db.updateSessionSummary(sessionId, summary);

    return {
      content: [{ type: 'text' as const, text: summary }],
      metadata: {
        sessionId,
        messageCount: messages.length,
        provider,
      },
    };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: 'text' as const, text: `Failed to generate summary: ${errorMessage}` }],
      isError: true,
    };
  }
}
