# Wave 7 Engineering-Zero Closeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current 24-complete/19-partial Wave 7 state with evidence-backed engineering zero, reconcile the active follow-up surfaces, and deploy one final verified Engram build.

**Architecture:** Four implementation waves close the remaining semantic/security, MCP contract, UX/operations, and service/gate defects. Two final gates reconcile backlog truth and verify CI, release, install, and runtime behavior. Product-direction items remain in `docs/roadmap.md` with explicit decisions; they are not relabeled as engineering defects.

**Tech Stack:** Swift 6, Swift Concurrency, GRDB/SQLite/FTS5, Foundation, Security/Keychain Services, XCTest, XcodeGen, native Unix-socket IPC, shell/CI contract gates.

## Global Constraints

- Start from clean `origin/main` at or after `45bb5284`.
- Read `AGENTS.md`, `docs/reviews/2026-07-10-multi-expert-audit.md`, and `docs/reviews/2026-07-10-wave7-remediation-closeout.md` before editing.
- Swift product behavior is authoritative. Do not recreate Node product entrypoints.
- App and MCP writes continue through `EngramServiceClient` and `ServiceWriterGate`.
- Never edit `macos/Engram.xcodeproj`; use `macos/project.yml` and `xcodegen generate`.
- Follow red-green-refactor for every behavior change. Record the failing test command and expected failure before production edits.
- Use one branch and one review gate per wave. Do not allow Grok and Codex to edit the same worktree concurrently.
- Grok is the primary implementer. Codex performs source adjudication, diff review, regression-gap review, and merge/deploy acceptance.
- A ledger row may close only as `CONFIRMED-FIXED`, `OVERTURNED`, or `ACCEPTED-DESIGN` with explicit owner rationale. `PARTIAL-FIXED` is not a terminal state.
- Do not claim repo-wide zero while `docs/TODO.md`, `docs/followups.md`, the Wave 7 ledger, or CI disagree.
- Build, install, and launch only after all four implementation waves and backlog reconciliation are complete.

## Definition of Engineering Zero

All of the following must be true:

1. The Wave 7 ledger contains 43 terminal verdicts and zero `PARTIAL-FIXED` or `UNADJUDICATED` rows.
2. Every confirmed defect has a named regression test or an executable contract gate.
3. `docs/TODO.md` contains no false closed claims.
4. `docs/followups.md` contains no implementation-ready engineering work; conditional or product-decision items are moved to `docs/roadmap.md` with rationale.
5. The 12 roadmap decision rows remain visible until the owner explicitly accepts, rejects, or schedules them. Roadmap decisions do not block engineering zero.
6. Tests, CodeQL, release verification, installed runtime, socket health, MCP smoke, and adaptive scheduling smoke all pass on the same commit.

---

### Task 1: Open the Zero-Closeout Ledger and Resolve Two Product Decisions

**Files:**
- Create: `docs/reviews/2026-07-10-wave7-engineering-zero-closeout.md`
- Modify: `docs/reviews/2026-07-10-wave7-remediation-closeout.md`

**Interfaces:**
- Consumes: 19 `PARTIAL-FIXED` rows plus active follow-ups.
- Produces: one deduplicated ledger with owner decisions for M09 and M16.

- [ ] **Step 1: Create the residual ledger**

Create rows for exactly:

```text
H07 H12
M02 M06 M07 M08 M09 M11 M12 M13 M14 M15 M16 M19
L01 L02 L06 L07 L09
```

Columns: `ID`, `Current source proof`, `Target contract`, `Test/gate`, `Wave`, `Terminal verdict`, `Commit`.

- [ ] **Step 2: Lock M09 semantic-search decision**

Adopt this target contract: semantic search evaluates the full eligible corpus in cancellable GRDB batches with constant-memory top-K accumulation. Remove recency as an implicit eligibility cap. Latency is telemetry, not a correctness filter.

- [ ] **Step 3: Lock M16 transcript-redaction decision**

Adopt this target contract: MCP transcript reads use the same default redaction policy as export. Raw content requires an explicit request field and remains local-only; no implicit unredacted default.

- [ ] **Step 4: Verify exact coverage and commit**

```bash
for id in H07 H12 M02 M06 M07 M08 M09 M11 M12 M13 M14 M15 M16 M19 L01 L02 L06 L07 L09; do
  rg -Fq "| $id |" docs/reviews/2026-07-10-wave7-engineering-zero-closeout.md || echo "missing $id"
done
```

Expected: no output. Commit only the ledger files.

### Task 2: Wave 8A - Semantic Integrity and Secret Hygiene

**Scope:** `H07`, `M06`, `M07`, `M08`, `M09`, `M13`, `M14`, `M15`, `M16`.

**Files:**
- Modify: `macos/EngramService/Core/EngramServiceReadProvider.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/Shared/EngramCore/AI/SessionVectorSearchAvailability.swift`
- Modify: `macos/Shared/EngramCore/AI/SessionSemanticSearchPolicy.swift`
- Modify: `macos/Shared/EngramCore/AI/EmbeddingSettings.swift`
- Create: `macos/Shared/EngramCore/AI/KeychainSecretStore.swift`
- Modify: `macos/Shared/EngramCore/AI/EmbeddingCircuitBreaker.swift`
- Modify: `macos/Engram/Views/Settings/SettingsIO.swift`
- Modify: `macos/Engram/Core/DiagnosticBundleComposer.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Modify: `macos/EngramMCP/Core/MCPTranscriptTools.swift`
- Modify: `macos/EngramMCP/Core/MCPTranscriptReader.swift`
- Modify: `macos/EngramService/Core/TranscriptExportService.swift`
- Test: `macos/EngramServiceCoreTests/EmbeddingGuardrailsTests.swift`
- Test: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`
- Test: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Test: `macos/EngramTests/DiagnosticBundleComposerTests.swift`
- Test: `macos/EngramCoreTests/AI/EmbeddingCircuitBreakerTests.swift`
- Test: `macos/EngramCoreTests/AI/SemanticMemoryUnitTests.swift`

**Interfaces:**
- Produces: exact query/stored model compatibility, shared breaker semantics, full-corpus semantic top-K, Keychain-backed embedding credentials, complete redaction, mode-0600 settings writes.

- [ ] **Step 1: RED for H07 model equality**

Add service and MCP tests with stored model `model-a`, configured query model `model-b`, identical dimension. Expected current failure: semantic results are returned or fallback hides the mismatch. Target: structured `embeddingModelMismatch`, with no cosine ranking.

- [ ] **Step 2: GREEN for H07**

Probe `embedding_meta` before query embedding. Require configured model and dimension to equal stored model and dimension. Do not generate a query vector when compatibility fails.

- [ ] **Step 3: RED/GREEN for M06-M08**

Add distinct tests for provider unavailable, corpus missing, model mismatch, breaker open, and transport recovery. Use `EmbeddingGuardrails.sharedBreaker` in MCP and service; remove private bypass paths. `get_memory` warnings must describe the actual failure reason.

- [ ] **Step 4: RED/GREEN for M09 full-corpus correctness**

Seed an older semantically exact candidate outside the former recency cap and a newer weak candidate inside it. Assert the older exact candidate wins. Stream eligible vector rows in bounded batches, maintain constant-memory top-K, and check cancellation between batches.

- [ ] **Step 5: RED/GREEN for M13 Keychain migration**

Extract the Security-framework operations from app-only `KeychainHelper` into shared `KeychainSecretStore`; keep `KeychainHelper` as the UI facade. Test plaintext legacy key, `@keychain`, interrupted migration, missing Keychain entry, and idempotent reload. Remove plaintext only after successful Keychain persistence.

- [ ] **Step 6: RED/GREEN for M14-M15**

Add `embeddingApiKey` and normalized aliases to diagnostic redaction. Write settings through an atomic temporary file with POSIX mode `0600` set before rename; assert final permissions after both create and update.

- [ ] **Step 7: RED/GREEN for M16**

Extract one shared transcript-redaction policy used by MCP read and export. Default to redacted. Test explicit local raw opt-in separately and ensure structured metadata states whether redaction was applied.

- [ ] **Step 8: Verify and hand to Codex review**

Run `EngramCoreTests`, `EngramServiceCore`, `EngramMCPTests`, and focused `EngramTests`. Codex must review model mismatch fail-closed behavior, Keychain migration interruption safety, permission timing, and redaction bypasses before merge.

### Task 3: Wave 8B - MCP and Structured Contract Truth

**Scope:** `M11`, `M12`, `L06`, `L07`.

**Files:**
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry+ProjectResults.swift`
- Modify: `macos/EngramMCP/Core/MCPTranscriptTools.swift`
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramService/Core/TranscriptExportService.swift`
- Modify: `docs/mcp-tools.md`
- Test: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Test: `macos/EngramServiceCoreTests/TranscriptExportServiceTests.swift`

**Interfaces:**
- Produces: role-default truth, preserved `transcriptTooLarge`, accurate project root count, memory type in structured payload.

- [ ] **Step 1: RED/GREEN for M11**

Lock the default transcript role set in executable schema tests and document the same set. Explicit `roles` continues to override the default.

- [ ] **Step 2: RED/GREEN for M12**

Map transcript-size failures to a stable service error kind and preserve `transcriptTooLarge` through service IPC and MCP. Do not collapse it to `invalidRequest`.

- [ ] **Step 3: RED/GREEN for L06-L07**

Derive project root count from the scanner's single source of truth rather than prose. Include requested/returned insight type in `get_memory` structured payload and golden tests.

- [ ] **Step 4: Verify and hand to Codex review**

Run MCP goldens and service export tests. Codex compares `tools/list`, runtime responses, and `docs/mcp-tools.md` field by field before merge.

### Task 4: Wave 8C - Export, Favorites, and Long-Operation UX

**Scope:** `H12`, `M19`, plus actionable perceived-duration follow-ups.

**Files:**
- Modify: `macos/Engram/Views/CommandPaletteView.swift`
- Modify: `macos/Engram/Views/SessionActionHandlers.swift`
- Modify: `macos/Engram/Views/Pages/SessionsPageView.swift`
- Modify: `macos/Engram/Components/ExpandableSessionCard.swift`
- Modify: `macos/Engram/Models/Session.swift`
- Modify: `macos/Engram/Views/Projects/BatchMoveSheet.swift`
- Modify: `macos/Engram/Views/Projects/RenameSheet.swift`
- Modify: `macos/Engram/Views/Projects/ArchiveSheet.swift`
- Modify: `macos/EngramService/Core/ProjectMoveBatchCancelRegistry.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler+ProjectMigration.swift`
- Test: `macos/EngramTests/CommandPaletteTests.swift`
- Test: `macos/EngramTests/SessionModelTests.swift`
- Test: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`
- Test: `macos/EngramCoreTests/ProjectMove/OrchestratorTests.swift`

**Interfaces:**
- Produces: explicit export state machine, symmetric favorite toggle, cancellable/reconnectable project operations.

- [ ] **Step 1: RED/GREEN for H12**

Model export as `idle`, `inFlight`, `succeeded(path)`, `failed(message)`. Keep palette results and selection visible while exporting. Disable only the duplicate export action, show progress, and expose Finder reveal after success.

- [ ] **Step 2: RED/GREEN for M19**

Expose `isFavorite` on the app session model/read DTO. Browse and Starred use one toggle closure with `favorite: !session.isFavorite`. Labels and accessibility values must reflect Add versus Remove.

- [ ] **Step 3: Close the long-migration follow-up**

Give rename/archive/undo the same operation ID and cooperative cancellation contract already used by batch. Cancellation before the commit boundary returns remaining work; after the commit boundary the operation continues in the service and the app reconnects by operation ID instead of pretending it stopped.

- [ ] **Step 4: Verify and hand to Codex review**

Run focused app, IPC, and ProjectMove suites. Codex reviews state restoration, double-submit prevention, cancellation boundaries, and partial-result wording before merge.

### Task 5: Wave 8D - Telemetry, Logging, and Executable Invariants

**Scope:** `M02`, `L01`, `L02`, `L09`, plus local-ignore and disk-audit follow-up reconciliation.

**Files:**
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift`
- Modify: `macos/EngramService/Core/ServiceTelemetryCollector.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Modify: `scripts/check-invariants-ledger.sh`
- Create: `scripts/invariant-gates.json`
- Modify: `tests/scripts/invariants-ledger.test.ts`
- Modify: `.gitignore`
- Modify local `.git/info/exclude` only after classifying entries; do not commit it
- Test: `macos/EngramServiceCoreTests/ServiceTelemetryTests.swift`
- Test: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`

**Interfaces:**
- Produces: success-honest telemetry, JSON-safe stdout, strict service-log payload errors, allowlisted executable invariant gates.

- [ ] **Step 1: RED/GREEN for M02**

Make a required initial-scan phase fail and assert no success scan sample is recorded. Record separate failed-phase telemetry with phase name and duration.

- [ ] **Step 2: RED/GREEN for L01-L02**

Encode stdout events with `JSONEncoder`; never interpolate error text into JSON. Reject malformed `serviceLogs` payload with structured `invalidRequest` rather than silently applying defaults.

- [ ] **Step 3: RED/GREEN for L09**

Use `scripts/invariant-gates.json` as an allowlisted registry from invariant ID to repository command. The shell runner validates referenced paths and executes every registered gate. Tests must prove a present-but-behaviorally-invalid fixture fails.

- [ ] **Step 4: Resolve the disk-audit advisory**

Current source already updates session/insight `last_accessed_at` and `access_count`. Add an end-to-end read-path test for the disk-audit consumer, then close or narrow the follow-up based on proven coverage; do not add duplicate counters.

- [ ] **Step 5: Normalize ignore rules**

Classify `.git/info/exclude` entries. Move only universally generated artifacts into `.gitignore`; keep machine-specific/private paths local. Verify `git status --ignored --short` before and after.

- [ ] **Step 6: Verify and hand to Codex review**

Run service suites, invariant script tests, lint, and `git diff --check`. Codex reviews that the invariant registry cannot execute arbitrary markdown content.

### Task 6: Reconcile TODO, Follow-ups, Roadmap, and Durable Closeout

**Files:**
- Modify: `docs/TODO.md`
- Modify: `docs/followups.md`
- Modify: `docs/roadmap.md`
- Modify: `docs/reviews/2026-07-10-wave7-remediation-closeout.md`
- Modify: `docs/reviews/2026-07-10-wave7-engineering-zero-closeout.md`
- Modify: `CHANGELOG.md`
- Modify: `.memory`

**Interfaces:**
- Produces: one consistent backlog truth and a terminal 43-row Wave 7 ledger.

- [ ] **Step 1: Remove stale claims**

Correct the `TODO.md` favorite-toggle claim only after M19 is green. Do not preserve contradictory “shipped” wording.

- [ ] **Step 2: Deduplicate follow-ups**

Close export progress through H12, long migration through Task 4, disk audit and ignore rules through Task 5. Move Sources navigation and `ai_audit_log` precondition to roadmap decision rows. Mark the perf-integration section closed because it states zero active items.

- [ ] **Step 3: Close all 43 audit rows**

Replace every Wave 7 `PARTIAL-FIXED` row with `CONFIRMED-FIXED`, `OVERTURNED`, or `ACCEPTED-DESIGN`, including commit and test evidence. Recompute counts mechanically.

- [ ] **Step 4: Verify backlog truth**

```bash
! rg -n 'PARTIAL-FIXED|UNADJUDICATED' docs/reviews/2026-07-10-wave7-remediation-closeout.md
! rg -n '^## Open' docs/followups.md
rg -n '^## Decision pending' docs/roadmap.md
git diff --check
```

Expected: first two commands succeed with no matches; roadmap decisions remain visible.

- [ ] **Step 5: Commit durable closeout**

Record exact test commands, CI URLs, remaining product decisions, and the distinction between engineering zero and roadmap zero.

### Task 7: Final CI, Release, Install, and Runtime Gate

**Files:**
- Modify only durable closeout evidence after verification
- Do not patch production code in this task; return failures to the owning wave

- [ ] **Step 1: Run local full matrix**

```bash
cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skip-testing:EngramUITests
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Also run `npm run lint`, `npm run knip`, `npm run typecheck:test`, `npm run test:coverage`, fixture checks, and executable invariant gates.

- [ ] **Step 2: Require remote gates on the same SHA**

Tests and CodeQL must both complete successfully. A still-running CodeQL job is not a green closeout.

- [ ] **Step 3: Build and verify one final release**

```bash
cd macos
export ENGRAM_BUILD_NUMBER="$(date +%Y%m%d%H%M)"
./scripts/build-release.sh --local-only
./scripts/release-verify.sh "$PWD/build/EngramExport/Engram.app" --expected-build "$ENGRAM_BUILD_NUMBER"
```

- [ ] **Step 4: Install, launch, and smoke**

Deploy with `macos/scripts/deploy-local.sh`, launch Engram, verify version/build, `codesign --verify --deep --strict`, Engram and EngramService processes, socket permissions, service health, MCP `initialize` plus `tools/list`, semantic model-mismatch rejection, default transcript redaction, export progress, favorite removal, and adaptive schedule backend/interval.

- [ ] **Step 5: Final acceptance**

Codex performs the final repo/backlog/runtime reconciliation. The terminal report must say separately:

```text
Wave 7 audit ledger: 43 terminal / 0 partial
Engineering TODO: 0
Engineering follow-ups: 0
Roadmap decisions: 12 visible, not misreported as implemented
Tests: green on final SHA
CodeQL: green on final SHA
Installed build: verified
Runtime smoke: verified
```

## Recommended Execution Order and Ownership

| Order | Branch | Primary | Independent gate | Merge prerequisite |
|------:|--------|---------|------------------|--------------------|
| 1 | `wave8a-semantic-security` | Grok | Codex | Focused suites + security review |
| 2 | `wave8b-mcp-contracts` | Grok | Codex | MCP goldens + docs parity |
| 3 | `wave8c-ux-operations` | Grok | Codex | App/IPC/ProjectMove suites |
| 4 | `wave8d-telemetry-gates` | Grok | Codex | Service + invariant gates |
| 5 | `wave8-closeout` | Codex | Grok read-only challenge | Backlog/ledger consistency |
| 6 | final release | Codex | CI + live runtime | Same-SHA green evidence |

Do not stack all changes into one branch. Merge each wave into `main` before creating the next branch so later work starts from reviewed state.

## Parallel Execution DAG

Use two implementation agents with cross-review. Each round uses isolated worktrees and disjoint production/test ownership. Do not start a later round until both branches in the current round are reviewed and merged.

### Round 0: Contract freeze (Codex, serial, 2-4 hours)

Before parallel edits, lock these names and payloads in the residual ledger:

- semantic incompatibility code: `embeddingModelMismatch`;
- semantic availability reasons: provider unavailable, corpus missing, model mismatch, breaker open;
- transcript request: explicit raw opt-in, redacted by default;
- transcript response: whether redaction was applied;
- export UI states: `idle`, `inFlight`, `succeeded`, `failed`;
- invariant registry schema: invariant ID to allowlisted gate ID, never markdown to shell.

This round prevents both agents from inventing incompatible DTOs while working in parallel.

### Round 1: Semantic versus secret storage (parallel)

| Lane | Primary | Scope | Exclusive production ownership | Exclusive test ownership |
|------|---------|-------|--------------------------------|--------------------------|
| 1A | Grok | H07, M06-M09 | `EngramServiceReadProvider.swift`, `MCPDatabase.swift`, `SessionVectorSearchAvailability.swift`, `SessionSemanticSearchPolicy.swift`, `EmbeddingCircuitBreaker.swift` | semantic/model/breaker tests |
| 1B | Codex | M13-M15 | `EmbeddingSettings.swift`, new `KeychainSecretStore.swift`, `SettingsIO.swift`, `DiagnosticBundleComposer.swift`, settings-write helper extracted from `EngramServiceCommandHandler.swift` | Keychain, diagnostic, permission tests |

Interface rule: lane 1B preserves the public `EmbeddingSettings.load(...) -> EmbeddingConfig?` signature. Lane 1A consumes it but does not edit `EmbeddingSettings.swift`.

Review/merge order:

1. Grok reviews 1B for migration-loss and Keychain fallback errors.
2. Codex reviews 1A for fail-open model mixing and hidden recency caps.
3. Merge 1B first, rebase 1A, rerun focused semantic tests, then merge 1A.

### Round 2: MCP/transcript contracts versus app UX (parallel)

| Lane | Primary | Scope | Exclusive production ownership | Exclusive test ownership |
|------|---------|-------|--------------------------------|--------------------------|
| 2A | Grok | M11, M12, M16, L06, L07 | `MCPToolRegistry.swift`, `MCPToolRegistry+ProjectResults.swift`, `MCPTranscriptTools.swift`, `MCPTranscriptReader.swift`, `TranscriptExportService.swift`, `docs/mcp-tools.md` | MCP goldens and export contract tests |
| 2B | Codex | H12, M19 | `CommandPaletteView.swift`, `SessionActionHandlers.swift`, `SessionsPageView.swift`, `ExpandableSessionCard.swift`, `Session.swift` | command-palette, session-model, favorite tests |

Review/merge order:

1. Codex reviews 2A for schema compatibility and redaction bypasses.
2. Grok reviews 2B for state loss, duplicate export, and incorrect favorite labels.
3. Merge 2A, then 2B. These lanes have no intended production-file overlap.

### Round 3: Long operations versus service/gates (parallel)

| Lane | Primary | Scope | Exclusive production ownership | Exclusive test ownership |
|------|---------|-------|--------------------------------|--------------------------|
| 3A | Grok | long migration follow-up | project sheets, `ProjectMoveBatchCancelRegistry.swift`, `EngramServiceCommandHandler+ProjectMigration.swift`, ProjectMove domain files | ProjectMove and migration IPC tests |
| 3B | Codex | M02, L01, L02, L09, disk-audit evidence | `EngramServiceRunner.swift`, `ServiceTelemetryCollector.swift`, base `EngramServiceCommandHandler.swift`, invariant scripts/registry | telemetry, service-log, invariant tests |

Conflict rule: lane 3A edits only the `+ProjectMigration` extension, never the base command-handler file owned by 3B.

Review/merge order:

1. Codex reviews 3A cancellation/commit boundaries.
2. Grok reviews 3B gate safety and telemetry truth.
3. Merge either order after both reviews because ownership is disjoint.

### Round 4: Backlog and release closeout (serial)

Codex reconciles ledger/TODO/follow-ups/roadmap and runs final local verification. Grok performs one read-only adversarial pass against the closeout claims. Only then run remote CI, release build, install, and runtime smoke.

## Acceleration Rules

1. **Parallelize investigation, tests, and coding; serialize heavy builds.** On the shared Mac, allow only one local `xcodebuild`/archive at a time. Concurrent Swift builds compete for DerivedData and disk bandwidth, defeating the scan-I/O work just shipped.
2. **Use focused RED/GREEN commands per lane.** Agents run `-only-testing` or direct `xcrun xctest` filters during implementation. Run the full Swift matrix once per merged round and once at final acceptance, not from every worktree.
3. **Keep separate DerivedData per worktree when compilation is unavoidable.** Set `LANE=1a` (or the active lane ID) and use `-derivedDataPath "/tmp/engram-dd-$LANE"` while sharing the SPM download cache.
4. **Review as soon as a branch is ready.** The other agent stops implementing its own branch only at a clean test boundary, reviews the peer diff, then resumes. Do not wait for both branches to finish before starting review.
5. **Freeze cross-lane DTOs in Round 0.** Any contract change after freeze requires both branch owners to acknowledge it before code changes continue.
6. **No shared hotspot edits.** `MCPDatabase.swift`, `MCPTranscriptTools.swift`, `EngramServiceCommandHandler.swift`, and `SessionActionHandlers.swift` each have exactly one owner per round.
7. **Merge small terminal commits.** Each finding or tightly coupled finding set ends with its regression test and ledger update. This keeps rebase conflicts local and makes rollback possible.
8. **Use CI selectively.** Open draft PRs early for remote cache warming, but require full Tests + CodeQL only on the round integration SHA and final SHA.

With two implementation agents, this changes the critical path from four large sequential waves to three parallel rounds plus closeout. Expected elapsed time is approximately 4-6 working days instead of 8-12, with M09 full-corpus performance and reconnectable project migration as the two schedule-risk items.
