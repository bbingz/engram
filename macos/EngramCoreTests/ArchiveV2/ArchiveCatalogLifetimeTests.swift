import EngramCoreWrite
import Foundation
import XCTest

final class ArchiveCatalogLifetimeTests: XCTestCase {
    func testCloseSealsReadsAndWritesWhileTheCatalogReferenceRemainsAlive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-catalog-lifetime-\(UUID().uuidString)")
        let catalog = try ArchiveCatalog(root: root)
        defer { try? catalog.close(); try? FileManager.default.removeItem(at: root) }
        try catalog.migrate()
        let identity = try catalog.machineID()
        try catalog.close()
        XCTAssertThrowsError(try catalog.machineID(), "close must seal the retained catalog's readers")
        XCTAssertThrowsError(try catalog.migrate(), "close must seal the retained catalog's writer")
        let reopened = try ArchiveCatalog(root: root)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.machineID(), identity)
    }

    func testCloseIsIdempotentWithoutReopeningTheDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-catalog-lifetime-\(UUID().uuidString)")
        let catalog = try ArchiveCatalog(root: root)
        defer { try? catalog.close(); try? FileManager.default.removeItem(at: root) }
        try catalog.migrate()
        try catalog.close()
        XCTAssertNoThrow(try catalog.close())
        XCTAssertThrowsError(try catalog.machineID())
    }
}
