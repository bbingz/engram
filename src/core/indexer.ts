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
          const fileStat = await stat(filePath)
          // 跳过已索引且文件大小未变的
          if (this.db.isIndexed(filePath, fileStat.size)) continue

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
      const fileStat = await stat(filePath)
      const info = await adapter.parseSessionInfo(filePath)
      if (!info) return false

      if (info.cwd && !info.project) {
        info.project = await resolveProjectName(info.cwd)
      }

      this.db.upsertSession({ ...info, sizeBytes: fileStat.size })

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
