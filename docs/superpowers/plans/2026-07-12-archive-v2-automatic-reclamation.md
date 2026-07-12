# Archive V2 Automatic Reclamation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in, fail-closed automatic reclamation of Archive V2 source files and local CAS objects after dual-replica durability and recent bounded recovery drills are proven.

**Architecture:** Extend the Archive V2 catalog with durable object references, local residency, recovery leases, and reclamation intents. A low-priority coordinator plans and executes write-ahead same-directory quarantine, then evicts shared CAS objects only when every reference is remote-safe. Existing service, CLI, resolver, and Settings surfaces expose status and controls without adding remote deletion.

**Tech Stack:** Swift 6, GRDB/SQLite, Swift Concurrency, SwiftUI, XCTest, XcodeGen, Vitest safety gates.

## Global Constraints

- Default off; hot-window choices are exactly 30, 60, 90, and 180 days, default 30.
- Only replay-proven single-regular-file Claude Code and Codex sources are eligible.
- Never delete remote Archive V2 objects, manifests, receipts, or catalog history.
- Keep local manifests, receipts, session metadata, summaries, and search data.
- Require current HQ and M1 receipts per candidate plus HQ and M1 recovery leases no older than 30 days.
- Each recovery drill reads at most 64 MiB and runs at most 60 seconds.
- Each reclamation cycle handles at most 10 sources, hashes at most 256 MiB of source bytes, and evicts at most 256 MiB of CAS bytes.
- A source larger than 256 MiB pauses as `source_too_large`; no verification bypass exists.
- Every production behavior change is implemented RED/GREEN and reviewed by Grok before the next phase.
- Deployment, enablement, and real production deletion remain separate explicit-authorization operations.

---

### Task 1: Catalog object graph, residency, leases, and intents

**Files:**
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalogMigrations.swift`
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift`
- Modify: `macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift`
- Modify: `macos/EngramCoreTests/ArchiveV2/ArchiveModelTests.swift`

**Interfaces:**
- Produces: `ArchiveLocalObject`, `ArchiveManifestObject`, `ArchiveRecoveryLease`, `ArchiveReclamationIntent`, `ArchiveReclamationPhase`, and catalog CRUD/claim transitions used by later tasks.
- Invariant: binding acceptance writes manifest-object references and resident object rows in the same catalog transaction.

- [ ] **Step 1: Write failing migration and catalog tests**

Add tests proving schema v3 creates:

```sql
archive_local_objects(object_sha256 PRIMARY KEY, raw_byte_count, residency, updated_at)
archive_manifest_objects(manifest_sha256, ordinal, object_sha256, raw_byte_count,
                         PRIMARY KEY(manifest_sha256, ordinal))
archive_recovery_leases(replica_id PRIMARY KEY, manifest_sha256, verified_at,
                        verified_bytes, result, error)
archive_reclamation_intents(manifest_sha256 PRIMARY KEY, capture_id, session_id,
                            locator, phase, quarantine_path, attempts,
                            released_source_bytes, released_cas_bytes,
                            last_error, updated_at)
```

Tests must cover canonical-manifest backfill, invalid-manifest migration rollback,
shared object reverse lookup, resident/evicted transition CAS, lease upsert, intent
claim generation, legal phase transitions, and bounded symbolic errors.

- [ ] **Step 2: Run RED**

Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests \
  -destination 'platform=macOS' \
  -only-testing:EngramCoreTests/ArchiveCatalogTests \
  -only-testing:EngramCoreTests/ArchiveModelTests
```

Expected: new schema/types/API tests fail to compile or fail because schema v3 is absent.

- [ ] **Step 3: Implement minimal schema and catalog APIs**

Increment `currentSchemaVersion` to `3`. Decode each existing canonical bound
manifest during migration and insert its ordered chunk references with
`INSERT ... ON CONFLICT` checks that reject digest/size disagreement. Add typed
rows and explicit transition methods; never expose arbitrary phase strings or
an unconditional delete method.

- [ ] **Step 4: Run GREEN and commit**

Run the Task 1 command, then:

```bash
git add macos/EngramCoreWrite/ArchiveV2/ArchiveCatalogMigrations.swift \
        macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift \
        macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift \
        macos/EngramCoreTests/ArchiveV2/ArchiveModelTests.swift
git diff --cached --check
git commit -m "feat(archive): add reclamation catalog state"
```

### Task 2: Bounded rotating recovery-drill leases

**Files:**
- Modify: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler+ArchiveV2.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/EngramServiceProtocol.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/Shared/Service/MockEngramServiceClient.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2IPCTests.swift`

**Interfaces:**
- Produces: `runRecoveryDrill(replicaID:)` and lease/status DTOs.
- Reuses: existing remote recovery-probe resolver path; no second byte-verification implementation.

- [ ] **Step 1: Write failing tests**

Cover durable round-robin selection, independent HQ/M1 leases, 64 MiB candidate
exclusion, 60-second timeout mapping, manifest/chunk/whole-hash verification,
lease expiry at 30 days, failed drill not extending a lease, and capability-token
protection for the mutating drill command.

- [ ] **Step 2: Run RED**

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests \
  -only-testing:EngramServiceCoreTests/ArchiveV2IPCTests
```

- [ ] **Step 3: Implement and run GREEN**

Extend the existing probe operation with catalog-selected session identity,
replica-specific backend selection, a `ContinuousClock` timeout race, and lease
recording only after the existing resolver returns verified bytes. Persist the
round-robin cursor in `archive_metadata`.

- [ ] **Step 4: Commit**

```bash
git add macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift \
        macos/EngramService/Core/EngramServiceCommandHandler+ArchiveV2.swift \
        macos/Shared/Service macos/EngramServiceCoreTests
git diff --cached --check
git commit -m "feat(archive): record bounded recovery drill leases"
```

### Task 3: Reclamation policy and read-only preview

**Files:**
- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveReclamationPolicy.swift`
- Create: `macos/EngramCoreTests/ArchiveV2/ArchiveReclamationPolicyTests.swift`
- Modify: `macos/project.yml`

**Interfaces:**
- Produces: pure `ArchiveReclamationPolicy.evaluate(candidate:context:)` returning `eligible` or one bounded blocker symbol.
- Consumes: age, source kind, favorite/live state, generation, receipts, leases, active-operation claims, and byte budgets.

- [ ] **Step 1: Write failing table-driven tests**

Test exact 30/60/90/180-day boundaries, invalid windows, Claude/Codex admission,
unsupported sources, live/favorite, missing/current receipts, missing/expired
leases, newer capture, active operation, and `source_too_large`. Test deterministic
blocker precedence so Preview and execution report the same reason.

- [ ] **Step 2: Run RED**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests \
  -destination 'platform=macOS' \
  -only-testing:EngramCoreTests/ArchiveReclamationPolicyTests
```

- [ ] **Step 3: Implement pure policy, run GREEN, and commit**

Keep policy free of filesystem/network/database calls. Use injected `now` and
integer nanosecond/date facts. Commit as `feat(archive): add reclamation policy`.

### Task 4: Write-ahead source quarantine and crash recovery

**Files:**
- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveSourceReclaimer.swift`
- Create: `macos/EngramCoreTests/ArchiveV2/ArchiveSourceReclaimerTests.swift`
- Modify: `macos/project.yml`

**Interfaces:**
- Produces: `planAndReclaim(intent:)` and `recoverPlannedQuarantines()`.
- Consumes: catalog phase-CAS APIs and exact source generation/hash primitives.

- [ ] **Step 1: Write failing filesystem tests**

Cover write-ahead `quarantine_planned`, crash before rename, crash after rename,
post-rename generation/hash mismatch, symlink/non-regular rejection, recreated
original collision, successful unlink, directory fsync failure, cancellation,
and 256 MiB hashing budget. Assert no path combination overwrites user data.

- [ ] **Step 2: Run RED**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests \
  -destination 'platform=macOS' \
  -only-testing:EngramCoreTests/ArchiveSourceReclaimerTests
```

- [ ] **Step 3: Implement minimal safe filesystem primitive**

Persist plan/path before `rename`, fsync the catalog through its existing FULL
durability boundary, use same-directory unique names, `lstat`/`open(O_NOFOLLOW)`/
`fstat`, stream SHA-256, fsync the parent after rename/unlink, and phase-CAS every
commit. Recovery handles the two approved path combinations and pauses all others.

- [ ] **Step 4: Run GREEN and commit**

Commit as `feat(archive): reclaim source files with write-ahead quarantine`.

### Task 5: Shared CAS eviction and resolver residency

**Files:**
- Create: `macos/EngramCoreWrite/ArchiveV2/ArchiveCASEvictor.swift`
- Create: `macos/EngramCoreTests/ArchiveV2/ArchiveCASEvictorTests.swift`
- Modify: `macos/EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift`
- Modify: `macos/EngramService/Core/ArchiveTranscriptResolver.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveTranscriptResolverTests.swift`
- Modify: `macos/project.yml`

**Interfaces:**
- Produces: bounded `evictEligibleObjects(for:)` and resolver residency lookup.
- Invariant: an object is evictable only when every referencing manifest has source-deleted state and current HQ/M1 receipts plus leases.

- [ ] **Step 1: Write failing tests**

Cover shared chunk held by one unsafe manifest, all references safe, 256 MiB
budget, phase/state ordering around unlink, intentional evicted fallback,
resident-but-missing integrity fault plus remote recovery, HQ failure→M1 success,
and both-remotes-fail behavior.

- [ ] **Step 2: Run RED**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests \
  -destination 'platform=macOS' \
  -only-testing:EngramCoreTests/ArchiveCASEvictorTests
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramServiceCoreTests/ArchiveTranscriptResolverTests
```

- [ ] **Step 3: Implement, run GREEN, and commit**

Mark an object evicted only after its CAS file removal succeeds. If removal
fails, keep residency `resident`; if a resident file is absent, record the
integrity fault without mutating residency. Commit as
`feat(archive): evict remote-safe local objects`.

### Task 6: Coordinator, settings, IPC, and CLI

**Files:**
- Create: `macos/EngramService/Core/ArchiveReclamationCoordinator.swift`
- Create: `macos/EngramServiceCoreTests/ArchiveReclamationCoordinatorTests.swift`
- Modify: `macos/EngramService/Core/ArchiveV2Settings.swift`
- Modify: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler+ArchiveV2.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/EngramServiceProtocol.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/Shared/Service/MockEngramServiceClient.swift`
- Modify: `macos/Shared/Service/ServiceCapabilityToken.swift`
- Modify: `macos/Shared/Service/EngramCLIArchiveCommand.swift`
- Modify: `macos/EngramTests/EngramCLIArchiveCommandTests.swift`
- Modify: `macos/project.yml`

**Interfaces:**
- Produces: status, preview, settings update, run-once, and drill commands.
- Fixed command names: `archiveReclamationStatus`, `archiveReclamationPreview`, `archiveReclamationUpdateSettings`, `archiveReclamationRun`, `archiveV2RecoveryDrill`.

- [ ] **Step 1: Write failing coordinator/wire/CLI tests**

Cover default-off and invalid-value fail-closed parsing, candidate/blocker preview,
coalesced background/manual cycle, 10-source/256 MiB budgets, protected mutating
commands, read-only status/preview, JSON round trips, CLI parsing/output, and
settings refresh without restart.

- [ ] **Step 2: Run RED**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramServiceCoreTests/ArchiveReclamationCoordinatorTests \
  -only-testing:EngramServiceCoreTests/ArchiveV2IPCTests
xcodebuild test -project Engram.xcodeproj -scheme Engram \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -skip-testing:EngramUITests \
  -only-testing:EngramTests/EngramCLIArchiveCommandTests
```

Expected: the new coordinator, wire DTOs, commands, and CLI cases fail before
their production interfaces exist.

- [ ] **Step 3: Implement orchestration and run GREEN**

Run recovery before new work, plan candidates through the pure policy, execute
source phase before CAS phase, and expose bounded aggregate status. Schedule only
when enabled; one replica outage pauses reclamation without failing indexing.

- [ ] **Step 4: Commit**

Commit as `feat(archive): wire automatic reclamation service`.

### Task 7: Storage Settings UI

**Files:**
- Create: `macos/Engram/Views/Settings/StorageSettingsSection.swift`
- Create: `macos/EngramTests/StorageSettingsTests.swift`
- Modify: `macos/Engram/Views/SettingsView.swift`
- Modify: `macos/EngramTests/AppSearchServiceCutoverScanTests.swift`
- Modify: `macos/project.yml`

**Interfaces:**
- Consumes: service status/preview/update/run/drill DTOs from Task 6.
- Produces: top-level Storage category and approved controls/accessibility IDs.

- [ ] **Step 1: Write failing view-model and source-wiring tests**

Test category presence, default off, picker values, two-lease enable gate,
first-enable confirmation, persisted reload, Disabled/Ready/Paused labels,
candidate/released-byte rendering, blocker text, Preview, Run Now, duplicate
action disablement, error display, and stable accessibility identifiers.

- [ ] **Step 2: Run RED**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme Engram \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -skip-testing:EngramUITests \
  -only-testing:EngramTests/StorageSettingsTests \
  -only-testing:EngramTests/AppSearchServiceCutoverScanTests
```

- [ ] **Step 3: Implement approved UI, run GREEN, and commit**

Keep internal batch/byte limits hidden. Confirmation copy must state that source
files and local archive content are removed while metadata/search remain and
full text restores from HQ/M1. Commit as `feat(app): add archive storage settings`.

### Task 8: Safety gates, docs, Grok zero-findings review, and full verification

**Files:**
- Modify: `scripts/check-archive-v2-safety.sh`
- Modify: `tests/scripts/archive-v2-safety-gate.test.ts`
- Modify: `docs/remote-archive-v2.md`
- Modify: `docs/followups.md`
- Modify: `docs/roadmap.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: explicit allowlist for only the reviewed local deletion primitives; remote v2 DELETE remains forbidden.

- [ ] **Step 1: Write RED safety-gate tests**

Prove remote delete methods/routes remain rejected, generic filesystem deletion
outside `ArchiveSourceReclaimer`/`ArchiveCASEvictor` remains rejected, quarantine
cleanup is not a broad glob, and docs no longer claim zero local deletion after
the feature is implemented (while default-off remains true).

- [ ] **Step 2: Run RED, implement gate/docs, and run GREEN**

```bash
npm test -- tests/scripts/archive-v2-safety-gate.test.ts
bash scripts/check-archive-v2-safety.sh
```

- [ ] **Step 3: Run Grok adversarial branch review**

Use Polycli Grok against the branch diff from `897a25e7`, focused on data loss,
TOCTOU/crash recovery, shared CAS references, SQLite transitions, concurrency,
settings honesty, and test gaps. Adjudicate every finding against source. For
each confirmed behavior bug, add a failing test, run RED, implement the smallest
fix, and run GREEN. Repeat Grok review until it reports no confirmed issue.

- [ ] **Step 4: Run full verification**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skip-testing:EngramUITests
xcodebuild build -project Engram.xcodeproj -scheme Engram -configuration Debug CODE_SIGNING_ALLOWED=NO
cd ..
npm test -- tests/scripts/archive-v2-safety-gate.test.ts tests/scripts/ci-workflow.test.ts
bash scripts/check-archive-v2-safety.sh
git diff --check
```

- [ ] **Step 5: Commit closeout**

Commit verified safety/docs changes as
`docs(archive): document automatic reclamation safety gates`. Do not deploy,
enable reclamation, run production drills, or delete production data in this task.
