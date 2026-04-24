import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

final class SQLiteConnectionPolicyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-core-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testWriterAppliesNodeCompatiblePragmas() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("writer.sqlite"))

        let pragmas = try writer.read { db in
            (
                try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0,
                try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0,
                try Int.fetchOne(db, sql: "PRAGMA wal_autocheckpoint") ?? 0,
                try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? 0
            )
        }

        XCTAssertEqual(pragmas.0.lowercased(), "wal")
        XCTAssertEqual(pragmas.1, 30_000)
        XCTAssertEqual(pragmas.2, 1)
        XCTAssertEqual(pragmas.3, SQLiteConnectionPolicy.walAutocheckpointPages)
        XCTAssertEqual(pragmas.4, 1)
    }

    func testReaderCanReadExistingWalDatabaseWithoutWrites() throws {
        let path = databasePath("reader.sqlite")
        let writer = try EngramDatabaseWriter(path: path)
        try writer.write { db in
            try db.execute(sql: "CREATE TABLE sessions(id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO sessions(id) VALUES ('s1')")
        }

        let reader = try EngramDatabaseReader(path: path)
        let count = try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions") ?? 0
        }

        XCTAssertEqual(count, 1)
    }

    func testReaderRejectsNonWalDatabase() throws {
        let path = databasePath("delete-journal.sqlite")
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
            try db.execute(sql: "CREATE TABLE t(id TEXT)")
        }

        XCTAssertThrowsError(try EngramDatabaseReader(path: path)) { error in
            guard case SQLiteConnectionPolicyError.journalModeNotWAL = error else {
                return XCTFail("expected journalModeNotWAL, got \(error)")
            }
        }
    }

    private func databasePath(_ name: String) -> String {
        tempDir.appendingPathComponent(name).path
    }
}
