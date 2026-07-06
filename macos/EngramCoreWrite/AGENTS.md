# ENGRAM CORE WRITE KNOWLEDGE BASE

## OVERVIEW
`EngramCoreWrite` is the product write core. It owns GRDB schema/migrations, indexing writes, startup backfills, repo discovery, session snapshot persistence, embedding backfill tables/jobs, and project migration support.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Database writer | `Database/EngramDatabaseWriter.swift` | Product write pool and writer-owned DB operations. |
| Migrations | `Database/EngramMigrations.swift`, `Database/EngramMigrationRunner.swift` | Idempotent Swift migrations and schema runner. |
| Indexing | `Indexing/EngramDatabaseIndexer.swift`, `Indexing/SessionSnapshotWriter.swift` | Session indexing and snapshot writes. |
| Startup backfills | `Indexing/StartupBackfills.swift` | Provider-parent and suggested-parent backfills. |
| Repo discovery | `Indexing/RepoDiscovery.swift` | Populates repo metadata from session cwd state. |
| Project moves | `ProjectMove/` | Move/archive/undo/recover/batch domain; see the ProjectMove section below. |
| Tests | `../EngramCoreTests/` | Indexer, migration, startup backfill, project move, parity coverage. |

## CONVENTIONS
- Swift migrations are the product schema authority; keep them idempotent and covered by focused Swift tests.
- Write paths should be reachable through service-owned writers, not app/MCP local writers.
- `SessionSnapshotWriter` and indexer behavior should preserve tiering and parent/child invariants.
- Startup/backfill code must not surface provider health probes or review probes as normal sessions.
- Product sqlite-vec scaffolding has been removed; future vector work should introduce a fresh implementation with runtime callers and tests instead of wiring speculative placeholders.

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

---

# PROJECT MOVE SUBDIRECTORY (`ProjectMove/`)

> Merged here from `ProjectMove/AGENTS.md`: xcodegen bundles per-directory
> `AGENTS.md` files as framework resources, so two `AGENTS.md` under
> `EngramCoreWrite/` collided on the same output path and failed the release
> archive. Kept as one file per framework instead of adding a project.yml
> `excludes`.

## OVERVIEW
`ProjectMove/` is the Swift product implementation of project move/archive/undo/recover/batch. It patches filesystem state, AI session roots, Gemini project registry state, migration logs, and recovery metadata transactionally.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Orchestration | `Orchestrator.swift` | End-to-end move/archive transaction and compensation flow. |
| Source roots | `Sources.swift` | Claude, Codex, Gemini, iFlow, OpenCode, and related source path handling. |
| Gemini registry | `GeminiProjectsJSON.swift` | `~/.gemini/projects.json` plan/apply/reverse parity with TS reference. |
| Claude/Codex path encoding | `EncodeClaudeCodeDir.swift`, related files | Encoded cwd mapping; lossy one-way encoders. |
| Retry policy | `RetryPolicy.swift` | Terminal/transient classification and user-facing retry guidance. |
| Migration logs | `MigrationLog*.swift` | GRDB-backed records for undo/recover/list. |
| Tests | `../../EngramCoreTests/ProjectMove/` | Swift product coverage for fs ops, sources, orchestrator, retry, undo/recover. |
| TS parity reference | `../../../src/core/project-move/` | Reference/dev mirror, not product authority. |

## CONVENTIONS
- Project operations are sequential. Never launch multiple `project_*` tools in parallel.
- User-facing tools preview with `dry_run: true` first unless the user explicitly asked to execute immediately.
- `force: true` is only for explicit user force/override intent.
- Compensation and rollback behavior is part of the feature, not cleanup code.
- Preserve byte-exact snapshots when a reverse path promises it.
- Keep Swift and TS parity where retained fixture or compatibility tests require it, but Swift is the product path.
- Treat dirty git state as a safety gate, not a formatting issue.

## ANTI-PATTERNS
- Do not retry blindly after concurrent session modification; surface the affected state.
- Do not collapse distinct encoded cwd paths casually; encoders may be lossy by design.
- Do not mutate Gemini registry entries without collision checks.
- Do not hide partial migration state; recover/list tools depend on the migration log.

## COMMANDS
```bash
npm test -- tests/core/project-move
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/ProjectMove
```
