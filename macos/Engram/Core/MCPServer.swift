// macos/Engram/Core/MCPServer.swift
import Foundation
import Hummingbird
import NIOCore
import Logging

@MainActor
class MCPServer: ObservableObject {
    @Published var isRunning = false

    private let tools: MCPTools
    private let port: Int
    private let socketPath: String
    private var serverTask: Task<Void, Error>?

    init(tools: MCPTools, port: Int = 3456, socketPath: String = "/tmp/engram.sock") {
        self.tools = tools
        self.port = port
        self.socketPath = socketPath
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        try? FileManager.default.removeItem(atPath: socketPath)

        let tools = self.tools
        let port  = self.port
        let sock  = self.socketPath

        serverTask = Task.detached {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await MCPServer.runHTTP(tools: tools, address: .hostname("127.0.0.1", port: port))
                }
                group.addTask {
                    try await MCPServer.runHTTP(tools: tools, address: .unixDomainSocket(path: sock))
                }
                try await group.waitForAll()
            }
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
        isRunning = false
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private static func runHTTP(tools: MCPTools, address: BindAddress) async throws {
        var logger = Logger(label: "engram.mcp")
        logger.logLevel = .warning

        let router = Router()

        // POST /mcp — JSON-RPC handler
        router.post("/mcp") { request, context in
            var req = request
            let body = try await req.collectBody(upTo: 1024 * 1024) // 1 MB max
            let data = Data(buffer: body)

            // Decode JSON-RPC request
            let rpcRequest: JSONRPCRequest
            do {
                rpcRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
            } catch {
                let errResp = JSONRPCResponse.err(id: nil, code: -32700, message: "Parse error: \(error)")
                return try MCPServer.jsonResponse(errResp)
            }

            // Dispatch on MainActor
            let rpcResponse: JSONRPCResponse
            do {
                let result = try await MainActor.run {
                    try tools.handle(method: rpcRequest.method, params: rpcRequest.params)
                }
                rpcResponse = JSONRPCResponse.ok(id: rpcRequest.id, result: result)
            } catch let e as MCPError {
                switch e {
                case .methodNotFound(let m):
                    rpcResponse = JSONRPCResponse.err(id: rpcRequest.id, code: -32601, message: "Method not found: \(m)")
                case .toolNotFound(let t):
                    rpcResponse = JSONRPCResponse.err(id: rpcRequest.id, code: -32601, message: "Tool not found: \(t)")
                case .invalidParams(let msg):
                    rpcResponse = JSONRPCResponse.err(id: rpcRequest.id, code: -32602, message: "Invalid params: \(msg)")
                }
            } catch {
                rpcResponse = JSONRPCResponse.err(id: rpcRequest.id, code: -32603, message: "Internal error: \(error)")
            }

            return try MCPServer.jsonResponse(rpcResponse)
        }

        // GET /mcp/sse — not implemented
        router.get("/mcp/sse") { _, _ in
            Response(status: .notImplemented, headers: [:], body: .init())
        }

        let app = Application(
            router: router,
            configuration: ApplicationConfiguration(address: address),
            logger: logger
        )

        // run() drives the server; it returns when task is cancelled
        try await app.run()
    }

    private nonisolated static func jsonResponse(_ value: some Encodable) throws -> Response {
        let data = try JSONEncoder().encode(value)
        let buffer = ByteBuffer(data: data)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.contentLength] = String(data.count)
        return Response(
            status: .ok,
            headers: headers,
            body: ResponseBody(byteBuffer: buffer)
        )
    }
}
