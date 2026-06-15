import XCTest
import GRDB
import Foundation
@testable import EngramServiceCore

final class HygieneChecksTests: XCTestCase {
    func testCleanDatabaseScoresFullAndNoIssues() throws {
        let path = try seedHygieneFixture { db in
            try insertSession(db, id: "ok", messageCount: 4, sizeBytes: 4096)
        }
        let response = try EngramServiceCommandHandler.hygiene(
            EngramServiceHygieneRequest(force: false),
            databasePath: path
        )
        XCTAssertEqual(response.score, 100)
        XCTAssertTrue(response.issues.isEmpty)
    }

    func testEmptySessionsProduceIssueAndLowerScore() throws {
        let path = try seedHygieneFixture { db in
            try insertSession(db, id: "e1", messageCount: 0, sizeBytes: 100)
            try insertSession(db, id: "e2", messageCount: 0, sizeBytes: 200)
        }
        let response = try EngramServiceCommandHandler.hygiene(
            EngramServiceHygieneRequest(force: false),
            databasePath: path
        )
        XCTAssertTrue(response.issues.contains(where: { $0.kind == "empty-sessions" }))
        XCTAssertEqual(response.score, 96) // 100 - 2*2
    }

    func testPendingSuggestionProducesInfoIssue() throws {
        let path = try seedHygieneFixture { db in
            try insertSession(db, id: "s1", messageCount: 3, sizeBytes: 4096, suggestedParentId: "p1")
        }
        let response = try EngramServiceCommandHandler.hygiene(
            EngramServiceHygieneRequest(force: false),
            databasePath: path
        )
        let issue = try XCTUnwrap(response.issues.first(where: { $0.kind == "pending-suggestions" }))
        XCTAssertEqual(issue.severity, "info")
        XCTAssertEqual(response.score, 99)
    }

    func testOrphanProducesWarningIssue() throws {
        let path = try seedHygieneFixture { db in
            try insertSession(db, id: "o1", messageCount: 3, sizeBytes: 4096, orphanStatus: "missing-parent")
        }
        let response = try EngramServiceCommandHandler.hygiene(
            EngramServiceHygieneRequest(force: false),
            databasePath: path
        )
        let issue = try XCTUnwrap(response.issues.first(where: { $0.kind == "orphans" }))
        XCTAssertEqual(issue.severity, "warning")
        XCTAssertEqual(response.score, 95)
    }

    func testEmptyOrphanStatusNotCounted() throws {
        let path = try seedHygieneFixture { db in
            try insertSession(db, id: "o1", messageCount: 3, sizeBytes: 4096, orphanStatus: "")
        }
        let response = try EngramServiceCommandHandler.hygiene(
            EngramServiceHygieneRequest(force: false),
            databasePath: path
        )
        XCTAssertFalse(response.issues.contains(where: { $0.kind == "orphans" }))
        XCTAssertEqual(response.score, 100)
    }

    func testEmptyCountMatchesHidePredicate() throws {
        let path = try seedHygieneFixture { db in
            // 2 empty (match), 1 already-hidden (no match), 1 big (no match).
            try insertSession(db, id: "e1", messageCount: 0, sizeBytes: 100)
            try insertSession(db, id: "e2", messageCount: 0, sizeBytes: 500)
            try insertSession(db, id: "hidden", messageCount: 0, sizeBytes: 100, hiddenAt: "2026-06-01T00:00:00Z")
            try insertSession(db, id: "big", messageCount: 0, sizeBytes: 4096)
        }
        let response = try EngramServiceCommandHandler.hygiene(
            EngramServiceHygieneRequest(force: false),
            databasePath: path
        )
        let issue = try XCTUnwrap(response.issues.first(where: { $0.kind == "empty-sessions" }))
        // The message embeds the count; assert the predicate matched exactly 2.
        XCTAssertTrue(issue.message.hasPrefix("2 empty session"))

        // Independently count the hideEmptySessions predicate to prove parity.
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        let predicateCount = try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sessions
                WHERE message_count = 0 AND size_bytes < 1024 AND hidden_at IS NULL
            """) ?? 0
        }
        XCTAssertEqual(predicateCount, 2)
    }

    // MARK: - Helpers

    private func seedHygieneFixture(seed: (GRDB.Database) throws -> Void) throws -> String {
        let path = NSTemporaryDirectory() + "engram-hygiene-\(UUID().uuidString.prefix(8)).sqlite"
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
                  cwd TEXT NOT NULL DEFAULT '',
                  file_path TEXT NOT NULL DEFAULT '',
                  indexed_at TEXT NOT NULL DEFAULT '',
                  message_count INTEGER NOT NULL DEFAULT 0,
                  size_bytes INTEGER NOT NULL DEFAULT 0,
                  hidden_at TEXT,
                  parent_session_id TEXT,
                  suggested_parent_id TEXT,
                  orphan_status TEXT
                );
            """)
            try seed(db)
        }
        return path
    }

    private func insertSession(
        _ db: GRDB.Database,
        id: String,
        messageCount: Int,
        sizeBytes: Int,
        hiddenAt: String? = nil,
        suggestedParentId: String? = nil,
        orphanStatus: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sessions
                  (id, message_count, size_bytes, hidden_at, suggested_parent_id, orphan_status)
                VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, messageCount, sizeBytes, hiddenAt, suggestedParentId, orphanStatus]
        )
    }
}
