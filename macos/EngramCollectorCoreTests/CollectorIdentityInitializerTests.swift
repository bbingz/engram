import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

final class CollectorIdentityInitializerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".engram-identity-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let canonical = try XCTUnwrap(Darwin.realpath(root.path, nil))
        root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        Darwin.free(canonical)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testCreatesFirstMachineIdentityAndReaderReadback() throws {
        let catalog = catalogURL("identity")
        let machineID = try CollectorIdentityInitializer.create(at: catalog)
        XCTAssertEqual(UUID(uuidString: machineID)?.uuidString, machineID)
        XCTAssertEqual(machineID.utf8.count, 36)
        XCTAssertEqual(try CollectorMachineIdentityReader.read(from: catalog), machineID)
        XCTAssertEqual(
            try CollectorMachineIdentityReader.read(from: catalog, expectedMachineID: machineID),
            machineID
        )
        XCTAssertEqual(try permissions(catalog.deletingLastPathComponent().path), 0o700)
        XCTAssertEqual(try permissions(catalog.path), 0o600)
    }

    func testRepeatCreateRefusesAndLeavesBytesUnchanged() throws {
        let catalog = catalogURL("identity")
        let machineID = try CollectorIdentityInitializer.create(at: catalog)
        let before = try Data(contentsOf: catalog)
        XCTAssertFalse(before.isEmpty)
        XCTAssertThrowsError(try CollectorIdentityInitializer.create(at: catalog))
        XCTAssertEqual(try Data(contentsOf: catalog), before)
        XCTAssertEqual(try CollectorMachineIdentityReader.read(from: catalog), machineID)
        XCTAssertEqual(try names(in: catalog.deletingLastPathComponent()), ["archive.sqlite"])
    }

    func testCreatesNoIndexSpoolOrCASStores() throws {
        let catalog = catalogURL("identity")
        _ = try CollectorIdentityInitializer.create(at: catalog)
        let parent = catalog.deletingLastPathComponent()
        XCTAssertEqual(try names(in: parent), ["archive.sqlite"])
        for extra in [
            "index.sqlite", "inventory", "capture", "objects", "manifests", "tmp",
            "collector-owner.lock", "archive.sqlite-wal", "archive.sqlite-shm",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: parent.appendingPathComponent(extra).path),
                extra
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.sqlite").path))
    }

    func testSymlinkAndUnsafeAncestorRefuseWithoutMutation() throws {
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(
            try CollectorIdentityInitializer.create(
                at: alias.appendingPathComponent("identity").appendingPathComponent("archive.sqlite")
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity").path))

        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(
            at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(shared.path, 0o777), 0)
        let unsafeCatalog = shared.appendingPathComponent("identity").appendingPathComponent("archive.sqlite")
        XCTAssertThrowsError(try CollectorIdentityInitializer.create(at: unsafeCatalog))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("identity").path))
        XCTAssertEqual(try permissions(shared.path), 0o777)
    }

    func testExistingParentRefusesWithoutMutation() throws {
        let parent = root.appendingPathComponent("identity")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let keep = parent.appendingPathComponent("keep")
        try Data("preserve".utf8).write(to: keep)
        XCTAssertEqual(chmod(keep.path, 0o600), 0)
        let before = try Data(contentsOf: keep)
        XCTAssertThrowsError(
            try CollectorIdentityInitializer.create(at: parent.appendingPathComponent("archive.sqlite"))
        )
        XCTAssertEqual(try names(in: parent), ["keep"])
        XCTAssertEqual(try Data(contentsOf: keep), before)
        XCTAssertEqual(try permissions(parent.path), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("archive.sqlite").path))
    }

    func testSpoolInitializerBorrowsMintedIdentityWithoutChangingCatalog() throws {
        let catalog = catalogURL("identity")
        let machineID = try CollectorIdentityInitializer.create(at: catalog)
        let before = try Data(contentsOf: catalog)
        let spool = root.appendingPathComponent("collector")
        try CollectorSpoolInitializer.create(root: spool, identityCatalog: catalog)
        XCTAssertEqual(try Data(contentsOf: catalog), before)
        XCTAssertEqual(try CollectorMachineIdentityReader.read(from: catalog), machineID)
        XCTAssertEqual(
            try CollectorMachineIdentityReader.read(from: spool.appendingPathComponent("archive.sqlite")),
            machineID
        )
        XCTAssertEqual(
            try CollectorMachineIdentityReader.read(from: spool.appendingPathComponent("capture/archive.sqlite")),
            machineID
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.deletingLastPathComponent().appendingPathComponent("capture").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.deletingLastPathComponent().appendingPathComponent("index.sqlite").path))
    }

    func testArchiveCatalogMigratePreservesMintedIdentity() throws {
        let catalog = catalogURL("identity")
        let machineID = try CollectorIdentityInitializer.create(at: catalog)
        let other = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        XCTAssertNotEqual(other, machineID)
        let archive = try ArchiveCatalog(
            root: catalog.deletingLastPathComponent(),
            machineID: other
        )
        try archive.migrate()
        XCTAssertEqual(try archive.machineID(), machineID)
        try archive.close()
        // A closed WAL catalog need not retain readable sidecars. Reopen using
        // its owning API to verify persistence without weakening the borrower.
        let reopened = try ArchiveCatalog(root: catalog.deletingLastPathComponent(), machineID: other)
        try reopened.migrate()
        XCTAssertEqual(try reopened.machineID(), machineID)
        try reopened.close()
    }

    private func catalogURL(_ parentName: String) -> URL {
        root.appendingPathComponent(parentName).appendingPathComponent("archive.sqlite")
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func permissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
