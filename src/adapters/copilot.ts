// src/adapters/copilot.ts
// GitHub Copilot CLI adapter
// Sessions stored in ~/.copilot/session-state/<uuid>/events.jsonl
import { createReadStream } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { createInterface } from 'node:readline';
import { isFileAccessible } from './_accessible.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  TokenUsage,
} from './types.js';

export class CopilotAdapter implements SessionAdapter {
  readonly name = 'copilot' as const;
  private static readonly maxCheckpointBodyLength = 4_000;
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
          continue;
        } catch {
          // no events.jsonl, try checkpoint fallback
        }
        const checkpointIndexPath = join(
          this.sessionRoot,
          dir.name,
          'checkpoints',
          'index.md',
        );
        if ((await this.checkpointEntries(checkpointIndexPath)).length > 0) {
          yield checkpointIndexPath;
        }
      }
    } catch {
      // sessionRoot doesn't exist
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      if (this.isCheckpointIndex(filePath)) {
        return await this.parseCheckpointSessionInfo(filePath);
      }

      const fileStat = await stat(filePath);
      const sessionDir = join(filePath, '..');

      // Try to read workspace.yaml for metadata (simple key: value parsing)
      const workspace = await readWorkspace(join(sessionDir, 'workspace.yaml'));

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
    if (this.isCheckpointIndex(filePath)) {
      const offset = Math.max(opts.offset ?? 0, 0);
      const limit = opts.limit ?? Infinity;
      const entries = await this.checkpointEntries(filePath);
      let yielded = 0;
      for (let i = offset; i < entries.length && yielded < limit; i++) {
        const entry = entries[i];
        yield {
          role: 'system',
          content: await this.checkpointMessageContent(entry, filePath),
        };
        yielded++;
      }
      return;
    }

    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? Infinity;

    if (limit === Infinity) {
      const messages: Message[] = [];
      let shutdownUsage: TokenUsage | undefined;
      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;
        const type = obj.type as string;
        const data = obj.data as Record<string, unknown> | undefined;
        if (type === 'user.message' || type === 'assistant.message') {
          messages.push(
            this.messageFromEvent(
              type,
              data,
              obj.timestamp as string | undefined,
            ),
          );
        } else if (type === 'session.shutdown') {
          shutdownUsage = mergeUsage(
            shutdownUsage,
            shutdownUsageFromData(data),
          );
        }
      }
      if (shutdownUsage) {
        for (let i = messages.length - 1; i >= 0; i--) {
          if (messages[i].role === 'assistant') {
            messages[i].usage = shutdownUsage;
            break;
          }
        }
      }
      for (const message of messages.slice(Math.max(offset, 0))) {
        yield message;
      }
      return;
    }

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

      yield this.messageFromEvent(
        type,
        data,
        obj.timestamp as string | undefined,
      );
      yielded++;
    }
  }

  private messageFromEvent(
    type: string,
    data: Record<string, unknown> | undefined,
    timestamp: string | undefined,
  ): Message {
    return {
      role: type === 'user.message' ? 'user' : 'assistant',
      content: (data?.content as string) || '',
      timestamp,
    };
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    // try/finally so a consumer that breaks early (e.g. limit/offset slicing in
    // streamMessages) still closes the readline interface + fd — otherwise we
    // leak descriptors and hit EMFILE when indexing many sessions.
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

  private isCheckpointIndex(filePath: string): boolean {
    const parts = filePath.split(/[\\/]/);
    return parts.at(-1) === 'index.md' && parts.at(-2) === 'checkpoints';
  }

  private async parseCheckpointSessionInfo(
    filePath: string,
  ): Promise<SessionInfo | null> {
    const entries = await this.checkpointEntries(filePath);
    if (entries.length === 0) return null;
    const fileStat = await stat(filePath);
    const sessionDir = join(filePath, '..', '..');
    const workspace = await readWorkspace(join(sessionDir, 'workspace.yaml'));
    const sessionId = workspace.id || sessionDir.split('/').pop() || '';
    if (!sessionId) return null;
    return {
      id: sessionId,
      source: 'copilot',
      startTime: workspace.created_at || '',
      endTime: workspace.updated_at || undefined,
      cwd: workspace.cwd || '',
      messageCount: entries.length,
      userMessageCount: 0,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: entries.length,
      summary: entries[0]?.title,
      filePath,
      sizeBytes: fileStat.size,
    };
  }

  private async checkpointEntries(
    filePath: string,
  ): Promise<CheckpointEntry[]> {
    let content: string;
    try {
      content = await readFile(filePath, 'utf8');
    } catch {
      return [];
    }
    return content
      .split('\n')
      .map((line): CheckpointEntry | null => {
        const columns = line.split('|').map((column) => column.trim());
        const number = Number.parseInt(columns[1] ?? '', 10);
        const title = columns[2] ?? '';
        if (!Number.isFinite(number) || title.length === 0) return null;
        return {
          number,
          title,
          fileName: columns[3]?.length ? columns[3] : undefined,
        };
      })
      .filter((entry): entry is CheckpointEntry => entry !== null);
  }

  private async checkpointMessageContent(
    entry: CheckpointEntry,
    checkpointIndexPath: string,
  ): Promise<string> {
    const title = `Checkpoint ${entry.number}: ${entry.title}`;
    const body = await this.checkpointBody(entry, checkpointIndexPath);
    return body ? `${title}\n\n${body}` : title;
  }

  private async checkpointBody(
    entry: CheckpointEntry,
    checkpointIndexPath: string,
  ): Promise<string | undefined> {
    if (
      !entry.fileName ||
      entry.fileName !== basename(entry.fileName) ||
      !entry.fileName.endsWith('.md')
    ) {
      return undefined;
    }
    let content: string;
    try {
      content = await readFile(
        join(checkpointIndexPath, '..', entry.fileName),
        'utf8',
      );
    } catch {
      return undefined;
    }
    const trimmed = content.trim();
    return trimmed
      ? trimmed.slice(0, CopilotAdapter.maxCheckpointBodyLength)
      : undefined;
  }
}

interface CheckpointEntry {
  number: number;
  title: string;
  fileName?: string;
}

async function readWorkspace(
  filePath: string,
): Promise<Record<string, string>> {
  const workspace: Record<string, string> = {};
  try {
    const yamlContent = await readFile(filePath, 'utf8');
    for (const line of yamlContent.split('\n')) {
      const m = line.match(/^(\w+):\s*(.+)$/);
      if (m) workspace[m[1]] = stripYamlQuotes(m[2].trim());
    }
  } catch {
    /* no workspace.yaml */
  }
  return workspace;
}

function shutdownUsageFromData(
  data: Record<string, unknown> | undefined,
): TokenUsage | undefined {
  const modelMetrics = data?.modelMetrics;
  if (!modelMetrics || typeof modelMetrics !== 'object') return undefined;
  let total: TokenUsage | undefined;
  for (const metric of Object.values(modelMetrics as Record<string, unknown>)) {
    if (!metric || typeof metric !== 'object') continue;
    const usage = (metric as Record<string, unknown>).usage;
    if (!usage || typeof usage !== 'object') continue;
    total = mergeUsage(total, {
      inputTokens: int((usage as Record<string, unknown>).inputTokens),
      outputTokens: int((usage as Record<string, unknown>).outputTokens),
      cacheReadTokens: int((usage as Record<string, unknown>).cacheReadTokens),
      cacheCreationTokens: int(
        (usage as Record<string, unknown>).cacheWriteTokens,
      ),
    });
  }
  return total;
}

function mergeUsage(
  lhs: TokenUsage | undefined,
  rhs: TokenUsage | undefined,
): TokenUsage | undefined {
  if (!rhs) return lhs;
  const merged = {
    inputTokens: (lhs?.inputTokens ?? 0) + rhs.inputTokens,
    outputTokens: (lhs?.outputTokens ?? 0) + rhs.outputTokens,
    cacheReadTokens: (lhs?.cacheReadTokens ?? 0) + (rhs.cacheReadTokens ?? 0),
    cacheCreationTokens:
      (lhs?.cacheCreationTokens ?? 0) + (rhs.cacheCreationTokens ?? 0),
  };
  if (
    merged.inputTokens === 0 &&
    merged.outputTokens === 0 &&
    merged.cacheReadTokens === 0 &&
    merged.cacheCreationTokens === 0
  ) {
    return lhs;
  }
  return merged;
}

function int(value: unknown): number {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === 'string') {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

// Strip a single matched pair of YAML quote chars from a value.
// `"/path with space"` → `/path with space`. Mismatched or absent → unchanged.
function stripYamlQuotes(value: string): string {
  if (value.length < 2) return value;
  const first = value[0];
  const last = value[value.length - 1];
  if ((first === '"' || first === "'") && first === last) {
    return value.slice(1, -1);
  }
  return value;
}
