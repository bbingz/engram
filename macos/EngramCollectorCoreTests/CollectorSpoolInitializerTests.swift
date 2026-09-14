import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorSpoolInitializerTests: XCTestCase {
    private var root: URL!
    private var catalog: URL!
    private let machineID = "11111111-2222-3333-4444-555555555555"

    override func setUpWithError() throws {
        // Match runtime fixtures: use an explicit checkout-local root, avoiding
        // macOS temporary-directory aliases rejected by the identity reader.
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".engram-initialize-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let canonical = try XCTUnwrap(Darwin.realpath(root.path, nil))
        root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        Darwin.free(canonical)
        let borrowed = root.appendingPathComponent("borrowed")
        try FileManager.default.createDirectory(at: borrowed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        catalog = borrowed.appendingPathComponent("archive.sqlite")
        let database = try DatabaseQueue(path: catalog.path)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT)")
            try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [machineID])
        }
        try database.close()
        XCTAssertEqual(chmod(catalog.path, 0o600), 0)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testCreatesMatchingPrivateClosedCatalogsAndDoesNotTouchBorrowedIdentity() throws {
        let before = try Data(contentsOf: catalog)
        let target = root.appendingPathComponent("collector")
        do { try CollectorSpoolInitializer.create(root: target, identityCatalog: catalog) }
        catch { XCTFail("Fresh fixture initialization failed at \(target.path): \(error)"); return }
        XCTAssertEqual(try Data(contentsOf: catalog), before)
        XCTAssertEqual(try CollectorMachineIdentityReader.read(from: target.appendingPathComponent("archive.sqlite")), machineID)
        XCTAssertEqual(try CollectorMachineIdentityReader.read(from: target.appendingPathComponent("capture/archive.sqlite")), machineID)
        for relative in ["", "capture", "capture/tmp", "capture/objects/sha256", "capture/manifests/sha256"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent(relative).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("inventory").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("index.sqlite").path))
        XCTAssertThrowsError(try CollectorSpoolInitializer.create(root: target, identityCatalog: catalog))
    }

    func testMissingBorrowedIdentityCreatesNothing() throws {
        let target = root.appendingPathComponent("collector")
        XCTAssertThrowsError(try CollectorSpoolInitializer.create(root: target, identityCatalog: root.appendingPathComponent("missing.sqlite")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testBorrowedCatalogDirectoryCannotBecomeCollectorDestination() throws {
        let before = try Data(contentsOf: catalog)
        let target = catalog.deletingLastPathComponent().appendingPathComponent("collector")
        XCTAssertThrowsError(try CollectorSpoolInitializer.create(root: target, identityCatalog: catalog))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: catalog), before)
    }

    func testSymlinkParentAndExistingLeafAreNeverFollowedOrReplaced() throws {
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try CollectorSpoolInitializer.create(root: alias.appendingPathComponent("collector"), identityCatalog: catalog))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("collector").path))
        let existing = root.appendingPathComponent("existing")
        try Data("preserve".utf8).write(to: existing)
        XCTAssertThrowsError(try CollectorSpoolInitializer.create(root: existing, identityCatalog: catalog))
        XCTAssertEqual(try Data(contentsOf: existing), Data("preserve".utf8))
    }

    func testUnsafeParentIsRejectedWithoutPermissionRepair() throws {
        let parent = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(chmod(parent.path, 0o777), 0)
        let target = parent.appendingPathComponent("collector")
        XCTAssertThrowsError(try CollectorSpoolInitializer.create(root: target, identityCatalog: catalog))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o777)
    }

    func testDirectoryReplacementBeforeSQLiteOpenCannotMigrateAnUnrelatedDatabase() throws {
        let target = root.appendingPathComponent("collector")
        let moved = root.appendingPathComponent("detached-owned-spool")
        var victim: URL?
        var before: Data?
        XCTAssertThrowsError(try CollectorSpoolInitializer.create(root: target, identityCatalog: catalog, beforeDatabaseOpen: { url in
            XCTAssertNil(victim)
            try FileManager.default.moveItem(at: target, to: moved)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let unrelated = try DatabaseQueue(path: url.path)
            try unrelated.write { try $0.execute(sql: "CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES ('preserve')") }
            try unrelated.close()
            XCTAssertEqual(chmod(url.path, 0o600), 0)
            victim = url
            before = try Data(contentsOf: url)
        }))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(victim)), try XCTUnwrap(before),
            "reject before any schema write to the replacement database")
    }

    func testDirectoryReplacementHotJournalDoesNotRecoverVictim() throws {
        let frozen = root.appendingPathComponent("frozen-hot.sqlite")
        try freezeHotJournal(at: frozen)
        try proveHotJournalViaControlCopy(of: frozen)
        let planted = try assertCreateRejectsPreservingPlantedFamily { [self] url in
            try self.copySQLiteFamily(from: frozen, to: url)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
            return url
        }
        XCTAssertEqual(planted.after, planted.before,
            "open-time recovery must not rewrite a proven-hot journal victim")
    }

    func testDirectoryReplacementDirtyWALDoesNotMutateVictim() throws {
        let frozen = root.appendingPathComponent("frozen-wal.sqlite")
        try freezeDirtyWAL(at: frozen)
        try proveDirtyWALViaControlCopy(of: frozen)
        let planted = try assertCreateRejectsPreservingPlantedFamily { [self] url in
            try self.copySQLiteFamily(from: frozen, to: url)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
            return url
        }
        XCTAssertEqual(planted.after, planted.before,
            "open-time WAL replay must not rewrite a proven-dirty WAL victim or its sidecars")
    }

    func testDirectoryReplacementSymlinkDoesNotMutateTarget() throws {
        let targetVictim = root.appendingPathComponent("symlink-target.sqlite")
        try freezeDirtyWAL(at: targetVictim)
        try proveDirtyWALViaControlCopy(of: targetVictim)
        let planted = try assertCreateRejectsPreservingPlantedFamily { [self] url in
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: targetVictim)
            return targetVictim
        }
        XCTAssertEqual(planted.after, planted.before,
            "sqlite3_open following a replacement symlink must not mutate the target family")
        let linkSidecars = try SQLiteFamilySnapshot.sidecars(at: planted.leaf)
        XCTAssertEqual(linkSidecars, .missing,
            "opening via the symlink path must not create sidecars beside the link")
    }

    private struct SQLiteFamilySnapshot: Equatable {
        var main: Data
        var journal: Data?
        var wal: Data?
        var shm: Data?

        static let missing = SQLiteFamilySnapshot(main: Data(), journal: nil, wal: nil, shm: nil)

        static func capture(at url: URL) throws -> SQLiteFamilySnapshot {
            SQLiteFamilySnapshot(
                main: try Data(contentsOf: url),
                journal: try optionalFile(url.path + "-journal"),
                wal: try optionalFile(url.path + "-wal"),
                shm: try optionalFile(url.path + "-shm")
            )
        }

        static func sidecars(at url: URL) throws -> SQLiteFamilySnapshot {
            SQLiteFamilySnapshot(
                main: Data(),
                journal: try optionalFile(url.path + "-journal"),
                wal: try optionalFile(url.path + "-wal"),
                shm: try optionalFile(url.path + "-shm")
            )
        }

        private static func optionalFile(_ path: String) throws -> Data? {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    private struct PlantedFamily {
        let leaf: URL
        let before: SQLiteFamilySnapshot
        let after: SQLiteFamilySnapshot
    }

    private func freezeHotJournal(at destination: URL) throws {
        let live = root.appendingPathComponent("hot-live.sqlite")
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        configuration.allowsUnsafeTransactions = true
        let database = try DatabaseQueue(path: live.path, configuration: configuration)
        try database.write { db in
            try db.execute(sql: "PRAGMA journal_mode=DELETE")
            try db.execute(sql: "CREATE TABLE sentinel(value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO sentinel VALUES ('committed')")
        }
        try database.writeWithoutTransaction { db in
            try db.beginTransaction(.immediate)
            try db.execute(sql: "INSERT INTO sentinel VALUES ('uncommitted-hot')")
            XCTAssertEqual(sqlite3_db_cacheflush(db.sqliteConnection), SQLITE_OK,
                "owned dirty pages must spill before the family is frozen")
            XCTAssertTrue(FileManager.default.fileExists(atPath: live.path + "-journal"),
                "rollback journal must exist after cacheflush")
            try self.copySQLiteFamily(from: live, to: destination)
        }
        try database.close()
        XCTAssertNotNil(try SQLiteFamilySnapshot.capture(at: destination).journal)
    }

    private func proveHotJournalViaControlCopy(of frozen: URL) throws {
        let control = root.appendingPathComponent("hot-control.sqlite")
        try copySQLiteFamily(from: frozen, to: control)
        let before = try SQLiteFamilySnapshot.capture(at: control)
        let journal = try XCTUnwrap(before.journal, "control copy must include a journal, not just a filename")
        XCTAssertFalse(journal.isEmpty)
        let recovered = try DatabaseQueue(path: control.path)
        let values = try recovered.read { try String.fetchAll($0, sql: "SELECT value FROM sentinel ORDER BY value") }
        try recovered.close()
        let after = try SQLiteFamilySnapshot.capture(at: control)
        XCTAssertEqual(values, ["committed"],
            "control recovery must roll back the in-flight insert")
        XCTAssertNil(after.journal, "control recovery must consume the hot journal")
        XCTAssertNotEqual(before.main, after.main,
            "control recovery must rewrite the main file; otherwise the journal was not hot")
    }

    private func freezeDirtyWAL(at destination: URL) throws {
        let live = root.appendingPathComponent("wal-live-\(UUID().uuidString).sqlite")
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        configuration.journalMode = .wal
        let database = try DatabaseQueue(path: live.path, configuration: configuration)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE sentinel(value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO sentinel VALUES ('wal-committed')")
        }
        let wal = try Data(contentsOf: URL(fileURLWithPath: live.path + "-wal"))
        XCTAssertFalse(wal.isEmpty, "WAL must contain uncheckpointed frames before the frozen copy")
        try copySQLiteFamily(from: live, to: destination)
        try database.close()
        XCTAssertNotNil(try SQLiteFamilySnapshot.capture(at: destination).wal)
    }

    private func proveDirtyWALViaControlCopy(of frozen: URL) throws {
        let withWAL = root.appendingPathComponent("wal-control-\(UUID().uuidString).sqlite")
        let mainOnly = root.appendingPathComponent("wal-main-only-\(UUID().uuidString).sqlite")
        try copySQLiteFamily(from: frozen, to: withWAL)
        try FileManager.default.copyItem(at: frozen, to: mainOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainOnly.path + "-wal"))
        let recovered = try DatabaseQueue(path: withWAL.path)
        let values = try recovered.read { try String.fetchAll($0, sql: "SELECT value FROM sentinel") }
        try recovered.close()
        XCTAssertEqual(values, ["wal-committed"], "control open must replay the dirty WAL")
        let isolated = try DatabaseQueue(path: mainOnly.path)
        let isolatedValues = try isolated.read {
            (try? String.fetchAll($0, sql: "SELECT value FROM sentinel")) ?? []
        }
        try isolated.close()
        XCTAssertNotEqual(isolatedValues, ["wal-committed"],
            "main-only copy must not already contain the WAL row; otherwise the WAL was not dirty")
    }

    private func copySQLiteFamily(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.copyItem(at: source, to: destination)
        for suffix in ["-journal", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            let to = URL(fileURLWithPath: destination.path + suffix)
            if manager.fileExists(atPath: to.path) { try manager.removeItem(at: to) }
            if manager.fileExists(atPath: from.path) { try manager.copyItem(at: from, to: to) }
        }
    }

    private func assertCreateRejectsPreservingPlantedFamily(
        plant: @escaping (URL) throws -> URL
    ) throws -> PlantedFamily {
        let target = root.appendingPathComponent("collector-\(UUID().uuidString)")
        let moved = root.appendingPathComponent("detached-\(UUID().uuidString)")
        var leaf: URL?
        var victim: URL?
        var before: SQLiteFamilySnapshot?
        XCTAssertThrowsError(try CollectorSpoolInitializer.create(
            root: target, identityCatalog: catalog, beforeDatabaseOpen: { [self] url in
                XCTAssertNil(victim)
                try FileManager.default.moveItem(at: target, to: moved)
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let planted = try plant(url)
                leaf = url
                victim = planted
                before = try SQLiteFamilySnapshot.capture(at: planted)
            }))
        let observedVictim = try XCTUnwrap(victim)
        let observedLeaf = try XCTUnwrap(leaf)
        let observedBefore = try XCTUnwrap(before)
        return PlantedFamily(
            leaf: observedLeaf,
            before: observedBefore,
            after: try SQLiteFamilySnapshot.capture(at: observedVictim)
        )
    }
}
