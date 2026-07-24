# Design Doc: Transcript Paging Cost & Per-Turn Duration Chip

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog rows 27 (Q4) and 30
  (UX-7); composes with `docs/tail-parse-design-2026-07.md` (reuses its
  byte-boundary primitives) and Invariant 13 in `docs/invariants.md`. Prior art
  cross-referenced read-only as `as-main/…` (Agent Sessions origin/main
  @ v4.6.4).

> Citation note: the recon that seeded this doc pins line numbers at HEAD
> `23dca547`. This doc's `path:line` anchors were personally re-verified against
> the working tree at HEAD `586fc6e0`, and again at the branch's current HEAD
> (`feat/adapter-format-drift`, `94d3f65`); the load-bearing anchors (windowed
> helper loop, `rebuildIndexed`, `ChatMessage`, `replayDurationMs`,
> `ColorBarMessageView` header) match to within a line or two at all three.
> Concurrent implementation on other branches will drift them; treat every anchor
> as a lead to re-verify, not a fact to copy.

Two backlog rows share the SwiftUI transcript data path
(`SessionDetailView` → `MessageParser` → `IndexedMessage` →
`ColorBarMessageView`). They are bundled because Row 30's turn-walk rides the
same per-page rebuild that Row 27 makes cheaper, but each part below is
independently landable — a reader implementing one may ignore the other, with
the single sequencing caveat called out in "Cross-row coupling".

---

## Problem

**Row 27 — paging is quadratic in loaded prefix.** Transcripts above
`transcriptPageThreshold = 800` messages page in `transcriptPageSize = 500`
chunks (`SessionDetailView.swift:13-14`). Each "Load more" click:

1. Re-parses the JSONL file from byte 0, skipping `offset` already-produced
   messages before collecting the next page — the shared windowed helper opens a
   fresh `StreamingLineReader` at file start every call
   (`CodexAdapter.swift:428-437`). Page *k* parses `500·k` lines.
2. Re-classifies the **entire** loaded prefix: `rebuildIndexed` snapshots all of
   `messages` and runs `IndexedMessage.build` over it
   (`SessionDetailView.swift:1006-1019`; `IndexedMessage.swift:17-27`), then
   `updateDisplayIndexed` re-filters the whole `indexedMessages` array
   (`SessionDetailView.swift:91-102`).
3. *(Conditional)* re-runs the O(N·content) find-match scan — but only when a
   find query is active; `updateMatchIndicesDebounced` early-returns on an empty
   query (`SessionDetailView.swift:153`).

Measured worst case: a 10,000-message session paged 500 at a time is
~20 "Load more" clicks; total lines parsed across the page-through is
`Σ 500·k ≈ 105,000` — an order of magnitude over the 10,000 the file contains,
plus ~20 full-prefix classify/filter passes.

**Scale honesty (unverified — live user data under `~`, read-only, not
in-repo):** ~421 of ~33,525 indexed sessions exceed the 800-message threshold.
"Load all" is already O(n) and one click (`appendMessages(all:)` →
`limit == nil` → `readObjects` reads the file once, `SessionDetailView.swift:1037-1046`,
`CodexAdapter.swift:397-413`). So the quadratic manifests **only** via repeated
incremental "Load more", never via the one-click path. This materially weakens
the M-effort justification and drives the scope decision below (see Part A vs B
and Alternatives).

**Row 30 — the transcript UI cannot show per-turn wall-clock, though the
adapters already parse it.** `ChatMessage` has four fields and no timestamp
(`MessageParser.swift:11-18`), so the render path is blind to times that
`NormalizedMessage.timestamp` already carries (`SessionAdapter.swift:71`) and
that `adapterMessages` **discards** at construction
(`MessageParser.swift:184`). Similar duration arithmetic already exists, but in
the **EngramService process, not the app** — `replayDurationMs` diffs
consecutive ISO timestamps (`EngramServiceReadProvider.swift:1625-1627`, a
`private static` in the service target) — and it is message-to-message, lives
across the service socket, and is consumed only as replay pacing
(`ReplayState.swift:12`). It is **not** reused by the in-app transcript render;
Part C deliberately reuses the app-side `ReplayState.parseISO` instead (see
Part C) rather than reaching across the process boundary.

---

## Goals / Non-goals

**Goals**

- Row 27: make a full incremental page-through of a large transcript O(n) total,
  not O(n²), without regressing the MCP stateless pager or "Load all".
- Row 30: render a per-turn duration chip in the transcript, degrading honestly
  (no chip when a timestamp is missing/unparseable/out-of-order), reusing times
  adapters already parse.

**Non-goals**

- Per-tool / per-message durations (Row 30). Tool records are dropped before
  `ChatMessage` exists (`MessageParser.swift:177`) and `.toolCall`/`.toolResult`
  are content-pattern guesses (`MessageTypeClassifier.swift:50-63`); pairing them
  would time heuristics. Rejected under Alternatives.
- Tail-first / reverse cold paint (Row 27). Incompatible with a genuinely paged
  forward view; rejected under Alternatives.
- Any change to the MCP `StreamMessagesOptions.offset/limit` **produced-message**
  semantics (Row 27). The byte cursor is strictly additive.
- Any schema, DB, or `file_index_state` write. Both rows are read/parse/render
  paths only.

---

## Current state

**Windowed paging (Row 27).** `JSONLAdapterSupport.windowedMessagesWithMetadata`
(inside `CodexAdapter.swift:390-448`) is the shared paged reader. Its
early-stopping branch (`CodexAdapter.swift:420-438`) opens
`StreamingLineReader(fileURL:)` at file start, then
`produced += 1; if produced <= offset { continue }` until `messages.count >=
cappedLimit`. Correction to the mirror's "CodexAdapter-specific" framing: this
helper is **shared by seven JSONL adapters** — ClaudeCode
(`ClaudeCodeAdapter.swift:450`), Codex, Copilot, Antigravity, CommandCode, Iflow,
Qoder — so a fix here lands once for all seven. The transform is a **pure
per-line mapping** `(JSONObject) -> NormalizedMessage?` with no cross-line state
(`CodexAdapter.swift:360-395`), which is exactly what makes seek-resume sound.

`StreamingLineReader` has **no** seek/offset entry point (confirms the mirror):
`init` takes only `fileURL/chunkSize/maxLineBytes` and `readLines()` opens a
`FileHandle` at offset 0 (`StreamingLineReader.swift:25-113`). It trims
whitespace and **skips empty lines** (`:65-66`), so a byte cursor cannot be
derived from a line count — it must be tracked from raw bytes consumed.

`SessionDetailView` pages in **produced-message space**: `appendMessages` passes
`offset = loadedProducedCount` (`SessionDetailView.swift:1038`), and
`producedCount` counts pre-filter adapter messages (`MessageParser.swift:176`),
so role-filtered tool records still advance it. `rebuildIndexed` rebuilds over
the full `messages` snapshot each page (`SessionDetailView.swift:1006-1019`) and
`updateDisplayIndexed` re-filters the whole array + bumps `displayVersion`
(`:91-102`). `IndexedMessage.build` maps each message independently, no neighbor
access (`IndexedMessage.swift:17-27`).

**MCP paging is NOT random-access** (correction to the mirror's "verify"):
`MCPTranscriptReader.collectVisiblePageWindow` always requests
`StreamMessagesOptions(offset: 0, limit: rawLimit)` and re-streams from the start,
doubling `rawLimit` until enough visible messages accumulate
(`MCPTranscriptReader.swift:499-503`). It caches no byte cursor; it is stateless
per tool call. The counted offset/limit path must stay intact.

**Tail-parse primitives already exist** (`docs/tail-parse-design-2026-07.md`):
`readTailObjects` (`CodexAdapter.swift:142`, `handle.seek(toOffset:)` at `:159`),
`completeLineOffset` (last-newline scan, `:227`), and `boundaryHash`
(SHA-256 of the bytes before an offset, `:246`) — currently `private static` in
`JSONLAdapterSupport`. Invariant 13 (`docs/invariants.md:89-94`) governs their
**write-path** use (`file_index_state.parsed_offset` advances only to a
newline-complete boundary with a bounded hash). Row 27 is a **read-path** pager
and persists nothing, so it touches no ledger entry — but it reuses the same
newline-complete-boundary + boundary-hash-validation principle for its in-memory
cursor.

**Message model & timing (Row 30).** `ChatMessage` = `{id, role, content,
systemCategory}` (`MessageParser.swift:11-18`); `id` is a `let = UUID()`, so it
is omitted from the synthesized memberwise init — that is why the 10 production
construction sites pass only `role/content/systemCategory`. Correction to the
mirror's "14 construction sites": there are **10 production sites, all in
`MessageParser.swift`** (lines 184, 216, 237, 263, 284, 309, 322, 325, 383, 420);
the "14" counts four test sites. Only **one** production site — the adapter path
at `MessageParser.swift:184` — has a `NormalizedMessage` (hence a real timestamp)
in scope; the other nine are legacy fallback parsers reading raw JSON with no
timestamp. For every supported source the adapter path wins, so threading the
timestamp at `:184` alone covers all real sessions.

`replayDurationMs` (`EngramServiceReadProvider.swift:1625-1627`) parses ISO with
a fractional-seconds formatter falling back to a plain one
(`:1608-1623`), diffs to ms, and **clamps negatives with `max(0, …)`** because
pacing wants a non-negative wait. The identical dual-format parser also exists
app-side as `ReplayState.parseISO` (`ReplayState.swift:38-40`), and
`ReplayTimelineEntry` already carries `timestamp: String?` + `durationToNextMs:
Int?` (`ReplayState.swift:4-12`).

The chip's render target is `ColorBarMessageView.roleHeader`: the assistant
branch is `HStack(spacing: 6) { Text(label); Spacer(minLength: 0) }`
(`ColorBarMessageView.swift:94-100`) — a trailing chip inserts before the
`Spacer`. But the view receives one `IndexedMessage` and has no neighbor
context, so the duration must be **precomputed** in a sequence-aware pass and
threaded onto the row.

No bucketed "Xm Ys" duration formatter exists in the app today (only
`RelativeDateTimeFormatter`), so Row 30 needs a small new pure formatter.

---

## Proposed design

The minimum that meets the goals. Row 27 is deliberately split; Row 30 is one
slice. Each part is independently landable.

### Part A (Row 27) — append-only rebuild [always-on cost; recommended first]

Removes terms 2 and 3 for **every** "Load more" with an app-only diff and no
cross-module or adapter risk.

- Extract an append-only build entry point on `IndexedMessage`:
  `IndexedMessage.appending(_ newPage: [ChatMessage], to prior: [IndexedMessage],
  counts: [MessageType: Int]) -> (messages, counts)` that classifies **only**
  `newPage`, carries `typeIndex` counters forward from `counts`, and appends.
  The existing `build(from:)` stays for the first load.
- In `rebuildIndexed`, when the call is an **append** (not a session switch /
  filter toggle), call `appending` over just the new page instead of `build` over
  the whole snapshot. `appendMessages` already knows the page it just added;
  thread it through (e.g. `rebuildIndexed(appended: parsed)` with `nil` meaning
  full rebuild).
- Make the visible filter incremental to match: filter only the appended
  `IndexedMessage`s and append to `displayIndexed`, rather than re-filtering the
  whole array in `updateDisplayIndexed`. Full rebuild remains the path for a
  filter-toggle (`displayVersion` still bumps so the conditional match scan
  re-runs).
- Term 3 (match scan) is already conditional; with an incremental append the
  scan can extend `matchIndices` by scanning only the appended `displayIndexed`
  slice when a query is active. If that proves fiddly, leaving the full
  conditional scan is acceptable — it only fires while a find query is open and is
  already off-main and debounced (`SessionDetailView.swift:151-163`).

**Result:** each "Load more" does O(page) classify + filter, not O(prefix).

**Acceptance criteria (A)** — falsifiable:
- `IndexedMessage.appending(newPage, to: prior, counts:)` yields the same
  `(messages, counts)` as `build(from: prior + newPage)` — and, because `prior`
  arrives already built, it is structurally incapable of re-classifying it, so
  equivalence proves only `newPage` was classified.
- `typeIndex` counters carry forward across an append (no reset to the page's
  local indices).
- A filter-toggle still takes the full-rebuild path (`displayVersion` bumps, the
  conditional match scan re-runs), while a plain append does not re-filter the
  whole array.

### Part B (Row 27) — byte-seek resume cursor [Load-more-only; scoped, optional]

Removes term 1 (re-parse from 0). This is the bulk of the M effort and its
benefit is bounded (see Problem: "Load all" is already O(n); only repeated
incremental paging is quadratic). Land it **after** Part A, and only if the
parse-side quadratic is measured to still matter. Design in full so it is
buildable when justified:

- `StreamingLineReader`: add `func seek(toByteOffset: UInt64)` (or an
  `init(fileURL:startByteOffset:…)`) that positions the underlying `FileHandle`,
  and expose the **byte position after each yielded line** (a running counter of
  raw bytes consumed, incremented before the trim/skip so empties are counted).
  Because it trims/skips, the cursor is bytes-consumed, never a line count.
- Add a named cursor type — `struct ResumeCursor: Equatable, Sendable { var
  byteOffset: UInt64; var producedCount: Int }`. It **must** be a named
  `Equatable, Sendable` struct, **not a tuple**: `StreamMessagesOptions` is
  declared `public struct StreamMessagesOptions: Equatable, Sendable`
  (`SessionAdapter.swift:169`) and Swift cannot synthesize `Equatable` for a
  struct with a stored tuple property (tuples do not conform to `Equatable` even
  though `==` is overloaded for them), so a tuple field makes the type fail to
  compile.
- `StreamMessagesOptions`: add an **optional additive** `resumeCursor:
  ResumeCursor?`. When present, the windowed helper seeks to `byteOffset`,
  initializes `produced = producedCount`, and continues — never re-skipping
  from 0. When absent, behavior is byte-for-byte the current counted path.
  `offset`/`limit` produced-message semantics are unchanged, so the MCP stateless
  pager (`MCPTranscriptReader.swift:502`, always `offset: 0`, no cursor) is
  untouched.
- `WindowedMessagesResult`: add the **end cursor** (a `ResumeCursor` captured at
  the break point), plus a validation token — reuse tail-parse's `boundaryHash`
  over the bytes before `byteOffset` (`CodexAdapter.swift:246`) and an
  **inode/device** file-identity check captured when the cursor was minted.
  **Exclude file size from the identity token:** transcripts are append-only and
  typically grow *while the detail view is open*, so total size changes between
  Load-more clicks; gating resume on size-equality would false-reject every valid
  resume on a live transcript and silently force the counted re-parse fallback.
  `boundaryHash` over the prefix bytes *before* `byteOffset` is stable under
  append and is the sound check.
- `SessionDetailView` (the only stateful pager): persist the returned end cursor
  in view state and pass it back as `resumeCursor` on the next `appendMessages`.
  Before trusting it, re-validate boundary hash + file identity; on mismatch
  (transcript rewritten/truncated while the detail view is open), fall back to
  the counted re-parse from 0 — soundness over speed.
- Expose (or narrowly mirror) `completeLineOffset`/`boundaryHash` from
  `JSONLAdapterSupport` for cursor validation rather than inventing a new
  mechanism — compose with tail-parse, do not collide.

Excluded from Part B (stay O(n)/page, note explicitly): whole-document /
cross-line-state adapters — Gemini, Cline, Cursor(SQLite), OpenCode(SQLite),
Kimi (cross-line `turnIndex`/`hasMessageInTurn` accumulation while buffering all
`records`, `KimiAdapter.swift:150-177`, then a second pass keyed on
`lastAssistantByTurn`, `:179-193`), VsCode, Qwen, Windsurf. The
cursor is sound only for the pure per-line transform path.

**Acceptance criteria (B)** — falsifiable:
- A full incremental page-through of an N-message fixture, feeding each
  `WindowedMessagesResult.endCursor` back as `resumeCursor`, parses total lines
  `≤ c·N` (O(n)), not `≈ N²/2·pageFraction` — proven via the `#if DEBUG`
  `parsedLineCount` counter, since the counted and seek paths emit byte-identical
  messages and output-equivalence alone cannot falsify the quadratic.
- A rewritten/truncated prefix fails the `boundaryHash` (over the bytes before
  `byteOffset`) + inode/device identity check and falls back to the counted
  re-parse with correct output; file-size change alone (append growth) never
  triggers the fallback.
- The MCP stateless pager (`MCPTranscriptReader`, always `offset: 0`, no cursor)
  is byte-for-byte unchanged; existing `AdapterParityTests` offset/limit cases
  pass unedited.

### Part C (Row 30) — per-turn duration chip

- **Model:** add `timestamp` to `ChatMessage` as a defaulted optional. Use
  `var timestamp: String? = nil` **or** an explicit
  `init(role:content:systemCategory:timestamp: String? = nil)` — a plain
  `let timestamp: String?` would make it a required memberwise parameter and
  break all 10 sites, and a `let timestamp = nil` would be omitted from the init
  and be uncallable. Populate it **only** at `MessageParser.swift:184`
  (`timestamp: message.timestamp`); the other nine legacy sites take the nil
  default and compile untouched. Minimal diff = the type + one site.
- **Turn walk:** a sequence-aware pass keyed on `ChatMessage.role` (deterministic;
  the parsers set `role == "user"` directly — `MessageParser.swift:177,182`),
  **not** on `MessageType` (a `.thinking`/`.code`/`.toolCall` block is still an
  assistant continuation, `MessageTypeClassifier.swift:94-135`). A new user
  message opens a turn; the turn's wall-clock is `nextUser.timestamp −
  thisUser.timestamp`. Skip `isSystem` user records as anchors so injected
  system-reminders don't create phantom turns. Emit `[UUID: seconds]` keyed on
  the **first assistant message** of the turn (as-main anchors on the first
  assistant block).
- **Where it runs:** fold the walk into (or run it alongside) `IndexedMessage.build`
  — it is one extra O(n) pass over the same sequence, already off-main inside
  `rebuildIndexed`'s `Task.detached` (`SessionDetailView.swift:1006-1019`). No new
  async plumbing. If Part A is also present, the walk joins the append-only
  rebuild (see Cross-row coupling).
- **Render:** thread the per-message duration onto `IndexedMessage` as a new
  **`var turnDurationSeconds: Double?`** — a `var`, not `let`. `IndexedMessage`'s
  current fields are all `let` (`IndexedMessage.swift:5-8`), but Part A's append
  path must backfill exactly one boundary row in place (see Cross-row coupling for
  the committed mechanism), which requires mutability. Insert `Text(chip)` before
  the `Spacer(minLength: 0)` in the assistant `roleHeader`
  (`ColorBarMessageView.swift:94-100`).
- **Duration convention — deliberate divergence from replay:** reuse the
  dual-format ISO parse (`ReplayState.parseISO`, app-side, keeps the helper in the
  app target), but **hide the chip on a negative/skewed delta** (return `nil`),
  matching as-main (`TranscriptTurnTiming.swift:110-113`) rather than
  `replayDurationMs`'s `max(0, …)` clamp. A "0s" chip on clock skew is worse UX
  than no chip; the clamp is correct only for pacing.
- **Formatter:** a new small pure bucketed formatter — `<10s` → one decimal
  (`4.8s`); `10–59s` → whole seconds; `≥60s` → `Nm Ns`. **Drop** as-main's
  `· N calls` suffix (tool counts are unavailable in the role-filtered
  `ChatMessage` stream and would rest on heuristic classification).

**Acceptance criteria (C)** — falsifiable:
- The turn walk emits one duration per turn keyed on the turn's **first assistant
  message** id, segmented on `ChatMessage.role` (not `MessageType`), skipping
  `isSystem` user anchors.
- An out-of-order / negative delta returns `nil` (chip hidden), diverging from
  `replayDurationMs`'s `max(0, …)` clamp; a missing/unparseable endpoint likewise
  returns `nil`.
- The bucketed formatter renders `4.8s` / `42s` / `3m 5s` with no `· N calls`
  suffix.
- `ChatMessage.timestamp` is populated via the adapter path
  (`MessageParser.swift:184`) and `nil` via a legacy-parser fixture; the other
  nine production sites and four test sites compile untouched on the defaulted
  optional.

---

## Invariants affected

- **Row 27 (Parts A & B): touches none.** Both are read/parse/render paths; they
  write nothing to `file_index_state` and add no DB read methods. Part B is
  *adjacent* to Invariant 13 (`docs/invariants.md:89-94`) and deliberately reuses
  its newline-complete-boundary + boundary-hash principle for the in-memory read
  cursor, but introduces no new ledger entry and modifies no write-path checkpoint.
- **Row 30 (Part C): touches none.** Model + view + a pure timing helper; no
  schema, IPC, or write path.

No new invariants are introduced; no ledger edit is required in these PRs.

---

## Alternatives considered

- **Tail-first / reverse cold paint** (Row 27, as-main
  `ReverseJSONLTailReader.swift:8-9`). Rejected: that reader is explicitly a
  throwaway that full-re-parses, incompatible with a genuinely paged forward
  view; it would not compose with the append-only prefix model.
- **Make "Load more" load-all-remaining / raise page size** (Row 27). Rejected as
  the primary fix: changes the UX contract and defeats incremental paging's
  memory benefit on multi-hundred-MB transcripts; the one-click "Load all"
  already offers this. Kept in mind as the cheap escape hatch if Part B is never
  justified.
- **Byte cursor as a replacement for `offset/limit`** (Row 27). Rejected: MCP's
  stateless pager depends on produced-message `offset/limit` and holds no cursor
  between calls (`MCPTranscriptReader.swift:502`). The cursor must be additive.
- **Persist the read cursor in `file_index_state`** (Row 27). Rejected: that is a
  write path under Invariant 13, unnecessary for an in-memory pager whose lifetime
  is one open detail view.
- **Edit all 14 `ChatMessage` sites** (Row 30, per the mirror). Rejected: only
  `MessageParser.swift:184` has a timestamp in scope; a defaulted field means the
  other nine production + four test sites compile untouched.
- **Per-tool / per-message durations** (Row 30). Rejected: tool records are
  dropped at `MessageParser.swift:177` and `.toolCall`/`.toolResult` are content
  guesses (`MessageTypeClassifier.swift:50-63`); timing them pairs heuristics.
- **Segment turns by `MessageType`** (Row 30). Rejected: assistant blocks
  classified `.thinking`/`.code`/`.toolCall` would spuriously split one turn.
- **Reuse `replayDurationMs` verbatim (clamp-to-0)** (Row 30). Rejected for a
  user-facing chip: it would render a misleading `0.0s` on skew; hide instead.

---

## Cross-row coupling

If **both** Part A and Part C land, the Row 30 turn-walk must join Part A's
append-only rebuild rather than the full-prefix `build`, or it re-introduces the
O(prefix)/page cost Part A removed. The walk is naturally incremental with one
seam rule: a turn that spans the page boundary has its first-assistant row built
in page *k* with `turnDurationSeconds == nil` (the next-user timestamp that ends
the turn isn't known until page *k+1* arrives).

**Committed mechanism (not an open alternative):** make `turnDurationSeconds` a
`var` and, when the append that loads page *k+1* discovers the boundary turn's
closing timestamp, mutate **only that one prior first-assistant row** in place —
an O(1) targeted write, the sole explicit exception to Part A's "never re-touch
prior rows" rule and fully compatible with its per-page cost goal. Do **not**
reach for a sidecar `[UUID: Double]` map or a per-page full recompute; the
single-row `var` backfill is the design. If Part C lands **alone** (full rebuild
each page, today's behavior), every turn closes within its own rebuild — no
boundary backfill needed, and the walk is O(n)/page like the existing classify
pass, no regression. State this ordering in whichever PR lands second.

---

## Test plan

**Part A (append-only rebuild) — repro first.** New
`macos/EngramTests/IndexedMessageTests.swift`:
`func testAppendOnlyRebuildClassifiesOnlyNewPage_repro()` — assert
`IndexedMessage.appending(newPage, to: prior, counts:)` yields the same
`(messages, counts)` as `build(from: prior + newPage)`. The falsifier is this
output-equivalence **combined with the `prior: [IndexedMessage]` signature**:
because `prior` arrives already built (not `[ChatMessage]`), `appending` is
structurally incapable of re-classifying it, so equivalence-with-`build` can hold
only if exactly `newPage` was classified. Do **not** try to inject a counting
classifier — `MessageTypeClassifier.classify` is a `static func` with no injection
seam (`MessageTypeClassifier.swift:94`), so a counter would require a production
refactor beyond the minimal diff and is unnecessary given the structural
argument. Fails before extraction (no `appending`), passes after. Add
`testAppendPreservesTypeIndexContinuity` for `typeIndex` carry-forward.

**Part B (byte-seek cursor) — repro first.** Extend
`macos/EngramCoreTests/AdapterWindowedReadTests.swift`:
`func testWindowedPageThroughParsesLinearLines_repro()` — seed a synthetic
N-message JSONL fixture. The only reusable harness piece today is `makeTempDir()`
at `AdapterWindowedReadTests.swift:10`; there is **no** shared N-message builder
in that file (`:19-286` are independent `func test…` bodies, each inline-writing
its own 2-3-line JSONL), so add a small parametric builder that follows the same
per-test temp-dir + JSONL-line-writer pattern. Page through the fixture in fixed
chunks feeding each `WindowedMessagesResult.endCursor` back as `resumeCursor`, and
assert the **total lines parsed** across the full page-through is O(n) (≤ `c·N`),
not O(n²). Output-equivalence alone **cannot** falsify the quadratic — the counted
and seek paths emit byte-identical messages — so the repro needs an
instrumentation seam. **Specify it concretely:** add a test-only counter under
`#if DEBUG` on `JSONLAdapterSupport` — `#if DEBUG static var parsedLineCount = 0
#endif` — incremented in the windowed helper's per-line loop and reset by the test
at start; the `#if DEBUG` guard keeps it out of the shipped path. (Behavioral
alternative if the seam is unwanted: assert the reader's byte position after a
resumed page equals the fed-in `endCursor.byteOffset`, proving the resumed page
did not re-scan from 0 — but the counter is the primary, directly falsifiable
mechanism.) Fails before the cursor (counted path re-skips → total ≈
N²/2·pageFraction), passes after. Add
`testResumeCursorRejectsRewrittenPrefixAndFallsBack` (mutate the fixture prefix,
assert boundary-hash mismatch → counted re-parse, correct output) and confirm the
MCP path is unchanged via existing `AdapterParityTests` offset/limit cases.

**Part C (duration chip).** New
`macos/EngramTests/TranscriptTurnTimingTests.swift`, pure (no view):
- `testTurnSegmentationAnchorsOnFirstAssistant` — synthetic `[ChatMessage]` with
  timestamps; assert one duration keyed on each turn's first assistant id.
- `testNegativeDeltaHidesChip_repro` — out-of-order timestamps → `nil` (fails if
  the helper clamps to 0 like `replayDurationMs`).
- `testMissingTimestampHidesChip` — nil endpoint → `nil`.
- `testFormatterBuckets` — `4.8s` / `42s` / `3m 5s`, no `· N calls` suffix.
Plus, in `macos/EngramTests/MessageParserTests.swift`,
`func testAdapterPathThreadsTimestamp()` — reuse the timestamp-bearing
custom-profile fixture (`MessageParserTests.swift:326`) to assert
`ChatMessage.timestamp` is populated via the adapter path and `nil` via a
legacy-parser fixture.

**Intentionally not tested:** per-tool durations (out of scope); the SwiftUI
view render itself (the timing + append logic is extracted into pure,
independently testable helpers, per the as-main pattern).

---

## Rollout

- Pure app/adapter changes; no schema, no migration, no service protocol change.
  Ship in the app + service rebuild; no backfill, effective immediately on next
  launch of a rebuilt `Engram.app`.
- Suggested order: **Part A** (small, always-on win, app-only) → **Part C**
  (model + UI, honors the coupling rule) → **Part B** only if the operational
  go/no-go gate below fires.
- **Part B go/no-go gate (operational, owner-run).** The app ships no telemetry,
  so this is a *local measurement*, not a query. After Part A ships, the owner
  (whoever landed Part A) opens the largest local transcripts (the >800-message
  tail) in a normal session and records two numbers: (1) `parsedLineCount` — the
  `#if DEBUG` counter from Part B's repro — aggregated across a full page-through;
  (2) the count of `appendMessages(all: false)` (Load-more) vs
  `appendMessages(all:)` (Load-all) invocations, logged locally. **Build Part B
  only if both hold:** incremental Load-more (not Load-all) is the dominant way
  large transcripts get fully read, **and** aggregate `parsedLineCount` for a
  page-through exceeds ~2× the file's line count (the quadratic is empirically
  material). If Load-all dominates or the ratio stays near 1×, **drop Part B** —
  do not build it.
- Revert story: each part is a self-contained diff. Reverting Part B restores the
  counted re-parse (correct, just O(prefix)/page). Reverting Part A restores the
  full rebuild (correct, O(prefix)/page). Reverting Part C removes the field +
  chip + helper; `timestamp` defaulting to nil means no other call site changes.

---

## Risks and open questions

- **[high] Part B M-effort may not clear the bar.** The always-on cost is Part A
  (terms 2/3); Part B (term 1) helps only repeated "Load more", and one-click
  "Load all" is already O(n) (`SessionDetailView.swift:1037-1046`). Decided via
  the **operational go/no-go gate in Rollout** (owner-run local `parsedLineCount`
  + Load-more-vs-Load-all counts, ~2× threshold), not open-ended telemetry the app
  does not emit. If Load-all dominates, Part B is dropped, not built.
- **[medium] Cursor false-positive resume** on a rewritten/truncated transcript
  shows wrong messages. Resolved: re-validate with `boundaryHash` over the prefix
  bytes before `byteOffset` **every page** (stable under append) plus inode/device
  file-identity; **size is excluded** because append-only growth changes it and
  would false-reject every valid live resume, silently forcing the counted
  re-parse fallback on exactly the sessions Part B is meant to help.
- **[medium] Coupling regression.** Folding Part C's walk into a full rebuild
  after Part A lands re-introduces the per-page cost Part A removed. The committed
  seam mechanism — single-row `var turnDurationSeconds` backfill on the boundary
  turn (see Cross-row coupling) — must be implemented, not just noted.
- **[medium] Negative-delta convention.** Chosen: hide (nil). Open question:
  confirm product prefers a hidden chip over a `0s`/`~0s` chip on clock skew and
  out-of-order records (this doc assumes yes).
- **[open] Exact turn endpoint.** This doc uses `user → next-user` wall-clock
  (captures trailing tool time implicitly). Alternative: `user → last-assistant-
  before-next-user`. They differ because tool records are dropped from
  `ChatMessage` (`MessageParser.swift:177`); the former is truer wall-clock.
  Confirm before implementing the walk.
- **[open] Chip anchor with multiple assistant messages per turn.** This doc
  anchors on the **first** assistant of the turn (as-main). Confirm vs.
  per-assistant-message chips.
- **[open] `isSystem` user anchors.** This doc **skips** injected system-reminder
  user records as turn anchors. Confirm.
- **[open] Page-boundary chip suppression.** While `hasMoreToLoad`, the last
  loaded turn is incomplete and under-counts until the next page loads. Suppress
  the trailing chip when `hasMoreToLoad`, or accept the transient? This doc leans
  suppress; minor.
- **[unverified] Scale figures.** "421 of 33,525 sessions exceed 800 messages"
  is from live user data under `~` (read-only) and is not verifiable in-repo.
- **[unverified] Per-source timestamp presence.** Adapters read `object["timestamp"]`
  per record and pass `nil` when absent; the design degrades safely either way,
  but real Gemini/Cursor/OpenCode fixtures were not opened to confirm per-message
  wall-clock granularity vs. an ordering proxy.
