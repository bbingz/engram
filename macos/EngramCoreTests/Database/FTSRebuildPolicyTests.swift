import EngramCoreRead
@testable import EngramCoreWrite
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
        XCTAssertEqual(counts.ftsRows, 1)
        XCTAssertEqual(counts.sessionsWithSize, 1)
        XCTAssertEqual(counts.sessionEmbeddings, 0)
        XCTAssertEqual(counts.vecSessions, 0)
        XCTAssertEqual(counts.sessionChunks, 1)
        XCTAssertEqual(counts.insights, 1)
        XCTAssertEqual(counts.insightsFts, 1)
        XCTAssertEqual(counts.ftsVersion, "2")
        XCTAssertEqual(counts.pendingFtsVersion, "3")
        XCTAssertTrue((try tableSQL(writer, "sessions_fts") ?? "").contains("CREATE VIRTUAL TABLE sessions_fts"))
        XCTAssertTrue(try tableExists(writer, "sessions_fts_rebuild"))
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

    func testFreshEmptyDatabaseMarksCurrentVersionWithoutShadowRebuild() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("fresh.sqlite"))
        try writer.migrate()

        let (ftsRows, ftsVersion, pendingFtsVersion) = try writer.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions_fts") ?? -1,
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_version'"),
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_rebuild_version'")
            )
        }
        XCTAssertEqual(ftsRows, 0)
        XCTAssertEqual(ftsVersion, "3")
        XCTAssertNil(pendingFtsVersion)
        XCTAssertFalse(try tableExists(writer, "sessions_fts_rebuild"))
    }

    // A version bump must not drop the live sessions_fts table before the rebuilt
    // table is ready. Re-open completed jobs and build into a shadow table first
    // so old keyword search results remain available during the rebuild window.
    func testRebuildReopensCompletedFtsJobsForReindex() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("reopen-fts.sqlite"))
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, cwd, file_path, size_bytes)
                VALUES ('s1', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/p', '/tmp/s.jsonl', 42);
                INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'still searchable while rebuilding');
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES ('s1:0::fts', 's1', 'fts', 0, 'completed');
                INSERT INTO metadata(key, value) VALUES ('fts_version', '2')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
        }

        try writer.write { db in try FTSRebuildPolicy.apply(db) }

        let (pending, completed) = try writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM session_index_jobs WHERE job_kind='fts' AND status='pending'") ?? -1,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM session_index_jobs WHERE job_kind='fts' AND status='completed'") ?? -1)
        }
        XCTAssertEqual(pending, 1, "completed FTS jobs must be re-opened so unchanged sessions get re-indexed")
        XCTAssertEqual(completed, 0)
        let liveRows = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 's1'")
        }
        XCTAssertEqual(liveRows, ["still searchable while rebuilding"])
        XCTAssertEqual(try writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions_fts_rebuild") }, 0)
    }

    func testFinalizeRebuildInvalidatesStoredOptimizeSignatureForSwappedTable_repro() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("finalize-fts-optimize.sqlite"))
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, cwd, file_path, size_bytes, sync_version, indexed_at)
                VALUES ('s1', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/p', '/tmp/s.jsonl', 42, 1, '2026-05-01T00:00:00Z');
                INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'legacy searchable row');
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES ('s1:1::fts', 's1', 'fts', 1, 'completed');
                INSERT INTO metadata(key, value) VALUES ('fts_version', '2')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
            try FTSRebuildPolicy.apply(db)

            try db.execute(sql: "INSERT INTO sessions_fts_rebuild(session_id, content) VALUES ('s1', 'rebuilt searchable row')")
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE id = 's1:1::fts'")

            // PR #142 regression: a completed full rebuild swaps in a new FTS
            // table without changing session aggregates, so it must invalidate
            // the stored optimize signature before the next optimize gate.
            XCTAssertTrue(try StartupBackfills.optimizeFts(db), "pre-finalize optimize stores the current content signature")
            XCTAssertFalse(try StartupBackfills.optimizeFts(db), "unchanged signature skips before the rebuild table is swapped in")

            XCTAssertTrue(try FTSRebuildPolicy.finalizeRebuildIfReady(db))
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 's1'"),
                ["rebuilt searchable row"]
            )
            XCTAssertTrue(try StartupBackfills.optimizeFts(db), "the swapped-in rebuild table must receive a fresh optimize pass")
        }
    }

    /// Wave 7A H01: permanent/N/A FTS jobs must not cause live keyword rows to
    /// disappear when a rebuild finalizes. Missing shadow rows are copied from live.
    func testFinalizeRebuildPreservesLiveRowsForPermanentFailures_repro() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("finalize-preserve-permanent.sqlite"))
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, cwd, file_path, size_bytes, sync_version, indexed_at, tier)
                VALUES
                  ('ok', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/p', '/tmp/ok.jsonl', 42, 1, '2026-05-01T00:00:00Z', 'normal'),
                  ('perm', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/p', '/tmp/perm.jsonl', 43, 1, '2026-05-01T00:00:00Z', 'normal');
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('ok', 'ok live'), ('perm', 'permanent live keyword');
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES
                  ('ok:1::fts', 'ok', 'fts', 1, 'completed'),
                  ('perm:1::fts', 'perm', 'fts', 1, 'failed_permanent');
                INSERT INTO metadata(key, value) VALUES ('fts_version', '2')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
            try FTSRebuildPolicy.apply(db)
            // Only the recoverable job is rebuilt into the shadow table.
            try db.execute(sql: "INSERT INTO sessions_fts_rebuild(session_id, content) VALUES ('ok', 'ok rebuilt')")
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE id = 'ok:1::fts'")
            // Permanent failure remains non-recoverable and is never reopened.
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE status = 'failed_permanent'") ?? 0,
                1
            )
            XCTAssertTrue(try FTSRebuildPolicy.finalizeRebuildIfReady(db))
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT session_id, content FROM sessions_fts ORDER BY session_id, content"
            )
            let bySession = Dictionary(grouping: rows, by: { $0["session_id"] as String })
            XCTAssertEqual(bySession["ok"]?.map { $0["content"] as String }, ["ok rebuilt"])
            XCTAssertEqual(
                bySession["perm"]?.map { $0["content"] as String },
                ["permanent live keyword"],
                "live keyword rows for permanent-failure sessions must survive rebuild swap"
            )
        }
    }

    func testInterruptedRebuildApplyResumesExistingShadowTable() throws {
        let writer = try EngramDatabaseWriter(path: databasePath("resume-fts.sqlite"))
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, cwd, file_path, size_bytes)
                VALUES
                  ('s1', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/p', '/tmp/s1.jsonl', 42),
                  ('s2', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/p', '/tmp/s2.jsonl', 43);
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('s1', 'legacy one'), ('s2', 'legacy two');
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES
                  ('s1:0::fts', 's1', 'fts', 0, 'completed'),
                  ('s2:0::fts', 's2', 'fts', 0, 'completed');
                INSERT INTO metadata(key, value) VALUES ('fts_version', '2')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
            try FTSRebuildPolicy.apply(db)
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'rebuilt one')")
            try db.execute(sql: "INSERT INTO sessions_fts_rebuild(session_id, content) VALUES ('s1', 'rebuilt one')")
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE session_id = 's1'")
        }

        try writer.write { db in try FTSRebuildPolicy.apply(db) }

        let state = try writer.read { db in
            (
                rebuildRows: try String.fetchAll(db, sql: "SELECT content FROM sessions_fts_rebuild ORDER BY content"),
                pendingJobs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE status = 'pending'") ?? -1,
                completedJobs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE status = 'completed'") ?? -1,
                pendingVersion: try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_rebuild_version'"),
                activeRows: try String.fetchAll(db, sql: "SELECT content FROM sessions_fts ORDER BY content")
            )
        }

        XCTAssertEqual(state.rebuildRows, ["rebuilt one"])
        XCTAssertEqual(state.pendingJobs, 1)
        XCTAssertEqual(state.completedJobs, 1)
        XCTAssertEqual(state.pendingVersion, FTSRebuildPolicy.expectedVersion)
        XCTAssertTrue(state.activeRows.contains("rebuilt one"))
        XCTAssertTrue(state.activeRows.contains("legacy two"))
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
        ftsVersion: String?,
        pendingFtsVersion: String?
    ) {
        try writer.read { db in
            let ftsRows = try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions_fts") ?? 0
            let sessionsWithSize = try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE size_bytes > 0") ?? 0
            let sessionEmbeddings = try Int.fetchOne(db, sql: "SELECT count(*) FROM session_embeddings") ?? 0
            let vecSessions = try Int.fetchOne(db, sql: "SELECT count(*) FROM vec_sessions") ?? 0
            let sessionChunks = try Int.fetchOne(db, sql: "SELECT count(*) FROM session_chunks") ?? 0
            let insights = try Int.fetchOne(db, sql: "SELECT count(*) FROM insights") ?? 0
            let insightsFts = try Int.fetchOne(db, sql: "SELECT count(*) FROM insights_fts") ?? 0
            let ftsVersion = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_version'")
            let pendingFtsVersion = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_rebuild_version'")
            return (
                ftsRows,
                sessionsWithSize,
                sessionEmbeddings,
                vecSessions,
                sessionChunks,
                insights,
                insightsFts,
                ftsVersion,
                pendingFtsVersion
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

    private func tableExists(_ writer: EngramDatabaseWriter, _ name: String) throws -> Bool {
        try tableSQL(writer, name) != nil
    }
}
