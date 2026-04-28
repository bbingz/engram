// src/adapters/kimi.ts
import { createReadStream } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
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

interface KimiWorkDir {
  path: string;
  kaos: string;
  last_session_id: string;
}

interface KimiJson {
  work_dirs: KimiWorkDir[];
}

export class KimiAdapter implements SessionAdapter {
  readonly name = 'kimi' as const;
  private sessionsRoot: string;
  private kimiJsonPath: string;

  constructor(sessionsRoot?: string, kimiJsonPath?: string) {
    this.sessionsRoot = sessionsRoot ?? join(homedir(), '.kimi', 'sessions');
    this.kimiJsonPath = kimiJsonPath ?? join(homedir(), '.kimi', 'kimi.json');
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
    // Structure: sessionsRoot/<workspace-id>/<session-id>/context.jsonl
    try {
      const workspaceDirs = await readdir(this.sessionsRoot);
      for (const wsDir of workspaceDirs) {
        const wsPath = join(this.sessionsRoot, wsDir);
        try {
          const sessionDirs = await readdir(wsPath);
          for (const sessDir of sessionDirs) {
            const contextPath = join(wsPath, sessDir, 'context.jsonl');
            try {
              await stat(contextPath);
              yield contextPath;
            } catch {
              // context.jsonl does not exist in this session dir
            }
          }
        } catch {
          // skip unreadable workspace dirs
        }
      }
    } catch {
      // sessionsRoot does not exist
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      const sessionId = basename(dirname(filePath));

      const cwd = await this.resolveCwd(sessionId);
      const turns = await this.readTurnTimestamps(filePath);
      const wireStart = turns[0]?.begin ?? '';
      const wireEnd =
        turns.length > 0
          ? (turns[turns.length - 1].end ?? turns[turns.length - 1].begin)
          : '';

      let userCount = 0;
      let assistantCount = 0;
      let firstUserText = '';
      let firstLineTs = '';
      let lastLineTs = '';
      let totalSize = fileStat.size;

      // Read all context files: context.jsonl + context_sub_*.jsonl
      for (const file of await this.getAllContextFiles(filePath)) {
        try {
          if (file !== filePath) {
            const subStat = await stat(file);
            totalSize += subStat.size;
          }
          for await (const line of this.readLines(file)) {
            const obj = this.parseLine(line);
            if (!obj) continue;

            const lineTs = this.extractLineTimestamp(obj);
            if (lineTs) {
              if (!firstLineTs) firstLineTs = lineTs;
              lastLineTs = lineTs;
            }

            const role = obj.role as string;
            if (role === '_checkpoint') continue;
            if (role !== 'user' && role !== 'assistant') continue;

            if (role === 'user') {
              userCount++;
              if (!firstUserText && typeof obj.content === 'string') {
                firstUserText = obj.content;
              }
            } else {
              assistantCount++;
            }
          }
        } catch {
          // skip unreadable sub files
        }
      }

      // Prefer wire.jsonl turn boundaries (skips heartbeats / metadata);
      // fall back to line-level timestamps before resorting to file mtime.
      const startTime =
        wireStart ||
        firstLineTs ||
        new Date(fileStat.mtimeMs - 60000).toISOString();
      const endTime = wireEnd || lastLineTs || startTime;

      return {
        id: sessionId,
        source: 'kimi',
        startTime,
        endTime: endTime && endTime !== startTime ? endTime : undefined,
        cwd,
        messageCount: userCount + assistantCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath,
        sizeBytes: totalSize,
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

    // Pull paired turn timestamps from wire.jsonl. Pairing (rather than two
    // independent arrays) keeps assistant timestamps aligned even if a turn's
    // TurnEnd is missing — the affected turn just falls back to its begin.
    const turns = await this.readTurnTimestamps(filePath);
    // State machine: each wire turn binds at most one user (begin) + one
    // assistant (end). When the next message would re-bind a slot already
    // claimed in the current turn, we advance to the next turn. This handles
    // user→user, assistant→assistant, and any mixed sequence safely; missing
    // turns produce undefined timestamps rather than misaligned ones.
    let turnIdx = 0;
    let userBoundInTurn = false;
    let asstBoundInTurn = false;

    // Stream from all context files in order
    for (const file of await this.getAllContextFiles(filePath)) {
      if (yielded >= limit) break;
      try {
        for await (const line of this.readLines(file)) {
          if (yielded >= limit) break;
          const obj = this.parseLine(line);
          if (!obj) continue;

          const role = obj.role as string;
          if (role === '_checkpoint') continue;
          if (role !== 'user' && role !== 'assistant') continue;

          const lineTs = this.extractLineTimestamp(obj);
          // A user always opens a new turn unless we're still on the very
          // first turn with no bindings yet. An assistant only advances when
          // the current turn's assistant slot is already taken.
          const advance =
            role === 'user'
              ? userBoundInTurn || asstBoundInTurn
              : asstBoundInTurn;
          if (advance) {
            turnIdx++;
            userBoundInTurn = false;
            asstBoundInTurn = false;
          }
          const turn = turns[turnIdx];
          const wireTs =
            role === 'user' ? turn?.begin : (turn?.end ?? turn?.begin);
          if (role === 'user') userBoundInTurn = true;
          else asstBoundInTurn = true;

          if (count < offset) {
            count++;
            continue;
          }
          count++;

          yield {
            role: role as 'user' | 'assistant',
            content: typeof obj.content === 'string' ? obj.content : '',
            timestamp: lineTs || wireTs,
          };
          yielded++;
        }
      } catch {
        // skip unreadable sub files
      }
    }
  }

  private extractLineTimestamp(obj: Record<string, unknown>): string {
    if (typeof obj.timestamp === 'number') {
      return new Date(obj.timestamp * 1000).toISOString();
    }
    if (typeof obj.timestamp === 'string') return obj.timestamp;
    return '';
  }

  /**
   * Get all context files for a session: context.jsonl + context_sub_1.jsonl ... context_sub_N.jsonl
   * Returns files in order (main first, then subs sorted numerically).
   */
  private async getAllContextFiles(contextPath: string): Promise<string[]> {
    const dir = dirname(contextPath);
    const files = [contextPath];
    try {
      const entries = await readdir(dir);
      const subs = entries
        .filter((f) => f.startsWith('context_sub_') && f.endsWith('.jsonl'))
        .sort((a, b) => {
          const numA = parseInt(
            a.replace('context_sub_', '').replace('.jsonl', ''),
            10,
          );
          const numB = parseInt(
            b.replace('context_sub_', '').replace('.jsonl', ''),
            10,
          );
          return numA - numB;
        });
      for (const sub of subs) {
        files.push(join(dir, sub));
      }
    } catch {
      // can't read directory — just use the main file
    }
    return files;
  }

  private async resolveCwd(sessionId: string): Promise<string> {
    try {
      const raw = await readFile(this.kimiJsonPath, 'utf8');
      const data = JSON.parse(raw) as KimiJson;
      for (const wd of data.work_dirs) {
        if (wd.last_session_id === sessionId) {
          return wd.path;
        }
      }
    } catch {
      // kimi.json not found or invalid
    }
    return '';
  }

  // Walk wire.jsonl and pair every TurnBegin with the next TurnEnd, keeping
  // them as one record. This way a missing TurnEnd only drops the end of one
  // turn — it doesn't shift subsequent assistants onto the wrong wall-clock.
  private async readTurnTimestamps(
    contextPath: string,
  ): Promise<{ begin: string; end?: string }[]> {
    const wirePath = join(dirname(contextPath), 'wire.jsonl');
    const turns: { begin: string; end?: string }[] = [];
    try {
      for await (const line of this.readLines(wirePath)) {
        const obj = this.parseLine(line);
        if (!obj || typeof obj.timestamp !== 'number') continue;
        const iso = new Date(obj.timestamp * 1000).toISOString();
        const message = obj.message as Record<string, unknown> | undefined;
        const type = message?.type;
        if (type === 'TurnBegin') {
          turns.push({ begin: iso });
        } else if (type === 'TurnEnd' && turns.length > 0) {
          const last = turns[turns.length - 1];
          if (!last.end) last.end = iso;
        }
      }
    } catch {
      // wire.jsonl not found or unreadable
    }
    return turns;
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    try {
      for await (const line of rl) {
        if (line.trim()) yield line;
      }
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

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}
