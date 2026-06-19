# PROJECT MOVE KNOWLEDGE BASE

## OVERVIEW
This directory contains the Swift product implementation of project move/archive/undo/recover/batch. It patches filesystem state, AI session roots, Gemini project registry state, migration logs, and recovery metadata transactionally.

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
