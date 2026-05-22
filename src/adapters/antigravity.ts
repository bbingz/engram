// src/adapters/antigravity.ts
import { createReadStream } from 'node:fs';
import { mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { isFileAccessible } from './_accessible.js';
import { truncateJSON } from './_truncate.js';
import { CascadeGrpcClient } from './grpc/cascade-client.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  ToolCall,
} from './types.js';

interface CacheMetaLine {
  id: string;
  title: string;
  summary?: string; // AI-generated summary from GetAllCascadeTrajectories
  createdAt: string;
  updatedAt: string;
  cwd?: string; // workspace folder path from GetAllCascadeTrajectories
  pbSizeBytes?: number; // .pb file size stored for dedup consistency
}

export class AntigravityAdapter implements SessionAdapter {
  readonly name = 'antigravity' as const;
  private daemonDir: string;
  private cacheDir: string;
  private conversationsDir: string;
  private cliBrainDir: string;

  constructor(
    daemonDir?: string,
    cacheDir?: string,
    conversationsDir?: string,
    cliBrainDir?: string,
  ) {
    const home = homedir();
    this.daemonDir =
      daemonDir ?? join(home, '.gemini', 'antigravity', 'daemon');
    this.cacheDir = cacheDir ?? join(home, '.engram', 'cache', 'antigravity');
    this.conversationsDir =
      conversationsDir ?? join(home, '.gemini', 'antigravity', 'conversations');
    this.cliBrainDir =
      cliBrainDir ?? join(home, '.gemini', 'antigravity-cli', 'brain');
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.daemonDir);
      return true;
    } catch {
      try {
        await stat(this.cacheDir);
        return true;
      } catch {
        try {
          await stat(this.cliBrainDir);
          return true;
        } catch {
          return false;
        }
      }
    }
  }

  // Sync runs before listing — fetches new/updated conversations from gRPC, saves to cache
  async sync(): Promise<void> {
    await mkdir(this.cacheDir, { recursive: true });
    // Try new process-based discovery first (Antigravity 1.18+), then old JSON file method
    const client =
      (await CascadeGrpcClient.fromProcess()) ??
      (await CascadeGrpcClient.fromDaemonDir(this.daemonDir));
    if (!client) return; // app not running, use existing cache

    try {
      const conversations = await client.listConversations();
      const syncedIds = new Set<string>();

      for (const conv of conversations) {
        if (!conv.cascadeId) continue;
        syncedIds.add(conv.cascadeId);
        const cachePath = join(this.cacheDir, `${conv.cascadeId}.jsonl`);
        const pbPath = join(this.conversationsDir, `${conv.cascadeId}.pb`);

        // Check if cache is fresh (pb mtime <= cache mtime) AND has actual content (> meta-only)
        try {
          const [pbStat, cacheStat] = await Promise.all([
            stat(pbPath),
            stat(cachePath),
          ]);
          if (cacheStat.mtimeMs >= pbStat.mtimeMs && cacheStat.size > 200)
            continue; // cache is fresh with content
        } catch {
          /* pb or cache doesn't exist — proceed with fetch */
        }

        try {
          // Primary: use ConnectRPC GetCascadeTrajectory for full conversation steps
          let messages = await client.getTrajectoryMessages(conv.cascadeId);
          // Fallback: try ConvertTrajectoryToMarkdown (older servers)
          if (messages.length === 0) {
            const markdown = await client.getMarkdown(conv.cascadeId);
            messages = parseMarkdownToMessages(markdown);
          }
          // Last resort: use the summary from GetAllCascadeTrajectories
          if (messages.length === 0 && conv.summary) {
            messages = [{ role: 'assistant', content: conv.summary }];
          }

          let pbSizeBytes: number | undefined;
          try {
            pbSizeBytes = (await stat(pbPath)).size;
          } catch {
            /* pb may not exist */
          }

          const metaLine: CacheMetaLine = {
            id: conv.cascadeId,
            title: conv.title,
            summary: conv.summary || undefined,
            createdAt: conv.createdAt,
            updatedAt: conv.updatedAt,
            cwd: conv.cwd || undefined,
            pbSizeBytes,
          };
          const lines = [
            JSON.stringify(metaLine),
            ...messages.map((m) => JSON.stringify(m)),
          ];
          await writeFile(cachePath, `${lines.join('\n')}\n`, 'utf8');
        } catch {
          /* skip if fetch fails */
        }
      }

      // Scan .pb directory for sessions not returned by API (API only returns ~10 recent)
      await this.syncFromPbFiles(client, syncedIds);
    } finally {
      client.close();
    }
  }

  /**
   * Sync .pb files not covered by GetAllCascadeTrajectories (which only returns ~10 recent).
   * For each uncached .pb, fetches content via GetCascadeTrajectory and creates a cache entry.
   */
  private async syncFromPbFiles(
    client: CascadeGrpcClient,
    syncedIds: Set<string>,
  ): Promise<void> {
    let pbFiles: string[];
    try {
      pbFiles = (await readdir(this.conversationsDir)).filter((f) =>
        f.endsWith('.pb'),
      );
    } catch {
      return;
    }

    for (const file of pbFiles) {
      const cascadeId = file.replace(/\.pb$/, '');
      if (syncedIds.has(cascadeId)) continue;

      const cachePath = join(this.cacheDir, `${cascadeId}.jsonl`);
      const pbPath = join(this.conversationsDir, file);

      // Skip if cache already exists with content
      try {
        const cacheStat = await stat(cachePath);
        if (cacheStat.size > 200) continue;
      } catch {
        /* no cache yet */
      }

      try {
        let messages = await client.getTrajectoryMessages(cascadeId);
        if (messages.length === 0) {
          const markdown = await client.getMarkdown(cascadeId);
          messages = parseMarkdownToMessages(markdown);
        }

        const pbStat = await stat(pbPath);
        const metaLine: CacheMetaLine = {
          id: cascadeId,
          title: '', // no title available from .pb scan
          createdAt: pbStat.birthtime.toISOString(),
          updatedAt: pbStat.mtime.toISOString(),
          pbSizeBytes: pbStat.size,
        };
        const lines = [
          JSON.stringify(metaLine),
          ...messages.map((m) => JSON.stringify(m)),
        ];
        await writeFile(cachePath, `${lines.join('\n')}\n`, 'utf8');
      } catch {
        /* skip on error */
      }
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    await this.sync();
    try {
      const files = await readdir(this.cacheDir);
      for (const file of files) {
        if (file.endsWith('.jsonl')) {
          yield join(this.cacheDir, file);
        }
      }
    } catch {
      /* cache dir not created yet */
    }
    try {
      const sessions = await readdir(this.cliBrainDir, { withFileTypes: true });
      for (const session of sessions) {
        if (!session.isDirectory()) continue;
        const transcript = join(
          this.cliBrainDir,
          session.name,
          '.system_generated',
          'logs',
          'transcript.jsonl',
        );
        try {
          await stat(transcript);
          yield transcript;
        } catch {
          /* no transcript */
        }
      }
    } catch {
      /* CLI brain dir not present */
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      if (this.isCliTranscript(filePath)) {
        return await this.parseCliTranscript(filePath);
      }
      const firstLine = await readFirstLine(filePath);
      if (!firstLine) return null;

      let meta: CacheMetaLine;
      try {
        meta = JSON.parse(firstLine) as CacheMetaLine;
      } catch {
        return null;
      }
      if (!meta.id) return null;

      // Use .pb file size (the real conversation).
      // Prefer value embedded in meta (written during sync), else stat the .pb directly.
      let sizeBytes: number;
      if (meta.pbSizeBytes && meta.pbSizeBytes > 0) {
        sizeBytes = meta.pbSizeBytes;
      } else {
        const pbPath = join(this.conversationsDir, `${meta.id}.pb`);
        try {
          sizeBytes = (await stat(pbPath)).size;
        } catch {
          sizeBytes = (await stat(filePath)).size;
        }
      }

      // Count messages (skip first meta line)
      let userCount = 0;
      let assistantCount = 0;
      let firstUserText = '';
      let isFirst = true;

      for await (const line of this.readLines(filePath)) {
        if (isFirst) {
          isFirst = false;
          continue;
        } // skip meta line
        try {
          const msg = JSON.parse(line) as { role: string; content: string };
          if (msg.role === 'user') {
            userCount++;
            if (!firstUserText) firstUserText = msg.content;
          } else if (msg.role === 'assistant') {
            assistantCount++;
          }
        } catch {
          /* skip */
        }
      }

      // If no cwd from gRPC, try to infer from file paths mentioned in messages
      let cwd = meta.cwd || '';
      if (!cwd) {
        const content = (await readFile(filePath, 'utf8')).slice(0, 50000); // scan first 50KB
        const pathMatches =
          content.match(/\/Users\/[^/]+\/-Code-\/([^/\s"'`)]+)/g) || [];
        if (pathMatches.length > 0) {
          // Count occurrences of each project name, pick the most frequent
          const counts = new Map<string, number>();
          for (const p of pathMatches) {
            const m = p.match(/\/-Code-\/([^/\s"'`)]+)/);
            if (m) counts.set(m[1], (counts.get(m[1]) || 0) + 1);
          }
          const topProject = [...counts.entries()].sort(
            (a, b) => b[1] - a[1],
          )[0];
          if (topProject)
            cwd = `/Users/${homedir().split('/').pop()}/-Code-/${topProject[0]}`;
        }
      }

      return {
        id: meta.id,
        source: 'antigravity',
        startTime: meta.createdAt,
        endTime: meta.updatedAt !== meta.createdAt ? meta.updatedAt : undefined,
        cwd,
        messageCount: userCount + assistantCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary:
          (meta.title || meta.summary || firstUserText).slice(0, 200) ||
          undefined,
        filePath,
        sizeBytes,
      };
    } catch {
      return null;
    }
  }

  async *streamMessages(
    filePath: string,
    opts: StreamMessagesOptions = {},
  ): AsyncGenerator<Message> {
    if (this.isCliTranscript(filePath)) {
      const offset = opts.offset ?? 0;
      const limit = opts.limit ?? Infinity;
      let count = 0;
      let yielded = 0;
      for await (const line of this.readLines(filePath)) {
        if (yielded >= limit) break;
        const obj = this.parseLine(line);
        if (!obj) continue;
        const msg = this.cliMessage(obj);
        if (!msg) continue;
        if (count < offset) {
          count++;
          continue;
        }
        count++;
        yield msg;
        yielded++;
      }
      return;
    }
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? Infinity;
    let count = 0;
    let yielded = 0;
    let isFirst = true;

    for await (const line of this.readLines(filePath)) {
      if (isFirst) {
        isFirst = false;
        continue;
      } // skip meta line
      if (yielded >= limit) break;

      try {
        const msg = JSON.parse(line) as {
          role: string;
          content: string;
          timestamp?: string;
        };
        if (msg.role !== 'user' && msg.role !== 'assistant') continue;
        if (count < offset) {
          count++;
          continue;
        }
        count++;
        yield {
          role: msg.role as 'user' | 'assistant',
          content: msg.content,
          timestamp: msg.timestamp,
        };
        yielded++;
      } catch {
        /* skip malformed */
      }
    }
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

  private isCliTranscript(filePath: string): boolean {
    const normalized = filePath.split('\\').join('/');
    const cliRoot = this.cliBrainDir.split('\\').join('/');
    return (
      normalized === cliRoot ||
      normalized.startsWith(`${cliRoot}/`) ||
      (normalized.includes('/.gemini/antigravity-cli/brain/') &&
        normalized.endsWith('/.system_generated/logs/transcript.jsonl'))
    );
  }

  private async parseCliTranscript(
    filePath: string,
  ): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      let startTime = '';
      let endTime = '';
      let userCount = 0;
      let assistantCount = 0;
      let toolCount = 0;
      let firstUserText = '';

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;
        const msg = this.cliMessage(obj);
        if (!msg) continue;
        if (!startTime && msg.timestamp) startTime = msg.timestamp;
        if (msg.timestamp) endTime = msg.timestamp;
        if (msg.role === 'user') {
          userCount++;
          if (!firstUserText) firstUserText = msg.content;
        } else if (msg.role === 'assistant') assistantCount++;
        else if (msg.role === 'tool') toolCount++;
      }

      const id = this.cliSessionId(filePath);
      if (!id || userCount + assistantCount + toolCount === 0) return null;
      return {
        id,
        source: 'antigravity',
        startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd: await this.inferCwd(filePath),
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

  private cliMessage(obj: Record<string, unknown>): Message | null {
    const type = obj.type as string | undefined;
    const timestamp = obj.created_at as string | undefined;
    const content = typeof obj.content === 'string' ? obj.content : '';
    if (type === 'USER_INPUT') return { role: 'user', content, timestamp };
    if (type === 'PLANNER_RESPONSE') {
      const body = content || ((obj.thinking as string | undefined) ?? '');
      const toolCalls = this.cliToolCalls(obj.tool_calls);
      return {
        role: 'assistant',
        content: body,
        timestamp,
        toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
      };
    }
    if (!content) return null;
    return { role: 'tool', content, timestamp };
  }

  private cliToolCalls(value: unknown): ToolCall[] {
    if (!Array.isArray(value)) return [];
    return value
      .filter((item): item is Record<string, unknown> => {
        return (
          item !== null &&
          typeof item === 'object' &&
          typeof (item as Record<string, unknown>).name === 'string'
        );
      })
      .map((item) => {
        return {
          name: item.name as string,
          input: truncateJSON(item.args, 500),
        };
      });
  }

  private cliSessionId(filePath: string): string {
    const normalized = filePath.split('\\').join('/');
    const cliRoot = this.cliBrainDir.split('\\').join('/');
    if (normalized.startsWith(`${cliRoot}/`)) {
      const first = normalized.slice(cliRoot.length + 1).split('/')[0] ?? '';
      if (first && !first.endsWith('.jsonl')) return first;
    }

    const parts = normalized.split('/');
    const brainIndex = parts.lastIndexOf('brain');
    if (
      brainIndex >= 0 &&
      parts[brainIndex + 2] === '.system_generated' &&
      parts[brainIndex + 3] === 'logs' &&
      parts[brainIndex + 4] === 'transcript.jsonl'
    ) {
      return parts[brainIndex + 1] ?? '';
    }
    return (
      normalized
        .split('/')
        .pop()
        ?.replace(/\.jsonl$/, '') ?? ''
    );
  }

  private async inferCwd(filePath: string): Promise<string> {
    try {
      const content = (await readFile(filePath, 'utf8')).slice(0, 50000);
      const pathMatches =
        content.match(/\/Users\/[^/]+\/-Code-\/([^/\s"'`)]+)/g) || [];
      if (pathMatches.length === 0) return '';
      const counts = new Map<string, number>();
      for (const p of pathMatches) {
        const m = p.match(/\/-Code-\/([^/\s"'`)]+)/);
        if (m) counts.set(m[1], (counts.get(m[1]) || 0) + 1);
      }
      const topProject = [...counts.entries()].sort((a, b) => b[1] - a[1])[0];
      return topProject
        ? `/Users/${homedir().split('/').pop()}/-Code-/${topProject[0]}`
        : '';
    } catch {
      return '';
    }
  }
}

// Parse the Markdown output of ConvertTrajectoryToMarkdown into {role, content} pairs.
// Format: ## User\n\ntext...\n\n## Cascade\n\ntext...
function parseMarkdownToMessages(
  markdown: string,
): { role: 'user' | 'assistant'; content: string; timestamp?: string }[] {
  const messages: { role: 'user' | 'assistant'; content: string }[] = [];
  const sections = markdown.split(/^##\s+/m).filter(Boolean);
  for (const section of sections) {
    const newline = section.indexOf('\n');
    if (newline === -1) continue;
    const header = section.slice(0, newline).trim().toLowerCase();
    const content = section.slice(newline + 1).trim();
    if (!content) continue;
    if (header.startsWith('user')) {
      messages.push({ role: 'user', content });
    } else if (header.startsWith('assistant') || header.startsWith('cascade')) {
      messages.push({ role: 'assistant', content });
    }
  }
  return messages;
}

async function readFirstLine(filePath: string): Promise<string | null> {
  // Stream the file and bail out after the first line. The cache meta file
  // can grow to multiple MB, so readFile-then-split would load the entire
  // payload into memory just to discard everything after the newline.
  const stream = createReadStream(filePath, { encoding: 'utf8' });
  const reader = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of reader) {
      const trimmed = line.trim();
      return trimmed || null;
    }
    return null;
  } finally {
    reader.close();
    stream.destroy();
  }
}
