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
  ToolCall,
} from './types.js';

export class CommandCodeAdapter implements SessionAdapter {
  readonly name = 'commandcode' as const;
  private projectsRoot: string;

  constructor(projectsRoot?: string) {
    this.projectsRoot =
      projectsRoot ?? join(homedir(), '.commandcode', 'projects');
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
        const files = await readdir(projectPath);
        for (const file of files) {
          if (file.endsWith('.jsonl') && !file.endsWith('.checkpoints.jsonl')) {
            yield join(projectPath, file);
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
      let startTime = '';
      let endTime = '';
      let userCount = 0;
      let assistantCount = 0;
      let toolCount = 0;
      let firstUserText = '';
      let cwd = '';
      let model: string | undefined;

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;
        const role = obj.role as string;
        if (role !== 'user' && role !== 'assistant' && role !== 'tool')
          continue;
        if (!sessionId && obj.sessionId) sessionId = obj.sessionId as string;
        if (!cwd && typeof obj.cwd === 'string') cwd = obj.cwd;
        if (!model && typeof obj.model === 'string') model = obj.model;
        const metadata = obj.metadata as Record<string, unknown> | undefined;
        if (!model && typeof metadata?.model === 'string')
          model = metadata.model;
        const timestamp = this.timestamp(obj);
        if (!startTime && timestamp) startTime = timestamp;
        if (timestamp) endTime = timestamp;
        if (role === 'user') {
          userCount++;
          if (!firstUserText) firstUserText = this.extractContent(obj.content);
        } else if (role === 'assistant') assistantCount++;
        else toolCount++;
      }

      if (!sessionId) return null;
      return {
        id: sessionId,
        source: 'commandcode',
        startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd: cwd || this.decodeCwdFromLocator(filePath),
        model,
        messageCount: userCount + assistantCount + toolCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: toolCount,
        systemMessageCount: 0,
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
      if (!obj) continue;
      const role = obj.role as Message['role'];
      if (role !== 'user' && role !== 'assistant' && role !== 'tool') continue;
      if (count < offset) {
        count++;
        continue;
      }
      count++;
      yield {
        role,
        content: this.extractContent(obj.content),
        timestamp: this.timestamp(obj),
        toolCalls: this.toolCalls(obj.content),
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

  private timestamp(obj: Record<string, unknown>): string | undefined {
    if (typeof obj.timestamp === 'string') return obj.timestamp;
    const metadata = obj.metadata as Record<string, unknown> | undefined;
    return typeof metadata?.timestamp === 'string'
      ? metadata.timestamp
      : undefined;
  }

  private decodeCwdFromLocator(filePath: string): string {
    const encoded = basename(dirname(filePath));
    if (!encoded.includes('-')) return '';
    return encoded
      .replace(/--/g, '\x00')
      .replace(/-/g, '/')
      .replace(/\x00/g, '-');
  }

  private extractContent(content: unknown): string {
    if (!Array.isArray(content))
      return typeof content === 'string' ? content : '';
    return content
      .map((item) => {
        const c = item as Record<string, unknown>;
        if (c.type === 'text') return c.text as string | undefined;
        if (c.type === 'tool-call' && c.toolName) return `\`${c.toolName}\``;
        if (c.type === 'tool-result') {
          if (typeof c.output === 'string') return c.output;
          if (c.output !== undefined && c.output !== null) {
            return JSON.stringify(c.output).slice(0, 2000);
          }
        }
        return undefined;
      })
      .filter(Boolean)
      .join('\n\n');
  }

  private toolCalls(content: unknown): ToolCall[] | undefined {
    if (!Array.isArray(content)) return undefined;
    const calls = content
      .filter((item) => {
        const c = item as Record<string, unknown>;
        return c.type === 'tool-call' && c.toolName;
      })
      .map((item) => {
        const c = item as Record<string, unknown>;
        return {
          name: c.toolName as string,
          input: c.input ? JSON.stringify(c.input).slice(0, 500) : undefined,
        };
      });
    return calls.length > 0 ? calls : undefined;
  }
}
