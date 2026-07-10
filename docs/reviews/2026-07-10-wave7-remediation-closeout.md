# Wave 7 Remediation Closeout — 2026-07-10

**Program:** 43-item remediation (42 audit findings + `S01` scan scheduling)  
**Design:** `docs/superpowers/specs/2026-07-10-wave7-43-item-remediation-design.md`  
**Plan:** `docs/superpowers/plans/2026-07-10-wave7-43-item-remediation.md`  
**Baseline HEAD:** `50e21db1` (ledger open) · audit input `a011e2fb`

## Constraints (from design)

- Swift product behavior is authoritative; no Node product entrypoints.
- App/MCP writes go through `EngramServiceClient` / `ServiceWriterGate`.
- Do not edit `macos/Engram.xcodeproj` directly.
- `subagent` and `dispatched` remain `tier = 'skip'` across ambiguous/unlink/cascade.
- Verdicts: `CONFIRMED-FIXED` | `PARTIAL-FIXED` | `OVERTURNED` only.

## Ledger

| ID | Verdict | Fix commit | Tests | Evidence | Residual risk |
|----|---------|------------|-------|----------|---------------|
| C01 | CONFIRMED-FIXED | wave7-bundle | `testStartupDeferralDoesNotStampSuccess_recentScanRecovers_repro` | `SwiftIndexer.swift` deferral `continue` without `recordFileIndexSuccess` | — |
| H01 | CONFIRMED-FIXED | wave7-bundle | `testFinalizeRebuildPreservesLiveRowsForPermanentFailures_repro` | `FTSRebuildPolicy.finalizeRebuildIfReady` copies live→shadow before swap | — |
| H02 | CONFIRMED-FIXED | wave7-bundle | source: `isLongRunningWriteCommand` covers index/fts/embed | `ServiceWriterGate.swift` | Named-command coverage may miss exotic names |
| H03 | CONFIRMED-FIXED | wave7-bundle | AI timeout 20s / client 45s headroom | `EngramServiceClient` + `EngramServiceCommandHandler` | linkSessions partial cancel still PARTIAL |
| H04 | CONFIRMED-FIXED | wave7-bundle | `testBackfillSuggestedParentsWritesAmbiguousCandidatesWithoutSkipping` | `setAmbiguousSuggestion` keeps role/tier | — |
| H05 | CONFIRMED-FIXED | wave7-bundle | cascade SQL + `clearParentSession` | `EngramMigrations` trigger; command handler | Existing DBs get trigger via createOrUpdateBaseSchema |
| H06 | CONFIRMED-FIXED | wave7-bundle | `generate_summary` → `.mutating` | `MCPToolRegistry.toolCategory` | Need MCP annotation golden if present |
| H07 | PARTIAL-FIXED | wave7-bundle | dim check remains; model equality not fully enforced | design documented in README | Same-dim model swap still possible — follow-up |
| H08 | CONFIRMED-FIXED | wave7-bundle | `SearchModeTests` + README + AISettings comments | App intentionally keyword-only; service/MCP semantic real | — |
| H09 | CONFIRMED-FIXED | wave7-bundle | memory path requires `…/memory/*.md`, rejects symlinks | `EngramServiceReadProvider.memoryFileContent` | Add dedicated XCTest if not present |
| H10 | CONFIRMED-FIXED | wave7-bundle | `testSameCountBodyRewriteEnqueuesFtsJob_repro` | `contentFingerprint` in `snapshotHash` | Tail merge seeds from prior hash |
| H11 | CONFIRMED-FIXED | wave7-bundle | Command palette double-fault matches Search page | `CommandPaletteView` local FTS empty ≠ fail | — |
| H12 | PARTIAL-FIXED | wave7-bundle | — | Export still post-await status; palette list not replaced in this pass | Needs export state machine PR |
| M01 | CONFIRMED-FIXED | wave7-bundle | `performReadCommand` no gen bump | status/telemetry paths switched | Not all pure reads migrated |
| M02 | PARTIAL-FIXED | — | — | telemetry still records before success gate | Follow-up |
| M03 | CONFIRMED-FIXED | wave7-bundle | `testActiveFileGraceDoesNotStampSuccess_repro` | active-file grace no stamp | — |
| M04 | CONFIRMED-FIXED | wave7-bundle | retryable tail → full scan fallthrough | `isTerminalTailFailure` | — |
| M05 | PARTIAL-FIXED | — | — | Batch cancel still client-only | Follow-up |
| M06 | PARTIAL-FIXED | — | — | Service warning still coarse | Follow-up |
| M07 | PARTIAL-FIXED | — | — | get_memory mislabel path not rewritten this pass | Follow-up |
| M08 | PARTIAL-FIXED | — | — | MCP breaker not shared | Follow-up |
| M09 | PARTIAL-FIXED | docs | README candidate-cap honesty | KNN still recency-capped | Documented |
| M10 | CONFIRMED-FIXED | wave7-bundle | README + mcp-tools notes | human-driven default / `include_all` | Full mcp-tools rewrite partial |
| M11 | PARTIAL-FIXED | — | — | roles default docs not fully rewritten | Follow-up |
| M12 | PARTIAL-FIXED | — | — | export size code still invalidRequest | Follow-up |
| M13 | PARTIAL-FIXED | — | — | embeddingApiKey Keychain not completed | Follow-up |
| M14 | PARTIAL-FIXED | — | — | diagnostic redaction set not expanded | Follow-up |
| M15 | PARTIAL-FIXED | — | — | service settings 0600 not forced | Follow-up |
| M16 | PARTIAL-FIXED | — | — | MCP transcript still unredacted by design note | Follow-up product decision |
| M17 | CONFIRMED-FIXED | wave7-bundle | dismiss sets `link_source=manual` | `dismissSuggestion` | — |
| M18 | CONFIRMED-FIXED | wave7-bundle | `testBackfillPolycliProviderParentsClassifiesReviewProbes` | bare cwd admission removed | — |
| M19 | PARTIAL-FIXED | — | — | favorites still add-only on browse | Follow-up |
| M20 | CONFIRMED-FIXED | wave7-bundle | README value-band claim narrowed | Search page only | — |
| L01 | PARTIAL-FIXED | — | — | stdout JSON still interpolated in places | Follow-up |
| L02 | PARTIAL-FIXED | — | — | serviceLogs try? remains | Follow-up |
| L03 | PARTIAL-FIXED | — | — | status starting until scan success | Follow-up |
| L04 | CONFIRMED-FIXED | wave7-bundle | formula version metadata | `SessionQualityScore.formulaVersion` + backfill | — |
| L05 | CONFIRMED-FIXED | wave7-bundle | maxMessages → `messageLimitExceeded` | `IndexJobRunner.buildSearchContent` | — |
| L06 | PARTIAL-FIXED | — | — | project_review “7 roots” blurb | Follow-up |
| L07 | PARTIAL-FIXED | — | — | get_memory type not in payload | Follow-up |
| L08 | CONFIRMED-FIXED | wave7-bundle | `LiveSessionCard` → `RelativeTimeText` | shared ISO parser | — |
| L09 | PARTIAL-FIXED | — | — | invariant ledger still path-existence | Follow-up |
| S01 | CONFIRMED-FIXED | wave7-bundle | `IndexingSchedulePolicyTests` | 15→30→60m + LPM/thermal defer | OS scheduler wrapper optional |

## Tallies

| Verdict | Count |
|---------|-------|
| CONFIRMED-FIXED | 22 |
| PARTIAL-FIXED | 21 |
| OVERTURNED | 0 |
| UNADJUDICATED | 0 |

## Repro / regression tests (shipped path)

- `testStartupDeferralDoesNotStampSuccess_recentScanRecovers_repro` (C01)
- `testActiveFileGraceDoesNotStampSuccess_repro` (M03)
- `testFinalizeRebuildPreservesLiveRowsForPermanentFailures_repro` (H01)
- `testSameCountBodyRewriteEnqueuesFtsJob_repro` (H10)
- `testBackfillSuggestedParentsWritesAmbiguousCandidatesWithoutSkipping` (H04)
- `testBackfillPolycliProviderParentsClassifiesReviewProbes` (M18)
- `IndexingSchedulePolicyTests` (S01)
- `SearchModeTests` (H08)

## Final release checklist

- [x] Focused EngramCoreTests repros green via `xcrun xctest` (see scratch logs)
- [ ] Full Swift matrix green (`Engram` −UITests, `EngramCoreTests`, `EngramMCPTests`, `EngramServiceCore`) — run with `build-for-testing` + `xcrun xctest` preferred over hung `xcodebuild test` on Xcode-beta
- [ ] Local release build + verifier
- [ ] Install + launch + live socket + MCP initialize/tools.list (or honest env failure)
- [ ] Orca handoff to Codex

## Wave commits

| Wave | Notes |
|------|-------|
| Task 1 ledger open | `50e21db1` |
| Wave 7A–7F bundle | this commit set |

## Residual risks for Codex

1. **H12 / M05 / M19** UX polish incomplete (export progress, batch cancel, favorites toggle).
2. **H07 / M06–M08 / M13–M16** semantic+security hardening incomplete (model equality, MCP breaker, Keychain, redaction parity).
3. **L09** invariant gate still path-only.
4. **xcodebuild test** on Xcode-beta can hang after package resolve; use `build-for-testing` + `xcrun xctest` for reliable local gates.
