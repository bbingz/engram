// macos/EngramTests/DatabaseManagerTests.swift
import XCTest
import GRDB
@testable import Engram

final class DatabaseManagerTests: XCTestCase {
    var db: DatabaseManager!
    var dbPath: String!

    @MainActor
    override func setUpWithError() throws {
        let tempDir = FileManager.default.temporaryDirectory
        dbPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sqlite").path
        // Create the sessions table first (daemon's job in production)
        try createSessionsTable(at: dbPath)
        db = DatabaseManager(path: dbPath)
        try db.open()
    }

    @MainActor
    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
    }

    // MARK: - Basic open/close

    func testOpenCreatesExtensionTables() throws {
        let tables = try db.readInBackground { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        XCTAssertTrue(tables.contains("favorites"), "favorites table should exist")
        XCTAssertTrue(tables.contains("tags"), "tags table should exist")
    }

    func testPathReturnsCorrectPath() throws {
        XCTAssertEqual(db.path, dbPath)
    }

    @MainActor
    func testReadInBackgroundThrowsWhenNotOpen() throws {
        let closedDb = DatabaseManager(path: "/tmp/nonexistent-\(UUID().uuidString).sqlite")
        XCTAssertThrowsError(try closedDb.readInBackground { db in
            try String.fetchAll(db, sql: "SELECT 1")
        }) { error in
            XCTAssertTrue(error is Engram.DatabaseError)
        }
    }

    // MARK: - Favorites

    @MainActor
    func testAddAndRemoveFavorite() throws {
        try insertTestSession(at: dbPath)
        try db.addFavorite(sessionId: "test-session-001")
        XCTAssertTrue(try db.isFavorite(sessionId: "test-session-001"))

        try db.removeFavorite(sessionId: "test-session-001")
        XCTAssertFalse(try db.isFavorite(sessionId: "test-session-001"))
    }

    @MainActor
    func testListFavorites() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s2", source: "cursor")
        try db.addFavorite(sessionId: "s1")
        try db.addFavorite(sessionId: "s2")

        let favorites = try db.listFavorites()
        XCTAssertEqual(favorites.count, 2)
    }

    @MainActor
    func testIsFavoriteReturnsFalseForNonFavorite() throws {
        try insertTestSession(at: dbPath)
        XCTAssertFalse(try db.isFavorite(sessionId: "test-session-001"))
    }

    // MARK: - Session queries

    @MainActor
    func testListSessionsReturnsInsertedSessions() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s2", source: "cursor")
        try insertTestSession(at: dbPath, id: "s3", source: "codex")

        let sessions = try db.listSessions()
        XCTAssertEqual(sessions.count, 3)
    }

    @MainActor
    func testListSessionsWithSourceFilter() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s2", source: "cursor")

        let claudeOnly = try db.listSessions(sources: Set(["claude-code"]))
        XCTAssertEqual(claudeOnly.count, 1)
        XCTAssertEqual(claudeOnly.first?.source, "claude-code")
    }

    @MainActor
    func testListSessionsWithProjectFilter() throws {
        try insertTestSession(at: dbPath, id: "s1", project: "engram")
        try insertTestSession(at: dbPath, id: "s2", project: "my-app")

        let engramOnly = try db.listSessions(projects: Set(["engram"]))
        XCTAssertEqual(engramOnly.count, 1)
        XCTAssertEqual(engramOnly.first?.project, "engram")
    }

    @MainActor
    func testGetSessionReturnsCorrectSession() throws {
        try insertTestSession(at: dbPath, id: "specific-id", source: "codex")

        let session = try db.getSession(id: "specific-id")
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.id, "specific-id")
        XCTAssertEqual(session?.source, "codex")
    }

    @MainActor
    func testGetSessionReturnsNilForMissing() throws {
        let session = try db.getSession(id: "nonexistent")
        XCTAssertNil(session)
    }

    @MainActor
    func testCountSessions() throws {
        try insertTestSession(at: dbPath, id: "s1")
        try insertTestSession(at: dbPath, id: "s2")
        try insertTestSession(at: dbPath, id: "s3")

        let count = try db.countSessions()
        XCTAssertEqual(count, 3)
    }

    @MainActor
    func testCountSessionsWithSourceFilter() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s2", source: "cursor")

        let count = try db.countSessions(sources: Set(["claude-code"]))
        XCTAssertEqual(count, 1)
    }

    // MARK: - Stats

    @MainActor
    func testStatsReturnsCorrectCounts() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code", messageCount: 10)
        try insertTestSession(at: dbPath, id: "s2", source: "cursor", messageCount: 5)

        let stats = try db.stats()
        XCTAssertEqual(stats.totalSessions, 2)
        XCTAssertEqual(stats.totalMessages, 15)
        XCTAssertEqual(stats.bySource["claude-code"], 1)
        XCTAssertEqual(stats.bySource["cursor"], 1)
    }

    @MainActor
    func testKPIStats() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code", project: "engram", messageCount: 10)
        try insertTestSession(at: dbPath, id: "s2", source: "cursor", project: "my-app", messageCount: 5)

        let kpi = try db.kpiStats()
        XCTAssertEqual(kpi.sessions, 2)
        XCTAssertEqual(kpi.sources, 2)
        XCTAssertEqual(kpi.messages, 15)
        XCTAssertEqual(kpi.projects, 2)
    }

    // MARK: - Hide/Unhide

    @MainActor
    func testHideAndUnhideSession() throws {
        try insertTestSession(at: dbPath, id: "s1")

        try db.hideSession(id: "s1")
        // Hidden sessions should not appear in normal queries
        let sessions = try db.listSessions()
        XCTAssertEqual(sessions.count, 0)

        // But should appear in hidden list
        let hidden = try db.listHiddenSessions()
        XCTAssertEqual(hidden.count, 1)

        try db.unhideSession(id: "s1")
        let restored = try db.listSessions()
        XCTAssertEqual(restored.count, 1)
    }

    @MainActor
    func testCountHiddenSessions() throws {
        try insertTestSession(at: dbPath, id: "s1")
        try insertTestSession(at: dbPath, id: "s2")
        try db.hideSession(id: "s1")

        let count = try db.countHiddenSessions()
        XCTAssertEqual(count, 1)
    }

    // MARK: - Rename

    @MainActor
    func testRenameSession() throws {
        try insertTestSession(at: dbPath, id: "s1")
        try db.renameSession(id: "s1", name: "My Custom Name")

        let session = try db.getSession(id: "s1")
        XCTAssertEqual(session?.customName, "My Custom Name")
    }

    // MARK: - Tier filtering

    @MainActor
    func testListSessionsExcludesSkipTier() throws {
        try insertTestSession(at: dbPath, id: "s1", tier: "normal")
        try insertTestSession(at: dbPath, id: "s2", tier: "skip")

        let sessions = try db.listSessions(subAgent: false)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "s1")
    }

    // MARK: - DB size

    @MainActor
    func testDbSizeBytesReturnsPositiveValue() throws {
        XCTAssertGreaterThan(db.dbSizeBytes(), 0)
    }

    // MARK: - FTS Search

    @MainActor
    func testSearchReturnsFTSMatches() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "refactored the database connection pooling logic")

        let results = try db.search(query: "database connection")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "s1")
    }

    @MainActor
    func testSearchWithCJKContent() throws {
        try insertTestSession(at: dbPath, id: "s-cjk", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "s-cjk", content: "重构了数据库连接池逻辑")

        // CJK path requires query.count >= 2 and uses LIKE fallback
        let results = try db.search(query: "数据库")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "s-cjk")
    }

    @MainActor
    func testSearchWithJapaneseContent() throws {
        try insertTestSession(at: dbPath, id: "s-jp", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "s-jp", content: "データベース接続プールをリファクタリング")

        let results = try db.search(query: "データベース")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "s-jp")
    }

    @MainActor
    func testSearchExcludesHiddenSessions() throws {
        try insertTestSession(at: dbPath, id: "s-visible", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s-hidden", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "s-visible", content: "visible session with search terms")
        try insertFTSContent(at: dbPath, sessionId: "s-hidden", content: "hidden session with search terms")
        try db.hideSession(id: "s-hidden")

        let results = try db.search(query: "search terms")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "s-visible")
    }

    @MainActor
    func testSearchShortQueryReturnsEmpty() throws {
        try insertTestSession(at: dbPath, id: "s1")
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "some content")

        // 1-char query should return empty (guard query.count >= 2)
        let results = try db.search(query: "a")
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Tier filtering (extended)

    @MainActor
    func testListSessionsWithNullTierTreatedAsNormal() throws {
        try insertTestSession(at: dbPath, id: "s-null-tier", tier: nil)

        // subAgent:false filters skip tier but keeps null tier
        let sessions = try db.listSessions(subAgent: false)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "s-null-tier")
    }

    @MainActor
    func testListSessionsWithAllTiers() throws {
        try insertTestSession(at: dbPath, id: "s-skip", tier: "skip", agentRole: "sub")
        try insertTestSession(at: dbPath, id: "s-lite", tier: "lite", agentRole: "sub")
        try insertTestSession(at: dbPath, id: "s-normal", tier: "normal", agentRole: "sub")
        try insertTestSession(at: dbPath, id: "s-premium", tier: "premium", agentRole: "sub")

        // subAgent:true returns all tiers (no tier filter applied)
        let sessions = try db.listSessions(subAgent: true)
        XCTAssertEqual(sessions.count, 4)
    }

    @MainActor
    func testCountSessionsExcludesSkipTier() throws {
        try insertTestSession(at: dbPath, id: "s1", tier: "normal")
        try insertTestSession(at: dbPath, id: "s2", tier: "skip")
        try insertTestSession(at: dbPath, id: "s3", tier: "lite")

        let count = try db.countSessions(subAgent: false)
        XCTAssertEqual(count, 2) // normal + lite, skip excluded
    }

    // MARK: - Observability

    @MainActor
    func testFetchLogsReturnsInsertedLogs() throws {
        try insertTestLog(at: dbPath, level: "info", module: "indexer", message: "Indexed 5 sessions")
        try insertTestLog(at: dbPath, level: "info", module: "watcher", message: "File changed")
        try insertTestLog(at: dbPath, level: "error", module: "indexer", message: "Parse failed")

        let result = try db.fetchLogs(level: "All", module: "indexer", limit: 10)
        XCTAssertEqual(result.entries.count, 2) // 2 indexer logs
        XCTAssertTrue(result.modules.contains("indexer"))
        XCTAssertTrue(result.modules.contains("watcher"))
    }

    @MainActor
    func testErrorsByModule24h() throws {
        // Insert errors with current timestamps (default ts = now)
        try insertTestLog(at: dbPath, level: "error", module: "indexer", message: "Error 1")
        try insertTestLog(at: dbPath, level: "error", module: "indexer", message: "Error 2")
        try insertTestLog(at: dbPath, level: "error", module: "watcher", message: "Error 3")
        // Non-error should not appear
        try insertTestLog(at: dbPath, level: "info", module: "indexer", message: "OK")

        let errors = try db.errorsByModule24h()
        XCTAssertEqual(errors.count, 2) // indexer, watcher
        let indexerErrors = errors.first { $0.module == "indexer" }
        XCTAssertEqual(indexerErrors?.count, 2)
        let watcherErrors = errors.first { $0.module == "watcher" }
        XCTAssertEqual(watcherErrors?.count, 1)
    }

    @MainActor
    func testObservabilityTableCounts() throws {
        try insertTestSession(at: dbPath, id: "s1")
        try insertTestLog(at: dbPath, level: "info", module: "test", message: "msg")

        let counts = try db.observabilityTableCounts()
        // Should have entries for sessions, logs, traces, metrics, metrics_hourly, sessions_fts
        XCTAssertGreaterThanOrEqual(counts.count, 4)
        let sessionCount = counts.first { $0.table == "sessions" }
        XCTAssertEqual(sessionCount?.count, 1)
        let logCount = counts.first { $0.table == "logs" }
        XCTAssertEqual(logCount?.count, 1)
    }

    // MARK: - Stats edge cases

    @MainActor
    func testStatsWithEmptyDatabase() throws {
        let stats = try db.stats()
        XCTAssertEqual(stats.totalSessions, 0)
        XCTAssertEqual(stats.totalMessages, 0)
        XCTAssertTrue(stats.bySource.isEmpty)
    }

    @MainActor
    func testKPIStatsWithEmptyDatabase() throws {
        let kpi = try db.kpiStats()
        XCTAssertEqual(kpi.sessions, 0)
        XCTAssertEqual(kpi.sources, 0)
        XCTAssertEqual(kpi.messages, 0)
        XCTAssertEqual(kpi.projects, 0)
    }

    @MainActor
    func testListSessionsWithMultipleSourceFilters() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s2", source: "cursor")
        try insertTestSession(at: dbPath, id: "s3", source: "codex")

        let results = try db.listSessions(sources: Set(["claude-code", "cursor"]))
        XCTAssertEqual(results.count, 2)
        let sources = Set(results.map(\.source))
        XCTAssertTrue(sources.contains("claude-code"))
        XCTAssertTrue(sources.contains("cursor"))
        XCTAssertFalse(sources.contains("codex"))
    }

    @MainActor
    func testListSessionsWithMultipleProjectFilters() throws {
        try insertTestSession(at: dbPath, id: "s1", project: "engram")
        try insertTestSession(at: dbPath, id: "s2", project: "my-app")
        try insertTestSession(at: dbPath, id: "s3", project: "other")

        let results = try db.listSessions(projects: Set(["engram", "my-app"]))
        XCTAssertEqual(results.count, 2)
        let projects = Set(results.compactMap(\.project))
        XCTAssertTrue(projects.contains("engram"))
        XCTAssertTrue(projects.contains("my-app"))
        XCTAssertFalse(projects.contains("other"))
    }
}
