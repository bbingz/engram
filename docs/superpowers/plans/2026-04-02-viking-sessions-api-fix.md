# Viking Sessions API Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate Viking integration from Resources API (100M+ tokens/batch) to Sessions API (~6M tokens/batch) — a 94% cost reduction.

**Architecture:** Fix `pushSession()` message format, add `X-Agent-Id` header, switch `indexer.ts` from `addResource()` to `pushSession()`, rewrite `get_context.ts` to use memory-based results directly (not resource URI mapping), update `search.ts` to surface Viking memory results as standalone "Related Knowledge", and fix `findMemories()` URI targets.

**Tech Stack:** TypeScript (strict, ES2022, Node16 modules), Vitest, OpenViking REST API

**Spec:** `docs/superpowers/specs/2026-04-02-viking-sessions-api-fix-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/core/viking-bridge.ts` | Modify | Fix `pushSession` parts format, add `agentId` header, fix `find()` skills, fix `findMemories()` URIs |
| `src/core/indexer.ts` | Modify | Switch `pushToViking()` from `addResource()` to `pushSession()` with `::` composite session ID |
| `src/core/bootstrap.ts` | Modify | Pass `agentId` from settings to `VikingBridge` constructor |
| `src/core/config.ts` | Modify | Add `agentId` to `VikingSettings` interface |
| `src/tools/get_context.ts` | Modify | Rewrite Viking-enhanced section: use `find()` memory snippets directly instead of resource URI mapping |
| `src/tools/search.ts` | Modify | Add memory-aware pipeline: session-mapped results go to RRF, memory results go to "Related Knowledge" section |
| `src/web.ts` | Modify | Update backfill endpoint from `addResource()` to `pushSession()` with dedup tracking |
| `tests/core/viking-bridge.test.ts` | Modify | Add `agentId` header test, fix `pushSession` parts format assertion, add `findMemories` dual-URI test, add `find` skills test |
| `tests/core/indexer-viking.test.ts` | Modify | Switch mock from `addResource` to `pushSession`, verify composite session ID |
| `tests/tools/search-viking.test.ts` | Modify | Add memory URI test case, verify "Related Knowledge" handling |
| `tests/tools/get_context-viking.test.ts` | Modify | Rewrite for memory-based approach: mock `find()` returning memory snippets |

---

### Task 1: Fix `VikingBridge` — message format, agentId, find skills, findMemories URIs

**Files:**
- Modify: `src/core/viking-bridge.ts:96-106` (constructor), `src/core/viking-bridge.ts:176-181` (pushSession messages), `src/core/viking-bridge.ts:280-284` (find), `src/core/viking-bridge.ts:372-384` (findMemories)
- Modify: `src/core/config.ts:28-32` (VikingSettings interface)
- Test: `tests/core/viking-bridge.test.ts`

- [ ] **Step 1: Write failing test — pushSession sends `parts` format**

In `tests/core/viking-bridge.test.ts`, add to the existing `pushSession` describe block:

```typescript
it('sends messages with parts format (not flat content)', async () => {
  const bridge = new VikingBridge('http://localhost:1933', 'key');
  const mockFetch = vi.fn().mockResolvedValue({
    ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }),
  });
  vi.stubGlobal('fetch', mockFetch);

  await bridge.pushSession('test-parts', [
    { role: 'user', content: 'Hello world' },
  ]);

  // Message call is the second (after create)
  const msgBody = JSON.parse(mockFetch.mock.calls[1][1].body);
  expect(msgBody.parts).toEqual([{ type: 'text', text: 'Hello world' }]);
  expect(msgBody).not.toHaveProperty('content');
});
```

- [ ] **Step 2: Write failing test — agentId header**

Add a new `describe('agentId header')` block:

```typescript
describe('agentId header', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('includes X-Agent-Id header when agentId is provided', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key', { agentId: 'ffb1327b18bf' });
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.isAvailable();
    expect(mockFetch.mock.calls[0][1].headers).toHaveProperty('X-Agent-Id', 'ffb1327b18bf');
  });

  it('omits X-Agent-Id header when agentId is not provided', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.isAvailable();
    expect(mockFetch.mock.calls[0][1].headers).not.toHaveProperty('X-Agent-Id');
  });
});
```

- [ ] **Step 3: Write failing test — find() includes skills**

Add to the existing `find` describe block:

```typescript
it('includes skills in find results', async () => {
  const bridge = new VikingBridge('http://localhost:1933', 'key');
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
    ok: true, json: () => Promise.resolve({ result: {
      resources: [],
      memories: [{ uri: 'viking://user/default/memories/pref-1', score: 0.8, abstract: 'Prefers TypeScript' }],
      skills: [{ uri: 'viking://agent/default/skills/debug', score: 0.7, abstract: 'Debugging patterns' }],
    }}),
  }));
  const results = await bridge.find('coding preferences');
  expect(results).toHaveLength(2);
  expect(results.map(r => r.uri)).toContain('viking://agent/default/skills/debug');
});
```

- [ ] **Step 4: Write failing test — findMemories searches user + agent scopes**

Replace the existing `findMemories` test:

```typescript
it('findMemories searches both user and agent memory scopes', async () => {
  const bridge = new VikingBridge('http://localhost:1933', 'key');
  const mockFetch = vi.fn()
    // First call: user memories
    .mockResolvedValueOnce({
      ok: true, json: () => Promise.resolve({ result: {
        memories: [{ uri: 'viking://user/default/memories/pref-1', score: 0.9, abstract: 'User prefers TS' }],
        resources: [],
      }}),
    })
    // Second call: agent memories
    .mockResolvedValueOnce({
      ok: true, json: () => Promise.resolve({ result: {
        memories: [{ uri: 'viking://agent/default/memories/pattern-1', score: 0.7, abstract: 'Debug pattern' }],
        resources: [],
      }}),
    });
  vi.stubGlobal('fetch', mockFetch);
  const result = await bridge.findMemories('coding style');
  expect(result).toHaveLength(2);
  // Sorted by confidence descending
  expect(result[0].confidence).toBe(0.9);
  expect(result[1].confidence).toBe(0.7);
  // Verify two find calls with different target URIs
  const call1Body = JSON.parse(mockFetch.mock.calls[0][1].body);
  const call2Body = JSON.parse(mockFetch.mock.calls[1][1].body);
  expect(call1Body.target_uri).toBe('viking://user/');
  expect(call2Body.target_uri).toBe('viking://agent/');
});
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: 4 new tests FAIL (parts format mismatch, no agentId header, no skills in find, wrong findMemories URI)

- [ ] **Step 6: Implement — fix pushSession message format**

In `src/core/viking-bridge.ts`, change lines 176-181:

```typescript
// BEFORE:
for (const msg of messages) {
  await this.post(`${this.api}/sessions/${sessionId}/messages/async`, {
    role: msg.role,
    content: msg.content,
  }, 5000);
}

// AFTER:
for (const msg of messages) {
  await this.post(`${this.api}/sessions/${sessionId}/messages/async`, {
    role: msg.role,
    parts: [{ type: 'text', text: msg.content }],
  }, 5000);
}
```

- [ ] **Step 7: Implement — add agentId to constructor**

In `src/core/viking-bridge.ts`, change the constructor (lines 96-106):

```typescript
// BEFORE:
constructor(url: string, apiKey: string, opts?: { log?: Logger; metrics?: MetricsCollector; tracer?: Tracer }) {
  this.baseUrl = url.replace(/\/$/, '');
  this.api = `${this.baseUrl}/api/v1`;
  this.headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${apiKey}`,
  };
  this.log = opts?.log;
  this.metrics = opts?.metrics;
  this.tracer = opts?.tracer;
}

// AFTER:
constructor(url: string, apiKey: string, opts?: { agentId?: string; log?: Logger; metrics?: MetricsCollector; tracer?: Tracer }) {
  this.baseUrl = url.replace(/\/$/, '');
  this.api = `${this.baseUrl}/api/v1`;
  this.headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${apiKey}`,
  };
  if (opts?.agentId) this.headers['X-Agent-Id'] = opts.agentId;
  this.log = opts?.log;
  this.metrics = opts?.metrics;
  this.tracer = opts?.tracer;
}
```

- [ ] **Step 8: Implement — fix find() to include skills**

In `src/core/viking-bridge.ts`, change lines 280-284:

```typescript
// BEFORE:
const items = [
  ...(Array.isArray(r) ? r : []),
  ...(Array.isArray(r.resources) ? r.resources : []),
  ...(Array.isArray(r.memories) ? r.memories : []),
];

// AFTER:
const items = [
  ...(Array.isArray(r) ? r : []),
  ...(Array.isArray(r.resources) ? r.resources : []),
  ...(Array.isArray(r.memories) ? r.memories : []),
  ...(Array.isArray(r.skills) ? r.skills : []),
];
```

- [ ] **Step 9: Implement — fix findMemories() to search user + agent scopes**

In `src/core/viking-bridge.ts`, replace the `findMemories` method (lines 372-384):

```typescript
async findMemories(query: string): Promise<VikingMemory[]> {
  try {
    const [userResults, agentResults] = await Promise.all([
      this.find(query, 'viking://user/'),
      this.find(query, 'viking://agent/'),
    ]);
    const all = [...userResults, ...agentResults]
      .sort((a, b) => b.score - a.score);
    return all.map(r => ({
      content: r.snippet,
      source: r.uri,
      confidence: r.score,
      createdAt: r.metadata?.createdAt ?? '',
    }));
  } catch {
    return [];
  }
}
```

- [ ] **Step 10: Implement — add agentId to VikingSettings**

In `src/core/config.ts`, change lines 28-32:

```typescript
// BEFORE:
export interface VikingSettings {
  url?: string;
  apiKey?: string;
  enabled?: boolean;
}

// AFTER:
export interface VikingSettings {
  url?: string;
  apiKey?: string;
  agentId?: string;
  enabled?: boolean;
}
```

- [ ] **Step 11: Run tests to verify they pass**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: ALL tests PASS

- [ ] **Step 12: Commit**

```bash
git add src/core/viking-bridge.ts src/core/config.ts tests/core/viking-bridge.test.ts
git commit -m "fix(viking): fix pushSession parts format, add agentId header, include skills in find, fix findMemories URIs"
```

---

### Task 2: Fix `bootstrap.ts` — pass agentId to VikingBridge

**Files:**
- Modify: `src/core/bootstrap.ts:68-73`

- [ ] **Step 1: Implement — pass agentId from settings**

In `src/core/bootstrap.ts`, change the `initViking` function (lines 68-73):

```typescript
// BEFORE:
export function initViking(settings: FileSettings, opts?: { log?: Logger; metrics?: MetricsCollector; tracer?: Tracer }): VikingBridge | null {
  if (settings.viking?.enabled && settings.viking.url && settings.viking.apiKey) {
    return new VikingBridge(settings.viking.url, settings.viking.apiKey, opts)
  }
  return null
}

// AFTER:
export function initViking(settings: FileSettings, opts?: { log?: Logger; metrics?: MetricsCollector; tracer?: Tracer }): VikingBridge | null {
  if (settings.viking?.enabled && settings.viking.url && settings.viking.apiKey) {
    return new VikingBridge(settings.viking.url, settings.viking.apiKey, {
      agentId: settings.viking.agentId,
      ...opts,
    })
  }
  return null
}
```

- [ ] **Step 2: Verify build passes**

Run: `npx tsc --noEmit`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add src/core/bootstrap.ts
git commit -m "fix(viking): pass agentId from settings to VikingBridge constructor"
```

---

### Task 3: Switch `indexer.ts` from `addResource()` to `pushSession()`

**Files:**
- Modify: `src/core/indexer.ts:37-69` (pushToViking method), `src/core/indexer.ts:15` (import)
- Test: `tests/core/indexer-viking.test.ts`

- [ ] **Step 1: Write failing test — indexer calls pushSession**

Replace the first test in `tests/core/indexer-viking.test.ts`:

```typescript
it('calls viking.pushSession (not addResource) after indexing a premium session', async () => {
  tmpDir = mkdtempSync(join(tmpdir(), 'indexer-viking-'))
  db = new Database(join(tmpDir, 'test.sqlite'))
  const mockViking = {
    checkAvailable: vi.fn().mockResolvedValue(true),
    pushSession: vi.fn().mockResolvedValue(undefined),
  } as unknown as VikingBridge

  const filePath = join(tmpDir, 'session.jsonl')
  const adapter = {
    name: 'codex',
    detect: () => Promise.resolve(true),
    listSessionFiles: async function* () { yield filePath },
    parseSessionInfo: () => Promise.resolve(makeSessionInfo({ id: 'test-session-1', filePath, messageCount: 20, userMessageCount: 10, assistantMessageCount: 10 })),
    streamMessages: async function* () {
      yield { role: 'user', content: 'Hello' }
      yield { role: 'assistant', content: 'Hi there' }
    },
  }
  writeFileSync(filePath, '{}')
  const indexer = new Indexer(db, [adapter as any], { viking: mockViking })
  await indexer.indexAll()
  await new Promise(r => setTimeout(r, 50))
  expect(mockViking.pushSession).toHaveBeenCalledWith(
    'codex::unknown::test-session-1',   // composite session ID with :: separator
    expect.arrayContaining([
      expect.objectContaining({ role: 'user', content: 'Hello' }),
    ])
  )
})
```

- [ ] **Step 2: Update second test — pushSession failure does not crash indexer**

Replace the second test:

```typescript
it('does not fail if viking.pushSession throws', async () => {
  tmpDir = mkdtempSync(join(tmpdir(), 'indexer-viking-'))
  db = new Database(join(tmpDir, 'test.sqlite'))
  const mockViking = {
    checkAvailable: vi.fn().mockResolvedValue(true),
    pushSession: vi.fn().mockRejectedValue(new Error('server down')),
  } as unknown as VikingBridge

  const filePath = join(tmpDir, 'session.jsonl')
  const adapter = {
    name: 'codex',
    detect: () => Promise.resolve(true),
    listSessionFiles: async function* () { yield filePath },
    parseSessionInfo: () => Promise.resolve(makeSessionInfo({
      id: 'test-session-2', filePath, messageCount: 1, userMessageCount: 1, assistantMessageCount: 0, sizeBytes: 50,
    })),
    streamMessages: async function* () { yield { role: 'user', content: 'test' } },
  }
  writeFileSync(filePath, '{}')
  const indexer = new Indexer(db, [adapter as any], { viking: mockViking })
  const count = await indexer.indexAll()
  expect(count).toBe(1)
  expect(db.getSession('test-session-2')).not.toBeNull()
})
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npx vitest run tests/core/indexer-viking.test.ts`
Expected: First test FAIL (pushSession not called — addResource is called instead)

- [ ] **Step 4: Implement — rewrite pushToViking**

In `src/core/indexer.ts`, replace `pushToViking` method (lines 37-69):

```typescript
private async pushToViking(info: SessionInfo, messages: { role: string; content: string }[]): Promise<void> {
  if (!this.opts?.viking || messages.length === 0) return

  // Skip if already pushed with same message count (no new content)
  try {
    const row = this.db.getRawDb().prepare(
      'SELECT viking_pushed_msg_count FROM sessions WHERE id = ?'
    ).get(info.id) as { viking_pushed_msg_count: number | null } | undefined
    if (row?.viking_pushed_msg_count != null && row.viking_pushed_msg_count >= messages.length) return
  } catch { /* column may not exist yet */ }

  try {
    const ok = await this.opts.viking.checkAvailable()
    if (!ok) return
    const filtered = filterForViking(messages)
    if (filtered.length === 0) return
    const sessionId = `${info.source}::${info.project ?? 'unknown'}::${info.id}`
    await this.opts.viking.pushSession(sessionId, filtered)
    try {
      this.db.getRawDb().prepare(
        "UPDATE sessions SET viking_pushed_at = datetime('now'), viking_pushed_msg_count = ? WHERE id = ?"
      ).run(messages.length, info.id)
    } catch { /* best-effort */ }
  } catch (err) {
    this.log?.warn('viking push failed', { sessionId: info.id }, err)
  }
}
```

- [ ] **Step 5: Remove unused import**

In `src/core/indexer.ts`, change line 15:

```typescript
// BEFORE:
import { toVikingUri, type VikingBridge } from './viking-bridge.js'

// AFTER:
import type { VikingBridge } from './viking-bridge.js'
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `npx vitest run tests/core/indexer-viking.test.ts`
Expected: ALL tests PASS

- [ ] **Step 7: Commit**

```bash
git add src/core/indexer.ts tests/core/indexer-viking.test.ts
git commit -m "fix(viking): switch indexer from addResource to pushSession with composite session IDs"
```

---

### Task 4: Rewrite `get_context.ts` Viking-enhanced section

**Files:**
- Modify: `src/tools/get_context.ts:7-8` (imports), `src/tools/get_context.ts:90-144` (Viking-enhanced block)
- Test: `tests/tools/get_context-viking.test.ts`

- [ ] **Step 1: Write failing test — uses find() memory snippets directly**

Replace the first test in `tests/tools/get_context-viking.test.ts`:

```typescript
it('uses Viking find() memory snippets directly for context', async () => {
  tmpDir = mkdtempSync(join(tmpdir(), 'ctx-viking-'))
  db = new Database(join(tmpDir, 'test.sqlite'))
  db.upsertSession(makeSession({ id: 'session-1', filePath: '/tmp/s1', project: 'myproject', summary: 'Fixed auth bug' }))
  const mockViking = {
    checkAvailable: vi.fn().mockResolvedValue(true),
    find: vi.fn().mockResolvedValue([
      { uri: 'viking://user/default/memories/pref-1', score: 0.9, snippet: 'User prefers TypeScript strict mode' },
      { uri: 'viking://agent/default/memories/pattern-1', score: 0.8, snippet: 'Auth module uses JWT with bcrypt' },
    ]),
  } as unknown as VikingBridge
  const result = await handleGetContext(db,
    { cwd: '/projects/myproject', task: 'fix auth', detail: 'overview' },
    { viking: mockViking }
  )
  // Memory snippets should appear in context
  expect(result.contextText).toContain('User prefers TypeScript strict mode')
  expect(result.contextText).toContain('Auth module uses JWT with bcrypt')
  // Should NOT call overview/abstract/read (no resource URI mapping)
  expect(mockViking).not.toHaveProperty('overview')
})
```

- [ ] **Step 2: Add test — includes local session summaries alongside memories**

```typescript
it('includes local session summaries alongside Viking memories', async () => {
  tmpDir = mkdtempSync(join(tmpdir(), 'ctx-viking-'))
  db = new Database(join(tmpDir, 'test.sqlite'))
  db.upsertSession(makeSession({ id: 'session-1', filePath: '/tmp/s1', project: 'myproject', summary: 'Migrated auth to JWT' }))
  const mockViking = {
    checkAvailable: vi.fn().mockResolvedValue(true),
    find: vi.fn().mockResolvedValue([
      { uri: 'viking://user/default/memories/pref-1', score: 0.9, snippet: 'Prefers async/await' },
    ]),
  } as unknown as VikingBridge
  const result = await handleGetContext(db,
    { cwd: '/projects/myproject', task: 'update auth', detail: 'overview' },
    { viking: mockViking }
  )
  expect(result.contextText).toContain('Prefers async/await')
  expect(result.contextText).toContain('Migrated auth to JWT')
})
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npx vitest run tests/tools/get_context-viking.test.ts`
Expected: FAIL (current code tries to call `overview()` which doesn't exist on the mock)

- [ ] **Step 4: Implement — rewrite Viking-enhanced block**

In `src/tools/get_context.ts`, change the import (line 7):

```typescript
// BEFORE:
import { sessionIdFromVikingUri, toVikingUri, type VikingBridge } from '../core/viking-bridge.js'

// AFTER:
import type { VikingBridge } from '../core/viking-bridge.js'
```

Then replace the Viking-enhanced block (lines 90-144):

```typescript
  // Viking-enhanced: use find() memory snippets + local session summaries
  if (deps.viking && params.detail && await deps.viking.checkAvailable()) {
    let vikingContext: string[] = []
    if (params.task) {
      try {
        const vikingResults = await deps.viking.find(params.task)
        vikingContext = vikingResults
          .filter(r => r.snippet)
          .slice(0, 5)
          .map(r => r.snippet)
      } catch { /* fall through */ }
    }

    const targetSessions = sessions.slice(0, 5)
    const parts: string[] = []
    let totalChars = 0

    if (params.task) {
      const taskLine = `当前任务：${params.task}\n`
      parts.push(taskLine)
      totalChars += taskLine.length
    }

    // Viking memories first (cross-session extracted knowledge)
    for (const mem of vikingContext) {
      const line = `[memory] ${mem}\n`
      if (totalChars + line.length > maxChars) break
      parts.push(line)
      totalChars += line.length
    }

    // Then local session summaries
    const selectedSessions: typeof sessions = []
    for (const session of targetSessions) {
      if (!session.summary) continue
      const line = `[${session.source}] ${toLocalDate(session.startTime)} — ${session.summary}\n`
      if (totalChars + line.length > maxChars) break
      parts.push(line)
      totalChars += line.length
      selectedSessions.push(session)
    }

    const footer = `\n— ${selectedSessions.length} sessions + ${vikingContext.length} memories (${params.detail}), ~${Math.ceil(totalChars / CHARS_PER_TOKEN)} tokens`
    parts.push(footer)

    const envSection = (params.include_environment !== false) ? await gatherEnvironmentData(db, deps, params, maxTokens) : ''

    return {
      contextText: parts.join('') + envSection,
      sessionCount: selectedSessions.length,
      sessionIds: selectedSessions.map(s => s.id),
    }
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npx vitest run tests/tools/get_context-viking.test.ts`
Expected: ALL tests PASS

- [ ] **Step 6: Commit**

```bash
git add src/tools/get_context.ts tests/tools/get_context-viking.test.ts
git commit -m "fix(viking): rewrite get_context to use memory snippets instead of resource URI mapping"
```

---

### Task 5: Update `search.ts` — memory-aware Viking pipeline

**Files:**
- Modify: `src/tools/search.ts:143-168` (Viking search section), `src/tools/search.ts:171-182` (RRF merge)
- Test: `tests/tools/search-viking.test.ts`

- [ ] **Step 1: Write failing test — memory URIs returned as knowledge**

Add a new test to `tests/tools/search-viking.test.ts`:

```typescript
it('returns Viking memory results that cannot map to sessions', async () => {
  tmpDir = mkdtempSync(join(tmpdir(), 'search-viking-'))
  db = new Database(join(tmpDir, 'test.sqlite'))
  db.upsertSession(makeSession({ id: 'session-1', filePath: '/tmp/s1' }))
  const vikingResults: VikingSearchResult[] = [
    // Memory URI — does NOT map to a session
    { uri: 'viking://user/default/memories/pref-1', score: 0.95, snippet: 'User prefers TypeScript strict mode' },
    // Session URI — maps to session-1
    { uri: 'viking://session/claude-code/engram/session-1', score: 0.8, snippet: 'Fixed auth bug' },
  ]
  const mockViking = {
    checkAvailable: vi.fn().mockResolvedValue(true),
    find: vi.fn().mockResolvedValue(vikingResults),
  } as unknown as VikingBridge
  const result = await handleSearch(db, { query: 'TypeScript preferences' }, { viking: mockViking })
  // Session result should be in main results
  expect(result.results.some(r => r.session.id === 'session-1')).toBe(true)
  // Memory results should be surfaced via vikingMemories
  expect(result.vikingMemories).toContain('User prefers TypeScript strict mode')
  expect(result.searchModes).toContain('viking-semantic')
})
```

- [ ] **Step 2: Run test to verify current behavior**

Run: `npx vitest run tests/tools/search-viking.test.ts`
Expected: May PASS (memory results are just silently dropped by current code — the test verifies they don't crash)

- [ ] **Step 3: Implement — add memory collection to Viking search section**

In `src/tools/search.ts`, update the return type to support vikingMemories. Add to the `SearchResult` or return interface. We'll surface them in the result object.

First, update the return type of `handleSearch` (add `vikingMemories` field):

In `src/tools/search.ts`, change the function signature return type (line 54):

```typescript
// BEFORE:
): Promise<{ results: SearchResult[]; query: string; searchModes: string[]; warning?: string }> {

// AFTER:
): Promise<{ results: SearchResult[]; query: string; searchModes: string[]; vikingMemories?: string[]; warning?: string }> {
```

Then update the Viking search section (lines 143-168). Replace the inner part of the Viking async block:

```typescript
    // Viking semantic search (find only — grep excluded for latency)
    (async () => {
      if (deps.viking && vikingAvailable) {
        const vikStart = performance.now()
        const vikingSpan = deps.tracer?.startSpan('search.viking', 'search', { parentSpan: searchSpan })
        try {
          const findResults = await deps.viking.find(params.query)
          if (findResults.length > 0) searchModes.push('viking-semantic')
          const seen = new Set<string>()
          let rank = 1
          for (const vr of findResults) {
            const sessionId = sessionIdFromVikingUri(vr.uri)
            if (sessionId && !seen.has(sessionId)) {
              seen.add(sessionId)
              vikingScores.set(sessionId, { score: rrfScore(rank) + VIKING_RRF_BOOST, snippet: vr.snippet })
              rank++
            } else if (!sessionId && vr.snippet) {
              // Memory/skill results — standalone knowledge entries
              vikingMemoryResults.push(vr.snippet)
            }
          }
          deps.metrics?.histogram('search.viking_ms', performance.now() - vikStart)
          vikingSpan?.setAttribute('resultCount', vikingScores.size)
          vikingSpan?.end()
        } catch (err) {
          vikingSpan?.setError(err)
          /* intentional: Viking search failed, continue with FTS */
        }
      }
    })(),
```

Add `vikingMemoryResults` array declaration (near line 88, after vikingScores):

```typescript
const vikingMemoryResults: string[] = []
```

Finally, include `vikingMemories` in the return value (near line 222):

```typescript
return { results, query: params.query, searchModes, vikingMemories: vikingMemoryResults.length > 0 ? vikingMemoryResults.slice(0, 5) : undefined, warning }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/tools/search-viking.test.ts`
Expected: ALL tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/tools/search.ts tests/tools/search-viking.test.ts
git commit -m "fix(viking): add memory-aware pipeline to search, surface memories as vikingMemories"
```

---

### Task 6: Update `web.ts` backfill endpoint

**Files:**
- Modify: `src/web.ts:616-665` (backfill endpoint)

- [ ] **Step 1: Implement — switch backfill from addResource to pushSession**

In `src/web.ts`, replace the backfill endpoint (lines 616-665):

```typescript
  // --- Viking backfill: push premium sessions to OpenViking via Sessions API ---
  app.post('/api/viking/backfill', async (c) => {
    if (!opts?.viking || !opts?.adapters) {
      return c.json({ error: 'Viking not configured or no adapters' }, 501)
    }
    const viking = opts.viking
    const available = await viking.checkAvailable()
    if (!available) {
      return c.json({ error: 'Viking server unreachable' }, 503)
    }

    const limit = parseInt(c.req.query('limit') ?? '100', 10)
    const offset = parseInt(c.req.query('offset') ?? '0', 10)
    const source = c.req.query('source')
    const sessions = db.listPremiumSessions({ source: source || undefined, limit, offset })

    let pushed = 0
    let skipped = 0
    const failures: { id: string; error: string }[] = []
    for (const session of sessions) {
      try {
        const adapter = opts.adapters.find(a => a.name === session.source)
        if (!adapter) continue

        const messages: { role: string; content: string }[] = []
        for await (const msg of adapter.streamMessages(session.filePath)) {
          if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
            messages.push({ role: msg.role, content: msg.content })
          }
        }
        if (messages.length === 0) continue

        const filtered = filterForViking(messages)
        if (filtered.length === 0) { skipped++; continue }

        const sessionId = `${session.source}::${session.project ?? 'unknown'}::${session.id}`
        await viking.pushSession(sessionId, filtered)

        // Track push to prevent duplicate work by indexer
        try {
          db.getRawDb().prepare(
            "UPDATE sessions SET viking_pushed_at = datetime('now'), viking_pushed_msg_count = ? WHERE id = ?"
          ).run(messages.length, session.id)
        } catch { /* best-effort */ }

        pushed++
      } catch (err) {
        failures.push({ id: session.id, error: err instanceof Error ? err.message : String(err) })
      }
    }

    return c.json({ pushed, skipped, errors: failures.length, failures: failures.slice(0, 10), total: sessions.length, offset, limit })
  })
```

- [ ] **Step 2: Verify build passes**

Run: `npx tsc --noEmit`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add src/web.ts
git commit -m "fix(viking): switch backfill endpoint from addResource to pushSession"
```

---

### Task 7: Full test suite verification

- [ ] **Step 1: Run full test suite**

Run: `npm test`
Expected: ALL tests PASS (684+ tests)

- [ ] **Step 2: Run build**

Run: `npm run build`
Expected: Build succeeds with no errors

- [ ] **Step 3: Final commit (if any fixes needed)**

If any test failures were found and fixed, commit those fixes.

---

## Notes

- `pushToViking()` remains fire-and-forget (not awaited) at call sites in `indexer.ts:280,417`. This is intentional — Viking push must not block session indexing.
- Composite session IDs use `::` separator (`{source}::{project}::{id}`) to avoid collision with directory names.
- Old Resources API data is preserved. Cleanup is available via `POST /api/viking/cleanup`.
- The `extractMemory()` and `addResource()` methods remain on `VikingBridge` — they're not removed, just no longer called from the indexer hot path.
- `toVikingUri()` and `sessionIdFromVikingUri()` helper functions remain exported — they're still used by `search.ts` for backward-compatible session URI matching.
