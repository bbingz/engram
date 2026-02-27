// src/adapters/opencode.ts
import { existsSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import Database from 'better-sqlite3'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

interface SessionRow {
  id: string
  directory: string
  title: string
  time_created: number
  time_updated: number
}

interface MessageRow {
  id: string
  session_id: string
  time_created: number
  data: string
}

interface MessageCountRow {
  count: number
}

interface MessageData {
  role: 'user' | 'assistant'
  time?: { created?: number; completed?: number }
  content?: Array<{ type: string; value?: string; text?: string }>
}

export class OpenCodeAdapter implements SessionAdapter {
  readonly name = 'opencode' as const
  private dbPath: string

  constructor(dbPath?: string) {
    this.dbPath = dbPath ?? join(homedir(), '.local', 'share', 'opencode', 'opencode.db')
  }

  async detect(): Promise<boolean> {
    return existsSync(this.dbPath)
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    if (!existsSync(this.dbPath)) return

    let db: Database.Database | null = null
    try {
      db = new Database(this.dbPath, { readonly: true })
      const rows = db.prepare<[], SessionRow>(
        'SELECT id, directory, title, time_created, time_updated FROM session WHERE time_archived IS NULL ORDER BY time_updated DESC'
      ).all()

      for (const row of rows) {
        yield `${this.dbPath}::${row.id}`
      }
    } catch {
      // DB open or query failed
    } finally {
      db?.close()
    }
  }

  private splitVirtualPath(filePath: string): { dbPath: string; sessionId: string } | null {
    const idx = filePath.lastIndexOf('::')
    if (idx === -1) return null
    return {
      dbPath: filePath.slice(0, idx),
      sessionId: filePath.slice(idx + 2),
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    const parts = this.splitVirtualPath(filePath)
    if (!parts) return null

    const { dbPath, sessionId } = parts

    let db: Database.Database | null = null
    try {
      db = new Database(dbPath, { readonly: true })

      const session = db.prepare<[string], SessionRow>(
        'SELECT id, directory, title, time_created, time_updated FROM session WHERE id = ? AND time_archived IS NULL'
      ).get(sessionId)

      if (!session) return null

      const countRow = db.prepare<[string], MessageCountRow>(
        'SELECT COUNT(*) as count FROM message WHERE session_id = ?'
      ).get(sessionId)

      const messageCount = countRow?.count ?? 0

      const messages = db.prepare<[string], MessageRow>(
        'SELECT id, session_id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created ASC'
      ).all(sessionId)

      let startTime = new Date(session.time_created).toISOString()
      let endTime: string | undefined

      if (messages.length > 0) {
        startTime = new Date(messages[0].time_created).toISOString()
        if (messages.length > 1) {
          endTime = new Date(messages[messages.length - 1].time_created).toISOString()
        }
      }

      let userMessageCount = 0
      for (const msgRow of messages) {
        try {
          const data = JSON.parse(msgRow.data) as MessageData
          if (data.role === 'user') userMessageCount++
        } catch {
          // skip unparseable messages
        }
      }

      return {
        id: session.id,
        source: 'opencode',
        startTime,
        endTime,
        cwd: session.directory,
        messageCount,
        userMessageCount,
        summary: session.title || undefined,
        filePath,
        sizeBytes: session.time_updated,
      }
    } catch {
      return null
    } finally {
      db?.close()
    }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const parts = this.splitVirtualPath(filePath)
    if (!parts) return

    const { dbPath, sessionId } = parts
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity

    let db: Database.Database | null = null
    try {
      db = new Database(dbPath, { readonly: true })

      const rows = db.prepare<[string], MessageRow>(
        'SELECT id, session_id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created ASC'
      ).all(sessionId)

      let count = 0
      let yielded = 0

      for (const row of rows) {
        if (yielded >= limit) break

        let data: MessageData
        try {
          data = JSON.parse(row.data) as MessageData
        } catch {
          continue
        }

        if (data.role !== 'user' && data.role !== 'assistant') continue

        if (count < offset) { count++; continue }
        count++

        const content = this.extractContent(data.content)
        const timestamp = new Date(row.time_created).toISOString()

        yield {
          role: data.role,
          content,
          timestamp,
        }
        yielded++
      }
    } catch {
      // DB open or query failed
    } finally {
      db?.close()
    }
  }

  private extractContent(content: MessageData['content']): string {
    if (!content || !Array.isArray(content)) return ''
    for (const item of content) {
      if (item.type === 'text') {
        if (item.value) return item.value
        if (item.text) return item.text
      }
    }
    return ''
  }
}
