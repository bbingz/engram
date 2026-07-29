# Design Doc: Remote Read-Only MCP Endpoint (2026-07-28 Streamable HTTP)

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-29
- **Related**: CHANGELOG "Remote read-only MCP endpoint over Streamable HTTP
  (2026-07-29)"; `docs/mcp-swift.md`; `docs/mcp-2026-07-28-dual-era-design.md`
  (the stdio helper's dual-era work this builds on); `docs/remote-offload.md`
  and `docs/remote-archive-v2.md` for the server this endpoint is mounted in;
  branch `claude/mcp-protocol-update-cwkrxn`, commit `eef22db`. Code citations
  are against `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift` and
  `macos/EngramRemoteServer/Core/EngramRemoteServerConfig.swift` at that commit;
  line numbers will drift.

## Problem

Engram's MCP surface is bound to the workstation. `EngramMCP` is a stdio helper
inside `Engram.app`, so an MCP client can only reach Engram's data if it runs on
the same Mac as the app, the service socket, and `~/.engram/index.sqlite`. A
client on a phone, on another machine, or in a hosted agent runtime has no path
to any of it.

Two things changed that make a remote endpoint worth building now:

1. **MCP 2026-07-28 removed the `initialize` handshake.** Every request carries
   its own `_meta["io.modelcontextprotocol/protocolVersion"]`, and
   `server/discover` replaces the handshake as the discovery mechanism. That
   makes a *stateless* HTTP MCP server viable: no session identifiers, no
   server-side connection state, no resumable event stream to implement. The
   pre-2026-07-28 Streamable HTTP transport required all of it.
2. **The Mac mini already holds the data.** `EngramRemoteServer` runs on the
   mini under launchd (see `docs/remote-offload.md`) and, with archive v2
   enabled, stores archived captures — manifests, chunked encrypted objects,
   and receipts — for every machine that offloads to it
   (`docs/remote-archive-v2.md`). Reading an archived transcript today means
   driving the raw `/v2/...` blob routes by hand and reassembling chunks.

So the missing piece is small: expose the archive store the mini already serves
through the protocol MCP clients already speak, rather than standing up a second
Engram instance somewhere.

## Goals / Non-goals

- Goals:
  - Serve MCP 2026-07-28 clients over Streamable HTTP from
    `EngramRemoteServer`, read-only, against the archive v2 store.
  - Enumerate archived machines and captures, and read an archived transcript
    without downloading the whole capture.
  - Stay off by default, behind its own credential, and impossible to enable
    without archive v2.
  - Add no dependency the remote-server target is not already allowed to have.
- Non-goals:
  - Legacy-era (handshake + `Mcp-Session-Id`) HTTP MCP support.
  - Any write, delete, or mutation tool. The endpoint is read-only.
  - Search, ranking, embeddings, or anything that needs `index.sqlite`. The mini
    has no Engram index.
  - Browser clients, OAuth, or public-internet exposure. The server binds
    loopback or Tailscale only (`isAllowedArchiveBindAddress`).
  - SSE streaming, resumability, or server-initiated notifications.
  - Replacing the stdio helper. `EngramMCP` remains the primary, full-featured
    MCP surface.

## Current state

`EngramRemoteServerApp.buildRouter()` mounts three route groups on a Hummingbird
router: the legacy v1 bundle routes, and — when `config.archiveV2` is set —
`ArchiveRoutes.mount(...)` for the v2 object/manifest/receipt/machines/receipts/
status routes. Auth is a bearer token compared through
`EngramRemoteServerApp.constantTimeEquals` (SHA-256 digests, so neither length
nor bytes leak through timing). Archive v2 carries its own token and its own
at-rest key, both required to be distinct from the v1 pair.

Constraints that shaped this design and were already in place:

- `testRemoteServerCoreIncludesOnlyPureArchiveWireSources`
  (`macos/EngramRemoteServerCoreTests/ArchiveConfigTests.swift`) asserts the
  `EngramRemoteServerCore` target in `macos/project.yml` pulls in only the pure
  archive wire sources and explicitly **not** `EngramCoreRead` or
  `EngramCoreWrite`.
- `scripts/check-archive-v2-safety.sh` scans this target for `router.delete`
  registrations and fails on any that is not on its exact allowlist (the single
  legacy `/v1/bundles/:key` route plus the two explicit v2 405 guards).
- `ArchiveRemoteTelemetryObservation`
  (`macos/EngramRemoteServer/Core/ArchiveRemoteTelemetryStore.swift`) clamps
  every recorded observation to fixed allowlists: endpoints
  `object`/`manifest`/`receipt`/`machines`/`receipts`/`status`/`unknown`, and
  methods `GET`/`HEAD`/`PUT`/`DELETE`.
- The stdio helper `EngramMCP` is dual-era as of `d1bbb4e`; its version sets and
  envelope shape are the reference for what "modern" means here.

## Proposed design

One new endpoint, entirely contained in the existing files: `MCPRemoteEndpoint`
at the bottom of `EngramRemoteServerApp.swift`, plus `EngramRemoteMCPConfig` and
its env parsing in `EngramRemoteServerConfig.swift`.

### Configuration and gating

`ENGRAM_REMOTE_MCP_ENABLED` accepts `0`/`1`/unset only; anything else throws
`invalidMCPEnabled` rather than being coerced. When enabled:

- archive v2 must also be enabled (`mcpRequiresArchive`) — the endpoint serves
  archive data and has nothing else to serve;
- `ENGRAM_REMOTE_MCP_TOKEN` is required (`missingMCPToken`);
- that token must differ from both `ENGRAM_REMOTE_TOKEN` and
  `ENGRAM_REMOTE_ARCHIVE_TOKEN` (`mcpTokenMustBeDistinct`).

Default is off: unset `ENGRAM_REMOTE_MCP_ENABLED` produces `mcp == nil` and
`buildRouter()` never mounts the endpoint. Because archive v2 is a prerequisite,
the endpoint inherits its bind-address restriction (loopback or Tailscale
`100.64.0.0/10` / `fd7a:115c:a1e0::/48`).

### Transport and era

Modern era only. There is no `initialize` path, no `Mcp-Session-Id`, and no
per-connection state:

- `POST /mcp` — the only method that does work. Every request must carry
  `_meta["io.modelcontextprotocol/protocolVersion"]`, and the only accepted
  value is `2026-07-28`.
- `GET /mcp` — authenticated, then `405` with `Allow: POST`. Pre-2026-07-28
  Streamable HTTP clients open a GET stream to receive server-initiated
  messages; this endpoint has none, so it refuses per the spec's compatibility
  guidance.
- `DELETE /mcp` — deliberately unrouted, so it falls through to `404`. See
  Deviations.
- Every response is a single JSON object with `Content-Type: application/json`.
  SSE is never used; the spec permits a JSON-object response for any request.
- Requests with no `id` (notifications) are accepted and dropped with `202`. The
  2026-07-28 core protocol defines no client-to-server notifications over
  Streamable HTTP.

### Request validation order

1. **Bearer auth** — `Authorization: Bearer <ENGRAM_REMOTE_MCP_TOKEN>`, compared
   with the existing constant-time helper. Failure → `401` with
   `WWW-Authenticate: Bearer`.
2. **Origin** — *any* `Origin` header at all → `403`, JSON-RPC `-32600`. The
   spec requires validating `Origin` against DNS rebinding; since this endpoint
   has no browser clients, the strictest possible policy is also the simplest
   correct one.
3. **Body limit** — `1 MiB`; overflow → `413` with `-32600`.
4. **Parse** — non-JSON → `400` with `-32700`; missing `method` → `400` with
   `-32600`.
5. **Header/body agreement** — `MCP-Protocol-Version` and `Mcp-Method` are
   required on every request, and `Mcp-Name` on `tools/call`. Each is compared
   against the corresponding body value; any disagreement or absence →
   `400` with `-32020` and a message naming the field. `Mcp-Name` accepts the
   `=?base64?...?=` sentinel form for values that are not plain ASCII.
6. **Version** — a `_meta` version other than `2026-07-28` → `400` with
   `-32022`, `data.supported = ["2026-07-28"]`, `data.requested = <value>`, so
   the client can react without a second round trip.
7. **Dispatch** — `server/discover`, `tools/list`, `tools/call`. Anything else,
   including `subscriptions/listen`, → `404` with `-32601`.

Validating the headers *against the body* rather than merely requiring them is
the point: the header trio exists so proxies and gateways can route and audit
MCP traffic without parsing bodies, and that is only sound if the two agree.

### Result envelope

Same shape as the stdio helper's modern era, independently implemented:
`resultType: "complete"` first, then the body, then `ttlMs` +
`cacheScope: "private"` where a freshness hint applies, then
`_meta["io.modelcontextprotocol/serverInfo"]` last. `server/discover` and
`tools/list` both carry `ttlMs` of one hour — the tool set here is a compile-time
constant, unlike the stdio helper's, whose `tools/list` varies with embedding
availability. `cacheScope` is `private` because every payload is the owner's own
archived data.

JSON is emitted through `MCPRemoteWireValue`, a small insertion-ordered JSON
value type local to this target. It duplicates the stdio helper's
`OrderedJSONValue` on purpose: sharing that type would drag `EngramCore` into
`EngramRemoteServerCore` and fail the purity test.

### Tools

Three, all annotated `readOnlyHint: true`, `openWorldHint: false`, with
`additionalProperties: false` schemas and explicit unknown-argument rejection:

- **`archive_list_machines`** (`cursor`, `limit` ≤ 100) — machine IDs that have
  archived sessions on this server, paged with `nextCursor`.
- **`archive_list_captures`** (`machine_id` required, `cursor`, `limit`) — one
  entry per capture with `manifestSHA256` and `receiptSHA256`, enriched from the
  receipt with `sessionID`, `captureID`, `rawByteCount`, and `storedAt` when the
  receipt decodes. The `sessionID` + manifest digest pair is what makes the
  result actionable: the digest is the handle `archive_get_session` takes.
- **`archive_get_session`** (`manifest_sha256` required, `offset` ≥ 0,
  `max_bytes` ≤ 1 MiB, default 256 KiB) — reads the manifest, walks its chunks in
  ordinal order, and reassembles only the requested byte window. Each chunk's
  `rawByteCount` is known from the manifest, so chunks entirely before `offset`
  or entirely after `offset + max_bytes` are skipped **without being fetched or
  decrypted**. The result carries `structuredContent` with `sessionID`, `source`,
  `locator`, `machineID`, `captureID`, `capturedAt`, `totalBytes`, `offset`,
  `byteCount`, and `nextOffset` when more remains — so an agent can page a large
  transcript deterministically instead of guessing.

Tool-level failures return `isError: true` with a machine-readable
`structuredContent.code` (`invalidArguments`, `notFound`, `unknownTool`,
`archiveStoreError`, `internal`) rather than a JSON-RPC error, which is the
2026-07-28 convention for tool execution problems.

No schema change, no migration, no backfill, no service IPC change, no UI change.

## Invariants affected

- **1. Single-Writer Discipline** — preserved trivially. The endpoint performs
  no writes: it only calls `ArchiveStore.listMachines`, `listReceipts`,
  `getReceipt`, `getManifest`, and `getObject`.
- **8. Service Socket Security** — untouched. This is a separate process on a
  separate machine with its own transport; the local Unix socket is not
  involved.
- **12. EngramMCP Is Read-Only Except Service IPC Writes** — not literally about
  this target (it covers the stdio helper), but the same posture is applied
  here, and more strictly: there is no IPC write path at all. If the ledger is
  later extended to cover remote MCP, this endpoint already satisfies the
  stronger form.

No new invariant is introduced. The two red lines this design depends on —
"no `EngramCoreRead`/`EngramCoreWrite` in `EngramRemoteServerCore`" and "no
DELETE routes in the remote-server target" — are already enforced by
`testRemoteServerCoreIncludesOnlyPureArchiveWireSources` and
`scripts/check-archive-v2-safety.sh` respectively.

## Alternatives considered

- **Dual-era HTTP MCP (handshake + sessions), mirroring the stdio helper.**
  Rejected. The pre-2026-07-28 Streamable HTTP transport needs `Mcp-Session-Id`
  issuance and validation, session expiry, `DELETE` for session teardown, an SSE
  GET stream, and `Last-Event-ID` resumability — a large stateful surface, in a
  target whose entire value is being small and auditable, for exactly zero
  current legacy-HTTP clients. This server has never had an MCP client of any
  era.
- **Reuse `MCPToolRegistry` and the GRDB read layer in the remote target.**
  Rejected twice over: `testRemoteServerCoreIncludesOnlyPureArchiveWireSources`
  forbids `EngramCoreRead`/`EngramCoreWrite` dependencies in
  `EngramRemoteServerCore`, and the mini has no `index.sqlite` to read anyway —
  it stores encrypted archive blobs, not an Engram index. The tool set had to be
  archive-shaped, not a copy of the stdio helper's 27 tools.
- **New source files (`MCPRemoteEndpoint.swift`, `MCPRemoteWire.swift`).**
  Rejected. `Engram.xcodeproj` is generated by `xcodegen` from
  `macos/project.yml`, and `xcodegen` is not available in the implementation
  environment; adding files would either leave the pbxproj un-regenerated
  (drift, and the new code silently absent from the compiled target) or require
  hand-editing generated project state. Extending the two existing files keeps
  the project file untouched. The cost is a longer
  `EngramRemoteServerApp.swift`; the split can be done in an environment that
  can run `xcodegen`.
- **Serve raw archive routes and let the client reassemble chunks.** Rejected —
  that is the status quo, and it pushes chunk ordering, window arithmetic, and
  digest bookkeeping into every client.
- **Return whole transcripts from `archive_get_session`.** Rejected. Archived
  captures routinely exceed any sane single response; windowing with
  `nextOffset` bounds memory on both ends and lets the server skip chunks it
  never has to decrypt.

## Deviations from the spec

Two, both deliberate:

1. **`DELETE /mcp` returns `404`, not `405`.** The spec SHOULDs a `405` for
   unsupported methods on the MCP endpoint. `scripts/check-archive-v2-safety.sh`
   fails the build on any `router.delete` registration in this target outside
   its exact allowlist, including one that only returns `405` — the gate matches
   on *registration*, and its purpose is to keep destructive verbs from ever
   being wired into the archive-serving target. Adding a route to satisfy a
   SHOULD would require widening a safety gate whose narrowness is the whole
   point. An unrouted `DELETE` falls through to the router's `404`, which is a
   correct HTTP answer for a path that does not exist for that method, and
   costs a client nothing: DELETE is meaningful only for session teardown, and
   this endpoint has no sessions. The safety gate wins over the spec's SHOULD.
2. **`subscriptions/listen` returns `-32601`.** The endpoint advertises no
   change notifications and holds no per-client state, so there is nothing to
   subscribe to. `-32601` from the default dispatch branch, with the `404`
   status the spec pairs with unknown methods, is the honest answer.

## Security notes

- **Token separation.** A third credential, refused at startup if it collides
  with the v1 or archive tokens. Handing an agent runtime the ability to *read*
  archived transcripts must not hand it the ability to *write* to the archive or
  to the legacy v1 store.
- **Origin refusal.** Any `Origin` header is rejected. The endpoint is for
  programmatic clients over Tailscale, never a browser, so DNS-rebinding
  hardening costs nothing here.
- **At-rest key posture is unchanged.** The server already holds the archive
  at-rest key — the documented, deliberate decision recorded in
  `docs/remote-archive-v2.md` and `docs/remote-offload.md`; this is not a
  zero-knowledge design. `archive_get_session` therefore adds no new key
  exposure: it decrypts with a key the process already has in memory for the
  existing routes.
- **It does widen the read audience.** This is the real security delta, and it
  should be stated plainly: before, reading an archived transcript required the
  archive token plus manual chunk reassembly; now anyone holding
  `ENGRAM_REMOTE_MCP_TOKEN` can read any archived transcript on the server, from
  anywhere on the tailnet, through a single tool call. That is the intended
  capability, but it is a capability — treat the MCP token as equivalent to
  "read every archived session on this mini", rotate it independently, and keep
  the endpoint off unless it is being used.
- **Bounded inputs.** 1 MiB request bodies, `limit` ≤ 100, `max_bytes` ≤ 1 MiB,
  strict `additionalProperties: false` with explicit unknown-key rejection, and
  type/range checks on every numeric argument.
- **No telemetry, and therefore no request log.** See Risks.

## Test plan

New cases, added to the existing files so the Xcode project stays unregenerated:

- `macos/EngramRemoteServerCoreTests/ArchiveConfigTests.swift`:
  - `ENGRAM_REMOTE_MCP_ENABLED` unset/`0` → `mcp == nil`; any other value →
    `invalidMCPEnabled`.
  - Enabled without archive v2 → `mcpRequiresArchive`.
  - Enabled without a token → `missingMCPToken`.
  - Token equal to the v1 token, and to the archive token → both
    `mcpTokenMustBeDistinct`.
  - Enabled + valid → `mcp?.bearerToken` matches.
- `macos/EngramRemoteServerCoreTests/ArchiveRouteTests.swift`, driving the built
  router:
  - Endpoint absent when disabled (`POST /mcp` → `404`); present when enabled.
  - Wrong/absent bearer → `401`; archive or v1 token on `/mcp` → `401`; MCP
    token on `/v2/...` → `401`.
  - Any `Origin` header → `403` with `-32600`.
  - `GET /mcp` → `405` with `Allow: POST`; `DELETE /mcp` → `404` (pinning the
    documented deviation so it cannot regress silently).
  - `server/discover` → `supportedVersions == ["2026-07-28"]`, `tools`
    capability, `resultType`, `ttlMs`, `cacheScope`, `serverInfo` in `_meta`.
  - `tools/list` → the three tools, `readOnlyHint: true`, stable key order.
  - Header matrix: missing `MCP-Protocol-Version`, missing `Mcp-Method`,
    mismatched `Mcp-Method`, missing `Mcp-Name` on `tools/call`, mismatched
    `Mcp-Name`, and the base64-sentinel `Mcp-Name` accepted → `-32020` for each
    failure, success for the sentinel.
  - `_meta` naming another revision → `-32022` with `data.supported` /
    `data.requested`; missing `_meta` → `-32020`.
  - Unknown method and `subscriptions/listen` → `404` with `-32601`.
  - Notification (no `id`) → `202` with an empty body.
  - Over-size body → `413`; malformed JSON → `400` with `-32700`.
  - Tool behavior against a seeded archive store: machines and captures paging
    with `nextCursor`; captures carrying `sessionID` + manifest digest;
    `archive_get_session` full read, windowed read at a chunk boundary, a
    window spanning three chunks, `offset` past the end (empty window, no
    `nextOffset`), and an unknown digest → `isError` with
    `structuredContent.code == "notFound"`.
  - Unknown argument keys and out-of-range `limit`/`max_bytes` → `isError` with
    `invalidArguments`.
- Gates that must keep passing unchanged: `scripts/check-archive-v2-safety.sh`
  (no new DELETE registration) and
  `testRemoteServerCoreIncludesOnlyPureArchiveWireSources` (no new target
  dependency).
- CI: all of the above runs in the existing `remote-server-swift` lane in
  `.github/workflows/test.yml`, which regenerates the project with `xcodegen`
  and runs the `EngramRemoteServerCore` scheme.
- Intentionally not tested: TLS (terminated upstream or handled by Tailscale),
  SSE/resumability (not implemented), and legacy-era HTTP MCP (not supported).

## Rollout

- Ships with the next remote-server package built for the mini. Deploy is the
  existing flow in `docs/remote-offload.md`: build the package, install it,
  restart the launchd job.
- Enabling is operator-side and additive. Put the two new variables into the
  same secrets env file the launchd wrapper already sources
  (`secrets/archive-v2.env`), alongside the archive credentials:

  ```sh
  ENGRAM_REMOTE_MCP_ENABLED=1
  ENGRAM_REMOTE_MCP_TOKEN=<a fresh random token, distinct from the other two>
  ```

  The packaging templates and the launchd plist need no change and must not
  change — the wrapper already sources that file.
- Client side, one command per client; see `docs/mcp-swift.md`.
- Revert story: unset `ENGRAM_REMOTE_MCP_ENABLED` and restart the job — the
  route is not mounted and the server is byte-for-byte its previous self. A code
  revert is equally clean: the change is additive, confined to two files, and
  touches no existing route, no schema, and no stored data.

## Risks and open questions

- **Risk (medium/medium): the MCP token becomes a broad read credential.**
  Anyone holding it can read every archived transcript on the mini. Mitigated by
  default-off, token separation, and tailnet-only binding; not mitigated by any
  per-machine or per-session scoping, which does not exist yet.
- **Risk (medium/low): no telemetry, so no operational visibility.**
  `ArchiveRemoteTelemetryObservation` allowlists neither the `POST` method nor
  an `mcp` endpoint, so MCP traffic is invisible in the status snapshot. Chosen
  over widening the allowlists in the same change, since those allowlists are
  themselves a safety mechanism. Until it is extended, an operator cannot tell
  from telemetry whether the endpoint is being used or abused.
- **Risk (low/medium): a spec revision after 2026-07-28.** The endpoint hard-codes
  a single supported version. A client on a newer revision gets a clean `-32022`
  with `data.supported`, so it fails legibly rather than mysteriously — but it
  fails.
- **Risk (low/low): `EngramRemoteServerApp.swift` is now over 1,100 lines.** A
  file-split is blocked only by `xcodegen` availability, not by design.
- **Open question:** should `archive_get_session` expose a `session_id` lookup
  in addition to `manifest_sha256`? Today a client must page
  `archive_list_captures` to map a session to a digest. A reverse index would
  need either a store-side map or a full scan.
- **Open question:** what does an authenticated-but-idle endpoint cost on the
  mini? Nothing is held open, but the endpoint has not been load-tested.

## Future work

- **Extend the telemetry allowlists** to include a `POST` method and an `mcp`
  endpoint, so remote MCP shows up in the archive status snapshot alongside the
  v2 routes.
- **Index and search on the mini.** The natural next step is a real Engram index
  next to the archive so the remote endpoint can serve `search_sessions` and
  friends instead of digest-addressed reads. That requires
  `EngramCoreRead` in the remote target — i.e. relaxing or splitting the purity
  test — and is a much larger design.
- **OAuth / client ID metadata discovery** if this is ever fronted for
  claude.ai-facing deployments. Bearer tokens in a config file are appropriate
  for a private tailnet and not for anything broader.
- **MCP tunnels** so a client outside the tailnet can reach the endpoint without
  putting it on the public internet.
- **Per-machine or per-source scoping** on the MCP token, to narrow the read
  audience below "everything archived here".
