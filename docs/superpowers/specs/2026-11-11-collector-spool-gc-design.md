# Design Doc: Collector spool GC (K5)

- **Status**: Draft — direction accepted by t11; Phase B1 implements preview only. B2 execution and all production actions remain separately gated. Proposed policy parameters are not production-approved.
- **Owner**: Codex, with coordinator/owner acceptance through t11.
- **Date**: 2026-11-11
- **Related**: `/tmp/engram-k5-brief.md`; [invariants](../../invariants.md#collector-spool-reclamation-authority-draft); [design template](../../templates/design-doc.md); `CHANGELOG.md` sections on K6 and the 11-09/10 remediation. Private research: `~/.engram-shadow-core-20260911/hq/ops-notes/cleanup-research-20261111/{00-ERRATA.md,review-safety.md,review-code.md,collector-spool.md,plan.md}`; `/tmp/engram-noise-cleanup-verdict.md`, “Addendum 1 verdict”.

## Problem

The collector retains immutable chunks from superseded captures indefinitely. ACKs record historical replica acceptance; they do not establish current recoverability or central ingest readiness. Deleting by age, ACK count, or the legacy bound-manifest index can destroy shared or spool-only content.

The 11-09/10 incident is the regression to prevent: an ad hoc job used the empty `archive_manifest_objects` table as its keep-set, stranded 1,437 publications, and left 40 Claude generations unavailable until 1,067 objects (319 MB) were recovered from Time Machine. The remediation also re-dirtied 55 locators. These are historical incident records, not freshly reproduced production results (`collector-spool.md` §8; `CHANGELOG.md`, remediation and cutover review).

The later Addendum 1 snapshot found 1,680 M1 captures, 1,675 ACKs and five withheld publications per replica, and 1,409 distinct latest capture IDs, while both legacy object-reference/residency tables had zero rows. Neither the historical-capture difference nor summed capture bytes measures reclaimable unique physical storage. No new live size estimate is made in this design.

## Goals / Non-goals

- Prove a complete reference graph from unbound manifests; keep shared objects whenever any reference is protected or unknown.
- Reclaim only proven superseded chunks, in bounded, explicit offline operations with a reversible quarantine and verified restore.
- Keep collector publication, privacy reassessment, deduplication and restart behavior correct while objects have recorded nonresident states.
- Provide a token-free, nonmutating preview. Require current central evidence, dual-replica P-PROOF and explicit operator apply before mutation.
- Start the eventual pilot on **M2**, as the new owner brief specifies. The older research's M1-first order is superseded.
- Non-goals: native-file retirement (K1/K4), compression support, Grok identity changes, central CAS/generation pruning (K7/K8), replica deletion/movement, deleting manifests/capture rows, VACUUM, automatic scheduling, Web/UI changes, or changing K6.

## Current state

Code references below are relative to the repository at **`5a4fdb1f99477317a16f0d4d97e8eff729517b0c`**. They describe this design baseline, not binary equivalence on a host.

| Verified source | Consequence for K5 |
|---|---|
| `macos/EngramCaptureShared/ArchiveCatalog.swift:608` validates and records unbound manifest bytes; `:790` populates legacy object/residency tables only during binding. | Parse every `archive_captures.unbound_manifest_bytes`; never infer collector references from legacy tables. |
| `macos/EngramCollectorCore/CollectorInventoryStore.swift:873` claims only non-ACKed publications at the current root revision; `:918` validates ACK identity; `:938` backs off deferrals. | Old-revision, unpublished and withheld rows still matter even if an upload selector cannot currently claim them. |
| `macos/Shared/EngramCore/ArchiveV2/CollectorPublicationModels.swift:99` states ACK is storage proof only; `:103` carries `journalID`. | A logical replica label is insufficient for a proof lease; bind the storage instance too. |
| `macos/EngramCollectorCore/CollectorPublicationWorker.swift:2003` reads local manifest/chunks before upload; `:1987` maps invalid capture to `localContentUnavailable`; `:1422` reads previous Cursor legacy chunks for comparison. | GC needs residency-aware readers before any production eviction. Existing missing-object retries are not a recovery mechanism. |
| `macos/EngramCaptureShared/ExactSourceCapturer.swift:346` republishes staged chunks even for an existing capture; `macos/EngramCaptureShared/ImmutableArchiveCAS.swift:321` publishes with `link(2)`. | Recapture may recreate an evicted digest. Its new reference must pin it and invalidate old unlink authority. |
| `macos/EngramCollectorCore/CollectorInventoryOwner.swift:65` limits flock to cooperating processes; `:125` opens/fences storage and takes the nonblocking owner lock before preparing the DB. | A writable owner open is unsuitable for a token-free/read-only preview. Apply must share the real lock and still detect external path/byte changes. |
| `macos/EngramCollectorCore/CollectorRuntime.swift:163` opens owner/catalog before loading credentials and making workers. | Insert GC recovery before worker creation/claiming. Do not start the ordinary runtime for preview. |
| `macos/EngramCollectorCore/CollectorEventCoordinator.swift:210` requests a restart walk and `:226` resumes the durable checkpoint; `CollectorNativeEventStream.swift:179` resumes historical events. | Stopping/restarting does not erase removal events. K5 must never clear checkpoints or rewrite dirty revisions. |
| `macos/EngramCollectorCore/CollectorRuntime.swift:1126` reconciles native epochs under the same lock; `CollectorPublicationWorker.swift:717` uses previous capture metadata for K6 cooldown. | Reconcile and GC are mutually exclusive; keep capture metadata and cooldown state intact. |
| `macos/EngramCoreWrite/CaptureIngest/CaptureIngestLedger.swift:21` distinguishes `parsed`, `index_ready` and quarantine; `CaptureIngestCommitter.swift:111` reads historical generations and `:496` checks duplicate heads only at commit. | A terminal label or old duplicate decision alone cannot establish a retained normalized generation. No K8 pruning is assumed. |
| `scripts/check-archive-v2-safety.sh:40` limits primitive scanning to ArchiveV2/shared capture/Archive service files. Its route scan at `:263` now enumerates all server Swift files, but patterns at `:286` match router registration, not manual HTTP dispatch. `macos/EngramRemoteServer/StorageOnlyMain.swift:401` manually rejects v2 DELETE. | Extend collector/ingest primitive coverage and add a manual-dispatch 405 guard. Do not describe the current route file enumeration as absent. |

The original main checkout's later local `CHANGELOG.md` records K6 fleet deployment, six HQ epoch reconciliations, native retention pinning and escrow. Those records are inputs to revalidation, not live proof in this task. The escrow at `~/.engram-escrow/spool-20261111/` is recorded as **plaintext on a trusted Mac under an owner decision**, not encrypted NAS storage. It covered then-current non-dual-ACKed captures and consistent database snapshots; it does not automatically cover later captures. The post-K6 24-hour measurement belongs to t82 at `~/.engram-shadow-core-20260911/hq/ops-notes/growth-post-k6-20261111/samples.tsv`; earlier growth projections must not size an apply batch.

## Proposed design

### 1. Operator surfaces and authority

Phase B1 implements only `--spool-gc` preview. Proposed B2 modes (not implemented): `--spool-gc --apply` quarantines a reviewed batch; `--spool-gc --finalize RUN` is a separate explicit unlink; `--spool-gc --restore RUN` restores local quarantine. They are mutually exclusive with collection, initialization and epoch reconciliation. There is no `--force`, unattended retention job, or automatic finalize on restart.

Preview uses dedicated strict readers for existing inventory and capture DBs, `file:...?mode=ro` and SQLite read-only open flags, without migrations, writable `ArchiveCatalog`, owner acquisition, secret loading, network calls or spool output files. If WAL access would require creating sidecars, fail read-only rather than fall back to a writable open. Never use `immutable=1` against a live WAL database. It can print a private report to stdout; writing that report is an explicit caller action.

Read both DBs in read transactions, capture identities and input fingerprints before and after, and label a live preview **provisional** because two separate SQLite snapshots are not an atomic fleet snapshot. A cross-store mismatch, unfinished reservation, changing settings or scan truncation is blocking evidence, not an invitation to repair. The stopped, locked apply must build the graph again. Preview with no central evidence or K9 lease reports conditional candidates and `blocked: proof_missing`; it never reports these as approved reclaimable bytes.

Apply/restore/finalize require the collector stopped by a separately authorized operator, the existing `collector-owner.lock` acquired nonblockingly, and verified spool/identity directory identities. They must not stop a service themselves. A running collector, restarted collector or another GC wins the lock and yields `busy` without mutation. Keep the lock through journaling, all renames/unlinks/restores, postchecks and close. Refuse other open writers/maintenance operations; flock alone is not protection against arbitrary same-user SQL or filesystem writers.

### 2. Complete reference graph and fail-closed keep-set

1. Enumerate **all** capture rows across every status/root revision, including captures without publications, ignored/error rows and reservation-related captures. An unreadable DB, unknown schema, interrupted enumeration, NULL/empty manifest or malformed manifest aborts the entire plan; no partial graph can authorize work.
2. Decode the canonical unbound manifest and check its digest, unbound status, machine/capture identity, source, raw byte counts, chunk ordinals/lengths, replay layout and whole-source metadata against the row. Reject conflicting sizes for the same digest. Retain the manifest file and row permanently in K5; a missing/disagreeing manifest file also blocks apply.
3. Build `refs[digest] -> all capture IDs` from manifest chunks. Publication rows, filesystem enumeration and legacy tables may cross-check this graph but can never replace it. Unreferenced physical files are **unknown/orphans, retained**; orphan cleanup is a separate task.
4. Build the protected capture set first, then `K = union(chunks of every protected capture)`. Independently compute the mandatory floor from every non-dual-ACKed/unpublished capture, every reservation, every latest capture and every unresolved locator/root. Require **set inclusion**, not just a numeric count: `floor ⊆ K`.
5. Empty `archive_captures`, an empty decoded graph, **or an empty keep-set K** yields a non-applicable result with zero mutation, even if physical objects exist or every parsed capture appears eligible. A genuinely empty fresh spool is reported as empty/no-op, never swept. There is no empty-set override.
6. A candidate must be a present, regular, private CAS object with known nonempty `refs`, outside `K`, and every referencing capture must pass the table below. Missing historical objects are reported as pre-existing damage/recorded evictions, never counted as new savings. Any missing/corrupt kept object blocks the host's batch.
7. Hash-read the complete protected object set before and after mutation (including **every** non-dual-ACKed/unpublished object), not just backlog counters. A resource limit that prevents completing this proof blocks apply; preview may report an incomplete estimate only.

### 3. Eligibility: conjunction over every referencing capture

| Gate | Required evidence / blocking case |
|---|---|
| Publication identity | Exact capture, manifest, publication bytes/digest, machine, source instance, epoch, stream sequence and root revision agree. Missing, conflicting or unknown mapping keeps the object. Evaluate every publication of a capture, not one convenient join. |
| Dual ACK | Exactly the configured `hq` and `m1` slots have valid matching ACKs. Pending, inflight, withheld, `localContentUnavailable`, invalid ACK, unsupported replica, missing rows or stale errors keep all their chunks. An ACK alone never passes. |
| Local privacy | Current policy/format assessment of the captured bytes permits their existing publication; withheld/unknown/stale proof keeps them even if historically ACKed. GC never uses a policy relaxation to upload withheld data. |
| P-PROOF | Both current physical replica instances have a valid K9 lease covering publication, manifest and **every chunk**, plus reassembly proof (§4). No sample, HEAD, filename match, legacy receipt or ACK substitutes for it. |
| Central terminal | Fresh evidence for the exact publication/parser revision shows `index_ready` with its retained generation/normalized payload; or `quarantined` with `quarantine.cross_machine_duplicate` and a currently verified matching retained target (§4). All other quarantine/failure/processing/pending states keep data. **Plain `parsed`, including skip-tier rows, stays protected in this first release.** Widening this needs a separate readiness contract. |
| Supersession and locator | First release requires a newer complete capture in the same mapped locator/stream and protects **all latest captures**, even if the native file is absent. It therefore protects the latest generation of every live locator and defers vanished/latest retirement to K1/K4. Unknown ordering/locator is protected. |
| Clean source/root | No dirty revision, retry/claim, active reservation, unfinished bootstrap/reconciliation, suspended root, configuration drift or observed-generation mismatch for any referencing locator. K6 `recaptureCooldown` is still dirty work. Recheck native identity/size/times and root epoch before and after each object transition. A native writer is not stopped by the collector lock; any detected change aborts the batch and restores affected quarantine. |
| Escrow and recovery | Required spool-only escrow coverage is complete for the current protected captures, with verified object/manifest hashes and an approved storage location. `escrow-missing`, stale coverage or unreadable evidence blocks apply for that host. Escrow is additional protection and **never** makes withheld content evictable. P-KEY and the replica restore drill below are also required. |

Shared chunks survive if even one reference fails. Sort the remaining objects by oldest superseded capture time (maximum time among their references), then digest for stable ordering. Never prioritize latest/live, withheld or orphan objects to fill a budget.

### 4. Evidence bundle: K9 lease, central readback and escrow

K9 is a separately authorized **read-only verifier**. Its authenticated GETs obtain each replica's accepted publication record, manifest and plaintext objects; it checks canonical digests, sizes and chunk order, then reconstructs `wholeSourceSHA256` and the source layout (including main+WAL pairs). Publication ACK `journalID`/arrival identity must match the currently addressed store. The server decrypts: **K9 needs the replica bearer token only; it does not need the at-rest key.** At-rest key escrow/decrypt verification (P-KEY) is a separate operational prerequisite, not a token for GET and not permission to rotate keys.

The owner has **not authorized replica token use**. Phase A performs no K9 calls, key reads or lease issuance. The design permits preview without any token. Apply/finalize must refuse without a valid supplied lease; they do not silently load collector credentials to manufacture one.

Proposed versioned evidence bundle fields:

- Bundle version, verifier build/version, run nonce, creation/expiry UTC, policy version and scope digest.
- Spool machine ID and real directory identity, root revisions, source-instance/epoch tuples, capture/publication/manifest hashes and complete per-publication object lists with raw lengths and reassembly results.
- Per replica: logical slot, canonical endpoint, physical host/store identity, `journalID`, accepted publication/arrival identity, object/manifest verification timestamps and failures. Shared disks are recorded, not counted as independent hosts. A replica relocation, journal reset or endpoint/physical-store change invalidates the lease; m1-origin data still requires off-host `hq` proof.
- Central index instance/path identity, parser revision, query time and normalized generation evidence for each publication, authority/epoch snapshot, ledger status/failure code, and duplicate target evidence when applicable.
- Escrow manifest identity and coverage set, current protected-set digest, verification date and P-KEY/restore-drill evidence IDs. No bearer tokens, keys, source bodies or secret-bearing configuration are stored in reports.

The maximum K9 content-proof age is **30 days**; it is capped by the earliest prerequisite expiry. Apply and finalize each require a same-run freshness receipt, at most **five minutes old**, from the authorized verifier confirming both current replica identities and central evidence, bound to the GC nonce/scope. Renew this receipt during a long batch; stop on expiry. Clock skew over five minutes, future-dated proof, unavailable central/replica checks, partial GET failure or unsupported evidence schema fails closed. Content proof cannot substitute for current-instance checks.

Evidence is consumed from owner-controlled private regular files (0600, private parents, no symlinks) or an authenticated verifier pipe. The batch hash binds exact bytes; a hash is **not** an authenticity signature. V1 trusts the local operator and approved verifier executable, not arbitrary imported JSON. Owner approval binds the manifest hash, target spool, action and budgets. Do not add a new signing-key system just for this operator tool. If evidence cannot be sourced through that trusted path, apply remains blocked.

Central reads must use the actual capture index (`~/.engram-shadow-core-20260911/hq/state/service-index/database/index.sqlite` in the research), never `~/.engram/index.sqlite` by assumption. An operator-side verifier opens it read-only and exports evidence; CollectorCore gains no CoreWrite/index schema dependency. For an ordinary historical `index_ready` publication, prove its own retained generation, not that it is today's head. For a duplicate, require source/native identity and identical normalized content in an extant other-machine generation. The current duplicate decision does not persist a target pointer: if the verifier cannot reconstruct and verify the equality (through a separately authorized isolated replay), keep that class blocked. A moved/divergent head invalidates the old duplicate proof. K8 must remain disabled for the pilot; any later pruning integration needs durable target pins before these proofs can be trusted across pruning.

Before final unlink, demonstrate replica-to-private-spool restore from **each** replica on the pilot's source shapes, including S1m; check full reconstruction hashes. This is not a native-history restore or production ingest drill. A future move of a replica slot must preserve its byte-exact history or invalidate proof; repointing an ACKed slot at an empty store is not backfill.

Reconcile the existing `~/.engram-escrow/spool-20261111/` coverage by manifest/object identity, without deleting, moving or modifying that escrow. Missing coverage requires a separately authorized refresh that respects withholding/privacy and the owner-approved destination/encryption policy. Do not assume the plaintext trusted-Mac exception authorizes a new external destination. Old inventory snapshots in escrow are recovery evidence, **not** rollback images to install after sequence advancement.

### 5. Durable state and filesystem protocol

Use the collector's existing inventory DB, under its owner, for new **collector-specific** GC journal/residency tables. Do not populate legacy bound-manifest tables or mutate capture/publication/ACK/identity records to make GC work. Proposed tables:

| Table | Minimum durable fields |
|---|---|
| `collector_gc_runs` | run ID, format/version, machine/spool identity, plan/evidence/input hashes, action, state, creation/hold deadlines, max bytes/objects, consumed/reserved budget totals, failure reason |
| `collector_gc_objects` | run ID + digest key, raw length, allocated bytes observed, complete reference-set hash, original and quarantine relative paths, inode/device/generation metadata, pre/post hashes, per-object transition state and timestamps |
| `collector_spool_object_residency` | digest key, raw length, resident/quarantined/evicted/recoveryRequired state, run ID, quarantine relative path, evidence digest, last verified timestamp, residency generation counter |

Transitions are compare-and-set, transactional within inventory, durably committed before irreversible filesystem steps. Tables are created idempotently in the normal inventory migration path, with inline CREATE definitions and any future add-column list kept consistent. Unknown versions fail closed. No eager all-object backfill: seed only fully verified objects on an explicitly approved apply; absence of a residency row means unmanaged, never evictable-by-default. Capture catalog schema/rows stay unchanged. A complete manifest-derived reference set is rebuilt for each apply/finalize; any cached graph is an accelerator only and must match its input digest.

The inventory and capture catalog remain separate DBs. Do not claim a cross-DB transaction: the stopped collector plus shared lock excludes legitimate writers, repeated identity/data fingerprints detect outside changes, and the journal handles filesystem/DB crash boundaries. Dry-run cannot invoke migrations or the writable owner. Reserve journal/WAL headroom before starting; ENOSPC/fsync/commit failure stops work with recoverable files retained.

Quarantine lives at `<spool>/capture/quarantine/k5/<run-id>/sha256/<prefix>/<digest>`, mode 0700 with 0600 objects, outside all native collector roots and tool-cleanup paths, on the **same volume** as CAS. Refuse symlinks, path traversal, unexpected hard links, mount mismatch, replaced directories or nonregular objects. Use descriptor-relative fenced operations and no-replace atomic rename; no copy-and-delete fallback and no generic recursive removal.

| Phase | Operation and crash interpretation |
|---|---|
| Prepare | Under lock, recompute eligibility and hash checks, reserve the object's full budget, commit `quarantinePrepared` with expected identities. Crash before rename leaves a resident object; recovery may cancel the intent. |
| Quarantine | Revalidate, rename the one object to its exclusive quarantine path, fsync both directories, verify the same object/hash, then commit `quarantined` residency. Crash after rename but before DB commit is recognized by journal + verified destination. Missing at both paths is an integrity incident, never inferred success. |
| Hold | Default/minimum **14 days** from durable quarantine completion. Quarantine frees no volume bytes. Keep reference evidence, journal and objects; no automatic expiry deletion. Restart may retain historical objects in quarantine with unlink authority suspended during reconciliation; restore objects before a new consumer needs them, and restore any object that fails final eligibility. |
| Restore | Commit `restorePrepared`; verify/hash the quarantine object; rename back without overwrite and fsync both directories; commit `resident` with a new residency generation. If CAS already contains the same digest, verify it and mark resident while retaining the extra quarantine copy for explicit reconciliation. Conflicting bytes block without overwrite/unlink. Restore needs no K9/token and works after lease expiry. |
| Finalize | Collector stopped + lock again; hold elapsed; rebuild the full graph and protected hashes, renew central/replica freshness, validate content proof/escrow, rehash quarantine and enforce exact run/budgets. Commit `unlinkPrepared`; recheck identity/reference fences; unlink only this quarantined regular file; fsync its directory; commit `evicted`. Crash after unlink is reconciled only from durable unlink intent with valid recorded pre-unlink evidence; otherwise missing means `recoveryRequired`. Never resume interrupted unlink automatically. |

If any eligibility/reference/native-identity check changes during a batch, stop further mutation and restore affected quarantined objects before allowing collection. Abort does not pretend to roll back already finalized objects. No deletion of manifests, directories, capture rows, publications, receipts, escrow, native files or central data is part of this protocol.

### 6. Collector reads, restart and restoration

The new collector must understand residency **before** the first quarantine. A spool GC recovery layer runs after owner acquisition and before reservation recovery, privacy assessment, upload claims, comparisons or event loops. It reconciles prepared transitions by inspecting both fenced paths and bytes; no automatic unlink occurs. Recoverable ambiguous renames restore toward the CAS; corrupt/missing kept content blocks affected processing with a dedicated `spoolIntegrityBlocked` diagnostic. During hold, verified quarantine is still local recoverable storage, not an eviction. A routine restart's full-walk request temporarily pins affected objects against finalize; it does not restore the entire quarantine solely because the walk is unfinished. Any actual reader first restores its objects, while finalize remains blocked until reconciliation converges and fresh eligibility is proven.

| Read/admission case | Required behavior |
|---|---|
| Kept capture needs a quarantined object | Restore/verify it under the held owner before returning bytes or claiming publication. Pin the object and invalidate its old batch intent. No network/token is needed. |
| Kept object missing or corrupt at both paths | Fail the GC/startup/admission integrity gate; preserve publication and dirty state, surface the capture/digest without transcript data. **A kept capture must never become `localContentUnavailable` because of K5.** Do not disguise an external integrity loss as a successful eviction or ordinary network retry. |
| Previously evicted historical capture is requested again | Require explicit verified restore into the spool before a new upload/privacy/read claim; report `spoolRestoreRequired`, without resetting ACKs or pretending to recapture historical bytes from today's native file. Operator replica GET restore needs separately authorized bearer-token use; escrow restore needs its own approval. |
| A new capture reuses an evicted/quarantined digest | Materialize and verify bytes from the capturer's staged content (or restore quarantine), record `resident`/increment residency generation, and cancel stale unlink authority **before** committing the new capture/publication reference. Keep the existing capture identity and publication dedup rules. |
| Cursor legacy comparison, privacy assessment or direct CAS read | Route through the same resolver/pin boundary. Audit all CollectorCore readers, not only `transmit`; a generic catch converting recovery errors to `invalidCapture` would violate this design. |

After a quarantine batch, hash verification proves all kept bytes still available. The restart gate re-evaluates references before enabling consumers, including publications requeued or newly withheld since quarantine. A protection change pins any quarantined bytes immediately and invalidates unlink authority; materialization precedes the affected consumer's admission. An evicted object that becomes required cannot be silently promoted into a kept, claimable capture until restored. Guard transitions that change protection as well as reads; do not merely suppress an error label. Finalize builds a new approval-bound plan from the intersection of the original quarantined batch and current eligibility; it cannot add new objects, reuse stale reference hashes or bypass new pins. Objects no longer eligible are restored, and any enlarged target needs a new quarantine run and hold.

K6 timestamps, capture IDs and dirty revisions are untouched. A cooling locator keeps all its chunks, including older captures under the conservative dirty-locator rule. Restart still forces root walks and replays same-epoch removals. K5 acts only in the spool, never resets FSEvents checkpoints, never marks missing native files acknowledged, and never claims to fix K1. Epoch reconcile runs separately under the same lock; changed epochs/root revisions invalidate GC plans and require a new preview. Never restore an old `inventory.sqlite` after collection resumes: that can reuse published sequence numbers. Object-level restore preserves machine, source-instance, epoch, sequence and publication identities.

An old collector binary does **not** understand the new journal merely because metadata exists. Rollback to it is allowed only after all quarantined objects are restored, every evicted object needed by its readers is restored and verified, and all incomplete intents are resolved. Otherwise retain the GC-aware binary with GC disabled. Do not swap an old DB snapshot to bypass this restriction.

### 7. Budgets, output and observation

Proposed M2 pilot caps: **256 MiB unique raw object bytes and 128 objects per run**, whichever binds first, and a 14-day hold. These are design defaults requiring approval with the concrete pilot plan, not authorization now. Both quarantine and finalize enforce finite nonnegative byte/count limits; zero selects no objects, overflow/negative/unlimited values reject. One digest is charged once even if referenced by many captures. Reserve before mutation and account durably across crashes; a new process cannot reset a run's budget. New runs cannot adopt old quarantine automatically.

Report separately: referenced logical bytes, unique present candidate bytes, kept bytes, unknown/orphan bytes, existing quarantine bytes, blocked bytes by reason, physical allocated blocks, and observed volume free space. Never sum generations to promise freed storage. APFS sharing/snapshots can make allocated totals and `df` gains differ; quarantine alone should not be presented as reclaimed space. Finalization records actual unlinked unique bytes and before/after directory allocation/free space without promising equivalence.

Read/verification work also has explicit memory, time and byte ceilings. Exceeding a ceiling produces an incomplete preview or blocked apply, never a sampled safety proof. Run the future M2 pilot alone, with low scheduling priority and observed memory pressure; no production scan or estimate runs in Phase A.

### 8. Implementation boundaries for the next approved phase

- CollectorCore: narrow manifest graph/eligibility model, strict read-only inspector, inventory journal/residency store and fenced executor/resolver. Reuse capture validation and directory identity patterns; avoid a second implementation of manifest parsing.
- Collector CLI: exclusive preview/apply/restore/finalize dispatch before normal credential loading. No service or Web mutation endpoint, IPC DTO, app UI, new daemon or Node product entrypoint.
- Catalog/CAS: bounded read APIs and narrow fenced quarantine/restore primitive if needed. No public unguarded collector delete API; final unlink confined to one reviewed executor site with a durable authorized intent.
- K9/central verifier: external evidence producer using strict read-only inputs; no index libraries in CollectorCore. Its authorization and operational validation are prerequisites, not implemented in Phase A.
- No TypeScript parser mirror or adapter fixture changes are expected because capture bytes/format do not change. Swift persistence/CLI fixtures and the TypeScript safety-gate regression harness do need coverage in the implementation phase.

## Invariants affected

- **Collector Spool Reclamation Authority (Draft)**: new ledger entry, “ACK alone is never reclamation authority; keep-set fails closed.” All enforcement below is planned.
- **Collector Publication ACK Durability / Durable Collector Intake Is Not Index Readiness**: ACKs remain immutable storage records; a separate conjunction grants local reclamation authority.
- **Collector Capture Core Excludes Product Index Dependencies / Single-Writer Discipline**: read-only central export outside CollectorCore; inventory-owned journal under the existing lock.
- **Local Privacy Proof Binds Captured Bytes and Current Format**: no withholding bypass, no secret loading for preview, and restored captured bytes are revalidated before use.
- **Native Epoch Reconciliation Is An Explicit Operator Action / Collector Root Revision Bump Keeps The Source Instance / Collector Event Loss Is A Root-Local Gap**: no checkpoint, stream, authority or epoch rewrites by GC.
- **Collector Re-Capture Of Large Locators Is Rate-Limited / Collector Vanished Uncaptured Locators Leave The Dirty Set**: preserve cooldown and dirty state; no native retirement or retry repair.
- **Cross-Machine Exact Duplicates Are Quarantined At Commit**: central retains its publication/CAS/generation behavior; K5 does not prune central and must re-prove the retained duplicate target.
- **Tests Avoid Production Engram Data**: all future regressions use isolated synthetic roots/databases and fake replicas; never copy live secret-bearing transcripts into fixtures.

## Alternatives considered

- Legacy `ArchiveCASEvictor` or an age/ACK SQL script: its bound reference index is not the collector authority and recreates the empty-set incident.
- Online GC under a SQLite transaction alone: capture catalog, inventory and filesystem cannot form one transaction; concurrent publication/recapture can create new references.
- Delete latest/live generations and rely on recapture: it refills storage, cannot restore vanished historical bytes, and breaks privacy/publication/dedup readers.
- Permanently retain all spool bytes: safe default until the gates exist, but leaves unbounded historical storage after K6.
- Direct unlink with replica ACKs and a backup: forfeits the reversible hold and current object-level readback proof. A historical backup may omit withheld or later data.
- Reuse legacy residency/receipt tables: would conflate bound-session authority with unbound collector captures. Collector-owned state keeps their contracts distinct.
- Automatically fetch missing objects with normal collector credentials: would turn preview/recovery into unapproved network/secret use and conceal integrity failures. Local quarantine restore is automatic only as a safe GC-aware recovery action; remote restore is explicit.

## Test plan

**Phase A RED list; B1 implements the preview subset only.** Executor/recovery cases below remain proposed; actual B1 evidence is recorded in `/tmp/engram-k5-phaseB1.md`. Start with the `_repro` cases failing against the pre-K5 behavior (missing proposed APIs may be an initial compilation failure; record behavioral RED once the minimal interfaces exist). A test name here is not a result.

| Planned test name | What it proves |
|---|---|
| `test1109EmptyLegacyKeepSetCannotAuthorizeSpoolDeletion_repro` | Nonempty unbound captures + empty legacy tables protect withheld/latest objects; the legacy empty set is never used. |
| `testEmptyCaptureGraphOrProtectedSetFailsClosed_repro` | Empty source/graph/keep-set and physically nonempty spool mutate nothing; no force path. |
| `testMalformedUnboundManifestAbortsWholePlan_repro` | Invalid digest/schema/length/ordinal/layout or one undecodable row aborts, without partial selection. |
| `testUnpublishedAndOldRevisionCapturesRemainInReferenceGraph_repro` | Catalog-only, ignored, reserved and fenced old-revision captures are protected. |
| `testSharedChunkWithOneKeptCaptureCannotBeEvicted_repro` | One ineligible reference pins a digest despite many ACKed superseded references. |
| `testWithheldPendingInflightAndUnavailableAlwaysPinObjects_repro` | Each publication/error/privacy state blocks independently; a historical ACK does not bypass current withholding. |
| `testLatestMissingOrLiveLocatorIsAlwaysKept_repro` | All latest captures remain resident; native absence does not authorize K1/K4 behavior. |
| `testDirtyLocatorIncludingK6CooldownBlocksAllItsCaptures_repro` | Dirty revisions, reservation, retry and deferred large-locator work stay intact. |
| `testAckWithoutCentralTerminalAndReplicaProofCannotApply_repro` | ACK-only, ordinary parsed/skip, wrong parser/identity and incomplete central evidence refuse. |
| `testDuplicateWithChangedOrUnprovableTargetRemainsKept_repro` | Historical duplicate quarantine without a currently verified matching retained generation is insufficient. |
| `testProofBindsBothPhysicalReplicaInstancesAndAllBytes` | Endpoint/journal/physical-host changes, partial readback, bad reassembly, expired lease and missing freshness receipt block. |
| `testMissingEscrowCoverageOrKeyRecoveryEvidenceBlocksApply` | Existing escrow path/old counts alone are insufficient; protected content is never made evictable by escrow. |
| `testPreviewNeverOpensWriterLocksLoadsTokensOrCallsNetwork` | Absent credentials, unwritable storage and live collector still permit bounded read-only reporting; no migration/sidecar creation fallback. |
| `testLockContentionRefusesBeforeAnyMutation_repro` | Running collector, second GC and epoch reconcile contend on the same lock; no stop/restart is attempted. |
| `testLateWriterInvalidatesPlanBeforeRenameAndUnlink_repro` | New reference, changed native generation/config or object/path replacement aborts/restores, preserving dirty state. |
| `testCrashBetweenQuarantineAndUnlinkPreservesRecoverableState_repro` | Fault injection before/after each DB commit, rename, directory fsync and unlink recovers idempotently; restart never auto-unlinks. |
| `testRestoreReturnsExactBytesWithoutRewindingInventory_repro` | Hash-identical local restore after lease expiry preserves machine/epoch/sequence/ACKs; conflict never overwrites. |
| `testKeptCaptureRestoresQuarantineBeforeClaim_repro` | Requeued/newly withheld references and all reader paths restore/pin before access; no `localContentUnavailable`. |
| `testMissingKeptObjectBlocksAdmissionWithoutRelabeling_repro` | Actual loss is exposed as integrity failure, never hidden by counter suppression or publication acknowledgement. |
| `testNewCaptureReusingEvictedDigestCancelsOldUnlinkIntent_repro` | New resident bytes/reference increment residency generation and survive a stale finalizer. |
| `testReplicaRestoreReassemblesSingleFileFileSetAndSQLitePair` | Each fake replica alone can restore pilot shapes/hash identity; bad length/hash/missing objects fail closed. |
| `testByteAndObjectBudgetsRemainExactAcrossCrash_repro` | Shared digests count once; both caps, zero, overflow and persisted reservations prevent overshoot/retry reset. |
| `testQuarantineRequiresSameVolumePrivateRegularFiles` | Cross-volume rename, symlink/path traversal, unexpected hard links and inode swaps fail without fallback. |
| `testHoldAndProofAreRevalidatedAtFinalize` | Too-young hold, clock skew, expired proof, changed central evidence or new reference blocks irreversible unlink. |
| `testGCJournalMigrationIsIdempotentAndUnknownVersionBlocks` | Fresh/existing inventory migration, repeated open and interrupted schema work preserve all existing state. |
| `testRestartReplayEpochFenceAndCooldownSurviveGC_repro` | Forced walks/removal replay still run; ordinary restart holds quarantine safely without a whole-spool restore, consumers restore before admission, epoch reconcile is separate, and K6 deadline/source identity are unchanged. |
| `testSafetyGateRejectsCollectorAndIngestDeletionBypasses_repro` | Newly covered directories cannot hide direct or wrapper-mediated CAS deletion or blanket table purges. |
| `testSafetyGateChecksStorageOnlyManualV2DeleteGuard_repro` | Manual `if`/`switch` dispatch changed to allow v2 deletion or bypass auth fails; exact legacy v1 route remains separately constrained. |

Suggested homes: new `CollectorSpoolGC*Tests.swift` in `macos/EngramCollectorCoreTests/`, reader/runtime/CLI scenarios beside `CollectorPublicationWorkerTests.swift`, `CollectorRuntimeTests.swift`, `CollectorCLIIntegrationTests.swift`, and gate cases in `tests/scripts/archive-v2-safety-gate.test.ts`. Test crash boundaries with subprocess exit/fault injection in temporary spools and use deterministic clocks; include a real Release CLI restore/hold-boundary smoke with isolated fixtures before pilot.

The safety-script extension must recursively cover `EngramCollectorCore`, `EngramCollector`, `EngramCoreWrite/CaptureIngest`, and `EngramService/Core/ServiceCapture*`, retaining existing scopes. Review existing temporary-file cleanup individually rather than adding a directory-wide allowlist. Cover calls to destructive CAS wrappers as well as primitives, and `DELETE`/`DROP` of protected capture/publication tables. Allow only the exact journal-gated quarantine unlink site plus existing reviewed temporary cleanup; mutations in neighboring functions must fail. Add explicit `StorageOnlyMain.swift` manual v2 auth-then-405 checks and mutation fixtures without pretending the legacy `/v1/bundles` DELETE is forbidden today. Run existing archive-gate regression tests as well as new negative cases.

Phase A validation is document structure, source-reference/requirement review, `git diff --check`, and changed-path scope only. No Swift/TypeScript tests, builds, live estimates, replica GETs, locks, database writes or production actions are needed to draft this gate. Implementation acceptance later needs the relevant CollectorCore/Service/CLI and safety-gate suites; a green document review is not runtime evidence.

### B1 preview contract

`EngramCollector --spool-gc (--spool-root ABS | --settings ABS) [--central-evidence ABS] [--max-preview-bytes N] [--max-preview-objects N] [--dry-run]` emits one JSON document on stdout. Settings mode securely reads only role/enabled/shadowRoot. Credentials, collection, initialization, reconciliation and apply/restore/finalize combinations are rejected before runtime construction. It uses the existing strict SQLite identity reader's opener (`mode=ro`, `readonly_shm=1`), including sidecar preflight and writable-SHM rejection; no migration, permission repair or owner lock.

The separate `scripts/collector-spool-gc-central-export.py` reads the central DB at `~/.engram-shadow-core-20260911/hq/state/service-index/database/index.sqlite` by default, or an explicit `--database ABS`, using a separate `/usr/bin/sqlite3 -readonly` process. It exports metadata/retained-generation existence for `swift-capture-v1`, without raw messages. It writes only stdout. Settings and caller-saved JSON must be private regular files with mode 0600 (no permission repair); preview accepts schema version 1, a timestamp no older than 24 hours/no more than five minutes ahead, and unique publication digests. These bounds are preview input validation, not a K9 proof lease.

Reports always have `previewOnly=true`, `provisional=true`, `actionableBytes=0`, and blockers `proof_missing`/`escrow`; absent central evidence additionally reports `central_evidence_missing`. `potentialBytesBeforeProofAndEscrow` is conditional on all unverified gates, including current privacy/native state. `firstBlockingGate` uniquely assigns each present referenced object to the earliest gate; a candidate sharing a chunk with a kept capture instead uses `shared_pinned`, with the underlying cause in `sharedPinCauses`. Capture counts use the same gate order. Escrow has zero first-blocking bytes while the earlier proof gate is unsatisfied; it is still an explicit blocker.

Unique present bytes are logical regular-file lengths checked against manifest chunk sizes, not allocated/free disk space or content-hash verification. Budgeted potential is a deterministic digest-ordered subset, counted once per shared digest; B1 does not claim oldest-first executor selection. B1 review correction: absent objects whose every reference is dual-ACKed are reported without savings; protected absent objects appear in `missingProtectedByACK` (objects/bytes for `dual_acked`, with `not_dual_acked` necessarily zero on success). Any absent object with a non-dual-ACKed reference, empty graph/keep-set, failed set-inclusion floor, incomplete references, malformed input or snapshot drift still refuses the estimate. This preview exception does not relax apply protection. POSIX realpath validation accepts both canonical `/private/...` and standard macOS alias spellings while rejecting arbitrary symlink inputs. Supported schema versions are inventory 2/publication 11/catalog 5; limits are 250,000 rows per table, 256 MiB metadata/fingerprint payload and two million chunk references. Both stores are reread and fingerprints must match; a busy collector can yield `inputChanged` and no JSON, without authorizing a stop or writer open. Manifest-file fixity, object hashes, orphan enumeration, proof, escrow, physical allocation and production compatibility remain unverified.

## Rollout

1. **Phase A accepted as Draft:** t11's `/tmp/engram-k5-gate.md` accepts the direction and splits implementation into B1/B2. The 256 MiB/128-object budgets, 14-day hold, 30-day lease and five-minute freshness remain proposals only.
2. **B1 (authorized):** implement and synthetically test the complete manifest graph, fail-closed keep-set/floor, conservative eligibility, unique-byte gate accounting, read-only CLI and separate central exporter. No journal, residency, quarantine, restore, finalizer, executor allowlist or production run. Stop after the B1 report for t11 review.
3. **B1 measurement gate (t11):** t11 runs token-free previews against real spools using a matching executable plus its frameworks and central export, then compares conditional bytes with t82's post-K6 growth. A zero estimate is acceptable. Decide whether B2 is worthwhile and for which host; do not weaken protection rules to create savings. Snapshot drift or unsupported schemas may block a live estimate without authorizing a service stop.
4. **B2 (not authorized):** only after the measurement decision, establish RED/GREEN for recovery/execution and land the expanded safety gate, GC-aware readers/startup, migration and isolated restore/crash tests together. Preserve compatible deployment lineage; this main-derived preview build is not a production collector replacement. New K9 token authorization, current escrow/P-KEY evidence, proven replica restore and a bounded batch review are mandatory before a pilot. Missing gates mean **blocked apply**, even if preview offers attractive byte counts.
5. **M2 first**, one small batch within the proposed caps and off-hours, with memory-pressure observation. Install the validated GC-aware collector through a separately approved rollout, verify baseline pending/withheld/unavailable counts and hash all protected bytes, stop collector, take lock, quarantine, verify/restore a selected subset, and restart only after recovery admission succeeds. Observe resumed upload, dirty/backlog behavior, epoch/walk health and protected hashes; record the operation's exact binary and plan/evidence hashes.
6. Hold at least 14 days and observe at least seven days without a K5-induced `localContentUnavailable`, restore failure or protected hash loss. No volume-space reduction is expected from quarantine. Before separate finalization approval, repeat central/replica/escrow proof, restore drill, locked reference graph and hashes. Stop on any unexplained object loss, new keep-reference, state drift or proof failure.
7. Expand to other collectors only after M2 acceptance with fresh per-host proofs/budgets. Frozen-store moves, K7/K8 and native retirement remain later independent tasks. No scheduling follows automatically.

Rollback during hold restores individual objects and cancels uncommitted intents while keeping current inventory/stream history. After unlink, recovery needs a verified replica/escrow fetch; it is not a local rename rollback. Keep receipts/journal and the GC-aware binary until that recovery is proven. No DB snapshot rewind or identity reinitialization is a rollback mechanism.

## Risks and open questions

- **Accepted conservative under-reclamation:** parsed/skip, unprovable duplicates, dirty locators, all latest captures and orphan objects stay local. The first preview may yield zero actionable bytes. Do not relax these rules just to meet an old estimate.
- **Evidence producer is a dependency:** K9, trusted current-instance proof and exact duplicate replay evidence remain unimplemented. B1 supplies only a central metadata exporter for conditional previews. Until supplied and validated, apply is blocked. Token authorization is explicitly outstanding; no credential was read in Phase A or B1.
- **Lease risk:** a proof is point-in-time, not a promise that both replicas will remain healthy. Thirty-day content expiry plus fresh identity checks is a proposed policy; independent host/volume evidence, P-KEY and restore verification reduce but do not remove correlated loss risk. Owner design acceptance must confirm lease age, pilot caps and hold policy.
- **Escrow drift/privacy:** the existing 11-11 escrow is a historical trusted-Mac snapshot. Its present integrity and coverage of new protected content remain UNVERIFIED; do not infer encryption, off-host independence or authorization for a new destination.
- **Central drift:** proof covers exact publications and retained generations at its timestamp. K8/pruning must not run concurrently with this pilot; future integration needs durable generation pins. No claim that source-only evidence proves the current central binary or current host state.
- **Hostile/noncooperating writers:** flock cannot stop arbitrary privileged/same-user byte mutation. Descriptor fences, hashes and drift checks detect ordinary races; the operational window must exclude unrelated spool writers. On ambiguity, retain/restore and stop.
- **Performance and crash durability:** complete manifest parsing/protected hashing may be expensive on M2, and APFS/disk-full/fsync behavior needs isolated testing. A timeout must fail closed. Physical reclaimed bytes and post-K6 growth remain unmeasured by this task.
- **Rollback compatibility:** legacy collectors ignore the new journal. Downgrade requires verified restoration or retaining the GC-aware build; this is an operational deployment gate, not a protection magically enforced by old code.
