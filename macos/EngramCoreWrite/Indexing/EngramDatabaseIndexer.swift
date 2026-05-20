import Foundation
import GRDB
import EngramCoreRead

public struct EngramDatabaseIndexStatus: Sendable, Equatable {
    public let total: Int
    public let todayParents: Int
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
        try await indexSessions(adapters: adapters)
    }

    func indexAllSessions(
        adapters: [any SessionAdapter] = SessionAdapterFactory.defaultAdapters()
    ) async throws -> EngramDatabaseIndexResult {
        try await indexSessions(adapters: adapters)
    }

    private func indexSessions(adapters: [any SessionAdapter]) async throws -> EngramDatabaseIndexResult {
        let indexer = SwiftIndexer(
            sink: EngramDatabaseIndexingSink(writer: self),
            adapters: adapters
        )
        let indexed = try await indexer.indexAll()

        try write { db in
            _ = try StartupBackfills.backfillPolycliProviderParents(db)
            _ = try StartupBackfills.backfillSuggestedParents(db)
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
                return EngramDatabaseIndexStatus(total: 0, todayParents: 0)
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
                  AND start_time >= ?
                """,
                arguments: [since]
            ) ?? 0
            return EngramDatabaseIndexStatus(total: total, todayParents: todayParents)
        }
    }
}
