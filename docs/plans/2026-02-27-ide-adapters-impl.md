# IDE AI Adapters Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add 4 new session adapters (cursor, vscode, antigravity, windsurf) to bring IDE AI conversation history into coding-memory.

**Architecture:** Cursor and VS Code use direct SQLite/JSONL reads. Antigravity and Windsurf use an encrypted format (unreadable directly), so we call their local gRPC API (daemon config provides port + CSRF token), export to JSONL cache in `~/.coding-memory/cache/`, and adapters read from cache.

**Tech Stack:** TypeScript + vitest, better-sqlite3 (already installed), @grpc/grpc-js + @grpc/proto-loader (new), Node.js fs/sqlite3 APIs.

---

## Task 1: Extend SourceName type + update tool enums

**Files:**
- Modify: `src/adapters/types.ts:3`
- Modify: `src/tools/list_sessions.ts:14`
- Modify: `src/tools/search.ts:13`

**Step 1: Update types.ts**

```typescript
// src/adapters/types.ts line 3 — replace the SourceName line:
export type SourceName = 'codex' | 'claude-code' | 'gemini-cli' | 'opencode' | 'iflow' | 'qwen' | 'kimi' | 'cline' | 'cursor' | 'vscode' | 'antigravity' | 'windsurf'
```

**Step 2: Update list_sessions.ts source enum**

```typescript
// src/tools/list_sessions.ts — find the `enum:` line and replace:
enum: ['codex', 'claude-code', 'gemini-cli', 'opencode', 'iflow', 'qwen', 'kimi', 'cline', 'cursor', 'vscode', 'antigravity', 'windsurf'],
```

**Step 3: Update search.ts source enum (same change)**

```typescript
// src/tools/search.ts — find the `enum:` line and replace:
source: { type: 'string', enum: ['codex', 'claude-code', 'gemini-cli', 'opencode', 'iflow', 'qwen', 'kimi', 'cline', 'cursor', 'vscode', 'antigravity', 'windsurf'] },
```

**Step 4: Build and check types compile**

```bash
npm run build
```
Expected: no errors.

**Step 5: Commit**

```bash
git add src/adapters/types.ts src/tools/list_sessions.ts src/tools/search.ts
git commit -m "feat: add cursor, vscode, antigravity, windsurf to SourceName"
```

---

## Task 2: Cursor adapter

Cursor stores all sessions in a single SQLite file. Each session is a "composer". We use a virtual filePath of the form `<sqlitePath>?composer=<composerId>` so the indexer can treat each session as a distinct file.

**Files:**
- Create: `src/adapters/cursor.ts`
- Create: `tests/adapters/cursor.test.ts`
- Create: `tests/fixtures/cursor/state.vscdb` (SQLite fixture)

**Step 1: Create SQLite fixture**

Run this script to create a minimal fixture DB:

```bash
node --input-type=module << 'EOF'
import BetterSqlite3 from 'better-sqlite3'
import { mkdirSync } from 'fs'
mkdirSync('tests/fixtures/cursor', { recursive: true })
const db = new BetterSqlite3('tests/fixtures/cursor/state.vscdb')
db.exec(`CREATE TABLE IF NOT EXISTS cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)`)
// Composer metadata
db.prepare('INSERT INTO cursorDiskKV VALUES (?, ?)').run(
  'composerData:abc-123',
  JSON.stringify({
    _v: 3,
    composerId: 'abc-123',
    createdAt: 1771392000000,
    lastUpdatedAt: 1771392060000,
    latestConversationSummary: { summary: 'Fix the login bug' }
  })
)
// Messages
db.prepare('INSERT INTO cursorDiskKV VALUES (?, ?)').run(
  'bubbleId:abc-123:msg-001',
  JSON.stringify({ _v: 2, bubbleId: 'msg-001', type: 1, text: 'Fix the login bug', timingInfo: { clientStartTime: 1771392000000 } })
)
db.prepare('INSERT INTO cursorDiskKV VALUES (?, ?)').run(
  'bubbleId:abc-123:msg-002',
  JSON.stringify({ _v: 2, bubbleId: 'msg-002', type: 2, text: 'I found the issue in auth.ts', timingInfo: { clientStartTime: 1771392030000 } })
)
db.close()
console.log('Fixture created')
EOF
```

**Step 2: Write failing test**

```typescript
// tests/adapters/cursor.test.ts
import { describe, it, expect } from 'vitest'
import { CursorAdapter } from '../../src/adapters/cursor.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_DB = join(__dirname, '../fixtures/cursor/state.vscdb')

describe('CursorAdapter', () => {
  const adapter = new CursorAdapter(FIXTURE_DB)

  it('name is cursor', () => {
    expect(adapter.name).toBe('cursor')
  })

  it('listSessionFiles yields virtual paths', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) {
      files.push(f)
    }
    expect(files).toHaveLength(1)
    expect(files[0]).toContain('abc-123')
  })

  it('parseSessionInfo returns session metadata', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    const info = await adapter.parseSessionInfo(files[0])
    expect(info).not.toBeNull()
    expect(info!.id).toBe('abc-123')
    expect(info!.source).toBe('cursor')
    expect(info!.summary).toBe('Fix the login bug')
  })

  it('streamMessages yields user then assistant', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    const msgs: { role: string; content: string }[] = []
    for await (const m of adapter.streamMessages(files[0])) msgs.push(m)
    expect(msgs).toHaveLength(2)
    expect(msgs[0]).toMatchObject({ role: 'user', content: 'Fix the login bug' })
    expect(msgs[1]).toMatchObject({ role: 'assistant', content: 'I found the issue in auth.ts' })
  })
})
```

**Step 3: Run test to verify it fails**

```bash
npm run test -- tests/adapters/cursor.test.ts
```
Expected: FAIL — `CursorAdapter` not found.

**Step 4: Implement CursorAdapter**

```typescript
// src/adapters/cursor.ts
import BetterSqlite3 from 'better-sqlite3'
import { stat } from 'fs/promises'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

interface ComposerData {
  _v: number
  composerId: string
  createdAt: number
  lastUpdatedAt: number
  latestConversationSummary?: { summary?: string }
}

interface BubbleData {
  _v: number
  bubbleId: string
  type: number      // 1 = user, 2 = assistant
  text?: string
  rawText?: string
  timingInfo?: { clientStartTime?: number }
}

export class CursorAdapter implements SessionAdapter {
  readonly name = 'cursor' as const
  private dbPath: string

  constructor(dbPath?: string) {
    this.dbPath = dbPath ?? join(homedir(), 'Library', 'Application Support', 'Cursor', 'User', 'globalStorage', 'state.vscdb')
  }

  async detect(): Promise<boolean> {
    try { await stat(this.dbPath); return true } catch { return false }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const db = new BetterSqlite3(this.dbPath, { readonly: true })
      try {
        const rows = db.prepare(
          `SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'`
        ).all() as { key: string; value: string }[]

        for (const row of rows) {
          try {
            const data = JSON.parse(row.value) as ComposerData
            if (data.composerId) {
              yield `${this.dbPath}?composer=${data.composerId}`
            }
          } catch { /* skip malformed */ }
        }
      } finally {
        db.close()
      }
    } catch { /* db not found */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const { dbPath, composerId } = this.parsePath(filePath)
      if (!composerId) return null

      const db = new BetterSqlite3(dbPath, { readonly: true })
      try {
        const row = db.prepare(
          `SELECT value FROM cursorDiskKV WHERE key = ?`
        ).get(`composerData:${composerId}`) as { value: string } | undefined
        if (!row) return null

        const data = JSON.parse(row.value) as ComposerData
        const fileStat = await stat(dbPath)

        const summary = data.latestConversationSummary?.summary

        return {
          id: data.composerId,
          source: 'cursor',
          startTime: new Date(data.createdAt).toISOString(),
          endTime: data.lastUpdatedAt !== data.createdAt
            ? new Date(data.lastUpdatedAt).toISOString()
            : undefined,
          cwd: '',
          messageCount: 0,   // populated by indexer via streamMessages
          userMessageCount: 0,
          summary: summary?.slice(0, 200),
          filePath,
          sizeBytes: fileStat.size,
        }
      } finally {
        db.close()
      }
    } catch { return null }
  }

  async *streamMessages(filePath: string, opts: StreamMessagesOptions = {}): AsyncGenerator<Message> {
    const { dbPath, composerId } = this.parsePath(filePath)
    if (!composerId) return

    const offset = opts.offset ?? 0
    const limit = opts.limit ?? Infinity

    try {
      const db = new BetterSqlite3(dbPath, { readonly: true })
      try {
        const rows = db.prepare(
          `SELECT value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid ASC`
        ).all(`bubbleId:${composerId}:%`) as { value: string }[]

        let count = 0
        let yielded = 0

        for (const row of rows) {
          if (yielded >= limit) break
          try {
            const bubble = JSON.parse(row.value) as BubbleData
            const role = bubble.type === 1 ? 'user' : bubble.type === 2 ? 'assistant' : null
            if (!role) continue

            if (count < offset) { count++; continue }
            count++

            const content = bubble.text || bubble.rawText || ''
            if (!content.trim()) continue

            const ts = bubble.timingInfo?.clientStartTime
            yield {
              role,
              content,
              timestamp: ts ? new Date(ts).toISOString() : undefined,
            }
            yielded++
          } catch { /* skip malformed bubble */ }
        }
      } finally {
        db.close()
      }
    } catch { /* db not found */ }
  }

  private parsePath(filePath: string): { dbPath: string; composerId: string | null } {
    const [dbPath, query] = filePath.split('?composer=')
    return { dbPath, composerId: query ?? null }
  }
}
```

**Step 5: Run test to verify it passes**

```bash
npm run test -- tests/adapters/cursor.test.ts
```
Expected: all 4 tests PASS.

**Step 6: Commit**

```bash
git add src/adapters/cursor.ts tests/adapters/cursor.test.ts tests/fixtures/cursor/
git commit -m "feat: add Cursor adapter (SQLite cursorDiskKV)"
```

---

## Task 3: VS Code Copilot Chat adapter

VS Code stores each chat session as a JSONL file in `workspaceStorage/<hash>/chatSessions/<sessionId>.jsonl`. The session index is in `workspaceStorage/<hash>/state.vscdb`.

**Note:** If sessions are empty (`isEmpty: true`) no JSONL file exists. The adapter skips those.

**Files:**
- Create: `src/adapters/vscode.ts`
- Create: `tests/adapters/vscode.test.ts`
- Create: `tests/fixtures/vscode/chatSessions/sess-001.jsonl`

**Step 1: Inspect actual JSONL format**

Run this to see the real format (if any non-empty sessions exist locally):

```bash
find ~/Library/Application\ Support/Code/User/workspaceStorage -name "*.jsonl" -path "*/chatSessions/*" 2>/dev/null | head -3 | xargs -I{} head -5 {}
```

If no output, we create a fixture based on the VS Code Copilot Chat open-source format (each line is a `RequestMessage` or `ResponseMessage` JSON object).

**Step 2: Create fixture**

```bash
mkdir -p tests/fixtures/vscode/chatSessions
cat > tests/fixtures/vscode/chatSessions/sess-001.jsonl << 'JSONL'
{"type":"request","message":{"role":"user","content":[{"type":"text","value":"How do I use async/await in TypeScript?"}],"id":"req-1","timestamp":1771392000000}}
{"type":"response","message":{"role":"assistant","content":[{"type":"text","value":"Use the `async` keyword on functions and `await` before Promises."}],"id":"resp-1","timestamp":1771392010000}}
JSONL
```

**Step 3: Write failing test**

```typescript
// tests/adapters/vscode.test.ts
import { describe, it, expect } from 'vitest'
import { VsCodeAdapter } from '../../src/adapters/vscode.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_DIR = join(__dirname, '../fixtures/vscode')

describe('VsCodeAdapter', () => {
  const adapter = new VsCodeAdapter(FIXTURE_DIR)

  it('name is vscode', () => {
    expect(adapter.name).toBe('vscode')
  })

  it('parseSessionInfo reads from JSONL', async () => {
    const jsonlPath = join(FIXTURE_DIR, 'chatSessions/sess-001.jsonl')
    const info = await adapter.parseSessionInfo(jsonlPath)
    expect(info).not.toBeNull()
    expect(info!.source).toBe('vscode')
    expect(info!.userMessageCount).toBe(1)
    expect(info!.summary).toContain('async/await')
  })

  it('streamMessages yields user and assistant', async () => {
    const jsonlPath = join(FIXTURE_DIR, 'chatSessions/sess-001.jsonl')
    const msgs: { role: string; content: string }[] = []
    for await (const m of adapter.streamMessages(jsonlPath)) msgs.push(m)
    expect(msgs).toHaveLength(2)
    expect(msgs[0].role).toBe('user')
    expect(msgs[1].role).toBe('assistant')
  })
})
```

**Step 4: Run test to verify it fails**

```bash
npm run test -- tests/adapters/vscode.test.ts
```
Expected: FAIL.

**Step 5: Implement VsCodeAdapter**

Note: `listSessionFiles()` scans all workspaceStorage dirs for `chatSessions/*.jsonl`. `parseSessionInfo` and `streamMessages` read the JSONL file directly.

```typescript
// src/adapters/vscode.ts
import { createReadStream } from 'fs'
import { stat, readdir, glob } from 'fs/promises'
import { createInterface } from 'readline'
import { homedir } from 'os'
import { join, basename } from 'path'
import { createHash } from 'crypto'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

export class VsCodeAdapter implements SessionAdapter {
  readonly name = 'vscode' as const
  private workspaceStorageDir: string

  constructor(workspaceStorageDir?: string) {
    this.workspaceStorageDir = workspaceStorageDir
      ?? join(homedir(), 'Library', 'Application Support', 'Code', 'User', 'workspaceStorage')
  }

  async detect(): Promise<boolean> {
    try { await stat(this.workspaceStorageDir); return true } catch { return false }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    try {
      const pattern = join(this.workspaceStorageDir, '*', 'chatSessions', '*.jsonl')
      for await (const file of glob(pattern)) {
        yield file
      }
    } catch { /* dir not found */ }
  }

  async parseSessionInfo(filePath: string): Promise<SessionInfo | null> {
    try {
      const fileStat = await stat(filePath)
      const sessionId = basename(filePath, '.jsonl')
      let startTime = ''
      let endTime = ''
      let userCount = 0
      let totalCount = 0
      let firstUserText = ''

      for await (const line of this.readLines(filePath)) {
        const obj = this.parseLine(line)
        if (!obj) continue

        const role = this.extractRole(obj)
        if (!role) continue

        totalCount++
        const ts = this.extractTimestamp(obj)
        if (!startTime && ts) startTime = ts
        if (ts) endTime = ts

        if (role === 'user') {
          userCount++
          if (!firstUserText) firstUserText = this.extractText(obj)
        }
      }

      if (totalCount === 0) return null

      return {
        id: sessionId,
        source: 'vscode',
        startTime: startTime || new Date(fileStat.mtimeMs).toISOString(),
        endTime: endTime !== startTime ? endTime : undefined,
        cwd: '',
        messageCount: totalCount,
        userMessageCount: userCount,
        summary: firstUserText.slice(0, 200) || undefined,
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

    for await (const line of this.readLines(filePath)) {
      if (yielded >= limit) break
      const obj = this.parseLine(line)
      if (!obj) continue

      const role = this.extractRole(obj)
      if (!role) continue

      if (count < offset) { count++; continue }
      count++

      yield {
        role,
        content: this.extractText(obj),
        timestamp: this.extractTimestamp(obj),
      }
      yielded++
    }
  }

  private extractRole(obj: Record<string, unknown>): 'user' | 'assistant' | null {
    // Format: {"type":"request","message":{"role":"user",...}} or {"type":"response",...}
    const msg = obj.message as Record<string, unknown> | undefined
    const role = msg?.role as string ?? (obj.type === 'request' ? 'user' : obj.type === 'response' ? 'assistant' : null)
    if (role === 'user') return 'user'
    if (role === 'assistant') return 'assistant'
    return null
  }

  private extractText(obj: Record<string, unknown>): string {
    const msg = obj.message as Record<string, unknown> | undefined
    const content = msg?.content ?? obj.content
    if (typeof content === 'string') return content
    if (Array.isArray(content)) {
      for (const item of content) {
        const c = item as Record<string, unknown>
        if (c.value) return c.value as string
        if (c.text) return c.text as string
      }
    }
    return ''
  }

  private extractTimestamp(obj: Record<string, unknown>): string | undefined {
    const msg = obj.message as Record<string, unknown> | undefined
    const ts = msg?.timestamp ?? obj.timestamp
    if (typeof ts === 'number') return new Date(ts).toISOString()
    if (typeof ts === 'string') return ts
    return undefined
  }

  private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' })
    const rl = createInterface({ input: stream, crlfDelay: Infinity })
    for await (const line of rl) {
      if (line.trim()) yield line
    }
  }

  private parseLine(line: string): Record<string, unknown> | null {
    try { return JSON.parse(line) as Record<string, unknown> } catch { return null }
  }
}
```

**Step 6: Run test — if JSONL format differs, adjust fixture and extractRole/extractText**

The actual VS Code Copilot Chat JSONL format may differ. Run the test, read the actual fixture, adjust the parsing methods as needed.

```bash
npm run test -- tests/adapters/vscode.test.ts
```
Expected: all 3 tests PASS.

**Step 7: Commit**

```bash
git add src/adapters/vscode.ts tests/adapters/vscode.test.ts tests/fixtures/vscode/
git commit -m "feat: add VS Code Copilot Chat adapter (JSONL)"
```

---

## Task 4: Install gRPC dependencies

**Step 1: Install**

```bash
npm install @grpc/grpc-js @grpc/proto-loader
```

**Step 2: Add types**

```bash
npm install --save-dev @grpc/proto-loader
```

(Note: `@grpc/grpc-js` and `@grpc/proto-loader` include their own types.)

**Step 3: Verify build still works**

```bash
npm run build
```
Expected: no errors.

**Step 4: Commit**

```bash
git add package.json package-lock.json
git commit -m "chore: add @grpc/grpc-js and @grpc/proto-loader for cascade gRPC client"
```

---

## Task 5: Cascade gRPC client (shared by Antigravity and Windsurf)

This client:
1. Reads the daemon JSON config file to get port and CSRF token
2. Connects to the local gRPC server (self-signed TLS, skip verification)
3. Calls `GetAllCascadeTrajectories` to list conversations
4. Calls `ConvertTrajectoryToMarkdown` to get conversation content

**Files:**
- Create: `src/adapters/grpc/cascade-client.ts`

**Step 1: Verify daemon config format (Antigravity)**

```bash
cat ~/.gemini/antigravity/daemon/ls_*.json
```
Expected output like: `{"pid":1844,"httpsPort":53925,"httpPort":53926,"lspPort":53931,"lsVersion":"1.19.4","csrfToken":"b0d95bcd-..."}`

**Step 2: Test gRPC connectivity manually before coding**

```bash
# Install grpcurl if not present: brew install grpcurl
# Try calling the API (adjust port from daemon config):
CSRF=$(cat ~/.gemini/antigravity/daemon/ls_*.json | python3 -c "import json,sys; print(json.load(sys.stdin)['csrfToken'])")
PORT=$(cat ~/.gemini/antigravity/daemon/ls_*.json | python3 -c "import json,sys; print(json.load(sys.stdin)['httpsPort'])")
grpcurl -insecure -H "x-codeium-csrf-token: $CSRF" \
  localhost:$PORT \
  exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories
```

Study the output to confirm field names and types. Adjust the proto definition below if needed.

**Step 3: Implement cascade-client.ts**

```typescript
// src/adapters/grpc/cascade-client.ts
import { readdir, readFile } from 'fs/promises'
import { join } from 'path'
import * as grpc from '@grpc/grpc-js'
import * as protoLoader from '@grpc/proto-loader'

// Minimal proto definition — only what we need
const PROTO_DEFINITION = `
syntax = "proto3";
package exa.language_server_pb;

service LanguageServerService {
  rpc GetAllCascadeTrajectories(GetAllCascadeTrajectoriesRequest) returns (GetAllCascadeTrajectoriesResponse);
  rpc ConvertTrajectoryToMarkdown(ConvertTrajectoryToMarkdownRequest) returns (ConvertTrajectoryToMarkdownResponse);
}

message GetAllCascadeTrajectoriesRequest {}

message Timestamp {
  int64 seconds = 1;
  int32 nanos = 2;
}

message ConversationAnnotations {
  string title = 1;
}

message CascadeTrajectorySummary {
  string summary = 1;
  string trajectory_id = 4;
  Timestamp created_time = 7;
  Timestamp last_modified_time = 3;
  ConversationAnnotations annotations = 15;
}

message GetAllCascadeTrajectoriesResponse {
  map<string, CascadeTrajectorySummary> trajectory_summaries = 1;
}

message ConvertTrajectoryToMarkdownRequest {
  string cascade_id = 1;
}

message ConvertTrajectoryToMarkdownResponse {
  string markdown = 1;
}
`

// NOTE: field numbers and message names are based on research/reverse engineering.
// If the gRPC call fails with field errors, run grpcurl with --reflect or decode the proto
// from the extension bundle at:
// /Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/dist/extension.js

export interface ConversationSummary {
  id: string
  title: string
  summary: string
  createdAt: string
  updatedAt: string
}

interface DaemonConfig {
  httpsPort: number
  httpPort: number
  csrfToken: string
}

export class CascadeGrpcClient {
  private client: grpc.Client
  private csrfToken: string
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private serviceDefinition: any

  private constructor(client: grpc.Client, csrfToken: string, serviceDefinition: unknown) {
    this.client = client
    this.csrfToken = csrfToken
    this.serviceDefinition = serviceDefinition
  }

  static async fromDaemonDir(daemonDir: string): Promise<CascadeGrpcClient | null> {
    try {
      const files = await readdir(daemonDir)
      const jsonFile = files.find(f => f.endsWith('.json'))
      if (!jsonFile) return null

      const config = JSON.parse(
        await readFile(join(daemonDir, jsonFile), 'utf8')
      ) as DaemonConfig

      const packageDef = await protoLoader.load([], {
        keepCase: false,
        defaults: true,
        oneofs: true,
      })

      // Load from inline string (protoLoader doesn't directly support strings,
      // so we use a temp approach via the deprecated loadSync with inline)
      // Alternative: use protobufjs directly for inline proto
      const { loadSync } = await import('@grpc/proto-loader')
      const tmpProtoPath = join('/tmp', `cascade-${Date.now()}.proto`)
      const { writeFileSync, unlinkSync } = await import('fs')
      writeFileSync(tmpProtoPath, PROTO_DEFINITION)

      const pkgDef = loadSync(tmpProtoPath, { keepCase: false, defaults: true })
      unlinkSync(tmpProtoPath)

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const proto = grpc.loadPackageDefinition(pkgDef) as any
      const ServiceClass = proto.exa.language_server_pb.LanguageServerService

      // Use TLS credentials that skip certificate verification for localhost
      const credentials = grpc.credentials.createSsl(
        null, null, null,
        { checkServerIdentity: () => undefined }
      )

      const client = new ServiceClass(
        `localhost:${config.httpsPort}`,
        credentials
      )

      return new CascadeGrpcClient(client, config.csrfToken, ServiceClass)
    } catch { return null }
  }

  private metadata(): grpc.Metadata {
    const meta = new grpc.Metadata()
    meta.add('x-codeium-csrf-token', this.csrfToken)
    return meta
  }

  async listConversations(): Promise<ConversationSummary[]> {
    return new Promise((resolve, reject) => {
      this.client.makeUnaryRequest(
        '/exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories',
        (arg: unknown) => Buffer.from(JSON.stringify(arg)),
        (buf: Buffer) => JSON.parse(buf.toString()),
        {},
        this.metadata(),
        {},
        (err: Error | null, response: { trajectory_summaries?: Record<string, { trajectory_id?: string; annotations?: { title?: string }; summary?: string; created_time?: { seconds?: number }; last_modified_time?: { seconds?: number } }> }) => {
          if (err) { reject(err); return }
          const summaries = response?.trajectory_summaries ?? {}
          const result: ConversationSummary[] = Object.values(summaries).map(s => ({
            id: s.trajectory_id ?? '',
            title: s.annotations?.title ?? '',
            summary: s.summary ?? '',
            createdAt: s.created_time?.seconds
              ? new Date(Number(s.created_time.seconds) * 1000).toISOString() : '',
            updatedAt: s.last_modified_time?.seconds
              ? new Date(Number(s.last_modified_time.seconds) * 1000).toISOString() : '',
          }))
          resolve(result)
        }
      )
    })
  }

  async getMarkdown(cascadeId: string): Promise<string> {
    return new Promise((resolve, reject) => {
      this.client.makeUnaryRequest(
        '/exa.language_server_pb.LanguageServerService/ConvertTrajectoryToMarkdown',
        (arg: unknown) => Buffer.from(JSON.stringify(arg)),
        (buf: Buffer) => JSON.parse(buf.toString()),
        { cascade_id: cascadeId },
        this.metadata(),
        {},
        (err: Error | null, response: { markdown?: string }) => {
          if (err) { reject(err); return }
          resolve(response?.markdown ?? '')
        }
      )
    })
  }

  close(): void {
    this.client.close()
  }
}
```

**Important note:** The `makeUnaryRequest` approach with JSON serialization likely won't work for protobuf. During implementation, you'll need to use the proper protobuf-encoded service from `grpc.loadPackageDefinition`. The above is a starting skeleton. Adjust based on actual gRPC call success/failure from grpcurl testing in Step 2.

**Step 4: Verify build compiles**

```bash
npm run build
```

**Step 5: Manual integration test (Antigravity must be running)**

```bash
node --input-type=module << 'EOF'
import { CascadeGrpcClient } from './dist/adapters/grpc/cascade-client.js'
import { join, homedir } from 'path'
const client = await CascadeGrpcClient.fromDaemonDir(
  join(homedir(), '.gemini', 'antigravity', 'daemon')
)
if (!client) { console.log('Could not connect'); process.exit(1) }
const convs = await client.listConversations()
console.log('Conversations:', convs.slice(0, 3))
client.close()
EOF
```

Fix any proto/serialization issues until the list returns real conversation data.

**Step 6: Commit**

```bash
git add src/adapters/grpc/
git commit -m "feat: add cascade gRPC client for Antigravity/Windsurf"
```

---

## Task 6: Antigravity adapter

Uses the cascade gRPC client to sync conversations to `~/.coding-memory/cache/antigravity/` as JSONL files, then reads from cache.

**Files:**
- Create: `src/adapters/antigravity.ts`
- Create: `tests/adapters/antigravity.test.ts`
- Create: `tests/fixtures/antigravity/cache/conv-001.jsonl`

**Step 1: Create fixture cache file**

```bash
mkdir -p tests/fixtures/antigravity/cache
cat > tests/fixtures/antigravity/cache/conv-001.jsonl << 'JSONL'
{"id":"conv-001","title":"Fix auth bug","createdAt":"2026-02-20T10:00:00.000Z","updatedAt":"2026-02-20T10:30:00.000Z"}
{"role":"user","content":"There's a bug in auth.ts","timestamp":"2026-02-20T10:00:00.000Z"}
{"role":"assistant","content":"I can see the issue. The token expiry check is inverted.","timestamp":"2026-02-20T10:00:30.000Z"}
JSONL
```

(First line is session metadata JSON, subsequent lines are messages.)

**Step 2: Write failing test**

```typescript
// tests/adapters/antigravity.test.ts
import { describe, it, expect } from 'vitest'
import { AntigravityAdapter } from '../../src/adapters/antigravity.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_CACHE = join(__dirname, '../fixtures/antigravity/cache')

describe('AntigravityAdapter (cache mode)', () => {
  // Pass a non-existent daemon dir — adapter falls back to cache-only mode
  const adapter = new AntigravityAdapter('/nonexistent/daemon', FIXTURE_CACHE)

  it('name is antigravity', () => {
    expect(adapter.name).toBe('antigravity')
  })

  it('listSessionFiles yields cache JSONL files', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    expect(files.some(f => f.endsWith('conv-001.jsonl'))).toBe(true)
  })

  it('parseSessionInfo reads metadata from first line', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-001.jsonl')
    const info = await adapter.parseSessionInfo(filePath)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('conv-001')
    expect(info!.source).toBe('antigravity')
    expect(info!.summary).toContain('Fix auth bug')
  })

  it('streamMessages yields user and assistant from cache', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-001.jsonl')
    const msgs: { role: string; content: string }[] = []
    for await (const m of adapter.streamMessages(filePath)) msgs.push(m)
    expect(msgs).toHaveLength(2)
    expect(msgs[0].role).toBe('user')
    expect(msgs[1].role).toBe('assistant')
  })
})
```

**Step 3: Run test to verify it fails**

```bash
npm run test -- tests/adapters/antigravity.test.ts
```
Expected: FAIL.

**Step 4: Implement AntigravityAdapter**

```typescript
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

  constructor(
    daemonDir?: string,
    cacheDir?: string,
    conversationsDir?: string,
  ) {
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
        if (!conv.id) continue
        const cachePath = join(this.cacheDir, `${conv.id}.jsonl`)
        const pbPath = join(this.conversationsDir, `${conv.id}.pb`)

        // Check if cache is fresh (pb mtime <= cache mtime)
        try {
          const [pbStat, cacheStat] = await Promise.all([stat(pbPath), stat(cachePath)])
          if (cacheStat.mtimeMs >= pbStat.mtimeMs) continue  // cache is fresh
        } catch { /* pb or cache doesn't exist — proceed with fetch */ }

        try {
          const markdown = await client.getMarkdown(conv.id)
          const messages = parseMarkdownToMessages(markdown)

          const metaLine: CacheMetaLine = {
            id: conv.id,
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
// Adjust this based on actual output from grpcurl testing.
export function parseMarkdownToMessages(markdown: string): { role: 'user' | 'assistant'; content: string; timestamp?: string }[] {
  const messages: { role: 'user' | 'assistant'; content: string }[] = []
  // Expected format (verify with grpcurl output):
  // ## User\n\ntext...\n\n## Assistant\n\ntext...
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
```

**Step 5: Run test to verify it passes**

```bash
npm run test -- tests/adapters/antigravity.test.ts
```
Expected: all 4 tests PASS.

**Step 6: Commit**

```bash
git add src/adapters/antigravity.ts tests/adapters/antigravity.test.ts tests/fixtures/antigravity/
git commit -m "feat: add Antigravity cascade adapter (gRPC → JSONL cache)"
```

---

## Task 7: Windsurf adapter

Windsurf uses the same cascade architecture as Antigravity. The adapter is nearly identical — different daemon dir, conversations dir, and cache dir.

**Files:**
- Create: `src/adapters/windsurf.ts`
- Create: `tests/adapters/windsurf.test.ts`
- Create: `tests/fixtures/windsurf/cache/conv-w01.jsonl`

**Step 1: Create fixture**

```bash
mkdir -p tests/fixtures/windsurf/cache
cat > tests/fixtures/windsurf/cache/conv-w01.jsonl << 'JSONL'
{"id":"conv-w01","title":"Refactor the API","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z"}
{"role":"user","content":"Refactor the API to use REST","timestamp":"2026-02-18T09:00:00.000Z"}
{"role":"assistant","content":"I'll restructure the endpoints.","timestamp":"2026-02-18T09:00:20.000Z"}
JSONL
```

**Step 2: Write failing test**

```typescript
// tests/adapters/windsurf.test.ts
import { describe, it, expect } from 'vitest'
import { WindsurfAdapter } from '../../src/adapters/windsurf.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_CACHE = join(__dirname, '../fixtures/windsurf/cache')

describe('WindsurfAdapter (cache mode)', () => {
  const adapter = new WindsurfAdapter('/nonexistent/daemon', FIXTURE_CACHE)

  it('name is windsurf', () => expect(adapter.name).toBe('windsurf'))

  it('parseSessionInfo reads from cache', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-w01.jsonl')
    const info = await adapter.parseSessionInfo(filePath)
    expect(info).not.toBeNull()
    expect(info!.source).toBe('windsurf')
    expect(info!.id).toBe('conv-w01')
  })

  it('streamMessages yields messages', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-w01.jsonl')
    const msgs: { role: string }[] = []
    for await (const m of adapter.streamMessages(filePath)) msgs.push(m)
    expect(msgs).toHaveLength(2)
  })
})
```

**Step 3: Run test to verify it fails**

```bash
npm run test -- tests/adapters/windsurf.test.ts
```

**Step 4: Implement WindsurfAdapter**

Windsurf is identical to Antigravity except for paths. Extract a shared base class or simply copy and change the three paths:

```typescript
// src/adapters/windsurf.ts
import { homedir } from 'os'
import { join } from 'path'
import { AntigravityAdapter } from './antigravity.js'

export class WindsurfAdapter extends AntigravityAdapter {
  // Override name — TypeScript requires a workaround since readonly name is set in parent
  get name(): 'windsurf' { return 'windsurf' }

  constructor(daemonDir?: string, cacheDir?: string, conversationsDir?: string) {
    const home = homedir()
    super(
      daemonDir ?? join(home, '.codeium', 'windsurf', 'daemon'),
      cacheDir ?? join(home, '.coding-memory', 'cache', 'windsurf'),
      conversationsDir ?? join(home, '.codeium', 'windsurf', 'cascade'),
    )
  }
}
```

**Note:** TypeScript may complain about overriding a `readonly` field via getter. If so, copy the full implementation from AntigravityAdapter and change the name + paths instead of extending.

**Step 5: Run test**

```bash
npm run test -- tests/adapters/windsurf.test.ts
```

**Step 6: Commit**

```bash
git add src/adapters/windsurf.ts tests/adapters/windsurf.test.ts tests/fixtures/windsurf/
git commit -m "feat: add Windsurf cascade adapter"
```

---

## Task 8: Register all adapters in index.ts

**Files:**
- Modify: `src/index.ts`

**Step 1: Update imports and adapter registration**

```typescript
// Add these imports after the existing adapter imports:
import { CursorAdapter } from './adapters/cursor.js'
import { VsCodeAdapter } from './adapters/vscode.js'
import { AntigravityAdapter } from './adapters/antigravity.js'
import { WindsurfAdapter } from './adapters/windsurf.js'
```

```typescript
// Update the adapters array (add 4 new entries):
const adapters = [
  new CodexAdapter(),
  new ClaudeCodeAdapter(),
  new GeminiCliAdapter(),
  new OpenCodeAdapter(),
  new IflowAdapter(),
  new QwenAdapter(),
  new KimiAdapter(),
  new ClineAdapter(),
  new CursorAdapter(),
  new VsCodeAdapter(),
  new AntigravityAdapter(),
  new WindsurfAdapter(),
]
```

Also create the cache directories on startup:

```typescript
// Add after DB_DIR creation:
import { mkdirSync as mkdirSyncExtra } from 'fs'
mkdirSyncExtra(join(homedir(), '.coding-memory', 'cache', 'antigravity'), { recursive: true })
mkdirSyncExtra(join(homedir(), '.coding-memory', 'cache', 'windsurf'), { recursive: true })
```

**Step 2: Build**

```bash
npm run build
```
Expected: no errors.

**Step 3: Run all tests**

```bash
npm run test
```
Expected: all existing + new tests pass.

**Step 4: Commit**

```bash
git add src/index.ts
git commit -m "feat: register cursor, vscode, antigravity, windsurf adapters in MCP server"
```

---

## Task 9: Smoke test with live MCP server

**Step 1: Build**

```bash
npm run build
```

**Step 2: Start the server and check output**

```bash
node dist/index.js 2>&1 &
sleep 8
# Then in Claude Code or Codex, call list_sessions and check sources
```

**Step 3: Verify Antigravity data (requires Antigravity app running)**

```bash
# With Antigravity running:
node --input-type=module << 'EOF'
import { AntigravityAdapter } from './dist/adapters/antigravity.js'
const a = new AntigravityAdapter()
const files = []
for await (const f of a.listSessionFiles()) { files.push(f); if (files.length >= 3) break }
console.log('Files:', files)
if (files[0]) {
  const info = await a.parseSessionInfo(files[0])
  console.log('Session:', info)
}
EOF
```

**Step 4: Kill background server**

```bash
kill %1
```

**Step 5: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: smoke test fixes for IDE adapters"
```

---

## Verification Checklist

- [ ] `npm run test` — all tests pass
- [ ] `npm run build` — no TypeScript errors
- [ ] `list_sessions` MCP tool shows `cursor`, `vscode`, `antigravity`, `windsurf` in source filter
- [ ] Antigravity conversations appear in `list_sessions` when app is running and `sync()` has been called
- [ ] Windsurf conversations appear similarly
- [ ] Cursor sessions appear if Cursor is installed

## Known Implementation Risks

1. **gRPC proto field numbers**: The inline proto definition uses field numbers from reverse-engineering. If calls fail, decode the actual proto from the extension bundle with:
   ```bash
   node -e "const fs=require('fs'); const s=fs.readFileSync('/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/dist/extension.js','utf8'); const m=s.match(/GetAllCascadeTrajector[^'\"]+/g); console.log([...new Set(m)])"
   ```
2. **Markdown format**: `ConvertTrajectoryToMarkdown` output format is assumed. Verify with grpcurl before parsing.
3. **VS Code JSONL format**: VS Code Copilot Chat JSONL format may differ from the fixture. Inspect actual files and adjust `extractRole`/`extractText`.
4. **WindsurfAdapter name override**: TypeScript `readonly` field extension workaround may need full class copy instead of extends.
