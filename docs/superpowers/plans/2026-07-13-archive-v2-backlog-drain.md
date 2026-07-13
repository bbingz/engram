# Archive V2 Backlog Drain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Archive V2's index-schedule-bound shared batch with a resource-bounded, event-driven backlog drainer that advances capture, binding, policy, HQ, and M1 continuously while work is runnable.

**Architecture:** Keep the existing synchronous recent-source capture barrier around indexing, but add an `ArchiveV2BacklogDrainer` actor that repeatedly asks `ArchiveV2ServiceCoordinator` for one bounded historical drain pass. Cache the full locator snapshot only for the lifetime of an active sweep, split catalog claims by replica and pending/retry class, and run at most one HQ plus one M1 worker concurrently. Expose bounded worker state through the existing Archive V2 IPC status and settings card.

**Tech Stack:** Swift 5.9, Swift concurrency actors/tasks, Foundation `ProcessInfo` notifications, GRDB/SQLite, XCTest, SwiftUI, XcodeGen/Xcode.

## Global Constraints

- Preserve capture-before-parse for supported Claude Code and Codex sources.
- Preserve immutable CAS, generation validation, dual receipts, retry jitter, claim generation, stale recovery, recovery drills, reclamation, and deletion gates.
- Do not add dependencies, a persistent locator inventory, FSEvents, an event database, a high-frequency idle poll, or user-facing tuning controls.
- Use internal defaults: capture 32 files or 128 MiB, bind 100 rows, policy 100 rows, HQ 16 rows, M1 16 rows, approximately 10 seconds active time, and 2 seconds cool-down.
- Pause new work in Low Power Mode and serious/critical thermal pressure; resume from `ProcessInfo` notifications.
- Remote concurrency is at most two globally and one per replica.
- Keep settings and CLI decoding backward compatible.
- Do not modify `macos/Engram.xcodeproj` directly; run XcodeGen only if project structure requires it.

---

### Task 1: Reusable Full-Sweep Capture Budgets

**Files:**
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCaptureCoordinator.swift`
- Modify: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Test: `macos/EngramCoreTests/ArchiveV2/ArchiveCaptureCoordinatorTests.swift`
- Test: `macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift`

**Interfaces:**
- Produces: `ArchiveCaptureBudget(locatorLimit:sourceByteLimit:)`.
- Produces: `ArchiveCaptureCycleResult.capturedSourceBytes`.
- Extends: `ArchiveCaptureCoordinator.capture(adapters:budget:cursorScope:refreshLocatorSnapshot:)`.
- Preserves: the current `capture(adapters:locatorBudget:cursorScope:)` overload for existing callers.

- [ ] **Step 1: Write failing capture-budget and snapshot-reuse tests**

Add tests that use a counting exact adapter and source files with known byte sizes:

```swift
let budget = ArchiveCaptureBudget(locatorLimit: 32, sourceByteLimit: 5)
let first = try await coordinator.capture(
    adapters: [adapter],
    budget: budget,
    cursorScope: .full,
    refreshLocatorSnapshot: false
)
let second = try await coordinator.capture(
    adapters: [adapter],
    budget: budget,
    cursorScope: .full,
    refreshLocatorSnapshot: false
)
XCTAssertGreaterThanOrEqual(first.capturedSourceBytes, 5)
XCTAssertEqual(await adapter.listCount(), 1)
XCTAssertTrue(first.hasMore)
XCTAssertFalse(second.items.isEmpty)
```

Also prove `.recent` with `refreshLocatorSnapshot: true` re-enumerates and that an exhausted full sweep discards its cache.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/ArchiveCaptureCoordinatorTests
```

Expected: compile/test failure because `ArchiveCaptureBudget`, `capturedSourceBytes`, and the new overload do not exist.

- [ ] **Step 3: Implement the capture budget and process-local sweep cache**

Add the concrete types and overload:

```swift
public struct ArchiveCaptureBudget: Equatable, Sendable {
    public let locatorLimit: Int
    public let sourceByteLimit: Int64
}

public struct ArchiveCaptureCycleResult: Equatable, Sendable {
    // existing fields
    public let capturedSourceBytes: Int64
}
```

Keep a cache per `ArchiveCaptureCursorScope` containing the exact adapter references and stable sorted locator snapshots. Build it when absent or explicitly refreshed, reuse it while the persisted sweep reports `hasMore`, and clear it when the sweep exhausts or enumeration fails. Stop before starting another locator after either count or byte limit is reached; a single completed file may cross the byte boundary. Sum bytes from `ArchiveCaptureResult.manifest.rawByteCount` with overflow-safe arithmetic.

Extend `ArchiveV2ServiceCaptureSummary` with `processed` and `capturedSourceBytes`, and add a production operation dedicated to backlog capture using the new budget and cached full snapshot.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Task 1 focused Core and Service tests. Expected: all selected tests pass and existing cursor/fairness tests remain green.

- [ ] **Step 5: Commit Task 1**

```bash
git add macos/EngramCoreWrite/ArchiveV2/ArchiveCaptureCoordinator.swift \
  macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift \
  macos/EngramCoreTests/ArchiveV2/ArchiveCaptureCoordinatorTests.swift \
  macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift
git commit -m "feat(archive): bound reusable capture sweeps"
```

---

### Task 2: Independent Fair Replica Workers

**Files:**
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift`
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveReplicationCoordinator.swift`
- Test: `macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift`
- Test: `macos/EngramCoreTests/ArchiveV2/ArchiveReplicationCoordinatorTests.swift`

**Interfaces:**
- Produces: `ArchiveCatalog.claimReplicaWork(replicaID:limit:retryQuota:now:)`.
- Produces: `ArchiveReplicationCoordinator.runBacklogPass(perReplicaLimit:)`.
- Extends: `ArchiveReplicationCycleResult.pausedReplicaIDs` with deterministic HQ/M1 ordering.
- Preserves: `claimReplicaWork(limit:now:)` and `runOnce(limit:)` for compatibility tests and non-drainer callers.

- [ ] **Step 1: Write failing catalog fairness tests**

Create mixed pending and due-retry rows for each replica, then assert:

```swift
let hq = try catalog.claimReplicaWork(
    replicaID: "hq",
    limit: 16,
    retryQuota: 8,
    now: now
)
XCTAssertEqual(Set(hq.map(\.replicaID)), ["hq"])
XCTAssertEqual(hq.count, 16)
XCTAssertEqual(hq.filter { $0.attempts > 0 }.count, 8)
```

Add borrowing cases where one class has fewer than eight rows, invalid replica/limit rejection, and deterministic oldest-first ordering inside each class.

- [ ] **Step 2: Write failing replica concurrency and short-circuit tests**

Use blocking fake backends to prove HQ and M1 overlap while each backend's maximum concurrent call count remains one. Add two manifests per replica, fail HQ's first request with `.transport(.network)`, and assert HQ receives no request for its second manifest while M1 verifies both. Add a 401 case that returns `pausedReplicaIDs == ["hq"]` without touching later HQ rows.

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' \
  -only-testing:EngramCoreTests/ArchiveCatalogTests \
  -only-testing:EngramCoreTests/ArchiveReplicationCoordinatorTests
```

Expected: failures because per-replica fair claiming and concurrent backlog replication do not exist.

- [ ] **Step 4: Implement per-replica fair claim in one transaction**

Validate `replicaID` against `ArchiveCatalog.currentReplicaIDs`. In one GRDB write transaction, select up to `retryQuota` due retry keys and `limit - retryQuota` pending keys, borrow unused capacity from the remaining eligible candidates, update only those keys to `uploadingObjects`, and return their claims. Keep state/generation compare-and-set semantics and deterministic ordering.

- [ ] **Step 5: Implement concurrent replica processing with failure short-circuit**

Add `runBacklogPass(perReplicaLimit:)` that performs stale recovery and row reconciliation once, claims HQ and M1 independently, and processes them with `async let`. Move per-claim execution into a sendable replica-batch helper. Stop only the affected replica after these symbols:

```swift
let transientInfrastructure = [
    "transport_timeout", "transport_network",
    "remote_rate_limited", "remote_server_unavailable",
]
let attentionInfrastructure = [
    "remote_auth_rejected", "replica_configuration_failure",
]
```

The current failed row still performs its existing retry/quarantine transition. Merge both batch accumulators deterministically and retain all current receipt verification logic.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Task 2 command. Expected: all selected tests pass, including existing dual-receipt, retry, cancellation, stale-claim, and source-scan tests.

- [ ] **Step 7: Commit Task 2**

```bash
git add macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift \
  macos/EngramCoreWrite/ArchiveV2/ArchiveReplicationCoordinator.swift \
  macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift \
  macos/EngramCoreTests/ArchiveV2/ArchiveReplicationCoordinatorTests.swift
git commit -m "feat(archive): drain replicas independently"
```

---

### Task 3: Event-Driven Backlog Drainer and Runner Integration

**Files:**
- Create: `macos/EngramService/Core/ArchiveV2BacklogDrainer.swift`
- Modify: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift`
- Create: `macos/EngramServiceCoreTests/ArchiveV2BacklogDrainerTests.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2RunnerIntegrationTests.swift`

**Interfaces:**
- Produces: `ArchiveV2DrainState`, `ArchiveV2DrainStage`, `ArchiveV2DrainPassSummary`, and `ArchiveV2DrainSnapshot`.
- Produces: `ArchiveV2BacklogDrainer.start()`, `signal()`, `snapshot()`, and `stop()`.
- Produces: `ArchiveV2ServiceCoordinator.runBacklogPass(adapters:)` and `attachDrainer(_:)`.
- Consumes: Task 1 backlog capture operation and Task 2 `runBacklogPass(perReplicaLimit:)`.

- [ ] **Step 1: Write failing pure worker lifecycle tests**

Use injected conditions, clock, sleeper, and pass closure to prove:

```swift
await drainer.start()
await drainer.signal()
await recorder.waitForPassCount(2)
XCTAssertEqual(await recorder.passCount(), 2)
XCTAssertEqual(await recorder.maximumConcurrency(), 1)
```

Also prove signal coalescing, no sleeper call after an idle/no-retry outcome, exact retry-deadline sleep, two-second productive cool-down, Low Power and thermal pause, notification-triggered resume, cancellation, and clean `stop()`.

- [ ] **Step 2: Run drainer tests and verify RED**

Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramServiceCoreTests/ArchiveV2BacklogDrainerTests
```

Expected: compile failure because the drainer types do not exist.

- [ ] **Step 3: Implement bounded coordinator drain passes**

Extract post-index binding/policy work from `executeCycle` into a reusable helper with independent `bindingLimit: 100` and `policyLimit: 100`. Implement one pass in this order:

```swift
capture full sweep: 32 files / 128 MiB
binding: 100 rows
policy: 100 rows
replication: HQ 16 and M1 16 concurrently
status aggregation: runnable backlog, earliest retry, attention state
```

Do not run remote replication inside the periodic indexing cycle after the drainer is attached. The periodic path retains recent capture, indexing, and immediate binding/policy reconciliation, then signals the drainer. Coordinate `runCycle` and `runBacklogPass` so they never mutate archive pipeline state concurrently; the short drain pass yields to a waiting index cycle before another pass begins.

- [ ] **Step 4: Implement `ArchiveV2BacklogDrainer`**

Use one utility-priority task, a checked-continuation work signal, and one optional deadline sleeper. A productive outcome schedules a two-second cool-down and another pass. A retry-only outcome sleeps until the earliest retry. An idle outcome waits indefinitely. Subscribe to `ProcessInfo.thermalStateDidChangeNotification` and `Notification.Name.NSProcessInfoPowerStateDidChange`; notification handlers only signal the actor.

The approximately ten-second slice is cooperative: check the deadline before starting each stage or new unit, never cancel a source publication or remote request merely because the deadline elapsed, and yield before claiming more work.

- [ ] **Step 5: Wire startup, periodic signals, retry, and shutdown**

Create the drainer beside the coordinator in `EngramServiceRunner.run`. Start and signal it only after `initialScanTask` finishes. Ensure manual `archiveV2Retry` signals it. On service shutdown, cancel and await the drainer before tearing down `ServiceWriterGate`. Keep Archive V2 default-off free of worker tasks and archive filesystem effects.

- [ ] **Step 6: Run focused integration tests and verify GREEN**

Run the drainer, coordinator, runner integration, initial scan, and indexing schedule tests. Expected: all pass and the existing 15/30/60 indexing policy remains unchanged.

- [ ] **Step 7: Commit Task 3**

```bash
git add macos/EngramService/Core/ArchiveV2BacklogDrainer.swift \
  macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift \
  macos/EngramService/Core/EngramServiceRunner.swift \
  macos/EngramServiceCoreTests/ArchiveV2BacklogDrainerTests.swift \
  macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift \
  macos/EngramServiceCoreTests/ArchiveV2RunnerIntegrationTests.swift
git commit -m "feat(archive): add backlog-driven drain worker"
```

---

### Task 4: IPC, CLI, Settings Status, and Localization

**Files:**
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Modify: `macos/Shared/Service/MockEngramServiceClient.swift`
- Modify: `macos/Engram/Views/Settings/ArchiveSettingsSection.swift`
- Modify: `macos/Engram/Resources/Localizable.xcstrings`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2ServiceWireTests.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift`
- Modify: `macos/EngramTests/ArchiveSettingsSectionTests.swift`

**Interfaces:**
- Produces: `EngramServiceArchiveV2DrainPassSummary`.
- Extends: `EngramServiceArchiveV2StatusResponse` with `drainState`, `activeStages`, `lastDrainPass`, and `nextWakeAt`.
- Consumes: Task 3 `ArchiveV2DrainSnapshot`.

- [ ] **Step 1: Write failing wire-validation and compatibility tests**

Prove valid symbols and deterministic stage arrays decode, negative counts/bytes and invalid timestamps fail, more than two active stages fail, only `["hq", "m1"]` may contain two stages, and older JSON with none of the new keys decodes as idle/default values.

- [ ] **Step 2: Write failing settings/localization tests**

Require stable identifiers `archiveSync_drainState`, `archiveSync_activeStages`, `archiveSync_lastDrainPass`, and `archiveSync_nextWake`. Require English and Simplified Chinese translations for idle, draining, waiting retry, Low Power pause, thermal pause, needs attention, all five stages, last-pass format, and next-wake format. Preserve the source-level no-automatic-polling assertion.

- [ ] **Step 3: Run focused model and UI tests and verify RED**

Run the selected `EngramServiceCoreTests` and `EngramTests` cases. Expected: failures for missing DTO fields, presentation helpers, identifiers, and translations.

- [ ] **Step 4: Implement bounded DTOs and coordinator mapping**

Use optional/default decoding so an app can read an older service. Validate symbols with the existing wire validator, cap active stages to two, validate non-negative stage counts and captured bytes, and include the drainer snapshot in `ArchiveV2ServiceCoordinator.status()` without adding network calls.

- [ ] **Step 5: Implement compact settings presentation and Chinese strings**

Place drain state immediately below the existing top status row. Show active stages only while draining, last pass when present, and next wake only while waiting retry. Keep the existing manual Refresh Status button and do not add `.onReceive`, a timer, or a polling task.

- [ ] **Step 6: Run focused tests and verify GREEN**

Expected: model, coordinator, source contract, and localization coverage tests pass.

- [ ] **Step 7: Commit Task 4**

```bash
git add macos/Shared/Service/EngramServiceModels.swift \
  macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift \
  macos/Shared/Service/MockEngramServiceClient.swift \
  macos/Engram/Views/Settings/ArchiveSettingsSection.swift \
  macos/Engram/Resources/Localizable.xcstrings \
  macos/EngramServiceCoreTests/ArchiveV2ServiceWireTests.swift \
  macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift \
  macos/EngramTests/ArchiveSettingsSectionTests.swift
git commit -m "feat(archive): expose backlog drain status"
```

---

### Task 5: Review, Build, Deploy, and Installed-Runtime Verification

**Files:**
- Review: every file changed by Tasks 1-4
- Generate only if required by new source discovery: `macos/Engram.xcodeproj`
- Evidence: the directory printed by
  `EVIDENCE_DIR="/tmp/engram-archive-drain-$(date -u +%Y%m%dT%H%M%SZ)"`.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: installed Engram app/service with verified backlog drain behavior and an evidence bundle outside the repo.

- [ ] **Step 1: Perform a requirement-by-requirement self review**

Compare the diff with every design section and record a temporary checklist covering capture-before-parse, idle no-polling, budgets, fairness, failure isolation, power/thermal pause, status compatibility, localization, security-sensitive logging, rollback compatibility, and all ten acceptance criteria. Inspect changed code directly; do not treat passing tests as sufficient review.

- [ ] **Step 2: Run formatting/static diff checks**

```bash
git diff --check origin/main...HEAD
rg -n 'token|Authorization|locator|sessionID|manifestSHA256' macos/EngramService/Core/ArchiveV2BacklogDrainer.swift macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift
```

Expected: no whitespace errors and no new sensitive-value logging.

- [ ] **Step 3: Run the full relevant Swift test matrix**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skip-testing:EngramUITests
```

Expected: all tests pass.

- [ ] **Step 4: Build and verify the release bundle**

```bash
macos/scripts/build-release.sh --local-only
EXPORT_APP="$PWD/macos/build/EngramExport/Engram.app"
VERIFY_ARGS=()
if [[ ! -d "$EXPORT_APP" ]]; then
  EXPORT_APP="$PWD/macos/build/EngramExport/Engram-local-only.app"
  VERIFY_ARGS=(--adhoc)
fi
macos/scripts/release-verify.sh "$EXPORT_APP" "${VERIFY_ARGS[@]}"
```

Expected: signed app export succeeds and the release verifier reports no forbidden Node runtime artifacts or signature failures.

- [ ] **Step 5: Commit any review fixes, then deploy locally**

Use `apply_patch` for fixes, rerun affected tests, commit the reviewed implementation, then:

```bash
macos/scripts/deploy-local.sh "$EXPORT_APP"
```

Expected: `/Applications/Engram.app` is replaced, Engram and EngramService restart, and the service socket becomes healthy.

- [ ] **Step 6: Verify installed identity and immediate runtime state**

Record in the evidence directory:

- `HEAD` and `origin/main` status;
- installed `CFBundleShortVersionString` and `CFBundleVersion`;
- installed/exported service binary SHA-256 parity;
- `release-verify.sh /Applications/Engram.app` output;
- process IDs, socket permissions, service health, and `archive status --json`.

Expected: installed identity matches the exported build and status reports the new drain fields.

- [ ] **Step 7: Observe the live backlog for at least 30 minutes**

Sample archive status, EngramService CPU/RSS, and bounded service logs at the beginning and at regular intervals. Verify:

- at least two productive drain passes occur without an indexing-scheduler wake;
- captured/bound/verified counts move monotonically except for expected newly admitted work;
- HQ failure/retry does not prevent M1 progress and vice versa;
- no repeated-request storm or sensitive log value appears;
- no sustained high CPU or unbounded RSS growth occurs; and
- idle or retry-wait periods match `drainState` and `nextWakeAt`.

- [ ] **Step 8: Final completion audit**

Map every design acceptance criterion to a test, build output, installed-runtime observation, or explicit remaining limitation. Do not claim completion while any required criterion lacks evidence. Push only if separately authorized; deployment authorization does not imply push.
