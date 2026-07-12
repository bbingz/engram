# Archive V2 Automatic Reclamation Design

**Date:** 2026-07-12

**Status:** Approved in conversation; awaiting written-spec review

**Branch:** `bbingz/archive-v2-dual-replica`

## Goal

Bound local storage growth after Archive V2 has preserved an exact session
source generation on both remote replicas. Reclaim both the old live source
file and its local Archive V2 content while keeping local metadata, summaries,
searchability, manifests, receipts, and catalog history.

The default local hot window is 30 days, matching Claude Code's current default
local transcript cleanup period. Reclamation is opt-in and default-off.

## Non-goals

- No remote deletion, remote garbage collection, or mutable Archive V2 API.
- No deletion for adapters without an explicit replay-proven exact-source
  descriptor.
- No full-database restore drill or full remote scan.
- No capacity target, adaptive retention algorithm, or storage policy engine.
- No automated Time Machine or offline-backup inspection. The operator's local
  Time Machine remains an additional manual safeguard, not a product gate.
- No deletion of local session metadata, summaries, keyword-search data,
  manifests, receipts, or archive catalog history.

## Product behavior

The first release supports only replay-proven, single-regular-file Claude Code
and Codex sources already admitted by Archive V2. A session is eligible only
when all of the following are true:

1. Its last activity is at least the configured hot-window age; the default is
   30 days.
2. It is not live and not favorited.
3. The current source generation is bound to an accepted exact capture.
4. HQ and M1 each have a verified, replica-bound receipt for that manifest.
5. HQ and M1 each have a successful production recovery drill no older than
   30 days.
6. There is no newer capture for the locator and no active capture, replication,
   recovery, or reclamation operation for it. An already-open source descriptor
   is not a correctness blocker: same-directory quarantine preserves that
   descriptor, and the post-rename generation/hash check detects concurrent
   mutation before removal.
7. Immediately before source removal, the live file still matches the captured
   device, inode, size, modification time, and whole-source SHA-256.

Failure of any condition is a fail-closed skip. Capture, replication, indexing,
and ordinary reads continue even when reclamation is paused.

## Architecture

Add a low-priority `ArchiveReclamationCoordinator` after the existing Archive
V2 service cycle. It uses the existing archive catalog, receipt verification,
replica backends, exact-source generation model, and transcript resolver.

Add one durable `archive_reclamation_intents` table. An intent is keyed by the
capture/manifest identity and tracks the locator, expected generation, current
phase, quarantine path when present, attempts, released byte counts, bounded
error symbol, and timestamps. The phase progression is:

```text
eligible -> quarantine_planned -> source_quarantined -> source_deleted
         -> local_content_evicted
```

Terminal success is `local_content_evicted`. Retryable failures stay in their
current phase with bounded retry metadata. A safety mismatch moves the intent
to a non-destructive paused state until a newer capture or operator-visible
condition makes it eligible again.

Local object residency and references must be explicit. Add
`archive_local_objects`, keyed by object SHA-256, for byte count and local
residency (`resident` or `evicted`), plus `archive_manifest_objects`, keyed by
manifest SHA-256 and ordinal with an indexed object SHA-256, for the durable
manifest-to-object relation. Populate both transactionally when a binding is
accepted. The schema migration backfills them by decoding the canonical bound
manifests already stored in `archive_session_bindings`; any invalid manifest
fails the migration closed. These tables let the coordinator prove that every
manifest referencing a shared chunk is remote-safe without an unbounded
manifest scan. Integrity checks must distinguish deliberate eviction from
unexpected loss and must not infer intent solely from a missing CAS file.

The coordinator runs at most 10 source intents, hashes at most 256 MiB of source
bytes, and evicts at most 256 MiB of CAS content per cycle. A source larger than
256 MiB is paused as `source_too_large` in v1 rather than bypassing full-hash
verification. These are fixed implementation limits, not user-facing settings.

## Source-file removal

The coordinator must not directly unlink the live locator after a preflight
stat. It uses same-directory quarantine to close the validation/removal race:

1. Claim one intent durably.
2. Revalidate the complete eligibility gate.
3. Choose a unique hidden quarantine path in the same directory, persist that
   path and the `quarantine_planned` phase, and commit the catalog transaction
   before touching the filesystem.
4. Atomically rename the source to the persisted quarantine path, then commit
   `source_quarantined`.
5. Open the quarantined file without following symlinks and verify its device,
   inode, size, modification time, regular-file mode, and whole-source SHA-256.
6. If every value matches the accepted capture, remove the quarantined file and
   commit `source_deleted` with released bytes.
7. If validation fails, restore the original name only when the destination is
   absent. Never overwrite a newly created source. Leave a recoverable paused
   intent and surface the collision if automatic restoration is unsafe.

Startup recovery inspects both `quarantine_planned` and `source_quarantined`.
For a planned intent it handles both crash windows: original present/quarantine
absent means rename never happened and may be retried after the full gate;
original absent/quarantine present means rename happened and recovery advances
to validation. Any other path combination pauses without overwriting either
file. A quarantined intent validates and finishes deletion only under the same
gate, otherwise restores or pauses it. Quarantine files are never generic
temporary garbage.

## Local Archive V2 content eviction

CAS eviction runs in a later cycle than source removal. For each
`source_deleted` intent:

1. Revalidate both current receipts and both recovery-drill leases.
2. Validate the persisted receipts against the canonical manifest. Archive V2
   receipts are chunk-level durability proof: the existing server creates a
   receipt only after durably reopening every referenced object, validating
   every chunk length and SHA-256, and rebuilding the whole-source SHA-256.
   Manifest-only acceptance is not a valid receipt.
3. Determine which local chunks may be removed. A shared chunk is evictable
   only when every local manifest that references it is independently eligible
   for remote-only content residency.
4. Mark the affected objects as intentionally evicted and remove their local
   files using the catalog/CAS transaction pattern defined by the implementation
   plan.
5. Keep the local manifest bytes, receipt bytes, catalog rows, session metadata,
   summary, and search data.

The transcript resolver consults local residency before classifying a missing
object. An `evicted` object is a normal remote fallback condition. A `resident`
object that is missing or invalid records a bounded local-integrity fault and
degrades archive status, but the resolver still tries HQ and then M1 so a local
fault does not hide recoverable history. It must never silently change the
object's residency to `evicted`.

## Recovery-drill lease

Each replica needs one successful drill within the previous 30 days. The drill
is deliberately small:

- select one eligible archived session per replica using a durable round-robin
  cursor, so repeated drills do not permanently exercise the same manifest;
- restore and validate its canonical manifest, every referenced chunk, rebuilt
  byte count, and whole-source SHA-256;
- read at most 64 MiB and run for at most 60 seconds per replica;
- discard temporary restored bytes after verification;
- record replica ID, manifest identity, verified byte count, completion time,
  result, and bounded failure symbol.

HQ and M1 drills may run at different times. A timeout, missing key, network
failure, or byte mismatch expires only that replica's lease and pauses
reclamation. It does not block capture, replication, indexing, or reads.

## Configuration

Persist the user policy under:

```json
{
  "archiveReclamation": {
    "enabled": false,
    "hotWindowDays": 30
  }
}
```

Supported hot-window choices are 30, 60, 90, and 180 days. Invalid values fail
closed to disabled reclamation rather than silently selecting a shorter window.
Settings are written through service IPC and refresh the coordinator without an
app restart.

## Settings UI

Add a top-level **Storage** category to the existing Settings window. Do not
place destructive retention controls under Advanced.

The **Automatic Reclamation** group contains:

- an `Automatically reclaim old sessions` toggle, default off;
- a `Local hot window` picker with 30, 60, 90, and 180 days;
- concise text explaining that old source files and local archived content are
  reclaimed while metadata, summaries, and search remain local and full text is
  restored from HQ/M1.

The first enable attempt presents a confirmation dialog. Enabling is allowed
when both recovery-drill leases are currently valid. Receipts are per-manifest,
so they remain a candidate-level execution gate and appear in Preview blocker
counts; they are not a global enable gate when there are no candidates.

The **Status** group shows:

- `Disabled`, `Ready`, or `Paused`;
- the last cycle time;
- cumulative released bytes;
- current candidate count;
- one bounded pause reason;
- `Preview` and `Run Now` buttons.

`Preview` is read-only and returns candidate count, estimated source/CAS bytes,
and grouped blocker counts. `Run Now` executes one normal bounded cycle and
cannot bypass the backend gate. Internal batch and byte limits are not exposed.

## Service and operator surfaces

Add service IPC for:

- reading reclamation status and preview;
- updating the enabled flag and hot-window choice;
- executing one bounded cycle;
- executing one bounded recovery drill per requested replica by extending the
  existing remote recovery-probe implementation with deterministic selection
  and durable lease recording, rather than creating a second verification path.

Mutating commands require the existing service capability token. The command
line exposes equivalent operator surfaces:

```text
engram archive reclaim-preview
engram archive reclaim-run
engram archive recovery-drill --replica hq
engram archive recovery-drill --replica m1
```

No command accepts `force`, ignores generation drift, fabricates a lease, or
bypasses receipt verification.

## Failure handling and observability

Use bounded symbolic errors in durable state and status responses. Logs may add
detail but must not be required to determine why reclamation is paused.

Expected pause classes include disabled, insufficient age, live, favorite,
missing receipt, expired drill, active operation, generation changed,
quarantine collision, source too large, remote unavailable, remote mismatch,
local integrity fault, and local I/O failure. Repeated failures use the existing
bounded retry style and do not spin continuously.

Settings and status must never imply that a health endpoint or HEAD response is
durability proof. Only verified receipts and current drill leases satisfy the
gate.

## Testing strategy

Implementation follows test-first RED/GREEN cycles. At minimum, cover:

- 30-day boundary and each configurable window;
- live and favorite protection;
- missing/mismatched receipt and expired/missing drill produce zero deletion;
- generation or whole-file hash drift produces zero deletion;
- quarantine validation failure restores the source when safe;
- quarantine destination collision never overwrites a recreated source;
- restart recovery at every durable phase;
- source deletion and CAS eviction occur in separate cycles;
- object/reference migration backfills canonical manifests and fails closed on
  invalid bytes;
- shared chunks remain until every referencing capture is remote-safe;
- intentional eviction is distinct from corruption;
- remote-only resolution succeeds independently through HQ and M1;
- 10-source and 256 MiB cycle bounds;
- preview is read-only and run-now cannot bypass the gate;
- Settings load/save, first-enable confirmation, blocked enable, status, preview,
  and run-now behavior;
- accessibility identifiers and keyboard operation for new Settings controls;
- the Archive V2 static safety gate still rejects remote deletion and permits
  only the named, reviewed local reclamation primitives.

Focused Core, Service, app Settings, CLI, safety-gate, build, and existing
Archive V2 recovery suites form the completion verifier. Production enablement
additionally requires preview evidence, successful HQ/M1 bounded drills, one
real bounded cycle, local search verification, remote full-text restoration
from each replica, and measured disk reclamation.

## Rollout and rollback

1. Ship with reclamation disabled.
2. Run preview and inspect grouped blockers and estimated bytes.
3. Run the bounded HQ and M1 drills.
4. Enable reclamation in Settings after both replica drill checks are green.
5. Run or wait for one bounded cycle.
6. Verify source removal, local search, HQ restoration, M1 restoration, and
   actual disk reduction.

Turning the feature off stops new reclamation immediately but does not recreate
already removed local bytes. Previously reclaimed sessions remain readable via
Archive V2 remote fallback. Rollback must preserve the reclamation catalog and
quarantine records; it must not delete remote archive material or receipts.

## Done when / verifier

Repository implementation is done when all specified focused tests and safety
gates pass, the app builds, Settings exposes the approved controls, and the
static archive contract still contains no remote delete capability.

Production activation is separately done when both current recovery-drill
leases exist, preview is reviewed, one bounded real cycle completes, old session
metadata/search remain local, full text restores independently from HQ and M1,
and released disk bytes are measured. Deployment, activation, and production
deletion require explicit user authorization after repository implementation.
