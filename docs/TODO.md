# Engram TODO

Confirmed engineering tasks. Product-level work belongs in `docs/roadmap.md`;
verification and low-priority follow-ups belong in `docs/followups.md`.

## Open

Deferred follow-ups from the 2026-06-15 UX-flow alignment review (PR #74) —
intentionally scoped out of that PR, not regressions:

- **Readable gated-Observability logs.** WP17's blanket `privacy: .public`
  redaction was reverted to `.private` (no system-log leak). The follow-up is a
  sanitized in-process log buffer so the gated Observability page can show
  readable recent logs without exposing message bodies to other processes.
- **Sources page consolidation.** Finish unifying the Sources surface (status,
  health, per-source ingest controls) rather than the current partial view.
- **Manual arbitrary `linkSessions`.** Allow linking sessions beyond the
  detected parent/child relationships.
- **Orphaned `embeddingStatus()` cleanup.** Remove the dead embedding-status
  path — the Swift product search is keyword-only (no embedding provider wired).

Low-priority UX follow-ups (also fit `docs/followups.md`):

- **Command-palette no-results state.** Explicit empty/fail state in the `⌘K`
  palette search.

## Closed in cleanup

Retired on 2026-06-21 — already shipped, confirmed against current main:

- **Favorite toggle from browse.** Shipped with PR #74: session actions incl.
  favorite on the browse pages (`ExpandableSessionCard.onToggleFavorite`).
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
