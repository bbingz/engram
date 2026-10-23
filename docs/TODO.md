# Engram TODO

Confirmed engineering tasks. Product-level work belongs in `docs/roadmap.md`;
verification and low-priority follow-ups belong in `docs/followups.md`.

## Current execution status (2026-10-23)

Fresh routing: [development reconciliation](reviews/2026-10-23-development-reconciliation.md).
The detailed dated entries below preserve history; their presence does not
make a closed item open again. Local baseline and live remote main were both
`5216ff3a`. Current development is in `codex/leader-loop-20261023`.

| Item | Current status | Remaining verifier |
|---|---|---|
| Collector CPU | Open | Comparable 30-minute Daily window: CPU <=2%, RSS <=150 MiB; optimize only measured leads. |
| W4.1 alias reconciliation | Closed, superseded by D7(c)/D9 | Reopen only as a separately scoped old-DB user-state import. |
| W4.5 old-receipt bootstrap | Closed, owner won't-do | Preserve retained old DB/archive; no automatic reimplementation. |
| W4.7 epoch operator command | Implemented | Authorized HQ binary/CLI readback and real recovery; authority-file runbook remains. |
| W6.2 real-binary gate | Closed, recorded gate exists | Hosted [39098816343](https://github.com/bbingz/engram/actions/runs/39098816343) rechecked success; not a real-host acceptance receipt. |
| App Open Web Reader | Implemented | Set/verify each intended host's URL under host-change authorization. |
| P2 duplicate quarantine | Implemented, deployment recorded | Real cross-machine duplicate remains unexercised. |
| P3 install tooling | Implemented | First real-host installation/upgrade/rollback receipt. |
| D7 legacy local rows | Closed, purge recorded | Do not rerun destructive action. |
| `cutover-role-surface-1` | Fixed locally | RED: 8 expected catalog assertions failed. GREEN: 215 MCP executable tests passed; not pushed/deployed. |
| Collector fixture race/leak | Fixed locally | 85 CollectorRuntime tests plus the affected publication test passed; hosted flake recurrence not measured. |
| `collector-blocked-root-backoff-1` | Fixed locally | Final 87 runtime tests passed after behavioral RED and scheduler negative control. Per-root 1–60 second monotonic retry preserves healthy-root progress and recovery/reset/restart; no real-host CPU claim. |
| Round-12 secrets / live navigation / favorites | Existing fixes verified locally | 210 selected App tests passed with an isolated home; source and exact coverage in the reconciliation. Transcript apply concurrency remains a narrower verification item. |
| Web project audit actor | Fixed locally for four project commands | HTTP/auth/IPC 60, service/registry 29 and native batch/store 34 tests passed after RED. Alias audit storage and other Web hardening remain separate; not deployed. |

Remaining historical residuals require current repro before promotion;
remaining Web hardening and measured performance follow the bounded queue
in the reconciliation. Product choices stay in `roadmap.md`. Production changes,
push/merge and releases require separate authorization.

## Dated engineering ledger

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
  2026-10-18 read-only window (PID 96925, the 2026-10-17 build, poll 10 s, 16
  roots converged before and after, host in active use): 61 samples over
  1803 s, CPU 5.891% (FAIL), max RSS 81.2 MiB (PASS), no re-walk, 37
  publications ACKed (35 Claude Code). The Cursor peer-scan lead was already
  mitigated on 2026-09-12 (30 s hint cache, 10 s gate) and the D1-D3
  diagnostics were negative, so no code was changed. Next measured lead:
  per-change capture cost of large appended transcripts
  (`docs/followups.md` `collector-publication-cost-1`). Still open; receipt in
  the retirement checklist and `CHANGELOG.md`.
  2026-10-18 local profiling found and fixed the largest per-publication cost
  (privacy assessment repeated per replica; PR #482
  `059fe3b9`, 20-46% less collector CPU per
  publication), but it explains only part of Daily's bursts. Next: deploy to
  Daily (separately authorized), re-measure the 30-minute window, and if it
  still fails, `sample` the Daily collector during a burst (owner approval).
  2026-10-18 deployed to Daily (owner-authorized; `ea2bbb57`, package
  `collector-epoch-proof-reuse-20261018`) and re-measured after the restart
  walk converged: 12:01-12:31Z, 61 samples over 1800 s, CPU 5.847% (FAIL),
  max RSS 96.9 MiB (PASS), PID stable, 26 publications ACKed by both
  replicas, median 30 s interval 3.8%. A 90 s `sample` with no capture in it
  shows the idle per-turn floor dominates (Cursor legacy observation
  reconciliation 31% of sampled busy stacks, unavailable-source deferrals 13%,
  captured-dependency checks 11%, mostly `openat`/`fstatat`/`getdirentries`).
  This corrects the sentence above: the 2026-09-12 hint cache and 10 s gate
  made the Cursor scan less frequent, not cheaper. The 2% target is unchanged
  (roadmap D2: it blocks only a "lightweight" claim, not "finished"). Next:
  `docs/followups.md` `collector-idle-turn-cost-1`, then
  `collector-stuck-dirty-locators-1`.
  2026-10-19: a 15 s `sample` of the Daily collector put the per-turn floor on
  `validateStorageFilesystem`'s ancestor walk, not on directory enumeration.
  Built locally on `perf/collector-idle-turn-cost-20261019`: a finished scan
  deletes its root's frontier rows, the ancestor walk is proven once per open,
  and vanished never-captured locators leave the dirty set. The Cursor legacy
  observation reconciliation, the largest share of the 2026-10-18 sample, is
  untouched. Deployed to Daily 2026-10-19 as `collector-idle-turn-20261019`
  (owner-authorized "授权部署，再测"; commit `81bf3f1a`): all three fixes
  verified live (frontier 12,130,812 -> ~1,000 rows; cached ancestor holds with
  no full re-walk in a 60 s `sample`; dirty locators 414+ stuck -> 266). The
  07:59-08:25Z window read 34.6% CPU but is NOT a steady-state receipt: an
  active multi-agent Claude Code workflow wrote `~/.claude/projects` the whole
  time, `daily-claude` never converged, and 0 of 51 intervals were below 2%.
  The comparable quiet-host 30-minute window (CPU <= 2%, RSS <= 150 MiB) still
  needs to be taken once that workload ends; record it here and in
  `CHANGELOG.md`.
- **Alias reconciliation (plan W4 item 1, design section 4).** Not started. The
  committer refuses any occupied proposed ID, so pre-cutover local rows, their
  insights and parent links stay in the local-ID namespace and are not visible
  on Web. Done when exact-provenance aliasing and mismatch quarantine are tested.
  2026-10-18: scoped (about 800-1,100 lines, schema change, design doc first)
  but not built; it needs an owner decision because D7(c) and D9 removed the
  current production need: close as superseded, build as designed for a future
  local-role host that also ingests its own collector, or re-scope as an old-DB
  user-state import. See `CHANGELOG.md` 2026-10-18.
  Closed 2026-10-18 by owner decision: superseded by D7(c) and D9. The cutover
  design (`docs/superpowers/specs/2026-10-02-hq-local-collector-cutover-design.md`)
  kept the alias only for HQ's own legacy rows (D7, purged on 2026-10-18) and
  the old local history (D9, gap accepted); neither remains in the central DB.
  Reopen trigger: when the HQ collector (D6/D8) goes live and the owner wants
  the old HQ local DB's user state (favorites, custom names, insights, manual
  links) carried over, open a new item scoped as an old-DB user-state import,
  not as this alias.
- **Old-receipt bootstrap (plan W4 item 5).** Not started; no implementing code.
  2026-10-18: scoped as XL (the ingest generation and ledger assume a collector
  publication envelope; receipt provenance needs a schema change) and dependent
  on W4.1 or an explicit duplicate rule. D9 ("accept the history gap, W4.5 is a
  later decision") still stands; needs an owner decision to reopen or to mark
  won't-do. See `CHANGELOG.md` 2026-10-18.
  Closed 2026-10-18 by owner decision: won't do. D9 stands and W4.1 is closed,
  so the prerequisite is gone; the old DB and archives stay retained.
- **Operator epoch reconcile command (plan W4 item 7).** `dryRunEpoch` and
  `approveEpoch` exist in `CaptureIngestSourceRegistry.swift` without a non-test
  caller. Done when a local authenticated IPC/CLI action and its test exist.
  2026-10-17: the collector-local half shipped as
  `EngramCollector --reconcile-native-epoch [--dry-run]` after the Daily
  reboot left seven roots on a stale FSEvents epoch
  (`docs/superpowers/specs/2026-10-17-collector-native-epoch-reconcile-design.md`,
  invariant "Native Epoch Reconciliation Is An Explicit Operator Action"),
  deployed to Daily the same day as `collector-native-epoch-reconcile-20261017`
  (real-host dry run: 0 affected roots). 2026-10-18: the HQ half merged as
  PR #477 (`9f131f25`)
  (`docs/superpowers/specs/2026-10-18-hq-collector-epoch-approval-design.md`,
  invariant "Collector Epoch Approval Is A Local Operator Action"): the
  token-protected Service command `collectorApproveEpoch` and the read-only
  `collectorEpochDryRun` (which also lists observed but unapproved epochs for
  the source instance), reached through
  `EngramCLI collector-epoch dry-run|approve`; repro test
  `testUnapprovedEpochBecomesIngestibleAfterOperatorApproval_repro`. Remaining:
  the HQ service-index and EngramCLI deployment is a separate owner-authorized
  step, and the command has no real-world trigger yet because the collector
  never rotates an epoch under an existing source instance (owner decision in
  `docs/followups.md` `collector-epoch-producer-1`).
- **Real-binary chain in a recorded gate (plan W6 item 2).** Every test in
  `CollectorBinaryShadowIntegrationTests.swift` skips unless three binary-path
  environment variables are set, and no CI workflow sets them. Done when CI sets
  them or a documented manual gate with a receipt exists.
  Done 2026-10-18: merged as PR #475 (`5b5b09af`), hosted run 39098816343 passed with `--timeout-scale 6`. Shipped the
  non-required `.github/workflows/real-binary.yml` (weekly Sunday 20:17 UTC,
  `workflow_dispatch`, and pull requests that touch its own five gate paths;
  not in `test.yml` or `ci-gate`) and `scripts/ci/run-real-binary-gate.sh`,
  which builds the Debug `EngramCollector`/`EngramService`/`EngramRemoteServer`
  tools, sets the three binary variables (plain and `TEST_RUNNER_` forms) with
  an isolated `CFFIXED_USER_HOME`, and runs
  `CollectorBinaryShadowIntegrationTests`, `CollectorLargeHistoryBinaryTests`
  and `CollectorCLIIntegrationTests` (CLI needs only the collector binary).
  `scripts/ci/check-real-binary-results.py` compares the exact test set parsed
  from the Swift sources with the xcresult tree and fails on any missing,
  extra, failed or skipped test except the opt-in browser demo. Local Debug
  receipt on Xcode 26.4 at `b2e8ef2a` (dirty paths 0):
  `REAL_BINARY_GATE result=pass expected=50 passed=49 skipped=1 failed=0`; the
  same classes run without the variables exit 0 with 50 skipped and the
  verifier rejects them (`result=fail ... skipped=50`). Remains: the PR's own
  hosted macos-15 "Real-binary chain" run must be green with that line (Debug
  tool loading and the 25 s scope deadlines are unproven on hosted runners);
  record the run URL here and close the item.
- **App "open Web reader" entry (design section 1).** In `collector`/`replica`
  roles the App shows only the unavailable message; it has no action that opens
  the Web reader as the design states.
  2026-10-18: shipped in PR #476 (`7a48d19d`). The unavailable
  window and Settings fallback now show "Open Web Reader" for collector/replica,
  driven by an optional top-level `webReaderURL` in the owner-only
  `settings.json` (https only, host required, no userinfo/query/fragment,
  printable ASCII, <= 2048 bytes), parsed only by the App. Unset or invalid
  keeps the button disabled; the action opens the default browser and never
  opens the DB or spawns/adopts the Service. Still open: each collector/replica
  host's `settings.json` needs the key (owner-approved manual edit, value checked
  against the live `ENGRAM_REMOTE_WEB_ORIGIN`); `render-collector-settings.mjs`
  does not write it.
- **P2 exact-content cross-machine duplicate quarantine (cutover design §3-B,
  decision D6; added 2026-10-07).** Merged as PR #455 (`5d7d684d`, 2026-10-07):
  `testIdenticalCrossMachineCaptureIsQuarantinedNotDuplicated_repro` passes and
  the ledger entry exists. Deployed 2026-10-17: HQ service-index moved to
  `b95d99ad` (package `service-index-main-b95d99ad-20261017`), whose startup
  migration created `capture_ingest_identity_bindings_native_id_source`.
  Done; the ledger code is live but unexercised until a real cross-machine
  duplicate arrives.
- **P3 install tooling (cutover design §4.1-4.6, decision D12; added
  2026-10-07).** Done: merged as PR #454 (`63e0a17e`, 2026-10-07) with the
  `tests/scripts` suites and `CollectorRenderedSettingsFixtureTests`; the
  2026-10-17 status check confirmed the scripts and tests on `main`. The
  tooling has still never run against a real host; that remains under
  `docs/followups.md` `cutover-install-tooling-1`.
- **D7 purge of legacy `origin=local` grok/pi rows, dry-run first (added
  2026-10-07).** Tooling merged 2026-10-18 as PR #478 (`9ef7fb4f`)
  (`docs/superpowers/specs/2026-10-18-d7-legacy-local-origin-purge-design.md`):
  a SELECT-only report and a plan-bound purge in
  `LegacyLocalSessionPurge`, the index-role-only, capability-protected
  service commands `legacyLocalPurgePreview` / `legacyLocalPurgeApply`
  (one `ServiceWriterGate` transaction, refused on any user-state
  dependent, metadata audit row), `EngramCLI maintenance legacy-local-purge
  preview|apply`, and the offline read-only
  `EngramService --legacy-local-purge-report --database-path ABS`. The
  dry-run report exists (2026-10-18, read-only `VACUUM INTO` snapshot of the
  HQ index at 02:24Z, binary built from merged `main`, cross-checked with
  plain SQL): `sessionCount` 6,191 (grok 5,959, pi 232, unchanged since the
  role gate), every blocking dependent 0, `purgeAllowed` true, `planToken`
  `9fa54d7d1ab87778faf42d525076f8544b322207313ed06b4bb916f9d8890b8f`; see
  `CHANGELOG.md` 2026-10-18. The owner approved that report on 2026-10-18
  ("批准": `sessionCount` 6,191, `planToken` `9fa54d7d…90b8f`). Done
  2026-10-18: HQ service-index deployed from `9ef7fb4f`, the live preview
  reproduced the approved values, a `VACUUM INTO` rollback copy was taken,
  and the apply deleted the 6,191 rows plus their derived rows (audit
  `legacy_local_purge.v1.2026-10-18T05:17:15Z`); re-preview 0, no
  `origin=local` rows left, capture-bound grok/pi rows untouched. See
  `CHANGELOG.md` 2026-10-18.

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
