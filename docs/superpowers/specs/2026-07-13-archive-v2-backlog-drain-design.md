# Archive V2 Backlog Drain Design

**Date:** 2026-07-13

**Status:** Approved in conversation

## Goal

Drain Archive V2 capture, binding, policy, and dual-replica backlogs continuously
while work is available, without tying backlog throughput to the adaptive indexing
schedule. The service must remain resource-conscious, preserve capture-before-parse
and dual-receipt safety, and become idle without polling when no work is runnable.

## Problem

Archive V2 currently runs inside the periodic indexing cycle. That creates two
independent throughput defects:

1. archive backlog work inherits the indexing scheduler's adaptive 15, 30, or 60
   minute delay even when the archive queue is non-empty; and
2. one `batchSize` value, currently defaulting to 20, limits capture, binding,
   policy, and replication, while HQ and M1 replica rows share the replication
   allowance.

The replication coordinator also processes claimed replica rows sequentially. A
transport failure can therefore consume a shared batch with retries while useful
work for the other replica waits. Raising the batch or shortening the indexing
interval would change the constants but would not correct these couplings.

## Constraints

- Preserve exact capture before parsing for supported Claude Code and Codex source
  files.
- Preserve immutable CAS publication, generation validation, independent HQ and
  M1 verification, receipt validation, retry jitter, stale-claim recovery, and
  reclamation gates.
- Do not add a persistent locator inventory, FSEvents integration, a new event
  database, or user-facing performance tuning controls.
- Do not poll while the archive is idle.
- Pause discretionary work in Low Power Mode or under serious or critical thermal
  pressure.
- Keep the existing indexing schedule for discovery, indexing, and unrelated
  maintenance work.
- Keep all work single-flight at the archive-cycle level and respect service
  cancellation.

## Considered Approaches

### A. Shorter schedule and larger shared batch

Run the existing periodic cycle more often and raise `batchSize`.

This is the smallest code change, but it keeps archive work coupled to indexing,
causes idle wakeups, preserves cross-stage contention, and replaces one hard
throughput ceiling with another. It is not selected.

### B. Independent backlog-driven drain worker

Keep the real-time capture barrier in the indexing path, but hand historical and
durable backlog work to an event-driven worker. Give each stage a separate bounded
budget, let HQ and M1 advance independently, and continue with short cool-downs
while runnable work remains.

This corrects the coupling without introducing durable discovery infrastructure.
It is selected.

### C. Persistent locator inventory maintained by FSEvents

Create a durable source-file queue and maintain it incrementally from filesystem
events.

This can avoid full discovery scans across restarts, but requires a new schema,
event-gap recovery, rebuild semantics, and substantially more operational state.
It is disproportionate to the current corpus and is not selected.

## Architecture

Archive V2 is split into two cooperating paths.

### Real-time safety path

```text
discover recent source changes
        |
        v
capture the exact generations that are about to be parsed
        |
        v
index only capture-safe exact locators
        |
        v
bind sessions and enqueue replica rows
        |
        v
signal the backlog drainer
```

This path remains synchronous with the periodic index cycle where required to
preserve capture-before-parse. A source that fails exact capture is not allowed to
bypass the existing exact-locator index plan.

### Historical backlog path

```text
one locator discovery
        |
        v
process-local ordered locator snapshot
        |
        v
capture -> bind -> policy -> HQ queue + M1 queue
        |                         |
        +------ continue --------+
               while runnable
```

The discovered locator snapshot is process-local. The drainer consumes it across
multiple capture batches without re-enumerating the full source tree between
batches. A service restart discards the snapshot and performs discovery again.
Generation checks at capture time remain authoritative, so a stale snapshot cannot
publish stale or mixed bytes.

## Components

### `ArchiveV2BacklogDrainer`

Add one actor-owned worker to the service composition. It owns:

- a coalescing work signal;
- a single worker task;
- the current drain state and stage;
- the in-memory historical locator snapshot and cursor;
- the next retry wake deadline; and
- cancellation and shutdown coordination.

The actor never runs two drain passes concurrently. Multiple signals collapse into
one pending wake. It waits without a timer when no runnable work exists.

### Existing archive coordinator

`ArchiveV2ServiceCoordinator` remains the authority for exact capture, binding,
policy, status, and single-flight archive operations. Its current all-in-one batch
entry points are separated into bounded stage operations that the drainer can call
without invoking the index scan again.

The periodic index integration retains the recent-file capture barrier and signals
the drainer after it creates any historical capture work, new binding, policy
decision, replica row, manual retry, or newly due retry.

### Replica coordinator and catalog

Replica claiming becomes replica-specific and fair between pending work and due
retry work. HQ and M1 each retain serial processing, but one HQ task and one M1 task
may run concurrently. Existing compare-and-set claim generations, heartbeat,
state transitions, and stale recovery remain unchanged.

## Worker Lifecycle

The worker starts after initial archive discovery and initial indexing are ready.
It may be awakened by:

- service startup completion;
- a periodic discovery or index cycle producing archive work;
- a productive drain pass that leaves runnable backlog;
- the earliest `nextRetryAt` becoming due;
- a user-requested retry; or
- a `ProcessInfo` power-state or thermal-state notification after a resource
  pause.

The worker stops claiming new work when the service is cancelled. It waits for the
current bounded operation to reach its existing cancellation point, then exits.
Claims interrupted by process termination remain recoverable through the current
stale-claim protocol.

When a pass finds no runnable work, it either waits until the exact earliest retry
deadline or waits indefinitely for a work signal. It does not use a fixed idle
poll interval.

## Resource Budgets

Each productive pass uses separate internal defaults:

| Stage | Per-pass budget |
| --- | ---: |
| Historical capture | 32 files or 128 MiB of source bytes |
| Binding | 100 rows |
| Remote policy | 100 rows |
| HQ replication | 16 replica rows |
| M1 replication | 16 replica rows |
| Active wall-clock slice | approximately 10 seconds |
| Productive-pass cool-down | 2 seconds |

Capture ends when it reaches the first applicable file, byte, or time boundary. A
single source file may complete even when it crosses the remaining byte or time
budget; the worker then yields before beginning another file. Binding and policy
retain short database transactions.

The counts are yield boundaries, not per-window throughput ceilings. If runnable
work remains, the worker begins another pass after the two-second cool-down.

These values are implementation constants, not settings. Changing them requires
focused tests and runtime evidence; the settings page does not expose tuning
controls.

All worker tasks run at background or utility priority. Capture and local catalog
stages do not run concurrently with each other. Remote processing has a global
maximum of two active tasks: at most one for HQ and one for M1.

Before claiming each new unit of work, the worker checks cancellation, Low Power
Mode, and thermal state. Low Power Mode or serious/critical thermal pressure moves
the worker into a paused state without changing queue rows. The service subscribes
to the corresponding `ProcessInfo` power-state and thermal-state notifications and
signals the worker when conditions change. This avoids a high-frequency condition
poll and does not depend on unrelated archive work arriving before the worker can
resume.

## Replica Fairness and Failure Handling

Each replica claims up to 16 rows per pass. When both classes exist, the initial
allocation is up to eight due retry rows and eight pending rows. Either class may
borrow unused capacity from the other. Ordering inside each class remains oldest
first with deterministic digest tie-breaking.

Failure behavior is scoped as follows:

- A transient transport failure, HTTP 408, HTTP 429, or HTTP 5xx schedules the
  existing exponential full-jitter retry for the current row and stops that
  replica's remaining work for the current pass. This prevents a known outage from
  converting the rest of a batch into immediate failures. The other replica keeps
  running.
- Authentication or replica-configuration failure pauses that replica immediately
  and presents an attention state. It does not walk the remaining queue and mark
  every row with the same infrastructure error. A manual retry, or a service
  restart after correcting configuration or credentials, can resume it.
- A row-specific local object, manifest, binding, receipt, or remote verification
  contradiction follows the current quarantine policy for that row. Other rows
  and the other replica may continue.
- A source generation change, disappearance, or unsafe identity during historical
  capture cannot publish a manifest. It returns to discovery/retry according to
  the existing capture classification.
- A lost compare-and-set claim is counted and skipped; it is never overwritten.

Manual retry resets only the requested replica or replicas under the existing
contract and signals the worker immediately.

## Observability

Extend the bounded Archive V2 status response rather than adding an event store.
Add:

- `drainState`: `idle`, `draining`, `waitingRetry`, `pausedLowPower`,
  `pausedThermal`, or `needsAttention`;
- `activeStages`: a bounded, deterministically ordered collection containing
  `capture`, `binding`, `policy`, `hq`, or `m1`; only `hq` and `m1` may appear
  together;
- `lastDrainPass`: start and finish timestamps, duration, stage counts, captured
  bytes, retry count, quarantine count, and cancellation state; and
- `nextWakeAt`: present only when a retry deadline is scheduled.

Existing per-replica pending, retry, verified, oldest-outstanding, retry-reason,
and remote telemetry fields remain authoritative. The CLI retains exact symbolic
errors. The settings page localizes drain state and stage names and continues to
use its existing refresh mechanism; this change does not add a permanent polling
loop.

Emit at most one bounded service log entry per completed drain pass. It may contain
state, duration, counts, and captured bytes. It must not contain source paths,
locators, session IDs, capture IDs, manifest hashes, URLs, credentials, response
bodies, or transcript content.

## Testing

Use failing-then-passing focused tests for:

- coalesced work signals and strict single-flight behavior;
- two consecutive productive passes without an indexing-scheduler wake;
- no timer wake while idle;
- wake at the earliest due retry;
- cancellation before each stage and clean shutdown;
- Low Power Mode and thermal pause/resume transitions;
- in-memory locator snapshot reuse across capture batches;
- restart behavior that rebuilds the locator snapshot;
- unchanged capture-before-parse integration;
- independent HQ/M1 claiming and maximum concurrency of one per replica;
- fair pending/retry allocation with unused-capacity borrowing;
- stopping one replica's batch after a transient infrastructure failure;
- continued progress for the healthy replica;
- auth/config pause without mass queue mutation;
- row-specific quarantine without pipeline blockage;
- bounded status DTO validation and backward-compatible decoding;
- Simplified Chinese localization for every new settings label; and
- source-level checks preserving the settings page's no-polling behavior.

Run the focused Archive V2 core, service, and app tests, then the Engram Debug
build. Before deployment, run the release verifier against the built app.

After local installation, observe a real backlog for at least 30 minutes. Compare
settings status with `EngramCLI archive status --json`, verify that both replicas
continue to advance, sample service CPU and memory for sustained growth, and check
logs for repeated-request storms or sensitive fields.

## Acceptance Criteria

1. Runnable archive backlog executes at least two consecutive drain passes without
   waiting for the indexing scheduler.
2. An empty archive produces no periodic worker wakeups.
3. A failed HQ does not stop M1, and a failed M1 does not stop HQ.
4. One transient transport failure stops the affected replica's remaining pass
   instead of failing every claimed row.
5. Low Power Mode and serious/critical thermal pressure prevent new claims, and
   work resumes without queue repair.
6. Same-replica concurrency never exceeds one and global remote concurrency never
   exceeds two.
7. New exact-source indexing still satisfies capture-before-parse.
8. Restart discovery and stale-claim recovery restore progress without persistent
   locator state.
9. Settings and CLI agree on worker state, last pass, replica counts, and next
   retry time.
10. A 30-minute installed-runtime observation shows continuing queue reduction,
    no sustained high CPU, no unbounded memory growth, and no repeated-request
    storm.

## Non-Goals

- Changing archive durability, receipt, recovery-drill, reclamation, or deletion
  gates.
- Adding exact-source support for adapters beyond Claude Code and Codex.
- Adding a persistent locator queue or FSEvents watcher.
- Exposing batch, byte, concurrency, or cool-down values in settings.
- Adding server-side scheduling or cross-server coordination.
- Promising a fixed completion time before measuring the installed implementation
  against the real corpus and network.

## Rollout and Rollback

Ship the worker behind the existing Archive V2 enablement; do not add a second
user-facing feature switch. Deployment follows the existing local release and
remote compatibility process. No RemoteServer wire change is required because
the scheduling and claim changes are client-side; existing remote telemetry
remains compatible.

Rollback is the previous app/service build or disabling Archive V2 in settings.
All catalog rows, CAS objects, remote objects, manifests, and receipts remain
compatible because this design changes scheduling and status only, not archive
formats or durability semantics.
