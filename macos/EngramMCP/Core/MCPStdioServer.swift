import Foundation

final class MCPStdioServer {
    private let config = MCPConfig.load()

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
                        ("tools", .object([
                            ("listChanged", .bool(false)),
                        ])),
                    ])),
                    ("serverInfo", .object([
                        ("name", .string("engram")),
                        ("version", .string("0.1.0")),
                    ])),
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
