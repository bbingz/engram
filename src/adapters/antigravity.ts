// src/adapters/antigravity.ts
import { createReadStream } from 'fs'
import { stat, readdir, mkdir, writeFile, readFile } from 'fs/promises'
import { createInterface } from 'readline'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'
import { CascadeGrpcClient } from './grpc/cascade-client.js'

interface CacheMetaLine {
  id: string
  title: string
  createdAt: string
  updatedAt: string
}

export class AntigravityAdapter implements SessionAdapter {
  readonly name = 'antigravity' as const
  private daemonDir: string
  private cacheDir: string
  private conversationsDir: string

  constructor(daemonDir?: string, cacheDir?: string, conversationsDir?: string) {
    const home = homedir()
    this.daemonDir = daemonDir ?? join(home, '.gemini', 'antigravity', 'daemon')
    this.cacheDir = cacheDir ?? join(home, '.coding-memory', 'cache', 'antigravity')
    this.conversationsDir = conversationsDir ?? join(home, '.gemini', 'antigravity', 'conversations')
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.daemonDir)
      return true
    } catch {
      try { await stat(this.cacheDir); return true } catch { return false }
    }
  }

  // Sync runs before listing — fetches new/updated conversations from gRPC, saves to cache
  async sync(): Promise<void> {
    await mkdir(this.cacheDir, { recursive: true })
    const client = await CascadeGrpcClient.fromDaemonDir(this.daemonDir)
    if (!client) return  // app not running, use existing cache

    try {
      const conversations = await client.listConversations()

      for (const conv of conversations) {
        if (!conv.cascadeId) continue
        const cachePath = join(this.cacheDir, `${conv.cascadeId}.jsonl`)
        const pbPath = join(this.conversationsDir, `${conv.cascadeId}.pb`)

        // Check if cache is fresh (pb mtime <= cache mtime)
        try {
          const [pbStat, cacheStat] = await Promise.all([stat(pbPath), stat(cachePath)])
          if (cacheStat.mtimeMs >= pbStat.mtimeMs) continue  // cache is fresh
        } catch { /* pb or cache doesn't exist — proceed with fetch */ }

        try {
          const markdown = await client.getMarkdown(conv.cascadeId)
          const messages = parseMarkdownToMessages(markdown)

          const metaLine: CacheMetaLine = {
            id: conv.cascadeId,
            title: conv.title,
            createdAt: conv.createdAt,
            updatedAt: conv.updatedAt,
          }
          const lines = [
            JSON.stringify(metaLine),
            ...messages.map(m => JSON.stringify(m)),
          ]
          await writeFile(cachePath, lines.join('\n') + '\n', 'utf8')
        } catch { /* skip if markdown fetch fails */ }
      }
    } finally {
      client.close()
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    await this.sync()
    try {
      const files = await readdir(this.cacheDir)
      for (const file of files) {
        if (file.endsWith('.jsonl')) {
          yield join(this.cacheDir, file)
        }
      }
    } catch { /* cache dir not created yet */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      const firstLine = await readFirstLine(filePath)
      if (!firstLine) return null

      const meta = JSON.parse(firstLine) as CacheMetaLine
      if (!meta.id) return null

      // Count messages (skip first meta line)
      let userCount = 0
      let totalCount = 0
      let firstUserText = ''
      let isFirst = true

      for await (const line of this.readLines(filePath)) {
        if (isFirst) { isFirst = false; continue }  // skip meta line
        try {
          const msg = JSON.parse(line) as { role: string; content: string }
          totalCount++
          if (msg.role === 'user') {
            userCount++
            if (!firstUserText) firstUserText = msg.content
          }
        } catch { /* skip */ }
      }

      return {
        id: meta.id,
        source: 'antigravity',
        startTime: meta.createdAt,
        endTime: meta.updatedAt !== meta.createdAt ? meta.updatedAt : undefined,
        cwd: '',
        messageCount: totalCount,
        userMessageCount: userCount,
        summary: (meta.title || firstUserText).slice(0, 200) || undefined,
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
    let isFirst = true

    for await (const line of this.readLines(filePath)) {
      if (isFirst) { isFirst = false; continue }  // skip meta line
      if (yielded >= limit) break

      try {
        const msg = JSON.parse(line) as { role: string; content: string; timestamp?: string }
        if (msg.role !== 'user' && msg.role !== 'assistant') continue
        if (count < offset) { count++; continue }
        count++
        yield { role: msg.role as 'user' | 'assistant', content: msg.content, timestamp: msg.timestamp }
        yielded++
      } catch { /* skip malformed */ }
    }
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' })
    const rl = createInterface({ input: stream, crlfDelay: Infinity })
    for await (const line of rl) {
      if (line.trim()) yield line
    }
  }
}

// Parse the Markdown output of ConvertTrajectoryToMarkdown into {role, content} pairs.
// Format: ## User\n\ntext...\n\n## Cascade\n\ntext...
export function parseMarkdownToMessages(markdown: string): { role: 'user' | 'assistant'; content: string; timestamp?: string }[] {
  const messages: { role: 'user' | 'assistant'; content: string }[] = []
  const sections = markdown.split(/^##\s+/m).filter(Boolean)
  for (const section of sections) {
    const newline = section.indexOf('\n')
    if (newline === -1) continue
    const header = section.slice(0, newline).trim().toLowerCase()
    const content = section.slice(newline + 1).trim()
    if (!content) continue
    if (header.startsWith('user')) {
      messages.push({ role: 'user', content })
    } else if (header.startsWith('assistant') || header.startsWith('cascade')) {
      messages.push({ role: 'assistant', content })
    }
  }
  return messages
}

async function readFirstLine(filePath: string): Promise<string | null> {
  const content = await readFile(filePath, 'utf8')
  const line = content.split('\n')[0]?.trim()
  return line || null
}
