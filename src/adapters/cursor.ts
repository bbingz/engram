// src/adapters/cursor.ts

import { stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import BetterSqlite3 from 'better-sqlite3';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  TokenUsage,
} from './types.js';

interface ComposerData {
  composerId: string;
  createdAt?: number;
  lastUpdatedAt?: number;
  latestConversationSummary?: { summary?: unknown };
  context?: {
    fileSelections?: { uri?: { fsPath?: string } }[];
    folderSelections?: { uri?: { fsPath?: string } }[];
  };
}

interface BubbleData {
  type: number; // 1 = user, 2 = assistant
  text?: string;
  rawText?: string;
  timingInfo?: { clientStartTime?: number };
  tokenCount?: { inputTokens?: unknown; outputTokens?: unknown };
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
        // Approximate per-session storage as the size of this composer's JSON
        // payload rather than the whole state.vscdb file (which is shared by
        // every Cursor session and inflates per-session totals).
        let perSessionBytes = Buffer.byteLength(row.value ?? '', 'utf8');

        // Count messages from conversation array (or fallback to bubbleId keys)
        let bubbles: BubbleData[] = [];
        if (Array.isArray(data.conversation) && data.conversation.length > 0) {
          bubbles = data.conversation;
        } else {
          const bubbleRows = db
            .prepare(`SELECT value FROM cursorDiskKV WHERE key LIKE ?`)
            .all(`bubbleId:${composerId}:%`) as { value: string }[];
          for (const br of bubbleRows) {
            perSessionBytes += Buffer.byteLength(br.value ?? '', 'utf8');
            try {
              const bubble = JSON.parse(br.value);
              if (this.isBubbleData(bubble)) bubbles.push(bubble);
            } catch {
              /* skip */
            }
          }
        }
        let userMessageCount = 0;
        let assistantMessageCount = 0;
        for (const b of bubbles) {
          if (!this.isBubbleData(b)) continue;
          const role =
            b.type === 1 ? 'user' : b.type === 2 ? 'assistant' : null;
          if (!role) continue;
          const content = b.text || b.rawText || '';
          if (!content.trim()) continue;
          if (role === 'user') userMessageCount++;
          else assistantMessageCount++;
        }
        if (userMessageCount + assistantMessageCount === 0) return null;

        const createdAt =
          this.numberValue(data.createdAt) ??
          this.firstVisibleBubbleTimestamp(bubbles) ??
          this.numberValue(data.lastUpdatedAt) ??
          0;
        const lastUpdatedAt = this.numberValue(data.lastUpdatedAt) ?? createdAt;
        const summary = this.summary(data.latestConversationSummary);

        return {
          id: data.composerId,
          source: 'cursor',
          startTime: new Date(createdAt).toISOString(),
          endTime:
            lastUpdatedAt !== createdAt
              ? new Date(lastUpdatedAt).toISOString()
              : undefined,
          cwd: this.inferCwd(data),
          messageCount: userMessageCount + assistantMessageCount,
          userMessageCount,
          assistantMessageCount,
          toolMessageCount: 0,
          systemMessageCount: 0,
          summary,
          filePath,
          sizeBytes: perSessionBytes,
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
              const bubble = JSON.parse(row.value);
              if (this.isBubbleData(bubble)) bubbles.push(bubble);
            } catch {
              /* skip */
            }
          }
        }
        let count = 0;
        let yielded = 0;
        for (const bubble of bubbles) {
          if (yielded >= limit) break;
          if (!this.isBubbleData(bubble)) continue;
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
          const usage =
            role === 'assistant' ? this.usage(bubble.tokenCount) : undefined;
          yield {
            role,
            content,
            timestamp: ts ? new Date(ts).toISOString() : undefined,
            usage,
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

  // Cursor doesn't bind composers to a workspace. Best signal is the first
  // attached folder, or the parent of the first selected file. Heuristic;
  // returns '' when nothing usable is present.
  private inferCwd(data: ComposerData): string {
    const folder = data.context?.folderSelections?.[0]?.uri?.fsPath;
    if (folder) return folder;
    const file = data.context?.fileSelections?.[0]?.uri?.fsPath;
    if (file) return dirname(file);
    return '';
  }

  private firstVisibleBubbleTimestamp(
    bubbles: BubbleData[],
  ): number | undefined {
    for (const bubble of bubbles) {
      if (!this.isBubbleData(bubble)) continue;
      const role =
        bubble.type === 1 ? 'user' : bubble.type === 2 ? 'assistant' : null;
      if (!role) continue;
      const content = bubble.text || bubble.rawText || '';
      if (!content.trim()) continue;
      const timestamp = this.numberValue(bubble.timingInfo?.clientStartTime);
      if (timestamp !== undefined) return timestamp;
    }
    return undefined;
  }

  private isBubbleData(value: unknown): value is BubbleData {
    return value !== null && typeof value === 'object';
  }

  private numberValue(value: unknown): number | undefined {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string' && value.trim()) {
      const parsed = Number(value);
      if (Number.isFinite(parsed)) return parsed;
    }
    return undefined;
  }

  private summary(
    value: ComposerData['latestConversationSummary'],
  ): string | undefined {
    return this.summaryText(value);
  }

  private summaryText(value: unknown): string | undefined {
    if (typeof value === 'string') return value.slice(0, 200);
    if (value !== null && typeof value === 'object') {
      return this.summaryText((value as { summary?: unknown }).summary);
    }
    return undefined;
  }

  private usage(tokenCount: BubbleData['tokenCount']): TokenUsage | undefined {
    if (!tokenCount) return undefined;
    const usage = {
      inputTokens: this.int(tokenCount.inputTokens),
      outputTokens: this.int(tokenCount.outputTokens),
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    if (usage.inputTokens === 0 && usage.outputTokens === 0) return undefined;
    return usage;
  }

  private int(value: unknown): number {
    return Math.trunc(this.numberValue(value) ?? 0);
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

  async isAccessible(locator: string): Promise<boolean> {
    const { dbPath, composerId } = this.parsePath(locator);
    if (!composerId) return false;
    try {
      await stat(dbPath);
    } catch {
      return false;
    }
    let db: BetterSqlite3.Database | null = null;
    try {
      db = new BetterSqlite3(dbPath, { readonly: true });
      const row = db
        .prepare('SELECT 1 FROM cursorDiskKV WHERE key = ? LIMIT 1')
        .get(`composerData:${composerId}`);
      return row !== undefined;
    } catch {
      return false;
    } finally {
      db?.close();
    }
  }
}
