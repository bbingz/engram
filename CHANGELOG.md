# Changelog

All notable changes to this project will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/).

---

## [Unreleased]

### Advanced noise controls quieted (2026-06-01, Codex)

Continued the approved Today Workbench + Advanced noise-reduction direction.

- Moved the simplified `Session Filter` from General settings into Advanced,
  while preserving the existing `noiseFilter` settings contract.
- Moved raw transcript diagnostic toggles (`Show System Prompts` and
  `Show Agent Communication`) from General display settings into a new
  Advanced `Transcript Diagnostics` group, preserving the existing
  `@AppStorage` keys.
- Added `zh-Hans` localization for the new diagnostics group.
- Added scan tests that keep these low-level noise/diagnostic controls out of
  General settings.

Verified with:
- red targeted tests for the session-filter and transcript-diagnostics moves
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram
  -configuration Debug -derivedDataPath macos/build/DerivedData
  -only-testing:EngramTests/AppSearchServiceCutoverScanTests/testSessionFilterLivesUnderAdvancedSettings
  -only-testing:EngramTests/AppSearchServiceCutoverScanTests/testTranscriptDiagnosticTogglesLiveUnderAdvancedSettings
  CODE_SIGNING_ALLOWED=NO`

### Today Workbench completion pass (2026-06-01, Codex)

Closed the concrete gaps left by the first Today Workbench UI pass.

- Added safe copy-resume-command actions to Today session rows. The copied
  command is rendered through the same shell-safe `EngramCLIResumeCommand`
  path used by CLI resume.
- Added durable local follow-up handling: marking a Today follow-up handled
  stores the session id in UserDefaults and removes it from the Follow-ups
  section.
- Ranked Continue sessions by resume-oriented usefulness instead of pure
  recency, boosting known direct-resume sources, cwd availability, and
  agent-child context.
- Added Changed Repos warnings for recent migrations and dirty/unpushed repo
  state, plus string-catalog entries for the new labels.

Verified with:
- `python3 -m json.tool macos/Engram/Resources/Localizable.xcstrings`
- `git diff --check`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram
  -configuration Debug -derivedDataPath macos/build/DerivedData
  -only-testing:EngramTests/TodayWorkbenchTests
  -only-testing:EngramTests/AppSearchServiceCutoverScanTests
  CODE_SIGNING_ALLOWED=NO`
- `xcodebuild build -project macos/Engram.xcodeproj -scheme Engram
  -configuration Debug -derivedDataPath macos/build/DerivedData
  CODE_SIGNING_ALLOWED=NO`

### Today Workbench i18n sync (2026-06-01, Codex)

Fixed the localization gap left by the Today Workbench UI pass.

- Added `zh-Hans` entries for the new Today Workbench and Search Advanced
  labels, empty states, service rows, tooltips, and count-format strings in
  `Localizable.xcstrings`.
- Routed dynamic Today values through localization APIs: service KPI state,
  unavailable Web UI state, follow-up detail text, parent/agent/recent
  transcript counts, and the Today load error message.

Verified with:
- `python3 -m json.tool macos/Engram/Resources/Localizable.xcstrings`
- `git diff --check`
- `xcodebuild build -project macos/Engram.xcodeproj -scheme Engram
  -configuration Debug -derivedDataPath macos/build/DerivedData
  CODE_SIGNING_ALLOWED=NO`

### Today Workbench UI first pass (2026-06-01, Codex)

Implemented the approved Today Workbench + Advanced noise-reduction direction
in the macOS app instead of only recording the spec.

- **Default screen is Today**: the existing `home` route now presents as
  `Today` in the sidebar and remains the app launch target.
- **Today Workbench shipped**: `HomeView` now focuses on Continue, Follow-ups,
  Changed Repos, and Service State. Continue and Follow-up rows expose
  open-transcript and resume actions; resume reuses the hardened
  `ResumeDialog` / `TerminalLauncher` path.
- **Follow-up/deferred home added**: Today derives follow-up candidates from
  indexed markers such as `follow-up`, `followup`, `deferred`, `todo`,
  `review`, `remaining`, `延后`, and `跟进`, deduplicated by session id.
- **Search advanced filters quieted**: `SearchPageView` keeps the query and
  mode selector visible, while project/source/time filters now live behind one
  `Advanced filters` disclosure.
- **README reality aligned**: macOS App docs now describe Today Workbench and
  collapsed Advanced filters, and transcript pagination docs now state the raw
  adapter-offset behavior.

Verified with:
- `git diff --check`
- `xcodebuild build -project macos/Engram.xcodeproj -scheme Engram
  -configuration Debug -derivedDataPath macos/build/DerivedData
  CODE_SIGNING_ALLOWED=NO`
- `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram
  -configuration Debug -derivedDataPath macos/build/DerivedData
  -only-testing:EngramTests/ViewMainThreadReadTests
  -only-testing:EngramTests/AppSearchServiceCutoverScanTests
  CODE_SIGNING_ALLOWED=NO`

UI smoke note: selected `EngramUITests` did not establish an XCTest connection
and failed before app assertions with `EngramUITests-Runner ... Early
unexpected exit`; the failing result bundle is
`macos/build/DerivedData/Logs/Test/Test-Engram-2026.06.01_10-43-57-+0800.xcresult`.

### Copilot hardening triage + Today Workbench spec (2026-06-01, Codex)

Recorded the Copilot multi-expert review and closed the two Critical security
items before continuing product UI expansion. Continued through all Important
and Minor follow-ups from that review.

- **Resume command injection fixed**: `TerminalLauncher` now shell-quotes `cwd`,
  command, and args before AppleScript interpolation, reusing the CLI resume
  shell escaping behavior. Added malicious-character coverage for semicolons,
  command substitution, quotes, spaces, and AppleScript escaping after shell
  quoting.
- **Project mutators fail closed**: `project_move`, `project_archive`,
  `project_undo`, and `project_move_batch` now force the Swift service
  single-writer path and do not direct-write fallback when the daemon/service is
  unreachable, regardless of the user-level strict toggle.
- **`project_move_batch` contract aligned**: TS MCP/API now require inline JSON
  in the legacy `yaml` field, matching Swift service/MCP/docs. YAML payloads are
  rejected on the MCP/API path; the CLI file-based `move-batch <yaml>` entry
  remains unchanged.
- **Transcript defaults aligned**: TS `get_session`, TS HTTP transcript routes,
  and Swift WebUI now default to non-empty user/assistant messages and hide tool,
  system prompt, and agent communication messages unless a diagnostic/raw path is
  used.
- **Transcript pagination fixed**: HTTP transcript `offset` now tracks consumed
  adapter position instead of filtered visible-message count, avoiding missing or
  repeated visible messages when hidden messages sit between pages.
- **Service stdout event parsing hardened**: `EngramServiceLauncher` now buffers
  stdout by newline before decoding JSON events and appends stdout data before
  trimming complete lines, so pipe chunk boundaries, including a JSON chunk
  followed by a separate newline chunk, no longer silently drop structured
  service events.
- **Swift transcript exports aligned**: Swift MCP `get_session` and service
  JSON/Markdown export now apply `SystemMessageClassifier` in their default
  visible-message predicate, matching App/Web/TS behavior for system prompts and
  agent communication messages.
- **Transcript classifier parity expanded**: shared fixtures now cover leading
  whitespace, Antigravity and `antigravity-legacy` `<SYSTEM_MESSAGE>` wrappers,
  Qwen prompts, local-command output, and skill/system wrappers. TS
  classification now trims prefix input and treats `<SYSTEM_MESSAGE>` as a
  system prompt only for Antigravity-family transcripts.
- **Swift test HOME isolation hardened**: HOME-mutating service-core tests now
  use a serialized `ServiceCoreTestHomeScope` that restores process-global HOME
  even after failures.
- **WriterGate cancellation test stabilized**: the queued-cancellation test now
  waits for a real queued waiter instead of relying on fixed sleep timing.
- **EmbeddingIndexer integration covered**: added a real
  `Database` + `SqliteVecStore` + deterministic `EmbeddingClient` test that
  verifies model persistence and restart skip behavior.
- **Adapter parity freshness gated**: `check-adapter-parity-fixtures` now
  regenerates fixtures into a temp tree and compares canonical JSON against the
  committed corpus, ignoring only volatile commit/node metadata.
- **CI screenshot gate hardened**: UI screenshot jobs now require a manifest,
  fail true size mismatches, and write diff images under the uploaded
  `screenshots/diffs/` artifact path. The fixture-check job now runs adapter
  parity freshness.
- **Swift review surfaces split**: project migration service commands now live
  in `EngramServiceCommandHandler+ProjectMigration.swift`, and MCP project
  result ordering now lives in `MCPToolRegistry+ProjectResults.swift`, reducing
  the main handler/registry audit surface without changing tool contracts.
- **Focused Swift test schemes added**: `EngramTests` and `EngramUITests` are
  now generated shared schemes alongside the existing aggregate `Engram`
  scheme.
- **Fixture-generator test shell assumptions removed**: Stage 2 fixture
  generator tests now use Node filesystem traversal instead of Unix `find`, and
  script/test/active-doc invocations use `npm exec` or package scripts instead
  of hard-coded `./node_modules/.bin/tsx`.
- **Settings copy aligned**: Network settings now says project migration tools
  always require the Swift service and the strict toggle only controls remaining
  MCP write fallbacks.
- **Review captured**:
  `docs/reviews/2026-06-01-copilot-product-hardening-review.md` tracks the full
  Critical/Important/Minor queue from Copilot's review.
- **Product direction captured**:
  `docs/superpowers/specs/2026-06-01-today-workbench-design.md` records the
  approved Today Workbench + Advanced noise-reduction direction and names these
  hardening items as prerequisites.

### Deferred follow-ups closed + local release build deployed (2026-05-30, Codex)

Resumed from Claude session `93d5af5d-80b5-42ee-bca2-b397732c0dd0` and handled
the combined continuation scope: the two deferred items plus all documented
follow-ups from the prior audit handoff.

- **Closed mig-2**: `FTSRebuildPolicy` now rebuilds into
  `sessions_fts_rebuild`, keeps the live `sessions_fts` searchable during the
  rebuild, and atomically swaps the shadow table into place only after
  recoverable FTS jobs drain. Fresh empty databases mark `fts_version=3`
  immediately so fresh-schema and parity checks stay current.
- **Closed conc-1**: `UnixSocketServiceServer` now offloads blocking frame
  reads/writes to a dedicated concurrent GCD queue, keeping per-client socket I/O
  off Swift's cooperative executor while preserving the #32 receive-timeout
  behavior.
- **Closed CI follow-up**: `.github/workflows/test.yml` now runs the `Engram`,
  `EngramServiceCore`, and `EngramMCPTests` schemes in `swift-unit`.
- **Closed post-merge audit follow-up**:
  `docs/reviews/2026-05-30-pr26-32-post-merge-regression-audit.md` records a
  PASS verdict for PR #26-#32 with source-grounded evidence.
- **Updated README reality map**: the GitHub-facing README now documents 28 Swift
  MCP tools, keyword-only Swift search with semantic/hybrid downgrade behavior,
  current App capabilities, and local release/deploy commands.
- **Hardened CI follow-up tests**: `testGetSessionMatchesGolden` now runs
  against a temporary fixture DB with the transcript path rewritten to the
  current checkout, so Swift MCP contract tests no longer depend on the absolute
  path that existed when `mcp-contract.sqlite` was generated.
- **Verified and deployed locally**: full Swift/Node verification passed, a full
  Developer ID export was produced at `macos/build/EngramExport/Engram.app`, and
  build `0.1.0 (719)` was installed into `/Applications/Engram.app`.

### Deep-dimension audit of main + 16 fixes across PR #26–#32 (2026-05-30, Claude)

A second, deeper adversarially-verified audit (8 dimensions beyond the first
round's 7: concurrency/actor-isolation, GRDB transactions, IPC/transport edges,
migration idempotency, parsing/path-safety, UI state races, ProjectMove
integrity, indexing lifecycle). 22 raw findings → 18 confirmed (≥2/3 skeptic
lenses) → 16 deduped, shipped as seven focused, individually-verified,
squash-merged PRs:

- **#26 project-move integrity** (HIGH) — (pm-1) `MigrationLock.acquire` + the
  Phase-A write sat outside the do/catch, so a transient DB error leaked the
  lock holding the live pid → permanent DoS for all moves until restart; fixed
  with a function-scoped `defer` release. (pm-2) the patch loop threw on the
  first hard error before recording a later-index success, so compensation left
  it rewritten-but-unreverted (silent corruption); two-pass manifest build.
- **#27 writer-gate permit leak** (HIGH) — `ServiceAsyncSemaphore.wait()` could
  hand a permit to a waiter whose task was cancelled-after-signal, then throw at
  the post-resume `checkCancellation()` without releasing → permanent
  single-writer deadlock (every later write WriterBusy). Release on cancel. Also
  fixed a flaky existing gate test this bug caused.
- **#28 startup-scan gate split** (idx-2) — the whole structural backfill ran as
  one gated command, starving user writes with WriterBusy for minutes after
  start; split `runStartupBackfills` into index|maintenance+parents|orphan,
  gated separately. Also fixed a stale FTS test (`testFTSSyntaxErrorIsTagged…`)
  broken by #19's escaping and hidden by the CI gap (below).
- **#29 DB write atomicity** — (mig-1, HIGH-impact) aux-table v2 migrations
  copied rows into FK-bearing tables without orphan filtering → `FOREIGN KEY
  constraint failed` fataled `migrate()` → `exit(70)` every boot; add
  `AND session_id IN (SELECT id FROM sessions)`. (grdb_txn-2) per-snapshot writes
  weren't atomic → a mid-sequence failure left the sessions row advanced with no
  FTS job; wrap in `db.inSavepoint`.
- **#30 live indexing** — (idx-1) the 5-min periodic scan never ran
  parent-link/dispatch detection, so agent children created mid-run stayed
  top-level until restart; run `runPeriodicParentBackfills()` after each scan.
  (idx-4) `RepoDiscovery.runGit` read pipes only after exit → deadlock on >64KB
  git output; drain concurrently.
- **#31 SwiftUI off-main + async ordering** (ui-1..7) — four views read SQLite
  on the main thread (Timeline/Favorites/About/command-palette nav); search
  could clobber results with a stale response; ExpandableSessionCard invalidated
  on the count SUM; filter `.onChange` spawned uncancelled Tasks. Task.detached,
  cancellation guards, `[confirmed,suggested]` key, `.task(id:)`.
- **#32 IPC liveness + retention + web-host** (LOW) — (ipc-3) reject on
  `setSocketTimeout` failure (was `try?` → unbounded read + permit leak). (ipc-4)
  events() rides out transient `serviceUnavailable` instead of terminating the
  status stream. (idx-5) add `usage_snapshots` to observability retention.
  (web-port) enforce `expectedPort` in WebUI loopback Host/Origin checks.

Verified clean (no fix): **parsing/path-safety** — MCP transcript reads
DB-resolved paths (ID lookup, not caller input), lint refs are cwd-confined,
JSONL readers skip malformed lines / invalid UTF-8 without crashing, regexes are
ReDoS-safe.

Deferred as documented conscious tradeoffs (risk > value at LOW severity):
- **mig-2** — an FTS_VERSION bump drops + rebuilds `sessions_fts`, so keyword
  search returns empty during the background re-index. Crash recovery is correct;
  no data loss. The clean fix (side-table build + atomic swap) is an invasive,
  risky rewrite of the rebuild + drain path; left for a dedicated effort.
- **conc-1** — per-client blocking `readFrame` runs on the cooperative pool, but
  with #32's ipc-3 the read is always bounded by the 10s SO_RCVTIMEO, so
  starvation is bounded + self-recovering + same-user-gated. Offloading I/O off
  the cooperative pool is a larger transport refactor.

Process note: **CI does not run `EngramServiceCoreTests` or `EngramMCPTests`**
(the `swift-unit` job only runs the `Engram` scheme = EngramCoreTests +
EngramTests). Service-core/MCP fixes were compile-gated by CI and unit-verified
locally; this gap let #19's stale FTS test slip into main. Adding those targets
to CI is a follow-up (socket/timing tests need a stability review first).

### Multi-expert audit of main + 13 fixes across PR #19–#23 (2026-05-30, Claude)

After the PR #18/#15/#16 merge train, ran a 7-dimension adversarially-verified
audit of the Swift product runtime (29 surviving findings, 0 refuted), deduped
to ~15 real issues, and shipped 13 fixes as five focused, individually
CI-green, squash-merged PRs:

- **#19 search robustness** — (#1) FTS version bump dropped `sessions_fts` but
  `enqueueStaleFtsJobs` only re-enqueues content-changed sessions, so unchanged
  sessions vanished from search after an upgrade → re-open completed FTS jobs in
  `FTSRebuildPolicy`. (#2) Raw queries with FTS5 syntax chars threw `fts5: syntax
  error` → new `ftsMatchQuery` quotes each token. (#3) `containsCJK` missed
  Hangul Syllables (≥ U+AC00) → Korean now routes through the LIKE fallback.
  (#9) `GROUP BY … ORDER BY rank` used an arbitrary message bm25 → `MIN(rank)`.
- **#20 runtime/data** — (#5) one-shot ~661k-row `metrics` prune (no `ts` index,
  single transaction) → add `idx_metrics_ts` + rowid-bounded batched prune looped
  via separate gated writes. (#4) menu-bar today's-parents badge over-counted →
  add `suggested_parent_id IS NULL` + `tier != 'skip'`.
- **#21 read-pool + shared helpers** — (#8) extracted the verbatim-duplicated
  CJK/FTS helpers into `Shared/EngramCore/CJKText` (compiled into both app +
  EngramCoreRead, no new dependency). (#15) app read-pool `cache_size` literal →
  shared `SharedDBConfig.cacheSizeKiB`. (#10) `EngramServiceCommandHandler.readOnlyPool`
  → `SQLiteConnectionPolicy.readerConfiguration()`.
- **#22 dead-code removal** — (#7) deleted the never-instantiated
  `MCPServer`/`MCPTools`/`IndexerProcess` cluster (incl. a Node-daemon spawner)
  + its test.
- **#23 parent-detection + service** — (#12) polycli review-content match scoped
  to provider sources (`source != 'claude-code'`) so genuine claude-code review
  sessions aren't hidden. (#13) all stdout JSON serialized through a lock-guarded
  `writeStdoutLine`. (#14) `RepoDiscovery.sessionCwdCounts` capped to the 200
  busiest cwds to bound the per-cycle git fan-out.

Every behavior change has Swift tests; each PR was CI-green before squash-merge.
Two larger items were deferred to their own focused PRs. **#6 shipped as PR #24**
— `StartupBackfills.runInitialScan` now delegates to `runStartupBackfills` +
`drainStartupIndexJobs`, and the service runs the structural scan in one gated
command then drains the FTS backlog one batch per gated command, releasing the
single write gate between batches so user writes no longer time out with
WriterBusy behind a long startup scan (indexAll itself still holds the gate for
its run). **#11 shipped as PR #25** — `quality_score` is now plumbed through
`EngramServiceSearchResponse.Item` so the value band (re-introduced from #21)
reaches the primary online search path, rendered as a thin leading value-band
bar on each search result row (high=green, medium=neutral, low=dim, unknown
hidden). All 15 deduped audit issues are now resolved across PR #19–#25.

### Reviewed + hardened PR #15; merged PR #18/#15/#16 (2026-05-30, Claude)

Multi-agent review of `feat/search-snippet-highlight` (6 dimensions,
adversarially verified — 17 findings, 0 refuted), then fixes and a clean
squash-merge train. Fixes landed on PR #15 (`e1a557e5`, `57b76e90`):

- Removed `PRAGMA mmap_size = 256MiB` from the shared connection policy. The
  service runs an in-process startup `VACUUM` (`StartupBackfills.vacuumIfNeeded`)
  that can shrink the DB file while reader connections in the SAME process are
  already serving socket requests — a large mmap window over a truncated file is
  a SIGBUS hazard. Kept `cache_size = -16000` (the primary read accelerator) and
  also applied it to `DatabaseManager.openReadOnlyPool` so the GUI search path
  (`searchWithSnippets`) actually benefits. Verified macOS system SQLite default
  `mmap_size` is 0, so dropping the pragma genuinely disables mmap.
- Replaced `try! Session(row:)` with throwing `try` in both `searchWithSnippets`
  map closures. Force-try turned a recoverable GRDB decode error into a hard
  crash the callers' `try?`/`catch` could not handle; the throwing form restores
  graceful degradation.
- Dropped the unwired `Session.ValueBand`/`valueBand`/thresholds. No view
  consumed them and the online/service search path never carries `quality_score`
  (so a band would only ever render in the offline fallback). Kept the
  `quality_score` decode. Value-band UI deferred to a follow-up that plumbs
  `quality_score` through `EngramServiceSearchResponse.Item`.

Merge train (all squash; CI green at each step): #18 → main; main merged into
#15 (0 conflicts) → #15 CI green → merged; main merged into #16 → CI green →
merged. Open PR queue is now empty.

Deferred follow-ups: `cache_size` on `EngramServiceCommandHandler.readOnlyPool`;
value-band online plumbing + UI; extract the duplicated `cjkHighlightedSnippet`
into a shared module.

### Fixed — PR #18 CI/test follow-up after Claude handoff (2026-05-30, Codex)

- Fixed the Linux TypeScript coverage failure by making the Swift boundary
  script test skip only when `xcodegen` is truly unavailable, while avoiding a
  login-shell PATH probe that would hide the CI condition.
- Fixed the macOS Swift CI success-marker check by using literal
  `grep -Fq '** TEST SUCCEEDED **'` instead of an invalid BSD grep regex.
- Reduced Swift compiler type-check pressure in
  `FTSRebuildPolicyTests.readCounts` without changing test behavior.
- Removed an empty `ReplayState` `nonisolated deinit` that compiled locally on
  Xcode 26.4 but failed GitHub's Xcode 16.4 runner without the experimental
  `IsolatedDeinit` frontend flag.
- Hardened the CI-sensitive Swift tests uncovered after that fix: `runGit`
  now treats monotonic timeout overruns as nil even if the process finishes
  before a delayed semaphore wake, the timeout regression test no longer uses a
  0.1s timing cliff or late stdout, and the Unix socket fixture now uses GCD
  accept/handler queues without sharing one `JSONDecoder` across concurrent
  client handlers.
- Restored test strength from the handoff: release bundle forbidden-artifact
  hygiene remains cross-platform, and the resume API test asserts the
  deterministic Cursor `open` command instead of allowing a broad error shape.
- Fixed the screenshot comparison gate reached after Swift/TypeScript were
  green: same-aspect UI screenshots are now normalized to the smaller
  resolution before pixel/SSIM/hash comparison, while true aspect-ratio
  mismatches still fail as `size_mismatch`.
- Hardened UI CI against GitHub-hosted macOS Setup Assistant popups by
  quitting/killing Setup Assistant before smoke/full XCUITest runs.
- Made CI screenshot size mismatches report-only because GitHub macOS captures
  1024x768 screenshots while the committed baselines are 3840x2160; true
  same-size visual diffs still fail the comparison step.

Verification: no-xcodegen Vitest skip smoke under a restricted PATH; targeted
Vitest suites for server, release-verify, and Swift boundary scripts; full
`npm run test:coverage` (1424 pass); `npm run typecheck:test`; `npm run lint`;
targeted `EngramCoreTests/FTSRebuildPolicyTests`; full local Swift unit run
(227 tests, 1 skipped, 0 failures); literal `grep -Fq` success-marker smoke on
the xcodebuild log. First PR #18 rerun after `90f869dc` passed lint,
dead-code, fixture-check, and typescript, then exposed the Xcode 16.4
`nonisolated deinit` compiler error fixed here. Second rerun after `5f572403`
passed the same non-Swift checks and progressed to CI-only Swift timing/fixture
failures fixed here. The next rerun after `c561d0fb` passed swift-unit and
typescript, then exposed a UI smoke screenshot comparison size-mismatch gate;
the UI tests themselves passed and the comparison script now handles runner
resolution differences. The next rerun after `818cb599` progressed past
comparison and failed only because `com.apple.SetupAssistant` /
`DiagnosticsAndUsage` intercepted app activation until the UI job timeout.
The next rerun after `794107f1` passed XCUITest and failed only on the known
1024x768-vs-3840x2160 screenshot size mismatch, now made report-only in CI.
Pre-existing untracked `docs/full-review-report.md` was not touched.

### Fixed — AI title/summary observability defects, 5-round review (2026-05-27, Claude)

Fixed seven correctness/robustness defects in the "filtered search and AI title
observability" change (`168b4abc`), each with regression coverage:

- **AI saw only the first message.** `EngramServiceCommandHandler.aiContext`
  read the transcript with `LIMIT 1`, but `sessions_fts` stores one row per
  message, so every AI summary/title was generated from just the opening
  message. Now aggregates all rows `ORDER BY rowid`.
  Test: `EngramServiceIPCTests.testReadAIContextAggregatesAllFtsRows`.
- **`regenerateAllTitles` was all-or-nothing + included noise.** A single AI
  failure (rate limit/timeout) aborted the whole batch and discarded every
  generated title; it also issued paid AI calls for `skip`-tier sessions.
  Now per-item failures are caught and skipped, and `readTitleContexts`
  excludes `tier = 'skip'`.
  Test: `EngramServiceIPCTests.testReadTitleContextsExcludesSkipTierAndTitledSessions`.
- **Summary prompt ignored user settings.** The service hardcoded a Chinese
  3-sentence prompt. Added `ServiceAIClient.renderSummaryPrompt` (mirrors
  `renderPromptTemplate` in `src/core/ai-client.ts`) honoring
  `summaryLanguage` / `summaryMaxSentences` / `summaryStyle` / `summaryPrompt`.
  Tests: `testRenderSummaryPromptHonorsLanguageMaxSentencesAndStyle`,
  `testServiceAISettingsSummaryConfigCarriesTuning`.
- **`DatabaseManager.currentPool()` data race.** Removed the lock-free read of
  the `nonisolated(unsafe)` `pool`; it is now always read under `poolLock`.
- **Dead code.** Removed unused `SearchPageView.hasActiveFilters`.
- **TS settings migration not persisted.** `readFileSettings` only wrote back
  when `migrateSettings` returned a new object, so the legacy Swift
  `titleBaseURL → titleBaseUrl` rename never reached disk and the deprecated
  key was never removed. Now forces write-back and deletes `titleBaseURL`.
  Test: extended `tests/core/config.test.ts` to assert the on-disk result.
- **`joinApiUrl` doubled the gemini path.** It only collapsed an exact `/v1`
  segment, so a base ending `/v1beta` produced `/v1beta/v1beta/...`. Generalized
  to collapse any duplicated leading path segment.
  Tests: new `joinApiUrl` + `normalizeOpenAICompatibleModel` suites.

Verification: `npx vitest run tests/core/{config,ai-client,title-generator}.test.ts`
→ 63 pass; `npm run build` (tsc) exit 0; `./node_modules/.bin/biome check .`
0 errors (note: `npm run lint` exit 1 is an rtk-wrapper artifact, biome itself
passes); `xcodebuild -scheme Engram build-for-testing` exit 0;
`xcodebuild -scheme EngramServiceCore test` → 85 pass;
`-only-testing:EngramTests/DatabaseManagerTests` → 43 pass.

Known residual (intentionally deferred): anthropic/gemini summary protocols
still fall back to native (service implements OpenAI shape only, pre-PR
behavior); Keychain API key is injected to the service via env at launch, so
key rotation needs a service restart; `enqueueStaleFtsJobs` first-run reindex
is unbounded by design.

### Fixed — Codex v0.133 MCP startup compatibility (2026-05-25, Codex)

- Fixed Engram MCP startup in current Codex TUI sessions by accepting MCP
  `protocolVersion: 2025-06-18`. Before this, `/Users/bing/.engram/bin/engram-mcp`
  rejected initialize with `-32602 Unsupported protocolVersion`, so Codex showed
  `MCP startup incomplete (failed: engram)` and `Tools: (none)`.
- Added an executable regression test for the current Codex protocol version,
  alongside the older-version and unsupported-version coverage.
- Built and deployed `/Applications/Engram.app` build `0.1.0 (691)` with
  Developer ID team `J25GS8J4XM`. Installed-shim smoke now returns
  `protocolVersion: 2025-06-18` and the full Engram MCP tool list; app/service
  process checks show normal CPU/RSS and no resident `EngramMCP` helper after
  the client closes.

### Fixed — TDD remediation of all open roadmap items (2026-05-23, Claude)

Drove every open item in `docs/roadmap.md` to resolution with failing-test-first
TDD against the Swift product. All Swift suites + the TS fixture-generator test
pass.

- **Repos page no longer dormant (High):** new
  `EngramCoreWrite/Indexing/RepoDiscovery.swift` populates `git_repos` from
  distinct session `cwd`s (NUL-separated `git log`, never `|` — retiring the old
  Node `git-probe.ts` pipe bug). Wired into the service recent-scan loop. Tests:
  `RepoDiscoveryTests` (injected-probe aggregation/upsert + real-git probe).
- **Auto-title on indexing (Med):** `SessionSnapshotWriter.upsert` now derives
  `generated_title` (summary first line → project/cwd + date → id) at index
  time; `ON CONFLICT` COALESCE never clobbers an existing/custom title. Tests:
  `IndexAutoTitleTests`. Indexer-parity fixture + `gen-indexer-parity-fixtures.ts`
  updated to mirror the derivation (regen-stable).
- **Search false promise (Med):** `SearchMode.availableModes(embeddingAvailable:)`
  restricts modes to keyword unless embeddings exist (sqlite-vec is unimplemented);
  the mode toggle hides when only one mode is serviceable; `GlobalSearchOverlay`
  requests `keyword` instead of hardcoded `hybrid`. Tests: `SearchModeTests`.
- **Transcript (Low):** `ColorBarMessageView.displayLabel` surfaces `TOOL: <name>`
  for tool rows; "Copy Entire Conversation" added to the message context menu,
  backed by the new pure `TranscriptText.conversationText`. Tests:
  `TranscriptLabelAndCopyTests`.
- **Session list (Low):** column-visibility menu bound to `ColumnVisibilityStore`;
  `selectedProject` / `sortOrder` persisted via `@AppStorage` (sort round-trips a
  key+ascending pair). Tests: `SessionListPersistenceTests`.
- **Perf (Low):** shared static `ISO8601DateFormatter` in `SwiftIndexer` and
  `EngramServiceCommandHandler` (was per-call).
- **PR5 usage probes (investigated):** not a defect — `usage_snapshots` is never
  written and the collector is a no-op, but `PopoverUsageSection` already hides on
  empty data (no fake bars). Real probes are deferred net-new work.

Regression: `EngramCoreTests` 281/281, `EngramServiceCore` 63/63, `EngramTests`
8/8 (run under developer signing, team `J25GS8J4XM`), `EngramService` builds,
`stage2-fixture-generators` 9/9.

### Docs — issues.md verification + canonical roadmap (2026-05-23, Claude)

Re-verified all 16 open items in `tasks/issues.md` (written 2026-04-29 against
the Node-era spec) against the **Swift product**, using 4 parallel exploration
passes. Result recorded in new `docs/roadmap.md` (now the canonical pending-work
list); `tasks/issues.md` keeps a header note pointing there.

- **Resolved/obsolete** (closed out): claude-code `file_path`, PR1 JSON view
  mode, RepoDetailView, git probe main-thread, git-log `|` separator (Node-only,
  gone), CLI resume (ported to Swift `resumeCommand()`), Ghostty launch,
  regenerate-all titles, displayTitle fallback, displayIndexed/matchIndices
  caching.
- **Confirmed still open**: `git_repos` is never populated — no Swift repo
  discovery, so the Repos/Workspace page is dormant (**High**); auto-title on
  indexing not wired (`generated_title` stays NULL); `SearchView` semantic-mode
  toggle is a false promise (product search is keyword-only, no sqlite-vec);
  plus low-priority UI/perf polish (transcript copy actions, tool-name labels,
  column-visibility toggle UI, `@AppStorage` persistence, service-layer
  `ISO8601DateFormatter` reuse).
- **Investigate**: PR5 usage probes — UI/plumbing exist, but whether real
  Claude-OAuth / Codex-tmux data flows is unconfirmed.
- Hygiene: `.superpowers/` brainstorm artifacts (44 tracked files) untracked and
  gitignored; `.claude/` runtime artifacts (`scheduled_tasks.lock`, `worktrees/`,
  `settings.local.json`) gitignored.

### Tooling — Claude Code automation hooks (2026-05-23, Claude)

Added `.claude/settings.json` with two project-scoped Claude Code hooks, derived
from running the `claude-automation-recommender` skill (claude-code-setup plugin)
against this codebase:

- **PostToolUse** (`Edit|Write|MultiEdit`): biome `check --write` on edited
  `.ts/.tsx/.js/.jsx` via the project-local `node_modules/.bin/biome`. Complements
  the husky `pre-commit` lint-staged pass by formatting at edit-time, closing the
  edit→commit window where files sit unformatted.
- **PreToolUse** (`Edit|Write|MultiEdit`): block (`exit 2`) edits to generated /
  locked artifacts — `package-lock.json`, `dist/**`, `test-fixtures/**` — with a
  message pointing at the `generate:*` npm scripts.

Both validated via simulated hook payloads (block paths, allow src, format TS,
skip non-JS). Hooks **fail-open** if `jq` is absent (protection silently disabled,
never a false block). Hooks load at session startup, not in already-open sessions.

### Shipped — Round-6/7 deep review + full remediation (2026-05-22, Claude + Gemini + Codex)

Two adversarial review rounds (17 Opus subagents) + cross-provider validation
(Gemini 3.1 Pro and Codex/GPT-5.x independently confirmed the critical findings;
Codex also caught one over-statement and one new bug — SEC-H3). Then completely
remediated via 4 parallel worktree agents + a sequential integration/SST pass,
merged to `main` (`286093f9..63d2b800`). See `docs/reviews/2026-05-22-FINAL-report.md`
and `docs/reviews/2026-05-22-remediation-closeout.md`.

Headline fixes (all behavioral + security + correctness landed; 384 framework
tests green, app build SUCCEEDED):
- **Composition root (P0)**: the running `EngramService` never wrote FTS content
  nor called `migrate()`/`runInitialScan` — new sessions were unsearchable and a
  fresh install produced a permanently empty DB. Wired `IndexJobRunner` (FTS
  drain + content build), migrate + startup backfills + fresh-machine fail-fast.
- **Security**: web UI now opt-in + token + Host/Origin + redaction (was always-on
  unauthenticated, unredacted, DNS-rebindable); `project_move` path-confined;
  peer-cred + capability token on destructive commands; `Library/Keychains` guard
  fixed; socket `chmod 0600`.
- **IPC**: accept() errno handling; snippet truncation + frame-cap symmetry;
  real request-id on error.
- **Write path / read adapters**: datetime window, change-count, cascade tier
  reset, reconcile guard; CascadeDiscovery pipe deadlock; Antigravity cwd no
  longer fabricated; WatchPathRules key.
- **UI/observability**: 12 views off the main thread; observability views read
  `OSLogStore`; index errors surfaced; real a11y; dead controls removed.
- **Release**: no more un-notarizable ditto fallback; bundle-hygiene + Hardened
  Runtime + version + deploy + CI gates; CLAUDE.md falsehoods corrected.
- **Tiering**: Swift `SessionTier` parity with TS (probe/noise) + first tests.

Deferred (rationale in closeout): SST full classifier/scoring consolidation
(refactor, not a bug); service-side `.degraded` SLA (app-side already covers);
P3 cross-validation omissions (WAL `-shm`/App Nap/JSON memory/UI refresh —
unverified); advertised-but-inert features removed from UI rather than built.

### Shipped — EngramUITests fully restored (2026-05-22, Claude + Codex)

Building on the data-loading fix (18 → 7), the remaining 7 UI failures are now
fixed and **EngramUITests is fully green (0 failures)**. Root causes:
- XCUITest's `descendants(matching: .any)` id lookups forced a ~1600-deep AX
  snapshot that stack-overflowed the app on macOS 26.5. Replaced with typed
  collection queries (`button(id:)`/`group(id:)`/`scrollView(id:)`) in the
  UITest helpers/screens. (Codex.)
- SwiftUI's accessibility merge heuristic collapsed two containers (the
  `SidebarFooter` HStack with its decorative divider, and the `home_dailyChart`
  VStack), hiding the Settings/Theme footer buttons and the
  `home_sourceDistribution` legend. Fixed with
  `.accessibilityElement(children: .contain)` on both — additive a11y only, no
  layout/behavior change. (Codex + Claude.)

Verified: full `EngramUITests` green; `EngramCoreTests` + `EngramTests` green;
no change to `npm test` (1395) or the service/MCP suites. The diagnosis is
summarized in this changelog entry.

### Shipped — round-5 fresh-angle remediation (2026-05-22)

Round-4 closed the known P0/P1 set; a fresh 6-angle scan then found 61 new
issues (3 P0, 21 P1, 37 P2) that the prior session recorded but never fixed.
All 61 are addressed here, with tests added wherever the path
is reachable from the test targets. Green: `npm test` 1395 ✓, `biome` clean,
Swift `Engram` + `EngramServiceCore` (44) + `EngramMCPTests` (46) all ✓.
(EngramUITests are environment-dependent — they need a seeded GUI session and
fail identically on the round-4 base commit; out of scope here.)

TypeScript dev/reference:
- Snapshot write window: `applyParentLink` + `writeExtractedData` folded into
  the snapshot transaction so a mid-write crash can't leave cost/tool/parent
  data half-applied; `metricsRepo.upsertSessionCost` persists NULL (not "") for
  an unknown model to match the Swift writer (schema source of truth).
- project-move SIGINT handler installed before lock acquisition (+ownsLock
  guard); `upsertInsight` dual-write wrapped in a transaction; orphan scan
  honours a shutdown AbortSignal; `backfillScores` reads inside its txn;
  `MetricsCollector.flush` re-queues on failure instead of dropping.
- Adapters: codex `startTime` mtime fallback; codex counts a tool use once
  (function_call only); 5 adapters' `readLines` get try/finally (fd leak);
  kimi epoch guard; gemini originator case-insensitive; cline cwd anchors on
  `) Files`; opencode `::` right-split; windsurf surfaces Cascade cwd; kimi
  sessionId validation; `_truncate` drops trailing lone low-surrogate; vscode
  streamed first-line read.
- Tools/HTTP/MCP: `/api/link-sessions` + `/api/handoff` $HOME-confined;
  `hide_session` parameterized (no SQL interpolation); bounded message loading
  for summary/export/web (DoS); YAML batch size + alias-bomb cap; cooperative
  MCP cancellation; `deleteInsight` returns the real result; `source_session_id`
  validated; `/api/log` + `project_move` note size caps.

Swift product runtime:
- Concurrency: `SessionWatcher` pending dict guarded by a lock; `SwiftIndexer`
  no longer holds a GRDB handle across an await; `StreamingLineReader` failures
  lock-guarded; immutable adapters / GRDB wrappers / service client conform to
  `Sendable` (dropped unnecessary `@unchecked`); `MockEngramServiceClient` made
  immutable.
- Service: final WAL checkpoint on graceful shutdown; `ServiceWriterGate` write
  wait gains a timeout (a wedged write no longer blocks the queue forever);
  transcript reader/exporter no longer bridge async→sync via DispatchSemaphore;
  `EngramWebUIServer` opens read-only + deterministic close; launcher
  `stopProcessOnly` bounded-waits for exit + exponential backoff health probe;
  search `mode` honoured (semantic degrades to keyword with a warning);
  FTS/SQL query syntax errors classified `retryPolicy: "never"` across the
  IPC search path (matches the real "unterminated string"/"no such column"
  fts5 messages, not just "syntax error"/"fts5").
- UI: expand chevron is a Button (VoiceOver); hidden shortcut buttons
  accessibility-hidden; search/loadParentInfo tasks tracked + cancelled on
  disappear; skeleton respects reduce-motion; "Copied" tasks cancellable;
  ContentSegment NSCaches get a totalCostLimit.
- Adapter parity realigned to TS (codex single tool count, cline `) Files`
  anchor, windsurf cwd) with goldens regenerated.

Out-of-R5 fixes folded in to get a fully green suite (verified pre-existing on
the round-4 base commit, not regressions):
- `testPingHealthProbeSessionsAreSkipped` asserted `.lite` for a "ping" probe
  that is correctly `.skip` — corrected the stale assertion.
- `handoff` MCP output: Swift had drifted from the Node parity contract by
  emitting extra `sessions`/`project` fields (R4); reverted to the documented
  `{brief, sessionCount}` contract (the brief text already lists the sessions).

### Shipped — DeepSeek round-4 cross-layer remediation (2026-05-22)

Round-3 confirmed P0 100% but deferred P1/P2; round-4 found the **Swift
product runtime carried copies of the same bugs fixed in TS dev tooling**.
Since Swift is the shipped runtime (TS is reference/fixtures), these product
reproductions were the higher priority. All green: `npm test` 1351 ✓,
`xcodebuild test` 199 ✓ (incl. AdapterParityTests), lint clean, build ✓.

- **P1-24 (Gemini-authored, reviewed + kept)** — all remaining `DatabaseManager`
  read methods marked `nonisolated` + routed through `readInBackground`, plus
  `tableExists` nonisolated. Verified: compiles, consistent with existing
  convention, builds on top of the round-3 nil-fallback fixes.
- **Swift CJK LIKE injection (cross-layer of TS P1-1)** — escaped `% _ \` and
  added `ESCAPE '\'` in all three Swift fallback paths:
  `EngramServiceReadProvider.search`, `DatabaseManager.search`,
  `MCPDatabase.searchInsightsFTS`. Also fixed a pre-existing broken
  `ESCAPE '\\'` (two-backslash → SQLite "must be single character" runtime
  error) in `MCPDatabase` tool-analytics project filter.
- **Swift CursorAdapter sizeBytes (cross-layer of TS P0-7)** — per-session
  bytes (composer JSON + raw bubble-row JSON) instead of whole `state.vscdb`
  size; aligned **byte-for-byte** with the TS adapter. OpenCode TS adapter
  re-aligned to `SUM(length(message.data)) + SUM(length(part.data))` to match
  the Swift adapter. Parity golden fixtures regenerated (cursor 12288→382,
  opencode 197).
- **Swift CommandCodeAdapter system injection (cross-layer of TS NEW-2)** —
  added `isSystemInjection` (9 Claude-style wrappers) so injected wrappers are
  counted as system, not user; mirrors the TS commandcode fix for parity.
- **Swift crash hardening** — `ToolCallParser` regex compiled via
  precondition (was `try?` silently disabling ALL tool-call parsing);
  `EngramWebUIServer` adapter map built with a loop (was
  `Dictionary(uniqueKeysWithValues:)` — same P0-14 crash class);
  `MCPConfig` dropped dead `daemonBaseURL`/`bearerToken` and the
  force-unwrapped `URL(string:)!` (HTTP daemon is gone from the product path).
- **TS adapters** — `commandcode.ts` gained `isSystemInjection` +
  `systemMessageCount` tracking + file-mtime startTime fallback; remaining raw
  `JSON.stringify().slice()` in `commandcode`/`antigravity`/`qoder` routed
  through `truncateJSON`/`truncateString`.
- **Tests added** — `commandcode.test.ts` covers injection classification +
  mtime fallback; Swift `AdapterParityTests` now exercises the aligned
  cursor/opencode sizeBytes.

Still open from round-4 (documented, non-blocking sweep): TS P1-5/6/7
(COALESCE authority, cache-token sync, title PII), several Swift UI P1s
(MessageParser semaphore, Theme scroll timing), and the remaining new P2/P3
findings (chunker step<=0 guard, config error distinction, gemini-cli endTime,
duplicate ISO8601 formatters).

### Shipped — DeepSeek round-3 review remediation (2026-05-21)

P0 / P1 / select P2 fixes from `review-round3-confirmed.md` (Codex 6-agent
round-3 audit, 121 confirmed findings). Test/lint/build all green:
`npm test` 1347 ✓, `npm run lint` clean, `xcodebuild Engram` succeeds.

- **Swift P0** — `Database.listGitRepos` and `Row.fetchOne!` sites gained
  `guard let pool` / nil-row fallbacks; `AdapterRegistry.init` no longer
  crashes on duplicate `SourceName` keys (first registration wins);
  `MCPTranscriptTools.handoff` actually renders the recent-session list it
  fetches; `MCPStdioServer.run()` is now async over `FileHandle.bytes.lines`
  with no DispatchSemaphore (`main.swift` uses Task + dispatchMain).
- **Swift P1** — `UnixSocketEngramServiceTransport.send` wraps the detached
  I/O task with a cancellation handler that `shutdown(2)`s the fd to release
  the leak window; `StreamingLineReader` now closes its FileHandle via a
  HandleHolder so callers that `.prefix(...)` or `break` don't leak fds;
  `OrderedJSON.quotedJSONString` falls back to a manual JSON escaper on bad
  UTF-8 instead of crashing the MCP stdio process with `try!`.
- **Swift P2** — `ParentDetection.compile` reports which regex failed instead
  of bare `try!`; `MainWindowView` drops dead `searchQuery` / `performSearch`.
- **TypeScript P0** — FTS-version reset is wrapped in BEGIN IMMEDIATE/COMMIT
  so a mid-reset crash no longer wipes FTS on every restart;
  `upsertAuthoritativeSnapshot` preserves NULL tier from sync peers (so
  `backfillTiers` re-evaluates) instead of coercing to 'normal';
  `Indexer.indexFile` adds the same `isIndexed(filePath, fileSize)` fast-skip
  that `indexAll` already had — watcher events on hot files no longer cause
  full re-parse / FTS churn; `backfillCosts`'s 50 ms rate-limit moved into a
  `finally` so the no-filePath / no-adapter fast paths can't stampede SQLite;
  `runPostMigrationBackfill` reconciles `sessions.hidden_at` →
  `session_local_state.hidden_at` on every startup, and `hide_session`
  writes both tables in a transaction so sync peers see the hide;
  OpenCode and Cursor `sizeBytes` now reflect per-session payload bytes
  instead of the whole shared SQLite file; Antigravity / Windsurf
  `readFirstLine` is streamed instead of `readFile`-then-split (no more
  multi-MB load to read one line); Codex `extractText` skips
  non-text-bearing content blocks and `isSystemInjection` matches all five
  missing Claude-style wrappers; Codex `session_meta` rows without a string
  `id` are rejected.
- **TypeScript P1** — CJK LIKE fallback in `searchSessions` and
  `searchInsightsFts` now escapes `% _ \` and uses `ESCAPE '\\'`; the
  fts-syntax retry is gated on `isFtsSyntaxError` so DB lock / I/O errors
  propagate; `searchSessionsLike` replaces the non-portable
  GROUP-BY-non-aggregated-columns shape with a per-session MIN(rowid)
  subquery; `countSessions` honors `includeOrphans`; `get_session`
  streams-and-windows messages by page instead of buffering all of them;
  Codex `function_call(_output)` truncation goes through
  `truncateJSON`/`truncateString` so `null` no longer leaks as the literal
  string "null" and a slice cannot strand a UTF-16 surrogate; OpenCode
  sets `endTime` even on single-message sessions; `backfillParentLinks`,
  `backfillCodexOriginator`, and `backfillSuggestedParents` now page
  through their LIMIT 500 candidates instead of silently skipping the
  rest.
- **TypeScript P2** — `searchSessions` project filter is now an exact
  match on resolved alias names (no more `engram` matching
  `engram-tools`); `save_insight` defers `randomUUID()` until after dedup
  so the common duplicate path doesn't waste crypto work; `KimiAdapter`
  caches the parsed `kimi.json` keyed by mtime so a 50-session indexing
  pass reads the file once.
- **Tests added** — `tests/adapters/codex.test.ts` covers the new
  extractText / injection behavior; `tests/adapters/opencode.test.ts`
  asserts per-session `sizeBytes < statSync(dbFile).size`;
  `tests/core/maintenance.test.ts` covers `runPostMigrationBackfill`
  reconciling hidden_at in both directions.

Remaining P1 / P2 follow-ups documented in `review-round3-confirmed.md`
(e.g. P1-24 Swift `nonisolated` audit, P1-32 reader-WAL doc, P1-33
SQLITE_BUSY retry on OpenCodeAdapter, P2-31 shared ISO8601 formatter).
None block product behavior; addressing them is a sweep pass.



- **27 项 review finding 全部收口** —— 基于 `docs/superpowers/reports/2026-05-20-engram-review-findings.md` 的 Codex 多子 agent 审计 + Gemini 线索复核,完成 Swift service/db/IPC、Node dev tooling、文档/UI 承诺、MCP 工具、Web route 拆分、安全权限、provider parser/display parity 的整轮修复。最终证据写入 `docs/superpowers/reports/2026-05-20-engram-review-resolution.md`。
- **Provider parser parity 变成发布门禁** —— `tests/fixtures/adapter-parity/**` 作为 Swift product adapter 与 TypeScript dev/reference tooling 的 golden corpus。当前 fixture gate 覆盖 15 个独立 provider:Antigravity CLI、Claude Code、Cline、Codex CLI、Command Code、GitHub Copilot、Cursor、Gemini CLI、iflow、Kimi、OpenCode、Qoder、Qwen Code、VS Code Copilot、Windsurf。MiniMax / Lobster AI 作为 Claude-compatible derived source 继续走 Claude parser,但以独立 source 入库。
- **Antigravity CLI / Command Code / Qoder 重点修复** —— Antigravity CLI 新增 `~/.gemini/antigravity-cli/brain/` transcript 支持并保留 legacy cache mapping;Command Code 覆盖 `tool-call.input` / `tool-call.args`;Qoder 覆盖 nested `subagents/` parent detection,同时避免 project-level `subagents/` 目录被误判为 parent。
- **HTTP / Swift / MCP / export 显示契约统一** —— Swift App、Swift MCP、Swift Service export、Swift HTTP transcript endpoint 只返回非空 `user` / `assistant` 正文。tool/system/event/subagent notification 行保留给索引、统计和诊断,不混入普通对话气泡。相关 Command Code tool row、blank/whitespace assistant、Antigravity legacy-source 读取都有 Swift/Node 回归测试。
- **两轮 Polycli review 吸收完毕** —— 可用 provider 为 `gemini`、`claude`、`copilot`、`minimax`、`cmd`、`agy`。第二轮实质修复包括 Qoder `/Users` 外 parent detection、MCP/export 空白 transcript 过滤、blank assistant stats/noop cost metadata refresh,以及 Xcode project worktree-name 泄漏。记录见 `docs/verification/provider-parser-parity-2026-05-20.md`。
- **最终 ship 验证**:`npm run check:adapter-parity-fixtures` ✓;目标 Antigravity/Command Code/Qoder + web/API tests 6 files / 115 tests ✓;完整 `npm test` 120 files / 1342 tests ✓;`npm run typecheck:test` ✓;`npm run knip` ✓;`npm run build` ✓;`npm audit --audit-level=high --json` 0 high/critical ✓;Swift AdapterParity / MCP source-schema+transcript / ServiceCore HTTP+export parity 选测 ✓。`macos/scripts/build-release.sh` archive 成功,本机 Developer-ID exportOptions 限制触发后使用 signed archive fallback;`/Applications/Engram.app` 已替换,codesign 通过,`Engram` / `EngramService` / `EngramMCP` 均运行。
- **Git/发布线清理** —— 本地与远端最终只保留 `main`。由于旧 `origin/main` 与当前本地 `main` 无共同祖先,先检查并尝试普通推送/compare/集成 merge,确认不可行后用 `--force-with-lease` 将 `origin/main` 更新到 `83f096c3 fix: harden provider parser parity`;随后删除临时 `codex/*`、backup、`public-main` 远端分支和所有本地旧分支/worktree。

### Fixed — Recent indexing covers updated Claude sessions (2026-05-10)

- **Claude 今日会话不再漏入库** —— `EngramService` 的 recent indexing 之前实际只走 `SessionAdapterFactory.recentCodexAdapters()`,导致持续写入的 `~/.claude/projects/*.jsonl` 不会被服务周期扫描捞进索引。现在 `indexRecentSessions()` 默认使用 `recentActiveAdapters()`:Codex 继续按近两天日期目录扫,Claude/Gemini/OpenCode/Cursor/Qwen/Kimi/Cline/VS Code/Windsurf/Antigravity/Copilot 等文件型来源按 backing file mtime 过滤最近活跃 locator。OpenCode `db.sqlite::sessionId` 和 Cursor `db.sqlite?composer=...` 这类虚拟 locator 会先解析回实际 DB 文件再取 mtime。
- **服务扫描节奏调整**:`EngramServiceRunner` 启动后立即扫一次,之后每 5 分钟扫最近活跃来源。Release 重新部署到 `/Applications/Engram.app` 后,实测 `/Users/bing/.claude/projects/-Users-bing--NetWork--Safeline/00bca506-271f-4f5c-92b4-c8e088696aae.jsonl` 已入 `~/.engram/index.sqlite`: `source=claude-code`, `project=Safeline`, `message_count=1250`, `indexed_at=2026-05-10T15:25:39Z`;`EngramMCP get_session` 可读 transcript。
- **验证**:`IndexerParityTests` 16/16 通过;`EngramService` build 通过;Release `Engram` build 通过;`codesign --verify --deep --strict /Applications/Engram.app` 通过;bundle 未包含 Node runtime 残留。

### Fixed — Session detail keeps transcript visible with many agent children (2026-05-09)

- **Agent Sessions 不再挤没正文可视区** —— `SessionDetailView` 的子 agent 列表改成默认折叠标题行;展开后列表有独立滚动区域并限制最大高度。含几十条 Polycli/qwen/kimi/pi/copilot 子会话的父会话不再把 transcript 视口压到不可用。

### Fixed — Swift-only cutover removes stale Node schema compat gate (2026-05-08)

- **丢掉旧 Node schema 兼容门禁** —— 删除 `scripts/db/check-swift-schema-compat.ts`、对应 `tests/scripts/check-swift-schema-compat.test.ts`,并从 `.github/workflows/test.yml` 的 `swift-unit` job 后移除 `Check Swift/Node schema compatibility` step。这个 gate 是 Stage 0-4 迁移期护栏,现在会反向要求 Swift schema 迎合旧 TypeScript `src/core/db.ts` 默认值(本次暴露为 `sessions.indexed_at` 的 `''` vs `datetime('now')` drift),不再是 Swift-only 单栈的正确验收条件。
- **边界澄清**:删的是旧 Node 兼容护栏,不是 npm/TypeScript 开发与 fixture 工具链。当前活跃入口已无 `check-swift-schema-compat` 引用;`npm run test` 112 files / 1272 tests 通过,`npm run build` 通过。
- **下一步开发基线补齐**:`CLAUDE.md` 改成 Swift `EngramService`/`EngramMCP` 为产品路径、TypeScript 为 dev/reference/fixture;`docs/verification/swift-single-stack-stage5.md`、`docs/swift-single-stack/daemon-client-map.md`、`docs/swift-single-stack/file-disposition.md` 和 `.memory` 同步当前状态:project migration 已是 Swift service pipeline,旧 Node schema gate 不再是当前 CI/验收条件,Polycli provider 噪声识别从 Swift adapter/indexer/backfill 层继续维护。

### Shipped — Adapter parser hardening via 3-way review + 2 codex follow-ups (2026-04-28)

- **4 commit 闭环修补 14 个 session adapter** —— 起因是用户问"所有解析器是否都能正确解析 AI sessions 内容"。流程:并行 3-way 静态 review(Claude general-purpose + Codex/GPT + Gemini→挂→Qwen→挂)+ 主对话覆盖度审查 + 真实 `~/.claude` `~/.codex` 数据 cross-check → 13 P1/P2 ship → Codex review 出 3 medium + 1 low → 修 → 再 review 出 3 partial + 1 low + 6 gaps → 再修。最终 `1206 → 1244` tests, biome clean。
  - **`b27af8d`** — 13 parser fixes:
    - codex 4 条:`model` 取自 `response_item.payload.model`(非 `model_provider`,真实数据 `~/.codex/sessions/.../rollout-*.jsonl` 的 `model="gpt-5.3-codex"` 而 `model_provider="openai"`);`lastTimestamp` 任何 ts 行都更新(不止 message payload);`function_call`/`function_call_output` 现在计入 `toolMessageCount` + stream yield `role='tool'`(之前完全丢弃);assistant `payload.usage` 映射到 `Message.usage`。
    - claude-code:`tool_result` 顶层 `type='user'` 的行 yield `role='tool'`(之前 stream 标 user 与 `toolMessageCount` 不一致);引入 `MESSAGE_TYPES Set` 显式登记,sessionId 在 filter 前抓(适配真实数据演进出的 5 类新 type:`attachment` / `queue-operation` / `permission-mode` / `last-prompt` / `file-history-snapshot`)。
    - cline 加 `modelInfo.modelId` 提取;iflow 加 `message.model` 提取;qwen `message.model` fallback;qwen/iflow `extractContent` 改 `parts.join('\n')` 与 gemini-cli 对齐(多 part 不再丢)。
    - kimi `streamMessages` 现在带 timestamp(line ts 优先,否则按 wire turn 配对);`startTime` 兜底 mtime 前先扫 line ts。
    - vscode `assistantMessageCount` 用真实 `extractAssistantText` 非空数(非 1:1 padding);`cwd` 从 `workspaceStorage/<hash>/workspace.json` 读 `folder`/`configuration` URI(配合 `.code-workspace` 多根解析)。
    - cursor `cwd` 从 `composerData.context.folderSelections`/`fileSelections` heuristic 推断(真实 Cursor 不绑 workspace,best-effort)。
    - windsurf/antigravity `readLines` `try/finally` close + destroy(防 fd 泄漏);`JSON.parse(firstLine)` 二级 try。
    - copilot YAML value 剥引号配对。
  - **`f8d7109`** — codex review #1 闭环 3 medium + 1 low:kimi `readTurnTimestamps` 改返 `{begin, end?}[]` paired turns(原独立数组在 TurnEnd 缺失时位移整个尾段);vscode multi-root `.code-workspace` 真解析 `folders[0].path`(原代码把 `.code-workspace` 路径直接当 cwd);claude-code 加 `!startTime` 守卫防 metadata-only 文件污染索引;`readTimestamps` 合并到 `readTurnTimestamps` 排除心跳/元数据。
  - **`fbbc504`** — 测试覆盖 + 顺手修 vscode 2 个 URI bug:`file://localhost/path` 把 localhost 算进路径;`vscode-remote://`、`vsls://` 等非 file URI 被原样当 cwd。`decodeFileUri` 现在严格只接受 `file://`,strip `localhost/` authority,malformed percent-encoding 走 catch 返空。补 codex `function_call` 边界 / kimi 无 wire fallback / vscode workspace.json 边界 / cursor 空 folder 回退 / qwen+iflow 多 part join 共 14 条测试。
  - **`2fa2a2a`** — codex review #2 闭环 3 partial + 4 gaps:kimi `turnIdx` 状态机重写 —— 由 `lastRole` 比较改成 binding-state(`userBoundInTurn`/`asstBoundInTurn`),user 推进当前 turn 任意 slot 已绑定,assistant 仅推进自己 slot 已绑定,handles `u-u-a` / `u-a-a` / `u-a-a-u` 全部正确;vscode `.code-workspace` 现在也接 `{uri: "file://..."}` 形式 folder(非仅 `{path}`)+ Windows-style `file:///C%3A/...` 解码测试;claude-code `startTime` guard 改 `totalMessages > 0`,fallback 到 `fileStat.mtimeMs`(原 guard 误丢无 timestamp 但有有效消息的合法文件);补 codex 重复 `function_call` 不去重 / cursor `folderSelections[1]` 不被扫(fall through 到 file)/ cursor symlink 不 realpath 三条断言现状的测试。
- **覆盖度审查独家发现**(主对话从 user 真实 `~/.claude/projects/-Users-bing--Code--ShortcutRadar/...jsonl` 头 200 行抓):claude-code 已演进出 5 类新 record type(`attachment` 10 行 / `queue-operation` 9 / `permission-mode` 6 / `last-prompt` 5 / `file-history-snapshot` 1),adapter 当前显式过滤为非消息 type;5 个 adapter fixture 自 2026-02-27 起未刷新(60+ 天):antigravity / cline / cursor / vscode / windsurf,留作后续独立 task。
- **3-way review 实战观察**:Gemini(`gemini-3.1-pro-preview` HTTP 429 capacity exhausted)和 Qwen(max session turns)两次第三路都失败,主对话兼任第三 reviewer + 用真实数据实证修补;Claude general-purpose 报 14 finding、Codex 报 7 finding,重叠率仅 1 条(kimi timestamp),说明跨模型 review 高互补。`feedback_agent_review_verify_before_trust` memory 的 ~45% 误报率经验在本次再次成立 —— 每条 P0/P1 都独立 Read 源文件 + 用真实 user data cross-check 才接纳。

### Shipped — project_move pipeline port to Swift (2026-04-28)

- **MCP behavioural gap closed** —— `project_move` / `project_archive` / `project_undo` / `project_move_batch` 4 个工具从 Swift `EngramMCP` 跑直达 `EngramService` 原生 pipeline,不再 throw `unsupportedNativeCommand`。MCP `tools/list` 工具数 22 → 26。覆盖 `src/core/project-move/` 全部 16 模块 + `src/tools/project.ts` handler 半部 = ~3,455 行 Node port 到 Swift,分 6 commits ship(`9b9233e`/`65d0e97`/`0d6db00`/`d00593a`/`281b687`/`d4ecb9b`):
  - **Stage 4.1** — `MigrationLogStore.swift` (write half) + `MigrationLogReaders.swift` (GRDB-backed read half),三相状态机 startMigration → markFsDone → applyMigrationDb → finishMigration + watcher 守门 + stale 清理。`applyMigrationDb` 用 `:old`/`:new` 命名占位符 + `pathMatch`/`rewrite` SQL helper(避免按位置塞 33 个参数),substr boundary check 防 LIKE 通配符泄漏。Stage 3 协议 `MigrationLogReader` / `SessionByIdReader` 加 `throws`(GRDB 错误不能静默吞)。+16 测试。
  - **Stage 4.2** — `Orchestrator.swift` 7 步 pipeline + LIFO compensation,~700 行单文件。`URL.standardizedFileURL.path` 做 path canonicalize(对齐 Node `path.resolve`,纯 lexical 不解 symlink);`realpath(3)` 在 APFS 大小写不敏感场景区分真碰撞 vs 大小写改名;`withTaskGroup` bounded concurrency(50 worker)patch JSONL;FS 工作不持写事务(每个 `writer.write {}` 即开即关)。SIGINT handler 故意未 port —— launchd helper 无 controlling terminal;`cleanupStaleMigrations` 启动时清理崩溃残留。+10 集成测试(validation / dry-run / happy path / DirCollision / LockBusy / 多源)。
  - **Stage 4.3** — `Archive.swift` 4 条建议规则(YYYYMMDD 前缀 → 历史脚本 / 空 or README → 空项目 / .git+content → 归档完成 / 否则 ambiguous 让用户指定)+ `ArchiveCategory` 枚举(原始 CJK 值)+ aliases 表(`historical-scripts` / `archived-done` 等英文别名也归一到 CJK),Round-4 critical fix 保留:HTTP 层不再因为穿英文别名而创出英文目录。+16 测试。
  - **Stage 4.4** — `Batch.swift` JSON-only(无 Yams SwiftPM 依赖,Swift MCP boundary 本就 JSON);schema v1 严格 parser(version、ops、`dst|archive` XOR、`continue_from` 拒绝)+ runner(`stopOnError` 默认 true、`~/foo` 经 override home 展开、archive ops 自动建 `_archive/<category>/` 父目录)。+14 测试。
  - **Stage 4.5** — `MCPToolRegistry.unavailableNativeProjectOperationTools` 清空,4 个工具走标准 `serviceUnavailable` 路径(operational category)。`mcp-golden/tools.json` 22 → 26;`mcp-golden/initialize.result.json` instructions 同步;`ServiceUnavailableMutatingToolTests` 4 个 `*IsUnavailableInSwiftOnlyRuntime` 重命名为 `*FailsClosedWithoutServiceSocket` 翻测断言。
  - **Stage 4.6** — `EngramServiceCommandHandler` 4 个 `unsupportedNativeCommand` stub 替换为真 pipeline 调用:`projectMove → Orchestrator.run`;`projectArchive → Archive.suggestTarget + Orchestrator.run(archived: true)` + 自动建 `_archive/<category>/` 父目录;`projectUndo → UndoMigration.prepareReverseRequest + Orchestrator.run(rolledBackOf:)`;`projectMoveBatch → Batch.parseJSON + Batch.run`,`yaml` 字段名保留(IPC 兼容),内容改 JSON。`mapPipelineResult` helper 把 `PipelineResult` 翻成 `EngramServiceProjectMoveResult`。`testProjectMigrationCommandsFailClosedWithoutLegacyBridge` 重写为 `testProjectMigrationCommandsSurfacePipelineErrors`(断 commands 走到 pipeline,not UnsupportedNative)。
- **UI gate flip** —— `ProjectMoveServiceError.swift` `nativeProjectMigrationCommandsEnabled = false → true`;ProjectsView + RenameSheet/ArchiveSheet/UndoSheet 13 处 gate 重新激活。
- **测试矩阵全绿**:`EngramCoreTests` 231(+40 新)/ `EngramServiceCore` 22 / `EngramMCPTests` 39。`ArchiveError` 加 `LocalizedError`(避免 migration_log error 列吞成 generic Cocoa 字符串)。
- **设计决策记录**:
  - **`ProjectMoveError` 协议**做 Node 动态 `err.name` 反射的 Swift 替代;每个具体错误(`LockBusyError` / `DirCollisionError` / `SharedEncodingCollisionError` / `UndoNotAllowedError` / `UndoStaleError` / `InvalidUtf8Error` / `ConcurrentModificationError`)都实现 `errorName` / `errorMessage` / `errorDetails`,`RetryPolicyClassifier` switch on errorName。
  - **mtime-CAS race test 推迟**(`testConcurrentModificationErrorContractFields` 只断错误类型契约,full path 在 orchestrator 集成测试中走过)。Foundation 同步 API 难 deterministic 驱动 Node `queueMicrotask` 的双 stat race。
  - **`SecRandomCopyBytes` 避用** —— `arc4random_buf` 覆盖 temp 名随机性,免 `Security.framework` import。
  - **每个 `MigrationLogStore` 写操作独立 `pool.write {}`** —— 避免 orchestrator 长跑(数十 GB 跨卷复制)期间持写事务阻塞其他 service write 命令。

### Shipped — MCP cutover Node→Swift + observability hardening (2026-04-28)

- **Node MCP 路径退役** — `~/.codex/config.toml` 和 `~/.claude.json` 的 `mcp_servers.engram` / `mcpServers.engram` 切到 `/Applications/Engram.app/Contents/Helpers/EngramMCP`(Swift 原生)。Swift MCP helper 自 commit `46814f9` 起就 ship 了但默认未启用,客户端配置才是真正的 cutover。Node `dist/index.js` 保留作 fallback,生产路径不再 spawn。诊断显示 chokidar 4.x 在 macOS 上非递归监视产生 ~17,727 FSWatcher handle/进程,`process.exit(0)` 在 17K handle teardown 期间挂住导致 SIGTERM 无效退出 — Codex.app spawn-per-tool-call 模式累积出 13 GB 僵尸内存。切换后 RAM 13 GB → 100 MB(单进程 ~470 MB → ~11 MB,~26×)。
- **EngramService 接 os_log**(`74b934a`):新增 `ServiceLogger`(`com.engram.service` subsystem,5 个 category)。之前 `EngramServiceLauncher.drain(pipe:)` 把子进程 stdout/stderr 路由到主 app `EngramLogger.daemon` 的链路在生产无声 4 天 — 改为 Service 进程**直接**走 os_log,不再依赖父 drain。`log show --predicate 'subsystem == "com.engram.service"'` 现可直接用。
- **启动 WAL TRUNCATE**(`74b934a` → `4cc7a34` → `2807259` 三轮修):`PRAGMA wal_checkpoint(PASSIVE)` 永远不收缩 WAL 文件磁盘大小,生产 WAL 4 天累积到 144 MB。`EngramServiceRunner.run()` 在 `ready` event 之后启动 fire-and-forget Task 跑 `wal_checkpoint(TRUNCATE)`(必须在 ready 之后,因为 TRUNCATE 触发 writer busy_handler 最坏等 30s 会撞 launcher 5s 健康探针);shutdown 路径 `await truncateTask.value` 而非 `cancel()`(SQLite PRAGMA 不感知 Task 取消)。WAL 144 MB → 0 B。
- **DeprecatedSettings scrub**(`74b934a`):2026-04-13 Viking 代码删除时遗留的 `viking` JSON key + Keychain `vikingApiKey` entry 在 `applicationDidFinishLaunching` 接 `migrateKeysToKeychainIfNeeded()` 后做幂等清理。纯函数 `DeprecatedSettings.scrub(_:)` 抽出便于单测。
- **5 份 stale `.bak` 备份移到 `~/.Trash`**(2026-04-20 zombie-rescue 残留,共 1.7 GB)。
- **Codex 两轮 adversarial review** 全部 adjust 落实:第一轮发现 startup TRUNCATE 同步阻塞 ready 撞 5s 健康检查 + path 用 `.public` 泄漏 + 缺 busy-reader 测试,修了前两个,测试 gap 在 commit message 诚实标注理由(`SQLiteConnectionPolicy.minimumBusyTimeoutMilliseconds = 5000` 强制下限,deterministic 测试需 fork 进程或 30s+ 等待);第二轮发现 Task 创建时序仍靠调度偶然 + cancel 不 await,修齐。
- **测试**:`ServiceWriterGateTests.testCheckpointTruncateShrinksWalAfterPendingWrites`(seed 1,600 INSERT,断言 PASSIVE 后 WAL > 0,TRUNCATE 后 = 0);`DeprecatedSettingsScrubTests` 4 case(scrub + 幂等 + 不动其他 key + keychain 列表完整性)。
- **未做(单开 plan)**:`project_move/project_archive/project_undo/project_move_batch` 4 个 MCP 工具 — `EngramServiceCommandHandler` 4 个 stub 仍 throw `unsupportedNativeCommand`,需要把 `src/core/project-move/` 整个 pipeline(3,455 行 / 16 模块)port 到 Swift,3-5 天扎实工程。

### Shipped — Swift single-stack migration v3 (2026-04-24)

- **Node daemon 全量迁成 Swift 原生 EngramService**(单 commit `6a47273` + 3 轮 review 修复 `6d732ca` → `3e3d45c` → `88d5e01`)。新增 `EngramService` helper(Unix socket IPC)/ `EngramCoreRead` + `EngramCoreWrite` 双模块(read-only 给 App/MCP/CLI,write 仅给 Service)/ `Shared/EngramCore` 12 个 Swift adapter / 27 个 MCP 工具契约保持。Node `src/` 保留作 parity baseline,计划 2026-06-01 前分 3 阶段删除。
- **多 AI 交叉 review(15 路并行 Kimi/MiniMax/Qwen/Gemini/MiMo-via-polycli)+ 人工裁定**,证实第一轮 Explore agent review 有 ~45% 误报(C1/C2/C3/C5/C6/H2/H3)。教训:大规模 review 不能信单轮 agent 的 file:line 断言,必须独立 Read 原文。v2→v3 修复过程与方法论记录在 `docs/swift-single-stack/2026-04-24-review-feedback{,-v2,-v2-followup,-v3}.md`。
- **v3 三轮修复核心**:
  - **Dead Node HTTP 链路清零**(`DaemonClient.swift` -433 / `DaemonHTTPClientCore.swift` -192 / `EngramLogger.forwardToDaemon` -21 / `AppEnvironment.daemonPort` 字段删除),App/MCP/CLI 全部走 Unix socket;`EngramServiceLauncher.drain(pipe:)` 用 `readabilityHandler` 消费 stdout/stderr 防止子进程写阻塞死锁。
  - **IPC 安全加固**:`UnixSocketServiceServer` 的共享 JSONEncoder/Decoder 改 per-request 新建(消除数据竞争);加 `ServiceConnectionLimiter(value: 32)` 并发上限 + 10s socket timeout;frame max length 从 32MB 降到 256KB(X6 防嵌套 DoS);`TranscriptExportService` 3 条正则脱敏(api_key/bearer/sk-/ghp_/xoxb-)+ 写入后 chmod 0600;`linkSessions` 按 source 白名单 + `.ssh`/`.aws`/`.gnupg`/`.kube`/`.docker`/`.1password`/`Keychains` 黑名单防 symlink 攻击。
  - **辅助表 schema 幂等迁移**(`EngramMigrations.migrateAuxTablesToV2`):10 张表(session_tools/session_files/logs/traces/metrics_hourly/alerts/ai_audit_log/git_repos/session_costs/insights)每张都走 `__engram_<t>_v2` shadow + `INSERT ... FROM old` + `columnExpr(..., fallback:)` 逐列兼容 + DROP+RENAME。`logs.source CHECK` 用 `CASE WHEN IN (...)` 防违反值;`traces.span_id` 空则补 `hex(randomblob(16))` UUID;`ai_audit_log.total_tokens` 按 `prompt+completion` 重算。写 `metadata.swift_aux_schema_version=2` 不污染 Node 的 `schema_version`,保留双向兼容。
  - **insights 软删下线**:对齐 Node 当前行为,迁移时 `DELETE FROM insights_fts WHERE insight_id IN (SELECT id FROM insights WHERE deleted_at IS NOT NULL)` 清 FTS,再 `INSERT ... WHERE deleted_at IS NULL` 跳过软删行。
  - **SwiftIndexer 流式化**(`streamSnapshots()` public + `continuation.onTermination = scanTask.cancel()` + `try Task.checkCancellation()`),session-level 不再 collect-to-array;`indexAll`/`collectSnapshots` 复用同一流。单文件(如 Gemini JSON 全 load)OOM 是 adapter 内部独立问题,留待后续。
  - **测试**:`MigrationRunnerTests.testMigratesLegacyAuxiliaryTablesToCurrentWritableSchema` 预填 v1 schema + 数据 → 跑迁移 → 逐表断言新列可写 + 老列已消;`StartupBackfillTests` 的 quality score 从 magic number 72 改为 `expectedQualityScore(...)` 可计算期望 + codex originator 加反例(`originator="Codex CLI"` 不应触发 `dispatched`);`IndexerParityTests.testIndexAllFlushesSnapshotsInBoundedBatches` 断言 205 session / batchSize 100 → `[100, 100, 5]`。
- **Project UI 按钮冻结**(`ProjectMoveServiceError.swift` `let nativeProjectMigrationCommandsEnabled = false`):ProjectsView + Archive/Rename/UndoSheet 共 13 处 gate,在 Swift 原生 project migration pipeline port 完前 UI 入口不可见。Service 层对应 `projectMove/projectArchive/projectUndo/projectMoveBatch` 仍抛 `unsupportedNativeCommand`(fail-closed)。
- **CI 门禁**:`.github/workflows/test.yml` swift-unit job 后跑 `scripts/db/check-swift-schema-compat.ts --fixture-root tests/fixtures`,老改 Swift schema 不同步 Node 直接红灯。
- **Stage 5 文档诚实化**:`docs/verification/swift-single-stack-stage4.md` 承认 projectMove 等 "intentionally unavailable until native migration pipeline is ported";`app-write-inventory.md` 从 "Conflict" 改为 "Resolved"。
- **已知未做(不阻塞 ship)**:L-1 JSON 嵌套深度硬检查(Unix socket 仅本用户可达,defense-in-depth,可进安全加固 PR);单文件级 OOM(GeminiCliAdapter.parseSessionInfo 全 load JSON,属 adapter 内部重构)。

### Shipped — Phase C Swift MCP helper (2026-04-23)

- **Native Swift MCP helper bundled into `Engram.app/Contents/Helpers/EngramMCP`**（`macos/EngramMCP/`, `macos/project.yml`, `macos/scripts/copy-mcp-helper.sh`）：26 个 MCP 工具全量 port 到 Swift,读走 GRDB readonly pool,写经 daemon HTTP API (`actor: "mcp"`,strict 模式无 direct-SQLite fallback)。Engram target 声明 `EngramMCP` 为非链接依赖,postbuild 脚本在 Xcode codesign 前把 helper ditto 到 `Contents/Helpers/`,外层签名天然覆盖。Node `dist/index.js` 保留作 fallback;用户改 `.claude/mcp.json` 的 `command` 就能切换(参见 `docs/mcp-swift.md`)。
- **29 个 byte-equivalent contract 测试**(`macos/EngramMCPTests/EngramMCPExecutableTests.swift`):把 helper 作为 subprocess 起,灌 JSON-RPC,断言字节级等同于 check-in 的 `tests/fixtures/mcp-golden/*.json`;写类工具通过 `MockDaemonServer` 拦截 HTTP 流量。Generator (`scripts/gen-mcp-contract-fixtures.ts`) **必须用 `TZ=UTC` 跑**,否则 golden 时间戳按 host TZ 产生 (+8h CST) 而 xctest 在 UTC 下输出,5 个涉及 startTime/endTime 的 golden 会静默偏移 → 已在 generator header 注明。
- **Release 部署 & 回归全绿**:`/Applications/Engram.app` Release 构建含 EngramMCP 10.6M helper,codesign `--validated` Helpers/EngramMCP;EngramMCPTests 29/29 + `npm test` 1210/1210 在 main 上均绿。
- **2 个 MVP 限制曾带标注**(`macos/EngramMCP/MCPStdioServer.swift`):协议版本当时 hardcode `"2025-03-26"`,stdio 异步-同步桥接当时使用 `DispatchSemaphore` —— 后续已在 Swift MCP 合同处理中收口。

### Fixed — monitor/session-repo start_time 字符串格式跨日比较 (2026-04-23)

- **`checkDailyCost` / `checkCostBudget` / `countTodayParentSessions` 4 处 SQL 双侧包 `datetime()` 归一**(`src/core/monitor.ts:141,190,231`, `src/core/db/session-repo.ts:422-423`)。`start_time >= ? AND start_time < ?` 之前做纯字符串 lex 比较,参数来自 `Date.toISOString()`(`"2026-04-22T16:00:00.000Z"`)而 `datetime('now')` 返 `"2026-04-22 22:46:15"`;UTC 日期前缀相同时退化到 char-10 `' '(0x20)` vs `'T'(0x54)`,SQLite 格式行被判更小漏掉。本地 CST 00:00–08:00(UTC 日期与 `startUtcIso` 前缀同步)的 8 小时窗口周期性触发,monitor cost 告警和菜单栏 today-parent 徽章产生假零。
- **回归用例保留不改**:`tests/core/monitor.test.ts` 的 3 个失败用例(用 `datetime('now')` 插 session)恰好暴露此缺陷,是天然的回归守护。
- **索引权衡**:`idx_sessions_start_time` 在这 4 处查询里本就不起决定性作用(均带 JOIN 聚合或复合 filter),`datetime(start_time)` 包裹不可走索引的代价可忽略。

### Fixed — defensive logging + daemon auto-restart (2026-04-22)

- **ai-audit silent catch 除掉**（`src/core/ai-audit.ts`）：constructor prepare / record() / cleanup() 三处 `catch {}` 改成 `console.error('[ai-audit] ...', err)`。daemon stderr 经 IndexerProcess 转发到 os_log（subsystem `com.engram.app`, category `daemon`），Console.app 可见。历史上 audit 写失败纯静默，只有 `return -1` 一个几乎没人查的返回值暴露
- **metrics.flush() 加外层 try/catch**（`src/core/metrics.ts`）：batch INSERT throw 不再 propagate 到 setInterval 的 uncaughtException。失败时 `console.error('[metrics] flush failed, dropped N entries', err)`，buffer 已 `splice(0)` 所以下个周期干净重试
- **IndexerProcess 自动重拉 daemon**（`macos/Engram/Core/IndexerProcess.swift`）：之前 daemon 崩溃 `terminationHandler` 只设 `status = .stopped`，需要用户手动重启 Engram.app 才能恢复。加 `userInitiatedStop` / `restartAttempts` / `restartTask` / `lastStartArgs` 字段 + `scheduleAutoRestart()` 方法：非 user-initiated 退出时 5 秒 backoff 后 `start()`，上限 5 次，稳定 tick（`ready/indexed/rescan/sync_complete/watcher_indexed`）重置计数。实测 `kill daemon-pid` → ~10 秒内新 daemon 在 3457 listen 就绪
- 单测 +2：`tests/core/ai-audit.test.ts` "logs to console.error when record fails" + `tests/core/metrics.test.ts` "does not throw on flush failure and logs the drop"
- **时区陷阱教训**：SQLite `datetime('now')` 返回 UTC，所有 engram ts 列（ai_audit_log、metrics、insights.created_at、sessions.indexed_at、git_repos.probed_at、session_index_jobs）均 UTC ISO-8601。debug 本轮 30 分钟 false alarm "daemon 没写 audit/metrics" 根因就是 `WHERE ts > '2026-04-22T16:00'`（当 CST 写）vs UTC ts 静默对错零匹配。lesson 记在 memory/feedback_timezone_trap.md
- `npm run build` ✓、`npm test` 全过、`xcodebuild` SUCCEEDED、`/Applications/Engram.app` 重部署 + daemon auto-restart 生产实测

### Fixed — 6-way Review Round 3：envelope 统一 + 并发回归测试 (2026-04-22)

- **R3a 并发回归测试**（`tests/web/insight-api.test.ts`）：Kimi Important 指 save_insight dedup→write 有 race。代码审查后结论：**不存在**。text-only 路径里 `findDuplicateInsight` 到 `saveInsightText` 之间没 await，better-sqlite3 同步 + Node 单线程 = 原子。embedded 路径本就不 reject 重复（只 warn），也不是 race 场景。**加一个 concurrent Promise.all 回归测试**钉死这个不变量，未来改动引入异步间隙会立即暴露
- **R3b `/api/insight` 错误 envelope 统一**（`src/web.ts`）：Superpowers Important 指 `/api/insight` 返回 `{error: "string"}`，与 `/api/project/*` 的 `{error: {name, message, retry_policy}}` 不一致。改成统一 envelope：400 validation 走 `validationError('MissingParam'/'InvalidInsight', msg)`、500 server error 用 `{name:'InsightSaveFailed', retry_policy:'safe'}`。两个 insight-api 测试更新为断言 envelope 形状
- **Defer 不修项**（文档化，不在这次改动）：
  - orchestrator dry_run 遇 git-dirty 先抛异常（Gemini Important）—— pre-existing 行为，属于 orchestrator-level UX bug，单独 ticket
  - `mcpStrictSingleWriter` toggle 不热更新（Superpowers）—— UI 帮助文案已声明 "Takes effect on next MCP spawn"
  - Step 4 commit 先于 Step 3 land（Superpowers Nit）—— 历史不重写
  - DELETE with body 在代理下的剥离风险（Kimi Nit）—— loopback 不触发
- `npm run build` ✓、`npx vitest run` **1208/1208** ✓（+1 并发回归测试）、biome 干净

Phase A + Phase B + 6-way review triage **全部完工**。剩下被动观察 24h 锁错误收敛。

### Fixed — 6-way Review Round 2：batch 迁移 + dst 透出 + 声明前置 (2026-04-22)

- **M3 `project_move_batch` 接入 HTTP**（6-way review 发现的 Phase B 漏网第 7 个写工具）：
  - 新增 `POST /api/project/move-batch`（`src/web.ts`）：调 `runBatch(db, doc, {force})`，actor 由 runBatch 内部硬编码为 `'batch'`（符合原有审计语义）
  - MCP dispatch `src/index.ts` `project_move_batch` 改走 HTTP，带 fallback helper
  - 契约测 2 个：缺 yaml → 400 MissingParam、dry-run 完整管道 smoke
  - DB 写工具覆盖从 6/6 升级为 **7/7** ✅（至此 Phase B 真正完整）
- **S2 archive 响应补 `dst`**（`src/tools/project.ts:242, 224` + `src/index.ts:544-553`）：MCP callers（AI agents）原本拿不到归档落地目录。直接路径、dry_run 路径、HTTP 转换路径三处同步加 `dst`，形状对齐（`archive: {category, reason, dst}`）。Swift UI 走的是 `suggestion.dst`，独立字段不受影响
- **S3 `strictSingleWriter` 声明前置**（`src/index.ts:93`）：从 line 412 挪到 `daemonClient` 旁边，消除"先用后声明"的 TDZ 依赖，读起来自然
- `npm run build` ✓、`npx vitest run` **1207/1207** ✓（+2 batch 契约测）、biome 干净
- **需要 daemon 重新部署**：新增 `/api/project/move-batch` 端点

### Fixed — 6-way Review Round 1：安全 + 锁 + fallback 三个 Must-fix (2026-04-22)

6 家独立 review（codex / gemini / kimi / minimax / qwen / superpowers-reviewer）出来的 critical / important 里合并同类项抽了最紧要的三个。

- **M1 撤销 `actor:'mcp'` 的 `$HOME` bypass**（`src/web.ts` 的 /api/project/{move,archive}）：原设计让 actor='mcp' 跳过 $HOME 约束，理由是"MCP 是本地信任对等"。4 家 reviewer 同时标为 Critical：**trust 从不可信 body 字符串派生** —— 任何本地进程都能 POST `{actor:'mcp', src:'/etc/...'}` 绕过。改法：`actor` 字段保留作 audit（已透传到 `migration_log.actor`），但所有 actor 都受 `$HOME` 约束。MCP 调 project_move 本来就在 `~/-Code-/` 之下，不影响正常使用
- **M2 周期 WAL checkpoint 改 `PASSIVE`，启动保留 `TRUNCATE`**（`src/daemon.ts:454`）：原代码周期 `TRUNCATE` 跑在 daemon 主连接上，better-sqlite3 同步 API + 30s `busy_timeout` → 最坏阻塞事件循环 30s。`PASSIVE` 不阻塞，能搬多少搬多少。启动时仍 `TRUNCATE`（此时我们独占 DB）
- **S1 `shouldFallbackToDirect` envelope 判断放宽**（`src/core/daemon-client.ts:155`）：原来只看 `{error:...}`，旧 daemon 返 `{message:...}` 结构 404 会被误判成"端点缺失"静默降级。改成 **任何 JSON object body 的 404/405/501 都 bubble up**，只有 body 为 undefined/字符串才算 Hono 默认的未命中路由
- 测试更新 `project-api.test.ts` `actor:mcp still respects $HOME`（原来测 bypass 存在，现在测 bypass 已撤）+ 3 个新 `shouldFallbackToDirect` 单测覆盖 `{message}` / 空对象 / string-body 分支
- `npm run build` ✓、`npx vitest run` **1205/1205** ✓（+3）、biome 干净

### Added — Phase B Step 6B：mcpStrictSingleWriter 开关上 Swift UI (2026-04-22)

`mcpStrictSingleWriter` 原本只能手改 `~/.engram/settings.json`，现在 Settings → Network 新增 `MCP` GroupBox 里有个 Toggle。

- `macos/Engram/Views/Settings/NetworkSettingsSection.swift` 加 `MCP` GroupBox + `Strict single writer` Toggle
- 走现成的 `readEngramSettings()` / `mutateEngramSettings()`、`isLoadingSettings` 防抖模式（与同文件里的 Sync 设置一致）
- Help text 解释 trade-off：ON = daemon 不可达时 MCP 写直接失败（零锁竞争，依赖 daemon 可用性）、OFF（默认）= 降级到本地直写（resilient）
- 生效时机：下次 MCP spawn（MCP 启动读 `fileSettings` 一次，保留到进程结束）
- `xcodebuild Release` ✓、TS `npm test` **1202/1202** ✓、已部署

Phase A + Phase B **正式全部完工**。剩下 Step 6A 是跑 24h 观察锁错误是否归零——被动的。

### Added — Phase B Step 3：project_* 家族全量迁移，DB 写工具 6/6 ✅ (2026-04-22)

Phase B 最后一块 —— project_move / project_archive / project_undo 全部路由到 daemon。至此所有 DB 写工具（6/6）都走 daemon 单写者。

**端点侧（`src/web.ts`）**：
- `/api/project/{move,archive,undo}` 新增可选 `actor?: 'cli'|'mcp'|'swift-ui'|'batch'` body 字段，默认 `'swift-ui'`。未知值 → `400 InvalidActor`（防审计污染）
- `actor === 'mcp'` → `normalizeHttpPath` 的 `allowOutsideHome: true`：MCP 作为本地信任对等进程，跳过 HTTP 层的 $HOME 防御（MCP 原本就没这约束，保持对等）
- 原硬编码 `actor: 'swift-ui'` 改为用 `parseActor(body.actor)` 的结果 —— Swift UI 不传 actor 依然落回 'swift-ui'

**MCP dispatch（`src/index.ts`）**：
- `project_move` / `project_undo`：本地 `expandHome` → snake_case→camelCase → 带 `actor:'mcp'` POST；PipelineResult 原本就对齐，响应透传
- `project_archive`：同上 + **响应转换** `{...result, suggestion:{category,reason,dst}}` → `{...result, archive:{category,reason}}`。保持 MCP 契约不变 + Swift UI 契约不变（Swift 只看 `suggestion`）
- 用共享 `shouldFallbackToDirect` 做降级判断

**dry-run 路径自动对齐**：查 orchestrator 发现 `runProjectMove({dryRun:true})` 在 `orchestrator.ts:211-212` 内部就是调 `buildDryRunPlan`，所以 MCP 走 HTTP 后和原来直调 `buildDryRunPlan` 走同一条路径，之前担心的"差异"不存在

**测试 +5**（`tests/web/project-api.test.ts`）：
- 未知 actor → 400 InvalidActor（move / archive / undo 三个端点分别测）
- `actor:'mcp'` 允许 $HOME 外路径通过 normalizeHttpPath
- `actor` 不传 → 默认 'swift-ui'，$HOME 约束仍生效（回归保障）

**结果**：`npm run build` ✓、`npx vitest run` **1202/1202** ✓

**需要 daemon 重新部署**：端点新增 `actor` 字段，旧 daemon 会忽略它（MCP 请求暂时按 `actor:'swift-ui'` 记录审计，功能正常、仅审计字段有小漂移）。Swift UI 不受影响（Swift 没碰 actor，一直是 'swift-ui'）。

### Added — Phase B Step 4：manage_project_alias 迁移 + DELETE body (2026-04-22)

Step 3（project 家族）迁移发现响应形状不对齐（`archive` vs `suggestion`、dry-run 计划差异、$HOME 约束）— 延后为专门一轮。先做简单的 Step 4 闭环继续推进。

- **`manage_project_alias` add/remove 路由到 `POST/DELETE /api/project-aliases`**（端点早有）。`list` 保持直接读（Phase B 只动写路径）
- **`DaemonClient.delete(path, body?)`** 扩展支持带 body 的 DELETE —— `/api/project-aliases` DELETE 需要 `{alias, canonical}` 才能定位要删的行
- MCP dispatch 参数翻译：`old_project/new_project` → `alias/canonical`
- 契约测新增 alias POST+DELETE round-trip + 400 validation bubble-up
- 测试文件重命名 `summary-contract` → `daemon-http-contract`（作用域拓宽到多端点）
- `npm run build` ✓、`npx vitest run` **1197/1197** ✓（+1 delete-with-body + 2 alias contract）
- **不需要 daemon 重新部署**：`/api/project-aliases` 端点早就存在

**Phase B 写工具清点再修订（Survey v3）**：实际 DB 写工具 **6 个**（原估计 10，然后 7，现在 6）：
- `link_sessions` 实为只读（filesystem symlink 是副作用，不触 DB 写），移出 Phase B 范围
- 已完成 4/6：save_insight / generate_summary / alias add / alias remove
- 剩下 Step 3 的 project_move / project_archive / project_undo（共享 orchestrator）

### Added — Phase B Step 2：generate_summary 迁移 + fallback helper 抽共享 (2026-04-22)

Step 1 留的 dispatch 内联判断抽成共享 `shouldFallbackToDirect(err, strict)`，给剩下 5 个工具复用；顺手把 generate_summary 接上 HTTP。

- **`shouldFallbackToDirect(err, strict)`**（`src/core/daemon-client.ts`）—— 核心判断：**`{error:...}` envelope + 4xx = 应用层拒绝（上抛），无 envelope 的 404/405/501 = 旧 daemon 端点缺失（降级）**。理由：Hono 对未知路由返回纯文本 404（无 envelope），而应用层 404（如 "Session not found"）始终带 envelope。这条规则把 rolling deploy 的行为从每个工具内联判断抽到一处
- **save_insight dispatch refactor**：用 helper 替换 inline 判断。行为不变，`src/index.ts` 中 save_insight 的分支从 28 行缩到 15 行
- **generate_summary 迁移**：MCP dispatch 从 `handleGenerateSummary(db, ...)` 改成 `daemonClient.post('/api/summary', {sessionId})`，返回 `{summary}` 包装进 MCP content 格式。**HTTP 响应形状不动**（Swift `SessionDetailView.swift:446` 依赖 `{summary}`）。审计（`audit`）从 MCP 侧迁到 daemon 侧 —— 一次操作一条审计，原本直写路径会产生两条
- 应用层错误降级为 MCP `isError: true` 而非 `throw`，匹配直接路径的行为
- 新增 `tests/web/summary-contract.test.ts`（3 tests）—— DaemonClient → Hono app 的真实 404/400 envelope 与 helper 判断对齐
- `npm run build` ✓、`npx vitest run` **1194/1194** ✓（+5 helper 单测 + 3 contract 测）、biome 干净
- **不需要 daemon 重新部署**：/api/summary 早就存在，Step 2 只改 MCP 路由代码

### Added — Phase B Step 1：DaemonClient + save_insight 单写者 pilot (2026-04-22)

MCP 从"多写者"改造成"daemon 唯一写者"的基础设施 + 首个 pilot 工具。Survey 发现实际写工具 7 个（非 10），其中 6 个端点已存在，只 save_insight 需新增。

- **`src/core/daemon-client.ts`**（新）：`DaemonClient` 封装 fetch + Bearer 鉴权 + timeout + `fetchImpl` 注入（测试友好）。`DaemonClientError` 带 status + body，4xx 与网络错误语义分离。`createDaemonClientFromSettings()` 固定走 127.0.0.1（即使 daemon 绑 0.0.0.0，MCP 走 loopback）
- **`POST /api/insight`**（`src/web.ts`）：调 `handleSaveInsight(params, { db, vecStore, embedder })`，与 MCP 直写路径共用同一 handler，行为一致。校验错误 400，其他 500
- **`src/index.ts` save_insight dispatch**：HTTP 优先，5 种错误分路：
  - 网络错误 (ECONNREFUSED/AbortError) → 软降级到直写
  - 404/405/501 → 软降级（rolling deploy：旧 daemon 没新端点时 MCP 不挂）
  - 400/409/422 → 直接 throw（避免 MCP 对无效输入静默重试到本地）
  - 500+ → 软降级
  - 任何情况下 `mcpStrictSingleWriter=true` → throw
- **`FileSettings.mcpStrictSingleWriter`**（默认 `false`）：软/硬约束开关，硬约束下 daemon 不可达直接 fail
- **测试 +13**：DaemonClient 单测 7 个（fetch 注入）、`/api/insight` 端点测 4 个、DaemonClient → Hono app 契约测 2 个（通过 fetch-shim 把 app.request 包装成 fetch）
- `npm run build` ✓、`npx vitest run` **1185/1185** ✓、biome 对改动 6 个文件干净

**行为变化**：
- 新 MCP 进程（下次 spawn）save_insight 先 POST 到 daemon，不可达则退回直写
- 现有旧 MCP 进程（session 里已在跑的）不受影响，仍走旧路径
- 部署 daemon 后才真正激活单写者（否则 404→ 降级到直写，等效于 Phase A 行为）

### Fixed — MCP 锁竞争快速止血 Phase A (2026-04-22)

用户报"MCP 又挂了"。排查发现 MCP 其实 `✓ Connected`，真症状是 `database is locked` —— 近 2h 有 29 条 `indexFile failed` 报错，**全部来自 `src=watcher`**。DB 同时有 3 个 node 进程（daemon + 2 MCP）持写句柄，WAL 涨到 137 MB，`busy_timeout=5s` 被突破。

**不是 node 稳定性问题**。换 bun / Swift 原生不治本（SQLite 还是 SQLite）。真因是**多进程并发写同一个 SQLite**。Phase A 先止血，Phase B 改架构。

- **busy_timeout 5s → 30s** (`src/core/db/database.ts:48`)：watcher 批事务突破窗口时不抛错
- **`checkpointWal()` helper** (`src/core/db/maintenance.ts`)：暴露 `PRAGMA wal_checkpoint(MODE)`，busy=1 退化为 PASSIVE 不抛错，支持 PASSIVE / FULL / RESTART / TRUNCATE
- **daemon 启动时 TRUNCATE + 每 10 分钟周期** (`src/daemon.ts`)：battery 模式 × 2；观测事件 `wal_checkpoint` + `db.wal_frames` gauge
- MCP 不参与 checkpoint —— 只由 daemon 驱动，避免多进程 pragma 竞争
- 契约测试：`tests/core/maintenance.test.ts` + 3 个 `checkpointWal` 测试（fresh DB / 写后 TRUNCATE / PASSIVE 模式）
- `npm run build` ✓、`npx vitest run` **1172/1172** ✓

**预期效果**：WAL 稳定在几 MB，`database is locked` 频次 ≥ 90% 下降。剩余来自真正长事务（> 30s），需 Phase B 拆小或走单写者。

### Fixed — Project Migration Round 4 (2026-04-20)

Third post-ship review cycle — user 在 Rename UI 上报了两个 UX 缺陷（进度条缺失、受影响文件列表不展开），并再次请 codex + gemini + self-review 三方平行审 `cf91fea..9427021`。合并后去重 4 Critical + 7 Important + 12 Minor/Nit，全修，分 5 个 commit 提交。

**B1: Error envelope 统一 (`cb95811`)**
- 抽出 `src/core/project-move/retry-policy.ts` 作单一事实源 — `classifyRetryPolicy()` / `mapErrorStatus()` / `buildErrorEnvelope()` / `humanizeForMcp()` / `sanitizeProjectMoveMessage()`。MCP (`src/index.ts`) 和 HTTP (`src/web.ts`) 都改调这一个模块
- 修复 **Critical**：未知错误默认 `retry_policy` MCP 为 `never`、HTTP 为 `safe` —— 同一错误两个端客户端行为不一致。现统一为 `never`（让用户决定，不鼓励盲目重试）
- 修复 **Critical**：`DirCollisionError` / `SharedEncodingCollisionError` 的 `sourceId` / `oldDir` / `newDir` / `sharingCwds` 在网络层被拍扁成字符串消息。现通过 `details` 字段透传给 Swift UI + MCP structuredContent，UI 能展示"Source: claude-code / Conflict path: /x/y"结构化行
- 修复 **Minor**：`sanitizeProjectMoveMessage` 的 ENOENT/EACCES/EEXIST 正则用 `[^,]*` 停在第一个逗号 —— 包含逗号的路径（APFS 允许）会被截断。改成匹配到闭合单引号或 EOL
- 修复 **Minor**：Swift `ProjectMoveAPIError.errorDescription` 返回 `"\(name): \(message)"` —— 服务端已剥掉 `project-move:` 前缀，Swift 又拼回 `DirCollisionError:` 变冗余。改返回 `message`
- 修复 **Minor**：MCP humanText 加 `DirCollisionError` / `SharedEncodingCollisionError` 分支 —— 之前 fallback 到 `name: message`，AI agent 没拿到"move aside then retry"具体指导
- 加 19 条 retry-policy 契约测试

**B2: Swift UI 破坏性保护 + issue 暴露 + 输入校验 (`a5c4edf`)**
- **Critical**：`PipelineResult.skippedDirs` 加到响应 + Swift Decodable + RenameSheet 预览显示 —— 之前只记在 `migration_log.detail`，iFlow 有损编码折叠 / 无目录 的源静默跳过，用户以为全部迁移成功
- **Critical**：`perSource[].issues` 加到 Swift Decodable + 预览红色警告 —— 之前 dry-run 期间 EACCES / too_large 被扫描发现但 UI 完全看不到
- **Critical**：ArchiveSheet 加 `.confirmationDialog` + `.role(.destructive)` —— 物理移动项目目录本来一键就能断开用户正在用的编辑器/shell/build
- **Important**：RenameSheet Preview 按钮绑定 `.keyboardShortcut(.defaultAction)`（Enter 键）—— 之前必须鼠标点击
- **Important**：RenameSheet 输入 trim whitespace + 拒绝 src == dst —— 之前只判 `isEmpty`，全空格或同路径都能透传到后端
- **Important**：UndoSheet 禁用行显示红色内联 "Can't undo: reason" —— 之前只是变灰，用户不知为何
- **Important**：ArchiveSheet 横幅 `Will move to …` 改用 `selectedCwd` 实际父目录 —— 之前硬编码 `~/-Code-/_archive/`
- **Minor**：预览失效改用 `opacity(0.5)` + "Path changed" 提示 —— 之前粗暴清空视觉突兀
- **Minor**：UndoSheet 行 accessibilityLabel 包含禁用原因

**B3: 后端正确性 (`c95f788`)**
- **Critical**：`autoFixDotQuote` sweep 折入 `patchFile` 的 CAS 窗口（新 `patchBufferWithDotQuote`）—— 之前 orchestrator step 4 是单独 readFile/writeFile pass，并发写下能静默覆盖另一进程的 append
- **Critical**：补偿自动反转 dot-quote 变换 —— step 4 不存在后，补偿用同一 `patchFile` 替换（src/dst 互换），dot-quote 变换原路回退
- **Critical**：`patchFile` 错误分类硬/软 —— `InvalidUtf8Error` + `ConcurrentModificationError` 向上抛触发整体补偿；软 EACCES / 文件中途消失降级为 `WalkIssue` 给 UI 显示。之前全降级导致 `state='committed'` 却半修
- **Critical**：`ARCHIVE_CATEGORY_ALIASES` 从 `src/tools/project.ts` 迁到 `src/core/project-move/archive.ts` (`normalizeArchiveCategory`)，`suggestArchiveTarget` 统一 normalize —— 之前 HTTP `/api/project/archive` 直接把 `archived-done` 透传产生英文目录 `_archive/archived-done/` 而不是 `/归档完成/`
- **Important**：`/api/project/migrations` 的 state filter 从 JS 层下推到 `listMigrations` —— 之前 `state=committed&limit=5` 在最近 5 行里过滤，失败/待定行消耗窗口导致结果数不足
- **Important**：Archive dry-run 不再 `mkdir` `_archive/<category>/` —— 之前 preview 模式也留空目录在磁盘上
- **Important**：dry-run `filesPatched++` 移到 size + read gate **之后** —— 之前先计再 skip，banner count 含被跳过的文件
- **Critical**：`skippedDirs` 同步 surface 到 CLI dry-run plan（含 per-source role + too_large issues）+ commit 后总结 + Swift UI preview
- **Bonus**：CLI dry-run 输出 per-source 分类（rename+patch vs content patch）+ issues 头 5 个 + skipped + clippy summary

**B4: macOS 大小写 + NFC/NFD (`ff333cb`)**
- **Critical**：preflight 允许 case-only rename（`/X/Foo` → `/X/foo` on APFS default case-insensitive）—— 之前 `stat(newDir)` 返源 inode 误触 `DirCollisionError`。现 `realpath(oldDir) === realpath(newDir)` 则放行
- **Critical**：`patchBuffer` NFC/NFD 回退 —— HFS+ 的文件名 NFD 存储，AI CLI 在该卷写 JSONL 可能把路径 NFD 写入。用户 NFC 输入会漏匹配。主正则 0 命中时自动用 `oldPath.normalize('NFD')` 需要再扫一遍
- 3 条 NFC/NFD 往返 + case-preserve 测试

**B5: Minor 收尾 (`f3e9a5c`)**
- **Minor**：`ProjectsView` 卡片加 `.contextMenu` —— 右键菜单镜像 `⋯` 按钮，新用户更易发现
- **Nit**：MCP tool `src`/`dst` description 加具体例子路径 —— AI agent 有模板不捏造
- **Minor**：`recover.ts` 对 `fs_done / src 消失 dst 存在` 的建议改正 —— 之前说 "re-run project move" 但 src 已不存在会立即失败。现指向手动 mv 回或直接 SQL update `migration_log`
- **Minor**：Gemini projects.json 补偿若发现"engram 创建的 + 移除我们的条目后 map 为空"，直接 `unlink` 文件 —— 之前留空壳
- **Minor**：CLI 错误处理调用共享 `classifyRetryPolicy` 输出重试提示 —— 和 MCP/HTTP 行为一致

测试：1169 passed (+20 since Round 3 landing)。Swift xcodebuild Debug 绿。

### Fixed — Project Migration Review Rounds 2/3 (2026-04-20)

**Round 2**（user 实测 `Pi-Agent` rename 时发现 `buildDryRunPlan` 是 stub，所有 dry-run 永远显示 0/0）:
- `buildDryRunPlan` 从占位 stub 改为真扫描 — `findReferencingFiles` 每源 + `Buffer.indexOf` 统计 occurrences，`renamedDirs`/`perSource` 填真实数据
- `watcher.ts` chokidar `ignored` pattern 加 `/.gemini/tmp/<proj>/tool-outputs/` 等 —— 修历史 `ENFILE: file table overflow` crash（gemini tmp 下工具输出文件堆积几万个）
- `runProjectMove` 入口加空值/自引用 guard 防 `Buffer.indexOf(emptyNeedle)` 无限循环

**Round 3**（codex + gemini 再审，聚焦 "stub-class / silent trust failures"，又抓到 4 Important + 4 Minor + 1 Low，全修）:
- `runProjectMove` 入口用 `path.resolve()` canonicalize src/dst —— 之前只 HTTP 层做，MCP/CLI/batch 通过 `/x/a/../proj` 能绕过 `src===dst` / 自子目录 guard（**Critical 漏洞**）
- MCP tool 成功返回加 `structuredContent` —— 之前只错误路径有，AI 客户端成功时拿不到结构化 `migrationId`/`totalFilesPatched`
- dry-run 超大文件（>50 MiB）和 stat 失败改发 `WalkIssue{too_large, stat_failed}`，`perSource.issues` 真实填充 —— 之前硬编码 `+= 1` 或静默吞
- `recover.ts` `tempArtifacts: []` 改真扫 `.engram-tmp-*` / `.engram-move-tmp-*` 残留；`exists()` 改 `PathProbe` 三态（`exists`/`absent`/`unknown`），区分 ENOENT vs EACCES
- Swift 3 sheets：`res.state === committed` 但 `res.review.own` 非空时展示橙色警告 + 换 "Close" 按钮不再 auto-dismiss，软警告不再被静默
- `ProjectsView.hasRecentMigrations: Bool?` —— nil = daemon 不可达，不再乐观保留旧值误导
- `DaemonClient.fetch<T>` 挂 `freshBearerToken()` —— 之前 GET 漏 bearer，`/api/ai/*` 在 token 保护下会 401
- dry-run 200 contract test 加 `totalFilesPatched ≥ 1` 等真值断言 —— 之前只验类型，stub 降级成 0 仍然过
- Gemini projects.json 与 stale "6 AI session roots" 描述改成 7（`encodeIflow` 加入后陈旧了）

**Learning**: Stub-class bugs（返回类型正确但值硬编码/系统性低估）能避开 3 轮 review + 单测 type-check；只有人肉 UI 实测或强断言数值才能拦。已把"测试必须验 count 真值"纳入新 review 清单。

### Added — Project Directory Migration (2026-04-20)

完整接管原 `mvp.py` 脚本职责，跨 7 个 AI 会话源（Claude Code / Codex / Gemini CLI / iFlow / OpenCode / Antigravity / Copilot）重命名或归档项目目录，同步打 patch 所有 cwd 引用。

- **CLI**：`engram project {move,archive,review,undo,list,recover,move-batch}`（`src/cli/project.ts`）
- **MCP**：7 个工具返回 `structuredContent` + `retry_policy`（`safe` / `conditional` / `wait` / `never`），描述带 `⚠️ Cannot run concurrently`
- **HTTP**：`/api/project/{move,undo,archive,cwds,migrations}`，统一错误 envelope 结构，`$HOME` 前缀保护 + `path.resolve` 收 `..` 穿越
- **Swift UI**：`ProjectsView` `⋯` 菜单（Rename / Archive）+ 顶栏 Undo 按钮；`RenameSheet` 反查 cwd（单/多/空三分支），`ArchiveSheet` 分类选择 + 物理移动警告，`UndoSheet` 最近 5 条 committed
- **Gemini projects.json 同步**：新增 `gemini-projects-json.ts`，`~/.gemini/projects.json` 的 cwd→basename 映射随 tmp 目录 rename 原子更新，补偿可回滚
- **Basename 劫持防护**：`SharedEncodingCollisionError` — Gemini `/a/proj` 和 `/b/proj` 共用 `tmp/proj/` 时拒绝 rename
- **Preflight 冲突检查**：`DirCollisionError` — 目标目录已存在时在 step 1 物理移动 **之前** 拒绝，不需要回滚 GB 级 move
- **iFlow 有损编码**：`encodeIflow` 去端破折号，作为第 7 个源接入 `getSourceRoots`
- **三层错误 envelope**（Swift `DaemonClient.validateResponse`）：structured → legacy string → plain text，所有 HTTP 方法统一解码
- **任务取消**：Swift sheet 存 `@State var activeTask`，`onDisappear` 取消 + `Task.isCancelled` 守卫 + `.interactiveDismissDisabled(isExecuting)` — ESC/swipe 不会让 FS 操作静默继续
- **Per-request bearer token**：服务端中间件 + Swift `freshBearerToken()` 都每次读 settings.json，token rotation 不用重启
- **Task retry_policy 人话化**：`RetryPolicyCopy.swift` 把枚举翻成自然语言 + 条件 Retry 按钮；UndoStale 行级禁用防重复提交
- **Python `mvp` 退役**：`/Users/bing/-Code-/_项目扫描报告/mvp` 变 50 行 bash shim delegating to `engram project`；Python 原版备份为 `mvp.py-retired-20260420`
- **Orphan session 处理**（前置工作）：`SessionAdapter.isAccessible`、`sessions.orphan_status/since/reason`、`watcher.onUnlink`、`detectOrphans` 30 天 grace 状态机
- **救援迁移**：41 Gemini + 1 iFlow 活会话从 `coding-memory` 迁到 `engram`，DB 同步 42 条

### Fixed
- daemon 启动时的首个 `ready.todayParents` 事件现在在父子链接/层级回填后再发出，避免菜单栏 badge 启动瞬间出现旧值
- `ThemeTests` 改为断言本地时区显示结果，不再把 UTC 字符串误当作本地时间
- 文档同步到当前事实：`922 tests`、`save_insight` 默认 importance = `5`、非 localhost + 缺少 `httpAllowCIDR` 时 daemon 直接拒绝启动
- `upsertAuthoritativeSnapshot` ON CONFLICT UPDATE 补 `file_path` 回填条件 —— 修 37 条空 `file_path` 行
- `/api/*` 401 响应改成 JSON envelope（原本 plain-text），Swift 客户端统一解码

### Changed
- **Tests**：1111 → **1146**（+35 新测覆盖 project-move 全路径、Gemini projects.json、envelope contract、$HOME 保护）

## [0.0.1.1] - 2026-04-13

### Added
- **Agent Session Grouping**：父子会话关联，agent 子会话自动归组到父会话
  - Layer 1：从 Claude Code subagent 文件路径提取父 ID（确定性）
  - Layer 1b：Codex `originator === "Claude Code"` 自动标记 dispatched
  - Layer 1c：Gemini sidecar `.engram.json` 文件读取 parentSessionId
  - Layer 2：Dispatch pattern 匹配 + 时间/CWD 打分（启发式 → `suggested_parent_id`）
  - Layer 3：HTTP API 手动确认/解除关联
  - Swift UI：`ExpandableSessionCard` 折叠展开，HomeView/SessionList/Timeline 三处联动
  - Menu bar badge 显示今日父会话数量
- **Insight Hardening**：`save_insight` 输入校验（10~50K 字符）、文本去重、`sourceSessionId` 贯穿、删除双表一致性
- **Bootstrap Factories**：`createMCPDeps()` / `createDaemonDeps()` / `createShutdownHandler()` 统一初始化

### Changed
- **测试覆盖率提升**：767 → 922 tests

### Fixed
- MCP Server idle timeout 导致提前断连（已禁用 `idleTimeoutMs`）
- `importance` 默认值全局统一为 5

---

## [0.0.1.0] - 2026-04-13

### Added
- **本地语义搜索**：Viking/OpenViking 替换为 sqlite-vec + FTS5 trigram + RRF 融合
  - `save_insight` MCP 工具 — 主动记忆写入
  - `chunker.ts` — 消息边界优先的文本分块
  - `vector-store.ts` — chunk + insight 向量表 + model tracking
  - `embeddings.ts` — provider 策略（Ollama / OpenAI / Transformers.js opt-in）
  - `ServerInfo.instructions` — MCP 自描述协议
- **Insights 文本存储 + FTS 搜索**：`insights` 表 + `insights_fts`，无 embedding 也能保存和搜索知识
- **save_insight 优雅降级**：无 embedding → 纯文本保存 + warning；有 embedding → 双写
- **get_memory / search / get_context FTS 回退**：无 embedding provider 时关键词搜索 insights
- **Insight embedding 回填**：daemon 启动时自动将纯文本 insights 升级为向量
- **MCP 工具 API 参考文档**：`docs/mcp-tools.md` 记录全部 19 个 MCP 工具
- **CONTRIBUTING.md**：新增贡献者指南

### Changed
- **db.ts God Object 拆分**：1869 行拆分为 10 个领域模块 + facade 类 + ESM re-export shim（`src/core/db/`）
- **测试覆盖率提升**：691 → 767 tests，67% → 75% lines

### Fixed
- Flaky hygiene test 时间戳竞态条件修复
- CJK insight 搜索增加 LIKE 回退
- Insight FTS 原子性（事务包裹）

### Removed
- **Viking/OpenViking 全部移除**：删除 `viking-bridge.ts`（851 行）、`viking-filter.ts`、7 个 Viking API 路由、Swift 设置页面
- 移除未使用依赖 `js-yaml`
- 清理 14 个未使用导出、53 个未使用导出类型

---

## [0.0.0.9] - 2026-04-09

### Changed
- **Biome 代码规范强制执行**：pre-commit hook（husky + lint-staged），178 个文件 lint 清理
- **安全 + 性能 + DX 综合升级**：code review 修复轮次

---

## [0.0.0.8] - 2026-04-07

### Added
- **AI Audit Log**：所有外部 AI 调用（embedding、摘要、标题生成、Viking）的审计日志
  - `AiAuditWriter` + `AiAuditQuery` + schema migration
  - 自动提取 token 用量（input/output/cost）
  - `/api/ai/*` HTTP 端点查询审计记录
  - VikingBridge observer proxy 方法

### Fixed
- Viking `pushSession` parts 格式修复、`findMemories` URI 修复
- Viking 从 `addResource` 切换到 `pushSession` + composite session ID
- `get_context` 改用 memory snippets 替代 resource URI mapping
- `search` 增加 `vikingMemories` 记忆感知管道

---

## [0.0.0.7] - 2026-03-24

### Added
- **竞争力追赶（Competitive Catch-up）**
  - Health Rules Engine：9 项环境健康检查 + 可注入 `ShellExecutor`
  - Cost Advisor：费用优化引擎 + `get_insights` MCP 工具
  - `get_context` 环境数据块：活跃会话、今日费用、工具使用、告警
  - Hygiene 页面（macOS app）
  - Transcript 工具调用/结果卡片 + 语法高亮
- **可观测性（SP3 系列）**
  - SP3a：结构化日志（ALS 自动关联、stderr JSON、PII 过滤、request-id 贯穿）
  - SP3b：系统指标收集（DB query 自动计时 Proxy、FTS/vector 子查询计时、HTTP 错误计数）
  - SP3b-alerting：AlertRuleEngine + 6 条性能告警规则 + `alerts` 表
  - SP3d：AI 视觉验证（Kimi + Claude VLM 对比截图 AI 审查）
  - SP3e：测试覆盖扩展（33 个新测试，copilot/MCP/indexer/web/viking 错误路径）
- **自动化测试（SP1 + SP2）**
  - 截图对比管线 + baseline 管理
  - Test fixture 自动生成 + schema 校验
  - Viking quality test 脚本

### Fixed
- SQLite busy_timeout=5000ms 防止 `database is locked`
- Keychain 授权对话框问题（Debug 构建跳过 Keychain）
- Settings onChange 在 load 时触发导致 Viking API key 丢失
- Viking 重复推送跳过已发送的会话

---

## [0.0.0.6] - 2026-03-19

### Added
- **macOS App 大重构**
  - 主窗口全新设计：Sidebar + Pages 架构
  - Session Pipeline Tiering：4 级会话分级（skip/lite/normal/premium）
  - Settings 重新设计：General/AI/Network/Sources 分区
  - 8 个 PR 系列功能：
    - PR1：Transcript 增强（颜色条、chips、查找、工具栏）
    - PR2：Session List 重写（SwiftUI Table、agent 过滤、项目搜索）
    - PR3：Top Bar（⌘K 搜索、Resume 按钮、主题切换）
    - PR4：Session Housekeeping（preamble 检测、tier 增强）
    - PR5：Usage Probes（采集器、DB、API、Popover UI）
    - PR6：Workspace（repos、detail、work graph）
    - PR7：Session Resume（GUI 对话框、CLI `engram --resume`、终端启动器）
    - PR8：AI Title（生成器、设置、indexer 触发、regenerate-all）
- **Popover Dashboard**：Menu bar 弹出窗口仪表盘（KPI 卡片、热力图）
- **UI Performance 优化**：虚拟滚动、懒加载、缓存

---

## [0.0.0.5] - 2026-03-16

### Added
- **OpenViking 集成**：外部语义搜索引擎接入（后于 v0.0.1.0 移除）
  - VikingBridge + VikingFilter
  - 会话自动推送到 Viking
  - `get_memory` MCP 工具

---

## [0.0.0.4] - 2026-03-10

### Added
- **AI Summary Redesign**：AI 摘要管线重构（多 provider 支持）
- **Popover Dashboard 设计**：menu bar 弹出窗口交互设计

---

## [0.0.0.3] - 2026-03-03

### Added
- **Web UI + 多机同步**
  - Hono HTTP 服务器 + 纯 HTML/JS 前端
  - `/api/sessions`、`/api/search`、`/api/stats` 等 REST 端点
  - 会话列表、详情、搜索、用量统计页面
  - SQLite-based 多机同步（pull-based，增量同步元数据）
  - 配置文件：`~/.engram/settings.json`
- **RAG 向量搜索基础**
  - sqlite-vec 集成（embedding 向量存储）
  - Ollama + nomic-embed-text 本地 embedding
  - OpenAI embedding fallback
  - 后台异步索引

### Changed
- **消息计数重设计**：精确区分 user/assistant/tool 消息数

---

## [0.0.0.2] - 2026-02-28

### Added
- **macOS SwiftUI 应用**
  - Menu bar 菜单栏应用 + Popover + 独立窗口
  - SessionList、搜索、时间轴、收藏夹、设置 UI
  - GRDB 数据库只读访问（Node 拥有 schema，Swift 只读）
  - Node.js daemon 子进程管理（`IndexerProcess`）
  - MCP Server（Hummingbird 2、TCP + Unix socket）
  - stdio ↔ Unix socket 桥接（CodingMemoryCLI）
  - LaunchAgent 登录自启动
  - 发布脚本（归档、公证、DMG 打包）
- **IDE 适配器（4 个）**
  - Cursor（SQLite cursorDiskKV）
  - VS Code Copilot Chat（JSONL kind:0 格式）
  - Antigravity（gRPC → JSONL cache，cascade client）
  - Windsurf（gRPC cascade adapter）
- **会话浏览增强**
  - Clean/raw 对话视图 + 系统注入过滤
  - Agent badge + 过滤 chips（Claude Code agent 子进程识别）
  - 会话排序、多选过滤、时间轴展开/折叠

### Fixed
- Antigravity gRPC 端口检测（lsof PID 精确过滤、TLS/明文端口区分）
- Antigravity 会话内容读取（GetCascadeTrajectory API、三级降级策略）
- 索引器去重一致性（缓存文件 vs .pb 文件大小）
- 孤儿 Node 进程清理（Xcode SIGKILL 后 pkill 旧进程）
- MCP Server 启动问题（HTTP/1.1 Unix socket、stamp 文件、write pool 泄漏、stdin 关闭退出）

---

## [0.0.0.1] - 2026-02-27

### Added
- **项目初始化**：TypeScript MCP Server 脚手架（Node.js 20+、ES modules、vitest）
- **核心架构**
  - `SessionAdapter` 接口定义（detect/listSessionFiles/parseSessionInfo/streamMessages）
  - SQLite 数据库层（better-sqlite3、WAL 模式、FTS5 全文搜索）
  - 会话索引器（全量扫描 + skip-unchanged 优化）
  - 文件监听器（chokidar 增量更新）
  - 项目名解析器（git remote / basename）
- **CLI 适配器（4 个）**
  - Codex CLI（`~/.codex/sessions/` JSONL 逐行流式读取）
  - Claude Code（`~/.claude/projects/` JSONL，路径编码解析）
  - Gemini CLI（`~/.gemini/tmp/` JSON，projectHash 反推）
  - OpenCode（`~/.local/share/opencode/` SQLite + JSON）
- **第二批适配器（5 个）**
  - iflow、Qwen、Kimi、Cline、MiniMax、Lobster AI
- **MCP 工具（7 个）**
  - `list_sessions` — 列出会话（按来源/项目/时间过滤）
  - `get_session` — 读取会话内容（分页，每页 50 条）
  - `search` — FTS5 全文搜索
  - `project_timeline` — 项目跨工具时间线
  - `stats` — 用量统计（按来源/项目/天/周分组）
  - `get_context` — 智能上下文提取（token 预算控制）
  - `export` — 导出会话为 Markdown/JSON

### Fixed
- Codex `environment_context` 系统注入过滤
- Claude Code `superpowers` skill injection 过滤
- Cline malformed JSON 处理
- Kimi readline stream 提前退出关闭
- Watcher watchMap 非空断言移除
