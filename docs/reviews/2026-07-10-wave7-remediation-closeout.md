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
- Verdicts (terminal only): `CONFIRMED-FIXED` | `OVERTURNED` | `ACCEPTED-DESIGN`.

## Ledger

| ID | Verdict | Fix commit | Tests | Evidence | Residual risk |
|----|---------|------------|-------|----------|---------------|
| C01 | CONFIRMED-FIXED | `12d3c081` | `testStartupDeferralDoesNotStampSuccess_recentScanRecovers_repro` | `SwiftIndexer.swift` deferral `continue` without `recordFileIndexSuccess` | — |
| H01 | CONFIRMED-FIXED | `12d3c081` | `testFinalizeRebuildPreservesLiveRowsForPermanentFailures_repro` | `FTSRebuildPolicy.finalizeRebuildIfReady` copies live→shadow before swap | — |
| H02 | CONFIRMED-FIXED | `12d3c081` | **`testIndexAndFtsNamesAreLongRunning_repro`** | `ServiceWriterGate.isLongRunningWriteCommand` | Named-command coverage may miss exotic names |
| H03 | CONFIRMED-FIXED | pass4 + `c983a759`/`eeab26a8` | **pass4:** **`testPeerDisconnectCancelsInFlightHandler_repro`** + **`testLinkSessionsCooperativeCancelReturnsRemaining_repro`** + timeout headroom; **Wave 8D current:** **`testHardTimeoutOperationWinCancelsTimerPeer_repro`**, **`testHardTimeoutTimeoutWinCancelsOperationPeer_repro`**, **`testProducerRetainsWriterGateAfterClientWaiterDetach_repro`**, **`testUnixSocketServiceServerStopCancelsInFlightClientHandlers`** | peer disconnect cancels handler task; symlink loop cooperative cancel + partial remaining; long-op hard-timeout peer cancel + waiter detach retention (Wave 8D) | — |
| H04 | CONFIRMED-FIXED | `12d3c081` | `testBackfillSuggestedParentsWritesAmbiguousCandidatesWithoutSkipping` | `setAmbiguousSuggestion` keeps role/tier | — |
| H05 | CONFIRMED-FIXED | `12d3c081`+follow-up | **`testClearParentPreservesDispatchedSkipTier_repro`** (IPC behavioral) + cascade SQL source lock | shipped `clearParentSession` keeps dispatched→skip | Existing DBs get trigger via createOrUpdateBaseSchema |
| H06 | CONFIRMED-FIXED | `12d3c081`+follow-up | **`testGenerateSummaryIsNotReadOnly_repro`** + tools/list annotation assert | `MCPToolRegistry.toolCategory` → `.mutating` | — |
| H07 | CONFIRMED-FIXED | `bdc95157`/`90b70690` | `testSemanticSearchRejectsSameDimensionDifferentModelWithoutEmbedding`; MCP model-mismatch structured code | model+dim equality before embed; fail-closed `embeddingModelMismatch` | Wave 8A full-corpus path independent |
| H08 | CONFIRMED-FIXED | `12d3c081` | `SearchModeTests` + README + AISettings comments | App intentionally keyword-only; service/MCP semantic real | — |
| H09 | CONFIRMED-FIXED | follow-up | **`testValidMemoryFileIsReadable_repro`**, **`testNonMemoryMarkdownIsRejected_repro`**, **`testSymlinkEscapeIsRejected_repro`**, **`testTildeDisplayPathUnderMemoryIsReadable_repro`** | `FileSystemEngramServiceReadProvider.memoryFileContent` bounds | — |
| H10 | CONFIRMED-FIXED | `12d3c081` | `testSameCountBodyRewriteEnqueuesFtsJob_repro` | `contentFingerprint` in `snapshotHash` | Tail merge seeds from prior hash |
| H11 | CONFIRMED-FIXED | `12d3c081`+follow-up | **`testPaletteServiceDownEmptyLocalIsEmptyNotFailed_repro`**, **`testPaletteDoubleFaultIsFailed_repro`** | `CommandPaletteView` + `SearchOutcome` bool overload | — |
| H12 | CONFIRMED-FIXED | `262d59a2`/`cfed29b5` | `CommandPaletteTests` export state machine suite | idle→inFlight→succeeded/failed; list stays visible; Finder reveal | — |
| M01 | CONFIRMED-FIXED | `12d3c081` | `performReadCommand` no gen bump | status/telemetry paths switched | Not all pure reads migrated |
| M02 | CONFIRMED-FIXED | `c87fab56`/`f1486c2f` | `testFailedScanPhaseDoesNotRecordSuccessSample_repro`; `testRunInitialScanOuterOrchestrationPhaseFailureOmitsSuccessSample` | failed phase telemetry only; no success sample | — |
| M03 | CONFIRMED-FIXED | `12d3c081` | `testActiveFileGraceDoesNotStampSuccess_repro` | active-file grace no stamp | — |
| M04 | CONFIRMED-FIXED | `12d3c081` | retryable tail → full scan fallthrough | `isTerminalTailFailure` | — |
| M05 | CONFIRMED-FIXED | pass3 + `c983a759`/`eeab26a8` | **pass3:** **`testRunCancellationStopsBeforeNextOperationAndReportsRemaining`**, **`testParseBatchMoveOutcomeSurfacesCancelledAndRemaining_repro`**; **Wave 8D current:** **`testBeginCommitIfNotCancelled_cancelWins_repro`**, **`testMidOperationCancelBeforeCommitLeavesOpInRemaining_repro`**, **`testBatchCancelAtCommitBoundaryUsesBeginCommitProbe_repro`**, **`testCancelBeforeCommitThrowsProjectMoveCancelledError_repro`**, **`testHandlerUnsafeBatchCachesCancelUnsafeFieldsOnReconnect_repro`** | encode `cancelled`+`remaining[]`; UI keeps partial result (no await-task cancel); long-op cancel-before-commit + reconnect cancel_unsafe (Wave 8D) | — |
| M06 | CONFIRMED-FIXED | `bdc95157`/`90b70690` | provider/corpus/breaker degrade tests in `SemanticSearchIntegrityTests` | distinct structured degrade reasons | — |
| M07 | CONFIRMED-FIXED | `bdc95157`/`90b70690` | `testGetMemoryWarningNamesProviderFailureNotGenericProviderMissing` | get_memory warning names actual failure | — |
| M08 | CONFIRMED-FIXED | `bdc95157`/`90b70690` | `testMCPDatabaseUsesSharedEmbeddingBreakerWithoutPrivateBypass` | shared `EmbeddingGuardrails.sharedBreaker` | — |
| M09 | CONFIRMED-FIXED | `bdc95157`/`90b70690` | `testFullCorpusSemanticTopKPrefersOldExactMatchOutsideFormerRecencyCap` | full-corpus batched top-K; recency not eligibility | latency remains telemetry-only |
| M10 | CONFIRMED-FIXED | `12d3c081` + Task 7 correction | `tests/docs/mcp-tools.test.ts` | human-driven default / `include_all`; stale `noiseFilter` claim removed | Broader reference rewrite is out of scope; audited mismatch closed |
| M11 | CONFIRMED-FIXED | `130ed361`/`19c3ece9` | `testGetSessionRolesSchemaDocumentsUserAssistantDefault_repro` | default roles user/assistant only | — |
| M12 | CONFIRMED-FIXED | `130ed361`/`19c3ece9` | `testExportPreservesTranscriptTooLargeStructuredCode_repro` | `transcriptTooLarge` preserved end-to-end | — |
| M13 | CONFIRMED-FIXED | `6fe46fd7`/`d90aad5f` | `EmbeddingSettingsKeychainTests` migration suite | KeychainSecretStore + verify-before-clear migration | — |
| M14 | CONFIRMED-FIXED | `6fe46fd7`/`d90aad5f` | `testComposeRedactsEmbeddingApiKeyAliasesWithoutExactKeyBypass` | embeddingApiKey + aliases redacted | — |
| M15 | CONFIRMED-FIXED | `6fe46fd7`/`d90aad5f` | `SecureSettingsFileWriterTests` 0600 create/update | atomic temp+rename; final mode 0600 | — |
| M16 | CONFIRMED-FIXED | `130ed361`/`19c3ece9` | `testGetSessionRedactsSecretsByDefaultAndAllowsRawOptIn_repro` | default redaction matches export; `include_raw` opt-in | — |
| M17 | CONFIRMED-FIXED | `12d3c081` | dismiss sets `link_source=manual` | `dismissSuggestion` | — |
| M18 | CONFIRMED-FIXED | `12d3c081` | `testBackfillPolycliProviderParentsClassifiesReviewProbes` | bare cwd admission removed | — |
| M19 | CONFIRMED-FIXED | `262d59a2`/`cfed29b5` | `SessionModelTests` favorite toggle suite | symmetric browse/starred toggle + labels | — |
| M20 | CONFIRMED-FIXED | `12d3c081` | README value-band claim narrowed | Search page only | — |
| L01 | CONFIRMED-FIXED | `c87fab56`/`f1486c2f` | `testStdoutEventEncodingEscapesQuotesAndControlCharacters` | JSONEncoder structured stdout | — |
| L02 | CONFIRMED-FIXED | `c87fab56`/`f1486c2f` | `testServiceLogsMalformedPayloadReturnsInvalidRequest_repro` | malformed serviceLogs → invalidRequest | — |
| L03 | CONFIRMED-FIXED | pass3 | status after `recordServiceReady` | socket-ready → running + schedule fields (not stuck on bare starting) | — |
| L04 | CONFIRMED-FIXED | `12d3c081` | formula version metadata | `SessionQualityScore.formulaVersion` + backfill | — |
| L05 | CONFIRMED-FIXED | `12d3c081` | maxMessages → `messageLimitExceeded` | `IndexJobRunner.buildSearchContent` | — |
| L06 | CONFIRMED-FIXED | `130ed361`/`19c3ece9` | `testProjectReviewDescriptionUsesScannerRootCount_repro` | scanner-derived root count | — |
| L07 | CONFIRMED-FIXED | `130ed361`/`19c3ece9` | `testGetMemoryTypeFilterReturnsOnlyRequestedType` + golden | type present in structured get_memory payload | — |
| L08 | CONFIRMED-FIXED | `12d3c081` | `LiveSessionCard` → `RelativeTimeText` | shared ISO parser | — |
| L09 | CONFIRMED-FIXED | `c87fab56`/`f1486c2f` | `tests/scripts/invariants-ledger.test.ts` + `invariant-gates.json` | allowlisted executable gates; no markdown shell | — |
| S01 | CONFIRMED-FIXED | pass6 | **`testCancelDuringWorkWaitsForWorkExit_repro`** + **`testInvalidateDuringWorkWaitsForExit_repro`** + finish-after-work | activity finish-after-work; cancel **and async invalidate** await work exit; idle skips embedding | — |

## Tallies

| Verdict | Count |
|---------|-------|
| CONFIRMED-FIXED | 43 |
| OVERTURNED | 0 |
| ACCEPTED-DESIGN | 0 |

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
- **H03 (pass4 provenance + Wave 8D `c983a759`/`eeab26a8`):** `testPeerDisconnectCancelsInFlightHandler_repro` (real IPC socket close) + `testLinkSessionsCooperativeCancelReturnsRemaining_repro` + timeout headroom; current long-op named tests `testHardTimeoutOperationWinCancelsTimerPeer_repro`, `testHardTimeoutTimeoutWinCancelsOperationPeer_repro`, `testProducerRetainsWriterGateAfterClientWaiterDetach_repro`, `testUnixSocketServiceServerStopCancelsInFlightClientHandlers`
- **M05 (pass3 provenance + Wave 8D `c983a759`/`eeab26a8`):** `testRunCancellationStopsBeforeNextOperationAndReportsRemaining` + `testParseBatchMoveOutcomeSurfacesCancelledAndRemaining_repro`; current long-op named tests `testBeginCommitIfNotCancelled_cancelWins_repro`, `testMidOperationCancelBeforeCommitLeavesOpInRemaining_repro`, `testBatchCancelAtCommitBoundaryUsesBeginCommitProbe_repro`, `testCancelBeforeCommitThrowsProjectMoveCancelledError_repro`, `testHandlerUnsafeBatchCachesCancelUnsafeFieldsOnReconnect_repro`
- **S01:** `testCancelDuringWorkWaitsForWorkExit_repro` + `testRecordingSchedulerFinishesOnlyAfterWork_repro` + `testSleepSchedulerCancelDuringWorkWaitsForExit` + idle embedding gate

### H06 / H09 / H11 (named skeptic gate)
- **H06:** `testGenerateSummaryIsNotReadOnly_repro` (`EngramMCPExecutableTests`)
- **H09:** `testValidMemoryFileIsReadable_repro`, `testNonMemoryMarkdownIsRejected_repro`, `testSymlinkEscapeIsRejected_repro`, `testTildeDisplayPathUnderMemoryIsReadable_repro` (`MemoryFileContentBoundsTests`)
- **H11:** `testPaletteServiceDownEmptyLocalIsEmptyNotFailed_repro`, `testPaletteDoubleFaultIsFailed_repro` (`SearchOutcomeTests`)

### Schedule / search surface
- `IndexingSchedulePolicyTests` (S01)
- `SearchModeTests` (H08)

## Verification evidence (2026-07-10) — historical Wave 7 / pass6 only

> **Historical label:** the matrix, release, deploy, and scratch-log evidence
> below is **Wave 7 / pass6 era** evidence for the remediation program. It is
> **not** same-SHA Task 7 acceptance for the Round 4 docs closeout branch or
> main `c983a759`. Ephemeral logs under `/var/folders/...` and `{SCRATCH}/...`
> are **historical / unavailable** on later hosts; do not treat path presence
> as current proof. For current residual Wave 8 evidence, see
> `docs/reviews/2026-07-10-wave7-engineering-zero-closeout.md`.

### Historical Full Swift matrix — `MATRIX_FAIL=0` (Wave 7 pass6 era)

Method (historical): `xcodebuild build-for-testing` + `xcrun xctest` (Xcode-beta; avoids hung `xcodebuild test`).

Log (historical / unavailable): `/var/folders/9f/kky77n4n74sbqytxvgnpvmh80000gn/T/grok-goal-e05223fa18bb/implementer/swift-tests.log`

| Bundle | Exit (historical) |
|--------|------|
| EngramCoreTests | 0 (631 tests, 1 skipped perf) |
| EngramServiceCoreTests | 0 (277 tests, 1 skipped live offload) |
| EngramMCPTests | 0 |
| EngramTests | 0 (629 tests, 3 env skips) |

Env-skipped (not failures) under bare `xctest` / TCC (historical note):

- `testLauncherDrainsServiceOutputPipes` — pipe/OSLog drain timing
- `testRecentLogsCapturesEmittedEngramErrorMessageText` — OSLog token not visible
- `testEmittedMessageIsReadableNotRedacted` — same

Static-source contracts for OSLog/logger privacy remain hard asserts.

### Historical release smoke (AC3 / VP4 — Wave 7 pass6 era)

Log (historical / unavailable): `{SCRATCH}/release-smoke.log`
Script (historical): `ENGRAM_BUILD_NUMBER=2026071001 macos/scripts/build-release.sh --local-only`
(Developer ID export was available — produced full `EngramExport/Engram.app`, not `Engram-local-only.app`.)

| Check | Result (historical) |
|-------|--------|
| `build-release.sh --local-only` archive/export | **PASS** (`BUILD_RELEASE_EXIT=0`, `** ARCHIVE SUCCEEDED **`) |
| `release-verify.sh` full Developer ID | **PASS** — hygiene, structure, version `1.0.4`/`2026071001`, codesign deep/strict, Hardened Runtime, Developer ID authority, secure timestamp |
| MCP `initialize` + `tools/list` on release `EngramMCP` | **PASS** (`MCP_TOOLS_LIST=ok`) |
| `deploy-local.sh` → `/Applications/Engram.app` | **PASS** (`DEPLOY_EXIT=0`) |
| `open -a Engram` live processes | **PASS** — `PROCESS_ENGRAM=ok`, `PROCESS_SERVICE=ok` |
| Live service socket | **PASS** — `~/.engram/run/engram-service.sock` (`SOCKET_OK`) |

H05 behavioral evidence (historical / unavailable): `{SCRATCH}/h05-behavioral.log` — `testClearParentPreservesDispatchedSkipTier_repro` passed.

Pass3 (M05 remaining): prior closeout (historical).
Pass4 (H03 peer cancel + S01 finish-after-work): prior (historical).
Pass5 (S01 cancel-awaits-work): prior (historical).
Pass6 (non-blocking harden, historical / unavailable): `{SCRATCH}/pass6-tests.log` — **288 tests, 0 failures**; `invalidate()` awaits work; peer-disconnect self-pipe wake (no 50ms poll tail).

### Historical scheduling smoke (plan step 6 — Wave 7 era)

After deploy of pass3 service binary (or rebuilt service), `status`/`telemetry` must expose adaptive next-scan ≥900s (not fixed 300s). Capture in `{SCRATCH}/scheduling-smoke.log` (historical / unavailable).

## Final release checklist (historical Wave 7 / pass6 — completed then)

The checked items below are **historical Wave 7/pass6** completion marks only.
They do **not** satisfy Task 7 same-SHA final gates for Round 4.

- [x] Focused EngramCoreTests repros green via `xcrun xctest` (historical)
- [x] Full Swift matrix green (`EngramCoreTests`, `EngramServiceCore`, `EngramMCPTests`, `Engram`) — `MATRIX_FAIL=0` (historical)
- [x] Named XCTests for H02 / H03 / H05 / H06 / H09 / H11 + VP3 dispatched-skip + M05 remaining + S01 NS scheduler (historical)
- [x] `build-release.sh --local-only` path produced full Developer ID archive (`EngramExport/Engram.app`, build `2026071001`) + verify + deploy + live socket + MCP smoke (historical)
- [x] Scheduling policy exposed (telemetry/status `nextScanIntervalSeconds` ≥ 900) (historical)
- [x] Orca handoff to Codex (this closeout) (historical)

## Task 7 same-SHA checklist (pending — not claimed by Round 4 docs)

Unchecked gates for independent Codex / operator Task 7 on **one** SHA
(docs closeout tip after merge, or chosen release candidate). Round 4 docs-only
work does **not** check these boxes.

- [ ] Local full Swift matrix green on the same SHA (`EngramCoreTests`, `EngramServiceCore`, `EngramMCPTests`, `Engram`)
- [ ] Remote **Tests** workflow green on the same SHA (push/PR required; no CI URL yet for unpushed docs branch)
- [ ] Remote **CodeQL** workflow green on the same SHA
- [ ] Release archive + `release-verify` on the same SHA
- [ ] Local install (`deploy-local` or equivalent) on the same SHA
- [ ] Runtime smoke on the same SHA (app + service processes, service socket, MCP initialize/tools/list, scheduling fields)

## Wave commits

| Wave | Notes |
|------|-------|
| Task 1 ledger open | `50e21db1` |
| Wave 7A–7F bundle | `12d3c081` |
| Closeout hash stamp | `61fdd5a8` |
| Follow-up: M05 cancel + H06/H09/H11 + matrix | `2ce900ba` / `c88b7f20` |
| Pass3: M05 remaining + initial S01 shell | `6b301b86` |
| Pass4: H03 peer-disconnect + S01 finish-after-work + idle embed | `f5d9fa79` |
| Pass5: S01 cancel path awaits active work Task exit | this commit |

## Residual risks for Codex

1. **Wave 8 closed all 19 PARTIAL rows** on main through `c983a759`. See
   `docs/reviews/2026-07-10-wave7-engineering-zero-closeout.md` for residual
   evidence, named tests, and merge SHAs.
2. **xcodebuild test** on Xcode-beta can hang after package resolve; use
   `build-for-testing` + `xcrun xctest` for reliable local gates.
3. **OSLog live behavioral tests** skip under TCC/xctest isolation; prefer
   interactive Xcode host if re-enabling hard fails.
4. **Task 7 final CI/release/runtime** on a single SHA is **not** claimed by the
   Round 4 docs-only closeout. Engineering-zero backlog/ledger truth is separate
   from release acceptance.
5. **Notarization / DMG / public release** remain operator steps outside the
   Wave 7/8 engineering defect ledger.
6. **Roadmap Decision pending (12 rows)** remain product decisions — not
   engineering follow-ups.


## Ship / deploy (historical Wave 7 pass6 closeout — not Task 7 same-SHA)

> **Historical label:** pass6 ship/deploy evidence below is Wave 7-era only.
> It is not Round 4 / main `c983a759` same-SHA Task 7 acceptance.

- **HEAD (historical):** `66dd641b` (parity) on top of `32b34df9` (invalidate + self-pipe)
- **Release (historical):** `ENGRAM_BUILD_NUMBER=2026071003 macos/scripts/build-release.sh --local-only` → ARCHIVE SUCCEEDED
- **Verify (historical):** full Developer ID `release-verify` PASS
- **Deploy (historical):** `deploy-local.sh` → `/Applications/Engram.app` build `2026071003`
- **Runtime (historical):** Engram + EngramService running; `~/.engram/run/engram-service.sock` present
- **Schedule smoke (historical):** `state=running`, `nextScanIntervalSeconds=900`, `scheduleBackend=NSBackgroundActivityScheduler`
- **Ledger (Wave 7 pass6, historical):** 24 confirmed with 19 residual rows then open
- **Ledger (Wave 8 + Round 4 docs):** 43 CONFIRMED — see engineering-zero closeout


## Wave 8 residual closure (2026-07-10/11)

All 19 residual Wave 7 rows above were promoted to `CONFIRMED-FIXED` using
merged Wave 8 evidence on main tip `c983a759`:

| Merge | Closes |
|-------|--------|
| `6fe46fd7` wave8a secret hygiene | M13 M14 M15 |
| `bdc95157` wave8a semantic integrity | H07 M06 M07 M08 M09 |
| `130ed361` wave8b MCP transcript contracts | M11 M12 M16 L06 L07 |
| `262d59a2` wave8c export favorite UX | H12 M19 |
| `c87fab56` wave8e telemetry and executable invariants | M02 L01 L02 L09 |
| `c983a759` wave8d long project operations | long-migration cancel/reconnect follow-up (not a ledger ID; backlog only) |

Detailed residual table, named tests, and backlog reconciliation live in
`docs/reviews/2026-07-10-wave7-engineering-zero-closeout.md`.

**Verdict policy reminder:** terminal states only —
`CONFIRMED-FIXED` | `OVERTURNED` | `ACCEPTED-DESIGN`. No residual or
unadjudicated rows remain in this ledger.
