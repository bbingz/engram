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
        cwd: String = "/work/engram",
        sizeBytes: Int64? = 0,
        messageCount: Int = 4,
        userMessageCount: Int = 2,
        assistantMessageCount: Int = 2,
        toolMessageCount: Int = 0,
        systemMessageCount: Int = 0,
        summaryMessageCount: Int? = nil,
        tier: SessionTier? = .normal,
        agentRole: String? = nil,
        parentSessionId: String? = nil,
        implementationBeats: [SessionImplementationBeat] = []
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id, source: source, authoritativeNode: "node", syncVersion: 1,
            snapshotHash: "\(hash)-\(id)", indexedAt: "2026-05-23T10:00:00Z",
            sourceLocator: "/tmp/\(id).jsonl", sizeBytes: sizeBytes, startTime: "2026-05-23T10:00:00.000Z",
            cwd: cwd, messageCount: messageCount, userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount, toolMessageCount: toolMessageCount, systemMessageCount: systemMessageCount,
            summaryMessageCount: summaryMessageCount,
            tier: tier, agentRole: agentRole, parentSessionId: parentSessionId,
            implementationBeats: implementationBeats
        )
    }

    private func beat(
        sessionId: String,
        index: Int = 0,
        date: String = "2026-05-23",
        title: String = "Add implementation timeline",
        status: SessionImplementationStatus = .completed,
        events: [SessionOperationEvent] = [.verified]
    ) -> SessionImplementationBeat {
        SessionImplementationBeat(
            sessionId: sessionId,
            beatIndex: index,
            actionDate: date,
            actionTimestamp: "\(date)T10:30:00.000Z",
            workKey: title.lowercased().replacingOccurrences(of: " ", with: "-"),
            workTitle: title,
            humanIntent: title,
            assistantOutcome: "Completed \(title)",
            kind: .implementation,
            status: status,
            operationEvents: events,
            confidence: 0.91
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

    func testReindexPreservesInstructionSignalsOnEmptyRestream() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            // Healthy first index: 3 distinct asks, streamStats sentinel = 10.
            var s1 = snapshot(id: "ses", hash: "h1")
            s1.summaryMessageCount = 10
            s1.instructionCount = 3
            s1.humanTurnCount = 6
            s1.instructionSummary = "Add login\nFix parser\nWrite tests"
            _ = try w.writeAuthoritativeSnapshot(s1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT instruction_count FROM sessions WHERE id = 'ses'"), 3)

            // Empty/failed re-stream (sentinel = 0) must preserve all three together.
            var s2 = snapshot(id: "ses", hash: "h2")
            s2.summaryMessageCount = 0
            s2.instructionCount = 0
            s2.humanTurnCount = 0
            s2.instructionSummary = nil
            _ = try w.writeAuthoritativeSnapshot(s2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT instruction_count FROM sessions WHERE id = 'ses'"), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT human_turn_count FROM sessions WHERE id = 'ses'"), 6)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT instruction_summary FROM sessions WHERE id = 'ses'"),
                "Add login\nFix parser\nWrite tests"
            )

            // Healthy re-stream overwrites the set fresh.
            var s3 = snapshot(id: "ses", hash: "h3")
            s3.summaryMessageCount = 12
            s3.instructionCount = 4
            s3.humanTurnCount = 8
            s3.instructionSummary = "A\nB\nC\nD"
            _ = try w.writeAuthoritativeSnapshot(s3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT instruction_count FROM sessions WHERE id = 'ses'"), 4)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT instruction_summary FROM sessions WHERE id = 'ses'"), "A\nB\nC\nD")
        }
    }

    func testReindexPreservesCwdAndMessageCountsWhenIncomingParseIsEmpty() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "partial",
                    hash: "h1",
                    cwd: "/work/engram",
                    messageCount: 5,
                    userMessageCount: 2,
                    assistantMessageCount: 2,
                    toolMessageCount: 1,
                    systemMessageCount: 0
                )
            )

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "partial",
                    hash: "h2",
                    cwd: "",
                    messageCount: 0,
                    userMessageCount: 0,
                    assistantMessageCount: 0,
                    toolMessageCount: 0,
                    systemMessageCount: 0
                )
            )

            let row = try Row.fetchOne(db, sql: """
                SELECT cwd, message_count, user_message_count, assistant_message_count,
                       tool_message_count, system_message_count
                  FROM sessions
                 WHERE id = 'partial'
                """)
            XCTAssertEqual(row?["cwd"], "/work/engram")
            XCTAssertEqual(row?["message_count"], 5)
            XCTAssertEqual(row?["user_message_count"], 2)
            XCTAssertEqual(row?["assistant_message_count"], 2)
            XCTAssertEqual(row?["tool_message_count"], 1)
            XCTAssertEqual(row?["system_message_count"], 0)
        }
    }

    func testWriterPersistsImplementationBeats() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "work",
                    hash: "h1",
                    summaryMessageCount: 6,
                    implementationBeats: [beat(sessionId: "work")]
                )
            )

            let row = try Row.fetchOne(db, sql: """
                SELECT action_date, work_title, status, operation_events, confidence
                  FROM session_work_beats
                 WHERE session_id = 'work' AND beat_index = 0
                """)
            XCTAssertEqual(row?["action_date"], "2026-05-23")
            XCTAssertEqual(row?["work_title"], "Add implementation timeline")
            XCTAssertEqual(row?["status"], "completed")
            XCTAssertEqual(row?["operation_events"], "[\"verified\"]")
            let confidence: Double? = row?["confidence"]
            XCTAssertEqual(confidence ?? 0, 0.91, accuracy: 0.001)
        }
    }

    func testNoopReindexReplacesChangedImplementationBeats() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "work",
                    hash: "stable",
                    summaryMessageCount: 6,
                    implementationBeats: [beat(sessionId: "work", title: "Add old timeline")]
                )
            )

            let result = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "work",
                    hash: "stable",
                    summaryMessageCount: 6,
                    implementationBeats: [
                        beat(sessionId: "work", title: "Add implementation timeline"),
                        beat(sessionId: "work", index: 1, date: "2026-05-24", title: "Polish implementation timeline"),
                    ]
                )
            )

            XCTAssertEqual(result.action, .noop)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_work_beats WHERE session_id = 'work'"),
                2
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT work_title FROM session_work_beats WHERE session_id = 'work' AND beat_index = 0"
                ),
                "Add implementation timeline"
            )
        }
    }

    func testEmptyRestreamPreservesImplementationBeats() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "work",
                    hash: "h1",
                    summaryMessageCount: 6,
                    implementationBeats: [beat(sessionId: "work")]
                )
            )

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "work",
                    hash: "h2",
                    messageCount: 0,
                    userMessageCount: 0,
                    assistantMessageCount: 0,
                    summaryMessageCount: 0,
                    implementationBeats: []
                )
            )

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_work_beats WHERE session_id = 'work'"),
                1
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT work_title FROM session_work_beats WHERE session_id = 'work'"),
                "Add implementation timeline"
            )
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
