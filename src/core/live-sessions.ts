import { closeSync, openSync, readdirSync, readSync, statSync } from 'node:fs';
import { extname, join } from 'node:path';
import type { SourceName } from '../adapters/types.js';

export type ActivityLevel = 'active' | 'idle' | 'recent';

export interface LiveSession {
  source: SourceName;
  sessionId?: string;
  project?: string;
  title?: string;
  cwd: string;
  filePath: string;
  startedAt: string;
  model?: string;
  currentActivity?: string;
  lastModifiedAt: string;
  activityLevel: ActivityLevel;
}

export interface WatchDir {
  path: string;
  source: SourceName;
}

// Activity level thresholds
const ACTIVE_MS = 15 * 60 * 1000; // 15 min → green (active)
const IDLE_MS = 8 * 3600 * 1000; // 8 hours → yellow (idle)
const RECENT_MS = 48 * 3600 * 1000; // 48 hours → gray (recent)

export interface LiveSessionMonitorOptions {
  watchDirs: WatchDir[];
  stalenessMs?: number; // default 48 hours
}

interface SessionMetadata {
  sessionId?: string;
  cwd: string;
  startedAt: string;
  title?: string;
}

export class LiveSessionMonitor {
  private sessions: Map<string, LiveSession> = new Map();
  private metadataCache: Map<string, SessionMetadata> = new Map();
  private interval: ReturnType<typeof setInterval> | null = null;
  private watchDirs: WatchDir[];
  private stalenessMs: number;

  constructor(opts: LiveSessionMonitorOptions) {
    this.watchDirs = opts.watchDirs;
    this.stalenessMs = opts.stalenessMs ?? RECENT_MS;
  }

  start(intervalMs = 5000): void {
    if (this.interval) return;
    this.interval = setInterval(() => this.scan().catch(() => {}), intervalMs); // intentional: periodic scan, file I/O errors are expected
    this.scan().catch(() => {}); // intentional: initial scan, file I/O errors are expected
  }

  stop(): void {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
  }

  isRunning(): boolean {
    return this.interval !== null;
  }

  getSessions(): LiveSession[] {
    return [...this.sessions.values()];
  }

  async scan(): Promise<void> {
    const now = Date.now();
    const found = new Set<string>();

    for (const { path: watchDir, source } of this.watchDirs) {
      try {
        const files = this.findJsonlFiles(watchDir);
        for (const filePath of files) {
          try {
            const st = statSync(filePath);
            const mtimeMs = st.mtimeMs;
            if (now - mtimeMs > this.stalenessMs) continue; // stale

            found.add(filePath);
            const existing = this.sessions.get(filePath);
            if (
              existing &&
              existing.lastModifiedAt === new Date(mtimeMs).toISOString()
            )
              continue;

            // Parse session metadata from file
            const session = this.parseSessionFile(
              filePath,
              source,
              mtimeMs,
              st.size,
            );
            if (session) {
              this.sessions.set(filePath, session);
            }
          } catch {
            /* intentional: skip unreadable files */
          }
        }
      } catch {
        /* intentional: skip inaccessible directories */
      }
    }

    // Remove sessions whose files are no longer active
    for (const key of this.sessions.keys()) {
      if (!found.has(key)) {
        this.sessions.delete(key);
        this.metadataCache.delete(key);
      }
    }
  }

  private findJsonlFiles(dir: string): string[] {
    const results: string[] = [];
    try {
      this.walkDir(dir, results, 0);
    } catch {
      /* intentional: directory may not exist */
    }
    return results;
  }

  private walkDir(dir: string, results: string[], depth: number): void {
    if (depth > 5) return; // safety limit
    try {
      const entries = readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) {
          this.walkDir(full, results, depth + 1);
        } else if (entry.isFile() && extname(entry.name) === '.jsonl') {
          results.push(full);
        }
      }
    } catch {
      /* intentional: skip unreadable dirs */
    }
  }

  /** Read at most `bytes` from the start of a file. */
  private readHead(filePath: string, bytes: number): string {
    const fd = openSync(filePath, 'r');
    try {
      const buf = Buffer.alloc(bytes);
      const bytesRead = readSync(fd, buf, 0, bytes, 0);
      return buf.toString('utf-8', 0, bytesRead);
    } finally {
      closeSync(fd);
    }
  }

  /** Read at most `bytes` from the end of a file, given its size. */
  private readTail(filePath: string, fileSize: number, bytes: number): string {
    const fd = openSync(filePath, 'r');
    try {
      const readSize = Math.min(bytes, fileSize);
      const offset = Math.max(0, fileSize - readSize);
      const buf = Buffer.alloc(readSize);
      const bytesRead = readSync(fd, buf, 0, readSize, offset);
      return buf.toString('utf-8', 0, bytesRead);
    } finally {
      closeSync(fd);
    }
  }

  private parseSessionFile(
    filePath: string,
    source: SourceName,
    mtimeMs: number,
    fileSize: number,
  ): LiveSession | null {
    try {
      // --- First-line metadata (cached; session metadata never changes) ---
      let meta = this.metadataCache.get(filePath);
      // Re-parse if cached metadata has empty cwd (codex fix: payload.cwd)
      if (meta && meta.cwd === '') meta = undefined;
      if (!meta) {
        // Codex first lines can be 15KB+ (includes base_instructions), read enough
        const head = this.readHead(filePath, 32768);
        const firstLineEnd = head.indexOf('\n');
        const firstLine =
          firstLineEnd >= 0 ? head.slice(0, firstLineEnd) : head;
        if (!firstLine) return null;

        meta = { sessionId: undefined, cwd: '', startedAt: '' };
        try {
          const first = JSON.parse(firstLine);
          // Claude Code: top-level sessionId/cwd/timestamp
          // Codex: payload.id/payload.cwd/payload.timestamp
          meta.sessionId = first.sessionId ?? first.payload?.id;
          meta.cwd = first.cwd ?? first.payload?.cwd ?? '';
          meta.startedAt = first.timestamp ?? first.payload?.timestamp ?? '';
        } catch {
          /* intentional: skip unparseable first line */
        }

        // Extract title from first user message in the head
        const headLines = head.split('\n').filter(Boolean);
        for (let i = 0; i < Math.min(headLines.length, 15); i++) {
          try {
            const line = JSON.parse(headLines[i]);
            // Claude Code: role=user at top level or message.role=user
            // Codex: type=event_msg, payload.type=user_message, payload.message=text
            const isUser =
              line.role === 'user' ||
              line.message?.role === 'user' ||
              (line.type === 'event_msg' &&
                line.payload?.type === 'user_message');
            if (isUser) {
              const text =
                typeof line.content === 'string'
                  ? line.content
                  : typeof line.message?.content === 'string'
                    ? line.message.content
                    : typeof line.payload?.message === 'string'
                      ? line.payload.message
                      : '';
              // Skip system-like content that gets classified as user messages
              if (
                text &&
                !text.startsWith('<') &&
                !text.startsWith('//') &&
                text.length > 5
              ) {
                meta.title = text.replace(/\s+/g, ' ').trim().slice(0, 60);
                break;
              }
            }
          } catch {
            /* intentional: skip unparseable title lines */
          }
        }

        this.metadataCache.set(filePath, meta);
      }

      // --- Tail: last 8KB for current activity + model ---
      let model: string | undefined;
      let currentActivity: string | undefined;

      const tail = this.readTail(filePath, fileSize, 8192);
      const tailLines = tail.split('\n').filter(Boolean);
      // First partial line may be truncated — start from the second if tail was truncated
      const startIdx = fileSize > 8192 && tailLines.length > 0 ? 1 : 0;
      for (let i = tailLines.length - 1; i >= startIdx; i--) {
        try {
          const line = JSON.parse(tailLines[i]);
          if (!model && line.message?.model) {
            model = line.message.model;
          }
          if (!currentActivity && line.type === 'assistant') {
            const content = line.message?.content;
            if (Array.isArray(content)) {
              const toolUse = [...content]
                .reverse()
                .find((c: any) => c.type === 'tool_use');
              if (toolUse) {
                const input = toolUse.input;
                const target =
                  input?.file_path || input?.command || input?.pattern || '';
                currentActivity = target
                  ? `${toolUse.name} ${String(target).slice(0, 80)}`
                  : toolUse.name;
              }
            }
          }
          if (model && currentActivity) break;
        } catch {
          /* intentional: skip unparseable tail lines */
        }
      }

      // Derive project from cwd or file path
      let project: string | undefined;
      if (meta.cwd) {
        project = meta.cwd.split('/').pop();
      } else {
        // Try to extract from claude-code path: ~/.claude/projects/-Users-bing--Code--foo/SESSION.jsonl
        project = this.projectFromPath(filePath);
      }

      const ageMs = Date.now() - mtimeMs;
      const activityLevel: ActivityLevel =
        ageMs <= ACTIVE_MS ? 'active' : ageMs <= IDLE_MS ? 'idle' : 'recent';

      return {
        source,
        sessionId: meta.sessionId,
        project,
        title: meta.title,
        cwd: meta.cwd,
        filePath,
        startedAt: meta.startedAt,
        model,
        currentActivity,
        lastModifiedAt: new Date(mtimeMs).toISOString(),
        activityLevel,
      };
    } catch {
      return null; // intentional: skip files that can't be parsed
    }
  }

  /** Extract project name from claude-code path like ~/.claude/projects/-Users-bing--Code--foo/SESSION.jsonl */
  private projectFromPath(filePath: string): string | undefined {
    const match = filePath.match(/\.claude\/projects\/([^/]+)\//);
    if (!match) return undefined;
    const encoded = match[1];
    if (encoded === '-') return undefined; // global session, no project
    // Decode: -Users-bing--Code--foo → /Users/bing/-Code-/foo → last segment = "foo"
    const decoded = encoded
      .replace(/^-/, '/')
      .replace(/--/g, '§')
      .replace(/-/g, '/')
      .replace(/§/g, '-');
    return decoded.split('/').pop() || undefined;
  }
}
