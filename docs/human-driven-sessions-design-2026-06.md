# Human-Driven Sessions: Default Filter + Instruction-First Summary (rev. 2)

Status: Proposed design (Swift product), revised to incorporate adversarial critique.
Author: synthesis of three approaches + critique resolution.
Scope: `macos/` Swift product only. No TypeScript reference changes.

## 0. Critique resolution map

Every high/medium issue is fixed; lows are fixed or explicitly justified.

| # | Sev | Issue | Resolution |
|---|-----|-------|------------|
| 1 | high | Rule 4 (`len<8 && no-whitespace`) drops short CJK asks → undercounts → hides Chinese sessions | **Script-aware rule 4**: skip the length/whitespace gate when the first line contains any non-Latin (CJK/Hangul/Kana/etc.) character; gate only ASCII-ish short tokens. CJK fixture added (§3.1, §9). |
| 2 | med | Missed native web UI browse list (`EngramWebUIServer.readSessions`) | Added as the 6th surface; predicate + `?all=1` escape hatch (§5). |
| 3 | med | Default filters only 2/17 sources at launch (allowlist) | Stated as explicit expected outcome in §1/§11; graduation order + adapter-role audit defined (§3.2, §11). |
| 4 | med | Predicate reuses rejected `user_message_count` via a 2nd counting path | **Replaced** with `human_turn_count`, computed in the *same* `streamStats` pass as instruction extraction (one "human turn" definition). 3rd nullable column (§3, §4, §7). |
| 5 | med | `instruction_count` ON CONFLICT guard keyed on `message_count` (different pass) | Guard re-keyed on `summary_message_count` — itself the streamStats-derived sentinel (`indexedMessageCount`, SwiftIndexer.swift:357), so guard co-varies with the extraction pass (§4). |
| 6 | med | `SessionDetailView` relabel + numbered render lands before instruction generation; Regenerate button mislabeled | **No relabel.** A new *read-only* "What you asked" section renders only when `instructionSummary != nil`; the existing "Summary" section + Generate/Regenerate button are untouched (§6). |
| 7 | low | Premium single-ask sessions get hidden | Added `OR tier = 'premium'` to the predicate so substantial (≥20-msg) sessions stay visible (§3). |
| 8 | low | Escape hatch not global (Home/Timeline) | One global `@AppStorage("sessions.showAll")` threaded into `recentSessions`/`sessionTimeline` via a `humanDriven` param (§5). |

Over-engineering trimmed:
- **Phase 5 (LLM instruction-first refinement) is cut from shipped scope** → deferred (§10). The deterministic baseline fully satisfies the instruction-first ask.
- **Phase 4 version-gated forced re-stream removed.** Default population is lazy/natural re-index (NULL-tolerant, safe); an *optional* bounded one-time backfill is offered without the `InstructionExtractionVersion` constant or `file_index_state` clearing apparatus (§8).
- Allowlist **graduation** = add a source to the set + one adapter-uniformity test; the version/re-stream ceremony is gone (§3.2).

Missed read surfaces explicitly triaged (§5.1): web UI (fixed), HomeView Follow-ups (search-backed, verify-then-decide), MCP `project_timeline`/`stats` (analytics, intentionally unfiltered).

## 1. Problem

Users face a massive number of AI coding sessions across 17 sources and cannot read them
all. The default app surfaces too many low-value sessions (single-shot, automated, probe,
agent, trivial). The only per-session summary on click is either the raw first user message
or an AI-narrated "what the assistant did" summary — neither matches how humans recall their
own work: by their own intent ("what did I ask the AI to do").

Three coupled asks:

1. **Default view = human-driven sessions only**, with an escape hatch to show everything.
2. **Instruction-first summary**: clicking a session shows what the *human asked the AI to
   do*, grounded in the human's distinct requests.
3. **Correct filtering + distillation**: decide which sessions qualify and extract the human
   instruction set from each.

**Scope honesty (critique #3).** At launch the instruction signal is computed only for the
two adapters whose `streamMessages` `.user` roles are verified (claude-code, codex). For the
other 15 sources the signal is `NULL` and the predicate degrades to `agent_role IS NULL`
(≈ today's behavior). So real instruction-based corpus reduction ships for claude-code/codex
first; remaining sources graduate as their adapter role-emission is verified (§3.2, §11).
This is a deliberate safe-rollout choice, not full coverage on day one.

## 2. Chosen approach (and why)

Candidates: (A) overload `tier` with a `user_message_count` gate; (B) two
`streamStats`-derived columns rendered at display time; (C) derive the default filter FROM an
index-time-extracted distinct-instruction set in two additive columns.

The design uses **Angle C as the backbone**, grafting **Angle B's distinct-instruction
predicate and explicit `agent_role IS NULL` gate**, plus the critique's robustness fixes.
**Angle A is dropped** because threading `userCount` into `TierInput` mutates what
`lite`/`normal`/`premium` mean and silently strips keyword-search and embedding eligibility
(`jobKinds` gates embeddings on `tier == .normal || .premium`, SessionSnapshotWriter.swift:618-627)
— a side effect the user never asked for.

Core principles:

- **Visibility is a separate axis from tiering.** The human-driven signal is *additive,
  reversible* nullable columns. `SessionTier.compute`, `TierInput`, `jobKinds` embedding
  eligibility, and keyword-search predicates are **left exactly as-is** (verified
  SessionTier.swift:9-46, jobKinds at SessionSnapshotWriter.swift:618-627).
- **Both predicate signals come from one pass, one definition (critique #4).**
  `instruction_count` (distinct asks) and `human_turn_count` (raw substantive human turns)
  are computed side-by-side in the existing `SwiftIndexer.streamStats` normalized-message
  pass (SwiftIndexer.swift:299-335), gated identically. The predicate never re-derives a
  human-turn count from the inconsistent `user_message_count` (parseSessionInfo path,
  ClaudeCodeAdapter.swift:136-143).
- **No LLM required.** A deterministic instruction set is rendered at index time and stored.
  LLM refinement is deferred (§10).
- **Instruction text lives in its own column**, never overwriting `summary`, because
  `generatedTitle(for:)` derives `generated_title` from `summary`'s first line
  (SessionSnapshotWriter.swift:415-419).

## 3. Definition of "human-driven"

A session is **human-driven** (default-visible) iff:

```sql
agent_role IS NULL
AND (
  instruction_count IS NULL          -- not yet assessed → visible (safe default)
  OR instruction_count >= 2          -- multiple DISTINCT human asks
  OR human_turn_count >= 12          -- a dozen-plus substantive human turns (long thread)
  OR tier = 'premium'                -- substantial session (≥20 msgs / long-duration) — critique #7
)
```

Notes:
- `instruction_count IS NULL` keeps the predicate **NULL-tolerant**: legacy / non-allowlisted
  rows stay visible, so the default list is never silently emptied.
- `human_turn_count >= 12` reproduces the user's literal "a dozen-plus user messages" rescue,
  but sourced from the same `streamStats` pass as `instruction_count` — resolving the
  two-counting-paths contradiction (critique #4). It rescues long iterative sessions whose
  follow-ups dedup/stoplist down to <2 distinct asks (e.g. one big ask + many "continue").
- `tier = 'premium'` keeps high-value single-ask sessions visible (critique #7): a premium
  session is ≥20 messages or >30 min (SessionTier.swift:33-37) — not "single-shot" in the
  noise sense, even if it carries one instruction. For non-allowlisted sources this term is
  redundant (they're already visible via NULL-tolerance); it only "bites" for an allowlisted
  premium session with `instruction_count = 1` and `human_turn_count < 12`.

Constants (tunable, in `InstructionExtractor`; re-index-free to change):
- `HUMAN_DRIVEN_MIN_INSTRUCTIONS = 2`
- `HUMAN_DRIVEN_MIN_HUMAN_TURNS = 12`

### 3.1 A "distinct human instruction" (the distillation rule)

`instruction_count` counts **distinct, substantive human instruction turns**, NOT raw user
turns. A user turn reaches the extractor only after `streamStats`' existing gates
(SwiftIndexer.swift:313-328): `role == .tool` excluded; `role == .user &&
isSystemInjection(content)` excluded (SwiftIndexer.swift:319, strips
AGENTS.md/`<INSTRUCTIONS>`/`<environment_context>`/`<skills_instructions>`/`<plugins_instructions>`/local-command-caveat,
SwiftIndexer.swift:436-443); empty content excluded.

`InstructionExtractor.distinctInstruction(from:seen:) -> String?` then rejects a candidate
when ANY hold:

1. First non-empty line starts with `/` (slash/local command), or content has prefix
   `<command-name>` / `<command-message>` / `<local-command`.
2. Looks like a tool result (prefix `<tool_use_result` / obvious tool-result envelope) —
   belt-and-suspenders beyond the upstream `role == .tool` exclusion.
3. Normalized first line is in the **stoplist** = `SessionTier.probeFirstLines`
   (SessionTier.swift:58-60: ping/hi/hello/test/echo/ok/hey/say hello/reply: t4) ∪
   micro-acks `{ok, okay, yes, yep, no, y, n, k, continue, go, go on, go ahead, sure,
   thanks, thank you, done, 继续, 好, 好的, 嗯, 行}` ∪ Polycli probes
   `{POLYCLI_HEALTH_OK, "no tools. review…", "no tools. stage … facts…"}`.
4. **Short-token gate, script-aware (critique #1, FIXED).** Reject only when the trimmed
   first line is a short ASCII-ish token: `firstLine.count < 8 AND contains no whitespace AND
   contains no non-Latin (CJK/Hangul/Kana/…) scalar`. The non-Latin clause means a real short
   CJK ask like `改成深色模式` (6 graphemes, no whitespace) or `修复登录bug` is **kept**.
   Implementation: `firstLine.unicodeScalars.contains { $0.value > 0x2E80 }` (the CJK/East-Asian
   block start) ⇒ treat as substantive; rule 4 only fires for pure short Latin tokens like
   `"y"`, `"k"`. This makes rule 4 err toward VISIBLE for non-Latin scripts, consistent with
   the stoplist's stated safety direction.
5. Its **normalized key** (lowercased + whitespace-collapsed + `prefix(200)`) was already
   seen in this session (dedup, so `"continue"`×5 or a re-sent prompt counts once).

Survivors increment `instruction_count` and are appended (verbatim, `prefix(200)`) to the
instruction set. **The set array and the `seen` Set are capped at 16** to bound memory; a
>16-distinct-ask session already has `instruction_count == 16 (>= 2)` → visible, so the cap
needs no special predicate handling (this corrects the original doc's claim that the >12
clause exists to handle the cap — it does not). The EN/ZH stoplist errs toward VISIBLE for
other languages.

`human_turn_count` is incremented in the SAME user block (SwiftIndexer.swift:330) for every
substantive human turn that passes the upstream gates — *before* dedup/stoplist. This is the
"dozen-plus user messages" signal, sharing the gate definition with instruction extraction.

### 3.2 Per-source reliability allowlist (false-hide guard)

A source whose `streamMessages` omits `.user` roles would yield `instruction_count = 0` /
`human_turn_count = 0` and be wrongly hidden. Mitigation: only **allowlisted** sources get
non-null `instruction_count` / `human_turn_count` / `instruction_summary`; all others store
`NULL` (→ always visible, no instruction subtitle).

```swift
static let reliableInstructionSources: Set<SourceName> = [.claudeCode, .codex]  // initial
```

In `buildSnapshot`:
`let extracted = reliableInstructionSources.contains(info.source)`;
`instructionCount = extracted ? stats.instructions.count : nil`;
`humanTurnCount = extracted ? stats.humanTurnCount : nil`;
`instructionSummary = extracted && !stats.instructions.isEmpty ? stats.instructions.joined(separator: "\n") : nil`.

**Graduation (trimmed, critique over-eng).** Adding a source = (a) append it to the set,
(b) add one `InstructionExtractorParityTest` fixture proving that adapter's stream emits
`.user` roles with non-empty content. No version constant, no forced re-stream. Newly
graduated sources populate via natural re-index (§8). **Graduation priority** by corpus
volume / role-emission likelihood: gemini-cli, cursor, copilot, opencode next (audit their
`streamMessages` role emission first — see §11 Open work).

## 4. Signal computation (where + how)

All index-time, single pass, no new file read.

**`macos/EngramCoreWrite/Indexing/SwiftIndexer.swift`**
- `SessionStreamStats` (struct at :280-297): add
  `var instructions: [String] = []`,
  `var seenInstructionKeys: Set<String> = []`,
  `var humanTurnCount = 0`.
- `streamStats` user branch (:330, where `firstUserMessages` is appended): inside the
  `if message.role == .user` block, after the existing `isSystemInjection` (:319) and
  non-empty (:328) guards:
  - `stats.humanTurnCount += 1`
  - `if let instr = InstructionExtractor.distinctInstruction(from: content, seen: &stats.seenInstructionKeys), stats.instructions.count < 16 { stats.instructions.append(instr) }`
- `buildSnapshot` (:337-386): apply the allowlist gate (§3.2) and pass the three values into
  the snapshot. **`TierInput` construction at :342-356 is UNCHANGED** — tier stays keyed on
  message/assistant/tool counts only.

**`macos/Shared/EngramCore/Indexing/InstructionExtractor.swift`** (new, co-located with
`SessionTier.swift`): pure, testable. Holds the stoplist/constants and
`distinctInstruction(from:seen:) -> String?`. Reuses `SessionTier.probeFirstLines`
(change `private static let` → `static let` at SessionTier.swift:58, internal). Requires
`xcodegen generate` (dir already globbed by `project.yml`).

**`macos/Shared/EngramCore/Indexing/IndexingEventTypes.swift`**
(`AuthoritativeSessionSnapshot`, :3-86): add
`public var instructionCount: Int?`, `public var humanTurnCount: Int?`,
`public var instructionSummary: String?` to the struct + init params (defaulted `nil`) +
assignments. `Equatable`/`Sendable` derive.

**`macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift`** (`upsert`, :270-407):
- INSERT column list (:274-280): append `instruction_count, human_turn_count, instruction_summary`.
- VALUES (:281-288): three more `?`.
- `arguments` (:376-405): append `snapshot.instructionCount, snapshot.humanTurnCount, snapshot.instructionSummary`.
- ON CONFLICT — **guard keyed on `summary_message_count` (critique #5).** The existing
  count guards (:299-318) key on `excluded.message_count = 0`, which is safe only for
  parseSessionInfo-derived counts. The three new columns come from `streamStats`, whose
  co-varying sentinel is `summary_message_count` (= `stats.indexedMessageCount`,
  SwiftIndexer.swift:357). So:
  ```sql
  instruction_count = CASE
    WHEN excluded.summary_message_count = 0 AND sessions.summary_message_count > 0
      THEN sessions.instruction_count ELSE excluded.instruction_count END,
  human_turn_count = CASE
    WHEN excluded.summary_message_count = 0 AND sessions.summary_message_count > 0
      THEN sessions.human_turn_count ELSE excluded.human_turn_count END,
  instruction_summary = CASE
    WHEN excluded.summary_message_count = 0 AND sessions.summary_message_count > 0
      THEN sessions.instruction_summary ELSE excluded.instruction_summary END
  ```
  All three derive from the same pass and use the same streamStats-derived sentinel, so an
  empty/failed re-stream (`indexedMessageCount = 0` while the prior row was good) preserves
  all three together; a healthy re-stream overwrites all three fresh (keeping the displayed
  instruction set current as an append-only log grows).

This is a writer-owned, index-time write inside the existing write path — no new plumbing.

## 5. Surfaces: default filter + escape hatch

The instruction filter applies to **default browse surfaces only**, NOT to keyword search
(filtering search would hurt recall — single-shot sessions must stay searchable, consistent
with today's `tier`-only search predicates at EngramServiceReadProvider.swift:630/698/810 and
MCPDatabase.swift:1518, left unchanged).

A single global toggle governs all browse surfaces (critique #8):
`@AppStorage("sessions.showAll") private var showAllSessions = false`. When `true`, browse
surfaces pass `humanDriven: false`.

**App shared path — `macos/Engram/Core/Database.swift`**
- `appendSessionFilters` (:127-164): add param `humanDriven: Bool = false`; when true append
  ```
  AND agent_role IS NULL
  AND (instruction_count IS NULL OR instruction_count >= 2
       OR human_turn_count >= 12 OR tier = 'premium')
  ```
  This single builder feeds both `listSessions` (:171-201) and `sessionListStats` (:203-219),
  keeping list rows and KPI counts consistent.
- `listSessions` / `sessionListStats`: add `humanDriven: Bool = false`, thread through.
- `recentSessions` (:1028-1039) and `sessionTimeline` (:1041-1052): add
  `humanDriven: Bool = false` param; when true, append the same predicate string to their
  hard-coded WHERE. (Critique #8: these are now toggle-able, not hard-pinned.)

**Main list — `macos/Engram/Views/Pages/SessionsPageView.swift`**
- Add `@AppStorage("sessions.showAll") private var showAllSessions = false` (next to
  `showHiddenSessions` at :8).
- Add `Toggle("Show all sessions", isOn: $showAllSessions).toggleStyle(.checkbox)` beside the
  "Show hidden sessions" toggle (:72).
- Add `AnyHashable(showAllSessions)` to the `.task(id:)` reload key array.
- Pass `humanDriven: !showAllSessions` into the `listSessions` / `sessionListStats` calls.

**Home — `macos/Engram/Views/Pages/HomeView.swift`**: add the same
`@AppStorage("sessions.showAll")`; pass `humanDriven: !showAllSessions` into
`db.recentSessions(limit: 12)` (HomeView.swift:294). One global flag now reveals Home too.

**Timeline — `macos/Engram/Views/Pages/TimelinePageView.swift`**: add the same
`@AppStorage("sessions.showAll")`; pass `humanDriven: !showAllSessions` into
`database.sessionTimeline(days:sort:)` (TimelinePageView.swift:259).

**Menu bar — `macos/Engram/Views/PopoverView.swift`** (own inline SQL + `settings.json`
`noiseFilter`, :318-338): add a new `noiseFilter` mode `"human-driven"` (make it the default)
that appends the human-driven predicate to `noiseConditions` (:319-327); keep
`all`/`hide-noise`/`hide-skip` as the escape hatch. `readNoiseFilter()` already centralizes
the mode.

**Native web UI — `macos/EngramService/Core/EngramWebUIServer.swift`** (critique #2, MISSED
SURFACE). `readSessions(limit:)` (:325-343) is a browse list (the `/` route), not search, and
its WHERE (`hidden_at IS NULL AND COALESCE(tier,'normal') NOT IN ('skip','lite') AND
parent/suggested NULL AND orphan_status IS NULL`) would still show single-ask
claude-code/codex sessions. Per CLAUDE.md `EngramWebUIServer` is in the product path.
- Add `humanDriven: Bool` param to `readSessions`; when true append the predicate to the
  WHERE.
- Route handler: default `humanDriven: true`; escape hatch via `?all=1` query param mirroring
  the others.

**MCP parity — `macos/EngramMCP/Core/MCPDatabase.swift`** (`listSessions`, :128-182): add the
human-driven predicate to the `conditions` array (:136), gated by a new `humanDriven: Bool =
true` arg with an `include_all` tool override. Keeps app and agent defaults consistent.
**Update `tests/fixtures/mcp-golden/tools.json`, affected golden result fixtures, and the
executable test.**

Escape-hatch summary: one global `sessions.showAll` toggle covers SessionsPage + Home +
Timeline; `noiseFilter` modes cover Popover; `?all=1` covers web UI; `include_all` covers MCP.

### 5.1 Read surfaces deliberately NOT filtered (triage)

- **HomeView "Follow-ups" panel** (`db.searchWithSnippets` + `TodayFollowUps.isEligible`):
  search-backed, so exempt by the search rule. **Verify** the existing search path already
  excludes `skip`/`lite` and agent sessions; if it surfaces agent/probe rows, add a cheap
  `agent_role IS NULL` guard there only (no instruction filter). Tracked as an Open work item.
- **MCP `project_timeline` / `stats`** (MCPDatabase.swift FROM sessions at :382, :1347/:1375):
  analytics/aggregates, not browse lists. Intentionally unfiltered so totals reflect the full
  corpus (consistent with stats semantics). Documented decision, no change.
- **`MCPDatabase` projects/stats at :98**: aggregate, same rationale — unchanged.

## 6. Instruction-first summary (deterministic, no LLM in v1)

### 6.1 Stored value

`instruction_summary` is the newline-joined distinct instruction set (§4), allowlist-gated.
First line = first instruction. It is **read-only and deterministic** in v1.

### 6.2 Display — separate read-only section (critique #6, FIXED)

**`macos/Engram/Views/SessionDetailView.swift`**: do **NOT** relabel the existing "Summary"
section (:654-688) and do **NOT** touch its Generate/Regenerate button (:665) — that button
still writes the assistant-narrated `summary` column, which is correct under its existing
label. Avoiding the relabel removes the "button does the wrong thing under a new label" and
"15/17 sources render a garbled single-item list" defects entirely.

Instead, add a new **read-only** section, rendered only when `session.instructionSummary !=
nil`, placed just above `summarySection`:

```swift
@ViewBuilder
private var instructionSection: some View {
    if let lines = session.instructionLines, !lines.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
            Label("What you asked", systemImage: "person.bubble")
                .font(.caption.bold()).foregroundStyle(Theme.secondaryText)
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text("\(i + 1). \(line)")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .accessibilityIdentifier("detail_instructionSection")
    }
}
```

No state seeding, no generate button (deterministic, index-derived). For the 15 non-allowlisted
sources `instructionSummary` is `nil`, so the section is absent and the unchanged "Summary"
section behaves exactly as today.

### 6.3 Cards

**`macos/Engram/Components/ExpandableSessionCard.swift` (:83-87)** and
**`macos/Engram/Components/SessionCard.swift` (:19-23)**: add a nil-guarded second `Text` line
under `displayTitle` showing `instructionLines?.first`, `.lineLimit(2)` (no blank row when
nil). Optional small "N asks" badge from `instructionCount` reusing `msgCountLabel` styling
(Session.swift:92-96).

## 7. Schema / migration

**`macos/EngramCoreWrite/Database/EngramMigrations.swift`** — idempotent ALTER-on-missing
pattern:
- CREATE TABLE block (:9-48): add nullable columns mirroring `summary_message_count` (:23):
  ```sql
  instruction_count INTEGER,
  human_turn_count INTEGER,
  instruction_summary TEXT,
  ```
- `addSessionColumnsIfNeeded` tuple list (:541-575): append
  ```swift
  ("instruction_count", "INTEGER"),
  ("human_turn_count", "INTEGER"),
  ("instruction_summary", "TEXT"),
  ```
  The loop (:576-577) runs `ALTER TABLE sessions ADD COLUMN` only when `PRAGMA table_info`
  shows the column missing — re-runnable/idempotent.

No index added (trim, critique minimal-diff): browse lists are `LIMIT 200`, time-ordered, and
the predicate is OR-heavy (a single-column index on `instruction_count` won't be used by the
OR). Add one only if query plans later show full table scans on the live distribution.

Nullable (no `NOT NULL`/`DEFAULT`) so `NULL` = "never computed" for the NULL-tolerant
predicate. No new tables, no `tier` value, no change to `summary` / `summary_message_count` /
`user_message_count` semantics.

**Read model — `macos/Engram/Models/Session.swift`** (explicit `CodingKeys` + custom
`init(from:)` — `SELECT *` alone will NOT surface new columns). Only the two UI-consumed
columns need decoding (`human_turn_count` is SQL-predicate-only and is harmlessly ignored by
the custom decoder):
- Add `var instructionCount: Int? = nil` and `var instructionSummary: String? = nil`
  (optional + defaulted, mirroring `qualityScore` at :38).
- Add `case instructionCount = "instruction_count"` and
  `case instructionSummary = "instruction_summary"` to `CodingKeys` (:40-64).
- Add `instructionCount = try c.decodeIfPresent(Int.self, forKey: .instructionCount)` and
  `instructionSummary = try c.decodeIfPresent(String.self, forKey: .instructionSummary)` in
  `init(from:)` (:123-154).
- Add convenience `var instructionLines: [String]? { instructionSummary?.split(separator:
  "\n").map(String.init) }` for cards/detail.

## 8. Corpus population (trimmed, critique over-eng)

- **Default = lazy / natural.** New and re-indexed allowlisted sessions populate the columns
  through the normal `SwiftIndexer`/`SessionSnapshotWriter` path. Because the predicate is
  NULL-tolerant, un-populated rows stay visible — never false-hidden. Time-sorted lists put
  freshly populated (active) sessions at the top, so the default view filters increasingly as
  the user keeps working. **No `InstructionExtractionVersion` constant, no `file_index_state`
  clearing.**
- **Optional one-time backfill (not version-gated).** For users who want immediate historical
  filtering, an idempotent startup backfill (modeled on existing `StartupBackfills`) selects
  `WHERE source IN (allowlist) AND agent_role IS NULL AND instruction_count IS NULL` and
  re-streams just those via the existing index path, writing through the existing UPSERT. It
  self-terminates once no NULL rows remain (no version constant). This carries a one-time
  I/O cost (re-reading historical allowlisted files); run it in the background after startup.
  **Cuttable** — the lazy path is correct and safe without it.

## 9. Phased implementation plan

**Phase 0 — Schema + read model**
- EngramMigrations: CREATE TABLE + tuple (§7).
- Session.swift: properties + CodingKeys + decode lines + `instructionLines`.
- Tests: `MigrationRunnerTests` (fresh DB has columns; legacy DB ALTERs them; idempotent
  re-run); a Session decode test.

**Phase 1 — Extraction (no UI)**
- New `InstructionExtractor.swift`; expose `SessionTier.probeFirstLines`; `xcodegen generate`.
- `SessionStreamStats` (+`humanTurnCount`) + `streamStats` user branch; `buildSnapshot`
  allowlist gate; `AuthoritativeSessionSnapshot` fields; `SessionSnapshotWriter` UPSERT with
  the `summary_message_count`-keyed guard.
- Allowlist = `{.claudeCode, .codex}`.
- Tests: `InstructionExtractorTests` (reject/dedup matrix incl. **CJK**); index parity test
  (3 distinct asks + 2 "continue" + 1 probe → `instruction_count == 3`, `human_turn_count ==
  6`); adapter-uniformity test (zeroed-`user_message_count` fixture still yields correct
  `instruction_count`/`human_turn_count` from the stream); writer test asserting all three
  columns preserve-on-empty-restream / overwrite-on-healthy-restream via the
  `summary_message_count` sentinel.

**Phase 2 — Default filter + global escape hatch**
- `Database.appendSessionFilters` (+`humanDriven`) + `listSessions`/`sessionListStats` +
  `recentSessions` + `sessionTimeline`.
- `SessionsPageView` + `HomeView` + `TimelinePageView` share `@AppStorage("sessions.showAll")`.
- Tests: `humanDriven:true` excludes a 1-ask/3-turn row, includes a 4-ask row, a
  13-human-turn row, a premium 1-ask row, and a NULL-`instruction_count` legacy row;
  `humanDriven:false` returns all; `sessionListStats` counts match; `recentSessions`/
  `sessionTimeline` honor the flag.

**Phase 3 — Deterministic instruction-first display**
- `SessionDetailView` new read-only `instructionSection` (Summary section untouched); card
  second line.
- Tests: `instructionLines` numbered render; nil-guard (nil → section absent, no blank row);
  non-allowlisted source shows unchanged Summary only.

**Phase 4 — Cross-surface parity + lazy population**
- `PopoverView` `"human-driven"` noiseFilter mode; `EngramWebUIServer.readSessions` predicate
  + `?all=1`; `MCPDatabase.listSessions` predicate + `include_all`; update
  `tests/fixtures/mcp-golden/tools.json` + golden results + executable test.
- (Optional) one-time backfill (§8).
- Tests: MCP default excludes non-human-driven, `include_all` restores; web UI route default
  excludes, `?all=1` restores; non-allowlisted rows remain visible.

## 10. Deferred / out of scope for v1 (was Phase 5)

LLM instruction-first refinement is **cut from the shipped scope** (critique over-eng). The
deterministic baseline already satisfies the instruction-first ask. If pursued later, the
forward-compatible shape is: a `summarizeInstructions` prompt + `instructionFirst` flag
through `EngramServiceCommandHandler.generateSummary` writing a *separate* refined column (so
re-index overwrite-fresh of `instruction_summary` does not clobber refined text), a bounded
background pass scoped to `instruction_count >= 2`, and an MCP `instruction_first` arg.
Explicitly not built now; no golden-fixture churn for it.

## 11. Test plan (summary)

- **InstructionExtractorTests** (new): slash command, `<command-name>` echo, probe
  (`ping`/`POLYCLI_HEALTH_OK`), micro-acks (`ok`/`yes`/`继续`), short Latin token (`y` → reject),
  **short CJK ask (`改成深色模式`, `修复登录bug` → KEEP, critique #1)**, repeated ask (dedup → 1),
  five distinct asks → 5; cap at 16.
- **Index integration**: real `streamStats` path yields correct `instruction_count`,
  `human_turn_count`, and newline-joined `instruction_summary`.
- **Adapter uniformity**: zeroed-`user_message_count` fixture still produces correct counts
  from the stream; a non-allowlisted source yields `NULL` (stays visible).
- **Migration** (`MigrationRunnerTests`): three columns present; idempotent.
- **Writer invariant** (`SessionSnapshotWriter`): all three columns preserve on empty
  re-stream (via `summary_message_count` sentinel), overwrite fresh on healthy re-stream;
  a partial parse with `message_count > 0` but empty stream does not zero them.
- **Read filter** (`Database`/`EngramCoreTests`): full OR/NULL/premium predicate;
  `sessionListStats` parity; `recentSessions`/`sessionTimeline` honor `humanDriven`.
- **MCP parity** (`EngramMCPExecutableTests`): default excludes non-human-driven; `include_all`
  restores; golden fixtures updated.
- **Web UI** (EngramService tests if present, else manual route check): `/` default excludes;
  `?all=1` restores.
- **No-regression**: `generated_title` still derives from `summary`; `tier` values unchanged;
  keyword-search results unchanged; embedding `jobKinds` unchanged.

New Swift test files require `xcodegen generate` before `xcodebuild`.

Open work (audits, not blockers):
- Verify HomeView Follow-ups search path already excludes skip/lite/agent (§5.1).
- Audit gemini-cli/cursor/copilot/opencode `streamMessages` `.user` role emission for the
  next allowlist graduation wave (§3.2).

## 12. Risks + mitigations

- **Adapter user-role reliability (top risk).** Mitigated by the per-source allowlist
  (`NULL`→visible until proven) + adapter-uniformity tests gating graduation.
- **Partial coverage at launch (2/17).** Stated explicitly (§1); NULL-tolerant so safe;
  graduation order defined. Honest about gradual benefit rather than overstating.
- **Backfill false-hide.** Avoided by refusing to seed from raw `user_message_count`; legacy
  rows are `NULL`→visible; populated by real extraction only (lazy or optional backfill).
- **Two-counting-paths contradiction (critique #4).** Eliminated — `instruction_count` and
  `human_turn_count` share one `streamStats` pass and one gate definition; the predicate no
  longer reads `user_message_count`.
- **CJK undercount (critique #1).** Eliminated — script-aware rule 4 keeps short CJK asks.
- **Premium single-ask hidden (critique #7).** Rescued by `tier = 'premium'`.
- **Stale `instruction_summary`.** Overwrite-fresh (sentinel-guarded) keeps the displayed set
  current as append-only logs grow; `instruction_count` stays fresh so visibility is always
  correct.
- **Threshold over-hiding.** Rescued by `human_turn_count >= 12`, `tier = 'premium'`, and the
  global Show-all toggle; thresholds are re-index-free constants.
- **Cross-surface drift.** SIX surfaces now enumerated (App builder, recent, timeline,
  Popover, web UI, MCP) + the global toggle covers App browse; covered by enumerated steps,
  the MCP golden test, and the web UI route check.
- **Tier/embedding regression.** Avoided — `SessionTier`/`TierInput`/`jobKinds` untouched.

## 13. Rollout

1. Ship Phases 0–3 behind the default-true `humanDriven` predicate with the global Show-all
   toggle. NULL-tolerant + 2-source allowlist ⇒ first launch hides nothing it cannot reliably
   assess.
2. Ship Phase 4 cross-surface parity (incl. web UI + MCP). Population is lazy by default;
   enable the optional one-time backfill if immediate historical filtering is wanted. Monitor
   the visible-session delta on the live distribution before tuning thresholds or graduating
   sources.
3. LLM refinement (§10) is deferred; the deterministic instruction-first summary is the
   shipped default and works with no model configured.
4. Reversibility: drop the `humanDriven` predicate (one line per surface) to revert visibility
   instantly; the three additive nullable columns can remain dormant. No `tier`, `summary`, or
   `generated_title` data is mutated by this feature.

---

## Appendix A — Key decisions

1. Re-source the 'dozen-plus messages' predicate term to a new nullable human_turn_count column computed in the SAME SwiftIndexer.streamStats pass as instruction_count (gated identically at SwiftIndexer.swift:330), instead of reusing the inconsistent parseSessionInfo-derived user_message_count. Accepts a 3rd nullable column to remove the flagged two-counting-paths contradiction and honor the user's literal OR spec.
2. Make distinctInstruction rule 4 script-aware: the <8-chars/no-whitespace reject only fires for pure short Latin tokens; any first line containing a non-Latin scalar (unicodeScalars > 0x2E80) is treated as substantive, so short CJK asks are counted. Fixes the high-severity CJK undercount that would hide the author's own Chinese sessions.
3. Key the new columns' ON CONFLICT guard on summary_message_count (= streamStats indexedMessageCount, SwiftIndexer.swift:357) rather than message_count, so the preserve-on-empty-restream guard co-varies with the actual extraction pass.
4. Do NOT relabel SessionDetailView's Summary section. Add a separate read-only 'What you asked' section rendered only when instructionSummary != nil, leaving the existing Summary section and its Generate/Regenerate button (which correctly writes the summary column) untouched. This kills the mislabeled-button and garbled-list defects without touching the LLM path.
5. Add tier='premium' to the visibility predicate so substantial sessions (>=20 msgs / >30 min) with a single instruction stay visible by default.
6. Use one global @AppStorage('sessions.showAll') flag threaded into recentSessions and sessionTimeline (HomeView.swift:294, TimelinePageView.swift:259), making the escape hatch govern all App browse surfaces, not just the Sessions page.
7. Add the native web UI browse list (EngramWebUIServer.readSessions, :325-343) as the 6th filtered surface with a ?all=1 query-param escape hatch.
8. Trim corpus population to lazy natural re-index (NULL-tolerant, safe) plus an OPTIONAL idempotent one-time backfill keyed on instruction_count IS NULL; remove the InstructionExtractionVersion constant and file_index_state clearing.
9. Cut LLM instruction-first refinement from shipped scope (deferred). The deterministic baseline satisfies the instruction-first requirement with no model.
10. State partial launch coverage explicitly: only claude-code and codex are allowlisted at launch; the other 15 sources degrade to agent_role IS NULL via NULL-tolerance, graduating after a per-adapter .user-role audit.

## Appendix B — Open questions (need your call)

1. Confirm keeping the human_turn_count rescue (3rd column) versus dropping the 'dozen-plus messages' clause entirely for fewer columns. The 3rd column honors the user's literal OR spec and guards against extractor under-count, but a pure instruction_count>=2 predicate would be 2 columns and arguably a cleaner operationalization of 'human-driven'.
2. Confirm tier='premium' should keep substantial single-ask sessions visible (current proposal) versus treating any single trivial ask as correctly de-emphasized regardless of tier.
3. Adapter audit needed: which of gemini-cli/cursor/copilot/opencode/antigravity/windsurf actually emit reliable .user roles in streamMessages? This determines the allowlist graduation order and how quickly default filtering reaches beyond 2/17 sources.
4. Does the HomeView Follow-ups search path (searchWithSnippets + TodayFollowUps.isEligible) already exclude skip/lite/agent sessions? If not, decide whether to add a minimal agent_role IS NULL guard there (it is search-backed, so the instruction filter stays off).
5. Should the optional one-time historical backfill ship in Phase 4, or rely purely on lazy re-index? Backfill gives immediate historical filtering at a one-time I/O cost (re-reading all historical claude-code/codex files); lazy-only leaves the stale historical backlog visible until those files change.
6. Are the thresholds (HUMAN_DRIVEN_MIN_INSTRUCTIONS=2, HUMAN_DRIVEN_MIN_HUMAN_TURNS=12) correct for the live distribution, or should they be tuned after observing the visible-session delta in Phase 4?
