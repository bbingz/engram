import Foundation

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: JSONValue

    var jsonValue: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }

    var orderedJSONValue: OrderedJSONValue {
        .object([
            ("name", .string(name)),
            ("description", .string(description)),
            ("inputSchema", OrderedJSONValue(inputSchema)),
        ])
    }
}

enum MCPToolRegistry {
    static let tools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_sessions",
            description: "列出 AI 编程助手的历史会话。支持按工具来源、项目、时间范围过滤。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("codex"),
                            .string("claude-code"),
                            .string("gemini-cli"),
                            .string("opencode"),
                            .string("iflow"),
                            .string("qwen"),
                            .string("kimi"),
                            .string("cline"),
                            .string("cursor"),
                            .string("vscode"),
                            .string("antigravity"),
                            .string("windsurf"),
                        ]),
                        "description": .string("过滤特定工具的会话"),
                    ]),
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("过滤特定项目（部分匹配）"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("开始时间（ISO 8601）"),
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("结束时间（ISO 8601）"),
                    ]),
                    "limit": .object([
                        "type": .string("number"),
                        "description": .string("最多返回条数，默认 20，最大 100"),
                    ]),
                    "offset": .object([
                        "type": .string("number"),
                        "description": .string("分页偏移量"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "stats",
            description: "统计各工具的会话数量、消息数等用量数据。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object(["type": .string("string")]),
                    "until": .object(["type": .string("string")]),
                    "group_by": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("source"),
                            .string("project"),
                            .string("day"),
                            .string("week"),
                        ]),
                        "description": .string("按维度分组，默认 source"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "get_costs",
            description: "Get token usage costs across sessions, grouped by model, source, project, or day.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_by": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("model"),
                            .string("source"),
                            .string("project"),
                            .string("day"),
                        ]),
                        "description": .string("Group dimension (default: model)"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Start time (ISO 8601)"),
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("End time (ISO 8601)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "tool_analytics",
            description: "Analyze which tools (Read, Edit, Bash, etc.) are used most across sessions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("Filter by project name (partial match)"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Start time (ISO 8601)"),
                    ]),
                    "group_by": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("tool"),
                            .string("session"),
                            .string("project"),
                        ]),
                        "description": .string("Group dimension (default: tool)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "file_activity",
            description: "Show most frequently edited/read files across sessions for a project. Helps understand project activity patterns.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("Filter by project name"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO 8601 date filter"),
                    ]),
                    "limit": .object([
                        "type": .string("number"),
                        "description": .string("Max results (default 50)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "project_timeline",
            description: "查看某个项目跨工具的操作时间线，了解在不同 AI 助手里分别做了什么。",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("project")]),
                "properties": .object([
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("项目名或路径片段"),
                    ]),
                    "since": .object(["type": .string("string")]),
                    "until": .object(["type": .string("string")]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "project_list_migrations",
            description: "List recent project-move migrations with state, paths, counts, and timestamps. Used to find a migration_id for undo/recover, or to build the daily audit table.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("number"),
                        "default": .int(20),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO timestamp — only rows started after this"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "live_sessions",
            description: "List currently active coding sessions detected by file activity.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "get_memory",
            description: "Retrieve curated insights and memories from past sessions. Use save_insight to add new memories.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("query")]),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("What to remember (e.g. \"user's coding preferences\")"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "save_insight",
            description: "Save an important insight, decision, or lesson learned for future retrieval. Use this to preserve knowledge that should persist across sessions.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("content")]),
                "properties": .object([
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("The insight or knowledge to save"),
                    ]),
                    "wing": .object([
                        "type": .string("string"),
                        "description": .string("Project or domain name (optional)"),
                    ]),
                    "room": .object([
                        "type": .string("string"),
                        "description": .string("Sub-area within the project (optional)"),
                    ]),
                    "importance": .object([
                        "type": .string("number"),
                        "description": .string("Importance level 0-5 (default: 5)"),
                        "minimum": .int(0),
                        "maximum": .int(5),
                    ]),
                    "source_session_id": .object([
                        "type": .string("string"),
                        "description": .string("Session ID that generated this insight (optional)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "manage_project_alias",
            description: "Link two project names so sessions from one appear in queries for the other. Only use this for directories moved MANUALLY outside of engram (e.g. someone ran `mv` directly). Do NOT call after project_move — that tool already creates the alias automatically.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("action")]),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("add"),
                            .string("remove"),
                            .string("list"),
                        ]),
                        "description": .string("Action to perform"),
                    ]),
                    "old_project": .object([
                        "type": .string("string"),
                        "description": .string("Old project name (for add/remove)"),
                    ]),
                    "new_project": .object([
                        "type": .string("string"),
                        "description": .string("New project name (for add/remove)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
    ]

    static func handle(
        tool name: String,
        arguments: [String: JSONValue],
        config: MCPConfig
    ) async throws -> OrderedJSONValue {
        switch name {
        case "list_sessions":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.listSessions(
                source: arguments["source"]?.stringValue,
                project: arguments["project"]?.stringValue,
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue,
                limit: min(arguments["limit"]?.intValue ?? 20, 100),
                offset: arguments["offset"]?.intValue ?? 0
            )
            return .toolSuccess(structured)
        case "stats":
            let database = try MCPDatabase(path: config.dbPath)
            let groupBy = arguments["group_by"]?.stringValue ?? "source"
            let structured = try database.stats(
                groupBy: groupBy,
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue
            )
            return .toolSuccess(structured)
        case "get_costs":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.getCosts(
                groupBy: arguments["group_by"]?.stringValue ?? "model",
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue
            )
            return .toolSuccess(structured)
        case "tool_analytics":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.getToolAnalytics(
                project: arguments["project"]?.stringValue,
                since: arguments["since"]?.stringValue,
                groupBy: arguments["group_by"]?.stringValue ?? "tool"
            )
            return .toolSuccess(structured)
        case "file_activity":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.getFileActivity(
                project: arguments["project"]?.stringValue,
                since: arguments["since"]?.stringValue,
                limit: arguments["limit"]?.intValue ?? 50
            )
            return .toolSuccess(structured)
        case "project_timeline":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.projectTimeline(
                project: try requiredString("project", in: arguments),
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue
            )
            return .toolSuccess(structured)
        case "project_list_migrations":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.listMigrations(
                limit: arguments["limit"]?.intValue ?? 20,
                since: arguments["since"]?.stringValue
            )
            return .toolSuccess(structured)
        case "live_sessions":
            return .toolSuccess(
                .object([
                    ("sessions", .array([])),
                    ("count", .int(0)),
                    ("note", .string("Live session monitor not available (MCP server mode)")),
                ])
            )
        case "get_memory":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.getMemory(query: try requiredString("query", in: arguments))
            return .toolSuccess(structured)
        case "save_insight":
            let body = SaveInsightBody(
                actor: "mcp",
                content: try requiredString("content", in: arguments),
                wing: arguments["wing"]?.stringValue,
                room: arguments["room"]?.stringValue,
                importance: arguments["importance"]?.doubleValue,
                sourceSessionID: arguments["source_session_id"]?.stringValue
            )
            let client = DaemonHTTPClientCore(
                baseURL: config.daemonBaseURL,
                bearerTokenProvider: { config.bearerToken }
            )
            let raw: JSONValue = try await client.post("/api/insight", body: body)
            let structured = orderedSaveInsight(from: raw)
            return .toolSuccess(structured)
        case "manage_project_alias":
            let action = try requiredString("action", in: arguments)
            switch action {
            case "list":
                let database = try MCPDatabase(path: config.dbPath)
                return .toolSuccess(try database.listProjectAliases())
            case "add", "remove":
                let alias = try requiredString("old_project", in: arguments)
                let canonical = try requiredString("new_project", in: arguments)
                let body = ProjectAliasBody(
                    actor: "mcp",
                    alias: alias,
                    canonical: canonical
                )
                let client = DaemonHTTPClientCore(
                    baseURL: config.daemonBaseURL,
                    bearerTokenProvider: { config.bearerToken }
                )
                if action == "add" {
                    let _: JSONValue = try await client.post("/api/project-aliases", body: body)
                    return .toolSuccess(
                        .object([
                            ("added", .object([
                                ("alias", .string(alias)),
                                ("canonical", .string(canonical)),
                            ])),
                        ])
                    )
                } else {
                    let _: JSONValue = try await client.delete("/api/project-aliases", body: body)
                    return .toolSuccess(
                        .object([
                            ("removed", .object([
                                ("alias", .string(alias)),
                                ("canonical", .string(canonical)),
                            ])),
                        ])
                    )
                }
            default:
                return .toolError(message: "Unknown action: \(action)")
            }
        default:
            return .toolError(message: "Unknown tool: \(name)")
        }
    }

    private static func requiredString(
        _ key: String,
        in arguments: [String: JSONValue]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw MCPToolError.invalidArguments("\(key) is required")
        }
        return value
    }
}

private func orderedSaveInsight(from raw: JSONValue) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = []
    if let id = raw["id"] { entries.append(("id", OrderedJSONValue(id))) }
    if let content = raw["content"] { entries.append(("content", OrderedJSONValue(content))) }
    if let wing = raw["wing"] { entries.append(("wing", OrderedJSONValue(wing))) }
    if let room = raw["room"] { entries.append(("room", OrderedJSONValue(room))) }
    if let importance = raw["importance"] { entries.append(("importance", OrderedJSONValue(importance))) }
    if let duplicateWarning = raw["duplicateWarning"] {
        entries.append(("duplicateWarning", OrderedJSONValue(duplicateWarning)))
    }
    if let warning = raw["warning"] { entries.append(("warning", OrderedJSONValue(warning))) }
    return .object(entries)
}

private struct SaveInsightBody: Encodable {
    let actor: String
    let content: String
    let wing: String?
    let room: String?
    let importance: Double?
    let sourceSessionID: String?

    enum CodingKeys: String, CodingKey {
        case actor
        case content
        case wing
        case room
        case importance
        case sourceSessionID = "source_session_id"
    }
}

private struct ProjectAliasBody: Encodable {
    let actor: String
    let alias: String
    let canonical: String
}

private enum MCPToolError: LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        }
    }
}

extension OrderedJSONValue {
    static func toolSuccess(_ structured: OrderedJSONValue) -> OrderedJSONValue {
        .object([
            ("content", .array([
                .object([
                    ("type", .string("text")),
                    ("text", .string(structured.prettyJSONString())),
                ]),
            ])),
            ("structuredContent", structured),
        ])
    }

    static func toolError(message: String) -> OrderedJSONValue {
        .object([
            ("content", .array([
                .object([
                    ("type", .string("text")),
                    ("text", .string(message)),
                ]),
            ])),
            ("isError", .bool(true)),
        ])
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }
}
