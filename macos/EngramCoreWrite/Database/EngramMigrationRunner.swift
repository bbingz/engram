import Foundation
import GRDB

public enum EngramMigrationRunner {
    public static func migrate(_ db: GRDB.Database) throws {
        try EngramMigrations.createOrUpdateBaseSchema(db)
        try FTSRebuildPolicy.apply(db)
        // VectorRebuildPolicy is intentionally not invoked here: sqlite-vec is
        // not implemented in the shipped product, so there is no active
        // embedding model/dimension to gate a vector-table rebuild on. Wire it
        // in once sqlite-vec lands. See VectorRebuildPolicy doc comment.
        try EngramMigrations.writeSchemaMetadata(db)
    }
}
