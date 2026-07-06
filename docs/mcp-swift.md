# Switching to the Swift MCP Helper

Engram's product MCP path is the Swift helper bundled inside the macOS app.
The older Node MCP entrypoint was deleted; TypeScript remains retained
development/reference tooling but no longer provides MCP startup.

| Impl | Path | Runtime |
|------|------|---------|
| Swift helper (product) | `Engram.app/Contents/Helpers/EngramMCP` | native macOS binary |
| Node reference | deleted | no TypeScript MCP startup path |

The Swift helper exposes the MCP tools over stdio. Reads use the Swift
GRDB read layer, and mutating tools route through the local `EngramService`
Unix socket instead of a daemon HTTP API.

## Why switch

- **No Node.js runtime required** on the user's machine.
- **~100ms faster cold start** (no V8 warmup, no `npm` resolution).
- **Code-signed, sandbox-friendly**: the helper lives inside the
  notarized `Engram.app` bundle and inherits its signature.

The Node entrypoint is not retained. Use the Swift helper for MCP startup.

## Prerequisites

- Engram.app installed to `/Applications/` (or wherever you keep it);
  Release-built, or Debug build from the Xcode DerivedData path.
- `EngramService` reachable through the Unix socket managed by the app
  under `~/.engram/run/engram-service.sock`.

## Switching Claude Code

Use the CLI path when possible:

```bash
claude mcp add --scope user engram /Applications/Engram.app/Contents/Helpers/EngramMCP
```

For manual user-scope edits, use `~/.claude/settings.json`:

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
show the 27 tools.

## Switching Codex

Codex keeps the MCP stdio process alive for the lifetime of a session. For Codex,
prefer a stable shim outside the replaceable app bundle:

```bash
mkdir -p ~/.engram/bin
cat > ~/.engram/bin/engram-mcp <<'EOF'
#!/bin/sh
set -eu

HELPER="/Applications/Engram.app/Contents/Helpers/EngramMCP"
if [ ! -x "$HELPER" ]; then
  echo "Engram MCP helper is not executable at $HELPER" >&2
  exit 127
fi

exec "$HELPER" "$@"
EOF
chmod 755 ~/.engram/bin/engram-mcp
```

Then configure `~/.codex/config.toml`:

```toml
[mcp_servers.engram]
command = "/Users/<you>/.engram/bin/engram-mcp"
args = []
```

Existing Codex sessions still need a restart after changing MCP configuration.

## Switching other MCP clients

Any client that accepts a `command` + `args` config works. Point
`command` at the absolute path to the helper; no args are required.

## Sanity check from the terminal

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
  | /Applications/Engram.app/Contents/Helpers/EngramMCP
```

Expected: single JSON line with `"serverInfo":{"name":"engram",...}`.

## Known limitations (MVP)

No MCP stdio-loop limitation is currently tracked here.

Protocol version handling supports `"2024-11-05"`, `"2025-03-26"`,
`"2025-06-18"`, and `"2025-11-25"`. Unknown newer initialize versions
negotiate down to the latest supported version instead of failing closed. Tool
contract behaviour is covered by `macos/EngramMCPTests/`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `engram` tools missing after restart | Service not running | Start Engram.app (it supervises EngramService) |
| `spawn EACCES` from client | Binary not executable | `chmod +x` the Helpers/EngramMCP path |
| `Transport closed` after deploying a new app build | Client session still holds an old stdio process/config | Use the stable Codex shim above, then restart the client session |
| Write tool returns service unreachable | EngramService not running or socket missing | Start Engram.app and check Console.app `com.engram.app` logs |
| Stale tool count (< 27) | Client cached old spec | Restart the client |

Logs: helper stderr flows to the client; service logs are in Console.app
subsystem `com.engram.app`.
