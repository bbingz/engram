// src/adapters/opencode.ts

import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import Database from 'better-sqlite3';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  TokenUsage,
} from './types.js';

interface SessionRow {
  id: string;
  directory: string;
  title: string;
  time_created: number;
  time_updated: number;
}

interface MessageRow {
  id: string;
  session_id: string;
  time_created: number;
  data: string;
}

interface MessageData {
  role?: string;
  time?: { created?: number; completed?: number };
  content?: Array<{ type: string; value?: string; text?: string }>;
  tokens?: {
    input?: number;
    output?: number;
    reasoning?: number;
    cache?: {
      read?: number;
      write?: number;
    };
  };
}

interface PartData {
  type?: string;
  text?: string;
  value?: string;
}

interface JoinedPartRow {
  mid: string;
  mdata: string;
  pdata: string;
  time_created?: number;
}

interface MessagePart {
  messageId: string;
  role: 'user' | 'assistant';
  content: string;
  timestamp?: string;
  usage?: TokenUsage;
}

export class OpenCodeAdapter implements SessionAdapter {
  readonly name = 'opencode' as const;
  private dbPath: string;

  constructor(dbPath?: string) {
    this.dbPath =
      dbPath ?? join(homedir(), '.local', 'share', 'opencode', 'opencode.db');
  }

  async detect(): Promise<boolean> {
    return existsSync(this.dbPath);
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    if (!existsSync(this.dbPath)) return;

    let db: Database.Database | null = null;
    try {
      db = new Database(this.dbPath, { readonly: true });
      const rows = db
        .prepare<[], SessionRow>(
          'SELECT id, directory, title, time_created, time_updated FROM session WHERE time_archived IS NULL ORDER BY time_updated DESC',
        )
        .all();

      for (const row of rows) {
        yield `${this.dbPath}::${row.id}`;
      }
    } catch {
      // DB open or query failed
    } finally {
      db?.close();
    }
  }

  private splitVirtualPath(
    filePath: string,
  ): { dbPath: string; sessionId: string } | null {
    // Split from the right: the locator is `${dbPath}::${sessionId}` and the
    // session id never contains '::', so lastIndexOf keeps the split correct
    // even when the db path itself contains '::' (e.g. an odd mount point).
    const idx = filePath.lastIndexOf('::');
    if (idx === -1) return null;
    return {
      dbPath: filePath.slice(0, idx),
      sessionId: filePath.slice(idx + 2),
    };
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    const parts = this.splitVirtualPath(filePath);
    if (!parts) return null;

    const { dbPath, sessionId } = parts;

    let db: Database.Database | null = null;
    try {
      db = new Database(dbPath, { readonly: true });

      const session = db
        .prepare<[string], SessionRow>(
          'SELECT id, directory, title, time_created, time_updated FROM session WHERE id = ? AND time_archived IS NULL',
        )
        .get(sessionId);

      if (!session) return null;

      const messages = db
        .prepare<[string], MessageRow>(
          'SELECT id, session_id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created ASC',
        )
        .all(sessionId);

      let startTime = new Date(session.time_created).toISOString();
      let endTime: string | undefined;

      if (messages.length > 0) {
        startTime = new Date(messages[0].time_created).toISOString();
        endTime = new Date(
          messages[messages.length - 1].time_created,
        ).toISOString();
      }

      const countRows = db
        .prepare<[string], JoinedPartRow>(
          `SELECT m.id AS mid, m.data AS mdata, p.data AS pdata
           FROM message m
           JOIN part p ON p.message_id = m.id
           WHERE m.session_id = ?`,
        )
        .all(sessionId);

      const userMessageIds = new Set<string>();
      const assistantMessageIds = new Set<string>();
      for (const row of countRows) {
        const part = this.messagePart(row);
        if (!part) continue;
        if (part.role === 'user') userMessageIds.add(part.messageId);
        else assistantMessageIds.add(part.messageId);
      }
      const userMessageCount = userMessageIds.size;
      const assistantMessageCount = assistantMessageIds.size;

      // Per-session size = message payload bytes + part payload bytes. The old
      // statSync(dbPath) measured the whole shared SQLite file and attributed
      // the entire DB size to every session. Sum length() in SQL so this stays
      // byte-for-byte identical to the Swift OpenCode adapter (parity).
      const messageBytesRow = db
        .prepare<[string], { bytes: number }>(
          'SELECT COALESCE(SUM(length(data)), 0) AS bytes FROM message WHERE session_id = ?',
        )
        .get(sessionId);
      const partBytesRow = db
        .prepare<[string], { bytes: number }>(
          `SELECT COALESCE(SUM(length(p.data)), 0) AS bytes
           FROM part p JOIN message m ON m.id = p.message_id
           WHERE m.session_id = ?`,
        )
        .get(sessionId);
      const perSessionBytes =
        (messageBytesRow?.bytes ?? 0) + (partBytesRow?.bytes ?? 0);

      return {
        id: session.id,
        source: 'opencode',
        startTime,
        endTime,
        cwd: session.directory,
        messageCount: userMessageCount + assistantMessageCount,
        userMessageCount,
        assistantMessageCount,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: session.title || undefined,
        filePath,
        sizeBytes: perSessionBytes,
      };
    } catch {
      return null;
    } finally {
      db?.close();
    }
  }

  async *streamMessages(
    filePath: string,
    opts: StreamMessagesOptions = {},
  ): AsyncGenerator<Message> {
    const parts = this.splitVirtualPath(filePath);
    if (!parts) return;

    const { dbPath, sessionId } = parts;
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? Infinity;

    let db: Database.Database | null = null;
    try {
      db = new Database(dbPath, { readonly: true });

      const rows = db
        .prepare<[string], JoinedPartRow>(
          `SELECT m.id AS mid, m.data AS mdata, p.data AS pdata, m.time_created
           FROM message m
           JOIN part p ON p.message_id = m.id
           WHERE m.session_id = ?
           ORDER BY m.time_created ASC, p.time_created ASC`,
        )
        .all(sessionId);

      const messages: Message[] = [];
      const indexByMessageId = new Map<string, number>();
      for (const row of rows) {
        const part = this.messagePart(row);
        if (!part) continue;
        const index = indexByMessageId.get(part.messageId);
        if (index !== undefined) {
          messages[index].content += `\n${part.content}`;
        } else {
          indexByMessageId.set(part.messageId, messages.length);
          messages.push({
            role: part.role,
            content: part.content,
            timestamp: part.timestamp,
            usage: part.usage,
          });
        }
      }

      for (const message of messages.slice(offset, offset + limit)) {
        yield message;
      }
    } catch {
      // DB open or query failed
    } finally {
      db?.close();
    }
  }

  async isAccessible(locator: string): Promise<boolean> {
    const parts = this.splitVirtualPath(locator);
    if (!parts) return false;
    if (!existsSync(parts.dbPath)) return false;
    let db: Database.Database | null = null;
    try {
      db = new Database(parts.dbPath, { readonly: true });
      const row = db
        .prepare('SELECT 1 FROM session WHERE id = ? LIMIT 1')
        .get(parts.sessionId);
      return row !== undefined;
    } catch {
      return false;
    } finally {
      db?.close();
    }
  }

  private usage(tokens: MessageData['tokens']): TokenUsage | undefined {
    if (!tokens) return undefined;
    const inputTokens = this.int(tokens.input);
    const outputTokens = this.int(tokens.output) + this.int(tokens.reasoning);
    const cacheReadTokens = this.int(tokens.cache?.read);
    const cacheCreationTokens = this.int(tokens.cache?.write);

    if (
      inputTokens === 0 &&
      outputTokens === 0 &&
      cacheReadTokens === 0 &&
      cacheCreationTokens === 0
    )
      return undefined;

    return {
      inputTokens,
      outputTokens,
      cacheReadTokens,
      cacheCreationTokens,
    };
  }

  private int(value: unknown): number {
    return typeof value === 'number' && Number.isFinite(value)
      ? Math.trunc(value)
      : 0;
  }

  private normalizedPartType(value: unknown): string {
    return typeof value === 'string' ? value.trim().toLowerCase() : '';
  }

  private messagePart(row: JoinedPartRow): MessagePart | null {
    let mdata: MessageData;
    let pdata: PartData;
    try {
      mdata = JSON.parse(row.mdata);
      pdata = JSON.parse(row.pdata);
    } catch {
      return null;
    }

    if (mdata.role !== 'user' && mdata.role !== 'assistant') return null;
    if (this.normalizedPartType(pdata.type) !== 'text') return null;
    const content =
      typeof pdata.text === 'string'
        ? pdata.text
        : typeof pdata.value === 'string'
          ? pdata.value
          : '';
    if (!content.trim()) return null;

    return {
      messageId: row.mid,
      role: mdata.role,
      content,
      timestamp:
        typeof row.time_created === 'number'
          ? new Date(row.time_created).toISOString()
          : undefined,
      usage: mdata.role === 'assistant' ? this.usage(mdata.tokens) : undefined,
    };
  }
}
