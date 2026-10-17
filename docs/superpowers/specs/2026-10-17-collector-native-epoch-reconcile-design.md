# Design Doc: Native FSEvents epoch reconciliation is an explicit collector operator command

- **Status**: Accepted (implemented in the same PR)
- **Owner**: Engram maintainers (Claude session, 2026-10-17)
- **Date**: 2026-10-17
- **Related**: `docs/superpowers/specs/2026-10-02-collector-replay-loss-design.md`
  (epoch mismatch fails closed, never rebases the checkpoint; "an epoch change
  still ends the process" listed as an open owner question);
  `docs/superpowers/specs/2026-09-05-collector-server-web-design.md` §3
  ("an overflow or missed-event indication requests reconciliation") and W4.7
  (HQ-side `collectorApproveEpoch`, still not built); `docs/TODO.md` "Operator
  epoch reconcile command (plan W4 item 7)"; `docs/followups.md`
  `collector-epoch-change-scope-1`; CHANGELOG 2026-10-17 "Daily collector
  stopped on a changed FSEvents epoch".

## Problem

On 2026-10-17 the Daily Mac rebooted at 17:28 CST. Its FSEvents database UUID
changed (stored `fsevents-device-v1:04BF0C1C-…`, live
`fsevents-device-v1:E99B19DE-…`). Seven of the sixteen collector roots had a
stored event checkpoint under the old epoch, so every start of
`EngramCollector` threw `CollectorRuntimeError.reconciliationRequired` from
`CollectorRuntime.startEventsIfNeeded` (`CollectorRuntime.swift:541-545` at
`c496fd07`), exited 70, and launchd relaunched it every 10 s: 882 runs in
about 2.5 h, no uploads, and the HQ central index received nothing after
09:19 UTC. The behaviour is the designed one (the checkpoint belongs to another
event history and must not be rebased), but the design's other half, an
explicit operator reconciliation, did not exist. Recovery was a hand-written
SQL `UPDATE` on the Daily inventory with the job booted out, recorded only in
a JSON note next to the backup. Daily rebooted three times in the preceding
nine days, so this recurs.

## Goals / Non-goals

- Goals: an operator command that performs exactly the hand-made recovery,
  refuses while a collector owns the inventory, records the transition
  durably before clearing anything, previews with `--dry-run`, and is covered
  by a repro test that reproduces the incident shape.
- Non-goals: changing the runtime's fail-closed behaviour (whether an epoch
  change should suspend one root instead of ending the process stays the owner
  decision in `docs/followups.md` `collector-epoch-change-scope-1`); the
  HQ-side `collectorApproveEpoch` IPC action for a new *collector* epoch
  (spool reset); any automatic reconciliation at start; any change to
  publication sequence, identity bindings or the capture catalog.

## Current state

- `CollectorRuntime.startEventsIfNeeded` (`CollectorRuntime.swift:541-545`)
  throws `reconciliationRequired` when the coordinator is `.recoveryRequired`
  and `rootState.eventCheckpoint.epoch` differs from
  `CollectorNativeEventStream.currentEpoch(binding:)`
  (`"fsevents-device-v1:" + FSEvents database UUID`).
- The only code that clears `collector_roots.event_epoch` / `event_cursor` is
  the root re-enrollment path for a changed settings revision
  (`CollectorInventoryStore.swift:86-120`), which also resets every other
  per-root cursor. `applyEventBatch` refuses to write a checkpoint whose epoch
  differs from the stored one unless the coordinator asked for reconciliation
  (`CollectorInventoryStore.swift` `staleCheckpoint` guard).
- `EngramCollector` accepts `--settings`, `--credentials-file`, `--once`,
  `--initialize`, `--initialize-identity`, `--help` (`main.swift`). There is
  no maintenance mode that opens the inventory without running a cycle.
- Every process start already forces a full walk of every root (2026-10-02
  entry, known residual), so a cleared checkpoint plus a fresh subscription
  loses no files; it only re-walks.

## Proposed design

- **CLI**: `EngramCollector --settings ABS --reconcile-native-epoch [--dry-run]`.
  Exclusive with `--once`, `--initialize` and `--credentials-file`;
  `--dry-run` is only valid with it. Prints one JSON object
  (`dryRun`, `affectedRoots`, `roots[]` with `rootID`, `source`, `rootPath`,
  `storedEpoch`, `liveEpoch`, `outcome`, `requestedRevision`, optional
  `failure`) and exits 0. Any failure prints
  `engram-collector: native epoch reconcile failed: <Type>.<case>` and exits
  70; a running collector yields `CollectorRuntimeError.busy`.
- **Runtime API**: `CollectorRuntime.reconcileNativeEpoch(settingsURL:dryRun:)`
  (`CollectorRuntime.swift`, extension at the end of the file). It loads the
  configuration, opens `CollectorInventoryOwner` (the same exclusive `flock`
  the runtime takes, so `alreadyOwned` maps to `busy`), and for each configured
  root: no stored checkpoint, or a settings revision that no longer matches the
  stored root, reports `noCheckpoint`; otherwise it observes the root
  read-only (`CollectorPOSIXRootEnumerator.observeRoot`, no enrollment, no
  write) and reads the live epoch; an unobservable root reports `unavailable`
  with the error type and case; equal epochs report `current`; a difference
  reports `mismatch` under `--dry-run` or performs the store transaction and
  reports `cleared` with the new requested revision.
- **Schema** (`CollectorInventoryStore.createSchema`, `CREATE TABLE IF NOT
  EXISTS`, so existing inventories gain it on the next open; the
  `schema_version` metadata stays `2`): `collector_root_epoch_transitions`
  (`root_id`, `root_revision`, `previous_epoch`, `previous_cursor`,
  `next_epoch` ≠ `previous_epoch`, `requested_revision_before`,
  `requested_revision_after` > before, `owner_run_id`, `reconciled_at`;
  primary key `(root_id, requested_revision_after)`, foreign key to
  `collector_roots`).
- **Store** (`CollectorInventoryStore.reconcileNativeEpoch`): one `write`
  transaction under the owner-run check: require the root with the exact
  configuration, require the stored checkpoint to equal the one the command
  observed (`staleCheckpoint` otherwise), require a non-empty live epoch that
  differs, insert the transition row, then
  `UPDATE collector_roots SET event_epoch = NULL, event_cursor = NULL,
  requested_revision = <incremented>`. Nothing else in the row changes; cursor,
  walk and observer columns, bindings, locators and frontier stay as they are.
- **Owner**: `CollectorInventoryOwner.reconcileNativeEpoch` forwards under
  `withStore` (storage validation before and after, as for every other write).

## Invariants affected

- "Collector Event Loss Is A Root-Local Gap" (`docs/invariants.md`): the
  runtime still never rewrites a stored checkpoint after a loss and still
  stops on an epoch mismatch; this change adds no automatic path. Preserved;
  `testNativeEpochChangeStillStopsRuntimeWithoutRebasingCheckpoint` stays.
- New: "Native Epoch Reconciliation Is An Explicit Operator Action" (added to
  the ledger in this PR): the checkpoint is cleared only by the command, only
  without a running collector, and only together with a durable transition
  record in the same transaction.
- "Source and Epoch Authority Precedes Capture Replay": untouched. The
  collector/source epoch approved by HQ, sequence numbers and identity
  bindings are not read or written by this command.

## Alternatives considered

- Clear the checkpoint automatically at start when the epoch changed: rejected
  by the 2026-10-02 design (erases the epoch-change evidence, contradicts the
  native contract) and would hide reboots that lose history.
- Suspend only the affected root instead of exiting: a behaviour change the
  owner has not decided (`collector-epoch-change-scope-1`); out of scope.
- Bump the settings revision for the affected roots so re-enrollment clears
  the checkpoint: resets every per-root cursor and observer column, needs a
  settings edit on the host, and leaves no record of why.
- A launchd `--once`-style maintenance flag that also runs a cycle: mixes
  reconciliation with collection and would need credentials.

## Test plan

- `testReconcileNativeEpochClearsMismatchedCheckpointAndRecordsTransition_repro`
  (`macos/EngramServiceCoreTests/CollectorRuntimeTests.swift`): drive a
  runtime to a stored checkpoint, stop it, poison the stored epoch exactly as
  the existing epoch test does, then assert: dry run reports `mismatch` with
  the stale and live epochs and changes nothing; the apply reports `cleared`,
  nulls the checkpoint, increments `requested_revision` and writes one
  transition row with the previous epoch and cursor, the live epoch, both
  revisions, an owner run id and a timestamp; a second apply reports
  `noCheckpoint` and adds no row; the runtime then starts on the same inventory.
- `testReconcileNativeEpochRefusesWhileRuntimeOwnsInventory`: the command
  throws `busy` while a runtime holds the owner lock and succeeds after `stop`.
- Not tested: the real `launchctl bootout` / `bootstrap` sequence around the
  command (host procedure, recorded in CHANGELOG); the CLI argument matrix
  beyond compilation (the native CLI suite is gated on
  `ENGRAM_COLLECTOR_BINARY` and does not run in CI).

## Rollout

- Ships in the collector binary only; the service-index, receiver and Web
  are unchanged. Daily gets it with the next collector package
  (`macos/scripts/package-collector.sh`), installed by swapping
  `ProgramArguments[0]` in `com.engram.collector` as on 2026-10-02.
- Operator procedure on a stopped host: `launchctl bootout gui/<uid>/com.engram.collector`,
  `EngramCollector --settings <settings> --reconcile-native-epoch --dry-run`,
  review, run again without `--dry-run`, `launchctl bootstrap gui/<uid> <plist>`,
  then confirm new publications at HQ.
- Revert: remove the flag handling and the API; the transitions table is
  additive and harmless if left in place.

## Risks and open questions

- The command observes the root with the same `st_dev`/identity checks as the
  runtime; a root whose identity changed in another way reports `unavailable`
  and is left to the runtime's existing `rootIdentityChanged` handling.
- Reading the live epoch requires the FSEvents device UUID to be available for
  the volume; if it is not, the root reports `unavailable` and nothing is
  cleared.
- Whether an epoch change should end the process at all remains the owner
  decision recorded in `docs/followups.md`.
