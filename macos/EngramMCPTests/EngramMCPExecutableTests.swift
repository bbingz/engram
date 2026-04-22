import Foundation
import Network
import XCTest

final class EngramMCPExecutableTests: XCTestCase {
    func testToolsListHasTemplateFloor() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """
        )

        guard case .array(let tools)? = capture.ordered["result"]?["tools"] else {
            XCTFail("Expected tools/list result.tools array")
            return
        }
        XCTAssertGreaterThanOrEqual(tools.count, 3)
        // TODO(mcp-bulk-port): switch to XCTAssertEqual(..., 26) when all tools land.
    }

    func testInitializeReturnsServerCapabilities() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"XCTest","version":"1.0"}}}
            """
        )

        let response = capture.response
        XCTAssertEqual(response.error?.code, nil)
        XCTAssertNotNil(response.result)
    }

    func testStatsMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "stats",
            arguments: """
            {"group_by":"source","since":"2026-01-01T00:00:00.000Z"}
            """,
            goldenFixture: "mcp-golden/stats.source.json"
        )
    }

    func testListSessionsMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "list_sessions",
            arguments: """
            {"project":"engram","since":"2026-01-01T00:00:00.000Z","limit":4,"offset":0}
            """,
            goldenFixture: "mcp-golden/list_sessions.engram.json"
        )
    }

    func testGetCostsMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "get_costs",
            arguments: """
            {"group_by":"project","since":"2026-01-01T00:00:00.000Z"}
            """,
            goldenFixture: "mcp-golden/get_costs.project.json"
        )
    }

    func testToolAnalyticsMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "tool_analytics",
            arguments: """
            {"group_by":"tool","since":"2026-01-01T00:00:00.000Z"}
            """,
            goldenFixture: "mcp-golden/tool_analytics.tool.json"
        )
    }

    func testFileActivityMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "file_activity",
            arguments: """
            {"project":"engram","since":"2026-01-01T00:00:00.000Z","limit":4}
            """,
            goldenFixture: "mcp-golden/file_activity.engram.json"
        )
    }

    func testProjectTimelineMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "project_timeline",
            arguments: """
            {"project":"engram","since":"2026-01-01T00:00:00.000Z"}
            """,
            goldenFixture: "mcp-golden/project_timeline.engram.json"
        )
    }

    func testProjectListMigrationsMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "project_list_migrations",
            arguments: """
            {"since":"2026-03-01T00:00:00.000Z","limit":3}
            """,
            goldenFixture: "mcp-golden/project_list_migrations.recent.json"
        )
    }

    func testLiveSessionsMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "live_sessions",
            arguments: "{}",
            goldenFixture: "mcp-golden/live_sessions.unavailable.json"
        )
    }

    func testGetMemoryMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "get_memory",
            arguments: """
            {"query":"single writer daemon HTTP"}
            """,
            goldenFixture: "mcp-golden/get_memory.keyword.json"
        )
    }

    func testSearchMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "search",
            arguments: """
            {"query":"Swift MCP shim","mode":"keyword","limit":5}
            """,
            goldenFixture: "mcp-golden/search.keyword.json"
        )
    }

    func testGetContextMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "get_context",
            arguments: """
            {"cwd":"/Users/test/work/engram","task":"port engram mcp shim to swift","include_environment":false,"sort_by":"score"}
            """,
            goldenFixture: "mcp-golden/get_context.engram.json"
        )
    }

    func testGetInsightsMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "get_insights",
            arguments: """
            {"since":"2026-02-15T00:00:00.000Z"}
            """,
            goldenFixture: "mcp-golden/get_insights.empty.json"
        )
    }

    func testLintConfigMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "lint_config",
            arguments: """
            {"cwd":"\(fixturePath("mcp-runtime/lint-project"))"}
            """,
            goldenFixture: "mcp-golden/lint_config.fixture.json"
        )
    }

    func testLinkSessionsMatchesGolden() throws {
        let conversationLogDir = fixturePath("mcp-runtime/engram/conversation_log")
        try? FileManager.default.removeItem(atPath: conversationLogDir)
        try assertToolCallMatchesGolden(
            tool: "link_sessions",
            arguments: """
            {"targetDir":"\(fixturePath("mcp-runtime/engram"))"}
            """,
            goldenFixture: "mcp-golden/link_sessions.engram.json"
        )
    }

    func testProjectReviewMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "project_review",
            arguments: """
            {"old_path":"/Users/test/work/engram-old","new_path":"/Users/test/work/engram-v2","max_items":100}
            """,
            goldenFixture: "mcp-golden/project_review.fixture.json",
            environment: [
                "HOME": fixturePath("mcp-runtime/review-home"),
            ]
        )
    }

    func testGetSessionMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "get_session",
            arguments: """
            {"id":"mcp-transcript-01","page":1}
            """,
            goldenFixture: "mcp-golden/get_session.transcript.json"
        )
    }

    func testExportMatchesGolden() throws {
        let exportDir = fixturePath("mcp-runtime/export-home/codex-exports")
        try? FileManager.default.removeItem(atPath: exportDir)
        try assertToolCallMatchesGolden(
            tool: "export",
            arguments: """
            {"id":"mcp-transcript-01","format":"json"}
            """,
            goldenFixture: "mcp-golden/export.transcript.json",
            environment: [
                "HOME": fixturePath("mcp-runtime/export-home"),
            ]
        )
    }

    func testHandoffMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "handoff",
            arguments: """
            {"cwd":"/Users/test/work/missing-project","format":"markdown"}
            """,
            goldenFixture: "mcp-golden/handoff.empty.json"
        )
    }

    func testSaveInsightMatchesGoldenViaDaemonHTTP() throws {
        let goldenPath = fixturePath("mcp-golden/save_insight.text_only.json")
        let goldenData = try Data(contentsOf: URL(fileURLWithPath: goldenPath))
        let goldenObject = try JSONDecoder().decode(TestJSONValue.self, from: goldenData)
        let structured = try XCTUnwrap(goldenObject["structuredContent"])

        let server = try MockDaemonServer { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api/insight")
            let body = try request.decodeBody([String: TestJSONValue].self)
            XCTAssertEqual(body["actor"]?.stringValue, "mcp")
            XCTAssertEqual(body["wing"]?.stringValue, "engram")
            XCTAssertEqual(body["room"]?.stringValue, "mcp-swift")
            return .json(statusCode: 200, body: structured)
        }
        try server.start()
        defer { server.stop() }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"save_insight","arguments":{"content":"Swift MCP contract tests should use deterministic fixture databases and byte-stable JSON golden files.","wing":"engram","room":"mcp-swift","importance":5,"source_session_id":"mcp-fixture-01"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
                "ENGRAM_MCP_DAEMON_BASE_URL": server.baseURL.absoluteString,
            ]
        )

        let actual = try normalizeUUIDs(in: prettyJSONString(from: XCTUnwrap(capture.ordered["result"])))
        let expected = try String(contentsOfFile: goldenPath, encoding: .utf8)
        XCTAssertEqual(actual, expected)
    }

    func testManageProjectAliasRoutesReadAndWriteModes() throws {
        let fixtureDB = fixturePath("mcp-contract.sqlite")

        let listCapture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"manage_project_alias","arguments":{"action":"list"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixtureDB,
            ]
        )
        let listActual = try prettyJSONString(from: XCTUnwrap(listCapture.ordered["result"]))
        let listExpected = try String(contentsOfFile: fixturePath("mcp-golden/manage_project_alias.list.json"), encoding: .utf8)
        XCTAssertEqual(listActual, listExpected)

        let addGolden = try Data(contentsOf: URL(fileURLWithPath: fixturePath("mcp-golden/manage_project_alias.add.json")))
        let addStructured = try XCTUnwrap(try JSONDecoder().decode(TestJSONValue.self, from: addGolden)["structuredContent"])
        let removeGolden = try Data(contentsOf: URL(fileURLWithPath: fixturePath("mcp-golden/manage_project_alias.remove.json")))
        let removeStructured = try XCTUnwrap(try JSONDecoder().decode(TestJSONValue.self, from: removeGolden)["structuredContent"])
        var seenPaths: [String] = []

        let server = try MockDaemonServer { request in
            seenPaths.append("\(request.method) \(request.path)")
            let body = try request.decodeBody([String: TestJSONValue].self)
            XCTAssertEqual(body["actor"]?.stringValue, "mcp")
            switch (request.method, request.path) {
            case ("POST", "/api/project-aliases"):
                return .json(statusCode: 200, body: addStructured)
            case ("DELETE", "/api/project-aliases"):
                return .json(statusCode: 200, body: removeStructured)
            default:
                XCTFail("Unexpected request \(request.method) \(request.path)")
                return .json(statusCode: 500, body: .object([:]))
            }
        }
        try server.start()
        defer { server.stop() }

        let addCapture = try rpc(
            """
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"manage_project_alias","arguments":{"action":"add","old_project":"apollo-next","new_project":"apollo"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixtureDB,
                "ENGRAM_MCP_DAEMON_BASE_URL": server.baseURL.absoluteString,
            ]
        )
        XCTAssertEqual(
            try prettyJSONString(from: XCTUnwrap(addCapture.ordered["result"])),
            try String(contentsOfFile: fixturePath("mcp-golden/manage_project_alias.add.json"), encoding: .utf8)
        )

        let removeCapture = try rpc(
            """
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"manage_project_alias","arguments":{"action":"remove","old_project":"apollo-next","new_project":"apollo"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixtureDB,
                "ENGRAM_MCP_DAEMON_BASE_URL": server.baseURL.absoluteString,
            ]
        )
        XCTAssertEqual(
            try prettyJSONString(from: XCTUnwrap(removeCapture.ordered["result"])),
            try String(contentsOfFile: fixturePath("mcp-golden/manage_project_alias.remove.json"), encoding: .utf8)
        )
        XCTAssertEqual(seenPaths, ["POST /api/project-aliases", "DELETE /api/project-aliases"])
    }

    private func rpc(_ request: String, environment: [String: String] = [:]) throws -> RPCCapture {
        let process = Process()
        process.executableURL = executableURL()
        process.environment = ProcessInfo.processInfo.environment
            .merging(["TZ": "UTC"]) { _, new in new }
            .merging(environment) { _, new in new }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()

        if let data = "\(request)\n".data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = try XCTUnwrap(String(data: outputData, encoding: .utf8))
        let firstLine = try XCTUnwrap(output.split(separator: "\n").first.map(String.init))
        let responseData = try XCTUnwrap(firstLine.data(using: .utf8))
        var parser = OrderedTestJSONParser(text: firstLine)
        return RPCCapture(
            rawLine: firstLine,
            response: try JSONDecoder().decode(TestJSONRPCResponse.self, from: responseData),
            ordered: try parser.parse()
        )
    }

    private func executableURL() -> URL {
        Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("EngramMCP")
    }

    private func fixturePath(_ relativePath: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures")
            .appendingPathComponent(relativePath)
            .path
    }

    private func prettyJSONString(from value: OrderedTestJSONValue) throws -> String {
        value.prettyJSONString() + "\n"
    }

    private func assertToolCallMatchesGolden(
        tool: String,
        arguments: String,
        goldenFixture: String,
        environment: [String: String] = [:]
    ) throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\(tool)","arguments":\(arguments)}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
            ].merging(environment) { _, new in new }
        )
        let actual = try prettyJSONString(from: XCTUnwrap(capture.ordered["result"]))
        let expected = try String(contentsOfFile: fixturePath(goldenFixture), encoding: .utf8)
        XCTAssertEqual(actual, expected)
    }

    private func normalizeUUIDs(in text: String) throws -> String {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<generated-uuid>")
    }
}

private final class MockDaemonServer {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(T.self, from: body)
        }
    }

    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        static func json(statusCode: Int, body: TestJSONValue) -> Response {
            let data = Data(body.compactJSONString().utf8)
            return Response(
                statusCode: statusCode,
                headers: [
                    "Content-Type": "application/json",
                    "Content-Length": "\(data.count)",
                ],
                body: data
            )
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MockDaemonServer")
    private let handler: (Request) throws -> Response
    private let readyExpectation = XCTestExpectation(description: "mock daemon ready")

    init(handler: @escaping (Request) throws -> Response) throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        self.handler = handler
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }

    func start() throws {
        listener.stateUpdateHandler = { [readyExpectation] state in
            if case .ready = state {
                readyExpectation.fulfill()
            }
        }
        listener.newConnectionHandler = { [handler, queue] connection in
            connection.start(queue: queue)
            Self.receiveRequest(on: connection, handler: handler)
        }
        listener.start(queue: queue)
        let result = XCTWaiter.wait(for: [readyExpectation], timeout: 2)
        if result != .completed {
            throw NSError(domain: "MockDaemonServer", code: 1)
        }
    }

    func stop() {
        listener.cancel()
    }

    private static func receiveRequest(
        on connection: NWConnection,
        handler: @escaping (Request) throws -> Response
    ) {
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data {
                    buffer.append(data)
                }
                if let request = parseRequest(from: buffer) {
                    let response = (try? handler(request)) ?? .json(statusCode: 500, body: .object([:]))
                    send(response: response, on: connection)
                    return
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    private static func parseRequest(from data: Data) -> Request? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: delimiter) else { return nil }
        let headerData = data[..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            headers[String(pieces[0]).lowercased()] = String(pieces[1]).trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        let body = data[bodyStart...]
        guard body.count >= contentLength else { return nil }
        return Request(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: Data(body.prefix(contentLength))
        )
    }

    private static func send(response: Response, on connection: NWConnection) {
        let reason = response.statusCode == 200 ? "OK" : "Error"
        var headerLines = ["HTTP/1.1 \(response.statusCode) \(reason)"]
        for (key, value) in response.headers {
            headerLines.append("\(key): \(value)")
        }
        headerLines.append("")
        headerLines.append("")
        var payload = Data(headerLines.joined(separator: "\r\n").utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private enum TestJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([TestJSONValue])
    case object([String: TestJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TestJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: TestJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                TestJSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    subscript(key: String) -> TestJSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

private struct TestJSONRPCResponse: Decodable {
    let jsonrpc: String
    let id: TestJSONRPCID?
    let result: TestJSONValue?
    let error: TestJSONRPCError?
}

private enum TestJSONRPCID: Decodable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .number(try container.decode(Int.self))
        }
    }
}

private struct TestJSONRPCError: Decodable {
    let code: Int
    let message: String
}

private struct RPCCapture {
    let rawLine: String
    let response: TestJSONRPCResponse
    let ordered: OrderedTestJSONValue
}

private extension TestJSONValue {
    func prettyJSONString() -> String {
        jsonString(pretty: true)
    }

    func compactJSONString() -> String {
        jsonString(pretty: false)
    }

    private func jsonString(pretty: Bool, depth: Int = 0) -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            return value.rounded(.towardZero) == value ? String(Int(value)) : String(value)
        case .string(let value):
            return quotedJSONString(value)
        case .array(let values):
            guard !values.isEmpty else { return "[]" }
            if !pretty {
                return "[\(values.map { $0.jsonString(pretty: false, depth: depth + 1) }.joined(separator: ","))]"
            }
            let indent = String(repeating: "  ", count: depth)
            let childIndent = String(repeating: "  ", count: depth + 1)
            let body = values
                .map { "\(childIndent)\($0.jsonString(pretty: true, depth: depth + 1))" }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(indent)]"
        case .object(let values):
            guard !values.isEmpty else { return "{}" }
            let entries = values.map { key, value in
                let renderedValue = value.jsonString(pretty: pretty, depth: depth + 1)
                return "\(quotedJSONString(key))\(pretty ? ": " : ":")\(renderedValue)"
            }
            if !pretty {
                return "{\(entries.joined(separator: ","))}"
            }
            let indent = String(repeating: "  ", count: depth)
            let childIndent = String(repeating: "  ", count: depth + 1)
            let body = entries.map { "\(childIndent)\($0)" }.joined(separator: ",\n")
            return "{\n\(body)\n\(indent)}"
        }
    }

    private func quotedJSONString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let arrayText = String(data: data, encoding: .utf8)!
        return String(arrayText.dropFirst().dropLast()).replacingOccurrences(of: "\\/", with: "/")
    }
}

private indirect enum OrderedTestJSONValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([OrderedTestJSONValue])
    case object([(String, OrderedTestJSONValue)])

    subscript(key: String) -> OrderedTestJSONValue? {
        guard case .object(let entries) = self else { return nil }
        return entries.first(where: { $0.0 == key })?.1
    }

    func prettyJSONString() -> String {
        jsonString(pretty: true)
    }

    private func jsonString(pretty: Bool, depth: Int = 0) -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            return value.rounded(.towardZero) == value ? String(Int(value)) : String(value)
        case .string(let value):
            return quotedJSONString(value)
        case .array(let values):
            guard !values.isEmpty else { return "[]" }
            let indent = String(repeating: "  ", count: depth)
            let childIndent = String(repeating: "  ", count: depth + 1)
            let body = values
                .map { "\(childIndent)\($0.jsonString(pretty: pretty, depth: depth + 1))" }
                .joined(separator: pretty ? ",\n" : ",")
            if !pretty { return "[\(body)]" }
            return "[\n\(body)\n\(indent)]"
        case .object(let entries):
            guard !entries.isEmpty else { return "{}" }
            let indent = String(repeating: "  ", count: depth)
            let childIndent = String(repeating: "  ", count: depth + 1)
            let body = entries.map { key, value in
                let rendered = "\(quotedJSONString(key))\(pretty ? ": " : ":")\(value.jsonString(pretty: pretty, depth: depth + 1))"
                return pretty ? "\(childIndent)\(rendered)" : rendered
            }.joined(separator: pretty ? ",\n" : ",")
            if !pretty { return "{\(body)}" }
            return "{\n\(body)\n\(indent)}"
        }
    }

    private func quotedJSONString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let arrayText = String(data: data, encoding: .utf8)!
        return String(arrayText.dropFirst().dropLast()).replacingOccurrences(of: "\\/", with: "/")
    }
}

private struct OrderedTestJSONParser {
    let text: String
    private var index: String.Index

    init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    mutating func parse() throws -> OrderedTestJSONValue {
        let value = try parseValue()
        skipWhitespace()
        return value
    }

    private mutating func parseValue() throws -> OrderedTestJSONValue {
        skipWhitespace()
        guard index < text.endIndex else { throw ParserError.unexpectedEOF }
        switch text[index] {
        case "{":
            return try parseObject()
        case "[":
            return try parseArray()
        case "\"":
            return .string(try parseString())
        case "t":
            try consume("true")
            return .bool(true)
        case "f":
            try consume("false")
            return .bool(false)
        case "n":
            try consume("null")
            return .null
        default:
            return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> OrderedTestJSONValue {
        advance()
        skipWhitespace()
        var entries: [(String, OrderedTestJSONValue)] = []
        if current == "}" {
            advance()
            return .object(entries)
        }
        while true {
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            let value = try parseValue()
            entries.append((key, value))
            skipWhitespace()
            if current == "}" {
                advance()
                return .object(entries)
            }
            try expect(",")
        }
    }

    private mutating func parseArray() throws -> OrderedTestJSONValue {
        advance()
        skipWhitespace()
        var values: [OrderedTestJSONValue] = []
        if current == "]" {
            advance()
            return .array(values)
        }
        while true {
            values.append(try parseValue())
            skipWhitespace()
            if current == "]" {
                advance()
                return .array(values)
            }
            try expect(",")
        }
    }

    private mutating func parseString() throws -> String {
        try expect("\"")
        var result = ""
        while index < text.endIndex {
            let char = text[index]
            advance()
            if char == "\"" { return result }
            if char == "\\" {
                guard index < text.endIndex else { throw ParserError.unexpectedEOF }
                let escaped = text[index]
                advance()
                switch escaped {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    let scalar = try parseUnicodeScalar()
                    result.unicodeScalars.append(scalar)
                default:
                    throw ParserError.invalidEscape
                }
            } else {
                result.append(char)
            }
        }
        throw ParserError.unexpectedEOF
    }

    private mutating func parseUnicodeScalar() throws -> UnicodeScalar {
        let start = index
        for _ in 0..<4 {
            guard index < text.endIndex else { throw ParserError.unexpectedEOF }
            advance()
        }
        let hex = String(text[start..<index])
        guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else {
            throw ParserError.invalidUnicode
        }
        return scalar
    }

    private mutating func parseNumber() throws -> OrderedTestJSONValue {
        let start = index
        if current == "-" { advance() }
        while index < text.endIndex, current?.isNumber == true { advance() }
        if current == "." {
            advance()
            while index < text.endIndex, current?.isNumber == true { advance() }
        }
        if current == "e" || current == "E" {
            advance()
            if current == "+" || current == "-" { advance() }
            while index < text.endIndex, current?.isNumber == true { advance() }
        }
        let raw = String(text[start..<index])
        if raw.contains(".") || raw.contains("e") || raw.contains("E") {
            guard let value = Double(raw) else { throw ParserError.invalidNumber }
            return .double(value)
        }
        guard let value = Int(raw) else { throw ParserError.invalidNumber }
        return .int(value)
    }

    private mutating func consume(_ literal: String) throws {
        for char in literal {
            try expect(char)
        }
    }

    private mutating func expect(_ char: Character) throws {
        skipWhitespace()
        guard current == char else { throw ParserError.unexpectedCharacter }
        advance()
    }

    private mutating func skipWhitespace() {
        while index < text.endIndex, current?.isWhitespace == true { advance() }
    }

    private var current: Character? {
        guard index < text.endIndex else { return nil }
        return text[index]
    }

    private mutating func advance() {
        index = text.index(after: index)
    }

    enum ParserError: Error {
        case unexpectedEOF
        case unexpectedCharacter
        case invalidEscape
        case invalidUnicode
        case invalidNumber
    }
}
