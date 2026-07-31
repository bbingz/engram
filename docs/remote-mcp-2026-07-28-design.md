# Design Doc: Remote Read-Only MCP Endpoint (Dual-Era Streamable HTTP)

- **Status**: Implemented (#278), revised 2026-07-29 after real-client testing —
  see Revision below.
- **Owner**: unassigned
- **Date**: 2026-07-29
- **Filename**: kept as `remote-mcp-2026-07-28-design.md` because other docs and
  the code link to it. The title no longer says "2026-07-28" because the endpoint
  is no longer single-revision.
- **Related**: CHANGELOG "Remote read-only MCP endpoint over Streamable HTTP
  (2026-07-29)" (what #278 shipped) and "Dual-era remote MCP endpoint and
  transcript visibility fix (2026-07-29)" (this revision);
  `docs/mcp-swift.md`; `docs/mcp-2026-07-28-dual-era-design.md` (the stdio
  helper's dual-era work this builds on); `docs/remote-offload.md` and
  `docs/remote-archive-v2.md` for the server this endpoint is mounted in;
  branch `claude/mcp-protocol-update-cwkrxn`, commit `eef22db` for the original
  endpoint, branch `claude/remote-mcp-dual-era-hvbfrk` for the dual-era
  revision. Code citations are against
  `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift` and
  `macos/EngramRemoteServer/Core/EngramRemoteServerConfig.swift`; line numbers
  will drift.

## Revision (2026-07-29): the modern-only premise was false

The first version of this design made the endpoint **modern-era only**, on a
premise that end-to-end testing on a real Mac falsified. Legacy support was
rejected "for exactly zero current legacy-HTTP clients", because "this server has
never had an MCP client of any era". The client we actually wanted to point at it
is legacy-era. Claude Code 2.1.220 opens an HTTP MCP connection with

```json
{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{}},"clientInfo":{"…":"…"}},"jsonrpc":"2.0","id":0}
```

— no `MCP-Protocol-Version` header and no `_meta` — then
`notifications/initialized`, then `tools/list`, which does carry
`mcp-protocol-version: 2025-11-25` but still no `_meta` and no `Mcp-Method`.
Against the modern-only endpoint the first POST got
`400 -32020 Header mismatch: MCP-Protocol-Version header is required`:
spec-correct for a 2026-07-28 server, and completely unusable.

Two corrections follow. Both are applied to the sections below; the original
reasoning is kept visible rather than rewritten away.

1. **The endpoint is now dual-era and stateless in both eras.** See Transport
   and era. Era is decided per request, and the legacy path mints no session.
2. **The Alternatives rejection was wrong in its cost estimate, not only in its
   premise.** It priced legacy support as `Mcp-Session-Id`
   issuance/validation/expiry, `DELETE` teardown, an SSE `GET` stream, and
   `Last-Event-ID` resumability — "a large stateful surface". Every one of those
   is optional. `Mcp-Session-Id` is a MAY in all four legacy revisions; a server
   that never returns one on `initialize` is a server a client must not send one
   to, and teardown, the standalone GET stream, and resumability all fall away
   with it. What is left is `initialize` + `notifications/initialized` + `ping` +
   `tools/list` + `tools/call` over plain POST: about 40 lines, no state, no new
   route. Rejecting legacy support on a statefulness argument was an
   overestimate, and it was checkable in advance.

A third finding is not about eras at all. **Claude Code drops the `content`
block when a tool result also carries `structuredContent`.** Verified with an
isolated probe MCP server that returned a distinct marker string in each field:
only the `structuredContent` marker reached the model. `archive_get_session`
carried the transcript **only** in `content[0].text`, so the transcript never
reached the model and the tool was effectively unusable — the one tool whose
entire output is unstructured text was the one tool that could not deliver it.
The transcript is now duplicated into `structuredContent["text"]`. The other two
tools were unaffected because `toolSuccess` already puts the same JSON in both
places, which is exactly why the bug survived the modern-era test matrix.

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
   makes a *stateless* HTTP MCP server the only shape available in that
   revision, which is what prompted the design. (The original text went further
   and claimed the pre-2026-07-28 transport *required* session identifiers,
   server-side connection state, and a resumable event stream. It does not —
   those are all MAYs. See Revision. Statelessness is a property this endpoint
   chooses in both eras, not one 2026-07-28 grants it.)
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
  - Serve MCP over Streamable HTTP from `EngramRemoteServer`, read-only, against
    the archive v2 store — for 2026-07-28 clients **and** for the legacy-era
    clients that actually ship today (revised 2026-07-29).
  - Work with an unmodified `claude mcp add --transport http` client out of the
    box, with no protocol flags or client patches (revised 2026-07-29).
  - Stay stateless in both eras: no session identifier is minted, echoed, or
    required.
  - Enumerate archived machines and captures, and read an archived transcript
    without downloading the whole capture.
  - Stay off by default, behind its own credential, and impossible to enable
    without archive v2.
  - Add no dependency the remote-server target is not already allowed to have.
- Non-goals:
  - `Mcp-Session-Id` sessions, session teardown, or any per-connection state, in
    either era. Legacy *methods* are served; legacy *sessions* are not.
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
- The stdio helper `EngramMCP` is dual-era as of `d1bbb4e`; its version sets,
  envelope shape, and per-request era detection are the reference for what
  "modern" and "legacy" mean here.

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

**Dual-era and stateless in both eras** (revised 2026-07-29 — the original
design was modern-only; see Revision). There is no `Mcp-Session-Id` and no
per-connection state on either path:

- `POST /mcp` — the only method that does work, for both eras.
- `GET /mcp` — authenticated, then `405` with `Allow: POST`. Legacy clients may
  open a standalone GET stream to receive server-initiated messages; this
  endpoint never initiates any (no sampling, no elicitation, no roots, no
  logging, no change notifications), so it refuses the stream; a legacy client is
  expected to treat the refusal as "no server-to-client channel here" and carry
  on over POST. The captured Claude Code traffic is POST-only and the client works
  against the endpoint end to end, so whatever it does with GET, the refusal costs
  it nothing. The refusal is no longer justified by "modern-only"; it is justified
  by having nothing to push.
- `DELETE /mcp` — deliberately unrouted, so it falls through to `404`. See
  Deviations. With no sessions in either era there is nothing to tear down.
- Every response is a single JSON object with `Content-Type: application/json`.
  SSE is never used; the spec permits a JSON-object response for any request in
  both eras.
- Requests with no `id` (notifications) are accepted and dropped with `202`,
  before the era split. That is what answers a legacy client's
  `notifications/initialized`, and it is also correct for the modern era, whose
  core protocol defines no client-to-server notifications over Streamable HTTP.

#### Era detection

One rule, evaluated per request, with nothing remembered between requests:

> `params._meta["io.modelcontextprotocol/protocolVersion"]` **present** →
> modern era. **Absent** → legacy era.

Presence of the key, not its value: an unknown value is a modern-era `-32022`,
not a demotion to legacy. This is the same rule the stdio helper uses
(`MCPStdioServer.era(of:)`), which keeps one mental model across both MCP
surfaces. It is also the only rule available without state — the era of the
current POST cannot depend on an earlier one, because the server does not know
which connection an earlier one was on.

Consequences worth stating: a legacy client is never asked for `_meta` or for
the modern header trio, and a modern client is never offered `initialize`. A
modern client that violated the spec by omitting `_meta` would be served the
legacy path and would work anyway; that is a benign failure mode, not a
supported configuration.

#### Legacy era

Revisions served: `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25` — the
same legacy set as the stdio helper. Methods:

- `initialize` — returns `protocolVersion` (the requested value if it is in the
  legacy set, otherwise negotiated down to `2025-11-25`), a `tools` capability,
  `serverInfo`, and `instructions`. An unknown newer revision negotiates down
  rather than failing the connection, matching the stdio helper.
- `notifications/initialized` — has no `id`, so it is absorbed by the
  notification branch above (`202`, empty body).
- `ping` — empty result. Cheap, and a liveness probe can arrive era-ambiguous.
- `tools/list` — `{"tools": [...]}`, the same three definitions the modern era
  serves.
- `tools/call` — the same three implementations the modern era calls.
- Anything else — HTTP `200` with a JSON-RPC `-32601` body. The modern era's
  `404`-for-unknown-method rule is a 2026-07-28 addition that lets a client
  distinguish a modern server from a legacy one; applying it to a legacy client
  would be a transport-level surprise where an ordinary JSON-RPC error is
  expected.

Legacy results are **unwrapped**: no `resultType`, no `ttlMs`/`cacheScope`, no
`_meta` server identity. Legacy clients do not expect those fields, and a legacy
client reads server identity from the `initialize` result, where it already is.

**No session, deliberately.** `initialize` returns no `Mcp-Session-Id`, so a
conforming client sends none, and none is ever validated or expired. Every POST
therefore stands alone in the legacy era exactly as in the modern one — the
server has no table of connections, nothing to garbage-collect, and no way for a
restart to invalidate a client's state.

#### Modern era

Unchanged from the original design: `_meta` version must be `2026-07-28`, the
header trio is validated against the body, results are wrapped in the
2026-07-28 envelope, and unknown methods (including `subscriptions/listen`) get
`404` with `-32601`.

One deliberate asymmetry with the stdio helper: `server/discover` still reports
`supportedVersions: ["2026-07-28"]` — the modern set only, not the union across
eras that the stdio helper advertises. It is not wrong for its audience (only a
modern client can call `server/discover` here, and only the modern revision is
usable from one), but it does mean the discovery result understates what the
endpoint serves. Widening it to the union is a candidate follow-up, not a fix
this revision makes.

### Request validation order

Steps 1–4 are era-independent; the era split happens at step 5.

1. **Bearer auth** — `Authorization: Bearer <ENGRAM_REMOTE_MCP_TOKEN>`, compared
   with the existing constant-time helper. Failure → `401` with
   `WWW-Authenticate: Bearer`.
2. **Origin** — *any* `Origin` header at all → `403`, JSON-RPC `-32600`. The
   spec requires validating `Origin` against DNS rebinding; since this endpoint
   has no browser clients, the strictest possible policy is also the simplest
   correct one.
3. **Body limit** — `1 MiB`; overflow → `413` with `-32600`.
4. **Parse** — non-JSON → `400` with `-32700`; missing `method` → `400` with
   `-32600`; missing `id` → `202` (notification, dropped).
5. **Era split** — `_meta["io.modelcontextprotocol/protocolVersion"]` absent →
   the legacy dispatch above, and steps 6–8 do not apply. Present → continue.
6. **Header/body agreement** (modern only) — `MCP-Protocol-Version` and
   `Mcp-Method` are required on every request, and `Mcp-Name` on `tools/call`.
   Each is compared against the corresponding body value; any disagreement or
   absence → `400` with `-32020` and a message naming the field. `Mcp-Name`
   accepts the `=?base64?...?=` sentinel form for values that are not plain
   ASCII.
7. **Version** (modern only) — a `_meta` version other than `2026-07-28` → `400`
   with `-32022`, `data.supported = ["2026-07-28"]`, `data.requested = <value>`,
   so the client can react without a second round trip.
8. **Dispatch** (modern only) — `server/discover`, `tools/list`, `tools/call`.
   Anything else, including `subscriptions/listen`, → `404` with `-32601`.

Validating the headers *against the body* rather than merely requiring them is
the point: the header trio exists so proxies and gateways can route and audit
MCP traffic without parsing bodies, and that is only sound if the two agree. It
applies only to the modern era because only the modern era defines the trio —
Claude Code sends `mcp-protocol-version` on some legacy requests and not others,
and neither is a protocol error there.

### Result envelope

Modern era only. Same shape as the stdio helper's modern era, independently
implemented: `resultType: "complete"` first, then the body, then `ttlMs` +
`cacheScope: "private"` where a freshness hint applies, then
`_meta["io.modelcontextprotocol/serverInfo"]` last. `server/discover` and
`tools/list` both carry `ttlMs` of one hour — the tool set here is a compile-time
constant, unlike the stdio helper's, whose `tools/list` varies with embedding
availability. `cacheScope` is `private` because every payload is the owner's own
archived data. Legacy results skip the envelope entirely (see Legacy era), so
the wrapping is applied at emit time per era rather than inside the shared
result builders.

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
  `max_bytes` ≤ 1 MiB, default 256 KiB) — calls
  `ArchiveStore.readSourceWindow(manifestDigest:offset:maxBytes:)`, which
  authenticates the manifest envelope, walks its chunks in ordinal order
  accumulating `rawByteCount`, and reassembles only the requested byte window.
  Chunks entirely before `offset` or entirely after `offset + max_bytes` are
  skipped **without being fetched or decrypted**; the chunks that are fetched are
  verified against the manifest's `rawByteCount` and `rawSHA256`. Corrected
  2026-07-31 (retro PR-2, F01): this guarantee was false until then, because the
  tool went through `getManifest`, whose `wholeSourceSHA256` fold reads every
  chunk. That fold is deliberately **not** on the windowed path — it is only
  computable by reading the whole source — so the served bytes are covered by
  envelope AEAD plus per-chunk digests rather than by a whole-source digest. See
  `docs/archive-windowed-read-design.md`. `GET /v2/archive/manifests/{digest}`
  keeps the full check.
  The result carries `structuredContent` with `sessionID`, `source`,
  `locator`, `machineID`, `captureID`, `capturedAt`, `totalBytes`, `offset`,
  `byteCount`, and `nextOffset` when more remains — so an agent can page a large
  transcript deterministically instead of guessing — plus `text`, the transcript
  window itself (see below). The window is snapped to UTF-8 scalar boundaries
  before it is decoded (retro PR-2, F18), so a multibyte character is never split
  across pages: `offset` is the **effective** start of the returned text (equal to
  the requested offset unless the caller aimed inside a character), and
  `nextOffset` advances from the snapped end, so concatenated pages reproduce the
  source byte-for-byte. A window too small to hold one whole scalar is returned
  unsnapped so paging still advances, and genuinely invalid stored bytes still
  repair to U+FFFD.

Tool-level failures return `isError: true` with a machine-readable
`structuredContent.code` (`invalidArguments`, `notFound`, `unknownTool`,
`archiveStoreError`, `internal`) rather than a JSON-RPC error, which is the
2026-07-28 convention for tool execution problems. The human-readable message is
in both `content[0].text` and `structuredContent.message`, for the same reason as
below.

#### The transcript must be inside `structuredContent`

Added 2026-07-29. **Claude Code surfaces only `structuredContent` when a tool
result carries both it and `content`**: verified with an isolated probe MCP server
that returned a different marker string in each field, of which only the
`structuredContent` marker reached the model. `archive_get_session` originally
put the transcript in `content[0].text` alone, with `structuredContent` holding
just the metadata — so the transcript never reached the model at all, and the
tool was silently useless in the exact client this endpoint exists to serve.

The fix is to append the window to `structuredContent` as `text` while keeping
the `content` block, so clients that read either field get the transcript — which
is the spirit of the spec's guidance that a structured result should still carry
text content for clients that ignore structure. The other two tools were never
affected: `toolSuccess`
serializes the same structured object into both fields, so their payload was
always reachable — which is precisely why every modern-era test passed while the
one tool that mattered most did not work.

The cost is real: the window bytes are counted twice in the response body. With
the 256 KiB default that is ~512 KiB of transcript on the wire, and with the 1 MiB
`max_bytes` ceiling ~2 MiB. Corrected 2026-07-31 (retro PR-2, F18): those are
*estimates of the duplication*, not hard bounds on the response — JSON string
escaping of `"`, `\` and control characters expands both copies, and bytes that
are not valid UTF-8 repair to U+FFFD (3 bytes out per bad byte). Size against the
duplication factor of 2, not against a byte ceiling. Both copies are outbound-only
(the 1 MiB cap is on request bodies), and paging through `nextOffset` is
unaffected. Dropping the `content` block instead would halve it, but would break
any client that reads `content` and ignores structured results — a strictly worse
trade than paying for the duplicate.

No schema change, no migration, no backfill, no service IPC change, no UI change.

## Invariants affected

- **1. Single-Writer Discipline** — preserved trivially. The endpoint performs
  no writes: it only calls `ArchiveStore.listMachines`, `listReceipts`,
  `getReceipt`, and `readSourceWindow` (which reads manifest and chunk objects).
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
  ~~Rejected. The pre-2026-07-28 Streamable HTTP transport needs
  `Mcp-Session-Id` issuance and validation, session expiry, `DELETE` for session
  teardown, an SSE GET stream, and `Last-Event-ID` resumability — a large
  stateful surface, in a target whose entire value is being small and auditable,
  for exactly zero current legacy-HTTP clients. This server has never had an MCP
  client of any era.~~

  **Reversed 2026-07-29 — adopted, minus the sessions.** Two errors in the text
  above. First, the premise: "zero current legacy-HTTP clients" was an
  assumption, and the very client this endpoint was built for (Claude Code
  2.1.220) turned out to be legacy-era. Nobody captured its bytes before the era
  policy was chosen; one `initialize` POST would have settled it. Second, the
  cost: every item in that list is a MAY, not a MUST. Sessions are optional in
  all four legacy revisions, and once you decline to mint an `Mcp-Session-Id`,
  validation, expiry, `DELETE` teardown, the SSE GET stream, and `Last-Event-ID`
  resumability all disappear with it. Legacy support as actually built is ~40
  lines of dispatch and zero bytes of state — smaller than the paragraph
  rejecting it. The rejected alternative was "dual-era **with sessions**"; the
  version worth building was never priced.
- **Dual-era with real sessions.** Still rejected, and this is the option the
  original text was actually describing. `Mcp-Session-Id` would buy nothing here
  (there is no per-client state to key), and it would cost a session table,
  expiry, and a teardown verb the archive v2 safety gate forbids registering.
  Stateless in both eras is not a compromise for this endpoint; it is the better
  design.
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
   this endpoint has no sessions in either era. The safety gate wins over the
   spec's SHOULD.
2. **`subscriptions/listen` returns `-32601`.** The endpoint advertises no
   change notifications and holds no per-client state, so there is nothing to
   subscribe to. `-32601` from the default dispatch branch, with the `404`
   status the spec pairs with unknown methods, is the honest answer. (Modern era.
   In the legacy era the method is simply unknown and gets `-32601` over HTTP
   `200`, per that era's conventions.)

## Security notes

- **Token separation.** A third credential, refused at startup if it collides
  with the v1 or archive tokens. Handing an agent runtime the ability to *read*
  archived transcripts must not hand it the ability to *write* to the archive or
  to the legacy v1 store.
- **Origin refusal.** Any `Origin` header is rejected. The endpoint is for
  programmatic clients over Tailscale, never a browser, so DNS-rebinding
  hardening costs nothing here.
- **The legacy era opens no bypass.** Auth, `Origin` refusal, and the body limit
  all run *before* the era split, so a legacy-shaped request cannot reach a tool
  without the bearer token, and there is no era in which an unauthenticated
  `initialize` is answered. What the legacy path does skip is the header trio, so
  a proxy auditing `Mcp-Method` sees nothing for legacy traffic — an
  observability loss, not an access-control one, and it stacks on the existing
  no-telemetry gap under Risks.
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
  - Added 2026-07-31 (retro PR-2): paging a mixed-width UTF-8 transcript
    reassembles byte-exactly with no U+FFFD
    (`testMCPGetSessionPagesUTF8ScalarBoundariesExactly_repro`). The
    skip-without-fetch guarantee is pinned store-side in `ArchiveStoreTests`
    (`testWindowedSourceReadSkipsNonOverlappingChunks_repro`,
    `testWindowedSourceReadRejectsCorruptOverlappingChunk_repro`,
    `testGetManifestStillValidatesEveryChunkObject`).
- Gates that must keep passing unchanged: `scripts/check-archive-v2-safety.sh`
  (no new DELETE registration) and
  `testRemoteServerCoreIncludesOnlyPureArchiveWireSources` (no new target
  dependency).
- CI: all of the above runs in the existing `remote-server-swift` lane in
  `.github/workflows/test.yml`, which regenerates the project with `xcodegen`
  and runs the `EngramRemoteServerCore` scheme.
- Intentionally not tested: TLS (terminated upstream or handled by Tailscale) and
  SSE/resumability (not implemented).

### Legacy-era cases (added 2026-07-29)

Same file, same router harness, driven through `mcpLegacyHeaders()` /
`mcpLegacyBody(...)` helpers that send **no** `_meta` and none of the
2026-07-28 request-metadata headers — the shape Claude Code actually sends:

- `testMCPLegacyInitializeHandshakeWithoutModernMetadata` — the captured Claude
  Code 2.1.220 handshake, once per served revision (`2024-11-05`, `2025-03-26`,
  `2025-06-18`, `2025-11-25`): each is echoed back, with a `tools`-only
  capability object, `serverInfo`, and non-empty `instructions`, and header
  validation is skipped.
- `testMCPLegacyInitializeNegotiatesUnknownVersionDown` — older, newer,
  wrong-typed, absent, and `2026-07-28`-without-`_meta` all negotiate to
  `2025-11-25` instead of failing. The modern revision offered through
  `initialize` is still a legacy handshake, which pins the era rule from the
  other side.
- `testMCPLegacyResultsAreUnwrapped` — `tools/list` carries exactly `tools`;
  `tools/call` carries exactly `content` + `structuredContent`; a failing
  `tools/call` carries `isError` + `structuredContent.code`; none of them carry
  `resultType`, `ttlMs`, `cacheScope`, or `_meta`.
- `testMCPLegacyPingAndInitializedNotification` — `notifications/initialized` →
  `202` with a zero-byte body, `ping` → `200` with an empty result and the
  request's `id` echoed.
- `testMCPLegacyUnknownMethodReturns200MethodNotFound` — `resources/list`,
  `prompts/list`, `server/discover`, `subscriptions/listen`, `logging/setLevel`
  all get HTTP `200` with `-32601`. `server/discover` is in that list on purpose:
  it is modern-only, so without `_meta` it is simply unknown.
- `testMCPLegacyPathStillEnforcesAuthAndOrigin` — absent, v1, archive, and bogus
  tokens → `401` with `WWW-Authenticate: Bearer`; any `Origin` → `403` with
  `-32600`, refused before the era branch. (The body limit and the JSON parse
  error are era-independent for the same structural reason and stay covered by
  the modern cases.)
- `testMCPLegacyResponsesNeverMintSessionID` — no `Mcp-Session-Id` on any legacy
  response, a client-supplied one is neither required nor validated, and the
  modern era is checked for the same absence. This is the test that keeps the
  stateless property from eroding.
- `testMCPModernEraStillWrappedAlongsideLegacy` — one server instance answering
  both shapes of `tools/list`, with identical tool lists and different envelopes;
  the same unknown method getting `404` modern and `200` legacy; `-32022` still
  raised for an unsupported modern version; and `initialize` **with** `_meta`
  still a modern-era unknown method.
- `testMCPGetSessionDuplicatesTranscriptIntoStructuredContent` — the regression
  test for the transcript-visibility bug (it fails against the pre-2026-07-29
  endpoint): a full read and a windowed read both carry the window in
  `content[0].text` *and* `structuredContent.text`, in both eras.

The pre-existing modern-era unknown-method case keeps `initialize` and `ping` in
its list and still passes, because it sends `_meta`: in the modern era those names
are genuinely unknown methods. The era split is what makes both assertions true at
once, so both must stay.

### Real-client verification (done 2026-07-29)

Run on a real Mac against the real built binary over a real socket, not through
the in-process router harness:

- 60/60 modern-era checks and 16/16 legacy-era checks passed against the running
  server.
- A real `claude -p` run with the endpoint added via
  `claude mcp add --transport http` drove all three tools end to end and read
  back marker strings embedded in an archived transcript — which is the check
  that would have caught the `structuredContent` bug, and the reason it is worth
  keeping in the loop rather than trusting router-level tests alone.

The harness for that run is out of tree; the in-tree XCTest cases above are what
CI enforces. Anything that changes the era policy or the tool result shape should
be re-run against a real client before it is believed, because both bugs this
revision fixes were invisible to a conformant-but-synthetic test matrix.

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
- **Risk (low/medium): a spec revision after 2026-07-28.** The modern path
  hard-codes a single supported version. A modern client on a newer revision gets
  a clean `-32022` with `data.supported`, so it fails legibly rather than
  mysteriously — but it fails. The legacy path is more forgiving by construction:
  an unknown `initialize` version negotiates down.
- **Risk (medium/low): `archive_get_session` sends the window twice.** The
  transcript is in `content[0].text` and in `structuredContent.text`, so a
  256 KiB default window is ~512 KiB on the wire and a 1 MiB window ~2 MiB —
  before JSON escaping and U+FFFD expansion, which apply to both copies. This
  is deliberate (see Tools) and the driver is client behavior that could change:
  if a future Claude Code surfaces `content` alongside structured results, the
  duplication becomes pure waste and should be dropped — but only after
  re-verifying against a real client, never on the strength of a spec reading.
- **Risk (low/low): era detection depends on clients following the spec's
  `_meta` requirement.** A modern client that omits `_meta` silently gets the
  legacy path. It still works, so the failure is benign, but the endpoint cannot
  tell "legacy client" from "buggy modern client" and does not try.
- **Risk (low/low): `EngramRemoteServerApp.swift` is now over 1,200 lines**, and
  `ArchiveRouteTests.swift` over 1,900. A file-split is blocked only by
  `xcodegen` availability, not by design.
- **Risk (low/low): `server/discover` understates what the endpoint serves.** It
  advertises the modern set only, not the union across eras. Harmless for its
  audience, wrong as a description; see Future work.
- **Open question:** should `archive_get_session` expose a `session_id` lookup
  in addition to `manifest_sha256`? Today a client must page
  `archive_list_captures` to map a session to a digest. A reverse index would
  need either a store-side map or a full scan.
- **Open question:** what does an authenticated-but-idle endpoint cost on the
  mini? Nothing is held open, but the endpoint has not been load-tested.

## Future work

- **Advertise both eras from `server/discover`** — the union of the modern and
  legacy revision sets, as the stdio helper does, instead of the modern set
  alone.
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
