// src/adapters/codex.ts
import { createReadStream } from 'node:fs';
import { glob, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import { isFileAccessible } from './_accessible.js';
import { truncateJSON, truncateString } from './_truncate.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  TokenUsage,
} from './types.js';

export class CodexAdapter implements SessionAdapter {
  readonly name = 'codex' as const;
  private sessionRoots: string[];

  constructor(sessionsRoot?: string) {
    const root = sessionsRoot ?? join(homedir(), '.codex', 'sessions');
    this.sessionRoots = this.expandSessionRoots(root);
  }

  async detect(): Promise<boolean> {
    for (const root of this.sessionRoots) {
      try {
        await stat(root);
        return true;
      } catch {
        // try next root
      }
    }
    return false;
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    for (const root of this.sessionRoots) {
      try {
        const pattern = join(root, '**', 'rollout-*.jsonl');
        for await (const file of glob(pattern)) {
          yield file;
        }
      } catch {
        // sessions root 不存在时静默返回
      }
    }
  }

  private expandSessionRoots(root: string): string[] {
    if (basename(root) !== 'sessions') return [root];
    return [root, join(dirname(root), 'archived_sessions')];
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      let meta: Record<string, unknown> | null = null;
      let userCount = 0;
      let assistantCount = 0;
      let toolCount = 0;
      let systemCount = 0;
      let firstUserText = '';
      let lastTimestamp = '';
      let detectedModel: string | undefined;
      let turnContextModel: string | undefined;

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line);
        if (!obj) continue;

        // Update lastTimestamp on any line carrying a timestamp so endTime
        // reflects the true tail (function_call_output, event_msg, etc.).
        if (obj.timestamp) {
          lastTimestamp = obj.timestamp as string;
        }

        if (obj.type === 'session_meta' && !meta) {
          meta = obj.payload as Record<string, unknown>;
        }

        if (
          obj.type === 'turn_context' &&
          !turnContextModel &&
          obj.payload &&
          typeof obj.payload === 'object'
        ) {
          const payload = obj.payload as Record<string, unknown>;
          if (typeof payload.model === 'string') {
            turnContextModel = payload.model;
          }
        }

        if (obj.type === 'response_item') {
          const payload = obj.payload as Record<string, unknown>;
          // The real model name lives on response_item.payload.model
          // (e.g. "gpt-5.3-codex"); otherwise Codex stores the label on
          // turn_context.payload.model. session_meta.model_provider is only
          // the provider name and must not become the model.
          if (!detectedModel && typeof payload.model === 'string') {
            detectedModel = payload.model;
          }
          if (payload.type === 'message') {
            const role = payload.role as string;
            if (role === 'user') {
              const text = this.extractText(payload.content as unknown[]);
              if (this.isSystemInjection(text)) {
                systemCount++;
              } else {
                userCount++;
                if (!firstUserText) {
                  firstUserText = text;
                }
              }
            } else if (role === 'assistant') {
              assistantCount++;
            }
          } else if (
            payload.type === 'function_call' ||
            payload.type === 'function_call_output'
          ) {
            // streamMessages emits both; counts must match (M6).
            toolCount++;
          }
        }
      }

      if (!meta) return null;

      const payload = meta as Record<string, unknown>;
      // Reject session_meta entries that do not carry an id — without a stable
      // id we cannot upsert or dedup the session, and downstream code assumes
      // SessionInfo.id is a non-empty string.
      const rawId = payload.id;
      if (typeof rawId !== 'string' || rawId.length === 0) return null;
      const agentRole = payload.agent_role as string | undefined;
      const originator = payload.originator as string | undefined;
      // If Claude Code launched this session and no explicit role was set,
      // mark it as dispatched so it skips dispatch-pattern matching in backfill.
      const effectiveRole =
        agentRole || (originator === 'Claude Code' ? 'dispatched' : undefined);
      // session_meta may omit timestamp; fall back to file mtime like the other
      // adapters so startTime is never undefined (it sorts to epoch otherwise).
      const metaTimestamp =
        typeof payload.timestamp === 'string' ? payload.timestamp : '';
      const startTime =
        metaTimestamp ||
        lastTimestamp ||
        new Date(fileStat.mtimeMs).toISOString();
      return {
        id: rawId,
        source: 'codex',
        startTime,
        endTime: lastTimestamp || undefined,
        cwd: (payload.cwd as string) || '',
        model:
          detectedModel ||
          turnContextModel ||
          (payload.model as string | undefined),
        messageCount: userCount + assistantCount + toolCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: toolCount,
        systemMessageCount: systemCount,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath,
        sizeBytes: fileStat.size,
        agentRole: effectiveRole,
        originator: originator || undefined,
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
    let pending: Message | null = null;
    let pendingUsageCameFromTokenCount = false;
    let pendingUsage: TokenUsage | undefined;

    const flushPending = (): Message | null => {
      if (!pending) return null;
      const msg = pending;
      pending = null;
      pendingUsageCameFromTokenCount = false;
      if (count < offset) {
        count++;
        return null;
      }
      count++;
      yielded++;
      return msg;
    };

    for await (const line of this.readLines(filePath)) {
      const obj = this.parseLine(line);
      if (!obj) continue;

      const eventUsage = this.tokenCountUsage(obj);
      if (eventUsage) {
        if (pending && pending.role !== 'user') {
          if (pendingUsageCameFromTokenCount || !pending.usage) {
            pending.usage = this.mergeUsage(pending.usage, eventUsage);
            pendingUsageCameFromTokenCount = true;
          }
        } else {
          pendingUsage = this.mergeUsage(pendingUsage, eventUsage);
        }
        continue;
      }

      if (obj.type !== 'response_item') continue;

      const payload = obj.payload as Record<string, unknown>;
      const timestamp = obj.timestamp as string | undefined;
      let msg: Message | null = null;

      if (payload.type === 'message') {
        const role = payload.role as string;
        if (role !== 'user' && role !== 'assistant') continue;
        const built: Message = {
          role: role as 'user' | 'assistant',
          content: this.extractText(payload.content as unknown[]),
          timestamp,
        };
        if (role === 'assistant') {
          const rawUsage = payload.usage as Record<string, unknown> | undefined;
          if (rawUsage && typeof rawUsage === 'object') {
            built.usage = {
              inputTokens: (rawUsage.input_tokens as number) ?? 0,
              outputTokens: (rawUsage.output_tokens as number) ?? 0,
              cacheReadTokens: rawUsage.cache_read_input_tokens as
                | number
                | undefined,
              cacheCreationTokens: rawUsage.cache_creation_input_tokens as
                | number
                | undefined,
            };
          }
        }
        msg = built;
      } else if (payload.type === 'function_call') {
        const name = (payload.name as string) || '';
        const argsStr = truncateJSON(payload.arguments, 500) ?? '';
        msg = {
          role: 'tool',
          content: argsStr ? `${name} ${argsStr}` : name,
          timestamp,
          toolCalls: [{ name, input: argsStr || undefined }],
        };
      } else if (payload.type === 'function_call_output') {
        const output = payload.output;
        msg = {
          role: 'tool',
          content:
            typeof output === 'string'
              ? truncateString(output, 2000)
              : (truncateJSON(output, 2000) ?? ''),
          timestamp,
        };
      }

      if (!msg) continue;

      const ready = flushPending();
      if (ready) {
        yield ready;
        if (yielded >= limit) break;
      }
      if (msg.role !== 'user' && pendingUsage) {
        msg.usage ??= pendingUsage;
        pendingUsage = undefined;
      }
      pending = msg;
      pendingUsageCameFromTokenCount = false;
    }

    if (yielded < limit) {
      const ready = flushPending();
      if (ready) yield ready;
    }
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    // try/finally so a consumer that breaks early (e.g. .limit/.prefix) still
    // closes the readline interface + fd — otherwise we leak descriptors and
    // hit EMFILE when indexing many sessions.
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

  private tokenCountUsage(
    obj: Record<string, unknown>,
  ): TokenUsage | undefined {
    if (obj.type !== 'event_msg') return undefined;
    const payload = obj.payload;
    if (!payload || typeof payload !== 'object') return undefined;
    const payloadRecord = payload as Record<string, unknown>;
    if (payloadRecord.type !== 'token_count') return undefined;
    const info = payloadRecord.info;
    if (!info || typeof info !== 'object') return undefined;
    const usage = (info as Record<string, unknown>).last_token_usage;
    if (!usage || typeof usage !== 'object') return undefined;
    const usageRecord = usage as Record<string, unknown>;
    const inputTokens = this.int(usageRecord.input_tokens);
    const cachedInputTokens = this.int(usageRecord.cached_input_tokens);
    const outputTokens = this.int(usageRecord.output_tokens);
    const tokenUsage = {
      inputTokens: Math.max(inputTokens - cachedInputTokens, 0),
      outputTokens,
      cacheReadTokens: cachedInputTokens,
      cacheCreationTokens: 0,
    };
    if (
      tokenUsage.inputTokens <= 0 &&
      tokenUsage.outputTokens <= 0 &&
      tokenUsage.cacheReadTokens <= 0 &&
      tokenUsage.cacheCreationTokens <= 0
    ) {
      return undefined;
    }
    return tokenUsage;
  }

  private mergeUsage(lhs: TokenUsage | undefined, rhs: TokenUsage): TokenUsage {
    if (!lhs) return rhs;
    return {
      inputTokens: lhs.inputTokens + rhs.inputTokens,
      outputTokens: lhs.outputTokens + rhs.outputTokens,
      cacheReadTokens: (lhs.cacheReadTokens ?? 0) + (rhs.cacheReadTokens ?? 0),
      cacheCreationTokens:
        (lhs.cacheCreationTokens ?? 0) + (rhs.cacheCreationTokens ?? 0),
    };
  }

  private int(value: unknown): number {
    return typeof value === 'number' && Number.isFinite(value) ? value : 0;
  }

  private isSystemInjection(text: string): boolean {
    return (
      text.startsWith('# AGENTS.md instructions for ') ||
      text.includes('<INSTRUCTIONS>') ||
      text.startsWith('<local-command-caveat>') ||
      text.startsWith('<local-command-stdout>') ||
      text.startsWith('<environment_context>') ||
      text.includes('<command-name>') ||
      text.includes('<command-message>') ||
      text.startsWith('Unknown skill: ') ||
      text.startsWith('Invoke the superpowers:') ||
      text.startsWith('Base directory for this skill:')
    );
  }

  private extractText(content: unknown[]): string {
    if (!Array.isArray(content)) return '';
    // Search the full array for a usable text payload. Returning on the first
    // truthy `text`/`input_text` field would surface stray strings on non-text
    // blocks (e.g. a tool_use entry that happens to carry a `text` name) and
    // hide the real user/assistant text that follows.
    for (const item of content) {
      if (item === null || typeof item !== 'object') continue;
      const c = item as Record<string, unknown>;
      const type = typeof c.type === 'string' ? c.type : '';
      if (
        type !== '' &&
        type !== 'input_text' &&
        type !== 'output_text' &&
        type !== 'text'
      ) {
        continue;
      }
      if (typeof c.text === 'string' && c.text) return c.text;
      if (typeof c.input_text === 'string' && c.input_text) return c.input_text;
    }
    return '';
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}
