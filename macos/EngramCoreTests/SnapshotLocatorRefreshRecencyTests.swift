import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

/// Covers the freshness guard in
/// `SessionSnapshotWriter.shouldAcceptLowerSyncLocalLocatorRefresh`: a same-uuid
/// snapshot arriving from a DIFFERENT local path (e.g. a leftover
/// `<old-encoded-cwd>/<uuid>.jsonl` after a Claude Code project rename, while a
/// fresh `<new-cwd>/<uuid>.jsonl` also exists) may only refresh the stored
/// locator when it is at least as fresh as the current row. A staler/emptier
/// leftover must not clobber the richer current record; an equal-or-newer moved
/// file still refreshes.
final class SnapshotLocatorRefreshRecencyTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-locator-recency-\(UUID().uuidString).sqlite")
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
        hash: String,
        sourceLocator: String,
        syncVersion: Int,
        messageCount: Int,
        sizeBytes: Int64,
        endTime: String
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id,
            source: .claudeCode,
            authoritativeNode: "node",
            syncVersion: syncVersion,
            snapshotHash: hash,
            indexedAt: "2026-05-23T10:00:00Z",
            sourceLocator: sourceLocator,
            sizeBytes: sizeBytes,
            startTime: "2026-05-23T09:00:00.000Z",
            endTime: endTime,
            cwd: "/work/engram",
            messageCount: messageCount,
            userMessageCount: max(0, messageCount / 2),
            assistantMessageCount: max(0, messageCount / 2),
            toolMessageCount: 0,
            systemMessageCount: 0,
            tier: .normal
        )
    }

    /// (a) A stale/emptier leftover at a different local path must NOT overwrite
    /// the current richer row, even though the sorted scan visits it last.
    func testStaleLeftoverDoesNotClobberRicherCurrentRow() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            // Richer current row: new path, more messages, larger, later.
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "s", hash: "new-hash", sourceLocator: "/work/new-cwd/s.jsonl",
                    syncVersion: 5, messageCount: 40, sizeBytes: 4000,
                    endTime: "2026-05-23T12:00:00.000Z"
                )
            )
            // Leftover from the old path: same uuid, lower sync, fewer messages,
            // smaller, earlier — a strictly staler/emptier snapshot.
            let result = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "s", hash: "old-hash", sourceLocator: "/work/old-cwd/s.jsonl",
                    syncVersion: 3, messageCount: 4, sizeBytes: 300,
                    endTime: "2026-05-23T10:00:00.000Z"
                )
            )
            XCTAssertEqual(result.action, .noop)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT source_locator FROM sessions WHERE id = 's'"),
                "/work/new-cwd/s.jsonl"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT message_count FROM sessions WHERE id = 's'"),
                40
            )
        }
    }

    /// (b) A genuinely moved file with equal-or-newer content DOES refresh the
    /// stored locator, even though its computed sync_version is lower.
    func testEqualOrNewerMovedFileRefreshesLocator() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            // Current row indexed from the old path.
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "s", hash: "old-hash", sourceLocator: "/work/old-cwd/s.jsonl",
                    syncVersion: 5, messageCount: 10, sizeBytes: 1000,
                    endTime: "2026-05-23T10:00:00.000Z"
                )
            )
            // Same uuid, moved to the new path with newer/richer content but a
            // lower computed sync_version.
            let result = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "s", hash: "new-hash", sourceLocator: "/work/new-cwd/s.jsonl",
                    syncVersion: 3, messageCount: 20, sizeBytes: 2000,
                    endTime: "2026-05-23T12:00:00.000Z"
                )
            )
            XCTAssertEqual(result.action, .merge)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT source_locator FROM sessions WHERE id = 's'"),
                "/work/new-cwd/s.jsonl"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT message_count FROM sessions WHERE id = 's'"),
                20
            )
        }
    }
}
