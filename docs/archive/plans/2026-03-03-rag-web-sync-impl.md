# RAG + Web + Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add semantic search (RAG), a cross-device Web UI, and bidirectional peer sync to Engram — all unified through a single Hono web server.

**Architecture:** Each Engram instance runs a Hono HTTP server on port 3457. The server exposes JSON API endpoints consumed by: (1) HTMX-powered browser UI for phones/iPads/desktops, (2) peer nodes for pull-based sync, and (3) a semantic search endpoint backed by sqlite-vec embeddings. The existing MCP server (`src/index.ts`) and daemon (`src/daemon.ts`) are untouched; the web server is a new entry point (`src/web.ts`) that shares the same Database instance.

**Tech Stack:** Hono (HTTP), sqlite-vec (vectors), HTMX + Pico CSS (frontend), Ollama/OpenAI (embeddings), vitest (tests)

**Design doc:** `docs/plans/2026-03-03-rag-web-sync-design.md`

---

## Phase 1: Web Server + JSON API

### Task 1: Install dependencies and create web server entry point

**Files:**
- Modify: `package.json` (add hono, sqlite-vec, marked)
- Create: `src/web.ts`
- Create: `tests/web/server.test.ts`

**Step 1: Install dependencies**

Run:
```bash
npm install hono @anthropic-ai/sdk sqlite-vec marked
npm install -D @types/marked
```

Note: `hono` is listed as "already a dependency" in the design doc but is NOT currently in package.json. `sqlite-vec` provides prebuilt binaries for macOS ARM64.

**Step 2: Write the failing test**

Create `tests/web/server.test.ts`:

```typescript
// tests/web/server.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { createApp } from '../../src/web.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('Web Server', () => {
  let db: Database
  let tmpDir: string
  let app: ReturnType<typeof createApp>

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-web-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    app = createApp(db)
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('GET /api/sync/status returns node info', async () => {
    const res = await app.request('/api/sync/status')
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toHaveProperty('sessionCount')
    expect(body).toHaveProperty('nodeName')
  })
})
```

**Step 3: Run test to verify it fails**

Run: `npx vitest run tests/web/server.test.ts`
Expected: FAIL — cannot resolve `../../src/web.js`

**Step 4: Write minimal implementation**

Create `src/web.ts`:

```typescript
// src/web.ts
import { Hono } from 'hono'
import { serve } from 'hono/node-server'
import { join } from 'path'
import { Database } from './core/db.js'
import { ensureDataDirs } from './core/bootstrap.js'
import { readFileSettings } from './core/config.js'

export function createApp(db: Database) {
  const app = new Hono()

  // --- Sync endpoints ---
  app.get('/api/sync/status', (c) => {
    const settings = readFileSettings()
    return c.json({
      nodeName: settings.syncNodeName ?? 'unnamed',
      sessionCount: db.countSessions(),
      timestamp: new Date().toISOString(),
    })
  })

  return app
}

// CLI entry point — only runs when executed directly
const isMain = process.argv[1]?.endsWith('web.js') || process.argv[1]?.endsWith('web.ts')
if (isMain) {
  const DB_DIR = ensureDataDirs()
  const db = new Database(join(DB_DIR, 'index.sqlite'))
  const settings = readFileSettings()
  const port = settings.httpPort ?? 3457
  const app = createApp(db)

  serve({ fetch: app.fetch, port }, (info) => {
    process.stderr.write(`[engram-web] Listening on http://0.0.0.0:${info.port}\n`)
  })
}
```

**Step 5: Run test to verify it passes**

Run: `npx vitest run tests/web/server.test.ts`
Expected: PASS

**Step 6: Commit**

```bash
git add src/web.ts tests/web/server.test.ts package.json package-lock.json
git commit -m "feat(web): add Hono web server entry point with /api/sync/status"
```

---

### Task 2: JSON API — session list and detail endpoints

**Files:**
- Modify: `src/web.ts`
- Modify: `tests/web/server.test.ts`

**Step 1: Write the failing tests**

Add to `tests/web/server.test.ts`:

```typescript
import type { SessionInfo } from '../../src/adapters/types.js'

// Add inside describe block, after the existing test:

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
  summary: 'Fix login bug',
  filePath: '/Users/test/.codex/sessions/rollout-123.jsonl',
  sizeBytes: 50000,
}

it('GET /api/sessions returns session list', async () => {
  db.upsertSession(mockSession)
  db.upsertSession({ ...mockSession, id: 'session-002', source: 'claude-code' })

  const res = await app.request('/api/sessions')
  expect(res.status).toBe(200)
  const body = await res.json()
  expect(body.sessions).toHaveLength(2)
  expect(body.sessions[0]).toHaveProperty('id')
  expect(body.sessions[0]).toHaveProperty('source')
})

it('GET /api/sessions supports source filter', async () => {
  db.upsertSession(mockSession)
  db.upsertSession({ ...mockSession, id: 'session-002', source: 'claude-code' })

  const res = await app.request('/api/sessions?source=codex')
  const body = await res.json()
  expect(body.sessions).toHaveLength(1)
  expect(body.sessions[0].source).toBe('codex')
})

it('GET /api/sessions supports pagination', async () => {
  db.upsertSession(mockSession)
  db.upsertSession({ ...mockSession, id: 'session-002', startTime: '2026-01-02T10:00:00Z' })

  const res = await app.request('/api/sessions?limit=1&offset=1')
  const body = await res.json()
  expect(body.sessions).toHaveLength(1)
})

it('GET /api/sessions/:id returns single session', async () => {
  db.upsertSession(mockSession)

  const res = await app.request('/api/sessions/session-001')
  expect(res.status).toBe(200)
  const body = await res.json()
  expect(body.id).toBe('session-001')
  expect(body.source).toBe('codex')
})

it('GET /api/sessions/:id returns 404 for missing session', async () => {
  const res = await app.request('/api/sessions/nonexistent')
  expect(res.status).toBe(404)
})
```

**Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/web/server.test.ts`
Expected: FAIL — routes not defined

**Step 3: Implement the endpoints**

Add to `createApp` in `src/web.ts`, after the sync/status route:

```typescript
// --- API endpoints ---
app.get('/api/sessions', (c) => {
  const source = c.req.query('source') as SourceName | undefined
  const project = c.req.query('project')
  const since = c.req.query('since')
  const until = c.req.query('until')
  const limit = Math.min(parseInt(c.req.query('limit') ?? '20'), 100)
  const offset = parseInt(c.req.query('offset') ?? '0')

  const sessions = db.listSessions({ source, project, since, until, limit, offset })
  return c.json({ sessions, total: sessions.length })
})

app.get('/api/sessions/:id', (c) => {
  const session = db.getSession(c.req.param('id'))
  if (!session) return c.json({ error: 'Session not found' }, 404)
  return c.json(session)
})
```

Add the import at the top of `src/web.ts`:
```typescript
import type { SourceName } from './adapters/types.js'
```

**Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/web/server.test.ts`
Expected: PASS (all tests)

**Step 5: Commit**

```bash
git add src/web.ts tests/web/server.test.ts
git commit -m "feat(web): add /api/sessions list and detail endpoints"
```

---

### Task 3: JSON API — search and stats endpoints

**Files:**
- Modify: `src/web.ts`
- Modify: `tests/web/server.test.ts`

**Step 1: Write the failing tests**

Add to `tests/web/server.test.ts`:

```typescript
it('GET /api/search returns FTS5 results', async () => {
  db.upsertSession(mockSession)
  db.indexSessionContent('session-001', [
    { role: 'user', content: 'Fix the SSL certificate error in nginx config' },
  ])

  const res = await app.request('/api/search?q=SSL')
  expect(res.status).toBe(200)
  const body = await res.json()
  expect(body.results.length).toBeGreaterThan(0)
  expect(body.results[0].session.id).toBe('session-001')
})

it('GET /api/search returns warning for short query', async () => {
  const res = await app.request('/api/search?q=ab')
  const body = await res.json()
  expect(body.warning).toBeTruthy()
})

it('GET /api/stats returns grouped statistics', async () => {
  db.upsertSession(mockSession)
  db.upsertSession({ ...mockSession, id: 'session-002', source: 'claude-code' })

  const res = await app.request('/api/stats')
  expect(res.status).toBe(200)
  const body = await res.json()
  expect(body.groups.length).toBeGreaterThan(0)
  expect(body.totalSessions).toBe(2)
})
```

**Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/web/server.test.ts`
Expected: FAIL

**Step 3: Implement**

Add to `createApp` in `src/web.ts`:

```typescript
app.get('/api/search', async (c) => {
  const query = c.req.query('q') ?? ''
  const source = c.req.query('source') as SourceName | undefined
  const project = c.req.query('project')
  const since = c.req.query('since')
  const limit = parseInt(c.req.query('limit') ?? '10')

  const result = await handleSearch(db, { query, source, project, since, limit })
  return c.json(result)
})

app.get('/api/stats', async (c) => {
  const since = c.req.query('since')
  const until = c.req.query('until')
  const group_by = c.req.query('group_by')

  const result = await handleStats(db, { since, until, group_by })
  return c.json(result)
})
```

Add imports:
```typescript
import { handleSearch } from './tools/search.js'
import { handleStats } from './tools/stats.js'
```

**Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/web/server.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add src/web.ts tests/web/server.test.ts
git commit -m "feat(web): add /api/search and /api/stats endpoints"
```

---

### Task 4: Sync endpoints — sessions since timestamp and messages

**Files:**
- Modify: `src/core/db.ts` (add `listSessionsSince` method)
- Modify: `src/web.ts`
- Modify: `tests/web/server.test.ts`
- Modify: `tests/core/db.test.ts`

**Step 1: Write failing DB test**

Add to `tests/core/db.test.ts`:

```typescript
it('listSessionsSince returns sessions indexed after a given time', () => {
  db.upsertSession(mockSession)
  // Session indexed_at is set to datetime('now') by DB default

  // Query for sessions since yesterday — should find our session
  const yesterday = new Date(Date.now() - 86400000).toISOString()
  const results = db.listSessionsSince(yesterday, 100)
  expect(results).toHaveLength(1)
  expect(results[0].id).toBe('session-001')

  // Query for sessions since tomorrow — should find nothing
  const tomorrow = new Date(Date.now() + 86400000).toISOString()
  const resultsEmpty = db.listSessionsSince(tomorrow, 100)
  expect(resultsEmpty).toHaveLength(0)
})
```

**Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/db.test.ts`
Expected: FAIL — `listSessionsSince` is not a function

**Step 3: Add `listSessionsSince` to Database**

Add to `src/core/db.ts` class, after `listSessions`:

```typescript
listSessionsSince(since: string, limit = 100): SessionInfo[] {
  const rows = this.db.prepare(`
    SELECT * FROM sessions
    WHERE indexed_at > @since AND hidden_at IS NULL
    ORDER BY indexed_at ASC
    LIMIT @limit
  `).all({ since, limit }) as Record<string, unknown>[]
  return rows.map(r => this.rowToSession(r))
}
```

**Step 4: Run DB test**

Run: `npx vitest run tests/core/db.test.ts`
Expected: PASS

**Step 5: Write failing web test for sync endpoints**

Add to `tests/web/server.test.ts`:

```typescript
it('GET /api/sync/sessions returns sessions since timestamp', async () => {
  db.upsertSession(mockSession)

  const yesterday = new Date(Date.now() - 86400000).toISOString()
  const res = await app.request(`/api/sync/sessions?since=${yesterday}`)
  expect(res.status).toBe(200)
  const body = await res.json()
  expect(body.sessions).toHaveLength(1)
})

it('GET /api/sync/sessions requires since parameter', async () => {
  const res = await app.request('/api/sync/sessions')
  expect(res.status).toBe(400)
})
```

**Step 6: Run web test to verify failure**

Run: `npx vitest run tests/web/server.test.ts`
Expected: FAIL

**Step 7: Implement sync endpoints**

Add to `createApp` in `src/web.ts`:

```typescript
app.get('/api/sync/sessions', (c) => {
  const since = c.req.query('since')
  if (!since) return c.json({ error: 'since parameter required' }, 400)
  const limit = parseInt(c.req.query('limit') ?? '100')
  const sessions = db.listSessionsSince(since, limit)
  return c.json({ sessions })
})
```

**Step 8: Run all tests**

Run: `npx vitest run tests/web/ tests/core/db.test.ts`
Expected: PASS

**Step 9: Commit**

```bash
git add src/core/db.ts src/web.ts tests/web/server.test.ts tests/core/db.test.ts
git commit -m "feat(web): add sync endpoints — /api/sync/sessions with since filter"
```

---

### Task 5: HTML pages with HTMX + Pico CSS

**Files:**
- Create: `src/web/views.ts` (HTML template functions)
- Modify: `src/web.ts` (add HTML routes)
- Create: `tests/web/views.test.ts`

**Step 1: Write failing test**

Create `tests/web/views.test.ts`:

```typescript
// tests/web/views.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { createApp } from '../../src/web.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('Web Views', () => {
  let db: Database
  let tmpDir: string
  let app: ReturnType<typeof createApp>

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-views-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    app = createApp(db)
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('GET / returns HTML with HTMX', async () => {
    const res = await app.request('/')
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toContain('text/html')
    const html = await res.text()
    expect(html).toContain('htmx')
    expect(html).toContain('pico')
    expect(html).toContain('Engram')
  })

  it('GET /search returns HTML search page', async () => {
    const res = await app.request('/search')
    expect(res.status).toBe(200)
    const html = await res.text()
    expect(html).toContain('search')
  })
})
```

**Step 2: Run test to verify it fails**

Run: `npx vitest run tests/web/views.test.ts`
Expected: FAIL

**Step 3: Create views module**

Create `src/web/views.ts`:

```typescript
// src/web/views.ts
import type { SessionInfo } from '../adapters/types.js'

// HTMX and Pico CSS loaded from CDN — zero build step
const CDN_PICO = 'https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css'
const CDN_HTMX = 'https://unpkg.com/htmx.org@2.0.4'

export function layout(title: string, body: string): string {
  return `<!DOCTYPE html>
<html lang="zh" data-theme="auto">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title} — Engram</title>
  <link rel="stylesheet" href="${CDN_PICO}">
  <script src="${CDN_HTMX}"></script>
  <style>
    :root { --pico-font-size: 16px; }
    nav a.active { font-weight: bold; }
    .session-card { margin-bottom: 1rem; }
    .badge { display: inline-block; padding: 0.1em 0.5em; border-radius: 4px; font-size: 0.8em; background: var(--pico-secondary-background); }
    .snippet { font-size: 0.9em; color: var(--pico-muted-color); }
    pre { white-space: pre-wrap; word-break: break-word; }
  </style>
</head>
<body>
  <header class="container">
    <nav>
      <ul>
        <li><strong><a href="/">Engram</a></strong></li>
      </ul>
      <ul>
        <li><a href="/">Sessions</a></li>
        <li><a href="/search">Search</a></li>
        <li><a href="/stats">Stats</a></li>
        <li><a href="/settings">Settings</a></li>
      </ul>
    </nav>
  </header>
  <main class="container">
    ${body}
  </main>
</body>
</html>`
}

export function sessionListPage(sessions: SessionInfo[]): string {
  const rows = sessions.map(s => `
    <article class="session-card">
      <header>
        <a href="/session/${s.id}"><strong>${escapeHtml(s.summary ?? s.id)}</strong></a>
        <span class="badge">${s.source}</span>
      </header>
      <footer>
        <small>${s.project ?? ''} · ${s.startTime} · ${s.messageCount} msgs</small>
      </footer>
    </article>
  `).join('\n')

  return layout('Sessions', `
    <hgroup>
      <h2>Sessions</h2>
      <p>${sessions.length} sessions</p>
    </hgroup>
    <div>
      <input type="search"
        name="q" placeholder="Filter sessions..."
        hx-get="/api/search" hx-trigger="keyup changed delay:300ms"
        hx-target="#session-results">
    </div>
    <div id="session-results">
      ${rows}
    </div>
  `)
}

export function searchPage(): string {
  return layout('Search', `
    <h2>Search</h2>
    <input type="search" name="q" placeholder="Search sessions..."
      hx-get="/partials/search-results" hx-trigger="keyup changed delay:300ms"
      hx-target="#search-results">
    <div id="search-results"></div>
  `)
}

export function statsPage(groups: { key: string; sessionCount: number; messageCount: number }[], totalSessions: number): string {
  const rows = groups.map(g => `
    <tr><td>${escapeHtml(g.key)}</td><td>${g.sessionCount}</td><td>${g.messageCount}</td></tr>
  `).join('\n')

  return layout('Stats', `
    <h2>Stats</h2>
    <p>Total sessions: ${totalSessions}</p>
    <table>
      <thead><tr><th>Source</th><th>Sessions</th><th>Messages</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
  `)
}

export function settingsPage(syncConfig: { nodeName: string; peers: { name: string; url: string }[] }): string {
  const peerRows = syncConfig.peers.map(p => `
    <tr><td>${escapeHtml(p.name)}</td><td>${escapeHtml(p.url)}</td><td><button hx-post="/api/sync/trigger?peer=${encodeURIComponent(p.name)}" hx-swap="innerHTML" hx-target="closest td">Sync Now</button></td></tr>
  `).join('\n')

  return layout('Settings', `
    <h2>Settings</h2>
    <h3>Sync</h3>
    <p>Node name: <strong>${escapeHtml(syncConfig.nodeName)}</strong></p>
    <table>
      <thead><tr><th>Peer</th><th>URL</th><th>Action</th></tr></thead>
      <tbody>${peerRows}</tbody>
    </table>
  `)
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}
```

**Step 4: Add HTML routes to web.ts**

Add to `createApp` in `src/web.ts`:

```typescript
import { layout, sessionListPage, searchPage, statsPage, settingsPage } from './web/views.js'

// --- HTML routes ---
app.get('/', (c) => {
  const sessions = db.listSessions({ limit: 50 })
  return c.html(sessionListPage(sessions))
})

app.get('/search', (c) => {
  return c.html(searchPage())
})

app.get('/stats', async (c) => {
  const result = await handleStats(db, {})
  return c.html(statsPage(result.groups, result.totalSessions))
})

app.get('/settings', (c) => {
  const settings = readFileSettings()
  return c.html(settingsPage({
    nodeName: settings.syncNodeName ?? 'unnamed',
    peers: settings.syncPeers ?? [],
  }))
})
```

**Step 5: Run tests**

Run: `npx vitest run tests/web/`
Expected: PASS

**Step 6: Commit**

```bash
git add src/web.ts src/web/views.ts tests/web/views.test.ts
git commit -m "feat(web): add HTML pages with HTMX + Pico CSS"
```

---

### Task 6: Session detail HTML page with message rendering

**Files:**
- Modify: `src/web/views.ts` (add `sessionDetailPage`)
- Modify: `src/web.ts` (add `/session/:id` HTML route)
- Modify: `tests/web/views.test.ts`

**Step 1: Write failing test**

Add to `tests/web/views.test.ts`:

```typescript
it('GET /session/:id returns HTML session detail', async () => {
  db.upsertSession({
    id: 'sess-1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
    cwd: '/p', project: 'proj', messageCount: 5, userMessageCount: 2,
    summary: 'Test session', filePath: '/f1', sizeBytes: 100,
  })

  const res = await app.request('/session/sess-1')
  expect(res.status).toBe(200)
  const html = await res.text()
  expect(html).toContain('Test session')
  expect(html).toContain('codex')
})

it('GET /session/:id returns 404 HTML for missing session', async () => {
  const res = await app.request('/session/nonexistent')
  expect(res.status).toBe(404)
})
```

**Step 2: Run tests to verify failure**

Run: `npx vitest run tests/web/views.test.ts`
Expected: FAIL

**Step 3: Implement session detail page**

Add to `src/web/views.ts`:

```typescript
export function sessionDetailPage(session: SessionInfo, messages: { role: string; content: string }[]): string {
  const msgHtml = messages.map(m => `
    <article>
      <header><strong>${m.role === 'user' ? 'User' : 'Assistant'}</strong></header>
      <pre>${escapeHtml(m.content)}</pre>
    </article>
  `).join('\n')

  return layout(session.summary ?? session.id, `
    <hgroup>
      <h2>${escapeHtml(session.summary ?? session.id)}</h2>
      <p><span class="badge">${session.source}</span> · ${session.project ?? ''} · ${session.startTime} · ${session.messageCount} msgs</p>
    </hgroup>
    <a href="/">&larr; Back to sessions</a>
    <hr>
    ${msgHtml}
  `)
}
```

Add HTML route to `src/web.ts`:

```typescript
app.get('/session/:id', async (c) => {
  const session = db.getSession(c.req.param('id'))
  if (!session) return c.html(layout('Not Found', '<h2>Session not found</h2>'), 404)

  // Load messages from adapter if available, otherwise show metadata only
  const adapter = getAdapter(session.source)
  const messages: { role: string; content: string }[] = []
  if (adapter) {
    for await (const msg of adapter.streamMessages(session.filePath)) {
      messages.push({ role: msg.role, content: msg.content })
    }
  }
  return c.html(sessionDetailPage(session, messages))
})
```

Add import: `import { getAdapter } from './core/bootstrap.js'`

Note: In test environment, `getAdapter` will return undefined (no real session files), so the detail page will render with metadata only. This is fine — the test verifies the route works and renders the session info.

**Step 4: Run tests**

Run: `npx vitest run tests/web/`
Expected: PASS

**Step 5: Commit**

```bash
git add src/web.ts src/web/views.ts tests/web/views.test.ts
git commit -m "feat(web): add session detail page with message rendering"
```

---

### Task 7: Add web server to daemon and build config

**Files:**
- Modify: `src/daemon.ts` (start web server alongside daemon)
- Modify: `src/core/config.ts` (add sync config types)
- Modify: `tsconfig.json` (if needed for new directory)

**Step 1: Extend config types**

Add to `src/core/config.ts` `FileSettings` interface:

```typescript
export interface SyncPeer {
  name: string
  url: string
}

export interface FileSettings {
  // ... existing fields ...
  syncNodeName?: string
  syncPeers?: SyncPeer[]
  syncIntervalMinutes?: number
  syncEnabled?: boolean
}
```

**Step 2: Start web server in daemon**

Add to `src/daemon.ts` after the watcher setup:

```typescript
import { createApp } from './web.js'
import { serve } from 'hono/node-server'
import { readFileSettings } from './core/config.js'

// Start web server
const settings = readFileSettings()
const port = settings.httpPort ?? 3457
const app = createApp(db)
const webServer = serve({ fetch: app.fetch, port }, (info) => {
  emit({ event: 'web_ready', port: info.port })
})
```

Update the `onExit` cleanup:

```typescript
setupProcessLifecycle({
  idleTimeoutMs: 0,
  onExit: () => {
    clearInterval(rescanTimer)
    watcher?.close()
    webServer.close()
  },
})
```

**Step 3: Build and verify**

Run: `npm run build`
Expected: No errors

**Step 4: Commit**

```bash
git add src/daemon.ts src/core/config.ts
git commit -m "feat(web): integrate web server into daemon process"
```

---

## Phase 2: RAG / Semantic Search

### Task 8: VectorStore interface and sqlite-vec implementation

**Files:**
- Create: `src/core/vector-store.ts` (interface + sqlite-vec impl)
- Create: `tests/core/vector-store.test.ts`

**Step 1: Write failing test**

Create `tests/core/vector-store.test.ts`:

```typescript
// tests/core/vector-store.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { SqliteVecStore } from '../../src/core/vector-store.js'
import BetterSqlite3 from 'better-sqlite3'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('SqliteVecStore', () => {
  let rawDb: BetterSqlite3.Database
  let store: SqliteVecStore
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'vec-test-'))
    rawDb = new BetterSqlite3(join(tmpDir, 'test.sqlite'))
    store = new SqliteVecStore(rawDb)
  })

  afterEach(() => {
    rawDb.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('stores and retrieves vectors by KNN', () => {
    // 768-dim vectors
    const vec1 = new Float32Array(768).fill(0.1)
    const vec2 = new Float32Array(768).fill(0.9)

    store.upsert('session-1', vec1)
    store.upsert('session-2', vec2)

    // Query close to vec2
    const query = new Float32Array(768).fill(0.85)
    const results = store.search(query, 2)

    expect(results).toHaveLength(2)
    expect(results[0].sessionId).toBe('session-2') // closest
  })

  it('deletes a vector', () => {
    const vec = new Float32Array(768).fill(0.5)
    store.upsert('session-1', vec)
    store.delete('session-1')

    const results = store.search(vec, 10)
    expect(results).toHaveLength(0)
  })

  it('upsert overwrites existing vector', () => {
    const vec1 = new Float32Array(768).fill(0.1)
    const vec2 = new Float32Array(768).fill(0.9)

    store.upsert('session-1', vec1)
    store.upsert('session-1', vec2) // overwrite

    const query = new Float32Array(768).fill(0.85)
    const results = store.search(query, 1)
    expect(results[0].sessionId).toBe('session-1')
  })
})
```

**Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/vector-store.test.ts`
Expected: FAIL — cannot resolve module

**Step 3: Implement VectorStore**

Create `src/core/vector-store.ts`:

```typescript
// src/core/vector-store.ts
import type BetterSqlite3 from 'better-sqlite3'
import * as sqliteVec from 'sqlite-vec'

export interface VectorSearchResult {
  sessionId: string
  distance: number
}

export interface VectorStore {
  upsert(sessionId: string, embedding: Float32Array): void
  search(query: Float32Array, topK: number): VectorSearchResult[]
  delete(sessionId: string): void
  count(): number
}

export class SqliteVecStore implements VectorStore {
  constructor(private db: BetterSqlite3.Database) {
    sqliteVec.load(db)
    this.migrate()
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS session_embeddings (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS vec_sessions USING vec0(
        session_id TEXT PRIMARY KEY,
        embedding float[768]
      );
    `)
  }

  upsert(sessionId: string, embedding: Float32Array, model = 'unknown'): void {
    const buf = Buffer.from(embedding.buffer, embedding.byteOffset, embedding.byteLength)

    const transaction = this.db.transaction(() => {
      // Delete old entry if exists
      this.db.prepare('DELETE FROM vec_sessions WHERE session_id = ?').run(sessionId)
      this.db.prepare('DELETE FROM session_embeddings WHERE session_id = ?').run(sessionId)

      // Insert new
      this.db.prepare('INSERT INTO vec_sessions (session_id, embedding) VALUES (?, ?)').run(sessionId, buf)
      this.db.prepare('INSERT INTO session_embeddings (session_id, model) VALUES (?, ?)').run(sessionId, model)
    })
    transaction()
  }

  search(query: Float32Array, topK: number): VectorSearchResult[] {
    const buf = Buffer.from(query.buffer, query.byteOffset, query.byteLength)
    const rows = this.db.prepare(`
      SELECT session_id, distance
      FROM vec_sessions
      WHERE embedding MATCH ? AND k = ?
      ORDER BY distance
    `).all(buf, topK) as { session_id: string; distance: number }[]

    return rows.map(r => ({ sessionId: r.session_id, distance: r.distance }))
  }

  delete(sessionId: string): void {
    this.db.prepare('DELETE FROM vec_sessions WHERE session_id = ?').run(sessionId)
    this.db.prepare('DELETE FROM session_embeddings WHERE session_id = ?').run(sessionId)
  }

  count(): number {
    const row = this.db.prepare('SELECT COUNT(*) as n FROM session_embeddings').get() as { n: number }
    return row.n
  }
}
```

**Step 4: Run test**

Run: `npx vitest run tests/core/vector-store.test.ts`
Expected: PASS

Note: If `sqlite-vec` fails to load (native extension issue), the test will fail with a load error. In that case, check `npm ls sqlite-vec` and verify the prebuilt binary exists for darwin-arm64.

**Step 5: Commit**

```bash
git add src/core/vector-store.ts tests/core/vector-store.test.ts
git commit -m "feat(rag): add VectorStore interface and SqliteVecStore implementation"
```

---

### Task 9: Embedding client — Ollama + OpenAI fallback

**Files:**
- Create: `src/core/embeddings.ts`
- Create: `tests/core/embeddings.test.ts`

**Step 1: Write failing test**

Create `tests/core/embeddings.test.ts`:

```typescript
// tests/core/embeddings.test.ts
import { describe, it, expect, vi } from 'vitest'
import { createEmbeddingClient, EmbeddingClient } from '../../src/core/embeddings.js'

describe('EmbeddingClient', () => {
  it('returns null when no provider is available', async () => {
    const client = createEmbeddingClient({ ollamaUrl: 'http://localhost:99999', openaiApiKey: undefined })
    // Both providers unavailable — embed should return null
    const result = await client.embed('test text')
    expect(result).toBeNull()
  })

  it('returns a Float32Array of the correct dimension when mocked', async () => {
    const mockClient: EmbeddingClient = {
      embed: async (_text: string) => new Float32Array(768).fill(0.1),
      dimension: 768,
      model: 'mock',
    }
    const result = await mockClient.embed('hello world')
    expect(result).toBeInstanceOf(Float32Array)
    expect(result!.length).toBe(768)
  })
})
```

**Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/embeddings.test.ts`
Expected: FAIL

**Step 3: Implement**

Create `src/core/embeddings.ts`:

```typescript
// src/core/embeddings.ts
import OpenAI from 'openai'

export interface EmbeddingClient {
  embed(text: string): Promise<Float32Array | null>
  dimension: number
  model: string
}

interface EmbeddingClientOptions {
  ollamaUrl?: string
  openaiApiKey?: string
}

export function createEmbeddingClient(opts: EmbeddingClientOptions): EmbeddingClient {
  // Try Ollama first
  const ollamaUrl = opts.ollamaUrl ?? 'http://localhost:11434'

  return {
    dimension: 768,
    model: 'auto',

    async embed(text: string): Promise<Float32Array | null> {
      // Try Ollama
      try {
        const res = await fetch(`${ollamaUrl}/api/embed`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ model: 'nomic-embed-text', input: text }),
          signal: AbortSignal.timeout(10000),
        })
        if (res.ok) {
          const data = await res.json() as { embeddings: number[][] }
          if (data.embeddings?.[0]) {
            return new Float32Array(data.embeddings[0])
          }
        }
      } catch { /* Ollama not available */ }

      // Fallback to OpenAI
      if (opts.openaiApiKey) {
        try {
          const client = new OpenAI({ apiKey: opts.openaiApiKey })
          const res = await client.embeddings.create({
            model: 'text-embedding-3-small',
            input: text,
            dimensions: 768,
          })
          if (res.data[0]) {
            return new Float32Array(res.data[0].embedding)
          }
        } catch { /* OpenAI not available */ }
      }

      return null
    },
  }
}
```

**Step 4: Run test**

Run: `npx vitest run tests/core/embeddings.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add src/core/embeddings.ts tests/core/embeddings.test.ts
git commit -m "feat(rag): add embedding client with Ollama + OpenAI fallback"
```

---

### Task 10: Background embedding indexer

**Files:**
- Create: `src/core/embedding-indexer.ts`
- Create: `tests/core/embedding-indexer.test.ts`

**Step 1: Write failing test**

Create `tests/core/embedding-indexer.test.ts`:

```typescript
// tests/core/embedding-indexer.test.ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { EmbeddingIndexer } from '../../src/core/embedding-indexer.js'
import type { VectorStore } from '../../src/core/vector-store.js'
import type { EmbeddingClient } from '../../src/core/embeddings.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('EmbeddingIndexer', () => {
  let db: Database
  let tmpDir: string
  let mockStore: VectorStore
  let mockClient: EmbeddingClient
  let indexer: EmbeddingIndexer

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'embed-idx-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    mockStore = {
      upsert: vi.fn(),
      search: vi.fn().mockReturnValue([]),
      delete: vi.fn(),
      count: vi.fn().mockReturnValue(0),
    }

    mockClient = {
      embed: vi.fn().mockResolvedValue(new Float32Array(768).fill(0.1)),
      dimension: 768,
      model: 'mock',
    }

    indexer = new EmbeddingIndexer(db, mockStore, mockClient)
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('indexes a session that has FTS content', async () => {
    db.upsertSession({
      id: 's1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', messageCount: 5, userMessageCount: 2,
      filePath: '/f1', sizeBytes: 100,
    })
    db.indexSessionContent('s1', [
      { role: 'user', content: 'Help me fix the login bug' },
    ])

    const count = await indexer.indexAll()
    expect(count).toBe(1)
    expect(mockClient.embed).toHaveBeenCalledOnce()
    expect(mockStore.upsert).toHaveBeenCalledOnce()
  })

  it('skips sessions that already have embeddings', async () => {
    db.upsertSession({
      id: 's1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', messageCount: 5, userMessageCount: 2,
      filePath: '/f1', sizeBytes: 100,
    })
    db.indexSessionContent('s1', [
      { role: 'user', content: 'Hello world testing' },
    ])

    // First index
    await indexer.indexAll()
    // Mock store now reports 1 entry
    ;(mockStore.count as ReturnType<typeof vi.fn>).mockReturnValue(1)

    // Reset call counts
    ;(mockClient.embed as ReturnType<typeof vi.fn>).mockClear()
    ;(mockStore.upsert as ReturnType<typeof vi.fn>).mockClear()

    // Second index — should skip
    const count = await indexer.indexAll()
    expect(count).toBe(0)
  })
})
```

**Step 2: Run test to verify failure**

Run: `npx vitest run tests/core/embedding-indexer.test.ts`
Expected: FAIL

**Step 3: Implement**

Create `src/core/embedding-indexer.ts`:

```typescript
// src/core/embedding-indexer.ts
import type { Database } from './db.js'
import type { VectorStore } from './vector-store.js'
import type { EmbeddingClient } from './embeddings.js'

export class EmbeddingIndexer {
  private indexed = new Set<string>()

  constructor(
    private db: Database,
    private store: VectorStore,
    private client: EmbeddingClient
  ) {}

  /** Index all sessions that don't yet have embeddings. Returns count of newly indexed. */
  async indexAll(): Promise<number> {
    const sessions = this.db.listSessions({ limit: 10000 })
    let count = 0

    for (const session of sessions) {
      if (this.indexed.has(session.id)) continue

      const text = this.getSessionText(session.id)
      if (!text) {
        this.indexed.add(session.id) // no FTS content, skip permanently
        continue
      }

      const embedding = await this.client.embed(text)
      if (!embedding) continue // provider unavailable

      this.store.upsert(session.id, embedding, this.client.model)
      this.indexed.add(session.id)
      count++
    }

    return count
  }

  /** Index a single session by ID. */
  async indexOne(sessionId: string): Promise<boolean> {
    const text = this.getSessionText(sessionId)
    if (!text) return false

    const embedding = await this.client.embed(text)
    if (!embedding) return false

    this.store.upsert(sessionId, embedding, this.client.model)
    this.indexed.add(sessionId)
    return true
  }

  /** Get concatenated user message text from FTS index. */
  private getSessionText(sessionId: string): string | null {
    // Query FTS content for this session (first 2000 chars)
    const rows = this.db.getFtsContent(sessionId)
    if (!rows || rows.length === 0) return null

    const text = rows.join('\n').slice(0, 2000)
    return text.length > 0 ? text : null
  }
}
```

This requires adding `getFtsContent` to the Database class. Add to `src/core/db.ts`:

```typescript
getFtsContent(sessionId: string): string[] {
  const rows = this.db.prepare(
    'SELECT content FROM sessions_fts WHERE session_id = ?'
  ).all(sessionId) as { content: string }[]
  return rows.map(r => r.content)
}
```

**Step 4: Run tests**

Run: `npx vitest run tests/core/embedding-indexer.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add src/core/embedding-indexer.ts src/core/db.ts tests/core/embedding-indexer.test.ts
git commit -m "feat(rag): add background EmbeddingIndexer with batch and single-session support"
```

---

### Task 11: Enhanced get_context with semantic search

**Files:**
- Modify: `src/tools/get_context.ts`
- Modify: `tests/tools/get_context.test.ts`

**Step 1: Write failing test**

Add to `tests/tools/get_context.test.ts`:

```typescript
import type { VectorStore, VectorSearchResult } from '../../src/core/vector-store.js'

it('uses vector search when vectorStore is provided and task is given', async () => {
  // s3 is in a different project but semantically relevant
  db.upsertSession({ id: 's4', source: 'codex', startTime: '2026-01-22T10:00:00Z', cwd: '/Users/test/myapp', project: 'myapp', summary: '配置了 OAuth 认证流程', messageCount: 10, userMessageCount: 5, filePath: '/f4', sizeBytes: 50 })

  const mockVectorStore: VectorStore = {
    upsert: () => {},
    delete: () => {},
    count: () => 2,
    search: (_query: Float32Array, _topK: number): VectorSearchResult[] => [
      { sessionId: 's4', distance: 0.1 },  // most relevant
      { sessionId: 's1', distance: 0.3 },
    ],
  }

  const mockEmbed = async (_text: string) => new Float32Array(768).fill(0.1)

  const result = await handleGetContext(db, { cwd: '/Users/test/myapp', task: '修复认证问题' }, { vectorStore: mockVectorStore, embed: mockEmbed })
  // s4 should appear (vector search found it as most relevant)
  expect(result.sessions.some(s => s.id === 's4')).toBe(true)
})
```

**Step 2: Run test to verify failure**

Run: `npx vitest run tests/tools/get_context.test.ts`
Expected: FAIL — handleGetContext doesn't accept 3rd argument

**Step 3: Update get_context implementation**

Modify `src/tools/get_context.ts`:

```typescript
// src/tools/get_context.ts
import { basename } from 'path'
import type { Database } from '../core/db.js'
import type { VectorStore } from '../core/vector-store.js'
import { toLocalDate } from '../utils/time.js'

export const getContextTool = {
  name: 'get_context',
  description: '为当前工作目录自动提取相关的历史会话上下文。在开始新任务时调用，获取该项目的历史记录。',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: '当前工作目录（绝对路径）' },
      task: { type: 'string', description: '当前任务描述（可选，用于语义搜索）' },
      max_tokens: { type: 'number', description: 'token 预算，默认 4000（约 16000 字符）' },
    },
    additionalProperties: false,
  },
}

const CHARS_PER_TOKEN = 4

export interface GetContextDeps {
  vectorStore?: VectorStore
  embed?: (text: string) => Promise<Float32Array | null>
}

export async function handleGetContext(
  db: Database,
  params: { cwd: string; task?: string; max_tokens?: number },
  deps: GetContextDeps = {}
) {
  const maxTokens = params.max_tokens ?? 4000
  const maxChars = maxTokens * CHARS_PER_TOKEN

  // Step 1: project-based filtering (unchanged)
  const projectName = basename(params.cwd.replace(/\/$/, ''))
  let sessions = db.listSessions({ project: projectName, limit: 50 })
  if (sessions.length === 0 && params.cwd) {
    sessions = db.listSessions({ project: params.cwd, limit: 50 })
  }

  // Step 2: if task + vector store available, boost with semantic search
  if (params.task && deps.vectorStore && deps.embed) {
    try {
      const queryVec = await deps.embed(params.task)
      if (queryVec) {
        const vecResults = deps.vectorStore.search(queryVec, 10)
        const vecSessionIds = new Set(vecResults.map(r => r.sessionId))

        // Add vector-matched sessions that aren't already in the list
        const existingIds = new Set(sessions.map(s => s.id))
        for (const vr of vecResults) {
          if (!existingIds.has(vr.sessionId)) {
            const s = db.getSession(vr.sessionId)
            if (s && s.project === projectName) {
              sessions.push(s)
            }
          }
        }

        // Re-sort: vector-matched sessions first, then by time
        sessions.sort((a, b) => {
          const aVec = vecSessionIds.has(a.id) ? 0 : 1
          const bVec = vecSessionIds.has(b.id) ? 0 : 1
          if (aVec !== bVec) return aVec - bVec
          return b.startTime.localeCompare(a.startTime)
        })
      }
    } catch { /* vector search failed, fall through to FTS */ }
  }

  const contextParts: string[] = []
  let totalChars = 0
  const selectedSessions: typeof sessions = []

  if (params.task) {
    const taskLine = `当前任务：${params.task}\n`
    contextParts.push(taskLine)
    totalChars += taskLine.length
  }

  for (const session of sessions) {
    if (!session.summary) continue
    const line = `[${session.source}] ${toLocalDate(session.startTime)} — ${session.summary}\n`
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

**Step 4: Update index.ts to pass deps**

In `src/index.ts`, the `handleGetContext` call at line 77 needs to pass vector deps when available. For now, change to:

```typescript
} else if (name === 'get_context') {
  result = await handleGetContext(db, a as { cwd: string }, vectorDeps)
```

Where `vectorDeps` is initialized near the top of `index.ts` (after vector store is set up in a later task). For now, just pass `{}` — the existing behavior is preserved.

**Step 5: Run tests**

Run: `npx vitest run tests/tools/get_context.test.ts`
Expected: PASS (all existing tests still pass, new test passes)

**Step 6: Commit**

```bash
git add src/tools/get_context.ts tests/tools/get_context.test.ts
git commit -m "feat(rag): enhance get_context with optional semantic search"
```

---

### Task 12: Semantic search API endpoint

**Files:**
- Modify: `src/web.ts`
- Modify: `tests/web/server.test.ts`

**Step 1: Write failing test**

Add to `tests/web/server.test.ts`:

```typescript
it('GET /api/search/semantic returns 501 when vector store not configured', async () => {
  const res = await app.request('/api/search/semantic?q=test+query')
  expect(res.status).toBe(501)
  const body = await res.json()
  expect(body.error).toContain('not available')
})
```

**Step 2: Run test to verify failure**

Run: `npx vitest run tests/web/server.test.ts`
Expected: FAIL

**Step 3: Add semantic search endpoint**

Add to `createApp` in `src/web.ts`. The function signature needs an optional `vectorStore` and `embeddingClient` parameter:

```typescript
export function createApp(db: Database, opts?: { vectorStore?: VectorStore; embeddingClient?: EmbeddingClient }) {
  // ... existing code ...

  app.get('/api/search/semantic', async (c) => {
    const query = c.req.query('q') ?? ''
    const topK = parseInt(c.req.query('limit') ?? '10')

    if (!opts?.vectorStore || !opts?.embeddingClient) {
      return c.json({ error: 'Semantic search not available — no embedding provider configured' }, 501)
    }

    if (query.length < 2) {
      return c.json({ results: [], warning: 'Query too short' })
    }

    const embedding = await opts.embeddingClient.embed(query)
    if (!embedding) {
      return c.json({ error: 'Failed to generate embedding' }, 500)
    }

    const vecResults = opts.vectorStore.search(embedding, topK)
    const results = vecResults.map(vr => {
      const session = db.getSession(vr.sessionId)
      return { session, distance: vr.distance }
    }).filter(r => r.session !== null)

    return c.json({ results, query })
  })
}
```

**Step 4: Run tests**

Run: `npx vitest run tests/web/`
Expected: PASS

**Step 5: Commit**

```bash
git add src/web.ts tests/web/server.test.ts
git commit -m "feat(rag): add /api/search/semantic endpoint"
```

---

### Task 13: Wire up vector store and embedding indexer in daemon

**Files:**
- Modify: `src/daemon.ts`
- Modify: `src/index.ts`

**Step 1: Initialize vector store in daemon**

Add to `src/daemon.ts`, after db creation:

```typescript
import { SqliteVecStore } from './core/vector-store.js'
import { createEmbeddingClient } from './core/embeddings.js'
import { EmbeddingIndexer } from './core/embedding-indexer.js'

// Vector store — may fail if sqlite-vec extension can't load
let vectorStore: SqliteVecStore | undefined
let embeddingIndexer: EmbeddingIndexer | undefined
try {
  // sqlite-vec needs the raw db handle — access it via Database
  vectorStore = new SqliteVecStore(db.getRawDb())
  const embeddingClient = createEmbeddingClient({
    ollamaUrl: 'http://localhost:11434',
    openaiApiKey: settings.openaiApiKey,
  })
  embeddingIndexer = new EmbeddingIndexer(db, vectorStore, embeddingClient)
} catch (err) {
  emit({ event: 'warning', message: `Vector store unavailable: ${err}` })
}
```

This requires exposing the raw `better-sqlite3` handle from `Database`. Add to `src/core/db.ts`:

```typescript
getRawDb(): BetterSqlite3.Database {
  return this.db
}
```

Then update the web server creation to pass the vector store:

```typescript
const app = createApp(db, { vectorStore, embeddingClient })
```

And add a background embedding pass after initial indexing:

```typescript
// After indexer.indexAll() resolves:
indexer.indexAll().then(async (indexed) => {
  const total = db.countSessions()
  emit({ event: 'ready', indexed, total })

  // Background embedding generation
  if (embeddingIndexer) {
    const embedded = await embeddingIndexer.indexAll()
    if (embedded > 0) {
      emit({ event: 'embeddings_ready', embedded })
    }
  }
}).catch(err => {
  emit({ event: 'error', message: String(err) })
})
```

**Step 2: Do the same in index.ts (MCP server)**

In `src/index.ts`, similar setup — try to create vector store, pass to `handleGetContext`:

```typescript
import { SqliteVecStore } from './core/vector-store.js'
import { createEmbeddingClient } from './core/embeddings.js'
import { EmbeddingIndexer } from './core/embedding-indexer.js'
import type { GetContextDeps } from './tools/get_context.js'

let vectorDeps: GetContextDeps = {}
try {
  const vectorStore = new SqliteVecStore(db.getRawDb())
  const settings = readFileSettings()
  const embeddingClient = createEmbeddingClient({
    ollamaUrl: 'http://localhost:11434',
    openaiApiKey: settings.openaiApiKey,
  })
  vectorDeps = {
    vectorStore,
    embed: (text) => embeddingClient.embed(text),
  }

  // Background embedding generation after indexing
  const embeddingIndexer = new EmbeddingIndexer(db, vectorStore, embeddingClient)
  indexer.indexAll().then(async () => {
    await embeddingIndexer.indexAll()
  })
} catch {
  // sqlite-vec unavailable — get_context falls back to FTS5 only
}
```

**Step 3: Build and verify**

Run: `npm run build`
Expected: No errors

**Step 4: Commit**

```bash
git add src/daemon.ts src/index.ts src/core/db.ts
git commit -m "feat(rag): wire up vector store and embedding indexer in daemon and MCP server"
```

---

## Phase 3: Bidirectional Sync

### Task 14: Sync engine — pull sessions from peer

**Files:**
- Create: `src/core/sync.ts`
- Create: `tests/core/sync.test.ts`

**Step 1: Write failing test**

Create `tests/core/sync.test.ts`:

```typescript
// tests/core/sync.test.ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { SyncEngine } from '../../src/core/sync.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('SyncEngine', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'sync-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('pulls new sessions from a peer', async () => {
    // Mock fetch to simulate peer API
    const mockSessions = [
      { id: 'remote-1', source: 'codex', startTime: '2026-01-01T10:00:00Z', cwd: '/p', project: 'proj', messageCount: 5, userMessageCount: 2, summary: 'Remote session', filePath: '/remote/f1', sizeBytes: 100 },
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessionCount: 1, nodeName: 'mac-mini', timestamp: new Date().toISOString() }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessions: mockSessions }) })

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://192.0.2.10:3457' })

    expect(result.pulled).toBe(1)
    expect(db.getSession('remote-1')).not.toBeNull()
    expect(db.getSession('remote-1')!.source).toBe('codex')
  })

  it('skips sessions that already exist locally', async () => {
    // Pre-insert a session
    db.upsertSession({
      id: 'remote-1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', messageCount: 5, userMessageCount: 2,
      filePath: '/f1', sizeBytes: 100,
    })

    const mockSessions = [
      { id: 'remote-1', source: 'codex', startTime: '2026-01-01T10:00:00Z', cwd: '/p', messageCount: 5, userMessageCount: 2, summary: 'Already here', filePath: '/f1', sizeBytes: 100 },
    ]

    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessionCount: 1, nodeName: 'mac-mini', timestamp: new Date().toISOString() }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessions: mockSessions }) })

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://192.0.2.10:3457' })

    expect(result.pulled).toBe(0)
    expect(result.skipped).toBe(1)
  })

  it('handles unreachable peer gracefully', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('Network error'))

    const engine = new SyncEngine(db, mockFetch as unknown as typeof fetch)
    const result = await engine.pullFromPeer({ name: 'mac-mini', url: 'http://192.0.2.10:3457' })

    expect(result.error).toBeTruthy()
    expect(result.pulled).toBe(0)
  })
})
```

**Step 2: Run test to verify failure**

Run: `npx vitest run tests/core/sync.test.ts`
Expected: FAIL

**Step 3: Implement SyncEngine**

Create `src/core/sync.ts`:

```typescript
// src/core/sync.ts
import type { Database } from './db.js'
import type { SessionInfo } from '../adapters/types.js'

export interface SyncPeer {
  name: string
  url: string
}

export interface SyncResult {
  peer: string
  pulled: number
  skipped: number
  error?: string
}

export class SyncEngine {
  private lastSyncTimes = new Map<string, string>()

  constructor(
    private db: Database,
    private fetchFn: typeof fetch = fetch
  ) {}

  async pullFromPeer(peer: SyncPeer): Promise<SyncResult> {
    const result: SyncResult = { peer: peer.name, pulled: 0, skipped: 0 }

    try {
      // Step 1: Check reachability
      const statusRes = await this.fetchFn(`${peer.url}/api/sync/status`, {
        signal: AbortSignal.timeout(5000),
      })
      if (!statusRes.ok) {
        result.error = `Peer returned ${statusRes.status}`
        return result
      }

      // Step 2: Pull sessions since last sync
      const since = this.lastSyncTimes.get(peer.name) ?? '1970-01-01T00:00:00Z'
      const sessionsRes = await this.fetchFn(
        `${peer.url}/api/sync/sessions?since=${encodeURIComponent(since)}`,
        { signal: AbortSignal.timeout(30000) }
      )
      if (!sessionsRes.ok) {
        result.error = `Failed to fetch sessions: ${sessionsRes.status}`
        return result
      }

      const { sessions } = await sessionsRes.json() as { sessions: SessionInfo[] }

      // Step 3: Insert new sessions
      for (const session of sessions) {
        const existing = this.db.getSession(session.id)
        if (existing) {
          result.skipped++
          continue
        }

        this.db.upsertSession({
          ...session,
          // Mark origin as the peer name
          filePath: `sync://${peer.name}/${session.filePath}`,
        })
        result.pulled++
      }

      // Step 4: Update last sync time
      this.lastSyncTimes.set(peer.name, new Date().toISOString())

    } catch (err) {
      result.error = String(err)
    }

    return result
  }

  async syncAllPeers(peers: SyncPeer[]): Promise<SyncResult[]> {
    const results: SyncResult[] = []
    for (const peer of peers) {
      results.push(await this.pullFromPeer(peer))
    }
    return results
  }
}
```

**Step 4: Run tests**

Run: `npx vitest run tests/core/sync.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add src/core/sync.ts tests/core/sync.test.ts
git commit -m "feat(sync): add SyncEngine with pull-based peer sync"
```

---

### Task 15: Add origin column to database

**Files:**
- Modify: `src/core/db.ts` (migration + column)
- Modify: `tests/core/db.test.ts`

**Step 1: Write failing test**

Add to `tests/core/db.test.ts`:

```typescript
it('preserves origin field on upsert', () => {
  db.upsertSession({ ...mockSession, origin: 'mac-mini' } as any)
  const result = db.getSession('session-001')
  // origin should be accessible (added to rowToSession)
  expect((result as any).origin).toBe('mac-mini')
})
```

**Step 2: Run test to verify failure**

Run: `npx vitest run tests/core/db.test.ts`
Expected: FAIL

**Step 3: Add origin column**

In `src/core/db.ts` `migrate()` method, add to the migration block:

```typescript
if (!colNames.has('origin')) this.db.exec("ALTER TABLE sessions ADD COLUMN origin TEXT DEFAULT 'local'")
```

In the CREATE TABLE statement, add: `origin TEXT DEFAULT 'local'`

In `upsertSession`, add `origin` to the INSERT and ON CONFLICT clauses.

In `rowToSession`, add: `origin: row.origin as string | undefined`

In `SessionInfo` (types.ts), add: `origin?: string`

**Step 4: Run tests**

Run: `npx vitest run tests/core/db.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add src/core/db.ts src/adapters/types.ts tests/core/db.test.ts
git commit -m "feat(sync): add origin column to sessions table"
```

---

### Task 16: Integrate sync into daemon with timer

**Files:**
- Modify: `src/daemon.ts`

**Step 1: Add sync to daemon**

Add to `src/daemon.ts`, after web server setup:

```typescript
import { SyncEngine } from './core/sync.js'

// Sync engine
const syncEngine = new SyncEngine(db)
const syncPeers = settings.syncPeers ?? []
const syncIntervalMs = (settings.syncIntervalMinutes ?? 30) * 60 * 1000

// Initial sync on startup
if (settings.syncEnabled && syncPeers.length > 0) {
  syncEngine.syncAllPeers(syncPeers).then(results => {
    const totalPulled = results.reduce((sum, r) => sum + r.pulled, 0)
    if (totalPulled > 0) {
      emit({ event: 'sync_complete', results, totalPulled })
    }
  }).catch(() => {})
}

// Periodic sync timer
const syncTimer = settings.syncEnabled && syncPeers.length > 0
  ? setInterval(async () => {
      try {
        const results = await syncEngine.syncAllPeers(syncPeers)
        const totalPulled = results.reduce((sum, r) => sum + r.pulled, 0)
        if (totalPulled > 0) {
          emit({ event: 'sync_complete', results, totalPulled })
        }
      } catch { /* ignore */ }
    }, syncIntervalMs)
  : null
```

Update cleanup:

```typescript
onExit: () => {
  clearInterval(rescanTimer)
  if (syncTimer) clearInterval(syncTimer)
  watcher?.close()
  webServer.close()
},
```

**Step 2: Build and verify**

Run: `npm run build`
Expected: No errors

**Step 3: Commit**

```bash
git add src/daemon.ts
git commit -m "feat(sync): integrate periodic sync into daemon with configurable interval"
```

---

### Task 17: Sync trigger endpoint and settings page

**Files:**
- Modify: `src/web.ts` (add POST /api/sync/trigger)
- Modify: `src/web/views.ts` (update settings page with sync status)

**Step 1: Add sync trigger endpoint**

In `src/web.ts`, update `createApp` to accept a `syncEngine` parameter:

```typescript
export function createApp(db: Database, opts?: {
  vectorStore?: VectorStore
  embeddingClient?: EmbeddingClient
  syncEngine?: SyncEngine
  syncPeers?: SyncPeer[]
}) {
  // ... existing routes ...

  app.post('/api/sync/trigger', async (c) => {
    if (!opts?.syncEngine || !opts?.syncPeers) {
      return c.json({ error: 'Sync not configured' }, 501)
    }
    const peerName = c.req.query('peer')
    const peers = peerName
      ? opts.syncPeers.filter(p => p.name === peerName)
      : opts.syncPeers

    const results = await opts.syncEngine.syncAllPeers(peers)
    return c.json({ results })
  })
}
```

**Step 2: Build and verify**

Run: `npm run build`
Expected: No errors

**Step 3: Commit**

```bash
git add src/web.ts src/web/views.ts
git commit -m "feat(sync): add manual sync trigger endpoint and settings page"
```

---

## Phase 4: Integration and Polish

### Task 18: Run full test suite and fix any issues

**Step 1: Run all tests**

Run: `npx vitest run`
Expected: All tests PASS

If any tests fail, fix them before proceeding.

**Step 2: Manual smoke test**

Run: `npx tsx src/web.ts`

Then open in browser:
- `http://localhost:3457/` — should show session list
- `http://localhost:3457/search` — should show search page
- `http://localhost:3457/api/sessions` — should return JSON
- `http://localhost:3457/api/sync/status` — should return node info

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve integration issues from full test run"
```

---

### Task 19: Update macOS app Settings for sync config

**Files:**
- Modify: `macos/Engram/Views/SettingsView.swift`

This task adds sync configuration UI to the macOS app Settings view:
- Text field for node name
- List of peers (name + URL)
- "Sync Now" button
- Display of last sync time and status

**Note:** The Swift app reads settings from `~/.engram/settings.json` (same file as `readFileSettings()` in TypeScript). Add the sync fields there.

This is a UI-only task — the actual sync is handled by the daemon process. The Settings view writes to `settings.json`, and the daemon reads it.

**Step 1: Add sync section to SettingsView**

Add a new section in SettingsView.swift with:
- `syncNodeName` text field
- `syncEnabled` toggle
- Peer list with add/remove
- "Sync Now" button that calls `http://localhost:3457/api/sync/trigger` via URLSession

Implementation details depend on the existing SettingsView structure. Read the file first, then add the sync section following the existing patterns.

**Step 2: Build and test in Xcode**

Run: `xcodegen generate` in `macos/`, then build in Xcode.

**Step 3: Commit**

```bash
git add macos/Engram/Views/SettingsView.swift
git commit -m "feat(macos): add sync configuration UI to Settings"
```

---

### Task 20: Final integration test and documentation

**Step 1: Run full test suite**

Run: `npx vitest run`
Expected: All PASS

**Step 2: Build TypeScript**

Run: `npm run build`
Expected: No errors

**Step 3: Manual end-to-end verification**

1. Start daemon: `npx tsx src/daemon.ts`
2. Open `http://localhost:3457/` in browser
3. Verify session list loads
4. Test search functionality
5. Check `/api/sync/status` returns correct info

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete RAG + Web + Sync unified implementation"
```

---

## File Summary

### New files (12)
- `src/web.ts` — Hono web server entry point
- `src/web/views.ts` — HTML template functions (HTMX + Pico CSS)
- `src/core/vector-store.ts` — VectorStore interface + SqliteVecStore
- `src/core/embeddings.ts` — Embedding client (Ollama + OpenAI)
- `src/core/embedding-indexer.ts` — Background embedding generation
- `src/core/sync.ts` — SyncEngine for peer-to-peer sync
- `tests/web/server.test.ts` — Web API tests
- `tests/web/views.test.ts` — HTML view tests
- `tests/core/vector-store.test.ts` — Vector store tests
- `tests/core/embeddings.test.ts` — Embedding client tests
- `tests/core/embedding-indexer.test.ts` — Embedding indexer tests
- `tests/core/sync.test.ts` — Sync engine tests

### Modified files (7)
- `package.json` — add hono, sqlite-vec, marked
- `src/core/db.ts` — add `listSessionsSince`, `getFtsContent`, `getRawDb`, `origin` column
- `src/core/config.ts` — add sync config types
- `src/adapters/types.ts` — add `origin` to SessionInfo
- `src/tools/get_context.ts` — add optional vector search
- `src/daemon.ts` — integrate web server, vector store, sync engine
- `src/index.ts` — integrate vector store for get_context
