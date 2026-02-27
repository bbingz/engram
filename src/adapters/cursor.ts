// src/adapters/cursor.ts
import BetterSqlite3 from 'better-sqlite3'
import { stat } from 'fs/promises'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

interface ComposerData {
  composerId: string
  createdAt: number
  lastUpdatedAt: number
  latestConversationSummary?: { summary?: string }
}

interface BubbleData {
  type: number      // 1 = user, 2 = assistant
  text?: string
  rawText?: string
  timingInfo?: { clientStartTime?: number }
}

export class CursorAdapter implements SessionAdapter {
  readonly name = 'cursor' as const
  private dbPath: string

  constructor(dbPath?: string) {
    this.dbPath = dbPath ?? join(homedir(), 'Library', 'Application Support', 'Cursor', 'User', 'globalStorage', 'state.vscdb')
  }

  async detect(): Promise<boolean> {
    try { await stat(this.dbPath); return true } catch { return false }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const db = new BetterSqlite3(this.dbPath, { readonly: true })
      try {
        const rows = db.prepare(
          `SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'`
        ).all() as { key: string; value: string }[]
        for (const row of rows) {
          try {
            const data = JSON.parse(row.value) as ComposerData
            if (data.composerId) {
              yield `${this.dbPath}?composer=${data.composerId}`
            }
          } catch { /* skip malformed */ }
        }
      } finally {
        db.close()
      }
    } catch { /* db not found */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const { dbPath, composerId } = this.parsePath(filePath)
      if (!composerId) return null
      const db = new BetterSqlite3(dbPath, { readonly: true })
      try {
        const row = db.prepare(
          `SELECT value FROM cursorDiskKV WHERE key = ?`
        ).get(`composerData:${composerId}`) as { value: string } | undefined
        if (!row) return null
        const data = JSON.parse(row.value) as ComposerData
        const fileStat = await stat(dbPath)
        return {
          id: data.composerId,
          source: 'cursor',
          startTime: new Date(data.createdAt).toISOString(),
          endTime: data.lastUpdatedAt !== data.createdAt
            ? new Date(data.lastUpdatedAt).toISOString()
            : undefined,
          cwd: '',
          messageCount: 0,
          userMessageCount: 0,
          summary: data.latestConversationSummary?.summary?.slice(0, 200),
          filePath,
          sizeBytes: fileStat.size,
        }
      } finally {
        db.close()
      }
    } catch { return null }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const { dbPath, composerId } = this.parsePath(filePath)
    if (!composerId) return
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity
    try {
      const db = new BetterSqlite3(dbPath, { readonly: true })
      try {
        const rows = db.prepare(
          `SELECT value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid ASC`
        ).all(`bubbleId:${composerId}:%`) as { value: string }[]
        let count = 0
        let yielded = 0
        for (const row of rows) {
          if (yielded >= limit) break
          try {
            const bubble = JSON.parse(row.value) as BubbleData
            const role = bubble.type === 1 ? 'user' : bubble.type === 2 ? 'assistant' : null
            if (!role) continue
            if (count < offset) { count++; continue }
            count++
            const content = bubble.text || bubble.rawText || ''
            if (!content.trim()) continue
            const ts = bubble.timingInfo?.clientStartTime
            yield {
              role,
              content,
              timestamp: ts ? new Date(ts).toISOString() : undefined,
            }
            yielded++
          } catch { /* skip malformed */ }
        }
      } finally {
        db.close()
      }
    } catch { /* db not found */ }
  }

  private parsePath(filePath: string): { dbPath: string; composerId: string | null } {
    const idx = filePath.indexOf('?composer=')
    if (idx === -1) return { dbPath: filePath, composerId: null }
    return { dbPath: filePath.slice(0, idx), composerId: filePath.slice(idx + 10) }
  }
}
