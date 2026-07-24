# Design Doc: Transcript find & rendering fidelity (UX-1)

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog rows 8, 10, 26 (UX-1a/1b/1a-rework). Composes with the accepted `source-health-predicate` baseline only insofar as both edit files under `macos/Engram/Views/` on adjacent branches; no shared symbols. No accepted baseline spec touches these files. **Three sibling mirror-follow-up specs do share this doc's hot files and must serialize on them (see the coordination note below):** `docs/transcript-paging-timing-design-2026-07.md` (rows 27/30 — `SessionDetailView.rebuildIndexed` + the match scan, and `ColorBarMessageView.roleHeader`), `docs/uiux-polish-a11y-design-2026-07.md` (row 31 Part D — threads a scaled `fontSize` through the same `ContentSegmentViews`/`ColorBarMessageView` leaves this doc threads `searchText` through), and `docs/build-provenance-perf-design-2026-07.md` (row 16 Part B — DEBUG spans around `parseWindow`/`rebuildIndexed`, no-op in Release).

> **Cross-spec coordination (integration pass, 2026-07-24).** `ColorBarMessageView.swift` and `ContentSegmentViews.swift` are edited by this spec (Part A: `searchText` param on `SegmentedMessageView`/`MarkdownText`/`CodeBlockView`/`HeadingView`/list leaves/`TableBlockView`) **and** by `docs/uiux-polish-a11y-design-2026-07.md` Part D (a `scaledFont`/composed-`fontSize` change on the same leaves and on `ToolCallView`/`ToolResultView`). The two are additive on the same signatures — one adds a `searchText: String = ""` parameter, the other rewrites a `.font(...)` modifier — so land them **serially on this file**, not in parallel, and thread both new inputs through the leaf initializers together. `SessionDetailView.rebuildIndexed` / the detached match scan are additionally touched by `docs/transcript-paging-timing-design-2026-07.md` Part A (append-only rebuild) — see this doc's Part B note about the hidden-type scan riding the same detached pass.

> **Citation basis.** The recon anchors quote HEAD `23dca547`. Every `path:line` below was personally opened and re-verified line-for-line at each concurrent checkout this doc passed through — `586fc6e0` (`feat/source-health-predicate`), `382693db` and `004d79c8` (`feat/adapter-format-drift`) — so the anchors are stable across the batch's live branches and resolve on whichever tree an implementer checks out. Concurrent work will keep drifting the line numbers; re-verify at implementation time.

## Problem

Three defects on the transcript surface, all reachable from a single interaction (click a keyword-search result → the detail view auto-opens with the query primed and the find bar shown, `SessionDetailView.swift:471-472`). The search carrier is already live, so all three now land on the *arrival* surface of a search, not on rare in-session actions.

1. **User turns render raw markdown (row 8).** `.user` messages have no case in the body switch and fall to the `default:` branch, which renders `Text(highlightedText(content))` — plain highlighted text (`ColorBarMessageView.swift:162-199`, default at `:195-199`). A user turn containing a fenced diff shows literal backticks and `##`, never the segmented renderer that `.assistant`/`.code` get. 1 of the 2 default-visible types renders wrong.

2. **Find lies about matches in hidden types (row 10).** The match scan snapshots `displayIndexed` (the *post-filter* set) and scans only that (`SessionDetailView.swift:156-161`). `defaultTypeVisibility` shows only `.user` + `.assistant` (`:85-89`), so on every fresh session open **7 of 9 `MessageType` cases are hidden** (`MessageTypeClassifier.swift:5-14`). A query matching only Tools/Thinking/Code/System reports a flat "No matches" (`TranscriptFindBar.swift:41-42`). The all-hidden empty state (`:358-368`) fires only when *everything* is filtered, so it never covers this case. The find bar is confidently wrong about the most common default state, not an edge case.

3. **Search destroys rich rendering (row 26).** For `.assistant`/`.code`, any non-empty `searchText` swaps `SegmentedMessageView` for `Text(highlightedText(content))` on the **raw source string** (`ColorBarMessageView.swift:163-170`, `computeHighlight` on raw `text` at `:122-144`). During a search, headings become `##`, tables become `|---|`, code cards become plain text, per-block Copy buttons vanish — exactly on the surface a searcher is reading. Row 8's one-line fix inherits this fork, so shipping row 8 alone regresses user turns into flat rendering under active search.

## Goals / Non-goals

**Goals**
- G1 (row 8): user turns render through `SegmentedMessageView` like assistant turns.
- G2 (row 10): ⌘F never reports "No matches" when matches exist in hidden types; instead it surfaces a count and a one-tap reveal that flips the *correct* gate for each hidden bucket.
- G3 (row 26): during an active search, `.assistant`/`.code`/`.user` keep rich segmented rendering with matches highlighted on the **rendered** text, without re-parsing markdown per keystroke.

**Non-goals**
- N1: A UTF-16 source→rendered offset map (as-main `RenderedBody`/`SourceMapSegment`). Engram find is message-granular (see Current state); a paint miss is cosmetic. Reversed under Alternatives.
- N2: Find-driven auto-expand of collapsed rows (mirror F12). Adjudicated out of scope with evidence under Alternatives.
- N3: Highlighting inside successfully-parsed tool rows and system bubbles. Flagged as an open scope decision, defaulted out (Risks Q3).
- N4: A distinct current-match accent color in Session mode (transcript-5, deferred at `docs/reviews/alignment-design-2026-06-14.md:196`). Not requested by this batch.

## Current state

- **Body switch** (`ColorBarMessageView.swift:162-200`): cases are `.assistant/.code`, `.thinking`, `.toolCall`, `.toolResult`, `.system`, `default`. `SegmentedMessageView` is reached **only** by `.assistant/.code` (`:165`) and **only** when `searchText.isEmpty` (`:164`); otherwise `Text(highlightedText)`.
- **Classifier bounds row 8's inputs** (`MessageTypeClassifier.swift:94-108`): `.user` is returned iff `systemCategory == .none` AND `role == "user"`; `systemPrompt`/`agentComm` return `.system` first (`:95-105`). So routing `.user` through the markdown renderer never captures plumbing — a clean, bounded input set.
- **Match scan** (`SessionDetailView.swift:151-171`): debounced 200ms, off-main `Task.detached`, keyed on `matchScanToken` = `displayVersion \u{1} searchText` (`:144`). `updateDisplayIndexed` bumps `displayVersion` (`:101`) so the scan re-runs after any filter/page change. Snapshot = `displayIndexed` (`:156`); matches use `content.lowercased().contains(query)` (`:159`). Navigation is **message-granular**: `matchIndices` holds row indices, `navigateFind`/`scrollTarget` scroll to a message id, not a character range.
- **Gate matrix** (`SessionDetailView.swift:111-125`): `isMessageVisible` switches on `systemCategory` FIRST — `.systemPrompt` → `showSystemPrompts`, `.agentComm` → `showAgentComm`, `.none` → `typeVisibility[messageType]`. Two independent gate families. `.system` MessageType arises IFF `systemCategory ∈ {.systemPrompt, .agentComm}` (`MessageTypeClassifier.swift:94-105`), so `typeVisibility[.system]` is dead and `.system` is absent from `chipTypes` (`:44`). Revealing hidden `.system` matches requires writing the `@AppStorage` toggles `showSystemPrompts`/`showAgentComm` (`SessionDetailView.swift:55-56`), NOT flipping `typeVisibility`; `onShowAll` (`:202`) sets only `typeVisibility` and cannot reveal them.
- **Hint slot** (`SessionDetailView.swift:251-267`): the partial-load hint is an `HStack` gated on `hasMoreToLoad && !searchText.isEmpty`, sitting outside `if showFind`. The row-10 hint reuses this slot's styling as a sibling banner with an independent gate.
- **Render fidelity** (`macos/Engram/Views/ContentSegmentViews.swift` — note: parent `Views/` dir, NOT the `Views/Transcript/` subdir where `ColorBarMessageView.swift`/`TranscriptFindBar.swift` live): the shared parse uses `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)` (`:26-29`), which **consumes** inline markers, so rendered characters differ from source — raw-source `computeHighlight` ranges misalign on the rendered string. Two NSCaches memoize the parse keyed on the **source string alone**: `MarkdownText.attrCache` on `NSString(text)` (`:14-33`) and `SegmentedMessageView.segmentCache` on `NSString(content)` (`:73-96`). `SegmentedMessageView` dispatches 8 segment kinds (`:105-123`); the text-bearing leaves are `MarkdownText` (`:37-47`), `CodeBlockView` (`:214-224` — **two branches**: `Text(SyntaxHighlighter.highlight(...))` when `!language.isEmpty` at `:214-218`, else `Text(verbatim: code)` for unlabeled fences at `:219-224`), `HeadingView` (routes through `MarkdownText.cachedAttributed`), `BulletListView`/`NumberedListView`/`TaskListView` (each embed `MarkdownText`, `:250/:272/:293`), and `TableBlockView` (per-cell `Text(verbatim:)`, `:316/:331`).

**Mirror corrections recorded:**
- The mirror/brief cite "PR #97" for the parse memoization. **No PR #97 exists** for this; the two source-keyed NSCaches were introduced together (`ContentSegmentViews.swift:14-33,73-96`), and the per-row `HighlightCache` comment references "#27" (`ColorBarMessageView.swift:11,232`). The *mechanism* — keys on `text`/`content` alone — is what must be preserved, regardless of PR number.
- Brief cites the row-10 scan snapshot at `:155`; the actual snapshot line is `SessionDetailView.swift:156`.
- Brief frames row 26 as "thread searchText into segment views" (implying one edit). It is a multi-leaf change (7 text-bearing leaves above).

## Proposed design

Minimum change per row. **Rows 8 and 26 are one interaction and land together** (row 8 alone regresses user turns under search). Row 10 is fully independent.

Each part below is independently landable with its own slices and acceptance criteria. A reader implementing one part can ignore the others.

---

### Part A — Row 8 + Row 26: rich rendering with rendered-text highlight

**A1. Remove the destroy-on-search fork and admit `.user`.** In `ColorBarMessageView.swift`, change the `.assistant, .code` case (`:163`) to `.user, .assistant, .code`, and drop the `if searchText.isEmpty` branch (`:164-170`): always render `SegmentedMessageView(content:searchText:)`. Delete `.user`'s reliance on the `default:` branch. The `default:` branch, `.thinking`, and the parse-failure tool fallbacks keep `highlightedText` (raw-source highlight is correct there — those paths render raw text, markers intact).

  The routing decision the switch makes (`:162-200`) lives inside `body: some View` and is not unit-testable headlessly. So extract the predicate into a pure static and route the body case through it, so the repro asserts on the production decision rather than a test-local reconstruction:
  ```
  static func usesSegmentedView(for type: MessageType) -> Bool  // true for .user, .assistant, .code
  ```
  The body case becomes `case _ where Self.usesSegmentedView(for: indexed.messageType): SegmentedMessageView(...)` (or equivalent), and the acceptance test asserts on `usesSegmentedView(for:)`.

**A2. Thread `searchText` into `SegmentedMessageView` and its text-bearing leaves.** Add a `searchText: String` parameter (default `""`) to `SegmentedMessageView`, `MarkdownText`, `CodeBlockView`, `HeadingView`, `BulletListView`, `NumberedListView`, `TaskListView`, `TableBlockView`. Do **not** re-key `attrCache`/`segmentCache` — the parse stays memoized on `text`/`content` alone; highlight is applied to a **value copy** of the cached parse after fetch.

**A3. Shared rendered-text highlight helper.** Add one pure static:
```
static func highlightRendered(_ attr: AttributedString, query: String, backgroundOnly: Bool = false) -> AttributedString
```
**Index bridge (exact, index-safe).** Do NOT scan `String(attr.characters)` for `String.Index` ranges and assign them onto the `AttributedString` — those are different index spaces and will not compile. Do NOT use `attr.characters.range(of:options:)` either — `AttributedString.CharacterView` is not a `StringProtocol`, so that method is unavailable. Use the same bridge `computeHighlight` already uses at `ColorBarMessageView.swift:129-138`, with the *rendered* string substituted for the raw source: let `rendered = String(attr.characters)`; loop `rendered.range(of: query, options: .caseInsensitive, range: searchStart..<rendered.endIndex)` for `String.Index` ranges; convert each with `Range(NSRange(range, in: rendered), in: attr)` to a `Range<AttributedString.Index>`; carry over computeHighlight's zero-width-match guard (`:139-141`). This is exact and needs no source→rendered offset map.

**Paint (background-only on syntax leaves).** `computeHighlight` sets BOTH `.backgroundColor = .yellow` and `.foregroundColor = .black` (`:136-137`). On plain markdown leaves that is fine, but on syntax-highlighted code the `.black` foreground would overwrite the syntax colors on every matched run — flattening exactly the rich rendering row 26 preserves. So `highlightRendered` paints `.backgroundColor = .yellow` always, and `.foregroundColor = .black` **only when `!backgroundOnly`**. Markdown leaves call it with the default (`backgroundOnly: false`); code/syntax leaves pass `backgroundOnly: true` so the yellow background layers over the syntax foreground without flattening it.

**Per-leaf application.** Each markdown leaf calls it on `MarkdownText.cachedAttributed(text)` (default paint). `CodeBlockView` has **two branches** and both must be highlighted with `backgroundOnly: true`: the `!language.isEmpty` branch highlights `SyntaxHighlighter.highlight(...)` output (`:214-218`); the empty-language branch (unlabeled fences, `:219-224`) currently renders `Text(verbatim: code)` and must become `Text(highlightRendered(AttributedString(code), query: searchText, backgroundOnly: true))`. `TableBlockView` cells wrap their verbatim string in `AttributedString` then highlight (default paint — table cells carry no syntax foreground). Any `Text(verbatim:)` leaf that must highlight switches to `Text(highlightRendered(AttributedString(cell), query: searchText))`.

**A4. Preserve memoization.** Highlight cost is O(rendered chars) per visible segment with **no re-parse**. If profiling shows recompute on unrelated re-renders (scroll/font drag), add a per-leaf single-slot memo keyed on `(text, query)` mirroring the existing `ColorBarMessageView.HighlightCache` (`:230-236`) — but ship without it first; the parse (the expensive part) is already cached.

**Why rendered-text, not a source map:** because find is message-granular (navigation scrolls to a row, never a char range, `SessionDetailView.swift:157-169`), a paint miss is purely cosmetic and self-corrects on scroll. The A3 bridge (scan `String(attr.characters)`, map each `String.Index` range onto the `AttributedString` via `Range(NSRange(range, in: rendered), in: attr)`) yields an index directly usable on the same `AttributedString`. No UTF-16 source map is needed (Alternatives).

**Acceptance criteria (A):**
- A user turn routes through `SegmentedMessageView` (so a fenced code block renders a code card, not backticks), both with and without an active search. *(falsifiable: `usesSegmentedView(for: .user) == true`)*
- With a non-empty query, `.user`/`.assistant`/`.code` still route through `SegmentedMessageView` (no `searchText.isEmpty` fork), so a heading + table stay rendered (not `##`/`|---|`). *(falsifiable at the testable surface: `usesSegmentedView(for:)` routing + a source-scan test that the `if searchText.isEmpty` fork is gone and the leaves take `searchText` — SwiftUI render output itself is not headlessly asserted; see "Intentionally not tested".)*
- `highlightRendered` on `**bold**`-rendered text with query `bold` paints the run for `bold`; `String(result.characters)` contains no `*`. *(falsifiable)*
- `attrCache`/`segmentCache` keys remain `text`/`content` only (no query in key). *(falsifiable: source-scan test)*

---

### Part B — Row 10: honest hidden-type match count with correct reveal

**B1. Count hidden matches in the existing detached scan.** In `updateMatchIndicesDebounced` (`SessionDetailView.swift:151-171`), after computing `matchIndices` over `displayIndexed`, run a second partition over the **full** `indexedMessages` inside the *same* `Task.detached` (one pass, no extra debounce). For each message whose content matches `query` AND which `isMessageVisible(...)` returns `false`, bucket it by **the gate that hid it**:
- `systemCategory == .systemPrompt` → bucket `systemPrompt` (reveal: `showSystemPrompts = true`)
- `systemCategory == .agentComm` → bucket `agentComm` (reveal: `showAgentComm = true`)
- else → bucket by `messageType` (reveal: `typeVisibility[type] = true`)

Extract this as a pure static for testability. The reveal-key representation is load-bearing (B3): system buckets key on `systemCategory`, type buckets on `MessageType`, so define the discriminator explicitly rather than leaving its shape to be inferred:
```
enum RevealKind: Equatable {
    case systemPrompt                 // reveal: showSystemPrompts = true
    case agentComm                    // reveal: showAgentComm = true
    case typeVisibility(MessageType)  // reveal: typeVisibility[type] = true
}
struct HiddenMatchBucket: Equatable {
    let label: String
    let revealKind: RevealKind
    let count: Int
}

static func hiddenTypeMatchSummary(
    _ all: [IndexedMessage], query: String,
    typeVisibility: [MessageType: Bool],
    showSystemPrompts: Bool, showAgentComm: Bool
) -> [HiddenMatchBucket]
```
Assign its result to a new `@State var hiddenMatchBuckets` alongside `matchIndices` under the same `Task.isCancelled` guard (`:162-163`). Also clear it in the empty-query early return (`:153`) next to `matchIndices = []`, so an emptied query leaves no stale bucket set (harmless in render because B2's gate ANDs `!searchText.isEmpty`, but kept for state hygiene).

**Count scope.** `hiddenTypeMatchSummary` scans `indexedMessages`, which on a partially-loaded transcript (`hasMoreToLoad`) is only the loaded prefix (paged by `initialTranscriptLimit`, `:130-132`). So the hidden-match count is scoped to loaded messages — exactly the same scope as the existing partial-load hint (`:251-267`), and the two banners coexist without contradiction (a user who reveals every bucket may still have matches in unloaded pages, which the partial-load hint already communicates).

> **Coordination with `docs/transcript-paging-timing-design-2026-07.md` (row 27, Part A — integration pass 2026-07-24).** That spec makes `rebuildIndexed` append-only (classify only the newly-paged messages) and makes the *match scan* (its "term 3") extend `matchIndices` by scanning only the appended `displayIndexed` slice when a query is active. This Part B hidden-type scan is **query-triggered, not page-triggered**: it re-runs on `matchScanToken` change (`displayVersion` ⊗ `searchText`), does one full pass over the loaded-prefix `indexedMessages`, and is already off-main + debounced in the same `Task.detached`. It composes cleanly — Part A's incremental-append optimization concerns the per-page cost of `matchIndices`, while `hiddenMatchBuckets` is recomputed wholesale per query change and is not on the page-append hot path. Whichever lands second on `SessionDetailView.updateMatchIndicesDebounced` must keep both the incremental `matchIndices` extension (row 27) and the full-prefix `hiddenTypeMatchSummary` pass (this Part) inside the one detached scan; do not fold the hidden-type pass into the per-page incremental slice, or a filter toggle would leave stale hidden-match counts.

**B2. New hint banner.** Add a sibling banner beside the partial-load hint (`:251-267`), gated independently on `!searchText.isEmpty && !hiddenMatchBuckets.isEmpty`. Copy: `"N more matches in hidden types (Tools, Thinking, System)"` where the type list joins bucket labels (`MessageType.label`, and "System Prompts"/"Agent Comm" for the two `systemCategory` buckets).

  The tap target's reveal step must be a pure static so "reveal flips the correct gate" is falsifiable against production code rather than re-implemented in the test:
  ```
  static func applyReveal(
      _ kinds: [RevealKind],
      typeVisibility: inout [MessageType: Bool],
      showSystemPrompts: inout Bool,
      showAgentComm: inout Bool
  )
  ```
  For each `revealKind`: `.typeVisibility(type)` → `typeVisibility[type] = true`; `.systemPrompt` → `showSystemPrompts = true`; `.agentComm` → `showAgentComm = true`. The view tap calls `applyReveal` on its `@State`/`@AppStorage` bindings; the test drives `applyReveal` on local vars and then asserts `isMessageVisible(...)` returns true for the previously-hidden message. After reveal, `updateDisplayIndexed()` bumps `displayVersion`, the scan re-runs, the hidden matches enter `matchIndices`, and the banner's gate goes false.

**B3. `.system` sub-partitioning is mandatory.** Because both `systemPrompt` and `agentComm` classify to `MessageType.system` but need *different* toggles, the bucket key is `systemCategory` for those two, never `MessageType.system`. A single "System" label with one tap target would silently fail to reveal one population — verified at `SessionDetailView.swift:111-125` + `MessageTypeClassifier.swift:94-105`.

**Acceptance criteria (B):**
- On a fresh session (default visibility) with a query matching only a Tool row, the find bar's context shows a hidden-match hint with count ≥ 1 (not a bare "No matches"). *(falsifiable: `hiddenTypeMatchSummary(...)` returns a `.tool` bucket count 1)*
- A query matching only an `agentComm` message buckets under `agentComm`, and the reveal action sets `showAgentComm`, not `typeVisibility`. *(falsifiable)*
- Tapping reveal flips the gates such that the next `isMessageVisible` returns true for the previously-hidden matches. *(falsifiable via gate re-eval)*
- The banner does not appear when all matches are already visible. *(falsifiable: empty buckets → gate false)*

---

## Invariants affected

**None** of the **13** ledger entries in `docs/invariants.md` (##1–13: Single-Writer, Subagent-Stay-Skip, Tier Visibility, Parent-Detection Parity, FTS Rebuild Versioning, Tests-Avoid-Production-Data, Bundle Hygiene, Service Socket Security, Startup Backfills Ordered/Idempotent, Manual Unlink, Schema Migrations Idempotent, EngramMCP Read-Only, JSONL Tail Checkpoints) are touched. All three parts are pure UI rendering/filter surfaces — view-local `@State`/`@AppStorage` only, no schema, IPC, writer, tier, or parent-detection impact. The two entries closest to this doc's own risk claims are affirmed explicitly:
- **#9 Startup Backfills Are Ordered and Idempotent** — not engaged: no startup backfill is added or reordered; the design touches only `Views/` and `EngramService`/`StartupBackfills` are untouched.
- **#11 Sessions Schema Migrations Are Idempotent** — not engaged: no schema migration is added; `EngramCoreWrite`/schema are untouched (the only writes are `@AppStorage`/`UserDefaults`).

No new invariant is proposed: "find completeness" is a UX property already made falsifiable by the acceptance tests; promoting it to a ledgered red line would be over-formalization for a single view.

## Alternatives considered

- **as-main UTF-16 source→rendered offset map** (`as-main/AgentSessions/Services/MarkdownBodyRenderer.swift:764-776`, `RenderedBody.swift:62-70`): render-first-then-scan with an offset map so highlights map from source ranges. Reversed: their renderer keeps source offsets because their find navigates to char ranges; Engram navigates to message rows (`SessionDetailView.swift:157-169`), so a paint miss is cosmetic and the map's per-render cost buys nothing. Post-render per-segment scan on `String(attr.characters)` is strictly cheaper and sufficient.
- **Re-key the parse caches on `text+query`** to memoize highlighted output: rejected — re-parses markdown every keystroke, undoing the `attrCache`/`segmentCache` memoization (`ContentSegmentViews.swift:14-33,73-96`) and regressing typing on large transcripts. Highlight is layered after the cached parse instead.
- **Row 10 reveal via `onShowAll`** (`SessionDetailView.swift:202`): rejected — it sets only `typeVisibility` and cannot reveal `systemPrompt`/`agentComm` matches; its own "Tap All to reset" copy (`:363`) is already misleading for system content. The reveal must additionally write the two `@AppStorage` toggles.
- **Mirror F12 — find-driven auto-expand of collapsed rows** (as-main `TranscriptBlockListView.swift:497-515`): out of scope. Within Engram's default-visible set (user/assistant/code) **nothing collapses** — those render fully. The only collapse-by-default surfaces are `CollapsibleSystemBubble` (`ContentSegmentViews.swift:355`), `ToolResultView` (>5 lines, `ToolResultView.swift:22-25`), and `ToolCallView` (params truncated, `:89,129`) — **all hidden-by-default types**. So find never hides a highlight behind a collapse for default-visible content; auto-expand only matters *after* row 10 reveals the type, making it a strictly narrower follow-on (reveal the collapsed *row body* after revealing its *type*). Folding it here would add per-row expansion-state plumbing to the scan for marginal benefit. Deferred.
- **Grade-change vs prior deferral**: row 26 = finding `session-detail-transcript-7`, graded 🟡 Low (`docs/reviews/ux-flow-review-2026-06-14.md:1375`) and deferred at `docs/reviews/alignment-design-2026-06-14.md:196` (note corrected path — brief said `docs/alignment-design...`). The deferral was on **file ownership** (`ColorBarMessageView.swift`/`ContentSegmentViews.swift` were unowned by that WP), not merit. The grade rises now because the search carrier landed (`SessionDetailView.swift:471-472`): the flat-render fallback fires on the *landing surface* of every keyword-search→transcript click — a silent wrong answer at the moment of arrival, not a rare in-session action.

## Test plan

Product runtime is Swift-only; all tests are Swift under `macos/EngramTests/` (target `EngramTests`, `@testable import Engram`, glob `- path: EngramTests` in `macos/project.yml:325-345`). Every defect lives in `body`, so each fix extracts its decision into a pure static and tests that — the established pattern. Fixtures need no DB and no UI: `ChatMessage(role:content:systemCategory:)` + `IndexedMessage.build(from:)` (`IndexedMessage.swift:4-28`) build rows in-process, as `TranscriptLabelAndCopyTests` and `TodayWorkbenchScopeTests` already do.

**Part A (rows 8 + 26)** — in `macos/EngramTests/TranscriptLabelAndCopyTests.swift`:
- `func testUserMessagesUseSegmentedView_repro()` — assert a new static `ColorBarMessageView.usesSegmentedView(for: .user) == true` (and `.assistant`, `.code`). Fails before A1 (`.user` returns false / falls to default).
- `func testHighlightPaintsOnRenderedMarkdownNotRawSource_repro()` — build the rendered `AttributedString` for `**bold**`, call `highlightRendered(_:query:"bold")`, assert (a) `String(result.characters)` has no `*`, (b) the run covering `bold` carries `.backgroundColor`. Template: `SnippetHighlighterTests.swift:5-40`. Fails before A3 (raw-source ranges misalign).
- Source-scan (normalized-substring, per `TranscriptFindTests.swift:44-89`) asserting `attrCache`/`segmentCache` are not keyed on query.

**Part B (row 10)** — in `macos/EngramTests/TranscriptFindTests.swift`, reusing the `indexed(category:type:)` builder pattern at `TodayWorkbenchScopeTests.swift:143-149`:
- `func testFindReportsMatchesInHiddenTypes_repro()` — build messages incl. a `.tool` row containing the query; call `hiddenTypeMatchSummary(...)` with the default two-key visibility built inline (`[.user: true, .assistant: true]`, everything else absent → hidden) — `SessionDetailView.defaultTypeVisibility` is `private static` (`:85`) and NOT reachable through `@testable import` (which exposes only `internal`), so construct the dict inline exactly as the existing tests do; assert a `.tool` bucket with count 1. Fails before B1 (no such function; scan only saw `displayIndexed`).
- `func testHiddenSystemMatchBucketsBySystemCategory_repro()` — an `agentComm` message matching the query buckets under `agentComm` with `revealKind == .agentComm` (not `.typeVisibility(.system)`). Guards B3.
- `func testHiddenMatchRevealFlipsCorrectGate()` — after applying a bucket's `revealKind`, `isMessageVisible(...)` returns true for that message.

**Intentionally not tested:** SwiftUI render output of the banner and the leaf highlight overlay (no headless render harness; covered by source-inspection of the wiring, as `ViewMainThreadReadTests.swift:243-260` does for `SegmentedMessageView`). Exotic-Unicode grapheme behavior of `.caseInsensitive` range on rendered text is spot-checked at implementation, mirroring the ß caveat already documented at `ColorBarMessageView.swift:125-128`.

## Rollout

- App-only (SwiftUI) change; no service, schema, or migration. Rebuild `Engram.app` (`xcodebuild -project macos/Engram.xcodeproj -scheme Engram build`); no `EngramService` rebuild required. No backfill, no version/tag gate.
- Parts A and B are independent PRs. A must ship as a unit (A1+A2+A3 together) — landing A1 without A2/A3 regresses `.user`/assistant turns to flat rendering under search.
- Revert story: each part is a self-contained view diff; `git revert` of the part's commit restores prior behavior with no data or state to unwind.

## Risks and open questions

- **R1 (medium) — leaf-coverage gap.** A row-26 pass that patches only `MarkdownText` silently drops highlights in `CodeBlockView`/`TableBlockView`/list leaves during search. Mitigation: A2 enumerates all 7 text-bearing leaves; a render-inspection or per-leaf helper test per leaf.
- **R2 (medium) — count/highlight divergence (OPEN Q1).** The row-10 count scans **raw** `message.content` (`:159`) while row-26 highlights the **rendered** text (markers consumed). A query containing markdown markers (`**`, `` ` ``, `|`) can be counted yet paint nothing, or vice-versa. **Open question:** accept this divergence for marker-containing queries (rare) and document it, or also scan rendered text for the count (larger scope, and rendered text isn't available off-main without the parse)? Defaulting to *accept + document*; flag for product sign-off.
- **R3 (low) — row-26 scope for tool/system rows (OPEN Q3).** Even after row 10 reveals Tool/System types, a match inside a *parsed* `ToolCallView`/`ToolResultView`/`CollapsibleSystemBubble` is counted but shown **unhighlighted** (those views take no `searchText`). **Open question:** extend row 26's highlight to tool/system rows, or scope to user/assistant/code only? Defaulting to *scope to user/assistant/code*; tool/system highlight is a clean follow-on.
- **R4 (low) — global side effect of system reveal.** The row-10 reveal for system buckets writes `showSystemPrompts`/`showAgentComm`, which are global `@AppStorage` (`:55-56`) affecting all sessions, unlike per-session `typeVisibility`. This matches the existing "Show System Prompts" settings semantics; accepted.
- **Open Q2 — reveal UX granularity.** Single tap reveals *all* hidden buckets vs per-bucket reveal chips. Not fixed by code; product choice. Spec assumes single "reveal all" tap for minimum surface; revisit if per-bucket is wanted.
- **Open Q4 — VoiceOver.** The find bar has no a11y announcement today; whether the hidden-match count must be announced is unresolved. Out of scope unless a11y requirements are raised.
