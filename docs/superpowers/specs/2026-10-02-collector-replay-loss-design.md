# Design Doc: Collector event replay loss is a root-local gap, not a process exit

- **Status**: Draft
- **Owner**: collector maintainers
- **Date**: 2026-10-02
- **Related**: `2026-10-02-collector-volume-identity-design.md` (risk "FSEvents
  epoch"); `2026-09-05-collector-server-web-design.md` §3; plan
  `docs/superpowers/plans/2026-09-05-collector-server-web.md` (N3-B2 native
  adapter contract).

All `path:line` anchors are at commit `65390b43` (before this change).

## Problem

After the volume-identity fix was deployed to the daily collector host on
2026-10-02, the collector captured again, but launchd restarted it about every
12 s (`last exit code = 70`). Each start printed `running` and then
`engram-collector: runtime failed`. The same loop wrote 20,142 identical lines
between 2026-09-13 and 2026-09-22. Two roots (cursor, grok) showed
`requested_revision` near 985,000 against `completed_revision` 3,089 and 151:
they had not converged in weeks.

## Current state

- Five roots store an FSEvents checkpoint. Each coordinator start resumes a
  FullHistory replay from it
  (`macos/EngramCollectorCore/CollectorEventCoordinator.swift:218-220`,
  `CollectorNativeEventStream.swift:177-181`).
- A replay from an old cursor reports a loss. Possible causes are dropped events,
  MustScanSubDirs/RootChanged/EventIdsWrapped, a directory removal, an unknown
  item type, more paths per callback than the budget, or more queued batches than
  the budget while recovery holds them (`CollectorNativeEventStream.swift:392-426`,
  `CollectorEventCoordinator.swift:512-517`). The history between the stored
  cursor and the present does not change, so every replay reports the same loss.
- A loss is recorded as a durable gap. The gap bumps `requested_revision` and
  forces a full walk (`CollectorEventCoordinator.swift:481-497`,
  `CollectorInventoryStore.swift:1386-1391`). By design the gap never advances
  or clears the checkpoint (plan N3-B2: "never advances a checkpoint"). The next
  start therefore replays the same history and loses again. That adds 2
  revisions per cycle, and recovery (`completed >= requested`) never converges.
- Exit: callbacks run on the stream's own queue. A loss admitted between
  `accepting = true` (`CollectorEventCoordinator.swift:224`) and the runtime's
  phase check (`CollectorRuntime.swift:458-461`) leaves the coordinator
  `.recoveryRequired`. The runtime then throws `reconciliationRequired`, which
  is meant for a changed native epoch. `main.swift:147-161` maps it to exit 70
  with no reason. The check is a race, but it is re-run on every restart cycle
  of every looping root, so an exit follows within seconds to minutes.

## Proposed design

1. **Runtime** (`CollectorRuntime.startEventsIfNeeded`). The runtime throws
   `reconciliationRequired` only when the coordinator is `.recoveryRequired`
   *and* the stored checkpoint epoch differs from the live FSEvents epoch. A
   stream loss leaves the root available. Its gap is persisted, the next turn
   restarts the stream, and other roots and both upload loops keep running.
   This is the designed response (design §3: "an overflow or missed-event
   indication requests reconciliation").
2. **Coordinator**. Once a loss gap is durable (any reason except a plain
   `.restart` stop, including an Owner-side reconciliation result), later starts
   of that coordinator subscribe without resuming the stored checkpoint (native
   SinceNow plus synthetic HistoryDone). The forced full walk starts after the
   new subscription, so walk plus stream still cover everything. The stored
   checkpoint is not rewritten. The first batch applied after recovery advances
   it past the poisoned history, so a later process resumes cleanly. The flag is
   per coordinator instance (in memory). A new process tries the stored
   checkpoint once more, which costs at most one extra gap per process start.
3. **Observability**. The exit line is
   `engram-collector: runtime failed: <Type>.<case>`, for example
   `CollectorRuntimeError.reconciliationRequired`. It contains type and case
   names only, never payloads or descriptions
   (`CollectorRuntime.failureReason`).

No schema, settings, environment, receiver or HQ change is needed.

## Invariants affected

There is no existing ledger entry. Draft entry (not added here):

> ## Collector Event Loss Is A Root-Local Gap
> - **Statement** - An event-stream loss (overflow, kernel/user drop,
>   structural flag, budget) records a durable gap that forces a full walk of
>   that root only. It never ends the collector process and never rewrites the
>   stored checkpoint. After a loss the coordinator does not replay the same
>   stored history again. Only a changed FSEvents database UUID (epoch) stops the
>   runtime, and it never rebases the checkpoint. A process-ending failure is
>   reported as one stderr line naming the error type and case.
> - **Enforced by** - `macos/EngramCollectorCore/CollectorRuntime.swift`,
>   `macos/EngramCollectorCore/CollectorEventCoordinator.swift`,
>   `macos/EngramCollector/main.swift`.
> - **Verified by** - `CollectorEventCoordinatorTests`
>   (testReplayLossFromStoredCheckpointConvergesWithoutReplayingItAgain_repro,
>   testRestartResumesOnlyDurableCheckpointAndEpochMismatchCannotRebase),
>   `CollectorRuntimeTests`
>   (testReplayLossDuringStartKeepsRuntimeAndOtherRootsRunning_repro,
>   testNativeEpochChangeStillStopsRuntimeWithoutRebasingCheckpoint,
>   testFailureReasonNamesErrorTypeAndCaseWithoutPayload).
> - **Gate** - `none`.

## Alternatives considered

- **Clear the stored checkpoint when a gap is persisted.** This converges
  durably, but it contradicts the native contract ("loss never advances a
  checkpoint", mismatched epochs "fail closed without rebasing") and the
  existing tests that pin the checkpoint after a loss. It would also erase the
  epoch-change evidence.
- **Always subscribe SinceNow.** Every start already forces a full walk, so
  this would be safe too. It is a wider behavior change than the failure
  requires.
- **Retry the replay with backoff.** The same history loses deterministically,
  so this only slows the loop.

## Test plan

- `CollectorEventCoordinatorTests.testReplayLossFromStoredCheckpointConvergesWithoutReplayingItAgain_repro`
  uses a fake stream that loses on the poisoned cursor. RED: the second start
  replays the poisoned cursor again and never leaves `.recoveryRequired`.
- `CollectorRuntimeTests.testReplayLossDuringStartKeepsRuntimeAndOtherRootsRunning_repro`
  delivers the loss synchronously inside stream start, which hits the race
  deterministically. RED: `start()` throws `reconciliationRequired`. GREEN: both
  roots capture, both replicas acknowledge, the root converges and the
  checkpoint is unchanged.
- `testNativeEpochChangeStillStopsRuntimeWithoutRebasingCheckpoint` (guard)
  and `testFailureReasonNamesErrorTypeAndCaseWithoutPayload`.
- `CollectorCLIIntegrationTests` credential cases assert the new stderr line
  on the real binary.
- Not tested: real FSEvents history truncation. The native adapter's flag
  mapping is covered by `CollectorNativeEventStreamTests`.

## Rollout

Same packaging as the volume-identity build. On first start, each stale
checkpoint is tried once. A losing root records one gap, restarts SinceNow and
walks. Revert by reinstalling the previous package. No stored state is changed
in a way the old build rejects.

## Risks and open questions

- A quiet root whose checkpoint is still poisoned is replayed once per process
  start, which costs one extra gap and walk. This is bounded, but it is not
  durable convergence until the root's next applied batch.
- An epoch change still ends the process, so uploads stop and launchd restarts
  every 10 s. It is now visible on stderr. Whether to suspend only that root
  instead, like `rootIdentityChanged`, is an owner decision.
