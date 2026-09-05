# Collector / central Service / Web implementation plan

**Date:** 2026-09-05

**Governing design:** [collector-server-web-design](../specs/2026-09-05-collector-server-web-design.md)

**Worktree:** `.worktrees/collector-server-web-20260905`

**Branch / base:** `codex/collector-server-web-20260905` / `625ecc9737c219f401200d3c2e301f537582ff11`

**Status:** W1 local implementation/independent review passed; Core 1,452 tests
(one existing performance skip), launcher 56 tests. Revised design passed the
independent B1-B7 closure gate; W2 intake and W3/W4 interfaces are frozen. Later
waves are planned, not implemented or deployed. The next bounded implementation
slice is W2 wire models/fixtures, followed by receiver storage/routes.
The owner authorized committing/pushing W1, running CI, then autonomous staged
implementation/review/CI through W6 on 2026-09-05. Production W7, credentials,
network changes, and merge/release remain separate authority boundaries.

## Execution rules

- Coordinator owns this plan, design, integration routing, and CHANGELOG/MEMO.
  Workers own explicit files. Never overwrite another worker or another worktree.
- Every behavioral fix needs captured RED then GREEN; independent review maps
  acceptance criteria to actual diff/tests, not worker self-report.
- At most three independent workers. Serialize heavy Xcode builds with jobs 2
  or less; use isolated temporary homes/data and identified DerivedData. Do not
  run production helpers, local Docker, provider requests, or broad filesystem
  inventories in tests.
- Preserve complete build/test logs and producer exits. Infrastructure failure
  is not RED; skipped tests are not PASS. Coordinator runs `git diff --check` and
  the appropriate product-boundary tests before each local closeout.
- Feature/network paths remain default OFF. A green implementation gate does
  not grant operational authority. Stop at exact authority boundaries.

## Dependency order and parallel lanes

| Wave | Work | Dependency | Can run alongside |
|---|---|---|---|
| W1 | Hot query and App ownership fixes; freeze full design | Current source evidence | Each other; coordinator design |
| W2 | Publication/ACK/journal wire contract and receiver | Reviewed design | Headless packaging dry-run work; Web facade contracts |
| W3 | No-index collector, privacy proof, inventory and two-replica uploader | W2 fixtures/API | HQ ingest implementation using same fixtures |
| W4 | HQ ingest ledger/replay/identity and independent readiness | W2; W3 fixtures | Additional source exporters; Web implementation |
| W5 | Read-only Web reader and optional native module | W4 read contracts | Packaging and source coverage |
| W6 | Integrated shadow verification, complete source coverage, resource tests | W3-W5 plus packages | Independent security and operational review |
| W7 | Separately authorized one-host cutover and natural observation | W6 PASS plus owner transaction | No unrelated operations |

W2-W5 may have fixture-backed parallel development, but may not claim an
end-to-end pass until their real integrations run together. No worker edits
`project.yml` or shared DTO ownership without coordinator coordination.

## W1 — remove measured blockers without claiming collector completion

### W1-A: bounded session embedding selection

Owner: query worker. Files: `macos/EngramCoreWrite/Indexing/InsightEmbeddingBackfill.swift`
and `macos/EngramCoreTests/AI/InsightEmbeddingBackfillTests.swift` only.

Acceptance:

1. Real production query fails a deterministic SQLite VM-step budget on the old
   implementation with many pending jobs/unrelated FTS rows, then passes.
2. Pending-before-retry/retry-count/creation/id ordering, nonempty text,
   hidden/skip/lite exclusion, complete ordered text, duplicate/NULL handling,
   and zero/negative/positive limits remain compatible.
3. No schema migration/index, dependency, or unrelated Runner change.
4. Focused Core tests and independent diff review pass; full Core suite follows.

### W1-B: external service connection-only lifecycle

Owner: lifecycle worker. Files: `macos/Engram/Core/EngramServiceLauncher.swift`
and `macos/EngramTests/EngramServiceLauncherTests.swift` only.

Acceptance:

1. An actually adopted Unix-socket service receives no shutdown after App quit,
   failed health probes, or manual reconnect; its runtime secret remains intact.
2. No replacement process/lock takeover is attempted, including a suspended
   health probe that resumes after quit/cancellation.
3. External recovery reconnects; unavailable status is honest.
4. App-owned shutdown, stderr drain, writer-lock conflict, timeout, and restart
   budget tests retain coverage. Remove only orphaned code created by this change.
5. Focused launcher behavior tests and independent review pass.

### W1-C: review and next-wave readiness

Coordinator checks the exact current diff and logs. A separate read-only worker
reviews this design/plan for unsafe privacy, protocol, identity, pagination,
capability, and cutover assumptions. Blocking findings are resolved in the
design before assigning cross-component production changes.

**Not included in W1 completion:** collector binary, new wire protocol, HQ ingest,
Web UI, changes to actual launchd/config/Keychain, or performance claims on the
installed build. Record those as remaining, not as implied work.

## W2 — freeze and implement durable publication intake

Scope: narrow ArchiveV2 wire models plus RemoteServer store/routes/tests;
coordinator owns target source lists. Preserve old canonical schema-1 bytes.

1. Write compatibility and negative fixtures for a separately versioned
   publication referencing an existing manifest; agree exact endpoints, bounded
   payload/page sizes, conflict/error/status codes, and server capability check
   from the design's W2 intake contract. Do not invent another wire shape.
2. Implement per-replica durable acceptance and a restart-safe arrival journal.
   Verify referenced content before ACK, and test every crash boundary that
   could separate acknowledgement from later discoverability.
3. Test sequence conflicts, epoch policy, two independent server identities,
   missing/corrupt chunks, retransmission, unavailable old servers, and no DELETE.
4. Preserve all bound receipt/recovery/reclamation and archive MCP tests.

Gate: Remote Core full suite; canonical golden comparison; independent protocol
and safety review. A bare `putManifest` 2xx is not enough.

## W3 — genuine no-index collector

Scope: native collector target and narrow reusable capture code, tests, packaging
source list by coordinator. No direct product-index writer dependencies.

1. Start with Claude/Codex exact files and a minimal generation-bound metadata
   privacy proof; fail closed for unknown/excluded/ambiguous roots. Use the frozen
   parser projection and conservative conflict policy. Provision an independent
   shadow catalog with the existing machine UUID; never share its writer with
   the live Service catalog.
2. Add durable root inventory and dirty queue, resumable bootstrap, FSEvents
   reconciliation, stable capture, byte/file/concurrency budgets, and disk-pressure
   status. Do not replace an O(N) crawl with an undocumented O(N) crawl.
3. Add persisted epoch/sequence publication allocation and two independent upload
   queues with bounded backoff, idempotency, wrong-ACK rejection and restart tests.
4. Prove launch without App, product DB, FTS tables, embedding/config credentials,
   repository scan, or model network access. Capture stats must use correct units.
   Implement persisted host-role gating before App DB open/service spawn, with
   cold/absent-socket, Spotlight-style launch, quit/cancellation and invalid-role
   tests. A launchd-only environment setting does not satisfy this criterion.
5. Build the enabled-source coverage matrix per host. Add replay-proven exporters
   for database/composite/cache sources before retiring their old collector path.
   Treat missing Grok/Pi support as an explicit source decision, not silent loss.

Gate: hermetic capture/upload integration with two local test stores, privacy
adversarial tests, target-dependency guard, restart/overflow/disk-pressure tests.
Actual production source inspection is separate and read-only until authorized.

## W4 — central replay, identity, and ready states

Scope: Service/CoreWrite ingest ledger/replay integration and tests; share the
W2 fixtures. Coordinator serializes schema/Runner/DTO changes.

1. Implement the frozen ImportRepo-based identity encoding, binding/alias table,
   original-locator replay and parent mapping. Prove collisions are quarantined
   and aliases preserve existing insights/user state. Provision source-instance
   maps before legacy receipt bootstrap; do not auto-invent a legacy stream.
2. Implement durable ingest ledger and transaction-safe cursor advancement;
   replay original bytes through existing adapters in confined staging.
3. Preserve last-good generations, reject out-of-order replacement and unknown
   epoch promotion, and classify parse/retry/quarantine distinctly.
4. Add explicit capture/ACK/parse/FTS-ready/AI/freshness read DTOs; do not infer
   readiness from `running`, counts, a healthy socket, or archive durability.
   Freeze and implement IPC message+UTF-8-offset continuation below the encoded
   256 KiB frame ceiling, redacting before fragmentation. Reassemble oversized
   Unicode messages in tests; stale-generation cursors fail explicitly.
5. Bootstrap old receipts with restart-safe dedup and EOF-reset discovery;
   preserve existing remote snapshot and local session behavior.
6. Move optional AI work off required readiness, checking provider/backoff before
   backlog work. Keep bounded maintenance and terminal-failure semantics.
7. Implement read-only epoch-recovery dry-run plus authenticated local operator
   reconciliation with expected-binding checks. Keep unapproved epochs and old
   last-good data without automatic retraction or promotion. Never expose this
   mutation through Web.

Gate: full Core/Service suites, fixture transcript/usage/tier/parent parity,
crash/reorder/namespace tests, direct-writer and migration guards. Demonstrate
capture and keyword-ready when the AI provider is absent or indefinitely failing.

## W5 — native read-only Web

Scope: optional RemoteServer Web module/assets/read facade/tests. Shared IPC
read DTO extraction is coordinator-owned and must not link DB writer libraries.

1. Freeze narrow overview/list/search/detail/message-continuation DTOs. Prove
   every non-allowlisted command is rejected before any IPC/token loading.
   W4's real IPC continuation is a prerequisite; HTTP-only fixture pagination
   cannot close full-transcript acceptance.
2. Implement dedicated viewer authentication, short-lived cookie, exact
   Host/Origin/CSRF controls, page/body/time budgets, safe errors and no-store.
3. Implement same-origin static reader with source/machine/project filters and
   safe transcript text. Full content remains pageable even for oversized messages.
4. Test no token/secret leakage and all attempted write methods/routes; preserve
   existing archive/v1/MCP auth contracts.
5. Use browser/render checks on the real test server: login/logout, keyboard,
   empty/stale/error states, long transcript, XSS fixture, and narrow viewport.

Gate: Remote + relevant Service/MCP suites; negative authority tests; browser
acceptance. Production Web remains OFF without approved HTTPS/credential setup.

## W6 — packages, coverage, and shadow integration

1. Build complete role-specific packages with dependency hashes, verify-only and
   dry-run installers; test missing/mismatched framework rejection.
2. In temporary homes run collector -> two independent RemoteServers -> HQ
   Service -> Web with real binary boundaries and synthetic append/rename/crash
   cases. Compare exact bytes, messages, roles, timestamps, usage and tiering.
   Shadow HQ uses a separate product DB/socket; shadow collectors use separate
   CAS/catalogs with explicitly copied machine identity. No live catalog gets
   a second writer, and no shadow row enters the production read corpus.
3. Verify the design's resource/latency targets with declared workload, then
   separately request a bounded real-host shadow transaction. Keep old ingestion.
4. Independently review privacy, authorization, overwrite/order, source coverage,
   old-client compatibility, and operational rollback; fix blockers, not nits.

Gate: all contract tests plus end-to-end browser/read evidence and a source-by-
source retirement checklist. Any enabled unsupported source keeps its old path
and blocks a claim that the host has become fully lightweight.

## W7 — production transaction, separately authorized

Before mutation refresh each host's executable/hash, version, job domain,
PID/start time, socket/listener, config shape (no secrets), source coverage,
backups and rollback pointer. Present exact targets and blast radius to owner.

Deploy compatible receiver first, then HQ ingest, then shadow collector and Web.
Do not alter root plists, credentials, tailnet exposure or watchdogs implicitly.
Cut over one host only after both ACKs and full HQ search/transcript proof.
Observe natural cycles, including the existing watchdog path where applicable.
Do not manually trigger external-message jobs, force-kill uncertain processes,
or reboot for evidence without explicit authority.

Rollback on lost coverage, repeated durable-ACK mismatch, last-good overwrite,
privacy failure, unrecoverable ingest lag, or resource failure. Restore the
identified old role/config with matching checked backup if necessary; preserve
all source bytes, new archives, and ledgers. Stop and report on identity ambiguity.

## Local closeout record

After each implemented tranche, update CHANGELOG/MEMO minimally with actual
changed paths, RED/GREEN and independent gates, complete log paths, skipped
checks, and remaining waves. Do not mark this full plan complete on W1 tests.
