// src/adapters/gemini-cli.ts
import { readFile, stat, readdir } from 'fs/promises'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

interface GeminiSession {
  sessionId: string
  projectHash: string
  startTime: string
  lastUpdated?: string
  messages: GeminiMessage[]
}

interface GeminiMessage {
  id: string
  timestamp: string
  type: 'user' | 'model' | 'info' | string
  content: string
}

export class GeminiCliAdapter implements SessionAdapter {
  readonly name = 'gemini-cli' as const
  private tmpRoot: string
  private projectsFile: string
  private projectsCache: Map<string, string> | null = null

  constructor(tmpRoot?: string, projectsFile?: string) {
    this.tmpRoot = tmpRoot ?? join(homedir(), '.gemini', 'tmp')
    this.projectsFile = projectsFile ?? join(homedir(), '.gemini', 'projects.json')
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.tmpRoot)
      return true
    } catch {
      return false
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const projectDirs = await readdir(this.tmpRoot)
      for (const dir of projectDirs) {
        const chatsDir = join(this.tmpRoot, dir, 'chats')
        try {
          const files = await readdir(chatsDir)
          for (const file of files) {
            if (file.startsWith('session-') && file.endsWith('.json')) {
              yield join(chatsDir, file)
            }
          }
        } catch {
          // chats 目录不存在
        }
      }
    } catch {
      // tmpRoot 不存在
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      const raw = await readFile(filePath, 'utf8')
      const session = JSON.parse(raw) as GeminiSession

      const userMessages = session.messages.filter(m => m.type === 'user')
      const modelMessages = session.messages.filter(m => m.type === 'model')
      const totalCount = userMessages.length + modelMessages.length

      // 从文件路径提取 projectName：.../tmp/<projectName>/chats/session-*.json
      const parts = filePath.split('/')
      const chatsIdx = parts.indexOf('chats')
      const projectName = chatsIdx > 0 ? parts[chatsIdx - 1] : ''

      // 通过 projects.json 解析真实 cwd
      const cwd = await this.resolveProject(projectName) ?? projectName

      return {
        id: session.sessionId,
        source: 'gemini-cli',
        startTime: session.startTime,
        endTime: session.lastUpdated,
        cwd,
        project: projectName,
        messageCount: totalCount,
        userMessageCount: userMessages.length,
        summary: userMessages[0]?.content.slice(0, 200) || undefined,
        filePath,
        sizeBytes: fileStat.size,
      }
    } catch {
      return null
    }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity

    const raw = await readFile(filePath, 'utf8')
    const session = JSON.parse(raw) as GeminiSession

    const relevant = session.messages.filter(m => m.type === 'user' || m.type === 'model')
    const sliced = relevant.slice(offset, limit === Infinity ? undefined : offset + (limit as number))

    for (const msg of sliced) {
      yield {
        role: msg.type === 'model' ? 'assistant' : 'user',
        content: msg.content,
        timestamp: msg.timestamp,
      }
    }
  }

  // projectName → cwd（通过 projects.json 反查）
  async resolveProject(projectName: string): Promise<string | null> {
    const map = await this.loadProjects()
    for (const [cwd, name] of map.entries()) {
      if (name === projectName) return cwd
    }
    return null
  }

  private async loadProjects(): Promise<Map<string, string>> {
    if (this.projectsCache) return this.projectsCache
    try {
      const raw = await readFile(this.projectsFile, 'utf8')
      const obj = JSON.parse(raw) as Record<string, unknown>
      // 支持 {"projects": {...}} 和直接 {...} 两种格式
      const projects = (obj.projects ?? obj) as Record<string, string>
      this.projectsCache = new Map(Object.entries(projects))
    } catch {
      this.projectsCache = new Map()
    }
    return this.projectsCache
  }
}
