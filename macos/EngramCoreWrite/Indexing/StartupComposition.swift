import Foundation
import GRDB
import EngramCoreRead
import os

/// Production conformers that wire the unit-tested `StartupBackfills` static
/// functions into a real `EngramDatabaseWriter` so the composition root
/// (`EngramServiceRunner`) can run the initial scan once on startup.
///
/// These are thin wrappers: each method forwards to the corresponding static
/// `StartupBackfills.*` function (or to the indexer / job runner) inside a
/// `writer.write` / `writer.read` block.

// MARK: - Logging

public final class OSLogStartupBackfillLogging: StartupBackfillLogging {
    private let log = os.Logger(subsystem: "com.engram.service", category: "startup-backfill")

    public init() {}

    public func warn(_ message: String, error: Error) {
        log.warning("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
    }
}

// MARK: - Indexing

public final class WriterStartupIndexing: StartupIndexing {
    private let writer: EngramDatabaseWriter
    private let adapters: [any SessionAdapter]

    public init(writer: EngramDatabaseWriter, adapters: [any SessionAdapter]) {
        self.writer = writer
        self.adapters = adapters
    }

    public func indexAll() async throws -> Int {
        let result = try await writer.indexAllSessions(adapters: adapters)
        return result.indexed
    }

    /// Message counts are written directly by the indexer upsert; there is no
    /// separate Swift count-backfill pass.
    public func backfillCounts() async throws -> Int { 0 }

    /// Cost computation has no Swift provider; zero-cost rows are seeded during
    /// indexing. No separate backfill pass.
    public func backfillCosts() async throws -> Int { 0 }
}

// MARK: - Database maintenance

public final class WriterStartupBackfillDatabase: StartupBackfillDatabase {
    private let writer: EngramDatabaseWriter

    public init(writer: EngramDatabaseWriter) {
        self.writer = writer
    }

    public func countSessions() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE hidden_at IS NULL") ?? 0
        }
    }

    public func countTodayParentSessions() throws -> Int {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let since = ISO8601DateFormatter().string(from: startOfToday)
        return try writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM sessions
                WHERE hidden_at IS NULL AND parent_session_id IS NULL AND start_time >= ?
                """,
                arguments: [since]
            ) ?? 0
        }
    }

    public func backfillScores() throws -> Int {
        try writer.write { db in try StartupBackfills.backfillScores(db) }
    }

    public func deduplicateFilePaths() throws -> Int {
        try writer.write { db in try StartupBackfills.deduplicateFilePaths(db) }
    }

    public func optimizeFts() throws {
        try writer.write { db in try StartupBackfills.optimizeFts(db) }
    }

    public func vacuumIfNeeded(_ fragmentationPercent: Int) throws -> Bool {
        try writer.write { db in try StartupBackfills.vacuumIfNeeded(db, fragmentationPercent: fragmentationPercent) }
    }

    public func reconcileInsights() throws -> StartupInsightReconcileResult {
        try writer.write { db in try StartupBackfills.reconcileInsights(db) }
    }

    public func backfillFilePaths() throws -> Int {
        try writer.write { db in try StartupBackfills.backfillFilePaths(db) }
    }

    public func downgradeSubagentTiers() throws -> Int {
        try writer.write { db in try StartupBackfills.downgradeSubagentTiers(db) }
    }

    public func backfillParentLinks() throws -> StartupBackfills.ParentLinkResult {
        try writer.write { db in try StartupBackfills.backfillParentLinks(db) }
    }

    public func resetStaleDetections() throws -> Int {
        try writer.write { db in try StartupBackfills.resetStaleDetections(db) }
    }

    public func backfillCodexOriginator() throws -> Int {
        try writer.write { db in try StartupBackfills.backfillCodexOriginator(db) }
    }

    public func backfillPolycliProviderParents() throws -> StartupBackfills.ProviderParentResult {
        try writer.write { db in try StartupBackfills.backfillPolycliProviderParents(db) }
    }

    public func backfillSuggestedParents() throws -> StartupBackfills.SuggestedParentResult {
        try writer.write { db in try StartupBackfills.backfillSuggestedParents(db) }
    }

    public func enqueueStaleFtsJobs() throws -> Int {
        try writer.write { db in try StartupBackfills.enqueueStaleFtsJobs(db) }
    }

    public func cleanupStaleMigrations() throws -> Int {
        try writer.write { db in try StartupBackfills.cleanupStaleMigrations(db) }
    }
}

// MARK: - Orphan scanning

/// Detects sessions whose on-disk source file is no longer accessible and
/// applies a conservative state machine, mirroring `src/core/db/maintenance.ts`
/// `detectOrphans`. Recovers (clears) flags when a file reappears.
public final class WriterStartupOrphanScanning: StartupOrphanScanning {
    private let writer: EngramDatabaseWriter
    private let gracePeriodDays: Int

    public init(writer: EngramDatabaseWriter, gracePeriodDays: Int = 30) {
        self.writer = writer
        self.gracePeriodDays = gracePeriodDays
    }

    private struct OrphanRow {
        let id: String
        let source: String
        let locator: String
        let orphanStatus: String?
        let orphanSince: String?
    }

    public func detectOrphans(adapters: [any SessionAdapter]) async throws -> StartupOrphanScanResult {
        let adaptersBySource = Dictionary(adapters.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })

        let rows = try writer.read { db -> [OrphanRow] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, source, orphan_status, orphan_since,
                  COALESCE(NULLIF(file_path, ''), source_locator) AS locator
                FROM sessions
                WHERE (source_locator IS NOT NULL AND source_locator != '')
                   OR (file_path IS NOT NULL AND file_path != '')
                """
            ).map { row in
                OrphanRow(
                    id: row["id"],
                    source: row["source"],
                    locator: row["locator"] ?? "",
                    orphanStatus: row["orphan_status"],
                    orphanSince: row["orphan_since"]
                )
            }
        }

        var scanned = 0
        var newlyFlagged = 0
        var confirmed = 0
        var recovered = 0
        var skipped = 0
        let now = Date()
        let graceInterval = TimeInterval(gracePeriodDays) * 24 * 60 * 60

        for row in rows {
            try Task.checkCancellation()
            scanned += 1
            guard let sourceName = SourceName(rawValue: row.source),
                  let adapter = adaptersBySource[sourceName],
                  !row.locator.isEmpty,
                  !row.locator.hasPrefix("sync://")
            else {
                skipped += 1
                continue
            }

            let accessible = await adapter.isAccessible(locator: row.locator)

            if accessible {
                if row.orphanStatus != nil {
                    try writer.write { db in
                        try db.execute(
                            sql: """
                            UPDATE sessions
                            SET orphan_status = NULL, orphan_since = NULL, orphan_reason = NULL
                            WHERE id = ?
                            """,
                            arguments: [row.id]
                        )
                    }
                    recovered += 1
                }
                continue
            }

            if row.orphanStatus == nil {
                try writer.write { db in
                    try db.execute(
                        sql: """
                        UPDATE sessions
                        SET orphan_status = 'suspect',
                            orphan_since = datetime('now'),
                            orphan_reason = COALESCE(orphan_reason, 'path_unreachable')
                        WHERE id = ?
                        """,
                        arguments: [row.id]
                    )
                }
                newlyFlagged += 1
                continue
            }

            if row.orphanStatus == "suspect", let since = row.orphanSince,
               let sinceDate = Self.parseSQLiteDate(since),
               now.timeIntervalSince(sinceDate) >= graceInterval {
                try writer.write { db in
                    try db.execute(
                        sql: "UPDATE sessions SET orphan_status = 'confirmed' WHERE id = ?",
                        arguments: [row.id]
                    )
                }
                confirmed += 1
            }
        }

        return StartupOrphanScanResult(
            scanned: scanned,
            newlyFlagged: newlyFlagged,
            confirmed: confirmed,
            recovered: recovered,
            skipped: skipped
        )
    }

    /// Parses SQLite `datetime('now')` output ("YYYY-MM-DD HH:MM:SS", UTC).
    static func parseSQLiteDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: value) {
            return date
        }
        let iso = ISO8601DateFormatter()
        return iso.date(from: value)
    }
}
