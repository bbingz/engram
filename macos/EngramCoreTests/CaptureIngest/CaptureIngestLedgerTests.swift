import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

final class CaptureIngestLedgerTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let journal = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    private let revision = "swift-parser-1"
    private var directory: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        writer = try EngramDatabaseWriter(path: directory.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testFreshAndRepeatedMigrationAddsEmptyLedgerWithoutSessionSideEffects() throws {
        try writer.migrate()
        try writer.migrate()
        let required: Set<String> = [
            "capture_ingest_publications", "capture_ingest_ledger",
            "capture_ingest_arrivals", "capture_ingest_checkpoints",
        ]
        let tables = try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        XCTAssertTrue(required.isSubset(of: tables), "missing durable ingest tables: \(required.subtracting(tables))")
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertEqual(try count("session_index_jobs"), 0)
        XCTAssertNil(try checkpoint())
    }

    func testAcceptedPagePersistsExactPublicationAndPendingWorkBeforeCheckpoint() throws {
        let record = try acceptance(sequence: 1, ordinal: 1)
        let page = try makePage([record])
        try accept(page)
        XCTAssertEqual(try checkpoint(), page.afterCursor)
        XCTAssertEqual(try entry(record)?.status, .pending)
        XCTAssertEqual(try entry(record)?.parserRevision, revision)
        XCTAssertNil(try entry(record)?.failureCode)
        XCTAssertEqual(try writer.read { try CaptureIngestLedger.publication($0, sha256: record.ack.publicationSHA256) }, record.publication)
        XCTAssertEqual(try count("sessions"), 0, "arrival does not create a read model")
        XCTAssertEqual(try count("session_index_jobs"), 0, "ACK does not mean parse or FTS ready")
        writer = nil
        writer = try EngramDatabaseWriter(path: directory.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
        XCTAssertEqual(try checkpoint(), page.afterCursor)
        XCTAssertEqual(try entry(record)?.status, .pending)
    }

    func testTwoReplicaArrivalsDeduplicateWorkWithoutConflatingCursors() throws {
        let record = try acceptance(sequence: 1, ordinal: 1)
        let replica = try acceptance(sequence: 1, ordinal: 9, server: "m1", journalID: epoch)
        let hqPage = try makePage([record])
        let m1Page = try makePage([replica])
        try accept(hqPage)
        try accept(m1Page, server: "m1")
        XCTAssertEqual(try checkpoint(), hqPage.afterCursor)
        XCTAssertEqual(try checkpoint(server: "m1"), m1Page.afterCursor)
        guard try requireSchema() else { return }
        XCTAssertEqual(try count("capture_ingest_publications"), 1)
        XCTAssertEqual(try count("capture_ingest_ledger"), 1)
        XCTAssertEqual(try count("capture_ingest_arrivals"), 2)
    }

    func testExactPageRetryDoesNotResetTerminalWork() throws {
        let record = try acceptance(sequence: 1, ordinal: 1)
        let page = try makePage([record])
        try accept(page)
        guard try requireSchema() else { return }
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_ledger SET status = 'quarantined', failure_code = 'parse_failed'")
        }
        try accept(page)
        XCTAssertEqual(try checkpoint(), page.afterCursor)
        XCTAssertEqual(try entry(record)?.status, .quarantined)
        XCTAssertEqual(try entry(record)?.failureCode, "parse_failed")
        XCTAssertEqual(try count("capture_ingest_ledger"), 1)
        XCTAssertEqual(try count("capture_ingest_arrivals"), 1)
    }

    func testDistinctParserRevisionGetsItsOwnWorkWithoutResettingOldRevision() throws {
        let record = try acceptance(sequence: 1, ordinal: 1)
        let page = try makePage([record])
        try accept(page)
        guard try requireSchema() else { return }
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET status = 'parsed'") }
        try accept(page, parser: "swift-parser-2")
        XCTAssertEqual(try entry(record)?.status, .parsed)
        XCTAssertEqual(try writer.read {
            try CaptureIngestLedger.entry($0, publicationSHA256: record.ack.publicationSHA256, parserRevision: "swift-parser-2")?.status
        }, .pending)
        XCTAssertEqual(try count("capture_ingest_ledger"), 2)
    }

    func testWrongReplicaAndStaleOrUnpersistedRequestedCursorCannotAdvance() throws {
        let record = try acceptance(sequence: 1, ordinal: 1)
        let page = try makePage([record])
        XCTAssertThrowsError(try accept(page, server: "m1"))
        let forged = try CollectorPublicationCursor(journalID: journal, afterArrivalOrdinal: 20).encoded()
        let future = try makePage([acceptance(sequence: 2, ordinal: 21)])
        XCTAssertThrowsError(try accept(future, requested: forged))
        XCTAssertNil(try checkpoint())
        try accept(page)
        let next = try makePage([acceptance(sequence: 2, ordinal: 2)])
        XCTAssertThrowsError(try accept(next))
        XCTAssertEqual(try checkpoint(), page.afterCursor)
        try accept(next, requested: page.afterCursor)
        XCTAssertEqual(try checkpoint(), next.afterCursor)
    }

    func testChangedJournalCannotSilentlyReplacePersistedNamespace() throws {
        let first = try makePage([acceptance(sequence: 1, ordinal: 1)])
        try accept(first)
        let reset = try makePage([acceptance(sequence: 2, ordinal: 1, journalID: epoch)])
        XCTAssertThrowsError(try accept(reset, requested: first.afterCursor))
        XCTAssertThrowsError(try accept(reset))
        XCTAssertEqual(try checkpoint(), first.afterCursor)
    }

    func testEmptyEofCursorRemainsReusableAndSeesLaterArrival() throws {
        let start = try CollectorPublicationCursor(journalID: journal, afterArrivalOrdinal: 0).encoded()
        let empty = try CollectorPublicationPage(items: [], afterCursor: start, hasMore: false)
        try accept(empty)
        try accept(empty, requested: start)
        XCTAssertEqual(try checkpoint(), start)
        let page = try makePage([acceptance(sequence: 1, ordinal: 1)])
        try accept(page, requested: start)
        XCTAssertEqual(try checkpoint(), page.afterCursor)
    }

    func testCheckpointFailureRollsBackEveryPublicationAndWorkRowEvenWhenCallerCatches() throws {
        guard try requireSchema() else { return }
        let page = try makePage([acceptance(sequence: 1, ordinal: 1), acceptance(sequence: 2, ordinal: 2)])
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER injected_checkpoint_failure BEFORE INSERT ON capture_ingest_checkpoints
                BEGIN SELECT RAISE(ABORT, 'injected checkpoint failure'); END
                """)
            XCTAssertThrowsError(try CaptureIngestLedger.accept(
                db, page: page, requestedCursor: nil, serverID: "hq", parserRevision: revision
            ))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_publications"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_ledger"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_arrivals"), 0)
            try db.execute(sql: "DROP TRIGGER injected_checkpoint_failure")
        }
        XCTAssertNil(try checkpoint())
        try accept(page)
        XCTAssertEqual(try checkpoint(), page.afterCursor)
        XCTAssertEqual(try count("capture_ingest_ledger"), 2)
    }

    func testCrossReplicaTupleConflictIsDurablyQuarantinedAndDoesNotRewritePriorGoodRecord() throws {
        let good = try acceptance(sequence: 1, ordinal: 1)
        try accept(makePage([good]))
        guard try requireSchema() else { return }
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET status = 'index_ready'") }
        let conflict = try acceptance(sequence: 1, ordinal: 1, server: "m1", journalID: epoch, digestCharacter: "e")
        let page = try makePage([conflict])
        try accept(page, server: "m1")
        XCTAssertEqual(try entry(good)?.status, .indexReady)
        XCTAssertEqual(try entry(conflict)?.status, .quarantined)
        XCTAssertEqual(try entry(conflict)?.failureCode, "sequence_conflict")
        XCTAssertEqual(try checkpoint(server: "m1"), page.afterCursor)
        XCTAssertEqual(try writer.read { try CaptureIngestLedger.publication($0, sha256: good.ack.publicationSHA256) }, good.publication)
    }

    func testCheckpointUpdateFailurePreservesPreviousCursorAndRollsBackNewWork() throws {
        guard try requireSchema() else { return }
        let first = try makePage([acceptance(sequence: 1, ordinal: 1)])
        try accept(first)
        let next = try makePage([acceptance(sequence: 2, ordinal: 2)])
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER injected_checkpoint_update_failure BEFORE UPDATE ON capture_ingest_checkpoints
                BEGIN SELECT RAISE(ABORT, 'injected checkpoint update failure'); END
                """)
            XCTAssertThrowsError(try CaptureIngestLedger.accept(
                db, page: next, requestedCursor: first.afterCursor, serverID: "hq", parserRevision: revision
            ))
            XCTAssertEqual(try CaptureIngestLedger.checkpoint(db, serverID: "hq"), first.afterCursor)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_publications"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_ledger"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_arrivals"), 1)
            try db.execute(sql: "DROP TRIGGER injected_checkpoint_update_failure")
        }
        try accept(next, requested: first.afterCursor)
        XCTAssertEqual(try checkpoint(), next.afterCursor)
    }

    func testConflictingPublicationCannotEscapeQuarantineThroughReplicaOrParserRevisionReplay() throws {
        let original = try acceptance(sequence: 1, ordinal: 1)
        try accept(makePage([original]))
        let conflict = try acceptance(sequence: 1, ordinal: 1, server: "m1", journalID: epoch, digestCharacter: "e")
        let conflictPage = try makePage([conflict])
        try accept(conflictPage, server: "m1")
        try accept(conflictPage, server: "m1", parser: "swift-parser-2")
        XCTAssertEqual(try entry(conflict)?.status, .quarantined)
        XCTAssertEqual(try writer.read {
            try CaptureIngestLedger.entry($0, publicationSHA256: conflict.ack.publicationSHA256, parserRevision: "swift-parser-2")?.status
        }, .quarantined)
        let retryOnHQ = try acceptance(sequence: 1, ordinal: 2, digestCharacter: "e")
        let current = try checkpoint()
        try accept(makePage([retryOnHQ]), requested: current)
        XCTAssertEqual(try entry(conflict)?.status, .quarantined)
        XCTAssertEqual(try entry(conflict)?.failureCode, "sequence_conflict")
    }

    func testReusedArrivalOrdinalWithAnotherPublicationCannotBeTreatedAsPageRetry() throws {
        let first = try makePage([acceptance(sequence: 1, ordinal: 1)])
        try accept(first)
        let changed = try makePage([acceptance(sequence: 2, ordinal: 1)])
        XCTAssertThrowsError(try accept(changed))
        XCTAssertEqual(try checkpoint(), first.afterCursor)
    }

    func testInvalidParserRevisionDoesNotAdvanceCheckpoint() throws {
        let page = try makePage([acceptance(sequence: 1, ordinal: 1)])
        for invalid in ["", " ", "x\0y", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try accept(page, parser: invalid)) {
                XCTAssertEqual($0 as? CaptureIngestLedgerError, .invalidParserRevision)
            }
        }
        XCTAssertNil(try checkpoint())
    }

    private func requireSchema(file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let exists = try writer.read { try $0.tableExists("capture_ingest_ledger") }
        XCTAssertTrue(exists, "ledger migration is required", file: file, line: line)
        return exists
    }

    private func count(_ table: String) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    private func checkpoint(server: String = "hq") throws -> String? {
        try writer.read { try CaptureIngestLedger.checkpoint($0, serverID: server) }
    }

    private func entry(_ record: CollectorPublicationAcceptanceRecord) throws -> CaptureIngestLedgerEntry? {
        try writer.read { try CaptureIngestLedger.entry($0, publicationSHA256: record.ack.publicationSHA256, parserRevision: revision) }
    }

    private func accept(
        _ page: CollectorPublicationPage, requested: String? = nil, server: String = "hq", parser: String? = nil
    ) throws {
        try writer.write { try CaptureIngestLedger.accept(
            $0, page: page, requestedCursor: requested, serverID: server, parserRevision: parser ?? revision
        ) }
    }

    private func makePage(_ records: [CollectorPublicationAcceptanceRecord]) throws -> CollectorPublicationPage {
        let last = records[records.count - 1].ack
        return try CollectorPublicationPage(items: records, afterCursor: CollectorPublicationCursor(
            journalID: last.journalID, afterArrivalOrdinal: last.arrivalOrdinal
        ).encoded(), hasMore: false)
    }

    private func acceptance(
        sequence: Int64, ordinal: Int64, server: String = "hq", journalID: String? = nil, digestCharacter: Character = "a"
    ) throws -> CollectorPublicationAcceptanceRecord {
        let publication = try CollectorPublicationEnvelope(
            machineID: machine, sourceInstanceID: instance, collectorEpoch: epoch,
            sequence: sequence, manifestSHA256: String(repeating: digestCharacter, count: 64)
        )
        let ack = try CollectorPublicationACK(
            serverID: server, journalID: journalID ?? journal, arrivalOrdinal: ordinal,
            publicationSHA256: publication.sha256(), manifestSHA256: publication.manifestSHA256,
            storedAt: "2026-09-05T12:00:00.000Z"
        )
        return try CollectorPublicationAcceptanceRecord(publication: publication, ack: ack)
    }
}
