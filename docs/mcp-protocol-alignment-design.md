# Design Doc: MCP Protocol Alignment Across the Two Dual-Era Servers

- **Status**: Implemented (retro PR-4)
- **Owner**: unassigned
- **Date**: 2026-07-31
- **Related**: the retrospective on merged MCP PRs #277–#281 (findings F02,
  F13, F14, F16, F17, F21, F22, F29); `docs/mcp-2026-07-28-dual-era-design.md`
  (the stdio helper's dual-era work); `docs/remote-mcp-2026-07-28-design.md`
  (the remote endpoint's); `docs/mcp-swift.md`. Code citations are against
  `macos/EngramMCP/Core/MCPStdioServer.swift` and
  `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift` on branch
  `retro/pr4-protocol`; line numbers will drift.

## Problem

Engram ships two independent dual-era MCP servers — the stdio helper
(`EngramMCP`) and the remote read-only HTTP endpoint (`EngramRemoteServer`).
They were built two weeks apart, each with its own era detection, its own
version sets, and its own error payloads, and the docs assert they behave the
same. A retrospective on #277–#281 found four places where they do not, and
where the wire contract contradicts itself or the doc that describes it:

- **F02** — the stdio `-32022` (UnsupportedProtocolVersionError) reported
  `data.supported = advertisedProtocolVersions`, the union of the modern set and
  the four legacy handshake revisions. So the same response said "2025-11-25 is
  unsupported" and "supported: [..., 2025-11-25, ...]". A client that follows the
  advertised list retries a listed legacy revision through the same `_meta`
  channel and gets the byte-identical rejection, forever.
- **F13 / F16 / F22 / F29** — era detection disagreed on malformed `_meta`.
  stdio keyed on `.stringValue`, so a present-but-non-string version silently
  became a *legacy* request and a client that had asserted modern semantics got
  an un-enveloped result with no `resultType` and no diagnostic. The remote
  endpoint keyed on key presence (modern), then reported the failure as `-32020`
  "request body is missing `_meta[...]`" — naming a key the request did carry.
  Neither behavior is what
  `docs/remote-mcp-2026-07-28-design.md` claimed ("the same rule the stdio
  helper uses").
- **F14** — a modern-tagged `initialize` on stdio returned the legacy handshake
  result through a raw `emit`, the one result-producing branch that escaped the
  modern envelope. Modern revisions define no handshake at all, and the remote
  endpoint already answers `-32601` for it.
- **F17 / F21** — the remote endpoint's legacy handshake echoed `2025-03-26`,
  the revision that *requires* receivers to accept JSON-RPC batches, while the
  endpoint rejects any top-level array with `-32700`. It also echoed
  `2024-11-05`, whose transport is HTTP+SSE rather than Streamable HTTP.

None of this is reachable by the shipping client (Claude Code 2.1.220 sends a
plain legacy `initialize` with `protocolVersion: 2025-11-25` and no `_meta`), so
the impact is on clients that adopt 2026-07-28 or that are stricter than today's,
plus the cost of two servers that document one contract and implement two.

## Goals / Non-goals

- Goals:
  - One era predicate, stated once and implemented identically in both servers.
  - A `-32022` payload a client can act on: advertise only revisions actually
    selectable through the channel the error arrived on.
  - Remove the two self-contradictions: the modern-era `initialize` success on
    stdio, and the batch/transport promises in the remote legacy version set.
  - A test for every behavior change, `_repro`-suffixed where a
    failing-before/passing-after repro is natural.
- Non-goals:
  - Changing `server/discover` on either server. On stdio its cross-era union is
    the intentional backward-compatibility probe answer; on the remote endpoint
    the modern-only answer is already documented as a known understatement.
  - Widening the stdio legacy version set, or narrowing it to match the remote
    one (see Decision 4).
  - Any change to the golden fixtures under `tests/fixtures/mcp-golden/`, the
    fixture generator, or the tool surface.
  - The other retrospective findings (performance, coverage, and doc-sync
    items); this PR is the protocol-consistency slice.

## Current state

- `MCPStdioServer.era(of:)` returned `.legacy` whenever
  `params._meta["io.modelcontextprotocol/protocolVersion"]?.stringValue` was nil
  — which `JSONValue.stringValue` is for null, bool, number, array, and object.
- `MCPStdioServer.emitUnsupportedProtocolVersion` reported
  `advertisedProtocolVersions` (modern ∪ legacy).
- `MCPStdioServer.handle` answered `initialize` with a raw `emit` regardless of
  era.
- `MCPRemoteEndpoint.handle` routed on `meta[protocolVersionMetaKey] != nil`,
  then ran `headerMismatch`, whose second guard reported a missing body key when
  the value would not cast to `String`; only afterwards did it compare the
  version.
- `MCPRemoteEndpoint.legacyProtocolVersions` held all four legacy revisions;
  `latestLegacyProtocolVersion` is their `max()`.
- Both servers coerce a non-object `params`/`_meta` to empty and fall through to
  legacy — untested on either side.

## Proposed design

### Decision 1 (F02): the `-32022` payload advertises the modern set only

`data.supported` now lists exactly the revisions selectable through the channel
the error arrived on. The error only ever fires on the per-request `_meta`
channel, and a legacy revision can never be chosen there, so:

| Surface | stdio | remote |
|---|---|---|
| `-32022` `data.supported` | modern set (`["2026-07-28"]`) | modern set (unchanged) |
| `server/discover` `supportedVersions` | cross-era union (unchanged) | modern set (unchanged) |

The union stays in stdio `server/discover` on purpose: that RPC is answered
*before* era detection precisely because it is the spec's stdio
backward-compatibility probe, so "fall back to the `initialize` handshake with
2025-11-25" is a real, actionable answer there. It is not an actionable answer
inside a `-32022`. The generated golden `discover.result.json` therefore does not
change.

### Decision 2 (F13/F16/F22/F29): one era predicate

Stated once, implemented in `MCPStdioServer.era(of:)` and
`MCPRemoteEndpoint.handle`:

> The **key** `io.modelcontextprotocol/protocolVersion`, present in an
> object-valued `_meta` inside object-valued `params`, signals modern-era
> intent — whatever its value type.
>
> - Key absent, `_meta` not an object, or `params` not an object → **legacy
>   era**. Those shapes cannot carry the key, so there is nothing to honor.
> - Key present, value a string in the modern set → **modern era**.
> - Key present, value a string outside the modern set → **`-32022`**, with
>   `data.requested` = the string.
> - Key present, value not a string (null, number, bool, array, object) →
>   **`-32022`**, with `data.requested` naming the JSON type that arrived:
>   `<null>`, `<number>`, `<bool>`, `<array>`, `<object>`.

The angle-bracket forms cannot collide with a real revision (every MCP revision
is a date string), so a client can tell "you asked for a revision I do not speak"
from "you did not send me a revision at all". On the remote endpoint the
type check runs *before* header validation, so the misleading `-32020` "body key
missing" message is gone; `headerMismatch` now takes the already-validated
version string and its unreachable second guard is deleted.

The legacy half of the predicate is behavior neither server changes — it is
pinned by new tests so the modern half cannot quietly widen into it.

### Decision 3 (F14): modern-era `initialize` is `-32601`

Modern revisions removed the handshake, so there is no negotiated connection
version to hand back
(`docs/mcp-2026-07-28-dual-era-design.md`, "Proposed design"). Returning the
legacy handshake body under modern `_meta` was both the one un-enveloped modern
result and an answer to a question the revision does not ask. stdio now answers
`-32601`, matching the remote endpoint (which 404s it). The legacy handshake,
including negotiate-down, is untouched — the golden `initialize.result.json`
still matches.

### Decision 4 (F17/F21): trim the remote legacy version set, not the stdio one

`MCPRemoteEndpoint.legacyProtocolVersions` becomes `{"2025-06-18",
"2025-11-25"}`. The two dropped revisions each promise a contract this endpoint
does not implement:

- `2025-03-26` requires receivers to support JSON-RPC batches. The endpoint
  accepts only a top-level JSON object; a batch array gets `-32700`.
- `2024-11-05` predates Streamable HTTP entirely — its transport is HTTP+SSE,
  with a standalone GET stream this endpoint refuses (`405`) and an `endpoint`
  event it never emits.

`latestLegacyProtocolVersion` is still `max()`, still `2025-11-25`, so the
negotiate-down default is unchanged and a client asking for either dropped
revision is served under `2025-11-25` rather than refused. The real client asks
for `2025-11-25`.

**The stdio helper's version sets are deliberately left broad**, and this
asymmetry is the point of the decision rather than an oversight:

- stdio has no batch contradiction (its framing is one JSON object per line, and
  no local client batches) and no transport mismatch — the HTTP-only concerns
  above do not exist there;
- local clients (Codex, older Claude Code) still connect over the older
  revisions;
- `scripts/gen-mcp-contract-fixtures.ts` extracts `supportedProtocolVersions`
  and `modernProtocolVersions` from the Swift source to build
  `tests/fixtures/mcp-golden/discover.result.json`, so trimming them would
  change a generated golden for no protocol reason.

## Invariants affected

- **12. EngramMCP Is Read-Only Except Service IPC Writes** — preserved. Every
  change is in the transport/dispatch layer of the two MCP servers; no read or
  write path is added, removed, or rerouted.

No new invariant is introduced, and no ledger entry is needed: the properties
here are pinned by tests in the two suites rather than by a red line.

## Alternatives considered

- **Advertise the union in `-32022` and make legacy revisions selectable through
  `_meta`.** Rejected: `_meta` version negotiation is defined by 2026-07-28, and
  a legacy revision selected through it would have no defined result shape (the
  envelope is a modern-era construct).
- **Demote a non-string `_meta` version to legacy on both servers** (make the
  remote match the old stdio behavior). Rejected: it answers a client that has
  asserted modern semantics with a result its parser rejects, silently, and it
  gives a proxy that retypes JSON the power to change the server's era.
- **Keep the stdio modern `initialize` and just wrap it in the envelope.**
  Rejected: it makes the reply *shape* valid while the reply itself still claims
  a negotiated protocol version the modern era does not define, and it keeps the
  two servers disagreeing on the same request.
- **Trim the stdio legacy set to match the remote one.** Rejected: it breaks
  local clients on older revisions for a contradiction that only exists over
  HTTP, and it churns a generated golden.
- **Keep `2025-03-26` on the remote endpoint and implement JSON-RPC batching.**
  Rejected: batching was removed again in `2025-06-18`, no client this endpoint
  serves uses it, and it would add a fan-out execution path to a read-only
  endpoint whose value is being small and auditable.

## Test plan

All new cases carry an `MCP retro F##, retro PR-4` comment.

- `macos/EngramMCPTests/EngramMCPExecutableTests.swift` (real executable over
  stdio):
  - `testModernRequestWithUnsupportedVersionReturnsUnsupportedProtocolVersionError`
    — tightened from `supported.contains("2026-07-28")` to
    `supported == ["2026-07-28"]` (F02). Fails before the fix.
  - `testModernMetaWithNonStringVersionIsUnsupportedProtocolVersion_repro` —
    number, null, bool, array, object each yield `-32022` with the matching
    `<type>` in `data.requested` and the modern-only `supported` (F13). Fails
    before the fix (the server answered a legacy `tools/list` result).
  - `testNonObjectMetaOrParamsSelectsLegacyEra` — `_meta` as string/array/null
    and `params` as string/array all stay legacy and unwrapped (F29). Passes
    before and after: it pins behavior the fix must not change.
  - `testModernInitializeIsMethodNotFound_repro` — modern `_meta` on
    `initialize` yields `-32601` (F14). Fails before the fix.
  - `testServerDiscoverMatchesGolden` and `testServerDiscoverAnswersWithoutMeta`
    keep passing unchanged, which is what pins the discover/error asymmetry.
- `macos/EngramRemoteServerCoreTests/ArchiveRouteTests.swift` (router harness):
  - `testMCPModernMetaWithNonStringVersionIsUnsupportedProtocolVersion_repro` —
    the five non-string shapes yield `-32022` with the JSON type and
    `supported == ["2026-07-28"]` (F16/F22). Fails before the fix with `-32020`.
  - `testMCPNonObjectMetaOrParamsSelectsLegacyEra` — the legacy half of the
    predicate (F29). Passes before and after.
  - `testMCPHeaderMismatchRejections` — the numeric-`_meta` case is removed from
    the matrix; header validation now only sees well-formed modern requests.
  - `testMCPLegacyInitializeHandshakeWithoutModernMetadata` — the served set is
    pinned to exactly `{"2025-06-18", "2025-11-25"}` and the handshake matrix
    runs over those two (F17/F21). Fails before the trim.
  - `testMCPLegacyInitializeNegotiatesUnknownVersionDown` — gains `2025-03-26`
    and `2024-11-05` as negotiate-down cases, so the trim's cost to a client is
    pinned as "served under 2025-11-25", not "refused". Fails before the trim.
- Golden fixtures: unchanged by construction — `server/discover` is untouched,
  the stdio version-set literals the generator reads are untouched, and the
  legacy `initialize` result is untouched. Verified by the golden-comparison
  tests inside `EngramMCPTests` (`testServerDiscoverMatchesGolden`,
  `testInitializeMatchesGolden`, and the `assertToolCallMatchesGolden` cases),
  not by re-running the generator.
- Intentionally not tested: a real 2026-07-28 client (none exists yet), and
  JSON-RPC batch handling on the remote endpoint (no longer promised by any
  advertised revision).

## Rollout

- stdio: ships with the next `Engram.app` build as
  `Contents/Helpers/EngramMCP`. Legacy clients cannot observe any of it — every
  changed path requires a modern `_meta` key they never send.
- remote: ships with the next `EngramRemoteServer` package for the mini
  (`docs/remote-offload.md`: build, install, restart the launchd job). The
  connected Claude Code client negotiates `2025-11-25`, which is still in the
  set, so the deploy is invisible to it.
- No schema, migration, backfill, IPC, or UI change; nothing to sequence.
- Revert story: each decision is independent and confined to one function per
  server. Reverting the commit restores the previous wire behavior exactly;
  there is no persisted state to unwind.

## Risks and open questions

- **Risk (low/low): a client depends on the old stdio modern `initialize`
  success.** Only a client that both sends modern `_meta` and calls a method the
  modern era removed, i.e. one already violating the revision it claims. It now
  gets a clean `-32601` instead of a result it should not parse.
- **Risk (low/low): a client pins `2025-03-26` against the remote endpoint and
  cannot handle negotiate-down.** It is served under `2025-11-25` rather than
  refused; the previous behavior echoed a revision whose batch requirement the
  endpoint never honored, which fails later and less legibly.
- **Risk (low/low): the `<type>` sentinel forms in `data.requested`.** They are
  not spec'd — the spec assumes a version string. A client that echoes
  `data.requested` back verbatim would send a nonsense revision and get the same
  error; the alternative (an empty string, which the remote endpoint used to
  produce) is strictly less informative.
- **Open question:** should the remote `server/discover` now advertise
  `["2026-07-28", "2025-11-25", "2025-06-18"]` — the union it actually serves?
  Still tracked as future work in `docs/remote-mcp-2026-07-28-design.md`; the
  trim makes that union honest and small, but widening discovery is a separate
  behavior change with its own client-visible risk.
- **Open question:** the two servers now implement the same predicate twice, in
  two languages of JSON access (`JSONValue` vs `[String: Any]`). Sharing the
  code would drag `EngramCore` into `EngramRemoteServerCore` and fail
  `testRemoteServerCoreIncludesOnlyPureArchiveWireSources`, so the duplication is
  deliberate — but the only thing keeping the two in step is the pair of test
  suites and this doc.
