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
}

public extension EngramDatabaseWriter {
    func indexRecentSessions(
        adapters: [any SessionAdapter] = SessionAdapterFactory.recentActiveAdapters()
    ) async throws -> EngramDatabaseIndexResult {
        try await indexSessions(adapters: adapters, runParentBackfills: false)
    }

    func indexAllSessions(
        adapters: [any SessionAdapter] = SessionAdapterFactory.defaultAdapters()
    ) async throws -> EngramDatabaseIndexResult {
        try await indexSessions(adapters: adapters, runParentBackfills: true)
    }

    private func indexSessions(
        adapters: [any SessionAdapter],
        runParentBackfills: Bool
    ) async throws -> EngramDatabaseIndexResult {
        let indexer = SwiftIndexer(
            sink: EngramDatabaseIndexingSink(writer: self),
            adapters: adapters
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
