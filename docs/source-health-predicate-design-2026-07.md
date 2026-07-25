# Design Doc: Source Health Predicate and Health Reason

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog row 2 (F3, effort S,
  impact Medium). Sibling specs from the same mirror pass, and the single
  authoritative implementation sequence, are indexed in that report's
  **Follow-up specs** section:
  `docs/insight-supersede-filter-design-2026-07.md` (row 1),
  `docs/codex-native-parentage-design-2026-07.md` (row 22),
  `docs/adapter-format-drift-design-2026-07.md` (row 23). This spec is
  **second** in that sequence.

## Problem

Measured read-only against `~/.engram/index.sqlite` on 2026-07-24 by running the
provider's own statements verbatim: **18 of 21 sources have a search-coverage
gap** (`searchableSessionCount < sessionCount`). Pushed through the *full* ladder
those 18 render as **14 `partial` and 4 `attention`**: `claude-code` (481 failed
index jobs), `grok` (119), `codex` (9) and `antigravity` (4) hit the earlier
`failedIndexJobCount > 0 → "attention"` branch (`:1840`) before the coverage
branch (`:1842`) is ever evaluated. No source has a non-`observed` usage status
today, so branches 2 and 4 never fire. Only three sources render `healthy` — the
tiny archived default-off adapters `cline` 3/3, `iflow` 2/2, `lobsterai` 1/1. The
badge on the Sources page is therefore orange for every source a user actually
uses, and it has been for the whole life of the feature.

Exact SQL run (mirrors `macos/EngramService/Core/EngramServiceReadProvider.swift:1011-1016`
and `:1698-1704`):

```sql
WITH tot AS (
  SELECT source, COUNT(*) c FROM sessions WHERE hidden_at IS NULL GROUP BY source),
 srch AS (
  SELECT s.source src, COUNT(DISTINCT f.session_id) n
  FROM sessions_fts f JOIN sessions s ON s.id = f.session_id
  WHERE s.hidden_at IS NULL GROUP BY s.source)
SELECT tot.source, tot.c, COALESCE(srch.n, 0)
FROM tot LEFT JOIN srch ON srch.src = tot.source ORDER BY tot.c DESC;
```

Worst rows: `claude-code` 1,181/18,372, `codex` 628/5,762, `kimi` 196/2,719,
`glm` 0/2,229, `qwen` 271/1,438, `deepseek` 0/526.

The cause is not a broken index. It is a wrong denominator. `skip`-tier sessions
(subagent, dispatch, and noise sessions) are *deliberately* excluded from
`sessions_fts` by the writer, yet they are counted in the health denominator.
Measured tier split of non-hidden sessions:

| tier | sessions | with an `sessions_fts` row |
| --- | --- | --- |
| skip | 29,829 | 0 |
| premium | 2,197 | 2,074 |
| normal | 1,169 | 992 |
| lite | 299 | 250 |

29,829 sessions contribute to the denominator and 0 to the numerator, by design.
The badge is reporting a design decision as a defect, permanently, so users learn
to ignore it — and the 349 genuinely-missing FTS rows are invisible inside the
noise.

Second problem, same surface: when the badge is not `healthy` it says only
`PARTIAL` / `ATTENTION` / `CRITICAL` in uppercase with no tooltip and no reason
(`macos/Engram/Views/Pages/SourcePulseView.swift:512-528`). Even a correct
non-healthy verdict is not actionable.

## Goals / Non-goals

Goals:

- The source health verdict is computed over **index-eligible** (non-`skip`)
  sessions only, so `partial` means "something that should own a search-index row
  does not".
- Every non-`healthy` badge carries a one-sentence reason explaining the verdict,
  surfaced as a tooltip and an accessibility label.
- The `Search N%` pill on the same row uses the same denominator as the badge, so
  the two indicators cannot contradict each other.
- No user-visible session count or KPI changes.

Non-goals:

- **Changing what "searchable" means.** Today a session counts as searchable if
  it owns at least one `sessions_fts` row. That definition interacts with the
  10,000-message indexing cap and a deliberate Wave 7A L05 decision; revisiting
  it needs its own evidence pass. Only the *denominator* moves here.
- Fixing the residual gaps themselves. After this change 7 sources still have a
  residual coverage gap (see Acceptance criteria). Diagnosing why 288 of the 349
  gap sessions have no FTS job row at all is a separate investigation.

- **Renaming or re-denominating `tokenCoveragePercent`**
  (`macos/EngramService/Core/EngramServiceReadProvider.swift:1032-1034`). It keeps
  the raw `sessionCount` denominator and this is deliberate, not an oversight:
  token/cost attribution is genuinely not tier-gated on the write side — measured,
  29,661 of the 29,829 non-hidden `skip` sessions carry a `session_costs` row, so
  they really do incur cost and belong in a cost denominator. After this change
  the two adjacent pills (`Search N%` at
  `macos/Engram/Views/Pages/SourcePulseView.swift:296`, `Tokens N%` at `:301`)
  intentionally use different denominators. Acceptance criterion 9 pins
  `tokenCoveragePercent` unchanged.

- **Calling the new denominator "search-eligible".** The term is deliberately
  *index*-eligible. The non-`skip` set includes `lite` sessions, which own FTS
  rows but are contractually excluded from keyword *results* by invariant 3
  (`docs/invariants.md:21`) — measured, `kimi` is 140 lite of 212 index-eligible,
  `gemini-cli` 54 of 208, `qoder` 7 of 16. Naming the metric "search-eligible"
  would assert something invariant 3 forbids. The helper, the local, and both
  reason strings say "indexable"/"index-eligible" throughout.
- Any MCP change. Verified negative: `EngramMCP` never calls `sources()` (grep
  for `sources()` and `healthStatus` under `macos/EngramMCP` returns nothing);
  the `sources` command exists only in the app-facing dispatch at
  `macos/EngramService/Core/EngramServiceCommandHandler.swift:293`; and
  `docs/mcp-tools.md` contains zero occurrences of `health` or `searchable`
  (re-verified in the integration pass, 2026-07-24: both counts are 0).
  **`docs/mcp-tools.md` needs no update *for this spec*.** Note that
  `docs/insight-supersede-filter-design-2026-07.md` (row 1) *does* edit
  `docs/mcp-tools.md:124` and `:143`; acceptance criterion 8 below is scoped to
  this spec's own diff and is not a repo-wide freeze on that file.
- Unifying the per-source session count between MCP `stats` and the Sources page.
  They already differ (MCP `stats` applies `SessionVisibilityFilter.listVisibleSQL`;
  `sources()` does not). Pre-existing; out of scope; see Risks.
- Any schema change, migration, backfill, or write path. This is a read-side
  change inside `try await read { db in ... }`
  (`macos/EngramService/Core/EngramServiceReadProvider.swift:1009-1010`).

## Current state

At `main` commit `382693db`.

**The health ladder** is `sourceHealthStatus(sessionCount:searchableSessionCount:failedIndexJobCount:latestUsageStatus:)`
at `macos/EngramService/Core/EngramServiceReadProvider.swift:1832-1844`, in strict
precedence order:

1. `sessionCount == 0` → `"empty"` (`:1838`)
2. `latestUsageStatus == "critical"` → `"critical"` (`:1839`)
3. `failedIndexJobCount > 0` → `"attention"` (`:1840`)
4. `latestUsageStatus == "attention"` → `"attention"` (`:1841`)
5. `searchableSessionCount < sessionCount` → `"partial"` (`:1842`)
6. otherwise `"healthy"` (`:1843`)

Exactly one state is emitted per source, so exactly one reason is ever needed.
Branch 1 is unreachable from this provider: the driver query is a `GROUP BY
source` over `sessions`, so every returned row has `sessionCount >= 1`. A seventh
state, `"unknown"`, exists as the DTO default
(`macos/Shared/Service/EngramServiceModels.swift:506`, `:565`) and is emitted only
by the app's DB fallback (below).

**The denominator** is the driver query at
`macos/EngramService/Core/EngramServiceReadProvider.swift:1011-1016`:

```sql
SELECT source, COUNT(*) AS session_count, MAX(indexed_at) AS latest_indexed
FROM sessions WHERE hidden_at IS NULL GROUP BY source ORDER BY source
```

No tier filter. This same `session_count` is also the displayed "N sessions"
label (`macos/Engram/Views/Pages/SourcePulseView.swift:270`) and is summed into
the "Archived Sessions" KPI card (`:22`, `:33`). The query also decides which
source rows exist at all.

**The numerator** is `sourceSearchableCounts(_:)` at
`macos/EngramService/Core/EngramServiceReadProvider.swift:1696-1706`, guarded by
`tableExists("sessions_fts")` returning `[:]` (`:1697`):

```sql
SELECT s.source AS source, COUNT(DISTINCT f.session_id) AS count
FROM sessions_fts f JOIN sessions s ON s.id = f.session_id
WHERE s.hidden_at IS NULL GROUP BY s.source
```

**`searchCoveragePercent`** uses the same uncorrected denominator at
`macos/EngramService/Core/EngramServiceReadProvider.swift:1029-1031` and renders
as the `Search N%` pill directly under the badge
(`macos/Engram/Views/Pages/SourcePulseView.swift:296`). Three lines below it,
`tokenCoveragePercent` (`:1032-1034`) uses that same uncorrected denominator and
renders as the adjacent `Tokens N%` pill (`SourcePulseView.swift:301`); see
Non-goals for why it stays.

**Why skip has no FTS rows — the writer side.** FTS jobs are enqueued for every
tier *except* skip: `if tier != .skip, changeSet.flags.contains(.searchTextChanged)
{ kinds.append(.fts) }` at
`macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:807-808`. Existing
rows are deleted on the non-skip→skip transition (`:49-50`, `shouldDeleteIndexArtifacts`
at `:744`, `deleteIndexArtifacts` at `:752`) and swept at startup by
`StartupBackfills.reconcileSkipTierIndexArtifacts`
(`macos/EngramCoreWrite/Indexing/StartupBackfills.swift:891`), whose subquery is
`SELECT id FROM sessions WHERE COALESCE(tier, 'normal') = 'skip'` (`:892`) feeding
`DELETE FROM sessions_fts WHERE session_id IN (...)` (`:912`).

Note: the mirror's anchor `StartupBackfills.swift:843` is wrong. Line 843 is
inside `ftsContentSignature`; the skip exclusion there is `:845`, and the deletes
are `:892`/`:912`.

**`lite` is not skip.** `SessionSemanticSearchPolicy.searchableTierSQL` is
literally `"(s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))"`
(`macos/Shared/EngramCore/AI/SessionSemanticSearchPolicy.swift:28-30`). Its doc
comment says `lite` is "list-visible but FTS/vector-excluded" — true of *search
results*, false of *FTS row existence*. `lite` sessions do get FTS jobs
(`SessionSnapshotWriter.swift:807`) and measurably own rows: 250 of 299 lite
sessions have `sessions_fts` rows today. `searchableTierSQL` is a query-result
filter, used at 7 sites, all of them search paths
(`EngramServiceReadProvider.swift:611`, `:680`, `:920`;
`macos/EngramMCP/Core/MCPDatabase.swift:1360`, `:2179`, `:2236`;
`macos/Shared/EngramCore/AI/SessionVectorSearchAvailability.swift:191`). It has
never been used as a coverage metric.

**The correct predicate already exists** as a shared helper:
`SessionVisibilityFilter.nonSkipTierSQL` = `"(tier IS NULL OR tier != 'skip')"`
(`macos/Shared/EngramCore/Indexing/SessionVisibilityFilter.swift:12`) with an
aliased overload at `:15-18`. Semantically identical to
`COALESCE(tier,'normal') != 'skip'`. The file header comment already draws the
exact distinction this fix needs (`:5-8`). `EngramServiceReadProvider.swift`
already imports `EngramCoreRead`, so no build-graph work.

**The DTO.** `EngramServiceSourceInfo`
(`macos/Shared/Service/EngramServiceModels.swift:467`) is
`Codable, Equatable, Identifiable, Sendable`. Every init parameter after
`latestIndexed` is defaulted, `CodingKeys` is hand-written, `init(from:)` uses
`decodeIfPresent` with a fallback for each, and the encoder is synthesized. The
`liveSyncDisabled` field (`:488`, `:507`, `:545`, `:566`) is the exact precedent
for an additive optional field. There are 7 construction sites:

| site | role |
| --- | --- |
| `EngramServiceReadProvider.swift:1036` | production producer |
| `SourcePulseView.swift:141` | app DB fallback when `serviceClient.sources()` throws |
| `EngramServiceCoreTests/EngramServiceIPCTests.swift:1653`, `:2158` | whole-struct `XCTAssertEqual` expectations (literals span `:1652-1661` and `:2157-2166`) |
| `EngramTests/SourcesSyncTests.swift:31`, `:52` | DTO round-trip tests |
| `EngramTests/SourceCatalogTests.swift:42` | `liveSource` factory |

**The badge.** `healthBadge(_ status: String)` at
`macos/Engram/Views/Pages/SourcePulseView.swift:512-528`, carrying `@ViewBuilder`
on `:511`, is a bare `Text(status.uppercased())` pill (`:521`) with a color switch
and no `.help`, no `.accessibilityLabel`. Called once, at `:268`. The two sibling
pills in the same view *do* carry `.help` (`:294`, `:299`), so the tooltip pattern
is already house style in this file. Note for the source-text guard below:
`.accessibilityLabel` already appears in this file at `:58` (the archive-store
reveal button), so a whole-file `contains` check for it proves nothing.

## Proposed design

Three changes, all read-side.

### 1. Separate index-eligible denominator

Add a private per-source count alongside the existing helpers:

```swift
private func sourceIndexEligibleCounts(_ db: GRDB.Database) throws -> [String: Int] {
    let rows = try Row.fetchAll(db, sql: """
        SELECT source AS source, COUNT(*) AS count
        FROM sessions
        WHERE hidden_at IS NULL AND \(SessionVisibilityFilter.nonSkipTierSQL)
        GROUP BY source
    """)
    return sourceCountDictionary(rows)
}
```

Wire it into the `map` closure next to `:1026`, mirroring the existing lookup:

```swift
let indexEligible = indexEligibleCounts[source] ?? 0
```

**The `?? 0` default is load-bearing**, not defensive boilerplate: a source whose
sessions are 100% `skip` (`glm`, `deepseek`, `doubao`) produces no `GROUP BY` row
in the new query at all, so it only reaches branch 5 below via this default.
Writing `?? sessionCount` as a "safe fallback" silently disables branch 5 and
leaves those three sources `partial` forever.

and add the aliased predicate to the numerator at `:1700-1703`:

```sql
WHERE s.hidden_at IS NULL AND (s.tier IS NULL OR s.tier != 'skip')
```

written as `\(SessionVisibilityFilter.nonSkipTierSQL(alias: "s"))`.

**The driver query at `:1011-1016` is not touched.** `sessionCount` keeps its
current meaning. This is deliberate and load-bearing: filtering it would drop
`glm` (2,229 sessions, all skip), `deepseek` (526, all skip) and `doubao` (24,
all skip) out of the response entirely — none of the three exists in
`SourceCatalog`, so `mergedSourceRows`
(`macos/Engram/Views/Pages/SourcePulseView.swift:423-437`) would have no
catalog-only row to fall back to and they would vanish from the Sources page —
and it would move "Archived Sessions" from 33,494 to 3,665 and "Active Sources"
from 21 to 18.

The numerator change moves no number on *today's* data — measured, zero skip-tier
sessions currently hold FTS rows — but it is **structural, not cosmetic**: it is
what guarantees `searchableSessionCount <= indexEligibleCount`, so the ladder's
comparison and the existing `min(100, …)` clamp can never mask an inversion. It
also guards the documented leak window for sessions first classified as skip
before `reconcileSkipTierIndexArtifacts` runs
(`macos/EngramCoreWrite/Indexing/StartupBackfills.swift:881-890`, leak sentence
`:883-886`). Keep it; do not delete it as dead code — it has its own named test
(Test plan, "Numerator guard"). The `tableExists("sessions_fts")` guard at `:1697`
stays.

`searchCoveragePercent` (`:1029-1031`) switches to the index-eligible denominator,
with the existing zero guard changed from `sessionCount > 0` to
`indexEligible > 0`. This is in scope because leaving it produces a
self-contradicting row: `qwen` would render `HEALTHY` next to `Search 19%`
(271/1,438) where the correct figure is 271/271 = 100%.
`tokenCoveragePercent` on the next three lines (`:1032-1034`) is **not** changed;
see Non-goals.

### 2. `healthReason` on the DTO

Add one field to `EngramServiceSourceInfo`, mirroring `liveSyncDisabled`
precisely:

`liveSyncDisabled` has **five** edit points, not four (`:488`, `:507`, `:525`,
`:545`, `:566`); miss the third and the struct does not compile
(`'self.healthReason' not initialized before use`). Mirror all five:

- stored property `let healthReason: String?` (after `:488`)
- init parameter `healthReason: String? = nil` (after `:507`)
- `self.healthReason = healthReason` in the memberwise init **body** (after `:525`)
- `case healthReason` in `CodingKeys` (after `:545`)
- `healthReason = try container.decodeIfPresent(String.self, forKey: .healthReason)`
  in `init(from:)` (after `:566`)

**Every row produced by `SQLiteEngramServiceReadProvider.sources()` must carry
`healthReason == nil` exactly when `healthStatus == "healthy"`.** With that rule
6 of the 7 construction sites compile and pass unchanged, including the two
whole-struct `XCTAssertEqual` expectations at
`EngramServiceIPCTests.swift:1652-1661` and `:2157-2166` whose fixture produces a
healthy codex source. Any non-nil healthy reason forces both literals to be
edited in the same diff for no benefit. The rule is a property of the *producer*,
not of the type: the memberwise default (`healthStatus: String = "unknown"`,
`:507`) and the legacy decode fallback (`?? "unknown"`, `:566`) both yield
`unknown` + `nil`, and that combination is intentional and out of scope for the
rule — see acceptance criterion 5.

No `indexEligibleSessionCount` field is added to the DTO. The reason string
interpolates the numbers, and nothing else needs the value. Adding it would be a
field with one consumer that already has the string.

### 3. Health verdict returns its reason

Change the private helper at `:1832` to return both, and take the eligible count:

```swift
private func sourceHealth(
    sessionCount: Int,
    indexEligibleCount: Int,
    searchableSessionCount: Int,
    failedIndexJobCount: Int,
    latestUsageStatus: String?
) -> (status: String, reason: String?)
```

Ladder and exact strings, in evaluation order:

| # | condition | status | `healthReason` |
| --- | --- | --- | --- |
| 1 | `sessionCount == 0` | `empty` | `"No sessions indexed for this source yet."` |
| 2 | `latestUsageStatus == "critical"` | `critical` | `"Provider usage for this source is at a critical level."` |
| 3 | `failedIndexJobCount > 0` | `attention` | `"<n> index job(s) failed for this source. They retry on the next indexing pass."` |
| 4 | `latestUsageStatus == "attention"` | `attention` | `"Provider usage for this source needs attention."` |
| 5 | `indexEligibleCount == 0` | `empty` | `"All <sessionCount> sessions are subagent or noise sessions. They are searched through their parent session, not on their own."` |
| 6 | `searchableSessionCount < indexEligibleCount` | `partial` | `"<missing> of <indexEligibleCount> indexable sessions are missing search-index rows."` |
| 7 | otherwise | `healthy` | `nil` |

Rules embedded in that table, all deliberate:

- Branch 3 wins over branch 6 — a source with both failed jobs and a coverage gap
  reports only the jobs reason. That matches today's precedence; the reason
  describes the *winning* branch only. **This is not hypothetical**: measured,
  `claude-code` (481 failed jobs), `grok` (119), `codex` (9) and `antigravity` (4)
  all take branch 3, so the three largest sources stay orange after this change —
  with a reason string, but orange. Only 4 of the 7 residual-gap sources ever
  reach branch 6. Do not "fix" this by reordering the ladder; see Open questions.
- Branches 2 and 4 do not interpolate the usage metric or value. The usage pill
  rendered on the same row already shows them
  (`macos/Engram/Views/Pages/SourcePulseView.swift:305` onward), and interpolating
  them would widen the helper signature for no new information. Neither branch
  fires on today's real data: every latest `usage_snapshots` row is `observed`.
- Branch 6 is **descriptive, not causal**. Measured breakdown of the 349 residual
  gap sessions by `session_index_jobs` row with `job_kind='fts'`: 288 have no job
  row at all, 32 `failed_permanent`, 29 `not_applicable`. Any string blaming
  failed indexing would be wrong for 317 of 349 cases.
- Branch 5 is new. Without it, `glm`/`deepseek`/`doubao` fall through `0 < 0`
  into `healthy` and would render a green HEALTHY badge next to "2,229 sessions"
  and "Search 0%". Reusing the existing `empty` state costs no new badge color
  (`SourcePulseView.swift:518` already maps `"empty"` to `Theme.gray`) and makes
  branch 1's currently-unreachable state meaningfully reachable.

Call site `:1036` passes `healthReason:` from the tuple.

### 4. App fallback and badge rendering

`SourcePulseView.swift:141` (the DB fallback built from `db.sourceDistribution()`
when the service call throws) passes
`healthReason: "Service unavailable — counts were read directly from the local database."`
This is the state that renders the gray `UNKNOWN` pill; without it the stated
goal "every non-healthy badge says why" is false in exactly the situation users
are most confused by. All other construction sites keep the default.

`healthBadge` gains a second parameter and two modifiers:

```swift
@ViewBuilder
private func healthBadge(_ status: String, reason: String?) -> some View {
    // … unchanged color switch and Text(status.uppercased()) …
        .help(reason ?? status.uppercased())
        .accessibilityLabel(reason.map { "\(status.uppercased()): \($0)" } ?? status.uppercased())
}
```

The `@ViewBuilder` attribute on `:511` is **not** optional and must be kept: the
body is a `let color: Color = switch …` statement followed by the `Text` chain, so
without it the multi-statement body does not compile. It sits one line *above* the
literal `"private func healthBadge"`, so it is outside the slice used by the guard
test below and is safe to keep.

The `?? status.uppercased()` fallbacks are deliberate. `.help(reason ?? "")` would
install an empty tooltip on every healthy pill, and `.accessibilityLabel(status)`
would replace the rendered "HEALTHY" with the lowercase raw DTO value for
VoiceOver — an accessibility regression on the majority of rows, introduced by an
accessibility fix.

Call site `:268` becomes `healthBadge(source.healthStatus, reason: source.healthReason)`.

`.help` alone is not enough: it is invisible to VoiceOver and to XCUITest.
**`healthBadge` must stay above `usageColor` and both function names must stay
verbatim** — `macos/EngramTests/SourcePulseUsageFormattingTests.swift:93-107`
slices the source file between the literals `"private func healthBadge"` (`:99`)
and `"private func usageColor"` (`:100`) and will crash on a reversed range.

### Implementation slices

Ordered. Slice 1 is landable alone as a strict improvement, but leaves 8 sources
non-`healthy` with no explanation, so both slices should reach the same release.

**Slice 1 — predicate + the `empty` branch (service, read-only).**
Files: `macos/EngramService/Core/EngramServiceReadProvider.swift`,
`macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`,
`macos/EngramTests/SourcesSyncTests.swift`,
`docs/invariants.md`.
Add `sourceIndexEligibleCounts`, wire `indexEligibleCounts[source] ?? 0` at
`:1026`, add the aliased predicate to `sourceSearchableCounts`, switch the health
comparison and `searchCoveragePercent` to the index-eligible denominator, **and
insert `if indexEligibleCount == 0 { return "empty" }` immediately before the
`partial` comparison in `sourceHealthStatus`** (branch 5). Add both repro tests,
the numerator guard, the branch-5 test, the missing-FTS-table test, and the
predicate source-text guard. Amend invariant 3's Verified-by list.

**Branch 5 is in slice 1, not slice 2, and this is load-bearing.** It needs no DTO
field and no UI change — `SourcePulseView.swift:518` already maps `"empty"` to
`Theme.gray`. Without it, slice 1 alone is a *regression*, not a partial
improvement: for `glm`/`deepseek`/`doubao` the rewritten comparison becomes
`0 < 0` → false → falls through to `healthy`, so all three would ship a green
HEALTHY badge next to "2,229 sessions" and "Search 0%".

*Done when*: `testSourceHealthExcludesSkipTierSessions_repro` and
`testSourceHealthCountsLiteTierSessions_repro` fail on the parent commit and pass
on the branch **on their count/coverage assertions alone** (no `healthReason` is
referenced in slice 1 — that symbol does not exist yet);
`testSourceHealthExcludesSkipTierSessionsFromNumerator`,
`testSourceHealthReportsEmptyWhenAllSessionsAreSkipTier` and
`testSourceHealthSurvivesMissingFTSTable` pass;
`xcodebuild test` for the service and app test targets is green;
`bash scripts/check-invariants-ledger.sh` passes.

**Slice 2 — reason (DTO + service + UI).**
Files: `macos/Shared/Service/EngramServiceModels.swift`,
`macos/EngramService/Core/EngramServiceReadProvider.swift`,
`macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`,
`macos/Engram/Views/Pages/SourcePulseView.swift`,
`macos/EngramTests/SourcesSyncTests.swift`.
Add `healthReason` (all five DTO edit points), convert `sourceHealthStatus` to
`sourceHealth` returning the tuple with the strings above, pass a reason from the
app fallback, add `.help` + `.accessibilityLabel` to the badge. **Extend the two
slice-1 repro tests with their `healthReason` assertions here** — that is why
`EngramServiceIPCTests.swift` appears in both slices.
*Done when*: the three DTO tests below pass; the badge source-text guard passes;
`EngramServiceIPCTests.swift:1652-1661` and `:2157-2166` still pass **unedited**;
the app builds.

No new Swift file, so no `xcodegen generate`.

### Acceptance criteria

Falsifiable, checkable on the branch. Criteria 2, 3 and 10 are **service-path
only** — they describe `serviceClient.sources()`, not the app's DB fallback, which
already applies a different filter (see Risks).

1. **Machine-independent.** For every row returned by `sources()`,
   `searchableSessionCount <= indexEligibleCount`; and no source reports `partial`
   when every one of its non-hidden non-`skip` sessions owns a `sessions_fts` row.
   Check on whatever DB is at hand with:
   ```sql
   WITH elig AS (SELECT source, COUNT(*) c FROM sessions
                 WHERE hidden_at IS NULL AND (tier IS NULL OR tier != 'skip') GROUP BY source),
    srch AS (SELECT s.source src, COUNT(DISTINCT f.session_id) n FROM sessions_fts f
             JOIN sessions s ON s.id = f.session_id
             WHERE s.hidden_at IS NULL AND (s.tier IS NULL OR s.tier != 'skip') GROUP BY s.source)
   SELECT elig.source, elig.c, COALESCE(srch.n,0) FROM elig
     LEFT JOIN srch ON srch.src = elig.source WHERE COALESCE(srch.n,0) > elig.c;
   ```
   Expect zero rows. The per-source numbers below are *evidence*, not a gate.
2. **Author's machine, 2026-07-24, will drift.** Exactly 7 sources have a residual
   coverage gap: `claude-code` 1,181/1,247, `codex` 628/714, `copilot` 81/113,
   `gemini-cli` 65/208, `grok` 230/231, `kimi` 196/212, `pi` 107/112. Rendered
   through the full ladder that is **`partial` = {kimi, gemini-cli, pi, copilot}**
   (4), **`attention` = {claude-code, codex, grok, antigravity}** (4, all via the
   earlier failed-jobs branch; `antigravity` has no coverage gap at all),
   **`empty` = {glm, deepseek, doubao}** (3), **`healthy`** = the remaining 10.
   Orange badges go 18 → 8, not 18 → 7.
3. `glm`, `deepseek`, `doubao` report `empty`, still appear as rows on the
   Sources page, and still display their raw session counts (2,229 / 526 / 24).
   Verified by `testSourceHealthReportsEmptyWhenAllSessionsAreSkipTier`.
4. **Mechanically checkable, no app run needed.** `git diff` shows
   `EngramServiceReadProvider.swift:1011-1016` unchanged and `sessionCount:` still
   bound to `row["session_count"]`; `testSQLiteReadProviderSourcesExposeArchiveHealthFacts`
   still asserts `codex?.sessionCount == 2` (`EngramServiceIPCTests.swift:1737`)
   unedited. That pins the "Archived Sessions" KPI and every per-source
   "N sessions" label byte-identical to `main`.
5. For every row returned by `SQLiteEngramServiceReadProvider.sources()`,
   `healthReason == nil` if and only if `healthStatus == "healthy"`. The DTO
   memberwise default and the legacy decode both yield `unknown` + `nil`; that is
   intentional and explicitly **not** covered by this criterion.
6. Neither `SessionSemanticSearchPolicy.searchableTierSQL` nor
   `FTSRebuildPolicy.eligibleSessionSQLPredicate` appears anywhere in the diff.
7. `grep -rn "COALESCE" macos/EngramService/Core/EngramServiceReadProvider.swift`
   shows no newly hand-written tier predicate; both new predicates come from
   `SessionVisibilityFilter`.
8. `git diff --stat` touches no file under `macos/EngramCoreWrite/`,
   `macos/EngramMCP/`, or `docs/mcp-tools.md`.
9. `tokenCoveragePercent` is unchanged from `main` for every source. Pinned by the
   existing unedited `XCTAssertEqual(codex?.tokenCoveragePercent, 50)`
   (`EngramServiceIPCTests.swift:1742`).
10. On a database with no `sessions_fts` table, `sources()` still returns rows
    (the `tableExists` guard at `:1697` is intact). Verified by
    `testSourceHealthSurvivesMissingFTSTable`, which drops the table from the
    seeded fixture (`try db.execute(sql: "DROP TABLE sessions_fts")`) and asserts
    one `codex` row with `searchableSessionCount == 0`. The nearest existing test,
    `testReadOnlyAppFacingCommandsDoNotReturnUnsupportedCommand`
    (`EngramServiceIPCTests.swift:1604-1627`), does **not** cover this: it builds
    the handler with no read provider at all (`:1607`) and asserts
    `XCTAssertEqual(sources, [])` (`:1624`).

## Invariants affected

**Entry 3, Tier Visibility** (`docs/invariants.md:19-24`). Touched. Its Enforced-by
list already names `macos/EngramService/Core/EngramServiceReadProvider.swift` and
`macos/Shared/EngramCore/AI/SessionSemanticSearchPolicy.swift`, so no path edit is
needed. The change *strengthens* the entry: it makes a read surface consistent
with the skip exclusion the entry already mandates, and it must not blur the
skip-vs-lite distinction the entry encodes — hence the hard constraint against
`searchableTierSQL`. Add
`macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`
(`testSourceHealthExcludesSkipTierSessions_repro`,
`testSourceHealthCountsLiteTierSessions_repro`,
`testSourceHealthExcludesSkipTierSessionsFromNumerator`,
`testSourceHealthReportsEmptyWhenAllSessionsAreSkipTier`) to its Verified-by list
in the same PR. Gate remains `none`; the only executable gate is `ledger-paths`, and
every backticked path in the amended entry exists.

**Cross-spec collision on `docs/invariants.md:23` (integration pass,
2026-07-24).** `docs/codex-native-parentage-design-2026-07.md` (row 22, slice 4)
amends the **same** entry-3 `Verified by` line, adding
`testBackfillCodexNativeParentsDeletesFtsRowsWhenTierBecomesSkip`. The two
additions are a union — neither removes the other's names — but they are a
line-level merge conflict if landed in parallel. The recorded sequence puts this
spec **before** row 22, so row 22 rebases onto the already-amended line. Row 1
(`docs/insight-supersede-filter-design-2026-07.md`) appends a *new* entry 14 and
touches no existing entry, so it does not collide with either.

**Entry 2, Subagent Sessions Stay Skip** (`docs/invariants.md:12-17`). Cited, not
modified. It is the by-design reason skip sessions own no FTS rows. This change
writes no tier and opens no writer.

No new invariant. An S-effort badge fix does not warrant a ledger entry.

## Alternatives considered

**Reuse `SessionSemanticSearchPolicy.searchableTierSQL` on both sides.** Rejected
by the hard constraint and by measurement: it also excludes `lite`, and 250 lite
sessions currently own FTS rows. It would drop 299 denominators and 250
numerators, permanently hiding 49 genuinely-missing lite rows — concentrated in
`gemini-cli` (36), `kimi` (11), `claude-code` (2). Structurally it is also the
only non-search use it would ever have had.

**Apply `searchableTierSQL` to the denominator only.** Rejected, and this is the
cancelling blind spot the two errors would create: measured, 6 sources invert to
numerator > denominator and read `HEALTHY` — `kimi` 196 ≥ 72 while 16 non-skip
sessions have no FTS row, `pi` 107 ≥ 95 with 5 missing, plus `grok` 230 ≥ 225,
`opencode` 251 ≥ 246, `qwen` 271 ≥ 265, `qoder` 16 ≥ 9. `searchCoveragePercent`
would clamp to 100 via the existing `min(100, …)`.

**Reuse `FTSRebuildPolicy.eligibleSessionSQLPredicate`** (`COALESCE(s.tier,'normal')
!= 'skip' AND s.hidden_at IS NULL AND s.orphan_status IS NULL`,
`macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift:134-140`). The most
plausible-looking wrong answer, because it is named "eligible". Rejected: on this
machine most non-skip sessions carry a non-null `orphan_status`, which would
collapse `claude-code`'s health denominator to 13 and `codex`'s to 23, and orphan
sessions do overwhelmingly have FTS rows.

**Tier-filter the existing `sources()` driver query.** Rejected: it is the
literal reading of the mirror's one-line prescription and it is a regression —
three source rows disappear from the UI, "Archived Sessions" drops 33,494 → 3,665,
"Active Sources" 21 → 18.

**Delete the `partial` state entirely.** Rejected: 7 sources retain a real
residual coverage gap after the fix (4 of them rendering `partial`, 3 outranked by
the failed-jobs branch), including `gemini-cli` at 65/208, which is a real signal
the current noise was masking.

**Add `indexEligibleSessionCount` to the DTO.** Rejected as a single-use field.
The reason string already carries the numbers to the only consumer.

**Move `tokenCoveragePercent` to the index-eligible denominator too.** Raised by
review on the grounds that Goal 3 ("adjacent indicators must share a denominator")
applies verbatim to the `Search N%` / `Tokens N%` pill pair
(`macos/Engram/Views/Pages/SourcePulseView.swift:296` and `:301`). Rejected on
measurement: 29,661 of the 29,829 non-hidden `skip` sessions carry a
`session_costs` row, so `skip` sessions genuinely incur cost and belong in a cost
denominator — unlike search-index rows, which the writer deliberately never
creates for them. Goal 3's argument is about a metric contradicting *its own
badge*, not about two unrelated metrics sharing a row. Recorded as a Non-goal with
acceptance criterion 9 pinning it unchanged.

**Reviewer claim rejected on the evidence.** One review reported the whole-struct
assertion at `EngramServiceIPCTests.swift` as spanning `:1652-1662`. Verified: the
literal opens at `:1652` (`XCTAssertEqual(sources, [`) and closes at `:1661`
(`])`); `:1662` is the function's closing brace. The corrected range used
throughout this doc is `:1652-1661`. The same reviewer's other five anchor
corrections were correct and have been applied.

## Test plan

All service-side tests live in
`macos/EngramServiceCoreTests/EngramServiceIPCTests.swift` and are built on the
existing helpers `makeServiceIPCPaths()` (`:5523`) and `seedSearchFixture(at:)`
(`:5565`) — the fixture creates a `sessions` table with a `tier` column (`:5594`)
and a real `sessions_fts` trigram virtual table (`:5636`), seeded with two codex
sessions `s1`/`s2` (tier NULL) each owning one FTS row (`:5661-5662`). Layer extra
rows on with `DatabaseQueue(path:)` + `db.execute(sql:)`, exactly as
`testSQLiteReadProviderSourcesExposeArchiveHealthFacts` (`:1664-1761`) does; the
skip-plus-FTS seed shape to copy is in
`testSQLiteReadProviderSearchExcludesSkipAndLiteSessions` (`:1962-1986`,
`INSERT INTO sessions_fts(session_id, content) VALUES ('s-skip', …)` at `:1976`).
The base fixture creates neither `session_index_jobs` nor `usage_snapshots`, so
the ladder falls straight through past branches 2–4 to the coverage comparison,
isolating the branch under test.

**Repro tests** (fail on the parent commit, pass on the branch). *In slice 1 they
assert only counts, coverage, and status — `healthReason` does not exist until
slice 2, so referencing it in slice 1 is a compile error, not a repro.*

1. `func testSourceHealthExcludesSkipTierSessions_repro()` — insert `s3`, source
   `codex`, `tier='skip'`, no `sessions_fts` row. Assert
   `healthStatus == "healthy"`, `searchableSessionCount == 2`,
   `searchCoveragePercent == 100`. Before the fix: `"partial"`, coverage 67.
   *Slice 2 adds:* `healthReason == nil`.
2. `func testSourceHealthCountsLiteTierSessions_repro()` — insert `s4`
   (`tier='lite'`, **with** an FTS row), `s5` (`tier='lite'`, **without**), and
   `s6` (`tier='skip'`, **without**). Assert `searchCoveragePercent == 75` and
   `searchableSessionCount == 3`. *Slice 2 adds:* the reason contains
   `"1 of 4"`.

   The `s6` skip row is what makes this a genuine repro rather than a guard: on
   the parent commit the denominator is `COUNT(*)` over all 5 non-hidden sessions
   → 3/5 → coverage **60**; on the branch the denominator is the 4 index-eligible
   sessions → 3/4 → coverage **75**. Without `s6`, parent and branch both compute
   4/3 → `partial`, coverage 75, and nothing flips.

   `searchableSessionCount == 3` is the anti-`searchableTierSQL` assertion and is
   deliberately on counts, not on the verdict: both the correct predicate and the
   forbidden `searchableTierSQL` produce identical `partial` verdicts on today's
   real data, so a verdict-only test would go green with the wrong predicate.
   Under `searchableTierSQL` this test sees 2/2 → `healthy`, coverage 100, and
   fails on both assertions.

Both get a comment above them referencing the PR, per CLAUDE.md.

**Numerator guard** — `func testSourceHealthExcludesSkipTierSessionsFromNumerator()`.
The aliased predicate added to `sourceSearchableCounts` is production code and
must not ship unexercised. Copy the seed from `:1969-1977`: insert `s-skip`
(`tier='skip'`) **plus** an `INSERT INTO sessions_fts(session_id, content)` row for
it, call `provider.sources()`, assert `searchableSessionCount == 2`. Without the
numerator predicate it is 3. Neither repro test above covers this — neither seeds
a skip session that owns an FTS row.

**Branch-5 test** — `func testSourceHealthReportsEmptyWhenAllSessionsAreSkipTier()`.
The verifier for acceptance criterion 3, and the only test that exercises the
branch that changes the verdict for `glm`/`deepseek`/`doubao`. Insert a session for
a *new* source (`('g1', 'glm', …, tier='skip')`) with no FTS row; assert the `glm`
row has `sessionCount == 1`, `searchableSessionCount == 0`,
`searchCoveragePercent == 0`, `healthStatus == "empty"`. Without branch 5 this
returns `"healthy"`.

**Missing-FTS-table test** — `func testSourceHealthSurvivesMissingFTSTable()`. The
verifier for acceptance criterion 10: seed the fixture, `DROP TABLE sessions_fts`,
call `sources()`, assert one `codex` row with `searchableSessionCount == 0`.

**Predicate source-text guard**, in `macos/EngramTests/SourcesSyncTests.swift`
using its existing repo-relative `source(_:)` helper (`:12-14`): read
`macos/EngramService/Core/EngramServiceReadProvider.swift`, slice it between the
literals `"private func sourceIndexEligibleCounts"` and the following
`"private func sourceSearchableCounts"` … end of `sourceSearchableCounts`, and
assert the slice contains `SessionVisibilityFilter.nonSkipTierSQL` and contains
neither `searchableTierSQL` nor `'lite'`. Cheap insurance against a future
refactor "unifying" the two predicates.

*This guard cannot live in `macos/EngramCoreTests/SessionVisibilityFilterTests.swift`
as an earlier draft proposed.* That target's dependencies are `EngramCoreRead`,
`EngramCoreWrite`, GRDB only (`macos/project.yml:70-74`) — it cannot see anything
under `EngramService`. And the design introduces no new named predicate symbol
(the queries interpolate `SessionVisibilityFilter.nonSkipTierSQL` inline), so the
only assertions available there — "is the `nonSkipTierSQL` form and does not
contain `lite`" — already exist verbatim at
`SessionVisibilityFilterTests.swift:7-10` and `:26-30`. No file under
`macos/EngramCoreTests/` is touched by this change.

**DTO tests** (slice 2), in `macos/EngramTests/SourcesSyncTests.swift`, mirroring
the three existing `liveSyncDisabled` tests at `:30-54`: round-trip a non-nil
`healthReason`; assert the legacy JSON
`{"name":"codex","sessionCount":3,"healthStatus":"healthy"}` decodes with
`healthReason == nil`; assert the memberwise init defaults it to `nil`.

**Badge source-text guard** (slice 2), same file, following
`testSourcePulseRendersCacheOnlyPillGatedOnFlag` (`:58-62`). Do **not** write a
whole-file `contains` check: `.accessibilityLabel` already exists in
`SourcePulseView.swift` at `:58`, so that half would pass on the parent commit and
guard nothing. Slice the file between `"private func healthBadge"` and
`"private func usageColor"` — the technique already used at
`macos/EngramTests/SourcePulseUsageFormattingTests.swift:99-101` — and assert the
slice contains `.accessibilityLabel`, `.help(`, and `reason`. Also assert
whole-file that `SourcePulseView.swift` contains `source.healthReason` (which is at
the call site `:268`, outside the slice).

**Regression check, not a new test**: `EngramServiceIPCTests.swift:1652-1661` and
`:2157-2166` must pass **without edits**. If they need editing, the
nil-for-healthy rule was broken.

**Not tested and why**: the rendered tooltip. There is no unit harness for
`.help()` in this repo — the only SourcePulse UI coverage is XCUITest smoke tests
(`macos/EngramUITests/Tests/FullTests/SourcePulseTests.swift`) and the source-text
slice test. The source-text guard is the available substitute.

## Rollout

No version bump, no migration, no backfill. Rebuild and redeploy `Engram.app`
plus the bundled `EngramService`; the new verdict takes effect on the next
`sources()` call, i.e. the next time the Sources page loads. Nothing is persisted,
so there is no stale state to reconcile.

Perf: the numerator is already a full scan over `sessions_fts` (`session_id` is
`UNINDEXED`, ~330k rows) and `sources()` already costs roughly a third of a second
per load. Adding the tier predicate measured no meaningful change, and the new
per-source eligible count is an indexed aggregate over `sessions`. No perf work is
needed; the pre-existing cost is worth not compounding.

Revert: revert the diff. There is no stored artifact and no forward-compat
concern — an old app decoding a new payload ignores the extra key, and a new app
decoding an old payload gets `healthReason == nil`, which renders as today.

## Risks and open questions

**Risk — the mirror's one-liner gets implemented literally** (high). "Exclude
skip from both numerator and denominator" reads like an edit to `:1011-1016`.
That deletes three source rows from the UI and drops the Archived Sessions KPI by
89%. Mitigation: acceptance criteria 3 and 4 are stated as pass/fail.

**Risk — reaching for the wrong named-right predicate** (high). Both
`searchableTierSQL` and `FTSRebuildPolicy.eligibleSessionSQLPredicate` sound
correct and are measurably wrong. Mitigation: acceptance criterion 6, the predicate
source-text guard, plus repro
test 2, which asserts counts specifically because verdicts do not discriminate.

**Risk — slice 1 ships alone** (medium). Eight sources stay orange with no
explanation (four `partial`, four `attention` via the failed-jobs branch); the
user-visible outcome is "fewer orange badges, still no reason", which does not
close the finding. Mitigation: both slices in one release.

**Risk — branch 5 gets deferred out of slice 1** (high). It looks like reason-copy
work and reads as belonging with the DTO change. It does not: without it, slice 1
turns `glm`/`deepseek`/`doubao` **green** because the rewritten comparison is
`0 < 0`. That is a worse user-visible state than `main`. It is in slice 1 for this
reason, needs no DTO field, and has its own named test.

**Risk — the numerator predicate gets deleted as dead code** (medium). It moves no
number on today's data and a future reader will correctly observe that. It is what
guarantees `searchableSessionCount <= indexEligibleCount`.
`testSourceHealthExcludesSkipTierSessionsFromNumerator` exists specifically so the
deletion fails CI.

**Risk — non-nil healthy reason** (medium). Breaks two whole-struct
`XCTAssertEqual` assertions with a whole-struct diff that reads as unrelated, and the
likely "fix" is to weaken the assertions rather than restore the rule.

**Open question — is `empty` the right badge word for a 100%-skip source?**
`glm` will render a gray `EMPTY` pill next to "2,229 sessions". The reason string
explains it and the alternative (`healthy` + reason) is arguably worse, but this
is a copy/product call the spec author made without approval. Revisit if the
badge reads wrong in the app.

**Open question — approved copy for the six reason strings.** The strings above
are evidence-shaped, not reviewed. Branch 6's wording in particular must not
acquire a causal clause during review; 317 of 349 real cases are not failures.

**Open question — should `failedIndexJobCount` (`:1708-1726`) get the same skip
filter?** It has no tier filter either. Measured: zero skip-tier sessions
currently own a failed job (failed jobs today are 479 premium, 115 normal, 19
lite), so it changes nothing now. Latent inconsistency; deliberately not widened
here.

**Open question — does the failed-jobs branch deserve to outrank the coverage
branch?** It is the reason this change moves `claude-code`, `codex`, `grok` and
`antigravity` from orange to *a different orange* rather than to green: 481 / 9 /
119 / 4 failed jobs respectively win at `:1840` before `:1842` is evaluated. The
ladder's precedence is preserved as-is here because reordering it is a product
call with no evidence behind it yet, and because those failed jobs are very likely
the same signal as the 288 gap sessions with no FTS job row (next question).
Revisit only after that investigation.

**Open question — why do 288 of the 349 residual gap sessions have no FTS job row
at all?** Per source: `gemini-cli` 143, `codex` 80, `copilot` 32, `claude-code`
17, `kimi` 16. `gemini-cli` alone is 41% of the entire post-fix residual gap. This
is very likely a real indexing bug and needs its own investigation; it is exactly
the signal the current noise was hiding.

**Open question — is the heavy `orphan_status` population on this machine
representative?** It decides whether the `FTSRebuildPolicy` alternative is
universally wrong or only wrong here. Not investigated.

**Known inconsistency, not fixed here — the app's own fallback already disagrees.**
`SourcePulseView.loadData` falls back to `db.sourceDistribution()` when
`serviceClient.sources()` throws (`macos/Engram/Views/Pages/SourcePulseView.swift:139-141`),
and that query applies `SessionVisibilityFilter.listVisibleSQL`
(`macos/Engram/Core/Database.swift:1175-1181`). So whenever the service call fails
today, `glm`/`deepseek`/`doubao` already vanish from the page and "Archived
Sessions" already reads ~3,665 — the exact state acceptance criteria 3 and 4 forbid
on the service path. Those criteria are therefore scoped to the service path only.
Not unified here: doing so is the display regression argued against above, in the
opposite direction.

**Known inconsistency, not fixed here**: MCP `stats` already applies
`SessionVisibilityFilter.listVisibleSQL` to its per-source session count
(`macos/EngramMCP/Core/MCPDatabase.swift`), while `sources()` does not — so
`claude-code` reads 1,247 sessions via MCP and 18,372 on the Sources page. A
reviewer may ask for this to be unified mid-review. Unifying it *is* the display
regression described above. Decline and file separately.
