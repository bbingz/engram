// src/adapters/cline.ts
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { isFileAccessible } from './_accessible.js';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  StreamMessagesOptions,
  TokenUsage,
} from './types.js';

interface UiMessage {
  ts: number;
  type: string;
  say?: string;
  ask?: string;
  text?: string;
  partial?: boolean;
  modelInfo?: { providerId?: string; modelId?: string; mode?: string };
}

export class ClineAdapter implements SessionAdapter {
  readonly name = 'cline' as const;
  private tasksRoot: string;

  constructor(tasksRoot?: string) {
    this.tasksRoot = tasksRoot ?? join(homedir(), '.cline', 'data', 'tasks');
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.tasksRoot);
      return true;
    } catch {
      return false;
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const taskDirs = await readdir(this.tasksRoot);
      for (const dir of taskDirs) {
        const uiPath = join(this.tasksRoot, dir, 'ui_messages.json');
        try {
          await stat(uiPath);
          yield uiPath;
          continue;
        } catch {
          /* skip */
        }
        const legacyPath = join(this.tasksRoot, dir, 'claude_messages.json');
        try {
          await stat(legacyPath);
          yield legacyPath;
        } catch {
          /* skip */
        }
      }
    } catch {
      /* tasksRoot missing */
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath);
      const taskId = basename(dirname(filePath));
      const msgs = await this.loadMessages(filePath);
      if (msgs.length === 0) return null;

      const firstMsg = msgs[0];
      const lastMsg = msgs[msgs.length - 1];
      const taskMsg = msgs.find((m) => m.say === 'task');
      const summary = taskMsg?.text?.slice(0, 200);
      const cwd = this.extractCwd(msgs);
      const model = msgs.find((m) => m.modelInfo?.modelId)?.modelInfo?.modelId;

      const userMsgs = msgs.filter(
        (m) => m.say === 'task' || m.say === 'user_feedback',
      );
      const assistantMsgs = msgs.filter((m) => m.say === 'text' && !m.partial);

      return {
        id: taskId,
        source: 'cline',
        startTime: new Date(firstMsg.ts).toISOString(),
        endTime:
          lastMsg.ts !== firstMsg.ts
            ? new Date(lastMsg.ts).toISOString()
            : undefined,
        cwd,
        model,
        messageCount: userMsgs.length + assistantMsgs.length,
        userMessageCount: userMsgs.length,
        assistantMessageCount: assistantMsgs.length,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary,
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
    const offset = opts.offset ?? 0;
    const limit = opts.limit ?? Infinity;
    const msgs = await this.loadMessages(filePath);
    let pendingUsage: TokenUsage | undefined;
    let count = 0;
    let yielded = 0;
    for (const m of msgs) {
      if (yielded >= limit) break;
      if (m.say === 'api_req_started') {
        const usage = this.apiRequestUsage(m);
        if (usage) {
          pendingUsage = {
            inputTokens: (pendingUsage?.inputTokens ?? 0) + usage.inputTokens,
            outputTokens:
              (pendingUsage?.outputTokens ?? 0) + usage.outputTokens,
            cacheReadTokens:
              (pendingUsage?.cacheReadTokens ?? 0) +
              (usage.cacheReadTokens ?? 0),
            cacheCreationTokens:
              (pendingUsage?.cacheCreationTokens ?? 0) +
              (usage.cacheCreationTokens ?? 0),
          };
        }
        continue;
      }
      if (
        m.say !== 'task' &&
        m.say !== 'user_feedback' &&
        !(m.say === 'text' && !m.partial)
      )
        continue;
      const role: 'user' | 'assistant' =
        m.say === 'task' || m.say === 'user_feedback' ? 'user' : 'assistant';
      const usage = role === 'assistant' ? pendingUsage : undefined;
      if (role === 'assistant') pendingUsage = undefined;
      if (count < offset) {
        count++;
        continue;
      }
      count++;
      yield {
        role,
        content: m.text ?? '',
        timestamp: new Date(m.ts).toISOString(),
        usage,
      };
      yielded++;
    }
  }

  private async loadMessages(filePath: string): Promise<UiMessage[]> {
    try {
      const raw = await readFile(filePath, 'utf8');
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? (parsed as UiMessage[]) : [];
    } catch {
      return [];
    }
  }

  private extractCwd(msgs: UiMessage[]): string {
    for (const m of msgs) {
      if (m.say !== 'api_req_started' || !m.text) continue;
      try {
        const inner = JSON.parse(m.text) as { request?: string };
        // Cline writes "Current Working Directory (<path>) Files ...". A path
        // can itself contain ')', so anchor on the "\) Files" suffix and match
        // the path greedily up to it instead of stopping at the first ')'.
        const request = inner.request ?? '';
        const match =
          request.match(/Current Working Directory \((.+?)\) Files/s) ??
          request.match(/Current Working Directory \(([^)]+)\)/);
        if (match) {
          const cwd = match[1];
          return cwd.startsWith('Primary: ') ? '' : cwd;
        }
      } catch {
        /* skip */
      }
    }
    return '';
  }

  private apiRequestUsage(message: UiMessage): TokenUsage | undefined {
    if (!message.text) return undefined;
    try {
      const parsed = JSON.parse(message.text) as {
        tokensIn?: unknown;
        tokensOut?: unknown;
      };
      const usage = {
        inputTokens: this.int(parsed.tokensIn),
        outputTokens: this.int(parsed.tokensOut),
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
      };
      if (usage.inputTokens === 0 && usage.outputTokens === 0) return undefined;
      return usage;
    } catch {
      return undefined;
    }
  }

  private int(value: unknown): number {
    return typeof value === 'number' && Number.isFinite(value)
      ? Math.trunc(value)
      : 0;
  }

  async isAccessible(locator: string): Promise<boolean> {
    return isFileAccessible(locator);
  }
}
