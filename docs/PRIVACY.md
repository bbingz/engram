# Engram Privacy Policy

**Last updated**: 2026-07-02

## Overview

Engram is a local-first AI session aggregator. Your data stays on your machine.

## Data Collection

**Zero telemetry.** Engram does not collect, transmit, or share any usage data, analytics, crash reports, or personal information.

## What Engram Reads

Engram reads session files created by AI coding tools on your local machine:

| Source | Path | Indexing access |
|--------|------|-----------------|
| Claude Code | `~/.claude/projects/` | Read-only |
| Codex CLI | `~/.codex/sessions/`, plus `~/.claude-openai/projects/` when launched via Claude Code | Read-only |
| Grok Build | `~/.grok/sessions/` | Read-only |
| Pi | `~/.pi/agent/sessions/` | Read-only |
| Gemini CLI | `~/.gemini/tmp/` | Read-only |
| Cursor | `~/Library/Application Support/Cursor/` | Read-only |
| VS Code | `~/Library/Application Support/Code/` | Read-only |
| Cline | `~/.cline/data/tasks/` | Read-only |
| Copilot | `~/.copilot/session-state/<uuid>/events.jsonl` | Read-only |
| OpenCode | `~/.local/share/opencode/opencode.db` | Read-only |
| Windsurf | Existing Engram cache under `~/.engram/cache/windsurf` (live gRPC sync disabled) | Read-only |
| Kimi | `~/.kimi/sessions/`, plus `~/.claude-kimi/projects/` when launched via Claude Code | Read-only |
| Qwen | `~/.qwen/projects/`, plus `~/.claude-qwen/projects/` when launched via Claude Code | Read-only |
| Qoder | `~/.qoder/projects/` | Read-only |
| iflow | `~/.iflow/projects/` | Read-only |
| Antigravity | `~/.gemini/antigravity-cli/brain/` and legacy `~/.gemini/antigravity/` cache data | Read-only |
| Command Code | `~/.commandcode/projects/` | Read-only |
| MiniMax | `~/.claude/projects/` and `~/.claude-minimax/projects/` Claude Code-compatible transcripts | Read-only |
| Mimo | `~/.claude-mimo/projects/`, `~/.claude-mimosg/projects/` Claude Code-compatible transcripts | Read-only |
| Doubao | `~/.claude-doubao/projects/` Claude Code-compatible transcripts | Read-only |
| GLM | `~/.claude-glm/projects/`, `~/.claude-glmc/projects/` Claude Code-compatible transcripts | Read-only |
| DeepSeek | `~/.claude-ds/projects/`, `~/.claude-dsc/projects/` Claude Code-compatible transcripts | Read-only |

Indexing and normal browsing are read-only. Explicit project migration commands
(`project_move`, `project_archive`, `project_undo`, and `project_move_batch`)
can move project directories, rewrite project path strings inside supported AI
session files, update Gemini project registry data, and record migration state.
Those commands run only when invoked by the user or an MCP client.

## What Engram Stores

- **SQLite database**: `~/.engram/index.sqlite` — session metadata, FTS index, and compatibility fields/tables for future vector search
- **Settings**: `~/.engram/settings.json` — non-sensitive configuration only
- **API keys**: Stored securely in macOS Keychain (service: `com.engram.app`), not in plaintext files

## Network Activity

Data is local by default. The current Swift service does not implement peer sync, semantic/vector search, or embedding generation, and the macOS app does not trigger peer sync. Network calls are only made by optional, user-configured AI summaries and title generation.

By default, the macOS app talks to EngramService over a Unix domain socket under `~/.engram/run/engram-service.sock`. The default app runtime does not expose a localhost HTTP API. No external network connections are made unless you explicitly configure:

- **Peer sync compatibility fields**: Older settings may contain peer-sync keys, but the current Swift service returns unsupported for sync commands and the macOS app does not start sync traffic.
- **AI Summary** (optional): Sends session excerpts to your configured OpenAI-compatible chat provider when you request summary generation.
- **Title Generation** (optional): Sends session excerpts to your configured title provider (Ollama, OpenAI, or custom OpenAI-compatible endpoint) when you request title generation.
- **Embedding compatibility fields**: Older settings may contain Ollama/OpenAI embedding keys, but the current Swift product path does not generate embeddings or enable semantic search from those fields.
- **Remote session offload** (optional, default **OFF**): When you explicitly enable it and configure a server, regenerable index artifacts for cold/archived sessions are uploaded to a server you control. See below.

## Remote session offload (opt-in)

Remote offload is **disabled by default** and moves data off your machine only after you set `remoteOffloadEnabled: true` and configure a server URL + token in `~/.engram/settings.json`. When enabled:

- **What leaves the machine:** only **regenerable index artifacts** — a session's full-text-search (`sessions_fts`) content and its generated summary, bundled and **encrypted with AES-GCM** before upload. **Raw transcript files (`~/.claude`, `~/.codex`, etc.) are never moved or uploaded** — they stay on your disk untouched.
- **Where it goes:** a **self-hosted server you run** (the `engram-remote` binary), never a third-party cloud and never bundled in `Engram.app`. The server holds the at-rest encryption key and requires a bearer token. The client refuses any non-HTTPS, non-loopback URL.
- **What stays local:** every offloaded session keeps one keyword "shadow" line so it remains discoverable in keyword search; opening it transparently re-downloads (rehydrates) the full content.
- **Eligibility:** archived/hidden sessions and visible sessions untouched longer than `remoteOffloadColdAgeDays`. `skip`-tier and subagent sessions are never offloaded.

See `docs/remote-offload.md` for the full deployment and operations guide.

## Optional legacy HTTP tooling

Retained development/reference tooling may still understand older HTTP settings. Those paths are not used by the default macOS app runtime. If any local HTTP tool is explicitly exposed beyond localhost, it must use a CIDR whitelist, bearer-token protection for write endpoints, and CORS rejection for untrusted origins.

## Third-party Services

Engram does not integrate with any advertising, analytics, or tracking services. The only third-party network calls in the current Swift product path are those you explicitly configure for AI providers used by summaries or title generation.

## Data Deletion

To remove all Engram data:
```bash
rm -rf ~/.engram/
security delete-generic-password -s "com.engram.app" -a "aiApiKey" 2>/dev/null
security delete-generic-password -s "com.engram.app" -a "titleApiKey" 2>/dev/null
```
