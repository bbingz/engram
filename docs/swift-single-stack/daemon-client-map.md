# DaemonClient to EngramServiceClient Map

Stage 3 owns this inventory. Stage 4 extends it across App callers and the highest-risk MCP/CLI mutations. Retained compatibility shim files may keep legacy names until Stage 4/5, but production callers must move to the service boundary before cutover.

## Stage 4 Gate

Stage 4 no longer blocks on writer authority. The real IPC gate is green, and app-facing move/archive/undo plus sync/title bulk actions now cross the service boundary first.

Recorded passing IPC gate:

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme EngramServiceCore test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/engram-dd-stage3-ipc -only-testing:EngramServiceCoreTests/EngramServiceIPCTests
```

Recorded result on 2026-04-23:

- `EngramServiceIPCTests.testTwoClientsSerializeWriteIntentThroughOneServiceGate` passed.
- Full selected suite passed with `5 tests, 0 failures` before Stage 4 routing continued.
- `EngramServiceClientTests` passed with `7 tests, 0 failures`.
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram build ...`
  succeeded after the App UI surfaces moved to `EngramServiceClient`.

Decision values:

- `service command`: route through `EngramServiceClient` and, for writes, through `ServiceWriterGate`.
- `read repository`: app/MCP can read through `EngramCoreRead` or existing read-only facades.
- `Stage 4 MCP/CLI`: route through service when backed; otherwise fail closed or stay on existing read-only tooling.
- `removed with documented deprecation`: do not expose in the Swift-only runtime.

| Current owner | Current path or method | Current response model | Stage 3 service method | Stage 3 caller | Stage 4 owner | Decision |
| --- | --- | --- | --- | --- | --- | --- |
| App startup/status | `IndexerProcess.Status`, daemon stdout `ready`/`indexed`/`rescan`/`sync_complete`/`watcher_indexed` | `DaemonEvent`, `IndexerProcess.Status` | `subscribeEvents()`, `status()` via `EngramServiceStatusStore.apply(_:)` | App | none | service command |
| App usage UI | daemon stdout `usage` event | `IndexerProcess.UsageItem` | `subscribeEvents()`, `usageStatus()` | App | none | service command |
| App health badge | `/health` | text/HTTP status | `health()` | App | none | service command |
| App search UI | `/api/search`, `/api/search/status`, `/api/search/semantic` | search rows, semantic availability | `search(_:)`, `searchStatus()` | App | MCP read parity remains read repository | service command |
| App sessions list/detail | `/api/sessions`, `/api/sessions/:id`, `/api/sessions/:id/children` | session lists/details/children | `listSessions(_:)`, `session(id:)`, `sessionChildren(id:)` | App | MCP read parity remains read repository | read repository |
| App replay timeline | `/api/sessions/:id/timeline` | `ReplayTimelineResponse` | `replayTimeline(sessionId:limit:)` | App | none | service command |
| App parent link management | `DaemonClient.linkSession`, `unlinkSession`, `confirmSuggestion`, `dismissSuggestion`; `/api/sessions/:id/link`, `/api/sessions/:id/confirm-suggestion`, `/api/sessions/:id/suggestion` | `DaemonClient.LinkResponse` | `linkSession(_:)`, `unlinkSession(_:)`, `confirmSuggestion(_:)`, `dismissSuggestion(_:)` | App | MCP mutation gate | service command |
| App resume UI | `/api/session/:id/resume` | resume command payload | `resumeCommand(sessionId:)` | App | none | service command |
| App source pulse | `/api/live`, `/api/sources`, `/api/health/sources` | `LiveSessionsResponse`, `SourceInfo`, source health | `liveSessions()`, `sources()`, `sourceHealth()` | App | none | service command |
| App skills page | `/api/skills` | `SkillInfo` | `skills()` | App | none | service command |
| App memory page | `/api/memory` | `MemoryFile` | `memoryFiles()` | App | none | service command |
| App hooks page | `/api/hooks` | `HookInfo` | `hooks()` | App | none | service command |
| App hygiene page | `DaemonClient.fetchHygieneChecks`, `/api/hygiene?force=` | `HygieneCheckResult` | `hygiene(force:)` | App | CLI lint remains Stage 4 | service command |
| App lint action | `/api/lint` | `LintResult` | `lintConfig(path:)` | App | CLI lint retained/ported in Stage 4 | service command |
| App handoff | `/api/handoff` | `HandoffResponse` | `handoff(_:)` | App | App service command; MCP handoff remains transcript tooling | service command |
| App summary generation | `/api/summary` | `GenerateSummaryResponse` | `generateSummary(_:)` | App | App and MCP callers route through native service code | service command |
| App title generation | `/api/session/:id/generate-title`, `/api/titles/regenerate-all` | title response / bulk result | `generateTitle(sessionId:)`, `regenerateAllTitles()` | App | Bulk title regeneration runs in native service code | service command |
| App embedding status | `/api/search/status` | semantic/vector status fields | `embeddingStatus()` | App | MCP search parity | service command |
| App sync settings | `/api/sync/status`, `/api/sync/sessions`, `/api/sync/trigger` | sync status/sessions/trigger result | `syncStatus()`, `syncSessions()`, `triggerSync(_:)` | App | Sync trigger is native service fail-soft status reporting; no daemon bridge | service command |
| App monitor alerts | `/api/monitor/alerts`, `/api/monitor/alerts/:id/dismiss` | `MonitorAlert` | `monitorAlerts()`, `dismissMonitorAlert(id:)` | App | none | service command |
| App project migrations list | `DaemonClient.listProjectMigrations`, `/api/project/migrations` | `[MigrationLogEntry]` | `projectMigrations(_:)` | App | MCP/CLI project ops in Stage 4 | service command |
| App project CWD lookup | `DaemonClient.projectCwds`, `/api/project/cwds` | `[String]` | `projectCwds(project:)` | App | MCP/CLI project ops in Stage 4 | service command |
| App project move | `DaemonClient.projectMove`, `/api/project/move` | `ProjectMoveResult` | `projectMove(_:)` | App | App and MCP callers route through service; command fails closed until native migration pipeline exists | service command |
| App project archive | `DaemonClient.projectArchive`, `/api/project/archive` | `ProjectMoveResult` | `projectArchive(_:)` | App | App and MCP callers route through service; command fails closed until native migration pipeline exists | service command |
| App project undo | `DaemonClient.projectUndo`, `/api/project/undo` | `ProjectMoveResult` | `projectUndo(_:)` | App | App and MCP callers route through service; command fails closed until native migration pipeline exists | service command |
| MCP save insight | `/api/insight` | raw JSON / insight result | `saveInsight(_:)` | none by default app | Native Swift/GRDB service implementation | service command |
| MCP manage project aliases | `/api/project-aliases` GET/POST/DELETE | raw JSON | `projectAliases(_:)`, `manageProjectAlias(_:)` | none by default app | list stays read-only; add/remove now route through service | service command |
| MCP project move batch | `/api/project/move-batch` | raw JSON | `projectMoveBatch(_:)` | none by default app | Routed through service and fails closed until native migration batch pipeline exists | service command |
| MCP link sessions | `/api/link-sessions` and file/symlink helpers | link result | `linkSessions(_:)` | none by default app | Stage 5 MCP mutation now routed through service; native Swift file operation behind writer gate | service command |
| App/MCP stats/costs/tool analytics | `/api/stats`, `/api/costs`, `/api/costs/sessions`, `/api/file-activity`, `/api/tool-analytics`, `/api/usage` | stats/cost/usage DTOs | `stats(_:)`, `costs(_:)`, `fileActivity(_:)`, `toolAnalytics(_:)`, `usageStatus()` | App if surfaced | MCP read parity remains read repository | read repository |
| App repository list | `/api/repos` | repo list DTO | `repositories()` | App if surfaced | none | service command |
| App AI audit views | `/api/ai/audit`, `/api/ai/audit/:id`, `/api/ai/stats` | audit rows/detail/stats | `aiAudit(_:)`, `aiAuditDetail(id:)`, `aiStats()` | App if surfaced | none | read repository |
| App log forwarding | `/api/log` | empty/ok | OSLog-only | App | none | removed with documented deprecation |
| Dev mock routes | `/api/dev/mock` POST/DELETE | mock result | none | none | none | removed with documented deprecation |
| Browser-only HTML routes | `/`, `/search`, `/stats`, `/settings`, `/session/:id`, `/goto` | HTML | none | none | none | removed with documented deprecation |
| App-local MCP bridge | `MCPServer("/mcp")`, `MCPTools` | Hummingbird HTTP MCP | none in production startup | none | Stage 5 deletion | removed with documented deprecation |
| Node daemon launch | `IndexerProcess.start(nodePath:scriptPath:)`, bundled `node/daemon.js` | daemon process/stdout | `EngramService` helper launch/connect | App | Stage 5 deletion | service command |

## Capability Checklist

- Live sessions: `liveSessions()`.
- Source info and source health: `sources()`, `sourceHealth()`.
- Skills: `skills()`.
- Memory: `memoryFiles()`.
- Hooks: `hooks()`.
- Hygiene and lint: `hygiene(force:)`, `lintConfig(path:)`.
- Handoff: `handoff(_:)`.
- Replay timeline: `replayTimeline(sessionId:limit:)`.
- Parent link and suggestion management: `linkSession(_:)`, `unlinkSession(_:)`, `confirmSuggestion(_:)`, `dismissSuggestion(_:)`.
- Project migrations, project CWDs, project move, project archive, project undo, and project move batch: service command, including current App and MCP caller routing.
- Search and embedding status: `search(_:)`, `searchStatus()`, `embeddingStatus()`.
- Summary generation and title regeneration: `generateSummary(_:)`, `generateTitle(sessionId:)`, `regenerateAllTitles()`.
- Sync trigger and status: `syncStatus()`, `syncSessions()`, `triggerSync(_:)`.
- Resume command: `resumeCommand(sessionId:)`.
- Save insight: service command.
- Link sessions: service command with MCP fail-closed coverage.
- Log forwarding: OSLog-only. The old `/api/log` forwarding path is removed.
- Health: `health()`.

## Stage 5 Debt Snapshot

- App UI surfaces no longer call daemon HTTP directly for sync trigger, bulk title regeneration, or project move/archive/undo.
- `LegacyDaemonBridge` has been deleted. No service-internal command forwards to retained daemon endpoints.
- Project move/archive/undo/batch are intentionally fail-closed service commands until a native Swift migration pipeline replaces the old Node orchestrator.
- MCP direct daemon HTTP compatibility has been removed from the routed mutation/operational paths in `macos/EngramMCP/Core/MCPToolRegistry.swift`.
- `DaemonClient` and `DaemonHTTPClientCore` have been deleted from production targets. `EngramLogger` remains as an OSLog-only utility and no longer posts to `/api/log`.
- `UnixSocketEngramServiceTransport.events()` now polls service status over the Unix socket instead of returning an immediately empty stream.

## Stage 3 Gate Commands

```bash
rtk rg -n "live|source|skills|memory|hooks|hygiene|lint|handoff|replay|parent|project|search|embedding|summary|title|sync|resume|insight|link|log|health" docs/swift-single-stack/daemon-client-map.md
rtk rg -n "DaemonClient|DaemonHTTPClientCore|IndexerProcess|http://127\\.0\\.0\\.1|localhost:|/api/|/health|ENGRAM_MCP_DAEMON_BASE_URL" macos/Engram macos/Shared macos/EngramMCP macos/EngramCLI --glob '!macos/build/**' --glob '!**/*.xcarchive/**'
```
