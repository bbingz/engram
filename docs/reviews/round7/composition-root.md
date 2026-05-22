# Round 7 — Definitive Map of the Production Composition Root (2026-05-22)

Read-only deep dive on product code. Builds on round 6 §0 (VERIFIED V1/V2),
§2, §5, §8. V1/V2 are re-confirmed here with fresh empirical evidence plus
several new instances of the same systemic root cause.

**Thesis:** Engram contains a correct-looking, unit-tested, deferred-job /
ordered-backfill / migration / live-watch / observability architecture. The
single production composition root — `EngramServiceRunner.run()` — wires almost
none of it. It assembles exactly three things (writer gate, socket server, web
UI) and runs one polling loop that calls `writer.indexRecentSessions()`. Every
other subsystem (migration, initial scan, job draining, FTS-content writing,
backfill chain, orphan scan, file watcher, usage collector) exists only as
types with test-only conformers. This is the dominant systemic defect.

---

## 1. EngramService startup/runtime trace (what IS wired vs documented)

### 1.1 The complete production call chain

`EngramService/main.swift`
→ `EngramServiceRunner.run()` (`EngramService/Core/EngramServiceRunner.swift:12`)

`run()` constructs and starts, in order:

| Step | Line | What it does | Wired? |
|---|---|---|---|
| socket/db path resolution | :16-24 | resolves `--service-socket`, `--database-path`; db defaults to `~/.engram/index.sqlite` | yes |
| runtime dir (0700) | :26-42 | creates secure runtime dir + db parent dir | yes |
| `ServiceWriterGate(...)` | :52 | dual flock + `EngramDatabaseWriter(path:)` | yes |
| `EngramServiceCommandHandler(...)` | :53-56 | command dispatch + `SQLiteEngramServiceReadProvider` | yes |
| `UnixSocketServiceServer(...).start()` | :57-60 | accepts IPC | yes |
| `EngramWebUIServer(databasePath:)` | :61-90 | **web UI on 127.0.0.1:3457, started unconditionally** (corroborates round 6 sec-C1; CLAUDE.md claims web is removed — it is NOT) | yes |
| `runIndexingLoop(gate:)` | :96-98, :191 | the only write workload | yes |
| startup WAL TRUNCATE | :107 | best-effort checkpoint | yes |
| periodic PASSIVE checkpoint (20s) | :129 | WAL maintenance | yes |
| idle wait + shutdown TRUNCATE | :156-188 | teardown | yes |

### 1.2 `runIndexingLoop` — the entire production write workload

`EngramServiceRunner.swift:191-226`. First iteration runs immediately, then
every 5 min (`intervalNanoseconds = 5*60*1e9`, :192). Each iteration does
**only**:

```swift
try await gate.performWriteCommand(name: "indexRecent") { writer in
    try await writer.indexRecentSessions()      // :207-209
}
```

`writer.indexRecentSessions()` (`EngramCoreWrite/Indexing/EngramDatabaseIndexer.swift:34`)
→ `indexSessions(adapters: SessionAdapterFactory.recentActiveAdapters())` (:36)
→ `SwiftIndexer(sink:adapters:).indexAll()` (:47-51) — upserts session rows + enqueues `session_index_jobs`
→ INLINE `write { db in StartupBackfills.backfillPolycliProviderParents(db); backfillSuggestedParents(db) }` (:53-56)
→ `indexStatus()` (:58) — COUNT(*) for total/todayParents.

**`EngramServiceRunner.swift:208` is the SOLE non-test production caller of any
indexing entrypoint** (verified by grep: only other matches are the defs and
`*Tests`). `indexAllSessions()` (full scan, all adapters) is never called in
production.

### 1.3 What CLAUDE.md documents vs what is wired

CLAUDE.md (§"Process Lifecycle", §"Session tiering", §"Agent Session Grouping")
documents this startup chain:
`downgradeSubagentTiers → backfillParentLinks → resetStaleDetections →
backfillCodexOriginator → backfillSuggestedParents`, plus
`StartupBackfills.backfillPolycliProviderParents`, `reconcileInsights`,
`optimizeFts`, FTS indexing of `lite+` tiers, embedding of `normal+`.

Reality — what actually runs in production:

| Documented step | Production status |
|---|---|
| `migrate()` (schema + FTS rebuild policy + schema metadata) | **NOT CALLED** — only `EngramCoreSchemaTool/main.swift:13` (CLI dev tool) + tests |
| `runInitialScan` (the ordered chain) | **NOT CALLED** — defined `StartupBackfills.swift:123`, zero non-test callers |
| `downgradeSubagentTiers` | **NOT CALLED** (only via `runInitialScan` → dead) |
| `backfillParentLinks` | **NOT CALLED** (only via `runInitialScan` → dead) |
| `resetStaleDetections` | **NOT CALLED** (only via `runInitialScan` → dead) |
| `backfillCodexOriginator` | **NOT CALLED** (only via `runInitialScan` → dead) |
| `backfillPolycliProviderParents` | **RUNS** — inline at indexer :54 |
| `backfillSuggestedParents` | **RUNS** — inline at indexer :55 |
| `reconcileInsights`, `optimizeFts`, `vacuumIfNeeded`, `deduplicateFilePaths`, `backfillScores`, `backfillFilePaths`, `cleanupStaleMigrations` | **NOT CALLED** (only via `runInitialScan` → dead) |
| orphan scan (`detectOrphans`) | **NOT CALLED** (only via `runInitialScan` → dead; no production conformer) |
| `runRecoverableJobs` (drain `session_index_jobs`) | **NOT CALLED** — no production conformer exists at all |
| `backfillInsightEmbeddings` | **NOT CALLED** — no production conformer |
| FTS content writing | **NEVER HAPPENS** in product Swift (see §2) |
| live file watcher (`SessionWatcher`) | **NOT INSTANTIATED** in production (see §6) |

So of the documented chain, only the two inline backfills at indexer :54-55
run. Everything else is inert.

---

## 2. "Enqueue but never consume" mechanisms

### 2.1 `session_index_jobs` (kinds: `fts`, `embedding`)

**Who enqueues:** `SessionSnapshotWriter.insertIndexJobs`
(`SessionSnapshotWriter.swift:295-321`), driven by `jobKinds(for:changeSet:)`
(:350-359): `.fts` when `tier != skip && searchTextChanged`; `.embedding` when
`tier in {normal,premium} && embeddingTextChanged`. This runs on every merge in
the production indexing loop.

**Who SHOULD consume:** a `StartupIndexJobRunning` conformer's
`runRecoverableJobs()` (called inside `runInitialScan`, `StartupBackfills.swift:286`)
and `NonWatchableIndexJobRunning.runRecoverableJobs()` (called in
`NonWatchableSourceRescanner.rescanNow`, :38).

**Production consumer:** **NONE.** Grep for `func runRecoverableJobs` /
`FROM session_index_jobs` / `IndexJobRunner` returns only `*Tests` files
(`StartupBackfillTests.swift:693`, `WatcherSemanticsTests.swift:192`). There is
no production class that reads the table, no `IndexJobRunner` type, and no
`INSERT INTO sessions_fts(session_id, content, ...)` anywhere in product Swift.

**Empirical (live `~/.engram/index.sqlite`, 2026-05-22):**

```
job_kind  | status            | count
embedding | completed         | 46484
embedding | not_applicable    | 58368
embedding | pending           |   798
embedding | failed_retryable  |    50
fts       | completed         | 31873
fts       | pending           |    57
```

Total 137,630 rows. The `completed`/`not_applicable` rows were drained by a
**prior** runtime: most-recent `fts|completed.updated_at = 2026-05-20 16:39:12`,
most-recent `embedding|completed = 2026-05-20 11:58:45`. But `fts|pending`
spans up to `2026-05-22 12:23:48` (today) and `embedding|pending` to
`2026-05-22 12:22:54`. **Every job created after 2026-05-20 ~16:39 is stuck
pending — nothing has drained one since.** (Round 6 saw "137,628 pending"; the
mix has since shifted because a previous-build/TS run drained the bulk, but the
current Swift service has drained exactly zero. The signal is identical.)

**Consequence:** every newly-indexed `lite+` session never gets FTS content; the
search reader (`EngramServiceReadProvider.swift:341-369`) does
`FROM sessions_fts f JOIN sessions s` (inner join, `MATCH` or `LIKE`), so those
sessions return **zero** keyword hits. `normal+` sessions also never get
embeddings (compounded by feature-C1: no Swift embedding provider exists
anyway).

### 2.2 No other deferred-work queue

`session_index_jobs` is the only deferred-work queue. `migration_log`
(`fs_pending`/`fs_done` states) is reconciled by `cleanupStaleMigrations`, which
is itself dead (§3), but it is not a periodic work queue.

---

## 3. Defined-but-never-called migration / backfill / maintenance functions

All of the following are reachable in production **only** through `migrate()`
or `runInitialScan()`, neither of which the service calls. For each: exact
consequence + any inline mitigation.

| Function | Def | Reached only via | Production consequence of never running | Inline mitigation? |
|---|---|---|---|---|
| `migrate()` / `EngramMigrationRunner.migrate` | `EngramDatabaseWriter.swift:46`, `EngramMigrationRunner.swift:5` | callers: `EngramCoreSchemaTool/main.swift:13` + tests | No schema creation, no FTS-version rebuild, no schema-metadata write on service start. On an existing DB this is masked (schema already present from old build). On a fresh machine the service cannot create any table (see §4). | NONE |
| `FTSRebuildPolicy.apply` | `FTSRebuildPolicy.swift:7` | only inside `migrate()` | A `FTS_VERSION`/`fts_version` bump never forces the documented full FTS re-index; `sessions_fts` is never DROP/recreated. Live `fts_version=3` matches expected, so currently a no-op, but any future bump is silently inert. | NONE |
| `runInitialScan` | `StartupBackfills.swift:123` | nothing (no non-test caller) | Entire ordered backfill chain + orphan scan + job recovery never runs at startup. | partial — see rows below |
| `downgradeSubagentTiers` | `StartupBackfills.swift:441` | `runInitialScan` :198 | Subagent sessions incorrectly upgraded from `skip` by an old build stay searchable/embedded and surface as independent sessions; their FTS rows are never purged. | NONE |
| `backfillParentLinks` (Layer 1 retroactive) | `StartupBackfills.swift:457` | `runInitialScan` :202 | Pre-existing Claude-Code subagent sessions with NULL parent are never retroactively linked. | partial — Layer 1/1b/1c fire INLINE at adapter parse time for *new* sessions (round 6 §0); only retroactive repair of old rows is lost |
| `resetStaleDetections` | `StartupBackfills.swift:490` | `runInitialScan` :206 | `DETECTION_VERSION` bump (`detection_version` metadata, live=4) never triggers re-evaluation; improved heuristics never reapply to already-checked sessions. | NONE |
| `backfillCodexOriginator` | `StartupBackfills.swift:531` | `runInitialScan` :210 | Codex sessions with `originator="Claude Code"` not caught by inline Layer 1b (e.g. originator deeper than first 16 KB, or rows from old builds) never get `agent_role='dispatched'`/`tier='skip'`; dispatched Codex probes surface as independent sessions. | partial — Layer 1b inline at parse covers new Codex sessions |
| `backfillPolycliProviderParents` | `StartupBackfills.swift:570` | `runInitialScan` :214 **AND inline** indexer :54 | (none — actually runs) | **RUNS** inline every scan |
| `backfillSuggestedParents` | `StartupBackfills.swift:694` | `runInitialScan` :228 **AND inline** indexer :55 | (none — actually runs) | **RUNS** inline every scan |
| `reconcileInsights` | `StartupBackfills.swift:363` | `runInitialScan` :171 | `has_embedding` flag and `memory_insights` vector store diverge permanently after partial/failed embedding writes; never reconciled. | NONE |
| `optimizeFts` | `StartupBackfills.swift:346` | `runInitialScan` :167 | FTS5 index never optimized; query perf degrades as `sessions_fts` grows (currently 82,931 rows). Cosmetic vs correctness. | NONE |
| `vacuumIfNeeded` | `StartupBackfills.swift:351` | `runInitialScan` :168 | DB never auto-VACUUMs; the 544 MB file's freelist never reclaimed after deletes. | NONE |
| `deduplicateFilePaths` | `StartupBackfills.swift:335` | `runInitialScan` :163 | Duplicate `file_path` rows accumulate (now mitigated by `ON CONFLICT(id)` upsert, so impact low). | NONE |
| `backfillScores` | `StartupBackfills.swift:306` | `runInitialScan` :154 | Sessions with `quality_score=0/NULL` from old builds never get scored; but new sessions get scored inline in `SessionSnapshotWriter.computeQualityScore` (:234). | partial — new sessions scored inline |
| `backfillFilePaths` | `StartupBackfills.swift:390` | `runInitialScan` :189 | Old rows missing `file_path` / `session_local_state.local_readable_path` never repaired; affected sessions un-openable. | partial — upsert sets `file_path` inline for new sessions (:197-202) |
| `cleanupStaleMigrations` | `StartupBackfills.swift:428` | `runInitialScan` :246 | Crashed project-move migrations stuck `fs_pending`/`fs_done` >24 h never marked `failed`; `project_recover` / status views show stale in-progress migrations forever. | NONE |
| orphan scan `detectOrphans` | protocol `StartupBackfills.swift:71` | `runInitialScan` :266 | Sessions whose source file was deleted/moved are never flagged orphan/recovered. No production conformer of `StartupOrphanScanning` exists. | NONE |
| `runRecoverableJobs` | protocol `StartupBackfills.swift:66` | `runInitialScan` :286 | **The FTS/embedding backlog (§2) is never drained.** No production conformer. | NONE |
| `backfillInsightEmbeddings` | protocol `StartupBackfills.swift:67` | `runInitialScan` :295 | Text-only insights never promoted to embedded when a provider appears (moot — no Swift embedding provider, feature-C1). | NONE |
| usage collector `start()` | protocol `StartupBackfills.swift:56` | `runInitialScan` :303 | No production conformer of `StartupUsageCollecting`. | NONE |

---

## 4. How the live schema was created; fresh-machine fail-fast analysis

### 4.1 Provenance of the live schema

`EngramDatabaseWriter.init` (`EngramDatabaseWriter.swift:9-16`) only opens a
`DatabasePool` and secures the files — it does **not** migrate. The live DB
already has all tables, so they were created by something other than the
running service. Live `metadata` table:

```
fts_version   | 3
schema_version| 1
detection_version | 4
vec_dimension | 768
pricing_source| node-pricing-table        ← old TS/Node daemon marker
pricing_version | 2026-05-06:model-prices-v1
```

`pricing_source = node-pricing-table` and the historical `completed` job rows
confirm: **the schema was migrated by the old TypeScript/Node daemon (and/or a
prior Swift build that wired `migrate()`), never by the current
`EngramServiceRunner`.** The current service has been free-riding on a
pre-existing schema.

### 4.2 Fresh `~/.engram` scenario (reasoned)

On a clean machine (no `index.sqlite`):

1. `run()` :39-42 creates `~/.engram/` dir.
2. `ServiceWriterGate.init` :50 → `EngramDatabaseWriter(path:)` opens a **new
   empty** SQLite file. No tables, no `metadata`. **No migration runs.**
3. First indexing loop iteration :207 → `indexRecentSessions` → `SwiftIndexer.indexAll`
   → `SessionBatchUpsert.upsertBatch` → `SessionSnapshotWriter.writeAuthoritativeSnapshot`
   → first statement `currentSnapshot`: `SELECT * FROM sessions WHERE id = ?`
   → throws `no such table: sessions`.
4. That error is caught **per-snapshot** in `SessionBatchUpsert.swift:27-36`
   (each item → `.failure`), so the scan does not crash.
5. `SwiftIndexer.indexAll` increments `indexed += batch.count` (`SwiftIndexer.swift:38-39,44-45`)
   **regardless of per-item failure** → reports a non-zero `indexed` count while
   **zero rows were actually written**.
6. The inline `write { db in backfillPolycliProviderParents(db) }` at indexer :54
   then throws `no such table: sessions` from inside `write{}` — this is NOT
   per-item caught, so it propagates → `indexRecentSessions` throws →
   `runIndexingLoop` catch (:221-224) logs "index scan failed" to os_log and
   emits `ServiceIndexErrorEvent`, then loops again in 5 min and fails the same
   way forever.

**Conclusion:** the service does **not** fail-fast on absent schema. On a fresh
machine it (a) reports a misleading non-zero `indexed`, (b) writes nothing, (c)
silently fails every scan. The DB never gets a schema. There is no startup
assertion that `sessions`/`metadata` exist. This is a latent
total-failure-on-fresh-install bug masked on the author's machine by the
legacy-created schema.

---

## 5. MINIMAL CORRECT WIRING

All changes are in `EngramServiceRunner.run()` plus one new production conformer
type. No schema changes required (schema is idempotent, §5.4).

### 5.1 Call `migrate()` exactly once, before the socket opens

`migrate()` is idempotent: `createOrUpdateBaseSchema` uses
`CREATE TABLE IF NOT EXISTS` + `addSessionColumnsIfNeeded`
(`EngramMigrations.swift:7-48`); `FTSRebuildPolicy.apply` is version-gated
(`FTSRebuildPolicy.swift:12`). Safe on fresh and existing DBs.

Expose migrate through the gate (it already holds the only `EngramDatabaseWriter`):

```swift
// ServiceWriterGate.swift — add:
public func migrate() async throws {
    try await writeSemaphore.wait()
    defer { Task { await writeSemaphore.signal() } }   // or signal in do/catch like peers
    try Task.checkCancellation()
    try writer.migrate()
}
```

In `EngramServiceRunner.run()`, immediately after constructing `gate` (:52),
**before** `server.start()`:

```swift
let gate = try ServiceWriterGate(databasePath: databasePath, runtimeDirectory: runtimeDirectory)
try await gate.migrate()   // NEW: fail-fast — if schema can't be created, exit(1) rather than serve a broken DB
```

Failing here is correct: a service that cannot establish schema should not
advertise `ready`.

### 5.2 Run an initial scan + backfill chain once at startup

Add a real conformer set and call `runInitialScan` once, then let the existing
5-min loop continue. Concretely, construct production conformers backed by the
gate's writer. The cleanest minimal approach is a single facade class living in
`EngramService/Core/` (e.g. `ServiceStartupBackfillRunner`) that the writer's
`write{db}` scope satisfies for all six protocols:

- `StartupIndexing` → delegates `indexAll` to `writer.indexAllSessions()` (full
  scan on first start), `backfillCounts`/`backfillCosts` to existing writer
  methods.
- `StartupBackfillDatabase` → each method is a thin `writer.write { db in
  StartupBackfills.<fn>(db) }` wrapper (the static `StartupBackfills.*(db)`
  functions already exist and are unit-tested).
- `StartupIndexJobRunning` → the new job drainer (§5.3).
- `StartupOrphanScanning`, `StartupUsageCollecting`, `StartupBackfillLogging` →
  minimal real implementations (orphan scan can be a no-op-returning stub that
  is honestly documented if `detectOrphans` has no impl yet; logging → os_log).

Ordering in `run()`:

```
gate.migrate()                       // §5.1
server.start()                        // can serve reads immediately
emit ready
Task { runInitialScan(...) once }     // §5.2 — heavy, off the ready path
Task { runIndexingLoop(gate:) }       // existing 5-min loop (now also drains jobs, §5.3)
```

`runInitialScan` must run in its own Task (not before `ready`) so the launcher's
5 s health probe is not delayed by a full scan + 137K-job drain. The indexing
loop and `runInitialScan` both go through `gate.performWriteCommand`, which
serializes them via `writeSemaphore` — no concurrent-writer hazard.

### 5.3 A real `StartupIndexJobRunning` conformer that drains fts/embedding jobs

The FTS job carries only `session_id` + `target_sync_version`; **content must be
regenerated by re-streaming the session's messages from its source file** (the
TS reference `indexSessionContent`, `src/core/db/fts-repo.ts:20-48`, writes one
FTS row per user/assistant message + one for the summary). The drainer:

```
runRecoverableJobs():
  loop in bounded batches (e.g. LIMIT 200, ORDER BY created_at) over
    SELECT id, session_id, job_kind, target_sync_version
    FROM session_index_jobs
    WHERE status IN ('pending','failed_retryable')
  for each fts job:
    1. load session row (file_path, summary, sync_version, tier)
    2. if tier == 'skip' OR sync_version > target_sync_version → mark 'not_applicable'
    3. resolve adapter via SessionAdapterFactory for session.source
    4. re-stream messages: adapter.streamMessages(locator: file_path)
    5. write FTS content (buildSearchContent below) in a single transaction:
         DELETE FROM sessions_fts WHERE session_id = ?
         INSERT one row per qualifying message + one for summary
    6. mark job 'completed'  (on throw: retry_count++, status='failed_retryable',
       last_error; after N retries → 'failed')
  embedding jobs: no Swift provider exists (feature-C1) → mark 'not_applicable'
    with a recorded reason, OR leave pending behind a settings flag. Do NOT
    silently complete them.
```

`buildSearchContent(session)` — the per-message FTS population logic
(mirrors `fts-repo.ts:33-46`), written as multiple `sessions_fts` rows
(per-message granularity is what the existing 82,931 rows use — see live
`SELECT length(content)` returns many short rows per session_id):

```swift
func writeSearchContent(db: Database, sessionId: String,
                        messages: [IndexedMessage], summary: String?) throws {
    try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = ?",
                   arguments: [sessionId])
    let insert = "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)"
    for m in messages where (m.role == .user || m.role == .assistant) {
        let text = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        try db.execute(sql: insert, arguments: [sessionId, text])
    }
    if let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
        try db.execute(sql: insert, arguments: [sessionId, s])
    }
}
```

(Note: round 6 F2 — `EngramServiceReadProvider.swift:340,361` returns
`f.content AS snippet` untruncated. Per-message rows keep individual rows small,
which also relieves the 256 KB frame issue; still truncate the snippet
server-side.)

### 5.4 Draining the existing backlog safely

- The 855 stuck `pending` rows (57 fts + 798 embedding) are drained by the same
  `runRecoverableJobs` on first startup. The 392 non-skip sessions missing FTS
  content are repaired because each has a `pending` fts job (verify:
  `pending fts jobs` ⊇ the missing-content sessions).
- **Bound the work**: process in `LIMIT`ed batches inside separate
  `performWriteCommand` calls so a single transaction never holds the writer for
  minutes (re-streaming 57 sessions' full transcripts is I/O-heavy). Yield
  between batches so incoming write commands and checkpoints interleave.
- **Idempotency**: each fts drain `DELETE`s then re-`INSERT`s, so re-running is
  safe; job id is `"{sessionId}:{syncVersion}:{snapshotHash}:{kind}"` with
  `ON CONFLICT(id) DO UPDATE` (`SessionSnapshotWriter.swift:308`), so re-enqueue
  is also safe.
- For sessions whose source file is gone (orphan), mark the fts job
  `not_applicable` rather than failing forever.

### 5.5 Test that would have caught this (round 6 test meta-gap)

Add an end-to-end test: index a fixture session through the **real**
`EngramServiceRunner` path (or `indexRecentSessions` + the job drainer), then
assert `search("known phrase")` returns it. Today every search test passes
`{}` for vectorStore and never drives the drainer, so the suite stays green
while production search is broken.

---

## 6. Other instances of "built but not wired"

Same pattern, found by enumerating public protocols and grepping their
conformers / public funcs for non-test callers:

1. **`SessionWatcher` (live FS-watch incremental indexing) — NOT WIRED.**
   `EngramCoreWrite/Indexing/SessionWatcher.swift:68`. Instantiated only in
   `EngramCoreTests/Round5RemediationTests.swift` and
   `WatcherSemanticsTests.swift`. Protocols `SessionWatchIndexing` /
   `SessionWatchOrphanMarking` / `WatcherClock` have no production conformer.
   **Consequence:** there is no real-time indexing; new sessions appear only on
   the 5-min poll. CLAUDE.md / settings imply live sync; the watcher exists but
   the runner never starts it.

2. **`NonWatchableSourceRescanner` — NOT WIRED.**
   `NonWatchableSourceRescanner.swift:11`, instantiated only in
   `WatcherSemanticsTests.swift:122`. Its `NonWatchableIndexJobRunning`
   protocol (:7) has no production conformer. **Consequence:** non-watchable
   sources (e.g. SQLite-backed: OpenCode) rely solely on the generic 5-min scan;
   the dedicated rescan-and-drain path is dead.

3. **`StartupOrphanScanning` / `StartupUsageCollecting` — no production
   conformer** (only `RecordingStartup*` in `StartupBackfillTests.swift`).
   Orphan detection and usage collection never run.

4. **`migrate()` family** (`EngramDatabaseWriter.migrate`, `EngramMigrationRunner`,
   `FTSRebuildPolicy`, `EngramMigrations.*`) — production-callable only through
   the CLI dev tool `EngramCoreSchemaTool/main.swift`, never the service.

5. **`indexAllSessions()`** (`EngramDatabaseIndexer.swift:40`) — full-scan
   entrypoint, zero non-test callers; only `indexRecentSessions` runs.

6. **`EngramServiceError.unauthorized`** (round 6 H1) — defined, never thrown:
   a built-but-inert authz surface, same family.

The unifying signature: a protocol or public entrypoint with a complete
unit-test conformer that drives it directly, and a production composition root
that never constructs the conformer. The tests pass; production is inert.

---

## 7. Empirical method / commands used

- `EngramService/main.swift`, `EngramServiceRunner.swift`, `ServiceWriterGate.swift`,
  `EngramDatabaseWriter.swift`, `EngramDatabaseIndexer.swift`,
  `SessionSnapshotWriter.swift`, `SwiftIndexer.swift`, `StartupBackfills.swift`,
  `FTSRebuildPolicy.swift`, `EngramMigrationRunner.swift`, `EngramMigrations.swift`,
  `EngramServiceReadProvider.swift` read in full / in relevant ranges.
- Conformer grep: `StartupIndexJobRunning|StartupIndexing|StartupBackfillDatabase|
  StartupOrphanScanning|StartupUsageCollecting` → all conformers in `*Tests`.
- `migrate()` / `runInitialScan` / `indexRecentSessions` caller grep
  (excluding `/build/`, `*Tests`) → runner :208 sole indexing caller; migrate
  only via schema tool.
- `SessionWatcher(` / `NonWatchableSourceRescanner(` instantiation grep → tests
  only.
- Live DB (`~/.engram/index.sqlite`, 544 MB): job counts by kind/status, job
  `updated_at` ranges (drain stopped 2026-05-20), newest non-skip sessions
  NO-FTS, 392 non-skip sessions without FTS content, 82,931 FTS rows,
  `metadata` keys (`pricing_source=node-pricing-table`).
