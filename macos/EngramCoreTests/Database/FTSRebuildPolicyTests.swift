import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

final class FTSRebuildPolicyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-fts-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testOldFTSVersionRebuildPreservesSessionMetadata() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("old-fts.sqlite"))
        try writer.migrate()
        try seedRebuildState(writer, ftsVersion: "2")

        try writer.write { db in
            try FTSRebuildPolicy.apply(db)
        }

        let counts = try readCounts(writer)
        XCTAssertEqual(counts.ftsRows, 0)
        XCTAssertEqual(counts.sessionsWithSize, 1)
        XCTAssertEqual(counts.sessionEmbeddings, 0)
        XCTAssertEqual(counts.vecSessions, 0)
        XCTAssertEqual(counts.sessionChunks, 1)
        XCTAssertEqual(counts.insights, 1)
        XCTAssertEqual(counts.insightsFts, 1)
        XCTAssertEqual(counts.ftsVersion, "3")
        XCTAssertTrue((try tableSQL(writer, "sessions_fts") ?? "").contains("CREATE VIRTUAL TABLE sessions_fts"))
    }

    func testCurrentFTSVersionIsNoOp() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("current-fts.sqlite"))
        try writer.migrate()
        try seedRebuildState(writer, ftsVersion: "3")

        try writer.write { db in
            try FTSRebuildPolicy.apply(db)
        }

        let counts = try readCounts(writer)
        XCTAssertEqual(counts.ftsRows, 1)
        XCTAssertEqual(counts.sessionsWithSize, 1)
        XCTAssertEqual(counts.sessionChunks, 1)
        XCTAssertEqual(counts.insights, 1)
        XCTAssertEqual(counts.insightsFts, 1)
    }

    private func seedRebuildState(_ writer: EngramDatabaseWriter, ftsVersion: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, cwd, file_path, size_bytes)
                VALUES ('s1', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/project', '/tmp/session.jsonl', 42);
                INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'hello');
                CREATE TABLE IF NOT EXISTS session_embeddings(session_id TEXT PRIMARY KEY);
                INSERT INTO session_embeddings(session_id) VALUES ('s1');
                CREATE TABLE IF NOT EXISTS vec_sessions(session_id TEXT PRIMARY KEY);
                INSERT INTO vec_sessions(session_id) VALUES ('s1');
                CREATE TABLE IF NOT EXISTS session_chunks(chunk_id TEXT PRIMARY KEY, session_id TEXT, text TEXT);
                INSERT INTO session_chunks(chunk_id, session_id, text) VALUES ('c1', 's1', 'keep');
                INSERT INTO insights(id, content) VALUES ('i1', 'keep insight');
                INSERT INTO insights_fts(insight_id, content) VALUES ('i1', 'keep insight');
                INSERT INTO metadata(key, value) VALUES ('fts_version', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, arguments: [ftsVersion])
        }
    }

    private func readCounts(_ writer: EngramDatabaseWriter) throws -> (
        ftsRows: Int,
        sessionsWithSize: Int,
        sessionEmbeddings: Int,
        vecSessions: Int,
        sessionChunks: Int,
        insights: Int,
        insightsFts: Int,
        ftsVersion: String?
    ) {
        try writer.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions_fts") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE size_bytes > 0") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM session_embeddings") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM vec_sessions") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM session_chunks") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM insights") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM insights_fts") ?? 0,
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_version'")
            )
        }
    }

    private func databasePath(_ name: String) -> String {
        tempDir.appendingPathComponent(name).path
    }

    private func tableSQL(_ writer: EngramDatabaseWriter, _ name: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [name]
            )
        }
    }
}
