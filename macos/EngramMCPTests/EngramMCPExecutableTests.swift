import Darwin
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
        XCTAssertEqual(tools.count, 26)
    }

    func testToolNameParityMatchesNodeAllTools() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """
        )

        guard case .array(let tools)? = capture.ordered["result"]?["tools"] else {
            XCTFail("Expected tools/list result.tools array")
            return
        }
        let actual = Set(tools.compactMap { $0["name"]?.stringValue })
        let expectedData = try Data(contentsOf: URL(fileURLWithPath: fixturePath("mcp-golden/tools.json")))
        let expected = Set(try JSONDecoder().decode([String].self, from: expectedData))
        XCTAssertEqual(actual, expected)
    }

    func testInitializeMatchesGolden() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"XCTest","version":"1.0"}}}
            """
        )

        let response = capture.response
        XCTAssertEqual(response.error?.code, nil)
        XCTAssertEqual(
            try prettyJSONString(from: XCTUnwrap(capture.ordered["result"])),
            try String(contentsOfFile: fixturePath("mcp-golden/initialize.result.json"), encoding: .utf8)
        )
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

    func testSearchHybridNoEmbeddingMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "search",
            arguments: """
            {"query":"single writer daemon HTTP","mode":"hybrid","limit":5}
            """,
            goldenFixture: "mcp-golden/search.hybrid.keyword_only.json"
        )
    }

    func testSearchSemanticShortQueryMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "search",
            arguments: """
            {"query":"ab","mode":"semantic","limit":5}
            """,
            goldenFixture: "mcp-golden/search.semantic.short_query.json"
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

    func testGetContextWithMemoryMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "get_context",
            arguments: """
            {"cwd":"/Users/test/work/engram","task":"daemon HTTP single writer","include_environment":false,"sort_by":"score"}
            """,
            goldenFixture: "mcp-golden/get_context.engram.with_memory.json"
        )
    }

    func testGetContextAbstractEnvironmentMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "get_context",
            arguments: """
            {"cwd":"/Users/test/work/engram","detail":"abstract","include_environment":true,"sort_by":"score"}
            """,
            goldenFixture: "mcp-golden/get_context.engram.abstract_environment.json",
            environment: [
                "ENGRAM_MCP_NOW": "2026-01-09T12:00:00.000Z",
            ]
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
        let goldenPath = fixturePath("mcp-golden/link_sessions.engram.json")
        let goldenData = try Data(contentsOf: URL(fileURLWithPath: goldenPath))
        let goldenObject = try JSONDecoder().decode(TestJSONValue.self, from: goldenData)
        let structured = try XCTUnwrap(goldenObject["structuredContent"])
        let service = try MockServiceSocketServer { request in
            switch request.command {
            case "status":
                return try request.success(
                    .object([
                        "state": .string("running"),
                        "total": .int(0),
                        "todayParents": .int(0),
                    ])
                )
            case "linkSessions":
                let body = try request.decodePayload([String: TestJSONValue].self)
                XCTAssertEqual(
                    body["targetDir"]?.stringValue,
                    self.fixturePath("mcp-runtime/engram")
                )
                XCTAssertEqual(body["actor"]?.stringValue, "mcp")
                return try request.success(structured, databaseGeneration: 1)
            default:
                throw NSError(domain: "MockServiceSocketServer", code: 99)
            }
        }
        try service.start()
        defer { service.stop() }
        try assertToolCallMatchesGolden(
            tool: "link_sessions",
            arguments: """
            {"targetDir":"\(fixturePath("mcp-runtime/engram"))"}
            """,
            goldenFixture: "mcp-golden/link_sessions.engram.json",
            environment: [
                "ENGRAM_MCP_SERVICE_SOCKET": service.socketPath,
            ]
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
        let service = try makeReachableServiceSocketServer()
        try service.start()
        defer { service.stop() }
        try assertToolCallMatchesGolden(
            tool: "export",
            arguments: """
            {"id":"mcp-transcript-01","format":"json"}
            """,
            goldenFixture: "mcp-golden/export.transcript.json",
            environment: [
                "HOME": fixturePath("mcp-runtime/export-home"),
                "ENGRAM_MCP_SERVICE_SOCKET": service.socketPath,
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

    func testProjectRecoverMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "project_recover",
            arguments: """
            {"since":"2026-03-01T00:00:00.000Z"}
            """,
            goldenFixture: "mcp-golden/project_recover.fixture.json"
        )
    }

    func testSaveInsightMatchesGoldenViaServiceSocket() throws {
        let goldenPath = fixturePath("mcp-golden/save_insight.text_only.json")
        let goldenData = try Data(contentsOf: URL(fileURLWithPath: goldenPath))
        let goldenObject = try JSONDecoder().decode(TestJSONValue.self, from: goldenData)
        let structured = try XCTUnwrap(goldenObject["structuredContent"])
        let server = try MockServiceSocketServer { request in
            switch request.command {
            case "status":
                return try request.success(
                    .object([
                        "state": .string("running"),
                        "total": .int(0),
                        "todayParents": .int(0),
                    ])
                )
            case "saveInsight":
                let body = try request.decodePayload([String: TestJSONValue].self)
                XCTAssertEqual(body["actor"]?.stringValue, "mcp")
                XCTAssertEqual(body["wing"]?.stringValue, "engram")
                XCTAssertEqual(body["room"]?.stringValue, "mcp-swift")
                return try request.success(structured, databaseGeneration: 1)
            default:
                throw NSError(domain: "MockServiceSocketServer", code: 101)
            }
        }
        try server.start()
        defer { server.stop() }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"save_insight","arguments":{"content":"Swift MCP contract tests should use deterministic fixture databases and byte-stable JSON golden files.","wing":"engram","room":"mcp-swift","importance":5,"source_session_id":"mcp-fixture-01"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
                "ENGRAM_MCP_SERVICE_SOCKET": server.socketPath,
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

        var seenActions: [String] = []
        let server = try MockServiceSocketServer { request in
            switch request.command {
            case "status":
                return try request.success(
                    .object([
                        "state": .string("running"),
                        "total": .int(0),
                        "todayParents": .int(0),
                    ])
                )
            case "manageProjectAlias":
                let body = try request.decodePayload([String: TestJSONValue].self)
                XCTAssertEqual(body["actor"]?.stringValue, "mcp")
                let action = body["action"]?.stringValue ?? "unknown"
                seenActions.append(action)
                switch action {
                case "add":
                    return try request.success(
                        .object(["added": .object(["alias": .string("apollo-next"), "canonical": .string("apollo")])]),
                        databaseGeneration: 1
                    )
                case "remove":
                    return try request.success(
                        .object(["removed": .object(["alias": .string("apollo-next"), "canonical": .string("apollo")])]),
                        databaseGeneration: 2
                    )
                default:
                    throw NSError(domain: "MockServiceSocketServer", code: 102)
                }
            default:
                XCTFail("Unexpected command \(request.command)")
                return try request.success(.object([:]))
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
                "ENGRAM_MCP_SERVICE_SOCKET": server.socketPath,
            ]
        )
        try assertAliasMutation(addCapture, key: "added")

        let removeCapture = try rpc(
            """
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"manage_project_alias","arguments":{"action":"remove","old_project":"apollo-next","new_project":"apollo"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixtureDB,
                "ENGRAM_MCP_SERVICE_SOCKET": server.socketPath,
            ]
        )
        try assertAliasMutation(removeCapture, key: "removed")
        XCTAssertEqual(seenActions, ["add", "remove"])
    }

    func testGenerateSummaryMatchesGoldenViaServiceSocket() throws {
        let goldenPath = fixturePath("mcp-golden/generate_summary.fixture.json")
        let server = try MockServiceSocketServer { request in
            switch request.command {
            case "status":
                return try request.success(
                    .object([
                        "state": .string("running"),
                        "total": .int(0),
                        "todayParents": .int(0),
                    ])
                )
            case "generateSummary":
                let body = try request.decodePayload([String: TestJSONValue].self)
                XCTAssertEqual(body["sessionId"]?.stringValue, "mcp-fixture-01")
                return try request.success(
                    .object([
                        "summary": .string("Fixture summary: Phase C ports the stdio MCP shim and forwards writes through daemon HTTP."),
                    ]),
                    databaseGeneration: 1
                )
            default:
                throw NSError(domain: "MockServiceSocketServer", code: 100)
            }
        }
        try server.start()
        defer { server.stop() }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"generate_summary","arguments":{"sessionId":"mcp-fixture-01"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
                "ENGRAM_MCP_SERVICE_SOCKET": server.socketPath,
            ]
        )
        XCTAssertEqual(
            try prettyJSONString(from: XCTUnwrap(capture.ordered["result"])),
            try String(contentsOfFile: goldenPath, encoding: .utf8)
        )
    }

    func testNativeProjectOperationsRouteThroughTheService() throws {
        // Stage 4 ships the four project_* tools natively. Without a
        // service socket they MUST fall through to the standard
        // serviceUnavailable response (operational category) — not the
        // legacy "Swift-only runtime" filter, which has been removed.
        // Point ENGRAM_MCP_SERVICE_SOCKET at a path that doesn't exist so
        // the test runs reliably on a dev box where the user's real
        // service might be live.
        let bogusSocket = "/tmp/engram-mcp-tests-no-such-\(UUID().uuidString).sock"
        for (index, tool) in ["project_move", "project_archive", "project_undo", "project_move_batch"].enumerated() {
            let capture = try rpc(
                """
                {"jsonrpc":"2.0","id":\(20 + index),"method":"tools/call","params":{"name":"\(tool)","arguments":{}}}
                """,
                environment: [
                    "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
                    "ENGRAM_MCP_SERVICE_SOCKET": bogusSocket,
                    "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
                ]
            )
            let result = try XCTUnwrap(capture.ordered["result"]?.objectValue)
            XCTAssertEqual(result["isError"]?.boolValue, true)
            let structured = result["structuredContent"]?.objectValue
            XCTAssertEqual(structured?["code"]?.stringValue, "serviceUnavailable",
                           "\(tool) must surface serviceUnavailable, not the legacy unavailable-tool filter")
            XCTAssertEqual(structured?["tool"]?.stringValue, tool)
        }
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

    private func assertAliasMutation(_ capture: RPCCapture, key: String) throws {
        let result = try XCTUnwrap(capture.ordered["result"])
        XCTAssertEqual(result["structuredContent"]?[key]?["alias"]?.stringValue, "apollo-next")
        XCTAssertEqual(result["structuredContent"]?[key]?["canonical"]?.stringValue, "apollo")

        guard case .array(let content)? = result["content"],
              let text = content.first?["text"]?.stringValue,
              let data = text.data(using: .utf8) else {
            return XCTFail("Expected text content")
        }
        let decodedText = try JSONDecoder().decode(TestJSONValue.self, from: data)
        XCTAssertEqual(decodedText[key]?["alias"]?.stringValue, "apollo-next")
        XCTAssertEqual(decodedText[key]?["canonical"]?.stringValue, "apollo")
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

    private func loadGoldenJSON(_ relativePath: String) throws -> TestJSONValue {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath(relativePath)))
        return try JSONDecoder().decode(TestJSONValue.self, from: data)
    }

    private func makeReachableServiceSocketServer() throws -> MockServiceSocketServer {
        try MockServiceSocketServer { request in
            switch request.command {
            case "status":
                return try request.success(
                    .object([
                        "state": .string("running"),
                        "total": .int(0),
                        "todayParents": .int(0),
                    ])
                )
            case "exportSession":
                return try request.success(
                    .object([
                        "outputPath": .string(self.fixturePath("mcp-runtime/export-home/codex-exports/codex-mcp-tran-2026-01-15.json")),
                        "format": .string("json"),
                        "messageCount": .int(3),
                    ])
                )
            default:
                throw NSError(domain: "MockServiceSocketServer", code: 104)
            }
        }
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

private final class MockServiceSocketServer {
    struct RequestEnvelope: Decodable {
        let requestId: String
        let kind: String
        let command: String
        let payload: Data?

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case kind
            case command
            case payload
        }

        func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: try XCTUnwrap(payload))
        }

        func success(_ result: TestJSONValue, databaseGeneration: Int? = nil) throws -> Data {
            let resultData = try JSONEncoder().encode(result)
            let response = SuccessEnvelope(
                requestId: requestId,
                result: resultData,
                databaseGeneration: databaseGeneration
            )
            return try JSONEncoder().encode(response)
        }
    }

    private struct SuccessEnvelope: Encodable {
        let requestId: String
        let kind: String = "response"
        let ok: Bool = true
        let result: Data
        let databaseGeneration: Int?

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case kind
            case ok
            case result
            case databaseGeneration = "database_generation"
        }
    }

    private struct FailureEnvelope: Encodable {
        let requestId: String
        let kind: String = "response"
        let ok: Bool = false
        let error: FailureBody

        struct FailureBody: Encodable {
            let name: String
            let message: String
            let retryPolicy: String

            enum CodingKeys: String, CodingKey {
                case name
                case message
                case retryPolicy = "retry_policy"
            }
        }

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case kind
            case ok
            case error
        }
    }

    let socketPath: String

    private let handler: (RequestEnvelope) throws -> Data
    private let queue = DispatchQueue(label: "MockServiceSocketServer")
    private var socketFD: Int32 = -1
    private var acceptWorkItem: DispatchWorkItem?

    init(handler: @escaping (RequestEnvelope) throws -> Data) throws {
        self.socketPath = "/tmp/egmcp-\(UUID().uuidString.prefix(8)).sock"
        self.handler = handler
    }

    func start() throws {
        socketFD = try Self.bindSocket(path: socketPath)
        let socketFD = self.socketFD
        let handler = self.handler
        let workItem = DispatchWorkItem {
            while true {
                let client = accept(socketFD, nil, nil)
                if client < 0 { break }
                var requestID = "unknown"
                do {
                    let frame = try Self.readFrame(from: client)
                    let request = try JSONDecoder().decode(RequestEnvelope.self, from: frame)
                    requestID = request.requestId
                    let response = try handler(request)
                    try Self.writeFrame(response, to: client)
                } catch {
                    let fallback = try? JSONEncoder().encode(
                        FailureEnvelope(
                            requestId: requestID,
                            error: .init(
                                name: "InvalidRequest",
                                message: error.localizedDescription,
                                retryPolicy: "never"
                            )
                        )
                    )
                    if let fallback {
                        try? Self.writeFrame(fallback, to: client)
                    }
                }
                Darwin.close(client)
            }
        }
        acceptWorkItem = workItem
        queue.async(execute: workItem)
    }

    func stop() {
        acceptWorkItem?.cancel()
        acceptWorkItem = nil
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private static func bindSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "MockServiceSocketServer", code: 1) }
        try? FileManager.default.removeItem(atPath: path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "MockServiceSocketServer", code: 2)
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    memset(destination, 0, maxPathLength)
                    strncpy(destination, source, maxPathLength - 1)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "MockServiceSocketServer", code: 3)
        }
        return fd
    }

    private static func writeFrame(_ data: Data, to fd: Int32) throws {
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { buffer in
            try writeAll(buffer, to: fd)
        }
        try data.withUnsafeBytes { buffer in
            try writeAll(buffer, to: fd)
        }
    }

    private static func readFrame(from fd: Int32) throws -> Data {
        let lengthData = try readExact(count: 4, from: fd)
        let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 32 * 1024 * 1024 else {
            throw NSError(domain: "MockServiceSocketServer", code: 4)
        }
        return try readExact(count: Int(length), from: fd)
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to fd: Int32) throws {
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            guard written > 0 else {
                throw NSError(domain: "MockServiceSocketServer", code: 5)
            }
            offset += written
        }
    }

    private static func readExact(count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let readCount = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                guard readCount > 0 else {
                    throw NSError(domain: "MockServiceSocketServer", code: 6)
                }
                offset += readCount
            }
        }
        return data
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

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
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

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [OrderedTestJSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    var objectValue: OrderedTestJSONValue? {
        guard case .object = self else { return nil }
        return self
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
