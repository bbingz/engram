import Foundation
import GRDB

public struct SQLiteSchemaSnapshot: Equatable {
    public let tableNames: Set<String>
    public let indexNames: Set<String>
    public let triggerNames: Set<String>
    public let metadataKeys: Set<String>
}

public enum SchemaIntrospection {
    public static func snapshot(_ db: GRDB.Database) throws -> SQLiteSchemaSnapshot {
        let tables = try String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            """
        )
        let indexes = try String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'index' AND name NOT LIKE 'sqlite_%'
            """
        )
        let triggers = try String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'trigger' AND name NOT LIKE 'sqlite_%'
            """
        )
        let metadata = try String.fetchAll(db, sql: "SELECT key FROM metadata")
        return SQLiteSchemaSnapshot(
            tableNames: Set(tables),
            indexNames: Set(indexes),
            triggerNames: Set(triggers),
            metadataKeys: Set(metadata)
        )
    }
}
