// src/adapters/types.ts

export const SOURCE_NAMES = [
  'codex',
  'claude-code',
  'grok',
  'copilot',
  'pi',
  'gemini-cli',
  'opencode',
  'iflow',
  'qwen',
  'qoder',
  'kimi',
  'minimax',
  'mimo',
  'doubao',
  'glm',
  'deepseek',
  'lobsterai',
  'commandcode',
  'cline',
  'cursor',
  'vscode',
  'antigravity',
  'windsurf',
] as const;

export type SourceName = (typeof SOURCE_NAMES)[number];

export interface SessionInfo {
  id: string;
  source: SourceName;
  startTime: string; // ISO 8601
  endTime?: string;
  cwd: string;
  project?: string; // 解析后的项目名
  model?: string;
  messageCount: number; // user + assistant + tool (no system)
  userMessageCount: number;
  assistantMessageCount: number;
  toolMessageCount: number;
  systemMessageCount: number;
  summary?: string; // 首条用户消息文本（截断到 200 字符）
  filePath: string; // 原始文件路径（用于流式读取消息）
  sizeBytes: number;
  indexedAt?: string; // ISO 8601 — when this session was last indexed (set by DB)
  agentRole?: string; // e.g. "worker" | "awaiter" for Codex; "subagent" for claude-code
  originator?: string; // e.g. "Claude Code" — the tool that launched this session
  origin?: string; // machine/device identifier for sync (default: 'local')
  summaryMessageCount?: number; // message count at last summary generation (for auto-refresh)
  tier?: string; // session tier: 'skip' | 'lite' | 'normal' | 'premium'
  qualityScore?: number; // 0-100 quality score based on session heuristics
  parentSessionId?: string;
  suggestedParentId?: string;
}

export interface ToolCall {
  name: string;
  input?: string;
  output?: string;
}

export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
}

export interface Message {
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  timestamp?: string;
  toolCalls?: ToolCall[];
  usage?: TokenUsage;
}

export interface StreamMessagesOptions {
  offset?: number; // 跳过前 N 条消息
  limit?: number; // 最多返回 N 条消息
}

export interface SessionAdapter {
  readonly name: SourceName;
  detect(): Promise<boolean>;
  listSessionFiles(): AsyncGenerator<string>;
  parseSessionInfo(filePath: string): Promise<SessionInfo | null>;
  streamMessages(
    filePath: string,
    opts?: StreamMessagesOptions,
  ): AsyncGenerator<Message>;
  /**
   * Check whether a locator is still accessible (file exists, virtual path resolvable, etc.).
   * Orphan-scanner entry point. Default behaviour for real file paths: fs.stat; adapters that
   * store virtual locators (opencode, cursor) must override with source-specific checks.
   */
  isAccessible(locator: string): Promise<boolean>;
  /**
   * Optional: whether this adapter owns the given locator. Implemented by
   * adapters that can share a `name`/source with a sibling (e.g. the
   * `~/.claude-<provider>` provider-root ClaudeCodeAdapters share a source with
   * the native provider adapters). Used by locator-aware resolution so a session
   * is parsed by the adapter that actually produced its on-disk file rather than
   * whichever same-source adapter was registered first/last. Mirrors Swift's
   * `LocatorOwningSessionAdapter`.
   */
  ownsLocator?(locator: string): boolean;
}

/**
 * Pick the adapter that should handle `locator` among all adapters sharing
 * `source`. Mirrors Swift `SessionAdapterFactory.adapter(for:locator:)`:
 *   1. If a single adapter has the source, use it.
 *   2. Prefer an adapter that positively owns the locator.
 *   3. Otherwise fall back to the first adapter that does NOT explicitly disown
 *      it (an adapter without `ownsLocator`, or one whose `ownsLocator` is true).
 *      This keeps resolution order-independent, so a provider-root clone can
 *      never capture a native locator merely by registration order.
 *   4. Otherwise fall back to the first same-source adapter.
 */
export function resolveAdapterForLocator(
  adapters: SessionAdapter[],
  source: string,
  locator: string,
): SessionAdapter | undefined {
  const candidates = adapters.filter((a) => a.name === source);
  if (candidates.length <= 1) return candidates[0];

  const owner = candidates.find((a) => a.ownsLocator?.(locator) === true);
  if (owner) return owner;

  const fallback = candidates.find(
    (a) => typeof a.ownsLocator !== 'function' || a.ownsLocator(locator),
  );
  return fallback ?? candidates[0];
}
