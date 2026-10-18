# Design Doc: Collector keeps the source instance across a root revision bump, and a changed FSEvents epoch suspends only its root

- **Status**: Accepted (implemented in the same PR)
- **Owner**: Engram maintainers (Claude session, 2026-10-18)
- **Date**: 2026-10-18
- **Related**: `docs/followups.md` `collector-epoch-producer-1` (owner decision (a),
  2026-10-18) and `collector-epoch-change-scope-1` (owner decision: suspend only
  that root, 2026-10-18);
  `docs/superpowers/specs/2026-10-18-hq-collector-epoch-approval-design.md`
  (HQ `collectorApproveEpoch`, PR #477);
  `docs/superpowers/specs/2026-10-17-collector-native-epoch-reconcile-design.md`
  (`--reconcile-native-epoch`); CHANGELOG 2026-10-17 "Daily collector stopped on
  a changed FSEvents epoch".

## Problem

Two collector behaviours were left as owner decisions.

1. **Root revision bump.** A `collector_streams` row is created once per root,
   root revision and effective source with fresh UUIDs for both
   `source_instance_id` and `collector_epoch`
   (`macos/EngramCollectorCore/CollectorInventoryStore.swift:657-660` at
   `6f5c5432`), so a settings revision bump of an already registered root reaches
   HQ as a new, unregistered source instance. Its publications stay pending, and
   registering it in the source-authority file makes
   `CaptureIngestSourceRegistry.provision` throw `overlappingRoot` (UNIQUE
   machine/source/root), which aborts service-index startup. The HQ operator
   command `collectorApproveEpoch` keeps the source instance, so it cannot recover
   this case.
2. **Changed FSEvents epoch.** When a root's stored event checkpoint belongs to
   another FSEvents database UUID, `CollectorRuntime.startEventsIfNeeded` threw
   `CollectorRuntimeError.reconciliationRequired`
   (`macos/EngramCollectorCore/CollectorRuntime.swift:541-545` at `6f5c5432`),
   which stopped the whole runtime, uploads for every other root included. On
   2026-10-17 a Daily reboot left seven of sixteen roots on a stale epoch; the
   collector exited 70 on every launchd restart (882 runs in about 2.5 h) and HQ
   received nothing until a manual recovery.

## Goals / Non-goals

- Goals:
  - (a) For the same root, source and root path, a revision bump keeps the
    source instance and rotates only the collector epoch, so HQ's
    `collectorApproveEpoch` becomes the recovery path. Existing rows are never
    rewritten.
  - A changed native epoch suspends only that root: no checkpoint rebase, no walk
    or live capture from it, one stderr line when the suspended set changes,
    other roots and both upload loops keep running. `--reconcile-native-epoch`
    still clears it, and the root resumes on the next start.
- Non-goals: a spool or inventory wipe that loses the stored instance id (it
  still arrives as a new instance; operator runbook limitation below); an HQ
  source-instance retire/rebind design (option (b)); any HQ code change; any
  automatic epoch approval or automatic checkpoint reconciliation; delivering
  publications staged under a superseded root revision (see Risks).

## Current state

At `6f5c5432`:

- **HQ binding.** `capture_ingest_source_registry` is keyed by
  `(machine_id, source_instance_id)` and stores `source`, `parse_format`,
  `configured_root`, `approved_epoch` and `authority_generation`, with
  `UNIQUE (machine_id, source, configured_root)`
  (`macos/EngramCoreWrite/CaptureIngest/CaptureIngestSourceRegistry.swift:111-136`).
  HQ never sees a root id or root revision: `CollectorPublicationEnvelope`
  carries only machine, source instance, collector epoch, sequence, manifest
  digest and representation
  (`macos/Shared/EngramCore/ArchiveV2/CollectorPublicationModels.swift:47-90`).
  Eligibility requires the manifest source to equal the binding's source and the
  locator to sit under the configured root, and then the publication epoch to
  equal the approved epoch (`CaptureIngestSourceRegistry.swift:222-252`). The
  ingest worker claims only approved-epoch publications
  (`macos/EngramService/Core/ServiceCaptureIngestWorker.swift:319-350`).
- **Sequence.** Every HQ and replica key includes the epoch: the ledger conflict
  check (`macos/EngramCoreWrite/CaptureIngest/CaptureIngestLedger.swift:341`,
  `:454`), the stream index (`:229-230`) and the replica journal key
  `PublicationSequenceKey` (`macos/EngramRemoteServer/Core/ArchiveStore.swift:479-490`).
  The committer orders generations of one identity by authority generation and
  compares sequences only within one generation
  (`macos/EngramCoreWrite/CaptureIngest/CaptureIngestCommitter.swift:547-553`);
  approval always increments the generation. Collector-side,
  `collector_publications` is `UNIQUE(source_instance_id, collector_epoch, sequence)`
  (`CollectorInventoryStore.swift:2296`).
- **Session identity.** The HQ peer is `capture-v1.<machine>.<source instance>`
  (`macos/EngramCoreWrite/CaptureIngest/CaptureIngestIdentity.swift:33`), so a
  new instance turns every re-captured session into a second session row, while
  a kept instance continues the same session as a newer generation.
- **Collector root revision.** `registerRoot` updates `collector_roots` in place
  on a revision bump, including `source` and `root_path`
  (`CollectorInventoryStore.swift:83-119`), and is reached from
  `CollectorInventoryOwner.enrollAndActivateRoot`. Old locator, binding and
  stream rows stay fenced by their revision. The old root path is not recorded
  anywhere else, so the bump is the only point where both the old and the new
  configuration are known.
- **Epoch mismatch.** `CollectorEventCoordinator.start(epoch:)` requests a
  `.restart` reconciliation, then on a stored checkpoint from another epoch
  records a `continuityLoss` gap and stays `recoveryRequired`
  (`macos/EngramCollectorCore/CollectorEventCoordinator.swift:210-222`); each of
  those writes advances `requested_revision`. The runtime then threw. The
  identity-change path instead calls `suspendSource`, keeps the root out of the
  capture set and reports `identitySuspendedRoots` once per change
  (`CollectorRuntime.swift:474-488`, `:548-570`).

## Verification results for option (a)

1. *What HQ binds an instance to*: machine, source, parse format and configured
   root, plus the approved epoch and generation. Not the root id, not the root
   path history, not the root revision; the envelope carries no revision, so HQ
   cannot check one.
2. *Sequence restarting at 1 under a new epoch for the same instance*: accepted.
   All keys include the epoch and ordering uses the authority generation first,
   so the new stream row starts at `last_sequence = 0` and the sequence is **not**
   carried forward. Carrying it would add no safety and would blur the "new epoch
   branch" model the 2026-09-05 design assumes.
   `testRotatedEpochWithRestartedSequenceContinuesSessionAfterApproval` shows a
   sequence-1 publication on the approved new epoch continuing a session first
   committed at sequence 9.
3. *Root path or source changes*: a kept instance would be quarantined at HQ
   (`locatorOutsideRoot` or `sourceMismatch`), which is worse than today's
   pending unknown instance. Rule: **keep the instance only when the root's
   source and its byte-exact root path are unchanged; otherwise mint a new
   instance at the new revision's first capture, as before.** Cursor layout
   flags do not take part in the HQ binding and do not affect the rule. The
   collector inventory does not record the settings `parseFormat`, so a
   parse-format change on the same path keeps the instance while HQ keeps the
   format it registered (`provision` refuses to change a known instance's
   format); a parse-format change needs a new root id (limitation).
4. *Existing rows*: nothing is rewritten. The carry runs only inside a future
   revision bump, so Daily's current stream rows keep their instance and epoch
   until its next bump. Publications already staged under the old
   (instance, epoch) stay valid envelopes and stay claimable at HQ while the old
   epoch is the approved one.
5. *Finding: approval breaks the next HQ start unless the source-authority file
   is edited.* `provision` accepts an existing binding only when the file's
   `initialEpoch` equals the current approved epoch
   (`CaptureIngestSourceRegistry.swift:167-171`), and the service provisions
   from that file on every start when `--capture-source-authority-file` is passed
   (`macos/EngramService/Core/EngramServiceRunner.swift:460-463`). After
   `collectorApproveEpoch`, an unchanged file throws `sourceInstanceConflict` and
   aborts startup. This is not specific to (a); it applies to every approval. It
   is handled in the runbook, not in code (Alternatives).
6. *Finding (pre-existing): publications staged under a superseded revision are
   never uploaded.* `claimPublications` and the claim revalidation join
   `collector_roots` on the current `root_revision`
   (`CollectorInventoryStore.swift:864`, `:1833`); reservation recovery does the
   same (`:707`). The rows stay valid but stop being claimable after a bump. Not
   changed here; the runbook drains a root before bumping it.

## Proposed design

- **(a) Stream carry** (`CollectorInventoryStore.registerRoot`, new private
  `carrySourceInstances`): in the revision-bump branch, after the existing
  `UPDATE`, if `existing.configuration.source == new.source` and the root paths
  are byte-equal, copy every stream row of the previous stored revision whose
  `effective_source` is not empty into the new revision with the same
  `source_instance_id`, a fresh `UUID()` collector epoch and `last_sequence = 0`,
  in the same transaction. The previous revision is the stored one, so skipped
  revision numbers work. A claude-code root's `minimax` and `lobsterai` streams
  are carried individually, each keeping its own instance. An empty effective
  source is an unresolved pre-schema-10 row and is never carried. The lazy
  `INSERT OR IGNORE` at reservation time then finds the carried row; an effective
  source first seen after the bump still mints a fresh instance. No schema
  change.
- **Per-root epoch suspension** (`CollectorRuntime.startEventsIfNeeded`): the
  mismatch check stays where it was, but instead of throwing it calls
  `suspendSource` (stops and drops the coordinator, keeps the root activated for
  delivery), records the index in `epochSuspendedRoots`, and skips the root.
  Later turns skip indices in that set before enrolling or starting a
  coordinator, so the root is not retried for the rest of the process; retrying
  would repeat the coordinator's `.restart` and `continuityLoss` writes every
  poll turn, and the only way out, `--reconcile-native-epoch`, needs the owner
  lock and therefore a stopped collector. `reportEpochSuspensionsIfChanged`
  writes `engram-collector: source roots suspended for native epoch change: N/M
  (ids)`, with `; capture stopped` when every root is suspended, each time the
  set changes. The root is absent from the capture set, so `--once` counts it in
  `deferred`. Publications already staged for that root, and reservations whose
  bytes were already frozen in the capture store, still deliver, exactly as for
  an identity suspension; nothing new is read from the root.
- `CollectorRuntimeError.reconciliationRequired` had no other producer and is
  removed. The `EngramCollector --help` text names the new stderr line.

### Operator runbook

- **FSEvents epoch changed** (stderr `source roots suspended for native epoch
  change`): the collector keeps running for the other roots. Then
  `launchctl bootout gui/<uid>/com.engram.collector`,
  `EngramCollector --settings <settings> --reconcile-native-epoch --dry-run`,
  review, run again without `--dry-run`, `launchctl bootstrap gui/<uid> <plist>`.
  The command refuses with `busy` while the collector runs. The root resumes on
  that start with a full walk. HQ needs nothing: the collector epoch is
  unchanged. Do not bump the root revision for this; a bump now rotates the
  collector epoch and requires an HQ approval.
- **Root revision bump** (same source and path, for example to re-enroll a root
  whose directory identity changed):
  1. Before the bump, wait until the root has no non-acknowledged publication
     for either replica; staged publications of the old revision are not
     uploaded after it (finding 6).
  2. Bump the revision, restart the collector. New publications carry the same
     source instance and a new collector epoch.
  3. On HQ, as the service-index user:
     `EngramCLI collector-epoch dry-run --machine-id <m> --source-instance-id <i>
     --candidate-epoch <current approved epoch>` lists the new epoch under
     `observedUnapprovedEpochs`. Run it again with that epoch as the candidate
     and wait until `currentBacklog.ledgerTaskCounts` shows no `pending`,
     `processing` or `failed_retryable` work: publications of the old epoch that
     are still pending at approval stay pending for good.
  4. With owner authorization, `EngramCLI collector-epoch approve ...
     --expected-epoch <current approved epoch> --expected-authority-generation
     <current generation>`.
  5. Before the next service-index restart, set that entry's `initialEpoch` in
     the source-authority file to the newly approved epoch (finding 5). Until
     then a restart fails with `sourceInstanceConflict`.
- **Known limitation, spool or inventory wipe**: a wiped or re-initialized
  inventory loses its stream rows, so the next capture mints a new source
  instance for an already registered root. That still needs option (b) (HQ
  retire/rebind) or a manual HQ procedure; this change does not cover it.
- **Known limitation, path or parse-format change**: a new root path or source
  mints a new instance, which hits `overlappingRoot` if it overlaps the old
  registered root. A parse-format change needs a new root id.

## Invariants affected

- New: "Collector Root Revision Bump Keeps The Source Instance".
- "Collector Event Loss Is A Root-Local Gap": its "only a stored checkpoint whose
  FSEvents epoch differs from the live epoch stops the runtime" sentence becomes
  "suspends that root for the process lifetime"; the no-rebase guarantee is
  unchanged.
- "Native Epoch Reconciliation Is An Explicit Operator Action": the runtime fails
  closed for that root instead of ending the process; the command, its owner
  lock and its transition record are unchanged.
- "Collector Epoch Approval Is A Local Operator Action": a same-source,
  same-path revision bump is now covered; a spool wipe is still not, and the
  authority-file step is named.
- "Source and Epoch Authority Precedes Capture Replay": untouched; no HQ code
  changes and approval stays explicit.
- "Collector Root Binding Survives Device Renumbering Only": untouched; the
  rebind still leaves revision, instance, epoch and sequence unchanged.

## Alternatives considered

- Carry the instance lazily at reservation time: the old root path is overwritten
  in place by the bump, so the reservation cannot tell a path change from a
  plain revision bump without a new column.
- Also carry `last_sequence`: no HQ or replica key needs it (verification 2).
- Keep the instance even when the path changes: HQ would quarantine the new
  publications against the old configured root.
- Relax HQ `provision` to accept any previously approved epoch as `initialEpoch`:
  a small change, but it alters the "never approves a later epoch" contract of
  the authority file and needs an HQ deploy; the runbook step keeps this change
  collector-only. Recorded for a later owner decision.
- Retry an epoch-suspended root every turn: no automatic recovery is possible
  (the reconcile command needs the owner lock) and every retry writes two
  reconciliation requests.
- Pre-check the epoch before starting the coordinator: would avoid the one
  `.restart` and gap write at detection, but moves the check away from the
  existing guard for no behavioural gain.

## Test plan

- `testRootRevisionBumpKeepsSourceInstanceAndRotatesEpoch_repro`
  (`macos/EngramServiceCoreTests/CollectorRuntimeTests.swift`): capture under
  revision 1, bump to 3 with the same path, capture again: the revision-3 stream
  keeps the instance, has a new epoch, its publications start at sequence 1, the
  revision-1 row is unchanged, and both in-process replicas accept every
  publication. Fails before the change (new instance).
- `testRevisionBumpCarriesSourceInstancesOnlyForUnchangedSourceAndPath`
  (`macos/EngramCollectorCoreTests/CollectorInventoryStoreTests.swift`): carries
  claude-code and minimax streams individually with distinct fresh epochs and
  sequence 0, never carries the empty-source row, never rewrites old rows, and
  carries nothing after a path or source change.
- `testChangedNativeEpochSuspendsOnlyThatRoot_repro`
  (`CollectorRuntimeTests.swift`, replaces
  `testNativeEpochChangeStillStopsRuntimeWithoutRebasingCheckpoint`): two roots,
  one with a stale epoch. `start()` does not throw, the healthy root's new file
  reaches both replicas, exactly one suspension line, the stale checkpoint is
  unchanged, the suspended root's new file is never walked, its
  `requested_revision` does not move over about ten turns, and after
  `reconcileNativeEpoch` the next start captures it with no new line. Fails
  before the change (`reconciliationRequired`).
- `testRotatedEpochWithRestartedSequenceContinuesSessionAfterApproval`
  (`macos/EngramServiceCoreTests/ServiceCaptureIngestWorkerTests.swift`): the HQ
  half with the producer's exact shape. The rotated-epoch publication stays
  unclaimed, `collectorEpochDryRun` lists it, `collectorApproveEpoch` approves
  it, and it commits as a newer generation of the same session.
- Not tested: a real FSEvents database UUID change (tests poison the stored
  epoch); a single in-process run from collector to HQ ingest (the collector
  half ends at the replicas' acceptance, the HQ half starts from an accepted
  publication; the real-binary chain is gated on built binaries); the
  source-authority restart conflict (runbook only).

## Rollout

- Collector binary only. Daily gets it with the next collector package
  (`macos/scripts/package-collector.sh`), installed as on 2026-10-17. No
  inventory migration; the carry applies only to revision bumps after the
  deploy.
- HQ needs no build from this change. The recovery path depends on
  `collectorApproveEpoch` (PR #477) being deployed on the HQ service-index and
  `EngramCLI`.
- Revert: restore the throw and drop the carry call. Carried stream rows stay
  valid; they only mean a later bump of that root kept its instance.

## Risks and open questions

- Approval followed by a service-index restart without the authority-file edit
  aborts startup (finding 5). Whether the HQ plist passes
  `--capture-source-authority-file` is not visible from the repo.
- Publications staged under a superseded revision are stranded on the collector
  (finding 6, pre-existing).
- A suspended root stays suspended until the collector restarts after the
  reconcile command; the stderr line is the only signal besides the dry run.
