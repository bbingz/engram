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

    func testOpenDoesNotCreateServiceOwnedExtensionTables() throws {
        let tables = try db.readInBackground { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        XCTAssertFalse(tables.contains("favorites"), "App read model must not create favorites")
        XCTAssertFalse(tables.contains("tags"), "App read model must not create tags")
    }

    func testPathReturnsCorrectPath() throws {
        XCTAssertEqual(db.path, dbPath)
    }

    // UI-M4: `journalMode()` must report the real PRAGMA value, not a hardcoded
    // "WAL Mode: OK". SystemHealthView drives its journal-mode status row from it.
    func testJournalModeReportsRealPragmaValue() throws {
        let mode = try db.journalMode()
        // A freshly opened SQLite DB reports a concrete journal mode (e.g. "wal",
        // "delete", "memory"); it must never be the empty/"unknown" placeholder.
        XCTAssertFalse(mode.isEmpty)
        XCTAssertNotEqual(mode, "unknown")
    }

    @MainActor
    func testReadInBackgroundLazilyOpensExistingDatabase() throws {
        let lazyDb = DatabaseManager(path: dbPath)

        let count = try lazyDb.readInBackground { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions")
        }

        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testReadInBackgroundThrowsForMissingDatabase() throws {
        let closedDb = DatabaseManager(path: "/tmp/nonexistent-\(UUID().uuidString).sqlite")
        XCTAssertThrowsError(try closedDb.readInBackground { db in
            try String.fetchAll(db, sql: "SELECT 1")
        })
    }

    // MARK: - Favorites

    @MainActor
    func testIsFavoriteReadsServiceOwnedFavorite() throws {
        try insertTestSession(at: dbPath)
        try insertFavorite(at: dbPath, sessionId: "test-session-001")
        XCTAssertTrue(try db.isFavorite(sessionId: "test-session-001"))

        try deleteFavorite(at: dbPath, sessionId: "test-session-001")
        XCTAssertFalse(try db.isFavorite(sessionId: "test-session-001"))
    }

    @MainActor
    func testListFavorites() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s2", source: "cursor")
        try insertFavorite(at: dbPath, sessionId: "s1")
        try insertFavorite(at: dbPath, sessionId: "s2")

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
    func testListSessionsSinceUsesActivityTime() throws {
        try insertTestSession(
            at: dbPath,
            id: "started-yesterday-active-today",
            startTime: "2026-05-08T10:00:00Z",
            endTime: "2026-05-09T01:00:00Z"
        )
        try insertTestSession(
            at: dbPath,
            id: "inactive-yesterday",
            startTime: "2026-05-08T08:00:00Z",
            endTime: "2026-05-08T09:00:00Z"
        )

        let sessions = try db.listSessions(since: "2026-05-09T00:00:00Z")

        XCTAssertEqual(sessions.map(\.id), ["started-yesterday-active-today"])
    }

    @MainActor
    func testSessionTimelineCanUseActivityOrCreatedTime() throws {
        try insertTestSession(
            at: dbPath,
            id: "started-yesterday-active-today",
            startTime: "2026-05-08T10:00:00Z",
            endTime: "2026-05-09T01:00:00Z"
        )
        try insertTestSession(
            at: dbPath,
            id: "created-today",
            startTime: "2026-05-09T00:30:00Z",
            endTime: nil
        )

        let byActivity = try db.sessionTimeline(days: 10_000, sort: .updatedDesc)

        XCTAssertEqual(byActivity.map(\.date), ["2026-05-09"])
        XCTAssertEqual(
            byActivity.first?.sessions.map(\.id),
            ["started-yesterday-active-today", "created-today"]
        )

        let byCreated = try db.sessionTimeline(days: 10_000, sort: .createdDesc)

        XCTAssertEqual(byCreated.map(\.date), ["2026-05-09", "2026-05-08"])
        XCTAssertEqual(byCreated[0].sessions.map(\.id), ["created-today"])
        XCTAssertEqual(byCreated[1].sessions.map(\.id), ["started-yesterday-active-today"])
    }

    @MainActor
    func testListSessionsCanIncludeHiddenSessions() throws {
        try insertTestSession(at: dbPath, id: "visible")
        try insertTestSession(at: dbPath, id: "hidden")
        try setHidden(at: dbPath, sessionId: "hidden", hidden: true)

        XCTAssertEqual(try db.listSessions().map(\.id), ["visible"])

        let sessions = try db.listSessions(includeHidden: true)

        XCTAssertEqual(Set(sessions.map(\.id)), Set(["visible", "hidden"]))
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

    @MainActor
    func testSessionListStatsCountsAllMatchesBeyondPageLimit() throws {
        for i in 0..<201 {
            try insertTestSession(
                at: dbPath,
                id: "s\(i)",
                source: i.isMultiple(of: 2) ? "claude-code" : "codex",
                messageCount: 1
            )
        }

        let page = try db.listSessions(subAgent: false, limit: 200)
        let stats = try db.sessionListStats(subAgent: false)

        XCTAssertEqual(page.count, 200)
        XCTAssertEqual(stats.totalSessions, 201)
        XCTAssertEqual(stats.totalMessages, 201)
        XCTAssertEqual(Set(stats.sources), Set(["claude-code", "codex"]))
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

        try setHidden(at: dbPath, sessionId: "s1", hidden: true)
        // Hidden sessions should not appear in normal queries
        let sessions = try db.listSessions()
        XCTAssertEqual(sessions.count, 0)

        // But should appear in hidden list
        let hidden = try db.listHiddenSessions()
        XCTAssertEqual(hidden.count, 1)

        try setHidden(at: dbPath, sessionId: "s1", hidden: false)
        let restored = try db.listSessions()
        XCTAssertEqual(restored.count, 1)
    }

    @MainActor
    func testCountHiddenSessions() throws {
        try insertTestSession(at: dbPath, id: "s1")
        try insertTestSession(at: dbPath, id: "s2")
        try setHidden(at: dbPath, sessionId: "s1", hidden: true)

        let count = try db.countHiddenSessions()
        XCTAssertEqual(count, 1)
    }

    // MARK: - Rename

    @MainActor
    func testRenameSession() throws {
        try insertTestSession(at: dbPath, id: "s1")
        try setCustomName(at: dbPath, sessionId: "s1", name: "My Custom Name")

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

    // quality_score (already computed at index time) must decode into the GUI
    // read model. Session uses an explicit CodingKeys enum, so qualityScore must
    // be a listed key or it silently stays nil.
    @MainActor
    func testSearchPopulatesQualityScore() throws {
        try insertTestSession(at: dbPath, id: "s-hi", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s-lo", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "s-hi", content: "alpha widget refactor")
        try insertFTSContent(at: dbPath, sessionId: "s-lo", content: "alpha widget refactor")
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "UPDATE sessions SET quality_score = 65 WHERE id = 's-hi'")
            try db.execute(sql: "UPDATE sessions SET quality_score = 20 WHERE id = 's-lo'")
        }

        let results = try db.search(query: "widget")
        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        XCTAssertEqual(byId["s-hi"]?.qualityScore, 65)
        XCTAssertEqual(byId["s-lo"]?.qualityScore, 20)
    }

    // searchWithSnippets powers the GUI offline-fallback path: it must return a
    // match-centered <mark> highlight, not the transcript from char 0.
    @MainActor
    func testSearchWithSnippetsLatinHighlightsWindow() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 200)
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "\(filler) needle \(filler)")

        let hits = try db.searchWithSnippets(query: "needle", limit: 10)
        XCTAssertEqual(hits.map(\.session.id), ["s1"])
        let snippet = try XCTUnwrap(hits.first?.snippet)
        XCTAssertTrue(snippet.contains("<mark>needle</mark>"), "got: \(snippet.prefix(80))")
        XCTAssertLessThan(snippet.count, filler.count)
    }

    @MainActor
    func testSearchWithSnippetsCJKHighlightsWindow() throws {
        try insertTestSession(at: dbPath, id: "s-cjk", source: "claude-code")
        let filler = String(repeating: "你好世界这是填充内容", count: 80)
        try insertFTSContent(at: dbPath, sessionId: "s-cjk", content: "\(filler)需要修复这个缺陷\(filler)")

        let hits = try db.searchWithSnippets(query: "需要修复", limit: 10)
        XCTAssertEqual(hits.map(\.session.id), ["s-cjk"])
        let snippet = try XCTUnwrap(hits.first?.snippet)
        XCTAssertTrue(snippet.contains("<mark>需要修复</mark>"), "got: \(snippet.prefix(60))")
        XCTAssertLessThan(snippet.count, filler.count)
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
        try setHidden(at: dbPath, sessionId: "s-hidden", hidden: true)

        let results = try db.search(query: "search terms")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "s-visible")
    }

    @MainActor
    func testSearchExcludesSkipAndLiteSessions() throws {
        try insertTestSession(at: dbPath, id: "s-visible", source: "claude-code", tier: "normal")
        try insertTestSession(at: dbPath, id: "s-skip", source: "claude-code", tier: "skip")
        try insertTestSession(at: dbPath, id: "s-lite", source: "claude-code", tier: "lite")
        try insertFTSContent(at: dbPath, sessionId: "s-visible", content: "visible session with search terms")
        try insertFTSContent(at: dbPath, sessionId: "s-skip", content: "skip session with search terms")
        try insertFTSContent(at: dbPath, sessionId: "s-lite", content: "lite session with search terms")

        let results = try db.search(query: "search terms")
        XCTAssertEqual(results.map(\.id), ["s-visible"])
    }

    @MainActor
    func testSearchAppliesProjectSourceAndSinceFilters() throws {
        try insertTestSession(
            at: dbPath,
            id: "match",
            source: "codex",
            project: "engram",
            startTime: "2026-05-20T10:00:00Z",
            endTime: nil
        )
        try insertTestSession(
            at: dbPath,
            id: "wrong-project",
            source: "codex",
            project: "other",
            startTime: "2026-05-20T10:00:00Z",
            endTime: nil
        )
        try insertTestSession(
            at: dbPath,
            id: "wrong-source",
            source: "claude-code",
            project: "engram",
            startTime: "2026-05-20T10:00:00Z",
            endTime: nil
        )
        try insertTestSession(
            at: dbPath,
            id: "too-old",
            source: "codex",
            project: "engram",
            startTime: "2026-04-20T10:00:00Z",
            endTime: nil
        )
        for id in ["match", "wrong-project", "wrong-source", "too-old"] {
            try insertFTSContent(at: dbPath, sessionId: id, content: "filterable search terms")
        }

        let results = try db.search(
            query: "search terms",
            limit: 10,
            sources: Set(["codex"]),
            projects: Set(["engram"]),
            since: "2026-05-01T00:00:00Z"
        )

        XCTAssertEqual(results.map(\.id), ["match"])
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
