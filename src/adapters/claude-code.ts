// src/adapters/claude-code.ts
import { createReadStream } from 'fs'
import { stat, readdir } from 'fs/promises'
import { createInterface } from 'readline'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

export class ClaudeCodeAdapter implements SessionAdapter {
  readonly name = 'claude-code' as const
  private projectsRoot: string

  constructor(projectsRoot?: string) {
    this.projectsRoot = projectsRoot ?? join(homedir(), '.claude', 'projects')
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.projectsRoot)
      return true
    } catch {
      return false
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const projectDirs = await readdir(this.projectsRoot)
      for (const dir of projectDirs) {
        const projectPath = join(this.projectsRoot, dir)
        try {
          const entries = await readdir(projectPath, { withFileTypes: true })
          for (const entry of entries) {
            if (entry.isFile() && entry.name.endsWith('.jsonl')) {
              yield join(projectPath, entry.name)
            } else if (entry.isDirectory()) {
              // UUID subdirectory — look for subagents/ inside it
              const subagentsPath = join(projectPath, entry.name, 'subagents')
              try {
                const subFiles = await readdir(subagentsPath)
                for (const file of subFiles) {
                  if (file.endsWith('.jsonl')) {
                    yield join(subagentsPath, file)
                  }
                }
              } catch {
                // no subagents dir, skip
              }
            }
          }
        } catch {
          // 跳过无法读取的目录
        }
      }
    } catch {
      // projectsRoot 不存在
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      let sessionId = ''
      let agentId = ''
      let cwd = ''
      let startTime = ''
      let endTime = ''
      let userCount = 0
      let assistantCount = 0
      let systemCount = 0
      let firstUserText = ''
      let detectedModel = ''

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line)
        if (!obj) continue

        const type = obj.type as string
        if (type !== 'user' && type !== 'assistant') continue

        if (!sessionId && obj.sessionId) sessionId = obj.sessionId as string
        if (!agentId && obj.agentId) agentId = obj.agentId as string
        if (!cwd && obj.cwd) cwd = obj.cwd as string
        if (!startTime && obj.timestamp) startTime = obj.timestamp as string
        if (obj.timestamp) endTime = obj.timestamp as string

        const msg = obj.message as Record<string, unknown> | undefined
        if (!detectedModel && msg?.model) {
          detectedModel = msg.model as string
        }

        if (type === 'assistant') {
          assistantCount++
        } else if (type === 'user') {
          if (this.isToolResult(msg?.content)) {
            assistantCount++ // tool results are machine-generated, count with assistant
          } else {
            const text = this.extractContent(msg?.content)
            if (this.isSystemInjection(text)) {
              systemCount++
            } else {
              userCount++
              if (!firstUserText) {
                firstUserText = text
              }
            }
          }
        }
      }

      if (!sessionId) return null

      const isSubagent = filePath.includes('/subagents/')
      // Subagent files share sessionId with the parent — use agentId as the unique DB key
      const id = isSubagent && agentId ? agentId : sessionId
      const source = ClaudeCodeAdapter.detectSource(detectedModel, filePath)

      return {
        id,
        source,
        startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd,
        model: detectedModel || undefined,
        messageCount: userCount + assistantCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        systemMessageCount: systemCount,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath,
        sizeBytes: fileStat.size,
        agentRole: isSubagent ? 'subagent' : undefined,
      }
    } catch {
      return null
    }
  }

  /** Map model string + file path to source name. Non-Claude models get their own source. */
  static detectSource(model: string, filePath?: string): SessionInfo['source'] {
    // Lobster AI writes to ~/.claude/projects/ with its own project dirs
    if (filePath && filePath.includes('lobsterai')) return 'lobsterai'
    if (!model || model.startsWith('claude') || model.startsWith('<')) return 'claude-code'
    const m = model.toLowerCase()
    if (m.includes('qwen')) return 'qwen'
    if (m.includes('kimi')) return 'kimi'
    if (m.includes('gemini')) return 'gemini-cli'
    if (m.includes('minimax')) return 'minimax'
    // Unknown non-Claude model — still file is in ~/.claude, keep as claude-code
    return 'claude-code'
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity
    let count = 0
    let yielded = 0

    for await (const line of this.readLines(filePath)) {
      if (yielded >= limit) break
      const obj = this.parseLine(line)
      if (!obj) continue

      const type = obj.type as string
      if (type !== 'user' && type !== 'assistant') continue

      if (count < offset) { count++; continue }
      count++

      const msg = obj.message as Record<string, unknown>
      yield {
        role: type as 'user' | 'assistant',
        content: this.extractContent(msg?.content),
        timestamp: obj.timestamp as string | undefined,
      }
      yielded++
    }
  }

  private isSystemInjection(text: string): boolean {
    return (
      text.startsWith('# AGENTS.md instructions for ') ||
      text.includes('<INSTRUCTIONS>') ||
      text.startsWith('<local-command-caveat>') ||
      text.startsWith('<local-command-stdout>') ||
      text.includes('<command-name>') ||
      text.includes('<command-message>') ||
      text.startsWith('Unknown skill: ') ||
      text.startsWith('Invoke the superpowers:') ||
      text.startsWith('Base directory for this skill:')
    )
  }

  // 解码 Claude Code 目录名：-Users-bing--Code--project → /Users/bing/-Code-/project
  static decodeCwd(encoded: string): string {
    return encoded.replace(/--/g, '\x00').replace(/-/g, '/').replace(/\x00/g, '-')
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' })
    const rl = createInterface({ input: stream, crlfDelay: Infinity })
    for await (const line of rl) {
      if (line.trim()) yield line
    }
  }

  private parseLine(line: string): Record<string, unknown> | null {
    try {
      return JSON.parse(line) as Record<string, unknown>
    } catch {
      return null
    }
  }

  private isToolResult(content: unknown): boolean {
    if (!Array.isArray(content)) return false
    return content.some((c: Record<string, unknown>) => c.type === 'tool_result')
  }

  private extractContent(content: unknown): string {
    if (typeof content === 'string') return content
    if (Array.isArray(content)) {
      // Collect all text blocks (some models emit multiple)
      const texts: string[] = []
      let thinkingFallback = ''
      for (const item of content) {
        const c = item as Record<string, unknown>
        if (c.type === 'text' && c.text) {
          texts.push(c.text as string)
        } else if (c.type === 'thinking' && c.thinking && !thinkingFallback) {
          thinkingFallback = c.thinking as string
        }
      }
      if (texts.length > 0) return texts.join('\n')
      // Fall back to thinking content if no text blocks exist
      if (thinkingFallback) return thinkingFallback
    }
    return ''
  }
}
