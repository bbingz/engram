import XCTest
import GRDB
import Foundation
@testable import EngramServiceCore

final class ReplayDataTests: XCTestCase {
    func testReplayEntriesFromMessagesPreservesRolesAndComputesDurations() {
        let messages = [
            msg(role: "user", content: "hi", ts: "2026-06-14T10:00:00.000Z"),
            msg(role: "assistant", content: "running", ts: "2026-06-14T10:00:01.500Z", toolName: "Bash", input: 10, output: 20),
            msg(role: "tool", content: "ok", ts: "2026-06-14T10:00:05.000Z")
        ]
        let entries = SQLiteEngramServiceReadProvider.replayEntries(from: messages, limit: 500)

        XCTAssertEqual(entries.map(\.role), ["user", "assistant", "tool"])
        XCTAssertEqual(entries[1].toolName, "Bash")
        XCTAssertEqual(entries[1].tokens?.input, 10)
        XCTAssertEqual(entries[1].tokens?.output, 20)
        XCTAssertEqual(entries[0].durationToNextMs, 1500)
        XCTAssertEqual(entries[1].durationToNextMs, 3500)
        XCTAssertNil(entries[2].durationToNextMs)
        // No summary appended → entry count equals message count.
        XCTAssertEqual(entries.count, 3)
    }

    func testReplayEntriesNilDurationWhenTimestampMissing() {
        let messages = [
            msg(role: "user", content: "a", ts: "2026-06-14T10:00:00Z"),
            msg(role: "assistant", content: "b", ts: nil),
            msg(role: "user", content: "c", ts: "2026-06-14T10:00:10Z")
        ]
        let entries = SQLiteEngramServiceReadProvider.replayEntries(from: messages, limit: 500)
        // Both neighbors of the timestamp-less middle message get nil duration.
        XCTAssertNil(entries[0].durationToNextMs)
        XCTAssertNil(entries[1].durationToNextMs)
    }

    func testReplayEntriesToleratesNonFractionalISO() {
        let messages = [
            msg(role: "user", content: "a", ts: "2026-06-14T10:00:00Z"),
            msg(role: "assistant", content: "b", ts: "2026-06-14T10:00:30Z")
        ]
        let entries = SQLiteEngramServiceReadProvider.replayEntries(from: messages, limit: 500)
        XCTAssertEqual(entries[0].durationToNextMs, 30_000)
    }

    func testReplayEntriesRespectsLimit() {
        let messages = (0..<10).map { msg(role: "user", content: "m\($0)", ts: nil) }
        let entries = SQLiteEngramServiceReadProvider.replayEntries(from: messages, limit: 3)
        XCTAssertEqual(entries.count, 3)
    }

    func testInsightsReadsTableAndEmptyWhenAbsent() async throws {
        // Table present → rows returned newest-first.
        let withTable = try seedInsightsFixture(createInsightsTable: true) { db in
            try db.execute(
                sql: "INSERT INTO insights (id, content, importance, created_at) VALUES (?, ?, ?, ?)",
                arguments: ["i1", "decision content", 7, "2026-06-14T10:00:00Z"]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: withTable)
        let insights = try await provider.insights()
        XCTAssertEqual(insights.count, 1)
        XCTAssertEqual(insights.first?.id, "i1")
        XCTAssertEqual(insights.first?.content, "decision content")
        XCTAssertEqual(insights.first?.importance, 7)
        XCTAssertEqual(insights.first?.createdAt, "2026-06-14T10:00:00Z")

        // Table absent (fresh DB) → empty, no "no such table" throw.
        let withoutTable = try seedInsightsFixture(createInsightsTable: false) { _ in }
        let emptyProvider = try SQLiteEngramServiceReadProvider(databasePath: withoutTable)
        let empty = try await emptyProvider.insights()
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - Helpers

    private func msg(
        role: String,
        content: String,
        ts: String?,
        toolName: String? = nil,
        input: Int? = nil,
        output: Int? = nil
    ) -> SQLiteEngramServiceReadProvider.ReplayMessage {
        SQLiteEngramServiceReadProvider.ReplayMessage(
            role: role,
            content: content,
            timestamp: ts,
            toolName: toolName,
            inputTokens: input,
            outputTokens: output
        )
    }

    private func seedInsightsFixture(
        createInsightsTable: Bool,
        seed: (GRDB.Database) throws -> Void
    ) throws -> String {
        let path = NSTemporaryDirectory() + "engram-insights-\(UUID().uuidString.prefix(8)).sqlite"
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL DEFAULT 'codex',
                  start_time TEXT NOT NULL DEFAULT '',
                  hidden_at TEXT
                );
            """)
            if createInsightsTable {
                try db.execute(sql: """
                    CREATE TABLE insights (
                      id TEXT PRIMARY KEY,
                      content TEXT NOT NULL,
                      wing TEXT,
                      room TEXT,
                      source_session_id TEXT,
                      importance INTEGER DEFAULT 5,
                      has_embedding INTEGER DEFAULT 0,
                      created_at TEXT DEFAULT (datetime('now'))
                    );
                """)
            }
            try seed(db)
        }
        return path
    }
}
