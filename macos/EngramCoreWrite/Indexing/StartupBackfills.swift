import Foundation
import GRDB
import EngramCoreRead

public struct StartupBackfillEvent: Equatable, Sendable {
    public var event: String
    public var payload: [String: JSONValue]

    public init(event: String, payload: [String: JSONValue] = [:]) {
        self.event = event
        self.payload = payload
    }
}

public struct StartupInsightReconcileResult: Equatable, Sendable {
    public var resetEmbedding: Int
    public var orphanedVector: Int

    public init(resetEmbedding: Int, orphanedVector: Int) {
        self.resetEmbedding = resetEmbedding
        self.orphanedVector = orphanedVector
    }
}

public struct StartupIndexJobRecoveryResult: Equatable, Sendable {
    public var completed: Int
    public var notApplicable: Int

    public init(completed: Int, notApplicable: Int) {
        self.completed = completed
        self.notApplicable = notApplicable
    }
}

public struct StartupOrphanScanResult: Equatable, Sendable {
    public var scanned: Int
    public var newlyFlagged: Int
    public var confirmed: Int
    public var recovered: Int
    public var skipped: Int

    public init(scanned: Int, newlyFlagged: Int, confirmed: Int, recovered: Int, skipped: Int) {
        self.scanned = scanned
        self.newlyFlagged = newlyFlagged
        self.confirmed = confirmed
        self.recovered = recovered
        self.skipped = skipped
    }
}

public protocol StartupBackfillLogging: AnyObject {
    func warn(_ message: String, error: Error)
}

public protocol StartupUsageCollecting: AnyObject {
    func start()
}

public protocol StartupIndexing: AnyObject {
    var usesInlineCountAndCostBackfills: Bool { get }
    func indexAll() async throws -> Int
    func backfillCounts() async throws -> Int
    func backfillCosts() async throws -> Int
}

public extension StartupIndexing {
    var usesInlineCountAndCostBackfills: Bool { false }
}

public protocol StartupIndexJobRunning: AnyObject {
    func runRecoverableJobs() async throws -> StartupIndexJobRecoveryResult
    func backfillInsightEmbeddings() async throws -> Int
}

public protocol StartupOrphanScanning: AnyObject {
    func detectOrphans(adapters: [any SessionAdapter]) async throws -> StartupOrphanScanResult
}

public protocol StartupBackfillDatabase: AnyObject {
    func countSessions() throws -> Int
    func countTodayParentSessions() throws -> Int
    func backfillScores() throws -> Int
    func deduplicateFilePaths() throws -> Int
    func optimizeFts() throws
    func vacuumIfNeeded(_ fragmentationPercent: Int) throws -> Bool
    func reconcileInsights() throws -> StartupInsightReconcileResult
    func reconcileGroupedSourceDirs() throws -> GroupedDirReconcileResult
    func backfillFilePaths() throws -> Int
    func downgradeSubagentTiers() throws -> Int
    func backfillParentLinks() throws -> StartupBackfills.ParentLinkResult
    func resetStaleDetections() throws -> Int
    func backfillCodexOriginator() throws -> Int
    func backfillPolycliProviderParents() throws -> StartupBackfills.ProviderParentResult
    func backfillSuggestedParents() throws -> StartupBackfills.SuggestedParentResult
    func enqueueStaleFtsJobs() throws -> Int
    func reconcileSkipTierIndexArtifacts() throws -> Int
    func pruneIndexJobs() throws -> Int
    func cleanupStaleMigrations() throws -> Int
}

public enum StartupBackfills {
    public struct ParentLinkResult: Equatable, Sendable {
        public var linked: Int

        public init(linked: Int) {
            self.linked = linked
        }
    }

    public struct SuggestedParentResult: Equatable, Sendable {
        public var checked: Int
        public var suggested: Int

        public init(checked: Int, suggested: Int) {
            self.checked = checked
            self.suggested = suggested
        }
    }

    public struct ProviderParentResult: Equatable, Sendable {
        public var checked: Int
        public var classified: Int
        public var linked: Int
        public var suggested: Int

        public init(checked: Int, classified: Int, linked: Int, suggested: Int = 0) {
            self.checked = checked
            self.classified = classified
            self.linked = linked
            self.suggested = suggested
        }
    }

    /// Full startup scan: structural backfills followed by the FTS-job drain.
    /// Kept as a single entry point (and exercised whole by tests); the product
    /// service instead calls `runStartupBackfills` and `drainStartupIndexJobs`
    /// in separate gated write commands so the write gate is released between the
    /// (long) structural scan and the (chunked) drain.
    public static func runInitialScan(
        emit: (StartupBackfillEvent) -> Void,
        log: any StartupBackfillLogging,
        usageCollector: any StartupUsageCollecting,
        indexer: any StartupIndexing,
        indexJobRunner: any StartupIndexJobRunning,
        database: any StartupBackfillDatabase,
        orphanScanner: any StartupOrphanScanning,
        adapters: [any SessionAdapter] = []
    ) async throws {
        try await runStartupBackfills(
            emit: emit,
            log: log,
            indexer: indexer,
            database: database,
            orphanScanner: orphanScanner,
            adapters: adapters
        )
        try await drainStartupIndexJobs(
            emit: emit,
            log: log,
            usageCollector: usageCollector,
            indexJobRunner: indexJobRunner
        )
    }

    /// Structural startup backfills: index, maintenance, parent-link detection,
    /// emit "ready", orphan scan, and enqueue stale FTS jobs. Does NOT drain the
    /// FTS backlog (see `drainStartupIndexJobs`), so the caller can run the drain
    /// in separate gated write commands.
    public static func runStartupBackfills(
        emit: (StartupBackfillEvent) -> Void,
        log: any StartupBackfillLogging,
        indexer: any StartupIndexing,
        database: any StartupBackfillDatabase,
        orphanScanner: any StartupOrphanScanning,
        adapters: [any SessionAdapter] = []
    ) async throws {
        let indexed = try await runStartupIndex(indexer: indexer)
        try await runStartupMaintenanceAndParents(
            indexed: indexed,
            emit: emit,
            log: log,
            indexer: indexer,
            database: database
        )
        try await runStartupOrphanScan(
            emit: emit,
            log: log,
            orphanScanner: orphanScanner,
            database: database,
            adapters: adapters
        )
    }

    /// Phase 1 of the structural startup scan: (re)index recent sessions. This
    /// is the heaviest step (it re-parses session files), so the product service
    /// runs it as its own gated write command and releases the write gate before
    /// the maintenance/parent phase — letting user writes interleave instead of
    /// waiting out the whole scan.
    public static func runStartupIndex(indexer: any StartupIndexing) async throws -> Int {
        try await indexer.indexAll()
    }

    /// Phase 2: count/cost/score backfills, DB maintenance, parent-link
    /// detection, migration cleanup, and the "ready" emit. Takes the indexed
    /// count from phase 1.
    public static func runStartupMaintenanceAndParents(
        indexed: Int,
        emit: (StartupBackfillEvent) -> Void,
        log: any StartupBackfillLogging,
        indexer: any StartupIndexing,
        database: any StartupBackfillDatabase
    ) async throws {
        do {
            let backfilled = try await indexer.backfillCounts()
            if backfilled > 0 {
                emit(StartupBackfillEvent(event: "backfill_counts", payload: ["backfilled": .int(backfilled)]))
            } else if indexer.usesInlineCountAndCostBackfills {
                emit(StartupBackfillEvent(event: "backfill_inline", payload: ["type": .string("counts")]))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.warn("backfill counts failed", error: error)
        }

        do {
            let costBackfilled = try await indexer.backfillCosts()
            if costBackfilled > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("costs"), "count": .int(costBackfilled)]))
            } else if indexer.usesInlineCountAndCostBackfills {
                emit(StartupBackfillEvent(event: "backfill_inline", payload: ["type": .string("costs")]))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.warn("backfill costs failed", error: error)
        }

        do {
            let scoreBackfilled = try database.backfillScores()
            if scoreBackfilled > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("scores"), "count": .int(scoreBackfilled)]))
            }
        } catch {
            log.warn("backfill scores failed", error: error)
        }

        do {
            let deduped = try database.deduplicateFilePaths()
            if deduped > 0 {
                emit(StartupBackfillEvent(event: "db_maintenance", payload: ["action": .string("dedup"), "removed": .int(deduped)]))
            }
            try database.optimizeFts()
        } catch {
            log.warn("db maintenance failed", error: error)
        }

        do {
            if try database.vacuumIfNeeded(15) {
                emit(StartupBackfillEvent(event: "db_maintenance", payload: ["action": .string("vacuum")]))
            }
        } catch {
            log.warn("db vacuum failed", error: error)
        }

        do {
            let reconciled = try database.reconcileInsights()
            if reconciled.resetEmbedding > 0 || reconciled.orphanedVector > 0 {
                emit(
                    StartupBackfillEvent(
                        event: "db_maintenance",
                        payload: [
                            "action": .string("reconcile_insights"),
                            "resetEmbedding": .int(reconciled.resetEmbedding),
                            "orphanedVector": .int(reconciled.orphanedVector)
                        ]
                    )
                )
            }
        } catch {
            log.warn("db insight reconcile failed", error: error)
        }

        do {
            let grouped = try database.reconcileGroupedSourceDirs()
            if grouped.scannedDirs > 0 || grouped.plannedRenames > 0 || grouped.appliedRenames > 0
                || grouped.collisions > 0 || grouped.ambiguous > 0 || grouped.issues > 0 {
                emit(
                    StartupBackfillEvent(
                        event: "db_maintenance",
                        payload: [
                            "action": .string("reconcile_grouped_dirs"),
                            "scanned": .int(grouped.scannedDirs),
                            "planned": .int(grouped.plannedRenames),
                            "applied": .int(grouped.appliedRenames),
                            "collisions": .int(grouped.collisions),
                            "ambiguous": .int(grouped.ambiguous),
                            "issues": .int(grouped.issues)
                        ]
                    )
                )
            }
        } catch {
            log.warn("db grouped source dir reconcile failed", error: error)
        }

        do {
            let pathsFixed = try database.backfillFilePaths()
            if pathsFixed > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("file_paths"), "count": .int(pathsFixed)]))
            }
        } catch {
            emit(StartupBackfillEvent(event: "error", payload: ["message": .string("backfillFilePaths: \(error)")]))
        }

        do {
            let downgraded = try database.downgradeSubagentTiers()
            if downgraded > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("subagent_tier_downgrade"), "count": .int(downgraded)]))
            }
            let parentLinks = try database.backfillParentLinks()
            if parentLinks.linked > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("parent_links"), "linked": .int(parentLinks.linked)]))
            }
            let detectionReset = try database.resetStaleDetections()
            if detectionReset > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("detection_reset"), "count": .int(detectionReset)]))
            }
            let originatorUpdated = try database.backfillCodexOriginator()
            if originatorUpdated > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("codex_originator"), "updated": .int(originatorUpdated)]))
            }
            let providerParents = try database.backfillPolycliProviderParents()
            if providerParents.classified > 0 || providerParents.linked > 0 || providerParents.suggested > 0 {
                emit(
                    StartupBackfillEvent(
                        event: "backfill",
                        payload: [
                            "type": .string("polycli_provider_parents"),
                            "checked": .int(providerParents.checked),
                            "classified": .int(providerParents.classified),
                            "linked": .int(providerParents.linked),
                            "suggested": .int(providerParents.suggested)
                        ]
                    )
                )
            }
            let suggestions = try database.backfillSuggestedParents()
            if suggestions.suggested > 0 {
                emit(
                    StartupBackfillEvent(
                        event: "backfill",
                        payload: [
                            "type": .string("suggested_parents"),
                            "checked": .int(suggestions.checked),
                            "suggested": .int(suggestions.suggested)
                        ]
                    )
                )
            }
        } catch {
            log.warn("parent link backfill failed", error: error)
        }

        do {
            let stale = try database.cleanupStaleMigrations()
            if stale > 0 {
                emit(StartupBackfillEvent(event: "migration_cleanup", payload: ["stale": .int(stale)]))
            }
        } catch {
            log.warn("migration cleanup failed", error: error)
        }

        emit(
            StartupBackfillEvent(
                event: "ready",
                payload: [
                    "indexed": .int(indexed),
                    "total": .int(try database.countSessions()),
                    "todayParents": .int(try database.countTodayParentSessions())
                ]
            )
        )
    }

    /// Phase 3: orphan scan + stale-FTS-job enqueue. Runs after "ready" so the
    /// service is already answering reads; gated separately so its per-row
    /// writes don't hold the write gate across the whole structural scan.
    public static func runStartupOrphanScan(
        emit: (StartupBackfillEvent) -> Void,
        log: any StartupBackfillLogging,
        orphanScanner: any StartupOrphanScanning,
        database: any StartupBackfillDatabase,
        adapters: [any SessionAdapter]
    ) async throws {
        do {
            let orphanScan = try await orphanScanner.detectOrphans(adapters: adapters)
            if orphanScan.newlyFlagged > 0 || orphanScan.confirmed > 0 || orphanScan.recovered > 0 {
                emit(
                    StartupBackfillEvent(
                        event: "orphan_scan",
                        payload: [
                            "scanned": .int(orphanScan.scanned),
                            "newly_flagged": .int(orphanScan.newlyFlagged),
                            "confirmed": .int(orphanScan.confirmed),
                            "recovered": .int(orphanScan.recovered),
                            "skipped": .int(orphanScan.skipped)
                        ]
                    )
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.warn("orphan scan failed", error: error)
        }

        do {
            let staleFtsJobs = try database.enqueueStaleFtsJobs()
            if staleFtsJobs > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("stale_fts_jobs"), "count": .int(staleFtsJobs)]))
            }
        } catch {
            log.warn("stale fts job enqueue failed", error: error)
        }

        do {
            let reconciled = try database.reconcileSkipTierIndexArtifacts()
            if reconciled > 0 {
                emit(StartupBackfillEvent(event: "db_maintenance", payload: ["action": .string("reconcile_skip_fts"), "removed": .int(reconciled)]))
            }
        } catch {
            log.warn("skip-tier index reconcile failed", error: error)
        }

        do {
            let pruned = try database.pruneIndexJobs()
            if pruned > 0 {
                emit(StartupBackfillEvent(event: "db_maintenance", payload: ["action": .string("prune_index_jobs"), "removed": .int(pruned)]))
            }
        } catch {
            log.warn("index job prune failed", error: error)
        }
    }

    /// Drain the FTS backlog enqueued by `runStartupBackfills`, then start the
    /// usage collector. Separate from the structural scan so the product service
    /// can run it in its own gated write command(s) and release the write gate
    /// between batches.
    public static func drainStartupIndexJobs(
        emit: (StartupBackfillEvent) -> Void,
        log: any StartupBackfillLogging,
        usageCollector: any StartupUsageCollecting,
        indexJobRunner: any StartupIndexJobRunning
    ) async throws {
        do {
            let jobSummary = try await indexJobRunner.runRecoverableJobs()
            if jobSummary.completed > 0 || jobSummary.notApplicable > 0 {
                emit(
                    StartupBackfillEvent(
                        event: "index_jobs_recovered",
                        payload: ["completed": .int(jobSummary.completed), "notApplicable": .int(jobSummary.notApplicable)]
                    )
                )
            }
            let promoted = try await indexJobRunner.backfillInsightEmbeddings()
            if promoted > 0 {
                emit(StartupBackfillEvent(event: "insights_promoted", payload: ["count": .int(promoted)]))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.warn("index job recovery failed", error: error)
        }

        usageCollector.start()
    }

    public static func backfillScores(_ db: Database) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, user_message_count, assistant_message_count, tool_message_count, system_message_count,
                   start_time, end_time, project
            FROM sessions
            WHERE (quality_score IS NULL OR quality_score = 0)
              AND tier != 'skip'
              AND (user_message_count > 0 OR assistant_message_count > 0)
            """
        )
        guard !rows.isEmpty else { return 0 }

        for row in rows {
            let score = computeQualityScore(
                userCount: row["user_message_count"],
                assistantCount: row["assistant_message_count"],
                toolCount: row["tool_message_count"],
                systemCount: row["system_message_count"],
                startTime: row["start_time"],
                endTime: row["end_time"],
                project: row["project"]
            )
            try db.execute(sql: "UPDATE sessions SET quality_score = ? WHERE id = ?", arguments: [score, row["id"]])
        }
        return rows.count
    }

    public static func backfillCosts(_ db: Database) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT c.session_id,
                   COALESCE(NULLIF(c.model, ''), NULLIF(s.model, '')) AS model,
                   COALESCE(c.input_tokens, 0) AS input_tokens,
                   COALESCE(c.output_tokens, 0) AS output_tokens,
                   COALESCE(c.cache_read_tokens, 0) AS cache_read_tokens,
                   COALESCE(c.cache_creation_tokens, 0) AS cache_creation_tokens
            FROM session_costs c
            LEFT JOIN sessions s ON s.id = c.session_id
            WHERE COALESCE(c.cost_usd, 0) = 0
              AND (
                COALESCE(c.input_tokens, 0) > 0
                OR COALESCE(c.output_tokens, 0) > 0
                OR COALESCE(c.cache_read_tokens, 0) > 0
                OR COALESCE(c.cache_creation_tokens, 0) > 0
              )
            """
        )
        guard !rows.isEmpty else { return 0 }

        var changed = 0
        for row in rows {
            let model: String? = row["model"]
            let usage = TokenUsage(
                inputTokens: row["input_tokens"],
                outputTokens: row["output_tokens"],
                cacheReadTokens: row["cache_read_tokens"],
                cacheCreationTokens: row["cache_creation_tokens"]
            )
            let costUSD = SessionCostPricing.computeCost(model: model, usage: usage)
            guard costUSD > 0 else { continue }

            try db.execute(
                sql: """
                UPDATE session_costs
                SET model = NULLIF(?, ''),
                    cost_usd = ?,
                    computed_at = datetime('now')
                WHERE session_id = ?
                """,
                arguments: [model ?? "", costUSD, row["session_id"]]
            )
            changed += 1
        }
        return changed
    }

    public static func deduplicateFilePaths(_ db: Database) throws -> Int {
        let duplicateMappingSQL = """
            WITH keepers AS (
              SELECT file_path, MAX(rowid) AS keep_rowid
              FROM sessions
              WHERE file_path IS NOT NULL
                AND file_path != ''
              GROUP BY file_path
            ),
            duplicates AS (
              SELECT duplicate.id AS old_id, keeper.id AS keep_id
              FROM sessions duplicate
              JOIN keepers ON keepers.file_path = duplicate.file_path
              JOIN sessions keeper ON keeper.rowid = keepers.keep_rowid
              WHERE duplicate.rowid != keepers.keep_rowid
            )
            """
        try db.execute(
            sql: """
            \(duplicateMappingSQL)
            UPDATE sessions
            SET parent_session_id = (
              SELECT keep_id FROM duplicates WHERE old_id = sessions.parent_session_id
            )
            WHERE parent_session_id IN (SELECT old_id FROM duplicates)
            """
        )
        try db.execute(
            sql: """
            \(duplicateMappingSQL)
            UPDATE sessions
            SET suggested_parent_id = (
              SELECT keep_id FROM duplicates WHERE old_id = sessions.suggested_parent_id
            )
            WHERE suggested_parent_id IN (SELECT old_id FROM duplicates)
            """
        )
        let removed = try db.executeAndCountChanges(
            sql: """
            DELETE FROM sessions
            WHERE rowid NOT IN (SELECT MAX(rowid) FROM sessions GROUP BY file_path)
              AND file_path IS NOT NULL
              AND file_path != ''
            """
        )
        // The DELETE above leaves orphaned sessions_fts rows behind (FTS is an
        // external-content-style table keyed by session_id, with no cascade), so
        // reconcile them in the same transaction.
        if removed > 0 {
            try db.execute(
                sql: "DELETE FROM sessions_fts WHERE session_id NOT IN (SELECT id FROM sessions)"
            )
        }
        return removed
    }

    static let ftsOptimizeSignatureKey = "fts_optimize_signature"

    /// FTS5 'optimize' merges every b-tree segment into one — a full read+rewrite
    /// of the (multi-hundred-MB) index. Running it unconditionally on every launch
    /// re-merged an unchanged index and stalled user writes queued behind the held
    /// write gate. Gate it on a cheap content signature stored in `metadata`: skip
    /// entirely when no FTS-eligible content changed since the last optimize.
    /// Content the drain writes AFTER this call is consolidated on the next launch
    /// whose signature differs — an acceptable one-launch lag, since a permanently
    /// idle corpus has no search-perf pressure. Returns true when optimize ran.
    @discardableResult
    public static func optimizeFts(_ db: Database) throws -> Bool {
        let signature = try ftsContentSignature(db)
        let stored = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [ftsOptimizeSignatureKey]
        )
        guard stored != signature else { return false }

        try db.execute(sql: "INSERT INTO sessions_fts(sessions_fts) VALUES('optimize')")
        try db.execute(sql: "INSERT INTO insights_fts(insights_fts) VALUES('optimize')")
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [ftsOptimizeSignatureKey, signature]
        )
        return true
    }

    /// Cheap proxy for "has FTS-eligible content changed since last optimize":
    /// aggregates over the small, indexed `sessions`/`insights` rows (sub-ms) and
    /// never touches the FTS index itself. Non-skip sessions own the sessions_fts
    /// rows; sync_version/indexed_at advance on every content re-index.
    private static func ftsContentSignature(_ db: Database) throws -> String {
        let sessions = try Row.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) AS n,
                   COALESCE(SUM(sync_version), 0) AS v,
                   COALESCE(MAX(indexed_at), '') AS m
            FROM sessions
            WHERE COALESCE(tier, 'normal') != 'skip'
            """
        )
        let insights = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*) AS n, COALESCE(MAX(created_at), '') AS m FROM insights"
        )
        let sn: Int = sessions?["n"] ?? 0
        let sv: Int = sessions?["v"] ?? 0
        let sm: String = sessions?["m"] ?? ""
        let inN: Int = insights?["n"] ?? 0
        let inM: String = insights?["m"] ?? ""
        return "\(sn):\(sv):\(sm):\(inN):\(inM)"
    }

    /// Cross-session sweep pruning terminal `session_index_jobs` rows that
    /// accumulate unbounded once a session stops changing (one hot session held
    /// 10,783). Keeps every in-flight row plus the most-recent terminal row per
    /// (session, kind). Complements the per-insert same-session delete in
    /// `SessionSnapshotWriter.insertIndexJobs`, which only fires as a given
    /// session is re-indexed.
    public static func pruneIndexJobs(_ db: Database) throws -> Int {
        try db.executeAndCountChanges(
            sql: """
            DELETE FROM session_index_jobs
            WHERE status NOT IN ('pending', 'failed_retryable')
              AND rowid NOT IN (
                SELECT MAX(rowid)
                FROM session_index_jobs
                WHERE status NOT IN ('pending', 'failed_retryable')
                GROUP BY session_id, job_kind
              )
            """
        )
    }

    /// Deletes index artifacts for any session whose CURRENT tier is 'skip'.
    /// Today FTS/embedding rows are only removed on the non-skip→skip transition
    /// (`SessionSnapshotWriter.shouldDeleteIndexArtifacts`), so sessions first
    /// classified as skip — or skip rows predating that cleanup — leak stale FTS
    /// rows. DELETE-only: it never modifies tier, so the subagent/skip invariant
    /// holds. Because `sessions_fts.session_id` is UNINDEXED, the batched DELETE
    /// is a full-FTS scan, so only pay it when a skip-tier session still owns an
    /// fts/embedding job — a cheap, index-backed staleness signal. The obsolete
    /// jobs are then cleared so the signal is empty (and this scan skipped) next
    /// launch.
    public static func reconcileSkipTierIndexArtifacts(_ db: Database) throws -> Int {
        let hasStale = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
              SELECT 1
              FROM session_index_jobs j
              JOIN sessions s ON s.id = j.session_id
              WHERE j.job_kind IN ('fts', 'embedding')
                AND COALESCE(s.tier, 'normal') = 'skip'
            )
            """
        ) ?? false
        guard hasStale else { return 0 }

        let skipSubquery = "SELECT id FROM sessions WHERE COALESCE(tier, 'normal') = 'skip'"
        let deletedFts = try db.executeAndCountChanges(
            sql: "DELETE FROM sessions_fts WHERE session_id IN (\(skipSubquery))"
        )
        var deletedFtsMap = 0
        if try tableExists(db, "fts_map") {
            deletedFtsMap = try db.executeAndCountChanges(
                sql: "DELETE FROM fts_map WHERE session_id IN (\(skipSubquery))"
            )
        }
        if try tableExists(db, "session_embeddings") {
            try db.execute(
                sql: "DELETE FROM session_embeddings WHERE session_id IN (\(skipSubquery))"
            )
        }
        try db.execute(
            sql: """
            DELETE FROM session_index_jobs
            WHERE job_kind IN ('fts', 'embedding')
              AND session_id IN (\(skipSubquery))
            """
        )
        return deletedFts + deletedFtsMap
    }

    public static func vacuumIfNeeded(_ db: Database, fragmentationPercent: Int) throws -> Bool {
        let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
        let freeCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        guard pageCount > 0 else { return false }
        let fragmentation = (Double(freeCount) / Double(pageCount)) * 100
        if fragmentation > Double(fragmentationPercent) {
            try db.execute(sql: "VACUUM")
            return true
        }
        return false
    }

    public static func reconcileInsights(_ db: Database) throws -> StartupInsightReconcileResult {
        do {
            let resetEmbedding = try db.executeAndCountChanges(
                sql: """
                UPDATE insights
                SET has_embedding = 0
                WHERE has_embedding = 1
                  AND id NOT IN (SELECT id FROM memory_insights WHERE deleted_at IS NULL)
                """
            )
            // Guard against an empty/partial `insights` table wiping the entire
            // vector store: `id NOT IN (SELECT id FROM insights)` is true for every
            // row when `insights` is empty. Only soft-delete orphaned vectors when
            // the text table actually has rows to reconcile against.
            let orphanedVector = try db.executeAndCountChanges(
                sql: """
                UPDATE memory_insights
                SET deleted_at = datetime('now')
                WHERE deleted_at IS NULL
                  AND EXISTS (SELECT 1 FROM insights)
                  AND id NOT IN (SELECT id FROM insights)
                """
            )
            return StartupInsightReconcileResult(resetEmbedding: resetEmbedding, orphanedVector: orphanedVector)
        } catch {
            if "\(error)".contains("no such table") {
                return StartupInsightReconcileResult(resetEmbedding: 0, orphanedVector: 0)
            }
            throw error
        }
    }

    public static func backfillFilePaths(_ db: Database) throws -> Int {
        let sessionPaths = try db.executeAndCountChanges(
            sql: """
            UPDATE sessions SET file_path = source_locator
            WHERE (file_path IS NULL OR file_path = '')
              AND source_locator IS NOT NULL
              AND source_locator != ''
              AND source_locator NOT LIKE 'sync://%'
            """
        )

        let localPaths = try db.executeAndCountChanges(
            sql: """
            UPDATE session_local_state
            SET local_readable_path = (
              SELECT COALESCE(
                NULLIF(CASE WHEN source_locator LIKE 'sync://%' THEN '' ELSE source_locator END, ''),
                NULLIF(CASE WHEN file_path LIKE 'sync://%' THEN '' ELSE file_path END, '')
              )
              FROM sessions
              WHERE id = session_local_state.session_id
            )
            WHERE (local_readable_path IS NULL OR local_readable_path = '')
              AND EXISTS (
                SELECT 1
                FROM sessions
                WHERE id = session_local_state.session_id
                  AND COALESCE(
                    NULLIF(CASE WHEN source_locator LIKE 'sync://%' THEN '' ELSE source_locator END, ''),
                    NULLIF(CASE WHEN file_path LIKE 'sync://%' THEN '' ELSE file_path END, '')
                  ) IS NOT NULL
              )
            """
        )

        return sessionPaths + localPaths
    }

    public static func cleanupStaleMigrations(_ db: Database) throws -> Int {
        try MigrationLogStore.cleanupStaleMigrations(db)
    }

    public static func enqueueStaleFtsJobs(_ db: Database) throws -> Int {
        try db.executeAndCountChanges(
            sql: """
            INSERT INTO session_index_jobs (
                id, session_id, job_kind, target_sync_version, status,
                retry_count, last_error, created_at, updated_at
            )
            SELECT
                s.id || ':' || s.sync_version || ':' || s.snapshot_hash || ':fts',
                s.id,
                'fts',
                s.sync_version,
                'pending',
                0,
                NULL,
                datetime('now'),
                datetime('now')
            FROM sessions s
            WHERE COALESCE(s.tier, 'normal') != 'skip'
              AND COALESCE(s.snapshot_hash, '') != ''
              AND EXISTS (
                SELECT 1
                FROM session_index_jobs old
                WHERE old.session_id = s.id
                  AND old.job_kind = 'fts'
                  AND old.status = 'completed'
              )
              AND NOT EXISTS (
                SELECT 1
                FROM session_index_jobs current
                WHERE current.id = s.id || ':' || s.sync_version || ':' || s.snapshot_hash || ':fts'
              )
            """
        )
    }

    public static func downgradeSubagentTiers(_ db: Database) throws -> Int {
        let changed = try db.executeAndCountChanges(
            sql: """
            UPDATE sessions SET tier = 'skip'
            WHERE agent_role = 'subagent' AND tier != 'skip'
            """
        )
        try deleteRecoverableIndexArtifactsForSkippedSessions(db, whereClause: "agent_role = 'subagent'")
        return changed
    }

    private static func deleteRecoverableIndexArtifactsForSkippedSession(_ db: Database, sessionId: String) throws {
        try db.execute(
            sql: "DELETE FROM sessions_fts WHERE session_id = ?",
            arguments: [sessionId]
        )
        if try tableExists(db, "session_embeddings") {
            try db.execute(
                sql: "DELETE FROM session_embeddings WHERE session_id = ?",
                arguments: [sessionId]
            )
        }
        try db.execute(
            sql: """
            DELETE FROM session_index_jobs
            WHERE session_id = ?
              AND status IN ('pending', 'failed_retryable')
            """,
            arguments: [sessionId]
        )
    }

    private static func deleteRecoverableIndexArtifactsForSkippedSessions(
        _ db: Database,
        whereClause: String
    ) throws {
        try db.execute(
            sql: """
            DELETE FROM sessions_fts
            WHERE session_id IN (SELECT id FROM sessions WHERE \(whereClause))
            """
        )
        if try tableExists(db, "session_embeddings") {
            try db.execute(
                sql: """
                DELETE FROM session_embeddings
                WHERE session_id IN (SELECT id FROM sessions WHERE \(whereClause))
                """
            )
        }
        try db.execute(
            sql: """
            DELETE FROM session_index_jobs
            WHERE session_id IN (SELECT id FROM sessions WHERE \(whereClause))
              AND status IN ('pending', 'failed_retryable')
            """
        )
    }

    private static func tableExists(_ db: Database, _ table: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [table]
        ) ?? false
    }

    public static func backfillParentLinks(_ db: Database) throws -> ParentLinkResult {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, file_path FROM sessions
            WHERE agent_role = 'subagent'
              AND parent_session_id IS NULL
              AND (link_source IS NULL OR link_source != 'manual')
            LIMIT 500
            """
        )

        var linked = 0
        let regex = try NSRegularExpression(pattern: #"/([^/]+)/subagents/[^/]+\.jsonl$"#)
        for row in rows {
            let id: String = row["id"]
            let filePath: String = row["file_path"]
            guard let match = regex.firstMatch(in: filePath, range: NSRange(filePath.startIndex..., in: filePath)),
                  let range = Range(match.range(at: 1), in: filePath)
            else {
                continue
            }
            let parentId = String(filePath[range])
            guard try validateParentLink(db, sessionId: id, parentId: parentId) else {
                continue
            }
            try setParentSession(db, sessionId: id, parentId: parentId, linkSource: "path")
            linked += 1
        }

        return ParentLinkResult(linked: linked)
    }

    public static func resetStaleDetections(_ db: Database) throws -> Int {
        let stored = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = 'detection_version'"
        ).flatMap(Int.init) ?? 0
        guard stored < ParentDetection.detectionVersion else {
            return 0
        }

        let resetUnchecked = try db.executeAndCountChanges(
            sql: """
            UPDATE sessions
            SET link_checked_at = NULL
            WHERE link_checked_at IS NOT NULL
              AND parent_session_id IS NULL
              AND suggested_parent_id IS NULL
              AND (link_source IS NULL OR link_source != 'manual')
              AND source IN ('gemini-cli', 'codex')
            """
        )
        let resetDispatched = try db.executeAndCountChanges(
            sql: """
            UPDATE sessions
            SET link_checked_at = NULL
            WHERE link_checked_at IS NOT NULL
              AND agent_role = 'dispatched'
              AND parent_session_id IS NULL
              AND suggested_parent_id IS NULL
              AND (link_source IS NULL OR link_source != 'manual')
            """
        )
        try db.execute(
            sql: """
            INSERT INTO metadata (key, value) VALUES ('detection_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: ["\(ParentDetection.detectionVersion)"]
        )
        return resetUnchecked + resetDispatched
    }

    public static func backfillCodexOriginator(_ db: Database) throws -> Int {
        var updated = 0
        while true {
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, file_path FROM sessions
                WHERE source = 'codex'
                  AND agent_role IS NULL
                  AND parent_session_id IS NULL
                  AND suggested_parent_id IS NULL
                  AND (link_source IS NULL OR link_source != 'manual')
                  AND link_checked_at IS NULL
                ORDER BY rowid
                LIMIT 500
                """
            )
            guard !rows.isEmpty else { break }

            for row in rows {
                let id: String = row["id"]
                let filePath: String = row["file_path"]
                guard let firstLine = readFirstLine(path: filePath, maxBytes: 16_384),
                      let data = firstLine.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      payload["originator"] as? String == "Claude Code"
                else {
                    try db.execute(
                        sql: "UPDATE sessions SET link_checked_at = datetime('now') WHERE id = ?",
                        arguments: [id]
                    )
                    continue
                }
                let changes = try db.executeAndCountChanges(
                    sql: """
                    UPDATE sessions
                    SET agent_role = 'dispatched', tier = 'skip', link_checked_at = NULL
                    WHERE id = ?
                    """,
                    arguments: [id]
                )
                if changes > 0 {
                    try deleteRecoverableIndexArtifactsForSkippedSession(db, sessionId: id)
                }
                updated += changes
            }
        }
        return updated
    }

    public static func backfillPolycliProviderParents(_ db: Database) throws -> ProviderParentResult {
        let candidates = try Row.fetchAll(
            db,
            sql: """
            SELECT id, source, start_time, cwd, summary, agent_role
            FROM sessions
            WHERE parent_session_id IS NULL
              AND (link_source IS NULL OR link_source != 'manual')
              AND link_checked_at IS NULL
              AND source IN ('claude-code', 'copilot', 'gemini-cli', 'kimi', 'opencode', 'pi', 'qwen')
              AND (
                summary LIKE 'You are acting as % inside polycli.%'
                OR summary LIKE 'Reply with POLYCLI_HEALTH_OK only.%'
                OR lower(trim(summary)) IN (
                  'ping',
                  'quick ping',
                  'test ping',
                  'quick ping check',
                  'ping-pong test'
                )
                -- The bare review-content match is a PROVIDER probe behavior, so
                -- exclude 'claude-code': otherwise a genuine claude-code session
                -- whose summary merely mentions "review" was mis-classified as a
                -- dispatched provider child and hidden.
                OR (
                  source != 'claude-code'
                  AND (lower(summary) LIKE '%review%' OR lower(summary) LIKE '%re-review%')
                )
                OR lower(summary) LIKE 'no tools.%stage %'
                OR (
                  source IN ('copilot', 'gemini-cli', 'kimi', 'opencode', 'pi', 'qwen')
                  AND trim(cwd) != ''
                )
              )
            ORDER BY start_time DESC
            LIMIT 1000
            """
        )

        var checked = 0
        var classified = 0
        let linked = 0
        var suggested = 0

        for candidate in candidates {
            let summary: String? = candidate["summary"]
            let summaryMatches = isPolycliProviderSummary(summary)

            let id: String = candidate["id"]
            let source: String = candidate["source"]
            let agentRole: String? = candidate["agent_role"]
            let childCwd: String = candidate["cwd"]
            let childStartTime: String = candidate["start_time"]
            let scored = try scoredPolycliHosts(
                db,
                childId: id,
                childStartTime: childStartTime,
                childCwd: childCwd
            )

            if !summaryMatches {
                guard let best = scored.first,
                      best.score >= 7,
                      try isConcurrentProviderChild(db, childStartTime: childStartTime, parentId: best.parentId)
                else {
                    if source == "gemini-cli" {
                        continue
                    }
                    try markChecked(db, sessionId: id)
                    continue
                }
            }

            checked += 1
            if agentRole == nil { classified += 1 }

            try db.execute(
                sql: """
                UPDATE sessions
                SET agent_role = COALESCE(agent_role, 'dispatched'),
                    tier = 'skip',
                    link_checked_at = datetime('now')
                WHERE id = ?
                """,
                arguments: [id]
            )
            try deleteRecoverableIndexArtifactsForSkippedSession(db, sessionId: id)

            guard let best = scored.first, best.score >= 4 else { continue }
            guard try validateParentLink(db, sessionId: id, parentId: best.parentId) else {
                continue
            }

            try setSuggestedParent(db, sessionId: id, suggestedParentId: best.parentId)
            suggested += 1
        }

        return ProviderParentResult(checked: checked, classified: classified, linked: linked, suggested: suggested)
    }

    private static func scoredPolycliHosts(
        _ db: Database,
        childId: String,
        childStartTime: String,
        childCwd: String
    ) throws -> [ScoredParent] {
        guard !childCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let hosts = try Row.fetchAll(
            db,
            sql: """
            SELECT id, source, start_time, end_time, cwd
            FROM sessions
            WHERE id != ?
              AND source IN ('codex', 'claude-code', 'claude')
              AND agent_role IS NULL
              AND parent_session_id IS NULL
              AND rtrim(cwd, '/') = rtrim(?, '/')
              AND datetime(start_time) <= datetime(?)
              AND datetime(start_time) >= datetime(?, '-48 hours')
            """,
            arguments: [childId, childCwd, childStartTime, childStartTime]
        )

        return hosts.compactMap { host -> ScoredParent? in
            let score = scorePolycliHostCandidate(
                childStartTime: childStartTime,
                parentSource: host["source"],
                parentStartTime: host["start_time"],
                parentEndTime: host["end_time"],
                parentCwd: host["cwd"],
                childCwd: childCwd
            )
            guard score > 0 else { return nil }
            return ScoredParent(parentId: host["id"], score: score)
        }.sorted { $0.score > $1.score }
    }

    public static func backfillSuggestedParents(_ db: Database) throws -> SuggestedParentResult {
        let candidates = try Row.fetchAll(
            db,
            sql: """
            SELECT id, start_time, project, cwd, summary, agent_role FROM sessions
            WHERE parent_session_id IS NULL
              AND suggested_parent_id IS NULL
              AND link_checked_at IS NULL
              AND link_source IS NULL
              AND source IN ('gemini-cli', 'codex')
            LIMIT 500
            """
        )

        var checked = 0
        var suggested = 0
        let eligibleCandidates = candidates.filter { candidate in
            let agentRole: String? = candidate["agent_role"]
            if agentRole != nil { return true }
            let summary: String? = candidate["summary"]
            return summary.map(ParentDetection.isDispatchPattern) ?? false
        }
        let parentRows: [Row]
        if let earliestStart = eligibleCandidates.compactMap({ $0["start_time"] as String? }).min(),
           let latestStart = eligibleCandidates.compactMap({ $0["start_time"] as String? }).max() {
            parentRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, start_time, end_time, project, cwd FROM sessions
                WHERE source IN ('claude-code', 'claude')
                  AND datetime(start_time) BETWEEN datetime(?, '-24 hours') AND datetime(?)
                  AND parent_session_id IS NULL
                """,
                arguments: [earliestStart, latestStart]
            )
        } else {
            parentRows = []
        }

        for candidate in candidates {
            checked += 1
            let id: String = candidate["id"]
            let agentRole: String? = candidate["agent_role"]
            let summary: String? = candidate["summary"]

            if agentRole == nil {
                guard let summary, ParentDetection.isDispatchPattern(summary) else {
                    try markChecked(db, sessionId: id)
                    continue
                }
            }

            let startTime: String = candidate["start_time"]
            let candidateParentRows = parentRows.filter {
                isParentWithinCandidateLookback(parentStartTime: $0["start_time"], candidateStartTime: startTime)
            }
            let scored = candidateParentRows.map { parent -> ScoredParent in
                ScoredParent(
                    parentId: parent["id"],
                    score: ParentDetection.scoreCandidate(
                        agentStartTime: startTime,
                        parentStartTime: parent["start_time"],
                        parentEndTime: parent["end_time"],
                        agentProject: candidate["project"],
                        parentProject: parent["project"],
                        agentCwd: candidate["cwd"],
                        parentCwd: parent["cwd"]
                    )
                )
            }

            if let bestParent = ParentDetection.pickBestCandidate(scored) {
                try setSuggestedParent(db, sessionId: id, suggestedParentId: bestParent)
                suggested += 1
            } else {
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET agent_role = COALESCE(agent_role, 'dispatched'),
                        tier = 'skip',
                        link_checked_at = datetime('now')
                    WHERE id = ?
                    """,
                    arguments: [id]
                )
                try deleteRecoverableIndexArtifactsForSkippedSession(db, sessionId: id)
            }
        }

        return SuggestedParentResult(checked: checked, suggested: suggested)
    }

    private static func validateParentLink(_ db: Database, sessionId: String, parentId: String) throws -> Bool {
        if sessionId == parentId { return false }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, parent_session_id FROM sessions WHERE id = ?",
            arguments: [parentId]
        ) else {
            return false
        }
        let parentSessionId: String? = row["parent_session_id"]
        guard parentSessionId == nil else { return false }
        let childCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sessions WHERE parent_session_id = ? LIMIT 1",
            arguments: [sessionId]
        ) ?? 0
        return childCount == 0
    }

    private static func isConcurrentProviderChild(
        _ db: Database,
        childStartTime: String,
        parentId: String
    ) throws -> Bool {
        guard let parentStartTime = try String.fetchOne(
            db,
            sql: "SELECT start_time FROM sessions WHERE id = ?",
            arguments: [parentId]
        ),
              let childStart = parseDate(childStartTime),
              let parentStart = parseDate(parentStartTime)
        else {
            return false
        }
        return abs(childStart.timeIntervalSince(parentStart)) <= 5
    }

    private static func setParentSession(
        _ db: Database,
        sessionId: String,
        parentId: String,
        linkSource: String
    ) throws {
        try db.execute(
            sql: """
            UPDATE sessions
            SET parent_session_id = ?,
                link_source = ?,
                suggested_parent_id = NULL
            WHERE id = ?
            """,
            arguments: [parentId, linkSource, sessionId]
        )
    }

    private static func isParentWithinCandidateLookback(
        parentStartTime: String?,
        candidateStartTime: String
    ) -> Bool {
        guard let parentStartTime,
              let parentStart = parseDate(parentStartTime),
              let candidateStart = parseDate(candidateStartTime)
        else {
            return false
        }
        let lookback: TimeInterval = 24 * 60 * 60
        return parentStart <= candidateStart
            && parentStart >= candidateStart.addingTimeInterval(-lookback)
    }

    private static func setSuggestedParent(
        _ db: Database,
        sessionId: String,
        suggestedParentId: String
    ) throws {
        try db.execute(
            sql: """
            UPDATE sessions
            SET suggested_parent_id = ?,
                link_checked_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [suggestedParentId, sessionId]
        )
    }

    private static func markChecked(_ db: Database, sessionId: String) throws {
        try db.execute(
            sql: "UPDATE sessions SET link_checked_at = datetime('now') WHERE id = ?",
            arguments: [sessionId]
        )
    }

    private static func isPolycliProviderSummary(_ summary: String?) -> Bool {
        guard let summary else { return false }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "ping"
            || lower == "quick ping"
            || lower == "test ping"
            || lower == "quick ping check"
            || lower == "ping-pong test" {
            return true
        }
        if trimmed.range(of: #"^You are acting as [a-z0-9_-]+ inside polycli\."#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if trimmed.range(of: #"^Reply with POLYCLI_HEALTH_OK only\.?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return isProviderReviewSummary(trimmed)
    }

    private static func isProviderReviewSummary(_ summary: String) -> Bool {
        let lower = summary.lowercased()
        let isStageFactProbe = lower.hasPrefix("no tools.") &&
            lower.contains("stage ") &&
            (lower.contains("facts") || lower.contains("verified") || lower.contains("diff:"))
        let isScopedInput = lower.contains("no tools") ||
            lower.contains("use only") ||
            lower.contains("snippets") ||
            lower.contains("diff:") ||
            lower.contains("tests passed") ||
            lower.contains("tests ") ||
            lower.range(of: #"\bp\d+(\.\d+)?\b"#, options: .regularExpression) != nil ||
            lower.contains("stage ")
        let asksForOnlyFindings = lower.contains("blocking") ||
            lower.contains("correctness") ||
            lower.contains("report only") ||
            lower.contains("any blocking issue")
        let isReviewProbe = lower.contains("review") || lower.contains("re-review")
        return isStageFactProbe || (isReviewProbe && isScopedInput && asksForOnlyFindings)
    }

    private static func scorePolycliHostCandidate(
        childStartTime: String,
        parentSource: String,
        parentStartTime: String,
        parentEndTime: String?,
        parentCwd: String,
        childCwd: String
    ) -> Double {
        guard let childStart = parseDate(childStartTime),
              let parentStart = parseDate(parentStartTime),
              parentStart <= childStart
        else {
            return 0
        }

        let normalizedChild = childCwd.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let normalizedParent = parentCwd.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        guard !normalizedChild.isEmpty, normalizedChild == normalizedParent else {
            return 0
        }

        var score = 3.0
        if let parentEndTime, let parentEnd = parseDate(parentEndTime) {
            if parentEnd >= childStart {
                score += 3.0
            } else {
                let gap = childStart.timeIntervalSince(parentEnd)
                if gap > 30 * 60 { return 0 }
                score += 0.8
            }
        } else {
            score += 1.2
        }

        let ageHours = childStart.timeIntervalSince(parentStart) / (60 * 60)
        if ageHours <= 6 {
            score += 2 * (1 - ageHours / 6)
        } else if ageHours <= 48 {
            score += max(0, 0.8 * (1 - (ageHours - 6) / 42))
        } else {
            return 0
        }

        if parentSource == "codex" {
            score += 0.3
        }
        if parentSource == "claude-code" || parentSource == "claude" {
            score += 0.2
        }
        return score
    }

    private static func readFirstLine(path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    private static func computeQualityScore(
        userCount: Int,
        assistantCount: Int,
        toolCount: Int,
        systemCount: Int,
        startTime: String?,
        endTime: String?,
        project: String?
    ) -> Int {
        let total = userCount + assistantCount + toolCount + systemCount
        var turnScore = 0.0
        if userCount > 0, assistantCount > 0, total > 0 {
            turnScore = min(30, (Double(min(userCount, assistantCount)) / Double(total)) * 30)
        }

        var toolScore = 0.0
        if assistantCount > 0 {
            toolScore = min(25, (Double(toolCount) / Double(assistantCount)) * 50)
        }

        let duration = durationMinutes(startTime: startTime, endTime: endTime)
        let densityScore: Double
        if duration < 1 {
            densityScore = 0
        } else if duration <= 5 {
            densityScore = (duration / 5) * 20
        } else if duration <= 60 {
            densityScore = 20
        } else if duration <= 180 {
            densityScore = 20 - ((duration - 60) / 120) * 10
        } else {
            densityScore = 10
        }

        let projectScore = project == nil ? 0.0 : 15.0
        let volumeScore = min(10, Double(userCount + assistantCount + toolCount) / 5)
        return max(0, min(100, Int((turnScore + toolScore + densityScore + projectScore + volumeScore).rounded())))
    }

    private static func durationMinutes(startTime: String?, endTime: String?) -> Double {
        guard let startTime,
              let endTime,
              let start = parseDate(startTime),
              let end = parseDate(endTime)
        else {
            return 0
        }
        return end.timeIntervalSince(start) / 60
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private extension Database {
    /// Executes a single statement and returns the rows changed by THAT statement
    /// only (`db.changesCount`), not the connection-cumulative `totalChangesCount`.
    /// The cumulative counter also includes rows changed by triggers (e.g. the
    /// `trg_sessions_parent_cascade` cascade fired by `DELETE FROM sessions` in
    /// `deduplicateFilePaths`), which inflates the reported counts surfaced as
    /// maintenance event payloads. Per-statement `changesCount` reflects only the
    /// directly affected rows.
    func executeAndCountChanges(sql: String, arguments: StatementArguments = StatementArguments()) throws -> Int {
        try execute(sql: sql, arguments: arguments)
        return changesCount
    }
}
