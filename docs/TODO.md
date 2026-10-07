# Engram TODO

Confirmed engineering tasks. Product-level work belongs in `docs/roadmap.md`;
verification and low-priority follow-ups belong in `docs/followups.md`.

## Open

### Collector / central index cutover gaps (added 2026-10-02)

Source-verified gaps against the accepted design
(`docs/superpowers/specs/2026-09-05-collector-server-web-design.md`) and plan
(`docs/superpowers/plans/2026-09-05-collector-server-web.md`). Owner decisions
that change their priority are listed in `docs/roadmap.md`; none of these
authorizes host changes.

- **Collector CPU on the Daily Mac (plan W6 item 3).** The last recorded full
  Daily window measured 13.178% of one core against the 2% target; resource work
  was deferred on 2026-09-13, not passed. The checklist names a repeated Cursor
  peer scan as the measured lead. Done when a 30-minute Daily window meets
  CPU <= 2% and RSS <= 150 MiB and the receipt is summarized in the checklist.
- **Alias reconciliation (plan W4 item 1, design section 4).** Not started. The
  committer refuses any occupied proposed ID, so pre-cutover local rows, their
  insights and parent links stay in the local-ID namespace and are not visible
  on Web. Done when exact-provenance aliasing and mismatch quarantine are tested.
- **Old-receipt bootstrap (plan W4 item 5).** Not started; no implementing code.
- **Operator epoch reconcile command (plan W4 item 7).** `dryRunEpoch` and
  `approveEpoch` exist in `CaptureIngestSourceRegistry.swift` without a non-test
  caller. Done when a local authenticated IPC/CLI action and its test exist.
- **Real-binary chain in a recorded gate (plan W6 item 2).** Every test in
  `CollectorBinaryShadowIntegrationTests.swift` skips unless three binary-path
  environment variables are set, and no CI workflow sets them. Done when CI sets
  them or a documented manual gate with a receipt exists.
- **App "open Web reader" entry (design section 1).** In `collector`/`replica`
  roles the App shows only the unavailable message; it has no action that opens
  the Web reader as the design states.
- **P2 exact-content cross-machine duplicate quarantine (cutover design §3-B,
  decision D6; added 2026-10-07).** Implementation branch
  `feat/p2-cross-machine-duplicate-quarantine-20261007`. Done when
  `testIdenticalCrossMachineCaptureIsQuarantinedNotDuplicated_repro` passes,
  the ledger entry exists, and a service-index build carrying it is deployed at
  runbook step R7.
- **P3 install tooling (cutover design §4.1-4.6, decision D12; added
  2026-10-07).** Branch `feat/p3-install-tooling-20261007`. Done when the
  settings renderer, identity branch, credential checks, planner fixes,
  upgrade/rollback plan kinds and the hash-checked executor have `(repro)`
  tests and a rendered fixture loads through the collector settings parser.
- **D7 purge of legacy `origin=local` grok/pi rows, dry-run first (added
  2026-10-07).** Not started. The HQ central index held 6,188 such rows on
  2026-10-07 (P0 counted 6,140) and they grow until the role gate runs on HQ.
  Done when a dry-run report exists, the owner approves it, and the purge
  clears the rows plus their derived rows.

Earlier status: no implementation-ready engineering task is selected as of 2026-08-16.

The former public macOS release-baseline task is complete. GitHub Release
[`v1.0.5`](https://github.com/bbingz/engram/releases/tag/v1.0.5) was published
on 2026-08-02 from exact source `ea2f1817`, build 1424. Its notarized ZIP has
SHA-256 `8174193159c15c9e9a6a5215bf0d32f6200694c567379835a0f26b9d921e699a`;
the signed/notarized, clean-host, tag, Release Gate, download, and re-download
verification evidence is retained in `CHANGELOG.md` and `MEMO.md`.

This 2026-08-16 closeout does **not** select or authorize a newer public
release. Do not create a new tag or GitHub Release, reuse/mutate an existing
tag, sign/notarize a new distribution, or update Homebrew/Sparkle without a new
explicit owner request and an exact release verifier.

The exact-source dual-replica archive v2 has shipped and is operator-enabled on
the current deployment. Its finite eligible replica drain and two-site recovery
closeout completed on 2026-07-15 and is recorded in `docs/roadmap.md`, not as an
engineering TODO. Deferred
engineering boundaries (bounded discovery and additional canonical source
exporters) and the still-forbidden remote deletion/GC surface are recorded
conditionally in `docs/followups.md`.

Historical note: as of 2026-06-21 all 2026-06-15 UX-flow-alignment (PR #74)
follow-ups were already resolved — see "Closed in cleanup". Wave 8 closed the
remaining Wave 7 residual engineering defects on main through `c983a759`; this
file had zero open engineering tasks until the release baseline above was
selected; that baseline completed on 2026-08-02. The other product-direction
work stays in `docs/roadmap.md` Decision pending (12 rows), not here.

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

- **Cost/usage notifications.** Shipped: monthly-budget + long-session notify
  in `SettingsView` (`monthlyBudget`, `notifyOnLongSession`) — the cost
  dashboard's budget notifier.

### Closed — Wave 8C favorite symmetry (historical)

- **Favorite toggle (symmetric browse/starred/child).** Closed via Wave 8C /
  M19 (`262d59a2`), not the 2026-06-21 cleanup retirements above. Symmetric
  Add/Remove on browse, Starred, and child cards uses session `isFavorite` /
  `favoriteToggleTarget` — see `SessionModelTests` favorite suite
  (`testFavoriteToggleTargetIsSymmetricNegation`,
  `testFavoriteMenuLabelReflectsAddVersusRemove`,
  `testBrowseStarredAndChildCardsWireIsFavoriteSourceTruth`). Do not re-open as
  a partial claim or attribute the symmetric toggle to the older PR #74 UX
  alignment work.

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
