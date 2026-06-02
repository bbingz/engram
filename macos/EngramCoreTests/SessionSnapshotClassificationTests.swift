import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

/// Covers the re-index preservation guards in `SessionSnapshotWriter.upsert`:
/// a content re-index must not revert a Layer-2 dispatched/skip classification,
/// and a Gemini sidecar parent (Layer 1c) must be persisted without clobbering a
/// user-confirmed ('manual') link.
final class SessionSnapshotClassificationTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-classification-\(UUID().uuidString).sqlite")
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
        source: SourceName = .codex,
        hash: String = "h",
        tier: SessionTier? = .normal,
        agentRole: String? = nil,
        parentSessionId: String? = nil
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id, source: source, authoritativeNode: "node", syncVersion: 1,
            snapshotHash: "\(hash)-\(id)", indexedAt: "2026-05-23T10:00:00Z",
            sourceLocator: "/tmp/\(id).jsonl", startTime: "2026-05-23T10:00:00.000Z",
            cwd: "/work/engram", messageCount: 4, userMessageCount: 2,
            assistantMessageCount: 2, toolMessageCount: 0, systemMessageCount: 0,
            tier: tier, agentRole: agentRole, parentSessionId: parentSessionId
        )
    }

    func testReindexPreservesDispatchedSkipClassificationOnContentChange() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            // First index a normal session, then classify it dispatched/skip
            // (as the Layer-2 backfill would).
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "child", hash: "h1"))
            try db.execute(sql: "UPDATE sessions SET agent_role = 'dispatched', tier = 'skip' WHERE id = 'child'")

            // Re-index with a content change (distinct hash). The incoming snapshot
            // carries the default agent_role=nil, tier=normal — which must NOT revert
            // the stored classification.
            let result = try w.writeAuthoritativeSnapshot(snapshot(id: "child", hash: "h2"))
            XCTAssertEqual(result.action, .merge)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'child'"), "dispatched")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'child'"), "skip")
        }
    }

    func testReindexDoesNotEnqueueFtsForPreservedSkipChild() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "child", hash: "h1"))
            try db.execute(sql: "UPDATE sessions SET agent_role = 'dispatched', tier = 'skip' WHERE id = 'child'")
            // Clear any pending jobs from the initial normal-tier index.
            try db.execute(sql: "DELETE FROM session_index_jobs WHERE session_id = 'child'")

            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "child", hash: "h2"))

            // Because the row stays 'skip', the re-index must not enqueue an FTS job
            // (which jobKinds gates on the preserved tier, not the incoming one).
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'child' AND job_kind = 'fts'"),
                0
            )
        }
    }

    func testReindexPreservesAgentRoleWhenIncomingHasNone() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            // Index with agent_role set, then re-index a content change with no role.
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "child", hash: "h1", tier: .skip, agentRole: "dispatched"))
            let result = try w.writeAuthoritativeSnapshot(snapshot(id: "child", hash: "h2", tier: .normal, agentRole: nil))
            XCTAssertEqual(result.action, .merge)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'child'"), "dispatched")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'child'"), "skip")
        }
    }

    func testGeminiSidecarParentSessionIdPersistedAsPathLink() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(id: "gem-child", source: .geminiCli, parentSessionId: "cc-parent")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'gem-child'"),
                "cc-parent"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'gem-child'"),
                "path"
            )
        }
    }

    func testReindexDoesNotOverwriteManualParentLink() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(id: "gem-child", source: .geminiCli, hash: "h1", parentSessionId: "cc-parent")
            )
            // A user manually links the child to a different parent.
            try db.execute(
                sql: "UPDATE sessions SET parent_session_id = 'manual-parent', link_source = 'manual' WHERE id = 'gem-child'"
            )

            // Re-index still carries the sidecar parent, but the manual link must win.
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(id: "gem-child", source: .geminiCli, hash: "h2", parentSessionId: "cc-parent")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'gem-child'"),
                "manual-parent"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'gem-child'"),
                "manual"
            )
        }
    }

    func testSnapshotWithoutParentLeavesLinkColumnsNull() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "plain"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'plain'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'plain'"))
        }
    }
}
