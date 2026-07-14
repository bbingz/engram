import Foundation
import GRDB
import EngramCoreRead
import os

public enum UsageParserBackfillPolicy {
    public static let metadataKey = "usage_parser_version"
    public static let currentVersion = "4"

    public static func needsBackfill(_ db: GRDB.Database) throws -> Bool {
        let stored = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [metadataKey]
        )
        return stored != currentVersion
    }

    public static func markComplete(_ db: GRDB.Database) throws {
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [metadataKey, currentVersion]
        )
    }
}

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
        log.warning("\(message, privacy: .private): \(String(describing: error), privacy: .private)")
    }
}

// MARK: - Indexing

public final class WriterStartupIndexing: StartupIndexing {
    private let writer: EngramDatabaseWriter
    private let adapters: [any SessionAdapter]
    public let usesInlineCountAndCostBackfills = true

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

    /// Cost rows are written directly by the indexer upsert; this pass only
    /// re-prices legacy zero-cost rows that already have token usage.
    public func backfillCosts() async throws -> Int {
        try writer.write { db in try StartupBackfills.backfillCosts(db) }
    }
}

// MARK: - Database maintenance

public extension EngramDatabaseWriter {
    /// Periodic-path bounded FTS merge: min-interval + content-signature gate.
    ///
    /// Throw-safe throttle: the attempt timestamp is committed in its own write
    /// **before** the merge step runs. A failing step (missing FTS tables,
    /// SQLITE_ERROR, etc.) still advances the 24h floor so the 5-minute loop
    /// does not retry every tick.
    @discardableResult
    func optimizeFtsIfDue(
        now: Date = Date(),
        minInterval: TimeInterval = StartupBackfills.ftsOptimizeMinInterval
    ) throws -> Bool {
        let due = try write { db in
            try StartupBackfills.isFtsOptimizeDue(db, now: now, minInterval: minInterval)
        }
        guard due else { return false }

        // Commit attempt before the rewrite so optimize throws cannot roll it back.
        try write { db in
            try StartupBackfills.recordFtsOptimizeAttempt(db, now: now)
        }

        do {
            return try write { db in
                try StartupBackfills.optimizeFts(db)
            }
        } catch {
            // A failed continuation must not bypass the attempt floor forever.
            try? write { db in
                try db.execute(
                    sql: "DELETE FROM metadata WHERE key = ?",
                    arguments: [StartupBackfills.ftsMergeInProgressKey]
                )
            }
            throw error
        }
    }
}

public final class WriterStartupBackfillDatabase: StartupBackfillDatabase {
    private let writer: EngramDatabaseWriter
    private let groupedDirRoots: @Sendable () -> [SourceRoot]

    public init(writer: EngramDatabaseWriter) {
        self.writer = writer
        groupedDirRoots = { SessionSources.roots() }
    }

    init(
        writer: EngramDatabaseWriter,
        groupedDirRoots: @escaping @Sendable () -> [SourceRoot]
    ) {
        self.writer = writer
        self.groupedDirRoots = groupedDirRoots
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
                WHERE hidden_at IS NULL
                  AND parent_session_id IS NULL
                  AND suggested_parent_id IS NULL
                  AND (tier IS NULL OR tier != 'skip')
                  AND start_time >= ?
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

    public func reconcileInsights() throws -> StartupInsightReconcileResult {
        try writer.write { db in try StartupBackfills.reconcileInsights(db) }
    }

    public func reconcileGroupedSourceDirs() throws -> GroupedDirReconcileResult {
        let storedVersion = try writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM metadata WHERE key = ?",
                arguments: [StartupBackfills.groupedDirReconcileMetadataKey]
            )
        }
        guard storedVersion != StartupBackfills.groupedDirReconcileVersion else {
            return GroupedDirReconcileResult()
        }

        let result = GroupedDirReconcile.run(roots: groupedDirRoots())
        // Filesystem repairs are idempotent. Stamp the version only after the
        // complete sweep so a crash retries instead of recording partial work.
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO metadata(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [
                    StartupBackfills.groupedDirReconcileMetadataKey,
                    StartupBackfills.groupedDirReconcileVersion,
                ]
            )
        }
        return result
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

    public func backfillCodexModelLabels() throws -> Int {
        try writer.write { db in try StartupBackfills.backfillCodexModelLabels(db) }
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

    public func reconcileSkipTierIndexArtifacts() throws -> Int {
        try writer.write { db in try StartupBackfills.reconcileSkipTierIndexArtifacts(db) }
    }

    public func pruneIndexJobs() throws -> Int {
        try writer.write { db in try StartupBackfills.pruneIndexJobs(db) }
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
    static let lastScanMetadataKey = "last_orphan_scan"

    private let writer: EngramDatabaseWriter
    private let gracePeriodDays: Int
    private let minimumScanInterval: TimeInterval

    public init(
        writer: EngramDatabaseWriter,
        gracePeriodDays: Int = 30,
        minimumScanInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.writer = writer
        self.gracePeriodDays = gracePeriodDays
        self.minimumScanInterval = minimumScanInterval
    }

    private struct OrphanRow {
        let id: String
        let source: String
        let locator: String
        let orphanStatus: String?
        let orphanSince: String?
    }

    public func detectOrphans(adapters: [any SessionAdapter]) async throws -> StartupOrphanScanResult {
        // The scan loads every session row and stats every locator on disk. Its
        // result is unchanged since the previous launch on a corpus that has not
        // moved, so skip it within a bounded interval (files that disappear are
        // detected on the next scan or the per-session recovery path).
        if try scanIsWithinMinimumInterval() {
            return StartupOrphanScanResult(scanned: 0, newlyFlagged: 0, confirmed: 0, recovered: 0, skipped: 0)
        }

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
        var skipped = 0
        let now = Date()
        let graceInterval = TimeInterval(gracePeriodDays) * 24 * 60 * 60

        // Phase 1 (ungated): probe each session's source file without holding the
        // write gate. The per-session `isAccessible` probe is I/O and was
        // previously interleaved with per-row `writer.write` calls, keeping the
        // write gate contended across the whole N-session scan. Collect the
        // intended state transitions here, then apply them in short gated batches.
        var recover: [String] = []
        var flagSuspect: [String] = []
        var confirmOrphan: [String] = []

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
                    recover.append(row.id)
                }
                continue
            }

            if row.orphanStatus == nil {
                flagSuspect.append(row.id)
                continue
            }

            if row.orphanStatus == "suspect", let since = row.orphanSince,
               let sinceDate = Self.parseSQLiteDate(since),
               now.timeIntervalSince(sinceDate) >= graceInterval {
                confirmOrphan.append(row.id)
            }
        }

        // Phase 2 (gated): apply the transitions in short batched writes so the
        // write gate is only held briefly per batch, never across the I/O probe.
        try await applyOrphanTransitions(
            recover: recover,
            flagSuspect: flagSuspect,
            confirmOrphan: confirmOrphan
        )
        try recordScanTimestamp()

        return StartupOrphanScanResult(
            scanned: scanned,
            newlyFlagged: flagSuspect.count,
            confirmed: confirmOrphan.count,
            recovered: recover.count,
            skipped: skipped
        )
    }

    /// Batch-applies orphan-state transitions in short gated writes. Each call to
    /// `writer.write` is one gated command, so chunking keeps the held window
    /// small. `Task.checkCancellation` runs between batches.
    private func applyOrphanTransitions(
        recover: [String],
        flagSuspect: [String],
        confirmOrphan: [String],
        batchSize: Int = 200
    ) async throws {
        for batch in recover.chunked(into: batchSize) {
            try Task.checkCancellation()
            try writer.write { db in
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET orphan_status = NULL, orphan_since = NULL, orphan_reason = NULL
                    WHERE id IN (\(Self.placeholders(batch.count)))
                    """,
                    arguments: StatementArguments(batch)
                )
            }
        }
        for batch in flagSuspect.chunked(into: batchSize) {
            try Task.checkCancellation()
            try writer.write { db in
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET orphan_status = 'suspect',
                        orphan_since = datetime('now'),
                        orphan_reason = COALESCE(orphan_reason, 'path_unreachable')
                    WHERE id IN (\(Self.placeholders(batch.count)))
                    """,
                    arguments: StatementArguments(batch)
                )
            }
        }
        for batch in confirmOrphan.chunked(into: batchSize) {
            try Task.checkCancellation()
            try writer.write { db in
                try db.execute(
                    sql: "UPDATE sessions SET orphan_status = 'confirmed' WHERE id IN (\(Self.placeholders(batch.count)))",
                    arguments: StatementArguments(batch)
                )
            }
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// True when a scan ran within `minimumScanInterval`. A missing/unparseable
    /// timestamp forces a scan (the safe default).
    private func scanIsWithinMinimumInterval() throws -> Bool {
        guard minimumScanInterval > 0 else { return false }
        let last = try writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM metadata WHERE key = ?",
                arguments: [Self.lastScanMetadataKey]
            )
        }
        guard let last, let lastDate = Self.parseSQLiteDate(last) else { return false }
        return Date().timeIntervalSince(lastDate) < minimumScanInterval
    }

    private func recordScanTimestamp() throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO metadata(key, value) VALUES (?, datetime('now'))
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [Self.lastScanMetadataKey]
            )
        }
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

private extension Array {
    /// Splits the array into consecutive slices of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
