# Engram Follow-ups

Follow-ups are verification gaps, low-priority refactors, or items that need
real data, UI exercise, or product confirmation before becoming TODOs.

## Blind-audit implementation inventory (2026-07-19)

The closeout workflow completed 15/15 discovery scopes, explicitly named all
17 Swift sources, and adjudicated 23 canonical candidates: 22 confirmed and 1
refuted. KIMI-001 and WRITER-LOCATOR-001 retain document-scoped legacy
references; one duplicate MCP submission maps to the existing MCP-001 row.
MCP-001 is a confirmed MCP 2025-11-25 object-root violation.

All `_repro` names from this closeout are proposed TDD entry points only; none
was created or executed during adjudication. A source with no retained finding
was not proven defect-free. Twenty-one findings can enter TDD; CURSOR-CWD-001
remains design/evidence pending until a deterministic workspace-ownership
contract is established. This readiness scope does not close the
repository-wide audit.

| Batch | Status | Confirmed IDs |
|-------|--------|---------------|
| **A1 — Codex parser and indexing integrity** | stacked PR #205 | ADAPTER-CODEX-001, ADAPTER-CODEX-002, IDX-PARTIAL-001 |
| **A2 — Kimi composite session correctness** | stacked PR #206 | KIMI-001, KIMI-002, KIMI-003 |
| **A3 — Qwen product integration** | stacked PR #207 | SRC-QWEN-001, SRC-QWEN-002 |
| **A4 — Adapter ingestion guardrails** | stacked PR #208 | ADAPTER-CC-001, SRC-COMMANDCODE-001, VSCODE-INCR-001 |
| **B1 — Composite-input discovery and invalidation** | stacked PR #209 | ADAPTER-GEMINI-001, COPILOT-AUX-001, COPILOT-DISCOVERY-001 |
| **B2 — OpenCode archive and byte accounting** | stacked PR #210 | ADAPTER-OPENCODE-001, ADAPTER-OPENCODE-002 |
| **B3 — Cursor content and ownership** | partial: content in stacked PR #211; cwd design pending | CURSOR-CONTENT-001, CURSOR-CWD-001 |
| **C1a — Archive V2 source-toggle convergence** | stacked PR #212 | SRC-001 |
| **C1b — Writer locator relocation** | stacked PR #213 | WRITER-LOCATOR-001 |
| **C1c — Startup parent-backfill pagination** | stacked PR #214 | PARENT-BACKFILL-STARVE-001 |
| **D1 — MCP result contract** | stacked PR #215 | MCP-001 |

Legacy references: KIMI-001 corresponds to `H08` only within
`2026-06-10-multi-expert-audit.md`, and WRITER-LOCATOR-001 corresponds to `L3`
only within `2026-07-17-engram-full-audit.md`. The duplicate MCP submission maps
to `MCP-001`. `AG-BYTES-001` is refuted by a 1–2 vote because Antigravity's
retained `pbSizeBytes` is the documented historical logical size of the complete
`.pb` session.

Each implementation-ready finding requires a failing `_repro`, recorded RED,
minimum production fix, focused/full GREEN, and a fresh Codex `PASS` before
commit/push/stacked PR. CURSOR-CWD-001 must first establish a deterministic
workspace-ownership contract and must never infer authoritative project state
from an unrelated file selection. No automatic merge is authorized.

## Post-review residuals (2026-07-18 full-project review)

Promoted from `docs/reviews/2026-07-18-full-project-review.md` so open work is
not only a bare disposition status table. R2–R5 and R10 closed in #196 / R4+;
R1 remains open. R4 terminalization is limited to explicit input-local provider
rejection; HTTP/transport, malformed response, and dimension/config failures
remain recoverable and do not consume the permanent budget. Remaining items:

| ID | Status | Home / next step |
|----|--------|------------------|
| **R1** / ARCH-001 | open (structural investment; partially mitigated) | Triple Read SQL stacks remain as accepted architecture debt until a shared CoreRead predicate + cross-surface parity suite lands; READ-001/002/003 + visibility filter tests mitigate drift without closing ARCH-001 |
| **READ-001/002/003** | closed (post-audit follow-up) | MCP multi-term session-scoped AND, activity-time `since`, and exact project-or-alias filtering are covered by executable `_repro` tests; this does not close ARCH-001 |
| **R6** | accepted residual (redesign deferred) | Producer intentionally holds the writer gate for the full FS+patch lifetime (finding 8 integrity). M1 prevents false timeouts; availability redesign (release gate across network/FS phases like remote offload) is product-scale work, not a defect fix |
| **R7** | closed (#220) | Offload HTTP matches Archive V2 transport depth (ephemeral session, redirect reject, size caps, post-DNS private check for named private hosts); requireTLS product default fail-closed docs fixed |
| **SEC-001** | closed (pending PR review) | Auto-offload treats remote HEAD as a soft optimization: absent objects require a successful PUT, while existing objects require GET + bundle decode + exact expected content-hash match before `commitOffloaded` may collapse local FTS; both shipped call paths have `_repro` coverage |
| **R8** | closed (#218) | Durable `content_fingerprint` enables parity-stable `mergeTailSnapshot` for Claude/Codex user-led appends; covered by `testCodexTailMergeMatchesFullReindex_repro` + updated Claude tail parity |
| **R9** / M21 residual | closed (flush; #219); MainActor I/O residual | AI settings flush pending debounce on disappear; MainActor flock/Keychain I/O after debounce remains accepted residual |
| **R11 ledger** | closed | Disposition evidence columns + this followups section |
| **L-a…L-j** | residual | Low/Info rows in full-project review; not engineering-zero blockers |
| **SEC-M5 / I1 / I2** | design residual | See `docs/reviews/2026-07-17-accepted-residuals.md` |

Also see disposition inventory: `docs/reviews/2026-07-17-finding-disposition.md`.

## Open conditional follow-ups — exact-source archive v2 (2026-07-15)

These boundaries are deliberately outside the current operator deployment and
are not implementation-ready blockers for its operational closeout:

- **Restart-stable bounded locator discovery.** Current Claude Code and Codex
  discovery is cooperative-cancellable but O(N) and materializes/sorts the
  current locator set before `batchSize` applies. A future design needs a
  durable locator inventory/work queue, normally bootstrapped by one explicit
  full crawl and maintained with FSEvents. Do not claim discovery itself is
  bounded until that implementation and restart tests exist.
- **Canonical exporters for additional adapters.** Keep virtual, composite,
  adjacent-shard, path-sensitive, and database-backed locators unsupported
  until each adapter declares a complete canonical source set and passes a
  delete-original/replay-equivalence fixture. Regular-file shape alone is not
  sufficient.
- **Remote archive erasure or server-side GC.** The current v2 remote API is
  immutable and every DELETE remains `405`. Any future erasure/GC needs a
  separate design, explicit authorization, independent backup/key recovery,
  fresh two-site restore evidence, and a deletion safety review.

Reconciled from the first-release boundary: opt-in local source reclamation and
local CAS eviction are now implemented and operator-enabled. They are gated by
dual receipts, current per-replica recovery leases, generation revalidation,
and write-ahead quarantine, so they are no longer an open follow-up. They do not
authorize remote deletion or GC.

## Historical engineering-zero status (2026-07-11, Wave 8 Round 4)

**Open implementation-ready engineering follow-ups: 0.**

Wave 8 merged on main through `c983a759` closed the actionable perceived-duration
items (export progress, long project migrations), disk-audit consumer evidence,
and ignore-rule classification. Product-decision items already live in
`docs/roadmap.md` Decision pending (exactly 12 rows). Conditional UX that is not
currently exposed (FTS full-rebuild progress) is recorded as closed/deferred
below, not as open engineering work.

This remains the follow-up count, not the total delivery count: on 2026-07-15
the owner selected one implementation-ready public macOS release baseline in
`docs/TODO.md`. It is a scheduled delivery rather than a follow-up and does not
reopen any Wave 7 defect.

Evidence ledger:
`docs/reviews/2026-07-10-wave7-engineering-zero-closeout.md`.

## Closed — Wave 8 perceived-duration + ops (2026-07-10/11)

CLOSEOUT (2026-07-11): actionable items from the 2026-07-08 perceived-duration
audit and related ops follow-ups.

- **Session export in-flight feedback.** Closed across every exposed app entry:
  Wave 8C / H12 (`262d59a2` / `cfed29b5`) added the command-palette state
  machine; the final Task 7 remediation extended the same
  idle→inFlight→succeeded|failed contract to Sessions and Timeline rows, with
  visible progress, duplicate-export disable, and Finder reveal. Evidence:
  `CommandPaletteTests` and `SessionActionsTests` export-state/wiring suites.
- **Long project migrations cancel or continue.** Closed via Wave 8D
  (`c983a759` / `eeab26a8`): stable operation ID, cancel-before-commit,
  post-commit reconnect/continuation (not false cancellation), idempotent
  re-submit. Evidence: ProjectMove Core/Service/App long-op suites.
- **Disk-audit advisory access counters.** Closed via Wave 8E
  (`c87fab56` / `f1486c2f`): product read paths already update
  `last_accessed_at` / `access_count`; E2E consumer coverage in
  `EngramMCPExecutableTests.testGetMemoryRanksByServiceRecordedAccessCount_diskAuditConsumer`.
- **Normalize local ignore rules.** Closed: universal generated artifacts already
  live in shared `.gitignore` (`node_modules/`, `dist/`, `.husky/_/`). Remaining
  `.git/info/exclude` entries are host-local by design and stay uncommitted.
- **FTS full-rebuild progress UI.** Closed as not implementation-ready. Command
  palette still excludes `reindex`/`triggerSync`; aggregate index-job coverage
  remains the only surface. Reopen only if product exposes a user-visible full
  rebuild action.

## Closed — plan-completion product decisions moved to roadmap (2026-07-11)

CLOSEOUT (2026-07-11): these were never wave-6 implementation tasks; they remain
product decisions in `docs/roadmap.md` Decision pending (do not re-open here).

- **Sources-sync-3 nav consolidation** — roadmap row (alignment design deferred).
- **`ai_audit_log` desensitization design** — roadmap row (design-before-writer).

## Closed — provider-audit branch (2026-07-09)


CLOSEOUT (2026-07-09): **Resolve preserved `codex-provider-audit-remediation`
branch.**

- Reconciliation doc landed (PR #144) and is committed as
  `docs/reviews/provider-audit-branch-reconciliation-2026-07.md`.
- Branch deleted local + origin on 2026-07-09 after third-model (Grok)
  adjudication following Claude + Codex review.
- Tip preserved as annotated archive tag
  `archive/codex-provider-audit-remediation` (`285453d7`, pushed to origin).
- Deliberately-unported valuable features remain inventoried in the
  reconciliation doc and the roadmap Decision pending table; do not resurrect
  the branch name for new work.

Closed during the 2026-07-06 sync: documentation archive cleanup was already
committed; immediate Time Machine snapshot reclamation is no longer needed
(`df -h .` shows 241Gi available on 2026-07-06, so macOS can manage snapshots
normally).

## Completed — feature-cut execution plan, adjudicated Top 10 (2026-07-05)

CLOSEOUT (2026-07-06): items 0-10 completed in PR #103-#112, then LOW residual
cleanup completed in PR #113 (`24cc4562`). PR #113 and main `24cc4562` both had
Tests + CodeQL green. This section is retained as the historical execution
protocol and evidence trail; it is no longer active backlog.

Historical blocker (2026-07-05, RESOLVED 2026-07-06 by Claude): stopped at ITEM 0 /
PR #103 after the protocol's "CI stays red after 2 fix attempts" gate fired.
PR head `e903a06e` passed everything except `ui-test-full`, where only
`settings_dark` failed (`SSIM=0.8982` vs 0.91 threshold; `pHash=6` and
`diff=4.7001%` were within limits). Root cause: the checked-in baseline
`macos/EngramUITests/baselines/settings_dark.png` was stale — a
Chinese-locale capture last touched in `322f5095`, predating the forced
`-AppleLanguages (en)` in `TestLaunchConfig`, and still showing the Web UI /
MCP HTTP endpoint rows this PR deletes. It had only ever passed marginally
(SSIM 0.9157 on the last green main run); the PR's intentional settings
change pushed it below threshold. Fixed by refreshing the baseline from CI
run `28745689659`'s actual capture. Not a product regression. Related: main
HEAD `30e3a4af` is independently red on `swift-unit`
(`testPopoverStatusLabelsServiceInsteadOfMcpWhenUsingServiceStatus` expects
the popover Service chip that `30e3a4af` removed); this PR already carries
the aligned scan test (`d77e1ffa`), so merging ITEM 0 also restores main to
green.

Original goal for Codex: execute the cuts below. Provenance: a 38-agent opus+sonnet
workflow (4-area inventory → 4-lens propose → dedup → adversarial verify per
candidate: refuter + blast-radius → opus final ranking), merged with Codex's
own 2026-07-05 "hide/downgrade defaults" round. Every DELETE item survived
double adversarial verification; items 9-10 are product-default demotions the
owner explicitly approved in-session (2026-07-05).

Historical execution protocol (updated 2026-07-05, owner-approved AUTONOMOUS mode —
supersedes the earlier "Claude reviews before merge" gate):

- Run fully autonomously through STEP 0 and items 0-10 IN ORDER, one PR at a
  time, merged before the next starts (items share test files).
- Self-review replaces the Claude gate. After implementing each item, spawn
  independent review sub-agents covering at least: (a) line-by-line diff
  correctness; (b) removed-behavior audit — did any RETAINED behavior lose
  test coverage (the exact class of miss found in PR #103: deleting a test
  file silently uncovered the live redaction pattern matrix); (c) orphan
  tracer — grep the post-change tree for orphans the change created:
  project.yml/package deps, settings.json keys (add newly-dead keys to the
  SettingsView.saveAdvancedSettings scrub), on-disk artifacts (token/cache
  files needing one-time startup cleanup), Localizable.xcstrings keys,
  stale comments justifying retained code via deleted features, and
  followups/docs line anchors. Adversarially verify each finding before
  acting; fix CONFIRMED findings pre-merge; record findings + outcomes in
  the PR description.
- Tombstone tests: each deleted surface gets ONE negative-assertion owner
  per source file — never duplicate the same forbidden-string scan across
  suites (PR #103 finding 5).
- Merge gates per PR: CI green; self-review findings fixed or explicitly
  deferred with reasons in the PR description; matching CHANGELOG.md entry;
  the doc trims for that item done in the same PR; mark the item done in
  this file.
- STOP AND FILE A BLOCKER (do not improvise) if: CI stays red after 2 fix
  attempts; a review finding suggests deleting anything on a KEEP list; a
  destructive data migration seems needed; or an item's scope materially
  exceeds this plan. Record the blocker at the top of this section and move
  to the next item only if independent.

STEP 0 (before any merge): reconcile the main-checkout working tree.
Inspect `git status`/`git diff` — expected: (a) doc/plan files (CHANGELOG.md,
MEMO.md, docs/followups.md, .memory) carrying this plan → commit as
`docs(plan): file feature-cut execution plan and decision records`; (b) Swift
popover/menubar modifications (MenuBarController, PopoverView,
GeneralSettingsSection, EngramServiceReadProvider, HomePopoverActionsTests,
PopoverScreen, PopoverSmokeTests, EngramServiceIPCTests) → run the focused
suites (HomePopoverActionsTests, EngramServiceIPCTests); if green and
coherent with the 2026-07-05 popover perf work, commit as a perf follow-up;
if not coherent, stash with a dated note here and continue. Then rebase
PR #103 if needed.

ITEM 0 — DONE in PR #103: finish PR #103 (Delete HTTP transcript web UI). Apply the review at
https://github.com/bbingz/engram/pull/103#issuecomment-4886389830 —
4 REQUIRED: (1) port `testRedactionCoversCommonTokenFamilies` +
`testRedactionStaticPatternsProduceByteIdenticalOutput` from deleted
EngramWebUIServerTests into EngramServiceCoreTests targeting
`TranscriptExportService.redactSensitiveContent` (5 of 8 secret families
currently uncovered); (2) add `settings.removeValue(forKey: "webUIEnabled")`
to the SettingsView.saveAdvancedSettings scrub (~:452-457); (3) remove the
orphaned Hummingbird dep from EngramServiceCore in macos/project.yml
(~:113-114) + `xcodegen generate` (app-target dep at ~:168-169 is
pre-existing dead — optional bonus); (4) one-time startup cleanup
`try? FileManager.default.removeItem(at: runtimeDirectory
.appendingPathComponent("webui.token"))`. 4 RECOMMENDED: consolidate the
tombstone scans to one owner per source file; legacy transcript-pager comments
now name live consumers; the orphaned unavailable localization key was removed;
the perf-section EngramWebUIServer anchors in this file are annotated as
resolved-by-deletion (PR #103). Then self-review, merge, and proceed to item 2
(item 1 == this PR).

Ground rules:

- Land or stash the uncommitted perf working tree FIRST (it touches
  `PopoverView.swift`, `MenuBarController.swift`, `HomePopoverActionsTests`,
  which collide with item 1).
- One PR per numbered item; item 2 MUST be its own PR (~11K LOC).
- Repo test rule applies: delete a feature's tests in the same PR; behavior
  changes need matching Swift tests. Run `xcodegen generate` after
  adding/removing Swift files; `npm run lint` must pass.
- Items 1 and 4 both touch `EngramServiceIPCTests.swift`,
  `SettingsHonestyTests.swift`, `AppSearchServiceCutoverScanTests.swift` —
  if doing both, edit each shared test file once, not per-feature.
- No destructive DB migrations: leave orphaned tables (`mined_rules`,
  vector scaffolding) inert on installed DBs.
- Each cut carries its own doc trim (README/CLAUDE.md/docs/mcp-tools.md:
  MCP tool count, "Local Service Security" web-UI section, sources count).

1. **DONE in PR #103 — DELETE EngramWebUIServer (HTTP transcript web UI).** Remove
   `macos/EngramService/Core/EngramWebUIServer.swift` (761 LOC) +
   `EngramWebUIServerTests.swift` (629 LOC); strip
   `readWebUIEnabled`/`provisionWebToken`/`webTask`/`emitWebReady`/
   `ServiceWebErrorEvent` wiring from `EngramServiceRunner.swift`; remove the
   toggle/button/menu-item/status-tile in `NetworkSettingsSection.swift`,
   `GeneralSettingsSection.swift`, `MenuBarController.swift`,
   `Views/Pages/HomeView.swift`; drop `endpointHost`/`endpointPort`/
   `web_ready`/`web_error` from `EngramServiceStatusStore.swift`; fix
   scattered assertions in EngramServiceIPCTests/SettingsHonestyTests/
   HomePopoverActionsTests/EngramServiceStatusStoreTests. KEEP
   `TranscriptExportService` + `redactSensitiveContent` (used by
   get_session/export) and the Hummingbird SPM dependency
   (EngramRemoteServer uses it). Trim the CLAUDE.md "Local Service
   Security" web-UI paragraphs.
2. **DONE in PR #104 — DELETE legacy TS dev-server/entrypoint surface.** Remove
   `src/web.ts`, `src/web/routes/*`, `src/web/views.ts`, `src/index.ts`,
   `src/daemon.ts`, `src/core/lifecycle.ts`, `src/core/daemon-startup.ts`,
   plus daemon-exclusive orphans (candidates: `auto-summary`, `alert-rules`,
   `mock-data`, `daemon-client`, `git-probe`, `watcher` under `src/core/`)
   and their tests + `tests/web/`. The orphan list is ADVISORY — confirm each
   with `npm run knip`/grep before deleting; two prior passes disagreed on
   `src/core/sync.ts` and `tests/integration/`, so keep any test/module that
   covers retained code (`tests/web/hygiene.test.ts` likely stays). KEEP
   modules used by retained `src/tools/*` (config, monitor, live-sessions,
   logger, usage-collector, ai-client). REQUIRED follow-through in the same
   PR: repoint `scripts/gen-mcp-contract-fixtures.ts` (parses `src/index.ts`
   today) at `macos/EngramMCP/Core/MCPToolRegistry.swift` so the CI-gated
   `tests/fixtures/mcp-golden/tools.json` Swift parity test keeps working;
   trim `bootstrap.ts` (`createMCPDeps`/`createDaemonDeps`), `knip.json`
   entry points, `package.json` `dev` script, `src/cli` dispatch fallback,
   README HTTP/API section.
3. **DONE in PR #105 — DELETE corpus rule mining (get_rules + background miner + schema).**
   Remove `mineCorpusRulesOnce`/`mineRulesWithLLM`/`corpusMiningCandidates`/
   `writeMinedRules` + 2 scheduling call sites in
   `EngramServiceRunner.swift` (~:799-1113); `get_rules` def/dispatch in
   `MCPToolRegistry.swift`; `getRules`/`minedRuleRows` in `MCPDatabase.swift`
   and the get_context rule-folding branch (~:860-873, covered by
   `testGetContextIncludesMinedRulesForProject`); `ensureMinedRulesTables` in
   `EngramMigrations.swift` (~:586-608, 2 idempotent call sites, no FKs).
   Update tests in EngramServiceIPCTests/EngramMCPExecutableTests/
   MigrationRunnerTests. Existing `mined_rules` rows on installed DBs stay
   inert. Add get_rules removal note to `docs/mcp-tools.md` (it was never
   documented there — that omission was part of the cut rationale).
4. **DONE in PR #106 — DELETE Skills + Hooks config-browser pages.** Remove
   `Views/Pages/SkillsView.swift` + `HooksView.swift` (92 LOC each), the two
   `Screen` enum cases + switch arms + `Section.config` entries,
   MainWindowView dispatch arms, `skills()`/`hooks()` across
   protocol/client/mock/`FileSystemEngramServiceReadProvider` (+3 private
   parsing helpers used only here) + `EngramServiceSkillInfo`/`HookInfo`
   DTOs, and tests (HooksSkillsTests, EngramServiceClientTests parts,
   EngramUITests Skills/Hooks screens+tests). Repoint ServiceTelemetryTests'
   one `hooks` example command to another empty-provider command (e.g.
   `sources`). CONFIG sidebar shrinks 4→2 (Agents, Memory) — relabel if it
   reads oddly.
5. **DONE in PR #107 — DELETE lint_config MCP tool (Swift product side only).** Remove
   `lintConfig`/`lintIssues` + the 8 lint-only private helpers from
   `MCPFileTools.swift` (KEEP `projectReview` helpers and shared
   `trimTrailingSlash`); registry def/dispatch/category in
   `MCPToolRegistry.swift` (~:371, :909-910, :1138); the golden test +
   fixture in EngramMCPExecutableTests; doc rows `docs/mcp-tools.md:297`,
   `README.md:237`, `macos/EngramMCP/AGENTS.md:13`. LEAVE
   `src/tools/lint_config.ts` alone (reference-only). Evidence: 0 calls in
   ~995K tracked tool-call telemetry.
6. **DONE in PR #108 — DELETE dead peer-sync settings surface.** Remove the "Sync" GroupBox in
   `NetworkSettingsSection.swift:25` (it literally states "Sync is not
   implemented in the Swift service") and demote the README peer-sync
   section (~README.md:321) to a one-line historical note. Keep
   `settings.json` legacy keys (`syncEnabled`/`syncPeers`/...) parse-tolerant
   — do not crash on their presence; grep `macos/` for sync DTO/field
   consumers to size the full removal before deleting beyond the UI.
7. **DONE in PR #109 — DELETE verified-dead scaffolding bundle.** Deleted
   `SQLiteVecSupport.swift`, `VectorRebuildPolicy.swift`, their self-only test,
   and the unused Swift Cascade gRPC live-sync client/discovery/proto bundle.
   Kept Antigravity legacy cache + CLI transcript parsing, Windsurf cache
   reading, TS reference/dev Cascade tooling, and active Swift semantic/hybrid
   retrieval. Added a deletion-guard scan test, updated active docs, and moved
   Windsurf SourceCatalog to the actual cache root `~/.engram/cache/windsurf`.
8. **DONE in PR #110 — FOLD Favorites page into a Sessions FilterPill.** Delete the 63-LOC
   Favorites page clone + its Screen case; add a "Starred" FilterPill on
   SessionsPageView. KEEP star toggle, favorites table, `setFavorite` IPC,
   and `listFavorites()` (2 callers — repoint to the pill's query path).
   Both verifiers passed this at confidence 5.
9. **DONE in PR #111 — DEMOTE project-migration batch/undo/history UI (no deletion).** In
   `Views/Pages/ProjectsView.swift` (~:87) move Select / Move Selected /
   Undo Recent Move / History behind an Advanced (or Developer Tools)
   affordance; keep single-project move and ALL project_* MCP tools intact.
   Motivation: local `migration_log` has exactly 2 rows, both
   `_engram_e2e_test_*` from 2026-04-20, and `BatchMoveSheet.swift:8`
   documents a dry_run-omission commit risk. `project_aliases` stays — it is
   load-bearing for list_sessions/search/get_context.
10. **DONE in PR #112 — DEFAULT-OFF archived sources: cline / iflow / lobsterai.** Keep parser
    code + fixtures; change defaults so these three are not scanned unless
    the user enables them (Workspace > Sources under an "Archived" group).
    Local evidence: 3/2/1 sessions, last activity 2026-02-27/2026-02-27/
    2026-03-08. Do NOT touch minimax (234 local sessions, active). Update
    the "17 sources" claims in README/CLAUDE.md to describe the
    active-vs-archived split.

Explicitly REJECTED (do not implement, recorded so nobody re-proposes them
blind): hiding the `live_sessions` MCP stub (deliberate honest-unavailable
contract with its own regression tests; hiding creates a worse inconsistent
state), cutting Windsurf/Antigravity adapters (Antigravity is live),
cutting the Observability suite (deliberate 2026-06-15 rebuild; UI-only cut
strands live telemetry), cutting the whole semantic/vector bundle (hybrid
retrieval behind get_memory is live and tested — only item 7a is dead), and
demoting the Popover usage section (active UX work stream, owner decides
there, not a maintenance cut).

## Closed — perf-integration review findings (2026-07-04)

**Historical section (closed).** As of 2026-07-08 there were **no active**
items in this section. The CursorAdapter WAL-aware parse-cache signature and
the three P3 latent issues were closed in the Wave 5 perf-residual closeout;
older P1/Web UI entries remain below only as closeout evidence. Do not treat
the narrative below as open engineering work.

From the 18-agent adversarial review of the Codex-integrated 8-PR perf batch
(base `f9a236dc..main`). The one blocking item (fts_map self-heal ownership) was
already fixed on `main` (see `CHANGELOG.md`, new test
`FTSIncrementalTests.testReusedRowidWithUnchangedContentIsNotMaskedByStaleMap`).
Each item below was re-verified against real code and **later closed** (see
per-item Resolution notes). The narrative is retained as historical evidence
only; it is not an open fix-pass list.

### P1 — oversized-transcript (>10k msgs) silent truncation makes totals/tails stale

- **Where:** `JSONLAdapterSupport.windowedMessages` and CodexAdapter's own
  path (`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:210`, and
  the `.messageLimitExceeded` return around `:98`–`:113`); consumers
  `macos/EngramMCP/Core/MCPTranscriptReader.swift` (`fullScanPage` `:347`,
  `collectVisiblePageWindow` `:384`). The former HTTP Web UI consumer was
  resolved by deletion in feature-cut item 1.
- **What changed:** an unwindowed read (`options.limit == nil`) that exceeds
  `ParserLimits.maxMessages` (10,000) no longer throws
  `.messageLimitExceeded`; it logs a private `.notice` and returns only the
  first 10k parsed records as success. This is a *deliberate, tested* change
  (AdapterWindowedReadTests) to avoid falling back to an uncapped legacy parser.
- **Why it was a problem (historical):** two downstream call sites still assumed
  "a whole read either fully succeeds or throws." MCP `get_session` computed
  `totalPages` from a truncated total, so a client that paged to the reported
  last page believed it read the whole session while the tail past record
  ~10,000 was silently missing; the resume primer's "last messages" could
  likewise go stale. Separately, `collectVisiblePageWindow` (cache-hit fast
  path) asked the adapter for `StreamMessagesOptions(offset: 0, limit: rawLimit)`,
  which bypassed the 10k cap that `fullScanPage` used to compute the cached
  total — so deep paging and the cached total disagreed about how much content
  existed.
- **Decision resolved (historical):** silent truncation was replaced by an
  explicit incompleteness signal. The preferred direction was adopted: a
  `truncated`/`totalKnownComplete` signal is threaded out of the adapter window
  so MCP totals and the resume primer report incompleteness instead of quietly
  capping (see residuals resolution below).

#### P1 residuals after Codex fix pass (re-verified 2026-07-05, Claude Code)

Codex's fix batches closed the *core* of P1: MCP `get_session` now surfaces
`truncatedAt` / `totalKnownComplete=false` and computes `totalPages` from the
capped window, `collectVisiblePageWindow` respects the cap via
`maxRawMessages`, the resume primer marks truncation, and markdown/JSON export
carry truncation metadata for the nine JSONL/cascade adapters that override
`streamMessagesWithMetadata`. Verified by re-reading the working tree plus green
focused suites (`AdapterWindowedReadTests`, `EngramMCPExecutableTests`,
`EngramServiceIPCTests`, `StartupBackfillTests`, `DatabaseManagerTests`). The
former HTTP Web UI suite and line anchors were resolved by feature-cut item 1
deletion. The two residuals below were resolved on 2026-07-05 by Codex:

- **Resolved by deletion:** the HTTP Web UI oversized-transcript
  banner/clamp path, helper-only tests, and `EngramWebUIServer` line anchors no
  longer exist after feature-cut item 1. MCP/export whole-transcript surfaces
  remain capped and marked; there is no browser transcript page left to track in
  this follow-up list.
- **Residual silent export truncation on adapters that do not override
  `streamMessagesWithMetadata`.** `KimiAdapter` (`:105`) and `OpenCodeAdapter`
  (`:220`) override only `streamMessages`, so they inherit the default
  `SessionAdapter.streamMessagesWithMetadata` (`SessionAdapter.swift:256`–`:264`)
  which always returns `truncatedAt = nil` / `totalKnownComplete = true`. An
  oversized (>10k message) session from either source therefore exports (and
  MCP-pages) capped at 10_000 with no truncation marker — the exact silent
  truncation P1 set out to remove, still present for these sources.
  **Resolution:** `KimiAdapter` and `OpenCodeAdapter` now override
  `streamMessagesWithMetadata` and report `truncatedAt = 10_000` /
  `totalKnownComplete = false` for whole-transcript reads that exceed the cap.
  Regression coverage lives in
  `EngramServiceIPCTests.testExportSessionMarksKimiOversizedTranscriptTruncated`
  and
  `EngramServiceIPCTests.testExportSessionMarksOpenCodeOversizedTranscriptTruncated`.

  **Validation:** focused
  `xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` with the three
  new/changed `-only-testing` filters passed on 2026-07-05. The required
  `xcodebuild -project macos/Engram.xcodeproj -scheme Engram -configuration
  Debug build` also passed.

### P2 — Web UI session-page ETag omits DB-mutable display fields

- **Resolved by deletion:** feature-cut item 1 removed the HTTP Web UI session
  page and `EngramWebUIServer`, so this ETag path no longer exists.

### P2 — CursorAdapter parse cache keyed on shared WAL db mtime/size

- **Where:** `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift:126`
  (parse cache keyed via `ParsedTranscriptCache.Signature.forFile(dbPath)`).
- **Problem:** `state.vscdb` is Cursor/VSCode's live SQLite store, commonly in
  WAL mode; committed writes land in `-wal` and the main file's mtime/size can
  stay unchanged until a checkpoint. Long-lived adapter cache consumers can serve
  stale cached messages while Cursor is open.
- **Fix direction:** include the `-wal` (and `-shm`) sidecar mtime/size in the
  cache signature, or don't cache while the sidecar is non-empty.
- **Resolution (2026-07-08, Codex):** current Swift cache signatures include
  both `-wal` and `-shm` sidecar mtime/size, and the residual is covered by
  `AdapterWindowedReadTests.testParsedTranscriptSignatureIncludesSQLiteWalSidecars_repro`.

### P3 — lower-impact / latent

- **FTS `optimize` gate blind to full rebuilds.**
  `macos/EngramCoreWrite/Indexing/StartupBackfills.swift` `optimizeFts` (`:625`)
  gates the FTS5 `optimize` merge on `ftsContentSignature` (`:650`), computed
  from `sessions`/`insights` aggregates. A `FTSRebuildPolicy` full rebuild
  doesn't move those aggregates, so on a future `expectedVersion` bump the freshly
  rebuilt multi-segment index is never merged. *Latent* until the next tokenizer/
  schema version bump. Fix: also gate on a rebuild marker/version, not just the
  content signature.
  **Resolution (2026-07-08, Codex):** `FTSRebuildPolicy.finalizeRebuildIfReady`
  invalidates the stored optimize signature after swapping in the rebuilt table;
  coverage lives in
  `FTSRebuildPolicyTests.testFinalizeRebuildInvalidatesStoredOptimizeSignatureForSwappedTable_repro`.
- **Whitespace-only query returns empty vs old browse-all.**
  `macos/Engram/Core/Database.swift` `keywordSearchSQL` (`:418`), `ctes.isEmpty`
  branch (`:445`). When `CJKText.ftsMatchTerms` yields `[]` (e.g. a 3-space
  query), the new CTE returns no rows; the old correlated-EXISTS query returned
  the most recent non-hidden sessions. Fix: restore the empty-term browse-all
  fallback (or short-circuit whitespace-only queries upstream).
  **Resolution (2026-07-08, Codex):** the app read path now falls through to
  the empty-term browse-all branch and preserves hidden/skip/lite exclusions;
  coverage lives in
  `DatabaseManagerTests.testWhitespaceOnlySearchBrowsesRecentVisibleSessions_repro`.
- **`reconcileSkipTierIndexArtifacts` undercounts embeddings deletes.**
  `macos/EngramCoreWrite/Indexing/StartupBackfills.swift` (`:713`) discards the
  `session_embeddings` delete count, so the returned/logged `reconcile_skip_fts`
  total understates cleanup. *Latent* until sqlite-vec / `session_embeddings`
  is implemented. Fix: add the embeddings-delete row count to the return value.
  **Resolution (2026-07-08, Codex):** skip-tier reconciliation now includes
  `session_embeddings` deletions in its returned/logged total; coverage lives in
  `StartupBackfillTests.testReconcileSkipTierDeleteCountIncludesEmbeddings_repro`.

## Closed in cleanup

All follow-up items from the 2026-05-24 backlog cleanup pass have matching
implementation or verification coverage. Evidence is recorded in
`docs/backlog-cleanup-report.md`.
