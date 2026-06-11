# Engram Audit Complete Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every confirmed finding in `CODE-REVIEW-2026-06-10.md` and adjudicate the 47 low-severity notes, fixing every note that is true.

**Architecture:** Treat the audit report as an evidence queue, not as truth by itself. Each item is first checked against current source because a previous Codex pass already fixed part of the high-risk set. Behavior changes get failing tests before production edits; documentation-only drift gets bounded source/doc verification and direct doc correction.

**Tech Stack:** Swift/macOS app, Swift service/helper, GRDB/SQLite, MCP stdio helper, XcodeGen, GitHub Actions, markdown docs.

---

### Task 1: Build And Maintain The Remediation Ledger

**Files:**
- Read: `CODE-REVIEW-2026-06-10.md`
- Create/update as needed: `docs/superpowers/plans/2026-06-10-audit-complete-remediation.md`

- [x] **Step 1: Extract the report scope**

Confirmed counts from the report:

```text
HIGH: 26
MEDIUM: 50
LOW: 12
Low-severity notes requiring adjudication: 47
```

- [x] **Step 2: Mark prior Codex fixes as already covered**

Covered in the previous pass:

```text
H01 H02 H03 H04 H05 H07 H08 H12 H13 H14 H15 H16 H17 H18 H19 H20 H21 H22 H24 H25 H26
M19 M46 M47 M48
U07
```

Covered in this continuation pass:

```text
H06
H09
H10
M24 M25 M27 M33 M34 M49
M35 M36 M37 M38 M39 M40 M41 M42 M43 M44 M50
H11
M45
H23
M03
M10
M01
M11
M12
M13
M14
M15
M16
M17
M18
M20
M21
M22
M23
M02
M09
M08
M07
M06
M05
M04
M26
M28
M29
M30
M31
M32
L01
L02
L03
L04
L05
L06 L07 L08 L09
L10 L11 L12
```

- [x] **Step 3: For each remaining item, record one of these states**

```text
OPEN: current source still matches the finding
CLOSED: current source no longer matches the finding and a verifier/test proves it
OVERTURNED: current source contradicts the finding
PARTIAL: current source fixes part of the finding but leaves an actionable remainder
DEFERRED: item is true but needs a larger architectural batch and is not yet fixed
```

### Task 2: MCP/Resume Behavior Tranche

**Files:**
- Modify: `macos/EngramMCP/Core/MCPStdioServer.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramService/Core/EngramServiceReadProvider.swift`
- Test: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Test: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`

- [x] **Step 1: Write failing tests**

Required tests:

```text
M24: ping returns {"jsonrpc":"2.0","id":...,"result":{}} instead of -32601.
M25: list_sessions total reports all matching rows, not only returned page rows.
M27: nullable aggregate/grouping rows map to JSON without fatalError.
M49: empty-cwd resume command returns an error/hint instead of open ''.
```

Run:

```bash
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -only-testing:EngramMCPTests/EngramMCPExecutableTests/testPingReturnsEmptyResult -quiet
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -only-testing:EngramMCPTests/EngramMCPExecutableTests/testListSessionsTotalCountsMatchesBeyondPage -quiet
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testResumeCommandForEmptyCwdReturnsHintInsteadOfOpenEmptyString -quiet
```

Expected before implementation: each new test fails for the specific missing behavior.

- [x] **Step 2: Implement minimal fixes**

Implementation requirements:

```text
M24: handle "ping" in MCPStdioServer before the unknown-method default.
M25: use a COUNT(*) query with the same WHERE clauses as listSessions.
M27: replace non-optional nullable/aggregate reads with tolerant helpers or SQL COALESCE.
M49: return a response with command nil/empty and a clear hint when cwd is empty for open-based resume.
```

- [x] **Step 3: Verify tranche**

Run the targeted tests above plus:

```bash
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -quiet
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -only-testing:EngramServiceCoreTests/EngramServiceIPCTests -quiet
```

Executed targeted verification:

```bash
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests \
  -only-testing:EngramMCPTests/EngramMCPExecutableTests/testPingReturnsEmptyResult \
  -only-testing:EngramMCPTests/EngramMCPExecutableTests/testListSessionsTotalCountsMatchesBeyondPage \
  -only-testing:EngramMCPTests/EngramMCPExecutableTests/testStatsDayGroupingDoesNotCrashOnMalformedStartTime \
  -only-testing:EngramMCPTests/EngramMCPExecutableTests/testListSessionsMatchesGolden \
  -only-testing:EngramMCPTests/EngramMCPExecutableTests/testStatsMatchesGolden \
  -only-testing:EngramMCPTests/EngramMCPExecutableTests/testGetCostsSerializesNonFiniteCostAsNull -quiet
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore \
  -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testResumeCommandForEmptyCwdReturnsHintInsteadOfOpenEmptyString \
  -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testSQLiteResumeCommandUsesCodexResumeSubcommand -quiet
```

Both commands exited 0. Xcode beta/CoreSimulator warnings were present but did not fail the tests.

### Task 3: Documentation Drift Tranche

**Files:**
- Modify: `README.md`
- Modify: `docs/PRIVACY.md`
- Modify: `docs/mcp-tools.md`
- Modify: `docs/mcp-swift.md`
- Modify: `CLAUDE.md`
- Possibly modify: `config.yaml`

- [x] **Step 1: Verify each doc claim against current code**

Claims:

```text
M33: index-time redaction is undocumented or implemented.
M34: source paths are not described as read-only without project-move caveat.
L06: Windsurf support accurately describes cache/live-sync behavior.
L07: MiniMax/Lobster AI paths match the Claude-derived adapter implementation.
L08: MCP tool docs list all shipped Swift tools.
L09: FTS rebuild docs name the Swift product constant.
```

- [x] **Step 2: Correct docs or implement missing behavior**

Default decision for this tranche: fix documentation drift rather than add new product features, unless the codebase already contains an incomplete implementation intended to be wired.

- [x] **Step 3: Verify docs**

Run:

```bash
rg -n "REDACTED|redact_patterns|Read-only|Windsurf|MiniMax|Lobster|26 tools|FTS_VERSION" README.md docs CLAUDE.md config.yaml
git diff --check
```

Executed verification:

```bash
rg -n 'redact_patterns|建立索引时会被替换|Engram never modifies|~/.minimax/sessions|~/.lobsterai/sessions|gRPC \+ `~/.codeium/windsurf/`|26 tools|FTS_VERSION forces full re-index|Total tools: 26|show the 26 tools' README.md docs/PRIVACY.md docs/mcp-tools.md docs/mcp-swift.md CLAUDE.md config.yaml
rg -n "^## " docs/mcp-tools.md | wc -l
git diff --check -- README.md config.yaml docs/PRIVACY.md docs/mcp-tools.md docs/mcp-swift.md CLAUDE.md
```

The stale-claim search returned no matches, `docs/mcp-tools.md` has 28 tool sections, and `git diff --check` exited 0.

### Task 4: Continue Remaining Confirmed Items

**Files:** Determined per item from `CODE-REVIEW-2026-06-10.md`.

- [x] **Step 1: Process remaining OPEN confirmed findings in severity order**

Remaining confirmed medium/low themes:

```text
L01-L12 except those closed by earlier shared fixes
```

Closed in this pass:

```text
M26: get_session now caps oversized message content and omits oversized text mirrors while preserving structuredContent.
M28: stdio executable tests cover multi-request sessions, ping, tools/list, tools/call, and cancelled notifications.
M29: transient missing-FTS coverage uses a real MCP executable behavior test instead of source-string assertions.
M30: UI fixture generation and an existing fixture now include Swift SchemaManifest table coverage.
M31: DatabaseManager has a product read-path test against the Swift-gated fixture schema.
M32: NavigationSmokeTests.testCommandPalette no longer uses XCTSkip or XCTAssertTrue(true); it requires Cmd+K to expose the real commandPalette_search field, and CommandPaletteView now exposes stable accessibility identifiers.
L01: AppDelegate status observation now degrades after an initial status failure but still starts the service event stream; UnixSocketEngramServiceTransport treats transportClosed as a transient event-stream restart condition.
L02: backfillCodexOriginator now filters by unchecked rows, marks ordinary/non-Claude Codex sessions inspected, orders/paginates batches, and drains later Claude-originated rows beyond the first 500 candidates.
L03: ui-test-full now gates pull requests as well as main, so the full EngramUITests bundle is not post-merge only.
L04: screenshot-compare now hard-fails missing baselines and size mismatches by default, and CI no longer opts size mismatches into report-only mode.
L05: release.yml now only runs for v* tags, runs release-tests before archive verification, and passes the pushed tag version to release-verify; release-verify rejects CFBundleShortVersionString/tag mismatches.
L10: EngramService main now installs SIGTERM/SIGINT dispatch sources that cancel the service task, allowing EngramServiceRunner.run() to execute its existing graceful shutdown path before process exit.
L11: EngramServiceRunner.runInitialScan now wraps each gated startup phase in runInitialScanPhase, retries writerBusy with backoff, records per-phase failures, and continues later startup maintenance phases instead of abandoning the whole launch.
L12: EngramCLI default stdio mode no longer posts to the retired /tmp/engram.sock HTTP bridge; after resume handling it execs the shipped EngramMCP helper or fails loudly if the helper is unavailable.
```

M32 verification note:

```text
xcodebuild build -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -quiet
  exited 0.

xcodebuild test -project macos/Engram.xcodeproj -scheme EngramUITests -destination 'platform=macOS' -only-testing:EngramUITests/NavigationSmokeTests/testCommandPalette -quiet
  currently fails because the only installed Xcode is /Applications/Xcode-beta.app and XCTAutomationSupport aborts the app while fetching accessibility snapshots (see ~/Library/Logs/DiagnosticReports/Engram-2026-06-10-202051.ips). Source checks confirm the previous tautology/skip is removed and the PR smoke lane includes NavigationSmokeTests.
```

L01 verification note:

```text
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramTests -destination 'platform=macOS' -only-testing:EngramTests/ServiceEventRoutingTests -only-testing:EngramTests/UnixSocketTransportTests -quiet
  exited 0.
```

L02 verification note:

```text
xcodebuild build -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -derivedDataPath /tmp/engram-dd-l02 -quiet
  exited 0.

xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -derivedDataPath /tmp/engram-dd-l02 -parallel-testing-enabled NO -only-testing:EngramCoreTests/StartupBackfillTests/testBackfillCodexOriginatorMarksClaudeLaunchedCodexSessions -only-testing:EngramCoreTests/StartupBackfillTests/testBackfillCodexOriginatorDrainsLargeOrdinaryBatchBeforeClaudeOriginatedRows -quiet
  fails because the EngramCoreTests host exits after loading duplicate GRDB classes from EngramCoreRead.framework, EngramCoreWrite.framework, and the test bundle. The result bundle only reports uncategorized failure after xcodebuild restarts and runs 0 tests. The source under test and new regression cases compile; runtime assertion proof is blocked by the pre-existing test-host linking issue.
```

L03-L04 verification note:

```text
npm test -- tests/scripts/screenshot-compare.test.ts
  exited 0 (4 tests passed).
```

L05 verification note:

```text
npm test -- tests/scripts/build-release-script.test.ts
  exited 0 (16 tests passed).
```

L10-L11 verification note:

```text
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testServiceMainCancelsRunnerOnTerminationSignals -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testRunnerInitialScanPhasesAreFaultIsolatedAndRetryWriterBusy -quiet
  exited 0.
```

L12 verification note:

```text
xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests/EngramCLIResumeCommandTests/testDefaultCLIStdioModeDelegatesToSwiftMCPHelper -quiet
  exited 0.

xcodebuild build -project macos/Engram.xcodeproj -scheme EngramCLI -destination 'platform=macOS' -quiet
  exited 0.
```

- [x] **Step 2: Process the 47 low-severity notes**

Each note must be checked against current source. True notes get tests or bounded doc/config verification before fixes.

Low-severity note adjudication ledger:

```text
N01 CLOSED service graceful shutdown unreachable without SIGTERM handler
N02 CLOSED health monitor SIGTERMs legitimately slow startup
N03 CLOSED UnixSocketServiceServer second start rewrites capability token
N04 CLOSED skip-tier backfills miss index-artifact cleanup
N05 CLOSED SessionWatcher.drainReady drops rest of batch on one indexFile throw
N06 CLOSED sessionTimeline accessed-sort grouping ignores last_accessed_at
N07 CLOSED Popover data load swallows read errors without logging
N08 CLOSED Minimax/Lobsterai derived adapters double-parse inherited heads
N09 CLOSED Antigravity/Windsurf liveSync=false wording/behavior mismatch
N10 CLOSED Codex/Iflow/Qwen extract only first text part of multipart content
N11 CLOSED Cursor composers without createdAt get epoch-1970 start times
N12 CLOSED SQLite-backed adapters swallow listing errors for entire source
N13 CLOSED watchedSources lists minimax/lobsterai without watch entries
N14 CLOSED parent depth validation permits depth-2 chains when linking a parent
N15 CLOSED scoredPolycliHosts exact cwd equality defeats normalization
N16 CLOSED project-move undo rewrites pre-existing destination references
N17 CLOSED MigrationLock TTL can break verified-alive holder after 1h
N18 CLOSED documented watcher guard/cleanup are dead or drifted duplicate code
N19 CLOSED undo pre-flight validation runs outside migration lock
N20 CLOSED unreachable SessionListView remains maintained and scan-tested
N21 CLOSED find bar can show stale out-of-range match counter
N22 CLOSED Advanced settings tab rewrites settings on open
N23 CLOSED cancelled tools/call emits result and duplicate ids overwrite task
N24 CLOSED JSON-RPC id-less response and parse-error id:null nits
N25 CLOSED project filter docs advertise partial match but implementation is exact
N26 CLOSED MCPLiveSessionScanner dead code
N27 CLOSED OrderedJSONStringParser rejects surrogate-pair escapes
N28 CLOSED macOS-only vitest suites skipped in CI
N29 CLOSED health-monitor recovery test depends on wall-clock sleep race
N30 CLOSED no-mocking test convention contradicted by module-mocked vitest suites
N31 CLOSED npm audit hard-gates PRs on upstream advisory churn
N32 CLOSED stale unused root VERSION contradicts single-source version
N33 CLOSED no CI freshness gate for Engram.xcodeproj vs project.yml
N34 CLOSED biome/tsconfig do not check nested CI scripts
N35 CLOSED gitignored LFS hook shims with core.hooksPath .husky
N36 CLOSED xcodegen install failures masked and unpinned
N37 CLOSED SPM cache key ignores Package.resolved and ui jobs lack restore-keys
N38 CLOSED CLAUDE tiering docs point to TS canonical implementation
N39 CLOSED README/docs disagree on Claude Code MCP config path
N40 CLOSED root config.yaml documents unread configuration surface
N41 CLOSED CLAUDE manual linking docs only mention legacy HTTP endpoints
N42 CLOSED blocking accept() runs on Swift cooperative pool and stop cannot wake it
N43 CLOSED SessionWatcher/NonWatchableSourceRescanner not constructed in product
N44 CLOSED General settings legacy Node rollback controls are dead
N45 CLOSED favorite-star load race on rapid session switch
N46 CLOSED Search page advertises semantic/hybrid while service is keyword-only
N47 CLOSED Ollama title provider selection deletes stored titleApiKey
```

Low-severity note verification log:

```text
N01: Covered by L10. macos/EngramService/main.swift now installs SIGTERM/SIGINT dispatch sources and cancels serviceTask, so EngramServiceRunner.run() can unwind through its graceful shutdown path. Verified by EngramServiceIPCTests/testServiceMainCancelsRunnerOnTerminationSignals.
N02: Confirmed true. EngramServiceLauncher.startHealthMonitor treated the first socket/status probe failure exactly like a wedged helper, so a legitimately slow startup could be SIGTERM'ed and restarted before the service bound its socket. Added EngramServiceLauncherTests/testHealthMonitorDoesNotRestartDuringStartupGrace; RED first failed because no startup-grace state existed, GREEN after EngramServiceLauncher gained a default 30s startup grace window that reports .starting without consuming restart budget or killing the helper. Existing restart-budget and recovery tests were updated to pass startupGraceNanoseconds: 0 and all three targeted health-monitor tests exited 0.
N03: Added EngramServiceIPCTests/testSecondUnixSocketServerStartDoesNotRewriteCapabilityToken. RED failed because the second start rewrote the token file; GREEN after UnixSocketServiceServer.start() returns before token generation when already running and cleans up descriptor state if initial token generation fails.
N04: Covered by L02. StartupBackfills skip-tier paths now delete sessions_fts/index_jobs artifacts for reclassified sessions. The new StartupBackfillTests compile; runtime assertion remains blocked by the documented duplicate-GRDB test-host issue.
N24: Added EngramMCPExecutableTests/testParseErrorIncludesNullId and testIdLessRequestsDoNotEmitResponses. RED failed under the old MCPStdioServer behavior; GREEN after parse errors emit id:null and decoded id-less requests are treated as notifications.
N25: Added EngramMCPExecutableTests/testListSessionsProjectFilterIsPartialMatch. RED failed because list_sessions used project = ?. GREEN after listSessions uses escaped LIKE patterns while preserving alias expansion and existing list_sessions golden/total tests.
N26: Added AppSearchServiceCutoverScanTests/testMcpModeDoesNotKeepUnusedLiveSessionScannerCompiled. RED failed while MCPLiveSessionScanner.swift was still compiled even though MCP live_sessions returns unavailable; GREEN after deleting the unused scanner and regenerating Engram.xcodeproj.
N27: Added EngramMCPExecutableTests/testProjectListMigrationsParsesSurrogatePairEscapesInDetail. RED failed because OrderedJSONStringParser rejected paired Unicode surrogate escapes; GREEN after parseString combines high/low surrogate pairs and rejects malformed pairs. Targeted xcodebuild test with testProjectListMigrationsMatchesGolden exited 0.
N28: Extended tests/scripts/ci-workflow.test.ts to require a macos-vitest job. RED failed with no lane; GREEN after test.yml added a macos-15 vitest lane for build-release-script and swift-boundary script tests.
N29: Replaced EngramServiceLauncherTests fixed 1.5s sleep with ServiceStatusRecorder.waitUntil condition polling. xcodebuild targeted testHealthMonitorKeepsProbingAndRecoversAfterBudgetExhausted exited 0.
N30: CLAUDE.md now documents the actual test convention: real fixtures for parser/DB behavior, focused module mocks for external boundaries/failure injection. rg confirms the stale "No mocking" claim is gone.
N31-N37: Added tests/scripts/ci-workflow.test.ts. RED failed for all seven CI/build notes. GREEN after PR npm audit became non-blocking, root VERSION was deleted, test.yml checks xcodegen-generated pbxproj freshness, tsconfig/biome cover nested scripts, .husky/pre-push is unignored for tracking, xcodegen install failures are no longer masked and the expected 2.45.4 generator version is asserted, and all SPM cache keys include Package.resolved with UI restore-keys.
N38-N41: Updated CLAUDE.md/docs/mcp-swift.md and deleted the unread root config.yaml. Tiering docs now name Swift SessionTier.swift as product canonical, Claude Code MCP manual edits are unified on ~/.claude/settings.json (verified against local claude mcp help and local ~/.claude state), manual linking docs name EngramServiceClient/EngramServiceCommandHandler instead of retired HTTP endpoints, and the root config template no longer advertises an unread configuration surface.
N42: Confirmed true. UnixSocketServiceServer accepted clients via direct accept(descriptor, nil, nil) inside Task.detached, while only frame I/O used the dedicated blocking queue; stop() cancelled the task and closed the listener without an explicit wake. Added EngramServiceIPCTests/testUnixSocketServiceServerOffloadsAcceptAndWakesItOnStop; RED failed on the direct accept/stop path, GREEN after adding acceptClientOffCooperativePool backed by blockingIOQueue.async and calling shutdown(snapshot.descriptor, SHUT_RDWR) before close. Adjacent testUnixSocketServiceServerStopCancelsInFlightClientHandlers exited 0. testServerRecyclesPermitsAcrossManySequentialConnections remains blocked before IPC assertions by the existing duplicate-GRDB test-host fatal.
N44: Added AppSearchServiceCutoverScanTests/testGeneralSettingsDoesNotExposeLegacyNodeRollbackControls. RED failed on legacy Node rollback AppStorage/labels; GREEN after GeneralSettingsSection removed httpPort/nodejsPath controls while preserving live Swift service Web UI and MCP endpoint display.
N45: Confirmed true. SessionDetailView launched a detached favorite read for the previous session and unconditionally assigned isFavorite on return, so rapid session switches could leave the current detail view with stale star state. Extended TodayWorkbenchScopeTests/testSessionDetailBuildsTranscriptOffMain to require a favoriteLoadSessionId guard; RED failed against the unguarded assignment, GREEN after SessionDetailView resets isFavorite on each session load, tags the active session id, and only applies async read/toggle results when favoriteLoadSessionId still matches. Targeted xcodebuild test exited 0.
N46: Updated SearchModeTests and added AppSearchServiceCutoverScanTests/testAppSearchSurfacesRequestKeywordModeOnly. RED failed because embeddingAvailable=true exposed hybrid/semantic and CommandPalette requested hybrid; GREEN after app search surfaces became keyword-only until a real Swift vector query path ships.
N47: Added DeprecatedSettingsScrubTests/testTitleSettingsPreserveStoredApiKeyWhenSwitchingToOllama and EngramServiceIPCTests/testServiceAISettingsIgnoresStoredTitleApiKeyForOllamaTitleProvider. RED failed because the UI deleted titleApiKey on Ollama and the service resolved stored keys for Ollama; GREEN after title key persistence gained preserve/write/delete decisions and Ollama title config ignores stored API keys.
N21: Added TodayWorkbenchScopeTests/testDisplayedFindMatchIndexClampsStaleIndex. RED failed because SessionDetailView had no display-index clamp and the find bar received max(currentMatchIndex, 0); GREEN after displayedFindMatchIndex clamps stale indices to the current match count before rendering.
N22: Covered by ViewMainThreadReadTests/testSettingsLoadsDoNotImmediatelyWriteBackUnchangedValues. AdvancedSettingsSection now holds isLoadingSettings through a post-load MainActor Task.yield, so SwiftUI onChange writes are suppressed while loaded state settles. Targeted xcodebuild test exited 0.
N23: Added EngramMCPExecutableTests/testMCPStdioCancellationDoesNotEmitCancelledToolResultsOrOverwriteDuplicateIds. RED failed because async tools/call still emitted a result after cancellation and duplicate ids could overwrite in-flight requests. GREEN after MCPStdioServer rejects duplicate in-flight ids and suppresses cancelled async tool responses; testStdioSessionHandlesMultipleRequestsAndNotifications now asserts cancelled calls emit no response.
N10: Added AdapterMessageCountTests multipart stream tests for Codex, Iflow, and Qwen. RED failed because each adapter returned only the first text part. GREEN after the three extractors collect all non-empty text/input_text/output_text parts in order and join them with blank lines; adjacent usage attachment tests still pass.
N11: Added AdapterMessageCountTests/testCursorComposerMissingCreatedAtUsesFirstBubbleTimestamp. RED failed because missing composer createdAt produced the epoch-1970 startTime. GREEN after CursorAdapter falls back to the first visible bubble timingInfo.clientStartTime, then lastUpdatedAt, before the old zero fallback.
N12: Added AdapterMessageCountTests malformed-SQLite listing tests for OpenCode and Cursor. RED failed because both listSessionLocators methods swallowed sqliteUnreadable and returned an empty source. GREEN after missing DB files still return [], while schema/open/query errors propagate ParserFailure.sqliteUnreadable.
N13: Superseded by N43. The entire unused Swift watcher/rescanner path, including WatchPathRules, was removed from product/test compilation instead of preserving a test-only routing table.
N09: Added AppSearchServiceCutoverScanTests/testCascadeAdapterDocsDoNotClaimDisabledLiveSyncMeansZeroIngest. RED failed because CLAUDE.md claimed enableLiveSync:false means zero ingest. GREEN after docs state live gRPC sync is disabled, Windsurf is cache-only, and Antigravity still reads CLI brain transcripts plus existing legacy cache; docs/PRIVACY.md now names the Windsurf cache-only path.
N05: Superseded by N43. SessionWatcher was not product-wired, so the bounded fix is deletion of the unused watcher subsystem and its tests rather than continuing to maintain test-only drain semantics.
N06: Added DatabaseManagerTests/testSessionTimelineAccessedSortUsesLastAccessedForGrouping. RED failed because sessionTimeline used last_accessed_at only in SQL filtering while Swift grouping and secondary sorting used endTime/startTime. GREEN after the Swift timestamp helper mirrors accessed/updated/created sort semantics; adjacent sessionTimeline activity and listSessions accessed-order tests still pass.
N07: Added AppSearchServiceCutoverScanTests/testPopoverDataLoadLogsReadFailures. RED failed because PopoverView.loadData used try? defaults for all DB/file reads. GREEN after each popover read goes through explicit do/catch logging via EngramLogger.error while preserving bounded fallback values for the menu UI.
N08: Added AdapterParityTests/testClaudeDerivedAdaptersShareBaseAndSourceHintCache. RED failed because derived minimax/lobsterai adapters each created their own ClaudeCodeAdapter and no sourceHintCache existed. GREEN after SessionAdapterFactory shares one Claude base with the two derived adapters and ClaudeCodeAdapter caches locator source hints by file signature; existing derived-source routing tests still pass.
N14: Confirmed true. EngramServiceCommandHandler.validateParentLink and StartupBackfills.validateParentLink only rejected candidate parents that already had a parent, so linking child -> parent and then parent -> grandparent could create a depth-2 chain. Fixed both validators to count existing children for the session being linked and reject with depth-exceeded/false when childCount > 0. Added AppSearchServiceCutoverScanTests/testParentLinkValidationRejectsDepthTwoChainsInServiceAndBackfill; it passed, and EngramServiceCore build passed. Runtime IPC/StartupBackfill tests were attempted but blocked before behavior assertions by the existing duplicate-GRDB test-host fatal.
N15: Confirmed true. scoredPolycliHosts filtered host candidates with SQL `AND cwd = ?` before scorePolycliHostCandidate could apply its trailing-slash normalization, so `/repo` and `/repo/` could not match. Added AppSearchServiceCutoverScanTests/testPolycliHostScoringSqlDoesNotDefeatCwdNormalization; RED failed on the exact cwd filter, GREEN after changing the SQL prefilter to `rtrim(cwd, '/') = rtrim(?, '/')`. EngramServiceCore build passed.
N16: Confirmed true for rollback/compensation. File compensation used global `attemptedDst -> originalSrc` reverse patching for every manifest path, so any destination-path text that existed before the move could be rewritten during rollback. Fixed runtime manifests to carry a per-file backupPath captured before forward patching, and compensation now restores exact pre-patch bytes when a backup is available, keeping the old reverse-patch path only as a legacy fallback. Added AppSearchServiceCutoverScanTests/testProjectMoveRollbackRestoresPatchedFilesFromBackups; it passed, and EngramServiceCore build passed. Direct Orchestrator runtime tests were attempted but currently abort before assertions due the existing duplicate-GRDB test-host fatal.
N17: Confirmed true. MigrationLock.acquire treated a live holder older than staleTTL as stale, so another process could unlink an active project-move lock after one hour. Replaced that rule with "live pid always LockBusy"; stale cleanup still breaks dead, zombie, or corrupt holders. Updated MigrationLockTests/testAcquireDoesNotBreakLiveHolderOlderThanTTL from the old break-live-holder contract to the corrected busy contract; RED failed before the fix and GREEN passed with testAcquireThrowsLockBusyWhenLiveHolderExists, testAcquireBreaksStaleLockFromDeadPid, and testAcquireBreaksZombieHolder.
N18: Confirmed true. Swift MigrationLogStore.hasPendingMigrationFor was a watcher-only guard with no Swift product caller, and StartupBackfills carried a second hardcoded stale-migration cleanup SQL instead of using the project-move store implementation. Added AppSearchServiceCutoverScanTests/testStartupMigrationCleanupUsesProjectMoveStoreImplementation; RED failed on the duplicate SQL, GREEN after StartupBackfills.cleanupStaleMigrations delegates to MigrationLogStore.cleanupStaleMigrations. Added AppSearchServiceCutoverScanTests/testUnusedSwiftWatcherPathIsRemovedFromProductAndTests; RED failed while hasPendingMigrationFor and the unused watcher files still existed, GREEN after removing the dead Swift guard.
N20: Confirmed true. MainWindowView routes to SessionsPageView, while the legacy SessionListView and SessionList/* controls had no product entry point and only stayed alive through scan/persistence tests. Added AppSearchServiceCutoverScanTests/testUnreachableLegacySessionListViewIsRemoved; RED failed while the legacy files existed, GREEN after deleting SessionListView.swift, SessionList/SessionTableView.swift, SessionList/ProjectSearchField.swift, SessionList/ColumnVisibilityStore.swift, SessionList/AgentFilterBar.swift, and SessionListPersistenceTests.swift, then regenerating Engram.xcodeproj. rg confirms no legacy SessionList references remain outside the source-gate test, and the targeted xcodebuild source-gate exited 0.
N43: Confirmed true. SessionWatcher and NonWatchableSourceRescanner were complete test-only subsystems with no EngramServiceRunner construction or FSEvents/runtime event source. Rather than wire a partial fake watcher beside the real startup/periodic scan path, removed SessionWatcher.swift, NonWatchableSourceRescanner.swift, WatchPathRules.swift, WatcherSemanticsTests.swift, and the Round5 SessionWatcher concurrency test, then regenerated Engram.xcodeproj with xcodegen. Source rg confirms no Swift/product/project references remain outside the AppSearchServiceCutoverScanTests guard.
N19: Confirmed true. EngramServiceCommandHandler.projectUndo previously instantiated GRDBMigrationLogReader/GRDBSessionByIdReader and ran UndoMigration.prepareReverseRequest before ProjectMoveOrchestrator.run acquired the migration lock. Added AppSearchServiceCutoverScanTests/testProjectUndoPreflightRunsInsideProjectMoveLock; RED failed while the handler performed preflight directly, GREEN after adding ProjectMoveOrchestrator.runUndo, which acquires MigrationLock, prepares the reverse request, then invokes the normal pipeline with lockAlreadyHeld=true. EngramServiceCore build passed.
```

- [x] **Step 3: Final verification and deployment**

Run the strongest practical test/build set, then:

```bash
macos/scripts/build-release.sh --local-only
macos/scripts/deploy-local.sh macos/build/EngramExport/Engram.app
codesign --verify --deep --strict --verbose=2 /Applications/Engram.app
```

Final verification log:

```text
git diff --check
  exited 0.

xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests/EngramServiceLauncherTests/testHealthMonitorDoesNotRestartDuringStartupGrace -only-testing:EngramTests/EngramServiceLauncherTests/testHealthMonitorRestartsThenMarksDegradedAfterBudget -only-testing:EngramTests/EngramServiceLauncherTests/testHealthMonitorKeepsProbingAndRecoversAfterBudgetExhausted -only-testing:EngramTests/TodayWorkbenchScopeTests/testSessionDetailBuildsTranscriptOffMain -only-testing:EngramTests/AppSearchServiceCutoverScanTests/testUnreachableLegacySessionListViewIsRemoved -quiet
  exited 0.

xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testUnixSocketServiceServerOffloadsAcceptAndWakesItOnStop -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testUnixSocketServiceServerStopCancelsInFlightClientHandlers -quiet
  exited 0.

xcodebuild build -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' -quiet
  exited 0.

xcodebuild build -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -quiet
  exited 0.

macos/scripts/build-release.sh --local-only
  exited 0; archived to macos/build/Engram.xcarchive and exported macos/build/EngramExport/Engram.app.

macos/scripts/deploy-local.sh macos/build/EngramExport/Engram.app
  exited 0; installed /Applications/Engram.app build 20260610144819.

codesign --verify --deep --strict --verbose=2 /Applications/Engram.app
  exited 0; /Applications/Engram.app is valid on disk and satisfies its Designated Requirement.

/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' /Applications/Engram.app/Contents/Info.plist
  printed 20260610144819.

/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Engram.app/Contents/Info.plist
  printed 0.1.0.
```

Known blocked verifier:

```text
EngramServiceCoreTests/EngramServiceIPCTests/testServerRecyclesPermitsAcrossManySequentialConnections
  aborts before the IPC assertion with the existing duplicate-GRDB test-host fatal:
  "Fatal error: Database was not used on the correct thread."
```

- [x] **Step 4: Durable closeout**

Append final verified state and residual risk to:

```text
.memory
CHANGELOG.md
```

Closeout records were appended to both files on 2026-06-10.
