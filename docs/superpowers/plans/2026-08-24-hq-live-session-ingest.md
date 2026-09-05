# HQ Live Session Ingest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task on the **current dirty tree** after Codex idle. Steps use checkbox (`- [ ]`) syntax for tracking. Do **not** use a `d97d0257` worktree. Do **not** commit unless the owner asks.

**Goal:** Automatically publish HQ-indexable sessions and import them on the daily Mac as searchable `remote:hq:<id>` rows, without using `GET /v1/catalog` or collapsing HQ FTS.

**Architecture:** Reuse Layer 2 bundles + `ImportRepo.commitImported`. Add `makeLiveIfEnabled` (backend without `runOnce`), live blob keys `live.<peer>.head` / `live.<peer>.<generation>.<seq>.manifest`, ledger-join assembly, complete-only peer retract with shrink guard. App/MCP consume the same local FTS; `remote://` is a snapshot locator.

**Tech Stack:** Swift, GRDB, existing `RemoteStorageBackend`, XCTest, Unix-socket service IPC.

## Global Constraints

- Implement on the dirty tree after Codex idle. No `origin/main` worktree.
- No commit, push, tag, v1.0.6, Round-13, xcodeproj hand-edit, or live XcodeGen unless a new file is unavoidable (prefer existing files).
- Defaults OFF. Writes via `ServiceWriterGate`. Tests set `HOME` + `CFFIXED_USER_HOME`.
- Peer id fail-closed: no hostname fallback for live ingest. Mac must not set `ENGRAM_REMOTE_OFFLOAD_PEER=hq`.
- Live listing is blob GET/PUT, not the 4 MiB catalog aggregate.
- Incomplete manifests never retract. Shrink guard latches; import/update still runs.
- Bundles are FTS+summary, never raw transcripts.
- Task 0 is already satisfied on this disk: `retractImportedSessions`, `isPublishable`, and bundle/manifest visibility fields exist.

---

## File map

- Modify: `macos/EngramCoreWrite/RemoteSync/ManifestCodec.swift` — `LiveIngestHead`, live key helpers, encode/decode, 16 MiB cap constant
- Modify: `macos/EngramCoreWrite/RemoteSync/OffloadRepo.swift` — `livePublishCandidates`, `livePublishedEntries`, live-path ledger compaction
- Modify: `macos/EngramCoreWrite/RemoteSync/ImportRepo.swift` — occupancy helper, `retractImportedPeerSessions`
- Modify: `macos/EngramService/Core/RemoteSyncCoordinator.swift` — `LiveIngestConfig`, `makeLiveIfEnabled`, `publishLivePeer`, `pullLivePeer`
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift` — construct live coordinator independently; never `runOnce` it
- Modify later: Session DTO / MCP transcript / settings / protocol + mock
- Test: `macos/EngramCoreTests/RemoteSync/SessionSyncTests.swift`
- Test: `macos/EngramServiceCoreTests/RemoteSyncCoordinatorTests.swift`

---

### Task 1: Live config + fail-closed peer + coordinator without offload

**Files:**
- Modify: `macos/EngramService/Core/RemoteSyncCoordinator.swift`
- Test: `macos/EngramServiceCoreTests/RemoteSyncCoordinatorTests.swift`

**Interfaces:**
- Produces: `LiveIngestConfig.read(environment:homeDirectory:)`
- Produces: `RemoteSyncCoordinator.makeLiveIfEnabled(gate:environment:) -> RemoteSyncCoordinator?`
- Produces: `LiveIngestConfig.resolvePublishPeer(...)` — `ENGRAM_LIVE_INGEST_PEER` → `liveIngestPeerId` → `ENGRAM_REMOTE_OFFLOAD_PEER`; empty ⇒ nil

- [ ] **Step 1: Write failing tests**

Add to `RemoteSyncCoordinatorTests`:

```swift
func testLiveCoordinatorExistsWhenOffloadDisabled_repro() throws {
    // settings: livePublishEnabled=true, remoteOffloadEnabled=false, liveIngestPeerId=hq
    // HOME+CFFIXED set. makeIfEnabled == nil. makeLiveIfEnabled != nil and peer == "hq"
}

func testLivePeerIdFailsClosedWithoutExplicitPeer_repro() throws {
    // livePublishEnabled=true, no peer keys. makeLiveIfEnabled == nil
    // hostname must not appear
}

func testLiveMacSourcesDivergeFromPeerIdFailsClosed_repro() throws {
    // liveIngestEnabled=true, liveIngestPeerId=hq, liveIngestSources=["other"]
    // makeLiveIfEnabled == nil
}
```

- [ ] **Step 2: Run RED**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramServiceCoreTests/RemoteSyncCoordinatorTests/testLiveCoordinatorExistsWhenOffloadDisabled_repro \
  -only-testing:EngramServiceCoreTests/RemoteSyncCoordinatorTests/testLivePeerIdFailsClosedWithoutExplicitPeer_repro \
  -only-testing:EngramServiceCoreTests/RemoteSyncCoordinatorTests/testLiveMacSourcesDivergeFromPeerIdFailsClosed_repro
```

Expected: compile or XCTFail because `makeLiveIfEnabled` / `LiveIngestConfig` do not exist.

- [ ] **Step 3: Minimal implementation** — `LiveIngestConfig` + shared backend builder + `makeLiveIfEnabled`. Enable allowlist `1/true/yes`. Interval clamp 300…900.

- [ ] **Step 4: Run GREEN** — same xcodebuild, 3/3 pass.

---

### Task 2: Occupancy + peer-wide retract

**Files:**
- Modify: `macos/EngramCoreWrite/RemoteSync/ImportRepo.swift`
- Test: `macos/EngramCoreTests/RemoteSync/SessionSyncTests.swift`

**Interfaces:**
- Produces: `ImportRepo.localOriginOccupiesNativeId(_ db:peerSessionId:) -> Bool`
- Produces: `ImportRepo.retractImportedPeerSessions(_ db:peer:retainingRemoteSessionIds:) -> Int`

- [ ] **Step 1: Failing tests** `testLivePullSkipsWhenLocalOriginAlreadyOwnsNativeId_repro` (including skip occupant), `testLivePullRetractsWhenCompleteManifestDropsSkip_repro` (only `remote:hq:*`, FTS cleared), `testLivePullDoesNotRetractLocalOrigin_repro`.

- [ ] **Step 2: RED** via `EngramCoreTests/SessionSyncTests`

- [ ] **Step 3: Implement** occupancy + retract with FTS clear then DELETE, `LIKE 'remote:' || peer || ':%' ESCAPE '\'`.

- [ ] **Step 4: GREEN**

---

### Task 3: Live candidate + ledger-join assembly

**Files:**
- Modify: `macos/EngramCoreWrite/RemoteSync/OffloadRepo.swift`
- Test: `macos/EngramCoreTests/RemoteSync/SessionSyncTests.swift`

**Interfaces:**
- Produces: `OffloadRepo.livePublishCandidates(limit:afterStart:afterId:)`
- Produces: `OffloadRepo.livePublishedEntries(peer:)`
- Produces: `OffloadRepo.compactLivePublishLedger(peer:sessionId:)` (live path only)

- [ ] Tests: omit skip/subagent/suggested-parent; page by `(start_time,id)`; assembly contains all ledger rows not last batch; imported origin excluded; offloaded excluded.

---

### Task 4: Live head/manifest codec + keys

**Files:**
- Modify: `macos/EngramCoreWrite/RemoteSync/ManifestCodec.swift`
- Test: `macos/EngramCoreTests/RemoteSync/SessionSyncTests.swift`

**Interfaces:**
- Produces: `LiveIngestHead` (`peer, generation, seq, complete, entryCount, manifestKey, contentHash, withdrawnCount`)
- Produces: `LiveIngestKeys.head(peer:)`, `.manifest(peer:generation:seq:)`
- Produces: encode/decode; `maxLiveManifestBytes = 16 * 1024 * 1024`
- Keys must pass `RemoteStorageKey.validate` and must **not** match `ManifestCodec.isManifestKey`

---

### Task 5: publishLivePeer + pullLivePeer

**Files:**
- Modify: `macos/EngramService/Core/RemoteSyncCoordinator.swift`
- Test: `macos/EngramServiceCoreTests/RemoteSyncCoordinatorTests.swift`

**Interfaces:**
- Produces: `publishLivePeer(batch:completeWalk:)` writes bundles, ledger (no FTS collapse), manifest then head
- Produces: `pullLivePeer(peer:)` import/update, occupancy, complete-only retract, shrink guard + latch metadata
- Produces: generation retention (keep current + previous complete; delete after 2 successful publish cycles)

Tests from spec: import into FTS with `origin=hq`; no catalog usage; incomplete no retract; shrink guard fail-closed + recover IPC later; HQ FTS unchanged; listing keys not in catalog.

---

### Task 6: Runner wiring

**Files:**
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift`
- Test: existing runner/command tests or a focused service test that live coordinator is constructed when offload is off and `runOnce` is not invoked on it.

---

### Task 7: App origin badge + remote snapshot + MCP

**Files:**
- Modify: `macos/Engram/Models/Session.swift`, search DTOs, `MCPTranscriptReader.swift`, protocol + mock + settings
- Tests: App Session decode origin; `testRemoteLocatorRendersSnapshotNotFilesystem_repro`

---

### Task 8: Honest docs

- Append unreleased note to CHANGELOG/MEMO only if behavior is on disk and `_repro`s are green. Do not claim v1.0.6. Park residuals in `docs/followups.md`.
- No commit.

---

## Execution note

Owner said start now. Execute inline with TDD. Skip every “Commit” step. Stop if a test cannot be made to fail for the intended reason.
