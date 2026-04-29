# Swift Single Stack Adapters and Indexing Implementation Plan Draft

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Node-owned session adapters, parser fixture coverage, indexing, parent detection, startup backfills, watcher semantics, Gemini sidecars, and Windsurf/Cascade support into Swift with evidence that Swift produces the same normalized rows and failure classifications as the current TypeScript implementation.

**Architecture:** Treat TypeScript as the reference until Stage 5 deletion. Build Swift adapters behind an app/MCP-safe adapter protocol, normalize each source into `SessionInfo`, `Message`, `ToolCall`, and `AuthoritativeSessionSnapshot` equivalents, then send writes through service-only `EngramCoreWrite` indexing components that mirror `SessionSnapshotWriter` and index job dispatch. All parsing is deterministic, bounded, streaming where possible, and fixture-gated for malformed and large inputs before Swift service cutover.

**Tech Stack:** Swift 5.9, XCTest, GRDB, Foundation `FileHandle`, FSEvents/DispatchSource wrappers, URLSession for ConnectRPC JSON, optional generated SwiftProtobuf/gRPC fallback, TypeScript Node 20 reference scripts, Vitest, XcodeGen.

---

## Scope and Dependencies

This draft covers Stage 2 plus the indexing/watch/backfill portions of Stage 3 that are required to prove Stage 2 parity. It is blocked until Stage 1 acceptance passes, including `SchemaManifest`, metadata keys such as parent detection version, read/write module boundaries, and sqlite-vec strategy decision. App/MCP-safe adapter parsing files may live under `macos/Shared/EngramCore/...` during transition, but Stage 2 write-capable indexing files must live under `EngramCoreWrite`. Stage 3 may add `EngramService` server/orchestrator code, but Stage 2 implementers must not place production indexing writers there. Do not put production writers in `macos/Shared`, because `macos/project.yml` currently shares that tree with `Engram`, `EngramMCP`, and `EngramCLI`.

Do not delete or disable any TypeScript source in this unit. Node remains the reference implementation and continues to run `npm test` during verification.

## Reference Files Inspected

- `src/adapters/types.ts` defines `SourceName`, `SessionInfo`, `Message`, `ToolCall`, `TokenUsage`, and `SessionAdapter`.
- `src/adapters/codex.ts`, `claude-code.ts`, `gemini-cli.ts`, `opencode.ts`, `iflow.ts`, `qwen.ts`, `kimi.ts`, `copilot.ts`, `cline.ts`, `cursor.ts`, `vscode.ts`, `antigravity.ts`, `windsurf.ts` define source-specific formats and locators.
- `src/adapters/grpc/cascade-client.ts` defines current Cascade discovery, ConnectRPC JSON calls, inline `.proto` fallback, CSRF metadata, and markdown fallback behavior.
- `macos/Shared/EngramCore/Adapters/Cascade/cascade.proto` must copy the inline proto declaration from `src/adapters/grpc/cascade-client.ts`; do not invent or hand-author a divergent contract.
- `src/core/indexer.ts` defines adapter orchestration, file-size dedup, `resolveProjectName`, stream accumulation, tier computation, title generation hook, parent-link apply, and failure skip behavior.
- `src/core/watcher.ts` defines watched roots, ignored paths, 2s write stability, unlink orphan hook, and project-move skip hook.
- `src/core/parent-detection.ts` defines `DETECTION_VERSION = 4`, dispatch regex/probe detection, candidate scoring, CWD relation, 4h ended-parent window, and best-pick behavior.
- `src/core/session-tier.ts`, `src/core/session-snapshot.ts`, `src/core/session-writer.ts` define tiering, authoritative snapshots, merge/noop semantics, and FTS/embedding job enqueue rules.
- `src/core/daemon-startup.ts`, `src/core/db/maintenance.ts`, `src/core/db/session-repo.ts`, and `src/core/db/metrics-repo.ts` define startup backfill order, parent/suggested-parent maintenance, orphan state machine, cost/tool/file metric upserts, and snapshot SQL.
- `macos/Engram/Core/MessageParser.swift`, `ContentSegmentParser.swift`, `ToolCallParser.swift`, and `StreamingJSONLReader.swift` define the current UI parser subset and streaming JSONL behavior, but they are not full adapter/indexer parity.
- `tests/fixtures` and `macos/EngramTests` define current adapter and parser fixtures, but they do not yet provide a shared Swift adapter parity harness or large/malformed gate matrix.

## File Map

- Create: `macos/Shared/EngramCore/Adapters/SessionAdapter.swift` — Swift protocol and normalized model types equivalent to `src/adapters/types.ts`.
- Create: `macos/Shared/EngramCore/Adapters/AdapterRegistry.swift` — source ordering and root injection matching `src/core/bootstrap.ts`.
- Create: `macos/Shared/EngramCore/Adapters/ParserLimits.swift` — shared parser limits and failure classifications.
- Create: `macos/Shared/EngramCore/Adapters/StreamingLineReader.swift` — production replacement or extracted equivalent of `StreamingJSONLReader` with stable diagnostics.
- Create: `macos/Shared/EngramCore/Adapters/JSONValue.swift` — small JSON helper layer for source adapters.
- Create: `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/OpenCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/IflowAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/QwenAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/KimiAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/ClineAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/VsCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/AntigravityAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/WindsurfAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/CascadeClient.swift` — shared Antigravity/Windsurf client strategy.
- Create: `macos/Shared/EngramCore/Adapters/Cascade/cascade.proto` — checked-in proto source copied from the TypeScript inline definition plus `GetCascadeTrajectory` fields used by ConnectRPC JSON.
- Create: `macos/Shared/EngramCore/Adapters/Cascade/Generated/README.md` — documents generated file ownership if SwiftProtobuf/gRPC fallback is enabled.
- Create: `macos/Shared/EngramCore/Indexing/SwiftIndexer.swift` — Swift equivalent of `src/core/indexer.ts`.
- Create: `macos/Shared/EngramCore/Indexing/IndexingWriteSink.swift` — stable write-sink protocol used by Stage 2 tests and Stage 3 service integration.
- Create: `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift` — Swift equivalent of `src/core/session-writer.ts`; service-only/write-target code, not app/MCP shared code.
- Create: `macos/EngramCoreWrite/Indexing/SessionBatchUpsert.swift` — one-transaction batch writer for sessions, metrics, parent links, and index jobs; service-only/write-target code, not app/MCP shared code.
- Create: `macos/Shared/EngramCore/Indexing/SessionTier.swift` — Swift equivalent of `src/core/session-tier.ts`.
- Create: `macos/Shared/EngramCore/Indexing/ParentDetection.swift` — Swift equivalent of `src/core/parent-detection.ts`.
- Create: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift` — Swift equivalent of the write-capable backfill subset in `src/core/daemon-startup.ts` and `src/core/db/maintenance.ts`; service-only/write-target code, not app/MCP shared code.
- Create: `macos/Shared/EngramCore/Indexing/SessionWatcher.swift` — Swift watcher semantics equivalent to `src/core/watcher.ts`.
- Create: `macos/Shared/EngramCore/Indexing/WatchPathRules.swift` — watched roots and ignore rules.
- Create: `macos/Shared/EngramCore/Indexing/FixtureRoot.swift` — test-only root injection support if not already provided by Stage 1.
- Modify: `macos/project.yml` — include any new files, generated Cascade artifacts, test fixture resources, and optional SwiftProtobuf/gRPC packages.
- Modify: `macos/Engram/Core/MessageParser.swift` — after adapter parity exists, delegate supported source parsing to the shared Swift adapters or remove duplicated parsing logic behind a compatibility wrapper.
- Modify: `macos/Engram/Core/StreamingJSONLReader.swift` — after `StreamingLineReader` exists, keep this as a thin wrapper or move tests to the shared type.
- Modify: `macos/Engram/Core/ToolCallParser.swift` — preserve UI display parser, but do not use it as the indexing tool-call extractor unless parity tests prove it matches `ClaudeCodeAdapter.streamMessages`.
- Create: `macos/EngramTests/AdapterParityTests.swift`
- Create: `macos/EngramTests/IndexerParityTests.swift`
- Create: `macos/EngramTests/ParentDetectionParityTests.swift`
- Create: `macos/EngramTests/StartupBackfillTests.swift`
- Create: `macos/EngramTests/WatcherSemanticsTests.swift`
- Create: `macos/EngramTests/CascadeClientTests.swift`
- Create: `scripts/gen-adapter-parity-fixtures.ts` — Node reference exporter for normalized adapter output and failure classifications.
- Create: `scripts/check-adapter-parity-fixtures.ts` — validates golden freshness, file-size policy, and malformed fixture matrix completeness.
- Create: `tests/fixtures/adapter-parity/<source>/*.input.*` — source inputs copied or minimized from existing fixtures.
- Create: `tests/fixtures/adapter-parity/<source>/*.expected.json` — Node-generated normalized snapshots and messages.
- Create: `tests/fixtures/adapter-malformed/<case>/manifest.json` — malformed/large generated-case manifests; do not commit a real >100 MB file.
- Create: `tests/fixtures/indexer-parity/fixture-root/...` — synthetic multi-source HOME tree for indexing row parity.
- Create: `tests/fixtures/indexer-parity/expected-db-checksums.json` — Node-generated row checksums for Swift parity.

## Normalized Contracts

- `SessionInfo` must include the same public fields and semantics as `src/adapters/types.ts`: source, id, timestamps, cwd, project, model, message counts, summary, file path/source locator, size bytes, origin, tier inputs, parent/suggested parent fields, agent role, and originator.
- `Message` must include role, content, timestamp, tool calls, and token usage. The indexer must skip system-injection messages from user counts exactly where Node adapters do.
- `ToolCall` extraction must preserve Node behavior: count every tool call by name, stringify tool input with the same 500-character cap where Node does, and extract absolute `file_path` only for `Read`, `Edit`, `Write`, `read_file`, `edit_file`, and `write_file`.
- `ParserFailure` must be stable and testable. Required categories: `fileMissing`, `fileTooLarge`, `invalidUtf8`, `truncatedJSON`, `truncatedJSONL`, `malformedJSON`, `malformedToolCall`, `deeplyNestedRecord`, `messageLimitExceeded`, `lineTooLarge`, `fileModifiedDuringParse`, `sqliteUnreadable`, `grpcUnavailable`, `unsupportedVirtualLocator`.
- Successful adapters may skip malformed records as Node does, but the harness must still record failure classifications for malformed fixture cases so parity includes errors, not just happy-path rows.

## Parser Limits and Gates

- Maximum committed fixture file size: 5 MB. The >100 MB gate must generate a sparse or temporary file during the Swift test and Node reference test, then delete it.
- Production parser hard skip threshold: any single session source file or resolved virtual payload over 100 MB returns no session and records `fileTooLarge`.
- JSONL line threshold: keep the existing 8 MB max-line behavior from `StreamingJSONLReader`; oversized lines are skipped with `lineTooLarge`.
- Message cap: parse at most 10,000 normalized conversation messages per session. Before Swift implementation, add a generated Node reference case for >10k messages and commit its observed behavior to `tests/fixtures/adapter-malformed/message-limit/expected-node-behavior.json`; Swift must then copy that recorded behavior exactly. If Node indexes/truncates, preserve the first 10,000 for count parity mode; if Node skips, classify as `messageLimitExceeded`.
- File modified during parse: capture `(size, mtime, inode/fileResourceIdentifier if available)` before and after parse. If any changed, abort the session with `fileModifiedDuringParse` and let watcher/debounce retry.
- Invalid UTF-8: JSONL line reader skips invalid lines and records `invalidUtf8`; whole-file JSON adapters (`gemini-cli`, `cline`, VS Code line-0) must return no session with `invalidUtf8` when the payload cannot be decoded.
- Truncated JSON/JSONL: JSONL adapters skip bad lines for normal source drift, but the malformed fixture harness must include a case where required metadata appears only in the truncated line and the adapter returns no session with `truncatedJSONL`; whole-file JSON adapters return no session with `truncatedJSON`.
- Malformed tool calls: assistant/user messages still stream, but malformed tool-call input must not crash cost/file metric extraction and must not emit a `session_files` row.
- Deeply nested records: generate nested JSON/JSONL payloads that exceed the parser's configured nesting limit and assert deterministic `deeplyNestedRecord` failure instead of stack overflow, hang, or partial indexing.

## Task 1: Build Node Reference Goldens Before Swift Ports

**Files:**
- Create: `scripts/gen-adapter-parity-fixtures.ts`
- Create: `scripts/check-adapter-parity-fixtures.ts`
- Create/modify fixtures under `tests/fixtures/adapter-parity/**`
- Create/modify manifests under `tests/fixtures/adapter-malformed/**`
- Modify: `package.json`

- [ ] Add `gen-adapter-parity-fixtures.ts` that imports every TypeScript adapter from `src/adapters/*`, runs `parseSessionInfo` and `streamMessages` against fixture inputs, and writes deterministic JSON with sorted object keys.
- [ ] The generated JSON shape must include `source`, `inputPath`, `sessionInfo`, `messages`, `toolCalls`, `usageTotals`, `fileToolCounts`, `failure`, and `nodeVersion`.
- [ ] Support injected roots for filesystem adapters so fixture paths are stable: Codex sessions root, Claude projects root, Gemini tmp root + projects file, Kimi sessions root + `kimi.json`, Copilot root, Cline tasks root, Windsurf/Antigravity cache roots, Cursor `state.vscdb`, OpenCode `opencode.db`, VS Code workspace storage root.
- [ ] Add `check-adapter-parity-fixtures.ts` to fail when any supported source lacks at least one success golden and when any required malformed case is missing.
- [ ] Add package scripts:
  - `generate:adapter-parity-fixtures`
  - `check:adapter-parity-fixtures`
- [ ] Generate baseline goldens for existing fixtures first; do not invent Swift expectations.
- [ ] Verify:
  - `npm run generate:adapter-parity-fixtures`
  - `npm run check:adapter-parity-fixtures`
  - `npm test -- tests/adapters tests/core/indexer.test.ts tests/core/parent-detection.test.ts`

## Task 2: Create Shared Swift Adapter Model and Harness

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/SessionAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/AdapterRegistry.swift`
- Create: `macos/Shared/EngramCore/Adapters/ParserLimits.swift`
- Create: `macos/Shared/EngramCore/Adapters/StreamingLineReader.swift`
- Create: `macos/Shared/EngramCore/Adapters/JSONValue.swift`
- Create: `macos/EngramTests/AdapterParityTests.swift`
- Modify: `macos/project.yml`

- [ ] Define Swift model names that map one-to-one to Node concepts: `SourceName`, `NormalizedSessionInfo`, `NormalizedMessage`, `NormalizedToolCall`, `TokenUsage`, `StreamMessagesOptions`, `AdapterParseResult`, `ParserFailure`.
- [ ] Define `SessionAdapter` with async `detect()`, async throwing `listSessionLocators()`, `parseSessionInfo(locator:)`, `streamMessages(locator:options:)`, and `isAccessible(locator:)`.
- [ ] Add fixture-root initializers for every adapter. Do not hardcode the real user HOME in tests.
- [ ] Extract or wrap `StreamingJSONLReader` into `StreamingLineReader` so adapter tests can inspect diagnostics instead of only getting strings.
- [ ] Add `AdapterParityTests` that loads every `tests/fixtures/adapter-parity/<source>/*.expected.json`, runs the matching Swift adapter, and compares normalized `sessionInfo`, `messages`, usage totals, and failure classifications.
- [ ] Keep `MessageParserTests` passing by leaving current UI parser behavior in place until the adapter layer is complete.
- [ ] Verify:
  - `cd macos && xcodegen generate`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/StreamingJSONLReaderTests`

## Task 3: Port JSONL Filesystem Adapters First

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/IflowAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/QwenAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift`
- Create/modify: `tests/fixtures/adapter-parity/{codex,claude-code,iflow,qwen,copilot}/**`
- Modify: `macos/EngramTests/AdapterParityTests.swift`

- [ ] Port Codex: `session_meta`, `response_item` message extraction, `originator`, effective `agentRole = dispatched` when `originator === "Claude Code"`, system-injection count, `model_provider`, file-size dedup input, and offset/limit streaming.
- [ ] Port Claude Code: project root walking including nested `subagents`, `agentId` as DB id for subagents, parent id from path, source remapping for Qwen/Kimi/Gemini/MiniMax/LobsterAI by model/path, tool result counts, token usage, `tool_use` extraction, image placeholder text, noise tool filtering for rendered content, and `decodeCwd` parity including current ambiguity.
- [ ] Port iFlow: project directory walk, `session-*.jsonl`, `sessionId`, CWD, start/end timestamps, system-injection detection, and text-array extraction.
- [ ] Port Qwen: `message.parts[].text`, Qwen system prompt filtering, model extraction, and chats directory traversal.
- [ ] Port Copilot: `session-state/<uuid>/events.jsonl`, `workspace.yaml` key-value metadata, `session.start` CWD fallback, `user.message`/`assistant.message`, and summary precedence.
- [ ] Add malformed cases for each adapter:
  - invalid UTF-8 line
  - truncated JSONL metadata line
  - deeply nested JSON/JSONL record that returns `deeplyNestedRecord`
  - malformed tool call input for Claude Code
- [ ] Add explicit Claude-format success fixtures whose expected normalized `source` is `minimax` and `lobsterai`.
  - file modified during parse
  - generated >100 MB file gate
  - generated >10k messages gate
- [ ] Verify adapter parity source-by-source before moving to whole-file or SQLite adapters:
  - `npm run generate:adapter-parity-fixtures`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests`

## Task 4: Port Whole-File and Multi-File Adapters

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/KimiAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/ClineAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/VsCodeAdapter.swift`
- Create/modify: `tests/fixtures/adapter-parity/{gemini-cli,kimi,cline,vscode}/**`
- Modify: `macos/EngramTests/AdapterParityTests.swift`

- [ ] Port Gemini CLI whole-file JSON parsing: `sessionId`, `projectHash`, `startTime`, `lastUpdated`, `messages`, `type=user|gemini|model`, content string or text parts, `projects.json` reverse lookup, and project name from `.../tmp/<project>/chats/session-*.json`.
- [ ] Add Gemini sidecar support exactly matching Node: read `{sessionId}.engram.json` beside the session file, set `parentSessionId`, `originator`, and `agentRole = dispatched` when originator is `claude-code`; missing or malformed sidecar must not fail the session.
- [ ] Port Kimi: session id from `sessions/<workspace>/<session>/context.jsonl`, CWD from `kimi.json` by `last_session_id`, timestamp scan from `wire.jsonl`, include `context_sub_N.jsonl` sorted numerically, skip `_checkpoint`, and size as total of all context files.
- [ ] Port Cline: `ui_messages.json`, task id from parent dir, `say=task|user_feedback|text`, skip partial assistant messages, CWD extraction from `api_req_started` JSON text.
- [ ] Port VS Code: `workspaceStorage/*/chatSessions/*.jsonl`, first line `kind:0`, `v.requests`, user text from `message.text` or `parts`, assistant markdown content from response array, id fallback to basename.
- [ ] Add malformed cases:
  - invalid UTF-8 whole-file JSON
  - truncated JSON
  - Gemini sidecar with malformed JSON
  - Kimi missing `wire.jsonl` and missing sub context file
  - Cline non-array JSON
  - VS Code first line malformed with later valid lines ignored
- [ ] Verify:
  - `npm run generate:adapter-parity-fixtures`
  - `npm run check:adapter-parity-fixtures`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests`

## Task 5: Port SQLite and Virtual Locator Adapters

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/Sources/OpenCodeAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift`
- Create/modify: `tests/fixtures/adapter-parity/{opencode,cursor}/**`
- Modify: `macos/EngramTests/AdapterParityTests.swift`
- Modify: `macos/project.yml` if these files require extra GRDB visibility in the shared module

- [ ] Port OpenCode virtual locators with the exact `dbPath::sessionId` format, read-only GRDB access, session query excluding archived sessions, message/part join ordering, text part extraction, DB file size as `sizeBytes`, and `isAccessible` via session existence.
- [ ] Port Cursor virtual locators with the exact `dbPath?composer=<id>` format, read-only GRDB access to `cursorDiskKV`, new `composerData:<id>.conversation` format first, old `bubbleId:<composerId>:%` fallback ordered by `rowid`, `type` 1/2 mapping, text/rawText extraction, timing timestamp, and `isAccessible` via `composerData` key.
- [ ] Add fixture DBs that cover both Cursor new and old formats plus malformed JSON rows that must be skipped.
- [ ] Ensure file-size dedup for virtual locators is based on the backing DB size where Node does so and does not call filesystem `stat` on the virtual locator string.
- [ ] Verify:
  - `npm test -- tests/adapters/opencode.test.ts tests/adapters/cursor.test.ts`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests`

## Task 6: Port Antigravity and Windsurf Cache Adapters

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/Sources/AntigravityAdapter.swift`
- Create: `macos/Shared/EngramCore/Adapters/Sources/WindsurfAdapter.swift`
- Create/modify: `tests/fixtures/adapter-parity/{antigravity,windsurf}/**`
- Modify: `macos/EngramTests/AdapterParityTests.swift`

- [ ] Port cache-mode parsing first because it is deterministic and does not need a live language server.
- [ ] Antigravity cache metadata must include `id`, `title`, `summary`, `createdAt`, `updatedAt`, optional `cwd`, optional `pbSizeBytes`, skip first line, count messages, prefer `.pb` size over cache size, and infer CWD from `/Users/<user>/-Code-/<project>` occurrences when missing.
- [ ] Windsurf cache metadata must include `id`, `title`, `createdAt`, `updatedAt`, skip first line, count messages, and use cache file size.
- [ ] Preserve markdown fallback behavior for both sources: split on `## User`, `## Assistant`, or `## Cascade` sections and drop empty sections.
- [ ] Add cache malformed cases:
  - malformed metadata first line returns no session
  - malformed message line is skipped
  - meta-only cache is accepted only if Node accepts it
  - missing `.pb` for Antigravity falls back to cache size
- [ ] Verify cache parity:
  - `npm test -- tests/adapters/antigravity.test.ts tests/adapters/windsurf.test.ts`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests`

## Task 7: Implement Cascade ConnectRPC and Protobuf Strategy

**Files:**
- Create: `macos/Shared/EngramCore/Adapters/Cascade/CascadeClient.swift`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/CascadeDiscovery.swift`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/cascade.proto`
- Create: `macos/Shared/EngramCore/Adapters/Cascade/Generated/README.md`
- Create: `macos/EngramTests/CascadeClientTests.swift`
- Modify: `macos/project.yml`
- Modify: `macos/Shared/EngramCore/Adapters/Sources/AntigravityAdapter.swift`
- Modify: `macos/Shared/EngramCore/Adapters/Sources/WindsurfAdapter.swift`

- [ ] Use cache mode as the always-on default and make live Cascade sync best-effort, matching Node’s “app not running, use existing cache” behavior.
- [ ] Implement discovery in two layers:
  - process discovery for Antigravity 1.18+ by scanning `ps aux`, extracting `--csrf_token`, excluding `--extension_server_port`, and probing candidate listening ports;
  - daemon-dir JSON discovery for older Antigravity and Windsurf by reading the newest `*.json` containing `httpPort` and `csrfToken`.
- [ ] Implement ConnectRPC JSON with `URLSession` as the primary Swift path for:
  - `GetAllCascadeTrajectories`
  - `GetCascadeTrajectory`
  - `ConvertTrajectoryToMarkdown`
- [ ] Keep the `.proto` checked in even if the first implementation does not compile generated gRPC code, because it documents the current Node inline proto and prevents accidental contract drift.
- [ ] Add generated SwiftProtobuf/gRPC fallback only if live-source parity requires it after ConnectRPC JSON tests. Decision deadline: after fake ConnectRPC tests and the opt-in live smoke are implemented, compare returned message count, metadata fields, markdown fallback behavior, and attachment/tool-call fields against Node; if any required field is missing solely because JSON transport cannot expose it, either add the gRPC fallback in this task or mark live Cascade sync blocked and do not claim Stage 2 exit.
- [ ] Preserve Antigravity `.pb` backfill behavior: after `GetAllCascadeTrajectories`, scan the local trajectory `.pb` cache directory for sessions not returned by the recent live API and parse them through the same cache/fallback path.
- [ ] Tests must not require a real Antigravity/Windsurf process. Add a local fake ConnectRPC HTTP server inside `CascadeClientTests` that returns JSON matching Node’s expected fields and validates the CSRF header.
- [ ] Add an opt-in live smoke test guarded by `ENGRAM_LIVE_CASCADE_TEST=1`; it must be skipped by default.
- [ ] Acceptance gate: if ConnectRPC JSON cannot produce full message parity for supported live sources, mark Windsurf/Antigravity live sync as blocked and do not claim Stage 2 exit. Cache-mode parity alone is not enough unless the product explicitly narrows live sync support in the Stage 2 review.

## Task 8: Port Parent Detection and Link Backfills

**Files:**
- Create: `macos/Shared/EngramCore/Indexing/ParentDetection.swift`
- Create: `macos/EngramTests/ParentDetectionParityTests.swift`
- Create: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Create: `macos/EngramTests/StartupBackfillTests.swift`
- Create/modify: `tests/fixtures/indexer-parity/parent-detection/**`

- [ ] Port `DETECTION_VERSION = 4` and every dispatch/probe regex from `src/core/parent-detection.ts`.
- [ ] Generate `tests/fixtures/parent-detection/detection-version.json` from `src/core/parent-detection.ts`, then add a parity test that compares the Swift constant against that snapshot. During Stages 2-4, a helper may also compare the snapshot back to TypeScript; after Stage 5, tests must not require deleted TypeScript source.
- [ ] Preserve empty-message behavior: empty or whitespace-only first message counts as dispatched.
- [ ] Preserve probe matching for `ping`, math questions, `say hello`, `say exactly`, `echo`, `reply/respond with`, and the current exclusions for normal “say more” questions.
- [ ] Preserve CWD relation scoring: exact, nested, unrelated, unknown.
- [ ] Preserve candidate scoring:
  - agent starts before parent returns 0
  - ended parent with unrelated/unknown CWD returns 0
  - ended parent with same/nested CWD is allowed only when gap is under 4h
  - time half-life is 4h
  - project match weight is 0.3
  - active bonus semantics match Node
- [ ] Preserve `pickBestCandidate`: return highest positive score even when close; return nil for empty or all-zero candidates.
- [ ] Port startup parent/link backfills:
  - `downgradeSubagentTiers`
  - `backfillParentLinks`
  - `resetStaleDetections`
  - `backfillCodexOriginator`
  - `backfillSuggestedParents`
- [ ] Preserve manual-link safety: never overwrite `link_source = manual`.
- [ ] Tests must include direct TypeScript parity cases from `tests/core/parent-detection.test.ts` plus DB-level fixtures for path-based subagent links, Gemini sidecar links, Codex originator links, stale detection reset, and no-parent dispatched sessions.
- [ ] Verify:
  - `npm test -- tests/core/parent-detection.test.ts`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ParentDetectionParityTests -only-testing:EngramTests/StartupBackfillTests`

## Task 9: Port Session Tier, Snapshot Writer, Metrics Extraction, and Batch Upsert

**Files:**
- Create: `macos/Shared/EngramCore/Indexing/SessionTier.swift`
- Create: `macos/Shared/EngramCore/Indexing/IndexingWriteSink.swift`
- Create: `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift`
- Create: `macos/EngramCoreWrite/Indexing/SessionBatchUpsert.swift`
- Create: `macos/Shared/EngramCore/Indexing/SwiftIndexer.swift`
- Create: `macos/EngramTests/IndexerParityTests.swift`
- Create/modify: `tests/fixtures/indexer-parity/**`

- [ ] Port `computeTier` exactly: preamble-only skip, probes path skip, any `agentRole` skip, `/subagents/` skip, `messageCount <= 1` skip, no-reply lite when assistant/tool counts are explicitly zero, premium thresholds, noise summary lite, normal fallback.
- [ ] Port authoritative snapshot creation:
  - `authoritativeNode` default `local`
  - sync payload fields and SHA-256 hash over JSON-equivalent payload
  - first three user messages for preamble detection
  - assistant/tool counts for tiering
  - `sourceLocator`, `sizeBytes`, timestamps, origin, tier, and agent role
- [ ] Port merge/noop semantics from `src/core/session-merge.ts` and job enqueue rules from `SessionSnapshotWriter`: FTS for non-skip searchable changes; embedding for normal/premium embedding changes.
- [ ] Port cost/tool/file extraction:
  - always write a `session_costs` row, including zero-token sessions
  - compute costs using the existing pricing logic after Stage 1 pricing parity is available
  - upsert `session_tools`
  - upsert `session_files` only for absolute `file_path` values from supported file tools
  - skip malformed tool-call JSON silently
- [ ] Implement `SessionBatchUpsert` as the default writer for Swift indexing:
  - conform to `IndexingWriteSink` with one async method: `upsertBatch(_ snapshots: [AuthoritativeSessionSnapshot], reason: IndexingWriteReason) async throws -> SessionBatchUpsertResult`
  - `SessionBatchUpsertResult` must contain per-session `indexed`, `noop`, `skipped`, `failure`, `enqueuedJobs`, and event-payload details needed by Stage 3 service events
  - Stage 2 tests may use a test double for `IndexingWriteSink`, but the double must live in tests and must use the same request/result structs as production `SessionBatchUpsert`
  - test doubles must be excluded from production targets, and acceptance must scan `macos/project.yml` plus source paths to prove no `TestIndexingWriteSink` or equivalent shim is compiled into `Engram`, `EngramMCP`, `EngramCLI`, or `EngramService`
  - Stage 3 service must consume the same protocol and result structs without redesigning the indexing write interface
  - one GRDB write transaction per batch
  - default batch size 100 sessions for `indexAll`
  - batch size 1 for watcher-triggered `indexFile`
  - write sessions, local state readable path, costs, tools, files, parent links, and index jobs in one transaction
  - return per-session indexed/noop/skipped result details for events and tests
- [ ] Capture Node-derived batch constants in `tests/fixtures/adapter-parity/batch-sizes.json`, including watcher changed-path drain size and session DB transaction batch size. Swift must use those values; do not change batch sizes based on ad hoc measurements without updating the fixture through a reviewed Node-reference run.
- [ ] Preserve TypeScript dedup semantics:
  - real files skip when DB `sizeBytes` matches file stat size
  - Antigravity may dedup against `info.sizeBytes` when `.pb` size differs from cache file size
  - virtual locators skip direct stat and attempt parse
- [ ] `SwiftIndexer.indexAll` must continue after unprocessable files and log/classify failures; `SwiftIndexer.indexFile` must return `indexed = false` instead of throwing for parse failures.
- [ ] Add DB checksum parity tests comparing Swift output against Node-generated `expected-db-checksums.json` for `sessions`, `session_costs`, `session_tools`, `session_files`, `index_jobs`, parent link columns, and selected metadata.
- [ ] Verify:
  - `npm test -- tests/core/indexer.test.ts tests/core/session-tier.test.ts tests/core/sync.test.ts`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/IndexerParityTests`

## Task 10: Port Startup Backfill Ordering and Events

**Files:**
- Modify: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Create/modify: `macos/EngramTests/StartupBackfillTests.swift`
- Create/modify: `tests/fixtures/indexer-parity/startup-backfills/**`

- [ ] Port the startup sequence from `runInitialScan` without starting Swift service integration yet:
  - `indexAll`
  - `backfillCounts`
  - `backfillCosts`
  - `backfillScores`
  - `deduplicateFilePaths`
  - `optimizeFts`
  - `vacuumIfNeeded(15)`
  - `reconcileInsights`
  - `backfillFilePaths`
  - `downgradeSubagentTiers`
  - `backfillParentLinks`
  - `resetStaleDetections`
  - `backfillCodexOriginator`
  - `backfillSuggestedParents`
  - `cleanupStaleMigrations`
  - ready event count calculation
  - background orphan scan
  - recoverable index job run
  - insight embedding backfill
- [ ] For any backfill owned by another plan unit, add a typed dependency and a no-op test double here; do not silently omit it from the event sequence.
- [ ] Add a typed dependency for usage collection start after ready/orphan scan/index-job recovery, or implement `usageCollector.start` in the service plan and assert the event-order handoff.
- [ ] Preserve emitted event names and payload fields for UI compatibility: `backfill_counts`, `backfill`, `db_maintenance`, `migration_cleanup`, `ready`, `orphan_scan`, `index_jobs_recovered`, `insights_promoted`.
- [ ] Startup tests must assert both DB effects and event ordering.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/StartupBackfillTests`

## Task 11: Implement Swift Watcher Semantics

**Files:**
- Create: `macos/Shared/EngramCore/Indexing/WatchPathRules.swift`
- Create: `macos/Shared/EngramCore/Indexing/SessionWatcher.swift`
- Create: `macos/EngramTests/WatcherSemanticsTests.swift`

- [ ] Match `getWatchEntries` roots exactly:
  - `~/.codex/sessions` -> `codex`
  - `~/.claude/projects` -> `claude-code`
  - `~/.gemini/tmp` -> `gemini-cli`
  - `~/.gemini/antigravity` -> `antigravity`
  - `~/.iflow/projects` -> `iflow`
  - `~/.qwen/projects` -> `qwen`
  - `~/.kimi/sessions` -> `kimi`
  - `~/.cline/data/tasks` -> `cline`
- [ ] Preserve watched source set: Codex, Claude Code, Gemini CLI, Antigravity, iFlow, Qwen, Kimi, Cline, and derived Claude-directory sources LobsterAI/MiniMax.
- [ ] Preserve ignored paths and add Swift tests for them:
  - `.gemini/tmp/<proj>/tool-outputs/`
  - `.vite-temp/`
  - `.engram-tmp-`
  - `.engram-move-tmp-`
  - `node_modules/`
  - `.DS_Store`
- [ ] Implement recursive macOS watching with no symlink following. Prefer FSEvents for recursive directories; use `DispatchSourceFileSystemObject` only for narrow file-level tests or fallback directories.
- [ ] Implement write-stability semantics equivalent to chokidar `awaitWriteFinish`: wait 2 seconds of unchanged `(size, mtime)` with 500 ms polling before indexing.
- [ ] Add a write-stability reset test: append or rewrite the file before the 2-second window expires, assert the timer restarts, and assert indexing occurs only after the final unchanged `(size, mtime)` window.
- [ ] Implement debounce and batching:
  - coalesce duplicate add/change events for the same path
  - maximum batch size 500 paths per drain
  - if more than 500 paths arrive, drain in FIFO chunks and emit progress
- [ ] Implement rename semantics:
  - directory rename triggers rescan of new subtree
  - file rename appears as unlink + add; call `shouldSkip` for both while project move is active
  - unlink marks rows by `file_path` or `source_locator` as orphan suspect with reason `cleaned_by_source`
- [ ] Implement symlink target change semantics: because Node has `followSymlinks: false`, target changes behind a symlink must not trigger indexing unless the symlink file itself changes.
- [ ] Implement permission revocation semantics: watcher logs/classifies permission errors, keeps running for other roots, and does not delete sessions.
- [ ] Implement rapid append/delete semantics: if a file is appended then deleted before stability passes, do not index it; mark orphan only if it previously existed in DB.
- [ ] Add non-watchable rescan parity tests owned jointly with the service plan: verify 10-minute interval configuration, `rescan` event payload, skipped watch roots, and recoverable index-job trigger after each rescan.
- [ ] Tests must use temporary HOME roots and a fake indexer/writer; they must not read real user session roots.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/WatcherSemanticsTests`

## Task 12: Wire Swift Adapters into Current UI Parser Without Behavioral Regression

**Files:**
- Modify: `macos/Engram/Core/MessageParser.swift`
- Modify: `macos/Engram/Core/StreamingJSONLReader.swift`
- Modify: `macos/Engram/Core/ToolCallParser.swift`
- Modify: `macos/EngramTests/MessageParserTests.swift`
- Modify: `macos/EngramTests/StreamingJSONLReaderTests.swift`

- [ ] Keep existing UI parser tests green before replacing internals.
- [ ] Route `MessageParser.parse(filePath:source:)` through the new Swift adapter registry for sources that have parity coverage.
- [ ] Preserve `SystemCategory` classification for UI display. If shared adapters classify system messages differently, add a UI-only mapping layer rather than changing indexing counts.
- [ ] Keep `ContentSegmentParser` unchanged unless tests show rendered transcript differences.
- [ ] Keep `ToolCallParser` as a UI formatter; indexing metrics must use adapter `toolCalls`, not regex display parsing.
- [ ] Add regression tests for current UI-specific cases: CJK, system prompts, empty content, malformed lines, unknown source, nonexistent file.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/MessageParserTests -only-testing:EngramTests/StreamingJSONLReaderTests`

## Task 13: Full Parity and Acceptance Gates

**Files:**
- Modify/create all files listed above
- Modify: `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md` only in a later coordination pass if implementation discovers a spec-changing unsupported source; do not modify the spec inside this draft execution.

- [ ] Run Node reference checks:
  - `npm run generate:adapter-parity-fixtures`
  - `npm run check:adapter-parity-fixtures`
  - `npm test`
  - `npm run lint`
- [ ] Run Swift focused checks:
  - `cd macos && xcodegen generate`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/AdapterParityTests`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/IndexerParityTests`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/ParentDetectionParityTests`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/StartupBackfillTests`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/WatcherSemanticsTests`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS' -only-testing:EngramTests/CascadeClientTests`
- [ ] Run Swift broad checks:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS'`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'`
- [ ] Acceptance gate: every supported source has at least one success parity golden and all required malformed gates.
- [ ] Acceptance gate: Swift indexing produces the same row checksums as Node on `tests/fixtures/indexer-parity/fixture-root`.
- [ ] Acceptance gate: parent detection direct unit cases match Node and DB backfill fixtures prove path, sidecar, Codex originator, stale reset, and suggested-parent behavior.
- [ ] Acceptance gate: watcher tests prove debounce interval, maximum batch size, rename handling, symlink target changes, directory renames, permission revocation, rapid append/delete cycles, duplicate-event suppression, and project-move skip semantics.
- [ ] Acceptance gate: no committed fixture file exceeds 5 MB; generated >100 MB and >10k message tests run in temp directories only.
- [ ] Acceptance gate: live Cascade sync remains optional and skipped by default, but cache-mode Antigravity/Windsurf parity is always tested. If live sync is still unsupported, Stage 2 exit must explicitly record that risk before Node deletion can proceed.

## Execution Order

1. Generate Node adapter goldens and malformed manifests first; all Swift work depends on these reference outputs.
2. Add shared Swift adapter models and harness without changing UI parser behavior.
3. Port JSONL filesystem adapters because they exercise streaming, tool calls, usage, system filtering, and subagent paths.
4. Port whole-file and multi-file adapters, including Gemini sidecars.
5. Port SQLite virtual locator adapters.
6. Port Antigravity/Windsurf cache parsing, then Cascade live-sync strategy.
7. Port parent detection and startup link backfills.
8. Port session tier, snapshot writer, metrics extraction, indexer, and batch upsert.
9. Port startup backfill sequencing and watcher semantics.
10. Only after adapter/indexer parity is green, route current UI message parsing through the shared adapter layer.

## Residual Risks

- Swift gRPC package/build integration may be heavier than the value of live Cascade fallback. ConnectRPC JSON should be proven first; if it is enough, keep gRPC generated files out of the shipping build and retain only the `.proto` contract.
- Node and Swift JSON serialization can differ in key ordering and timestamp parsing. Goldens must compare normalized semantic fields, not raw object byte strings, except for explicitly stable checksum files.
- >10k message behavior is not clearly defined in current Node code until `tests/fixtures/adapter-malformed/message-limit/expected-node-behavior.json` is generated; Swift implementation must follow that artifact rather than make a fresh subjective decision.
- File-modified-during-parse detection is stricter than Node’s current behavior. This is acceptable for safety only if watcher retry tests prove the session indexes after writes stabilize.
- UI `MessageParser` currently supports display-only transformations that are not identical to adapter stream content. Keep UI tests separate from indexing parity tests so display compatibility and DB parity do not mask each other.
- Existing dirty worktree changes outside this draft must not be touched while implementing this section.
