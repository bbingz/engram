# OpenViking Integration — Design Spec

**Date:** 2026-03-16
**Problem:** Engram's search relies on FTS trigram + optional sqlite-vec, lacking hierarchical context, tiered summaries, and memory evolution.
**Solution:** Integrate OpenViking as an optional external context engine. User deploys OpenViking independently; Engram connects via HTTP API.
**Principle:** OpenViking is always optional. All existing functionality works without it. When available, it enhances search, context retrieval, and adds memory capabilities.

---

## 0. Configuration

**File:** `~/.engram/settings.json`

```json
{
  "viking": {
    "url": "http://localhost:1933",
    "apiKey": "your-api-key",
    "enabled": true
  }
}
```

- `viking.enabled`: master switch, default `false`
- `viking.url`: OpenViking server URL
- `viking.apiKey`: authentication key
- When `enabled: true` but server unreachable, Engram logs a warning and falls back to built-in search. No error to the user.

**File changes:** `src/core/config.ts` — add `viking` to `FileSettings` interface.

---

## 1. Viking Bridge — HTTP Client

**New file:** `src/core/viking-bridge.ts`

A thin HTTP client wrapping OpenViking's API. No Python dependency — pure HTTP calls from Node.js.

### Methods

```typescript
class VikingBridge {
  constructor(url: string, apiKey: string)

  // Health check — returns true if server is reachable
  async isAvailable(): Promise<boolean>

  // Push content to OpenViking for indexing + L0/L1/L2 generation
  async addResource(uri: string, content: string, metadata?: Record<string, string>): Promise<void>

  // Semantic search — returns ranked results with URIs and scores
  async find(query: string, targetUri?: string): Promise<VikingSearchResult[]>

  // Full-text search
  async grep(pattern: string, targetUri?: string): Promise<VikingSearchResult[]>

  // Read content at different detail levels
  async abstract(uri: string): Promise<string>   // L0: ~100 tokens
  async overview(uri: string): Promise<string>    // L1: ~2K tokens
  async read(uri: string): Promise<string>        // L2: full content

  // List entries under a URI
  async ls(uri: string): Promise<VikingEntry[]>

  // Memory operations
  async extractMemory(sessionContent: string): Promise<void>
  async findMemories(query: string): Promise<VikingMemory[]>
}
```

### URI Convention

Sessions pushed to OpenViking use this path structure:
```
viking://sessions/{source}/{project}/{session_id}
```

Example: `viking://sessions/claude-code/engram/cc-session-001`

### Error Handling

All methods catch network errors and return empty results / throw descriptive errors. The caller (indexer, MCP tool) decides whether to fall back to Engram's built-in search.

---

## 2. Indexer Dual-Write

**File:** `src/core/indexer.ts`

After `db.upsertSession(info)` + `db.indexSessionContent(...)`, if Viking is available:

```typescript
// Existing: write to SQLite + FTS
db.upsertSession(info)
db.indexSessionContent(info.id, messages, info.summary)

// New: push to OpenViking (async, non-blocking, fire-and-forget)
if (viking?.isAvailable()) {
  const uri = `viking://sessions/${info.source}/${info.project ?? 'unknown'}/${info.id}`
  const content = messages.map(m => `[${m.role}] ${m.content}`).join('\n\n')
  viking.addResource(uri, content, {
    source: info.source,
    project: info.project ?? '',
    startTime: info.startTime,
    model: info.model ?? '',
  }).catch(() => {}) // swallow errors — Viking is best-effort
}
```

Key design decisions:
- **Fire-and-forget** — Viking indexing errors never block Engram's pipeline
- **Full content push** — OpenViking generates L0/L1/L2 from the raw content
- **Metadata as attributes** — source, project, time, model passed for filtering
- **Dedup** — if URI already exists, OpenViking updates (idempotent add_resource)

---

## 3. MCP Tools Enhancement

### 3a. `search` tool — Viking-first with fallback

**File:** `src/tools/search.ts`

```
User calls: search("SSL certificate error")

If Viking available:
  1. viking.find("SSL certificate error") → semantic results
  2. viking.grep("SSL") → keyword results
  3. Merge, deduplicate by session_id
  4. Enrich with Engram metadata (db.getSession for each result)
  5. Return enriched results

If Viking unavailable:
  Existing FTS search (unchanged)
```

### 3b. `get_context` tool — Tiered retrieval

**File:** `src/tools/get_context.ts`

Add optional `detail` parameter: `"abstract" | "overview" | "full"` (default: `"overview"`)

```
User calls: get_context({ query: "auth middleware", detail: "overview" })

If Viking available:
  1. viking.find("auth middleware") → top 5 session URIs
  2. For each: viking.overview(uri) → L1 summary (~2K tokens each)
  3. Return structured context with tiered content

If Viking unavailable:
  Existing get_context logic (unchanged)
```

This is the biggest win — returning L1 summaries (~2K tokens) instead of full messages saves 80%+ tokens.

### 3c. New `get_memory` tool

**New file:** `src/tools/get_memory.ts`

```
User calls: get_memory({ query: "user's coding style" })

If Viking available:
  1. viking.findMemories("user's coding style")
  2. Return matching memories with source attribution

If Viking unavailable:
  Return: "Memory features require OpenViking. See docs for setup."
```

### 3d. Tool registration

**File:** `src/index.ts`

Register `get_memory` in the MCP tool list. Add `detail` parameter to `get_context` schema.

---

## 4. Daemon Integration

**File:** `src/daemon.ts`

```typescript
// Initialize Viking bridge if configured
const vikingBridge = settings.viking?.enabled
  ? new VikingBridge(settings.viking.url, settings.viking.apiKey)
  : null

// Health check on startup
if (vikingBridge) {
  const available = await vikingBridge.isAvailable()
  emit({ event: 'viking_status', available })
}

// Pass to indexer
const indexer = new Indexer(db, adapters, { viking: vikingBridge })

// Pass to web server for search proxy
const app = createApp(db, { ..., viking: vikingBridge })
```

---

## 5. Web API Enhancement

**File:** `src/web.ts`

### `/api/search` — Viking-enhanced search

When Viking available, add `vikingResults` alongside existing FTS results:

```json
{
  "results": [...],
  "searchModes": ["semantic", "keyword"],
  "vikingAvailable": true
}
```

### `/api/status` — Viking status

Add to existing status endpoint:

```json
{
  "totalSessions": 2118,
  "vikingAvailable": true,
  "vikingSessionCount": 1850
}
```

---

## 6. macOS App Adaptation

**Minimal changes.** The Swift app reads from the web API, so Viking-enhanced search results flow through automatically.

**SearchView.swift** — no changes needed; the web API returns Viking results transparently.

**PopoverView.swift** — could show Viking status dot. Optional, low priority.

**SettingsView.swift** — add Viking configuration section:
- URL field
- API Key field (secure)
- Enable/Disable toggle
- Status indicator (connected/disconnected)

---

## 7. Graceful Degradation Matrix

| Scenario | Behavior |
|----------|----------|
| Viking not configured | All tools work as before, no mention of Viking |
| Viking configured but server down | Warning in daemon log, fallback to FTS, retry every 5 min |
| Viking configured and healthy | Dual-write on index, Viking-first search, L0/L1/L2 available |
| Viking loses connection mid-session | Current request falls back to FTS, next health check in 5 min |

---

## 8. Files Changed

| File | Action | Description |
|------|--------|-------------|
| `src/core/config.ts` | Modify | Add `viking` to FileSettings |
| `src/core/viking-bridge.ts` | **Create** | HTTP client for OpenViking API |
| `src/core/indexer.ts` | Modify | Add Viking dual-write after SQLite |
| `src/tools/search.ts` | Modify | Viking-first search with fallback |
| `src/tools/get_context.ts` | Modify | Add `detail` param, use Viking L1 |
| `src/tools/get_memory.ts` | **Create** | New MCP tool for memory queries |
| `src/index.ts` | Modify | Register get_memory, pass Viking to tools |
| `src/daemon.ts` | Modify | Initialize VikingBridge, pass to indexer/web |
| `src/web.ts` | Modify | Viking status in /api/status, enhanced /api/search |
| `macos/Engram/Views/SettingsView.swift` | Modify | Viking config UI section |

## 9. Testing

- Unit tests for VikingBridge (mock HTTP responses)
- Integration test: indexer dual-write with mock Viking server
- Search fallback test: Viking unavailable → FTS works
- MCP tool tests: get_context with `detail` parameter
- Manual: deploy OpenViking via Docker, connect Engram, verify end-to-end

## 10. User Setup

用户需要：
1. `pip install openviking` 或用 Docker 部署
2. 配置 OpenViking 的 LLM API key（用于生成 L0/L1/L2）
3. 启动 `openviking-server`
4. 在 Engram settings.json 或 macOS 设置中填入 URL + API key
5. 重启 Engram — 自动开始双写新会话，存量会话需手动触发全量同步

## 11. Scope Exclusions

- 不做 OpenViking 进程管理（用户自行部署）
- 不做存量数据自动迁移（可后续提供 CLI 命令）
- 不做 OpenViking 的 Docker compose 集成
- 不修改 OpenViking 本身的代码
