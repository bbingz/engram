# Round 7 — Single Source of Truth Consolidation Design

Round-2 deep dive on round-6 root-cause theme #2 ("missing single source of
truth"). Scope: read-only on product code; this file is the only write.

Every claim below is confirmed by `Read`/`grep` against the working tree at
commit `cfae3ea3`. File:line citations are exact unless marked "approx".

Severity verdicts use: **BEHAVIORAL** (different input → different stored row /
tier / visible transcript) vs **COSMETIC** (duplication only; same output for
all reachable inputs today, but a latent divergence trap).

---

## 0. Executive summary — the divergence map

There is no single classifier, scorer, or normalizer. Each concern is forked
into 2–8 independently-maintained copies. The forks have **already diverged in
behavior**, not just in source text.

| Concern | # of copies | Diverged? | Worst verdict |
|---|---|---|---|
| System-injection classification | 8 (1 canonical + 7 inline) | YES | BEHAVIORAL — Codex header set is narrower than every other path AND than its own TS reference |
| Provider-probe / review detection | 2 (SwiftIndexer + StartupBackfills) | token-identical logic, different *health-prompt* sets | BEHAVIORAL — over-broad `contains("tests ")`/`contains("review")` hides real review sessions |
| Parent scoring | 2 (ParentDetection 4h-exp vs StartupBackfills 6h/48h-piecewise) | YES | BEHAVIORAL — same candidate pair links in one path, scores 0 in the other |
| Adapter count↔stream | 16 adapters, 2 paths each | YES in ≥8 | BEHAVIORAL — `messageCount` (tier input) ≠ streamed/indexed count; drives wrong tier |
| TS↔Swift tier rules | 2 | YES | BEHAVIORAL — TS `PROBE_FIRST_LINES`+`messageCount<=3` rule and 6-entry NOISE_PATTERNS absent in Swift (2 entries) |

The structural reason all five are invisible to CI: `AdapterParityHarness`
(`macos/Shared/EngramCore/Adapters/AdapterRegistry.swift:80-122`) produces both
`sessionInfo.messageCount` and a `messages` array but the test
(`macos/EngramCoreTests/AdapterParityTests.swift:80-81`) asserts each against an
**independently authored golden** — never `sessionInfo.messageCount ==
messages.count`. A golden that bakes in the divergence passes green.

---

## 1. SystemMessageClassifier — 8 sites, full pattern matrix

### 1.1 The eight definitions (exact pattern sets)

**Canonical** — `macos/Shared/EngramCore/SystemMessageClassifier.swift:9-39`.
Returns a 3-way enum (`none` / `systemPrompt` / `agentComm`), source-aware
(`antigravity` special-case). Used only at render time:
`macos/Engram/Core/MessageParser.swift:373` and
`macos/EngramService/Core/EngramWebUIServer.swift:311`.

The other seven are private `static func isSystemInjection(_:) -> Bool` (no
source param, boolean):

| # | Site | file:line |
|---|---|---|
| 1 | canonical | `SystemMessageClassifier.swift:9` |
| 2 | ClaudeCodeAdapter | `Adapters/Sources/ClaudeCodeAdapter.swift:216-226` |
| 3 | CodexAdapter | `Adapters/Sources/CodexAdapter.swift:384-389` |
| 4 | CommandCodeAdapter | `Adapters/Sources/CommandCodeAdapter.swift:165-175` |
| 5 | IflowAdapter | `Adapters/Sources/IflowAdapter.swift:163-167` |
| 6 | QoderAdapter | `Adapters/Sources/QoderAdapter.swift:166-168` |
| 7 | QwenAdapter | `Adapters/Sources/QwenAdapter.swift:156-160` |
| 8 | SwiftIndexer | `EngramCoreWrite/Indexing/SwiftIndexer.swift:238-245` |

### 1.2 Difference matrix (✓ = recognized as injection by that site)

Tag / prefix tested → which sites recognize it. `P` = `hasPrefix`, `C` =
`contains`.

| Pattern | 1 Canon | 2 CC | 3 Codex | 4 CmdC | 5 Iflow | 6 Qoder | 7 Qwen | 8 Indexer |
|---|---|---|---|---|---|---|---|---|
| `# AGENTS.md instructions for ` (P) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – | ✓ |
| `<INSTRUCTIONS>` (C) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `<local-command-caveat>` (P) | ✓ | ✓ | ✓ | ✓ | ✓ | – | – | ✓ |
| `<local-command-stdout>` (P) | ✓ | ✓ | – | ✓ | – | – | – | – |
| `<command-name>` (C) | ✓ | ✓ | – | ✓ | – | – | – | – |
| `<command-message>` (C) | ✓ | ✓ | – | ✓ | – | – | – | – |
| `Unknown skill: ` (P) | ✓ | ✓ | – | ✓ | – | – | – | – |
| `Invoke the superpowers:` (P) | ✓ | ✓ | – | ✓ | – | – | – | – |
| `Base directory for this skill:` (P) | ✓ | ✓ | – | ✓ | – | – | – | – |
| `<environment_context>` (P) | ✓ | – | ✓ | – | – | – | – | ✓ |
| `<system-reminder>` (P) | ✓ | – | – | – | – | – | – | – |
| `<EXTREMELY_IMPORTANT>` (P) | ✓ | – | – | – | – | – | – | – |
| `<subagent_notification>` (P) | ✓ | – | – | – | – | – | – | – |
| `<SYSTEM_MESSAGE>` (P, antigravity only) | ✓ | – | – | – | – | – | – | – |
| `You are Qwen Code` (P) | ✓ | – | – | – | – | – | ✓* | – |
| `<skills_instructions>` (P) | – | – | – | – | – | – | – | ✓ |
| `<plugins_instructions>` (P) | – | – | – | – | – | – | – | ✓ |

\* Qwen also matches `"\nYou are Qwen Code"` (leading-newline variant) which no
other site has.

Note Codex's *stripping* helper `normalizeUserText`
(`CodexAdapter.swift:391-423`) additionally peels `skills_instructions` /
`plugins_instructions` blocks before calling `isSystemInjection`, so Codex's
*effective* recognized set differs again from its declared `isSystemInjection`.

### 1.3 Behavioral divergences with concrete inputs

All adapters apply `isSystemInjection` at **header-count time** only (e.g.
`ClaudeCodeAdapter.swift:96-99`: injection → `systemCount++` and excluded from
`messageCount`); the matching `streamMessages` `message(from:)` does **not**
call it (e.g. `ClaudeCodeAdapter.swift:197-214`, `IflowAdapter.swift:147-161`,
`QwenAdapter.swift:141-154`, `QoderAdapter.swift:150-164`). The SwiftIndexer
re-applies its *own* set (#8) at stream-stat time
(`SwiftIndexer.swift:132`). The render path applies the canonical set (#1).

**Divergence A — Codex `<command-name>` slash-command echo (BEHAVIORAL).**
Input: a Codex `user` message whose text is
`<command-name>/review</command-name><command-message>...`.
- Canonical (#1) and TS codex reference recognize `<command-name>` → render as
  `agentComm` (system), and TS would count it as `systemCount`.
- Swift Codex header set (#3) does **not** contain `<command-name>` → counted
  as a real `userMessageCount`, inflating `messageCount`.
- Consequence: the message is **counted as a user turn** in the stored
  `sessions` row (drives tier toward `normal`/`premium`) but **rendered as a
  system pill** in the app (`MessageParser` uses #1). User sees "5 messages" in
  the list but 4 conversational bubbles; a pure-slash-command session can be
  promoted from `skip`/`lite` to `normal` and get embedded.

**Divergence B — Qwen `# AGENTS.md` preamble (BEHAVIORAL).**
Input: a Qwen first user message starting `# AGENTS.md instructions for foo`.
- Qwen set (#7) lacks the `# AGENTS.md` prefix (only `You are Qwen Code` /
  `<INSTRUCTIONS>`). Every other header set has it.
- Consequence: in Qwen the AGENTS.md preamble is counted as a real user message
  and becomes `firstUserText` → the session **summary/title** becomes the
  AGENTS.md boilerplate, and `isSkippableFirstUserMessages`
  (`SwiftIndexer.swift:233`, which *does* check `# AGENTS.md`) may then mark it
  preamble→`skip` while the header still counted it as user. Header count and
  tier-preamble logic disagree on the same string.

**Divergence C — `<skills_instructions>` block (BEHAVIORAL, indexer-only).**
Input: a Claude-Code user message starting `<skills_instructions>...`.
- Adapter header set (#2) does not list it → counted as user (`userCount++`).
- SwiftIndexer stream set (#8) lists it → `streamStats` skips it
  (`SwiftIndexer.swift:132`), so `summaryMessageCount` (indexed count) excludes
  it.
- Consequence: `messageCount` (header, used for tiering at
  `SwiftIndexer.swift:157`) > `summaryMessageCount` (indexed). The session is
  tiered as if it had one more user turn than is actually FTS-indexed.

**Cosmetic-only today:** the `<system-reminder>` / `<EXTREMELY_IMPORTANT>` /
`<subagent_notification>` prefixes exist only in the canonical render path; no
adapter header counts them, so they never affect counts — but they *do* affect
render, and any future adapter that forgets them silently regresses.

### 1.4 Proposed API and migration

Single enum in `Shared/EngramCore/SystemMessageClassifier.swift`, extend the
existing type rather than add a parallel one:

```swift
public enum SystemMessageClassifier {
    // Existing render-time API (keep, now delegates):
    public static func classify(content: String, source: String)
        -> SharedSystemMessageCategory

    // New unified injection predicate. `source` lets per-source tags
    // (antigravity <SYSTEM_MESSAGE>, qwen "You are Qwen Code") stay scoped
    // instead of leaking into every adapter.
    public static func isInjection(_ content: String, source: SourceName) -> Bool {
        classify(content: content, source: source.rawValue) != .none
    }
}
```

Make `classify` the union of all currently-recognized tags (the matrix's
left column), with the two source-scoped tags gated on `source`. Then route:

1. Every adapter header loop: replace `Self.isSystemInjection(text)` with
   `SystemMessageClassifier.isInjection(text, source: self.source)`. Delete the
   7 private copies (#2–#7 and the Codex one). Keep Codex's `normalizeUserText`
   block-stripping (it does more than classify) but have it call
   `isInjection` instead of its private helper.
2. `SwiftIndexer.streamStats` (#8): replace `Self.isSystemInjection(content)`
   with `SystemMessageClassifier.isInjection(content, source: info.source)`.
   This is the fix that re-aligns header vs indexed counts.
3. `MessageParser`/`EngramWebUIServer` already call `classify` — no change,
   they now see the same superset.

Migration risk: widening Codex/Qwen recognition will change some stored
`messageCount`/`tier` values on next re-index. Gate behind a snapshot-hash
re-index (the hash already includes `messageCount`,
`SwiftIndexer.swift:205`), so changed sessions re-tier automatically. Add the
parity assertion from §6 first so the change is observable.

---

## 2. Provider-probe detection — SwiftIndexer:247-266 vs StartupBackfills:864-883

### 2.1 Token-by-token comparison

`SwiftIndexer.isProviderReviewPrompt` (`SwiftIndexer.swift:247-266`) and
`StartupBackfills.isProviderReviewSummary` (`StartupBackfills.swift:864-883`)
are **character-identical** in their bodies (verified line-by-line: same
`isStageFactProbe`, `isScopedInput`, `asksForOnlyFindings`, `isReviewProbe`,
same final `isStageFactProbe || (isReviewProbe && isScopedInput &&
asksForOnlyFindings)`). The only difference is the wrapper:

- SwiftIndexer's `isSkippableFirstUserMessages` (`:224-236`) gates on
  `healthProbePrompts` = `Set(["ping"])` (`:268-270`) — **one** entry.
- StartupBackfills' `isPolycliProviderSummary` (`:844-862`) gates on a literal
  set `ping` / `quick ping` / `test ping` / `quick ping check` / `ping-pong
  test`, plus two regexes (`You are acting as … inside polycli.`,
  `Reply with POLYCLI_HEALTH_OK only.`).

So the *health-prompt* recognition sets disagree (1 vs 5+2), exactly as round 6
noted (`"ping"` only vs `POLYCLI_HEALTH_OK`).

### 2.2 The over-broad heuristic — a real review prompt wrongly hidden

The shared body's `isScopedInput` includes `lower.contains("tests ")` (note
trailing space) and `isReviewProbe` includes `lower.contains("review")`.
`asksForOnlyFindings` includes `lower.contains("correctness")`.

**Concrete false-positive (BEHAVIORAL):** A genuine, substantial review-request
session whose first user message is:

> "Please review the auth refactor for correctness. The unit tests passed but I
> want a second pair of eyes on the token-rotation path."

- `isReviewProbe` = true (`contains("review")`).
- `isScopedInput` = true (`contains("tests ")` matches "tests passed").
- `asksForOnlyFindings` = true (`contains("correctness")`).
- → `isProviderReviewPrompt` returns **true**.
- In SwiftIndexer, `isSkippableFirstUserMessages` returns true →
  `TierInput.isPreamble = true` (`SwiftIndexer.swift:165`) → `SessionTier`
  returns `.skip` (`SessionTier.swift:10`).
- Consequence: a real multi-turn review session is **hidden** (tier=skip → DB
  only, no FTS, never surfaces in UI lists which filter `tier != 'skip'`).

This is the highest-severity item in this section: substring-soup on free-text
prompts cannot distinguish a 2-line polycli probe from a paragraph-long human
review request.

### 2.3 Proposed `PolycliProbeDetector` — structural signals first

```swift
public enum PolycliProbeDetector {
    public struct Signals {
        var originator: String?        // session_meta.originator / sidecar
        var summaryExact: String?      // trimmed first-user / summary
        var source: SourceName
        var messageCount: Int
    }

    public static func isProbe(_ s: Signals) -> Bool {
        // 1. STRUCTURAL (deterministic, high-confidence) — decide alone.
        if let exact = s.summaryExact?.lowercased() {
            if Self.exactHealthPrompts.contains(exact) { return true }
            if exact.range(of: #"^reply with polycli_health_ok only\.?$"#,
                           options: .regularExpression) != nil { return true }
            if exact.range(of: #"^you are acting as [a-z0-9_-]+ inside polycli\."#,
                           options: .regularExpression) != nil { return true }
        }
        // 2. STRUCTURAL stage-fact probe (anchored, not substring).
        if let exact = s.summaryExact?.lowercased(),
           exact.hasPrefix("no tools.") && exact.contains("stage ") &&
           (exact.contains("facts") || exact.contains("verified") || exact.contains("diff:")) {
            return true
        }
        // 3. NO free-text "review"/"tests " substring fallback.
        //    A review *request* is a real session; only the exact polycli
        //    probe templates above are throwaways.
        return false
    }

    private static let exactHealthPrompts: Set<String> = [
        "ping", "quick ping", "test ping", "quick ping check", "ping-pong test"
    ]
}
```

Key design choices, prefer structural over substring:
- Drop the `isReviewProbe && isScopedInput && asksForOnlyFindings` branch
  entirely. It was the source of the false-positive in §2.2 and has no
  deterministic anchor.
- Health/template prompts are matched by **exact string** or **anchored regex**
  (`^…$`), not `contains`.
- Both SwiftIndexer and StartupBackfills call `PolycliProbeDetector.isProbe`;
  the single `exactHealthPrompts` set ends the 1-vs-5 disagreement.
- StartupBackfills additionally has originator/cwd-concurrency confirmation
  (`isConcurrentProviderChild`, `:785-801`); keep that as the *linking* gate,
  separate from the *probe* gate.

Verdict: **BEHAVIORAL** — review sessions are currently mis-hidden.

---

## 3. Parent scoring — ParentDetection.scoreCandidate vs scorePolycliHostCandidate

### 3.1 The two functions

**A. `ParentDetection.scoreCandidate`**
(`Shared/EngramCore/Indexing/ParentDetection.swift:74-131`), used by the
suggested-parent backfill (`StartupBackfills.swift:740`):
- Reject if `agentStart < parentStart`.
- If parent ended before agent: `maxGap = 4h`; reject if gap > 4h or cwd
  unrelated/unknown.
- `timeScore = exp(-diffSeconds / 14_400) * 0.6 * cwdPenalty` — **exponential,
  4h (14400s) half-life-ish decay**, never hard-zero on age alone.
- `projectScore` 0–0.3, `activeScore` 0.01–0.1. Total typically 0–1.0.

**B. `StartupBackfills.scorePolycliHostCandidate`**
(`StartupBackfills.swift:885-935`), used by the polycli provider-parent linker
(`:681`):
- Reject if `parentStart > childStart` or cwd not **exactly equal** (no nested
  relation).
- Base `3.0`; +3.0 if parent still open at child start, else +0.8 (and reject
  if post-end gap > 30min); +1.2 if parent has no end_time.
- Age term: `<=6h` linear `2*(1-age/6)`; `6–48h` linear `max(0, 0.8*(1-(age-6)/42))`;
  **>48h → hard return 0**.
- +0.3 codex / +0.2 claude bonus. Total typically 3–8.

Different units (B is ~10× A), different time windows (4h-exp vs 6h/48h-piece),
different cwd rules (A allows nested, B requires exact), different gap cutoffs
(4h vs 30min). The SQL prefilters also differ: A's query window is `-24 hours`
(`:731`), B's is `-48 hours` (`:675`).

### 3.2 Candidate pair that links differently (BEHAVIORAL)

Setup: child agent session and one candidate parent, **same cwd**
`/Users/x/proj`, child starts **7 hours** after parent start, parent has an
`end_time` 7.5h after parent start (still "open" at — no, ended 0.5h before
child… let me pin it): parent `start=T`, `end=T+6h`; child `start=T+7h`. Gap
between parent-end and child-start = 1h. cwd identical.

- **Path B (polycli linker, scorePolycliHostCandidate):** parentEnd (T+6h) <
  childStart (T+7h), gap = 1h > 30min → `return 0`. Plus age 7h is in the
  6–48h band so it would have scored, but the 30-min post-end gap rule fires
  first → **score 0, no link**.
- **Path A (suggested-parent, scoreCandidate):** parent ended before agent,
  gap 1h ≤ 4h maxGap, cwd `.exact` (not unrelated) → not rejected.
  `timeScore = exp(-25200/14400)*0.6 ≈ exp(-1.75)*0.6 ≈ 0.104`; `projectScore`
  cwd exact = 0.28; `activeScore` endedBefore = 0.02 → total ≈ **0.40 > 0 →
  suggested link created**.

So the *same* (child, parent, cwd, timing) tuple is linked (as a suggestion) by
Path A and rejected by Path B. Conversely a 40-hour-gap same-cwd pair: Path B's
48h window keeps it alive (age band 6–48h), Path A's `-24 hours` SQL prefilter
(`:731`) never even fetches the parent → no suggestion. The two paths disagree
on linkage in both directions.

Note these two paths feed *different columns* today (B → `parent_session_id`
confirmed; A → `suggested_parent_id` advisory), so a user could see a confirmed
link from one heuristic and a *different* suggested parent from the other for
sibling sessions in the same cwd cluster — inconsistent grouping in the UI.

### 3.3 Proposed `ParentScoring` module

One module, named/documented constants, two named profiles rather than two
copy-pasted functions:

```swift
public enum ParentScoring {
    // Documented, single source for every time constant.
    public static let timeHalfLifeSeconds: TimeInterval = 14_400   // 4h
    public static let maxEndGapSeconds: TimeInterval     = 4 * 3600 // suggestion path
    public static let probeMaxEndGapSeconds: TimeInterval = 30 * 60 // polycli path
    public static let maxAgeSeconds: TimeInterval        = 48 * 3600
    public static let sqlWindowHours = 48                            // unify A's 24→48

    public enum Profile { case suggestion   // advisory, exp decay, nested cwd ok
                          case polycliHost } // confirm, requires exact cwd

    public static func score(_ c: Candidate, profile: Profile) -> Double { ... }
}
```

- Collapse the exponential and piecewise curves into one decay with a profile
  flag, OR (lower-risk) keep two curves but move both into this module with the
  shared constants, and document *why* polycli is stricter (cwd-exact +
  30-min gap because polycli children are near-concurrent by construction).
- Unify the SQL prefilter window to `ParentScoring.sqlWindowHours` so the
  fetch set matches the scorer's `maxAgeSeconds` (today A fetches 24h but
  scores out to ∞ via exp; B fetches 48h and scores to 48h — A's prefilter is
  the tighter, silently-dropping one).
- Add a parity test (see §6) over a shared corpus asserting both profiles agree
  on the **link/no-link boolean** for cases where they're supposed to.

Verdict: **BEHAVIORAL** — confirmed by the constructed pair in §3.2.

---

## 4. Adapter count↔stream divergence — per adapter

`messageCount` is computed in `parseSessionInfo` and feeds `SessionTier.compute`
(`SwiftIndexer.swift:157`). The streamed message list is what gets indexed
(`streamStats`, and `summaryMessageCount = indexedMessageCount`,
`SwiftIndexer.swift:170`). When they diverge, the tier is decided on a count
that does not match reality.

| Adapter | header `messageCount` formula | stream emits | divergence | tier consequence |
|---|---|---|---|---|
| **ClaudeCode** | `userCount+assistantCount+toolCount`, injection→system excluded (`ClaudeCodeAdapter.swift:121`, `:96-99`) | every user/assistant object, no injection filter (`:197-214`) | stream > header by # of injection user msgs | header undercounts → session may sit at `lite`/`normal` while indexed content is larger |
| **Codex** | `userCount+assistantCount+toolCount`; tool = `function_call` only (`CodexAdapter.swift:217-220,243`) | `function_call` **and** `function_call_output` both → `.tool` (`:359-378`) | stream tool count ≈ 2× header tool count | header undercounts tool turns; `streamStats` re-counts so `summaryMessageCount` > `messageCount` |
| **Qwen** | `userCount+assistantCount`, injection excluded (`QwenAdapter.swift:101,81-84`); narrow injection set (no `# AGENTS.md`) | every user/assistant, no filter (`:141-154`) | header counts AGENTS.md preamble as user; stream emits it too but tier-preamble logic skips it | summary/title polluted; preamble vs count disagree (§1.3-B) |
| **Iflow** | `userCount+assistantCount`, injection excluded (`IflowAdapter.swift:100,80-84`); minimal injection set (3 tags) | every user/assistant, no filter (`:147-161`) | injection msgs beyond the 3 tags counted user in header, also streamed | header≈stream here but both miss `<command-name>` etc. → over-counts vs canonical |
| **CommandCode** | `userCount+assistantCount+toolCount`, injection excluded (`CommandCodeAdapter.swift:103,78-79`) | every user/assistant, no injection filter (`:143-…`) | stream > header by injection user msgs | same as ClaudeCode |
| **Qoder** | `userCount+assistantCount+toolCount`, injection excluded (`QoderAdapter.swift:110,88-89`); injection set = only `# AGENTS.md`+`<INSTRUCTIONS>` | stream classifies tool-result→`.tool` (`:150-164`) but never injection | header injection set tiny → most wrappers counted user; stream also counts them | over-count both sides; narrowest injection set of all adapters |
| **VsCode** | `requestObjects.count * 2` (`VsCodeAdapter.swift:65`) — hardcoded 2/request | per request: 0, 1, or 2 (only non-empty user/assistant text) (`:101-129`) | header always 2N; stream ≤ 2N, often < | a request with only a user prompt and empty assistant (in-flight/aborted) counts 2 in header, 1 in stream; a tool-only request counts 2 vs 0 → header massively over-counts → wrongly promoted to `premium` at `messageCount>=20` (10 requests) |
| **OpenCode** | `userCount+assistantCount` (one per message row) (`OpenCodeAdapter.swift:156,124-138`) | JOIN on `part`, one stream msg per **non-empty text part**; tool-only/empty msgs → 0 (`:185-206,267-294`) | header counts message; stream counts text parts (can be 0 or many) | a session of mostly tool-call messages (no text parts) counts N in header, ~0 in stream → tiered as a real session but indexes empty |

All eight confirmed BEHAVIORAL (different stored `messageCount` than the
content actually streamed/indexed).

### 4.1 Proposed shared `normalize() -> [NormalizedMessage]`

The root cause is that each adapter has *two* parsers. Collapse to one:

```swift
public protocol SessionAdapter {
    // The ONE parser. Produces the canonical message list + raw metadata.
    func normalize(locator: String) async throws
        -> AdapterParseResult<(meta: SessionMeta, messages: [NormalizedMessage])>
}

// Header counts become a pure projection of the message list:
extension NormalizedSessionInfo {
    static func counting(_ msgs: [NormalizedMessage], meta: SessionMeta) -> Self {
        // userMessageCount = msgs.filter { $0.role == .user }.count, etc.
        // messageCount = msgs.count  (BY CONSTRUCTION equal to stream count)
    }
}
```

- `parseSessionInfo` = `normalize` then `NormalizedSessionInfo.counting(...)`.
- `streamMessages` = `normalize` then `applyWindow`.
- Injection classification happens **once**, inside `normalize`, via
  `SystemMessageClassifier.isInjection` (§1.4): injected user messages are
  either dropped or emitted as `.system` role — but the *same* decision feeds
  both count and stream because there is only one list.
- VsCode's `*2` and OpenCode's part-vs-message mismatch vanish because the count
  is `messages.count` by construction.
- Codex `function_call_output` is either counted as `.tool` in both or in
  neither — one decision.

Migration: implement `normalize` per adapter (mechanical — the logic already
exists in the two halves), keep `parseSessionInfo`/`streamMessages` as thin
shims for the protocol, then the §6 parity assertion holds by construction.

---

## 5. TS↔Swift tier parity

Source: `src/core/session-tier.ts` (TS reference) vs
`macos/Shared/EngramCore/Indexing/SessionTier.swift` (product).

| Rule | TS | Swift | Verdict |
|---|---|---|---|
| `isPreamble → skip` | yes (`:54`) | yes (`:10`) | parity |
| `/.engram/probes/ → skip` | yes (`:56`) | yes (`:11`) | parity |
| `agentRole != null → skip` | yes (`:57`) | yes (`:12`) | parity |
| `/subagents/ → skip` | yes (`:58`) | yes (`:13`) | parity |
| `messageCount <= 1 → skip` | yes (`:59`) | yes (`:14`) | parity |
| `assistantCount==0 && tool==0 → lite` | yes (`:62-67`) | yes (`:15-20`) | parity |
| **`messageCount<=3 && PROBE_FIRST_LINES → lite`** | **yes (`:69-75`)** | **ABSENT** | **BEHAVIORAL** |
| `messageCount>=20 → premium` | yes (`:78`) | yes (`:22`) | parity |
| `messageCount>=10 && project → premium` | yes (`:79`) | yes (`:23`) | parity |
| `duration>30min → premium` | yes (`:80`) | yes (`:24`) | parity |
| `summary matches NOISE_PATTERNS → lite` | yes, **6 patterns** (`:17-24`) | yes, **2 patterns** (`:37`) | **BEHAVIORAL** |

- `PROBE_FIRST_LINES` (TS `:28-38`): `ping, hi, hello, test, echo, ok, hey, say
  hello, reply: t4` — none of this exists in Swift. A short Swift session whose
  summary is "hi" stays `normal`; TS makes it `lite`.
- `NOISE_PATTERNS`: TS has `/usage`, `Generate a short, clear title`, `Reply
  exactly:`, `Reply with exactly:`, `reply with just`, `/status/exit`. Swift
  has only the first two (`SessionTier.swift:37`). A session summarized
  `Reply with just the number` is `lite` in TS, `normal` in Swift → embedded in
  product but suppressed in the reference regression suite. The TS suite
  therefore cannot catch the Swift behavior, and vice versa.

**Canonical decision:** Swift is the product runtime, so **Swift is
canonical** — but it is currently the *less* complete one. The probe→lite and
6-pattern noise rules are correct noise-suppression behavior and should be
**ported into `SessionTier.swift`** (add `PROBE_FIRST_LINES` set + the
`messageCount<=3` rule; extend `noisePatterns` to all 6). Then TS becomes the
mirror, and a shared corpus (§6) pins them together. Do NOT instead delete the
TS rules — they encode real noise classes seen in production.

---

## 6. Parity-test additions to prevent regression

### 6.1 Count↔stream parity assertion (catches §1, §4)

In `AdapterParityHarness.run()` results, add to
`macos/EngramCoreTests/AdapterParityTests.swift` after line 81:

```swift
guard let info = result.sessionInfo else { continue }
// messageCount MUST equal the streamed message count (single source of truth).
XCTAssertEqual(info.messageCount, result.messages.count,
    "\(result.source.rawValue): header messageCount != streamed count")
// Per-role tallies must match the stream.
let u = result.messages.filter { $0.role == .user }.count
let a = result.messages.filter { $0.role == .assistant }.count
let t = result.messages.filter { $0.role == .tool }.count
XCTAssertEqual(info.userMessageCount, u, "\(result.source.rawValue) user")
XCTAssertEqual(info.assistantMessageCount, a, "\(result.source.rawValue) assistant")
XCTAssertEqual(info.toolMessageCount, t, "\(result.source.rawValue) tool")
```

This fails **today** for ClaudeCode, Codex, Qwen, CommandCode, Qoder, VsCode,
OpenCode (and any adapter that excludes injection from the header but streams
it). It only goes green after the §4 `normalize()` consolidation. It must be
added *before* the consolidation so the fix is observable. Note: the current
goldens may also need regeneration since they encode the divergence — the
assertion is against `result` (live parser output), not the golden, which is
the point.

### 6.2 TS↔Swift tier corpus test (catches §5)

Add a shared JSON corpus `tests/fixtures/tier-corpus.json` of `(TierInput,
expectedTier)` cases covering: each skip rule, the probe→lite rule (summary
`"hi"`, count 2), each of the 6 NOISE_PATTERNS, the premium thresholds, the
duration rule. Run it from **both**:
- TS: extend `tests/core/session-tier.test.ts` to load the corpus and assert
  `computeTier(input) === expected`.
- Swift: new `macos/EngramCoreTests/SessionTierTests.swift` loading the same
  corpus (copied as a bundle resource) and asserting `SessionTier.compute(...)
  == expected`.

The corpus is the single source of truth for tier behavior; any divergence
fails one side. Today there is **no Swift `SessionTier` test at all** (grep:
only `IndexerParityTests` references `TierInput`, no dedicated tier suite).

### 6.3 Parent-scoring parity (catches §3)

A shared corpus of `(child, candidate parent, expected link?)` run against both
`ParentScoring.score(.suggestion)` and `.polycliHost`, asserting agreement on
the cases that should agree and documenting (with an explicit expected-differ
flag) the cases where polycli is intentionally stricter. Round 6 noted the
existing `ParentDetectionParityTests` covers only 2/15 cases via a hardcoded
`switch` with `default: XCTFail` — replace with the corpus.

### 6.4 Injection-classifier exhaustiveness (catches §1)

A table test feeding each tag in the §1.2 matrix's left column to
`SystemMessageClassifier.isInjection(_, source:)` for every `SourceName`,
asserting the expected (source-scoped) result. This pins the union set and
prevents an adapter from silently shipping a narrower copy again — because there
will be no copies, only the one classifier.

---

## 7. Priority / sequencing

1. **Add §6.1 + §6.2 + §6.4 assertions first** (they will fail — that is the
   proof the divergences are real and behavioral).
2. **§1.4** consolidate injection classifier (unblocks §6.1 partly, §6.4 fully).
3. **§4.1** `normalize()` single-parser (makes §6.1 green by construction).
4. **§5** port probe→lite + 6 NOISE_PATTERNS into Swift (makes §6.2 green).
5. **§3.3** `ParentScoring` module + unify SQL window (makes §6.3 green).
6. **§2.3** `PolycliProbeDetector` structural-first (fixes the review-session
   hiding; lower blast radius, do after the count work since tier depends on
   counts).

All five divergences are **BEHAVIORAL**, each with a concrete differing input
above. The cosmetic-only residue is the render-only canonical tags
(`<system-reminder>` etc.) that no count path reads yet — still worth folding
into the single classifier to prevent the next regression.
