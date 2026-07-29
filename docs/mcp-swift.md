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

To probe the modern (2026-07-28) era, which has no `initialize` handshake:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"server/discover"}' \
  | /Applications/Engram.app/Contents/Helpers/EngramMCP
```

Expected: single JSON line containing
`"supportedVersions":["2026-07-28","2025-11-25","2025-06-18","2025-03-26","2024-11-05"]`.

## Known limitations (MVP)

No MCP stdio-loop limitation is currently tracked here.

The helper is a dual-era server: it speaks both the legacy
`initialize`-handshake revisions and the modern per-request revisions
introduced by MCP 2026-07-28.

- **Legacy era** — `"2024-11-05"`, `"2025-03-26"`, `"2025-06-18"`, and
  `"2025-11-25"` negotiate through `initialize` exactly as before. An unknown
  newer `initialize` version negotiates down to `"2025-11-25"` instead of
  failing closed, and the legacy response bytes are unchanged.
- **Modern era** — `"2026-07-28"` clients skip the handshake entirely and put
  `_meta["io.modelcontextprotocol/protocolVersion"]` on every request. The era
  is decided per request from the presence of that key. Modern results carry a
  `"resultType":"complete"` discriminator, the server identity under result
  `_meta["io.modelcontextprotocol/serverInfo"]` (there is no `initialize`
  result to read it from), and CacheableResult freshness hints
  `ttlMs` + `"cacheScope":"private"` on `tools/list` (300000),
  `prompts/list` (3600000), `resources/list` and `resources/read` (30000).
- **`server/discover`** — MUST-implement in 2026-07-28 and always answered,
  including without `_meta`, because it doubles as the spec's stdio
  backward-compatibility probe. It returns `supportedVersions` across both
  eras, `capabilities` (`tools`/`resources`/`prompts`), `instructions`,
  `ttlMs` 3600000, `"cacheScope":"private"`, and `serverInfo` in `_meta`.
- **Unsupported modern version** — a request whose `_meta` names a revision
  this build does not speak gets JSON-RPC error code `-32022`
  ("Unsupported protocol version") with
  `data: {supported: [...], requested: "..."}`.
- **`ping`** — removed from the 2026-07-28 core spec, but still answered in
  both eras so an era-ambiguous liveness probe cannot kill the transport.
- **Resource not found** — already returned `-32602`, which is what
  2026-07-28 changed to (from `-32002`), so no behavior changed there.
- **Roots / Sampling / Logging** — deprecated in 2026-07-28 and never
  implemented by this helper, so nothing is affected.

Tool contract behaviour is covered by `macos/EngramMCPTests/`.

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

## Remote MCP endpoint (Mac mini)

Separate from the stdio helper above, `EngramRemoteServer` — the offload server
running on the Mac mini — can serve an opt-in, **read-only** MCP endpoint over
Streamable HTTP at `POST /mcp`. It exposes archived session data from the
archive v2 store, not the local index: three tools,
`archive_list_machines`, `archive_list_captures` (each entry carries the
sessionID and the manifest digest), and `archive_get_session` (windowed
transcript read by manifest digest, `offset`, and `max_bytes`). Every result puts
its payload in `structuredContent` as well as in the text `content` block —
including the transcript window, as `structuredContent.text` — because Claude Code
surfaces only `structuredContent` when a result has both.

It is **dual-era and stateless**, like the stdio helper: it works with today's
Claude Code out of the box (`initialize` handshake, MCP revisions `2024-11-05`
through `2025-11-25`), and a client on revision `2026-07-28` gets the modern
per-request path instead. The era is decided per request on whether the body
carries `_meta["io.modelcontextprotocol/protocolVersion"]` — present is modern
(and then the `MCP-Protocol-Version` / `Mcp-Method` / `Mcp-Name` headers are
required and must match the body), absent is legacy. No `Mcp-Session-Id` is ever
issued or required in either era, so there is no session to expire and a server
restart costs a client nothing. `GET /mcp` returns 405 (the endpoint never pushes
server-initiated messages, so it declines the legacy standalone stream), and any
`Origin` header is refused (there are no browser clients).

Enable it on the mini by adding two variables to the secrets env file the
launchd wrapper already sources (`secrets/archive-v2.env`), then restarting the
job:

```sh
ENGRAM_REMOTE_MCP_ENABLED=1
ENGRAM_REMOTE_MCP_TOKEN=<fresh random token>
```

It is off by default. Archive v2 must already be enabled, and the token must be
distinct from both `ENGRAM_REMOTE_TOKEN` and `ENGRAM_REMOTE_ARCHIVE_TOKEN` —
the server refuses to start otherwise.

Point a client at it over the tailnet:

```bash
claude mcp add --transport http engram-remote http://<tailscale-ip>:8787/mcp \
  --header "Authorization: Bearer <ENGRAM_REMOTE_MCP_TOKEN>"
```

Treat that token as "read every archived session on this mini". Design and
rationale: `docs/remote-mcp-2026-07-28-design.md`.
