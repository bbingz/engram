// src/adapters/iflow.ts
import { createReadStream } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
} from './types.js';

export class IflowAdapter implements SessionAdapter {
  readonly name = 'iflow' as const;
  private projectsRoot: string;

  constructor(projectsRoot?: string) {
    this.projectsRoot = projectsRoot ?? join(homedir(), '.iflow', 'projects');
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
          const files = await readdir(projectPath);
          for (const file of files) {
            if (file.startsWith('session-') && file.endsWith('.jsonl')) {
              yield join(projectPath, file);
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
      let cwd = '';
      let startTime = '';
      let endTime = '';
      let userCount = 0;
      let assistantCount = 0;
      let systemCount = 0;
      let firstUserText = '';

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;

        const type = obj.type as string;
        if (type !== 'user' && type !== 'assistant') continue;

        if (!sessionId && obj.sessionId) sessionId = obj.sessionId as string;
        if (!cwd && obj.cwd) cwd = obj.cwd as string;
        if (!startTime && obj.timestamp) startTime = obj.timestamp as string;
        if (obj.timestamp) endTime = obj.timestamp as string;

        if (type === 'assistant') {
          assistantCount++;
        } else if (type === 'user') {
          const msg = obj.message as Record<string, unknown>;
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

      if (!sessionId) return null;

      return {
        id: sessionId,
        source: 'iflow',
        startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd,
        messageCount: userCount + assistantCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: 0,
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
      if (!obj) continue;

      const type = obj.type as string;
      if (type !== 'user' && type !== 'assistant') continue;

      if (count < offset) {
        count++;
        continue;
      }
      count++;

      const msg = obj.message as Record<string, unknown>;
      yield {
        role: type as 'user' | 'assistant',
        content: this.extractContent(msg?.content),
        timestamp: obj.timestamp as string | undefined,
      };
      yielded++;
    }
  }

  private isSystemInjection(text: string): boolean {
    return (
      text.startsWith('# AGENTS.md instructions for ') ||
      text.includes('<INSTRUCTIONS>') ||
      text.startsWith('<local-command-caveat>')
    );
  }

  // 解码 iflow 目录名：-Users-bing--Code--project → /Users/bing/-Code-/project
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

  private extractContent(content: unknown): string {
    if (typeof content === 'string') return content;
    if (Array.isArray(content)) {
      for (const item of content) {
        const c = item as Record<string, unknown>;
        if (c.type === 'text' && c.text) return c.text as string;
      }
    }
    return '';
  }
}
