# PR #26-#32 Post-Merge Regression Audit

Date: 2026-05-30
Scope: current `main` plus the focused fixes for deferred `mig-2`, `conc-1`, and the CI follow-up.
Verdict: PASS. No post-merge regression found in PR #26-#32 fixes.

## Evidence

| PR | Current-state check | Evidence |
| --- | --- | --- |
| #26 project-move integrity | Phase-A failures now release the migration lock on every exit path; rollback records all successful patches before surfacing hard per-file errors. | `macos/EngramCoreWrite/ProjectMove/Orchestrator.swift:246`, `macos/EngramCoreWrite/ProjectMove/Orchestrator.swift:252`, `macos/EngramCoreWrite/ProjectMove/Orchestrator.swift:408`, `macos/EngramCoreWrite/ProjectMove/Orchestrator.swift:421` |
| #27 writer-gate permit leak | A waiter that is cancelled after being signalled returns the acquired permit before throwing cancellation. | `macos/EngramService/Core/ServiceWriterGate.swift:205`, `macos/EngramService/Core/ServiceWriterGate.swift:214` |
| #28 startup gate split | Startup indexing, maintenance/parents, orphan scan, FTS drain, and usage collection are separate gated write commands; no single `initialScan` gate remains. | `macos/EngramService/Core/EngramServiceRunner.swift:357`, `macos/EngramService/Core/EngramServiceRunner.swift:362`, `macos/EngramService/Core/EngramServiceRunner.swift:371`, `macos/EngramService/Core/EngramServiceRunner.swift:386`, `macos/EngramService/Core/EngramServiceRunner.swift:395` |
| #29 DB write atomicity | Aux-table migrations filter orphan `session_id` rows before FK-bearing rebuilds; per-snapshot writes run under a savepoint. | `macos/EngramCoreWrite/Database/EngramMigrations.swift:432`, `macos/EngramCoreWrite/Database/EngramMigrations.swift:436`, `macos/EngramCoreWrite/Database/EngramMigrations.swift:459`, `macos/EngramCoreWrite/Database/EngramMigrations.swift:463`, `macos/EngramCoreWrite/Database/EngramMigrations.swift:820`, `macos/EngramCoreWrite/Database/EngramMigrations.swift:835`, `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:36` |
| #30 live indexing | Periodic scans run parent-link backfills after indexing new sessions, and git subprocess output is drained concurrently. | `macos/EngramService/Core/EngramServiceRunner.swift:288`, `macos/EngramService/Core/EngramServiceRunner.swift:293`, `macos/EngramCoreWrite/Indexing/EngramDatabaseIndexer.swift:79`, `macos/EngramCoreWrite/Indexing/RepoDiscovery.swift:230`, `macos/EngramCoreWrite/Indexing/RepoDiscovery.swift:237` |
| #31 SwiftUI off-main + async ordering | Source guards pin off-main view reads, stale-search cancellation guards, child-count invalidation, and cancelling `.task(id:)` patterns. | `macos/EngramTests/ViewMainThreadReadTests.swift:19`, `macos/EngramTests/ViewMainThreadReadTests.swift:28`, `macos/EngramTests/ViewMainThreadReadTests.swift:34`, `macos/EngramTests/ViewMainThreadReadTests.swift:48`, `macos/EngramTests/ViewMainThreadReadTests.swift:56`, `macos/EngramTests/ViewMainThreadReadTests.swift:65` |
| #32 IPC liveness + retention + web-host | Socket timeout setup failure rejects the client; status events ride out transient service unavailability; retention includes `usage_snapshots`; Host/Origin checks enforce expected port. | `macos/EngramService/IPC/UnixSocketServiceServer.swift:91`, `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:96`, `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:103`, `macos/EngramService/Core/ObservabilityRetention.swift:20`, `macos/EngramService/Core/ObservabilityRetention.swift:63`, `macos/EngramService/Core/EngramWebUIServer.swift:140`, `macos/EngramService/Core/EngramWebUIServer.swift:144`, `macos/EngramService/Core/EngramWebUIServer.swift:177`, `macos/EngramService/Core/EngramWebUIServer.swift:187` |

## Cross-Regression Notes

- The `conc-1` transport change keeps #32's timeout rejection intact before client tasks start, then offloads only the bounded `readFrame`/`writeFrame` calls to a dedicated GCD queue (`macos/EngramService/IPC/UnixSocketServiceServer.swift:10`, `macos/EngramService/IPC/UnixSocketServiceServer.swift:114`, `macos/EngramService/IPC/UnixSocketServiceServer.swift:125`, `macos/EngramService/IPC/UnixSocketServiceServer.swift:240`).
- The `mig-2` side-table rebuild keeps #28/#30's FTS recovery path intact: rebuild apply reopens recoverable FTS jobs, `IndexJobRunner` writes active + shadow FTS during pending rebuild, and finalizes only when recoverable jobs are drained.
- The CI follow-up now runs the service-core and MCP schemes that previously only received local coverage.

## Checks

- `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — passed, 94 tests.
- `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — passed, 53 tests.
- Targeted `mig-2` FTS tests passed after TDD implementation.
- Targeted `conc-1` IPC offload guard passed after TDD implementation.
