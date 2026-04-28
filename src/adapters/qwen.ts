// src/adapters/qwen.ts
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
} from './types.js';

export class QwenAdapter implements SessionAdapter {
  readonly name = 'qwen' as const;
  private projectsRoot: string;

  constructor(projectsRoot?: string) {
    this.projectsRoot = projectsRoot ?? join(homedir(), '.qwen', 'projects');
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
        const chatsPath = join(this.projectsRoot, dir, 'chats');
        try {
          const files = await readdir(chatsPath);
          for (const file of files) {
            if (file.endsWith('.jsonl')) {
              yield join(chatsPath, file);
            }
          }
        } catch {
          // skip unreadable directories
        }
      }
    } catch {
      // projectsRoot does not exist
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      let sessionId = '';
      let cwd = '';
      let model: string | undefined;
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

        const msg = obj.message as Record<string, unknown> | undefined;
        if (!model) {
          if (typeof obj.model === 'string') model = obj.model;
          else if (typeof msg?.model === 'string') model = msg.model;
        }

        if (type === 'assistant') {
          assistantCount++;
        } else if (type === 'user') {
          const text = this.extractContent(msg ?? {});
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
        source: 'qwen',
        startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd,
        model,
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
      const role = type === 'assistant' ? 'assistant' : 'user';

      yield {
        role: role as 'user' | 'assistant',
        content: this.extractContent(msg),
        timestamp: obj.timestamp as string | undefined,
      };
      yielded++;
    }
  }

  private isSystemInjection(text: string): boolean {
    return (
      text.startsWith('\nYou are Qwen Code') ||
      text.startsWith('You are Qwen Code') ||
      text.includes('<INSTRUCTIONS>')
    );
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

  // Extract text content from Qwen message object
  // Qwen format: message.parts[].text (not message.content)
  // All text parts are joined so multi-part messages keep their full body —
  // matches the gemini-cli adapter so the same conversation looks identical
  // across sources.
  private extractContent(message: Record<string, unknown>): string {
    if (!message) return '';
    const parts = message.parts;
    if (Array.isArray(parts)) {
      const texts: string[] = [];
      for (const part of parts) {
        const p = part as Record<string, unknown>;
        if (typeof p.text === 'string' && p.text) texts.push(p.text);
      }
      return texts.join('\n');
    }
    return '';
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}
