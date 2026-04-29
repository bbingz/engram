import Foundation
import GRDB

public struct SQLiteVecProbeResult: Equatable, Sendable {
    public let isAvailable: Bool
    public let version: String?
    public let unavailableReason: String?

    public init(isAvailable: Bool, version: String?, unavailableReason: String?) {
        self.isAvailable = isAvailable
        self.version = version
        self.unavailableReason = unavailableReason
    }
}

public enum SQLiteVecSupport {
    public static func probe() -> SQLiteVecProbeResult {
        guard let extensionPath = ProcessInfo.processInfo.environment["ENGRAM_SQLITE_VEC_EXTENSION_PATH"],
              !extensionPath.isEmpty else {
            return SQLiteVecProbeResult(
                isAvailable: false,
                version: nil,
                unavailableReason: "sqlite-vec extension path is not configured for Swift"
            )
        }

        return SQLiteVecProbeResult(
            isAvailable: false,
            version: nil,
            unavailableReason: "sqlite-vec extension loading is not implemented yet: \(extensionPath)"
        )
    }

    public static func probe(_ db: GRDB.Database) throws -> SQLiteVecProbeResult {
        do {
            let version = try String.fetchOne(db, sql: "SELECT vec_version()")
            return SQLiteVecProbeResult(
                isAvailable: version != nil,
                version: version,
                unavailableReason: version == nil ? "sqlite-vec returned no version" : nil
            )
        } catch {
            return SQLiteVecProbeResult(
                isAvailable: false,
                version: nil,
                unavailableReason: "sqlite-vec is not loaded for this SQLite connection: \(error.localizedDescription)"
            )
        }
    }
}
