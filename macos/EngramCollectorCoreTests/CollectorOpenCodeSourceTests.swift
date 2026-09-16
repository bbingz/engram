import Darwin
import Foundation
import GRDB
import SQLite3
import XCTest
@testable import EngramCollectorCore

final class CollectorOpenCodeSourceTests: XCTestCase {
    func testLeaseRejectsDeadlineOverflowWithoutOpeningSQLite() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        var opened = false
        XCTAssertThrowsError(try fixture.snapshot(
            budget: .init(maximumLeaseMilliseconds: Int(UInt64.max / 1_000_000)),
            testHooks: .init(willOpenSQLite: { _ in opened = true }))) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .exceededBudget)
        }
        XCTAssertFalse(opened)
    }

    func testLeaseSQLBudgetIsSharedAcrossRepeatedPages() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        var completed = 0
        XCTAssertThrowsError(try CollectorOpenCodeSource.withSnapshotLease(
            root: fixture.root, stagingParent: fixture.staging,
            budget: .init(maximumSQLiteSteps: 2_000)
        ) { lease in
            for _ in 0..<200 {
                let page = try lease.sessionIDs(limit: 1)
                XCTAssertEqual(page, ["ses-one"])
                completed += 1
            }
        }) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .exceededBudget)
        }
        XCTAssertGreaterThan(completed, 0, "a single bounded page fits the lease budget")
        XCTAssertLessThan(completed, 200, "repeated calls cannot reset the aggregate VM budget")
    }

    func testSealedLeaseSurvivesOriginalSourceRemoval() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        try CollectorOpenCodeSource.withSnapshotLease(root: fixture.root, stagingParent: fixture.staging) { lease in
            let first = try lease.snapshot(sessionID: "ses-one")
            fixture.stopWriter()
            try FileManager.default.removeItem(at: fixture.root)
            XCTAssertEqual(try lease.sessionIDs(), ["ses-one", "ses-private"])
            XCTAssertEqual(try lease.snapshot(sessionID: "ses-one").image, first.image)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testForcedStreamingCopiesSourcePairOnceWithinItsBudget() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let originals = try fixture.sourceBytes()
        let total = originals.values.reduce(Int64(0)) { $0 + Int64($1.count) }
        var copied: Int64 = 0
        var stages = 0
        try CollectorOpenCodeSource.withSnapshotLease(root: fixture.root, stagingParent: fixture.staging,
            budget: .init(maximumCopyByteCount: total),
            testHooks: .init(didStageSourceFile: { _, cloned, bytes in
                XCTAssertFalse(cloned)
                copied += bytes
                stages += 1
            }, forceStreamingCopy: true)) { lease in
            _ = try lease.snapshot(sessionID: "ses-one")
            _ = try lease.snapshot(sessionID: "ses-private")
        }
        XCTAssertEqual(stages, 2)
        XCTAssertEqual(copied, total)
        XCTAssertEqual(try fixture.sourceBytes(), originals)
    }

    func testStagingAncestorAliasBeforeSQLiteOpenIsRejectedAndCleanupUsesOwnedFD() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let moved = fixture.base.appendingPathComponent("moved-staging")
        XCTAssertThrowsError(try fixture.snapshot(testHooks: .init(willOpenSQLite: { _ in
            try FileManager.default.moveItem(at: fixture.staging, to: moved)
            try FileManager.default.createSymbolicLink(at: fixture.staging, withDestinationURL: moved)
        }))) {
            let error = $0 as? CollectorOpenCodeSourceError
            XCTAssertTrue(error == .unsafePath || error == .sourceChanged)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testSQLiteOnlyOpensPrivateImagesAndLeavesSourceSHMUnchanged() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let shm = URL(fileURLWithPath: fixture.database.path + "-shm")
        let before = try Data(contentsOf: shm)
        var opened: [URL] = []
        _ = try fixture.snapshot(testHooks: .init(willOpenSQLite: { opened.append($0) }))
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(try XCTUnwrap(opened.first).path.hasPrefix(fixture.staging.path + "/"),
            "native SQLite must never open a source path after an lstat-only sidecar check")
        XCTAssertEqual(try Data(contentsOf: shm), before)
    }

    func testOnePrivateLeasePagesAndExportsMultipleSessionsWithoutRestaging() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        var staged: [String] = []
        var sqliteOpens = 0
        try CollectorOpenCodeSource.withSnapshotLease(root: fixture.root, stagingParent: fixture.staging,
            testHooks: .init(willOpenSQLite: { _ in sqliteOpens += 1 },
                didStageSourceFile: { name, _, _ in staged.append(name) })) { lease in
            let first = try lease.sessionIDs(limit: 1)
            XCTAssertEqual(first, ["ses-one"])
            XCTAssertEqual(try lease.sessionIDs(after: first[0], limit: 1), ["ses-private"])
            XCTAssertEqual(try lease.sessionIDs(after: "ses-private", limit: 1), [])
            let image = try lease.snapshot(sessionID: "ses-one")
            let other = try lease.snapshot(sessionID: "ses-private")
            XCTAssertNil(image.image.range(of: Data("EXCLUDED-SIBLING-PRIVATE".utf8)))
            XCTAssertNotNil(other.image.range(of: Data("EXCLUDED-SIBLING-PRIVATE".utf8)))
            XCTAssertEqual(try lease.snapshot(sessionID: "ses-one").image, image.image)
            XCTAssertEqual(staged.sorted(), ["opencode.db", "opencode.db-wal"])
            XCTAssertEqual(sqliteOpens, 1)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testLeaseKeepsItsCommittedGenerationWhileSourceWriterAdvances() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        try CollectorOpenCodeSource.withSnapshotLease(root: fixture.root, stagingParent: fixture.staging) { lease in
            let initial = try lease.snapshot(sessionID: "ses-one")
            try fixture.sql("UPDATE part SET data='{\"type\":\"text\",\"text\":\"after lease\"}' WHERE id='p-answer'")
            XCTAssertEqual(try lease.snapshot(sessionID: "ses-one").image, initial.image)
        }
        let latest = try fixture.snapshot()
        let replay = try fixture.replay(latest.image)
        XCTAssertEqual(try replay.read { try String.fetchOne($0, sql: "SELECT data FROM part WHERE id='p-answer'") },
            "{\"type\":\"text\",\"text\":\"after lease\"}")
    }

    func testEscapedLeaseCannotReadAfterScopeCleanup() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let escaped = try CollectorOpenCodeSource.withSnapshotLease(root: fixture.root, stagingParent: fixture.staging) { $0 }
        XCTAssertThrowsError(try escaped.sessionIDs())
        XCTAssertThrowsError(try escaped.snapshot(sessionID: "ses-one"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testStreamingFallbackHonorsCopyBudgetBeforeOpeningSQLite() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        var sqliteOpened = false
        XCTAssertThrowsError(try CollectorOpenCodeSource.withSnapshotLease(root: fixture.root, stagingParent: fixture.staging,
            budget: .init(maximumCopyByteCount: 1),
            testHooks: .init(willOpenSQLite: { _ in sqliteOpened = true }, forceStreamingCopy: true)) { _ in }) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .exceededBudget)
        }
        XCTAssertFalse(sqliteOpened)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testWALOnlySessionExportPreservesTypedRowsAndExcludesSiblingBytes() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let original = try fixture.sourceBytes()
        XCTAssertEqual(original[""], fixture.checkpointedMain)
        XCTAssertGreaterThan(try XCTUnwrap(original["-wal"]).count, 32)
        let snapshot = try fixture.snapshot()
        XCTAssertEqual(snapshot.sessionID, "ses-one")
        XCTAssertEqual(snapshot.cwd, "/offline/project-one")
        XCTAssertEqual(snapshot.databaseGeneration.size, Int64(fixture.checkpointedMain.count))
        XCTAssertNotNil(snapshot.walGeneration)
        XCTAssertNil(snapshot.image.range(of: Data("EXCLUDED-SIBLING-PRIVATE".utf8)))
        XCTAssertEqual(try fixture.sourceBytes(), original, "source main/WAL must not be rewritten")
        let replay = try fixture.replay(snapshot.image)
        try replay.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT id FROM session"), ["ses-one"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM part"), 3)
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM session"))
            XCTAssertEqual(row["big_integer"] as Int64, 9_007_199_254_740_993)
            XCTAssertEqual(row["opaque"] as Data, Data([0, 255, 1, 0]))
            XCTAssertEqual(row["fraction"] as Double, 1.25)
            XCTAssertNil(row["nullable"] as String?)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT CAST(raw_text AS BLOB) FROM session"), Data([65, 0, 66]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT data FROM part WHERE id='p-question'"), fixture.question)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT data FROM part WHERE id='p-tool'"), fixture.tool)
            let bytes = try Int64.fetchOne(db, sql: """
                SELECT (SELECT sum(length(CAST(data AS BLOB))) FROM message)
                     + (SELECT sum(length(CAST(data AS BLOB))) FROM part)
                """)
            XCTAssertEqual(snapshot.nativePayloadByteCount, bytes)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testConcurrentWriterCannotMixSessionAndMessageGenerations() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        var hookRan = false
        let snapshot = try fixture.snapshot(testHooks: .init(afterSessionRead: {
            hookRan = true
            try fixture.sql("""
                BEGIN;
                UPDATE session SET title='new title', time_updated=200 WHERE id='ses-one';
                UPDATE part SET data='{"type":"text","text":"new answer"}' WHERE id='p-answer';
                COMMIT;
                """)
        }))
        XCTAssertTrue(hookRan)
        let replay = try fixture.replay(snapshot.image)
        try replay.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT title FROM session"), "old title")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT data FROM part WHERE id='p-answer'"), fixture.answer)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.database), fixture.checkpointedMain)
    }

    func testRepeatedExportIsStableAndIndependentOfSiblingCommit() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let first = try fixture.snapshot()
        try fixture.sql("UPDATE session SET title='changed sibling' WHERE id='ses-private'")
        let second = try fixture.snapshot()
        XCTAssertEqual(first.image, second.image, "unrelated sessions must not change the scoped artifact")
        XCTAssertEqual(first.nativePayloadByteCount, second.nativePayloadByteCount)
    }

    func testByteAndRowBudgetsRejectInsteadOfReturningPartialImage() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        for budget in [CollectorOpenCodeSource.Budget(maximumByteCount: 10),
                       CollectorOpenCodeSource.Budget(maximumRows: 2)] {
            XCTAssertThrowsError(try fixture.snapshot(budget: budget)) {
                XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .exceededBudget)
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testMissingOrArchivedSessionNeverExportsSiblingRows() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        XCTAssertThrowsError(try fixture.snapshot(sessionID: "missing")) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .missingSession)
        }
        try fixture.sql("UPDATE session SET time_archived=300 WHERE id='ses-one'")
        XCTAssertThrowsError(try fixture.snapshot()) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .missingSession)
        }
    }

    func testOfflineWALWithoutSHMIsReadWithoutCreatingSourceSidecars() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let saved = try fixture.sourceBytes()
        try fixture.restoreOfflineWAL(saved)
        let beforeNames = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        XCTAssertFalse(beforeNames.contains("opencode.db-shm"))
        let snapshot = try fixture.snapshot()
        let replay = try fixture.replay(snapshot.image)
        XCTAssertEqual(try replay.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM part") }, 3)
        XCTAssertEqual(try fixture.sourceBytes(), saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted(), beforeNames)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testSQLiteStepBudgetAndCancellationTerminateWithoutAnImage() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        XCTAssertThrowsError(try fixture.snapshot(budget: .init(maximumSQLiteSteps: 1))) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .exceededBudget)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.snapshot()
        }
        do { _ = try await task.value; XCTFail("cancelled collection must not produce an image") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testOfflineSnapshotHonorsImageByteBudgetWithoutSourceSidecars() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let saved = try fixture.sourceBytes()
        try fixture.restoreOfflineWAL(saved)
        XCTAssertThrowsError(try fixture.snapshot(budget: .init(maximumByteCount: 1))) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .exceededBudget)
        }
        XCTAssertEqual(try fixture.sourceBytes(), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.database.path + "-shm"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testUnsafeSessionIdentityAndLinkedWALAreRejected() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        for identity in ["", "ses-one\0tail"] {
            XCTAssertThrowsError(try fixture.snapshot(sessionID: identity)) {
                XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .invalidSession)
            }
        }
        let saved = try fixture.sourceBytes()
        fixture.stopWriter()
        try fixture.removeOwnedSidecars()
        try XCTUnwrap(saved[""]).write(to: fixture.database)
        let victim = fixture.base.appendingPathComponent("wal-victim")
        try XCTUnwrap(saved["-wal"]).write(to: victim)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: fixture.database.path + "-wal"),
            withDestinationURL: victim)
        XCTAssertThrowsError(try fixture.snapshot()) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .unsafePath)
        }
        XCTAssertEqual(try Data(contentsOf: victim), saved["-wal"])
    }

    func testSymlinkDatabaseAndSymlinkRootAreRejectedWithoutOpeningTarget() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let linkedRoot = fixture.base.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.root)
        XCTAssertThrowsError(try CollectorOpenCodeSource.snapshot(root: linkedRoot,
            sessionID: "ses-one", stagingParent: fixture.staging)) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .unsafePath)
        }
        let otherRoot = fixture.base.appendingPathComponent("other-root")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: otherRoot.appendingPathComponent("opencode.db"),
            withDestinationURL: fixture.database)
        XCTAssertThrowsError(try CollectorOpenCodeSource.snapshot(root: otherRoot,
            sessionID: "ses-one", stagingParent: fixture.staging)) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .unsafePath)
        }
    }

    func testSymlinkAncestorIsRejectedEvenWhenFinalRootIsARealDirectory() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        let alias = fixture.base.appendingPathComponent("ancestor-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.base)
        let throughAlias = alias.appendingPathComponent("source")
        XCTAssertThrowsError(try CollectorOpenCodeSource.snapshot(root: throughAlias,
            sessionID: "ses-one", stagingParent: fixture.staging)) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .unsafePath)
        }
    }

    func testRemovedSourceNameBeforeSealDoesNotYieldAnUnboundImage() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        XCTAssertThrowsError(try fixture.snapshot(testHooks: .init(afterSourceDescriptorsOpened: {
            try FileManager.default.moveItem(at: fixture.database,
                to: fixture.root.appendingPathComponent("replaced-original.db"))
        }))) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .sourceChanged)
        }
    }

    func testOversizedUnparsedColumnIsRejectedBeforeReadingMessageRows() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        try fixture.sql("UPDATE session SET opaque=zeroblob(262144) WHERE id='ses-one'")
        var readPastSession = false
        XCTAssertThrowsError(try fixture.snapshot(budget: .init(maximumByteCount: 32768),
            testHooks: .init(afterSessionRead: { readPastSession = true }))) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .exceededBudget)
        }
        XCTAssertFalse(readPastSession, "the byte budget must fence raw columns before retaining subsequent rows")
    }

    func testEmptyTextAndBlobRetainTheirStorageTypes() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        try fixture.sql("UPDATE session SET raw_text='', opaque=X'' WHERE id='ses-one'")
        let replay = try fixture.replay(fixture.snapshot().image)
        try replay.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT typeof(raw_text) FROM session"), "text")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT typeof(opaque) FROM session"), "blob")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT length(raw_text) FROM session"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT length(opaque) FROM session"), 0)
        }
    }

    func testPrivateCopyFencesWALAbsenceAsPartOfItsGeneration() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        fixture.stopWriter()
        try fixture.removeOwnedSidecars()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.database.path + "-wal"))
        var concurrent: OpaquePointer?
        defer { if let concurrent { sqlite3_close(concurrent) } }
        XCTAssertThrowsError(try fixture.snapshot(testHooks: .init(afterPrivateMainCopy: {
            guard sqlite3_open(fixture.database.path, &concurrent) == SQLITE_OK,
                  sqlite3_exec(concurrent, "PRAGMA journal_mode=WAL; UPDATE session SET title='new WAL generation' WHERE id='ses-one'",
                    nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
        }))) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .sourceChanged)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testRootReplacedBySymlinkBeforeSealIsRejected() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        XCTAssertThrowsError(try fixture.snapshot(testHooks: .init(afterSourceDescriptorsOpened: {
            let moved = fixture.base.appendingPathComponent("moved-source")
            try FileManager.default.moveItem(at: fixture.root, to: moved)
            try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: moved)
        }))) {
            let error = $0 as? CollectorOpenCodeSourceError
            XCTAssertTrue(error == .sourceChanged || error == .unsafePath)
        }
    }

    func testNamedPipeDatabaseIsRejectedWithoutWaitingForAWriter() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        fixture.stopWriter()
        try FileManager.default.removeItem(at: fixture.database)
        XCTAssertEqual(mkfifo(fixture.database.path, 0o600), 0)
        XCTAssertThrowsError(try fixture.snapshot()) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .unsafePath)
        }
    }

    func testCheckpointedDatabaseWithoutSidecarsExportsWithoutSourceWrites() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        try fixture.sql("PRAGMA wal_checkpoint(TRUNCATE)")
        fixture.stopWriter()
        try fixture.removeOwnedSidecars()
        let original = try Data(contentsOf: fixture.database)
        let snapshot = try fixture.snapshot()
        let replay = try fixture.replay(snapshot.image)
        XCTAssertEqual(try replay.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM part") }, 3)
        XCTAssertNil(snapshot.walGeneration)
        XCTAssertEqual(try Data(contentsOf: fixture.database), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["opencode.db"])
    }

    func testOfflineSourceAlsoRejectsRootAliasReplacementBeforeSeal() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        try fixture.restoreOfflineWAL(fixture.sourceBytes())
        XCTAssertThrowsError(try fixture.snapshot(testHooks: .init(afterSourceDescriptorsOpened: {
            let moved = fixture.base.appendingPathComponent("moved-offline-source")
            try FileManager.default.moveItem(at: fixture.root, to: moved)
            try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: moved)
        }))) {
            let error = $0 as? CollectorOpenCodeSourceError
            XCTAssertTrue(error == .sourceChanged || error == .unsafePath)
        }
    }

    func testHotRollbackJournalIsRefusedWithoutRecoveryOrUncommittedExport() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.close() }
        try fixture.sql("""
            PRAGMA journal_mode=DELETE;
            PRAGMA cache_size=1;
            BEGIN IMMEDIATE;
            UPDATE session SET title='uncommitted private change', opaque=zeroblob(262144) WHERE id='ses-one';
            """)
        try fixture.flushSource()
        let main = try Data(contentsOf: fixture.database)
        let journal = URL(fileURLWithPath: fixture.database.path + "-journal")
        let journalBytes = try Data(contentsOf: journal)
        XCTAssertGreaterThan(journalBytes.count, 512)
        XCTAssertThrowsError(try fixture.snapshot()) {
            XCTAssertEqual($0 as? CollectorOpenCodeSourceError, .unsafePath)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.database), main)
        XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
        try fixture.sql("ROLLBACK")
    }
}

private final class OpenCodeFixture {
    let base: URL
    let root: URL
    let staging: URL
    var database: URL { root.appendingPathComponent("opencode.db") }
    private var writer: OpaquePointer?
    private(set) var checkpointedMain = Data()
    let question = "{ \"type\" : \"text\", \"text\" : \"原始问题\" }"
    let answer = "{\"type\":\"text\",\"text\":\"old answer\"}"
    let tool = "{\"type\":\"tool\",\"tool\":\"read\",\"state\":{\"input\":\"retain raw nontext\"}}"

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        root = base.appendingPathComponent("source")
        staging = base.appendingPathComponent("private-staging")
        for directory in [root, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        guard sqlite3_open(database.path, &writer) == SQLITE_OK else { throw POSIXError(.EIO) }
        try sql("""
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, slug TEXT, agent TEXT,
                directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER,
                big_integer INTEGER, opaque BLOB, fraction REAL, nullable TEXT, raw_text TEXT);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
            CREATE INDEX message_session ON message(session_id);
            CREATE INDEX part_message ON part(message_id);
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        checkpointedMain = try Data(contentsOf: database)
        try sql("""
            BEGIN;
            INSERT INTO session VALUES ('ses-one', NULL, 'native', 'build', '/offline/project-one',
                'old title', 100, 110, NULL, 9007199254740993, X'00ff0100', 1.25, NULL, CAST(X'410042' AS TEXT));
            INSERT INTO session (id, directory, title, time_created, time_updated) VALUES
                ('ses-private', '/excluded/project', 'EXCLUDED-SIBLING-PRIVATE', 1, 2);
            INSERT INTO message VALUES ('m-question','ses-one',101,'{"role":"user"}');
            INSERT INTO message VALUES ('m-answer','ses-one',102,'{"role":"assistant","tokens":{"input":96,"output":10}}');
            INSERT INTO message VALUES ('m-private','ses-private',1,'EXCLUDED-SIBLING-PRIVATE');
            INSERT INTO part VALUES ('p-question','m-question',101,'\(question)');
            INSERT INTO part VALUES ('p-answer','m-answer',102,'\(answer)');
            INSERT INTO part VALUES ('p-tool','m-answer',103,'\(tool)');
            INSERT INTO part VALUES ('p-private','m-private',1,'EXCLUDED-SIBLING-PRIVATE');
            COMMIT;
            """)
    }

    func sql(_ value: String) throws {
        guard sqlite3_exec(writer, value, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
    }

    func flushSource() throws {
        guard sqlite3_db_cacheflush(writer) == SQLITE_OK else { throw POSIXError(.EIO) }
    }

    func sourceBytes() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["", "-wal"].map { suffix in
            (suffix, try Data(contentsOf: URL(fileURLWithPath: database.path + suffix)))
        })
    }

    func snapshot(sessionID: String = "ses-one", budget: CollectorOpenCodeSource.Budget = .init(),
                  testHooks: CollectorOpenCodeSource.TestHooks = .init()) throws -> CollectorOpenCodeSource.Snapshot {
        try CollectorOpenCodeSource.snapshot(root: root, sessionID: sessionID, stagingParent: staging,
            budget: budget, testHooks: testHooks)
    }

    func replay(_ image: Data) throws -> DatabaseQueue {
        let path = base.appendingPathComponent("replay-\(UUID().uuidString).sqlite")
        try image.write(to: path)
        return try DatabaseQueue(path: path.path)
    }

    func close() {
        stopWriter()
        try? FileManager.default.removeItem(at: base)
    }

    func stopWriter() {
        if let writer { XCTAssertEqual(sqlite3_close(writer), SQLITE_OK); self.writer = nil }
    }

    func removeOwnedSidecars() throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let path = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }

    func restoreOfflineWAL(_ bytes: [String: Data]) throws {
        stopWriter()
        try removeOwnedSidecars()
        for (suffix, value) in bytes {
            try value.write(to: URL(fileURLWithPath: database.path + suffix))
        }
    }
}

extension CollectorOpenCodeSourceTests {
    func testOpenCodePrivacyUsesCapturedMetadataAfterOriginalRemoval() throws {
        let f = try OpenCodeFixture()
        defer { f.close() }
        let snapshot = try f.snapshot()
        let captured = try privacyCapture(f, snapshot: snapshot)
        f.stopWriter()
        try FileManager.default.removeItem(at: f.root)
        let policy = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.opencode])
        let result = try CollectorPrivacyProof.assess(capture: captured.result, cas: captured.cas,
            format: .opencode, policy: policy)
        guard case .eligible(let proof) = result else { return XCTFail("captured SQLite metadata should authorize: \(result)") }
        XCTAssertEqual(proof.nativeSessionID, "ses-one")
        XCTAssertEqual(proof.projectRoot, "/offline/project-one")
        XCTAssertEqual(proof.source, .opencode)
        XCTAssertTrue(proof.isCurrent(for: captured.result, policy: policy, format: .opencode))
        let newer = try CollectorPrivacyPolicy(revision: 2, excludedProjectRoots: [], allowedSources: [.opencode])
        XCTAssertFalse(proof.isCurrent(for: captured.result, policy: newer, format: .opencode))
    }

    func testOpenCodePhysicalTemporaryRootArchivesWithoutProjectExclusions_repro() throws {
        let f = try OpenCodeFixture()
        defer { f.close() }
        try f.sql("UPDATE session SET directory='/private/tmp' WHERE id='ses-one'")
        let captured = try privacyCapture(f, snapshot: f.snapshot())
        let policy = try openCodePolicy()
        let result = try CollectorPrivacyProof.assess(capture: captured.result, cas: captured.cas,
            format: .opencode, policy: policy)
        guard case .eligible(let proof) = result else { return XCTFail("Physical temporary root should authorize: \(result)") }
        XCTAssertEqual(proof.projectRoot, "/private/tmp")
        XCTAssertTrue(proof.isCurrent(for: captured.result, policy: policy, format: .opencode))
        let excluded = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: ["/unrelated"], allowedSources: [.opencode])
        XCTAssertFalse(proof.isCurrent(for: captured.result, policy: excluded, format: .opencode))
        XCTAssertEqual(try CollectorPrivacyProof.assess(capture: captured.result, cas: captured.cas,
            format: .opencode, policy: excluded), .withheld(.excludedProject))
    }

    func testOpenCodePrivacyWithholdsExcludedAndInvalidProjectRoots() throws {
        for invalid in [false, true] {
            let f = try OpenCodeFixture()
            defer { f.close() }
            if invalid { try f.sql("UPDATE session SET directory='' WHERE id='ses-one'") }
            let captured = try privacyCapture(f, snapshot: f.snapshot())
            let policy = try CollectorPrivacyPolicy(revision: 1,
                excludedProjectRoots: invalid ? [] : ["/offline"], allowedSources: [.opencode])
            XCTAssertEqual(try CollectorPrivacyProof.assess(capture: captured.result, cas: captured.cas,
                format: .opencode, policy: policy), .withheld(invalid ? .invalidProjectRoot : .excludedProject))
        }
    }

    func testOpenCodePrivacyRejectsSiblingSessionsAndForeignChildRows() throws {
        for mutation in [
            "INSERT INTO session(id,directory) VALUES ('other','/excluded/project')",
            "UPDATE message SET session_id='other' WHERE id='m-answer'",
            "UPDATE part SET message_id='other-message' WHERE id='p-answer'"
        ] {
            let f = try OpenCodeFixture()
            defer { f.close() }
            let snapshot = try f.snapshot()
            let file = f.base.appendingPathComponent("tampered.sqlite")
            try snapshot.image.write(to: file)
            let database = try DatabaseQueue(path: file.path)
            try database.write { try $0.execute(sql: mutation) }
            try database.close()
            let captured = try privacyCapture(f, snapshot: snapshot, image: Data(contentsOf: file))
            XCTAssertEqual(try CollectorPrivacyProof.assess(capture: captured.result, cas: captured.cas,
                format: .opencode, policy: openCodePolicy()), .withheld(.invalidCapture), mutation)
        }
    }

    func testOpenCodePrivacyBindsImageNativeIdentityAndPayloadSize() throws {
        for wrongID in [true, false] {
            let f = try OpenCodeFixture()
            defer { f.close() }
            let snapshot = try f.snapshot()
            let context = try ArchiveSQLiteSessionContext(databaseLocator: f.database.path,
                nativeSessionID: wrongID ? "wrong-id" : snapshot.sessionID,
                nativePayloadByteCount: snapshot.nativePayloadByteCount + (wrongID ? 0 : 1),
                walGeneration: snapshot.walGeneration)
            let captured = try privacyCapture(f, snapshot: snapshot, context: context)
            XCTAssertEqual(try CollectorPrivacyProof.assess(capture: captured.result, cas: captured.cas,
                format: .opencode, policy: openCodePolicy()), .withheld(.invalidCapture))
        }
    }

    func testOpenCodePrivacyBoundsImageBytesAndRows() throws {
        let f = try OpenCodeFixture()
        defer { f.close() }
        let captured = try privacyCapture(f, snapshot: f.snapshot())
        for limits in [CollectorPrivacyLimits(maxSourceBytes: 1), CollectorPrivacyLimits(maxRecords: 1)] {
            XCTAssertEqual(try CollectorPrivacyProof.assess(capture: captured.result, cas: captured.cas,
                format: .opencode, policy: openCodePolicy(), limits: limits), .withheld(.limitsExceeded))
        }
    }

    func testOpenCodePrivacyDoesNotParseSemanticMessageBodies() throws {
        let f = try OpenCodeFixture()
        defer { f.close() }
        try f.sql("UPDATE part SET data='not JSON; retained opaque tool text' WHERE id='p-answer'")
        let captured = try privacyCapture(f, snapshot: f.snapshot())
        let result = try CollectorPrivacyProof.assess(capture: captured.result, cas: captured.cas,
            format: .opencode, policy: openCodePolicy())
        guard case .eligible = result else { return XCTFail("privacy should inspect relational ownership, not parse messages: \(result)") }
    }

    private func openCodePolicy() throws -> CollectorPrivacyPolicy {
        try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.opencode])
    }

    private func privacyCapture(_ f: OpenCodeFixture, snapshot: CollectorOpenCodeSource.Snapshot,
        image: Data? = nil, context: ArchiveSQLiteSessionContext? = nil
    ) throws -> (cas: ImmutableArchiveCAS, result: ArchiveCaptureResult) {
        let root = f.base.appendingPathComponent("privacy-archive-\(UUID().uuidString)")
        let machineID = "11111111-2222-3333-4444-555555555555"
        let cas = try ImmutableArchiveCAS(root: root)
        let catalog = try ArchiveCatalog(root: root, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let context = try context ?? ArchiveSQLiteSessionContext(databaseLocator: f.database.path,
            nativeSessionID: snapshot.sessionID, nativePayloadByteCount: snapshot.nativePayloadByteCount,
            walGeneration: snapshot.walGeneration)
        let result = try ExactSourceCapturer.captureSQLiteSessionImage(image ?? snapshot.image,
            context: context, generation: snapshot.databaseGeneration,
            machineID: machineID, cas: cas, catalog: catalog)
        return (cas, result)
    }
}
