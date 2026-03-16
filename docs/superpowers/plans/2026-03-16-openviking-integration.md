# OpenViking Integration — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate OpenViking as an optional external context engine that enhances Engram's search, tiered retrieval, and memory capabilities via HTTP API.

**Architecture:** VikingBridge HTTP client connects to a user-deployed OpenViking server. Dual-write: indexer pushes content to both SQLite FTS and OpenViking. All MCP tools fall back to existing FTS when Viking is unavailable. Config in `~/.engram/settings.json`.

**Tech Stack:** TypeScript (Node.js fetch API), Vitest, SwiftUI (macOS settings UI)

**Spec:** `docs/superpowers/specs/2026-03-16-openviking-integration-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/core/config.ts` | Modify | Add `viking` to `FileSettings` interface |
| `src/core/viking-bridge.ts` | **Create** | HTTP client wrapping OpenViking API |
| `src/core/indexer.ts` | Modify | Accept optional VikingBridge, dual-write after SQLite |
| `src/tools/search.ts` | Modify | Accept optional VikingBridge in SearchDeps, Viking-first search |
| `src/tools/get_context.ts` | Modify | Add `detail` parameter, use Viking L0/L1/L2 |
| `src/tools/get_memory.ts` | **Create** | New MCP tool for memory queries |
| `src/index.ts` | Modify | Register `get_memory`, pass VikingBridge to tools |
| `src/daemon.ts` | Modify | Initialize VikingBridge, pass to indexer/web |
| `src/web.ts` | Modify | Viking status in `/api/status`, enhanced `/api/search` |
| `macos/Engram/Views/SettingsView.swift` | Modify | Viking configuration UI section |
| `tests/core/viking-bridge.test.ts` | **Create** | VikingBridge unit tests (mock HTTP) |
| `tests/core/indexer-viking.test.ts` | **Create** | Indexer dual-write integration tests |
| `tests/tools/search-viking.test.ts` | **Create** | Search fallback tests |
| `tests/tools/get_context-viking.test.ts` | **Create** | get_context detail parameter tests |
| `tests/tools/get_memory.test.ts` | **Create** | get_memory tool tests |

---

## Chunk 1: Configuration + VikingBridge

### Task 1: Add Viking settings to FileSettings

**Files:**
- Modify: `src/core/config.ts:21-69`
- Test: `tests/core/config.test.ts` (if exists, otherwise inline verification)

- [ ] **Step 1: Add VikingSettings interface and extend FileSettings**

```typescript
// Add after line 19 (after SummaryConfig interface):
export interface VikingSettings {
  url?: string
  apiKey?: string
  enabled?: boolean
}

// Add to FileSettings interface (after syncEnabled line 68):
  // ── OpenViking ──────────────────────────────────────────────────
  viking?: VikingSettings
```

- [ ] **Step 2: Verify build succeeds**

Run: `npm run build`
Expected: Clean compile, no errors

- [ ] **Step 3: Commit**

```bash
git add src/core/config.ts
git commit -m "feat(config): add viking settings to FileSettings"
```

---

### Task 2: VikingBridge HTTP client — types and constructor

**Files:**
- Create: `src/core/viking-bridge.ts`
- Create: `tests/core/viking-bridge.test.ts`

- [ ] **Step 1: Write the failing test for VikingBridge constructor**

```typescript
// tests/core/viking-bridge.test.ts
import { describe, it, expect } from 'vitest'
import { VikingBridge } from '../../src/core/viking-bridge.js'

describe('VikingBridge', () => {
  it('creates instance with url and apiKey', () => {
    const bridge = new VikingBridge('http://localhost:1933', 'test-key')
    expect(bridge).toBeInstanceOf(VikingBridge)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: FAIL — cannot resolve `../src/core/viking-bridge.js`

- [ ] **Step 3: Write VikingBridge skeleton with types**

```typescript
// src/core/viking-bridge.ts

export interface VikingSearchResult {
  uri: string
  score: number
  snippet: string
  metadata?: Record<string, string>
}

export interface VikingEntry {
  uri: string
  title?: string
  type: string
}

export interface VikingMemory {
  content: string
  source: string
  confidence: number
  createdAt: string
}

/** Extract session ID from viking URI: viking://sessions/{source}/{project}/{session_id} */
export function sessionIdFromVikingUri(uri: string): string {
  const match = uri.match(/viking:\/\/sessions\/[^/]+\/[^/]+\/(.+)$/)
  return match?.[1] ?? ''
}

const CIRCUIT_BREAKER_TTL = 5 * 60 * 1000 // 5 minutes — matches spec retry interval

export class VikingBridge {
  private baseUrl: string
  private headers: Record<string, string>
  // Circuit breaker: avoid hammering a dead server
  private circuitOpen = false
  private lastHealthCheck = 0

  constructor(url: string, apiKey: string) {
    this.baseUrl = url.replace(/\/$/, '')
    this.headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    }
  }

  /** Cached health check — returns false without network call if circuit is open and TTL not expired */
  async checkAvailable(): Promise<boolean> {
    const now = Date.now()
    if (this.circuitOpen && now - this.lastHealthCheck < CIRCUIT_BREAKER_TTL) return false
    const ok = await this.isAvailable()
    this.circuitOpen = !ok
    this.lastHealthCheck = now
    return ok
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "feat(viking): add VikingBridge skeleton with types"
```

---

### Task 3: VikingBridge.isAvailable() health check

**Files:**
- Modify: `src/core/viking-bridge.ts`
- Modify: `tests/core/viking-bridge.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect, vi, afterEach } from 'vitest'

// Add to existing describe block:
describe('isAvailable', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('returns true when server responds with auth header', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    const mockFetch = vi.fn().mockResolvedValue({ ok: true })
    vi.stubGlobal('fetch', mockFetch)

    const result = await bridge.isAvailable()
    expect(result).toBe(true)
    expect(mockFetch).toHaveBeenCalledWith(
      'http://localhost:1933/api/health',
      expect.objectContaining({
        method: 'GET',
        signal: expect.any(AbortSignal),
        headers: expect.objectContaining({ Authorization: 'Bearer key' }),
      })
    )
  })

  it('returns false when server is unreachable', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('ECONNREFUSED')))

    const result = await bridge.isAvailable()
    expect(result).toBe(false)
  })
})

describe('checkAvailable (circuit breaker)', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('caches false result and skips network call within TTL', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    const mockFetch = vi.fn().mockRejectedValue(new Error('down'))
    vi.stubGlobal('fetch', mockFetch)

    // First call — hits network, returns false
    expect(await bridge.checkAvailable()).toBe(false)
    expect(mockFetch).toHaveBeenCalledTimes(1)

    // Second call — circuit open, returns false without network
    expect(await bridge.checkAvailable()).toBe(false)
    expect(mockFetch).toHaveBeenCalledTimes(1) // no additional call
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: FAIL — `bridge.isAvailable is not a function`

- [ ] **Step 3: Implement isAvailable()**

```typescript
// Add to VikingBridge class:
  async isAvailable(): Promise<boolean> {
    try {
      const res = await fetch(`${this.baseUrl}/api/health`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(3000),
      })
      return res.ok
    } catch {
      return false
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "feat(viking): implement isAvailable() health check"
```

---

### Task 4: VikingBridge.addResource()

**Files:**
- Modify: `src/core/viking-bridge.ts`
- Modify: `tests/core/viking-bridge.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
describe('addResource', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('sends content to OpenViking', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    const mockFetch = vi.fn().mockResolvedValue({ ok: true })
    vi.stubGlobal('fetch', mockFetch)

    await bridge.addResource('viking://sessions/claude-code/engram/001', 'session content', {
      source: 'claude-code',
      project: 'engram',
    })

    expect(mockFetch).toHaveBeenCalledWith(
      'http://localhost:1933/api/resources',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          uri: 'viking://sessions/claude-code/engram/001',
          content: 'session content',
          metadata: { source: 'claude-code', project: 'engram' },
        }),
      })
    )
  })

  it('throws on server error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 500, text: () => Promise.resolve('Internal error') }))

    await expect(bridge.addResource('uri', 'content')).rejects.toThrow('Viking addResource failed')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: FAIL — `bridge.addResource is not a function`

- [ ] **Step 3: Implement addResource()**

```typescript
// Add to VikingBridge class:
  async addResource(uri: string, content: string, metadata?: Record<string, string>): Promise<void> {
    const res = await fetch(`${this.baseUrl}/api/resources`, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify({ uri, content, metadata }),
      signal: AbortSignal.timeout(30000),
    })
    if (!res.ok) {
      throw new Error(`Viking addResource failed (${res.status}): ${await res.text()}`)
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "feat(viking): implement addResource()"
```

---

### Task 5: VikingBridge search methods (find, grep)

**Files:**
- Modify: `src/core/viking-bridge.ts`
- Modify: `tests/core/viking-bridge.test.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
describe('find', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('returns semantic search results', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    const mockResults = [
      { uri: 'viking://sessions/a', score: 0.95, snippet: 'SSL error fix' },
    ]
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ results: mockResults }),
    }))

    const results = await bridge.find('SSL error')
    expect(results).toEqual(mockResults)
  })

  it('returns empty array on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('timeout')))

    const results = await bridge.find('query')
    expect(results).toEqual([])
  })
})

describe('grep', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('returns keyword search results', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ results: [{ uri: 'u', score: 1, snippet: 'match' }] }),
    }))

    const results = await bridge.grep('SSL')
    expect(results).toHaveLength(1)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: FAIL — methods not found

- [ ] **Step 3: Implement find() and grep()**

```typescript
// Add to VikingBridge class — shared search helper + public methods:
  private async searchEndpoint(endpoint: string, query: string, targetUri?: string): Promise<VikingSearchResult[]> {
    try {
      const params = new URLSearchParams({ q: query })
      if (targetUri) params.set('target', targetUri)
      const res = await fetch(`${this.baseUrl}${endpoint}?${params}`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      })
      if (!res.ok) return []
      const data = await res.json()
      return Array.isArray(data?.results) ? data.results : []
    } catch {
      return []
    }
  }

  async find(query: string, targetUri?: string): Promise<VikingSearchResult[]> {
    return this.searchEndpoint('/api/find', query, targetUri)
  }

  async grep(pattern: string, targetUri?: string): Promise<VikingSearchResult[]> {
    return this.searchEndpoint('/api/grep', pattern, targetUri)
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "feat(viking): implement find() and grep() search methods"
```

---

### Task 6: VikingBridge tiered read methods (abstract, overview, read)

**Files:**
- Modify: `src/core/viking-bridge.ts`
- Modify: `tests/core/viking-bridge.test.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
describe('tiered read', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('abstract returns L0 summary', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ content: 'Brief summary' }),
    }))
    const result = await bridge.abstract('viking://sessions/a')
    expect(result).toBe('Brief summary')
  })

  it('overview returns L1 summary', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ content: 'Detailed overview...' }),
    }))
    const result = await bridge.overview('viking://sessions/a')
    expect(result).toBe('Detailed overview...')
  })

  it('read returns L2 full content', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ content: 'Full session content...' }),
    }))
    const result = await bridge.read('viking://sessions/a')
    expect(result).toBe('Full session content...')
  })

  it('returns empty string on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('fail')))
    const result = await bridge.abstract('viking://sessions/a')
    expect(result).toBe('')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement tiered read methods**

```typescript
// Add private helper + public methods to VikingBridge:
  private async readLevel(uri: string, level: 'abstract' | 'overview' | 'read'): Promise<string> {
    try {
      const params = new URLSearchParams({ uri, level })
      const res = await fetch(`${this.baseUrl}/api/read?${params}`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      })
      if (!res.ok) return ''
      const data = await res.json()
      return typeof data?.content === 'string' ? data.content : ''
    } catch {
      return ''
    }
  }

  async abstract(uri: string): Promise<string> {
    return this.readLevel(uri, 'abstract')
  }

  async overview(uri: string): Promise<string> {
    return this.readLevel(uri, 'overview')
  }

  async read(uri: string): Promise<string> {
    return this.readLevel(uri, 'read')
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "feat(viking): implement tiered read methods (abstract/overview/read)"
```

---

### Task 7: VikingBridge ls() and memory methods

**Files:**
- Modify: `src/core/viking-bridge.ts`
- Modify: `tests/core/viking-bridge.test.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
describe('ls', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('lists entries under a URI', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    const entries = [{ uri: 'viking://sessions/a/b', type: 'session' }]
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ entries }),
    }))
    const result = await bridge.ls('viking://sessions/a')
    expect(result).toEqual(entries)
  })
})

describe('memory', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('extractMemory sends content', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    const mockFetch = vi.fn().mockResolvedValue({ ok: true })
    vi.stubGlobal('fetch', mockFetch)

    await bridge.extractMemory('session content')
    expect(mockFetch).toHaveBeenCalledWith(
      'http://localhost:1933/api/memory/extract',
      expect.objectContaining({ method: 'POST' })
    )
  })

  it('findMemories returns results', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    const memories = [{ content: 'User prefers TypeScript', source: 'session-1', confidence: 0.9, createdAt: '2026-03-16' }]
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ memories }),
    }))
    const result = await bridge.findMemories('coding style')
    expect(result).toEqual(memories)
  })

  it('findMemories returns empty array on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key')
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('fail')))
    const result = await bridge.findMemories('query')
    expect(result).toEqual([])
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement ls(), extractMemory(), findMemories()**

```typescript
// Add to VikingBridge class:
  async ls(uri: string): Promise<VikingEntry[]> {
    try {
      const params = new URLSearchParams({ uri })
      const res = await fetch(`${this.baseUrl}/api/ls?${params}`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      })
      if (!res.ok) return []
      const data = await res.json()
      return Array.isArray(data?.entries) ? data.entries : []
    } catch {
      return []
    }
  }

  async extractMemory(sessionContent: string): Promise<void> {
    const res = await fetch(`${this.baseUrl}/api/memory/extract`, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify({ content: sessionContent }),
      signal: AbortSignal.timeout(30000),
    })
    if (!res.ok) {
      throw new Error(`Viking extractMemory failed (${res.status})`)
    }
  }

  async findMemories(query: string): Promise<VikingMemory[]> {
    try {
      const params = new URLSearchParams({ q: query })
      const res = await fetch(`${this.baseUrl}/api/memory/search?${params}`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      })
      if (!res.ok) return []
      const data = await res.json()
      return Array.isArray(data?.memories) ? data.memories : []
    } catch {
      return []
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: PASS

- [ ] **Step 5: Run full test suite to verify no regressions**

Run: `npm test`
Expected: All 173+ tests pass

- [ ] **Step 6: Commit**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "feat(viking): implement ls() and memory methods, complete VikingBridge"
```

---

## Chunk 2: Indexer Dual-Write + Search Enhancement

### Task 8: Indexer dual-write — accept optional VikingBridge

**Files:**
- Modify: `src/core/indexer.ts`
- Create: `tests/core/indexer-viking.test.ts`

- [ ] **Step 1: Write the failing test for Viking dual-write**

```typescript
// tests/core/indexer-viking.test.ts
import { describe, it, expect, vi, afterEach } from 'vitest'
import { mkdtempSync, writeFileSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { Database } from '../../src/core/db.js'
import { Indexer } from '../../src/core/indexer.js'
import type { VikingBridge } from '../../src/core/viking-bridge.js'

// Helper to build a complete SessionInfo for tests
function makeSessionInfo(overrides: Record<string, unknown>) {
  return {
    source: 'codex',
    startTime: '2026-03-16T00:00:00Z',
    messageCount: 2,
    userMessageCount: 1,
    assistantMessageCount: 1,
    toolMessageCount: 0,
    systemMessageCount: 0,
    sizeBytes: 100,
    cwd: '/tmp',
    ...overrides,
  }
}

describe('Indexer with Viking', () => {
  let db: Database
  let tmpDir: string

  afterEach(() => {
    db?.close()
    if (tmpDir) rmSync(tmpDir, { recursive: true })
  })

  it('calls viking.addResource after indexing a session', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'indexer-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    const mockViking = {
      isAvailable: vi.fn().mockResolvedValue(true),
      addResource: vi.fn().mockResolvedValue(undefined),
    } as unknown as VikingBridge

    const filePath = join(tmpDir, 'session.jsonl')
    const adapter = {
      name: 'codex',
      detect: () => Promise.resolve(true),
      listSessionFiles: async function* () { yield filePath },
      parseSessionInfo: () => Promise.resolve(makeSessionInfo({
        id: 'test-session-1',
        filePath,
      })),
      streamMessages: async function* () {
        yield { role: 'user', content: 'Hello' }
        yield { role: 'assistant', content: 'Hi there' }
      },
    }

    writeFileSync(filePath, '{}')

    const indexer = new Indexer(db, [adapter as any], { viking: mockViking })
    await indexer.indexAll()

    expect(mockViking.addResource).toHaveBeenCalledWith(
      expect.stringContaining('viking://sessions/codex/'),
      expect.stringContaining('[user] Hello'),
      expect.objectContaining({ source: 'codex' })
    )
  })

  it('does not fail if viking.addResource throws', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'indexer-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    const mockViking = {
      isAvailable: vi.fn().mockResolvedValue(true),
      addResource: vi.fn().mockRejectedValue(new Error('server down')),
    } as unknown as VikingBridge

    const filePath = join(tmpDir, 'session.jsonl')
    const adapter = {
      name: 'codex',
      detect: () => Promise.resolve(true),
      listSessionFiles: async function* () { yield filePath },
      parseSessionInfo: () => Promise.resolve(makeSessionInfo({
        id: 'test-session-2',
        filePath,
        messageCount: 1, userMessageCount: 1, assistantMessageCount: 0, sizeBytes: 50,
      })),
      streamMessages: async function* () { yield { role: 'user', content: 'test' } },
    }

    writeFileSync(filePath, '{}')

    const indexer = new Indexer(db, [adapter as any], { viking: mockViking })
    const count = await indexer.indexAll()

    // Session should still be indexed in SQLite despite Viking failure
    expect(count).toBe(1)
    expect(db.getSession('test-session-2')).not.toBeNull()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/indexer-viking.test.ts`
Expected: FAIL — Indexer constructor doesn't accept third arg

- [ ] **Step 3: Modify Indexer to accept optional VikingBridge**

In `src/core/indexer.ts`, change the constructor and add Viking dual-write:

```typescript
// Update import:
import type { VikingBridge } from './viking-bridge.js'

// Change constructor (line 8-11):
export class Indexer {
  constructor(
    private db: Database,
    private adapters: SessionAdapter[],
    private opts?: { viking?: VikingBridge | null }
  ) {}
```

Add a private helper method to the class:

```typescript
  // Fire-and-forget push to OpenViking — errors are swallowed, circuit breaker avoids hammering dead server
  private pushToViking(info: SessionInfo, messages: { role: string; content: string }[]): void {
    if (!this.opts?.viking) return
    this.opts.viking.checkAvailable().then(ok => {
      if (!ok) return
      const uri = `viking://sessions/${info.source}/${info.project ?? 'unknown'}/${info.id}`
      const content = messages.map(m => `[${m.role}] ${m.content}`).join('\n\n')
      this.opts!.viking!.addResource(uri, content, {
        source: info.source,
        project: info.project ?? '',
        startTime: info.startTime,
        model: info.model ?? '',
      }).catch(() => {})
    }).catch(() => {})
  }
```

Then after `db.indexSessionContent(info.id, messages, info.summary)` (line 56), add:

```typescript
          this.pushToViking(info, messages)
```

Also add the same call in `indexFile()` after `db.indexSessionContent` (line 118):

```typescript
      this.pushToViking(info, messages)
```

Add `SessionInfo` import if not already present:

```typescript
import type { SessionAdapter, SessionInfo } from '../adapters/types.js'
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/indexer-viking.test.ts`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All existing tests still pass (constructor change is backward-compatible)

- [ ] **Step 6: Commit**

```bash
git add src/core/indexer.ts tests/core/indexer-viking.test.ts
git commit -m "feat(indexer): add Viking dual-write (fire-and-forget)"
```

---

### Task 9: Search tool — Viking-first with fallback

**Files:**
- Modify: `src/tools/search.ts`
- Create: `tests/tools/search-viking.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// tests/tools/search-viking.test.ts
import { describe, it, expect, vi, afterEach } from 'vitest'
import { mkdtempSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { Database } from '../../src/core/db.js'
import { handleSearch } from '../../src/tools/search.js'
import type { VikingBridge, VikingSearchResult } from '../../src/core/viking-bridge.js'

// Helper to build a complete SessionInfo for upsertSession
function makeSession(overrides: Record<string, unknown>) {
  return {
    source: 'claude-code',
    startTime: '2026-03-16T00:00:00Z',
    messageCount: 5,
    userMessageCount: 3,
    assistantMessageCount: 2,
    toolMessageCount: 0,
    systemMessageCount: 0,
    sizeBytes: 100,
    cwd: '/tmp',
    ...overrides,
  } as any
}

describe('handleSearch with Viking', () => {
  let db: Database
  let tmpDir: string

  afterEach(() => {
    db?.close()
    if (tmpDir) rmSync(tmpDir, { recursive: true })
  })

  it('uses Viking find results when available', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    db.upsertSession(makeSession({ id: 'session-1', filePath: '/tmp/s1' }))

    const vikingResults: VikingSearchResult[] = [
      { uri: 'viking://sessions/claude-code/engram/session-1', score: 0.95, snippet: 'SSL fix found' },
    ]
    const mockViking = {
      find: vi.fn().mockResolvedValue(vikingResults),
      grep: vi.fn().mockResolvedValue([]),
    } as unknown as VikingBridge

    const result = await handleSearch(db, { query: 'SSL error' }, { viking: mockViking })
    expect(result.results).toHaveLength(1)
    expect(result.results[0].session.id).toBe('session-1')
    expect(result.searchModes).toContain('viking-semantic')
  })

  it('falls back to FTS when Viking is not provided', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    db.upsertSession(makeSession({ id: 'session-2', filePath: '/tmp/s2' }))
    db.indexSessionContent('session-2', [{ role: 'user', content: 'SSL certificate error' }])

    const result = await handleSearch(db, { query: 'SSL certificate' }, {})
    expect(result.searchModes).toContain('keyword')
  })

  it('falls back to FTS when Viking find() throws', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    db.upsertSession(makeSession({ id: 'session-3', filePath: '/tmp/s3' }))
    db.indexSessionContent('session-3', [{ role: 'user', content: 'SSL cert renewal' }])

    const mockViking = {
      find: vi.fn().mockRejectedValue(new Error('timeout')),
      grep: vi.fn().mockRejectedValue(new Error('timeout')),
    } as unknown as VikingBridge

    const result = await handleSearch(db, { query: 'SSL cert' }, { viking: mockViking })
    // FTS should still work even when Viking errors
    expect(result.searchModes).toContain('keyword')
    expect(result.results.length).toBeGreaterThan(0)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/tools/search-viking.test.ts`
Expected: FAIL — SearchDeps doesn't have `viking` property

- [ ] **Step 3: Extend SearchDeps and handleSearch**

In `src/tools/search.ts`:

```typescript
// Add import at top:
import { sessionIdFromVikingUri, type VikingBridge, type VikingSearchResult } from '../core/viking-bridge.js'

// Extend SearchDeps (line 6-9):
export interface SearchDeps {
  vectorStore?: VectorStore
  embed?: (text: string) => Promise<Float32Array | null>
  viking?: VikingBridge | null
}
```

Then after the semantic vector search block (after line 99), add Viking search:

```typescript
  // --- Viking semantic + keyword search ---
  // Viking results get a small RRF boost because they incorporate hierarchical context
  const VIKING_RRF_BOOST = 0.002
  const vikingScores = new Map<string, { score: number; snippet: string }>()

  if (deps.viking && params.query.length >= 2) {
    try {
      const [findResults, grepResults] = await Promise.all([
        deps.viking.find(params.query),
        params.query.length >= 3 ? deps.viking.grep(params.query) : Promise.resolve([]),
      ])

      const allViking = [...findResults, ...grepResults]
      if (findResults.length > 0) searchModes.push('viking-semantic')
      if (grepResults.length > 0) searchModes.push('viking-keyword')

      const seen = new Set<string>()
      let rank = 1
      for (const vr of allViking) {
        const sessionId = sessionIdFromVikingUri(vr.uri)
        if (!sessionId || seen.has(sessionId)) continue
        seen.add(sessionId)
        vikingScores.set(sessionId, { score: rrfScore(rank) + VIKING_RRF_BOOST, snippet: vr.snippet })
        rank++
      }
    } catch { /* Viking search failed, continue with FTS */ }
  }
```

Update the RRF merge to include Viking scores (modify line 102):

```typescript
  const allSessionIds = new Set([...ftsScores.keys(), ...vecScores.keys(), ...vikingScores.keys()])
```

And in the merge loop (line 108), add Viking score:

```typescript
    const viking = vikingScores.get(sessionId)
    const score = (fts?.score ?? 0) + (vec?.score ?? 0) + (viking?.score ?? 0)
    const matchType = fts && vec ? 'both' : fts ? 'keyword' : viking ? 'semantic' : 'semantic'
    merged.push({ sessionId, score, snippet: viking?.snippet ?? fts?.snippet ?? '', matchType })
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/tools/search-viking.test.ts`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass (SearchDeps extension is backward-compatible)

- [ ] **Step 6: Commit**

```bash
git add src/tools/search.ts tests/tools/search-viking.test.ts
git commit -m "feat(search): add Viking-first search with RRF merge and FTS fallback"
```

---

### Task 10: get_context — add `detail` parameter with Viking L1

**Files:**
- Modify: `src/tools/get_context.ts`
- Create: `tests/tools/get_context-viking.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// tests/tools/get_context-viking.test.ts
import { describe, it, expect, vi, afterEach } from 'vitest'
import { mkdtempSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { Database } from '../../src/core/db.js'
import { handleGetContext } from '../../src/tools/get_context.js'
import type { VikingBridge } from '../../src/core/viking-bridge.js'

function makeSession(overrides: Record<string, unknown>) {
  return {
    source: 'claude-code',
    startTime: '2026-03-16T00:00:00Z',
    messageCount: 5,
    userMessageCount: 3,
    assistantMessageCount: 2,
    toolMessageCount: 0,
    systemMessageCount: 0,
    sizeBytes: 100,
    cwd: '/tmp',
    ...overrides,
  } as any
}

describe('handleGetContext with Viking', () => {
  let db: Database
  let tmpDir: string

  afterEach(() => {
    db?.close()
    if (tmpDir) rmSync(tmpDir, { recursive: true })
  })

  it('uses Viking overview for L1 detail level', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'ctx-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    db.upsertSession(makeSession({
      id: 'session-1', filePath: '/tmp/s1',
      project: 'myproject', summary: 'Fixed auth bug',
    }))

    const mockViking = {
      find: vi.fn().mockResolvedValue([
        { uri: 'viking://sessions/claude-code/myproject/session-1', score: 0.9, snippet: '' },
      ]),
      overview: vi.fn().mockResolvedValue('Detailed L1 overview of auth bug fix session...'),
    } as unknown as VikingBridge

    const result = await handleGetContext(db,
      { cwd: '/projects/myproject', detail: 'overview' },
      { viking: mockViking }
    )

    expect(mockViking.overview).toHaveBeenCalled()
    expect(result.contextText).toContain('Detailed L1 overview')
  })

  it('falls back to summary-based context without Viking', async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'ctx-viking-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    db.upsertSession(makeSession({
      id: 'session-2', filePath: '/tmp/s2',
      project: 'myproject', summary: 'Fixed auth bug',
    }))

    const result = await handleGetContext(db, { cwd: '/projects/myproject' }, {})
    expect(result.contextText).toContain('Fixed auth bug')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/tools/get_context-viking.test.ts`
Expected: FAIL — `detail` not a valid parameter / GetContextDeps doesn't have `viking`

- [ ] **Step 3: Extend get_context tool schema, deps, and handler**

In `src/tools/get_context.ts`:

```typescript
// Add import:
import { sessionIdFromVikingUri, type VikingBridge } from '../core/viking-bridge.js'

// Add 'detail' to inputSchema properties (after max_tokens line 15):
      detail: { type: 'string', enum: ['abstract', 'overview', 'full'], description: '详情级别 (需要 OpenViking): abstract (~100 tokens), overview (~2K tokens), full' },

// Extend GetContextDeps (line 23-26):
export interface GetContextDeps {
  vectorStore?: VectorStore
  embed?: (text: string) => Promise<Float32Array | null>
  viking?: VikingBridge | null
}

// Extend params type in handleGetContext (line 30):
  params: { cwd: string; task?: string; max_tokens?: number; detail?: 'abstract' | 'overview' | 'full' },
```

Then add Viking-enhanced path after the sessions list is built (after line 68, before the context building loop):

```typescript
  // Viking-enhanced: use tiered content when available
  if (deps.viking && params.detail) {
    const readFn = params.detail === 'abstract' ? deps.viking.abstract.bind(deps.viking)
      : params.detail === 'full' ? deps.viking.read.bind(deps.viking)
      : deps.viking.overview.bind(deps.viking)

    // Use Viking find for task-based search, or build URIs from session list
    let targetSessions = sessions.slice(0, 5)
    if (params.task) {
      try {
        const vikingResults = await deps.viking.find(params.task)
        const vikingSessionIds = vikingResults.map(r => sessionIdFromVikingUri(r.uri))
        const vikingSessions = vikingSessionIds
          .map(id => db.getSession(id))
          .filter((s): s is NonNullable<typeof s> => s !== null)
        if (vikingSessions.length > 0) targetSessions = vikingSessions.slice(0, 5)
      } catch { /* fall through to session list */ }
    }

    // Pre-fetch all in parallel, then apply token budget
    const uris = targetSessions.map(s => `viking://sessions/${s.source}/${s.project ?? 'unknown'}/${s.id}`)
    const fetched = await Promise.allSettled(uris.map(u => readFn(u)))

    const parts: string[] = []
    let totalChars = 0
    const selectedSessions: typeof sessions = []

    if (params.task) {
      const taskLine = `当前任务：${params.task}\n`
      parts.push(taskLine)
      totalChars += taskLine.length
    }

    for (let i = 0; i < targetSessions.length; i++) {
      const result = fetched[i]
      const content = result.status === 'fulfilled' ? result.value : ''
      if (!content) continue
      const session = targetSessions[i]
      const line = `[${session.source}] ${toLocalDate(session.startTime)} — ${content}\n`
      if (totalChars + line.length > maxChars) break
      parts.push(line)
      totalChars += line.length
      selectedSessions.push(session)
    }

    const footer = `\n— ${selectedSessions.length} sessions (${params.detail}), ~${Math.ceil(totalChars / CHARS_PER_TOKEN)} tokens`
    parts.push(footer)

    return {
      contextText: parts.join(''),
      sessionCount: selectedSessions.length,
      sessionIds: selectedSessions.map(s => s.id),
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/tools/get_context-viking.test.ts`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add src/tools/get_context.ts tests/tools/get_context-viking.test.ts
git commit -m "feat(get_context): add detail parameter with Viking L0/L1/L2 tiered retrieval"
```

---

### Task 11: New get_memory MCP tool

**Files:**
- Create: `src/tools/get_memory.ts`
- Create: `tests/tools/get_memory.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// tests/tools/get_memory.test.ts
import { describe, it, expect, vi, afterEach } from 'vitest'
import { handleGetMemory } from '../../src/tools/get_memory.js'
import type { VikingBridge } from '../../src/core/viking-bridge.js'

describe('handleGetMemory', () => {
  it('returns memories from Viking', async () => {
    const mockViking = {
      findMemories: vi.fn().mockResolvedValue([
        { content: 'User prefers TypeScript', source: 'session-1', confidence: 0.9, createdAt: '2026-03-16' },
      ]),
    } as unknown as VikingBridge

    const result = await handleGetMemory({ query: 'coding style' }, { viking: mockViking })
    expect(result.memories).toHaveLength(1)
    expect(result.memories[0].content).toBe('User prefers TypeScript')
  })

  it('returns helpful message when Viking is not available', async () => {
    const result = await handleGetMemory({ query: 'coding style' }, {})
    expect(result.message).toContain('OpenViking')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/tools/get_memory.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement get_memory tool**

```typescript
// src/tools/get_memory.ts
import type { VikingBridge, VikingMemory } from '../core/viking-bridge.js'

export const getMemoryTool = {
  name: 'get_memory',
  description: 'Retrieve memories extracted from past sessions. Requires OpenViking.',
  inputSchema: {
    type: 'object' as const,
    required: ['query'],
    properties: {
      query: { type: 'string', description: 'What to remember (e.g. "user\'s coding preferences")' },
    },
    additionalProperties: false,
  },
}

export interface GetMemoryDeps {
  viking?: VikingBridge | null
}

export async function handleGetMemory(
  params: { query: string },
  deps: GetMemoryDeps = {}
): Promise<{ memories: VikingMemory[]; message?: string }> {
  if (!deps.viking) {
    return {
      memories: [],
      message: 'Memory features require OpenViking. See docs for setup: configure viking.url and viking.apiKey in ~/.engram/settings.json',
    }
  }

  const memories = await deps.viking.findMemories(params.query)
  return { memories }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/tools/get_memory.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/tools/get_memory.ts tests/tools/get_memory.test.ts
git commit -m "feat(tools): add get_memory MCP tool for Viking memory queries"
```

---

## Chunk 3: Wiring (index.ts, daemon.ts, web.ts) + macOS UI

### Task 12: Register get_memory and wire Viking in MCP server (index.ts)

**Files:**
- Modify: `src/index.ts`

- [ ] **Step 1: Add imports**

Add after the existing tool imports (after line 28):

```typescript
import { getMemoryTool, handleGetMemory } from './tools/get_memory.js'
import { VikingBridge } from './core/viking-bridge.js'
```

- [ ] **Step 2: Initialize VikingBridge and reorder Indexer creation**

The current `index.ts` creates the Indexer on line 33 *before* reading settings on line 36. We need vikingBridge before the Indexer. Move `readFileSettings()` and add VikingBridge init before the Indexer:

```typescript
// Move settings + viking init BEFORE indexer creation (before line 33):
const fileSettings = readFileSettings()
const vikingBridge = fileSettings.viking?.enabled
  ? new VikingBridge(fileSettings.viking.url, fileSettings.viking.apiKey)
  : null

const indexer = new Indexer(db, adapters, { viking: vikingBridge })

// Then vecDeps uses the same fileSettings (remove the duplicate readFileSettings call on line 36)
const vecDeps = initVectorDeps(db, {
  openaiApiKey: fileSettings.openaiApiKey,
  // ... rest unchanged
})
```

- [ ] **Step 3: Register get_memory in allTools array**

Add `getMemoryTool` to the `allTools` array (after `linkSessionsTool`, line 72):

```typescript
const allTools = [
  listSessionsTool,
  getSessionTool,
  searchTool,
  projectTimelineTool,
  statsTool,
  getContextTool,
  exportTool,
  generateSummaryTool,
  manageProjectAliasTool,
  linkSessionsTool,
  getMemoryTool,
]
```

- [ ] **Step 4: Add get_memory handler**

In the `CallToolRequestSchema` handler (after the `link_sessions` block, before the `else` on line 139):

```typescript
    } else if (name === 'get_memory') {
      result = await handleGetMemory(a as { query: string }, { viking: vikingBridge })
```

- [ ] **Step 5: Pass viking to search and get_context handlers**

Update the search handler (line 102-106) to pass Viking:

```typescript
    } else if (name === 'search') {
      const sDeps: SearchDeps = {
        ...(vecDeps ? { vectorStore: vecDeps.vectorStore, embed: (text: string) => vecDeps.embeddingClient.embed(text) } : {}),
        viking: vikingBridge,
      }
      result = await handleSearch(db, a as { query: string; mode?: string }, sDeps)
```

Update the get_context handler (line 111-113):

```typescript
    } else if (name === 'get_context') {
      const ctxDeps: GetContextDeps = { ...vectorDeps, viking: vikingBridge }
      const ctx = await handleGetContext(db, a as { cwd: string; task?: string; max_tokens?: number; detail?: string }, ctxDeps)
      return { content: [{ type: 'text', text: ctx.contextText }] }
```

Also update the `GetContextDeps` import (line 17) if needed.

- [ ] **Step 6: Build and verify**

Run: `npm run build`
Expected: Clean compile

- [ ] **Step 7: Run full test suite**

Run: `npm test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add src/index.ts
git commit -m "feat(mcp): register get_memory tool, wire Viking to search/context/indexer"
```

---

### Task 13: Daemon integration — initialize VikingBridge

**Files:**
- Modify: `src/daemon.ts`

- [ ] **Step 1: Add imports**

Add after existing imports (after line 14):

```typescript
import { VikingBridge } from './core/viking-bridge.js'
```

- [ ] **Step 2: Initialize VikingBridge after settings read**

Add after `const settings = readFileSettings()` (after line 21):

```typescript
// Viking bridge — optional external context engine
const vikingBridge = settings.viking?.enabled
  ? new VikingBridge(settings.viking.url, settings.viking.apiKey)
  : null
```

- [ ] **Step 3: Health check on startup and emit status**

Add after the Viking bridge initialization:

```typescript
if (vikingBridge) {
  vikingBridge.isAvailable().then(available => {
    emit({ event: 'viking_status', available })
  }).catch(() => {
    emit({ event: 'viking_status', available: false })
  })
}
```

- [ ] **Step 4: Pass viking to Indexer (reorder)**

In daemon.ts, `const indexer = new Indexer(db, adapters)` is on line 20 but settings are read on line 21. Move the indexer creation AFTER vikingBridge init:

```typescript
// line 19: const adapters = createAdapters()
// line 21: const settings = readFileSettings()
// NEW:     const vikingBridge = ...  (from Step 2)
// MOVE:    const indexer = new Indexer(db, adapters, { viking: vikingBridge })
```

- [ ] **Step 5: Pass viking to createApp**

Update the `createApp` call (line 176) to include Viking:

```typescript
const app = createApp(db, {
  vectorStore: vecDeps?.vectorStore,
  embeddingClient: vecDeps?.embeddingClient,
  syncEngine,
  syncPeers,
  settings,
  adapters,
  viking: vikingBridge,
})
```

- [ ] **Step 6: Build and verify**

Run: `npm run build`
Expected: Clean compile

- [ ] **Step 7: Commit**

```bash
git add src/daemon.ts
git commit -m "feat(daemon): initialize VikingBridge, pass to indexer and web"
```

---

### Task 14: Web API — Viking status and enhanced search

**Files:**
- Modify: `src/web.ts`

- [ ] **Step 1: Extend createApp opts to accept viking**

Update the `createApp` function signature (line 52-58):

```typescript
export function createApp(db: Database, opts?: {
  vectorStore?: VectorStore
  embeddingClient?: EmbeddingClient
  syncEngine?: SyncEngine
  syncPeers?: SyncPeer[]
  settings?: FileSettings
  adapters?: SessionAdapter[]
  viking?: VikingBridge | null
}) {
```

Add import at top:

```typescript
import type { VikingBridge } from './core/viking-bridge.js'
```

- [ ] **Step 2: Add cached vikingAvailable to /api/status**

Add a cached health check before the routes (avoids blocking network call on every status request):

```typescript
  // Viking health: cache result with 60s TTL to avoid blocking /api/status
  let vikingAvailableCache = false
  let vikingCacheTime = 0
  const VIKING_CACHE_TTL = 60_000

  async function isVikingAvailable(): Promise<boolean> {
    if (!opts?.viking) return false
    const now = Date.now()
    if (now - vikingCacheTime < VIKING_CACHE_TTL) return vikingAvailableCache
    vikingAvailableCache = await opts.viking.isAvailable()
    vikingCacheTime = now
    return vikingAvailableCache
  }
```

Then in the `/api/status` handler (line 120-135), add Viking fields:

```typescript
  app.get('/api/status', async (c) => {
    const totalSessions = db.countSessions()
    const sources = db.listSources()
    const projects = db.listProjects()
    const embeddedCount = opts?.vectorStore?.count() ?? 0
    const embeddingAvailable = !!(opts?.vectorStore && opts?.embeddingClient)
    const vikingAvailable = await isVikingAvailable()
    return c.json({
      totalSessions,
      sourceCount: sources.length,
      projectCount: projects.length,
      sources,
      projects,
      embeddingAvailable,
      embeddedCount,
      vikingAvailable,
    })
  })
```

- [ ] **Step 3: Pass viking to search handler**

Update searchDeps (line 177-179):

```typescript
  const searchDeps: SearchDeps = {
    ...(opts?.vectorStore && opts?.embeddingClient
      ? { vectorStore: opts.vectorStore, embed: (text: string) => opts!.embeddingClient!.embed(text) }
      : {}),
    viking: opts?.viking ?? null,
  }
```

- [ ] **Step 4: Build and verify**

Run: `npm run build`
Expected: Clean compile

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add src/web.ts
git commit -m "feat(web): add Viking status to /api/status, pass to search"
```

---

### Task 15: macOS Settings — Viking configuration section

**Files:**
- Modify: `macos/Engram/Views/SettingsView.swift`

- [ ] **Step 1: Add Viking state variables**

Add after the sync state variables (after line 67):

```swift
    // Viking (OpenViking) settings
    @State private var vikingEnabled: Bool = false
    @State private var vikingURL: String = ""
    @State private var vikingApiKey: String = ""
    @State private var vikingStatus: String = ""
    @State private var isCheckingViking: Bool = false
```

- [ ] **Step 2: Add Viking settings section**

Add before the "Sync" section (before line 330):

```swift
            Section("OpenViking") {
                Toggle("Enable", isOn: $vikingEnabled)
                    .onChange(of: vikingEnabled) { saveVikingSettings() }

                HStack {
                    Text("Server URL")
                    Spacer()
                    TextField("http://localhost:1933", text: $vikingURL)
                        .frame(width: 260)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: vikingURL) { saveVikingSettings() }
                }

                HStack {
                    Text("API Key")
                    Spacer()
                    SecureField("Required", text: $vikingApiKey)
                        .frame(width: 260)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: vikingApiKey) { saveVikingSettings() }
                }

                HStack {
                    Button {
                        checkVikingStatus()
                    } label: {
                        Text("Test Connection")
                    }
                    .disabled(isCheckingViking || !vikingEnabled || vikingURL.isEmpty)

                    if !vikingStatus.isEmpty {
                        Circle()
                            .fill(vikingStatus == "Connected" ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(verbatim: vikingStatus)
                            .font(.caption)
                            .foregroundStyle(vikingStatus == "Connected" ? .green : .red)
                    }
                }

                Text("OpenViking enhances search with semantic understanding and tiered summaries")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
```

- [ ] **Step 3: Add save/load/check methods**

Add after `loadSyncSettings()` (after line 588):

```swift
    private func saveVikingSettings() {
        mutateSettings { settings in
            var viking: [String: Any] = [:]
            viking["enabled"] = vikingEnabled
            if !vikingURL.isEmpty { viking["url"] = vikingURL }
            if !vikingApiKey.isEmpty { viking["apiKey"] = vikingApiKey }
            settings["viking"] = viking
        }
    }

    private func loadVikingSettings() {
        guard let settings = readSettings(),
              let viking = settings["viking"] as? [String: Any] else { return }
        if let enabled = viking["enabled"] as? Bool { vikingEnabled = enabled }
        if let url = viking["url"] as? String { vikingURL = url }
        if let key = viking["apiKey"] as? String { vikingApiKey = key }
    }

    private func checkVikingStatus() {
        isCheckingViking = true
        vikingStatus = ""

        guard let url = URL(string: "\(vikingURL)/api/health") else {
            vikingStatus = "Invalid URL"
            isCheckingViking = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(vikingApiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                isCheckingViking = false
                if let error = error {
                    vikingStatus = "Error: \(error.localizedDescription)"
                } else if let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) {
                    vikingStatus = "Connected"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if vikingStatus == "Connected" { vikingStatus = "" }
                    }
                } else {
                    vikingStatus = "Unreachable"
                }
            }
        }.resume()
    }
```

- [ ] **Step 4: Call loadVikingSettings() in onAppear**

Update the `.onAppear` block (line 454-457) to also load Viking settings:

```swift
        .onAppear {
            loadAISettings()
            loadSyncSettings()
            loadVikingSettings()
        }
```

- [ ] **Step 5: Build macOS app**

Run from `macos/`: `xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add macos/Engram/Views/SettingsView.swift
git commit -m "feat(macos): add OpenViking configuration section in Settings"
```

---

### Task 16: Final verification

- [ ] **Step 1: Full TypeScript build**

Run: `npm run build`
Expected: Clean compile, no errors

- [ ] **Step 2: Full test suite**

Run: `npm test`
Expected: All tests pass (173+ existing + ~15 new)

- [ ] **Step 3: Verify Viking-off behavior (graceful degradation)**

The existing test suite running without a Viking server proves all tools work with Viking disabled (the default path). No Viking = no VikingBridge = all `deps.viking` checks are falsy.

- [ ] **Step 4: Commit any remaining changes**

```bash
git status
# If any unstaged changes, add and commit
```
