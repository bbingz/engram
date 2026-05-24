import GRDB
import XCTest
@testable import EngramCoreWrite

final class StartupUsageCollectorTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-usage-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB {
            try? FileManager.default.removeItem(at: tempDB)
        }
        tempDB = nil
    }

    func testCollectorWritesProviderUsageSnapshotsForTrackedCLIs() throws {
        try writer.write { db in
            try insertSession(db, id: "claude-1", source: "claude-code", startTime: "2026-05-24T10:00:00.000Z")
            try insertSession(db, id: "codex-1", source: "codex", startTime: "2026-05-24T10:10:00.000Z")
            try insertSession(db, id: "gemini-1", source: "gemini-cli", startTime: "2026-05-24T10:20:00.000Z")
            try insertSession(db, id: "ag-1", source: "antigravity", startTime: "2026-05-24T10:30:00.000Z")
            try insertSession(db, id: "open-1", source: "opencode", startTime: "2026-05-24T10:40:00.000Z")
            try insertCost(db, sessionId: "claude-1", model: "claude-sonnet", input: 100, output: 40, cost: 0.24)
            try insertCost(db, sessionId: "codex-1", model: "gpt-5", input: 200, output: 60, cost: 0.36)
            try insertCost(db, sessionId: "gemini-1", model: "gemini-2.5-pro", input: 150, output: 20, cost: 0.18)
            try insertCost(db, sessionId: "ag-1", model: "gemini-2.5-pro", input: 50, output: 10, cost: 0.07)
            try insertCost(db, sessionId: "open-1", model: "opencode", input: 70, output: 20, cost: 0.09)
        }

        let emitted = try WriterStartupUsageCollector(writer: writer, now: {
            ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")!
        }).collect()

        XCTAssertEqual(Set(emitted.map(\.source)), ["claude-code", "codex", "gemini-cli", "antigravity", "opencode"])
        XCTAssertTrue(emitted.allSatisfy { $0.metric == "7d cost share" && $0.value > 0 })

        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT source, metric, value, unit FROM usage_snapshots ORDER BY source, metric"
            )
        }
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(Set(rows.map { $0["unit"] as String }), ["%"])
    }

    private func insertSession(
        _ db: Database,
        id: String,
        source: String,
        startTime: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(id, source, start_time, cwd, file_path, indexed_at)
            VALUES (?, ?, ?, '/repo', '/tmp/\(id).jsonl', ?)
            """,
            arguments: [id, source, startTime, startTime]
        )
    }

    private func insertCost(
        _ db: Database,
        sessionId: String,
        model: String,
        input: Int,
        output: Int,
        cost: Double
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO session_costs(
              session_id, model, input_tokens, output_tokens, cache_read_tokens,
              cache_creation_tokens, cost_usd, computed_at
            ) VALUES (?, ?, ?, ?, 0, 0, ?, '2026-05-24T12:00:00.000Z')
            """,
            arguments: [sessionId, model, input, output, cost]
        )
    }
}
