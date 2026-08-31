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
        sourceLocator: String? = nil,
        implementationBeats: [SessionImplementationBeat] = []
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id, source: source, authoritativeNode: "node", syncVersion: 1,
            snapshotHash: "\(hash)-\(id)", indexedAt: "2026-05-23T10:00:00Z",
            sourceLocator: sourceLocator ?? "/tmp/\(id).jsonl", sizeBytes: sizeBytes, startTime: "2026-05-23T10:00:00.000Z",
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

    func testOpenCodeNilRoleClearsStoredDispatchedClassificationOnSameHash_repro() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "ordinary-fork",
                    source: .opencode,
                    hash: "same",
                    tier: .skip,
                    agentRole: "dispatched"
                )
            )
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "ordinary-fork",
                    source: .opencode,
                    hash: "same",
                    tier: .normal,
                    agentRole: nil
                )
            )

            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'ordinary-fork'")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'ordinary-fork'"),
                "normal"
            )
        }
    }

    func testOpenCodeReindexPreservesCheckedDispatchedProbe_repro() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "checked-probe",
                    source: .opencode,
                    hash: "same",
                    tier: .skip,
                    agentRole: "dispatched"
                )
            )
            try db.execute(
                sql: "UPDATE sessions SET link_checked_at = '2026-08-23T12:00:00Z' WHERE id = 'checked-probe'"
            )
            try db.execute(sql: "DELETE FROM session_index_jobs WHERE session_id = 'checked-probe'")

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "checked-probe",
                    source: .opencode,
                    hash: "same",
                    tier: .normal,
                    agentRole: nil
                )
            )

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'checked-probe'"),
                "dispatched"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'checked-probe'"),
                "skip"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'checked-probe' AND job_kind = 'fts'"
                ),
                0
            )
        }
    }

    func testOpenCodeCheckedOrdinaryForkDoesNotPinSkipTier_repro() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(id: "ordinary", source: .opencode, hash: "old", tier: .skip)
            )
            try db.execute(
                sql: "UPDATE sessions SET link_checked_at = '2026-08-23T12:00:00Z' WHERE id = 'ordinary'"
            )

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(id: "ordinary", source: .opencode, hash: "new", tier: .normal)
            )

            XCTAssertNil(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'ordinary'"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'ordinary'"),
                "normal"
            )
        }
    }

    func testOpenCodeParentBackfillLinksChildAfterHostArrives_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-parent-backfill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY,
                    parent_id TEXT,
                    time_archived INTEGER
                );
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('child', 'host', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "child",
                    source: .opencode,
                    hash: "child",
                    sourceLocator: "\(externalURL.path)::child"
                )
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'")
            )
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))

            let result = try StartupBackfills.backfillParentLinks(db)

            XCTAssertEqual(result.linked, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"),
                "host"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'child'"),
                "path"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'child'"),
                "an ordinary OpenCode fork must not receive a skip-pinning classification stamp"
            )
        }
    }

    func testOpenCodeWriteWalksMissingVendorIntermediateToHost_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-missing-intermediate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, time_archived INTEGER);
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('fork', 'host', NULL);
                INSERT INTO session VALUES ('task', 'fork', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "task",
                    source: .opencode,
                    hash: "task",
                    tier: .skip,
                    agentRole: "dispatched",
                    sourceLocator: "\(externalURL.path)::task"
                )
            )

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'task'"),
                "host",
                "authoritative OpenCode writes should resolve external ancestry immediately"
            )
            XCTAssertEqual(
                try StartupBackfills.backfillParentLinks(db).linked,
                0,
                "startup backfill should have no stale parent left to repair"
            )
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, agent_role, tier FROM sessions WHERE id = 'task'"
            ))
            XCTAssertEqual(row["parent_session_id"] as String?, "host")
            XCTAssertEqual(row["agent_role"] as String?, "dispatched")
            XCTAssertEqual(row["tier"] as String?, "skip")
        }
    }

    func testOpenCodeWriteWalksArchivedVendorForkToLiveHostAndPreservesSkip_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-archived-fork-write-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, time_archived INTEGER);
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('archived-fork', 'host', 1);
                INSERT INTO session VALUES ('task', 'archived-fork', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "task",
                    source: .opencode,
                    hash: "task",
                    tier: .skip,
                    agentRole: "dispatched",
                    sourceLocator: "\(externalURL.path)::task"
                )
            )

            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, agent_role, tier FROM sessions WHERE id = 'task'"
            ))
            XCTAssertEqual(row["parent_session_id"] as String?, "host")
            XCTAssertEqual(row["agent_role"] as String?, "dispatched")
            XCTAssertEqual(row["tier"] as String?, "skip")
        }
    }

    func testOpenCodeBackfillWalksArchivedVendorForkToLiveHostAndPreservesSkip_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-archived-fork-backfill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, time_archived INTEGER);
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('archived-fork', 'host', 1);
                INSERT INTO session VALUES ('task', 'archived-fork', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "task",
                    source: .opencode,
                    hash: "task",
                    tier: .skip,
                    agentRole: "dispatched",
                    sourceLocator: "\(externalURL.path)::task"
                )
            )
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))

            XCTAssertEqual(try StartupBackfills.backfillParentLinks(db).linked, 1)
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, agent_role, tier FROM sessions WHERE id = 'task'"
            ))
            XCTAssertEqual(row["parent_session_id"] as String?, "host")
            XCTAssertEqual(row["agent_role"] as String?, "dispatched")
            XCTAssertEqual(row["tier"] as String?, "skip")
        }
    }

    func testOpenCodeCheckedOrdinaryForkReindexStaysDispatchedSkip_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-checked-ordinary-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY, parent_id TEXT, title TEXT,
                    agent TEXT, slug TEXT, time_archived INTEGER
                );
                INSERT INTO session VALUES ('host', NULL, 'Host', NULL, NULL, NULL);
                INSERT INTO session VALUES ('checked-task', 'host', 'quick ping', 'build', NULL, NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            let locator = "\(externalURL.path)::checked-task"
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "checked-task",
                    source: .opencode,
                    hash: "same",
                    tier: .skip,
                    agentRole: "dispatched",
                    sourceLocator: locator
                )
            )
            try db.execute(
                sql: "UPDATE sessions SET link_checked_at = '2026-08-24T00:00:00Z' WHERE id = 'checked-task'"
            )
            try db.execute(sql: "DELETE FROM session_index_jobs WHERE session_id = 'checked-task'")

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "checked-task",
                    source: .opencode,
                    hash: "same",
                    tier: .normal,
                    agentRole: nil,
                    sourceLocator: locator
                )
            )

            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT agent_role, tier, link_checked_at FROM sessions WHERE id = 'checked-task'"
            ))
            XCTAssertEqual(row["agent_role"] as String?, "dispatched")
            XCTAssertEqual(row["tier"] as String?, "skip")
            XCTAssertNotNil(row["link_checked_at"] as String?)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'checked-task' AND job_kind = 'fts'"
                ),
                0
            )
        }
    }

    func testOpenCodeReindexKeepsValidatedParentWhenExternalDatabaseIsUnavailable_repro() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-opencode-\(UUID().uuidString).sqlite")
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "child",
                    source: .opencode,
                    hash: "child",
                    parentSessionId: "host",
                    sourceLocator: "\(missing.path)::child"
                )
            )

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"),
                "host",
                "an unreadable vendor database is not authoritative evidence that the parent disappeared"
            )
        }
    }

    func testOpenCodeBackfillRemovesExistingPathLinkWhenExternalHostIsArchived_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-existing-archived-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, time_archived INTEGER);
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('child', 'host', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "child",
                    source: .opencode,
                    hash: "child",
                    parentSessionId: "host",
                    sourceLocator: "\(externalURL.path)::child"
                )
            )
            try external.write { externalDB in
                try externalDB.execute(sql: "UPDATE session SET time_archived = 1 WHERE id = 'host'")
            }

            _ = try StartupBackfills.backfillParentLinks(db)

            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'")
            )
        }
    }

    func testOpenCodeTaskToolBackfillRetargetsTopLevelHostAndStaysSkip_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-nested-task-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, time_archived INTEGER);
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('fork', 'host', NULL);
                INSERT INTO session VALUES ('task', 'fork', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "fork",
                    source: .opencode,
                    hash: "fork",
                    parentSessionId: "host",
                    sourceLocator: "\(externalURL.path)::fork"
                )
            )
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "task",
                    source: .opencode,
                    hash: "task",
                    tier: .skip,
                    agentRole: "dispatched",
                    parentSessionId: "fork",
                    sourceLocator: "\(externalURL.path)::task"
                )
            )
            _ = try StartupBackfills.backfillParentLinks(db)

            let row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, agent_role, tier FROM sessions WHERE id = 'task'"
            )
            XCTAssertEqual(row?["parent_session_id"], "host")
            XCTAssertEqual(row?["agent_role"], "dispatched")
            XCTAssertEqual(row?["tier"], "skip")
        }
    }

    func testOpenCodeSameHashDropsHiddenOrphanPathParent_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-hidden-parent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY,
                    parent_id TEXT,
                    time_archived INTEGER
                );
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('child', 'host', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            let child = snapshot(
                id: "child",
                source: .opencode,
                hash: "same",
                messageCount: 1,
                userMessageCount: 1,
                assistantMessageCount: 0,
                parentSessionId: "host",
                sourceLocator: "\(externalURL.path)::child"
            )
            _ = try w.writeAuthoritativeSnapshot(child)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"),
                "host"
            )

            try db.execute(
                sql: "UPDATE sessions SET hidden_at = datetime('now'), orphan_status = 'archive_pending' WHERE id = 'host'"
            )
            let result = try w.writeAuthoritativeSnapshot(child)

            XCTAssertEqual(result.action, .merge)
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'")
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'child'")
            )

            _ = try StartupBackfills.backfillParentLinks(db)
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"),
                "startup backfill must not reattach to a hidden/orphan host"
            )
        }
    }

    func testOpenCodeBackfillDoesNotWalkNestedForkIntoHiddenHost_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-hidden-nested-host-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, time_archived INTEGER);
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('fork', 'host', NULL);
                INSERT INTO session VALUES ('task', 'fork', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "fork",
                    source: .opencode,
                    hash: "fork",
                    parentSessionId: "host",
                    sourceLocator: "\(externalURL.path)::fork"
                )
            )
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "task",
                    source: .opencode,
                    hash: "task",
                    tier: .skip,
                    agentRole: "dispatched",
                    sourceLocator: "\(externalURL.path)::task"
                )
            )
            try db.execute(
                sql: "UPDATE sessions SET hidden_at = datetime('now'), orphan_status = 'archive_pending' WHERE id = 'host'"
            )
            try db.execute(
                sql: "UPDATE sessions SET parent_session_id = NULL, link_source = NULL WHERE id = 'task'"
            )

            XCTAssertEqual(try StartupBackfills.backfillParentLinks(db).linked, 0)
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'task'")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'task'"),
                "skip"
            )
        }
    }

    func testOpenCodeBackfillRejectsArchivedExternalHost_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-archived-parent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY,
                    parent_id TEXT,
                    time_archived INTEGER
                );
                INSERT INTO session VALUES ('host', NULL, 1);
                INSERT INTO session VALUES ('child', 'host', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "child",
                    source: .opencode,
                    hash: "child",
                    sourceLocator: "\(externalURL.path)::child"
                )
            )

            XCTAssertEqual(try StartupBackfills.backfillParentLinks(db).linked, 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"))
        }
    }

    func testOpenCodeReindexClearsNativePathParentWhenExternalParentBecomesNil_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-cleared-parent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY,
                    parent_id TEXT,
                    time_archived INTEGER
                );
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('child', 'host', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "child",
                    source: .opencode,
                    hash: "before",
                    parentSessionId: "host",
                    sourceLocator: "\(externalURL.path)::child"
                )
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"),
                "host"
            )

            try external.write { externalDB in
                try externalDB.execute(sql: "UPDATE session SET parent_id = NULL WHERE id = 'child'")
            }
            _ = try w.writeAuthoritativeSnapshot(
                snapshot(
                    id: "child",
                    source: .opencode,
                    hash: "after",
                    parentSessionId: nil,
                    sourceLocator: "\(externalURL.path)::child"
                )
            )

            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'child'"))
        }
    }

    func testOpenCodeReindexDropsPathParentWhenExternalHostBecomesArchived_repro() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-reindex-archived-parent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let external = try DatabaseQueue(path: externalURL.path)
        try external.write { db in
            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY,
                    parent_id TEXT,
                    time_archived INTEGER
                );
                INSERT INTO session VALUES ('host', NULL, NULL);
                INSERT INTO session VALUES ('child', 'host', NULL);
                """)
        }

        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "host", source: .opencode, hash: "host"))
            let child = snapshot(
                id: "child",
                source: .opencode,
                hash: "same",
                parentSessionId: "host",
                sourceLocator: "\(externalURL.path)::child"
            )
            _ = try w.writeAuthoritativeSnapshot(child)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"),
                "host"
            )

            try external.write { externalDB in
                try externalDB.execute(sql: "UPDATE session SET time_archived = 1 WHERE id = 'host'")
            }
            _ = try w.writeAuthoritativeSnapshot(child)

            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'child'"))
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
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "cc-parent"))
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

    /// R1/R2 P1 path-parent-unvalidated-no-reconcile: an adapter-provided
    /// parent is only authoritative after the writer proves a one-level,
    /// browseable relationship. Invalid candidates must leave the child top-level.
    func testPathParentWriteRejectsSelfDanglingNestedAndSkipParents_repro() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "root"))
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "skip-parent", tier: .skip))
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "nested-parent"))
            try db.execute(
                sql: "UPDATE sessions SET parent_session_id = 'root', link_source = 'path' WHERE id = 'nested-parent'"
            )

            for (child, parent) in [
                ("self-child", "self-child"),
                ("dangling-child", "missing-parent"),
                ("nested-child", "nested-parent"),
                ("skip-child", "skip-parent"),
            ] {
                _ = try w.writeAuthoritativeSnapshot(snapshot(id: child, parentSessionId: parent))
            }
            _ = try w.writeAuthoritativeSnapshot(snapshot(id: "valid-child", parentSessionId: "root"))

            for child in ["self-child", "dangling-child", "nested-child", "skip-child"] {
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT parent_session_id, link_source FROM sessions WHERE id = ?",
                    arguments: [child]
                )
                XCTAssertNil(row?["parent_session_id"] as String?, "\(child) must remain top-level")
                XCTAssertNil(row?["link_source"] as String?, "\(child) must not claim a path link")
            }
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'valid-child'"),
                "root"
            )

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(id: "valid-child", hash: "h2", parentSessionId: "missing-parent")
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'valid-child'"),
                "an invalid replacement candidate must clear a prior non-manual path link"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'valid-child'")
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

    // Audit WRITER-LOCATOR-001: same syncVersion/snapshotHash content with a
    // relocated sourceLocator must refresh sessions.source_locator and file_path.
    func testContentIdenticalMoveRefreshesLocator_repro() throws {
        try writer.write { db in
            let w = SessionSnapshotWriter(db: db)
            let oldLocator = "/tmp/old-location/session.jsonl"
            let newLocator = "/tmp/new-location/session.jsonl"

            _ = try w.writeAuthoritativeSnapshot(
                snapshot(id: "moved", hash: "same", sourceLocator: oldLocator)
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT source_locator FROM sessions WHERE id = 'moved'"),
                oldLocator
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT file_path FROM sessions WHERE id = 'moved'"),
                oldLocator
            )

            let result = try w.writeAuthoritativeSnapshot(
                snapshot(id: "moved", hash: "same", sourceLocator: newLocator)
            )
            XCTAssertEqual(result.action, .merge, "locator-only move must leave the no-op path")
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT source_locator FROM sessions WHERE id = 'moved'"),
                newLocator
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT file_path FROM sessions WHERE id = 'moved'"),
                newLocator
            )
        }
    }
}
