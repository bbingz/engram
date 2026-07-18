# Engram Full-Codebase Audit — 2026-07-17

## Methodology

Two-round multi-agent audit orchestrated by Claude (Fable 5), with Claude Opus 4.8
as the reviewing model.

- **Round 1** — 12 subsystem reviewers: service-runtime, db-write, archive-sync,
  db-read, adapters, tiering-linking, mcp, app-ui, concurrency-memory,
  ts-reference, build-ci-docs, recent-changes (regression review of the
  2026-07-15..17 merges).
- **Completeness critic** — an independent agent audited round 1's coverage
  against the repo tree and identified blind spots.
- **Round 2** — 7 targeted reviewers on those blind spots: project-move
  (~5.6K LOC migration engine), remote-server (~3.3K LOC), ai-search (Swift
  semantic/hybrid runtime), mcp-read-parity, app-ui-2 (uncovered views),
  adapters-2 (Swift-only adapters + sidecar + cache), consistency-x
  (day-boundary/timezone + protocol skew).
- **Adversarial verification** — every finding was re-examined by an independent
  verifier instructed to refute it by re-reading the code (not the reviewer's
  quoted evidence). One verifier compiled the verbatim `JsonlPatch.swift` source
  and empirically reproduced the streaming-patch defect on >128 MB files.

**Outcome: 63 findings confirmed (2 high / 25 medium / 36 low), 8 refuted,
0 unverified.** Roughly 115 agent runs, ~9 M subagent tokens, 1,600+ tool calls.

**Scope exclusion:** security auditing (IPC trust boundary, credential handling,
untrusted-input exploitation, injection surfaces) was deliberately excluded by
owner decision. Reviewers were instructed to skip vulnerability hunting.
See "Coverage and limitations."

## Executive summary

The codebase is in strong health. The write path (migrations, FTS self-heal,
Archive V2 CAS, project-move engine) shows unusually disciplined engineering:
content-addressed storage with fsync/rename ordering, LIFO compensation with
byte-exact backups, dual-receipt-gated reclamation, and a genuinely enforced
single-writer contract. Concurrency hygiene is very good — the hard
continuation races (semaphore timeout-vs-signal, fd-reuse windows, permit
leaks) are handled correctly. CI actually builds and tests the Swift product
path, all actions are SHA-pinned, and parity goldens keep TS and Swift adapters
honestly in sync. No crash-in-product-path, data-corruption, or data-loss
defect was found in the primary write path.

The confirmed defects cluster into five themes:

1. **Read-surface parity drift (the biggest theme).** There are three
   independent query implementations — app `Database.swift`, MCP
   `MCPDatabase.swift`, service `EngramServiceReadProvider` — and they have
   silently diverged on visibility invariants: CJK search fallback (H2),
   top-level/skip filters (M18, M5, L7, L31), hidden-session cost filtering
   (M19), and day bucketing (M24). Bug fixes have repeatedly landed on one or
   two surfaces but not the third.
2. **Lifecycle gaps in the embedding subsystem.** No re-embed on model/dimension
   change, no per-session terminal failure state, and config-vs-native dimension
   divergence can render the whole corpus silently unqueryable (M3, M16, M17).
3. **Boundary conditions in rare-but-destructive paths.** The >128 MB streaming
   JSONL patcher silently misses or corrupts path references at chunk
   boundaries (M12, empirically reproduced); Gemini sidecar parent links are
   written unvalidated (M23).
4. **Aggregate/count inconsistencies.** Projects page truncation (H1), KPI vs
   browse-list disagreement (M5), Codex header-vs-stream counts (M6),
   UTC-vs-local day bucketing (M24, M25).
5. **Settings-surface UI debt.** A user-triggerable crash (M20), per-keystroke
   synchronous file I/O on the main thread (M21), and a stale-write race (M22).

## High-severity findings

### H1. Projects page drops projects and shows wrong per-project counts
`macos/Engram/Core/Database.swift:1384` — `listSessionsByProject` fetches only
the `limit*10` most-recent top-level sessions (1,000 rows at the default
limit=100) and groups them in memory. Any project whose most recent session
falls outside that window disappears from the Projects page, and every
displayed `sessionCount` is the within-window count, not the true total. For a
heavy user (thousands of sessions — this tool's target audience), both the
project list and the "Total Projects" KPI are wrong. An accurate
`countsByProject()` already exists but is unused here.
**Fix:** enumerate projects and counts via GROUP BY over the full filtered set
(or reuse `countsByProject()`); cap only the per-project preview list.

### H2. MCP keyword search returns wrong/empty results for CJK queries
`macos/EngramMCP/Core/MCPDatabase.swift:2116` — the MCP `search` tool's keyword
path always issues trigram `MATCH` and rejects queries under 3 characters. The
app and service both branch to a LIKE scan when `containsCJK(query) ||
query.count < 3` (the "Korean fallback" fix, commit 02d2cbb9, touched
`Database.swift` + `EngramServiceReadProvider.swift` but never
`MCPDatabase.swift`). A 2-char CJK query like `配置` returns an empty result
with a "needs at least 3 characters" warning via MCP while the app finds every
match; ≥3-char CJK queries go through the MATCH path the codebase's own
comments call unreliable for CJK/Hangul. A CJK-speaking user searching through
Claude Code gets divergent results from the app for the same query.
**Fix:** port the same CJK/short-query LIKE branch; drop the 3-char guard for
the CJK path. Add CJK fixtures to EngramMCPTests (none exist).

## Medium-severity findings

### Service runtime
- **M1. Writer-gate queue timeout fixed at enqueue time** —
  `macos/EngramService/Core/ServiceWriterGate.swift:95`. A write that enqueues
  behind a queued (not yet holding) project migration arms a 60 s timeout that
  is never re-evaluated when the migration acquires the gate, so it surfaces a
  false `writerBusy` while legitimately waiting. Fix: count pending+active long
  writes and pass `timeout=nil` while > 0.
- **M2. One failed initial-scan phase pins status to "degraded" for ≥15 min** —
  `macos/EngramService/Core/EngramServiceRunner.swift:1216`.
  `recordScanSuccess()` fires only when `failedPhaseCount == 0`; a single
  non-fatal phase error leaves the degraded banner until the first periodic
  cycle. Fix: record partial success when the core index phase succeeded.

### DB write / embedding lifecycle
- **M3. Embedding backfill has no per-session terminal state** —
  `macos/EngramCoreWrite/Indexing/InsightEmbeddingBackfill.swift:255`. Batch
  processing aborts on first failure, retry_count is never advanced, and there
  is no `failed_permanent` transition (unlike the FTS runner). One
  deterministically-failing session re-selects forever, trips the circuit
  breaker, and stalls the entire embedding corpus. Fix: per-job retry counting
  with a terminal state; isolate per-session failures within a batch.
- **M16. Configured-vs-native dimension divergence silently poisons the corpus**
  — `InsightEmbeddingBackfill.swift:315`. The write path stores the *configured*
  dimension while the BLOB carries the provider's *native* vector length. A
  1024-native provider with the 1536 default yields rows the availability probe
  reports usable but every query rejects, with a misleading "model mismatch"
  degrade reason. Fix: store `chunk.vector.count`, validate batch uniformity,
  refuse writes when returned length ≠ configured dimension.
- **M17. Model/dimension change never re-embeds; shared `embedding_meta` couples
  subsystems** — `InsightEmbeddingBackfill.swift:65`. Already-embedded content
  is never re-selected after a model change (stale rows accumulate and silently
  vanish from results), and the single `embedding_meta` id=1 row is shared by
  sessions and insights, so re-embedding one subsystem can disable the other's
  still-valid corpus. This is a parity gap with the documented TS behavior
  ("dimension/model changes trigger automatic rebuild"). Fix: detect
  (model, dimension) change → purge/re-enqueue; or split the meta rows.

### Archive / remote
- **M4. Reclamation cursor skips eligible candidates** —
  `macos/EngramService/Core/ArchiveReclamationCoordinator.swift:232`. Each cycle
  scans up to 1,000 candidates but reclaims at most 10, then advances the
  cursor past all 1,000; skipped eligible sessions wait a full wrap. Fix:
  advance the cursor only past what was actually processed.
- **M14. Server HEAD reads+decrypts full content** —
  `macos/EngramRemoteServer/Core/ArchiveRoutes.swift:66`. The HEAD-before-PUT
  dedup fast-path costs as much as a GET server-side: HEAD object reads,
  AES-GCM-decrypts, and SHA-256-verifies the whole blob; HEAD manifest
  additionally re-reads every referenced chunk. A re-push of an
  already-present 100 MiB session decrypts ~100 MiB just to answer 200. Fix:
  existence-only lstat API with the same safe-file identity checks.
- **M15. Discovery listings are O(N²) with fsync per receipt per page** —
  `macos/EngramRemoteServer/Core/ArchiveStore.swift:847`.
  `listMachines`/`listReceipts` full-scan and durably re-validate
  (receipt+manifest read, canonical re-encode, 2 fsyncs) every receipt on every
  page. Latent today (only service-coordinator tests hit these routes) but the
  protocol is wired for it. Fix: lightweight discovery decode; cursor-seek.

### Adapters / tiering
- **M6. Codex persisted message counts disagree with the streamed transcript** —
  `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:578`.
  `parseSessionInfo` doesn't count `function_call_output`; `streamMessages`
  emits it. The committed golden itself encodes the mismatch
  (statsFields.messageCount=4 vs insightFields.messageCount=5). Session cards
  disagree with transcripts for essentially every Codex session. Fix: count it
  (or stop emitting it); add the missing `info.messageCount == streamed.count`
  Codex test.
- **M7. Non-Claude JSONL sources lack tail-resume** — `CodexAdapter.swift:462`.
  Only ClaudeCodeAdapter conforms to `TailIndexingSessionAdapter`; a live Codex
  rollout file (append-only, identical shape) is fully re-parsed every scan
  cycle even though the tail machinery already exists in JSONLAdapterSupport.
  Fix: conform CodexAdapter (then other append-only sources).
- **M8. Direct gemini-cli sessions can be misclassified as dispatched and have
  index artifacts deleted** —
  `macos/EngramCoreWrite/Indexing/StartupBackfills.swift:1599`. Codex has a
  per-session originator gate before suggested-parent scoring; gemini-cli does
  not. A genuine `gemini` session opening with a dispatch-shaped message (e.g.
  "Analyze the …") while no claude-code parent scores is set
  `agent_role='dispatched', tier='skip'` and its FTS/message rows deleted —
  hidden from every surface with no user-facing recovery. Fix: require positive
  dispatch evidence before the `.none` branch may skip-tier + delete; otherwise
  `markChecked` and keep visible.
- **M23. Gemini sidecar `parentSessionId` becomes a confirmed link with zero
  validation** —
  `macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift:158`. Empty,
  self-referential, dangling, or depth-2 sidecar values are written verbatim as
  `link_source='path'` confirmed links. A `{"parentSessionId": ""}` sidecar
  makes the session invisible on every top-level surface and unfindable as a
  child. The sibling Layer-1 backfill already has the right guard
  (`validateParentLink`); the sidecar path bypasses it. Fix: run sidecar values
  through the same existence/self/depth-1 validation (or downgrade to
  suggested).

### MCP surface
- **M9. `file_activity`/`list_sessions` limits are not clamped** —
  `macos/EngramMCP/Core/MCPToolRegistry.swift:920`. Negative limits dump the
  entire filtered table (SQLite treats negative LIMIT as unbounded);
  `file_activity` has no ceiling at all. Fix: `min(max(limit,1),cap)` as
  `search` already does.
- **M18. `list_sessions` omits top-level and skip-tier filters** —
  `MCPDatabase.swift:152`. Its comment claims it "matches the app default", but
  the app default passes `topLevelOnly:true` + `subAgent:false`. Suggested or
  manually-linked children the app groups under parents appear as top-level
  rows (and inflate `total`) via MCP. Fix: append
  `parent_session_id IS NULL AND suggested_parent_id IS NULL` and the skip-tier
  predicate when `include_all=false`.
- **M19. `get_costs`/`get_context` count hidden (trashed) sessions** —
  `MCPDatabase.swift:243` (also `totalCostSince`, `totalCostBetween`,
  `topCostGroupsSince`). The service costs() path filters
  `hidden_at IS NULL` everywhere; the MCP cost queries don't, so the two
  surfaces disagree on spend. Fix: add the filter to all four sites.
- **M24. `get_costs` buckets days by UTC; everything else by local day** —
  `MCPDatabase.swift:228`. The service costs() was deliberately fixed to
  localtime (with an explanatory comment); MCP `get_costs` still uses UTC
  `date()` — and the same binary's `stats` tool uses localtime. For UTC+8
  users, ~8 h of every day is attributed differently across surfaces. Fix:
  `date(s.start_time,'localtime')` + a cross-TZ parity test.

### App UI
- **M10. TimelinePageView applies detached-read results without a staleness
  guard** — `macos/Engram/Views/Pages/TimelinePageView.swift:367`. A filter
  change mid-load can display the previous filter's data; the code comment
  claims the opposite. SessionsPageView already has the right pattern
  (`shouldApplyLoad`). Fix: post-await cancellation/generation guard.
- **M20. "Test Connection" force-unwraps `URL(string:)` on a free-text field**
  — `macos/Engram/Views/Settings/AISettingsSection.swift:249`. A leading space
  or malformed host in the Base URL field crashes the app. Fix: guard-let with
  a `.failed("Invalid URL")` status.
- **M21. AI settings perform synchronous settings.json I/O on the main thread
  per keystroke** — `AISettingsSection.swift:75`. Each character typed runs two
  flock+read+rewrite cycles plus a runtime-secrets write on the MainActor.
  Fix: debounce + move off-main.
- **M22. ArchiveSettings `refresh()` reverts user input with a stale server
  value** — `macos/Engram/Views/Settings/ArchiveSettingsSection.swift:740`. The
  reclamation-status half of refresh is not generation-guarded and the controls
  are enabled during the initial load; a slow response silently reverts the
  toggle/picker, and Save then persists the wrong value. Fix: reuse the
  existing generation guard or disable controls until first load completes.

### Read-surface aggregates
- **M5. Dashboard KPI and activity aggregates count skip-tier sessions** —
  `macos/Engram/Core/Database.swift:1153`. `kpiStats`, `dailyActivity`,
  `hourlyActivity`, `sourceDistribution` etc. filter only `hidden_at`, so a
  parent with 3 subagents counts as 4 — the Home "Sessions" KPI reads
  several-fold higher than anything browsable, diverging from the CLAUDE.md
  invariant. Fix: add the tier filter (or label the metrics as raw activity).

### Project move
- **M12. Streaming JSONL patch misses/corrupts path references at chunk
  boundaries** (>128 MB files) —
  `macos/EngramCoreWrite/ProjectMove/JsonlPatch.swift:321`. Segment and carry
  are adjacent with no overlap, so an `oldPath` straddling the ~1 MiB cut is
  written half-unpatched (silent miss), and the `$` terminator lookahead can
  false-match a prefix ending exactly on the boundary, rewriting an unrelated
  token (silent corruption). **Empirically reproduced by the verifier against
  the verbatim source.** The only streaming test places the needle at offset 0.
  Fix: overlap the carry by the max needle length (keep the boundary window
  unwritten until the next chunk); add boundary repro tests.
- **M13. Case-only project rename is always refused on case-insensitive APFS**
  — `macos/EngramCoreWrite/ProjectMove/FsOps.swift:167`. `fileExists(dst)`
  sees the same inode and throws `destinationExists`; the orchestrator's
  encoded-dir path already handles case-only renames via realpath equality,
  Step 1 does not. Clean failure, no data loss. Fix: treat
  `realpath(dst)==realpath(src)` as non-conflicting.

### CI
- **M11. Per-PR bundle verification is hygiene-only** —
  `.github/workflows/test.yml:210`. The structural check (all three helpers
  present) runs only at v* tags; a dropped helper-bundling postbuild script
  would merge green and surface at release time. Fix: run the structural
  portion per-PR.

### Cross-cutting time semantics
- **M25. Timeline/WorkGraph bucket days by UTC while the Activity heatmap uses
  local days** —
  `macos/Shared/EngramCore/Indexing/ImplementationDigestExtractor.swift:196`.
  Work-beat `action_date` is the UTC prefix of the timestamp, then re-labeled
  as local midnight; for UTC+8 users, this morning's work shows as "Yesterday"
  in the Timeline but as today in Activity. Fix: pick one day basis for all
  day surfaces (local, matching the heatmap/costs) + a cross-TZ test.

## Low-severity findings

| # | Area | Finding | Location |
|---|------|---------|----------|
| L1 | service | Status poll exposes pre-backfill `todayParents`; badge transiently inflated for heuristic-classified sessions | `ServiceStatusMonitor.swift:58` |
| L2 | service | `setSourceEnabled` mutates settings.json before the DB write; failure leaves ingest/visibility divergent | `EngramServiceCommandHandler.swift:1231` |
| L3 | db-write | Content-identical relocation leaves `source_locator`/`file_path` stale | `SessionSnapshotWriter.swift:123` |
| L4 | archive | RemoteSync backend: no response-size bound, shared URLCache on a mutable catalog endpoint | `EngramRemoteBackend.swift:106` |
| L5 | archive | One recover/evict failure aborts the whole reclamation cycle | `ArchiveReclamationCoordinator.swift:192` |
| L6 | db-read | `sparklineData` unanchored cwd prefix over-counts sibling repos (`app` matches `app-v2`) | `Database.swift:1363` |
| L7 | db-read | Skip-tier hiding coupled to `subAgent==false`; default `nil` leaks skip rows (ActivityView.openMostRecent affected) | `Database.swift:200` |
| L8 | db-read | Dead facade methods `listSessionsChronologically`/`listSessionsInGroup` (zero callers) | `Database.swift:968` |
| L9 | db-read | Default browse sort on unindexed `COALESCE(end_time,start_time)` forces a filesort per page load | `Database.swift:15` |
| L10 | adapters | Qwen/Qoder/CommandCode/Iflow stream paths skip the injection filter (counts diverge; injected text reaches FTS/replay; transcript display is guarded by SystemMessageClassifier) | `CommandCodeAdapter.swift:78` |
| L11 | tiering | DETECTION_VERSION bump never re-scores existing single `suggested_parent_id` rows; stale wrong suggestions persist | `StartupBackfills.swift:1274` |
| L12 | tiering | Dead `isConcurrentProviderChild` helper + always-zero `linked` in polycli backfill | `StartupBackfills.swift:1670` |
| L13 | mcp | Unreachable `tools/call` branch in `handle()` (dead code) | `MCPStdioServer.swift:147` |
| L14 | app-ui | TimelinePageView recomputes `projectOptions`/`filteredTimeline` over the full window multiple times per body eval | `TimelinePageView.swift:143` |
| L15 | app-ui | WorkGraphView allocates a fresh `ISO8601DateFormatter` per repo per render | `WorkGraphView.swift:79` |
| L16 | app-ui | Home "Changed Repos" badge advertises full count while rendering `prefix(5)` (violates own panel-badge contract) | `HomeView.swift:224` |
| L17 | concurrency | Indexer producer→consumer `AsyncThrowingStream` is unbounded; batch bound is consumer-side only (queued items are small digests, so tens of MB worst case) | `SwiftIndexer.swift:131` |
| L18 | concurrency | Shutdown never awaits the periodic checkpoint task, contradicting the gate-unwind contract | `EngramServiceRunner.swift:412` |
| L19 | ts-ref | `engram logs`/`traces` CLI query tables the Swift runtime never populates (silently inert) | `src/cli/logs.ts:60` |
| L20 | ts-ref | FTS rebuild policy TS mirror silently lags the product (missing H01 guard) while sharing version "3" | `src/core/db/fts-rebuild-policy.ts:63` |
| L21 | ci | Notarization/stapling has no CI backstop (manual-only; documented) | `.github/workflows/release.yml:181` |
| L22 | ci | perf.yml is nightly-only and its non-gating nature is undocumented | `.github/workflows/perf.yml:3` |
| L23 | docs | docs/archive (85 files) + docs/reviews (35) have no index/retention policy | `docs/CONTRIBUTING.md:47` |
| L24 | recent | VsCodeAdapter strict `requestObjects` guard turns stably-corrupt sessions into an untested hourly retry loop | `VsCodeAdapter.swift:51` |
| L25 | recent | SettingsIO dropped the release-build signature-validity check; broken-signature release builds outside DerivedData now hit Keychain | `SettingsIO.swift:73` |
| L26 | project-move | Gemini projects.json `writeAtomic` skips temp-file and parent-dir fsync (power-loss window) | `GeminiProjectsJSON.swift:202` |
| L27 | remote-server | `/v2/archive/status` polling rewrites the telemetry snapshot every poll (read-triggered write amplification) | `ArchiveRoutes.swift:280` |
| L28 | remote-server | Storage failures return 503 but telemetry maps only 507 → `storage_unavailable`; mislabeled `internal_error` | `ArchiveRemoteTelemetryStore.swift:175` |
| L29 | remote-server | Legacy `/v1/catalog` aggregates all peer manifests (≤64 MiB each) in memory, unbounded | `EngramRemoteServerApp.swift:86` |
| L30 | ai-search | MCP hybrid fusion pairs ids to items positionally with `zip`; a session deleted mid-search mislabels results (service uses the correct id-keyed pattern) | `MCPDatabase.swift:1235` |
| L31 | mcp-parity | `stats` counts skip-tier noise with no `exclude_noise` flag (TS reference has one); internally inconsistent with its own zeroed `userMessageCount` | `MCPDatabase.swift:82` |
| L32 | app-ui-2 | SessionDetailView type-filter runs synchronously on main over the fully-loaded set (100k+ rows after "Load all") | `SessionDetailView.swift:91` |
| L33 | app-ui-2 | LogStreamView module picker computed once; late-appearing modules never listed | `LogStreamView.swift:155` |
| L34 | adapters-2 | Antigravity `inferredCWD` re-reads the whole transcript for a 50 KB prefix on every parse | `AntigravityAdapter.swift:333` |
| L35 | adapters-2 | EngramCoreSchemaTool: build target with no caller, no test, no bundle wiring | `EngramCoreSchemaTool/main.swift:4` |
| L36 | consistency | Catalog manifests never validate `schemaVersion`; skewed manifests silently dropped (bundles fail loudly — asymmetric) | `RemoteSync/ManifestCodec.swift:96` |

## Per-area health assessment

| Area | Verdict |
|------|---------|
| service-runtime | Robust. Solid single-instance guarantees, careful fd/permit handling, real writer gate. Gaps: status-poll contract bypass, enqueue-time timeout classification. |
| db-write | Mature. Idempotent migrations, FTS self-heal against rowid reuse, network I/O correctly outside transactions. Gap: embedding job lifecycle. |
| archive-sync (client) | Exceptionally engineered. CAS integrity, crash-resumable reclaim state machine, dual-receipt gating all verified. Gaps are throughput, not safety. |
| remote-server | Well-engineered store (crash-consistent, append-only, no GC hazard); perf debt on HEAD/list paths. |
| project-move | Strong for its risk class (compensation, locking, savepoint atomicity). The >128 MB streaming path is the one genuinely wrong corner. |
| db-read | Good discipline (readInBackground everywhere, parameterized SQL). Result-correctness defects: truncation, aggregate/browse divergence. |
| adapters | Robust shared parsing core (caps, identity re-checks). Count-parity between header and stream is the weak axis; tail-resume is Claude-only. |
| tiering-linking | Mature, unusually well-tested (_repro coverage). Two real gaps: gemini-cli misclassification, frozen single suggestions. |
| mcp (protocol) | Well-engineered; golden contracts genuinely pin the wire format; PR #186 object-root change verified sound with a catalog-wide guard. |
| mcp (read parity) | The weakest surface audited: an independent ~2,850-line query implementation missing several invariants the app/service enforce. |
| app-ui | Disciplined overall (off-main reads, memoized transcript path). Debt concentrated in TimelinePageView and the Settings sections. |
| concurrency-memory | Strong. All `@unchecked Sendable` claims verified honest; recent malloc-pressure work is functional, not cosmetic. One unbounded stream. |
| ts-reference | Healthy and honestly scoped; session-tier/parent-detection mirrors verified in sync verbatim; FTS policy is the one silently stale mirror. |
| build-ci-docs | Unusually disciplined (SHA-pinned actions, fail-closed gates, mechanical bundle hygiene). Boundary gaps only. |
| recent-changes (7/15–17) | High quality; all five major merges fully propagated with tests. Two minor untested behavior changes. |
| ai-search | Search math verified correct (RRF, KNN, top-K, dimension guards). Lifecycle (rebuild/dimension recording) is the weak layer. |

## Cross-cutting recommendations

1. **Unify or parity-test the three read surfaces.** H2, M5, M18, M19, M24, L7,
   L31 are all one root cause: `Database.swift`, `MCPDatabase.swift`, and
   `EngramServiceReadProvider` re-implement the same invariants independently.
   Either extract shared predicate builders (tier/top-level/hidden/CJK-fallback
   SQL fragments already exist piecemeal, e.g. `searchableTierSQL`,
   `HumanDrivenFilter`) or add a cross-implementation parity test that pins the
   three surfaces' filters against each other. Every future fix will otherwise
   land on 1–2 of 3 surfaces again.
2. **Give the embedding subsystem a lifecycle.** Terminal failure states (M3),
   actual-dimension recording (M16), and model-change rebuild (M17) are one
   coherent work item; without them, semantic search degrades silently and
   unrecoverably in several realistic configurations.
3. **Pick one day-boundary basis.** Local day is already the deliberate choice
   of the service cost path and heatmaps; M24/M25 are the two holdouts. A
   single cross-timezone test asserting badge/heatmap/timeline/costs agree
   would pin this permanently.
4. **Close the two destructive-path corners:** streaming-patch boundary overlap
   (M12) and sidecar link validation (M23). Both are silent-failure modes in
   the paths users trust most (project move, deterministic linking).
5. **Adopt the codebase's own best patterns where siblings lag:** staleness
   guards (SessionsPageView → TimelinePageView/ArchiveSettings), limit clamping
   (`search` → `file_activity`/`list_sessions`), tail-resume (ClaudeCode →
   Codex), fsync discipline (JsonlPatch → GeminiProjectsJSON), response bounds
   (HTTPArchiveReplicaBackend → EngramRemoteBackend).

## Priority test gaps

1. CJK/2-char search fixtures for EngramMCPTests (H2 has zero coverage).
2. `listSessionsByProject` beyond the `limit*10` window (H1).
3. Streaming-patch boundary repro: needle straddling the 1 MiB cut in a
   >128 MB file, forward+reverse (M12; verifier's repro driver in scratchpad
   can seed this).
4. Gemini sidecar Layer-1c cases: empty/self/dangling/depth-2/valid (M23 —
   currently zero sidecar tests exist).
5. Poison-session embedding job: assert eventual terminal state and batch
   isolation (M3); provider returning native ≠ configured dimension (M16).
6. Cross-timezone day-bucket parity (badge vs heatmap vs timeline vs costs,
   M24/M25) and the sub-second midnight boundary (`.000Z` vs no-fraction
   string compare — flagged by consistency-x as untested).
7. Negative/oversized MCP limits (M9).
8. Cross-implementation filter parity (app vs MCP vs service) for
   list/search/costs/stats (theme 1).
9. Writer-gate follower-timeout race (M1) and status-poll backfill contract
   (L1) — both currently only exercised on paths that don't hit the bug.
10. HEAD-is-cheap assertion for the remote server (M14) and status-poll
    persistence frequency (L27).

## Refuted findings (verification rigor)

Eight reviewer claims were killed by adversarial verification — worth recording
so they are not re-reported:

1. *Launcher permanently stops re-spawning after the restart budget* — the
   budget-exhausted branch never terminates the last child; a live helper can
   still probe healthy and reset the budget.
2. *Parent-link backfills block user writes by holding the writer transaction
   during file reads* — mechanically true that reads happen in-transaction, but
   all writes serialize above SQLite through the writer gate anyway; no
   incremental blocking is reachable.
3. *`fetchTraces` unescaped LIKE* — the method has zero callers.
4. *MCP in-flight id dedup spuriously rejects after emit* — emit+flush ordering
   makes the race benign.
5. *SPM cache-key collision between perf.yml and release.yml* — keys/scopes
   differ in practice.
6. *Kimi/GeminiCli missing zero-visible-message terminal classification causes
   retry loops* — the failure scenario doesn't materialize for those adapters'
   actual input shapes.
7. *SessionReplayView keeps playing after sheet dismissal* — teardown is handled
   at all three presentation sites.
8. *ParsedTranscriptCache doc/memory-bound claims* — misread; the 10 MB guard
   reference is to TranscriptSizeGuard and is accurate.

## Coverage and limitations

**Covered:** all Swift product targets (app, EngramService, EngramMCP,
EngramCoreRead/Write incl. ArchiveV2 + ProjectMove + RemoteSync,
EngramRemoteServer, shared adapters/AI), the TS reference layer, CI/build/docs,
and the 2026-07-15..17 diffs. Round 2 specifically closed the blind spots the
completeness critic identified (ProjectMove engine, RemoteServer, semantic
search runtime, MCP read parity, uncovered views, Swift-only adapters,
timezone/protocol-skew consistency).

**Security (completed 2026-07-17 in a follow-on pass):** see
`docs/reviews/2026-07-17-engram-security-audit.md`. Outcome: 14 findings
(0 critical / 2 high / 5 medium / 5 low / 2 info). High: remote-offload HTTP
host policy + default `requireTLS=false` (SEC-H1); plaintext `ai-secrets.json`
bridge without stop cleanup (SEC-H2). Cross-user IPC isolation is strong;
same-user/MCP is a trusted peer by design. Historical Terminal/RepoDetail
command-injection claims are closed in current code.

**Other residual limits:** EngramUITests themselves were not reviewed;
cost-*ingestion* correctness (session_costs writers) was only spot-checked via
the read paths; findings marked "latent" (M15) assume future wiring of
discovery routes.

---
*Generated by a two-round Opus multi-agent audit with per-finding adversarial
verification (63 confirmed / 8 refuted / 0 unverified). Orchestrated by Claude
Fable 5, 2026-07-17.*
