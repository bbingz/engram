# Swift Single Stack Stage 2 Adapters and Indexing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` or `superpowers:subagent-driven-development` before implementing this plan. Execute tasks in order and update checkboxes only after the listed verification command passes.

**Goal:** Port session adapters, fixture parity, indexing, parent detection, startup backfills, and watcher semantics from the Node reference into Swift without changing product behavior or deleting Node.

**Architecture:** Node remains the reference implementation through Stage 4. Swift parsing models and read-only adapter code may be shared with app/MCP-safe read targets, but all production indexing writes, batch upserts, startup backfills, and DB mutation APIs must live in `EngramCoreWrite` and be consumable only by the Stage 3 service writer. `IndexingWriteSink` may define shared request/result shapes, but production write implementations must not live in `EngramService`, `Engram`, `EngramMCP`, `EngramCLI`, or app/MCP shared source trees; test doubles must live only in test targets.

**Tech Stack:** Swift 5.9+, XCTest, GRDB, Foundation file streaming, FSEvents or DispatchSource wrappers for tests, TypeScript/Node reference scripts, Vitest, XcodeGen, existing SQLite schema from Stage 1.

**Source spec:** `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`

**Parent plan:** `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md`

**Normative draft:** `docs/superpowers/plans/drafts/2026-04-23-swift-single-stack-adapters-indexing.md`

---

## Goal

Stage 2 is complete when Swift adapters and the Swift indexer produce the same normalized sessions, messages, metrics, parent links, index job effects, failure classifications, and watcher/backfill behavior as the current TypeScript implementation on controlled fixtures.

The stage must preserve the old runtime. Do not remove or disable `src/adapters/*`, `src/core/indexer.ts`, `src/core/parent-detection.ts`, `src/core/watcher.ts`, Node scripts, Node tests, app daemon launch code, or MCP code in this stage.

## Scope

In scope:

- Generate Node reference goldens for adapter success cases and parser failures.
- Port these adapters to Swift: `MessageAdapter` shared model/protocol, `SessionAdapter`, `ProjectAdapter`, `InsightAdapter`, `SearchAdapter`, `StatsAdapter`, Codex, Claude Code, Gemini CLI, OpenCode, iFlow, Qwen, Kimi, Cline, Cursor, VS Code, Windsurf, Antigravity, Copilot, and the shared Cascade client used by Windsurf/Antigravity.
- Add fixture parity for normalized session snapshots, messages, tool calls, token usage, source metadata, and failure classifications.
- Add malformed fixture coverage for invalid UTF-8, truncated JSON/JSONL, deeply nested records, malformed tool-call arguments, generated files over 100 MB, sessions over 10,000 messages, and file modification during parse.
- Add `tests/fixtures/adapter-parity/batch-sizes.json` generated from the Node reference and make Swift indexing use those values.
- Add `tests/fixtures/parent-detection/detection-version.json` generated from `src/core/parent-detection.ts` and test that Swift `DETECTION_VERSION` matches it.
- Port parent detection scoring, dispatch/probe detection, CWD classification, temporal decay, orphan handling, suggested parent behavior, and startup link backfills.
- Port Swift indexer orchestration, session tiering, authoritative snapshot writing, metric extraction, batch upsert, and index job enqueue behavior.
- Port watcher semantics: watch roots, ignored paths, 2 second write stability, 500 path drain batch, duplicate coalescing, rename/unlink handling, symlink semantics, permission errors, and project-move skip hooks.

Out of scope:

- Deleting Node runtime code or TypeScript adapters.
- Moving app startup from Node daemon to Swift service. That is Stage 3.
- Enabling mutating Swift MCP or CLI commands. That is Stage 4.
- Changing SQLite schema unless Stage 1 already established the migration and Node compatibility gates.
- Putting production write APIs into `EngramService`, `macos/Engram`, `macos/EngramMCP`, `macos/EngramCLI`, or app/MCP shared code.
- Shipping `TestIndexingWriteSink`, fake writers, fixture injectors with real HOME defaults, or any test double in production targets.

## Prerequisites

Stage 2 is blocked until Stage 1 passes in the same working tree.

The Stage 1 gate is the full Stage 1 acceptance gate, not a file-existence smoke check. Before any adapter or indexing edit, the worker must verify:

- `EngramCoreRead`, `EngramCoreWrite`, and `EngramCoreTests` exist in `macos/project.yml`.
- Baseline validation has passed in `--compare-only` mode without changing the canonical baseline or committed fixture checksums.
- Swift read parity, migration validation, schema compatibility, WAL/busy-timeout/foreign-key policy, FTS rebuild policy, vector strategy, and module-boundary tests have passed.
- `scripts/db/check-swift-schema-compat.ts` proves Node can read Swift-created and Swift-migrated DBs.
- App/MCP/CLI/shared direct-write scans have passed after Stage 1 target graph changes.

Before editing code for Stage 2, run:

```bash
test -f docs/swift-single-stack/stage-gates.md
test -f docs/performance/baselines/2026-04-23-node-runtime-baseline.json
test -f docs/swift-single-stack/app-write-inventory.md
test -f docs/superpowers/decisions/2026-04-23-swift-sqlite-vec.md
```

Expected: all commands exit `0`.

Failure handling: if any file is missing, stop Stage 2 and return to Stage 0/1 ownership. Do not create replacement baseline, inventory, or vector-strategy artifacts in this stage.

Then run:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
rtk npx tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 50 --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
rtk npx tsx scripts/db/check-swift-schema-compat.ts --fixture-root tests/fixtures/db
rtk sh scripts/check-swift-module-boundaries.sh
rtk sh scripts/check-app-mcp-cli-direct-writes.sh
```

Expected: every command exits `0` and Stage 1 gates are green.

Failure handling: if this fails, do not start adapter/indexer work. Fix Stage 1 in the Stage 1 plan or wait for the Stage 1 worker to land its changes.

Then run:

```bash
rtk npm test
```

Expected: exit `0`; Node remains the parity reference.

Failure handling: if Node tests fail before Stage 2 changes, capture the failing test names in the stage handoff and stop. Stage 2 must not generate goldens from a failing reference.

## Files to create/modify

Build and package metadata:

- Modify: `macos/project.yml`
- Regenerate only through XcodeGen: `macos/Engram.xcodeproj/project.pbxproj`
- Modify: `package.json`

Node reference fixture scripts:

- Create: `scripts/gen-adapter-parity-fixtures.ts`
- Create: `scripts/check-adapter-parity-fixtures.ts`
- Create: `scripts/gen-parent-detection-fixtures.ts`
- Create: `scripts/gen-indexer-parity-fixtures.ts`

Fixture trees:

- Create/modify: `tests/fixtures/adapter-parity/codex/**`
- Create/modify: `tests/fixtures/adapter-parity/claude-code/**`
- Create/modify: `tests/fixtures/adapter-parity/gemini-cli/**`
- Create/modify: `tests/fixtures/adapter-parity/opencode/**`
- Create/modify: `tests/fixtures/adapter-parity/iflow/**`
- Create/modify: `tests/fixtures/adapter-parity/qwen/**`
- Create/modify: `tests/fixtures/adapter-parity/kimi/**`
- Create/modify: `tests/fixtures/adapter-parity/cline/**`
- Create/modify: `tests/fixtures/adapter-parity/cursor/**`
- Create/modify: `tests/fixtures/adapter-parity/vscode/**`
- Create/modify: `tests/fixtures/adapter-parity/windsurf/**`
- Create/modify: `tests/fixtures/adapter-parity/antigravity/**`
- Create/modify: `tests/fixtures/adapter-parity/copilot/**`
- Create: `tests/fixtures/adapter-parity/batch-sizes.json`
- Create/modify: `tests/fixtures/adapter-malformed/**`
- Create: `tests/fixtures/parent-detection/detection-version.json`
- Create/modify: `tests/fixtures/indexer-parity/fixture-root/**`
- Create: `tests/fixtures/indexer-parity/expected-db-checksums.json`
- Create/modify: `tests/fixtures/indexer-parity/parent-detection/**`
- Create/modify: `tests/fixtures/indexer-parity/startup-backfills/**`

Shared Swift adapter/read-safe code:

- Create: `macos/Shared/EngramCore/Adapters/SessionAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/AdapterRegistry.swift`
- Create: `macos/Shared/EngramCore/Adapters/ParserLimits.swift`
- Create: `macos/Shared/EngramCore/Adapters/StreamingLineReader.swift`
- Create: `macos/Shared/EngramCore/Adapters/JSONValue.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/OpenCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/IflowAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/QwenAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/KimiAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/ClineAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/VsCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/WindsurfAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/AntigravityAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/CascadeClient.swift`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/CascadeDiscovery.swift`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/cascade.proto`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/Generated/README.md`
- Create: `macos/Shared/EngramCore/Indexing/SessionTier.swift`
- Create: `macos/Shared/EngramCore/Indexing/ParentDetection.swift`
- Create: `macos/Shared/EngramCore/Indexing/WatchPathRules.swift`
- Create: `macos/Shared/EngramCore/Indexing/FixtureRoot.swift`
- Create: `macos/Shared/EngramCore/Indexing/IndexingEventTypes.swift`

Service-only/write-target Swift code:

- Create: `macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift`
- Create: `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift`
- Create: `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift`
- Create: `macos/EngramCoreWrite/Indexing/SessionBatchUpsert.swift`
- Create: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Create: `macos/EngramCoreWrite/Indexing/SessionWatcher.swift`
- Create: `macos/EngramCoreWrite/Indexing/NonWatchableSourceRescanner.swift`

Swift tests:

- Create: `macos/EngramTests/AdapterParityTests.swift`
- Create: `macos/EngramTests/IndexerParityTests.swift`
- Create: `macos/EngramTests/ParentDetectionParityTests.swift`
- Create: `macos/EngramTests/StartupBackfillTests.swift`
- Create: `macos/EngramTests/WatcherSemanticsTests.swift`
- Create: `macos/EngramTests/CascadeClientTests.swift`
- Modify: `macos/EngramTests/MessageParserTests.swift`
- Modify: `macos/EngramTests/StreamingJSONLReaderTests.swift`

Current UI parser compatibility:

- Modify: `macos/Engram/Core/MessageParser.swift`
- Modify: `macos/Engram/Core/StreamingJSONLReader.swift`
- Modify: `macos/Engram/Core/ToolCallParser.swift`

## Phased tasks

### Phase 1: Generate Node reference goldens and fixture gates

**Purpose:** create stable reference artifacts before any Swift adapter behavior is invented.

**Files:**

- Create: `scripts/gen-adapter-parity-fixtures.ts`
- Create: `scripts/check-adapter-parity-fixtures.ts`
- Create: `scripts/gen-parent-detection-fixtures.ts`
- Create: `scripts/gen-indexer-parity-fixtures.ts`
- Modify: `package.json`
- Create/modify: `tests/fixtures/adapter-parity/**`
- Create/modify: `tests/fixtures/adapter-malformed/**`
- Create: `tests/fixtures/adapter-parity/batch-sizes.json`
- Create: `tests/fixtures/parent-detection/detection-version.json`
- Create: `tests/fixtures/indexer-parity/expected-db-checksums.json`

Steps:

- [ ] Add `scripts/gen-adapter-parity-fixtures.ts` that imports every TypeScript adapter from `src/adapters/*`, runs `detect`, locator listing, `parseSessionInfo`, `streamMessages`, and the Node behavior feeding `ProjectAdapter`, `InsightAdapter`, `SearchAdapter`, and `StatsAdapter`, then writes deterministic JSON with sorted object keys.
- [ ] The fixture JSON shape must include `source`, `inputPath`, `locator`, `sessionInfo`, `messages`, `toolCalls`, `usageTotals`, `fileToolCounts`, `projectFields`, `insightFields`, `searchIndexFields`, `statsFields`, `failure`, `nodeVersion`, and `generatedAtCommit`.
- [ ] Add root injection for every source so generated paths are stable: Codex sessions root, Claude projects root, Gemini tmp root plus projects file, OpenCode DB path, iFlow projects root, Qwen projects root, Kimi sessions root plus `kimi.json`, Cline tasks root, Cursor `state.vscdb`, VS Code workspace storage root, Windsurf cache root, Antigravity cache root, Copilot session-state root.
- [ ] Add `scripts/check-adapter-parity-fixtures.ts` that fails when any supported source lacks one success expected JSON, when any malformed category is missing, when Project/Insight/Search/Stats parity fields are absent, when a committed fixture exceeds 5 MB, or when `batch-sizes.json` does not match values extracted from the Node reference.
- [ ] Add `scripts/gen-parent-detection-fixtures.ts` that reads `src/core/parent-detection.ts`, extracts the actual `DETECTION_VERSION`, and writes that extracted value to `tests/fixtures/parent-detection/detection-version.json` with the source commit. Do not hard-code `4` in the generator or checker.
- [ ] Add `scripts/gen-indexer-parity-fixtures.ts` that indexes `tests/fixtures/indexer-parity/fixture-root` with the Node reference and writes row checksums for `sessions`, `session_costs`, `session_tools`, `session_files`, `index_jobs`, parent-link columns, and selected metadata into `tests/fixtures/indexer-parity/expected-db-checksums.json`.
- [ ] Add package scripts: `generate:adapter-parity-fixtures`, `check:adapter-parity-fixtures`, `generate:parent-detection-fixtures`, and `generate:indexer-parity-fixtures`.
- [ ] Generate malformed manifests for `invalidUtf8`, `truncatedJSON`, `truncatedJSONL`, `malformedJSON`, `malformedToolCall`, `deeplyNestedRecord`, `fileTooLarge`, `messageLimitExceeded`, and `fileModifiedDuringParse`. Generate >100 MB and >10,000 message inputs inside tests, not as committed files.

Verification:

```bash
rtk npm run generate:adapter-parity-fixtures
rtk npm run generate:parent-detection-fixtures
rtk npm run generate:indexer-parity-fixtures
rtk npm run check:adapter-parity-fixtures
rtk npm test -- tests/adapters tests/core/indexer.test.ts tests/core/parent-detection.test.ts
```

Expected: every command exits `0`; fixture JSON is deterministic on a second run; no committed fixture exceeds 5 MB; `tests/fixtures/adapter-parity/batch-sizes.json` records values extracted from the Node reference and the Swift tests read that fixture instead of mirroring constants; `tests/fixtures/parent-detection/detection-version.json` records the extracted Node `DETECTION_VERSION`.

Failure handling: if a Node adapter test fails, repair the Node reference test or fixture generator before porting Swift. If fixture output changes on a second run without source changes, fix key ordering, timestamp normalization, path normalization, or root injection in the generator.

### Phase 2: Add shared Swift adapter contracts and test harness

**Purpose:** establish Swift model boundaries before source-specific adapter ports.

**Files:**

- Create: `macos/Shared/EngramCore/Adapters/SessionAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/AdapterRegistry.swift`
- Create: `macos/Shared/EngramCore/Adapters/ParserLimits.swift`
- Create: `macos/Shared/EngramCore/Adapters/StreamingLineReader.swift`
- Create: `macos/Shared/EngramCore/Adapters/JSONValue.swift`
- Create: `macos/EngramTests/AdapterParityTests.swift`
- Modify: `macos/project.yml`

Steps:

- [ ] Define Swift source enums and normalized models that map one-to-one with Node concepts: `SourceName`, `NormalizedSessionInfo`, `NormalizedMessage`, `NormalizedToolCall`, `TokenUsage`, `StreamMessagesOptions`, `AdapterParseResult`, and `ParserFailure`.
- [ ] Include read-facing adapter roles for `MessageAdapter`, `SessionAdapter`, `ProjectAdapter`, `InsightAdapter`, `SearchAdapter`, and `StatsAdapter`. They may share files or protocols, but the plan executor must preserve explicit type names so later MCP/service code can route each concern without guessing.
- [ ] Define `SessionAdapter` with async methods for source detection, locator listing, session info parsing, message streaming, and accessibility checks. Do not include any DB write method on these protocols.
- [ ] Define `ParserFailure` categories exactly: `fileMissing`, `fileTooLarge`, `invalidUtf8`, `truncatedJSON`, `truncatedJSONL`, `malformedJSON`, `malformedToolCall`, `deeplyNestedRecord`, `messageLimitExceeded`, `lineTooLarge`, `fileModifiedDuringParse`, `sqliteUnreadable`, `grpcUnavailable`, and `unsupportedVirtualLocator`.
- [ ] Define `ParserLimits` with a 100 MB production skip threshold, 8 MB JSONL line threshold, 10,000 normalized message cap, and pre/post parse file identity checks using size, mtime, and inode or file resource identifier when available.
- [ ] Extract or wrap existing Swift JSONL line reading into `StreamingLineReader` so tests can assert diagnostics and source adapters can stream without loading large files into memory.
- [ ] Add `AdapterParityTests` that loads every `tests/fixtures/adapter-parity/<source>/*.expected.json`, runs the matching Swift adapter with injected fixture roots, and compares normalized session info, messages, tool calls, usage totals, and failure classification.
- [ ] Update `macos/project.yml` to include the new shared files and tests, then regenerate the Xcode project.

Verification:

```bash
rtk sh -lc 'cd macos && xcodegen generate'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/StreamingJSONLReaderTests
```

Expected: XcodeGen exits `0`; the harness builds; parity tests initially fail only for adapters that are not implemented yet or pass with explicitly empty source filters used while bringing up the harness; existing streaming tests pass.

Failure handling: if production targets cannot import the shared model without importing write code, stop and repair `macos/project.yml` target membership. Do not move writer protocols into app/MCP targets to make compilation easier.

### Phase 3: Port filesystem JSONL adapters

**Purpose:** cover the streaming sources that exercise line parsing, tool calls, usage, system filtering, subagent paths, and source remapping.

**Files:**

- Create: `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/IflowAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/QwenAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift`
- Modify: `macos/EngramTests/AdapterParityTests.swift`
- Create/modify: `tests/fixtures/adapter-parity/{codex,claude-code,iflow,qwen,copilot}/**`

Steps:

- [ ] Port Codex behavior from `src/adapters/codex.ts`: `session_meta`, `response_item`, `originator`, effective `agentRole = dispatched` when originator is `Claude Code`, system-injection count, `model_provider`, file-size dedup input, and offset/limit streaming.
- [ ] Port Claude Code behavior from `src/adapters/claude-code.ts`: project root walking including nested `subagents`, `agentId` as DB id for subagents, parent id from path, source remapping for Qwen/Kimi/Gemini/MiniMax/LobsterAI by model/path, tool result counts, token usage, `tool_use` extraction, image stand-in text, noise tool filtering, and `decodeCwd` parity.
- [ ] Add Claude-format success fixtures whose expected normalized `source` values include `minimax` and `lobsterai`.
- [ ] Port iFlow behavior: project directory walk, `session-*.jsonl`, `sessionId`, CWD, start/end timestamps, system-injection detection, and text-array extraction.
- [ ] Port Qwen behavior: `message.parts[].text`, Qwen system prompt filtering, model extraction, and chats directory traversal.
- [ ] Port Copilot behavior: `session-state/<uuid>/events.jsonl`, `workspace.yaml` key-value metadata, `session.start` CWD fallback, `user.message`, `assistant.message`, and summary precedence.
- [ ] Add malformed fixtures for each adapter group: invalid UTF-8 line, truncated JSONL metadata line, deeply nested JSON/JSONL record, malformed tool-call input, file modified during parse, generated >100 MB file gate, and generated >10,000 messages gate.

Verification:

```bash
rtk npm run generate:adapter-parity-fixtures
rtk npm run check:adapter-parity-fixtures
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests
```

Expected: Node generation exits `0`; fixture check exits `0`; Swift adapter parity passes for `codex`, `claude-code`, `iflow`, `qwen`, and `copilot`.

Failure handling: if Swift and Node disagree, update Swift to match the Node golden. Do not edit the expected JSON unless the generator output changed after an intentional Node reference fixture update and the Node adapter tests still pass.

### Phase 4: Port whole-file, multi-file, SQLite, and virtual-locator adapters

**Purpose:** complete non-Cascade source coverage and source-specific edge cases.

**Files:**

- Create: `macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/KimiAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/ClineAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/VsCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/OpenCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift`
- Modify: `macos/EngramTests/AdapterParityTests.swift`
- Create/modify: `tests/fixtures/adapter-parity/{gemini-cli,kimi,cline,vscode,opencode,cursor}/**`

Steps:

- [ ] Port Gemini CLI whole-file parsing: `sessionId`, `projectHash`, `startTime`, `lastUpdated`, `messages`, `type=user|gemini|model`, content strings/text parts, `projects.json` reverse lookup, and project name from `.../tmp/<project>/chats/session-*.json`.
- [ ] Port Gemini sidecar handling exactly: read `{sessionId}.engram.json` beside the session file; set `parentSessionId`, `originator`, and `agentRole = dispatched` when originator is `claude-code`; missing or malformed sidecar must not fail the session.
- [ ] Port Kimi behavior: session id from `sessions/<workspace>/<session>/context.jsonl`, CWD from `kimi.json` by `last_session_id`, timestamp scan from `wire.jsonl`, include `context_sub_N.jsonl` sorted numerically, skip `_checkpoint`, and compute size as total context file size.
- [ ] Port Cline behavior: `ui_messages.json`, task id from parent directory, `say=task|user_feedback|text`, skip partial assistant messages, and CWD extraction from `api_req_started` JSON text.
- [ ] Port VS Code behavior: `workspaceStorage/*/chatSessions/*.jsonl`, first line `kind:0`, `v.requests`, user text from `message.text` or `parts`, assistant markdown content from response array, and id fallback to basename.
- [ ] Port OpenCode virtual locators with exact `dbPath::sessionId` format, read-only GRDB access, session query excluding archived sessions, message/part join ordering, text part extraction, DB file size as `sizeBytes`, and accessibility via session existence.
- [ ] Port Cursor virtual locators with exact `dbPath?composer=<id>` format, read-only GRDB access to `cursorDiskKV`, `composerData:<id>.conversation` first, `bubbleId:<composerId>:%` fallback ordered by `rowid`, `type` 1/2 mapping, text/rawText extraction, timing timestamp, and accessibility via `composerData`.
- [ ] Add malformed fixtures for invalid UTF-8 whole-file JSON, truncated JSON, malformed Gemini sidecar, Kimi missing `wire.jsonl`, Kimi missing sub context file, Cline non-array JSON, VS Code malformed first line, OpenCode unreadable SQLite, Cursor malformed JSON rows, and unsupported virtual locator strings.

Verification:

```bash
rtk npm run generate:adapter-parity-fixtures
rtk npm run check:adapter-parity-fixtures
rtk npm test -- tests/adapters/opencode.test.ts tests/adapters/cursor.test.ts
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests
```

Expected: Node adapter tests and Swift parity tests pass for `gemini-cli`, `kimi`, `cline`, `vscode`, `opencode`, and `cursor`.

Failure handling: if virtual locators accidentally call `stat` on the virtual string, fix Swift locator abstraction before continuing. Virtual locator size/dedup must use backing DB semantics from Node.

### Phase 5: Port Windsurf, Antigravity, and Cascade strategy

**Purpose:** preserve cache-mode behavior and prove live Cascade support without making tests depend on a real editor process.

**Files:**

- Create: `macos/Shared/EngramCore/Adapters/Sources/WindsurfAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/AntigravityAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/CascadeClient.swift`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/CascadeDiscovery.swift`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/cascade.proto`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/Generated/README.md`
- Create: `macos/EngramTests/CascadeClientTests.swift`
- Modify: `macos/EngramTests/AdapterParityTests.swift`
- Modify: `macos/project.yml`
- Create/modify: `tests/fixtures/adapter-parity/{windsurf,antigravity}/**`

Steps:

- [ ] Port Windsurf cache parsing: metadata first line, `id`, `title`, `createdAt`, `updatedAt`, skip first line, count messages, cache file size, markdown fallback split on `## User`, `## Assistant`, and `## Cascade`.
- [ ] Port Antigravity cache parsing: metadata first line, `id`, `title`, `summary`, `createdAt`, `updatedAt`, optional `cwd`, optional `pbSizeBytes`, skip first line, count messages, prefer `.pb` size over cache size, infer CWD from `/Users/<user>/-Code-/<project>` occurrences when missing, and markdown fallback.
- [ ] Copy the inline Cascade proto contract from `src/adapters/grpc/cascade-client.ts` into `macos/Shared/EngramCore/Adapters/Cascade/cascade.proto`. Do not hand-author divergent field names.
- [ ] Implement Cascade discovery by scanning `ps aux` for Antigravity 1.18+ `--csrf_token` arguments while excluding `--extension_server_port`, plus daemon-dir JSON discovery for older Antigravity and Windsurf `*.json` files containing `httpPort` and `csrfToken`.
- [ ] Implement ConnectRPC JSON via `URLSession` for `GetAllCascadeTrajectories`, `GetCascadeTrajectory`, and `ConvertTrajectoryToMarkdown`.
- [ ] Preserve Antigravity `.pb` backfill: after live trajectory listing, scan the local `.pb` trajectory cache for sessions not returned by the recent live API and parse them through the same cache/fallback path.
- [ ] Add fake ConnectRPC HTTP tests in `CascadeClientTests` that validate the CSRF header and response decoding. Add live smoke coverage guarded by `ENGRAM_LIVE_CASCADE_TEST=1` and skipped by default.
- [ ] Add SwiftProtobuf/gRPC generated fallback only when fake ConnectRPC tests or opt-in live smoke prove JSON transport cannot return the fields needed for parity. If fallback is added, keep generated files in the Cascade generated directory and document regeneration in `Generated/README.md`.

Verification:

```bash
rtk npm test -- tests/adapters/antigravity.test.ts tests/adapters/windsurf.test.ts
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/CascadeClientTests
```

Expected: cache-mode adapter parity passes for `windsurf` and `antigravity`; fake Cascade tests pass; live smoke is skipped unless `ENGRAM_LIVE_CASCADE_TEST=1`.

Failure handling: if live Cascade cannot reach message parity through JSON or generated gRPC, record the exact unsupported fields in the Stage 2 handoff and do not mark Stage 2 accepted. Cache-only parity is not sufficient unless the product scope is explicitly narrowed in the parent spec by a separate reviewed change.

### Phase 6: Port parent detection and startup link backfills

**Purpose:** make Swift parent/orphan inference match Node before indexing writes are trusted.

**Files:**

- Create: `macos/Shared/EngramCore/Indexing/ParentDetection.swift`
- Create: `macos/EngramTests/ParentDetectionParityTests.swift`
- Create: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Create: `macos/EngramTests/StartupBackfillTests.swift`
- Create/modify: `tests/fixtures/indexer-parity/parent-detection/**`
- Create: `tests/fixtures/parent-detection/detection-version.json`

Steps:

- [ ] Extract the current `DETECTION_VERSION` from `src/core/parent-detection.ts` into `tests/fixtures/parent-detection/detection-version.json` during fixture generation. Swift must compare against that fixture and must not hard-code an unchecked version value in the plan or tests.
- [ ] Port dispatch and probe regex behavior, including empty or whitespace-only first message as dispatched; probes for `ping`, math questions, `say hello`, `say exactly`, `echo`, `reply with`, and `respond with`; and exclusions for normal "say more" style questions.
- [ ] Port CWD relation classification: exact, nested, unrelated, and unknown.
- [ ] Port candidate scoring: agent starts before parent returns 0; ended parent with unrelated or unknown CWD returns 0; ended parent with same or nested CWD is allowed only when the gap is under 4 hours; time half-life is 4 hours; project match weight is 0.3; active bonus matches Node.
- [ ] Port best candidate selection: return the highest positive score even when close; return nil for empty or all-zero candidates.
- [ ] Port startup backfills into `EngramCoreWrite/Indexing/StartupBackfills.swift`: `downgradeSubagentTiers`, `backfillParentLinks`, `resetStaleDetections`, `backfillCodexOriginator`, and `backfillSuggestedParents`.
- [ ] Preserve manual-link safety: never overwrite `link_source = manual`.
- [ ] Add DB-level fixtures for path-based subagent links, Gemini sidecar links, Codex originator links, stale detection reset, no-parent dispatched sessions, orphan handling, and suggested-parent updates.

Verification:

```bash
rtk npm run generate:parent-detection-fixtures
rtk npm test -- tests/core/parent-detection.test.ts
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ParentDetectionParityTests -only-testing:EngramTests/StartupBackfillTests
```

Expected: Node parent detection tests pass; Swift direct cases match Node; Swift DB backfill tests pass; detection version fixture equals the current Node source value.

Failure handling: if Swift behavior seems more correct than Node, keep the Node behavior for Stage 2 and open a separate post-parity change request. This stage is parity-first.

### Phase 7: Port session tiering, indexing adapter, and batch upsert writer

**Purpose:** write the Swift indexer without leaking write-capable orchestration into app/MCP targets.

**Files:**

- Create: `macos/Shared/EngramCore/Indexing/SessionTier.swift`
- Create: `macos/Shared/EngramCore/Indexing/IndexingEventTypes.swift`
- Create: `macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift`
- Create: `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift`
- Create: `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift`
- Create: `macos/EngramCoreWrite/Indexing/SessionBatchUpsert.swift`
- Create: `macos/EngramTests/IndexerParityTests.swift`
- Create/modify: `tests/fixtures/indexer-parity/**`
- Modify: `macos/project.yml`

Steps:

- [ ] Port `computeTier` exactly: preamble-only skip, probes path skip, any `agentRole` skip, `/subagents/` skip, `messageCount <= 1` skip, no-reply lite when assistant/tool counts are explicitly zero, premium thresholds, noise summary lite, and normal fallback.
- [ ] Define read-safe event and snapshot DTOs in shared code only. Define `IndexingWriteSink` in `macos/EngramCoreWrite/Indexing` so app/MCP-importable targets cannot construct a sink or drive production writes.
- [ ] Make `IndexingWriteSink` expose one async method: `upsertBatch(_ snapshots: [AuthoritativeSessionSnapshot], reason: IndexingWriteReason) async throws -> SessionBatchUpsertResult`.
- [ ] Make `SessionBatchUpsertResult` contain per-session `indexed`, `noop`, `skipped`, `failure`, `enqueuedJobs`, and event-payload details needed by Stage 3 service events.
- [ ] Implement `SessionSnapshotWriter` and `SessionBatchUpsert` in `EngramCoreWrite` only. Do not place production write code under `EngramService`, `macos/Shared` if compiled into app/MCP, `macos/Engram`, `macos/EngramMCP`, or `macos/EngramCLI`.
- [ ] Put test doubles such as `TestIndexingWriteSink` only in `macos/EngramTests`. Add a target-membership scan that fails if a test double is compiled into `Engram`, `EngramMCP`, `EngramCLI`, `EngramService`, `EngramCoreRead`, or `EngramCoreWrite`.
- [ ] Port authoritative snapshot creation: `authoritativeNode` default `local`, sync payload fields, SHA-256 hash over JSON-equivalent payload, first three user messages for preamble detection, assistant/tool counts, `sourceLocator`, `sizeBytes`, timestamps, origin, tier, and agent role.
- [ ] Port merge/noop semantics from the Node session merge path and enqueue rules: FTS jobs for non-skip searchable changes and embedding jobs for normal/premium embedding changes.
- [ ] Port metric extraction: always write a `session_costs` row including zero-token sessions; upsert `session_tools`; upsert `session_files` only for absolute file paths from supported file tools; skip malformed tool-call JSON silently.
- [ ] Use `tests/fixtures/adapter-parity/batch-sizes.json` for batch constants at runtime in Swift tests and production defaults. Do not duplicate the Node values in Swift without a fixture-backed assertion that fails on Node drift.
- [ ] Preserve dedup semantics: real files skip when DB `sizeBytes` matches file stat size; Antigravity may dedup against `info.sizeBytes`; virtual locators skip direct filesystem stat and attempt parse.
- [ ] Implement `SwiftIndexer.indexAll` so parse failures are classified and indexing continues. Implement `SwiftIndexer.indexFile` so parse failures return `indexed = false` instead of throwing.
- [ ] Add DB checksum parity comparing Swift output with `tests/fixtures/indexer-parity/expected-db-checksums.json` for `sessions`, `session_costs`, `session_tools`, `session_files`, `index_jobs`, parent-link columns, and selected metadata.

Verification:

```bash
rtk npm run generate:indexer-parity-fixtures
rtk npm test -- tests/core/indexer.test.ts tests/core/session-tier.test.ts tests/core/sync.test.ts
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/IndexerParityTests
rtk sh scripts/check-indexing-test-double-boundaries.sh
```

Expected: Node indexer/tier/sync tests pass; Swift indexer parity passes; the boundary script proves every type conforming to `IndexingWriteSink` or named as a fake/test/recording/in-memory fixture helper lives under test sources and is absent from production target membership.

Failure handling: if the target-membership scan finds a test double in production paths, remove it from production target membership before continuing. If checksums differ, inspect per-table diffs and repair Swift writer semantics rather than editing expected checksums.

### Phase 8: Port startup backfill ordering and event sequence

**Purpose:** make Stage 3 service startup consume a tested indexing/backfill sequence without redesign.

**Files:**

- Modify: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Create/modify: `macos/EngramTests/StartupBackfillTests.swift`
- Create/modify: `tests/fixtures/indexer-parity/startup-backfills/**`

Steps:

- [ ] Port the startup sequence from the Node initial scan path in order: `indexAll`, `backfillCounts`, `backfillCosts`, `backfillScores`, `deduplicateFilePaths`, `optimizeFts`, `vacuumIfNeeded(15)`, `reconcileInsights`, `backfillFilePaths`, `downgradeSubagentTiers`, `backfillParentLinks`, `resetStaleDetections`, `backfillCodexOriginator`, `backfillSuggestedParents`, `cleanupStaleMigrations`, ready event count calculation, background orphan scan, recoverable index job run, and insight embedding backfill.
- [ ] For backfills owned by another stage, add typed dependencies and test fakes in test targets only; the production Stage 2 code must expose the hook and event shape without performing unrelated Stage 3/4 work.
- [ ] Preserve event names and payload fields needed by UI compatibility: `backfill_counts`, `backfill`, `db_maintenance`, `migration_cleanup`, `ready`, `orphan_scan`, `index_jobs_recovered`, and `insights_promoted`.
- [ ] Add tests that assert DB effects where Stage 2 owns the write and event ordering for every startup step.

Verification:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/StartupBackfillTests
```

Expected: startup backfill tests pass and event ordering matches the Node reference fixture.

Failure handling: if another stage has not delivered a dependency hook, keep the typed dependency boundary and skip only the external operation through a test fake. Do not silently remove the event from the sequence.

### Phase 9: Port watcher semantics

**Purpose:** match Node/chokidar semantics closely enough for Stage 3 service replacement.

**Files:**

- Create: `macos/Shared/EngramCore/Indexing/WatchPathRules.swift`
- Create: `macos/EngramCoreWrite/Indexing/SessionWatcher.swift`
- Create: `macos/EngramCoreWrite/Indexing/NonWatchableSourceRescanner.swift`
- Create: `macos/EngramTests/WatcherSemanticsTests.swift`

Steps:

- [ ] Match watched roots exactly: `~/.codex/sessions` for Codex, `~/.claude/projects` for Claude Code, `~/.gemini/tmp` for Gemini CLI, `~/.gemini/antigravity` for Antigravity, `~/.iflow/projects` for iFlow, `~/.qwen/projects` for Qwen, `~/.kimi/sessions` for Kimi, and `~/.cline/data/tasks` for Cline.
- [ ] Preserve watched source set: Codex, Claude Code, Gemini CLI, Antigravity, iFlow, Qwen, Kimi, Cline, and derived Claude-directory sources LobsterAI/MiniMax.
- [ ] Preserve non-watchable source rescan parity: Cursor, VS Code, Windsurf, Copilot, and any source that Node handles through periodic polling must have a typed `NonWatchableSourceRescanner` plan with 10-minute default interval, `rescan` event payload, recoverable index-job trigger, and tests using temporary HOME roots.
- [ ] Preserve ignored paths: `.gemini/tmp/<proj>/tool-outputs/`, `.vite-temp/`, `.engram-tmp-`, `.engram-move-tmp-`, `node_modules/`, and `.DS_Store`.
- [ ] Implement recursive macOS watching with no symlink following. Prefer FSEvents for recursive directories; use `DispatchSourceFileSystemObject` only for narrow file-level tests or fallback paths.
- [ ] Implement write stability equivalent to chokidar `awaitWriteFinish`: wait 2 seconds of unchanged size and mtime with 500 ms polling before indexing.
- [ ] Implement duplicate event coalescing and FIFO drain batches of at most 500 paths, using the value from `tests/fixtures/adapter-parity/batch-sizes.json`.
- [ ] Implement rename and unlink behavior: directory rename triggers subtree rescan; file rename appears as unlink plus add; both paths call project-move skip hooks; unlink marks rows by file path or source locator as orphan suspect with reason `cleaned_by_source`.
- [ ] Implement symlink target change behavior: target changes behind a symlink do not trigger indexing unless the symlink file itself changes.
- [ ] Implement permission revocation and rapid append/delete behavior: permission errors are classified and watcher continues for other roots; append then delete before stability does not index; orphan is marked only if the DB already had that source.
- [ ] Use temporary HOME roots and a fake indexer/writer in tests. Tests must not read real user session roots.

Verification:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/WatcherSemanticsTests
```

Expected: tests cover debounce interval, write-stability reset, max batch size, rename handling, symlink target changes, directory rename, permission revocation, rapid append/delete, duplicate suppression, project-move skip semantics, non-watchable source polling, `rescan` events, and recoverable index-job triggers.

Failure handling: if macOS watcher behavior is nondeterministic, keep production watcher code but make tests exercise a deterministic scheduler/clock abstraction. Do not weaken the 2 second/500 ms/500 path semantics.

### Phase 10: Route current UI parser through parity-backed adapters

**Purpose:** reuse the new adapter layer without changing UI display semantics.

**Files:**

- Modify: `macos/Engram/Core/MessageParser.swift`
- Modify: `macos/Engram/Core/StreamingJSONLReader.swift`
- Modify: `macos/Engram/Core/ToolCallParser.swift`
- Modify: `macos/EngramTests/MessageParserTests.swift`
- Modify: `macos/EngramTests/StreamingJSONLReaderTests.swift`

Steps:

- [ ] Keep existing UI parser tests passing before replacing internals.
- [ ] Route `MessageParser.parse(filePath:source:)` through `AdapterRegistry` for sources with parity coverage.
- [ ] Preserve UI-only `SystemCategory` display classification. If indexing adapters classify system messages differently, add a UI mapping layer rather than changing indexing counts.
- [ ] Keep `ContentSegmentParser` display behavior stable unless a current UI test proves it must be adjusted for adapter output.
- [ ] Keep `ToolCallParser` as a UI formatter only. Indexing metrics must come from adapter `toolCalls`, not display regex parsing.
- [ ] Add regression coverage for CJK, system prompts, empty content, malformed lines, unknown source, nonexistent file, and offset/limit display parsing.

Verification:

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/MessageParserTests -only-testing:EngramTests/StreamingJSONLReaderTests
```

Expected: current UI parser behavior remains green while supported sources use shared adapter parsing internally.

Failure handling: if UI display parity conflicts with indexing parity, keep a UI compatibility mapping layer and preserve indexing parity. Do not change Node fixture expectations to satisfy UI rendering.

### Phase 11: Run full Stage 2 verification and boundary scans

**Purpose:** prove Stage 2 can hand off to Stage 3 without leaking write APIs or test doubles.

**Files:**

- Modify/create only files listed in this plan.

Steps:

- [ ] Run Node reference generation and checks.
- [ ] Run all Swift focused tests.
- [ ] Run broad Swift app/MCP tests.
- [ ] Run source scans for illegal write placement, test double leakage, fixture size, and accidental Node deletion.
- [ ] Record exact command output in the Stage 2 handoff or verification log used by the implementation worker.

Verification:

```bash
rtk npm run generate:adapter-parity-fixtures
rtk npm run generate:parent-detection-fixtures
rtk npm run generate:indexer-parity-fixtures
rtk npm run check:adapter-parity-fixtures
rtk npm run lint
rtk npm test
rtk sh -lc 'cd macos && xcodegen generate'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/IndexerParityTests
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ParentDetectionParityTests
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/StartupBackfillTests
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/WatcherSemanticsTests
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/CascadeClientTests
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS'
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
rtk rg -n "import EngramCoreWrite|EngramDatabaseWriter|SessionBatchUpsert|StartupBackfills" macos/Engram macos/EngramMCP macos/EngramCLI macos/Shared
rtk rg -n "TestIndexingWriteSink|FakeIndexingWriteSink|MockIndexingWriteSink" macos/project.yml macos/Engram macos/EngramMCP macos/EngramCLI macos/EngramService macos/EngramCoreRead macos/EngramCoreWrite
rtk sh -lc 'find tests/fixtures -type f -size +5M -print | tee /tmp/engram-large-fixtures.txt; test ! -s /tmp/engram-large-fixtures.txt'
```

Expected:

- All generation, lint, npm, XcodeGen, Engram, EngramCore, and MCP xcodebuild commands exit `0`.
- The illegal write placement `rg` exits `1` with no matches in app/MCP/shared paths.
- The test-double `rg` exits `1` with no matches in production target paths.
- The large-fixture scan exits `0` and prints no files.

Failure handling: any non-zero test/build command blocks Stage 2 acceptance. Any illegal write or test-double scan match must be fixed by moving code to `EngramCoreWrite` or test targets before Stage 3 starts.

## Verification

During implementation, run the focused command listed in each phase before moving to the next phase. At Stage 2 completion, run the full Phase 11 command set.

Minimum evidence required for handoff:

- Node reference tests still pass.
- `npm run check:adapter-parity-fixtures` proves every supported source has success and malformed fixture coverage.
- Swift `AdapterParityTests` prove every adapter listed in scope matches Node goldens.
- Swift `IndexerParityTests` prove DB row checksums match Node for the fixture root.
- Swift `ParentDetectionParityTests` prove `DETECTION_VERSION`, dispatch/probe detection, CWD scoring, temporal scoring, and best candidate behavior match Node.
- Swift `StartupBackfillTests` prove DB backfills and event ordering.
- Swift `WatcherSemanticsTests` prove watcher debounce, batching, rename, symlink, permission, rapid append/delete, and project-move skip behavior.
- Boundary scans prove app/MCP/shared production paths cannot import or instantiate `EngramCoreWrite` writers and cannot compile test doubles.
- Windsurf/Antigravity live Cascade parity must be resolved as one of two explicit outcomes before Stage 2 acceptance: either ConnectRPC JSON passes fake and opt-in live parity for required fields, or SwiftProtobuf/gRPC fallback is implemented and tested. Cache-only parity is not an acceptable Stage 2 pass state unless the parent spec is narrowed by a reviewed change.

## Acceptance gates

- [ ] Stage 1 acceptance is already green in this working tree.
- [ ] Every supported source has at least one success adapter parity golden: Codex, Claude Code, Gemini CLI, OpenCode, iFlow, Qwen, Kimi, Cline, Cursor, VS Code, Windsurf, Antigravity, Copilot, plus Claude-derived MiniMax and LobsterAI fixtures.
- [ ] Every supported source has malformed fixture coverage for its relevant parser mode, and the global malformed matrix covers invalid UTF-8, truncated JSON, truncated JSONL, deeply nested records, malformed tool-call arguments, generated >100 MB file, generated >10,000 messages, and file modification during parse.
- [ ] `tests/fixtures/adapter-parity/batch-sizes.json` is generated from Node source, the fixture checker fails on Node drift, and Swift indexing reads it or has a fixture-backed assertion that prevents unchecked duplication.
- [ ] `tests/fixtures/parent-detection/detection-version.json` is generated from Node source and Swift `ParentDetection.DETECTION_VERSION` equals that fixture value.
- [ ] Project, Insight, Search, and Stats adapter parity fixtures exist and Swift tests assert their field shapes against Node goldens, not only session/message fixtures.
- [ ] Swift parent detection matches Node scoring, dispatch/probe detection, CWD classification, 4 hour decay/window rules, orphan handling, and suggested-parent behavior.
- [ ] Gemini sidecar `{sessionId}.engram.json` linkage sets parent, originator, and dispatched role exactly as Node does.
- [ ] Windsurf/Antigravity cache-mode parity always passes, and live Cascade behavior is either parity-proven with fake plus opt-in live tests or recorded as a blocking Stage 2 risk.
- [ ] Production write APIs for indexing, snapshot writing, batch upsert, startup backfills, and DB mutation live in `macos/EngramCoreWrite` and are not implemented in `EngramService`, app, MCP, CLI, or shared app/MCP production paths.
- [ ] `IndexingWriteSink` test doubles exist only in test targets and are excluded from production targets by `macos/project.yml` and source scans.
- [ ] Swift indexing produces the same row checksums as Node for sessions, costs, tools, files, index jobs, parent link columns, and selected metadata on `tests/fixtures/indexer-parity/fixture-root`.
- [ ] Non-watchable source rescan parity covers Cursor, VS Code, Windsurf, Copilot, 10-minute default polling, `rescan` event payloads, and recoverable index-job triggers.
- [ ] Existing app parser tests, `EngramCoreTests`, and Swift MCP tests still pass.
- [ ] No TypeScript adapter, indexer, daemon, MCP, or app Node-launch code is deleted or disabled by this stage.

## Rollback/abort guidance

Abort Stage 2 and return to Stage 1 when:

- `EngramCoreTests` do not pass before Stage 2 work starts.
- `EngramCoreWrite` boundaries are missing or app/MCP can import write APIs.
- SQLite schema, metadata, FTS, vector, or migration fixtures required by Stage 1 are missing.

Abort Stage 2 and repair Node reference fixtures when:

- `npm test` fails before Swift work begins.
- Generated parity fixtures are nondeterministic on repeated runs.
- `batch-sizes.json` or `detection-version.json` cannot be generated from the Node reference.
- Node and Swift disagree because the Node reference changed intentionally but expected JSON was not regenerated through the approved generator.

Abort Stage 2 and repair Swift implementation when:

- A production write implementation appears outside `macos/EngramCoreWrite`.
- A test double appears in production target membership.
- Swift adapters read the real user HOME in tests instead of injected fixture roots.
- Swift parser limits allow committed >100 MB fixtures or unbounded in-memory parsing.
- Swift indexing throws on ordinary parse failures that Node skips/classifies.
- Live Cascade support cannot reach parity and the unsupported behavior is not recorded as a Stage 2 blocker.

Rollback is file-level before Stage 3 consumes the new APIs:

- Revert Swift adapter/indexer additions from the current branch.
- Keep Node reference files intact.
- Keep generated fixture scripts only if they pass `npm test` and do not change runtime behavior.
- Do not edit user databases as part of rollback; Stage 2 tests must use fixture or temporary DBs.

## Self-review Checklist

- [ ] This plan names every required section: Goal, Scope, Prerequisites, Files to create/modify, Phased tasks, Verification, Acceptance gates, Rollback/abort guidance, and Self-review checklist.
- [ ] Stage 2 is explicitly blocked until Stage 1 passes.
- [ ] The plan keeps all production write APIs in `EngramCoreWrite` and forbids production writes in `EngramService`, app, MCP, CLI, or app/MCP shared paths.
- [ ] The plan allows `IndexingWriteSink` shared request/result shapes but forbids production test doubles and fake sinks in production targets.
- [ ] The plan covers `MessageAdapter`, `SessionAdapter`, `ProjectAdapter`, `InsightAdapter`, `SearchAdapter`, `StatsAdapter`, and the indexing adapter boundary.
- [ ] The plan covers Codex, Claude Code, Gemini CLI, OpenCode, iFlow, Qwen, Kimi, Cline, Cursor, VS Code, Windsurf, Antigravity, Copilot, MiniMax, and LobsterAI behavior.
- [ ] Fixture parity covers successful output and failure classification.
- [ ] The batch-size fixture is named and tied to Swift constants.
- [ ] The parent detection `DETECTION_VERSION` fixture is named and tied to Swift tests.
- [ ] Every phase lists exact file paths, commands, expected output, and failure handling.
- [ ] No task asks workers to delete Node runtime code in Stage 2.
- [ ] No committed fixture file may exceed 5 MB; generated >100 MB and >10,000 message cases run in temporary directories.
- [ ] UI parser compatibility remains separate from indexing parity.
- [ ] The acceptance gates are sufficient for Stage 3 to consume Swift indexing without redesigning the write boundary.
