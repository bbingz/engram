// src/adapters/claude-code.ts
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

export class ClaudeCodeAdapter implements SessionAdapter {
  readonly name = 'claude-code' as const;
  private projectsRoot: string;

  // Message-bearing record types. Everything else (attachment, queue-operation,
  // permission-mode, last-prompt, file-history-snapshot, summary, system, ...)
  // is metadata and is intentionally skipped. If Claude Code introduces a new
  // user-visible message type, add it here.
  private static MESSAGE_TYPES = new Set(['user', 'assistant']);

  constructor(projectsRoot?: string) {
    this.projectsRoot = projectsRoot ?? join(homedir(), '.claude', 'projects');
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
      const projectDirs = await readdir(this.projectsRoot);
      for (const dir of projectDirs) {
        const projectPath = join(this.projectsRoot, dir);
        try {
          const entries = await readdir(projectPath, { withFileTypes: true });
          for (const entry of entries) {
            if (entry.isFile() && entry.name.endsWith('.jsonl')) {
              yield join(projectPath, entry.name);
            } else if (entry.isDirectory()) {
              // UUID subdirectory — look for subagents/ inside it
              const subagentsPath = join(projectPath, entry.name, 'subagents');
              try {
                const subFiles = await readdir(subagentsPath);
                for (const file of subFiles) {
                  if (file.endsWith('.jsonl')) {
                    yield join(subagentsPath, file);
                  }
                }
              } catch {
                // no subagents dir, skip
              }
            }
          }
        } catch {
          // 跳过无法读取的目录
        }
      }
    } catch {
      // projectsRoot 不存在
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
      let userCount = 0;
      let assistantCount = 0;
      let toolCount = 0;
      let systemCount = 0;
      let firstUserText = '';
      let detectedModel = '';

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;

        const type = obj.type as string;
        // sessionId can live on non-message records too (permission-mode, etc.)
        // — capture it before filtering so single-record sessions still parse.
        if (!sessionId && obj.sessionId) sessionId = obj.sessionId as string;
        if (!ClaudeCodeAdapter.MESSAGE_TYPES.has(type)) continue;

        if (!agentId && obj.agentId) agentId = obj.agentId as string;
        if (!cwd && obj.cwd) cwd = obj.cwd as string;
        if (!startTime && obj.timestamp) startTime = obj.timestamp as string;
        if (obj.timestamp) endTime = obj.timestamp as string;

        const msg = obj.message as Record<string, unknown> | undefined;
        if (!detectedModel && msg?.model) {
          detectedModel = msg.model as string;
        }

        if (type === 'assistant') {
          assistantCount++;
        } else if (type === 'user') {
          if (this.isToolResult(msg?.content)) {
            toolCount++;
          } else {
            const text = this.extractContent(msg?.content);
            if (this.isSystemInjection(text)) {
              systemCount++;
            } else {
              userCount++;
              if (!firstUserText) {
                firstUserText = text;
              }
            }
          }
        }
      }

      // sessionId is captured before the type filter so single-record sessions
      // can still resolve, but a file with NO message records (only permission-
      // mode / attachment / etc.) yields nothing useful — keep parity with the
      // pre-Batch-3 behavior of returning null instead of an empty-startTime row.
      const totalMessages = userCount + assistantCount + toolCount;
      if (!sessionId || totalMessages === 0) return null;

      // Fall back to file mtime when message records exist but none carry a
      // timestamp. Without this, sessions with valid content would silently
      // drop just because the producer hadn't written timestamps.
      const safeStartTime =
        startTime || new Date(fileStat.mtimeMs).toISOString();
      const safeEndTime = endTime || safeStartTime;

      const isSubagent = filePath.includes('/subagents/');
      // Subagent files share sessionId with the parent — use agentId as the unique DB key
      const id = isSubagent && agentId ? agentId : sessionId;
      const source = ClaudeCodeAdapter.detectSource(detectedModel, filePath);

      // Extract parent session ID from subagent path
      let parentSessionId: string | undefined;
      if (isSubagent) {
        const match = filePath.match(/\/([^/]+)\/subagents\/[^/]+\.jsonl$/);
        if (match) parentSessionId = match[1];
      }

      return {
        id,
        source,
        startTime: safeStartTime,
        endTime: safeEndTime !== safeStartTime ? safeEndTime : undefined,
        cwd,
        model: detectedModel || undefined,
        messageCount: userCount + assistantCount + toolCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: toolCount,
        systemMessageCount: systemCount,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath,
        sizeBytes: fileStat.size,
        agentRole: isSubagent ? 'subagent' : undefined,
        parentSessionId,
      };
    } catch {
      return null;
    }
  }

  /** Map Claude-compatible project files to Engram's derived Claude sources. */
  static detectSource(model: string, filePath?: string): SessionInfo['source'] {
    // Lobster AI writes to ~/.claude/projects/ with its own project dirs
    if (filePath?.includes('lobsterai')) return 'lobsterai';
    if (!model || model.startsWith('claude') || model.startsWith('<'))
      return 'claude-code';
    const m = model.toLowerCase();
    if (m.includes('minimax')) return 'minimax';
    // Qwen/Kimi/Gemini models can be routed through Claude-compatible clients,
    // but the session file is still owned by Claude Code's on-disk format.
    return 'claude-code';
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
      if (!ClaudeCodeAdapter.MESSAGE_TYPES.has(type)) continue;

      if (count < offset) {
        count++;
        continue;
      }
      count++;

      const msg = obj.message as Record<string, unknown>;
      // user-typed records carrying tool_result content are tool messages;
      // parseSessionInfo already counts them under toolMessageCount, so the
      // streamed role must agree to keep stream + counts in sync.
      const role: 'user' | 'assistant' | 'tool' =
        type === 'user' && this.isToolResult(msg?.content)
          ? 'tool'
          : (type as 'user' | 'assistant');
      const content = this.extractContent(msg?.content);
      const timestamp = obj.timestamp as string | undefined;

      // Extract usage from message object
      let usage: TokenUsage | undefined;
      let toolCalls: ToolCall[] | undefined;

      if (msg && typeof msg === 'object') {
        // Extract usage
        const rawUsage = msg.usage as Record<string, unknown> | undefined;
        if (rawUsage && typeof rawUsage === 'object') {
          usage = {
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

        // Extract toolCalls from content array
        const rawContent = msg.content;
        if (Array.isArray(rawContent)) {
          const calls = rawContent
            .filter(
              (c: Record<string, unknown>) => c.type === 'tool_use' && c.name,
            )
            .map((c: Record<string, unknown>) => ({
              name: c.name as string,
              input: c.input
                ? JSON.stringify(c.input).slice(0, 500)
                : undefined,
            }));
          if (calls.length > 0) toolCalls = calls;
        }
      }

      yield { role, content, timestamp, usage, toolCalls };
      yielded++;
    }
  }

  private isSystemInjection(text: string): boolean {
    return (
      text.startsWith('# AGENTS.md instructions for ') ||
      text.includes('<INSTRUCTIONS>') ||
      text.startsWith('<local-command-caveat>') ||
      text.startsWith('<local-command-stdout>') ||
      text.includes('<command-name>') ||
      text.includes('<command-message>') ||
      text.startsWith('Unknown skill: ') ||
      text.startsWith('Invoke the superpowers:') ||
      text.startsWith('Base directory for this skill:')
    );
  }

  // 解码 Claude Code 目录名：-Users-example--Code--project → /Users/example/-Code-/project
  static decodeCwd(encoded: string): string {
    return encoded
      .replace(/--/g, '\x00')
      .replace(/-/g, '/')
      .replace(/\x00/g, '-');
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

  private isToolResult(content: unknown): boolean {
    if (!Array.isArray(content)) return false;
    return content.some(
      (c: Record<string, unknown>) => c.type === 'tool_result',
    );
  }

  private extractContent(content: unknown): string {
    if (typeof content === 'string') return content;
    if (Array.isArray(content)) {
      const parts: string[] = [];
      let thinkingFallback = '';
      for (const item of content) {
        const c = item as Record<string, unknown>;
        if (c.type === 'text' && c.text) {
          const text = (c.text as string).trim();
          if (text && text !== 'Tool loaded.') parts.push(c.text as string);
        } else if (c.type === 'thinking' && c.thinking && !thinkingFallback) {
          thinkingFallback = c.thinking as string;
        } else if (c.type === 'tool_use') {
          parts.push(this.formatToolUse(c));
        } else if (c.type === 'tool_result') {
          const formatted = this.formatToolResult(c);
          if (formatted) parts.push(formatted);
        } else if (c.type === 'image') {
          const mediaType =
            (c.source as Record<string, unknown>)?.media_type ??
            'image/unknown';
          const dataLen =
            ((c.source as Record<string, unknown>)?.data as string)?.length ??
            0;
          const sizeKB = Math.round((dataLen * 0.75) / 1024);
          parts.push(`[Image: ${mediaType}, ~${sizeKB} KB]`);
        }
      }
      const nonEmpty = parts.filter((p) => p);
      if (nonEmpty.length > 0) return nonEmpty.join('\n\n');
      if (thinkingFallback) return thinkingFallback;
    }
    return '';
  }

  // Internal tools that add no conversational value
  private static NOISE_TOOLS = new Set([
    'ToolSearch',
    'ExitPlanMode',
    'EnterPlanMode',
    'Skill',
    'TodoWrite',
    'TodoRead',
    'TaskCreate',
    'TaskUpdate',
    'TaskGet',
    'TaskList',
  ]);

  private formatToolUse(c: Record<string, unknown>): string {
    const name = c.name as string;
    if (ClaudeCodeAdapter.NOISE_TOOLS.has(name)) return '';
    const input = c.input as Record<string, unknown> | undefined;
    if (name === 'AskUserQuestion' && input?.questions) {
      return this.formatAskUserQuestion(
        input.questions as Record<string, unknown>[],
      );
    }
    // For other tools, show a brief summary
    if (!input) return `\`${name}\``;
    const summary =
      typeof input === 'object' ? this.summarizeToolInput(name, input) : '';
    return summary ? `\`${name}\`: ${summary}` : `\`${name}\``;
  }

  private formatAskUserQuestion(questions: Record<string, unknown>[]): string {
    return questions
      .map((q) => {
        const header = q.header ? `**${q.header}**\n` : '';
        const question = q.question as string;
        const options = q.options as Record<string, unknown>[] | undefined;
        let text = `${header}${question}`;
        if (options?.length) {
          text +=
            '\n' +
            options
              .map((o, i) => {
                const desc = o.description ? ` — ${o.description}` : '';
                return `  ${i + 1}. ${o.label}${desc}`;
              })
              .join('\n');
        }
        return text;
      })
      .join('\n\n');
  }

  private formatToolResult(c: Record<string, unknown>): string {
    const content = c.content;
    if (typeof content === 'string') {
      if (content.startsWith('User has answered')) return content;
      return '';
    }
    if (Array.isArray(content)) {
      // Skip tool_reference items ("Tool loaded" responses)
      const texts = content
        .filter(
          (item: Record<string, unknown>) => item.type === 'text' && item.text,
        )
        .map((item: Record<string, unknown>) => item.text as string);
      if (texts.length > 0) {
        const joined = texts.join('\n');
        if (joined.startsWith('User has answered')) return joined;
      }
    }
    return '';
  }

  private summarizeToolInput(
    name: string,
    input: Record<string, unknown>,
  ): string {
    // Show meaningful context for common tools
    if (name === 'Read' || name === 'Write' || name === 'Edit')
      return (input.file_path as string) || '';
    if (name === 'Bash') return ((input.command as string) || '').slice(0, 120);
    if (name === 'Glob') return (input.pattern as string) || '';
    if (name === 'Grep') return (input.pattern as string) || '';
    if (name === 'Agent') return (input.description as string) || '';
    return '';
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}
