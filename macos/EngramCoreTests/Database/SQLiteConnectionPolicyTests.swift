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

    // Engine pragma for the hundreds-of-MB FTS-heavy DB: a larger page cache keeps
    // hot FTS pages resident. cache_size is negative (KiB) per the SQLite
    // convention. mmap_size is intentionally left disabled (default 0): the
    // in-process startup VACUUM can shrink the file under live mmap readers
    // (SIGBUS), so we rely on cache_size alone.
    func testConnectionAppliesCacheSizePragmaAndLeavesMmapDisabled() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("pragmas.sqlite"))
        let (mmap, cache) = try writer.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA mmap_size") ?? 0,
             try Int.fetchOne(db, sql: "PRAGMA cache_size") ?? 0)
        }
        XCTAssertEqual(mmap, 0)
        XCTAssertEqual(cache, -SQLiteConnectionPolicy.cacheSizeKiB)
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

    func testFileSecurityAssertsOwnerAndModeForDatabaseSiblings() throws {
        let source = try coreReadSource("Database/SQLiteConnectionPolicy.swift")
        let start = try XCTUnwrap(source.range(of: "public enum SQLiteFileSecurity"))
        let securitySource = String(source[start.lowerBound...])

        XCTAssertTrue(securitySource.contains("stat("))
        XCTAssertTrue(securitySource.contains("st_uid"))
        XCTAssertTrue(securitySource.contains("geteuid()"))
        XCTAssertTrue(securitySource.contains("0o600"))
    }

    private func databasePath(_ name: String) -> String {
        tempDir.appendingPathComponent(name).path
    }

    private func coreReadSource(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        while directory.lastPathComponent != "macos" {
            directory.deleteLastPathComponent()
        }
        let file = directory
            .appendingPathComponent("EngramCoreRead")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
