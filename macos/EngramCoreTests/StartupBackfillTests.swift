import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class StartupBackfillTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-backfills-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB {
            try? FileManager.default.removeItem(at: tempDB)
        }
        tempDB = nil
    }

    func testDowngradeSubagentTiersAndRemoveFTSRows() throws {
        try writer.write { db in
            try insertSession(db, id: "subagent-1", source: "codex", agentRole: "subagent", tier: "lite")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('subagent-1', 'hidden')")

            let changed = try StartupBackfills.downgradeSubagentTiers(db)
            XCTAssertEqual(changed, 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'subagent-1'"), "skip")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'subagent-1'"), 0)
        }
    }

    func testBackfillParentLinksUsesPathAndPreservesManualLinks() throws {
        try writer.write { db in
            try insertSession(db, id: "parent-1", source: "codex", tier: "normal")
            try insertSession(
                db,
                id: "child-1",
                source: "codex",
                filePath: "/tmp/parent-1/subagents/worker.jsonl",
                agentRole: "subagent",
                tier: "skip"
            )
            try insertSession(
                db,
                id: "manual-child",
                source: "codex",
                filePath: "/tmp/parent-1/subagents/manual.jsonl",
                agentRole: "subagent",
                tier: "skip",
                linkSource: "manual"
            )

            let result = try StartupBackfills.backfillParentLinks(db)
            XCTAssertEqual(result.linked, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child-1'"),
                "parent-1"
            )
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'manual-child'"))
        }
    }

    func testResetStaleDetectionsStoresVersionAndSkipsManualLinks() throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO metadata(key, value) VALUES ('detection_version', '3')")
            try insertSession(
                db,
                id: "stale",
                source: "gemini-cli",
                linkCheckedAt: "2026-01-01T00:00:00Z"
            )
            try insertSession(
                db,
                id: "manual",
                source: "gemini-cli",
                linkSource: "manual",
                linkCheckedAt: "2026-01-01T00:00:00Z"
            )

            let reset = try StartupBackfills.resetStaleDetections(db)
            XCTAssertEqual(reset, 1)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'stale'"))
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'manual'"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'detection_version'"),
                "\(ParentDetection.detectionVersion)"
            )
        }
    }

    func testBackfillCodexOriginatorMarksClaudeLaunchedCodexSessions() throws {
        let codexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-originator-\(UUID().uuidString).jsonl")
        let nativeCodexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-native-originator-\(UUID().uuidString).jsonl")
        try #"{"type":"session_meta","payload":{"id":"codex-1","originator":"Claude Code"}}"#
            .appending("\n")
            .write(to: codexFile, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"codex-2","originator":"Codex CLI"}}"#
            .appending("\n")
            .write(to: nativeCodexFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: codexFile) }
        defer { try? FileManager.default.removeItem(at: nativeCodexFile) }

        try writer.write { db in
            try insertSession(db, id: "codex-1", source: "codex", filePath: codexFile.path)
            try insertSession(db, id: "codex-2", source: "codex", filePath: nativeCodexFile.path)

            let updated = try StartupBackfills.backfillCodexOriginator(db)
            XCTAssertEqual(updated, 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'codex-1'"), "dispatched")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'codex-1'"), "skip")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'codex-2'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'codex-2'"))
        }
    }

    func testBackfillSuggestedParentsScoresClaudeParentsAndMarksOrphans() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "parent",
                source: "claude-code",
                startTime: "2026-04-23T10:00:00.000Z",
                endTime: nil,
                cwd: "/Users/example/-Code-/engram",
                project: "engram"
            )
            try insertSession(
                db,
                id: "agent",
                source: "gemini-cli",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/Users/example/-Code-/engram",
                project: "engram",
                summary: "Your task is to review the adapter implementation"
            )
            try insertSession(
                db,
                id: "ordinary",
                source: "gemini-cli",
                startTime: "2026-04-23T10:12:00.000Z",
                summary: "What does this function do?"
            )
            try insertSession(
                db,
                id: "orphan",
                source: "codex",
                startTime: "2026-04-23T09:00:00.000Z",
                summary: "Your task is to audit the repo",
                agentRole: "dispatched"
            )

            let result = try StartupBackfills.backfillSuggestedParents(db)
            XCTAssertEqual(result.checked, 3)
            XCTAssertEqual(result.suggested, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'agent'"),
                "parent"
            )
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'ordinary'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'orphan'"), "dispatched")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'orphan'"), "skip")
        }
    }

    func testRunInitialScanEmitsNodeCompatibleStartupEventsInOrder() async throws {
        let indexer = RecordingStartupIndexer(indexed: 7, countBackfilled: 2, costBackfilled: 3)
        let database = RecordingStartupDatabase()
        let jobRunner = RecordingStartupIndexJobRunner()
        let usageCollector = RecordingStartupUsageCollector()
        let orphanScanner = RecordingStartupOrphanScanner()
        let logger = RecordingStartupLogger()
        var events: [StartupBackfillEvent] = []

        try await StartupBackfills.runInitialScan(
            emit: { events.append($0) },
            log: logger,
            usageCollector: usageCollector,
            indexer: indexer,
            indexJobRunner: jobRunner,
            database: database,
            orphanScanner: orphanScanner
        )

        XCTAssertEqual(
            database.callOrder,
            [
                "backfillScores",
                "deduplicateFilePaths",
                "optimizeFts",
                "vacuumIfNeeded",
                "reconcileInsights",
                "backfillFilePaths",
                "downgradeSubagentTiers",
                "backfillParentLinks",
                "resetStaleDetections",
                "backfillCodexOriginator",
                "backfillSuggestedParents",
                "cleanupStaleMigrations",
                "countSessions",
                "countTodayParentSessions"
            ]
        )
        XCTAssertEqual(
            events,
            [
                StartupBackfillEvent(event: "backfill_counts", payload: ["backfilled": .int(2)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("costs"), "count": .int(3)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("scores"), "count": .int(4)]),
                StartupBackfillEvent(event: "db_maintenance", payload: ["action": .string("dedup"), "removed": .int(5)]),
                StartupBackfillEvent(event: "db_maintenance", payload: ["action": .string("vacuum")]),
                StartupBackfillEvent(
                    event: "db_maintenance",
                    payload: [
                        "action": .string("reconcile_insights"),
                        "resetEmbedding": .int(6),
                        "orphanedVector": .int(7)
                    ]
                ),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("file_paths"), "count": .int(8)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("subagent_tier_downgrade"), "count": .int(9)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("parent_links"), "linked": .int(10)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("detection_reset"), "count": .int(11)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("codex_originator"), "updated": .int(12)]),
                StartupBackfillEvent(
                    event: "backfill",
                    payload: [
                        "type": .string("suggested_parents"),
                        "checked": .int(13),
                        "suggested": .int(14)
                    ]
                ),
                StartupBackfillEvent(event: "migration_cleanup", payload: ["stale": .int(15)]),
                StartupBackfillEvent(
                    event: "ready",
                    payload: ["indexed": .int(7), "total": .int(16), "todayParents": .int(17)]
                ),
                StartupBackfillEvent(
                    event: "orphan_scan",
                    payload: [
                        "scanned": .int(18),
                        "newly_flagged": .int(19),
                        "confirmed": .int(20),
                        "recovered": .int(21),
                        "skipped": .int(22)
                    ]
                ),
                StartupBackfillEvent(
                    event: "index_jobs_recovered",
                    payload: ["completed": .int(23), "notApplicable": .int(24)]
                ),
                StartupBackfillEvent(event: "insights_promoted", payload: ["count": .int(25)])
            ]
        )
        XCTAssertTrue(usageCollector.didStart)
        XCTAssertTrue(logger.warnings.isEmpty)
    }

    func testRunInitialScanKeepsReadyWhenRecoverableBackfillsFail() async throws {
        let database = RecordingStartupDatabase()
        database.backfillScoresError = TestError.expected
        database.filePathBackfillError = TestError.expected
        var events: [StartupBackfillEvent] = []

        try await StartupBackfills.runInitialScan(
            emit: { events.append($0) },
            log: RecordingStartupLogger(),
            usageCollector: RecordingStartupUsageCollector(),
            indexer: RecordingStartupIndexer(indexed: 1),
            indexJobRunner: RecordingStartupIndexJobRunner(completed: 0, notApplicable: 0, promoted: 0),
            database: database,
            orphanScanner: RecordingStartupOrphanScanner(newlyFlagged: 0, confirmed: 0, recovered: 0),
            adapters: []
        )

        XCTAssertEqual(events.map(\.event).filter { $0 == "ready" }.count, 1)
        XCTAssertTrue(events.contains(StartupBackfillEvent(event: "error", payload: ["message": .string("backfillFilePaths: expected")])))
    }

    func testBackfillFilePathsUpdatesSessionsAndLocalStateIgnoringSyncLocators() throws {
        try writer.write { db in
            try insertSession(db, id: "local", source: "codex", filePath: "", sourceLocator: "/tmp/local.jsonl")
            try insertSession(db, id: "sync", source: "codex", filePath: "", sourceLocator: "sync://peer/session")
            try db.execute(sql: "INSERT INTO session_local_state(session_id, local_readable_path) VALUES ('local', NULL), ('sync', NULL)")

            let changed = try StartupBackfills.backfillFilePaths(db)

            XCTAssertEqual(changed, 2)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_path FROM sessions WHERE id = 'local'"), "/tmp/local.jsonl")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT local_readable_path FROM session_local_state WHERE session_id = 'local'"), "/tmp/local.jsonl")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_path FROM sessions WHERE id = 'sync'"), "")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT local_readable_path FROM session_local_state WHERE session_id = 'sync'"))
        }
    }

    func testBackfillScoresMatchesNodeQualityScoringForEligibleSessions() throws {
        struct ScoreCase {
            let id: String
            let userCount: Int
            let assistantCount: Int
            let toolCount: Int
            let systemCount: Int
            let durationMinutes: Int
            let project: String?
        }

        let cases = [
            ScoreCase(
                id: "balanced-tool-session",
                userCount: 3,
                assistantCount: 3,
                toolCount: 2,
                systemCount: 1,
                durationMinutes: 10,
                project: "engram"
            ),
            ScoreCase(
                id: "short-chat-no-tools",
                userCount: 1,
                assistantCount: 1,
                toolCount: 0,
                systemCount: 0,
                durationMinutes: 2,
                project: nil
            ),
            ScoreCase(
                id: "long-tool-heavy-session",
                userCount: 8,
                assistantCount: 6,
                toolCount: 12,
                systemCount: 2,
                durationMinutes: 240,
                project: "infra"
            )
        ]

        try writer.write { db in
            for scoreCase in cases {
                try insertSession(
                    db,
                    id: scoreCase.id,
                    source: "codex",
                    startTime: "2026-04-23T10:00:00.000Z",
                    endTime: endTime(minutesAfterStart: scoreCase.durationMinutes),
                    project: scoreCase.project,
                    tier: "normal",
                    userMessageCount: scoreCase.userCount,
                    assistantMessageCount: scoreCase.assistantCount,
                    toolMessageCount: scoreCase.toolCount,
                    systemMessageCount: scoreCase.systemCount,
                    qualityScore: 0
                )
            }
            try insertSession(
                db,
                id: "skip-tier",
                source: "codex",
                tier: "skip",
                userMessageCount: 3,
                assistantMessageCount: 3,
                qualityScore: 0
            )

            let changed = try StartupBackfills.backfillScores(db)

            XCTAssertEqual(changed, cases.count)
            for scoreCase in cases {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT quality_score FROM sessions WHERE id = ?", arguments: [scoreCase.id]),
                    expectedQualityScore(
                        userCount: scoreCase.userCount,
                        assistantCount: scoreCase.assistantCount,
                        toolCount: scoreCase.toolCount,
                        systemCount: scoreCase.systemCount,
                        durationMinutes: Double(scoreCase.durationMinutes),
                        hasProject: scoreCase.project != nil
                    ),
                    scoreCase.id
                )
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT quality_score FROM sessions WHERE id = 'skip-tier'"), 0)
        }
    }

    func testDeduplicateFilePathsKeepsLatestRowid() throws {
        try writer.write { db in
            try insertSession(db, id: "old", source: "codex", filePath: "/tmp/dup.jsonl")
            try insertSession(db, id: "new", source: "codex", filePath: "/tmp/dup.jsonl")

            let removed = try StartupBackfills.deduplicateFilePaths(db)

            XCTAssertEqual(removed, 1)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = 'old'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE file_path = '/tmp/dup.jsonl'"), "new")
        }
    }

    func testCleanupStaleMigrationsFailsOnlyOldNonTerminalRows() throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO migration_log(id, old_path, new_path, old_basename, new_basename, state, started_at)
                VALUES
                  ('stale', '/old', '/new', 'old', 'new', 'fs_pending', datetime('now', '-25 hours')),
                  ('fresh', '/old2', '/new2', 'old2', 'new2', 'fs_done', datetime('now', '-1 hours')),
                  ('done', '/old3', '/new3', 'old3', 'new3', 'committed', datetime('now', '-25 hours'))
                """
            )

            let cleaned = try StartupBackfills.cleanupStaleMigrations(db)

            XCTAssertEqual(cleaned, 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id = 'stale'"), "failed")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id = 'fresh'"), "fs_done")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id = 'done'"), "committed")
        }
    }

    private func insertSession(
        _ db: Database,
        id: String,
        source: String,
        startTime: String = "2026-04-23T10:00:00.000Z",
        endTime: String? = "2026-04-23T11:00:00.000Z",
        cwd: String = "",
        project: String? = nil,
        summary: String? = nil,
        filePath: String = "/tmp/session.jsonl",
        sourceLocator: String? = nil,
        agentRole: String? = nil,
        tier: String? = nil,
        linkSource: String? = nil,
        linkCheckedAt: String? = nil,
        userMessageCount: Int = 0,
        assistantMessageCount: Int = 0,
        toolMessageCount: Int = 0,
        systemMessageCount: Int = 0,
        qualityScore: Int? = nil
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(
              id, source, start_time, end_time, cwd, project, summary, file_path,
              source_locator, agent_role, tier, link_source, link_checked_at,
              user_message_count, assistant_message_count, tool_message_count, system_message_count,
              quality_score
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, source, startTime, endTime, cwd, project, summary, filePath,
                sourceLocator, agentRole, tier, linkSource, linkCheckedAt,
                userMessageCount, assistantMessageCount, toolMessageCount, systemMessageCount,
                qualityScore
            ]
        )
    }

    private func endTime(minutesAfterStart: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.date(from: "2026-04-23T10:00:00.000Z")!
        let end = start.addingTimeInterval(TimeInterval(minutesAfterStart * 60))
        return formatter.string(from: end)
    }

    private func expectedQualityScore(
        userCount: Int,
        assistantCount: Int,
        toolCount: Int,
        systemCount: Int,
        durationMinutes: Double,
        hasProject: Bool
    ) -> Int {
        let totalMessages = userCount + assistantCount + toolCount + systemCount
        var turnScore = 0.0
        if userCount > 0, assistantCount > 0, totalMessages > 0 {
            turnScore = min(30, (Double(min(userCount, assistantCount)) / Double(totalMessages)) * 30)
        }

        var toolScore = 0.0
        if assistantCount > 0 {
            toolScore = min(25, (Double(toolCount) / Double(assistantCount)) * 50)
        }

        let densityScore: Double
        if durationMinutes < 1 {
            densityScore = 0
        } else if durationMinutes <= 5 {
            densityScore = (durationMinutes / 5) * 20
        } else if durationMinutes <= 60 {
            densityScore = 20
        } else if durationMinutes <= 180 {
            densityScore = 20 - ((durationMinutes - 60) / 120) * 10
        } else {
            densityScore = 10
        }

        let projectScore = hasProject ? 15.0 : 0.0
        let volumeScore = min(10, Double(userCount + assistantCount + toolCount) / 5)
        return max(0, min(100, Int((turnScore + toolScore + densityScore + projectScore + volumeScore).rounded())))
    }
}

private enum TestError: Error, CustomStringConvertible {
    case expected

    var description: String { "expected" }
}

private final class RecordingStartupLogger: StartupBackfillLogging {
    var warnings: [String] = []

    func warn(_ message: String, error: Error) {
        warnings.append("\(message): \(error)")
    }
}

private final class RecordingStartupUsageCollector: StartupUsageCollecting {
    var didStart = false

    func start() {
        didStart = true
    }
}

private final class RecordingStartupIndexer: StartupIndexing {
    var indexed: Int
    var countBackfilled: Int
    var costBackfilled: Int

    init(indexed: Int, countBackfilled: Int = 0, costBackfilled: Int = 0) {
        self.indexed = indexed
        self.countBackfilled = countBackfilled
        self.costBackfilled = costBackfilled
    }

    func indexAll() async throws -> Int {
        indexed
    }

    func backfillCounts() async throws -> Int {
        countBackfilled
    }

    func backfillCosts() async throws -> Int {
        costBackfilled
    }
}

private final class RecordingStartupIndexJobRunner: StartupIndexJobRunning {
    var completed: Int
    var notApplicable: Int
    var promoted: Int

    init(completed: Int = 23, notApplicable: Int = 24, promoted: Int = 25) {
        self.completed = completed
        self.notApplicable = notApplicable
        self.promoted = promoted
    }

    func runRecoverableJobs() async throws -> StartupIndexJobRecoveryResult {
        StartupIndexJobRecoveryResult(completed: completed, notApplicable: notApplicable)
    }

    func backfillInsightEmbeddings() async throws -> Int {
        promoted
    }
}

private final class RecordingStartupOrphanScanner: StartupOrphanScanning {
    var scanned: Int
    var newlyFlagged: Int
    var confirmed: Int
    var recovered: Int
    var skipped: Int

    init(scanned: Int = 18, newlyFlagged: Int = 19, confirmed: Int = 20, recovered: Int = 21, skipped: Int = 22) {
        self.scanned = scanned
        self.newlyFlagged = newlyFlagged
        self.confirmed = confirmed
        self.recovered = recovered
        self.skipped = skipped
    }

    func detectOrphans(adapters: [any SessionAdapter]) async throws -> StartupOrphanScanResult {
        StartupOrphanScanResult(
            scanned: scanned,
            newlyFlagged: newlyFlagged,
            confirmed: confirmed,
            recovered: recovered,
            skipped: skipped
        )
    }
}

private final class RecordingStartupDatabase: StartupBackfillDatabase {
    var callOrder: [String] = []
    var backfillScoresError: Error?
    var filePathBackfillError: Error?

    func countSessions() throws -> Int {
        callOrder.append("countSessions")
        return 16
    }

    func countTodayParentSessions() throws -> Int {
        callOrder.append("countTodayParentSessions")
        return 17
    }

    func backfillScores() throws -> Int {
        callOrder.append("backfillScores")
        if let backfillScoresError { throw backfillScoresError }
        return 4
    }

    func deduplicateFilePaths() throws -> Int {
        callOrder.append("deduplicateFilePaths")
        return 5
    }

    func optimizeFts() throws {
        callOrder.append("optimizeFts")
    }

    func vacuumIfNeeded(_ fragmentationPercent: Int) throws -> Bool {
        callOrder.append("vacuumIfNeeded")
        XCTAssertEqual(fragmentationPercent, 15)
        return true
    }

    func reconcileInsights() throws -> StartupInsightReconcileResult {
        callOrder.append("reconcileInsights")
        return StartupInsightReconcileResult(resetEmbedding: 6, orphanedVector: 7)
    }

    func backfillFilePaths() throws -> Int {
        callOrder.append("backfillFilePaths")
        if let filePathBackfillError { throw filePathBackfillError }
        return 8
    }

    func downgradeSubagentTiers() throws -> Int {
        callOrder.append("downgradeSubagentTiers")
        return 9
    }

    func backfillParentLinks() throws -> StartupBackfills.ParentLinkResult {
        callOrder.append("backfillParentLinks")
        return StartupBackfills.ParentLinkResult(linked: 10)
    }

    func resetStaleDetections() throws -> Int {
        callOrder.append("resetStaleDetections")
        return 11
    }

    func backfillCodexOriginator() throws -> Int {
        callOrder.append("backfillCodexOriginator")
        return 12
    }

    func backfillSuggestedParents() throws -> StartupBackfills.SuggestedParentResult {
        callOrder.append("backfillSuggestedParents")
        return StartupBackfills.SuggestedParentResult(checked: 13, suggested: 14)
    }

    func cleanupStaleMigrations() throws -> Int {
        callOrder.append("cleanupStaleMigrations")
        return 15
    }
}
