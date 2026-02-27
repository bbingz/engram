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
  async indexAll(): Promise<number> {
    let newCount = 0

    for (const adapter of this.adapters) {
      if (!await adapter.detect()) continue

      for await (const filePath of adapter.listSessionFiles()) {
        try {
          // 虚拟路径（如 cursor: dbPath?composer=id）stat 会失败，跳过 dedup 直接尝试索引
          let fileSize = 0
          try {
            const fileStat = await stat(filePath)
            fileSize = fileStat.size
          } catch { /* virtual path */ }

          // 跳过已索引且文件大小未变的（虚拟路径 fileSize=0 时始终尝试，由 upsertSession 幂等处理）
          if (fileSize > 0 && this.db.isIndexed(filePath, fileSize)) continue

          const info = await adapter.parseSessionInfo(filePath)
          if (!info) continue

          // 解析项目名（如果没有）
          if (info.cwd && !info.project) {
            info.project = await resolveProjectName(info.cwd)
          }

          this.db.upsertSession(info)

          // 索引用户消息内容用于全文搜索
          const messages: { role: string; content: string }[] = []
          for await (const msg of adapter.streamMessages(filePath)) {
            if (msg.role === 'user' && msg.content.trim()) {
              messages.push({ role: msg.role, content: msg.content })
            }
          }
          if (messages.length > 0) {
            this.db.indexSessionContent(info.id, messages)
          }

          newCount++
        } catch {
          // 跳过无法处理的文件，不中断整体流程
        }
      }
    }

    return newCount
  }

  // 索引单个文件（文件变化时增量更新用）
  async indexFile(adapter: SessionAdapter, filePath: string): Promise<boolean> {
    try {
      let fileSize = 0
      try { fileSize = (await stat(filePath)).size } catch { /* virtual path */ }

      const info = await adapter.parseSessionInfo(filePath)
      if (!info) return false

      if (info.cwd && !info.project) {
        info.project = await resolveProjectName(info.cwd)
      }

      this.db.upsertSession({ ...info, sizeBytes: info.sizeBytes || fileSize })

      const messages: { role: string; content: string }[] = []
      for await (const msg of adapter.streamMessages(filePath)) {
        if (msg.role === 'user' && msg.content.trim()) {
          messages.push({ role: msg.role, content: msg.content })
        }
      }
      if (messages.length > 0) {
        this.db.indexSessionContent(info.id, messages)
      }

      return true
    } catch {
      return false
    }
  }
}
