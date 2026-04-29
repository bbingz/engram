import EngramCoreWrite
import GRDB
import XCTest

final class VectorRebuildPolicyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-vector-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testUnavailableSqliteVecReturnsTypedDiagnostic() {
        let support = SQLiteVecSupport.probe()
        XCTAssertFalse(support.isAvailable)
        XCTAssertNotNil(support.unavailableReason)
    }

    func testDimensionMismatchClearsVectorStateButPreservesMemoryInsights() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("dimension.sqlite"))
        try writer.migrate()
        try seedVectorState(writer, dimension: "384", model: "current")

        try writer.write { db in
            try VectorRebuildPolicy.apply(db, expectedDimension: 768, activeModel: "current")
        }

        let counts = try vectorCounts(writer)
        XCTAssertEqual(counts.sessionEmbeddings, 0)
        XCTAssertEqual(counts.sessionChunks, 0)
        XCTAssertEqual(counts.vecSessionsExists, false)
        XCTAssertEqual(counts.vecChunksExists, false)
        XCTAssertEqual(counts.vecInsightsExists, false)
        XCTAssertEqual(counts.memoryInsights, 1)
        XCTAssertEqual(counts.dimension, "768")
    }

    func testCompatibleMetadataIsNoOp() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("compatible.sqlite"))
        try writer.migrate()
        try seedVectorState(writer, dimension: "768", model: "current")

        try writer.write { db in
            try VectorRebuildPolicy.apply(db, expectedDimension: 768, activeModel: "current")
        }

        let counts = try vectorCounts(writer)
        XCTAssertEqual(counts.sessionEmbeddings, 1)
        XCTAssertEqual(counts.sessionChunks, 1)
        XCTAssertEqual(counts.memoryInsights, 1)
    }

    func testPendingModelRebuildClearsVectorState() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("pending.sqlite"))
        try writer.migrate()
        try seedVectorState(writer, dimension: "768", model: "__pending_rebuild__")

        try writer.write { db in
            try VectorRebuildPolicy.apply(db, expectedDimension: 768, activeModel: "current")
        }

        let counts = try vectorCounts(writer)
        XCTAssertEqual(counts.sessionEmbeddings, 0)
        XCTAssertEqual(counts.sessionChunks, 0)
        XCTAssertEqual(counts.memoryInsights, 1)
        XCTAssertEqual(counts.model, "current")
    }

    func testModelMismatchClearsVectorState() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("model-mismatch.sqlite"))
        try writer.migrate()
        try seedVectorState(writer, dimension: "768", model: "previous-model")

        try writer.write { db in
            try VectorRebuildPolicy.apply(db, expectedDimension: 768, activeModel: "current")
        }

        let counts = try vectorCounts(writer)
        XCTAssertEqual(counts.sessionEmbeddings, 0)
        XCTAssertEqual(counts.sessionChunks, 0)
        XCTAssertEqual(counts.memoryInsights, 1)
        XCTAssertEqual(counts.model, "current")
    }

    func testMissingVectorMetadataInitializesExpectedValues() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("fresh-vector.sqlite"))
        try writer.migrate()

        try writer.write { db in
            try VectorRebuildPolicy.apply(db, expectedDimension: 768, activeModel: "current")
        }

        let counts = try vectorCounts(writer)
        XCTAssertEqual(counts.dimension, "768")
        XCTAssertEqual(counts.model, "current")
    }

    private func seedVectorState(
        _ writer: EngramDatabaseWriter,
        dimension: String,
        model: String
    ) throws {
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_embeddings(session_id TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS session_chunks(chunk_id TEXT PRIMARY KEY, session_id TEXT, text TEXT);
                CREATE TABLE IF NOT EXISTS memory_insights(id TEXT PRIMARY KEY, content TEXT);
                CREATE TABLE IF NOT EXISTS vec_sessions(session_id TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS vec_chunks(chunk_id TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS vec_insights(insight_id TEXT PRIMARY KEY);
                INSERT INTO session_embeddings(session_id) VALUES ('s1');
                INSERT INTO session_chunks(chunk_id, session_id, text) VALUES ('c1', 's1', 'keep');
                INSERT INTO memory_insights(id, content) VALUES ('m1', 'keep memory');
                INSERT INTO vec_sessions(session_id) VALUES ('s1');
                INSERT INTO vec_chunks(chunk_id) VALUES ('c1');
                INSERT INTO vec_insights(insight_id) VALUES ('m1');
                INSERT INTO metadata(key, value) VALUES ('vec_dimension', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                INSERT INTO metadata(key, value) VALUES ('vec_model', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, arguments: [dimension, model])
        }
    }

    private func vectorCounts(_ writer: EngramDatabaseWriter) throws -> (
        sessionEmbeddings: Int,
        sessionChunks: Int,
        memoryInsights: Int,
        vecSessionsExists: Bool,
        vecChunksExists: Bool,
        vecInsightsExists: Bool,
        dimension: String?,
        model: String?
    ) {
        try writer.read { db in
            (
                try countIfTableExists(db, "session_embeddings"),
                try countIfTableExists(db, "session_chunks"),
                try countIfTableExists(db, "memory_insights"),
                try tableExists(db, "vec_sessions"),
                try tableExists(db, "vec_chunks"),
                try tableExists(db, "vec_insights"),
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'vec_dimension'"),
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'vec_model'")
            )
        }
    }

    private func countIfTableExists(_ db: GRDB.Database, _ table: String) throws -> Int {
        guard try tableExists(db, table) else { return 0 }
        return try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
    }

    private func tableExists(_ db: GRDB.Database, _ table: String) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil
    }

    private func databasePath(_ name: String) -> String {
        tempDir.appendingPathComponent(name).path
    }
}
