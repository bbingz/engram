// src/adapters/pi.ts
import { createReadStream } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { createInterface } from 'node:readline';
import { isFileAccessible } from './_accessible.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  TokenUsage,
  ToolCall,
} from './types.js';

interface PiContentPart {
  type?: string;
  text?: string;
  name?: string;
  arguments?: unknown;
}

interface PiMessage {
  role?: string;
  content?: PiContentPart[];
  model?: string;
  usage?: {
    input?: number;
    output?: number;
    cacheRead?: number;
    cacheWrite?: number;
  };
}

export class PiAdapter implements SessionAdapter {
  readonly name = 'pi' as const;
  private sessionsRoot: string;

  constructor(sessionsRoot?: string) {
    this.sessionsRoot =
      sessionsRoot ?? join(homedir(), '.pi', 'agent', 'sessions');
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
    try {
      yield* this.walkJsonlFiles(this.sessionsRoot);
    } catch {
      // sessions root does not exist
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      let sessionId = '';
      let startTime = '';
      let endTime = '';
      let cwd = '';
      let model: string | undefined;
      let userCount = 0;
      let assistantCount = 0;
      let toolCount = 0;
      let systemCount = 0;
      let firstUserText = '';

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;

        if (typeof obj.timestamp === 'string') {
          if (!startTime) startTime = obj.timestamp;
          endTime = obj.timestamp;
        }

        if (obj.type === 'session') {
          sessionId = (obj.id as string) || sessionId;
          cwd = (obj.cwd as string) || cwd;
          startTime = (obj.timestamp as string) || startTime;
          continue;
        }

        if (obj.type === 'model_change') {
          model = (obj.modelId as string) || model;
          continue;
        }

        if (obj.type !== 'message') continue;
        const msg = obj.message as PiMessage | undefined;
        const role = msg?.role;
        if (!role) continue;
        if (!model && typeof msg?.model === 'string') model = msg.model;

        if (role === 'user') {
          const text = this.extractText(msg.content);
          if (this.isSystemInjection(text)) {
            systemCount++;
          } else {
            userCount++;
            if (!firstUserText) firstUserText = text;
          }
        } else if (role === 'assistant') {
          assistantCount++;
        } else if (role === 'toolResult') {
          toolCount++;
        } else if (role === 'system') {
          systemCount++;
        }
      }

      if (!sessionId) sessionId = this.idFromFileName(filePath);
      if (!sessionId || !startTime) return null;

      return {
        id: sessionId,
        source: 'pi',
        startTime,
        endTime: endTime && endTime !== startTime ? endTime : undefined,
        cwd,
        model,
        messageCount: userCount + assistantCount + toolCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: toolCount,
        systemMessageCount: systemCount,
        summary: firstUserText.slice(0, 200) || undefined,
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
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? Infinity;
    let count = 0;
    let yielded = 0;

    for await (const line of this.readLines(filePath)) {
      if (yielded >= limit) break;
      const obj = this.parseLine(line);
      if (!obj || obj.type !== 'message') continue;

      const msg = obj.message as PiMessage | undefined;
      const role = msg?.role;
      if (!role) continue;

      const timestamp = obj.timestamp as string | undefined;
      let built: Message | null = null;

      if (role === 'user' || role === 'assistant' || role === 'system') {
        built = {
          role,
          content: this.extractText(msg.content),
          timestamp,
        };
        if (role === 'assistant') {
          const toolCalls = this.extractToolCalls(msg.content);
          if (toolCalls.length) built.toolCalls = toolCalls;
          const usage = this.extractUsage(msg);
          if (usage) built.usage = usage;
        }
      } else if (role === 'toolResult') {
        built = {
          role: 'tool',
          content: this.extractText(msg.content),
          timestamp,
        };
      }

      if (!built) continue;
      if (this.isSystemInjection(built.content) && built.role === 'user') {
        built.role = 'system';
      }

      if (count < offset) {
        count++;
        continue;
      }
      count++;
      yield built;
      yielded++;
    }
  }

  private async *walkJsonlFiles(dir: string): AsyncGenerator<string> {
    const entries = await readdir(dir, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        yield* this.walkJsonlFiles(fullPath);
      } else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        yield fullPath;
      }
    }
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    for await (const line of rl) {
      if (line.trim()) yield line;
    }
  }

  private parseLine(line: string): Record<string, unknown> | null {
    try {
      return JSON.parse(line) as Record<string, unknown>;
    } catch {
      return null;
    }
  }

  private idFromFileName(filePath: string): string {
    const file = basename(filePath).replace(/\.jsonl$/, '');
    const idx = file.indexOf('_');
    return idx >= 0 ? file.slice(idx + 1) : file;
  }

  private extractText(content: PiContentPart[] | undefined): string {
    if (!Array.isArray(content)) return '';
    const texts: string[] = [];
    for (const part of content) {
      if (part.type === 'text' && typeof part.text === 'string') {
        texts.push(part.text);
      }
    }
    return texts.join('\n');
  }

  private extractToolCalls(content: PiContentPart[] | undefined): ToolCall[] {
    if (!Array.isArray(content)) return [];
    const calls: ToolCall[] = [];
    for (const part of content) {
      if (part.type !== 'toolCall' || typeof part.name !== 'string') continue;
      calls.push({
        name: part.name,
        input:
          part.arguments !== undefined
            ? JSON.stringify(part.arguments)
            : undefined,
      });
    }
    return calls;
  }

  private extractUsage(message: PiMessage): TokenUsage | undefined {
    const usage = message.usage;
    if (!usage) return undefined;
    return {
      inputTokens: usage.input ?? 0,
      outputTokens: usage.output ?? 0,
      cacheReadTokens: usage.cacheRead,
      cacheCreationTokens: usage.cacheWrite,
    };
  }

  private isSystemInjection(text: string): boolean {
    return (
      text.startsWith('# AGENTS.md instructions for ') ||
      text.includes('<INSTRUCTIONS>') ||
      text.startsWith('<local-command-caveat>') ||
      text.startsWith('<environment_context>')
    );
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}
