# Design Doc: Suppress Resume where the command cannot succeed (row 11)

- **Status**: Draft
- **Owner**: reviewer
- **Date**: 2026-07-26
- **Related**: `docs/competitive-mirror-2026-07.md` row 11 / F10;
  `docs/claude-workflow-subagents-design-2026-07.md` (row 32, which multiplied
  the affected population); mirror bundle table — row 11 is the only open row
  with no spec, no PR, and no owner gate.

## Problem

Every Resume and Copy-Resume-Command affordance in the app funnels into one
service call, `EngramServiceClient.resumeCommand(sessionId:)`. For
`source == "claude-code"` that call unconditionally emits
`claude --resume <sessionId>`. Claude Code resolves `--resume` against
`~/.claude/projects/<slug>/<id>.jsonl`; a subagent transcript is not at that
path, so the emitted command names an id no session file backs and the resume
fails outside Engram, after the user has already copied or run it.

**Measured on `~/.engram/index.sqlite`, read-only, one snapshot at
`2026-07-25 16:04:59` UTC.** The corpus indexes continuously, so these drift
upward; every figure in this doc comes from that single snapshot.

| claude-code rows | count |
|---|---|
| total | 38,725 |
| transcript filename is **not** `<id>.jsonl` (non-resumable) | **36,279** |
| of those, under `…/subagents/workflows/…` | 26,993 |
| of those, under a flat `…/subagents/…` | 9,282 |
| of those, an `agent-*.jsonl` sitting directly in the project slug dir | 4 |
| of those, `tier != 'skip'` (visible in top-level list surfaces) | **1** |

**Reachability, stated so the impact is not overclaimed.** 36,278 of the 36,279
are `tier = 'skip'` and are therefore filtered out of the top-level list
surfaces. They are not unreachable: they are exactly the rows rendered by
`CompactChildRow` under an expanded parent card, which passes Resume and
Copy-Resume-Command unconditionally, so every expanded parent puts broken
buttons in front of the user. The single non-skip row is browsable normally.

The mirror recorded 14,991 affected rows on 2026-07-24. Row 32 shipped in
`08fb7837` on 2026-07-25 and began indexing `subagents/workflows/wf_*/agent-*.jsonl`,
which is where 26,993 of today's 36,279 come from. **Row 32 did not cause the
bug — it enlarged it 2.4x**, and it is the reason this row is worth doing now
rather than at its original S/medium ratio.

## Goals / Non-goals

**Goals**

- A claude-code session whose transcript `claude --resume` cannot open must not
  produce a resume command from any surface.
- The refusal must name the parent session, so the affordance degrades into
  navigation rather than a dead end.
- One choke point. Not seven.

**Non-goals**

- Codex, Gemini, and every other source keep today's behaviour. Codex is
  measured-correct as-is: **all 2,771 codex rows with a non-NULL `agent_role`
  are ordinary rollout files whose own id is in the path** (2,771 of 2,771), so
  `codex resume <id>` succeeds for them. Suppressing on `agent_role` alone would
  break all of them. Gemini's 113 role-carrying rows do not embed the id in the
  path either, but the `gemini` CLI's resume contract was not investigated and
  is deliberately left alone.
- Hiding the buttons in the UI. That is a follow-up slice, deliberately split
  (see *Proposed design*, slice B).
- `handoff`, `export`, `replay`, and transcript viewing, which do not depend on
  a resumable CLI id.
- Making subagent transcripts resumable. They are not, by Claude Code's design.

## Current state

Anchored at `origin/main` = `138a3740`.

1. **`EngramServiceReadProvider.resumeCommand`** —
   `macos/EngramService/Core/EngramServiceReadProvider.swift:1397`. The SELECT
   at `:1405-1411` is 12 columns —
   `id, source, cwd, file_path, project, model, message_count,
   user_message_count, assistant_message_count, tool_message_count,
   generated_title, summary` — with no `agent_role` and no `parent_session_id`.
   `file_path` **is** already selected (`:1406`) and already carried out of the
   read block (`:1422`).
2. **Dispatch is on `source` alone** — `:1454-1486`. `case "claude-code"` at
   `:1455` calls `resumeCLICommand(tool: "claude", …)`, which builds
   `["resume", sessionId]` / `["--resume", sessionId]` via
   `resumeArguments(tool:sessionId:)` at `:2066-2073`.
3. **The refusal shape already exists.**
   `EngramServiceResumeCommandResponse` (`macos/Shared/Service/EngramServiceModels.swift:933-959`)
   carries `error` and `hint`, and both consumers already handle them:
   - `ResumeDialog.fetchResumeInfo()` (`macos/Engram/Views/Resume/ResumeDialog.swift:156-168`)
     renders `error` + `hint` on separate lines.
   - `TodayResumeCommand.copyableClipboardItem(from:)`
     (`macos/Engram/Views/Pages/TodayWorkbenchSupport.swift:13-36`) treats a
     non-empty `error` as unavailable and **falls back to copying the context
     primer** with "Context primer copied". So the copy surface does not fail —
     it starts handing over the thing that is actually useful for a subagent
     transcript.
4. **Every entry point routes through the one service call.** Verified call
   sites: `SessionActionHandlers.copyResumeCommand:118`, `HomeView:497`,
   `ResumeDialog:158`, plus the affordances at `SessionDetailView.swift:342`,
   `TranscriptToolbar.swift:124`, `CommandPaletteView.swift:53`
   (`PaletteItem.swift:95`), `SessionsPageView.swift:214-215`,
   `TimelinePageView.swift:290-291`, and `ExpandableSessionCard.swift:227-245`
   (confirmed children) / `:261-281` (suggested children), which pass
   `onResume` / `onCopyResumeCommand` to `CompactChildRow` unconditionally.

**Anchor drift from the mirror, recorded so the next reader does not chase it.**
`EngramServiceReadProvider.swift:1364-1372` is now `:1397-1411` and `:1436-1445`
is now `:1454-1486`; `EngramServiceModels.swift:926-951` is now `:933-959`.
`ExpandableSessionCard.swift:228` and `:263` are **exact** — the two
`CompactChildRow(` call sites are still on those lines. Every claim the mirror
makes at all four anchors re-verified true.

## Proposed design

### Slice A — one service-side gate (the whole fix)

In `resumeCommand`, after `contextPrimer` is built (`:1448-1453`) and before the
`switch source` (`:1454`), refuse when the session is a claude-code session
whose transcript file is not what `--resume` will look for:

```swift
// claude --resume <id> resolves ~/.claude/projects/<slug>/<id>.jsonl. A
// subagent transcript lives under <parentId>/subagents/… and is not at that
// path, so the command would name an id no session file backs. Refuse with
// the parent instead of emitting it. Filename identity — not agent_role — is
// the predicate; see Alternatives.
if source == "claude-code", !Self.claudeResumeFileMatchesID(filePath: session.filePath, id: sessionId) {
    return EngramServiceResumeCommandResponse(
        contextPrimer: contextPrimer,
        error: "This transcript cannot be resumed directly",
        hint: parentHint   // "It is a subagent of <parentId>. Resume that session instead."
    )
}
```

`contextPrimer` is passed through deliberately: it is what makes
`copyableClipboardItem` degrade to "Context primer copied" instead of throwing.

**The predicate is a pure function** so it is testable without a database:

```swift
static func claudeResumeFileMatchesID(filePath: String, id: String) -> Bool {
    !id.isEmpty && (filePath as NSString).lastPathComponent == "\(id).jsonl"
}
```

**The parent id needs one column.** `parent_session_id` is not in the SELECT.
Add exactly that one column (`agent_role` is *not* needed — see Alternatives)
and fall back to deriving from the path the same way the adapter does
(`ClaudeCodeAdapter.swift:947-952`: the path component before `subagents`) when
it is NULL, which is the state of 185 rows today (see *Risks*).

### Slice B — belt and braces on the child rows (follow-up, separately landable)

`CompactChildRow` is the only surface where these rows are routinely visible.
Passing `nil` for `onResume` / `onCopyResumeCommand` there when the child is a
claude-code subagent removes the affordance rather than letting the user open a
dialog that only says no. This is a UI-only diff against
`ExpandableSessionCard.swift:227-245` and `:261-281`, needs the same predicate
on the `Session` model, and is **not** required for correctness once slice A
lands. Splitting it keeps slice A's diff inside one file plus its test.

Slice B must gate on the predicate, **not** on `Session.isSubAgent`
(`macos/Engram/Models/Session.swift:121`, `agentRole != nil`) — see Alternatives.

## Invariants affected

None in `docs/invariants.md`. This adds no write path, no schema change, no
backfill, and no new startup ordering. Slice A is a read-path refusal.

Per the CLAUDE.md invariant back-reference rule, the code comment cites the
`--resume` path contract it is enforcing rather than claiming a ledger entry it
does not have.

## Alternatives considered

- **Gate on `agent_role == "subagent"` (what the mirror proposed).** Lost on
  live data: `agent_role` is not a two-valued enum. claude-code carries **19
  distinct non-NULL values**, because the Task tool's *agent type* is what lands
  in the column — `subagent` (35,327), `general-purpose` (383),
  `codex:codex-rescue` (184), `Explore` (133), `dispatched` (109),
  `gemini:gemini-agent` (97), `superpowers:code-reviewer` (45),
  `polycli:polycli-provider-agent` (34), `kimi:kimi-agent` (24),
  `qwen:qwen-rescue` (21), `minimax:minimax-agent` (15), `Plan` (5),
  `claude-code-guide` (2), `i18n` (2), `privacy` (2), and four one-row roles
  (`scientific`, `hallucination`, `compliance`, `accessibility`).
  **The gate misses 952 non-resumable rows** — 948 role-carrying rows under
  `…/subagents/…` that are not spelled `subagent`, plus the 4 `agent-*.jsonl`
  files in a project slug dir, one of which is `tier = normal` and therefore
  browsable at top level.
- **Gate on `Session.isSubAgent` (`agentRole != nil`).** Lost, and the mirror
  is right about why: it would kill Resume for 109 claude-code and 447 codex
  `dispatched` rows whose ids *are* resumable, plus 394 qwen and 166 kimi.
- **Gate on `agent_role IS NOT NULL AND agent_role != 'dispatched'`.** Lost by
  one row (36,278 of 36,279) and on principle: it hard-codes that `dispatched`
  is the only resumable role name, which the 19-value spread gives no reason to
  believe will hold.
- **Gate on `file_path LIKE '%/subagents/%'`.** Closest runner-up and it mirrors
  the adapter's own predicate (`ClaudeCodeAdapter.swift:378`), but it is a
  strict subset: 36,275 vs 36,279, missing the same 4 `agent-*.jsonl` rows.
  Filename identity subsumes it and is the actual CLI contract.
- **Gate in each of the ~10 client call sites.** Lost: ten diffs, ten chances to
  miss one, and the command palette and transcript toolbar are easy to forget.
  One service refusal covers every present and future caller.
- **Suppress on every source with a non-NULL `agent_role`.** Lost: measured
  wrong for codex, where all 2,771 such rows are ordinary rollouts carrying
  their own id.

## Test plan

Swift, `macos/EngramServiceCoreTests/`:

1. `testClaudeSubagentTranscriptRefusesResume_repro` — a claude-code session
   whose `file_path` is `…/<parent>/subagents/<child>.jsonl` returns a non-nil
   `error`, a `hint` naming the parent, and **no** `command`. Fails before
   slice A (today it returns `claude --resume <child>`).
2. `testClaudeWorkflowSubagentTranscriptRefusesResume_repro` — same for
   `…/<parent>/subagents/workflows/wf_x/agent-y.jsonl`, the 26,993-row shape
   that row 32 introduced.
3. `testClaudeTopLevelSessionStillResumes` — `…/<slug>/<id>.jsonl` still emits
   `claude --resume <id>`. Guards against over-firing.
4. `testCodexAgentRoleSessionStillResumes` — a codex row with
   `agent_role = 'subagent'` and an ordinary rollout path still resumes. This
   is the regression the rejected `agent_role` gate would have caused; it is the
   reason to write it.
5. `testResumeRefusalKeepsContextPrimer` — the refusal response carries a
   non-empty `contextPrimer`, so `copyableClipboardItem` takes the
   "Context primer copied" branch rather than throwing.
6. Pure-function table test on `claudeResumeFileMatchesID` covering: exact
   match, `agent-<id>.jsonl` (the 4-row shape), a `subagents/` path, empty id,
   and an id that is a suffix of the filename but not the whole stem.

**Not tested:** the SwiftUI surfaces. Slice A is asserted at the service, which
is the only thing all of them call; slice B, if taken, gets its own view-model
level assertion rather than a rendered-view test.

## Rollout

- Service + app rebuild. No migration, no backfill, no metadata version bump,
  nothing to re-index.
- Takes effect the first time a user opens Resume after the rebuild.
- Revert: delete the guard block. It is additive and touches no stored state.

## Risks and open questions

- **185 workflow rows have `parent_session_id IS NULL`** (measured 2026-07-26;
  all 185 share one parent directory, and that parent **is** indexed, premium
  tier, not hidden — so the link is derivable and simply was not made). For
  those rows the hint must fall back to deriving the parent from the path, or
  it will read "It is a subagent of (unknown)". Root cause of the 185 is
  **not** established here; see the row-32 note below.
- **`agent_role` provenance is not audited.** This design does not read the
  column, so its 20 values are evidence for rejecting an alternative, not a
  dependency. If a future change *does* depend on `agent_role`, that audit
  becomes a prerequisite.
- **Filename identity assumes Claude Code keeps `<id>.jsonl`.** If a future
  Claude Code release changes the resume lookup, the predicate goes stale
  silently — it would start refusing resumable sessions rather than emitting
  broken ones, which is the safer failure direction but still wrong. Row 23
  (`docs/adapter-format-drift-design-2026-07.md`) is the mechanism that would
  notice.
- **Open question — is the refusal the right UX for `tier = normal` rows?** 4 of
  the 36,279 are not subagents in the usual sense; one is `tier = normal` and
  browsable. Refusing is correct (its file genuinely is not resumable), but the
  hint copy written for subagents will read oddly. Suggested resolution: when no
  parent can be derived, use a generic "its transcript is not stored where
  `claude --resume` looks" hint instead of naming a parent.

## Appendix — row 32 is partial, not landed

`docs/competitive-mirror-2026-07.md`'s verified-status block (authored 2026-07-25,
PR #268) lists row 32 as landed. Slices A/B shipped in `08fb7837`; **slice C did
not.** `docs/claude-workflow-subagents-design-2026-07.md:212` specifies widening
the `backfillParentLinks` regex, and `StartupBackfills.swift:1278` still reads

```swift
let regex = try NSRegularExpression(pattern: #"/([^/]+)/subagents/[^/]+\.jsonl$"#)
```

which cannot match `…/subagents/workflows/wf_x/agent-y.jsonl`. The primary path
is unaffected — the adapter sets `parentSessionId` at parse time
(`ClaudeCodeAdapter.swift:384`, `:947-952`), which is why 26,808 of 26,993
workflow rows are linked. The 185 that are not are exactly the population slice C's
backfill exists to catch, so slice C is a measured gap, not the
"defense-in-depth" its own spec calls it. Corrected in the status block on the
`docs/mirror-backlog-verified-status` branch.
