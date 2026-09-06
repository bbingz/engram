# Design Doc: lightweight collectors, central indexing, and a read-only Web client

- **Status**: Accepted for staged implementation. Pushed `f683ff71` remains in draft/open/unmerged PR #446, but Tests `34011185057` failed Swift unit/UI smoke compilation on Xcode 16.4 in the same readiness test-helper optional-array inference; Node/scripts/Remote/package passed. Dependency review passed and CodeQL remains separate. A one-line explicit array type correction passed independent SPEC PASS / QUALITY APPROVED; all 38 test bodies/default values and production/workflow settings stay unchanged. Complete corrected local Core passed 1,681/one existing performance skip/zero failures, producer 97659 exit 0 at 12:39:10 CST. Final five-path correction review/commit/push and new correction-head CI remain pending; local Xcode-beta cannot prove Xcode 16.4 compatibility. The correction commit excludes all five locally integrated A5a/N3-A files. Those feature files passed donor implementation gates and central Remote 372, Service 875 (one existing skip), App 1,175, MCP 270 and Collector 169, zero failures and producer exits 0; App also reran Core 1,681 (one existing skip). Scripts 207/207 and typecheck/safety/invariants pass, but their final integration/commit/CI remain separate. T3b FTS consumer and N3-B native events pause at read-only proposals while CI is repaired. Runtime wiring, upload queues, real read/FTS consumers, Web UI and W6 remain incomplete; no production or full-transcript/browser acceptance is claimed. W7 remains separately authorized.
- **Owner**: Engram maintainers; Codex coordinates bounded implementation workers
- **Latest checkpoint (2026-09-06 12:48 CST)**: The correction passed its final independent five-path gate and pinned staged drift, and is normally committed/pushed as `5995ad66bad8d827f311dd04fef81f287a4d70be` in the same draft/open/unmerged PR #446. Dependency review `34012392885` passed; Tests `34012392893` and CodeQL `34012392888` remain pending. This supersedes the prior correction commit/push checkpoint, not the requirement for authoritative Xcode 16.4 CI. The five A5a/N3-A feature files remain uncommitted, with all combined local gates above passed and hashes unchanged; their final integration/record gate is pending, and their push must wait for correction-head CI success. N3-B1 and T3b are still separate proposals, not native watch or Service/Web runtime acceptance.
- **Date**: 2026-09-05
- **CI follow-up**: Exact `5995ad66` Tests `34012392893`, including Swift unit/UI smoke/CI Gate, subsequently passed. The downloaded Xcode 16.4 job log confirms readiness 38/38 and Core 1,681/one existing skip/zero failures. Swift CodeQL is still pending; it must pass separately before the A5a/N3-A feature push.
- **Related**: [implementation plan](../plans/2026-09-05-collector-server-web.md), [archive v2 contract](../../remote-archive-v2.md), [invariants](../../invariants.md), root `CHANGELOG.md`
- **Push follow-up (2026-09-06)**: Correction `5995ad66` Tests, CodeQL and dependency review all succeeded, superseding the pending checkpoint. A5a/N3-A passed the final independent nine-path integration/record gate and is normally committed/pushed as `8a53174b182baba1c2d671dcc6b42dfdd3eaf408`, with unchanged five-file hashes and zero-exit producers. Its dependency review `34013832384` passed; Tests `34013832379` and CodeQL `34013832367` are pending. N3-B1's separate two-file fake-stream draft passed its independent gate and has donor-only routing for executable RED; T3b's 35-test draft is under review, not GREEN. No donor draft or W3-W6 runtime acceptance is attributed to this pushed SHA.
- **Source baseline**: `625ecc9737c219f401200d3c2e301f537582ff11`
- **N3-B1 integration checkpoint (2026-09-06)**: Exact pushed `8a53174b` Tests, CodeQL and dependency review all succeeded; PR #446 remains Draft/open/unmerged. The coordinator independently approved the bounded generic event coordinator, integrated its frozen source/test hashes plus explicit dependency/routing entries, and verified central Collector 196/196 with no skip/failure/runtime warning. Scripts passed 205/two dirty-project conditional skips and typecheck/safety/invariants passed. The nine-path candidate awaits pinned staged drift, final integration/record gate, commit/push and its own CI. T3b and A5b remain separate donors; further T3b sibling-registry/tier RED cases are not waived by earlier GREEN. This slice proves no native FSEvents, uploader, Service/Web runtime, browser or full W3-W6 acceptance; W7 authority is unchanged.

- **T3b central candidate / N3-B1 push (2026-09-06)**: N3-B1 passed its independent final gate and was normally committed/pushed as `5073f3f8`; exact-head Tests `34016074877` and dependency review `34016074843` succeeded, CodeQL `34016074803` is pending. T3b passed supplemental independent implementation gates and donor 45/45 plus Core 1,713/one skip/zero failures, retaining original test bytes. Four matching files and four generated test references entered the central candidate. Central Core 1,726 and Service 875 passed with one existing skip each and zero failures; App/MCP, staged drift, final integration/commit/new-head CI remain pending. A5b has real 13-new-case RED with all old 49 passed; two additive budget tests remain donor-only pending RED. Runtime wiring, native watch, uploader, browser and W3-W6 acceptance are incomplete; W7 remains separate.

- **T3b combined-gate follow-up (2026-09-06)**: Exact `5073f3f8` Tests, dependency review and CodeQL all succeeded; CodeQL Gate completed 06:49:03 UTC. Central App v1's sole failure was a stale call-string source scanner; its one-line correction passed App v2, 2,901 total/one existing skip/zero failures/11 QoS warnings, including App 1,175 and the rerun Core suite. MCP passed 270/270 without skips/runtime warnings; both actual producers exited 0. Pinned staged drift passed. The ten-path candidate awaits final independent integration/record review, commit/push and new-head CI; unchanged Remote/Collector suites were not rerun. A5b valid-DTO budget tests have real RED and its isolated donor implementation is under focused GREEN verification. Native watch, runtime, uploader, browser and W3-W6 acceptance remain incomplete.

- **T3b final candidate gate (2026-09-06)**: Independent ten-path integration and record/index gates passed SPEC PASS / QUALITY APPROVED with unchanged donor hashes, scanner-only adjustment, matching staged bytes and pinned drift v2. Prior-head CI is verified separately. The authorized normal commit/push is next; no new-head CI or full W3-W6 result is claimed.

- **A5b integration / T3b push (2026-09-06)**: T3b is normally committed/pushed as `6a33a42a`; its dependency review passed while Tests `34017787159` and CodeQL `34017787170` are pending. Independently approved A5b passed donor focused 68/68 and full Remote 391/391, then entered central by four unchanged file hashes plus four pinned generated test references. Central full Remote passed 391/391, zero skips/failures/runtime warnings and actual exit 0; scripts 205/two conditional skips and typecheck/safety/invariants passed. Final nine-path integration/record review and staged drift remain pending, and the next push waits for T3b CI. Service metadata production, real transcript authority, browser and full W3-W6 remain incomplete; A5c/N3-B2 are separate proposal/test-draft work.

- **A5b final candidate gate (2026-09-06)**: Independent nine-path integration/record review passed SPEC PASS / QUALITY APPROVED with unchanged four hashes, exact old-test inverse, index/worktree equality and verified xcresults/producer exits. Pinned staged drift v1 passed. T3b Tests `34017787159` now succeeded alongside dependency review, superseding its pending checkpoint; CodeQL `34017787170` is still running. A5b push waits for that prior-head gate; new-head CI and full W3-W6 remain unverified.

- **A5b pushed / next drafts (2026-09-06)**: T3b `6a33a42a` now has all three workflows successful, CodeQL Gate at 07:31:39 UTC. A5b was normally committed/pushed as `18c9bc06`, producer exits 0, and PR #446 remains Draft/open/unmerged. New dependency review `34019523987` passed; Tests `34019524050` and CodeQL `34019524056` are pending. N3-B2 full RED v2 has old 196 passed/new 58 failed/zero skips or runtime warnings, authorizing only native source GREEN. A5c has a frozen metadata-only acceptance in the plan and two-file test-draft authority, not Service/browser/full W3-W6 completion.

Checkpoint follow-up: A5b `18c9bc06` Tests and dependency review succeeded;
CodeQL is still pending. N3-B2 independently reviewed native source passed donor
254/254 injected tests; a separate real temporary-root smoke passed 1/1 after
two retained fixture failures, then full donor Collector passed 255/255. The
smoke records one setup semaphore QoS warning and does not prove native replay,
kernel drops, normalization-form identity end-to-end or W6 latency. Supplemental
smoke/routing review and central integration remain pending; A5c is correcting
its independently rejected initial test draft before RED, not running SQL.

## Problem

Final correction gate: independent five-path staged/record review passed
SPEC PASS / QUALITY APPROVED with exact one-token inverse proof and unchanged
corrected hashes. Normal corrective commit/push is next; fixed-head Xcode 16.4
CI and all donor feature/runtime gates remain separate and unverified.

CI correction checkpoint: `010a2c5d` Tests failed during Xcode 16.4 compilation
of one test-helper shadowed property. Independently approved self.records-only
correction passed local central Service 912/one skip/zero failures; 38 test
bodies and producer bytes are unchanged. Final correction gate/commit/new-head
16.4 CI remain pending. No donor feature is included; A5d has actual RED but
its extension GREEN/full Service and all runtime/W3-W6/W7 claims remain separate.

Push/RED checkpoint: A5c is pushed at `010a2c5d` in Draft/open/unmerged PR #446;
its new Tests/CodeQL/dependency workflows remain pending. T4a v5 and N4a v2
have verified behavioral RED, opening only their respective source GREEN;
N4a all 255 old Collector tests passed. A5d's 23-test draft passed independent
review and is under coordinator-owned RED, not implemented IPC. All next-slice
source remains donor-only; runtime/browser/full W3-W6/W7 is not complete.

Final A5c checkpoint: independent seven-path staged integration/record gate
passed SPEC PASS / QUALITY APPROVED with frozen hashes and pinned drift.
Prior-head `843d0038` CI was refreshed successfully; normal commit/push and
new-head CI remain next. T4a v3/v4 RED exposed staging-path fixture errors;
canonical-root/import-only corrections are under v5, not GREEN. N4a/A5d
remain TEST-DRAFT; runtime/browser/full W3-W6/W7 remain incomplete.

Latest integration checkpoint: independently approved A5c source/tests are
central at unchanged hashes, with 912 Service tests passing, one existing skip,
zero failures and one reader QoS warning. Donor baseline scanner correction
and its separate 901-pass result are recorded in CHANGELOG. Final staged gate
and new-head CI remain pending. T4a is executing 45-test RED; N4a/A5d remain
test drafts, not runtime composition or full W3-W6/W7 acceptance.

Latest supersession: A5c focused GREEN v4 passed 38/38 after a byte-verified
NUL fixture correction and a real snapshot transaction/close RED regression;
full donor Service and independent source/spec gate remain pending. T4a second
draft remains correction-only; N4a passed amended feasibility and is only a
two-file TEST-DRAFT. No new central source or runtime readiness is claimed.

Latest checkpoint: `843d0038` now has all three CI workflows successful and
PR #446 remains Draft/open/unmerged. A5c corrected source is running GREEN v2
after a compile-only type fix; T4a's initial test draft failed independent
review and is being corrected before RED. N4a remains a proposal. No overall
runtime, browser, deployment or full W3-W6 result is claimed.

Checkpoint supersession: exact `843d0038` Tests `34024026924` and dependency
review succeeded; CodeQL `34024026923` is still in progress. T4a's supplemental
independent feasibility gate passed SPEC/QUALITY; the plan now freezes its
two-file TEST-DRAFT contract. T4b and runtime wiring remain excluded. A5c source
GREEN is ongoing against 37 frozen tests, not a completed producer.

A5c RED follow-up: the corrected 37-test draft passed independent review and
executed with five passed/32 failed, zero skips/runtime warnings and exit 65.
The earlier missing-CAS-baseline compile failure is retained separately.
Only producer source now enters GREEN; tests stay frozen. See CHANGELOG for
exact hashes/logs; Service wiring, browser and full W3-W6/W7 remain incomplete.

Push follow-up: N3-B2 is `843d0038`, normally committed/pushed with exit 0
after prior-head CI success; staged drift v2 passed. Draft/open/unmerged PR
#446 now has new dependency review `34024026926` successful, with Tests
`34024026924` and CodeQL `34024026923` running. A5c remains test-draft work;
T4a claim/replay/parsed-worker acceptance is proposed only, and skip/no-job
readiness/restart recovery remains T4b. No full W3-W6/W7 completion is implied.

Final N3-B2 gate follow-up: the independent ten-path index/record/source gate
passed SPEC PASS / QUALITY APPROVED with unchanged six hashes; pinned staged
drift v1 passed. Normal commit/push and new-head CI remain next. CHANGELOG
clarifies execution command-session numbers versus OS PIDs without changing
historical records or rerunning tests. Runtime/full W3-W6/W7 remain excluded.

Implementation checkpoint supersession (2026-09-06): exact A5b `18c9bc06`
now has all three CI workflows successful. N3-B2 passed supplemental independent
smoke/routing review and six frozen implementation/routing files are integrated.
Central Collector passed 255/255, zero failures/skips, producer exit 0, with
one retained smoke setup QoS warning; scripts passed 205/two conditional skips
and typecheck/safety/invariants passed. The ten-path candidate awaits staged
drift, final independent index/record gate, commit/push and its own CI. A5c's
two-file draft is now corrected by the bounded worker before independent
review/RED; SQL implementation remains closed. Native replay, kernel drops,
normalization identity end-to-end, runtime wiring, uploader, browser and full
W3-W6 remain unverified; W7 authority is unchanged. Exact logs are in CHANGELOG.

The desired deployment is a lightweight daily-Mac collector, central parsing,
indexing and reading on HQ, and an independent M1 archive replica. Opening or
quitting the macOS App must not control an externally managed service. A browser
must be sufficient to read the central corpus; local offline MCP is not required
for this design unless the owner changes that assumption.

The existing deployment is not this topology. On 2026-09-05 at approximately
14:00 CST, a sample of daily-Mac Service build 1569 resolved against its matching
CoreWrite dSYM to `SessionEmbeddingBackfill.pendingSessions`. The initial scan
had not completed after approximately 33 minutes. This identifies a hot query,
not a claim that all indexing cost has the same cause. The previous
`enqueueStaleFtsJobs` repair is a different query. Live deployment observations
are historical measurements, not acceptance evidence for the changes below.

Existing archive counts also describe captures/generations, not distinct
sessions. An unbound capture is not automatically lost data, and a dual archive
receipt is not evidence that HQ can search or read its full transcript.

## Goals / Non-goals

Goals:

1. Collect enabled sources without requiring a local sessions/FTS/embedding DB
   or App process. Preserve exact bytes where replay has been proved.
2. Upload independently to HQ and M1 with durable retries, explicit per-replica
   acknowledgement, and no dependence on HQ-to-M1 forwarding.
3. Let HQ own parsing, tier/parent classification, usage, FTS, and optional AI
   work, through the existing service writer boundary.
4. Provide authenticated, read-only Web overview, search, details, and complete
   pageable transcripts through the existing native RemoteServer listener.
5. Package and operate headless binaries with explicit ownership and rollback.
6. Prove per-source coverage before retiring the old local indexer.

Non-goals:

- No new Node product server, third-party data store, local Docker, public
  listener/Funnel, unrelated cleanup, or automatic source deletion/GC.
- No promise that v1 FTS bundles contain original transcripts or full usage.
- No change to archive-v2 legacy receipts, reclamation eligibility, or existing
  remote MCP tools by implication. New capture ACKs never authorize reclamation.
- No browser write APIs, terminal/resume execution, arbitrary IPC proxy, or
  local App redesign. The existing App remains an optional local reader while
  Web becomes the central-corpus reader.
- No production installation, credentials, network changes, merge, or release
  under this source-implementation tranche. Those need a separately confirmed
  target/transaction after the local gates below.

## Current state

Anchors below refer to the named baseline; follow symbol names if lines move.

| Concern | Current source evidence | Consequence |
|---|---|---|
| Local cost | `macos/EngramCoreWrite/Indexing/InsightEmbeddingBackfill.swift`, `SessionEmbeddingBackfill.pendingSessions`; `macos/EngramService/Core/EngramServiceRunner.swift:2275` | The periodic backlog probe fetches full text before the provider check; the hot query repeats FTS work. |
| Readiness | `EngramServiceRunner.swift:477`, `:497`, `:531`, `:554`, `:2090` | Socket ready precedes indexing; periodic indexing/archive drain wait for the initial task, which includes optional embedding work. |
| App ownership | `macos/Engram/Core/EngramServiceLauncher.swift`, `adoptExistingService`, `stopIfOwned`, `restart`, `startHealthMonitor` | Adopted and spawned services must not share termination authority. |
| Exact capture | `macos/EngramCoreWrite/ArchiveV2/ExactSourceCapturer.swift:144`; `macos/Shared/EngramCore/ArchiveV2/ArchiveModels.swift:291` | Capture already produces an immutable manifest with optional `sessionID`; local parsing need not precede raw capture. |
| Archive completion | `macos/EngramRemoteServer/Core/ArchiveStore.swift:577`, `:703`, `:850` | Unbound manifest storage is accepted, but receipts require a session binding and listing is receipt-based, sorted by digest. |
| Wire compatibility | `macos/Shared/EngramCore/ArchiveV2/ArchiveCanonicalJSON.swift:14` | Decode/re-encode equality rejects unknown fields; do not silently extend schema-1 canonical manifests. |
| Privacy | `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift:1633` | Current eligibility requires trusted generation/index state and a normalized project root. Removing local indexing must replace, not bypass, this proof. |
| Coverage | `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift`; `docs/remote-archive-v2.md`, Supported source boundary | Seventeen registered adapters do not mean seventeen exact replay exporters. Current exact capture is Claude Code/Codex only. |
| Live snapshots | `macos/EngramService/Core/RemoteSyncCoordinator.swift`, live publication; `macos/EngramCoreWrite/RemoteSync/RemoteSyncModels.swift` | Legacy live snapshots depend on local FTS and cannot supply the proposed raw-first path. |
| Network boundary | `macos/project.yml:252`; `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift`; `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:29` | RemoteServer currently has no DB-core dependency; general IPC transport can attach write capability tokens. |

## Proposed design

### 1. Roles and process ownership

| Host/role | Required processes | Work performed | Work explicitly absent |
|---|---|---|---|
| Daily Mac | Headless collector, managed by launchd | Known-root inventory, stable capture/export, local privacy proof, durable spool, two direct uploads | Session index, FTS, embeddings, AI generation, repository discovery, mandatory App |
| HQ | Existing RemoteServer plus independently managed EngramService; collector for HQ-local sources | Immutable archive intake, central ingest/index/read; local source collection | Browser-owned writer; forwarding as the only M1 copy |
| M1 | Existing RemoteServer; collector if enabled local sources are present | Independent archive plus local-source capture | Mandatory full secondary index or App |
| Optional App | Existing App | Connect to a service or open the Web reader | Shutdown/replacement of an adopted service |

One process owns each local store. The collector may write only its own
inventory/spool DB, never the product `index.sqlite`. The HQ Service remains the
only product writer. Shared capture code can be extracted into a narrow native
collector target only when its file boundary is known; do not link and start the
entire indexer merely to call it a collector. Dependency checks must prove this.

Freeze the host-role setting before W3/W5: owner-only `settings.json` has
`runtimeRole = local | collector | index | replica`, with missing value retaining
the existing `local` behavior and an invalid explicit value failing closed.
Both launch configuration and App read the same persisted value; an environment
variable alone is insufficient because Spotlight does not inherit it. In
`collector`/`replica`, the App takes a Web-entry/unavailable branch before
`db.open()` or any service spawn/restart wiring. It must not display stale local
DB contents as the central corpus. In `index`, Service is externally supervised;
an absent initial socket never grants App process ownership. The `local` mode
retains the legacy App-owned workflow. MCP on a collector-only host reports
unavailable/configuration guidance, not success against stale local data.

An adopted service remains external for the lifetime of that attachment. Quit
only cancels probes and detaches. Failed probes report unavailable and retry
connection; manual restart of an adopted service is a reconnect request, not
permission to signal it, acquire its writer lock, spawn a replacement, or clear
its runtime secret. App-owned child stop/restart behavior remains unchanged.
W1 covers a successfully adopted attachment, not the initial probe before
ownership is known. Headless-role packaging must explicitly select external
ownership even when the first probe fails; do not use W1 as proof that every
startup/quit cancellation race or absent-socket launch has been addressed.

Shadow collection uses a separate owner-only root, such as a task-provisioned
`collector-shadow/`, with its own CAS/catalog/queue. It must never open the live
`~/.engram/archive-v2/archive.sqlite` as a writer. Provision the same machine UUID
by a read-only read of existing `archive_metadata.machine_id`, then pass that
identity explicitly when initializing the independent shadow catalog. Do not
call the live `ArchiveCatalog` constructor/migrate merely to read the ID. A
missing/conflicting identity on a previously archived host blocks shadow start;
new machines get an identity only during explicit provisioning. Service retains
sole ownership of its live catalog through W6/W7; no simultaneous catalog owner
is introduced by reuse of capture code.

W3 extraction starts with the existing `ExactSourceCapturer`,
`ImmutableArchiveCAS`, `ArchiveCatalog`/`ArchiveCatalogMigrations`,
`ArchiveSourceDescriptor`, canonical/hash/models, and their narrowly required
secure-file helpers. Inventory their transitive dependencies before moving
files. `SwiftIndexer`, `StartupBackfills`, `SessionSnapshotWriter`, FTS jobs,
embedding/AI/repository maintenance, and `EngramDatabaseWriter` are forbidden
collector dependencies. Reuse may include a collector-owned GRDB catalog, but
not the product writer module or product schema. File moves and target routing
are one coordinator-owned change, not independent copies of those implementations.

### 2. Data planes and compatibility

Keep schema-1 exact manifests, chunks, bound receipts, and recovery semantics
unchanged. Add a separately versioned **collector publication envelope** that
references an existing immutable unbound manifest. This is necessary because
the old receipt contract requires local session binding; it is not a replacement
for archive v2. Implement servers before enabling collector publication.

The envelope contains `schemaVersion`, `machineID`, `sourceInstanceID`,
`collectorEpoch`, a durable positive `sequence`, `manifestSHA256`, and the
representation identifier. It contains no credentials. Exact Claude/Codex
publications use `exact-source-v1`; other representations require their own
explicitly versioned exporter/replay contract and cannot claim exact fidelity.
Do not put extra fields into the existing canonical manifest.

- Machine ID is a persisted machine identity, not a hostname. Source instance
  distinguishes configured roots/runtimes. Sequence is allocated transactionally
  from the collector spool, never inferred from timestamps, mtime, or digest.
- Retry sends the identical canonical publication and publication digest. A
  repeated sequence with different bytes is a conflict, not last-write-wins.
- Epoch survives ordinary upgrades/restarts. Spool restoration/reset must be
  reconciled explicitly; HQ must not let an unrecognized new epoch supersede
  the established stream automatically.
- Upload order is chunks, manifest, then publication. The receiving replica
  verifies referenced bytes and durable storage before issuing a capture ACK
  bound to its own server ID, publication digest, and manifest digest.
- Capture ACK, parsed result, and index-ready state are different records. A
  capture ACK is never converted into an existing session receipt or recovery
  lease. Neither ACK nor indexing alone permits local or remote deletion.
- Each replica maintains its own publication-arrival journal with an opaque,
  monotonically progressing cursor. ACK/journal durability is one recoverable
  transaction; a crash cannot create acknowledged but undiscoverable data.
  Rebuild/reconciliation must be tested, not assumed from directory presence.
- An HQ ingest ledger keyed by publication digest and parser revision records
  pending, processing, parsed, index-ready, retryable failure, or quarantined.
  Commit parsed state with the product snapshot/index-job transaction. Promote
  to index-ready only after the corresponding required FTS job completes (or
  is explicitly not applicable for skip); snapshot UPSERT alone is not enough.
  Cursor advancement must not drop uncommitted work.
- Existing bound receipts remain readable. A bounded, restart-safe bootstrap
  enumerates old receipts from EOF-reset passes, deduplicated by a ledger;
  digest ordering must never be reused as an incremental arrival watermark.
  Legacy captures without an order proof do not overwrite newer collector data.

The concrete W2 contract is specified below and locked by shared fixtures before
client/server implementation diverges. All additions are default OFF; old
clients and servers continue serving unchanged v1/v2 paths. Unsupported new
capability means retained local backlog and an explicit status, not fallback to
a weaker privacy/durability contract.

#### W2 publication intake contract

This tranche accepts only `exact-source-v1` referring to an existing schema-1
Claude/Codex manifest. New formats are rejected, not optimistically decoded.
IDs use canonical UUID strings, digests lowercase SHA-256, and sequence is a
positive Int64. Publication digest is SHA-256 of its canonical envelope bytes.
Maximum publication is 2 KiB; acceptance record is 4 KiB; response page is
256 KiB, default 50/maximum 100 records; cursor is at most 256 bytes. Canonical
decoding rejects unknown fields/version/representation and noncanonical encodings.

| Endpoint | Frozen behavior |
|---|---|
| `GET /v2/archive/publication-capabilities` | Authenticated version/representation/limits advertisement; no secret or path fields. |
| `PUT /v2/archive/publications/:digest` | Canonical JSON publication; 201 for first acceptance, 200 for identical retry, both return the same ACK. |
| `GET /v2/archive/publications/:digest` | Accepted publication plus ACK, or 404. |
| `GET /v2/archive/publications?cursor=...&limit=...` | Arrival-ordered accepted records, `afterCursor`, and `hasMore`; EOF still returns a valid reusable cursor. |

Use existing archive bearer auth and a separate default-OFF publication switch.
Closed feature returns the existing disabled/not-found behavior and creates no
new journal/lock files. Wrong/missing auth returns 401; malformed input/cursor
400; unknown digest 404; tuple conflict, journal mismatch or ahead-of-tail cursor
409; oversized body 413; wrong content type 415; failed manifest/reference proof
422; temporarily unavailable/poisoned intake 503. Error codes are fixed symbolic
strings without paths/body contents. DELETE remains 405. No new cross-origin
policy is applied to existing routes.

One encrypted immutable **acceptance record** contains the canonical publication
and ACK (`serverID`, `journalID`, positive `arrivalOrdinal`, publication/manifest
digests, canonical `storedAt`). It is stored under the publication digest with
a new archive envelope kind; existing kind numbers and raw-digest checks remain
unchanged. Its successful file-fsync / exclusive-rename / directory-fsync is the
single commit point for ACK and discoverability, not two separate durable writes.
The new envelope may use a publication-keyed payload as receipts use manifest-
keyed payloads; authenticated raw-payload hash still verifies all record bytes.

A durable `serverID+journalID` metadata record precedes the first acceptance.
Existing acceptance files without that metadata fail closed. A new empty store
gets a new journal ID; no store reset silently reuses another cursor namespace.
Publication storage holds a lifetime filesystem lock and in-process mutex;
value copies of ArchiveStore share their lock/allocator owner. It verifies the
manifest machine identity, supported replay/source shape, every referenced
chunk and whole-source digest before durable acceptance.

The in-memory lookup/tuple/arrival index is derived from acceptance files. A cold
rebuild streams files without loading transcript bodies; incomplete or poisoned
rebuild serves publication 503 without blocking old archive endpoints. Duplicate
arrival ordinal, conflicting sequence tuple, corrupted record, or foreign
server/journal identity fails closed. There is no second authoritative DB/cache.
Uncertain rename/fsync failure poisons allocation until record durability and
the derived index are reconciled; never reuse an uncertain ordinal. Ordinal
overflow fails explicitly. An acknowledged record must survive process restart
and be rediscovered from disk with no retained memory state.

Arrival ordinal is replica-specific and distinct from collector sequence. The
replica accepts old-but-unseen sequence values and unapproved epoch branches as
durable bytes, but never promotes them into the current HQ read model. A repeated
`(machineID, sourceInstanceID, collectorEpoch, sequence)` with different digest
is 409. The canonical base64url cursor encodes version, journal ID and last
returned arrival ordinal. Empty EOF preserves the cursor; later arrivals are
readable even when their digest sorts before older data. Page-size budgets may
return fewer records but must advance exactly past returned items.

HQ initially registers approved source instances/epochs from the provisioned
host manifest, not from whichever network request arrives first. Spool reset
creates a retained new epoch branch and an explicit recovery-required state;
it cannot silently replace last-good data. W4 defines a local authenticated
`collectorApproveEpoch` operator IPC action, never exposed to Web, requiring
machine/source instance, old+new epoch, and an exact expected current binding.
The action appends an epoch transition/reconciliation record. New epoch sequence
may restart, but a separately increasing HQ authority generation prevents rollback
across epochs. Until source inventory reconciliation passes, old sessions remain
last-good and missing new-epoch entries do not retract them. Read-only dry-run
lists affected identities; a mismatch refuses the action. No such operation is
performed during this source tranche.

### 3. Capture, privacy, and source fidelity

Source discovery uses only configured/known roots, not a home-directory crawl.
Bootstrap has a durable inventory and restart checkpoints. FSEvents then marks
locators dirty; an overflow or missed-event indication requests reconciliation.
Budget capture bytes, file count, concurrent uploads, and retry rate separately.
The current traverse-and-sort-all locator path is not a bounded implementation.

Privacy eligibility is proved locally against the same stable generation as the
uploaded bytes. A minimal source metadata reader establishes the normalized
project root and source identity without building a session index. Missing,
conflicting, truncated, or invalid identity/root evidence remains withheld.
Explicit excluded roots remain excluded. Symlinks, traversal, changing files,
and unsafe adjacent dependencies fail closed. Eligibility is rechecked before
upload when policy changes. Policy changes cannot retroactively erase already
authorized remote bytes; report that limitation.

For W3's first two formats, the streamed metadata projection uses the same
selection rules as current source parsing: Claude takes the first nonempty cwd
on user/assistant records (`ClaudeCodeAdapter.aggregateSessionInfo`); Codex takes
cwd from the first applicable `session_meta.payload`
(`CodexAdapter.sessionInfo`). Native identity and Claude-derived source detection
use the same helpers/rules, including minimax/lobsterai distinctions. Extract a
shared narrow projection helper with parser-equivalence tests instead of copying
heuristics or inferring cwd from an encoded folder name.

The projection scans the immutable captured generation, recording all recognized
cwd/source conflicts. It may be stricter than current indexing: multiple roots,
source disagreement, malformed/truncated proof, unsupported derived source, or
limits preventing a complete privacy assessment mean `withheld`, not upload.
This conservative distinction is explicit and tested; it is not advertised as
identical upload eligibility. The local proof binds manifest digest, whole-source
SHA, stable generation, source/root result, and a revision/digest of exclusion
policy. Revalidate the policy revision immediately before each upload. Do not
add proof fields to the schema-1 manifest or call a local inode proof an HQ proof.
Privacy tests compare chosen cwd with parser output, then test later cwd changes,
excluded prefix boundaries, missing cwd, symlinks, changing bytes, derived source
opt-out, and partial lines. Local exact capture can still retain withheld bytes.

Every enabled source receives a coverage row: roots, discovery mechanism,
representation, privacy proof, parser/replay fixture, latest successful capture,
latest HQ index, and an explicit unsupported reason where applicable. For
database-backed sources use a consistent, scoped read/export, not a byte copy of
an open SQLite main file that ignores WAL. Composite sources need a verified
dependency manifest. Cache-only adapters remain cache-only; no new live provider
API or credential access is introduced implicitly.

Grok/Pi are separately tracked missing adapter coverage, not newly broken
registered adapters. Inventory their user-approved roots before deciding whether
they block retirement on a host. Standard Codex CLI, Orca-launched Codex, and
OpenAI-bundled Codex roots must be assessed independently. If runtime diagnostics
are performed, record executable, version, config home/file, loaded instruction
chain, and session start separately for each; do not infer one from another.

The old indexer stays enabled for every source without a proved replacement.
No claim of a fully lightweight host is allowed while such a fallback remains.
Raw `skip`/dispatched content is preserved when privacy-eligible, but normal
search/list visibility still obeys skip/lite rules after central parsing.

### 4. HQ parsing and read readiness

HQ uses the existing Swift adapters, snapshot writer, FTS jobs, tiering, and
parent-link rules behind `ServiceWriterGate`. Replayed bytes live in confined
service-owned paths or a dedicated archive resolver; never follow a client's
absolute locator on HQ. Do not overload `remote://` FTS-only snapshots as though
they were replayable sources.

Logical central identity includes machine, source instance, adapter source, and
native session ID. Persist the native ID/provenance separately and map parents
inside the same namespace. Two machines with an identical native ID cannot
overwrite each other. Newest accepted stream sequence controls replacement;
older retries/backfills cannot revert a newer good session. A malformed newest
generation records failure while retaining the last good read model.

Freeze identity encoding through the existing `ImportRepo.importedLocalId`
helper: peer is `capture-v1.<canonical-machine-UUID>.<canonical-source-instance-UUID>`;
its session ID component is base64url of canonical JSON `[source, nativeID]`.
This preserves the existing `remote:<peer>:<sessionId>` namespace, avoids delimiter
collisions, and does not use `remote://` file locators. Full provenance remains
in an ingest identity-binding table rather than being recovered by ad hoc ID
splitting. Legacy live peers such as `hq` are different authority namespaces and
their old retraction loops must never select capture peers.

The parser receives a logical source locator/replay layout separately from its
physical byte location. Preserve the original Claude subagents-relative path,
parent path and source classification; a temporary basename must never reach
`stableSubagentFallbackId`. Parent/related IDs are mapped through the same
namespace/binding table before snapshot writes; manual unlink stays authoritative.
Fixture the same exact bytes under different staging roots and assert identical
native identity, parent, role, and tier.

Before bootstrap or production activation, provision a stable source-instance
map for `(machineID, source, configured root)`. Old bound receipts resolve through
that map using their verified source/locator/replay layout. They do not invent
a second `legacy-archive-v2` instance or random UUID. Missing, overlapping, or
ambiguous maps quarantine rather than create a visible duplicate. Bootstrap
imports history only when no ordered publication owns that identity; later old
receipt arrivals never overwrite an ordered last-good generation.

Existing local/native or legacy-live rows are not silently rewritten, deleted,
or duplicated during shadow mode: use a separate HQ shadow DB/socket. Before
production cutover, an explicit reconciliation creates identity aliases to the
existing stored session ID only with exact machine/source/locator/native-ID
provenance and matching captured-byte proof. Preserve dependent insights,
parents and user metadata by retaining that stored ID. Unproved collisions stay
quarantined and block coverage acceptance. New identities use the encoding above;
all subsequent lookups/writes use the persisted binding. No fuzzy cwd/title/id-
alone match may claim that old data and a new stream are the same session.

Expose independently: collector heartbeat, last captured generation, per-replica
ACK lag, ingest backlog/age, parse failures, FTS readiness, and optional AI state.
Counts must state their unit (files, generations, logical sessions, visible
sessions). Collector offline, transport blocked, bytes durable but unparsed,
parse failed, and searchable are distinct user-visible states.

Initial queryability must not wait for external embedding providers. First fix
the measured rich-text query, then introduce bounded background AI maintenance
after required indexing readiness. No-provider/backoff checks precede backlog
work. FTS completion is required for keyword-ready, not for capture durability.
Old terminal parse/index failures remain terminal unless an explicit source
generation/version change or separately authorized retry policy reopens them.

### 5. Read-only Web boundary

Use the existing native RemoteServer/Hummingbird process. Add an optional Web
module with a narrow, typed read facade over local Service IPC. RemoteServer
must not link CoreWrite, open `index.sqlite`, or accept an arbitrary command/body
to forward. The facade allowlists only the concrete read operations below and
does not load a capability token. Update dependency/negative tests with the
module; do not remove the existing architectural guards.

| Route | Contract |
|---|---|
| `POST /web/api/auth` / `DELETE /web/api/auth` | Exchange a dedicated viewer credential for a short-lived same-origin session; logout revokes it. |
| `GET /web/api/overview` | Status/source/ingest summary with freshness and capability fields, no secret/config dump. |
| `GET /web/api/sessions` | Bounded list or keyword search, source/machine/project filters, deterministic page cursor. |
| `GET /web/api/sessions/:id` | Read-only metadata and provenance; not a raw path or resume command. |
| `GET /web/api/sessions/:id/messages` | Bounded message pages plus continuation for oversized individual content, no silent truncation. |

Pages are native-bundled static HTML/CSS/JS; no runtime Node or external CDN.
Keep browser credentials in an HttpOnly, short-lived cookie, not URL/localStorage
or HTML. Viewer credentials must differ from archive/v1/MCP credentials.
Production Web requires an explicitly configured HTTPS origin; existing tailnet
HTTP archive listeners need not change and Web remains off until approved HTTPS
exposure exists. Tests may use loopback HTTP with explicit test-only settings.

Require exact Host/Origin validation, no wildcard CORS, CSRF checks on login and
logout, bounded bodies/pages/timeouts, login throttling, `Cache-Control: no-store`,
CSP without inline script/eval, and same-origin assets. Render session/tool text
as untrusted text; no raw HTML, executable Markdown, remote images, or active
links without a safe scheme policy. Unknown/write routes return a safe rejection
before IPC. Service unavailable returns 503, not an empty successful corpus.

The initial reader is keyword-only. Semantic/hybrid is not advertised unless a
later explicit capability contract is implemented and tested. Archive-only M1
does not pretend to offer a complete secondary searchable Web corpus.

W4 must add a typed read-only IPC continuation contract before W5 starts real
transcript integration. Request identifies central session, immutable generation,
role filter and an opaque cursor containing message ordinal plus UTF-8 content
offset. Response carries stable generation, fragments, message identity/role,
continuation and truthful completeness. Redact each complete supported message
before splitting its content, and split only at valid UTF-8 boundaries. Build
fragments against the final encoded JSON/frame size, not character count; keep
the result below the existing 256 KiB frame ceiling with envelope headroom.
The same cursor reads the same generation; changed/unavailable generation gives
an explicit stale-cursor error, never silently switches content mid-page.

The concrete projection is `redacted-normalized-message-json-v1`. Preserve all
NormalizedMessage fields, including toolCalls name/input/output and usage. Apply
the existing redaction policy to each complete string field before canonical
JSON encoding; fragment the resulting UTF-8 payload, not just message.content.
Each fragment carries ordinal, role, full redacted-payload SHA, payload offset
and completion. The browser reassembles that whole message payload before
JSON.parse and text-only rendering, so large tool fields also continue without
loss. Cursor offsets may split ASCII JSON escapes but never a UTF-8 scalar;
the client must not parse individual fragments. Bind cursor state to session ID
hash, immutable generation, projection/redaction revisions and canonical role
filter; writer databaseGeneration is not that immutable generation. Account for
the final success envelope's base64 Data expansion, not merely inner page JSON.
This is complete normalized-message projection, not preservation of raw log
bytes or a promise that parser limits disappear. Partial/failed sources never
become complete, even if the parser returned some messages.

The existing `archiveReadSessionPage` prefix-truncating response is forbidden as
the full Web transcript path. Oversized messages within parser limits must have
continuations that reconstruct the complete redacted content. Source/parser
limits (currently 100 MiB file, 8 MiB line and 10,000 messages) remain explicit:
unsupported/partial source must report an error/completeness boundary, not a
successful full transcript. Raising those limits is a separate measured change.
W4 tests exceed 160 KiB in one message, use escape-heavy Unicode and redaction
matches crossing fragment boundaries, and reconstruct exact redacted output.

Web transport is a dedicated typed read client with no capability-token loader
and no generic caller-supplied command string. Exhaustively compare the handler
command inventory against its fixed allowlist; deny everything else before IPC,
including `resumeCommand`, `memoryFileContent`, `exportSession`, and `shutdown`,
whether or not the general capability list currently marks it protected.
Host validation covers every Web asset/API route, including failures. Every API
request requires the single exact `X-Engram-Web: 1` header. Login and logout also
require JSON and a single exact configured Origin. An authenticated GET with an
Origin header requires that same exact Origin: empty, null, malformed, duplicate,
comma-list or mismatched values fail closed and never use a fallback. Only when
Origin is entirely absent may GET use all of these single-value checks together:
`Sec-Fetch-Site: same-origin`, `Sec-Fetch-Mode: cors` or `same-origin`, and
`Sec-Fetch-Dest: empty` (the literal token, not an empty/missing value). Missing,
duplicate or other values fail closed. Cookies and exact Host are still required;
metadata is not authentication, and non-browser clients can forge it. Do not use
Referer or Forwarded as an alternative. OPTIONS, HEAD and unlisted methods remain
rejected before IPC; do not add automatic HEAD or a CORS preflight allowance.
Top-level static navigation may lack Origin, but receives no data or credentials itself.
This corrects the earlier mandatory-Origin GET rule: same-origin browser GET
normally omits Origin and script cannot set it, per the
[Fetch algorithm](https://fetch.spec.whatwg.org/#origin-header). The
[Fetch Metadata draft](https://www.w3.org/TR/fetch-metadata/#sec-fetch-dest-header)
defines the literal destination token. Chrome 152 loopback evidence is recorded
in the 2026-09-06 CHANGELOG; real Web tests must cover this positive path and the
same-site/cross-site/no-cors/navigation negative paths without forged test headers.
No shared global Origin/CORS middleware is added. Existing authenticated MCP
POST rejects any Origin; current archive routes use bearer auth without that
blanket Origin rejection and must not be described as having one.

The first concrete transcript provider requires `lastParsed == lastReady ==
requestedGeneration` and current session metadata/owner/source/version/hash
matching that immutable generation. Every page rechecks current source and
visibility authority after asynchronous preparation. A newer parsed but not
ready generation therefore makes transcript reads temporarily unavailable;
the old artifact, ready head and FTS remain durable. This is not historical
last-good transcript-read support, and no current title may wrap an older body.

Metadata DTOs distinguish unknown observations from observed zero/empty values,
and count distinct publications, publication-by-parser tasks and logical sessions
separately. Continuation snapshots bind normalized query bytes, all filters,
limit, sort version and the visibility/registry/FTS view; they are not transcript
generations. The typed client only adds `webOverview`, `webSessions` and
`webSessionDetail` to `webMessages`. Missing providers return unavailable, not
an empty successful corpus. Paths, native IDs and resume commands remain absent.

Retain the same-process Web module as the minimum deployment choice, with its
security cost explicit: an online Web/RemoteServer code-execution compromise can
read that process's archive AES keys and archive plaintext. Read-only DTOs and
token separation constrain normal request authority, not an RCE. They are not a
process/OS sandbox. This follows the existing online-server compromise model;
if separate-key-process isolation becomes an acceptance requirement, use a
separately approved native Web helper with a distinct OS principal/read-only
service capability. Merely adding another same-UID process is not that isolation.

### 6. Packaging and operational transition

Reuse the established headless release-directory/current-symlink pattern.
Packages include required frameworks, a manifest with exact hashes, verification
and dry-run operations, and role-specific launch configuration. Do not install
a bare dynamic-linked helper without its frameworks. Keep App-owned and
launchd-owned labels/locks non-conflicting. No installer mutates an existing
source config, secret, or job without an explicit confirmed transaction.

Shadow mode captures/uploads/indexes a fixture and then a bounded approved
corpus without disabling the old chain. Compare canonical session/message/usage
results and visibility, not just counts. Prove both independent replicas and
HQ reads. Only then propose one-host-at-a-time cutover, first the daily Mac,
then HQ-local and M1-local coverage as appropriate. Preserve old binary/config
and checked DB backups; no automatic cleanup during this migration.

## Invariants affected

Preserve existing invariants 1 (single writer), 2/3 (skip and visibility),
5 (FTS rebuild version), 6 (isolated tests), 7 (no Node bundle), 8 (socket
security), 9 (ordered/idempotent backfills), 10 (manual unlink), 11 (schema
migrations), 12 (MCP read/write boundary), and 13 (complete-line tail replay).
Parser/parent changes require existing parity gates where applicable.

Add ledger entries only alongside implemented code/tests for: external service
ownership, no-index collector, ACK versus index readiness, upload privacy proof,
generation ordering, and Web read-only authority. A planned assertion is not an
already enforced invariant.

## Alternatives considered

- Keep indexing locally and upload FTS: useful during migration, but does not
  remove local parse/index cost or preserve a replayable full transcript.
- Reuse bound session receipts for unbound capture: changes safety semantics and
  could weaken reclamation guarantees; use a distinct publication/ACK contract.
- Put HTTP in EngramService: adds network attack surface to the writer process
  and repeats a removed product path; reuse the separate RemoteServer boundary.
- Add a third Web process/Node server: unnecessary deployment and dependency
  growth for a small read-only surface.
- Centralize before local privacy decisions: sends data before exclusions are
  known; rejected.

## Test plan

All production behavior changes start with failing behavior tests, then the
smallest implementation. Work is gated in dependency order in the linked plan.
Fixtures live in temporary homes/stores and do not contact model providers.

- W1: deterministic SQLite VM-step regression plus text/order/tier/limit
  equivalence; external-process lifecycle socket tests, including cancellation
  races and preservation of App-owned behavior.
- Wire/capture: canonical compatibility, crash/restart/idempotency, two-server
  identity separation, wrong ACK/hash, missing chunks, capability refusal,
  exclusions/unknown metadata, mutable file/WAL/multi-file snapshots, inventory
  overflow, disk pressure and failed network retry.
- Ingest: namespaces/parents, out-of-order versions, epoch resets, crash between
  data and checkpoint, bad generation preserving last good data, full transcript,
  usage/cost/tier parity, old-receipt bootstrap, service single-writer contention.
- Web: auth/CSRF/Origin/Host, every denied mutation, no token auto-attachment,
  adversarial transcript/XSS, server-side title/snippet/tool/message redaction
  before pagination without changing stored exact bytes, pagination without loss/duplication, very large
  message continuation, service failure, browser keyboard/mobile/read rendering.
- Performance targets to verify, not current claims: steady-state collector
  average CPU <=2% of one core and RSS <=150 MiB over a 30-minute representative
  window; bounded bootstrap separately reported; p95 capture-to-HQ-search <=120s
  for small append fixtures on healthy tailnet; p95 indexed Web reads <=2s.
  Publish host/corpus/workload/concurrency when measuring; do not tune away
  failures or compare idle and bootstrap as the same workload.

## Rollout

W1 repairs can be reviewed independently. New network/collector paths stay off
until contract, replay, privacy, and operational gates pass. Source completion
does not authorize deployment. Production checks require dated host-specific
evidence: binary/hash, unique job/process/socket, source coverage, two replica
ACKs, full HQ query/read, observed lag, and rollback assets. Reboot testing is
separately authorized; a healthy listener is not reboot proof.

Rollback disables the new role/path, returns to the retained prior binary/config,
and preserves every new immutable archive and ingest ledger for reconciliation.
No rollback deletes source data or downgrades an incompatible DB in place. Use a
checked backup with the matching old binary when migrations require it. Stop
only the exact task-owned process after re-identifying PID/path/start time.

## Risks and open questions

- Full source coverage is the largest dependency; Claude/Codex-only success is
  insufficient to retire a host that uses unsupported database/composite tools.
- Confirm the no-offline-MCP assumption before final daily-Mac retirement. No
  answer so far is treated as the stated design assumption, not confirmed need.
- Publication record durability/cursor recovery now has a concrete W2 contract;
  implementation crash tests still must prove it. W4 IPC extraction and identity
  reconciliation must follow the frozen boundaries before W5 integration.
- HTTPS setup and viewer credential provisioning require separate operational
  authority; no implicit changes to Tailscale, Keychain, or existing tokens.
- Local corpus size, optional provider behavior, and historical terminal jobs
  can still affect central cost. W1 is not proof of end-to-end performance.
- An online archive server compromise remains able to read its own decrypted
  data, as in the existing archive threat model.

## Independent design review adjudication (2026-09-05)

Grok reviewed this worktree read-only in the owner-provided Herdr pane. Its first
design verdict was FAIL / CHANGES_REQUESTED; W1 remained independently runnable.
The following revisions address its seven grouped issues, not seven observed
production failures. At approximately 17:03 CST its bounded follow-up reread the
revised design/plan and source anchors and returned SPEC_COMPLIANCE: PASS and
CODE_QUALITY: APPROVED, closing B1-B7 without a new design blocker. W2 intake and
W3/W4 interface boundaries are frozen for implementation. This is design
readiness, not implementation, crash-test, operational, or deployment approval.

| ID | Adjudication / correction |
|---|---|
| B1 | Accepted identity/replay/legacy gap: freeze ImportRepo encoding, original logical locator, source-instance map, explicit alias reconciliation and separate shadow DB. Reusing a namespace does not by itself prove old/new equivalence. |
| B2 | Accepted shadow ownership gap: independent CAS/catalog with explicitly provisioned existing machine ID; live catalog stays Service-owned. |
| B3 | Accepted need for concrete metadata rules/tests: same parser projection plus explicit more-conservative conflicting/partial-proof withholding. Existing upload privacy is preserved, not newly invented. |
| B4 | Accepted IPC gap: W4 owns message/content continuation and encoded-frame budgets; old prefix-truncating command is not a complete Web reader. |
| B5 | Accepted role gap: persisted role gates App DB/spawn before startup; W1 adopted behavior alone is insufficient. |
| B6 | Accepted recovery gap: single durable acceptance record, filesystem allocator lock, journal ID/cursor reconstruction, explicit epoch reconciliation authority. |
| B7 | Partially accepted: typed no-token transport, exhaustive command denial, route-local Origin and explicit same-process compromise model. Corrected the claim that archive routes already reject any Origin; only MCP POST does. A separate same-UID helper is not automatically an isolation boundary, so a third process is not added by default. |
