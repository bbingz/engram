import Foundation
import GRDB

public enum FTSRebuildPolicy {
    public static let expectedVersion = "3"

    public static func apply(_ db: GRDB.Database) throws {
        let current = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = 'fts_version'"
        )
        guard current != expectedVersion else { return }

        try db.execute(sql: "DROP TABLE IF EXISTS sessions_fts")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE sessions_fts USING fts5(
              session_id UNINDEXED,
              content,
              tokenize='trigram case_sensitive 0'
            )
        """)
        if try tableExists(db, "session_embeddings") {
            try db.execute(sql: "DELETE FROM session_embeddings")
        }
        if try tableExists(db, "vec_sessions") {
            try db.execute(sql: "DELETE FROM vec_sessions")
        }
        // The FTS table was just dropped and recreated empty. `enqueueStaleFtsJobs`
        // only re-enqueues sessions whose content version changed, so without this
        // every UNCHANGED session would stay absent from search until it next
        // changes. Re-open the already-completed FTS jobs so IndexJobRunner
        // re-indexes every previously-indexed session into the fresh table.
        if try tableExists(db, "session_index_jobs") {
            try db.execute(sql: """
                UPDATE session_index_jobs
                SET status = 'pending', retry_count = 0, last_error = NULL,
                    updated_at = datetime('now')
                WHERE job_kind = 'fts' AND status = 'completed'
            """)
        }
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('fts_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [expectedVersion]
        )
    }

    private static func tableExists(_ db: GRDB.Database, _ table: String) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil
    }
}
