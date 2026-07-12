# Archive Sync Observability Design

**Date:** 2026-07-12

**Status:** Approved in conversation; pending written-spec review

## Goal

Make Archive V2 synchronization explainable from the existing settings page and
`archive status --json`: show when synchronization last ran, what the latest
replication pass did, why work is waiting, when it can retry, and when the next
background opportunity is expected.

The implementation must remain lightweight. It must not add polling, a new
database table, a persistent event stream, per-object UI, or additional network
requests.

## Considered approaches

### A. Extend the existing status path (selected)

Add bounded aggregate fields to `ArchiveStatusAggregate`, retain the most recent
replication-cycle result in the service actor, and extend the existing Archive
V2 status DTO. The settings page renders a compact always-visible summary.

This closes the operational gap using data already produced by the replication
coordinator and one bounded catalog aggregation. The only volatile data is the
latest per-cycle summary; durable queue and receipt facts remain available after
a service restart.

### B. Derive more labels from current counts

This would require almost no service work, but it still could not explain a
retry, show the next retry time, or distinguish a productive cycle from an idle
one. It does not meet the goal.

### C. Add a persistent synchronization event log

This would preserve history across restarts and support trends, but requires a
schema, retention rules, privacy review, and a separate query surface. It is not
proportionate to the current operational need.

## Service and catalog model

Extend each replica aggregate with:

- `oldestOutstandingAt`: the oldest `updated_at` among pending, in-flight,
  retry-wait, or quarantined rows;
- `nextRetryAt`: the earliest non-null retry time among retry-wait rows;
- `retryReasons`: counts grouped by non-null `last_error` for retry-wait and
  quarantined rows, sorted by descending count and then symbol.

These values are calculated inside the existing `archiveStatus()` read. They do
not expose manifest hashes, capture IDs, session IDs, locators, paths, or source
content. Invalid timestamps or symbols continue to fail closed through the
existing Archive V2 wire validation.

Retain one `lastReplicationCycle` value inside `ArchiveV2ServiceCoordinator`.
It contains:

- start and finish timestamps;
- duration in milliseconds;
- claimed, verified, retry-scheduled, quarantined, lost-claim,
  stale-recovered, and reconciled counts;
- cancellation state and the existing symbolic cycle error.

The summary is replaced after each replication attempt and resets when the
service restarts. No historical cycle list is retained.

The background scheduler records an approximate `nextScheduledCycleAt` on the
same coordinator whenever it schedules the next indexing/archive opportunity.
The value is explicitly an estimate because macOS may defer background work.

## Wire contract

Extend `EngramServiceArchiveV2StatusResponse` rather than adding a command:

- each `EngramServiceArchiveV2ReplicaStatus` gains `oldestOutstandingAt`,
  `nextRetryAt`, and `retryReasons`;
- the top-level response gains `lastReplicationCycle` and
  `nextScheduledCycleAt`;
- a retry reason contains only `symbol` and non-negative `count`;
- decoding defaults newly added optional and collection fields so a new app can
  still read an older service response during a rolling local update;
- existing strict validation for replica order, non-negative counts,
  timestamps, and symbolic errors remains in force.

The existing CLI JSON output receives the fields automatically through the
shared response. No new CLI command is added.

## Settings UI

Keep the current Archive Sync Status card and its manual refresh behavior. Do
not add a timer.

Below the existing progress and HQ/M1 count rows, show up to three compact
localized lines when data exists:

1. latest pass: finish time, duration, verified, retry-scheduled, and
   quarantined counts;
2. queue explanation per replica: oldest outstanding time, earliest retry time,
   and retry reason counts;
3. approximate next background opportunity.

Known retry symbols are grouped into user-facing categories:

- network: `transport_*`, `remote_server_unavailable`, and
  `remote_rate_limited`;
- credentials: `remote_auth_rejected`;
- local archive: `local_*`;
- remote verification: remaining `remote_*` symbols;
- configuration: `replica_configuration_failure`;
- other: unrecognized symbols.

The CLI keeps exact symbols. The settings page shows localized categories so
`transport_network` is presented as a temporary network retry rather than a
permanent data failure.

Dates use the user's locale and time zone. Missing volatile cycle data after a
service restart is omitted; it is not rendered as a failure. Quarantined work,
configuration errors, local archive failures, and remote verification failures
continue to produce the existing needs-attention state. Retry-wait work remains
in-progress unless its reason belongs to a non-transient attention category.

## Logging

Emit one bounded Archive V2 service log line per completed replication pass
with only the cycle counts, duration, cancellation flag, and error symbol. Do
not log identifiers, paths, URLs, tokens, response bodies, or retry rows.

This gives the existing service log ring one useful archive-specific event
without introducing a new logging backend.

## Tests

Use failing-then-passing focused tests for:

- catalog aggregation of oldest outstanding time, earliest retry, and reason
  counts for both replicas;
- wire validation and backward-compatible decoding of the new fields;
- service coordinator capture and replacement of the latest cycle summary;
- next-schedule recording;
- retry reason presentation grouping and overall attention-state behavior;
- Simplified Chinese coverage for every new settings string;
- source-level settings checks that preserve no-polling behavior and stable
  accessibility identifiers.

Run the focused Archive V2 core, service, and app tests, then the Engram Debug
build. After installing the app, compare the settings values with
`EngramCLI archive status --json` and inspect the Chinese rendering.

## Acceptance criteria

- A user can tell the latest replication pass time, result, and approximate next
  opportunity from Archive & Storage settings.
- Retrying rows show a friendly reason and earliest retry time rather than only
  a count called "failed".
- Exact retry symbols and aggregate timestamps are present in CLI JSON for
  diagnosis.
- No polling, new persistence, per-object exposure, or additional network call
  is introduced.
- Existing archive capture, replication, recovery, and reclamation behavior is
  unchanged.
