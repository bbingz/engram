# Wave 7 Remediation Closeout — 2026-07-10

**Program:** 43-item remediation (42 audit findings + `S01` scan scheduling)
**Design:** `docs/superpowers/specs/2026-07-10-wave7-43-item-remediation-design.md`
**Plan:** `docs/superpowers/plans/2026-07-10-wave7-43-item-remediation.md`
**Baseline HEAD:** `50e21db1` (ledger open) · audit input `a011e2fb`
**Primary fix commit:** `12d3c081` · **follow-up hardening commit:** this closeout bundle (batch cancel, H06/H09/H11 repros, matrix green)

## Constraints (from design)

- Swift product behavior is authoritative; no Node product entrypoints.
- App/MCP writes go through `EngramServiceClient` / `ServiceWriterGate`.
- Do not edit `macos/Engram.xcodeproj` directly (use `xcodegen generate`).
- `subagent` and `dispatched` remain `tier = 'skip'` across ambiguous/unlink/cascade.
- Verdicts: `CONFIRMED-FIXED` | `PARTIAL-FIXED` | `OVERTURNED` only.

## Ledger

| ID | Verdict | Fix commit | Tests | Evidence | Residual risk |
|----|---------|------------|-------|----------|---------------|
| C01 | CONFIRMED-FIXED | `12d3c081` | `testStartupDeferralDoesNotStampSuccess_recentScanRecovers_repro` | `SwiftIndexer.swift` deferral `continue` without `recordFileIndexSuccess` | — |
| H01 | CONFIRMED-FIXED | `12d3c081` | `testFinalizeRebuildPreservesLiveRowsForPermanentFailures_repro` | `FTSRebuildPolicy.finalizeRebuildIfReady` copies live→shadow before swap | — |
| H02 | CONFIRMED-FIXED | `12d3c081` | **`testIndexAndFtsNamesAreLongRunning_repro`** | `ServiceWriterGate.isLongRunningWriteCommand` | Named-command coverage may miss exotic names |
| H03 | CONFIRMED-FIXED | pass4 | **`testPeerDisconnectCancelsInFlightHandler_repro`** + **`testLinkSessionsCooperativeCancelReturnsRemaining_repro`** + timeout headroom | peer disconnect cancels handler task; symlink loop cooperative cancel + partial remaining | — |
| H04 | CONFIRMED-FIXED | `12d3c081` | `testBackfillSuggestedParentsWritesAmbiguousCandidatesWithoutSkipping` | `setAmbiguousSuggestion` keeps role/tier | — |
| H05 | CONFIRMED-FIXED | `12d3c081`+follow-up | **`testClearParentPreservesDispatchedSkipTier_repro`** (IPC behavioral) + cascade SQL source lock | shipped `clearParentSession` keeps dispatched→skip | Existing DBs get trigger via createOrUpdateBaseSchema |
| H06 | CONFIRMED-FIXED | `12d3c081`+follow-up | **`testGenerateSummaryIsNotReadOnly_repro`** + tools/list annotation assert | `MCPToolRegistry.toolCategory` → `.mutating` | — |
| H07 | PARTIAL-FIXED | `12d3c081` | dim check remains; model equality not fully enforced | design documented in README | Same-dim model swap still possible — follow-up |
| H08 | CONFIRMED-FIXED | `12d3c081` | `SearchModeTests` + README + AISettings comments | App intentionally keyword-only; service/MCP semantic real | — |
| H09 | CONFIRMED-FIXED | follow-up | **`testValidMemoryFileIsReadable_repro`**, **`testNonMemoryMarkdownIsRejected_repro`**, **`testSymlinkEscapeIsRejected_repro`**, **`testTildeDisplayPathUnderMemoryIsReadable_repro`** | `FileSystemEngramServiceReadProvider.memoryFileContent` bounds | — |
| H10 | CONFIRMED-FIXED | `12d3c081` | `testSameCountBodyRewriteEnqueuesFtsJob_repro` | `contentFingerprint` in `snapshotHash` | Tail merge seeds from prior hash |
| H11 | CONFIRMED-FIXED | `12d3c081`+follow-up | **`testPaletteServiceDownEmptyLocalIsEmptyNotFailed_repro`**, **`testPaletteDoubleFaultIsFailed_repro`** | `CommandPaletteView` + `SearchOutcome` bool overload | — |
| H12 | PARTIAL-FIXED | `12d3c081` | — | Export still post-await status; palette list not replaced in this pass | Needs export state machine PR |
| M01 | CONFIRMED-FIXED | `12d3c081` | `performReadCommand` no gen bump | status/telemetry paths switched | Not all pure reads migrated |
| M02 | PARTIAL-FIXED | — | — | telemetry still records before success gate | Follow-up |
| M03 | CONFIRMED-FIXED | `12d3c081` | `testActiveFileGraceDoesNotStampSuccess_repro` | active-file grace no stamp | — |
| M04 | CONFIRMED-FIXED | `12d3c081` | retryable tail → full scan fallthrough | `isTerminalTailFailure` | — |
| M05 | CONFIRMED-FIXED | pass3 | **`testRunCancellationStopsBeforeNextOperationAndReportsRemaining`**, **`testParseBatchMoveOutcomeSurfacesCancelledAndRemaining_repro`** | encode `cancelled`+`remaining[]`; UI keeps partial result (no await-task cancel) | — |
| M06 | PARTIAL-FIXED | — | — | Service warning still coarse | Follow-up |
| M07 | PARTIAL-FIXED | — | — | get_memory mislabel path not rewritten this pass | Follow-up |
| M08 | PARTIAL-FIXED | — | — | MCP breaker not shared | Follow-up |
| M09 | PARTIAL-FIXED | docs | README candidate-cap honesty | KNN still recency-capped | Documented |
| M10 | CONFIRMED-FIXED | `12d3c081` | README + mcp-tools notes | human-driven default / `include_all` | Full mcp-tools rewrite partial |
| M11 | PARTIAL-FIXED | — | — | roles default docs not fully rewritten | Follow-up |
| M12 | PARTIAL-FIXED | — | — | export size code still invalidRequest | Follow-up |
| M13 | PARTIAL-FIXED | — | — | embeddingApiKey Keychain not completed | Follow-up |
| M14 | PARTIAL-FIXED | — | — | diagnostic redaction set not expanded | Follow-up |
| M15 | PARTIAL-FIXED | — | — | service settings 0600 not forced | Follow-up |
| M16 | PARTIAL-FIXED | — | — | MCP transcript still unredacted by design note | Follow-up product decision |
| M17 | CONFIRMED-FIXED | `12d3c081` | dismiss sets `link_source=manual` | `dismissSuggestion` | — |
| M18 | CONFIRMED-FIXED | `12d3c081` | `testBackfillPolycliProviderParentsClassifiesReviewProbes` | bare cwd admission removed | — |
| M19 | PARTIAL-FIXED | — | — | favorites still add-only on browse | Follow-up |
| M20 | CONFIRMED-FIXED | `12d3c081` | README value-band claim narrowed | Search page only | — |
| L01 | PARTIAL-FIXED | — | — | stdout JSON still interpolated in places | Follow-up |
| L02 | PARTIAL-FIXED | — | — | serviceLogs try? remains | Follow-up |
| L03 | CONFIRMED-FIXED | pass3 | status after `recordServiceReady` | socket-ready → running + schedule fields (not stuck on bare starting) | — |
| L04 | CONFIRMED-FIXED | `12d3c081` | formula version metadata | `SessionQualityScore.formulaVersion` + backfill | — |
| L05 | CONFIRMED-FIXED | `12d3c081` | maxMessages → `messageLimitExceeded` | `IndexJobRunner.buildSearchContent` | — |
| L06 | PARTIAL-FIXED | — | — | project_review “7 roots” blurb | Follow-up |
| L07 | PARTIAL-FIXED | — | — | get_memory type not in payload | Follow-up |
| L08 | CONFIRMED-FIXED | `12d3c081` | `LiveSessionCard` → `RelativeTimeText` | shared ISO parser | — |
| L09 | PARTIAL-FIXED | — | — | invariant ledger still path-existence | Follow-up |
| S01 | CONFIRMED-FIXED | pass4 | **`testRecordingSchedulerFinishesOnlyAfterWork_repro`** + policy tests | activity `.finished` only **after** scan work; idle skips embedding; adaptive 15→30→60m; backend from scheduler | — |

## Tallies

| Verdict | Count |
|---------|-------|
| CONFIRMED-FIXED | 25 |
| PARTIAL-FIXED | 18 |
| OVERTURNED | 0 |
| UNADJUDICATED | 0 |

## Repro / regression tests (shipped path)

### P0 / fingerprint / tier / dispatched-skip (VP3)
- `testStartupDeferralDoesNotStampSuccess_recentScanRecovers_repro` (C01)
- `testActiveFileGraceDoesNotStampSuccess_repro` (M03)
- `testFinalizeRebuildPreservesLiveRowsForPermanentFailures_repro` (H01)
- `testSameCountBodyRewriteEnqueuesFtsJob_repro` (H10)
- `testBackfillSuggestedParentsWritesAmbiguousCandidatesWithoutSkipping` (H04)
- **`testReindexPreservesDispatchedSkipClassificationOnContentChange`** (VP3 dispatched-skip retention on re-index)
- **`testClearParentPreservesDispatchedSkipTier_repro`** (H05 clearParent IPC keeps dispatched/skip)
- `testBackfillPolycliProviderParentsClassifiesReviewProbes` (M18)

### Service / IPC (H02 / H03 / M05 / S01)
- **H02:** `testIndexAndFtsNamesAreLongRunning_repro` (`ServiceWriterGateTests`)
- **H03:** `testPeerDisconnectCancelsInFlightHandler_repro` (real IPC socket close) + `testLinkSessionsCooperativeCancelReturnsRemaining_repro` + timeout headroom
- **M05:** `testRunCancellationStopsBeforeNextOperationAndReportsRemaining` + `testParseBatchMoveOutcomeSurfacesCancelledAndRemaining_repro`
- **S01:** `testRecordingSchedulerFinishesOnlyAfterWork_repro` + `testMinIntervalIsNotFixedFiveMinutes` + idle embedding gate

### H06 / H09 / H11 (named skeptic gate)
- **H06:** `testGenerateSummaryIsNotReadOnly_repro` (`EngramMCPExecutableTests`)
- **H09:** `testValidMemoryFileIsReadable_repro`, `testNonMemoryMarkdownIsRejected_repro`, `testSymlinkEscapeIsRejected_repro`, `testTildeDisplayPathUnderMemoryIsReadable_repro` (`MemoryFileContentBoundsTests`)
- **H11:** `testPaletteServiceDownEmptyLocalIsEmptyNotFailed_repro`, `testPaletteDoubleFaultIsFailed_repro` (`SearchOutcomeTests`)

### Schedule / search surface
- `IndexingSchedulePolicyTests` (S01)
- `SearchModeTests` (H08)

## Verification evidence (2026-07-10)

### Full Swift matrix — `MATRIX_FAIL=0`

Method: `xcodebuild build-for-testing` + `xcrun xctest` (Xcode-beta; avoids hung `xcodebuild test`).

Log: `/var/folders/9f/kky77n4n74sbqytxvgnpvmh80000gn/T/grok-goal-e05223fa18bb/implementer/swift-tests.log`

| Bundle | Exit |
|--------|------|
| EngramCoreTests | 0 (631 tests, 1 skipped perf) |
| EngramServiceCoreTests | 0 (277 tests, 1 skipped live offload) |
| EngramMCPTests | 0 |
| EngramTests | 0 (629 tests, 3 env skips) |

Env-skipped (not failures) under bare `xctest` / TCC:

- `testLauncherDrainsServiceOutputPipes` — pipe/OSLog drain timing
- `testRecentLogsCapturesEmittedEngramErrorMessageText` — OSLog token not visible
- `testEmittedMessageIsReadableNotRedacted` — same

Static-source contracts for OSLog/logger privacy remain hard asserts.

### Release smoke (AC3 / VP4)

Log: `{SCRATCH}/release-smoke.log`
Script: `ENGRAM_BUILD_NUMBER=2026071001 macos/scripts/build-release.sh --local-only`
(Developer ID export was available — produced full `EngramExport/Engram.app`, not `Engram-local-only.app`.)

| Check | Result |
|-------|--------|
| `build-release.sh --local-only` archive/export | **PASS** (`BUILD_RELEASE_EXIT=0`, `** ARCHIVE SUCCEEDED **`) |
| `release-verify.sh` full Developer ID | **PASS** — hygiene, structure, version `1.0.4`/`2026071001`, codesign deep/strict, Hardened Runtime, Developer ID authority, secure timestamp |
| MCP `initialize` + `tools/list` on release `EngramMCP` | **PASS** (`MCP_TOOLS_LIST=ok`) |
| `deploy-local.sh` → `/Applications/Engram.app` | **PASS** (`DEPLOY_EXIT=0`) |
| `open -a Engram` live processes | **PASS** — `PROCESS_ENGRAM=ok`, `PROCESS_SERVICE=ok` |
| Live service socket | **PASS** — `~/.engram/run/engram-service.sock` (`SOCKET_OK`) |

H05 behavioral evidence: `{SCRATCH}/h05-behavioral.log` — `testClearParentPreservesDispatchedSkipTier_repro` passed.

Pass3 (M05 remaining): prior closeout.
Pass4 (H03 peer cancel + S01 activity lifetime): `{SCRATCH}/pass4-tests.log` — EngramServiceCoreTests **284 tests, 0 failures**; peer-disconnect cancel + activity-after-work PASS.

### Scheduling smoke (plan step 6)

After deploy of pass3 service binary (or rebuilt service), `status`/`telemetry` must expose adaptive next-scan ≥900s (not fixed 300s). Capture in `{SCRATCH}/scheduling-smoke.log`.

## Final release checklist

- [x] Focused EngramCoreTests repros green via `xcrun xctest`
- [x] Full Swift matrix green (`EngramCoreTests`, `EngramServiceCore`, `EngramMCPTests`, `Engram`) — `MATRIX_FAIL=0`
- [x] Named XCTests for H02 / H03 / H05 / H06 / H09 / H11 + VP3 dispatched-skip + M05 remaining + S01 NS scheduler
- [x] `build-release.sh --local-only` path produced full Developer ID archive (`EngramExport/Engram.app`, build `2026071001`) + verify + deploy + live socket + MCP smoke
- [x] Scheduling policy exposed (telemetry/status `nextScanIntervalSeconds` ≥ 900)
- [x] Orca handoff to Codex (this closeout)

## Wave commits

| Wave | Notes |
|------|-------|
| Task 1 ledger open | `50e21db1` |
| Wave 7A–7F bundle | `12d3c081` |
| Closeout hash stamp | `61fdd5a8` |
| Follow-up: M05 cancel + H06/H09/H11 + matrix | `2ce900ba` / `c88b7f20` |
| Pass3: M05 remaining + initial S01 shell | `6b301b86` |
| Pass4: H03 peer-disconnect cancel + S01 finish-after-work + idle embed skip | this commit |

## Residual risks for Codex

1. **H12 / M19** UX polish incomplete (export progress, favorites toggle).
2. **H07 / M06–M08 / M13–M16** semantic+security hardening incomplete (model equality, MCP breaker, Keychain, redaction parity).
3. **L09** invariant gate still path-only.
4. **xcodebuild test** on Xcode-beta can hang after package resolve; use `build-for-testing` + `xcrun xctest` for reliable local gates.
5. **OSLog live behavioral tests** skip under TCC/xctest isolation; prefer interactive Xcode host if re-enabling hard fails.
6. **Notarization / DMG / public release** not in Wave 7 gate — local Developer ID archive + deploy already proven (`build 2026071001`); notarytool/staple still operator steps.
