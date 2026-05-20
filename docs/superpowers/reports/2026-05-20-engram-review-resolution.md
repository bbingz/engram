# Engram Review Findings Resolution - 2026-05-20

Scope: closeout evidence for `docs/superpowers/reports/2026-05-20-engram-review-findings.md`.

Status: all 27 findings from the review report are resolved in the current remediation branch. Items that were intentionally narrowed, such as peer sync and Project Aliases UI, are resolved by removing the product promise and adding scan tests that prevent the unsupported UI from being presented as working.

## Resolution Matrix

| # | Finding | Resolution evidence |
|---|---|---|
| 1 | Codex adapter drops real user intent after injected instructions | `macos/EngramCoreTests/IndexerParityTests.swift` includes `testCodexSessionWithAgentInstructionsAndRealUserTaskIsNotSkipped`; Swift indexing preserves the real task. |
| 2 | FTS and embedding jobs can remain stale after content changes | `IndexerParityTests` covers same-version content hash changes and distinct index jobs. |
| 3 | Downgraded `skip` sessions can leak through old FTS | `testDowngradingSessionToSkipDeletesStaleSearchArtifacts` covers cleanup, and service search filters `skip`/`lite`. |
| 4 | Swift read provider opens a new SQLite queue per read | `SQLiteEngramServiceReadProvider` owns a persistent `ServiceDatabaseReading`; `EngramServiceIPCTests` includes `testSQLiteReadProviderReusesOpenedReaderAcrossRepeatedReads`. |
| 5 | Unix socket server lifecycle has unchecked mutable state | `UnixSocketServiceServer` uses lock-protected state and tracked client tasks; IPC tests cover lifecycle, concurrent clients, and cancellation. |
| 6 | Writer gate semaphore ignores cancellation | `ServiceAsyncSemaphore.wait()` uses cancellation handlers and post-acquire `Task.checkCancellation()`. |
| 7 | Service runner cancellation can skip cleanup | `EngramServiceRunner.run` uses `defer` to cancel background tasks and stop the server; IPC tests verify runner cancellation releases locks. |
| 8 | Supply-chain audit has critical/high vulnerabilities | `npm audit --json` reports zero vulnerabilities. |
| 9 | Sensitive local files are too broadly readable | Node config and DB paths chmod to `0600`; Swift settings tests cover secure writes; local `~/.engram/settings.json` and `~/.engram/index.sqlite` are `0600`. |
| 10 | Node v26 is allowed but local runtime is broken | `package.json` now limits engines to `>=22 <27`, `better-sqlite3` is `^12.10.0`, and Node v26 local tests pass. |
| 11 | Sync is advertised but service returns stub failure | README and Swift single-stack docs mark peer sync unsupported; App settings no longer exposes a working Sync Now action. |
| 12 | `triggerSync` no-op goes through writer gate | `EngramServiceCommandHandler` returns unsupported `triggerSync` directly outside `performWriteCommand`, so no generation bump is emitted. |
| 13 | README claims Project Aliases settings UI exists | README now documents MCP/Web API management and states the macOS App has no Project Aliases UI yet. |
| 14 | Web UI readiness can be misreported | App does not preset endpoint readiness; service emits `web_ready` only after `/health` succeeds. Scan tests cover both sides. |
| 15 | Popover reports MCP status from service status only | Popover label/accessibility now use `Service` for `serviceStatusStore.isRunning`; scan test prevents MCP-helper mislabeling. |
| 16 | MCP tool gaps: `delete_insight` and `hide_session` | Node and Swift MCP registries expose both tools; Swift MCP tests cover service-backed success and service-unavailable fail-closed behavior. |
| 17 | `knip` coverage too narrow and fails | `knip.json` includes the real entry points and scripts; CI uses `npm run knip`; `npm run knip` passes. |
| 18 | Test typecheck exists but is not a gate | `package.json` has `typecheck:test`; CI runs it; `npm run typecheck:test` passes. |
| 19 | Viking artifacts and static credentials remain active | Active scripts were removed or archived behind `VIKING_BASE`/`VIKING_TOKEN`; `tests/tooling/no-static-viking-creds.test.ts` enforces no static endpoint/token. |
| 20 | `sqlite-vec` pinned to older alpha | `package.json` uses `sqlite-vec` `0.1.9`; `tests/core/vector-store.test.ts` covers the evaluated capability baseline. |
| 21 | `web.ts` input validation gaps | Web/project API tests cover NaN query handling, and shared route code rejects invalid numeric params. |
| 22 | Node maintenance N+1/sync-I/O hotspots | `backfillSuggestedParents` loads parent candidates once per batch; `backfillCodexOriginator` and `LiveSessionMonitor` use async fs paths; tests scan against sync fs APIs and count parent lookup calls. |
| 23 | `web.ts` monolith maintainability debt | Low-coupling routes have been split under `src/web/routes/` for AI audit, project aliases, search, sessions, stats, and sync; `src/web.ts` is no longer the 2000+ line all-in-one route owner described by the report. |
| 24 | Documentation stale | README, `docs/mcp-swift.md`, and `docs/swift-single-stack/daemon-client-map.md` now describe Swift service/Unix socket reality, unsupported sync, and drift-free test commands. |
| 25 | Localized UI paths bypass string catalogs | Menu titles use `String(localized:)` / `Screen.localizedTitle`; AI settings statuses use enum-backed localized state models; scan tests cover both. |
| 26 | Project Alias Settings UI promise | Resolved by removing the App UI promise from README and documenting current MCP/Web API paths. |
| 27 | HTTP transcript rendering diverges from Swift | Swift HTTP transcript, Swift App/MCP/export paths now share the same visible-message contract: only non-empty `user` / `assistant` transcript body rows are returned. Tests cover Command Code tool rows, whitespace-only assistant rows, and Antigravity legacy-source reads. |

## Provider Parser Final Pass

Antigravity CLI, Command Code, and Qoder received the final focused provider pass. Antigravity CLI is covered as the new provider under `~/.gemini/antigravity-cli/brain/` with legacy `antigravity-legacy` source mapping. Command Code covers both `tool-call.input` and `tool-call.args`. Qoder covers nested subagent parent detection while avoiding false parent IDs for project-level `subagents/` folders.

HTTP/API display was checked against Swift behavior: Swift HTTP transcript endpoints, MCP `get_session`, export, and the App-facing parser all filter to non-empty `user` / `assistant` visible transcript messages. Tool/event/system-like rows remain available for indexing and diagnostics, but do not render as normal transcript content.

Two Polycli review rounds were run. The second round produced three actionable fixes after the initial implementation: Qoder parent detection outside `/Users`, blank/whitespace transcript filtering in MCP/export, and blank assistant indexing stats/noop cost metadata refresh. These fixes are covered by new Swift and TypeScript regressions.

## Verification Commands

The following gates were run from the remediation worktree during closeout:

```bash
npm install
npm run knip
npm run typecheck:test
npm test -- tests/core/db/parent-link-repo.test.ts tests/core/live-sessions.test.ts tests/web/server.test.ts tests/web/project-api.test.ts
npm audit --json
```

The final shipping pass on the remediation branch also ran:

```bash
bash -n macos/scripts/build-release.sh
npm run typecheck:test
npm run knip
npm run check:adapter-parity-fixtures
npm test -- tests/adapters/antigravity.test.ts tests/adapters/commandcode.test.ts tests/adapters/qoder.test.ts tests/scripts/stage2-fixture-generators.test.ts tests/web/api.test.ts tests/web/server.test.ts
npm test
npm run build
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/AdapterParityTests CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-provider-core-round1fix
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' -only-testing:EngramMCPTests/EngramMCPExecutableTests/testSourceSchemasCoverEveryKnownProvider CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-mcp-source-schema-round1fix
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testExportSessionFiltersToolMessagesLikeSwiftDisplay -only-testing:EngramServiceCoreTests/EngramWebUIServerTests/testTranscriptDisplayFiltersToolMessagesLikeSwiftApp CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-final-service
macos/scripts/build-release.sh
```

`macos/scripts/build-release.sh` archived successfully, hit the expected local Developer ID export-method error on this machine, fell back to the archived signed app, and verified the exported app before reporting success.
