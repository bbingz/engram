# Orphan Process Elimination Design

## Problem

Node.js processes (`dist/index.js` MCP Server) accumulate as orphans when MCP clients disconnect.
Found 22 orphan processes each consuming 20-60% CPU. Root causes:

1. **stdin `close` event unreliable**: `StdioServerTransport` calls `stdin.on('data', ...)` (flowing mode) but doesn't listen for `end`. Some MCP clients (Claude Code, Codex CLI) may kill the connection without properly closing stdin.
2. **chokidar watcher keeps event loop alive**: `persistent: true` watcher has no cleanup — even if stdin closes, the process can't exit naturally.
3. **daemon.ts has zero exit mechanisms**: No stdin monitoring, no signal handlers, no parent process detection. If Swift app crashes (SIGKILL), daemon lives forever.

## Design: Multi-Layer Defense

Four independent exit triggers — any one alone is sufficient:

| Layer | Mechanism | Triggers When | Latency |
|-------|-----------|---------------|---------|
| 1 | stdin `end` + `close` | Client closes pipe normally | Instant |
| 2 | Parent process liveness (`kill(ppid, 0)` every 2s) | Parent killed/crashed | ≤ 2s |
| 3 | Idle timeout (5 min no MCP requests) | Any abnormal state | ≤ 5 min |
| 4 | SIGTERM/SIGINT + watcher cleanup | Normal signal shutdown | Instant |

### Files to Change

**New: `src/core/lifecycle.ts`** — Unified lifecycle manager

```typescript
export function setupProcessLifecycle(options?: {
  idleTimeoutMs?: number    // default 300_000 (5 min), 0 = disabled
  onExit?: () => void       // cleanup callback (close watcher, db, etc.)
}): {
  heartbeat: () => void     // call on each MCP request to reset idle timer
}
```

Implementation:
- Layer 1: `process.stdin.on('end', exit)` + `process.stdin.on('close', exit)`
- Layer 2: `setInterval(() => { try { process.kill(ppid, 0) } catch { exit() } }, 2000).unref()`
- Layer 3: Idle timer reset by `heartbeat()`, fires `exit()` after timeout
- Layer 4: `process.on('SIGTERM', exit)` + `process.on('SIGINT', exit)`
- `exit()`: calls `onExit()` callback then `process.exit(0)`

**Modified: `src/core/watcher.ts`** — Add `stopWatcher()`

Return the watcher instance from `startWatcher()` so lifecycle can close it.

**Modified: `src/index.ts`** — Use `setupProcessLifecycle()`

- Remove the old `process.stdin.on('close', ...)` line
- Call `setupProcessLifecycle()` with watcher cleanup
- Call `heartbeat()` inside MCP request handler

**Modified: `src/daemon.ts`** — Add parent process detection

- Use `setupProcessLifecycle({ idleTimeoutMs: 0 })` (no idle timeout for daemon)
- stdin layer still active (daemon's stdin is connected to Swift app's pipe)

## Verification

1. Start MCP server via `echo '{}' | timeout 3 node dist/index.js` — process should exit within 2s after stdin closes
2. Start MCP server, kill parent process — server should exit within 2s
3. Start MCP server, leave idle — should exit after 5 minutes
4. `ps aux | grep coding-memory` should show 0 orphan processes after testing
