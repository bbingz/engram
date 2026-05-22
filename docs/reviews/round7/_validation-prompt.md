# Cross-provider validation request — Engram deep review (rounds 1+2)

You are an independent senior reviewer. A multi-agent review of the **Engram**
macOS app (native SwiftUI + Swift `EngramService`/`EngramMCP` runtime; TypeScript
is dev/reference only) produced the findings below. Your job is NOT to repeat the
review from scratch. Your job is to **adjudicate**:

1. **Verify correctness** — for each CRITICAL/HIGH claim, open the cited files in
   this repo and confirm whether the claim is TRUE, OVERSTATED, or FALSE. Cite
   the file:line evidence you actually saw. Do not trust the claim; check it.
2. **Find omissions** — name concrete defects, risks, or band-aids the agents
   MISSED, with file:line. Focus on the runtime product path (Swift), not the
   retained TypeScript reference.
3. **Re-rank severity** — give your own top-5 most important issues and say where
   you disagree with the assigned severity.
4. **Call out any agent over-reach** — places where the review invented a problem
   that isn't real, or proposed a fix that would break something.

Be terse and specific. Prefer "WRONG: <file:line> actually does X because …" over
generic agreement. If you cannot verify a claim from the code, say "UNVERIFIED"
rather than guessing.

## Repo facts (ground truth, already empirically confirmed)
- Working dir is the repo root. Read `docs/reviews/2026-05-22-deep-review-round6.md`
  (round-1, 11 agents, organized by area) and `docs/reviews/round7/*.md`
  (round-2 deep dives: composition-root, single-source-of-truth,
  advertised-vs-runtime, security-confirm, release-gate, ui-obs-test).
- Live DB `~/.engram/index.sqlite` is 544 MB, ~11,413 sessions.

## The two VERIFIED-CRITICAL findings to scrutinize hardest
- **V1**: current Swift code never writes FTS content. `sessions_fts` is a
  standalone fts5 table (no external-content, no triggers); the only
  `INSERT INTO sessions_fts` is `VALUES('optimize')`. `SessionSnapshotWriter`
  only DELETEs FTS rows + enqueues `session_index_jobs(job_kind='fts')`, and the
  consumer protocol `StartupIndexJobRunning` has no production conformer. Newest
  sessions show NO FTS content; many pending fts jobs accumulate. ⇒ new sessions
  are not keyword-searchable; the reader uses `INNER JOIN sessions_fts`.
- **V2**: `EngramServiceRunner.run()` (the only thing `EngramService/main.swift`
  calls) only calls `writer.indexRecentSessions()`. It never calls `migrate()`
  (only the CLI `EngramCoreSchemaTool` does) nor `StartupBackfills.runInitialScan`
  (defined, never called). ⇒ the documented startup backfill chain, FTS job
  drain, reconcileInsights, vacuum, etc. are dead in production. Inline
  adapter-time parent-detection (Layers 1/1b/1c) still works for new sessions.

**Scrutinize V1/V2 hardest**: is there ANY path (a trigger, a GRDB observation, a
launcher step, an Xcode build phase, a different runner) that actually populates
FTS or runs migrate/backfills that the agents missed? If you find one, V1/V2 are
wrong — say so loudly with evidence.

- **V3 (new, also scrutinize hard)**: fresh-machine fake success. Because the
  service never calls `migrate()`, on a clean `~/.engram` the first
  `indexRecentSessions` should fail with `no such table: sessions`, BUT the
  per-snapshot catch (`SessionBatchUpsert.swift:27`) swallows the error and
  `SwiftIndexer.indexAll` still does `indexed += batch.count` (~:38), reporting a
  fake non-zero indexed count with zero actual writes → permanently empty DB on a
  new install. Verify this swallow-and-fake-count path. Also: `SessionWatcher`
  (real-time incremental indexing), orphan scan, usage collecting are claimed to
  have no production conformer/caller (test-only) — confirm or refute.

## Condensed findings to adjudicate (full detail in the docs above)

### Composition root / runtime wiring
- V1, V2 (above). Plus: `session_index_jobs` 137k+ rows accumulate unconsumed.

### Single source of truth (all judged behavioral, not cosmetic)
- System-injection prefix list duplicated across 8 sites, diverging (canonical
  `SystemMessageClassifier` + 7 inline copies in SwiftIndexer ×2, Codex/ClaudeCode/
  CommandCode/Iflow/Qwen/Qoder adapters). Codex header set (4 tags) narrower than
  its TS reference (10) despite a "mirrors TS" comment.
- `isProviderReviewPrompt/Summary` duplicated verbatim (SwiftIndexer:247-266 vs
  StartupBackfills:864-883); over-broad `contains("tests ")/"review"/"correctness"`
  can misclassify a real review session as a throwaway probe → tier=skip → hidden.
- Parent scoring duplicated with DIFFERENT constants (ParentDetection 4h half-life,
  4h gap vs StartupBackfills 6h/48h, 30min gap) → live vs backfill disagree on links.
- `parseSessionInfo` header counts vs `streamMessages` diverge in ≥6 adapters;
  VsCode hardcodes `messageCount = requests*2`; no parity assertion
  (`messageCount == messages.count`) exists; no Swift `SessionTier` test exists.
- TS tier rules (PROBE_FIRST_LINES, messageCount<=3 probe→lite, 6 NOISE_PATTERNS)
  absent from Swift (Swift has 2 NOISE_PATTERNS).

### Advertised but inert
- Local semantic search (FTS+sqlite-vec+RRF) not implemented in product:
  `SQLiteVecSupport.probe()` returns "not implemented yet"; no Swift embedding
  client; RRF computes `1/(60+rank)` over a single keyword list (no-op fusion);
  `save_insight` always text-only.
- Whole AI Settings section (provider/prompt/embeddings ×3/title/auto-summary)
  persisted but never read at runtime. `generate_summary` and `regenerateAllTitles`
  are template/extractive (`nativeSummary`/`nativeTitle`), ignoring AI settings,
  yet described as "AI summary".
- Layer-3 manual link/unlink dead (request types defined, no handler/client/caller).
- Windsurf + Antigravity adapters `enableLiveSync:false` everywhere → zero ingest.
- "JSON" transcript tab byte-identical to "Text"; summary UI entry is dead code;
  `hygiene` returns constant score 100; `triggerSync` returns "not implemented".
- CLAUDE.md says web UI "removed from product path" — it is NOT (still wired).

### Security (all empirically confirmed reachable on the running machine)
- `EngramWebUIServer` always-on `127.0.0.1:3457`, no auth/CSRF/Origin check
  (curl returns 200 even with spoofed Host/Origin → DNS-rebinding/CSRF); renders
  UNREDACTED transcripts (web does HTML-escape only; export uses
  `redactSensitiveContent`).
- `project_move/archive/batch` src/dst unconfined (no allow-list, unlike
  `linkSessions`' `isAllowedSessionFilePath`); `force:true` bypasses git guard.
- No authz on mutating commands; `EngramServiceError.unauthorized` is dead code;
  no `getpeereid` on accept().
- `isUnsignedBuild` silently writes API keys plaintext to settings.json (no UI
  warning) for DerivedData/ad-hoc builds.

### Service / IPC
- accept() loop treats any `accept()<0` as fatal `break` (EINTR/ECONNABORTED/EMFILE
  permanently kill the acceptor while the process stays alive holding the lock).
- `writeFrame` doesn't enforce the 256 KB cap that `readFrame` enforces; `search`
  snippet is full untruncated FTS content → limit=100 responses can exceed 256 KB
  → client rejects legit results.
- decode/handler errors reply `requestId:"unknown"` → client id-match guard masks
  the real error.

### Write path / data integrity
- `backfillSuggestedParents` 24h window compares ISO8601 `...T...Z` lexicographically
  against `datetime(?, '-24 hours')` (space-separated) → broken lower bound.
- `executeAndCountChanges` uses `sqlite3_total_changes` (trigger-inclusive) →
  inflated dedup "removed" counts.
- cascade trigger resets tier only for confirmed children, not `suggested_parent_id`
  children (they keep `skip`, never resurface).
- `reconcileInsights` `id NOT IN (SELECT id FROM insights)` soft-deletes the entire
  vector store when `insights` is empty/partial; NULL-unsafe.

### Read path / adapters
- `AntigravityAdapter.inferredCWD` hardcodes the author's machine layout
  `/Users/<user>/-Code-/<project>`.
- `CascadeDiscovery` calls `waitUntilExit()` before `readDataToEndOfFile()` →
  pipe-buffer deadlock on large `ps`/`lsof` output.
- `WatchPathRules` `maxDrainBatchSize` loaded from unrelated key
  `startupParentBackfillLimit`.

### Observability / UI
- 5 Observability views read `logs`/`traces`/`metrics` tables that Swift never
  writes (os_log only) → perpetually empty "all clear".
- `status` command always returns `.running`; app's `apply(event:)` has no
  `index_error` branch → indexing failure invisible.
- 12 views call synchronous `DatabaseManager` reads on the main thread (no
  `Task.detached`) → UI hangs on a real DB. SessionListView re-runs 2000-row fetch
  + 2× 2000-param IN + main-thread grouping on every filter/favorite/delete.
- a11y is test-satisfying: 112 accessibilityIdentifier, 5 label, 0 value; charts
  invisible to VoiceOver.

### Release
- export fallback `ditto`-copies an `Apple Development`-signed app and reports
  "Build complete!" though it cannot be notarized; the only release test asserts
  script TEXT not behavior; no bundle-hygiene gate; no Hardened Runtime; static
  uncoordinated versions; `--deep` verify removed.

## Output format
Return markdown:
1. **V1/V2 verdict** (TRUE/OVERSTATED/FALSE + evidence; did you find a missed
   population/migration path?).
2. **Per-section adjudication** — only the items where you have something to add
   (confirm with evidence / refute / nuance).
3. **Omissions** — concrete missed issues with file:line.
4. **Your top-5 by severity.**
5. **Over-reach / wrong fixes flagged.**
