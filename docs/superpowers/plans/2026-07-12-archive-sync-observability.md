# Archive Sync Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose lightweight Archive V2 cycle, retry, backlog, and scheduling diagnostics through the existing status command and localized settings card.

**Architecture:** Extend the existing catalog aggregate and shared status DTO instead of creating a second status system. Keep one latest replication summary and one approximate next-cycle timestamp in the service actor, while durable retry/backlog facts continue to come from the archive catalog. Render compact, friendly categories in SwiftUI and retain exact symbols in CLI JSON.

**Tech Stack:** Swift 6, GRDB, Swift concurrency actors, Codable service IPC, SwiftUI, XCTest, String Catalog localization.

## Global Constraints

- Do not add polling, a database migration, a persistent event stream, per-object UI, or an additional network request.
- Do not expose manifest hashes, capture IDs, session IDs, locators, paths, source content, URLs, tokens, or response bodies in the new diagnostics.
- Preserve the current Archive V2 capture, replication, recovery, and reclamation behavior.
- Keep the current strict wire validation and make newly added fields backward-decodable from an older service payload.
- Use Simplified Chinese for every new user-visible settings string.

---

### Task 1: Durable replica backlog aggregates

**Files:**
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift`
- Test: `macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift`

**Interfaces:**
- Produces: `ArchiveRetryReasonCount(symbol:count:)`.
- Produces: `ArchiveReplicaStatusCounts.oldestOutstandingAt`, `.nextRetryAt`, and `.retryReasons`.
- Consumes: existing `archive_replica_receipts.state`, `updated_at`, `next_retry_at`, and `last_error` columns.

- [ ] **Step 1: Write failing catalog aggregation tests**

Create pending, retry-wait, quarantined, and verified receipt rows for both
replicas. Assert that `archiveStatus()` returns the minimum outstanding
`updated_at`, the minimum retry-wait `next_retry_at`, and deterministic
reason/count ordering. Also assert that verified-only replicas return nil dates
and an empty reason list.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/ArchiveCatalogTests
```

Expected: compilation or assertion failure because the aggregate fields do not
exist.

- [ ] **Step 3: Implement the bounded aggregate**

Add the value type:

```swift
public struct ArchiveRetryReasonCount: Equatable, Sendable {
    public let symbol: String
    public let count: Int
}
```

Extend `ArchiveReplicaStatusCounts` with optional timestamps and a bounded,
sorted reason list. In `archiveStatus()`, augment the per-replica grouped query
with conditional `MIN(updated_at)` and `MIN(next_retry_at)`, then run one grouped
reason query for retry-wait and quarantined rows. Sort by count descending and
symbol ascending before constructing the aggregate.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Task 1 command. Expected: `ArchiveCatalogTests` pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift
git commit -m "feat: aggregate archive retry diagnostics"
```

### Task 2: Backward-compatible status wire contract

**Files:**
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/MockEngramServiceClient.swift`
- Modify: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler+ArchiveV2.swift`
- Test: `macos/EngramServiceCoreTests/ArchiveV2ServiceWireTests.swift`

**Interfaces:**
- Produces: `EngramServiceArchiveV2RetryReasonCount`.
- Produces: `EngramServiceArchiveV2ReplicationCycleSummary`.
- Extends: `EngramServiceArchiveV2ReplicaStatus` with durable backlog fields.
- Extends: `EngramServiceArchiveV2StatusResponse` with optional
  `lastReplicationCycle` and `nextScheduledCycleAt`.

- [ ] **Step 1: Write failing wire tests**

Assert round-trip encoding for all new fields, rejection of negative counts and
invalid timestamp/symbol values, deterministic replica order, and successful
decoding when an older payload omits every new field.

- [ ] **Step 2: Run the tests and verify RED**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramServiceCoreTests/ArchiveV2ServiceWireTests
```

Expected: compilation failure because the wire types and fields do not exist.

- [ ] **Step 3: Implement validated Codable models**

Add retry-reason and cycle-summary structs with non-negative count validation,
finite non-negative duration validation, ISO-8601 timestamp validation, and
symbol validation. Decode optional timestamps and cycle summary with
`decodeIfPresent`; decode reason arrays with `decodeIfPresent(...) ?? []`.
Update zero/default status constructors and the mock client.

- [ ] **Step 4: Map catalog aggregates into the response**

Map exact retry symbols and counts without UI grouping. Pass nil for volatile
cycle/schedule fields until Task 3 records them.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Task 2 command. Expected: `ArchiveV2ServiceWireTests` pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add macos/Shared/Service/EngramServiceModels.swift macos/Shared/Service/MockEngramServiceClient.swift macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift macos/EngramService/Core/EngramServiceCommandHandler+ArchiveV2.swift macos/EngramServiceCoreTests/ArchiveV2ServiceWireTests.swift
git commit -m "feat: expose archive backlog diagnostics"
```

### Task 3: Latest cycle and next opportunity

**Files:**
- Modify: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift`
- Test: `macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift`
- Test: `macos/EngramServiceCoreTests/ArchiveV2RunnerIntegrationTests.swift`

**Interfaces:**
- Produces: `ArchiveV2ServiceCoordinator.recordNextScheduledCycle(at:)`.
- Updates: `EngramServiceArchiveV2StatusResponse.lastReplicationCycle` and
  `.nextScheduledCycleAt`.
- Consumes: existing `ArchiveReplicationCycleResult`.

- [ ] **Step 1: Write failing coordinator and runner tests**

Use an injected clock to assert the exact start, finish, duration, and replication
counts. Run a second pass and assert it replaces the first summary. Assert that
`recordNextScheduledCycle(at:)` updates status and that the runner records the
calculated opportunity before waiting.

- [ ] **Step 2: Run the tests and verify RED**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests -only-testing:EngramServiceCoreTests/ArchiveV2RunnerIntegrationTests
```

Expected: compilation or assertion failure for missing summary/schedule behavior.

- [ ] **Step 3: Record bounded actor state**

Inject `now: @Sendable () -> Date` into coordinator construction. Around only
the replication attempt, capture start and finish dates and replace the latest
summary. Clamp duration to zero if a test clock moves backwards. Add an actor
method accepting an exact `Date` for the next opportunity.

- [ ] **Step 4: Connect the scheduler and bounded log**

Before each background wait, call `recordNextScheduledCycle(at:)` with
`Date().addingTimeInterval(sleepSeconds)`. After a replication attempt, emit one
Archive V2 log summary containing only counts, duration, cancellation, and the
cycle error symbol.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Task 3 command. Expected: both focused suites pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift macos/EngramService/Core/EngramServiceRunner.swift macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift macos/EngramServiceCoreTests/ArchiveV2RunnerIntegrationTests.swift
git commit -m "feat: record archive sync cycle telemetry"
```

### Task 4: Localized settings diagnostics

**Files:**
- Modify: `macos/Engram/Views/Settings/ArchiveSettingsSection.swift`
- Modify: `macos/Engram/Resources/Localizable.xcstrings`
- Test: `macos/EngramTests/ArchiveSettingsSectionTests.swift`
- Test: `macos/EngramUITests/Tests/FullTests/SettingsTests.swift`

**Interfaces:**
- Consumes: the Task 2 status fields.
- Produces: friendly retry categories while leaving exact symbols unchanged in
  the status DTO and CLI JSON.

- [ ] **Step 1: Write failing presentation tests**

Assert category grouping for network, credentials, local archive, remote
verification, configuration, and unknown symbols. Assert non-transient reasons
produce `needsAttention`, while network retry-wait remains `inProgress`. Assert
new accessibility identifiers and Simplified Chinese keys are present.

- [ ] **Step 2: Run the tests and verify RED**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skip-testing:EngramUITests -only-testing:EngramTests/ArchiveSettingsSectionTests
```

Expected: compilation or assertion failure for missing presentation behavior.

- [ ] **Step 3: Implement compact always-visible details**

Add pure presentation helpers for grouping, local date formatting, and duration
formatting. Render latest pass, per-replica backlog explanation, and approximate
next opportunity only when data exists. Keep the current refresh button and do
not add timers or sleeps.

- [ ] **Step 4: Add and validate Simplified Chinese strings**

Add every new heading, formatted line, category, and accessibility-visible label
to `Localizable.xcstrings`. Preserve format placeholder signatures.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Task 4 command. Expected: `ArchiveSettingsSectionTests` pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add macos/Engram/Views/Settings/ArchiveSettingsSection.swift macos/Engram/Resources/Localizable.xcstrings macos/EngramTests/ArchiveSettingsSectionTests.swift macos/EngramUITests/Tests/FullTests/SettingsTests.swift
git commit -m "feat: explain archive sync retries in settings"
```

### Task 5: Integrated verification

**Files:**
- Verify only; no planned production-file change.

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: fresh test, build, diff, and product-status evidence.

- [ ] **Step 1: Run all Archive V2 core and service tests**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: both commands exit 0 with zero failures.

- [ ] **Step 2: Run app tests and build**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skip-testing:EngramUITests
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: tests and build exit 0.

- [ ] **Step 3: Run repository and localization guards**

```bash
git diff --check
git status --short
```

Inspect the final diff for unrelated changes, secrets, identifiers, or polling.

- [ ] **Step 4: Compare supported JSON shape**

Run the built CLI helper against the running service only if the helper and
service share the new build. Confirm retry symbols, timestamps, cycle summary,
and scheduling fields encode without exposing object identifiers. Do not deploy
or replace `/Applications/Engram.app` without separate authorization.
