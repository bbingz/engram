# MCP Swift Shim Implementation Plan

**Goal:** Replace Node `src/index.ts` with a bundled Swift stdio helper for the **same 26 callable MCP tools**, while keeping all write-side mutations inside daemon HTTP and leaving the rest of Engram unchanged.

**Architecture:** Add a standalone `EngramMCP` executable target under `macos/` that speaks stdio JSON-RPC, exposes the current Node runtime tool surface from `src/index.ts`, executes read tools against `~/.engram/index.sqlite` through GRDB, and executes write tools through daemon HTTP only. This shim is **strict-only**: if daemon HTTP is unavailable, it returns an MCP error immediately and never falls back to direct DB writes.

**Tech Stack:** Swift 5.9 language mode on macOS 14+, GRDB for read-only SQLite access, `Foundation`/`URLSession` for daemon HTTP, `os.Logger` with subsystem `com.engram.app`, XCTest for contract tests, XcodeGen/Xcode build integration.

## Scope lock

- In scope:
  - stdio transport
  - JSON-RPC lifecycle
  - tool schema registry for **26 callable tools**
  - read dispatch to GRDB
  - write dispatch to daemon HTTP
  - packaging inside `Engram.app`
- Out of scope:
  - adapters
  - `daemon.ts`
  - chunker/embedder/vector store/sqlite-vec
  - DB schema changes
  - `src/index.ts` removal

## Source of truth

- Tool surface: `src/index.ts` `allTools`, not README / “19 tools” wording.
- Write-path behavior: Phase B single-writer architecture in `PROGRESS.md`.
- HTTP behavior: `src/web.ts` endpoints + existing Swift `macos/Engram/Core/DaemonClient.swift`.

## Shared-core mechanism

Chosen mechanism: **xcodegen shared source path + fileGroups**, not a local SPM package.

Trade-off:

- Pros:
  - no extra local `Package.swift`
  - no second module graph to debug during Phase 2
  - smallest path from current XcodeGen setup to “app and helper compile the same HTTP core”
- Cons:
  - less explicit module boundary than a standalone package
  - shared files remain inside the Xcode project’s source graph rather than a separately versioned product

Rationale: this repo already uses XcodeGen targets, and the required reuse is narrow: request building, bearer handling, and response envelope decoding from `DaemonClient.swift`. A local SPM package is viable later if the shared network layer grows; Phase 2 optimizes for low-churn extraction.

## Directory / target layout

- New target:
  - `macos/EngramMCP`
- New files:
  - `macos/EngramMCP/main.swift`
  - `macos/EngramMCP/Core/JSONRPC.swift`
  - `macos/EngramMCP/Core/StdioTransport.swift`
  - `macos/EngramMCP/Core/MCPServerCore.swift`
  - `macos/EngramMCP/Core/MCPToolRegistry.swift`
  - `macos/EngramMCP/Core/MCPToolSchemas.swift`
  - `macos/EngramMCP/Core/MCPReadHandlers.swift`
  - `macos/EngramMCP/Core/MCPWriteHandlers.swift`
  - `macos/EngramMCP/Core/MCPDatabase.swift`
  - `macos/EngramMCP/Core/MCPErrorMapping.swift`
- Shared refactor, reused by app + helper:
  - extract the reusable transport/error core from `macos/Engram/Core/DaemonClient.swift` into `macos/Shared/Networking/DaemonHTTPClientCore.swift`
  - update `macos/project.yml` so both `Engram` and `EngramMCP` include `Shared/Networking`
  - keep app-only DTOs/extensions in `macos/Engram/Core/DaemonClient.swift`
  - `EngramMCP` imports the shared core instead of re-implementing bearer/validateResponse/request building
- Tests:
  - `macos/EngramTests/MCP/EngramMCPProtocolTests.swift`
  - `macos/EngramTests/MCP/EngramMCPContractTests.swift`
  - `macos/EngramTests/MCP/NodeContractFixtureTests.swift` or a fixture generator script under `scripts/`
- Checked-in fixtures:
  - `tests/fixtures/mcp-contract.sqlite`
  - `tests/fixtures/mcp-golden/*.json`
  - generator input script or SQL rebuild path if fixture refresh is needed
- Packaging:
  - update `macos/project.yml`
  - add `macos/scripts/copy-mcp-helper.sh`
  - ship helper at `Engram.app/Contents/Helpers/EngramMCP`

## Execution order

1. Create `EngramMCP` target and stdio lifecycle only.
2. Add protocol smoke tests: `initialize`, `tools/list`, `ping`, invalid JSON.
3. Extract shared daemon HTTP core from existing `DaemonClient.swift`.
4. Add tool schema registry for all **26 callable tools**.
5. Implement one read template (`stats`) and one write template (`save_insight`).
6. Add mixed-mode template (`manage_project_alias`) showing `action`-based read/write split.
7. Scaffold portable fixture DB + offline Node golden generator.
8. Lock contract-test harness against Node output snapshots.
9. Port remaining read tools.
10. Port remaining write tools with strict-only fail-fast behavior.
11. Integrate bundle copy step and app packaging.
12. Run Swift verification, then Node regression verification.

## Strict-only write-path rule

The Swift shim does **not** inherit Node’s `mcpStrictSingleWriter=false` fallback. Every write tool behaves as:

- build JSON body
- call daemon HTTP
- return success result if HTTP 2xx
- map daemon/network error to MCP `isError: true` response
- stop there

No direct DB writes. No silent retry to SQLite. No write-path branch on settings.

## Read tool template: `stats`

Template target: ~60-120 LOC for schema + dispatch + formatting.

```swift
// MCPToolSchemas.swift
let statsTool = MCPTool(
    name: "stats",
    description: "统计各工具的会话数量、消息数等用量数据。",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "group_by": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("source"), .string("project"),
                    .string("day"), .string("week")
                ])
            ]),
            "since": .object(["type": .string("string")]),
            "until": .object(["type": .string("string")]),
        ]),
        "additionalProperties": .bool(false),
    ])
)

// MCPReadHandlers.swift
func handleStats(args: JSONValue, db: MCPDatabase) throws -> MCPToolResult {
    let groupBy = args["group_by"]?.stringValue ?? "source"
    let since = args["since"]?.stringValue
    let until = args["until"]?.stringValue
    let rows = try db.stats(groupBy: groupBy, since: since, until: until)
    return .json(rows)
}

// MCPToolRegistry.swift
registry["stats"] = .read { args, ctx in
    try handleStats(args: args, db: ctx.db)
}
```

Behavioral requirement:

- match Node output shape exactly for the chosen fixture input
- use GRDB read-only access only
- no inferred defaults beyond current TS handler behavior

## Write tool template: `save_insight`

Template target: ~80-120 LOC for schema + body + error mapping.

```swift
// MCPToolSchemas.swift
let saveInsightTool = MCPTool(
    name: "save_insight",
    description: "Save an important insight, decision, or lesson learned for future retrieval. Use this to preserve knowledge that should persist across sessions.",
    inputSchema: .object([
        "type": .string("object"),
        "required": .array([.string("content")]),
        "properties": .object([
            "content": .object(["type": .string("string")]),
            "wing": .object(["type": .string("string")]),
            "room": .object(["type": .string("string")]),
            "importance": .object([
                "type": .string("number"),
                "minimum": .number(0),
                "maximum": .number(5),
            ]),
            "source_session_id": .object(["type": .string("string")]),
        ]),
        "additionalProperties": .bool(false),
    ])
)

// MCPWriteHandlers.swift
func handleSaveInsight(args: JSONValue, client: DaemonHTTPClientCore) async throws -> MCPToolResult {
    struct Body: Encodable {
        let content: String
        let wing: String?
        let room: String?
        let importance: Int?
        let sourceSessionId: String?

        enum CodingKeys: String, CodingKey {
            case content, wing, room, importance
            case sourceSessionId = "source_session_id"
        }
    }

    guard let content = args["content"]?.stringValue else {
        throw MCPToolError.invalidParams("content is required")
    }

    let response: SaveInsightResponse = try await client.post(
        "/api/insight",
        body: Body(
            content: content,
            wing: args["wing"]?.stringValue,
            room: args["room"]?.stringValue,
            importance: args["importance"]?.intValue,
            sourceSessionId: args["source_session_id"]?.stringValue
        )
    )
    return .json(response)
}

// MCPErrorMapping.swift
catch let error as DaemonHTTPClientCore.ErrorEnvelope {
    return .mcpError("save_insight failed: \(error.message)")
} catch {
    return .mcpError("save_insight failed: \(error.localizedDescription)")
}
```

Behavioral requirement:

- POST daemon only
- fail fast on network error
- preserve daemon 4xx/5xx message text in MCP error content
- no SQLite fallback

## Mixed-mode template: `manage_project_alias`

This is the third template because it demonstrates a single MCP tool splitting into read and write paths on `action`.

```swift
func handleManageProjectAlias(
    args: JSONValue,
    db: MCPDatabase,
    client: DaemonHTTPClientCore
) async throws -> MCPToolResult {
    let action = args["action"]?.stringValue ?? ""
    switch action {
    case "list":
        let aliases = try db.listProjectAliases()
        return .json(aliases)

    case "add":
        struct Body: Encodable {
            let oldProject: String
            let newProject: String

            enum CodingKeys: String, CodingKey {
                case oldProject = "old_project"
                case newProject = "new_project"
            }
        }
        let response: AliasMutationResponse = try await client.post(
            "/api/project-aliases",
            body: Body(
                oldProject: try requireString(args, "old_project"),
                newProject: try requireString(args, "new_project")
            )
        )
        return .json(response)

    case "remove":
        struct Body: Encodable {
            let oldProject: String
            let newProject: String

            enum CodingKeys: String, CodingKey {
                case oldProject = "old_project"
                case newProject = "new_project"
            }
        }
        let response: AliasMutationResponse = try await client.delete(
            "/api/project-aliases",
            body: Body(
                oldProject: try requireString(args, "old_project"),
                newProject: try requireString(args, "new_project")
            )
        )
        return .json(response)

    default:
        throw MCPToolError.invalidParams("action must be add, remove, or list")
    }
}
```

## Contract test methodology

Chosen Phase 2 contract set:

- `get_context`
- `search`
- `stats`
- `save_insight`
- `project_move` (`dry_run: true`)
- optional stretch: `get_costs`, `list_sessions`, `tool_analytics`, `manage_project_alias`

Method:

1. Start from a fixed SQLite fixture or a read-only harness against `~/.engram/index.sqlite`.
2. For each selected tool/input pair, invoke current Node shim and save the raw JSON response as a fixture snapshot.
3. Invoke Swift shim with the same input.
4. Compare raw bytes.
5. If bytes differ, either:
   - make Swift output byte-equivalent, or
   - record the exact justified difference in the test fixture README and assert normalized equivalence intentionally.

Fixture discipline:

- fixture DB is checked in and never points at `~/.engram/index.sqlite`
- fixture contains ~20-50 sessions, ~10 insights, and metrics rows, sized for fast CI
- reset fixture DB / temp rows between runs
- write tools use daemon dry-run or isolated cleanup hooks
- all timestamps compared in UTC-form strings only

## Risk table

| Risk | Impact | Mitigation |
|---|---|---|
| Runtime surface drift between Node and Swift | Wrong Claude tool selection / missing tools | Generate tool list from `src/index.ts` inventory and assert count = 26 in tests |
| Reusing `DaemonClient.swift` pulls app-only DTO baggage into helper | Target coupling and compile noise | Extract only request-building, bearer, validation, error envelope logic into shared core; leave app DTOs/extensions in app target |
| Strict-only fail-fast changes behavior vs current Node fallback | Expected by review, but may surprise users during daemon outages | Document explicitly in plan/tests; return clear MCP error text naming daemon unreachability |
| Hardcoded MCP protocol version | Future client/server negotiation mismatch | Ship MVP with `2025-03-26`, add explicit TODO for `initialize` negotiation, and cover version handling before broad client rollout |
| `DispatchSemaphore` sync bridge in stdio tool dispatch | Blocks stdin during long calls today and becomes a Swift 6 Sendable migration hazard later | Accept for MVP only, add explicit TODO to move to an async stdin loop before Swift 6 migration / concurrency tightening |
| GRDB query parity for read tools | Shape mismatch | Port selected handlers one-by-one with Node snapshot tests before bulk rollout |
| Generated Xcode project churn from worktree name | Noisy diffs | Keep `project.yml` authoritative; review generated diffs for bundle/helper additions only |

## Verification plan

- `xcodegen generate`
- `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCP -configuration Debug build`
- protocol smoke tests for stdio initialize/list/call/ping
- byte-equivalent contract tests for selected tools
- `xcodebuild -project macos/Engram.xcodeproj -scheme Engram -configuration Debug build`
- `npm run build`
- `npm test`
