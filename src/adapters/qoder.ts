import { createReadStream } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
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

export class QoderAdapter implements SessionAdapter {
  readonly name = 'qoder' as const;
  private projectsRoot: string;

  constructor(projectsRoot?: string) {
    this.projectsRoot = projectsRoot ?? join(homedir(), '.qoder', 'projects');
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.projectsRoot);
      return true;
    } catch {
      return false;
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const projectDirs = await readdir(this.projectsRoot, {
        withFileTypes: true,
      });
      for (const project of projectDirs) {
        if (!project.isDirectory()) continue;
        const projectPath = join(this.projectsRoot, project.name);
        const entries = await readdir(projectPath, { withFileTypes: true });
        for (const entry of entries) {
          if (entry.isFile() && entry.name.endsWith('.jsonl')) {
            yield join(projectPath, entry.name);
          } else if (entry.isDirectory()) {
            const subagentsPath = join(projectPath, entry.name, 'subagents');
            try {
              const subFiles = await readdir(subagentsPath);
              for (const file of subFiles) {
                if (file.endsWith('.jsonl')) yield join(subagentsPath, file);
              }
            } catch {
              /* no subagents dir */
            }
          }
        }
      }
    } catch {
      /* projectsRoot does not exist */
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      let sessionId = '';
      let agentId = '';
      let cwd = '';
      let startTime = '';
      let endTime = '';
      let model: string | undefined;
      let userCount = 0;
      let assistantCount = 0;
      let toolCount = 0;
      let systemCount = 0;
      let firstUserText = '';

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;
        const type = obj.type as string;
        if (type !== 'user' && type !== 'assistant') continue;

        if (!sessionId && obj.sessionId) sessionId = obj.sessionId as string;
        if (!agentId && obj.agentId) agentId = obj.agentId as string;
        if (!cwd && obj.cwd) cwd = obj.cwd as string;
        if (!startTime && obj.timestamp) startTime = obj.timestamp as string;
        if (obj.timestamp) endTime = obj.timestamp as string;

        const msg = obj.message as Record<string, unknown> | undefined;
        if (!model && typeof msg?.model === 'string') model = msg.model;

        if (type === 'assistant') {
          assistantCount++;
        } else if (this.isToolResult(msg?.content)) {
          toolCount++;
        } else {
          const text = this.extractContent(msg?.content);
          if (this.isSystemInjection(text)) systemCount++;
          else {
            userCount++;
            if (!firstUserText) firstUserText = text;
          }
        }
      }

      if (!sessionId) return null;
      const isSubagent = filePath.includes('/subagents/');
      const id = isSubagent && agentId ? agentId : sessionId;
      return {
        id,
        source: 'qoder',
        startTime,
        endTime: endTime !== startTime ? endTime : undefined,
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
        agentRole: isSubagent ? 'subagent' : undefined,
        parentSessionId: isSubagent
          ? this.parentSessionId(filePath)
          : undefined,
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
      const type = obj.type as string;
      if (type !== 'user' && type !== 'assistant') continue;
      if (count < offset) {
        count++;
        continue;
      }
      count++;
      const msg = obj.message as Record<string, unknown>;
      const content = msg?.content;
      const role: Message['role'] =
        type === 'assistant'
          ? 'assistant'
          : this.isToolResult(content)
            ? 'tool'
            : 'user';
      yield {
        role,
        content: this.extractContent(content),
        timestamp: obj.timestamp as string | undefined,
        toolCalls: this.toolCalls(content),
        usage: this.usage(msg?.usage),
      };
      yielded++;
    }
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    try {
      for await (const line of rl) if (line.trim()) yield line;
    } finally {
      rl.close();
      stream.destroy();
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
      text.includes('<INSTRUCTIONS>')
    );
  }

  private isToolResult(content: unknown): boolean {
    return (
      Array.isArray(content) &&
      content.some((c) => (c as Record<string, unknown>).type === 'tool_result')
    );
  }

  private extractContent(content: unknown): string {
    if (typeof content === 'string') return content;
    if (!Array.isArray(content)) return '';
    const parts: string[] = [];
    let thinkingFallback = '';
    for (const item of content) {
      const c = item as Record<string, unknown>;
      if (c.type === 'text' && typeof c.text === 'string' && c.text)
        parts.push(c.text);
      else if (
        c.type === 'thinking' &&
        typeof c.thinking === 'string' &&
        !thinkingFallback
      )
        thinkingFallback = c.thinking;
      else if (c.type === 'tool_use' && typeof c.name === 'string')
        parts.push(`\`${c.name}\``);
      else if (c.type === 'tool_result') {
        const output = c.content ?? c.output;
        if (typeof output === 'string' && output) parts.push(output);
        else if (output !== undefined && output !== null)
          parts.push(JSON.stringify(output).slice(0, 2000));
      }
    }
    return parts.length > 0 ? parts.join('\n\n') : thinkingFallback;
  }

  private toolCalls(content: unknown): ToolCall[] | undefined {
    if (!Array.isArray(content)) return undefined;
    const calls = content
      .filter(
        (c) =>
          (c as Record<string, unknown>).type === 'tool_use' &&
          (c as Record<string, unknown>).name,
      )
      .map((c) => {
        const obj = c as Record<string, unknown>;
        return {
          name: obj.name as string,
          input: obj.input
            ? JSON.stringify(obj.input).slice(0, 500)
            : undefined,
        };
      });
    return calls.length > 0 ? calls : undefined;
  }

  private usage(value: unknown): TokenUsage | undefined {
    if (!value || typeof value !== 'object') return undefined;
    const raw = value as Record<string, unknown>;
    return {
      inputTokens: (raw.input_tokens as number) ?? 0,
      outputTokens: (raw.output_tokens as number) ?? 0,
      cacheReadTokens: raw.cache_read_input_tokens as number | undefined,
      cacheCreationTokens: raw.cache_creation_input_tokens as
        | number
        | undefined,
    };
  }

  private parentSessionId(filePath: string): string | undefined {
    return filePath.match(/\/([^/]+)\/subagents\/[^/]+\.jsonl$/)?.[1];
  }
}
