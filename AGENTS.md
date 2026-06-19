# PROJECT KNOWLEDGE BASE

**Generated:** 2026-06-19
**Commit:** 9df601ec
**Branch:** main

## OVERVIEW
Engram is a cross-tool AI session aggregator. The shipped product runtime is
the native Swift macOS app, `EngramService`, and `EngramMCP`; TypeScript under
`src/` is retained for dev/reference tooling, fixture generation, historical
entrypoints, and regression tests.

## STRUCTURE
```
- macos/      # Swift product runtime, XcodeGen project, app/service/MCP/tests
- src/        # TypeScript dev/reference logic, retained CLIs, fixture support
- tests/      # Vitest tests, generated fixtures, parity/golden data
- scripts/    # fixture, screenshot, release, and boundary tooling
- docs/       # canonical backlog, reviews, plans, and archived history
- .github/    # CI, release, CodeQL, and Copilot repo rules
```

Ignore source-of-truth drift from `dist/`, `coverage/`, `node_modules/`,
`.codegraph/`, `macos/build/`, `.worktrees/`, `.claude/worktrees/`,
`docs/archive/`, `docs/superpowers/reports/`, `tests/fixtures/`, and
`test-fixtures/`. They are generated, cached, archived, fixture-only, or
historical surfaces.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Swift app startup/UI | `macos/Engram/` | `App.swift` owns `EngramApp` and `AppDelegate`; UI reads through service/read facades. |
| Swift service runtime | `macos/EngramService/` | Startup, IPC command handling, writer gate, indexing loop, and native web UI. |
| Swift MCP runtime | `macos/EngramMCP/` | Native stdio helper; tool routing lives in `Core/MCPToolRegistry.swift`. |
| Product writes/schema/indexing | `macos/EngramCoreWrite/` | GRDB writer, migrations, indexing, startup backfills, project migration. |
| Product reads | `macos/EngramCoreRead/` | GRDB read repositories/facades used by app and service surfaces. |
| Product adapters | `macos/Shared/EngramCore/Adapters/` | Swift-first parser source of truth for shipped behavior. |
| Service DTO/client contracts | `macos/Shared/Service/` | App/MCP service transport models and mocks. |
| TS retained tooling | `src/` | Reference/dev logic only unless a fixture or regression path still depends on it. |
| Test and fixture policy | `tests/` | Vitest, Swift fixture resources, MCP golden contracts, parity data. |

## CODE MAP
| Symbol | Type | Location | Refs | Role |
|--------|------|----------|------|------|
| `EngramApp` / `AppDelegate` | Swift app | `macos/Engram/App.swift` | entry | App startup, service launch, menu/window/onboarding routing. |
| `EngramServiceRunner.run` | Swift service | `macos/EngramService/Core/EngramServiceRunner.swift` | entry | Service startup, indexing loop, web readiness, usage events. |
| `MCPToolRegistry.handle` | Swift MCP | `macos/EngramMCP/Core/MCPToolRegistry.swift` | entry | Native MCP tool schema and command router. |
| `ServiceWriterGate` | Swift class | `macos/EngramService/Core/ServiceWriterGate.swift` | 12 callers | Serializes service-owned write traffic. |
| `EngramDatabaseWriter` | Swift class | `macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift` | 4 callers | Product write pool, migrations, indexing write path. |
| `SessionAdapterFactory.defaultAdapters` | Swift function | `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift` | 5 callers | Registers the 17 shipped source adapters. |
| `EngramServiceReadProvider.search` | Swift method | `macos/EngramService/Core/EngramServiceReadProvider.swift` | service/API | Product keyword search with unsupported semantic-mode downgrade. |
| `ProjectMoveOrchestrator` | Swift/TS domain | `macos/EngramCoreWrite/ProjectMove/`, `src/core/project-move/` | central | Transactional project move/archive/undo/batch logic. |
| `Session` | Swift model | `macos/Engram/Models/Session.swift` | 40 callers | App-facing session model used across UI and tests. |

## CONVENTIONS
- Swift product behavior is authoritative. `src/index.ts`, `src/daemon.ts`, and `src/web.ts` are historical/dev/reference entrypoints, not shipped runtime.
- App and MCP write paths go through `EngramServiceClient` / `ServiceWriterGate`; do not add direct SQLite writers in app or MCP code.
- Swift product search is keyword-only through FTS5/LIKE. Semantic/hybrid/vector search in TypeScript is reference design only.
- Product adapters are Swift-first. Update TypeScript adapters only when retained fixture tooling or regression coverage requires it.
- Parser output changes need fixture/parity coverage updates before or with adapter logic changes.
- Subagent/dispatch/noise sessions stay `skip`; parent-link operations must not upgrade child sessions out of `skip`.
- Swift `DatabaseManager` read methods must be `nonisolated` and use `readInBackground`; views follow existing detached-task patterns.
- Cache and identity keys must use stable values, not `hashValue`.
- Current backlog lives in `docs/roadmap.md`, `docs/TODO.md`, and `docs/followups.md`; archive historical plans under `docs/archive/`.

## ANTI-PATTERNS
- Do not edit `macos/Engram.xcodeproj` directly. Edit `macos/project.yml`, then run `xcodegen generate`.
- Do not rely on `macos/build/`; use `~/Library/Developer/Xcode/DerivedData/Engram-*` for real build products.
- Do not add product startup paths that shell out to `node`/`npm` or copy `dist` / `node_modules` into the app bundle.
- Do not reintroduce Node schema-compatibility or Node bundle checks as active Swift-only gates.
- Do not commit `.sqlite`, `node_modules/`, or `dist/`.
- Do not assume a root `Makefile` or root `Package.swift`; neither is the project entrypoint.

## COMMANDS
```bash
npm ci
npm run build
npm run lint
npm run knip
npm run typecheck:test
npm run test:coverage
npm run generate:fixtures
npm run check:adapter-parity-fixtures
npm run check:fixtures
npm run screenshots:compare

cd macos
xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skip-testing:EngramUITests
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## NOTES
- Node tooling expects Node 24 (`package.json` allows `>=24 <27`; CI uses Node 24).
- Biome covers `src/**`, `tests/**`, and `scripts/**`, with generated fixture directories excluded by config.
- `lint-staged` runs `biome check --write --no-errors-on-unmatched` on staged TS/JS files.
- Release verification rejects app bundles containing `node`, `node_modules`, `dist`, `daemon.js`, `index.js`, or `web.js`.
- `CLAUDE.md` contains the longer architecture notes; this file is the concise routing surface for Codex-style agents.
