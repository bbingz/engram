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
    func indexAll() async throws -> Int
    func backfillCounts() async throws -> Int
    func backfillCosts() async throws -> Int
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
    func backfillFilePaths() throws -> Int
    func downgradeSubagentTiers() throws -> Int
    func backfillParentLinks() throws -> StartupBackfills.ParentLinkResult
    func resetStaleDetections() throws -> Int
    func backfillCodexOriginator() throws -> Int
    func backfillSuggestedParents() throws -> StartupBackfills.SuggestedParentResult
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
        let indexed = try await indexer.indexAll()

        do {
            let backfilled = try await indexer.backfillCounts()
            if backfilled > 0 {
                emit(StartupBackfillEvent(event: "backfill_counts", payload: ["backfilled": .int(backfilled)]))
            }
        } catch {
            log.warn("backfill counts failed", error: error)
        }

        do {
            let costBackfilled = try await indexer.backfillCosts()
            if costBackfilled > 0 {
                emit(StartupBackfillEvent(event: "backfill", payload: ["type": .string("costs"), "count": .int(costBackfilled)]))
            }
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
            if try database.vacuumIfNeeded(15) {
                emit(StartupBackfillEvent(event: "db_maintenance", payload: ["action": .string("vacuum")]))
            }
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
            log.warn("db maintenance failed", error: error)
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
        } catch {
            log.warn("orphan scan failed", error: error)
        }

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

    public static func deduplicateFilePaths(_ db: Database) throws -> Int {
        try db.executeAndCountChanges(
            sql: """
            DELETE FROM sessions
            WHERE rowid NOT IN (SELECT MAX(rowid) FROM sessions GROUP BY file_path)
              AND file_path IS NOT NULL
              AND file_path != ''
            """
        )
    }

    public static func optimizeFts(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO sessions_fts(sessions_fts) VALUES('optimize')")
        try db.execute(sql: "INSERT INTO insights_fts(insights_fts) VALUES('optimize')")
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
            let orphanedVector = try db.executeAndCountChanges(
                sql: """
                UPDATE memory_insights
                SET deleted_at = datetime('now')
                WHERE deleted_at IS NULL
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
        try db.executeAndCountChanges(
            sql: """
            UPDATE migration_log
            SET state = 'failed',
                error = 'stale_after_crash: non-terminal for over 24 hours',
                finished_at = datetime('now')
            WHERE state IN ('fs_pending', 'fs_done')
              AND started_at <= datetime('now', '-86400 seconds')
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
        try db.execute(
            sql: """
            DELETE FROM sessions_fts
            WHERE session_id IN (SELECT id FROM sessions WHERE agent_role = 'subagent')
            """
        )
        return changed
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
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, file_path FROM sessions
            WHERE source = 'codex'
              AND agent_role IS NULL
              AND parent_session_id IS NULL
              AND suggested_parent_id IS NULL
              AND (link_source IS NULL OR link_source != 'manual')
            LIMIT 500
            """
        )

        var updated = 0
        for row in rows {
            let id: String = row["id"]
            let filePath: String = row["file_path"]
            guard let firstLine = readFirstLine(path: filePath, maxBytes: 16_384),
                  let data = firstLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["originator"] as? String == "Claude Code"
            else {
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
            updated += changes
        }
        return updated
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
            let parents = try Row.fetchAll(
                db,
                sql: """
                SELECT id, start_time, end_time, project, cwd FROM sessions
                WHERE source IN ('claude-code', 'claude')
                  AND start_time <= ?
                  AND start_time >= datetime(?, '-24 hours')
                  AND parent_session_id IS NULL
                """,
                arguments: [startTime, startTime]
            )

            let scored = parents.map { parent -> ScoredParent in
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
        return parentSessionId == nil
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
    func executeAndCountChanges(sql: String, arguments: StatementArguments = StatementArguments()) throws -> Int {
        let before = totalChangesCount
        try execute(sql: sql, arguments: arguments)
        return totalChangesCount - before
    }
}
