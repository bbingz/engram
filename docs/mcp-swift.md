# Switching to the Swift MCP Helper

Engram ships two interchangeable MCP server implementations:

| Impl | Path | Runtime |
|------|------|---------|
| Node (default) | `dist/index.js` | `node ≥ 18` |
| Swift helper | `Engram.app/Contents/Helpers/EngramMCP` | native macOS binary |

Both expose the **same 26 tools with identical JSON-RPC contracts** —
the Swift helper delegates reads to GRDB (read-only pool) and writes
through the daemon's HTTP API (`actor: "mcp"`). Switching is one line
of config on the MCP client.

## Why switch

- **No Node.js runtime required** on the user's machine.
- **~100ms faster cold start** (no V8 warmup, no `npm` resolution).
- **Code-signed, sandbox-friendly**: the helper lives inside the
  notarized `Engram.app` bundle and inherits its signature.

The Node impl stays around as the fallback — if anything goes wrong,
reverting is a single edit back to `node dist/index.js`.

## Prerequisites

- Engram.app installed to `/Applications/` (or wherever you keep it);
  Release-built, or Debug build from the Xcode DerivedData path.
- The Engram daemon reachable at its configured port (default 9100);
  the Swift helper is **strict-mode only** and does not fall back to
  direct SQLite on daemon unreachability.

## Switching Claude Code

Edit `~/.claude/mcp.json` (project-scoped lives at `.claude/mcp.json`):

```jsonc
{
  "mcpServers": {
    "engram": {
      "command": "/Applications/Engram.app/Contents/Helpers/EngramMCP",
      "args": [],
      "env": {}
    }
  }
}
```

Restart Claude Code. Verify with `/mcp` — the `engram` entry should
show the 26 tools.

## Switching other MCP clients

Any client that accepts a `command` + `args` config works. Point
`command` at the absolute path to the helper; no args are required.

## Reverting to Node

Change the `command` back:

```jsonc
{
  "mcpServers": {
    "engram": {
      "command": "node",
      "args": ["/absolute/path/to/engram/dist/index.js"]
    }
  }
}
```

Restart the client. No data migration is needed — both impls read and
write the same `~/.engram/index.sqlite`.

## Sanity check from the terminal

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
  | /Applications/Engram.app/Contents/Helpers/EngramMCP
```

Expected: single JSON line with `"serverInfo":{"name":"engram",...}`.

## Known limitations (MVP)

Two intentional TODOs, tracked for the eventual Swift 6 migration, not
blocking switchover:

- **Protocol version hardcoded** to `"2025-03-26"` — negotiation with
  clients that request a different version is deferred.
- **Async/sync bridge** via `DispatchSemaphore` around the stdio loop —
  will migrate to structured concurrency under Swift 6.

Neither affects tool contract behaviour, which is covered by 29
byte-for-byte golden tests in `macos/EngramMCPTests/`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `engram` tools missing after restart | Daemon not running | Start Engram.app (it supervises the daemon) |
| `spawn EACCES` from client | Binary not executable | `chmod +x` the Helpers/EngramMCP path |
| Write tool returns `DaemonUnreachable` | Daemon port changed or dead | Check Console.app `com.engram.app:daemon` logs |
| Stale tool count (< 26) | Client cached old spec | Restart the client |

Logs: helper stderr flows to the client; daemon logs are in Console.app
subsystem `com.engram.app:daemon`.
