# Design Doc: Service Resilience — Reachable Recovery, Last-Good Holds, Parse-Failure Surfacing, Manual Scan + Currency

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog rows **5** (Q3),
  **9** (Q2), **12** (F6), **25** (F11). Composes with the accepted
  `docs/source-health-predicate-design-2026-07.md` (row 2) on the shared
  `EngramServiceSourceInfo` DTO and `SourcePulseView` chip row. Sibling mirror
  specs: `docs/insight-supersede-filter-design-2026-07.md` (row 1),
  `docs/codex-native-parentage-design-2026-07.md` (row 22),
  `docs/adapter-format-drift-design-2026-07.md` (row 23).
  **Also co-edits two files with `docs/mcp-cost-honesty-design-2026-07.md`
  (rows 3/4, integration pass 2026-07-25):** `MCPDatabase.swift` (this spec's
  `stats` emitter `:123-146` and search `:2196-2218` vs. cost's `getCosts`
  `:231-272` and un-`private` `contextNow` `:2540`) and
  `EngramServiceReadProvider.swift` (this spec's `sources()` `:1009-1058` and
  `keywordSearch` `:591-630` vs. cost's `costs()` `:1140-1203`) — all distinct
  methods, a text-level merge. Both inherit the non-reentrant `queue.read` trap
  and hoist probes/aggregates inside the one open `db` closure; see the reciprocal
  note in that spec's "Cross-spec coordination".

All code citations are at **HEAD `23dca547`** on branch
`docs/mirror-followup-specs`, verified by opening each file. Concurrent
implementation of the accepted baseline specs will drift line numbers; that is
expected. Measured corpus figures are read read-only from `~/.engram/index.sqlite`
on 2026-07-24 and are evidence, not invariants.

This bundle has one theme — when the service, a poll, or a parse fails, the app
must say so, offer recovery, and let the user (or an agent) force a refresh —
split into four **independently landable** parts. A reader implementing only one
part can ignore the other three safely.

## Problem

**Row 5 — the one-click recovery is unreachable.** `.restartService` is declared
(`macos/Engram/AppNotifications.swift:8`), observed (`App.swift:154-158`),
dispatched (`:157`) and implemented (`:225`), and a source comment at
`App.swift:151-152` claims two UI surfaces post it. A repo-wide grep returns five
references and **zero posters**: nothing in the app ever posts the notification,
so the handler cannot fire. When the launcher exhausts its 3-restart budget
(`EngramServiceLauncher.swift:241`, `maxRestarts` default 3) it emits `.degraded`
and stops spawning restarts; a service wedged past that point cannot be recovered
except by quitting the whole app. The primary real-world trigger is
`index_error`, which `App.applyServiceEvent` maps to `.degraded`
(`App.swift:250-258`).

**Row 9 — a failed poll renders as "nothing is running".** Three call sites blank
a live indicator on a single IPC exception, so a broken service is
indistinguishable from an idle machine: `SourcePulseView.loadLiveSessions`
sets `liveSessions = []` on `catch` (`:126`) and the entire Live section is gated
`if !liveSessions.isEmpty` (`:65`) — the section vanishes; `PopoverView`'s
`(try? … ) ?? []` (`:270-272`) collapses failure and genuine-empty into one
state; `MenuBarController.updateBadge`'s `catch` drops the live dot (`:437`). The
"hard half" already ships: `ServiceDataFreshness { live / stale(asOf:) / expired }`
with a 30-minute TTL (`EngramServiceStatusStore.swift:21-25`, `:36`, `:69-74`) —
but it measures the **status-poll** channel, not the live-session list, so it
cannot be reused verbatim (see Current state).

**Row 12 — recorded parse failures are never read.** `file_index_state` persists
`parse_status` and `failure_kind` per file (`EngramMigrations.swift:163-180`),
written on every `ParserFailure` (`IndexingWriteSink.swift:186-214`), and no
source-health read path reads it. Measured on the corpus: **35,062** files `ok`,
**529** `retry`, **754** `terminal` — 1,283 recorded parse failures, zero
surfaced. The distribution is the whole design problem: **693 of the 754 terminal
rows (92%) are `noVisibleMessages`** on `claude-code` — legitimately empty
transcripts, a by-design outcome. A naive `failure_kind IS NOT NULL` count would
render `claude-code` at 965 permanently — the exact "render a by-design exclusion
as degradation" anti-pattern that row 2 exists to remove.

**Row 25 — no manual scan, and search serves known-stale results silently.** No
manual scan trigger exists: 73 service commands, and `triggerSync`
(`EngramServiceCommandHandler.swift:1483-1495`) is a peer-sync stub that returns
`"Sync is not implemented in the Swift service"`, not a local-scan lever. The
background scan is 15–60 min with no file watcher
(`IndexingSchedulePolicy.swift:32-35`), and both search paths are
FTS-authoritative with no freshness check
(`EngramServiceReadProvider.swift:591-630`; `MCPDatabase.swift:2196-2218`). An
agent that just wrote a session, or a user who just closed one, gets stale or
missing results until the next scheduled scan, with nothing telling them so and
no way to force a refresh — least of all an MCP agent, who cannot press a
Settings button.

## Goals / Non-goals

**Row 5.** Goal: a `.error`/`.degraded` service is recoverable from the UI in one
click, from the HomeView Service State section and the menu-bar right-click menu,
reusing the single existing restart sequencing point. Non-goal: a typed
remediation ladder (`AuthRemediationBanner`-style) — one real call site does not
justify an abstraction; the popover as a poster site (its status chrome removal is
test-pinned).

**Row 9.** Goal: a failed live poll holds the last-good list, captions it with its
age, and degrades to an explicit "unavailable" state only past the existing 30-min
TTL. Non-goal: inventing a freshness vocabulary parallel to `ServiceDataFreshness`;
changing the status-poll channel; making a successful poll that returns zero
sessions look like a failure.

**Row 12.** Goal: surface a per-source count of genuine parse failures on the
source DTO + a `SourcePulseView` chip + an MCP `stats` field, so a user or agent
can tell its memory is incomplete. Non-goal: a new table or migration
(`file_index_state` already exists); feeding the health ladder that row 2 is
concurrently rewriting; catching record-kind drift that still parses as valid JSON
(that is row 23's adapter-side counter); distinguishing benign empties from a
`noVisibleMessages` surge (impossible from a point-in-time count — see Risks).

**Row 25.** Goal: a `scanNow` service command, reachable from both the app and an
MCP tool, that runs one index cycle immediately; and a currency-aware search read
that annotates each result as fresh / stale / reclaimed by stat-ing its source
file. Non-goal: a file watcher; withholding stale results (that blanks valid data
— annotate, then let `scanNow` fix); a three-surface UI coordinator.

## Current state

### Row 5 — restart wiring

- **Zero posters, false comment.** `App.swift:151-152` asserts "WP09's menu-bar
  item / Service-State banner post `.restartService` when status is
  `.error`/`.degraded`." No such poster exists. Line `:153` ("Gated on
  autoStartService…") is accurate and describes real behaviour: the observer is
  registered inside the `if environment.autoStartService` block.
- **The restart path is complete and single.** `App.restartService`
  (`:224-242`) flips the store to `.starting` then calls
  `serviceLauncher.restart(configuration:statusProbe:onStatus:onEvent:)`, reusing
  the exact closures built at first launch; it does **not** re-implement
  start+monitor. `EngramServiceLauncher.restart` (`:278-296`) stops the old helper,
  re-`start`s, re-arms the health monitor, and surfaces `.error(message:)` if
  `start()` throws (`:294`).
- **Correction to the mirror/brief framing: `.degraded` is not a permanent
  latch.** After the restart budget is spent, the else branch
  (`EngramServiceLauncher.swift:258-266`) sets `.degraded` but the monitor
  **keeps probing with capped backoff** (comment `:259-261`: "keep the monitor
  alive … recover without requiring an app relaunch"); a later successful probe
  resets `restartAttempts = 0` and calls `onStatus(.running)` (`:224-230`),
  clearing `.degraded`. It only stops *spawning restarts*. Row 5's value is
  escaping a service that cannot self-recover — a genuinely wedged helper — not
  breaking a hard latch. State this precisely; do not claim permanence.
- **Poster sites.** HomeView `serviceStateSection` (`HomeView.swift:256-276`) is a
  `WorkbenchPanel` holding two `ServiceStateRow` instances (Indexer `:261-266`,
  Today indexed `:267-272`). `ServiceStateRow` (`:658-684`) is a non-interactive
  `HStack` with no button, tap, or callback. The menu-bar right-click menu is
  built fresh on every open in `showContextMenu` (`MenuBarController.swift:176-197`)
  as a plain `NSMenu` (Open Window / Settings / separator / Quit), each item using
  `#selector` + `target = self`, torn down in `menuDidClose` (`:200-202`).
- **Gating state.** Failure cases are `.degraded(message:)` / `.error(message:)`
  (`EngramServiceModels.swift:52-53`). `EngramServiceStatusStore` exposes only
  `isRunning` (`:60-63`); there is no `isFailed`/`isDegraded` helper.
- **Test substrate.** `HomePopoverActionsTests` are source-inspection guards:
  they read the `.swift` file as a `String` and assert substring presence/absence
  via helpers `homeView()`, `popoverView()`, `menuBarController()`
  (`HomePopoverActionsTests.swift:18-36`).
  `testPopoverDropsTechnicalChromeKeepsSessionContent` forbids only the **literal**
  `popover_status_web` (`HomePopoverActionsTests.swift:233`) — a "Restart Service"
  button would not contain that string, so this existing pin does **not** by itself
  catch a restart control in the popover. Part A's new
  `testPopoverDoesNotPostRestartService` (below) is what enforces the popover
  exclusion. The HomeView and menu-bar guards forbid only Web-UI strings
  (`openWebUI`, `"Web UI"`), which restart strings do not collide with.

### Row 9 — live-poll blanking and freshness

- **Three blank-on-catch sites:** `SourcePulseView.swift:65,121-128` (section
  gated, `catch { liveSessions = [] }`, error swallowed — the `:73` banner is for
  `loadData`, not the live poll); `PopoverView.swift:263-266,270-272`
  (documented-intentional silent-fail, `?? []` collapses failure and empty);
  `MenuBarController.swift:427-439` (dot glyph `\u{25CF}` on success `:434`, `catch`
  keeps the today count but drops the dot `:437`).
- **`ServiceDataFreshness` measures the wrong clock for the live list.**
  `dataFreshness(now:)` (`EngramServiceStatusStore.swift:69-74`) is derived from
  `isRunning` + `lastEventAt`; `lastEventAt` is bumped only by `store.apply(status/
  event/refresh)` (`:77`, `:92`), i.e. the status-poll and stdout channels. All
  three live polls call `serviceClient.liveSessions()` directly and **never** call
  `store.apply`, so a failed live poll while the service is still `.running` would
  report `.live`. The `ServiceDataFreshness` **type** and 30-min TTL are reusable;
  the **timestamp** is not — the live list needs its own clock.
- **`asOfText` is not a shared symbol.** It is duplicated privately in
  `HomeView.swift:343-345` and `PopoverView.swift:295-297`, each with its own
  formatter, and absent from `SourcePulseView`/`MenuBarController`. "Reuse
  `asOfText`" as written points at a symbol that does not exist at two of the three
  row-9 sites.

### Row 12 — parse-failure recording

- **DTO shape.** `EngramServiceSourceInfo` (`EngramServiceModels.swift:467-568`)
  is `Codable, Equatable, Identifiable, Sendable` with a hand-written init,
  `CodingKeys`, and `init(from:)`. Every additive field needs **five** edit points
  (`liveSyncDisabled` is the precedent: `:488`, `:507`, `:525`, `:545`, `:566`);
  miss the memberwise-body assignment and it does not compile. Row 2 adds
  `healthReason` here; row 12's field extends the same shape after it.
- **The signal is unread on the health path.** `sources()`
  (`EngramServiceReadProvider.swift:1009-1058`) reads `sourceSearchableCounts`
  (`:1696-1706`), `sourceFailedIndexJobCounts` (`:1708-1726`), token/cost/usage —
  never `file_index_state`. `failedIndexJobCount` is a **different signal**: it
  counts `session_index_jobs` rows (per-session fts/embedding job failures), not
  per-file parse failures. Naming must keep them distinct.
- **Schema.** `file_index_state` (`EngramMigrations.swift:163-180`) is keyed by
  `(source, locator)` with `parse_status TEXT CHECK IN ('ok','terminal','retry')`
  and nullable `failure_kind`. A per-source count is a plain `GROUP BY source`,
  guarded by `tableExists`.
- **Failure kinds and benignity.** `ParserFailure` has 15 cases
  (`SessionAdapter.swift:197-214`); the terminal set is `{fileTooLarge,
  messageLimitExceeded, lineTooLarge, unsupportedVirtualLocator, noVisibleMessages}`
  (`IndexingWriteSink.swift:228-235`), all of which are **by-design**: size/line
  caps (a deliberate Wave 7A L05 decision), virtual/`sync://` locators, and empty
  transcripts. Failure writes set `parse_status = 'terminal'|'retry'` and
  `failure_kind = ParserFailure.rawValue` (`:194-213`).
- **Measured distribution (2026-07-24).** `parse_status`: ok 35,062, retry 529,
  terminal 754. Non-`ok` by kind: `noVisibleMessages` 693 (claude-code) + 8 (qwen)
  + 5 (vscode) = 706 terminal, benign; `malformedJSON` 262 (claude-code) + 170
  (codex) + 44 (glm) + … = the entire `retry` set (529), transient; the remaining
  terminal rows are size caps (`messageLimitExceeded` 27, `fileTooLarge` 17,
  `lineTooLarge` 6). **No currently-recorded failure is unambiguous format drift.**
- **UI + MCP surfaces.** The `SourcePulseView` chip row
  (`SourcePulseView.swift:291-304`) already has the exact pattern to copy: a
  conditional `factPill(…, color:)` gated on `failedIndexJobCount > 0` with `.help`
  (`:297-299`). MCP `stats` output schema (`MCPOutputSchemas.swift:31-33`) is
  `additionalProperties:false` with `required:[groupBy,groups,indexJobs,
  totalSessions]`; the emitter (`MCPDatabase.swift:123-146`) builds an
  `OrderedJSONValue.object`. The golden `tests/fixtures/mcp-golden/stats.source.json`
  is exact-string-compared, and `tests/fixtures/mcp-contract.sqlite` has **no**
  `file_index_state` table — the emitter must `tableExists`-guard and emit 0 there.

### Row 25 — scan scheduling and search reads

- **`triggerSync` is the wrong lever** (`EngramServiceCommandHandler.swift:1483-1495`):
  a peer-sync stub with fields `peer/pulled/pushed`. `scanNow` is a genuinely new
  command. Commands dispatch through one string switch on `request.command`
  (`:123`); a new command is one new case, and capability-token/peer-UID checks are
  enforced at the transport layer, not per-case.
- **The real cycle** is `runOnePeriodicIndexCycle` (`EngramServiceRunner.swift:726`,
  `private static`): archiveV2 index → `indexRecentSessions` → backoff bookkeeping
  → parent backfills → FTS drain loop → embedding backfills → remoteSync →
  reclamation → backup → fts optimize → status/event → telemetry. It runs strictly
  inside `activityScheduler.performWhenDue(interval:tolerance:)` in `runIndexingLoop`
  (`:681-722`), which exposes **no fire-now** API. When `archiveV2Coordinator` is
  present the cycle is wrapped in `withBacklogDrainPaused(periodicCycle)`
  (`:712-716`).
- **`withBacklogDrainPaused` is a plain-bool gate, not reentrant**
  (`ArchiveV2ServiceCoordinator.swift:577-596`): sets `periodicMaintenanceActive =
  true` on entry, `false` + `drainer.signal()` on exit; `runBacklogPass` guards on
  it (`:615`). Two overlapping cycles corrupt the flag — the first to finish
  signals the drainer while the second is still writing. **scanNow must not run
  concurrently with the periodic cycle or itself.**
- **The manual-refresh path exists but is unused.**
  `IndexingSchedulePolicy.nextInterval(manualRefresh:)` (`:78-83`) returns
  `minInterval`, bypassing idle backoff. It has **zero production callers** (only a
  unit test) — strong evidence the original design intended a manual scan to reset
  the loop's backoff through it. `recordScan` ramps 15→30→60m on idle (`:56-76`);
  `shouldDefer` returns true under Low Power / serious thermal (`:46-54`).
- **Client wiring is a 3-point conformance.** An `EngramServiceClient` command is
  a one-liner over the generic `command(name:payload:)` helper, declared in
  `EngramServiceProtocol` (`:33`, `triggerSync` precedent), `EngramServiceClient`
  (`:171`), and `MockEngramServiceClient` (`:288`). MCP write tools already route
  through `serviceClient.<method>` over the socket
  (`MCPToolRegistry.swift:1016-1017`) — not a direct DB write.
- **`isLongRunningWriteCommand`** (`ServiceWriterGate.swift:274-306`) classifies
  `indexRecent`, `periodicFtsDrain`, etc. as long-running and prefix-matches
  `index*`/`fts*`/`embed*`/`backfill*`/`initialScan*` (`:300`). A bare name
  `scanNow` matches none of these and would get the 60s follower timeout — a reason
  **not** to wrap the dispatch case in a top-level `performWriteCommand`; the
  cycle's own subcommands are already correctly gated.
- **Search reads are pure GRDB closures.** `EngramServiceReadProvider.keywordSearch`
  (`:591-630`) runs inside `read { db in … }`; its `Item` DTO already carries
  `filePath`/`sourceLocator`/`sizeBytes`/`indexedAt`
  (`EngramServiceModels.swift:327-347`). `MCPDatabase` search (`:2196-2218`) selects
  `ls.local_readable_path` per row. The **search-side** locator is
  `COALESCE(NULLIF(ls.local_readable_path,''), NULLIF(s.file_path,''),
  s.source_locator)` (`IndexJobRunner.swift:322-326`); `sync://` and offloaded
  locators are legitimately non-readable and skipped by the FTS runner (`:160-193`).
  But `file_index_state.locator` is keyed per **scanned file**: it is the raw
  locator each adapter returns from `listSessionLocators()`
  (`SwiftIndexer.swift:160`), stored verbatim as `state.locator`
  (`SwiftIndexer.swift:90,222` → `upsertFileIndexState`,
  `EngramDatabaseIndexer.swift:326`) — **not** any COALESCE over `sessions` (the
  COALESCE at `EngramDatabaseIndexer.swift:93` is an unrelated instruction-backfill
  *read* over `sessions`, not the locator write). That adapter locator equals the
  search-side COALESCE only for file==session sources (`claude-code`, adapter
  locator == `s.file_path`) — for one-file-many-sessions or virtual-locator sources
  it differs — so the D2 currency JOIN is only guaranteed to hit for file==session
  sources (see D2).
  Because `file_index_state.mtime_ns` **is** the indexed stat, an in-DB self-join is
  a no-op: the *current* mtime must come from a real `stat()` at read time, outside
  the GRDB block. Prior art (does not transfer directly — Engram lacks the two
  DB-recorded mtime tables AS compares): `as-main/AgentSessions/Indexing/DB.swift:1810-1848`
  (`indexedSessionIDsCurrent`), `as-main/AgentSessions/Search/SearchCoordinator.swift:294-305`.

## Proposed design

Four parts. Each names its own files, slices, and acceptance criteria and is
landable without the others.

---

### Part A (row 5) — make `.restartService` reachable

Post `.restartService` from two surfaces, gated on failure status, reusing the
existing `App.restartService` path unchanged.

**Gating helper.** Add to `EngramServiceStatusStore`, beside `isRunning`:

```swift
var isFailed: Bool {
    switch status {
    case .degraded, .error: return true
    default: return false
    }
}
```

Both posters need it; factoring once beats two inline `if case` matches. (Naming
is reversible; do not ask.)

**HomeView poster.** In `serviceStateSection` (`HomeView.swift:256-276`), append a
third element to the `VStack` shown only when `serviceStatusStore.isFailed`: a
`Button("Restart Service") { NotificationCenter.default.post(name: .restartService,
object: nil) }`. This keeps the shared `ServiceStateRow` struct (`:658-684`)
untouched — the minimum diff — instead of threading a callback through a type used
by both rows. The section already recomputes on `serviceStatusStore` changes, so
the conditional appears/disappears with status.

**Menu-bar poster.** In `showContextMenu` (`MenuBarController.swift:176-197`), when
`serviceStatusStore.isFailed`, insert a `Restart Service` `NSMenuItem` (with a
separator) before Quit, `target = self`, `action = #selector(restartService)`, and
add `@objc func restartService() { NotificationCenter.default.post(name:
.restartService, object: nil) }`. The menu is rebuilt on every right-click, so the
conditional include needs no observation wiring.

> **Collision (integration pass, 2026-07-25) — `showContextMenu()` is edited by
> two mirror-follow-up specs.** `docs/mcp-activation-onboarding-design-2026-07.md`
> Part B2 (row 7) also inserts items into this same rebuilt `NSMenu` — "Report an
> Issue…" / "Show Onboarding" as plain items *before the separator* (`:187`).
> This spec's conditional "Restart Service" item goes *before Quit* (after the
> separator) and is gated on `serviceStatusStore.isFailed`, so the two edits are
> additive and non-overlapping, but whichever lands second must merge into one
> menu build rather than replace it. Agreed order top-to-bottom: Open Window /
> Settings / (Help items: Report an Issue, Show Onboarding) / separator /
> [Restart Service when `isFailed`] / Quit. Both specs must preserve the
> `menu.delegate = self` / `statusItem.menu` / `menuDidClose` swap (`:194-202`).
> `App.swift` is likewise touched by three of the nine specs in disjoint regions —
> this spec at the restart observer/handler (`:151-158`, `:225-250`),
> `mcp-activation` at the AppDelegate onboarding lifecycle (`:262-295`), and
> `docs/build-provenance-perf-design-2026-07.md` Part B3 at the launch hook
> (`:91`) — a line-level merge, no functional overlap.

**Not the popover.** Keep restart controls out of `PopoverView` — the popover is
session-content only. The existing
`testPopoverDropsTechnicalChromeKeepsSessionContent` pin forbids only the literal
`popover_status_web` and would not catch a restart button, so Part A adds
`testPopoverDoesNotPostRestartService` (AC #1) to enforce the exclusion.

**Delete the false comment.** Remove `App.swift:151-152`; keep `:153` (the accurate
`autoStartService` note). Optionally rewrite `:151-152` to state the real posters.

**Presentation.** Restart failure already surfaces through the same status store
the UI renders (`EngramServiceLauncher.restart` → `.error`, `App.applyServiceEvent`
→ `.degraded`); `ServiceErrorPresenter.displayMessage(for:)` is available if a
richer message is wanted, but is not required.

**Implementation slices.**
- **A1** — add `isFailed`; post from the HomeView Service State section; delete the
  false comment. Landable alone.
- **A2** — add the menu-bar `Restart Service` item + `@objc` poster.

**Acceptance criteria.**
1. A source-inspection test asserts `HomeView.swift` and `MenuBarController.swift`
   each contain `post(name: .restartService` (or `.restartService, object`), and
   `PopoverView.swift` does **not**.
2. `App.swift` no longer contains the false two-poster comment string; the
   `autoStartService` gating note remains.
3. `grep -rn "restartService" macos` shows at least two `post(name:` call sites
   (was zero).
4. Existing `HomePopoverActionsTests` (all Web-UI-chrome guards) pass unedited.
5. No new start+monitor path: `App.restartService` and
   `EngramServiceLauncher.restart` are unchanged.

---

### Part B (row 9) — hold last-good across a failed poll

Introduce one small, testable value type for the last-good live list, consumed at
all three sites, reusing the `ServiceDataFreshness` **type** and 30-min TTL but its
own timestamp.

```swift
// Shared/Service — one seam so the three sites cannot drift.
struct LiveSessionsHold: Equatable, Sendable {
    private(set) var sessions: [EngramServiceLiveSessionInfo] = []
    private(set) var lastSuccessAt: Date?

    /// A *successful* poll (including one that returns []) replaces the list and
    /// stamps the clock. Never call this on a thrown poll.
    mutating func succeeded(_ sessions: [EngramServiceLiveSessionInfo], at now: Date = Date()) {
        self.sessions = sessions
        self.lastSuccessAt = now
    }

    /// A just-succeeded poll stays `.live` for one poll cadence, then ages to
    /// `.stale`, then past the 30-min TTL to `.expired`. `.live` MUST be a small
    /// window, NOT `age == 0`: callers compute `freshness(now: Date())` a moment
    /// after `succeeded(at: Date())`, so at every real render `age > 0` and an
    /// exact-equality `.live` is unreachable — every fresh poll would falsely
    /// caption "as of HH:mm". `liveThreshold` ≈ one SourcePulseView poll cadence.
    static let liveThreshold: TimeInterval = 15

    /// Freshness of the held list, on the live-poll clock (NOT the status channel).
    func freshness(now: Date = Date()) -> ServiceDataFreshness {
        guard let lastSuccessAt else { return .expired }
        let age = max(0, now.timeIntervalSince(lastSuccessAt))
        if age <= Self.liveThreshold { return .live }
        if age <= EngramServiceStatusStore.staleUsefulInterval { return .stale(asOf: lastSuccessAt) }
        return .expired
    }
}
```

(Requires exposing `staleUsefulInterval` as non-`private` on the store, or
duplicating the `30 * 60` constant with a comment. Reversible; recommend
exposing.)

On a **thrown** poll, do nothing — the hold keeps its last-good list and its clock,
so `freshness` naturally ages into `.stale` then `.expired`. On a **successful**
poll returning `[]` (genuinely no live sessions), `succeeded([])` clears the list
and marks it fresh — so "no sessions" and "poll failed" stay distinct.

**Three sites.**
- `SourcePulseView` — replace the `@State var liveSessions` with a
  `LiveSessionsHold`; on catch, do not blank. The section gate becomes
  `if !hold.sessions.isEmpty || hold.freshness(now:) == .expired` so an expired
  hold shows an explicit "Live sessions unavailable" row instead of vanishing;
  when `.stale`, caption the section header with the `asOf` text.
- `PopoverView` — split the `?? []`: on success call `hold.succeeded(...)`, on
  failure leave the hold; caption with `asOf` when `.stale`.
- `MenuBarController.updateBadge` — on catch, render the last-good live count from
  the hold instead of dropping the dot; drop the dot only when the hold is
  `.expired`. The today count is separate and already survives. The badge counts
  only `activityLevel == "active"` sessions (`MenuBarController.swift:430`), but the
  hold stores the full unfiltered `response.sessions` — so the consumer must
  re-apply `.filter { $0.activityLevel == "active" }.count` when rendering the held
  count, or the held badge over-counts vs the live badge.

**`asOfText`.** There is no shared helper. Factor one into the shared module
(e.g. `ServiceDataFreshness.asOfText(_:)` or a small `ServiceFreshnessFormatting`
enum) and have `SourcePulseView`/`MenuBarController` use it; leaving the two
existing private copies in place is acceptable but a third copy is not. Do **not**
send the implementer to a non-existent shared symbol.

**Implementation slices.**
- **B1** — `LiveSessionsHold` + its unit test (the repro). Landable alone.
- **B2** — wire `SourcePulseView` (the mirror's named first slice).
- **B3** — wire `PopoverView`.
- **B4** — wire `MenuBarController`; factor the shared `asOfText`.

**Acceptance criteria.**
1. `LiveSessionsHold` repro: `succeeded([a,b])`, then a simulated failed poll (no
   `succeeded` call), asserts `hold.sessions == [a,b]` and `freshness` is `.stale`
   beyond `liveThreshold` but within TTL, `.expired` past TTL. Fails against a
   `[] on catch` baseline.
2. A successful poll returning `[]` yields `hold.sessions == []`, and
   `freshness(now:)` called a few seconds later — within `liveThreshold`, the
   real-render case, NOT exact-timestamp equality — is `.live`. This asserts both
   that a failed poll and a genuine-empty poll are distinguishable and that a
   just-fresh poll is not miscaptioned as stale.
3. `SourcePulseView.swift` no longer contains `liveSessions = []` in a `catch`.
4. No new freshness enum or TTL constant is introduced;
   `ServiceDataFreshness` and `staleUsefulInterval` are reused.
5. `asOfText` appears at most three times in the tree (the two existing private
   copies + one shared helper), and `SourcePulseView`/`MenuBarController` reference
   the shared one.

---

### Part C (row 12) — surface persisted parse failures

Read `file_index_state`, add a per-source count to the DTO, a chip, and one MCP
`stats` field. Read-only, no migration. **Composes with row 2**: the DTO field
sits after `healthReason`; the chip sits in the same `SourcePulseView`
`factPill` row (`:291-304`) as row 2's badge; neither collides. **Also disjoint
from `docs/uiux-polish-a11y-design-2026-07.md` (row 29)**, which edits this same
file's load-failure `AlertBanner` (`:74`) and error-catch text (`:137`/`:169`/
`:178`) — a different region from the chip and from Part B's live-poll catch
(`:120-127`); rebase, do not patch by frozen line.

**Predicate — persistently-stuck `retry` rows, NOT `terminal`.** Verifying the
writer overturns both the mirror's naive "count all failures" AND an earlier draft
of this doc that counted `parse_status='terminal' AND failure_kind NOT IN (the 5
by-design kinds)`. `parse_status='terminal'` is written at exactly one site
(`IndexingWriteSink.swift:206`, `parseStatus: isTerminal ? .terminal : .retry`)
gated on `isTerminalFailure` (`:228-235`), which returns true for **exactly** the
five by-design kinds `{fileTooLarge, messageLimitExceeded, lineTooLarge,
unsupportedVirtualLocator, noVisibleMessages}` and false → `.retry` for every
genuine parse breakage (`malformedJSON`, `malformedToolCall`, `truncatedJSON`,
`truncatedJSONL`, `invalidUtf8`, `deeplyNestedRecord`). So `parse_status='terminal'`
is logically equivalent to "failure_kind ∈ those five" — and the earlier draft's
`NOT IN (those same five)` is a permanent contradiction that counts identically 0
on **every** corpus, not just today's. Genuine breakage lives in the `retry` rows.

Count `retry` rows whose kind is a real parse-format breakage AND that have stopped
self-healing — persistence gated by `retry_count` so a single transient pass does
not flap the chip:

```sql
SELECT source, COUNT(*) AS parse_failures
FROM file_index_state
WHERE parse_status = 'retry'
  AND retry_count >= 3
  AND failure_kind IN
      ('malformedJSON','malformedToolCall','truncatedJSON',
       'truncatedJSONL','invalidUtf8','deeplyNestedRecord')
GROUP BY source
```

`retry_count` exists (`EngramMigrations.swift:175`) and increments on each failed
re-attempt (`IndexingWriteSink.swift:195`). The `retry_count >= 3` floor (tunable
— tune so a single-pass transient does not count) excludes files that failed once
and self-healed on the next pass; only a file that keeps failing to parse across
several cycles counts. Environmental retry kinds (`fileMissing`,
`fileModifiedDuringParse`, `sqliteUnreadable`, `grpcUnavailable`) are excluded —
transient I/O, not format breakage. On today's corpus this counts the subset of the
529 `retry` rows (all currently `malformedJSON`) that are persistently stuck; the
exact count is not measured here and the earlier draft's "0 in steady state" claim
is dropped — a persistently-unparseable file SHOULD surface. Guard with
`tableExists("file_index_state")`.

> **Measured, 2026-07-25 (before implementing and before orphan pruning
> landed).** The paragraph above left the count unmeasured; it has now been run
> against a real `~/.engram/index.sqlite` (42,421 `ok` / 529 `retry` / 756
> `terminal`). The follow-up below overturns several of its assumptions. These
> are pre-prune snapshot counts, not a claim about the database after PR #264.
>
> **1. The `retry_count >= 3` floor filters nothing.** Identical counts with and
> without it:
>
> | predicate | rows |
> |---|---|
> | format-breakage kinds, `retry_count >= 1` | 528 |
> | format-breakage kinds, `retry_count >= 3` | **528** |
>
> `MIN(retry_count)` over the matching rows is **3** (max 58). The one-row delta
> between all 529 `retry` rows and the 528-row format-breakage set had
> `retry_count = 1` and was outside the IN-list. Its exact `source` and
> `failure_kind` were not preserved with the snapshot; the isolating query was:
>
> ```sql
> SELECT source, failure_kind, retry_count
> FROM file_index_state
> WHERE parse_status = 'retry' AND retry_count = 1
> ```
>
> So the floor does not "exclude files that failed once and self-healed" from the
> counted set — no matching row is below 3. **Keep the floor as a defensive lower
> bound (another corpus may differ), but do not write a comment claiming a
> flap-protection it does not currently provide.** A comment that describes a
> guard the data shows is inert is the same class of defect as the rest of this
> backlog.
>
> **2. The chip is not a rare badge.** Per-source hits and their denominators:
>
> | source | rows | hits | share |
> |---|---|---|---|
> | claude-code | 28,724 | 262 | 0.91% |
> | codex | 6,014 | 169 | 2.81% |
> | glm | 2,359 | 44 | 1.87% |
> | deepseek | 569 | 16 | 2.81% |
> | kimi | 2,665 | 14 | 0.53% |
> | mimo | 272 | 9 | 3.31% |
> | qwen | 1,484 | 8 | 0.54% |
> | minimax | 414 | 4 | 0.97% |
> | doubao | 30 | 2 | 6.67% |
>
> These nine rows are the complete 528-hit set. `file_index_state.source` is raw
> persisted text from the adapter that wrote the row, so the workflow-journal
> residue is distributed across derived and legacy source values; it is not all
> recorded as `claude-code`.
>
> `"\(n) unparsed"` therefore renders a permanent three-digit number on the two
> main sources. A bare `262` reads as an alarm; `0.9%` reads as negligible — same
> fact, opposite impression. **The chip must carry its denominator** (e.g.
> `262 / 28,724 unparsed`, or the share in the `.help` text), for the same reason
> row 13 stopped drawing a limitless share as a filled quota meter.
>
> **3. 97% of the counted rows are not parse failures.** The note above ("all 528
> are `malformedJSON`; sample before trusting it") was followed up. Sampling the
> locators:
>
> | subset | rows |
> |---|---|
> | `…/subagents/workflows/*/journal.jsonl` | **514** |
> | everything else (see finding 5) | 14 |
>
> A sampled workflow journal parses as **94 valid JSON lines, 0 invalid**, with
> top-level keys `agentId` / `key` / `result` / `type` — a workflow-journal
> schema, not a chat transcript. The file is not malformed.
>
> **4. Those 514 rows are stale orphans, not live failures.** This corrects the
> first draft of finding 3 above, which read them as an adapter that "meets a
> record type it does not model" and as "514 rows retrying forever". Both are
> wrong. The timestamps say the retries stopped three weeks ago:
>
> | field, over the 514 journal rows | value |
> |---|---|
> | `updated_at` range | 2026-07-02 09:10 → **2026-07-04 07:44** |
> | `retry_after` max | **2026-07-04 08:44** (long past) |
> | newest `updated_at` anywhere in the table | 2026-07-25 17:39 (at measurement) |
>
> The table was live at measurement time; these rows had not been touched since
> 2026-07-04, so nothing was retrying them. Nor could it:
> `ClaudeCodeProfileService` counts only direct `.jsonl` children one level under
> `subagents/` (`macos/EngramService/Core/ClaudeCodeProfileService.swift:286-319`).
> `ClaudeCodeAdapter` also enumerates direct children and now descends into
> `subagents/workflows/wf_*`, but accepts only `agent-*.jsonl` there — explicitly
> never `journal.jsonl`
> (`macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:112-156`).
> Neither current path can produce a
> `subagents/workflows/<wf>/journal.jsonl` locator. **1,166** such files exist
> under `~/.claude` alone against only **262** rows persisted as `claude-code`;
> that partial, frozen coverage is consistent with a removed historical discovery
> path, not evidence that a current live scan would enumerate the journals.
>
> At measurement time, **nothing pruned `file_index_state`**. Product code only
> created, inserted, and read the table, so a row written by a discovery path
> that no longer existed was counted forever. That statement is historical, not
> current: PR #264 (`33887fc4`, 2026-07-26) added domain-scoped pruning after a
> complete, non-empty adapter enumeration. Empty or failed enumeration publishes
> no prune domain; prune failures are logged and isolated. The pre-prune snapshot
> above still explains why the 528 rows existed, but it does not establish their
> post-#264 count.
>
> All **262** claude-code hits are journal rows. Globally, the 514 journal rows
> are **~97%** of the 528-hit set and span nine persisted source values. Shipping
> a permanent `262` claude-code chip would therefore be a new false claim in a
> backlog whose whole subject is false claims.
>
> **Row 12 cannot ship on this predicate.** Options, in the order they should be
> considered:
> 1. Prune orphan `file_index_state` rows — delete rows whose locator the current
>    scan no longer enumerates. This is the actual defect; the chip is only the
>    first surface that would have exposed it.
> 2. Failing that, scope every count derived from this predicate — the service
>    DTO, chip, MCP aggregate, and acceptance checks — to locators the current
>    scan still enumerates, so orphans cannot inflate any surface regardless of
>    how they got there.
> 3. Weakest: exclude `…/subagents/workflows/%journal.jsonl` from the predicate
>    and say so in the help text. Cosmetic — it leaves the orphans in the table
>    and only hides this one shape.
>
> Option 1 was out of row 12's scope and has since landed independently in PR
> #264. Before implementing row 12, run one complete post-#264 indexing pass on
> the measured corpus and re-run the exact predicate. If the old rows remain,
> stop and adjudicate the declared domain rather than treating code presence as
> proof that the stored state was repaired.
>
> **5. The other 14 rows are orphans too. Nothing in the counted set is a current
> failure.** The earlier draft left these unopened and called them "real session
> transcripts". Opened now — every one was read and JSON-validated line by line:
>
> | subset of the 14 | rows | finding |
> |---|---|---|
> | file no longer exists on disk | **10** | deleted sessions; 4 of them had `size_bytes = 0` |
> | file exists, **every line valid JSON** | 4 | 7–8 control-only records, 2.4–2.6 KB |
> | file exists and is actually malformed | **0** | — |
>
> Their `updated_at` is 2026-06-21 (the 10 missing), 2026-07-02 (3), 2026-07-04
> (1) — the same frozen pattern as the journals.
>
> **Across all 528 counted rows, zero are a file that currently fails to parse.**
> Every one is residue: an orphan row for a file that is gone, or one written by a
> discovery path no longer in the tree. A chip reading `262` on claude-code would
> be reporting corpus damage of which none exists. Option 1 (prune) remains the
> preferred repair because it fixes the stored state; PR #264 now implements that
> repair for adapters that declare a complete domain. Option 2 can still produce
> an honest live-domain reading (`0 / N` on this pre-prune corpus) without
> deleting the residue. Only option 3 leaves unrelated orphan shapes in the
> measured set and is merely cosmetic.
>
> **Not established:** which code wrote these rows during 2026-06-21..07-04. No
> specific commit was traced, so no source branch or change is attributed here.

**Prerequisite status for every C slice below: implemented in code, runtime
remeasurement still required.** PR #264 landed option 1 in `33887fc4`: opted-in
adapters publish roots only after a complete listing, and pruning deletes only
rows under that declared domain that are absent from the same keep-set. The 528
rows above came from a pre-prune snapshot. Do not execute C1-C3 against that
stale result: first complete a post-#264 indexing pass on the target corpus and
re-run the exact numerator and denominator queries. Until that read-only
remeasurement exists, the runtime count is **UNVERIFIED**. The DTO, chip, MCP
field, and acceptance criteria below describe the post-prerequisite surface; a
denominator alone does not make a stale numerator honest.

**DTO.** Add `parseFailureCount: Int` (default 0) to `EngramServiceSourceInfo` at
all five edit points, after `healthReason`. Named `parseFailureCount`, **not**
`drifted`/`failedIndexJobCount`, so it does not read as row 2's ladder input or the
existing `session_index_jobs` counter. It does **not** feed the health ladder
(row 2 is rewriting it concurrently; a ladder branch invites a merge conflict and
re-opens a decision row 2 owns).

**Chip.** In `SourcePulseView.swift` (re-anchored after PR #262: chip `HStack` at
`:330-356`, `failedIndexJobCount` pill at `:336-339`), mirror the
`failedIndexJobCount` pill. Per the measurement above the label must
carry its denominator rather than a bare count — `"\(n)/\(total) unparsed"`, or a
bare count only if the share is stated in `.help`. Neutral gray, informational —
not an error state. `n` and `total` must come from the same repaired/scoped
locator domain: the declared domain after prune, or the currently enumerated
locators under option 2. Never pair a scoped numerator with a table-wide
denominator. Help text: "Files this source could not parse (excludes empty,
oversized, and virtual sessions). A sudden rise can signal a vendor format change."

**MCP `stats`.** After the prerequisite above, add one top-level `parseFailures`
integer = the global sum of the repaired/scoped predicate. The following MCP
anchors were rechecked unchanged at `main@33887fc4`. Edit the schema string
(`MCPOutputSchemas.swift:31-33`: add
`parseFailures` to `properties`; leave it out of `required` so a missing
`file_index_state` table is valid) **and** the emitter
(`MCPDatabase.swift:123-146`: append `("parseFailures", .int(count))`) in the same
diff, or
`testStructuredContentMatchesDeclaredOutputSchema` fails. **Reentrancy trap:**
`MCPDatabase` has **no** `tableExists` helper, and the stats reads already run
inside one `queue.read { db in … }` closure (`:111-122`) that returns a tuple. Do
the `file_index_state` existence check *and* the count on the **same `db` handle
inside that existing closure** — probe `sqlite_master` via `db`, then run the
`GROUP BY`, and add the result to the returned tuple. A nested `queue.read` inside
`:111-122` deadlocks (the probe/`queue.read` reentrancy trap the baseline specs
flagged); never open a second `queue.read` for the probe. Regenerate
`stats.source.json` (both the escaped `content` text and `structuredContent`) with
`parseFailures: 0`. `tools.outputSchema.json` is a name list and does not change.

**Honest limit (state it in the doc and the chip tooltip).** This catches only
files the parser already flags as a persistently-stuck parse-format failure
(`retry` + a format-breakage kind + `retry_count>=3`). A vendor rename that
manifests as a `noVisibleMessages` surge is **excluded** by construction (it is a
by-design `terminal` kind, benign baseline 693), and a renamed record kind that
still parses as valid JSON produces no `ParserFailure` at all — that is row 23's
adapter-side `unknownRecordKinds` counter. Row 12 is the coarse "genuine parse
breakage" signal; it is not a drift detector.

**Implementation slices.**
- **C1** — service read: `sourceParseFailureCounts(_:)` helper + wire
  `parseFailureCount` into the `sources()` map. DTO field (all five points).
  Service tests. Landable alone (DTO field unused by UI/MCP yet, defaults 0).
- **C2** — `SourcePulseView` chip + DTO round-trip tests.
- **C3** — MCP `stats` field: schema + emitter + golden regen + `docs/mcp-tools.md`
  (the stats shape at `:21` and the section listing `{groupBy, groups, indexJobs,
  totalSessions}`).

**Acceptance criteria.**
1. `parseFailureCount` counts only `retry` rows with `retry_count>=3` and a
   format-breakage kind, so a source with no persistently-stuck files reads 0 and
   hides the chip; `git diff` shows no ladder change in
   `sourceHealthStatus`/`sourceHealth`.
2. A service `_repro` seeding a `file_index_state` row with
   `parse_status='retry', failure_kind='malformedToolCall', retry_count=3` for
   `codex` — the state the writer actually produces (`malformedToolCall` →
   `isTerminalFailure=false` → `.retry`, `IndexingWriteSink.swift:206,228-235`) —
   makes `sources()` report `codex.parseFailureCount == 1`; the same kind with
   `retry_count=1` (self-healed, below the floor) reports 0, and a by-design
   `parse_status='terminal', failure_kind='noVisibleMessages'` row reports 0.
3. The two whole-struct `XCTAssertEqual(sources, […])` literals
   (`EngramServiceIPCTests.swift:1652-1661`, `:2157-2166`) pass **unedited** —
   `parseFailureCount` defaults 0 and `seedSearchFixture` creates no
   `file_index_state`.
4. `stats` structuredContent contains `parseFailures` and validates against the
   declared schema; `testStatsMatchesGolden` passes with the regenerated fixture.
5. On `mcp-contract.sqlite` (no `file_index_state`), `stats` emits
   `parseFailures: 0` and does not throw.

---

### Part D (row 25) — `scanNow` + currency-aware search

Two independently landable halves: **D1** the command, **D2** the read.

#### D1 — `scanNow` command (app + MCP reachable)

Recommended: **signal the loop** (not an out-of-band cycle). A `scanNow` that runs
its own cycle in the command handler must reproduce `withBacklogDrainPaused` and a
real mutex excluding the periodic loop (the plain-bool gate is not reentrant); it
also cannot reset the live loop's backoff. Signalling the single loop is naturally
single-flight, runs the existing wrapped `periodicCycle` path (inheriting
`withBacklogDrainPaused` for free). Backoff after the manual cycle is reset by the
existing `recordScan` path when the cycle indexes anything (`indexed>0` →
`targetInterval=minInterval`, `IndexingSchedulePolicy.swift:62-64`); a manual scan
that indexes nothing leaves `targetInterval` unchanged.

- Construct a `ManualScanTrigger` (an `AsyncStream<Void>` continuation, or a small
  actor with a signalled continuation) **before** both `runIndexingLoop` and the
  command handler, and pass it to each.
- **The scheduled wait is NOT in `runIndexingLoop`.** That loop
  (`EngramServiceRunner.swift:681-722`) only *awaits*
  `activityScheduler.performWhenDue(interval:tolerance:)` at `:695` and `break`s the
  entire loop on a `.cancelled` result (`:719`). The actual sleep lives inside the
  `IndexingBackgroundActivityScheduling` conformers'
  `waitForScheduleFire(interval:tolerance:)` — production
  `IndexingBackgroundActivityScheduler.swift:71-88` plus the two test doubles. So
  the trigger must be threaded into the **protocol**, not the loop body: add an
  interrupt that wakes `waitForScheduleFire` early and resolves it as `.run` (open
  an activity and run the existing wrapped `periodicCycle`/`withBacklogDrainPaused`
  path), implemented in the NS-backed conformer and both test doubles. It must
  **never** resolve as `.cancelled` — `.cancelled` at Runner `:719` terminates the
  indexing loop entirely. Preserve the `.deferred/.run/.cancelled` outcome contract
  and the `withBacklogDrainPaused` wrap (`:712-716`). Keep the diff surgical, but do
  not describe it as a one-line `select` in `runIndexingLoop`; the seam is the
  scheduler protocol.
- **Backoff reset is the existing `recordScan` behaviour, not `manualRefresh`.**
  After the manual cycle, `recordScan(indexed>0)` sets `targetInterval=minInterval`
  (`IndexingSchedulePolicy.swift:62-64`). `nextInterval(manualRefresh:)` is a
  read-only helper that returns `minInterval` for one sleep and never mutates
  `targetInterval` (`:80-83`) — neither necessary nor sufficient for the reset. If
  shortening the *next* scheduled sleep after a manual scan is also wanted, pass
  `manualRefresh: true` into the `nextInterval()` call at `Runner:682` for the
  following iteration; do not attribute the backoff reset to it.
- Add `case "scanNow":` to the dispatch switch (`EngramServiceCommandHandler.swift:123`)
  that signals the trigger. Do **not** wrap the case in a top-level
  `performWriteCommand` — the cycle's subcommands (`indexRecent`,
  `periodicFtsDrain`, …) are already correctly gated, and a bare `scanNow` name
  would mis-classify as short-running.
- Client wiring: add `scanNow()` to `EngramServiceProtocol`, `EngramServiceClient`
  (via `command("scanNow", …)`), and `MockEngramServiceClient`.
- MCP: register a `scan_now` tool in `MCPToolRegistry` that calls
  `serviceClient.scanNow()`. No direct DB write.

The scan must reuse the **full** cycle, not a thin "index recent only": skipping the
FTS drain loop leaves `sessions_fts` empty for just-indexed sessions, so search
returns nothing immediately after a manual scan — the exact failure the feature
fixes.

**Open return-semantics decision (see Risks):** recommend `scanNow` returns
immediately with `{accepted: true}` and the caller polls `status`, since a full
cycle can take minutes and neither an MCP agent nor the app should block on it.

**D1 acceptance criteria.**
1. Calling `scanNow` on an idle loop runs one full cycle within one tolerance
   window (not one scheduled interval); a `_repro` proves a session written after
   the last scheduled scan is searchable after `scanNow` and was not before.
2. `scanNow` reachable via `EngramServiceClient.scanNow()` and via the `scan_now`
   MCP tool; both route over the socket, no direct SQLite write.
3. A `scanNow` issued while a periodic cycle is in flight does not start a second
   cycle (single-flight); `periodicMaintenanceActive` is never set by two callers
   at once.
4. After `scanNow` that indexes new sessions, `IndexingSchedulePolicy.targetInterval
   == minInterval` — the reset comes from `recordScan` on the `indexed>0` branch
   (`:62-64`), NOT from `manualRefresh`. To prove the scheduled sleep was actually
   interrupted (not merely that `recordScan` ran), start the policy at
   `targetInterval == maxInterval` (60m), issue `scanNow`, and assert a full cycle
   completes within one tolerance window rather than after the 60-min interval.
5. `triggerSync` is untouched and still returns its peer-sync error.

#### D2 — currency-aware search read

Annotate each search result with its currency; do not withhold (that blanks valid
data — `scanNow` is the recovery).

- Inside the GRDB read block (`EngramServiceReadProvider.keywordSearch:598`;
  `MCPDatabase` search `:2196-2218`), also fetch each result's `file_index_state.
  mtime_ns` (LEFT JOIN on `source` + the COALESCE locator) and return the locator +
  indexed mtime with each row. **JOIN is not guaranteed to hit:** `file_index_state`
  is keyed per **scanned file** by the raw adapter locator — `state.locator` from
  `adapter.listSessionLocators()` (`SwiftIndexer.swift:160,90,222` →
  `upsertFileIndexState`, `EngramDatabaseIndexer.swift:326`), **not** a COALESCE
  over `sessions` — a *different* value than the search COALESCE
  `NULLIF(ls.local_readable_path,''), NULLIF(s.file_path,''), s.source_locator`
  (`IndexJobRunner.swift:322-326`). Equal for file==session sources (`claude-code`,
  adapter locator == `s.file_path`), but not for one-file-many-sessions or
  virtual-locator sources — a LEFT JOIN so a miss yields NULL indexed mtime.
- **Outside** the closure, `stat()` each **distinct** locator (dedupe; bound by
  `limit`). Classify: **no matching `file_index_state` row (JOIN miss, indexed mtime
  NULL)**, `sync://`/empty locator, offloaded session, or failed `stat` →
  **`reclaimed`** (expected, **never `stale`** — the JOIN degrades safely); `stat`
  succeeds and file `mtime_ns > indexed mtime_ns` → **`stale`**; else **`fresh`**.
- App search `Item` gains a `currency: String?` field (plain Codable — free).
- MCP search: add one top-level optional `staleCount` integer to
  `MCPOutputSchemas.search` (`:63-64`, `additionalProperties:false` on the top
  object and each result item — a per-item field would need the item schema
  edited; a top-level count is cheaper). Emit it only when > 0 to avoid golden
  churn on all-fresh data; fold a human note into the existing `warning` string.

**D2 acceptance criteria.**
1. A `_repro` on a **file==session locator source (`claude-code`)** so the JOIN is
   guaranteed to hit: index a session, assert the result resolves a non-NULL indexed
   mtime (JOIN hit — a key mismatch must fail loudly here, not silently default to
   `fresh`), then `touch` its source file to advance mtime past `indexed mtime_ns`;
   the result's `currency == "stale"`.
2. An offloaded / `sync://` result maps to `reclaimed`, never `stale`, even though
   its `stat` fails.
3. `stat()` calls happen outside the GRDB read closure (no filesystem syscall
   inside `read { db in … }`).
4. MCP search with all-fresh results emits no `staleCount` and matches
   `search.keyword.json` unedited; with a stale result it emits `staleCount >= 1`
   and validates against the schema.
5. Distinct locators are stat-ed once each; a search returning N results over K
   distinct files does K stats, not N.

## Invariants affected

- **#1 Single-Writer Discipline** (`docs/invariants.md:5`) — preserved. Part D's
  `scanNow` routes through `ServiceWriterGate` via the existing cycle subcommands;
  no new writer.
- **#3 Tier Visibility** (`:19-24`) — **not touched.** Part C reads
  `file_index_state`, not tier; Part D2's currency read adds no tier logic. Do not
  amend this entry (row 2 and row 22 already contend on line `:23`).
- **#12 EngramMCP Is Read-Only Except Service IPC Writes** (`:82-88`) — preserved
  and strengthened. Part C's `stats` field and Part D2's `staleCount` are reads;
  Part D1's `scan_now` MCP tool calls `serviceClient.scanNow()` over the socket,
  the exact IPC-write pattern this entry mandates, not a direct GRDB write.
- **#13 JSONL Tail Checkpoints** (`:89-94`) — preserved. Part D2's currency read
  `stat`s source files but writes no `file_index_state` row and does not touch
  `parsed_offset`/`boundary_hash`.
- No new invariant. These are last-mile UX/read fixes and one command; none
  introduces a cross-runtime contract warranting a ledger entry.

## Alternatives considered

- **Row 5: build the typed remediation ladder** (AS `AuthRemediationBanner`).
  Rejected — one real call site; an abstraction for single-use code. Post the
  notification and reuse the one existing restart path.
- **Row 5: post from the popover too.** Rejected — keep the popover session-only.
  The existing `testPopoverDropsTechnicalChromeKeepsSessionContent` pin catches only
  the literal `popover_status_web`, so Part A adds
  `testPopoverDoesNotPostRestartService` to enforce it.
- **Row 5: mutate `ServiceStateRow` to carry a restart callback.** Rejected — the
  struct is shared by both rows; a conditional button in the section is a smaller
  diff.
- **Row 9: reuse `ServiceDataFreshness` verbatim for the live list.** Rejected —
  it reads the status channel's `lastEventAt`, which live polls never bump, so a
  failed live poll during a `.running` service would falsely report `.live`. Reuse
  the type, track a separate clock.
- **Row 9: reference `asOfText` as if shared.** Rejected — it is duplicated
  privately and absent from two of the three sites; factor one shared helper.
- **Row 12: count `failure_kind IS NOT NULL`** (the mirror's literal reading).
  Rejected on measurement — 92% of terminal failures are benign `noVisibleMessages`
  empties; the chip would be permanently orange, the exact row-2 anti-pattern.
- **Row 12: count `parse_status='terminal' AND failure_kind NOT IN (the 5 by-design
  kinds)`** (an earlier draft of this doc). Rejected as structurally dead —
  `parse_status='terminal'` is written only for exactly those five kinds
  (`IndexingWriteSink.swift:206,228-235`), so the predicate is a permanent
  contradiction that counts 0 on every corpus. Genuine breakage lands in `retry`.
- **Row 12: count all `retry` rows regardless of `retry_count`.** Rejected — a
  single transient `malformedJSON` pass self-heals and would flap the chip; gate on
  `retry_count>=N` so only persistently-stuck files count.
- **Row 12: feed the health ladder.** Rejected — row 2 is concurrently rewriting
  the ladder; a branch here invites a merge conflict and re-opens a decision row 2
  owns. Separate DTO field + neutral chip only.
- **Row 25: repurpose `triggerSync`.** Rejected — it is a peer-sync stub with the
  wrong response shape; `scanNow` is a new command.
- **Row 25: out-of-band cycle in the command handler (Option A).** Rejected as the
  primary path — needs a real mutex excluding the periodic loop (the
  `periodicMaintenanceActive` bool is not reentrant), cannot reset live backoff,
  and risks corrupting archive-drain ordering on overlap. Signalling the single
  loop is naturally single-flight.
- **Row 25: thin "index recent only" scan.** Rejected — skips the FTS drain loop,
  so search returns nothing immediately after the manual scan.
- **Row 25: withhold stale search results.** Rejected — withholding blanks valid
  data; annotate, and let `scanNow` refresh.

## Test plan

All Swift/Vitest; no TypeScript product change. Named files and functions:

- **Row 5** — extend `macos/EngramTests/HomePopoverActionsTests.swift` (reuse
  `homeView()`, `menuBarController()`, `popoverView()`):
  `testHomeServiceStateSectionPostsRestartService`,
  `testMenuBarMenuPostsRestartService`,
  `testPopoverDoesNotPostRestartService`,
  `testAppRemovesFalseRestartPosterComment`. Source-inspection asserts, matching the
  file's existing pattern; SwiftUI bodies are not unit-instantiable here.
- **Row 9** — new `macos/EngramTests/LiveSessionsHoldTests.swift`:
  `testFailedPollRetainsLastGoodList_repro` (the mirror's named repro — a thrown
  poll must not empty the list), `testSuccessfulEmptyPollClearsAndMarksLive`,
  `testHoldExpiresPastThirtyMinuteTTL` (mirror
  `EngramServiceStatusStoreTests.testDataFreshnessTransitionsAcrossThirtyMinuteBoundary:53`).
  Source-inspection guard in `SourcePulseUsageFormattingTests`-style: `SourcePulseView.swift`
  no longer contains `liveSessions = []` in a catch.
- **Row 12** — service `_repro` in
  `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`, extending
  `seedSearchFixture(at:)` (`:5565`) with an inline `CREATE TABLE file_index_state`
  + INSERTs, mirroring `testSQLiteReadProviderSourcesExposeArchiveHealthFacts`
  (`:1664-1761`): `testSourceParseFailureCountExcludesBenignKinds_repro`
  (`retry`+`malformedToolCall`+`retry_count=3` → 1; `retry_count=1` → 0;
  `terminal`+`noVisibleMessages` → 0). DTO round-trip in
  `macos/EngramTests/SourcesSyncTests.swift` (mirror the `liveSyncDisabled` trio
  `:30-54`): legacy JSON without `parseFailureCount` decodes to 0. MCP:
  `testStatsReportsParseFailures` in
  `macos/EngramMCPTests/EngramMCPExecutableTests.swift`, copy-`mcp-contract.sqlite`
  + insert (pattern: `testStatsReportsIndexJobCountsByRawStatus:1569`), plus the
  regenerated `stats.source.json` golden.
- **Row 25** — D1 `_repro` in `EngramServiceCoreTests`
  (`testScanNowIndexesSessionWrittenAfterLastScheduledScan_repro`): write a session
  file after the last scheduled scan, assert not searchable, call `scanNow`, assert
  searchable — proving the full cycle (incl. FTS drain) ran. Single-flight test
  asserting no double cycle. D2 `_repro`
  (`testSearchMarksResultStaleWhenSourceFileAdvancesPastIndexedMtime_repro`): index,
  `touch` past `mtime_ns`, assert `currency == "stale"`; `…MapsOffloadedResultToReclaimed`.
  MCP schema-conformance is covered by the existing
  `testStructuredContentMatchesDeclaredOutputSchema`.

**Intentionally not tested:** rendered tooltips (`.help()` has no unit harness —
source-inspection guards substitute); the exact wall-clock of a `scanNow` cycle
(asserted as a searchability property, not a duration).

## Rollout

No version bump, no migration, no schema change. All four parts ship in the next
`Engram.app` + bundled `EngramService` build. Part A/B take effect on the next UI
render; Part C on the next `sources()`/`stats` call; Part D1 on the next `scanNow`;
Part D2 on the next search. `scan_now` is a new MCP tool — MCP clients see it after
the helper rebuild.

Revert: each part reverts independently by reverting its diff. Nothing is
persisted; there is no stale state to reconcile. An old app decoding a new payload
ignores `parseFailureCount`/`currency`; a new app decoding an old payload defaults
them.

## Risks and open questions

- **Row 5 — precise framing (medium).** The spec must not repeat the brief's
  "latches `.degraded` forever." The monitor keeps probing and self-heals on a
  successful probe (`EngramServiceLauncher.swift:224-230,258-266`); the restart
  button matters only for a service that cannot self-recover. A wrong invariant
  here misleads the implementer about when the affordance is needed.
- **Row 9 — live-list TTL boundary (open).** When a failed poll follows a genuine
  period of zero live sessions, the hold correctly shows nothing (last success was
  `[]`). But should an `.expired` hold show an explicit "unavailable" row
  (recommended) or silently vanish as today? Decided per-site above; confirm the
  copy in-app.
- **Row 9 — where the shared `asOfText` lives (open, reversible).** On
  `ServiceDataFreshness` vs a formatting enum; either is fine, do not block on it.
- **Row 12 — the persistent-`retry` predicate has a real blind spot (open,
  stated).** Counting only stuck `retry` format-breakage rows and excluding the
  by-design `noVisibleMessages` `terminal` kind, Part C cannot see the mirror's own
  motivating drift mode (a vendor rename producing empty parses). This is
  deliberate: the benign baseline (693) makes that count useless as a badge.
  **Open question:** is a *trend* monitor over `noVisibleMessages` per source (out
  of scope here) worth a follow-up, or does row 23's record-kind counter cover the
  same ground?
- **Row 12 — MCP golden churn on an S-row (medium).** `parseFailures` forces
  regenerating `stats.source.json` (content text + structuredContent) alongside the
  schema and emitter, or `testStructuredContentMatchesDeclaredOutputSchema` /
  `testStatsMatchesGolden` break. Land all four in one diff.
- **Row 25 — the scheduler-protocol interrupt is the real risk (high).** The
  interrupt lives in `IndexingBackgroundActivityScheduling.waitForScheduleFire`, not
  in `runIndexingLoop` — it touches the one place both periodic and manual scans
  flow through, across the production conformer and both test doubles; a careless
  change alters the periodic path's timing or, worse, resolves the wait as
  `.cancelled` and kills the loop at `Runner:719`. Keep the diff surgical, cover
  single-flight explicitly, and assert the interrupt resolves `.run` not
  `.cancelled`. **Open question:** exact interrupt mechanism inside
  `waitForScheduleFire` — an `AsyncStream`/continuation vs a cancellable timer Task
  — is left to implementation; all conformers must preserve the
  `withBacklogDrainPaused` wrap and the `.deferred/.run/.cancelled` outcomes.
- **Row 25 — return semantics (open).** `scanNow` returns immediately
  (`{accepted}`, caller polls `status`) vs blocks until the cycle completes (a
  minutes-long await; migration commands set a precedent with long timeouts).
  Recommended immediate; confirm with the MCP tool contract.
- **Row 25 — `shouldDefer` under thermal/low-power (low, open).** Should a manual
  `scanNow` override `IndexingSchedulePolicy.shouldDefer` (`:46-54`), or defer like
  the periodic cycle? An agent forcing heavy indexing under thermal pressure is the
  downside; deferring a user-requested scan is the other. Recommend honouring
  `shouldDefer` and reporting "deferred" in the response.
- **Row 25 — stat() cost ceiling (low).** Up to `limit` stats per search on
  slow/network volumes; dedupe by locator and bound by `limit` (default is small).
  Measured cost not taken; expected negligible for the default limit.
