// macos/CodingMemory/Core/MCPTools.swift
import Foundation

enum MCPError: Error {
    case methodNotFound(String)
    case toolNotFound(String)
    case invalidParams(String)
}

@MainActor
class MCPTools {
    private let db: DatabaseManager

    init(db: DatabaseManager) { self.db = db }

    // MARK: - Tool definitions (mirrors src/tools/*.ts)
    static let toolList: [MCPTool] = [
        MCPTool(name: "list_sessions",
                description: "列出 AI 编程助手的历史会话。支持按工具来源、项目、时间范围过滤。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source":  .object(["type": .string("string")]),
                        "project": .object(["type": .string("string")]),
                        "since":   .object(["type": .string("string")]),
                        "limit":   .object(["type": .string("number")]),
                        "offset":  .object(["type": .string("number")]),
                    ])
                ])),
        MCPTool(name: "get_session",
                description: "按 ID 获取会话详情。",
                inputSchema: .object([
                    "type": .string("object"),
                    "required": .array([.string("id")]),
                    "properties": .object(["id": .object(["type": .string("string")])])
                ])),
        MCPTool(name: "search",
                description: "在所有会话内容中全文搜索（FTS5 trigram）。",
                inputSchema: .object([
                    "type": .string("object"),
                    "required": .array([.string("query")]),
                    "properties": .object([
                        "query":  .object(["type": .string("string")]),
                        "source": .object(["type": .string("string")]),
                        "limit":  .object(["type": .string("number")]),
                    ])
                ])),
        MCPTool(name: "project_timeline",
                description: "查看某个项目跨工具的操作时间线。",
                inputSchema: .object([
                    "type": .string("object"),
                    "required": .array([.string("project")]),
                    "properties": .object(["project": .object(["type": .string("string")])])
                ])),
        MCPTool(name: "stats",
                description: "统计各工具的会话数量、消息数等用量数据。",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
        MCPTool(name: "get_context",
                description: "为当前工作目录自动提取相关的历史会话上下文。",
                inputSchema: .object([
                    "type": .string("object"),
                    "required": .array([.string("cwd")]),
                    "properties": .object([
                        "cwd":   .object(["type": .string("string")]),
                        "limit": .object(["type": .string("number")]),
                    ])
                ])),
        MCPTool(name: "export",
                description: "导出单条会话为 JSON。",
                inputSchema: .object([
                    "type": .string("object"),
                    "required": .array([.string("id")]),
                    "properties": .object(["id": .object(["type": .string("string")])])
                ])),
    ]

    // MARK: - JSON-RPC dispatch
    func handle(method: String, params: JSONValue?) throws -> JSONValue {
        switch method {
        case "initialize":
            return .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])])
            ])
        case "tools/list":
            let tools = Self.toolList.map { t -> JSONValue in
                .object(["name": .string(t.name),
                         "description": .string(t.description),
                         "inputSchema": t.inputSchema])
            }
            return .object(["tools": .array(tools)])
        case "tools/call":
            return try callTool(params: params)
        case "notifications/initialized", "ping":
            return .object([:])
        default:
            throw MCPError.methodNotFound(method)
        }
    }

    private func callTool(params: JSONValue?) throws -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            throw MCPError.invalidParams("missing tool name")
        }
        let args = params?["arguments"] ?? .object([:])

        let text: String
        switch name {
        case "list_sessions":
            let sessions = try db.listSessions(
                source:  args["source"]?.stringValue,
                project: args["project"]?.stringValue,
                since:   args["since"]?.stringValue,
                limit:   args["limit"]?.intValue ?? 20,
                offset:  args["offset"]?.intValue ?? 0)
            text = formatSessions(sessions)

        case "get_session":
            guard let id = args["id"]?.stringValue else { throw MCPError.invalidParams("missing id") }
            if let s = try db.getSession(id: id) {
                text = sessionJSON(s)
            } else {
                text = "Session not found: \(id)"
            }

        case "search":
            guard let q = args["query"]?.stringValue else { throw MCPError.invalidParams("missing query") }
            let sessions = try db.search(query: q, limit: args["limit"]?.intValue ?? 10)
            text = formatSessions(sessions)

        case "project_timeline":
            guard let project = args["project"]?.stringValue else { throw MCPError.invalidParams("missing project") }
            let timeline = try db.projectTimeline(project: project)
            text = timeline.map {
                "[\(String($0.lastUpdated.prefix(10)))] \($0.project ?? "unknown") — \($0.sessionCount) sessions"
            }.joined(separator: "\n")

        case "stats":
            let s = try db.stats()
            let bySource = s.bySource.sorted { $0.value > $1.value }
                .map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
            text = "Total sessions: \(s.totalSessions)\nTotal messages: \(s.totalMessages)\nBy source:\n\(bySource)"

        case "get_context":
            guard let cwd = args["cwd"]?.stringValue else { throw MCPError.invalidParams("missing cwd") }
            let sessions = try db.getContext(cwd: cwd, limit: args["limit"]?.intValue ?? 5)
            text = sessions.map { s in
                "[\(s.source)] \(s.displayDate) — \(s.summary ?? "(no summary)")"
            }.joined(separator: "\n")

        case "export":
            guard let id = args["id"]?.stringValue else { throw MCPError.invalidParams("missing id") }
            if let s = try db.getSession(id: id) {
                text = sessionJSON(s)
            } else {
                text = "Session not found: \(id)"
            }

        default:
            throw MCPError.toolNotFound(name)
        }

        return .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    // MARK: - Formatting helpers
    private func formatSessions(_ sessions: [Session]) -> String {
        sessions.map { s in
            "[\(s.source)] \(s.displayTitle) | \(s.messageCount) msgs | \(s.displayDate) | \(s.project ?? "no project")"
        }.joined(separator: "\n")
    }

    private func sessionJSON(_ s: Session) -> String {
        let obj: [String: Any?] = [
            "id": s.id, "source": s.source,
            "startTime": s.startTime, "endTime": s.endTime,
            "cwd": s.cwd, "project": s.project,
            "model": s.model, "summary": s.summary,
            "messageCount": s.messageCount,
            "userMessageCount": s.userMessageCount,
            "filePath": s.filePath, "sizeBytes": s.sizeBytes,
        ]
        let clean = obj.compactMapValues { $0 }
        let data = try? JSONSerialization.data(withJSONObject: clean, options: .prettyPrinted)
        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
    }
}
