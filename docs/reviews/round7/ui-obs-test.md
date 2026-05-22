# Round 7 — Deep Dive: hangs + blind + untested cluster

Date: 2026-05-22. Scope: read-only on product code. Compounding cluster from
round 6 §8 (observability), §9 (UI), §7-H1/H3 + Meta gap (testing). Goal: confirm
mechanisms empirically, design fixes, and design the test that would have caught
V1 (FTS write-path regression).

Severity legend: CRITICAL / HIGH / MEDIUM.

---

## Executive summary

The three round-6 findings are one failure mode wearing three masks:

1. The current runtime never writes FTS content (**V1**) — new sessions are
   unsearchable.
2. Every observability surface that *could* show it is cosmetic or always-green
   (**O1/O2/O3/O4**) — the outage is invisible.
3. No test indexes through the real writer/service and asserts searchability —
   every search test **pre-seeds `sessions_fts` by hand** (`TestHelpers.swift:162`),
   so the suite stays green while production is broken (**Meta gap**).
4. Meanwhile the browser UI runs all of this on the main thread (**ui-C1/C2/H1-H3**),
   so when the DB is large the user gets a *frozen* app with a "No errors" health
   panel.

All five mechanisms confirmed below by source + live DB inspection.

---

## 1. Main-thread blocking — mechanism CONFIRMED

### 1.1 The mechanism

`macos/Engram/Core/Database.swift`:

- `DatabaseManager` is `@MainActor @Observable final class` (line 51-53).
- The pool is `nonisolated(unsafe)` (line 55); read methods are all `nonisolated`.
- `readInBackground` (line 62-65) calls `pool.read(block)` **synchronously and
  returns on the calling thread**:

  ```swift
  nonisolated func readInBackground<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
      guard let pool = pool else { throw DatabaseError.notOpen }
      return try pool.read(block)   // synchronous; runs on whatever thread calls it
  }
  ```

`nonisolated` removes the *compiler's* actor hop, but it does **not** move work
off the caller's thread. When a `@MainActor` view body / `.task` / `onAppear`
closure calls `db.listSessions(...)` directly, the synchronous `pool.read`
executes **on the main thread**. It compiles, looks async (the enclosing func is
`async`), runs fine on a tiny dev DB, and freezes the UI on the real 544 MB DB.

The correct pattern is `HomeView.loadData` (HomeView.swift:189-219): capture
`let db = self.db`, then run all reads inside `try await Task.detached { ... }.value`
so the synchronous `pool.read` runs on a background executor; assign results back
on the MainActor.

### 1.2 Every offending call site (CONFIRMED — `Task.detached` count = 0 in each)

| View | File:line | DB calls on main thread | Trigger |
|---|---|---|---|
| **SessionListView** (worst) | SessionListView.swift:316-345 | `countHiddenSessions`, `listSessions(limit:2000)`, `childCount`, `suggestedChildCount`, `listFavorites` | `.task`, filter `onChange` (×4), favorite/rename/delete |
| **ReposView** | ReposView.swift:79 + :82 | `listGitRepos` + per-repo `sparklineData` (N+1) | `.task` |
| **WorkGraphView** | WorkGraphView.swift:72 | `listGitRepos` | `.task` |
| **RepoDetailView** | RepoDetailView.swift:136 | `listSessionsForProject` | `.task` |
| **ActivityView** | ActivityView.swift:50-56 | `dailyActivity`, `hourlyActivity`, `sourceDistribution`, `countSessionsSince` ×2 (5 sequential) | `.task` |
| **ProjectsView** | ProjectsView.swift:219 | `listSessionsByProject` (fetches `limit*10` rows) | `.task` + `projectsDidChange` notification |
| **AgentsView** | AgentsView.swift:49 | `listSessions(subAgent:true, limit:200)` | `.task` |
| **SourcePulseView** | SourcePulseView.swift:120 + :124 | `sourceDistribution` (twice — empty-catch fallback re-read) | `.task` |
| **ErrorDashboardView** | ErrorDashboardView.swift:92-94 | `countErrors24h`, `errorsByModule24h`, `recentErrors` | `.task` + **30 s timer** |
| **TraceExplorerView** | TraceExplorerView.swift:141 | `fetchTraces` | `.task` + **30 s timer** + **every keystroke** (`onChange(nameFilter)`, line 134) |
| **PerformanceView** | PerformanceView.swift:93-94 | `slowTraces`, `recentHourlyMetrics` | `.task` + **30 s timer** |
| **SystemHealthView** | SystemHealthView.swift:70-72 | `dbSizeBytes`, `observabilityTableCounts` | `.task` + **30 s timer** |

No previously-missed views found. Confirmed-correct (already off-main): HomeView,
SessionsPageView, TimelinePageView, SessionDetailView, PopoverView (all use
`Task.detached`); SearchPageView uses `serviceClient.search` (off-main IPC);
LogStreamView uses GRDB `ValueObservation.start(in: pool)` (off-main by design).

### 1.3 Worst case — SessionListView blocking estimate

On every `.task` / filter change / favorite / rename / delete, on the main thread:

1. `countHiddenSessions` — full `COUNT(*)` over `sessions`.
2. `listSessions(limit:2000)` — fetch up to **2000 rows** + GRDB `Session`
   row→struct decoding (≈25 columns each).
3. `childCount(parentIds:)` — `... WHERE parent_session_id IN (≤2000 placeholders) GROUP BY` (one SQLite statement with up to 2000 bound params).
4. `suggestedChildCount(parentIds:)` — same shape again.
5. `updateFilteredSessions()` (SessionListView.swift:59-76) — MainActor:
   two `Dictionary(grouping:)` passes over 2000 rows + `sorted(using:)`.

That is ~4 large synchronous reads + 2000-element decode + O(n log n) sort, all
on the main thread, **re-run on every favorite toggle / source filter / sort
change**. On the 544 MB / 11.4 k-session DB this is multi-hundred-ms to
multi-second beachballing per interaction.

### 1.4 Fix pattern

Mirror `HomeView.loadData`. For SessionListView, wrap the DB portion of
`loadSessions()`:

```swift
private func loadSessions() async {
    let db = self.db
    let showingTrash = self.showingTrash
    let agentFilter = self.agentFilter
    let useTopLevel = agentFilterMode != 1
    do {
        let loaded = try await Task.detached {
            let hidden = (try? db.countHiddenSessions()) ?? 0
            let sessions = showingTrash
                ? ((try? db.listHiddenSessions(limit: 500)) ?? [])
                : try db.listSessions(subAgent: agentFilter, topLevelOnly: useTopLevel, limit: 2000)
            let ids = sessions.map(\.id)
            let confirmed = (try? db.childCount(parentIds: ids)) ?? [:]
            let suggested = (try? db.suggestedChildCount(parentIds: ids)) ?? [:]
            return (hidden, sessions, confirmed, suggested)
        }.value
        hiddenCount = loaded.0
        sessions = loaded.1
        confirmedCounts = loaded.2
        suggestedCounts = loaded.3
        // refresh cached selection on MainActor
    } catch {
        EngramLogger.error("SessionListView load failed", module: .ui, error: error)
        sessions = []
    }
}
```

`updateFilteredSessions()` (pure in-memory transform on already-loaded `sessions`)
may stay on the MainActor for small result sets, but for 2000 rows the grouping +
sort should also move into the detached block and return precomputed
`filteredSessions` / `sourceCounts` / `projectList`.

Apply the same `let db = self.db; try await Task.detached { ... }.value` wrapper
to every call site in §1.2. For ReposView's N+1 sparkline fan-out, do the
`listGitRepos` + all per-repo `sparklineData` reads inside one detached block.
For the four timer-driven observability views, the wrap also fixes the 30 s
re-block; for TraceExplorer it fixes the per-keystroke re-block (additionally
debounce `nameFilter`).

---

## 2. Observability cosmetic views (O1) — CONFIRMED

Grep for `INSERT INTO logs|traces|metrics` (`--include=*.swift`, excluding build)
returns **zero non-test hits**. The only writers are
`EngramCoreTests/Database/MigrationRunnerTests.swift` and
`EngramTests/TestHelpers.swift` (a test seeder). Production Swift logs only via
`EngramLogger` (os_log, subsystem `com.engram.app`, EngramLogger.swift) and
`ServiceLogger` (os_log, subsystem `com.engram.service`). Nothing ever populates
`logs` / `traces` / `metrics` / `metrics_hourly`.

Consequence: LogStreamView, ErrorDashboardView, TraceExplorerView, PerformanceView,
and SystemHealthView's table counts read tables that the current runtime never
fills. They show empty/"No errors" forever — including during the V1 outage.

### Option A — os_log → DB sink

Add a `LogSink` to `EngramLogger`/`ServiceLogger` that, in addition to `os_log`,
writes a row to `logs` (and span rows to `traces` for instrumented operations)
through the writer gate. Service-side: route through `ServiceWriterGate`
(`logs`/`traces` are writer-owned, same lock); app-side UI logs would have to be
forwarded to the service (the app DB handle is read-only — Database.swift:74).

- Pro: the existing views work unchanged; durable history; queryable by module.
- Con: new write volume + retention/rotation policy; app→service log forwarding
  channel; another writer path to keep correct; ironically depends on the same
  composition root that V1/V2 showed is unreliable.

### Option B — repoint the 5 views at `OSLogStore`

Replace the `logs`/`traces`/`metrics` reads with
`OSLogStore.local()` queried by `subsystem IN ('com.engram.app','com.engram.service')`,
mapping `OSLogEntryLog.level` → the view's level filter, `category` → module,
`composedMessage` → message, `date` → ts. PerformanceView/TraceExplorer can
derive simple durations from paired begin/end log lines or from `signpost`
intervals if added later.

- Pro: **shows what the runtime already emits today** (both subsystems already
  log richly, including `index scan failed` and checkpoint failures); zero new
  write path; no retention to manage (the unified log handles it); immediately
  surfaces real incidents.
- Con: `OSLogStore.local()` needs the right entitlement/permission and only
  retains per the system log budget; no custom `trace`/`metric` schema (would
  need signposts); query latency on large stores (run off-main — see §1).

### Recommendation: **Option B**, with a thin Option-A follow-up only for metrics.

Rationale: the dominant defect is *blindness during an incident*. Option B makes
the views truthful immediately using data the runtime already produces, and does
not add yet another write path through the composition root that round 6 proved
is the systemic weak point. Reserve a minimal Option-A sink **only** for
aggregate `metrics_hourly` (counters/durations that os_log does not model well),
written service-side through the gate. Charts (PerformanceView) can then read
metrics from DB while logs/errors/traces read the unified log.

---

## 3. Status blindness (O2) — CONFIRMED + design

### Confirmed mechanism

`EngramServiceCommandHandler.handle` `case "status"`
(EngramServiceCommandHandler.swift:21-28) does:

```swift
let status = try await writerGate.indexStatus()   // just a COUNT(*) + today-parents COUNT
return .success(... EngramServiceStatus.running(total: status.total, todayParents: status.todayParents))
```

So `status` returns `.running` whenever the COUNT succeeds — regardless of
whether the last index scan failed. The scan failure path
(`EngramServiceRunner.runIndexingLoop`, runner.swift:219-224) emits a
`ServiceIndexErrorEvent(event:"index_error", error:...)` to **stdout + os_log
only**. Worse: the app's `EngramServiceStatusStore.apply(event:)`
(EngramServiceStatusStore.swift:46-71) has **no case for `"index_error"`** →
falls into `default: break`. And the polled status stream
(`UnixSocketEngramServiceTransport.events`, line 59-69) calls the `status`
command, which can only ever say `.running`. Both the event channel and the poll
channel are blind to scan failure. `.degraded(message:)` exists in the enum
(EngramServiceModels.swift) but is only ever produced for *web-UI* errors, never
indexing.

### Design — service-side last-scan-outcome tracking

1. **Track outcome in the runner.** Add an actor (or `ServiceWriterGate`-owned
   value) `IndexScanState`:
   ```swift
   struct IndexScanOutcome: Sendable {
       var lastSuccessAt: Date?
       var lastAttemptAt: Date?
       var lastIndexedCount: Int?
       var lastError: String?   // nil = last scan ok
   }
   ```
   In `runIndexingLoop`, on success set `lastSuccessAt = now`, `lastError = nil`,
   `lastIndexedCount = result.value.indexed`; in the `catch` set
   `lastError = error.localizedDescription`, `lastAttemptAt = now` (keep prior
   `lastSuccessAt`). Persist a copy in a tiny `service_state` row so a freshly
   restarted service can report staleness too.

2. **Make `status` consult it.** In `case "status"`, after computing the COUNT,
   read the outcome and apply an SLA:
   ```swift
   let outcome = await scanState.current()
   let slaSeconds = 30 * 60   // 6× the 5-min scan interval
   if let err = outcome.lastError {
       return .success(... .degraded(message: "Last index scan failed: \(err)"))
   }
   if let last = outcome.lastSuccessAt, Date().timeIntervalSince(last) > slaSeconds {
       return .success(... .degraded(message: "No successful index scan in \(Int(age/60)) min"))
   }
   return .success(... .running(total:, todayParents:))
   ```
   (Surface the *real* error message guardedly — strip paths/SQL per round-6
   sec-M2.)

3. **Wire the event store.** Add `case "index_error":` to
   `EngramServiceStatusStore.apply(event:)` → `status = .degraded(message:)`, and
   add an `"index_ok"` event on recovery that clears it. This fixes the push
   channel; step 2 fixes the poll channel.

4. **App surfacing.** `displayString` already renders
   `"Degraded: <message>"` for `.degraded`. Menu bar: show a warning glyph +
   degraded text when `!isRunning && status is .degraded`. SystemHealthView: add
   a real "Index scan" row driven by the status store
   (`lastSuccessAt`, `lastError`) instead of the hardcoded "WAL Mode: OK"
   (round-6 ui-M4 / O6) — this is the natural home for the SLA indicator.

---

## 4. Per-session parse failure (O3) + whole-scan abort (O4) — CONFIRMED + design

### Confirmed mechanism

`SwiftIndexer.scanSnapshots` (SwiftIndexer.swift:82-106):

```swift
for adapter in adapters {
    ...
    for locator in try await adapter.listSessionLocators() {
        switch try await adapter.parseSessionInfo(locator: locator) {
        case .failure:
            continue                       // O3: ParserFailure reason DISCARDED
        case .success(var info):
            let stats = try await streamStats(...)   // O4: throws abort whole scan
            yield(buildSnapshot(...))
        }
    }
}
```

- **O3**: `case .failure: continue` throws away the `ParserFailure` payload
  (`ParserFailure` enum, SessionAdapter.swift:179-194 — 14 categories incl.
  `truncatedJSONL`, `malformedJSON`, `sqliteUnreadable`). "Session X isn't
  showing up" is undiagnosable.
- **O4**: any `throws` from `listSessionLocators`, `parseSessionInfo`, or
  `streamStats` propagates out of `scanSnapshots` →
  `streamSnapshots`'s `continuation.finish(throwing: error)` (line 73) → the
  `for try await` in `indexAll` rethrows → `indexRecentSessions` throws →
  `runIndexingLoop` logs "index scan failed" and **the whole scan is abandoned**.
  Every adapter/session ordered after the bad one is silently skipped.

### Design — collect-and-continue + failure-count surfacing

1. **Log the failure with reason + locator** (fixes O3):
   ```swift
   case .failure(let reason):
       ServiceLogger.warn("parse failed: source=\(adapter.source.rawValue) locator=\(locator) reason=\(reason.rawValue)", category: .indexer)
       scanFailures.append(.init(source: adapter.source, locator: locator, reason: reason.rawValue))
       continue
   ```

2. **Isolate per-session/adapter errors** (fixes O4): wrap each session's
   parse+stream in `do/catch` so a thrown error becomes a recorded failure, not
   an abort:
   ```swift
   for locator in (try? await adapter.listSessionLocators()) ?? [] {
       try Task.checkCancellation()        // cancellation still propagates
       do {
           switch try await adapter.parseSessionInfo(locator: locator) { ... }
       } catch is CancellationError {
           throw CancellationError()
       } catch {
           ServiceLogger.warn("index error: source=\(adapter.source.rawValue) locator=\(locator) error=\(error.localizedDescription)", category: .indexer)
           scanFailures.append(.init(source: adapter.source, locator: locator, reason: "thrown:\(error)"))
           continue
       }
   }
   ```
   Wrap `listSessionLocators()` / `detect()` failures per-adapter the same way so
   one broken source cannot kill the scan. `Task.checkCancellation()` must still
   `throw` to preserve teardown.

3. **Surface the failure count.** Extend `EngramDatabaseIndexResult` with
   `failedCount: Int` (+ optionally a capped `[ScanFailure]`). Plumb it through
   `indexRecentSessions` → `runIndexingLoop`'s success log
   (`indexed=… failed=…`) and into the §3 `IndexScanOutcome`
   (`lastFailedCount`). When `failedCount > 0` (or exceeds a threshold), the
   `status` command returns `.degraded("N sessions failed to index")`. This makes
   partial-failure visible without aborting the good 99%.

---

## 5. a11y theater (H4) — CONFIRMED + design

Counts (`macos/Engram`, `--include=*.swift`): **112 `accessibilityIdentifier`**,
**5 `accessibilityLabel`**, **0 `accessibilityValue`**. Identifiers are XCUITest
selectors, not VoiceOver content — they satisfy the UI test suite while leaving
the app unusable with VoiceOver. The data-viz components have effectively no
semantic exposure:

- `KPICard.swift` — 0 a11y; VStack of value+label read as two disconnected strings.
- `HeatmapGrid.swift` — 0 a11y; 24 colored rectangles, no per-hour meaning.
- `TierBar.swift` — 0 a11y; proportional bar segments invisible.
- `SparklineView.swift` — 0 a11y; 7 bars, pure decoration to VoiceOver.
- `WorkGraphView.swift` — only `accessibilityIdentifier("workGraph_container")` (a test hook, not a label).

### Design — real labels/values (combine children + describe data)

- **KPICard**: `.accessibilityElement(children: .ignore)` +
  `.accessibilityLabel(label)` + `.accessibilityValue(delta == nil ? value : "\(value), \(deltaPositive ? "up" : "down") \(delta!)")`.
- **HeatmapGrid**: `.accessibilityElement(children: .ignore)` +
  `.accessibilityLabel("Activity by hour")` +
  `.accessibilityValue(data.enumerated().filter{$0.element>0}.map{"\(hourName($0.offset)): \($0.element)"}.joined(separator: ", "))`;
  optionally make peak hour an `.accessibilityValue` summary.
- **TierBar**: `.accessibilityElement(children: .ignore)` +
  `.accessibilityLabel("Session tiers")` +
  `.accessibilityValue("premium \(premium), normal \(normal), lite \(lite), skip \(skip)")`.
- **SparklineView**: `.accessibilityElement(children: .ignore)` +
  `.accessibilityLabel("7-day activity")` +
  `.accessibilityValue("\(values.map(String.init).joined(separator: ", ")); latest \(values.last ?? 0)")`.
- **WorkGraphView**: keep the identifier, add `.accessibilityLabel` +
  `.accessibilityValue` summarizing repo/edge counts; expose node rows as
  labeled elements.

Add a `chartAccessibility(label:value:)` `ViewModifier` so all five share one
implementation, and add an a11y-audit test that asserts each chart exposes a
non-empty label+value (so this can't silently regress to identifier-only again).

---

## 6. THE KEY TEST — end-to-end real-writer searchability (would have caught V1)

### Why the current suite stayed green

- **Search tests pre-seed FTS by hand.** `EngramTests/TestHelpers.swift:162-169`
  exposes a helper that does `INSERT INTO sessions_fts (session_id, content)`
  directly. `DatabaseManagerTests` search cases call it, so `db.search(...)`
  finds rows that **were never written by the product path**.
- **Indexer tests assert the *job*, not the *content*.**
  `IndexerParityTests.testSessionSnapshotWriterPersistsSnapshotCostsAndJobsThenNoops`
  (lines 96-112) asserts `session_index_jobs.job_kind == ["embedding","fts"]` —
  i.e. that a fts *job was enqueued* — and never asserts a `sessions_fts.content`
  row exists or that `search()` returns the session.
  `SessionSnapshotWriter` (SessionSnapshotWriter.swift:332) only **DELETEs**
  `sessions_fts` and enqueues the job (line 304); it never writes content.
- **The job consumer is never driven in production.** `runInitialScan`
  (StartupBackfills.swift:123) takes a `StartupIndexJobRunning` to drain fts
  jobs, but `EngramServiceRunner` calls only `writer.indexRecentSessions()`
  (runner.swift:207-208), never `runInitialScan`. Grep for non-test
  `StartupIndexJobRunning` conformers / `runInitialScan` callers in
  `EngramService` = **zero**. So no production code path ever turns the fts job
  into fts content.
- **No test ever runs the whole chain** (real adapter fixture → real
  `EngramDatabaseWriter`/`ServiceWriterGate` → reader `search`). Every layer is
  tested in isolation against pre-seeded state, masking the composition-root gap.

### Live confirmation

`sqlite3 -readonly ~/.engram/index.sqlite`:
- pending `fts` jobs (`job_kind='fts' AND status='pending'`): **57** (never drained).
- searchable-tier sessions (`tier NOT IN ('skip','lite')`, not hidden) with **no**
  `sessions_fts` content row: **340**.
- `sessions_fts` is `CREATE VIRTUAL TABLE ... USING fts5(session_id UNINDEXED,
  content, tokenize='trigram ...')` — **standalone**, no external-content, no
  sync triggers. Nothing keeps it in sync but explicit content writes that don't
  exist.

### Test design (the one that fails today, red→green only after V1 is fixed)

Place in `EngramServiceTests` (preferred, exercises the gate) or
`EngramCoreTests`. It must **not** touch `sessions_fts` directly — it drives the
real write path end-to-end and queries through the reader:

```swift
func testIndexedSessionIsKeywordSearchableThroughRealWritePath() async throws {
    // 1. Fresh temp DB through the REAL schema/migrations (no pre-seeded FTS).
    let dbPath = makeTempDBPath()
    let gate = try ServiceWriterGate(databasePath: dbPath, runtimeDirectory: tmpDir)

    // 2. Real adapter over a real fixture containing a unique sentinel token.
    //    Use a fixture whose transcript contains e.g. "ZZQXSEARCHTOKEN".
    let adapter = ClaudeCodeAdapter(root: fixtureRoot)   // points at tests/fixtures/...

    // 3. Index through the SAME entry point the service uses.
    let result = try await gate.performWriteCommand(name: "indexRecent") { writer in
        try await writer.indexRecentSessions(adapters: [adapter])
    }
    XCTAssertGreaterThan(result.value.indexed, 0)

    // 4. CRITICAL post-condition the suite never checks: FTS CONTENT exists.
    let reader = SQLiteEngramServiceReadProvider(databasePath: dbPath)
    let hits = try await reader.search(.init(query: "ZZQXSEARCHTOKEN", limit: 10))
    XCTAssertFalse(hits.items.isEmpty,
        "Session indexed via the real writer must be keyword-searchable; \
         empty result means FTS content was never written (V1 regression).")

    // 5. Belt-and-suspenders: assert content row exists and no fts job is left pending.
    try gate.readForTest { db in
        let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE content LIKE '%ZZQXSEARCHTOKEN%'") ?? 0
        XCTAssertGreaterThan(n, 0, "sessions_fts.content not written by product path")
        let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE job_kind='fts' AND status='pending'") ?? 0
        XCTAssertEqual(pending, 0, "fts jobs enqueued but never drained")
    }
}
```

Today this fails at step 4/5: `indexRecentSessions` enqueues an fts job but
nothing writes content, so `search` returns empty and the pending-job count is
nonzero. It goes green only once the runtime actually drains fts jobs into
`sessions_fts.content` (the V1 fix). This is the single test that converts the
composition-root gap from invisible to CI-blocking.

A second, cheaper guard (regression net for O4): feed `indexAll` an adapter list
where one adapter throws and a later one yields a known session; assert the later
session is still indexed (proves collect-and-continue).

---

## Confirmation method

Source: `Database.swift` (read-method/`readInBackground` mechanism, all
observability reads), all 12 view files (`Task.detached` count = 0,
`db.<method>` call sites, `.task`/timer/`onChange` triggers),
`EngramServiceRunner.swift` (indexing loop only calls `indexRecentSessions`,
emits index_error to stdout only), `EngramServiceCommandHandler.swift` (status =
always `.running`), `EngramServiceStatusStore.swift` (no `index_error` case),
`SwiftIndexer.swift:82-106` (O3 `continue`, O4 throw-abort), `SessionAdapter.swift`
(`ParserFailure` 14 cases), `SessionSnapshotWriter.swift` (FTS DELETE + job
enqueue, no content write), `StartupBackfills.swift` (`runInitialScan` only
caller of fts job runner; never wired), `IndexerParityTests.swift` /
`TestHelpers.swift` (pre-seeded FTS, job-only assertions), the 5 chart components
(a11y), and a11y modifier counts (112/5/0). Live DB
(`sqlite3 -readonly ~/.engram/index.sqlite`): 57 pending fts jobs, 340 NO-FTS
searchable sessions, standalone fts5 schema with no sync triggers.

Note: round 6 reported 137,628 pending jobs; the live count is now 57 pending
*fts* jobs (other kinds/statuses may differ, or a prior cleanup ran). The
qualitative finding is unchanged — jobs are enqueued and never drained to FTS
content, and 340 searchable sessions remain unsearchable.
