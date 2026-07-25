# Design Doc: Index Claude Code workflow-nested subagents

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog row 32 (F12 first
  bullet); composes with the accepted `docs/codex-native-parentage-design-2026-07.md`
  (route adjudication). Prior art: Agent Sessions
  `as-main/AgentSessions/Models/ClaudeSessionParser.swift:1178-1213`, commit
  `77498434`.

All code citations are at HEAD `23dca547`. Concurrent branches
(`feat/adapter-format-drift`) have already drifted these line numbers by a few
lines inside `ClaudeCodeAdapter.swift`; that is expected. Corpus counts were
measured on 2026-07-24 on one Codex/Claude-heavy machine (N=1) and will drift.

## Problem

Claude Code Workflow runs write subagent transcripts one directory deeper than
the adapter looks. The real layout is:

```
{projectsRoot}/{project}/{sessionUUID}/subagents/workflows/wf_{runid}/agent-{agentid}.jsonl
{projectsRoot}/{project}/{sessionUUID}/subagents/workflows/wf_{runid}/agent-{agentid}.meta.json
{projectsRoot}/{project}/{sessionUUID}/subagents/workflows/wf_{runid}/journal.jsonl
```

`ClaudeCodeAdapter.listSessionLocators` enumerates only the **direct** `.jsonl`
children of each `subagents/` directory (`ClaudeCodeAdapter.swift:112-119`). It
never descends into `subagents/workflows/wf_*/`, so every workflow-run agent
transcript is invisible to the indexer.

Measured on this machine: **30,460 net-new** `agent-*.jsonl` workflow
transcripts across 314 workflow parent dirs and 1,144 `wf_*` run dirs, versus
6,241 direct `subagents/*.jsonl` already discovered. (The mirror's headline
"~31,400 transcripts" counts the 1,143 `journal.jsonl` control files too;
corrected here to **30,460 real transcripts**.) One session's own run has
produced 100+ agents; the largest single `wf_` dir holds 577 agent files.

The consequence is a parent-child completeness gap: a Claude Code session that
fanned out to dozens of workflow subagents shows none of them under its card,
and the corpus accounting undercounts Claude subagent activity by ~5x.

## Goals / Non-goals

Goals:

- Discover and index `subagents/workflows/wf_*/agent-*.jsonl` so each workflow
  agent becomes a `tier='skip'` session row linked to its parent via
  `parent_session_id` at index time.
- Preserve every existing invariant: workflow agents stay `skip`, never appear
  in keyword/semantic search, never appear in top-level session lists, and are
  reachable only through the parent.
- Add a Swift-only regression test that fails today (files not discovered) and
  passes after the descent lands.

Non-goals:

- Reading the `.meta.json` role sidecars (`agentType`, `spawnDepth`). Justified
  under Alternatives — near-zero signal at high scan cost.
- Any new schema column, DTO field, service command, or read method. The
  design is adapter-listing-only.
- A workflow badge / fan-out marker on the parent card (the Agent Sessions
  prior art at `ClaudeSessionParser.swift:1178-1213`). That is a separate
  UI/schema change; this row is index-only. Filed as an open question.
- Indexing `journal.jsonl` (control records, not transcripts) or the
  session-level `workflows/` dir (holds `wf_*.json` orchestration state).

## Current state

`ClaudeCodeAdapter.listSessionLocators(projectsRoot:)`
(`ClaudeCodeAdapter.swift:99-123`) walks each project dir, lists direct `.jsonl`
files, then for every non-`.jsonl` entry checks for a `subagents/`
subdirectory and lists that directory's **direct** `.jsonl` children only
(`:112-119`). There is no recursion; `subagents/workflows/` is a directory, so
it is silently skipped.

Everything downstream of listing already handles the workflow path shape
unchanged — this is what makes a listing-only fix sufficient:

- **agentRole**: `ClaudeCodeAdapter.swift:334` sets `agentRole="subagent"` for
  any locator containing `/subagents/`. True for workflow paths.
- **parentSessionId**: `ClaudeCodeAdapter.swift:340` calls `parentSessionId(from:)`
  (`:869-877`), which splits on `/`, finds the `subagents` component, and
  returns the component immediately before it. For
  `.../{UUID}/subagents/workflows/wf_x/agent-y.jsonl` it returns `{UUID}` (the
  parent session) — the extra `workflows/wf_x/` nesting does not affect it.
  Verified: the transcript's own `sessionId` field equals the path-derived
  parent.
- **Row id**: `id(locator:)` (`:363-366`) returns `agentId` (not `sessionId`)
  for any `/subagents/` path, so each workflow agent indexes under its own
  distinct id; no collision with the parent or between siblings.
- **Tier**: `SessionTier.compute` returns `.skip` at two independent checks —
  `agentRole != nil` (`SessionTier.swift:12`) and
  `filePath.contains("/subagents/")` (`:13`). `SwiftIndexer.isProvableSkip`
  mirrors both (`SwiftIndexer.swift:673-676`). Skip is set in the same write
  that sets `parent_session_id`, so there is **no NULL-tier visibility window**.
- **Write path**: `SessionSnapshotWriter.upsert` writes the adapter-provided
  `parent_session_id` with `link_source='path'`; on re-index the ON CONFLICT DO
  UPDATE CASE (`SessionSnapshotWriter.swift:374-382`) preserves
  `link_source='manual'` (the INSERT-time `CASE WHEN ? IS NOT NULL THEN 'path'`
  is at `:276`).
- **Search exclusion**: `SessionSemanticSearchPolicy.searchableTierSQL`
  (`macos/Shared/EngramCore/AI/SessionSemanticSearchPolicy.swift:29-30`) =
  `"(s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))"`, applied at
  `EngramServiceReadProvider.swift:611,680,920`.
- **Top-level list exclusion**: `EngramServiceCommandHandler.swift:2606` filters
  `parent_session_id IS NULL AND (s.tier IS NULL OR s.tier != 'skip')`.

Corrections to the mirror / brief, recorded explicitly:

1. **The `backfillParentLinks` regex does NOT match the workflow path.**
   `StartupBackfills.swift:1267` uses `#"/([^/]+)/subagents/[^/]+\.jsonl$"#`,
   which requires exactly one component between `/subagents/` and `.jsonl`. A
   workflow path has three (`workflows/wf_x/agent-y.jsonl`), so it returns no
   match. The brief left this open; it is decisive — a path-based backfill
   fallback would silently miss these rows.
2. **The transcript count is 30,460, not ~31,400** (the mirror included the
   1,143 `journal.jsonl` control files).
3. **The `.meta.json` sidecar carries no parent pointer** — only
   `{"agentType": ..., "spawnDepth": N?}`. `agentType` is 99% the generic
   `"workflow-subagent"` (2976/3000 sampled).

## Proposed design

The minimum change is a scoped two-level descent inside the existing
`subagents/` branch of `listSessionLocators` (`ClaudeCodeAdapter.swift:112-119`).
No parse-code change, no schema change, no backfill, no DTO, no read method.

### Adapter listing descent

After the existing direct-child loop over `subagents/`, add: if
`subagents/workflows/` is a directory, enumerate each `wf_*` subdirectory and
append its `agent-*.jsonl` files. Two scoping rules are load-bearing:

- **Filter to the `agent-` filename prefix**, not blanket `*.jsonl`. This
  excludes the 1,143 `journal.jsonl` control files, whose first record is
  `{"type":"started",...}` with no user/assistant messages —
  `aggregateSessionInfo` would yield `messageCount == 0` →
  `sessionInfo` returns `.failure(.noVisibleMessages)` (`:310`), a harmless but
  wasteful parse.
- **Descend only `subagents/workflows/`**, never the sibling session-level
  `workflows/` dir (which holds `wf_*.json` orchestration state, not
  transcripts).

No double-listing risk: the existing loop filters direct children by
`pathExtension == "jsonl"`, and `workflows/` is a directory with no extension,
so it is already skipped by the direct loop; the descent handles it additively.

The existing `directChildren` helper is single-level; a
`recursiveFiles(under:matching:)` helper already exists in
`JSONLAdapterSupport` (`CodexAdapter.swift:50-63`) but a blanket recursive walk
would re-collect the direct subagent `.jsonl` and the `journal.jsonl` files, so
the explicit two-level descent (`workflows/` → each `wf_*/` →
`agent-*.jsonl`) is preferred for scope precision.

### Why the adapter route here, when codex row 22 rejected it

`docs/codex-native-parentage-design-2026-07.md:247-255` rejected the adapter
route for Codex native parentage for three reasons. Adjudicated point by point;
all three invert or dissolve for workflow files because these are **NEW,
never-indexed discoveries**, not already-indexed rows:

1. *"It never runs on the existing rollouts (both skip layers hold)."* — For
   Codex, the files were already indexed, so an adapter change never re-parses
   them. Workflow agent files have **no `file_index_state` row** (they were
   never listed), so on first discovery the adapter parses them fresh. A
   backfill cannot link a row that was never inserted; the adapter is the only
   thing that will run on them. **Inverts.**
2. *"It writes through the unvalidated upsert CASE, bypassing
   validateParentLink."* — `validateParentLink`
   (`StartupBackfills.swift:1701-1718`) guards advisory/heuristic links.
   Workflow parentage is deterministic (path-derived, exactly as direct
   subagents already are via `link_source='path'`), so bypassing heuristic
   validation is correct, not a regression. **Does not apply.**
3. *"It leaves `suggested_parent_id` untouched."* — Desired: workflow agents get
   a confirmed `parent_session_id`, never a `suggested_parent_id`. **Not a
   cost.**

Conclusion: the adapter route is correct here for the same reason the backfill
route was correct for Codex — each picks the layer that actually runs on the
target rows.

### Implementation slices (row 32)

Slices A and B **land together in one PR** — slice A is a production-path
behavior change, so per the test-coverage invariant (CLAUDE.md: behavior
changes in production paths require corresponding tests) it is not independently
landable without slice B's repro. Slice C is a separately-landable optional
follow-up.

- **Slice A — Descent (required, ships with B).** Extend `listSessionLocators`
  at `ClaudeCodeAdapter.swift:112-119`: descend `subagents/workflows/wf_*/` and
  append `agent-*.jsonl`. ~10 lines. No other file. Done-when: slice B's repro
  passes.
- **Slice B — Regression test (required, ships with A).** Extend
  `macos/EngramCoreTests/Adapters/ClaudeCodeMultiRootAdapterTests.swift`. Add a
  `workflowRun: String?` parameter to the existing `makeTranscript` helper —
  real signature `makeTranscript(root:project:name:model:subagentSession:)` with
  a defaulted `model: String = "claude-sonnet-4"` between `name` and
  `subagentSession` (`:335-373`) — so it can build
  `{project}/{UUID}/subagents/workflows/{wf}/agent-{name}.jsonl`. The workflow
  fixture must set **both** `subagentSession` (the `{UUID}`, which supplies the
  parent dir name AND the non-empty `agentId` via the helper's
  `subagentSession == nil ? "" : "agent-\(name)"` ternary at `:354,366`) and
  the new `workflowRun` (the `wf_*` nesting); otherwise `agentId` is empty and
  `id(locator:)` falls back to `sessionId`, so A2's `id == agentId` assertion
  fails. Add `testClaudeWorkflowSubagentsAreDiscovered_repro()` asserting
  `listSessionLocators()` includes the workflow path and `parseSessionInfo`
  yields `agentRole == "subagent"` and `parentSessionId == {UUID}`. Fails today
  (file not discovered), passes after slice A.
- **Slice C — Backfill regex widening (optional, defense-in-depth).** Widen
  `StartupBackfills.swift:1267` to
  `#"/([^/]+)/subagents/(?:workflows/[^/]+/)?[^/]+\.jsonl$"#` so a workflow row
  whose `parent_session_id` is ever NULL (e.g. inserted by a path that skipped
  the adapter) can be re-linked by the safety net, at parity with direct
  subagents. Not required — slice A sets the parent inline at every index pass —
  and it touches invariant #9 (see below), so land it only if the safety-net
  parity is wanted.

### Acceptance criteria (falsifiable)

- A1: With a fixture tree containing
  `{UUID}/subagents/workflows/wf_x/agent-y.jsonl`,
  `ClaudeCodeAdapter.listSessionLocators()` returns that path. (Fails at
  `23dca547`.)
- A2: `parseSessionInfo` on that locator returns `.success` with
  `agentRole == "subagent"`, `parentSessionId == {UUID}`, and the row id equal
  to the file's `agentId`, not `{UUID}`.
- A3: A `journal.jsonl` placed in the same `wf_x/` dir is **not** returned by
  `listSessionLocators()`.
- A4: A `wf_a.json` file placed in the session-level `workflows/` dir (sibling
  of `subagents/`) is **not** returned.
- A5: `SessionTier.compute` on the workflow locator returns `.skip` (already
  true; guard against regression).
- A6 (slice C only): the widened regex matches
  `.../subagents/workflows/wf_x/agent-y.jsonl` and still matches
  `.../subagents/direct.jsonl`.

## Invariants affected

- **#2 Subagent Sessions Stay Skip** (`docs/invariants.md:12-17`) — Preserved.
  Workflow agents are `skip` at index time via two checks
  (`SessionTier.swift:12-13`); no code here upgrades their tier. Enforcement
  point unchanged.
- **#3 Tier Visibility** (`docs/invariants.md:19-24`) — Preserved. `skip` is
  excluded from search (`searchableTierSQL`) and from top-level lists
  (`EngramServiceCommandHandler.swift:2606`); this change adds `skip` rows only.
- **#10 Manual Unlink Is Respected** (`docs/invariants.md:68-73`) — Preserved.
  The ON CONFLICT DO UPDATE CASE (`SessionSnapshotWriter.swift:374-382`)
  preserves `link_source='manual'` and its `parent_session_id`; the adapter
  never overwrites it.
- **#13 JSONL Tail Checkpoints** (`docs/invariants.md:88-93`) — Not affected.
  `ClaudeCodeAdapter.swift` is a named #13 enforcer, but workflow-agent files
  land `tier='skip'`, and the append-tail checkpoint path is gated to
  normal/premium (`SwiftIndexer.swift:423`,
  `guard current.tier == .normal || current.tier == .premium else`), so these
  files always take the full-reparse path and never advance `parsed_offset`.
- **#9 Startup Backfills Are Ordered and Idempotent** (`docs/invariants.md:61-66`)
  — Touched **only if slice C lands** (widening the `backfillParentLinks`
  regex). The backfill stays idempotent and self-terminating; widening the
  pattern does not change ordering. Slices A/B do not touch #9.

No new invariant is introduced; no ledger entry is added.

## Alternatives considered

- **Startup backfill instead of adapter descent** — Rejected. A backfill cannot
  insert never-discovered rows; only the adapter lists new files. (See "Why the
  adapter route here".)
- **Blanket recursive `*.jsonl` walk under `subagents/`** — Rejected. Would
  re-collect direct subagents and the 1,143 `journal.jsonl` control files
  (`noVisibleMessages` failures), noisy and wasteful. The `agent-*.jsonl`
  prefix filter is cleaner.
- **Read `.meta.json` and carry `agentType`/`spawnDepth`** — Rejected. The
  sidecar has no parentage signal; `agentType` is 99% the generic
  `"workflow-subagent"`, and `agent_role` must stay the literal `"subagent"`
  because `StartupBackfills` keys on it (`:1072`, `:1075`, `:1274`) — overloading
  it would drop rows from the parent-link backfill. Carrying it would cost
  reading ~30k sidecars and a new DTO+schema field for near-zero display value.
  `NormalizedSessionInfo` (`SessionAdapter.swift`) has no field for it today.
- **Workflow badge / fan-out marker on the parent card** (Agent Sessions prior
  art) — Deferred to a follow-up. It needs a schema/display decision beyond this
  index-only fix.
- **Adding a parity fixture under `tests/fixtures/adapter-parity/claude-code/`**
  — Rejected. That golden is TS-generated single-file parse comparison and does
  not exercise directory descent; adding a case would drag `src/adapters`
  reference code into scope (same reasoning as codex row 22). Prove behavior
  with the Swift-only temp-directory test instead.

## Test plan

- **Repro test (required):**
  `macos/EngramCoreTests/Adapters/ClaudeCodeMultiRootAdapterTests.swift` →
  `testClaudeWorkflowSubagentsAreDiscovered_repro()`, built on the existing
  `makeTranscript(root:project:name:model:subagentSession:)` helper (`:335-373`,
  `model:` defaulted) extended with a `workflowRun` parameter — the fixture must
  set `subagentSession` too so `agentId` is non-empty (see Slice B) — and
  driving the convenience
  initializer `ClaudeCodeAdapter(projectsRoot:)` used across these tests
  (`AdapterMessageCountTests.swift:1840`). Asserts A1 and A2. Fails at
  `23dca547`, passes after slice A.
- **Negative guards (required):** in the same test, place a `journal.jsonl` and
  a session-level `workflows/wf_a.json` and assert they are excluded (A3, A4).
- **Tier guard (cheap):** extend the existing `SessionTier` skip assertions
  (`IndexerParityTests.swift:76`) with the workflow path (A5).
- **Regex test (slice C only):** a focused `NSRegularExpression` unit test on
  the widened pattern covering both the workflow and direct paths (A6).
- **Not tested:** the one-time indexing cost of 30k files (a benchmark, not a
  unit test — see Risks); `.meta.json` parsing (out of scope).

## Rollout

- App + service rebuild picks up the adapter change; no migration, no version
  bump required for slices A/B. Slice C rides the existing startup-backfill pass.
- The first scan after the change parses all ~30k workflow transcripts once
  (they land `skip`, so no FTS/vector artifacts are kept). This is a one-time
  cost per machine at first discovery, then incremental thereafter.
- Revert story: slice A/B is a self-contained listing block plus a test —
  reverting the descent stops discovery; already-indexed workflow rows remain as
  harmless `skip` rows (or can be cleared by normal maintenance). Slice C revert
  narrows the regex back; no data migration needed either way.

## Risks and open questions

- **One-time parse cost (medium).** ~30,460 transcripts (10 KB–490 KB each,
  several GB total) are fully parsed via `scanForIndexing` on first discovery,
  even though all become `skip` with search artifacts discarded. Open question:
  is a lighter info-only parse path for provably-skip files worth it, or is the
  one-time cost acceptable? Not benchmarked here — measure before shipping if
  first-scan latency matters.
- **Recurring per-scan enumeration cost (low-medium).** Distinct from the
  one-time parse: `listSessionLocators(projectsRoot:)`
  (`ClaudeCodeAdapter.swift:99-123`) rebuilds the locator set fresh on **every**
  index pass, and the indexer then stats each locator against `file_index_state`
  every pass. The descent adds walking ~1,144 `wf_*` dirs and stat-ing ~30k
  `agent-*.jsonl` files to every incremental scan, not just first discovery. On
  a large corpus expect slower incremental scans even when nothing changed;
  measure if scan cadence matters.
- **Permanent DB growth (low).** +30,460 `skip` rows, ~5x the current 6,241
  direct subagents. Per-row cost is small; watch any full-table maintenance
  scans.
- **`agentId` global uniqueness (low, pre-existing).** Row id = `agentId`
  (17-hex). Two agents in different workflow runs sharing an `agentId` would
  collide on upsert (last-write-wins). Not measured; the same latent risk
  already exists for direct subagents. Open question: confirm `agentId`
  uniqueness across `wf_*` runs, or key the row id on `sessionId + agentId` if
  collisions are observed.
- **Orphan / cascade behavior (open).** `trg_sessions_parent_cascade` behavior
  when a workflow agent's parent session is not itself indexed (or is later
  deleted) was not re-verified for the workflows case. The child is hidden by
  `tier='skip'` regardless, but a momentarily unresolved link is possible if the
  child is scanned before its parent. Open question: confirm the parent
  top-level row is always present in the same scan.
- **Slice C safety-net gap (low).** If slice C is not taken, any future path
  that inserts a workflow row without the adapter (or with a NULL parent) would
  leave it top-level-eligible were it not for `tier='skip'`. Correctness relies
  on the adapter setting `parentSessionId` inline. Documented so a future
  contributor does not assume the backfill covers these.
- **Fan-out UI scope (open).** The brief frames payoff partly as "fan-out
  visibility on the parent card." That requires a parent-card UI change beyond
  this adapter fix (Agent Sessions prior art `ClaudeSessionParser.swift:1178-1213`,
  commit `77498434`). Open question: is the fan-out badge in scope now, or is
  row 32 strictly index-only with UI deferred?
