// src/adapters/types.ts

export type SourceName = 'codex' | 'claude-code' | 'copilot' | 'gemini-cli' | 'opencode' | 'iflow' | 'qwen' | 'kimi' | 'minimax' | 'lobsterai' | 'cline' | 'cursor' | 'vscode' | 'antigravity' | 'windsurf'

export interface SessionInfo {
  id: string
  source: SourceName
  startTime: string       // ISO 8601
  endTime?: string
  cwd: string
  project?: string        // 解析后的项目名
  model?: string
  messageCount: number          // user + assistant + tool (no system)
  userMessageCount: number
  assistantMessageCount: number
  toolMessageCount: number
  systemMessageCount: number
  summary?: string        // 首条用户消息文本（截断到 200 字符）
  filePath: string        // 原始文件路径（用于流式读取消息）
  sizeBytes: number
  indexedAt?: string      // ISO 8601 — when this session was last indexed (set by DB)
  agentRole?: string      // e.g. "worker" | "awaiter" for Codex; "subagent" for claude-code
  origin?: string         // machine/device identifier for sync (default: 'local')
  summaryMessageCount?: number  // message count at last summary generation (for auto-refresh)
  tier?: string           // session tier: 'skip' | 'lite' | 'normal' | 'premium'
  qualityScore?: number   // 0-100 quality score based on session heuristics
}

export interface ToolCall {
  name: string
  input?: string
  output?: string
}

export interface TokenUsage {
  inputTokens: number
  outputTokens: number
  cacheReadTokens?: number
  cacheCreationTokens?: number
}

export interface Message {
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp?: string
  toolCalls?: ToolCall[]
  usage?: TokenUsage
}

export interface StreamMessagesOptions {
  offset?: number   // 跳过前 N 条消息
  limit?: number    // 最多返回 N 条消息
}

export interface SessionAdapter {
  readonly name: SourceName
  detect(): Promise<boolean>
  listSessionFiles(): AsyncGenerator<string>
  parseSessionInfo(filePath: string): Promise<SessionInfo | null>
  streamMessages(filePath: string, opts?: StreamMessagesOptions): AsyncGenerator<Message>
}
