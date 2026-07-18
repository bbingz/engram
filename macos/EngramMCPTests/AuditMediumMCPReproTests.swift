import Foundation
import GRDB
import XCTest

/// Behavioral repros for M9/M18/M19/M24 driving the shipped EngramMCP binary
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
        timezone: String = "UTC"
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
        let result = try XCTUnwrap(json["result"] as? [String: Any], "raw=\(firstLine)")
        return try XCTUnwrap(result["structuredContent"] as? [String: Any], "raw=\(firstLine)")
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

    // MARK: - Seeds

    private func wipeSessionsAndCosts(at dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM session_costs")
            try db.execute(sql: "DELETE FROM sessions")
            try? db.execute(sql: "DELETE FROM sessions_fts")
        }
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
