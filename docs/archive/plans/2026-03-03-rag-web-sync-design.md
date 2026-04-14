# Engram: RAG + Web + Sync — Unified Design

Date: 2026-03-03

## Problem

Three pain points with Engram today:
1. `get_context` returns imprecise results — FTS5 keyword matching misses semantically related sessions
2. No cross-device access — can't view sessions from phone/iPad or as a lighter alternative to the macOS app
3. Two Macs (MacBook + Mac Mini) both run AI tools, but sessions are isolated on each machine

## Architecture: Web-API Unified

One system solves all three problems. Each machine runs Engram with a Web server. The Web API serves both the browser UI and the peer-to-peer sync protocol.

```
MacBook                              Mac Mini
┌────────────────────┐              ┌────────────────────┐
│ Engram             │              │ Engram             │
│ ┌────────────────┐ │   REST API   │ ┌────────────────┐ │
│ │ Web Server     │◄├──── sync ────┤►│ Web Server     │ │
│ │ (Hono :3457)   │ │              │ │ (Hono :3457)   │ │
│ └──────┬─────────┘ │              │ └──────┬─────────┘ │
│ ┌──────┴─────────┐ │              │ ┌──────┴─────────┐ │
│ │ SQLite         │ │              │ │ SQLite         │ │
│ │ + FTS5         │ │              │ │ + FTS5         │ │
│ │ + sqlite-vec   │ │              │ │ + sqlite-vec   │ │
│ └────────────────┘ │              │ └────────────────┘ │
└────────────────────┘              └────────────────────┘
        ▲                                    ▲
   Phone/iPad                          Phone/iPad
   via browser                         via browser
```

Key insight: sessions are append-only (created once, never modified across machines), so sync is conflict-free — just UPSERT by session ID.

---

## Part 1: Web API

Framework: **Hono** (already a dependency), port **3457**.

### UI endpoints

```
GET  /                          → HTML SPA entry (session list)
GET  /session/:id               → Session detail (message stream)
GET  /search                    → Search page
GET  /stats                     → Usage statistics
GET  /settings                  → Sync configuration

GET  /api/sessions              → JSON session list (paginated, filterable)
GET  /api/sessions/:id          → JSON session detail + messages
GET  /api/search?q=xxx          → FTS5 text search
GET  /api/search/semantic?q=xxx → Vector similarity search (RAG)
GET  /api/stats                 → Usage stats JSON
GET  /api/project-aliases       → List project aliases
POST /api/project-aliases       → Add alias { alias, canonical }
DELETE /api/project-aliases     → Remove alias { alias, canonical }
POST /api/summary               → Generate AI summary { sessionId }
POST /api/link-sessions         → Create symlinks { targetDir }
```

### Sync endpoints

```
GET  /api/sync/status                    → Node info (name, session count, last updated)
GET  /api/sync/sessions?since=<ISO>      → Sessions added after timestamp
GET  /api/sync/messages/:id              → Full message list for a session
```

### Security

- LAN only, no authentication (home network trust)
- Read-only API (no write/delete operations via Web)
- Optional: Bearer token for accidental access prevention

---

## Part 2: RAG / Semantic Search

### Vector store abstraction

```typescript
interface VectorStore {
  index(sessionId: string, text: string): Promise<void>
  search(query: string, topK: number): Promise<{sessionId: string, score: number}[]>
  delete(sessionId: string): Promise<void>
}
```

Default implementation: **sqlite-vec**. Abstraction allows future switch to LanceDB if needed.

### Schema additions

```sql
CREATE TABLE session_embeddings (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id),
  embedding BLOB NOT NULL,
  model TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE VIRTUAL TABLE vec_sessions USING vec0(
  session_id TEXT PRIMARY KEY,
  embedding float[768]
);
```

### Embedding generation

**Input**: First 2000 characters of concatenated user messages per session (matches FTS5 content).

**Model priority**:
1. Ollama `nomic-embed-text` (local, 768-dim) — preferred
2. OpenAI `text-embedding-3-small` (1536-dim, truncated to 768) — fallback
3. Neither available → skip, use FTS5 only

**Trigger**: Background incremental generation:
- File watcher detects new session → index → embed (async)
- Sync pulls new session → insert → embed (async)
- First run → batch embed all un-embedded sessions in background

### Improved `get_context`

```
get_context(cwd, task):
  1. Filter sessions by cwd/project (unchanged)
  2. If task provided AND vector index available:
     - Generate embedding for task
     - KNN search top-10 most similar sessions via sqlite-vec
     - Merge with cwd-filtered results, rank by similarity
  3. Fallback: FTS5 keyword search on task (unchanged)
  4. Assemble and return context
```

Semantic search augments FTS5, does not replace it.

---

## Part 3: Web UI Frontend

**Stack**: HTMX + Pico CSS — zero build step, mobile-responsive, dark/light mode.

### Pages

| Route | Content | HTMX behavior |
|-------|---------|---------------|
| `/` | Session list with filters | Infinite scroll, filter chips trigger partial reload |
| `/session/:id` | Message stream | Paginated load-more |
| `/search` | Search input + results | Debounced keyup triggers search, toggle FTS5/semantic |
| `/stats` | Charts/numbers | Static load |
| `/settings` | Sync config | Form submit, manual sync button |

### Style

- Pico CSS for base styling (classless, auto dark/light, mobile-first)
- Minimal custom CSS for Engram-specific elements
- Markdown rendering for session messages (server-side via marked or similar)

---

## Part 4: Bidirectional Sync

### Database extension

```sql
ALTER TABLE sessions ADD COLUMN origin TEXT DEFAULT 'local';
-- 'local' = indexed from this machine
-- 'macbook' / 'mac-mini' = synced from peer
```

### Configuration

In `~/.engram/config.yaml`:

```yaml
sync:
  node_name: "macbook"
  peers:
    - name: "mac-mini"
      url: "http://10.0.10.100:3457"
  interval_minutes: 30
  enabled: true
```

### Sync protocol (pull-based)

```
On timer (30min) / manual trigger / app startup:
  for each peer:
    1. GET {peer}/api/sync/status → check reachability
       failure → log, skip
    2. GET {peer}/api/sync/sessions?since={last_sync_with_peer}
       → [{id, source, start_time, summary, ...}]
    3. Filter out locally existing sessions (by id)
    4. For each new session:
         GET {peer}/api/sync/messages/{id}
         INSERT OR IGNORE into sessions (origin = peer.name)
         INSERT into sessions_fts
         Queue embedding generation (async)
    5. Update last_sync_time for this peer
```

### Design properties

- **Pull-only**: Each machine pulls from peers. No push endpoint needed.
- **Idempotent**: INSERT OR IGNORE by session ID. Safe to re-run.
- **Offline-friendly**: Unreachable peer = skip, retry next cycle.
- **Incremental**: `since` parameter ensures only new data transfers.

### macOS app integration

- Settings: peer list, connection status, last sync time per peer
- "Sync Now" button
- Notification: "Synced 12 new sessions from mac-mini"

---

## Implementation phases

### Phase 1: Web server + API (foundation)
- Hono server with UI and API endpoints
- HTML pages with HTMX
- Serves existing FTS5 search

### Phase 2: RAG / semantic search
- VectorStore interface + sqlite-vec implementation
- Embedding generation (Ollama + OpenAI fallback)
- Enhanced `get_context` tool
- Semantic search API endpoint

### Phase 3: Bidirectional sync
- Sync endpoints on Web server
- Pull-based sync engine
- Config file for peers
- macOS app Settings integration

### Phase 4: Polish
- Mobile UI refinements
- Sync progress/status UI
- Error handling and retry logic
- Performance tuning

---

## Technical choices summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Web framework | Hono | Already in dependencies, lightweight |
| Vector DB | sqlite-vec (via VectorStore interface) | Same DB file, sync-friendly, sufficient scale |
| Embedding model | Ollama nomic-embed-text, OpenAI fallback | Local-first, hybrid availability |
| Frontend | HTMX + Pico CSS | Zero build, mobile-responsive, minimal JS |
| Sync protocol | REST pull-based | Reuses Web API, no extra infrastructure |
| Security | LAN-only, read-only, optional token | Home network, simplicity |
| Port | 3457 | Adjacent to MCP (3456) |
| Vector dimensions | 768 | nomic-embed-text native dimension |

---

## Risks and mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| sqlite-vec compile failure | No RAG | VectorStore abstraction allows LanceDB swap; FTS5 still works |
| Ollama not installed | No local embeddings | OpenAI fallback + skip-and-retry later |
| Port conflict | Web server won't start | Auto-try next port (3458, 3459...) |
| Peer unreachable | Sync fails | Log and skip, retry on next cycle |
| Slow embedding batch | Poor first-run UX | Background async with progress indicator |
| Large session sync | Slow transfer | Paginate sync endpoint, transfer metadata first |
