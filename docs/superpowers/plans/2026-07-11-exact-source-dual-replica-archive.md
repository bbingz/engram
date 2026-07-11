# Exact-Source Dual-Replica Archive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILLS: `superpowers:subagent-driven-development`, `superpowers:test-driven-development`, and `scoped-task-worker`. Implement one task at a time. Observe RED before production edits, produce a worker report, run the task verifier, commit, and pass both spec-compliance and code-quality review before starting the next task.

**Goal:** Add exact capture for adapter-declared, replay-proven source files, an immutable `/v2/archive` server, two independent remote replicas, and verified local/HQ/M1 transcript recovery without adding any deletion path.

**Design:** `docs/superpowers/specs/2026-07-11-exact-source-dual-replica-archive-design.md`

**Baseline:** `95c73bf7`

**Tech stack:** Swift 5.9/6 toolchain, CryptoKit, Compression/LZFSE, Darwin POSIX APIs, GRDB/SQLite, Hummingbird 2, URLSession, Security/Keychain, XCTest, XcodeGen.

## Global Constraints

- Work only in `/Users/bing/orca/workspaces/engram/archive-v2-dual-replica` on `bbingz/archive-v2-dual-replica`.
- Treat the Swift macOS product as authoritative. Do not add a Node product path.
- Preserve `/v1/bundles` and legacy offload behavior. Archive v2 uses new types, tables, credentials, coordinator, routes, and storage roots.
- Never edit `macos/Engram.xcodeproj` directly. Edit `macos/project.yml`, run `xcodegen generate`, and commit generated project changes only if the repository tracks them.
- No source unlink, local archive delete/evict/GC, remote final-object delete/GC, public endpoint, deployment, service restart, or production credential change.
- Every production behavior starts with a focused failing test whose failure is caused by the missing behavior, not a compile error unrelated to the assertion.
- Do not use a HEAD response as durability proof. Persist and verify a server-specific receipt.
- Capture is deny-by-default: only adapters with an explicit `ExactArchiveSourceAdapter` descriptor and a delete-original/replay fixture may be enabled. Do not infer source completeness from a regular-file locator.
- Do not put archive payload blobs in `index.sqlite`.
- Each task ends with `git diff --check`, its focused test scheme, a scoped commit, worker report, and two-gate review.
- Production deployment to `macmini-hq` and `macmini-m1` is explicitly outside this plan.

## Required Test Fixtures

Create temporary directories inside XCTest and clean them in `tearDown`. Fixture payloads must include:

- empty data;
- UTF-8 JSONL with CRLF and BOM;
- embedded NUL and invalid UTF-8 bytes;
- an exact 8 MiB chunk;
- an 8 MiB + 1 byte request;
- a multi-chunk payload with a truncated final JSONL record.

Tests must compare `Data`, not decoded strings, for archive exactness.

---

### Task 1: Canonical Archive Wire Models and Hashing

**Files:**

- Create: `macos/Shared/EngramCore/ArchiveV2/ArchiveHash.swift`
- Create: `macos/Shared/EngramCore/ArchiveV2/ArchiveCanonicalJSON.swift`
- Create: `macos/Shared/EngramCore/ArchiveV2/ArchiveModels.swift`
- Create: `macos/EngramCoreTests/ArchiveV2/ArchiveModelTests.swift`
- Modify: `macos/project.yml` only if target source membership requires it

**Interfaces:**

```swift
public enum ArchiveV2Hash {
    public static func sha256(_ data: Data) -> String
    public static func isValidSHA256(_ value: String) -> Bool
}

public enum ArchiveCanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

public struct ArchiveSourceGeneration: Codable, Equatable, Sendable { ... }
public struct ArchiveChunkReference: Codable, Equatable, Sendable { ... }
public struct ArchiveSourceManifest: Codable, Equatable, Sendable { ... }
public struct ArchiveServerReceipt: Codable, Equatable, Sendable { ... }
```

Models use strings/integers only for timestamps and sizes, validate `schemaVersion == 1`, lowercase 64-character digests, contiguous chunk ordinals, exact aggregate raw byte count, and bound receipt requirements.

- [ ] **Step 1: RED — canonical bytes and validation**

Add tests asserting stable sorted-key JSON bytes, round-trip equality, known SHA-256 vectors, invalid uppercase/short digests rejected, non-contiguous chunks rejected, aggregate byte mismatch rejected, and a receipt without `sessionID` rejected. Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' \
  -only-testing:EngramCoreTests/ArchiveModelTests CODE_SIGNING_ALLOWED=NO
```

Expected RED: the new model/hash symbols do not exist. If adding an empty compile shell is needed to reach behavioral RED, keep it test-only.

- [ ] **Step 2: GREEN — minimum canonical implementation**

Use `JSONEncoder` with `.sortedKeys` and `.withoutEscapingSlashes`; do not encode `Date` or floating point. Add validating initializers or `validate()` methods and decode-time validation at every trust boundary.

- [ ] **Step 3: Verify target membership**

Run `xcodegen generate` whenever new source files need generated PBX file references, even if the recursive source declaration in `project.yml` itself did not change. Rerun the focused test, then run:

```bash
git diff --check
git status --short
```

- [ ] **Step 4: Commit**

```bash
git add macos/Shared/EngramCore/ArchiveV2 macos/EngramCoreTests/ArchiveV2 macos/project.yml macos/Engram.xcodeproj
git commit -m "feat(archive): define canonical v2 wire models"
```

Stage only paths that actually changed.

---

### Task 2: Local Immutable CAS and Independent Archive Catalog

**Files:**

- Create: `macos/EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift`
- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift`
- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalogMigrations.swift`
- Create: `macos/EngramCoreTests/ArchiveV2/ImmutableArchiveCASTests.swift`
- Create: `macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift`

**Interfaces:**

```swift
public struct ImmutableArchiveCAS: Sendable {
    public init(root: URL) throws
    public func publishObject(raw: Data, expectedSHA256: String) throws -> ArchivePublishResult
    public func readObject(sha256: String) throws -> Data
    public func publishManifest(_ bytes: Data, expectedSHA256: String) throws -> ArchivePublishResult
    public func readManifest(sha256: String) throws -> Data
}

public final class ArchiveCatalog: @unchecked Sendable {
    public init(root: URL) throws
    public func migrate() throws
    public func recordCapture(...) throws
    public func bind(...) throws
    public func upsertReplicaState(...) throws
    public func pendingReplicaWork(...) throws -> [ArchiveReplicaWork]
    public func latestBinding(sessionID: String) throws -> ArchiveBinding?
}
```

`ArchiveCatalog` opens `<root>/archive.sqlite`, uses idempotent GRDB migrations and `synchronous=FULL`, and never attaches or migrates `index.sqlite`.

- [ ] **Step 1: RED — immutable publication**

Test exact binary round-trip, empty object, dedupe without modifying mtime/inode, expected-digest mismatch, manually corrupted existing object conflict without overwrite, symlink final path rejection, owner-only directories/files, and no public delete method.

- [ ] **Step 2: GREEN — POSIX publication**

Use same-directory temp files, `O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC`, a full short-write loop, file `fsync`, `link`/exclusive final publication, temp unlink, and parent-directory `fsync`. On `EEXIST`, read and re-hash the existing regular file; never replace it.

- [ ] **Step 3: RED — catalog migration and state**

Test fresh migration, repeat migration, persisted machine UUID, capture idempotency, immutable generation fields, bound/unbound manifests, independent `(manifestSHA256, replicaID)` states retaining capture ID, stale-inflight recovery, and absence of archive tables from a separately created `index.sqlite`.

- [ ] **Step 4: GREEN — catalog**

Implement only the four tables in the design. Keep receipt bytes and receipt digest together. Reject a second receipt for the same replica/manifest if its canonical bytes differ.

- [ ] **Step 5: Verify and commit**

Run both focused test classes and `git diff --check`; commit:

```bash
git commit -am "feat(archive): add immutable local store and catalog"
```

Include newly created paths with `git add`; do not use `git add -A`.

---

### Task 3: Stable Regular-File Capture Before Parsing

**Files:**

- Create: `macos/EngramCoreWrite/ArchiveV2/ExactSourceCapturer.swift`
- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveCaptureCoordinator.swift`
- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveLocatorClassifier.swift`
- Create: `macos/Shared/EngramCore/ArchiveV2/ArchiveSourceDescriptor.swift`
- Modify: `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift`
- Modify: `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`
- Create: `macos/EngramCoreTests/ArchiveV2/ExactSourceCapturerTests.swift`
- Create: `macos/EngramCoreTests/ArchiveV2/ArchiveCaptureCoordinatorTests.swift`

**Interfaces:**

```swift
public enum ArchiveLocatorClassification: Equatable, Sendable {
    case declaredSingleFile(URL)
    case missing
    case unsupportedComposite
    case unsupportedVirtual
    case unsupportedAdapter
    case unsafe(String)
}

public protocol ExactArchiveSourceAdapter: SessionAdapter {
    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor
}

public struct ExactSourceCapturer: Sendable {
    public func capture(source: SourceName, locator: String, machineID: String) throws -> ArchiveCaptureResult
}

public actor ArchiveCaptureCoordinator {
    public func capture(adapters: [any SessionAdapter]) async -> ArchiveCaptureCycleResult
    public func bind(_ sessions: [ArchiveSessionIdentity]) throws -> ArchiveBindingCycleResult
}
```

- [ ] **Step 1: RED — locator classification**

Test a descriptor-declared ordinary file, missing file, directory, symlink, FIFO, an undeclared adapter, `db.sqlite::session`, and `db.sqlite?composer=id`. Explicitly prove unsupported/unsafe cases do not produce objects or verified captures. Assert Kimi, Copilot, Antigravity, Cursor, and OpenCode are not enabled by a regular-file `stat` result.

- [ ] **Step 2: RED — generation race**

Inject a read hook or file-operation seam that appends/replaces the file between the two `fstat` calls. Assert no verified capture or manifest is committed. Test source mode, size, and bytes are unchanged by capture.

- [ ] **Step 3: GREEN — streamed capture**

Read one descriptor in 8 MiB chunks, hash chunk and whole source incrementally, publish immutable objects, compare pre/post identity, then publish and record the unbound manifest. Do not decode text and do not call an adapter parser.

- [ ] **Step 4: RED/GREEN — coordinator and binding**

Use fake adapters to prove locator enumeration and capture occur before an injected parse marker, unchanged captures are idempotent, and parser failure leaves an unbound capture. Binding requires exactly one normalized `(source, locator)` session match plus a structured `parse_status = ok` generation proof whose capture ID/source/locator/size/mtime/inode/device match the capture; its snapshot fingerprint is derived internally rather than accepted from the caller. Then re-open and re-hash the source to prove it is still the captured generation. Test stale rows after parser failure, append after capture, atomic replacement, duplicate session matches, and pre-cancellation; all unsafe cases remain unbound. Add Claude Code and Codex fixtures that delete the original tree, reconstruct the descriptor layout from archive objects, and obtain equivalent messages through the same adapter.

- [ ] **Step 5: Verify and commit**

Run the two focused test classes plus existing `IndexerParseOnceTests`; run `git diff --check`; commit:

```bash
git commit -m "feat(archive): capture stable regular-file generations"
```

---

### Task 4: Immutable `/v2/archive` Server

**Files:**

- Create: `macos/EngramRemoteServer/Core/ArchiveEnvelopeCodec.swift`
- Create: `macos/EngramRemoteServer/Core/ArchiveStore.swift`
- Create: `macos/EngramRemoteServer/Core/ArchiveRoutes.swift`
- Modify: `macos/EngramRemoteServer/Core/EngramRemoteServerConfig.swift`
- Modify: `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift`
- Modify: `macos/Shared/EngramCore/ArchiveV2/ArchiveModels.swift` for shared bounded machine/receipt page DTOs and protocol limits
- Modify: `macos/project.yml`
- Create: `macos/EngramRemoteServerCoreTests/ArchiveStoreTests.swift`
- Create: `macos/EngramRemoteServerCoreTests/ArchiveRouteTests.swift`
- Modify: `macos/EngramRemoteServerCoreTests/EngramRemoteServerTests.swift` only for explicit v1 compatibility assertions

**Interfaces:**

```swift
public struct ArchiveStore: Sendable {
    public func putObject(digest: String, raw: Data) throws -> ArchivePublishResult
    public func getObject(digest: String) throws -> Data
    public func putManifest(digest: String, canonicalBytes: Data) throws -> ArchivePublishResult
    public func getManifest(digest: String) throws -> Data
    public func createReceipt(manifestDigest: String) throws -> Data
    public func getReceipt(manifestDigest: String) throws -> Data
    public func listMachines(cursor: String?, limit: Int) throws -> ArchiveMachinePage
    public func listReceipts(machineID: String, cursor: String?, limit: Int) throws -> ArchiveReceiptPage
}
```

- [ ] **Step 1: RED — config isolation**

Prove legacy config starts with v2 disabled, enabling v2 requires server ID and absolute archive root, and v1 store root remains unchanged. When v2 is enabled, accept only loopback or literal Tailscale IPv4/IPv6 bind addresses; reject wildcard, public, RFC1918/LAN, and DNS bind names. Add `Shared/EngramCore/ArchiveV2` to `EngramRemoteServerCore` sources without adding a dependency on `EngramCoreWrite`.

- [ ] **Step 2: RED — encrypted immutable store**

Test compression-before-encryption round-trip, ciphertext not containing a plaintext sentinel, AAD/digest/codec tamper rejection, wrong-key restart rejection, identical repeat PUT with unchanged file identity, corrupt existing path conflict/no overwrite, and symlink rejection.

- [ ] **Step 3: GREEN — envelope and publication**

Use LZFSE only when it reduces size. AAD binds version/kind/digest/codec/raw length. Reuse the strict POSIX publication semantics from the design, but do not reuse mutable `BlobStore`.

- [ ] **Step 4: RED — HTTP contract**

Test auth on every route; object 8 MiB success and +1 rejection; path/body mismatch; binary GET; manifest missing-reference conflict; corrupt-reference conflict; coherent manifest success; idempotent receipt; bounded deterministic machine listing and receipt-list pagination with malformed/non-advancing cursor rejection; bounded redacted errors; verified HEAD; all v2 DELETE variants `405`; wrong-key restart; existing v1 PUT/GET/DELETE still pass.

- [ ] **Step 5: GREEN — routes**

Mount archive routes only when v2 is enabled. Receipt creation loads and verifies the bound manifest and every object after durable publication. Store the first canonical receipt so repeated calls preserve `storedAt` and receipt digest. Enforce shared object/manifest/receipt/page/cursor/error limits while reading, not after unbounded buffering, and derive discovery only from immutable receipt namespaces.

- [ ] **Step 6: Verify and commit**

Run:

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramRemoteServerCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Commit:

```bash
git commit -m "feat(remote): add immutable archive v2 protocol"
```

---

### Task 5: Archive-Only HTTP Client and Dual-Replica State Machine

**Files:**

- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveReplicaBackend.swift`
- Create: `macos/EngramCoreWrite/ArchiveV2/HTTPArchiveReplicaBackend.swift`
- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveReplicationCoordinator.swift`
- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveCredentialStore.swift`
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift`
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalogMigrations.swift`
- Modify: `macos/Shared/EngramCore/ArchiveV2/ArchiveModels.swift` for strict receipt timestamp/page decoding if Task 4 has not already done so
- Create: `macos/EngramCoreTests/ArchiveV2/HTTPArchiveReplicaBackendTests.swift`
- Create: `macos/EngramCoreTests/ArchiveV2/ArchiveReplicationCoordinatorTests.swift`

**Interfaces:**

```swift
public protocol ArchiveReplicaBackend: Sendable {
    var replicaID: String { get }
    func headObject(digest: String) async throws -> Bool
    func putObject(digest: String, data: Data) async throws
    func getObject(digest: String) async throws -> Data
    func headManifest(digest: String) async throws -> Bool
    func putManifest(digest: String, data: Data) async throws
    func getManifest(digest: String) async throws -> Data
    func createReceipt(manifestDigest: String) async throws -> Data
    func getReceipt(manifestDigest: String) async throws -> Data
    func listMachines(cursor: String?, limit: Int) async throws -> ArchiveMachinePage
    func listReceipts(machineID: String, cursor: String?, limit: Int) async throws -> ArchiveReceiptPage
}

public actor ArchiveReplicationCoordinator {
    public func runOnce(limit: Int) async -> ArchiveReplicationCycleResult
    public func retryQuarantined(replicaID: String?) throws
}
```

There is deliberately no delete method.

Frozen Task 5 constants and semantics:

- the current replica set is exactly `hq` plus `m1`; `runOnce(limit:)` counts replica rows;
- request/resource timeouts are 30/120 seconds;
- retry is 60-second-base full jitter capped at 24 hours;
- first/idempotent concurrent PUT may return `201`/`200`, but only independent receipt GET is durable proof;
- manual retry touches only quarantined rows for the selected current replica (or both when nil), resets attempts, and increments `claim_generation`;
- schema v2 adds binding `project_root_snapshot`, fail-closed `remote_eligibility`, and receipt-row `claim_generation`. Task 5 reconciles only `eligible`; Task 6 derives and records eligibility from its gated snapshot.

- [ ] **Step 1: RED — transport confinement**

Test HTTPS `.ts.net` plus policy-allowed literal Tailscale IPv4 `100.64.0.0/10` and IPv6 `fd7a:115c:a1e0::/48`. Loopback exists only behind an internal test override. Refuse every public host even over HTTPS, RFC1918/link-local, `.local`, wildcard/zone-scoped addresses, malformed `.ts.net`, bare names, userinfo/query/fragment/non-root paths, and normalized duplicate origins. Require replica IDs exactly `hq` and `m1`, distinct normalized origins, and loaded non-empty distinct token values. Prove redirects are never followed and the redirect target never receives Authorization. Do not reuse legacy `isPrivateHost`.

- [ ] **Step 2: GREEN — HTTP backend and credentials**

Own an ephemeral no-cookie/no-cache/no-credential/no-proxy session with a no-redirect delegate, `waitsForConnectivity=false`, 30-second request timeout, and 120-second resource timeout; inject only a bounded low-level transport/test protocol, not an arbitrary redirect-following session. Store tokens under Keychain service `com.engram.remote-archive-v2`, accounts `replica:<id>`, using update-first writes. Never reuse the v1 credential account. Move canonical fractional-second UTC validation for receipt `storedAt` into the shared wire model.

- [ ] **Step 3: RED — dual state machine**

With two fake replicas, prove:

- hq success/m1 failure records one verified receipt and retries only m1;
- two receipts with different `serverID` but the same manifest are required;
- a receipt with wrong replica/server/manifest/machine/session is quarantined;
- cancellation does not increment attempts;
- transient error/5xx retries with capped backoff;
- contradiction/422 quarantines;
- stale in-flight work requeues after ten minutes;
- verified hq is not re-uploaded when m1 retries;
- a stale worker cannot regress verified state, and restart reconciliation seeds any missing replica row for every eligible historical binding;
- no legacy remote backend, offload queue, FTS mutation, or vacuum method is invoked.
- migrated/new bindings remain `remote_eligibility=unknown` and seed nothing until Task 6 records a trusted `eligible` snapshot;
- stale recovery and manual retry invalidate prior workers by advancing monotonic `claim_generation`.

- [ ] **Step 4: GREEN — replication**

Use verified HEAD to upload only missing objects, then the manifest, request a receipt, fetch it independently, require exact canonical bytes plus every binding field and canonical timestamp, then atomically persist. Accept verified first/idempotent PUT statuses `201`/`200`, but HEAD/PUT success is never durability evidence. Use state-plus-generation compare-and-set claims/transitions and heartbeat each uploaded chunk, retry only the failed replica with 60-second-base full jitter, classify auth/protocol contradictions as quarantine and transient network/408/429/5xx as bounded retry, and derive dual durability only from both current configured verified rows for the same bound manifest.

- [ ] **Step 5: Verify and commit**

Run focused archive client/coordinator tests and existing `RemoteOffloadTests`; run `git diff --check`; commit:

```bash
git commit -m "feat(archive): replicate to two independent servers"
```

---

### Task 6: Service Orchestration, Configuration, Status, and Offline Behavior

**Files:**

- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCaptureCoordinator.swift`
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift`
- Modify: `macos/EngramCoreTests/ArchiveV2/ArchiveCaptureCoordinatorTests.swift`
- Modify: `macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift`
- Create: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Create: `macos/EngramService/Core/ArchiveV2Settings.swift`
- Create: `macos/EngramService/Core/EngramServiceCommandHandler+ArchiveV2.swift`
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Modify: `macos/Shared/Service/EngramServiceProtocol.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/Shared/Service/MockEngramServiceClient.swift`
- Modify: `macos/Shared/Service/ServiceCapabilityToken.swift`
- Modify: `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift` to preserve exact-source conformance in the periodic recent wrapper
- Create: `macos/EngramCoreTests/ArchiveV2/ArchiveV2RecentAdapterTests.swift`
- Create: `macos/EngramServiceCoreTests/ArchiveV2SettingsTests.swift`
- Create: `macos/EngramServiceCoreTests/ArchiveV2ServiceWireTests.swift`
- Create: `macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift`
- Create: `macos/EngramServiceCoreTests/ArchiveV2IPCTests.swift`

**Behavior:**

Archive v2 is default-off. When enabled, startup and periodic cycles execute:

```text
capture supported locators outside ServiceWriterGate
-> existing indexing through ServiceWriterGate
-> one brief gated snapshot joining sessions to successful file_index_state identities and cwd/project root
-> bind in archive.sqlite outside the gate
-> bounded dual replication outside the gate
```

Before service composition, add bounded Core support without a fifth table: a global fair budget for source-byte capture after locator discovery, a binding row budget whose continuation advances past poison rows, stable bounded enumeration of historical unknown bindings, and a fixed-size current-replica status aggregate. Continuation envelopes live under archive-owned `archive_metadata` keys and are digest-checked on every read.

**Zero-deletion v1 discovery exception:** Claude Code and Codex locator discovery remains a cooperative-cancellable `O(N)` filesystem traversal that materializes and sorts the current locator set before the capture budget is applied. `batchSize` bounds source-byte capture, binding, policy, and replication work; it does not bound locator discovery. A restart-stable hard-bounded filesystem cursor cannot be represented safely by the metadata token alone: directory cookies are tied to a live directory stream, while a path cursor must rescan from the root after restart. Claiming bounded discovery therefore requires a future durable locator inventory/work queue (normally bootstrapped by one explicit full crawl and maintained with FSEvents). This operational exception does not weaken capture-before-parse, archive integrity, or deletion safety; v1 remains default-off and performs no source deletion.

- [ ] **Step 1: RED — settings and fail-closed policy**

Test environment/settings precedence, default off with no archive side effects, `batchSize` default `20` and range `1...100`, atomic whole-object remote environment override, exact two distinct replicas, no token environment variables, missing Keychain token disables remote replication with a status error, project exclusion, absent/ambiguous cwd remote exclusion, persisted project-root/eligibility snapshot, restart reconciliation, and local capture still allowed for remote-excluded projects.

- [ ] **Step 2: RED — orchestration order**

Use fakes to record capture, index, one brief gated snapshot, bind, reconcile, and replicate calls. Assert capture precedes the parser/index marker, archive I/O does not hold the writer gate, parser failure or non-`ok`/stale `file_index_state` retains capture, unchanged `ok` index state still permits first capture, and remote offline errors do not fail service readiness or index success. The gated snapshot preserves all duplicate locator rows, constructs capture-exact Task 3 proofs, and never calls a parser.

Also assert that binding refuses a changed post-index generation and an ambiguous `(source, locator)` result rather than associating capture A with parsed generation B.

- [ ] **Step 3: GREEN — composition root**

Create one archive coordinator from the index database sibling path `archive-v2`. Thread the same instance through runner and handler without changing default-off execution. Startup performs cancellable full Claude/Codex locator discovery followed by bounded exact source-byte capture; periodic capture uses an exact-conformance-preserving recent wrapper plus bounded retry of earlier transient capture failures. Explicitly single-flight/coalesce cycles, persist fair capture/bind cursors, bound post-discovery capture/bind/policy/remote work, recover stale in-flight state and historical unknown policy on restart, and check cancellation between files/replicas. The indexing loop waits for the initial scan before starting its first periodic archive cycle.

- [ ] **Step 4: RED/GREEN — IPC**

Add `archiveV2Status` and `archiveV2Retry`. Status is read-only, bounded, and telemetry-excluded; retry is capability-protected, accepts only `nil|hq|m1`, and only resets eligible quarantined current-replica work without starting network activity. Prove there is no archive delete/evict/GC/reclaim command and no capability token grants one.

- [ ] **Step 5: Verify and commit**

Run `ArchiveV2ServiceCoordinatorTests`, `ArchiveV2IPCTests`, existing `RemoteSyncCoordinatorTests`, and `RemoteSyncIPCTests`; run `git diff --check`; commit:

```bash
git commit -m "feat(service): orchestrate exact dual-replica archive"
```

---

### Task 7: Verified Local/HQ/M1 Transcript Fallback and Clean Recovery

**Files:**

- Create: `macos/EngramService/Core/ArchiveTranscriptResolver.swift`
- Create: `macos/EngramService/Core/EngramServiceCommandHandler+ArchiveTranscript.swift`
- Modify: `macos/EngramService/Core/TranscriptExportService.swift`
- Modify: `macos/Shared/Service/EngramServiceProtocol.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/EngramMCP/Core/MCPTranscriptTools.swift`
- Create: `macos/EngramServiceCoreTests/ArchiveTranscriptResolverTests.swift`
- Modify: `macos/EngramServiceCoreTests/TranscriptExportServiceTests.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Create: `macos/EngramRemoteServerCoreTests/ArchiveRecoveryIntegrationTests.swift`

**Resolution contract:** first select bytes with a typed outcome (`live -> local bound manifest -> hq -> m1`), then invoke the existing parser exactly once. Only definitive source unavailability leaves live. A live/local/remote parser failure never silently selects another generation or replica, and cancellation never advances tiers.

- [ ] **Step 1: RED — exact materialization**

Test one locked latest manifest digest, its persisted verified receipt per remote replica, local reconstruction, and every per-chunk plus whole-source digest. Stream to an exclusive owner-only temp file instead of concatenating the transcript in memory. Test zero-byte sources, secure permissions/cleanup on every exit, and rejection of corrupt/missing objects.

- [ ] **Step 2: RED — fallback order**

Use fake backends to prove live/local/hq/m1 order by replica ID, no service/remote request on live/local success, hq absence/transport/integrity error falls through to m1, parser errors do not fall through, and cancellation does not call the next tier.

- [ ] **Step 3: GREEN — resolver**

Materialize the same canonical manifest digest to an owner-only temporary regular file beneath its declared replay path, parse through the existing adapter/reader using the archived source name, and remove the isolated temp root after the result is materialized. Keep audit locator, live path, replay path, and temp path distinct. Keep network and Keychain access in EngramService.

- [ ] **Step 4: RED/GREEN — service export and MCP page**

Add a read-only bounded `archiveReadSessionPage` command and DTO. The service accepts bounded session ID, page, page size, and user/assistant role filter; it owns live/local/HQ/M1 resolution plus visible-message pagination and returns messages, total pages, current page, transcript completeness, and a separate response-budget truncation field. MCP invokes it only after a typed definitive local-source-unavailable result and retains `include_raw` redaction/output shaping. Encode the real outer Unix-socket response and enforce a conservative aggregate content budget below the 256 KiB frame after JSON/base64 expansion. IPC must not return raw archive bytes, receipt/manifest bytes, or a temporary path. Preserve `transcriptTooLarge` mapping and route export through the same resolver.

- [ ] **Step 5: RED/GREEN — clean-machine recovery**

Start two in-process archive routers with separate roots, keys, tokens, and server IDs. Replicate multiple generations including one multi-chunk capture; delete the test client's temporary catalog/CAS and machine ID without constructing a replacement catalog; list machine IDs from a server, select one, page receipts with cursor-progress/cycle checks, download manifest/objects, and assert byte-identical collision-safe reconstruction under `<machine>/<manifest>/<replay-path>`. Stop hq, restart m1 pagination from a nil cursor, and prove m1 fallback.

- [ ] **Step 6: Verify and commit**

Run focused service/MCP/server tests, existing MCP transcript paging/redaction tests, and `git diff --check`; commit:

```bash
git commit -m "feat(archive): recover transcripts from local and remote copies"
```

---

### Task 8: Documentation, Static Safety Gates, and Full Verification

**Files:**

- Create: `docs/remote-archive-v2.md`
- Modify: `docs/PRIVACY.md`
- Modify: `docs/roadmap.md`
- Modify: `docs/TODO.md` or `docs/followups.md` only for precise remaining non-deployment work
- Modify: relevant `.github/workflows/*.yml` only if the remote-server scheme is absent from CI
- Create or modify: repository safety script only if no existing boundary script can express the checks

- [ ] **Step 1: RED/GREEN — documentation contract**

Document v1 artifacts versus v2 raw bytes, default-off behavior, Tailscale-only topology, separate keys/tokens, honest online-compromise limits, unsupported locator classes, zero-deletion release, configuration, health/status, backup prerequisites, and rollback by disabling v2 without deleting bytes.

- [ ] **Step 2: Static no-delete and namespace gates**

Add/extend a test or script proving:

- `/v2/archive` has no successful DELETE handler;
- new archive modules contain no source `unlink`/`removeItem` except temporary-file cleanup;
- `ArchiveReplicaBackend` has no delete method;
- v2 does not reference legacy offload commit/purge/vacuum APIs;
- release bundle remains Swift-only.

- [ ] **Step 3: Regenerate and focused matrix**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramRemoteServerCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 4: Product build and boundary verification**

```bash
cd macos
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build CODE_SIGNING_ALLOWED=NO
./scripts/release-verify.sh <built-app-path> --adhoc
```

Do not install, launch, restart, or deploy the product.

- [ ] **Step 5: Repository checks**

```bash
git diff --check
git status --short
git log --oneline --decorate -10
```

Confirm all changes belong to archive v2 and all task commits are present.

- [ ] **Step 6: Final review and commit**

Run an independent full-diff reviewer against the design and plan. Resolve every confirmed correctness/security/data-loss issue. Commit documentation and gates:

```bash
git commit -m "docs: add dual-replica archive runbook and gates"
```

## Failure Handling

- If a focused RED does not fail for the intended reason, fix the test before production code.
- If an adapter lacks an explicit replay-proven archive descriptor, classify it unsupported even when its locator is a regular file; do not broaden scope inside that task.
- If Hummingbird cannot express a required bounded route safely, stop that task and produce a minimal reproducer; do not weaken hash, size, auth, or no-overwrite guarantees.
- If POSIX durability calls are unavailable or untestable on macOS, retain no-overwrite and hash verification, mark the exact unsupported guarantee, and do not issue receipts until the gap is closed.
- If either remote is unavailable, record retry state and continue local operation. Do not convert offline state into index failure.
- If a test failure is pre-existing, prove it against baseline `95c73bf7`; do not mask it or expand scope.
- If XcodeGen creates unrelated project drift, revert only generated drift caused by the current task after inspecting it; never edit the project file manually.

## Completion Evidence

The branch is complete only with:

- focused RED/GREEN logs or worker reports for Tasks 1-7;
- one scoped commit per task;
- task-level spec and quality approvals;
- full Swift scheme results;
- two-independent-server integration recovery result;
- static no-delete evidence;
- product Debug build and release boundary check;
- clean worktree except explicitly documented generated/test artifacts;
- no production deployment or service mutation.
