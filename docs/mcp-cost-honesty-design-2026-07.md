# Design Doc: MCP Cost Honesty

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog rows 3 (F2), 4 (F9),
  14 (F8). Composes with the accepted baseline specs that share files touched
  here: `docs/source-health-predicate-design-2026-07.md` (row 2) and
  `docs/adapter-format-drift-design-2026-07.md` (row 23) — see "Cross-spec
  coordination". All code citations are at HEAD `23dca547`; concurrent
  implementation will drift line numbers, which is expected.

One theme, three independently landable parts: **every cost figure Engram
publishes must be either correct or explicitly refused.** Today three figures
are silently wrong or silently incomplete:

- `get_insights` projects a 30-day monthly pace by dividing any window's spend
  by a hardcoded 7 — a 30-day `since` over-projects ~4.3x, a 1-day `since`
  amplifies noise ~10x (Part A).
- Both cost readers `SUM(cost_usd)` beside `COUNT(*)` with no signal that 1,929
  of 26,190 token-carrying rows (7.6% of tokens) are unpriced — and the two
  distinct bugs behind that number are conflated (Part B).
- The pricing table is compile-time only; a correction to a wrong price cannot
  be applied without a rebuild-and-ship cycle (Part C).

A reader implementing only one part can ignore the other two. Part A gains one
optional refusal reason only if Part B lands first; that coupling is called out
explicitly and the reason is cut cleanly if the parts land apart.

## Problem

Measured read-only against `~/.engram/index.sqlite` on 2026-07-24:

| Measurement | Value |
| --- | --- |
| Token-carrying `session_costs` rows | 26,190 |
| Unpriced (`COALESCE(cost_usd,0)=0`) | 1,929 (7.6% of tokens) |
| — cause A: `model IS NULL` (attribution defect) | 867 |
| — cause B: model present, no price (table gap) | 1,062 |
| Largest cause-B bucket: `gpt-5.6-sol` | 781 |
| Cause-A rows by source: opencode / kimi / copilot / cursor / codex / gemini-cli | 385 / 270 / 207 / 3 / 1 / 1 |

Three honesty failures follow:

1. **`get_insights` over-projects.** `projectedMonthly = (totalSpent / 7.0) *
   30.0` (`macos/EngramMCP/Core/MCPInsightsTool.swift:7`) divides by a constant
   7 regardless of the actual window. A 30-day `since` reports ~4.3x the real
   monthly pace; a 1-day `since` multiplies a single day's noise. The `>$50`
   "Monthly pace" advice (`:24-25`) is gated on this wrong number. `since` is
   documented as supported (`docs/mcp-tools.md:373-375`).

2. **Unpriced spend is invisible and its two causes are conflated.** Both
   readers report a total that silently drops NULL-cost rows, and a
   `sessionCount` that silently includes them (`MCPDatabase.swift:231-272`;
   `EngramServiceReadProvider.swift:1140-1156`). A window whose spend is entirely
   unpriced returns `$0` beside real token usage. The 867 attribution-defect rows
   (a write-time bug) and the 1,062 table-gap rows (a pricing bug) need different
   fixes; one counter hides both.

3. **Prices are frozen at compile time.** `SessionCostPricing.tableVersion = "3"`
   is a source constant (`SessionCostPricing.swift:12`). `cost_usd` feeds
   get_costs, cost insights, and the app cost dashboard. A wrong or missing price
   (e.g. `gpt-5.6-sol`) cannot be corrected without editing Swift and shipping a
   build.

### Mirror corrections (recorded per evidence discipline)

- **The 867 rows carry `model IS NULL`, not an empty string.** The brief said
  "EMPTY model string". The writer stores `NULLIF(?, '')`
  (`macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:457,477`), so any
  empty model collapses to NULL at write time; a re-measure found **zero**
  empty-string rows in the unpriced cohort. The cause-A predicate must be
  `model IS NULL OR model = ''`, never `model = ''`.
- **The pricing-gap bucket is 1,062 rows, not 781.** `gpt-5.6-sol` (781) is only
  the largest; the tail includes `openai` (71), `grok-4.5-build` (35),
  `grok-4.5` (28), `doubao-seed-2.0-code` (28), and others. Cause B must be a
  general "model present but unpriced" bucket, not a `gpt-5.6-sol` special case.
- **A price *correction* does not flow through the `COALESCE(cost_usd,0)=0`
  predicate.** The brief implied it does. `backfillCosts` uses that predicate
  only in the version-**matched** steady-state branch, which cannot re-price an
  already-nonzero row; corrections flow only through the version-**mismatch**
  `1 = 1` full-recompute branch (`StartupBackfills.swift:554-555`). Part C's
  effective-version bump is essential precisely for this reason.

## Goals / Non-goals

**Goals**

- A (row 3): `get_insights` divides window spend by the actual window length, and
  withholds the projection with a named reason when the window is too short to
  project honestly.
- B (row 4): both cost readers and their DTOs disclose the unpriced count split
  by cause; the app cost dashboard and MCP `get_costs` surface it; docs updated.
- C (row 14): a local `~/.engram/prices.json` overlay, read service-side, whose
  presence/update forces the existing full cost recompute exactly once per
  correction.

**Non-goals**

- Fixing the adapter-side model-attribution defect (opencode/kimi/copilot emit
  `model: nil`). Part B *discloses* the 867 rows; it does not fix them. The fix
  is adapter work with a re-parse dependency (see Risks) and is filed as a
  separate row. Copilot is the sharpest lead — `shutdownUsage` iterates
  `modelMetrics.values` and discards the model **key** the dict is keyed by
  (`macos/Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift:369`) — but
  even fixing it would not backfill existing rows without a forced re-index.
- A remote prices fetch. A default-off network fetch would amend the enumerated
  network features in `docs/PRIVACY.md:70-80` for no local benefit. Local overlay
  only; reading a local file is not a network call and needs no privacy
  amendment.
- Per-`SourceRow` cause granularity in the costs DTO. Top-level two-cause counts
  disclose both bugs; per-source attribution is a diagnostic query, not a
  headline number (see Alternatives).
- Any TypeScript / `src/` change. Pricing and both readers are Swift-only product
  paths; TS cost code is reference-only per CLAUDE.md.
- Adding `gpt-5.6-sol` to the compile-time table as part of this doc. Part C
  makes it a `prices.json` entry; whether to also hardcode it is a separate
  pricing-content decision.

## Current state

Anchors verified at HEAD `23dca547` on 2026-07-24.

**Projection (Part A).** `MCPInsightsTool.result` is the entire tool
(`macos/EngramMCP/Core/MCPInsightsTool.swift:4-47`): `effectiveSince = since ??
iso8601DaysAgo(7)` (`:5`), `totalSpent = totalCostSince(effectiveSince)` (`:6`),
`projectedMonthly = (totalSpent / 7.0) * 30.0` (`:7`). The `>$50` advice reads
"current 7-day spend" (`:25`). `iso8601DaysAgo` calls `Date()` directly (`:59`)
— **not** `contextNow()`. `contextNow()` (which honors `ENGRAM_MCP_NOW`) is a
file-**private** free function in `MCPDatabase.swift:2540-2550`, unreachable from
`MCPInsightsTool.swift` today. The output schema is `required:["content"]`,
content items `required:["type","text"]`, both `additionalProperties:false`
(`macos/EngramMCP/Core/MCPOutputSchemas.swift:67-69`) — no structured field is
possible; a refusal must be prose inside `content[0].text`.

`totalCostSince` `SUM`s `cost_usd` and cannot see unpriced rows
(`MCPDatabase.swift:1569-1584`). A sibling projection with the same `/7.0`
literal lives in the get_context cost-suggestions path (`MCPDatabase.swift:1826`)
but there the window is a **fixed** `sevenDaysAgo` (`:1660,:1693`), so its `/7`
is arithmetically **correct** and out of scope for Part A.

The get_insights golden test passes `{"since":"2026-02-15T…"}` (~160-day window)
against an empty-costs fixture and runs **without** `ENGRAM_MCP_NOW`
(`macos/EngramMCPTests/EngramMCPExecutableTests.swift:2980-2988`;
`tests/fixtures/mcp-golden/get_insights.empty.json`). It stays byte-identical
under Part A because $0 spend yields a $0 projection at any window length, and
the withholding path never fires at a 160-day window.

**Readers and DTO (Part B).** MCP `getCosts` selects `SUM(c.cost_usd) AS costUsd,
COUNT(*) AS sessionCount` grouped, over `session_costs c JOIN sessions s … WHERE
s.hidden_at IS NULL` (`MCPDatabase.swift:231-242`), returning
`totalCostUsd/totalInputTokens/totalOutputTokens/breakdown` (`:267-272`). Service
`costs()` does the identical shape per source (`EngramServiceReadProvider.swift:1140-1156`).
The MCP output schema is `additionalProperties:false` with a `required` array at
both the top object and each breakdown item (`MCPOutputSchemas.swift:35-37`),
runtime-enforced by `testStructuredContentMatchesDeclaredOutputSchema`
(`EngramMCPExecutableTests.swift:411`); the byte golden is
`tests/fixtures/mcp-golden/get_costs.project.json`. The DTO
`EngramServiceCostsResponse` and its `SourceRow` are synthesized-Codable/Equatable
value types (`macos/Shared/Service/EngramServiceModels.swift:2674-2693`).
`session_costs.model` is nullable and `cost_usd REAL DEFAULT 0`, but
`computeCost` returns `Double?` and nil binds as SQL NULL, so unpriced rows are
NULL, not 0 (`SessionSnapshotWriter.swift:503`); the disclosure predicate must
treat both alike via `COALESCE(cost_usd,0)=0`. The app renders costs in exactly
one view, `CostSummarySection` (display-only,
`macos/Engram/Views/Usage/CostSummarySection.swift:9-54`), hosted only by
`SourcePulseView`, which forwards the whole DTO opaquely. The service reader is
test-locked by `testCostsTreatNullCostRowsAsZero`
(`macos/EngramServiceCoreTests/EngramServiceCostsTests.swift:126-145`), which
already seeds a priced + NULL-cost pair and asserts `sessionCount = 2`,
`costUsd = 1.25`.

**Pricing and recompute (Part C).** `computeCost` returns nil for any model
`resolvedPrice` can't resolve (`SessionCostPricing.swift:113-119`); the choke
point both bugs flow through. Prices are static `let` dictionaries; tiered prices
use `ResolvedPrice{price, tier: .threshold(272_000, rate)}` expanded to per-field
`TierRate{threshold, rate}` (`:50-78,280-304`), applied in `cost(tokens:baseRate:tier:)`
(`:269-278`). Four-flat-doubles cannot express the 272K tier. `computeCost` is
called from exactly two write paths, both service-side in `EngramCoreWrite`:
index-time upsert (`SessionSnapshotWriter.swift:471`) and startup recompute
(`StartupBackfills.swift:595`). No app-side or MCP-side pricing exists.
`backfillCosts` (`StartupBackfills.swift:548-616`) reads the stored version from
metadata key `session_cost_pricing_version` (`:552`), sets
`recomputeAllTokenRows = storedVersion != SessionCostPricing.tableVersion` (`:554`),
`costPredicate = recomputeAllTokenRows ? "1 = 1" : "COALESCE(c.cost_usd,0)=0"`
(`:555`), and stamps the version current only after a full recompute
(`markCostPricingVersionCurrent`, `:618-626`, writing the bare `tableVersion`).
The live DB's stored value is currently `"3"` (in sync; no pending recompute).
`backfillCosts` recomputes model from `COALESCE(NULLIF(c.model,''),
NULLIF(s.model,''))` (`:561`), so it cannot rescue the 867 dual-NULL rows —
confirming Part B's disclosure and the adapter fix are independent.

## Proposed design

Minimum per part. Each part is a standalone PR.

### Part A — `get_insights` projection refusal (row 3)

Two edits, both in `MCPInsightsTool.swift`, plus one visibility change.

1. **Make the tool clock-injectable.** Remove `private` from `contextNow()` in
   `MCPDatabase.swift:2540` (one word; it becomes module-internal in `EngramMCP`).
   In `MCPInsightsTool`, compute `let now = contextNow()`; derive the default
   window from it (`effectiveSince = since ?? iso8601String(now - 7 days)`) so the
   default path is clock-consistent, and parse `effectiveSince` to a `Date` with
   the same dual-formatter fallback `contextNow` uses.

2. **Divide by the real window and withhold when too short.**

   ```
   windowDays = max(day-count(from: effectiveSince, to: now), 0)
   if windowDays >= 3:
       projectedMonthly = (totalSpent / Double(windowDays)) * 30.0   // honest
   else:
       withhold — emit no figure
   ```

   Only the withhold branch changes wording. When `windowDays >= 3` the
   Period-summary line stays **byte-identical** to today's format —
   `**Period summary:** Spent $X · Projected monthly $Y` — and only `$Y` moves
   from `(totalSpent/7.0)*30` to `(totalSpent/windowDays)*30`; do not reword the
   non-withhold line (the empty-costs golden asserts this exact string). When
   withholding, the line reports the spend and replaces the projection with a
   named refusal, e.g.
   `**Period summary:** Spent $X over N day(s) · Projected monthly: withheld
   (window under 3 days — too short to project)`, and the `>$50` advice is
   suppressed. The refusal is plain prose inside `content[0].text` — no schema
   change. The default (no `since`) path yields `windowDays = 7`, so the default
   experience is unchanged except that the number is now arithmetically correct
   for non-7-day windows.

**Refusal reasons.** Reason 1 (**window under 3 days**) is the core, and is fully
self-contained. Reason 2 (**future/zero-length `since`**, `windowDays == 0`) is
folded into reason 1's `< 3` guard (no division, withhold). Reason 3
(**window is unpriced-dominant**: real token usage but `totalSpent` is $0 or
near-$0 because the spend is unpriced) is **only implementable with Part B's
data** — `totalCostSince` cannot see unpriced rows. Decision: **Part A ships
reasons 1+2 only.** Reason 3 lands with Part B (or a follow-up) as a one-line
addition once a shared `unpricedTokensSince(window)` helper exists; specified
here, cut from Part A's diff so the parts stay independent.

`since` parse failure: withhold with "could not parse `since`" rather than
silently running the lexical SQL with an unknown window.

**Not touched:** the `MCPDatabase.swift:1826` get_context projection (fixed
7-day window, `/7` is correct) — stated explicitly so the discrepancy does not
read as a missed fix.

#### Part A — Implementation slices

- **A1 — clock + window.** Un-`private` `contextNow()`; wire `now`, parse
  `effectiveSince`, compute `windowDays`, divide by it. Add the withhold branch
  and suppress the `>$50` advice under withhold.
- **A2 — tests.** Repro + golden guard (below). Update
  `docs/mcp-tools.md:373-375`.

#### Part A — Acceptance criteria

1. With `ENGRAM_MCP_NOW` fixed and a seeded window of exactly 30 days carrying
   $30 priced spend, `projectedMonthly` is `$30.00` (± rounding), **not**
   `$128.57`.
2. With `ENGRAM_MCP_NOW` fixed and `since` = now − 2 days, the output contains no
   projected dollar figure and contains the substring "too short to project"; the
   `>$50` advice bullet is absent.
3. `testGetInsightsMatchesGolden` (160-day window, $0 spend, no `ENGRAM_MCP_NOW`)
   still passes byte-identically.
4. Default call (no `since`) over a fixture with $70 spread across 7 days reports
   `projectedMonthly = $300.00`.

### Part B — unpriced disclosure split by cause (row 4)

Read-side aggregation only; **no schema migration** (the split is expressible in
pure SQL on existing columns).

**Cause split (both readers).** Add two sibling aggregates over the same JOIN,
qualified on `tokens > 0` so a legitimately zero-usage $0 session is never
flagged:

```sql
SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
         AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
         AND (c.model IS NULL OR c.model = '')
    THEN 1 ELSE 0 END)                                   AS unpricedUnattributedSessions,
SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
         AND (…tokens…) > 0
         AND c.model IS NOT NULL AND c.model <> ''
    THEN 1 ELSE 0 END)                                   AS unpricedNoPriceSessions,
```

plus the matching token sums (`unpricedUnattributedTokens`,
`unpricedNoPriceTokens`) so the UI can show share-of-tokens, not just row counts.

**MCP `getCosts` (`MCPDatabase.swift:231-272`).** The four sums are aggregate over
the whole predicate and cannot be reduced from the existing GROUP-BY rows, so a
distinct one-row query is required (folding into the grouped SELECT would
per-group-duplicate them). **Placement matters: the getCosts read is
`try queue.read { db in try Row.fetchAll(db, …) }` at `:254`; run the four-sum
statement as a sibling `Row.fetchOne` inside that *same* `db` closure (return a
tuple), never as a second `queue.read` nested inside the first.** GRDB's read
queue is non-reentrant — a nested `queue.read` inside an open read closure
deadlocks (the probe/reentrancy trap the concurrent baseline specs also hit in
this file). Add the four keys to the top-level object. **Declare them
in `MCPOutputSchemas.getCosts` `properties`** but **do not add them to
`required`** — additive and backward-compatible for strict clients; the fields
are always emitted. Regenerate `get_costs.project.json` (the byte golden breaks;
this is unavoidable, unlike Part A).

**Service `costs()` (`EngramServiceReadProvider.swift:1140-1203`).** Compute the
same four sums as a top-level query and add them to `EngramServiceCostsResponse`.
`SourceRow` is **unchanged** (per-source cause split is a non-goal).

Two compile-time constraints, both compiler-caught:

1. **Preserve the memberwise initializer.** Declare the four new stored
   properties with `= 0` defaults
   (`let unpricedUnattributedSessions: Int = 0`, etc.). Without defaults the
   synthesized memberwise init changes shape and breaks all five existing
   construction sites — the two stub returns
   (`EngramServiceReadProvider.swift:60,264`), the table-absent early return
   (`:1131-1137`), the main return (`:1197-1203`), and
   `MockEngramServiceClient.swift:75`. With `= 0` defaults, only the main return
   `:1197` is edited to pass the real sums; the other four keep compiling
   untouched, emitting zeros.
2. **Add the custom `init(from:)` in an extension, not the struct body.** Add a
   custom `init(from:)` using `decodeIfPresent(…) ?? 0` for the four new fields
   so an older-build payload still decodes across the IPC frame (house
   forward-compat pattern). Placing it in the struct body would suppress the
   memberwise init even with defaults present; put it in an
   `extension EngramServiceCostsResponse { init(from:) … }` so both initializers
   coexist. (Existing in-body `init(from:)` examples at
   `EngramServiceModels.swift:179,265,548` are structs with no external
   memberwise-init callers, so they can afford in-body; this DTO cannot.)

**App UI (`CostSummarySection.swift`).** When any unpriced count is non-zero, add
one disclosure row under the summary, e.g. "1,929 sessions unpriced — 867
unattributed, 1,062 unknown model", worded so it reads as a data-quality note,
not a billing figure (the header's `.help()` already says "Not billing-authoritative"
at `CostSummarySection.swift:21`; `:20` is the `SectionHeader` title "Cost"). Read
straight off the DTO; `SourcePulseView` needs no change. Gate the row on a pure
`static func showsUnpricedRow(_ costs: EngramServiceCostsResponse?) -> Bool`
helper (true iff any of the four counts is non-zero) so the show/hide predicate is
unit-testable without a SwiftUI render harness; the view body reads the helper.

**Docs.** Update `docs/mcp-tools.md:303-315` (get_costs Notes) to list the four
unpriced fields and their meaning.

#### Part B — Implementation slices

- **B1 — service reader + DTO + UI.** Add the four sums to `costs()`; extend
  `EngramServiceCostsResponse` with defaulted decode; add the disclosure row to
  `CostSummarySection`. Extend `testCostsTreatNullCostRowsAsZero` and add the
  two-cause `_repro`.
- **B2 — MCP reader + schema + golden.** Add the four keys to `getCosts`; declare
  in the output schema (properties only); regenerate `get_costs.project.json`.
- **B3 — docs.** `docs/mcp-tools.md` get_costs Notes.

#### Part B — Acceptance criteria

1. Service `costs()` over a fixture with one priced row, one NULL-cost row with
   tokens and NULL model, and one row with tokens and model `"gpt-5.6-sol"`
   returns `unpricedUnattributedSessions = 1` and `unpricedNoPriceSessions = 1`;
   `totalUsd` and `sessionCount` are unchanged from today's conflated values.
2. A zero-token NULL-cost row is counted in neither unpriced bucket.
3. MCP `get_costs` structuredContent carries the four keys and validates against
   the declared schema (`testStructuredContentMatchesDeclaredOutputSchema`
   passes); the regenerated golden matches byte-for-byte.
4. `CostSummarySection` renders the disclosure row iff a count is non-zero, and
   omits it when all four are zero.

### Part C — local `prices.json` overlay (row 14)

Service-side read in `EngramCoreWrite`, **reloaded at the start of each
`backfillCosts` invocation** (not a once-per-process static — see the test seam
below), merged over the static tables. **The overlay's `updated` string bumps the
*effective* pricing version, which routes corrections through the existing
`1 = 1` full-recompute branch** — the only path that re-prices already-nonzero
rows.

The design has two cleanly separated concerns, because `resolvedPrice` is called
from two paths (index-time upsert at `SessionSnapshotWriter.swift:471` and startup
recompute at `StartupBackfills.swift:595`):

1. **Overlay prices** — a db-free in-memory table parsed from the file, read by
   `resolvedPrice` on both call sites. Controls what price *any* row (new or
   recomputed) gets.
2. **Adopt / recompute gate** — lives in `backfillCosts`, where a `Database`
   handle exists. Decides whether to *re-price existing rows*, by comparing the
   effective version (derived from the overlay `updated` date and the stored
   marker) against the stored `session_cost_pricing_version`.

Keeping these separate is what makes the reject-older rule and the
effective-version compare mutually consistent (they were conflated in an earlier
draft; see Risks).

**File.** `~/.engram/prices.json`, absent by default:

```json
{
  "updated": "2026-07-24",
  "models": {
    "gpt-5.6-sol": {
      "input": 1.75, "output": 14, "cacheRead": 0.175, "cacheWrite": 0,
      "tier": { "threshold": 272000, "input": 3.5, "output": 28, "cacheRead": 0.35, "cacheWrite": 0 }
    }
  }
}
```

`tier` is optional; its shape mirrors `.threshold(272_000, SessionModelPrice)` so
the 272K long-context tier round-trips (four-flat-doubles, as Agent Sessions'
`RunwayPriceTable` uses, cannot). An overlay entry **overrides** the static table
for that model key; unlisted models fall through to the static tables unchanged.

**Overlay lookup must run at the TOP of `resolvedPrice(for:)`, before the
OpenAI short-circuit.** `resolvedPrice` returns nil at
`SessionCostPricing.swift:125` (`if isOpenAIModel(model) { return nil }`) for any
unmatched `gpt-`prefixed model. The motivating model `gpt-5.6-sol` matches
`isOpenAIModel` (`hasPrefix("gpt-")`, `:224`) and fails `longestDelimitedMatch`
(boundary after `gpt-5` is `.`), so it hits that `return nil`. An overlay lookup
added anywhere *after* `:125` — the natural "fall through to the static tables"
reading — would never apply to the entire 781-row point of Part C. So the merge
is: at the very top of `resolvedPrice(for:)`, on the `normalized(model)` key,
`if let overlayPrice = overlay?[normalized] { return overlayPrice }` **before**
`resolveClaude` / `resolveOpenAI` / the `:125` short-circuit. Overlay wins for
OpenAI-prefixed keys too.

**Load (db-free) in `SessionCostPricing`.** Parse `~/.engram/prices.json` into an
in-memory `PricesOverlay { updated: String; models: [String: ResolvedPrice] }`.
No db, no marker, no adopt here. Expose:
- `static func loadOverlay(from url: URL)` — parse and set the in-memory overlay
  (nil on absent; nil + `os_log` warning on malformed; the static tables stand).
  Called at the top of each `backfillCosts` run with the resolved default path,
  and once from `SessionSnapshotWriter` init, so both `resolvedPrice` call sites
  read the same table within a process. Reloading per backfill (not a
  once-per-process lazy static) is what makes the four Part C tests — which each
  need a different `prices.json` — independently runnable in one XCTest process.
- `static func resetOverlayForTesting()` — clears the in-memory overlay for tests
  that exercise `resolvedPrice` directly.

The default path is resolved through an injectable seam
(`overlayURLProvider`, defaulting to
`FileManager.default.homeDirectoryForCurrentUser/.engram/prices.json`) so tests
point it at a temp file and **existing** `StartupBackfillTests` cost tests run
with no file present → overlay nil → their behavior is unchanged even on a
developer/CI machine that happens to have a real `~/.engram/prices.json`.

**Adopt + effective-version gate (in `backfillCosts`, where `db` exists).**
Compute, before the version compare:

```swift
SessionCostPricing.loadOverlay(from: overlayURLProvider())          // may set nil
let fileDate = SessionCostPricing.overlay?.updated                  // nil if absent
let storedOverlayDate = metadata["session_cost_pricing_overlay_updated"]
// accept-equal, reject-older: never let an older file lower the adopted date
let adoptedDate = [fileDate, storedOverlayDate].compactMap { $0 }.max()   // lexical ISO
let effectiveVersion = adoptedDate.map { "\(tableVersion)+\($0)" } ?? tableVersion
recomputeAllTokenRows = storedVersion != effectiveVersion           // :554
```

- **No file, never adopted** → `adoptedDate == nil` → `effectiveVersion == "3"` ==
  stored → no recompute (backward compatible). (C1)
- **New file dated D, none stored** → `adoptedDate == D` →
  `"3+D" != "3"` → one full `1 = 1` recompute; on completion
  `markCostPricingVersionCurrent` stamps **both** `session_cost_pricing_version =
  "3+D"` and `session_cost_pricing_overlay_updated = D`. (C2)
- **Same file re-loaded** → `adoptedDate == D` == stored → no recompute
  (accept-equal no-op). (C4 equal)
- **Older file dated D' < D replacing it** → `adoptedDate = max(D', D) = D` ==
  stored → **no recompute** — the older `updated` is rejected *as a gate input*
  (C4 older). The file's prices still apply to newly-indexed rows via
  `resolvedPrice`; only the historical recompute is withheld, which is the whole
  point of the downgrade guard.
- **Later file dated D'' > D** → `adoptedDate == D''` → mismatch → one recompute,
  markers converge to `D''`. (C3)

**Both the compare (`:554`) and the store (`markCostPricingVersionCurrent`,
`:624`) must use this `effectiveVersion`, and the overlay marker must be written
in the same `markCostPricingVersionCurrent` call**, or the recompute either never
fires, fires every startup, or reverts overlay prices to static. The marker is
computed and written only inside `backfillCosts`/`markCostPricingVersionCurrent`
(db present) — never inside the db-free `SessionCostPricing` static.

**Process placement.** All of the above is in `EngramCoreWrite`, invoked by the
`EngramService` process inside the existing `writer.write`
(`StartupComposition.swift:74`). No app-side pricing, no new writer path, no IPC.
Reading `~/.engram/prices.json` is a local file read, not a `ServiceWriterGate`
write. A mid-session file edit is **not** hot-reloaded; it takes effect on the
next service start, when `effectiveVersion` is recomputed and the full recompute
fires — the documented, intended behavior.

#### Part C — Implementation slices

- **C1 — overlay model + db-free load.** `PricesOverlay` JSON type, `loadOverlay`,
  `resetOverlayForTesting`, `overlayURLProvider` seam. Unit tests for parse (with
  and without `tier`) and malformed-ignored. No db, no marker in this slice.
- **C2 — merge into `resolvedPrice`.** Overlay lookup at the **top** of
  `resolvedPrice`, before the `:125` OpenAI short-circuit; unit test that a
  `gpt-`prefixed overlay model (`gpt-5.6-sol`) resolves to the overlay price and
  its tier applies at 272K.
- **C3 — adopt + effective-version wiring.** In `backfillCosts`: reload overlay,
  read the overlay marker, compute `adoptedDate = max(fileDate, storedDate)` and
  `effectiveVersion`; change the compare (`:554`) and stamp both markers in
  `markCostPricingVersionCurrent` (`:624`). Tests: overlay change forces one full
  recompute, a second start is a no-op, an older file is rejected as a gate input.

#### Part C — Acceptance criteria

1. With no `~/.engram/prices.json`, `effectiveVersion == "3"`, and a service start
   runs **zero** cost recompute rows (parity with today).
2. With a `prices.json` pricing `gpt-5.6-sol` (incl. its 272K tier), a first
   start recomputes the 781 previously-NULL `gpt-5.6-sol` rows to non-zero costs
   applying the tier above 272K tokens; a second start recomputes **zero** rows.
3. Editing `prices.json` to a later `updated` re-forces the full recompute on the
   next start exactly once (proving corrections to already-nonzero rows apply).
4. Starting from stored markers `session_cost_pricing_version = "3+2026-08-01"`
   and `session_cost_pricing_overlay_updated = "2026-08-01"`, a `prices.json`
   dated `updated = "2026-07-01"` (older) causes **zero** recompute rows and
   leaves both markers unchanged (rejected as a gate input); a file dated exactly
   `"2026-08-01"` (equal) is likewise a zero-row no-op with markers unchanged.
5. The 867 `model IS NULL` rows remain unpriced after any overlay (the overlay
   cannot rescue rows with no model) — confirming Part C and the adapter fix are
   independent.

## Invariants affected

- **#1 Single-writer** (`docs/invariants.md:7`) — preserved by all three parts.
  Part A and Part B are read-only. Part C reads a local file and writes only
  through the existing `backfillCosts` inside `writer.write`; no new writer, no
  app-side or MCP-side write.
- **#9 Startup backfills version-gated and idempotent** (`docs/invariants.md:63-65`)
  — touched by Part C. `backfillCosts` stays version-gated; the gate input
  changes from `tableVersion` to `effectiveVersion`, which is stable across
  restarts when the overlay is unchanged, so idempotence is preserved. Add the
  Part C recompute-once test to this entry's `Verified by` list.
- No new invariant is introduced. Part B adds no schema, so **#11 Sessions Schema
  Migrations Are Idempotent** is not touched.

## Cross-spec coordination

Four baseline specs are being implemented concurrently on a separate branch; two
share files this spec edits. Those specs are not in this branch's tree, so their
exact anchors are cited only as they stand on their branch and will drift — the
coordination below is at the symbol level, which is stable.

- **`source-health-predicate-design-2026-07.md` (row 2)** edits a source-health
  predicate in `MCPDatabase.swift` and `EngramServiceReadProvider.swift`. Part B
  edits *cost* symbols in the same two files — `getCosts`
  (`MCPDatabase.swift:231-272`) and `costs()`
  (`EngramServiceReadProvider.swift:1140-1203`) — disjoint from the health
  predicate; no symbol collision, only a text-level merge. Two inherited traps
  apply and Part B already honors both: (1) `MCPDatabase`'s `queue.read` is
  non-reentrant, so Part B runs its four-sum query as a sibling `Row.fetchOne`
  inside the existing `db` closure, never a nested `queue.read` (see Part B design
  above); (2) `searchableTierSQL` also excludes `lite` and must not be reused as a
  health/coverage predicate — Part B's unpriced predicate is
  `COALESCE(cost_usd,0)=0` gated on `tokens > 0`, not any tier SQL, so there is no
  interaction.
- **`service-resilience-design-2026-07.md` (rows 12, 25) — same two files, disjoint
  symbols (integration pass, 2026-07-25).** That spec also edits `MCPDatabase.swift`
  (row 12 adds a `parseFailures` field to the `stats` emitter at `:123-146`; row 25
  D2 annotates the search read at `:2196-2218`) and
  `EngramServiceReadProvider.swift` (row 12 extends `sources()` at `:1009-1058`;
  row 25 D2 the `keywordSearch` read at `:591-630`). Part A here un-`private`s
  `contextNow()` (`:2540`) and Part B edits `getCosts` (`:231-272`) / `costs()`
  (`:1140-1203`) — all distinct methods, so this is a text-level merge, not a
  symbol collision. **Both specs inherit the same non-reentrant `queue.read` trap
  and both hoist their probe/aggregate as a sibling `Row.fetchOne`/`fetchAll`
  inside the one open `db` closure** (Part B above; service-resilience Part C/D2),
  so serializing the two on `MCPDatabase.swift` is mechanical. `docs/mcp-tools.md`
  is also co-edited: Part A here at get_insights `:373-375`, Part B at get_costs
  `:303-315`, service-resilience row 12 at the `stats` section — disjoint tool
  entries.
- **`adapter-format-drift-design-2026-07.md` (row 23)** and the concurrent
  `codex-native-parentage` work touch `ClaudeCodeAdapter.swift` and the
  `StartupBackfills.swift` region. Part C edits cost-pricing symbols only —
  `backfillCosts` / `markCostPricingVersionCurrent`
  (`StartupBackfills.swift:548-626`) and `SessionCostPricing.swift`. The
  concurrent codex-parentage change inserts a new function *after* `backfillCosts`
  rather than altering its body, so the edits are adjacent/append, not
  overlapping; re-anchor at merge.
- **Shared merge points, already reflected above:** `docs/invariants.md` #9
  (Part C adds its recompute-once test to that entry's `Verified by` list — an
  append merge), `StartupBackfillTests.swift` (Part C appends tests — append
  merge), and `docs/mcp-tools.md` (Part B edits only the get_costs Notes at
  `:303-315`; concurrent specs edit other tool entries — text-level merge).
- **MCP output-schema constraint inherited:** the get_insights and get_costs
  schemas are `additionalProperties:false` with `required:["content"]`, so Part A
  adds no structured field (prose refusal in `content[0].text`) and Part B adds
  the four unpriced keys to `getCosts` `properties` only, never to `required`.

## Alternatives considered

- **Part A: inject a `now: Date` parameter into `MCPInsightsTool.result` instead
  of exposing `contextNow()`.** Both give determinism; un-`private`ing the
  existing free function is a one-word diff and reuses the existing
  `ENGRAM_MCP_NOW` test lever, so the parameter add lost on minimum-diff.
- **Part A: add a structured `windowDays`/`projectionWithheld` field to the
  output.** Impossible: the schema is `additionalProperties:false,
  required:["content"]`. Refusal is prose only.
- **Part A: also fix the `MCPDatabase.swift:1826` `/7` projection.** Lost: that
  window is a fixed 7 days, so `/7` is correct; touching it is an unrelated
  no-op edit.
- **Part B: per-`SourceRow` cause split.** Doubles the DTO surface and the SQL,
  and ripples `SourceRow`'s Codable/Equatable identity into every mock. The
  headline honesty need is a total-level "N unpriced, split A/B"; which source is
  unattributed is a diagnostic `GROUP BY source` query, not a dashboard number.
  Cut.
- **Part B: fix the adapter model attribution in the same PR.** Lost: it is
  adapter work (opencode/kimi/copilot emit `model: nil`), and already-indexed
  files are not re-parsed on unchanged size/mtime — deleting `file_index_state`
  does **not** force re-parse — so a code fix alone backfills nothing without a
  forced re-index. Disclose now; fix separately.
- **Part C: remote price fetch (the AS "runway" model).** Lost: default-off
  network adds a `docs/PRIVACY.md:70-80` network feature for zero local benefit.
  Local overlay only.
- **Part C: drive corrections through the `COALESCE(cost_usd,0)=0` predicate.**
  Lost: that branch cannot re-price an already-nonzero row (`StartupBackfills.swift:555`);
  only the version-mismatch `1 = 1` branch can. The effective-version bump is the
  mechanism, not the predicate.
- **Part C: mutate `SessionCostPricing.tableVersion` at load time.** Lost:
  `tableVersion` is a semantic constant; a computed `effectiveVersion` keeps the
  base version meaningful and the overlay contribution explicit.

## Test plan

All Swift. No `src/`, `scripts/`, or `tests/fixtures/adapter-parity/` change.

**Part A** — `macos/EngramMCPTests/EngramMCPExecutableTests.swift`:

- Repro: `func testGetInsightsWithholdsProjectionForShortWindow_repro()` — set
  `ENGRAM_MCP_NOW` to a fixed instant, seed a `session_costs` fixture with
  token-carrying priced spend, call `get_insights` with `since` = now − 2 days;
  assert the output contains "too short to project", contains **no** dollar
  projection, and contains **no** "Monthly pace:" advice bullet (guards the
  second half of acceptance #2 — the `>$50` bullet at `MCPInsightsTool.swift:24-25`
  must be suppressed under withhold). Establish red by asserting the pre-fix
  output contains a projected figure (the hardcoded `/7` still projects at a
  2-day window); it is observable because the golden harness already spawns the
  real binary.
- `func testGetInsightsProjectsOverActualWindow()` — 30-day window, $30 spend,
  fixed `ENGRAM_MCP_NOW`; assert `$30.00`, not `$128.57`.
- Guard: `testGetInsightsMatchesGolden` must still pass **unmodified** (it sets no
  `ENGRAM_MCP_NOW`; $0 spend keeps the line byte-identical). If it breaks, either
  the withhold path is firing on the 160-day/$0 case, **or** the non-withhold
  Period-summary line was reworded away from
  `**Period summary:** Spent $X · Projected monthly $Y` — both violate the design.

Determinism note: these tests require `get_insights` to honor `ENGRAM_MCP_NOW`,
which is exactly the `contextNow()` visibility change in A1; without it the
window is `Date()`-driven and untestable.

**Part B** — `macos/EngramServiceCoreTests/EngramServiceCostsTests.swift`:

- The seed helper `insertCost` (`:224`) inserts only `session_id, cost_usd`; the
  `session_costs` fixture table already has `model` and token columns
  (`:191-199`). B1 extends `insertCost` with defaulted `model: String? = nil`,
  `inputTokens: Int = 0`, `outputTokens: Int = 0` parameters so existing calls
  are unchanged and the two-cause rows can be seeded with tokens.
- Extend `testCostsTreatNullCostRowsAsZero` (`:126`) to seed tokens on the
  existing NULL-cost row and assert `unpricedUnattributedSessions == 1`.
- Repro: `func testCostsDiscloseUnpricedSplitByCause_repro()` — seed one priced
  row, one NULL-model token row (cause A), one `"gpt-5.6-sol"` token row (cause
  B), one zero-token NULL-cost row (counted in neither); assert
  `unpricedUnattributedSessions == 1`, `unpricedNoPriceSessions == 1`, and the
  token sums. Red before the reader change: the fields do not exist.
- MCP: regenerate `tests/fixtures/mcp-golden/get_costs.project.json`;
  `testStructuredContentMatchesDeclaredOutputSchema` and
  `testGetCostsMatchesGolden` gate the schema+golden.
- UI predicate: `func testCostSummaryShowsUnpricedRowOnlyWhenNonZero()` in a
  `macos/EngramTests` view-model test — asserts
  `CostSummarySection.showsUnpricedRow` is `true` when any count is non-zero and
  `false` when all four are zero (and for a nil DTO). Covers acceptance #4 without
  a render harness. (`CostSummarySection` has no existing test reference; this is
  the first.)

**Part C** — `macos/EngramCoreTests/StartupBackfillTests.swift`. **Test seam:**
each test points `overlayURLProvider` at a per-test temp `prices.json` (or none)
and calls `SessionCostPricing.resetOverlayForTesting()` in setup; because
`backfillCosts` reloads the overlay per invocation, the four tests are
independently runnable in one process, and any test with no file gets a nil
overlay regardless of the machine's real `~/.engram/prices.json`.

- `func testPricesOverlayForcesRecomputeOnce_repro()` — seed token rows for a
  **`gpt-`prefixed** model absent from the static table (`gpt-5.6-sol`, so the
  test exercises the `:125` OpenAI short-circuit the overlay must beat, not an
  easy non-`gpt-` name); point the seam at a `prices.json` pricing that model;
  assert first `backfillCosts` recomputes them to non-zero and stamps
  `effectiveVersion`, and a second call recomputes 0. Red before the
  effective-version wiring: without the bump, the version-matched branch's
  `COALESCE(cost_usd,0)=0` would price the currently-NULL rows anyway on first
  run, so red is established specifically on the **correction** case — pre-price a
  row to a wrong non-zero cost and show the un-bumped code leaves it wrong while
  the fix corrects it.
- `func testPricesOverlayAdoptRejectsOlderUpdated()` — seed stored markers
  `session_cost_pricing_version = "3+2026-08-01"`,
  `session_cost_pricing_overlay_updated = "2026-08-01"`; point the seam at a file
  dated `"2026-07-01"`; assert `backfillCosts` recomputes **0** rows and both
  markers are still `"3+2026-08-01"` / `"2026-08-01"` afterward. Then a file dated
  exactly `"2026-08-01"` also recomputes 0 with markers unchanged (accept-equal
  no-op). Both branches carry concrete recompute-count and marker assertions so
  "rejected" is falsifiable.
- `func testPricesOverlayTierAppliesAbove272K()` — overlay tier applies to a row
  above the 272K threshold (uses the same `gpt-5.6-sol` overlay entry).
- `func testNoOverlayLeavesEffectiveVersionUnchanged()` — no file → effective
  version `"3"`, no recompute; the guard that a real machine `~/.engram/prices.json`
  cannot leak in relies on the `overlayURLProvider` seam pointing at an empty temp
  dir.

**Intentionally not tested:** the adapter model-attribution fix (out of scope);
hot-reload of a mid-session `prices.json` edit (explicitly next-start only);
per-source cause granularity (non-goal).

## Rollout

- **Part A**: MCP-only behavior change, ships with the next `EngramMCP` build. No
  migration. Revert = revert `MCPInsightsTool.swift` and re-`private` `contextNow`.
- **Part B**: service + MCP + app; DTO field additions are forward-compatible via
  `decodeIfPresent`, so a mixed app/service build decodes cleanly. Regenerated
  MCP golden ships with it. Revert = drop the four fields and regenerate the
  golden; the DTO's defaulted decode means old and new builds interoperate during
  the revert window.
- **Part C**: service-only, ships with the next `EngramService` build. On the
  first start after a user drops a `prices.json`, one full cost recompute runs
  inside the existing startup write command, before `ready`; subsequent starts
  no-op. Revert = revert the `effectiveVersion` wiring; a stored
  `"3+<date>"` marker then differs from `tableVersion "3"`, forcing exactly one
  recompute back to static prices, after which it converges. `DELETE FROM metadata
  WHERE key IN ('session_cost_pricing_overlay_updated')` fully resets the overlay
  state.

## Risks and open questions

- **High — Part B MCP golden + schema break is mandatory.** Adding fields to
  `getCosts` output requires editing `MCPOutputSchemas.getCosts` and regenerating
  `get_costs.project.json`; forgetting the schema edit fails
  `testStructuredContentMatchesDeclaredOutputSchema` at runtime. Budgeted in B2.
- **High — Part C non-convergence if only one of `:554`/`:624` is changed.**
  Changing the compare to `effectiveVersion` but stamping `tableVersion` (or vice
  versa) causes a recompute every startup or a correction that never applies.
  Both must move together; acceptance criterion C1/C2 guards it.
- **Medium — the 867 attribution-defect rows are disclosed but not fixed.**
  Part B counts them; the adapter fix (opencode/kimi/copilot) is a separate row
  with a re-parse dependency. **Open question:** do opencode and kimi payloads
  actually carry a recoverable model? Copilot's does (the `modelMetrics` dict
  key, `CopilotAdapter.swift:369`); opencode/kimi need payload inspection before
  their fix is scoped.
- **Medium — Part A reason 3 couples A↔B.** The unpriced-share refusal needs
  Part B's data. Mitigated by shipping A with reasons 1+2 only and specifying
  reason 3 as a one-line follow-up behind a shared `unpricedTokensSince` helper.
  **Open question:** is reason 3 worth adding at all, or is the withhold-on-short-
  window plus the Part B disclosure sufficient honesty?
- **Low — `gpt-5.6-sol` provenance.** **Open question:** is it a real released
  model that belongs in the static table, or an alias/typo? Determines whether
  Part C's overlay is the permanent home or a stopgap for the 781-row bucket.
- **Low — Part C overlay caching.** The overlay is read once per process; a user
  who edits `prices.json` expecting an immediate change sees it only on the next
  service restart. Accepted and documented; a file-watcher hot-reload is a
  possible future enhancement, not in scope.
- **Open question — Part A `since` timezone/fractional-seconds variance.** The
  dual-formatter fallback (mirroring `contextNow`) covers the observed shapes;
  whether any caller sends a zoneless timestamp is unverified. Parse failure
  withholds rather than guesses.
