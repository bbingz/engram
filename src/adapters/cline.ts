// src/adapters/cline.ts
import { stat, readdir, readFile } from 'fs/promises'
import { homedir } from 'os'
import { join, basename, dirname } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

interface UiMessage {
  ts: number
  type: string
  say?: string
  ask?: string
  text?: string
  partial?: boolean
}

export class ClineAdapter implements SessionAdapter {
  readonly name = 'cline' as const
  private tasksRoot: string

  constructor(tasksRoot?: string) {
    this.tasksRoot = tasksRoot ?? join(homedir(), '.cline', 'data', 'tasks')
  }

  async detect(): Promise<boolean> {
    try { await stat(this.tasksRoot); return true } catch { return false }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const taskDirs = await readdir(this.tasksRoot)
      for (const dir of taskDirs) {
        const uiPath = join(this.tasksRoot, dir, 'ui_messages.json')
        try { await stat(uiPath); yield uiPath } catch { /* skip */ }
      }
    } catch { /* tasksRoot missing */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      const taskId = basename(dirname(filePath))
      const msgs = await this.loadMessages(filePath)
      if (msgs.length === 0) return null

      const firstMsg = msgs[0]
      const lastMsg = msgs[msgs.length - 1]
      const taskMsg = msgs.find(m => m.say === 'task')
      const summary = taskMsg?.text?.slice(0, 200)
      const cwd = this.extractCwd(msgs)

      const userMsgs = msgs.filter(m => m.say === 'task' || m.say === 'user_feedback')
      const assistantMsgs = msgs.filter(m => m.say === 'text' && !m.partial)

      return {
        id: taskId,
        source: 'cline',
        startTime: new Date(firstMsg.ts).toISOString(),
        endTime: lastMsg.ts !== firstMsg.ts ? new Date(lastMsg.ts).toISOString() : undefined,
        cwd,
        messageCount: userMsgs.length + assistantMsgs.length,
        userMessageCount: userMsgs.length,
        assistantMessageCount: assistantMsgs.length,
        systemMessageCount: 0,
        summary,
        filePath,
        sizeBytes: fileStat.size,
      }
    } catch { return null }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity
    const msgs = await this.loadMessages(filePath)
    const display = msgs.filter(m =>
      m.say === 'task' ||
      m.say === 'user_feedback' ||
      (m.say === 'text' && !m.partial)
    )
    let yielded = 0
    for (let i = offset; i < display.length && yielded < limit; i++) {
      const m = display[i]
      const role: 'user' | 'assistant' =
        (m.say === 'task' || m.say === 'user_feedback') ? 'user' : 'assistant'
      yield { role, content: m.text ?? '', timestamp: new Date(m.ts).toISOString() }
      yielded++
    }
  }

  private async loadMessages(filePath: string): Promise<UiMessage[]> {
    try {
      const raw = await readFile(filePath, 'utf8')
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed as UiMessage[] : []
    } catch {
      return []
    }
  }

  private extractCwd(msgs: UiMessage[]): string {
    for (const m of msgs) {
      if (m.say !== 'api_req_started' || !m.text) continue
      try {
        const inner = JSON.parse(m.text) as { request?: string }
        const match = inner.request?.match(/Current Working Directory \(([^)]+)\)/)
        if (match) return match[1]
      } catch { /* skip */ }
    }
    return ''
  }
}
