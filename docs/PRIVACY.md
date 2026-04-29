# Engram Privacy Policy

**Last updated**: 2026-04-24

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
| Copilot | `~/.copilot/session-state/<uuid>/events.jsonl` | Read-only |
| OpenCode | `~/.local/share/opencode/opencode.db` | Read-only |
| Windsurf | `~/.codeium/windsurf/` | Read-only |
| Kimi | `~/.kimi/sessions/` | Read-only |
| Qwen | `~/.qwen/projects/` | Read-only |
| iflow | `~/.iflow/projects/` | Read-only |
| Antigravity | `~/.gemini/antigravity/` | Read-only |

Engram never modifies your AI tool session files.

## What Engram Stores

- **SQLite database**: `~/.engram/index.sqlite` — session metadata, FTS index, and optional vector embeddings
- **Settings**: `~/.engram/settings.json` — non-sensitive configuration only
- **API keys**: Stored securely in macOS Keychain (service: `com.engram.app`), not in plaintext files

## Network Activity

Data is local by default. Network calls are made by: peer sync, AI summaries, title generation, and embedding providers — all optional and user-configured.

By default, the macOS app talks to EngramService over a Unix domain socket under `~/.engram/run/engram-service.sock`. The default app runtime does not expose a localhost HTTP API. No external network connections are made unless you explicitly configure:

- **Peer Sync** (optional): Pulls session metadata (not message content) from configured peer Engram instances on your network.
- **AI Summary** (optional): Sends session excerpts to your configured AI provider (OpenAI/Anthropic/Gemini/Ollama) for summary generation.
- **Title Generation** (optional): Sends session excerpts to your configured AI provider for automatic title generation.
- **Embedding Providers** (optional): Sends message content to Ollama (local or remote) or OpenAI for vector embedding generation used in semantic search.

## Optional legacy HTTP tooling

Retained development/reference tooling may still understand older HTTP settings. Those paths are not used by the default macOS app runtime. If any local HTTP tool is explicitly exposed beyond localhost, it must use a CIDR whitelist, bearer-token protection for write endpoints, and CORS rejection for untrusted origins.

## Third-party Services

Engram does not integrate with any advertising, analytics, or tracking services. The only third-party network calls are those you explicitly configure (AI providers, sync peers).

## Data Deletion

To remove all Engram data:
```bash
rm -rf ~/.engram/
security delete-generic-password -s "com.engram.app" -a "aiApiKey" 2>/dev/null
security delete-generic-password -s "com.engram.app" -a "titleApiKey" 2>/dev/null
```
