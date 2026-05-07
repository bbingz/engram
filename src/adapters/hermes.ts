import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { isFileAccessible } from './_accessible.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  ToolCall,
} from './types.js';

interface HermesSession {
  session_id: string;
  model?: string;
  platform?: string;
  session_start?: string;
  last_updated?: string;
  cwd?: string;
  model_config?: { cwd?: string };
  message_count?: number;
  messages?: HermesMessage[];
}

interface HermesMessage {
  role?: string;
  content?: string;
  tool_calls?: Array<{
    id?: string;
    type?: string;
    function?: {
      name?: string;
      arguments?: string;
    };
  }>;
  tool_call_id?: string;
  tool_name?: string;
  finish_reason?: string;
  reasoning?: string;
}

function normalizeRole(role?: string): string {
  return role?.trim().toLowerCase() ?? '';
}

function cleanText(text?: string): string {
  return text?.trim() ?? '';
}

function looksLikeHermesPreamble(text: string): boolean {
  const lower = text.toLowerCase();
  return (
    lower.includes('[system: the user has invoked') ||
    lower.includes('[skill directory:') ||
    lower.includes('name: hermes-agent') ||
    lower.includes('resolve any relative paths in this skill')
  );
}

function normalizePath(path?: string): string {
  const trimmed = path?.trim();
  if (!trimmed) return '';
  return trimmed.startsWith('~') ? join(homedir(), trimmed.slice(1)) : trimmed;
}

function toToolCalls(message: HermesMessage): ToolCall[] | undefined {
  const calls = message.tool_calls
    ?.map((call) => ({
      name: call.function?.name ?? call.type ?? '',
      input: call.function?.arguments,
    }))
    .filter((call) => call.name);
  return calls && calls.length > 0 ? calls : undefined;
}

export class HermesAdapter implements SessionAdapter {
  readonly name = 'hermes' as const;
  private sessionsRoot: string;

  constructor(sessionsRoot?: string) {
    this.sessionsRoot = sessionsRoot ?? join(homedir(), '.hermes', 'sessions');
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.sessionsRoot);
      return true;
    } catch {
      return false;
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    let files: string[];
    try {
      files = await readdir(this.sessionsRoot);
    } catch {
      return;
    }
    for (const file of files) {
      if (file.startsWith('session_') && file.endsWith('.json')) {
        yield join(this.sessionsRoot, file);
      }
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      const session = await this.readSession(filePath);
      if (!session?.session_id) return null;
      const messages = session.messages ?? [];
      let userCount = 0;
      let assistantCount = 0;
      let toolCount = 0;
      let systemCount = 0;
      let summary = '';

      for (const message of messages) {
        const role = normalizeRole(message.role);
        const content = cleanText(message.content);
        if (role === 'user') {
          if (content && !looksLikeHermesPreamble(content)) {
            userCount++;
            if (!summary) summary = content;
          } else {
            systemCount++;
          }
        } else if (role === 'assistant') {
          assistantCount++;
          toolCount += message.tool_calls?.length ?? 0;
        } else if (role === 'tool') {
          toolCount++;
        } else if (role) {
          systemCount++;
        }
      }

      const cwd =
        normalizePath(session.cwd) || normalizePath(session.model_config?.cwd);
      return {
        id: session.session_id,
        source: 'hermes',
        startTime:
          session.session_start ?? new Date(fileStat.mtimeMs).toISOString(),
        endTime: session.last_updated,
        cwd,
        project: cleanText(session.platform) || undefined,
        model: session.model,
        messageCount: userCount + assistantCount + toolCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: toolCount,
        systemMessageCount: systemCount,
        summary:
          summary.slice(0, 200) ||
          `${cleanText(session.platform) || 'Hermes'} ${session.session_id}`,
        filePath,
        sizeBytes: fileStat.size,
      };
    } catch {
      return null;
    }
  }

  async *streamMessages(
    filePath: string,
    opts: StreamMessagesOptions = {},
  ): AsyncGenerator<Message> {
    const session = await this.readSession(filePath);
    if (!session) return;
    const messages = session?.messages ?? [];
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? Infinity;
    let count = 0;
    let yielded = 0;

    for (const message of messages) {
      if (yielded >= limit) break;
      const role = normalizeRole(message.role);
      let normalizedRole: Message['role'];
      if (role === 'user') normalizedRole = 'user';
      else if (role === 'assistant') normalizedRole = 'assistant';
      else if (role === 'tool') normalizedRole = 'tool';
      else continue;

      const content = cleanText(message.content);
      const toolCalls =
        normalizedRole === 'assistant' ? toToolCalls(message) : undefined;
      if (!content && !toolCalls?.length) continue;
      if (count < offset) {
        count++;
        continue;
      }
      count++;

      yield {
        role: normalizedRole,
        content: content || '[tool call]',
        timestamp: session.last_updated ?? session.session_start,
        toolCalls,
      };
      yielded++;
    }
  }

  private async readSession(filePath: string): Promise<HermesSession | null> {
    try {
      return JSON.parse(await readFile(filePath, 'utf8')) as HermesSession;
    } catch {
      return null;
    }
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}
