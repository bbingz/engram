// src/adapters/cursor.ts

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
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
  latestConversationSummary?: { summary?: unknown };
  name?: unknown;
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
              bubbles.push(JSON.parse(br.value));
            } catch {
              /* skip */
            }
          }
        }
        let userMessageCount = 0;
        let assistantMessageCount = 0;
        let firstUserText: string | undefined;
        for (const b of bubbles) {
          const role =
            b.type === 1 ? 'user' : b.type === 2 ? 'assistant' : null;
          if (!role) continue;
          // Prefer first non-empty-after-trim candidate; empty/whitespace text must
          // not shadow restored rawText (matches Swift CursorAdapter).
          const content =
            [b.text, b.rawText].find((c) => (c ?? '').trim()) ?? '';
          if (!content.trim()) continue;
          if (role === 'user') {
            userMessageCount++;
            firstUserText ??= content.trim();
          } else assistantMessageCount++;
        }

        const cwd = this.inferCwd(db, composerId);
        const summary =
          conversationSummary(data.latestConversationSummary?.summary) ??
          firstUserText;
        return {
          id: data.composerId,
          source: 'cursor',
          startTime: new Date(data.createdAt).toISOString(),
          endTime:
            data.lastUpdatedAt !== data.createdAt
              ? new Date(data.lastUpdatedAt).toISOString()
              : undefined,
          cwd,
          project: cwd ? basename(cwd) : undefined,
          messageCount: userMessageCount + assistantMessageCount,
          userMessageCount,
          assistantMessageCount,
          toolMessageCount: 0,
          systemMessageCount: 0,
          summary: summary ? truncateGraphemes(summary, 200) : undefined,
          displayTitle: officialTitle(data.name),
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
          const content =
            [bubble.text, bubble.rawText].find((c) => (c ?? '').trim()) ?? '';
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

  private inferCwd(db: BetterSqlite3.Database, composerId: string): string {
    const globalStorage = dirname(this.dbPath);
    if (basename(globalStorage) !== 'globalStorage') return '';
    const workspaceStorage = join(dirname(globalStorage), 'workspaceStorage');
    if (!existsSync(workspaceStorage)) return '';
    const workspaceCwds = new Map<string, string>();
    const paths = new Set<string>();
    for (const workspaceName of readdirSync(workspaceStorage)) {
      const workspace = join(workspaceStorage, workspaceName);
      const metadataPath = join(workspace, 'workspace.json');
      try {
        const metadata = JSON.parse(
          readFileSync(metadataPath, 'utf8'),
        ) as Record<string, unknown>;
        if (metadata.configuration || typeof metadata.folder !== 'string')
          continue;
        const folder = new URL(metadata.folder);
        if (
          folder.protocol !== 'file:' ||
          (folder.hostname && folder.hostname !== 'localhost')
        )
          continue;
        const cwd = decodeURIComponent(folder.pathname);
        if (!cwd.startsWith('/') || cwd === '/') continue;
        workspaceCwds.set(workspaceName, cwd);
        const workspaceDb = new BetterSqlite3(join(workspace, 'state.vscdb'), {
          readonly: true,
        });
        try {
          const row = workspaceDb
            .prepare('SELECT value FROM ItemTable WHERE key = ?')
            .get('composer.composerData') as { value: string } | undefined;
          const composers =
            row && (JSON.parse(row.value) as { allComposers?: unknown });
          if (
            Array.isArray(composers?.allComposers) &&
            composers.allComposers.some(
              (item) =>
                typeof item === 'object' &&
                item !== null &&
                (item as { composerId?: unknown }).composerId === composerId,
            )
          )
            paths.add(cwd);
        } finally {
          workspaceDb.close();
        }
      } catch {}
    }
    try {
      const row = db
        .prepare('SELECT value FROM ItemTable WHERE key = ?')
        .get('composer.composerHeaders') as { value: string } | undefined;
      const headers =
        row && (JSON.parse(row.value) as { allComposers?: unknown });
      if (Array.isArray(headers?.allComposers)) {
        for (const header of headers.allComposers) {
          if (!header || typeof header !== 'object') continue;
          const value = header as {
            composerId?: unknown;
            workspaceIdentifier?: { id?: unknown };
          };
          if (
            value.composerId !== composerId ||
            typeof value.workspaceIdentifier?.id !== 'string'
          )
            continue;
          const cwd = workspaceCwds.get(value.workspaceIdentifier.id);
          if (cwd) paths.add(cwd);
        }
      }
    } catch {
      return '';
    }
    return paths.size === 1 ? [...paths][0] : '';
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

function conversationSummary(value: unknown): string | undefined {
  let current = value;
  for (let depth = 0; depth < 4; depth++) {
    if (typeof current === 'string') {
      const trimmed = current.trim();
      return trimmed || undefined;
    }
    if (!current || typeof current !== 'object' || Array.isArray(current))
      return undefined;
    current = (current as Record<string, unknown>).summary;
  }
  return undefined;
}

function officialTitle(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed ? truncateGraphemes(trimmed, 120) : undefined;
}

function truncateGraphemes(value: string, maximum: number): string {
  const segments = new Intl.Segmenter(undefined, {
    granularity: 'grapheme',
  }).segment(value);
  let result = '';
  let count = 0;
  for (const { segment } of segments) {
    if (count === maximum) break;
    result += segment;
    count++;
  }
  return result;
}
