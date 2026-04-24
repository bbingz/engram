# Swift Single Stack Cutover Verification Implementation Plan Draft

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the packaging/docs cutover and final Node deletion only after Swift service/MCP parity, performance, and clean-checkout gates prove Engram ships as a Swift-only macOS app.

**Architecture:** Treat this as the final verification and deletion unit, not a porting unit. First add automated parity/performance/packaging checks that still run while Node exists as the reference, then remove Node runtime packaging and docs, then delete Node source/runtime paths after the checks prove Swift owns the product behavior.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, XcodeGen, Xcode build/archive tooling, shell verification scripts, TypeScript/Node only as pre-deletion reference fixture tooling.

---

## Scope and Preconditions

This draft covers implementation planning unit 12, "Packaging/docs cutover", and unit 13, "Node deletion", from `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`.

Do not start this plan until prior units have landed and these facts are already true:

- `macos/EngramMCP` is the only supported MCP server implementation.
- `EngramServiceClient` exists and replaces all runtime uses of `DaemonClient`.
- Swift service owns indexing, watching, maintenance, AI summaries, embeddings/vector rebuild behavior, project move/archive/undo/recover, session linking, insights, export, stats, costs, memory, timeline, lint config, live sessions, and hygiene operations.
- Swift MCP mutating tools route through the shared service IPC endpoint and fail closed when the service is unavailable.
- Stage 0 canonical Node performance baseline was already captured and checked in as a versioned artifact.
- Stage 4 dual-run parity is green against the standard fixture corpus.

If any precondition is false, stop this cutover plan and return to the earlier migration unit. This plan intentionally does not describe porting missing behavior from Node.

## Current References Observed

- `README.md` still requires `Node.js >= 20`, `npm install && npm run build`, `node /absolute/path/to/engram/dist/index.js`, and `node dist/daemon.js`.
- `CLAUDE.md` still describes TypeScript as the primary runtime, `src/index.ts`, `src/daemon.ts`, `macos/scripts/build-node-bundle.sh`, `Resources/node`, `dist/`, and `node_modules`.
- `package.json` still points `main` to `dist/index.js`, `bin.engram` to `dist/cli/index.js`, declares `engines.node`, and carries runtime Node dependencies.
- `macos/project.yml` is the source of truth for Xcode project generation and still defines the `Bundle Node.js Daemon` prebuild script using `macos/scripts/build-node-bundle.sh`.
- `macos/Engram.xcodeproj/project.pbxproj` is generated but currently contains the same Node build phase and should be regenerated, not manually edited.
- `macos/scripts/build-node-bundle.sh` runs `npm run build` and copies `dist/` plus `node_modules` into `Contents/Resources/node`.
- `macos/Engram/App.swift` still starts the app-local `MCPServer`/`MCPTools` bridge and launches `daemon.js` from `Resources/node`.
- `macos/Engram/Core/IndexerProcess.swift` still launches `node`, kills orphaned `node.*daemon.js`, parses Node daemon stdout events, and auto-restarts the process.
- `macos/Engram/Views/Settings/GeneralSettingsSection.swift` and `macos/Engram/Views/Settings/SourcesSettingsSection.swift` still expose Node.js path and `~/.engram/dist/index.js` MCP setup guidance.
- `tests/fixtures/mcp-golden` and `scripts/gen-mcp-contract-fixtures.ts` currently use Node as the golden generator and read `src/index.ts` for tool names and initialize instructions.
- `biome.json` only includes `src/**`, `tests/**`, and `scripts/*.ts`; after Stage 5 it must not be a shipped-product gate unless TypeScript reference tooling is intentionally retained outside app/runtime.
- `macos/build/` contains stale archive/build outputs; final verification must inspect fresh DerivedData and archive/export outputs, not trust this directory.

## File Map

### Create

- `scripts/verify-swift-only-cutover.sh` - one command for grep gates, Xcode build-setting inspection, app bundle inspection, and docs checks.
- `scripts/measure-swift-cutover-performance.sh` - records Stage 5 performance metrics and compares them to the checked-in Stage 0 baseline.
- `scripts/run-mcp-dual-parity.sh` - final pre-deletion Node-vs-Swift MCP parity harness against `tests/fixtures/mcp-contract.sqlite` and `tests/fixtures/mcp-golden`.
- `scripts/run-service-dual-parity.sh` - final pre-deletion Node-daemon-vs-Swift-service indexing/event/database checksum parity harness.
- `scripts/verify-clean-checkout-no-npm.sh` - clones/checks out the current branch into a temporary directory, skips `npm install`, and proves Swift app/MCP build and smoke tests work from scratch.
- `docs/performance/swift-single-stack-stage5.json` - Stage 5 performance results produced by the measurement script.
- `docs/verification/swift-single-stack-cutover.md` - human-readable final cutover report with command output summaries, app bundle path, and known intentional exceptions.

## Required Execution Order

Stage 5 must execute in this order:

- Freeze Node reference artifacts and baseline metadata.
- Add verification, dual-parity, and performance scripts before deleting anything.
- Run MCP dual parity, service dual parity, performance comparison, and `verify-clean-checkout-no-npm.sh`.
- Create a deletion checkpoint branch or commit marker after those gates pass.
- Remove Node packaging and app bridge references through `macos/project.yml` and production Swift sources.
- Convert, archive, or explicitly label any retained TypeScript fixture tooling as non-shipped.
- Delete Node runtime source in small dependency-ordered groups.
- After each deletion group, rerun `scripts/verify-swift-only-cutover.sh` and the relevant Swift build/tests.
- Run final clean-checkout and app-bundle verification.

### Modify

- `README.md` - replace Node install/build/MCP examples with Swift app/helper setup and clean-checkout macOS build instructions.
- `CLAUDE.md` - update architecture, quick reference, build output, and "What NOT To Do" for Swift-only runtime.
- `package.json` - either remove runtime package metadata entirely with Node source deletion or narrow it to non-shipped reference tooling if a later task keeps any TypeScript fixture utilities.
- `package-lock.json` - remove if no TypeScript tooling remains; otherwise update to match the narrowed dev-only package metadata.
- `biome.json` - remove if no TypeScript tooling remains; otherwise narrow to retained non-runtime tooling only.
- `macos/project.yml` - remove the `Bundle Node.js Daemon` prebuild script, remove `EngramCLI` from the main scheme unless a Swift CLI target is intentionally kept, and keep `EngramMCP` as the only MCP helper dependency.
- `macos/Engram.xcodeproj/project.pbxproj` - regenerate with `xcodegen generate`; do not edit directly.
- `macos/Engram.xcodeproj/xcshareddata/xcschemes/Engram.xcscheme` - regenerate from `macos/project.yml`; verify it no longer builds `EngramCLI` unless retained as a Swift CLI.
- `macos/Engram.xcodeproj/xcshareddata/xcschemes/EngramCLI.xcscheme` - delete through `project.yml` regeneration if `EngramCLI` is removed.
- `macos/Engram/Core/AppEnvironment.swift` - remove or rename Node/daemon-specific launch flags only after Swift service test launch flags replace them.
- `macos/Engram/App.swift` - remove app-local `MCPServer`/`MCPTools` startup and Node daemon startup; start/connect Swift service only.
- `macos/Engram/Core/IndexerProcess.swift` - delete after UI state has moved to Swift service state, or reduce to a compatibility type renamed away from process semantics before final deletion.
- `macos/Engram/Core/DaemonClient.swift` - delete after all users move to `EngramServiceClient`.
- `macos/Engram/Core/MCPServer.swift` - delete the old app-local HTTP MCP bridge.
- `macos/Engram/Core/MCPTools.swift` - delete the old app-local HTTP MCP tools.
- `macos/Engram/Views/Settings/GeneralSettingsSection.swift` - remove Node.js path and MCP HTTP endpoint settings; show Swift service status instead.
- `macos/Engram/Views/Settings/SourcesSettingsSection.swift` - replace Node script setup snippets with Swift stdio helper setup snippets.
- `macos/EngramTests/*Daemon*`, `macos/EngramTests/*IndexerProcess*`, and `macos/Engram/TestSupport/MockDaemonFixtures.swift` - delete or replace with Swift service client/status tests.
- `macos/EngramMCPTests/EngramMCPExecutableTests.swift` - keep and expand as the post-cutover MCP contract suite, no Node fallback assumptions.
- `tests/fixtures/mcp-golden/README.md` - document goldens as historical Node reference fixtures after Stage 5.
- `scripts/gen-mcp-contract-fixtures.ts` - archive/delete after final parity artifacts are checked in, or move to an explicit historical reference path that is not required for clean-checkout app builds.
- `macos/scripts/build-release.sh` - add Swift-only verification after archive/export and remove any implicit expectation that Node resources exist.

### Delete After Gates Pass

- `macos/scripts/build-node-bundle.sh`
- `src/index.ts`
- `src/daemon.ts`
- `src/web.ts`
- `src/core/**` modules that only exist for Node app/daemon/MCP runtime
- `src/tools/**` TypeScript MCP tool modules
- `src/adapters/**` TypeScript adapters after Swift adapter parity is complete
- `src/cli/**` only after Swift CLI replacement or documented CLI deprecation is complete
- `dist/` if present locally
- `node_modules/` if present locally
- Node-only tests whose behavior is covered by Swift tests or archived reference fixtures

Do not delete `macos/EngramMCP`. It is the single shipped MCP server.

## Task 1: Freeze Node Reference Artifacts Before Deletion

**Files:**

- Modify or confirm: `tests/fixtures/mcp-golden/README.md`
- Create: `docs/verification/swift-single-stack-cutover.md`
- Create: `scripts/run-mcp-dual-parity.sh`
- Create: `scripts/run-service-dual-parity.sh`

- [ ] Run the current MCP golden generator while Node still exists:

```bash
TZ=UTC npm run generate:mcp-contract-fixtures
```

Expected: `tests/fixtures/mcp-contract.sqlite` and all files under `tests/fixtures/mcp-golden/` are regenerated deterministically.

- [ ] Run the existing Swift MCP contract tests against the regenerated fixtures:

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: all `EngramMCPTests` pass and `testToolNameParityMatchesNodeAllTools` still proves current Swift tool names match Node before Node is deleted.

- [ ] Create `scripts/run-mcp-dual-parity.sh` to run Node MCP and Swift MCP against the same fixture DB before Stage 5 deletion. The script must:
  - set `TZ=UTC`;
  - set `ENGRAM_MCP_DB_PATH="$PWD/tests/fixtures/mcp-contract.sqlite"` for Swift MCP;
  - start the Node MCP reference from `dist/index.js` only after `npm run build`;
  - start the Swift MCP executable built by Xcode;
  - send identical JSON-RPC `initialize`, `tools/list`, and `tools/call` requests for every public tool represented in `tests/fixtures/mcp-golden`;
  - normalize allowed dynamic fields only: generated UUIDs, temp directories inside `tests/fixtures/mcp-runtime`, and fixed current-time overrides already used by tests;
  - write raw outputs to `tmp/mcp-dual-parity/node/` and `tmp/mcp-dual-parity/swift/`;
  - fail on any JSON shape, ordering, error flag, content text, or structured content difference not listed in the spec.

- [ ] Create `scripts/run-service-dual-parity.sh` to compare Node daemon and Swift service before deletion. The script must:
  - operate only on temporary fixture homes and fixture databases under `tmp/service-dual-parity/`;
  - ensure only one writer is active at a time;
  - run Node daemon indexing on the fixture corpus and snapshot row counts plus checksums;
  - run Swift service indexing on a fresh copy of the same fixture corpus and snapshot row counts plus checksums;
  - compare `sessions`, `messages`, `session_costs`, `session_tools`, `session_files`, `metrics`, `insights`, `project_aliases`, `parent_session_id`, `suggested_parent_id`, `agent_role`, and `tier`;
  - compare service event sequences for `ready`, indexing progress, usage payloads, summary generation, and maintenance events;
  - fail on checksum or event-count drift unless `docs/verification/swift-single-stack-cutover.md` lists a spec-approved intentional improvement.

- [ ] Update `tests/fixtures/mcp-golden/README.md` so it states:
  - these fixtures are the final historical Node reference for Stage 5;
  - after Node deletion they are not regenerated by default clean-checkout app builds;
  - fixture DB is `tests/fixtures/mcp-contract.sqlite`;
  - contract tests must never use `~/.engram/index.sqlite`.

- [ ] Update `docs/verification/swift-single-stack-cutover.md` with the Node reference artifact commit hash, generator command, and the exact fixture/golden paths retained after deletion.

## Task 2: Add Performance Gate Automation

**Files:**

- Create: `scripts/measure-swift-cutover-performance.sh`
- Create: `docs/performance/swift-single-stack-stage5.json`
- Read required baseline path from Stage 0: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`
- Modify: `docs/verification/swift-single-stack-cutover.md`

- [ ] Load the canonical Stage 0 Node baseline artifact at `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`. It must contain:
  - cold app launch to service-ready;
  - idle RSS with app open but not indexing;
  - initial indexing time on the standard fixture corpus;
  - incremental indexing latency after one new session file appears;
  - MCP `search` p50/p95 on `tests/fixtures/mcp-contract.sqlite`;
  - MCP `get_context` p50/p95 on `tests/fixtures/mcp-contract.sqlite`.

- [ ] Create `scripts/measure-swift-cutover-performance.sh`. It must:
  - use strict shell settings (`set -euo pipefail`) and exit non-zero if any required threshold is exceeded;
  - refuse to run if the baseline JSON is missing or lacks any canonical schema key;
  - build a fresh Debug or Release app from `macos/Engram.xcodeproj`;
  - launch the app with fixture-only arguments and a temporary `ENGRAM_HOME`;
  - wait for Swift service-ready using the Swift service event stream or app test hook, not Node stdout;
  - measure idle RSS with `ps -o rss= -p <pid>` after the app is ready and not indexing;
  - run fixture initial indexing and record wall-clock milliseconds;
  - append one new fixture session file and record time to committed index visibility;
  - run at least 30 calls each for Swift MCP `search` and `get_context` against `tests/fixtures/mcp-contract.sqlite`;
  - calculate p50 and p95 latencies;
  - write `docs/performance/swift-single-stack-stage5.json`.

- [ ] Encode the blocking thresholds in the script:
  - cold launch to service-ready must be `<= baseline * 1.20`;
  - idle RSS must be `<= baseline + 50 MB`;
  - initial indexing must be `<= baseline * 1.20`;
  - incremental indexing must be `<= baseline * 1.50`;
  - MCP `search` p50 and `get_context` p50 must be `<= baseline * 1.20`;
  - MCP `search` p95 and `get_context` p95 must be `<= baseline * 1.50`.

- [ ] Add the performance summary and threshold comparison to `docs/verification/swift-single-stack-cutover.md`.

- [ ] Run the performance script before deleting Node source:

```bash
scripts/measure-swift-cutover-performance.sh
```

Expected: exits 0 only when every threshold passes and writes `docs/performance/swift-single-stack-stage5.json`; any threshold failure blocks Node deletion.

## Task 3: Remove Xcode Node Packaging and Build Phase

**Files:**

- Modify: `macos/project.yml`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`
- Regenerate: `macos/Engram.xcodeproj/xcshareddata/xcschemes/Engram.xcscheme`
- Delete: `macos/scripts/build-node-bundle.sh`
- Modify: `macos/scripts/build-release.sh`
- Modify: `docs/verification/swift-single-stack-cutover.md`

- [ ] Precondition: Task 7 dual-parity runs, Task 2 performance comparison, and `scripts/verify-clean-checkout-no-npm.sh` have already passed against frozen Node artifacts. Do not remove packaging while Node is still needed to establish parity.

- [ ] In `macos/project.yml`, remove the `prebuildScripts` entry named `Bundle Node.js Daemon`.

- [ ] In `macos/project.yml`, remove the `EngramCLI` target and `EngramCLI` scheme only if prior units replaced or explicitly deprecated terminal workflows. If a Swift CLI is intentionally kept, rename/keep it as a Swift-only target and document that it is not the old HTTP bridge.

- [ ] Before removing `EngramCLI` or `src/cli/**`, add a command-by-command replacement/deprecation table to README, CLAUDE, and `docs/verification/swift-single-stack-cutover.md`.

- [ ] Keep the `Engram` target dependency on `EngramMCP` with `link: false` and `embed: false` unless the earlier service packaging unit chose a different helper-copy mechanism.

- [ ] Delete `macos/scripts/build-node-bundle.sh`.

- [ ] Update `macos/scripts/build-release.sh` so the release pipeline runs `scripts/verify-swift-only-cutover.sh` after archive/export and before notary/DMG instructions.

- [ ] Regenerate Xcode project files:

```bash
cd macos
xcodegen generate
```

Expected: `project.pbxproj` and shared schemes no longer contain `node-bundle.stamp` or `build-node-bundle.sh`.

- [ ] Verify generated project cleanup:

```bash
rg -n 'build-node-bundle|node-bundle\.stamp|Bundle Node\.js Daemon|Resources/node|node_modules|npm run build|dist/' macos/project.yml macos/Engram.xcodeproj
```

Expected: no matches.

## Task 4: Remove App Runtime Node Launch and Old App-Local MCP Bridge

**Files:**

- Modify: `macos/Engram/App.swift`
- Modify or delete: `macos/Engram/Core/IndexerProcess.swift`
- Delete: `macos/Engram/Core/MCPServer.swift`
- Delete: `macos/Engram/Core/MCPTools.swift`
- Delete: `macos/Engram/Core/DaemonClient.swift`
- Modify: `macos/Engram/Core/AppEnvironment.swift`
- Modify: `macos/Engram/MenuBarController.swift`
- Modify all SwiftUI files currently using `@Environment(IndexerProcess.self)` or `@Environment(DaemonClient.self)`
- Modify/delete tests: `macos/EngramTests/DaemonClientTests.swift`, `macos/EngramTests/DaemonHTTPClientCoreTests.swift`, `macos/EngramTests/IndexerProcessTests.swift`, `macos/Engram/TestSupport/MockDaemonFixtures.swift`

- [ ] Precondition: Task 7 dual-parity runs, Task 2 performance comparison, and `scripts/verify-clean-checkout-no-npm.sh` have already passed against frozen Node artifacts. Do not remove app Node launch while it is still needed as the parity reference.

- [ ] Replace `AppDelegate` stored properties so the app owns Swift service state and `EngramServiceClient`, not `IndexerProcess`, `DaemonClient`, or `MCPServer`.

- [ ] Remove this behavior from `App.swift`:
  - constructing `MCPTools(db:)`;
  - constructing and starting `MCPServer`;
  - resolving `nodejsPath`;
  - looking up `daemon.js` in `Bundle.main` under `node`;
  - calling `indexer.start(nodePath:scriptPath:)`;
  - calling `indexer.stop()` and `mcpServer?.stop()` at termination.

- [ ] Replace UI environment injection so settings, popover, main window, pages, and project sheets receive the Swift service status/client types introduced in earlier units.

- [ ] Delete or retire `IndexerProcess.swift` only after no Swift file references `DaemonEvent`, `IndexerProcess.Status`, `IndexerProcess.UsageItem`, or `start(nodePath:scriptPath:)`.

- [ ] Delete `DaemonClient.swift` only after no Swift file references `/api/*` Node daemon URLs or `DaemonClient.DaemonClientError`.

- [ ] Delete `MCPServer.swift` and `MCPTools.swift`. The shipped app must not run an app-local HTTP MCP bridge after `macos/EngramMCP` is the stdio server.

- [ ] Replace daemon/indexer tests with Swift service tests. Coverage must include:
  - service-ready status display;
  - total sessions and today parent session counts;
  - usage payload parsing/display;
  - service unavailable UI behavior;
  - project move/archive/undo UI calls through `EngramServiceClient`;
  - session linking/suggestion commands through `EngramServiceClient`.

- [ ] Run Swift compile check after this task:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: unit tests compile and pass without `IndexerProcess`, `DaemonClient`, `MCPServer`, or `MCPTools`.

## Task 5: Update Settings UI and MCP Config Guidance

**Files:**

- Modify: `macos/Engram/Views/Settings/GeneralSettingsSection.swift`
- Modify: `macos/Engram/Views/Settings/SourcesSettingsSection.swift`
- Modify tests/screenshots as needed under `macos/EngramUITests`
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] In `GeneralSettingsSection.swift`, remove `@AppStorage("nodejsPath")`, the "Node.js Path" text field, and the old "MCP HTTP endpoint" row.

- [ ] Replace the infrastructure settings with Swift service status and, if still user-configurable, Swift service IPC status. Do not mention Node, npm, `daemon.js`, `dist`, or `Resources/node`.

- [ ] In `SourcesSettingsSection.swift`, remove `nodejsPath`, `mcpScriptPath`, and snippets that pass `node` plus `~/.engram/dist/index.js`.

- [ ] Replace MCP client snippets with Swift stdio helper examples. Use the installed helper path chosen by the packaging unit, for example:
  - bundled helper: `/Applications/Engram.app/Contents/Helpers/EngramMCP`;
  - development helper: `macos/build/Debug/EngramMCP` or DerivedData path only in the development section.

- [ ] README MCP examples must use Swift helper command with no Node wrapper. Required examples:
  - Claude Code `claude mcp add --scope user engram /Applications/Engram.app/Contents/Helpers/EngramMCP`;
  - Codex TOML with `command = "/Applications/Engram.app/Contents/Helpers/EngramMCP"` and no `args`;
  - generic JSON with `"command": "/Applications/Engram.app/Contents/Helpers/EngramMCP"` and no Node args.

- [ ] README quick start must remove Node as a product prerequisite. It should describe installing/building the macOS app and configuring the Swift MCP helper.

- [ ] README Web UI section must no longer instruct `node dist/daemon.js`; describe the Swift service/app-owned UI path instead.

- [ ] README development section must make clear that clean app builds do not require `npm install`. If TypeScript historical fixture tooling is retained, isolate it under a "historical reference fixture maintenance" subsection and mark it as not needed for shipped app/runtime builds.

- [ ] `CLAUDE.md` must be updated from "TypeScript MCP server + macOS SwiftUI menu bar app" to Swift-only runtime architecture. Remove `src/index.ts`, `src/daemon.ts`, `macos/scripts/build-node-bundle.sh`, `Resources/node`, `dist`, and `node_modules` from runtime guidance.

- [ ] Run docs/settings grep check:

```bash
rg -n 'node dist/index\.js|dist/index\.js|dist/daemon\.js|node /absolute/path|Node\.js >=|npm install && npm run build|Resources/node|nodejsPath|mcpScriptPath|/usr/local/bin/node|~/.engram/dist/index\.js' README.md CLAUDE.md macos/Engram/Views/Settings
```

Expected: no matches.

## Task 6: Convert or Archive Node Fixture Tooling

**Files:**

- Modify/delete: `scripts/gen-mcp-contract-fixtures.ts`
- Modify/delete: `package.json`
- Modify/delete: `package-lock.json`
- Modify/delete: `biome.json`
- Modify: `tests/fixtures/mcp-golden/README.md`
- Modify: `docs/verification/swift-single-stack-cutover.md`

- [ ] Decide before deleting Node source whether `scripts/gen-mcp-contract-fixtures.ts` remains useful. It currently imports `src/adapters/codex.js`, `src/core/db.js`, and many `src/tools/*.js`, and reads `src/index.ts`; it cannot work after `src/` deletion without being archived with a frozen reference.

- [ ] Preferred final state: delete `scripts/gen-mcp-contract-fixtures.ts`, keep generated `tests/fixtures/mcp-contract.sqlite` and `tests/fixtures/mcp-golden/**`, and document them as historical goldens.

- [ ] Acceptable alternate final state: move Node reference tooling to an explicit archived path outside shipped app/runtime, for example `docs/reference/node-mcp-golden-generator/`, with its own README stating it is not used by clean-checkout app build/test. In that case, do not keep root `package.json` runtime fields pointing to `dist/index.js`.

- [ ] If no TypeScript scripts remain, delete root `package.json`, `package-lock.json`, and `biome.json`.

- [ ] If TypeScript scripts remain only for non-runtime maintenance, narrow `package.json`:
  - remove `main`;
  - remove `bin`;
  - remove `engines.node` if there is no root Node workflow;
  - remove runtime dependencies such as `@hono/node-server`, `hono`, `@modelcontextprotocol/sdk`, `better-sqlite3`, `chokidar`, `sqlite-vec`, and `openai` unless an archived script explicitly needs them;
  - remove scripts that build or run shipped runtime entries, including `build`, `dev`, and any `dist/*` targets.

- [ ] Update `biome.json` only for retained TypeScript maintenance files. It must not require `src/**` after `src/` deletion.

- [ ] Run:

```bash
rg -n 'src/index\.ts|src/daemon\.ts|src/web\.ts|dist/index\.js|dist/cli/index\.js|"main": "dist|node_modules|Resources/node|node dist/index\.js' package.json package-lock.json biome.json scripts tests/fixtures/mcp-golden README.md CLAUDE.md 2>/dev/null
```

Expected: no matches except intentional historical fixture text in `tests/fixtures/mcp-golden/README.md` and `docs/verification/swift-single-stack-cutover.md`.

## Task 7: Run Dual-Run Parity and Performance Gates Before Deletion

**Files:**

- Modify: `docs/verification/swift-single-stack-cutover.md`
- Modify: `docs/performance/swift-single-stack-stage5.json`

- [ ] Build Node reference while Node still exists:

```bash
npm run build
```

Expected: `dist/index.js` and `dist/daemon.js` exist for the parity harness only.

- [ ] Run TypeScript reference tests one final time:

```bash
npm test
npm run lint
```

Expected: pass before deletion. After Stage 5 these commands are not required unless retained maintenance tooling explicitly remains.

- [ ] Run Swift MCP tests:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: pass.

- [ ] Run app/service Swift tests:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: pass.

- [ ] Run dual MCP parity:

```bash
scripts/run-mcp-dual-parity.sh
```

Expected: pass with raw output saved under `tmp/mcp-dual-parity/`.

- [ ] Run dual service parity:

```bash
scripts/run-service-dual-parity.sh
```

Expected: pass with row checksums and event comparisons saved under `tmp/service-dual-parity/`.

- [ ] Run performance gate:

```bash
scripts/measure-swift-cutover-performance.sh
```

Expected: pass and update `docs/performance/swift-single-stack-stage5.json`.

- [ ] Append the exact command results, output artifact paths, and checked thresholds to `docs/verification/swift-single-stack-cutover.md`.

Do not delete Node source until every step in this task is green.

## Task 8: Final Stage 5 Node Runtime Deletion

**Files:**

- Delete: `src/index.ts`
- Delete: `src/daemon.ts`
- Delete: `src/web.ts`
- Delete: TypeScript runtime-only modules under `src/core/**`
- Delete: TypeScript MCP tool modules under `src/tools/**`
- Delete: TypeScript adapters under `src/adapters/**`
- Delete: `src/cli/**` after Swift CLI replacement or documented CLI deprecation is complete
- Delete or narrow: Node-only tests under `tests/**`
- Modify/delete: `package.json`, `package-lock.json`, `biome.json`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/verification/swift-single-stack-cutover.md`

- [ ] Precondition: `scripts/verify-swift-only-cutover.sh`, `scripts/run-mcp-dual-parity.sh`, `scripts/run-service-dual-parity.sh`, `scripts/measure-swift-cutover-performance.sh`, and `scripts/verify-clean-checkout-no-npm.sh` already exist, and the parity/performance/clean-checkout gates pass against frozen Node artifacts. Performance means the script exits non-zero for threshold failures; recording a failure in the verification doc is not sufficient to proceed.
- [ ] Create a deletion checkpoint branch or commit marker before removing Node files; rollback during this task is a git revert to the checkpoint.

- [ ] Delete Node stdio MCP server entry `src/index.ts`.

- [ ] Delete Node daemon entry `src/daemon.ts`.

- [ ] Delete Node web/HTTP daemon entry `src/web.ts`.

- [ ] Delete TypeScript runtime modules that only supported app/daemon/MCP backend behavior after Swift replacements and historical fixtures are committed.

- [ ] Delete TypeScript MCP tool modules after Swift MCP contract tests cover every public tool.

- [ ] Delete TypeScript adapters after Swift adapter/indexing parity tests cover every supported source.

- [ ] Delete `src/cli/**` only if terminal workflows are replaced by Swift CLI or documented as removed in README, CLAUDE, and `docs/verification/swift-single-stack-cutover.md`.

- [ ] Remove root Node package/runtime metadata if no retained maintenance tooling requires it.

- [ ] Run filesystem check:

```bash
test ! -e src/index.ts
test ! -e src/daemon.ts
test ! -e src/web.ts
test ! -e macos/scripts/build-node-bundle.sh
```

Expected: all commands exit 0.

- [ ] After each deletion group, run `scripts/verify-swift-only-cutover.sh` plus the relevant Swift build/tests before continuing to the next group.

## Task 9: Add Swift-Only Verification Script and Grep Gates

**Files:**

- Create: `scripts/verify-swift-only-cutover.sh`
- Modify: `macos/scripts/build-release.sh`
- Modify: `docs/verification/swift-single-stack-cutover.md`

- [ ] Create `scripts/verify-swift-only-cutover.sh` with strict shell settings and repo-root detection.

- [ ] The script must run these source/docs grep gates and fail if any shipped app/runtime path references Node runtime terms:

```bash
rg -n '\bnode\b|\bnpm\b|\bnode_modules\b|Resources/node|build-node-bundle|node-bundle\.stamp|dist/index\.js|dist/daemon\.js|src/index\.ts|src/daemon\.ts|nodejsPath|nodeJsPath|daemon\.js|MCPServer\(|DaemonClient|http://127\.0\.0\.1|localhost:' \
  README.md CLAUDE.md package.json package-lock.json biome.json .github/workflows scripts \
  macos/project.yml macos/Engram macos/EngramMCP macos/Shared macos/scripts \
  -g '!macos/build/**' \
  -g '!docs/archive/**' \
  -g '!docs/superpowers/**' \
  -g '!scripts/gen-mcp-contract-fixtures.ts' \
  -g '!scripts/gen-adapter-parity-fixtures.ts' \
  -g '!scripts/check-adapter-parity-fixtures.ts'
```

Expected: no matches in shipped app/runtime/docs paths. Retained TypeScript fixture generators must be listed in an explicit allowlist, documented as non-shipped historical tooling, and excluded by exact path rather than broad `scripts/**` ignores.

- [ ] The script must run these Xcode project grep gates:

```bash
rg -n '\bnode\b|\bnpm\b|\bnode_modules\b|Resources/node|build-node-bundle|node-bundle\.stamp|dist/index\.js|dist/daemon\.js|src/index\.ts|src/daemon\.ts|nodejsPath|nodeJsPath|daemon\.js' \
  macos/Engram.xcodeproj macos/project.yml
```

Expected: no matches.

- [ ] The script must run build settings inspection:

```bash
cd macos
xcodebuild -showBuildSettings -project Engram.xcodeproj -scheme Engram | \
  rg -n '\bnode\b|\bnpm\b|\bnode_modules\b|Resources/node|build-node-bundle|node-bundle\.stamp|dist/index\.js|dist/daemon\.js|nodejsPath|nodeJsPath|daemon\.js'
```

Expected: `rg` exits with no matches; the verification script must invert this result so no matches is success.

- [ ] The script must inspect the freshly built app bundle:

```bash
DERIVED_DATA="${DERIVED_DATA:-/tmp/engram-swift-only-derived-data}"
xcodebuild build -project macos/Engram.xcodeproj -scheme Engram -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO
APP="$DERIVED_DATA/Build/Products/Debug/Engram.app"
test -n "$APP"
test ! -e "$APP/Contents/Resources/node"
find "$APP" \( -name 'node_modules' -o -name 'dist' -o -name 'daemon.js' -o -name 'index.js' -o -name 'web.js' -o -name 'package.json' \) -print | tee /tmp/engram-node-artifacts.txt
test ! -s /tmp/engram-node-artifacts.txt
```

Expected: no Node resource directory and no Node runtime artifacts in the app bundle.
- [ ] The bundle check must inspect the exact build product from the dedicated `-derivedDataPath`, not the first matching app in global DerivedData.

- [ ] The script must inspect linked/copy helper paths:
  - verify `EngramMCP` exists where packaging expects it;
  - verify no `EngramCLI` bridge is packaged unless a Swift CLI target is intentionally retained;
  - verify `otool -L` output for app and helpers does not reference Node runtime libraries.

- [ ] The script must inspect archive/export output when paths are supplied:

```bash
scripts/verify-swift-only-cutover.sh --app "/path/to/Engram.app"
scripts/verify-swift-only-cutover.sh --archive "macos/build/Engram.xcarchive"
```

Expected: same no-Node checks pass for exported app and archive products.

## Task 10: Clean-Checkout Verification Without npm Install

**Files:**

- Modify: `docs/verification/swift-single-stack-cutover.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] Create a clean checkout in a temporary directory from the current commit. Do not copy `node_modules`, `dist`, DerivedData, or local build artifacts. Require a clean worktree before this step so uncommitted deletions cannot be accidentally omitted from verification.

```bash
TMPDIR="$(mktemp -d)"
test -z "$(git status --porcelain)"
CURRENT_SHA="$(git rev-parse HEAD)"
git worktree add --detach "$TMPDIR/engram-clean" "$CURRENT_SHA"
cd "$TMPDIR/engram-clean"
```

- [ ] Prove no npm install is needed for app build/test by intentionally not running `npm install`.

- [ ] Run macOS dependency resolution and project generation:

```bash
cd macos
xcodegen generate
```

Expected: succeeds using Swift/XcodeGen dependencies only.

- [ ] Build the app:

```bash
export CLEAN_DERIVED_DATA="$TMPDIR/engram-clean-derived-data"
xcodebuild build -project Engram.xcodeproj -scheme Engram -configuration Debug -destination 'platform=macOS' -derivedDataPath "$CLEAN_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO
```

Expected: succeeds without `npm install`.

- [ ] Run Swift unit tests:

```bash
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' -derivedDataPath "$CLEAN_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' -derivedDataPath "$CLEAN_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO
```

Expected: succeeds without `npm install`.

- [ ] Launch the built app with a temporary `ENGRAM_HOME` and assert Swift service-ready without Node:

```bash
export ENGRAM_HOME="$TMPDIR/engram-clean-home"
mkdir -p "$ENGRAM_HOME"
open "$CLEAN_DERIVED_DATA/Build/Products/Debug/Engram.app" --args --fixture-home "$ENGRAM_HOME" --assert-service-ready
```

Expected: app reaches Swift service-ready and does not spawn `node`.

- [ ] Run Swift MCP stdio smoke from the clean checkout:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cutover-smoke","version":"1"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n' \
  | "$CLEAN_DERIVED_DATA/Build/Products/Debug/EngramMCP"
```

Expected: initialize and tools/list return valid JSON-RPC responses from Swift helper only.

- [ ] Run app bundle verification from the clean checkout:

```bash
../scripts/verify-swift-only-cutover.sh
```

Expected: succeeds.

- [ ] Run README command audit from the clean checkout:

```bash
rg -n 'npm install|npm run build|node dist/index\.js|dist/index\.js|dist/daemon\.js|Node\.js >=|Resources/node|node_modules' README.md CLAUDE.md macos
```

Expected: no shipped app/runtime instructions require npm or Node. Historical fixture notes must be outside the shipped app/runtime command set and explicitly labeled non-runtime.

- [ ] Validate documented MCP config examples from the clean checkout without mutating the user's real config:
  - extract README/CLAUDE Swift MCP command snippets into a temporary file;
  - run syntax validation for JSON/TOML snippets;
  - assert every referenced helper path exists in the fresh build output or uses an explicitly documented placeholder;
  - run any CLI-based `mcp add/list` smoke only with a temporary `HOME` or temporary agent config directory.

- [ ] Record the clean checkout path, commands, and pass/fail results in `docs/verification/swift-single-stack-cutover.md`.

## Task 11: Final Acceptance Gates

Run all gates from the repo root after deletion and docs updates:

```bash
git status --short --branch
(cd macos && xcodegen generate)
(cd macos && xcodebuild build -project Engram.xcodeproj -scheme Engram -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO)
(cd macos && xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO)
(cd macos && xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO)
scripts/verify-swift-only-cutover.sh
scripts/measure-swift-cutover-performance.sh
```

Expected: all commands pass.

Run explicit no-reference gates:

```bash
rg -n '\bnode\b|\bnpm\b|\bnode_modules\b|src/index\.ts|src/daemon\.ts|Resources/node|dist/index\.js|dist/daemon\.js|dist/cli|nodejsPath|nodeJsPath|daemon\.js|MCPServer\(|DaemonClient|http://127\.0\.0\.1|localhost:' \
  README.md CLAUDE.md package.json package-lock.json biome.json .github/workflows scripts \
  macos/project.yml macos/Engram macos/EngramMCP macos/Shared macos/scripts \
  -g '!macos/build/**' \
  -g '!docs/archive/**' \
  -g '!docs/superpowers/**' \
  -g '!scripts/gen-mcp-contract-fixtures.ts' \
  -g '!scripts/gen-adapter-parity-fixtures.ts' \
  -g '!scripts/check-adapter-parity-fixtures.ts'
```

Expected: no matches.

```bash
rg -n 'build-node-bundle|node-bundle\.stamp|Resources/node|node_modules|npm run build|dist/index\.js|dist/daemon\.js|dist/cli' \
  macos/project.yml macos/Engram.xcodeproj
```

Expected: no matches.

```bash
rg -n 'node dist/index\.js|dist/index\.js|dist/daemon\.js|/absolute/path/to/engram/dist/index\.js|command = "node"|\"command\": \"node\"' \
  README.md CLAUDE.md macos/Engram/Views/Settings
```

Expected: no matches.

Inspect the app bundle:

```bash
APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug/Engram.app' -maxdepth 6 -print | head -n 1)"
test -n "$APP"
test ! -d "$APP/Contents/Resources/node"
find "$APP" \( -name 'node_modules' -o -name 'daemon.js' -o -name 'index.js' -o -name 'web.js' -o -name 'package.json' \) -print
```

Expected: `test` commands pass and `find` prints nothing.

## Success Criteria

- Clean checkout builds and tests the macOS app and Swift MCP helper without `npm install`.
- Xcode project, schemes, build settings, scripts, app bundle, archive/export output, README, CLAUDE.md, and settings UI contain no shipped app/runtime references to Node, npm, `dist`, `node_modules`, `src/index.ts`, `src/daemon.ts`, `Resources/node`, or `node dist/index.js`.
- `macos/EngramMCP` is the only shipped MCP server.
- The app does not start `MCPServer`/`MCPTools`, `DaemonClient`, `IndexerProcess`, `node`, or `daemon.js`.
- Dual-run MCP and service parity artifacts were captured before deletion and documented.
- Stage 5 performance metrics are within the spec thresholds.
- Historical Node reference fixtures remain available only as checked-in goldens, not as a runtime or clean-build requirement.

## Rollback

Before this plan deletes Node, rollback is to re-enable the previous Node daemon/MCP path. After Task 8 lands, rollback is a git revert of the Stage 5 deletion commit. Do not keep Node fallback runtime code in the product after cutover.

## Residual Risks

- Broad `rg` terms such as plain `node`, `npm`, or `dist` can catch false positives such as ordinary English words or fixture prose; use the anchored patterns in this plan and keep allowlists narrow and outside shipped app/runtime paths.
- Archived Node fixture tooling can accidentally become a hidden build dependency if root `package.json` remains broad. Prefer deleting root Node package metadata unless a concrete non-runtime script is retained.
- Existing `macos/build/` artifacts can contain old Node resources. Always inspect fresh DerivedData and newly exported apps, and do not use stale `macos/build/Engram.xcarchive` as evidence.
- CLI deletion is only safe after Swift CLI replacement or explicit deprecation is already documented; otherwise user terminal workflows may silently disappear.
