# MACOS KNOWLEDGE BASE

## OVERVIEW
`macos/` contains the shipped Swift product runtime: menu bar app, service
helper, native MCP helper, GRDB read/write cores, shared adapters, and Swift
test targets.

## STRUCTURE
```
- Engram/                # SwiftUI app, app models, app read facades, UI
- EngramService/         # helper executable plus service core and IPC
- EngramMCP/             # native stdio MCP helper and tool registry
- EngramCoreRead/        # read repositories/facades
- EngramCoreWrite/       # migrations, writer, indexing, project moves
- Shared/                # shared adapters, service DTOs, MCP models
- Engram*Tests/          # unit, service, MCP, and UI test targets
- scripts/               # helper copy/release/boundary scripts
- project.yml            # XcodeGen source of truth
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| App startup | `Engram/App.swift` | `EngramApp`, `AppDelegate`, service launch, app lifecycle. |
| App service process launch | `Engram/Core/EngramServiceLauncher.swift` | Locates helper and monitors health. |
| UI read models | `Engram/Core/Database.swift`, `Engram/Views/**` | App-facing reads should stay off the main thread. |
| Service command path | `EngramService/Core/EngramServiceCommandHandler*.swift` | Command dispatch, project operations, native behavior. |
| MCP routing | `EngramMCP/Core/MCPToolRegistry.swift` | Tool schemas and handler switch. |
| Product schema/indexing | `EngramCoreWrite/Database/`, `EngramCoreWrite/Indexing/` | GRDB writer, migrations, indexer/backfills. |
| Shared adapters | `Shared/EngramCore/Adapters/` | Product parser source of truth. |
| Service DTOs | `Shared/Service/EngramServiceModels.swift` | App/MCP/service contract surface. |

## CONVENTIONS
- `project.yml` owns targets, signing, version metadata, helper copy scripts, and package dependencies.
- Run `xcodegen generate` after adding/removing Swift files; never hand-edit generated project files.
- Swift settings are macOS 14.0, Xcode 16.0, Swift 5.9.
- The app embeds `EngramMCP` and `EngramService` as helper products via postbuild scripts.
- `EngramCoreRead` and `Shared/EngramCore` are shared into multiple targets; check blast radius before changing public models.
- App/MCP writes must cross the service boundary. Reads use GRDB read repositories or service DTOs, not ad hoc SQLite access.
- UI tests use accessibility identifiers and helpers under `EngramUITests/Helpers`; avoid layout rewrites for test-only visibility unless the product behavior requires it.

## ANTI-PATTERNS
- Do not use `macos/build/` as evidence. It is stale local output.
- Do not add Node runtime files to product bundles.
- Do not add SwiftPM root assumptions; dependencies are declared in `project.yml` and resolved through the generated Xcode workspace.
- Do not use `hashValue` for cache keys or SwiftUI identity.

## COMMANDS
```bash
cd macos
xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skip-testing:EngramUITests
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
