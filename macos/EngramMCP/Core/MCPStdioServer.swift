import Foundation

final class MCPStdioServer {
    private let config = MCPConfig.load()
    private static let instructions = """
    Engram is a cross-tool AI session aggregator. Key tools:
    - search: Full-text + semantic search across all AI coding sessions (15+ tools)
    - get_context: Auto-extract relevant project history for your current task
    - save_insight: Save important decisions, lessons, and knowledge for future sessions
    - get_memory: Retrieve previously saved insights and cross-session knowledge
    - get_session: Read full conversation transcript of any session
    - list_sessions: Browse sessions with filters (source, project, date)
    - project_list_migrations / project_recover / project_review: inspect project
        migration history.
    - project_move / project_archive / project_undo / project_move_batch: rewrite
        AI session paths when a project moves on disk. ⚠️ run sequentially.

    Best practices:
    1. Call get_context at the start of a task to see what's been done before
    2. Use save_insight to preserve important decisions that should persist
    3. Verify facts from memory before acting on them — memories can be stale
    4. Cite session IDs when referencing past work
    """

    func run() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let requestData = trimmed.data(using: .utf8),
                  let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: requestData) else {
                emitError(id: nil, code: -32700, message: "Parse error")
                continue
            }

            handle(request)
        }
    }

    private func handle(_ request: JSONRPCRequest) {
        switch request.method {
        case "initialize":
            emit(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    // TODO(mcp-version-negotiation): read params.protocolVersion and negotiate.
                    ("protocolVersion", .string("2025-03-26")),
                    ("capabilities", .object([
                        ("tools", .object([])),
                    ])),
                    ("serverInfo", .object([
                        ("name", .string("engram")),
                        ("version", .string("0.1.0")),
                    ])),
                    ("instructions", .string(Self.instructions)),
                ])
            )
        case "notifications/initialized":
            return
        case "tools/list":
            emit(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    ("tools", .array(MCPToolRegistry.tools.map(\.orderedJSONValue))),
                ])
            )
        case "tools/call":
            handleToolCall(request)
        default:
            emitError(id: request.id, code: -32601, message: "Method not found")
        }
    }

    private func handleToolCall(_ request: JSONRPCRequest) {
        guard let params = request.params?.objectValue,
              let name = params["name"]?.stringValue else {
            emitError(id: request.id, code: -32602, message: "Invalid params")
            return
        }
        let arguments = params["arguments"]?.objectValue ?? [:]

        // TODO(swift6-async-loop): replace DispatchSemaphore with an async stdin loop.
        let semaphore = DispatchSemaphore(value: 0)
        var response: OrderedJSONValue?
        Task {
            response = await handleToolCall(name: name, arguments: arguments)
            semaphore.signal()
        }
        semaphore.wait()
        emit(
            jsonrpc: "2.0",
            id: request.id,
            result: response ?? .object([("content", .array([])), ("isError", .bool(true))])
        )
    }

    private func handleToolCall(
        name: String,
        arguments: [String: JSONValue]
    ) async -> OrderedJSONValue {
        do {
            return try await MCPToolRegistry.handle(
                tool: name,
                arguments: arguments,
                config: config
            )
        } catch {
            return .toolError(message: error.localizedDescription)
        }
    }

    private func emit(jsonrpc: String, id: JSONRPCId?, result: OrderedJSONValue) {
        var entries: [(String, OrderedJSONValue)] = [("jsonrpc", .string(jsonrpc))]
        if let id {
            entries.append(("id", id.orderedJSONValue))
        }
        entries.append(("result", result))
        print(OrderedJSONValue.object(entries).compactJSONString())
        fflush(stdout)
    }

    private func emitError(id: JSONRPCId?, code: Int, message: String) {
        var entries: [(String, OrderedJSONValue)] = [("jsonrpc", .string("2.0"))]
        if let id {
            entries.append(("id", id.orderedJSONValue))
        }
        entries.append((
            "error",
            .object([
                ("code", .int(code)),
                ("message", .string(message)),
            ])
        ))
        print(OrderedJSONValue.object(entries).compactJSONString())
        fflush(stdout)
    }
}
