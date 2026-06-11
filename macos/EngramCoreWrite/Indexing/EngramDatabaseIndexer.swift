import Foundation
import GRDB
import EngramCoreRead

public struct EngramDatabaseIndexStatus: Sendable, Equatable {
    public let total: Int
    public let todayParents: Int
    /// Distinguishes a healthy empty database (`schemaPresent == true, total == 0`)
    /// from a degraded one where the `sessions` table is absent
    /// (`schemaPresent == false`). The read-only status command tolerates the
    /// degraded case (reports total:0); the composition root fails fast via
    /// `verifySchemaPresent()`.
    public let schemaPresent: Bool

    public init(total: Int, todayParents: Int, schemaPresent: Bool = true) {
        self.total = total
        self.todayParents = todayParents
        self.schemaPresent = schemaPresent
    }
}

/// Thrown by `verifySchemaPresent()` when the `sessions` table does not exist.
/// The composition root treats this as fatal — migrations should have created
/// the schema before the service starts serving.
public enum EngramDatabaseIndexStatusError: Error, CustomStringConvertible {
    case missingSchema

    public var description: String {
        switch self {
        case .missingSchema:
            return "sessions table is absent; schema migration has not run"
        }
    }
}

public struct EngramDatabaseIndexResult: Sendable, Equatable {
    public let indexed: Int
    public let total: Int
    public let todayParents: Int
}

private final class EngramDatabaseIndexingSink: IndexingWriteSink {
    private let writer: EngramDatabaseWriter

    init(writer: EngramDatabaseWriter) {
        self.writer = writer
    }

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        try writer.write { db in
            try SessionBatchUpsert(db: db).upsertBatch(snapshots, reason: reason)
        }
    }

    func knownIndexedFileStates(source: SourceName, locators: [String]) throws -> [String: KnownIndexedFileState] {
        guard !locators.isEmpty else { return [:] }
        return try writer.read { db in
            try Self.knownIndexedFileStates(db, source: source, locators: locators)
        }
    }

    private static func knownIndexedFileStates(
        _ db: Database,
        source: SourceName,
        locators: [String]
    ) throws -> [String: KnownIndexedFileState] {
        var states: [String: KnownIndexedFileState] = [:]
        for batch in stride(from: 0, to: locators.count, by: 500) {
            let slice = Array(locators[batch..<Swift.min(batch + 500, locators.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            var arguments: StatementArguments = [source.rawValue]
            for locator in slice {
                arguments += [locator]
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT COALESCE(source_locator, file_path) AS locator, size_bytes, indexed_at
                FROM sessions
                WHERE source = ?
                  AND COALESCE(source_locator, file_path) IN (\(placeholders))
                """,
                arguments: arguments
            )
            for row in rows {
                let locator = row["locator"] as String? ?? ""
                guard !locator.isEmpty else { continue }
                if let size = row["size_bytes"] as Int64? {
                    states[locator] = KnownIndexedFileState(sizeBytes: size, indexedAt: row["indexed_at"])
                }
            }
        }
        return states
    }
}

public extension EngramDatabaseWriter {
    func indexRecentSessions(
        adapters: [any SessionAdapter] = SessionAdapterFactory.recentActiveAdapters()
    ) async throws -> EngramDatabaseIndexResult {
        try await indexSessions(adapters: adapters, runParentBackfills: false, skipUnchangedFileLocators: true)
    }

    func indexAllSessions(
        adapters: [any SessionAdapter] = SessionAdapterFactory.defaultAdapters()
    ) async throws -> EngramDatabaseIndexResult {
        try await indexSessions(adapters: adapters, runParentBackfills: true, skipUnchangedFileLocators: false)
    }

    /// Run the deterministic parent-link backfills after a periodic scan so
    /// agent/dispatched child sessions created mid-run are grouped under their
    /// parent (and skip-tiered) without waiting for a service restart. The
    /// periodic `indexRecentSessions` path indexes with `runParentBackfills:
    /// false`, so without this the periodic scan leaves new children top-level
    /// until the next restart.
    func runPeriodicParentBackfills() throws {
        try write { db in
            _ = try StartupBackfills.backfillParentLinks(db)
            _ = try StartupBackfills.backfillCodexOriginator(db)
            _ = try StartupBackfills.backfillPolycliProviderParents(db)
            _ = try StartupBackfills.backfillSuggestedParents(db)
        }
    }

    private func indexSessions(
        adapters: [any SessionAdapter],
        runParentBackfills: Bool,
        skipUnchangedFileLocators: Bool
    ) async throws -> EngramDatabaseIndexResult {
        let indexer = SwiftIndexer(
            sink: EngramDatabaseIndexingSink(writer: self),
            adapters: adapters,
            skipUnchangedFileLocators: skipUnchangedFileLocators
        )
        let indexed = try await indexer.indexAll()

        if runParentBackfills {
            try write { db in
                _ = try StartupBackfills.backfillPolycliProviderParents(db)
                _ = try StartupBackfills.backfillSuggestedParents(db)
            }
        }

        let status = try indexStatus()
        return EngramDatabaseIndexResult(
            indexed: indexed,
            total: status.total,
            todayParents: status.todayParents
        )
    }

    func indexStatus(now: Date = Date()) throws -> EngramDatabaseIndexStatus {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let since = ISO8601DateFormatter().string(from: startOfToday)
        return try read { db in
            let hasSessions = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sessions')"
            ) ?? false
            guard hasSessions else {
                // Degraded: schema absent. The read-only status path tolerates
                // this (total:0); the composition root rejects it via
                // verifySchemaPresent(). This is NOT a silent empty-DB result —
                // schemaPresent is false so callers can distinguish.
                return EngramDatabaseIndexStatus(total: 0, todayParents: 0, schemaPresent: false)
            }
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions WHERE hidden_at IS NULL"
            ) ?? 0
            let todayParents = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM sessions
                WHERE hidden_at IS NULL
                  AND parent_session_id IS NULL
                  AND suggested_parent_id IS NULL
                  AND (tier IS NULL OR tier != 'skip')
                  AND start_time >= ?
                """,
                arguments: [since]
            ) ?? 0
            return EngramDatabaseIndexStatus(total: total, todayParents: todayParents)
        }
    }

    /// Composition-root fail-fast check: throws `.missingSchema` when the
    /// `sessions` table is absent after migration was supposed to run.
    func verifySchemaPresent() throws {
        let status = try indexStatus()
        guard status.schemaPresent else {
            throw EngramDatabaseIndexStatusError.missingSchema
        }
    }
}
