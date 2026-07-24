# Engram Claude Code plugin (MVP)

Thin Claude Code plugin that connects to the **installed Engram app helpers**.
It does **not** ship a second Swift binary.

The SessionStart bridge requires an Engram build that includes
`EngramCLI context`. Engram v1.0.5 and earlier do not provide that command;
on those versions the hook fails open and injects no context.

## Layout

| Path | Role |
|------|------|
| `.claude-plugin/plugin.json` | Plugin manifest |
| `.mcp.json` | MCP server via `scripts/engram-mcp` |
| `hooks/hooks.json` | `SessionStart` **command** hook (not `mcp_tool`) |
| `scripts/session-start-context` | Fail-open context injector |
| `scripts/engram-mcp` | Fail-closed resolver for long-lived MCP stdio |
| `scripts/resolve-engram-helper` | Shared path resolution |
| `skills/{catch-up,remember,handoff}` | Explicit skills only |

## Why command hooks (not mcp_tool) for SessionStart

Official Claude Code docs note that `SessionStart` often fires **before** plugin
MCP servers finish connecting. This plugin therefore:

1. Resolves product `EngramCLI`
2. Runs `EngramCLI context`, which spawns sibling `EngramMCP` and calls `get_context`
3. Emits SessionStart `hookSpecificOutput.additionalContext` JSON (≤8KB)
4. Fail-opens on missing app/helper/timeout/malformed output (exit 0, no block)

## Memory write policy

- **Only** the explicit `remember` skill may call `save_insight`
- All three skills require manual `/engram:<skill>` invocation
- No `Stop` / `SessionEnd` automatic writes

## Helper resolution

Order (no user-home hardcodes):

1. `ENGRAM_CLI_PATH` / `ENGRAM_MCP_PATH` / `ENGRAM_CLI_MCP_HELPER`
2. Sibling of discovered CLI (`…/Helpers/EngramMCP`, same directory)
3. `/Applications/Engram.app/Contents/Helpers/…`
4. `PATH`

## Local enable (dev)

```bash
claude --plugin-dir /path/to/engram/integrations/claude-code/engram
# or
claude plugin validate integrations/claude-code/engram
```
