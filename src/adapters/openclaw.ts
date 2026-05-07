import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { createInterface } from 'node:readline';
import { isFileAccessible } from './_accessible.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  ToolCall,
} from './types.js';

interface OpenClawRecord {
  type?: string;
  id?: string;
  timestamp?: string | number;
  cwd?: string;
  modelId?: string;
  message?: {
    role?: string;
    model?: string;
    content?: unknown;
    toolCallId?: string;
    tool_call_id?: string;
    toolName?: string;
    tool_name?: string;
    isError?: boolean;
    is_error?: boolean;
  };
}

interface OpenClawContentBlock {
  type?: string;
  text?: string;
  id?: string;
  toolCallId?: string;
  tool_call_id?: string;
  name?: string;
  tool_name?: string;
  arguments?: unknown;
}

function normalizeKey(value: unknown): string {
  return typeof value === 'string'
    ? value
        .trim()
        .toLowerCase()
        .replace(/[_\-\s]/g, '')
    : '';
}

function toIsoTimestamp(value: unknown): string | undefined {
  if (typeof value === 'string' && value.trim()) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? value : date.toISOString();
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    let seconds = value;
    if (seconds > 1e14) seconds /= 1_000_000;
    else if (seconds > 1e11) seconds /= 1_000;
    return new Date(seconds * 1000).toISOString();
  }
  return undefined;
}

function stringifyJSON(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value);
  } catch {
    return undefined;
  }
}

function isRedundantMediaAttachment(text: string): boolean {
  const lower = text.toLowerCase();
  return (
    lower.startsWith('[media attached:') ||
    (lower.includes('to send an image back') && lower.includes('media:'))
  );
}

function extractText(content: unknown): string {
  if (typeof content === 'string') return content.trim();
  if (!Array.isArray(content)) return '';
  const hasImage = content.some(
    (item) =>
      typeof item === 'object' &&
      item != null &&
      (item as { type?: unknown }).type === 'image',
  );
  const texts: string[] = [];
  for (const item of content) {
    if (typeof item !== 'object' || item == null) continue;
    const block = item as OpenClawContentBlock;
    if (block.type !== 'text' || typeof block.text !== 'string') continue;
    const trimmed = block.text.trim();
    if (!trimmed) continue;
    if (hasImage && isRedundantMediaAttachment(trimmed)) continue;
    texts.push(block.text);
  }
  if (texts.length > 0) return texts.join('\n');
  return hasImage ? 'Image attached' : '';
}

function extractToolCalls(content: unknown): ToolCall[] | undefined {
  if (!Array.isArray(content)) return undefined;
  const calls: ToolCall[] = [];
  for (const item of content) {
    if (typeof item !== 'object' || item == null) continue;
    const block = item as OpenClawContentBlock;
    if (normalizeKey(block.type) !== 'toolcall') continue;
    const name = block.name ?? block.tool_name;
    if (!name) continue;
    calls.push({
      name,
      input: stringifyJSON(block.arguments),
    });
  }
  return calls.length > 0 ? calls : undefined;
}

function isHeartbeatPrompt(text: string): boolean {
  const lower = text.toLowerCase();
  return (
    lower.includes('heartbeat.md') &&
    (lower.includes('read heartbeat.md') ||
      lower.includes('consider outstanding tasks'))
  );
}

function isNewSessionScaffold(text: string): boolean {
  const lower = text.toLowerCase();
  return (
    lower.includes('a new session was started via /new') ||
    lower.includes('via /new or /reset')
  );
}

function deriveOrigin(text: string): string {
  const lower = text.trim().toLowerCase();
  if (
    lower.startsWith('conversation info (untrusted metadata):') &&
    lower.includes('"sender_id"') &&
    lower.includes('sender (untrusted metadata):')
  ) {
    return 'telegram';
  }
  if (lower.startsWith('[telegram ') || lower.includes('\n[telegram '))
    return 'telegram';
  if (
    lower.startsWith('[cron:') ||
    lower.startsWith('[cron ') ||
    lower.includes('\n[cron:') ||
    lower.includes('\n[cron ')
  ) {
    return 'cron';
  }
  if (lower.startsWith('[whatsapp ') || lower.includes('\n[whatsapp '))
    return 'whatsapp';
  if (lower.startsWith('[discord ') || lower.includes('\n[discord '))
    return 'discord';
  if (lower.startsWith('[imessage ') || lower.includes('\n[imessage '))
    return 'imessage';
  if (lower.startsWith('[webchat ') || lower.includes('\n[webchat '))
    return 'webchat';
  return 'tui';
}

function agentIdFromPath(filePath: string): string {
  const parts = filePath.split('/');
  const agentsIdx = parts.lastIndexOf('agents');
  if (agentsIdx >= 0 && parts[agentsIdx + 1]) return parts[agentsIdx + 1];
  return 'default';
}

function sessionIdFromPath(filePath: string): string {
  const base = basename(filePath).replace(/\.jsonl(?:\.deleted\..*)?$/, '');
  return (
    base || createHash('sha256').update(filePath).digest('hex').slice(0, 16)
  );
}

export class OpenClawAdapter implements SessionAdapter {
  readonly name = 'openclaw' as const;
  private roots: string[];

  constructor(roots?: string[]) {
    const candidates = [
      process.env.OPENCLAW_STATE_DIR,
      join(homedir(), '.openclaw'),
      join(homedir(), '.clawdbot'),
    ].filter((v): v is string => Boolean(v));
    this.roots = roots ?? [...new Set(candidates)];
  }

  async detect(): Promise<boolean> {
    for (const root of this.roots) {
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
    for (const root of this.roots) {
      const agentsRoot = join(root, 'agents');
      let agents: string[];
      try {
        agents = await readdir(agentsRoot);
      } catch {
        continue;
      }
      for (const agent of agents) {
        const sessionsDir = join(agentsRoot, agent, 'sessions');
        let files: string[];
        try {
          files = await readdir(sessionsDir);
        } catch {
          continue;
        }
        for (const file of files) {
          if (file.includes('.jsonl')) {
            yield join(sessionsDir, file);
          }
        }
      }
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
      let toolCount = 0;
      let systemCount = 0;
      let firstUserText = '';
      let firstToolName = '';
      let origin: string | undefined;
      let sawHeartbeatPrompt = false;
      let sawNonHousekeepingUser = false;

      for await (const record of this.readRecords(filePath)) {
        const timestamp = toIsoTimestamp(
          record.timestamp ?? record.message?.['timestamp' as never],
        );
        if (timestamp) {
          if (!startTime || timestamp < startTime) startTime = timestamp;
          if (!endTime || timestamp > endTime) endTime = timestamp;
        }

        const type = normalizeKey(record.type);
        if (type === 'session') {
          if (!sessionId && record.id) sessionId = record.id;
          if (!cwd && record.cwd) cwd = record.cwd;
          continue;
        }
        if (type === 'modelchange') {
          if (!model && record.modelId) model = record.modelId;
          continue;
        }
        if (type !== 'message' || !record.message) continue;

        const role = normalizeKey(record.message.role);
        if (role === 'user') {
          const text = extractText(record.message.content);
          if (text) {
            if (isHeartbeatPrompt(text)) {
              sawHeartbeatPrompt = true;
              continue;
            }
            if (isNewSessionScaffold(text)) continue;
            sawNonHousekeepingUser = true;
            if (!origin) origin = deriveOrigin(text);
            if (!firstUserText) firstUserText = text;
          }
          userCount++;
        } else if (role === 'assistant') {
          assistantCount++;
          if (!model && record.message.model) model = record.message.model;
          const toolCalls = extractToolCalls(record.message.content);
          toolCount += toolCalls?.length ?? 0;
          if (!firstToolName && toolCalls?.[0]?.name)
            firstToolName = toolCalls[0].name;
        } else if (role === 'toolresult') {
          toolCount++;
          firstToolName ||=
            record.message.toolName ?? record.message.tool_name ?? '';
        } else if (role) {
          systemCount++;
        }
      }

      const baseId = sessionId || sessionIdFromPath(filePath);
      const summary = firstUserText || firstToolName || undefined;
      const isHousekeeping = !sawNonHousekeepingUser && sawHeartbeatPrompt;
      return {
        id: `openclaw:${agentIdFromPath(filePath)}:${baseId}`,
        source: 'openclaw',
        startTime: startTime || new Date(fileStat.mtimeMs).toISOString(),
        endTime: endTime && endTime !== startTime ? endTime : undefined,
        cwd,
        project: origin ?? 'system',
        model,
        messageCount: userCount + assistantCount + toolCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: toolCount,
        systemMessageCount: systemCount,
        summary: summary?.slice(0, 200),
        filePath,
        sizeBytes: fileStat.size,
        agentRole: isHousekeeping ? 'housekeeping' : undefined,
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

    for await (const record of this.readRecords(filePath)) {
      if (yielded >= limit) break;
      if (normalizeKey(record.type) !== 'message' || !record.message) continue;

      const roleKey = normalizeKey(record.message.role);
      let role: Message['role'];
      if (roleKey === 'user') role = 'user';
      else if (roleKey === 'assistant') role = 'assistant';
      else if (roleKey === 'toolresult') role = 'tool';
      else continue;

      const content = extractText(record.message.content);
      const toolCalls =
        role === 'assistant'
          ? extractToolCalls(record.message.content)
          : undefined;
      if (!content && !toolCalls?.length) continue;
      if (count < offset) {
        count++;
        continue;
      }
      count++;

      yield {
        role,
        content: content || `[${roleKey}]`,
        timestamp: toIsoTimestamp(record.timestamp),
        toolCalls,
      };
      yielded++;
    }
  }

  private async *readRecords(filePath: string): AsyncGenerator<OpenClawRecord> {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    for await (const line of rl) {
      if (!line.trim()) continue;
      try {
        yield JSON.parse(line) as OpenClawRecord;
      } catch {
        // skip malformed lines
      }
    }
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}
