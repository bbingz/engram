// src/adapters/copilot.ts
// GitHub Copilot CLI adapter
// Sessions stored in ~/.copilot/session-state/<uuid>/events.jsonl
import { createReadStream } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
} from './types.js';

export class CopilotAdapter implements SessionAdapter {
  readonly name = 'copilot' as const;
  private sessionRoot: string;

  constructor(sessionRoot?: string) {
    this.sessionRoot =
      sessionRoot ?? join(homedir(), '.copilot', 'session-state');
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.sessionRoot);
      return true;
    } catch {
      return false;
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const dirs = await readdir(this.sessionRoot, { withFileTypes: true });
      for (const dir of dirs) {
        if (!dir.isDirectory()) continue;
        const eventsPath = join(this.sessionRoot, dir.name, 'events.jsonl');
        try {
          await stat(eventsPath);
          yield eventsPath;
        } catch {
          // no events.jsonl, skip
        }
      }
    } catch {
      // sessionRoot doesn't exist
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      const sessionDir = join(filePath, '..');

      // Try to read workspace.yaml for metadata (simple key: value parsing)
      const workspace: Record<string, string> = {};
      try {
        const yamlContent = await readFile(
          join(sessionDir, 'workspace.yaml'),
          'utf8',
        );
        for (const line of yamlContent.split('\n')) {
          const m = line.match(/^(\w+):\s*(.+)$/);
          if (m) workspace[m[1]] = m[2].trim();
        }
      } catch {
        /* no workspace.yaml */
      }

      const sessionId = workspace.id || sessionDir.split('/').pop() || '';
      let startTime = workspace.created_at || '';
      let endTime = workspace.updated_at || '';
      let cwd = workspace.cwd || '';
      let userCount = 0;
      let assistantCount = 0;
      let firstUserText = '';

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;

        const type = obj.type as string;
        const data = obj.data as Record<string, unknown> | undefined;
        const ts = obj.timestamp as string | undefined;

        if (type === 'session.start') {
          const ctx = (data?.context as Record<string, unknown>) ?? {};
          if (!startTime && data?.startTime)
            startTime = data.startTime as string;
          if (!cwd && ctx.cwd) cwd = ctx.cwd as string;
        }

        if (type === 'user.message') {
          userCount++;
          if (!firstUserText && data?.content) {
            firstUserText = (data.content as string).slice(0, 200);
          }
          if (ts && (!startTime || ts < startTime)) startTime = ts;
          if (ts && ts > endTime) endTime = ts;
        }

        if (type === 'assistant.message') {
          assistantCount++;
          if (ts && ts > endTime) endTime = ts;
        }
      }

      const totalCount = userCount + assistantCount;
      if (!sessionId || totalCount === 0) return null;

      return {
        id: sessionId,
        source: 'copilot',
        startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd,
        messageCount: userCount + assistantCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: workspace.summary || firstUserText || undefined,
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
      const data = obj.data as Record<string, unknown> | undefined;
      if (type !== 'user.message' && type !== 'assistant.message') continue;

      if (count < offset) {
        count++;
        continue;
      }
      count++;

      const role =
        type === 'user.message' ? ('user' as const) : ('assistant' as const);
      const content = (data?.content as string) || '';
      yield {
        role,
        content,
        timestamp: obj.timestamp as string | undefined,
      };
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
}
