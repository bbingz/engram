import { readdirSync, statSync, readFileSync } from 'fs'
import { join, extname } from 'path'
import type { SourceName } from '../adapters/types.js'

export interface LiveSession {
  source: SourceName
  sessionId?: string
  project?: string
  cwd: string
  filePath: string
  startedAt: string
  model?: string
  currentActivity?: string
  lastModifiedAt: string
}

export interface WatchDir {
  path: string
  source: SourceName
}

export interface LiveSessionMonitorOptions {
  watchDirs: WatchDir[]
  stalenessMs?: number  // default 60_000 (60s)
}

export class LiveSessionMonitor {
  private sessions: Map<string, LiveSession> = new Map()
  private interval: ReturnType<typeof setInterval> | null = null
  private watchDirs: WatchDir[]
  private stalenessMs: number

  constructor(opts: LiveSessionMonitorOptions) {
    this.watchDirs = opts.watchDirs
    this.stalenessMs = opts.stalenessMs ?? 60_000
  }

  start(intervalMs = 5000): void {
    if (this.interval) return
    this.interval = setInterval(() => this.scan().catch(() => {}), intervalMs)
    this.scan().catch(() => {})
  }

  stop(): void {
    if (this.interval) {
      clearInterval(this.interval)
      this.interval = null
    }
  }

  isRunning(): boolean {
    return this.interval !== null
  }

  getSessions(): LiveSession[] {
    return [...this.sessions.values()]
  }

  async scan(): Promise<void> {
    const now = Date.now()
    const found = new Set<string>()

    for (const { path: watchDir, source } of this.watchDirs) {
      try {
        const files = this.findJsonlFiles(watchDir)
        for (const filePath of files) {
          try {
            const st = statSync(filePath)
            const mtimeMs = st.mtimeMs
            if (now - mtimeMs > this.stalenessMs) continue // stale

            found.add(filePath)
            const existing = this.sessions.get(filePath)
            if (existing && existing.lastModifiedAt === new Date(mtimeMs).toISOString()) continue

            // Parse session metadata from file
            const session = this.parseSessionFile(filePath, source, mtimeMs)
            if (session) {
              this.sessions.set(filePath, session)
            }
          } catch { /* skip unreadable files */ }
        }
      } catch { /* skip inaccessible directories */ }
    }

    // Remove sessions whose files are no longer active
    for (const key of this.sessions.keys()) {
      if (!found.has(key)) {
        this.sessions.delete(key)
      }
    }
  }

  private findJsonlFiles(dir: string): string[] {
    const results: string[] = []
    try {
      this.walkDir(dir, results, 0)
    } catch { /* directory may not exist */ }
    return results
  }

  private walkDir(dir: string, results: string[], depth: number): void {
    if (depth > 5) return // safety limit
    try {
      const entries = readdirSync(dir, { withFileTypes: true })
      for (const entry of entries) {
        const full = join(dir, entry.name)
        if (entry.isDirectory()) {
          this.walkDir(full, results, depth + 1)
        } else if (entry.isFile() && extname(entry.name) === '.jsonl') {
          results.push(full)
        }
      }
    } catch { /* skip unreadable dirs */ }
  }

  private parseSessionFile(filePath: string, source: SourceName, mtimeMs: number): LiveSession | null {
    try {
      const content = readFileSync(filePath, 'utf-8')
      const lines = content.split('\n').filter(Boolean)
      if (lines.length === 0) return null

      // Parse first line for session metadata
      let sessionId: string | undefined
      let cwd = ''
      let startedAt = ''
      let model: string | undefined

      try {
        const first = JSON.parse(lines[0])
        sessionId = first.sessionId
        cwd = first.cwd ?? ''
        startedAt = first.timestamp ?? ''
      } catch { /* skip unparseable first line */ }

      // Parse last few lines for current activity + model
      let currentActivity: string | undefined
      const tailLines = lines.slice(-10)
      for (let i = tailLines.length - 1; i >= 0; i--) {
        try {
          const line = JSON.parse(tailLines[i])
          if (!model && line.message?.model) {
            model = line.message.model
          }
          if (!currentActivity && line.type === 'assistant') {
            const content = line.message?.content
            if (Array.isArray(content)) {
              const toolUse = [...content].reverse().find((c: any) => c.type === 'tool_use')
              if (toolUse) {
                const input = toolUse.input
                const target = input?.file_path || input?.command || input?.pattern || ''
                currentActivity = target
                  ? `${toolUse.name} ${String(target).slice(0, 80)}`
                  : toolUse.name
              }
            }
          }
          if (model && currentActivity) break
        } catch { /* skip unparseable lines */ }
      }

      // Derive project from cwd
      const project = cwd ? cwd.split('/').pop() : undefined

      return {
        source,
        sessionId,
        project,
        cwd,
        filePath,
        startedAt,
        model,
        currentActivity,
        lastModifiedAt: new Date(mtimeMs).toISOString(),
      }
    } catch {
      return null
    }
  }
}
