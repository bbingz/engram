# Design Doc: UI Honesty & Accessibility Polish

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog rows 13 (UX-4),
  19 (UX-8 labels), 29 (UX-9), 31 (UX-8 ramp). Composes with the accepted
  baseline spec `docs/source-health-predicate-design-2026-07.md` (shares
  `SourcePulseView.swift` — see Part C). All citations are `path:line` at HEAD
  `23dca547` (branch `docs/mirror-followup-specs`), personally opened while
  drafting. A concurrent branch is editing `SourcePulseView.swift`,
  `StartupBackfills.swift`, and MCP files; line numbers in those files will
  drift and that is expected.

This is a bundle of four independent UI-only fixes sharing an accessibility /
honesty theme. Each Part under **Proposed design** is separately landable with
its own slices and acceptance criteria; a reader implementing only one Part can
ignore the other three. None touches schema, service, IPC, DTOs, or the writer.

## Problem

The macOS app ships four measurable UI-honesty / accessibility gaps:

1. **Row 13 — a limitless share is drawn as a green quota meter.** The usage
   popover renders "7d token share" / "5h token share" as a filled green
   progress bar (`PopoverUsageSection.swift:278` default `.green`,
   `:333-336` fill `value/100`, `:328` bare `"NN%"`). Shares are computed as a
   source's fraction of the cross-source total and **sum to 100%**
   (`StartupUsageCollector.swift:231-234`), so the busiest source always shows
   the fullest green bar under a "USAGE" header — reading as "at quota /
   healthy-full" for a number that has no quota. Compact mode additionally
   drops the metric word, so a share renders as `codex … 62% 7d` with nothing
   distinguishing it from an actual limit meter (`:64`, `:71`, `:112-117`).

2. **Row 19 — icon-only transcript controls are silent to VoiceOver.** The app
   has 234 `accessibilityIdentifier` (UI-test targeting, invisible to assistive
   tech) against 19 `accessibilityLabel` and 1 `accessibilityHint`. In
   `Views/Transcript/` the font ± glyphs `Text("A−")` / `Text("A+")`, the four
   `Image`-only find-bar buttons, and the chip nav glyphs `Text("∧")` /
   `Text("∨")` at 9pt carry no label — VoiceOver reads the last two as the
   logical-and/or symbols, not "previous/next".

3. **Row 29 — we ship remediation slots we never fill.** `AlertBanner` and
   `EmptyState` both expose an optional `action:(label:action:)` affordance
   (`AlertBanner.swift:6`, `EmptyState.swift:8`). Across 45 call sites (20
   AlertBanner + 25 EmptyState) exactly **one** passes it
   (`MigrationHistoryView.swift:68` — a "Retry"). Meanwhile `error
   .localizedDescription` is piped raw into banners, collapsing structured
   service errors (case name + retry policy) to a bare message, while the
   `ServiceErrorPresenter` that preserves that structure is called at only 2
   sites.

4. **Row 31 — nothing scales with the OS text-size setting.** 0 uses of
   `dynamicTypeSize` / `@ScaledMetric` against 172 `.font(.system(size:))`.
   The sidebar is pinned to 10.5pt / 8pt text in a hard `frame(minWidth:160,
   maxWidth:160)` (`SidebarView.swift:47,:150,:153,:21`) with `lineLimit(1)`
   everywhere. Low-vision users get no scaling and no honest fallback.

## Goals / Non-goals

**Goals**

- Row 13: stop rendering limitless cross-source shares as quota meters; render
  them as plain, self-labeling text. Resolve the dead `resetAt` threading.
- Row 19: give every icon/glyph-only control in `Views/Transcript/` a VoiceOver
  label and a hover `.help()`; deliver the exact string catalog as this Part.
- Row 29: wire a Retry closure at the four highest-traffic load-failure banners
  and route their text through `ServiceErrorPresenter`; define the mechanical
  routing rule for the rest as an explicit follow-up list (not this Part's work).
- Row 31: introduce the type-scaling pattern and apply it to two starter
  surfaces (sidebar chrome + transcript body), defining the conversion pattern
  others follow later.

**Non-goals**

- No collector / DTO / service / schema / migration change in any Part (row 13
  data is already honest at the DB layer: shares are written `limit_value NULL,
  status 'observed'`).
- Row 13: no absence-copy enum (single call site) and no configure-limits link
  (Settings "Usage Limits" GroupBox exists at `SettingsView.swift:272-301`;
  `PopoverView.swift` empty state already links to it).
- Row 19: no relabeling of already-text-labeled buttons beyond adding `.help()`;
  no sweep outside `Views/Transcript/`.
- Row 29: not routing all 43 `localizedDescription` uses (many feed sheets /
  inline text / status enums, not banners); not touching the third unused-slot
  component `SectionHeader.trailingAction` (37 sites).
- Row 31: not converting all 172 font sites; no i18n/localized-label upgrade.

## Current state

Anchors at HEAD `23dca547`.

**Row 13 — usage popover.** `UsageMetricRow.body` routes any percent/nil unit
to `UsageBar` (`PopoverUsageSection.swift:173-190`, `isPercent` at `:226-228`).
`UsageBar.barColor` returns `.green` for every non-critical/non-attention
status (`:274-280`); `fillFraction` fills `value/100` (`:333-336`);
`percentText` prints bare `"\(Int(value))%"` when `limit == nil` and the metric
is not "remaining" (`:325-329`). `UsageValueRow` (`:245-263`) is an existing
label-plus-right-aligned-text renderer. Shares reach the view carrying
`unit == "%"`, `limit == nil`, `status == "observed"` — written by the only
production writer at `StartupUsageCollector.swift:237-241` (`appendShareSnapshots`,
fn `:224-253`). Compact passes `label: SourceColors.label(for:)` and only a
`windowSuffix` of `5h`/`7d` (`:64`, `:71`, `:112-117`). `resetAt` is threaded
through `:49,:68,:168,:179,:269` and referenced in **no** `Text(...)` —
`UsageBar.body` (`:282-313`) never reads it.

Correction to the mirror/brief: the proposed predicate
`limit == nil && isPercent(unit)` is **too broad** — it also matches a
`remaining`/`used` percent metric (which also carries `limit == nil`), and
those have live bar-rendering branches (`percentText:325-326`,
`fillFraction:334`) plus tests asserting they render as bars
(`PopoverUsageSectionTests.swift:212-234`). On today's production data the two
predicates coincide (shares are the only limit-nil non-remaining percents
written), but conflating them would silently regress the defensive
remaining/used meter path. This Part scopes the predicate to shares.

**Row 19 — transcript controls.** `TranscriptToolbar.swift`: the one existing
label is the star at `:62`; `ID`/`Handoff`/`Replay`/`Resume` already have
`.help()` (`:83,:101,:118,:135`). The gaps: `A−` glyph `:140-143`, `A+` glyph
`:145-148`, `Copy` `:152-160` (text, no help), `Find ⌘F` `:164-169` (VoiceOver
reads "Find command F"), the empty-labeled segmented `Picker("", …)` `:66`,
`Back` `:41-50` (text, no help), `All` `:178-186`. `MessageTypeChip.swift`: nav
glyphs `Text("∧")` `:35-37` and `Text("∨")` `:41-43`; toggle `:22-32` conveys
shown/hidden only via `.opacity(0.5)` `:48`. `TranscriptFindBar.swift`:
decorative `magnifyingglass` `:16`, and `Image`-only buttons clear `:25-32`,
prev `:47-51`, next `:54-58`, close `:64-72`.

Correction to the brief: it says "~12 icon-only buttons". Most toolbar buttons
carry visible text (Back, ID, Handoff, Replay, Resume, Copy, Find) so VoiceOver
already reads their name; the genuinely glyph/icon-only **unlabeled** controls
in `Views/Transcript/` number 8 (2 toolbar glyph + 2 chip glyph + 4 find-bar
image). The remainder of the ~15 remediation items are `.help()` and
state-value additions on text-labeled controls.

**Row 29 — banners / empty states.** `AlertBanner.action` and
`EmptyState.action` are optional and already fully rendered when present
(`AlertBanner.swift:16-26`, `EmptyState.swift:22-30`) — no component edit is
needed to pass one. The reference pattern is `action: ("Retry", retry)` at
`MigrationHistoryView.swift:68`. `ServiceErrorPresenter.displayMessage(for:)`
(`EngramServiceError.swift:56-63`) returns `userFacingDetail` (case name +
message + `[retry: policy]`) for `EngramServiceError`, else
`localizedDescription`; called at 2 sites only (`SessionDetailView.swift:735,
:931`). The four targets and their catch lines: `SessionsPageView.swift:149`
(catch `:407`), `ReposView.swift:44` (catch `:100`), `SourcePulseView.swift:74`
(catch `:137`/`:169`), `TimelinePageView.swift:232` (catch `:405`/`:420`/`:437`).
Each target already has a `loadData()` entrypoint driven by `.task`/`onRefresh`
(`ReposView.swift:79,:49`; `SourcePulseView.swift:77`;
`SessionsPageView.swift:287,:316`; `TimelinePageView.swift:336,:361`).

Correction to the brief: `SessionsPageView.swift:152` and
`TimelinePageView.swift:236` are **not** load failures — they render a transient
`actionStatus` set after a mutation and auto-cleared (`SessionsPageView.swift
:107-115`; `TimelinePageView.swift:127-135`). They must **not** get Retry.

**Row 31 — typography.** `Theme.swift` (`:6-92`) holds only color tokens plus
one layout token (`cornerRadius` `:91`); there is **no** typography/font token
layer. So the ramp cannot "go into an existing token layer" — this Part must
introduce one, and `Theme.swift` is its home. `MotionAware.swift:4-37` is the
house pattern for centralizing an a11y concern (pure helper + `ViewModifier` +
`View` extension) and is the model to mirror. Sidebar font sizes: section
header 8pt (`SidebarView.swift:21`), `SidebarItem` icon+label 10.5pt (`:150,
:153`), footer 10pt (`:122,:125`); pinned width `frame(minWidth:160,
maxWidth:160)` `:47`; hosted as the `NavigationSplitView` sidebar column
(`MainWindowView.swift:13-15,:26`). Transcript body already has a **manual**
knob: `@AppStorage("contentFontSize") = 14` rendered via
`.font(.system(size: fontSize))` and adjusted 10–22 by the A−/A+ buttons
(`ColorBarMessageView.swift:8`; `TranscriptToolbar.swift:35,:140-147`) — it
ignores OS Dynamic Type but is not a plain hardcoded surface.

## Proposed design

Minimum design per Part. Land in any order.

### Part A — Row 13: render limitless shares as text, not meters

One file: `PopoverUsageSection.swift` (~35 lines). No writer/DTO/schema change.

1. **Share predicate (scoped, not the brief's broad form).** Add an **internal**
   (not `private`, so the test target sees it) static helper
   `isLimitlessShare(metric:limit:) -> Bool` on `UsageMetricRow` returning
   `limit == nil && metric.lowercased().contains("share")`. In
   `UsageMetricRow.body` (`:173-190`), route a limitless share to
   `UsageValueRow` **before** the `isPercent` check, leaving the existing
   `isPercent → UsageBar` branch intact for pressure/remaining/used meters:

   ```
   if Self.isLimitlessShare(metric: metric ?? label, limit: limit) {
       UsageValueRow(label: label, text: Self.shareText(value: value, metric: metric ?? label, suffix: suffix))
   } else if Self.isPercent(unit) { UsageBar(...) } else { UsageValueRow(...) }
   ```

   `body` has no compact/expanded branch — the same `UsageMetricRow` serves both
   (compact passes a non-empty `suffix` at `:71`, expanded passes `suffix: ""`),
   so the compact/expanded distinction rides on `suffix`, consumed in step 2.

2. **Honest share text, suffix-aware.** `shareText(value:metric:suffix:)`
   branches on `suffix`:
   - **`suffix` empty (expanded):** `"\(Int(value))% of \(window)"` where
     `window` derives from the metric by the rule *strip a trailing `share`, map
     the noun `token → tokens`, keep `cost` as-is*: "7d token share" →
     "7d tokens", "5h token share" → "5h tokens", "7d cost share" → "7d cost".
   - **`suffix` non-empty (compact):** `"\(Int(value))% \(suffix) share"`, e.g.
     `suffix == "7d"` → `"62% 7d share"`.

   This makes the number self-describing as a share of a window's cross-source
   activity — not a quota. Reuse `UsageValueRow` (`:245-263`); add no new view.
   **`windowSuffix` is left untouched** — the compact suffix still comes from
   `windowSuffix(for:)` returning bare `"7d"`/`"5h"` (`:112-117`) and `shareText`
   adds the "share" noun. Keeping `windowSuffix` unchanged is what preserves the
   existing `windowSuffix(for:"7D cost share") == "7d"` assertion at
   `PopoverUsageSectionTests.swift:47` (that metric contains "share", so widening
   the function — as the brief's first cut proposed — would have reddened `:47`;
   this Part does not touch `windowSuffix`).

3. **Compact metric word (`:64,:71`).** With step 2, compact reads
   `codex … 62% 7d share` instead of `codex … 62% 7d`, because a share now routes
   to `UsageValueRow(shareText(...))` in compact and `shareText` appends the
   "share" noun to the passed `suffix`. Shares no longer reach `formattedValue`
   in either mode — they are intercepted by `isLimitlessShare` first — so
   `formattedValue`'s own suffix handling (`:217-223`) is irrelevant to shares.

4. **resetAt — delete the dead threading (minimum honest diff).** Remove the
   `resetAt` parameter from `UsageMetricRow` (`:168,:179`) and `UsageBar`
   (`:269`) and the two pass-throughs (`:49,:68`). This is safe: compact
   selection and its tests read `resetAt` off the `EngramServiceUsageItem`, not
   off the view params. Rendering it well (relative "resets in ~3h", laid out in
   a cramped popover) is scope creep beyond row 13's honesty goal; see
   Alternatives. If a future Part wants it on pressure meters, reuse
   `EngramServiceStatusStore.formattedResetAt` (`:255-273`, currently `private
   static`).

**Implementation slices (A)**

- A1: add `isLimitlessShare` (internal static) + suffix-aware `shareText`;
  reroute in `UsageMetricRow.body`. `windowSuffix` is unchanged.
- A2: delete the 5 `resetAt` view-layer references.
- A3: tests in `PopoverUsageSectionTests.swift`.

**Acceptance criteria (A)** — falsifiable:

- The pure predicate `UsageMetricRow.isLimitlessShare(metric:"7d token share",
  limit:nil)` == `true` (a limitless share routes to `UsageValueRow`, not
  `UsageBar`). Asserted directly on the static helper — the test target has no
  view-tree introspection dependency (no `ViewInspector`/`SnapshotTesting`
  anywhere under `macos/`), so routing is verified through the predicate, not a
  rendered `some View` body.
- `isLimitlessShare(metric:"weekly remaining", limit:nil)` == `false`
  (regression guard on the scoped predicate: a `remaining` percent stays on the
  `isPercent → UsageBar` branch).
- Expanded: `shareText(value:62, metric:"7d token share", suffix:"")` ==
  `"62% of 7d tokens"`; `shareText(value:41, metric:"7d cost share", suffix:"")`
  == `"41% of 7d cost"`; `shareText(value:30, metric:"5h token share",
  suffix:"")` == `"30% of 5h tokens"`.
- Compact: `shareText(value:62, metric:"7d token share", suffix:"7d")` ==
  `"62% 7d share"`.
- `windowSuffix(for:"7D cost share")` == `"7d"` still holds
  (`PopoverUsageSectionTests.swift:47` stays green — `windowSuffix` untouched).
- `PopoverUsageSectionTests.swift:212-234` (remaining/used bar tests) stay green
  unchanged.
- Smoke (manual, EVIDENCE_PATH): the expanded share string `"62% of 7d tokens"`
  (~16 chars at 9pt in the fixed 64pt trailing frame, `:256-260`) is not clipped
  in the popover; if it truncates, shorten the expanded form (drop "of") or widen
  the value frame for share rows.
- Grep: no `resetAt` symbol remains in `PopoverUsageSection.swift`.

### Part B — Row 19: VoiceOver label + help catalog for `Views/Transcript/`

This Part **is** the string catalog. Add `.accessibilityLabel(_:)` and
`.help(_:)` (and `.accessibilityValue`/`.accessibilityHidden` where noted) at
each anchor. No behavior change beyond assistive metadata. Labels are bare
`String` literals matching the existing `.help()` precedent in this file (no
`String(localized:)` — out of scope).

| # | File:line | Control | accessibilityLabel | .help() / value |
|---|-----------|---------|--------------------|-----------------|
| 1 | TranscriptToolbar.swift:66 | segmented `Picker("", …)` | `"Transcript view mode"` | — |
| 2 | TranscriptToolbar.swift:41-50 | Back (has text) | — | `.help("Back to session list")` |
| 3 | TranscriptToolbar.swift:140-143 | `A−` glyph | `"Decrease text size"` | `.help("Decrease transcript text size")` |
| 4 | TranscriptToolbar.swift:145-148 | `A+` glyph | `"Increase text size"` | `.help("Increase transcript text size")` |
| 5 | TranscriptToolbar.swift:152-160 | Copy (has text) | — | `.help("Copy entire conversation")` |
| 6 | TranscriptToolbar.swift:164-169 | `Find ⌘F` (reads "Find command F") | `"Find in transcript"` | `.help("Find in transcript (⌘F)")` |
| 7 | TranscriptToolbar.swift:178-186 | `All` (has text) | — | `.help("Show all message types")` |
| 8 | MessageTypeChip.swift:22-32 | toggle (has text) | — | `.accessibilityValue(isVisible ? "shown" : "hidden")` |
| 9 | MessageTypeChip.swift:35-37 | prev `∧` glyph | `"Previous \(type.label)"` | `.help("Previous \(type.label) message")` |
| 10 | MessageTypeChip.swift:41-43 | next `∨` glyph | `"Next \(type.label)"` | `.help("Next \(type.label) message")` |
| 11 | TranscriptFindBar.swift:16 | decorative magnifyingglass | — | `.accessibilityHidden(true)` |
| 12 | TranscriptFindBar.swift:25-32 | clear (image) | `"Clear search"` | `.help("Clear search")` |
| 13 | TranscriptFindBar.swift:47-51 | prev match (image) | `"Previous match"` | `.help("Previous match")` |
| 14 | TranscriptFindBar.swift:54-58 | next match (image) | `"Next match"` | `.help("Next match")` |
| 15 | TranscriptFindBar.swift:64-72 | close (image) | `"Close find bar"` | `.help("Close find bar")` |

The star (`:62`) already has a dynamic label; add `.help(isFavorite ? "Remove
from favorites" : "Add to favorites")` for parity (optional, item 16). The chip
nav labels **must** interpolate `type.label` (dynamic) — a static
"Previous"/"Next" would technically satisfy "has a label" while every chip's
arrows read identically, defeating the navigation-clarity goal. To keep that
requirement testable without view introspection, build the two labels from a
pure static helper `MessageTypeChip.chipNavLabel(_ direction:type:) -> String`
(returning `"Previous \(type.label)"` / `"Next \(type.label)"`) that the
`.accessibilityLabel` modifiers at rows 9–10 call, rather than interpolating
inline.

**Implementation slices (B)** — one slice per file: B1 `TranscriptToolbar.swift`,
B2 `MessageTypeChip.swift`, B3 `TranscriptFindBar.swift`.

**Acceptance criteria (B)** — falsifiable:

- Every anchor in the table gains the specified modifier; grep of the three
  files finds no `Text("A−")`/`Text("A+")`/`Text("∧")`/`Text("∨")` or `Image`-
  only find-bar button without an adjacent `.accessibilityLabel`.
- `MessageTypeChip` prev/next labels contain `type.label` — verified through the
  pure static `MessageTypeChip.chipNavLabel(_ direction:type:)` (called by both
  the `.accessibilityLabel` modifier and the test, so it is not a tautology on
  `type.label` alone): `chipNavLabel(.prev, a) != chipNavLabel(.prev, b)` for two
  `MessageType` values, and each output contains the matching `type.label`. No
  view-tree introspection (the target has no `ViewInspector`).
- `magnifyingglass` at `:16` is `.accessibilityHidden(true)`.

### Part C — Row 29: fill the four highest-traffic remediation slots

Two mechanical changes per target, plus a routing rule for the rest.

1. **Retry closure** — add `action: ("Retry", { Task { await loadData() } })`
   to the load-failure `AlertBanner` at the four targets:
   `SessionsPageView.swift:149`, `ReposView.swift:44`,
   `SourcePulseView.swift:74`, `TimelinePageView.swift:232`. The closure is
   uniform because each file already exposes `loadData()` as its
   `.task`/`onRefresh` entrypoint — no new load method, no new
   DatabaseManager read.

2. **Presenter routing** — at each target's catch, replace
   `error.localizedDescription` with
   `ServiceErrorPresenter.displayMessage(for: error)`:
   `SessionsPageView.swift:407`, `ReposView.swift:100`,
   `SourcePulseView.swift:137` (and `:169`), `TimelinePageView.swift:405,:420,
   :437`, plus `SourcePulseView.swift:178` (the `costsError` catch — presenter
   routing **only**, no Retry; see below). Safe: the presenter falls back to
   `localizedDescription` for non-service errors.

**Excluded by design** (must not get Retry): the transient `actionStatus`
banners `SessionsPageView.swift:152` and `TimelinePageView.swift:236` (they
report completed mutations, not reloadable failures); and the `costsError`
banner `SourcePulseView.swift:98` (a separate cost load with its own entrypoint).
The `costsError` catch at `SourcePulseView.swift:178` **does** get the presenter
swap (so its text is structured too) but **not** a Retry closure — retry for the
cost load is deferred to the follow-up batch.

**Routing rule for the other ~40 sites (follow-up, not this Part's scope).** At
each catch block whose resulting `String` feeds an `AlertBanner`, replace raw
`error.localizedDescription` interpolation with
`ServiceErrorPresenter.displayMessage(for: error)`. Retry-able load-failure
banners that already have a `loadData()` — `ActivityView.swift:23`,
`AgentsView.swift:25`, `ProjectsView.swift:48`, `MemoryView.swift:60`,
`WorkGraphView.swift:44` (the un-targeted twin of `ReposView:44`) — are the
next batch. Distinct classes that want a **different** action, not data-Retry:
permission-gated static banners (`ErrorDashboardView.swift:23`,
`LogStreamView.swift:57`) and the settings gate `ObservabilityView.swift:26`
want "Open Settings", not Retry; the "service unavailable" `EmptyState`s
(`PerformanceView.swift:23`, `TraceExplorerView.swift:24`) are retry-able while
their sibling "no data yet" states are not — the retry/no-retry split is
per-branch, not per-file. Sheet-local / inline / status-enum
`localizedDescription` uses (e.g. `UndoSheet.swift:322`,
`RenameSheet.swift:519`, `AISettingsSection.swift:275`) are separate surfaces,
not banners — excluded from the rule.

**Implementation slices (C)** — one per target file: C1 SessionsPageView,
C2 ReposView, C3 SourcePulseView, C4 TimelinePageView. C3 must rebase onto three
concurrent edits to `SourcePulseView.swift`, all in disjoint regions — compose,
don't collide, and do not cite frozen line numbers when landing C3:
- `docs/source-health-predicate-design-2026-07.md` (row 2) rewrites the health
  badge (`:512-528`, call site `:268`) and the `Search N%` pill (`:296`).
- `docs/service-resilience-design-2026-07.md` Part B (row 9) replaces the
  live-poll `catch { liveSessions = [] }` at `:120-127` and the Live section gate
  at `:65`; Part C (row 12) adds a `parseFailureCount` chip to the `factPill` row
  at `:291-304`.
This Part's `:74` AlertBanner and `:137`/`:169`/`:178` catch swaps are disjoint
from all of the above (error banner vs. badge/pill/live-poll), but land after or
alongside them and rebase; the `costsError` catch at `:178` in particular sits
beside row 2's pill work.

**Acceptance criteria (C)** — falsifiable:

- Each of the four target `AlertBanner`s passes a non-nil `action` whose label
  is `"Retry"`; `MigrationHistoryView.swift:68` remains the fifth.
- Each target's catch assigns `ServiceErrorPresenter.displayMessage(for: error)`.
- The presenter's structure-preservation is already guarded by the existing
  `ServiceErrorPresenterTests.testCommandFailedIncludesNameMessageAndRetryPolicy_repro`
  (`:10-23`), which asserts a synthetic `.commandFailed` keeps name + message +
  retry policy and does not collapse to `localizedDescription`. Part C adds
  **no** new presenter test (the presenter is unchanged); its call-site swaps are
  verified by the greps here plus a manual smoke.
- `actionStatus` banners (`SessionsPageView:152`, `TimelinePageView:236`) still
  pass no `action`.

### Part D — Row 31: introduce a type-scaling pattern; apply to two surfaces

Introduce the scaling primitive; convert sidebar chrome + transcript body only.

1. **Type token layer in `Theme.swift`.** Mirror `MotionAware` exactly (pure
   helper + `ViewModifier` reading the environment + `View` extension), so the
   test has a real function to assert on. Add a pure
   `static func Theme.scaledFontSize(base: CGFloat, category: DynamicTypeSize)
   -> CGFloat` mapping a base point size and a resolved Dynamic Type category to
   an effective size (monotonic: larger category → ≥ size); then a
   `ScaledFont(size:weight:)` `ViewModifier` that reads
   `@Environment(\.dynamicTypeSize)` and applies `.font(.system(size:
   Theme.scaledFontSize(base: size, category: category), weight: weight))`; plus
   a `View.scaledFont(_ size:weight:)` extension. A call site swaps
   `.font(.system(size: 10.5))` for `.scaledFont(10.5)` and the size tracks the
   OS Dynamic Type setting. The modifier routes through the pure helper — the
   `MotionAware.effectiveAnimation` precedent — so the mapping is unit-testable
   without a rendered view; `@ScaledMetric` is **not** used for the font path,
   because it scales opaquely inside SwiftUI and would leave nothing pure to
   assert on (D4 would then be untestable). This is the single conversion pattern
   all future font sites follow; it is not applied broadly here.

2. **Sidebar — scale font AND width together.** Scaling the 10.5/8pt fonts
   without scaling the 160pt pin would clip `lineLimit(1)` labels — the pin fix
   is the load-bearing part. Drive the width from `@ScaledMetric var
   sidebarWidth = 160` and set it via
   `.navigationSplitViewColumnWidth(min:ideal:max:)` on `SidebarView` in
   `MainWindowView.swift` (the column-width API governs the split-view column;
   the inner `frame(160/160)` at `SidebarView.swift:47` must relax to
   `minWidth: sidebarWidth` or be removed so the two mechanisms don't fight).
   Convert the three font sites (`:21`, `:122/:125`, `:150/:153`) to
   `.scaledFont(...)`.

3. **Transcript body — compose with the existing knob across all four
   consumers, don't double-scale.** The body already scales via
   `@AppStorage("contentFontSize")` — but that value is read in **four**
   independent view structs, and the primary assistant/code render path is
   `SegmentedMessageView` (`ColorBarMessageView.swift:165` →
   `ContentSegmentViews.swift:66`), **not** `ColorBarMessageView`'s own five
   `.font(.system(size: fontSize))` sites (which fire only on the search-
   highlight fallback / thinking / unparsed-tool / error rows). Converting only
   `ColorBarMessageView` would scale a few secondary rows while the dominant
   markdown + tool content stayed on the raw `@AppStorage` value — inconsistent,
   worse than today. So feed `fontSize` through the scaled base at **every**
   transcript-body `contentFontSize` consumer: `ColorBarMessageView.swift`
   (`:168,:173,:182,:190,:197`), `ContentSegmentViews.swift:66`,
   `ToolCallView.swift:6`, and `ToolResultView.swift:6`. Compose OS size and the
   A−/A+ knob (e.g. `Theme.scaledFontSize(base: fontSize, category:)`) instead of
   multiplying; the persisted A± knob remains authoritative as the user's
   explicit override.

**Implementation slices (D)**

- D1: `Theme.scaledFontSize` pure helper + `ScaledFont` modifier +
  `View.scaledFont` in `Theme.swift`.
- D2: sidebar width (`@ScaledMetric` + column-width API) + 3 font conversions.
  **Not landable on anchors alone** — gated behind a live-build check that
  `.navigationSplitViewColumnWidth(min:ideal:max:)` actually governs the rendered
  width once the inner `frame(160/160)` is relaxed (see Risks).
- D3: transcript body base composition across all four `contentFontSize`
  consumers (`ColorBarMessageView`, `ContentSegmentViews`, `ToolCallView`,
  `ToolResultView`).
- D4: a pure size-mapping test on `Theme.scaledFontSize` (see Test plan) — the
  SwiftUI modifiers themselves are not unit-testable, so the testable surface is
  the pure helper the modifier calls, mirroring `MotionAware.effectiveAnimation`.

**Acceptance criteria (D)** — falsifiable:

- `Theme.swift` exposes `View.scaledFont(_:weight:)` and the pure
  `Theme.scaledFontSize(base:category:)` it calls; grep finds the scaled path
  used at the sidebar (`SidebarView.swift`) and **every** transcript-body
  `contentFontSize` consumer (`ColorBarMessageView.swift`,
  `ContentSegmentViews.swift`, `ToolCallView.swift`, `ToolResultView.swift`), and
  **not** broadcast across all 172 sites.
- Sidebar column width is driven by a `@ScaledMetric` value, verified by a build
  where the `frame(minWidth:160,maxWidth:160)` literal no longer pins width
  (grep: no `maxWidth: 160` on the sidebar frame).
- The pure helper `Theme.scaledFontSize(base:category:)` — which the `ScaledFont`
  modifier actually calls to compute its size (not a parallel dead function) —
  has a unit test asserting monotonic growth (larger `DynamicTypeSize` →
  ≥ effective size).
- Manual VoiceOver/Larger-Text smoke: at `AX5` the sidebar grows without
  clipping labels (recorded as EVIDENCE_PATH screenshot).

## Invariants affected

None of the ledger entries in `docs/invariants.md` (1–13) are touched. All four
Parts are read/render-only UI changes:

- Part A renders existing `usage_snapshots` rows differently; it adds no writer,
  so **Invariant 1 (Single-Writer Discipline)** is preserved by not being
  engaged — the collector at `StartupUsageCollector.swift:237-241` is unchanged.
- Parts B/C/D add assistive metadata, banner closures, and font modifiers; none
  reads or writes the DB, touches tiering (**Invariant 2/3**), FTS
  (**Invariant 5**), or MCP (**Invariant 12**).

No new invariant is introduced (these are polish fixes, not properties that must
survive every future change). No `scripts/invariant-gates.json` entry is added.

## Alternatives considered

- **Row 13, brief's literal predicate `limit == nil && isPercent(unit)`.** Lost:
  it also reroutes `remaining`/`used` percent meters (also `limit == nil`) away
  from their legitimate bar render, regressing the intent pinned by
  `PopoverUsageSectionTests.swift:212-234`. Share-scoping is the same result on
  today's data with the defensive path intact.
- **Row 13, render `resetAt` instead of deleting.** Lost (for now): an honest
  render wants a relative "resets in ~3h" (new `RelativeDateTimeFormatter`
  code) laid out in a 6pt-spaced popover; the absolute
  `formattedResetAt` reuse is inconsistent UX for a share (a share has no reset).
  Deleting the dead threading is the smaller honest diff; rendering can return in
  a dedicated pressure-meter Part.
- **Row 19, one merged `.accessibilityElement`.** Lost: the controls are
  independent buttons; merging would hide per-button actions from VoiceOver.
  Per-control labels are correct.
- **Row 29, edit the components to auto-inject Retry.** Lost: the components
  already support `action`; the gap is call sites, and a global auto-inject
  would staple Retry onto transient/permission banners that must not have it.
- **Row 31, inline `@ScaledMetric` at each of 172 sites.** Lost: violates
  minimum-diff and duplicates the primitive 172×; a single centralized modifier
  (the `MotionAware` precedent) is the house pattern.

## Test plan

- **Part A** — add to `macos/EngramTests/PopoverUsageSectionTests.swift`, all
  against pure static helpers (no view-tree introspection — the target has no
  `ViewInspector`):
  `testLimitlessSharePredicateIsTrue_repro` asserts
  `UsageMetricRow.isLimitlessShare(metric:"7d token share", limit:nil) == true`
  — a valid repro: the symbol does not exist before the fix, so the test fails to
  compile (fails) before and passes after.
  `testRemainingPercentStaysOnBarBranch_repro` asserts
  `isLimitlessShare(metric:"weekly remaining", limit:nil) == false` (scoped-
  predicate guard; also unbuildable before the symbol exists → valid repro).
  `testShareTextIsSelfLabeling` asserts the three expanded forms
  (`shareText(62,"7d token share",suffix:"") == "62% of 7d tokens"`,
  `shareText(41,"7d cost share",suffix:"") == "41% of 7d cost"`,
  `shareText(30,"5h token share",suffix:"") == "30% of 5h tokens"`) and the
  compact form (`shareText(62,"7d token share",suffix:"7d") == "62% 7d share"`).
  The existing remaining/used bar tests at `:212-234` and the `windowSuffix` test
  at `:47` must remain green unchanged (neither the predicate branch nor
  `windowSuffix` is altered). `StartupUsageCollectorTests.swift:52,:62-63` are
  unaffected (DB layer already correct) — do not touch them.
- **Part B** — SwiftUI accessibility modifiers are not directly unit-testable;
  extract the label construction into the pure static
  `MessageTypeChip.chipNavLabel(_ direction:type:)` the modifier calls, and add
  `testChipNavLabelsAreTypeSpecific` asserting `chipNavLabel(.prev, a) !=
  chipNavLabel(.prev, b)` for two `MessageType` values and that each output
  contains the matching `type.label` (the string actually shipped, not a
  tautology on `type.label` alone). The remaining modifiers rely on the
  acceptance greps plus a manual VoiceOver smoke pass (EVIDENCE_PATH).
- **Part C** — no new unit test: the presenter is unchanged, and its
  structure-preservation is already covered by
  `ServiceErrorPresenterTests.testCommandFailedIncludesNameMessageAndRetryPolicy_repro`
  (`:10-23`). Part C's diff (Retry closures + call-site
  `localizedDescription → ServiceErrorPresenter.displayMessage` swaps, including
  the `costsError` catch at `SourcePulseView.swift:178`) is view wiring, verified
  by the acceptance greps (each target passes `action: ("Retry", …)`; each catch
  assigns the presenter) plus a manual smoke.
- **Part D** — add `testScaledFontSizeIsMonotonic` on the pure
  `Theme.scaledFontSize(base:category:)` helper that the `ScaledFont` modifier
  calls (base size + `DynamicTypeSize` → effective size grows with category — the
  real render path, not a parallel dead function), mirroring how
  `MotionAware.effectiveAnimation` is the testable seam. The no-clip behavior is a
  manual Larger-Text smoke (EVIDENCE_PATH screenshot).
- **Intentionally not tested**: the visual green→text change (A), hover
  `.help()` tooltips (B), and column-width growth (D) — verified by build +
  manual smoke, not unit tests.

## Rollout

- All four Parts are app-only; each is a normal app rebuild
  (`xcodebuild -project macos/Engram.xcodeproj -scheme Engram build`), no
  service rebuild, no migration, no backfill. Deploy to `/Applications` follows
  the `rm -rf` then `cp -R` rule in `CLAUDE.md`.
- No version/tag implication beyond the next app build.
- **Revert story**: each Part is an isolated diff — revert the single commit.
  Part A reverting restores the meter render; B restores silent controls; C
  restores raw error text; D restores fixed sizes. No data or schema state to
  unwind.

## Risks and open questions

- **Row 13 (medium)**: if an implementer ships the brief's broad predicate
  instead of the share-scoped one, `remaining`/`used` meters silently render as
  flat text — the guard test `testRemainingPercentStaysOnBarBranch_repro`
  exists to catch this.
- **Row 29 (low)**: `ServiceErrorPresenter.userFacingDetail` prefixes a case
  name and `[retry: policy]`; for service errors this makes the banner noisier
  than a bare message. **Open question**: is the structured detail the right
  end-user copy for a compact banner, or should the presenter grow a
  short/verbose split for banner vs. log surfaces? (Left open — current 2 caller
  sites already accept the structured form.)
- **Row 29 (medium)**: `SourcePulseView.swift` is under concurrent edit by
  **three** other specs — `docs/source-health-predicate-design-2026-07.md`
  (row 2, badge + pill) and `docs/service-resilience-design-2026-07.md` (row 9
  live-poll hold, row 12 chip). C3 will conflict on merge. Regions are disjoint
  (error banner vs. badge/pill vs. live-poll vs. chip), so the resolution is
  mechanical, but the implementer must rebase, not patch by frozen line. See the
  enumerated region map under Implementation slices (C).
- **Row 31 (high)**: scaling sidebar fonts without the width fix clips
  `lineLimit(1)` labels at large accessibility sizes — worse than today. The
  `@ScaledMetric` width + `navigationSplitViewColumnWidth` is load-bearing.
  **Open question**: does `.navigationSplitViewColumnWidth(min:ideal:max:)`
  actually override the inner `frame(minWidth:160,maxWidth:160)` on the shipping
  macOS version, or do the two width mechanisms fight? Must be settled by a
  live build before D2 lands — the spec's answer (relax/remove the inner frame)
  is the expected resolution but is unverified against a running app.
- **Row 31 (low)**: **Open question** — should OS Dynamic Type be a floor, a
  default, or a multiplier for the persisted transcript `contentFontSize`?
  Seeding from OS size could surprise users who set a manual A±. This Part
  treats the A± knob as the authoritative override and OS size as the base;
  confirm with product before shipping D3.
- **Row 19 (low)**: the exact VoiceOver reading of `Text("A−")`/`Text("∧")` on
  the shipping macOS version is assumed ("A minus" / a logic symbol) from the
  glyphs, not verified against a live screen reader; the label fix is correct
  regardless of the pre-fix reading.

**Rejected review finding (recorded for the record).** One reviewer flagged the
`MainWindowView.swift:26` citation (Current state, Row 31) as off-by-one —
claiming `.navigationSplitViewStyle(.balanced)` is at `:25`. Refuted at the
spec's cited HEAD: `git show 23dca547:macos/Engram/Views/MainWindowView.swift`
puts `.navigationTitle("")` at `:25` and `.navigationSplitViewStyle(.balanced)`
at `:26` (with `NavigationSplitView { SidebarView }` at `:14-15`), so `:13-15,:26`
is accurate; the reviewer read a drifted working tree (that same reviewer's
`SourcePulseView.loadData :77→:130` drift is the expected concurrent-edit
movement the spec already disclaims). The `ColorBarMessageView` fontSize site
`:189` **was** off by one and is corrected to `:190` throughout Part D (verified:
sites at `:168,:173,:182,:190,:197`).
