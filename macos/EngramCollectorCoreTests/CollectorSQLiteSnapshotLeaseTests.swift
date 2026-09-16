import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EngramCollectorCore

/// Physical main/WAL custody only. Cursor modern+legacy export, transport, and HQ replay
/// remain outside this helper.
final class CollectorSQLiteSnapshotLeaseTests: XCTestCase {
    func testCapturedPairUsesOnlyProvidedBytesAndCleansSuccessAndFailure() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        let main = Data([255, 0, 128, 10])
        let wal = Data([0, 255])
        for throwFromBody in [false, true] {
            var admitted = false
            do {
                try CollectorSQLiteSnapshotLease.withCapturedPair(databaseBytes: main, walBytes: wal,
                    databaseName: "captured.db", stagingParent: f.staging) { url, validate in
                    admitted = true
                    try validate()
                    XCTAssertEqual(try Data(contentsOf: url), main)
                    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")), wal)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
                    XCTAssertEqual(try f.generation(of: url).mode & 0o777, 0o600)
                    if throwFromBody { throw POSIXError(.ECANCELED) }
                }
                XCTAssertFalse(throwFromBody)
            } catch {
                XCTAssertTrue(throwFromBody)
                XCTAssertTrue(error is POSIXError)
            }
            XCTAssertTrue(admitted)
            XCTAssertTrue(try f.stagingNames().isEmpty)
        }
    }

    func testCapturedPairAggregateWriteBudgetAndUnsafeNamesRefuseBeforeBody() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        let main = Data([1, 2, 3, 4]), wal = Data([5, 6])
        for budget in [
            CollectorSQLiteSnapshotLease.Budget(maximumSnapshotByteCount: 5),
            .init(maximumCopyByteCount: 5), .init(maximumCopyByteCount: -1),
            .init(maximumLeaseMilliseconds: -1), .init(maximumLeaseMilliseconds: Int.max),
        ] {
            assertRefused(as: [.exceededBudget]) {
                try CollectorSQLiteSnapshotLease.withCapturedPair(databaseBytes: main, walBytes: wal,
                    databaseName: "store.db", stagingParent: f.staging, budget: budget) { _, _ in XCTFail("admitted over-budget pair") }
            }
            XCTAssertTrue(try f.stagingNames().isEmpty)
        }
        try CollectorSQLiteSnapshotLease.withCapturedPair(databaseBytes: main, walBytes: wal,
            databaseName: "store.db", stagingParent: f.staging,
            budget: .init(maximumSnapshotByteCount: 6, maximumCopyByteCount: 6)) { url, validate in
                try validate()
                    XCTAssertEqual(try Data(contentsOf: url), main)
            }
        assertRefused(as: [.unsafePath]) {
            try CollectorSQLiteSnapshotLease.withCapturedPair(databaseBytes: main, walBytes: nil,
                databaseName: "../store.db", stagingParent: f.staging) { _, _ in XCTFail("unsafe name") }
        }
        XCTAssertTrue(try f.stagingNames().isEmpty)
    }

    func testCapturedPairRejectsPrivateMutationBeforeAdmission() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        for mutation in ["main", "wal", "shm", "journal"] {
            assertRefused(as: [.sourceChanged, .unsafePath]) {
                try CollectorSQLiteSnapshotLease.withCapturedPair(databaseBytes: Data("MAIN".utf8),
                    walBytes: Data("WAL".utf8), databaseName: "store.db", stagingParent: f.staging,
                    testHooks: .init(beforeSnapshotUse: { url in
                        let target = mutation == "main" ? url : URL(fileURLWithPath: url.path + "-" + mutation)
                        try Data("changed".utf8).write(to: target)
                    })) { _, _ in XCTFail("mutated pair admitted") }
            }
            XCTAssertTrue(try f.stagingNames().isEmpty)
        }
    }

    func testStoreDBExposesCommittedWALOnPrivateCopyWithoutOpeningSource() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        let before = try f.sourceBytes()
        XCTAssertNotNil(before["-shm"])
        var privateURL: URL?
        var staged: [String] = []
        try f.withSnapshot(testHooks: .init(beforeSnapshotUse: { privateURL = $0 },
            didStageSourceFile: { name, _, _ in staged.append(name) })) { snapshot in
            XCTAssertEqual(snapshot.databaseGeneration, try f.generation(of: f.database))
            XCTAssertEqual(snapshot.walGeneration, try f.generation(of: f.wal))
            XCTAssertTrue(snapshot.privateDatabaseURL.path.hasPrefix(f.staging.path + "/"))
            XCTAssertEqual(privateURL, snapshot.privateDatabaseURL)
            XCTAssertEqual(try f.readCommitted(snapshot.privateDatabaseURL), f.committed)
            XCTAssertEqual(Set(staged), ["store.db", "store.db-wal"])
        }
        XCTAssertEqual(try f.sourceBytes(), before)
        XCTAssertTrue(try f.stagingNames().isEmpty)
    }

    func testStateVscdbWithoutSHMKeepsSHMAbsentAndReportsNilWALAfterCheckpoint() throws {
        let wal = try LeaseFixture(databaseName: "state.vscdb"); defer { wal.close() }
        try wal.restoreOfflinePair()
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal.shm.path))
        let beforeNames = try wal.rootNames()
        try wal.withSnapshot { snapshot in
            XCTAssertNotNil(snapshot.walGeneration)
            XCTAssertEqual(try wal.readCommitted(snapshot.privateDatabaseURL), wal.committed)
        }
        XCTAssertEqual(try wal.rootNames(), beforeNames)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal.shm.path))

        let checkpointed = try LeaseFixture(databaseName: "state.vscdb"); defer { checkpointed.close() }
        try checkpointed.checkpointAndRemoveSidecars()
        let main = try Data(contentsOf: checkpointed.database)
        try checkpointed.withSnapshot { snapshot in
            XCTAssertNil(snapshot.walGeneration)
            XCTAssertEqual(try checkpointed.readCommitted(snapshot.privateDatabaseURL), checkpointed.committed)
        }
        XCTAssertEqual(try Data(contentsOf: checkpointed.database), main)
        XCTAssertEqual(try checkpointed.rootNames(), ["state.vscdb"])
    }

    func testArbitraryBytesAreCopiedWithoutParsing() throws {
        let f = try LeaseFixture(databaseName: "store.db", seed: false); defer { f.close() }
        let main = Data("not-a-sqlite-database".utf8)
        let wal = Data([0x00, 0xFF, 0x01, 0x20])
        try main.write(to: f.database)
        try wal.write(to: f.wal)
        try f.withSnapshot { snapshot in
            XCTAssertEqual(try Data(contentsOf: snapshot.privateDatabaseURL), main)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: snapshot.privateDatabaseURL.path + "-wal")), wal)
        }
        XCTAssertEqual(try Data(contentsOf: f.database), main)
        XCTAssertEqual(try Data(contentsOf: f.wal), wal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.shm.path))
        XCTAssertTrue(try f.stagingNames().isEmpty)
    }

    func testBodySeesSealedRowsAfterSourceRemovalAndWriterAdvance() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        try f.withSnapshot { snapshot in
            XCTAssertEqual(try f.readCommitted(snapshot.privateDatabaseURL), f.committed)
            try f.sql("UPDATE kv SET v='after-seal' WHERE k='row'")
            XCTAssertEqual(try f.readCommitted(snapshot.privateDatabaseURL), f.committed)
            f.stopWriter()
            try FileManager.default.removeItem(at: f.root)
            XCTAssertEqual(try f.readCommitted(snapshot.privateDatabaseURL), f.committed)
        }
        XCTAssertTrue(try f.stagingNames().isEmpty)
    }

    func testStagingIsEmptyAfterSuccessAndAfterBodyError() throws {
        let ok = try LeaseFixture(databaseName: "state.vscdb"); defer { ok.close() }
        try ok.withSnapshot { _ in }
        XCTAssertTrue(try ok.stagingNames().isEmpty)

        let failed = try LeaseFixture(databaseName: "store.db"); defer { failed.close() }
        XCTAssertThrowsError(try failed.withSnapshot { _ in throw BodyError() }) { error in
            XCTAssertTrue(error is BodyError, "body error must propagate; notImplemented is not a refusal")
        }
        XCTAssertTrue(try failed.stagingNames().isEmpty)
    }

    func testForcedCopySharesMainAndWALBudgetAndHonorsSnapshotCap() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        try f.restoreOfflinePair()
        let total = try f.pairSize()
        var streamed: Int64 = 0
        var stages = 0
        try f.withSnapshot(
            budget: .init(maximumCopyByteCount: total),
            testHooks: .init(didStageSourceFile: { _, cloned, bytes in
                XCTAssertFalse(cloned)
                streamed += bytes
                stages += 1
            }, forceStreamingCopy: true)
        ) { snapshot in
            XCTAssertEqual(try f.readCommitted(snapshot.privateDatabaseURL), f.committed)
        }
        XCTAssertEqual(stages, 2)
        XCTAssertEqual(streamed, total)

        let maxSide = try max(f.generation(of: f.database).size, f.generation(of: f.wal).size)
        assertRefused(as: [.exceededBudget]) {
            try f.withSnapshot(
                budget: .init(maximumCopyByteCount: maxSide + 1),
                testHooks: .init(forceStreamingCopy: true)
            ) { _ in }
        }
        assertRefused(as: [.exceededBudget]) {
            try f.withSnapshot(budget: .init(maximumSnapshotByteCount: try f.generation(of: f.database).size)) { _ in }
        }
        XCTAssertTrue(try f.stagingNames().isEmpty)
    }

    func testUnsafeNamesRootsAndRecognizedSidecarsAreRefused() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        let outside = f.base.appendingPathComponent("outside.db")
        try f.invalidStoreBytes.write(to: outside)

        for name in ["../store.db", "dir/store.db", "", ".", "..", "store.db/tail", "store.db\0x"] {
            assertRefused(as: [.unsafePath]) { try f.withSnapshot(databaseName: name) { _ in } }
        }
        for root in [
            URL(fileURLWithPath: f.root.path + "/../" + f.root.lastPathComponent),
            URL(fileURLWithPath: f.root.path + "/."),
            URL(fileURLWithPath: "relative-root"),
            f.base.appendingPathComponent("missing-root"),
        ] {
            assertRefused(as: [.unsafePath, .unavailable]) { try f.withSnapshot(root: root) { _ in } }
        }

        let linkedRoot = f.base.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: f.root)
        assertRefused(as: [.unsafePath]) { try f.withSnapshot(root: linkedRoot) { _ in } }

        let ancestor = f.base.appendingPathComponent("ancestor-alias")
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: f.base)
        assertRefused(as: [.unsafePath]) {
            try f.withSnapshot(root: ancestor.appendingPathComponent(f.root.lastPathComponent)) { _ in }
        }

        let linkedDB = try LeaseFixture(databaseName: "state.vscdb", seed: false); defer { linkedDB.close() }
        try FileManager.default.createSymbolicLink(at: linkedDB.database, withDestinationURL: outside)
        assertRefused(as: [.unsafePath]) { try linkedDB.withSnapshot { _ in } }

        let linkedWAL = try LeaseFixture(databaseName: "store.db"); defer { linkedWAL.close() }
        try linkedWAL.restoreOfflinePair()
        let walVictim = linkedWAL.base.appendingPathComponent("wal-victim")
        try FileManager.default.moveItem(at: linkedWAL.wal, to: walVictim)
        try FileManager.default.createSymbolicLink(at: linkedWAL.wal, withDestinationURL: walVictim)
        assertRefused(as: [.unsafePath]) { try linkedWAL.withSnapshot { _ in } }

        let linkedSHM = try LeaseFixture(databaseName: "store.db"); defer { linkedSHM.close() }
        try linkedSHM.restoreOfflinePair()
        if FileManager.default.fileExists(atPath: linkedSHM.shm.path) {
            try FileManager.default.removeItem(at: linkedSHM.shm)
        }
        try FileManager.default.createSymbolicLink(at: linkedSHM.shm, withDestinationURL: outside)
        assertRefused(as: [.unsafePath]) { try linkedSHM.withSnapshot { _ in } }

        let fifo = try LeaseFixture(databaseName: "store.db"); defer { fifo.close() }
        fifo.stopWriter()
        try FileManager.default.removeItem(at: fifo.database)
        XCTAssertEqual(mkfifo(fifo.database.path, 0o600), 0)
        assertRefused(as: [.unsafePath]) { try fifo.withSnapshot { _ in } }

        let fifoWAL = try LeaseFixture(databaseName: "state.vscdb"); defer { fifoWAL.close() }
        try fifoWAL.restoreOfflinePair()
        try FileManager.default.removeItem(at: fifoWAL.wal)
        XCTAssertEqual(mkfifo(fifoWAL.wal.path, 0o600), 0)
        assertRefused(as: [.unsafePath]) { try fifoWAL.withSnapshot { _ in } }
    }

    func testRollbackJournalIsRejectedWithoutRecovery() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        try f.sql("""
            PRAGMA journal_mode=DELETE;
            PRAGMA cache_size=1;
            BEGIN IMMEDIATE;
            UPDATE kv SET v='uncommitted', blob=zeroblob(262144) WHERE k='row';
            """)
        try f.flush()
        let main = try Data(contentsOf: f.database)
        let journal = try Data(contentsOf: f.journal)
        XCTAssertGreaterThan(journal.count, 512)
        assertRefused(as: [.unsafePath]) { try f.withSnapshot { _ in } }
        XCTAssertEqual(try Data(contentsOf: f.database), main)
        XCTAssertEqual(try Data(contentsOf: f.journal), journal)
        try f.sql("ROLLBACK")
    }

    func testAfterMainCopyFencesWALAddChangeRemovalAndRootReplacement() throws {
        let add = try LeaseFixture(databaseName: "store.db"); defer { add.close() }
        try add.checkpointAndRemoveSidecars()
        assertRefused(as: [.sourceChanged]) {
            try add.withSnapshot(testHooks: .init(afterPrivateMainCopy: {
                try add.reopenWriter()
                try add.sql("PRAGMA journal_mode=WAL; UPDATE kv SET v='late-wal' WHERE k='row'")
            })) { _ in }
        }

        let change = try LeaseFixture(databaseName: "state.vscdb"); defer { change.close() }
        try change.restoreOfflinePair()
        assertRefused(as: [.sourceChanged]) {
            try change.withSnapshot(testHooks: .init(afterPrivateMainCopy: {
                try Data("wal-changed".utf8).write(to: change.wal)
            })) { _ in }
        }

        let removed = try LeaseFixture(databaseName: "store.db"); defer { removed.close() }
        try removed.restoreOfflinePair()
        assertRefused(as: [.sourceChanged]) {
            try removed.withSnapshot(testHooks: .init(afterPrivateMainCopy: {
                try FileManager.default.removeItem(at: removed.wal)
            })) { _ in }
        }

        let root = try LeaseFixture(databaseName: "store.db"); defer { root.close() }
        assertRefused(as: [.sourceChanged, .unsafePath]) {
            try root.withSnapshot(testHooks: .init(afterPrivateMainCopy: {
                let moved = root.base.appendingPathComponent("moved-root")
                try FileManager.default.moveItem(at: root.root, to: moved)
                try FileManager.default.createDirectory(at: root.root, withIntermediateDirectories: false)
                try root.invalidStoreBytes.write(to: root.database)
            })) { _ in }
        }
        XCTAssertTrue(try add.stagingNames().isEmpty)
        XCTAssertTrue(try change.stagingNames().isEmpty)
        XCTAssertTrue(try removed.stagingNames().isEmpty)
        XCTAssertTrue(try root.stagingNames().isEmpty)
    }

    func testSourceDescriptorHooksFenceUnbindAndRootAlias() throws {
        let unbound = try LeaseFixture(databaseName: "store.db"); defer { unbound.close() }
        assertRefused(as: [.sourceChanged]) {
            try unbound.withSnapshot(testHooks: .init(afterSourceDescriptorsOpened: {
                try FileManager.default.moveItem(at: unbound.database,
                    to: unbound.root.appendingPathComponent("replaced-original.db"))
            })) { _ in }
        }

        let alias = try LeaseFixture(databaseName: "state.vscdb"); defer { alias.close() }
        assertRefused(as: [.sourceChanged, .unsafePath]) {
            try alias.withSnapshot(testHooks: .init(afterSourceDescriptorsOpened: {
                let moved = alias.base.appendingPathComponent("moved-source")
                try FileManager.default.moveItem(at: alias.root, to: moved)
                try FileManager.default.createSymbolicLink(at: alias.root, withDestinationURL: moved)
            })) { _ in }
        }
        XCTAssertTrue(try unbound.stagingNames().isEmpty)
        XCTAssertTrue(try alias.stagingNames().isEmpty)
    }

    func testStagingAliasBeforeUseIsRejectedAndOwnedDirectoryIsCleaned() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        let moved = f.base.appendingPathComponent("moved-staging")
        assertRefused(as: [.unsafePath, .sourceChanged]) {
            try f.withSnapshot(testHooks: .init(beforeSnapshotUse: { _ in
                try FileManager.default.moveItem(at: f.staging, to: moved)
                try FileManager.default.createSymbolicLink(at: f.staging, withDestinationURL: moved)
            })) { _ in }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testStagingParentEqualOrInsideSourceRootIsRejectedBeforeWriting() throws {
        let f = try LeaseFixture(databaseName: "store.db"); defer { f.close() }
        let before = try f.rootNames()
        let nested = f.root.appendingPathComponent("inside-staging")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        assertRefused(as: [.unsafePath]) { try f.withSnapshot(stagingParent: f.root) { _ in } }
        assertRefused(as: [.unsafePath]) { try f.withSnapshot(stagingParent: nested) { _ in } }
        XCTAssertEqual(Set(try f.rootNames()), Set(before + ["inside-staging"]))
    }

    func testCancellationAndInvalidBudgetsRefuseWithoutAPrivateImage() async throws {
        let f = try LeaseFixture(databaseName: "state.vscdb"); defer { f.close() }
        var used = false
        assertRefused(as: [.exceededBudget]) {
            try f.withSnapshot(budget: .init(maximumLeaseMilliseconds: Int(UInt64.max / 1_000_000))) { _ in used = true }
        }
        assertRefused(as: [.exceededBudget]) {
            try f.withSnapshot(budget: .init(maximumCopyByteCount: -1)) { _ in used = true }
        }
        assertRefused(as: [.exceededBudget]) {
            try f.withSnapshot(budget: .init(maximumSnapshotByteCount: -1)) { _ in used = true }
        }
        XCTAssertFalse(used)

        let cancelled = try LeaseFixture(databaseName: "store.db"); defer { cancelled.close() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try cancelled.withSnapshot { snapshot in
                _ = try cancelled.readCommitted(snapshot.privateDatabaseURL)
            }
        }
        do {
            _ = try await task.value
            XCTFail("cancelled collection must not produce a snapshot")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(try f.stagingNames().isEmpty)
        XCTAssertTrue(try cancelled.stagingNames().isEmpty)
    }
}

private struct BodyError: Error {}

private final class LeaseFixture {
    let invalidStoreBytes = Data("not-a-sqlite-database".utf8)
    let committed = "lease-committed-row"
    let databaseName: String
    let base: URL
    let root: URL
    let staging: URL
    var database: URL { root.appendingPathComponent(databaseName) }
    var wal: URL { URL(fileURLWithPath: database.path + "-wal") }
    var shm: URL { URL(fileURLWithPath: database.path + "-shm") }
    var journal: URL { URL(fileURLWithPath: database.path + "-journal") }
    private var writer: OpaquePointer?

    init(databaseName: String, seed: Bool = true) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("engram-sqlite-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        root = base.appendingPathComponent("source")
        staging = base.appendingPathComponent("private-staging")
        self.databaseName = databaseName
        for directory in [root, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        guard seed else { return }
        try reopenWriter()
        try sql("""
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT, blob BLOB);
            PRAGMA wal_checkpoint(TRUNCATE);
            BEGIN;
            INSERT INTO kv(k, v) VALUES ('row', '\(committed)');
            COMMIT;
            """)
    }

    func withSnapshot<T>(
        root: URL? = nil, databaseName: String? = nil, stagingParent: URL? = nil,
        budget: CollectorSQLiteSnapshotLease.Budget = .init(),
        testHooks: CollectorSQLiteSnapshotLease.TestHooks = .init(),
        _ body: (CollectorSQLiteSnapshotLease.Snapshot) throws -> T
    ) throws -> T {
        try CollectorSQLiteSnapshotLease.withSnapshot(
            root: root ?? self.root, databaseName: databaseName ?? self.databaseName,
            stagingParent: stagingParent ?? staging, budget: budget, testHooks: testHooks, body
        )
    }

    func sql(_ value: String) throws {
        guard let writer, sqlite3_exec(writer, value, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
    }

    func flush() throws {
        guard let writer, sqlite3_db_cacheflush(writer) == SQLITE_OK else { throw POSIXError(.EIO) }
    }

    func reopenWriter() throws {
        stopWriter()
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw POSIXError(.EIO) }
        writer = handle
    }

    func sourceBytes() throws -> [String: Data] {
        var bytes: [String: Data] = ["": try Data(contentsOf: database)]
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                bytes[suffix] = try Data(contentsOf: url)
            }
        }
        return bytes
    }

    func restoreOfflinePair() throws {
        let saved = try sourceBytes()
        stopWriter()
        for suffix in ["-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try XCTUnwrap(saved[""]).write(to: database)
        try XCTUnwrap(saved["-wal"]).write(to: wal)
    }

    func checkpointAndRemoveSidecars() throws {
        try sql("PRAGMA wal_checkpoint(TRUNCATE)")
        stopWriter()
        for suffix in ["-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func pairSize() throws -> Int64 {
        try generation(of: database).size + generation(of: wal).size
    }

    func generation(of url: URL) throws -> ArchiveSourceGeneration {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let inode = Int64(exactly: info.st_ino) else { throw POSIXError(.EIO) }
        func nanos(_ time: timespec) throws -> Int64 {
            let seconds = Int64(time.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
            let result = seconds.partialValue.addingReportingOverflow(Int64(time.tv_nsec))
            guard !seconds.overflow, !result.overflow else { throw POSIXError(.EOVERFLOW) }
            return result.partialValue
        }
        return try ArchiveSourceGeneration(
            device: Int64(info.st_dev), inode: inode, size: Int64(info.st_size),
            mtimeNs: nanos(info.st_mtimespec), ctimeNs: nanos(info.st_ctimespec), mode: Int64(info.st_mode)
        )
    }

    func readCommitted(_ privateDatabase: URL) throws -> String {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(privateDatabase.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT v FROM kv WHERE k='row'", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw POSIXError(.EIO) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw POSIXError(.EIO)
        }
        return String(cString: text)
    }

    func rootNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    func stagingNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: staging.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: staging.path)
    }

    func stopWriter() {
        if let writer {
            XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
            self.writer = nil
        }
    }

    func close() {
        stopWriter()
        try? FileManager.default.removeItem(at: base)
    }
}

private func assertRefused<T>(
    as allowed: [CollectorSQLiteSnapshotError],
    _ work: () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try work(), file: file, line: line) { error in
        if let posix = error as? CollectorPOSIXEnumerationError {
            XCTAssertNotEqual(posix, .notImplemented, "refusal must be behavioral, not the draft stub", file: file, line: line)
        }
        guard let sqlite = error as? CollectorSQLiteSnapshotError else {
            XCTFail("expected CollectorSQLiteSnapshotError, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(allowed.contains(sqlite), "got \(sqlite)", file: file, line: line)
    }
}

