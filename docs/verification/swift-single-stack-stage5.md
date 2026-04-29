# Swift Single Stack Stage 5 Verification

Date: 2026-04-24

## Gate Status

Stage 5 is partially closed, not fully complete. The remaining app-side SQLite writer, Node app packaging, service-internal compatibility bridge, and Swift 6 warning surfaces found in the App scheme build were closed, but the repository still retains TypeScript `src/**` and Node fixture tooling as development/reference material.

Closed:

- App `DatabaseManager` is read-only. Favorites, rename, hide/unhide, and empty-session cleanup now go through typed `EngramServiceClient` commands.
- `ServiceWriterGate` owns App session metadata mutation commands: `setFavorite`, `renameSession`, `setSessionHidden`, and `hideEmptySessions`.
- `ServiceWriterGate` also owns `saveInsight` and `manageProjectAlias`; both now write native Swift/GRDB tables without invoking the Node compatibility bridge.
- `LegacyDaemonBridge` is deleted. Former bridge commands now either run in Swift service code (`hygiene`, `handoff`, `generateSummary`, `regenerateAllTitles`, `triggerSync`) or fail closed with `UnsupportedNativeCommand` and `retry_policy = never` (`projectMove`, `projectArchive`, `projectUndo`, `projectMoveBatch`).
- Swift MCP and App UI no longer expose project move/archive/undo/batch entrypoints. Direct MCP calls return an explicit unavailable error until the native Swift project migration pipeline is ported.
- XcodeGen no longer emits the `Bundle Node.js Daemon` phase.
- `macos/scripts/build-node-bundle.sh` is deleted.
- Root `package.json` and `package-lock.json` no longer expose `dist/index.js` or `dist/cli/index.js` as shipped `main`/`bin` entrypoints.
- The freshly built `.app` contains no `Contents/Resources/node`, `node_modules`, `dist`, `daemon.js`, `index.js`, or `web.js`.

Still intentionally retained:

- Project move/archive/undo/batch execution is not reimplemented in Swift yet; the service rejects these commands explicitly instead of forwarding to a daemon bridge.
- TypeScript `src/**` and fixture scripts remain dev/reference material only; they are not copied into the macOS app bundle.
- A clean checkout still needs npm for fixture/schema parity checks in CI; full Stage 5 requires deleting or archiving Node source/runtime scripts rather than retaining them as active development tools.

## Recorded Verification

- `cd macos && xcodegen generate`
  - Result: generated `Engram.xcodeproj` successfully.
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage5-app-build`
  - Result: `BUILD SUCCEEDED`.
  - Filtered build log shows no `error:`, no project Swift warnings, no `Bundle Node`, no `node-bundle`, no `build-node`, and no `Multiple commands produce`.
  - Only retained warnings are Xcode AppIntents metadata extraction warnings: `No AppIntents.framework dependency found`.
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage5-app-tests -only-testing:EngramTests/DatabaseManagerTests`
  - Result: `TEST SUCCEEDED`.
  - `DatabaseManagerTests`: `35 tests, 0 failures`.
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramServiceCore test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage5-service-tests -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testAppSessionMetadataMutationsAreOwnedByServiceWriterGate -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testInsightAndProjectAliasMutationsAreOwnedByServiceWriterGate`
  - Result: `TEST SUCCEEDED`.
  - `EngramServiceIPCTests`: `2 tests, 0 failures`.
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramServiceCore test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage5-service-full`
  - Result: `TEST SUCCEEDED`.
  - `EngramServiceCoreTests`: `17 tests, 0 failures`.
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramServiceCore test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage5-no-bridge-green -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testFormerBridgeCommandsUseNativeServiceBehavior -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testProjectMigrationCommandsFailClosedWithoutLegacyBridge`
  - Result: `TEST SUCCEEDED`.
  - `EngramServiceIPCTests`: `2 tests, 0 failures`.
- `scripts/check-app-mcp-cli-direct-writes.sh`
  - Result: pass.
  - No legacy App DB writer allowlist remains.
  - Allowed hits are read-only DB open/query paths only.
- `rg -n "build-node-bundle|node-bundle\\.stamp|Bundle Node\\.js Daemon|Resources/node|npm run build|dist/index\\.js|dist/cli/index\\.js" macos/project.yml macos/Engram.xcodeproj package.json macos/scripts`
  - Result: no output.
- `find /tmp/engram-dd-stage5-app-build/Build/Products/Debug/Engram.app/Contents -path '*Resources/node*' -o -name 'node_modules' -o -name 'daemon.js' -o -name 'index.js' -o -name 'web.js' -o -name 'dist'`
  - Result: no output.
- `rg -n 'dist/index\\.js|dist/cli/index\\.js|"main": "dist|"engram": "dist' package.json package-lock.json`
  - Result: no output.
- `rg -n "LegacyDaemonBridge|bridge\\." macos/EngramService macos/Shared/Service`
  - Result: no output.

## Code Changes Covered

- Added service DTOs/client commands/mocks for App session metadata mutations.
- Added native service writer-gated implementations for favorites, hidden state, custom name, and empty-session cleanup.
- Added native service writer-gated implementations for text insight writes and project alias add/remove.
- Removed the service-internal Node daemon compatibility bridge and covered former bridge commands with native Swift IPC tests.
- Migrated `SessionListView` and `SessionDetailView` write actions from `DatabaseManager` to `EngramServiceClient`.
- Converted `DatabaseManager.open()` to a read-only `DatabasePool` and removed app-local writer methods.
- Updated tests to seed service-owned metadata directly and assert read-model behavior.
- Removed active Node packaging from `macos/project.yml`, regenerated the Xcode project, deleted the Node bundle script, and removed npm package runtime entrypoints.
- Fixed Swift 6 actor-isolation warnings in timeline/search/popover/replay/service runner/read-provider code paths.
