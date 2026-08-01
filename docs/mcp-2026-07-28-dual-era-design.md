# Design Doc: MCP 2026-07-28 Dual-Era Stdio Server

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-29
- **Related**: CHANGELOG "MCP 2026-07-28 dual-era protocol support
  (2026-07-29)"; `docs/mcp-swift.md`; branch
  `claude/mcp-protocol-update-cwkrxn`. Code citations are against
  `macos/EngramMCP/Core/MCPStdioServer.swift` on that branch; line numbers will
  drift.

## Problem

MCP revision 2026-07-28 is not a routine date bump. It removes the
`initialize` handshake: there is no connection-scoped negotiated protocol
version any more. A client on that revision sends
`_meta["io.modelcontextprotocol/protocolVersion"]` on every request and is
expected to discover server capabilities through a new MUST-implement
`server/discover` RPC.

`EngramMCP` only knew the handshake era. Its `initialize` path negotiated over
`"2024-11-05"`, `"2025-03-26"`, `"2025-06-18"`, `"2025-11-25"`, negotiating
unknown newer versions down to the latest it knew. A 2026-07-28 client never
reaches that path at all — it would send `server/discover` (method not found,
`-32601`) and then tool calls carrying `_meta` the server ignored. Claude
clients are adopting the revision, so the helper needs to serve it without
disturbing the clients that are still on the handshake (Codex, older Claude
Code).

## Goals / Non-goals

- Goals:
  - Serve 2026-07-28 clients correctly: `server/discover`, per-request `_meta`
    version handling, the modern result envelope, and the spec's error code for
    an unsupported version.
  - Leave every legacy response byte-identical.
  - Make the era decision explicit and per-request, with no connection state.
- Non-goals:
  - Implementing Roots, Sampling, or Logging (deprecated in 2026-07-28 and
    never implemented here).
  - Streaming/partial results (`resultType` values other than `"complete"`).
  - Any change to the tool set, tool schemas, or tool semantics.
  - HTTP/SSE transports — this helper is stdio only.

## Current state

`MCPStdioServer.run()` reads newline-delimited JSON-RPC from stdin, routes
notifications and cancellations, and dispatches the rest through `handle(_:)`.
Before this change:

- `supportedProtocolVersions` was a single flat set of the four handshake
  revisions, and `initialize` echoed a requested member or fell back to
  `latestSupportedProtocolVersion`.
- Results were emitted verbatim by `emit(jsonrpc:id:result:)`; there was no
  envelope layer.
- `_meta` on incoming requests was never read.
- Resource-not-found and other invalid-params conditions already used `-32602`.

The exact stdio bytes are pinned: `tests/fixtures/mcp-golden/` holds 30+
executable behavior snapshots owned by `macos/EngramMCPTests/EngramMCPExecutableTests.swift`,
plus `initialize.result.json` and `tools.json` generated from the Swift source
by `npm run generate:mcp-contract-fixtures`.

## Proposed design

Dual-era stdio server. Nothing is stored per connection; each request decides
its own era.

- **Version sets split in two.** `supportedProtocolVersions` keeps only the
  legacy handshake revisions. `modernProtocolVersions` holds `"2026-07-28"`.
  `advertisedProtocolVersions` is their union, newest first (date-stamped
  versions sort chronologically as strings), and is what `server/discover` and
  the unsupported-version error report.
- **Era detection.** `era(of:)` returns `.legacy` when the request has no
  `_meta["io.modelcontextprotocol/protocolVersion"]`, `.modern` when the value
  is in `modernProtocolVersions`, and `.unsupportedModern(requested:)`
  otherwise. The resulting `modern` flag is threaded through `handle`,
  `handleToolCall`, and `emitRegistryResult`. (Revised in retro PR-4: the key's
  *presence* decides the era, so a present-but-non-string value is
  `.unsupportedModern` rather than a silent demotion to legacy. See
  `docs/mcp-protocol-alignment-design.md`.)
- **Result envelope.** `emitResult(id:_:modern:cacheTTLMs:)` passes legacy
  results through untouched. For modern results, `modernResult(_:cacheTTLMs:)`
  prepends the required `resultType: "complete"` discriminator, appends the
  CacheableResult pair `ttlMs` + `cacheScope: "private"` when the method
  requires freshness hints, and appends
  `_meta["io.modelcontextprotocol/serverInfo"]` — modern clients have no
  `initialize` result to read server identity from. TTLs:
  `tools/list` 300000 (the search-mode enum flips with embedding availability),
  `prompts/list` 3600000, `resources/list` and `resources/read` 30000 (they
  churn as sessions index). `cacheScope` is always `"private"`; every payload
  is local per-user data.
- **`server/discover`.** Handled in `run()` *before* era detection, so it
  answers even with no `_meta`. That is deliberate: the spec also uses it as
  the stdio backward-compatibility probe, which is precisely the case where the
  client does not yet know the server's era. It returns `resultType`,
  `supportedVersions`, `capabilities` (`tools`/`resources`/`prompts`),
  `instructions`, `ttlMs` 3600000, `cacheScope`, and `serverInfo` in `_meta`.
- **Unsupported modern version.** `emitUnsupportedProtocolVersion` emits code
  `-32022` ("Unsupported protocol version") with
  `data: {supported: modernProtocolVersions, requested: <value>}` so the
  client can pick a version without another round trip. The
  `-32020..-32099` range is reserved by the spec; no app-specific codes there.
  (Revised in retro PR-4: this used to report `advertisedProtocolVersions`, the
  cross-era union, which advertised legacy revisions that cannot be selected
  through `_meta` at all. `server/discover` still reports the union.)
- **`initialize`.** Unchanged in the legacy era, including the negotiate-down
  for unknown versions — which now lands on the latest *legacy* revision, since
  modern revisions never negotiate through the handshake. A request that tags
  `initialize` with modern `_meta` gets `-32601`: the modern era defines no
  handshake, so there is no negotiated version to return (revised in retro
  PR-4; it used to answer with an un-enveloped legacy handshake result).
- **`ping`.** Removed from the 2026-07-28 core spec but still answered in both
  eras: an era-ambiguous liveness probe must not kill the transport, and legacy
  clients depend on it. Under `_meta` it gets the modern envelope like any
  other result.
- **Resource not found.** Already `-32602`, which is where 2026-07-28 moved it
  from `-32002`. No code change.

No schema, migration, backfill, service IPC, or UI change. `MCPToolRegistry`
and the tool handlers are untouched.

## Invariants affected

- **12. EngramMCP Is Read-Only Except Service IPC Writes** — preserved. The
  change is confined to the stdio transport/dispatch layer; no read or write
  path is added or rerouted, and `server/discover` reads only compile-time
  constants.

No new invariant is introduced. The "legacy responses stay byte-stable"
property is enforced by the existing golden-fixture gate rather than by a new
ledger entry.

## Alternatives considered

- **Modern-only server** (replace the handshake with `_meta` handling): breaks
  every client still on the handshake — Codex and older Claude Code — for a
  revision no installed client requires yet.
- **Accept `2026-07-28` through `initialize`**: nonsensical, because the modern
  era has no handshake. Only a confused client could reach it, and the reply
  would be a negotiated-version contract the revision no longer defines.
- **Store the negotiated era per connection after the first `_meta` request**:
  adds state the spec deliberately removed and makes `server/discover` (which
  may legitimately arrive first, last, or alone) ambiguous.
- **Emit the modern envelope unconditionally**: simplest code, but changes
  legacy response bytes and would break the golden fixtures and every
  handshake-era client parsing strict result shapes.

## Test plan

- New cases in `macos/EngramMCPTests/EngramMCPExecutableTests.swift`, driving
  the real executable over stdio:
  - `server/discover` with no `_meta` answers, and its pretty-printed result
    matches the generated golden.
  - A request with `_meta` at `2026-07-28` gets `resultType`, `serverInfo`
    `_meta`, and the expected `ttlMs`/`cacheScope` per method.
  - The same request without `_meta` is byte-identical to the pre-change
    response.
  - `_meta` naming an unknown version yields `-32022` with `data.supported`
    (the modern set only) and `data.requested`; a non-string version yields the
    same error with `data.requested` naming the JSON type, and a non-object
    `_meta`/`params` stays legacy (added in retro PR-4).
  - `initialize` under modern `_meta` is `-32601` (added in retro PR-4).
  - `ping` answers in both eras; the existing `initialize` version cases
    (including negotiate-down from `2999-01-01`) keep passing unchanged.
- `tests/fixtures/mcp-golden/discover.result.json`, generated from the Swift
  source by `scripts/gen-mcp-contract-fixtures.ts`. The generator extracts only
  `supportedVersions` and `instructions` from Swift; the other five discover
  fields are TypeScript literals.
- `npm run check:mcp-contract-fixtures`
  (`scripts/ci/check-mcp-contract-fixtures.sh`, run by `.github/workflows/test.yml`)
  regenerates and diffs the golden fixtures, so this cheap gate catches source
  drift in those two extracted fields, not the complete discover result.
- `EngramMCPExecutableTests.testServerDiscoverMatchesGolden` drives the real
  Swift executable and compares the complete discover result with the golden;
  it is the guard that catches drift in any of the seven fields.
- Not tested: transports other than stdio (none exist), and streaming
  `resultType` values (not implemented).

## Rollout

- Ships with the next `Engram.app` build; the helper is the bundled
  `Contents/Helpers/EngramMCP`, so users pick it up by replacing the app and
  restarting their MCP client. No service or schema rebuild, no backfill, no
  migration timing to consider.
- Legacy clients need no action: their bytes are unchanged, so a client that
  never sends `_meta` cannot tell the two builds apart.
- Revert story: the change is additive and localized to
  `MCPStdioServer.swift` plus the fixture generator. Reverting the commit
  restores the single-set handshake server; the only observable loss is
  `server/discover` returning `-32601` again.

## Risks and open questions

- **Risk (low/medium): a client sends `_meta` version on a legacy connection.**
  It would get the modern envelope mid-session. Accepted — a client that sends
  the modern key is asserting modern semantics, and the extra fields are
  additive.
- **Risk (low/low): TTL values are judgement calls.** 300000/3600000/30000 are
  hints, not guarantees; a stale `tools/list` for up to five minutes after
  embedding availability flips is the worst case.
- **Open question:** whether to advertise `2026-07-28` in the `initialize`
  reply's capabilities for clients that probe both ways. Currently not done,
  since the revision defines no such field.
- **Open question:** if a later revision reuses `_meta` with a different key,
  era detection keys off a single well-known name and will need extending.
