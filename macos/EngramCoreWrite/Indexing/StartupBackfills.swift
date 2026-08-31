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
    func reconcileInsights() throws -> StartupInsightReconcileResult
    func reconcileGroupedSourceDirs() throws -> GroupedDirReconcileResult
    func backfillFilePaths() throws -> Int
    func downgradeSubagentTiers() throws -> Int
    func backfillParentLinks() throws -> StartupBackfills.ParentLinkResult
    func backfillCodexNativeParents() throws -> Int
    func resetStaleDetections() throws -> Int
    func backfillCodexOriginator() throws -> Int
    func backfillCodexModelLabels() throws -> Int
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

    private struct StoredSuggestionCandidate: Encodable {
        var id: String
        var score: Double
    }

    private enum CodexModelHeadRead {
        case decoded(String?)
        case unreadable
    }

    static let codexModelBackfillMetadataKey = "codex_model_backfill_version"
    static let codexModelBackfillVersion = "1"
    static let codexSpawnParentBackfillMetadataKey = "codex_spawn_parent_backfill_version"
    static let codexSpawnParentBackfillVersion = "1"
    static let codexSpawnParentCursorMetadataKey = "codex_spawn_parent_scan_rowid"
    static let skipTierArtifactReconcileMetadataKey = "skip_tier_artifact_reconcile_version"
    static let skipTierArtifactReconcileVersion = "1"
    static let groupedDirReconcileMetadataKey = "grouped_dir_reconcile_version"
    static let groupedDirReconcileVersion = "2"
    // Codex rollout line 1 can include large base instructions; 256 KiB keeps
    // startup bounded while covering the early session_meta/turn_context lines.
    static let codexModelHeadScanBytes = 256 * 1024

    public struct ProviderParentResult: Equatable, Sendable {
        public var checked: Int
        public var classified: Int
        public var suggested: Int

        public init(checked: Int, classified: Int, suggested: Int = 0) {
            self.checked = checked
            self.classified = classified
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
            let updated = try database.backfillCodexModelLabels()
            if updated > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("codex_model_labels"), "updated": .int(updated)]))
            }
        } catch {
            log.warn("codex model label backfill failed", error: error)
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
        } catch {
            log.warn("db maintenance failed", error: error)
        }

        // Do not run full FTS optimize or VACUUM during startup. Both rewrite
        // a large database, multiply transient allocator footprint, and delay
        // readiness for minutes. FTS consolidation is handled by bounded
        // periodic merge steps; space reclamation remains explicit maintenance.
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
            let codexNativeLinked = try database.backfillCodexNativeParents()
            if codexNativeLinked > 0 {
                emit(StartupBackfillEvent(
                    event: "backfill",
                    payload: ["type": .string("codex_native_parents"), "linked": .int(codexNativeLinked)]
                ))
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
            if providerParents.classified > 0 || providerParents.suggested > 0 {
                emit(
                    StartupBackfillEvent(
                        event: "backfill",
                        payload: [
                            "type": .string("polycli_provider_parents"),
                            "checked": .int(providerParents.checked),
                            "classified": .int(providerParents.classified),
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
        var shouldReconcilePathLinks = false
        do {
            let orphanScan = try await orphanScanner.detectOrphans(adapters: adapters)
            shouldReconcilePathLinks = orphanScan.newlyFlagged > 0
                || orphanScan.confirmed > 0
                || orphanScan.recovered > 0
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

        if shouldReconcilePathLinks {
            do {
                // docs/invariants.md #2: revalidate path-derived edges after
                // orphan transitions without upgrading any child out of skip.
                _ = try database.backfillParentLinks()
            } catch {
                log.warn("path link reconcile after orphan scan failed", error: error)
            }
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
        let storedVersion = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [SessionQualityScore.formulaVersionMetadataKey]
        )
        let recomputeAll = storedVersion != SessionQualityScore.formulaVersion
        let scorePredicate = recomputeAll
            ? "1 = 1"
            : "(quality_score IS NULL OR quality_score = 0)"
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, user_message_count, assistant_message_count, tool_message_count, system_message_count,
                   start_time, end_time, project
            FROM sessions
            WHERE \(scorePredicate)
              AND tier != 'skip'
              AND (user_message_count > 0 OR assistant_message_count > 0)
            """
        )

        var updated = 0
        for row in rows {
            let score = SessionQualityScore.compute(
                userCount: row["user_message_count"],
                assistantCount: row["assistant_message_count"],
                toolCount: row["tool_message_count"],
                systemCount: row["system_message_count"],
                startTime: row["start_time"],
                endTime: row["end_time"],
                project: row["project"]
            )
            try db.execute(sql: "UPDATE sessions SET quality_score = ? WHERE id = ?", arguments: [score, row["id"]])
            updated += 1
        }
        if recomputeAll || updated > 0 {
            try db.execute(
                sql: """
                INSERT INTO metadata(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [
                    SessionQualityScore.formulaVersionMetadataKey,
                    SessionQualityScore.formulaVersion
                ]
            )
        }
        return updated
    }

    public static func backfillCosts(_ db: Database) throws -> Int {
        let storedVersion = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [SessionCostPricing.metadataKey]
        )
        let recomputeAllTokenRows = storedVersion != SessionCostPricing.tableVersion
        let costPredicate = recomputeAllTokenRows ? "1 = 1" : "COALESCE(c.cost_usd, 0) = 0"
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT c.session_id,
                   c.model AS stored_model,
                   COALESCE(NULLIF(c.model, ''), NULLIF(s.model, '')) AS model,
                   COALESCE(c.input_tokens, 0) AS input_tokens,
                   COALESCE(c.output_tokens, 0) AS output_tokens,
                   COALESCE(c.cache_read_tokens, 0) AS cache_read_tokens,
                   COALESCE(c.cache_creation_tokens, 0) AS cache_creation_tokens,
                   c.cost_usd AS current_cost_usd
            FROM session_costs c
            LEFT JOIN sessions s ON s.id = c.session_id
            WHERE \(costPredicate)
              AND (
                COALESCE(c.input_tokens, 0) > 0
                OR COALESCE(c.output_tokens, 0) > 0
                OR COALESCE(c.cache_read_tokens, 0) > 0
                OR COALESCE(c.cache_creation_tokens, 0) > 0
              )
            """
        )
        guard !rows.isEmpty else {
            if recomputeAllTokenRows {
                try markCostPricingVersionCurrent(db)
            }
            return 0
        }

        var changed = 0
        for row in rows {
            let model: String? = row["model"]
            let targetModel = model?.isEmpty == false ? model : nil
            let usage = TokenUsage(
                inputTokens: row["input_tokens"],
                outputTokens: row["output_tokens"],
                cacheReadTokens: row["cache_read_tokens"],
                cacheCreationTokens: row["cache_creation_tokens"]
            )
            let costUSD = SessionCostPricing.computeCost(model: model, usage: usage)
            let currentCost: Double? = row["current_cost_usd"]
            let storedModel: String? = row["stored_model"]
            guard currentCost != costUSD || storedModel != targetModel else { continue }

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
        if recomputeAllTokenRows {
            try markCostPricingVersionCurrent(db)
        }
        return changed
    }

    private static func markCostPricingVersionCurrent(_ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [SessionCostPricing.metadataKey, SessionCostPricing.tableVersion]
        )
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
        if try tableExists(db, "session_relations") {
            try db.execute(
                sql: """
                \(duplicateMappingSQL),
                remapped AS (
                  SELECT
                    COALESCE(a_map.keep_id, relation.a_id) AS mapped_a,
                    COALESCE(b_map.keep_id, relation.b_id) AS mapped_b,
                    relation.created_at AS created_at
                  FROM session_relations relation
                  LEFT JOIN duplicates a_map ON a_map.old_id = relation.a_id
                  LEFT JOIN duplicates b_map ON b_map.old_id = relation.b_id
                  WHERE a_map.old_id IS NOT NULL OR b_map.old_id IS NOT NULL
                )
                INSERT OR IGNORE INTO session_relations(a_id, b_id, created_at)
                SELECT
                  CASE WHEN mapped_a < mapped_b THEN mapped_a ELSE mapped_b END,
                  CASE WHEN mapped_a < mapped_b THEN mapped_b ELSE mapped_a END,
                  created_at
                FROM remapped
                WHERE mapped_a != mapped_b
                """
            )
            try db.execute(
                sql: """
                \(duplicateMappingSQL)
                DELETE FROM session_relations
                WHERE a_id IN (SELECT old_id FROM duplicates)
                   OR b_id IN (SELECT old_id FROM duplicates)
                """
            )
        }
        let removed = try db.executeAndCountChanges(
            sql: """
            DELETE FROM sessions
            WHERE rowid NOT IN (SELECT MAX(rowid) FROM sessions GROUP BY file_path)
              AND file_path IS NOT NULL
              AND file_path != ''
            """
        )
        // The DELETE above leaves recoverable artifacts keyed by session_id behind,
        // so reconcile them in the same transaction.
        if removed > 0 {
            _ = try deleteRowsFromSessionArtifactTableIfPresent(
                db,
                table: "messages",
                whereSQL: "session_id NOT IN (SELECT id FROM sessions)"
            )
            try db.execute(
                sql: "DELETE FROM sessions_fts WHERE session_id NOT IN (SELECT id FROM sessions)"
            )
            _ = try deleteRowsFromSessionArtifactTableIfPresent(
                db,
                table: "fts_map",
                whereSQL: "session_id NOT IN (SELECT id FROM sessions)"
            )
            _ = try deleteRowsFromSessionArtifactTableIfPresent(
                db,
                table: "sessions_fts_rebuild",
                whereSQL: "session_id NOT IN (SELECT id FROM sessions)"
            )
            _ = try deleteRowsFromSessionArtifactTableIfPresent(
                db,
                table: "session_embeddings",
                whereSQL: "session_id NOT IN (SELECT id FROM sessions)"
            )
        }
        return removed
    }

    static let ftsOptimizeSignatureKey = "fts_optimize_signature"
    static let ftsMergeInProgressKey = "fts_merge_in_progress"
    static let ftsMergePageBudget = 500
    /// ISO8601 timestamp of the last periodic-path optimize attempt (whether
    /// the content-signature gate then ran or skipped the rewrite).
    public static let ftsOptimizeLastAttemptKey = "fts_optimize_last_attempt"
    /// Floor between periodic optimize attempts. FTS5 'optimize' rewrites the
    /// whole index; the 5-minute indexing loop would otherwise re-merge after
    /// every content change and pin the writer gate. 24h is long enough that
    /// segment merge is infrequent, short enough that a long-running service
    /// still consolidates without waiting for a restart.
    public static let ftsOptimizeMinInterval: TimeInterval = 24 * 60 * 60

    /// Performs one bounded FTS5 merge step instead of the unbounded `optimize`
    /// command. SQLite documents `merge` as the way to split optimization into
    /// page-budgeted transactions. A changed content signature starts a merge
    /// with a negative budget; later periodic calls continue it with a positive
    /// budget until both FTS tables report no work.
    @discardableResult
    public static func optimizeFts(_ db: Database) throws -> Bool {
        let signature = try ftsContentSignature(db)
        let stored = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [ftsOptimizeSignatureKey]
        )
        let continuing = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [ftsMergeInProgressKey]
        ) == "1"
        let signatureChanged = stored != signature
        guard continuing || signatureChanged else { return false }

        let pageBudget = continuing ? ftsMergePageBudget : -ftsMergePageBudget
        let sessionsBefore = db.totalChangesCount
        try db.execute(
            sql: "INSERT INTO sessions_fts(sessions_fts, rank) VALUES('merge', ?)",
            arguments: [pageBudget]
        )
        let sessionsDidWork = db.totalChangesCount - sessionsBefore >= 2
        let insightsBefore = db.totalChangesCount
        try db.execute(
            sql: "INSERT INTO insights_fts(insights_fts, rank) VALUES('merge', ?)",
            arguments: [pageBudget]
        )
        let insightsDidWork = db.totalChangesCount - insightsBefore >= 2
        let didMergeWork = sessionsDidWork || insightsDidWork
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [ftsOptimizeSignatureKey, signature]
        )
        if didMergeWork {
            try db.execute(
                sql: """
                INSERT INTO metadata(key, value) VALUES (?, '1')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [ftsMergeInProgressKey]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM metadata WHERE key = ?",
                arguments: [ftsMergeInProgressKey]
            )
        }
        return signatureChanged || didMergeWork
    }

    /// Whether the periodic-path min-interval gate would admit an attempt at `now`.
    public static func isFtsOptimizeDue(
        _ db: Database,
        now: Date = Date(),
        minInterval: TimeInterval = ftsOptimizeMinInterval
    ) throws -> Bool {
        if try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [ftsMergeInProgressKey]
        ) == "1" {
            return true
        }
        if let lastRaw = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [ftsOptimizeLastAttemptKey]
        ),
           let last = parseDate(lastRaw),
           now.timeIntervalSince(last) < minInterval {
            return false
        }
        return true
    }

    /// Persist the periodic optimize attempt timestamp. Must run in its **own**
    /// committed write before `optimizeFts` so a throw from the rewrite does not
    /// roll back the throttle (throw-safe 24h floor). Crash mid-rewrite is still
    /// covered once this write has committed.
    public static func recordFtsOptimizeAttempt(
        _ db: Database,
        now: Date = Date()
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [ftsOptimizeLastAttemptKey, formatter.string(from: now)]
        )
    }

    /// Single-connection helper: interval gate + attempt stamp + `optimizeFts`.
    ///
    /// **Not throw-safe when nested in one outer transaction** — if `optimizeFts`
    /// throws, the attempt stamp rolls back with it. Production uses
    /// `EngramDatabaseWriter.optimizeFtsIfDue`, which commits the attempt in a
    /// separate write before the rewrite. Prefer that API for the periodic path.
    @discardableResult
    public static func optimizeFtsIfDue(
        _ db: Database,
        now: Date = Date(),
        minInterval: TimeInterval = ftsOptimizeMinInterval
    ) throws -> Bool {
        guard try isFtsOptimizeDue(db, now: now, minInterval: minInterval) else {
            return false
        }
        try recordFtsOptimizeAttempt(db, now: now)
        return try optimizeFts(db)
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
        return "fts:\(FTSRebuildPolicy.expectedVersion):\(sn):\(sv):\(sm):\(inN):\(inM)"
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
    /// fts/embedding job, cheap companion artifact row, or one-time migration
    /// sweep. The obsolete jobs are then cleared so the signal is empty (and this
    /// scan skipped) next launch.
    public static func reconcileSkipTierIndexArtifacts(_ db: Database) throws -> Int {
        let skipSubquery = "SELECT id FROM sessions WHERE COALESCE(tier, 'normal') = 'skip'"
        let shouldFullScanFts = try needsSkipTierArtifactFullScan(db)
        let hasStale = try hasSkipTierIndexArtifacts(
            db,
            skipSubquery: skipSubquery,
            includeFtsScan: shouldFullScanFts
        )
        guard hasStale else {
            if shouldFullScanFts {
                try markSkipTierArtifactFullScanComplete(db)
            }
            return 0
        }

        let deletedMessages = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "messages",
            whereSQL: "session_id IN (\(skipSubquery))"
        )
        let deletedFts = try db.executeAndCountChanges(
            sql: "DELETE FROM sessions_fts WHERE session_id IN (\(skipSubquery))"
        )
        let deletedRebuildFts = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "sessions_fts_rebuild",
            whereSQL: "session_id IN (\(skipSubquery))"
        )
        var deletedFtsMap = 0
        if try tableExists(db, "fts_map") {
            deletedFtsMap = try db.executeAndCountChanges(
                sql: "DELETE FROM fts_map WHERE session_id IN (\(skipSubquery))"
            )
        }
        var deletedEmbeddings = 0
        if try tableExists(db, "session_embeddings") {
            deletedEmbeddings = try db.executeAndCountChanges(
                sql: "DELETE FROM session_embeddings WHERE session_id IN (\(skipSubquery))"
            )
        }
        let deletedSemanticChunks = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "semantic_chunks",
            whereSQL: "session_id IN (\(skipSubquery))"
        )
        try db.execute(
            sql: """
            DELETE FROM session_index_jobs
            WHERE job_kind IN ('fts', 'embedding')
              AND session_id IN (\(skipSubquery))
            """
        )
        if shouldFullScanFts {
            try markSkipTierArtifactFullScanComplete(db)
        }
        return deletedMessages + deletedFts + deletedRebuildFts + deletedFtsMap + deletedEmbeddings + deletedSemanticChunks
    }

    public static func reconcileInsights(_ db: Database) throws -> StartupInsightReconcileResult {
        do {
            // Resolve every pointer against a frozen graph. Only a chain ending
            // at an existing row with no successor is live; missing nodes and
            // cycles have no successor and are reactivated for dedup below.
            let linkRows = try Row.fetchAll(db, sql: "SELECT id, superseded_by FROM insights")
            let links = Dictionary(uniqueKeysWithValues: linkRows.map { row in
                (row["id"] as String, row["superseded_by"] as String?)
            })
            func liveTip(startingAt start: String) -> String? {
                var current = start
                var visited = Set<String>()
                while let successor = links[current] {
                    guard visited.insert(current).inserted else { return nil }
                    guard let successor else { return current }
                    current = successor
                }
                return nil
            }
            for row in linkRows {
                let id: String = row["id"]
                guard (row["superseded_by"] as String?) != nil else { continue }
                if let tip = liveTip(startingAt: id), tip != id {
                    try db.execute(
                        sql: "UPDATE insights SET superseded_by = ? WHERE id = ?",
                        arguments: [tip, id]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE insights SET superseded_by = NULL WHERE id = ?",
                        arguments: [id]
                    )
                }
            }
            // Legacy/imported data can contain more than one active row for the
            // same normalized fact. Keep the newest active tip and hide every
            // older same-scope duplicate behind it.
            let activeRows = try Row.fetchAll(db, sql: """
                SELECT id, content, wing, room
                FROM insights
                WHERE superseded_by IS NULL
                ORDER BY created_at DESC, id DESC
                """)
            struct Scope: Hashable {
                let wing: String?
                let room: String?
            }
            var newestByScopeAndContent: [Scope: [String: String]] = [:]
            for row in activeRows {
                let id: String = row["id"]
                let scope = Scope(wing: row["wing"], room: row["room"])
                let normalized = normalizedInsightContent((row["content"] as String?) ?? "")
                if let newest = newestByScopeAndContent[scope]?[normalized] {
                    try db.execute(
                        sql: "UPDATE insights SET superseded_by = ? WHERE id = ? AND superseded_by IS NULL",
                        arguments: [newest, id]
                    )
                } else {
                    newestByScopeAndContent[scope, default: [:]][normalized] = id
                }
            }
            let resetEmbedding = try db.executeAndCountChanges(
                sql: """
                UPDATE insights
                SET has_embedding = 0
                WHERE has_embedding = 1
                  AND NOT EXISTS (
                    SELECT 1 FROM insight_embeddings
                    WHERE insight_embeddings.insight_id = insights.id
                  )
                """
            )
            try db.execute(
                sql: """
                UPDATE insights
                SET has_embedding = 1
                WHERE has_embedding = 0
                  AND EXISTS (
                    SELECT 1 FROM insight_embeddings
                    WHERE insight_embeddings.insight_id = insights.id
                  )
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

    private static func normalizedInsightContent(_ content: String) -> String {
        content.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
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
        // docs/invariants.md #5: a current completed/not-applicable job is not
        // proof that its live FTS rows still exist; reopen it to heal the hole.
        // A failed_permanent job has exhausted recovery and must stay drained.
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
              AND COALESCE(NULLIF(s.source_locator, ''), NULLIF(s.file_path, '')) IS NOT NULL
              AND NOT EXISTS (
                SELECT 1
                FROM session_index_jobs current
                WHERE current.id = s.id || ':' || s.sync_version || ':' || s.snapshot_hash || ':fts'
                  AND current.status IN ('pending', 'inflight')
              )
              AND NOT EXISTS (
                SELECT 1 FROM sessions_fts live WHERE live.session_id = s.id
              )
            ON CONFLICT(id) DO UPDATE SET
              status = 'pending',
              retry_count = 0,
              last_error = NULL,
              updated_at = datetime('now')
            WHERE session_index_jobs.status IN ('completed', 'not_applicable')
            """
        )
    }

    public static func downgradeSubagentTiers(_ db: Database) throws -> Int {
        let changed = try db.executeAndCountChanges(
            sql: """
            UPDATE sessions SET tier = 'skip'
            WHERE agent_role = 'subagent' AND COALESCE(tier, 'normal') != 'skip'
            """
        )
        try deleteRecoverableIndexArtifactsForSkippedSessions(db, whereClause: "agent_role = 'subagent'")
        return changed
    }

    private static func deleteRecoverableIndexArtifactsForSkippedSession(_ db: Database, sessionId: String) throws {
        _ = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "messages",
            whereSQL: "session_id = ?",
            arguments: [sessionId]
        )
        try db.execute(
            sql: "DELETE FROM sessions_fts WHERE session_id = ?",
            arguments: [sessionId]
        )
        // docs/invariants.md #3: skip-tier rows must stay absent from every
        // visibility corpus, including a pending FTS rebuild shadow table.
        _ = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "sessions_fts_rebuild",
            whereSQL: "session_id = ?",
            arguments: [sessionId]
        )
        _ = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "fts_map",
            whereSQL: "session_id = ?",
            arguments: [sessionId]
        )
        if try tableExists(db, "session_embeddings") {
            try db.execute(
                sql: "DELETE FROM session_embeddings WHERE session_id = ?",
                arguments: [sessionId]
            )
        }
        _ = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "semantic_chunks",
            whereSQL: "session_id = ?",
            arguments: [sessionId]
        )
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
        _ = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "messages",
            whereSQL: "session_id IN (SELECT id FROM sessions WHERE \(whereClause))"
        )
        try db.execute(
            sql: """
            DELETE FROM sessions_fts
            WHERE session_id IN (SELECT id FROM sessions WHERE \(whereClause))
            """
        )
        _ = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "sessions_fts_rebuild",
            whereSQL: "session_id IN (SELECT id FROM sessions WHERE \(whereClause))"
        )
        _ = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "fts_map",
            whereSQL: "session_id IN (SELECT id FROM sessions WHERE \(whereClause))"
        )
        if try tableExists(db, "session_embeddings") {
            try db.execute(
                sql: """
                DELETE FROM session_embeddings
                WHERE session_id IN (SELECT id FROM sessions WHERE \(whereClause))
                """
            )
        }
        _ = try deleteRowsFromSessionArtifactTableIfPresent(
            db,
            table: "semantic_chunks",
            whereSQL: "session_id IN (SELECT id FROM sessions WHERE \(whereClause))"
        )
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

    private static func needsSkipTierArtifactFullScan(_ db: Database) throws -> Bool {
        let current = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [skipTierArtifactReconcileMetadataKey]
        )
        return current != skipTierArtifactReconcileVersion
    }

    private static func markSkipTierArtifactFullScanComplete(_ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [skipTierArtifactReconcileMetadataKey, skipTierArtifactReconcileVersion]
        )
    }

    private static func hasSkipTierIndexArtifacts(
        _ db: Database,
        skipSubquery: String,
        includeFtsScan: Bool
    ) throws -> Bool {
        let hasJobSignal = try Bool.fetchOne(
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
        if hasJobSignal { return true }

        for table in ["messages", "sessions_fts_rebuild", "fts_map", "session_embeddings", "semantic_chunks"] {
            if try hasRowsInSessionArtifactTableIfPresent(
                db,
                table: table,
                whereSQL: "session_id IN (\(skipSubquery))"
            ) {
                return true
            }
        }
        if includeFtsScan {
            return try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sessions_fts WHERE session_id IN (\(skipSubquery)))"
            ) ?? false
        }
        return false
    }

    private static func hasRowsInSessionArtifactTableIfPresent(
        _ db: Database,
        table: String,
        whereSQL: String,
        arguments: StatementArguments = StatementArguments()
    ) throws -> Bool {
        guard try tableExists(db, table), try tableHasColumn(db, table: table, column: "session_id") else {
            return false
        }
        return try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE \(whereSQL))",
            arguments: arguments
        ) ?? false
    }

    private static func deleteRowsFromSessionArtifactTableIfPresent(
        _ db: Database,
        table: String,
        whereSQL: String,
        arguments: StatementArguments = StatementArguments()
    ) throws -> Int {
        guard try tableExists(db, table), try tableHasColumn(db, table: table, column: "session_id") else {
            return 0
        }
        return try db.executeAndCountChanges(
            sql: "DELETE FROM \(table) WHERE \(whereSQL)",
            arguments: arguments
        )
    }

    private static func tableHasColumn(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return rows.contains { row in
            (row["name"] as String?) == column
        }
    }

    public static func backfillParentLinks(
        _ db: Database,
        homeDirectory: URL = SessionAdapterFactory.resolvedHomeDirectory()
    ) throws -> ParentLinkResult {
        let qoderRoot = SessionAdapterFactory.qoderProjectsRoot(homeDirectory: homeDirectory)
        let claudeRoots = ClaudeCodeProfileResolver(
            homeDirectory: homeDirectory,
            settingsURL: homeDirectory.appendingPathComponent(".engram/settings.json")
        ).resolve().profiles.map(\.projectsRoot)

        // Reconcile legacy/path-derived links before attempting new inference.
        // Validate the whole pre-mutation graph first so cleanup order cannot
        // turn a depth>1 chain into a different, accidentally valid link.
        let existingPathLinks = try Row.fetchAll(
            db,
            sql: """
            SELECT id, source, parent_session_id,
                   COALESCE(NULLIF(source_locator, ''), file_path) AS locator
            FROM sessions
            WHERE link_source = 'path'
              AND parent_session_id IS NOT NULL
            """
        )
        var invalidPathSessionIds: [String] = []
        for row in existingPathLinks {
            let sessionId: String = row["id"]
            let source: String = row["source"]
            let parentId: String = row["parent_session_id"]
            let locator: String = row["locator"]
            if try !validateExistingPathParent(
                db,
                sessionId: sessionId,
                source: source,
                locator: locator,
                parentId: parentId
            ) {
                invalidPathSessionIds.append(sessionId)
            }
        }
        for sessionId in invalidPathSessionIds {
            try db.execute(
                sql: """
                UPDATE sessions
                SET parent_session_id = NULL,
                    link_source = NULL,
                    link_checked_at = CASE
                        WHEN agent_role IN ('dispatched', 'subagent') THEN link_checked_at
                        ELSE NULL
                    END,
                    suggested_parent_id = NULL,
                    suggestion_status = NULL,
                    suggestion_candidates = NULL
                WHERE id = ? AND link_source = 'path'
                """,
                arguments: [sessionId]
            )
        }

        // Paginate with a stable rowid cursor so a full page of unparseable or
        // invalid legacy candidates cannot starve later valid children in the
        // same backfill call (PARENT-BACKFILL-STARVE-001).
        var linked = 0
        var lastRowID: Int64 = 0
        while true {
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT rowid, id, source, file_path FROM sessions
                WHERE agent_role = 'subagent'
                  AND parent_session_id IS NULL
                  AND (link_source IS NULL OR link_source != 'manual')
                  AND rowid > ?
                ORDER BY rowid
                LIMIT 500
                """,
                arguments: [lastRowID]
            )
            if rows.isEmpty {
                break
            }
            for row in rows {
                lastRowID = row["rowid"]
                let id: String = row["id"]
                let source: String = row["source"]
                let filePath: String = row["file_path"]
                // docs/invariants.md #2: Qoder's project-level subagent layout
                // derives the real host from the transcript sessionId, not the
                // encoded project directory immediately above `subagents`.
                let parentId: String
                if source == SourceName.qoder.rawValue {
                    guard let qoderParent = qoderParentCandidate(
                        locator: filePath,
                        projectsRoot: qoderRoot
                    ) else {
                        continue
                    }
                    parentId = qoderParent
                } else {
                    guard let projectsRoot = confinedSubagentProjectsRoot(
                              locator: filePath,
                              source: source,
                              claudeProjectsRoots: claudeRoots
                          ),
                          let layout = SubagentTranscriptPath.layout(
                              locator: filePath,
                              projectsRoot: projectsRoot
                          )
                    else {
                        continue
                    }
                    parentId = layout.parentSessionId
                }
                guard try validateParentLink(db, sessionId: id, parentId: parentId) else {
                    continue
                }
                try setParentSession(db, sessionId: id, parentId: parentId, linkSource: "path")
                linked += 1
            }
        }

        // OpenCode stores native parentage in its own SQLite session table.
        // A child can be indexed before its host, so retry unresolved native
        // links here after all adapters have completed. docs/invariants.md #2:
        // setParentSession changes only the link and never upgrades skip tiers.
        while true {
            let openCodeRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, agent_role,
                       COALESCE(NULLIF(source_locator, ''), file_path) AS locator
                FROM sessions
                WHERE source = 'opencode'
                  AND parent_session_id IS NULL
                  AND (link_source IS NULL OR link_source != 'manual')
                """
            )
            var linkedThisPass = 0
            for row in openCodeRows {
                let sessionId: String = row["id"]
                let agentRole: String? = row["agent_role"]
                let locator: String = row["locator"]
                let externalParent = try openCodeResolvedParentCandidate(db, locator: locator)
                guard externalParent.checked,
                      let parentId = externalParent.parentId,
                      try validateParentLink(db, sessionId: sessionId, parentId: parentId)
                else { continue }
                try setParentSession(
                    db,
                    sessionId: sessionId,
                    parentId: parentId,
                    linkSource: "path",
                    stampCheckedAt: agentRole == "dispatched" || agentRole == "subagent"
                )
                linkedThisPass += 1
            }
            linked += linkedThisPass
            if linkedThisPass == 0 { break }
        }

        return ParentLinkResult(linked: linked)
    }

    private static func openCodeParentCandidates(locator: String) -> (checked: Bool, parentIds: [String]) {
        guard let separator = locator.range(of: "::", options: .backwards) else { return (false, []) }
        let databasePath = String(locator[..<separator.lowerBound])
        let sessionId = String(locator[separator.upperBound...])
        guard !databasePath.isEmpty, !sessionId.isEmpty else { return (true, []) }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = \(SQLiteConnectionPolicy.busyTimeoutMilliseconds)")
        }
        guard let queue = try? DatabaseQueue(path: databasePath, configuration: configuration) else {
            return (false, [])
        }
        do {
            let parentIds = try queue.read { external -> [String] in
                guard let child = try Row.fetchOne(
                    external,
                    sql: "SELECT parent_id, time_archived FROM session WHERE id = ?",
                    arguments: [sessionId]
                ), child["time_archived"] as Int64? == nil
                else { return [] }
                var current: String? = child["parent_id"]
                var visited: Set<String> = [sessionId]
                var candidates: [String] = []
                while let candidate = current, visited.insert(candidate).inserted {
                    guard let row = try Row.fetchOne(
                        external,
                        sql: "SELECT parent_id, time_archived FROM session WHERE id = ?",
                        arguments: [candidate]
                    ) else {
                        candidates.append(candidate)
                        continue
                    }
                    current = row["parent_id"]
                    guard row["time_archived"] as Int64? == nil else { continue }
                    candidates.append(candidate)
                }
                return candidates
            }
            return (true, parentIds)
        } catch {
            return (false, [])
        }
    }

    private static func openCodeResolvedParentCandidate(
        _ db: Database,
        locator: String
    ) throws -> (checked: Bool, parentId: String?) {
        let external = openCodeParentCandidates(locator: locator)
        guard external.checked else { return (false, nil) }
        for candidate in external.parentIds.reversed() {
            guard try sessionExists(db, id: candidate) else { continue }
            // docs/invariants.md #2: a present but hidden/orphan/skip ancestor
            // blocks descent; otherwise its now-top-level fork could be exposed.
            return (true, try openCodeTopLevelParentCandidate(db, candidate: candidate))
        }
        return (true, nil)
    }

    private static func openCodeTopLevelParentCandidate(
        _ db: Database,
        candidate: String
    ) throws -> String? {
        var current = candidate
        var visited: Set<String> = []
        while visited.insert(current).inserted {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, tier, hidden_at, orphan_status FROM sessions WHERE id = ?",
                arguments: [current]
            ) else { return nil }
            let tier: String? = row["tier"]
            let hiddenAt: String? = row["hidden_at"]
            let orphanStatus: String? = row["orphan_status"]
            guard tier != SessionTier.skip.rawValue, hiddenAt == nil, orphanStatus == nil else {
                return nil
            }
            guard let parentId = row["parent_session_id"] as String? else { return current }
            current = parentId
        }
        return nil
    }

    private static func qoderParentCandidate(locator: String, projectsRoot: String) -> String? {
        if let nested = SubagentTranscriptPath.layout(
            locator: locator,
            projectsRoot: projectsRoot
        ) {
            return nested.parentSessionId
        }

        guard SubagentTranscriptPath.layout(
            locator: locator,
            projectsRoot: projectsRoot,
            projectLevelParentSessionId: "layout-probe"
        ) != nil else {
            return nil
        }
        guard let parentSessionId = qoderTranscriptParentCandidate(locator: locator) else {
            return nil
        }
        return SubagentTranscriptPath.layout(
            locator: locator,
            projectsRoot: projectsRoot,
            projectLevelParentSessionId: parentSessionId
        )?.parentSessionId
    }

    private static func confinedSubagentProjectsRoot(
        locator: String,
        source: String,
        claudeProjectsRoots: [String]
    ) -> String? {
        switch source {
        case SourceName.claudeCode.rawValue, "claude",
             SourceName.minimax.rawValue, SourceName.lobsterai.rawValue:
            // docs/invariants.md #2: only adapter-configured roots may infer a
            // parent for a stored subagent locator; path-name sniffing is not proof.
            return claudeProjectsRoots.first { projectsRoot in
                SubagentTranscriptPath.layout(
                    locator: locator,
                    projectsRoot: projectsRoot
                ) != nil
            }
        default:
            return nil
        }
    }

    private static func qoderTranscriptParentCandidate(locator: String) -> String? {
        // Match Qoder's ParserLimits defaults without importing its internal
        // adapter type into the write core: 100 MiB per file, 8 MiB per line.
        let maxFileBytes = 100 * 1_024 * 1_024
        let maxLineBytes = 8 * 1_024 * 1_024
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: locator),
              let fileBytes = attributes[.size] as? NSNumber,
              fileBytes.int64Value <= Int64(maxFileBytes),
              let data = try? Data(contentsOf: URL(fileURLWithPath: locator), options: .mappedIfSafe)
        else { return nil }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.count <= maxLineBytes else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant",
                  let sessionId = object["sessionId"] as? String
            else { continue }
            let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { return normalized }
        }
        return nil
    }

    public static func resetStaleDetections(_ db: Database) throws -> Int {
        let stored = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = 'detection_version'"
        ).flatMap(Int.init) ?? 0
        guard stored < ParentDetection.detectionVersion else {
            return 0
        }

        // L11 / SUGGESTED-PARENT-RESCORE-001: a single suggested parent is
        // heuristic output, not a confirmed relationship. Invalidate it on a
        // detector-version bump so the later startup phase can score current
        // candidates. Manual and confirmed links remain authoritative.
        let resetSuggested = try db.executeAndCountChanges(
            sql: """
            UPDATE sessions
            SET suggested_parent_id = NULL,
                link_checked_at = NULL,
                suggestion_status = NULL,
                suggestion_candidates = NULL
            WHERE suggested_parent_id IS NOT NULL
              AND parent_session_id IS NULL
              AND (link_source IS NULL OR link_source != 'manual')
            """
        )
        let resetAmbiguous = try db.executeAndCountChanges(
            sql: """
            UPDATE sessions
            SET link_checked_at = NULL,
                suggestion_status = NULL,
                suggestion_candidates = NULL
            WHERE suggestion_status = 'ambiguous'
              AND parent_session_id IS NULL
              AND suggested_parent_id IS NULL
              AND (link_source IS NULL OR link_source != 'manual')
            """
        )
        let resetUnchecked = try db.executeAndCountChanges(
            sql: """
            UPDATE sessions
            SET link_checked_at = NULL,
                suggestion_status = NULL,
                suggestion_candidates = NULL
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
            SET link_checked_at = NULL,
                suggestion_status = NULL,
                suggestion_candidates = NULL
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
        return resetSuggested + resetAmbiguous + resetUnchecked + resetDispatched
    }

    /// Link Codex children from vendor-stamped `thread_spawn` / `parent_thread_id`
    /// in rollout line 1. Version-gated one-shot sweep + rowid high-water cursor.
    /// See `docs/codex-native-parentage-design-2026-07.md`.
    public static func backfillCodexNativeParents(_ db: Database) throws -> Int {
        let storedVersion = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [codexSpawnParentBackfillMetadataKey]
        )
        let isSweep = storedVersion != codexSpawnParentBackfillVersion
        let cursor: Int64
        if isSweep {
            cursor = 0
        } else {
            let raw = try String.fetchOne(
                db,
                sql: "SELECT value FROM metadata WHERE key = ?",
                arguments: [codexSpawnParentCursorMetadataKey]
            )
            cursor = Int64(raw ?? "0") ?? 0
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT rowid, id, file_path, agent_role FROM sessions
            WHERE source = 'codex'
              AND file_path LIKE '%/.codex/%'
              AND parent_session_id IS NULL
              AND (link_source IS NULL OR link_source != 'manual')
              AND rowid > ?
            ORDER BY rowid
            """,
            arguments: [cursor]
        )

        var linked = 0
        var maxRowID: Int64 = cursor
        for row in rows {
            let rowID: Int64 = row["rowid"]
            if rowID > maxRowID { maxRowID = rowID }
            let id: String = row["id"]
            let filePath: String = row["file_path"]
            let existingRole: String? = row["agent_role"]

            guard let firstLine = readFirstLineBytes(path: filePath, maxBytes: codexModelHeadScanBytes),
                  let spawn = codexSpawnParent(head: firstLine)
            else {
                continue
            }
            // Vendor depth > 1 is order-dependent under validateParentLink; skip.
            if let depth = spawn.depth, depth > 1 {
                continue
            }
            guard try validateParentLink(db, sessionId: id, parentId: spawn.parentId) else {
                continue
            }
            // Do not link under a skip-tier parent — child would be unreachable.
            let parentTier = try String.fetchOne(
                db,
                sql: "SELECT tier FROM sessions WHERE id = ?",
                arguments: [spawn.parentId]
            )
            if parentTier == "skip" {
                continue
            }

            if existingRole == nil {
                let changes = try db.executeAndCountChanges(
                    sql: """
                    UPDATE sessions
                    SET agent_role = 'dispatched', tier = 'skip'
                    WHERE id = ?
                    """,
                    arguments: [id]
                )
                if changes > 0 {
                    try deleteRecoverableIndexArtifactsForSkippedSession(db, sessionId: id)
                }
            }
            try setParentSession(db, sessionId: id, parentId: spawn.parentId, linkSource: "path")
            linked += 1
        }

        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [codexSpawnParentBackfillMetadataKey, codexSpawnParentBackfillVersion]
        )
        if !rows.isEmpty {
            try db.execute(
                sql: """
                INSERT INTO metadata(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [codexSpawnParentCursorMetadataKey, String(maxRowID)]
            )
        }
        return linked
    }

    /// Parse vendor-stamped Codex spawn parent from a session_meta first line.
    /// Requires unconditional `type == "session_meta"`; bare payload objects are rejected.
    /// Internal (not private) so tests can exercise it via `@testable`.
    static func codexSpawnParent(head: String) -> (parentId: String, depth: Int?)? {
        guard let data = head.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any]
        else {
            return nil
        }

        var parentId: String?
        var depth: Int?
        if let source = payload["source"] as? [String: Any],
           let subagent = source["subagent"] as? [String: Any],
           let threadSpawn = subagent["thread_spawn"] as? [String: Any]
        {
            parentId = threadSpawn["parent_thread_id"] as? String
            if let d = threadSpawn["depth"] as? Int {
                depth = d
            } else if let d = threadSpawn["depth"] as? NSNumber {
                depth = d.intValue
            }
        }
        if parentId == nil {
            parentId = payload["parent_thread_id"] as? String
        }
        guard let parentId, !parentId.isEmpty else { return nil }
        return (parentId, depth)
    }

    /// Read up to `maxBytes`, truncate at the first 0x0A, decode only that prefix.
    static func readFirstLineBytes(path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        let line = data.firstIndex(of: 0x0A).map { data[..<$0] } ?? data[...]
        return String(data: Data(line), encoding: .utf8)
    }

    public static func backfillCodexOriginator(_ db: Database) throws -> Int {
        var updated = 0
        var cursor: Int64 = 0
        while true {
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT rowid, id, file_path FROM sessions
                WHERE source = 'codex'
                  AND agent_role IS NULL
                  AND parent_session_id IS NULL
                  AND suggested_parent_id IS NULL
                  AND (link_source IS NULL OR link_source != 'manual')
                  AND link_checked_at IS NULL
                  AND rowid > ?
                ORDER BY rowid
                LIMIT 500
                """,
                arguments: [cursor]
            )
            guard !rows.isEmpty else { break }

            for row in rows {
                let rowID: Int64 = row["rowid"]
                cursor = rowID
                let id: String = row["id"]
                let filePath: String = row["file_path"]
                guard let firstLine = readFirstLineBytes(
                          path: filePath,
                          maxBytes: codexModelHeadScanBytes
                      ),
                      let data = firstLine.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any]
                else {
                    continue
                }
                guard payload["originator"] as? String == "Claude Code" else {
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

    public static func backfillCodexModelLabels(_ db: Database) throws -> Int {
        let storedVersion = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [codexModelBackfillMetadataKey]
        )
        guard storedVersion != codexModelBackfillVersion else { return 0 }

        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, file_path, model
            FROM sessions
            WHERE source = 'codex'
              AND (model = 'openai' OR model IS NULL)
            ORDER BY rowid
            """
        )

        var updated = 0
        var completed = true
        for row in rows {
            let id: String = row["id"]
            let filePath: String = row["file_path"]
            let currentModel: String? = row["model"]
            let model: String?
            switch codexModelLabelFromHead(path: filePath) {
            case .decoded(let decodedModel):
                model = decodedModel
            case .unreadable:
                completed = false
                continue
            }

            if let model {
                updated += try db.executeAndCountChanges(
                    sql: "UPDATE sessions SET model = ? WHERE id = ?",
                    arguments: [model, id]
                )
            } else if currentModel == "openai" {
                updated += try db.executeAndCountChanges(
                    sql: "UPDATE sessions SET model = NULL WHERE id = ?",
                    arguments: [id]
                )
            }
        }

        // docs/invariants.md #9: an incomplete model-label sweep must remain
        // eligible so cost backfill can price the corrected label on a retry.
        guard completed else { return updated }
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [codexModelBackfillMetadataKey, codexModelBackfillVersion]
        )
        return updated
    }

    public static func backfillPolycliProviderParents(_ db: Database) throws -> ProviderParentResult {
        var checked = 0
        var classified = 0
        var suggested = 0
        var cursor: Int64 = 0

        while true {
            let candidates = try Row.fetchAll(
                db,
                sql: """
                SELECT rowid, id, source, start_time, cwd, summary, agent_role
                FROM sessions
                WHERE parent_session_id IS NULL
                  AND (link_source IS NULL OR link_source != 'manual')
                  AND link_checked_at IS NULL
                  AND rowid > ?
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
                    OR (
                      source != 'claude-code'
                      AND (lower(summary) LIKE '%review%' OR lower(summary) LIKE '%re-review%')
                      AND (
                        lower(summary) LIKE '%no tools%'
                        OR lower(summary) LIKE '%use only%'
                        OR lower(summary) LIKE '%snippets%'
                        OR lower(summary) LIKE '%diff:%'
                      )
                      AND (
                        lower(summary) LIKE '%blocking%'
                        OR lower(summary) LIKE '%correctness%'
                        OR lower(summary) LIKE '%report only%'
                      )
                    )
                    OR (
                      lower(summary) LIKE 'no tools.%stage %'
                      AND (
                        lower(summary) LIKE '%facts%'
                        OR lower(summary) LIKE '%verified%'
                        OR lower(summary) LIKE '%diff:%'
                      )
                    )
                    -- Wave 7B M18: do NOT admit bare same-cwd provider sessions.
                    -- Concurrent timing alone is insufficient without probe/dispatch
                    -- summary evidence (false-skip of ordinary human sessions).
                  )
                ORDER BY rowid
                LIMIT 1000
                """,
                arguments: [cursor]
            )
            guard !candidates.isEmpty else { break }

            for candidate in candidates {
                cursor = candidate["rowid"]
                let summary: String? = candidate["summary"]
                let summaryMatches = isPolycliProviderSummary(summary)

                let id: String = candidate["id"]
                let source: String = candidate["source"]
                _ = source
                let agentRole: String? = candidate["agent_role"]
                let childCwd: String = candidate["cwd"]
                let childStartTime: String = candidate["start_time"]
                let scored = try scoredPolycliHosts(
                    db,
                    childId: id,
                    childStartTime: childStartTime,
                    childCwd: childCwd
                )

                // docs/invariants.md #9: this pass runs before later parent-link
                // layers. A SQL prefilter mismatch must remain unchecked so the
                // later layer can still evaluate it. docs/invariants.md #2 also
                // forbids false skip-demotion of ordinary sessions.
                if !summaryMatches {
                    continue
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
        }

        return ProviderParentResult(checked: checked, classified: classified, suggested: suggested)
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
        // Suggested links are heuristic. If their host later becomes hidden,
        // skip-tier, orphaned, or disappears, clear the stale suggestion so the
        // non-skip child can surface as a root without changing its tier.
        try db.execute(sql: """
            UPDATE sessions AS child
            SET suggested_parent_id = NULL,
                suggestion_status = NULL,
                suggestion_candidates = NULL
            WHERE child.suggested_parent_id IS NOT NULL
              AND child.parent_session_id IS NULL
              AND NOT EXISTS (
                SELECT 1
                FROM sessions AS host
                WHERE host.id = child.suggested_parent_id
                  AND host.hidden_at IS NULL
                  AND (host.tier IS NULL OR host.tier != 'skip')
                  AND host.orphan_status IS NULL
              )
            """)
        var checked = 0
        var suggested = 0
        var cursor: Int64 = 0

        while true {
            let candidates = try Row.fetchAll(
                db,
                sql: """
                SELECT rowid, id, start_time, project, cwd, summary, agent_role FROM sessions
                WHERE parent_session_id IS NULL
                  AND suggested_parent_id IS NULL
                  AND link_checked_at IS NULL
                  AND link_source IS NULL
                  AND source IN ('gemini-cli', 'codex')
                  AND rowid > ?
                ORDER BY rowid
                LIMIT 500
                """,
                arguments: [cursor]
            )
            guard !candidates.isEmpty else { break }

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
                      AND agent_role IS NULL
                      AND (tier IS NULL OR tier != 'skip')
                    """,
                    arguments: [earliestStart, latestStart]
                )
            } else {
                parentRows = []
            }

            for candidate in candidates {
                cursor = candidate["rowid"]
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
                // docs/invariants.md #2: skip/nested sessions cannot host a new
                // suggested child, and parent-link validation must remain fail-closed.
                let scored = try candidateParentRows.compactMap { parent -> ScoredParent? in
                    let parentId: String = parent["id"]
                    guard try validateParentLink(db, sessionId: id, parentId: parentId) else {
                        return nil
                    }
                    return ScoredParent(
                        parentId: parentId,
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

                switch ParentDetection.pickBestCandidate(scored) {
                case .suggest(let bestParent):
                    try setSuggestedParent(db, sessionId: id, suggestedParentId: bestParent)
                    suggested += 1
                case .ambiguous(let candidates):
                    try setAmbiguousSuggestion(db, sessionId: id, candidates: candidates)
                case .none:
                    // M8: skip-tier only with positive Layer-1 evidence (agent_role
                    // already dispatched/subagent, e.g. Codex originator).
                    let hasPositiveDispatchEvidence =
                        agentRole == "dispatched" || agentRole == "subagent"
                    if hasPositiveDispatchEvidence {
                        try db.execute(
                            sql: """
                            UPDATE sessions
                            SET agent_role = COALESCE(agent_role, 'dispatched'),
                                tier = 'skip',
                                link_checked_at = datetime('now'),
                                suggestion_status = NULL,
                                suggestion_candidates = NULL
                            WHERE id = ?
                            """,
                            arguments: [id]
                        )
                        try deleteRecoverableIndexArtifactsForSkippedSession(db, sessionId: id)
                    } else {
                        try markChecked(db, sessionId: id)
                    }
                }
            }
        }

        return SuggestedParentResult(checked: checked, suggested: suggested)
    }

    private static func validateParentLink(_ db: Database, sessionId: String, parentId: String) throws -> Bool {
        if sessionId == parentId { return false }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, parent_session_id, tier, hidden_at, orphan_status FROM sessions WHERE id = ?",
            arguments: [parentId]
        ) else {
            return false
        }
        let parentSessionId: String? = row["parent_session_id"]
        let parentTier: String? = row["tier"]
        let hiddenAt: String? = row["hidden_at"]
        let orphanStatus: String? = row["orphan_status"]
        // docs/invariants.md #2: inferred links must not hide children behind
        // a host that is itself hidden, orphaned, nested, or skip-tier.
        guard parentSessionId == nil,
              parentTier != SessionTier.skip.rawValue,
              hiddenAt == nil,
              orphanStatus == nil
        else { return false }
        let childCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sessions WHERE parent_session_id = ? LIMIT 1",
            arguments: [sessionId]
        ) ?? 0
        return childCount == 0
    }

    /// Existing path links yield to non-path children (especially manual
    /// decisions). Path/path chains are still reconciled from the top down:
    /// the lower path edge is rejected because its parent is already nested.
    private static func validateExistingPathParent(
        _ db: Database,
        sessionId: String,
        source: String,
        locator: String,
        parentId: String
    ) throws -> Bool {
        if sessionId == parentId { return false }
        if source == SourceName.opencode.rawValue {
            let externalParent = try openCodeResolvedParentCandidate(db, locator: locator)
            if externalParent.checked {
                guard externalParent.parentId == parentId
                else { return false }
            }
        }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT parent_session_id, tier, hidden_at, orphan_status FROM sessions WHERE id = ?",
            arguments: [parentId]
        ) else {
            return false
        }
        let parentSessionId: String? = row["parent_session_id"]
        let parentTier: String? = row["tier"]
        let hiddenAt: String? = row["hidden_at"]
        let orphanStatus: String? = row["orphan_status"]
        guard parentSessionId == nil,
              parentTier != SessionTier.skip.rawValue,
              hiddenAt == nil,
              orphanStatus == nil
        else {
            return false
        }
        let preservedChildCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM sessions
                WHERE parent_session_id = ?
                  AND (link_source IS NULL OR link_source != 'path')
                """,
            arguments: [sessionId]
        ) ?? 0
        return preservedChildCount == 0
    }

    private static func sessionExists(_ db: Database, id: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
            arguments: [id]
        ) ?? false
    }

    private static func setParentSession(
        _ db: Database,
        sessionId: String,
        parentId: String,
        linkSource: String,
        stampCheckedAt: Bool = false
    ) throws {
        try db.execute(
            sql: """
            UPDATE sessions
            SET parent_session_id = ?,
                link_source = ?,
                link_checked_at = CASE WHEN ? THEN datetime('now') ELSE link_checked_at END,
                suggested_parent_id = NULL,
                suggestion_status = NULL,
                suggestion_candidates = NULL
            WHERE id = ?
            """,
            arguments: [parentId, linkSource, stampCheckedAt, sessionId]
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
                suggestion_status = NULL,
                suggestion_candidates = NULL,
                link_checked_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [suggestedParentId, sessionId]
        )
    }

    private static func markChecked(_ db: Database, sessionId: String) throws {
        try db.execute(
            sql: """
            UPDATE sessions
            SET link_checked_at = datetime('now'),
                suggestion_status = NULL,
                suggestion_candidates = NULL
            WHERE id = ?
            """,
            arguments: [sessionId]
        )
    }

    private static func setAmbiguousSuggestion(
        _ db: Database,
        sessionId: String,
        candidates: [ScoredParent]
    ) throws {
        let payload = candidates.map { StoredSuggestionCandidate(id: $0.parentId, score: $0.score) }
        let data = try JSONEncoder().encode(payload)
        let encoded = String(decoding: data, as: UTF8.self)
        // Wave 7B H04: ambiguous suggestions must not un-skip dispatched agents.
        // Clear only relationship/suggestion fields; keep agent_role and skip tier.
        try db.execute(
            sql: """
            UPDATE sessions
            SET suggested_parent_id = NULL,
                suggestion_status = 'ambiguous',
                suggestion_candidates = ?,
                link_checked_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [encoded, sessionId]
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
            lower.contains("diff:")
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

    private static func codexModelLabelFromHead(path: String) -> CodexModelHeadRead {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        let read = handle.readData(ofLength: codexModelHeadScanBytes + 1)
        let isTruncated = read.count > codexModelHeadScanBytes
        let head = read.prefix(codexModelHeadScanBytes)
        var lines = head.split(separator: 0x0A, omittingEmptySubsequences: false)
        if isTruncated, head.last != 0x0A {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return .unreadable }

        var turnContextModel: String?
        var metaModel: String?
        var decodedLine = false
        for line in lines {
            guard !line.isEmpty,
                  let text = String(data: Data(line), encoding: .utf8)
            else {
                if !line.isEmpty { return .unreadable }
                continue
            }
            decodedLine = true
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else {
                continue
            }

            if type == "response_item", let model = payload["model"] as? String {
                return .decoded(model)
            }
            if type == "turn_context", turnContextModel == nil {
                turnContextModel = payload["model"] as? String
            } else if type == "session_meta", metaModel == nil {
                metaModel = payload["model"] as? String
            }
        }
        guard decodedLine else { return .unreadable }
        return .decoded(turnContextModel ?? metaModel)
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
