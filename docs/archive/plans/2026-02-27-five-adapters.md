# Five New Adapters Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add adapters for iflow, Qwen, OpenCode, Kimi, and Cline CLI, wiring them into the MCP server.

**Architecture:** Each adapter implements `SessionAdapter` interface. iflow/Qwen are near-identical to ClaudeCodeAdapter (JSONL). OpenCode reads from SQLite using `better-sqlite3`. Kimi reads `context.jsonl` + `wire.jsonl` per session directory. Cline reads a JSON array from `ui_messages.json`.

**Tech Stack:** TypeScript ESM, better-sqlite3 (already dep), vitest, chokidar

---

### Task 1: Expand SourceName type

**Files:**
- Modify: `src/adapters/types.ts`

**Step 1: Update the union type**

```typescript
export type SourceName = 'codex' | 'claude-code' | 'gemini-cli' | 'opencode' | 'iflow' | 'qwen' | 'kimi' | 'cline'
```

**Step 2: Verify TypeScript still compiles**

Run: `npm run build`
Expected: no errors

**Step 3: Commit**

```bash
git add src/adapters/types.ts
git commit -m "feat: expand SourceName to include iflow, qwen, kimi, cline"
```

---

### Task 2: iflow adapter

Format is nearly identical to Claude Code. `cwd` is present on every line. Session files are at `~/.iflow/projects/<encoded>/session-<uuid>.jsonl`.

**Files:**
- Create: `src/adapters/iflow.ts`
- Create: `tests/adapters/iflow.test.ts`
- Create: `tests/fixtures/iflow/sample.jsonl`

**Step 1: Create fixture**

`tests/fixtures/iflow/sample.jsonl`:
```jsonl
{"uuid":"aa-001","parentUuid":null,"sessionId":"session-iflow-001","timestamp":"2026-01-20T09:00:00.000Z","type":"user","isSidechain":false,"userType":"external","message":{"role":"user","content":"帮我优化数据库查询"},"cwd":"/Users/test/my-project","gitBranch":"main","version":"1.0.0"}
{"uuid":"aa-002","parentUuid":"aa-001","sessionId":"session-iflow-001","timestamp":"2026-01-20T09:00:05.000Z","type":"assistant","isSidechain":false,"userType":"external","message":{"id":"r1","type":"message","role":"assistant","content":[{"type":"text","text":"好的，我来分析数据库查询性能。"}],"model":"glm-5","stop_reason":null,"stop_sequence":null,"usage":{}},"cwd":"/Users/test/my-project","gitBranch":"main","version":"1.0.0"}
{"uuid":"aa-003","parentUuid":"aa-002","sessionId":"session-iflow-001","timestamp":"2026-01-20T09:01:00.000Z","type":"user","isSidechain":false,"userType":"external","message":{"role":"user","content":"好的谢谢"},"cwd":"/Users/test/my-project","gitBranch":"main","version":"1.0.0"}
```

**Step 2: Write failing tests**

`tests/adapters/iflow.test.ts`:
```typescript
import { describe, it, expect } from 'vitest'
import { IflowAdapter } from '../../src/adapters/iflow.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(__dirname, '../fixtures/iflow/sample.jsonl')

describe('IflowAdapter', () => {
  const adapter = new IflowAdapter()

  it('name is iflow', () => {
    expect(adapter.name).toBe('iflow')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('session-iflow-001')
    expect(info!.source).toBe('iflow')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.startTime).toBe('2026-01-20T09:00:00.000Z')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('帮我优化数据库查询')
  })

  it('streamMessages yields user and assistant', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg)
    }
    expect(messages.length).toBeGreaterThanOrEqual(2)
    expect(messages[0].role).toBe('user')
    expect(messages[0].content).toBe('帮我优化数据库查询')
    expect(messages[1].role).toBe('assistant')
  })

  it('streamMessages respects limit', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE, { limit: 1 })) {
      messages.push(msg)
    }
    expect(messages).toHaveLength(1)
  })
})
```

**Step 3: Run to confirm failure**

Run: `npm test -- tests/adapters/iflow.test.ts`
Expected: FAIL (IflowAdapter not found)

**Step 4: Implement adapter**

`src/adapters/iflow.ts`:
```typescript
// src/adapters/iflow.ts
import { createReadStream } from 'fs'
import { stat, readdir } from 'fs/promises'
import { createInterface } from 'readline'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

export class IflowAdapter implements SessionAdapter {
  readonly name = 'iflow' as const
  private projectsRoot: string

  constructor(projectsRoot?: string) {
    this.projectsRoot = projectsRoot ?? join(homedir(), '.iflow', 'projects')
  }

  async detect(): Promise<boolean> {
    try { await stat(this.projectsRoot); return true } catch { return false }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const projectDirs = await readdir(this.projectsRoot)
      for (const dir of projectDirs) {
        const projectPath = join(this.projectsRoot, dir)
        try {
          const files = await readdir(projectPath)
          for (const file of files) {
            if (file.startsWith('session-') && file.endsWith('.jsonl')) {
              yield join(projectPath, file)
            }
          }
        } catch { /* skip unreadable dirs */ }
      }
    } catch { /* projectsRoot missing */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      let sessionId = '', cwd = '', startTime = '', endTime = ''
      let userCount = 0, totalCount = 0, firstUserText = ''

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line)
        if (!obj) continue
        const type = obj.type as string
        if (type !== 'user' && type !== 'assistant') continue

        if (!sessionId && obj.sessionId) sessionId = obj.sessionId as string
        if (!cwd && obj.cwd) cwd = obj.cwd as string
        if (!startTime && obj.timestamp) startTime = obj.timestamp as string
        if (obj.timestamp) endTime = obj.timestamp as string
        totalCount++

        if (type === 'user') {
          userCount++
          if (!firstUserText) {
            const msg = obj.message as Record<string, unknown>
            const text = this.extractContent(msg?.content)
            if (!this.isSystemInjection(text)) firstUserText = text
          }
        }
      }

      if (!sessionId) return null
      return {
        id: sessionId, source: 'iflow', startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd, messageCount: totalCount, userMessageCount: userCount,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath, sizeBytes: fileStat.size,
      }
    } catch { return null }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity
    let count = 0, yielded = 0

    for await (const line of this.readLines(filePath)) {
      if (yielded >= limit) break
      const obj = this.parseLine(line)
      if (!obj) continue
      const type = obj.type as string
      if (type !== 'user' && type !== 'assistant') continue
      if (count < offset) { count++; continue }
      count++
      const msg = obj.message as Record<string, unknown>
      yield {
        role: type as 'user' | 'assistant',
        content: this.extractContent(msg?.content),
        timestamp: obj.timestamp as string | undefined,
      }
      yielded++
    }
  }

  private isSystemInjection(text: string): boolean {
    return text.startsWith('# AGENTS.md instructions for ') ||
      text.includes('<INSTRUCTIONS>') ||
      text.startsWith('<local-command-caveat>')
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' })
    const rl = createInterface({ input: stream, crlfDelay: Infinity })
    for await (const line of rl) { if (line.trim()) yield line }
  }

  private parseLine(line: string): Record<string, unknown> | null {
    try { return JSON.parse(line) as Record<string, unknown> } catch { return null }
  }

  private extractContent(content: unknown): string {
    if (typeof content === 'string') return content
    if (Array.isArray(content)) {
      for (const item of content) {
        const c = item as Record<string, unknown>
        if (c.type === 'text' && c.text) return c.text as string
      }
    }
    return ''
  }
}
```

**Step 5: Run tests**

Run: `npm test -- tests/adapters/iflow.test.ts`
Expected: 4 tests PASS

**Step 6: Commit**

```bash
git add src/adapters/iflow.ts tests/adapters/iflow.test.ts tests/fixtures/iflow/
git commit -m "feat: add iflow adapter"
```

---

### Task 3: Qwen adapter

Format identical to Claude Code, except:
- Path: `~/.qwen/projects/<encoded>/chats/<session-id>.jsonl`
- Assistant role in JSON is `"model"` not `"assistant"` — normalize to `"assistant"` on output
- Message content is in `message.parts[].text` (not `message.content`)
- System injection text starts with `\nYou are Qwen Code`

**Files:**
- Create: `src/adapters/qwen.ts`
- Create: `tests/adapters/qwen.test.ts`
- Create: `tests/fixtures/qwen/sample.jsonl`

**Step 1: Create fixture**

`tests/fixtures/qwen/sample.jsonl`:
```jsonl
{"uuid":"q-001","parentUuid":null,"sessionId":"qwen-session-001","timestamp":"2026-01-20T09:00:00.000Z","type":"user","cwd":"/Users/test/my-project","version":"0.10.5","message":{"role":"user","parts":[{"text":"帮我重构这个模块"}]}}
{"uuid":"q-002","parentUuid":"q-001","sessionId":"qwen-session-001","timestamp":"2026-01-20T09:00:08.000Z","type":"assistant","cwd":"/Users/test/my-project","version":"0.10.5","model":"qwen3.5-plus","message":{"role":"model","parts":[{"text":"好的，我来帮你重构这个模块。"}]}}
{"uuid":"q-003","parentUuid":"q-002","sessionId":"qwen-session-001","timestamp":"2026-01-20T09:01:00.000Z","type":"user","cwd":"/Users/test/my-project","version":"0.10.5","message":{"role":"user","parts":[{"text":"谢谢"}]}}
```

**Step 2: Write failing tests**

`tests/adapters/qwen.test.ts`:
```typescript
import { describe, it, expect } from 'vitest'
import { QwenAdapter } from '../../src/adapters/qwen.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(__dirname, '../fixtures/qwen/sample.jsonl')

describe('QwenAdapter', () => {
  const adapter = new QwenAdapter()

  it('name is qwen', () => {
    expect(adapter.name).toBe('qwen')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('qwen-session-001')
    expect(info!.source).toBe('qwen')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('帮我重构这个模块')
  })

  it('streamMessages normalizes model role to assistant', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg)
    }
    expect(messages[0].role).toBe('user')
    expect(messages[1].role).toBe('assistant')
  })

  it('streamMessages respects limit', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE, { limit: 1 })) {
      messages.push(msg)
    }
    expect(messages).toHaveLength(1)
  })
})
```

**Step 3: Run to confirm failure**

Run: `npm test -- tests/adapters/qwen.test.ts`
Expected: FAIL

**Step 4: Implement adapter**

`src/adapters/qwen.ts`:
```typescript
// src/adapters/qwen.ts
import { createReadStream } from 'fs'
import { stat, readdir } from 'fs/promises'
import { createInterface } from 'readline'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

export class QwenAdapter implements SessionAdapter {
  readonly name = 'qwen' as const
  private projectsRoot: string

  constructor(projectsRoot?: string) {
    this.projectsRoot = projectsRoot ?? join(homedir(), '.qwen', 'projects')
  }

  async detect(): Promise<boolean> {
    try { await stat(this.projectsRoot); return true } catch { return false }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const projectDirs = await readdir(this.projectsRoot)
      for (const dir of projectDirs) {
        const chatsPath = join(this.projectsRoot, dir, 'chats')
        try {
          const files = await readdir(chatsPath)
          for (const file of files) {
            if (file.endsWith('.jsonl')) yield join(chatsPath, file)
          }
        } catch { /* skip */ }
      }
    } catch { /* projectsRoot missing */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      let sessionId = '', cwd = '', startTime = '', endTime = ''
      let userCount = 0, totalCount = 0, firstUserText = ''

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line)
        if (!obj) continue
        const type = obj.type as string
        if (type !== 'user' && type !== 'assistant') continue

        if (!sessionId && obj.sessionId) sessionId = obj.sessionId as string
        if (!cwd && obj.cwd) cwd = obj.cwd as string
        if (!startTime && obj.timestamp) startTime = obj.timestamp as string
        if (obj.timestamp) endTime = obj.timestamp as string
        totalCount++

        if (type === 'user') {
          userCount++
          if (!firstUserText) {
            const msg = obj.message as Record<string, unknown>
            const text = this.extractParts(msg?.parts)
            if (!this.isSystemInjection(text)) firstUserText = text
          }
        }
      }

      if (!sessionId) return null
      return {
        id: sessionId, source: 'qwen', startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd, messageCount: totalCount, userMessageCount: userCount,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath, sizeBytes: fileStat.size,
      }
    } catch { return null }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity
    let count = 0, yielded = 0

    for await (const line of this.readLines(filePath)) {
      if (yielded >= limit) break
      const obj = this.parseLine(line)
      if (!obj) continue
      const type = obj.type as string
      if (type !== 'user' && type !== 'assistant') continue
      if (count < offset) { count++; continue }
      count++
      const msg = obj.message as Record<string, unknown>
      const role = (msg?.role as string) === 'model' ? 'assistant' : 'user'
      yield {
        role: role as 'user' | 'assistant',
        content: this.extractParts(msg?.parts),
        timestamp: obj.timestamp as string | undefined,
      }
      yielded++
    }
  }

  private isSystemInjection(text: string): boolean {
    return text.startsWith('\nYou are Qwen Code') ||
      text.startsWith('You are Qwen Code') ||
      text.includes('<INSTRUCTIONS>')
  }

  private extractParts(parts: unknown): string {
    if (!Array.isArray(parts)) return ''
    for (const p of parts) {
      const part = p as Record<string, unknown>
      if (typeof part.text === 'string' && part.text) return part.text
    }
    return ''
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' })
    const rl = createInterface({ input: stream, crlfDelay: Infinity })
    for await (const line of rl) { if (line.trim()) yield line }
  }

  private parseLine(line: string): Record<string, unknown> | null {
    try { return JSON.parse(line) as Record<string, unknown> } catch { return null }
  }
}
```

**Step 5: Run tests**

Run: `npm test -- tests/adapters/qwen.test.ts`
Expected: 4 tests PASS

**Step 6: Commit**

```bash
git add src/adapters/qwen.ts tests/adapters/qwen.test.ts tests/fixtures/qwen/
git commit -m "feat: add qwen adapter"
```

---

### Task 4: OpenCode adapter

OpenCode uses SQLite (`~/.local/share/opencode/opencode.db`). Since `listSessionFiles()` must yield string paths, use virtual paths: `${dbPath}::${sessionId}`. `sizeBytes` uses `time_updated` (ms) as a change-detection proxy.

**Files:**
- Modify: `src/adapters/opencode.ts` (replace stub)
- Create: `tests/adapters/opencode.test.ts` (replace existing)
- Create: `tests/fixtures/opencode/sample.db` (created programmatically in test setup)

**Step 1: Write failing tests**

Replace `tests/adapters/opencode.test.ts`:
```typescript
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { OpenCodeAdapter } from '../../src/adapters/opencode.js'
import Database from 'better-sqlite3'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'
import { mkdirSync, rmSync } from 'fs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_DIR = join(__dirname, '../fixtures/opencode')
const FIXTURE_DB = join(FIXTURE_DIR, 'sample.db')

beforeAll(() => {
  mkdirSync(FIXTURE_DIR, { recursive: true })
  const db = new Database(FIXTURE_DB)
  db.exec(`
    CREATE TABLE session (
      id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT,
      slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL,
      version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER,
      summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT,
      revert TEXT, permission TEXT,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
      time_compacting INTEGER, time_archived INTEGER
    );
    CREATE TABLE message (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
      data TEXT NOT NULL
    );
    INSERT INTO session VALUES (
      'ses_test001', 'proj_001', NULL, 'test-session', '/Users/test/my-project',
      '实现用户登录功能', '0.0.1', NULL, 3, 10, 2, NULL, NULL, NULL,
      1770000000000, 1770000060000, NULL, NULL
    );
    INSERT INTO message VALUES (
      'msg_001', 'ses_test001', 1770000001000, 1770000001000,
      '{"role":"user","time":{"created":1770000001000}}'
    );
    INSERT INTO message VALUES (
      'msg_002', 'ses_test001', 1770000010000, 1770000010000,
      '{"role":"assistant","time":{"created":1770000010000,"completed":1770000015000},"content":[{"type":"text","value":"好的，我来实现登录功能。"}]}'
    );
  `)
  db.close()
})

afterAll(() => {
  try { rmSync(FIXTURE_DB) } catch { /* ignore */ }
})

describe('OpenCodeAdapter', () => {
  const adapter = new OpenCodeAdapter(FIXTURE_DB)

  it('name is opencode', () => {
    expect(adapter.name).toBe('opencode')
  })

  it('listSessionFiles yields virtual paths', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    expect(files).toHaveLength(1)
    expect(files[0]).toContain('ses_test001')
  })

  it('parseSessionInfo extracts metadata from virtual path', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    const info = await adapter.parseSessionInfo(files[0])
    expect(info).not.toBeNull()
    expect(info!.id).toBe('ses_test001')
    expect(info!.source).toBe('opencode')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.summary).toBe('实现用户登录功能')
    expect(info!.messageCount).toBe(2)
  })

  it('streamMessages yields messages', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    const messages = []
    for await (const msg of adapter.streamMessages(files[0])) messages.push(msg)
    expect(messages.length).toBeGreaterThanOrEqual(1)
  })
})
```

**Step 2: Run to confirm failure**

Run: `npm test -- tests/adapters/opencode.test.ts`
Expected: FAIL

**Step 3: Implement adapter**

Replace `src/adapters/opencode.ts`:
```typescript
// src/adapters/opencode.ts
import { existsSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import BetterSqlite3 from 'better-sqlite3'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

interface OcSession {
  id: string; directory: string; title: string
  time_created: number; time_updated: number
}
interface OcMessage {
  id: string; session_id: string; time_created: number; data: string
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
    let db: BetterSqlite3.Database | null = null
    try {
      db = new BetterSqlite3(this.dbPath, { readonly: true })
      const rows = db.prepare('SELECT id FROM session WHERE time_archived IS NULL ORDER BY time_created DESC').all() as { id: string }[]
      for (const row of rows) {
        yield `${this.dbPath}::${row.id}`
      }
    } catch { /* ignore */ } finally {
      db?.close()
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    const [dbPath, sessionId] = this.splitVirtualPath(filePath)
    if (!sessionId) return null
    let db: BetterSqlite3.Database | null = null
    try {
      db = new BetterSqlite3(dbPath, { readonly: true })
      const row = db.prepare('SELECT * FROM session WHERE id = ?').get(sessionId) as OcSession | undefined
      if (!row) return null
      const msgCount = (db.prepare('SELECT COUNT(*) as c FROM message WHERE session_id = ?').get(sessionId) as { c: number }).c
      const firstMsg = db.prepare('SELECT data FROM message WHERE session_id = ? ORDER BY time_created ASC LIMIT 1').get(sessionId) as OcMessage | undefined
      const lastMsg = db.prepare('SELECT time_created FROM message WHERE session_id = ? ORDER BY time_created DESC LIMIT 1').get(sessionId) as { time_created: number } | undefined

      return {
        id: row.id,
        source: 'opencode',
        startTime: new Date(row.time_created).toISOString(),
        endTime: lastMsg ? new Date(lastMsg.time_created).toISOString() : undefined,
        cwd: row.directory,
        messageCount: msgCount,
        userMessageCount: this.countUserMessages(db, sessionId),
        summary: row.title || undefined,
        filePath,
        sizeBytes: row.time_updated,
      }
    } catch { return null } finally {
      db?.close()
    }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const [dbPath, sessionId] = this.splitVirtualPath(filePath)
    if (!sessionId) return
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? 1000000
    let db: BetterSqlite3.Database | null = null
    try {
      db = new BetterSqlite3(dbPath, { readonly: true })
      const rows = db.prepare(
        'SELECT data, time_created FROM message WHERE session_id = ? ORDER BY time_created ASC LIMIT ? OFFSET ?'
      ).all(sessionId, limit, offset) as { data: string; time_created: number }[]

      for (const row of rows) {
        try {
          const data = JSON.parse(row.data) as Record<string, unknown>
          const role = data.role as string
          if (role !== 'user' && role !== 'assistant') continue
          const content = this.extractContent(data)
          yield {
            role: role as 'user' | 'assistant',
            content,
            timestamp: new Date(row.time_created).toISOString(),
          }
        } catch { /* skip malformed */ }
      }
    } catch { /* ignore */ } finally {
      db?.close()
    }
  }

  private splitVirtualPath(filePath: string): [string, string] {
    const sep = filePath.lastIndexOf('::')
    if (sep === -1) return [filePath, '']
    return [filePath.slice(0, sep), filePath.slice(sep + 2)]
  }

  private countUserMessages(db: BetterSqlite3.Database, sessionId: string): number {
    const rows = db.prepare('SELECT data FROM message WHERE session_id = ?').all(sessionId) as { data: string }[]
    let count = 0
    for (const row of rows) {
      try {
        const d = JSON.parse(row.data) as Record<string, unknown>
        if (d.role === 'user') count++
      } catch { /* skip */ }
    }
    return count
  }

  private extractContent(data: Record<string, unknown>): string {
    // content may be array of {type, value/text} or string
    const content = data.content
    if (typeof content === 'string') return content
    if (Array.isArray(content)) {
      for (const item of content) {
        const c = item as Record<string, unknown>
        if (c.value) return c.value as string
        if (c.text) return c.text as string
      }
    }
    // fallback: parts array
    const parts = data.parts
    if (Array.isArray(parts)) {
      for (const p of parts) {
        const part = p as Record<string, unknown>
        if (part.text) return part.text as string
      }
    }
    return ''
  }
}
```

**Step 4: Run tests**

Run: `npm test -- tests/adapters/opencode.test.ts`
Expected: 4 tests PASS

**Step 5: Commit**

```bash
git add src/adapters/opencode.ts tests/adapters/opencode.test.ts tests/fixtures/opencode/
git commit -m "feat: implement opencode adapter (SQLite)"
```

---

### Task 5: Kimi adapter

Structure: `~/.kimi/sessions/<workspace-id>/<session-id>/context.jsonl`.
- `context.jsonl`: lines with `{"role":"user"|"assistant","content":"..."}` plus `{"role":"_checkpoint","id":N}` (skip checkpoints)
- Timestamps from `wire.jsonl`: first `TurnBegin` timestamp → startTime; last timestamp → endTime
- cwd from `~/.kimi/kimi.json`: `work_dirs[].last_session_id` → `work_dirs[].path`
- `listSessionFiles()` yields paths to `context.jsonl` files

**Files:**
- Create: `src/adapters/kimi.ts`
- Create: `tests/adapters/kimi.test.ts`
- Create: `tests/fixtures/kimi/sessions/ws-001/sess-001/context.jsonl`
- Create: `tests/fixtures/kimi/sessions/ws-001/sess-001/wire.jsonl`
- Create: `tests/fixtures/kimi/kimi.json`

**Step 1: Create fixtures**

`tests/fixtures/kimi/kimi.json`:
```json
{
  "work_dirs": [
    {
      "path": "/Users/test/my-project",
      "kaos": "local",
      "last_session_id": "sess-001"
    }
  ]
}
```

`tests/fixtures/kimi/sessions/ws-001/sess-001/context.jsonl`:
```jsonl
{"role": "_checkpoint", "id": 0}
{"role": "user", "content": "帮我排查内存泄漏"}
{"role": "_checkpoint", "id": 1}
{"role": "assistant", "content": "我来帮你分析内存使用情况。"}
{"role": "user", "content": "找到了，谢谢"}
```

`tests/fixtures/kimi/sessions/ws-001/sess-001/wire.jsonl`:
```jsonl
{"type": "metadata", "protocol_version": "1.3"}
{"timestamp": 1770000001.0, "message": {"type": "TurnBegin", "payload": {"user_input": "帮我排查内存泄漏"}}}
{"timestamp": 1770000060.0, "message": {"type": "TurnEnd", "payload": {}}}
```

**Step 2: Write failing tests**

`tests/adapters/kimi.test.ts`:
```typescript
import { describe, it, expect } from 'vitest'
import { KimiAdapter } from '../../src/adapters/kimi.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_ROOT = join(__dirname, '../fixtures/kimi')
const FIXTURE_SESSIONS = join(FIXTURE_ROOT, 'sessions')
const FIXTURE_KIMI_JSON = join(FIXTURE_ROOT, 'kimi.json')
const FIXTURE_CONTEXT = join(FIXTURE_SESSIONS, 'ws-001/sess-001/context.jsonl')

describe('KimiAdapter', () => {
  const adapter = new KimiAdapter(FIXTURE_SESSIONS, FIXTURE_KIMI_JSON)

  it('name is kimi', () => {
    expect(adapter.name).toBe('kimi')
  })

  it('listSessionFiles yields context.jsonl paths', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    expect(files).toHaveLength(1)
    expect(files[0]).toContain('context.jsonl')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE_CONTEXT)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('sess-001')
    expect(info!.source).toBe('kimi')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('帮我排查内存泄漏')
  })

  it('streamMessages skips checkpoints', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE_CONTEXT)) messages.push(msg)
    expect(messages.every(m => m.role === 'user' || m.role === 'assistant')).toBe(true)
    expect(messages[0].content).toBe('帮我排查内存泄漏')
    expect(messages[1].role).toBe('assistant')
  })
})
```

**Step 3: Run to confirm failure**

Run: `npm test -- tests/adapters/kimi.test.ts`
Expected: FAIL

**Step 4: Implement adapter**

`src/adapters/kimi.ts`:
```typescript
// src/adapters/kimi.ts
import { createReadStream } from 'fs'
import { stat, readdir, readFile } from 'fs/promises'
import { createInterface } from 'readline'
import { homedir } from 'os'
import { join, dirname, basename } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

export class KimiAdapter implements SessionAdapter {
  readonly name = 'kimi' as const
  private sessionsRoot: string
  private kimiJsonPath: string

  constructor(sessionsRoot?: string, kimiJsonPath?: string) {
    this.sessionsRoot = sessionsRoot ?? join(homedir(), '.kimi', 'sessions')
    this.kimiJsonPath = kimiJsonPath ?? join(homedir(), '.kimi', 'kimi.json')
  }

  async detect(): Promise<boolean> {
    try { await stat(this.sessionsRoot); return true } catch { return false }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const workspaces = await readdir(this.sessionsRoot)
      for (const ws of workspaces) {
        const wsPath = join(this.sessionsRoot, ws)
        try {
          const sessions = await readdir(wsPath)
          for (const sess of sessions) {
            const contextPath = join(wsPath, sess, 'context.jsonl')
            try { await stat(contextPath); yield contextPath } catch { /* skip */ }
          }
        } catch { /* skip */ }
      }
    } catch { /* sessionsRoot missing */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      const sessionId = basename(dirname(filePath))
      const cwd = await this.resolveCwd(sessionId)
      const { startTime, endTime } = await this.readTimestamps(filePath)

      let userCount = 0, totalCount = 0, firstUserText = ''
      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line)
        if (!obj || obj.role === '_checkpoint') continue
        totalCount++
        if (obj.role === 'user') {
          userCount++
          if (!firstUserText && typeof obj.content === 'string') firstUserText = obj.content
        }
      }

      return {
        id: sessionId, source: 'kimi',
        startTime: startTime ?? new Date(fileStat.mtimeMs - 60000).toISOString(),
        endTime,
        cwd, messageCount: totalCount, userMessageCount: userCount,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath, sizeBytes: fileStat.size,
      }
    } catch { return null }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity
    let count = 0, yielded = 0

    for await (const line of this.readLines(filePath)) {
      if (yielded >= limit) break
      const obj = this.parseLine(line)
      if (!obj || obj.role === '_checkpoint') continue
      const role = obj.role as string
      if (role !== 'user' && role !== 'assistant') continue
      if (count < offset) { count++; continue }
      count++
      yield {
        role: role as 'user' | 'assistant',
        content: typeof obj.content === 'string' ? obj.content : '',
      }
      yielded++
    }
  }

  private async resolveCwd(sessionId: string): Promise<string> {
    try {
      const raw = await readFile(this.kimiJsonPath, 'utf8')
      const data = JSON.parse(raw) as { work_dirs?: { path: string; last_session_id?: string }[] }
      for (const wd of data.work_dirs ?? []) {
        if (wd.last_session_id === sessionId) return wd.path
      }
    } catch { /* ignore */ }
    return ''
  }

  private async readTimestamps(contextPath: string): Promise<{ startTime?: string; endTime?: string }> {
    const wirePath = join(dirname(contextPath), 'wire.jsonl')
    try {
      let first: number | null = null, last: number | null = null
      for await (const line of this.readLines(wirePath)) {
        const obj = this.parseLine(line)
        if (!obj || typeof obj.timestamp !== 'number') continue
        if (first === null) first = obj.timestamp as number
        last = obj.timestamp as number
      }
      return {
        startTime: first !== null ? new Date(first * 1000).toISOString() : undefined,
        endTime: last !== null && last !== first ? new Date(last * 1000).toISOString() : undefined,
      }
    } catch { return {} }
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' })
    const rl = createInterface({ input: stream, crlfDelay: Infinity })
    for await (const line of rl) { if (line.trim()) yield line }
  }

  private parseLine(line: string): Record<string, unknown> | null {
    try { return JSON.parse(line) as Record<string, unknown> } catch { return null }
  }
}
```

**Step 5: Run tests**

Run: `npm test -- tests/adapters/kimi.test.ts`
Expected: 4 tests PASS

**Step 6: Commit**

```bash
git add src/adapters/kimi.ts tests/adapters/kimi.test.ts tests/fixtures/kimi/
git commit -m "feat: add kimi adapter"
```

---

### Task 6: Cline adapter

Files at `~/.cline/data/tasks/<task-id>/ui_messages.json` (JSON array, not JSONL).
- `id` = task_id (the numeric timestamp directory name)
- startTime/endTime: `ts` field (ms) on first/last message
- cwd: regex-extract "Current Working Directory (/path)" from the first `say:"api_req_started"` message's parsed JSON text field
- summary: first `say:"task"` message text
- user messages: `say:"task"` and `say:"user_feedback"`
- assistant messages: `say:"text"`

**Files:**
- Create: `src/adapters/cline.ts`
- Create: `tests/adapters/cline.test.ts`
- Create: `tests/fixtures/cline/tasks/1770000000000/ui_messages.json`

**Step 1: Create fixture**

`tests/fixtures/cline/tasks/1770000000000/ui_messages.json`:
```json
[
  {"ts": 1770000000000, "type": "say", "say": "task", "text": "帮我写单元测试", "modelInfo": {"providerId": "cline", "modelId": "glm-5", "mode": "act"}, "conversationHistoryIndex": -1},
  {"ts": 1770000001000, "type": "say", "say": "api_req_started", "text": "{\"request\":\"<task>\\n帮我写单元测试\\n</task>\\n\\nCurrent Working Directory (/Users/test/my-project) Files\\n\",\"tokensIn\":100,\"tokensOut\":0}", "conversationHistoryIndex": 0},
  {"ts": 1770000005000, "type": "say", "say": "text", "text": "好的，我来帮你写单元测试。", "partial": false, "conversationHistoryIndex": 1},
  {"ts": 1770000060000, "type": "say", "say": "user_feedback", "text": "谢谢", "conversationHistoryIndex": 5}
]
```

**Step 2: Write failing tests**

`tests/adapters/cline.test.ts`:
```typescript
import { describe, it, expect } from 'vitest'
import { ClineAdapter } from '../../src/adapters/cline.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_TASKS = join(__dirname, '../fixtures/cline/tasks')
const FIXTURE_FILE = join(FIXTURE_TASKS, '1770000000000/ui_messages.json')

describe('ClineAdapter', () => {
  const adapter = new ClineAdapter(FIXTURE_TASKS)

  it('name is cline', () => {
    expect(adapter.name).toBe('cline')
  })

  it('listSessionFiles yields ui_messages.json paths', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    expect(files).toHaveLength(1)
    expect(files[0]).toContain('ui_messages.json')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE_FILE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('1770000000000')
    expect(info!.source).toBe('cline')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.summary).toBe('帮我写单元测试')
    expect(info!.userMessageCount).toBe(2)
  })

  it('streamMessages yields user and assistant', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE_FILE)) messages.push(msg)
    expect(messages.some(m => m.role === 'user')).toBe(true)
    expect(messages.some(m => m.role === 'assistant')).toBe(true)
    expect(messages[0].content).toBe('帮我写单元测试')
  })
})
```

**Step 3: Run to confirm failure**

Run: `npm test -- tests/adapters/cline.test.ts`
Expected: FAIL

**Step 4: Implement adapter**

`src/adapters/cline.ts`:
```typescript
// src/adapters/cline.ts
import { stat, readdir, readFile } from 'fs/promises'
import { homedir } from 'os'
import { join, basename, dirname } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

interface UiMessage {
  ts: number
  type: string
  say?: string
  ask?: string
  text?: string
  partial?: boolean
}

export class ClineAdapter implements SessionAdapter {
  readonly name = 'cline' as const
  private tasksRoot: string

  constructor(tasksRoot?: string) {
    this.tasksRoot = tasksRoot ?? join(homedir(), '.cline', 'data', 'tasks')
  }

  async detect(): Promise<boolean> {
    try { await stat(this.tasksRoot); return true } catch { return false }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const taskDirs = await readdir(this.tasksRoot)
      for (const dir of taskDirs) {
        const uiPath = join(this.tasksRoot, dir, 'ui_messages.json')
        try { await stat(uiPath); yield uiPath } catch { /* skip */ }
      }
    } catch { /* tasksRoot missing */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      const taskId = basename(dirname(filePath))
      const msgs = await this.loadMessages(filePath)
      if (msgs.length === 0) return null

      const firstMsg = msgs[0]
      const lastMsg = msgs[msgs.length - 1]
      const taskMsg = msgs.find(m => m.say === 'task')
      const summary = taskMsg?.text?.slice(0, 200)
      const cwd = this.extractCwd(msgs)

      const userMsgs = msgs.filter(m => m.say === 'task' || m.say === 'user_feedback')
      const displayMsgs = msgs.filter(m => m.say === 'task' || m.say === 'user_feedback' || m.say === 'text')

      return {
        id: taskId, source: 'cline',
        startTime: new Date(firstMsg.ts).toISOString(),
        endTime: lastMsg.ts !== firstMsg.ts ? new Date(lastMsg.ts).toISOString() : undefined,
        cwd, messageCount: displayMsgs.length, userMessageCount: userMsgs.length,
        summary, filePath, sizeBytes: fileStat.size,
      }
    } catch { return null }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity
    const msgs = await this.loadMessages(filePath)
    const display = msgs.filter(m => m.say === 'task' || m.say === 'user_feedback' || m.say === 'text')
    let yielded = 0
    for (let i = offset; i < display.length && yielded < limit; i++) {
      const m = display[i]
      const role: 'user' | 'assistant' = (m.say === 'task' || m.say === 'user_feedback') ? 'user' : 'assistant'
      yield { role, content: m.text ?? '', timestamp: new Date(m.ts).toISOString() }
      yielded++
    }
  }

  private async loadMessages(filePath: string): Promise<UiMessage[]> {
    const raw = await readFile(filePath, 'utf8')
    return JSON.parse(raw) as UiMessage[]
  }

  private extractCwd(msgs: UiMessage[]): string {
    for (const m of msgs) {
      if (m.say !== 'api_req_started' || !m.text) continue
      try {
        const inner = JSON.parse(m.text) as { request?: string }
        const match = inner.request?.match(/Current Working Directory \(([^)]+)\)/)
        if (match) return match[1]
      } catch { /* skip */ }
    }
    return ''
  }
}
```

**Step 5: Run tests**

Run: `npm test -- tests/adapters/cline.test.ts`
Expected: 4 tests PASS

**Step 6: Commit**

```bash
git add src/adapters/cline.ts tests/adapters/cline.test.ts tests/fixtures/cline/
git commit -m "feat: add cline adapter"
```

---

### Task 7: Wire up all adapters in server + watcher

**Files:**
- Modify: `src/index.ts`
- Modify: `src/core/watcher.ts`
- Modify: `config.yaml`

**Step 1: Update index.ts**

Add imports after the existing adapter imports:
```typescript
import { IflowAdapter } from './adapters/iflow.js'
import { QwenAdapter } from './adapters/qwen.js'
import { OpenCodeAdapter } from './adapters/opencode.js'
import { KimiAdapter } from './adapters/kimi.js'
import { ClineAdapter } from './adapters/cline.js'
```

Update the adapters array:
```typescript
const adapters = [
  new CodexAdapter(),
  new ClaudeCodeAdapter(),
  new GeminiCliAdapter(),
  new OpenCodeAdapter(),
  new IflowAdapter(),
  new QwenAdapter(),
  new KimiAdapter(),
  new ClineAdapter(),
]
```

**Step 2: Update watcher.ts**

Add new entries to `watchMap`:
```typescript
[join(home, '.iflow', 'projects')]: adapters.find(a => a.name === 'iflow')!,
[join(home, '.qwen', 'projects')]: adapters.find(a => a.name === 'qwen')!,
[join(home, '.kimi', 'sessions')]: adapters.find(a => a.name === 'kimi')!,
[join(home, '.cline', 'data', 'tasks')]: adapters.find(a => a.name === 'cline')!,
```

Note: OpenCode uses SQLite polling — skip from chokidar watch (file watcher on .db has race conditions).

**Step 3: Update config.yaml**

Add after `opencode:`:
```yaml
  iflow:
    enabled: true

  qwen:
    enabled: true

  kimi:
    enabled: true

  cline:
    enabled: true
```

**Step 4: Build and run full test suite**

Run: `npm run build && npm test`
Expected: all tests PASS (should be 58+ tests now)

**Step 5: Commit**

```bash
git add src/index.ts src/core/watcher.ts config.yaml
git commit -m "feat: wire up iflow, qwen, kimi, cline, opencode adapters"
```

---

### Task 8: Update README

**Files:**
- Modify: `README.md`

**Step 1: Update the supported tools table**

Replace the existing table under `## 支持的工具` with:

```markdown
| 工具 | 日志路径 | 状态 |
|------|---------|------|
| [Codex CLI](https://github.com/openai/codex) | `~/.codex/sessions/` | ✅ 完整支持 |
| [Claude Code](https://claude.ai/code) | `~/.claude/projects/` | ✅ 完整支持 |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `~/.gemini/tmp/` | ✅ 完整支持 |
| [iflow](https://iflow.ai) | `~/.iflow/projects/` | ✅ 完整支持 |
| [Qwen Code](https://qwen.ai) | `~/.qwen/projects/` | ✅ 完整支持 |
| [OpenCode](https://opencode.ai) | `~/.local/share/opencode/opencode.db` | ✅ 完整支持 |
| [Kimi](https://kimi.moonshot.cn) | `~/.kimi/sessions/` | ✅ 完整支持 |
| [Cline CLI](https://github.com/cline/cline) | `~/.cline/data/tasks/` | ✅ 完整支持 |
```

**Step 2: Update source enum in list_sessions tool description**

In the `list_sessions` section, update the `source` parameter enum values to include all 8 sources.

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README for all 8 supported adapters"
```
