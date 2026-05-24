# 2026-05-24 CodeGraph Audit

## Scope

This was a read-mostly, CodeGraph-driven audit of the current Engram checkout.
CodeGraph provided the structural graph: symbol search, entry-point context,
callers, callees, impact radius, and indexed-file health. The bug selection,
risk classification, and source/test evidence review were manual.

Local CodeGraph state:

- Files indexed: 589
- Nodes: 7,878
- Edges: 21,765
- Backend: `node:sqlite`, WAL enabled

Native text search was still used for literal risk patterns such as `try?`,
`Task.detached`, `Process()`, `JSONSerialization`, and `NSLock`. The useful
scan excludes `macos/build`, DerivedData, SourcePackages, and tests; scanning
build output polluted results with third-party and dSYM hits.

## Findings

### High: long-running project migration commands can time out at 30s while the service keeps mutating

Evidence:

- `EngramServiceClient` defaults every command to a 30 second timeout:
  `macos/Shared/Service/EngramServiceClient.swift:13-16`.
- `projectMove`, `projectArchive`, `projectUndo`, and `projectMoveBatch` all
  call `command(...)` without passing a longer timeout:
  `macos/Shared/Service/EngramServiceClient.swift:125-138`.
- The timeout becomes the Unix socket receive/send timeout:
  `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:15-19`,
  `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:244-252`.
- A read timeout is reported as `Service socket read timed out`:
  `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:344-352`.
- The server runs the project move inside the request handler and then writes
  the response only after the pipeline finishes:
  `macos/EngramService/Core/EngramServiceCommandHandler.swift:181-215`.
- `ProjectMoveOrchestrator.run` performs git checks, lock acquisition,
  filesystem moves, source scans, JSON patching, DB migration logging, review,
  and compensation:
  `macos/EngramCoreWrite/ProjectMove/Orchestrator.swift:204-330`.
- App and MCP callers use the same default-timeout client:
  `macos/Engram/Views/Projects/RenameSheet.swift:488-530`,
  `macos/EngramMCP/Core/MCPToolRegistry.swift:1035-1097`.

Impact:

A legitimate project move/archive/undo/batch that takes longer than 30 seconds
can fail from the client's perspective while the service continues the mutation.
That creates a dangerous retry surface: the user or MCP caller can see a timeout
even though the migration lock, filesystem move, DB migration log, or
compensation path may still be progressing.

Suggested fix:

Give migration-class commands an explicit long timeout or a progress/event based
request model. At minimum, set a command-specific timeout for
`projectMove/projectArchive/projectUndo/projectMoveBatch` and add a test where a
slow handler exceeds the normal default but still succeeds under the migration
timeout.

### High: capability-token protection list has drifted from mutating service commands

Evidence:

- The token model says mutating/destructive service commands require a token:
  `macos/Shared/Service/ServiceCapabilityToken.swift:4-18`.
- The protected list only includes:
  `projectMove`, `projectArchive`, `projectUndo`, `projectMoveBatch`,
  `deleteInsight`, `setSessionHidden`, and `renameSession`:
  `macos/Shared/Service/ServiceCapabilityToken.swift:18-26`.
- The server enforces the token only when `requiresToken(request.command)` is
  true:
  `macos/EngramService/IPC/UnixSocketServiceServer.swift:95-105`.
- The client auto-attaches the token only for the same list:
  `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:21-38`.
- The command handler performs writes for additional commands that are not in
  `protectedCommands`: `generateSummary`, `saveInsight`,
  `manageProjectAlias`, `confirmSuggestion`, `dismissSuggestion`,
  `regenerateAllTitles`, `setFavorite`, `hideEmptySessions`, `linkSessions`,
  and `exportSession`:
  `macos/EngramService/Core/EngramServiceCommandHandler.swift:88-152`,
  `macos/EngramService/Core/EngramServiceCommandHandler.swift:172-278`.
- Current security tests prove token rejection for `setSessionHidden`, but do
  not cover every write command:
  `macos/EngramServiceCoreTests/ServiceSecurityHardeningTests.swift:163-190`,
  `macos/EngramServiceCoreTests/ServiceSecurityHardeningTests.swift:203-228`.

Impact:

The defense-in-depth boundary is inconsistent. A direct socket request without
a valid token can still mutate insights, aliases, favorites, title metadata,
suggested links, empty-session hiding, exported files, or symlink exports,
depending on command. The peer-euid gate still blocks other OS users, so this is
not a remote privilege escalation by itself, but it violates the service's own
mutating-command token contract and leaves future socket exposure changes risky.

Suggested fix:

Make the protected command list derive from a single service-command policy, or
add all mutating/file-writing commands explicitly. Add one table-driven security
test that sends each mutating command with a wrong token through
`UnixSocketEngramServiceTransport` and expects `Unauthorized`.

### Medium: read-only export is executed under the write gate and advances databaseGeneration

Evidence:

- `exportSession` is dispatched through `writerGate.performWriteCommand`:
  `macos/EngramService/Core/EngramServiceCommandHandler.swift:270-278`.
- `TranscriptExportService.exportSession` opens the database read-only:
  `macos/EngramService/Core/TranscriptExportService.swift:14-18`.
- The command then parses transcript content and writes a file under
  `codex-exports`:
  `macos/EngramService/Core/TranscriptExportService.swift:21-32`.
- `performWriteCommand` serializes on the write semaphore and increments
  `databaseGeneration` after any successful operation:
  `macos/EngramService/Core/ServiceWriterGate.swift:67-79`.

Impact:

Exporting a large transcript can block unrelated writes such as hide/rename,
favorites, insights, project aliases, and project migrations even though export
does not write the database. It also emits a new `databaseGeneration` for a
read-only DB operation, which can make app-side cache invalidation look like a
real database mutation.

Suggested fix:

Move export off `performWriteCommand`. If filesystem exports still need
serialization, use a separate export/file gate and return no
`databaseGeneration` unless a DB row actually changed.

### Medium: export path validation does not protect the fixed `codex-exports` child from symlink redirection

Evidence:

- `outputHome` validates the requested home path and rejects symlink ancestors
  from `outputHome` through `$HOME`:
  `macos/EngramService/Core/TranscriptExportService.swift:41-62`,
  `macos/EngramService/Core/TranscriptExportService.swift:65-81`.
- The actual export directory is appended after that validation:
  `macos/EngramService/Core/TranscriptExportService.swift:21-24`.
- The final write goes to `outputHome/codex-exports/<file>`:
  `macos/EngramService/Core/TranscriptExportService.swift:26-32`.
- Existing tests cover outside-HOME rejection and normal export behavior, but
  no test covers a pre-existing `codex-exports` symlink:
  `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift:341-382`,
  `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift:523-564`.

Impact:

If `$HOME/codex-exports` or `<requestedHome>/codex-exports` already exists as a
symlink, validation can pass for the parent home while the final write is
redirected outside the allowed tree. That bypasses the "output_home must be
within HOME" intent.

Suggested fix:

Validate the complete output directory and final path after appending
`codex-exports`, reject existing symlinks for that child, and re-check after
directory creation. Add a regression test that creates
`home/codex-exports -> outside` and expects `invalidRequest`.

### Medium: repository discovery shells out to git inside the serialized write path with no timeout

Evidence:

- The periodic indexing loop enters `gate.performWriteCommand("indexRecent")`:
  `macos/EngramService/Core/EngramServiceRunner.swift:243-257`.
- Inside that write-gated operation it calls `writer.write { db in
  RepoDiscovery.discover(db) }`:
  `macos/EngramService/Core/EngramServiceRunner.swift:258-261`.
- `RepoDiscovery.discover` iterates distinct session `cwd` values and probes
  each with real git:
  `macos/EngramCoreWrite/Indexing/RepoDiscovery.swift:57-79`.
- Each probe shells out up to four times:
  `rev-parse --show-toplevel`, `rev-parse --abbrev-ref HEAD`,
  `status --porcelain`, `rev-list --count @{u}..HEAD`, and `log -1`:
  `macos/EngramCoreWrite/Indexing/RepoDiscovery.swift:113-147`.
- `runGit` has no timeout and waits synchronously:
  `macos/EngramCoreWrite/Indexing/RepoDiscovery.swift:163-180`.

Impact:

A slow/hung git command, network-backed repo, enormous worktree, or bad git
config can hold the service write gate and/or DB writer path. During that time,
normal service writes can queue, time out, or appear wedged. This is exactly the
kind of shape that caused the earlier "startup scan / Repos page" risk, even
though the recent-scan scope is now smaller.

Suggested fix:

Move git probing outside the DB write closure and enforce a per-git timeout.
Persist only the final probe results under a short DB write. Add a test with an
injected slow/hanging probe proving the write gate is not held while git waits.

### Low: accepted client tasks can be inserted after they already completed

Evidence:

- The server creates and starts `clientTask` before inserting it into
  `state.clientTasks`:
  `macos/EngramService/IPC/UnixSocketServiceServer.swift:81-116`.
- The task's `defer` removes its id from `state.clientTasks`:
  `macos/EngramService/IPC/UnixSocketServiceServer.swift:83-89`.

Impact:

For very fast error paths or very small requests, the detached task can finish
and run its removal before the accept loop inserts the task. The accept loop can
then insert a completed task that will remain in `clientTasks` until service
stop. This is bounded by accepted request rate and service lifetime, but it is a
real lifecycle race.

Suggested fix:

Insert a placeholder/state entry before starting the detached task, or start the
task suspended via a small wrapper pattern. Add a stress test that sends many
fast invalid frames and exposes a debug-only active-client count.

## Non-findings / notes

- The current CodeGraph index is healthy and fast. No restart is needed for the
  current session.
- `.codegraph/` is a local index artifact and should normally stay uncommitted.
- `.cursor/rules/codegraph.mdc` is editor guidance generated by CodeGraph; it is
  optional project policy, not required for the app runtime.
- The broad literal scan must exclude build artifacts; otherwise third-party
  Swift package checkouts and dSYM relocation files dominate the output.

## Checks run

- `codegraph_status`
- `codegraph_context` for startup, service/MCP boundary, and adapter ingestion
- `codegraph_search` for service runner, command handler, IPC server, export,
  repo discovery, project move, session watcher
- `codegraph_callers`, `codegraph_callees`, and `codegraph_impact` for the
  findings above
- Targeted `rg` literal risk scans with build/test exclusions
- Targeted source reads with line numbers for each finding

## Checks not run

- No product tests were run.
- No build or lint was run.

Why not: this audit did not modify product code and the findings are static
defects or design gaps. Each recommended fix should be implemented with
failing-test-first coverage.

## Remediation status

Status: fixed in the same working tree.

Fixes implemented:

- Migration-class app/client commands now use an explicit long timeout.
- The capability-token command list now covers the service's mutating and
  file-writing commands.
- `exportSession` no longer runs through the write gate and no longer advances
  `databaseGeneration`.
- Transcript export validates the full `codex-exports` output directory and
  final file path against symlink redirection.
- Repository discovery now reads candidate `cwd` values under the DB gate,
  probes git outside the write path with a per-command timeout, then persists
  only final results under a short DB write.
- Accepted client handlers are now registered before they can complete, closing
  the completed-task tracking race.

Remediation checks run:

- `EngramCoreTests`: 284 tests, 0 failures.
- `EngramServiceCore`: 69 tests, 0 failures.
- `EngramTests`: 216 tests, 0 failures, 1 opt-in live test skipped.
- `EngramMCPTests`: 46 tests, 0 failures.
- `Engram` Debug build warning/error filter: no `warning:` or `error:` lines;
  `** BUILD SUCCEEDED **`.
- `git diff --check`: clean.
