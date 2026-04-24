# Swift Single Stack Stage 4 Verification

Date: 2026-04-24

## Gate Status

The Stage 4 service writer-gate blocker is closed for service-owned MCP/app mutation paths verified in this document.
App-side legacy `index.sqlite` writers remain explicit Stage 5 debt and are still allowlisted by the boundary scan.

Stage 5 follow-up has since removed the app-side DB writer allowlist and Node app bundle phase. Current closure evidence is recorded in `docs/verification/swift-single-stack-stage5.md`.

Recorded passing command:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramServiceCore test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage4-servicecore
```

Recorded result:

- `EngramServiceIPCTests.testTwoClientsSerializeWriteIntentThroughOneServiceGate` passed.
- `EngramServiceIPCTests.testSQLiteProviderServesProjectReadsAndSuggestionMutations` passed.
- Full `EngramServiceCoreTests` suite passed with `9 tests, 0 failures`.

## Verified This Pass

- `cd macos && xcodegen generate`
  - Result: regenerated `Engram.xcodeproj` successfully.
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage4-engramtests -only-testing:EngramTests/EngramServiceClientTests`
  - Result: `TEST SUCCEEDED`
  - `EngramServiceClientTests`: `7 tests, 0 failures`.
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage4-appbuild`
  - Result: `BUILD SUCCEEDED`
- `./scripts/check-stage3-daemon-cutover.sh`
  - Result: pass
  - App UI targets no longer show direct daemon HTTP hits for sync trigger, title regeneration, or project move/archive/undo sheets.
  - This check only proves those call sites are gone outside the script's allowlists; it does not prove retained service bridge hops are deleted.
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramServiceCore test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-service-export-fixes -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testExportSessionWritesThroughServiceCommand -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testExportSessionUsesRequestedHomeInsteadOfServiceHome -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testExportSessionRejectsInvalidFormat -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testExportSessionSupportsCopilotSource`
  - Result: `TEST SUCCEEDED`
  - `EngramServiceIPCTests`: `4 tests, 0 failures`.
  - `exportSession` writes `~/codex-exports` from the Swift service command path, honors caller-provided home, rejects unsupported formats, and covers a non-Codex source fixture.
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCP test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage5-export-mcp -only-testing:EngramMCPTests/EngramMCPExecutableTests/testExportMatchesGolden -only-testing:EngramMCPTests/EngramMCPExecutableTests/testLinkSessionsMatchesGolden -only-testing:EngramMCPTests/ServiceUnavailableMutatingToolTests/testExportFailsClosedWithoutServiceSocket -only-testing:EngramMCPTests/ServiceUnavailableMutatingToolTests/testLinkSessionsFailsClosedWithoutServiceSocket`
  - Result: `TEST SUCCEEDED`
  - `EngramMCPTests`: `4 tests, 0 failures`.
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCP test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage4-mcp-failclosed -only-testing:EngramMCPTests/ServiceUnavailableMutatingToolTests`
  - Result: `TEST SUCCEEDED`
  - `ServiceUnavailableMutatingToolTests`: `9 tests, 0 failures`.
  - Coverage: all service-unavailable mutating-tool tests, including `generate_summary`, `export`, `save_insight`, `project_archive`, `project_undo`, `project_move_batch`, `project_move` dry-run, and `link_sessions`.
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCP test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage5-export-mcp2 -only-testing:EngramMCPTests/EngramMCPExecutableTests/testExportMatchesGolden -only-testing:EngramMCPTests/ServiceUnavailableMutatingToolTests/testExportFailsClosedWithoutServiceSocket`
  - Result: `TEST SUCCEEDED`
  - `EngramMCPTests`: `2 tests, 0 failures`.
  - Confirms the added service request `output_home` field does not change the MCP stdio golden result and remains fail-closed without the service socket.
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage5-export-appbuild2`
  - Result: `BUILD SUCCEEDED`
  - Confirms the regenerated project links `Engram`, `EngramMCP`, and `EngramService` without the previous GRDB duplicate-framework failure.
  - The build still runs `Bundle Node.js Daemon`; this remains explicit Stage 5 compatibility debt.

## App Cutover Completed

- Session suggestion confirm/dismiss routes through `EngramServiceClient`.
- Resume command already routes through `EngramServiceClient`.
- Project migration list and project cwd lookup route through `EngramServiceClient`.
- Project rename/archive/undo sheets now call `EngramServiceClient` instead of `DaemonClient`.
- Settings actions now call `EngramServiceClient` instead of raw daemon HTTP:
  - `NetworkSettingsSection.swift` uses `triggerSync(_:)`
  - `AISettingsSection.swift` uses `regenerateAllTitles()`
- Service-side compatibility bridge now owns the remaining legacy daemon hop for:
  - summary generation
  - hygiene
  - handoff
  - sync trigger
  - bulk title regeneration
  - save insight
  - project alias add/remove
  - project move/archive/undo
  - project move batch

## 2026-04-24 Follow-up

- MCP mutation and operational routes now cross `EngramServiceClient` before any retained bridge hop for:
  - `generate_summary`
  - `export`
  - `save_insight`
  - `manage_project_alias` add/remove
  - `link_sessions`
  - `project_move`
  - `project_archive`
  - `project_undo`
  - `project_move_batch`
- `export` now has a native Swift service implementation for the actual file write to `~/codex-exports`; MCP no longer writes the export file in-process.
- MCP negative-path coverage now asserts fail-closed behavior when the service socket is unavailable for:
  - `generate_summary`
  - `export`
  - `save_insight`
  - `save_insight` with a non-Engram socket
  - `project_archive`
  - `project_undo`
  - `project_move_batch`
  - `project_move` dry-run
  - `link_sessions`
- CLI replacement/deprecation inventory is recorded in `docs/swift-single-stack/cli-replacement-table.md`.
  - Current Swift `EngramCLI` is only a compatibility stdio bridge.
  - Native Swift ArgumentParser CLI replacement remains Stage 5 work unless explicitly descoped.

## Stage 5 Compatibility Debt

- `LegacyDaemonBridge` is deleted. Remaining service commands either use native Swift implementations or fail closed for unsupported project migration execution.
- `DaemonClient` and `DaemonHTTPClientCore` are deleted from production targets. `EngramLogger` remains only as an OSLog utility and no longer forwards to `/api/log`.
- App `DatabaseManager` is read-only. Favorites, hide/unhide, rename, summary persistence, and empty-session cleanup route through typed service commands.
- Project move/archive/undo/batch execution remains intentionally unavailable in the Swift runtime until the native migration pipeline is ported.
- `macos/EngramCLI/main.swift` remains a compatibility stdio surface.
- TypeScript `src/**`, fixture tooling, and schema compatibility scripts remain development/reference material. They are not bundled into the default macOS app runtime.

## Remaining Stage 5 Work

- Port native Swift project migration execution for:
  - `projectMove`
  - `projectArchive`
  - `projectUndo`
  - `projectMoveBatch`
- Keep `exportSession` native in service and extend it only if adapter parity gaps appear.
- Replace current `EngramCLI` bridge with a real Swift CLI or delete it after MCP clients use `EngramMCP` directly.
- Delete or archive retained TypeScript development/reference surfaces after fixture/schema parity and CLI replacement no longer depend on them.
