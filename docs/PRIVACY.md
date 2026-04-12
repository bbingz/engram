# Engram Privacy Policy

**Last updated**: 2026-03-22

## Overview

Engram is a local-first AI session aggregator. Your data stays on your machine.

## Data Collection

**Zero telemetry.** Engram does not collect, transmit, or share any usage data, analytics, crash reports, or personal information.

## What Engram Reads

Engram reads session files created by AI coding tools on your local machine:

| Source | Path | Access |
|--------|------|--------|
| Claude Code | `~/.claude/projects/` | Read-only |
| Codex CLI | `~/.codex/sessions/` | Read-only |
| Gemini CLI | `~/.gemini/tmp/` | Read-only |
| Cursor | `~/Library/Application Support/Cursor/` | Read-only |
| VS Code | `~/Library/Application Support/Code/` | Read-only |
| Cline | `~/.cline/data/tasks/` | Read-only |
| Copilot | `~/.copilot/session-state/` | Read-only |
| OpenCode | `~/.local/share/opencode/` | Read-only |
| Windsurf | `~/.codeium/windsurf/` | Read-only |
| Kimi | `~/.kimi/` | Read-only |
| Qwen | `~/.qwen/` | Read-only |
| iflow | `~/.iflow/` | Read-only |
| Antigravity | `~/.gemini/antigravity/` | Read-only |

Engram never modifies your AI tool session files.

## What Engram Stores

- **SQLite database**: `~/.engram/index.sqlite` — session metadata, FTS index, and optional vector embeddings
- **Settings**: `~/.engram/settings.json` — non-sensitive configuration only
- **API keys**: Stored securely in macOS Keychain (service: `com.engram.app`), not in plaintext files

## Network Activity

By default, Engram listens on `127.0.0.1:3457` (localhost only). No external network connections are made unless you explicitly configure:

- **Peer Sync** (optional): Pulls session metadata (not message content) from configured peer Engram instances on your network.
- **AI Summary** (optional): Sends session excerpts to your configured AI provider (OpenAI/Anthropic/Gemini/Ollama) for summary generation.

## Non-localhost Binding

If you configure `httpHost: "0.0.0.0"` to expose the API beyond localhost:
- CIDR whitelist (`httpAllowCIDR`) is **required** — the daemon will refuse to start without it
- Write endpoints are protected by an auto-generated bearer token
- Cross-origin requests are rejected

## Third-party Services

Engram does not integrate with any advertising, analytics, or tracking services. The only third-party network calls are those you explicitly configure (AI providers, sync peers).

## Data Deletion

To remove all Engram data:
```bash
rm -rf ~/.engram/
security delete-generic-password -s "com.engram.app" -a "aiApiKey" 2>/dev/null
security delete-generic-password -s "com.engram.app" -a "titleApiKey" 2>/dev/null
```
