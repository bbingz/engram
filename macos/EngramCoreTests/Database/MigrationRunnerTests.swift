import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

final class MigrationRunnerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-migrations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testCreatesFreshCurrentSchema() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("fresh.sqlite"))
        try writer.migrate()

        let snapshot = try writer.read { db in
            try SchemaIntrospection.snapshot(db)
        }

        XCTAssertTrue(SchemaManifest.baseTables.isSubset(of: snapshot.tableNames))
        XCTAssertTrue(SchemaManifest.requiredMetadataKeys.isSubset(of: snapshot.metadataKeys))
    }

    func testMigrationIsIdempotentAcrossRepeatedRuns() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("idempotent.sqlite"))

        try writer.migrate()
        try writer.migrate()
        try writer.migrate()

        let metadata = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'schema_version'")
        }
        XCTAssertEqual(metadata, "1")
    }

    func testPreservesExistingSessionRows() throws {
        let path = databasePath("legacy.sqlite")
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  start_time TEXT NOT NULL,
                  cwd TEXT NOT NULL DEFAULT '',
                  file_path TEXT NOT NULL
                );
                INSERT INTO sessions(id, source, start_time, cwd, file_path)
                VALUES ('legacy-1', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/project', '/tmp/session.jsonl');
            """)
        }

        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()

        let rowCount = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE id = 'legacy-1'") ?? 0
        }
        XCTAssertEqual(rowCount, 1)
    }

    private func databasePath(_ name: String) -> String {
        tempDir.appendingPathComponent(name).path
    }
}
