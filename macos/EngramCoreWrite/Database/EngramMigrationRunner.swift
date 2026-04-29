import Foundation
import GRDB

public enum EngramMigrationRunner {
    public static func migrate(_ db: GRDB.Database) throws {
        try EngramMigrations.createOrUpdateBaseSchema(db)
        try FTSRebuildPolicy.apply(db)
        try EngramMigrations.writeSchemaMetadata(db)
    }
}
