// src/adapters/codex.ts
import { createReadStream } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import { isFileAccessible } from './_accessible.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
} from './types.js';

export class CodexAdapter implements SessionAdapter {
  readonly name = 'codex' as const;
  private sessionRoots: string[];

  constructor(sessionsRoot?: string) {
    const root = sessionsRoot ?? join(homedir(), '.codex', 'sessions');
    this.sessionRoots = this.expandSessionRoots(root);
  }

  async detect(): Promise<boolean> {
    for (const root of this.sessionRoots) {
      try {
        await stat(root);
        return true;
      } catch {
        // try next root
      }
    }
    return false;
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    for (const root of this.sessionRoots) {
      try {
        for await (const file of this.walkRolloutFiles(root)) {
          yield file;
        }
      } catch {
        // sessions root 不存在时静默返回
      }
    }
  }

  private expandSessionRoots(root: string): string[] {
    if (basename(root) !== 'sessions') return [root];
    return [root, join(dirname(root), 'archived_sessions')];
  }

  private async *walkRolloutFiles(dir: string): AsyncGenerator<string> {
    const entries = await readdir(dir, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        yield* this.walkRolloutFiles(fullPath);
      } else if (
        entry.isFile() &&
        entry.name.startsWith('rollout-') &&
        entry.name.endsWith('.jsonl')
      ) {
        yield fullPath;
      }
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      let meta: Record<string, unknown> | null = null;
      let userCount = 0;
      let assistantCount = 0;
      let toolCount = 0;
      let systemCount = 0;
      let firstUserText = '';
      let lastTimestamp = '';
      let detectedModel: string | undefined;

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;

        // Update lastTimestamp on any line carrying a timestamp so endTime
        // reflects the true tail (function_call_output, event_msg, etc.).
        if (obj.timestamp) {
          lastTimestamp = obj.timestamp as string;
        }

        if (obj.type === 'session_meta' && !meta) {
          meta = obj.payload as Record<string, unknown>;
        }

        if (obj.type === 'response_item') {
          const payload = obj.payload as Record<string, unknown>;
          // The real model name lives on response_item.payload.model
          // (e.g. "gpt-5.3-codex"); session_meta only carries provider name.
          if (!detectedModel && typeof payload.model === 'string') {
            detectedModel = payload.model;
          }
          if (payload.type === 'message') {
            const role = payload.role as string;
            if (role === 'user') {
              const text = this.extractText(payload.content as unknown[]);
              if (this.isSystemInjection(text)) {
                systemCount++;
              } else {
                userCount++;
                if (!firstUserText) {
                  firstUserText = text;
                }
              }
            } else if (role === 'assistant') {
              assistantCount++;
            }
          } else if (
            payload.type === 'function_call' ||
            payload.type === 'function_call_output'
          ) {
            toolCount++;
          }
        }
      }

      if (!meta) return null;

      const payload = meta as Record<string, unknown>;
      const agentRole = payload.agent_role as string | undefined;
      const originator = payload.originator as string | undefined;
      // If Claude Code launched this session and no explicit role was set,
      // mark it as dispatched so it skips dispatch-pattern matching in backfill.
      const effectiveRole =
        agentRole || (originator === 'Claude Code' ? 'dispatched' : undefined);
      return {
        id: payload.id as string,
        source: 'codex',
        startTime: payload.timestamp as string,
        endTime: lastTimestamp || undefined,
        cwd: (payload.cwd as string) || '',
        model: detectedModel || (payload.model_provider as string | undefined),
        messageCount: userCount + assistantCount + toolCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: toolCount,
        systemMessageCount: systemCount,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath,
        sizeBytes: fileStat.size,
        agentRole: effectiveRole,
        originator: originator || undefined,
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
      if (!obj) continue;
      if (obj.type !== 'response_item') continue;

      const payload = obj.payload as Record<string, unknown>;
      const timestamp = obj.timestamp as string | undefined;
      let msg: Message | null = null;

      if (payload.type === 'message') {
        const role = payload.role as string;
        if (role !== 'user' && role !== 'assistant') continue;
        const built: Message = {
          role: role as 'user' | 'assistant',
          content: this.extractText(payload.content as unknown[]),
          timestamp,
        };
        if (role === 'assistant') {
          const rawUsage = payload.usage as Record<string, unknown> | undefined;
          if (rawUsage && typeof rawUsage === 'object') {
            built.usage = {
              inputTokens: (rawUsage.input_tokens as number) ?? 0,
              outputTokens: (rawUsage.output_tokens as number) ?? 0,
              cacheReadTokens: rawUsage.cache_read_input_tokens as
                | number
                | undefined,
              cacheCreationTokens: rawUsage.cache_creation_input_tokens as
                | number
                | undefined,
            };
          }
        }
        msg = built;
      } else if (payload.type === 'function_call') {
        const name = (payload.name as string) || '';
        const args = payload.arguments;
        const argsStr =
          args !== undefined ? JSON.stringify(args).slice(0, 500) : '';
        msg = {
          role: 'tool',
          content: argsStr ? `${name} ${argsStr}` : name,
          timestamp,
          toolCalls: [{ name, input: argsStr || undefined }],
        };
      } else if (payload.type === 'function_call_output') {
        msg = {
          role: 'tool',
          content:
            typeof payload.output === 'string'
              ? payload.output
              : JSON.stringify(payload.output ?? '').slice(0, 2000),
          timestamp,
        };
      }

      if (!msg) continue;

      if (count < offset) {
        count++;
        continue;
      }
      count++;
      yield msg;
      yielded++;
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

  private isSystemInjection(text: string): boolean {
    return (
      text.startsWith('# AGENTS.md instructions for ') ||
      text.includes('<INSTRUCTIONS>') ||
      text.startsWith('<local-command-caveat>') ||
      text.startsWith('<environment_context>')
    );
  }

  private extractText(content: unknown[]): string {
    if (!Array.isArray(content)) return '';
    for (const item of content) {
      const c = item as Record<string, unknown>;
      if (c.text) return c.text as string;
      if (c.input_text) return c.input_text as string;
    }
    return '';
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}
