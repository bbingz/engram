// src/adapters/cursor.ts

import { stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import BetterSqlite3 from 'better-sqlite3';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
} from './types.js';

interface ComposerData {
  composerId: string;
  createdAt: number;
  lastUpdatedAt: number;
  latestConversationSummary?: { summary?: string };
}

interface BubbleData {
  type: number; // 1 = user, 2 = assistant
  text?: string;
  rawText?: string;
  timingInfo?: { clientStartTime?: number };
}

export class CursorAdapter implements SessionAdapter {
  readonly name = 'cursor' as const;
  private dbPath: string;

  constructor(dbPath?: string) {
    this.dbPath =
      dbPath ??
      join(
        homedir(),
        'Library',
        'Application Support',
        'Cursor',
        'User',
        'globalStorage',
        'state.vscdb',
      );
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.dbPath);
      return true;
    } catch {
      return false;
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const db = new BetterSqlite3(this.dbPath, { readonly: true });
      try {
        const rows = db
          .prepare(
            `SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'`,
          )
          .all() as { key: string; value: string }[];
        for (const row of rows) {
          try {
            const data = JSON.parse(row.value) as ComposerData;
            if (data.composerId) {
              yield `${this.dbPath}?composer=${data.composerId}`;
            }
          } catch {
            /* skip malformed */
          }
        }
      } finally {
        db.close();
      }
    } catch {
      /* db not found */
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const { dbPath, composerId } = this.parsePath(filePath);
      if (!composerId) return null;
      const db = new BetterSqlite3(dbPath, { readonly: true });
      try {
        const row = db
          .prepare(`SELECT value FROM cursorDiskKV WHERE key = ?`)
          .get(`composerData:${composerId}`) as { value: string } | undefined;
        if (!row) return null;
        const data = JSON.parse(row.value) as ComposerData & {
          conversation?: BubbleData[];
        };
        const fileStat = await stat(dbPath);

        // Count messages from conversation array (or fallback to bubbleId keys)
        let bubbles: BubbleData[] = [];
        if (Array.isArray(data.conversation) && data.conversation.length > 0) {
          bubbles = data.conversation;
        } else {
          const bubbleRows = db
            .prepare(`SELECT value FROM cursorDiskKV WHERE key LIKE ?`)
            .all(`bubbleId:${composerId}:%`) as { value: string }[];
          for (const br of bubbleRows) {
            try {
              bubbles.push(JSON.parse(br.value));
            } catch {
              /* skip */
            }
          }
        }
        let userMessageCount = 0;
        let assistantMessageCount = 0;
        for (const b of bubbles) {
          const role =
            b.type === 1 ? 'user' : b.type === 2 ? 'assistant' : null;
          if (!role) continue;
          const content = b.text || b.rawText || '';
          if (!content.trim()) continue;
          if (role === 'user') userMessageCount++;
          else assistantMessageCount++;
        }

        return {
          id: data.composerId,
          source: 'cursor',
          startTime: new Date(data.createdAt).toISOString(),
          endTime:
            data.lastUpdatedAt !== data.createdAt
              ? new Date(data.lastUpdatedAt).toISOString()
              : undefined,
          cwd: '',
          messageCount: userMessageCount + assistantMessageCount,
          userMessageCount,
          assistantMessageCount,
          toolMessageCount: 0,
          systemMessageCount: 0,
          summary: data.latestConversationSummary?.summary?.slice(0, 200),
          filePath,
          sizeBytes: fileStat.size,
        };
      } finally {
        db.close();
      }
    } catch {
      return null;
    }
  }

  async *streamMessages(
    filePath: string,
    opts: StreamMessagesOptions = {},
  ): AsyncGenerator<Message> {
    const { dbPath, composerId } = this.parsePath(filePath);
    if (!composerId) return;
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? Infinity;
    try {
      const db = new BetterSqlite3(dbPath, { readonly: true });
      try {
        // Try new format: conversation embedded in composerData
        let bubbles: BubbleData[] = [];
        const composerRow = db
          .prepare(`SELECT value FROM cursorDiskKV WHERE key = ?`)
          .get(`composerData:${composerId}`) as { value: string } | undefined;
        if (composerRow) {
          try {
            const data = JSON.parse(composerRow.value);
            if (
              Array.isArray(data.conversation) &&
              data.conversation.length > 0
            ) {
              bubbles = data.conversation;
            }
          } catch {
            /* malformed */
          }
        }
        // Fallback: old format with separate bubbleId keys
        if (bubbles.length === 0) {
          const rows = db
            .prepare(
              `SELECT value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid ASC`,
            )
            .all(`bubbleId:${composerId}:%`) as { value: string }[];
          for (const row of rows) {
            try {
              bubbles.push(JSON.parse(row.value));
            } catch {
              /* skip */
            }
          }
        }
        let count = 0;
        let yielded = 0;
        for (const bubble of bubbles) {
          if (yielded >= limit) break;
          const role =
            bubble.type === 1 ? 'user' : bubble.type === 2 ? 'assistant' : null;
          if (!role) continue;
          const content = bubble.text || bubble.rawText || '';
          if (!content.trim()) continue;
          if (count < offset) {
            count++;
            continue;
          }
          count++;
          const ts = bubble.timingInfo?.clientStartTime;
          yield {
            role,
            content,
            timestamp: ts ? new Date(ts).toISOString() : undefined,
          };
          yielded++;
        }
      } finally {
        db.close();
      }
    } catch {
      /* db not found */
    }
  }

  private parsePath(filePath: string): {
    dbPath: string;
    composerId: string | null;
  } {
    const idx = filePath.indexOf('?composer=');
    if (idx === -1) return { dbPath: filePath, composerId: null };
    return {
      dbPath: filePath.slice(0, idx),
      composerId: filePath.slice(idx + 10),
    };
  }
}
