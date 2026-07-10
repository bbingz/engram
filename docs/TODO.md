# Engram TODO

Confirmed engineering tasks. Product-level work belongs in `docs/roadmap.md`;
verification and low-priority follow-ups belong in `docs/followups.md`.

## Open

No open TODO items as of 2026-07-11 (Wave 8 Round 4 durable closeout).

Historical note: as of 2026-06-21 all 2026-06-15 UX-flow-alignment (PR #74)
follow-ups were already resolved — see "Closed in cleanup". Wave 8 closed the
remaining Wave 7 residual engineering defects on main through `c983a759`; this
file still has zero open engineering tasks. Product-direction work stays in
`docs/roadmap.md` Decision pending (12 rows), not here.

## Closed in cleanup

Implemented on 2026-06-21 (branch `feat/backlog-5-followups`):

- **Readable gated-Observability logs.** Sanitized in-process log ring
  (`ServiceLogRing` + `ServiceLogSanitizer`) teed from `ServiceLogger`, exposed
  over IPC (`serviceLogs`); `LogStreamView` reads service lines via IPC while
  `os_log` stays `.private`.
- **Sources page consolidation.** `SourcePulseView` is the single Sources
  surface (shared `SourceCatalog` overlaid on live rows) plus per-source ingest
  stop (`setSourceEnabled`/`disabledSources`, adapter filter in `runInitialScan`,
  hide/unhide existing sessions).
- **Manual arbitrary related sessions.** Symmetric `session_relations` +
  `addSessionRelation`/`removeSessionRelation`/`relatedSessions` IPC + a detail
  section and list context menu (distinct from parent/child).
- **Orphaned `embeddingStatus()` cleanup.** Dead IPC command removed end-to-end.
- **Command-palette no-results state.** `SearchOutcome`-driven failed-vs-empty
  distinction in the `⌘K` palette.

Retired on 2026-06-21 — already shipped, confirmed against current main:

- **Favorite toggle from browse.** Browse favorite action shipped with PR #74
  (`ExpandableSessionCard.onToggleFavorite`). Wave 8C / M19 (`262d59a2`) made
  the toggle symmetric (Add/Remove) via session `isFavorite` /
  `favoriteToggleTarget` on browse, Starred, and child cards — see
  `SessionModelTests` favorite suite. Do not re-open as a partial claim.
- **Cost/usage notifications.** Shipped: monthly-budget + long-session notify
  in `SettingsView` (`monthlyBudget`, `notifyOnLongSession`) — the cost
  dashboard's budget notifier.

The previous cleanup TODO items were completed and verified:

- Pin test target signing team.
- Make `get_insights` honest or actionable.
- Resolve `live_sessions` MCP contract.
- Add service-side degraded status SLA.
- Split TypeScript web routes.
- Add Swift CLI resume command.
- Add smart dirty-worktree policy.
- Add streaming patch support for oversized JSONL.
- Add SSE transport for live updates.

Evidence is recorded in `docs/backlog-cleanup-report.md`.
