# Engram Follow-ups

Follow-ups are verification gaps, low-priority refactors, or items that need
real data, UI exercise, or product confirmation before becoming TODOs.

## Open

Open follow-ups as of 2026-07-06:

- **Resolve the preserved audit-remediation branch.**
  `codex-provider-audit-remediation` still tracks
  `origin/codex-provider-audit-remediation`; as of 2026-07-06 on
  `main@24cc4562`,
  `git rev-list --left-right --cherry-pick --count main...codex-provider-audit-remediation`
  returned `61 4`, so it has four commits not on `main`. Review/merge it or
  explicitly close and delete it later; do not include it in stale-branch
  cleanup.
- **Normalize local ignore rules.** `.git/info/exclude` still contains local
  duplicates (`node_modules`, `.husky/_/`, `dist/`) and repo-specific entries
  such as `audit/` and `.github/copilot-instructions.md`. Decide which belong in
  shared `.gitignore` and which should remain local-only.
- **Fix remaining perf-integration residuals.** Active items are in the
  perf-integration section below: Cursor WAL-aware parse-cache signatures and
  the three P3 latent issues. P1 truncation, Web UI ETag, and Web UI line-anchor
  items are already resolved.

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

## Open — perf-integration review findings (2026-07-04)

Current active items in this section as of 2026-07-06: CursorAdapter WAL-aware
parse-cache signatures plus the three P3 latent issues. The original P1
oversized-transcript path, Web UI ETag path, and Web UI line anchors were
resolved by later fixes/deletions and remain below only as closeout evidence.

From the 18-agent adversarial review of the Codex-integrated 8-PR perf batch
(base `f9a236dc..main`). The one blocking item (fts_map self-heal ownership) was
already fixed on `main` (see `CHANGELOG.md`, new test
`FTSIncrementalTests.testReusedRowidWithUnchangedContentIsNotMaskedByStaleMap`).
The items below were each re-verified against real code and are left for a
follow-up fix pass. Every behavior change here needs a matching Swift test.

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
- **Why it's a problem:** two downstream call sites still assume "a whole read
  either fully succeeds or throws." MCP `get_session` now computes `totalPages`
  from a truncated total, so a client that pages to the reported last page
  believes it read the whole session while the tail past record ~10,000 is
  silently missing; the resume primer's "last messages" can likewise go stale.
  Separately, `collectVisiblePageWindow` (cache-hit fast path) asks the adapter
  for `StreamMessagesOptions(offset: 0, limit: rawLimit)`, which bypasses the
  10k cap that `fullScanPage` used to compute the cached total — so deep paging
  and the cached total disagree about how much content exists.
- **Needs a decision:** silent truncation vs. surfacing it. Preferred direction:
  thread a `truncated`/`totalKnownComplete` signal out of the adapter window so
  MCP totals and the resume primer can report incompleteness instead of
  quietly capping. Confirm the intended UX before implementing.

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

### P3 — lower-impact / latent

- **FTS `optimize` gate blind to full rebuilds.**
  `macos/EngramCoreWrite/Indexing/StartupBackfills.swift` `optimizeFts` (`:625`)
  gates the FTS5 `optimize` merge on `ftsContentSignature` (`:650`), computed
  from `sessions`/`insights` aggregates. A `FTSRebuildPolicy` full rebuild
  doesn't move those aggregates, so on a future `expectedVersion` bump the freshly
  rebuilt multi-segment index is never merged. *Latent* until the next tokenizer/
  schema version bump. Fix: also gate on a rebuild marker/version, not just the
  content signature.
- **Whitespace-only query returns empty vs old browse-all.**
  `macos/Engram/Core/Database.swift` `keywordSearchSQL` (`:418`), `ctes.isEmpty`
  branch (`:445`). When `CJKText.ftsMatchTerms` yields `[]` (e.g. a 3-space
  query), the new CTE returns no rows; the old correlated-EXISTS query returned
  the most recent non-hidden sessions. Fix: restore the empty-term browse-all
  fallback (or short-circuit whitespace-only queries upstream).
- **`reconcileSkipTierIndexArtifacts` undercounts embeddings deletes.**
  `macos/EngramCoreWrite/Indexing/StartupBackfills.swift` (`:713`) discards the
  `session_embeddings` delete count, so the returned/logged `reconcile_skip_fts`
  total understates cleanup. *Latent* until sqlite-vec / `session_embeddings`
  is implemented. Fix: add the embeddings-delete row count to the return value.

## Closed in cleanup

All follow-up items from the 2026-05-24 backlog cleanup pass have matching
implementation or verification coverage. Evidence is recorded in
`docs/backlog-cleanup-report.md`.
