# Deep Review — Round 6 (2026-05-22)

Multi-agent adversarial review across 11 expert subagents (read-only). Mandate:
hunt for "minimal-resistance" band-aid fixes (symptom suppression, stubs,
verification theater, advertised-but-inert features) on top of finding genuine
defects. All findings recorded here for persistence and round-2 follow-up.

Severity legend: CRITICAL / HIGH / MEDIUM / LOW.

---

## 0. EMPIRICALLY VERIFIED (against live `~/.engram/index.sqlite`, 544 MB, 11,413 sessions)

These were the two most consequential round-1 claims (flagged "static-analysis
only, needs live verification"). I verified them against the running DB and
the source. **Both confirmed as live production defects.** My initial read of
"live DB has FTS content ⇒ C1 false" was WRONG — the content is historical;
current code cannot write it.

### V1 (= write-path C1, feature C1) — CONFIRMED CRITICAL: FTS content is never written by current code; new sessions are unsearchable
Evidence:
- `sessions_fts` is a **standalone** FTS5 table (`USING fts5(session_id UNINDEXED, content, tokenize='trigram ...')`), NOT external-content. No triggers sync it.
- The only `INSERT INTO sessions_fts` in non-test Swift is `VALUES('optimize')` (StartupBackfills.swift:347). There is **no** `INSERT INTO sessions_fts(session_id, content, ...)` anywhere in the product path.
- `SessionSnapshotWriter` only DELETEs FTS rows and enqueues `session_index_jobs` of `job_kind='fts'`. The consumer protocol `StartupIndexJobRunning` has **no production conformer** (only the unused parameter in `runInitialScan`).
- Live DB: the 5 newest non-skip sessions (indexed today 2026-05-22) are all `NO-FTS`. **392 non-skip sessions have no FTS content.** **137,628 pending `session_index_jobs`** accumulated, never drained.
- The 82,931 existing FTS content rows were written by a previous version (TS daemon / older Swift build); they mask the regression.
Impact: keyword search silently misses every session indexed by the current
runtime. The reader uses `INNER JOIN sessions_fts`, so those sessions return
zero hits.

### V2 (= write-path C2, feature H1) — CONFIRMED CRITICAL: service never calls `migrate()` or `runInitialScan()`
Evidence:
- `migrate()` is called only by `EngramCoreSchemaTool/main.swift` (a CLI dev tool) + tests.
- `runInitialScan` is defined but never called outside its own definition.
- `EngramServiceRunner.run()` (the only thing `EngramService/main.swift` invokes) calls only `writer.indexRecentSessions()` (runner :207-208).
Consequence: the documented startup backfill chain
(`downgradeSubagentTiers → backfillParentLinks → resetStaleDetections →
backfillCodexOriginator → backfillSuggestedParents`), `reconcileInsights`,
`optimizeFts`, job recovery, orphan scan, vacuum — **all dead in production**.
Partial mitigation (found by feature agent): Layers 1/1b/1c parent detection
fire INLINE at adapter parse time, so *new* sessions still get parent links;
only the *retroactive* repair + version-gated re-evaluation (`DETECTION_VERSION`
bump) is inert. Schema exists in the live DB because the schema tool / an older
build migrated it — current service has no fail-fast if schema is absent.

**Root cause (V1+V2): composition-root gap.** A correct-looking deferred-job +
ordered-backfill + migration architecture was built, unit-tested in isolation
(tests drive `runInitialScan`/job runners directly), but the production
composition root (`EngramServiceRunner`) was never wired to assemble the
pieces. This is the dominant systemic finding of the entire review.

---

## 1. Code — Service + MCP runtime (`Shared/Service`, `EngramService`, `EngramMCP`)
Sound: writer single-lock (dual flock), frame read bounds, semaphore races
(actor-serialized), SQL parameterization, path confinement.
- **F1 HIGH** `UnixSocketServiceServer.swift:42-46` — accept loop treats ANY `accept()<0` as fatal `break`; `EINTR`/`ECONNABORTED`/`EMFILE` permanently kill the only acceptor while the process stays alive holding the lock ("zombie healthy"). Fix: discriminate `errno`, `continue` on transient.
- **F2 HIGH** `UnixSocketEngramServiceTransport.swift:178-182` — `writeFrame` does not enforce the 256 KB `maximumFrameLength` that `readFrame` enforces; `search` `snippet` is the **full untruncated FTS content**, so limit=100 responses exceed 256 KB → client `readFrame` rejects legit results as "Invalid service frame length". Root cause: snippet not truncated server-side. Fix: truncate snippet + symmetric write guard.
- **F3 MEDIUM** `UnixSocketServiceServer.swift:50-73` — per-client blocking `read`/`write` ignores `Task.cancel()`; teardown waits up to 10 s. Mirror the client-side `FdBox.shutdownIfOpen()` pattern.
- **F4 MEDIUM** `UnixSocketServiceServer.swift:63-73` — decode/handler errors always reply `requestId:"unknown"`, tripping the client id-match guard so the real error ("Session not found") is masked by a misleading "id mismatch". Fix: two-stage decode, reuse real request id.
- **F5 LOW** envelope `kind` field decoded but never validated (dead protocol surface).
- **F6 LOW** `EngramServiceRunner.swift:107-168` — startup TRUNCATE comment claims a guarantee that cancellation can void; benign (shutdown TRUNCATE catches up) but the comment misleads.

## 2. Code — Write path / schema / indexer (`EngramCoreWrite`)
(C1/C2 → see V1/V2 above.)
- **H1 HIGH** `StartupBackfills.swift:725-735` — `backfillSuggestedParents` 24 h window compares ISO8601 `start_time` (`...T...Z`) lexicographically against `datetime(?, '-24 hours')` (space-separated, no Z); lower bound effectively broken. `backfillPolycliProviderParents` (:674) does it correctly with `datetime(start_time)`. Fix: normalize both sides.
- **H2 HIGH** `StartupBackfills.swift:1010-1015` — `executeAndCountChanges` uses `sqlite3_total_changes` (trigger-inclusive); `deduplicateFilePaths`'s cascade-trigger child UPDATEs inflate the reported "removed" count. Fix: use per-statement `sqlite3_changes` (`db.changesCount`).
- **H3 HIGH** `EngramMigrations.swift:61-68` cascade trigger resets `tier=NULL` only for confirmed `parent_session_id` children, NOT for `suggested_parent_id` children (they keep `skip` → never resurface). Fix: extend trigger's second UPDATE.
- **M1 MEDIUM** `StartupBackfills.swift:363-388` `reconcileInsights` `id NOT IN (SELECT id FROM insights)` soft-deletes the entire vector store when `insights` is empty/partially-migrated; NULL-unsafe. Guard `AND EXISTS(SELECT 1 FROM insights)` / use `NOT EXISTS`.
- **M2 MEDIUM** `StartupBackfills.swift:335-344` `deduplicateFilePaths` keeps `MAX(rowid)`, can delete the row carrying `link_source='manual'`/parent link + orphan its children. Prefer manual/linked/most-recent row.
- **M3 MEDIUM** `StartupBackfills.swift:570-600` `backfillPolycliProviderParents` broad SQL prefilter (`source IN (...) AND trim(cwd)!=''`) + hard `LIMIT 1000` can clip relevant probe sessions before the real Swift classifier runs.
- **M4 MEDIUM** `EngramMigrations.swift:824-869` `migrateInsightsToV2` drops soft-deleted insights from text/FTS but never reconciles `memory_insights` (vector); reconciler is dead (V2).
- **L1** ALTER `indexed_at DEFAULT ''` vs CREATE `datetime('now')` schema drift. **L2** `replaceTable` DROP/RENAME under FK enforcement fragile if a *referenced* table is ever rebuilt. **L3** `snapshotHash` excludes `tier`/`agentRole`, change-detection relies on fragile equality branch.

## 3. Code — Read path + shared models/adapters (`EngramCoreRead`, `Shared/EngramCore`)
**Systemic:** `parseSessionInfo` (header counts) and `streamMessages` (actual
messages) are two independently-maintained paths that classify/filter
differently and drift. `AdapterParityHarness` never asserts
`messageCount == messages.count`, so the whole class is invisible to tests.
Tier decisions key off the (drifting) header count.
- **F1 HIGH** count↔stream divergence in ≥6 adapters (Codex, ClaudeCode, Qwen, Iflow, CommandCode, Qoder): header reclassifies injection→system & excludes; stream emits every user object. Fix: one shared `normalize()` feeding both + parity assertion.
- **F2 HIGH** `VsCodeAdapter.swift:65-67` hardcodes `messageCount = requests*2`; stream emits 0–2 per request. Band-aid `*2` placeholder.
- **F3 HIGH** `AntigravityAdapter.swift:413-435` `inferredCWD` hardcodes the author's machine layout (`/Users/<user>/-Code-/<project>`); wrong/empty for any other user. Derive from real metadata instead.
- **F4 HIGH** `CascadeDiscovery.swift:103-121` `waitUntilExit()` BEFORE `readDataToEndOfFile()` → classic pipe-buffer deadlock on large `ps`/`lsof` output, hangs indexing. Read-then-wait.
- **F5 MEDIUM** `WatchPathRules.swift:30` `maxDrainBatchSize` loaded from unrelated key `startupParentBackfillLimit` (copy-paste). 
- **F6 MEDIUM** `CodexAdapter.swift:59-62` `messageLimitExceeded` off-by-one + turns valid long session into a hard `.failure` (no index) instead of truncate-and-index.
- **F7 MEDIUM** `StreamingLineReader.swift:87-102` over-limit line recovery can drop a following valid line.
- **F8 MEDIUM** `CascadeClient.swift:55-126` hand-rolled JSON escaping for gRPC bodies (escapes only `\`,`"`); use JSONSerialization.
- **F9 MEDIUM** inconsistent per-adapter `isSystemInjection` sets vs `SystemMessageClassifier` (same message counted user / rendered system).
- **F10 LOW-MED** OpenCode header counts all rows; stream emits only non-empty text parts → divergence.
- **F11/F12/F13/F14 LOW** OpenCode recency by whole-DB mtime; dead `watchedSources` entries (minimax/lobsterai); unescaped LIKE `_`/`%` from interpolated IDs; `MessageTypeClassifier` substring matching tags prose discussing errors as `.error`.

## 4. Code — TypeScript reference/regression surface (`src/`)
- **F1 HIGH** `session-tier.ts:69-75` vs `SessionTier.swift` — probe→`lite` rule + 6-entry NOISE_PATTERNS exist in TS, absent in Swift (Swift has 2). Tier parity broken → probe sessions embedded in product, suppressed in TS; regression suite can't catch Swift behavior.
- **F2 HIGH** `index-job-runner.ts:138-148` — text→embedded promotion drops `source_session_id` (omitted from upsert opts) → permanent provenance loss in vector store.
- **F3 MEDIUM** `vector-store.ts:460-463` `deleteInsight` mixes soft-delete (memory_insights) + hard-delete (vec_insights) with no transaction; `reconcileInsights` has no rule for memory_insights↔vec_insights divergence.
- **F4 MEDIUM** `save_insight.ts:261-308` semantic dedup only WARNS then inserts the duplicate anyway (text path correctly blocks). Textbook symptom-masking.
- **F5 MEDIUM** `insight-repo.ts:63-87` `findDuplicateInsight` caps scan at `LIMIT 200` → dedup silently misses beyond 200/wing. Perf band-aid breaking correctness; add normalized-hash index.
- **F6 LOW** OpenAI embeddings skip the L2-normalize Ollama applies; cosine-dedup math assumes unit vectors.
- **F7 LOW** chunk re-embedding rebuilds messages from FTS blob labeling every line `[assistant]` → corrupts role context.
- **F8 LOW** `chunker.ts:61-73` `slidingWindow` infinite-loop if `overlap>=windowSize` (no guard).
- **F9 INFO** `maintenance.ts` `readCodexOriginator` swallows transient read errors then marks-inspected permanently → never retried.

## 5. Theme — Feature implementation correctness
- **C1 CRITICAL** Local Semantic Search (FTS5+sqlite-vec+RRF) **not implemented in product**: `SQLiteVecSupport.probe()` returns "not implemented yet", no Swift embedding provider, all search degrades to keyword, `save_insight` always text-only. MCPDatabase "RRF" computes `1/(60+rank)` over a SINGLE keyword list — fusing one list is a no-op. Settings UI still offers 3 embedding providers nothing consumes. Docs/UI/runtime disagree.
- **H1 HIGH** startup backfill sequence not the documented one (= V2); inline Layers 1/1b/1c mitigate new sessions, retroactive repair inert.
- **H2 HIGH** Windsurf + Antigravity adapters constructed `enableLiveSync:false` everywhere → index zero sessions on a real machine (the `.jsonl` cache they read is produced by the disabled `sync()`).
- **H3 HIGH** Layer-3 manual link/unlink unimplemented: `EngramServiceLinkRequest`/`UnlinkRequest` defined but no handler/client/caller; no code sets `parent_session_id=NULL, link_source='manual'`. Only confirm/dismiss-suggestion exist.
- **M1 MEDIUM** "Today" parent badge filters only `parent_session_id IS NULL`; list also filters `suggested_parent_id IS NULL` → badge over-counts vs list.
- **M2 MEDIUM** crash window between FS move and DB commit: `project_recover` is diagnostic-only (returns text advice), `cleanupStaleMigrations` flips to `failed` (non-undoable) without reversing FS.
- **M3 MEDIUM** service + app session-search throw on FTS5 syntax chars (no retry); MCP + insight paths already quote-and-retry. Inconsistent hardening.
- **L1** `pickBestCandidate` non-deterministic tie-break. **L2** MCP rejects 2-char CJK queries (service/app accept). **L3** `hygiene` stub returns constant score 100; `triggerSync` "not implemented".

## 6. Theme — Code quality / band-aid hunt
Good: zero `as!`, disciplined `try!` (2 infallible sites). Real rot = duplicated
heuristics + test-shaped string classifiers + missing single source of truth.
- **F1 CRITICAL** system-injection prefix list copy-pasted across **8 sites**, already diverging (canonical `SystemMessageClassifier` + 7 inline copies in SwiftIndexer ×2, CodexAdapter, ClaudeCode/CommandCode/Iflow/Qwen/Qoder). Whether a message is classified as injection depends on which path touched it. Consolidate to one classifier.
- **F2 CRITICAL** `isProviderReviewPrompt/Summary` near-verbatim duplicated in SwiftIndexer:247-266 + StartupBackfills:864-883; string-soup tokens tuned to specific probe prompts; over-broad `contains("tests ")`/`contains("review")` misclassifies real review requests as throwaway → hidden (`skip`). Health-probe prompt sets also disagree (`"ping"` only vs `POLYCLI_HEALTH_OK`).
- **F3 HIGH** `ClineAdapter.swift:132-143` cwd dual-regex keeps the KNOWN-BROKEN `[^)]+` regex as fallback (still truncates parenthesized paths without ` Files` trailer).
- **F4 HIGH** `SourcePulseView.swift:119-124` only empty `catch {}` blocks in the codebase; swallowed fallback DB read + redundant unconditional re-read.
- **F5 MEDIUM** Codex tool-count skip (borderline-acceptable, documented).
- **F6 MEDIUM** parent-scoring magic constants split across two files with DIFFERENT time constants (ParentDetection 4 h half-life vs StartupBackfills 6 h/48 h piecewise) → live vs backfill paths can disagree on linkage.
- **F7 LOW** 231 `try?` sites; concern is non-adapter paths (`SettingsIO`, `EngramServiceReadProvider`) silently turning corruption into empty/default with no log breadcrumb.

## 7. Theme — Automated testing
Good: UITest "green" commits are legit (typed XCUITest queries are stricter, a11y
additive); migrations, socket framing, project-move orchestrator, save_insight
genuinely covered.
- **H1 HIGH** `AppEnvironment.fromCommandLine` arg-precedence reorder (decides prod vs fixture DB) has NO unit test; validated only by UI suite going green.
- **H2 HIGH** `ParserFailure` categories pinned by tautology (`allCases == hardcoded list`); Swift product parsers never fed malformed input (only TS reference is). 7/9 malformed categories declared `generatedInTests:false`.
- **H3 HIGH** RRF search fusion never executed by any test — every search test passes `{}` (no vectorStore) → only FTS fallback runs. (Compounds feature-C1: the "fusion" isn't real AND isn't tested.)
- **M1** export.ts streaming rewrite, no tests (0-message + backpressure branches uncovered). **M2** daemon-startup wiring tested by source-string grep. **M3** Swift `JsonlPatch` not run against golden byte-parity fixtures. **M4** parent-score parity covers 2/15 cases via hardcoded `switch` (`default: XCTFail`).
- **L1** 14 sleep-based flaky Swift tests. **L2** codex `model:""→null` guarded only by opaque golden checksum.
- **Meta gap (mine to add in round 2):** no end-to-end test indexes via the REAL `EngramService` and asserts a newly-indexed session is keyword-searchable. Such a test would have caught V1 immediately.

## 8. Theme — Observability
Two CRITICALs compound to make the indexing outage (V1) invisible through every
surface.
- **O1 CRITICAL** all 5 Observability views (Logs/Errors/Performance/Traces/Health) are cosmetic: Swift runtime writes only `os_log`, never the `logs`/`traces`/`metrics` tables (only TS + a test helper write them). User sees "No errors" during an incident.
- **O2 CRITICAL** `status` command always returns `.running` whenever the COUNT succeeds; index-scan failures (emitted to stdout/os_log only) never reach the app. `.degraded`/`.error` only on full socket failure.
- **O3 HIGH** `SwiftIndexer.swift:93-95` per-session parse failure dropped via bare `continue`; the rich `ParserFailure` reason is discarded one line before it could be logged → "session X not showing up" is undiagnosable.
- **O4 HIGH** `SwiftIndexer` whole-scan throwing semantics: one bad session/adapter aborts the entire scan; everything sorted after it is not indexed.
- **O5 MEDIUM** `events()` stream finishes permanently on first error, never restarts (health-monitor partly compensates). **O6 MEDIUM** SystemHealthView hardcodes "WAL Mode: OK", no service-health row. **O7/O8 LOW** event-encode + migration-failure-record swallow their own failures.
No transcript/secret leakage found in log call sites.

## 9. Theme — UI / UX
Dominant defect: main-thread-blocking DB reads (`nonisolated` + synchronous
`pool.read` called inside MainActor `async` without `Task.detached`). Compiles,
looks async, fine on tiny dev DB, freezes on real DB.
- **C1 CRITICAL** `SessionListView.swift:316-345` main browser blocks on 2000-row read + child-count fan-out over all IDs + MainActor grouping/sort; re-blocks on every filter/favorite/delete.
- **C2 CRITICAL** `ReposView.swift:75-88` N+1 synchronous reads on main thread (50 repos = 51 blocking reads).
- **H1 HIGH** 5 Observability views block on load + every 30 s timer tick (TraceExplorer also per-keystroke). **H2** ActivityView 5 sequential blocking aggregations. **H3** Projects/Agents/WorkGraph/SourcePulse block.
- **H4 HIGH** a11y is test-satisfying: 112 `accessibilityIdentifier` vs 5 `accessibilityLabel`, 0 `accessibilityValue`; charts (Heatmap/Tier/Sparkline/WorkGraph) invisible to VoiceOver.
- **M1** 6+ views show blank/stale on error (only log, no error UI; HomeView has unused `alertMessage`). **M2** "JSON" transcript tab byte-identical to "Text" stub. **M3** summary feature has state+function but no UI entry point. **M4** hardcoded "WAL Mode: OK".
- **L1** Heatmap white-on-light contrast. **L2** ad-hoc colors bypass Theme. **L3** magic font sizes (no Dynamic Type). **L4** Onboarding 15 sync `fileExists` on main thread. **L5** fragile `ForEach` offset IDs.
Correct: HomeView/SessionsPage/SessionDetail use `Task.detached`; LogStreamView uses GRDB observe; service-backed views have AlertBanner error states.

## 10. Theme — Security (defensive)
Sound: socket framing/bounds, dual flock, runtime-dir validation (0700, owner,
non-symlink), parameterized SQL, export path-traversal blocked, linkSessions
confined, no off-machine exfiltration in Swift product path.
- **C1 CRITICAL** `EngramWebUIServer` starts unconditionally on `127.0.0.1:3457`, NO auth/CSRF/Origin check; `GET /session/:id` renders full UNREDACTED transcripts. Loopback ≠ access control on multi-user host; DNS-rebinding via missing Origin/Host validation. (CLAUDE.md claims web is removed from product path — it is NOT. Independently corroborated by service-runtime agent.) Fix: opt-in default-off + per-launch bearer token + Host/Origin validation, or Unix-socket bind.
- **C2 CRITICAL** `project_move/archive/batch` `src`/`dst` unconfined: any MCP client can `rename(2)` arbitrary dirs anywhere writable + byte-rewrite transcript files by substring. `force:true` removes the git guard. Fix: confine to canonicalized session/project roots (mirror `isAllowedSessionFilePath`).
- **H1 HIGH** no authz on any mutating command; `EngramServiceError.unauthorized` is dead code (never thrown). Add `getpeereid` peer-cred check + capability token for destructive commands, or honestly document same-uid trust.
- **H2 HIGH** `KeychainHelper.isUnsignedBuild` (true for any DerivedData/unsigned build) silently writes API keys plaintext to `settings.json` (0600) with no UI warning. Don't conflate Debug with ad-hoc-signed release.
- **M1** socket inode mode left to umask (only dir 0700 enforces). **M2** error envelopes echo raw `localizedDescription` (paths/SQL) over IPC + into web UI. **M3** export redaction is best-effort regex, export-only (not storage/web/embeddings); misses AWS/Google/JWT/PEM.
- **L1** FTS `MATCH ?` accepts raw FTS5 syntax (DoS surface, not SQLi — already handled gracefully).

## 11. Theme — Release process
Recent "harden release" commits are verification theater.
- **F1 CRITICAL** `build-release.sh:64-95` export fallback `ditto`-copies the `Apple Development`-signed archive, then `codesign --verify --strict` passes and prints "Build complete!" — but that signature **cannot be notarized** → Gatekeeper-blocked on other machines. `--verify` checks seal integrity, not identity.
- **F2 CRITICAL** `tests/scripts/build-release-script.test.ts` asserts the script TEXT contains a grep regex; never executes the script. Cannot catch F1/wrong-signature/forbidden-bundle/non-running binary.
- **F3 HIGH** CLAUDE.md bundle-hygiene rules (no node/dist/daemon.js) enforced by NOTHING (prose only). Add a forbidden-path assertion.
- **F4 HIGH** no scripted deploy; `rm -rf` + `cp -R` (silent-skip-running-binary) lives only in prose; no quit/verify step.
- **F5 HIGH** no Hardened Runtime (empty entitlements, no `ENABLE_HARDENED_RUNTIME`, no `hardenedRuntime` in ExportOptions) → notarization impossible regardless.
- **F6 HIGH** versions static + uncoordinated (Info.plist 1.0/1, package.json 0.1.0); no bump. **F7 MEDIUM** helper re-sign uses `--timestamp=none` (notarization rejects) + fragile `PlugIns`-absence heuristic; `--deep` verify was REMOVED in the "harden" commit. **F8 MEDIUM** no CI lane builds/exports/checks the release bundle. **F9/F10 LOW** writes to gitignored `macos/build/`; dead team-id placeholder guard.

---

## Cross-cutting root-cause themes (for round-2 targeting)
1. **Composition-root gap** (V1, V2, feat-C1, obs-O1/O2, test-H3): a correct-looking deferred-job / backfill / migration / observability architecture exists but the running service never wires it; unit tests drive the pieces directly so the suite stays green while production is broken. **Highest leverage.**
2. **Missing single source of truth** (qual-F1/F2/F6, read-F1/F9, ts-F1): injection classifier ×8, probe detector ×2, parent scoring ×2, count-vs-stream ×many, tier rules TS≠Swift. Consolidate + parity-assert.
3. **Advertised-but-inert** (feat-C1/H2/H3, ui-M2/M3, sec docs): semantic search, manual link/unlink, Windsurf/Antigravity, embedding settings, JSON tab, summary — docs/UI promise, runtime stubs/no-ops. Reconcile implement-vs-remove.
4. **Verification theater** (rel-F1/F2/F3, test-H2/H3/M2, sec "unauthorized"/"secure" naming, obs cosmetic views): checks that look protective but don't enforce.
5. **Main-thread blocking + invisibility** (ui-C1/C2/H1-H3 + obs-O2/O3/O4): the UI hangs AND the indexing failure that hangs it is unobservable.

## Verification method note
V1/V2 verified by: schema/trigger inspection of live DB DDL, `INSERT INTO
sessions_fts` grep (non-test), live counts (NO-FTS newest sessions, 392 missing,
137,628 pending jobs), `migrate()`/`runInitialScan` caller grep,
`StartupIndexJobRunning` conformer grep. Other findings are static-analysis from
the round-1 agents; round 2 should empirically confirm the next tier
(web-UI reachability, project_move exploitability, UI hang magnitude) before
remediation.
