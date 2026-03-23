// src/adapters/codex.ts
import { createReadStream } from 'fs'
import { stat } from 'fs/promises'
import { createInterface } from 'readline'
import { glob } from 'fs/promises'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

export class CodexAdapter implements SessionAdapter {
  readonly name = 'codex' as const
  private sessionsRoot: string

  constructor(sessionsRoot?: string) {
    this.sessionsRoot = sessionsRoot ?? join(homedir(), '.codex', 'sessions')
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.sessionsRoot)
      return true
    } catch {
      return false
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const pattern = join(this.sessionsRoot, '**', 'rollout-*.jsonl')
      for await (const file of glob(pattern)) {
        yield file
      }
    } catch {
      // sessions root 不存在时静默返回
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      let meta: Record<string, unknown> | null = null
      let userCount = 0
      let assistantCount = 0
      let systemCount = 0
      let firstUserText = ''
      let lastTimestamp = ''

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line)
        if (!obj) continue

        if (obj.type === 'session_meta' && !meta) {
          meta = obj.payload as Record<string, unknown>
        }

        if (obj.type === 'response_item') {
          const payload = obj.payload as Record<string, unknown>
          if (payload.type === 'message') {
            const role = payload.role as string
            if (role === 'user') {
              const text = this.extractText(payload.content as unknown[])
              if (this.isSystemInjection(text)) {
                systemCount++
              } else {
                userCount++
                if (!firstUserText) {
                  firstUserText = text
                }
              }
            } else if (role === 'assistant') {
              assistantCount++
            }
            if (obj.timestamp) {
              lastTimestamp = obj.timestamp as string
            }
          }
        }
      }

      if (!meta) return null

      const payload = meta as Record<string, unknown>
      const agentRole = payload.agent_role as string | undefined
      return {
        id: payload.id as string,
        source: 'codex',
        startTime: payload.timestamp as string,
        endTime: lastTimestamp || undefined,
        cwd: (payload.cwd as string) || '',
        model: payload.model_provider as string | undefined,
        messageCount: userCount + assistantCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: 0,
        systemMessageCount: systemCount,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath,
        sizeBytes: fileStat.size,
        agentRole: agentRole || undefined,
      }
    } catch {
      return null
    }
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
      if (obj.type !== 'response_item') continue

      const payload = obj.payload as Record<string, unknown>
      if (payload.type !== 'message') continue

      const role = payload.role as string
      if (role !== 'user' && role !== 'assistant') continue

      if (count < offset) { count++; continue }
      count++

      yield {
        role: role as 'user' | 'assistant',
        content: this.extractText(payload.content as unknown[]),
        timestamp: obj.timestamp as string | undefined,
      }
      yielded++
    }
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

  private isSystemInjection(text: string): boolean {
    return (
      text.startsWith('# AGENTS.md instructions for ') ||
      text.includes('<INSTRUCTIONS>') ||
      text.startsWith('<local-command-caveat>') ||
      text.startsWith('<environment_context>')
    )
  }

  private extractText(content: unknown[]): string {
    if (!Array.isArray(content)) return ''
    for (const item of content) {
      const c = item as Record<string, unknown>
      if (c.text) return c.text as string
      if (c.input_text) return c.input_text as string
    }
    return ''
  }
}
