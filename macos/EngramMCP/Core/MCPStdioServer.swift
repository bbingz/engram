import Foundation

final class MCPStdioServer {
    private let config = MCPConfig.load()
    private let inFlight = MCPInFlightRequests()
    private let outputLock = NSLock()
    private static let supportedProtocolVersions: Set<String> = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18",
        "2025-11-25",
    ]
    // Latest protocol version this build speaks. Date-stamped MCP versions
    // sort chronologically as strings, so `max()` is the newest. Used to
    // negotiate down when a client requests a version we don't recognize.
    private static let latestSupportedProtocolVersion =
        supportedProtocolVersions.max() ?? "2025-11-25"
    private static let instructions = """
    Engram is a cross-tool AI session aggregator. Key tools:
    - search: Full-text keyword search across all AI coding sessions (17 sources)
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

    func run() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let requestData = trimmed.data(using: .utf8),
                      let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: requestData) else {
                    emitError(id: nil, code: -32700, message: "Parse error", includeNullID: true)
                    continue
                }
                if request.method == "notifications/cancelled" {
                    await handleCancellation(request)
                    continue
                }
                guard request.id != nil else {
                    continue
                }
                if request.method == "tools/call", request.id != nil {
                    await handleToolCallAsync(request)
                    continue
                }
                await handle(request)
            }
        } catch {
            // stdin closed or unreadable; exit the loop quietly.
        }
        await inFlight.waitForAll()
    }

    private func handleCancellation(_ request: JSONRPCRequest) async {
        guard let key = Self.cancellationKey(from: request.params?["requestId"]) else {
            return
        }
        await inFlight.cancel(key)
    }

    private func handleToolCallAsync(_ request: JSONRPCRequest) async {
        guard let id = request.id,
              let key = Self.cancellationKey(from: id) else {
            await handleToolCall(request)
            return
        }
        guard let params = request.params?.objectValue,
              let name = params["name"]?.stringValue else {
            emitError(id: request.id, code: -32602, message: "Invalid params")
            return
        }
        let arguments = params["arguments"]?.objectValue ?? [:]
        let didStart = await inFlight.start(for: key) { [weak self] in
            guard let self else { return }
            let response = await handleToolCall(name: name, arguments: arguments)
            guard !Task.isCancelled else { return }
            emit(
                jsonrpc: "2.0",
                id: id,
                result: response
            )
        }
        if !didStart {
            emitError(id: id, code: -32600, message: "Duplicate request id")
        }
    }

    private func handle(_ request: JSONRPCRequest) async {
        switch request.method {
        case "initialize":
            guard let requestedVersion = request.params?["protocolVersion"]?.stringValue else {
                emitError(id: request.id, code: -32602, message: "Missing protocolVersion")
                return
            }
            // Per the MCP spec, the server echoes the requested version when it
            // supports it, otherwise responds with a version it does support
            // (the latest). Hard-erroring on an unknown version broke every
            // connection whenever a client adopted a newer protocol version
            // than this build knew about (e.g. Claude Code's 2025-11-25).
            let negotiatedVersion = Self.supportedProtocolVersions.contains(requestedVersion)
                ? requestedVersion
                : Self.latestSupportedProtocolVersion
            emit(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    ("protocolVersion", .string(negotiatedVersion)),
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
        case "ping":
            emit(jsonrpc: "2.0", id: request.id, result: .object([]))
        case "tools/list":
            emit(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    ("tools", .array(MCPToolRegistry.tools.map(\.orderedJSONValue))),
                ])
            )
        case "tools/call":
            await handleToolCall(request)
        default:
            emitError(id: request.id, code: -32601, message: "Method not found")
        }
    }

    private func handleToolCall(_ request: JSONRPCRequest) async {
        guard let params = request.params?.objectValue,
              let name = params["name"]?.stringValue else {
            emitError(id: request.id, code: -32602, message: "Invalid params")
            return
        }
        let arguments = params["arguments"]?.objectValue ?? [:]
        let response = await handleToolCall(name: name, arguments: arguments)
        emit(
            jsonrpc: "2.0",
            id: request.id,
            result: response
        )
    }

    private func handleToolCall(
        name: String,
        arguments: [String: JSONValue]
    ) async -> OrderedJSONValue {
        do {
            try Task.checkCancellation()
            let response = try await MCPToolRegistry.handle(
                tool: name,
                arguments: arguments,
                config: config
            )
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            return .toolError(
                message: "Request cancelled by client.",
                code: "cancelled"
            )
        } catch let error as MCPToolError {
            return .toolError(
                message: error.localizedDescription,
                code: error.structuredCode
            )
        } catch {
            return .toolError(message: error.localizedDescription)
        }
    }

    private static func cancellationKey(from id: JSONRPCId) -> String? {
        switch id {
        case .string(let value):
            return "s:\(value)"
        case .number(let value):
            return "n:\(value)"
        }
    }

    private static func cancellationKey(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let raw):
            return "s:\(raw)"
        case .int(let raw):
            return "n:\(raw)"
        default:
            return nil
        }
    }

    private func emit(jsonrpc: String, id: JSONRPCId?, result: OrderedJSONValue) {
        var entries: [(String, OrderedJSONValue)] = [("jsonrpc", .string(jsonrpc))]
        if let id {
            entries.append(("id", id.orderedJSONValue))
        }
        entries.append(("result", result))
        outputLock.lock()
        defer { outputLock.unlock() }
        print(OrderedJSONValue.object(entries).compactJSONString())
        fflush(stdout)
    }

    private func emitError(
        id: JSONRPCId?,
        code: Int,
        message: String,
        includeNullID: Bool = false
    ) {
        var entries: [(String, OrderedJSONValue)] = [("jsonrpc", .string("2.0"))]
        if let id {
            entries.append(("id", id.orderedJSONValue))
        } else if includeNullID {
            entries.append(("id", .null))
        }
        entries.append((
            "error",
            .object([
                ("code", .int(code)),
                ("message", .string(message)),
            ])
        ))
        outputLock.lock()
        defer { outputLock.unlock() }
        print(OrderedJSONValue.object(entries).compactJSONString())
        fflush(stdout)
    }
}

private actor MCPInFlightRequests {
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(for key: String, operation: @escaping @Sendable () async -> Void) -> Bool {
        guard tasks[key] == nil else { return false }
        let task = Task { [weak self] in
            await operation()
            await self?.remove(key)
        }
        tasks[key] = task
        return true
    }

    func cancel(_ key: String) {
        tasks[key]?.cancel()
    }

    func remove(_ key: String) {
        tasks.removeValue(forKey: key)
    }

    func waitForAll() async {
        let current = Array(tasks.values)
        for task in current {
            await task.value
        }
    }
}
