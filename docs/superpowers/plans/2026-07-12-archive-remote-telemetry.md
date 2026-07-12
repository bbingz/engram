# Archive Remote Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist bounded sanitized telemetry on each `EngramRemoteServer`, expose it through authenticated archive-v2 status, and show independent HQ/M1 runtime state in Engram settings.

**Architecture:** A RemoteServer-owned actor aggregates normalized request outcomes and atomically snapshots them at most once per minute. The existing authenticated archive transport reads a bounded `/v2/archive/status` response; the service fetches both replicas concurrently only on status refresh and passes optional validated DTOs to the settings page.

**Tech Stack:** Swift 5.9, Foundation, Hummingbird 2, XCTest, SwiftUI, XcodeGen, Bash/Vitest packaging tests.

## Global Constraints

- Do not add SQLite, GRDB, a metrics service, background polling, charts, or unbounded logs.
- The persisted snapshot is one bounded atomic JSON file with at most 100 sanitized errors.
- Never persist or return tokens, keys, URL hosts, paths, query strings, digests, machine/session IDs, bodies, or raw error descriptions.
- Telemetry failure must never change archive object, manifest, receipt, or list-route behavior.
- `GET /v2/archive/status` requires the archive-v2 bearer token and has a strict response-size cap.
- Existing clients and servers remain compatible through optional local-service fields and a default unsupported backend implementation.
- Remote status reads are concurrent, capped at three seconds per replica, and occur only on initial settings load or manual refresh.
- No source, local CAS, remote archive data, receipt, or rollback snapshot may be deleted.
- Deploy one reviewed arm64 package serially to HQ then M1, preserving and testing per-host rollback.

---

### Task 1: Shared remote telemetry contract and bounded HTTP client

**Files:**

- Create: `macos/Shared/EngramCore/ArchiveV2/ArchiveRemoteTelemetry.swift`
- Modify: `macos/project.yml`
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveReplicaBackend.swift`
- Modify: `macos/EngramCoreWrite/ArchiveV2/HTTPArchiveReplicaBackend.swift`
- Test: `macos/EngramCoreTests/ArchiveV2/HTTPArchiveReplicaBackendTests.swift`

**Interfaces:**

- Produces: `ArchiveRemoteTelemetrySnapshot`, `ArchiveRemoteTelemetryEndpoint`, `ArchiveRemoteTelemetryError`, and `ArchiveReplicaBackend.remoteTelemetryStatus()`.
- Consumers: RemoteServer telemetry store/routes in Task 2 and service DTO conversion in Task 4.

- [ ] **Step 1: Write failing DTO and HTTP tests**

Add tests that decode a valid bounded response, reject more than 100 errors,
reject duplicate endpoint names, reject negative/overflowing values, require the
canonical server ID, and prove the backend sends an authenticated GET to
`/v2/archive/status` with a three-second request timeout and rejects oversized,
redirected, malformed, and non-200 responses.

```swift
func testRemoteTelemetryStatusUsesAuthenticatedBoundedRequest() async throws {
    let backend = try makeBackend()
    StubURLProtocol.handler = { request in
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v2/archive/status")
        XCTAssertEqual(request.timeoutInterval, 3, accuracy: 0.01)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hq-token")
        return (.init(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, validTelemetryBytes)
    }

    let status = try await backend.remoteTelemetryStatus()
    XCTAssertEqual(status.serverID, "hq")
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests \
  -destination 'platform=macOS' \
  -only-testing:EngramCoreTests/HTTPArchiveReplicaBackendTests
```

Expected: compilation fails because the telemetry types and backend method do
not exist.

- [ ] **Step 3: Add the shared validated wire types**

Implement public Codable/Equatable/Sendable structs with throwing decoders.
Keep arrays bounded and reject unknown server IDs, invalid timestamps,
duplicate endpoints, invalid methods/categories, negative counts, and non-finite
durations.

```swift
public struct ArchiveRemoteTelemetrySnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumErrors = 100
    public static let maximumEndpoints = 7
    public static let maximumEncodedBytes = 64 * 1_024

    public let schema: Int
    public let serverID: String
    public let sourceRevision: String
    public let processStartedAt: String
    public let snapshotAt: String
    public let uptimeSeconds: Double
    public let diskAvailableBytes: Int64?
    public let diskTotalBytes: Int64?
    public let requestCount: Int64
    public let successCount: Int64
    public let clientErrorCount: Int64
    public let serverErrorCount: Int64
    public let requestBytes: Int64
    public let responseBytes: Int64
    public let lastArchiveMutationAt: String?
    public let persistenceError: String?
    public let endpoints: [ArchiveRemoteTelemetryEndpoint]
    public let recentErrors: [ArchiveRemoteTelemetryError]
}
```

- [ ] **Step 4: Add the optional backend operation and bounded HTTP implementation**

Declare the protocol requirement with a default unsupported implementation so
existing fakes continue to compile.

```swift
public protocol ArchiveReplicaBackend: Sendable {
    // existing methods
    func remoteTelemetryStatus() async throws -> ArchiveRemoteTelemetrySnapshot
}

public extension ArchiveReplicaBackend {
    func remoteTelemetryStatus() async throws -> ArchiveRemoteTelemetrySnapshot {
        throw ArchiveReplicaBackendError.telemetryUnsupported
    }
}
```

Implement HTTP GET using the existing ephemeral session, redirect/final-URL
checks, canonical decoder, and a new `.telemetry` response limit of 64 KiB.

- [ ] **Step 5: Run focused and core tests and verify GREEN**

Run the focused command from Step 2, then:

```bash
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests \
  -destination 'platform=macOS'
```

Expected: all tests pass with zero failures.

- [ ] **Step 6: Commit Task 1**

```bash
git add macos/project.yml \
  macos/Shared/EngramCore/ArchiveV2/ArchiveRemoteTelemetry.swift \
  macos/EngramCoreWrite/ArchiveV2/ArchiveReplicaBackend.swift \
  macos/EngramCoreWrite/ArchiveV2/HTTPArchiveReplicaBackend.swift \
  macos/EngramCoreTests/ArchiveV2/HTTPArchiveReplicaBackendTests.swift \
  macos/Engram.xcodeproj/project.pbxproj
git commit -m "feat(archive): add remote telemetry contract"
```

---

### Task 2: Bounded persistent telemetry store

**Files:**

- Create: `macos/EngramRemoteServer/Core/ArchiveRemoteTelemetryStore.swift`
- Create: `macos/EngramRemoteServerCoreTests/ArchiveRemoteTelemetryStoreTests.swift`

**Interfaces:**

- Consumes: shared telemetry structs from Task 1.
- Produces: `ArchiveRemoteTelemetryStore.record(_:)` and
  `ArchiveRemoteTelemetryStore.status(forcePersist:)`.

- [ ] **Step 1: Write failing store tests**

Cover accumulation, saturating arithmetic, endpoint sorting, error-category
mapping, 100-entry truncation, 60-second throttling, forced flush, mode
0700/0600 creation, snapshot reload, corrupt/oversized/schema-mismatch/symlink
rejection, disk fields, and injected persistence failure.

```swift
func testStatusForcePersistsAndReloadsBoundedState() async throws {
    let root = temporaryDirectory()
    let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
    let store = try ArchiveRemoteTelemetryStore(
        archiveRoot: root,
        serverID: "hq",
        sourceRevision: revision,
        now: clock.now
    )
    await store.record(.init(endpoint: "object", method: "PUT", statusCode: 201,
                             durationMs: 4, requestBytes: 12, responseBytes: 0,
                             archiveMutation: true))
    _ = await store.status(forcePersist: true)

    let reloaded = try ArchiveRemoteTelemetryStore(
        archiveRoot: root,
        serverID: "hq",
        sourceRevision: revision,
        now: clock.now
    )
    let snapshot = await reloaded.status(forcePersist: false)
    XCTAssertEqual(snapshot.requestCount, 1)
    XCTAssertEqual(snapshot.lastArchiveMutationAt, "2026-07-12T10:00:00.000Z")
}
```

- [ ] **Step 2: Run store tests and verify RED**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramRemoteServerCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramRemoteServerCoreTests/ArchiveRemoteTelemetryStoreTests
```

Expected: compilation fails because the store does not exist.

- [ ] **Step 3: Implement the actor and secure snapshot writer**

Use one actor state, saturating helpers, canonical encoder, `lstat`-based
symlink rejection, `Data.write(options: .atomic)`, and chmod after each replace.
The injected writer is used only by tests.

```swift
actor ArchiveRemoteTelemetryStore {
    static let flushInterval: TimeInterval = 60
    static let telemetryDirectoryName = ".telemetry"
    static let snapshotFileName = "status-v1.json"

    func record(_ observation: ArchiveRemoteTelemetryObservation) async {
        state.apply(observation, at: now())
        dirty = true
        if now().timeIntervalSince(lastPersistedAt) >= Self.flushInterval {
            persistBestEffort()
        }
    }

    func status(forcePersist: Bool) -> ArchiveRemoteTelemetrySnapshot {
        if forcePersist && dirty { persistBestEffort() }
        return makeSnapshot(at: now())
    }
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: all store tests pass.

- [ ] **Step 5: Run the full RemoteServerCore suite**

```bash
xcodebuild test -project Engram.xcodeproj -scheme EngramRemoteServerCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass with zero failures.

- [ ] **Step 6: Commit Task 2**

```bash
git add macos/EngramRemoteServer/Core/ArchiveRemoteTelemetryStore.swift \
  macos/EngramRemoteServerCoreTests/ArchiveRemoteTelemetryStoreTests.swift
git commit -m "feat(archive): persist bounded remote telemetry"
```

---

### Task 3: Observe archive routes, expose authenticated status, and package build identity

**Files:**

- Modify: `macos/EngramRemoteServer/Core/ArchiveRoutes.swift`
- Modify: `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift`
- Modify: `macos/EngramRemoteServer/Core/EngramRemoteServerConfig.swift`
- Modify: `macos/EngramRemoteServer/Packaging/run-engram-remote.zsh.template`
- Modify: `macos/scripts/package-remote-server.sh`
- Modify: `macos/EngramRemoteServerCoreTests/ArchiveRouteTests.swift`
- Modify: `macos/EngramRemoteServerCoreTests/ArchiveConfigTests.swift`
- Modify: `tests/scripts/remote-server-package.test.ts`

**Interfaces:**

- Consumes: telemetry store from Task 2.
- Produces: authenticated `GET /v2/archive/status` and package-provided source revision.

- [ ] **Step 1: Write failing route, config, and packaging tests**

Add tests proving unauthorized status is 401, authorized status is canonical and
bounded, status observes prior requests, PUT 201 updates last mutation, 4xx/5xx
map to sanitized categories, persistence failure leaves archive PUT successful,
and build revision accepts exactly 40 lowercase hex characters or reports
`unknown`. Add Vitest assertions that package substitution exports only the
validated revision and contains no secret material.

```swift
func testStatusRequiresArchiveTokenAndContainsPriorRequestTelemetry() async throws {
    let app = try makeApp()
    _ = try await execute(app, method: .put, path: objectPath, token: archiveToken,
                          body: objectBytes, contentType: "application/octet-stream")
    let unauthorized = try await execute(app, method: .get, path: "/v2/archive/status")
    XCTAssertEqual(unauthorized.status, .unauthorized)
    let authorized = try await execute(app, method: .get, path: "/v2/archive/status",
                                       token: archiveToken)
    let snapshot = try ArchiveCanonicalJSON.decode(
        ArchiveRemoteTelemetrySnapshot.self,
        from: try await authorized.body.collect(upTo: 64 * 1_024)
    )
    XCTAssertEqual(snapshot.requestCount, 2)
    XCTAssertEqual(snapshot.lastArchiveMutationAt, now)
}
```

- [ ] **Step 2: Run focused Swift and Vitest commands and verify RED**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramRemoteServerCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramRemoteServerCoreTests/ArchiveRouteTests \
  -only-testing:EngramRemoteServerCoreTests/ArchiveConfigTests
cd ..
npm test -- tests/scripts/remote-server-package.test.ts
```

Expected: route/config/package contract tests fail for missing behavior.

- [ ] **Step 3: Mount one observation wrapper and status route**

Create one helper that measures monotonic duration, reads only numeric content
lengths, records after response construction, and normalizes identifiers out of
the endpoint name.

```swift
private static func observed(
    _ request: Request,
    endpoint: String,
    telemetry: ArchiveRemoteTelemetryStore,
    archiveMutation: Bool = false,
    operation: () async -> Response
) async -> Response {
    let started = DispatchTime.now().uptimeNanoseconds
    let response = await operation()
    await telemetry.record(.init(
        endpoint: endpoint,
        method: request.method.rawValue,
        statusCode: response.status.code,
        durationMs: elapsedMilliseconds(since: started),
        requestBytes: boundedContentLength(request.headers),
        responseBytes: boundedContentLength(response.headers),
        archiveMutation: archiveMutation && response.status.code < 300
    ))
    return response
}
```

Mount `GET /v2/archive/status` before the DELETE deny-list and include `status`
in the explicit DELETE 405 list.

- [ ] **Step 4: Thread telemetry and source revision through config/app**

Derive the snapshot location from the archive root. Construct the telemetry
actor only when archive v2 is enabled. Validate the optional source revision
without making startup depend on it.

```swift
let sourceRevision = environment["ENGRAM_REMOTE_SOURCE_REVISION"].flatMap {
    $0.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil ? $0 : nil
} ?? "unknown"
```

- [ ] **Step 5: Substitute and verify the package revision**

Change the wrapper template to contain
`export ENGRAM_REMOTE_SOURCE_REVISION='__ENGRAM_REMOTE_SOURCE_REVISION__'`.
During packaging, replace the placeholder with the already validated revision;
verification rejects an unresolved placeholder, a mismatched value, or
credential-like template content.

- [ ] **Step 6: Run focused and full verification and verify GREEN**

Run Step 2, then:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramRemoteServerCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
cd ..
bash scripts/check-archive-v2-safety.sh
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 7: Commit Task 3**

```bash
git add macos/EngramRemoteServer macos/scripts/package-remote-server.sh \
  macos/EngramRemoteServerCoreTests tests/scripts/remote-server-package.test.ts
git commit -m "feat(archive): expose remote telemetry status"
```

---

### Task 4: Collect HQ/M1 telemetry in the local service wire

**Files:**

- Modify: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/MockEngramServiceClient.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2ServiceWireTests.swift`

**Interfaces:**

- Consumes: `ArchiveReplicaBackend.remoteTelemetryStatus()`.
- Produces: optional per-replica `remoteTelemetry` and
  `remoteTelemetryError` in `EngramServiceArchiveV2ReplicaStatus`.

- [ ] **Step 1: Write failing concurrent/partial-success/wire tests**

Prove both replica calls begin before either finishes, one failure does not
discard the other result, errors map only to fixed symbols, old JSON without
new fields decodes, and malformed remote telemetry is rejected.

```swift
func testStatusCollectsReplicaTelemetryConcurrentlyAndKeepsPartialSuccess() async throws {
    let probe = ConcurrentTelemetryProbe()
    let coordinator = makeCoordinator(remoteTelemetry: {
        await probe.collect(hq: .success(hqSnapshot), m1: .failure(.transport(.network)))
    })
    let status = await coordinator.status()
    XCTAssertEqual(status.replicas[0].remoteTelemetry?.serverID, "hq")
    XCTAssertEqual(status.replicas[1].remoteTelemetryError, "transport_network")
    XCTAssertTrue(await probe.overlapped)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests \
  -only-testing:EngramServiceCoreTests/ArchiveV2ServiceWireTests
```

Expected: compilation fails for missing DTO fields and collection closure.

- [ ] **Step 3: Add optional validated wire fields**

Define an app-facing remote telemetry DTO rather than exposing CoreWrite types
through the app module. Cap endpoint/error arrays again at the IPC boundary.

```swift
struct EngramServiceArchiveV2RemoteTelemetry: Codable, Equatable, Sendable {
    let serverID: String
    let sourceRevision: String
    let snapshotAt: String
    let uptimeSeconds: Double
    let diskAvailableBytes: Int64?
    let diskTotalBytes: Int64?
    let requestCount: Int64
    let clientErrorCount: Int64
    let serverErrorCount: Int64
    let lastArchiveMutationAt: String?
    let persistenceError: String?
    let recentErrors: [EngramServiceArchiveV2RemoteError]
}
```

- [ ] **Step 4: Fetch both remotes concurrently and map fixed errors**

Add a default-empty `remoteTelemetry` operation to
`ArchiveV2ServiceCoordinatorOperations`. Production uses a task group over the
two backend values. Never write the result into the archive catalog or retry
ledger.

- [ ] **Step 5: Run focused and full Service tests and verify GREEN**

Run Step 2, then:

```bash
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass with zero failures.

- [ ] **Step 6: Commit Task 4**

```bash
git add macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift \
  macos/Shared/Service/EngramServiceModels.swift \
  macos/Shared/Service/MockEngramServiceClient.swift \
  macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift \
  macos/EngramServiceCoreTests/ArchiveV2ServiceWireTests.swift
git commit -m "feat(archive): collect remote telemetry in status"
```

---

### Task 5: Show lightweight HQ/M1 runtime telemetry in settings

**Files:**

- Modify: `macos/Engram/Views/Settings/ArchiveSettingsSection.swift`
- Modify: `macos/Engram/Resources/Localizable.xcstrings`
- Modify: `macos/EngramTests/ArchiveSettingsSectionTests.swift`

**Interfaces:**

- Consumes: optional per-replica remote telemetry from Task 4.
- Produces: localized settings rows without polling.

- [ ] **Step 1: Write failing presentation and source tests**

Test online/offline summaries, short revision rendering, uptime/disk formatting,
last mutation, request/error counts, latest sanitized error, and the absence of
Timer/refresh loops.

```swift
func testRemoteSummaryShowsIndependentServerState() throws {
    let summary = ArchiveRemoteTelemetryPresentation.summary(
        replicaID: "hq",
        telemetry: telemetry,
        error: nil
    )
    XCTAssertTrue(summary.contains("HQ"))
    XCTAssertTrue(summary.contains(String(revision.prefix(8))))
    XCTAssertTrue(summary.contains("17:28"))
}
```

- [ ] **Step 2: Run App tests and verify RED**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramTests/ArchiveSettingsSectionTests
```

Expected: compilation fails because the presentation helper does not exist.

- [ ] **Step 3: Implement compact localized presentation**

Add one caption below each replica's local retry diagnostics. Show
`Remote status unavailable` with the fixed error category when absent; otherwise
show build, uptime, last write, requests/errors, disk free, and latest error.
Keep current `.task { await refresh() }` and manual button unchanged.

- [ ] **Step 4: Add complete English and Chinese localizations**

Add every new literal to `Localizable.xcstrings`; do not leave English-only
status labels or raw symbols in the UI.

- [ ] **Step 5: Run focused and full App tests and verify GREEN**

Run Step 2, then:

```bash
xcodebuild test -project Engram.xcodeproj -scheme EngramTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass with zero failures.

- [ ] **Step 6: Commit Task 5**

```bash
git add macos/Engram/Views/Settings/ArchiveSettingsSection.swift \
  macos/Engram/Resources/Localizable.xcstrings \
  macos/EngramTests/ArchiveSettingsSectionTests.swift
git commit -m "feat(archive): show remote telemetry in settings"
```

---

### Task 6: Full review, package, serial deployment, and production verification

**Files:**

- Modify if required by implementation truth: `docs/remote-archive-v2.md`
- Produce locally: `macos/build/remote-telemetry-package/`
- Produce locally: `/tmp/engram-remote-telemetry-deploy/`
- Deploy: `~/.engram-remote/releases/<reviewed-sha>/` on HQ and M1

**Interfaces:**

- Consumes: reviewed commits from Tasks 1-5.
- Produces: identical running packages on HQ/M1 and a matching locally installed Engram app.

- [ ] **Step 1: Run the complete local verification matrix**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramRemoteServerCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
cd ..
npm test -- tests/scripts/remote-server-package.test.ts
bash scripts/check-archive-v2-safety.sh
git diff --check
```

Expected: all test schemes and static gates exit zero.

- [ ] **Step 2: Commit any runbook correction and obtain code review**

Use `superpowers:requesting-code-review` with the design, this plan, base SHA
`36c7a323`, and implementation HEAD. Fix every Critical and Important finding,
add a failing regression test before each fix, re-run affected tests, and repeat
review until Ready to merge is Yes.

- [ ] **Step 3: Build and verify one arm64 RemoteServer package**

```bash
cd macos
xcodebuild -project Engram.xcodeproj -scheme EngramRemoteServer \
  -configuration Release -derivedDataPath build/RemoteTelemetryDerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
rm -rf build/remote-telemetry-package
./scripts/package-remote-server.sh \
  --derived-data "$PWD/build/RemoteTelemetryDerivedData" \
  --configuration Release --arch arm64 \
  --source-revision "$(git rev-parse HEAD)" \
  --output "$PWD/build/remote-telemetry-package"
./scripts/package-remote-server.sh --verify-only "$PWD/build/remote-telemetry-package"
```

Record `SHA256SUMS`, package directory hash, source revision, and executable hash.

- [ ] **Step 4: Capture bounded rollback evidence from both hosts**

For HQ and M1 record current symlink target, metadata, binary hash, PID,
listener, health, current status/telemetry file metadata, and LaunchAgent state
under `/tmp/engram-remote-telemetry-deploy/<host>-before.txt`. Do not copy or
scan archive payload contents.

- [ ] **Step 5: Deploy and verify HQ**

Copy the verified package to a new owner-only release directory, verify its
manifest on-host, render the wrapper with existing secret env paths, atomically
switch `current`, restart only `com.engram.remote-server`, and verify:

- process and Tailscale-only listener;
- `/v1/health` returns `ok`;
- unauthenticated `/v2/archive/status` returns 401;
- authenticated status has the reviewed revision and `serverID=hq`;
- one immutable object/manifest/receipt smoke succeeds without DELETE;
- snapshot exists mode 0600 and contains no forbidden fields;
- controlled restart reloads counters and leaves archive reads intact.

On failure, restore the recorded previous symlink target and restart/verify HQ.

- [ ] **Step 6: Deploy and verify M1**

Repeat Step 5 with `serverID=m1` only after HQ passes. Require the same package
and executable hashes. On failure, roll back M1 without changing HQ.

- [ ] **Step 7: Build, install, and verify the matching local Engram app**

Use `build-release.sh`, `release-verify.sh`, a timestamped `/tmp` rollback copy,
and `deploy-local.sh`. Verify installed/exported build and binary hashes, App and
Service PIDs, socket, `archive status --json`, and that both replica entries
contain independent remote telemetry with the reviewed source revision.

- [ ] **Step 8: Verify the settings UI and final live sync**

Open Archive & Storage, refresh once, and inspect accessibility text or a
screenshot. Confirm Chinese labels, both online states, independent counters,
last writes, build revisions, and no timer-driven requests. Trigger or wait for
one bounded archive cycle and prove both server snapshots advance.

- [ ] **Step 9: Capture durable closeout evidence**

Record final branch/commits, tests, package hashes, remote release targets,
rollback handles, health/status outputs, installed build, skipped checks, and
residual risk in the final response. Do not create memory/changelog files unless
the user separately requests them.
