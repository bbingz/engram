# Design Doc: HQ collector epoch approval is a local operator command

- **Status**: Accepted (implemented in the same PR)
- **Owner**: Engram maintainers (Claude session, 2026-10-18)
- **Date**: 2026-10-18
- **Related**: `docs/superpowers/specs/2026-09-05-collector-server-web-design.md`
  §2 (local authenticated `collectorApproveEpoch` operator IPC action, never
  exposed to Web, exact expected binding, transition record, read-only dry
  run); plan `docs/superpowers/plans/2026-09-05-collector-server-web.md` W4
  item 7; `docs/superpowers/specs/2026-10-17-collector-native-epoch-reconcile-design.md`
  (the collector-local half); `docs/TODO.md` "Operator epoch reconcile command
  (plan W4 item 7)"; `docs/followups.md` `collector-epoch-producer-1`.

## Problem

`CaptureIngestSourceRegistry.dryRunEpoch` and `approveEpoch`
(`macos/EngramCoreWrite/CaptureIngest/CaptureIngestSourceRegistry.swift` at
`4b84e3d5`) have no production caller. The ingest worker claims a publication
only when its epoch equals the registry's approved epoch for that source
instance (`ServiceCaptureIngestWorker.swift` `preselect`), so a publication on
any other epoch stays `pending` with attempt 0 forever
(`testUnknownEpochDoesNotPoisonLedger`). The only registry writer in
production is startup provisioning from the source-authority file, which by
design never approves a later epoch. The only way to promote a new epoch today
is hand-written SQL against the HQ index, which bypasses the writer gate, the
expected-binding check and the history record.

## Goals / Non-goals

- Goals: a local operator dry run and an approve that requires the exact
  current binding; the existing durable history row as the transition record;
  no Web path and no App/MCP surface; no automatic promotion or retraction; a
  repro test showing a pending new-epoch publication becomes ingestible only
  after the command.
- Non-goals: the collector-side epoch producer (see Risks); source-instance
  retire or rebind; alias reconciliation; any automatic approval at intake or
  start; any UI.

## Current state

At `4b84e3d5`:

- `dryRunEpoch` is read-only and returns the current binding, whether the
  candidate was ever approved, and current/candidate backlog (publication count
  plus ledger task counts per status). `approveEpoch` runs in a savepoint,
  requires `expectedEpoch` and `expectedAuthorityGeneration` to match
  (`staleBinding` otherwise), refuses any epoch already in history
  (`epochPreviouslyApproved`), guards generation overflow, and appends a
  `capture_ingest_epoch_history` row.
- `ServiceCaptureSourceAuthority.provision` (`ServiceCaptureSourceAuthority.swift`)
  is index-role only through `requireIndexCaptureAdmission`, checked before the
  write and again inside it, and also requires each source to be enabled.
- The capability token is required only for names in
  `ServiceCapabilityToken.protectedCommands`; every socket connection is
  peer-euid checked. The Web read and write clients forward only their own
  allowlists, and EngramRemoteServerCore does not compile
  `EngramServiceClient.swift` or `EngramServiceModels.swift`.
- `EngramCLI` dispatches `archive`, `resume` and `context` subcommands before
  falling through to exec `EngramMCP`.

## Proposed design

- **IPC** (`EngramServiceCommandHandler.swift`, new extension
  `EngramServiceCommandHandler+CollectorEpoch.swift`):
  - `collectorEpochDryRun`, exact payload keys `machineID`,
    `sourceInstanceID`, `candidateEpoch`. Not token-protected (read-only, like
    `archiveV2Status`), still peer-euid gated. Index-role only. Runs
    `dryRunEpoch` and one extra read-only query
    (`CaptureIngestSourceRegistry.observedUnapprovedEpochs`) under
    `ServiceWriterGate.performReadCommand`, which does not bump the database
    generation. The response carries `dryRun: true`, the current binding,
    `candidateWasPreviouslyApproved`, both backlogs, and
    `observedUnapprovedEpochs`: the epochs in `capture_ingest_publications` for
    that source instance that no history row ever approved, with publication
    counts. That list lets the operator find the candidate without opening the
    database; any canonical epoch (for example the current one) can be passed
    for a discovery-only run.
  - `collectorApproveEpoch`, exact payload keys `machineID`,
    `sourceInstanceID`, `candidateEpoch`, `expectedEpoch`,
    `expectedAuthorityGeneration`. Added to `protectedCommands`. Checks
    `requireIndexCaptureAdmission` before the gate, then inside
    `performWriteCommand` re-checks it, reads the binding, requires its source
    to be enabled, and calls `approveEpoch`. Returns the previous epoch and
    generation (the request's expected values) and the new binding, plus the
    gate's database generation.
  - Registry and authority errors become
    `commandFailed(name: "CollectorEpochRefused", retryPolicy: "never",
    details: ["reason": <case>])`, for example `staleBinding`,
    `epochPreviouslyApproved`, `unregisteredSourceInstance`, `invalidEpoch`,
    `capturePolicyUnavailable`, `sourceDisabled`. Missing or extra payload keys
    and wrong types are `InvalidRequest` before any database access.
  - The approve logs machine, instance and the generation change through
    `ServiceLogger.notice`; no paths.
- **DTOs and client** (`macos/Shared/Service`): plain Codable shapes; the
  registry validates. `EngramServiceClient.collectorEpochDryRun` and
  `collectorApproveEpoch` live only on the concrete client, not on
  `EngramServiceClientProtocol` or the mock, so the App and MCP gain no
  operator mutation.
- **CLI** (`EngramCLICollectorEpochCommand.swift`, `EngramCLI/main.swift`):
  `EngramCLI collector-epoch dry-run --machine-id --source-instance-id
  --candidate-epoch` and `approve` with `--expected-epoch
  --expected-authority-generation` added. Every flag exactly once; canonical
  uppercase UUIDs only (never normalized); a positive decimal Int64
  generation; candidate must differ from expected. Output is one sorted-keys
  JSON object; exit 0 on success, 1 on a service failure, 64 on usage. The
  socket comes from `ENGRAM_SERVICE_SOCKET` (the token from its `.cmd.token`
  sidecar), as for `EngramCLI archive`.
- **Schema**: none. `capture_ingest_epoch_history` (previous epoch, approved
  epoch, generation, timestamp) is written in the same savepoint and is the
  transition record the design asks for.
- **Ledger effect**: approval only makes pending publications of the new epoch
  claimable. Publications of other epochs stay pending; sessions already
  committed are neither retracted nor promoted.

## Invariants affected

- "Source and Epoch Authority Precedes Capture Replay": its sentence "This
  database contract does not expose an operator command" is replaced by a
  pointer to the new entry; the handler is added to Enforced by.
- New: "Collector Epoch Approval Is A Local Operator Action".
- Preserved: invariant 1 (single writer; the approve goes through
  `ServiceWriterGate`), local service socket security (token plus peer-euid),
  and "Web Reader and Editor Authority" (neither command is on a Web
  allowlist; `testAllowlistRejectsUnknownCommandsWithoutIPC` now names both).

## Alternatives considered

- A one-shot `EngramService` process flag: it would contend with the running
  service-index for the writer-gate process lock, so HQ would need a launchd
  bootout around every approval.
- A Web route: forbidden by the accepted design.
- Adding the methods to `EngramServiceClientProtocol`: gives the App and the
  mock an operator mutation for no product use.
- Approving automatically on first arrival of a new epoch: the design requires
  explicit operator authority.
- A machine-wide observed-epoch listing: it would need a different request
  shape (no instance) and mostly shows unregistered instances, which this
  command cannot act on.

## Test plan

- `macos/EngramServiceCoreTests/CollectorEpochIPCTests.swift`: capability and
  Web boundary; dry run reports the expected binding, both backlogs and the
  observed unapproved epochs without writing or bumping the generation;
  approve advances the generation and appends exactly one history row; stale
  epoch, stale generation and a replayed request are refused without writing;
  re-approving an earlier epoch is refused; unknown instance and lowercase IDs
  are refused; non-index role, missing capture ingest and a disabled source
  are refused; missing, extra and mistyped payload keys are `InvalidRequest`;
  the client sends exact command names and payload keys.
- `testUnapprovedEpochBecomesIngestibleAfterOperatorApproval_repro`
  (`ServiceCaptureIngestWorkerTests.swift`): a pending new-epoch publication
  stays unclaimed until `collectorApproveEpoch` is dispatched through the
  handler, then parses; the earlier session still exists and a later
  publication on the superseded epoch stays pending. Before this change the
  command is unsupported and the test fails.
- `macos/EngramTests/EngramCLICollectorEpochCommandTests.swift`: parse, the
  malformed-argument matrix, non-`collector-epoch` argv returns nil, and render
  emits one sorted JSON object.
- Not tested: a real HQ invocation over the live socket (deployment is a
  separate owner-authorized step).

## Rollout

- Rebuild and deploy the HQ service-index and `EngramCLI`; no migration runs.
- Operator procedure: `ENGRAM_SERVICE_SOCKET=<index socket>
  EngramCLI collector-epoch dry-run ...`, review, then with explicit owner
  authorization `EngramCLI collector-epoch approve ... --expected-epoch
  <current.approvedEpoch> --expected-authority-generation
  <current.authorityGeneration>`; run as the service-index user.
- Revert: remove the two handler cases, the extension and the CLI subcommand.
  History rows already written stay valid.

## Risks and open questions

- **Producer divergence (owner decision, `collector-epoch-producer-1`).** The
  collector never mints a new epoch under an existing source instance: a
  `collector_streams` row gets fresh UUIDs for both `source_instance_id` and
  `collector_epoch` once per root, root revision and source
  (`macos/EngramCollectorCore/CollectorInventoryStore.swift`), and later writes
  only advance `last_sequence`. A spool reset or a root revision bump therefore
  reaches HQ as a new, unregistered source instance on an already registered
  root; its publications stay pending, and adding it to the source-authority
  file makes `provision` throw `overlappingRoot`, which aborts service-index
  startup. This command keeps the instance and cannot recover that case. The
  2026-09-05 design assumed a spool reset "creates a retained new epoch
  branch" under a stable instance. The owner must choose between the collector
  rotating only the epoch (making this command the recovery path) and an HQ
  source-instance retire/rebind design.
- The dry run is unprotected, so any same-user process that can open the socket
  can read configured root paths and backlog counts. This matches the other
  read-only operator commands.
- `ENGRAM_SETTINGS_PATH` is process-global; the new tests restore it.
