# Engram Code Review — 5-Round Multi-Expert Audit

Goal: dispatch domain-expert subagents across 5 rounds (each round's brief
adjusts to the prior round's surface area), adversarially verify every
candidate finding against the actual code, and retain only the issues that can
be defended at file:line. Prior reviews (`docs/reviews/2026-06-02-macos-swift-product-code-review.md`) were
given to every expert as "do not re-report" input.

Scope priority follows `CLAUDE.md`: Swift is the product runtime; TypeScript is
dev/reference. All findings below are Swift unless noted.

Adversarial-verify rejection (the one candidate finding that did NOT survive):
a Round 4 expert claimed `SearchView` hardcoded `mode: "hybrid"` and ignored
the mode pills. Verified against
`macos/Engram/Views/SearchView.swift:273-278`: the code reads
`let mode = selectedMode.rawValue` and passes it to the request. Finding
discarded. This confirms the verification step is load-bearing rather than a
rubber stamp.

---

## Round 1 — EngramService runtime, IPC, capability/auth, writer gate

Expert: `swift_service_expert`. Prior review already closed capability-token
timing-attack, peer-uid, socket 0600, web UI host/CORS/bearer, body-size,
transcript path normalization, linkSessions gate-holding, FSEvents permit
leak, transcript pager raw-vs-displayed unit mismatch, and the missing
session 404. This round looks for residual issues on the same surface.

### Medium

**EINTR on `Darwin.read`/`write` aborts the IPC instead of retrying**
`macos/Shared/Service/UnixSocketEngramServiceTransport.swift:362-394`
- `writeAll` and `readExact` treat any negative return as fatal. POSIX returns
  `-1` with `errno == EINTR` when a blocking syscall is interrupted by a
  signal; the correct response is to retry. Current code falls through to
  `TransportClosed`.
- Impact: a benign signal during a frame transfer (the 30s per-frame deadline
  leaves plenty of room for one) is misclassified, tearing the connection
  down and triggering a reconnect storm under signal-heavy parent processes.
- Fix: `if written < 0 && errno == EINTR { continue }` (and the same in
  `readExact`). `SO_RCVTIMEO`/`SO_SNDTIMEO` persist on the fd, so re-arming
  is unnecessary.

### Low

**`stop()`-coincident client task leaks fd + connection-limiter permit**
`macos/EngramService/IPC/UnixSocketServiceServer.swift:99-152, 163-187`
- The per-client cleanup `defer` is declared inside the
  `guard await startGate.wait() else { return }` branch. If `stop()` cancels
  the task while it is parked at `startGate.wait()`, the continuation
  resumes `false`, the task returns through the guard's else, and the defer
  never executes — the client fd and the limiter permit leak.
- Impact: masked today because the service is short-lived (one process per
  app launch); kernel reaps fds on exit. Becomes real if the service ever
  restarts in-place: 32 leaks exhaust the limiter and the server stops
  accepting.
- Fix: hoist the cleanup out of the guard, or have the `!shouldContinue`
  path always do `close(client)` + `connectionLimiter.signal()` directly.

**`confirmSuggestion` does not update `link_checked_at`**
`macos/EngramService/Core/EngramServiceCommandHandler.swift:413-450`
- `setParentSession` writes `link_checked_at = datetime('now')`;
  `confirmSuggestion` does the same `parent_session_id` +
  `link_source = 'manual'` assignment but never bumps `link_checked_at`.
  Safe today because the backfill candidate query filters on
  `suggested_parent_id IS NOT NULL`, so confirmed rows are excluded via the
  suggestion clause. The drift invites a bug the next time the backfill
  filter is rewritten.
- Fix: mirror `setParentSession`'s write of `link_checked_at = datetime('now')`.

**`regenerateAllTitles` runs unbounded serial AI calls with no cancellation**
`macos/EngramService/Core/EngramServiceCommandHandler.swift:921-967`
- The loop iterates every session with NULL/empty `generated_title`
  serially, with a 45s per-call URLSession timeout. No `Task.isCancelled`
  check, no progress event, no concurrency cap. On a 1k-session DB this is
  tens of minutes of blocking IPC.
- Fix: add `Task.isCancelled` checks per iteration, batch with a
  `TaskGroup` capped at 4-8, emit a progress event every K iterations.

**Web UI transcript parser failure returns HTTP 200 with error body**
`macos/EngramService/Core/EngramWebUIServer.swift:253-314`
- The not-found branch correctly returns `.notFound` (prior fix). The
  parse-failure catch sets `messageHTML = transcriptErrorHTML` and falls
  through to the `.ok` return — a wedged parser ships a 200 with
  "Transcript unavailable" HTML.
- Fix: map `ParserFailure` cases to status codes (fileMissing /
  fileModifiedDuringParse → 404, fileTooLarge → 413/503) and return them.

---

## Round 2 — Swift indexing & write subsystem

Expert: `swift_indexing_expert`. Brief tightened after Round 1 to look for
the same "missing-COALESCE-on-upsert" anti-pattern on other columns (the
prior review's High finding was on `tier`/`agent_role`; verify whether
sibling columns share the defect).

### Medium

**Re-index clobbers `cwd` (sibling to the known tier/agent_role clobber)**
`macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:215`
- The ON CONFLICT clause sets `cwd = excluded.cwd` with no COALESCE while
  `project`, `model`, `summary`, `summary_message_count`, `origin` all use
  COALESCE-preserve. If an adapter ever returns an empty `cwd` for a
  re-index (mid-parse failure, future adapter that cannot derive cwd), the
  previous non-empty value is silently overwritten with `''`. The
  `SwiftIndexer.buildSnapshot` fallback (`if info.project == nil,
  !info.cwd.isEmpty`) cannot re-derive project from empty cwd, so the loss
  is permanent until a manual rewrite.
- Fix: `cwd = CASE WHEN excluded.cwd IS NULL OR excluded.cwd = '' THEN
  sessions.cwd ELSE excluded.cwd END`. Mirror in the Swift merge path
  (`merged.cwd = incoming.cwd.isEmpty ? sessions.cwd : incoming.cwd`).

**Re-index clobbers `message_count` and per-role sub-counts**
`macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:218-222`
- Same shape on `message_count`, `user_message_count`,
  `assistant_message_count`, `tool_message_count`, `system_message_count`.
  A future adapter or a partial parse returning zero counts blanks the
  existing counts. `summary_message_count` is preserved via COALESCE — the
  sub-counts are the asymmetric omission.
- Fix: COALESCE-preserve, or guard with `WHEN excluded.message_count = 0`
  → keep existing.

**`backfill_counts` and `backfill` (costs) events are never emitted**
`macos/EngramCoreWrite/Indexing/StartupComposition.swift:44-48` +
`macos/EngramCoreWrite/Indexing/StartupBackfills.swift:203-219`
- `WriterStartupIndexing.backfillCounts` / `backfillCosts` unconditionally
  return 0 (the Swift indexer handles counts/costs inline). The startup
  event emitter gates the corresponding events on count > 0, so they are
  never emitted. The UI consumer cannot distinguish "no-op because inline"
  from "broken".
- Fix: return the count of changed sessions from the inline path, or emit a
  `backfill_inline` event so the progress stream stays honest.

**`SessionBatchUpsert.upsertBatch` lacks an outer transaction**
`macos/EngramCoreWrite/Indexing/SessionBatchUpsert.swift:11-39`
- Each `writer.writeAuthoritativeSnapshot` opens its own savepoint; whole-
  batch atomicity depends on the caller wrapping in `writer.write`. Only
  `EngramDatabaseIndexingSink.upsertBatch` does. The four test call sites
  (`IndexerParityTests:49,202`, `IndexJobAndMaintenanceTests:159,254`)
  call it bare, so the test suite silently exercises a different
  transactionality than production. A future caller that omits the wrap
  silently loses batch atomicity.
- Fix: move the `writer.write` wrap into `SessionBatchUpsert.upsertBatch`
  itself, or add a `requiresTransactionalContext` precondition that throws
  when called outside a write block.

### Low

**FTS rebuild swap is two non-atomic renames with no reader retry**
`macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift:73-79`
- Rename `sessions_fts` → `sessions_fts_old`, then `sessions_fts_new` →
  `sessions_fts`, then drop old. Between the two renames the FTS5 virtual
  table is briefly absent under its canonical name; a concurrent reader
  (MCP `get_context`) can hit `no such table`. Window is microseconds and
  the rebuild is rare, but there is no read-side retry.
- Fix: wrap the swap in a single `db.write { ... }` to serialize against
  readers via the writer gate, or add a one-shot retry on the read side.

**Watcher rename (unlink + add) leaves a transient orphan-flagged session**
`macos/EngramCoreWrite/Indexing/SessionWatcher.swift:120-126`
- The unlink handler calls `orphanMarker.markOrphanByPath(...)`. If the
  unlink is part of a file rename, the subsequent add event indexes the new
  path and updates `file_path` but the orphan flag set against the OLD
  `file_path` is not cleared. The next orphan scan (gated by a 30-day grace
  window) clears it.
- Fix: in the indexFile success handler, clear `orphan_status` /
  `orphan_since` / `orphan_reason` for the affected session.

**`deduplicateFilePaths` orphans children when duplicate rows have
different ids**
`macos/EngramCoreWrite/Indexing/StartupBackfills.swift:434-452` +
`macos/EngramCoreWrite/Database/EngramMigrations.swift:62-78`
- The dedup DELETE keeps `MAX(rowid) GROUP BY file_path`. If two rows share
  a `file_path` but have different ids (adapter bug, or a source that
  hashes cwd into the id and the cwd changed), the trigger nullifies
  children of the deleted id and tier-resets them. The kept session does
  not inherit the children — link permanently lost until the next
  `DETECTION_VERSION` bump.
- Fix: in the dedup DELETE, also re-parent children:
  `UPDATE sessions SET parent_session_id = <kept_id> WHERE
  parent_session_id IN (<deleted_ids>)`.

**Orphan scan probes open every SQLite source DB once per session**
`macos/EngramCoreWrite/Indexing/StartupComposition.swift:202-233`
- `detectOrphans` calls `adapter.isAccessible(locator:)` per session.
  Cursor / OpenCode adapters do `Phase4SQLiteDatabase(path:) +
  query(...)` per call. On a corpus of 50k sessions sharing a few
  cursor.sqlite files, the scan opens the same DB N times.
- Fix: group sessions by `dbPath`, probe each unique dbPath once, cache.

**Noop merge still runs `upsertZeroCostRow` and
`replaceSessionToolsIfDifferent`**
`macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:20-26, 336-340`
- When the merge returns `.noop` (hash unchanged), the writer still issues
  an INSERT-OR-UPDATE on the cost row and a SELECT for tool counts. On a
  full-corpus rescan that finds 99% unchanged, that's two redundant
  statements per session per cycle.
- Fix: early-return from `writeAuthoritativeSnapshot` when
  `merge.action == .noop`.

**`link_source` first-INSERT and ON-CONFLICT clauses are textually
inconsistent**
`macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:209 vs 255-259`
- The first-INSERT writes
  `link_source = CASE WHEN ? IS NOT NULL THEN 'path' ELSE NULL END` (no
  'manual' guard); the ON CONFLICT correctly guards
  `sessions.link_source = 'manual'`. Both paths agree today for all
  observed inputs, but a future change adding `'manual'` to fresh inserts
  would silently diverge from the upsert path.
- Fix: centralize the link_source expression or add a parity truth-table
  test.

---

## Round 3 — Project migration / move / archive

Expert: `swift_migration_expert`. Brief adjusted: the prior review's Highs
covered the Claude Code dot→dash and Gemini basename-vs-slug encoder bugs.
Survey every other per-source encoder for the same shape; audit lock /
filesystem ops surfaces not touched before.

### High

**iFlow encoder is documented "lossy by design" but has no collision probe**
`macos/EngramCoreWrite/ProjectMove/Sources.swift:126-141` (encoder),
`macos/EngramCoreWrite/ProjectMove/Orchestrator.swift:289-321` (missing
probe)
- `encodeIflow` strips per-segment leading/trailing dashes. The docstring
  explicitly states `/a/-foo-/p` and `/a/foo/p` both encode to `-a-foo-p`
  and claims "the orchestrator's pre-flight stat catches the collision".
  The orchestrator's `Step 0.7` runs
  `GeminiProjectsJSON.collectOtherCwdsSharingBasename` for Gemini at
  `Orchestrator.swift:331`. There is NO iFlow equivalent. The filesystem
  stat at `Orchestrator.swift:309-321` only catches a collision when the
  target dir already exists — if neither cwd has a dir at the target yet,
  the rename succeeds and the second project silently merges over the
  first.
- Fix: enumerate `~/.iflow/projects`, reverse-map by re-running
  `encodeIflow` over known cwds, throw `SharedEncodingCollisionError` on
  match. Mirror Gemini's pre-flight in `Orchestrator.run` for iFlow.

### Medium

**SQLite-backed sources (opencode.db, antigravity state.db, codex,
copilot) are silently skipped by `walkSessionFiles`**
`macos/EngramCoreWrite/ProjectMove/Sources.swift:164` (extensions default)
- `walkSessionFiles`'s default
  `extensions: Set<String> = [".jsonl", ".json"]`. Verified live:
  `OpenCodeAdapter.swift:67` stores sessions in
  `.local/share/opencode/opencode.db`. `findReferencingFiles` uses the same
  default, so the orchestrator's perSource stats report 0 filesPatched / 0
  occurrences for these sources. A move silently leaves SQLite content
  pointing at the old cwd; orchestrator reports success.
- Fix: either add `.db` / `.sqlite` to the default set with a SQLite-aware
  `UPDATE` patch path (safer than byte replacement on binary blobs), or
  explicitly mark these sources as `unsupported` with a `perSource` reason
  surfaced in `PipelineResult`.

**`MigrationLock` has no age-based TTL**
`macos/EngramCoreWrite/ProjectMove/MigrationLock.swift:65-111`
- Stale-detection is `isProcessAlive(pid)` only. A wedged-but-alive
  holder (suspended in lldb, stuck on a slow filesystem walk) holds the
  lock forever. Every subsequent acquire throws `LockBusyError`; no
  documented recovery short of killing the holder.
- Fix: add a TTL parameter (default 1h). If
  `now - holder.startedAt > TTL` AND `holder.pid != getpid()`, break the
  lock and proceed (log a warning). Mirror in `hasPendingMigrationFor`.

**`kill(pid, 0)` returns 0 for zombies; lock treats them as alive**
`macos/EngramCoreWrite/ProjectMove/MigrationLock.swift:172-179`
- `isProcessAlive` returns true on `kill == 0`, which is also true for
  zombie processes. A zombie holder permanently parks the lock.
- Fix: after `kill == 0`, additionally check process state via
  `sysctl(KERN_PROC_PID)` and reject zombie processes. Combine with the
  TTL fix above.

### Low

**`Archive.suggestTarget` accepts an empty / malformed `.git` file as a
valid worktree marker**
`macos/EngramCoreWrite/ProjectMove/Archive.swift:174-198`
- When `.git` is a regular file (worktree/submodule case), the content is
  never inspected. An empty `.git` file or one with garbage content is
  categorized as `归档完成` (archive-complete). A real project with a
  healthy `.git` directory but a stray HEAD issue falls into the ambiguous
  bucket.
- Fix: read the first ~200 bytes, verify a `gitdir:` line that resolves to
  a real path containing HEAD. Otherwise fall through to ambiguous.

**`validateProjectPathConfined` does not resolve symlinks**
`macos/EngramService/Core/EngramServiceCommandHandler.swift:1067-1086`
- The check uses `URL.standardizedFileURL.path`, which does NOT follow
  symlinks. A symlink under home that points elsewhere passes the
  home-prefix check. Unreachable today because `FsOps` defaults to
  `followSymlinks = false`, but the boundary is fragile.
- Fix: after standardization, `lstat` and refuse symlink sources, or
  `realpath` and re-validate the resolved path under the home prefix.

**`walkSessionFiles` silently skips FIFO / socket / device files**
`macos/EngramCoreWrite/ProjectMove/Sources.swift:207`
- The walk handles `S_IFLNK` → `onIssue(.skippedSymlink)`, `S_IFDIR` →
  recurse, `S_IFREG` → check extension. Anything else hits
  `if mode != S_IFREG { continue }` with no `onIssue` call. An exotic
  layout disappears from the audit manifest.
- Fix: add `WalkIssueReason.skippedNonRegular` and emit it.

**`JsonlPatch.patchFile` does not fsync the tmp file before rename**
`macos/EngramCoreWrite/ProjectMove/JsonlPatch.swift:190-220, 252-352`
- The tmp file's bytes are not `fsync`'d before
  `Darwin.rename(tmp, filePath)`. The parent directory is fsync'd. On
  power loss between write and rename, the rename metadata commits but
  the tmp's contents may not be on disk; recovery sees an empty/truncated
  file while the migration log records the patch as successful. Rollback
  cannot recover bytes that were never durable.
- Fix: `fsync(fd)` on the tmp's descriptor before `rename`. Keep the
  parent-dir fsync.

**`hasPendingMigrationFor` is O(N) scan on `migration_log` with no index**
`macos/EngramCoreWrite/ProjectMove/MigrationLogStore.swift:349-373`
- Filters `state IN ('fs_pending', 'fs_done')` plus a substring-prefix
  match on `old_path` / `new_path`. Schema has no `state`, `started_at`,
  or path index. Every indexing scan / watcher tick consults this — slows
  the hot path as `migration_log` grows.
- Fix: `CREATE INDEX IF NOT EXISTS migration_log_state_started_idx ON
  migration_log(state, started_at)` in a new idempotent migration.

**`OrchestratorError.dirRenameFailed` discards POSIX `errno`**
`macos/EngramCoreWrite/ProjectMove/Orchestrator.swift:357-374`
- `moveItemRespectingExisting` builds an NSError with `strerror(code)` in
  `NSLocalizedDescriptionKey`, but the catch site builds the user-visible
  message from `error.localizedDescription`, which Foundation returns as
  the generic "The operation couldn't be completed". The errno code
  (EACCES, EBUSY, EPERM, EROFS) is unrecoverable from the response.
- Fix: define `PosixRenameError(code: Int32, message: String)` and surface
  the `strerror`-formatted message through `OrchestratorError`.

---

## Round 4 — SwiftUI views, view-model state, concurrency discipline

Experts: `swift_ui_views_expert` + `swift_concurrency_expert`. Brief
adjusted: Rounds 1-3 found "state-consistency / contract-by-convention"
bugs in the write/IPC/migration layer. Check whether the UI layer repeats
the same shape (settings persistence drops fields, debounce races leak
ghost results, the @MainActor / nonisolated contract is enforced only by
discipline).

### High

**`SearchView.performSearch` spawns uncancellable inner Task — ghost
results**
`macos/Engram/Views/SearchView.swift:192-205, 268-308`
- `onChange(of: query)` cancels `searchTask` (the 300ms debounce wrapper)
  and starts a new one. After the sleep, the wrapper calls
  `performSearch()`, which spawns a fresh `Task { ... }` for the
  `serviceClient.search` round-trip but does NOT assign it to `searchTask`.
  The next keystroke can cancel the debounce wrapper but the in-flight
  service round-trip continues; whichever response lands last writes
  `results`.
- Impact: typing "claude" can produce 6 in-flight searches; the slowest
  lands last and the visible result list is stale relative to the input.
- Fix: assign `searchTask = Task { ... }` inside `performSearch`. Mirror
  `CommandPaletteView.performSearch:183-187` and
  `GlobalSearchOverlay:100-104`.

**`@MainActor DatabaseManager` captured into `Task.detached` across the
entire UI relies on a type-system-unenforced "all reads are `nonisolated`"
contract**
`macos/Engram/Core/Database.swift:51-66` + 17 view files
- `DatabaseManager` is `@MainActor @Observable`, holds
  `nonisolated(unsafe) private var pool: DatabasePool?` under `NSLock`.
  Every view captures the instance into
  `Task.detached { let db = self.db; ... }` and calls only `nonisolated`
  read methods. Works today because every consumed method is `nonisolated`.
  The type system does not enforce that — a future contributor adding a
  non-`nonisolated` accessor would compile silently and break main-actor
  isolation off-thread. The project does not run strict-concurrency
  checking; the Sendable violation is tolerated.
- Fix: drop the `@MainActor` annotation on `DatabaseManager` and move state
  into a private actor or non-isolated `let` set at app init. The one
  `@Observable` registration that needs MainActor can hop via
  `MainActor.assumeIsolated`. The nonisolated discipline then becomes
  compiler-enforced.

### Medium

**`LogStreamView` timer and filter-change spawn overlapping uncancellable
reloads**
`macos/Engram/Views/Observability/LogStreamView.swift:82-86, 88-112`
- Both `.onReceive(timer)` and `.onChange(of: selectedLevel/Module)` start
  a fresh, unstored `Task { await reload() }`. 5s ticks and filter changes
  overlap; OSLogReader.recentLogs is a synchronous scan, so two concurrent
  scans can land in either order.
- Fix: hold `@State private var reloadTask: Task<Void, Never>?`, cancel +
  replace on every trigger.

**`SessionListView` `.task` (appear) and `.onChange` filterTask race**
`macos/Engram/Views/SessionListView.swift:165-185, 402-443`
- `.task` runs `loadSessions()` and is not stored. `.onChange` cancels and
  restarts `filterTask` after 150ms. A quick filter change within the
  first 150ms of view appearance can land the original `.task`'s result
  after the filter load has painted, overwriting `sessions` with the
  pre-filter list.
- Fix: wrap both in `task(id: filterFingerprint)`, or store and cancel the
  `.task` handle from `.onChange`.

**`CommandPaletteView.performSearch` has no debounce and unstored inner
Task**
`macos/Engram/Views/CommandPaletteView.swift:70-77, 179-218`
- `onChange(of: query)` calls `performSearch()` per keystroke. The
  function cancels `searchTask` and starts a new one — but the new Task is
  not assigned to `searchTask`. Same ghost-results shape as the
  `SearchView` finding above.
- Fix: add a 300ms debounce and assign `searchTask = Task { ... }`.

**`AISettingsSection` lacks the `isLoadingSettings` guard that other
SettingsSections use**
`macos/Engram/Views/Settings/AISettingsSection.swift:339, 427-467, 352-397`
- `AdvancedSettingsSection:400-401` and `NetworkSettingsSection:47-48` set
  `isLoadingSettings = true` during `load*()` and guard saves with
  `guard !isLoadingSettings else { return }`. `loadAISettings()` does no
  such guard; every visit to the AI tab fires 17 `.onChange` handlers
  that re-write `settings.json`.
  `SourcesSettingsSection.DataSourceRow:76-108` has the same issue.
- Fix: add `isLoadingSettings` and guard every save call.

**`App.startServiceStatusObservation` task inherits MainActor — event
pump on main thread**
`macos/Engram/App.swift:212-240`
- `AppDelegate` is `@MainActor`. The spawned `Task { ... }` inherits
  MainActor isolation; the `for try await event in serviceClient.events()`
  loop runs on main, and per-event `await MainActor.run` is a redundant
  trampoline. Under high event volume (rescan emits dozens of
  `watcher_indexed` events) each event competes with UI redraws.
- Fix: use `Task.detached` for the pump, keep the inner `MainActor.run`
  only around the actual `serviceStatusStore.apply` write.

**`UnixSocketEngramServiceTransport` is `@unchecked Sendable` but has only
`let` Sendable state — annotation is gratuitous**
`macos/Shared/Service/UnixSocketEngramServiceTransport.swift:1-21`
- The class holds only `let socketPath: String` and
  `let connectTimeout: TimeInterval`; both Sendable. All I/O is in
  `static func`. Compiler would verify plain `Sendable` conformance. The
  unchecked annotation is over-broad license; `FdBox:442` legitimately
  needs it.
- Fix: drop `@unchecked Sendable` on the transport; keep it on `FdBox`.

### Low

**`DataSourceRow` round-trips UserDefaults on every Sources tab visit**
`macos/Engram/Views/Settings/SourcesSettingsSection.swift:76-108`
- `onAppear` reads UserDefaults into `@State path`; the assignment
  triggers `onChange(of: path) { savePath(newValue) }`, which re-writes
  the same value. Theoretical data-loss risk if a custom path matches
  `defaultPath`.
- Fix: same `isLoading` guard pattern.

**`MainWindowView.navigateToSession` has no in-flight dedup**
`macos/Engram/Views/MainWindowView.swift:31-35, 102-112`
- `.onReceive(.openSession)` synchronously sets `selectedSession`;
  `navigateToSession` (palette path) starts a detached
  `db.getSession(id:)` and writes `selectedSession` async. Double-tap can
  leave the wrong session selected.
- Fix: track `pendingNavigationId` and ignore writes that don't match.

**`TimelinePageView.formatDateLabel` allocates a `DateFormatter` per call**
`macos/Engram/Views/Pages/TimelinePageView.swift:117-126`
- `TimelineView:192-203` uses a static formatter (the consistent pattern);
  the page view rebuilds one per call.
- Fix: hoist to `private static let`.

**`SearchView` local fallback path silently drops any
source/project/since filters that the service path would have applied**
`macos/Engram/Views/SearchView.swift:292-302`
- The view itself doesn't expose those filters today, but the signature
  diverges from `SearchPageView:433-439`. If the view ever surfaces
  filters, online/offline results diverge.
- Fix: thread the same filter set through both paths.

**`SessionDetailView.task(id: session.id)` does not reset `displayIndexed`
/ `displayVersion` at the start of the reset block**
`macos/Engram/Views/SessionDetailView.swift:405-442`
- Stale `displayIndexed` from the prior session persists for one render
  frame on switch — visible flash before the first page loads.
- Fix: add `displayIndexed = []; displayVersion &+= 1` to the reset block.

**`SegmentedMessageView.segments` parses markdown synchronously inside
`body` on cache miss**
`macos/Engram/Views/ContentSegmentViews.swift:60-110`
- A+/A− font-size changes invalidate the view; on cold cache the parse
  runs on MainActor. Bounded by `NSCache.countLimit = 200`.
- Fix: pre-parse on `.task(id: content)` into a `@State` array.

**`MessageParser.blockingAdapterMessages` uses `DispatchSemaphore.wait()`
inside async — safe today, deadlock trap if any caller invokes from
MainActor without the detached trampoline**
`macos/Engram/Core/MessageParser.swift:136-176`
- Currently every call site wraps in `Task.detached`. The
  semaphore-in-async pattern is a known footgun (SE-0297).
- Fix: make `parseWindowed` itself `async` with a
  `for try await message in stream` loop; drop the `Box` + semaphore.

**`AppDelegate.applicationWillTerminate` fires `Task.detached` to close
the client and returns synchronously**
`macos/Engram/App.swift:204-210`
- `close()` is a no-op today, so latent. Adding any real work to
  `close()` would make it disappear on quit.
- Fix: make `EngramServiceClient.close()` synchronous (it has no async
  work); drop the detached task.

**`MenuBarController` mixes `DispatchQueue.main.async` and
`Task { @MainActor in }` for the same kind of trampoline work**
`macos/Engram/MenuBarController.swift:78-82, 95-103, 122-128, 172-174,
185-188`
- Both compile; the dual idiom is leftover from pre-concurrency migration.
- Fix: standardize on `Task { @MainActor in }`. Same for
  `Theme.swift:162-169`.

**`LiveSessionCard.elapsedText` and `ReplayState.densityBuckets` allocate
an `ISO8601DateFormatter` per body / call**
`macos/Engram/Components/LiveSessionCard.swift:25-35`,
`macos/Engram/Models/ReplayState.swift:57-87`
- The rest of the codebase uses `private static let` formatters.
- Fix: hoist to static.

---

## Round 5 — Security & test/observability coverage gaps

Experts: `security_expert` + `tests_observability_expert`. Brief adjusted
to look for the "verified at file:line, but no regression test locks it
in" gap across all four prior rounds, plus security surface not covered
before (redaction, TOCTOU on FsOps leaf, DoS via unbounded inputs).

### High

**`EngramServiceCommandHandler+ProjectMigration` has zero `ServiceLogger`
calls**
`macos/EngramService/Core/EngramServiceCommandHandler+ProjectMigration.swift`
(verified: `grep -c ServiceLogger` returns 0 across the entire file)
- The four IPC entry points (`projectMove`, `projectArchive`,
  `projectUndo`, `projectMoveBatch`) are the most consequential mutating
  commands in the product. None log on success or failure paths.
  `ProjectMoveOrchestrator.run` also has zero logging. Failures surface
  only via the error envelope to the caller; the service's own `os_log`
  subsystem (`com.engram.service`) is empty for this entire code path.
- Impact: when a user reports "project-move failed", no service-side
  breadcrumb exists for triage. The migration_log table is the only
  diagnostic artifact, and the rollback compensation path silently
  swallows DB errors via `try? writer.write { try? failMigration }`.
- Fix: `ServiceLogger.notice` at every public entry (actor, src, dst,
  dryRun, archived, rolledBackOf). `ServiceLogger.error` in the catch
  around the orchestrator. Phase-boundary notices in
  `ProjectMoveOrchestrator.run` (`startMigration`, `markFsDone`,
  `applyMigrationDb`).

**No regression test for the cwd / message_count clobber found in
Round 2**
- `SessionSnapshotClassificationTests` covers `tier` / `agent_role` /
  `parent_session_id` re-index preservation. The sibling `cwd`,
  `message_count`, and per-role sub-count fields share the same upsert
  block and the same data-loss surface but are not asserted.
- Fix: add `testReindexPreservesCwdAndMessageCount` — write a snapshot
  with cwd='/work/engram' and messageCount=4, then re-index with cwd=''
  and messageCount=0; assert preserved. Drives the Round 2 COALESCE fix.

### Medium

**`TranscriptExportService` does not symlink-check the leaf output file**
`macos/EngramService/Core/TranscriptExportService.swift:34-41, 97-113`
- `rejectSymlinkAncestors` walks the ancestor chain but never `lstat`s
  the output file itself. A symlink pre-placed at the export target path
  is followed; `content.write(to: outputURL, atomically: true)` writes
  through the symlink. Same-uid escalation only, but defence-in-depth
  gap.
- Fix: before `content.write`, `lstat` the leaf and refuse `S_IFLNK`.
  Equivalent to `O_NOFOLLOW`.

**`MigrationLogStore.startMigration` stores unbounded `audit_note`**
`macos/EngramCoreWrite/ProjectMove/MigrationLogStore.swift:126-157`
- The `audit_note` column is bound from caller-supplied input with no
  length cap. Compare to `error` on the same table, capped at 2000 chars
  in `failMigration`. A misbehaving same-uid client can grow
  `index.sqlite` unboundedly. Persists across restarts.
- Fix: truncate at the IPC boundary in
  `EngramServiceCommandHandler+ProjectMigration` and defensively again in
  `startMigration`.

**LLM error envelope embeds first 300 bytes of upstream response body**
`macos/EngramService/Core/EngramServiceCommandHandler.swift:1658-1675`
- On a non-2xx LLM response, the truncated body is interpolated into the
  `commandFailed` message and surfaced to the IPC caller and indirectly
  to `ServiceLogger.error`. If a proxy mirrors `Authorization` headers in
  its error body, or a user-supplied prompt fragment includes a secret,
  the secret reaches the same-uid caller and the unified log.
- Fix: return a generic message (`AI request failed with status N`). Put
  any body excerpt only in a `details` field that the service does not
  echo to `os_log`.

**Source adapters follow symlinks during discovery; web UI then reads
through them**
`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:10-13`
(and similar in ClaudeCode/Copilot/Cline/GeminiCli)
- `JSONLAdapterSupport.isDirectory` uses
  `FileManager.fileExists(atPath:isDirectory:)`, which follows symlinks.
  A symlink planted in a source root is recursed into; the resulting
  `readable_path` is stored in `sessions.file_path` and later opened by
  `EngramWebUIServer.readMessages`. Same-uid writer of the source root
  required, but the web UI transcript view surfaces file content the
  user did not intend to expose there.
- Fix: lstat-based `isDirectory` checks during discovery; refuse
  `readablePath` whose standardized form resolves outside the per-source
  allow-list.

**`SwiftIndexer` logs raw user-controlled locator paths at `.public`
privacy**
`macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:130, 147` (verified
via grep)
- `locator=\(locator, privacy: .public)` puts absolute paths
  (`/Users/<name>/-Code-/engram/...`) into the unified log subsystem
  `com.engram.service`. Anything with Full Disk Access can read these
  via `log show --predicate`. Same pattern in `IndexJobRunner`.
  `redactedHost(config.baseURL)` already exists for LLM URLs.
- Fix: log `locator.lastPathComponent` or mark the substitution
  `privacy: .private(mask: .hash)`.

**iFlow lossy encoder has no test asserting the documented collision
behavior**
`macos/EngramCoreTests/ProjectMove/SessionSourcesTests.swift:83-97`
- `testEncodeIflowStripsLeadingTrailingDashesPerSegment` covers the
  strip-dashes behavior. The docstring's "lossy by design" / collision
  invariant is not asserted. An Orchestrator test for the pre-flight is
  also missing (Gemini's is the only one exercised).
- Fix: `testEncodeIflowCollidesForLeadingTrailingDashes` asserting
  `encodeIflow("/a/-foo-/p") == encodeIflow("/a/foo/p")`, plus an
  Orchestrator test that exercises the iFlow pre-flight probe (depends
  on the Round 3 fix).

**`MigrationLock` TTL gap has no regression test**
`macos/EngramCoreTests/ProjectMove/MigrationLockTests.swift:78-99`
- Covers stale-PID and corrupt-JSON. No test for live-but-age-stale
  holder.
- Fix: `testAcquireBreaksStaleLockOlderThanTTL` (depends on Round 3 TTL
  fix).

**Legacy `SearchView` race not covered by `ViewMainThreadReadTests`**
- Round 4 finding: `SearchView.performSearch` lacks the
  `Task.isCancelled`-after-await guards that `SearchPageView` has and
  that `ViewMainThreadReadTests.testSearchPageGuardsAgainstStaleResponses`
  locks in. The static-text guard only inspects `SearchPageView`. Verify
  whether the legacy view is still reachable in the shipped product
  (`grep -rn 'SearchView(' macos/Engram/`); either extend the test or
  delete the view.

**`ServiceWriterGateTests.testSemaphoreReleasesPermitWhenWaiterCancelledAfterSignal`
is timing-tolerant**
`macos/EngramServiceCoreTests/ServiceWriterGateTests.swift:235-266`
- 2000-round race-window test with a 200ms `wait(timeoutNanoseconds:)`.
  On a busy CI host a real release can time out; on a fast host the race
  window the test claims to exercise can be missed.
- Fix: reduce iteration count to 200, raise the timeout to 1s, replace
  `while waiterCount == 0 { yield }` with a deterministic continuation
  barrier.

**`DatabaseManager` nonisolated contract has only a source-text test
guard**
`macos/EngramTests/ViewMainThreadReadTests.swift` + Round 4 finding
- The test asserts `Task.detached` appears in 7 view files via regex.
  Doesn't compile and exercise the actual capture; doesn't cover the
  10+ other view call sites; doesn't verify every read method consumed
  is `nonisolated`.
- Fix: instantiate views, fire `readInBackground` from `Task.detached`,
  assert `!Thread.isMainThread` inside the closure. Add a unit test that
  reflects `DatabaseManager`'s public surface and asserts every consumed
  read method is `nonisolated`.

### Low

**`isLoopbackHost` port-validation skipped when Host has > 1 colons**
`macos/EngramService/Core/EngramWebUIServer.swift:168-181`
- Splits Host on ':' and enforces port only when `trailing.count == 1`.
  A Host header like `127.0.0.1:8080.attacker.com` slips the port check.
  The hostname check still applies, so no data exposure today.
- Fix: take the last segment as the candidate port; reject any Host
  shape that does not strictly match `host` or `host:port`.

**`JsonlPatch.patchFile` does not lstat the source before rename**
`macos/EngramCoreWrite/ProjectMove/JsonlPatch.swift:176-221`
- When `filePath` is a symlink, the rename atomically replaces the
  symlink with the patched content. Same-uid writer required; destructive
  to the user's link.
- Fix: lstat first; refuse symlink sources. Mirror the existing top-level
  `FsOps.isSymlink` check at the file-walk level.

**`redactSensitiveContent` regex set is narrow**
`macos/EngramService/Core/TranscriptExportService.swift:177-193`
- Misses PEM private-key blocks, `github_pat_…`, `xoxe-…`, `npm_…`,
  `AKIA[0-9A-Z]{16}`, fine-grained GH tokens. Used by both export and
  web UI.
- Fix: extend regex set; consider adopting a maintained list (gitleaks
  rules) so the surface stays up to date.

**`linkSessions` symlink-swap has a TOCTOU window**
`macos/EngramService/Core/EngramServiceCommandHandler.swift:1015-1047`
- `destinationOfSymbolicLink` → `removeItem` → `createSymbolicLink`. An
  attacker swapping `linkPath` from a symlink to a regular file (or
  directory) between the read and the remove can DoS user content.
  Same-uid attacker only.
- Fix: post-remove `lstat` and assert ENOENT; use
  `open(O_NOFOLLOW | O_EXCL | O_CREAT, 0600)` + rename.

**`migration_log` retains user paths in plaintext (relies on 0600 mode)**
`macos/EngramCoreWrite/Database/EngramMigrations.swift:125-149`
- The table stores `old_path`, `new_path`, `audit_note`, and
  per-migration `error` in plaintext. Protected by
  `SQLiteFileSecurity.secureDatabaseFiles` (0600). Becomes a finding if
  any future change weakens the file-mode hardening or omits the
  WAL/SHM siblings.
- Fix: add a startup assertion that DB / WAL / SHM are all 0600 and
  owned by the current uid. Document the sensitivity class.

**Stale `DaemonClient` references in tests**
`macos/EngramTests/EngramServiceLauncherTests.swift:20-27, 66-70`,
`macos/EngramTests/AppSearchServiceCutoverScanTests.swift:99-413`,
`macos/EngramTests/CascadeClientTests.swift:1-130`
- The Node daemon was removed; tests still assert its absence (negative
  guards, correct). `CascadeClientTests` is 130 lines that always
  `XCTSkip` against a removed service.
- Fix: delete or move `CascadeClientTests` under a legacy/ marker;
  convert negative DaemonClient guards into positive assertions on the
  new launch shape.

**`ServiceLogCategory` declares `.ipc`, `.writer`, `.reader` that no
production code uses**
`macos/EngramService/Core/ServiceLogger.swift:5-11`
- Six categories defined; only `.runner`, `.checkpoint`, `.ai` are
  emitted. An operator filtering `category=writer` gets zero hits and
  concludes the writer path is silent (it is — just not categorized that
  way).
- Fix: backfill real log calls in `UnixSocketServiceServer`,
  `ServiceWriterGate`, `EngramServiceReadProvider` (preferred — Round 5
  observability finding wants more logging, not less), or delete the
  unused cases.

**`runObservabilityRetention` is silent on 0-row passes**
`macos/EngramService/Core/EngramServiceRunner.swift:257-274`
- Only emits a notice when `total > 0`. A successful no-op leaves no
  positive trace. `readWebUIEnabled` similarly only logs the disabled
  case.
- Fix: log at `debug` or `info` regardless of count; log the effective
  web-UI decision and its source (env vs settings.json).

**`EngramServiceIPCTests` leaves `$HOME` artifacts on assertion failure**
`macos/EngramServiceCoreTests/EngramServiceIPCTests.swift:1778-1830`
- The "in-home but absent src" test creates `$HOME/.engram-test-
  missing-src-<uuid>` and `-dst-<uuid>`. The `defer` only stops the
  server; if `XCTFail` fires before the cleanup line, the real `$HOME`
  accumulates orphan dirs.
- Fix: use `FileManager.default.temporaryDirectory` with the UUID, OR
  add `defer { try? FileManager.default.removeItem(...) }` for src and
  dst.

---

## Verification methodology

Every finding above survives the following:

1. **Source verification**: file:line opened and read; the cited
   condition is present in the current `perf/transcript-paging` branch
   HEAD.
2. **Counter-evidence sweep**: a second pass looking for guards,
   retries, call-site mitigations, or test coverage that would
   invalidate the finding.
3. **Prior-art deduplication**: every finding was cross-checked against
   `docs/reviews/2026-06-02-macos-swift-product-code-review.md`; only items not already recorded are
   kept.

One candidate finding was rejected at this gate (`SearchView`
mode-toggle "cosmetic" claim), proving the verification step is
load-bearing rather than a rubber stamp.

## Counts

- High: 6 (1 iFlow encoder collision, 1 SearchView ghost-results, 1
  DatabaseManager @MainActor structural, 1 ProjectMigration zero
  ServiceLogger, 1 cwd-clobber regression-test gap, 1 paired with
  Round 5 observability).
- Medium: 22 (across all five rounds).
- Low: 23 (across all five rounds).
- Total: 51 verified findings + 1 rejected candidate.

## What this audit does NOT cover

- Performance regression measurements (no benchmarking was run).
- The TypeScript reference layer in `src/` — out of scope per CLAUDE.md;
  reviewed in prior revisions and retained as development/regression
  material.
- The `EngramMCP` stdio helper — only consulted indirectly via the
  shared IPC transport.
- Cross-platform behavior — macOS only.
