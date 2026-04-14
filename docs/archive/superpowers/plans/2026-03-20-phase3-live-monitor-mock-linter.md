# Phase 3: Live Monitor, Mock Data, Config Linter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add live session monitoring, background alert system, mock data generation for development, and CLAUDE.md linting — the final four features of the Readout-inspired spec.

**Architecture:** Live session detection via file mtime scanning of WATCHED_SOURCES directories (no ps/lsof). Background monitor runs periodic health checks (cost thresholds, long sessions) and emits alerts as JSON events on stdout. Mock data injects 50 synthetic sessions into DB via `file_path LIKE '__mock__%'` sentinel. Config linter validates backtick references in CLAUDE.md files against the filesystem.

**Tech Stack:** TypeScript, SQLite (better-sqlite3), Vitest, Hono, SSE, SwiftUI

**Spec:** `docs/superpowers/specs/2026-03-20-readout-inspired-features-design.md` — Phase 3 section (Features 6-9)

---

**Note:** Line numbers in this plan are approximate reference points from the time of writing. Earlier tasks modify files, causing line numbers to drift. Use function/method names to locate insertion points.

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `src/core/live-sessions.ts` | LiveSessionMonitor class — detects active sessions via file mtime |
| `src/core/monitor.ts` | BackgroundMonitor class — periodic health checks + alert emission |
| `src/core/mock-data.ts` | Mock session generation + cleanup for development |
| `src/tools/live_sessions.ts` | MCP tool: snapshot of currently active sessions |
| `src/tools/lint_config.ts` | MCP tool: validate CLAUDE.md references against filesystem |
| `tests/core/live-sessions.test.ts` | Unit tests for LiveSessionMonitor |
| `tests/core/monitor.test.ts` | Unit tests for BackgroundMonitor |
| `tests/core/mock-data.test.ts` | Unit tests for mock data generation + cleanup |
| `tests/tools/lint_config.test.ts` | Unit tests for config linter |

### Modified Files
| File | Changes |
|------|---------|
| `src/core/config.ts:27-91` | Add `MonitorConfig` interface, `monitor` field on `FileSettings` |
| `src/daemon.ts:1-253` | Start LiveSessionMonitor + BackgroundMonitor alongside indexer/watcher, add `--mock` CLI flag |
| `src/index.ts:73-163` | Register `live_sessions` and `lint_config` MCP tools |
| `src/web.ts:60-784` | Add `/api/live`, `/api/live/stream`, `/api/monitor/alerts`, `/api/dev/mock`, `/api/lint` endpoints |
| `macos/Engram/Views/Pages/SourcePulseView.swift` | Replace source list with live session cards |
| `macos/Engram/Core/DaemonClient.swift` | Add `fetchLiveSessions()`, `fetchAlerts()`, `postMock()`, `deleteMock()`, `postLint()` |
| `macos/Engram/MenuBarController.swift:52-57` | Show live session count badge on status item |

---

### Task 1: Add MonitorConfig to FileSettings

**Files:**
- Modify: `src/core/config.ts`

- [ ] **Step 1: Add MonitorConfig interface and field**

In `src/core/config.ts`, add the `MonitorConfig` interface before `FileSettings`, then add the `monitor` field:

```typescript
// Before FileSettings interface:
export interface MonitorConfig {
  enabled: boolean
  dailyCostBudget?: number        // USD, default 20
  longSessionMinutes?: number     // default 180
  notifyOnCostThreshold?: boolean // default true
  notifyOnLongSession?: boolean   // default true
}
```

Add to `FileSettings` interface, after the `viking` field:

```typescript
  // ── Background monitor ────────────────────────────────────────────
  monitor?: MonitorConfig

  // ── Dev mode ──────────────────────────────────────────────────────
  devMode?: boolean
```

- [ ] **Step 2: Verify build**

Run: `npm run build`
Expected: Clean compile, no errors. Fields are optional so existing code is unaffected.

- [ ] **Step 3: Run existing tests**

Run: `npm test`
Expected: All existing tests pass (no behavior change, only type additions).

- [ ] **Step 4: Commit**

```bash
git add src/core/config.ts
git commit -m "feat: add MonitorConfig interface and devMode to FileSettings"
```

---

### Task 2: Create LiveSessionMonitor

**Files:**
- Create: `src/core/live-sessions.ts`
- Create: `tests/core/live-sessions.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/core/live-sessions.test.ts`:

```typescript
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest'
import { mkdirSync, writeFileSync, rmSync, utimesSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { LiveSessionMonitor, type LiveSession } from '../../src/core/live-sessions.js'

const TEST_DIR = join(tmpdir(), 'engram-live-test-' + Date.now())
const CLAUDE_DIR = join(TEST_DIR, '.claude', 'projects', 'test-project')

function createSessionFile(name: string, content: string, mtime?: Date): string {
  const filePath = join(CLAUDE_DIR, name)
  writeFileSync(filePath, content, 'utf-8')
  if (mtime) {
    utimesSync(filePath, mtime, mtime)
  }
  return filePath
}

describe('LiveSessionMonitor', () => {
  beforeAll(() => {
    mkdirSync(CLAUDE_DIR, { recursive: true })
  })

  afterAll(() => {
    rmSync(TEST_DIR, { recursive: true, force: true })
  })

  it('detects recently modified .jsonl files as live sessions', async () => {
    // Create a "live" session file (recent mtime)
    const line = JSON.stringify({
      type: 'system', subtype: 'init', sessionId: 'live-1',
      cwd: '/test/project', timestamp: new Date().toISOString(),
    })
    createSessionFile('live-session.jsonl', line + '\n')

    const monitor = new LiveSessionMonitor({
      watchDirs: [{ path: join(TEST_DIR, '.claude', 'projects'), source: 'claude-code' as any }],
      stalenessMs: 60_000,
    })
    await monitor.scan()
    const sessions = monitor.getSessions()

    expect(sessions.length).toBe(1)
    expect(sessions[0].source).toBe('claude-code')
    expect(sessions[0].filePath).toContain('live-session.jsonl')
  })

  it('excludes stale files (modified > staleness threshold ago)', async () => {
    // Create a stale file (old mtime)
    const line = JSON.stringify({
      type: 'system', subtype: 'init', sessionId: 'stale-1',
      cwd: '/test/project', timestamp: '2026-01-01T00:00:00Z',
    })
    const staleDate = new Date(Date.now() - 120_000) // 2 minutes ago
    createSessionFile('stale-session.jsonl', line + '\n', staleDate)

    const monitor = new LiveSessionMonitor({
      watchDirs: [{ path: join(TEST_DIR, '.claude', 'projects'), source: 'claude-code' as any }],
      stalenessMs: 60_000,
    })
    await monitor.scan()
    const sessions = monitor.getSessions()

    // Only the live one from previous test, not the stale one
    const staleSession = sessions.find(s => s.filePath.includes('stale-session'))
    expect(staleSession).toBeUndefined()
  })

  it('extracts currentActivity from last tool_use line', async () => {
    const lines = [
      JSON.stringify({ type: 'system', subtype: 'init', sessionId: 'activity-1', cwd: '/code/myapp', timestamp: new Date().toISOString() }),
      JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'src/auth.ts' } }] }, timestamp: new Date().toISOString() }),
    ]
    createSessionFile('activity-session.jsonl', lines.join('\n') + '\n')

    const monitor = new LiveSessionMonitor({
      watchDirs: [{ path: join(TEST_DIR, '.claude', 'projects'), source: 'claude-code' as any }],
      stalenessMs: 60_000,
    })
    await monitor.scan()
    const sessions = monitor.getSessions()
    const session = sessions.find(s => s.filePath.includes('activity-session'))
    expect(session).toBeDefined()
    expect(session!.currentActivity).toContain('Read')
  })

  it('start/stop controls polling interval', async () => {
    const monitor = new LiveSessionMonitor({
      watchDirs: [],
      stalenessMs: 60_000,
    })
    monitor.start(100_000) // very long interval, won't fire during test
    expect(monitor.isRunning()).toBe(true)
    monitor.stop()
    expect(monitor.isRunning()).toBe(false)
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/core/live-sessions.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement LiveSessionMonitor**

Create `src/core/live-sessions.ts`:

```typescript
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
              const toolUse = content.findLast?.((c: any) => c.type === 'tool_use')
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/core/live-sessions.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All existing tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add src/core/live-sessions.ts tests/core/live-sessions.test.ts
git commit -m "feat: add LiveSessionMonitor for detecting active coding sessions"
```

---

### Task 3: Create live_sessions MCP Tool

**Files:**
- Create: `src/tools/live_sessions.ts`

- [ ] **Step 1: Create MCP tool handler**

Create `src/tools/live_sessions.ts`:

```typescript
import type { LiveSessionMonitor } from '../core/live-sessions.js'

export const liveSessionsTool = {
  name: 'live_sessions',
  description: 'List currently active coding sessions detected by file activity.',
  inputSchema: {
    type: 'object' as const,
    properties: {},
    additionalProperties: false,
  },
}

export function handleLiveSessions(monitor: LiveSessionMonitor | null) {
  if (!monitor) {
    return { sessions: [], count: 0, note: 'Live session monitor not available (MCP server mode)' }
  }
  const sessions = monitor.getSessions()
  return { sessions, count: sessions.length }
}
```

- [ ] **Step 2: Verify build**

Run: `npm run build`
Expected: Clean compile.

- [ ] **Step 3: Commit**

```bash
git add src/tools/live_sessions.ts
git commit -m "feat: add live_sessions MCP tool handler"
```

---

### Task 4: Create BackgroundMonitor

**Files:**
- Create: `src/core/monitor.ts`
- Create: `tests/core/monitor.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/core/monitor.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'
import { BackgroundMonitor, type MonitorAlert } from '../../src/core/monitor.js'
import type { MonitorConfig } from '../../src/core/config.js'

describe('BackgroundMonitor', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
  })

  it('creates alerts when daily cost exceeds budget', async () => {
    // Insert a session with high cost
    db.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier)
      VALUES ('cost-s1', 'claude-code', datetime('now'), '/test', 'test', 'claude-opus-4-6', 100, 30, 50, 10, 10, '/test/s1.jsonl', 5000, 'premium')
    `)
    db.getRawDb().exec(`
      INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cost_usd, computed_at)
      VALUES ('cost-s1', 'claude-opus-4-6', 5000000, 500000, 25.50, datetime('now'))
    `)

    const config: MonitorConfig = {
      enabled: true,
      dailyCostBudget: 20,
    }
    const alerts: MonitorAlert[] = []
    const monitor = new BackgroundMonitor(db, config, (alert) => alerts.push(alert))
    await monitor.check()

    const costAlerts = alerts.filter(a => a.category === 'cost_threshold')
    expect(costAlerts.length).toBe(1)
    expect(costAlerts[0].severity).toBe('warning')
    expect(costAlerts[0].title).toContain('$20')
  })

  it('does not alert when cost is within budget', async () => {
    const freshDb = new Database(':memory:')
    freshDb.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier)
      VALUES ('low-s1', 'claude-code', datetime('now'), '/test', 'test', 'claude-sonnet-4-6', 10, 3, 5, 1, 1, '/test/low.jsonl', 500, 'normal')
    `)
    freshDb.getRawDb().exec(`
      INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cost_usd, computed_at)
      VALUES ('low-s1', 'claude-sonnet-4-6', 100000, 5000, 0.42, datetime('now'))
    `)

    const config: MonitorConfig = { enabled: true, dailyCostBudget: 20 }
    const alerts: MonitorAlert[] = []
    const monitor = new BackgroundMonitor(freshDb, config, (alert) => alerts.push(alert))
    await monitor.check()

    const costAlerts = alerts.filter(a => a.category === 'cost_threshold')
    expect(costAlerts.length).toBe(0)
  })

  it('stores and retrieves alerts', async () => {
    const config: MonitorConfig = { enabled: true, dailyCostBudget: 1 }
    const monitor = new BackgroundMonitor(db, config)
    await monitor.check()
    const alerts = monitor.getAlerts()
    expect(alerts.length).toBeGreaterThan(0)
  })

  it('dismisses alert by id', async () => {
    const config: MonitorConfig = { enabled: true, dailyCostBudget: 1 }
    const monitor = new BackgroundMonitor(db, config)
    await monitor.check()
    const alerts = monitor.getAlerts()
    const firstId = alerts[0].id
    monitor.dismissAlert(firstId)
    const after = monitor.getAlerts()
    const dismissed = after.find(a => a.id === firstId)
    expect(dismissed?.dismissed).toBe(true)
  })

  it('start/stop controls check interval', () => {
    const config: MonitorConfig = { enabled: true }
    const monitor = new BackgroundMonitor(db, config)
    monitor.start(600_000) // very long interval
    expect(monitor.isRunning()).toBe(true)
    monitor.stop()
    expect(monitor.isRunning()).toBe(false)
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/core/monitor.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement BackgroundMonitor**

Create `src/core/monitor.ts`:

```typescript
import { randomUUID } from 'crypto'
import type { Database } from './db.js'
import type { MonitorConfig } from './config.js'

export interface MonitorAlert {
  id: string
  category: 'cost_threshold' | 'long_session' | 'high_error_rate' | 'unpushed_commits'
  severity: 'info' | 'warning' | 'critical'
  title: string
  detail: string
  timestamp: string
  dismissed: boolean
}

export class BackgroundMonitor {
  private alerts: MonitorAlert[] = []
  private interval: ReturnType<typeof setInterval> | null = null
  private db: Database
  private config: MonitorConfig
  private onAlert?: (alert: MonitorAlert) => void

  constructor(db: Database, config: MonitorConfig, onAlert?: (alert: MonitorAlert) => void) {
    this.db = db
    this.config = config
    this.onAlert = onAlert
  }

  start(intervalMs = 600_000): void {
    if (this.interval) return
    this.interval = setInterval(() => this.check().catch(() => {}), intervalMs)
    // Run initial check after a short delay (don't block startup)
    setTimeout(() => this.check().catch(() => {}), 10_000)
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

  getAlerts(): MonitorAlert[] {
    return [...this.alerts]
  }

  dismissAlert(id: string): void {
    const alert = this.alerts.find(a => a.id === id)
    if (alert) alert.dismissed = true
  }

  async check(): Promise<void> {
    await this.checkDailyCost()
    await this.checkUnpushedCommits()
  }

  private async checkDailyCost(): Promise<void> {
    const budget = this.config.dailyCostBudget ?? 20
    try {
      const row = this.db.getRawDb().prepare(`
        SELECT COALESCE(SUM(c.cost_usd), 0) as totalCost
        FROM session_costs c
        JOIN sessions s ON c.session_id = s.id
        WHERE date(s.start_time) = date('now')
      `).get() as { totalCost: number } | undefined

      const totalCost = row?.totalCost ?? 0
      if (totalCost > budget) {
        // Only alert if we haven't already alerted for this threshold today
        const existingToday = this.alerts.find(
          a => a.category === 'cost_threshold' && a.timestamp.startsWith(new Date().toISOString().slice(0, 10))
        )
        if (!existingToday) {
          const alert: MonitorAlert = {
            id: randomUUID(),
            category: 'cost_threshold',
            severity: totalCost > budget * 2 ? 'critical' : 'warning',
            title: `Daily cost exceeded $${budget}`,
            detail: `Current daily spend: $${totalCost.toFixed(2)} (budget: $${budget})`,
            timestamp: new Date().toISOString(),
            dismissed: false,
          }
          this.alerts.push(alert)
          this.onAlert?.(alert)
        }
      }
    } catch { /* session_costs table may not exist yet */ }
  }

  private async checkUnpushedCommits(): Promise<void> {
    try {
      const rows = this.db.getRawDb().prepare(`
        SELECT name, path, unpushed_count FROM git_repos
        WHERE unpushed_count > 10
      `).all() as Array<{ name: string; path: string; unpushed_count: number }>

      for (const row of rows) {
        const existingForRepo = this.alerts.find(
          a => a.category === 'unpushed_commits' && a.detail.includes(row.path) && !a.dismissed
        )
        if (!existingForRepo) {
          const alert: MonitorAlert = {
            id: randomUUID(),
            category: 'unpushed_commits',
            severity: 'warning',
            title: `${row.name}: ${row.unpushed_count} unpushed commits`,
            detail: `Repository at ${row.path} has ${row.unpushed_count} unpushed commits`,
            timestamp: new Date().toISOString(),
            dismissed: false,
          }
          this.alerts.push(alert)
          this.onAlert?.(alert)
        }
      }
    } catch { /* git_repos table may not exist yet */ }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/core/monitor.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All existing tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add src/core/monitor.ts tests/core/monitor.test.ts
git commit -m "feat: add BackgroundMonitor for cost threshold and health alerts"
```

---

### Task 5: Create Mock Data Generator

**Files:**
- Create: `src/core/mock-data.ts`
- Create: `tests/core/mock-data.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/core/mock-data.test.ts`:

```typescript
import { describe, it, expect, beforeAll, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import { populateMockData, clearMockData } from '../../src/core/mock-data.js'

describe('mock-data', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
  })

  afterEach(() => {
    clearMockData(db)
  })

  it('populates 50 mock sessions', async () => {
    const stats = await populateMockData(db)
    expect(stats.sessions).toBe(50)
    expect(stats.costUsd).toBeGreaterThan(0)
    expect(stats.tools).toBeGreaterThan(0)
  })

  it('mock sessions have __mock__ prefix in file_path', async () => {
    await populateMockData(db)
    const rows = db.getRawDb().prepare(
      "SELECT COUNT(*) as count FROM sessions WHERE file_path LIKE '__mock__%'"
    ).get() as { count: number }
    expect(rows.count).toBe(50)
  })

  it('mock sessions span multiple sources', async () => {
    await populateMockData(db)
    const sources = db.getRawDb().prepare(
      "SELECT DISTINCT source FROM sessions WHERE file_path LIKE '__mock__%'"
    ).all() as { source: string }[]
    expect(sources.length).toBeGreaterThanOrEqual(3)
  })

  it('mock sessions have cost data in session_costs', async () => {
    await populateMockData(db)
    const costs = db.getRawDb().prepare(`
      SELECT COUNT(*) as count FROM session_costs c
      JOIN sessions s ON c.session_id = s.id
      WHERE s.file_path LIKE '__mock__%'
    `).get() as { count: number }
    expect(costs.count).toBe(50)
  })

  it('mock sessions have tool data in session_tools', async () => {
    await populateMockData(db)
    const tools = db.getRawDb().prepare(`
      SELECT COUNT(DISTINCT t.session_id) as count FROM session_tools t
      JOIN sessions s ON t.session_id = s.id
      WHERE s.file_path LIKE '__mock__%'
    `).get() as { count: number }
    expect(tools.count).toBe(50)
  })

  it('clearMockData removes all mock sessions', async () => {
    await populateMockData(db)
    const cleared = clearMockData(db)
    expect(cleared).toBe(50)

    const remaining = db.getRawDb().prepare(
      "SELECT COUNT(*) as count FROM sessions WHERE file_path LIKE '__mock__%'"
    ).get() as { count: number }
    expect(remaining.count).toBe(0)
  })

  it('clearMockData cascades to session_costs and session_tools', async () => {
    await populateMockData(db)
    clearMockData(db)

    const costs = db.getRawDb().prepare(`
      SELECT COUNT(*) as count FROM session_costs c
      WHERE NOT EXISTS (SELECT 1 FROM sessions s WHERE s.id = c.session_id)
    `).get() as { count: number }
    expect(costs.count).toBe(0)
  })

  it('does not affect non-mock sessions', async () => {
    // Insert a real session first
    db.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier)
      VALUES ('real-1', 'claude-code', datetime('now'), '/real', 'real-project', 'claude-sonnet-4-6', 10, 3, 5, 1, 1, '/real/session.jsonl', 1000, 'normal')
    `)

    await populateMockData(db)
    clearMockData(db)

    const realSession = db.getSession('real-1')
    expect(realSession).toBeDefined()
    expect(realSession!.filePath).toBe('/real/session.jsonl')
  })

  it('mock sessions use 5 fictional projects', async () => {
    await populateMockData(db)
    const projects = db.getRawDb().prepare(
      "SELECT DISTINCT project FROM sessions WHERE file_path LIKE '__mock__%'"
    ).all() as { project: string }[]
    expect(projects.length).toBe(5)
  })

  it('mock sessions have diverse tiers', async () => {
    await populateMockData(db)
    const tiers = db.getRawDb().prepare(
      "SELECT DISTINCT tier FROM sessions WHERE file_path LIKE '__mock__%'"
    ).all() as { tier: string }[]
    expect(tiers.length).toBeGreaterThanOrEqual(3)
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/core/mock-data.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement mock data generator**

Create `src/core/mock-data.ts`:

```typescript
import { randomUUID } from 'crypto'
import type { Database } from './db.js'
import { computeCost } from './pricing.js'

export interface MockStats {
  sessions: number
  tools: number
  costUsd: number
}

const MOCK_SOURCES = [
  { name: 'claude-code', weight: 0.40 },
  { name: 'codex', weight: 0.15 },
  { name: 'gemini-cli', weight: 0.10 },
  { name: 'cursor', weight: 0.10 },
  { name: 'iflow', weight: 0.08 },
  { name: 'qwen', weight: 0.07 },
  { name: 'kimi', weight: 0.05 },
  { name: 'cline', weight: 0.05 },
] as const

const MOCK_PROJECTS = ['weather-api', 'chat-app', 'ml-pipeline', 'docs-site', 'infra-tools']

const MOCK_MODELS = [
  { name: 'claude-sonnet-4-6', weight: 0.50 },
  { name: 'claude-opus-4-6', weight: 0.20 },
  { name: 'gpt-4o', weight: 0.15 },
  { name: 'gemini-2.0-flash', weight: 0.15 },
] as const

const MOCK_TIERS = [
  { name: 'normal', weight: 0.60 },
  { name: 'lite', weight: 0.20 },
  { name: 'premium', weight: 0.10 },
  { name: 'skip', weight: 0.10 },
] as const

const MOCK_TOOLS = [
  { name: 'Read', weight: 0.30 },
  { name: 'Bash', weight: 0.25 },
  { name: 'Edit', weight: 0.15 },
  { name: 'Write', weight: 0.10 },
  { name: 'Grep', weight: 0.08 },
  { name: 'Glob', weight: 0.05 },
  { name: 'WebSearch', weight: 0.04 },
  { name: 'Skill', weight: 0.03 },
] as const

const MOCK_SUMMARIES = [
  'Implemented authentication middleware with JWT token validation',
  'Refactored database connection pooling for better performance',
  'Fixed race condition in WebSocket event handler',
  'Added pagination to the session list API endpoint',
  'Migrated from CommonJS to ES modules across the project',
  'Debugged memory leak in the file watcher component',
  'Created unit tests for the pricing computation module',
  'Optimized SQLite queries with proper indexing strategy',
  'Built CLI tool for batch processing session exports',
  'Resolved CORS issues in the development proxy setup',
  'Implemented SSE endpoint for real-time session updates',
  'Added graceful shutdown with cleanup of open connections',
  'Configured CI pipeline with automated test coverage reporting',
  'Designed and implemented the background alert monitoring system',
  'Integrated semantic search with vector embeddings for sessions',
]

function weightedRandom<T extends { weight: number }>(items: readonly T[]): T {
  const total = items.reduce((sum, item) => sum + item.weight, 0)
  let r = Math.random() * total
  for (const item of items) {
    r -= item.weight
    if (r <= 0) return item
  }
  return items[items.length - 1]
}

function randomInt(min: number, max: number): number {
  return Math.floor(Math.random() * (max - min + 1)) + min
}

function randomDate(daysBack: number): Date {
  const now = Date.now()
  const offset = Math.random() * daysBack * 24 * 60 * 60 * 1000
  return new Date(now - offset)
}

export async function populateMockData(db: Database): Promise<MockStats> {
  const rawDb = db.getRawDb()
  const SESSION_COUNT = 50
  let totalCost = 0
  let totalToolEntries = 0

  const insertSession = rawDb.prepare(`
    INSERT INTO sessions (id, source, start_time, end_time, cwd, project, model,
      message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count,
      summary, file_path, size_bytes, indexed_at, origin, tier)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), 'local', ?)
  `)

  const insertCost = rawDb.prepare(`
    INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, computed_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
  `)

  const insertTool = rawDb.prepare(`
    INSERT INTO session_tools (session_id, tool_name, call_count)
    VALUES (?, ?, ?)
  `)

  const insertAll = rawDb.transaction(() => {
    for (let i = 0; i < SESSION_COUNT; i++) {
      const id = `mock-${randomUUID()}`
      const source = weightedRandom(MOCK_SOURCES).name
      const project = MOCK_PROJECTS[randomInt(0, MOCK_PROJECTS.length - 1)]
      const model = weightedRandom(MOCK_MODELS).name
      const tier = weightedRandom(MOCK_TIERS).name

      const startDate = randomDate(30)
      const durationMinutes = randomInt(5, 240)
      const endDate = new Date(startDate.getTime() + durationMinutes * 60 * 1000)

      const messageCount = randomInt(5, 200)
      const userMsgCount = Math.floor(messageCount * 0.3)
      const assistantMsgCount = Math.floor(messageCount * 0.45)
      const toolMsgCount = Math.floor(messageCount * 0.2)
      const systemMsgCount = messageCount - userMsgCount - assistantMsgCount - toolMsgCount

      const summary = MOCK_SUMMARIES[randomInt(0, MOCK_SUMMARIES.length - 1)]
      const cwd = `/Users/dev/projects/${project}`
      const filePath = `__mock__/${id}.jsonl`
      const sizeBytes = randomInt(5000, 500000)

      insertSession.run(
        id, source, startDate.toISOString(), endDate.toISOString(),
        cwd, project, model,
        messageCount, userMsgCount, assistantMsgCount, toolMsgCount, systemMsgCount,
        summary, filePath, sizeBytes, tier
      )

      // Generate cost data
      const inputTokens = messageCount * randomInt(500, 3000)
      const outputTokens = messageCount * randomInt(50, 500)
      const cacheReadTokens = Math.floor(inputTokens * Math.random() * 0.8)
      const cacheCreationTokens = Math.floor(inputTokens * Math.random() * 0.3)
      const cost = computeCost(model, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)
      totalCost += cost

      insertCost.run(id, model, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, cost)

      // Generate tool data (3-8 different tools per session)
      const toolCount = randomInt(3, 8)
      const usedTools = new Set<string>()
      for (let j = 0; j < toolCount; j++) {
        const tool = weightedRandom(MOCK_TOOLS)
        if (usedTools.has(tool.name)) continue
        usedTools.add(tool.name)
        const callCount = randomInt(1, Math.floor(messageCount * 0.3) + 1)
        insertTool.run(id, tool.name, callCount)
        totalToolEntries++
      }
    }
  })

  insertAll()

  return {
    sessions: SESSION_COUNT,
    tools: totalToolEntries,
    costUsd: Math.round(totalCost * 100) / 100,
  }
}

export function clearMockData(db: Database): number {
  const rawDb = db.getRawDb()
  // Foreign key cascading handles session_costs and session_tools
  const result = rawDb.prepare("DELETE FROM sessions WHERE file_path LIKE '__mock__%'").run()
  return result.changes
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/core/mock-data.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All existing tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add src/core/mock-data.ts tests/core/mock-data.test.ts
git commit -m "feat: add mock data generator with 50 realistic sessions across sources"
```

---

### Task 6: Create CLAUDE.md Config Linter

**Files:**
- Create: `src/tools/lint_config.ts`
- Create: `tests/tools/lint_config.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/tools/lint_config.test.ts`:

```typescript
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { mkdirSync, writeFileSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { handleLintConfig, extractBacktickRefs, looksLikeFilePath, looksLikeNpmScript } from '../../src/tools/lint_config.js'

const TEST_DIR = join(tmpdir(), 'engram-lint-test-' + Date.now())

describe('lint_config', () => {
  beforeAll(() => {
    mkdirSync(join(TEST_DIR, '.claude'), { recursive: true })
    mkdirSync(join(TEST_DIR, 'src'), { recursive: true })

    // Create a real source file
    writeFileSync(join(TEST_DIR, 'src', 'index.ts'), 'export default {}', 'utf-8')

    // Create package.json with scripts
    writeFileSync(join(TEST_DIR, 'package.json'), JSON.stringify({
      scripts: { build: 'tsc', test: 'vitest', dev: 'tsx src/index.ts' },
    }), 'utf-8')

    // Create CLAUDE.md with mixed valid and invalid references
    writeFileSync(join(TEST_DIR, 'CLAUDE.md'), [
      '# Project Config',
      '',
      'Run `npm run build` to compile.',
      'Run `npm run deploy` to deploy.',
      'Edit `src/index.ts` for the entry point.',
      'See `src/nonexistent.ts` for details.',
      'The `Database` class handles persistence.',
    ].join('\n'), 'utf-8')
  })

  afterAll(() => {
    rmSync(TEST_DIR, { recursive: true, force: true })
  })

  describe('extractBacktickRefs', () => {
    it('extracts backtick-wrapped references', () => {
      const refs = extractBacktickRefs('Run `npm run build` and edit `src/foo.ts`')
      expect(refs).toContain('npm run build')
      expect(refs).toContain('src/foo.ts')
    })

    it('handles no backticks', () => {
      expect(extractBacktickRefs('no backticks here')).toEqual([])
    })

    it('handles empty backticks', () => {
      expect(extractBacktickRefs('empty ``')).toEqual([])
    })
  })

  describe('looksLikeFilePath', () => {
    it('recognizes file paths with extensions', () => {
      expect(looksLikeFilePath('src/index.ts')).toBe(true)
      expect(looksLikeFilePath('macos/Engram/Views/Page.swift')).toBe(true)
      expect(looksLikeFilePath('package.json')).toBe(true)
    })

    it('recognizes directory paths', () => {
      expect(looksLikeFilePath('src/')).toBe(true)
      expect(looksLikeFilePath('macos/Engram/')).toBe(true)
    })

    it('rejects non-path strings', () => {
      expect(looksLikeFilePath('npm run build')).toBe(false)
      expect(looksLikeFilePath('Database')).toBe(false)
      expect(looksLikeFilePath('true')).toBe(false)
    })
  })

  describe('looksLikeNpmScript', () => {
    it('recognizes npm run commands', () => {
      expect(looksLikeNpmScript('npm run build')).toBe('build')
      expect(looksLikeNpmScript('npm test')).toBe('test')
      expect(looksLikeNpmScript('npm run dev')).toBe('dev')
    })

    it('returns null for non-npm commands', () => {
      expect(looksLikeNpmScript('git status')).toBeNull()
      expect(looksLikeNpmScript('src/index.ts')).toBeNull()
    })
  })

  describe('handleLintConfig', () => {
    it('finds broken file references', async () => {
      const result = await handleLintConfig({ cwd: TEST_DIR })
      const fileErrors = result.issues.filter(i => i.message.includes('src/nonexistent.ts'))
      expect(fileErrors.length).toBe(1)
      expect(fileErrors[0].severity).toBe('error')
    })

    it('finds broken npm script references', async () => {
      const result = await handleLintConfig({ cwd: TEST_DIR })
      const npmWarnings = result.issues.filter(i => i.message.includes('deploy'))
      expect(npmWarnings.length).toBe(1)
      expect(npmWarnings[0].severity).toBe('warning')
    })

    it('does not flag valid references', async () => {
      const result = await handleLintConfig({ cwd: TEST_DIR })
      const validFile = result.issues.filter(i => i.message.includes('src/index.ts'))
      expect(validFile.length).toBe(0)
      const validScript = result.issues.filter(i => i.message.includes('npm run build') && i.message.includes('not found'))
      expect(validScript.length).toBe(0)
    })

    it('computes score correctly', async () => {
      const result = await handleLintConfig({ cwd: TEST_DIR })
      // 1 error (-10) + 1 warning (-3) = 87
      expect(result.score).toBe(87)
    })

    it('returns score of 100 for clean config', async () => {
      const cleanDir = join(tmpdir(), 'engram-lint-clean-' + Date.now())
      mkdirSync(join(cleanDir, 'src'), { recursive: true })
      writeFileSync(join(cleanDir, 'src', 'app.ts'), 'export {}', 'utf-8')
      writeFileSync(join(cleanDir, 'package.json'), JSON.stringify({ scripts: { build: 'tsc' } }), 'utf-8')
      writeFileSync(join(cleanDir, 'CLAUDE.md'), 'Run `npm run build` to compile.\nEdit `src/app.ts` for the entry.', 'utf-8')

      const result = await handleLintConfig({ cwd: cleanDir })
      expect(result.score).toBe(100)

      rmSync(cleanDir, { recursive: true, force: true })
    })

    it('returns empty issues when no config files exist', async () => {
      const emptyDir = join(tmpdir(), 'engram-lint-empty-' + Date.now())
      mkdirSync(emptyDir, { recursive: true })

      const result = await handleLintConfig({ cwd: emptyDir })
      expect(result.issues).toEqual([])
      expect(result.score).toBe(100)

      rmSync(emptyDir, { recursive: true, force: true })
    })
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/tools/lint_config.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement config linter**

Create `src/tools/lint_config.ts`:

```typescript
import { readFileSync, existsSync, readdirSync } from 'fs'
import { join, extname, dirname, basename } from 'path'

export const lintConfigTool = {
  name: 'lint_config',
  description: 'Lint CLAUDE.md and similar config files: verify file references exist, npm scripts are valid, and detect stale instructions.',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: 'Project root directory' },
    },
    additionalProperties: false,
  },
}

export interface LintIssue {
  file: string
  line: number
  severity: 'error' | 'warning' | 'info'
  message: string
  suggestion?: string
}

/**
 * Extract backtick-wrapped references from a line of text.
 * Returns the content between each pair of backticks.
 */
export function extractBacktickRefs(line: string): string[] {
  const refs: string[] = []
  const regex = /`([^`]+)`/g
  let match
  while ((match = regex.exec(line)) !== null) {
    const content = match[1].trim()
    if (content.length > 0) refs.push(content)
  }
  return refs
}

/**
 * Check if a string looks like a file or directory path.
 */
export function looksLikeFilePath(ref: string): boolean {
  // Must contain a slash or have a recognized extension
  if (ref.includes(' ') && !ref.includes('/')) return false
  if (ref.endsWith('/')) return true

  const ext = extname(ref)
  if (ext && ext.length > 1 && ext.length <= 8) return true

  // Has a slash separator (like src/foo or macos/bar)
  if (ref.includes('/') && !ref.startsWith('-') && !ref.includes(' ')) return true

  return false
}

/**
 * Check if a string looks like an npm script reference.
 * Returns the script name if it does, null otherwise.
 */
export function looksLikeNpmScript(ref: string): string | null {
  // npm run <script>
  const runMatch = ref.match(/^npm\s+run\s+(\S+)/)
  if (runMatch) return runMatch[1]

  // npm <builtin> (test, start, stop, restart)
  const builtinMatch = ref.match(/^npm\s+(test|start|stop|restart)(?:\s|$)/)
  if (builtinMatch) return builtinMatch[1]

  return null
}

/**
 * Find config files in the project root and .claude directory.
 */
function findConfigFiles(cwd: string): string[] {
  const candidates = [
    join(cwd, 'CLAUDE.md'),
    join(cwd, '.claude', 'CLAUDE.md'),
    join(cwd, 'AGENTS.md'),
    join(cwd, '.cursorrules'),
    join(cwd, '.github', 'copilot-instructions.md'),
  ]
  return candidates.filter(f => existsSync(f))
}

/**
 * Try to find a similar file in the project directory.
 * Returns the closest match or undefined.
 */
function findSimilarFile(cwd: string, ref: string): string | undefined {
  const dir = dirname(join(cwd, ref))
  const name = basename(ref)

  try {
    if (!existsSync(dir)) return undefined
    const entries = readdirSync(dir)
    const nameLower = name.toLowerCase()

    // Exact case-insensitive match
    const caseMatch = entries.find(e => e.toLowerCase() === nameLower)
    if (caseMatch) {
      const relative = join(dirname(ref), caseMatch)
      return relative
    }

    // Extension swap (e.g., .ts → .tsx, .js → .ts)
    const base = name.replace(extname(name), '')
    const ext = extname(name)
    const swaps: Record<string, string[]> = {
      '.ts': ['.tsx', '.js', '.mjs'],
      '.tsx': ['.ts', '.jsx'],
      '.js': ['.ts', '.mjs', '.cjs'],
      '.jsx': ['.tsx', '.js'],
      '.swift': ['.m', '.mm'],
    }
    const alternatives = swaps[ext] ?? []
    for (const alt of alternatives) {
      const altName = base + alt
      if (entries.includes(altName)) {
        return join(dirname(ref), altName)
      }
    }
  } catch { /* directory may not be readable */ }

  return undefined
}

/**
 * Read package.json scripts from the project root.
 */
function readPackageJsonScripts(cwd: string): Record<string, string> | null {
  try {
    const pkgPath = join(cwd, 'package.json')
    if (!existsSync(pkgPath)) return null
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf-8'))
    return pkg.scripts ?? {}
  } catch {
    return null
  }
}

export async function handleLintConfig(params: { cwd: string }): Promise<{ issues: LintIssue[]; score: number }> {
  const { cwd } = params
  const issues: LintIssue[] = []
  const configFiles = findConfigFiles(cwd)
  const scripts = readPackageJsonScripts(cwd)

  for (const configFile of configFiles) {
    let content: string
    try {
      content = readFileSync(configFile, 'utf-8')
    } catch {
      continue
    }

    const lines = content.split('\n')
    // Track if we're inside a fenced code block
    let inCodeBlock = false

    for (const [lineNum, line] of lines.entries()) {
      // Toggle code block state on fence markers
      if (line.trimStart().startsWith('```')) {
        inCodeBlock = !inCodeBlock
        continue
      }
      // Skip lines inside code blocks — references there are examples, not instructions
      if (inCodeBlock) continue

      const refs = extractBacktickRefs(line)

      for (const ref of refs) {
        // Check file references
        if (looksLikeFilePath(ref)) {
          const fullPath = join(cwd, ref)
          if (!existsSync(fullPath)) {
            const suggestion = findSimilarFile(cwd, ref)
            issues.push({
              file: configFile,
              line: lineNum + 1,
              severity: 'error',
              message: `Referenced file \`${ref}\` does not exist`,
              suggestion: suggestion ? `Did you mean \`${suggestion}\`?` : undefined,
            })
          }
        }

        // Check npm script references
        const scriptName = looksLikeNpmScript(ref)
        if (scriptName && scripts !== null) {
          if (!scripts[scriptName]) {
            issues.push({
              file: configFile,
              line: lineNum + 1,
              severity: 'warning',
              message: `npm script \`${scriptName}\` not found in package.json`,
            })
          }
        }
      }
    }
  }

  // Score: 100 - (errors * 10) - (warnings * 3) - (info * 1), min 0
  const score = Math.max(0, 100 - issues.reduce((s, i) =>
    s + (i.severity === 'error' ? 10 : i.severity === 'warning' ? 3 : 1), 0))

  return { issues, score }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/tools/lint_config.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All existing tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add src/tools/lint_config.ts tests/tools/lint_config.test.ts
git commit -m "feat: add CLAUDE.md config linter with file and npm script validation"
```

---

### Task 7: Register MCP Tools in index.ts

**Files:**
- Modify: `src/index.ts`

- [ ] **Step 1: Add imports**

At the top of `src/index.ts`, after the existing tool imports (around line 29):

```typescript
import { liveSessionsTool, handleLiveSessions } from './tools/live_sessions.js'
import { lintConfigTool, handleLintConfig } from './tools/lint_config.js'
```

- [ ] **Step 2: Register tools in allTools array**

Add to the `allTools` array (around line 73-85):

```typescript
  liveSessionsTool,
  lintConfigTool,
```

- [ ] **Step 3: Add tool handlers in CallToolRequestSchema**

Add to the if-else chain in the CallToolRequestSchema handler (before the `else` branch with "Unknown tool"):

```typescript
    } else if (name === 'live_sessions') {
      result = handleLiveSessions(null) // No live monitor in MCP server mode
    } else if (name === 'lint_config') {
      if (!a.cwd) return { content: [{ type: 'text', text: 'cwd parameter required' }], isError: true }
      result = await handleLintConfig({ cwd: a.cwd as string })
    }
```

- [ ] **Step 4: Verify build**

Run: `npm run build`
Expected: Clean compile.

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/index.ts
git commit -m "feat: register live_sessions and lint_config MCP tools"
```

---

### Task 8: Add Web API Endpoints

**Files:**
- Modify: `src/web.ts`

- [ ] **Step 1: Add imports**

At the top of `src/web.ts`, add:

```typescript
import type { LiveSessionMonitor } from './core/live-sessions.js'
import type { BackgroundMonitor } from './core/monitor.js'
import { populateMockData, clearMockData } from './core/mock-data.js'
import { handleLintConfig } from './tools/lint_config.js'
```

- [ ] **Step 2: Extend createApp options**

In the `createApp` function signature, add to the options type:

```typescript
  liveMonitor?: LiveSessionMonitor
  backgroundMonitor?: BackgroundMonitor
```

- [ ] **Step 3: Add live sessions endpoints**

After the existing API routes (before `return app`), add:

```typescript
  // --- Live Sessions API ---
  app.get('/api/live', (c) => {
    const sessions = opts?.liveMonitor?.getSessions() ?? []
    return c.json({ sessions, count: sessions.length })
  })

  app.get('/api/live/stream', (c) => {
    // SSE endpoint — push live session updates every 5 seconds
    const stream = new ReadableStream({
      start(controller) {
        const encoder = new TextEncoder()
        const send = () => {
          try {
            const sessions = opts?.liveMonitor?.getSessions() ?? []
            const data = JSON.stringify({ sessions, count: sessions.length })
            controller.enqueue(encoder.encode(`event: update\ndata: ${data}\n\n`))
          } catch {
            // Client disconnected
          }
        }
        send() // immediate first push
        const interval = setInterval(send, 5000)

        // Cleanup on abort
        c.req.raw.signal.addEventListener('abort', () => {
          clearInterval(interval)
          try { controller.close() } catch { /* already closed */ }
        })
      },
    })

    return new Response(stream, {
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      },
    })
  })
```

- [ ] **Step 4: Add monitor alerts endpoint**

```typescript
  // --- Monitor Alerts API ---
  app.get('/api/monitor/alerts', (c) => {
    const alerts = opts?.backgroundMonitor?.getAlerts() ?? []
    const undismissed = alerts.filter(a => !a.dismissed)
    return c.json({ alerts: undismissed, total: alerts.length })
  })

  app.post('/api/monitor/alerts/:id/dismiss', (c) => {
    const id = c.req.param('id')
    opts?.backgroundMonitor?.dismissAlert(id)
    return c.json({ dismissed: id })
  })
```

- [ ] **Step 5: Add mock data endpoints (dev mode only)**

```typescript
  // --- Dev Mode API ---
  app.post('/api/dev/mock', async (c) => {
    if (!settings.devMode) return c.json({ error: 'Dev mode not enabled' }, 403)
    const stats = await populateMockData(db)
    return c.json(stats)
  })

  app.delete('/api/dev/mock', (c) => {
    if (!settings.devMode) return c.json({ error: 'Dev mode not enabled' }, 403)
    const cleared = clearMockData(db)
    return c.json({ cleared })
  })
```

- [ ] **Step 6: Add lint endpoint**

```typescript
  // --- Config Linter API ---
  app.post('/api/lint', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    const cwd = (body as Record<string, unknown>).cwd as string | undefined
    if (!cwd) return c.json({ error: 'cwd required' }, 400)
    const result = await handleLintConfig({ cwd })
    return c.json(result)
  })
```

- [ ] **Step 7: Verify build**

Run: `npm run build`
Expected: Clean compile.

- [ ] **Step 8: Run full test suite**

Run: `npm test`
Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add src/web.ts
git commit -m "feat: add /api/live, /api/monitor/alerts, /api/dev/mock, /api/lint endpoints"
```

---

### Task 9: Integrate into Daemon Startup

**Files:**
- Modify: `src/daemon.ts`

- [ ] **Step 1: Add imports**

At the top of `src/daemon.ts`, add:

```typescript
import { LiveSessionMonitor, type WatchDir } from './core/live-sessions.js'
import { BackgroundMonitor } from './core/monitor.js'
import { populateMockData } from './core/mock-data.js'
```

- [ ] **Step 2: Build watch directories from WATCHED_SOURCES**

After the `const settings = readFileSettings()` line (around line 24), add:

```typescript
// Build watch directories for live session detection
const watchDirs: WatchDir[] = [
  { path: join(homedir(), '.codex', 'sessions'), source: 'codex' },
  { path: join(homedir(), '.claude', 'projects'), source: 'claude-code' },
  { path: join(homedir(), '.gemini', 'tmp'), source: 'gemini-cli' },
  { path: join(homedir(), '.gemini', 'antigravity'), source: 'antigravity' },
  { path: join(homedir(), '.iflow', 'projects'), source: 'iflow' },
  { path: join(homedir(), '.qwen', 'projects'), source: 'qwen' },
  { path: join(homedir(), '.kimi', 'sessions'), source: 'kimi' },
  { path: join(homedir(), '.cline', 'data', 'tasks'), source: 'cline' },
]
```

Add `import { homedir } from 'os'` at the top if not already imported (check existing imports from bootstrap.js — the `join` import from 'path' is already there).

- [ ] **Step 3: Create and start LiveSessionMonitor**

After the watcher startup (around line 173), add:

```typescript
// Live session monitor — detects active coding sessions via file mtime
const liveMonitor = new LiveSessionMonitor({ watchDirs })
liveMonitor.start(5000)
```

- [ ] **Step 4: Create and start BackgroundMonitor**

After the live monitor:

```typescript
// Background monitor — periodic health checks + alerts
const monitorConfig = settings.monitor ?? { enabled: true }
const backgroundMonitor = new BackgroundMonitor(db, monitorConfig, (alert) => {
  emit({ event: 'alert', alert })
})
if (monitorConfig.enabled) {
  backgroundMonitor.start(600_000) // every 10 minutes
}
```

- [ ] **Step 5: Pass monitors to createApp**

Update the `createApp` call to include the new monitors:

```typescript
const app = createApp(db, {
  vectorStore: vecDeps?.vectorStore,
  embeddingClient: vecDeps?.embeddingClient,
  syncEngine,
  syncPeers,
  settings,
  adapters,
  viking: vikingBridge,
  usageCollector,
  titleGenerator,
  liveMonitor,
  backgroundMonitor,
})
```

- [ ] **Step 6: Add --mock CLI flag handling**

Before the initial full scan (`indexer.indexAll().then(...)`), add:

```typescript
// Handle --mock flag for development
if (process.argv.includes('--mock')) {
  populateMockData(db).then(stats => {
    emit({ event: 'mock_data', ...stats })
  }).catch(err => {
    emit({ event: 'error', message: `Mock data failed: ${String(err)}` })
  })
}
```

- [ ] **Step 7: Update shutdown handler**

In the `shutdown()` function, add cleanup for the new monitors:

```typescript
function shutdown() {
  clearInterval(rescanTimer)
  if (syncTimer) clearInterval(syncTimer)
  clearInterval(gitProbeTimer)
  liveMonitor.stop()
  backgroundMonitor.stop()
  autoSummary?.cleanup()
  watcher?.close()
  webServer.close()
  db.close()
  process.exit(0)
}
```

- [ ] **Step 8: Verify build**

Run: `npm run build`
Expected: Clean compile.

- [ ] **Step 9: Run full test suite**

Run: `npm test`
Expected: All tests pass.

- [ ] **Step 10: Commit**

```bash
git add src/daemon.ts
git commit -m "feat: start LiveSessionMonitor + BackgroundMonitor in daemon, add --mock flag"
```

---

### Task 10: Update SourcePulseView with Live Session Cards

**Files:**
- Modify: `macos/Engram/Views/Pages/SourcePulseView.swift`

- [ ] **Step 1: Add LiveSession model to DaemonClient.swift**

In `macos/Engram/Core/DaemonClient.swift`, add the response types:

```swift
struct LiveSessionResponse: Decodable {
    let sessions: [LiveSession]
    let count: Int
}

struct LiveSession: Decodable, Identifiable {
    var id: String { filePath }
    let source: String
    let sessionId: String?
    let project: String?
    let cwd: String
    let filePath: String
    let startedAt: String
    let model: String?
    let currentActivity: String?
    let lastModifiedAt: String
}

struct AlertResponse: Decodable {
    let alerts: [MonitorAlertItem]
    let total: Int
}

struct MonitorAlertItem: Decodable, Identifiable {
    let id: String
    let category: String
    let severity: String
    let title: String
    let detail: String
    let timestamp: String
    let dismissed: Bool
}

struct MockStats: Decodable {
    let sessions: Int
    let tools: Int
    let costUsd: Double
}

struct LintResult: Decodable {
    let issues: [LintIssue]
    let score: Int
}

struct LintIssue: Decodable, Identifiable {
    var id: String { "\(file):\(line):\(message)" }
    let file: String
    let line: Int
    let severity: String
    let message: String
    let suggestion: String?
}
```

- [ ] **Step 2: Add API methods to DaemonClient**

Add methods to `DaemonClient`:

```swift
func fetchLiveSessions() async throws -> LiveSessionResponse {
    return try await fetch("/api/live")
}

func fetchAlerts() async throws -> AlertResponse {
    return try await fetch("/api/monitor/alerts")
}

func dismissAlert(id: String) async throws {
    let url = URL(string: "\(baseURL)/api/monitor/alerts/\(id)/dismiss")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode) else {
        throw DaemonClientError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

func postMock() async throws -> MockStats {
    let url = URL(string: "\(baseURL)/api/dev/mock")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode) else {
        throw DaemonClientError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    return try JSONDecoder().decode(MockStats.self, from: data)
}

func deleteMock() async throws -> Int {
    let url = URL(string: "\(baseURL)/api/dev/mock")!
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode) else {
        throw DaemonClientError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    let result = try JSONDecoder().decode([String: Int].self, from: data)
    return result["cleared"] ?? 0
}

func postLint(cwd: String) async throws -> LintResult {
    let url = URL(string: "\(baseURL)/api/lint")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["cwd": cwd])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode) else {
        throw DaemonClientError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    return try JSONDecoder().decode(LintResult.self, from: data)
}
```

- [ ] **Step 3: Rewrite SourcePulseView with live session cards**

Replace the contents of `macos/Engram/Views/Pages/SourcePulseView.swift`:

```swift
// macos/Engram/Views/Pages/SourcePulseView.swift
import SwiftUI

struct SourcePulseView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var daemonClient: DaemonClient

    @State private var liveSessions: [LiveSession] = []
    @State private var sources: [SourceInfo] = []
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var isLoading = true
    @State private var error: String? = nil

    private var totalIndexed: Int { sources.reduce(0) { $0 + $1.sessionCount } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // KPI row
                HStack(spacing: 12) {
                    KPICard(value: "\(liveSessions.count)", label: "Live Sessions")
                    KPICard(value: "\(sources.count)", label: "Active Sources")
                    KPICard(value: formatNumber(totalIndexed), label: "Total Indexed")
                }

                if let error {
                    AlertBanner(message: "Failed to load data: \(error)")
                }

                // Live Sessions section
                SectionHeader(icon: "bolt.fill", title: "Live Sessions",
                             onRefresh: { Task { await loadLiveSessions() } })

                if liveSessions.isEmpty && !isLoading {
                    EmptyState(icon: "bolt.slash", title: "No active sessions",
                              message: "Sessions will appear here when coding tools are actively running")
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(liveSessions) { session in
                            LiveSessionCard(session: session)
                        }
                    }
                }

                // Sources section
                SectionHeader(icon: "antenna.radiowaves.left.and.right", title: "Sources",
                             onRefresh: { Task { await loadSources() } })

                if sources.isEmpty && !isLoading {
                    EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No sources",
                              message: "No adapter sources detected")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(sources) { source in
                            HStack(spacing: 12) {
                                SourcePill(source: source.name)
                                Spacer()
                                Text("\(source.sessionCount) sessions")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                if let latest = source.latestIndexed {
                                    Text(latest.prefix(10))
                                        .font(.caption)
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if !sourceDist.isEmpty {
                    SectionHeader(icon: "chart.pie", title: "Distribution")
                    BarChart(items: sourceDist.prefix(10).map { item in
                        BarChartItem(label: SourceColors.label(for: item.source), value: item.count, color: SourceColors.color(for: item.source))
                    })
                }
            }
            .padding(24)
        }
        .task {
            await loadLiveSessions()
            await loadSources()
        }
    }

    private func loadLiveSessions() async {
        do {
            let response: LiveSessionResponse = try await daemonClient.fetch("/api/live")
            liveSessions = response.sessions
        } catch {
            // Live sessions are optional — fall back silently
            liveSessions = []
        }
    }

    private func loadSources() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            sources = try await daemonClient.fetch("/api/sources")
        } catch {
            self.error = error.localizedDescription
            do {
                sourceDist = try db.sourceDistribution()
                sources = sourceDist.map { SourceInfo(name: $0.source, sessionCount: $0.count, latestIndexed: nil) }
            } catch {}
        }
        do { sourceDist = try db.sourceDistribution() } catch {}
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Live Session Card

struct LiveSessionCard: View {
    let session: LiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Pulsing indicator
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: .green.opacity(0.5), radius: 4)

                SourcePill(source: session.source)

                if let project = session.project {
                    Text(project)
                        .font(.headline)
                        .lineLimit(1)
                }

                Spacer()

                if let model = session.model {
                    Text(model.split(separator: "-").prefix(3).joined(separator: "-"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                }
            }

            if let activity = session.currentActivity {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                    Text(activity)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                if !session.cwd.isEmpty {
                    Label(session.cwd.split(separator: "/").suffix(2).joined(separator: "/"),
                          systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text(relativeTime(from: session.startedAt))
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(12)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func relativeTime(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString) else {
            return ""
        }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        return "\(Int(elapsed / 3600))h ago"
    }
}
```

- [ ] **Step 4: Run xcodegen and verify build**

```bash
cd macos && xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```
Expected: Clean build.

- [ ] **Step 5: Commit**

```bash
git add macos/Engram/Views/Pages/SourcePulseView.swift macos/Engram/Core/DaemonClient.swift
git commit -m "feat: live session cards in SourcePulseView, add DaemonClient API methods"
```

---

### Task 11: Add Live Session Count Badge to Menu Bar

**Files:**
- Modify: `macos/Engram/MenuBarController.swift`

- [ ] **Step 1: Add live session polling**

In `MenuBarController`, add a polling timer for live session count. In the `init` method, after the existing badge update block (around line 52-57), add:

```swift
// Poll live session count for menu bar badge
Task { @MainActor in
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
        guard let self else { return }
        Task { @MainActor in
            do {
                let response: LiveSessionResponse = try await self.daemonClient.fetch("/api/live")
                let count = response.count
                if count > 0 {
                    self.statusItem.button?.title = " \(count) live"
                } else {
                    // Fall back to total session count
                    let total = self.indexer.totalSessions
                    self.statusItem.button?.title = total > 0 ? " \(total)" : ""
                }
            } catch {
                // Keep existing badge on error
            }
        }
    }
}
```

- [ ] **Step 2: Run xcodegen and verify build**

```bash
cd macos && xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```
Expected: Clean build.

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/MenuBarController.swift
git commit -m "feat: show live session count badge in menu bar status item"
```

---

### Task 12: Add Alert Event Parsing in IndexerProcess

**Files:**
- Modify: `macos/Engram/Core/IndexerProcess.swift`

- [ ] **Step 1: Parse alert events from daemon stdout**

In `IndexerProcess.swift`, in the existing JSON event parsing loop (where events like `ready`, `watcher_indexed`, etc. are handled), add a case for `alert`:

```swift
case "alert":
    if let alertData = event["alert"] as? [String: Any],
       let title = alertData["title"] as? String,
       let detail = alertData["detail"] as? String,
       let severity = alertData["severity"] as? String {
        // Show system notification for warning/critical alerts
        if severity != "info" {
            let content = UNMutableNotificationContent()
            content.title = "Engram Alert"
            content.subtitle = title
            content.body = detail
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
```

Also ensure `import UserNotifications` is at the top of the file.

- [ ] **Step 2: Request notification permissions in AppDelegate/App init**

In the app's initialization (e.g., `EngramApp.swift` or `AppDelegate`), add:

```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
```

- [ ] **Step 3: Run xcodegen and verify build**

```bash
cd macos && xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```
Expected: Clean build.

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Core/IndexerProcess.swift
git commit -m "feat: parse daemon alert events and show system notifications"
```

---

### Task 13: Integration Test — Live Monitor + Web API

**Files:**
- Create: `tests/integration/live-sessions-api.test.ts`

- [ ] **Step 1: Write integration test**

```typescript
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { mkdirSync, writeFileSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { LiveSessionMonitor, type WatchDir } from '../../src/core/live-sessions.js'

const TEST_DIR = join(tmpdir(), 'engram-live-api-test-' + Date.now())
const SESSION_DIR = join(TEST_DIR, 'sessions')

describe('live sessions integration', () => {
  let monitor: LiveSessionMonitor

  beforeAll(() => {
    mkdirSync(SESSION_DIR, { recursive: true })

    // Create two "live" session files
    const line1 = JSON.stringify({
      type: 'system', subtype: 'init', sessionId: 'live-api-1',
      cwd: '/projects/app', timestamp: new Date().toISOString(),
    })
    writeFileSync(join(SESSION_DIR, 'session1.jsonl'), line1 + '\n')

    const line2 = JSON.stringify({
      type: 'system', subtype: 'init', sessionId: 'live-api-2',
      cwd: '/projects/lib', timestamp: new Date().toISOString(),
    })
    writeFileSync(join(SESSION_DIR, 'session2.jsonl'), line2 + '\n')

    const watchDirs: WatchDir[] = [
      { path: SESSION_DIR, source: 'claude-code' as any },
    ]
    monitor = new LiveSessionMonitor({ watchDirs, stalenessMs: 60_000 })
  })

  afterAll(() => {
    monitor.stop()
    rmSync(TEST_DIR, { recursive: true, force: true })
  })

  it('scan detects multiple live sessions', async () => {
    await monitor.scan()
    const sessions = monitor.getSessions()
    expect(sessions.length).toBe(2)
  })

  it('getSessions returns correct structure', async () => {
    await monitor.scan()
    const sessions = monitor.getSessions()
    for (const s of sessions) {
      expect(s.source).toBe('claude-code')
      expect(s.filePath).toBeDefined()
      expect(s.lastModifiedAt).toBeDefined()
    }
  })

  it('sessions have derived project from cwd', async () => {
    await monitor.scan()
    const sessions = monitor.getSessions()
    const projects = sessions.map(s => s.project)
    expect(projects).toContain('app')
    expect(projects).toContain('lib')
  })
})
```

- [ ] **Step 2: Run integration test**

Run: `npm test -- tests/integration/live-sessions-api.test.ts`
Expected: All pass.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/live-sessions-api.test.ts
git commit -m "test: add integration test for live session detection"
```

---

### Task 14: Integration Test — Mock Data + Cleanup

**Files:**
- Create: `tests/integration/mock-data-lifecycle.test.ts`

- [ ] **Step 1: Write integration test**

```typescript
import { describe, it, expect } from 'vitest'
import { Database } from '../../src/core/db.js'
import { populateMockData, clearMockData } from '../../src/core/mock-data.js'

describe('mock data lifecycle', () => {
  it('populate → query → clear cycle works end-to-end', async () => {
    const db = new Database(':memory:')

    // Populate
    const stats = await populateMockData(db)
    expect(stats.sessions).toBe(50)

    // Query via DB methods
    const sessions = db.listSessions({ limit: 100 })
    const mockSessions = sessions.filter((s: any) => s.filePath?.startsWith('__mock__'))
    expect(mockSessions.length).toBe(50)

    // Verify cost data exists
    const costRows = db.getRawDb().prepare(
      "SELECT COUNT(*) as cnt FROM session_costs"
    ).get() as { cnt: number }
    expect(costRows.cnt).toBe(50)

    // Verify tool data exists
    const toolRows = db.getRawDb().prepare(
      "SELECT COUNT(DISTINCT session_id) as cnt FROM session_tools"
    ).get() as { cnt: number }
    expect(toolRows.cnt).toBe(50)

    // Clear
    const cleared = clearMockData(db)
    expect(cleared).toBe(50)

    // Verify cleanup
    const afterClear = db.listSessions({ limit: 100 })
    expect(afterClear.length).toBe(0)
  })

  it('mock data covers all specified source types', async () => {
    const db = new Database(':memory:')
    await populateMockData(db)

    const sources = db.getRawDb().prepare(
      "SELECT DISTINCT source FROM sessions WHERE file_path LIKE '__mock__%'"
    ).all() as { source: string }[]

    // Should have at least 3 different sources (probability very high with 50 sessions)
    expect(sources.length).toBeGreaterThanOrEqual(3)

    clearMockData(db)
  })
})
```

- [ ] **Step 2: Run integration test**

Run: `npm test -- tests/integration/mock-data-lifecycle.test.ts`
Expected: All pass.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/mock-data-lifecycle.test.ts
git commit -m "test: add integration test for mock data populate/clear lifecycle"
```

---

## Verification Checklist

After all tasks complete:

- [ ] `npm test` — all tests pass (all existing + ~40 new)
- [ ] `npm run build` — clean compile
- [ ] New MCP tools appear in `ListToolsRequestSchema` response: `live_sessions`, `lint_config`
- [ ] `GET /api/live` returns live session snapshot (empty array when no tools running)
- [ ] `GET /api/live/stream` returns SSE stream with `event: update` messages
- [ ] `GET /api/monitor/alerts` returns alert list (empty when within budget)
- [ ] `POST /api/dev/mock` populates 50 mock sessions (requires `devMode: true` in settings)
- [ ] `DELETE /api/dev/mock` clears all mock sessions without affecting real data
- [ ] `POST /api/lint` with `{ "cwd": "/path/to/project" }` returns issues and score
- [ ] Mock sessions identifiable by `file_path LIKE '__mock__%'` — NOT via origin column
- [ ] BackgroundMonitor alerts emitted as `{ event: "alert", alert: {...} }` on daemon stdout
- [ ] SourcePulseView shows live session cards with green pulse indicator
- [ ] Menu bar badge shows live session count when sessions are active
- [ ] Daemon `--mock` flag populates mock data on startup
- [ ] `cd macos && xcodegen generate && xcodebuild -scheme Engram -configuration Debug build` — clean build
