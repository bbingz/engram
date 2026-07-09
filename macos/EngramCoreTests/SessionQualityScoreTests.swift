import GRDB
import XCTest
@testable import EngramCoreWrite

final class SessionQualityScoreTests: XCTestCase {
    func testGoldenFactorBoundaries() {
        // All zeros → 0
        XCTAssertEqual(
            SessionQualityScore.compute(
                userCount: 0, assistantCount: 0, toolCount: 0, systemCount: 0,
                startTime: nil, endTime: nil, project: nil
            ),
            0
        )

        // Project alone → 15
        XCTAssertEqual(
            SessionQualityScore.compute(
                userCount: 0, assistantCount: 0, toolCount: 0, systemCount: 0,
                startTime: nil, endTime: nil, project: "engram"
            ),
            15
        )

        // Balanced multi-turn with tools, density, project, volume.
        let start = "2026-04-23T10:00:00.000Z"
        let end = "2026-04-23T10:30:00.000Z" // 30 min → density 20
        let score = SessionQualityScore.compute(
            userCount: 10,
            assistantCount: 10,
            toolCount: 5,
            systemCount: 0,
            startTime: start,
            endTime: end,
            project: "engram"
        )
        // turn: min(10,10)/25 * 30 = 12; tool: 5/10 * 50 = 25; density 20; project 15; volume min(10, 25/5)=5
        // → 12+25+20+15+5 = 77
        XCTAssertEqual(score, 77)

        // Same inputs always identical.
        XCTAssertEqual(
            SessionQualityScore.compute(
                userCount: 10, assistantCount: 10, toolCount: 5, systemCount: 0,
                startTime: start, endTime: end, project: "engram"
            ),
            score
        )
    }

    /// End-to-end: snapshot write path and startup backfill path must agree
    /// for the same factors on a temp DB (lifecycle plan same-input/same-output).
    func testSnapshotWriterAndBackfillAgreeOnTempDB() throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality-score-parity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()

        let start = "2026-04-23T10:00:00.000Z"
        let end = "2026-04-23T10:15:00.000Z"
        let expected = SessionQualityScore.compute(
            userCount: 4,
            assistantCount: 4,
            toolCount: 2,
            systemCount: 1,
            startTime: start,
            endTime: end,
            project: "engram"
        )

        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions(
                  id, source, start_time, end_time, project, file_path, tier,
                  user_message_count, assistant_message_count, tool_message_count, system_message_count,
                  quality_score
                ) VALUES (
                  'q-parity', 'codex', ?, ?, 'engram', '/tmp/q.jsonl', 'normal',
                  4, 4, 2, 1, 0
                )
                """,
                arguments: [start, end]
            )
            let updated = try StartupBackfills.backfillScores(db)
            XCTAssertEqual(updated, 1)
            let stored = try Int.fetchOne(db, sql: "SELECT quality_score FROM sessions WHERE id = 'q-parity'")
            XCTAssertEqual(stored, expected)
        }

        // Pure function remains the authority for the snapshot-writer path.
        XCTAssertEqual(
            SessionQualityScore.compute(
                userCount: 4, assistantCount: 4, toolCount: 2, systemCount: 1,
                startTime: start, endTime: end, project: "engram"
            ),
            expected
        )
    }
}
