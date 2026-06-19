# ENGRAM CORE WRITE KNOWLEDGE BASE

## OVERVIEW
`EngramCoreWrite` is the product write core. It owns GRDB schema/migrations, indexing writes, startup backfills, repo discovery, session snapshot persistence, vector policy placeholders, and project migration support.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Database writer | `Database/EngramDatabaseWriter.swift` | Product write pool and writer-owned DB operations. |
| Migrations | `Database/EngramMigrations.swift`, `Database/EngramMigrationRunner.swift` | Idempotent Swift migrations and schema runner. |
| Indexing | `Indexing/EngramDatabaseIndexer.swift`, `Indexing/SessionSnapshotWriter.swift` | Session indexing and snapshot writes. |
| Startup backfills | `Indexing/StartupBackfills.swift` | Provider-parent and suggested-parent backfills. |
| Repo discovery | `Indexing/RepoDiscovery.swift` | Populates repo metadata from session cwd state. |
| Project moves | `ProjectMove/` | Move/archive/undo/recover/batch domain; child AGENTS overrides. |
| Tests | `../EngramCoreTests/` | Indexer, migration, startup backfill, project move, parity coverage. |

## CONVENTIONS
- Swift migrations are the product schema authority; keep them idempotent and covered by focused Swift tests.
- Write paths should be reachable through service-owned writers, not app/MCP local writers.
- `SessionSnapshotWriter` and indexer behavior should preserve tiering and parent/child invariants.
- Startup/backfill code must not surface provider health probes or review probes as normal sessions.
- `SQLiteVecSupport` and vector rebuild policy are placeholders until product sqlite-vec is implemented; do not wire speculative vector behavior.

## ANTI-PATTERNS
- Do not use TypeScript schema code as source of truth for Swift-only defaults.
- Do not upgrade subagent/dispatch children out of `skip`.
- Do not make migration failures look like successful partial writes.
- Do not put project-move-specific safety rules only in callers; the domain code owns compensation and logging invariants.

## COMMANDS
```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/IndexerParityTests
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/StartupBackfillTests
```
