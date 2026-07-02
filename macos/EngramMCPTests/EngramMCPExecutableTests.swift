import Darwin
import Foundation
import GRDB
import Network
import XCTest

final class EngramMCPExecutableTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testExecutableResumeJSONRoutesToServiceInsteadOfStartingMCPStdio() throws {
        let server = try MockServiceSocketServer { request in
            XCTAssertEqual(request.command, "resumeCommand")
            let payload = try request.decodePayload([String: TestJSONValue].self)
            XCTAssertEqual(payload["sessionId"]?.stringValue, "session-1")
            return try request.success(
                .object([
                    "tool": .null,
                    "command": .null,
                    "args": .array([]),
                    "cwd": .null,
                    "contextPrimer": .string("""
                    Resume context from Engram archive:
                    - recover from archived transcript
                    """),
                    "error": .string("Resume command unavailable"),
                    "hint": .string("Install codex"),
                ])
            )
        }
        try server.start()
        defer { server.stop() }

        let result = try runExecutable(
            arguments: ["resume", "session-1", "--json", "--socket", server.socketPath],
            environment: ["TZ": "UTC"]
        )

        XCTAssertEqual(result.exitStatus, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        let decoded = try JSONDecoder().decode(TestJSONValue.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded["error"]?.stringValue, "Resume command unavailable")
        XCTAssertEqual(decoded["hint"]?.stringValue, "Install codex")
        XCTAssertEqual(decoded["contextPrimer"]?.stringValue, """
        Resume context from Engram archive:
        - recover from archived transcript
        """)
    }

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
        XCTAssertEqual(tools.count, 29)
    }

    func testPingReturnsEmptyResult() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"ping"}
            """
        )

        XCTAssertNil(capture.response.error)
        guard case .object(let entries)? = capture.ordered["result"] else {
            return XCTFail("Expected ping result to be an empty object")
        }
        XCTAssertEqual(entries.count, 0)
    }

    func testParseErrorIncludesNullId() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":
            """
        )

        XCTAssertNotNil(capture.response.error)
        guard case .null? = capture.ordered["id"] else {
            return XCTFail("Parse error response must include id: null, got \(capture.rawLine)")
        }
    }

    func testIdLessRequestsDoNotEmitResponses() throws {
        let responses = try rpcSession(
            [
                #"{"jsonrpc":"2.0","method":"tools/list"}"#,
            ]
        )

        XCTAssertEqual(responses.count, 0)
    }

    func testMCPStdioCancellationDoesNotEmitCancelledToolResultsOrOverwriteDuplicateIds() throws {
        let source = try source("macos/EngramMCP/Core/MCPStdioServer.swift")

        XCTAssertTrue(
            source.contains("guard !Task.isCancelled else { return }"),
            "Async tools/call handling must suppress output after notifications/cancelled instead of emitting a cancelled tool result"
        )
        XCTAssertTrue(
            source.contains("func start(for key: String, operation: @escaping @Sendable () async -> Void) -> Bool"),
            "In-flight request registration must report duplicate JSON-RPC ids"
        )
        XCTAssertTrue(
            source.contains("guard tasks[key] == nil else { return false }"),
            "A duplicate JSON-RPC id must not overwrite the original in-flight task's cancellation handle"
        )
    }

    func testStdioSessionHandlesMultipleRequestsAndNotifications() throws {
        let responses = try rpcSession(
            [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
                #"{"jsonrpc":"2.0","id":"ping-1","method":"ping"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":"call-a","method":"tools/call","params":{"name":"list_sessions","arguments":{"limit":1,"offset":0}}}"#,
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"call-a"}}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_sessions","arguments":{"limit":1,"offset":1}}}"#,
            ],
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
            ]
        )
        let byId = Dictionary(uniqueKeysWithValues: responses.compactMap { response -> (String, OrderedTestJSONValue)? in
            guard let id = response["id"] else { return nil }
            if let int = id.intValue { return ("n:\(int)", response) }
            if let string = id.stringValue { return ("s:\(string)", response) }
            return nil
        })

        XCTAssertNil(
            responses.first { $0["method"]?.stringValue == "notifications/cancelled" },
            "notifications must not emit a JSON-RPC response"
        )
        XCTAssertEqual(byId["n:1"]?["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
        if case .object(let pingEntries)? = byId["s:ping-1"]?["result"] {
            XCTAssertTrue(pingEntries.isEmpty)
        } else {
            XCTFail("ping should return an empty object")
        }
        XCTAssertNotNil(byId["n:2"]?["result"]?["tools"]?.arrayValue)
        XCTAssertNil(byId["s:call-a"], "cancelled tools/call requests must not emit a result response")
        let result = try XCTUnwrap(byId["n:3"]?["result"], "n:3 should produce a correlated tools/call response")
        XCTAssertNotNil(result["structuredContent"]?["sessions"]?.arrayValue)
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

    func testSourceSchemasCoverEveryKnownProvider() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """
        )

        guard case .array(let tools)? = capture.ordered["result"]?["tools"] else {
            XCTFail("Expected tools/list result.tools array")
            return
        }
        let expected = [
            "codex",
            "claude-code",
            "grok",
            "copilot",
            "pi",
            "gemini-cli",
            "opencode",
            "iflow",
            "qwen",
            "qoder",
            "kimi",
            "minimax",
            "mimo",
            "doubao",
            "glm",
            "deepseek",
            "lobsterai",
            "commandcode",
            "cline",
            "cursor",
            "vscode",
            "antigravity",
            "windsurf",
        ]

        for toolName in ["list_sessions", "search"] {
            let tool = tools.first { $0["name"]?.stringValue == toolName }
            let sourceEnum = tool?["inputSchema"]?["properties"]?["source"]?["enum"]?.arrayValue?
                .compactMap(\.stringValue)
            XCTAssertEqual(sourceEnum, expected, toolName)
        }
    }

    func testSearchSchemaDoesNotAdvertiseUnavailableSemanticModes() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """
        )

        guard case .array(let tools)? = capture.ordered["result"]?["tools"],
              let search = tools.first(where: { $0["name"]?.stringValue == "search" })
        else {
            XCTFail("Expected search tool in tools/list")
            return
        }
        let modeEnum = search["inputSchema"]?["properties"]?["mode"]?["enum"]?.arrayValue?
            .compactMap(\.stringValue)
        XCTAssertEqual(modeEnum, ["keyword"])
        XCTAssertFalse(search["description"]?.stringValue?.localizedCaseInsensitiveContains("semantic") ?? true)
    }

    func testContextAndSessionSchemasBoundNumericInputs() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """
        )

        guard case .array(let tools)? = capture.ordered["result"]?["tools"],
              let getContext = tools.first(where: { $0["name"]?.stringValue == "get_context" }),
              let getSession = tools.first(where: { $0["name"]?.stringValue == "get_session" }) else {
            return XCTFail("Expected get_context and get_session in tools/list")
        }
        let maxTokens = getContext["inputSchema"]?["properties"]?["max_tokens"]
        XCTAssertEqual(maxTokens?["minimum"]?.intValue, 1)
        XCTAssertEqual(maxTokens?["maximum"]?.intValue, 32_000)

        let page = getSession["inputSchema"]?["properties"]?["page"]
        XCTAssertEqual(page?["minimum"]?.intValue, 1)
        XCTAssertEqual(page?["maximum"]?.intValue, 100_000)
    }

    // MARK: - Deepened MCP surface (annotations / resources / prompts)

    func testToolsListIncludesCategoryDerivedAnnotations() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """
        )
        guard case .array(let tools)? = capture.ordered["result"]?["tools"] else {
            return XCTFail("Expected tools/list result.tools array")
        }
        func tool(_ name: String) -> OrderedTestJSONValue? {
            tools.first { $0["name"]?.stringValue == name }
        }
        // Read-only tools advertise readOnlyHint so clients can auto-approve.
        XCTAssertEqual(tool("search")?["annotations"]?["readOnlyHint"]?.boolValue, true)
        XCTAssertEqual(tool("get_context")?["annotations"]?["readOnlyHint"]?.boolValue, true)
        XCTAssertEqual(tool("search")?["title"]?.stringValue, "Search")
        // Destructive project ops are gated.
        XCTAssertEqual(tool("project_move")?["annotations"]?["readOnlyHint"]?.boolValue, false)
        XCTAssertEqual(tool("project_move")?["annotations"]?["destructiveHint"]?.boolValue, true)
        // Additive writes are not destructive; supersession creates a new version,
        // so save_insight is no longer idempotent.
        XCTAssertEqual(tool("save_insight")?["annotations"]?["destructiveHint"]?.boolValue, false)
        XCTAssertEqual(tool("save_insight")?["annotations"]?["idempotentHint"]?.boolValue, false)
    }

    func testInitializeAdvertisesResourcesAndPromptsCapabilities() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
            """
        )
        XCTAssertNotNil(capture.ordered["result"]?["capabilities"]?["resources"])
        XCTAssertNotNil(capture.ordered["result"]?["capabilities"]?["prompts"])
    }

    func testResourcesListExposesSessions() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"resources/list"}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite")]
        )
        XCTAssertNil(capture.response.error)
        let resources = try XCTUnwrap(capture.ordered["result"]?["resources"]?.arrayValue)
        let uris = resources.compactMap { $0["uri"]?.stringValue }
        XCTAssertTrue(uris.contains { $0.hasPrefix("engram://session/") }, "\(uris)")
    }

    func testResourceReadInsightReturnsContent() throws {
        let listed = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"resources/list"}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite")]
        )
        let resources = try XCTUnwrap(listed.ordered["result"]?["resources"]?.arrayValue)
        let insightURI = resources.compactMap { $0["uri"]?.stringValue }
            .first { $0.hasPrefix("engram://insight/") }
        let uri = try XCTUnwrap(insightURI, "fixture should contain at least one saved insight")

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"\(uri)"}}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite")]
        )
        XCTAssertNil(capture.response.error)
        let contents = try XCTUnwrap(capture.ordered["result"]?["contents"]?.arrayValue)
        XCTAssertEqual(contents.first?["uri"]?.stringValue, uri)
        XCTAssertFalse((contents.first?["text"]?.stringValue ?? "").isEmpty)
    }

    func testGetRulesAndRuleResourceReturnMinedRules() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-rules")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try seedMinedRuleFixture(at: dbPath)

        let rules = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_rules","arguments":{"project":"engram","query":"writer gate","limit":5}}}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": dbPath]
        )
        XCTAssertNil(rules.response.error)
        let firstRule = try XCTUnwrap(
            rules.ordered["result"]?["structuredContent"]?["rules"]?.arrayValue?.first
        )
        XCTAssertEqual(firstRule["id"]?.stringValue, "rule-writer-gate")
        XCTAssertEqual(firstRule["evidenceSessionIds"]?.arrayValue?.first?.stringValue, "mcp-fixture-01")

        let listed = try rpc(
            """
            {"jsonrpc":"2.0","id":2,"method":"resources/list"}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": dbPath]
        )
        let uri = try XCTUnwrap(
            listed.ordered["result"]?["resources"]?.arrayValue?
                .compactMap { $0["uri"]?.stringValue }
                .first { $0 == "engram://rule/rule-writer-gate" }
        )

        let read = try rpc(
            """
            {"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"\(uri)"}}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": dbPath]
        )
        XCTAssertNil(read.response.error)
        let text = read.ordered["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("# Preserve the service writer gate"), text)
        XCTAssertTrue(text.contains("mcp-fixture-01"), text)
    }

    func testGetContextIncludesMinedRulesForProject() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-context-rules")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try seedMinedRuleFixture(at: dbPath)

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/engram","task":"writer gate","include_environment":false,"max_tokens":1200}}}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": dbPath]
        )
        XCTAssertNil(capture.response.error)
        let text = capture.ordered["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("[rule] Preserve the service writer gate"), text)
    }

    func testGetContextRejectsHugeMaxTokensInsteadOfOverflowing() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/engram","include_environment":false,"max_tokens":9223372036854775807}}}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite")]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        let message = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("max_tokens must be <="), message)
    }

    func testGetSessionRejectsHugePageInsteadOfOverflowing() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-fixture-01","page":9223372036854775807}}}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite")]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        let message = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("page must be <="), message)
    }

    func testResourceReadRejectsUnknownURIScheme() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"https://example.com"}}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite")]
        )
        XCTAssertEqual(capture.response.error?.code, -32602)
    }

    func testPromptsListAdvertisesEngramPrompts() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"prompts/list"}
            """
        )
        let prompts = try XCTUnwrap(capture.ordered["result"]?["prompts"]?.arrayValue)
        let names = prompts.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("engram:catch-up"), "\(names)")
        XCTAssertTrue(names.contains("engram:handoff"), "\(names)")
    }

    func testPromptGetCatchUpReturnsUserMessage() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"prompts/get","params":{"name":"engram:catch-up","arguments":{"cwd":"/Users/test/work/engram"}}}
            """,
            environment: ["ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite")]
        )
        XCTAssertNil(capture.response.error)
        let messages = try XCTUnwrap(capture.ordered["result"]?["messages"]?.arrayValue)
        XCTAssertEqual(messages.first?["role"]?.stringValue, "user")
        XCTAssertEqual(messages.first?["content"]?["type"]?.stringValue, "text")
        XCTAssertFalse((messages.first?["content"]?["text"]?.stringValue ?? "").isEmpty)
    }

    func testPromptGetRequiresCwd() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"prompts/get","params":{"name":"engram:catch-up","arguments":{}}}
            """
        )
        XCTAssertEqual(capture.response.error?.code, -32602)
    }

    func testExportDescriptionAdvertisesEngramExportsDirectory() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """
        )

        guard case .array(let tools)? = capture.ordered["result"]?["tools"],
              let export = tools.first(where: { $0["name"]?.stringValue == "export" })
        else {
            XCTFail("Expected export tool in tools/list")
            return
        }
        let description = export["description"]?.stringValue ?? ""
        XCTAssertTrue(description.contains("~/.engram/exports/"), description)
        XCTAssertFalse(description.contains("~/codex-exports"), description)
    }

    func testMCPDatabaseRetriesTransientMissingFTSTables() throws {
        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-transient-fts-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: "DROP TABLE sessions_fts")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) {
            do {
                try DatabaseQueue(path: dbPath).write { db in
                    try db.execute(sql: "CREATE VIRTUAL TABLE sessions_fts USING fts5(session_id UNINDEXED, content)")
                    try db.execute(
                        sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                        arguments: ["mcp-fixture-01", "transientneedle"]
                    )
                }
            } catch {
                XCTFail("failed to restore sessions_fts: \(error)")
            }
        }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"transientneedle","mode":"keyword","limit":1}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )
        let results = try XCTUnwrap(capture.ordered["result"]?["structuredContent"]?["results"]?.arrayValue)
        XCTAssertEqual(results.first?["session"]?["id"]?.stringValue, "mcp-fixture-01")
    }

    func testKeywordSearchEscapesProjectLikeWildcards() throws {
        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-like-escape-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try seedProjectLikeWildcardFixture(at: dbPath)

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"wildcardneedle","mode":"keyword","project":"my_repo","limit":10}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )

        let results = try XCTUnwrap(capture.ordered["result"]?["structuredContent"]?["results"]?.arrayValue)
        XCTAssertEqual(results.compactMap { $0["session"]?["id"]?.stringValue }, ["mcp-like-literal"])
    }

    func testSearchFindsExactNonUUIDSessionIdOutsideFTSContent() throws {
        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-id-search-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes,
                  indexed_at, tier
                ) VALUES (
                  'session-short-id', 'codex', '2026-04-24T01:00:00Z',
                  '/tmp/engram', 'engram', 'gpt-5.5', 2, 1, 1,
                  '/tmp/session-short-id.jsonl', 50, '2026-04-24T01:01:00Z',
                  'premium'
                )
                """
            )
        }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"session-short-id","mode":"keyword","limit":10}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )

        let results = try XCTUnwrap(capture.ordered["result"]?["structuredContent"]?["results"]?.arrayValue)
        XCTAssertEqual(results.compactMap { $0["session"]?["id"]?.stringValue }, ["session-short-id"])
        XCTAssertEqual(results.first?["matchType"]?.stringValue, "id")
        XCTAssertEqual(capture.ordered["result"]?["structuredContent"]?["searchModes"]?.arrayValue?.first?.stringValue, "id")
    }

    func testMCPTranscriptFallbackDoesNotBypassAdapterSizeFailures() throws {
        let source = try String(contentsOfFile: sourcePath("EngramMCP/Core/MCPTranscriptReader.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static func readMessagePage"))
        let end = try XCTUnwrap(source.range(of: "private static func normalizeRoles", options: [], range: start.lowerBound..<source.endIndex))
        let reader = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(reader.contains("try await readPageWithAdapterRegistry"))
        XCTAssertTrue(reader.contains("try await readWithAdapterRegistry"))
        XCTAssertTrue(reader.contains("try TranscriptSizeGuard.validateFullJSONTranscript"))
        XCTAssertTrue(source.contains("isFallbackUnsafeParserFailure"))
        XCTAssertTrue(source.contains("catch let failure as ParserFailure where isFallbackUnsafeParserFailure(failure)"))
    }

    func testInitializeMatchesGolden() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"XCTest","version":"1.0"}}}
            """
        )

        let response = capture.response
        XCTAssertEqual(response.error?.code, nil)
        let instructions = capture.ordered["result"]?["instructions"]?.stringValue
        XCTAssertFalse(instructions?.localizedCaseInsensitiveContains("semantic") ?? true)
        XCTAssertEqual(
            try prettyJSONString(from: XCTUnwrap(capture.ordered["result"])),
            try String(contentsOfFile: fixturePath("mcp-golden/initialize.result.json"), encoding: .utf8)
        )
    }

    func testInitializeAcceptsOlderCodexProtocolVersion() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"XCTest","version":"1.0"}}}
            """
        )

        XCTAssertEqual(capture.response.error?.code, nil)
        XCTAssertEqual(capture.ordered["result"]?["protocolVersion"]?.stringValue, "2024-11-05")
        XCTAssertEqual(capture.ordered["result"]?["serverInfo"]?["name"]?.stringValue, "engram")
    }

    func testInitializeAcceptsCurrentCodexProtocolVersion() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"XCTest","version":"1.0"}}}
            """
        )

        XCTAssertEqual(capture.response.error?.code, nil)
        XCTAssertEqual(capture.ordered["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(capture.ordered["result"]?["serverInfo"]?["name"]?.stringValue, "engram")
    }

    func testInitializeAcceptsCurrentClaudeCodeProtocolVersion() throws {
        // Regression: Claude Code 2.1.x sends 2025-11-25. The server must echo
        // it back, not reject it with -32602 ("Failed to connect").
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"XCTest","version":"1.0"}}}
            """
        )

        XCTAssertEqual(capture.response.error?.code, nil)
        XCTAssertEqual(capture.ordered["result"]?["protocolVersion"]?.stringValue, "2025-11-25")
        XCTAssertEqual(capture.ordered["result"]?["serverInfo"]?["name"]?.stringValue, "engram")
    }

    func testInitializeNegotiatesUnknownProtocolVersionToLatest() throws {
        // Per the MCP spec, an unknown (e.g. newer-than-this-build) version is
        // negotiated down to the latest version the server speaks instead of
        // erroring — so future client protocol bumps degrade gracefully.
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2999-01-01","capabilities":{},"clientInfo":{"name":"XCTest","version":"1.0"}}}
            """
        )

        XCTAssertEqual(capture.response.error?.code, nil)
        XCTAssertEqual(capture.ordered["result"]?["protocolVersion"]?.stringValue, "2025-11-25")
        XCTAssertNotNil(capture.response.result)
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

    func testListSessionsTotalCountsMatchesBeyondPage() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{"project":"engram","since":"2026-01-01T00:00:00.000Z","limit":1,"offset":0}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
            ]
        )

        XCTAssertNil(capture.response.error)
        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"]?.objectValue)
        XCTAssertEqual(structured["sessions"]?.arrayValue?.count, 1)
        XCTAssertEqual(structured["total"]?.intValue, 6)
    }

    func testListSessionsProjectFilterIsPartialMatch() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{"project":"gram","since":"2026-01-01T00:00:00.000Z","limit":10,"offset":0}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
            ]
        )

        XCTAssertNil(capture.response.error)
        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"]?.objectValue)
        XCTAssertEqual(structured["sessions"]?.arrayValue?.count, 6)
        XCTAssertEqual(structured["total"]?.intValue, 6)
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

    func testGetCostsSerializesNonFiniteCostAsNull() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE session_costs SET cost_usd = ? WHERE session_id = ?",
                arguments: [Double.infinity, "mcp-fixture-01"]
            )
        }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_costs","arguments":{"group_by":"source","since":"2026-01-01T00:00:00.000Z"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
            ]
        )

        XCTAssertEqual(capture.response.error?.code, nil)
        let breakdown = try XCTUnwrap(capture.ordered["result"]?["structuredContent"]?["breakdown"]?.arrayValue)
        var foundNullCost = false
        for group in breakdown {
            if case .null? = group["costUsd"] {
                foundNullCost = true
                break
            }
        }
        let renderedResult = try prettyJSONString(from: XCTUnwrap(capture.ordered["result"]))
            XCTAssertTrue(foundNullCost, renderedResult)
    }

    func testStatsDayGroupingDoesNotCrashOnMalformedStartTime() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET start_time = ? WHERE id = ?",
                arguments: ["not-a-date", "mcp-fixture-01"]
            )
        }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"stats","arguments":{"group_by":"day"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
            ]
        )

        XCTAssertNil(capture.response.error)
        let groups = try XCTUnwrap(capture.ordered["result"]?["structuredContent"]?["groups"]?.arrayValue)
        XCTAssertTrue(groups.contains { $0["key"]?.stringValue == "(unknown)" })
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

    func testProjectListMigrationsParsesSurrogatePairEscapesInDetail() throws {
        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-migration-surrogate"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(
                sql: """
                INSERT INTO migration_log (
                  id, old_path, new_path, old_basename, new_basename, state,
                  started_at, actor, detail
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "mig-surrogate",
                    "/tmp/old",
                    "/tmp/new",
                    "old",
                    "new",
                    "committed",
                    "2026-03-04T00:00:00.000Z",
                    "test",
                    #"{"emoji":"\uD83D\uDE00"}"#,
                ]
            )
        }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_list_migrations","arguments":{"since":"2026-03-04T00:00:00.000Z","limit":1}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )

        XCTAssertNil(capture.response.error)
        let first = try XCTUnwrap(capture.ordered["result"]?["structuredContent"]?.arrayValue?.first)
        XCTAssertEqual(first["detail"]?["emoji"]?.stringValue, "😀")
    }

    func testLiveSessionsMatchesGolden() throws {
        try assertToolCallMatchesGolden(
            tool: "live_sessions",
            arguments: "{}",
            goldenFixture: "mcp-golden/live_sessions.unavailable.json",
            environment: ["HOME": "/tmp/engram-mcp-empty-home-for-golden-tests"]
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

    private func encodeVector(_ values: [Float]) -> Data {
        var data = Data()
        for value in values {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func seedMinedRuleFixture(at dbPath: String) throws {
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS mined_rules (
                  id TEXT PRIMARY KEY,
                  rule_type TEXT NOT NULL,
                  title TEXT NOT NULL,
                  body TEXT NOT NULL,
                  evidence_session_ids TEXT NOT NULL DEFAULT '[]',
                  confidence REAL NOT NULL DEFAULT 0,
                  source_project TEXT,
                  model TEXT,
                  created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE VIRTUAL TABLE IF NOT EXISTS mined_rules_fts USING fts5(
                  rule_id UNINDEXED,
                  title,
                  body,
                  tokenize='trigram case_sensitive 0'
                );
            """)
            try db.execute(sql: "DELETE FROM mined_rules")
            try db.execute(sql: "DELETE FROM mined_rules_fts")
            try db.execute(
                sql: """
                INSERT INTO mined_rules (
                  id, rule_type, title, body, evidence_session_ids,
                  confidence, source_project, model, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "rule-writer-gate",
                    "runbook",
                    "Preserve the service writer gate",
                    "Route app and MCP writes through EngramServiceClient and ServiceWriterGate.",
                    #"["mcp-fixture-01"]"#,
                    0.91,
                    "engram",
                    "test-model",
                    "2026-06-26T00:00:00.000Z",
                ]
            )
            try db.execute(
                sql: "INSERT INTO mined_rules_fts (rule_id, title, body) VALUES (?, ?, ?)",
                arguments: [
                    "rule-writer-gate",
                    "Preserve the service writer gate",
                    "Route app and MCP writes through EngramServiceClient and ServiceWriterGate.",
                ]
            )
        }
    }

    func testGetMemoryHybridUsesSemanticRankingViaMockProvider() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-semantic")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS insight_embeddings (
                  insight_id TEXT PRIMARY KEY, embedding BLOB NOT NULL,
                  model TEXT NOT NULL, dim INTEGER NOT NULL, created_at TEXT
                );
            """)
            try db.execute(sql: "DELETE FROM insights")
            try db.execute(sql: "DELETE FROM insights_fts")
            let seeds: [(id: String, content: String, vector: [Float])] = [
                ("sem-near", "vector about cats", [1, 0, 0, 0]),
                ("sem-far", "vector about cars", [0, 1, 0, 0]),
            ]
            for seed in seeds {
                try db.execute(
                    sql: "INSERT INTO insights (id, content, importance) VALUES (?, ?, 5)",
                    arguments: [seed.id, seed.content]
                )
                try db.execute(
                    sql: "INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)",
                    arguments: [seed.id, seed.content]
                )
                try db.execute(
                    sql: "INSERT INTO insight_embeddings (insight_id, embedding, model, dim) VALUES (?, ?, 'test', 4)",
                    arguments: [seed.id, encodeVector(seed.vector)]
                )
            }
        }

        // The mock provider returns a query embedding close to "sem-near".
        let server = try MockHTTPServer(jsonBody: #"{"data":[{"index":0,"embedding":[0.92,0.1,0,0]}]}"#)
        server.start()
        defer { server.stop() }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_memory","arguments":{"query":"feline"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "ENGRAM_EMBEDDING_BASE_URL": "http://127.0.0.1:\(server.port)/v1",
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "test",
                "ENGRAM_EMBEDDING_DIM": "4",
            ]
        )

        XCTAssertNil(capture.response.error)
        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"])
        XCTAssertEqual(structured["retrieval"]?.stringValue, "hybrid")
        let ids = try XCTUnwrap(structured["memories"]?.arrayValue).compactMap { $0["id"]?.stringValue }
        XCTAssertEqual(ids.first, "sem-near", "\(ids)")
    }

    func testGetMemoryDegradesToKeywordWhenEmbeddingProviderFails() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-semantic-degrade")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS insight_embeddings (
                  insight_id TEXT PRIMARY KEY, embedding BLOB NOT NULL,
                  model TEXT NOT NULL, dim INTEGER NOT NULL, created_at TEXT
                );
            """)
            try db.execute(
                sql: "INSERT INTO insight_embeddings (insight_id, embedding, model, dim) VALUES ('insight-01', ?, 'test', 4)",
                arguments: [encodeVector([1, 0, 0, 0])]
            )
        }

        // Provider returns 500 → semantic throws → get_memory falls back to keyword.
        let server = try MockHTTPServer(status: 500, jsonBody: "{}")
        server.start()
        defer { server.stop() }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_memory","arguments":{"query":"single writer daemon HTTP"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "ENGRAM_EMBEDDING_BASE_URL": "http://127.0.0.1:\(server.port)/v1",
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_DIM": "4",
            ]
        )

        XCTAssertNil(capture.response.error)
        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"])
        XCTAssertNil(structured["retrieval"], "semantic failure must not be marked hybrid")
        XCTAssertNotNil(structured["memories"]?.arrayValue, "must still return keyword memories")
    }

    func testGetMemoryRanksByImportanceAndRecencyWhenLifecyclePresent() throws {
        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-memory-lifecycle"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
            // Simulate the writer-side memory-lifecycle migration on an old DB.
            for ddl in [
                "ALTER TABLE insights ADD COLUMN insight_type TEXT DEFAULT 'semantic'",
                "ALTER TABLE insights ADD COLUMN superseded_by TEXT",
                "ALTER TABLE insights ADD COLUMN last_accessed_at TEXT",
                "ALTER TABLE insights ADD COLUMN access_count INTEGER NOT NULL DEFAULT 0",
            ] {
                try? db.execute(sql: ddl)
            }
            try db.execute(sql: "DELETE FROM insights")
            try db.execute(sql: "DELETE FROM insights_fts")
            // All three match "decay"; they differ only by importance, recency,
            // and supersession so the lifecycle ranking is what orders them.
            let rows: [(id: String, content: String, importance: Int, createdAt: String, superseded: String?)] = [
                ("old-high", "memory decay policy details", 9, "2026-01-01 00:00:00", nil),
                ("new-low", "memory decay quick note", 2, "2026-06-25 00:00:00", nil),
                ("superseded", "memory decay obsolete fact", 10, "2026-06-25 00:00:00", "new-low"),
            ]
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO insights
                      (id, content, importance, created_at, insight_type, superseded_by, access_count)
                    VALUES (?, ?, ?, ?, 'semantic', ?, 0)
                    """,
                    arguments: [row.id, row.content, row.importance, row.createdAt, row.superseded]
                )
                try db.execute(
                    sql: "INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)",
                    arguments: [row.id, row.content]
                )
            }
        }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_memory","arguments":{"query":"decay"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "ENGRAM_MCP_NOW": "2026-06-26T00:00:00.000Z",
            ]
        )

        XCTAssertNil(capture.response.error)
        let memories = try XCTUnwrap(
            capture.ordered["result"]?["structuredContent"]?["memories"]?.arrayValue
        )
        let ids = memories.compactMap { $0["id"]?.stringValue }
        // Superseded row is excluded entirely.
        XCTAssertFalse(ids.contains("superseded"), "\(ids)")
        XCTAssertEqual(ids.count, 2, "\(ids)")
        // A recent memory outranks a 6-month-old one even at much higher
        // importance (30-day half-life decays the old row to near zero).
        XCTAssertEqual(ids.first, "new-low", "\(ids)")
        let warning = capture.ordered["result"]?["structuredContent"]?["warning"]?.stringValue
        XCTAssertEqual(warning?.contains("ranked by importance and recency"), true, "\(warning ?? "nil")")
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
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        try seedGetContextEnvironmentFixture(dbURL)

        try assertToolCallMatchesGolden(
            tool: "get_context",
            arguments: """
            {"cwd":"/Users/test/work/engram","detail":"abstract","include_environment":true,"sort_by":"score"}
            """,
            goldenFixture: "mcp-golden/get_context.engram.abstract_environment.json",
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
                "ENGRAM_MCP_NOW": "2026-01-09T12:00:00.000Z",
            ]
        )
    }

    func testGetContextFullEnvironmentMatchesGolden() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        try seedGetContextEnvironmentFixture(dbURL)

        try assertToolCallMatchesGolden(
            tool: "get_context",
            arguments: """
            {"cwd":"/Users/test/work/engram","detail":"full","include_environment":true,"sort_by":"score"}
            """,
            goldenFixture: "mcp-golden/get_context.engram.full_environment.json",
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
                "ENGRAM_MCP_NOW": "2026-01-09T12:00:00.000Z",
            ]
        )
    }

    func testGetContextOverviewEnvironmentMatchesGolden() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        try seedGetContextEnvironmentFixture(dbURL)

        try assertToolCallMatchesGolden(
            tool: "get_context",
            arguments: """
            {"cwd":"/Users/test/work/engram","detail":"overview","include_environment":true,"sort_by":"score"}
            """,
            goldenFixture: "mcp-golden/get_context.engram.overview_environment.json",
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
                "ENGRAM_MCP_NOW": "2026-01-09T12:00:00.000Z",
            ]
        )
    }

    func testGetContextEnvironmentIgnoresMissingOptionalTables() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        try dropGetContextOptionalEnvironmentTables(dbURL)

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/engram","detail":"full","include_environment":true,"sort_by":"score"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
                "ENGRAM_MCP_NOW": "2026-01-09T12:00:00.000Z",
            ]
        )

        XCTAssertNil(capture.response.error)
        let text = capture.ordered["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        XCTAssertTrue(text?.contains("[windsurf] 2026-01-06") ?? false)
        XCTAssertTrue(text?.contains("Cost today: $0.18") ?? false)
    }

    func testGetContextEnvironmentReportsOptionalSchemaErrors() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        try corruptGetContextAlertsSchema(dbURL)

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/engram","detail":"full","include_environment":true,"sort_by":"score"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
                "ENGRAM_MCP_NOW": "2026-01-09T12:00:00.000Z",
            ]
        )

        XCTAssertNil(capture.response.error)
        let text = capture.ordered["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        XCTAssertTrue(text?.contains("Cost today: $0.18") ?? false)
        XCTAssertTrue(capture.stderr.contains("[get_context] alerts error:"), capture.stderr)
        XCTAssertTrue(capture.stderr.contains("no such column"), capture.stderr)
    }

    func testGetContextEnvironmentBudgetKeepsCostAndAlerts() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        try seedGetContextEnvironmentFixture(dbURL)

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/engram","detail":"full","include_environment":true,"sort_by":"score","max_tokens":120}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
                "ENGRAM_MCP_NOW": "2026-01-09T12:00:00.000Z",
            ]
        )

        XCTAssertNil(capture.response.error)
        let text = try XCTUnwrap(capture.ordered["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains("Cost today: $0.18"))
        XCTAssertTrue(text.contains("Alerts (1):"))
        XCTAssertFalse(text.contains("File hotspots (7d):"))
        XCTAssertFalse(text.contains("Git repos with changes"))
        XCTAssertFalse(text.contains("Recent errors (24h):"))
    }

    func testGetContextOverviewEnvironmentBudgetPrunesLowPriorityBlocks() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        try seedGetContextEnvironmentFixture(dbURL)

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/engram","detail":"overview","include_environment":true,"sort_by":"score","max_tokens":120}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
                "ENGRAM_MCP_NOW": "2026-01-09T12:00:00.000Z",
            ]
        )

        XCTAssertNil(capture.response.error)
        let text = try XCTUnwrap(capture.ordered["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains("Cost today: $0.18"))
        XCTAssertTrue(text.contains("Alerts (1):"))
        XCTAssertTrue(text.contains("Top tools (7d):"))
        XCTAssertTrue(text.contains("Cost suggestions (1):"))
        XCTAssertFalse(text.contains("File hotspots (7d):"))
        XCTAssertFalse(text.contains("Git repos with changes"))
        XCTAssertFalse(text.contains("Recent errors (24h):"))
    }

    func testGetContextCostTodayUsesUTCWindow() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mcp-contract.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fixturePath("mcp-contract.sqlite")),
            to: dbURL
        )
        try seedGetContextTimezoneCostFixture(dbURL)

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/engram","detail":"abstract","include_environment":true,"sort_by":"score"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbURL.path,
                "ENGRAM_MCP_NOW": "2026-01-09T12:00:00.000Z",
                "TZ": "Asia/Shanghai",
            ]
        )

        XCTAssertNil(capture.response.error)
        let text = try XCTUnwrap(capture.ordered["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains("Cost today: $0.25"), text)
        XCTAssertFalse(text.contains("Cost today: $10.24"), text)
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
        let targetDir = try temporaryFixtureCopy(
            "mcp-runtime/engram",
            prefix: "engram-mcp-link-sessions"
        )
        defer { try? FileManager.default.removeItem(atPath: targetDir) }
        let canonicalTargetDir = fixturePath("mcp-runtime/engram")
        let conversationLogDir = "\(targetDir)/conversation_log"
        try? FileManager.default.removeItem(atPath: conversationLogDir)
        let structured = TestJSONValue.object([
            "created": .int(6),
            "skipped": .int(0),
            "errors": .array([]),
            "targetDir": .string(targetDir),
            "projectNames": .array([
                .string("engram"),
                .string("engram-legacy"),
                .string("engram-mcp"),
            ]),
        ])
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
                    targetDir
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
            {"targetDir":"\(targetDir)"}
            """,
            goldenFixture: "mcp-golden/link_sessions.engram.json",
            environment: [
                "ENGRAM_MCP_SERVICE_SOCKET": service.socketPath,
            ],
            pathNormalizations: [targetDir: canonicalTargetDir]
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

    func testProjectReviewClassifiesClaudeCodeDirsWithNonAlnumEncoding() throws {
        try assertToolCallMatchesGolden(
            tool: "project_review",
            arguments: """
            {"old_path":"/Users/test/work/CCTV_Admin-old","new_path":"/Users/test/work/CCTV_Admin","max_items":100}
            """,
            goldenFixture: "mcp-golden/project_review.cc-nonalnum.json",
            environment: [
                "HOME": fixturePath("mcp-runtime/review-home"),
            ]
        )
    }

    func testGetSessionMatchesGolden() throws {
        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-get-session-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "codex",
            filePath: fixturePath("mcp-runtime/transcripts/rollout-mcp-transcript-01.jsonl"),
            messageCount: 3,
            userMessageCount: 2,
            assistantMessageCount: 1,
            toolMessageCount: 0
        )

        try assertToolCallMatchesGolden(
            tool: "get_session",
            arguments: """
            {"id":"mcp-transcript-01","page":1}
            """,
            goldenFixture: "mcp-golden/get_session.transcript.json",
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )
    }

    func testGetSessionEmptyRolesReturnsAllMessages() throws {
        // Regression: roles:[] previously made the role filter `[].contains`
        // always false, silently returning zero messages. An empty (or
        // whitespace-only) roles array must behave like no filter.
        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-empty-roles-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "codex",
            filePath: fixturePath("mcp-runtime/transcripts/rollout-mcp-transcript-01.jsonl"),
            messageCount: 3,
            userMessageCount: 2,
            assistantMessageCount: 1,
            toolMessageCount: 0
        )

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","page":1,"roles":[]}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )

        guard case .array(let messages)? = capture.ordered["result"]?["structuredContent"]?["messages"] else {
            XCTFail("Expected get_session messages array")
            return
        }
        XCTAssertEqual(messages.count, 3, "empty roles must not filter out every message")
        let roles = messages.compactMap { $0["role"]?.stringValue }
        XCTAssertEqual(roles, ["user", "assistant", "user"])
    }

    func testGetSessionFallsBackWhenLocalReadablePathIsStale() throws {
        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-stale-local-readable-path-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let transcriptPath = fixturePath("mcp-runtime/transcripts/rollout-mcp-transcript-01.jsonl")
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "codex",
            filePath: transcriptPath,
            messageCount: 3,
            userMessageCount: 2,
            assistantMessageCount: 1,
            toolMessageCount: 0
        )
        let stalePath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-\(UUID().uuidString).jsonl")
            .path
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO session_local_state (session_id, local_readable_path)
                VALUES ('mcp-transcript-01', ?)
                ON CONFLICT(session_id) DO UPDATE
                SET local_readable_path = excluded.local_readable_path
                """,
                arguments: [stalePath]
            )
        }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","page":1}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )

        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"])
        XCTAssertEqual(structured["session"]?["filePath"]?.stringValue, transcriptPath)
        let messages = try XCTUnwrap(structured["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 3)
    }

    func testGetSessionReadsQwenTranscriptThroughAdapterRegistry() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root
            .appendingPathComponent(".qwen/projects/-tmp-qwen-project/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        let transcript = chatsDir.appendingPathComponent("mcp-transcript-01.jsonl")
        try #"""
        {"uuid":"qwen-system","sessionId":"mcp-transcript-01","timestamp":"2026-04-23T01:00:00Z","type":"user","cwd":"/tmp/qwen-project","message":{"role":"user","parts":[{"text":"\nYou are Qwen Code, an interactive CLI agent. Analyze the current directory."}]}}
        {"uuid":"qwen-user","sessionId":"mcp-transcript-01","timestamp":"2026-04-23T01:00:01Z","type":"user","cwd":"/tmp/qwen-project","message":{"role":"user","parts":[{"text":"Build the dashboard."}]}}
        {"uuid":"qwen-assistant","sessionId":"mcp-transcript-01","timestamp":"2026-04-23T01:00:02Z","type":"assistant","cwd":"/tmp/qwen-project","model":"qwen3.5-plus","message":{"role":"model","parts":[{"text":"Dashboard ready."}]}}
        """#.write(to: transcript, atomically: true, encoding: .utf8)

        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-qwen-transcript-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "qwen",
            filePath: transcript.path,
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0
        )

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","page":1}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "CFFIXED_USER_HOME": root.path,
                "HOME": root.path,
            ]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        let structured = try XCTUnwrap(result["structuredContent"])
        let messages = try XCTUnwrap(structured["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.compactMap { $0["role"]?.stringValue }, ["user", "assistant"])
        XCTAssertEqual(messages.compactMap { $0["content"]?.stringValue }, ["Build the dashboard.", "Dashboard ready."])

        guard case .array(let content)? = result["content"],
              let text = content.first?["text"]?.stringValue else {
            return XCTFail("Expected get_session text content")
        }
        XCTAssertFalse(text.contains("You are Qwen Code"), "Qwen system injection must not leak into MCP transcript output")
    }

    func testGetSessionReadsKimiTranscriptThroughNativeAdapter() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root
            .appendingPathComponent(".kimi/sessions/ws-001/mcp-transcript-01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let transcript = sessionDir.appendingPathComponent("context.jsonl")
        try """
        {"role":"user","content":"Plan the refactor.","timestamp":"2026-04-23T01:00:00Z"}
        {"role":"assistant","content":[{"type":"text","text":"Refactor plan ready."}],"timestamp":"2026-04-23T01:00:01Z"}
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-kimi-transcript-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "kimi",
            filePath: transcript.path,
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0
        )

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","page":1}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "CFFIXED_USER_HOME": root.path,
                "HOME": root.path,
            ]
        )

        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"])
        let messages = try XCTUnwrap(structured["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.compactMap { $0["role"]?.stringValue }, ["user", "assistant"])
        XCTAssertEqual(messages.compactMap { $0["content"]?.stringValue }, ["Plan the refactor.", "Refactor plan ready."])
    }

    func testGetSessionPaginatesLargeCodexTranscript() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("large-codex-session.jsonl")
        let lines = (1...55).map { index in
            let role = index % 2 == 0 ? "assistant" : "user"
            return #"{"timestamp":"2026-04-23T01:00:00Z","type":"response_item","payload":{"type":"message","role":"\#(role)","content":[{"type":"input_text","text":"visible message \#(index)"}]}}"#
        }
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-large-transcript-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "codex",
            filePath: transcript.path,
            messageCount: 55,
            userMessageCount: 28,
            assistantMessageCount: 27,
            toolMessageCount: 0
        )

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","page":2}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )

        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"])
        XCTAssertEqual(structured["currentPage"]?.intValue, 2)
        XCTAssertEqual(structured["totalPages"]?.intValue, 2)
        let messages = try XCTUnwrap(structured["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 5)
        let contents = messages.compactMap { $0["content"]?.stringValue }
        XCTAssertEqual(contents, (51...55).map { "visible message \($0)" })
    }

    func testGetSessionTruncatesOversizedJSONLMessageAndTextMirror() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("oversized-codex-session.jsonl")
        let largeBody = String(repeating: "x", count: 12_000)
        try """
        {"timestamp":"2026-04-23T01:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\(largeBody)"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-oversized-jsonl-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "codex",
            filePath: transcript.path,
            messageCount: 1,
            userMessageCount: 1,
            assistantMessageCount: 0,
            toolMessageCount: 0
        )

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","page":1}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        let messages = try XCTUnwrap(result["structuredContent"]?["messages"]?.arrayValue)
        let messageContent = try XCTUnwrap(messages.first?["content"]?.stringValue)
        XCTAssertLessThan(messageContent.count, largeBody.count)
        XCTAssertTrue(messageContent.contains("[truncated"), messageContent)
        XCTAssertFalse(messageContent.contains(largeBody), "structuredContent must not carry unbounded JSONL message text")

        guard case .array(let content)? = result["content"],
              let text = content.first?["text"]?.stringValue else {
            return XCTFail("Expected text content")
        }
        XCTAssertFalse(text.contains(largeBody), "MCP text mirror must not duplicate a huge structured payload")
        XCTAssertLessThan(text.count, 4_096)
    }

    func testGetSessionRejectsOversizedGeminiJSONTranscript() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("oversized-gemini-session.json")
        let largeBody = String(repeating: "x", count: 512)
        try """
        {"messages":[{"type":"user","content":"\(largeBody)"}]}
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-oversized-gemini-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "gemini-cli",
            filePath: transcript.path,
            messageCount: 1,
            userMessageCount: 1,
            assistantMessageCount: 0,
            toolMessageCount: 0
        )

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","page":1}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "ENGRAM_MAX_FULL_JSON_TRANSCRIPT_BYTES": "128",
            ]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertEqual(result["structuredContent"]?["code"]?.stringValue, "transcriptTooLarge")
        guard case .array(let content)? = result["content"],
              let text = content.first?["text"]?.stringValue else {
            return XCTFail("Expected text error content")
        }
        XCTAssertTrue(text.contains("gemini-cli transcript is too large"), text)
        XCTAssertFalse(text.contains(largeBody), "error must not echo transcript contents")
    }

    func testGetSessionRejectsUnknownRoleEnumValue() throws {
        // roles is declared as an array with items.enum [user, assistant];
        // a bogus element (e.g. "banana") must be rejected, not silently
        // accepted by the array-type check.
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","roles":["banana"]}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
            ]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        guard case .array(let content)? = result["content"] else {
            XCTFail("Expected error content")
            return
        }
        let message = content.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("roles"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("one of"), message)
    }

    func testToolCallRejectsMissingRequiredArgument() throws {
        // The top-level `required` array must be enforced before dispatch:
        // get_memory requires `query`, so an empty argument object must surface
        // a consistent invalidArguments error.
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_memory","arguments":{}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
            ]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        guard case .array(let content)? = result["content"] else {
            XCTFail("Expected error content")
            return
        }
        let message = content.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("query is required"), message)
    }

    func testGetSessionFiltersToolMessagesLikeSwiftDisplay() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-mcp-commandcode-\(UUID().uuidString)", isDirectory: true)
        let transcript = root
            .appendingPathComponent(".commandcode/projects/-Users-test-my-project/commandcode-session.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"id":"msg-001","sessionId":"commandcode-session-001","parentId":null,"role":"user","cwd":"/Users/test/my-project","content":[{"type":"text","text":"检查解析器"}],"timestamp":"2026-05-20T02:00:00.000Z"}
        {"id":"msg-002","sessionId":"commandcode-session-001","parentId":"msg-001","role":"assistant","cwd":"/Users/test/my-project","model":"command-code-agent","content":[{"type":"text","text":"我会检查解析器。"},{"type":"tool-call","toolCallId":"tool-001","toolName":"read_file","args":{"path":"/Users/test/my-project/src/parser.ts"}}],"timestamp":"2026-05-20T02:00:01.000Z"}
        {"id":"msg-003","sessionId":"commandcode-session-001","parentId":"msg-002","role":"tool","cwd":"/Users/test/my-project","content":[{"type":"tool-result","toolCallId":"tool-001","toolName":"read_file","output":"file contents omitted"}],"timestamp":"2026-05-20T02:00:02.000Z"}
        {"id":"msg-004","sessionId":"commandcode-session-001","parentId":"msg-003","role":"assistant","cwd":"/Users/test/my-project","content":"   ","timestamp":"2026-05-20T02:00:03.000Z"}
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-commandcode-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "commandcode",
            filePath: transcript.path,
            messageCount: 3,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 1
        )

        let result = try getSessionTextFromMCP(dbPath: dbPath)
        XCTAssertTrue(result.contains(#""role": "user""#), result)
        XCTAssertTrue(result.contains(#""role": "assistant""#), result)
        XCTAssertFalse(result.contains(#""role": "tool""#), result)
        XCTAssertFalse(result.contains("file contents omitted"), result)
        XCTAssertFalse(result.contains(#""content": "   ""#), result)
    }

    func testGetSessionFiltersSystemAndAgentCommMessagesLikeSwiftDisplay() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-mcp-codex-visibility-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("codex-session.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"timestamp":"2026-04-23T01:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp\\nhidden system"}]}}
        {"timestamp":"2026-04-23T01:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<command-name>hidden agent comm</command-name>"}]}}
        {"timestamp":"2026-04-23T01:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"visible user"}]}}
        {"timestamp":"2026-04-23T01:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"visible assistant"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-codex-visibility-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "codex",
            filePath: transcript.path,
            messageCount: 4,
            userMessageCount: 3,
            assistantMessageCount: 1,
            toolMessageCount: 0
        )

        let result = try getSessionTextFromMCP(dbPath: dbPath)
        XCTAssertTrue(result.contains("visible user"), result)
        XCTAssertTrue(result.contains("visible assistant"), result)
        XCTAssertFalse(result.contains("hidden system"), result)
        XCTAssertFalse(result.contains("hidden agent comm"), result)
    }

    func testGetSessionReadsAntigravityLegacySourceThroughAdapterRegistry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-mcp-antigravity-legacy-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("legacy-cache.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"type":"metadata","id":"legacy-ag","createdAt":"2026-05-20T03:00:00Z","updatedAt":"2026-05-20T03:00:02Z"}
        {"role":"user","content":"<SYSTEM_MESSAGE>hidden legacy system</SYSTEM_MESSAGE>"}
        {"role":"user","content":"Review legacy cache"}
        {"role":"assistant","content":"Done"}
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-antigravity-legacy-db"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try rewriteTranscriptFixtureSession(
            dbPath: dbPath,
            source: "antigravity-legacy",
            filePath: transcript.path,
            messageCount: 3,
            userMessageCount: 2,
            assistantMessageCount: 1,
            toolMessageCount: 0
        )

        let result = try getSessionTextFromMCP(dbPath: dbPath)
        XCTAssertTrue(result.contains(#""source": "antigravity-legacy""#), result)
        XCTAssertTrue(result.contains("Review legacy cache"), result)
        XCTAssertTrue(result.contains("Done"), result)
        XCTAssertFalse(result.contains("hidden legacy system"), result)
    }

    func testExportMatchesGolden() throws {
        let homeDir = try temporaryFixtureCopy(
            "mcp-runtime/export-home",
            prefix: "engram-mcp-export-home"
        )
        defer { try? FileManager.default.removeItem(atPath: homeDir) }
        let canonicalHomeDir = fixturePath("mcp-runtime/export-home")
        let exportDir = "\(homeDir)/.engram/exports"
        try? FileManager.default.removeItem(atPath: exportDir)
        let service = try makeReachableServiceSocketServer(exportHomeDir: homeDir)
        try service.start()
        defer { service.stop() }
        try assertToolCallMatchesGolden(
            tool: "export",
            arguments: """
            {"id":"mcp-transcript-01","format":"json"}
            """,
            goldenFixture: "mcp-golden/export.transcript.json",
            environment: [
                "HOME": homeDir,
                "ENGRAM_MCP_SERVICE_SOCKET": service.socketPath,
            ],
            pathNormalizations: [homeDir: canonicalHomeDir]
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

    func testHandoffSessionIdFocusesSingleSession() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"handoff","arguments":{"cwd":"/Users/test/work/engram","sessionId":"mcp-fixture-02","format":"markdown"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
            ]
        )

        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"])
        XCTAssertEqual(structured["sessionCount"]?.intValue, 1)
        let brief = try XCTUnwrap(structured["brief"]?.stringValue)
        XCTAssertTrue(brief.contains("engram codex session 2"), brief)
        XCTAssertFalse(brief.contains("engram windsurf session 6"), brief)
    }

    func testHandoffIncludesCostDurationModelAndSuggestedPrompt() throws {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"handoff","arguments":{"cwd":"/Users/test/work/engram","format":"markdown"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
            ]
        )

        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"])
        XCTAssertEqual(structured["sessionCount"]?.intValue, 6)
        let brief = try XCTUnwrap(structured["brief"]?.stringValue)
        XCTAssertTrue(brief.contains("**Last active**:"), brief)
        XCTAssertTrue(brief.contains("via windsurf (sonnet)"), brief)
        XCTAssertTrue(brief.contains("19 msgs, 35m, $0.07"), brief)
        XCTAssertTrue(brief.contains("**Last task**:"), brief)
        XCTAssertTrue(brief.contains("**Suggested prompt**:"), brief)
    }

    func testHandoffRelativeTimeUsesLocalTimezoneForRecentSessionList() throws {
        let dbPath = try temporaryFixtureCopy(
            "mcp-contract.sqlite",
            prefix: "engram-mcp-handoff-timezone"
        )
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let start = Date().addingTimeInterval(-130 * 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let startTime = formatter.string(from: start)
        let dbQueue = try DatabaseQueue(path: dbPath)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE sessions
                SET start_time = ?, end_time = NULL
                WHERE id = 'mcp-fixture-06'
                """,
                arguments: [startTime]
            )
        }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"handoff","arguments":{"cwd":"/Users/test/work/engram","format":"markdown"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "TZ": "Asia/Shanghai",
            ]
        )

        let structured = try XCTUnwrap(capture.ordered["result"]?["structuredContent"])
        let brief = try XCTUnwrap(structured["brief"]?.stringValue)
        XCTAssertTrue(brief.contains("**Last active**: 2h ago via windsurf"), brief)
        XCTAssertFalse(brief.contains("**Last active**: just now"), brief)
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

    func testDeleteInsightRoutesThroughServiceSocket() throws {
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
            case "deleteInsight":
                let body = try request.decodePayload([String: TestJSONValue].self)
                XCTAssertEqual(body["id"]?.stringValue, "insight-123")
                return try request.success(
                    .object([
                        "id": .string("insight-123"),
                        "deleted": .bool(true),
                    ]),
                    databaseGeneration: 1
                )
            default:
                throw NSError(domain: "MockServiceSocketServer", code: 105)
            }
        }
        try server.start()
        defer { server.stop() }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_insight","arguments":{"id":"insight-123"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
                "ENGRAM_MCP_SERVICE_SOCKET": server.socketPath,
            ]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        XCTAssertEqual(result["structuredContent"]?["id"]?.stringValue, "insight-123")
        XCTAssertEqual(result["structuredContent"]?["deleted"]?.boolValue, true)
    }

    func testHideSessionRoutesThroughServiceSocket() throws {
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
            case "setSessionHidden":
                let body = try request.decodePayload([String: TestJSONValue].self)
                XCTAssertEqual(body["sessionId"]?.stringValue, "session-123")
                XCTAssertEqual(body["hidden"]?.boolValue, true)
                return try request.success(.object([:]), databaseGeneration: 1)
            default:
                throw NSError(domain: "MockServiceSocketServer", code: 106)
            }
        }
        try server.start()
        defer { server.stop() }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hide_session","arguments":{"session_id":"session-123"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
                "ENGRAM_MCP_SERVICE_SOCKET": server.socketPath,
            ]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        XCTAssertEqual(result["structuredContent"]?["session_id"]?.stringValue, "session-123")
        XCTAssertEqual(result["structuredContent"]?["hidden"]?.boolValue, true)
    }

    func testHideSessionPropagatesServiceNotFound() throws {
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
            case "setSessionHidden":
                return try request.failure(name: "SessionNotFound", message: "session-not-found")
            default:
                throw NSError(domain: "MockServiceSocketServer", code: 107)
            }
        }
        try server.start()
        defer { server.stop() }

        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hide_session","arguments":{"session_id":"missing-session"}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": fixturePath("mcp-contract.sqlite"),
                "ENGRAM_MCP_SERVICE_SOCKET": server.socketPath,
            ]
        )

        let result = try XCTUnwrap(capture.ordered["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        guard case .array(let content)? = result["content"] else {
            return XCTFail("Expected error content")
        }
        let message = content.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("session-not-found"), message)
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
        // Pass minimal valid required arguments per tool. Required-argument
        // validation now runs before dispatch, so empty args would surface
        // invalidArguments instead of reaching the serviceUnavailable branch.
        // The bogus socket still guarantees we fail closed before any side
        // effect, exercising the serviceUnavailable path under test.
        let validArguments = [
            "project_move": #"{"src":"/tmp/no-such-src","dst":"/tmp/no-such-dst","dry_run":true}"#,
            "project_archive": #"{"src":"/tmp/no-such-src","dry_run":true}"#,
            "project_undo": #"{"migration_id":"no-such-migration"}"#,
            "project_move_batch": #"{"yaml":"{}","dry_run":true}"#,
        ]
        for (index, tool) in ["project_move", "project_archive", "project_undo", "project_move_batch"].enumerated() {
            let capture = try rpc(
                """
                {"jsonrpc":"2.0","id":\(20 + index),"method":"tools/call","params":{"name":"\(tool)","arguments":\(validArguments[tool]!)}}
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
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()

        if let data = "\(request)\n".data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = try XCTUnwrap(String(data: outputData, encoding: .utf8))
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let firstLine = try XCTUnwrap(output.split(separator: "\n").first.map(String.init))
        let responseData = try XCTUnwrap(firstLine.data(using: .utf8))
        var parser = OrderedTestJSONParser(text: firstLine)
        return RPCCapture(
            rawLine: firstLine,
            response: try JSONDecoder().decode(TestJSONRPCResponse.self, from: responseData),
            ordered: try parser.parse(),
            stderr: stderr
        )
    }

    private func rpcSession(
        _ requests: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [OrderedTestJSONValue] {
        let process = Process()
        process.executableURL = executableURL()
        process.environment = ProcessInfo.processInfo.environment
            .merging(["TZ": "UTC"]) { _, new in new }
            .merging(environment) { _, new in new }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        for request in requests {
            if let data = "\(request)\n".data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
        }
        try stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("EngramMCP session did not exit within \(timeout)s", file: file, line: line)
        }

        let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(stderr, "", file: file, line: line)
        let lines = output.split(separator: "\n").map(String.init)
        return try lines.map { rawLine in
            var parser = OrderedTestJSONParser(text: rawLine)
            return try parser.parse()
        }
    }

    private func executableURL() -> URL {
        Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("EngramMCP")
    }

    private struct ProcessCapture {
        let stdout: String
        let stderr: String
        let exitStatus: Int32
    }

    private func runExecutable(
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProcessCapture {
        let process = Process()
        process.executableURL = executableURL()
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("EngramMCP did not exit within \(timeout)s", file: file, line: line)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessCapture(stdout: stdout, stderr: stderr, exitStatus: process.terminationStatus)
    }

    private func seedGetContextEnvironmentFixture(_ dbURL: URL) throws {
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO alerts (ts, rule, severity, message, value, threshold)
                VALUES ('2026-01-09T10:00:00.000Z', 'mcp_index_lag', 'critical',
                        'MCP indexing lag detected', 12, 5)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO git_repos (
                  path, name, branch, dirty_count, untracked_count, unpushed_count,
                  last_commit_hash, last_commit_msg, last_commit_at, session_count, probed_at
                )
                VALUES (
                  '/Users/test/work/engram', 'engram', 'perf/transcript-paging', 3, 1, 2,
                  'abc1234', 'fixture commit', '2026-01-09T08:00:00.000Z', 6,
                  '2026-01-09T11:00:00.000Z'
                )
                """
            )
            try db.execute(
                sql: """
                INSERT INTO logs (ts, level, module, message, source)
                VALUES
                  ('2026-01-09T11:30:00.000Z', 'error', 'mcp', 'transcript parser failed', 'daemon'),
                  ('2026-01-09T11:40:00.000Z', 'error', 'mcp', 'transcript parser failed', 'daemon')
                """
            )
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO session_tools (session_id, tool_name, call_count)
                VALUES
                  ('mcp-fixture-01', 'Glob', 8),
                  ('mcp-fixture-02', 'Write', 7),
                  ('mcp-fixture-03', 'Fetch', 6)
                """
            )
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO session_files (session_id, file_path, action, count)
                VALUES
                  ('mcp-fixture-01', '/Users/test/work/zephyr/src/index.ts', 'Edit', 6),
                  ('mcp-fixture-02', '/Users/test/work/orion/src/index.ts', 'Edit', 5),
                  ('mcp-fixture-03', '/Users/test/work/atlas/src/index.ts', 'Edit', 4)
                """
            )
        }
    }

    private func seedGetContextTimezoneCostFixture(_ dbURL: URL) throws {
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE session_costs SET cost_usd = 0")
            try db.execute(
                sql: "UPDATE sessions SET start_time = ? WHERE id = ?",
                arguments: ["2026-01-08T18:00:00.000Z", "mcp-fixture-01"]
            )
            try db.execute(
                sql: "UPDATE sessions SET start_time = ? WHERE id = ?",
                arguments: ["2026-01-09T02:00:00.000Z", "mcp-fixture-02"]
            )
            try db.execute(
                sql: "UPDATE session_costs SET cost_usd = ? WHERE session_id = ?",
                arguments: [9.99, "mcp-fixture-01"]
            )
            try db.execute(
                sql: "UPDATE session_costs SET cost_usd = ? WHERE session_id = ?",
                arguments: [0.25, "mcp-fixture-02"]
            )
        }
    }

    private func seedProjectLikeWildcardFixture(at dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count, tier, summary
                )
                VALUES
                  ('mcp-like-literal', 'codex', '2026-01-10T10:00:00.000Z',
                   '/Users/test/work/my_repo', 'my_repo', '/tmp/mcp-like-literal.jsonl', 1, 'normal',
                   'literal project'),
                  ('mcp-like-wildcard', 'codex', '2026-01-10T10:01:00.000Z',
                   '/Users/test/work/myXrepo', 'myXrepo', '/tmp/mcp-like-wildcard.jsonl', 1, 'normal',
                   'wildcard project')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO sessions_fts(session_id, content)
                VALUES
                  ('mcp-like-literal', 'wildcardneedle literal'),
                  ('mcp-like-wildcard', 'wildcardneedle wildcard')
                """
            )
        }
    }

    private func dropGetContextOptionalEnvironmentTables(_ dbURL: URL) throws {
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            for table in ["alerts", "git_repos", "logs", "session_files"] {
                try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
            }
        }
    }

    private func corruptGetContextAlertsSchema(_ dbURL: URL) throws {
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: "DROP TABLE alerts")
            try db.execute(
                sql: """
                CREATE TABLE alerts (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  ts TEXT NOT NULL,
                  severity TEXT NOT NULL,
                  message TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                INSERT INTO alerts (ts, severity, message)
                VALUES ('2026-01-09T10:00:00.000Z', 'critical', 'schema drift fixture')
                """
            )
        }
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

    private func sourcePath(_ relativePath: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
        environment: [String: String] = [:],
        pathNormalizations: [String: String] = [:]
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
        XCTAssertEqual(
            normalizeFixturePaths(in: actual, pathNormalizations: pathNormalizations),
            normalizeFixturePaths(in: expected, pathNormalizations: pathNormalizations)
        )
    }

    private func normalizeFixturePaths(
        in text: String,
        pathNormalizations: [String: String] = [:]
    ) -> String {
        var normalized = text
        for (source, replacement) in pathNormalizations {
            normalized = normalized.replacingOccurrences(of: source, with: replacement)
        }

        return normalizeAbsoluteFixtureRoots(in: normalized)
    }

    private func normalizeAbsoluteFixtureRoots(in text: String) -> String {
        let pattern = #"(?:/[^\s"\\]+)+/tests/fixtures"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<fixture-root>")
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

    private func temporaryFixtureCopy(_ relativePath: String, prefix: String) throws -> String {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.copyItem(
            atPath: fixturePath(relativePath),
            toPath: destination.path
        )
        return destination.path
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rewriteTranscriptFixtureSession(
        dbPath: String,
        source: String,
        filePath: String,
        messageCount: Int,
        userMessageCount: Int,
        assistantMessageCount: Int,
        toolMessageCount: Int
    ) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE sessions
                SET source = ?,
                    file_path = ?,
                    message_count = ?,
                    user_message_count = ?,
                    assistant_message_count = ?,
                    tool_message_count = ?
                WHERE id = 'mcp-transcript-01'
                """,
                arguments: [
                    source,
                    filePath,
                    messageCount,
                    userMessageCount,
                    assistantMessageCount,
                    toolMessageCount,
                ]
            )
        }
    }

    private func getSessionTextFromMCP(dbPath: String) throws -> String {
        let capture = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","page":1}}}
            """,
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
            ]
        )
        guard case .array(let content)? = capture.ordered["result"]?["content"] else {
            XCTFail("Expected get_session text content")
            return ""
        }
        return try XCTUnwrap(content.first?["text"]?.stringValue)
    }

    private func makeReachableServiceSocketServer(exportHomeDir: String? = nil) throws -> MockServiceSocketServer {
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
                let homeDir = exportHomeDir ?? self.fixturePath("mcp-runtime/export-home")
                return try request.success(
                    .object([
                        "outputPath": .string("\(homeDir)/.engram/exports/codex-mcp-tran-2026-01-15.json"),
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

        func failure(name: String, message: String, retryPolicy: String = "never") throws -> Data {
            let response = FailureEnvelope(
                requestId: requestId,
                error: .init(name: name, message: message, retryPolicy: retryPolicy)
            )
            return try JSONEncoder().encode(response)
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

private struct MockServerError: Error { let message: String }

/// Minimal localhost HTTP responder for embedding-provider e2e tests. Accepts a
/// connection, ignores the request, and writes a fixed status + JSON body. The
/// spawned MCP process reaches it via `ENGRAM_EMBEDDING_BASE_URL`.
private final class MockHTTPServer {
    private let listenFD: Int32
    let port: UInt16
    private let status: Int
    private let responseBody: Data

    init(status: Int = 200, jsonBody: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MockServerError(message: "socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { close(fd); throw MockServerError(message: "bind() failed") }
        guard listen(fd, 8) == 0 else { close(fd); throw MockServerError(message: "listen() failed") }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        listenFD = fd
        port = UInt16(bigEndian: assigned.sin_port)
        self.status = status
        responseBody = Data(jsonBody.utf8)
    }

    func start() {
        let fd = listenFD
        let status = self.status
        let body = responseBody
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                var buffer = [UInt8](repeating: 0, count: 8192)
                _ = recv(client, &buffer, buffer.count, 0)
                let header = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var out = Data(header.utf8)
                out.append(body)
                _ = out.withUnsafeBytes { send(client, $0.baseAddress, out.count, 0) }
                close(client)
            }
        }
    }

    func stop() { close(listenFD) }
}

private struct RPCCapture {
    let rawLine: String
    let response: TestJSONRPCResponse
    let ordered: OrderedTestJSONValue
    let stderr: String
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

    var intValue: Int? {
        guard case .int(let value) = self else { return nil }
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
