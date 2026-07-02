// src/adapters/gemini-cli.ts
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { isFileAccessible } from './_accessible.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
} from './types.js';

interface GeminiSession {
  sessionId: string;
  projectHash: string;
  startTime: string;
  lastUpdated?: string;
  summary?: string;
  messages: GeminiMessage[];
}

interface GeminiContentPart {
  text?: string;
}

interface GeminiMessage {
  id: string;
  timestamp: string;
  type: 'user' | 'gemini' | 'model' | 'info' | string;
  content: string | GeminiContentPart[];
  toolCalls?: unknown[];
}

const MAX_SESSION_JSON_BYTES = 10 * 1024 * 1024;

interface ProjectsCache {
  signature: string;
  map: Map<string, string>;
}

// Sidecars may write the originator in either Codex's "Claude Code" form or
// the plugin's "claude-code" slug. Normalize (lowercase, strip spaces/dashes)
// so the dispatched-role classification works regardless of which form the
// writer used — otherwise parent-link detection silently misses the session.
function isClaudeCodeOriginator(originator: string | undefined): boolean {
  if (!originator) return false;
  return originator.toLowerCase().replace(/[\s-]+/g, '') === 'claudecode';
}

function isConversation(m: GeminiMessage): boolean {
  return m.type === 'user' || m.type === 'gemini' || m.type === 'model';
}

function extractText(content: string | GeminiContentPart[]): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((p) => p.text ?? '')
      .filter(Boolean)
      .join('\n');
  }
  return '';
}

async function readJsonFileIfSmall<T>(filePath: string): Promise<T | null> {
  const fileStat = await stat(filePath);
  if (fileStat.size > MAX_SESSION_JSON_BYTES) return null;
  return JSON.parse(await readFile(filePath, 'utf8')) as T;
}

export class GeminiCliAdapter implements SessionAdapter {
  readonly name = 'gemini-cli' as const;
  private tmpRoot: string;
  private projectsFile: string;
  private projectsCache: ProjectsCache | null = null;

  constructor(tmpRoot?: string, projectsFile?: string) {
    this.tmpRoot = tmpRoot ?? join(homedir(), '.gemini', 'tmp');
    this.projectsFile =
      projectsFile ?? join(homedir(), '.gemini', 'projects.json');
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.tmpRoot);
      return true;
    } catch {
      return false;
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const projectDirs = await readdir(this.tmpRoot);
      for (const dir of projectDirs) {
        const chatsDir = join(this.tmpRoot, dir, 'chats');
        try {
          for await (const file of this.sessionFilesUnder(chatsDir)) {
            yield file;
          }
        } catch {
          // chats 目录不存在
        }
      }
    } catch {
      // tmpRoot 不存在
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      if (fileStat.size > MAX_SESSION_JSON_BYTES) return null;
      const session = await this.readSessionFile(filePath);
      if (!session) return null;

      const messageObjects = session.messages.filter(
        (m) => extractText(m.content) !== '',
      );
      const userMessages = messageObjects.filter((m) => m.type === 'user');
      const assistantMessages = messageObjects.filter(
        (m) => m.type === 'gemini' || m.type === 'model',
      );

      // 从文件路径提取 projectName：.../tmp/<projectName>/chats/<session>.json[l]
      const parts = filePath.split('/');
      const chatsIdx = parts.indexOf('chats');
      const projectName = chatsIdx > 0 ? parts[chatsIdx - 1] : '';
      const nativeParentSessionId =
        chatsIdx >= 0 && parts.length > chatsIdx + 2
          ? parts[chatsIdx + 1]
          : undefined;

      // Prefer Gemini CLI's native project root marker; older plugin-created
      // stores may still need the projects.json reverse map fallback.
      const cwd =
        (await this.resolveProjectRoot(projectName)) ??
        (await this.resolveProject(projectName)) ??
        projectName;

      const firstUserText = userMessages[0]
        ? extractText(userMessages[0].content)
        : undefined;

      // Try reading sidecar file written by gemini-plugin-cc for deterministic linking
      let parentSessionId: string | undefined;
      let originator: string | undefined;
      try {
        const sidecarPath = join(
          dirname(filePath),
          `${session.sessionId}.engram.json`,
        );
        const sidecar =
          await readJsonFileIfSmall<Record<string, unknown>>(sidecarPath);
        if (typeof sidecar?.parentSessionId === 'string') {
          parentSessionId = sidecar.parentSessionId;
        }
        if (typeof sidecar?.originator === 'string') {
          originator = sidecar.originator;
        }
      } catch {
        // No sidecar — fall through to heuristic detection
      }

      return {
        id: session.sessionId,
        source: 'gemini-cli',
        startTime: session.startTime,
        endTime: session.lastUpdated,
        cwd,
        project: projectName,
        messageCount: userMessages.length + assistantMessages.length,
        userMessageCount: userMessages.length,
        assistantMessageCount: assistantMessages.length,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: firstUserText?.slice(0, 200) || undefined,
        filePath,
        sizeBytes: fileStat.size,
        parentSessionId: parentSessionId ?? nativeParentSessionId,
        originator,
        agentRole: nativeParentSessionId
          ? 'subagent'
          : isClaudeCodeOriginator(originator)
            ? 'dispatched'
            : undefined,
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

    const fileStat = await stat(filePath);
    if (fileStat.size > MAX_SESSION_JSON_BYTES) return;

    const session = await this.readSessionFile(filePath);
    if (!session) return;

    const relevant = session.messages.filter(isConversation);
    const sliced = relevant.slice(
      offset,
      limit === Infinity ? undefined : offset + (limit as number),
    );

    for (const msg of sliced) {
      const text = extractText(msg.content);
      if (!text) continue;
      yield {
        role: msg.type === 'user' ? 'user' : 'assistant',
        content: text,
        timestamp: msg.timestamp,
      };
    }
  }

  // projectName → cwd（通过 projects.json 反查）
  async resolveProject(projectName: string): Promise<string | null> {
    const map = await this.loadProjects();
    for (const [cwd, name] of map.entries()) {
      if (name === projectName) return cwd;
    }
    return null;
  }

  private async resolveProjectRoot(
    projectName: string,
  ): Promise<string | null> {
    try {
      const root = await readFile(
        join(this.tmpRoot, projectName, '.project_root'),
        'utf8',
      );
      const trimmed = root.trim();
      return trimmed || null;
    } catch {
      return null;
    }
  }

  private async readSessionFile(
    filePath: string,
  ): Promise<GeminiSession | null> {
    const raw = await readFile(filePath, 'utf8');
    if (filePath.endsWith('.jsonl')) return replayJsonlSession(raw);
    return JSON.parse(raw) as GeminiSession;
  }

  private async *sessionFilesUnder(root: string): AsyncGenerator<string> {
    const entries = await readdir(root, { withFileTypes: true });
    for (const entry of entries) {
      const entryPath = join(root, entry.name);
      if (entry.isDirectory()) {
        yield* this.sessionFilesUnder(entryPath);
        continue;
      }
      if (
        entry.isFile() &&
        !entry.name.endsWith('.engram.json') &&
        (entry.name.endsWith('.json') || entry.name.endsWith('.jsonl'))
      ) {
        yield entryPath;
      }
    }
  }

  private async loadProjects(): Promise<Map<string, string>> {
    let signature = 'missing';
    try {
      const fileStat = await stat(this.projectsFile);
      signature = `${fileStat.size}:${fileStat.mtimeMs}:${fileStat.ctimeMs}`;
      if (this.projectsCache?.signature === signature) {
        return this.projectsCache.map;
      }
      if (fileStat.size > MAX_SESSION_JSON_BYTES) {
        const map = new Map<string, string>();
        this.projectsCache = { signature, map };
        return map;
      }

      const obj = JSON.parse(
        await readFile(this.projectsFile, 'utf8'),
      ) as Record<string, unknown>;
      // 支持 {"projects": {...}} 和直接 {...} 两种格式
      const projects = (obj.projects ?? obj) as Record<string, string>;
      const map = new Map(Object.entries(projects));
      this.projectsCache = { signature, map };
    } catch {
      if (this.projectsCache?.signature === signature) {
        return this.projectsCache.map;
      }
      const map = new Map<string, string>();
      this.projectsCache = { signature, map };
    }
    return this.projectsCache.map;
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}

function replayJsonlSession(raw: string): GeminiSession | null {
  const metadata: Partial<GeminiSession> = {};
  let messages: GeminiMessage[] = [];

  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const record = JSON.parse(trimmed) as Record<string, unknown>;
    const set = record.$set as Partial<GeminiSession> | undefined;
    if (set && typeof set === 'object') {
      Object.assign(metadata, set);
      if (Array.isArray(set.messages)) messages = set.messages;
      continue;
    }
    if (typeof record.$rewindTo === 'string') {
      const index = messages.findIndex(
        (message) => message.id === record.$rewindTo,
      );
      if (index >= 0) messages = messages.slice(0, index + 1);
      continue;
    }
    if (typeof record.type === 'string') {
      messages.push(record as unknown as GeminiMessage);
      continue;
    }
    Object.assign(metadata, record);
    if (Array.isArray(record.messages)) {
      messages = record.messages as GeminiMessage[];
    }
  }

  if (
    typeof metadata.sessionId !== 'string' ||
    typeof metadata.startTime !== 'string'
  ) {
    return null;
  }
  return {
    sessionId: metadata.sessionId,
    projectHash: metadata.projectHash ?? '',
    startTime: metadata.startTime,
    lastUpdated: metadata.lastUpdated,
    summary: metadata.summary,
    messages,
  };
}
