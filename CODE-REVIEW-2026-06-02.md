# Engram macOS Swift Product — Code Review Report

## Executive summary

The Engram Swift product is structurally sound and the concurrency discipline is, with isolated exceptions, consistently applied (most DB reads correctly hop off the main actor via `Task.detached`/`readInBackground`). The real risk concentrates in three subsystems. **(1) Parent-detection/tiering and indexing** carries the most consequential defect: a re-index of any session file silently clobbers writer-owned `agent_role`/`tier` classification because the upsert in `SessionSnapshotWriter` uses `excluded.*` with no `COALESCE`, so dispatched/skip agent children resurface as independent top-level sessions on a very common event. **(2) Project migration** has two encoder defects (Claude Code dot-to-dash omission; Gemini basename-vs-slug) that cause moves to silently orphan session directories with no error surfaced. **(3) The native web UI transcript pager** mixes raw and displayed message-count units across three places, producing broken Previous-navigation, wrong "Showing X-Y" labels, and O(N²) full-file re-parsing per page. A recurring secondary theme spans the read path: several UI surfaces (Sessions page, Projects, Today Workbench) omit the documented `topLevelOnly` / parent-suggested filter, so heuristic suggested-children appear as duplicate top-level rows once parent-detection runs. The single most important thing to fix is the **re-index classification clobber in `SessionSnapshotWriter.swift:216-217`** — it is high-severity data-integrity, triggers on the most frequent operation in the system, and is self-perpetuating until a detection-version bump.

## Findings

Two findings sharing the Today Follow-ups root cause (`HomeView.swift:497-511`) are merged below. The "no top-level filter" data class (Sessions page, Projects, Today Follow-ups) is kept as separate findings because they live in different files and views, but they are cross-referenced and form one fix theme. Severities were recalibrated for whole-set consistency: the indexing clobber and the two migration encoder bugs remain High (silent data orphaning on common operations); the transcript-highlight Unicode misalignment was downgraded from High to Medium (narrow Unicode trigger, cosmetic-only, medium confidence) to align it with peers of equal blast radius.

### High

**Re-index clobbers Layer-2 dispatched/skip classification (no COALESCE on upsert)**
parent-detection-tiering · data-integrity · high
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:216-217` (merge path: lines 92-94, 112)
- What's wrong: The upsert `ON CONFLICT` sets `tier = excluded.tier` and `agent_role = excluded.agent_role` with no `COALESCE`; the merge path likewise overwrites with the recomputed nil/non-skip values. A codex/gemini child classified by `backfillSuggestedParents` (`StartupBackfills.swift:904-913`) as `dispatched`/`skip` has `link_checked_at` set, so it is never re-classified (candidate query requires `link_checked_at IS NULL`, line 850).
- Impact: Any re-index (content append, even a size-only change) reverts `agent_role` to NULL and `tier` to normal/premium, resurfacing the hidden agent child as an independent top-level session — polluting the session list, today-parents badge, and FTS/embedding queues — until the next `DETECTION_VERSION` bump.
- Fix: Use `agent_role = COALESCE(excluded.agent_role, sessions.agent_role)` and refuse to downgrade a `skip` tier when `agent_role` is non-null (`CASE WHEN sessions.tier='skip' AND sessions.agent_role IS NOT NULL THEN sessions.tier ELSE excluded.tier END`). Add a Swift re-index-preservation test.

**Claude Code / qoder dir encoder omits dot-to-dash mapping; move skips session-dir rename for any dotted cwd**
project-migration · data-integrity · high
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/ProjectMove/EncodeClaudeCodeDir.swift:16-18` (also used for qoder: `Sources.swift:96`)
- What's wrong: `encode` does `replacingOccurrences(of: "/", with: "-")` only; real Claude Code encodes both `/` and `.` to `-` (verified live: `.config` → `-config`). The Swift encoder keeps the dot, computing a directory that does not exist.
- Impact: For any cwd with a dot in a segment (`.config`, `.local`, `app.v2` — very common), Orchestrator Step 0.5 computes the wrong oldDir/newDir, Step 2 hits ENOENT and records skipped(missing), and the session dir keeps its stale encoded name while the DB cwd/source_locator is rewritten — sessions orphaned, move reports success. Locked-in test at `SessionSourcesTests:65-66` must be updated.
- Fix: `.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")`; update `EncodeClaudeCodeDirTests` and verify against the qoder layout.

**Gemini dir encoder uses basename instead of slug; move skips Gemini tmp-dir rename and projects.json update**
project-migration · data-integrity · high
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/ProjectMove/Sources.swift:83-87` (also `GeminiProjectsJSON.swift:69`)
- What's wrong: `geminiCli encodeProjectDir` returns `lastPathComponent`, but the real tmp dir (and projects.json value) is a slug (lowercased, `_`→`-`, wrapping dashes stripped). Verified live: `surge` ← `/Users/bing/-NetWork-/Surge`.
- Impact: For any Gemini project whose basename ≠ slug (mixed case, underscores, wrapping dashes), Step 0.5 computes a non-existent oldDir, Step 2 records skipped(missing), and Step 2.5 (`projects.json` apply, gated on `renamedDirs.contains{.geminiCli}`) is also skipped — the tmp dir and registry entry silently keep pointing at the old cwd, no error reported.
- Fix: Apply Gemini's real slug rule in both the `encodeProjectDir` closure and `GeminiProjectsJSON` `newEntry.name`, or reverse-lookup the dir name from projects.json (cwd → name). Add a mixed-case/underscore parity test.

### Medium

**Gemini sidecar (Layer 1c) parentSessionId parsed but never persisted — deterministic link is dead**
parent-detection-tiering · correctness · high
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:197-244`
- What's wrong: `GeminiCliAdapter.swift:152` sets `NormalizedSessionInfo.parentSessionId` from the sidecar, but `buildSnapshot()` never reads it, `AuthoritativeSessionSnapshot` (`IndexingEventTypes.swift:3-27`) has no such field, and `SessionSnapshotWriter.upsert` never writes `parent_session_id`. No backfill compensates for Gemini.
- Impact: The documented Layer 1c deterministic link never lands; Gemini agent children get at best an advisory `suggested_parent_id`, or surface as independent top-level sessions if scoring finds no candidate. Adapter sidecar-read work is wasted.
- Fix: Add `parentSessionId` to `AuthoritativeSessionSnapshot`, populate in `buildSnapshot()`, persist via `setParentSession`/`link_source='path'` on insert (guard against overwriting a `link_source='manual'` link). Add a Swift test.

**SessionsPageView omits topLevelOnly: suggested-children appear as duplicate top-level rows**
ui-pages · correctness · high
`/Users/bing/-Code-/engram/macos/Engram/Views/Pages/SessionsPageView.swift:104-111`
- What's wrong: `loadData` calls `listSessions(... subAgent: false ...)` without `topLevelOnly: true`. The `subAgent==false` filter only adds `tier != 'skip'` (`Database.swift:117-143`); Layer-2 suggested-children keep their normal tier and survive. Sibling `SessionListView.swift:415-419` correctly passes `topLevelOnly`.
- Impact: A suggested-child renders both as its own top-level card and nested under its suggested parent — same session shown twice. Violates the documented top-level invariant for any DB where parent-detection has run (the common case).
- Fix: Pass `topLevelOnly: true` to both `listSessions` and `sessionListStats` in `loadData`.

**"Show System Prompts" toggle is dead — system messages unconditionally hidden by the type-visibility gate**
models-classifiers · correctness · high
`/Users/bing/-Code-/engram/macos/Engram/Views/SessionDetailView.swift:60-66`
- What's wrong: `updateDisplayIndexed()` runs the `typeVisibility[idx.messageType]` gate before the `showSystemPrompts` check. systemPrompt classifies as `.system` (`MessageTypeClassifier.swift:95-96`), `.system` defaults to false in `defaultTypeVisibility` (lines 54-58) and is omitted from `MessageType.chipTypes` (line 44), so no chip can flip it true — gate (1) drops every `.system` message before `showSystemPrompts` is reached.
- Impact: The Settings "Show System Prompts" toggle (`SettingsView.swift:251`) silently does nothing; injected instructions only appear via the unrelated "Show All" button. agentComm is partially affected too.
- Fix: Gate `.system`/system-category messages on `showSystemPrompts`/`showAgentComm` rather than `typeVisibility`, or special-case `.system` / add it to `chipTypes`.

**AISettingsSection silently deletes custom-generation settings after collapsing the disclosure**
ui-transcript-workspace-settings · data-integrity · high
`/Users/bing/-Code-/engram/macos/Engram/Views/Settings/AISettingsSection.swift:377-392`
- What's wrong: `saveAISettings()` persists `summaryMaxTokens`/`summaryTemperature`/sample/truncate only when `showCustomGeneration`/`showAdvancedGeneration` are true and `removeValue()`s otherwise. Those flags back the DisclosureGroup expansion state; there's no `.onChange`. Collapsing the disclosure then editing any unrelated AI field runs the else-branch and deletes the saved keys from `~/.engram/settings.json`.
- Impact: User-configured generation tuning is silently and irrecoverably lost whenever the disclosure is collapsed and another AI field is changed.
- Fix: Decouple persistence from the disclosure flag — always persist current values, or track a separate explicit `customGenerationEnabled` bool distinct from expansion state.

**Transcript pagination re-reads and re-parses the entire file on every page request**
web-ui-server · perf · high
`/Users/bing/-Code-/engram/macos/EngramService/Core/EngramWebUIServer.swift:351-374`
- What's wrong: `readMessages` passes `limit: nil` to `streamMessages`, so JSONL adapters read and JSON-parse the whole file (`readObjects` → `StreamingLineReader.readLines()`), then `applyWindow` just `dropFirst(offset)` in memory; the entire post-offset suffix is materialized before the web loop's `count >= limit` break can fire.
- Impact: Each page load is O(N); paging the whole session is O(N²). Large transcripts (tens of MB) spike CPU/latency and materialize the full suffix into memory regardless of the 50-message page size.
- Fix: Pass `limit: limit` (plus headroom for filtered messages) so `applyWindow` caps the suffix, and/or break out of the adapter stream early. At minimum stop passing `limit: nil`.

**ContentSegment.id uses hashValue as an Identifiable key (CLAUDE.md violation) with deterministic list collisions**
app-core · correctness · high
`/Users/bing/-Code-/engram/macos/Engram/Core/ContentSegmentParser.swift:14-25` (consumed at `ContentSegmentViews.swift:88`)
- What's wrong: `id` is built from `hashValue` (`"t:\(s.hashValue)"`), and for lists from only count + first element (`"bl:\(items.count):\(items.first?.hashValue ?? 0)"`). Two consecutive bullet lists with equal count and identical first item but different remaining items deterministically collide. Directly violates the CLAUDE.md "Don't use hashValue for cache keys" rule.
- Impact: On id collision SwiftUI `ForEach` coalesces/drops the duplicate, so a paragraph/code block/list silently fails to render or shows wrong content, with a duplicate-id warning. List collisions are deterministic and realistic in transcripts.
- Fix: Derive id from full content (segment kind + full joined item text) or assign a sequential index-based id in the parser.

**SessionDetailView classifies/filters/substring-searches the whole transcript on the main thread; transcript loaded unbounded**
concurrency-perf-crosscut · perf · high
`/Users/bing/-Code-/engram/macos/Engram/Views/SessionDetailView.swift:313-326`
- What's wrong: Parse is off-main but with no limit, so the whole transcript loads into memory. Then on MainActor: `IndexedMessage.build(from:)` classifies every message (316), `updateDisplayIndexed()` filters every message (319), and `.onChange(of: searchText)` → `updateMatchIndices()` (326) lowercases and `.contains`-scans every message's full content per keystroke.
- Impact: Opening a large session holds three full arrays in memory and runs O(n) classify/filter on open plus an O(n) full-content scan per keystroke — main-thread CPU work causing UI hangs proportional to transcript size.
- Fix: Run `IndexedMessage.build` and the initial filter inside the detached parse Task and hop only finished arrays back; debounce `updateMatchIndices` and run off-main; pass a sane parse limit with paging.

**PopoverView.loadData runs sourceStats() synchronously on the main thread after the detached block returns**
concurrency-perf-crosscut · perf · high
`/Users/bing/-Code-/engram/macos/Engram/Views/PopoverView.swift:240`
- What's wrong: After the detached read (204-233) returns, execution resumes on MainActor and line 240 `(try? db.sourceStats())` runs a synchronous `nonisolated` `readInBackground`/`pool.read` — a full-table aggregate over the sessions table — directly on the main thread.
- Impact: The frequently-shown menu-bar popover blocks the main thread on a full-table aggregate (and a cold-pool synchronous open) each load — a perceptible hitch on large DBs. The one clear violation in an otherwise consistently-detached codebase.
- Fix: Move `sourceStats()` and the stats-derived health computation inside the existing `Task.detached` block (return alongside the tuple), or wrap it in its own detached hop.

**linkSessions holds the single writer gate for up to 10k filesystem symlink operations despite no DB writes**
service-runtime · concurrency · high
`/Users/bing/-Code-/engram/macos/EngramService/Core/EngramServiceCommandHandler.swift:277-286` (impl 964-1052)
- What's wrong: The command runs through `writerGate.performWriteCommand { _ in ... }` but the closure discards the writer and the impl opens its own read-only queue, reads up to 10,000 rows, then loops doing only filesystem work (symlink create/remove) — no DB mutation.
- Impact: A single call serializes up to 10k filesystem ops behind the write gate, blocking every real write command (save_insight, project move, set_favorite, summary/title, indexing writes). On a slow/wedged FS it holds the gate until the 60s timeout, failing queued writes with WriterBusy though no DB write occurred.
- Fix: Run `linkSessions` outside the write gate (it already uses an independent read queue and only touches the filesystem); if serialization is wanted, use a separate lightweight lock.

**Transcript search highlight maps lowercased() indices against the original string, misaligning on length-changing Unicode**
ui-transcript-workspace-settings · correctness · medium
`/Users/bing/-Code-/engram/macos/Engram/Views/Transcript/ColorBarMessageView.swift:74-88`
- What's wrong: `highlightedText` finds match ranges in `lower = text.lowercased()`, then converts with `NSRange(range, in: text)` — passing `lower`-derived indices to a different string. When lowercasing changes length (`İ`→`i̇`, `ẞ`→`ss`), the UTF-16 offsets diverge.
- Impact: Find-in-transcript highlights the wrong characters (or shifts subsequent highlights) for messages with length-changing Unicode. Cosmetic-but-wrong; no data loss; narrow trigger.
- Fix: Search and map against a single string — use `text.range(of:options:.caseInsensitive)` directly, or build the AttributedString from `lower`. Don't mix the two.

**runGit can block forever in ioGroup.wait() if a timed-out git child ignores SIGTERM with the pipe open**
write-indexer · concurrency · low→medium (kept Medium per input)
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/Indexing/RepoDiscovery.swift:247-252`
- What's wrong: On timeout, `terminate()` (SIGTERM) only signals the process; it does not close the child's pipe write ends. If git (or an inheriting helper) is stuck in uninterruptible I/O, the read end never reaches EOF and the unconditional `ioGroup.wait()` blocks indefinitely.
- Impact: A single wedged git invocation hangs `runGit` → `probeRepositories` (called synchronously from the periodic loop at `EngramServiceRunner.swift:308`), permanently stalling that indexing-loop iteration. Untested (the existing test uses `/bin/sleep`, which dies on SIGTERM). Confidence low.
- Fix: Escalate to SIGKILL if `finished.wait` times out, and bound `ioGroup.wait()` with a timeout so `runGit` always returns.

**VsCode messageCount hard-coded to requests×2 while streamMessages drops empty turns**
adapters · data-integrity · high
`/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/Sources/VsCodeAdapter.swift:65-67, 101-129`
- What's wrong: `parseSessionInfo` sets `messageCount = requests * 2` and fabricates the user/assistant split, but `streamMessages` only appends non-empty user/assistant text; `extractAssistantText` returns `""` for aborted/tool-only/non-markdown responses.
- Impact: Every VsCode session with an aborted, tool-only, or non-markdown assistant response reports more messages than the transcript contains; the role split is fabricated.
- Fix: Compute counts by running the same `extractUserText`/`extractAssistantText` filtering used in `streamMessages` and counting non-empty results.

**ClaudeCode tool-result user records counted as tool but streamed as empty .user messages**
adapters · correctness · high
`/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:124, 322-326, 352-390, 453-469`
- What's wrong: A user-type record containing a tool_result is counted as `toolCount` (line 124) but emitted with role `.user` (325); `formatToolResult` returns `""` unless the text starts with "User has answered", so most stream as an empty `.user` message (then skipped by `SwiftIndexer:188`).
- Impact: The same record is a tool message for counting but a user message for the transcript; `toolMessageCount` is inflated by tool-result turns that produce no visible content.
- Fix: Classify tool_result-only user records as role `.tool` (matching the count) or exclude them from `toolMessageCount` when formatted content is empty.

### Low

**GeminiCli/OpenCode count messages that streamMessages drops for empty content**
adapters · data-integrity · high
`/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift:115-121, 137, 209-216`
- What's wrong: `parseSessionInfo` counts every user/gemini/model entry regardless of content; `message(from:)` returns nil for empty extracted text. A function-call-only turn is counted but not streamed. (OpenCode has the stronger analogous version.)
- Impact: Gemini sessions with function-call-only turns report a higher messageCount than the transcript shows.
- Fix: Count only entries whose extracted content is non-empty (mirror the `message(from:)` predicate), or render a placeholder for non-text turns.

**Antigravity CLI cwd inference hard-codes the reviewer's personal path layout /Users/<u>/-Code-/<proj>**
adapters · correctness · high
`/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/Sources/AntigravityAdapter.swift:413-437`
- What's wrong: `inferredCWD` scans the transcript with regex `/Users/[^/]+/-Code-/([^/]+)` (line 421). The literal `-Code-` segment is one user's convention; any other machine yields no match and cwd `""`. Reachable independent of `enableLiveSync` (`cliTranscriptLocators()` listed unconditionally, 42-45).
- Impact: Antigravity CLI transcripts on machines not using `~/-Code-/` get empty cwd, breaking project association. Low volume.
- Fix: Derive cwd from a non-personal signal (a workdir field in transcript metadata, or a generic most-frequent absolute-path heuristic).

**Today Workbench Follow-ups: searches entire history with over-broad keywords and can surface suggested-children**
ui-pages / recent-churn-regression · correctness · medium (merged: two findings on the same call site)
`/Users/bing/-Code-/engram/macos/Engram/Views/Pages/HomeView.swift:497-511`
- What's wrong: `loadTodayFollowUps` calls `db.searchWithSnippets(query:limit:)` with no `since:` (defaults nil, orders `start_time DESC` over the whole FTS index) for very common markers (`review`, `todo`, `remaining`). `searchWithSnippets` (`Database.swift:440-498`) filters only `hidden_at IS NULL AND tier NOT IN ('skip','lite')` — no parent/suggested-parent exclusion.
- Impact: Despite the "Today" framing, results are dominated by arbitrarily old sessions, undermining the feature; and a normal-tier suggested-child can appear as a top-level Follow-ups row, inconsistent with the Continue panel and the top-level invariant.
- Fix: Pass a `since:` cutoff (24-72h), narrow the keyword set, and filter results by `parent_session_id IS NULL AND suggested_parent_id IS NULL` (or add `topLevelOnly` to `searchWithSnippets`). Add a test asserting date-scoping and dedup.

**ProjectsView session counts / Avg Sessions KPI include suggested-children**
ui-pages · correctness · medium
`/Users/bing/-Code-/engram/macos/Engram/Views/Pages/ProjectsView.swift:35-38`
- What's wrong: `listSessionsByProject()` (`Database.swift:965-986`) filters only `hidden_at IS NULL AND project IS NOT NULL AND tier != 'skip'` — no parent/suggested-parent exclusion, so suggested-children inflate `sessionCount`, the Avg Sessions KPI, and the drill-down list.
- Impact: Per-project counts, the KPI, and the project list over-represent activity. Same root cause as the SessionsPageView bug; lower severity (secondary view).
- Fix: Add the `parent_session_id IS NULL AND suggested_parent_id IS NULL` clause (or a `topLevelOnly` parameter) to `listSessionsByProject`.

**Today Continue/Follow-ups badge counts up to 8 but only 5 rows render**
ui-pages · correctness · high
`/Users/bing/-Code-/engram/macos/Engram/Views/Pages/HomeView.swift:106-117` (followUps: 150)
- What's wrong: The badge uses `recentSessions.count` while the list renders `prefix(5)`; `recentSessions` is fetched with `limit: 8`. Same mismatch for the Follow-ups panel.
- Impact: Badge overstates visible items (shows '8' over a 5-row list). Cosmetic.
- Fix: Render `prefix` matching the badge, or set the badge to `min(count, 5)`, or fetch with `limit: 5`.

**HomeView relativeTime() renders blank for whole-second start_time**
recent-churn-regression · correctness · high
`/Users/bing/-Code-/engram/macos/Engram/Views/Pages/HomeView.swift:1-5, 461-470`
- What's wrong: The Today rewrite's `todayISOFormatter` uses `[.withInternetDateTime, .withFractionalSeconds]`, which returns nil for whole-second timestamps; `relativeTime` returns `""` on nil. The canonical `Theme.formatTimestamp` (`Theme.swift:115-130`) has the non-fractional fallback the new code omits. Live DB has 15 whole-second sessions (all `antigravity`).
- Impact: Continue/Follow-ups relative-time label is blank for whole-second-timestamp sources. Display-only; freshly introduced by the Today rewrite.
- Fix: Use `Theme.formatTimestamp`-style dual parsing (fractional, then plain fallback) or a shared helper. Add a unit test with both `...:09Z` and `...:09.123Z`.

**Web UI "Previous" pager link computes offset in wrong units**
web-ui-server · correctness · high
`/Users/bing/-Code-/engram/macos/EngramService/Core/EngramWebUIServer.swift:267-272`
- What's wrong: `nextOffset` is a raw message index (counts filtered messages); `previousOffset = max(0, offset - limit)` subtracts a displayed-count from a raw offset — mixed units. Page 2's Previous from raw offset 130 yields 80, not 0.
- Impact: Previous never reliably returns to the prior page boundary whenever filtered messages exist between displayed ones (the common case) — windows overlap or skip.
- Fix: Track and return a `previousOffset` in raw units; use raw offsets consistently for both directions.

**Web UI "Showing X-Y" range label mixes raw offset with displayed count**
web-ui-server · correctness · high
`/Users/bing/-Code-/engram/macos/EngramService/Core/EngramWebUIServer.swift:277`
- What's wrong: `Showing \(offset + 1)-\(offset + page.messages.count)` adds a raw offset to a displayed count. At offset=130 with 50 displayed it reads "Showing 131-180" though far fewer than 130 displayable messages precede the page.
- Impact: The position indicator is off by the number of filtered messages before the page; users can't trust their position.
- Fix: Maintain a displayed-message cursor separately from the raw offset and render the range in one unit.

**Web UI missing session returns HTTP 200 instead of 404**
web-ui-server · api · high
`/Users/bing/-Code-/engram/macos/EngramService/Core/EngramWebUIServer.swift:71`
- What's wrong: `/session/:id` returns `htmlResponse(sessionPage(...))`; on not-found, `sessionPage` (253-255) returns a not-found HTML body but `htmlResponse` defaults `status: .ok`. The sibling percent-decode-failure branch (line 69) correctly returns `.notFound`.
- Impact: Clients/caches treating status as authoritative see a missing session as success.
- Fix: Have `sessionPage` signal not-found and pass `.notFound` to `htmlResponse`, mirroring line 69.

**No test covers web UI transcript pagination behavior**
web-ui-server / recent-churn-regression · test-gap · high (merged: two findings on the same untested pager)
`/Users/bing/-Code-/engram/macos/EngramServiceCoreTests/EngramWebUIServerTests.swift:1-243` (subject: `EngramWebUIServer.swift:338-374`)
- What's wrong: The suite covers DB open/close, CSP, classification/redaction, host/origin/token, env flag — but nothing exercises `readMessages`/`sessionPage` pagination (offset/limit clamping, `hasMore`, `nextOffset`, Previous link, "Showing X-Y"). `readMessages` and the pager are private. Commit 91b6b0a8 rewrote `readMessages` to the `limit: nil` raw-count scheme with no direct test.
- Impact: The pager unit-mismatch bugs above shipped uncaught; future windowing changes have no regression guard. Per the repo test-coverage rule, this production behavior change requires tests.
- Fix: Add tests feeding a known mixed stream (interleaved displayable + filtered) through `readMessages` across pages, asserting `messages.count`, `hasMore`, `nextOffset`, the rendered Previous offset, and the Showing range. Expose a testable seam if needed.

**No regression test for re-index classification preservation or Gemini sidecar link persistence**
parent-detection-tiering · test-gap · high
`/Users/bing/-Code-/engram/macos/EngramCoreTests/StartupBackfillTests.swift:338-385`
- What's wrong: `testBackfillSuggestedParentsScoresClaudeParentsAndMarksOrphans` verifies classification immediately after backfill but not that a subsequent re-index (`upsertBatch`) preserves it — exactly where the High clobber bug lives. No test exercises a Gemini sidecar `parentSessionId` landing in `parent_session_id`.
- Impact: Both correctness defects above are silently uncovered; a future change could regress with no failing test.
- Fix: Add (1) classify a codex/gemini session, re-run `upsertBatch` with a content change, assert `agent_role`/`tier` preserved; (2) index a Gemini session with a sidecar `parentSessionId`, assert `parent_session_id` populated.

**No behavioral test for AISettingsSection save/load round-trip**
ui-transcript-workspace-settings · test-gap · medium
`/Users/bing/-Code-/engram/macos/Engram/Views/Settings/AISettingsSection.swift:352-464`
- What's wrong: The only reference is a source-string scan test; there is no `saveAISettings()`/`loadAISettings()` round-trip test, so the custom-generation data-loss path and keychain-vs-JSON fallback have no coverage.
- Impact: Settings persistence (and the data-loss bug) can regress undetected.
- Fix: Extract the settings dictionary transform into a pure testable function over `[String: Any]`; add a round-trip test including the collapse-then-edit case.

**isSkippableFirstUserMessages does not match documented POLYCLI_HEALTH_OK / "inside polycli" probes**
write-indexer · correctness · medium
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:271-317`
- What's wrong: It matches only `["ping"]` plus review/stage probes and AGENTS.md markers — not `Reply with POLYCLI_HEALTH_OK only.` or `You are acting as <provider> inside polycli.`, which `StartupBackfills` (721-722, 1003-1008) and CLAUDE.md both say this function should skip.
- Impact: These probe sessions aren't forced to skip at index time; they rely on later summary backfill. For sources not in `backfillPolycliProviderParents` (notably codex, excluded at 719) a health-ping child can surface as independent until another detector catches it.
- Fix: Add the missing patterns (and the stated `No tools.` probes), reusing the same strings/regexes as `StartupBackfills.isPolycliProviderSummary`. Cover with a parity test.

**Startup orphan scan holds the write gate across per-session file I/O for every session**
write-indexer · concurrency · medium
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/Indexing/StartupComposition.swift:164-255`
- What's wrong: `detectOrphans` reads all sessions then loops `await adapter.isAccessible(locator:)` (file stat / SQLite open+query) plus per-row `writer.write`, all inside the single `initialScanOrphans` gated command. The phase-3 comment claims per-row writes don't hold the gate across the whole scan, but one `performWriteCommand` wraps the entire N-session scan including all I/O.
- Impact: With 100k+ sessions, the scan does one FS/SQLite access per session while continuously holding the write gate (minutes); user writes time out with WriterBusy.
- Fix: Move `isAccessible` probing out of the gated command (ungated read+stat pass, then short gated write batches), or chunk into multiple gated commands.

**Service search() runs blocking pool.read directly on the Swift concurrency executor**
read-facades / concurrency-perf-crosscut · concurrency · medium (merged: same blocking-read pattern, both EngramServiceReadProvider read commands)
`/Users/bing/-Code-/engram/macos/EngramService/Core/EngramServiceReadProvider.swift:442-515` (also general read commands at 442)
- What's wrong: `search(...)` and sibling read commands are `async` but call synchronous `try read { ... }` → `pool.read`, blocking the calling cooperative thread for a hundreds-of-MB FTS MATCH / CJK `LIKE '%...%'` full scan. No `Task.detached`/dedicated-executor hop, unlike the socket I/O which correctly uses `blockingIOQueue`.
- Impact: Up to 32 concurrent clients can each pin a cooperative worker for the scan duration, risking cooperative-pool starvation that delays unrelated async work. GRDB's pool serializes actual access, bounding the blast radius — latent, not a hang.
- Fix: Run the blocking read off the cooperative pool (a dedicated DispatchQueue via `withCheckedThrowingContinuation`, mirroring `readFrameOffCooperativePool`) or adopt `pool.asyncRead`.

**Accept-loop start-gate race leaks client fd + connection-limiter permit on stop(); 32 leaks wedge all connections**
service-ipc · lifecycle · high
`/Users/bing/-Code-/engram/macos/EngramService/IPC/UnixSocketServiceServer.swift:131-140`
- What's wrong: After `accept()` the permit is held. The client task does `await startGate.wait()` then defers fd-close + `connectionLimiter.signal()`. If `stop()` sets `state.descriptor = -1` (159) between accept and the registration `withLock`, `shouldContinue` is false, so line 137 calls `clientTask.cancel()` but never `startGate.release()`. `ClientTaskStartGate.wait()` (283-288) uses a plain `withCheckedContinuation` with no cancellation handler, so the task hangs forever and its defer (close + signal) never runs.
- Impact: On every `stop()`/restart coinciding with a mid-connect client, one fd, one of 32 permits, the task, and a CheckedContinuation leak permanently. After 32 leaked permits the accept loop blocks at `connectionLimiter.wait()` and the service stops accepting any client until the process is killed.
- Fix: Make the start gate cancellation-aware (wrap the continuation in `withTaskCancellationHandler`, resume on cancel), or in the `!shouldContinue` branch do the cleanup directly (`close(client)` + `await connectionLimiter.signal()`) instead of relying on the abandoned task. Add a regression test.

**readExact/writeAll socket timeout is per-syscall, not per-frame**
service-ipc · perf · medium
`/Users/bing/-Code-/engram/macos/Shared/Service/UnixSocketEngramServiceTransport.swift:363-379` (setSocketTimeout 263-283)
- What's wrong: `SO_RCVTIMEO`/`SO_SNDTIMEO` bound each `read()`/`write()` syscall, not the whole frame. A peer sending one byte just before each 10s window keeps each read returning >0, making 1-byte progress for up to `maximumFrameLength` (256KB) iterations on a shared `blockingIOQueue` thread.
- Impact: A slow/buggy same-user client can hold a blocking-IO thread and its permit far beyond the intended 10s bound; up to 32 such clients tie up 32 threads/permits. Bounded by the 256KB cap and same-user access.
- Fix: Track a wall-clock deadline for the entire frame and throw once `now - start > clientTimeoutSeconds`, in addition to the per-syscall timeouts.

**runGit can discard a successful git result via a post-success elapsed-time recheck**
write-indexer · correctness · medium
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/Indexing/RepoDiscovery.swift:253-257`
- What's wrong: After `finished.wait` returns `.success`, `runGit` recomputes wall-clock elapsed and returns nil if it exceeds `timeoutSeconds` — scheduling jitter near the deadline can push the measured time just past it.
- Impact: A git command that completed at the boundary is treated as a timeout and its repo silently skipped from `git_repos` (stale Repos page). Low probability, self-correcting next cycle.
- Fix: Drop the redundant elapsed recheck on the success path; rely on the `finished.wait` result and `terminationStatus == 0`.

**Transcript export filename from 8-char id prefix can collide and silently overwrite**
service-runtime · data-integrity · medium
`/Users/bing/-Code-/engram/macos/EngramService/Core/TranscriptExportService.swift:25-34`
- What's wrong: Output path is `source-<id.prefix(8)>-<date>.<ext>` written atomically. Two distinct sessions sharing source + date + 8-char id prefix collide and the atomic write overwrites without detection. Unparseable `startTime` yields `serviceLocalDate == ""` → trailing-dash filename.
- Impact: A second export silently overwrites the first on prefix+same-day collision; empty-date filenames. No DB data loss, only the exported artifact.
- Fix: Use the full session id (or a longer prefix / content hash) and a stable fallback (e.g. `indexed_at`) when the date is empty.

**Cross-volume move: failed source delete after temp-rename leaves both src and dst, breaking rollback**
project-migration · data-integrity · medium
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/ProjectMove/FsOps.swift:198-206`
- What's wrong: In the EXDEV copy-then-delete path, after `rename(tempDst, dst)` succeeds, `removeItem(src)` is unguarded; if it throws, dst is populated and src still exists. Compensation `SafeMoveDir.run(src: attemptedDst, dst: originalSrc)` then fails preflight `fileExists(dst)` (167) because originalSrc still exists.
- Impact: Cross-volume moves (rare) where source deletion fails (EBUSY/EPERM) leave duplicated data plus a failed rollback. `migration_log` goes failed (no DB corruption); filesystem doubled.
- Fix: If `removeItem(src)` fails after temp-rename, treat the move as succeeded and log residual src for cleanup; or have compensation detect "dst exists AND src exists" and remove the fresh dst.

**Undo staleness check only validates the first affected session with exact cwd equality**
project-migration · correctness · medium
`/Users/bing/-Code-/engram/macos/EngramCoreWrite/ProjectMove/UndoMigration.swift:100-110`
- What's wrong: `prepareReverseRequest` checks only `affectedSessionIds.first` and rejects when `cwd != newPath`, but sessions are matched in `applyMigrationDb` by path-prefix, so an affected session can legitimately have `cwd = <newPath>/sub`.
- Impact: A legitimate current migration can be refused for undo (`UndoStaleError`) when the first affected session is a descendant of newPath. Usable undo blocked; user told to restore from backup.
- Fix: Relax to `cwd == newPath || cwd.hasPrefix(newPath + "/")` matching `applyMigrationDb`'s prefix semantics; check that at least one (not strictly the first) affected session resolves under newPath.

**Launcher blocks the main thread up to 2s on every restart and on quit (Thread.sleep poll on @MainActor)**
app-core · concurrency · high
`/Users/bing/-Code-/engram/macos/Engram/Core/EngramServiceLauncher.swift:168-192`
- What's wrong: `stopProcessOnly()` (on `@MainActor`) calls `Self.waitForExit(process, timeout: 2.0)`, whose body is `while process.isRunning, Date() < deadline { Thread.sleep(0.02) }` synchronously on the main thread. Invoked from the health-monitor restart path (138-140) and from `applicationWillTerminate` (`App.swift:206`).
- Impact: Every restart (probe failure/crash/socket loss) or quit freezes the SwiftUI main run loop up to 2s — a guaranteed up-to-2s beachball on quit if the helper doesn't exit instantly.
- Fix: Move terminate+wait off the main actor (await `process.waitUntilExit()` on a detached executor with a timeout race, or use `terminationHandler`). Don't `Thread.sleep` on the main actor.

**index_error detail silently dropped: service sends key "error", app decoder only has "message"**
app-core · correctness · high
`/Users/bing/-Code-/engram/macos/Engram/App.swift:248-256`
- What's wrong: `applyServiceEvent` reads `event.message ?? "indexing failed"`, but the service emits the failure under key `error` (`ServiceIndexErrorEvent`, `EngramServiceRunner.swift:544-547`); `EngramServiceEvent` CodingKeys (`EngramServiceModels.swift:131-145`) have `message` but no `error`, so `event.message` is always nil and the surfaced text is always the generic fallback.
- Impact: Indexing failures lose their cause string (e.g. "missing sessions table"); the degraded status is non-actionable — defeating the OBS-O2 routing's stated purpose. The regression test only asserts the static prefix, hiding the gap.
- Fix: Add `case error` to `EngramServiceEvent`, have `applyServiceEvent` use it, and update the test to assert the concrete detail.

**agentComm (user-injected) messages classified as assistant-side toolCall/toolResult, skewing chip counts**
models-classifiers · correctness · high
`/Users/bing/-Code-/engram/macos/Engram/Models/MessageTypeClassifier.swift:98-105`
- What's wrong: `.agentComm` is always a user-role message (skill invocations, `<command-name>`, etc.), but `classify` maps it to `.toolResult`/`.toolCall` before the `role == "user"` check (line 106). `IndexedMessage.build` then increments the tool counters for user-role injections.
- Impact: Tool Call/Result chip counts include user-side command injections; `navigateType` jumps to user-injection rows when stepping through Tool Call matches. UX correctness, not data loss.
- Fix: Introduce a dedicated MessageType for agent-comm, or classify it as `.system` so it is governed by `showAgentComm` and excluded from tool chip counts.

**errorPatterns substring match misclassifies ordinary assistant prose as .error**
models-classifiers · correctness · medium
`/Users/bing/-Code-/engram/macos/Engram/Models/MessageTypeClassifier.swift:77-83`
- What's wrong: `containsErrorPattern` scans the first 1000 chars for raw substrings `"error:"`, `"ERROR"`, `"FAILED"` with no word boundary, so "The error: case is handled by…" or "ERRORLEVEL" classify as `.error` (classify 128-130).
- Impact: Plain assistant explanations get colored/counted as errors; `.error` defaults hidden in `defaultTypeVisibility`, so a legitimate reply can be hidden by default. Common in coding transcripts.
- Fix: Anchor markers to line starts or use stricter tokens (drop the bare substrings). Add regression tests for prose containing "error".

**hasSignificantCodeBlock miscounts code length when fences are unbalanced**
models-classifiers · correctness · medium
`/Users/bing/-Code-/engram/macos/Engram/Models/MessageTypeClassifier.swift:171-179`
- What's wrong: `components(separatedBy: "```")` sums odd-offset segments as code; with an odd fence count the trailing prose after the last fence is counted as code.
- Impact: Occasional misclassification of assistant messages as `.code` (defaults hidden) or vice versa. Heuristic-level, no crash; limited to assistant messages.
- Fix: Guard on a balanced (odd component-count) fence count before summing, or ignore the final segment when fence count is odd. Add an unclosed-code-block test.

**ExpandableSessionCard.loadMoreChildren can append duplicate children on rapid taps**
ui-pages · concurrency · medium
`/Users/bing/-Code-/engram/macos/Engram/Components/ExpandableSessionCard.swift:226-239`
- What's wrong: `loadMoreChildren` captures `currentCount` then dispatches a detached fetch with no in-flight guard; two quick taps both capture the same offset, fetch the same rows, and append duplicates. The ForEach keys on `Session.id`, triggering ID-collision warnings/duplicate rows. The `onChange` handler (159-167) can reset `children=[]` mid-flight with no generation guard.
- Impact: Double-tapping "show more" duplicates rows and emits SwiftUI ID-collision warnings; a count change mid-load can briefly show stale children. Visible glitch, no crash.
- Fix: Guard re-entry (a loading flag or stored cancellable Task) and de-dup on append; add a generation guard for the reset path.

**SessionDetailView reads db.isFavorite synchronously on the main actor**
concurrency-perf-crosscut · perf · high
`/Users/bing/-Code-/engram/macos/Engram/Views/SessionDetailView.swift:292`
- What's wrong: The `.task(id:)` closure runs on MainActor; `db.isFavorite` (`Database.swift:576`) is a synchronous `pool.read`. Every other DB access in this view is correctly detached — this one is not.
- Impact: A synchronous single-row read on the main thread each time a detail opens; on a cold pool it forces the synchronous pool open on the main thread. Small but on a hot navigation path.
- Fix: Fold the `isFavorite` read into a `Task.detached` (alongside `loadParentInfo`'s fetch) and assign back via MainActor.

**Menu-bar badge refresh triggers a full recursive live-session filesystem scan ~every 5s**
concurrency-perf-crosscut · perf · medium
`/Users/bing/-Code-/engram/macos/Engram/MenuBarController.swift:307-376`
- What's wrong: `observeTotalSessions()` re-registers on every `totalSessions`/`todayParentSessions` change and calls `updateBadge()` → `serviceClient.liveSessions()` → `scanLiveSessions` (recursive `FileManager.enumerator` over all session-source dirs). The status stream updates counts every 5s, so the observation re-scans on that cadence.
- Impact: A recursive enumeration of all source dirs runs ~every 5s for the app's lifetime even when windows are closed. Bounded (capped at 100, server-side, off-main) — steady background I/O, not a hang.
- Fix: Throttle/coalesce `updateBadge()` (re-scan only when the badge is visible, or rate-limit), or cache the scan result with a short TTL service-side.

**GitRepo allocates a fresh ISO8601DateFormatter on every isActive access**
models-classifiers · perf · high
`/Users/bing/-Code-/engram/macos/Engram/Models/GitRepo.swift:30-34`
- What's wrong: `var isActive` constructs `ISO8601DateFormatter()` per call; `isActive` is invoked per-row during repo-list rendering.
- Impact: Per-row formatter allocation; noticeable only with many repos rendered/re-rendered. No correctness issue (result is correct).
- Fix: Hoist to `private static let isoFormatter = ISO8601DateFormatter()` and reuse.

**sparklineData mixes SQLite UTC date() with Swift local DateFormatter/Calendar**
read-facades · correctness · high
`/Users/bing/-Code-/engram/macos/Engram/Core/Database.swift:940-960`
- What's wrong: SQL `date(start_time)` (no `'localtime'`) returns a UTC calendar date, while `fmt` (DateFormatter, default device-local timezone) and `today = Calendar.current.startOfDay` are local. `daysAgo` compares a UTC-derived string parsed as local against local today. `start_time` is TEXT ISO-8601 so `date()` yields UTC.
- Impact: For sessions in the UTC/local offset window (late evening in US, around midnight in positive offsets), the 7-day repo sparkline buckets on the wrong day, double-counts, or drops a day. Wrong visualization, not data loss.
- Fix: Make both sides agree — `date(start_time,'localtime')` + `fmt.timeZone = .current`, or keep SQL UTC and set `fmt.timeZone = UTC` plus a UTC calendar.

**Today Workbench follow-up discovery can surface non-top-level sessions** — *(merged into the Today Follow-ups finding above; see `HomeView.swift:497-511`)*

**observeLogs is dead code and would block the main thread via .immediate scheduling if wired up**
read-facades · dead-code · high
`/Users/bing/-Code-/engram/macos/Engram/Core/Database.swift:1246-1296`
- What's wrong: `observeLogs(...)` calls `.start(in: pool, scheduling: .immediate, ...)`; no callers exist anywhere in `macos/`. With `.immediate`, GRDB delivers the initial value synchronously on the calling thread — a MainActor caller would run the full `logs` query (DISTINCT module scan + filtered fetch) on the main thread.
- Impact: No runtime impact today (unused). Latent main-thread-stall trap for the next caller; unused read-facade surface.
- Fix: Remove `observeLogs`, or if kept, use `.async(onQueue:)` and document off-main-actor invocation.

**SchemaManifest/SchemaIntrospection are shipped public API with no runtime consumers; validated only by a Node-shelling test that contradicts the no-Node-gate rule**
read-facades · test-gap · high
`/Users/bing/-Code-/engram/macos/EngramCoreRead/Database/Schema/SchemaManifest.swift:3-49`
- What's wrong: The manifest and `SchemaIntrospection.snapshot` ship in `EngramCoreRead` but have zero non-test references; the only product-relevant validation, `SchemaCompatibilityTests.testNodeReferenceSchemaEmissionCoversManifestBaseTables` (`SchemaCompatibilityTests.swift:32-64`), spawns `node_modules/.bin/tsx scripts/db/emit-current-schema.ts` — reintroducing a Node schema-compatibility gate CLAUDE.md says was deleted 2026-05-08 and must not return. (No active drift bug; manifest currently matches.)
- Impact: The Swift suite gains a hidden Node-toolchain dependency that fails on a Swift-only box for environmental reasons; schema drift would be pinned to the deprecated TS reference rather than the Swift writer.
- Fix: Replace the Node subprocess with a pure-Swift check (open a migrated DB, `SchemaIntrospection.snapshot`, assert `baseTables.isSubset(of:)` as `MigrationRunnerTests` does). Either delete the manifest/introspection types or wire them into a startup self-check.

**databaseGeneration decoded from the response envelope but never consumed in the app read path**
app-core · dead-code · medium
`/Users/bing/-Code-/engram/macos/Shared/Service/EngramServiceClient.swift:215-220`
- What's wrong: `EngramServiceResponseEnvelope.success` carries `databaseGeneration` (decoded at `EngramServiceModels.swift:269`) but `command` discards it; no app-side consumer exists (only the model and EngramMCP tests).
- Impact: No active bug (WAL reads are fresh), but the cache-coherence signal is wired nowhere; a future feature assuming the app honors it would be silently unimplemented.
- Fix: Either consume `databaseGeneration` (invalidate a future read-model cache / trigger refresh) or document it as MCP-only and drop the unused app-side decode.

**ToolResultView.lineCount is dead code**
ui-transcript-workspace-settings · dead-code · high
`/Users/bing/-Code-/engram/macos/Engram/Views/Transcript/ToolResultView.swift:8-10`
- What's wrong: `private var lineCount` is defined but never referenced; the init (line 27) recomputes the same expression inline.
- Impact: None behavioral; minor redundancy. Pre-existing (flagged per repo policy, not deleted).
- Fix: Remove the unused property, or have init reuse it.

**TerminalLauncher.appleScriptCommandLine is dead in production (test-only helper)**
recent-churn-regression · dead-code · high
`/Users/bing/-Code-/engram/macos/Engram/Views/Resume/TerminalLauncher.swift:32-34`
- What's wrong: The 91b6b0a8 refactor added `appleScriptCommandLine(...)`, but `launch()` (38) inlines `escapeForAppleScript(shellCommandLine(...))` instead. The only reference is `EngramCLIResumeCommandTests.swift:56`.
- Impact: An orphaned helper that exists only to be tested; no behavioral effect.
- Fix: Have `launch()` call `appleScriptCommandLine` (removing the inline duplication), or drop the helper and test the composition directly.

## Recommended fix order

1. **`SessionSnapshotWriter.swift:216-217` — re-index classification clobber.** Highest impact × highest frequency: the single most consequential data-integrity defect, self-perpetuating until a detection-version bump. Add the `COALESCE`/`CASE` guard and the re-index-preservation test in the same change.
2. **Project-move encoders — `EncodeClaudeCodeDir.swift:16-18` and `Sources.swift:83-87`.** Both silently orphan session directories with no error on a routine user action (dotted cwd; mixed-case/underscore Gemini projects). Fix the encoders and update the locked-in `SessionSourcesTests:65-66` expectation together.
3. **`UnixSocketServiceServer.swift:131-140` — start-gate race permit leak.** Resource exhaustion that escalates to a total IPC outage (all app/MCP calls time out) after 32 restart-coincident leaks. Make the gate cancellation-aware and add the regression test.
4. **Web UI transcript pager — `EngramWebUIServer.swift:267-272, 277, 351-374`.** A single root cause (raw vs displayed message-count units) produces broken Previous navigation, wrong range labels, and O(N²) full-file re-parsing. Fix the unit handling and pass a real `limit`, then add the pagination tests (closes the test-gap finding too).
5. **`SessionsPageView.swift:104-111` — missing `topLevelOnly`.** User-visible duplicate rows on the main Sessions page once parent-detection runs (the common case). One-line fix; then apply the same filter to ProjectsView and Today Follow-ups.
6. **`EngramServiceLauncher.swift:168-192` — main-thread Thread.sleep on restart/quit.** Guaranteed up-to-2s beachball on quit and during restarts; move terminate+wait off the main actor.
7. **`PopoverView.swift:240` + `SessionDetailView.swift:313-326,292` — main-thread DB/CPU on hot paths.** The frequently-shown popover and large-session open both hitch the UI; fold the reads/classification into the existing detached blocks.
8. **`AISettingsSection.swift:377-392` — silent settings data loss.** Low blast radius but irrecoverable user data loss; decouple persistence from the disclosure expansion flag and add the round-trip test.
9. **`SwiftIndexer.swift:197-244` — Gemini sidecar link dead.** A documented deterministic feature that never lands; persist `parentSessionId` and add the test.
10. **`SessionDetailView.swift:60-66` — dead "Show System Prompts" toggle** and **`App.swift:248-256` — dropped index_error detail.** Two user-facing controls/diagnostics that silently do nothing; both are small, isolated fixes that restore advertised behavior.

## Coverage & caveats

**Reviewed (16 subsystems):** parent-detection & tiering; project migration; UI transcript/workspace/settings; service runtime; write path & indexer; web UI server; app core & lifecycle; UI pages (Home/Sessions/Projects/Timeline); models & message classifiers; read facades; service IPC (Unix socket transport); concurrency/perf cross-cut; adapters (Claude Code, Codex, Gemini CLI, VsCode, OpenCode, Antigravity); read provider; recent-churn regression (Today Workbench rewrite, commits f108d4cd/f16333b8/91b6b0a8); schema/migration manifest.

**Explicitly excluded:** Security (per scope — auth, capability tokens, peer-UID checks, CORS/Host allowlists, path normalization were not assessed). The TypeScript reference surface under `src/` (dev/reference/fixture/regression material, not the shipped runtime) was out of scope except where Swift tests have a latent dependency on it (the `SchemaCompatibilityTests` Node-shelling finding).

**Needs deeper follow-up:**
- **Re-index/classification persistence semantics** beyond the single clobber: confirm whether other writer-owned columns (suggestion state, link_source='manual') survive re-index, and whether the merge path (lines 92-94, 112) has analogous overwrite bugs not surfaced here.
- **The `runGit` hang (RepoDiscovery.swift:247-252)** was filed at low confidence because the failure requires a git child ignoring SIGTERM; reproduce against a real wedged-FS/network-mount scenario before deciding between SIGKILL escalation and a bounded `ioGroup.wait()`.
- **Cooperative-pool starvation under load** (service `search`/read commands, transport trickle-timeout) is latent and bounded by GRDB's internal serialization and same-user access; load-test with concurrent heavy CJK `LIKE` scans to confirm whether the executor hop is worth the change.
- **OpenCode adapter message-count** was referenced as the "stronger analogous version" of the Gemini count defect but was reviewed separately and not included in this set — confirm it is tracked in its own finding before closeout.
- **Cross-volume project move** (`FsOps.swift:198-206`) rollback was reasoned about but not exercised on a real two-volume setup; validate the compensation path with an actual EXDEV move before shipping a fix.


---

# Gap-fill addendum (schema/migrations + MCP tools)

*Re-run of the two subsystems whose reviewers failed to emit structured output in the main pass; same adversarial verification.*

## Gap-fill addendum — schema/migrations + MCP tools

### Medium

**Session deletion (dedup + cascade) orphans `sessions_fts` content — no FK/trigger cleanup**
write-schema-migrations · data-integrity · high
`macos/EngramCoreWrite/Indexing/StartupBackfills.swift:434-443` (deduplicateFilePaths); cf. `macos/EngramCoreWrite/Database/EngramMigrations.swift:62-78` (trigger)
- What's wrong: `deduplicateFilePaths` runs `DELETE FROM sessions WHERE rowid NOT IN (...)`, but neither FK `ON DELETE CASCADE` nor `trg_sessions_parent_cascade` touches the `sessions_fts` virtual table, and the post-pass `optimizeFts()` (line 235) only runs FTS5 'optimize' (b-tree compaction), which does not remove orphaned rows. The maintainers know FTS needs manual cleanup — `downgradeSubagentTiers` explicitly deletes from `sessions_fts` (line 588-593) — but dedup has no equivalent.
- Impact: Orphaned FTS content accumulates indefinitely per dedup-deleted/merged session, bloating the index and slowing keyword search. Phantom hits are avoided today only via the search `INNER JOIN sessions_fts f JOIN sessions s` (EngramServiceReadProvider.swift:449-450); if a `session_id` is re-ingested as skip-tier (no FTS reindex), the stale orphan would re-attach and surface as an incorrect snippet.
- Fix: After `DELETE FROM sessions` in deduplicateFilePaths (and any direct session-delete path), delete matching `sessions_fts` rows in the same transaction, or run `DELETE FROM sessions_fts WHERE session_id NOT IN (SELECT id FROM sessions)` as a reconcile step. Same applies to session_embeddings/vec_sessions if they ever hold data.

**`live_sessions` returns real scan data, contradicting its registered "unavailable" description**
mcp-tools · api · high
`macos/EngramMCP/Core/MCPToolRegistry.swift:224-231, 817-818`
- What's wrong: The tool description states "Live session monitoring is not available in MCP mode; returns an explicit unavailable result," but the handler runs `.toolSuccess(MCPLiveSessionScanner.scan(...))`, enumerating ~/.codex, ~/.claude, ~/.gemini, etc. and returning up to 100 real sessions. The golden test sees `{sessions:[],count:0}` only because HOME points at an empty temp dir, so the contradiction is never exercised.
- Impact: Clients/LLMs read the schema description to decide whether to call the tool; the description asserts unavailability while the tool returns live filesystem-derived data. Output shape also differs from an unavailable/isError result, so callers branching on the documented contract mishandle the response.
- Fix: Pick one contract — either make `live_sessions` return an explicit unavailable result (matching the description), or update the description and the misleading golden fixture (`live_sessions.unavailable.json`) to reflect that it performs a live home-directory scan, and document the returned shape.

### Low

**`get_context` "Cost today" filters by `computed_at` (index time) instead of session activity time**
mcp-tools · data-integrity · high
`macos/EngramMCP/Core/MCPDatabase.swift:792-805, 761-767`
- What's wrong: `contextEnvironmentSection` computes "Cost today" via `totalCostBetween(start, end)`, whose SQL filters `WHERE computed_at >= ? AND computed_at < ?`. But `computed_at` is set to `datetime('now')` when the cost row is written (SessionSnapshotWriter.swift:281), i.e. indexing time, not session activity time. Every other cost query in the file correctly filters on `s.start_time` (getCosts 213-220, totalCostSince 696-710).
- Impact: After a full re-index or first-run backfill, all historical cost rows get `computed_at = today`, so the environment block reports the entire historical spend as "Cost today: $X". Conversely, costs computed on a prior day for sessions that ran today are excluded. The figure is unreliable for the summary the LLM consumes.
- Fix: Filter the today-cost window on the session's activity time, e.g. JOIN sessions and use `s.start_time >= ? AND s.start_time < ?` (consistent with totalCostSince/getCosts), rather than `session_costs.computed_at`.

**Argument validation ignores array `items.enum` and the schema `required` array**
mcp-tools · api · high
`macos/EngramMCP/Core/MCPToolRegistry.swift:1159-1201`
- What's wrong: `validateArguments` only checks additionalProperties and top-level per-property type/enum; it never reads `schema["required"]`, and `validateArgument` only inspects a property's own `enum`, never `items.enum`. For get_session.roles (`type:array`, `items.enum:[user,assistant]`, lines 406-416), `roles:["banana"]` passes. Missing required args slip past too — caught later only incidentally because every required field is a string handled by requiredString.
- Impact: Invalid enum members inside array arguments are accepted instead of rejected with a clear `must be one of` error, silently producing degraded/empty results. Missing-required handling is order-dependent: a non-dry-run delete_insight with empty id returns serviceUnavailable (if socket down) rather than "id is required" — an inconsistent error category.
- Fix: In validateArgument, when type==array and the schema has `items.enum`, validate each element against it; and enforce the top-level `required` array in validateArguments before dispatch so missing/invalid args fail with a consistent invalidArguments error independent of service reachability.

**`get_session` with empty `roles:[]` silently returns zero messages**
mcp-tools · correctness · medium
`macos/EngramMCP/Core/MCPTranscriptTools.swift:14-20`
- What's wrong: `readMessages(...).filter { roles == nil || roles!.contains($0.role) }`. When the caller passes `roles: []` (valid per schema, items.enum not enforced), `roles` is non-nil and `[].contains(role)` is always false, so every message is filtered out. The result is an empty `messages` array with `totalPages = max(1, ...) = 1`, indistinguishable from a genuinely empty session.
- Impact: A client sending `roles:[]` (constructed dynamically, or expecting "empty means all") gets a silently empty transcript page rather than an error or the full transcript, with no warning. A quiet correctness trap.
- Fix: Treat an empty/whitespace-only roles array as "no filter" (equivalent to nil), or reject empty roles with an invalidArguments error.

**`VectorRebuildPolicy` is never wired into the production migration path**
write-schema-migrations · dead-code · medium
`macos/EngramCoreWrite/Database/VectorRebuildPolicy.swift:5-44`
- What's wrong: `EngramMigrationRunner.migrate` (EngramMigrationRunner.swift:5-9) calls only createOrUpdateBaseSchema, FTSRebuildPolicy.apply, and writeSchemaMetadata. `VectorRebuildPolicy.apply` is referenced only from VectorRebuildPolicyTests; no production caller. The dimension/model-mismatch rebuild and the vec_dimension/vec_model metadata it writes never run at runtime.
- Impact: If/when embeddings are enabled, a dimension or model change will NOT trigger the documented automatic rebuild (CLAUDE.md "Model tracking: dimension/model changes trigger automatic rebuild") because the policy is unreachable — risking mixing vectors from different models in one space. Currently inert because sqlite-vec is not implemented.
- Fix: Either wire `VectorRebuildPolicy.apply` into `EngramMigrationRunner.migrate` (with the active model/dimension) when vector support lands, or remove it to avoid the false impression that vector rebuild-on-mismatch is active.

**`swift_aux_schema_version` is written but never used to gate aux migrations**
write-schema-migrations · perf · high
`macos/EngramCoreWrite/Database/EngramMigrations.swift:366-372` (write); `355-364` (migrateAuxTablesToV2)
- What's wrong: `migrateAuxTablesToV2` writes metadata key `swift_aux_schema_version='2'` but it is read nowhere in production (only MigrationRunnerTests.swift:207). Every startup therefore runs all 10 aux `migrate*ToV2` functions, each issuing `PRAGMA table_info(...)` introspection and recomputing its needs-migration guard, even on an already-v2 schema.
- Impact: Redundant PRAGMA/introspection work on every service startup. Correctness is preserved by the per-table column-shape guards (idempotent), so this is a startup-cost/clarity issue, not a data bug.
- Fix: Short-circuit `migrateAuxTablesToV2` when the stored `swift_aux_schema_version` already equals `auxSchemaVersion`, or drop the metadata write if no gating is intended.
