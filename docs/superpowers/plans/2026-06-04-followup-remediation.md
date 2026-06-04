# Follow-up Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the post-review backlog that was intentionally left outside PR #34: Swift Gemini transcript memory risk, service secret flow, Swift MCP `get_context` parity, CLI coverage, CI security hardening, P3 cleanup, and full Swift verification.

**Architecture:** Keep the work in `followups/full-remediation`, based on PR #34 head. Each task adds a failing verifier first, then production code, then focused tests and the relevant CI gate. Broad design changes are split by subsystem so one fix does not hide another.

**Tech Stack:** TypeScript/Vitest/Biome/Knip, Swift/XCTest/XcodeGen, GitHub Actions, SQLite/GRDB, macOS Keychain and Unix-socket service IPC.

---

### Task 1: Swift Gemini Transcript Size Guard

**Files:**
- Modify: `macos/EngramMCP/Core/MCPTranscriptReader.swift`
- Modify: `macos/EngramService/Core/TranscriptExportService.swift`
- Test: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Test: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`

- [x] **Step 1: Write failing tests**

Add tests that create a `gemini-cli` JSON transcript larger than the configured safe read limit and prove MCP `get_session` and service export return a bounded error instead of loading the entire file.

- [x] **Step 2: Verify RED**

Run the new targeted XCTest commands and confirm they fail because the current parsers call `Data(contentsOf:)`/`JSONSerialization` on the whole file.

- [x] **Step 3: Implement guard**

Introduce a shared Swift transcript file-size guard with an explicit default cap. `gemini-cli` full-object JSON keeps using a full parse only below the cap; oversized files return a user-visible error/status instead of allocating.

- [x] **Step 4: Verify GREEN**

Run the targeted MCP and service tests. Then run the full `EngramMCPTests` and affected service-core suite.

- [x] **Step 5: Commit**

Committed in `fix: close post-review followup findings`.

### Task 2: Service Secret Flow Refactor

**Files:**
- Modify: `macos/Engram/Core/EngramServiceLauncher.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Modify: `macos/Engram/Views/Settings/SettingsIO.swift`
- Test: `macos/EngramTests/EngramServiceLauncherTests.swift`
- Test: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`

- [x] **Step 1: Write failing tests**

Add a launcher test proving service process environment no longer contains raw `aiApiKey` or `titleApiKey` values. Add service command handler tests proving `@keychain` resolution happens via an injected key provider rather than `ENGRAM_KEYCHAIN_*` environment variables.

- [ ] **Step 2: Verify RED**

Run targeted launcher and service IPC tests. Confirm failures show raw key env injection and env-only key resolution.

- [x] **Step 3: Implement key-provider path**

Move Keychain reads behind a small testable provider. The app launcher must not put secret values into child environment. The service-side settings resolver must read Keychain directly when settings contain `@keychain`, with env fallback only for test override names that cannot contain raw user secrets in production.

- [x] **Step 4: Verify GREEN**

Run targeted tests, then run `EngramTests/EngramServiceLauncherTests` and service-core IPC tests touching AI/title settings.

Current audit note: RED was not replayed because the working tree already contains both the regression tests and implementation. GREEN was verified with the launcher raw-secret environment test and three service-core settings tests.

- [x] **Step 5: Commit**

Committed in `fix: close post-review followup findings`.

### Task 3: Swift MCP `get_context` Environment Parity

**Files:**
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Test: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Fixture: `macos/EngramMCPTests/Fixtures/mcp-golden/get_context.*.json`

- [x] **Step 1: Write failing tests**

Add golden assertions that Swift `get_context(include_environment:true)` includes the same major TS environment blocks: live-session unavailable note, today's cost summary, active alerts, recent tool usage, dirty/unpushed git repos, file hotspots, recent errors, and cost suggestions where fixture data supports them. Keep `abstract` mode limited to cost and alerts.

- [x] **Step 2: Verify RED**

Run the targeted MCP executable test and confirm the golden lacks the new blocks.

- [x] **Step 3: Implement parity blocks**

Add bounded SQL helpers matching TS semantics and ordering. Make unsupported live-session monitoring explicit, not silent.

- [x] **Step 4: Verify GREEN**

Run targeted MCP executable tests and regenerate only the intended golden fixtures.

- [x] **Step 5: Commit**

Committed in `fix: close post-review followup findings`.

### Task 4: CLI Coverage for Project and Resume

**Files:**
- Modify: `src/cli/project.ts`
- Modify: `src/cli/resume.ts`
- Test: `tests/cli/project.test.ts`
- Test: `tests/cli/resume.test.ts`

- [x] **Step 1: Write failing tests**

Add tests for project CLI flag parsing, dry-run output formatting, archive category passing, batch load error handling, and resume session selection/invalid selection/daemon-unavailable behavior. Prefer dependency injection over spawning real processes.

- [x] **Step 2: Verify RED**

Run the new CLI tests and confirm failures are from missing exports/injection seams.

- [x] **Step 3: Implement testable seams**

Export pure helpers and accept injected DB/fetch/stdin/stdout/spawn functions without changing the user-facing CLI commands.

- [x] **Step 4: Verify GREEN**

Run new CLI tests, then `npm run test:coverage` to ensure the global threshold has real margin.

- [x] **Step 5: Commit**

Committed in `fix: close post-review followup findings`.

### Task 5: CI Security Hardening

**Files:**
- Modify: `.github/workflows/test.yml`
- Possibly create: `.github/workflows/codeql.yml`

- [x] **Step 1: Add CI verifier**

Add a no-secret security gate that can run on public PRs: CodeQL for JavaScript/TypeScript and Swift if supported by the action matrix, or a documented fallback if Swift is unavailable.

- [x] **Step 2: Verify locally where possible**

Run YAML syntax checks and `actionlint` if available. If `actionlint` is absent, run a bounded workflow grep/schema sanity check and rely on GitHub Actions for final validation.

- [x] **Step 3: Commit**

Committed in `chore(ci): add code scanning workflow`.

### Task 6: P3 Cleanup Sweep

**Files:**
- Modify focused P3 files only after a test proves behavior: CLI dynamic import rejection, table-name centralization where already used by health checks, cancellation support in Swift search/UI tasks, duplicate duration/date formatter helpers where safe.

- [x] **Step 1: Inventory current P3 candidates**

Use current source, not old reports, and split candidates into behavior-impacting vs mechanical.

Current inventory note: CLI dynamic import rejection is already covered by `tests/cli/index.test.ts`; settings load reentrancy is already guarded by `ViewMainThreadReadTests`. This sweep selected two still-current, low-risk items: centralize the CLI health table list and cancel Search page work on disappearance.

- [x] **Step 2: TDD each selected cleanup**

For every behavior-impacting cleanup, add a failing test before production code. For pure mechanical cleanup, run the smallest build/lint verifier.

Current verification note: RED was observed for `tests/cli/health.test.ts` before exporting `HEALTH_TABLE_NAMES`, and for `EngramTests/ViewMainThreadReadTests/testSearchPageCancelsWorkOnDisappear` before adding Search page disappear cancellation. GREEN was verified with `npx vitest run tests/cli/health.test.ts`, `npx biome check src/cli/health.ts tests/cli/health.test.ts`, and `xcodebuild test ... -only-testing:EngramTests/ViewMainThreadReadTests`.

- [x] **Step 3: Commit small batches**

Committed in `fix: close post-review followup findings`.

### Task 7: Full Verification and Durable Closeout

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `.memory`

- [x] **Step 1: Run full verification**

Run `npm run lint`, `npm run build`, `npm run typecheck:test`, `npm run knip`, `npm run test:coverage`, fixture checks, Swift all-schemes unit tests with coverage, and UI smoke where feasible.

Current verification note: TypeScript lint/build/test/coverage/fixture/actionlint gates passed on Node 26 with the repo pinned to Node 24+. Swift unit suites passed with coverage: `EngramCoreTests` 364 tests, `EngramMCPTests` 73 tests, `EngramServiceCore` 127 tests, and `EngramTests` 301 tests with 1 skip. UI smoke was attempted with `EngramUITests`; build succeeded but the XCTest UI runner was killed before bootstrap (`XCTHTestRunnerErrorDomain`, signal kill before establishing connection), so no UI assertion body ran.

- [x] **Step 2: Update durable records**

Append concise English closeout to `CHANGELOG.md` and `.memory`, with exact checks run and residual risks.

Current closeout note: `CHANGELOG.md` and `.memory` record the follow-up remediation scope, verification commands, failed UI smoke evidence, and resume point for PR/CI.

- [ ] **Step 3: Push and open PR**

Push `followups/full-remediation`, open a PR, and monitor CI to green.

### Task 8: Session Detail Find Navigation Stale Index Crash

**Files:**
- Modify: `macos/Engram/Views/SessionDetailView.swift`
- Test: `macos/EngramTests/TodayWorkbenchScopeTests.swift`

- [x] **Step 1: Write failing test**

Add a pure-helper test proving find-bar navigation clamps a stale `currentMatchIndex` after the match set shrinks, including the previous-match branch that used to index out of range.

- [x] **Step 2: Verify RED**

Confirm the test fails against the inline `navigateFind` previous-match logic before the helper is used.

- [x] **Step 3: Implement guard**

Route find navigation through the same clamped position helper used by per-type navigation before indexing `matchIndices`.

- [x] **Step 4: Verify GREEN**

Run `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramTests -destination 'platform=macOS' -only-testing:EngramTests/TodayWorkbenchScopeTests CODE_SIGNING_ALLOWED=NO`.

- [x] **Step 5: Commit**

Committed in `fix: close post-review followup findings`.

### Task 9: OSLog Privacy Finding Adjudication

**Files:**
- Inspect: `macos/Engram/Core/EngramLogger.swift`
- Inspect: `macos/EngramService/Core/ServiceLogger.swift`
- Inspect/clarify: `macos/Engram/Core/OSLogReader.swift`
- Test/clarify: `macos/EngramTests/OSLogReaderTests.swift`

- [x] **Step 1: Verify current logging privacy**

Confirm app and service loggers emit user-facing message text with `.private`, preserving the prior privacy hardening.

- [x] **Step 2: Verify observability path**

Confirm `OSLogReader` reads the current-process unified log scope, not the broader local store path, and that `OSLogReaderTests` observes an emitted unique token in the in-app reader result.

- [x] **Step 3: Adjudicate Claude high finding**

Classify the Claude finding "Logger privacy flipped to .private redacts every in-app log message" as overturned for the current tree: the targeted OSLog reader tests pass and prove the in-app current-process reader still surfaces message text.

- [x] **Step 4: Clarify stale comments**

Update comments and skip messages that still referred to `OSLogStore.local()` so future reviewers do not route the finding against the wrong API surface.

- [x] **Step 5: Commit**

Committed in `fix: close post-review followup findings`.

### Task 10: AI Audit Error Sanitization Adjudication

**Files:**
- Inspect/verify: `src/core/ai-audit.ts`
- Test: `tests/core/ai-audit.test.ts`

- [x] **Step 1: Verify implementation**

Confirm `AiAuditWriter.record()` applies `applyPatterns()` to `entry.error` before both database insertion and `entry` event emission.

- [x] **Step 2: Verify test coverage**

Confirm the test suite includes a regression case proving errors are sanitized in both the stored row and emitted event.

- [x] **Step 3: Verify GREEN**

Run `npx vitest run tests/core/ai-audit.test.ts`.

- [x] **Step 4: Adjudicate Claude medium finding**

Classify the Claude finding "ai-audit persists error to DB unsanitized" as closed in the current tree.

- [x] **Step 5: Commit**

Committed in `fix: close post-review followup findings`.

### Task 11: MCP Handoff Relative Time Adjudication

**Files:**
- Inspect/verify: `macos/EngramMCP/Core/MCPTranscriptTools.swift`
- Test: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`

- [x] **Step 1: Verify implementation**

Confirm handoff date parsing first handles ISO8601 timestamps, then falls back to SQLite local datetime strings using the configured `TZ` timezone when provided.

- [x] **Step 2: Verify regression coverage**

Confirm the executable MCP test mutates a fixture session to a local `Asia/Shanghai` SQLite timestamp and asserts the handoff output says `2h ago`, not `just now`.

- [x] **Step 3: Verify GREEN**

Run `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' -only-testing:EngramMCPTests/EngramMCPExecutableTests/testHandoffRelativeTimeUsesLocalTimezoneForRecentSessionList CODE_SIGNING_ALLOWED=NO`.

- [x] **Step 4: Adjudicate Claude medium finding**

Classify the Claude finding "Handoff 'Last active' relative time is wrong off-UTC" as closed in the current tree.

- [x] **Step 5: Commit**

Committed in `fix: close post-review followup findings`.

### Task 12: Suggested Parent Batch Lookback Adjudication

**Files:**
- Inspect/verify: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Test: `macos/EngramCoreTests/StartupBackfillTests.swift`

- [x] **Step 1: Verify implementation**

Confirm `backfillSuggestedParents()` can batch-load a broad parent window for performance, but re-filters parent rows per candidate through `isParentWithinCandidateLookback()` before scoring.

- [x] **Step 2: Verify lookback semantics**

Confirm `isParentWithinCandidateLookback()` enforces `parentStart <= candidateStart` and `parentStart >= candidateStart - 24h`.

- [x] **Step 3: Verify regression coverage**

Confirm the regression test includes an early candidate that can use the fetched parent and a late candidate that must not score the same globally fetched parent outside its own 24h lookback.

- [x] **Step 4: Verify GREEN**

Run `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/StartupBackfillTests/testBackfillSuggestedParentsKeepsBatchParentsWithinCandidateLookback CODE_SIGNING_ALLOWED=NO`.

- [x] **Step 5: Adjudicate Claude medium finding**

Classify the Claude finding "Parent-detection batch optimization drops per-candidate 24h lookback lower bound" as closed in the current tree.

- [x] **Step 6: Commit**

Committed in `fix: close post-review followup findings`.

### Task 13: Symlinked Adapter Source Root Adjudication

**Files:**
- Inspect/verify: `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`
- Inspect/verify: `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift`
- Test: `macos/EngramCoreTests/AdapterParityTests.swift`

- [x] **Step 1: Verify implementation**

Confirm shared JSONL adapter filesystem helpers treat a symlinked root directory as an accessible directory by checking the resolved target and enumerating from the resolved root.

- [x] **Step 2: Verify adapter coverage**

Confirm both Claude Code projects root and Codex sessions root have regression coverage for symlinked source roots.

- [x] **Step 3: Verify GREEN**

Run `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/AdapterParityTests/testClaudeCodeAcceptsSymlinkedProjectsRoot -only-testing:EngramCoreTests/AdapterParityTests/testCodexAcceptsSymlinkedSessionsRoot CODE_SIGNING_ALLOWED=NO`.

- [x] **Step 4: Adjudicate Claude medium finding**

Classify the Claude finding "Symlinked source ROOT silently disables an adapter" as closed in the current tree.

- [x] **Step 5: Commit**

Committed in `fix: close post-review followup findings`.
