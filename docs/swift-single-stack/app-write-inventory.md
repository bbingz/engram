# App Write Inventory

Allowed writes are app-local settings, Keychain, launch-agent registration, and runtime-local cleanup. Data-plane writes to `index.sqlite`, session history, project migrations, indexing, summary/title generation, and MCP mutating tools must move behind the Swift service writer.

| File | Operation | Classification | Required action | Verification |
|---|---|---|---|---|
| `macos/Engram/Core/Database.swift` `open()` | Read-only `DatabasePool(path:)` | Resolved: app read facade only | Keep migrations/data-plane writes in `EngramCoreWrite`/service | Direct-write scan allows this read-only DB open only |
| `macos/Engram/Core/Database.swift` favorites methods | Removed app-local DML | Resolved: routed through service | Keep `setFavorite` behind typed service client | Favorite service IPC test plus writer scan |
| `macos/Engram/Core/Database.swift` hide/unhide/rename/project methods | Removed app-local session DML | Resolved for hide/unhide/rename; project ops use service command path | Keep session mutations behind typed service commands | App metadata service IPC test plus writer scan |
| `macos/Engram/Core/Database.swift` `hideEmptySessions()` | Removed app-local bulk update | Resolved: service-owned cleanup command | Keep `hideEmptySessions` behind service writer gate | App metadata service IPC test plus writer scan |
| `macos/Engram/Core/Database.swift` `updateSessionSummary()` | Removed app-local summary DML | Resolved: summary persistence is service-owned | Keep `generateSummary` behind service writer gate | Former-bridge service IPC test plus writer scan |
| `macos/Engram/Core/MessageParser.swift` | Readonly `DatabaseQueue(path:)`, `queue.read` | Allowed read-plane access | Keep behind read core/adapters | Confirm `readonly = true` and no DML |
| `macos/EngramMCP/Core/MCPDatabase.swift` | Readonly `DatabaseQueue(path:)`, `queue.read` | Allowed read-plane MCP access | Keep as read-only core facade | `rg "queue\\.write|db\\.execute|INSERT|UPDATE|DELETE" macos/EngramMCP/Core/MCPDatabase.swift` has no executable DML |
| `macos/Engram/Core/DaemonClient.swift` | Former generic `POST`, `postRaw`, `DELETE` transport | Resolved: file deleted from production targets | Keep App callers on typed `EngramServiceClient` | Raw daemon endpoint scan clean |
| UI relationship/project callers | Former `/api/sessions/*`, `/api/project/*` POST/DELETE | Resolved: routed through service or fail-closed when Swift project migration is unavailable | Keep project migration execution disabled until native Swift pipeline exists | Relationship and project operation tests |
| `macos/Engram/Core/EngramLogger.swift` | Former `POST /api/log` forwarding | Resolved: OSLog-only, no raw Node URL | Keep observability local unless a typed service log command is added | Raw URL scan |
| `SessionDetailView.swift` | `POST /api/summary` | Conflict: summary write via Node daemon | Service summary command | Summary UI test |
| `AISettingsSection.swift` | `POST /api/titles/regenerate-all` | Conflict: bulk title/session write | Service title-regeneration command | Title regeneration test |
| `NetworkSettingsSection.swift` | `POST /api/sync/trigger` | Conflict: sync/indexing write | Service sync command/status model | Sync UI test |
| `macos/EngramMCP/Core/MCPToolRegistry.swift` mutating tools | Service IPC commands for summary, insights, aliases, project ops | Resolved for service routing; project move/archive/undo/batch fail closed until native migration pipeline exists | Keep MCP direct DB/daemon fallback removed | MCP fail-closed/golden tests plus direct-write scan |
| `macos/EngramMCP/Core/MCPFileTools.swift` `linkSessions` | `removeItem`, `createDirectory`, symlink creation | Resolved: MCP routing moved behind service command and writer gate | Keep helper as service-side implementation detail only until cleanup | Service-unavailable test proves fail-closed routing |
| `macos/EngramMCP/Core/MCPTranscriptTools.swift` former `exportSession` | Write export under `~/codex-exports` | Resolved: direct MCP writer removed; export now routes through `EngramService` `exportSession` | Keep export writes service-owned | `EngramServiceIPCTests.testExportSessionWritesThroughServiceCommand`; MCP export golden and service-unavailable tests |
| `macos/Engram/Core/LaunchAgent.swift` | `SMAppService`, plist writes/removal | Allowed app-local OS integration | Keep app-owned | Manual smoke/settings test |
| `macos/Engram/Views/Settings/SettingsIO.swift` | Keychain and `~/.engram/settings.json` | Allowed app-local config/secret write | Keep app-owned unless service becomes config authority | Settings save/load tests |
| `SourcesSettingsSection.swift`, `App.swift` | `UserDefaults` | Allowed app-local preference write | Keep app-owned | Settings/app launch smoke |
