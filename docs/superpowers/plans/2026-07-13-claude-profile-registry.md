# Claude Code Profile Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically discover `~/.claude-*/projects`, allow validated custom Claude Code projects roots, index and Archive V2-sync them through one multi-root adapter, terminate generation-matched empty captures, and expose per-profile settings/status.

**Architecture:** Add a shared, bounded `ClaudeCodeProfileResolver` that merges default, direct-home automatic, and secure settings-backed custom roots. Refactor `ClaudeCodeAdapter` to resolve and route multiple roots while preserving default-root derived-source behavior. Add a service-owned configuration/status coordinator, an Archive V2 ignored-empty disposition, and a SwiftUI Data Sources card; keep custom roots outside source-file reclamation.

**Tech Stack:** Swift 5.9, Foundation, Swift concurrency, GRDB/SQLite, SwiftUI, XCTest, XcodeGen/Xcode, existing Archive V2 CAS and service IPC.

## Global Constraints

- Preserve exact capture before parsing, immutable CAS publication, generation checks, dual receipts, recovery drills, and deletion gates.
- Never parse `.zshrc`, provider settings, API keys, or shell environment to discover profiles.
- Automatic discovery is limited to direct `~/.claude-*` children with an immediate `projects` directory.
- Custom roots must be existing absolute Claude Code `projects` directories and are capped at 64.
- Default and automatic roots follow the approved global reclamation gate; custom roots are source-reclamation-ineligible.
- A generation-matched `noVisibleMessages` capture may become terminal ignored but must not be remotely replicated or locally deleted by that transition.
- Keep `sessions.source=claude-code` for non-default profiles; do not add provider cases to `SourceName` or a new sessions schema column.
- Status is manual-refresh only and must not add polling, timers, raw error bodies, secrets, or remote paths beyond the local profile path already chosen by the user.
- Do not add dependencies or manually edit `macos/Engram.xcodeproj`; add files through `macos/project.yml`/XcodeGen.
- Build on the implemented Archive V2 backlog-drainer branch so the expanded corpus is not tied to the old periodic shared batch.

---

### Task 1: Bounded Profile Resolution and Settings Validation

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/ClaudeCodeProfileResolver.swift`
- Create: `macos/EngramCoreTests/Adapters/ClaudeCodeProfileResolverTests.swift`
- Modify: `macos/project.yml`

**Interfaces:**
- Produces: `ClaudeCodeProfile`, `ClaudeCodeProfileSettings`, `ClaudeCodeProfileResolution`, and `ClaudeCodeProfileResolver`.
- Produces: `ClaudeCodeProfileResolver.resolve()` and `ClaudeCodeProfileResolver.validateCustomProjectsRoots(_:)`.
- Consumes: `~/.engram/settings.json` key `claudeCodeProfiles` without writing it.

- [ ] **Step 1: Write resolver RED tests**

Add tests covering default inclusion, default-on automatic discovery, direct-child-only matching, deterministic order, canonical duplicate collapse, missing configured roots, disabled automatic discovery, and the 64-root cap. Use temporary home/settings directories and write only fixture JSON.

The intended public surface is:

```swift
public struct ClaudeCodeProfile: Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case `default`, automatic, custom
    }
    public let id: String
    public let displayName: String
    public let projectsRoot: String
    public let origin: Origin
    public let available: Bool
    public let sourceReclamationAllowed: Bool
}

public struct ClaudeCodeProfileSettings: Equatable, Sendable {
    public let autoDiscover: Bool
    public let customProjectsRoots: [String]
}

public struct ClaudeCodeProfileResolution: Equatable, Sendable {
    public let settings: ClaudeCodeProfileSettings
    public let profiles: [ClaudeCodeProfile]
    public let configurationError: String?
}

public struct ClaudeCodeProfileResolver: Sendable {
    public init(homeDirectory: URL, settingsURL: URL)
    public func resolve() -> ClaudeCodeProfileResolution
    public func validateCustomProjectsRoots(_ roots: [String]) throws -> [String]
}
```

- [ ] **Step 2: Run resolver tests and verify RED**

Run:

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:EngramCoreTests/ClaudeCodeProfileResolverTests
```

Expected: compile failure because the resolver types do not exist.

- [ ] **Step 3: Implement the minimal resolver**

Implement bounded JSON parsing, path validation, immediate-home enumeration, symlink-resolved deduplication, deterministic SHA-256 IDs, availability, and source-reclamation flags. Invalid settings must return defaults plus a fixed symbolic `configurationError`; validation for a new save must throw and leave persistence to the service task.

- [ ] **Step 4: Run resolver tests and verify GREEN**

Run the Task 1 test command. Expected: every selected test passes.

- [ ] **Step 5: Commit Task 1**

```bash
git add macos/Shared/EngramCore/Adapters/ClaudeCodeProfileResolver.swift \
  macos/EngramCoreTests/Adapters/ClaudeCodeProfileResolverTests.swift \
  macos/project.yml macos/Engram.xcodeproj/project.pbxproj
git commit -m "feat(sources): resolve Claude profile roots"
```

---

### Task 2: Multi-root Claude Code Adapter

**Files:**
- Modify: `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift`
- Modify: `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift`
- Modify: `macos/EngramCoreTests/AdapterMessageCountTests.swift`
- Create: `macos/EngramCoreTests/Adapters/ClaudeCodeMultiRootAdapterTests.swift`

**Interfaces:**
- Extends: `ClaudeCodeAdapter.init(profileResolver:limits:sourceHintCacheDirectory:)`.
- Preserves: `ClaudeCodeAdapter.init(projectsRoot:limits:sourceHintCacheDirectory:)`.
- Produces: `ClaudeCodeAdapter.profile(for:)` and longest-root archive descriptor routing.
- Changes: derived MiniMax/LobsterAI locator enumeration is restricted to the default profile.

- [ ] **Step 1: Write multi-root adapter RED tests**

Create fixture trees with one default root, two automatic roots, one custom root,
duplicate symlink roots, top-level JSONL, and subagent JSONL. Assert:

```swift
let adapter = ClaudeCodeAdapter(profileResolver: resolver)
let locators = try await adapter.listSessionLocators()
XCTAssertEqual(Set(locators), Set(expectedCanonicalLocators))
XCTAssertEqual(try success(await adapter.parseSessionInfo(locator: apiFile)).source, .claudeCode)
XCTAssertEqual(try success(await adapter.parseSessionInfo(locator: apiFile)).originator, "claude-code")
```

Also prove default-root MiniMax remains `.minimax`, non-default MiniMax becomes
`.claudeCode`, archive replay-relative paths are calculated under the matching
profile root, a locator outside resolved roots fails closed, and settings changes
are observed on the next listing.

- [ ] **Step 2: Run adapter tests and verify RED**

Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:EngramCoreTests/ClaudeCodeMultiRootAdapterTests \
  -only-testing:EngramCoreTests/AdapterMessageCountTests
```

Expected: compile/test failure for the missing multi-root initializer and wrong
non-default source classification.

- [ ] **Step 3: Implement multi-root enumeration and routing**

Replace the single stored root with a resolver-backed profile snapshot. Extract
the existing one-root walk into a helper, merge canonical locators, and route
`archiveSourceDescriptor` through the longest containing root. Pass a
`forceClaudeCodeSource` decision into both parse-1 and parse+messages paths so
all non-default profiles return `.claudeCode` and `originator="claude-code"`.

Keep the legacy initializer by constructing a fixed one-profile resolver. Give
`SessionAdapterFactory.defaultAdapters()` a resolver-backed Claude adapter using
the default home/settings locations. Restrict derived adapter discovery to the
default root.

- [ ] **Step 4: Run adapter tests and verify GREEN**

Run the Task 2 command. Expected: all selected tests pass, including existing
empty-visible-message and source-hint cases.

- [ ] **Step 5: Commit Task 2**

```bash
git add macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift \
  macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift \
  macos/EngramCoreTests/AdapterMessageCountTests.swift \
  macos/EngramCoreTests/Adapters/ClaudeCodeMultiRootAdapterTests.swift
git commit -m "feat(sources): index Claude profiles through one adapter"
```

---

### Task 3: Terminal Empty-capture Disposition

**Files:**
- Modify: `macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift`
- Modify: `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift`

**Interfaces:**
- Produces: `ArchiveCatalog.ignoreUnboundCapture(captureID:reason:updatedAt:)`.
- Changes: unbound capture queries select `status='captured'` only.
- Extends: `ArchiveV2ServiceIndexSnapshot` with a target-scoped trusted terminal failure map.
- Extends: Archive V2 status with `ignoredEmptyCaptureCount` using backward-compatible decoding.

- [ ] **Step 1: Write catalog and coordinator RED tests**

Catalog tests must insert captured/unbound rows, mark one ignored, and prove it no
longer appears in boundary/page queries while the capture and local objects stay
present. Coordinator tests must build a current `file_index_state` row with
`failure_kind=noVisibleMessages` and matching device/inode/size/mtime, then prove:

```swift
XCTAssertEqual(result.boundRows, 0)
XCTAssertEqual(try catalog.ignoredCaptureCount(reason: "no_visible_messages"), 1)
XCTAssertEqual(try catalog.replicaReceiptCount(captureID: captureID), 0)
```

Separate tests must reject stale generation, current-schema mismatch, malformed
JSON, missing files, and an ordinary no-match.

- [ ] **Step 2: Run focused tests and verify RED**

Run the selected ArchiveCatalog and ArchiveV2ServiceCoordinator test suites.
Expected: compile/test failures for missing ignored disposition and status field.

- [ ] **Step 3: Implement ignored capture state and trusted failure proof**

Use `archive_captures.status='ignored'` and the fixed diagnostic
`no_visible_messages`; do not add a schema column or delete CAS objects. Update
unbound SQL predicates to require the current captured status. Build a target
state even when no `sessions` row exists, but trust `noVisibleMessages` only when
the index state and exact generation both match a fresh stat. During reconcile,
mark that target ignored instead of calling bind with an empty identity list.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Task 3 tests. Expected: ignored-empty, stale-state, existing binding,
receipt, and backlog-drainer tests pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add macos/EngramCoreWrite/ArchiveV2/ArchiveCatalog.swift \
  macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift \
  macos/Shared/Service/EngramServiceModels.swift \
  macos/EngramCoreTests/ArchiveV2/ArchiveCatalogTests.swift \
  macos/EngramServiceCoreTests/ArchiveV2ServiceCoordinatorTests.swift
git commit -m "fix(archive): retire empty transcript captures"
```

---

### Task 4: Custom-root Reclamation Safety

**Files:**
- Modify: `macos/EngramService/Core/ArchiveReclamationCoordinator.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveReclamationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ClaudeCodeProfileResolver.resolve()`.
- Produces: `ArchiveReclamationCoordinator.sourceReclamationAllowed(locator:source:)`.
- Preserves: local CAS reclamation and all existing receipt/drill/generation gates.

- [ ] **Step 1: Write reclamation RED tests**

Create otherwise-eligible candidates under default, automatic, and custom roots.
Assert source intents are created for default/automatic roots, not for custom
roots, and the custom source file remains byte-identical after preview and run.
Also assert Codex behavior is unchanged.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramServiceCoreTests/ArchiveReclamationCoordinatorTests
```

Expected: the custom-root candidate is currently treated like a normal Claude
source and the new assertion fails.

- [ ] **Step 3: Implement the source-path safety gate**

Resolve the profile containing a Claude locator before planning source
quarantine. Return false for custom profiles and unknown profile roots. Do not
change CAS eviction eligibility. Keep Codex and default/automatic Claude behavior
behind the existing global reclamation, dual-receipt, drill, age, generation, and
lease checks.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Task 4 command. Expected: all reclamation tests pass.

- [ ] **Step 5: Commit Task 4**

```bash
git add macos/EngramService/Core/ArchiveReclamationCoordinator.swift \
  macos/EngramServiceCoreTests/ArchiveReclamationCoordinatorTests.swift
git commit -m "fix(archive): protect custom transcript roots from reclamation"
```

---

### Task 5: Profile Configuration, Status, and IPC

**Files:**
- Create: `macos/EngramService/Core/ClaudeCodeProfileService.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/EngramServiceProtocol.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/Shared/Service/MockEngramServiceClient.swift`
- Modify: `macos/Shared/Service/ServiceCapabilityToken.swift`
- Create: `macos/EngramServiceCoreTests/ClaudeCodeProfileServiceTests.swift`
- Modify: `macos/EngramServiceCoreTests/EngramServiceWireCommandTests.swift`
- Modify: `macos/project.yml`

**Interfaces:**
- Produces: `EngramServiceClaudeCodeProfileStatus`,
  `EngramServiceClaudeCodeProfilesStatusResponse`, and
  `EngramServiceConfigureClaudeCodeProfilesRequest`.
- Produces: client methods `claudeCodeProfilesStatus()` and
  `configureClaudeCodeProfiles(_:)`.
- Produces: service commands `claudeCodeProfilesStatus` and
  `configureClaudeCodeProfiles`.

- [ ] **Step 1: Write service and wire RED tests**

Use temporary index/archive databases and fixture profile roots. Require bounded
status counts for discovered files/bytes, live indexed locators, captured,
ignored-empty, HQ verified, and M1 verified. Require deterministic row order,
fixed symbolic errors, old-response decoding defaults, capability registration,
no-payload enforcement for status, full-replacement configure semantics, and
preservation of unrelated settings JSON keys.

- [ ] **Step 2: Run service tests and verify RED**

Run selected `ClaudeCodeProfileServiceTests` and wire-command tests. Expected:
compile failures for missing models, protocol methods, commands, and coordinator.

- [ ] **Step 3: Implement `ClaudeCodeProfileService`**

Inject the resolver, `ServiceWriterGate`, optional `ArchiveCatalog`, settings URL,
and a `@Sendable () async -> Void` drainer signal. Count filesystem locators with
the same bounded walk as the adapter, query index rows by canonical root prefix,
and query archive rows/receipts by locator prefix. Cap returned profiles at 128
and integer counts at non-negative values.

Configure by validating the complete request, calling
`SecureSettingsFileWriter.mutateJSON`, then signalling the drainer. A failed save
must not mutate settings or signal work.

- [ ] **Step 4: Wire command handler, client, mock, and runner**

Register both commands and capability tokens, inject the profile service from
`EngramServiceRunner`, add client and mock implementations, and exclude the
manual status command from service telemetry self-noise. Keep absent profile
service behavior a fixed `feature_unavailable` error for unit-test compositions.

- [ ] **Step 5: Run service tests and verify GREEN**

Run Task 5 selected tests plus `ArchiveV2ServiceWireTests`. Expected: all pass.

- [ ] **Step 6: Commit Task 5**

```bash
git add macos/EngramService/Core/ClaudeCodeProfileService.swift \
  macos/EngramService/Core/EngramServiceCommandHandler.swift \
  macos/EngramService/Core/EngramServiceRunner.swift \
  macos/Shared/Service macos/EngramServiceCoreTests \
  macos/project.yml macos/Engram.xcodeproj/project.pbxproj
git commit -m "feat(service): manage Claude profile roots"
```

---

### Task 6: Data Sources Settings UI and Localization

**Files:**
- Modify: `macos/Engram/Views/Settings/SourcesSettingsSection.swift`
- Modify: `macos/Engram/Resources/Localizable.xcstrings`
- Modify: `macos/EngramTests/SourcesSyncTests.swift`
- Create: `macos/EngramTests/ClaudeCodeProfilesSettingsTests.swift`

**Interfaces:**
- Consumes: Task 5 service client methods and DTOs.
- Produces: `ClaudeCodeProfilesSettingsCard` with stable identifiers
  `claudeProfiles_autoDiscover`, `claudeProfiles_add`, `claudeProfiles_save`,
  `claudeProfiles_refresh`, and `claudeProfiles_row_<profile-id>`.

- [ ] **Step 1: Write UI/localization RED tests**

Require the Data Sources page to load status on task entry, show automatic/custom
rows, expose add/remove/save/refresh identifiers, use an `NSOpenPanel` configured
for one directory and no files, and never add a timer or `.onReceive` polling.
Require English and Simplified Chinese values for all new visible strings,
availability, reclamation, count summaries, validation failures, and save state.

- [ ] **Step 2: Run App tests and verify RED**

Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme Engram \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramTests/SourcesSyncTests \
  -only-testing:EngramTests/ClaudeCodeProfilesSettingsTests
```

Expected: source/localization assertions fail because the card does not exist.

- [ ] **Step 3: Implement the settings card**

Use `@Environment(EngramServiceClient.self)`, local editable settings state, and
manual async load/save. `Add Projects Folder...` appends the selected canonical
path if absent; Remove affects custom rows only. Render compact per-profile
counts with `ByteCountFormatter`, show custom-root reclamation protection, and
keep the existing MCP setup below the card.

- [ ] **Step 4: Add localized strings**

Add complete English and `zh-Hans` translations in
`Localizable.xcstrings`. Do not leave extraction-state placeholders or untranslated
English values in the Chinese locale.

- [ ] **Step 5: Run App tests and verify GREEN**

Run Task 6 selected tests. Expected: all pass with no Swift concurrency warning
introduced by the view.

- [ ] **Step 6: Commit Task 6**

```bash
git add macos/Engram/Views/Settings/SourcesSettingsSection.swift \
  macos/Engram/Resources/Localizable.xcstrings \
  macos/EngramTests/SourcesSyncTests.swift \
  macos/EngramTests/ClaudeCodeProfilesSettingsTests.swift
git commit -m "feat(app): configure and observe Claude profiles"
```

---

### Task 7: Integration, Review, Merge, and Deployment

**Files:**
- Modify only files required by confirmed review findings.
- Do not create memory/changelog/handoff artifacts unless separately requested.

**Interfaces:**
- Consumes: all Tasks 1-6 plus the existing backlog-drainer implementation.
- Produces: reviewed `main`, verified local app install, and matching healthy HQ/M1 RemoteServer deployments.

- [ ] **Step 1: Run focused integration verification**

Run all profile, adapter, archive catalog, coordinator, reclamation, wire, App,
backlog-drainer, localization, archive-safety, and `git diff --check` checks.

- [ ] **Step 2: Run independent review**

Dispatch at least two read-only reviewers: one for adapter/data/archive correctness
and one for IPC/UI/operational safety. Require file:line evidence and explicit
Critical/Important/Minor findings. Adjudicate each claim against current code and
tests; use TDD for every confirmed fix.

- [ ] **Step 3: Run release-level verification**

Run the relevant full Swift schemes, repository TypeScript checks affected by
docs/contracts, XcodeGen drift check, archive safety gates, Release app build, and
RemoteServer Release/package verification. Record exact commands and outputs for
the final response.

- [ ] **Step 4: Merge and push**

Merge `codex/claude-profile-registry` into local `main` without discarding the
backlog-drainer commits, verify `main` is clean, and push `main` to `origin`.

- [ ] **Step 5: Install and restart the native app**

Use repository release scripts to export/verify the Release bundle, atomically
replace `/Applications/Engram.app`, terminate stale app/service processes, launch
the installed app, and verify `CFBundleVersion`, socket health, runtime telemetry,
and installed/exported binary hash parity.

- [ ] **Step 6: Deploy and restart HQ/M1 RemoteServer**

Use the approved package/deploy scripts and existing credential channels. Confirm
the same package manifest/hash on HQ and M1, restart both services, and verify
health plus bounded remote telemetry. Never print or persist credentials.

- [ ] **Step 7: End-to-end production verification**

Refresh profile status and confirm automatic discovery covers the expected
`~/.claude-*` roots. Verify at least one non-empty API-profile manifest reaches
both HQ and M1 verified receipts, one canonical empty file creates no remote
receipt, and no custom-root source is reclamation-eligible. Only then report the
deployment ready for user inspection.
