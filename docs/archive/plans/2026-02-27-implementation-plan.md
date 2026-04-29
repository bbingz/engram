# coding-memory Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 构建一个 MCP Server，读取 Codex/Claude Code/Gemini CLI/OpenCode 的本地会话日志，让 AI 助手之间能共享历史上下文。

**Architecture:** TypeScript MCP Server，以 stdio 模式运行。首次启动扫描所有会话文件建立 SQLite 索引，之后用 chokidar 监听增量更新。大文件（200MB+）逐行流式读取，永远不整体加载进内存。

**Tech Stack:** Node.js 20+ / TypeScript 5 / `@modelcontextprotocol/sdk` / `better-sqlite3` / `chokidar` / `js-yaml` / `vitest`

---

## 前置说明

### 项目路径
```
/Users/example/-Code-/coding-memory/
```

### 各工具日志位置（已实地验证）

| 工具 | 路径 | 格式 |
|------|------|------|
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | JSONL，每行一个 JSON 对象 |
| Claude Code | `~/.claude/projects/<encoded-path>/<sessionId>.jsonl` | JSONL，每行一个 JSON 对象 |
| Gemini CLI | `~/.gemini/tmp/<projectName>/chats/session-*.json` | 单个 JSON 文件，含 messages 数组；`~/.gemini/projects.json` 映射 cwd→projectName |
| OpenCode | `~/.local/share/opencode/storage/session_diff/*.json` | JSON 数组（格式需运行时验证） |

### Codex JSONL 格式
```json
{"timestamp":"...","type":"session_meta","payload":{"id":"...","cwd":"/Users/example","model_provider":"openai","cli_version":"0.60.1"}}
{"timestamp":"...","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"用户输入"}]}}
{"timestamp":"...","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"助手回复"}]}}
```

### Claude Code JSONL 格式
```json
{"type":"user","cwd":"/Users/example/-Code-","sessionId":"abc","timestamp":"2026-02-26T00:40:12.301Z","message":{"role":"user","content":"用户输入"}}
{"type":"assistant","cwd":"/Users/example/-Code-","sessionId":"abc","timestamp":"2026-02-26T00:40:15.000Z","message":{"role":"assistant","content":[{"type":"text","text":"助手回复"}]}}
```

### Gemini CLI JSON 格式
```json
{
  "sessionId": "3752fa5b-d29e-4712-...",
  "projectHash": "b2c488d6ef...",
  "startTime": "2026-02-21T07:22:23.846Z",
  "lastUpdated": "2026-02-21T07:25:00.000Z",
  "messages": [
    {"id":"...","timestamp":"...","type":"user","content":"用户输入"},
    {"id":"...","timestamp":"...","type":"model","content":"助手回复"}
  ]
}
```

### Claude Code 路径编码规则
目录名 `-Users-example--Code--project` → cwd `/Users/example/-Code-/project`
规则：单个 `-` 是路径分隔符 `/`，双 `--` 是原始 `-`

---

## Phase 1: 项目脚手架

### Task 1: 初始化项目结构

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `vitest.config.ts`
- Create: `src/adapters/types.ts`（空占位）

**Step 1: 创建 package.json**

```bash
cd /Users/example/-Code-/coding-memory
```

写入以下内容到 `package.json`：

```json
{
  "name": "coding-memory",
  "version": "0.1.0",
  "description": "MCP Server: 读取多个 AI 编程助手的会话日志，实现跨工具历史上下文共享",
  "type": "module",
  "main": "dist/index.js",
  "bin": {
    "coding-memory": "dist/index.js"
  },
  "scripts": {
    "build": "tsc",
    "dev": "tsx src/index.ts",
    "test": "vitest run",
    "test:watch": "vitest",
    "test:coverage": "vitest run --coverage"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.10.2",
    "better-sqlite3": "^11.9.1",
    "chokidar": "^4.0.3",
    "js-yaml": "^4.1.0"
  },
  "devDependencies": {
    "@types/better-sqlite3": "^7.6.12",
    "@types/js-yaml": "^4.0.9",
    "@types/node": "^22.13.5",
    "tsx": "^4.19.3",
    "typescript": "^5.8.2",
    "vitest": "^3.0.7"
  }
}
```

**Step 2: 创建 tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "Node16",
    "moduleResolution": "Node16",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist", "tests"]
}
```

**Step 3: 创建 vitest.config.ts**

```typescript
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    globals: true,
  },
})
```

**Step 4: 创建目录结构**

```bash
mkdir -p src/adapters src/core src/tools tests/fixtures/codex tests/fixtures/claude-code tests/fixtures/gemini tests/fixtures/opencode
```

**Step 5: 安装依赖**

```bash
npm install
```

预期输出：`added N packages` 无报错。

**Step 6: 验证 TypeScript 编译配置**

```bash
npx tsc --noEmit --version
```

预期输出：`Version 5.x.x`

**Step 7: Commit**

```bash
git add package.json tsconfig.json vitest.config.ts
git commit -m "chore: project scaffolding"
```

---

### Task 2: 核心类型定义

**Files:**
- Create: `src/adapters/types.ts`
- Create: `tests/types.test.ts`

**Step 1: 写 types.ts**

```typescript
// src/adapters/types.ts

export type SourceName = 'codex' | 'claude-code' | 'gemini-cli' | 'opencode'

export interface SessionInfo {
  id: string
  source: SourceName
  startTime: string       // ISO 8601
  endTime?: string
  cwd: string
  project?: string        // 解析后的项目名
  model?: string
  messageCount: number
  userMessageCount: number
  summary?: string        // 首条用户消息文本（截断到 200 字符）
  filePath: string        // 原始文件路径（用于流式读取消息）
  sizeBytes: number
}

export interface ToolCall {
  name: string
  input?: string
  output?: string
}

export interface Message {
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp?: string
  toolCalls?: ToolCall[]
}

export interface StreamMessagesOptions {
  offset?: number   // 跳过前 N 条消息
  limit?: number    // 最多返回 N 条消息
}

export interface SessionAdapter {
  readonly name: SourceName
  detect(): Promise<boolean>
  listSessionFiles(): AsyncGenerator<string>
  parseSessionInfo(filePath: string): Promise<SessionInfo | null>
  streamMessages(filePath: string, opts?: StreamMessagesOptions): AsyncGenerator<Message>
}
```

**Step 2: 写类型测试（验证类型可用性）**

```typescript
// tests/types.test.ts
import { describe, it, expect } from 'vitest'
import type { SessionInfo, Message, SourceName } from '../src/adapters/types.js'

describe('types', () => {
  it('SessionInfo shape is correct', () => {
    const session: SessionInfo = {
      id: 'test-id',
      source: 'codex',
      startTime: '2026-01-01T00:00:00.000Z',
      cwd: '/Users/test',
      messageCount: 10,
      userMessageCount: 5,
      filePath: '/path/to/file.jsonl',
      sizeBytes: 1024,
    }
    expect(session.id).toBe('test-id')
    expect(session.source).toBe('codex')
  })

  it('Message role values are valid', () => {
    const roles: Message['role'][] = ['user', 'assistant', 'system', 'tool']
    expect(roles).toHaveLength(4)
  })

  it('SourceName values are valid', () => {
    const sources: SourceName[] = ['codex', 'claude-code', 'gemini-cli', 'opencode']
    expect(sources).toHaveLength(4)
  })
})
```

**Step 3: 运行测试验证通过**

```bash
npm test
```

预期输出：`3 tests passed`

**Step 4: Commit**

```bash
git add src/adapters/types.ts tests/types.test.ts
git commit -m "feat: add core type definitions"
```

---

### Task 3: SQLite 数据库层

**Files:**
- Create: `src/core/db.ts`
- Create: `tests/core/db.test.ts`

**Step 1: 写失败测试**

```typescript
// tests/core/db.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Database } from '../../src/core/db.js'
import type { SessionInfo } from '../../src/adapters/types.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('Database', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'coding-memory-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  const mockSession: SessionInfo = {
    id: 'session-001',
    source: 'codex',
    startTime: '2026-01-01T10:00:00.000Z',
    endTime: '2026-01-01T11:00:00.000Z',
    cwd: '/Users/test/project',
    project: 'my-project',
    model: 'gpt-4o',
    messageCount: 20,
    userMessageCount: 10,
    summary: '帮我修复登录 bug',
    filePath: '/Users/test/.codex/sessions/2026/01/01/rollout-123.jsonl',
    sizeBytes: 50000,
  }

  it('upserts and retrieves a session', () => {
    db.upsertSession(mockSession)
    const result = db.getSession('session-001')
    expect(result).not.toBeNull()
    expect(result!.id).toBe('session-001')
    expect(result!.source).toBe('codex')
    expect(result!.cwd).toBe('/Users/test/project')
  })

  it('lists sessions with source filter', () => {
    db.upsertSession(mockSession)
    db.upsertSession({ ...mockSession, id: 'session-002', source: 'claude-code' })

    const codexOnly = db.listSessions({ source: 'codex' })
    expect(codexOnly).toHaveLength(1)
    expect(codexOnly[0].source).toBe('codex')
  })

  it('lists sessions with time filter', () => {
    db.upsertSession(mockSession)
    db.upsertSession({ ...mockSession, id: 'session-003', startTime: '2025-06-01T00:00:00.000Z' })

    const recent = db.listSessions({ since: '2026-01-01T00:00:00.000Z' })
    expect(recent).toHaveLength(1)
    expect(recent[0].id).toBe('session-001')
  })

  it('indexes and searches FTS content', () => {
    db.upsertSession(mockSession)
    db.indexSessionContent('session-001', [
      { role: 'user', content: '帮我修复 SSL 证书错误' },
      { role: 'assistant', content: '你需要更新证书配置' },
    ])

    const results = db.searchSessions('SSL 证书')
    expect(results.length).toBeGreaterThan(0)
    expect(results[0].sessionId).toBe('session-001')
  })

  it('deletes a session', () => {
    db.upsertSession(mockSession)
    db.deleteSession('session-001')
    expect(db.getSession('session-001')).toBeNull()
  })

  it('checks if file is already indexed', () => {
    db.upsertSession(mockSession)
    expect(db.isIndexed(mockSession.filePath, mockSession.sizeBytes)).toBe(true)
    expect(db.isIndexed(mockSession.filePath, 99999)).toBe(false)
  })
})
```

**Step 2: 运行测试确认失败**

```bash
npm test tests/core/db.test.ts
```

预期输出：`FAIL` — `Cannot find module '../../src/core/db.js'`

**Step 3: 实现 db.ts**

```typescript
// src/core/db.ts
import BetterSqlite3 from 'better-sqlite3'
import type { SessionInfo, SourceName } from '../adapters/types.js'

export interface ListSessionsOptions {
  source?: SourceName
  project?: string
  since?: string
  until?: string
  limit?: number
  offset?: number
}

export interface FtsMatch {
  sessionId: string
  content: string
  rank: number
}

export class Database {
  private db: BetterSqlite3.Database

  constructor(dbPath: string) {
    this.db = new BetterSqlite3(dbPath)
    this.db.pragma('journal_mode = WAL')
    this.db.pragma('foreign_keys = ON')
    this.migrate()
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT,
        cwd TEXT NOT NULL DEFAULT '',
        project TEXT,
        model TEXT,
        message_count INTEGER NOT NULL DEFAULT 0,
        user_message_count INTEGER NOT NULL DEFAULT 0,
        summary TEXT,
        file_path TEXT NOT NULL,
        size_bytes INTEGER NOT NULL DEFAULT 0,
        indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
      );

      CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
      CREATE INDEX IF NOT EXISTS idx_sessions_start_time ON sessions(start_time);
      CREATE INDEX IF NOT EXISTS idx_sessions_cwd ON sessions(cwd);
      CREATE INDEX IF NOT EXISTS idx_sessions_file_path ON sessions(file_path);

      CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
        session_id UNINDEXED,
        content,
        tokenize='unicode61'
      );
    `)
  }

  upsertSession(session: SessionInfo): void {
    this.db.prepare(`
      INSERT INTO sessions (id, source, start_time, end_time, cwd, project, model,
        message_count, user_message_count, summary, file_path, size_bytes, indexed_at)
      VALUES (@id, @source, @startTime, @endTime, @cwd, @project, @model,
        @messageCount, @userMessageCount, @summary, @filePath, @sizeBytes, datetime('now'))
      ON CONFLICT(id) DO UPDATE SET
        end_time = excluded.end_time,
        message_count = excluded.message_count,
        user_message_count = excluded.user_message_count,
        summary = excluded.summary,
        size_bytes = excluded.size_bytes,
        indexed_at = excluded.indexed_at
    `).run({
      id: session.id,
      source: session.source,
      startTime: session.startTime,
      endTime: session.endTime ?? null,
      cwd: session.cwd,
      project: session.project ?? null,
      model: session.model ?? null,
      messageCount: session.messageCount,
      userMessageCount: session.userMessageCount,
      summary: session.summary ?? null,
      filePath: session.filePath,
      sizeBytes: session.sizeBytes,
    })
  }

  getSession(id: string): SessionInfo | null {
    const row = this.db.prepare('SELECT * FROM sessions WHERE id = ?').get(id) as Record<string, unknown> | undefined
    return row ? this.rowToSession(row) : null
  }

  listSessions(opts: ListSessionsOptions = {}): SessionInfo[] {
    const conditions: string[] = []
    const params: Record<string, unknown> = {}

    if (opts.source) { conditions.push('source = @source'); params.source = opts.source }
    if (opts.project) { conditions.push('project LIKE @project'); params.project = `%${opts.project}%` }
    if (opts.since) { conditions.push('start_time >= @since'); params.since = opts.since }
    if (opts.until) { conditions.push('start_time <= @until'); params.until = opts.until }

    const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : ''
    const limit = opts.limit ?? 20
    const offset = opts.offset ?? 0

    const rows = this.db.prepare(`
      SELECT * FROM sessions ${where}
      ORDER BY start_time DESC
      LIMIT @limit OFFSET @offset
    `).all({ ...params, limit, offset }) as Record<string, unknown>[]

    return rows.map(r => this.rowToSession(r))
  }

  indexSessionContent(sessionId: string, messages: { role: string; content: string }[]): void {
    // 只索引用户消息，避免索引过大
    const deleteStmt = this.db.prepare('DELETE FROM sessions_fts WHERE session_id = ?')
    const insertStmt = this.db.prepare('INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)')

    const transaction = this.db.transaction(() => {
      deleteStmt.run(sessionId)
      for (const msg of messages) {
        if (msg.role === 'user' && msg.content.trim()) {
          insertStmt.run(sessionId, msg.content)
        }
      }
    })
    transaction()
  }

  searchSessions(query: string, limit = 20): FtsMatch[] {
    return this.db.prepare(`
      SELECT session_id as sessionId, content, rank
      FROM sessions_fts
      WHERE sessions_fts MATCH ?
      ORDER BY rank
      LIMIT ?
    `).all(query, limit) as FtsMatch[]
  }

  deleteSession(id: string): void {
    this.db.prepare('DELETE FROM sessions WHERE id = ?').run(id)
    this.db.prepare('DELETE FROM sessions_fts WHERE session_id = ?').run(id)
  }

  isIndexed(filePath: string, sizeBytes: number): boolean {
    const row = this.db.prepare(
      'SELECT id FROM sessions WHERE file_path = ? AND size_bytes = ?'
    ).get(filePath, sizeBytes)
    return row !== undefined
  }

  close(): void {
    this.db.close()
  }

  private rowToSession(row: Record<string, unknown>): SessionInfo {
    return {
      id: row.id as string,
      source: row.source as SessionInfo['source'],
      startTime: row.start_time as string,
      endTime: row.end_time as string | undefined,
      cwd: row.cwd as string,
      project: row.project as string | undefined,
      model: row.model as string | undefined,
      messageCount: row.message_count as number,
      userMessageCount: row.user_message_count as number,
      summary: row.summary as string | undefined,
      filePath: row.file_path as string,
      sizeBytes: row.size_bytes as number,
    }
  }
}
```

**Step 4: 运行测试确认通过**

```bash
npm test tests/core/db.test.ts
```

预期输出：`6 tests passed`

**Step 5: Commit**

```bash
git add src/core/db.ts tests/core/db.test.ts
git commit -m "feat: add SQLite database layer with FTS5 search"
```

---

## Phase 2: 适配器

### Task 4: Codex 适配器

**Files:**
- Create: `tests/fixtures/codex/sample.jsonl`
- Create: `src/adapters/codex.ts`
- Create: `tests/adapters/codex.test.ts`

**Step 1: 创建测试 fixture**

写入 `tests/fixtures/codex/sample.jsonl`（每行一个 JSON）：

```
{"timestamp":"2026-01-15T10:00:00.000Z","type":"session_meta","payload":{"id":"codex-session-001","timestamp":"2026-01-15T10:00:00.000Z","cwd":"/Users/test/my-project","originator":"codex_cli_rs","cli_version":"0.60.1","instructions":null,"source":"cli","model_provider":"openai"}}
{"timestamp":"2026-01-15T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"帮我修复登录 bug，用户无法登录"}]}}
{"timestamp":"2026-01-15T10:00:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"我来看看登录相关的代码"}]}}
{"timestamp":"2026-01-15T10:00:06.000Z","type":"response_item","payload":{"type":"function_call","name":"read_file","arguments":{"path":"src/auth.ts"}}}
{"timestamp":"2026-01-15T10:00:07.000Z","type":"response_item","payload":{"type":"function_call_output","output":"// auth.ts content..."}}
{"timestamp":"2026-01-15T10:00:10.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"好的，谢谢"}]}}
{"timestamp":"2026-01-15T10:05:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}
```

**Step 2: 写失败测试**

```typescript
// tests/adapters/codex.test.ts
import { describe, it, expect } from 'vitest'
import { CodexAdapter } from '../../src/adapters/codex.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(__dirname, '../fixtures/codex/sample.jsonl')

describe('CodexAdapter', () => {
  const adapter = new CodexAdapter()

  it('name is codex', () => {
    expect(adapter.name).toBe('codex')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('codex-session-001')
    expect(info!.source).toBe('codex')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.startTime).toBe('2026-01-15T10:00:00.000Z')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('帮我修复登录 bug，用户无法登录')
  })

  it('streamMessages yields user and assistant messages', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg)
    }
    expect(messages.length).toBeGreaterThanOrEqual(3)
    expect(messages[0].role).toBe('user')
    expect(messages[0].content).toBe('帮我修复登录 bug，用户无法登录')
    expect(messages[1].role).toBe('assistant')
  })

  it('streamMessages respects offset and limit', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE, { offset: 1, limit: 1 })) {
      messages.push(msg)
    }
    expect(messages).toHaveLength(1)
    expect(messages[0].role).toBe('assistant')
  })
})
```

**Step 3: 运行测试确认失败**

```bash
npm test tests/adapters/codex.test.ts
```

预期：`FAIL` — `Cannot find module`

**Step 4: 实现 codex.ts**

```typescript
// src/adapters/codex.ts
import { createReadStream } from 'fs'
import { stat } from 'fs/promises'
import { createInterface } from 'readline'
import { glob } from 'fs/promises'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

export class CodexAdapter implements SessionAdapter {
  readonly name = 'codex' as const
  private sessionsRoot: string

  constructor(sessionsRoot?: string) {
    this.sessionsRoot = sessionsRoot ?? join(homedir(), '.codex', 'sessions')
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.sessionsRoot)
      return true
    } catch {
      return false
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      // 递归找所有 rollout-*.jsonl
      const pattern = join(this.sessionsRoot, '**', 'rollout-*.jsonl')
      for await (const file of glob(pattern)) {
        yield file
      }
    } catch {
      // sessions root 不存在时静默返回
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      let meta: Record<string, unknown> | null = null
      let userCount = 0
      let totalCount = 0
      let firstUserText = ''
      let lastTimestamp = ''

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line)
        if (!obj) continue

        if (obj.type === 'session_meta') {
          meta = obj.payload as Record<string, unknown>
        }

        if (obj.type === 'response_item') {
          const payload = obj.payload as Record<string, unknown>
          if (payload.type === 'message') {
            totalCount++
            const role = payload.role as string
            if (role === 'user') {
              userCount++
              if (!firstUserText) {
                firstUserText = this.extractText(payload.content as unknown[])
              }
            }
            if (obj.timestamp) {
              lastTimestamp = obj.timestamp as string
            }
          }
        }
      }

      if (!meta) return null

      const payload = meta as Record<string, unknown>
      return {
        id: payload.id as string,
        source: 'codex',
        startTime: payload.timestamp as string,
        endTime: lastTimestamp || undefined,
        cwd: (payload.cwd as string) || '',
        model: payload.model_provider as string | undefined,
        messageCount: totalCount,
        userMessageCount: userCount,
        summary: firstUserText.slice(0, 200) || undefined,
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
    let count = 0
    let yielded = 0

    for await (const line of this.readLines(filePath)) {
      if (yielded >= limit) break
      const obj = this.parseLine(line)
      if (!obj) continue
      if (obj.type !== 'response_item') continue

      const payload = obj.payload as Record<string, unknown>
      if (payload.type !== 'message') continue

      const role = payload.role as string
      if (role !== 'user' && role !== 'assistant') continue

      if (count < offset) { count++; continue }
      count++

      yield {
        role: role as 'user' | 'assistant',
        content: this.extractText(payload.content as unknown[]),
        timestamp: obj.timestamp as string | undefined,
      }
      yielded++
    }
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' })
    const rl = createInterface({ input: stream, crlfDelay: Infinity })
    for await (const line of rl) {
      if (line.trim()) yield line
    }
  }

  private parseLine(line: string): Record<string, unknown> | null {
    try {
      return JSON.parse(line) as Record<string, unknown>
    } catch {
      return null
    }
  }

  private extractText(content: unknown[]): string {
    if (!Array.isArray(content)) return ''
    for (const item of content) {
      const c = item as Record<string, unknown>
      if (c.text) return c.text as string
      if (c.input_text) return c.input_text as string
    }
    return ''
  }
}
```

**Step 5: 运行测试确认通过**

```bash
npm test tests/adapters/codex.test.ts
```

预期：`4 tests passed`

**Step 6: Commit**

```bash
git add src/adapters/codex.ts tests/adapters/codex.test.ts tests/fixtures/codex/
git commit -m "feat: add Codex session adapter"
```

---

### Task 5: Claude Code 适配器

**Files:**
- Create: `tests/fixtures/claude-code/sample.jsonl`
- Create: `src/adapters/claude-code.ts`
- Create: `tests/adapters/claude-code.test.ts`

**Step 1: 创建测试 fixture**

写入 `tests/fixtures/claude-code/sample.jsonl`：

```
{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"/Users/test/my-project","sessionId":"cc-session-001","version":"2.1.58","gitBranch":"main","type":"user","message":{"role":"user","content":"请帮我添加用户注册功能"},"uuid":"msg-001","timestamp":"2026-01-20T09:00:00.000Z","todos":[],"permissionMode":"default"}
{"parentUuid":"msg-001","isSidechain":false,"userType":"external","cwd":"/Users/test/my-project","sessionId":"cc-session-001","version":"2.1.58","type":"assistant","message":{"id":"resp-001","type":"message","role":"assistant","content":[{"type":"text","text":"好的，我来帮你实现用户注册功能。"}]},"uuid":"msg-002","timestamp":"2026-01-20T09:00:05.000Z"}
{"parentUuid":"msg-002","isSidechain":false,"userType":"external","cwd":"/Users/test/my-project","sessionId":"cc-session-001","version":"2.1.58","type":"user","message":{"role":"user","content":"需要邮件验证吗？"},"uuid":"msg-003","timestamp":"2026-01-20T09:01:00.000Z","todos":[],"permissionMode":"default"}
{"type":"file-history-snapshot","messageId":"msg-snap","snapshot":{"trackedFileBackups":{},"timestamp":"2026-01-20T09:01:30.000Z"},"isSnapshotUpdate":false}
```

**Step 2: 写失败测试**

```typescript
// tests/adapters/claude-code.test.ts
import { describe, it, expect } from 'vitest'
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(__dirname, '../fixtures/claude-code/sample.jsonl')

describe('ClaudeCodeAdapter', () => {
  const adapter = new ClaudeCodeAdapter()

  it('name is claude-code', () => {
    expect(adapter.name).toBe('claude-code')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('cc-session-001')
    expect(info!.source).toBe('claude-code')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('请帮我添加用户注册功能')
  })

  it('streamMessages filters only user and assistant', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg)
    }
    // file-history-snapshot 应该被过滤掉
    expect(messages.every(m => m.role === 'user' || m.role === 'assistant')).toBe(true)
    expect(messages[0].role).toBe('user')
    expect(messages[0].content).toBe('请帮我添加用户注册功能')
  })

  it('decodeCwd converts encoded path to real path', () => {
    expect(ClaudeCodeAdapter.decodeCwd('-Users-test--my-project'))
      .toBe('/Users/test/-my-project')
  })
})
```

**Step 3: 运行测试确认失败**

```bash
npm test tests/adapters/claude-code.test.ts
```

**Step 4: 实现 claude-code.ts**

```typescript
// src/adapters/claude-code.ts
import { createReadStream } from 'fs'
import { stat, readdir } from 'fs/promises'
import { createInterface } from 'readline'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

export class ClaudeCodeAdapter implements SessionAdapter {
  readonly name = 'claude-code' as const
  private projectsRoot: string

  constructor(projectsRoot?: string) {
    this.projectsRoot = projectsRoot ?? join(homedir(), '.claude', 'projects')
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.projectsRoot)
      return true
    } catch {
      return false
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const projectDirs = await readdir(this.projectsRoot)
      for (const dir of projectDirs) {
        const projectPath = join(this.projectsRoot, dir)
        try {
          const files = await readdir(projectPath)
          for (const file of files) {
            if (file.endsWith('.jsonl')) {
              yield join(projectPath, file)
            }
          }
        } catch {
          // 跳过无法读取的目录
        }
      }
    } catch {
      // projectsRoot 不存在
    }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      let sessionId = ''
      let cwd = ''
      let startTime = ''
      let endTime = ''
      let userCount = 0
      let totalCount = 0
      let firstUserText = ''

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line)
        if (!obj) continue

        // 从 file-history-snapshot 或 progress 中跳过
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
            firstUserText = this.extractContent(msg?.content)
          }
        }
      }

      if (!sessionId) return null

      return {
        id: sessionId,
        source: 'claude-code',
        startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd,
        messageCount: totalCount,
        userMessageCount: userCount,
        summary: firstUserText.slice(0, 200) || undefined,
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
    let count = 0
    let yielded = 0

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

  // 解码 Claude Code 的项目目录名
  // -Users-example--Code--project → /Users/example/-Code-/project
  // 规则：单 `-` = `/`，双 `--` = `-`
  static decodeCwd(encoded: string): string {
    return encoded.replace(/--/g, '\x00').replace(/-/g, '/').replace(/\x00/g, '-')
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' })
    const rl = createInterface({ input: stream, crlfDelay: Infinity })
    for await (const line of rl) {
      if (line.trim()) yield line
    }
  }

  private parseLine(line: string): Record<string, unknown> | null {
    try {
      return JSON.parse(line) as Record<string, unknown>
    } catch {
      return null
    }
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

**Step 5: 运行测试确认通过**

```bash
npm test tests/adapters/claude-code.test.ts
```

预期：`4 tests passed`

**Step 6: Commit**

```bash
git add src/adapters/claude-code.ts tests/adapters/claude-code.test.ts tests/fixtures/claude-code/
git commit -m "feat: add Claude Code session adapter"
```

---

### Task 6: Gemini CLI 适配器

**Files:**
- Create: `tests/fixtures/gemini/session-sample.json`
- Create: `tests/fixtures/gemini/projects.json`
- Create: `src/adapters/gemini-cli.ts`
- Create: `tests/adapters/gemini-cli.test.ts`

**Step 1: 创建测试 fixture**

`tests/fixtures/gemini/projects.json`：
```json
{"/Users/test/my-project": "my-project", "/Users/test/other": "other-project"}
```

`tests/fixtures/gemini/session-sample.json`（写成一个 JSON 文件，不是 JSONL）：
```json
{
  "sessionId": "gemini-session-001",
  "projectHash": "abc123def456",
  "startTime": "2026-01-25T14:00:00.000Z",
  "lastUpdated": "2026-01-25T14:30:00.000Z",
  "messages": [
    {"id": "m001", "timestamp": "2026-01-25T14:00:10.000Z", "type": "user", "content": "帮我优化这段 SQL 查询"},
    {"id": "m002", "timestamp": "2026-01-25T14:00:20.000Z", "type": "model", "content": "我来分析这段查询..."},
    {"id": "m003", "timestamp": "2026-01-25T14:01:00.000Z", "type": "info", "content": "Tool call: read_file"},
    {"id": "m004", "timestamp": "2026-01-25T14:02:00.000Z", "type": "user", "content": "谢谢，还有别的优化建议吗？"}
  ]
}
```

**Step 2: 写失败测试**

```typescript
// tests/adapters/gemini-cli.test.ts
import { describe, it, expect } from 'vitest'
import { GeminiCliAdapter } from '../../src/adapters/gemini-cli.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_DIR = join(__dirname, '../fixtures/gemini')
const SESSION_FIXTURE = join(FIXTURE_DIR, 'session-sample.json')
const PROJECTS_FIXTURE = join(FIXTURE_DIR, 'projects.json')

describe('GeminiCliAdapter', () => {
  const adapter = new GeminiCliAdapter(FIXTURE_DIR, PROJECTS_FIXTURE)

  it('name is gemini-cli', () => {
    expect(adapter.name).toBe('gemini-cli')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(SESSION_FIXTURE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('gemini-session-001')
    expect(info!.source).toBe('gemini-cli')
    expect(info!.startTime).toBe('2026-01-25T14:00:00.000Z')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('帮我优化这段 SQL 查询')
  })

  it('streamMessages yields only user and model messages (not info)', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(SESSION_FIXTURE)) {
      messages.push(msg)
    }
    expect(messages).toHaveLength(3) // 2 user + 1 model，info 被过滤
    expect(messages.every(m => m.role === 'user' || m.role === 'assistant')).toBe(true)
  })

  it('resolves project name from projects.json', async () => {
    const projectName = await adapter.resolveProject('my-project')
    expect(projectName).toBe('/Users/test/my-project')
  })
})
```

**Step 3: 运行测试确认失败**

```bash
npm test tests/adapters/gemini-cli.test.ts
```

**Step 4: 实现 gemini-cli.ts**

```typescript
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
      const projectName = parts[parts.indexOf('chats') - 1] ?? ''

      return {
        id: session.sessionId,
        source: 'gemini-cli',
        startTime: session.startTime,
        endTime: session.lastUpdated,
        cwd: projectName, // 先存 projectName，indexer 会通过 projects.json 解析出 cwd
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
    const sliced = relevant.slice(offset, limit === Infinity ? undefined : offset + limit)

    for (const msg of sliced) {
      yield {
        role: msg.type === 'model' ? 'assistant' : 'user',
        content: msg.content,
        timestamp: msg.timestamp,
      }
    }
  }

  // 返回 projectName → cwd 的映射
  async resolveProject(projectName: string): Promise<string | null> {
    const map = await this.loadProjects()
    // projects.json 是 { cwd: projectName }，需要反查
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
      const projects = (obj.projects ?? obj) as Record<string, string>
      this.projectsCache = new Map(Object.entries(projects))
    } catch {
      this.projectsCache = new Map()
    }
    return this.projectsCache
  }
}
```

**Step 5: 运行测试确认通过**

```bash
npm test tests/adapters/gemini-cli.test.ts
```

预期：`4 tests passed`

**Step 6: Commit**

```bash
git add src/adapters/gemini-cli.ts tests/adapters/gemini-cli.test.ts tests/fixtures/gemini/
git commit -m "feat: add Gemini CLI session adapter"
```

---

### Task 7: OpenCode 适配器

**Files:**
- Create: `tests/fixtures/opencode/ses_abc123.json`
- Create: `src/adapters/opencode.ts`
- Create: `tests/adapters/opencode.test.ts`

**Step 1: 探索实际 OpenCode 格式（先运行这个命令再写 fixture）**

```bash
find ~/.local/share/opencode/storage/session_diff -name "*.json" | head -3 | xargs -I{} sh -c 'echo "=== {} ===" && cat {} | head -5'
```

如果 session_diff 文件是空数组，尝试：
```bash
ls ~/.local/share/opencode/storage/
```

根据实际格式创建 fixture。如果 OpenCode 格式无法确认，写一个 stub 适配器（`detect()` 返回 false，其他方法空实现），等格式明确后补全。

**Step 2: 写 stub 测试**

```typescript
// tests/adapters/opencode.test.ts
import { describe, it, expect } from 'vitest'
import { OpenCodeAdapter } from '../../src/adapters/opencode.js'

describe('OpenCodeAdapter', () => {
  it('name is opencode', () => {
    const adapter = new OpenCodeAdapter()
    expect(adapter.name).toBe('opencode')
  })

  it('detect returns false if storage dir not found', async () => {
    const adapter = new OpenCodeAdapter('/nonexistent/path')
    expect(await adapter.detect()).toBe(false)
  })
})
```

**Step 3: 实现 opencode.ts（stub）**

```typescript
// src/adapters/opencode.ts
import { stat } from 'fs/promises'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

export class OpenCodeAdapter implements SessionAdapter {
  readonly name = 'opencode' as const
  private storageRoot: string

  constructor(storageRoot?: string) {
    this.storageRoot = storageRoot ?? join(homedir(), '.local', 'share', 'opencode', 'storage')
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.storageRoot)
      return true
    } catch {
      return false
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    // TODO: 实现后补全，需确认 session_diff 格式
  }

  async parseSessionInfo(_filePath: string): Promise<SessionInfo | null> {
    // TODO: 实现后补全
    return null
  }

  async *streamMessages(_filePath: string, _opts?: StreamMessagesOptions): AsyncGenerator<Message> {
    // TODO: 实现后补全
  }
}
```

**Step 4: 运行测试确认通过**

```bash
npm test tests/adapters/opencode.test.ts
```

**Step 5: Commit**

```bash
git add src/adapters/opencode.ts tests/adapters/opencode.test.ts
git commit -m "feat: add OpenCode adapter stub (pending format investigation)"
```

---

## Phase 3: 核心基础设施

### Task 8: 项目名解析器

**Files:**
- Create: `src/core/project.ts`
- Create: `tests/core/project.test.ts`

**Step 1: 写失败测试**

```typescript
// tests/core/project.test.ts
import { describe, it, expect } from 'vitest'
import { resolveProjectName } from '../../src/core/project.js'

describe('resolveProjectName', () => {
  it('uses last path segment as project name', async () => {
    // 对于不存在的路径，fallback 到目录名
    const name = await resolveProjectName('/Users/test/my-awesome-project')
    expect(name).toBe('my-awesome-project')
  })

  it('handles root directory', async () => {
    const name = await resolveProjectName('/')
    expect(name).toBe('/')
  })

  it('handles empty cwd', async () => {
    const name = await resolveProjectName('')
    expect(name).toBe('')
  })
})
```

**Step 2: 实现 project.ts**

```typescript
// src/core/project.ts
import { execFile } from 'child_process'
import { promisify } from 'util'
import { basename } from 'path'

const execFileAsync = promisify(execFile)

// 尝试从 git remote 获取项目名，fallback 到目录名
export async function resolveProjectName(cwd: string): Promise<string> {
  if (!cwd) return ''

  try {
    const { stdout } = await execFileAsync('git', ['-C', cwd, 'remote', 'get-url', 'origin'], {
      timeout: 2000,
    })
    const url = stdout.trim()
    // 从 git URL 提取仓库名
    // https://github.com/user/repo.git → repo
    // git@github.com:user/repo.git → repo
    const match = url.match(/([^/:]+?)(?:\.git)?$/)
    if (match?.[1]) return match[1]
  } catch {
    // 不是 git 仓库或命令失败，fallback
  }

  return basename(cwd) || cwd
}
```

**Step 3: 运行测试**

```bash
npm test tests/core/project.test.ts
```

预期：`3 tests passed`

**Step 4: Commit**

```bash
git add src/core/project.ts tests/core/project.test.ts
git commit -m "feat: add project name resolver"
```

---

### Task 9: 索引器

**Files:**
- Create: `src/core/indexer.ts`
- Create: `tests/core/indexer.test.ts`

**Step 1: 写失败测试**

```typescript
// tests/core/indexer.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { Indexer } from '../../src/core/indexer.js'
import { Database } from '../../src/core/db.js'
import { CodexAdapter } from '../../src/adapters/codex.js'
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('Indexer', () => {
  let db: Database
  let tmpDir: string
  let sessionsDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'indexer-test-'))
    sessionsDir = join(tmpDir, 'sessions', '2026', '01', '15')
    mkdirSync(sessionsDir, { recursive: true })
    db = new Database(join(tmpDir, 'index.sqlite'))
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('indexes a session file', async () => {
    // 创建一个测试 JSONL 文件
    const sessionFile = join(sessionsDir, 'rollout-2026-01-15T10-00-00-test001.jsonl')
    writeFileSync(sessionFile, [
      JSON.stringify({ timestamp: '2026-01-15T10:00:00.000Z', type: 'session_meta', payload: { id: 'test-001', timestamp: '2026-01-15T10:00:00.000Z', cwd: '/Users/test', model_provider: 'openai' } }),
      JSON.stringify({ timestamp: '2026-01-15T10:00:01.000Z', type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '测试消息' }] } }),
    ].join('\n'))

    const codexAdapter = new CodexAdapter(join(tmpDir, 'sessions'))
    const indexer = new Indexer(db, [codexAdapter])
    const count = await indexer.indexAll()

    expect(count).toBe(1)
    const sessions = db.listSessions()
    expect(sessions).toHaveLength(1)
    expect(sessions[0].id).toBe('test-001')
  })

  it('skips already-indexed files with same size', async () => {
    const sessionFile = join(sessionsDir, 'rollout-2026-01-15T10-00-00-test002.jsonl')
    writeFileSync(sessionFile, [
      JSON.stringify({ timestamp: '2026-01-15T10:00:00.000Z', type: 'session_meta', payload: { id: 'test-002', timestamp: '2026-01-15T10:00:00.000Z', cwd: '/tmp', model_provider: 'openai' } }),
      JSON.stringify({ timestamp: '2026-01-15T10:00:01.000Z', type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hello' }] } }),
    ].join('\n'))

    const codexAdapter = new CodexAdapter(join(tmpDir, 'sessions'))
    const indexer = new Indexer(db, [codexAdapter])

    const firstRun = await indexer.indexAll()
    const secondRun = await indexer.indexAll()

    expect(firstRun).toBe(1)
    expect(secondRun).toBe(0) // 第二次跳过
  })
})
```

**Step 2: 实现 indexer.ts**

```typescript
// src/core/indexer.ts
import type { SessionAdapter } from '../adapters/types.js'
import type { Database } from './db.js'
import { resolveProjectName } from './project.js'
import { stat } from 'fs/promises'

export class Indexer {
  constructor(
    private db: Database,
    private adapters: SessionAdapter[]
  ) {}

  // 全量扫描，返回新增索引数量
  async indexAll(): Promise<number> {
    let newCount = 0

    for (const adapter of this.adapters) {
      if (!await adapter.detect()) continue

      for await (const filePath of adapter.listSessionFiles()) {
        try {
          const fileStat = await stat(filePath)
          // 跳过已索引且大小未变的文件
          if (this.db.isIndexed(filePath, fileStat.size)) continue

          const info = await adapter.parseSessionInfo(filePath)
          if (!info) continue

          // 解析项目名
          if (info.cwd && !info.project) {
            info.project = await resolveProjectName(info.cwd)
          }

          // 写入索引
          this.db.upsertSession(info)

          // 索引用户消息内容（用于全文搜索）
          const messages: { role: string; content: string }[] = []
          for await (const msg of adapter.streamMessages(filePath)) {
            if (msg.role === 'user') {
              messages.push({ role: msg.role, content: msg.content })
            }
          }
          this.db.indexSessionContent(info.id, messages)

          newCount++
        } catch {
          // 跳过无法处理的文件
        }
      }
    }

    return newCount
  }

  // 索引单个文件（增量更新时使用）
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
        if (msg.role === 'user') {
          messages.push({ role: msg.role, content: msg.content })
        }
      }
      this.db.indexSessionContent(info.id, messages)
      return true
    } catch {
      return false
    }
  }
}
```

**Step 3: 运行测试**

```bash
npm test tests/core/indexer.test.ts
```

预期：`2 tests passed`

**Step 4: Commit**

```bash
git add src/core/indexer.ts tests/core/indexer.test.ts
git commit -m "feat: add session indexer with incremental update support"
```

---

## Phase 4: MCP Tools

### Task 10: MCP Server 入口 + list_sessions tool

**Files:**
- Create: `src/tools/list_sessions.ts`
- Create: `src/index.ts`
- Create: `tests/tools/list_sessions.test.ts`

**Step 1: 写失败测试**

```typescript
// tests/tools/list_sessions.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { listSessionsTool, handleListSessions } from '../../src/tools/list_sessions.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('list_sessions tool', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'tools-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    // 插入测试数据
    db.upsertSession({ id: 's1', source: 'codex', startTime: '2026-01-01T10:00:00Z', cwd: '/project-a', project: 'project-a', messageCount: 10, userMessageCount: 5, filePath: '/f1', sizeBytes: 100 })
    db.upsertSession({ id: 's2', source: 'claude-code', startTime: '2026-01-02T10:00:00Z', cwd: '/project-b', project: 'project-b', messageCount: 8, userMessageCount: 4, filePath: '/f2', sizeBytes: 200 })
    db.upsertSession({ id: 's3', source: 'codex', startTime: '2025-12-01T10:00:00Z', cwd: '/project-a', project: 'project-a', messageCount: 5, userMessageCount: 2, filePath: '/f3', sizeBytes: 50 })
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('returns all sessions without filters', async () => {
    const result = await handleListSessions(db, {})
    expect(result.sessions).toHaveLength(3)
  })

  it('filters by source', async () => {
    const result = await handleListSessions(db, { source: 'codex' })
    expect(result.sessions).toHaveLength(2)
    expect(result.sessions.every(s => s.source === 'codex')).toBe(true)
  })

  it('filters by since date', async () => {
    const result = await handleListSessions(db, { since: '2026-01-01T00:00:00Z' })
    expect(result.sessions).toHaveLength(2)
  })

  it('tool schema is valid MCP format', () => {
    expect(listSessionsTool.name).toBe('list_sessions')
    expect(listSessionsTool.inputSchema.type).toBe('object')
  })
})
```

**Step 2: 实现 list_sessions.ts**

```typescript
// src/tools/list_sessions.ts
import type { Database, ListSessionsOptions } from '../core/db.js'
import type { SourceName } from '../adapters/types.js'

export const listSessionsTool = {
  name: 'list_sessions',
  description: '列出 AI 编程助手的历史会话。支持按工具来源、项目、时间范围过滤。',
  inputSchema: {
    type: 'object' as const,
    properties: {
      source: {
        type: 'string',
        enum: ['codex', 'claude-code', 'gemini-cli', 'opencode'],
        description: '过滤特定工具的会话',
      },
      project: {
        type: 'string',
        description: '过滤特定项目（部分匹配项目名或路径）',
      },
      since: {
        type: 'string',
        description: '开始时间（ISO 8601 格式，如 2026-01-01T00:00:00Z）',
      },
      until: {
        type: 'string',
        description: '结束时间（ISO 8601 格式）',
      },
      limit: {
        type: 'number',
        description: '最多返回条数，默认 20，最大 100',
      },
      offset: {
        type: 'number',
        description: '分页偏移量',
      },
    },
    additionalProperties: false,
  },
}

export async function handleListSessions(
  db: Database,
  params: {
    source?: SourceName
    project?: string
    since?: string
    until?: string
    limit?: number
    offset?: number
  }
) {
  const opts: ListSessionsOptions = {
    source: params.source,
    project: params.project,
    since: params.since,
    until: params.until,
    limit: Math.min(params.limit ?? 20, 100),
    offset: params.offset ?? 0,
  }

  const sessions = db.listSessions(opts)

  return {
    sessions: sessions.map(s => ({
      id: s.id,
      source: s.source,
      startTime: s.startTime,
      endTime: s.endTime,
      cwd: s.cwd,
      project: s.project,
      model: s.model,
      messageCount: s.messageCount,
      userMessageCount: s.userMessageCount,
      summary: s.summary,
    })),
    total: sessions.length,
  }
}
```

**Step 3: 创建 MCP server 入口 src/index.ts**

```typescript
#!/usr/bin/env node
// src/index.ts
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { homedir } from 'os'
import { join } from 'path'
import { mkdirSync } from 'fs'

import { Database } from './core/db.js'
import { Indexer } from './core/indexer.js'
import { CodexAdapter } from './adapters/codex.js'
import { ClaudeCodeAdapter } from './adapters/claude-code.js'
import { GeminiCliAdapter } from './adapters/gemini-cli.js'
import { OpenCodeAdapter } from './adapters/opencode.js'
import { listSessionsTool, handleListSessions } from './tools/list_sessions.js'

const DB_DIR = join(homedir(), '.coding-memory')
mkdirSync(DB_DIR, { recursive: true })
const db = new Database(join(DB_DIR, 'index.sqlite'))

const adapters = [
  new CodexAdapter(),
  new ClaudeCodeAdapter(),
  new GeminiCliAdapter(),
  new OpenCodeAdapter(),
]

const indexer = new Indexer(db, adapters)

const server = new Server(
  { name: 'coding-memory', version: '0.1.0' },
  { capabilities: { tools: {} } }
)

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [listSessionsTool],
}))

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params

  try {
    if (name === 'list_sessions') {
      const result = await handleListSessions(db, args as Record<string, unknown> ?? {})
      return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] }
    }

    return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true }
  } catch (err) {
    return { content: [{ type: 'text', text: String(err) }], isError: true }
  }
})

// 启动时建立索引
indexer.indexAll().then(count => {
  if (count > 0) {
    process.stderr.write(`[coding-memory] Indexed ${count} new sessions\n`)
  }
}).catch(() => {})

const transport = new StdioServerTransport()
await server.connect(transport)
```

**Step 4: 运行所有测试**

```bash
npm test
```

预期：全部 pass

**Step 5: 编译验证**

```bash
npm run build
```

预期：`dist/` 目录下生成 JS 文件，无编译错误

**Step 6: Commit**

```bash
git add src/tools/list_sessions.ts src/index.ts tests/tools/list_sessions.test.ts
git commit -m "feat: add MCP server entry and list_sessions tool"
```

---

### Task 11: get_session tool

**Files:**
- Create: `src/tools/get_session.ts`
- Modify: `src/index.ts`
- Create: `tests/tools/get_session.test.ts`

**Step 1: 写失败测试**

```typescript
// tests/tools/get_session.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { handleGetSession } from '../../src/tools/get_session.js'
import { Database } from '../../src/core/db.js'
import { CodexAdapter } from '../../src/adapters/codex.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(__dirname, '../fixtures/codex/sample.jsonl')

describe('get_session', () => {
  let db: Database
  let tmpDir: string

  beforeEach(async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'get-session-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    const adapter = new CodexAdapter()
    const info = await adapter.parseSessionInfo(FIXTURE)
    if (info) db.upsertSession(info)
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('returns session with messages', async () => {
    const adapter = new CodexAdapter()
    const result = await handleGetSession(db, adapter, { id: 'codex-session-001', page: 1 })
    expect(result.session).not.toBeNull()
    expect(result.messages.length).toBeGreaterThan(0)
    expect(result.totalPages).toBeGreaterThanOrEqual(1)
  })

  it('returns error for unknown id', async () => {
    const adapter = new CodexAdapter()
    await expect(handleGetSession(db, adapter, { id: 'nonexistent' }))
      .rejects.toThrow('Session not found')
  })
})
```

**Step 2: 实现 get_session.ts**

```typescript
// src/tools/get_session.ts
import type { Database } from '../core/db.js'
import type { SessionAdapter } from '../adapters/types.js'

const PAGE_SIZE = 50

export const getSessionTool = {
  name: 'get_session',
  description: '读取单个会话的完整对话内容。大会话支持分页（每页 50 条消息）。',
  inputSchema: {
    type: 'object' as const,
    required: ['id'],
    properties: {
      id: { type: 'string', description: '会话 ID' },
      page: { type: 'number', description: '页码，从 1 开始，默认 1' },
      roles: {
        type: 'array',
        items: { type: 'string', enum: ['user', 'assistant'] },
        description: '只返回指定角色的消息，默认返回全部',
      },
    },
    additionalProperties: false,
  },
}

export async function handleGetSession(
  db: Database,
  adapter: SessionAdapter,
  params: { id: string; page?: number; roles?: string[] }
) {
  const session = db.getSession(params.id)
  if (!session) throw new Error(`Session not found: ${params.id}`)

  const page = params.page ?? 1
  const offset = (page - 1) * PAGE_SIZE

  const allMessages: { role: string; content: string; timestamp?: string }[] = []
  for await (const msg of adapter.streamMessages(session.filePath)) {
    if (!params.roles || params.roles.includes(msg.role)) {
      allMessages.push(msg)
    }
  }

  const totalPages = Math.ceil(allMessages.length / PAGE_SIZE)
  const messages = allMessages.slice(offset, offset + PAGE_SIZE)

  return { session, messages, totalPages, currentPage: page }
}
```

**Step 3: 在 src/index.ts 里注册 get_session**

在 `import` 部分加：
```typescript
import { getSessionTool, handleGetSession } from './tools/get_session.js'
```

在 `ListToolsRequestSchema` handler 里的 `tools` 数组加 `getSessionTool`。

在 `CallToolRequestSchema` handler 里加：
```typescript
if (name === 'get_session') {
  const a = args as { id: string; page?: number; roles?: string[] }
  // 根据会话 source 选择适配器
  const session = db.getSession(a.id)
  if (!session) return { content: [{ type: 'text', text: 'Session not found' }], isError: true }
  const adapterMap: Record<string, SessionAdapter> = {
    'codex': adapters[0],
    'claude-code': adapters[1],
    'gemini-cli': adapters[2],
    'opencode': adapters[3],
  }
  const adapter = adapterMap[session.source]
  if (!adapter) return { content: [{ type: 'text', text: 'Unsupported source' }], isError: true }
  const result = await handleGetSession(db, adapter, a)
  return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] }
}
```

**Step 4: 运行测试**

```bash
npm test
```

**Step 5: Commit**

```bash
git add src/tools/get_session.ts src/index.ts tests/tools/get_session.test.ts
git commit -m "feat: add get_session tool with pagination"
```

---

### Task 12: search tool

**Files:**
- Create: `src/tools/search.ts`
- Modify: `src/index.ts`
- Create: `tests/tools/search.test.ts`

**Step 1: 写失败测试**

```typescript
// tests/tools/search.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { handleSearch } from '../../src/tools/search.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('search', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    db.upsertSession({ id: 's1', source: 'codex', startTime: '2026-01-01T10:00:00Z', cwd: '/p', messageCount: 5, userMessageCount: 2, filePath: '/f1', sizeBytes: 100 })
    db.indexSessionContent('s1', [
      { role: 'user', content: '帮我修复 SSL 证书错误，nginx 返回 403' },
    ])

    db.upsertSession({ id: 's2', source: 'claude-code', startTime: '2026-01-02T10:00:00Z', cwd: '/p', messageCount: 3, userMessageCount: 1, filePath: '/f2', sizeBytes: 50 })
    db.indexSessionContent('s2', [
      { role: 'user', content: '添加用户注册功能' },
    ])
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('finds session by keyword', async () => {
    const result = await handleSearch(db, { query: 'SSL' })
    expect(result.results.length).toBeGreaterThan(0)
    expect(result.results[0].session.id).toBe('s1')
  })

  it('returns empty for no match', async () => {
    const result = await handleSearch(db, { query: 'kubernetes' })
    expect(result.results).toHaveLength(0)
  })
})
```

**Step 2: 实现 search.ts**

```typescript
// src/tools/search.ts
import type { Database } from '../core/db.js'
import type { SourceName } from '../adapters/types.js'

export const searchTool = {
  name: 'search',
  description: '在所有会话内容中全文搜索。使用 SQLite FTS5，支持中英文。',
  inputSchema: {
    type: 'object' as const,
    required: ['query'],
    properties: {
      query: { type: 'string', description: '搜索关键词' },
      source: { type: 'string', enum: ['codex', 'claude-code', 'gemini-cli', 'opencode'] },
      project: { type: 'string' },
      since: { type: 'string' },
      limit: { type: 'number', description: '默认 10，最大 50' },
    },
    additionalProperties: false,
  },
}

export async function handleSearch(
  db: Database,
  params: { query: string; source?: SourceName; project?: string; since?: string; limit?: number }
) {
  const limit = Math.min(params.limit ?? 10, 50)
  const matches = db.searchSessions(params.query, limit * 3) // 多查一些，方便过滤

  const results: { session: ReturnType<Database['getSession']>; snippet: string }[] = []
  const seen = new Set<string>()

  for (const match of matches) {
    if (seen.has(match.sessionId)) continue
    seen.add(match.sessionId)

    const session = db.getSession(match.sessionId)
    if (!session) continue
    if (params.source && session.source !== params.source) continue
    if (params.project && !session.project?.includes(params.project)) continue
    if (params.since && session.startTime < params.since) continue

    // 简单高亮：找到关键词前后 80 字符
    const idx = match.content.indexOf(params.query)
    const start = Math.max(0, idx - 80)
    const end = Math.min(match.content.length, idx + params.query.length + 80)
    const snippet = (start > 0 ? '...' : '') + match.content.slice(start, end) + (end < match.content.length ? '...' : '')

    results.push({ session, snippet })
    if (results.length >= limit) break
  }

  return { results, query: params.query }
}
```

**Step 3: 注册到 src/index.ts**（仿照前面 tool 的模式）

**Step 4: 运行测试**

```bash
npm test
```

**Step 5: Commit**

```bash
git add src/tools/search.ts src/index.ts tests/tools/search.test.ts
git commit -m "feat: add full-text search tool"
```

---

### Task 13: project_timeline + stats tools

**Files:**
- Create: `src/tools/project_timeline.ts`
- Create: `src/tools/stats.ts`
- Modify: `src/index.ts`

**Step 1: 实现 project_timeline.ts**

```typescript
// src/tools/project_timeline.ts
import type { Database } from '../core/db.js'

export const projectTimelineTool = {
  name: 'project_timeline',
  description: '查看某个项目跨工具的操作时间线，了解在不同 AI 助手里分别做了什么。',
  inputSchema: {
    type: 'object' as const,
    required: ['project'],
    properties: {
      project: { type: 'string', description: '项目名或路径片段' },
      since: { type: 'string' },
      until: { type: 'string' },
    },
    additionalProperties: false,
  },
}

export async function handleProjectTimeline(
  db: Database,
  params: { project: string; since?: string; until?: string }
) {
  const sessions = db.listSessions({ project: params.project, since: params.since, until: params.until, limit: 200 })
  const timeline = sessions.map(s => ({
    time: s.startTime,
    source: s.source,
    summary: s.summary ?? '（无摘要）',
    sessionId: s.id,
    messageCount: s.messageCount,
  })).sort((a, b) => a.time.localeCompare(b.time))

  return { project: params.project, timeline, total: timeline.length }
}
```

**Step 2: 实现 stats.ts**

```typescript
// src/tools/stats.ts
import type { Database } from '../core/db.js'

export const statsTool = {
  name: 'stats',
  description: '统计各工具的会话数量、消息数等用量数据。',
  inputSchema: {
    type: 'object' as const,
    properties: {
      since: { type: 'string' },
      until: { type: 'string' },
      group_by: {
        type: 'string',
        enum: ['source', 'project', 'day', 'week'],
        description: '按维度分组，默认 source',
      },
    },
    additionalProperties: false,
  },
}

export async function handleStats(
  db: Database,
  params: { since?: string; until?: string; group_by?: string }
) {
  const groupBy = params.group_by ?? 'source'
  const sessions = db.listSessions({ since: params.since, until: params.until, limit: 10000 })

  const groups: Record<string, { sessionCount: number; messageCount: number; userMessageCount: number }> = {}

  for (const s of sessions) {
    let key: string
    if (groupBy === 'source') key = s.source
    else if (groupBy === 'project') key = s.project ?? '(unknown)'
    else if (groupBy === 'day') key = s.startTime.slice(0, 10)
    else if (groupBy === 'week') {
      const d = new Date(s.startTime)
      d.setDate(d.getDate() - d.getDay())
      key = d.toISOString().slice(0, 10)
    } else key = s.source

    if (!groups[key]) groups[key] = { sessionCount: 0, messageCount: 0, userMessageCount: 0 }
    groups[key].sessionCount++
    groups[key].messageCount += s.messageCount
    groups[key].userMessageCount += s.userMessageCount
  }

  return {
    groupBy,
    groups: Object.entries(groups).map(([key, val]) => ({ key, ...val }))
      .sort((a, b) => b.sessionCount - a.sessionCount),
    totalSessions: sessions.length,
  }
}
```

**Step 3: 注册到 src/index.ts**

**Step 4: 运行所有测试**

```bash
npm test && npm run build
```

**Step 5: Commit**

```bash
git add src/tools/project_timeline.ts src/tools/stats.ts src/index.ts
git commit -m "feat: add project_timeline and stats tools"
```

---

### Task 14: get_context tool（核心）

**Files:**
- Create: `src/tools/get_context.ts`
- Modify: `src/index.ts`
- Create: `tests/tools/get_context.test.ts`

**Step 1: 写失败测试**

```typescript
// tests/tools/get_context.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { handleGetContext } from '../../src/tools/get_context.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('get_context', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'get-context-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    db.upsertSession({ id: 's1', source: 'codex', startTime: '2026-01-20T10:00:00Z', cwd: '/Users/test/myapp', project: 'myapp', summary: '修复了认证 bug', messageCount: 20, userMessageCount: 10, filePath: '/f1', sizeBytes: 100 })
    db.upsertSession({ id: 's2', source: 'claude-code', startTime: '2026-01-21T10:00:00Z', cwd: '/Users/test/myapp', project: 'myapp', summary: '添加了注册功能', messageCount: 15, userMessageCount: 7, filePath: '/f2', sizeBytes: 80 })
    db.upsertSession({ id: 's3', source: 'gemini-cli', startTime: '2026-01-15T10:00:00Z', cwd: '/Users/test/other', project: 'other', summary: '完全不相关的项目', messageCount: 5, userMessageCount: 2, filePath: '/f3', sizeBytes: 30 })
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('returns context for matching project', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp' })
    expect(result.sessions.length).toBeGreaterThan(0)
    expect(result.sessions.every(s => s.project === 'myapp')).toBe(true)
  })

  it('does not include unrelated project', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp' })
    expect(result.sessions.every(s => s.cwd !== '/Users/test/other')).toBe(true)
  })

  it('respects max_tokens budget', async () => {
    const result = await handleGetContext(db, { cwd: '/Users/test/myapp', max_tokens: 100 })
    // 100 token 非常小，应该只返回少量内容
    expect(result.contextText.length).toBeLessThan(600) // 约 100 tokens
  })
})
```

**Step 2: 实现 get_context.ts**

```typescript
// src/tools/get_context.ts
import type { Database } from '../core/db.js'
import { basename } from 'path'

export const getContextTool = {
  name: 'get_context',
  description: '为当前工作目录自动提取相关的历史会话上下文。在开始新任务时调用，获取该项目的历史记录。',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: '当前工作目录（绝对路径）' },
      task: { type: 'string', description: '当前任务描述（可选，用于提示相关性）' },
      max_tokens: { type: 'number', description: '上下文 token 预算，默认 4000（约 16000 字符）' },
    },
    additionalProperties: false,
  },
}

const CHARS_PER_TOKEN = 4 // 粗略估算

export async function handleGetContext(
  db: Database,
  params: { cwd: string; task?: string; max_tokens?: number }
) {
  const maxTokens = params.max_tokens ?? 4000
  const maxChars = maxTokens * CHARS_PER_TOKEN

  // 先按 cwd 精确匹配，找不到再用目录名模糊匹配
  let sessions = db.listSessions({ project: basename(params.cwd), limit: 50 })
  if (sessions.length === 0) {
    sessions = db.listSessions({ project: params.cwd, limit: 50 })
  }

  // 按时间倒序（最新在前），拼接摘要直到 token 预算用完
  const contextParts: string[] = []
  let totalChars = 0
  const selectedSessions: typeof sessions = []

  if (params.task) {
    contextParts.push(`当前任务：${params.task}\n`)
    totalChars += contextParts[0].length
  }

  for (const session of sessions) {
    if (!session.summary) continue
    const line = `[${session.source}] ${session.startTime.slice(0, 10)} — ${session.summary}\n`
    if (totalChars + line.length > maxChars) break
    contextParts.push(line)
    totalChars += line.length
    selectedSessions.push(session)
  }

  return {
    cwd: params.cwd,
    sessions: selectedSessions,
    contextText: contextParts.join(''),
    sessionCount: selectedSessions.length,
    estimatedTokens: Math.ceil(totalChars / CHARS_PER_TOKEN),
  }
}
```

**Step 3: 注册到 src/index.ts**

**Step 4: 运行所有测试 + 编译**

```bash
npm test && npm run build
```

**Step 5: Commit**

```bash
git add src/tools/get_context.ts src/index.ts tests/tools/get_context.test.ts
git commit -m "feat: add get_context tool for intelligent context extraction"
```

---

### Task 15: export tool + file watcher

**Files:**
- Create: `src/tools/export.ts`
- Create: `src/core/watcher.ts`
- Modify: `src/index.ts`

**Step 1: 实现 export.ts**

```typescript
// src/tools/export.ts
import { writeFile } from 'fs/promises'
import { homedir } from 'os'
import { join } from 'path'
import type { Database } from '../core/db.js'
import type { SessionAdapter } from '../adapters/types.js'

export const exportTool = {
  name: 'export',
  description: '将单个会话导出为 Markdown 或 JSON 文件，保存到 ~/codex-exports/ 目录。',
  inputSchema: {
    type: 'object' as const,
    required: ['id'],
    properties: {
      id: { type: 'string', description: '会话 ID' },
      format: { type: 'string', enum: ['markdown', 'json'], description: '默认 markdown' },
    },
    additionalProperties: false,
  },
}

export async function handleExport(
  db: Database,
  adapter: SessionAdapter,
  params: { id: string; format?: string }
) {
  const session = db.getSession(params.id)
  if (!session) throw new Error(`Session not found: ${params.id}`)

  const format = params.format ?? 'markdown'
  const messages: { role: string; content: string; timestamp?: string }[] = []
  for await (const msg of adapter.streamMessages(session.filePath)) {
    messages.push(msg)
  }

  const outputDir = join(homedir(), 'codex-exports')
  const filename = `${session.source}-${session.id.slice(0, 8)}-${session.startTime.slice(0, 10)}.${format === 'json' ? 'json' : 'md'}`
  const outputPath = join(outputDir, filename)

  let content: string
  if (format === 'json') {
    content = JSON.stringify({ session, messages }, null, 2)
  } else {
    const lines = [
      `# Session: ${session.id}`,
      `\n**Source:** ${session.source}  `,
      `**Date:** ${session.startTime}  `,
      `**Project:** ${session.project ?? session.cwd}  `,
      `**Messages:** ${session.messageCount}\n`,
      '---\n',
    ]
    for (const msg of messages) {
      lines.push(`### ${msg.role === 'user' ? '👤 User' : '🤖 Assistant'}\n`)
      lines.push(msg.content + '\n')
      lines.push('---\n')
    }
    content = lines.join('\n')
  }

  const { mkdirSync } = await import('fs')
  mkdirSync(outputDir, { recursive: true })
  await writeFile(outputPath, content, 'utf8')

  return { outputPath, format, messageCount: messages.length }
}
```

**Step 2: 实现 watcher.ts**

```typescript
// src/core/watcher.ts
import chokidar from 'chokidar'
import type { SessionAdapter } from '../adapters/types.js'
import type { Indexer } from './indexer.js'

export function startWatcher(adapters: SessionAdapter[], indexer: Indexer): void {
  const watchPaths: string[] = []

  // 收集所有适配器的监听路径（同步检查）
  for (const adapter of adapters) {
    if (adapter.name === 'codex') {
      const { homedir } = require('os')
      const { join } = require('path')
      watchPaths.push(join(homedir(), '.codex', 'sessions'))
    } else if (adapter.name === 'claude-code') {
      const { homedir } = require('os')
      const { join } = require('path')
      watchPaths.push(join(homedir(), '.claude', 'projects'))
    } else if (adapter.name === 'gemini-cli') {
      const { homedir } = require('os')
      const { join } = require('path')
      watchPaths.push(join(homedir(), '.gemini', 'tmp'))
    }
  }

  if (watchPaths.length === 0) return

  const watcher = chokidar.watch(watchPaths, {
    persistent: true,
    ignoreInitial: true,  // 忽略初始扫描（已由 indexAll 处理）
    awaitWriteFinish: { stabilityThreshold: 2000, pollInterval: 500 },
  })

  watcher.on('add', async (filePath: string) => {
    const adapter = adapters.find(a => filePath.includes(a.name === 'codex' ? '.codex' : a.name))
    if (adapter) {
      await indexer.indexFile(adapter, filePath)
    }
  })

  watcher.on('change', async (filePath: string) => {
    const adapter = adapters.find(a => filePath.includes(a.name === 'codex' ? '.codex' : a.name))
    if (adapter) {
      await indexer.indexFile(adapter, filePath)
    }
  })
}
```

**Step 3: 在 src/index.ts 加入 export tool 和 watcher**

import 部分加：
```typescript
import { exportTool, handleExport } from './tools/export.js'
import { startWatcher } from './core/watcher.js'
```

注册 `exportTool` 到 tools 列表。在 `indexer.indexAll()` 之后加：
```typescript
startWatcher(adapters, indexer)
```

**Step 4: 运行完整测试**

```bash
npm test && npm run build
```

预期：全部测试通过，编译无错误。

**Step 5: Commit**

```bash
git add src/tools/export.ts src/core/watcher.ts src/index.ts
git commit -m "feat: add export tool and file watcher for incremental indexing"
```

---

## Phase 5: 配置与收尾

### Task 16: config.yaml + README

**Files:**
- Create: `config.yaml`
- Create: `README.md`
- Modify: `src/index.ts`（读取 config.yaml）

**Step 1: 创建 config.yaml**

```yaml
# coding-memory 配置文件
# 可选——不存在时使用默认路径

sources:
  codex:
    enabled: true
    # paths:
    #   - ~/.codex/sessions  # 覆盖默认路径

  claude-code:
    enabled: true

  gemini-cli:
    enabled: true

  opencode:
    enabled: true

index:
  db_path: ~/.coding-memory/index.sqlite

# 隐私：敏感信息脱敏（正则，会在索引时过滤）
privacy:
  redact_patterns:
    - 'sk-[a-zA-Z0-9]{20,}'
    - 'AKIA[A-Z0-9]{16}'
```

**Step 2: 创建 README.md**

```markdown
# coding-memory

MCP Server：读取多个 AI 编程助手的会话日志，实现跨工具历史上下文共享。

## 支持的工具

- Codex CLI/App (`~/.codex/sessions/`)
- Claude Code (`~/.claude/projects/`)
- Gemini CLI (`~/.gemini/tmp/`)
- OpenCode (`~/.local/share/opencode/`)

## 安装

```bash
git clone https://github.com/bbingz/coding-memory
cd coding-memory
npm install && npm run build
```

## 注册为 MCP Server

### Claude Code

在 `~/.claude/settings.json` 中加入：

```json
{
  "mcpServers": {
    "coding-memory": {
      "command": "node",
      "args": ["/absolute/path/to/coding-memory/dist/index.js"]
    }
  }
}
```

### Codex

在 `~/.codex/config.toml` 中加入：

```toml
[mcp_servers.coding-memory]
command = "node"
args = ["/absolute/path/to/coding-memory/dist/index.js"]
```

## MCP Tools

| Tool | 说明 |
|------|------|
| `get_context` | 为当前工作目录自动提取相关历史（核心功能） |
| `list_sessions` | 列出会话，支持过滤 |
| `get_session` | 读取单个会话完整内容 |
| `search` | 全文搜索对话内容 |
| `project_timeline` | 某项目跨工具的操作时间线 |
| `stats` | 用量统计 |
| `export` | 导出会话为 Markdown/JSON |

## 开发

```bash
npm test          # 运行测试
npm run build     # 编译 TypeScript
npm run dev       # 开发模式（tsx 直接运行）
```
```

**Step 3: 运行全量测试 + 编译**

```bash
npm test && npm run build
```

**Step 4: 推送到 GitHub**

```bash
git add config.yaml README.md src/
git commit -m "feat: complete v0.1.0 - all 7 MCP tools + 4 adapters"
git push origin main
```

---

## 验证清单

完成所有 task 后执行：

```bash
# 全量测试
npm test

# 编译
npm run build

# 手动测试（查看是否能读取你自己的会话）
node dist/index.js &
# 然后用 MCP inspector 或直接在 Claude Code 里试用 get_context / list_sessions
```

预期输出：
- 测试全部通过
- `dist/index.js` 存在
- 第一次运行时终端输出 `[coding-memory] Indexed N new sessions`
