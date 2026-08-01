# Design Doc: Archive list index robustness

- **Status**: Accepted
- **Owner**: retro PR-3
- **Date**: 2026-07-31
- **Related**: MCP retrospective findings F04, F05, F06, F07, F19, F20, F28 on
  merged PRs #277–#281 (index added by #280, commit `2cec2354`);
  `docs/remote-mcp-2026-07-28-design.md`; `docs/archive-windowed-read-design.md`
  (retro PR-2, same files)

## Problem

#280 replaced the full-scan enumeration behind `ArchiveStore.listMachines` /
`listReceipts` with a process-local index (`ArchiveReceiptListIndex`), because a
scan costs ~18 s on the real ~25k-receipt archive on macmini-m1 and made the
remote MCP `archive_list_*` tools unusable. The index is correct on the happy
path, and the retrospective confirmed six robustness defects around it plus one
coverage gap.

**F04 — the merge is quadratic and holds the global lock for seconds.**
`ensureReady` applied the scan result entry-by-entry while holding the
`NSCondition` lock, and `applyLocked` did two linear scans per entry plus a
copy-on-write of the whole per-machine array on every insert (the array was
still referenced by the dictionary while the local copy was mutated). Scan
output arrives in directory-enumeration order, so no fast path applied.
Transcribed verbatim into a standalone `swiftc -O` benchmark, 25,461 entries
took 3.94 s across 3 machines and 13.63 s on a single machine. The lock the
merge holds is the same one `note()` takes, so every concurrent `createReceipt`
upload blocked for that window.

**F05 — a failed warm has no negative caching.** On failure `ensureReady` set
the phase back to `.cold` and broadcast. Every waiter then woke, saw cold,
claimed the latch and ran its own full scan, serialized one after another —
k queued listers cost k scans of wall time where the pre-#280 code cost ~1.
Warm failure is operationally reachable: a stray non-hex dirent under
`receipts/sha256`, a shard whose mode is not `0700`, or any `serverID` config
edit makes the scan throw `.conflict` forever.

**F20 — the pending queue is unbounded.** `note()` appends while cold or
building and the queue is drained only by a *successful* build, so a
persistently failing warm plus continued ingestion grows it for the process
lifetime, retaining entries whose receipts are already durable on disk.

**F06 — poisoning is silent.** A same-manifest / different-receipt-digest
observation sets a process-wide `poisoned` flag and wipes the index; every list
throws `.conflict` until restart. That fail-closed choice is deliberate, but it
happened inside a lock on a `createReceipt` path with no log line at all, so an
operator saw only `conflict` from every list with nothing pointing at a receipt.

**F19 — pages are not O(log n + page).** `listReceipts` ran
`lowerBound(entries.map(\.manifestSHA256), after: cursor)`: an O(n) allocation
of every manifest digest for that machine, on every page, under the lock, purely
to feed a binary search.

**F07 — `archive_list_captures` re-added the cost #280 removed.** The MCP tool
took the indexed page and then called the durable `store.getReceipt` once per
entry to enrich `sessionID` / `captureID` / `rawByteCount` / `storedAt`. That
path does directory-chain walks, an fsync of the file *and* of the shard
directory, plus a manifest read and canonical re-encode. With the default limit
of 100 a single page performed ~100 durable receipt reads (~200 fsyncs) — the
exact per-receipt work the index exists to avoid, in the tool the index was
built for. The `MEMO.md` "~3–5 ms, instant" deploy record measured
`archive_list_machines`, the one tool with no enrichment loop.

**F28 — the background warm has no outcome verification.** The warm scheduled
by `run()` executes under the live-socket tests, but nothing asserts its
failure behavior (cold reset, rebuild on demand) or the poison path.

## Goals / Non-goals

- Goals: bounded lock hold at warm completion; one scan per failure window
  instead of one per waiting lister; a bounded pending queue that cannot lose an
  entry from the final index; an observable poison transition; receipt pages
  that allocate nothing per page; capture pages served without a durable read;
  tests for the failure and poison paths.
- Non-goals: making poisoning recoverable or per-machine; persisting the index;
  rate limiting the MCP endpoint; changing cursor or page-shape semantics;
  fixing the other retrospective findings (F01–F03, F08–F18, F21–F27, F29).

## Current state

Before this change, at `2cec2354`:

- `macos/EngramRemoteServer/Core/ArchiveStore.swift:94-243` —
  `ArchiveReceiptListIndex`: `note` (:114), `ensureReady` (:130), `listMachineIDs`
  (:170), `listReceipts` (:183), `applyLocked` (:206), `lowerBound` (:229).
- `macos/EngramRemoteServer/Core/ArchiveStore.swift:646-676` —
  `ensureListIndexReady` builds entries from `forEachReceipt`;
  `notePublishedReceipt` feeds `note` from `createReceipt`.
- `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift:1045-1078` —
  `MCPRemoteEndpoint.listCaptures`, with the per-entry `store.getReceipt`
  enrichment loop.
- `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift:193-214` — `run()`
  schedules the detached warm and logs its outcome through
  `Logger(label: "engram.remote")` (swift-log, the target's convention).

## Proposed design

### 1. Off-lock build, lock only for the pending merge and swap (F04)

`ensureReady` keeps its single-flight latch and its `.cold → .building →
.ready` phases, but the merge is restructured:

1. Outside the lock, group the scan result into `[machineID: [manifest: Entry]]`.
   The inner dictionary gives O(1) dedup and conflict detection; a manifest that
   repeats with a different receipt digest records a conflict and stops the loop.
2. Outside the lock, sort each machine's entries by `manifestSHA256` once
   (O(n log n) total, no per-entry copy-on-write).
3. Take the lock once: merge the pending queue into the built structure, swap it
   in, flip to `.ready`, broadcast.

Exactly-once semantics are unchanged and rest on the same invariant as before:
`note()` appends under the same lock this final merge holds, so an entry queued
before the swap is merged here (manifest-keyed dedup absorbs scan/pending
overlap) and an entry queued after it applies directly to the ready structure.
Neither can be lost or double-counted. Conflict detection still fires across
scan ∪ pending: the off-lock pass covers scan-internal conflicts and the pending
merge reuses `applyLocked`, which detects a pending entry contradicting a
scanned one.

The pending merge stays inside the lock but is bounded by the cap below, and
each entry is now a binary-search insert instead of two linear scans.

### 2. Failure memo + retry backoff, with a forced-warm bypass (F05)

A failed build records `FailureMemo { error, at: DispatchTime }` (monotonic,
unaffected by wall-clock changes) and leaves the phase `.cold`.

- **Implicit builds** — anything reached through `listMachines` / `listReceipts`
  / `listCaptures` — pass `forced: false`. Inside the backoff window they throw
  the memoized error without touching the disk, so a queue of listers costs one
  scan per window instead of one scan each.
- **Explicit `warmListIndex()`** passes `forced: true` and always rebuilds. This
  is the recovery path: the background warm on `run()`, or an operator restarting
  the process after fixing the cause, is never blocked by the memo. It also keeps
  "failed warm → later successful warm rebuilds and lists work" true regardless
  of the window length.

The interval is an initializer parameter (`ArchiveReceiptListIndex.init(retryBackoff:)`,
default `ArchiveReceiptListIndex.defaultRetryBackoff` = 3 s) threaded through
`ArchiveStore.init(root:key:serverID:testHooks:listIndexRetryBackoff:)`, so tests
pass `600` (window open) or `0` (window expired) instead of sleeping.

Poisoning is unaffected: it is a `.ready` state, checked before the memo, and a
forced warm still fails closed.

### 3. Bounded pending queue with a rescan flag (F20)

`pending` is capped at `maxPendingEntries = 4096`. On overflow the queue is
dropped, and if the overflow happened while a scan was in flight
(`phase == .building`) the flag `rescanRequired` is raised; the completed build
is then discarded, the phase returns to `.cold`, and `ensureReady` scans again
(up to `maxBuildAttempts = 3`, after which it records a failure memo and throws
`.io` rather than publish a knowingly incomplete page set).

Dropping is safe, and only for this reason: **`note()` runs after the receipt is
durable on disk, so every dropped entry is re-discovered by a full rescan.** A
drop while `.cold` needs nothing extra — the next scan starts after the drop and
therefore sees the file. A drop while `.building` is the one unsafe case, since
that scan may already have walked past the receipt's shard; that is exactly what
`rescanRequired` invalidates. Reaching the cap at all requires 4096 receipt
publications inside a single scan, which the fsync-bound publish path cannot
sustain on the real archive.

### 4. Poison observability (F06)

Global, permanent fail-closed behavior is kept — an unexplained receipt-digest
divergence means no list is trustworthy — but `poisonLocked` now emits one
`Logger.error` naming the manifest digest and both receipt digests, through
swift-log with label `engram.remote.archive-index` (the label convention the
target already uses for `engram.remote`). The blast radius and the
restart-to-recover story are unchanged; only the silence is fixed.

### 5. Allocation-free receipt paging (F19)

`listEntries` binary-searches the entry array directly, comparing
`entries[i].manifestSHA256`, through one `partitionPoint` helper that also serves
machine-ID paging and the two sorted inserts in `applyLocked`. No projected key
array is allocated, so a page is genuinely O(log n + page).

### 6. Capture pages served from the index (F07)

`ArchiveReceiptListIndex.Entry` carries the four extra fields
`archive_list_captures` emits — `sessionID`, `captureID`, `rawByteCount`,
`storedAt` — captured where the receipt is already decoded, on both entry paths:
`forEachReceipt`'s `scanReceipt` result during warm, and
`decodeReceiptForDiscovery` in `notePublishedReceipt` on publish. No field needs
a non-durable fallback read; nothing else in the tool's output comes from the
receipt. Entry growth is four small values per receipt (~100 bytes with the
three added strings), i.e. tens of MB at 25k receipts remains a few MB.

`ArchiveStore` gains `listCaptures(machineID:cursor:limit:) -> ArchiveCapturePage`
(`ArchiveCaptureSummary` per entry). It shares `listIndexPage` with
`listReceipts`, so limit validation, machine-ID canonicalization, cursor decode,
the `limit + 1` lookahead and `nextCursor` derivation are identical for both
tools. `ArchiveReceiptSummary` / `ArchiveReceiptPage` — the `/v2/archive/receipts`
wire models — are untouched.

**Missing/corrupt entry behavior.** The old loop wrapped the durable read in
`try?`: a receipt that failed to read or decode silently degraded to two digest
fields in an otherwise successful page. That is gone, and deliberately not
replaced: the same corruption now fails the *warm scan* with `.conflict`
(`scanReceipt` enforces envelope AEAD, shard identity, `serverID`,
`manifestSHA256`, timestamp), so the whole list fails closed instead of quietly
serving a half-populated entry. After warm, a receipt file that disappears or
rots does not affect the page at all — the index already holds the fields. This
is a deliberate move from silent per-entry degradation to loud whole-list
failure, consistent with the existing poison semantics.

## Invariants affected

None of the entries in `docs/invariants.md` cover the remote archive list index;
this change adds no ledger entry. The two index-local invariants it preserves are
stated in code comments at their enforcement sites in
`macos/EngramRemoteServer/Core/ArchiveStore.swift`:

- Pending entries are merged exactly once, because `note()` appends under the
  same lock the final merge holds.
- Dropping the pending queue loses nothing from the final index, because every
  queued receipt is durable before `note()` runs and a full rescan re-discovers
  it; a drop during a scan invalidates that scan.

## Alternatives considered

- **Sort the built array and append in place, keeping the merge in the lock**
  (the fix sketched in the finding). Removes the copy-on-write but still holds
  the lock for the whole n-entry pass; grouping off-lock costs the same code and
  bounds the lock hold by the pending queue instead of by archive size.
- **Attempt cap on failed warms instead of a time backoff.** A cap either
  permanently disables lists after k failures or resets on some other clock; a
  time window is self-healing and directly expresses "do not rescan more than
  once per interval".
- **Backoff applied to explicit warms too.** Rejected: it would make an operator
  restarting the warm task wait out a window whose only purpose is protecting
  against retry storms from clients, and would break the "fix the cause, warm
  again" recovery story.
- **Keep the pending queue unbounded but deduplicate it.** Dedup does not bound
  it — distinct receipts keep arriving — and the queue is pure redundancy against
  durable state, so a cap plus rescan is both smaller and strictly safer.
- **Per-machine poisoning.** Rejected here as a semantics change; #280 chose
  process-wide fail-closed deliberately and this PR only adds observability.
- **Non-durable receipt read for capture enrichment** (the scan-style read, no
  fsync). Not needed: every emitted field is available at index time, so the read
  is removed rather than made cheaper.

## Test plan

`macos/EngramRemoteServerCoreTests/ArchiveStoreTests.swift`:

- `testListIndexFailedWarmIsMemoizedUntilForcedWarm_repro` (F05, F28) — a stray
  non-hex receipt shard fails the warm; with the cause removed an implicit list
  still throws the memoized error inside a 600 s window; a forced
  `warmListIndex()` rebuilds and both list surfaces work. Verified to fail
  before the fix (mutating the memo check out makes the middle assertion fail).
- `testListIndexRebuildsOnListWhenFailureBackoffExpired` (F05) — with the backoff
  injected as 0, the next list rebuilds by itself.
- `testListIndexPoisonFailsEveryListClosedAcrossForcedWarm` (F06, F28) — a
  receipt republished with a different `storedAt` poisons on the next publish;
  `listMachines`, `listReceipts` and a forced `warmListIndex()` all throw
  `.conflict`.
- `testListIndexPoisonDetectedWhenPendingContradictsScan` (F06) — the same
  divergence introduced while the scan is parked in the `afterListIndexBuild`
  hook, so the conflict only exists across scan ∪ pending; the merging caller
  fails and lists stay closed.
- `testListIndexCursorPagesSurviveInsertionsBetweenPages` (F04, F19) — receipts
  chosen by precomputed digest order; a cursor taken from page 1 still skips
  exactly the entries at or before it after one receipt is inserted before the
  cursor and one after.
- `testListIndexAppliesRepeatedNotesExactlyOnce` (F04) — the same receipt noted
  while cold, again mid-build and again against the ready index is listed once.
- `testListCapturesServesReceiptFieldsFromIndexWithoutDurableRead` (F07) — every
  capture field is byte-identical after the receipt file is deleted post-warm.

`macos/EngramRemoteServerCoreTests/ArchiveRouteTests.swift`:

- `testMCPListCapturesServesEnrichedFieldsFromWarmIndex_repro` (F07) — the same
  property end-to-end through `archive_list_captures`. Verified to fail before
  the fix (restoring the `getReceipt` enrichment loop drops `sessionID`,
  `captureID`, `rawByteCount` and `storedAt` from the page).

Intentionally not tested: wall-clock lock-hold and per-page allocation are
performance properties, and timing assertions are flaky in CI — they are covered
indirectly by the correctness tests above (same visible pages, same cursor
semantics, exactly-once merge). The `maxPendingEntries` overflow path is not
tested: reaching it needs 4096 real receipt publications inside one scan, and
faking it would require a test hook that only exists to prove itself.

## Rollout

Server-side only: `EngramRemoteServer` (the Mac mini deployment), no app or
service rebuild, no schema change, no migration. The index is process-local, so
the new behavior takes effect on the next server restart, and the first
`run()`-scheduled warm behaves exactly as before on a healthy archive. Revert is
a plain revert of the two source commits; nothing persists across it.

## Risks and open questions

- **Backoff hides a persistent failure behind a repeated error.** Likelihood
  low, impact low: the error is the real one from the scan, the warm-failure log
  line from `run()` is unchanged, and forced warm on restart still recovers.
- **`maxBuildAttempts` exhaustion returns `.io`.** Practically unreachable (see
  above); if it ever fires, lists fail closed for one backoff window rather than
  serving an index missing receipts.
- **Poison log volume.** One line per transition per process; the flag is latched,
  so it cannot spam.
- **Open**: the `run()` warm is exercised by the live-socket tests
  (`EngramRemoteServerTests`) but its completion is still not asserted from a
  test — observing it needs a hook on the detached task. The store-level tests
  above cover the contract that warm implements; the wiring itself stays
  unpinned, as F28 notes.
