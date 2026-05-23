import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class IndexAutoTitleTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-title-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB { try? FileManager.default.removeItem(at: tempDB) }
        tempDB = nil
    }

    private func snapshot(
        id: String,
        summary: String? = nil,
        project: String? = nil,
        cwd: String = "/work/engram",
        startTime: String = "2026-05-23T10:00:00.000Z",
        hash: String = "h"
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id, source: .codex, authoritativeNode: "node", syncVersion: 1,
            snapshotHash: "\(hash)-\(id)", indexedAt: "2026-05-23T10:00:00Z",
            sourceLocator: "/tmp/\(id).jsonl", startTime: startTime, cwd: cwd,
            project: project, messageCount: 4, userMessageCount: 2,
            assistantMessageCount: 2, toolMessageCount: 0, systemMessageCount: 0,
            summary: summary, tier: .normal
        )
    }

    func testFreshIndexSetsGeneratedTitleFromSummaryFirstLine() throws {
        try writer.write { db in
            _ = try SessionSnapshotWriter(db: db)
                .writeAuthoritativeSnapshot(snapshot(id: "s1", summary: "Fix the login bug\nmore detail"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='s1'"),
                "Fix the login bug"
            )
        }
    }

    func testFreshIndexFallsBackToProjectAndDateWhenNoSummary() throws {
        try writer.write { db in
            _ = try SessionSnapshotWriter(db: db)
                .writeAuthoritativeSnapshot(snapshot(id: "s2", project: "engram"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='s2'"),
                "engram 2026-05-23"
            )
        }
    }

    func testReindexNeverClobbersExistingTitle() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "s3", summary: "First title", hash: "h1"))
            // Simulate a user-set custom title living in generated_title.
            try db.execute(sql: "UPDATE sessions SET generated_title='User Edited' WHERE id='s3'")
            // Re-index with a changed snapshot (distinct hash forces the full
            // merge/upsert path, not a noop).
            let result = try w.writeAuthoritativeSnapshot(snapshot(id: "s3", summary: "Second title", hash: "h2"))
            XCTAssertEqual(result.action, .merge)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id='s3'"),
                "User Edited"
            )
        }
    }
}
