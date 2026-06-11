import Foundation
import GRDB

public enum FTSRebuildPolicy {
    public static let expectedVersion = "3"
    private static let rebuildVersionKey = "fts_rebuild_version"
    private static let activeTable = "sessions_fts"
    private static let rebuildTable = "sessions_fts_rebuild"

    public static func apply(_ db: GRDB.Database) throws {
        let current = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = 'fts_version'"
        )
        guard current != expectedVersion else { return }

        if current == nil, try sessionCount(db) == 0 {
            try db.execute(sql: "DROP TABLE IF EXISTS \(rebuildTable)")
            try markCurrentVersion(db)
            try db.execute(sql: "DELETE FROM metadata WHERE key = ?", arguments: [rebuildVersionKey])
            return
        }

        let pending = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [rebuildVersionKey]
        )
        let rebuildTableMissing = try !tableExists(db, rebuildTable)
        let startedRebuild = pending != expectedVersion || rebuildTableMissing
        if startedRebuild {
            try db.execute(sql: "DROP TABLE IF EXISTS \(rebuildTable)")
            try createFtsTable(db, named: rebuildTable)
        }
        if try tableExists(db, "session_embeddings") {
            try db.execute(sql: "DELETE FROM session_embeddings")
        }
        if try tableExists(db, "vec_sessions") {
            try db.execute(sql: "DELETE FROM vec_sessions")
        }
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [rebuildVersionKey, expectedVersion]
        )
        // Keep the live FTS table serving search while the runner builds the
        // replacement table. Re-open the already-completed FTS jobs so unchanged
        // sessions are replayed into `sessions_fts_rebuild`.
        if startedRebuild, try tableExists(db, "session_index_jobs") {
            try db.execute(sql: """
                UPDATE session_index_jobs
                SET status = 'pending', retry_count = 0, last_error = NULL,
                    updated_at = datetime('now')
                WHERE job_kind = 'fts' AND status = 'completed'
            """)
        }
    }

    static func replaceFtsContent(_ db: GRDB.Database, sessionId: String, contents: [String]) throws {
        try replaceFtsContent(db, table: activeTable, sessionId: sessionId, contents: contents)
        if try rebuildIsPending(db) {
            try replaceFtsContent(db, table: rebuildTable, sessionId: sessionId, contents: contents)
        }
    }

    @discardableResult
    static func finalizeRebuildIfReady(_ db: GRDB.Database) throws -> Bool {
        guard try rebuildIsPending(db) else { return false }
        guard try tableExists(db, rebuildTable) else { return false }
        guard try recoverableFtsJobCount(db) == 0 else { return false }

        if try tableExists(db, activeTable) {
            try db.execute(sql: "DROP TABLE IF EXISTS sessions_fts_old")
            try db.execute(sql: "ALTER TABLE \(activeTable) RENAME TO sessions_fts_old")
        }
        try db.execute(sql: "ALTER TABLE \(rebuildTable) RENAME TO \(activeTable)")
        try db.execute(sql: "DROP TABLE IF EXISTS sessions_fts_old")
        try markCurrentVersion(db)
        try db.execute(sql: "DELETE FROM metadata WHERE key = ?", arguments: [rebuildVersionKey])
        return true
    }

    private static func markCurrentVersion(_ db: GRDB.Database) throws {
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('fts_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [expectedVersion]
        )
    }

    private static func createFtsTable(_ db: GRDB.Database, named table: String) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE \(table) USING fts5(
              session_id UNINDEXED,
              content,
              tokenize='trigram case_sensitive 0'
            )
        """)
    }

    private static func replaceFtsContent(
        _ db: GRDB.Database,
        table: String,
        sessionId: String,
        contents: [String]
    ) throws {
        try db.execute(sql: "DELETE FROM \(table) WHERE session_id = ?", arguments: [sessionId])
        for content in contents {
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            try db.execute(
                sql: "INSERT INTO \(table)(session_id, content) VALUES (?, ?)",
                arguments: [sessionId, content]
            )
        }
    }

    private static func rebuildIsPending(_ db: GRDB.Database) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [rebuildVersionKey]
        ) == expectedVersion
    }

    private static func recoverableFtsJobCount(_ db: GRDB.Database) throws -> Int {
        guard try tableExists(db, "session_index_jobs") else { return 0 }
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM session_index_jobs
            WHERE job_kind = 'fts' AND status IN ('pending', 'failed_retryable')
            """
        ) ?? 0
    }

    private static func sessionCount(_ db: GRDB.Database) throws -> Int {
        guard try tableExists(db, "sessions") else { return 0 }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0
    }

    private static func tableExists(_ db: GRDB.Database, _ table: String) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil
    }
}
