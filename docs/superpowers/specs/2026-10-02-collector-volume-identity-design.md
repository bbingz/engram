# Design Doc: Collector root identity survives volume device renumbering

- **Status**: Draft
- **Owner**: collector maintainers
- **Date**: 2026-10-02
- **Related**: daily-collector outage audit (2026-10-02, operator scratch notes,
  not in repo); `docs/invariants.md` (no existing collector root-binding entry).

All `path:line` anchors are at commit `00bb5809` unless marked otherwise.

## Problem

The headless collector on a daily-use collector host captured nothing after
2026-09-22. A macOS update reboot renumbered the Data volume `st_dev` from
16777229 to 16777232. The number 16777229 now belongs to a mounted Recovery
volume. Every source root kept the same inode and birth time.

The collector stores `st_dev` in each root binding
(`macos/EngramCollectorCore/CollectorPOSIXRootEnumerator.swift:119-125`). It
then requires exact equality (`:239-241`), so all 16 roots threw
`rootIdentityChanged`. The runtime classifies that error as an unavailable source
(`macos/EngramCollectorCore/CollectorRuntime.swift:372-379`) and suspends the
roots every turn (`:382-395`, `:446-448`). It never rebinds
(`CollectorInventoryOwner.swift:180-183`), never exits and writes no log line.
To launchd the process looks healthy.

`st_dev` is assigned at mount time. It is not stable across reboots, so any
collector host can hit this.

## Goals / Non-goals

- Goals:
  - A root whose only changed identity field is the device number stays bound
    and keeps capturing. A host that already holds old-device bindings recovers
    on the first run of the fixed build, with no manual DB edit and no new
    source instance, epoch or root revision.
  - A device-only renumbering does not re-capture or re-publish unchanged files.
  - A real root replacement is still rejected.
  - A root suspended because its identity changed is no longer silent.
- Non-goals:
  - No change to the manifest wire format, schema-1 fields or capture IDs.
  - No change to the receiver or to HQ capture ingest.
  - The App/local service archive-v2 path (see a.10) is out of scope.
  - The FSEvents epoch-change path (see Risks) is out of scope.

## Current state (a + b)

The table lists where `st_dev`/`device` participates, and what happens today
when only the device number changes (inode, `st_gen` and birth time unchanged).

| # | Where | Role | Today on device-only change |
|---|---|---|---|
| 1 | `CollectorPOSIXRootEnumerator.swift:5-11,119-125`; stored in `collector_root_bindings.device` (`CollectorInventoryStore.swift:2764-2775`, written `:121-143`, read `:1983-2021`) | Root binding identity | `openBoundDirectory` throws `rootIdentityChanged` (`:239-241`). This is the outage. |
| 2 | `CollectorInventoryOwner.swift:169-200` | Enroll/activate | Reuses the stored binding and validates it (`:175-178`). This throws, and the root is never re-observed. `enrollRoot` refuses any different identity (`CollectorInventoryStore.swift:128-131`). |
| 3 | `CollectorRuntime.swift:372-379,397-451`; `CollectorInventoryOwner.swift:938-959`; `CollectorPublicationWorker.swift:266-283,474-477` | Error classification | The root is suspended or deferred as "unavailable". It is retried every turn, nothing is logged and the process never exits. |
| 4 | `CollectorPOSIXRootEnumerator.swift:577-598` | Per-directory identity during one cursor | Compares two stats taken in one process within one enumeration. A reboot cannot fall between them. Not affected. |
| 5 | `CollectorNativeEventStream.swift:320-326,515-535` | FSEvents stream | Requires `observation.volumeDevice == binding.expectedIdentity.device`. The epoch is the FSEvents DB UUID (`:104-117`), not `st_dev`. Unreachable today because #2 fails first. After a rebind it holds with the new device. |
| 6 | `CollectorPOSIXRootEnumerator.swift:467-482` | File generation (`stat-v1:` JSON incl. `device`) in `collector_locators.observed_generation` | The bootstrap compares strings (`CollectorInventoryStore.swift:1270-1305`). Every file differs, so every locator is dirtied. OpenCode's `opencode-pair-v1:` fingerprint (`:1275-1289`, `:2085-2096`) behaves the same. |
| 7 | `CollectorInventoryStore.swift:1013-1056` | Gemini/Kimi registry generation | `storedGeneration != generation` is true, so every Gemini/Kimi locator is dirtied. |
| 8 | `CollectorCursorSource.swift:248-280`, `CollectorVSCodeSource.swift:97-132` | Captured-dependency hints | Compare live stats with manifest generations. Every captured Cursor-modern/VSCode session is dirtied. |
| 9 | `CollectorCursorLegacyOwnership.swift:760-790`, `CollectorPublicationWorker.swift:700-703` | Cursor legacy observer fingerprints | `state.vscdb` is dirtied once. The walk deduplicates by content (`CollectorPublicationWorker.swift:1321-1327,1354-1400`), so this costs one re-read and no new publications. |
| 10 | `EngramCaptureShared/ExactSourceCapturer.swift:338-344,1326-1377` | Capture ID = hash(machine, source, locator, **generation**, whole SHA) | A dirtied unchanged file gets a new capture ID. It then produces a new manifest (`ArchiveModels.swift:861-895` generation keeps `device`), a new `archive_captures` row (`ArchiveCatalog.swift:648-670`) and a new publication. |
| 11 | `CollectorInventoryStore.swift:625-679,2167-2175` | Reservations, streams, sequence/epoch | Streams key on `(root_id, root_revision, effective_source)`, not device, so they are unchanged. A pre-renumbering reservation fails `currentMatchesReservation` (`CollectorPublicationWorker.swift:2172-2228`) and is abandoned and re-claimed. That is at most one per stream. |
| 12 | Receiver: `EngramRemoteServerApp.swift:442-449` | Startup filesystem-overlap check only | Not affected. Dedupe is by publication digest and CAS SHA (`CollectorPublicationWorker.swift:1964-1983`). |
| 13 | HQ: `CaptureIngestCommitter.swift:477-516` | Orders by authority generation + stream sequence; identity is (machine, source instance, source, native ID) | Never reads `generation.device`. A byte-identical new generation is a higher sequence, so it commits as a new head of the **same** session: a new ledger row, a new `capture_ingest_generations` row, a snapshot rewrite and an FTS job. It produces no duplicate session. `obsolete_generation` (`:510`) applies only to a lower sequence, so it does not fire. |
| 14 | Local service: `ArchiveCaptureCoordinator.swift:504-542,1277-1350` with `ExactSourceCapturer` | Sweeps every locator; dedupe by capture ID | Every locator gets a new capture ID once: re-read, new manifest and catalog rows, with CAS chunks deduplicated. `SwiftIndexer.swift:440-456`/`IndexingWriteSink.swift:220-225` force one full re-parse instead of a tail parse. Reclamation refuses while `st_dev != generation.device` (`ArchiveReclamationCoordinator.swift:536`, `ArchiveSourceReclaimer.swift:419,505`), which fails safe. This path has no root binding and no stall, so it is out of scope. |

## Proposed design (c)

### c.0 What the root-identity check protects

A different directory at the configured path must never join the original
source stream. Sequences in one `(source_instance_id, collector_epoch)` stream
must describe one physical lineage. The relevant tests are
`testRestartRootReplacementDoesNotRebindOrActivateNewInode`
(`CollectorInventoryOwnerTests.swift:367`) and
`testRestartDeliversPendingArchivesWithMissingOrReplacedSourceWithoutRebinding`
(`CollectorRuntimeTests.swift:378`). The protected cases are a moved, re-created
or restored directory (new inode, or new birth time on the same volume) and an
ancestor symlink swap. The swap is caught by the per-component `O_NOFOLLOW` walk
(`CollectorPOSIXRootEnumerator.swift:68-105`), which this design does not touch.

### c.1 Identity rule (chosen): device-only change is a renumbering

A stored binding is **rebound in place** only when the live root differs from
the stored identity in `device` alone. `inode`, `st_gen`, `birthSeconds` and
`birthNanoseconds` must be equal, and the birth time must be non-zero (known).
Anything else still throws `rootIdentityChanged`.

- Where: `CollectorInventoryOwner.enrollAndActivateRoot`. When validating a
  stored binding throws `rootIdentityChanged`, the root is re-observed through
  the same safe walk (`observeRoot`, which re-validates the route). It is
  rebound only if the rule holds. The rebind is a guarded `UPDATE` of the
  `device` column. Its `WHERE` clause matches the full old identity. The root
  revision, the activation stamp semantics, the stream, the epoch and the
  sequence are untouched.
- A running runtime picks this up one turn later. The live check suspends the
  coordinator, and the next turn's enroll path rebinds. The in-memory
  `activeRoots` entry is refreshed when the stored identity changed. Today it is
  refreshed only on a configuration change (`CollectorInventoryOwner.swift:192`).
  Otherwise later operations would throw `rootNotActivated`.

### c.2 Rejected: volume UUID (`getattrlist ATTR_VOL_UUID`)

A volume UUID would need a new binding column and a migration. Existing
bindings have no UUID, so their first adoption would still rely on the c.1
rule. It adds protection only against a *different* volume that carries the
same inode and nanosecond birth time. In practice that means a block-level
clone or a mounted APFS snapshot of the same volume, and those often carry the
same UUID anyway. The FSEvents backend comment also avoids filesystem volume
UUIDs as identity (`CollectorNativeEventStream.swift:20-22`). The cost is a
schema change; the gain is marginal.

### c.3 Migration of existing bindings

No schema change is needed. On the first run of the fixed build, the enroll
path finds the old-device row and applies c.1, which updates `device` once. The
operation is idempotent: the next run matches the new device directly. No new
source instance, epoch, root revision or history upload results.

### c.4 File generations (chosen): device-insensitive change detection

Capture identity and the wire format keep `device` (#10, #13 unchanged). Only
the collector's **change-detection hints** ignore a device-only difference.
"Same" means equal inode, size, mtime ns, ctime ns and mode:

- #6 bootstrap: `stat-v1:` and `opencode-pair-v1:` observations are compared
  ignoring device. A device-only difference does not dirty the locator. The
  stored string is refreshed to the live one, so the state converges.
- #7 registry: compared ignoring device.
- #8 Cursor-modern/VSCode dependency hints: the primary, members and workspace
  file are compared ignoring device.

Accepted residual work, all bounded and creating no duplicate sessions:

- The Cursor legacy walk re-reads once (#9) and publishes nothing for unchanged
  content.
- The VSCode external workspace-configuration recheck stays strict, because it
  shares code with the capture-time fence (`CollectorVSCodeSource.swift:264-291`).
  Sessions with an external `.code-workspace` are re-captured once.
- Pre-renumbering reservations re-capture at most one per stream (#11).
- Cursor-modern event fingerprints differ only for paths that receive real
  FSEvents.

A false "unchanged" would need a different file whose inode, size, mtime ns,
ctime ns and mode all match. ctime cannot be set from user space. Safety fences
that compare two stats taken at the same moment are not changed.

Without c.4, the cost on the affected host (about 40,451 captures) would be:

1. Re-read and SHA-256 every source byte.
2. Write one new manifest and catalog row per file (chunks are deduplicated).
3. Add one publication and two replica rows per file.
4. Per replica, send chunk HEADs plus a manifest HEAD+PUT and a publication PUT
   for each file.
5. On HQ, add about 40k ledger and `capture_ingest_generations` rows, each with
   normalized message JSON, plus about 40k snapshot rewrites and FTS jobs.

That load is not acceptable, so c.4 is required.

### e. Loud signal (chosen): stderr line on transition, no exit

The runtime records which roots were last suspended *because of*
`rootIdentityChanged`, after c.1 refused to rebind them. Whenever that set
changes it writes one line to stderr. launchd persists stderr through the
plist's `StandardErrorPath`, and stderr is the collector's only log channel
(`EngramCollector/main.swift`). The line is:

```
engram-collector: source roots suspended for identity change: <n>/<total>
```

When `n == total` it adds `; capture stopped`. The line contains root IDs only,
never paths.

A non-zero exit was rejected. Pending publications must still be delivered
while the source is missing or replaced (`CollectorRuntimeTests.swift:378-426`).
An exit 70 would stop those upload loops and turn silence into a 10 s launchd
restart loop (`ThrottleInterval 10`). That loop costs as much CPU as today, and
`main.swift:154-161` maps every failure to the same opaque `runtime failed`
line. Telemetry to HQ would need a receiver/HQ change, which is outside this
fix's gate.

## Invariants affected (f)

No current ledger entry covers root binding identity. Draft new entry (not
added to the ledger by this change):

> ## Collector Root Binding Survives Device Renumbering Only
>
> - **Statement** - A stored collector root binding is rebound in place only
>   when the live root differs from it in `st_dev` alone. Inode, `st_gen` and a
>   known birth time must all match. Any other identity change keeps the root
>   suspended, keeps its stream unchanged and never joins the original stream.
>   Collector change-detection hints treat a device-only file difference as
>   unchanged, while capture IDs and manifests keep the device. A root suspended
>   for an identity change is reported on stderr whenever the suspended set
>   changes. Publication delivery continues.
> - **Enforced by** - `macos/EngramCollectorCore/CollectorPOSIXRootEnumerator.swift`,
>   `macos/EngramCollectorCore/CollectorInventoryOwner.swift`,
>   `macos/EngramCollectorCore/CollectorInventoryStore.swift`,
>   `macos/EngramCollectorCore/CollectorRuntime.swift`.
> - **Verified by** - `macos/EngramCollectorCoreTests/CollectorInventoryOwnerTests.swift`
>   (testDeviceRenumberingKeepsRootBoundAndEnumerating_repro,
>   testDeviceRenumberingRuleStillRejectsDifferentInodeOrBirthTime,
>   testDeviceRenumberingDoesNotDirtyUnchangedFiles_repro),
>   `macos/EngramServiceCoreTests/CollectorRuntimeTests.swift`
>   (testDeviceRenumberingRebindsAndCapturesWithoutRepublishing_repro,
>   testRootIdentitySuspensionIsReportedOnceAndRuntimeKeepsRunning).
> - **Gate** - `none`.

## Alternatives considered

- **Ignore device in the root comparison without rebinding.** The FSEvents
  stream validation (#5) would then fail with `invalidRoot`, which is not an
  unavailable-source error, so the runtime would exit 70 in a loop.
- **Substitute the stored device into every observed generation.** That needs
  `ExactSourceCapturer`, which is shared with the App and service, and it changes
  capture-ID semantics. The blast radius is too wide.
- **Operator workaround: bump each root revision.** This creates new streams and
  source instances and re-captures the whole history. It also leaves the trap
  armed for the next renumbering.

## Test plan

The tests simulate a renumbering by rewriting the stored `device` (and the
stored `observed_generation` device) in the fixture inventory DB. The live
device stays real. This is exactly the state on the affected host (stored D,
live D′, same inode and birth time) and needs no mounts.

- `CollectorInventoryOwnerTests`:
  - `testDeviceRenumberingKeepsRootBoundAndEnumerating_repro`;
  - `testDeviceRenumberingRuleStillRejectsDifferentInodeOrBirthTime`;
  - `testDeviceRenumberingDoesNotDirtyUnchangedFiles_repro` (a changed file
    is still dirtied).
- `CollectorKimiPersistenceTests.testRegistryDeviceRenumberingDoesNotRedirtyLocators`.
- `CollectorVSCodeSourceTests.testCapturedDependencyProbeIgnoresDeviceRenumbering`,
  `CollectorInventoryStoreTests.testCursorModernDependencyProbeIgnoresDeviceRenumbering`.
- `CollectorRuntimeTests` (scheme EngramServiceCore):
  - `testDeviceRenumberingRebindsAndCapturesWithoutRepublishing_repro`;
  - `testRootIdentitySuspensionIsReportedOnceAndRuntimeKeepsRunning`.
- Not tested: a real mount renumbering, which needs a reboot; a renumbering
  while one owner run is live (the `activeRoots` refresh is covered by code path
  only); xnu `st_gen` behaviour.

## Rollout (d: affected-host recovery)

The fixed build changes no schema and no settings.

1. Package the build and switch the host's launchd job to it (owner action).
2. On start, `enrollAndActivateRoot` rebinds each of the 16 roots from 16777229
   to 16777232. There is one guarded `UPDATE` per root, the coordinators start,
   and the FSEvents epoch is read for the new device.
3. If the FSEvents DB UUID is unchanged, the stored checkpoints resume. Events
   since 2026-09-22 replay (FullHistory), and the about 490 changed files are
   dirtied.
4. Activation bumps `requested_revision`, which starts a full bootstrap. Unchanged
   files compare equal ignoring device and get no dirty bump; their stored
   strings are refreshed. Changed files are dirtied.
5. Only the dirtied files are captured. They get new capture IDs that carry the
   new device, then publications at the next sequence of each existing stream,
   then upload to both replicas. HQ commits them as new heads of the existing
   sessions.
6. Verify with `sqlite3 -readonly`: `collector_root_bindings.device = 16777232`,
   new `archive_captures` rows after the deploy, and that
   `collector_publications` grew by about the number of changed files (not by
   about 40k).

Revert: reinstall the previous package. The rebound root bindings hold the
live device, which the old build also accepts until the next renumbering.
Correction (2026-10-02, from the first deployment): this holds for root
bindings only. The old build compares stored locator observations exactly, so
reverting before every observation has been refreshed to the new device makes
it re-capture each unrefreshed locator. In that window stop the job instead
of reverting.

## Risks and open questions

- **FSEvents epoch (UNVERIFIED on the host).** If the OS update reset the
  volume's FSEvents DB UUID, the coordinator records a gap.
  `CollectorRuntime.swift:441-443` then throws `reconciliationRequired`, which
  exits 70. That path is separate and pre-existing and needs its own review if
  it occurs.
- **`st_gen`.** It is reported as 0 to non-root callers on macOS (INFERRED from
  the xnu `vn_stat` behaviour), so it adds no discrimination for the user-level
  collector.
- **Snapshot or clone residual.** A mounted APFS snapshot or block clone of the
  same volume, placed at or above a root path, could satisfy c.1. That requires
  a deliberate privileged mount. It is accepted, see c.2.
- **Local service (#14).** That path re-captures and re-parses every locator once
  after a renumbering. Follow-up candidate.
