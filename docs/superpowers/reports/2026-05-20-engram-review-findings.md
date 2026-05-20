# Engram Full Review Findings - 2026-05-20

Scope: read-only review of the current checkout at `/Users/bing/-Code-/engram`.

Input sources:
- Codex review with 5 specialist subagents: Swift runtime, data/indexing, macOS UI, Node/TS tooling, docs/product promises.
- Local cross-checks by Codex.
- Gemini's revised `/Users/bing/.gemini/antigravity-cli/brain/01ac5741-287a-4776-bd89-9efb6fc7063c/implementation_plan.md`, treated as leads and re-verified before inclusion.

Repository state at review time:
- `main...origin/main [ahead 603, behind 34]`.
- Dirty worktree before this report was written, including Swift app/service files, `src/web.ts`, tests, and untracked `.antigravitycli/`, `EngramDatabaseIndexer.swift`, `EngramWebUIServer.swift`, and `SessionAdapterFactory.swift`.
- This report is the only intended file write from the Codex follow-up.

## Executive Summary

No P0 issue was confirmed. The highest-value fixes are not broad refactors; they are correctness and verification blockers:

1. Swift indexing can lose real Codex user tasks when AGENTS/system-injection text appears in the same user message.
2. FTS/embedding jobs can stay stale after content hash changes or after a session is downgraded to `skip`.
3. Swift service read paths repeatedly create SQLite connections instead of reusing a persistent reader/pool.
4. IPC lifecycle and writer-gate cancellation have real concurrency/lifecycle risks.
5. Local Node verification is currently unreliable under Node v26 because of native `better-sqlite3` binding mismatch.
6. `npm audit` currently reports 8 vulnerabilities, including critical `protobufjs`.
7. Local `~/.engram/settings.json` and `~/.engram/index.sqlite` are mode `0644` on this machine.

## P1 - Fix First

### 1. Codex adapter drops real user intent after injected instructions

Evidence:
- `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:193`
- `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:127`
- `macos/EngramCoreTests/IndexerParityTests.swift:383`

Finding:
The Codex parser treats a user message containing `<INSTRUCTIONS>` as system content. In current Codex sessions, AGENTS/instructions and the real user task can appear in the same message. The indexer then skips that message, so single-turn sessions can end up with `userMessageCount = 0`, `summary = nil`, `tier = skip`, and no useful search/embedding payload.

Impact:
Real user work can disappear from Engram search/context, especially for sessions that start with AGENTS.md injection followed by the actual task.

Recommended fix:
Strip only the injected instruction/environment prefix and preserve the actual user task. Add a real Codex JSONL fixture with AGENTS text plus a real prompt, then assert `userMessageCount > 0`, `summary` contains the prompt, and `tier != skip`.

### 2. FTS and embedding jobs can remain stale after content changes

Evidence:
- `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:87`
- `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:258`
- `src/core/index-job-runner.ts:54`

Finding:
Swift writer can merge a changed snapshot under the same `syncVersion`, but index job ids only include `sessionId:syncVersion:jobKind`. Existing TS job runner logic treats already-present FTS as complete. A local file can change while `syncVersion` remains `1`, leaving search/embedding tied to old content.

Impact:
Search can return stale content even when the `sessions` row has been updated.

Recommended fix:
Include `snapshotHash` or equivalent content version in the job target, or increment local target version on content hash changes. Add a regression test: index "old", update same session/version to "new", run jobs, assert FTS contains "new" and not "old".

### 3. Downgraded `skip` sessions can still leak through old FTS

Evidence:
- `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:98`
- `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:267`
- `macos/EngramService/Core/EngramServiceReadProvider.swift:332`

Finding:
When a session is downgraded from normal/premium to `skip`, writer state changes but no FTS/embedding cleanup job is scheduled. Swift search filters `hidden_at` but not `tier = 'skip'`.

Impact:
Noise sessions that were intentionally downgraded can still appear in search from stale FTS rows.

Recommended fix:
On normal/premium -> skip, delete FTS and embedding rows. Also filter skip/lite in search as defense in depth. Add regression coverage for a normal session that becomes skip.

### 4. Swift service read provider opens a new SQLite queue per read

Evidence:
- `macos/EngramService/Core/EngramServiceReadProvider.swift:547`
- Existing reusable reader: `macos/EngramCoreRead/Database/EngramDatabaseReader.swift:4`
- Existing reader policy: `macos/EngramCoreRead/Database/SQLiteConnectionPolicy.swift:27`

Finding:
`SQLiteEngramServiceReadProvider.read` creates a new `DatabaseQueue` for each request and only sets `busy_timeout`, instead of using a persistent reader/pool and the shared connection policy.

Impact:
High-frequency status/search/source/embedding reads repeatedly open SQLite connections and miss shared pager/cache and policy behavior.

Recommended fix:
Initialize the provider with a persistent `DatabasePool` or `EngramDatabaseReader`. Reuse `SQLiteConnectionPolicy.readerConfiguration()`. Add a test seam to verify repeated reads do not rebuild the reader.

### 5. Unix socket server lifecycle uses unchecked shared mutable state

Evidence:
- `macos/EngramService/IPC/UnixSocketServiceServer.swift:4`
- Mutable state: `macos/EngramService/IPC/UnixSocketServiceServer.swift:13`
- Detached accept/client tasks: `macos/EngramService/IPC/UnixSocketServiceServer.swift:28`
- Stop path: `macos/EngramService/IPC/UnixSocketServiceServer.swift:64`

Finding:
`UnixSocketServiceServer` is `@unchecked Sendable` while `fd` and `acceptTask` are plain mutable vars. `start`, `stop`, and `deinit` are not actor/lock isolated. Client tasks are detached and not tracked.

Impact:
Concurrent start/stop/restart can race on fd close, accept loop state, socket unlink, and task lifetime.

Recommended fix:
Put lifecycle state in an actor or explicit lock-protected state machine. Track client tasks and cancel/wait on shutdown. Add concurrent start/stop/restart IPC tests.

### 6. Writer gate semaphore ignores cancellation

Evidence:
- `macos/EngramService/Core/ServiceWriterGate.swift:65`
- `macos/EngramService/Core/ServiceWriterGate.swift:146`
- `macos/EngramService/Core/ServiceWriterGate.swift:157`

Finding:
The custom semaphore stores continuations without a cancellation handler. A request cancelled while waiting can later receive a permit and execute its write.

Impact:
Timed-out or cancelled App/MCP mutations may still run later.

Recommended fix:
Make the semaphore cancellation-aware, remove cancelled waiters, and call `Task.checkCancellation()` after acquiring a permit.

### 7. Service runner cancellation can skip cleanup

Evidence:
- `macos/EngramService/Core/EngramServiceRunner.swift:136`
- Cleanup after loop: `macos/EngramService/Core/EngramServiceRunner.swift:143`

Finding:
The main sleep loop can throw `CancellationError`, but cleanup is after the loop instead of in `defer`.

Impact:
Task-level cancellation can skip `server.stop()`, web/indexing task cancellation, and checkpoint cleanup.

Recommended fix:
Wrap service startup resources in `defer` cleanup and make cancellation fall through the normal shutdown path.

### 8. Supply-chain audit currently has critical/high vulnerabilities

Evidence:
- `npm audit --json` reported 8 vulnerabilities: 1 critical, 1 high, 6 moderate.
- `package-lock.json:6153` pins `protobufjs` to `7.5.4`.
- `npm audit` reports `protobufjs` critical arbitrary code execution for `<7.5.5`, plus additional protobufjs advisories up to `<=7.5.7`.
- `package.json:37` uses `hono` `^4.12.4`; audit reports multiple Hono advisories fixed by newer 4.12.x releases.

Impact:
Node dev/reference tooling and retained web/API code depend on vulnerable packages. Even if not shipped as the main runtime, this blocks safe local tooling and CI.

Recommended fix:
Do not blindly run `npm audit fix` in the dirty tree. In a clean branch, update `protobufjs` to a safe version beyond all current audit ranges, update `hono` at least past `4.12.18`, refresh lockfile, then rerun `npm audit --json`, `npm run build`, and relevant tests under a supported Node version.

### 9. Sensitive local files are too broadly readable on this machine

Evidence:
- `stat` output at review time:
  - `/Users/bing/.engram`: `drwx------`
  - `/Users/bing/.engram/settings.json`: `-rw-r--r--`
  - `/Users/bing/.engram/index.sqlite`: `-rw-r--r--`
- Node settings writer: `src/core/config.ts:309`
- Swift settings writer: `macos/Engram/Views/Settings/SettingsIO.swift:91`, `macos/Engram/Views/Settings/SettingsIO.swift:113`, `macos/Engram/Views/Settings/SettingsIO.swift:147`
- Runtime directory hardening only covers `~/.engram` and `~/.engram/run`: `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:97`

Finding:
The parent directory is `0700`, which prevents traversal by other local users in the normal case, but the files themselves are still created/written as `0644`. If the directory mode regresses, files are directly readable. Debug/ad-hoc builds can store plaintext settings fallback when Keychain is skipped.

Impact:
API key sentinels/plaintext fallback, settings, and indexed session metadata have weaker file modes than expected for local sensitive data.

Recommended fix:
Ensure settings and DB files are created/written `0600` from both Swift and Node paths. Add startup repair/warning for broader modes. Keep the existing `0700` directory repair.

### 10. Node v26 is allowed by `engines` but local test runtime is broken

Evidence:
- `package.json:6` allows `node >=20`.
- Tooling review ran under Node v26 and `npm test` failed because `better-sqlite3` native binding for `node-v147-darwin-arm64` was not present.
- `package-lock.json` contains `better-sqlite3@11.10.0`.

Impact:
The current declared engine range allows a runtime where local tests/dev scripts fail before product behavior is tested. CI pins Node 20, so it does not catch this.

Recommended fix:
Short term: add `.nvmrc`/Volta and narrow engines to verified Node LTS. Medium term: upgrade `better-sqlite3` and add Node 22/current-LTS matrix coverage.

## P2 - Next

### 11. Sync is advertised and wired to UI but Swift service returns a stub failure

Evidence:
- README promises sync: `README.md:279`
- Settings exposes sync and `Sync Now`: `macos/Engram/Views/Settings/NetworkSettingsSection.swift:205`
- Swift service returns `"Sync is not implemented in the Swift service"`: `macos/EngramService/Core/EngramServiceCommandHandler.swift:537`
- IPC tests currently assert this failure: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift:665`

Impact:
Users can enable sync and click `Sync Now`, but the only real outcome is failure.

Recommended fix:
Either port sync to Swift and add behavior tests, or mark it unsupported/experimental in README and disable/hide the action in UI.

### 12. `triggerSync` no-op still goes through the writer gate

Evidence:
- `macos/EngramService/Core/EngramServiceCommandHandler.swift:156`
- `macos/EngramService/Core/EngramServiceCommandHandler.swift:537`
- `macos/EngramService/Core/ServiceWriterGate.swift:67`

Finding:
`triggerSync` does not write but is routed through `performWriteCommand`, which increments database generation for successful operations.

Impact:
Failed no-op sync can produce a misleading generation change.

Recommended fix:
Return unsupported sync status outside the writer gate until real sync writes exist.

### 13. README claims Project Aliases can be managed in macOS Settings, but UI is absent

Evidence:
- README claim: `README.md:255`
- Settings tabs contain no Project Aliases section.
- Service/MCP manage alias exists: `macos/EngramService/Core/EngramServiceCommandHandler.swift:705`, `macos/EngramMCP/Core/MCPToolRegistry.swift:939`

Impact:
User-facing docs point to a nonexistent App UI.

Recommended fix:
Either add a Settings section backed by service calls, or remove the App path from README and document MCP-only management.

### 14. Web UI endpoint readiness can be misreported

Evidence:
- App sets endpoint before real web readiness: `macos/Engram/App.swift:132`
- Service prints `web_ready` before `webServer.run()`: `macos/EngramService/Core/EngramServiceRunner.swift:61`
- Event stream polls status only: `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:36`

Impact:
Menu/popover can show Web UI as available even if bind fails, port conflicts, or server is not ready.

Recommended fix:
Expose real web endpoint/health through service status, or have App probe `/health` before enabling/opening Web UI.

### 15. Popover reports MCP status from service status only

Evidence:
- Popover uses `serviceStatusStore.isRunning` for `MCP`: `macos/Engram/Views/PopoverView.swift:54`
- MCP helper path/executable status is configured elsewhere in Sources settings.

Impact:
Service can be running while MCP helper is broken, but the UI still shows MCP green.

Recommended fix:
Rename the indicator to `Service`, or add a real MCP helper health check.

### 16. MCP tool completeness gaps: `delete_insight` and `hide_session`

Evidence:
- Node MCP tools list includes `save_insight` but no `delete_insight`/`hide_session`: `src/index.ts:127`
- Swift MCP defines `save_insight` but no delete/hide tool: `macos/EngramMCP/Core/MCPToolRegistry.swift:512`
- Underlying delete insight helper already exists: `src/core/db/insight-repo.ts:154`
- Underlying App/service hide session exists: `macos/EngramService/Core/EngramServiceCommandHandler.swift:430`
- Node has destructive `deleteSession`, but not a softer hide-session MCP API: `src/core/db/session-repo.ts:372`

Impact:
AI assistants can add memory/noise but cannot symmetrically remove insights or hide sessions through MCP.

Recommended fix:
Add MCP tools with conservative schemas:
- `delete_insight(id, dry_run?)`
- `hide_session(session_id, hidden = true, dry_run?)`
Route through Swift service where possible and keep direct fallback policy consistent with existing mutating tools.

### 17. `knip` dead-code coverage is too narrow and currently fails

Evidence:
- `knip.json:3` only lists `src/daemon.ts` as entry.
- `package.json:11` has `src/index.ts` as the dev/MCP entry.
- CI runs `npx knip` directly: `.github/workflows/test.yml:37`
- Local `npm run knip` failed with unused CLI files and exports.

Impact:
Dead-code checks can miss real entry points and scripts, or produce confusing findings.

Recommended fix:
Model `src/index.ts`, `src/cli/index.ts`, and intended `scripts/**/*.ts` in `knip.json`. Change CI to `npm run knip` so future script options are honored.

### 18. Test typecheck exists but is not a gate

Evidence:
- Tooling review ran `tsc --noEmit -p tsconfig.test.json` and it failed.
- `package.json` has no `typecheck:test` script.
- CI runs build/test coverage, but not test typecheck.

Impact:
Mocks and fixtures can drift from runtime types while Vitest still transpiles.

Recommended fix:
Fix current test type errors, add `typecheck:test`, and gate it in CI.

### 19. Viking artifacts and static credentials remain in active scripts

Evidence:
- `scripts/viking-quality-test.sh:6` hardcodes `http://10.0.8.9:1933/api/v1`.
- `scripts/viking-quality-test.sh:7` hardcodes bearer token text.
- `scripts/search-audit.sh:15` and `scripts/search-audit.sh:16` do the same.

Impact:
Deprecated external service scripts are easy to run accidentally and expose static internal tokens in repo history/worktree.

Recommended fix:
Delete or move to archive. If retained for historical comparison, require `VIKING_BASE` and `VIKING_TOKEN` env vars and mark as historical.

### 20. `sqlite-vec` is still pinned to an alpha package while newer versions exist

Evidence:
- `package.json:39` pins `sqlite-vec` to `0.1.7-alpha.2`.
- Prior `npm outdated --json` showed latest `0.1.9`.

Impact:
Semantic search depends on an older prerelease native package; loading failure degrades vector features.

Recommended fix:
Evaluate upgrade to stable `0.1.9` with a sqlite-vec load/capability smoke test.

### 21. `web.ts` has real input-validation gaps, but not every parse is unsafe

Evidence:
- Unsafe examples:
  - `/api/ai/audit`: `src/web.ts:450`
  - `/api/ai/audit/:id`: `src/web.ts:473`
  - `/api/sync/sessions`: `src/web.ts:500`
  - `/api/sessions`: `src/web.ts:567`
  - `/api/file-activity`: `src/web.ts:925`
- Some routes already guard NaN, for example `src/web.ts:681` and `src/web.ts:905`.

Impact:
Invalid query params can propagate `NaN` or surprising values into DB calls and API responses.

Recommended fix:
Add shared query parsers such as `parsePositiveIntParam` and `parseOffsetParam`, then replace ad hoc parse sites route by route. This can be done before or during web route splitting.

### 22. Node maintenance code has specific N+1/sync-I/O hotspots

Evidence:
- `backfillSuggestedParents` selects candidates, then queries parent candidates inside the loop: `src/core/db/maintenance.ts:402` and `src/core/db/maintenance.ts:415`.
- `backfillCodexOriginator` uses `openSync/readSync/closeSync` per candidate: `src/core/db/maintenance.ts:345`.
- `LiveSessionMonitor.scan` uses synchronous directory/stat/open/read operations on a periodic timer: `src/core/live-sessions.ts:76`, `src/core/live-sessions.ts:135`, `src/core/live-sessions.ts:153`, `src/core/live-sessions.ts:165`.

Impact:
Retained Node web/API/dev tooling can block the event loop under larger datasets. This is less critical than Swift product-runtime bugs but still blocks reliable reference tooling.

Recommended fix:
Batch parent lookups; use async fs APIs or move heavy scans off the request path; add representative dataset tests/benchmarks before refactoring broadly.

### 23. `web.ts` monolith is maintainability debt, not a first-order bug

Evidence:
- `src/web.ts` is over 2000 lines and mixes API routes, HTML pages, auth, health, settings, sync, project migration, AI, and dev endpoints.

Impact:
The file makes validation/security fixes harder to review and increases regression risk.

Recommended fix:
Split only after correctness fixes above, starting with low-coupling route groups: sync, project aliases, AI audit, stats/analytics, sessions/search.

### 24. Documentation is stale in several places

Evidence:
- README test count says `922 tests`: `README.md:387`; tooling review observed current Vitest discovery around `1279`.
- `docs/mcp-swift.md` still describes older daemon HTTP/Node default paths.
- `docs/swift-single-stack/daemon-client-map.md:53` lists sync status/trigger as service command despite current stub.
- Some project move plan/changelog text still describes missing/stub state after native pipeline landed.

Impact:
Developers and agents will choose wrong troubleshooting paths.

Recommended fix:
Remove fixed test counts, mark sync unsupported until implemented, update MCP Swift docs to Unix-socket Swift service reality, and mark old plans superseded/completed.

## P3 - Polish / Lower Priority

### 25. Some localized UI paths still bypass string catalogs

Evidence:
- Menu titles are raw strings in `macos/Engram/MenuBarController.swift:391`.
- Dynamic statuses in Settings use string state / `Text(verbatim:)`, for example `macos/Engram/Views/Settings/NetworkSettingsSection.swift:142`.

Impact:
Chinese UI can still show English menu/status text.

Recommended fix:
Use localization keys or enum-based localized rendering for menu items and operation statuses.

### 26. Project Alias Settings UI is a product improvement if README promise is kept

Evidence:
- Service and MCP support alias writes, but App Settings has no section.

Impact:
Not a backend blocker if docs are corrected, but a useful UI completion item.

Recommended fix:
Either remove the README promise or add a small Settings section with list/add/remove and service-backed validation.

### 27. HTTP transcript rendering is not aligned with Swift transcript classification

Evidence:
- The legacy TypeScript HTTP session detail view uses a local classifier in `src/web/views.ts`.
- The running macOS App HTTP session detail view is served by `macos/EngramService/Core/EngramWebUIServer.swift`.
- The Swift app uses `macos/Engram/Core/MessageParser.swift`, plus Swift-side message classification and filtering.
- `<subagent_notification>` currently renders in the HTTP view as a normal `You` message, while Swift treats comparable injected/agent metadata as system-like transcript content.
- `src/web/views.ts` also classifies `# AGENTS.md instructions for ...` differently from Swift despite the code comment saying the two classifiers should stay in sync.
- Large active Codex transcripts can exceed `ParserLimits.maxMessages`; `EngramWebUIServer` previously let adapter failures escape as HTTP 500 instead of showing an inline transcript notice.

Impact:
The same session can be readable in the Swift app but noisy or misleading in the HTTP transcript, especially when subagents emit large status payloads.

Recommended fix:
Keep the TypeScript Web, Swift app, and Swift service HTTP system classifiers in parity. Classify `<subagent_notification>` as agent communication, align AGENTS injected instruction classification with Swift, and render adapter parser failures as an inline notice rather than a blank HTTP 500.

## Gemini Revised Findings - Triage

| Gemini claim | Verdict | Notes |
|---|---|---|
| `protobufjs` ACE vulnerability | Confirmed | `npm audit --json` reports critical `protobufjs`; lock has `7.5.4`. |
| DB/settings permissions too broad | Confirmed on this machine | Files are `0644`; parent dir is `0700`, so exploitability is bounded but file modes should still be `0600`. |
| Node N+1 and sync I/O | Partially confirmed | Specific hotspots exist in maintenance/live monitor. Needs benchmark before broad claims. |
| Missing `delete_insight` and `hide_session` MCP tools | Confirmed as MCP surface gap | Underlying delete/hide helpers partly exist; MCP exposure is missing. |
| `web.ts` lacks NaN guards | Partially confirmed | Several unsafe parse sites exist; other routes already guard. |
| `web.ts` should be split | Valid tech debt | Lower priority than correctness/security fixes. |

## Suggested Repair Order

1. Security and verification baseline:
   - Fix audit vulnerabilities in a clean branch.
   - Add Node version pinning and restore local test execution.
   - Repair `0600` file creation for settings and DB.

2. Swift indexing correctness:
   - Fix Codex injected-instructions parsing.
   - Fix stale FTS/embedding job versioning and skip cleanup.
   - Add real fixture regression tests.

3. Swift service lifecycle:
   - Persistent read pool.
   - Unix socket lifecycle isolation.
   - Cancellation-aware writer gate.
   - Runner cleanup via `defer`.

4. User-visible product truth:
   - Disable or implement sync.
   - Fix README Project Alias claim.
   - Fix Web UI readiness and MCP/service status labels.

5. Tooling cleanup:
   - Fix `knip.json` and CI `npm run knip`.
   - Add test typecheck gate.
   - Remove or archive Viking scripts.
   - Evaluate `sqlite-vec` upgrade.

6. Refactor after behavior is stable:
   - Split `web.ts` route groups.
   - Add shared query parsing.
   - Localize remaining menu/status strings.

## Verification Performed During Review

Commands run read-only unless noted:
- `git status --short --branch`
- `git diff --stat`
- `rg` / `nl -ba` / `sed` source inspections
- `npm run knip` (failed with unused files/exports)
- `npm outdated --json`
- `npm audit --json` (failed as expected because vulnerabilities exist)
- `stat -f '%Sp %N' ~/.engram ~/.engram/settings.json ~/.engram/index.sqlite`

Verification reported by subagents:
- `tsc --noEmit -p tsconfig.json`: passed.
- `tsc --noEmit -p tsconfig.test.json`: failed.
- `npm test -- --run --reporter=dot` under Node v26: failed on native `better-sqlite3` binding.

Not run:
- Xcode build/test.
- macOS App UI smoke.
- `npm audit fix`.
- `npm run build` or `npm run test:coverage`, to avoid extra generated output in a dirty tree.
