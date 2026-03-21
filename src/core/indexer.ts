// src/core/indexer.ts
import { createHash } from 'crypto'
import { stat } from 'fs/promises'
import type { SessionAdapter, SessionInfo, Message } from '../adapters/types.js'
import type { Database } from './db.js'
import { computeCost } from './pricing.js'
import { resolveProjectName } from './project.js'
import type { AuthoritativeSessionSnapshot } from './session-snapshot.js'
import { computeTier, type SessionTier } from './session-tier.js'
import { isPreambleOnly } from './preamble-detector.js'
import { SessionSnapshotWriter } from './session-writer.js'
import { type VikingBridge } from './viking-bridge.js'
import { filterForViking } from './viking-filter.js'
import type { TitleGenerator } from './title-generator.js'

export class Indexer {
  private writer: SessionSnapshotWriter

  constructor(
    private db: Database,
    private adapters: SessionAdapter[],
    private opts?: { viking?: VikingBridge | null; authoritativeNode?: string; writer?: SessionSnapshotWriter; titleGenerator?: TitleGenerator }
  ) {
    this.writer = opts?.writer ?? new SessionSnapshotWriter(db)
  }

  private pushToViking(info: SessionInfo, messages: { role: string; content: string }[]): void {
    if (!this.opts?.viking || messages.length === 0) return
    this.opts.viking.checkAvailable().then(ok => {
      if (!ok) return
      const filtered = filterForViking(messages)
      if (filtered.length === 0) return
      const sessionId = `engram-${info.source}-${info.project ?? 'unknown'}-${info.id}`
      this.opts!.viking!.pushSession(sessionId, filtered).catch(() => {})
    }).catch(() => {})
  }

  private async generateTitleIfNeeded(sessionId: string, tier: SessionTier, messages: { role: string; content: string }[]): Promise<void> {
    const titleGenerator = this.opts?.titleGenerator
    if (!titleGenerator) return
    if (tier === 'skip' || tier === 'lite') return
    if (messages.length < 2) return

    // Skip if title already exists
    const existing = this.db.getRawDb().prepare('SELECT generated_title FROM sessions WHERE id = ?').get(sessionId) as { generated_title: string | null } | undefined
    if (existing?.generated_title) return

    const msgs = messages.slice(0, 6).map(m => ({ role: m.role, content: m.content?.slice(0, 200) || '' }))
    const title = await titleGenerator.generate(msgs)
    if (title) {
      this.db.getRawDb().prepare('UPDATE sessions SET generated_title = ? WHERE id = ?').run(title, sessionId)
    }
  }

  private writeExtractedData(sessionId: string, model: string, inputTokens: number, outputTokens: number, cacheReadTokens: number, cacheCreationTokens: number, toolCounts: Map<string, number>): void {
    // Always write a session_costs row, even with zero tokens.
    // Without this, sessionsWithoutCosts() returns non-claude-code sessions forever → infinite backfill loop.
    const cost = computeCost(model, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)
    this.db.upsertSessionCost(sessionId, model, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, cost)
    if (toolCounts.size > 0) {
      this.db.upsertSessionTools(sessionId, toolCounts)
    }
  }

  /** Accumulate token usage and tool calls from a message stream. */
  private static accumulateFromStream(msg: Message, acc: { inputTokens: number; outputTokens: number; cacheReadTokens: number; cacheCreationTokens: number; toolCounts: Map<string, number> }): void {
    if (msg.usage) {
      acc.inputTokens += msg.usage.inputTokens
      acc.outputTokens += msg.usage.outputTokens
      acc.cacheReadTokens += msg.usage.cacheReadTokens ?? 0
      acc.cacheCreationTokens += msg.usage.cacheCreationTokens ?? 0
    }
    if (msg.toolCalls) {
      for (const tc of msg.toolCalls) {
        acc.toolCounts.set(tc.name, (acc.toolCounts.get(tc.name) || 0) + 1)
      }
    }
  }

  private static newAccumulator() {
    return { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, toolCounts: new Map<string, number>() }
  }

  private buildLocalAuthoritativeSnapshot(
    current: AuthoritativeSessionSnapshot | null,
    info: SessionInfo,
    filePath: string,
    messages: Array<{ role: string; content: string }>,
  ): AuthoritativeSessionSnapshot {
    const authoritativeNode = this.opts?.authoritativeNode ?? 'local'
    const syncPayload = {
      cwd: info.cwd,
      project: info.project,
      model: info.model,
      messageCount: info.messageCount,
      userMessageCount: info.userMessageCount,
      assistantMessageCount: info.assistantMessageCount,
      toolMessageCount: info.toolMessageCount,
      systemMessageCount: info.systemMessageCount,
      summary: info.summary,
      summaryMessageCount: messages.length,
    }
    const snapshotHash = createHash('sha256').update(JSON.stringify(syncPayload)).digest('hex')

    const userMsgs = messages.filter(m => m.role === 'user').slice(0, 3).map(m => m.content?.slice(0, 500) || '')
    const isPreamble = isPreambleOnly(userMsgs)
    const assistantCount = messages.filter(m => m.role === 'assistant').length
    const toolCount = messages.filter(m => m.role === 'tool' || (m as { toolName?: string }).toolName).length

    const tier = computeTier({
      messageCount: info.messageCount,
      agentRole: info.agentRole ?? null,
      filePath,
      project: info.project ?? null,
      summary: info.summary ?? null,
      startTime: info.startTime,
      endTime: info.endTime ?? null,
      source: info.source,
      isPreamble,
      assistantCount,
      toolCount,
    })

    return {
      id: info.id,
      source: info.source,
      authoritativeNode,
      syncVersion: current ? current.syncVersion + 1 : 1,
      snapshotHash,
      indexedAt: new Date().toISOString(),
      sourceLocator: filePath,
      sizeBytes: info.sizeBytes,
      startTime: info.startTime,
      endTime: info.endTime,
      origin: authoritativeNode,
      tier,
      agentRole: info.agentRole ?? null,
      ...syncPayload,
    }
  }

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

          const messages: { role: string; content: string }[] = []
          const acc = Indexer.newAccumulator()

          for await (const msg of adapter.streamMessages(filePath)) {
            if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
              messages.push({ role: msg.role, content: msg.content })
            }
            Indexer.accumulateFromStream(msg, acc)
          }

          const current = this.db.getAuthoritativeSnapshot(info.id)
          const snapshot = this.buildLocalAuthoritativeSnapshot(current, info, filePath, messages)
          this.writer.writeAuthoritativeSnapshot(snapshot)

          // Write cost and tool data
          this.writeExtractedData(info.id, info.model || '', acc.inputTokens, acc.outputTokens, acc.cacheReadTokens, acc.cacheCreationTokens, acc.toolCounts)

          if (snapshot.tier === 'premium') {
            this.pushToViking(info, messages)
          }

          if (snapshot.tier) {
            await this.generateTitleIfNeeded(info.id, snapshot.tier, messages)
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

  // Backfill costs and tools for sessions that have no session_costs row
  async backfillCosts(): Promise<number> {
    let total = 0
    while (true) {
      const ids = this.db.sessionsWithoutCosts()
      if (ids.length === 0) break
      for (const id of ids) {
        const session = this.db.getSession(id)
        if (!session?.filePath) {
          this.writeExtractedData(id, '', 0, 0, 0, 0, new Map())
          total++
          continue
        }
        const adapter = this.adapters.find(a => a.name === session.source)
        if (!adapter) {
          this.writeExtractedData(id, session.model || '', 0, 0, 0, 0, new Map())
          total++
          continue
        }
        try {
          const acc = Indexer.newAccumulator()
          for await (const msg of adapter.streamMessages(session.filePath)) {
            Indexer.accumulateFromStream(msg, acc)
          }
          this.writeExtractedData(id, session.model || '', acc.inputTokens, acc.outputTokens, acc.cacheReadTokens, acc.cacheCreationTokens, acc.toolCounts)
          total++
        } catch {
          this.writeExtractedData(id, session.model || '', 0, 0, 0, 0, new Map())
          total++
        }
        // Rate limit: avoid I/O storms during large backfill
        await new Promise(r => setTimeout(r, 50))
      }
      console.log(`[backfill] Costs: ${ids.length} sessions processed (running total: ${total})`)
    }
    return total
  }

  // 索引单个文件（文件变化时增量更新用）
  async indexFile(adapter: SessionAdapter, filePath: string): Promise<{ indexed: boolean; sessionId?: string; messageCount?: number; tier?: SessionTier }> {
    try {
      let fileSize = 0
      try { fileSize = (await stat(filePath)).size } catch { /* virtual path */ }

      const info = await adapter.parseSessionInfo(filePath)
      if (!info) return { indexed: false }

      if (info.cwd && !info.project) {
        info.project = await resolveProjectName(info.cwd)
      }

      const messages: { role: string; content: string }[] = []
      const acc = Indexer.newAccumulator()

      for await (const msg of adapter.streamMessages(filePath)) {
        if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
          messages.push({ role: msg.role, content: msg.content })
        }
        Indexer.accumulateFromStream(msg, acc)
      }

      const current = this.db.getAuthoritativeSnapshot(info.id)
      const snapshot = this.buildLocalAuthoritativeSnapshot(current, { ...info, sizeBytes: info.sizeBytes || fileSize }, filePath, messages)
      this.writer.writeAuthoritativeSnapshot(snapshot)

      // Write cost and tool data
      this.writeExtractedData(info.id, info.model || '', acc.inputTokens, acc.outputTokens, acc.cacheReadTokens, acc.cacheCreationTokens, acc.toolCounts)

      if (snapshot.tier === 'premium') {
        this.pushToViking(info, messages)
      }

      if (snapshot.tier) {
        await this.generateTitleIfNeeded(info.id, snapshot.tier, messages)
      }

      return { indexed: true, sessionId: info.id, messageCount: info.messageCount ?? messages.length, tier: snapshot.tier }
    } catch {
      return { indexed: false }
    }
  }
}
