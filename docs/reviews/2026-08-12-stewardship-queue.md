# Engram stewardship priority queue — 2026-08-12

Owner: Grok (lead) + Herdr Codex `retro-handler` (w5:p1)  
Sources: two-round-retro-2 confirmed findings, `docs/TODO.md`, `docs/followups.md`, `docs/roadmap.md`  
Scope rule: Swift product path only; writes via service/writer gate; no Node product startup.

## Active

| Rank | ID | Sev | Title | Owner path | Done-when | Status |
|------|----|-----|-------|------------|-----------|--------|
| 1 | RETRO-P1-POPOVER | P1 | Popover omits top-level parent filter → child rows as top | implementer | `PopoverView` uses `SessionVisibilityFilter.topLevelSQL` (or equivalent parent+suggested NULL); `_repro`/UI-path unit test green | **DONE** 2026-08-12 |
| 2 | RETRO-P1-PARENT-VALIDATE | P1 | Path parent write lacks existence/depth/skip checks; startup never reconciles dangling | Codex | Writer validates parent; startup backfill/reconcile clears illegal parents; regression tests | **DONE** 2026-08-12 (Codex residual) |
| 3 | RETRO-P1-AGENTID-COLLISION | P1 | Empty agentId subagent id falls back to parent sessionId → row clobber | implementer | Subagent without agentId gets stable non-parent id or is skipped; conflict `_repro` green | **DONE** 2026-08-12 |
| 4 | RETRO-P1-SOURCE-DISABLE-BYPASS | P1 | disabledSources filters adapter.source only; Claude reclass still indexes as other sources | Codex | Post-detect / post-parse filter honors disabled set; reclass cannot reappear while disabled | **DONE** 2026-08-12 (Codex residual) |
| 5 | RETRO-P1-SOURCE-ENABLE-UNHIDE | P1 | `setSourceEnabled(true)` mass-clears `hidden_at` for whole source | implementer | Enable only unhides source-disable hides (or restores local_state); user manual hide preserved | **DONE** 2026-08-12 |
| 6 | RETRO-P1-SETTINGS-DB-SPLIT | P1 | Settings.json then SQLite; no shared rollback | Codex | Order/compensation so settings+DB converge or fail closed | **DONE** 2026-08-12 (Codex residual) |
| 7 | RETRO-P1-PROJECT-MOVE-SPLIT | P1 | Project-move `markFsDone` / DB apply two writer transactions | Codex | Single transaction or durable recover for `fs_done` mid-failure | DEFERRED — re-adjudicate recover path |
| 8 | RETRO-P1-GET-MEMORY-EMPTY | P1 | get_memory empty path suppresses degrade warning | implementer | Empty memory result still surfaces degrade warning when applicable; MCP test | **DONE** code (MCP RPC evidence deferred) |
| 9 | RETRO-P1-INVARIANT2-TEST | P1 | Invariant 2 lacks IPC setParent tier `_repro` | Codex | Swift IPC test: link does not upgrade skip child | **DONE** 2026-08-12 (Codex residual) |

## Deferred this cycle (queued, not active)

| Rank | ID | Sev | Title | Why deferred | Done-when |
|------|----|-----|-------|--------------|-----------|
| 10 | RETRO-P2-SKIP-PARENT | P2 | Generic/IPC can link to skip parent | **DONE** 2026-08-12 | Reject skip parent on IPC link — landed |
| 11 | RETRO-P2-TODAY-PARENTS | P2 | todayParents emitted before backfills | After P1 | Gate status on backfill completion |
| 12 | RETRO-P2-INVARIANT-LEDGER | P2 | Dual-era not in invariants ledger | Doc-only after code health | `docs/invariants.md` §15 |
| 13 | RETRO-P2-DENYLIST-CASE | P2 | Case-sensitive denylist | Low | Folded compare |
| 14 | RETRO-P2-TEST-MUTATOR | P2 | Prod `test.write_intent` surface | Security hygiene | Guarded/non-prod |
| 15 | RETRO-NIT-TOKEN-TIMING | nit | Non-constant-time token compare | **DONE** 2026-08-12 | Constant-time compare |
| 20 | TODO-REL-1.0.5 | release | Notarize/publish `v1.0.5` | **BLOCKED** — TODO forbids signing/Keychain/tag without explicit human auth | Human auth + notarization pass |
| 21 | FOLLOW-ALIAS-P2 | low | Same-basename ghost alias remove | No repro host | Only if repro appears |
| 22 | ROADMAP-DECISION | product | 12 Decision-pending rows | Parked until release baseline | Product owner pick |

## False-positive / partial notes (this cull)

| Claim | Verdict | Evidence |
|-------|---------|----------|
| Popover parent filter drift | **CONFIRMED** | `PopoverView.swift:265-268` only hidden+skip+HumanDriven; no parent/suggested NULL |
| Path parent unvalidated | **CONFIRMED** | Sticky CASE write; no existence check at 374-382 |
| Empty agentId collision | **CONFIRMED** | `id()` returns `sessionId` for subagents when agentId empty |
| Source disable bypass | **CONFIRMED** | Filter on `$0.source.rawValue` only |
| Enable mass unhide | **CONFIRMED** | `UPDATE … hidden_at=NULL WHERE source=?` |
| Project-move two-phase | **OPEN / re-check** | Orchestrator has recover paths; do not “fix” without proving gap |
| Release 1.0.5 deploy | **BLOCKED** | `docs/TODO.md` authorization boundary |

## Brainstorm (if health P1s clear)

1. Cursor CWD ownership contract (`CURSOR-CWD-001` followups) — design then implement.  
2. MCP object-root residual if any post #215 still open — re-grep MCP-001.  
3. Competitive gap: session “resume in original tool” deep-link UX (roadmap-adjacent).  
4. Archive V2 bounded discovery exporters (followups deferred engineering).

## Cycle contract

- Ship one PR for the largest coherent Codex batch of CONFIRMED P1s that tests pass.  
- Do **not** push `v*` or notarize without TODO authorization.  
- Daily retro: `docs/reviews/2026-08-12-daily-retro.md`.
