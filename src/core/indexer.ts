// src/core/indexer.ts
import { stat } from 'fs/promises'
import type { SessionAdapter } from '../adapters/types.js'
import type { Database } from './db.js'
import { resolveProjectName } from './project.js'

export class Indexer {
  constructor(
    private db: Database,
    private adapters: SessionAdapter[]
  ) {}

  // 全量扫描所有适配器，返回新增索引数量
  // sources: optional set of source names to scan (defaults to all)
  async indexAll(opts?: { sources?: Set<string> }): Promise<number> {
    let newCount = 0

    for (const adapter of this.adapters) {
      if (opts?.sources && !opts.sources.has(adapter.name)) continue
      if (!await adapter.detect()) continue

      for await (const filePath of adapter.listSessionFiles()) {
        try {
          // 虚拟路径（如 cursor: dbPath?composer=id）stat 会失败，跳过 dedup 直接尝试索引
          let fileSize = 0
          try {
            const fileStat = await stat(filePath)
            fileSize = fileStat.size
          } catch { /* virtual path */ }

          // 快速跳过：文件大小与 DB 记录一致（适用于大多数适配器）
          if (fileSize > 0 && this.db.isIndexed(filePath, fileSize)) continue

          const info = await adapter.parseSessionInfo(filePath)
          if (!info) continue

          // 二段跳过：某些适配器（如 antigravity）的 sizeBytes 与文件本身大小不同
          // 例如 antigravity 用 .pb 文件大小，此时用 info.sizeBytes 再做一次 dedup
          if (info.sizeBytes !== fileSize && info.sizeBytes > 0 && this.db.isIndexed(filePath, info.sizeBytes)) continue

          // 解析项目名（如果没有）
          if (info.cwd && !info.project) {
            info.project = await resolveProjectName(info.cwd)
          }

          this.db.upsertSession(info)

          // 索引消息内容用于全文搜索（user + assistant）
          const messages: { role: string; content: string }[] = []
          for await (const msg of adapter.streamMessages(filePath)) {
            if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
              messages.push({ role: msg.role, content: msg.content })
            }
          }
          if (messages.length > 0) {
            this.db.indexSessionContent(info.id, messages, info.summary)
          }

          newCount++
        } catch {
          // 跳过无法处理的文件，不中断整体流程
        }
      }
    }

    return newCount
  }

  // 回填缺少 assistant/system 计数的旧会话
  async backfillCounts(): Promise<number> {
    const ids = this.db.needsCountBackfill()
    if (ids.length === 0) return 0

    let count = 0
    for (const id of ids) {
      const session = this.db.getSession(id)
      if (!session) continue
      const adapter = this.adapters.find(a => a.name === session.source)
      // Build candidate list: exact match first, then all others as fallback
      // (derived sources like lobsterai/qwen/kimi share format with claude-code)
      const candidates = adapter ? [adapter] : this.adapters
      for (const a of candidates) {
        try {
          const info = await a.parseSessionInfo(session.filePath)
          if (info) {
            this.db.upsertSession({ ...info, project: session.project ?? info.project })
            count++
            break
          }
        } catch { /* try next */ }
      }
    }
    return count
  }

  // 索引单个文件（文件变化时增量更新用）
  async indexFile(adapter: SessionAdapter, filePath: string): Promise<{ indexed: boolean; sessionId?: string; messageCount?: number }> {
    try {
      let fileSize = 0
      try { fileSize = (await stat(filePath)).size } catch { /* virtual path */ }

      const info = await adapter.parseSessionInfo(filePath)
      if (!info) return { indexed: false }

      if (info.cwd && !info.project) {
        info.project = await resolveProjectName(info.cwd)
      }

      this.db.upsertSession({ ...info, sizeBytes: info.sizeBytes || fileSize })

      const messages: { role: string; content: string }[] = []
      for await (const msg of adapter.streamMessages(filePath)) {
        if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
          messages.push({ role: msg.role, content: msg.content })
        }
      }
      if (messages.length > 0) {
        this.db.indexSessionContent(info.id, messages, info.summary)
      }

      return { indexed: true, sessionId: info.id, messageCount: info.messageCount ?? messages.length }
    } catch {
      return { indexed: false }
    }
  }
}
