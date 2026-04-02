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
    const sessionId = `${info.source}--${info.project ?? 'unknown'}--${info.id}`
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

## Files Changed

| File | Change |
|------|--------|
| `src/core/viking-bridge.ts` | Fix message format in `pushSession()`, add `agentId` header, fix `find()` skills, fix `findMemories()` |
| `src/core/indexer.ts` | Switch `pushToViking()` from `addResource()` to `pushSession()` |
| `src/web.ts` | Update Viking backfill endpoint |
| `src/core/bootstrap.ts` | Pass `agentId` to VikingBridge constructor |

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
3. **Session ID collisions**: Use composite ID `{source}--{project}--{id}` to ensure uniqueness
4. **Existing resources data**: Preserved as-is; can be cleaned up later via `/api/viking/cleanup`

## Testing

1. Unit test: Verify `pushSession()` sends correct `parts` format
2. Integration test: Push a test session, commit, verify L0/L1 generated
3. Search test: After memory extraction, verify `find()` returns relevant memories
4. Dedup test: Re-push same session, verify no duplicate operations
