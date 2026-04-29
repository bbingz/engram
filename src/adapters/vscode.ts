// src/adapters/vscode.ts
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { isFileAccessible } from './_accessible.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
} from './types.js';

interface VsRequest {
  requestId: string;
  message: { text?: string; parts?: { kind: string; value: string }[] };
  response: { value: { kind: string; content?: { value: string } } }[];
  timestamp?: number;
}

interface VsSessionData {
  version: number;
  sessionId: string;
  creationDate: number;
  requests: VsRequest[];
}

interface VsLine0 {
  kind: 0;
  v: VsSessionData;
}

export class VsCodeAdapter implements SessionAdapter {
  readonly name = 'vscode' as const;
  private workspaceStorageDir: string;

  constructor(workspaceStorageDir?: string) {
    this.workspaceStorageDir =
      workspaceStorageDir ??
      join(
        homedir(),
        'Library',
        'Application Support',
        'Code',
        'User',
        'workspaceStorage',
      );
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.workspaceStorageDir);
      return true;
    } catch {
      return false;
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const workspaces = await readdir(this.workspaceStorageDir, {
        withFileTypes: true,
      });
      workspaces.sort((a, b) => a.name.localeCompare(b.name));
      for (const workspace of workspaces) {
        if (!workspace.isDirectory()) continue;
        const chatDir = join(
          this.workspaceStorageDir,
          workspace.name,
          'chatSessions',
        );
        const files = await readdir(chatDir, { withFileTypes: true }).catch(
          () => [],
        );
        files.sort((a, b) => a.name.localeCompare(b.name));
        for (const file of files) {
          if (file.isFile() && file.name.endsWith('.jsonl')) {
            yield join(chatDir, file.name);
          }
        }
      }
    } catch {
      /* dir not found */
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      const session = await this.readSession(filePath);
      if (!session || session.requests.length === 0) return null;

      const userMessages = session.requests
        .map((r) => this.extractUserText(r))
        .filter(Boolean);
      // Some response kinds (progressTask, toolUse) carry no markdown text;
      // count only requests that yield real assistant content.
      const assistantTexts = session.requests
        .map((r) => this.extractAssistantText(r))
        .filter(Boolean);
      const lastReq = session.requests[session.requests.length - 1];
      const userMessageCount = userMessages.length;
      const assistantMessageCount = assistantTexts.length;
      const cwd = await this.readWorkspaceCwd(filePath);

      return {
        id: session.sessionId || basename(filePath, '.jsonl'),
        source: 'vscode',
        startTime: new Date(session.creationDate).toISOString(),
        endTime:
          lastReq.timestamp && lastReq.timestamp !== session.creationDate
            ? new Date(lastReq.timestamp).toISOString()
            : undefined,
        cwd,
        messageCount: userMessageCount + assistantMessageCount,
        userMessageCount,
        assistantMessageCount,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: userMessages[0]?.slice(0, 200),
        filePath,
        sizeBytes: fileStat.size,
      };
    } catch {
      return null;
    }
  }

  // VS Code stores the workspace identity in workspaceStorage/<hash>/workspace.json
  // alongside the chatSessions/ folder. Two shapes:
  //   - single-folder: { "folder": "file:///path/to/proj" }
  //   - multi-root:    { "configuration": "file:///path/to/foo.code-workspace" }
  // For the latter, the configuration file itself is NOT a usable cwd — we
  // open it and pull folders[0].path (resolving relative paths against the
  // .code-workspace file's directory, per VS Code spec).
  private async readWorkspaceCwd(filePath: string): Promise<string> {
    try {
      const hashDir = dirname(dirname(filePath)); // .../<hash>/
      const wsJsonPath = join(hashDir, 'workspace.json');
      const raw = await readFile(wsJsonPath, 'utf8');
      const data = JSON.parse(raw) as {
        folder?: string;
        configuration?: string;
      };
      if (data.folder) return decodeFileUri(data.folder);
      if (data.configuration) {
        const wsFile = decodeFileUri(data.configuration);
        return await this.readCodeWorkspaceFirstFolder(wsFile);
      }
      return '';
    } catch {
      return '';
    }
  }

  private async readCodeWorkspaceFirstFolder(wsFile: string): Promise<string> {
    try {
      const raw = await readFile(wsFile, 'utf8');
      const ws = JSON.parse(raw) as {
        folders?: { path?: string; uri?: string }[];
      };
      const first = ws.folders?.[0];
      if (!first) return '';
      // VS Code accepts either { path } or { uri } per folder entry.
      if (first.uri) return decodeFileUri(first.uri);
      if (first.path) {
        // Absolute → use as-is. Relative → resolve against .code-workspace dir.
        return first.path.startsWith('/')
          ? first.path
          : join(dirname(wsFile), first.path);
      }
      return '';
    } catch {
      return '';
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

    try {
      const session = await this.readSession(filePath);
      if (!session) return;

      for (const req of session.requests) {
        // User message
        const userText = this.extractUserText(req);
        if (userText) {
          if (count >= offset && yielded < limit) {
            yield {
              role: 'user',
              content: userText,
              timestamp: req.timestamp
                ? new Date(req.timestamp).toISOString()
                : undefined,
            };
            yielded++;
          }
          count++;
        }

        // Assistant message
        const assistantText = this.extractAssistantText(req);
        if (assistantText) {
          if (count >= offset && yielded < limit) {
            yield {
              role: 'assistant',
              content: assistantText,
              timestamp: req.timestamp
                ? new Date(req.timestamp).toISOString()
                : undefined,
            };
            yielded++;
          }
          count++;
        }

        if (yielded >= limit) break;
      }
    } catch {
      /* file not readable */
    }
  }

  private async readSession(filePath: string): Promise<VsSessionData | null> {
    try {
      const content = await readFile(filePath, 'utf8');
      const firstLine = content.split('\n')[0]?.trim();
      if (!firstLine) return null;
      const parsed = JSON.parse(firstLine) as VsLine0;
      if (parsed.kind !== 0 || !parsed.v) return null;
      return parsed.v;
    } catch {
      return null;
    }
  }

  private extractUserText(req: VsRequest): string {
    if (req.message.text) return req.message.text;
    if (req.message.parts) {
      for (const p of req.message.parts) {
        if (p.kind === 'text' && p.value) return p.value;
      }
    }
    return '';
  }

  private extractAssistantText(req: VsRequest): string {
    for (const r of req.response) {
      if (r.value?.kind === 'markdownContent' && r.value.content?.value) {
        return r.value.content.value;
      }
    }
    return '';
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}

// Decode a file:// URI to a local path. Non-file URIs (vscode-remote://,
// vsls://, ...) and malformed percent-encoding both return '' — using a
// remote URI as cwd would be worse than no cwd at all.
function decodeFileUri(uri: string): string {
  if (!uri.startsWith('file://')) return '';
  let path = uri.slice('file://'.length);
  // Strip optional "localhost" authority — "file://localhost/path" → "/path".
  if (path.startsWith('localhost/')) path = path.slice('localhost'.length);
  try {
    return decodeURIComponent(path);
  } catch {
    return '';
  }
}
