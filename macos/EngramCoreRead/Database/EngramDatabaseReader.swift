import Foundation
import GRDB

public final class EngramDatabaseReader {
    private let pool: DatabasePool

    public init(path: String) throws {
        pool = try DatabasePool(
            path: path,
            configuration: SQLiteConnectionPolicy.readerConfiguration()
        )
    }

    public func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try pool.read(block)
    }
}
