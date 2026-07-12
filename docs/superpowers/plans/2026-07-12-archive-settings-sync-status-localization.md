# Archive Settings Sync Status and Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show current Archive V2 dual-replica synchronization status in Settings and fully localize the Archive & Storage page in Simplified Chinese.

**Architecture:** Reuse `EngramServiceClient.archiveV2Status()` and its existing status DTO inside `ArchiveSettingsSection`. Render a compact, refresh-on-demand summary and convert all runtime messages to catalog-backed localized formats; no polling or service changes are introduced.

**Tech Stack:** Swift 6, SwiftUI, String Catalogs, XCTest, XcodeGen.

## Global Constraints

- Keep HQ and M1 as untranslated replica identifiers.
- Do not add polling, background work, service commands, schema changes, or dependencies.
- Do not change replication, recovery, reclamation, the enabled setting, or the 30-day hot window.
- A status read failure must not disable reclamation controls.
- Implement RED/GREEN before deployment.

---

### Task 1: Archive status card and complete localization

**Files:**
- Create: `macos/EngramTests/ArchiveSettingsSectionTests.swift`
- Modify: `macos/Engram/Views/Settings/ArchiveSettingsSection.swift`
- Modify: `macos/Engram/Resources/Localizable.xcstrings`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EngramServiceClient.archiveV2Status() async throws -> EngramServiceArchiveV2StatusResponse`.
- Produces: accessibility identifiers `archiveSync_status`, `archiveSync_progress`, `archiveSync_hq`, `archiveSync_m1`, `archiveSync_unbound`, and `archiveSync_refresh`.

- [ ] **Step 1: Write the failing source and catalog tests**

Create `ArchiveSettingsSectionTests` that reads the settings source and string
catalog from the repository. Assert the source contains `archiveV2Status()`, all
six accessibility identifiers, and no timer/polling primitive. Parse the JSON
catalog and assert every Archive settings key used by the view has a translated,
non-empty `zh-Hans.stringUnit.value`.

- [ ] **Step 2: Run RED**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme Engram \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -skip-testing:EngramUITests \
  -only-testing:EngramTests/ArchiveSettingsSectionTests
```

Expected: FAIL because the sync card identifiers and Archive-specific catalog
translations are absent.

- [ ] **Step 3: Implement the minimal UI and localization**

Add one optional Archive V2 status state, load it alongside reclamation status,
and render the approved summary. Use localized format keys for days, progress,
replica counts, preview/released bytes, drill results, and errors. Keep refresh
manual plus page/action refresh only.

- [ ] **Step 4: Run GREEN and focused regression tests**

Run the RED command again, then:

```bash
xcodebuild test -project Engram.xcodeproj -scheme Engram \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -skip-testing:EngramUITests \
  -only-testing:EngramTests/EngramCLIArchiveCommandTests \
  -only-testing:EngramTests/ArchiveSettingsSectionTests
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```

Expected: all selected tests and the Debug build pass.

- [ ] **Step 5: Build, deploy, and inspect the installed app**

```bash
cd macos
ENGRAM_BUILD_NUMBER=$(date -u +%Y%m%d%H%M%S) ./scripts/build-release.sh --local-only
./scripts/deploy-local.sh ./build/EngramExport/Engram.app
open -a /Applications/Engram.app
/Applications/Engram.app/Contents/Helpers/EngramCLI archive status --json
```

Inspect the Chinese Archive & Storage page and confirm the displayed dual-copy,
HQ, M1, and unbound counts match the installed CLI output. Confirm the existing
30-day enabled reclamation setting remains unchanged.
