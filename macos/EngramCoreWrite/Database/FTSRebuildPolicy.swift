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
