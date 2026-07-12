# Archive Remote Telemetry Design

**Date:** 2026-07-12

**Status:** Approved for implementation

## Goal

Add lightweight, bounded, persistent observability to each
`EngramRemoteServer`, expose it through an authenticated archive-v2 status
endpoint, and surface the independently reported HQ and M1 state in Engram's
Archive & Storage settings page.

The feature must explain what each remote server actually received, rejected,
verified, and persisted without creating a high-volume log stream or a second
operations system.

## Chosen approach

Each server keeps aggregate counters and a bounded sanitized error ring in
memory. A dirty state is written at most once every 60 seconds to one atomic
JSON snapshot beneath that server's archive-v2 root. A status read flushes a
dirty snapshot first, so an operator-observed state is also durable. A crash
can lose at most the unflushed interval; archive payload durability is
independent of telemetry persistence.

Alternatives rejected:

- Per-request JSONL was rejected because it grows with traffic and creates a
  rotation and retention subsystem.
- SQLite was rejected because the remote server does not otherwise depend on
  GRDB or SQLite and the expected telemetry volume does not justify a new
  database dependency.
- Memory-only counters were rejected because they cannot explain behavior
  across a restart, which is the main gap this feature closes.

## Server components

### Shared wire model

Add a Codable archive-v2 remote telemetry model to the shared archive protocol
surface used by both `EngramRemoteServerCore` and `EngramCoreWrite`. The model
contains only bounded, non-sensitive values:

- schema version, server ID, build revision, process start time, snapshot time,
  and uptime;
- disk available and total bytes when Foundation can obtain them;
- total request, success, client-error, and server-error counts;
- total request and response bytes;
- last successful archive mutation time;
- normalized endpoint aggregates with count, error count, total duration,
  maximum duration, request bytes, and response bytes;
- at most 100 recent sanitized errors containing only timestamp, normalized
  endpoint, HTTP method, status code, and symbolic category.

All timestamps use the existing canonical UTC millisecond representation.
Counts and byte totals are non-negative and saturate instead of overflowing.
The status response has a strict encoded-size cap.

### Telemetry store

`ArchiveRemoteTelemetryStore` is an actor owned by one server process. It:

1. Creates a mode-0700 telemetry directory under the archive-v2 root.
2. Rejects symlinked snapshot paths and loads only a valid current-schema
   regular file.
3. Updates in-memory aggregates after each normalized archive-v2 request.
4. Retains only the newest 100 error summaries.
5. Writes a mode-0600 atomic JSON snapshot no more than once per 60 seconds,
   except that an authenticated status read flushes dirty state immediately.
6. Treats telemetry write failures as observability degradation, never as a
   reason to fail an otherwise successful archive write.

The snapshot never contains bearer tokens, encryption keys, URL hosts, raw
paths, object or manifest digests, machine IDs, session IDs, query strings,
request bodies, response bodies, or raw error descriptions.

### Request observation

Archive-v2 routes use one bounded observation wrapper rather than logging from
every store branch. The wrapper records monotonic duration, normalized route,
method, status, and Content-Length values after the response is constructed.

Normalized endpoints are limited to:

- `object`
- `manifest`
- `receipt`
- `machines`
- `receipts`
- `status`
- `unknown`

Status codes map to fixed categories such as `success`, `unauthorized`,
`malformed_request`, `not_found`, `conflict`, `payload_too_large`,
`invalid_content`, `storage_unavailable`, and `internal_error`. Raw thrown
errors are never persisted.

### Authenticated status endpoint

Add `GET /v2/archive/status`. It uses the archive-v2 bearer token and returns a
canonical JSON telemetry snapshot. The endpoint records its own request only
after creating the response, so each response is internally consistent and the
next response reflects the previous status read.

The endpoint remains unavailable when archive v2 is disabled. Existing archive
routes and immutable storage semantics do not change.

## Build identity

The package wrapper exports a non-secret `ENGRAM_REMOTE_SOURCE_REVISION`
generated from the package's validated 40-character source revision. The
server validates and reports this value; missing or malformed values report
`unknown` rather than preventing archive service startup.

The package verifier proves that the wrapper contains only the build-revision
placeholder and no credential material. HQ and M1 receive the exact same
verified package bytes.

## Client and settings flow

`ArchiveReplicaBackend` gains an optional telemetry-status operation with a
default unsupported implementation so existing test and in-memory backends do
not need fake telemetry.

`HTTPArchiveReplicaBackend` performs an authenticated bounded GET of
`/v2/archive/status`. The service fetches HQ and M1 concurrently only when
`archiveV2Status` is requested. Each request has a three-second timeout and a
bounded response. Failure of one remote status call does not fail the local
archive status response; that replica instead carries a fixed error symbol.

The Archive & Storage settings page already loads once on entry and refreshes
only when the user presses Refresh Status. Under each replica it displays:

- remote online or unavailable;
- build revision and uptime;
- last successful archive mutation;
- total requests and errors;
- available disk capacity;
- most recent sanitized error category when present.

It does not add a timer, polling task, event store, notification, chart, or
historical browser.

## Error handling and compatibility

- Existing clients and servers remain compatible because new wire fields are
  optional on the local service response and the remote status operation is
  not part of replication correctness.
- A telemetry snapshot that is absent, corrupt, oversized, symlinked, or from
  an unsupported schema is ignored and replaced on the next successful flush.
- Telemetry persistence failure is reported in the live status response with a
  fixed symbol but does not expose a path or raw error.
- Remote status network failures use existing fixed transport symbols and do
  not alter replication retry state.
- No source, local archive object, remote archive object, manifest, receipt, or
  rollback snapshot is deleted by this feature.

## Testing

Use test-driven development for every production behavior.

Server tests cover:

- aggregate and saturating counters;
- 100-entry error-ring truncation;
- 60-second flush throttling and forced status flush;
- atomic snapshot reload after a new store instance;
- corrupt, oversized, unsupported-schema, and symlink snapshot rejection;
- sanitized snapshot content;
- authenticated and unauthenticated status routes;
- route outcome, duration, and byte aggregation;
- telemetry write failure not changing archive response success.

Client and app tests cover:

- bounded remote status decoding and validation;
- concurrent partial-success HQ/M1 status collection;
- optional wire compatibility;
- settings presentation and localization.

Release verification covers the package source-revision export, package
manifest, signatures, arm64 architecture, dependency closure, and secret-free
templates.

## Deployment and rollback

Build one Release arm64 package from the reviewed implementation commit. Before
changing either host, capture its current release link, package metadata,
binary hash, LaunchAgent state, listener, health result, telemetry/log metadata,
and existing rollback directories without copying archive stores.

Deploy serially:

1. Install and verify HQ, restart only `com.engram.remote-server`, then verify
   health, authenticated status, immutable archive smoke, snapshot creation,
   and restart recovery.
2. Only after HQ passes, repeat the same process on M1.
3. Install the matching local Engram app and verify its settings-facing service
   response contains independent HQ and M1 telemetry.

Each host keeps its previous release directory and current symlink target as
the rollback handle. If a host fails any post-deploy gate, restore only that
host's previous current target, restart its LaunchAgent, and re-run health and
archive read verification before proceeding.

## Acceptance criteria

The work is complete only when:

1. Both hosts report the same reviewed build revision and package hash.
2. Each host persists and reloads its own bounded telemetry snapshot.
3. Auth is required and no sensitive identifier or content appears in the
   status response, snapshot, service logs, or client DTO.
4. Archive PUT/GET/receipt behavior and zero-delete guarantees remain intact.
5. HQ/M1 health, process, listener, authenticated status, and new archive write
   evidence pass after deployment and after one controlled service restart.
6. The local Archive & Storage page can show both remote states without adding
   background polling.
