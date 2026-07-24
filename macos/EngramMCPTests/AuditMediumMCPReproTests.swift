import Foundation
import GRDB
import XCTest

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
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
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
        var env = ProcessInfo.processInfo.environment
        env["TZ"] = timezone
        env["ENGRAM_MCP_DB_PATH"] = dbPath
        env.merge(environment) { _, requested in requested }
        process.environment = env
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

    // MARK: - M19

    func testGetCostsExcludesHiddenSessions_repro() throws {
        let dbPath = try temporaryFixtureCopy("mcp-contract.sqlite", prefix: "engram-mcp-m19")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try wipeSessionsAndCosts(at: dbPath)
        try seedCostHiddenFixture(at: dbPath)

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
        // Visible $1.0; hidden $99 excluded.
        XCTAssertEqual(totalCost, 1.0, accuracy: 0.001, "M19 structured=\(structured)")
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

    // PR #241 (mirror row 1): get_memory recency fills past overfetch after supersede filter.
    func testGetMemoryRecencyFillsActiveMemoriesPastOverfetchWindow_repro() throws {
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

        let structured = try rpc(
            """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_memory","arguments":{"query":"zzzznomatch"}}}
            """,
            dbPath: dbPath
        )
        let memories = try XCTUnwrap(structured["memories"] as? [[String: Any]])
        XCTAssertEqual(memories.count, 5, "\(memories.map { $0["id"] as? String })")
        for memory in memories {
            let id = memory["id"] as? String ?? ""
            XCTAssertTrue(id.hasPrefix("recency-active-"), "unexpected id \(id)")
        }
    }

    // MARK: - Seeds

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
                   NULL, NULL, NULL, 'skip')
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

    private func seedCostHiddenFixture(at dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count, tier, hidden_at
                ) VALUES
                  ('mcp-cost-visible', 'codex', '2026-02-10T10:00:00.000Z',
                   '/Users/test/v', 'v', '/tmp/v.jsonl', 1, 'normal', NULL),
                  ('mcp-cost-hidden', 'codex', '2026-02-10T11:00:00.000Z',
                   '/Users/test/h', 'h', '/tmp/h.jsonl', 1, 'normal', '2026-02-10T12:00:00.000Z')
                """)
            try db.execute(sql: """
                INSERT INTO session_costs (
                  session_id, model, input_tokens, output_tokens, cost_usd, computed_at
                ) VALUES
                  ('mcp-cost-visible', 'gpt-test', 10, 10, 1.0, '2026-02-10T10:00:00.000Z'),
                  ('mcp-cost-hidden', 'gpt-test', 100, 100, 99.0, '2026-02-10T11:00:00.000Z')
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
