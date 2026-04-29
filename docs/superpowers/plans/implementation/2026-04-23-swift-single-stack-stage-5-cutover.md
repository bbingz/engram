# Swift Single Stack Stage 5 Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` before implementing this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Goal

Complete the final Swift-only cutover by proving parity, performance, clean-checkout buildability, and packaging cleanliness before deleting the Node/HTTP bridge and Node runtime.

**Architecture:** Stage 5 is a hard-gate deletion stage, not a porting stage. Node remains available only as a pre-deletion reference while automation captures final MCP, service, indexing, project-operation, and performance evidence; after the deletion checkpoint, shipped app/runtime paths must use only `EngramService`, `EngramServiceClient`, `EngramCore`, and `macos/EngramMCP`.

**Tech Stack:** Swift 5.9+, XcodeGen, XCTest, GRDB/SQLite, macOS app/helper targets, shell verification scripts, checked-in fixture databases and goldens, TypeScript/Node only as frozen pre-deletion reference or explicitly labeled historical fixture tooling.

**Source Spec:** `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`

**Parent Plan:** `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md`

**Normative Draft:** `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-cutover-verification.md`

---

## Review-locked corrections

- Effective Stage 5 order overrides section numbering when there is a conflict: freeze Node reference artifacts, run parity and performance gates, deactivate Node packaging while retaining Node source reference, commit/checkpoint, run clean-checkout no-npm from that committed SHA, then delete Node source and package metadata in groups.
- Clean-checkout no-npm is valid only after Node packaging has been removed from `macos/project.yml` and the generated project. Running it before packaging deactivation is expected to fail and must not be used as deletion evidence.
- `scripts/verify-swift-only-cutover.sh` must implement grep gates as inverted checks (`if rg ...; then exit 1; fi`) and build path lists from existing files so deleted `package.json` or `biome.json` paths do not false-fail.
- Pre-deletion parity/performance scripts that mention Node must be deleted, moved to an exact non-shipped historical path, or excluded by exact path before the final Swift-only gate. This classification must include Stage 0/2 scripts such as `scripts/perf/capture-node-baseline.ts`, `scripts/db/emit-current-schema.ts`, `scripts/db/check-swift-schema-compat.ts`, `scripts/gen-parent-detection-fixtures.ts`, and `scripts/gen-indexer-parity-fixtures.ts`.
- App launch checks must run the actual built executable or use blocking `open -W` plus readiness polling and process-tree inspection. A bare `open` command is not sufficient evidence.
- Rollback after deletion restores every path changed since the checkpoint. Use `git diff --name-only <checkpoint-sha>..HEAD` to drive rollback scope instead of a manually maintained short path list.

## Scope

Stage 5 owns these outcomes:

- Add final automation for MCP parity, service/indexing parity, Swift cutover performance comparison, Swift-only grep/package checks, and clean-checkout no-npm verification.
- Freeze Node reference artifacts before deletion and record their commit, commands, and artifact paths.
- Remove Node packaging from XcodeGen and generated Xcode project files.
- Remove app runtime Node launch, the app-local HTTP MCP bridge, and daemon HTTP client paths after prior Stage 4 replacements are already in place.
- Update shipped user-facing docs and settings guidance to Swift service and Swift stdio MCP only.
- Delete Node runtime source and Node package metadata only after the parity gate, performance gate, clean checkout gate, and deletion checkpoint all pass.
- Keep historical fixture data only when it is explicitly labeled non-shipped and excluded by exact path from shipped-runtime grep gates.

Stage 5 does not own:

- Porting missing adapters, service commands, project operations, CLI behavior, database migrations, or MCP tools from Node to Swift.
- Rewriting the Swift UI visual layer.
- Changing SQLite database location or schema semantics except through already accepted Swift migration/service code.
- Keeping a Node fallback runtime after cutover.

## Prerequisites

Do not start Stage 5 until all of these are true in the same working tree:

- [ ] Stage 4 acceptance gates have passed and are recorded in the owning stage documents.
- [ ] `macos/EngramMCP` is the only supported MCP server implementation, and all public MCP tools have Swift contract coverage.
- [ ] `EngramServiceClient` replaces production runtime uses of `DaemonClient`.
- [ ] Swift service owns indexing, watching, maintenance, AI summaries, embeddings/vector rebuild behavior, project move/archive/undo/recover, session linking, insights, export, stats, costs, memory, timeline, lint config, live sessions, and hygiene operations.
- [ ] Swift MCP mutating tools route through the shared service IPC endpoint and fail closed when the service is unavailable.
- [ ] `docs/performance/baselines/2026-04-23-node-runtime-baseline.json` exists and contains every canonical baseline key: `coldAppLaunchToDaemonReadyMs`, `coldDbOpenMs`, `idleRssMB`, `initialFixtureIndexingMs`, `incrementalIndexingMs`, `mcpSearchP50Ms`, `mcpSearchP95Ms`, `mcpGetContextP50Ms`, `mcpGetContextP95Ms`, `gitCommit`, `macOSVersion`, `cpuArchitecture`, `nodeVersion`, `fixtureDbPath`, `fixtureCorpusPath`, `iterationCount`, `capturedAt`, and `captureMode`.
- [ ] `docs/swift-single-stack/file-disposition.md` exists and has a concrete final action for every Node/TypeScript file.
- [ ] `docs/swift-single-stack/stage-gates.md` has prior stages marked with exact command evidence.
- [ ] There are no unresolved Stage 4 parity exceptions in `docs/verification/swift-single-stack-cutover.md` or `docs/verification/swift-single-stack-stage4.md`.

If any prerequisite is false, abort Stage 5 and return to the owning earlier stage. Do not delete Node to make a Stage 5 prerequisite pass.

## Files to Create/Modify

Create these Stage 5 automation and evidence files:

- `scripts/run-mcp-dual-parity.sh`
- `scripts/run-service-dual-parity.sh`
- `scripts/measure-swift-cutover-performance.sh`
- `scripts/verify-swift-only-cutover.sh`
- `scripts/verify-clean-checkout-no-npm.sh`
- `docs/performance/swift-single-stack-stage5.json`
- `docs/verification/swift-single-stack-cutover.md`

Modify these product, packaging, docs, and test files only after the deletion checkpoint gates pass:

- `README.md`
- `CLAUDE.md`
- `macos/project.yml`
- `macos/Engram.xcodeproj/project.pbxproj` generated by XcodeGen only
- `macos/Engram.xcodeproj/xcshareddata/xcschemes/*.xcscheme` generated by XcodeGen only
- `macos/scripts/build-release.sh`
- `macos/Engram/App.swift`
- `macos/Engram/Core/AppEnvironment.swift`
- `macos/Engram/MenuBarController.swift`
- SwiftUI files under `macos/Engram/Views/**` that still reference Node, daemon HTTP, or app-local MCP bridge state
- Swift tests under `macos/EngramTests/**`, `macos/EngramMCPTests/**`, and `macos/Engram/TestSupport/**` that still reference Node daemon, `DaemonClient`, `IndexerProcess`, `MCPServer`, or `MCPTools`
- `tests/fixtures/mcp-golden/README.md`
- `package.json`, `package-lock.json`, and `biome.json` only after deciding whether any TypeScript historical fixture tooling remains

Delete only after all hard gates pass:

- `macos/scripts/build-node-bundle.sh`
- `macos/Engram/Core/MCPServer.swift`
- `macos/Engram/Core/MCPTools.swift`
- `macos/Engram/Core/DaemonClient.swift`
- `macos/Engram/Core/IndexerProcess.swift`, unless it has already been renamed into a Swift-service status type with no process/Node semantics in an earlier stage
- `src/index.ts`
- `src/daemon.ts`
- `src/web.ts`
- `src/tools/**`
- `src/adapters/**`
- app/daemon/MCP-only Node runtime modules under `src/core/**`
- `src/cli/**` only after Swift CLI replacement or explicit deprecation is already documented in `README.md`, `CLAUDE.md`, and `docs/verification/swift-single-stack-cutover.md`
- `dist/**` and `node_modules/**` if present locally and not tracked
- Node-only tests whose behavior is covered by Swift tests or preserved historical fixture goldens

Retain after cutover:

- `macos/EngramMCP/**`
- `tests/fixtures/mcp-contract.sqlite`
- `tests/fixtures/mcp-golden/**`
- Historical fixture generator scripts only if they are explicitly documented as non-shipped, retained by exact path, and excluded from clean app build/test. Allowed exact-path historical exceptions must be listed in `docs/verification/swift-single-stack-cutover.md` and reviewed before final grep gates; expected candidates include `scripts/gen-mcp-contract-fixtures.ts`, `scripts/gen-adapter-parity-fixtures.ts`, `scripts/check-adapter-parity-fixtures.ts`, `scripts/perf/capture-node-baseline.ts`, `scripts/db/emit-current-schema.ts`, `scripts/db/check-swift-schema-compat.ts`, `scripts/gen-parent-detection-fixtures.ts`, and `scripts/gen-indexer-parity-fixtures.ts`.
- Planning/spec files under `docs/superpowers/**`, which may mention Node as historical migration context and must be excluded from shipped-runtime no-reference gates.

## Phased Tasks

### Phase 1: Freeze Node Reference Artifacts

**Files:**

- Create or modify: `docs/verification/swift-single-stack-cutover.md`
- Modify: `tests/fixtures/mcp-golden/README.md`
- Create: `scripts/run-mcp-dual-parity.sh`
- Create: `scripts/run-service-dual-parity.sh`

- [ ] Confirm the worktree has no Stage 5 deletion changes:

```bash
git status --short
test -e src/index.ts
test -e src/daemon.ts
test -e src/web.ts
test -e macos/scripts/build-node-bundle.sh
```

Expected: `git status --short` may show unrelated in-progress files from prior workers, but the four `test -e` commands exit `0`. If any Node entrypoint is already missing, abort and repair Stage 4/Stage 5 ordering before continuing.

- [ ] Build the Node reference while it still exists:

```bash
TZ=UTC npm run build
```

Expected: exits `0`, and `dist/index.js` plus `dist/daemon.js` exist for parity harness use only. Failure means the Node reference is not freezeable; abort Stage 5 deletion.

- [ ] Regenerate MCP contract fixtures from the Node reference:

```bash
TZ=UTC npm run generate:mcp-contract-fixtures
```

Expected: exits `0`, `tests/fixtures/mcp-contract.sqlite` exists, and JSON files under `tests/fixtures/mcp-golden/` are deterministic. If fixture output changes unexpectedly, inspect and commit the fixture update before proceeding.

- [ ] Run the pre-deletion Node reference checks:

```bash
npm test
npm run lint
```

Expected: both commands exit `0`. Failure blocks deletion because Node is still the reference.

- [ ] Run Swift MCP tests against the frozen fixtures:

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: exits `0`, including tool-name and contract tests that compare Swift MCP behavior to the frozen Node fixture set.

- [ ] Implement `scripts/run-mcp-dual-parity.sh` with strict shell settings:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Required behavior:

- Set `TZ=UTC`.
- Build Node with `npm run build` before starting the Node reference.
- Use `tests/fixtures/mcp-contract.sqlite` only as the immutable source fixture DB path.
- Copy the fixture DB and fixture home into separate temporary directories for the Node MCP run and the Swift MCP run. Set `ENGRAM_MCP_DB_PATH` to the Swift temporary DB copy, never to the committed fixture file.
- Build or locate the Swift `EngramMCP` executable from `macos/Engram.xcodeproj`.
- Send identical JSON-RPC requests for `initialize`, `tools/list`, and `tools/call` for every public tool represented in `tests/fixtures/mcp-golden/**`.
- Normalize only generated UUIDs, temp paths under `tests/fixtures/mcp-runtime`, and fixed current-time overrides already used by tests.
- Write raw outputs under `tmp/mcp-dual-parity/node/` and `tmp/mcp-dual-parity/swift/`.
- Exit non-zero on any JSON shape, ordering, `isError`, content text, structured content, or tool-list difference not documented as an approved intentional improvement in `docs/verification/swift-single-stack-cutover.md`.

- [ ] Implement `scripts/run-service-dual-parity.sh` with strict shell settings:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Required behavior:

- Work only under `tmp/service-dual-parity/`.
- Copy fixture homes and fixture DBs before each run; never mutate `~/.engram/index.sqlite`.
- Ensure only one writer is active at a time.
- Run the Node daemon/indexing path against a temporary fixture corpus and capture row counts, checksums, and events.
- Run the Swift service/indexing path against a fresh copy of the same fixture corpus and capture row counts, checksums, and events.
- Compare `sessions`, `messages`, `session_costs`, `session_tools`, `session_files`, `metrics`, `insights`, `project_aliases`, `parent_session_id`, `suggested_parent_id`, `agent_role`, and `tier`.
- Compare service event sequences for `ready`, indexing progress, usage payloads, summary generation, maintenance events, and service-unavailable behavior.
- Include project move/archive/undo/recover dry-run and compensation parity if Stage 4 exposes those commands.
- Exit non-zero on checksum drift, row-count drift, or event drift unless the verification document lists a spec-approved intentional improvement.

- [ ] Update `tests/fixtures/mcp-golden/README.md` to state that these files are final historical Node reference fixtures, are not regenerated by default clean-checkout app builds, use `tests/fixtures/mcp-contract.sqlite`, and must never point tests at `~/.engram/index.sqlite`.

- [ ] Update `docs/verification/swift-single-stack-cutover.md` with the freeze commit hash, generator commands, fixture paths, and raw parity artifact paths.

Failure handling: any failure in this phase blocks Stage 5 deletion. Do not narrow the parity surface to make a failing comparison pass.

### Phase 2: Add Performance Gate Automation

**Files:**

- Create: `scripts/measure-swift-cutover-performance.sh`
- Create or update: `docs/performance/swift-single-stack-stage5.json`
- Modify: `docs/verification/swift-single-stack-cutover.md`
- Read: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`

- [ ] Implement `scripts/measure-swift-cutover-performance.sh` with strict shell settings:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Required baseline validation:

- Refuse to run if `docs/performance/baselines/2026-04-23-node-runtime-baseline.json` is missing.
- Refuse to run if any canonical key is missing.
- Refuse to run if any numeric baseline value is missing, non-finite, non-numeric, zero, or negative.
- Refuse to run if p95 is lower than p50 for the same MCP tool.
- Refuse to run if `iterationCount` is not a positive integer, `gitCommit` is empty, `fixtureDbPath` or `fixtureCorpusPath` does not exist, or a ratio denominator would be zero.
- Print the baseline `gitCommit`, `macOSVersion`, `cpuArchitecture`, `nodeVersion`, `fixtureDbPath`, `fixtureCorpusPath`, and `iterationCount` before measurement.

Required measurements:

- Build a fresh Debug or Release app from `macos/Engram.xcodeproj` using a dedicated `-derivedDataPath`.
- Launch the app with fixture-only arguments and a temporary `ENGRAM_HOME`.
- Wait for Swift service-ready using the Swift service event stream or app test hook, not Node stdout.
- Measure cold launch to service-ready in milliseconds.
- Measure idle RSS using `ps -o rss= -p <pid>` after service-ready and while not indexing; macOS reports RSS in KB, so divide by 1024 before writing the `idleRssMB` field.
- Measure initial fixture indexing wall-clock milliseconds.
- Append one new fixture session file and measure incremental indexing until committed visibility.
- Run at least 30 Swift MCP `search` calls and 30 Swift MCP `get_context` calls against `tests/fixtures/mcp-contract.sqlite`.
- Calculate p50 and p95 latencies for both MCP tools.
- Write `docs/performance/swift-single-stack-stage5.json` with the raw numbers, baseline numbers, ratios, thresholds, command metadata, and measured commit SHA.

Required blocking thresholds:

- `coldAppLaunchToDaemonReadyMs <= baseline * 1.20`.
- `idleRssMB <= baseline + 50`.
- `initialFixtureIndexingMs <= baseline * 1.20`.
- `incrementalIndexingMs <= baseline * 1.50`.
- `mcpSearchP50Ms <= baseline * 1.20`.
- `mcpGetContextP50Ms <= baseline * 1.20`.
- `mcpSearchP95Ms <= baseline * 1.50`.
- `mcpGetContextP95Ms <= baseline * 1.50`.

- [ ] The script must exit non-zero for any threshold failure. It is not acceptable to write a failing JSON report and continue.

- [ ] Run:

```bash
scripts/measure-swift-cutover-performance.sh
```

Expected: exits `0` only when every threshold passes and writes `docs/performance/swift-single-stack-stage5.json`. If it exits non-zero, record the failure in `docs/verification/swift-single-stack-cutover.md`, repair the owning earlier stage, and do not delete Node.

### Phase 3: Add Swift-Only Grep and Bundle Verification

**Files:**

- Create: `scripts/verify-swift-only-cutover.sh`
- Modify: `macos/scripts/build-release.sh`
- Modify: `docs/verification/swift-single-stack-cutover.md`

- [ ] Implement `scripts/verify-swift-only-cutover.sh` with strict shell settings and repo-root detection:

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
```

- [ ] Add this shipped-runtime source/docs grep gate. The script must treat matches as failure and must not scan `docs/superpowers/**` or fixture documentation:

```bash
EXISTING_PATHS=()
for path in README.md CLAUDE.md package.json package-lock.json biome.json .github/workflows scripts macos/project.yml macos/Engram macos/EngramMCP macos/Shared macos/scripts; do
  test -e "$path" && EXISTING_PATHS+=("$path")
done
if rg -n '(^|[[:space:]"'"'"'])node([[:space:]"'"'"'.]|$)|\bnpm\b|\bnode_modules\b|Resources/node|build-node-bundle|node-bundle\.stamp|dist/index\.js|dist/daemon\.js|dist/cli|src/index\.ts|src/daemon\.ts|src/web\.ts|nodejsPath|nodeJsPath|daemon\.js|MCPServer\(|MCPTools|DaemonClient|DaemonHTTPClientCore|IndexerProcess|http://127\.0\.0\.1|localhost:' \
  "${EXISTING_PATHS[@]}" \
  -g '!macos/build/**' \
  -g '!docs/superpowers/**' \
  -g '!tests/fixtures/**' \
  -g '!scripts/gen-mcp-contract-fixtures.ts' \
  -g '!scripts/gen-adapter-parity-fixtures.ts' \
  -g '!scripts/check-adapter-parity-fixtures.ts'; then
  echo "Node runtime reference found in shipped paths" >&2
  exit 1
fi
```

Expected after deletion: no matches. The exact historical fixture generator exclusions are allowed only if each retained script is documented as non-shipped in `docs/verification/swift-single-stack-cutover.md`.

- [ ] Add this generated project grep gate:

```bash
if rg -n '(^|[[:space:]"'"'"'])node([[:space:]"'"'"'.]|$)|\bnpm\b|\bnode_modules\b|Resources/node|build-node-bundle|node-bundle\.stamp|dist/index\.js|dist/daemon\.js|dist/cli|src/index\.ts|src/daemon\.ts|src/web\.ts|nodejsPath|nodeJsPath|daemon\.js' \
  macos/project.yml macos/Engram.xcodeproj; then
  echo "Node build reference found in generated project" >&2
  exit 1
fi
```

Expected after deletion: no matches.

- [ ] Add this docs/settings MCP guidance grep gate:

```bash
if rg -n 'node dist/index\.js|dist/index\.js|dist/daemon\.js|/absolute/path/to/engram/dist/index\.js|command = "node"|"command": "node"|Node\.js >=|npm install && npm run build|~/.engram/dist/index\.js|/usr/local/bin/node|/opt/homebrew/bin/node' \
  README.md CLAUDE.md macos/Engram/Views/Settings; then
  echo "Node setup guidance found in shipped docs/settings" >&2
  exit 1
fi
```

Expected after deletion: no matches.

- [ ] Add build-setting inspection that inverts `rg` correctly so no matches is success:

```bash
cd macos
xcodebuild -showBuildSettings -project Engram.xcodeproj -scheme Engram | \
  tee /tmp/engram-build-settings.txt
if rg -n '(^|[[:space:]"'"'"'])node([[:space:]"'"'"'.]|$)|\bnpm\b|\bnode_modules\b|Resources/node|build-node-bundle|node-bundle\.stamp|dist/index\.js|dist/daemon\.js|nodejsPath|nodeJsPath|daemon\.js' /tmp/engram-build-settings.txt; then
  echo "Node build setting found" >&2
  exit 1
fi
```

Expected after deletion: `rg` finds no matches. The verification script must not fail merely because `rg` returns `1` for no matches.

- [ ] Add fresh app bundle inspection using a dedicated DerivedData path:

```bash
DERIVED_DATA="${DERIVED_DATA:-/tmp/engram-swift-only-derived-data}"
rm -rf "$DERIVED_DATA"
xcodebuild build -project macos/Engram.xcodeproj -scheme Engram -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO
APP="$DERIVED_DATA/Build/Products/Debug/Engram.app"
test -d "$APP"
test ! -e "$APP/Contents/Resources/node"
find "$APP" \( -name 'node_modules' -o -name 'dist' -o -name 'daemon.js' -o -name 'index.js' -o -name 'web.js' -o -name 'package.json' \) -print | tee /tmp/engram-node-artifacts.txt
test ! -s /tmp/engram-node-artifacts.txt
```

Expected after deletion: build succeeds, `Contents/Resources/node` does not exist, and `find` prints nothing.

- [ ] Add helper and linkage inspection:

```bash
MCP_HELPER=""
for candidate in "$APP/Contents/Helpers/EngramMCP" "$DERIVED_DATA/Build/Products/Debug/EngramMCP"; do
  if test -x "$candidate"; then MCP_HELPER="$candidate"; break; fi
done
test -n "$MCP_HELPER"
if otool -L "$APP/Contents/MacOS/Engram" "$MCP_HELPER" 2>/dev/null | rg -n 'node|libnode|node_modules'; then
  echo "Node linkage found in app or MCP helper" >&2
  exit 1
fi
```

Expected after deletion: Swift MCP helper exists where packaging expects it, and `otool` output has no Node runtime linkage.

- [ ] Support optional artifact arguments:

```bash
scripts/verify-swift-only-cutover.sh --app "/path/to/Engram.app"
scripts/verify-swift-only-cutover.sh --archive "macos/build/Engram.xcarchive"
```

Expected: same no-Node checks run against supplied app/archive products. The script must inspect the supplied artifact, not stale global DerivedData.

- [ ] Update `macos/scripts/build-release.sh` to run `scripts/verify-swift-only-cutover.sh` after archive/export and before notarization or DMG packaging instructions.

Failure handling: any match in shipped-runtime grep gates fails Stage 5. Do not broaden exclusions beyond exact historical fixture generator paths, `tests/fixtures/**`, and `docs/superpowers/**`.

### Phase 4: Add Clean-Checkout No-npm Verification Script

**Files:**

- Create: `scripts/verify-clean-checkout-no-npm.sh`
- Modify: `docs/verification/swift-single-stack-cutover.md`
- Modify after deletion: `README.md`
- Modify after deletion: `CLAUDE.md`

- [ ] Implement `scripts/verify-clean-checkout-no-npm.sh` with strict shell settings:

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
```

- [ ] Require a clean worktree before creating the clean checkout:

```bash
test -z "$(git status --porcelain)"
```

Expected: exits `0`. If the worktree is dirty, the script exits non-zero because uncommitted deletions cannot be trusted in a clean-checkout gate.

- [ ] Use `git worktree add --detach` from the current commit:

```bash
TMPDIR="$(mktemp -d)"
CURRENT_SHA="$(git rev-parse HEAD)"
git worktree add --detach "$TMPDIR/engram-clean" "$CURRENT_SHA"
cd "$TMPDIR/engram-clean"
```

Expected: detached clean checkout is created without copying `node_modules`, `dist`, DerivedData, or local build artifacts.

- [ ] Prove app build/test works without `npm install` by intentionally not running any npm command:

```bash
cd macos
command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
xcodegen generate
export CLEAN_DERIVED_DATA="$TMPDIR/engram-clean-derived-data"
xcodebuild build -project Engram.xcodeproj -scheme Engram -configuration Debug -destination 'platform=macOS' -derivedDataPath "$CLEAN_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' -derivedDataPath "$CLEAN_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' -derivedDataPath "$CLEAN_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO
```

Expected: all commands exit `0` without `npm install`.

- [ ] Launch the fresh app with a temporary home and assert Swift service-ready without Node. The launch command must block until readiness or failure and must inspect the app process tree:

```bash
export ENGRAM_HOME="$TMPDIR/engram-clean-home"
mkdir -p "$ENGRAM_HOME"
APP_EXE="$CLEAN_DERIVED_DATA/Build/Products/Debug/Engram.app/Contents/MacOS/Engram"
"$APP_EXE" --fixture-home "$ENGRAM_HOME" --assert-service-ready --exit-after-ready &
APP_PID=$!
for _ in $(seq 1 60); do
  test -f "$ENGRAM_HOME/run/service-ready" && break
  sleep 1
done
if pgrep -P "$APP_PID" -fl 'node|npm|daemon\.js|dist/index\.js'; then
  kill "$APP_PID" 2>/dev/null || true
  exit 1
fi
wait "$APP_PID"
```

Expected: app reaches Swift service-ready and does not spawn `node`. If the app cannot expose `--assert-service-ready`, Stage 3 must add or document an equivalent test hook before Stage 5 deletion.

- [ ] Run Swift MCP stdio smoke from the clean checkout:

```bash
MCP_EXE=""
for candidate in "$CLEAN_DERIVED_DATA/Build/Products/Debug/Engram.app/Contents/Helpers/EngramMCP" "$CLEAN_DERIVED_DATA/Build/Products/Debug/EngramMCP"; do
  if test -x "$candidate"; then MCP_EXE="$candidate"; break; fi
done
test -n "$MCP_EXE"
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cutover-smoke","version":"1"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n' \
  | "$MCP_EXE"
```

Expected: stdout contains valid JSON-RPC responses for `initialize` and `tools/list` from Swift helper only.

- [ ] Run Swift-only verification from the clean checkout:

```bash
scripts/verify-swift-only-cutover.sh
```

Expected: exits `0`.

- [ ] Audit README and CLAUDE commands in the clean checkout:

```bash
if rg -n 'npm install|npm run build|node dist/index\.js|dist/index\.js|dist/daemon\.js|Node\.js >=|Resources/node|node_modules|command = "node"|"command": "node"' README.md CLAUDE.md macos; then
  echo "Node runtime setup reference found in clean checkout" >&2
  exit 1
fi
```

Expected after deletion: no shipped app/runtime instructions require npm or Node. Historical fixture notes must be outside shipped app/runtime command sets and explicitly labeled non-runtime.

- [ ] Record the temporary checkout path, commit SHA, command list, and pass/fail result in `docs/verification/swift-single-stack-cutover.md`.

Execution order: create the script in this phase, but run it as a blocking gate only after Phase 6 removes Node packaging from XcodeGen/generated project and that state is committed or otherwise checkpointed. Running clean checkout before packaging deactivation is invalid evidence.

Failure handling: clean-checkout failure blocks Node source deletion and final acceptance. Do not replace it with local DerivedData or local worktree evidence.

### Phase 5: Run Pre-Packaging Hard Gates

**Files:**

- Modify: `docs/verification/swift-single-stack-cutover.md`
- Modify: `docs/performance/swift-single-stack-stage5.json`

- [ ] Run from repo root:

```bash
rtk npm run lint
rtk npm test
rtk sh -lc 'cd macos && xcodegen generate'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
scripts/run-mcp-dual-parity.sh
scripts/run-service-dual-parity.sh
scripts/measure-swift-cutover-performance.sh
```

Expected: every command exits `0`; the performance script exits non-zero for threshold failures.

- [ ] Do not run clean-checkout as a deletion gate yet. First remove Node packaging in Phase 6, then run the clean-checkout script from that committed/checkpointed state:

```bash
echo "clean checkout deferred until after Phase 6 packaging deactivation"
```

Expected: no clean-checkout evidence is recorded before packaging deactivation.

- [ ] Append exact command results and artifact paths to `docs/verification/swift-single-stack-cutover.md`.

- [ ] Defer the deletion checkpoint until after Phase 6 removes Node packaging and the clean-checkout no-npm gate passes from the committed/checkpointed packaging-removal state:

```bash
CHECKPOINT="stage5-node-deletion-checkpoint-$(date -u +%Y%m%dT%H%M%SZ)"
git branch "$CHECKPOINT"
git rev-parse "$CHECKPOINT"
```

Expected when executed after Phase 6: a local branch points at the exact commit where parity, performance, Node packaging removal, and clean-checkout gates passed. Record the branch name and SHA in `docs/verification/swift-single-stack-cutover.md`.

Failure handling: if any pre-deletion hard gate fails, do not create the deletion checkpoint and do not delete Node. Fix the owning earlier stage or the gate automation first.

### Phase 6: Remove Node Packaging and Runtime Launch

**Files:**

- Modify: `macos/project.yml`
- Regenerate: `macos/Engram.xcodeproj/project.pbxproj`
- Regenerate: `macos/Engram.xcodeproj/xcshareddata/xcschemes/*.xcscheme`
- Delete: `macos/scripts/build-node-bundle.sh`
- Modify: `macos/scripts/build-release.sh`
- Modify: `macos/Engram/App.swift`
- Modify: `macos/Engram/Core/AppEnvironment.swift`
- Modify: `macos/Engram/MenuBarController.swift`
- Modify SwiftUI files under `macos/Engram/Views/**` that still use Node/daemon bridge state
- Delete: `macos/Engram/Core/MCPServer.swift`
- Delete: `macos/Engram/Core/MCPTools.swift`
- Delete: `macos/Engram/Core/DaemonClient.swift`
- Delete or rename away from process semantics: `macos/Engram/Core/IndexerProcess.swift`
- Modify or delete daemon/indexer bridge tests under `macos/EngramTests/**` and `macos/Engram/TestSupport/**`

- [ ] In `macos/project.yml`, remove the `Bundle Node.js Daemon` prebuild script and every reference to `macos/scripts/build-node-bundle.sh`, `node-bundle.stamp`, `Resources/node`, `dist`, `node_modules`, `npm`, or `node`.

- [ ] Keep `EngramMCP` as the only MCP helper path. Do not remove `macos/EngramMCP`.

- [ ] Keep `EngramCLI` if Stage 4 replaced Node CLI workflows with a Swift CLI. Remove only Node CLI wiring and document retained Swift-only CLI behavior in `docs/verification/swift-single-stack-cutover.md`.

- [ ] Delete `macos/scripts/build-node-bundle.sh`.

- [ ] Regenerate Xcode project files:

```bash
cd macos
xcodegen generate
```

Expected: exits `0`; generated project/scheme files no longer contain Node bundle phases.

- [ ] Verify generated project cleanup:

```bash
if rg -n 'build-node-bundle|node-bundle\.stamp|Bundle Node\.js Daemon|Resources/node|node_modules|npm run build|dist/|daemon\.js|src/index\.ts|src/daemon\.ts' macos/project.yml macos/Engram.xcodeproj; then
  echo "Node packaging reference remains" >&2
  exit 1
fi
```

Expected: no matches.

- [ ] Commit or otherwise checkpoint the packaging-removal state, then run the clean-checkout no-npm gate before deleting Node source:

```bash
test -z "$(git status --porcelain)"
scripts/verify-clean-checkout-no-npm.sh
CHECKPOINT="stage5-node-deletion-checkpoint-$(date -u +%Y%m%dT%H%M%SZ)"
git branch "$CHECKPOINT"
git rev-parse "$CHECKPOINT"
```

Expected: clean checkout builds/tests/launches without `npm install`; checkpoint branch records the Swift-only packaging state before Node source deletion starts.

- [ ] In `macos/Engram/App.swift`, remove construction/startup/termination behavior for `MCPTools`, `MCPServer`, `nodejsPath`, bundled `daemon.js`, `Resources/node`, and `IndexerProcess.start(nodePath:scriptPath:)`.

- [ ] Replace app environment injection with the Swift service status/client types from Stage 3/4. App UI must not receive `DaemonClient`, `IndexerProcess`, `DaemonEvent`, or app-local MCP bridge types.

- [ ] Delete `macos/Engram/Core/MCPServer.swift` and `macos/Engram/Core/MCPTools.swift`.

- [ ] Delete `macos/Engram/Core/DaemonClient.swift` only after this scan has no production callers:

```bash
if rg -n 'DaemonClient|DaemonHTTPClientCore|/api/|ENGRAM_MCP_DAEMON_BASE_URL|http://127\.0\.0\.1|localhost:' macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI --glob '!**/*Tests*' --glob '!macos/Engram/Core/DaemonClient.swift' --glob '!macos/Shared/Networking/DaemonHTTPClientCore.swift'; then
  echo "DaemonClient production caller remains" >&2
  exit 1
fi
```

Expected before deleting `DaemonClient.swift`: no production callers. Test names may be changed or deleted in the same phase.

- [ ] Delete or rename `macos/Engram/Core/IndexerProcess.swift` only after this scan has no production process semantics:

```bash
if rg -n 'IndexerProcess|DaemonEvent|start\(nodePath:scriptPath:\)|daemon\.js|nodejsPath|nodeJsPath' macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI --glob '!**/*Tests*' --glob '!macos/Engram/Core/IndexerProcess.swift'; then
  echo "IndexerProcess production semantics remain" >&2
  exit 1
fi
```

Expected before deleting/renaming: no production callers.

- [ ] Run after packaging/app bridge removal:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: both commands exit `0`.

- [ ] Run:

```bash
scripts/verify-swift-only-cutover.sh
```

Expected: exits `0` for packaging, source grep, and bundle checks.

Failure handling: if Swift tests fail after removing app bridge code, do not reintroduce Node fallback. Restore to the deletion checkpoint or repair the Swift service/app integration.

### Phase 7: Update Settings, README, CLAUDE, and Fixture Tooling

**Files:**

- Modify: `macos/Engram/Views/Settings/GeneralSettingsSection.swift`
- Modify: `macos/Engram/Views/Settings/SourcesSettingsSection.swift`
- Modify UI tests/screenshots under `macos/EngramUITests/**` if present
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `tests/fixtures/mcp-golden/README.md`
- Modify/delete: `scripts/gen-mcp-contract-fixtures.ts`
- Modify/delete: `package.json`
- Modify/delete: `package-lock.json`
- Modify/delete: `biome.json`
- Modify: `docs/verification/swift-single-stack-cutover.md`

- [ ] Remove `@AppStorage("nodejsPath")`, Node.js path fields, HTTP MCP endpoint rows, and snippets that run `node` or `~/.engram/dist/index.js` from settings views.

- [ ] Replace MCP setup guidance with Swift stdio helper examples:

```bash
claude mcp add --scope user engram /Applications/Engram.app/Contents/Helpers/EngramMCP
```

```toml
[mcp_servers.engram]
command = "/Applications/Engram.app/Contents/Helpers/EngramMCP"
```

```json
{
  "mcpServers": {
    "engram": {
      "command": "/Applications/Engram.app/Contents/Helpers/EngramMCP"
    }
  }
}
```

Expected: no Node command, args, `dist/index.js`, or HTTP bridge endpoint appears in user-facing setup.

- [ ] Update README quick start to remove Node as a product prerequisite and describe macOS app plus Swift MCP helper setup.

- [ ] Update README development instructions to state clean app builds do not require `npm install`. If historical TypeScript fixture tooling remains, isolate it under a section named `Historical reference fixture maintenance` and state that it is not needed for shipped app/runtime builds.

- [ ] Update `CLAUDE.md` from TypeScript MCP/server runtime guidance to Swift-only runtime guidance. Remove runtime references to `src/index.ts`, `src/daemon.ts`, `macos/scripts/build-node-bundle.sh`, `Resources/node`, `dist`, and `node_modules`.

- [ ] Prefer deleting `scripts/gen-mcp-contract-fixtures.ts` after frozen goldens are committed. If retained, document the exact retained path as historical and non-shipped in `docs/verification/swift-single-stack-cutover.md`.

- [ ] If no TypeScript maintenance scripts remain, delete `package.json`, `package-lock.json`, and `biome.json`.

- [ ] If TypeScript maintenance scripts remain, narrow `package.json`:

```json
{
  "private": true,
  "scripts": {
    "generate:historical-fixtures": "tsx scripts/gen-mcp-contract-fixtures.ts"
  },
  "devDependencies": {
  }
}
```

Expected: no `main`, no `bin`, no shipped runtime `build`/`dev` scripts, no `engines.node` requirement for product runtime, and no runtime dependencies unless the retained historical script proves it needs them.

- [ ] Run docs/settings/package grep checks:

```bash
DOC_PATHS=()
for path in README.md CLAUDE.md macos/Engram/Views/Settings package.json package-lock.json biome.json; do
  test -e "$path" && DOC_PATHS+=("$path")
done
if rg -n 'node dist/index\.js|dist/index\.js|dist/daemon\.js|node /absolute/path|Node\.js >=|npm install && npm run build|Resources/node|nodejsPath|mcpScriptPath|/usr/local/bin/node|/opt/homebrew/bin/node|~/.engram/dist/index\.js|command = "node"|"command": "node"' "${DOC_PATHS[@]}"; then
  echo "Node runtime setup reference found" >&2
  exit 1
fi
```

Expected: no matches, unless `package.json` has been deleted and shell `2>/dev/null` suppresses missing-file diagnostics.

Failure handling: shipped docs must not instruct Node setup. Historical fixture prose belongs in `tests/fixtures/mcp-golden/README.md` or `docs/verification/swift-single-stack-cutover.md`, not in quick start or user setup sections.

### Phase 8: Delete Node Runtime Source in Groups

**Files:**

- Delete: `src/index.ts`
- Delete: `src/daemon.ts`
- Delete: `src/web.ts`
- Delete: `src/tools/**`
- Delete: `src/adapters/**`
- Delete: app/daemon/MCP-only `src/core/**`
- Delete: `src/cli/**` only after Swift CLI replacement/deprecation is documented
- Modify/delete: Node-only tests under `tests/**`
- Modify/delete: `package.json`, `package-lock.json`, `biome.json`
- Modify: `docs/verification/swift-single-stack-cutover.md`

- [ ] Reconfirm hard gates immediately before the first deletion:

```bash
scripts/run-mcp-dual-parity.sh
scripts/run-service-dual-parity.sh
scripts/measure-swift-cutover-performance.sh
scripts/verify-clean-checkout-no-npm.sh
git rev-parse stage5-node-deletion-checkpoint-*
```

Expected: all scripts exit `0`, and a deletion checkpoint branch exists. If the branch glob matches multiple checkpoints, record the exact SHA used for rollback before deleting.

- [ ] Delete Group A: Node MCP and daemon entrypoints:

```bash
git rm src/index.ts src/daemon.ts src/web.ts
```

Expected: files are staged for deletion. Then run `scripts/verify-swift-only-cutover.sh` and Swift MCP tests.

- [ ] Delete Group B: TypeScript MCP tools:

```bash
git rm -r src/tools
```

Expected: files are staged for deletion. Then run `scripts/verify-swift-only-cutover.sh` and `cd macos && xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.

- [ ] Delete Group C: TypeScript adapters:

```bash
git rm -r src/adapters
```

Expected: files are staged for deletion only after Swift adapter/indexing parity is green. Then run Swift adapter/indexing tests named by Stage 2 plus `scripts/verify-swift-only-cutover.sh`.

- [ ] Delete Group D: app/daemon/MCP-only `src/core/**` runtime modules. Before deleting, list modules that are retained as historical fixture dependencies in `docs/verification/swift-single-stack-cutover.md`; all other app/daemon/MCP runtime modules are removed with `git rm`.

- [ ] Delete Group E: `src/cli/**` only if README, CLAUDE, and verification docs already contain a command-by-command Swift replacement/deprecation table. Then run CLI tests if a Swift CLI remains.

- [ ] Delete or narrow Node-only tests. Preserve checked-in fixture data under `tests/fixtures/**`; do not keep tests that require the deleted Node runtime in the final shipped verification path.

- [ ] After each group, run:

```bash
scripts/verify-swift-only-cutover.sh
cd macos
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: every command exits `0`. Record results in `docs/verification/swift-single-stack-cutover.md`.

Failure handling: if a deletion group breaks Swift build/tests or grep gates, restore that group from the deletion checkpoint and repair Swift-owned replacements. Do not re-add Node as fallback runtime.

### Phase 9: Final Acceptance Run

**Files:**

- Modify: `docs/verification/swift-single-stack-cutover.md`
- Modify: `docs/performance/swift-single-stack-stage5.json`

- [ ] Run from repo root after all deletions and docs updates:

```bash
git status --short --branch
(cd macos && xcodegen generate)
(cd macos && xcodebuild build -project Engram.xcodeproj -scheme Engram -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO)
(cd macos && xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO)
(cd macos && xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO)
scripts/verify-swift-only-cutover.sh
scripts/measure-swift-cutover-performance.sh
```

Expected: all commands exit `0`. `git status --short --branch` shows only intended Stage 5 changes.

- [ ] Run clean checkout after deletion from a clean commit:

```bash
test -z "$(git status --porcelain)"
scripts/verify-clean-checkout-no-npm.sh
```

Expected: exits `0`, builds/tests/launches app, and runs Swift MCP smoke without `npm install`.

- [ ] Run final no-reference gates manually to confirm the script result:

```bash
EXISTING_PATHS=()
for path in README.md CLAUDE.md package.json package-lock.json biome.json .github/workflows scripts macos/project.yml macos/Engram macos/EngramMCP macos/Shared macos/scripts; do
  test -e "$path" && EXISTING_PATHS+=("$path")
done
if rg -n '(^|[[:space:]"'"'"'])node([[:space:]"'"'"'.]|$)|\bnpm\b|\bnode_modules\b|src/index\.ts|src/daemon\.ts|src/web\.ts|Resources/node|dist/index\.js|dist/daemon\.js|dist/cli|nodejsPath|nodeJsPath|daemon\.js|MCPServer\(|MCPTools|DaemonClient|DaemonHTTPClientCore|IndexerProcess|http://127\.0\.0\.1|localhost:' \
  "${EXISTING_PATHS[@]}" \
  -g '!macos/build/**' \
  -g '!docs/superpowers/**' \
  -g '!tests/fixtures/**' \
  -g '!scripts/gen-mcp-contract-fixtures.ts' \
  -g '!scripts/gen-adapter-parity-fixtures.ts' \
  -g '!scripts/check-adapter-parity-fixtures.ts'; then
  echo "Node runtime reference found in shipped paths" >&2
  exit 1
fi
```

Expected: no matches in shipped app/runtime/docs paths.

```bash
if rg -n 'build-node-bundle|node-bundle\.stamp|Resources/node|node_modules|npm run build|dist/index\.js|dist/daemon\.js|dist/cli|daemon\.js' \
  macos/project.yml macos/Engram.xcodeproj; then
  echo "Node generated project reference found" >&2
  exit 1
fi
```

Expected: no matches.

```bash
if rg -n 'node dist/index\.js|dist/index\.js|dist/daemon\.js|/absolute/path/to/engram/dist/index\.js|command = "node"|"command": "node"' \
  README.md CLAUDE.md macos/Engram/Views/Settings; then
  echo "Node setup guidance found" >&2
  exit 1
fi
```

Expected: no matches.

- [ ] Inspect the exact app bundle from the dedicated DerivedData path used by `scripts/verify-swift-only-cutover.sh`; do not use stale `macos/build/**` artifacts as evidence.

- [ ] Append final command output summaries, app bundle path, archive/export path if applicable, retained historical exceptions, and deletion list to `docs/verification/swift-single-stack-cutover.md`.

## Verification

Stage 5 verification has four mandatory hard gates. All must pass before deletion starts, and all relevant post-deletion checks must pass again after deletion.

Parity gate:

```bash
scripts/run-mcp-dual-parity.sh
scripts/run-service-dual-parity.sh
```

Expected: both exit `0`; raw output artifacts are written under `tmp/mcp-dual-parity/**` and `tmp/service-dual-parity/**`; `docs/verification/swift-single-stack-cutover.md` records command output summaries and any approved intentional differences.

Performance gate:

```bash
scripts/measure-swift-cutover-performance.sh
```

Expected: exits `0` only when all thresholds pass; writes `docs/performance/swift-single-stack-stage5.json`. Any threshold failure must exit non-zero and block deletion.

Clean checkout gate:

```bash
test -z "$(git status --porcelain)"
scripts/verify-clean-checkout-no-npm.sh
```

Expected: uses `git worktree add --detach`, performs no `npm install`, builds/tests/launches app, and runs Swift MCP smoke from a temporary checkout.

Deletion checkpoint gate:

```bash
CHECKPOINT="stage5-node-deletion-checkpoint-$(date -u +%Y%m%dT%H%M%SZ)"
git branch "$CHECKPOINT"
git rev-parse "$CHECKPOINT"
```

Expected: checkpoint branch exists at the commit where parity, performance, and clean checkout passed. Node deletion starts only after this branch/SHA is recorded.

Post-deletion Swift-only gate:

```bash
(cd macos && xcodegen generate)
(cd macos && xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO)
(cd macos && xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO)
scripts/verify-swift-only-cutover.sh
scripts/measure-swift-cutover-performance.sh
```

Expected: all commands exit `0`; no shipped Node runtime, duplicate MCP bridge, Node app resource, or Node setup docs remain.

## Acceptance Gates

- [ ] Stage 5 prerequisites are true and recorded before any deletion.
- [ ] Node reference artifacts are frozen before deletion, including MCP goldens, service/indexing parity outputs, project-operation parity outputs, schema artifacts, and performance baseline metadata.
- [ ] `scripts/run-mcp-dual-parity.sh` passes before deletion.
- [ ] `scripts/run-service-dual-parity.sh` passes before deletion.
- [ ] `scripts/measure-swift-cutover-performance.sh` exits `0` before deletion and exits non-zero on any threshold failure.
- [ ] `scripts/verify-clean-checkout-no-npm.sh` passes from a clean worktree using `git worktree add --detach` and no `npm install`.
- [ ] A deletion checkpoint branch and SHA are recorded before deleting Node files.
- [ ] `scripts/verify-swift-only-cutover.sh` passes after deletion.
- [ ] `macos/project.yml` and regenerated `macos/Engram.xcodeproj/**` contain no Node bundle/build phase references.
- [ ] The freshly built app bundle contains no `Contents/Resources/node`, `node_modules`, `dist`, `daemon.js`, `index.js`, `web.js`, or `package.json` Node runtime artifact.
- [ ] `macos/EngramMCP` is the only shipped MCP server.
- [ ] The app does not start `MCPServer`, `MCPTools`, `DaemonClient`, `DaemonHTTPClientCore`, `IndexerProcess`, `node`, or `daemon.js`.
- [ ] User-facing README, CLAUDE, and settings UI do not instruct installing Node or running Node for Engram app/MCP runtime.
- [ ] Historical Node fixture references, if retained, are limited to exact documented non-shipped paths and are excluded from shipped-runtime grep gates without broad ignores.
- [ ] Clean checkout builds, tests, launches the macOS app, reaches Swift service-ready, and runs Swift MCP `initialize` plus `tools/list` without `npm install`.

## Rollback/Abort Guidance

Abort before deletion when:

- A prerequisite from Stage 0-4 is false.
- Frozen Node fixtures cannot be regenerated deterministically.
- Dual MCP parity or service parity has unexplained drift.
- Performance comparison cannot produce a non-zero failure for threshold regressions.
- Clean checkout requires `npm install`, `node_modules`, `dist`, or existing DerivedData.
- Any mutating Swift path can write without `EngramServiceClient`.
- `EngramMCP` can mutate when service IPC is unavailable.
- App UI or MCP targets import `EngramCoreWrite`.

Rollback before the deletion checkpoint:

- Leave Node reference files intact.
- Re-enable the previous Swift service/app configuration only if the owning earlier stage documents it.
- Rerun the failing gate after repair.

Rollback after the deletion checkpoint:

```bash
git status --short
git diff --name-only <checkpoint-sha>..HEAD > /tmp/engram-stage5-rollback-paths.txt
git restore --source <checkpoint-sha> --pathspec-from-file=/tmp/engram-stage5-rollback-paths.txt
cd macos && xcodegen generate
```

Expected: restores every path changed after the recorded checkpoint for repair, including generated project files, packaging scripts, docs/settings, package metadata, and Node reference files. Use a normal git revert of the Stage 5 deletion commit when the deletion has already been committed. Do not keep restored Node as a fallback runtime in the final product.

Rollback for package/docs-only defects:

- Restore only the defective docs/package files from the checkpoint.
- Keep Swift-only runtime deletion intact if parity, performance, clean checkout, and app bundle gates still pass.
- Rerun `scripts/verify-swift-only-cutover.sh` and `scripts/verify-clean-checkout-no-npm.sh`.

## Self-review Checklist

- [ ] The plan references the required source spec, parent plan, and Stage 5 draft.
- [ ] No step asks a worker to delete Node before parity, performance, clean checkout, and deletion checkpoint gates pass.
- [ ] Performance thresholds are numeric and the measurement script is required to exit non-zero on threshold failure.
- [ ] Clean checkout explicitly requires a clean worktree and `git worktree add --detach`.
- [ ] Grep gates exclude `docs/superpowers/**`, `tests/fixtures/**`, and only exact historical fixture generator script paths; no broad `scripts/**` or docs-wide ignore hides shipped runtime references.
- [ ] Node fixture/golden docs cannot false-fail shipped-runtime grep gates.
- [ ] Delete/retain lists explicitly name `src/index.ts`, `src/daemon.ts`, `src/web.ts`, `src/tools/**`, `src/adapters/**`, app/daemon/MCP-only `src/core/**`, `src/cli/**`, `macos/scripts/build-node-bundle.sh`, `MCPServer.swift`, `MCPTools.swift`, `DaemonClient.swift`, and `IndexerProcess.swift`.
- [ ] `macos/EngramMCP` is explicitly retained as the only shipped MCP server.
- [ ] Every phase lists file paths, commands, expected output, and failure handling.
- [ ] Every task contains concrete commands, paths, expected results, and failure handling.
