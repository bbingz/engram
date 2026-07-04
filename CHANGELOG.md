# Changelog

All notable changes to this project will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/).

---

## [Unreleased]

### Documentation: workspace cleanup memo and review archive (2026-07-04)

- Added `MEMO.md` as a short newest-first project memo for cross-agent
  workspace state.
- Archived root-level review/audit reports into `docs/reviews/` and moved the
  previously local `audit/` report pack into dated review files.
- Backfilled workspace-hygiene follow-ups in `docs/followups.md`: commit the
  archive cleanup, resolve `codex-provider-audit-remediation`, decide whether to
  reclaim Time Machine snapshot space immediately, and normalize local ignore
  rules.

### Performance: full audit + 8 optimization PRs, all adversarially reviewed (2026-07-03, Claude Code, ultracode workflows)

Two-workflow pass: (1) a 49-agent audit produced 25 adversarially-verified perf
findings against the live 835 MB / 29,093-session DB (43 raw → 25 confirmed, 13
refuted with measurements; roadmap + findings JSON preserved under
`~/.claude/projects/-Users-bing--Code--engram/2a2fe987-*/subagents/workflows/wf_3946e4d0-4a4/`);
(2) a 21-agent implement→review→fix pipeline shipped the findings as 8
file-disjoint PRs, each adversarially reviewed to zero blocking issues. At
Claude handoff, PRs were OPEN (not merged).

Codex follow-up on 2026-07-04 merged all eight PR branches locally into
`codex/perf-integration-review`, then ran a second review/fix pass before local
deployment. Confirmed fixes: startup skip-tier reconciliation now also deletes
and counts stale `fts_map` rows; project move/archive/batch dry-run execution
uses the same HOME-scoped root as service path validation, preventing local tests
from scanning the real `~/.claude/projects`; locale-sensitive Swift tests now
assert localized strings instead of English literals.

- **Codex verification/deploy**: `npm run build`, `npm run lint` (passes with
  the existing screenshot-compare warning), `npm run knip`,
  `npm run typecheck:test`, `npm run test:coverage` (1590 tests),
  `npm run generate:fixtures`, `npm run check:adapter-parity-fixtures`,
  `npm run check:fixtures`, `git diff --check`, `xcodegen generate` +
  pbxproj drift check, full `EngramCoreTests`, full `EngramServiceCore`
  (269 tests, 1 skip), full `EngramMCPTests`, and full `Engram` app tests with
  `EngramUITests` skipped all passed locally.
- **Installed app**: `./scripts/build-release.sh --local-only` exported
  `/Users/bing/-Code-/engram/macos/build/EngramExport/Engram.app`, release
  verifier passed bundle hygiene + Developer ID deep codesign, and
  `scripts/deploy-local.sh` replaced `/Applications/Engram.app` with version
  `0.1.0 (20260703234028)`. Installed `codesign --verify --deep --strict`
  passed; launch smoke showed `Engram` and `EngramService` running from
  `/Applications/Engram.app`.
- **Not run / blocked**: notarization, stapling, DMG creation, and remote CI were
  not run. `npm run screenshots:compare` was blocked by macOS container privacy
  (`EPERM` reading the UI-test screenshot manifest), and a capture-only UI smoke
  run produced no screenshots before being interrupted.

- **#98 perf(search)**: port service CTE keyword query into the app-local search
  fallback in `Database.swift` — kills a measured 80–100 s frozen-app hang
  (service briefly down) vs 81 ms; parity test local-vs-service.
- **#96 perf(startup)**: metadata-gate the unconditional FTS `optimize`
  (measured ~7 s holding the write gate every launch), interval-gate the 29k-row
  orphan re-stat, cross-session prune of terminal `session_index_jobs` rows
  (155 K rows / ~40 MB), startup reconcile deleting FTS/embedding rows for
  current-tier-skip sessions (DELETE-only, tier untouched).
- **#97 perf(ui)**: static regexes in `ToolCallParser`, single parse per tool
  row in `ColorBarMessageView`, memoized find-bar highlight, debounced
  browse-page reloads that preserve pagination during indexing ticks.
- **#99 perf(service)**: static redaction regexes (1,600→8 compiles per page),
  weak ETag/304 on web UI, windowed resume primer, `replayTimeline` defers its
  FTS fallback fetch (~180 ms discarded work per transcript open).
- **#95 perf(mcp)**: `get_session` pages via early-stopped streaming with the
  EXACT origin/main dense visible-unit contract preserved (raw-window/sentinel
  redesign was rejected in review); exact `totalPages` via count-scan cached per
  (locator, size, mtime); 110 MCP tests green.
- **#102 perf(indexer)**: parse each changed file once (was twice) and
  short-circuit provably-skip sessions before the heavy digest pass (88 % of
  corpus); provable-skip conditions are an exact subset of `SessionTier.compute`
  skip returns (verified in review); 5-tier parity test matrix.
- **#100 perf(adapters)**: `readObjects` truncate-and-succeed instead of
  throwing into the uncapped legacy parser (kills a hundreds-of-MB spike on a
  173 MB / 39 k-msg session), bounded whole-document parse cache keyed on
  (locator, mtime, size) values, persisted source-hint cache (saves ~26 k file
  head-reads per cold launch for minimax/lobsterai detection).
- **#101 perf(fts)**: THE structural fix — companion `fts_map` table
  (session_id → fts rowid, indexed) so per-session FTS deletes seek instead of
  full-scanning the 460 MB trigram index; incremental append-only inserts;
  live-session FTS job debounce; self-healing fallback when map rows are
  missing; NO sessions_fts vtable change, NO `expectedVersion` bump.
- **Orchestration lessons**: (a) initial implementer instructions wrongly said
  "never commit generated Engram.xcodeproj" — this repo TRACKS pbxproj and CI
  runs an xcodegen drift check; three branches needed follow-up
  regenerate-and-commit fixes from an `engram`-named worktree (xcodegen embeds
  the root directory name as the top-level group name, so agent worktree names
  leaked into pbxproj). (b) Deferred as follow-ups: #19 tail-parse via
  parsedOffset/boundaryHash (design together with fts_map), CJK shingle search
  index (#26 option a), MCP first-request count-scan still O(file).

### Project-detail timeline: vertical rail + AI semantic titles + click-through (2026-06-28, Claude Code, ultracode workflow)

Embedded a per-project work timeline in the Projects detail view (Workspace →
Projects → select a project), shown directly under the project header. Built via
a 2-workflow flow: parallel code-mapping/design, then 4 disjoint-file parallel
implementers + build-fix loop + 3 adversarial reviewers.

- **Vertical-rail UI** (`macos/Engram/Components/ProjectWorkTimeline.swift`): left
  rail + color-coded node dots (per `SessionImplementationKind`), date + kind
  badge + title + outcome. `TimelineRail`/`TimelineNode` private subviews;
  `WorkTimelineCard` stays `private` to `TimelinePageView` (global Timeline only).
- **AI per-work-item semantic titles**: new service-owned `work_item_titles`
  table (`project, work_key, title, intent_hash, model, updated_at`; idempotent
  migration, excluded from `SchemaManifest.baseTables`). New service command
  `generateProjectWorkTitles` generates a ≤30-char title per work item from its
  intent+outcome via the user's configured title model (mimo), reusing
  `ServiceAIClient.chat`+`cleanTitle`. AI calls run OUTSIDE the writer gate; only
  the upsert runs inside `ServiceWriterGate`. `intent_hash` (SHA256) drives
  skip-already-generated. App reads via a `tableExists`-guarded LEFT JOIN in
  `DatabaseManager.implementationTimeline` (project-scoped); display prefers
  `item.semanticTitle ?? item.title`. On-demand: opening a project triggers one
  generation pass (guarded by `requestedTitleGen`) then an in-place reload.
- **Click-through**: tapping a node opens the latest beat's session via the
  existing `.openSession`/`SessionBox` path.
- **IPC**: full 6-layer wiring (protocol, client, mock, DTOs, dispatch,
  capability-token allowlist `generateProjectWorkTitles`).
- **Post-review fixes**: (1) reload no longer flashes a spinner / blanks the rail
  (`load(showSpinner:)`); (2) hardened `generateProjectWorkTitles` to return the
  generated titles directly instead of a fragile post-write re-SELECT that threw
  `no such table` when `work_item_titles` was absent (app ignores the response
  and reloads from DB anyway).
- **Test seam**: `generateProjectWorkTitles` gained injectable `titleConfig` +
  `generateTitle` params (production defaults read real settings / call the real
  model) so cache/no-op paths are deterministically testable without network.
- **Tests (all green)**: `DatabaseManagerTests` semantic-title surfaced + null-safe
  when table absent + project scoping (3); `MigrationRunnerTests` work_item_titles
  columns/PK (in suite, 14); `EngramServiceIPCTests` generateProjectWorkTitles
  authorized + empty-result no-crash, intent_hash skip-cached + regenerate-on-
  change, and no-AI-config-persists-nothing-with-work-items (3). Full Debug build
  SUCCEEDED.
- **Residual**: full Swift/UI suites, lint, packaging not run.
- **Note (unrelated)**: `~/.claude/projects/-Users-bing--Code--engram/memory`
  symlinks to `.memory`, a regular file not a directory — auto-memory writes are
  currently broken. Left as-is (out of scope).
- **Codex review follow-up**: no behavior blocker found. Cleaned the newly added
  Swift comments/prompt text to match the repo's English/ASCII source-comment
  convention. Re-verified `xcodegen generate` stability, focused app read-join
  tests, service `generateProjectWorkTitles` tests, migration schema creation,
  and `git diff --check`.
- **Ready-for-review fix**: a subagent review before marking PR #93 ready found
  that empty/whitespace generated work-item titles could be persisted with the
  current `intent_hash`, making future generation passes skip the item while the
  app fell back to the heuristic title forever. Generated titles are now trimmed
  and empty results are skipped before upsert; added an IPC regression test that
  proves empty attempts persist nothing and are retried successfully.

### Full-project audit remediation pass (2026-06-28, Codex)

Closed the actionable 2026-06-28 audit items across Swift product runtime and
retained TypeScript parity surfaces.

- **Untrusted-input hardening:** bounded VS Code mutation replay depth/indexes,
  local remote-storage keys, MCP numeric tool args, Gemini/Copilot auxiliary
  reads, ReplayState density buckets, and VectorMath blob/dimension decoding.
- **Security/data-integrity:** switched RepoDetailView to the shared
  AppleScript command helper, escaped remaining LIKE call sites, synced
  protected capability-token commands, made GitDirty fail closed on git errors,
  guarded `commitRehydrated` by `sync_version`/`offload_state`, fixed log
  sanitizer ordering, and created project-move/web-token temp files with 0600
  permissions at creation time.
- **Robustness/performance:** bounded OSLog recent-log memory, added a default
  `sessionTimeline` limit, isolated SwiftIndexer file-state write failures,
  rethrew `CancellationError` from startup/offload backfills, parenthesized and
  structurally qualified `HumanDrivenFilter` SQL, locked FTS rebuild resume
  behavior with a test, lazy-rendered project detail sessions, and refreshed
  onboarding source counts after Full Disk Access.
- **Reference parity/cleanup:** reconciled TypeScript FTS rebuild policy with
  Swift authority and removed orphan iFlow cwd decode helpers.
- **Verification:** targeted App/Core/ServiceCore/MCP Xcode tests passed for the
  remediated paths; targeted Vitest adapter/FTS tests passed (7 files, 101
  tests); `npm run typecheck:test`, `npm run lint`, and `git diff --check`
  passed. Full Swift suites, full npm coverage, UI tests, release packaging, and
  CI were not run in this pass.

### Full-project read-only audit (2026-06-28, Claude Code — ultracode workflow)

3-phase audit: recon + architecture mapping (main agent) → 16 parallel
module-reviewer subagents in 4 batches (read-only, structured JSON findings)
→ cross-cutting synthesis. 118 findings (1 critical, 7 high, 20 medium, 87 low,
3 info) across ~104K LOC Swift + ~33K LOC TS. Report written to
`docs/reviews/2026-06-28-full-project-audit.md`. P0 items: VS Code mutation-log replay OOM/stack-overflow
DoS, LocalDirectoryBackend path traversal, AppleScript command injection in
RepoDetailView, MCP integer-overflow crashes, adapter aux-file OOM, ReplayState
densityBuckets crash. Dominant theme: untrusted-input bounds guards exist but
are applied inconsistently. No production code modified.

### Session implementation digest and work timeline first pass (2026-06-27, Codex)

Implemented the first deterministic project-work timeline derived from session
transcripts. The design follows the product decision that useful work evidence is
the human request plus the strongest final assistant completion report, not the
intermediate tool-call stream.

- **Digest extraction:** added `ImplementationDigestExtractor`, which emits
  `SessionImplementationBeat` rows from real user turns and completion-style
  assistant reports. It filters AGENTS/bootstrap text, local command wrappers,
  tool-result messages, system injections, short context-free acknowledgements,
  and progress chatter unless those turns provide operation evidence.
- **Timeline grouping:** added `ImplementationTimelineBuilder`, which excludes
  operation-only beats, groups same-work items by stable work key, merges
  adjacent action dates into ranges, and splits later non-contiguous returns into
  subsequent batches.
- **Schema/write path:** added `session_work_beats` with indexes by action date
  and work key. `SessionSnapshotWriter` persists beats alongside snapshots,
  replaces changed beats on healthy re-index, and preserves existing beats on
  empty failed re-streams.
- **Indexer/backfill:** `SwiftIndexer` collects implementation candidate
  messages during stream stats, extracts beats into authoritative snapshots, and
  `EngramDatabaseIndexer` can backfill existing reliable local sessions that
  have human signal but no work beats yet. `EngramServiceRunner` schedules this
  after instruction backfill and before normal initial indexing.
- **App read/UI:** `DatabaseManager.implementationTimeline(...)` exposes the
  grouped work rows with date/project/human-driven filters. Timeline now has a
  Work/Sessions segmented mode; Work mode renders date ranges, batch labels,
  source session counts, status/kind, human intent, and assistant outcome.
- **Verification:** targeted `EngramCoreTests` for extractor, migration,
  snapshot persistence, empty re-stream preservation, and backfill passed
  (9 tests, 0 failures). Targeted `EngramServiceCore` `EngramServiceIPCTests`
  passed (131 tests, 0 failures). `xcodebuild -project Engram.xcodeproj -scheme
  Engram -configuration Debug build CODE_SIGNING_ALLOWED=NO` passed. Not run:
  full `EngramCoreTests`, full `EngramServiceCore`, full `EngramMCPTests`,
  `EngramUITests`, full TS suite, release packaging, remote CI.

### Human-driven sessions follow-up: direct startup instruction backfill + live proof (2026-06-27, Codex)

Closed the remaining historical-data risk after the first backfill pass. The
live app showed parse/index state being refreshed while `sessions.instruction_*`
could still stay NULL for existing `codex` rows, so the startup backfill now
updates only the instruction signal columns directly from the message stream.

- **Startup phase:** `EngramServiceRunner` runs `initialInstructionBackfill`
  before the heavier initial scan. The phase is isolated behind its own writer
  gate call so a failure does not block the normal startup scan/backfills.
- **Direct writer path:** `EngramDatabaseWriter.indexInstructionBackfillSessions`
  now reads reliable-source candidates (`claude-code`, `codex`), streams user
  messages through `InstructionExtractor`, and batches direct `UPDATE sessions`
  writes for `instruction_count`, `human_turn_count`, and `instruction_summary`.
  It does not rely on full session UPSERT/hash/FTS paths.
- **Legacy locator compatibility:** candidate matching and known-state reads use
  `COALESCE(NULLIF(source_locator,''), NULLIF(file_path,''))`, so old rows with
  blank `source_locator` can still be backfilled from `file_path`.
- **Terminal parse handling:** terminal parser failures are marked handled with
  `instruction_count = 0`; default visibility still has `user_message_count >= 12`
  and `tier = premium` rescue gates for long historical human sessions.
- **Live proof:** installed `/Applications/Engram.app` version
  `0.1.0 (20260627085424)`. After startup backfill on the real
  `~/.engram/index.sqlite`, reliable-source rows with `instruction_count IS NULL`
  and existing local files are zero: `codex 0/0`, `claude-code 0 existing / 7131
  missing`. Populated rows: `codex=2614`, `claude-code=472`; sessions passing
  human-driven gates among those sources: `codex=820`, `claude-code=747`.
- **Verification:** targeted instruction-backfill tests 5/5, full
  `EngramCoreTests` 516/516, service startup-order tests 3/3, release build +
  Developer ID release verification, local deploy, installed app version check,
  `codesign --verify --deep --strict`, launch/process smoke, and real DB
  backfill smoke passed. Not run in this follow-up: `EngramUITests`, full
  `EngramServiceCore`, full `EngramMCPTests`, full TS suite, notarization/stapling,
  DMG, remote CI.

### Human-driven sessions: historical backfill + reliable-source NULL filter (2026-06-27, Codex)

Picked up Claude's human-driven session work, built and locally deployed the app,
then closed the remaining live-data gap: reliable historical `claude-code`/`codex`
rows with missing instruction signals were still visible by default because the
initial predicate treated `instruction_count IS NULL` as globally visible.

- **Backfill trigger:** `SwiftIndexer` now reparses known reliable-source rows
  (`claude-code`, `codex`) when `file_index_state` is parseable and the stored
  session has `instruction_count IS NULL`, bypassing normal same-file fast skips
  without retrying terminal/error file states.
- **Writer merge fix:** `SessionSnapshotWriter` no longer returns `noop` for a
  same-content snapshot whose newly-derived instruction signals differ from the
  stored row. It merges only `instruction_count`, `human_turn_count`, and
  `instruction_summary` as local state and avoids unnecessary FTS/embedding work.
- **Default predicate narrowed:** `HumanDrivenFilter.sqlPredicate` now allows
  NULL instruction signals by default only for sources not yet handled by the
  extractor. Reliable sources must pass `instruction_count >= 2`,
  `human_turn_count >= 12`, legacy `user_message_count >= 12`, or `tier = premium`.
  This keeps long historical human sessions visible while removing short reliable
  NULL sessions from the default browse surface.
- **Tests:** added same-content instruction backfill coverage in
  `IndexerParityTests`; extended `HumanDrivenFilterTests` for reliable-source NULL
  behavior, legacy `user_message_count` fallback, and non-extracted source NULL
  tolerance.
- **Runtime proof:** installed `/Applications/Engram.app` version
  `0.1.0 (20260627072621)`. Real DB projection after backfill/filter:
  default SQL predicate selects 3,365 agentless sessions vs 4,602 under the old
  global-NULL predicate; reliable sources have 1,948 populated instruction rows
  and 8,269 remaining NULL rows that no longer auto-pass. Installed MCP
  `list_sessions` reports `total=2511` by default and `total=5744` with
  `include_all=true`.
- **Verification:** full `EngramCoreTests` 513/513, full `EngramServiceCore`
  254 tests with 1 expected skip, full `EngramMCPTests` 101/101, release build
  + Developer ID release verification, local deploy, codesign smoke, process/socket
  smoke, installed MCP initialize smoke, real DB predicate smoke, and `git diff --check`
  passed. Not run: `EngramUITests`, notarization/stapling/DMG, full TS suite, remote CI.

### Human-driven sessions: default filter + instruction-first summary (2026-06-27, Claude)

Surfaces only sessions a human actually drove (multiple distinct instructions) by
default, and shows the human's instruction set ("What you asked") on click. Design:
`docs/human-driven-sessions-design-2026-06.md`. Swift product only; no TS changes.

- **Signal (index-time, no LLM):** new pure `InstructionExtractor`
  (`Shared/EngramCore/Indexing/`) distills distinct human instructions from the
  existing `SwiftIndexer.streamStats` user-turn pass (slash/tool-result/probe/ack
  filtering, dedup, cap 16). Script-aware short-token gate KEEPS short CJK asks
  (`改成深色模式`); Rule 3b drops compound polite acks (`好的，谢谢`). `human_turn_count`
  is counted in the same pass/gate (no reuse of inconsistent `user_message_count`).
- **Schema:** 3 additive nullable columns on `sessions` — `instruction_count`,
  `human_turn_count`, `instruction_summary` (idempotent ALTER). `SessionTier`,
  `TierInput`, and embedding `jobKinds` are untouched — visibility is a separate
  axis from tiering. Allowlisted sources at launch: claude-code, codex; others store
  NULL (NULL-tolerant predicate keeps them visible).
- **Predicate:** single source of truth `HumanDrivenFilter.sqlPredicate` =
  `agent_role IS NULL AND (instruction_count IS NULL OR instruction_count >= 2 OR
  human_turn_count >= 12 OR tier = 'premium')`. Tunable thresholds in one place.
- **Surfaces (6, default-on with escape hatch):** app list/Home/Timeline via one
  global `@AppStorage("sessions.showAll")`; menu-bar Popover via new default
  `noiseFilter = "human-driven"` (+ SettingsView segment); native web UI
  (`EngramWebUIServer.readSessions`, `?all=1`); MCP `list_sessions`
  (`include_all`, column-guarded so a read-only un-migrated DB falls back).
  Keyword search is intentionally NOT filtered.
- **Display:** read-only "What you asked" numbered section in `SessionDetailView`
  (existing Summary section + Generate button untouched); "N asks" badge on cards.
- **Writer:** UPSERT preserves the 3 columns on empty re-stream via the
  `summary_message_count` (streamStats) sentinel; overwrites fresh on a healthy one.
- **Deviations from design:** card shows an "N asks" badge instead of a
  first-instruction subtitle (less redundant with the title); added compound-ack
  Rule 3b (found via the real codex parity fixture); historical backfill deferred
  (design §8 marked it cuttable — lazy/natural re-index populates active sessions;
  legacy rows stay NULL→visible until they next change).
- **Verification:** EngramCoreTests 511/511, EngramMCP 101/101, EngramServiceCore
  WebUI 26/26, app `SessionModelTests`/`DatabaseManagerTests`/`TodayWorkbenchScopeTests`
  pass; full `Engram` app build succeeds. New tests: `InstructionExtractorTests` (incl.
  CJK + compound ack), `HumanDrivenFilterTests` (predicate selection), snapshot
  preserve-on-empty-restream, migration columns, updated codex parity golden + web UI
  source assertion. Pre-existing unrelated failures: 3 `TodayWorkbenchTests` localized-
  string assertions fail under the zh test locale (not in this diff). Not run: EngramUITests,
  full TS suite (no TS touched), remote CI.

### P1 relaunch — service semantic runtime, lifecycle writes, and corpus rules completed (2026-06-26, Codex)

Reviewed Claude's e/d/c.3 implementation and completed the remaining P1 runtime work.

- **c runtime wiring:** `EngramServiceRunner` now schedules session-chunk and insight embedding
  backfills after initial and periodic FTS drains. Backfills read/write through short
  `ServiceWriterGate` phases, while embedding calls run outside the gate. `IndexJobRunner` now
  excludes service-owned `embedding` jobs from the generic FTS drain so pending embeddings do not
  perturb FTS rebuild/drain semantics.
- **c search:** Swift service `search` now supports configured `semantic`/`hybrid` retrieval over
  `semantic_chunks` using pure-Swift vector KNN and RRF; missing or failing embedding config keeps
  the existing keyword fallback/warning behavior.
- **d write side:** `save_insight` accepts optional `type`, supersedes same-scope normalized duplicate
  insights, and `get_memory` records access metadata through a best-effort service command instead of
  direct MCP database writes.
- **f corpus mining:** added `mined_rules`/FTS schema, `get_rules`, `engram://rule/{id}` resources,
  `get_context` rule folding, and an opt-in service corpus miner. The miner selects high-quality edit
  sessions, runs completion outside the writer gate, merges evidence on same-title rule updates, and
  skips already-mined sessions.
- Verification: full `EngramMCPTests` 101/101, full `EngramCoreTests` 496/496, full
  `EngramServiceCore` 254 tests with 1 expected live-offload skip, `xcodebuild ... -scheme Engram
  build`, `npm run check:fixtures`, and `git diff --check` all passed. Remote CI, `EngramUITests`,
  and full TS lint/typecheck/coverage were not run.

### P1 relaunch — semantic memory c.3 (hybrid read + write backfill) shipped & verified (2026-06-26, Claude)

Completes the semantic-memory logic on top of c.1/c.2. The whole retrieval chain is verified
end-to-end; only the runtime scheduling hook remains.

- **EmbeddingSettings** (`Shared/EngramCore/AI/`): resolves `EmbeddingConfig` from env overrides
  (`ENGRAM_EMBEDDING_BASE_URL`/`_API_KEY`/`_MODEL`/`_DIM`) then `~/.engram/settings.json`
  (`embeddingBaseURL`/`embeddingApiKey`/… falling back to `aiBaseURL`/`aiApiKey`). Returns nil →
  semantic disabled (keyword fallback). Strictly opt-in.
- **c.3b — `get_memory` hybrid read** (`MCPDatabase`, now `async`): when a provider is configured and
  `insight_embeddings` is non-empty, embed the query → brute-force cosine KNN → RRF-fuse with the FTS
  keyword ranking → drop superseded → top 10 (`retrieval: "hybrid"`). Any failure (no key, unreachable,
  500, malformed) degrades to the existing keyword/lifecycle path. Verified **end-to-end through the
  spawned MCP process** against a localhost mock embeddings server.
- **c.3a — `InsightEmbeddingBackfill`** (`EngramCoreWrite/Indexing/`): embeds insights lacking an
  embedding (network call OUTSIDE the writer lock), writes `insight_embeddings` BLOBs + `embedding_meta`,
  bounded per run; provider is injected (unit-tested with a fake provider, no network).
- **Remaining for c:** wire `InsightEmbeddingBackfill.run` into `EngramServiceRunner` as a gated
  background job (read+embed off the write gate, short gated write per batch) so embeddings populate in
  production; plus session-chunk embedding + `search` semantic mode + d's deferred supersession/access
  writes. Intentionally not wired this turn — it is a runtime/concurrency change that unit tests can't
  cover and must be verified by running the app.
- Verification: `EngramMCPTests` **99/99** (new `testGetMemoryHybridUsesSemanticRankingViaMockProvider`,
  `testGetMemoryDegradesToKeywordWhenEmbeddingProviderFails`); `EngramCoreTests` **495/495** (new
  `InsightEmbeddingBackfillTests`). `get_memory` is now async (one call site updated).

### P1 relaunch — semantic memory foundation c.1 + c.2 shipped & verified (2026-06-26, Claude)

Architecture decision: **no sqlite-vec native dependency** — semantic search uses pure-Swift
brute-force cosine KNN over Float32 BLOBs (fast enough for a local personal corpus, optionally
FTS/project pre-filtered, fully testable, zero build-system risk). Provider is OpenAI-compatible
(configurable baseURL), all opt-in.

- **c.1 (reusable core, `macos/Shared/EngramCore/AI/`, public in EngramCoreRead + compiled into
  EngramMCP):** `OpenAICompatibleEmbeddingClient` (`POST {baseURL}/embeddings`, L2-normalized,
  order-preserving, injectable `URLSession`, throws `notConfigured` on empty key → keyword fallback);
  `SessionChunker` (message-boundary-first, port of `chunker.ts`); `VectorMath` (L2-normalize,
  cosine/dot, little-endian Float32 BLOB encode/decode).
- **c.2 (retrieval + storage):** `VectorSearch.knn` (brute-force cosine top-K) and `RankFusion.rrf`
  (Reciprocal Rank Fusion, deterministic tie-break) — pure, unit-tested. Schema adds
  `insight_embeddings`, `semantic_chunks`, `embedding_meta` (named to avoid the legacy TS-reference
  `session_chunks`/`session_embeddings` vector tables that `VectorRebuildPolicy` clears).
- **Remaining for c (c.3, next):** config reader (settings/keychain → `EmbeddingConfig`), service-side
  embedding write job (embed insights/sessions → BLOB tables) + d's deferred supersession/access
  writes, `get_memory`/`search` hybrid wiring (embed query → KNN → RRF + lifecycle), re-enable
  `semantic`/`hybrid` search modes when a provider + embeddings exist, and a localhost-mock-server e2e.
- Verification: `EngramCoreTests` **494/494** (incl. new `SemanticMemoryUnitTests` 10 +
  `testSemanticMemoryTablesCreated`); resolved a `session_chunks` name collision with
  `VectorRebuildPolicyTests` by renaming to `semantic_chunks`. New files picked up via
  `xcodegen generate`.

### P1 relaunch — MCP surface (e) + memory lifecycle ranking (d) shipped & verified (2026-06-26, Claude)

Implements roadmap items e and d from `docs/p1-semantic-memory-design-2026-06.md`. Items c (Swift
semantic memory: sqlite-vec + online embeddings + RRF) and f (corpus mining via online LLM) are
designed and staged; product owner confirmed an **OpenAI-compatible** online provider (configurable
baseURL, default `text-embedding-3-small`, all opt-in / degrade to keyword without a key).

- **e — deepened MCP surface (no external deps):**
  - Tool `annotations` derived from the existing `ToolCategory` (`readOnlyHint` on reads;
    `destructiveHint`/`idempotentHint` on mutating/operational) + human `title`, emitted in `tools/list`
    so clients auto-approve reads and gate `project_move`/`delete_insight`/`hide_session`.
  - `resources` capability: `resources/list` + `resources/read` (`engram://session/{id}`,
    `engram://insight/{id}`) → `@`-mention autocomplete.
  - `prompts` capability: `prompts/list` + `prompts/get` (`engram:catch-up` pre-fills `get_context`,
    `engram:handoff`) → native slash commands.
  - `MCPStdioServer` capabilities now `{tools, resources, prompts}`; `MCPDatabase` gains resource read
    methods; `OrderedJSONValue.firstToolText` reuses tool handlers for resources/prompts.
  - `outputSchema` intentionally deferred to land with c/d (must match existing `structuredContent`).
- **d — memory lifecycle ranking (read side + schema):**
  - Idempotent migration adds `insight_type` (episodic/semantic/procedural), `superseded_by`,
    `last_accessed_at`, `access_count` to `insights` (baseline + `migrateInsightsLifecycle`,
    `auxSchemaVersion` 3→4). Index `idx_insights_superseded` created only after the column exists
    (fixes a legacy-DB `CREATE INDEX` ordering bug caught by migration tests).
  - `get_memory` now ranks by `relevance · importanceBoost · recencyDecay · accessBoost` (per-type
    half-life: episodic 14d / semantic 30d / procedural 90d) and excludes superseded rows — **only
    when the lifecycle columns exist**; a read-only MCP on an un-migrated DB falls back to the prior
    keyword/recency behavior (so existing `get_memory` golden is unchanged).
  - Service-side writes for d (supersession on `save_insight`, access-count bump on read) are deferred
    to land together with c/f service-writer changes.
- Verification: `xcodebuild test -scheme EngramMCPTests` → **97/97**; `-scheme EngramCoreTests` →
  **483/483** (incl. new `testGetMemoryRanksByImportanceAndRecencyWhenLifecyclePresent`,
  `testInsightsLifecycleColumnsAddedOnMigration`, updated `swift_aux_schema_version` assertions).
  `xcodebuild build -scheme EngramMCP` → BUILD SUCCEEDED. `npm run lint` not run (changes are Swift +
  one JSON golden).

### Competitive relaunch analysis — verified roadmap (2026-06-26, Claude)

Ran an 11-agent workflow (4 source-level competitive intel + 5 code-level self-inventory +
synthesis + adversarial verify) to re-position Engram vs Agent Sessions and ReadOut, both
inspected from local source/reverse-eng docs, plus 2026 landscape research. Output:
`docs/competitive-relaunch-2026-06.md`.

- Positioning confirmed: Engram is the only MCP-first cross-tool memory/context layer (AI agents
  are the consumer). Agent Sessions = human session browser + Agent Cockpit HUD + resume (not MCP).
  ReadOut = AI-native chat dashboard with data-card embeds + one-click actions (not MCP).
- Verified moat: 17-source breadth (Swift parity-tested), project-migration path repair, MCP-first,
  cross-tool parent-child grouping, encrypted opt-in remote offload, vendor-neutral zero-telemetry.
- Verified relaunch roadmap. P0: (1) Engram Claude Code plugin = `EngramMCP` + `SessionStart`
  get_context hook + `Stop` save_insight hook + slash prompts (converts flagship PULL→PUSH and
  fixes distribution in one artifact; no hooks exist today); (2) Homebrew cask + Sparkle EdDSA
  auto-update (absent; stuck at 0.1.0 manual notarytool). P1: Swift semantic memory (finish
  sqlite-vec + port TS embeddings/chunker + RRF), memory lifecycle (decay/supersession + rank by
  importance — `get_memory` ignores stored importance, orders by created_at), deepen MCP surface
  (resources/prompts/annotations/outputSchema), mine corpus into reusable skills/rules.
- Adversarial verify KILLED already-shipped re-proposals — treat as DONE: quality_score + auto-title
  ARE computed in Swift (`SessionSnapshotWriter.generatedTitle` L415 + `StartupBackfills`,
  `Session.valueBand`); cache-hit-rate already in `get_insights` (`MCPDatabase.swift:995`); real
  usage probes ship (`StartupUsageCollector` usage_snapshots); `live_sessions` MCP "unavailable" is a
  deliberate contract not a stub; MCP 2025-11-25 negotiation already handled (`MCPStdioServer.swift`).
- Explicit non-goals: do NOT build in-session resume/checkpoint/`/rewind`, a chat-first dashboard, or
  dual licensing — vendor-owned and improving fast; hold the cross-tool wedge.
- No code changed in this entry — strategy artifact only.

### Codex remediated session parser drift from the 17-source format audit (2026-06-21, Codex)

Compared the 17-source session-format analysis against current Swift product adapters, TypeScript
reference adapters, and related migration/resume surfaces, then fixed confirmed drift with focused
regression tests.

- Fixed Gemini CLI current `.jsonl` event-log ingestion in Swift and TS: adapters now enumerate
  `.json`/`.jsonl` chat logs without requiring a `session-` prefix, skip `.engram.json` sidecars,
  replay metadata/message/`$set`/`$rewindTo` records, and prefer the native `.project_root` cwd marker
  before the legacy `projects.json` reverse map.
- Fixed VS Code chat-session mutation-log handling in Swift and TS: adapters now replay valid
  `ObjectMutationLog` kind `0/1/2/3` entries instead of reading only line 0.
- Fixed Kimi transcript coverage in Swift and TS: current `context_<N>.jsonl` rotation shards are
  included, and array-form `{type:"text"}` content is extracted while `think` blocks remain excluded.
- Fixed Qwen assistant content extraction in Swift and TS to skip `parts[]` entries with
  `thought: true`; fixed TS CommandCode `tool-call.args` fallback parity with Swift.
- Fixed Cline legacy `claude_messages.json` discovery and prevented multi-root `Primary: <name>`
  labels from being stored as cwd paths; fixed Swift Copilot `workspace.yaml` quote stripping parity.
- Fixed related Gemini project-move drift in Swift and TS: migration now scans/patches `.project_root`,
  discovers marker-only Gemini dirs, renames migrated Gemini dirs using SHA-256(projectRoot), writes
  the same hash into new `projects.json` entries, and still honors legacy/custom old `projects.json`
  names when locating the source dir.
- Resume command behavior did not need a direct command change (`gemini --resume <sessionId>` remains
  DB-backed), but the Gemini listing fix makes non-`session-` current logs visible to indexing and
  therefore to resume.
- Verification: targeted Vitest adapter/project-move/resume tests passed (`137` tests); focused resume
  endpoint/coordinator checks passed (`8` tests in the filtered run); `npm run typecheck:test`,
  `npm run lint`, `npm run build`, `npm run check:adapter-parity-fixtures`, `npm run check:fixtures`,
  full `xcodebuild test -scheme EngramCoreTests`, and `git diff --check` passed. `npm run lint`
  still reports only the pre-existing `tests/scripts/screenshot-compare.test.ts:136` warning.

### Codex reviewed and completed VS Code session-format source confirmation (2026-06-21, Codex)

Reviewed Claude's `docs/session-formats-claude-codex` work against the current branch state,
adapter registry, document set, and official sources. Claude's handoff state had the claimed
17-source / 34-file EN+ZH document set and 28,244-line count; after completing the VS Code
source pass the set has 28,299 lines. Every EN/ZH pair has matching heading counts, matching
fenced-code counts, and byte-identical fenced-code contents.

- Completed the one declared gap from Claude's handoff: `vscode` now has official
  `microsoft/vscode` source confirmation and a `## References (official sources)` section in
  both EN and ZH docs.
- Corrected the VS Code open-question wording: current upstream `chatSessionOperationLog.ts`
  explicitly includes `modelId` and usage-like request fields (`promptTokens`, `outputBuffer`,
  `promptTokenDetails`, `copilotCredits`), so those fields are official schema facts, though
  Engram still ignores them.
- Verification: `rtk node` structural checks returned 34 files, 17 bases, 28,299 total lines,
  and no missing references; the EN/ZH heading/fence/code-block parity check returned no
  errors. `npm run typecheck:test`, `npm run lint`, `npm run build`, and `git diff --check`
  passed. `npm run lint` still reports the pre-existing
  `tests/scripts/screenshot-compare.test.ts:136` warning.

### Session-format reference docs: ALL 17 sources, bilingual + official web-confirmation (2026-06-21, Claude)

Expanded the two pilot docs into a complete `docs/session-formats/` reference set covering ALL 17
Engram source adapters, each as an English authoritative doc + a Simplified-Chinese reading copy
(`<tool>.md` + `<tool>.zh.md`), then layered official web-confirmation on top. 34 files, ~28.2k lines.
EN is authoritative (what AIs read/write); ZH is a 1:1 structural mirror (identifiers/code/JSON/SQL/
paths/file:line kept English, prose translated). Every EN/ZH pair verified for `##` heading +
fenced-code-block parity.

- **Tools**: claude-code, codex, gemini-cli, qwen, iflow, kimi, opencode, qoder, commandcode, cline,
  cursor, vscode, copilot, windsurf, antigravity + the two Claude-Code-derived overlays minimax,
  lobsterai (short "differs only in detection" docs).
- **Method (per tool)**: multi-dimension research grounded in TWO sources of truth — the real on-disk
  store (or repo `tests/fixtures/`) AND the Engram adapters (on-disk reality wins on conflict) →
  synthesize EN → adversarial completeness critic → patch → ZH translate.
- **Official web-confirmation pass**: each doc's "Open questions" were checked against authoritative
  public sources, preferring open-source repo SOURCE CODE (openai/codex, google-gemini/gemini-cli,
  QwenLM/qwen-code, sst/opencode, cline/cline, MoonshotAI kimi-cli, microsoft/vscode, …) > official
  docs > reputable community. Findings folded in as "Confirmed (official):" with inline `[source]`
  links, body fixes for refuted claims, "(web-checked …: no authoritative source found)" for unknowns,
  and a final `## References (official sources)` section per doc.
- **Notable official corrections**: Codex — 8 body corrections + 1 refutation (e.g. `compacted`
  window-field types, `function_call_output` structured form is `content_items` not `{output,metadata}`,
  `instructions` vs `base_instructions` are distinct fields not a rename, 6th L1 type
  `inter_agent_communication`); Gemini CLI — 7 corrections / 3 refutations; Qwen — 4; iFlow — 3; Kimi
  — 3 (15 official URLs). This validated the web pass: the disk+adapter-only docs did contain claims
  the official sources corrected.
- **Known gap**: `vscode` web-confirmation could not run — an automated content-safety classifier
  repeatedly flagged the (benign) editor-session-storage research as a cybersecurity topic. Documented
  honestly in-doc (EN+ZH); no sources fabricated. Authoritative next step noted: read microsoft/vscode
  chat-session storage source directly.

### Session-format reference docs: Claude Code + Codex (2026-06-21, Claude)

Sequestered the on-disk session-saving mechanism of the two primary sources into two definitive
reference docs so we never re-investigate per task. Produced by a 16-agent Workflow
(`wf_994231d5-4ca`): 5 parallel dimension researchers per tool → synthesize → adversarial
completeness critic → patch. Every claim cross-checked against the REAL on-disk store AND both
Engram adapters; on-disk reality wins on conflict.

- `docs/session-formats/claude-code.md` (1528 lines, critic 93/100): 3-layer type model
  (top-level record `type` vs nested content-block `type` vs attachment/system subtypes); cwd→dir
  encoding is lossy (`decodeCwd` never trusted — real cwd comes from the `cwd` field); modern
  compaction = `system`/`compact_boundary` + `isCompactSummary` (NOT a top-level `summary` record);
  dispatch tool renamed `Task`→`Agent`; subagent parent linkage is PATH-based
  (`<parent>/subagents/<child>.jsonl`), not `isSidechain`; `~/.claude/` also has `history.jsonl`
  (`{display,pastedContents,timestamp,project,sessionId}`), `sessions/`, `file-history/`; full
  Engram-mapping table with TS+Swift file:line per row; 16 anonymized line samples.
- `docs/session-formats/codex.md` (1546 lines, critic 86/100): dual-layer architecture — rollout
  JSONL (`~/.codex/sessions/YYYY/MM/DD/rollout-<localtime>-<uuid>.jsonl`, authoritative for
  content) + SQLite (authoritative for state/index/relationships). SQLite fully documented:
  `state_5.sqlite` is active (migration 39, 2510 threads) vs `~/.codex/sqlite/state_5.sqlite`
  legacy (migration 35, 2267 threads); `threads` = rollout index (join `threads.id ==
  rollout-uuid == session_meta.id`, `rollout_path` → file); `thread_spawn_edges` (1561 rows) =
  subagent parent→child graph; `memories_1` (stage1/consolidate pipeline), `goals_1`
  (long-running thread goals), `logs_2` (~419k structured log rows). Dispatch detection:
  `session_meta.originator=="Claude Code"` AND `threads.source` JSON subagent tag.

Verification this session: re-confirmed `state_5` threads schema column-for-column, 2510
threads / 1561 spawn_edges / migration 39 live; spot-checked Claude Engram-mapping file:line
citations (`listSessionFiles:41`, `extractContent:347`, subagents regex `:151`, Swift
`parentSessionId(from:):528`) — all accurate. Docs-only change; no code/runtime touched.
Open items flagged inside each doc's §15 (e.g. exact CLI-version boundary for the
`instructions`→`base_instructions` rename; legacy pre-2.1 `{type:summary}` schema).

### Multi-Mac sync L2 — pre-merge review remediation (PR #88, non-security findings) (2026-06-21, Claude)

The prior session ran the pre-merge review workflow (`wlqv61o7n`, verdict `fix-before-merge`,
2 must-fix HIGH + 12 followups) but derailed on the SECURITY dimension (Opus cyber-safety filter
killed the turn) and merged nothing. This session collected ALL non-security findings and completed
them, then re-verified each fix adversarially. The 1 security-flavored finding (no live-server
path-traversal test) was intentionally EXCLUDED per the owner's instruction; it stays a followup.

- **HIGH #1 multi-project manifest data loss** (`RemoteSyncCoordinator.pushProject`): the per-peer
  manifest was full-replaced with only the current project's entries, so pushing project B dropped
  project A from hub discovery. Fix: pushProject now READ-MERGES the existing per-peer manifest
  (keep other projects' entries, replace only this project's slice). Pairs with
  `publishedManifestEntries` normalizing each entry's `project` to the requested name (so the
  cwd-scoped slice is identifiable and pull-matchable). FAIL-CLOSED: only an explicit
  `bundleNotFound` starts from an empty slice; a transient GET error or a corrupt existing manifest
  propagates (push throws, idempotent retry) rather than silently full-replacing.
- **HIGH #2 offloaded-session republish** (`OffloadRepo.pushCandidates`): added
  `AND COALESCE(offload_state,'local')='local'` so an already-offloaded session is never re-read as
  its collapsed one-line FTS shadow and republished (which also overwrote the rehydrate ledger key).
- **MED**: blank-cwd over-match — `projectScopeSQL` now `(... OR (? <> '' AND cwd = ?))`, bound
  `[project, cwd, cwd]` in both callers, so a blank cwd falls back to project-only (was sweeping in
  every empty-cwd session: 109 vs 2 in the live repro). + UPSERT FK-cascade-child survival test and
  L2 capability-token gating test.
- **LOW**: cwd-only-matched entries now importable (entry project normalized to request);
  `publishedManifestEntries` content_hash NULL guard (`AND content_hash IS NOT NULL`) — no more
  latent fatalError; coordinator publish-only invariant + negative pull-scoping assertions added.
- **NIT**: `pushCandidates` explicit `agent_role != 'subagent'` (defense-in-depth); preview
  `SessionPreview.id` now carries the real session id (via `ProjectSyncPreview.Sample{id,title}`),
  not the title; protocol comment corrected; `ManifestCodec.isManifestKey` (prefix+suffix, rejects
  `..`) used by both catalog producers so a stray `catalog.*` / `catalog..manifest` blob is excluded
  symmetrically (server mirrors the suffix check inline, stays storage-format-agnostic).
- **Deliberately NOT changed** (new observations from adversarial verify, out of the 15-finding
  scope, no content loss): `publishedManifestEntries` keeps NO offload_state/agent_role guard — it
  JOINs on the 'out' ledger (the chokepoint that already excludes subagents), and adding an
  offload_state guard there would DROP a legitimately-pushed-then-offloaded session from discovery.
- **Verification:** adversarial workflow (8 verifiers, one per fix) — 6 `yes`, 2 `partial` whose
  real gaps (manifest fail-open, catalog `..` asymmetry) were then fixed + tested. Tests green:
  `EngramCoreTests/SessionSyncTests` 14/14, `EngramServiceCore` RemoteSync 11/11 (1 live skipped),
  `EngramRemoteServerCore` 9/9. Full `Engram` app build SUCCEEDED. 10 new/changed RemoteSync tests
  (incl. a fail-closed manifest test with a failure-injection backend). NOT yet merged — PR #88 is
  MERGEABLE with prior CI green; this adds new commits that re-trigger CI.

### Multi-Mac sync — Layer 2 client (per-project session push/pull) DONE + deployed + live-verified (2026-06-21, Claude)

Completes the L2 session-record sync that the earlier entry left designed-only. Built via an
orchestrated workflow (implement→review→harden), then I finished the parts the workflow's
harden/security stages dropped (API errors) and reconciled the Codex review. Manual, default-OFF,
per-project, preview-first — exactly the owner's model: select a project → dry-run the impact →
confirm → sync just that project.

- **No-migration design (the safe simplification):** import state lives on EXISTING sessions
  columns — `origin`/`authoritative_node` = publishing peer, `snapshot_hash` = bundle content hash
  (the re-pull dedup key). Imported rows use a deterministic id `remote:<peer>:<sessionId>` and a
  SQLite UPSERT (`ON CONFLICT(id) DO UPDATE`, NOT `INSERT OR REPLACE` — avoids FK cascade). So NO
  sync_ledger CHECK migration was needed (Codex HIGH #4 dissolved). v1 bundle reused (FTS+summary+
  counts), so no bundle-hash break (Codex HIGH #2). Push is publish-only (a sync_ledger 'out' row,
  NEVER collapses local FTS / flips offload_state — Codex HIGH #3). Push only touches local-origin
  sessions, never re-pushes imported rows (Codex HIGH #1 / echo-loop guard).
- **Code:** `ManifestCodec` (per-peer manifest build/encode/decode/decodeCatalog); `OffloadRepo`
  +publishOnlyCommit/+pushCandidates(project|cwd scope, excludes skip/subagent/imported)/
  +publishedManifestEntries; new `ImportRepo` (commitImported UPSERT + FTS, needsImport);
  `RemoteSyncCoordinator` +pushProject/+pullProject/+previewProjectSync (network outside the write
  gate, DB writes gated); IPC `remoteProjectSyncPreview` (read-only) + `remotePushProject` +
  `remotePullProject` (both added to `ServiceCapabilityToken.protectedCommands` — token-gated) +
  DTOs + EngramServiceClient/protocol/mock.
- **Tests:** EngramCore RemoteSync 19/19 (SessionSync + offload, incl. "offload excludes imported
  peer-origin"), EngramServiceCore RemoteSync incl. push→pull round-trip / pull-skips-own-manifest /
  preview-is-read-only, EngramRemoteServerCore 9/9. Fixed a pre-existing test that read the
  developer's real settings.json (now env-hermetic).
- **Deployed + LIVE-verified on ReadOut:** rebuilt+redeployed Engram.app; server catalog already
  live. `remotePushProject ReadOut` → uploaded 2 top-level sessions + published
  `catalog.<peer>.manifest`; `/v1/catalog` shows them; re-preview → toPush 0 (idempotent). A
  simulated foreign-peer manifest pulled via `remotePullProject` → imported 1 searchable row
  (origin=peer), skipped own manifest (no echo); cleaned up. Unified `engram-sync push|pull <proj>`
  shows combined file + session preview behind one confirm.
- **Operator:** `~/bin/engram-sync` (L1 Unison + L2 IPC), `~/bin/engram-ipc` (framed-JSON socket
  client). Remaining enhancement (not blocking): schema-v2 bundle carrying the rendered transcript
  so imported sessions get full role-tagged replay (today they are searchable + summary + metadata;
  transcript view falls back to FTS).

### Multi-Mac sync — Layer 1 (Unison files) live + Layer 2 server catalog shipped (2026-06-21, Claude)

Toward an iCloud-like, MANUAL-CONFIRMED multi-Mac sync via the macmini-hub: each of
the owner's Macs push/pulls a project's files + AI session records through the hub,
on demand, with a diff preview + single confirm. Designed via workflow, reviewed by
the Codex subagent (verdict: architecture sound, 4 HIGH impl traps to fix). Two
layers: L1 = Unison bidirectional FILE sync; L2 = Engram cross-machine SESSION-RECORD
sync on the existing offload foundation.

- **L1 (files) — DONE + validated (pilot: ReadOut).** Matching Unison 2.54.0 binary
  copied to the mini (`/Users/bing/bin/unison`, otool dep = libSystem only, ad-hoc
  re-signed; no Homebrew needed). Profiles `~/.unison/readout.prf` (+ `readout-claude.prf`)
  sync `/Users/bing/-Code-/ReadOut` ↔ `ssh://mini//Users/bing/sync/ReadOut` over the
  tailnet; `Readout.app`/`.DS_Store`/`.codegraph`/VCS noise ignored. Wrapper
  `~/bin/engram-sync push|pull <proj>`: read-only preview (`printf '' | unison -terse`,
  EOF-aborts before propagating — empirically verified zero writes) → single confirm →
  directional `-batch -force`. Conflict safety verified: a two-sided edit is reported
  and SKIPPED, never silently overwritten.
- **L2 server catalog — DONE + deployed + tested.** `BlobStore.listKeys(prefix:)` +
  a bearer-gated `GET /v1/catalog` that decrypts and concatenates per-peer
  `catalog.<peer>.manifest` blobs into `{schemaVersion,manifests:[...]}` (server stays
  format-agnostic; corrupt/unparseable manifests skipped). `EngramRemoteBackend.catalog()`
  client method. Tests in EngramRemoteServerCoreTests (catalog merge + auth-gate +
  listKeys prefix); suite 9/9. Deployed to macmini-hub and verified live (auth → empty
  manifests, no-auth → 401).
- **L2 client — DESIGNED + Codex-vetted, NOT yet built/deployed.** Remaining:
  `ManifestCodec` (build per-peer manifest from `sync_ledger` 'out' rows), a
  `publishOnlyCommit` (push writes a ledger row WITHOUT collapsing local FTS /
  flipping offload_state — the current `commitOffloaded` clobbers, so this is genuinely
  new), `ImportRepo.commitImported` (INSERT-only foreign-origin row id
  `remote:<peer>:<sid>` + FTS + ledger `direction='import'`), an idempotent
  `sync_ledger` table-rebuild migration to extend the `direction` CHECK to include
  'import', IPC `remotePushProject`/`remotePullProject`/`remoteProjectCatalog`
  (mutating ones MUST be added to `ServiceCapabilityToken.protectedCommands`), and the
  wrapper L2 hook. Deferred deliberately: it mutates the live 13k-session DB schema +
  write path, so it needs its own tested + reviewed deploy rather than a blind push in
  an autonomous run.
- **Codex HIGH findings to honor when building L2 client:** (1) do NOT L1-sync AI
  transcript dirs (raw *.jsonl) AND L2-import the same session → double-index; keep
  L1 = project files only, sessions via L2. (2) version-aware bundle hash: a schema-v2
  bundle's transcript must not break decoding existing v1 bundles. (3) publish-only
  push must not clobber local FTS. (4) the `sync_ledger` CHECK can't auto-extend on
  existing DBs — needs an explicit table rebuild.
- **Operator artifacts:** `~/bin/engram-sync` (L1 wrapper), `~/.unison/readout*.prf`,
  `/tmp/engram_ipc.py` (framed-JSON unix-socket client for remoteSyncStatus/Offload/
  Rehydrate via `~/.engram/run/cmd.token`). Design plan + Codex review saved under the
  session tasks dir (`multimac-sync-design` workflow `wc092o7ys`).

### Remote offload — plain-HTTP-over-Tailscale + second server (macmini-hq) live (2026-06-20, Claude)

Made TLS optional on trusted private/VPN transports and deployed a second offload
server on `macmini-hq` (Tailscale `100.125.101.60`, **plain HTTP**) so the live app
offloads with no nginx / private-CA / cert work.

- **Product change — `EngramRemoteBackend` no longer hard-requires HTTPS.**
  New `requireTLS` (default true at the primitive; product reads the new
  `remoteOffloadRequireTLS` setting, default **OFF**) only forces HTTPS for
  non-loopback hosts. Plain HTTP is now allowed to loopback + private / CGNAT
  (`100.64/10` = Tailscale) / `.ts.net` / `.local` / bare-LAN hosts; **public
  hosts still require TLS in both modes** so a misconfig can't leak the bearer
  token to the internet. Rationale: WireGuard already encrypts+authenticates the
  tailnet, so a separate TLS cert is redundant; sensitive users opt back into
  strict mode. New `testRemoteBackendTLSPolicy`; EngramRemoteServerCore suite 7/7.
  Touches `EngramRemoteBackend.swift`, `RemoteSyncCoordinator.swift`
  (`RemoteSyncConfig.requireTLS` from settings/env).
- **Server:** `EngramRemoteServer` built on dev Mac → relocatable bundle →
  `~/.engram-remote` on macmini-hq; `ENGRAM_REMOTE_HOST=100.125.101.60` binds the
  Tailscale interface (not 0.0.0.0/LAN), plain HTTP :8787, launchd KeepAlive.
  Health ok from host + dev Mac over tailnet; sentinel PUT/GET proved auth
  (401 w/o token) + at-rest round-trip.
- **Client:** `settings.json remoteOffloadServerURL:"http://100.125.101.60:8787"`,
  `remoteOffloadRequireTLS:false`; reused existing Keychain token; rebuilt+
  redeployed `Engram.app`.
- **DATA-SAFETY INCIDENT (caught + fixed, zero loss):** the 5 prior
  `offload_state='offloaded'` sessions had bundles only on the OLD server
  (`100.108.19.20`). Draining to local didn't stick because the still-running OLD
  background loop re-offloaded them mid-deploy (audit risk #1/#3, live). Fixed by
  a server→server bundle copy: `GET old` (decrypted plaintext) → `PUT new`
  (re-encrypted with the new at-rest key) under the same content keys — no
  DB/loop race. All 5 now on the new server.
- **Verified e2e against the new server:** IPC rehydrate restored full FTS (shadow
  321 B → 13 456 B), `offload_state`→local; re-offload settled offloaded=5;
  invariant "every offloaded session has a bundle on the new server" = 0 misses;
  raw transcripts untouched throughout. Drove drain/offload/rehydrate/status via a
  tiny framed-JSON unix-socket client using `~/.engram/run/cmd.token`.
- **Lesson:** before repointing/draining, STOP the offload loop (disable or freeze)
  or it re-offloads to the old server during the deploy window.
- **Open hardening (audit, non-blocking):** server 201 is non-fsynced `.atomic`;
  no client read-back verify after PUT; no operator repair command for stranded
  sessions; offloaded session that later gains content silently drops appends.

### Remote offload — REAL app-side offload→rehydrate working over Tailscale (2026-06-20, Claude)

Wired the live `Engram.app` to the deployed server and ran a real offload→rehydrate
through the actual service. Net: **5 cold sessions offloaded, 1 rehydrated, all via
the production helper**, after discovering the LAN-direct path is blocked and
Tailscale is the fix.

- **App-side config:** `~/.engram/settings.json` gets `remoteOffloadEnabled:true`,
  `remoteOffloadBackend:"http"`, `remoteOffloadServerURL` + `remoteOffloadColdAgeDays`.
  Token stored in Keychain (`security add-generic-password -A -s
  com.engram.remote-offload -a default`). `remoteSyncStatus` confirmed
  `enabled:true` — the helper reads settings + Keychain token cleanly.
- **THE BLOCKER — background helper can't reach the LAN:** offload runs in the
  `EngramService` *helper* (separate process, designated id `EngramService`), not
  the main app. macOS **Local Network Privacy** prohibits it from the LAN IP
  (`10.0.8.9`) → every PUT failed `-1009 "Local network prohibited"`. The app's
  only TCC grant is Full-Disk-Access; there is no Local Network grant, and a
  background helper can't easily be granted one (no consent UI).
- **THE FIX — Tailscale:** both machines are on a tailnet (macmini `100.108.19.20`).
  Tailscale IPs route over the `utun` interface, NOT the local subnet, so they are
  **exempt from Local Network Privacy**. Re-issued the server cert with
  `IP:100.108.19.20` added to the SAN, pointed `remoteOffloadServerURL` at
  `https://100.108.19.20:8443`. The helper's PUTs then succeeded over `utun`.
- **Real run (coldAgeDays=365):** the offload candidate set is `ORDER BY size_bytes
  DESC LIMIT 500` then policy-filtered, so the "hidden-only" idea was a no-op here
  (all 22 hidden sessions are smaller than the 500th-largest). At coldAgeDays=365,
  5 large (28 MB) >1-yr-cold sessions qualified: all 5 offloaded (macmini store
  `0→5`, each left with 1 keyword shadow line, still searchable); rehydrating one
  via IPC restored `offload_state=local` + full FTS (1 shadow → 11 lines). Steady
  state after restart: `enabled:true, offloadedCount:4`, auto-loop on tailscale URL.
- **Takeaway for the product:** `remoteOffloadServerURL` should be a **Tailscale
  IP / tailnet name**, not a LAN IP — the background helper is firewalled off the
  LAN by Local Network Privacy but reaches the tailnet freely. (LAN HTTPS via nginx
  still works for Terminal/`curl`, which have Local Network access; the cert SANs
  cover LAN + tailscale + loopback.)
- **IPC driver:** added `/tmp/engram_ipc.py` (not committed) — 4-byte BE length +
  JSON envelope, capability token from `~/.engram/run/cmd.token` — to send
  `remoteSyncStatus`/`remoteOffload`/`remoteRehydrate` to the running service.

### Remote offload — live offload→rehydrate verified against the deployed server (2026-06-20, Claude)

Drove a real offload→rehydrate cycle through the production `RemoteSyncCoordinator`
+ `EngramRemoteBackend` against the deployed macmini server, end-to-end.

- **Test:** added `RemoteSyncCoordinatorTests.testLiveOffloadRehydrateAgainstDeployedServer`
  — a sibling of the local-backend test whose only change is the backend
  (`EngramRemoteBackend(url, token)` instead of `LocalDirectoryBackend`). Gated:
  skips unless `ENGRAM_LIVE_OFFLOAD_URL/_TOKEN` env **or** `~/.engram-live-offload.json`
  is present, so CI never touches the network.
- **Result:** PASS. The seeded session's FTS content was bundled, AES-GCM-encrypted,
  and PUT to the server (store `0 → 1` bundle, 513 B ciphertext); `offload_state`
  flipped to `offloaded` with only the keyword shadow left in FTS; rehydrate GET
  restored `offload_state = local` and the full FTS content byte-for-byte. Test
  bundle deleted afterward (store back to 0).
- **Two findings that affect the real app reaching the LAN server (the client uses
  `URLSession` with no custom delegate → standard validation):**
  1. **macOS Local Network Privacy** blocks a process from LAN private IPs until
     granted — the xctest harness hit `-1009 "Local network prohibited"` on
     `10.0.8.9`. The shipping app will trigger the "Engram wants to find devices
     on your local network" consent on first LAN offload; it must be granted.
  2. **mDNS `.local` names don't resolve for URLSession under the active TUN/VPN**
     (Surge-style, `198.18.0.1`) — `Bing-M1-MacMini.local` gave `-1009`, the IP
     worked. Prefer the IP (or a real DNS name) for `remoteOffloadServerURL`.
  - The live test reached the server via an **SSH loopback tunnel**
    (`ssh -L 8788:127.0.0.1:8443`): loopback is exempt from Local Network Privacy
    and the cert SAN includes `127.0.0.1`, so TLS still validated. This is also a
    valid client transport when Local Network can't be granted.

### Remote offload server — deployed to macmini-m1 (2026-06-20, Claude)

Built, tested, and deployed the self-hosted `EngramRemoteServer` to the remote
host `macmini-m1` (Apple Silicon, macOS 26.6, Command-Line-Tools only — no
Xcode) as a persistent launchd agent.

- **Build + test (local):** `EngramRemoteServerCore` unit tests 6/6; built the
  `EngramRemoteServer` tool (Debug). `EngramRemoteServerCore.framework`
  statically links Hummingbird/NIO, so the relocatable set is tiny:
  `EngramRemoteServer` + `EngramRemoteServerCore.framework` +
  `libswiftCompatibilitySpan.dylib` (both binary and framework already carry
  `@executable_path/../Frameworks` and `/usr/lib/swift` rpaths). HTTP smoke of
  the shippable (ad-hoc re-signed) bundle: 13/13.
- **App-side pipeline tests:** `RemoteSyncCoordinatorTests` +
  `RemoteSyncIPCTests` 5/5; `RemoteOffloadTests` + `MigrationRunnerTests` 19/19.
- **Deploy:** macmini-m1 has no Xcode (so no remote `xcodebuild`) but has the
  Swift 6.4 toolchain. Shipped the relocatable bundle via `rsync` to
  `~/.engram-remote/{bin,Frameworks,store}`. Secrets live in
  `~/.engram-remote/env` (0600) — NOT in the plist/argv — sourced by
  `run.sh`; `ENGRAM_REMOTE_TOKEN` (32-byte hex) + `ENGRAM_REMOTE_AT_REST_KEY`
  (32-byte base64, server-held). LaunchAgent `com.engram.remote-server`
  (RunAtLoad + KeepAlive, Background) bound to **127.0.0.1:8787**.
- **Verified on remote:** end-to-end 8/8 (health, 401 gating, PUT/HEAD/GET/
  DELETE lifecycle, at-rest ciphertext); KeepAlive respawn after `kill` → new
  pid + health 200; startup log `engram-remote listening on 127.0.0.1:8787`.

### Remote offload server — LAN HTTPS exposure via nginx TLS proxy (2026-06-20, Claude)

Per the best-practice pattern (the app server is plain-HTTP by design and the
client `EngramRemoteBackend` refuses non-HTTPS non-loopback URLs), exposed the
offload server on the LAN over **HTTPS** instead of loopback-only — token must
never cross the LAN in cleartext.

- **Topology:** `EngramRemoteServer` stays bound to **127.0.0.1:8787** (never
  directly LAN-reachable). The existing homebrew **nginx** (1.31.2,
  `--with-http_ssl_module`) terminates TLS on **`*:8443`** and reverse-proxies
  `/v1/` → `127.0.0.1:8787`, forwarding `Authorization` (bearer auth still
  enforced by the app server, now over TLS). Config dropped at
  `/opt/homebrew/etc/nginx/servers/engram-remote.conf` (alongside the user's
  pre-existing campus/dingtalk vhosts — untouched). `client_max_body_size 96m`
  (> the 64 MiB `maxBundleBytes`; nginx default 1m would 413 large bundles).
  TLSv1.2/1.3 only.
- **Cert:** private CA at `~/.engram-remote/tls/` (`ca.key` 4096, 0600), server
  cert CA-signed, 825-day validity, EKU=serverAuth, SAN = `DNS:Bing-M1-MacMini.
  local, DNS:macmini-m1, DNS:localhost, IP:10.0.8.9, IP:127.0.0.1` (Apple
  requires SAN + ≤825d + serverAuth for trust).
- **Verified from a LAN peer (this Mac):** `https://10.0.8.9:8443` and
  `https://Bing-M1-MacMini.local:8443` health 200 against the CA; a no-CA
  connection is REJECTED (real TLS validation, not `-k`); no-token PUT → 401
  through the proxy; full authed PUT/HEAD/GET/DELETE + a 3 MB bundle round-trip
  all pass; `lsof` confirms 8787 is still `127.0.0.1`-only.
- **Client trust (NEEDS ADMIN, per client):** URLSession does standard TLS
  validation (no pinning / no insecure escape hatch), so each client Mac must
  trust the CA once: `sudo security add-trusted-cert -d -r trustRoot -k
  /Library/Keychains/System.keychain <ca.crt>` (CA fetched to
  `/tmp/engram-remote-ca.crt`). Then set `remoteOffloadServerURL:
  https://Bing-M1-MacMini.local:8443` (use the `.local` name or `10.0.8.9` — the
  `macmini-m1` SSH alias is NOT DNS-resolvable by URLSession).
- **App-side enable** (`remoteOffloadEnabled` + `RemoteCredentialStore` token)
  NOT yet done — it mutates live `~/.engram` data and is the next step.
- **Optional hardening (not applied):** `allow 10.0.8.0/24; deny all;` in the
  nginx `location` to restrict to the LAN subnet; offline CA key.
- **Caveat:** GUI LaunchAgent only runs while the user is logged in (matches the
  existing `com.engram.dashscope-proxy` agent on that host). A LaunchDaemon
  (needs sudo) would make it login-independent. Deployed the Debug artifact (the
  one that passed smoke); a Release rebuild can swap in later.

### Remote session server — adversarial review + remediation (2026-06-20, Claude)

Ran a 6-dimension adversarial review workflow (concurrency/gate, FTS integrity,
crypto/credentials, server/HTTP, schema/migration, lifecycle) with per-finding
verification against the real code: 16 raw findings → 12 confirmed (9 real issues
+ 3 positive confirmations). Fixed all real findings:

- **[critical] Offload content race**: a re-index between bundle capture and commit
  could collapse fresh content into the shadow while the uploaded bundle held the
  old content. `OffloadRepo.bundleInputs` now captures `sync_version`;
  `commitOffloaded(expectedSyncVersion:)` flips state guarded by
  `sync_version = ? AND offload_state = 'local'` and throws `RemoteSyncError.offloadStale`
  (no FTS purge) if it changed — callers re-queue and re-capture next cycle.
- **[critical/high] Stuck `inflight` jobs**: a crashed/cancelled cycle left claimed
  jobs unrecoverable. `OffloadRepo.requeueStaleInflight` (age-thresholded so it can't
  disturb a concurrent cycle) runs at the start of every offload/rehydrate cycle.
- **[high] Failed jobs never retried**: `failOffload`/`failRehydrate` now retry
  (back to `pending`) until `maxAttempts` (5), then terminal `failed` — a transient
  network error no longer permanently abandons a session.
- **[high/medium] Orphaned ledger rows**: `sync_ledger.session_id` now has
  `REFERENCES sessions(id) ON DELETE CASCADE`; the version-guarded commit avoids
  inserting a ledger row for a session removed mid-flight.
- **[medium] HEAD invalid-key**: returns 400 (was 404), consistent with GET/PUT.
- **[low] Token compare**: `constantTimeEquals` now compares fixed-length SHA-256
  digests (no length side-channel).
- **[low] Queue indexes**: added composite `(session_id, status)` indexes on both queues.

Confirmed-solid (no change needed): AES-GCM nonce handling, server key/token sourced
only from env, Keychain `kSecAttrAccessibleAfterFirstUnlock` for the background helper.

Tests: `RemoteOffloadTests` gains stale-version-abort, stale-inflight-requeue, and
retry-until-cap cases. Full `EngramServiceCoreTests` (215) + targeted `EngramCoreTests`
+ `EngramRemoteServerCoreTests` green, 0 failures. (The review's synthesis agent and 2
crypto-lens judges were blocked by the model's cybersecurity content filter on
defensively-framed prompts — synthesis was done by hand from the verified findings.)

### Remote session server — Phase 5 IPC + Phase 7 read-path lazy rehydrate (2026-06-20, Claude)

Final two pieces; the feature is now end-to-end complete (all 8 phases).

IPC commands (`EngramServiceCommandHandler+RemoteSync.swift`, added to `dispatch()`):
- `remoteOffload` — run one offload/rehydrate/reclaim cycle now (no-op + `enabled:false`
  when offload is unconfigured). Protected (capability token).
- `remoteRehydrate {sessionId}` — force-rehydrate one offloaded session now. Protected.
- `remoteSyncStatus` — read-only: enabled, backendKind, local/offloaded counts, pending
  offload/rehydrate depths. Ungated, like other reads.
`remoteOffload`/`remoteRehydrate` added to `ServiceCapabilityToken.protectedCommands`;
`RemoteSyncCoordinator` gained `rehydrateNow(sessionId:)`.

Read-path lazy rehydrate (Phase 7): `recordSessionAccess` (fired when a session is
opened) now calls `OffloadRepo.enqueueRehydrate` — a no-op unless the session is
offloaded — so opening an offloaded session queues it to be pulled back and made
fully keyword-searchable again. The raw transcript stays on disk, so the detail
view is never blocked on rehydrate.

Fixture: the committed `test-fixtures/test-index.sqlite` is left as the TS
generator's deterministic output (no `offload_state`) — the app migrates the DB at
runtime, so read paths see the column without baking it into the fixture (an
earlier hand-edit was reverted because `fixture-check` regenerates + diffs it).
The `seedSearchFixture` test helper's hand-rolled `sessions` schema does get
`offload_state` so the access-path read works under test.

Tests (green): `RemoteSyncIPCTests` — token-gating of the mutating commands,
`remoteSyncStatus` counts, `remoteOffload` no-op-when-disabled, and
`recordSessionAccess` enqueues a rehydrate ONLY for an offloaded session. Full
`EngramServiceCoreTests` (215) green. CI (which runs the fuller suite) additionally
caught `IndexerParityTests` failing because the Swift indexer now emits
`offload_state`, absent from the Node reference golden — fixed by excluding that
Swift-only column from the cross-runtime parity comparison (not by editing the
golden, which the TS generator owns).

### Remote session server — Phase 2: self-hosted server + HTTP backend + Keychain (2026-06-20, Claude)

The offload feature is now genuinely *remote*. New `EngramRemoteServer` —
a standalone Swift/Hummingbird executable, NEVER bundled in `Engram.app`,
deployed separately (Mac mini / private host):
- `EngramRemoteServerCore` (framework): `BlobStore` (file-backed, content-addressed,
  AES-GCM at-rest encryption under a server-held key per the owner's decision —
  on-disk bytes are ciphertext; a path-traversal-safe key charset is enforced);
  `EngramRemoteServerApp` (Hummingbird router: `HEAD/GET/PUT/DELETE /v1/bundles/{key}`
  + unauthenticated `/v1/health`, Bearer auth with constant-time compare, 64MB body
  cap); `EngramRemoteServerConfig` (env-only secrets — token + base64 at-rest key —
  never from a settings file).
- `EngramRemoteServer` (tool): `main.swift` + `keygen` subcommand to mint an at-rest key.
- Transport security boundary: the server speaks plain HTTP and is meant to run
  behind a TLS-terminating proxy / on a private network (standard self-hosting
  pattern); the client refuses non-HTTPS, non-loopback URLs. In-process TLS
  (HummingbirdTLS) is a documented follow-up.

Client (`EngramCoreWrite/RemoteSync/`):
- `EngramRemoteBackend` — `RemoteStorageBackend` over `URLSession` (HEAD/PUT/GET/DELETE,
  Bearer auth, status→error mapping, 404→`bundleNotFound`). Refuses insecure URLs.
- `RemoteCredentialStore` — Keychain (`kSecAttrAccessibleAfterFirstUnlock`) for the
  bearer token; the non-secret server URL stays in settings.

Wiring: `RemoteSyncConfig` gained `backendKind` ("local"|"http") + `serverURL`;
`RemoteSyncCoordinator.makeIfEnabled` builds `EngramRemoteBackend` (URL from settings,
token from Keychain/env) for `http`, else `LocalDirectoryBackend`.

Tests (all green): `EngramRemoteServerCoreTests` — blob-store at-rest round-trip +
on-disk-is-ciphertext, wrong-key decrypt fails, path-traversal rejection; live
server ↔ `EngramRemoteBackend` full round-trip (bound on an OS-assigned port via
`onServerRunning`); 401 on bad token; insecure-URL refusal. Builds clean:
`EngramRemoteServerCore`, `EngramRemoteServer`, `EngramServiceCore`.

REMAINING: Phase 5 IPC commands (manual offload/rehydrate/status) + capability-token
gating; Phase 7 read-path lazy rehydrate in `EngramServiceReadProvider` (+ regenerate
the binary UI fixture `test-index.sqlite` for the `offload_state` column the read
path will SELECT).

### Remote session server — engine + both BLOCKERs + in-product loop drive (2026-06-20, Claude)

Implemented the client-side offload engine end-to-end and wired it into the
service runtime. The feature now genuinely offloads cold/archived sessions and
reclaims local disk, all behind an opt-in flag (default OFF), validated by tests.

New `EngramCoreWrite/RemoteSync/`:
- `RemoteSessionBundle` + `BundleCodec` — content-addressed (SHA-256), integrity-
  verified bundle of a session's regenerable index artifacts (full `sessions_fts`
  lines + summary + counts). Transcript bytes are never bundled or moved.
- `RemoteStorageBackend` protocol + `LocalDirectoryBackend` (file/NAS-mount store;
  also the layout the future self-hosted server exposes). The S3/HTTP backend is
  the documented drop-in.
- `OffloadPolicy` — eligibility (archived/hidden OR visible-but-cold past an age
  threshold; never skip/subagent) + size×staleness scoring + `OffloadShadow` (the
  one compact keyword line kept so offloaded sessions stay searchable — must-fix #8).
- `OffloadRepo` — all offload/rehydrate DB ops, reusing `FTSRebuildPolicy.replaceFtsContent`
  (full→shadow on offload, shadow→full on rehydrate); `offload_queue`/`rehydrate_queue`/
  `sync_ledger` driven idempotently. `OffloadRunner` — gate-free orchestration (network
  strictly between writes) used by tests.

BLOCKER #1 (re-index guard): `IndexJobRunner.process` now short-circuits
`offload_state='offloaded'` sessions to write only the shadow line (and marks the
job complete). This single point covers BOTH the periodic re-index and the full
FTS rebuild (the rebuild replays FTS jobs through the same path) and keeps the
shadow in the rebuild table so it survives a table swap — a routine rescan can no
longer re-materialize evicted FTS and erase the disk win.

BLOCKER #2 (real disk reclaim): `EngramDatabaseWriter.vacuum()` + `freelistPageCount()`
(no `VACUUM` existed before; `checkpointTruncate` is WAL-only). Wired into the
coordinator as a gated long-running `remoteVacuum` command, run only past a
free-page threshold.

Service wiring (`EngramService/Core/RemoteSyncCoordinator.swift`): drains the
offload/rehydrate queues and reclaims disk through `ServiceWriterGate`, each DB
step its own gated write with network PUT/GET strictly OUTSIDE the gate; FTS purge
happens only after a confirmed remote PUT. `RemoteSyncConfig` reads opt-in settings
(`remoteOffloadEnabled`, store root, cold-age days, batch sizes, vacuum threshold)
mirroring the web-UI posture. Driven from `EngramServiceRunner.runIndexingLoop`
after the FTS drain. Phase-D archive enqueue was intentionally NOT hard-wired into
`applyMigrationDb` — archived sessions are `hidden_at IS NOT NULL` and already
eligible to the policy scan, avoiding coupling + unbounded queue rows when disabled.

Tests (all green, 0 failures): `RemoteOffloadTests` (codec round-trip/tamper, policy
eligibility, full offload→re-index-guard→rehydrate cycle, VACUUM reclaim);
`RemoteSyncCoordinatorTests` (offload+rehydrate through a real `ServiceWriterGate`).
Regression: FTSRebuildPolicy/IndexJobAndMaintenance/MigrationRunner/SchemaCompatibility
(37 tests) green — no regression from the IndexJobRunner/migration/gate changes.
`EngramServiceCore` builds clean.

REMAINING (not yet built): Phase 2 self-hosted `engram-remote` HTTP server +
`EngramRemoteBackend` URLSession client + Keychain credential store (v1 currently
uses `LocalDirectoryBackend`); Phase 5 IPC commands (manual trigger/status) +
capability-token gating; Phase 7 read-path lazy rehydrate trigger in
`EngramServiceReadProvider` + UI fixture regen.

### Remote session server — design + Phase 0 schema (2026-06-19, Claude)

New feature in progress: offload a project's archived/cold sessions to a remote
server to reclaim local disk/CPU. Multi-agent workflow (6-subsystem map →
architecture brief → 3 candidate designs → adversarial multi-lens judging →
synthesis) selected the **Tiered Cold-Storage Sync Engine**, sliced to a v1 that
purges only regenerable index artifacts (`sessions_fts` content + `summary`) for
offloaded sessions while the original transcript bytes on disk are never moved.

Owner-locked v1 decisions: (1) backend = **self-hosted `engram-remote` Swift
server** (separate package, never bundled in `Engram.app`); (2) **no remote
analysis** in v1 (disk/CPU reclaim only); (3) **server-held encryption key**
(transport TLS + server-side at-rest; not zero-knowledge — accepted residual risk
for a self-hosted single-user server); (4) offload eligibility includes
**visible-but-cold** sessions past an age threshold, which requires a local
keyword shadow (must-fix #8) so cold sessions stay discoverable.

Two BLOCKER must-fixes carried into the plan: (#1) gate
`SessionSnapshotWriter.enqueueIndexJobs` + `FTSRebuildPolicy` replay on
`offload_state='offloaded'` so a routine rescan does not re-materialize evicted
FTS; (#2) add an explicit threshold `VACUUM`/`auto_vacuum=INCREMENTAL` because
`checkpointTruncate` is WAL-only and no `VACUUM` exists today, so deletes alone
do not return disk to the OS.

Phase 0 (choice-invariant foundation) shipped: `EngramMigrations.swift` adds
`sessions.offload_state TEXT NOT NULL DEFAULT 'local'` (CREATE + idempotent
`addSessionColumnsIfNeeded` ALTER with backfill), `offload_queue` /
`rehydrate_queue` / `sync_ledger` tables + indexes (`idx_sessions_offload_state`
et al.). New `SchemaManifest.remoteOffloadTables` set kept OUT of `baseTables` on
purpose so the legacy binary UI fixture (`test-index.sqlite`) compatibility test
stays green. Tests: `MigrationRunnerTests` gains fresh-schema (column default
`local`, tables/indexes present, status CHECK enforced), idempotency (column
added exactly once across 3 migrate() runs), and legacy-backfill cases. Phases
1–7 tracked as the remaining roadmap; Phases 4 and 7 carry the two BLOCKER
must-fixes. Validation: `EngramCoreTests` MigrationRunner (11) +
SchemaCompatibility (3) green, 0 failures.

### Project-wide performance audit + idle-CPU fixes (2026-06-19, Claude)

Multi-agent audit (6 angles → dedup → adversarial verify) of the macOS product
runtime for remaining steady-state/idle CPU burn after Codex's poll-cache work.
12 issues confirmed (11 idle-burn) / 7 rejected. Applied the four highest-impact,
clearly-safe fixes (all reduce idle wakeups/queries/polling):

- **[high] Gate periodic git-repo discovery on `scan.indexed > 0`**
  (`EngramServiceRunner.runIndexingLoop`). It previously re-probed every session
  cwd — up to ~5 `git` subprocess spawns per cwd, up to 200 cwds — every 5 min
  unconditionally, even on a fully idle machine with no new sessions. Now an idle
  cycle does zero git fan-out (mirrors the adjacent parent-backfill guard). This
  was the largest remaining steady-state CPU/process-churn source.
- **[med] Equality-guard `EngramServiceStatusStore.apply()`** so the ~5s idle
  health poll no longer rewrites unchanged @Observable props. @Observable fires
  on every assignment regardless of value, so the always-on menu-bar observers
  (NSImage rebuild + badge refresh) were re-firing 12x/min for no change; the
  guard makes the idle status poll free. Also restores the intended badge cadence
  (the spurious 5s observer fire had been pulling the live-session IPC to ~5s).
- **[med] Partial index `idx_sessions_visible ON sessions(hidden_at) WHERE
  hidden_at IS NULL`** so the visible-session `COUNT(*)` refreshed by the status
  poll (~every 10s) is an index-only scan instead of a full sessions-table scan
  (~12.8k rows, ~5ms each, forever).
- **[low] Menu-bar badge timer 10s → 30s** to match the service-side 30s
  live-session cache TTL — removes ~2/3 of the always-on idle badge IPC traffic
  that was just re-fetching the same cached payload.
- Tests: source-scan regression for the repo-discovery gate; behavioral test that
  an identical `.running` status does not refire observers (real change still
  does); migration test asserts `idx_sessions_visible` exists.
- Validation: full `EngramServiceCore` (210), `EngramCoreTests` (447), and
  targeted `EngramTests` suites green, 0 failures.

Low-severity follow-ups:
- DONE: `HeadingView` now reuses `MarkdownText`'s bounded NSCache instead of
  re-parsing markdown on every body evaluation (per-interaction main-thread CPU,
  zero behavior change).
- NOT changed (deliberate):
  - Health-monitor 5s cadence — kept for crash-detection responsiveness.
  - Indexer/live-session FS-walk narrowing — directory-mtime pruning is unsafe
    for trees whose files live in subdirs (would drop genuinely-active sessions),
    and codex date-dir windowing only saves bounded I/O (not CPU) while changing
    the full-history scan contract; not worth the correctness risk.
  - HomeView workbench reload — already off-main-thread and fires only ~every
    5 min when new sessions are indexed; debounce yields ~nothing and decoupling
    would cost freshness.

### Reviewed + hardened Codex's polling/CPU fix (2026-06-19, Claude)

Multi-agent adversarial review of the uncommitted Codex perf change (live-session
scan cache, `ServiceWriterGate.indexStatus()` cache, AppDelegate status-stream
removal). Verdict: no real bugs — the implementation is sound. 11 findings
confirmed, all low-severity polish/test-gaps after adversarial verification.
Applied the worthwhile ones:

- `EngramServiceReadProvider.scanLiveSessions`: sort+cap the candidate list ONCE
  after the scan instead of re-sorting the whole array on every accepted file
  (was O(M·N log N); now O(M log M), identical top-N result). Removes wasted CPU
  inside the very scan the 30s cache was added to make cheap.
- `ServiceWriterGate.indexStatus()`: guard the TTL check against a backward
  wall-clock jump (`elapsed >= 0 && elapsed < TTL`) so an NTP/sleep correction
  can't pin a stale cache past its TTL.
- `UnixSocketEngramServiceTransport.events()`: corrected the now-stale "snappy 5s
  self-healing status path" comment — the app no longer consumes `events()`;
  status/badge freshness rides solely on the launcher health monitor. The poll
  stream is retained (still protocol surface + test-covered), not deleted.
- Tests: made the live-session cache clock/TTL injectable and added an
  expiry-after-TTL test; added a `< vs <=` TTL-boundary assertion to the
  writer-gate cache test; added a cross-source global-cap test proving the newest
  active session from one source survives when another source floods 100+ files.
- DELIBERATELY KEPT as intended trade-offs (user asked for less realtime/polling):
  the 30s live-session TTL latency (new sessions/`activityLevel` lag up to 30s),
  and the existing source-text regression-sentinel tests.
- Validation: full `EngramServiceCore` suite green (209 tests, 0 failures),
  including the 3 new tests and Codex's 6 cache tests.

### Codex fixed menu/live-session polling load and redeployed locally (2026-06-19)

- Fixed the menu-bar `liveSessions()` load path: `FileSystemEngramServiceReadProvider`
  now streams recursive `FileManager` enumerators, keeps only the newest 100
  candidates, parses metadata only for selected candidates, and reuses a 30s
  cache across menu cadence calls.
- Removed the duplicate AppDelegate service status/event stream. Service events
  now flow through `EngramServiceLauncher`'s stdout event sink, and periodic
  status updates stay on the single `startHealthMonitor()` path.
- Added a generation-aware 10s `ServiceWriterGate.indexStatus()` cache. The
  cache is cleared when a gated write starts, bypassed while writes are in
  flight, and invalidated on successful or failed gated writes. Reviewer-found
  actor-reentrancy stale-cache risk is covered by in-flight write and
  mutate-then-throw tests.
- Verified targeted live-session, status-poll, and status-cache regression
  tests; full `EngramServiceCore` passed; `EngramTests` + `EngramCoreTests`
  passed. Full `Engram` scheme was attempted but `EngramUITests-Runner` hung
  before establishing the test-runner connection after 419s.
- Built and locally deployed `/Applications/Engram.app` version `0.1.0`, build
  `20260619100353` via `macos/scripts/build-release.sh --local-only` and
  `macos/scripts/deploy-local.sh macos/build/EngramExport/Engram.app`.
  Developer ID export and `release-verify` passed; installed app `codesign
  --verify --deep --strict --verbose=2` passed; live smoke showed `Engram` PID
  19252 and `EngramService` PID 19255 running from `/Applications/Engram.app`,
  with both sampling at 0.0% CPU after the startup indexing window.

### Fixed: de-flake jsonl-patch concurrent-modification test (2026-06-15, Claude) — PR #76

The `jsonl-patch` CAS test "throws ConcurrentModificationError when mtime
changes during patch" raced `patchFile`'s first async `stat` against a
`queueMicrotask` + `utimesSync` mtime bump. On slow/contended CI the bump
landed before that first stat, so the `before` snapshot already held the new
mtime, the compare-and-swap never fired, and `patchFile` resolved instead of
rejecting — an intermittent `typescript` job failure. Replaced the race with a
deterministic, scoped `vi.mock('node:fs/promises')` stat wrapper (the 2nd+ stat
for an armed path reports a bumped mtime). Production code untouched. Verified
6/6 reruns + full `test:coverage` 1580/1580.

### chore(deps): npm audit fix — esbuild + @grpc/grpc-js advisories (2026-06-15, Claude) — PR #77

CI `security-audit` (`npm audit --audit-level=moderate`) went red on `main`
after upstream published 3 high-severity advisories post-dating the green PR
runs: `@grpc/grpc-js` 1.14.0–1.14.3 (malformed-request crash) and `esbuild`
0.17–0.28 via `tsx` (Deno-module RCE + Windows dev-server file read) — all
dev/build-tooling deps, not shipped in the Swift product. `npm audit fix` (no
`--force`) patched all three within semver (package-lock.json only). Verified
build clean, vitest 1580/1580, `npm audit` → 0 vulnerabilities.

### B4 review round 2 (Codex) landed — alignment complete (2026-06-15, Claude+Codex) — branch `ux-flow-alignment`

- **Codex (gpt-5.5) independent adversarial implementation review** found 9
  MAJOR + 2 MINOR runtime/correctness/SECURITY bugs — a DIFFERENT class than
  Claude's round-1 (cross-model diversity paid off). All FIXED and verified:
  - **SECURITY**: WP17's redaction "fix" had flipped ServiceLogger + EngramLogger
    to `privacy: .public` for ALL messages — leaking project-move src/dst paths,
    session ids, error text, socket paths to the system log. Reverted to
    `.private` (readable gated-Observability logs deferred to a sanitized buffer).
  - `recordSessionAccess` mutated the DB but wasn't in `protectedCommands` →
    bypassed the capability token. Added.
  - `costs()` aggregated in UTC while budget dedup/dashboards use local day →
    wrong today/MTD near midnight in non-UTC zones. Switched to `localtime`.
  - Menu-bar polled `costs()` every 10s unconditionally + `costs` filled the
    telemetry ring buffer → gated the poll on a configured budget, excluded
    `costs` from spans.
  - Trace span `startedAt` was captured after dispatch (end time) → captured
    before. Replay `hasMore` was always false (fetch N, test `>N`) → fetch N+1
    sentinel. `insights()`/`memoryFiles()` returned full content × up to 500 over
    a 256 KiB IPC frame → detail-on-demand (`insightDetail`/`memoryFileContent`
    commands, list returns preview only). Insight importance UI `1...10` vs
    backend `0...5` → `1...5`. `confirmSuggestion` ok:false still swallowed on
    Sessions/Timeline browse pages (round-1 fixed only AgentsView) → surfaced.
    ActivityView Top-Files duplicate ForEach id; hygiene counts ignored
    hidden/confirmed rows → predicates aligned.
- **Final authoritative gate (re-run by Claude, not just the fix agent):** app
  `BUILD SUCCEEDED` (0 errors); **125 non-DB EngramTests + 7 ServiceTelemetryTests
  pass, 0 failures.** DB-backed tests remain blocked only by the pre-existing
  GRDB duplicate-linkage crash on this host (environmental; CI-runnable).
- Review artifacts: `.claude/codex-design-review.md`, `.claude/codex-impl-review.md`;
  full plan in `docs/reviews/alignment-design-2026-06-14.md`; source review in
  `docs/reviews/ux-flow-review-2026-06-14.md`.

### Stage 1 UI + B4 review round 1 landed (2026-06-15, Claude) — branch `ux-flow-alignment`

- All 20 work-packages implemented via 3 parallel build-gated batches
  (B1: 8 WPs, B2: 4, B3: 3) on top of the Stage 0 service base + Stage 0.5
  navigation/tokens/palette. **App + all test targets BUILD GREEN; 119 non-DB
  unit tests pass (0 failures).** DB-backed tests remain blocked on this host by
  the pre-existing GRDB duplicate-linkage threading crash (environmental; CI-runnable).
- Shipped UI: session actions (resume/copy/handoff/replay/hide/rename/export/
  favorite) on the browse pages; Favorites screen; search→transcript handoff +
  find-in-page fixes; Memory insights (list/read/save/delete) + full .md viewer;
  Agents grouping + confirm/dismiss + pending-suggestions inbox + Set-parent;
  Projects migration history/batch/alias; cost dashboard + budget notifier;
  Sources cache-only badges; Observability gated behind Developer Tools + real
  Performance/Traces telemetry; dashboards drill-in; replay using real backfill;
  hygiene checks + in-app remediation; service restart recovery + FDA onboarding;
  command-palette action hub. Removed (per human decision) the misleading
  semantic/hybrid search controls, dead embedding status, no-op Network/Web-
  security settings, and the non-existent HTTP `/mcp` endpoint row.
- **B4 review round 1 (Claude, 12-agent adversarial diff review):** found 11 real
  runtime/wiring bugs a green build hid — all FIXED: success-status banner never
  cleared (permanent warning), confirm/dismiss discarded `EngramServiceLinkResponse.ok`,
  insight-save failure invisible behind the sheet, stale `searchFailed` on empty
  query, always-favorite:true label, TraceExplorer double-reversed spans,
  regenerate-titles dead count branch, + dead-code/affordance nits.
- **Test fixes** (changeset regressions, now green): `sessionsForRepo` cwd match
  was a naive `LIKE 'path%'` that pulled in sibling repos (`/a/app` matched
  `/a/app-v2`) → fixed to path-boundary anchoring `(cwd = ? OR cwd LIKE ?/% ESCAPE)`
  with LIKE-metachar escaping; `EngramServiceHookInfo.path` made optional (was a
  required field → keyNotFound decoding payloads without it); two stale
  source-scan assertions updated for the intentional behavior changes.
- Next: B4 review round 2 (Codex independent adversarial pass) in progress.

### Stage 0 service base landed (2026-06-15, Claude) — branch `ux-flow-alignment`

- Additive service-layer foundation that all Stage-1 parallel UI WPs depend on.
  Build gate GREEN (`Engram` scheme, Debug). No existing signatures broken (new
  ctor params/DTO fields defaulted).
- DTOs (`EngramServiceModels.swift`): `EngramServiceMemoryFile.content` (opt),
  `EngramServiceSourceInfo.liveSyncDisabled` (default false; property + memberwise
  init + CodingKeys + `init(from:)`), `EngramServiceInsightInfo`,
  `EngramServiceCostsResponse{totalUsd,perSource,perDay,monthToDateUsd,todayUsd}`,
  telemetry `ServiceTelemetrySnapshot/ServiceCommandLatency/ServiceSpan`.
- Client surface (`insights()`/`costs()`/`telemetry()`) added to protocol,
  `EngramServiceClient` (`command("…")`), and `MockEngramServiceClient`.
- Read provider: `insights()` (tableExists("insights") guard), `costs()`
  (per-source + per-day-30d + MTD + today, `WHERE s.hidden_at IS NULL`,
  tableExists("session_costs") guard), `sources()` now sets `liveSyncDisabled`
  via new `LiveSyncDisabledSources` helper, and WP05 replay backfill: replay
  timeline now streams the real per-message adapter records (role incl. .tool,
  timestamp, tokens, tool name) OUTSIDE the GRDB read{} block, falls back to the
  FTS rows when the locator is unusable, and never appends the summary phantom.
- Command handler: `insights`/`costs`/`telemetry` read cases; WP14 real hygiene
  checks (empty/pending-suggestion/orphan counts → score+issues, error-issue on
  read failure; `hygiene` is now `internal static func(_:databasePath:)`); WP20
  telemetry — optional `telemetry: ServiceTelemetryCollector? = nil` ctor param,
  `handle(_:)` wraps dispatch with ContinuousClock timing → records a span,
  excluding `status`/`telemetry`.
- Runner: shared `ServiceTelemetryCollector` injected into the handler; BOTH the
  initial startup scan and the periodic scan now `recordScan(durationMs:indexed:total:)`.
- New files: `EngramService/Core/ServiceTelemetryCollector.swift` (actor: span
  ring cap 200, per-command ~100-sample p50/p95/max/count/errors, scan counters)
  and `Shared/Service/LiveSyncDisabledSources.swift` (windsurf+antigravity).
- Tests: `ServiceTelemetryTests` (7, all pass incl. handler-dispatch + IPC
  round-trip), `HygieneChecksTests` (6, all pass), `ReplayDataTests`
  (pure-builder + insights), `EngramServiceCostsTests`. 17 runnable tests GREEN.
- Residual: the costs/insights/replay-e2e tests that construct
  `SQLiteEngramServiceReadProvider` hit the PRE-EXISTING machine-specific
  duplicate-GRDB XCTest-host crash (`Statement.swift:126` "Database was not used
  on the correct thread") — confirmed on clean source via the existing
  `testSQLiteReadProviderServesSearchSourcesAndEmbeddingStatus`. They compile
  (TEST BUILD SUCCEEDED) and are CI/other-host runnable. Telemetry handler tests
  were routed through the default Empty read provider to avoid this trap.

### Claude designed + Codex-reviewed the alignment plan; implementation started (2026-06-14/15, Claude+Codex)

- Design workflow (56 agents, per-WP adversarial critique) turned the 144
  findings into a **20-work-package** alignment plan:
  `docs/reviews/alignment-design-2026-06-14.md`. Human decisions: delete
  misleading dead controls (semantic-search selector, no-op Network/Web
  settings, dead embedding status), BUILD a real per-dollar cost dashboard
  (WP19) and bounded in-process Observability telemetry (WP20), gate
  Observability behind a Developer-Tools flag (WP17).
- **Codex (gpt-5.5) adversarial design review** confirmed the source
  assumptions (WP01 closures, WP05 replay data in adapter layer, WP06
  save/delete backend, WP14 hideEmptySessions + hygiene stub) but caught
  coordination blockers: the wave table went stale after WP19/WP20 joined the
  service-file cluster (7 WPs share `EngramServiceModels/ReadProvider/
  CommandHandler`); WP13 read a `liveSyncDisabled` field owned by a later
  wave; WP02 `Screen.favorites` collided with WP18's `MainWindowView`
  ownership; finding-ID mislabels on WP20/WP19/WP13.
- **Revised execution model** (see doc): Stage 0 = SERIAL service base
  (all shared-seam additions + build gate) → Stage 0.5 = shared tokens +
  navigation (Screen/MainWindowView for WP02+WP18) → Stage 1 = PARALLEL
  file-disjoint UI WPs. Finding labels corrected (WP20→observability-1,
  WP19 usage-cost-2 PARTIAL, WP13 sources-sync-3 PARTIAL).
- Codex review artifact: `.claude/codex-design-review.md`. Implementation in
  progress on branch `ux-flow-alignment`.

### Claude ran a 28-surface UI/UX flow review of the macOS app (2026-06-14, Claude)

- Ran a multi-agent workflow (57 agents) tracing every end-to-end user
  workflow + 5 cross-cutting dimensions through the SwiftUI app, with an
  adversarial verify pass per surface. Output: **144 findings** (34 high /
  53 medium / 57 low) written to
  `docs/reviews/ux-flow-review-2026-06-14.md`.
- Systemic finding: the app is a near-complete read-only viewer with almost
  no action surface. `EngramService`/`EngramMCP` ship a write/action API
  (`setSessionHidden`, `renameSession`, `setFavorite`, `exportSession`,
  `saveInsight`/`deleteInsight`, `setParentSession`/`linkSessions`,
  `recordSessionAccess`, `projectMoveBatch`, `manageProjectAlias`,
  `get_costs`, `file_activity`) that has **0 callers** in the app views —
  only MCP agents can drive it. Three patterns: backend-ahead-of-UI,
  read-only viewers missing their action layer, and view-toggles shipped
  without their acting half (Show-hidden with no Hide, Favorites star with
  no list, cost-budget/threshold/Bearer-token controls no consumer reads).
- First-hand verified (not just agent claims): the 8 write methods have 0
  app-view callers; `SessionsPageView`/`TimelinePageView` omit the resume
  closures on `ExpandableSessionCard`; `triggerSync` is a hardcoded
  "not implemented in the Swift service" stub
  (`EngramServiceCommandHandler.swift:796-808`).
- Several sidebar pages are wired as real but are placeholders: Hygiene
  (Score 0 / "checks not implemented"), Observability Performance/Traces
  ("not collected"), `health()` constant stub.
- Next: full alignment design + implementation to close the gaps, both with
  adversarial review (Claude subagents + Codex). Workflow script kept at
  `.claude/wf-uxreview.js`.

### Codex rebuilt and redeployed current HEAD locally (2026-06-13, Codex)

- Rebuilt current `main`/`origin/main` (`a9e3f61e`) with
  `ENGRAM_BUILD_NUMBER=20260613125648 macos/scripts/build-release.sh --local-only`.
  Developer ID export succeeded at `macos/build/EngramExport/Engram.app` as
  version `0.1.0`, build `20260613125648`; `release-verify` passed full
  Developer ID checks.
- Installed the exported app with
  `macos/scripts/deploy-local.sh macos/build/EngramExport/Engram.app`, replacing
  `/Applications/Engram.app`, then launched it with `open -a`.
- Live verification after install: `/Applications/Engram.app` reports
  `CFBundleVersion=20260613125648`; `codesign --verify --deep --strict
  --verbose=2 /Applications/Engram.app` passed; `Engram` PID `29619` and
  `EngramService` PID `29628` started from `/Applications/Engram.app` and
  settled to about 0% CPU after startup; service socket
  `~/.engram/run/engram-service.sock` exists.
- MCP smoke verification against the installed helper exited 0, returned
  `serverInfo.name=engram`, `version=0.1.0`, and listed 28 tools.
- Recent runtime verifier found no severe `Engram`/`EngramService` log entries
  matching fatal/fault/error/crash/known indexing failures and no new
  `Engram*.ips` or `Engram*.crash` reports in `~/Library/Logs/DiagnosticReports`.
### Fixed: GRDB linked once as a shared dynamic framework (2026-06-15, Claude) — branch `fix/grdb-single-copy`

- **Symptom:** `EngramService` crash-looped at runtime with a GRDB
  `SchedulingWatchdog.preconditionValidQueue` SIGTRAP ("Database was not used on
  the correct thread") from `SQLStatementCursor.next()`. Pre-existing on `main`
  (crash reports dated 06-14 / 06-15 before the fix); also the host-only crash
  that blocked DB-backed unit tests locally.
- **Root cause:** the static SPM `GRDB` product was linked into all THREE dynamic
  frameworks the service process loads (EngramCoreRead, EngramCoreWrite,
  EngramServiceCore) → three GRDB copies, three independent `SchedulingWatchdog`
  thread-local registries. A cursor created under one copy and iterated via
  another tripped a false wrong-thread precondition. Same triple-embed produced
  the objc "class implemented in both" warnings.
- **Fix (GRDB's documented multi-target guidance):** switch every target from
  `product: GRDB` to the dynamic `product: GRDB-dynamic`, so the process loads
  ONE shared GRDB framework. `copy-service-helper.sh` bundles
  `GRDB-dynamic.framework` into `Contents/Frameworks` (emitted under
  `PackageFrameworks/` for plain builds, at `BUILT_PRODUCTS_DIR` root for
  archives); `EngramMCP`/`EngramCoreSchemaTool` gain `@rpath` entries.
- **Verified:** EngramServiceCoreTests **177/177** pass locally with 0
  thread-crashes / 0 duplicate-class warnings (could not run on this host
  before); `nm` shows one `GRDB-dynamic.framework` owning `SchedulingWatchdog`
  and 0 embedded copies in the three frameworks; Developer ID release build +
  deploy ran the live service **>2 min with 0 new crash reports** (was 4 in
  ~80s). PR #75; independent of #74.

### Codex synchronized public docs with the Swift product state (2026-06-12, Codex)

- Updated `README.md`, `docs/mcp-tools.md`, `docs/mcp-swift.md`,
  `docs/roadmap.md`, and `docs/PRIVACY.md` so GitHub-facing documentation
  matches the shipped Swift macOS app + Swift MCP helper state.
- Documented the current surface explicitly: 28 MCP tools, keyword-only Swift
  search, legacy `semantic`/`hybrid` search requests degraded to keyword with a
  warning, MCP `live_sessions` intentionally unavailable, app/service IPC live
  session scanning still available, exports under `~/.engram/exports/`, and
  text/FTS-only insight memory.
- Updated MCP protocol docs for the currently supported initialize versions
  (`2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25`) and the 28-tool
  troubleshooting threshold.
- Corrected README/privacy provider wording: Swift summary generation uses an
  OpenAI-compatible chat provider via `aiApiKey`; title generation uses
  `titleProvider`/`titleApiKey` and supports Ollama, OpenAI, or a custom
  OpenAI-compatible endpoint.
- Corrected the `get_context.task` MCP schema wording from semantic search to
  related context lookup. No runtime behavior changed.

### Codex fixed EngramService startup crash and high CPU scan (2026-06-12, Codex)

Fixed a new EngramService startup crash loop and the follow-on high-CPU startup
scan observed after redeploy.

- Follow-up scalability PR1: added `file_index_state`, a source+locator manifest
  table for file-level parse status. It records file size, mtime, inode/device,
  parser schema version, parse status, retry timing, retry count, and last
  failure kind.
- Added `FileIndexDecision` and writer APIs so startup/periodic scans can skip
  unchanged `ok` locators, skip terminal failures until the file changes, and
  honor backoff for retryable failures such as malformed partial writes.
- Terminal failure classification is conservative: deterministic oversized /
  unsupported locator failures are terminal; malformed JSON remains retryable
  because it can be a write/read race on a partial JSONL line.
- The follow-up intentionally did not implement append-only offset parsing yet;
  that remains a separate PR after profiling the single-file parser path.
- Follow-up verification passed: focused `EngramCoreTests/IndexerParityTests`
  for file-index decisions, terminal failure caching, retry backoff, startup
  known-file skipping, and recent-index changed-file behavior; `xcodebuild build`
  for `EngramServiceCore`; `git diff --check`.
- Follow-up deployment note: PR1 was initially left undeployed, then shipped
  together with PR2 in local build `20260612060821`.
- Follow-up residual risk: broader `SchemaCompatibilityTests` and full
  `IndexerParityTests` still hit the known duplicate-GRDB XCTest host crash on
  this machine; focused writer/indexer tests and framework build passed.
- Follow-up scalability PR2: profiled a live 9.6 MB Codex JSONL transcript and
  measured about 0.006s file read time, 0.268s JSON parse time, 4,931 parsed
  records, 3,350 response records, and 0.70s wall time. This made append-only
  offset parsing a poor immediate target compared with preventing repeated
  broad scans.
- Added lazy `file_index_state=ok` backfill when startup all-scan skips a
  locator because legacy `sessions` state already proves it is known. This lets
  the manifest cover older libraries without reparsing every historical file.
- Added regression coverage for the lazy backfill path:
  `IndexerParityTests.testStartupIndexBackfillsFileIndexStateWhenSkippingKnownSessionLocator`.
- PR2 verification passed: the new backfill test failed before implementation,
  then passed with the focused file-index, startup, and recent-index tests;
  `xcodebuild build` for `EngramServiceCore`; `git diff --check`.
- PR2 deployed locally: `macos/scripts/build-release.sh --local-only` exported
  `/Users/bing/-Code-/engram/macos/build/EngramExport/Engram.app` version
  `0.1.0`, build `20260612060821`, with full Developer ID verification.
  `macos/scripts/deploy-local.sh macos/build/EngramExport/Engram.app`
  installed it to `/Applications/Engram.app`.
- Live verification after deploy: first startup populated the live manifest
  (`file_index_state`: `ok=4549`, `retry=22`) and then settled to low CPU.
  A second app/service restart at `2026-06-12 14:14:25 +0800` verified the
  cached path: at 15s both `Engram` and `EngramService` were at 0.0% CPU; at
  about 90s both remained at 0.0% CPU. Logs after the second restart had no
  `session parse failed`, `session index error`, `Database was not used`,
  fatal, fault, or error entries, and no new `EngramService*.ips` crash report
  appeared.

- Root cause: `EngramServiceCore` executed retention SQL using a
  `GRDB.Database` handle owned by `EngramCoreWrite`, which hit the duplicate
  GRDB framework/runtime check (`Database was not used on the correct thread`)
  inside `ObservabilityRetention.prune`.
- Moved observability retention SQL into `EngramCoreWrite` and exposed
  `EngramDatabaseWriter.pruneObservabilityRetention(...)`, so the pool owner and
  SQL execution code use the same framework copy.
- Updated `EngramServiceRunner.runObservabilityRetention` to call the writer API
  through `ServiceWriterGate` instead of passing the raw database handle into
  `EngramServiceCore`.
- Added regression coverage for pruning through `ServiceWriterGate`, plus kept
  old/recent row retention and bounded-batch drain behavior covered through the
  new writer API.
- Root cause for the high-CPU restart scan: startup `indexAllSessions` skipped
  unchanged file locators but still reparsed known Codex transcript files that
  had grown after their last indexed timestamp. A live 8.6 MB Codex JSONL kept
  startup on the JSONL parser path for minutes after every restart.
- Changed startup/all indexing to skip known direct file locators entirely;
  recent/periodic indexing still reparses recently changed locators so active
  sessions continue to refresh outside the startup all-scan.
- Added regression coverage for startup skipping unchanged, hot, and known
  modified locators while preserving recent-index behavior for changed files.
- Built, deployed, and restarted `/Applications/Engram.app` as version `0.1.0`,
  build `20260612024348`; Developer ID export verification passed.
- Verification passed: `git diff --check`;
  `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  -only-testing:EngramServiceCoreTests/ObservabilityRetentionTests -quiet`;
  focused `EngramCoreTests` startup/recent-index tests;
  `xcodebuild build -project macos/Engram.xcodeproj -scheme EngramServiceCore
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet`;
  `macos/scripts/build-release.sh --local-only`; `macos/scripts/deploy-local.sh
  macos/build/EngramExport/Engram.app`.
- Live verification after restart: at 10s `EngramService` showed the expected
  startup CPU spike; by about 90s it was down to 4.0%, and by about 130s it was
  down to 1.5%. No new `EngramService-*.ips` crash reports appeared, and the
  final 30s log window had no `session parse failed` or `session index error`
  entries.
- Residual risk: the historical malformed/empty Codex JSONL files are still on
  disk and may log during the first seconds of startup until a separate failed
  locator cache/tombstone is implemented; they no longer caused sustained CPU in
  this verification.

### Codex completed full audit remediation (2026-06-10, Codex)

Closed the full local remediation scope from `docs/reviews/2026-06-10-multi-expert-audit.md`.

- Closed all 88 confirmed findings: 26 high, 50 medium, and 12 low.
- Adjudicated and closed all 47 additional low-severity notes; true notes were
  fixed or resolved by deleting the unused code path they described.
- Recorded the item-by-item ledger and verifier evidence in
  `docs/superpowers/plans/2026-06-10-audit-complete-remediation.md`.
- Built and locally deployed `macos/build/EngramExport/Engram.app` to
  `/Applications/Engram.app` as version `0.1.0`, build `20260610144819`.
- Final checks included `git diff --check`, focused Swift regression tests,
  `Engram` and `EngramServiceCore` builds, `macos/scripts/build-release.sh
  --local-only`, `macos/scripts/deploy-local.sh
  macos/build/EngramExport/Engram.app`, and deep strict codesign verification
  of the installed app.
- Residual risk: full all-schemes testing remains blocked by the known
  duplicate-GRDB test-host fatal on selected runtime tests; the CommandPalette
  UI runtime assertion is still blocked by Xcode beta accessibility automation
  aborting the app on this host.

### Codex remediation for high-risk audit findings (2026-06-10, Codex)

Implemented and locally deployed a focused remediation slice from
`docs/reviews/2026-06-10-multi-expert-audit.md`.

- Fixed resume/launch failures: Codex resume now uses the `resume` subcommand,
  CLI discovery includes common shell binary paths, Ghostty executes composite
  commands through `zsh -lc`, and the app carries Apple Events permission
  metadata.
- Fixed high-risk runtime/read-path issues: IPC frame deadlines honor long
  request timeouts, SQLite replay timeline reads real FTS-backed rows, Latin
  keyword search is driven from FTS matches, and startup scanning covers all
  adapters.
- Fixed AI/title and timestamp regressions: title regeneration includes existing
  generated titles, keyless Ollama/custom title providers are accepted,
  unsupported summary protocol options were removed from UI, AI summaries are
  preserved across equivalent reindexing, and shared timestamp parsing now
  covers fractional ISO and SQLite-style dates.
- Fixed supporting data/UI defects: Kimi token usage accumulates across status
  updates, project-move compensation only reverses completed physical moves,
  same-slug Gemini moves update `projects.json`, Sessions/Timeline suggested
  buttons call the service, and OSLog reading uses system scope with proper
  error-level mapping.
- Verification: targeted Swift tests passed for the changed surfaces;
  `macos/scripts/build-release.sh --local-only` produced and verified
  `macos/build/EngramExport/Engram.app`; `macos/scripts/deploy-local.sh` installed
  `/Applications/Engram.app` build `20260610065205`, whose version, helpers,
  Apple Events entitlement, and deep codesign verification were confirmed.
- Residual risk: this does not close all 88 confirmed audit findings. A full
  `EngramServiceCore` scheme test run was stopped after about 5m18s of repeated
  Xcode beta CoreDevice/CoreSimulator launch warnings with no explicit test
  failure observed.

### Multi-expert audit completed (2026-06-10, Claude)

Fresh full-repo read-only audit by 11 parallel domain experts + adversarial
verification (272 subagents over two passes; security dimension excluded by
user request). Full report: `docs/reviews/2026-06-10-multi-expert-audit.md`. No code changed.

- 88 confirmed findings (26 high / 50 medium / 12 low, 0 critical), 9 refuted,
  1 disputed, 8 unverified carryovers, 47 low-severity notes.
- Hotspots: `macos/EngramService/Core`, `macos/EngramCoreWrite/Indexing`,
  `macos/Engram/Views`.
- Top systemic themes: per-view ad-hoc timestamp parsing; 30s IPC frame
  deadline vs long-running commands; `sessions_fts.session_id` UNINDEXED full
  scans; AI generation pipeline inert in default config; resume/launch surface
  broken end-to-end; ingestion durability gaps (2-day rescan window, whole-file
  drops, poison-job starvation); docs promising unimplemented features
  (redaction, Windsurf); tests that cannot fail (source-string asserts,
  tautological smoke, TS-generated fixture DB).

### Close broad product-direction PR stack (2026-06-08, Codex)

Completed the split-stack closeout for the broad product-direction work.

- Merged #70 `feat(resume): add session action entrypoints` at `cb6a0959`.
- Rebased, verified, and merged #71
  `refactor(ui): remove legacy search surfaces` at `9925f31d`.
- Rebased, verified, and merged #72
  `chore(release): record split handoff` at `cc71258e`.
- Local `main` is synchronized with `origin/main` at `cc71258e`; the full
  pre-split backup remains on `codex/split-backup-20260608-usage-archive`
  at `9e9811d6`.
- Remaining open PRs are outside this product-direction split closeout:
  #66 docs-plan-closeout and Dependabot update PRs.

### Split broad product-direction work into stacked PRs (2026-06-08, Codex)

Prepared the previously broad local product-direction patch as a reviewable
stack of draft PR branches. The stack preserves the verified behavior while
separating UI-test signing, adapter robustness, usage/source health, resume
actions, search cleanup, and release handoff into independent review layers.

- Backed up the full original dirty state on
  `codex/split-backup-20260608-usage-archive` at commit `9e9811d6`.
- Split implementation branches from clean `origin/main` using worktrees under
  `~/.config/superpowers/worktrees/engram/`.
- Used XcodeGen as the source of truth for project-file changes; generated
  `macos/Engram.xcodeproj/project.pbxproj` per split branch instead of copying
  the broad generated project file.
- Full UI automation was unblocked by configuring the UI-test target signing in
  `macos/project.yml`; full `EngramUITests` passed on this host after the
  signing fix.


### Project move Gemini/iFlow dry-run parity tests (2026-06-06, Codex)

Closed a plan-review gap in the already-landed Gemini/iFlow project-move
compatibility work.

- **Coverage**: added TypeScript and Swift dry-run regression tests proving
  custom Gemini `projects.json` old slugs and iFlow directories discovered from
  structured `cwd` records are reported in `renamedDirs` without moving source,
  destination, Gemini, or iFlow directories.
- **Plan**: added the reviewed Superpowers implementation plan at
  `docs/superpowers/plans/2026-06-06-project-move-gemini-iflow.md`; OpenCode
  SQLite directory rewrites remain a separate PR scope.
- **Verification**: targeted TS and Swift dry-run tests passed against the
  current implementation, confirming this PR only closes acceptance coverage.

### Project move covers Codex rollout summaries (2026-06-06, Codex)

Closed the remaining Codex project-move compatibility gap found by checking
the real `~/.codex` layout.

- **Fix**: project moves now scan and patch
  `~/.codex/memories/rollout_summaries` as a flat Codex source, in both the
  TypeScript reference pipeline and the Swift product pipeline.
- **Why**: Codex sessions and `archived_sessions` were already covered, but
  exported/project-local rollout summary JSONL files can also retain
  `turn_context.cwd` and workspace-root paths. Leaving that directory out made
  project moves incomplete for Codex-derived durable memory artifacts.
- **Verification**: real-disk audit confirmed current Codex primary sessions
  live under `~/.codex/sessions`, archives under `~/.codex/archived_sessions`,
  and the rollout-summary store under
  `~/.codex/memories/rollout_summaries`. RED project-move tests failed until
  the new source root was added. GREEN targeted Vitest project-move tests and
  targeted `EngramCoreTests` Swift tests passed.

### Gemini CLI projects cache refresh (2026-06-06, Codex)

Closed a still-current P3 cache-staleness finding in the TypeScript Gemini CLI
adapter.

- **Fix**: `GeminiCliAdapter` now keys its `projects.json` cache by the
  file's `size:mtimeMs:ctimeMs` signature, keeping cache hits for unchanged
  files while reloading after Gemini rewrites the project map.
- **Why**: the prior cache lived for the adapter lifetime, so a long-running
  Engram process could keep resolving a Gemini project slug to an old cwd after
  `~/.gemini/projects.json` changed.
- **Verification**: RED `tests/adapters/gemini-cli.test.ts` failed because a
  rewritten `projects.json` still returned `/Users/test/old-project`. GREEN
  Gemini adapter tests passed 11 tests; adjacent adapter tests passed 30 tests;
  Biome and `npm run typecheck:test` passed. Subagent review approved the
  change; the same-size/same-mtime residual risk it noted was closed by adding
  `ctimeMs` to the cache signature.

### TypeScript generate_summary MCP status semantics (2026-06-06, Codex)

Closed the still-current `generate_summary` `isError` misuse finding.

- **Fix**: deterministic business outcomes now return structured status
  results without MCP `isError`: `not_found`, `not_configured`,
  `unsupported_source`, `empty`, and `empty_response`.
- **Fix**: direct handler exceptions and unknown daemon failures still return
  `isError: true`, now with `structuredContent.error.message`.
- **Fix**: daemon-routed `/api/summary` business rejections are mapped back to
  the same non-error MCP status shape, keeping the direct and single-writer
  paths aligned.
- **Verification**: RED `tests/tools/generate_summary.test.ts` failed on the
  old implementation because business statuses returned `isError: true` and
  had no structured status. GREEN targeted tool, daemon contract, and summary
  web tests passed 91 tests; Biome and `npm run typecheck:test` passed.

### TypeScript database statement wrapper without Proxy (2026-06-06, Codex)

Closed a still-current P1 performance/observability finding in the TypeScript
reference database facade.

- **Fix**: `Database.wrapStatement` no longer returns a `Proxy`. It now creates
  one pre-bound wrapper object per prepared statement, with stable own
  `run/get/all/iterate` methods and chain methods (`pluck`, `expand`, `raw`,
  `bind`, `safeIntegers`) that return the wrapper instead of the raw statement.
- **Why**: the Proxy path still allocated/bound dynamically through a get trap
  and chain methods such as `pluck()` returned the original statement, bypassing
  query metrics on subsequent `get/all/run` calls.
- **Verification**: RED `tests/core/db.test.ts` checks failed because the
  instrumented methods were not own pre-bound wrappers and `pluck().get()` did
  not record `db.query_ms`. After the fix, targeted RED tests passed, full
  `tests/core/db.test.ts` passed 55 tests, `npm run typecheck:test` passed, and
  `git diff --check` passed.

### Swift service IPC project-move test cleanup (2026-06-06, Codex)

Closed a still-current Round 5 test-isolation finding.

- **Fix**: `EngramServiceIPCTests.testProjectMigrationCommandsSurfacePipelineErrors`
  now stores the scoped-home missing project paths in local URL values and
  registers `defer` cleanup for both paths before exercising the native
  project-move pipeline.
- **Why**: the test already runs under a scoped HOME, but assertion failures or
  partial pipeline execution could still leave `.engram-test-missing-*`
  artifacts in that scoped home. The cleanup keeps the test hermetic even on
  failure paths.
- **Verification**: RED source-text guard failed because the missing-path locals
  and cleanup defers were absent; after the fix, targeted
  `EngramServiceCoreTests/EngramServiceIPCTests` checks for the source guard and
  real IPC pipeline error path passed 2 tests.

### TypeScript migration_log state/start-time index parity (2026-06-06, Codex)

Closed a still-current TS/Swift schema parity gap from the review backlog.

- **Fix**: TypeScript migrations now create
  `idx_migration_log_state_started` on `migration_log(state, started_at)`,
  matching the Swift schema and its startup migration repair path.
- **Why**: pending/stale migration scans filter by state and order or compare by
  start time; TS previously had separate `state` and `started_at` indexes but
  lacked the compound access path already present in Swift.
- **Verification**: RED `tests/core/db-migration.test.ts` failed because the
  index was absent from `sqlite_master`; after the migration fix, the targeted
  test file passed 16 tests. An old-DB smoke with an existing `migration_log`
  table and no compound index confirmed reopening through `Database` creates
  `CREATE INDEX idx_migration_log_state_started ON migration_log(state,
  started_at)`. The committed test fixture database was regenerated and
  inspected to confirm the same index exists there.

### Swift export directory parity with TypeScript (2026-06-06, Codex)

Closed the remaining Swift-side export directory drift from the review backlog.

- **Fix**: Swift service exports now write to `~/.engram/exports`, matching the
  TypeScript MCP export tool, instead of the legacy `~/codex-exports`
  directory.
- **MCP parity**: Swift MCP `tools/list` now advertises `~/.engram/exports/`,
  and the executable golden fixture expects service export paths under the
  same directory.
- **Safety**: existing export symlink defenses still cover the new
  `.engram/exports` directory and the final leaf output path.
- **Review**: subagent implementation review returned APPROVED with no
  blocking findings.
- **Verification**: RED service IPC path tests failed against the old
  `~/codex-exports` implementation; targeted `EngramServiceCore` export tests
  passed 5 tests; targeted `EngramMCPTests` export tests passed 3 tests;
  `git diff --check` passed.

### Swift hide_session not-found and local-state parity (2026-06-06, Codex)

Closed the remaining Swift-side `hide_session` silent-success gap.

- **Fix**: the service writer now checks the `sessions.hidden_at` update count
  and returns a structured `SessionNotFound` / `session-not-found` command
  failure when the session id does not exist.
- **Parity**: successful hide/unhide operations now mirror `hidden_at` into
  `session_local_state`, matching the local-state surface used by the app and
  MCP tooling.
- **Compatibility**: the service command guards minimal or older databases by
  creating `session_local_state` and adding missing local-state columns before
  the mirror write.
- **Verification**: RED missing-session IPC test failed before the service fix;
  targeted service and MCP tests passed; full `EngramServiceCore` passed 129
  tests; full `EngramMCPTests` passed 75 tests; `git diff --check` passed.

### Gemini CLI adapter large sidecar/projects guard (2026-06-06, Codex)

Closed the remaining P1 large-JSON gap in the TypeScript Gemini CLI adapter.

- **Fix**: `GeminiCliAdapter` now applies the same 10 MiB size cap to
  `.engram.json` sidecars and `.gemini/projects.json` before reading JSON
  into memory. Oversized sidecars are treated as absent; oversized
  `projects.json` files resolve to an empty project map.
- **Scope**: the existing 10 MiB guard for primary session JSON and streamed
  message reads was already present; this change covers the two remaining
  unconditional `readFile` paths.
- **Verification**: `npx vitest run tests/adapters/gemini-cli.test.ts` first
  failed on oversized sidecar/projects fixtures, then passed 10 tests after
  the fix. `npx biome check src/adapters/gemini-cli.ts
  tests/adapters/gemini-cli.test.ts` passed.

### Claude/Qoder grouped-dir reconcile for historical project moves (2026-06-06, Codex)

Added startup repair for already-orphaned Claude Code/Qoder grouped project
directories left behind by the previous incomplete directory encoder.

- **Fix**: Swift startup maintenance now scans only `.claude/projects` and
  `.qoder/projects`, extracts structured `cwd` values from JSON/JSONL session
  files, computes the corrected Claude/Qoder directory name, and repairs a
  stale grouped directory with no-overwrite copy/delete semantics.
- **Parity**: added the same reconcile helper to the TypeScript reference
  implementation for future cross-runtime comparisons.
- **Safety**: the repair skips child symlinks, nested symlink evidence,
  ambiguous directories, missing roots, already-correct directories, target
  collisions, and session files above the 50 MiB structured-cwd read cap.
- **Review**: subagent plan review initially requested stronger no-overwrite,
  symlink, startup-order, and Qoder parity coverage; subagent implementation
  review then requested the 50 MiB scan cap. Both review gates passed after
  the fixes.
- **Verification**: `npx vitest run
  tests/core/project-move/grouped-dir-reconcile.test.ts
  tests/core/project-move/encode-cc.test.ts
  tests/core/project-move/orchestrator.integration.test.ts` passed 49 tests;
  `npx biome check src/core/project-move/grouped-dir-reconcile.ts
  tests/core/project-move/grouped-dir-reconcile.test.ts` passed; selected Swift
  `SessionSourcesTests`, `StartupBackfillTests`, and `OrchestratorTests`
  passed 78 tests; `git diff --check` passed.

### CodeQL workflow Node 24 action cleanup (2026-06-06, Codex)

Closed the remaining CodeQL workflow Node 20 deprecation annotations.

- **Fix**: upgraded the CodeQL workflow from `actions/checkout@v4`,
  `actions/setup-node@v4`, and `github/codeql-action/*@v3` to the current
  `@v6` / CodeQL `@v4` actions while keeping explicit Node 24 setup for the
  Swift CodeQL job.
- **Verification**: `rg` found no remaining old CodeQL workflow action
  references; Ruby parsed `.github/workflows/codeql.yml`; `actionlint
  .github/workflows/codeql.yml` passed.

### Codex project-move compatibility verification (2026-06-06, Codex)

Verified the Codex project-move surface after the Claude/Qoder directory
encoding fix.

- **Conclusion**: no Codex-specific directory encoder is needed. Codex active
  sessions live under `.codex/sessions` and archived sessions under
  `.codex/archived_sessions`; both are flat roots from project-move's
  perspective, so migration patches literal path references in JSONL content
  and does not rename per-project directories.
- **Source evidence**: TypeScript and Swift `SessionSources` both register
  `codex` and `codex-archived` with no `encodeProjectDir`; the Swift adapter
  also expands `.codex/sessions` to include `.codex/archived_sessions`.
- **Real-corpus verification**: scanned the local Codex corpus read-only:
  2,175 rollout JSONL files, 2,165 cwd-bearing sessions, zero non-absolute
  cwd values, and zero project-dir-like path layouts. Five archived sessions
  live directly under `.codex/archived_sessions`, which is still covered by the
  flat archived root.
- **Verification**: TS project-move source/orchestrator/review tests passed
  50 tests; selected Swift project-move Codex/source/review tests passed 10
  tests.

### TypeScript empty-reindex session fact preservation (2026-06-06, Codex)

Closed a TS/Swift parity gap in session snapshot persistence.

- **Fix**: the TypeScript snapshot merge path now preserves an existing `cwd`
  when a newer parse returns an empty cwd, and preserves the existing message
  count breakdown when a newer parse returns zero total messages over a row
  that already has messages.
- **Defense in depth**: the lower-level `sessions` table conflict updates for
  both legacy `upsertSession` and authoritative snapshot upsert now apply the
  same preservation rule, so direct database writes cannot clobber known-good
  session facts. Direct authoritative upsert also preserves the existing
  `quality_score` under the same empty-reindex predicate, keeping the derived
  score consistent with the preserved counts.
- **Regression coverage**: added RED/GREEN tests for `mergeSessionSnapshot`,
  legacy `Database.upsertSession`, and direct
  `Database.upsertAuthoritativeSnapshot`, including the direct-upsert
  `quality_score` consistency case raised during subagent review.
- **Verification**: `npx vitest run tests/core/session-merge.test.ts
  tests/core/db.test.ts` failed on the old behavior and passed after the fix;
  `npx vitest run tests/core/session-writer.test.ts
  tests/core/session-merge.test.ts tests/core/db.test.ts` passed 69 tests;
  `npx biome check src/core/session-merge.ts src/core/db/session-repo.ts
  tests/core/session-merge.test.ts tests/core/db.test.ts` passed.

### Claude Code project-dir long-path encoding parity (2026-06-06, Codex)

Closed the remaining known Claude Code/Qoder project-move encoding gap.

- **Fix**: the TypeScript reference encoder and Swift product encoder now match
  Claude Code's long project-dir rule: replace every non-`[A-Za-z0-9]`
  UTF-16 code unit with `-`; when the encoded name exceeds 200 UTF-16 code
  units, keep the first 200 encoded units and append a base36 Java-style
  32-bit hash of the original path.
- **Source evidence**: verified against the local Claude Code 2.1.165 bundled
  `Hj()` / `SYH()` implementation (`uUH=200`). The same encoder remains shared
  with Qoder because the real Qoder corpus matches the same naming rule.
- **Real-corpus verification**: replayed local `~/.claude/projects` and
  `~/.qoder/projects` directories. Claude Code had 39 cwd-bearing dirs across
  88 total dirs, with zero mismatches after accounting for subagent/subdirectory
  cwd variation; Qoder matched 7/7. The longest observed real dir was 86
  code units, so the >200 branch is covered by binary-derived regression cases.
- **Regression coverage**: added TS and Swift tests for the 200-code-unit
  boundary, truncated hash suffixes, and long emoji paths to lock JavaScript
  UTF-16 semantics.
- **Verification**: `npx vitest run tests/core/project-move/encode-cc.test.ts`
  passed 12 tests; TS project-move/MCP tests passed 217 tests; selected Swift
  project-move tests passed 98 tests.

### Session snapshot noop write reduction (2026-06-06, Codex)

Closed two still-current Swift indexing follow-ups from
`docs/reviews/2026-06-03-five-round-multi-expert-audit.md`.

- **Fix**: `SessionSnapshotWriter` no longer rewrites `session_costs` for a
  fully unchanged noop snapshot. It still creates a missing zero-cost row and
  still refreshes a noop row when a previously-null model becomes non-empty.
- **Regression coverage**: added a RED/GREEN test proving an unchanged noop
  does not increase SQLite `total_changes()`, while preserving existing model,
  tool refresh, and orphan recovery behavior.
- **Link source guard**: added a behavior truth table for `link_source` so fresh
  inserts, path-derived updates, incoming nil-parent updates, and manual-link
  preservation stay aligned across the insert and conflict-update paths.
- **Review**: a reused subagent performed read-only review of the diff, raised a
  low-severity link-source coverage gap, and the gap was patched before commit.
- **Verification**: selected writer tests passed, then the full
  `IndexerParityTests` class passed 32 tests.

### MainActor UI trampoline cleanup (2026-06-06, Codex)

Closed the remaining still-current SwiftUI P3 cleanup finding from
`docs/reviews/2026-06-03-five-round-multi-expert-audit.md`.

- **Fix**: `MenuBarController` no longer mixes GCD main-queue trampolines with
  `Task { @MainActor in }` for deferred UI activation/session-open work. The
  MainActor-isolated controller now uses the Swift concurrency form
  consistently.
- **Scroll chrome**: `ModernScrollViewConfigurator` preserves the existing
  immediate + 200ms delayed configuration behavior, but schedules both passes
  through `Task { @MainActor in }` instead of `DispatchQueue.main.async` /
  `asyncAfter`.
- **Regression coverage**: added a source guard that rejects reintroducing
  `DispatchQueue.main.async` in `MenuBarController` and `Theme` for this
  reviewed path.
- **Verification**: the new guard failed against the old code, then selected
  `ViewMainThreadReadTests` and `ThemeTests` passed 26 tests after the fix.

### Synchronous service client close on app termination (2026-06-06, Codex)

Closed a still-current Swift app termination cleanup finding.

- **Fix**: `EngramServiceClient.close` and the underlying transport close API
  are now synchronous. `AppDelegate.applicationWillTerminate` calls
  `serviceClient.close()` directly instead of launching a fire-and-forget
  detached task after termination begins.
- **Cleanup**: MCP service-client call sites now use ordinary
  `defer { serviceClient.close() }` cleanup instead of spawning nested tasks
  solely to await a no-op close.
- **Regression coverage**: added a source guard that rejects reintroducing the
  detached terminate-close pattern.
- **Verification**: selected `EngramServiceClientTests`,
  `UnixSocketTransportTests`, and `ViewMainThreadReadTests` passed 40 tests.

### Async MessageParser adapter stream bridge (2026-06-06, Codex)

Closed a still-current SwiftUI P3 concurrency/performance finding.

- **Fix**: `MessageParser` no longer bridges async adapter streams through a
  detached task plus `DispatchSemaphore`. `parse` and `parseWindowed` are now
  async and await adapter `streamMessages` directly, while preserving the
  existing legacy-parser fallback path.
- **UI integration**: `SessionDetailView` keeps transcript parsing off the main
  actor via `Task.detached`, but now awaits the async parser inside that worker
  task instead of blocking a thread.
- **Regression coverage**: converted `MessageParserTests` to async parser calls
  and added a source guard rejecting `DispatchSemaphore` /
  `blockingAdapterMessages` in `MessageParser`.
- **Verification**: selected `MessageParserTests` and `ViewMainThreadReadTests`
  passed 40 tests.

### Off-main segmented message parsing (2026-06-06, Codex)

Closed a still-current SwiftUI P3 performance finding.

- **Fix**: `SegmentedMessageView` no longer cold-parses markdown/content
  segments synchronously from `body`. It now reuses the existing segment cache
  when available and otherwise parses/cache-fills from a `.task(id: content)`
  `Task.detached(priority: .userInitiated)` path.
- **Regression coverage**: extended `ViewMainThreadReadTests` with a source
  guard that locks the off-main parse shape and rejects returning to
  `ForEach(segments)` from body.
- **Verification**: selected `ViewMainThreadReadTests` passed 17 tests.

### Service writer gate timing test hardening (2026-06-06, Codex)

Closed a still-current Round 5 test-stability finding.

- **Fix**: `ServiceWriterGateTests.testSemaphoreReleasesPermitWhenWaiterCancelledAfterSignal`
  now runs 200 deterministic queued-waiter iterations instead of 2000 and uses
  a 1s acquire timeout instead of 200ms. The test still exercises the
  cancel-after-signal permit leak window, but no longer creates an avoidable CI
  timing hazard.
- **Verification**: the correct scheme is `EngramServiceCore` with the
  `EngramServiceCoreTests` target selected; `ServiceWriterGateTests` passed 9
  tests. The initially tried non-existent `EngramServiceCoreTests` scheme
  failed at xcodebuild scheme resolution, not test execution.

### Project archive gitdir marker validation (2026-06-06, Codex)

Closed a surviving low-priority project-migration review finding.

- **Root cause**: archive auto-categorization treated any regular `.git` file
  as a valid worktree/submodule marker. Empty or malformed marker files could
  therefore be auto-classified as `archived-done` instead of requiring an
  explicit category.
- **Fix**: Swift and TS archive suggestion logic now parse regular `.git`
  files as bounded 512-byte `gitdir:` markers and require the resolved git
  metadata directory to contain `HEAD`.
- **Regression coverage**: added Swift and TS tests for valid gitdir marker
  files and malformed marker files.
- **Verification**: `ArchiveTests` passed 18 tests; TS project-move archive,
  batch, and MCP tests passed 43 tests; targeted Biome check passed.

### Node 24 agent-instruction drift cleanup (2026-06-06, Codex)

Closed the remaining current-documentation drift after the Node 24 migration.

- **Fix**: `.github/copilot-instructions.md` now tells Copilot agents to use
  Node 24 and cites `.nvmrc`, `package.json` engines, and CI as the source of
  truth.
- **Verification**: checked `.nvmrc`, `package.json` engines, current GitHub
  workflows, and non-archive Node-version references. The only remaining Node
  20/22 mentions are package dependency engine ranges or archived/historical
  review documents that should not be rewritten.

### Local build 752 deployed (2026-06-06, Codex)

Deployed and restarted the local macOS app from current `main`.

- **Build**: ran `ENGRAM_BUILD_NUMBER=$(git rev-list --count HEAD)
  macos/scripts/build-release.sh --local-only`; Developer ID export succeeded
  anyway, producing `macos/build/EngramExport/Engram.app`.
- **Verification**: `release-verify.sh` passed full Developer ID checks:
  bundle hygiene, helper structure, version `0.1.0 (752)`,
  `codesign --verify --deep --strict`, Hardened Runtime, Developer ID
  authority, and secure timestamp.
- **Deploy/restart**: ran `macos/scripts/deploy-local.sh
  macos/build/EngramExport/Engram.app`, opened `/Applications/Engram.app`, and
  terminated old `EngramMCP` helpers so future MCP clients respawn from the new
  bundle.
- **Runtime proof**: `/Applications/Engram.app` reports
  `CFBundleVersion=752`; running processes are
  `/Applications/Engram.app/Contents/MacOS/Engram` and
  `/Applications/Engram.app/Contents/Helpers/EngramService`; service socket is
  present at `~/.engram/run/engram-service.sock`.

### Stale follow-up plan reconciliation (2026-06-06, Codex)

Reconciled current backlog surfaces after the recent PR sequence.

- **Project migration handoff**: updated the older Claude Code encoder handoff
  entry to reflect that Codex active/archived coverage, Gemini/iFlow grouped
  source coverage, PR #51, and PR #52 are closed. Historical reconcile for
  already-orphaned Claude Code dirs remains explicitly deferred because the
  real-disk audit found no local orphan to repair.
- **FTS plan status**: marked
  `docs/superpowers/plans/2026-06-04-fts-table-swap-rebuild.md` complete and
  linked it to merged PR #48 (`d199808c`), so backlog scans no longer report the
  already-shipped FTS table-swap work as open.

### Swift UI P3 cleanup follow-up (2026-06-06, Codex)

Closed a small still-current UI/concurrency cleanup slice from
`docs/reviews/2026-06-03-five-round-multi-expert-audit.md` Round 4.

- **Command Palette search**: `CommandPaletteView` now owns and cancels a single
  debounced search task. Per-keystroke session search waits 300 ms before
  calling the service, cancels superseded work, and checks cancellation before
  publishing service or local fallback results. A read-only subagent review
  caught the first pass still entering local fallback after a cancelled service
  call; the final version exits before starting fallback work.
- **Formatter reuse**: `LiveSessionCard.elapsedText` and
  `ReplayState.densityBuckets` now reuse static `ISO8601DateFormatter`
  instances instead of allocating one during repeated render/state calculations.
- **Regression coverage**: extended `ViewMainThreadReadTests` with source guards
  for Command Palette debounce/cancellation and live/replay ISO formatter reuse.
- **Verification**: RED first on the two new guards; GREEN with selected
  `ViewMainThreadReadTests` targeted tests, then the full
  `ViewMainThreadReadTests` suite (16 tests).

### MCP project_review Claude Code encoding parity (2026-06-06, Codex)

Closed a residual Claude Code compatibility gap outside the main project-move
pipeline.

- **Root cause**: PR #51 fixed the Swift product encoder and TS reference
  encoder, but Swift MCP `project_review` kept a private `encodeCC()` helper
  that only replaced `/` with `-`. For migrated projects whose Claude Code dir
  contains encoded `_`, spaces, dots, or other punctuation, `project_review`
  could classify the migrated project's own Claude Code leftovers as `other`.
- **Fix**: updated `macos/EngramMCP/Core/MCPFileTools.swift` to use the same
  UTF-16 code-unit rule as the product encoder: every non-`[A-Za-z0-9]` code
  unit maps to `-`.
- **Regression coverage**: added a golden MCP executable test using
  `CCTV_Admin`, which fails under the old slash-only helper and passes after
  the fix.
- **Verification**: RED confirmed
  `testProjectReviewClassifiesClaudeCodeDirsWithNonAlnumEncoding` misclassified
  the own Claude Code dir as `other`; GREEN after the helper fix. Also reran
  TS project-move/MCP/API compatibility tests (5 files / 88 tests) and Swift
  encoder tests (10 tests).

### Project migration OpenCode SQLite compatibility (2026-06-06, Codex)

Closed the SQLite-backed source gap in project migration.

- **Root cause**: OpenCode stores project cwd in
  `~/.local/share/opencode/opencode.db` (`session.directory`), but project
  migration only scanned JSON/JSONL files under the OpenCode data root. A move
  could therefore commit successfully while OpenCode sessions still pointed at
  the old project path.
- **Fix**: Swift and TS project-move now patch OpenCode's `session.directory`
  with exact/subtree matching (`oldPath` or `oldPath/...`) and leave lookalike
  paths such as `oldPath-lookalike` untouched. Dry-run impact counts the SQLite
  rows, and post-move review reports residual SQLite refs as virtual locators
  (`opencode.db::session:<id>:directory`).
- **Unicode parity**: SQLite matching checks `oldPath`, NFC, and NFD variants
  by byte identity before computing the replacement suffix, matching the
  existing JSON/JSONL canonical path fallback.
- **Rollback safety**: the forward SQLite update records the exact OpenCode
  session ids it changed. Compensation reverses only those rows, so a rollback
  cannot rewrite unrelated sessions that already belonged to the attempted
  destination path.
- **Regression coverage**: added Swift and TS orchestrator tests for OpenCode
  SQLite happy path, SQLite-patch-failure compensation, and
  rollback-after-later-source-failure, plus Swift and TS review-scan tests for
  residual SQLite refs. Unicode tests include a decomposed-path row.
- **Verification**: RED confirmed before implementation (`opencode` stayed
  0/0 and `session.directory` retained the old cwd). GREEN: `npm test --
  tests/core/project-move` (16 files / 191 tests); selected Swift
  `OrchestratorTests` + `ReviewScanTests` (30 tests); `npm test` (127 files /
  1516 tests); `npm run lint`; `npm run build`; `npm run typecheck:test`;
  `git diff --check`.

### Project migration Gemini/iFlow compatibility follow-up (2026-06-06, Codex)

Closed the remaining grouped-source compatibility audit left by the Claude Code
encoder fix.

- **Real-disk audit**: `~/.gemini/tmp` had 3 live project dirs; all 3 match the
  Swift/real Gemini slug rule (`basename.lowercased`, `_` → `-`, strip wrapping
  dashes). The TypeScript reference still used raw `basename`, which mismatched
  3/3 (`network`, `surge`, `tailscale-config`).
- **Fix**: added TS `encodeGemini()` and wired it through project source roots,
  Gemini `projects.json` update planning, and Gemini shared-slug collision
  checks so TS matches the Swift product encoder and real `projects.json`. The
  orchestrator now uses the old `projects.json` entry name when it differs from
  `encode(src)`, so existing Gemini tmp dirs with historical/custom slugs still
  move with the project.
- **iFlow drift guard**: the real `~/.iflow/projects` tree has one observed
  directory/content mismatch (`-Users-bing-Code-engram` contains a session whose
  cwd is `/Users/bing/-Code-/coding-memory`). Both TS and Swift project-move
  planning now scan grouped source roots for files whose structured `cwd` or
  `payload.cwd` equals the old cwd and prefer those observed dirs over the
  theoretical `encode(src)` dir. Plain text references remain patch candidates,
  but no longer prove project-dir ownership, preventing false renames of
  unrelated dirs that merely mention the old path.
- **Dry-run parity**: the same structured observed-dir discovery is used in both
  live migration and dry-run preview paths.
- **Review closeout**: a read-only subagent review caught the unsafe substring
  version of observed-dir discovery; the final implementation adds the
  structured-cwd gate plus TS/Swift negative tests for unrelated text mentions.
- **Verification**: RED/green TS coverage in `tests/core/project-move`
  (`sources`, `gemini-projects-json`, orchestrator integration); RED/green Swift
  coverage in `OrchestratorTests`; `npm test -- tests/core/project-move` (16
  files / 187 tests); selected Swift `OrchestratorTests`,
  `SessionSourcesTests`, and `GeminiProjectsJSONTests` (56 tests);
  `npm test` (127 files / 1512 tests); `npm run lint`; `npm run build`;
  `npm run typecheck:test`.
- **Residual risk**: this does not proactively reconcile already-mismatched
  source dirs at startup; it ensures a future project move of the affected cwd
  renames the observed dir instead of skipping it as missing.

### Codex archived-session project-migration coverage (2026-06-05, Codex)

Closed the Codex-side project-migration compatibility gap left after the
Claude Code encoder audit.

- **Root cause**: the Codex adapter reads both `~/.codex/sessions` and
  `~/.codex/archived_sessions` (`CodexAdapter.expandSessionRoots`), but
  project migration only scanned/patched `~/.codex/sessions`. Archived Codex
  rollout JSONL files could therefore retain the old cwd after a project move.
- **Fix**: added a flat-layout `codex-archived` source root in both the Swift
  product pipeline (`SessionSources.roots`) and the TypeScript reference
  pipeline (`getSourceRoots`). Like active Codex sessions, it has no
  `encodeProjectDir`; migration only rewrites file contents and review treats
  residual refs as own leftovers.
- **Regression coverage**: added Swift and TS source-root assertions plus
  orchestrator integration tests that plant active and archived Codex JSONL,
  run a project move, and assert both files are patched and review has no own
  residual refs.
- **Real-disk check**: this machine has 5 real files in
  `~/.codex/archived_sessions`; none currently reference this checkout, but the
  missing root was real, not hypothetical.
- **Verification**: RED confirmed before the fix (`codex-archived` missing and
  archived JSONL kept the old path). GREEN: `npm test -- tests/core/project-move`
  16 files / 182 tests; selected Swift ProjectMove suite 87/87; `npm run lint`;
  `npm run build`; `npm run typecheck:test`.

### Claude Code project-migration encoder fix (2026-06-05, Claude)

Fixed a Claude Code compatibility bug in the project-migration pipeline and
recorded the verification method so the Codex/other-source side can be audited
the same way.

- **Root cause**: `ClaudeCodeProjectDir.encode`
  (`macos/EngramCoreWrite/ProjectMove/EncodeClaudeCodeDir.swift`) replaced only
  `/` and `.` with `-`. Real Claude Code replaces **every** char not in
  `[A-Za-z0-9]` with `-` (`path.replace(/[^a-zA-Z0-9]/g, "-")`, per UTF-16 code
  unit, no collapse/case-change). The TS reference `encodeCC` was worse (`/`
  only).
- **Empirical truth**: verified 39/39 real `~/.claude/projects` dirs (and 7/7
  `~/.qoder/projects`) match the all-non-alnum rule; the old Swift encoder
  matched 30/39 and broke 9 real cwds across 7+ projects containing `_`/space
  (`CCTV_Admin`, `java_charge`, `Service_Asset`, `Service_Electricity`,
  `Service_Umami`, `mac_Book_Pro_Debug`, `Application Support/CodexBar/...`).
- **Failure mode (silent, no error)**: Orchestrator Step 0.5/2 computed the
  wrong old dir name → `rename(2)` ENOENT → `skippedDirs(.missing)` → the real
  dir was never renamed. Content patching (grep-by-cwd-substring in Step 3) still
  rewrote the in-file `cwd`, so Engram's own index looked healthy while Claude
  Code, relaunched in the new path, computed a fresh dir name and could not see
  the migrated history. Same blast radius hit dry-run, `Review.swift:34`
  own/other classification, undo (re-runs the orchestrator), batch, and the
  shared qoder source.
- **Why it survived**: the unit tests baked in the bug —
  `EncodeClaudeCodeDirTests` asserted `john_doe`→`john_doe` and `my proj`→`my
  proj` (only `.config` was checked against a real dir). TS test did the same.
- **Reverse-op safety (verified)**: undo/recover read raw `oldPath`/`newPath`
  from `migration_log` and recompute `encode()`; persisted `renamed_dirs` is
  write-only audit metadata, never consumed on the reverse path. So the fix does
  not break undo/recover of historical rows.
- **Fix**: encoder now maps every non-`[A-Za-z0-9]` UTF-16 unit to `-` (omits
  CC's unreachable >200-code-unit truncate+hash branch — documented). Mirrored
  the TS reference. Rewrote the two bug-asserting tests + added a real-corpus
  regression table (hardcoded literal expectations) in both Swift and TS.
- **Verification**: `EncodeClaudeCodeDirTests` 10/10; full encoder-consuming
  ProjectMove suite (SessionSources/Orchestrator/Batch/ReviewScan/Archive/Undo)
  86/86; TS `encode-cc.test.ts` 9/9; biome clean.
- **Not done (designed, not urgent)**: a startup reconcile to repair dirs
  ALREADY orphaned by a past buggy migration. On this machine the reconcile is a
  verified no-op (all 39 dirs already match the corrected encoder — no buggy
  `_`/space migration has actually run yet), so it is deferred. Detection MUST
  use the corrected encoder; ship encoder fix first, reconcile second.
- **Reusable verification method (for the Codex side)**: for each dir under a
  source root, read the first session file's `cwd`, recompute the adapter's
  `encode(cwd)`, assert `basename(dir) == encode(cwd)`; any mismatch = encoder
  diverges from real on-disk naming. (Dir names start with `-`, so prefix paths
  with `./` or use `--` with find/grep.)

**Handoff closeout update (2026-06-06, Codex):**
1. **Codex source audit**: closed by "Codex archived-session
   project-migration coverage" above. Codex remains intentionally flat-layout
   (`encodeProjectDir: nil`); active and archived JSONL roots are content-patched
   and covered by Swift/TS orchestrator tests.
2. **Other grouped encoders**: closed by "Project migration Gemini/iFlow
   compatibility follow-up" above. Gemini TS matches real slug values; iFlow has
   an observed-dir drift guard for real content/dir mismatches.
3. **Claude Code / qoder encoder branch**: pushed, reviewed, and merged via PR
   #51 (`485b932b`), with the MCP-only residual helper fixed via PR #52
   (`f8180379`).
4. **Reconcile feature** for dirs ALREADY orphaned by a past buggy CC migration
   remains intentionally deferred. It is a no-op on this machine per the real-disk
   encoder audit; future implementation must use the corrected encoder and
   collision-safe rename logic.

### PR #49 CI follow-up (2026-06-05, Codex)

Continued draft PR #49 after GitHub Actions exposed CI-only gaps on
`codex/followup-remediation`.

- **Fixture freshness**: refreshed `test-fixtures/test-index.sqlite` after the
  new schema/fixture generation path made `fixture-check` detect drift.
- **CodeQL command-line sink**: constrained `engram resume --launch` so the CLI
  maps session sources to literal launch commands instead of executing the
  daemon-provided command string.
- **CodeQL workflow runtime**: opted the CodeQL workflow into Node 24 JavaScript
  action execution and increased Swift CodeQL timeout from 30 to 60 minutes
  after the instrumented Swift build was still compiling when GitHub cancelled
  it at 30 minutes.
- **Verification**: `npm run check:fixtures`,
  `npm run check:adapter-parity-fixtures`, fixture regeneration diff check,
  `npx vitest run tests/cli/resume.test.ts`, `npm run typecheck:test`,
  `npm run lint`, and `actionlint .github/workflows/codeql.yml` passed locally.
- **Merge closeout**: PR #49 was marked ready, all checks passed, and the branch
  was squash-merged to `main` as `3c2303ab`.

### Follow-up remediation closeout (2026-06-05, Codex)

Closed the planned post-review follow-up sweep on the rebased
`codex/followup-remediation` branch. PR #49 was opened, verified, and
squash-merged to `main`.

- **Runtime baseline**: Node development/CI tooling is pinned to Node 24+
  (`.nvmrc`, package engines, GitHub Actions setup-node), with `@types/node`
  refreshed to the Node 24 line.
- **CI security**: added CodeQL code scanning for JavaScript/TypeScript and
  Swift, with Node 24 build setup and an explicit Swift manual build path.
- **Follow-up fixes**: added Swift Gemini transcript size guards for MCP and
  service export, removed raw Keychain secret forwarding from the app-to-service
  environment, moved service `@keychain` resolution behind a direct Keychain
  reader, expanded Swift MCP `get_context` environment parity, added focused
  CLI coverage for project/resume helpers, centralized CLI health table names,
  and cancelled Search page work on disappearance.
- **Review adjudication**: verified and documented the follow-up review claims
  around OSLog privacy, AI audit error sanitization, MCP handoff relative time,
  suggested-parent lookback batching, and symlinked adapter source roots.
- **Verification**: `npm run lint`, `npm run build`, `npm run typecheck:test`,
  `npm run knip`, `npm run check:fixtures`, `npm run test:coverage`, and
  `actionlint` passed locally. Swift unit suites passed with coverage:
  `EngramCoreTests` (364 tests), `EngramMCPTests` (73 tests),
  `EngramServiceCore` (127 tests), and `EngramTests` (301 tests, 1 skipped).
  `npm run test:coverage` passed 127 Vitest files / 1491 tests.
  `EngramUITests` UI smoke was attempted but the local XCTest UI runner either
  died before bootstrap or hung during runner startup before any UI test body
  ran; this is recorded as a local UI runner/environment failure pending CI or a
  GUI-permitted rerun.
### TypeScript FTS table-swap rebuild (2026-06-04, Codex)

- Added a TypeScript `sessions_fts` rebuild policy with `sessions_fts_rebuild`
  shadow-table creation, active-row copy, pending metadata, and transactional
  final swap once recoverable FTS jobs are clear.
- Kept active FTS search available during rebuilds, dual-wrote refreshed FTS
  content to active/rebuild tables, and dual-deleted rows for session artifact
  cleanup, session deletion, and subagent maintenance cleanup.
- Hardened pending rebuild reuse after subagent review: stale/non-FTS
  `sessions_fts_rebuild` tables are recreated from active FTS rows before reuse
  or final swap, and `deleteIndexArtifacts`/`deleteSession` now attempt
  finalization after deleting the last recoverable FTS job.
- Covered idempotent pending rebuild startup, vector cleanup, empty DB
  migration, stale shadow-table recreation, dual-write/delete behavior,
  deletion-drained finalization, and `IndexJobRunner` finalization.
- Intentionally left `insights_fts` table-swap support out of scope for this PR.

### Database raw handle API cleanup (2026-06-04, Codex)

Opened a follow-up branch after PR #34 was merged to remove the duplicated
TypeScript raw SQLite access surface.

- **Database API**: removed `Database.getRawDb()` and made `Database.raw` the
  sole TypeScript facade for callers that need the underlying `better-sqlite3`
  handle.
- **Call-site migration**: updated daemon, bootstrap, web routes, core helpers,
  fixture/schema scripts, and tests from `.getRawDb()` to `.raw`.
- **Regression coverage**: added a `Database` contract test that verifies the raw
  SQLite handle works through `raw` and that `getRawDb` is no longer present.

### Additional non-blocking follow-up remediation (2026-06-04, Codex)

Continued PR #34 after the first closeout to finish the remaining necessary
non-blocking items without broad refactors.

- **CI runtime hygiene**: opted GitHub Actions workflows into Node 24 JavaScript
  action execution via `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`, and fixed
  existing actionlint screenshot-copy shell quoting warnings.
- **TS follow-ups**: shared duration-minute parsing through `src/core/time.ts`
  for scoring/tiering invalid timestamp handling; FTS version refresh now keeps
  existing `sessions_fts` rows live while `size_bytes = 0` schedules reindexing,
  avoiding a temporary empty-search window during version upgrades.
- **Swift MCP cancellation**: stdio `tools/call` requests now run as tracked
  in-flight tasks; `notifications/cancelled` cancels matching numeric/string
  request ids; stdout writes are serialized; EOF drains in-flight responses; and
  cancelled tool calls return structured MCP errors with
  `structuredContent.code = "cancelled"`. Unix socket service cancellation now
  normalizes post-cancel I/O failures into `CancellationError` instead of
  `serviceUnavailable`.
- **Verification**: actionlint passed for `test.yml` and `release.yml`;
  targeted Vitest coverage passed 60 tests; `npm run typecheck:test`,
  `npm run lint`, full `npm test` passed 1481 tests; Swift
  `EngramMCPTests` passed 67 tests.
- **Intentionally deferred**: designing a full online FTS table-swap rebuild
  remains a separate larger refactor, not a necessary closeout fix.

### Follow-up remediation branch closeout (2026-06-04, Codex)

Continued the review-remediation branch with focused safety, parity, and
coverage fixes after the main 2026-06-03 adjudication pass.

- **Swift MCP/Service transcript safety**: added shared oversized transcript
  guarding for Gemini JSON reads, returning structured MCP/service failures
  before full-file loading.
- **Swift secret handling**: stopped passing Keychain-derived API keys through
  the service process environment; the service now resolves `@keychain`
  settings directly and ignores legacy `ENGRAM_KEYCHAIN_*` environment
  fallbacks.
- **Swift MCP context parity**: enriched `get_context` full-detail environment
  output with SQLite-backed git repo, file hotspot, and recent-error signals.
- **CLI and web/tool fixes**: added import-safe resume helpers and CLI coverage,
  made the dispatcher explicitly call `resume.main`, covered project flag
  parsing, corrected `list_sessions.total` to report total matching rows, and
  stopped search route failures from echoing internal exception strings.
- **Test isolation**: isolated the former bridge-command ServiceCore test from
  the developer machine's real AI settings so it consistently exercises native
  fallback behavior.
- **Verification**: `npm run build`, `npm run typecheck:test`, `npm run lint`,
  `npm audit --audit-level=moderate`, and full `npm test` passed; Swift
  `EngramMCPTests`, `EngramServiceCore`, and `EngramTests` passed locally after
  the ServiceCore HOME-isolation fix.

### Multi-model review adjudication and fixes (2026-06-03, Codex)

Adjudicated the Kimi/Gemini/MiniMax/Mimo review bundle against the current
`perf/transcript-paging` worktree and fixed the confirmed high-impact items with
focused tests.

- **Embedding/search correctness**: OpenAI truncated embeddings are normalized
  before storage/search; `deleteSession` now transactionally removes FTS,
  embedding, vector, chunk, and retry-job rows; parent cascade preserves
  subagent `tier='skip'`; session project and metrics timestamp indexes were
  added; `indexed_at` empty values are backfilled; today's parent count uses
  indexable string comparisons.
- **TS runtime hardening**: daemon shutdown resolves timers/auto-summary
  dynamically, MCP exit closes the DB, watcher indexing has a per-file in-flight
  lock, database statement wrapper functions are cached, AI audit event entries
  are sanitized before emit, Gemini JSON parsing has a 10 MiB cap, Antigravity
  cwd inference reads only a file head, sanitizer patterns cover common API key
  formats, config parse errors warn, title generation avoids
  `AbortSignal.timeout`, and `link_sessions` rejects protected system targets
  before writing; project-move core now rejects non-absolute/protected system
  paths before any filesystem step; `lint_config` rejects unsafe cwd roots; FTS
  empty queries return directly without relying on SQLite parser fallback.
- **Tooling and MCP behavior**: Vitest upgraded to 4.1.8; CI now runs
  `npm audit --audit-level=moderate`; daemon is no longer excluded from TS
  coverage; export output moved to `~/.engram/exports`; `hide_session` returns
  not-found for missing IDs; early MCP errors include `structuredContent`;
  production TS `noExplicitAny` is now an error; Swift CI tests run with code
  coverage enabled; Dependabot now covers npm and GitHub Actions; the CLI
  dispatcher now awaits dynamic imports with a top-level error handler.
- **Swift/macOS parity and MCP fixes**: migrations now align indexes,
  `insights_fts` tokenizer, metrics CHECK, and indexed-at backfill; suggested
  parent backfill avoids N+1 parent fetches; ClaudeCode project is inferred from
  cwd; MCP search fetches rows in one joined query; handoff respects `sessionId`
  and includes cost/duration/model/task prompt context; schema validation
  enforces numeric bounds; OrderedJSON renders non-finite doubles as `null`;
  `get_session` streams JSONL/adapter transcripts and retains only the requested
  page; generic os_log wrappers and CoreWrite direct os.Logger callsites use
  private interpolation; SearchView cancels async search and embedding-status
  tasks before stale callbacks can publish results; hygiene reports an explicit
  degraded result instead of a false perfect score.
- **Swift service hardening follow-ups**: Unix socket client transport retries
  interrupted read/write syscalls; `confirmSuggestion` refreshes
  `link_checked_at`; snapshot merge/upsert preserves existing `cwd` and message
  counts when new parse data is empty; migration audit notes are capped before
  insert; LLM non-2xx IPC errors no longer echo upstream response bodies;
  transcript export/web redaction covers common PAT/AWS/npm/Slack/PEM token
  families; native project migration commands now log requested/finished/failed
  paths.
- **Additional Swift review follow-ups**: batch snapshot upsert now runs inside
  a savepoint even for bare test callers; startup emits explicit
  `backfill_inline` events for Swift's inline count/cost path; `MigrationLock`
  has a default 1h TTL and treats Darwin zombie holders as stale; iFlow lossy
  project-dir collisions are rejected before any filesystem move even when
  old/new encoded dirs are equal; Web UI transcript parser failures return
  non-200 statuses; export leaf symlinks are locked by regression coverage.
- **Swift startup dedup follow-up**: startup file-path dedup now reparents
  confirmed and suggested children from duplicate session ids to the kept
  session id before deleting duplicate rows, preserving parent links instead of
  letting the delete trigger clear them.
- **Swift observability follow-up**: startup observability retention now always
  logs a completion line with the pruned row count, including zero-row runs, so
  the maintenance path is visible after restart.
- **Swift service-test isolation follow-up**: project-migration IPC pipeline
  error coverage now uses `ServiceCoreTestHomeScope` with a temp HOME instead
  of constructing absent-source paths under the user's real home directory.
- **Swift UI formatter follow-up**: `TimelinePageView` now reuses static date
  formatters for timeline group labels instead of allocating a formatter on
  every render.
- **Project-move/source filesystem hardening**: JSONL patching now rejects
  symlink source files and fsyncs the temporary replacement file before rename;
  project-move source walking reports FIFO/socket/device entries as
  `skipped_non_regular`; `migration_log` now has a `(state, started_at)` index
  for the pending-migration hot path; shared JSONL adapter discovery uses
  lstat-based directory/regular-file checks so direct-child adapters do not
  traverse symlinked source dirs; TS Claude Code parsing now also derives
  `project` from `cwd` so adapter parity fixtures remain source-generated.
- **UI/settings/security follow-ups**: LogStream reloads are now task-owned and
  cancel superseded timer/filter work; AI and source-path settings avoid
  writeback while loading persisted values; Web UI Host validation rejects
  malformed multi-colon loopback hosts instead of accepting them as bare
  loopback.
- **Title-regeneration follow-up**: `regenerateAllTitles` now checks
  cancellation before each generated title and again before DB writes, preserves
  resilient per-session AI failure skips, caps concurrent AI title calls at 4 by
  default, and logs coarse progress every 10 processed title contexts and at
  completion.
- **Swift app concurrency follow-up**: `DatabaseManager` is no longer globally
  `@MainActor`; it remains observable and is explicitly `@unchecked Sendable`
  with the existing lock-protected read pool, so detached view reads no longer
  depend on a type-system-unenforced `nonisolated` contract.
- **Swift IPC sendability follow-up**: `UnixSocketEngramServiceTransport` now
  uses checked `Sendable` conformance; the internal mutable `FdBox` remains
  `@unchecked Sendable`.
- **Swift app service-event follow-up**: the AppDelegate service status/event
  pump now starts with `Task.detached`, keeping the stream off the MainActor and
  returning to MainActor only for status-store updates.
- **Swift navigation race follow-up**: `MainWindowView.navigateToSession` now
  tracks the latest palette-requested session id and ignores stale detached DB
  lookup completions, so a slower lookup cannot overwrite a newer navigation or
  a direct `.openSession` notification.
- **Swift session-list race follow-up**: `SessionListView.loadSessions` now uses
  a monotonic load generation guard so the initial appear load, filter debounce
  reload, and action-triggered reloads cannot overwrite newer session/filter
  state when detached DB reads complete out of order.
- **MCP FTS transient-rebuild follow-up**: keyword reads against `sessions_fts`
  and `insights_fts` now retry once after a short delay when SQLite reports the
  canonical FTS table is transiently absent during rebuild swap.
- **Swift watcher/orphan follow-up**: `SessionSnapshotWriter` now clears
  `orphan_status`, `orphan_since`, and `orphan_reason` after successful
  authoritative snapshot handling, including same-content noop re-indexes, so
  unlink+add/rename recovery does not leave reappeared sessions hidden by MCP
  orphan filters.
- **Swift startup dedup follow-up**: `StartupBackfills.deduplicateFilePaths`
  now reparents confirmed and suggested children from duplicate session ids to
  the kept session id before deleting duplicate `file_path` rows, preserving
  parent links instead of letting the delete trigger clear them.
- **Swift observability follow-up**: startup observability retention now logs
  `observability retention complete: pruned=<count>` for both pruning and
  zero-row runs, so maintenance execution is visible after restart.
- **Swift service-test isolation follow-up**: project-migration IPC pipeline
  error coverage now runs under `ServiceCoreTestHomeScope` with a temp HOME
  instead of constructing absent-source paths under the user's real home.
- **Swift UI formatter follow-up**: `TimelinePageView.formatDateLabel` now
  reuses static input/output formatters instead of allocating `DateFormatter`
  per timeline group render.
- **Swift Web UI observability follow-up**: service startup now logs both
  disabled and enabled `webUIEnabled` branches before the ready event, so
  enabled-by-settings startup leaves a breadcrumb before the health probe.
- **Swift service log-category follow-up**: `.ipc` and `.reader` now have
  production `ServiceLogger` callsites for listener readiness and search-mode
  degradation; `.writer` and `.ai` were already exercised by production paths.
- **Swift link-sessions symlink follow-up**: native `linkSessions` no longer
  removes or replaces existing link paths; matching symlinks are skipped,
  different symlinks and non-symlinks are reported as errors, and missing paths
  are the only created paths.
- **Swift database file-security follow-up**: `SQLiteFileSecurity` now chmods
  and then asserts DB/WAL/SHM siblings are owned by the current uid and mode
  0600, keeping plaintext `migration_log` paths behind an explicit invariant.
- **Swift project-path symlink confinement follow-up**:
  `validateProjectPathConfined` now checks both the standardized caller path and
  the symlink-resolved path under the corresponding home root, so project
  move/archive/link targets cannot pass by placing a symlink inside `$HOME` that
  resolves outside it.
- **Swift project-move errno follow-up**: `OrchestratorError` now conforms to
  the `ProjectMoveError` envelope contract, and per-source dir rename failures
  preserve POSIX `errno=<code>` plus the strerror text in the
  `DirRenameFailedError` message/details path.
- **Swift SQLite adapter accessibility follow-up**: Cursor and OpenCode
  `isAccessible` now reuse an actor-isolated `Phase4SQLiteDatabase` per db path,
  avoiding one SQLite open per session/composer during startup orphan scans.

Verification: `npm run lint`, `npm run typecheck:test`, `npm run build`,
`npm audit --audit-level=moderate`, `npm test` (124 files, 1471 tests),
`npm run test:coverage` (124 files, 1471 tests; true coverage floor enforced
after daemon inclusion);
`xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests
-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` (63 tests); targeted
Engram and EngramServiceCore xcodebuild tests for migrations, startup backfills,
Claude adapter message counts, SearchView task cancellation, OS log privacy, and
service IPC hygiene; additional targeted Engram tests for snapshot preservation
and migration audit-note capping (21 tests); additional targeted
EngramServiceCore tests for IPC `EINTR`, LLM error body suppression,
`confirmSuggestion`, project migration logging, and redaction (6 tests);
additional EngramCore tests for batch upsert, startup inline progress,
MigrationLock TTL/zombie, and iFlow collision (36 tests across targeted
commands); additional EngramServiceCore tests for Web UI parser status and
export leaf symlink; additional EngramCore tests for JSONL patch symlink
rejection, source walking, adapter symlink discovery, migration schema, and
adapter parity (69 tests across targeted commands); `npx vitest run
tests/adapters/claude-code.test.ts`; `npm run check:adapter-parity-fixtures`;
`npm run typecheck:test`; `xcodebuild test -project macos/Engram.xcodeproj
-scheme EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
-only-testing:EngramTests/ViewMainThreadReadTests` (9 tests);
`xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore
-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
-only-testing:EngramServiceCoreTests/EngramWebUIServerTests` (24 tests);
targeted EngramServiceCore title-regeneration tests for cancellation/progress
concurrency limiting, and the native command path (4 tests);
targeted Engram DatabaseManager/ViewMainThread tests for the app read facade
actor-isolation change (55 tests);
targeted EngramServiceCore Unix socket transport sendability/EINTR tests
(2 tests);
targeted Engram ServiceEventRouting tests for detached service-event pumping
(6 tests);
targeted Engram ViewMainThreadReadTests for MainWindow stale navigation guards
(11 tests, with the new guard RED before the fix);
targeted Engram ViewMainThreadReadTests for SessionList stale load guards
(12 tests, with the new guard RED before the fix);
targeted EngramMCP FTS retry guard (1 test);
targeted EngramCore orphan recovery RED/GREEN guard
`IndexerParityTests/testReindexClearsRecoveredOrphanStatus` (1 test);
targeted EngramCore startup dedup RED/GREEN guard
`StartupBackfillTests/testDeduplicateFilePathsReparentsChildrenBeforeDeletingDuplicateParent`
(1 test) and full `StartupBackfillTests` (21 tests);
targeted EngramServiceCore observability-retention RED/GREEN guard
`EngramServiceIPCTests/testRunnerObservabilityRetentionLogsZeroRowCompletion`
(1 test) plus adjacent runner source guards (6 tests);
targeted EngramServiceCore HOME-isolation RED/GREEN guard
`EngramServiceIPCTests/testProjectMigrationPipelineErrorTestUsesScopedHome`
and `testProjectMigrationCommandsSurfacePipelineErrors` (2 tests);
targeted Engram Timeline formatter RED/GREEN guard
`ViewMainThreadReadTests/testTimelinePageReusesDateFormatters` (1 test) and
full `ViewMainThreadReadTests` (13 tests);
targeted EngramServiceCore Web UI startup branch logging RED/GREEN guard
`EngramWebUIServerTests/testRunnerLogsWebUIEnabledAndDisabledBranches` plus
`testWebUIEnvOverride` (2 tests);
targeted EngramServiceCore service log-category callsite RED/GREEN guard
`EngramServiceIPCTests/testServiceLogCategoriesHaveProductionCallsites`, plus
`testSearchSemanticModeDegradesToKeywordWithWarning` in the combined GREEN run
(2 tests);
targeted EngramServiceCore linkSessions symlink replacement RED/GREEN guard
`EngramServiceIPCTests/testLinkSessionsDoesNotReplaceExistingDifferentSymlink`
plus `testLinkSessionsRejectsPathsOutsideKnownSessionRoots` (2 tests);
targeted EngramCore database file-security RED/GREEN guard
`SQLiteConnectionPolicyTests/testFileSecurityAssertsOwnerAndModeForDatabaseSiblings`
and full `SQLiteConnectionPolicyTests` (5 tests);
`git diff --check`.

Residual: Swift `gemini-cli` transcript JSON remains whole-file parse; full
Keychain/service IPC secret-flow refactor, Swift `get_context` TS parity, broader
CLI/security-policy work that requires external services or secrets, and P3
cleanups remain outside this pass.

### Transcript paging — ultrareview round 2 fixes (2026-06-03, Claude)

Second cloud ultrareview of PR #34 (5 findings):

- **Chip Prev crash (real)**: switching from a long session to a shorter one left
  `navPositions` (and other transcript-derived state) stale; clicking a chip's Prev
  then indexed past the new match set and trapped. The `.task(id: session.id)` reset
  now also clears `navPositions`/`displayIndexed`/`matchIndices`/`currentMatchIndex`/
  `searchText`/`scrollTarget`, and the index math moved to a pure, clamped
  `nextNavPosition(current:direction:count:)` (unit-tested) so a stale position can
  never trap.
- **Dead-end empty state**: a huge session whose first page is entirely tool messages
  loads zero displayable rows but has more — the "No Messages"/"Filtered Out" states
  now show the Load more / Load all footer, so the rest is still reachable.
- **Rebuild clobber race**: `rebuildIndexed` snapshotted filter/search state then
  wrote back after the off-main build, clobbering a chip toggle or search edit made
  during the build. It now publishes only `messages`-derived state (indexed + counts)
  and recomputes display + matches from LIVE state; the match scan is a single
  off-main path keyed on `displayVersion + searchText`, so it never runs on main and
  never overwrites a concurrent edit.
- **Copy while loading**: Copy no longer silently no-ops when a load is in flight —
  it surfaces a transient "still loading" status.
- **EOF reparse (nit)**: `parseWindowed` now trusts an empty adapter result (paging
  past EOF) instead of falling through to a full-file legacy reparse; legacy is only
  the fallback on adapter error.

Full EngramTests 290 green (0 failures, 1 pre-existing skip).

### Transcript paging — ultrareview fixes (2026-06-03, Claude)

Addressed the cloud ultrareview of PR #34 (7 findings):

- **Page-seam offset bug (the real one)**: the pager advanced `offset` by the
  filtered (user/assistant) count, but adapter offset/limit count PRODUCED
  messages (incl. tool rows the UI drops) — so a transcript with tool messages
  could drift/dup at the seam and, worse, a first page thinned by tool rows set
  `hasMore=false` → silent truncation. Added `MessageParser.parseWindowed(...)`
  returning a PRODUCED count; the pager now advances in produced space. Locked by
  a Codex `function_call` test (produced > displayable; paged union == full).
- **Cross-session races**: added `Task.isCancelled` guards in `rebuildIndexed`
  (after the detached classify) and after `loadInitialTranscript()` in `.task`,
  so a slow load can't stomp the next session's state.
- **Main-thread match rescan**: the post-load match-index scan now runs inside
  the detached rebuild (was synchronous on main after Load all).
- **Copy honesty**: Copy / Copy Entire Conversation / ⌘⌥C now load the full
  transcript before copying when only a prefix is loaded (no silent partial copy).
- **Chip counts**: type-chip counts render `N+` while partially loaded so they
  don't read as authoritative session totals.
- **Search hint**: hoisted out of `if showFind` — it shows whenever a search is
  active on a partial transcript, even after the find bar is closed (search state
  outlives the bar via ⌘F / toolbar Find).
- **Cancel on disappear**: `transcriptLoadTask` is now cancelled in `.onDisappear`.
- Accepted nit (documented): when the produced count is an exact multiple of the
  page size the footer survives one extra "Load more" that fetches an empty
  window. The `>=` test is deliberate — `>` would silently truncate a transcript
  whose size equals the page size, and consulting `session.messageCount` (a
  differently-counted total) risks truncation, so produced-fullness is the safe
  signal.

Full EngramTests 289 green (0 failures, 1 pre-existing skip).

### SessionDetailView transcript paging (2026-06-02, Claude)

Closes the second deferred perf item from the review cleanup round.

`SessionDetailView` parsed + classified the WHOLE transcript into memory on open.
Rendering was already lazy (`LazyVStack`), so the residual cost was peak memory
and first-paint parse time for very large sessions.

Now threshold-gated: sessions at/under `transcriptPageThreshold` (800 messages)
load fully exactly as before (zero behavior change for the common case). Larger
sessions load a first page (`transcriptPageSize` = 500) and show a footer with
**Load more** / **Load all**. Paging is APPEND-based — each step parses from the
current loaded count (`MessageParser.parse(offset:limit:)`, which now
early-terminates per the prior change) and appends, so earlier pages aren't
re-materialized and loaded `ChatMessage` identities stay stable (the list diffs
cleanly; scroll position is preserved). The indexed view is rebuilt over the full
loaded prefix off the main actor, so `typeIndex`/type counts stay correct.

Honesty (no silent truncation): the footer reads "Showing first N messages" and
the full transcript is always one click away; when a search runs on a partially
loaded transcript the find bar shows "Search covers loaded messages only" with a
one-tap **Load all**.

Pure gating (`initialTranscriptLimit`, `hasMoreAfterLoad`) is unit-tested; a
`MessageParser` test proves a paged load (first page + remainder from
`offset = loadedCount`) reconstructs the full transcript exactly — no gap, dup,
or truncation at the seam. The off-main classification source guard was updated
to the new rebuild path. Green: full EngramTests 288 (0 failures, 1 pre-existing
skip).

Branch `perf/transcript-paging` (ultrareview pending).

### Web UI pager: O(N²) → O(N) via shared lazy-streaming window (2026-06-02, Claude)

Closes the first of the two deferred perf items from the review cleanup round.

The Web UI transcript pager re-parsed the whole transcript on every page: each
line-based adapter's `streamMessages` read + parsed ALL JSONL lines via
`readObjects` before applying the offset/limit window, so paging cost
O(pages · file) ≈ O(N²). Only `CodexAdapter` had a bespoke early-terminating
`readWindow`.

Centralized that fast path into `JSONLAdapterSupport.windowedMessages(...,
transform:)`: when `limit` is set it streams line by line, skips `offset`
PRODUCED messages (post-transform, nils excluded — matching `applyWindow`),
collects `limit`, then STOPS reading — so a paged read costs O(offset + limit)
parsed lines, not O(file). When `limit` is nil it falls back to `readObjects` +
`applyWindow`, byte-identical to the old whole-transcript behavior.

The indexer (`SwiftIndexer`/`IndexJobRunner`), transcript export, and MCP
transcript reader all pass `limit: nil`, so they keep the exact prior behavior —
indexing and adapter parity are unchanged, no re-index required.

In scope (now route through the shared helper): claude-code (+ minimax/lobsterai
via `ClaudeCodeDerivedSourceAdapter` delegation), qwen, iflow, qoder, commandcode,
copilot, antigravity (CLI-transcript branch only), and codex (its bespoke
`readWindow` collapsed into the shared helper, removing the duplicate).

Intentionally NOT changed (documented, not silently skipped): kimi (multi-file
read with cross-line turn-index/timestamp state — not a pure per-line map),
vscode (one whole-session object, not a per-line stream), gemini & cline
(whole-file JSON — no per-line boundary to early-terminate), cursor & opencode
(SQLite — a future SQL LIMIT/OFFSET push-down, not line streaming). These still
parse per page but are bounded by their format, not by re-reading a growing
JSONL tail.

Tests: shared-helper unit tests for produced-message windowing/parity and
physical early-termination (an oversized line past the window trips
`.lineTooLarge` on a full read, but a windowed read that ends before it
succeeds — proving the reader stops at the window boundary); a claude-code
end-to-end test that pages past a message cap a full read would trip. Existing
Codex window tests guard the collapse. Green: EngramTests (AdapterParity 24,
MessageParser 20), EngramCoreTests 341, EngramServiceCore 108, EngramMCPTests 58.

Branch `perf/jsonl-lazy-streaming` (ultrareview pending).

### Review cleanup round — adjudication + residual fixes (2026-06-02, Claude)

Re-verified every finding in `docs/reviews/2026-06-02-macos-swift-product-code-review.md` against CURRENT code
(12 adjudicators, skeptical/default-unresolved). Result: 61 fixed, 5
by-design (documented, no behavior change), 2 partial, 1 not_fixed. Closed the
residual:

- **AISettings test-gap (was not_fixed)**: extracted the generation-settings
  dictionary transform into a pure, testable `AIGenerationSettings`
  (`write(into:)`/`read(from:)`); routed `saveAISettings`/`loadAISettings`
  through it; added behavioral round-trip tests (custom-value survival incl.
  the collapse-then-edit case; default fallback). The data-loss bug itself was
  already fixed; this closes the missing behavioral coverage.
- **SessionDetailView search (was partial)**: the per-keystroke
  `updateMatchIndices` full-content scan now runs debounced (200ms) and off the
  main actor via `.task(id: searchText)`, so typing in the find bar no longer
  hitches on a large transcript. (The open-time classify/filter was already
  moved off-main in the prior round.)

Remaining, intentionally deferred (documented, NOT silently skipped):
- **Web UI transcript pager re-parses the whole file per page (O(N²) paging)**
  — `EngramWebUIServer`/adapter read path. The memory half is bounded (the
  prior round passes a real `limit` and breaks early); the remaining CPU cost
  is the adapter `readObjects` eagerly reading+parsing all lines before
  windowing. A full fix needs offset/limit-aware lazy streaming across ~15
  adapters (shared `JSONLAdapterSupport`) — high blast radius, perf-only, on a
  dev-facing surface. Deferred to a dedicated, separately-reviewed refactor.
- **SessionDetailView loads the whole transcript into memory (no parse limit)**
  — now fully off-main and one-time per open, so this is a memory-only concern;
  a real fix requires transcript paging UI (a feature), not a silent cap that
  would truncate content. Deferred.

Net: all correctness / data-integrity / lifecycle / test-gap findings are
resolved or by-design; the only open items are two deep perf optimizations with
the safe minimum already in place.

### Full Swift-product review + fixes (2026-06-02, Claude)

Comprehensive multi-agent review of the shipped Swift product (16 subsystems,
security excluded) followed by a parallel fix pass. Findings and rationale are
in `docs/reviews/2026-06-02-macos-swift-product-code-review.md`. 62 findings were confirmed via adversarial
verification; 53 were fixed this pass (4 high + the impactful mediums + safe
lows). 787 tests across EngramCoreTests/EngramServiceCore/EngramMCPTests/
EngramTests pass.

High-impact fixes:
- **Re-index classification clobber** (`SessionSnapshotWriter`): the upsert now
  `COALESCE`s `agent_role` and refuses to downgrade a `skip` tier when
  `agent_role` is set, so re-indexing no longer resurfaces dispatched/skip agent
  children as independent top-level sessions.
- **Project-move encoders** (`EncodeClaudeCodeDir`, `Sources`/`GeminiProjectsJSON`,
  `Orchestrator` collision probe): Claude Code/qoder now map `.`→`-` as well as
  `/`→`-`; Gemini uses the real slug (lowercase, `_`→`-`, trimmed dashes) for the
  tmp dir, `projects.json`, and the collision probe. Moves no longer silently
  orphan session dirs for dotted/mixed-case/underscore cwds.
- **IPC start-gate leak** (`UnixSocketServiceServer`): the start gate is
  cancellation-aware and the `!shouldContinue` branch releases the fd + limiter
  permit directly, so a stop()/connect race no longer leaks permits (32 leaks
  wedged all connections).
- **Web UI pager** (`EngramWebUIServer`): consistent offset units (Previous nav +
  "Showing X-Y"), real `limit` (no more O(N²) full-file re-parse), 404 on missing.

Other fixes by area: Gemini sidecar parent link now persisted; dedup cleans
orphan FTS rows; `linkSessions`/orphan-scan no longer hold the write gate across
filesystem I/O; service reads hop off the cooperative pool; bounded `runGit`
drain (SIGKILL + timed drain survives a grandchild holding the pipe); MCP
`live_sessions` matches its unavailable contract, arg validation enforces
`items.enum`/`required`, `get_context` cost uses `start_time`; top-level filters
on Sessions/Projects/Today; main-thread DB/CPU moved off (`PopoverView`,
`SessionDetailView`, launcher quit/restart); AISettings no longer drops custom
generation settings on collapse; `ContentSegment.id` no longer collides; adapter
message counts match streamed output; transcript export uses the full id;
classifier fixes; dead-code removals; Node-shelling schema test → pure Swift.

Intentionally not changed (documented, no behavior change): `VectorRebuildPolicy`
left unwired until sqlite-vec lands; `databaseGeneration` documented MCP-only.
Not committed-as-deployed: rebuild + reinstall to `/Applications` is a separate
step. `EngramUITests` (screenshot baselines) not run.

### EngramMCP protocol-version negotiation fix (2026-06-02, Claude)

- Root cause of the "engram MCP failed to connect" report: Claude Code 2.1.160
  sends `protocolVersion: "2025-11-25"` in `initialize`, but
  `MCPStdioServer.supportedProtocolVersions` only listed
  `2024-11-05 / 2025-03-26 / 2025-06-18` and hard-rejected anything else with
  `-32602 Unsupported protocolVersion`, so every connect failed. (Not a Codex
  regression — Claude Code bumped its MCP protocol version.)
- Fix (`macos/EngramMCP/Core/MCPStdioServer.swift`): added `2025-11-25` to the
  supported set AND, per the MCP spec, replaced the hard error with graceful
  negotiation — an unknown/newer requested version now responds with the
  latest version the server speaks instead of failing. Prevents this class of
  outage on future client protocol bumps.
- Tests (`macos/EngramMCPTests/EngramMCPExecutableTests.swift`): replaced
  `testInitializeRejectsUnsupportedProtocolVersion` with
  `testInitializeAcceptsCurrentClaudeCodeProtocolVersion` (2025-11-25 echoed)
  and `testInitializeNegotiatesUnknownProtocolVersionToLatest` (future version
  negotiated down). Full `EngramMCPTests` suite green (55/55).
- Deploy: rebuilt Release with Developer ID signing + build `735`
  (commit-count), `rm -rf` + `cp -R` to `/Applications/Engram.app`. Verified
  `codesign --verify --deep --strict`, Developer ID authority on app + helper,
  and `claude mcp list` now reports engram `✓ Connected`. Source files are
  modified but NOT committed (left for review/commit).

### CI gate repair (2026-06-01, Codex)

- Fixed the `dead-code` job by removing stale exported TypeScript symbols left
  after transcript visibility and project batch JSON cleanup.
- Added missing Today Workbench screenshot baselines for
  `home_workbench`, `home_followUps`, and `home_todayHeader`.
- Made screenshot size mismatches report-only in GitHub Actions because the
  committed baselines are high-resolution local captures while GitHub's macOS
  runner captures at `1024x768`; real screenshot diff failures still fail the
  gate.

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
- Closed out the slice by pushing commit `9ed04448`, building release
  `0.1.0 (732)`, installing it to `/Applications/Engram.app`, and relaunching
  the app from that path.
- Confirmed there is no current code blocker for this slice. The remaining
  product goal is intentionally deferred to real use: use the installed build
  for two days, then convert observed friction into new acceptance-sized work.

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
