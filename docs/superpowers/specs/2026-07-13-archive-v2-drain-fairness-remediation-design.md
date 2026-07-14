# Archive V2 Drain Fairness Remediation Design

**Date:** 2026-07-13

**Status:** Approved in conversation (Approach A)

> **2026-07-14 throughput amendment:** The original one-failure breaker below
> proved too coarse under sporadic transport errors. Current behavior permits
> one bounded next-claim health probe inside the same replica batch. A verified
> probe clears the candidate breaker and the batch continues; a second transient
> failure, no available probe, or a closed resource gate opens the existing
> 60-second breaker. This amendment supersedes statements below that say every
> first transient failure immediately releases the rest of the batch or limits
> outage traffic to exactly one failed claim per minute. Durable row jitter,
> replica independence, serial per-replica processing, and all safety boundaries
> remain unchanged.

## Goal

Restore continuous HQ and M1 progress while a large local capture, indexing, and
binding backlog is also active. A transient failure for one receipt must retain
row-level exponential backoff without pausing every pending receipt for that
replica for hours. The existing ten-second pass budget, two-second productive
cool-down, exact-capture safety, and resource gates remain in force.

## Production Evidence

The installed build `1.0.4 (1167)` at revision
`9ed58a0e01df415971b9b5161cad9894388aa7cf` produced the following bounded
monitoring evidence on 2026-07-13:

- local binding advanced from 8,086 to 8,138 while unbound captures fell from
  8,843 to 8,795;
- dual-replica verification remained fixed at 4,398;
- HQ had 2,969 queued eligible rows and M1 had 1,607 queued eligible rows;
- repeated replication cycles reported `claimedCount = 0` and
  `verifiedCount = 0`;
- both remote health endpoints returned `ok`, both reported zero server errors,
  and neither replica had quarantined work; and
- individual `transport_network` retry rows carried deadlines hours in the
  future while all ordinary pending rows had no row-level retry deadline.

The implementation retains a replica-wide in-memory retry pause after one
transient infrastructure failure. While that pause is present, claiming returns
no HQ or M1 work even when thousands of unrelated eligible pending rows exist.
Separately, every backlog pass currently orders capture, indexing, and binding
before replication under one ten-second admission deadline. A large local unit
can therefore repeatedly leave no admission time for remote work.

## Constraints

- Preserve immutable CAS data, manifests, receipts, remote formats, retry rows,
  stale-claim recovery, recovery drills, reclamation gates, and zero-delete
  behavior.
- Preserve row-level exponential full-jitter retry deadlines exactly; the
  remediation independently rate-limits the additional replica-wide circuit
  breaker to one failed request per replica per minute.
- Preserve a maximum of one active claim processor per replica and two globally.
- Preserve the existing ten-second active pass slice and two-second productive
  cool-down; do not add a polling loop or another worker.
- Preserve Low Power Mode, thermal-pressure, cancellation, and writer-gate
  admission checks.
- Do not add user-facing tuning controls, persistence tables, dependencies, or
  RemoteServer protocol changes.
- Keep Simplified Chinese and English settings text complete.

## Considered Approaches

### A. Bounded circuit breaker plus alternating pass priority

Keep per-row exponential backoff. Hold the additional replica-wide transient
pause for 60 seconds after a failure and alternate each backlog pass between
remote-first and local-first execution. Expose the effective replica pause and
next pass priority through the existing bounded status response.

This preserves outage backpressure, guarantees admission opportunities for both
local and remote work, and requires no new worker or durable state. It is
selected.

### B. Remove replica-wide pause

Retry only the failed row and immediately let the next pending row run. This is
smaller, but a real remote outage would cause a new network attempt on every
productive pass. It is rejected because it can create a request storm.

### C. Separate local and remote workers

Give replication its own independently scheduled actor. This provides stronger
isolation, but introduces overlapping pipeline ownership, additional shutdown
coordination, and wider concurrency risk. It is rejected as disproportionate.

## Selected Behavior

### Row retry and replica circuit breaker

When a claim fails with `transport_timeout`, `transport_network`,
`remote_rate_limited`, or `remote_server_unavailable`:

1. The failed receipt keeps the existing exponential full-jitter
   `next_retry_at` value without truncation.
2. Remaining claims for that replica in the current pass return to `pending`.
3. Absent an explicit manual retry or resume, the in-memory replica circuit
   breaker expires exactly 60 seconds after the failure, independently of the
   row's retry deadline.
4. The other replica continues independently.
5. After the circuit breaker expires, ordinary pending work for that replica is
   claimable even if the failed receipt remains in `retryWait` for hours.

Authentication and replica-configuration errors retain the existing indefinite
attention pause. Manual retry clears the requested replica's transient and
attention pause immediately. A service restart continues to clear process-local
pause state while preserving durable receipt states.

The 60-second interval is an implementation constant. It bounds repeated outage
traffic to at most one failed claim per replica per minute while ordinary
backlog exists, including when full jitter produces a zero or sub-minute row
retry; it is not exposed as a setting.

### Pass-level fairness

`ArchiveV2ServiceCoordinator` owns one process-local next-pass priority with two
values: `remote` and `local`. It starts as `remote` so an upgraded service with a
large existing remote queue attempts replication immediately.

For a remote-priority pass, the order is:

```text
HQ + M1 replication -> capture -> index -> bind -> policy
```

For a local-priority pass, the order is:

```text
capture -> index -> bind -> policy -> HQ + M1 replication
```

The priority flips once when a pass acquires the archive pipeline, before any
fallible work starts. Cancellation, errors, resource pauses, or a fully consumed
deadline therefore cannot pin all future passes to one priority. Both orders use
the same ten-second deadline and existing per-stage budgets. If one first-stage
unit crosses the deadline, the next pass starts from the opposite side after the
existing cool-down.

The archive pipeline remains single-flight. Alternation does not run local and
remote stages concurrently with each other; only HQ and M1 may run concurrently
inside the existing replication coordinator.

While the drainer is waiting to acquire that pipeline, `activeStages` remains
empty. The coordinator publishes capture or replica stages only after it has
pipeline ownership, so telemetry never attributes queueing time to capture.

### Capture byte budget

Historical capture already receives `ArchiveCaptureBudget(locatorLimit: 32,
sourceByteLimit: 128 MiB)`. The coordinator checks the accumulated completed
bytes before starting another locator. One file that begins below the boundary
is allowed to finish even when it is larger than the remaining budget, after
which the pass yields. This preserves exact immutable capture and explains the
observed 519 MiB single-file pass without adding partial-file state.

This remediation retains that behavior and adds no second capture limiter.
Tests continue to prove that another locator is not started after the completed
file crosses the byte boundary.

## Observability

Extend the existing Archive V2 status DTO with bounded optional fields:

- each replica gains `pauseReason` and `pausedUntil`;
- `pauseReason` is `transientInfrastructureBackoff` or `needsAttention`;
- transient backoff always includes `pausedUntil`;
- attention pause never includes `pausedUntil`; and
- the top-level response gains `nextPassPriority`, either `remote` or `local`.

Older payloads decode with no pause and `nextPassPriority = remote`. Exact receipt
retry symbols remain available in `retryReasons`; the new pause reason explains
the scheduler-wide gate without duplicating raw errors. No path, locator,
identifier, digest, URL, credential, or transcript content is added.

The Archive & Storage page shows a localized compact line only while a replica is
paused. It shows the effective deadline for transient backoff and an attention
label for credential/configuration pauses. It also shows which side gets priority
in the next backlog pass. The existing manual refresh behavior remains; no UI
polling is added.

## Error Handling

- Expired transient pauses are pruned before claiming.
- The current pause snapshot is copied into each cycle result before the first
  cancellation or catalog operation, so an early cancelled or failed pass
  cannot falsely clear status telemetry.
- A pass-entry pause snapshot is report-only. After a backend await, only pauses
  newly produced by that pass are committed, then the returned snapshot is
  refreshed from actor state. A concurrent manual clear therefore wins over old
  state, while a genuine failure after that clear can establish a new pause.
- Each replica has a process-local monotonic pause revision. A failure batch
  records the revision at the failure event point, after its durable row
  transition when one applies, and may commit only while that base revision is
  still current; a successful pause commit advances the revision. Manual clear
  advances the revision even when no pause is currently cached, creating an
  invalidation barrier for delayed work.
- Replication results and accepted retry outcomes carry those revisions only
  between the Core and Service process components. The Service applies cache
  changes only when the incoming replica revision is not older than its current
  revision and builds drain scheduling from that filtered effective pause view.
  Revisions are not persisted or added to the wire, remote, or UI contracts.
- A clock that advances beyond the pause makes pending work immediately
  claimable in the same pass.
- Multiple transient failures retain the later bounded circuit-breaker deadline,
  never a deadline more than 60 seconds after the most recent failure.
- A row-level retry deadline may remain later than the circuit breaker and is not
  rewritten when the breaker expires.
- A status response that omits the new fields remains valid.
- Invalid pause symbols, invalid timestamps, duplicate replica pause entries, or
  inconsistent reason/deadline combinations fail wire validation.
- A failure to render pause metadata never changes archive replication state.

## Testing

Use failing-then-passing tests for each production behavior:

1. A transient failure with a zero, short, or multi-hour row retry creates a
   replica pause that expires 60 seconds after the failure while preserving the
   row deadline.
2. Before the pause expires, the affected replica claims nothing and the healthy
   replica continues.
3. After 60 seconds, another ordinary pending row for the affected replica is
   claimed while the original retry row remains deferred.
4. A pre-cancelled or early catalog-failed pass preserves the current transient
   and attention pause snapshot in its result.
5. Manual retry clears transient and attention pauses for only the requested
   replica.
6. Consecutive backlog passes alternate remote-first and local-first order.
7. A local unit consuming the first pass deadline cannot prevent replication
   from starting first in the next pass, and the converse also holds.
8. Cancellation or a thrown stage still flips the next-pass priority once.
9. The 128 MiB capture budget admits one over-budget file but does not start a
   second locator in that pass.
10. Wire decoding remains backward compatible and rejects inconsistent pause
   metadata.
11. Settings source and localization tests cover both pause reasons, deadlines,
    next-pass priority, and unchanged manual-refresh behavior.
12. A replica failure that reaches `retryWait` or `quarantined` before a manual
    clear cannot re-establish its pause when another replica delays batch commit.
13. A delayed Service replication continuation cannot overwrite a newer manual
    clear in status or drain scheduling.
14. A delayed manual-retry continuation cannot erase a genuine failure with a
    newer replica pause revision.

Run the focused CoreWrite, ServiceCore, and App tests, then the full Core,
Service, App, MCP, RemoteServer, and TypeScript suites. Build and verify a signed
Release app before deployment.

## Deployment and Runtime Verification

Commit and push the reviewed implementation to `main`. Install and restart the
matching local app/service. No RemoteServer code or wire format changes are
required, but redeploy the same reviewed RemoteServer package to HQ and M1 so all
three deployed revision markers remain identical, as required by the current
operations contract.

Keep the previous local app and each remote `current` target as rollback handles.
After deployment:

1. Verify local/exported binary hash parity and the service socket.
2. Verify HQ and M1 health, process, package hash, and source revision.
3. Observe at least one remote-priority and one local-priority pass.
4. Verify `claimedCount > 0` and `verifiedCount > 0` for both replicas while local
   bound/indexed counts also continue increasing.
5. Verify queued counts decrease or verified counts increase on both replicas.
6. Verify pause metadata agrees with the effective circuit breaker and clears
   60 seconds after a transient failure unless manually cleared sooner.
7. Confirm zero quarantine growth, zero server-error growth, no repeated-request
   storm, and no sustained memory growth.

If either replica cannot resume, pause deployment progression and restore the
previous local app or remote `current` target as applicable. Catalog, CAS, remote
objects, manifests, and receipts require no migration or rollback.

## Acceptance Criteria

1. One transient receipt failure cannot pause unrelated pending work for that
   replica longer than 60 seconds.
2. Row-level exponential retry deadlines remain unchanged.
3. Both local and remote stages receive the first admission opportunity in
   alternating passes under sustained mixed backlog.
4. HQ failure does not stop M1 and M1 failure does not stop HQ.
5. Settings and CLI expose the effective pause reason, deadline, and next pass
   priority without polling or sensitive data.
6. Exact capture, dual-receipt verification, recovery, reclamation, cancellation,
   power, thermal, and single-flight guarantees remain intact.
7. Installed runtime evidence shows local backlog and both remote queues making
   progress on the reviewed revision.

## Non-Goals

- Changing receipt formats, remote endpoints, archive encryption, or durability.
- Splitting the archive pipeline into multiple workers.
- Persisting the pass priority or replica circuit breaker across restarts.
- Retrying quarantined rows automatically.
- Adding performance controls to settings.
- Partially capturing a single large source file.
