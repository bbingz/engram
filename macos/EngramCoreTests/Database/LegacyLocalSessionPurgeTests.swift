import CryptoKit
import Foundation
@testable import EngramCoreRead
@testable import EngramCoreWrite
import GRDB
import XCTest

/// D7 (docs/TODO.md): legacy origin=local grok/pi rows on an index host are
/// removed only by the explicit operator purge; docs/invariants.md "Legacy
/// Local-Origin Purge Is An Explicit Operator Action".
final class LegacyLocalSessionPurgeTests: XCTestCase {
    private static let capturePeer = "capture-v1.AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA.BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private static let captureID = "remote:\(capturePeer):Z3Jvay1jYXB0dXJl"
    private static let untouchedIDs = [captureID, "grok-bound", "cc-local", "remote:hq:cGVlcg"]
    private static let candidateIDs = ["grok-a", "grok-b", "pi-a"]

    private var directory: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-local-purge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
        try writer.write { try Self.seed($0) }
    }

    override func tearDownWithError() throws {
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private var databasePath: String { directory.appendingPathComponent("index.sqlite").path }

    func testReportCountsLegacyGrokPiRowsAndDerivedRowsExcludingCaptureBound() throws {
        let report = try writer.read { try LegacyLocalSessionPurge.report($0) }
        XCTAssertEqual(report.predicateVersion, 1)
        XCTAssertEqual(report.sessionCount, 3)
        XCTAssertEqual(report.planToken, Self.expectedToken(Self.candidateIDs))
        XCTAssertEqual(report.sources.map(\.source), ["grok", "pi"])
        XCTAssertEqual(report.sources.map(\.sessions), [2, 1])
        XCTAssertEqual(report.sources.first?.newestIndexedAt, "2026-10-07 10:00:00")
        XCTAssertEqual(report.sources.first?.newestStartTime, "2026-10-06T00:00:00Z")
        XCTAssertEqual(report.derived, Self.expectedDerived)
        XCTAssertEqual(report.captureBoundExcluded, 1)
        XCTAssertEqual(report.otherLocalOriginSessions, ["claude-code": 1])
        XCTAssertEqual(Set(report.blocking.keys), Set(LegacyLocalSessionPurge.blockingKeys))
        XCTAssertTrue(report.blocking.values.allSatisfy { $0 == 0 }, "\(report.blocking)")
        XCTAssertEqual(report.retained, ["fileIndexState": 1, "aiAuditLog": 0])
        XCTAssertTrue(report.purgeAllowed)
    }

    func testReportFlagsEveryUserStateDependentAsBlocking() throws {
        let seeds: [(key: String, sql: String)] = [
            ("sessionLocalState", "INSERT INTO session_local_state(session_id, hidden_at) VALUES ('grok-a', NULL)"),
            ("rowCustomName", "UPDATE sessions SET custom_name = 'Mine' WHERE id = 'grok-a'"),
            ("rowHidden", "UPDATE sessions SET hidden_at = '2026-10-01' WHERE id = 'grok-a'"),
            ("manualLinks", "UPDATE sessions SET link_source = 'manual' WHERE id = 'grok-a'"),
            ("externalConfirmedChildren", "UPDATE sessions SET parent_session_id = 'grok-a' WHERE id = 'cc-local'"),
            ("externalSuggestedChildren", "UPDATE sessions SET suggested_parent_id = 'grok-a' WHERE id = 'cc-local'"),
            ("sessionRelations", "INSERT INTO session_relations(a_id, b_id) VALUES ('cc-local', 'grok-a')"),
            ("favorites", """
                CREATE TABLE IF NOT EXISTS favorites (session_id TEXT PRIMARY KEY, created_at TEXT NOT NULL DEFAULT (datetime('now')));
                INSERT INTO favorites(session_id) VALUES ('grok-a')
                """),
            ("tags", """
                CREATE TABLE IF NOT EXISTS tags (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, tag TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')), UNIQUE(session_id, tag));
                INSERT INTO tags(session_id, tag) VALUES ('pi-a', 'keep')
                """),
            ("insights", "INSERT INTO insights(id, content, source_session_id) VALUES ('i1', 'remember this', 'grok-b')"),
            ("memoryInsights", "INSERT INTO memory_insights(id, content, source_session_id) VALUES ('m1', 'remember this', 'pi-a')"),
            ("offloaded", "UPDATE sessions SET offload_state = 'offloaded' WHERE id = 'grok-b'"),
        ]
        XCTAssertEqual(seeds.map(\.key), LegacyLocalSessionPurge.blockingKeys)
        for seed in seeds {
            try writer.write { db in
                try db.inSavepoint {
                    try db.execute(sql: seed.sql)
                    let report = try LegacyLocalSessionPurge.report(db)
                    XCTAssertEqual(report.blocking[seed.key], 1, seed.key)
                    XCTAssertEqual(report.blocking.filter { $0.value != 0 }.count, 1, "\(seed.key): \(report.blocking)")
                    XCTAssertFalse(report.purgeAllowed, seed.key)
                    XCTAssertEqual(report.sessionCount, 3, seed.key)
                    return .rollback
                }
            }
        }
        // A child whose parent is also a candidate is not an outside dependent.
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET parent_session_id = 'grok-a', suggested_parent_id = 'grok-a' WHERE id = 'grok-b'")
            let report = try LegacyLocalSessionPurge.report(db)
            XCTAssertEqual(report.blocking["externalConfirmedChildren"], 0)
            XCTAssertEqual(report.blocking["externalSuggestedChildren"], 0)
            XCTAssertTrue(report.purgeAllowed)
        }
    }

    func testPurgeRefusesWithUserStateDependentsAndChangesNothing() throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO insights(id, content, source_session_id) VALUES ('i1', 'remember this', 'grok-a')")
        }
        let report = try writer.read { try LegacyLocalSessionPurge.report($0) }
        let before = try tableCounts()
        XCTAssertThrowsError(try writer.write { db in
            try LegacyLocalSessionPurge.purge(
                db,
                expectedSessionCount: report.sessionCount,
                expectedPlanToken: report.planToken,
                purgedAt: "2026-10-18T00:00:00Z"
            )
        }) { error in
            XCTAssertEqual(error as? LegacyLocalSessionPurge.PurgeError, .blockingDependents(["insights": 1]))
        }
        XCTAssertEqual(try tableCounts(), before)
        XCTAssertEqual(try auditRows().count, 0)
    }

    func testPurgeRefusesChangedPlan() throws {
        let report = try writer.read { try LegacyLocalSessionPurge.report($0) }
        let before = try tableCounts()
        let wrongToken = String(repeating: "0", count: 64)
        for (count, token) in [(report.sessionCount, wrongToken), (report.sessionCount + 1, report.planToken)] {
            XCTAssertThrowsError(try writer.write { db in
                try LegacyLocalSessionPurge.purge(db, expectedSessionCount: count, expectedPlanToken: token, purgedAt: "t")
            }) { error in
                XCTAssertEqual(
                    error as? LegacyLocalSessionPurge.PurgeError,
                    .planChanged(sessionCount: report.sessionCount, planToken: report.planToken)
                )
            }
        }
        XCTAssertEqual(try tableCounts(), before)

        try writer.write { db in try Self.insertSession(db, id: "grok-c", source: "grok", origin: "local", authority: "local") }
        let grown = try writer.read { try LegacyLocalSessionPurge.report($0) }
        XCTAssertThrowsError(try writer.write { db in
            try LegacyLocalSessionPurge.purge(
                db, expectedSessionCount: report.sessionCount, expectedPlanToken: report.planToken, purgedAt: "t"
            )
        }) { error in
            XCTAssertEqual(
                error as? LegacyLocalSessionPurge.PurgeError,
                .planChanged(sessionCount: 4, planToken: grown.planToken)
            )
        }
        XCTAssertEqual(grown.planToken, Self.expectedToken(["grok-a", "grok-b", "grok-c", "pi-a"]))
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions") }, 8)

        XCTAssertThrowsError(try writer.writeWithoutTransaction { db in
            try LegacyLocalSessionPurge.purge(
                db, expectedSessionCount: grown.sessionCount, expectedPlanToken: grown.planToken, purgedAt: "t"
            )
        }) { error in
            XCTAssertEqual(error as? LegacyLocalSessionPurge.PurgeError, .notInTransaction)
        }
        XCTAssertEqual(try writer.read { try LegacyLocalSessionPurge.report($0) }.sessionCount, 4)
    }

    /// D7 repro: the HQ index held legacy origin=local grok/pi rows next to
    /// their capture copies with no tool to remove them; the purge removes
    /// exactly those rows and their derived rows and nothing capture-bound.
    func testPurgeClearsLegacyRowsAndDerivedRowsLeavingCaptureRowsUntouched_repro() throws {
        let report = try writer.read { try LegacyLocalSessionPurge.report($0) }
        let untouchedBefore = try untouchedSnapshot()
        let captureFTSBefore = try ftsRows(Self.captureID)
        let result = try writer.write { db in
            try LegacyLocalSessionPurge.purge(
                db,
                expectedSessionCount: report.sessionCount,
                expectedPlanToken: report.planToken,
                purgedAt: "2026-10-18T01:02:03Z"
            )
        }
        XCTAssertEqual(result.sessionsDeleted, 3)
        XCTAssertEqual(result.deleted, Self.expectedDerived)
        XCTAssertEqual(result.planToken, report.planToken)
        XCTAssertEqual(result.auditKey, "legacy_local_purge.v1.2026-10-18T01:02:03Z")

        try writer.read { db in
            let placeholders = Self.candidateIDs.map { "'\($0)'" }.joined(separator: ",")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id IN (\(placeholders))"), 0)
            for entry in LegacyLocalSessionPurge.derivedTables {
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = ?)", arguments: [entry.table]
                ) ?? false
                guard exists else { continue }
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(entry.table) WHERE session_id IN (\(placeholders))"),
                    0,
                    entry.table
                )
            }
            // file_index_state is scan-cursor state and is reported, never deleted.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_index_state"), 1)
        }
        XCTAssertEqual(try untouchedSnapshot(), untouchedBefore)
        XCTAssertEqual(try ftsRows(Self.captureID), captureFTSBefore)
        XCTAssertFalse(captureFTSBefore.isEmpty)

        let audits = try auditRows()
        XCTAssertEqual(audits.map(\.key), [result.auditKey])
        let audit = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(audits.first?.value).utf8)) as? [String: Any]
        )
        XCTAssertEqual(audit["planToken"] as? String, report.planToken)
        XCTAssertEqual(audit["sessionCount"] as? Int, 3)
        XCTAssertEqual(audit["predicateVersion"] as? Int, 1)
        XCTAssertEqual(audit["deleted"] as? [String: Int], Self.expectedDerived)

        let after = try writer.read { try LegacyLocalSessionPurge.report($0) }
        XCTAssertEqual(after.sessionCount, 0)
        XCTAssertFalse(after.purgeAllowed)
        XCTAssertThrowsError(try writer.write { db in
            try LegacyLocalSessionPurge.purge(
                db, expectedSessionCount: 3, expectedPlanToken: report.planToken, purgedAt: "2026-10-18T01:02:04Z"
            )
        }) { error in
            XCTAssertEqual(
                error as? LegacyLocalSessionPurge.PurgeError,
                .planChanged(sessionCount: 0, planToken: Self.expectedToken([]))
            )
        }
    }

    func testReportRunsOnReadOnlyConnection() throws {
        let expected = try writer.read { try LegacyLocalSessionPurge.report($0) }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databasePath, configuration: configuration)
        let report = try queue.read { try LegacyLocalSessionPurge.report($0) }
        try queue.close()
        XCTAssertEqual(report, expected)
    }

    // MARK: - Fixture

    static let expectedDerived: [String: Int] = [
        "messages": 0,
        "sessionsFts": 4,
        "sessionsFtsRebuild": 0,
        "ftsMap": 2,
        "sessionEmbeddings": 0,
        "semanticChunks": 1,
        "sessionIndexJobs": 2,
        "sessionCosts": 1,
        "sessionTools": 2,
        "sessionWorkBeats": 0,
        "sessionFiles": 1,
        "offloadQueue": 0,
        "rehydrateQueue": 0,
        "syncLedger": 1,
    ]

    static func expectedToken(_ ids: [String]) -> String {
        let bytes = Data(("engram-legacy-local-purge-v1\n" + ids.map { $0 + "\n" }.joined()).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func insertSession(
        _ db: Database,
        id: String,
        source: String,
        origin: String?,
        authority: String?,
        indexedAt: String = "2026-09-01 00:00:00",
        startTime: String = "2026-09-01T00:00:00Z"
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sessions(id, source, start_time, file_path, indexed_at, origin, authoritative_node)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, source, startTime, "/fixture/\(source)/\(id).jsonl", indexedAt, origin, authority]
        )
    }

    static func seed(_ db: Database) throws {
        try insertSession(
            db, id: "grok-a", source: "grok", origin: "local", authority: "local",
            indexedAt: "2026-10-07 10:00:00", startTime: "2026-10-06T00:00:00Z"
        )
        try insertSession(db, id: "grok-b", source: "grok", origin: nil, authority: nil)
        try insertSession(db, id: "pi-a", source: "pi", origin: " ", authority: "")
        try insertSession(db, id: "cc-local", source: "claude-code", origin: "local", authority: "local")
        try insertSession(db, id: captureID, source: "grok", origin: capturePeer, authority: capturePeer)
        try insertSession(db, id: "grok-bound", source: "grok", origin: "local", authority: "local")
        try insertSession(db, id: "remote:hq:cGVlcg", source: "grok", origin: "hq", authority: "hq")
        for (index, sessionID) in [captureID, "grok-bound"].enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO capture_ingest_identity_bindings(
                      machine_id, source_instance_id, source, native_id, stored_session_id
                    ) VALUES ('M', 'I', 'grok', ?, ?)
                    """,
                arguments: ["native-\(index)", sessionID]
            )
        }
        for (sessionID, content) in [
            ("grok-a", "legacy a one"), ("grok-a", "legacy a two"), ("grok-b", "legacy b"),
            ("pi-a", "legacy pi"), (captureID, "capture copy"), ("grok-bound", "bound copy"),
        ] {
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                arguments: [sessionID, content]
            )
        }
        try db.execute(sql: """
            INSERT INTO fts_map(session_id, msg_seq, fts_rowid) VALUES ('grok-a', 0, 1), ('pi-a', 0, 4), ('\(captureID)', 0, 5);
            INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
              VALUES ('j1', 'grok-a', 'fts', 1, 'pending'), ('j2', 'pi-a', 'fts', 1, 'completed'),
                     ('j3', '\(captureID)', 'fts', 1, 'completed');
            INSERT INTO session_costs(session_id, model) VALUES ('grok-a', 'grok-4'), ('\(captureID)', 'grok-4');
            INSERT INTO session_tools(session_id, tool_name, call_count) VALUES ('grok-a', 'bash', 2), ('grok-b', 'read', 1);
            INSERT INTO session_files(session_id, file_path, action) VALUES ('pi-a', '/x', 'read');
            INSERT INTO semantic_chunks(id, session_id, chunk_index, text) VALUES ('c1', 'grok-b', 0, 'chunk');
            INSERT INTO sync_ledger(session_id, direction) VALUES ('grok-a', 'out');
            INSERT INTO file_index_state(source, locator, size_bytes, mtime_ns, parse_status, schema_version, updated_at)
              VALUES ('grok', '/fixture/grok/grok-a.jsonl', 1, 1, 'ok', 1, 1);
            """)
    }

    private func tableCounts() throws -> [String: Int] {
        try writer.read { db in
            var counts: [String: Int] = [:]
            for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            }
            return counts
        }
    }

    private func untouchedSnapshot() throws -> [String] {
        try writer.read { db in
            let ids = Self.untouchedIDs.map { "'\($0)'" }.joined(separator: ",")
            let sessions = try Row.fetchAll(db, sql: "SELECT * FROM sessions WHERE id IN (\(ids)) ORDER BY id")
            let bindings = try Row.fetchAll(db, sql: "SELECT * FROM capture_ingest_identity_bindings ORDER BY native_id")
            let derived = try Row.fetchAll(db, sql: """
                SELECT 'jobs', id, session_id FROM session_index_jobs WHERE session_id IN (\(ids))
                UNION ALL SELECT 'costs', model, session_id FROM session_costs WHERE session_id IN (\(ids))
                UNION ALL SELECT 'map', fts_rowid, session_id FROM fts_map WHERE session_id IN (\(ids))
                ORDER BY 1, 2
                """)
            XCTAssertEqual(sessions.count, Self.untouchedIDs.count)
            XCTAssertEqual(bindings.count, 2)
            return (sessions + bindings + derived).map { $0.description }
        }
    }

    private func ftsRows(_ sessionID: String) throws -> [String] {
        try writer.read {
            try String.fetchAll($0, sql: "SELECT content FROM sessions_fts WHERE session_id = ? ORDER BY rowid", arguments: [sessionID])
        }
    }

    private func auditRows() throws -> [(key: String, value: String)] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT key, value FROM metadata WHERE key LIKE 'legacy_local_purge.%' ORDER BY key"
            ).map { ($0["key"], $0["value"]) }
        }
    }
}
