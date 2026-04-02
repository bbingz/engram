# Viking Sessions API Migration — Fix Design

## Problem

The current Viking integration uses the **Resources API** (`addResource`) which triggers VLM L0/L1/L2 generation for every semantic node in each uploaded session. This creates ~17 VLM calls per session. With 500+ sessions, this produces 8,000+ VLM tasks consuming 100M+ tokens — an unsustainable cost.

A previous attempt (commit `646c903`, Mar 21) correctly switched to the Sessions API but was reverted (`f1e6644`, same day) because committed session content appeared unsearchable via `find()`.

**Investigation conclusion**: The revert was based on a misunderstanding. Session content is not directly in `find()` results by design. Instead, the commit Phase 2 **extracts memories** (profile, preferences, entities, events, cases, patterns, tools, skills) which ARE searchable. The Viking instance already has **731 extracted memories** from the brief period Sessions API was active — confirming memory extraction works.

## Root Causes Found

1. **Wrong API**: Resources API costs ~17 VLM calls/session; Sessions API costs ~2-3 LLM calls/session
2. **Message format bug**: `pushSession()` sends `{role, content}` but the REST API expects `{role, parts: [{type: "text", text: ...}]}`
3. **Agent context missing**: Sessions created with `agent_id: "default"` instead of the configured agent `ffb1327b18bf` — may prevent memory extraction
4. **`find()` missing skills**: Search result parsing ignores the `skills` category
5. **`findMemories()` uses wrong URI**: Queries `viking://memory/` instead of `viking://user/` and `viking://agent/`

## Approach

Switch `pushToViking()` from `addResource()` to `pushSession()` with the following fixes:

1. Fix message format to use `parts` array
2. Configure agent context via `X-Agent-Id` header (or session create params)
3. Fix `find()` to include skills in results
4. Fix `findMemories()` URI targets
5. Keep existing circuit breaker, retry logic, and dedup tracking

## Design

### 1. Fix `pushSession()` message format (viking-bridge.ts)

Current (broken):
```typescript
await this.post(`${this.api}/sessions/${sessionId}/messages/async`, {
  role: msg.role,
  content: msg.content,
}, 5000);
```

Fixed:
```typescript
await this.post(`${this.api}/sessions/${sessionId}/messages/async`, {
  role: msg.role,
  parts: [{ type: 'text', text: msg.content }],
}, 5000);
```

### 2. Agent context header (viking-bridge.ts)

Add optional `agentId` to constructor. When set, include `X-Agent-Id` header in all requests:

```typescript
constructor(url: string, apiKey: string, opts?: { agentId?: string; log?: Logger; ... }) {
  this.headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${apiKey}`,
  };
  if (opts?.agentId) this.headers['X-Agent-Id'] = opts.agentId;
}
```

Configuration source: `~/.engram/settings.json` → `viking.agentId` (default: read from Viking's `/sessions` list if available).

### 3. Switch `pushToViking()` to use Sessions API (indexer.ts)

Replace `addResource()` call with `pushSession()`:

```typescript
private async pushToViking(info: SessionInfo, messages: { role: string; content: string }[]): Promise<void> {
  if (!this.opts?.viking || messages.length === 0) return

  // Dedup: skip if already pushed with same message count
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
    // Use session ID that's unique and descriptive
    const sessionId = `${info.source}::${info.project ?? 'unknown'}::${info.id}`
    await this.opts.viking.pushSession(sessionId, filtered)
    // Track push
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

### 4. Fix `find()` to include skills (viking-bridge.ts)

```typescript
const items = [
  ...(Array.isArray(r.resources) ? r.resources : []),
  ...(Array.isArray(r.memories) ? r.memories : []),
  ...(Array.isArray(r.skills) ? r.skills : []),
];
```

### 5. Fix `findMemories()` URI (viking-bridge.ts)

Search both user and agent memory scopes:

```typescript
async findMemories(query: string): Promise<VikingMemory[]> {
  try {
    // Search both user and agent memories
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

### 6. Viking backfill endpoint (web.ts)

Update `POST /api/viking/backfill` to also use `pushSession()` instead of `addResource()`.

### 7. Remove `addResource()` from hot path

`addResource()` and `extractMemory()` remain available (for future resource uploads) but are no longer called from the indexer. Remove `toVikingUri()` usage from indexer since session IDs replace resource URIs.

### 8. Configuration

Add `viking.agentId` to settings schema. Discover existing agent ID automatically on first run:

```typescript
// In bootstrap.ts, after creating VikingBridge
const agentId = settings.viking?.agentId;
// If not configured, try to discover from existing sessions
```

### 9. Fix `get_context.ts` Viking path (Critical)

After migration, `find()` returns **memories** (URIs like `viking://user/default/memories/...`) not resources. The current flow in `get_context.ts:99-110` will break:
- `sessionIdFromVikingUri(r.uri)` won't match memory URIs → returns `''`
- `toVikingUri()` + `readFn()` reads from nonexistent resource paths → returns `''`

**Fix**: Use `find()` results directly. The `abstract` field in each result already contains useful content. Don't try to map Viking results back to local session IDs — memories are cross-session extracted knowledge:

```typescript
// Viking-enhanced context with Sessions API (memories-based)
if (deps.viking && params.detail && await deps.viking.checkAvailable()) {
  let vikingContext: string[] = []
  if (params.task) {
    try {
      const vikingResults = await deps.viking.find(params.task)
      // Use the abstract/snippet directly — these are extracted memories
      vikingContext = vikingResults
        .filter(r => r.snippet)
        .slice(0, 5)
        .map(r => r.snippet)
    } catch { /* fall through */ }
  }

  // Fall back to local DB summaries for session-level content
  const targetSessions = sessions.slice(0, 5)
  const parts: string[] = []
  let totalChars = 0

  if (params.task) {
    parts.push(`当前任务：${params.task}\n`)
    totalChars += parts[0].length
  }

  // Viking memories first (cross-session knowledge)
  for (const mem of vikingContext) {
    const line = `[memory] ${mem}\n`
    if (totalChars + line.length > maxChars) break
    parts.push(line)
    totalChars += line.length
  }

  // Then local session summaries
  for (const session of targetSessions) {
    if (!session.summary) continue
    const line = `[${session.source}] ${toLocalDate(session.startTime)} — ${session.summary}\n`
    if (totalChars + line.length > maxChars) break
    parts.push(line)
    totalChars += line.length
  }
  // ... rest of assembly
}
```

### 10. Fix `search.ts` Viking result mapping

Same issue as `get_context.ts`: `search.ts:154` calls `sessionIdFromVikingUri(vr.uri)` on memory URIs. After migration, return Viking results as standalone knowledge entries, not mapped to local sessions.

### 11. Migration plan for previously-pushed sessions

Sessions already pushed via Resources API have `viking_pushed_msg_count` set. The dedup check would prevent re-pushing via Sessions API. Strategy:

- **Do NOT reset** `viking_pushed_msg_count` for existing sessions
- Old sessions remain searchable through existing resources data (preserved)
- Only NEW sessions (or sessions with new messages beyond `viking_pushed_msg_count`) use Sessions API
- When cleanup is triggered later (`POST /api/viking/cleanup`), reset all `viking_pushed_msg_count = NULL` to trigger re-push

### 12. Backfill endpoint implementation (web.ts)

```typescript
// POST /api/viking/backfill — re-push sessions via Sessions API
app.post('/api/viking/backfill', async (c) => {
  // ... existing validation ...
  for (const session of sessions) {
    const messages = db.getMessages(session.id)
    const filtered = filterForViking(messages)
    if (filtered.length === 0) { skipped++; continue }
    const sessionId = `${session.source}::${session.project ?? 'unknown'}::${session.id}`
    try {
      await viking.pushSession(sessionId, filtered)
      pushed++
    } catch (err) {
      errors.push({ id: session.id, error: String(err) })
    }
  }
  // ... existing response ...
})
```

## Files Changed

| File | Change |
|------|--------|
| `src/core/viking-bridge.ts` | Fix message format in `pushSession()`, add `agentId` header, fix `find()` skills + preserve array fallback, fix `findMemories()` |
| `src/core/indexer.ts` | Switch `pushToViking()` from `addResource()` to `pushSession()` (remains fire-and-forget) |
| `src/tools/get_context.ts` | Use `find()` results directly (abstract field) instead of mapping to resource URIs |
| `src/tools/search.ts` | Return Viking results as standalone entries, not mapped via `sessionIdFromVikingUri` |
| `src/web.ts` | Update Viking backfill endpoint to use `pushSession()` |
| `src/core/bootstrap.ts` | Pass `agentId` to VikingBridge constructor |

## Notes

- `pushToViking()` is deliberately **fire-and-forget** (not awaited) at call sites in `indexer.ts:280,417`. The method handles errors internally. This is intentional — Viking push should not block session indexing.
- Composite session IDs use `::` separator (not `--`) to avoid collision with directory names containing dashes.
- The `Array.isArray(r)` fallback in `find()` is preserved for backwards compatibility with potential older API responses.

## Cost Impact

| Metric | Before (Resources API) | After (Sessions API) |
|--------|----------------------|---------------------|
| VLM calls per session | ~17 | 0 |
| LLM calls per session | 0 | ~2-3 (summary + memory extraction) |
| Estimated tokens per session | ~200K | ~12K |
| 500 sessions total | ~100M tokens | ~6M tokens |
| **Cost reduction** | — | **~94%** |

## Risks and Mitigations

1. **Memory extraction may not cover all content**: Acceptable — extracted knowledge is more useful than raw conversation search
2. **Agent ID mismatch**: Mitigated by reading from settings + auto-discovery
3. **Session ID collisions**: Use composite ID `{source}::{project}::{id}` with `::` separator to avoid collision with directory names
4. **Existing resources data**: Preserved as-is; can be cleaned up later via `/api/viking/cleanup`
5. **`get_context.ts` / `search.ts` breaking**: Addressed in sections 9-10 — use `find()` abstracts directly instead of mapping to resource URIs

## Testing

1. Unit test: Verify `pushSession()` sends correct `parts` format
2. Integration test: Push a test session, commit, verify L0/L1 generated
3. Search test: After memory extraction, verify `find()` returns relevant memories
4. Dedup test: Re-push same session, verify no duplicate operations
