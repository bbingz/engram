# Engram Privacy Policy

**Last updated**: 2026-07-12

## Overview

Engram is a local-first AI session aggregator. Data stays on your machine by
default. It leaves the machine only for features you explicitly configure,
including AI providers, legacy remote offload, or exact-source remote archive
v2 as described below.

## Data Collection

**Zero Engram telemetry.** Engram does not send usage analytics, crash reports,
or personal information to the Engram project or an Engram-operated service.
Only the explicit, user-configured transfers described under Network Activity
leave the machine.

## What Engram Reads

Engram reads session files created by AI coding tools on your local machine:

| Source | Path | Indexing access |
|--------|------|-----------------|
| Claude Code | `~/.claude/projects/` | Read-only |
| Codex CLI | `~/.codex/sessions/` | Read-only |
| Gemini CLI | `~/.gemini/tmp/` | Read-only |
| Cursor | `~/Library/Application Support/Cursor/` | Read-only |
| VS Code | `~/Library/Application Support/Code/` | Read-only |
| Cline | `~/.cline/data/tasks/` | Read-only |
| Copilot | `~/.copilot/session-state/<uuid>/events.jsonl` | Read-only |
| OpenCode | `~/.local/share/opencode/opencode.db` | Read-only |
| Windsurf | Existing Engram cache under `~/.engram/cache/windsurf` (live gRPC sync disabled) | Read-only |
| Kimi | `~/.kimi/sessions/` | Read-only |
| Qwen | `~/.qwen/projects/` | Read-only |
| Qoder | `~/.qoder/projects/` | Read-only |
| iflow | `~/.iflow/projects/` | Read-only |
| Antigravity | `~/.gemini/antigravity-cli/brain/` and legacy `~/.gemini/antigravity/` cache data | Read-only |
| Command Code | `~/.commandcode/projects/` | Read-only |

Indexing and normal browsing are read-only. Explicit project migration commands
(`project_move`, `project_archive`, `project_undo`, and `project_move_batch`)
can move project directories, rewrite project path strings inside supported AI
session files, update Gemini project registry data, and record migration state.
Those commands run only when invoked by the user or an MCP client.

## What Engram Stores

- **SQLite database**: `~/.engram/index.sqlite` — session metadata and FTS plus
  the active optional semantic corpus. When a usable embedding provider is
  configured, `semantic_chunks`, `insight_embeddings`, and `embedding_meta` are
  actively written and queried by the service/MCP semantic paths. The App UI
  remains keyword-only; that UI boundary does not make these tables dormant.
- **Exact archive (only when enabled)**: `~/.engram/archive-v2/` — immutable
  exact-source chunks, manifests, and a separate archive catalog
- **Settings and API keys**: `~/.engram/settings.json` normally stores
  configuration and Keychain markers. New secrets use macOS Keychain with
  `@keychain` markers in the signed product. However, a legacy plaintext
  `embeddingApiKey` or `aiApiKey` may remain in `settings.json`; an unsigned or
  ad-hoc build can also retain a plaintext fallback when Keychain is
  unavailable. Legacy plaintext is replaced only after Keychain set, read-back
  verification, and settings rewrite all succeed. Migration failure preserves
  recoverable plaintext instead of risking credential loss. Inspect
  `settings.json` and complete the migration without printing secret values:
  use the signed app's Settings UI, confirm the marker locally, and never paste
  a key into logs, tickets, or shell commands.
- **Archive bearer tokens (only when configured)**: Stored in macOS Keychain
  service `com.engram.remote-archive-v2`, not in settings or the archive catalog

## Network Activity

Data is local by default. The current Swift service does not implement peer
sync, and the macOS app does not trigger peer sync. Network calls are made only
by configured features: AI summaries/titles, embedding generation and semantic
queries, legacy remote offload, or exact-source remote archive v2.

By default, the macOS app talks to EngramService over a Unix domain socket under `~/.engram/run/engram-service.sock`. The default app runtime does not expose a localhost HTTP API. No external network connections are made unless you explicitly configure:

- **Peer sync compatibility fields**: Older settings may contain peer-sync keys, but the current Swift service returns unsupported for sync commands and the macOS app does not start sync traffic.
- **AI Summary** (optional): Sends session excerpts to your configured OpenAI-compatible chat provider when you request summary generation.
- **Title Generation** (optional): Sends session excerpts to your configured title provider (Ollama, OpenAI, or custom OpenAI-compatible endpoint) when you request title generation.
- **Embedding generation and semantic/hybrid search** (optional): With a usable
  configured embedding provider, the Swift service automatically sends pending
  **session chunks** and **insight content** to the configured
  `{baseURL}/embeddings` endpoint during initial and periodic embedding
  backfills. A semantic/hybrid request with a compatible stored corpus sends
  the **semantic/hybrid query text** to the same endpoint. Configuration may use
  `ENGRAM_EMBEDDING_API_KEY` or `embeddingApiKey`; when those are absent,
  `EmbeddingSettings` may reuse the configured `aiApiKey` and its provider base
  URL. No embedding content or query text is sent when no usable embedding
  provider is configured; keyword search remains local.
- **Remote session offload** (optional, default **OFF**): When you explicitly enable it and configure a server, regenerable index artifacts for cold/archived sessions are uploaded to a server you control. See below.
- **Exact-source remote archive v2** (optional, default **OFF**): When you
  separately enable exact capture and configure both private replicas, exact raw
  source bytes for supported Claude Code and Codex single-file sessions can be
  uploaded to your `macmini-hq` and `macmini-m1` servers over Tailscale. This is
  distinct from legacy remote offload; see below.

## Remote session offload (opt-in)

Remote offload is **disabled by default** and moves data off your machine only after you set `remoteOffloadEnabled: true` and configure a server URL + token in `~/.engram/settings.json`. When enabled:

- **What leaves the machine:** only **regenerable index artifacts** — a session's full-text-search (`sessions_fts`) content and its generated summary, bundled and **encrypted with AES-GCM** before upload. **Raw transcript files (`~/.claude`, `~/.codex`, etc.) are never moved or uploaded** — they stay on your disk untouched.
- **Where it goes:** a **self-hosted server you run** (the `engram-remote` binary), never a third-party cloud and never bundled in `Engram.app`. The server holds the at-rest encryption key and requires a bearer token. The client refuses any non-HTTPS, non-loopback URL.
- **What stays local:** every offloaded session keeps one keyword "shadow" line so it remains discoverable in keyword search; opening it transparently re-downloads (rehydrates) the full content.
- **Eligibility:** archived/hidden sessions and visible sessions untouched longer than `remoteOffloadColdAgeDays`. `skip`-tier and subagent sessions are never offloaded.

See `docs/remote-offload.md` for the full deployment and operations guide.

## Exact-source remote archive v2 (opt-in, zero-delete release)

Exact-source archive v2 is **disabled by default**. Its dormant path does not
create the local archive, read archive credentials from Keychain, or construct
remote archive clients. It becomes active only after `exactArchiveEnabled` is
set to `true`; remote replication additionally requires an enabled, valid
`remoteArchiveV2` configuration and both replica tokens.

- **What leaves the machine:** exact raw bytes for adapter-declared,
  replay-proven Claude Code and Codex single-file locators, plus immutable
  manifests and receipt requests. Search tier does not decide retention.
- **What is not uploaded:** unsupported or unsafe virtual, composite,
  directory, symlink, adjacent-shard, or database-backed locators. Other
  adapters remain excluded until they have a canonical replay exporter and
  fixture proof.
- **Where it goes:** two self-hosted servers you operate — `macmini-hq` and
  `macmini-m1` — in separate physical locations. Production configuration is
  Tailscale-only and also requires distinct bearer tokens. There is no public
  endpoint or third-party archive service in this design.
- **What stays local:** the live source is never modified or deleted by this
  release. A local immutable archive lives under `~/.engram/archive-v2/` only
  when exact capture is enabled. The first release has no local eviction,
  remote deletion, archive GC, or source unlink path.
- **Encryption boundary:** each server uses its own server-held AES at-rest key.
  This protects stored bytes when the key is unavailable; it is not a
  zero-knowledge design. Compromise of an online server able to read its key can
  expose that replica's plaintext. Tailscale membership also does not replace
  bearer authorization.
- **Credentials:** client tokens are stored in macOS Keychain service
  `com.engram.remote-archive-v2`, accounts `replica:hq` and `replica:m1`.
  Tokens and server keys must be different between replicas and from legacy v1
  offload credentials.
- **Project exclusions:** normalized absolute project roots may be excluded
  from remote eligibility. The rule is applied before replication; a missing or
  ambiguous project identity is not silently treated as remotely eligible.

Exact bytes are the archive fact source. Parsed messages, FTS, summaries,
embeddings, tiers, and legacy offload bundles remain derived data. Full
configuration, supported-locator limits, status/retry fields, backup
prerequisites, rollback, and the current O(N) discovery limit are documented in
[`docs/remote-archive-v2.md`](remote-archive-v2.md).

## Optional legacy HTTP tooling

Retained development/reference tooling may still understand older HTTP settings. Those paths are not used by the default macOS app runtime. If any local HTTP tool is explicitly exposed beyond localhost, it must use a CIDR whitelist, bearer-token protection for write endpoints, and CORS rejection for untrusted origins.

## Third-party Services

Engram does not integrate with any advertising, analytics, or tracking services.
Third-party calls in the Swift product path go only to providers or servers you
configure for summaries, title generation, embeddings/semantic queries, legacy
offload, or exact-source archive v2.

## Data Deletion

The commands below remove local Engram data and the listed local AI-provider
keys. They do **not** remove legacy offload bytes or exact-source archive bytes
from a self-hosted server. Exact-source archive v2 deliberately exposes no
remote DELETE API in its first release; remote-media destruction is a separate
operator action and must account for backups and key recovery material.

To remove all Engram data:
```bash
rm -rf ~/.engram/
security delete-generic-password -s "com.engram.app" -a "aiApiKey" 2>/dev/null
security delete-generic-password -s "com.engram.app" -a "titleApiKey" 2>/dev/null
security delete-generic-password -s "com.engram.remote-archive-v2" -a "replica:hq" 2>/dev/null
security delete-generic-password -s "com.engram.remote-archive-v2" -a "replica:m1" 2>/dev/null
```
