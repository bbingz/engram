# MCP Swift Shim Feasibility

Date: 2026-04-22

## 1. Swift MCP SDK status

The official SDK exists: `modelcontextprotocol/swift-sdk`. It ships server/client support and, as of `0.12.0` (2026-03-24), targets MCP spec `2025-11-25`. But MCP’s own tier page classifies Swift as **Tier 3**, which means experimental / no stable-release guarantee / no conformance minimum. Its README also requires **Swift 6 / Xcode 16**, which is slightly ahead of Engram’s written “Swift 5.9” convention.

Claude Code docs confirm that **local stdio MCP servers are supported today**, but Anthropic’s public docs do **not** pin a protocol date for Claude Code. The local fact we can verify in this repo is that Engram’s current Node MCP entry is built on `@modelcontextprotocol/sdk` `^1.10.2`, which comes from the `2025-03-26` generation of the TS SDK. So the safe statement is: Swift SDK tracks `2025-11-25`; Engram’s shipped Node MCP is on TS SDK `1.10.2`; Claude Code’s exact negotiated date is **not publicly documented**, but current Claude Code + Node MCP interop already works over stdio with core tool calls.

Recommendation: **roll our own minimal stdio JSON-RPC shim** instead of adopting the Swift SDK. Estimated cost for lifecycle + stdio + tool dispatch shell: **~300-450 LOC**. That is lower-risk than importing a Tier-3, pre-1.0, Swift-6-first dependency into this repo for a server that only needs `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping`, and JSON-RPC errors.

## 2. Stdio transport

If we used the official SDK, stdio is already provided by `StdioTransport`. If we do the recommended roll-your-own path, stdio transport is ours; still not a blocker, because MCP stdio is just newline-delimited UTF-8 JSON-RPC over `stdin`/`stdout`, and this shim does not need HTTP/SSE/session resumption.

## 3. Tool schema surface

`src/tools/*.ts` is **19 modules**, not 19 callable names:

- `get_context` R: project history context.
- `search` R: keyword + semantic search.
- `save_insight` W: persist memory/insight.
- `list_sessions` R: filter sessions.
- `get_session` R: read one transcript.
- `get_memory` R: retrieve saved insights.
- `get_insights` R: cost optimization hints.
- `get_costs` R: token/cost summary.
- `stats` R: usage counts.
- `tool_analytics` R: tool usage analytics.
- `file_activity` R: hottest files by project.
- `export` R: export one session.
- `handoff` R: generate handoff brief.
- `generate_summary` W: summarize a session.
- `project_timeline` R: cross-tool project timeline.
- `link_sessions` R: create symlink mirror.
- `live_sessions` R: active sessions.
- `lint_config` R: lint CLAUDE/agent config.
- `project.ts` mixed: `project_move`, `project_archive`, `project_undo`, `project_move_batch` are W; `project_list_migrations`, `project_recover`, `project_review` are R.

Important mismatch: runtime also defines `manage_project_alias` in `src/index.ts` (W for add/remove, R for list), and `project.ts` expands one module into seven tools. So the **actual callable MCP surface today is 26 tools**. Phase C should port the runtime surface, not the stale “19 tools” README/module count.

## 4. HTTP client cost

`URLSession` fully covers `src/core/daemon-client.ts`: base URL, bearer auth, per-request timeout, `POST`/`DELETE` with JSON body, JSON-or-text error decoding, and `actor: "mcp"` on `project_*` routes. `macos/Engram/Core/DaemonClient.swift` already proves most of this.

Gotchas:

- Re-read `httpBearerToken` per request, matching daemon rotation behavior.
- Preserve Node fallback semantics: transport errors / 5xx may fall back; 4xx JSON envelopes should bubble.
- Keep default target at `http://127.0.0.1:3457`.
- If non-localhost binding is enabled later, consume the existing bearer token; do **not** invent auto-generation in this shim.

## 5. Bundle + ship

Put the binary at `Engram.app/Contents/Helpers/EngramMCP`. It is an auxiliary executable, not the app’s main binary, so `Helpers` is cleaner than `Contents/MacOS`.

Add a new Xcode tool target plus a sibling script such as `macos/scripts/copy-mcp-helper.sh` (or a Copy Files phase) that copies the built binary into `Contents/Helpers/`. Keep `build-node-bundle.sh` focused on `dist/`.

## 6. User migration

For this phase, switchover should be **manual/doc-only**: update `.claude/mcp.json` or rerun `claude mcp add ... /Applications/Engram.app/Contents/Helpers/EngramMCP`. No Settings toggle is needed for acceptance. `src/index.ts` stays unchanged as fallback.

## References

- Official Swift SDK: https://github.com/modelcontextprotocol/swift-sdk
- MCP SDK tiers: https://modelcontextprotocol.io/community/sdk-tiers
- MCP spec release: https://github.com/modelcontextprotocol/modelcontextprotocol/releases/tag/2025-11-25
- Claude Code MCP docs: https://docs.anthropic.com/en/docs/claude-code/mcp
