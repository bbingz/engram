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
        case "stats":
            let database = try MCPDatabase(path: config.dbPath)
            let groupBy = arguments["group_by"]?.stringValue ?? "source"
            let structured = try database.stats(
                groupBy: groupBy,
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue
            )
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
