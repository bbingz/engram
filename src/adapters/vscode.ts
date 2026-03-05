// src/adapters/vscode.ts
import { readFile, stat } from 'fs/promises'
import { glob } from 'fs/promises'
import { homedir } from 'os'
import { join, basename } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

interface VsRequest {
  requestId: string
  message: { text?: string; parts?: { kind: string; value: string }[] }
  response: { value: { kind: string; content?: { value: string } } }[]
  timestamp?: number
}

interface VsSessionData {
  version: number
  sessionId: string
  creationDate: number
  requests: VsRequest[]
}

interface VsLine0 {
  kind: 0
  v: VsSessionData
}

export class VsCodeAdapter implements SessionAdapter {
  readonly name = 'vscode' as const
  private workspaceStorageDir: string

  constructor(workspaceStorageDir?: string) {
    this.workspaceStorageDir = workspaceStorageDir
      ?? join(homedir(), 'Library', 'Application Support', 'Code', 'User', 'workspaceStorage')
  }

  async detect(): Promise<boolean> {
    try { await stat(this.workspaceStorageDir); return true } catch { return false }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const pattern = join(this.workspaceStorageDir, '*', 'chatSessions', '*.jsonl')
      for await (const file of glob(pattern)) {
        yield file
      }
    } catch { /* dir not found */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      const session = await this.readSession(filePath)
      if (!session || session.requests.length === 0) return null

      const userMessages = session.requests.map(r => this.extractUserText(r)).filter(Boolean)
      const lastReq = session.requests[session.requests.length - 1]

      const assistantMessageCount = session.requests.length  // 1:1 mapping with user

      return {
        id: session.sessionId || basename(filePath, '.jsonl'),
        source: 'vscode',
        startTime: new Date(session.creationDate).toISOString(),
        endTime: lastReq.timestamp && lastReq.timestamp !== session.creationDate
          ? new Date(lastReq.timestamp).toISOString()
          : undefined,
        cwd: '',
        messageCount: session.requests.length + assistantMessageCount,
        userMessageCount: session.requests.length,
        assistantMessageCount,
        systemMessageCount: 0,
        summary: userMessages[0]?.slice(0, 200),
        filePath,
        sizeBytes: fileStat.size,
      }
    } catch { return null }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity
    let count = 0
    let yielded = 0

    try {
      const session = await this.readSession(filePath)
      if (!session) return

      for (const req of session.requests) {
        // User message
        const userText = this.extractUserText(req)
        if (userText) {
          if (count >= offset && yielded < limit) {
            yield {
              role: 'user',
              content: userText,
              timestamp: req.timestamp ? new Date(req.timestamp).toISOString() : undefined,
            }
            yielded++
          }
          count++
        }

        // Assistant message
        const assistantText = this.extractAssistantText(req)
        if (assistantText) {
          if (count >= offset && yielded < limit) {
            yield {
              role: 'assistant',
              content: assistantText,
              timestamp: req.timestamp ? new Date(req.timestamp).toISOString() : undefined,
            }
            yielded++
          }
          count++
        }

        if (yielded >= limit) break
      }
    } catch { /* file not readable */ }
  }

  private async readSession(filePath: string): Promise<VsSessionData | null> {
    try {
      const content = await readFile(filePath, 'utf8')
      const firstLine = content.split('\n')[0]?.trim()
      if (!firstLine) return null
      const parsed = JSON.parse(firstLine) as VsLine0
      if (parsed.kind !== 0 || !parsed.v) return null
      return parsed.v
    } catch { return null }
  }

  private extractUserText(req: VsRequest): string {
    if (req.message.text) return req.message.text
    if (req.message.parts) {
      for (const p of req.message.parts) {
        if (p.kind === 'text' && p.value) return p.value
      }
    }
    return ''
  }

  private extractAssistantText(req: VsRequest): string {
    for (const r of req.response) {
      if (r.value?.kind === 'markdownContent' && r.value.content?.value) {
        return r.value.content.value
      }
    }
    return ''
  }
}
