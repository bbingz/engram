import Foundation
import GRDB

public enum VectorRebuildPolicy {
    public static func apply(
        _ db: GRDB.Database,
        expectedDimension: Int,
        activeModel: String
    ) throws {
        let storedDimension = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = 'vec_dimension'"
        )
        let storedModel = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = 'vec_model'"
        )

        let dimensionMismatch = storedDimension.map { Int($0) != expectedDimension } ?? false
        let modelMismatch = storedModel.map { $0 == "__pending_rebuild__" || $0 != activeModel } ?? false

        if dimensionMismatch || modelMismatch {
            try dropIfExists(db, "vec_sessions")
            try dropIfExists(db, "vec_chunks")
            try dropIfExists(db, "vec_insights")
            try deleteIfExists(db, "session_embeddings")
            try deleteIfExists(db, "session_chunks")
        }

        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('vec_dimension', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [String(expectedDimension)]
        )
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('vec_model', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [activeModel]
        )
    }

    private static func deleteIfExists(_ db: GRDB.Database, _ table: String) throws {
        guard try tableExists(db, table) else { return }
        try db.execute(sql: "DELETE FROM \(table)")
    }

    private static func dropIfExists(_ db: GRDB.Database, _ table: String) throws {
        guard try tableExists(db, table) else { return }
        try db.execute(sql: "DROP TABLE \(table)")
    }

    private static func tableExists(_ db: GRDB.Database, _ table: String) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil
    }
}
