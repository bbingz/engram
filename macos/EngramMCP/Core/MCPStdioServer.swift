import Foundation

final class MCPStdioServer {
    private let config = MCPConfig.load()
    private let inFlight = MCPInFlightRequests()
    private let outputLock = NSLock()
    // Legacy (initialize-handshake) protocol revisions this build speaks.
    // MCP 2026-07-28 and later are "modern" revisions negotiated per request
    // via `_meta` (see `modernProtocolVersions`), not through `initialize`.
    private static let supportedProtocolVersions: Set<String> = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18",
        "2025-11-25",
    ]
    // Latest legacy protocol version this build speaks. Date-stamped MCP
    // versions sort chronologically as strings, so `max()` is the newest.
    // Used to negotiate down when a client requests a version we don't
    // recognize over the `initialize` handshake.
    private static let latestSupportedProtocolVersion =
        supportedProtocolVersions.max() ?? "2025-11-25"
    // Modern (stateless, per-request `_meta`) protocol revisions this build
    // speaks. Requests that carry
    // `_meta["io.modelcontextprotocol/protocolVersion"]` are served under
    // modern semantics; requests without it keep legacy behavior, making this
    // a dual-era server per MCP 2026-07-28 versioning guidance.
    private static let modernProtocolVersions: Set<String> = [
        "2026-07-28",
    ]
    // Every revision this build supports across both eras, newest first.
    // Advertised by `server/discover` alone: it answers before era detection as
    // the backward-compatibility probe, so naming the legacy revisions there
    // tells a client it can fall back to the `initialize` handshake.
    // UnsupportedProtocolVersionError reports `modernProtocolVersions` instead.
    private static let advertisedProtocolVersions: [String] =
        modernProtocolVersions.union(supportedProtocolVersions).sorted(by: >)
    private static let serverInfoJSON: OrderedJSONValue = .object([
        ("name", .string("engram")),
        ("version", .string("0.1.0")),
    ])
    private static let capabilitiesJSON: OrderedJSONValue = .object([
        ("tools", .object([])),
        ("resources", .object([])),
        ("prompts", .object([])),
    ])
    // CacheableResult freshness hints (MCP 2026-07-28). Everything this
    // server returns is local per-user data, so `cacheScope` is always
    // "private". `tools/list` can change when semantic search availability
    // flips; resource surfaces churn as sessions index.
    private static let cacheScope = "private"
    private static let discoverTTLMs = 3_600_000
    private static let toolsListTTLMs = 300_000
    private static let promptsListTTLMs = 3_600_000
    private static let resourceTTLMs = 30_000
    private static let instructions = """
    Engram is a cross-tool AI session aggregator. Key tools:
    - search: Full-text keyword search across AI coding sessions; semantic/hybrid when session embeddings are usable
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
                let modern: Bool
                switch Self.era(of: request) {
                case .legacy:
                    modern = false
                case .modern:
                    modern = true
                case .unsupportedModern(let requested):
                    emitUnsupportedProtocolVersion(id: request.id, requested: requested)
                    continue
                }
                if request.method == "server/discover" {
                    // stdio backward-compatibility probe (MCP 2026-07-28):
                    // answer with or without supported `_meta`, after rejecting
                    // any explicitly unsupported modern protocol version.
                    emitDiscoverResult(id: request.id)
                    continue
                }
                if request.method == "tools/call" {
                    await handleToolCallAsync(request, modern: modern)
                    continue
                }
                await handle(request, modern: modern)
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

    private enum RequestEra {
        case legacy
        case modern
        case unsupportedModern(requested: String)
    }

    // The `_meta` key whose *presence* inside an object-valued `_meta` signals
    // modern-era intent. A non-object `params` or `_meta` cannot carry it, so
    // those requests stay legacy.
    private static let protocolVersionMetaKey = "io.modelcontextprotocol/protocolVersion"

    private static func era(of request: JSONRPCRequest) -> RequestEra {
        guard let requested = request.params?["_meta"]?[protocolVersionMetaKey] else {
            return .legacy
        }
        guard let version = requested.stringValue else {
            // The key is present, so the client asserted modern semantics; a
            // non-string value simply names no revision. Report it instead of
            // demoting the request to legacy, which answered a modern client
            // with an un-enveloped result (MCP retro F13, retro PR-4).
            return .unsupportedModern(requested: invalidVersionDescription(requested))
        }
        return modernProtocolVersions.contains(version)
            ? .modern
            : .unsupportedModern(requested: version)
    }

    /// Name the JSON type of a `_meta` protocol version that is not a string,
    /// so the -32022 payload describes what arrived rather than nothing.
    private static func invalidVersionDescription(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "<null>"
        case .bool:
            return "<bool>"
        case .int, .double:
            return "<number>"
        case .array:
            return "<array>"
        case .object:
            return "<object>"
        case .string(let version):
            return version
        }
    }

    private func handleToolCallAsync(_ request: JSONRPCRequest, modern: Bool) async {
        guard let id = request.id,
              let key = Self.cancellationKey(from: id) else {
            await handleToolCall(request, modern: modern)
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
            emitResult(id: id, response, modern: modern)
        }
        if !didStart {
            emitError(id: id, code: -32600, message: "Duplicate request id")
        }
    }

    private func handle(_ request: JSONRPCRequest, modern: Bool) async {
        switch request.method {
        case "initialize":
            if modern {
                // Modern revisions removed the handshake, so there is no
                // negotiated connection version to hand back and `initialize`
                // is simply not a method this era defines. Answering it also
                // escaped the modern result envelope (MCP retro F14, retro
                // PR-4); the remote endpoint refuses it the same way.
                emitError(id: request.id, code: -32601, message: "Method not found")
                return
            }
            guard let requestedVersion = request.params?["protocolVersion"]?.stringValue else {
                emitError(id: request.id, code: -32602, message: "Missing protocolVersion")
                return
            }
            // Per the MCP spec, the server echoes the requested version when it
            // supports it, otherwise responds with a version it does support
            // (the latest). Hard-erroring on an unknown version broke every
            // connection whenever a client adopted a newer protocol version
            // than this build knew about (e.g. Claude Code's 2025-11-25).
            // Modern revisions (2026-07-28+) never negotiate through
            // `initialize`, so an unknown-version request here still lands on
            // the latest legacy revision.
            let negotiatedVersion = Self.supportedProtocolVersions.contains(requestedVersion)
                ? requestedVersion
                : Self.latestSupportedProtocolVersion
            emit(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    ("protocolVersion", .string(negotiatedVersion)),
                    ("capabilities", Self.capabilitiesJSON),
                    ("serverInfo", Self.serverInfoJSON),
                    ("instructions", .string(Self.instructions)),
                ])
            )
        case "notifications/initialized":
            return
        case "ping":
            // Removed from the 2026-07-28 core spec, but kept answering in
            // both eras: era-ambiguous liveness probes must not kill the
            // transport, and legacy clients still depend on it.
            emitResult(id: request.id, .object([]), modern: modern)
        case "tools/list":
            // Search mode enum is gated by SessionVectorSearchAvailability on
            // the configured MCP database (semantic/hybrid only when usable).
            emitResult(
                id: request.id,
                .object([
                    ("tools", .array(MCPToolRegistry.tools(dbPath: config.dbPath).map(\.orderedJSONValue))),
                ]),
                modern: modern,
                cacheTTLMs: Self.toolsListTTLMs
            )
        case "tools/call":
            await handleToolCall(request, modern: modern)
        case "resources/list":
            await emitRegistryResult(id: request.id, modern: modern, cacheTTLMs: Self.resourceTTLMs) {
                try await MCPToolRegistry.resourcesList(config: config)
            }
        case "resources/read":
            guard let uri = request.params?["uri"]?.stringValue, !uri.isEmpty else {
                emitError(id: request.id, code: -32602, message: "Missing uri")
                return
            }
            await emitRegistryResult(id: request.id, modern: modern, cacheTTLMs: Self.resourceTTLMs) {
                try await MCPToolRegistry.resourceRead(uri: uri, config: config)
            }
        case "prompts/list":
            emitResult(
                id: request.id,
                MCPToolRegistry.promptsList(),
                modern: modern,
                cacheTTLMs: Self.promptsListTTLMs
            )
        case "prompts/get":
            guard let name = request.params?["name"]?.stringValue, !name.isEmpty else {
                emitError(id: request.id, code: -32602, message: "Missing prompt name")
                return
            }
            let arguments = request.params?["arguments"]?.objectValue ?? [:]
            await emitRegistryResult(id: request.id, modern: modern) {
                try await MCPToolRegistry.promptGet(name: name, arguments: arguments, config: config)
            }
        default:
            emitError(id: request.id, code: -32601, message: "Method not found")
        }
    }

    /// Run a `resources/*` or `prompts/*` registry operation and emit either a
    /// JSON-RPC result or a JSON-RPC error (invalid params for `MCPToolError`).
    private func emitRegistryResult(
        id: JSONRPCId?,
        modern: Bool,
        cacheTTLMs: Int? = nil,
        _ operation: () async throws -> OrderedJSONValue
    ) async {
        do {
            let result = try await operation()
            emitResult(id: id, result, modern: modern, cacheTTLMs: cacheTTLMs)
        } catch let error as MCPToolError {
            emitError(id: id, code: -32602, message: error.localizedDescription)
        } catch {
            emitError(id: id, code: -32603, message: error.localizedDescription)
        }
    }

    private func handleToolCall(_ request: JSONRPCRequest, modern: Bool) async {
        guard let params = request.params?.objectValue,
              let name = params["name"]?.stringValue else {
            emitError(id: request.id, code: -32602, message: "Invalid params")
            return
        }
        let arguments = params["arguments"]?.objectValue ?? [:]
        let response = await handleToolCall(name: name, arguments: arguments)
        emitResult(id: request.id, response, modern: modern)
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

    /// Emit a JSON-RPC result, wrapping it in the MCP 2026-07-28 result
    /// envelope when the request was made under a modern protocol revision.
    private func emitResult(
        id: JSONRPCId?,
        _ result: OrderedJSONValue,
        modern: Bool,
        cacheTTLMs: Int? = nil
    ) {
        emit(
            jsonrpc: "2.0",
            id: id,
            result: modern ? Self.modernResult(result, cacheTTLMs: cacheTTLMs) : result
        )
    }

    /// Wrap a legacy result body per MCP 2026-07-28: the required
    /// `resultType` discriminator first, CacheableResult fields for the
    /// list/read methods that require them, and the server identity in
    /// `_meta` (stateless clients have no initialize result to read it from).
    private static func modernResult(
        _ result: OrderedJSONValue,
        cacheTTLMs: Int?
    ) -> OrderedJSONValue {
        guard case .object(let entries) = result else { return result }
        var wrapped: [(String, OrderedJSONValue)] = [("resultType", .string("complete"))]
        wrapped.append(contentsOf: entries)
        if let cacheTTLMs {
            wrapped.append(("ttlMs", .int(cacheTTLMs)))
            wrapped.append(("cacheScope", .string(cacheScope)))
        }
        wrapped.append(("_meta", .object([
            ("io.modelcontextprotocol/serverInfo", serverInfoJSON),
        ])))
        return .object(wrapped)
    }

    private func emitDiscoverResult(id: JSONRPCId?) {
        emit(
            jsonrpc: "2.0",
            id: id,
            result: .object([
                ("resultType", .string("complete")),
                ("supportedVersions", .array(Self.advertisedProtocolVersions.map { .string($0) })),
                ("capabilities", Self.capabilitiesJSON),
                ("instructions", .string(Self.instructions)),
                ("ttlMs", .int(Self.discoverTTLMs)),
                ("cacheScope", .string(Self.cacheScope)),
                ("_meta", .object([
                    ("io.modelcontextprotocol/serverInfo", Self.serverInfoJSON),
                ])),
            ])
        )
    }

    private func emitUnsupportedProtocolVersion(id: JSONRPCId?, requested: String) {
        emitError(
            id: id,
            code: -32022,
            message: "Unsupported protocol version",
            data: .object([
                // Modern revisions only. This error fires on the per-request
                // `_meta` channel, and a legacy revision can never be selected
                // through it — advertising the cross-era union told clients to
                // retry with a revision that gets the identical rejection
                // (MCP retro F02, retro PR-4). `server/discover` still reports
                // the union: there it is the backward-compatibility probe's
                // answer, and falling back to the handshake is a real option.
                ("supported", .array(Self.modernProtocolVersions.sorted(by: >).map { .string($0) })),
                ("requested", .string(requested)),
            ])
        )
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
        data: OrderedJSONValue? = nil,
        includeNullID: Bool = false
    ) {
        var entries: [(String, OrderedJSONValue)] = [("jsonrpc", .string("2.0"))]
        if let id {
            entries.append(("id", id.orderedJSONValue))
        } else if includeNullID {
            entries.append(("id", .null))
        }
        var errorEntries: [(String, OrderedJSONValue)] = [
            ("code", .int(code)),
            ("message", .string(message)),
        ]
        if let data {
            errorEntries.append(("data", data))
        }
        entries.append(("error", .object(errorEntries)))
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
