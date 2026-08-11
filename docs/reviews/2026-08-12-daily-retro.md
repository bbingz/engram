# Engram daily retro — 2026-08-12

Lead: Grok (stewardship goal) · Implementation: Grok + Herdr Codex `retro-handler` (w5:p1)

## Done

### Process
- Ran `two-round-retro-2` workflow (5 phases, 31 agents): **ACTION_NEEDED**, 0 P0, multi P1.
- Wrote priority queue: `docs/reviews/2026-08-12-stewardship-queue.md`.
- Wrote handoff: `docs/reviews/2026-08-12-two-round-retro-handoff.md`.
- Dispatched Codex via Herdr; parallel implementer landed highest-value P1s while Codex continued adjudication/TDD on remaining items.

### Product fixes (shipped on branch `feat/retro-p1-2026-08-12`)
| ID | Fix | Test |
|----|-----|------|
| RETRO-P1-POPOVER | `PopoverView` uses `SessionVisibilityFilter.listVisibleSQL` + `topLevelSQL` | `testPopoverRecentSessionsUsesTopLevelVisibilityFilter_repro` GREEN |
| RETRO-P1-SOURCE-ENABLE-UNHIDE | `setSourceEnabled(true)` skips rows with `session_local_state.hidden_at` | `testSetSourceEnabledPreservesManualHideOnEnable_repro` GREEN |
| RETRO-P1-AGENTID-COLLISION | Claude/Qoder subagent empty `agentId` → `sub:{parent}:{leaf}` not parent id | `testSubagentEmptyAgentIdDoesNotCollideWithParentSessionId_repro` GREEN |
| RETRO-P1-GET-MEMORY-EMPTY | `emptyMemoryResult` carries degrade/keyword `warning` | code path updated (focused MCP RPC not re-run this cycle) |

### Deploy / release
- **Not shipped.** `docs/TODO.md` 1.0.5 notarization/tag remains **BLOCKED** on explicit human authorization (signing, Keychain, tag publish).

## Refuted / deferred
- Project-move two-phase commit: left for re-adjudication with recover-path evidence (Codex instructed not to “fix” without proof).
- Remaining queue P1s: path-parent validation + startup reconcile; disabledSources reclass bypass; settings/DB split; invariant-2 IPC `_repro`.
- P2/nits: skip-parent link, todayParents timing, denylist case, prod test mutator, token timing.

## Residual risks
- Empty-agentId path keys depend on file leaf uniqueness under a parent.
- Source-enable preserve-manual-hide relies on manual hide writing `session_local_state.hidden_at` (current `setSessionHidden` does).
- Path-parent validation still open → dangling parent can still hide children from top-level lists until fixed.
- Local worktree still has unrelated dirty UI baselines / MEMO / CHANGELOG — not included in this PR.

## PR / evidence
- Branch: `feat/retro-p1-2026-08-12`
- PR: https://github.com/bbingz/engram/pull/305
- Commit: `37702d59`
- Verify logs (scratch): `verify-popover-repro.log`, `verify-source-enable-repro.log`, `verify-agentid-repro.log`, `verify-summary.txt`
- Codex pane: `retro-handler` / `w5:p1` (continued residual P1 work after PR open)

## Next queue head
1. **RETRO-P1-PARENT-VALIDATE** — path parent existence/depth/skip + startup reconcile  
2. **RETRO-P1-SOURCE-DISABLE-BYPASS** — post-detect disabledSources filter  
3. **RETRO-P1-SETTINGS-DB-SPLIT** — settings/DB convergence  
4. **RETRO-P1-INVARIANT2-TEST** — IPC setParent does not upgrade skip  
5. Release 1.0.5 only after human auth

## Brainstorm (if health clears)
- CURSOR-CWD-001 ownership contract  
- Competitive “resume in original tool” deep-link  
- Archive V2 bounded discovery exporters (followups)
