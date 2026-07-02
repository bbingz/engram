import { createReadStream } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { isFileAccessible } from './_accessible.js';
import { truncateJSON, truncateString } from './_truncate.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  TokenUsage,
  ToolCall,
} from './types.js';

type JsonObject = Record<string, unknown>;

export class GrokAdapter implements SessionAdapter {
  readonly name = 'grok' as const;
  private sessionsRoot: string;

  constructor(sessionsRoot?: string) {
    this.sessionsRoot = sessionsRoot ?? join(homedir(), '.grok', 'sessions');
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
    try {
      const projects = await readdir(this.sessionsRoot, {
        withFileTypes: true,
      });
      projects.sort((a, b) => a.name.localeCompare(b.name));
      for (const project of projects) {
        if (!project.isDirectory()) continue;
        const projectDir = join(this.sessionsRoot, project.name);
        const sessions = await readdir(projectDir, { withFileTypes: true });
        sessions.sort((a, b) => a.name.localeCompare(b.name));
        for (const session of sessions) {
          if (!session.isDirectory()) continue;
          const locator = await this.preferredLocator(
            join(projectDir, session.name),
          );
          if (locator) yield locator;
        }
      }
    } catch {
      // sessions root does not exist
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const sessionDir = this.sessionDirectory(filePath);
      const transcript = await this.primaryTranscript(sessionDir, filePath);
      const fileStat = await stat(transcript);
      const summary = await this.readJSONObject(
        join(sessionDir, 'summary.json'),
      );
      const promptContext = await this.readJSONObject(
        join(sessionDir, 'prompt_context.json'),
      );
      const objects = await this.readObjects(transcript);
      const messages = objects
        .map((object) => this.messageFromObject(object))
        .filter((message): message is Message => message !== null);
      const counts = this.countMessages(messages);
      const systemCount = this.systemMessageCount(objects);
      const info = this.object(summary?.info);
      const id = this.string(info?.id) ?? sessionDir.split(/[\\/]+/).at(-1);
      if (!id) return null;

      const firstUserText = messages.find(
        (message) => message.role === 'user',
      )?.content;
      const summaryText =
        firstUserText ??
        this.string(summary?.session_summary) ??
        this.string(summary?.generated_title);

      return {
        id,
        source: 'grok',
        startTime:
          this.string(summary?.created_at) ??
          this.firstTimestamp(objects) ??
          new Date(fileStat.mtimeMs).toISOString(),
        endTime:
          this.string(summary?.updated_at) ?? this.lastTimestamp(objects),
        cwd:
          this.string(info?.cwd) ??
          this.string(promptContext?.working_directory) ??
          decodeURIComponent(sessionDir.split(/[\\/]+/).at(-2) ?? ''),
        model:
          this.string(summary?.current_model_id) ?? this.firstModel(objects),
        messageCount: counts.user + counts.assistant + counts.tool,
        userMessageCount: counts.user,
        assistantMessageCount: counts.assistant,
        toolMessageCount: counts.tool,
        systemMessageCount: systemCount,
        summary: summaryText ? truncateString(summaryText, 200) : undefined,
        filePath: transcript,
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
    const sessionDir = this.sessionDirectory(filePath);
    const transcript = await this.primaryTranscript(sessionDir, filePath);
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? Infinity;
    let count = 0;
    let yielded = 0;

    for await (const line of this.readLines(transcript)) {
      if (yielded >= limit) break;
      const object = this.parseLine(line);
      if (!object) continue;
      const message = this.messageFromObject(object);
      if (!message) continue;
      if (count < offset) {
        count++;
        continue;
      }
      count++;
      yield message;
      yielded++;
    }
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }

  private async preferredLocator(sessionDir: string): Promise<string | null> {
    for (const name of [
      'chat_history.jsonl',
      'updates.jsonl',
      'summary.json',
    ]) {
      const candidate = join(sessionDir, name);
      try {
        const fileStat = await stat(candidate);
        if (fileStat.isFile()) return candidate;
      } catch {
        // try next candidate
      }
    }
    return null;
  }

  private sessionDirectory(locator: string): string {
    if (
      locator.endsWith('/chat_history.jsonl') ||
      locator.endsWith('/updates.jsonl') ||
      locator.endsWith('/summary.json')
    ) {
      return locator.slice(0, locator.lastIndexOf('/'));
    }
    return locator;
  }

  private async primaryTranscript(
    sessionDir: string,
    locator: string,
  ): Promise<string> {
    if (
      locator.endsWith('/chat_history.jsonl') ||
      locator.endsWith('/updates.jsonl')
    ) {
      return locator;
    }
    for (const name of ['chat_history.jsonl', 'updates.jsonl']) {
      const candidate = join(sessionDir, name);
      try {
        const fileStat = await stat(candidate);
        if (fileStat.isFile()) return candidate;
      } catch {
        // try next candidate
      }
    }
    return locator;
  }

  private async readJSONObject(filePath: string): Promise<JsonObject | null> {
    try {
      const parsed = JSON.parse(await readFile(filePath, 'utf8')) as unknown;
      return this.object(parsed);
    } catch {
      return null;
    }
  }

  private async readObjects(filePath: string): Promise<JsonObject[]> {
    const objects: JsonObject[] = [];
    for await (const line of this.readLines(filePath)) {
      const object = this.parseLine(line);
      if (object) objects.push(object);
    }
    return objects;
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

  private parseLine(line: string): JsonObject | null {
    try {
      return this.object(JSON.parse(line) as unknown);
    } catch {
      return null;
    }
  }

  private messageFromObject(object: JsonObject): Message | null {
    const type = this.string(object.type);
    const timestamp =
      this.string(object.timestamp) ??
      this.string(object.created_at) ??
      this.string(object.createdAt);

    if (type === 'user') {
      const text = this.normalizeUserText(this.extractContent(object.content));
      return text ? { role: 'user', content: text, timestamp } : null;
    }
    if (type === 'assistant') {
      const content = this.extractContent(object.content).trim();
      const toolCalls = this.toolCalls(object.tool_calls);
      if (!content && toolCalls.length === 0) return null;
      const message: Message = { role: 'assistant', content, timestamp };
      if (toolCalls.length) message.toolCalls = toolCalls;
      const usage = this.usage(this.object(object.usage));
      if (usage) message.usage = usage;
      return message;
    }
    if (type === 'tool_result') {
      const content = this.extractContent(object.content).trim();
      return content ? { role: 'tool', content, timestamp } : null;
    }
    return null;
  }

  private countMessages(messages: Message[]): {
    user: number;
    assistant: number;
    tool: number;
  } {
    return messages.reduce(
      (counts, message) => {
        if (message.role === 'user') counts.user++;
        else if (message.role === 'assistant') counts.assistant++;
        else if (message.role === 'tool') counts.tool++;
        return counts;
      },
      { user: 0, assistant: 0, tool: 0 },
    );
  }

  private systemMessageCount(objects: JsonObject[]): number {
    let count = 0;
    for (const object of objects) {
      const type = this.string(object.type);
      if (type === 'system') count++;
      else if (
        type === 'user' &&
        this.isSystemInjection(this.extractContent(object.content))
      ) {
        count++;
      }
    }
    return count;
  }

  private normalizeUserText(text: string): string | null {
    const trimmed = text.trim();
    if (!trimmed || this.isSystemInjection(trimmed)) return null;
    if (!trimmed.startsWith('<user_query>')) return trimmed;
    const body = trimmed.slice('<user_query>'.length);
    const close = body.lastIndexOf('</user_query>');
    return (close >= 0 ? body.slice(0, close) : body).trim();
  }

  private isSystemInjection(text: string): boolean {
    const trimmed = text.trim();
    return (
      trimmed.startsWith('<user_info>') ||
      trimmed.startsWith('<system-reminder>') ||
      trimmed.startsWith('<codex_internal_context') ||
      trimmed.startsWith('# AGENTS.md instructions for ') ||
      trimmed.startsWith('<INSTRUCTIONS>') ||
      trimmed.startsWith('<environment_context>')
    );
  }

  private extractContent(value: unknown): string {
    if (typeof value === 'string') return value;
    if (Array.isArray(value)) {
      const parts: string[] = [];
      for (const item of value) {
        if (typeof item === 'string' && item) {
          parts.push(item);
        } else {
          const object = this.object(item);
          const text = object ? this.extractText(object) : undefined;
          if (text) parts.push(text);
        }
      }
      return parts.join('\n\n');
    }
    const object = this.object(value);
    if (!object) return '';
    return this.extractText(object) ?? truncateJSON(object, 2_000) ?? '';
  }

  private extractText(object: JsonObject): string | undefined {
    for (const key of [
      'text',
      'input_text',
      'output_text',
      'content',
      'message',
    ]) {
      const value = object[key];
      if (typeof value === 'string' && value) return value;
    }
    return undefined;
  }

  private toolCalls(value: unknown): ToolCall[] {
    if (!Array.isArray(value)) return [];
    const calls: ToolCall[] = [];
    for (const item of value) {
      const object = this.object(item);
      if (!object) continue;
      const fn = this.object(object.function);
      const name = this.string(object.name) ?? this.string(fn?.name);
      if (!name) continue;
      const input =
        this.stringOrJSON(object.arguments) ??
        this.stringOrJSON(fn?.arguments) ??
        this.stringOrJSON(object.rawInput) ??
        this.stringOrJSON(object.input) ??
        this.stringOrJSON(object.args);
      calls.push({ name, input });
    }
    return calls;
  }

  private usage(raw: JsonObject | null): TokenUsage | undefined {
    if (!raw) return undefined;
    const inputTokens = this.number(raw.input_tokens ?? raw.inputTokens);
    const outputTokens = this.number(raw.output_tokens ?? raw.outputTokens);
    if (inputTokens === undefined && outputTokens === undefined)
      return undefined;
    return {
      inputTokens: inputTokens ?? 0,
      outputTokens: outputTokens ?? 0,
      cacheReadTokens: this.number(
        raw.cache_read_input_tokens ?? raw.cacheReadTokens,
      ),
      cacheCreationTokens: this.number(
        raw.cache_creation_input_tokens ?? raw.cacheCreationTokens,
      ),
    };
  }

  private firstTimestamp(objects: JsonObject[]): string | undefined {
    for (const object of objects) {
      const value =
        this.string(object.timestamp) ??
        this.string(object.created_at) ??
        this.string(object.createdAt);
      if (value) return value;
    }
    return undefined;
  }

  private lastTimestamp(objects: JsonObject[]): string | undefined {
    for (const object of [...objects].reverse()) {
      const value =
        this.string(object.timestamp) ??
        this.string(object.created_at) ??
        this.string(object.createdAt);
      if (value) return value;
    }
    return undefined;
  }

  private firstModel(objects: JsonObject[]): string | undefined {
    for (const object of objects) {
      const value = this.string(object.model_id) ?? this.string(object.model);
      if (value) return value;
    }
    return undefined;
  }

  private stringOrJSON(value: unknown): string | undefined {
    if (typeof value === 'string') return value || undefined;
    return truncateJSON(value, 500);
  }

  private object(value: unknown): JsonObject | null {
    return value && typeof value === 'object' && !Array.isArray(value)
      ? (value as JsonObject)
      : null;
  }

  private string(value: unknown): string | undefined {
    return typeof value === 'string' && value ? value : undefined;
  }

  private number(value: unknown): number | undefined {
    return typeof value === 'number' && Number.isFinite(value)
      ? value
      : undefined;
  }
}
