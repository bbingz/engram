# ARCHIVE-DISCOVERY-001 design scope — 2026-08-12

- Base: `main@5114507f`
- Verdict: **CONFIRMED / DESIGN-READY / IMPLEMENTATION DEFERRED**
- Scope: exact-source Archive V2 discovery for Claude Code and Codex only.

## Confirmed current behavior

`batchSize` bounds capture after discovery; it does not bound discovery itself.

| Stage | Current evidence | Consequence |
|-------|------------------|-------------|
| Adapter contract | `SessionAdapter.listSessionLocators()` returns a complete `[String]` (`macos/Shared/EngramCore/Adapters/SessionAdapter.swift:323-326`). | The archive caller has no page, continuation, or stream to stop after a budget. |
| Claude Code discovery | All available profiles feed one `Set`, then the entire set is sorted (`macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:87-109`). | CPU and memory remain O(N) before capture starts. |
| Codex discovery | Recursive enumeration first materializes and sorts every matching file, and the adapter sorts the combined list again (`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:69-87,503-514`). | A small capture budget does not reduce filesystem traversal or list materialization. |
| Archive snapshot | `ArchiveCaptureCoordinator` awaits the full list, normalizes and sorts a second full snapshot, and hashes every key (`macos/EngramCoreWrite/ArchiveV2/ArchiveCaptureCoordinator.swift:430-500,1058-1076`). | The in-memory sweep cache avoids some repeated enumeration only while the actor survives. |
| Budget ordering | The locator and byte budget loop begins after every adapter snapshot is ready (`macos/EngramCoreWrite/ArchiveV2/ArchiveCaptureCoordinator.swift:504-535`). Service `batchSize` is passed into capture at `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift:1325-1334`. | The configured budget cannot cap initial or refreshed discovery latency. |
| Restart state | The durable checkpoint stores digest/path sweep anchors, while the complete locator snapshots live only in `locatorSweepCaches` (`macos/EngramCoreWrite/ArchiveV2/ArchiveCaptureCoordinator.swift:421-429,494-500,1000-1055`). | A process restart must reconstruct the O(N) list before the durable capture cursor can resume. |

Existing tests characterize fairness only after the complete list exists. For
example, `testCaptureBudgetIsGlobalFairAndResumesAfterCatalogRestart` exercises
a four-element in-memory adapter list, and
`testCaptureBudgetStopsAfterSourceByteLimitAndReusesFullSweepSnapshot` proves
that one process can reuse its full sweep cache
(`macos/EngramCoreTests/ArchiveV2/ArchiveCaptureCoordinatorTests.swift:616-694,898-931`).
Neither test establishes bounded filesystem discovery.

Focused baseline verification on this base ran:

```bash
cd macos
xcodebuild test -quiet -project Engram.xcodeproj -scheme EngramCoreTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:EngramCoreTests/ArchiveCaptureCoordinatorTests/testCaptureBudgetIsGlobalFairAndResumesAfterCatalogRestart \
  -only-testing:EngramCoreTests/ArchiveCaptureCoordinatorTests/testCaptureBudgetStopsAfterSourceByteLimitAndReusesFullSweepSnapshot \
  -only-testing:EngramCoreTests/ArchiveCaptureCoordinatorTests/testRecentCaptureRefreshReenumeratesLocatorSnapshot \
  -only-testing:EngramCoreTests/SessionSyncTests/testManifestCodecRoundTrip \
  -only-testing:EngramCoreTests/SessionSyncTests/testDecodeCatalogSkipsCorruptManifests
```

Result: 5 passed, 0 failed, 0 skipped. This is baseline evidence for the
current post-enumeration budget/cursor behavior and manifest codec tests, not
evidence that discovery is bounded.

## Why there is no safe small prefix fix

1. Passing `batchSize` into the current array API and returning only
   `prefix(batchSize)` makes the same lexicographically early locators win after
   every restart, so later locators can be permanently starved.
2. Persisting only a last-path cursor still requires rescanning from the root to
   find that path and can miss a newly-created locator that sorts before it.
3. Replacing the array with a process-local `AsyncStream` reduces peak memory
   but does not provide restart continuity, deletion reconciliation, or a safe
   response to dropped filesystem events.
4. Removing the full-set digest without another inventory/epoch authority
   breaks the current changed-set and wraparound guarantees
   (`ArchiveCaptureCoordinator.swift:1096-1155`).

The defect is therefore structural, not a one-function budget-ordering patch.

## Recommended implementation boundary

Add an archive-owned durable locator inventory for the two exact sources. All
mutations remain behind the service-owned, single-flight Archive V2 pipeline;
the App and MCP must not write archive or index state directly.

1. **Explicit bootstrap state.** First enablement records
   `bootstrap_required → bootstrapping → ready` and populates the inventory with
   one cancellable full crawl. This crawl remains explicitly O(N); the product
   must not label bootstrap itself bounded.
2. **Durable steady-state discovery.** Persist normalized locator identity,
   physical source, root/profile identity, observed generation, present/tombstone
   state, and the last acknowledged FSEvents ID in Archive V2 storage.
3. **Bounded capture admission.** Once bootstrap is ready, capture claims at
   most the configured locator budget directly from the inventory before any
   source-wide enumeration. Claimed work and its continuation survive service
   restart.
4. **Event-loss fail closed.** Root/profile changes, dropped FSEvents, or an
   invalid event cursor transition the source to `rescan_required`. New exact
   locators must not reach parsing without successful capture; UI/status must
   distinguish bootstrap/rescan work from ordinary bounded backlog.
5. **Compatibility boundary.** Do not widen `ExactArchiveSourceAdapter` to
   virtual, composite, database-backed, or adjacent-shard sources in this item.
   Remote erasure and GC remain out of scope.

## Proposed Done-when

- After an explicit successful bootstrap, a cycle with locator budget `B`
  performs no source-wide `listSessionLocators()` call and admits no more than
  `B` inventory rows.
- Restart resumes from the persisted inventory/claim cursor without rebuilding
  a complete `[String]` snapshot and without duplicate or starved locators.
- Create, modify, delete, profile-root change, event-stream restart, and dropped
  event paths have deterministic state transitions.
- Capture-before-parse remains fail closed for every exact locator, including
  while bootstrap or rescan is incomplete.
- Named executable coverage includes:
  `testArchiveDiscoveryBudgetDoesNotEnumerateWholeSource_repro`,
  `testArchiveDiscoveryResumesFromDurableInventoryAfterRestart_repro`,
  `testArchiveDiscoveryFSEventBeforeCursorIsNotStarved_repro`, and
  `testArchiveDiscoveryDroppedEventsRequireRescanBeforeIndexing_repro`.
- Archive status reports whether discovery is `bootstrapping`, `ready`, or
  `rescan_required`; operational docs continue to disclose the O(N) bootstrap.

## Next smaller implementation slice

Promote audit residual L36 as `REMOTE-MANIFEST-SCHEMA-001`. Current
`ManifestCodec.decode` accepts any decoded `SyncManifest.schemaVersion`, and
`decodeCatalog` does not validate the aggregate catalog version
(`macos/EngramCoreWrite/RemoteSync/ManifestCodec.swift:90-102`). The sibling
bundle decoder already rejects unsupported versions with
`RemoteSyncError.schemaVersionUnsupported`
(`macos/EngramCoreWrite/RemoteSync/BundleCodec.swift:100-106`). This has a small,
pure unit-regression path in
`macos/EngramCoreTests/RemoteSync/SessionSyncTests.swift:375-396` and does not
require an Archive V2 redesign. A no-repository-write Swift smoke against the
focused-test build confirmed both paths: a direct manifest with
`schemaVersion: 2` printed `decoded_schema=2`, and a catalog envelope with
`schemaVersion: 2` still printed `decoded_catalog_count=1`.
