# Wave 7 43-Item Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 42 audited defects plus the scan-I/O scheduling defect, then build, install, launch, and smoke-test Engram once at the end.

**Exact coverage:** `C01`; `H01`, `H02`, `H03`, `H04`, `H05`, `H06`, `H07`, `H08`, `H09`, `H10`, `H11`, `H12`; `M01`, `M02`, `M03`, `M04`, `M05`, `M06`, `M07`, `M08`, `M09`, `M10`, `M11`, `M12`, `M13`, `M14`, `M15`, `M16`, `M17`, `M18`, `M19`, `M20`; `L01`, `L02`, `L03`, `L04`, `L05`, `L06`, `L07`, `L08`, `L09`; `S01`.

**Architecture:** Six sequential waves isolate index integrity, lifecycle classification, service scheduling, semantic/security contracts, SwiftUI behavior, and documentation/gates. Every behavior change is test-first, every audit claim is rechecked against current source, and the final release gate runs only after all 43 ledger entries are closed.

**Tech Stack:** Swift 6, Swift Concurrency, GRDB/SQLite/FTS5, Foundation `NSBackgroundActivityScheduler`, XCTest, XcodeGen, native Unix-socket IPC, Keychain Services.

## Global Constraints

- Read `AGENTS.md` and `docs/superpowers/specs/2026-07-10-wave7-43-item-remediation-design.md` before editing.
- Treat Swift as product source of truth and preserve the single-writer service boundary.
- Never edit `macos/Engram.xcodeproj` directly.
- Use TDD: add one failing regression, run it and observe the expected failure, implement the minimum fix, rerun focused tests, then commit.
- Do not build, install, launch, or restart Engram until Task 8.
- Do not stage or modify unrelated work, including `docs/reviews/2026-07-10-multi-expert-audit.md` if it appears as an untracked file.
- Each task must update `docs/reviews/2026-07-10-wave7-remediation-closeout.md` with item verdict, evidence, tests, and commit.
- `OVERTURNED` is acceptable only with exact current `file:line` evidence and a regression test or contract proving the report claim false.

---

### Task 1: Establish the 43-Item Ledger and Baseline

**Files:**
- Create: `docs/reviews/2026-07-10-wave7-remediation-closeout.md`
- Test: repository status and focused preflight commands

**Interfaces:**
- Consumes: the approved design and current source at the implementation worktree HEAD.
- Produces: a table keyed by `C01`, `H01-H12`, `M01-M20`, `L01-L09`, `S01` with columns `Verdict`, `Fix commit`, `Tests`, `Evidence`, `Residual risk`.

- [ ] **Step 1: Record immutable baseline**

Run:

```bash
git status --short --branch
git rev-parse HEAD
pgrep -fl 'Engram|EngramService' || true
test -S "$HOME/.engram/run/engram-service.sock" && echo socket-present || echo socket-absent
```

Expected: clean implementation worktree; Engram app/service absent; MCP helpers may exist because external clients own them.

- [ ] **Step 2: Create the ledger with all 43 identifiers**

Each row starts `UNADJUDICATED`. Add the design constraints and final release checklist verbatim. Do not copy speculative prose from the source audit as proof.

- [ ] **Step 3: Verify exact identifier coverage**

Run:

```bash
for id in C01 H{01..12} M{01..20} L{01..09} S01; do rg -q "\| $id \|" docs/reviews/2026-07-10-wave7-remediation-closeout.md || echo "missing $id"; done
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add docs/reviews/2026-07-10-wave7-remediation-closeout.md
git commit -m "docs: open wave 7 remediation ledger"
```

### Task 2: Wave 7A - Index and FTS Integrity

**Files:**
- Modify: `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift`
- Modify: `macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift`
- Modify: `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift`
- Modify: `macos/EngramCoreWrite/Indexing/IndexJobRunner.swift`
- Modify: `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift`
- Modify: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Test: `macos/EngramCoreTests/IndexerParityTests.swift`
- Test: `macos/EngramCoreTests/IndexerParseOnceTests.swift`
- Test: `macos/EngramCoreTests/Database/FTSRebuildPolicyTests.swift`
- Test: `macos/EngramCoreTests/Database/FTSIncrementalTests.swift`
- Test: `macos/EngramCoreTests/IndexJobAndMaintenanceTests.swift`

**Interfaces:**
- Produces: lossless deferral semantics, deterministic searchable-content fingerprinting, and a rebuild-readiness contract that cannot swap away live rows.

- [ ] **Step 1: RED for C01 and M03**

Add tests proving startup skip and active-file grace do not upsert success for a changed identity, and that a subsequent recent scan parses the changed file. Run only the new tests; expected failure is that parse count remains zero after the recovery scan or state matches the new identity prematurely.

- [ ] **Step 2: GREEN for C01 and M03**

Remove success stamping from deferred branches. Preserve the last parsed `FileIndexState`; do not add a fake success or terminal state. Run the new tests and the existing startup-skip tests.

- [ ] **Step 3: RED/GREEN for M04**

Add a tail adapter fixture whose tail parse returns a retryable failure while full scan succeeds. Assert one full-scan snapshot is written in the same pass. Change the failure branch to fall through only for retryable tail failures; parser-limit terminal failures remain recorded and skipped.

- [ ] **Step 4: RED for H01**

Seed live FTS rows plus `failed_permanent` and `not_applicable` FTS jobs, begin a version rebuild, complete recoverable jobs, and assert finalization either preserves those live rows in the shadow table or refuses the swap. Expected current failure: finalization succeeds and the rows disappear.

- [ ] **Step 5: GREEN for H01**

Before swap, copy live rows for visible sessions missing from the shadow table inside the same transaction. Exclude skip-tier and deleted/orphan rows according to existing FTS eligibility. Finalization must then verify zero eligible sessions lack shadow content. Preserve current live search until this proof passes.

- [ ] **Step 6: RED/GREEN for H10**

In the single message pass, feed a deterministic SHA-256 accumulator with role plus normalized searchable content. Include its digest in `snapshotHash`. Add a same-count, same-summary body rewrite regression that must enqueue FTS and embedding jobs. Tail merge may extend only when a persisted compatible digest exists; otherwise return `nil` to force full parse.

- [ ] **Step 7: RED/GREEN for L04 and L05**

Version the quality-score formula in metadata so stale-version non-zero scores re-evaluate once. Make transcript truncation return `not_applicable` or permanent failure rather than `completed`. Add one regression for each contract.

- [ ] **Step 8: Verify and commit**

Run:

```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
```

Expected: PASS. Update ledger rows `C01`, `H01`, `H10`, `M03`, `M04`, `L04`, `L05`, then commit only Wave 7A files.

### Task 3: Wave 7B - Parent and Tier Lifecycle

**Files:**
- Modify: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Test: `macos/EngramCoreTests/StartupBackfillTests.swift`
- Test: `macos/EngramCoreTests/IndexJobAndMaintenanceTests.swift`
- Test: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`

**Interfaces:**
- Produces: one invariant helper/predicate for agent roles that must remain skip-tier and durable manual suggestion dismissal.

- [ ] **Step 1: RED for H04 and H05**

Add tests for dispatched ambiguous suggestion, dispatched confirmed-parent cascade, dispatched suggested-parent cascade, and `clearParentSession`. Each must retain `agent_role = 'dispatched'` and `tier = 'skip'` while clearing only relationship fields.

- [ ] **Step 2: GREEN for H04 and H05**

Change ambiguous update, cascade trigger, migration repair path, and clear-parent SQL to preserve skip when role is `subagent` or `dispatched`. Keep normal sessions' existing reset behavior.

- [ ] **Step 3: RED/GREEN for M17**

Dismiss a suggestion, rerun startup suggestion backfill, and assert it is not recreated. Persist a manual rejection marker using the existing relationship provenance fields; do not create a parallel preference store.

- [ ] **Step 4: RED/GREEN for M18**

Add same-cwd overlapping ordinary sessions without dispatch evidence and assert Polycli does not classify them. Retain a positive fixture with explicit dispatch evidence.

- [ ] **Step 5: Verify and commit**

Run `EngramCoreTests` and `EngramServiceCore`; update four ledger rows and commit Wave 7B.

### Task 4: Wave 7C - Service, IPC, Cancellation, and Scan Scheduling

**Files:**
- Create: `macos/EngramService/Core/IndexingSchedulePolicy.swift`
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift`
- Modify: `macos/EngramService/Core/ServiceWriterGate.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Modify: `macos/Engram/Views/Projects/BatchMoveSheet.swift`
- Modify: `macos/project.yml` if the new file is not automatically included
- Test: `macos/EngramServiceCoreTests/IndexingSchedulePolicyTests.swift`
- Test: `macos/EngramServiceCoreTests/ServiceWriterGateTests.swift`
- Test: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`

**Interfaces:**
- Produces: `IndexingSchedulePolicy` with pure next-interval and defer decisions; injected system conditions; explicit long-maintenance gate classification; structured cancellation/partial results.

- [ ] **Step 1: RED for S01 policy**

Test intervals `15m -> 30m -> 60m`, cap at `60m`, reset to `15m` after indexed work, manual refresh due immediately, and defer under Low Power Mode or serious/critical thermal state. Tests must use deterministic clock and conditions.

- [ ] **Step 2: GREEN for S01 policy**

Implement the pure policy without timers, subprocesses, or global mutable state. Use explicit `ScanOutcome(indexed: Int, failed: Bool)` and `SystemConditions(lowPower: Bool, thermalState: ...)` inputs.

- [ ] **Step 3: RED/GREEN for OS scheduling integration**

Wrap `NSBackgroundActivityScheduler` behind an injectable protocol. Configure background QoS, interval, and tolerance. Honor `shouldDefer` before each optional phase and report `.deferred` to the scheduler. Keep startup scan separate.

- [ ] **Step 4: RED/GREEN for maintenance decoupling**

Prove an idle incremental scan does not run parent backfill, repo probes, or embedding work; prove due FTS/backup/optimize maintenance still runs on its own gate; prove one-hour fallback remains scheduled.

- [ ] **Step 5: RED/GREEN for H02 and M01**

Classify index/backfill/FTS/embed operations as long maintenance so followers do not receive false `WriterBusy`. Pure read commands must use the read path and leave `databaseGeneration` unchanged.

- [ ] **Step 6: RED/GREEN for H03 and M05**

Set provider timeout below IPC frame timeout with explicit headroom. Add cancellation checks between symlink and batch-move units. Return completed/remaining counts when partial filesystem work exists; do not report an all-or-nothing failure.

- [ ] **Step 7: RED/GREEN for M02 and L01-L03**

Record scan success only when required phases succeed; JSON-encode fatal stdout events; surface malformed service-log payloads as structured errors; move status out of `.starting` after readiness even when optional maintenance is degraded.

- [ ] **Step 8: Regenerate if needed, verify, and commit**

Run XcodeGen only if `project.yml` changed. Run `EngramServiceCore` and focused `EngramTests` without launching the app. Update ten ledger rows and commit Wave 7C.

### Task 5: Wave 7D - Semantic, MCP, and Security

**Files:**
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramService/Core/EngramServiceReadProvider.swift`
- Modify: `macos/Shared/EngramCore/AI/EmbeddingSettings.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Modify: `macos/Engram/Core/DiagnosticBundleComposer.swift`
- Modify: `macos/EngramMCP/Core/MCPTranscriptTools.swift`
- Modify: `macos/EngramMCP/Core/MCPTranscriptReader.swift`
- Modify: `macos/EngramService/Core/TranscriptExportService.swift`
- Test: `macos/EngramMCPTests/`
- Test: `macos/EngramServiceCoreTests/`
- Test: `macos/EngramTests/`

**Interfaces:**
- Produces: honest MCP annotations, exact model/dimension checks, shared breaker semantics, canonical memory confinement, Keychain migration, redaction and permission guarantees.

- [ ] **Step 1: Adjudicate M06-M16 and L06-L07**

For each item, record exact source lines and current behavior in the ledger before editing. Resolve the M16 compatibility decision by preserving the stricter existing redaction policy; raw transcript exposure requires an explicit opt-in contract, never an undocumented default.

- [ ] **Step 2: RED/GREEN for H06-H07**

Assert `generate_summary.readOnlyHint == false`. Assert same-dimension/different-model semantic queries fail with a structured model-mismatch error in both MCP and service paths.

- [ ] **Step 3: RED/GREEN for H09**

Test valid memory file, non-memory `.md`, direct symlink, ancestor symlink, directory, and path-prefix collision. Resolve canonical URL and require containment beneath a `memory` directory under `~/.claude/projects`; reject symlinks before reading.

- [ ] **Step 4: RED/GREEN for M06-M09**

Add distinct fallback reasons, shared breaker behavior, and truthful candidate-cap metadata. Do not claim full-corpus KNN unless the implementation actually searches it within measured limits.

- [ ] **Step 5: RED/GREEN for M10-M12 and L06-L07**

Lock runtime schemas and structured errors for list filters, transcript roles, `transcriptTooLarge`, project root counts, and memory result type.

- [ ] **Step 6: RED/GREEN for M13-M15**

Test interrupted and idempotent legacy-key migration to Keychain, diagnostic redaction of every legacy/current key spelling, and mode `0600` after service settings rewrite. Use atomic write then permission-preserving rename.

- [ ] **Step 7: RED/GREEN for M16**

Apply the chosen redaction contract consistently to MCP transcript reads and export. Add explicit tests for default redaction and opt-in behavior if an opt-in already exists; do not invent a broad raw-data flag.

- [ ] **Step 8: Verify and commit**

Run `EngramMCPTests`, `EngramServiceCore`, and focused `EngramTests`. Update 17 ledger rows and commit Wave 7D.

### Task 6: Wave 7E - SwiftUI Behavior

**Files:**
- Modify: `macos/Engram/Views/CommandPaletteView.swift`
- Modify: `macos/Engram/Views/Pages/SessionsPageView.swift`
- Modify: `macos/Engram/Components/ExpandableSessionCard.swift`
- Modify: `macos/Engram/Components/LiveSessionCard.swift`
- Test: `macos/EngramTests/`
- Test: `macos/EngramUITests/` only where no unit seam exists

**Interfaces:**
- Produces: testable palette search/export state, symmetric favorites, shared date parsing.

- [ ] **Step 1: RED/GREEN for H11**

Extract or reuse the Search page's double-fault decision. Test service failure plus empty local success as empty results, and service failure plus local failure as unavailable.

- [ ] **Step 2: RED/GREEN for H12**

Model export as idle/in-flight/success/failure while preserving results and selection. Test progress visibility and Finder reveal availability.

- [ ] **Step 3: RED/GREEN for M19 and L08**

Test add/remove favorite from both Browse and Starred surfaces. Replace fractional-only parsing with the shared ISO parser and test timestamps with and without fractional seconds.

- [ ] **Step 4: Verify and commit**

Run focused `EngramTests`; use `EngramUITests` only for behavior not covered by extracted policies. Update four ledger rows and commit Wave 7E.

### Task 7: Wave 7F - Documentation, Claims, and Gates

**Files:**
- Modify: `README.md`
- Modify: `docs/mcp-tools.md`
- Modify: `macos/Engram/Views/SearchSupport.swift`
- Modify: `macos/Engram/Views/Settings/AISettingsSection.swift`
- Modify: `macos/EngramTests/SearchModeTests.swift`
- Modify: `scripts/check-invariants-ledger.sh`
- Modify: `scripts/perf/capture-node-baseline.ts`
- Modify: `.github/workflows/perf.yml`
- Modify: `docs/reviews/2026-07-10-wave7-remediation-closeout.md`

**Interfaces:**
- Produces: runtime-accurate claims, executable invariant gate, explicit performance-gate status, closed 43-row ledger.

- [ ] **Step 1: Fix H08, M10, M11, M20 claims**

State: App UI intentionally keyword-only; service semantic may fall back with a reason; MCP semantic hard-fails when unavailable. Align list filter, transcript roles, and value-band locations to runtime tests.

- [ ] **Step 2: RED/GREEN for L09 invariant gate**

Introduce at least one behavior mutation fixture that the old path-existence gate would pass and the new gate rejects. Make the gate execute contract assertions.

- [ ] **Step 3: Make nightly performance semantics explicit**

If a stable measured baseline is available, version it and enforce a documented tolerance. Otherwise rename/status the job as observe-only and prohibit merge-blocking claims.

- [ ] **Step 4: Close the ledger**

Every row must be `CONFIRMED-FIXED`, `PARTIAL-FIXED`, or `OVERTURNED`, with commit and test evidence. Run the identifier coverage command and reject any `UNADJUDICATED` row.

- [ ] **Step 5: Verify and commit**

Run documentation/gate scripts, `git diff --check`, and commit Wave 7F.

### Task 8: Full Verification, Release, Install, and Runtime Smoke

**Files:**
- Modify only closeout/changelog files required by repository convention after verification
- Do not change production code during this task; failures return to the owning task

**Interfaces:**
- Consumes: all six green waves.
- Produces: installed, signed, running Engram plus durable verification evidence.

- [ ] **Step 1: Confirm no app/service is running before build**

Run `pgrep -fl 'Engram|EngramService' || true` and confirm no Engram app/service process. Do not treat externally owned `EngramMCP` helpers as the app service.

- [ ] **Step 2: Run full Swift test matrix**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skip-testing:EngramUITests
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: all commands exit 0.

- [ ] **Step 3: Build and verify release**

Use a monotonically increasing local build number:

```bash
cd macos
ENGRAM_BUILD_NUMBER="$(date +%Y%m%d%H%M)" ./scripts/build-release.sh --local-only
```

Run the repository release verifier against the produced `.app`. Expected: signature valid and no `node`, `node_modules`, `dist`, `daemon.js`, `index.js`, or `web.js` in the bundle.

- [ ] **Step 4: Install and launch**

```bash
cd macos
./scripts/deploy-local.sh "$PWD/build/EngramExport/Engram-local-only.app"
open -a Engram
```

- [ ] **Step 5: Runtime smoke**

Verify installed plist version/build, `codesign --verify --deep --strict`, Engram and EngramService processes, `~/.engram/run/engram-service.sock`, service health, and packaged `EngramMCP` `initialize` plus `tools/list`.

- [ ] **Step 6: Scheduling smoke**

Read service telemetry/status and confirm the next scan is not a fixed five-minute deadline. Do not wait an hour; verify exposed policy/state and absence of an immediate repeated scan.

- [ ] **Step 7: Final closeout commit**

Record exact commands, exit status, installed version/build, and residual risks. Run `git status --short`, `git diff --check`, then commit the closeout without unrelated files.
