# Engram Deep Review — FINAL Consolidated Report (2026-05-22)

Synthesis of two adversarial review rounds (17 Opus subagents), the lead
reviewer's empirical verification against the live system, and independent
cross-provider validation. Supersedes nothing — it consolidates
`docs/reviews/2026-05-22-deep-review-round6.md` (round 1) and
`docs/reviews/round7/*.md` (round 2 + provider adjudications).

## Status legend
- **[V]** Empirically verified by the lead reviewer (live DB query / grep / DDL).
- **[V+G]** Verified by lead reviewer AND independently confirmed plausible by Gemini.
- **[A]** Found by code-reading Opus agents (read real source; not independently re-checked here).
- **[A+G]** Agent finding + Gemini independently rated PLAUSIBLE.
- **[?]** Flagged as possible over-reach or needs-scoping.
- **[NEW]** Surfaced by cross-validation, not yet code-verified.

---

## 1. Executive summary

The product has **one verified critical failure chain that makes core
functionality non-working on the current runtime**, plus two confirmed-reachable
**security criticals**, on top of a large body of band-aid / advertised-but-inert
/ verification-theater issues consistent with the "minimal-resistance" pattern
the review was asked to hunt.

The single most important result: **the running Swift `EngramService` never
populates FTS content and never runs schema migration or the documented startup
backfill chain.** New sessions indexed by the current code are not keyword-searchable;
a fresh install would silently produce a permanently empty database while
reporting success. This is masked on existing machines by 82,931 FTS rows written
by the *old* TS/Node runtime.

Important nuance (corrects an over-statement): the app is **not** fully "DOA" on
existing installs. The session **list** uses a normal table query and still shows
all 11,413 sessions; only **keyword search** uses `INNER JOIN sessions_fts`, so it
silently misses sessions indexed since the runtime switch. **Fresh installs**, by
contrast, are broken (empty DB, fake success) per V3.

## 2. Methodology & cross-validation coverage

- **Round 1** (11 Opus agents): feature, code-quality, testing, observability, UI,
  security, release + 4 code-implementation groups (service/MCP, write path,
  read/adapters, TypeScript).
- **Round 2** (6 Opus deep-dives): composition-root, single-source-of-truth,
  advertised-vs-runtime, security-confirm, release-gate, ui-obs-test.
- **Lead empirical verification**: live `~/.engram/index.sqlite` queries + source
  grep confirmed V1/V2/V3 (§3).
- **External cross-validation** (requested: Codex + all PolyCli providers):
  - **Gemini 3.1 Pro** — ✅ completed a full independent adjudication
    (`round7/_provider-gemini.md`). Confirmed V1/V2/V3 HIGHLY PLAUSIBLE, rated the
    major IPC/write/UI findings PLAUSIBLE, surfaced 5 omissions, flagged 2 over-reaches.
  - **Codex (GPT-5.x)** — ✅ completed on a bounded re-run (`round7/_provider-codex.md`).
    Independently confirmed V1/V2/V3 + SEC-C1/C2 **TRUE** with file:line proof, AND
    earned its keep by catching **one over-statement (V3 service-level) and one NEW
    bug (linkSessions sensitive-path guard ineffective)** that 17 agents + Gemini + the
    lead all missed. Both corrections were then re-verified by the lead against source.
    (The first attempt hung for 24 min and was cancelled.)
  - **qwen, cmd(deepseek), minimax** — ✗ network-unreachable in this environment
    (connection/fetch errors; minimax wants HTTPS_PROXY). Not run.
  - **opencode(deepseek-v4), claude** — ✗ PolyCli single-shot `ask` is non-agentic;
    they emitted tool-call markup without executing, or timed out. No usable verdict.
  - Coverage is therefore: 17 Opus agents + lead empirical + Gemini independent.
    The China-region providers and non-agentic single-shot providers could not
    participate; this is an environment/infra limitation, recorded honestly.

---

## 3. THE VERIFIED CRITICAL CHAIN (composition-root gap) — [V+G]

**Evidence (live DB + source):**
- `sessions_fts` DDL = standalone `fts5(session_id UNINDEXED, content, tokenize='trigram …')`, **no external-content, no triggers**.
- Only `INSERT INTO sessions_fts` in non-test Swift = `VALUES('optimize')`. No `(session_id, content)` insert exists. `SessionSnapshotWriter` only DELETEs + enqueues `session_index_jobs(job_kind='fts')`.
- `StartupIndexJobRunning` (the job consumer protocol) has **no production conformer** — only in `runInitialScan`'s signature.
- `EngramServiceRunner.run()` (only thing `EngramService/main.swift` calls) → only `writer.indexRecentSessions()`. **Never** calls `migrate()` (only CLI `EngramCoreSchemaTool` does) nor `StartupBackfills.runInitialScan` (defined, never called).
- Live counts: newest sessions (today) = NO FTS content; ~340–392 non-skip sessions lack FTS content; large `session_index_jobs` backlog never drained by current Swift (old Node runtime drained the pre-2026-05-20 ones — `metadata.pricing_source=node-pricing-table`).
- Reader: `EngramServiceReadProvider.search` uses `INNER JOIN sessions_fts`.

**V1** — new sessions not keyword-searchable (FTS content never written).
**V2** — migrate + entire documented startup backfill chain dead in production
(`downgradeSubagentTiers`, `resetStaleDetections`, `backfillCodexOriginator`,
`reconcileInsights`, `optimizeFts`, `vacuumIfNeeded`, orphan scan, job recovery).
Inline adapter-time parent detection (Layers 1/1b/1c) still works for new sessions.
**V3** — fresh-machine breakage. CORRECTED after Codex review: the per-snapshot
swallow + fake batch count is TRUE at the `SwiftIndexer` level (`SessionBatchUpsert.swift:27`
catches → `.failure`; `SwiftIndexer.swift:38` still `indexed += batch.count`), but the
*service-level* outcome is **invisible scan failure, not fake success**:
`EngramDatabaseIndexer.indexSessions()` runs `backfillPolycliProviderParents/SuggestedParents`
in a `write{}` block (`:53-55`) right after `indexAll()`, which THROWS on a missing
`sessions` table — so `indexRecentSessions` throws and the scan fails (silently, per
OBS-C2), rather than reporting success. Net outcome on a fresh install is still a
permanently empty DB; the failure is just invisible rather than fake-positive.
Separately, `indexStatus():73-75` returns `total:0` when `sessions` is absent → a
missing schema also *looks like* an empty-but-healthy DB in status paths.

Also dead/never-wired (same root): `SessionWatcher` (real-time incremental
indexing), `NonWatchableSourceRescanner` (`:34` can drain jobs after rescans but has
no production wiring — Codex-confirmed as a distinct dead surface),
`StartupOrphanScanning`, `StartupUsageCollecting`, `indexAllSessions()`.

**Fix** (round7/composition-root.md §5): in `EngramServiceRunner.run()` —
(1) call `gate.migrate()` once before `server.start()`, fail-fast `exit(1)` if
schema absent; (2) run `runInitialScan` once on startup in a detached task with
real `StartupBackfillDatabase`/`StartupIndexJobRunning`/`StartupOrphanScanning`
conformers (thin wrappers over existing, unit-tested static functions);
(3) the FTS job consumer must `buildSearchContent(session)` (one line per
user/assistant message + summary, mirroring `src/core/db/fts-repo.ts:33-46`) and
`INSERT INTO sessions_fts(session_id, content)`, batching (LIMIT 200) through
`performWriteCommand` to drain the backlog; mark embedding jobs `not_applicable`
(no Swift provider) rather than silently completing. Add the §6 end-to-end test
(index via real service → assert searchable) that would have caught this.

---

## 4. Security — confirmed reachable [V+G]

- **SEC-C1 [V+G] CRITICAL** — `EngramWebUIServer` always-on `127.0.0.1:3457`,
  started unconditionally by `EngramServiceRunner` (PID 54338 confirmed listening).
  No auth/CSRF/Origin; `curl` returns 200 even with spoofed `Host`/`Origin`
  → **DNS-rebinding/CSRF** (Gemini: "easily exploited from any malicious website").
  `GET /session/:id` renders **unredacted** transcripts (web does HTML-escape only;
  export path uses `redactSensitiveContent`). CLAUDE.md falsely says web UI is
  "removed from product path." **Fix**: opt-in default-off + per-launch bearer token
  in 0700 run-dir + Host/Origin validation + reuse redaction.
- **SEC-C2 [V] CRITICAL** — `project_move/archive/batch` `src`/`dst` unconfined
  (no allow-list, unlike `linkSessions`' `isAllowedSessionFilePath`); `force:true`
  from MCP bypasses the git guard. Any MCP client can `rename(2)` arbitrary dirs +
  substring-rewrite transcripts. **Fix**: canonicalize + confine to session roots.
- **SEC-H1 [V] HIGH** — no authz on mutating commands; `EngramServiceError.unauthorized`
  is dead code; no `getpeereid` on `accept()`. **Fix**: peer-cred check + capability
  token for destructive commands (share the run-dir token primitive with SEC-C1).
- **SEC-H2 [V] HIGH** — `isUnsignedBuild` silently writes API keys plaintext to
  `settings.json` (no UI warning) for DerivedData/ad-hoc builds. (Current
  `/Applications` build is Apple-Development-signed → not leaking on this machine.)
- **SEC-H3 [V, Codex-found] HIGH** — `linkSessions`' sensitive-path guard is partly
  ineffective. `containsSensitivePathComponent` (`EngramServiceCommandHandler.swift:1257-1258`)
  splits the relative path by `/` into single components and tests each against a set that
  includes the COMPOUND string `"Library/Keychains"` — which can never equal a single
  component, so paths under `~/Library/Keychains` are NOT blocked. (`.ssh/.aws/.gnupg/.kube/.docker/.1password`
  single-component entries DO work.) This also means round-1's claim that linkSessions
  "blocks Keychains" was OVERSTATED. **Fix**: split `"Library/Keychains"` into a 2-component
  sequence check, or match on path prefix rather than component equality.
- **SEC-M1/M2/M3** — socket inode mode left to umask (Gemini independently raised
  this as an omission — corroborates); error envelopes echo raw `localizedDescription`
  over IPC + into web UI; export-only redaction misses AWS/Google/JWT/PEM.

---

## 5. Service / IPC [A+G]

- **IPC-H1 [A+G] HIGH** — `accept()` loop treats any `accept()<0` as fatal `break`;
  `EINTR`/`ECONNABORTED`/`EMFILE` permanently kill the acceptor while the process
  stays alive holding the lock. Gemini: "classic … kills the listener permanently."
  Fix: discriminate `errno`, `continue` on transient.
- **IPC-H2 [A+G] HIGH** — `writeFrame` doesn't enforce the 256 KB cap `readFrame`
  enforces; `search` `snippet` is full untruncated FTS content → limit=100 responses
  exceed 256 KB → client rejects legit results. Fix: truncate snippet server-side +
  symmetric write guard.
- **IPC-M1 [A] MEDIUM** — decode/handler errors reply `requestId:"unknown"` → client
  id-match guard masks the real error.
- IPC-M2/L (cancellation-unaware blocking I/O on teardown; unchecked `kind` field).

## 6. Write path / data integrity [A, partial G]

- **WP-H1 [A+G] HIGH** — `backfillSuggestedParents` 24h window compares ISO8601
  `…T…Z` lexicographically vs `datetime(?, '-24 hours')` (space-separated) → broken
  lower bound. Gemini confirmed the `T`(84)/space(32) ordering hazard.
- **WP-H2 [A / ?] HIGH→scope** — `executeAndCountChanges` uses `sqlite3_total_changes`
  (trigger-inclusive) → inflated counts. Gemini: likely a **logging artifact /
  over-reach unless the count drives truncation or a loop**. ACTION: check whether
  the inflated count gates control flow; if only logged, downgrade to LOW.
- **WP-H3 [A] HIGH** — cascade trigger resets tier only for confirmed children, not
  `suggested_parent_id` children (stuck at `skip`, never resurface).
- **WP-M1 [A] MEDIUM** — `reconcileInsights` `id NOT IN (SELECT id FROM insights)`
  soft-deletes the entire vector store when `insights` is empty/partial; NULL-unsafe.
  (Mitigated today only because reconcile is dead per V2 — but becomes live once V2
  is fixed, so fix WP-M1 BEFORE wiring reconcile.)
- WP-M2/M3/M4, L1–L3 per round 6 §2.

## 7. Single source of truth — all behavioral [A]

- **SST-1** injection-classifier prefix list duplicated across **8 sites**, diverging
  (Codex header set 4 tags vs its TS reference 10, despite "mirrors TS"). `<command-name>`
  counted as user turn in header but rendered as system pill in app.
- **SST-2** `isProviderReviewPrompt/Summary` duplicated verbatim; over-broad
  `contains("tests ")/"review"/"correctness"` can misclassify a **real review session**
  as a throwaway probe → `tier=skip` → hidden.
- **SST-3** parent scoring duplicated with DIFFERENT constants (4h half-life/4h gap vs
  6h/48h/30min) → live vs backfill disagree on links.
- **SST-4** `parseSessionInfo` header counts vs `streamMessages` diverge in ≥6 adapters
  (VsCode hardcodes `messageCount = requests*2`); **no parity assertion
  `messageCount == messages.count` exists; no Swift `SessionTier` test exists at all.**
- **SST-5** TS tier rules (`PROBE_FIRST_LINES`, `messageCount<=3 probe→lite`, 6
  NOISE_PATTERNS) absent from Swift (Swift has 2).
- Fix: one `SystemMessageClassifier.isInjection`, one `PolicliProbeDetector`, one
  `ParentScoring`, one `normalize()->[NormalizedMessage]` feeding both count+stream;
  add the 4 missing parity/tier tests (they go red today — proof these are real).

## 8. Advertised but inert [A]

- Local semantic search (FTS+sqlite-vec+RRF) **not implemented**: `SQLiteVecSupport.probe()`
  = "not implemented yet"; no Swift embedding client; RRF over a single keyword list = no-op;
  `save_insight` always text-only. **Whole AI Settings section persisted but never read.**
  `generate_summary`/`regenerateAllTitles` are template/extractive (`nativeSummary`/`nativeTitle`)
  yet described as "AI summary".
- Layer-3 manual link/unlink dead; Windsurf+Antigravity `enableLiveSync:false` → zero ingest
  (17 sources advertised, 15 actually ingest); "JSON" transcript tab == "Text"; summary UI
  entry dead; `hygiene` returns constant score=100; `triggerSync` "not implemented".
- **[? Gemini]** Gemini flags "AI Settings never read" and "Layer-3 link dead" as possibly
  **roadmap/incomplete features, not bugs**. Adjudication: they are not crashes, but they ARE
  defects of the "advertised-but-inert" class the review targeted (docs/UI promise a capability
  the runtime silently no-ops). ACTION = honest reconcile (implement or remove claim+UI), not
  necessarily "fix now". The doc/UI lying about it is the real defect.

## 9. Read path / adapters [A+G]

- **RA-1 [A+G] HIGH** — `CascadeDiscovery` calls `waitUntilExit()` before
  `readDataToEndOfFile()` → pipe-buffer deadlock on large `ps`/`lsof`. Gemini: "legendary
  Apple Process bug … classic deadlock," FATAL. Fix: read-then-wait.
- **RA-2 [A] HIGH** — `AntigravityAdapter.inferredCWD` hardcodes the author's machine layout
  `/Users/<user>/-Code-/<project>` → wrong/empty for any other user.
- **RA-3 [A] MEDIUM** — `WatchPathRules.maxDrainBatchSize` loaded from unrelated key
  `startupParentBackfillLimit`.
- plus count↔stream divergences (→ §7), `StreamingLineReader` recovery, hand-rolled JSON escaping.

## 10. Observability / UI [A+G]

- **OBS-C1 [A] CRITICAL** — 5 Observability views read `logs`/`traces`/`metrics` tables
  Swift never writes (os_log only) → perpetually empty "all clear". Fix: repoint to
  `OSLogStore.local()`.
- **OBS-C2 [A] CRITICAL** — `status` always returns `.running`; app `apply(event:)` has no
  `index_error` branch → indexing failure invisible through every surface (compounds V1/V3).
- **OBS-H1/H2 [A]** — per-session parse failure dropped (bare `continue`, reason discarded);
  one bad session aborts the whole scan.
- **UI-C1/C2 [A+G] CRITICAL** — 12 views call synchronous `DatabaseManager` reads on the main
  thread (no `Task.detached`) → UI hangs on a real DB; SessionListView re-runs 2000-row fetch +
  2× 2000-param IN + main-thread grouping on every filter/favorite/delete. Gemini: "dreaded
  macOS spinning beachball." Fix: mirror `HomeView.loadData` `Task.detached`.
- **UI-H3 [A] HIGH** — a11y is test-satisfying: 112 identifiers, 5 labels, 0 values; charts
  invisible to VoiceOver.
- UI-M1..M4 (no error states; JSON tab stub; dead summary; hardcoded "WAL Mode: OK").

## 11. Release [A → confirmed against real artifact]

- **REL-C1 [A] CRITICAL** — export fallback `ditto`-copies an `Apple Development`-signed app
  (verified on the real Debug bundle: authority=Apple Development, `flags=0x0(none)` no Hardened
  Runtime, no Timestamp) and prints "Build complete!"; `codesign --verify` passes but it
  **cannot be notarized**. **REL-C2** the only release test asserts script TEXT, never executes.
- REL-H: no bundle-hygiene gate; no Hardened Runtime; static uncoordinated versions; no scripted
  deploy; `--deep` verify removed; no CI release lane. Real gate designed in round7/release-gate.md §6.

---

## 12. Cross-validation: NEW omissions to investigate (Gemini) [NEW]

Not yet code-verified — queue for a targeted follow-up:
1. **Multi-process SQLite WAL `-shm` permissions under App Sandbox** — if the app reads the
   service-owned DB, sandbox may block the `-shm`/`-wal` files → `SQLITE_BUSY`/`CANTOPEN`/silent
   corruption. (Check entitlements/sandbox + how app opens the DB.)
2. **App Nap / daemon suspension** — without `ProcessInfo.beginActivity(.userInitiated)` /
   `disableAutomaticTermination`, background `EngramService` may be suspended → socket drops.
3. **JSONDecoder memory spikes** on large transcripts — verify the Swift adapters stream
   (`StreamingLineReader` exists; check whether all source parsers use it vs whole-file decode).
4. **Socket inode permissions** — corroborates SEC-M1 (chmod 0600 the socket, not just the dir).
5. **UI refresh strategy** — how does the app learn of service writes? polling (battery) vs
   change-notification (staleness). Verify.

## 13. Over-reach / scoping adjudication

- **WP-H2** (`total_changes`): downgrade unless the count gates control flow — verify first.
- **AI Settings inert / Layer-3 link dead**: real "advertised-but-inert" defects, but remediation
  is "reconcile docs+UI vs runtime," not emergency bug-fix. Don't over-state as crashes.
- **V3 wording** (Codex): the per-batch fake count is real, but at the service level the run
  fails invisibly (backfill throws on missing `sessions`) rather than fake-completing — corrected in §3.
- **linkSessions "blocks Keychains"** (Codex): OVERSTATED; the guard is ineffective for that entry
  → reclassified as the NEW bug SEC-H3 (§4).
- General: no validator found a FALSE critical. Gemini + Codex both independently confirmed
  V1/V2/V3 + SEC-C1/C2; Codex's two corrections were re-verified by the lead against source. The
  lead's V1/V2/V3 are empirically grounded (live DB + grep), not static-only.

---

## 14. Prioritized remediation roadmap

**P0 — product is broken / exploitable (do first):**
1. Composition-root wiring: `migrate()` + `runInitialScan()` + real FTS job consumer +
   fresh-machine fail-fast (fixes V1, V2, V3). Add the e2e searchability test.
   ⚠ Fix WP-M1 (reconcileInsights empty-set guard) BEFORE wiring reconcile.
2. SEC-C1 web UI: default-off + token + Host/Origin + redaction.
3. SEC-C2 project_move path confinement; SEC-H1 peer-cred/capability token.

**P1 — reachable failures / data integrity:**
4. IPC-H1 accept() errno; IPC-H2 snippet truncation + write cap.
5. RA-1 Process pipe deadlock; WP-H1 datetime compare; WP-H3 suggested-child tier reset.
6. UI-C1/C2 main-thread DB reads → Task.detached.
7. OBS-C2 status `.degraded` + `index_error` event branch; OBS-H1/H2 per-session error logging.

**P2 — systemic quality / honesty:**
8. Single-source-of-truth consolidation (§7) + the 4 missing parity/tier tests.
9. Advertised-vs-runtime reconcile (§8): remove dead UI/claims or implement; fix CLAUDE.md's
   3 false statements (keyword-only search, 15 ingesting sources, web UI not removed).
10. Release gate (§11) + Hardened Runtime + bundle hygiene + CI lane.
11. OBS-C1 observability views via OSLogStore; UI-H3 real a11y.

**P3 — investigate (cross-validation omissions §12):** WAL `-shm` sandbox, App Nap, JSON memory,
socket chmod, UI refresh strategy.

**Process note:** the recurring root cause across P0–P2 is *building a correct-looking mechanism
and never wiring it into the production composition root, with tests driving the pieces directly
so the suite stays green.* The highest-leverage durable fix is the e2e "real service → assert
behavior" test class, which converts these silent gaps into red tests.
