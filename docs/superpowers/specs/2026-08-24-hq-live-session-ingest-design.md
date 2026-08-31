# Design Doc: HQ → daily-Mac live session ingest

- **Status**: Accepted by Claude (Herdr `hq-ingest-review`, 3 passes; `/tmp/engram-hq-ingest-design-review.md`). Not a public release.
- **Owner**: Cursor (orchestration) + Claude (design review; owner delegated the gate)
- **Date**: 2026-08-24
- **Related**: `/tmp/engram-round12-handoff-2026-08-24.md`; Herdr `wK:t8` requirement restatement; `docs/remote-offload.md`; `docs/remote-archive-v2.md`; `docs/remote-mcp-2026-07-28-design.md`; `macos/EngramCoreWrite/RemoteSync/ImportRepo.swift`; `macos/EngramService/Core/RemoteSyncCoordinator.swift`

## Problem

On 2026-08-24 the owner searched the daily machine (`Mo-Mo-MacBook-Pro`) for work that happened on `macmini-hq` / `Bing-HuaQiao` (example: Options-Radar / Invest Researcher at `http://10.0.10.100:8935/`). Local App search and local stdio `EngramMCP` missed it.

Two separate facts, both confirmed on disk that day:

1. **Cross-machine gap (this design).** Each machine has its own `~/.engram/index.sqlite`. Live counts were Mac ~51,726 vs HQ ~51,353. Both had **0** `remote:` imported rows. `syncPeers` is empty. Swift `triggerSync` still returns `Sync is not implemented in the Swift service`. Layer 2 `pushProject` / `pullProject` exists and writes searchable `remote:<peer>:<sessionId>` rows, but it is manual, per-project, preview-first, and is not running. Archive v2 dual-replica and `POST /mcp` on `macmini-m1` are cold archive surfaces, not a unified live search corpus.
2. **Index-surface gap (out of scope).** The exact string `10.0.10.100:8935` was in neither machine's FTS nor in historical Claude/Codex source files (except the investigation chat). Keyword search only indexes user/assistant text. Cross-machine ingest cannot invent a URL that never entered a transcript.

The owner wants the first gap closed: HQ live sessions must appear automatically in the daily Mac App search box and in local `engram` MCP `search` / `get_context` / `get_memory`.

This is a new product capability, not a bugfix of an existing auto-aggregator. Public baseline remains **v1.0.5**. This design does not authorize a tag, notarize, Homebrew, Sparkle, GitHub Release, or a commit of the current dirty remediation tree.

## Goals / Non-goals

### Goals

- On the daily Mac, App keyword search and local stdio MCP search/context/memory return HQ-origin sessions in the **same result set** as local sessions.
- Ingest is **automatic**. Target SLA for a newly indexed, **keyword-searchable** (`normal` or `premium`) HQ session: **within 16 minutes** after HQ has indexed it (60s publish debounce + pull interval clamp 300…900s). Historical backfill is best-effort and outside the SLA. Imported `lite` rows may appear in lists but must not be used as the SLA fixture.
- Results show a durable **machine origin**: an `HQ` badge when `origin == "hq"`. Local or null origin shows no badge.
- Open / resume is honest. `remote://` is not a local file and is not an archive capture id. Detail view shows the imported FTS/summary snapshot, labelled as such. Resume returns an error that the source lives on HQ.
- Default privacy holds: opt-in settings, Tailscale / existing hub auth only, no public internet, no expansion of m1 archive MCP into a write or live-search surface.
- Writes stay on `EngramService` / `ServiceWriterGate` (invariant 1). Skip / subagent / suggested-parent children stay unpublished and stay `skip` if ever present (invariants 2 and 3).
- First period is **unidirectional HQ → daily Mac**. m1 stays an archive replica, not a live source.

### Non-goals

- Expanding `macmini-m1` `POST /mcp` beyond `archive_list_machines` / `archive_list_captures` / `archive_get_session`.
- Client-side fan-out search (MCP/App querying HQ at search time and merging).
- Reviving empty `syncPeers` or advertising Swift `triggerSync` as working peer sync.
- Bidirectional live CRDT / multi-master conflict merge.
- Chrome / browser-history crawling to recover URLs that never entered a session body.
- Changing Options-Radar or any HQ product except the minimum Engram publisher.
- Installing a full `Engram.app` UI on HQ.
- Opening HQ `POST /mcp`.
- Shipping v1.0.6 or committing the Round-12 dirty tree as part of this work.
- Reopening the Grok review loop (no Round-13).
- Putting the live full-set inside `GET /v1/catalog` (4 MiB aggregate cap).

## Current state

Two baselines must not be conflated. Disk wins.

**`origin/main` = `d97d0257` (implementation must not pretend retract exists here):**

- `ImportRepo` has `importedLocalId`, `needsImport`, `commitImported` only. No `retractImportedSessions`.
- `pullProject` imports every project-matching catalog entry. No `isPublishable`.
- `RemoteSessionBundle` has no visibility fields (`tier` / `agentRole` / parent ids).
- `SyncManifestEntry` has `tier` only.
- `RemoteSyncCoordinator.makeIfEnabled` returns `nil` when `remoteOffloadEnabled` is false, before any HTTP backend is built (`macos/EngramService/Core/RemoteSyncCoordinator.swift` on that commit). `EngramServiceRunner` then never constructs a coordinator, and when one exists it calls `runOnce()` → `drainOffload` → possible FTS collapse.

**Dirty Round-12 tree (2026-08-24, Codex still writing; not `d97d0257`):**

- `ImportRepo.retractImportedSessions` exists and is **project-scoped** (`origin = ? AND lower(project) = lower(?)`).
- `isPublishable` plus pull-side retract exist on `RemoteSyncCoordinator`.
- Bundle / manifest entries gained visibility fields.
- `pushCandidates` on **both** trees already excludes imported origin, skip, subagent, offloaded rows, and parent / suggested-parent children.

**True on both trees:**

- Local search corpus is `sessions` + `sessions_fts`. App UI is keyword-only. Local `EngramMCP` is stdio against the daily Mac service/DB.
- `commitImported` UPSERTs `remote:<peer>:<sessionId>`, sets `origin` / `authoritative_node`, `file_path` `remote://<peer>/<sessionId>`, empty `cwd`, and replaces FTS from the bundle. Bundles are FTS lines + summary + counts, **never** raw transcripts (`macos/EngramCoreWrite/RemoteSync/RemoteSyncModels.swift`).
- `OffloadRepo.candidateRows` / `pushCandidates` refuse non-local `origin` (echo-loop guard).
- `GET /v1/catalog` is the aggregate of all peer manifests and is hard-capped at **4 MiB** (`EngramRemoteBackend.maxCatalogBytes`, `RemoteStorageBackend`, `EngramRemoteServerApp`). A measured publishable slice on this Mac (`pushCandidates` predicates) is ~3,652 rows / ~2.9–3.1 MB — too large to share that envelope with the Mac's own offload manifest.
- `makeIfEnabled` peer id is `ENGRAM_REMOTE_OFFLOAD_PEER ?? ProcessInfo.hostName`. There is no `ENGRAM_LIVE_INGEST_PEER` reader today.
- No product `remote://` transcript reader. `MCPTranscriptReader.isVirtualLocator` recognizes `::` and `?composer=` only; `remote://hq/<id>` would be `lstat`'d as a filesystem path and fail.
- App `Session` does not decode `origin` (`macos/Engram/Models/Session.swift`).
- `triggerSync` is still the stub “Sync is not implemented in the Swift service”.
- Daily Mac offload already points at HQ `EngramRemoteServer` over Tailscale. HQ has `index.sqlite` and the archive replica, not `Engram.app`. HQ `POST /mcp` is 404.

## Proposed design

### 0. Implementation base (locked; Claude B1)

Do **not** start coding while Codex is still editing the dirty tree.

After Codex is idle:

1. Re-read `ImportRepo`, `RemoteSyncCoordinator.pullProject`, and bundle/manifest visibility fields on **that** disk.
2. Implement this feature **on the dirty tree after Codex stops**, not on a `d97d0257` worktree. The withdrawal path this design needs is Round-12 work; building on `origin/main` today would import without retract and violate invariants 2 and 3.
3. If Codex stops and retract / `isPublishable` / visibility fields are still missing, **Task 0 of implementation is to port them** with their own `_repro`s. They are prerequisites, not “already there on main”.
4. Do not hand-edit `macos/Engram.xcodeproj`. No commit / push / tag / Round-13 unless the owner later asks.

### 1. Approach (locked)

Reuse Layer 2 **bundles** and `ImportRepo.commitImported`. Do **not** reuse `GET /v1/catalog` as the live listing, `makeIfEnabled` as the only constructor, `pushProject` / `pullProject` as the only cycles, or `retractImportedSessions` as the only retract (it is project-scoped).

Two new cycles:

1. **HQ publisher** — launchd `EngramService` (no App). Existing indexer stays on. A **publish-only** cycle uploads new/changed publishable bundles and writes a **live head + generation blob** (below). HQ FTS is not collapsed. HQ does not pull. HQ does not call `runOnce` / `drainOffload`.
2. **Daily-Mac puller** — existing App-launched `EngramService`. Periodically `GET`s the live head, then the generation blob, imports publishable `hq` entries, and retracts only under the complete-manifest + shrink-guard rules.

Headless HQ `EngramService` is still the minimum indexer. File-copy re-index on the Mac remains the escape hatch if HQ cannot run the helper.

### 2. Coordinator construction (locked; Claude B2)

Add `RemoteSyncCoordinator.makeLiveIfEnabled(gate:environment:)` (name may vary; the contract may not):

- Builds the same HTTP (or local-dir) backend as today from `remoteOffloadServerURL` / token / TLS settings.
- Arms when `livePublishEnabled` **or** `liveIngestEnabled` is true, **even if** `remoteOffloadEnabled` is false.
- Never registers `runOnce` / `drainOffload` for this coordinator.

HQ production flags: `livePublishEnabled=true`, `remoteOffloadEnabled=false`.
Mac: `liveIngestEnabled=true`; existing `remoteOffloadEnabled` may stay true for **Mac-local** cold offload. `runOnce` remains the offload coordinator only.

`EngramServiceRunner` must call the two constructors independently. A test must prove HQ publish runs with offload disabled and that `sessions_fts` line count / `offload_state` stay unchanged.

### 3. Identity and peer id (locked; Claude B3)

Two roles, two keys:

- **Publish identity (HQ only):** who I am. `ENGRAM_LIVE_INGEST_PEER` → `liveIngestPeerId` → `ENGRAM_REMOTE_OFFLOAD_PEER`. Empty ⇒ do not start live publish. No hostname fallback. First period: `hq`. `ENGRAM_REMOTE_OFFLOAD_PEER=hq` is allowed **only on HQ**.
- **Pull source (Mac only):** who I read. `liveIngestSources` is the only Mac list (`["hq"]`). `liveIngestPeerId` on the Mac is an alias that must equal the single entry of `liveIngestSources`; if they diverge, fail closed and start neither pull nor a peer-id rewrite.

The Mac must **not** set `ENGRAM_REMOTE_OFFLOAD_PEER=hq`. That env stamps the Mac offload coordinator and would let a manual `pushProject` overwrite `catalog.hq.manifest`.
- v1 forbids renaming the peer. Changing it orphans `remote:<old>:*` rows because retract keys on `origin`. No migration tool in v1.
- Imported primary key: `remote:hq:<nativeSessionId>`.
- **Native-id occupancy:** if a **local-origin** row already has `id == nativeSessionId`, do not create `remote:hq:…`.
  - If that local row is `skip` or hidden, still do not import (no second id). The session is then absent from Mac keyword search; that is accepted in v1 and must be stated in the Mac settings last-error / skip-count, not silently dropped without a counter.
- **Idempotent re-pull:** `needsImport` (`snapshot_hash` vs bundle `contentHash`).
- No fuzzy merge across different native ids.

### 4. Live listing transport (locked; Claude B4)

Do **not** put the HQ live full-set in `GET /v1/catalog`.

Use the existing authenticated blob `PUT`/`GET` (same bearer, same store):

- Head key: `live.<peer>.head` — small JSON `{ peer, generation, complete, entryCount, manifestKey, contentHash, withdrawnCount }`.
- Manifest key: `live.<peer>.<generation>.<seq>.manifest` — the entry list for that write. `seq` increments on every publish cycle so a key's bytes never change (avoids a head `contentHash` pointing at an overwritten blob). Sized as one blob, not inside the 4 MiB catalog aggregate.
- Bundles stay content-addressed as today (`<sha256>.bundle`).

Mac pull: `GET live.hq.head` then `GET` that `manifestKey`. Offload catalog behavior is unchanged.

If a future complete HQ publishable set exceeds a new live-manifest cap (16 MiB), fail closed and surface the error; do not silently truncate. Measured ~3k publishable rows / ~3 MB on this Mac is in budget for a **single** blob. HQ's own count is UNVERIFIED until someone reads HQ `index.sqlite` with the same `pushCandidates` SQL.

### 5. Publish / pull cycles (locked; Claude B5, B6)

Keep manual `pushProject` / `pullProject` for operators. They are not the live path.

**Publish candidate query:** `OffloadRepo.livePublishCandidates(limit:after:)` uses the same predicates as `pushCandidates` (local origin, non-skip, non-subagent, non-offloaded, both parent columns NULL) **without** a project scope. Page by `(start_time, id)`, never by `start_time` alone. Do **not** call `publishedManifestEntries` (it rewrites `entry.project` and has no `offload_state` guard).

**Publish assembly query (this is what makes the blob cumulative):** `OffloadRepo.livePublishedEntries(peer:)` — a new ledger-join, not a merge of the last 50 candidates. It returns every local-origin, still-publishable session that has an `out` ledger row for this peer, using the latest `content_hash` / `remote_key` per `session_id`, **plus** the `offload_state = 'local'` guard. This is `publishedManifestEntries` minus the project rewrite, plus the offload-state guard. A cycle that cannot read the writer DB fails closed and writes nothing.

Do **not** assemble the generation blob by “previous blob GET + merge the current batch”. A failed or corrupt prior-blob GET must abort the cycle (same class of fail-closed as `pushProject`'s catalog merge at `RemoteSyncCoordinator.swift:461-477`). The monotone set lives in `sync_ledger` + current session rows, not in a chained blob.

**`publishLivePeer`:** page candidates with `livePublishBatch` (default 50) and upload missing/changed bundles via **live-path** publish-only commit (ledger `out`, no `offload_state` flip, no FTS shadow). Then build the generation blob from `livePublishedEntries`. Write **manifest blob first**, then `live.<peer>.head`. Head-first would leave the Mac fetching a missing key.

- While historical backfill is in progress: `complete=false`. The assembled blob is everything in the ledger so far (grows as batches commit). Retract stays off.
- When the publisher has walked the full candidate keyset once with no remaining page: `complete=true`, increment `generation`.
- Later cycles that drop skip/child/offloaded rows write a new `complete=true` generation. `withdrawnCount` is the number of entries present in the previous **complete** generation that are absent from this one.

**Live-path ledger compaction only:** after a live publish of a new hash for `session_id`, delete older `out` rows for that `(peer, session_id)`. Do not change shared `publishOnlyCommit` semantics used by manual `pushProject`.

**Generation-blob retention:** keep the current write and the immediately previous complete write. HQ cannot observe a Mac pull (no read receipts). Delete older `live.<peer>.<generation>.<seq>.manifest` keys only after **two successful HQ publish cycles** have advanced the head. Bundles stay content-addressed and are not GC'd in v1. Revert may leave leftover blobs; ongoing cycles must not.

**`pullLivePeer`:**

1. Fetch head. If missing, no-op.
2. Fetch manifest blob. Verify `contentHash`.
3. Import / update publishable entries through `ImportRepo.commitImported` + writer gate, applying occupancy.
4. **Retract only when `complete == true`.** Incomplete prefixes never retract.
5. Retract API is new: `ImportRepo.retractImportedPeerSessions(db, peer:retainingRemoteSessionIds:)`.
   Select `id FROM sessions WHERE origin = ? AND id LIKE 'remote:' || peer || ':%' ESCAPE '\'` (peer is pinned to `hq` in v1; `ESCAPE` still required). Clear FTS via `FTSRebuildPolicy.replaceFtsContent(..., contents: [])` **before** deleting the session row — same order as today's project-scoped retract. Never delete local-origin rows. NULL `project` is irrelevant. Occupancy-skipped native ids are not retractable orphans.
6. **Shrink guard:** if `complete` and the retract set is `> max(50, 10% of current imported rows for that peer)`, **fail closed**, import nothing in that cycle, surface the error, and persist `live_ingest.hq.shrink_guard_latched=1`. `withdrawnCount` may excuse at most that same cap (`max(50, 10%)`); a publisher cannot disable the guard by writing a huge `withdrawnCount`.
7. **Shrink-guard recovery:** latch clears only after a later complete generation whose retract set is within the cap, or after an operator IPC `liveIngestResetShrinkGuard` (Settings button + mock client). While latched, pulls still **import/update** new/changed entries but do not retract. There is no silent auto-unlatch on the next incomplete blob.

Pull-side visibility filter: if dirty-tree `isPublishable` exists, use it; otherwise Task 0 must add it. Skip / subagent / parent / suggested-parent entries are ignored even if a corrupt blob contains them.

### 6. Hub and security

- Same HQ `EngramRemoteServer`, same bearer token, same TLS policy (`remoteOffloadRequireTLS` stays fail-closed by default).
- Live keys are ordinary blobs. No new anonymous route. Do not enable HQ `POST /mcp`.
- HQ helper binds only the existing private Unix socket (invariant 8).
- Tests: dual temp `HOME` + `CFFIXED_USER_HOME` (invariant 6).

New env bools follow the **enable allowlist** already used by `ENGRAM_REMOTE_OFFLOAD_ENABLED`: only `1` / `true` / `yes` (case-insensitive) are true. `0` / empty / unset is false.

### 7. Settings (new keys, not `syncPeers`)

Mac `~/.engram/settings.json`:

- `liveIngestEnabled` (bool, default **false**)
- `liveIngestSources` (`["hq"]`)
- `liveIngestIntervalSeconds` (int, default `900`, clamp 300…900)
- `liveIngestPeerId` (`"hq"`) — must match HQ

HQ `~/.engram/settings.json`:

- `livePublishEnabled` (bool, default **false**)
- `liveIngestPeerId` (`"hq"`)
- `livePublishBatch` (int, default `50`)
- `remoteOffloadEnabled` **false** on HQ for this feature

Env: `ENGRAM_LIVE_INGEST_ENABLED`, `ENGRAM_LIVE_PUBLISH_ENABLED`, `ENGRAM_LIVE_INGEST_PEER`, `ENGRAM_LIVE_INGEST_INTERVAL_SECONDS`. Token: `ENGRAM_REMOTE_OFFLOAD_TOKEN` / Keychain. `ENGRAM_REMOTE_OFFLOAD_PEER=hq` is an HQ-only peer pin (see §3); the Mac must not set it.

IPC / UI (must be updated together): `EngramServiceProtocol`, DTOs, real client, **and** `MockEngramServiceClient`. Mac Settings shows last pull time, imported count, occupancy-skip count, last error. One toggle: “Include HQ sessions in search”.

### 8. Scheduling

- HQ: index loop, then publish. Debounce 60s after an index generation that changed publishable rows. Timer every `liveIngestIntervalSeconds`.
- Mac: pull on that same interval, plus once when the service is ready.
- SLA starts after HQ **index**, not raw file appearance. Backfill is not the SLA.

### 9. App / MCP consumption (locked; Claude B7)

No second search index.

- App `Session` and search DTOs add `origin: String?`. Badge `HQ` iff `origin == "hq"`.
- MCP search / context / memory items add optional `origin`. No required `machine` filter in v1.
- **Open:** add a virtual locator for `remote://<peer>/<id>` in App transcript load and `MCPTranscriptReader`. The snapshot branch must run **before** `readWithAdapterRegistry`. `isVirtualLocator` alone only skips `lstat`; control must not reach the adapter file open. Render stored summary + FTS lines with caption `HQ 索引快照，不是源文件`. Do not call `archive_get_session`. Do not invent a local path.
- **Resume / open in CLI:** always an honest error (`source lives on HQ`). Never synthesize `cwd` or a helper command.
- Skip stays hidden. `list_sessions` `ORDER BY start_time` unchanged.
- Imported rows use unique `remote://hq/<id>` so the startup `file_path` dedupe DELETE does not collapse them. `source_locator` stays NULL so archive-v2 capture does not treat them as local files. Do not add a missing-file pruner that deletes `origin='hq'` rows.

### 10. Schema

- No new sessions columns. No `FTSRebuildPolicy.expectedVersion` bump (invariant 5).
- Invariant 11 (session schema migrations are idempotent) is untouched because no sessions column is added.
- Metadata only: `live_ingest.hq.last_pull_at`, `live_ingest.hq.last_generation`, `live_publish.hq.last_generation`.
- Live head/manifest are blob-store documents, not SQLite tables.

## Invariants affected

| # | How this design preserves it |
|---|------------------------------|
| 1 Single writer | HQ publish and Mac import run only inside `EngramService` / `ServiceWriterGate`. |
| 2 Skip stays skip | Publish candidates use `pushCandidates` predicates. Pull filters + complete-only retract of `remote:hq:*` only. Import copies `tier`; never upgrades. Prerequisite: retract/`isPublishable` present or ported (Task 0). |
| 3 Tier visibility | Skip never enters a complete live manifest. Lite may import and stay list-visible / keyword-excluded. |
| 5 FTS rebuild version | Per-id `replaceFtsContent` only. |
| 6 Test home | Dual temp homes. |
| 8 Socket security | Existing private socket + bearer hub. No new listener. |
| 11 Sessions schema migrations | No new sessions columns. |
| 12 MCP writes | Ingest is not an MCP tool. |
| 15 Remote MCP honesty | Archive MCP tool set unchanged. HQ `/mcp` stays off. |

New invariant, same implementation change (not before):

- **16. Live ingest is publish-only on the source and import-only on the sink.** Source construction must not arm `drainOffload`. Sink must not offload or re-publish `origin='hq'` rows. Live listing must not use the 4 MiB catalog aggregate.

## Alternatives considered

- **Implement on `origin/main` now.** Rejected: retract / `isPublishable` / visibility fields are not on `d97d0257`; a faithful implementation would ship an invariant 2/3 hole.
- **Reuse `GET /v1/catalog` for the live full-set.** Rejected: 4 MiB aggregate cap; this Mac's publishable slice already ~3 MB.
- **`remoteOffloadEnabled=false` plus today's `makeIfEnabled`.** Rejected: that constructor returns nil; publish would never run.
- **Mac copies HQ source trees and re-indexes.** Rejected as v1 default; escape hatch only.
- **Search-time fan-out / expand m1 archive MCP / revive `syncPeers` / full App on HQ / Unison session dirs.** Rejected as before.

## Test plan

TDD, `*_repro` first, hermetic dual homes. SLA fixture sessions are `normal` or `premium`, not `lite`.

- `testLiveCoordinatorExistsWhenOffloadDisabled_repro` — `livePublishEnabled` builds a backend; `runOnce` is not called; HQ FTS rows unchanged.
- `testLivePeerIdFailsClosedWithoutExplicitPeer_repro` — empty peer env/settings does not fall through to hostname.
- `testLivePublishOmitsSkipSubagentAndSuggestedChildren_repro`
- `testLivePullImportsPublishableRowIntoFtsWithHqOrigin_repro` — token only on HQ; Mac `id == remote:hq:<id>`; `origin == hq`.
- `testLivePullSkipsWhenLocalOriginAlreadyOwnsNativeId_repro` — including a skip/hidden local occupant (no `remote:hq:` row; skip-count increments).
- `testLivePullDoesNotRetractFromIncompleteManifest_repro`
- `testLivePullRetractsWhenCompleteManifestDropsSkip_repro` — only `remote:hq:*`; local-origin rows survive.
- `testLivePullShrinkGuardFailsClosed_repro`
- `testLiveListingDoesNotUseOffloadCatalog_repro` — pull succeeds with a 4 MiB-ineligible catalog fixture.
- `testImportedHqRowIsNotOffloadOrPushCandidate_repro`
- `testHqPublishDoesNotCollapseSourceFts_repro`
- `testLiveManifestAssembledFromLedgerNotLastBatch_repro` — after two batches, an incomplete blob contains both; a failed prior-blob GET (if any implementer adds one) does not shrink.
- `testLiveGenerationBlobRetentionKeepsCurrentAndPrevious_repro`
- `testLiveShrinkGuardRecoversViaOperatorReset_repro`
- `testAppSessionDecodesOriginBadge_repro`
- `testRemoteLocatorRendersSnapshotNotFilesystem_repro` — snapshot before adapter registry; resume errors.

Intentionally not tested in v1: live Tailscale against production HQ, Chrome history, bidirectional merge, m1 as a source, Options-Radar URL UI.

## Rollout

1. Codex finishes Round-12 must-fix (or at least the RemoteSync withdrawal surface) and goes idle.
2. Re-anchor line numbers on that disk; implement there. Defaults remain OFF.
3. HQ: copy `EngramService` only, launchd `RunAtLoad`, `livePublishEnabled=true`, `liveIngestPeerId=hq`, `ENGRAM_REMOTE_OFFLOAD_PEER=hq` (**HQ only**), `remoteOffloadEnabled=false`, existing hub token.
4. Daily Mac: `liveIngestEnabled=true`, `liveIngestSources=["hq"]`, `liveIngestPeerId=hq`. Do not set `ENGRAM_REMOTE_OFFLOAD_PEER=hq`. Keep the current offload URL/token for **local** offload if already used.
5. Spot-check App + MCP search for a unique **session-body** keyword from a new HQ `normal`/`premium` session — not a URL that never entered FTS.

Revert: both flags false; optional `retractImportedPeerSessions` for `hq`. Blobs may remain. No FTS version bump.

No v1.0.6 changelog section as if shipped.

## Risks and locked answers

| Topic | Decision |
|-------|----------|
| Implementation base | Dirty tree after Codex idle, not `d97d0257`. Task 0 ports retract if missing. |
| HQ constructor | `makeLiveIfEnabled`; offload stays independently armed. |
| Peer id | Fail-closed explicit `hq` via live/offload peer keys. No hostname. |
| Catalog cap | Live head + generation blob. Not `GET /v1/catalog`. |
| Partial backfill | `complete=false` ⇒ import only. Retract only when complete + shrink guard. |
| Retract API | New peer-wide function on `remote:<peer>:%` ids only. |
| Transcript open | Snapshot of FTS/summary, before adapter registry. Not archive-get. Resume errors. |
| Cumulative manifest | Ledger-join `livePublishedEntries`, not last-batch and not prior-blob merge. |
| Generation GC | Keep current + previous complete; delete older after head advances. |
| Shrink-guard latch | Import/update still runs; retract off until in-cap complete gen or operator reset. |
| HQ publishable count | UNVERIFIED. Size-cap fail-closed if over 16 MiB. |
| Owner review | Claude via Herdr. |
| Release | No commit/tag unless the owner later asks. |

## Acceptance

- After Codex is idle and this spec's tests are green on that tree: HQ creates a `normal`/`premium` session with a unique user/assistant keyword; within 16 minutes after HQ index+publish, daily-Mac App search and local MCP `search` both hit it with an HQ origin mark.
- A matching local-origin native id is not duplicated.
- A skip/subagent HQ session never appears in Mac keyword search via this path.
- Incomplete live manifests never delete already-imported HQ rows.
- Local-only sessions keep current search behavior.
- m1 `POST /mcp` still exposes only the three archive tools; HQ `/mcp` stays off.
- No commit/tag/release unless the owner later asks.
