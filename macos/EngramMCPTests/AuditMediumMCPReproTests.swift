import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead

/// Behavioral repros for M9/M18/M19/M24 and MCP-002/MCP-012 driving the shipped EngramMCP binary
/// (MCPToolRegistry → MCPDatabase) with real SQLite fixtures.
final class AuditMediumMCPReproTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fixturePath(_ relativePath: String) -> String {
        repoRoot
            .appendingPathComponent("tests/fixtures")
            .appendingPathComponent(relativePath)
            .path
    }

    private func temporaryFixtureCopy(_ relativePath: String, prefix: String) throws -> String {
        let source = fixturePath(relativePath)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).sqlite")
            .path
        try FileManager.default.copyItem(atPath: source, toPath: dest)
        return dest
    }

    private func executableURL() -> URL {
        Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("EngramMCP")
    }

    private func rpc(
        _ request: String,
        dbPath: String,
        timezone: String = "UTC",
        environment: [String: String] = [:]
    ) throws -> [String: Any] {
        let result = try rpcResult(
            request,
            dbPath: dbPath,
            timezone: timezone,
            environment: environment
        )
        return try XCTUnwrap(
            result["structuredContent"] as? [String: Any],
            "MCP result did not contain structuredContent: \(result)"
        )
    }

    private func rpcResult(
        _ request: String,
        dbPath: String,
        timezone: String = "UTC",
        environment: [String: String] = [:]
    ) throws -> [String: Any] {
        let process = Process()
        process.executableURL = executableURL()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: process.executableURL!.path),
            "EngramMCP missing at \(process.executableURL!.path)"
        )
        // docs/invariants.md #6: executable tests must never resolve ~/.engram.
        let sandbox = try makeHermeticRPCEnvironment(overrides: [
            "TZ": timezone,
            "ENGRAM_MCP_DB_PATH": dbPath,
        ].merging(environment) { _, requested in requested })
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        defer { try? sandbox.databaseKeeper?.close() }
        process.environment = sandbox.environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        if let data = "\(request)\n".data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let output = try XCTUnwrap(String(data: outputData, encoding: .utf8), "stderr=\(stderr)")
        let firstLine = try XCTUnwrap(
            output.split(separator: "\n").first.map(String.init),
            "empty stdout; stderr=\(stderr)"
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(json["result"] as? [String: Any], "raw=\(firstLine)")
    }

    // MARK: - R3 / M5 stats

    func testStatsExcludesSkipTierFromSessionCounts_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-r3-stats")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try seedStatsSkipFixture(at: dbPath)

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"stats","arguments":{"group_by":"source"}}}
            """,
            dbPath: dbPath
        )
        XCTAssertEqual(
            structured["totalSessions"] as? Int,
            1,
            "R3: MCP stats totalSessions must exclude skip-tier (got \(structured))"
        )
        let groups = try XCTUnwrap(structured["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?["key"] as? String, "codex")
        XCTAssertEqual(groups.first?["sessionCount"] as? Int, 1)
    }

    func testStatsIncludesLiteUserMessageCounts_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-lite-user-count")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, assistant_message_count, tool_message_count,
                  tier, hidden_at, orphan_status
                ) VALUES
                  ('normal-user-count', 'codex', '2026-08-23T10:00:00Z',
                   '/work/engram', 'engram', '/tmp/normal.jsonl', 6, 3, 2, 1,
                   'normal', NULL, NULL),
                  ('lite-user-count', 'codex', '2026-08-23T11:00:00Z',
                   '/work/engram', 'engram', '/tmp/lite.jsonl', 12, 7, 3, 2,
                   'lite', NULL, NULL)
                """)
        }

        let structured = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"stats","arguments":{"group_by":"source"}}}"#,
            dbPath: dbPath
        )
        let groups = try XCTUnwrap(structured["groups"] as? [[String: Any]])
        let codex = try XCTUnwrap(groups.first { $0["key"] as? String == "codex" })
        XCTAssertEqual(codex["userMessageCount"] as? Int, 10)
    }

    func testUsageToolsFilterOvernightSessionsByActivityTime_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-activity-time")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, end_time, cwd, project, file_path,
                  message_count, user_message_count, assistant_message_count,
                  instruction_count, human_turn_count, tier, summary
                ) VALUES (
                  'overnight-activity', 'codex', '2026-08-20T20:00:00Z',
                  '2026-08-23T10:00:00Z', '/work/engram', 'engram', '/tmp/overnight.jsonl',
                  2, 1, 1, 2, 1, 'normal', 'overnight activity summary'
                );
                INSERT INTO session_costs (
                  session_id, model, input_tokens, output_tokens, cache_read_tokens,
                  cache_creation_tokens, cost_usd, computed_at
                ) VALUES (
                  'overnight-activity', 'test-model', 10, 5, 0, 0, 1.25,
                  '2026-08-23T10:00:00Z'
                );
                INSERT INTO session_tools (session_id, tool_name, call_count)
                VALUES ('overnight-activity', 'Read', 3);
                """)
        }

        let since = "2026-08-23T00:00:00Z"
        let until = "2026-08-24T00:00:00Z"
        let stats = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"stats","arguments":{"group_by":"source","since":"\#(since)","until":"\#(until)"}}}"#,
            dbPath: dbPath
        )
        let costs = try rpc(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_costs","arguments":{"group_by":"source","since":"\#(since)","until":"\#(until)"}}}"#,
            dbPath: dbPath
        )
        let tools = try rpc(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tool_analytics","arguments":{"group_by":"tool","since":"\#(since)"}}}"#,
            dbPath: dbPath
        )
        let timeline = try rpc(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"project_timeline","arguments":{"project":"engram","since":"\#(since)","until":"\#(until)"}}}"#,
            dbPath: dbPath
        )
        let contextResult = try rpcResult(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/work/engram","include_environment":false}}}"#,
            dbPath: dbPath
        )
        let context = try XCTUnwrap(
            (contextResult["content"] as? [[String: Any]])?.first?["text"] as? String
        )

        XCTAssertEqual(stats["totalSessions"] as? Int, 1)
        XCTAssertEqual(costs["totalCostUsd"] as? Double, 1.25)
        XCTAssertEqual(tools["totalCalls"] as? Int, 3)
        XCTAssertEqual(timeline["total"] as? Int, 1)
        XCTAssertEqual((timeline["timeline"] as? [[String: Any]])?.first?["sessionId"] as? String, "overnight-activity")
        XCTAssertTrue(context.contains("[codex] 2026-08-23 — overnight activity summary"), context)
    }

    // MARK: - M18

    func testListSessionsExcludesChildrenAndSkipByDefault_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-m18")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try seedListSessionsVisibilityFixture(at: dbPath)

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{"limit":50}}}
            """,
            dbPath: dbPath
        )
        let sessions = try XCTUnwrap(structured["sessions"] as? [[String: Any]])
        let ids = Set(sessions.compactMap { $0["id"] as? String })
        XCTAssertTrue(ids.contains("mcp-m18-parent"), "M18: parent must appear (got \(ids))")
        XCTAssertFalse(ids.contains("mcp-m18-child"), "M18: confirmed child must be hidden")
        XCTAssertFalse(ids.contains("mcp-m18-skip"), "M18: skip-tier must be hidden")
        XCTAssertEqual(structured["total"] as? Int, 1)
    }

    func testListSessionsIncludeAllOnlyOverridesHumanDrivenFilter_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-include-all")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try seedListSessionsVisibilityFixture(at: dbPath)

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{"limit":50,"include_all":true}}}
            """,
            dbPath: dbPath
        )
        let sessions = try XCTUnwrap(structured["sessions"] as? [[String: Any]])
        let ids = Set(sessions.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["mcp-m18-parent", "mcp-m18-automated-parent"])
        XCTAssertEqual(structured["total"] as? Int, 2)
        let automated = try XCTUnwrap(sessions.first { $0["id"] as? String == "mcp-m18-automated-parent" })
        XCTAssertEqual(automated["tier"] as? String, "normal")
        XCTAssertTrue(automated.keys.contains("parentSessionId"))
    }

    // MARK: - M9

    func testListSessionsNegativeLimitDoesNotDumpUnbounded_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-m9")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try seedManyTopLevelSessions(at: dbPath, count: 15)

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{"limit":-5,"include_all":true}}}
            """,
            dbPath: dbPath
        )
        let sessions = try XCTUnwrap(structured["sessions"] as? [[String: Any]])
        // Clamp: min(max(-5,1),100) = 1
        XCTAssertEqual(
            sessions.count,
            1,
            "M9: negative limit must clamp to 1, got \(sessions.count)"
        )
    }

    func testSearchUUIDIsCaseInsensitiveAndHonorsSearchVisibility_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-search-uuid")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try seedSearchUUIDVisibilityFixture(at: dbPath)

        func resultIDs(query: String, mode: String = "keyword") throws -> [String] {
            let structured = try rpc(
                """
                {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"\(query)","mode":"\(mode)","limit":10}}}
                """,
                dbPath: dbPath
            )
            let results = try XCTUnwrap(structured["results"] as? [[String: Any]])
            return results.compactMap { ($0["session"] as? [String: Any])?["id"] as? String }
        }

        XCTAssertEqual(
            try resultIDs(query: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", mode: "semantic"),
            ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"],
            "UUID lookup must run before semantic availability and match case-insensitively."
        )
        for excluded in [
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        ] {
            XCTAssertEqual(try resultIDs(query: excluded), [], "Search UUID leaked \(excluded)")
        }
    }

    // MARK: - M19

    func testGetCostsExcludesHiddenAndSkipSessions_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-m19")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try seedCostVisibilityFixture(at: dbPath)

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_costs","arguments":{"group_by":"model"}}}
            """,
            dbPath: dbPath
        )
        let totalCost = try XCTUnwrap(
            structured["totalCostUsd"] as? Double ?? (structured["totalCostUsd"] as? NSNumber)?.doubleValue,
            "missing totalCostUsd in \(structured)"
        )
        // Visible $1.0; hidden $99 and skip-tier cost rows are excluded.
        XCTAssertEqual(totalCost, 1.0, accuracy: 0.001, "M19 structured=\(structured)")
        XCTAssertEqual(structured["unpricedNoPriceSessions"] as? Int, 0, "ARCH-001B structured=\(structured)")
    }

    // MARK: - M24

    func testGetCostsDayBucketsUseLocaltime_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-m24")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        // 2026-03-15 16:00 UTC == 2026-03-16 00:00 Asia/Shanghai (UTC+8).
        try seedDayBucketFixture(at: dbPath, startTimeUTC: "2026-03-15T16:00:00.000Z")

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_costs","arguments":{"group_by":"day"}}}
            """,
            dbPath: dbPath,
            timezone: "Asia/Shanghai"
        )
        let breakdown = try XCTUnwrap(structured["breakdown"] as? [[String: Any]], "structured=\(structured)")
        let keys = breakdown.compactMap { $0["key"] as? String }
        XCTAssertTrue(
            keys.contains("2026-03-16"),
            "M24: Asia/Shanghai local day must be 2026-03-16, got keys=\(keys)"
        )
        XCTAssertFalse(
            keys.contains("2026-03-15"),
            "M24: must not use UTC day 2026-03-15 under TZ=Asia/Shanghai"
        )
    }

    // MARK: - MCP-002 / MCP-012

    func testToolAnalyticsMatchesListSessionsDefaultVisibility_repro() throws {
        let dbPath = try secondaryVisibilityFixture(prefix: "engram-mcp-b2-tools")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try assertOnlyVisibleSessionIsListed(at: dbPath)

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tool_analytics","arguments":{"project":"b2-visibility","group_by":"tool"}}}
            """,
            dbPath: dbPath
        )
        XCTAssertEqual(structured["totalCalls"] as? Int, 1, "structured=\(structured)")
        let tools = try XCTUnwrap(structured["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["key"] as? String, "VisibilityProbeTool")
        XCTAssertEqual(tools.first?["callCount"] as? Int, 1)
        XCTAssertEqual(tools.first?["sessionCount"] as? Int, 1)
    }

    func testFileActivityMatchesListSessionsDefaultVisibility_repro() throws {
        let dbPath = try secondaryVisibilityFixture(prefix: "engram-mcp-b2-files")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try assertOnlyVisibleSessionIsListed(at: dbPath)

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"file_activity","arguments":{"project":"b2-visibility","limit":10}}}
            """,
            dbPath: dbPath
        )
        let files = try XCTUnwrap(structured["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?["file_path"] as? String, "/workspace/visibility.swift")
        XCTAssertEqual(files.first?["action"] as? String, "Edit")
        XCTAssertEqual(files.first?["total_count"] as? Int, 1)
        XCTAssertEqual(files.first?["session_count"] as? Int, 1)
    }

    func testProjectTimelineMatchesListSessionsDefaultVisibility_repro() throws {
        let dbPath = try secondaryVisibilityFixture(prefix: "engram-mcp-b2-timeline")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try assertOnlyVisibleSessionIsListed(at: dbPath)

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_timeline","arguments":{"project":"b2-visibility"}}}
            """,
            dbPath: dbPath
        )
        let timeline = try XCTUnwrap(structured["timeline"] as? [[String: Any]])
        XCTAssertEqual(timeline.compactMap { $0["sessionId"] as? String }, ["b2-visible"])
        XCTAssertEqual(structured["total"] as? Int, 1)
    }

    func testProjectTimelineReportsUncappedTotalAndHasMore_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-project-total")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            for index in 0..<201 {
                try db.execute(sql: """
                    INSERT INTO sessions (
                        id, source, start_time, cwd, project, message_count,
                        user_message_count, assistant_message_count, tool_message_count,
                        system_message_count, instruction_count, human_turn_count,
                        file_path, indexed_at, tier
                    ) VALUES (?, 'codex', ?, '/work/engram', 'timeline-count', 1,
                              1, 0, 0, 0, 2, 1, ?, datetime('now'), 'normal')
                    """, arguments: [
                        "timeline-count-\(index)",
                        String(format: "2026-05-09T12:%02d:%02dZ", (index / 60) % 60, index % 60),
                        "/tmp/timeline-count-\(index).jsonl",
                    ])
            }
        }

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_timeline","arguments":{"project":"timeline-count"}}}
            """,
            dbPath: dbPath
        )
        let timeline = try XCTUnwrap(structured["timeline"] as? [[String: Any]])

        XCTAssertEqual(timeline.count, 200)
        XCTAssertEqual(structured["total"] as? Int, 201)
        XCTAssertEqual(structured["hasMore"] as? Bool, true)
    }

    func testResourceCatalogMatchesDefaultHumanSignalsAcrossSources_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-resource-signals")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, tier,
                  user_message_count, instruction_count, human_turn_count
                ) VALUES
                  ('turn-rescue', 'gemini-cli', '2026-08-23T01:00:00Z', '/work/a', 'a', '/tmp/a.jsonl', 'normal', 3, NULL, 12),
                  ('legacy-rescue', 'cursor', '2026-08-23T02:00:00Z', '/work/b', 'b', '/tmp/b.jsonl', 'normal', 12, NULL, NULL),
                  ('premium-rescue', 'opencode', '2026-08-23T03:00:00Z', '/work/c', 'c', '/tmp/c.jsonl', 'premium', 1, NULL, NULL),
                  ('catalog-noise', 'gemini-cli', '2026-08-23T04:00:00Z', '/work/d', 'd', '/tmp/d.jsonl', 'normal', 1, NULL, NULL)
                """)
        }

        let result = try rpcResult(
            #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#,
            dbPath: dbPath
        )
        let resources = try XCTUnwrap(result["resources"] as? [[String: Any]])
        XCTAssertEqual(
            Set(resources.compactMap { $0["uri"] as? String }.filter { $0.hasPrefix("engram://session/") }),
            Set([
                "engram://session/turn-rescue",
                "engram://session/legacy-rescue",
                "engram://session/premium-rescue",
                "engram://session/catalog-noise",
            ])
        )
    }

    func testResourceCatalogKeepsDefaultUnknownProviderFailOpen_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-resource-two-turn")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, tier,
                  user_message_count, instruction_count, human_turn_count
                ) VALUES
                  ('two-turn-gemini', 'gemini-cli', '2026-08-23T01:00:00Z', '/work/a', 'a', '/tmp/a.jsonl', 'normal', 2, NULL, NULL),
                  ('one-turn-noise', 'gemini-cli', '2026-08-23T02:00:00Z', '/work/b', 'b', '/tmp/b.jsonl', 'normal', 1, NULL, NULL)
                """)
        }

        let result = try rpcResult(
            #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#,
            dbPath: dbPath
        )
        let resources = try XCTUnwrap(result["resources"] as? [[String: Any]])
        let sessionURIs = Set(
            resources.compactMap { $0["uri"] as? String }.filter { $0.hasPrefix("engram://session/") }
        )
        XCTAssertEqual(
            sessionURIs,
            ["engram://session/two-turn-gemini", "engram://session/one-turn-noise"]
        )
    }

    func testResourceCatalogMatchesListVisibilityForCopilotCheckpoint_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-resource-copilot")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, tier,
                  user_message_count, instruction_count, human_turn_count
                ) VALUES
                  ('copilot-checkpoint', 'copilot', '2026-08-23T01:00:00Z', '/work/a', 'a',
                   '/tmp/checkpoint.json', 'normal', 0, NULL, NULL)
                """)
        }

        let result = try rpcResult(
            #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#,
            dbPath: dbPath
        )
        let resources = try XCTUnwrap(result["resources"] as? [[String: Any]])
        let sessionURIs = Set(
            resources.compactMap { $0["uri"] as? String }.filter { $0.hasPrefix("engram://session/") }
        )
        XCTAssertEqual(sessionURIs, ["engram://session/copilot-checkpoint"])
    }

    func testGetContextSessionListMatchesListSessionsDefaultVisibility_repro() throws {
        let dbPath = try secondaryVisibilityFixture(prefix: "engram-mcp-b2-context-sessions")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try assertOnlyVisibleSessionIsListed(at: dbPath)

        let result = try rpcResult(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/b2-visibility","include_environment":false,"max_tokens":4000}}}
            """,
            dbPath: dbPath
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("B2 visible summary"), text)
        XCTAssertFalse(text.contains("B2 noise summary"), text)
        XCTAssertFalse(text.contains("B2 hidden summary"), text)
        XCTAssertFalse(text.contains("B2 skip summary"), text)
        XCTAssertFalse(text.contains("B2 confirmed child summary"), text)
        XCTAssertFalse(text.contains("B2 suggested child summary"), text)
        XCTAssertTrue(text.contains("— 1 sessions"), text)
    }

    func testGetContextTopToolsMatchesListSessionsDefaultVisibility_repro() throws {
        let dbPath = try secondaryVisibilityFixture(prefix: "engram-mcp-b2-context-tools")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try assertOnlyVisibleSessionIsListed(at: dbPath)

        let text = try getContextEnvironmentText(dbPath: dbPath)
        XCTAssertTrue(text.contains("VisibilityProbeTool: 1 calls"), text)
        XCTAssertFalse(text.contains("VisibilityProbeTool: 100001 calls"), text)
    }

    func testGetContextFileHotspotsMatchListSessionsDefaultVisibility_repro() throws {
        let dbPath = try secondaryVisibilityFixture(prefix: "engram-mcp-b2-context-files")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try assertOnlyVisibleSessionIsListed(at: dbPath)

        let text = try getContextEnvironmentText(dbPath: dbPath)
        XCTAssertTrue(text.contains("/workspace/visibility.swift (1 edits, 1 sessions)"), text)
        XCTAssertFalse(text.contains("/workspace/visibility.swift (100001 edits, 2 sessions)"), text)
    }

    // MARK: - Wave J34 MCP hardening

    func testGetSessionRedactsCompleteMessageBeforeApplyingContentCap_repro() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-mcp-j34-redaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let privateKey = "token:\n-----BEGIN PRIVATE KEY-----\n"
            + String(repeating: "A", count: 9_000)
            + "\n-----END PRIVATE KEY-----"
        let transcript = temp.appendingPathComponent("redaction.jsonl")
        let transcriptObject: [String: Any] = [
            "timestamp": "2026-08-22T00:00:00Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": privateKey]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: transcriptObject).write(to: transcript)

        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-j34-redaction")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'codex', file_path = ?, message_count = 1 WHERE id = 'mcp-transcript-01'",
                arguments: [transcript.path]
            )
        }
        let fixtureWriter = try prepareReaderFixture(at: dbPath)
        defer { withExtendedLifetime(fixtureWriter) {} }

        let redactedResult = try rpcResult(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01"}}}"#,
            dbPath: dbPath
        )
        let redacted = try XCTUnwrap(
            redactedResult["structuredContent"] as? [String: Any],
            "result=\(redactedResult)"
        )
        let redactedMessages = try XCTUnwrap(redacted["messages"] as? [[String: Any]])
        let redactedContent = try XCTUnwrap(redactedMessages.first?["content"] as? String)
        XCTAssertTrue(redactedContent.contains("[REDACTED]"), redactedContent)
        XCTAssertFalse(redactedContent.contains("BEGIN PRIVATE KEY"), redactedContent)
        XCTAssertFalse(redactedContent.contains("END PRIVATE KEY"), redactedContent)
        XCTAssertFalse(redactedContent.contains(String(repeating: "A", count: 64)), redactedContent)

        let rawResult = try rpcResult(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-transcript-01","include_raw":true}}}"#,
            dbPath: dbPath
        )
        let raw = try XCTUnwrap(
            rawResult["structuredContent"] as? [String: Any],
            "result=\(rawResult)"
        )
        let rawMessages = try XCTUnwrap(raw["messages"] as? [[String: Any]])
        let rawContent = try XCTUnwrap(rawMessages.first?["content"] as? String)
        XCTAssertTrue(rawContent.hasPrefix("token:\n-----BEGIN PRIVATE KEY-----"), rawContent)
        XCTAssertTrue(rawContent.contains("[truncated"), rawContent)
        XCTAssertFalse(rawContent.contains("-----END PRIVATE KEY-----"), rawContent)
    }

    func testSessionSummaryIsRedactedAcrossMCPReadSurfaces_repro() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-mcp-summary-redaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let transcript = temp.appendingPathComponent("session.jsonl")
        let transcriptObject: [String: Any] = [
            "timestamp": "2026-08-22T00:00:00Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "safe transcript"]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: transcriptObject).write(to: transcript)

        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-summary-redaction")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let secret = "api_key: " + String(repeating: "S", count: 64)
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'codex', start_time = '2026-08-22T00:00:00Z', end_time = '2026-08-22T00:01:00Z', file_path = ?, summary = ?, generated_title = ? WHERE id = 'mcp-fixture-01'",
                arguments: [transcript.path, secret, secret]
            )
        }
        let fixtureWriter = try prepareReaderFixture(at: dbPath)
        defer { withExtendedLifetime(fixtureWriter) {} }

        let getSession = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{"id":"mcp-fixture-01"}}}"#,
            dbPath: dbPath
        )
        let session = try XCTUnwrap(getSession["session"] as? [String: Any])
        XCTAssertEqual(session["summary"] as? String, TranscriptRedactionPolicy.redactionToken)

        let list = try rpc(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_sessions","arguments":{"project":"engram","limit":20}}}"#,
            dbPath: dbPath
        )
        let listed = try XCTUnwrap((list["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == "mcp-fixture-01" })
        XCTAssertEqual(listed["summary"] as? String, TranscriptRedactionPolicy.redactionToken)

        let search = try rpc(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"parity","limit":20}}}"#,
            dbPath: dbPath
        )
        let result = try XCTUnwrap((search["results"] as? [[String: Any]])?.first {
            (($0["session"] as? [String: Any])?["id"] as? String) == "mcp-fixture-01"
        })
        XCTAssertEqual((result["session"] as? [String: Any])?["summary"] as? String, TranscriptRedactionPolicy.redactionToken)

        let contextResult = try rpcResult(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/engram","include_environment":false,"max_tokens":4000}}}"#,
            dbPath: dbPath
        )
        let contextContent = try XCTUnwrap(contextResult["content"] as? [[String: Any]])
        let context = try XCTUnwrap(contextContent.first?["text"] as? String)
        XCTAssertFalse(context.contains(String(repeating: "S", count: 64)), context)
        XCTAssertTrue(context.contains(TranscriptRedactionPolicy.redactionToken), context)

        let handoff = try rpc(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"handoff","arguments":{"cwd":"/Users/test/work/engram","sessionId":"mcp-fixture-01","format":"markdown"}}}"#,
            dbPath: dbPath
        )
        let brief = try XCTUnwrap(handoff["brief"] as? String)
        XCTAssertFalse(brief.contains(String(repeating: "S", count: 64)), brief)
        XCTAssertTrue(brief.contains(TranscriptRedactionPolicy.redactionToken), brief)

        let resourcesResult = try rpcResult(
            #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#,
            dbPath: dbPath
        )
        let resources = try XCTUnwrap(resourcesResult["resources"] as? [[String: Any]])
        let resource = try XCTUnwrap(resources.first { $0["uri"] as? String == "engram://session/mcp-fixture-01" })
        XCTAssertEqual(resource["name"] as? String, TranscriptRedactionPolicy.redactionToken)

        let timeline = try rpc(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"project_timeline","arguments":{"project":"engram"}}}"#,
            dbPath: dbPath
        )
        let timelineRow = try XCTUnwrap((timeline["timeline"] as? [[String: Any]])?.first {
            $0["sessionId"] as? String == "mcp-fixture-01"
        })
        XCTAssertEqual(timelineRow["summary"] as? String, TranscriptRedactionPolicy.redactionToken)

        let analytics = try rpc(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"tool_analytics","arguments":{"project":"engram","group_by":"session"}}}"#,
            dbPath: dbPath
        )
        let analyticsRow = try XCTUnwrap((analytics["tools"] as? [[String: Any]])?.first {
            $0["key"] as? String == "mcp-fixture-01"
        })
        XCTAssertEqual(analyticsRow["label"] as? String, TranscriptRedactionPolicy.redactionToken)
    }

    func testInsightContentIsRedactedAcrossMCPReadSurfaces_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-insight-redaction")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let secretValue = String(repeating: "S", count: 64)
        let content = "egressprobe api_key: \(secretValue)"
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: "DELETE FROM insights")
            try db.execute(sql: "DELETE FROM insights_fts")
            try db.execute(
                sql: "INSERT INTO insights (id, content, importance) VALUES ('insight-egress-redaction', ?, 5)",
                arguments: [content]
            )
            try db.execute(
                sql: "INSERT INTO insights_fts (insight_id, content) VALUES ('insight-egress-redaction', ?)",
                arguments: [content]
            )
        }
        let fixtureWriter = try prepareReaderFixture(at: dbPath)
        defer { withExtendedLifetime(fixtureWriter) {} }

        let memory = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_memory","arguments":{"query":"egressprobe"}}}"#,
            dbPath: dbPath
        )
        let memories = try XCTUnwrap(memory["memories"] as? [[String: Any]])
        XCTAssertEqual(memories.first?["content"] as? String, "egressprobe [REDACTED]")

        let search = try rpc(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"query":"egressprobe","limit":5}}}"#,
            dbPath: dbPath
        )
        XCTAssertEqual(search["insightResults"] as? [String], ["egressprobe [REDACTED]"])

        let contextResult = try rpcResult(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/tmp/egressprobe","task":"egressprobe","include_environment":false}}}"#,
            dbPath: dbPath
        )
        let contextBlocks = try XCTUnwrap(contextResult["content"] as? [[String: Any]])
        let context = try XCTUnwrap(contextBlocks.first?["text"] as? String)
        XCTAssertTrue(context.contains("egressprobe [REDACTED]"), context)
        XCTAssertFalse(context.contains(secretValue), context)

        let listed = try rpcResult(
            #"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#,
            dbPath: dbPath
        )
        let resources = try XCTUnwrap(listed["resources"] as? [[String: Any]])
        let resource = try XCTUnwrap(resources.first {
            $0["uri"] as? String == "engram://insight/insight-egress-redaction"
        })
        XCTAssertEqual(resource["name"] as? String, "egressprobe [REDACTED]")

        let read = try rpcResult(
            #"{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"engram://insight/insight-egress-redaction"}}"#,
            dbPath: dbPath
        )
        let contents = try XCTUnwrap(read["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["text"] as? String, "egressprobe [REDACTED]")
    }

    func testKeywordAndContextKeepSessionResultsWhenInsightsFTSIsMissing_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-missing-insight-fts")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: "DROP TABLE insights_fts")
        }
        let fixtureWriter = try prepareReaderFixture(at: dbPath)
        defer { withExtendedLifetime(fixtureWriter) {} }

        let search = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"parity","limit":5}}}"#,
            dbPath: dbPath
        )
        XCTAssertFalse((search["results"] as? [[String: Any]] ?? []).isEmpty)

        let contextResult = try rpcResult(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/engram","task":"parity","include_environment":false}}}"#,
            dbPath: dbPath
        )
        XCTAssertNotEqual(contextResult["isError"] as? Bool, true)
        XCTAssertNotNil(contextResult["content"] as? [[String: Any]])
    }

    func testKeywordSearchBoundsFTSContentBeforeBuildingSnippet_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-search-pem-redaction")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let keyLine = String(repeating: "A", count: 64)
        let keyBody = String(repeating: "\(keyLine)\n", count: 140)
            + "midpemprobe\n"
            + String(repeating: "\(keyLine)\n", count: 140)
        let content = "token:\n-----BEGIN PRIVATE KEY-----\n"
            + keyBody
            + "-----END PRIVATE KEY-----"
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: "DELETE FROM sessions")
            try db.execute(sql: "DELETE FROM sessions_fts")
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, instruction_count, human_turn_count, tier, summary
                ) VALUES (
                  'search-pem-redaction', 'codex', '2026-08-22T00:00:00Z',
                  '/tmp/search-pem-redaction', 'search-pem-redaction', '/tmp/missing.jsonl',
                  4, 2, 2, 2, 'normal', 'safe summary'
                )
                """)
            try db.execute(
                sql: "INSERT INTO sessions_fts (session_id, content) VALUES (?, ?)",
                arguments: ["search-pem-redaction", content]
            )
        }
        let fixtureWriter = try prepareReaderFixture(at: dbPath)
        defer { withExtendedLifetime(fixtureWriter) {} }

        let structured = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"midpemprobe","limit":10}}}"#,
            dbPath: dbPath
        )
        let results = try XCTUnwrap(
            structured["results"] as? [[String: Any]],
            "structured=\(structured)"
        )
        let snippet = try XCTUnwrap(results.first?["snippet"] as? String)
        XCTAssertFalse(snippet.contains("BEGIN PRIVATE KEY"), snippet)
        XCTAssertFalse(snippet.contains("END PRIVATE KEY"), snippet)
        XCTAssertFalse(snippet.contains(keyLine), snippet)
        XCTAssertLessThanOrEqual(snippet.count, 600, snippet)
    }

    func testFileActivityExpandsProjectAliasesInBothDirections_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-j34-file-alias")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: "DELETE FROM session_files")
            try db.execute(sql: "DELETE FROM sessions")
            try db.execute(sql: "DELETE FROM project_aliases")
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, instruction_count, human_turn_count, tier
                )
                VALUES
                  ('j34-canonical', 'codex', '2026-08-21T10:00:00Z', '/tmp/canonical', 'canonical', '/tmp/canonical.jsonl', 2, 2, 2, 2, 'normal'),
                  ('j34-alias', 'codex', '2026-08-21T11:00:00Z', '/tmp/alias', 'legacy-alias', '/tmp/alias.jsonl', 2, 2, 2, 2, 'normal');
                INSERT INTO project_aliases(alias, canonical) VALUES ('legacy-alias', 'canonical');
                INSERT INTO session_files(session_id, file_path, action, count)
                VALUES
                  ('j34-canonical', '/tmp/shared.swift', 'Edit', 2),
                  ('j34-alias', '/tmp/shared.swift', 'Edit', 3);
                """)
        }
        let fixtureWriter = try prepareReaderFixture(at: dbPath)
        defer { withExtendedLifetime(fixtureWriter) {} }

        for project in ["canonical", "legacy-alias"] {
            let structured = try rpc(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"file_activity","arguments":{"project":"\#(project)"}}}"#,
                dbPath: dbPath
            )
            let files = try XCTUnwrap(structured["files"] as? [[String: Any]])
            XCTAssertEqual(files.first?["total_count"] as? Int, 5, "project=\(project), files=\(files)")
            XCTAssertEqual(files.first?["session_count"] as? Int, 2, "project=\(project), files=\(files)")
        }
    }

    func testGetContextCacheSuggestionExcludesSkipTierCosts_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-j34-cache-tier")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: "DELETE FROM session_costs")
            try db.execute(sql: "DELETE FROM sessions")
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, cwd, project, file_path, message_count, tier)
                VALUES
                  ('j34-visible-cost', 'claude-code', '2026-08-21T10:00:00Z', '/tmp/v', 'v', '/tmp/v.jsonl', 1, 'normal'),
                  ('j34-skip-cost', 'claude-code', '2026-08-21T11:00:00Z', '/tmp/s', 's', '/tmp/s.jsonl', 1, 'skip');
                INSERT INTO session_costs (
                  session_id, model, input_tokens, output_tokens, cache_read_tokens,
                  cache_creation_tokens, cost_usd, computed_at
                ) VALUES
                  ('j34-visible-cost', 'claude-3-7-sonnet', 10, 1, 90, 0, 1.0, '2026-08-21T10:00:00Z'),
                  ('j34-skip-cost', 'claude-3-7-sonnet', 1000, 1, 0, 0, 0.0, '2026-08-21T11:00:00Z');
                """)
        }
        let fixtureWriter = try prepareReaderFixture(at: dbPath)
        defer { withExtendedLifetime(fixtureWriter) {} }

        let result = try rpcResult(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/tmp/v","detail":"full","include_environment":true,"max_tokens":4000}}}"#,
            dbPath: dbPath,
            environment: ["ENGRAM_MCP_NOW": "2026-08-22T12:00:00.000Z"]
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.contains("Low prompt cache utilization"), text)
    }

    func testProjectReviewUsesCanonicalRootsAndSkipsSymlinkedFiles_repro() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-mcp-j34-review-\(UUID().uuidString)", isDirectory: true)
        let home = temp.appendingPathComponent("home", isDirectory: true)
        let qwenRoot = home.appendingPathComponent(".qwen/projects", isDirectory: true)
        let archivedRoot = home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        let codexRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: qwenRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let oldPath = "/Users/test/work/j34-old"
        var boundarySpanning = Data(repeating: 0x78, count: 65_530)
        boundarySpanning.append(Data(oldPath.utf8))
        try boundarySpanning.write(to: qwenRoot.appendingPathComponent("qwen.jsonl"))
        try #"{"cwd":"/Users/test/work/j34-old"}"#.write(
            to: archivedRoot.appendingPathComponent("archived.jsonl"), atomically: true, encoding: .utf8
        )
        let outside = temp.appendingPathComponent("outside.jsonl")
        try #"{"cwd":"/Users/test/work/j34-old"}"#.write(to: outside, atomically: true, encoding: .utf8)
        let symlink = codexRoot.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-j34-review")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let fixtureWriter = try prepareReaderFixture(at: dbPath)
        defer { withExtendedLifetime(fixtureWriter) {} }
        let structured = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_review","arguments":{"old_path":"/Users/test/work/j34-old","new_path":"/Users/test/work/j34-new"}}}"#,
            dbPath: dbPath,
            environment: ["HOME": home.path]
        )
        let own = try XCTUnwrap(structured["own"] as? [String])
        XCTAssertTrue(own.contains { $0.hasSuffix("/.qwen/projects/qwen.jsonl") }, "\(own)")
        XCTAssertTrue(
            own.contains { $0.hasSuffix("/.codex/archived_sessions/archived.jsonl") },
            "\(own)"
        )
        XCTAssertFalse(
            own.contains { $0.hasSuffix("/.codex/sessions/linked.jsonl") },
            "project_review must not follow symlinks: \(own)"
        )
    }

    // MARK: - Superseded insight filter (mirror row 1 / PR #241)

    /// Lifecycle seed used by the supersede-filter repros (PR #241): two ASCII
    /// FTS rows and two CJK LIKE-branch rows, one active + one superseded each.
    private func seedSupersedeProbeInsights(at dbPath: String) throws {
        try DatabaseQueue(path: dbPath).write { db in
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
            // CJK rows stay pure CJK so an ASCII FTS query ("supersede probe")
            // does not also hit them; the CJK LIKE branch is covered separately.
            let rows: [(id: String, content: String, superseded: String?)] = [
                ("sup-active", "supersede probe active fact", nil),
                ("sup-old", "supersede probe obsolete fact", "sup-active"),
                ("sup-cjk-active", "有效事实探针内容", nil),
                ("sup-cjk-old", "废弃事实探针内容", "sup-cjk-active"),
            ]
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO insights
                      (id, content, importance, created_at, insight_type, superseded_by, access_count)
                    VALUES (?, ?, 5, '2026-07-01 00:00:00', 'semantic', ?, 0)
                    """,
                    arguments: [row.id, row.content, row.superseded]
                )
                try db.execute(
                    sql: "INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)",
                    arguments: [row.id, row.content]
                )
            }
        }
    }

    // PR #241 (mirror row 1): get_context must drop superseded FTS insights.
    func testGetContextExcludesSupersededInsights_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-supersede-ctx")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try seedSupersedeProbeInsights(at: dbPath)

        let result = try rpcResult(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/tmp/engram-supersede-probe","task":"supersede probe","include_environment":false}}}
            """,
            dbPath: dbPath
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("supersede probe active fact"), text)
        XCTAssertFalse(text.contains("supersede probe obsolete fact"), text)
        XCTAssertTrue(text.contains("+ 1 memories"), text)
    }

    // PR #241 (mirror row 1): search insightResults drop superseded rows.
    func testSearchExcludesSupersededInsights_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-supersede-search")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try seedSupersedeProbeInsights(at: dbPath)

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"supersede probe","limit":5}}}
            """,
            dbPath: dbPath
        )
        let insightResults = try XCTUnwrap(structured["insightResults"] as? [String])
        XCTAssertEqual(insightResults.count, 1, "\(insightResults)")
        XCTAssertFalse(insightResults.contains { $0.contains("obsolete") }, "\(insightResults)")
    }

    // PR #241 (mirror row 1 / AC6): CJK LIKE branch must also honor superseded_by.
    // Query uses the shared substring present in BOTH active and superseded CJK
    // rows so the filter is what drops the superseded hit (not query mismatch).
    func testGetContextExcludesSupersededInsightsForCJKQuery_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-supersede-cjk")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try seedSupersedeProbeInsights(at: dbPath)

        let result = try rpcResult(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/tmp/engram-supersede-probe","task":"事实探针内容","include_environment":false}}}
            """,
            dbPath: dbPath
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("有效事实探针内容"), text)
        XCTAssertFalse(text.contains("废弃事实"), text)
        XCTAssertTrue(text.contains("+ 1 memories"), text)
    }

    // PR #241 (mirror row 1): resources/list omits superseded insight URIs.
    func testResourceCatalogExcludesSupersededInsights_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-supersede-res")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try seedSupersedeProbeInsights(at: dbPath)

        let result = try rpcResult(
            """
            {"jsonrpc":"2.0","id":1,"method":"resources/list"}
            """,
            dbPath: dbPath
        )
        let resources = try XCTUnwrap(result["resources"] as? [[String: Any]])
        let uris = resources.compactMap { $0["uri"] as? String }
        XCTAssertTrue(uris.contains("engram://insight/sup-active"), "\(uris)")
        XCTAssertFalse(uris.contains("engram://insight/sup-old"), "\(uris)")
    }

    func testResourceCatalogUsesHumanDrivenTopLevelVisibility_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-human-resources")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, file_path, message_count,
                  user_message_count, instruction_count, human_turn_count,
                  tier, parent_session_id, suggested_parent_id, hidden_at
                ) VALUES
                  ('resource-human-root', 'codex', '2026-08-22T10:00:00Z', '/tmp',
                   '/tmp/human.jsonl', 4, 4, 2, 2, 'normal', NULL, NULL, NULL),
                  ('resource-automated-root', 'codex', '2026-08-22T11:00:00Z', '/tmp',
                   '/tmp/automated.jsonl', 1, 1, 0, 0, 'normal', NULL, NULL, NULL),
                  ('resource-suggested-child', 'codex', '2026-08-22T12:00:00Z', '/tmp',
                   '/tmp/child.jsonl', 4, 4, 4, 4, 'normal', NULL, 'resource-human-root', NULL)
                """)
        }

        let result = try rpcResult(
            #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#,
            dbPath: dbPath
        )
        let resources = try XCTUnwrap(result["resources"] as? [[String: Any]])
        let sessionURIs = resources.compactMap { $0["uri"] as? String }
            .filter { $0.hasPrefix("engram://session/") }

        XCTAssertEqual(sessionURIs, ["engram://session/resource-human-root"])
    }

    func testSuggestedChildIsPromotedWhenItsHostFailsDefaultVisibility_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-promoted-child")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, instruction_count, human_turn_count, tier,
                  agent_role, parent_session_id, suggested_parent_id, hidden_at, summary
                ) VALUES
                  ('promote-weak-host', 'claude-code', '2026-08-24T10:00:00Z', '/tmp/promote',
                   'promote', '/tmp/host.jsonl', 1, 1, 1, 1, 'normal', NULL, NULL, NULL, NULL,
                   'weak host'),
                  ('promote-human-child', 'gemini-cli', '2026-08-24T11:00:00Z', '/tmp/promote',
                   'promote', '/tmp/child.jsonl', 4, 1, NULL, NULL, 'normal', NULL, NULL,
                   'promote-weak-host', NULL, 'PROMOTED CHILD UNIQUE SUMMARY')
                """)
        }

        let listed = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{"project":"promote","limit":50,"include_all":true}}}"#,
            dbPath: dbPath
        )
        let listedIDs = try XCTUnwrap(listed["sessions"] as? [[String: Any]])
            .compactMap { $0["id"] as? String }
        XCTAssertEqual(listedIDs, ["promote-weak-host"], "\(listedIDs)")

        let resourceResult = try rpcResult(
            #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#,
            dbPath: dbPath
        )
        let resourceURIs = try XCTUnwrap(resourceResult["resources"] as? [[String: Any]])
            .compactMap { $0["uri"] as? String }
        XCTAssertTrue(resourceURIs.contains("engram://session/promote-human-child"), "\(resourceURIs)")
        XCTAssertFalse(resourceURIs.contains("engram://session/promote-weak-host"), "\(resourceURIs)")

        let contextResult = try rpcResult(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/tmp/promote","detail":"full","include_environment":true,"max_tokens":4000}}}"#,
            dbPath: dbPath
        )
        let context = try XCTUnwrap(
            (contextResult["content"] as? [[String: Any]])?.first?["text"] as? String
        )
        XCTAssertTrue(context.contains("PROMOTED CHILD UNIQUE SUMMARY"), context)
    }

    func testKeywordSearchHighlightsTheWholeMixedQueryWindow_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-mixed-highlight")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, cwd, project, file_path, tier, summary)
                VALUES ('mixed-highlight', 'codex', '2026-08-24T00:00:00Z', '/tmp', 'mixed',
                        '/tmp/mixed.jsonl', 'normal', 'mixed highlight')
                """)
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                arguments: ["mixed-highlight", "Ship the AI usage monitor before release"]
            )
        }

        let result = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"AI usage","mode":"keyword","limit":10}}}"#,
            dbPath: dbPath
        )
        let results = try XCTUnwrap(result["results"] as? [[String: Any]])
        let snippet = try XCTUnwrap(results.first?["snippet"] as? String)
        XCTAssertTrue(snippet.contains("<mark>AI usage</mark>"), snippet)
    }

    func testKeywordSearchHighlightsEveryMixedTokenAcrossRows_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-mixed-row-highlight")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, cwd, project, file_path, tier, summary)
                VALUES ('mixed-row-highlight', 'codex', '2026-08-24T00:00:00Z', '/tmp', 'mixed',
                        '/tmp/mixed-row.jsonl', 'normal', 'mixed row highlight')
                """)
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                arguments: ["mixed-row-highlight", "alpha planning note"]
            )
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                arguments: ["mixed-row-highlight", "beta verifier note"]
            )
        }

        let result = try rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"alpha beta","mode":"keyword","limit":10}}}"#,
            dbPath: dbPath
        )
        let results = try XCTUnwrap(result["results"] as? [[String: Any]])
        let snippet = try XCTUnwrap(results.first?["snippet"] as? String)
        XCTAssertTrue(snippet.contains("<mark>alpha</mark>"), snippet)
        XCTAssertTrue(snippet.contains("<mark>beta</mark>"), snippet)
    }

    func testResourceCatalogRanksParentByItsNewestVisibleChild_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-parent-recency")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, project, file_path, message_count,
                      user_message_count, instruction_count, human_turn_count, tier,
                      parent_session_id, suggested_parent_id, summary
                    ) VALUES (?, 'codex', '2026-08-24T00:00:00Z', '/tmp/rank', 'rank', ?,
                              4, 4, 2, 2, 'normal', NULL, NULL, 'ranked parent')
                    """,
                arguments: ["ranked-parent", "/tmp/ranked-parent.jsonl"]
            )
            for index in 0..<15 {
                try db.execute(
                    sql: """
                        INSERT INTO sessions (
                          id, source, start_time, cwd, project, file_path, message_count,
                          user_message_count, instruction_count, human_turn_count, tier, summary
                        ) VALUES (?, 'codex', ?, '/tmp/rank', 'rank', ?, 4, 4, 2, 2, 'normal', ?)
                        """,
                    arguments: [
                        "rank-root-\(index)",
                        String(format: "2026-08-24T%02d:00:00Z", index + 1),
                        "/tmp/rank-root-\(index).jsonl",
                        "rank root \(index)",
                    ]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, project, file_path, message_count,
                      user_message_count, instruction_count, human_turn_count, tier,
                      parent_session_id, suggested_parent_id, summary
                    ) VALUES ('ranked-child', 'gemini-cli', '2026-08-24T23:59:00Z', '/tmp/rank',
                              'rank', '/tmp/ranked-child.jsonl', 4, 1, NULL, NULL, 'normal',
                              NULL, 'ranked-parent', 'newest child')
                    """
            )
        }

        let result = try rpcResult(
            #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#,
            dbPath: dbPath
        )
        let sessionURIs = try XCTUnwrap(result["resources"] as? [[String: Any]])
            .compactMap { $0["uri"] as? String }
            .filter { $0.hasPrefix("engram://session/") }

        XCTAssertEqual(sessionURIs.count, 15)
        XCTAssertTrue(sessionURIs.contains("engram://session/ranked-parent"), "\(sessionURIs)")
        XCTAssertFalse(sessionURIs.contains("engram://session/ranked-child"), "\(sessionURIs)")
    }

    func testGetMemoryNonmatchingQueryDoesNotRecencyFill_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-supersede-recency")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try DatabaseQueue(path: dbPath).write { db in
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
            // 40 most-recent rows all superseded; 5 older active rows fill after filter.
            for i in 0..<40 {
                let id = "recency-super-\(i)"
                try db.execute(
                    sql: """
                    INSERT INTO insights
                      (id, content, importance, created_at, insight_type, superseded_by, access_count)
                    VALUES (?, ?, 5, ?, 'semantic', 'recency-active-0', 0)
                    """,
                    arguments: [
                        id,
                        "recency superseded row \(i)",
                        String(format: "2026-07-20T%02d:00:00.000Z", i % 24),
                    ]
                )
                try db.execute(
                    sql: "INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)",
                    arguments: [id, "recency superseded row \(i)"]
                )
            }
            for i in 0..<5 {
                let id = "recency-active-\(i)"
                try db.execute(
                    sql: """
                    INSERT INTO insights
                      (id, content, importance, created_at, insight_type, superseded_by, access_count)
                    VALUES (?, ?, 5, ?, 'semantic', NULL, 0)
                    """,
                    arguments: [
                        id,
                        "recency active durable fact \(i)",
                        String(format: "2026-01-%02dT00:00:00.000Z", i + 1),
                    ]
                )
                try db.execute(
                    sql: "INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)",
                    arguments: [id, "recency active durable fact \(i)"]
                )
            }
        }
        let fixtureWriter = try prepareReaderFixture(at: dbPath)
        defer { withExtendedLifetime(fixtureWriter) {} }

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_memory","arguments":{"query":"zzzznomatch"}}}
            """,
            dbPath: dbPath
        )
        let memories = try XCTUnwrap(structured["memories"] as? [[String: Any]])
        XCTAssertEqual(memories.count, 0, "\(memories.map { $0["id"] as? String })")
    }

    // MARK: - Seeds

    private func prepareReaderFixture(at dbPath: String) throws -> DatabaseQueue {
        // MCPDatabase opens through the production read-only WAL policy. Keep
        // repros isolated in temp while making that fixture contract explicit.
        // docs/invariants.md #6: never use the production ~/.engram database.
        let queue = try DatabaseQueue(path: dbPath)
        try queue.writeWithoutTransaction { db in
            let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            XCTAssertEqual(mode?.lowercased(), "wal")
        }
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE __j34_reader_probe(value INTEGER)")
            try db.execute(sql: "DROP TABLE __j34_reader_probe")
        }
        return queue
    }

    private func wipeSessionsAndCosts(at dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM session_costs")
            try db.execute(sql: "DELETE FROM sessions")
            try? db.execute(sql: "DELETE FROM sessions_fts")
        }
    }

    private func secondaryVisibilityFixture(prefix: String) throws -> String {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: prefix)
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM session_tools")
            try db.execute(sql: "DELETE FROM session_files")
            try db.execute(sql: "DELETE FROM session_costs")
            try db.execute(sql: "DELETE FROM sessions")
            try? db.execute(sql: "DELETE FROM sessions_fts")
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, instruction_count, human_turn_count, agent_role, tier,
                  parent_session_id, suggested_parent_id, hidden_at, summary
                ) VALUES
                  ('b2-visible', 'codex', '2026-07-19T10:00:00.000Z',
                   '/Users/test/work/b2-visibility', 'b2-visibility', '/tmp/b2-visible.jsonl',
                   4, 4, 4, 4, NULL, 'normal', NULL, NULL, NULL, 'B2 visible summary'),
                  ('b2-noise', 'codex', '2026-07-19T10:30:00.000Z',
                   '/Users/test/work/b2-visibility', 'b2-visibility', '/tmp/b2-noise.jsonl',
                   1, 0, 0, 0, NULL, 'normal', NULL, NULL, NULL, 'B2 noise summary'),
                  ('b2-hidden', 'codex', '2026-07-19T11:00:00.000Z',
                   '/Users/test/work/b2-visibility', 'b2-visibility', '/tmp/b2-hidden.jsonl',
                   4, 4, 4, 4, NULL, 'normal', NULL, NULL, '2026-07-19T11:30:00.000Z', 'B2 hidden summary'),
                  ('b2-skip', 'codex', '2026-07-19T12:00:00.000Z',
                   '/Users/test/work/b2-visibility', 'b2-visibility', '/tmp/b2-skip.jsonl',
                   4, 4, 4, 4, NULL, 'skip', NULL, NULL, NULL, 'B2 skip summary'),
                  ('b2-confirmed-child', 'codex', '2026-07-19T13:00:00.000Z',
                   '/Users/test/work/b2-visibility', 'b2-visibility', '/tmp/b2-confirmed-child.jsonl',
                   4, 4, 4, 4, NULL, 'normal', 'b2-visible', NULL, NULL, 'B2 confirmed child summary'),
                  ('b2-suggested-child', 'codex', '2026-07-19T14:00:00.000Z',
                   '/Users/test/work/b2-visibility', 'b2-visibility', '/tmp/b2-suggested-child.jsonl',
                   4, 4, 4, 4, NULL, 'normal', NULL, 'b2-visible', NULL, 'B2 suggested child summary')
                """)
            try db.execute(sql: """
                INSERT INTO session_tools (session_id, tool_name, call_count) VALUES
                  ('b2-visible', 'VisibilityProbeTool', 1),
                  ('b2-noise', 'VisibilityProbeTool', 100000),
                  ('b2-hidden', 'VisibilityProbeTool', 10),
                  ('b2-skip', 'VisibilityProbeTool', 100),
                  ('b2-confirmed-child', 'VisibilityProbeTool', 1000),
                  ('b2-suggested-child', 'VisibilityProbeTool', 10000)
                """)
            try db.execute(sql: """
                INSERT INTO session_files (session_id, file_path, action, count) VALUES
                  ('b2-visible', '/workspace/visibility.swift', 'Edit', 1),
                  ('b2-noise', '/workspace/visibility.swift', 'Edit', 100000),
                  ('b2-hidden', '/workspace/visibility.swift', 'Edit', 10),
                  ('b2-skip', '/workspace/visibility.swift', 'Edit', 100),
                  ('b2-confirmed-child', '/workspace/visibility.swift', 'Edit', 1000),
                  ('b2-suggested-child', '/workspace/visibility.swift', 'Edit', 10000)
                """)
        }
        return dbPath
    }

    private func assertOnlyVisibleSessionIsListed(at dbPath: String) throws {
        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{"project":"b2-visibility","limit":50}}}
            """,
            dbPath: dbPath
        )
        let sessions = try XCTUnwrap(structured["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.compactMap { $0["id"] as? String }, ["b2-visible"])
        XCTAssertEqual(structured["total"] as? Int, 1)
    }

    private func getContextEnvironmentText(dbPath: String) throws -> String {
        let result = try rpcResult(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"cwd":"/Users/test/work/b2-visibility","detail":"full","include_environment":true,"max_tokens":4000}}}
            """,
            dbPath: dbPath,
            environment: ["ENGRAM_MCP_NOW": "2026-07-20T12:00:00.000Z"]
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    private func seedListSessionsVisibilityFixture(at dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            // codex is a reliable instruction-signal source: need instruction_count>=2
            // to pass HumanDrivenFilter.
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, instruction_count, human_turn_count, tier,
                  parent_session_id, suggested_parent_id, hidden_at, summary
                ) VALUES
                  ('mcp-m18-parent', 'codex', '2026-02-01T10:00:00.000Z',
                   '/Users/test/p', 'p', '/tmp/p.jsonl', 4, 4, 4, 4, 'normal',
                   NULL, NULL, NULL, 'parent'),
                  ('mcp-m18-child', 'codex', '2026-02-01T11:00:00.000Z',
                   '/Users/test/p', 'p', '/tmp/c.jsonl', 4, 4, 4, 4, 'normal',
                   'mcp-m18-parent', NULL, NULL, 'child'),
                  ('mcp-m18-skip', 'codex', '2026-02-01T12:00:00.000Z',
                   '/Users/test/p', 'p', '/tmp/s.jsonl', 4, 4, 4, 4, 'skip',
                   NULL, NULL, NULL, 'skip'),
                  ('mcp-m18-automated-parent', 'codex', '2026-02-01T13:00:00.000Z',
                   '/Users/test/p', 'p', '/tmp/a.jsonl', 1, 1, 0, 0, 'normal',
                   NULL, NULL, NULL, 'automated parent')
                """)
        }
    }

    private func seedStatsSkipFixture(at dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, assistant_message_count, tool_message_count,
                  tier, hidden_at, orphan_status
                ) VALUES
                  ('mcp-r3-normal', 'codex', '2026-02-01T10:00:00.000Z',
                   '/Users/test/p', 'p', '/tmp/n.jsonl', 10, 4, 4, 2, 'normal', NULL, NULL),
                  ('mcp-r3-skip', 'codex', '2026-02-01T11:00:00.000Z',
                   '/Users/test/p', 'p', '/tmp/s.jsonl', 99, 40, 40, 19, 'skip', NULL, NULL),
                  ('mcp-r3-skip-other', 'claude-code', '2026-02-01T12:00:00.000Z',
                   '/Users/test/p', 'p', '/tmp/s2.jsonl', 50, 20, 20, 10, 'skip', NULL, NULL)
                """)
        }
    }

    private func seedSearchUUIDVisibilityFixture(at dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, tier, hidden_at, orphan_status
                ) VALUES
                  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'codex', '2026-02-01T10:00:00.000Z',
                   '/tmp', 'uuid', '/tmp/a.jsonl', 1, 1, 'normal', NULL, NULL),
                  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'codex', '2026-02-01T10:01:00.000Z',
                   '/tmp', 'uuid', '/tmp/b.jsonl', 1, 1, 'normal', '2026-02-01T11:00:00.000Z', NULL),
                  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'codex', '2026-02-01T10:02:00.000Z',
                   '/tmp', 'uuid', '/tmp/c.jsonl', 1, 1, 'skip', NULL, NULL),
                  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'codex', '2026-02-01T10:03:00.000Z',
                   '/tmp', 'uuid', '/tmp/d.jsonl', 1, 1, 'lite', NULL, NULL),
                  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'codex', '2026-02-01T10:04:00.000Z',
                   '/tmp', 'uuid', '/tmp/e.jsonl', 1, 1, 'normal', NULL, 'suspect')
                """)
        }
    }

    private func seedManyTopLevelSessions(at dbPath: String, count: Int) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            for i in 0..<count {
                try db.execute(
                    sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, project, file_path, message_count,
                      user_message_count, instruction_count, human_turn_count, tier, hidden_at
                    ) VALUES (?, 'codex', ?, '/Users/test/x', 'x', ?, 4, 4, 4, 4, 'normal', NULL)
                    """,
                    arguments: [
                        "mcp-m9-\(i)",
                        String(format: "2026-02-01T%02d:00:00.000Z", i % 24),
                        "/tmp/m9-\(i).jsonl",
                    ]
                )
            }
        }
    }

    private func seedCostVisibilityFixture(at dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count, tier, hidden_at
                ) VALUES
                  ('mcp-cost-visible', 'codex', '2026-02-10T10:00:00.000Z',
                   '/Users/test/v', 'v', '/tmp/v.jsonl', 1, 'normal', NULL),
                  ('mcp-cost-hidden', 'codex', '2026-02-10T11:00:00.000Z',
                   '/Users/test/h', 'h', '/tmp/h.jsonl', 1, 'normal', '2026-02-10T12:00:00.000Z'),
                  ('mcp-cost-skip-priced', 'codex', '2026-02-10T12:00:00.000Z',
                   '/Users/test/s', 's', '/tmp/s-priced.jsonl', 1, 'skip', NULL),
                  ('mcp-cost-skip-unpriced', 'codex', '2026-02-10T13:00:00.000Z',
                   '/Users/test/s', 's', '/tmp/s-unpriced.jsonl', 1, 'skip', NULL)
                """)
            try db.execute(sql: """
                INSERT INTO session_costs (
                  session_id, model, input_tokens, output_tokens, cost_usd, computed_at
                ) VALUES
                  ('mcp-cost-visible', 'gpt-test', 10, 10, 1.0, '2026-02-10T10:00:00.000Z'),
                  ('mcp-cost-hidden', 'gpt-test', 100, 100, 99.0, '2026-02-10T11:00:00.000Z'),
                  ('mcp-cost-skip-priced', 'gpt-test', 1000, 1000, 100.0, '2026-02-10T12:00:00.000Z'),
                  ('mcp-cost-skip-unpriced', 'gpt-missing', 500, 500, 0.0, '2026-02-10T13:00:00.000Z')
                """)
        }
    }

    private func seedDayBucketFixture(at dbPath: String, startTimeUTC: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count, tier, hidden_at
                ) VALUES (
                  'mcp-day-bucket', 'codex', ?,
                  '/Users/test/d', 'd', '/tmp/d.jsonl', 1, 'normal', NULL
                )
                """,
                arguments: [startTimeUTC]
            )
            try db.execute(
                sql: """
                INSERT INTO session_costs (
                  session_id, model, input_tokens, output_tokens, cost_usd, computed_at
                ) VALUES (
                  'mcp-day-bucket', 'gpt-test', 1, 1, 0.5, ?
                )
                """,
                arguments: [startTimeUTC]
            )
        }
    }
}
