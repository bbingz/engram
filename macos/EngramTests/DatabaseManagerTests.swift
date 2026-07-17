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
        let queue = try DatabaseQueue(path: dbPath)
        let tables = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        XCTAssertFalse(tables.contains("favorites"), "App read model must not create favorites")
        XCTAssertFalse(tables.contains("tags"), "App read model must not create tags")
    }

    func testDatabaseManagerReadsSwiftGatedFixtureSchema() throws {
        guard let fixturePath = Bundle(for: type(of: self)).path(
            forResource: "test-index",
            ofType: "sqlite",
            inDirectory: "test-fixtures"
        ) else {
            return XCTFail("missing test-index.sqlite fixture")
        }
        let copiedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-fixture-read-\(UUID().uuidString).sqlite")
            .path
        try FileManager.default.copyItem(atPath: fixturePath, toPath: copiedPath)
        defer { cleanupTempDatabase(at: copiedPath) }

        let queue = try DatabaseQueue(path: copiedPath)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                arguments: ["seed-01", "fixture bridge marker"]
            )
        }

        let fixtureDb = DatabaseManager(path: copiedPath)
        try fixtureDb.open()

        let sessions = try fixtureDb.listSessions(limit: 5)
        XCTAssertFalse(sessions.isEmpty)
        let stats = try fixtureDb.sessionListStats()
        XCTAssertGreaterThan(stats.totalSessions, 0)
        let search = try fixtureDb.searchWithSnippets(query: "fixture bridge", limit: 1)
        XCTAssertEqual(search.first?.session.id, "seed-01")
        XCTAssertTrue(search.first?.snippet.contains("<mark>") ?? false)
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

    // The GUI read pool must apply the shared cache_size (SharedDBConfig), so it
    // cannot drift from SQLiteConnectionPolicy. cache_size is negative (KiB).
    func testReadPoolAppliesSharedCacheSize() throws {
        XCTAssertEqual(try db.cacheSize(), -SharedDBConfig.cacheSizeKiB)
    }

    @MainActor
    func testIndexJobCountsByStatusReadsGroupedCounts() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_index_jobs (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    job_kind TEXT NOT NULL,
                    target_sync_version INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                    not_before TEXT
                )
                """)
            try database.execute(sql: """
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status) VALUES
                ('job-pending-1', 'session-1', 'fts', 1, 'pending'),
                ('job-pending-2', 'session-2', 'embedding', 1, 'pending'),
                ('job-permanent-1', 'session-3', 'fts', 1, 'failed_permanent')
                """)
        }

        XCTAssertEqual(try db.indexJobCountsByStatus(), [
            IndexJobStatus.pending.rawValue: 2,
            IndexJobStatus.failedPermanent.rawValue: 1,
        ])
    }

    @MainActor
    func testReadInBackgroundLazilyOpensExistingDatabase() throws {
        let lazyDb = DatabaseManager(path: dbPath)

        XCTAssertEqual(try lazyDb.sessionListStats().totalSessions, 0)
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
    func testListSessionsCanFilterFavoritesWithoutUsingFavoritesPageQuery() throws {
        try insertTestSession(at: dbPath, id: "favorite-visible", source: "claude-code")
        try insertTestSession(at: dbPath, id: "not-favorite", source: "cursor")
        try insertTestSession(at: dbPath, id: "favorite-hidden", source: "codex", hiddenAt: "2026-05-09T00:00:00Z")
        try insertFavorite(at: dbPath, sessionId: "favorite-visible")
        try insertFavorite(at: dbPath, sessionId: "favorite-hidden")

        let visibleFavorites = try db.listSessions(favoritesOnly: true, sort: .createdDesc)
        XCTAssertEqual(visibleFavorites.map(\.id), ["favorite-visible"])

        let allFavorites = try db.listSessions(includeHidden: true, favoritesOnly: true, sort: .createdDesc)
        XCTAssertEqual(allFavorites.map(\.id), ["favorite-hidden", "favorite-visible"])
    }

    @MainActor
    func testSessionListStatsCanFilterFavorites() throws {
        try insertTestSession(at: dbPath, id: "favorite", source: "claude-code", messageCount: 5)
        try insertTestSession(at: dbPath, id: "not-favorite", source: "cursor", messageCount: 7)
        try insertFavorite(at: dbPath, sessionId: "favorite")

        let stats = try db.sessionListStats(favoritesOnly: true)
        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.totalMessages, 5)
        XCTAssertEqual(stats.sources, ["claude-code"])
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
    func testListSessionsDefaultsToLastAccessedTimeWhenPresent() throws {
        try insertTestSession(
            at: dbPath,
            id: "created-newer",
            startTime: "2026-05-09T12:00:00Z"
        )
        try insertTestSession(
            at: dbPath,
            id: "accessed-newer",
            startTime: "2026-05-08T12:00:00Z"
        )
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET last_accessed_at = ? WHERE id = ?",
                arguments: ["2026-05-10T12:00:00Z", "accessed-newer"]
            )
        }

        let sessions = try db.listSessions()

        XCTAssertEqual(sessions.map(\.id), ["accessed-newer", "created-newer"])
        XCTAssertEqual(sessions.first?.lastAccessedAt, "2026-05-10T12:00:00Z")
        XCTAssertEqual(sessions.first?.accessCount, 0)
    }

    func testAccessedSortFallsBackToCreatedSortWithoutAccessMetadataColumns() {
        XCTAssertEqual(
            SessionSort.accessedDesc.orderSQL(hasAccessMetadata: false),
            SessionSort.createdDesc.rawValue
        )
        XCTAssertEqual(
            SessionSort.accessedAsc.orderSQL(hasAccessMetadata: false),
            SessionSort.createdAsc.rawValue
        )
        XCTAssertEqual(
            SessionSort.updatedDesc.orderSQL(hasAccessMetadata: false),
            SessionSort.updatedDesc.rawValue
        )
    }

    @MainActor
    func testListGroupsAccessedSortFallsBackOnLegacySchema() throws {
        db = nil
        cleanupTempDatabase(at: dbPath)
        try createLegacySessionsTableWithoutAccessMetadata(at: dbPath)
        db = DatabaseManager(path: dbPath)
        try db.open()

        let groups = try db.listGroups(by: .project, sort: .accessedDesc)

        XCTAssertEqual(groups.map(\.key), ["newer", "older"])
        XCTAssertEqual(groups.map(\.lastUpdated), ["2026-05-10T12:00:00Z", "2026-05-09T12:00:00Z"])
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
    func testSessionTimelineAccessedSortUsesLastAccessedForGrouping() throws {
        try insertTestSession(
            at: dbPath,
            id: "started-yesterday-accessed-today",
            startTime: "2026-05-08T10:00:00Z",
            endTime: nil
        )
        try insertTestSession(
            at: dbPath,
            id: "created-today",
            startTime: "2026-05-09T00:30:00Z",
            endTime: nil
        )
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET last_accessed_at = ? WHERE id = ?",
                arguments: ["2026-05-09T12:00:00Z", "started-yesterday-accessed-today"]
            )
        }

        let byAccessed = try db.sessionTimeline(days: 10_000, sort: .accessedDesc)

        XCTAssertEqual(byAccessed.map(\.date), ["2026-05-09"])
        XCTAssertEqual(
            byAccessed.first?.sessions.map(\.id),
            ["started-yesterday-accessed-today", "created-today"]
        )
    }

    @MainActor
    func testSessionTimelineAppliesDefaultLimit() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            for index in 0..<2_005 {
                let timestamp = String(
                    format: "2026-05-09T%02d:%02d:%02dZ",
                    index / 3_600,
                    (index / 60) % 60,
                    index % 60
                )
                try db.execute(sql: """
                    INSERT INTO sessions (
                        id, source, start_time, end_time, cwd, project, model,
                        message_count, user_message_count, assistant_message_count,
                        tool_message_count, system_message_count, summary, file_path,
                        size_bytes, indexed_at, tier
                    ) VALUES (?, 'claude-code', ?, NULL, '/tmp', 'engram', 'sonnet',
                        1, 1, 0, 0, 0, NULL, ?, 1, datetime('now'), 'normal')
                """, arguments: ["limit-\(index)", timestamp, "/tmp/limit-\(index).jsonl"])
            }
        }

        let byCreated = try db.sessionTimeline(days: 10_000, sort: .createdDesc)
        let sessions = byCreated.flatMap(\.sessions)

        XCTAssertEqual(sessions.count, 2_000)
        XCTAssertEqual(sessions.first?.id, "limit-2004")
        XCTAssertEqual(sessions.last?.id, "limit-5")
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

    @MainActor
    func testSearchMatchesTermsAcrossMessagesWithinSameSession() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s2", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "alpha planning note")
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "beta verifier note")
        try insertFTSContent(at: dbPath, sessionId: "s2", content: "alpha only note")

        let results = try db.search(query: "alpha beta")

        XCTAssertEqual(results.map(\.id), ["s1"])
    }

    // quality_score (already computed at index time) must decode into the GUI
    // read model. Session uses an explicit CodingKeys enum, so qualityScore must
    // be a listed key or it silently stays nil.
    @MainActor
    func testSearchPopulatesQualityScoreAndValueBand() throws {
        for id in ["s-hi", "s-lo", "s-mid", "s-none"] {
            try insertTestSession(at: dbPath, id: id, source: "claude-code")
            try insertFTSContent(at: dbPath, sessionId: id, content: "alpha widget refactor")
        }
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "UPDATE sessions SET quality_score = 65 WHERE id = 's-hi'")
            try db.execute(sql: "UPDATE sessions SET quality_score = 20 WHERE id = 's-lo'")
            try db.execute(sql: "UPDATE sessions SET quality_score = 45 WHERE id = 's-mid'")
        }

        let byId = Dictionary(uniqueKeysWithValues: try db.search(query: "widget").map { ($0.id, $0) })
        XCTAssertEqual(byId["s-hi"]?.qualityScore, 65)
        XCTAssertEqual(byId["s-hi"]?.valueBand, .high)      // >= 60
        XCTAssertEqual(byId["s-lo"]?.valueBand, .low)       // <= 35
        XCTAssertEqual(byId["s-mid"]?.valueBand, .medium)   // 36..59
        XCTAssertEqual(byId["s-none"]?.valueBand, .unknown) // no quality_score
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
    func testSearchWithSnippetsMatchesTermsAcrossMessagesWithinSameSession() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertTestSession(at: dbPath, id: "s2", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "alpha planning note")
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "beta verifier note")
        try insertFTSContent(at: dbPath, sessionId: "s2", content: "alpha only note")

        let hits = try db.searchWithSnippets(query: "alpha beta", limit: 10)

        XCTAssertEqual(hits.map(\.session.id), ["s1"])
        let snippet = try XCTUnwrap(hits.first?.snippet)
        XCTAssertTrue(snippet.contains("<mark>alpha</mark>") || snippet.contains("<mark>beta</mark>"), "got: \(snippet)")
    }

    @MainActor
    func testSearchShortLatinAbbreviationUsesLiteralFallback() throws {
        try insertTestSession(at: dbPath, id: "s-ai", source: "codex")
        try insertTestSession(at: dbPath, id: "s-other", source: "codex")
        try insertFTSContent(at: dbPath, sessionId: "s-ai", content: "Ship the AI usage monitor before release")
        try insertFTSContent(at: dbPath, sessionId: "s-other", content: "Ship the quota monitor before release")

        let results = try db.search(query: "AI")

        XCTAssertEqual(results.map(\.id), ["s-ai"])
    }

    @MainActor
    func testSearchWithSnippetsShortLatinAbbreviationHighlightsLiteralFallback() throws {
        try insertTestSession(at: dbPath, id: "s-ui", source: "codex")
        try insertFTSContent(at: dbPath, sessionId: "s-ui", content: "Polish the UI quota warning")

        let hits = try db.searchWithSnippets(query: "UI", limit: 10)

        XCTAssertEqual(hits.map(\.session.id), ["s-ui"])
        XCTAssertTrue(hits.first?.snippet.contains("<mark>UI</mark>") ?? false, "got: \(hits.first?.snippet ?? "")")
    }

    @MainActor
    func testSearchShortLatinFallbackEscapesLikeWildcards() throws {
        try insertTestSession(at: dbPath, id: "literal", source: "codex")
        try insertTestSession(at: dbPath, id: "wildcard", source: "codex")
        try insertFTSContent(at: dbPath, sessionId: "literal", content: "Exact A_ marker")
        try insertFTSContent(at: dbPath, sessionId: "wildcard", content: "Exact AI marker")

        let results = try db.search(query: "A_")

        XCTAssertEqual(results.map(\.id), ["literal"])
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

    // FTS5 syntax characters in a raw query used to throw "fts5: syntax error".
    // ftsMatchQuery quotes each token so they are matched literally.
    @MainActor
    func testSearchToleratesFTS5SyntaxCharacters() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "the call site is handleRequest(payload) in the router")

        let results = try db.search(query: "handleRequest(payload)")
        XCTAssertEqual(results.map(\.id), ["s1"])
        // Quotes and bareword operators must be literal too, not FTS5 syntax.
        XCTAssertNoThrow(try db.search(query: "a \"b\" OR c"))
        XCTAssertNoThrow(try db.searchWithSnippets(query: "handleRequest(payload)", limit: 5))
    }

    // Hangul must route through the CJK LIKE fallback (trigram MATCH is broken for
    // Korean). Before the containsCJK fix, Hangul Syllables (>= U+AC00) were not
    // detected, so this took the MATCH path and returned nothing.
    @MainActor
    func testSearchWithKoreanContent() throws {
        try insertTestSession(at: dbPath, id: "s-ko", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "s-ko", content: "데이터베이스 연결 풀 로직을 리팩터링했다")

        let results = try db.search(query: "데이터베이스")
        XCTAssertEqual(results.map(\.id), ["s-ko"])
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
    func testSearchWhitespaceQueryBrowsesRecentVisibleSessions() throws {
        try insertTestSession(at: dbPath, id: "older", source: "codex", startTime: "2026-05-01T10:00:00Z", tier: "normal")
        try insertTestSession(at: dbPath, id: "newer", source: "codex", startTime: "2026-05-02T10:00:00Z", tier: "normal")
        try insertTestSession(at: dbPath, id: "skip", source: "codex", startTime: "2026-05-03T10:00:00Z", tier: "skip")
        try insertTestSession(at: dbPath, id: "lite", source: "codex", startTime: "2026-05-04T10:00:00Z", tier: "lite")
        try insertTestSession(at: dbPath, id: "hidden", source: "codex", startTime: "2026-05-05T10:00:00Z", tier: "normal")
        try setHidden(at: dbPath, sessionId: "hidden", hidden: true)

        let sessions = try db.search(query: "   ", limit: 10)
        let hits = try db.searchWithSnippets(query: "   ", limit: 10)

        XCTAssertEqual(sessions.map(\.id), ["newer", "older"])
        XCTAssertEqual(hits.map(\.session.id), ["newer", "older"])
        XCTAssertTrue(hits.allSatisfy { $0.snippet.isEmpty })
    }

    @MainActor
    func testProjectTimelineEscapesLikeWildcards() throws {
        try insertTestSession(at: dbPath, id: "literal-project", project: "my_repo")
        try insertTestSession(at: dbPath, id: "wildcard-project", project: "myXrepo")

        let projects = try db.projectTimeline(project: "my_repo").compactMap(\.project)

        XCTAssertEqual(projects, ["my_repo"])
    }

    @MainActor
    func testGetContextEscapesLikeWildcards() throws {
        try insertTestSession(at: dbPath, id: "literal-context-project", project: "my_repo")
        try insertTestSession(at: dbPath, id: "wildcard-context-project", project: "myXrepo")

        let projectMatches = try db.getContext(cwd: "/Users/test/my_repo", limit: 10).map(\.id)

        XCTAssertEqual(projectMatches, ["literal-context-project"])

        try insertSessionWithCwd(
            at: dbPath,
            id: "literal-context-cwd",
            cwd: "/Users/test/repo_1/sub",
            startTime: "2026-03-22T10:00:00Z"
        )
        try insertSessionWithCwd(
            at: dbPath,
            id: "wildcard-context-cwd",
            cwd: "/Users/test/repoX1/sub",
            startTime: "2026-03-22T10:00:00Z"
        )

        let cwdMatches = try db.getContext(cwd: "/Users/test/repo_1", limit: 10).map(\.id)

        XCTAssertEqual(cwdMatches, ["literal-context-cwd"])
    }

    // Audit #25: the local offline-fallback search must drive from sessions_fts
    // via a CTE (mirroring EngramServiceReadProvider.keywordSearch), NOT probe
    // MATCH once per sessions row (which cost 80-100s vs 81ms on the live DB).
    // (a) result parity with the service-shaped CTE query, and (b) the local
    // plan contains no correlated per-row MATCH.
    @MainActor
    func testSearchFTSFallbackUsesCTEShapeMatchingService() throws {
        try insertTestSession(at: dbPath, id: "s1", source: "claude-code", startTime: "2026-05-01T10:00:00Z")
        try insertTestSession(at: dbPath, id: "s2", source: "claude-code", startTime: "2026-05-02T10:00:00Z")
        try insertTestSession(at: dbPath, id: "s3", source: "claude-code", startTime: "2026-05-03T10:00:00Z")
        // s1 has the two terms in separate FTS rows; s2 in one row; s3 only "alpha".
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "alpha planning note")
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "beta verifier note")
        try insertFTSContent(at: dbPath, sessionId: "s2", content: "alpha beta together")
        try insertFTSContent(at: dbPath, sessionId: "s3", content: "alpha only, missing second term")

        let local = try db.search(query: "alpha beta", limit: 10).map(\.id)

        // (a) Parity with the service-side CTE query shape (drive from FTS,
        // inner-join per term, order by first term's rank then start_time).
        let terms = CJKText.ftsMatchTerms("alpha beta")
        let reference = try DatabaseQueue(path: dbPath).read { db -> [String] in
            try String.fetchAll(db, sql: """
                WITH m0 AS (SELECT session_id, MIN(rank) AS rank FROM sessions_fts
                            WHERE sessions_fts MATCH ? GROUP BY session_id),
                     m1 AS (SELECT session_id, MIN(rank) AS rank FROM sessions_fts
                            WHERE sessions_fts MATCH ? GROUP BY session_id)
                SELECT s.id
                FROM m0
                JOIN m1 ON m1.session_id = m0.session_id
                JOIN sessions s ON s.id = m0.session_id
                WHERE s.hidden_at IS NULL AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
                ORDER BY m0.rank, s.start_time DESC
                LIMIT 10
            """, arguments: StatementArguments(terms))
        }

        XCTAssertEqual(Set(local), Set(["s1", "s2"]), "only sessions containing both terms may match")
        XCTAssertEqual(local, reference, "local fallback must match the service CTE query shape (ids and order)")

        // (b) The generated SQL no longer probes MATCH per sessions row.
        let built = DatabaseManager.keywordSearchSQL(
            termMatches: terms,
            snippetMatch: terms.first ?? CJKText.ftsMatchQuery("alpha beta"),
            sources: [], projects: [], since: nil, limit: 10, withSnippet: false
        )
        XCTAssertTrue(built.sql.contains("m0 AS ("), "must be CTE-driven: \(built.sql)")
        XCTAssertTrue(built.sql.contains("m1 AS ("), "each term gets its own CTE: \(built.sql)")
        XCTAssertFalse(built.sql.contains("EXISTS"), "correlated per-row MATCH filter must be gone")
        XCTAssertTrue(built.sql.contains("ORDER BY m0.rank"), "rank must come from the CTE, not a correlated subquery")

        // And EXPLAIN QUERY PLAN confirms no correlated subquery / full sessions scan.
        let plan = try DatabaseQueue(path: dbPath).read { db -> String in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(built.sql)", arguments: StatementArguments(built.args))
                .map { ($0["detail"] as String?) ?? "" }
                .joined(separator: "\n")
        }
        XCTAssertFalse(plan.contains("CORRELATED"), "plan must have no correlated subquery:\n\(plan)")
        XCTAssertTrue(plan.contains("sessions_fts"), "plan must be FTS-driven:\n\(plan)")
    }

    @MainActor
    func testSearchShortQueryReturnsEmpty() throws {
        try insertTestSession(at: dbPath, id: "s1")
        try insertFTSContent(at: dbPath, sessionId: "s1", content: "some content")

        // 1-char query should return empty (guard query.count >= 2)
        let results = try db.search(query: "a")
        XCTAssertEqual(results.count, 0)
    }

    @MainActor
    func testWhitespaceOnlySearchBrowsesRecentVisibleSessions_repro() throws {
        try insertTestSession(at: dbPath, id: "old-visible", startTime: "2026-05-01T10:00:00Z", tier: "normal")
        try insertTestSession(at: dbPath, id: "new-visible", startTime: "2026-05-03T10:00:00Z", tier: "normal")
        try insertTestSession(at: dbPath, id: "skip-hidden", startTime: "2026-05-04T10:00:00Z", tier: "skip")
        try insertTestSession(at: dbPath, id: "lite-hidden", startTime: "2026-05-05T10:00:00Z", tier: "lite")
        try insertTestSession(
            at: dbPath,
            id: "user-hidden",
            startTime: "2026-05-06T10:00:00Z",
            hiddenAt: "2026-05-06T10:01:00Z"
        )

        // PR #142 regression: a whitespace-only query has no FTS terms, so the
        // app read path must browse recent visible sessions instead of returning [].
        let results = try db.search(query: "   ", limit: 10).map(\.id)

        XCTAssertEqual(results, ["new-visible", "old-visible"])
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

    /// L7: default `subAgent: nil` must hide skip-tier rows (ActivityView.openMostRecent).
    @MainActor
    func testListSessionsDefaultNilHidesSkipTier_repro() throws {
        try insertTestSession(at: dbPath, id: "s-skip", tier: "skip", agentRole: "sub")
        try insertTestSession(at: dbPath, id: "s-normal", tier: "normal")
        try insertTestSession(at: dbPath, id: "s-null", tier: nil)

        let sessions = try db.listSessions(sort: .createdDesc, limit: 10)
        let ids = Set(sessions.map(\.id))
        XCTAssertFalse(ids.contains("s-skip"), "L7: default listSessions must not leak skip-tier rows")
        XCTAssertTrue(ids.contains("s-normal"))
        XCTAssertTrue(ids.contains("s-null"))
    }

    @MainActor
    func testCountSessionsExcludesSkipTier() throws {
        try insertTestSession(at: dbPath, id: "s1", tier: "normal")
        try insertTestSession(at: dbPath, id: "s2", tier: "skip")
        try insertTestSession(at: dbPath, id: "s3", tier: "lite")

        let count = try db.countSessions(subAgent: false)
        XCTAssertEqual(count, 2) // normal + lite, skip excluded

        // L7: default nil matches false for skip exclusion.
        let defaultCount = try db.countSessions()
        XCTAssertEqual(defaultCount, 2)
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

    // MARK: - topLevelOnly filter

    // SessionsPageView lists top-level sessions only. Confirmed children
    // (parent_session_id) and suggested children (suggested_parent_id) are
    // shown nested under their parent, so they must not also appear as their
    // own top-level rows.
    @MainActor
    func testListSessionsTopLevelOnlyExcludesConfirmedAndSuggestedChildren() throws {
        try insertTestSession(at: dbPath, id: "parent")
        try insertTestSession(at: dbPath, id: "confirmed-child")
        try insertTestSession(at: dbPath, id: "suggested-child")
        try setParentLinks(at: dbPath, sessionId: "confirmed-child", parentSessionId: "parent")
        try setParentLinks(at: dbPath, sessionId: "suggested-child", suggestedParentId: "parent")

        // Default (topLevelOnly: false) returns every visible session.
        XCTAssertEqual(try db.listSessions(subAgent: false).count, 3)

        let topLevel = try db.listSessions(subAgent: false, topLevelOnly: true)
        XCTAssertEqual(topLevel.map(\.id), ["parent"])
    }

    @MainActor
    func testSessionListStatsTopLevelOnlyExcludesChildren() throws {
        try insertTestSession(at: dbPath, id: "parent", messageCount: 5)
        try insertTestSession(at: dbPath, id: "confirmed-child", messageCount: 7)
        try insertTestSession(at: dbPath, id: "suggested-child", messageCount: 9)
        try setParentLinks(at: dbPath, sessionId: "confirmed-child", parentSessionId: "parent")
        try setParentLinks(at: dbPath, sessionId: "suggested-child", suggestedParentId: "parent")

        let stats = try db.sessionListStats(subAgent: false, topLevelOnly: true)
        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.totalMessages, 5)
    }

    // listSessionsByProject backs ProjectsView's per-project counts; those
    // counts must not include nested children.
    @MainActor
    func testListSessionsByProjectExcludesChildren() throws {
        try insertTestSession(at: dbPath, id: "parent", project: "engram")
        try insertTestSession(at: dbPath, id: "confirmed-child", project: "engram")
        try insertTestSession(at: dbPath, id: "suggested-child", project: "engram")
        try setParentLinks(at: dbPath, sessionId: "confirmed-child", parentSessionId: "parent")
        try setParentLinks(at: dbPath, sessionId: "suggested-child", suggestedParentId: "parent")

        let groups = try db.listSessionsByProject()
        let engram = try XCTUnwrap(groups.first { $0.project == "engram" })
        XCTAssertEqual(engram.sessionCount, 1)
        XCTAssertEqual(engram.sessions.map(\.id), ["parent"])
    }

    /// H1: Projects page must not drop older projects when the global session
    /// window exceeds the old limit*10 fetch.
    @MainActor
    func testListSessionsByProjectDoesNotDropProjectsOutsideLimitWindow_repro() throws {
        // Insert 25 distinct projects with one session each, newest first.
        for index in 0..<25 {
            let ts = String(format: "2026-01-%02dT12:00:00Z", index + 1)
            try insertTestSession(
                at: dbPath,
                id: "proj-\(index)",
                project: "project-\(index)",
                startTime: ts
            )
        }
        // Old bug: LIMIT 100*10 was fine for small DBs; use limit=1 so the
        // broken path would only fetch 10 rows and drop 15 projects.
        let groups = try db.listSessionsByProject(limit: 1)
        XCTAssertEqual(
            groups.count,
            25,
            "H1: all projects must appear even when per-project preview limit is 1"
        )
        for group in groups {
            XCTAssertEqual(group.sessionCount, 1, "project \(group.project) count wrong")
            XCTAssertEqual(group.sessions.count, 1, "preview capped at limit")
        }
    }

    // MARK: - sparklineData date bucketing

    // sparklineData buckets by local calendar day on both the SQL and Swift
    // sides. A session whose UTC start_time falls on a different UTC day than
    // its local day (e.g. late-evening local time) must still land in the
    // local "today" bucket (index 6), not an adjacent one.
    @MainActor
    func testSparklineDataBucketsByLocalDay() throws {
        let repoPath = "/Users/test/repo"
        let calendar = Calendar.current
        let now = Date()
        // Pick a wall-clock time today at 23:30 local; in UTC this can roll to
        // the next or previous calendar day depending on the zone offset.
        let localLate = calendar.date(
            bySettingHour: 23, minute: 30, second: 0, of: calendar.startOfDay(for: now)
        ) ?? now
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        let startTimeUTC = utc.string(from: localLate)

        try insertSessionWithCwd(
            at: dbPath,
            id: "today-late",
            cwd: repoPath,
            startTime: startTimeUTC
        )

        let counts = try db.sparklineData(for: repoPath)
        XCTAssertEqual(counts.count, 7)
        // The local-late session belongs to today's bucket (last index).
        XCTAssertEqual(counts[6], 1, "expected today's local bucket to hold the session; got \(counts)")
        XCTAssertEqual(counts.reduce(0, +), 1, "session must appear in exactly one bucket; got \(counts)")
    }

    @MainActor
    func testDailyActivityBucketsByLocalDay() throws {
        let calendar = Calendar.current
        let localEarly = calendar.date(
            bySettingHour: 0, minute: 30, second: 0, of: calendar.startOfDay(for: Date())
        ) ?? Date()
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        let startTimeUTC = utc.string(from: localEarly)
        let localDayFormatter = DateFormatter()
        localDayFormatter.calendar = calendar
        localDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        localDayFormatter.timeZone = calendar.timeZone
        localDayFormatter.dateFormat = "yyyy-MM-dd"
        let expectedDay = localDayFormatter.string(from: localEarly)

        try insertSessionWithCwd(
            at: dbPath,
            id: "today-local-early",
            cwd: "/Users/test/repo",
            startTime: startTimeUTC
        )

        let daily = try db.dailyActivity(days: 2)
        XCTAssertEqual(daily.map(\.date), [expectedDay])
        XCTAssertEqual(daily.map(\.count), [1])

        let bySource = try db.dailySourceActivity(days: 2)
        XCTAssertEqual(bySource.map(\.date), [expectedDay])
        XCTAssertEqual(bySource.first?.segments.map(\.source), ["claude-code"])
        XCTAssertEqual(bySource.first?.segments.map(\.count), [1])
    }

    @MainActor
    func testSparklineDataMatchesCwdPrefixOnly() throws {
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        let today = utc.string(from: Date())
        try insertSessionWithCwd(at: dbPath, id: "in-repo", cwd: "/Users/test/repo/sub", startTime: today)
        try insertSessionWithCwd(at: dbPath, id: "other-repo", cwd: "/Users/test/elsewhere", startTime: today)
        // Exact repo root cwd must also count.
        try insertSessionWithCwd(at: dbPath, id: "at-root", cwd: "/Users/test/repo", startTime: today)

        let counts = try db.sparklineData(for: "/Users/test/repo")
        XCTAssertEqual(counts.reduce(0, +), 2)
    }

    /// L6: unanchored `cwd LIKE path%` over-counts sibling repos (`app` vs `app-v2`).
    @MainActor
    func testSparklineDataDoesNotMatchSiblingPathPrefix_repro() throws {
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        let today = utc.string(from: Date())
        try insertSessionWithCwd(at: dbPath, id: "app", cwd: "/Users/test/app", startTime: today)
        try insertSessionWithCwd(at: dbPath, id: "app-child", cwd: "/Users/test/app/src", startTime: today)
        try insertSessionWithCwd(at: dbPath, id: "app-v2", cwd: "/Users/test/app-v2", startTime: today)
        try insertSessionWithCwd(at: dbPath, id: "app-v2-child", cwd: "/Users/test/app-v2/src", startTime: today)

        let counts = try db.sparklineData(for: "/Users/test/app")
        XCTAssertEqual(
            counts.reduce(0, +),
            2,
            "L6: sibling repo app-v2 must not inflate sparkline for app; got \(counts)"
        )
    }

    @MainActor
    func testSparklineDataEscapesLikeWildcards() throws {
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        let today = utc.string(from: Date())
        try insertSessionWithCwd(at: dbPath, id: "literal-repo", cwd: "/Users/test/my_repo/sub", startTime: today)
        try insertSessionWithCwd(at: dbPath, id: "wildcard-repo", cwd: "/Users/test/myXrepo/sub", startTime: today)

        let counts = try db.sparklineData(for: "/Users/test/my_repo")

        XCTAssertEqual(counts.reduce(0, +), 1)
    }

    // MARK: - Local raw-SQL helpers for parent links / cwd

    private func setParentLinks(
        at path: String,
        sessionId: String,
        parentSessionId: String? = nil,
        suggestedParentId: String? = nil
    ) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET parent_session_id = ?, suggested_parent_id = ? WHERE id = ?",
                arguments: [parentSessionId, suggestedParentId, sessionId]
            )
        }
    }

    private func insertSessionWithCwd(
        at path: String,
        id: String,
        cwd: String,
        startTime: String
    ) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO sessions (
                    id, source, start_time, end_time, cwd, project,
                    message_count, file_path, size_bytes, indexed_at, tier
                ) VALUES (?, 'claude-code', ?, NULL, ?, 'engram', 1, '/tmp/test.jsonl', 0, datetime('now'), 'normal')
            """, arguments: [id, startTime, cwd])
        }
    }

    // MARK: - implementationTimeline project scoping

    /// ProjectWorkTimeline (project-detail embedded timeline) relies on
    /// `implementationTimeline(project:)` returning only the requested project's
    /// work. Lock that contract; it previously had no coverage.
    func testImplementationTimelineScopesToProject() throws {
        try seedWorkBeats(at: dbPath)

        let alpha = try db.implementationTimeline(days: 100_000, project: "alpha", humanDriven: false)
        XCTAssertFalse(alpha.isEmpty, "alpha should have a timeline item")
        XCTAssertTrue(
            alpha.allSatisfy { $0.beats.allSatisfy { $0.sessionId == "s-alpha" } },
            "alpha timeline must not include other projects' beats"
        )

        let beta = try db.implementationTimeline(days: 100_000, project: "beta", humanDriven: false)
        XCTAssertFalse(beta.isEmpty, "beta should have a timeline item")
        XCTAssertTrue(
            beta.allSatisfy { $0.beats.allSatisfy { $0.sessionId == "s-beta" } },
            "beta timeline must not include other projects' beats"
        )

        let unknown = try db.implementationTimeline(days: 100_000, project: "ghost", humanDriven: false)
        XCTAssertTrue(unknown.isEmpty, "unknown project should yield no timeline items")
    }

    /// When a matching `work_item_titles` row exists, the project-scoped read
    /// LEFT-joins it and surfaces the AI semantic title; absent rows keep nil.
    func testImplementationTimelineSurfacesSemanticTitle() throws {
        try seedWorkBeats(at: dbPath)
        try seedWorkItemTitles(at: dbPath)

        let alpha = try db.implementationTimeline(days: 100_000, project: "alpha", humanDriven: false)
        XCTAssertEqual(alpha.count, 1)
        XCTAssertEqual(alpha.first?.semanticTitle, "AI Alpha Title",
                       "semantic title from work_item_titles must override the heuristic")

        // beta has a work beat but no titles row -> semanticTitle stays nil (heuristic).
        let beta = try db.implementationTimeline(days: 100_000, project: "beta", humanDriven: false)
        XCTAssertEqual(beta.count, 1)
        XCTAssertNil(beta.first?.semanticTitle)
        XCTAssertEqual(beta.first?.title, "Beta fix", "missing title row falls back to heuristic title")
    }

    /// When the service-owned `work_item_titles` table is absent (read-only app
    /// never creates it), the read must not crash and must return heuristic titles.
    func testImplementationTimelineWithoutTitleTableUsesHeuristic() throws {
        try seedWorkBeats(at: dbPath) // no seedWorkItemTitles -> table does not exist

        let alpha = try db.implementationTimeline(days: 100_000, project: "alpha", humanDriven: false)
        XCTAssertEqual(alpha.count, 1)
        XCTAssertNil(alpha.first?.semanticTitle)
        XCTAssertEqual(alpha.first?.title, "Alpha feature")
    }

    /// Seed `session_work_beats` (a service/daemon-owned table the app read model
    /// does not create) plus two top-level sessions in distinct projects.
    private func seedWorkBeats(at path: String) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_work_beats (
                  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                  beat_index INTEGER NOT NULL,
                  action_date TEXT NOT NULL,
                  action_timestamp TEXT,
                  work_key TEXT NOT NULL,
                  work_title TEXT NOT NULL,
                  human_intent TEXT NOT NULL,
                  assistant_outcome TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  status TEXT NOT NULL,
                  operation_events TEXT NOT NULL DEFAULT '[]',
                  confidence REAL NOT NULL DEFAULT 0,
                  PRIMARY KEY (session_id, beat_index)
                );
            """)
            try db.execute(sql: """
                INSERT INTO sessions (
                    id, source, start_time, end_time, cwd, project,
                    message_count, file_path, size_bytes, tier
                ) VALUES
                    ('s-alpha', 'claude-code', '2026-06-01T10:00:00Z', '2026-06-01T11:00:00Z',
                     '/tmp/alpha', 'alpha', 10, '/tmp/alpha.jsonl', 0, 'normal'),
                    ('s-beta',  'claude-code', '2026-06-02T10:00:00Z', '2026-06-02T11:00:00Z',
                     '/tmp/beta',  'beta',  10, '/tmp/beta.jsonl',  0, 'normal');
            """)
            try db.execute(sql: """
                INSERT INTO session_work_beats (
                    session_id, beat_index, action_date, action_timestamp,
                    work_key, work_title, human_intent, assistant_outcome,
                    kind, status, operation_events, confidence
                ) VALUES
                    ('s-alpha', 0, '2026-06-01', '2026-06-01T10:30:00Z',
                     'wk-alpha', 'Alpha feature', 'build alpha', 'built alpha',
                     'implementation', 'complete', '[]', 0.9),
                    ('s-beta',  0, '2026-06-02', '2026-06-02T10:30:00Z',
                     'wk-beta',  'Beta fix',     'fix beta',    'fixed beta',
                     'fix', 'complete', '[]', 0.9);
            """)
        }
    }

    /// Seed `work_item_titles` (a service/writer-owned table the read-only app
    /// pool never creates) with one AI title row for the alpha work item, so the
    /// project-scoped read can LEFT-join it. Mirrors `seedWorkBeats(at:)`.
    private func seedWorkItemTitles(at path: String) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS work_item_titles (
                  project TEXT NOT NULL,
                  work_key TEXT NOT NULL,
                  title TEXT NOT NULL,
                  intent_hash TEXT NOT NULL,
                  model TEXT,
                  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                  PRIMARY KEY (project, work_key)
                );
            """)
            try db.execute(sql: """
                INSERT INTO work_item_titles (project, work_key, title, intent_hash, model)
                VALUES ('alpha', 'wk-alpha', 'AI Alpha Title', 'deadbeef', 'mimo-v2.5-pro');
            """)
        }
    }
}

private func createLegacySessionsTableWithoutAccessMetadata(at path: String) throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
        try db.execute(sql: "PRAGMA journal_mode = DELETE")
    }
    let queue = try DatabaseQueue(path: path, configuration: configuration)
    try queue.write { db in
        try db.execute(sql: "PRAGMA journal_mode = DELETE")
        try db.execute(sql: """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                start_time TEXT NOT NULL,
                end_time TEXT,
                cwd TEXT NOT NULL DEFAULT '',
                project TEXT,
                model TEXT,
                message_count INTEGER NOT NULL DEFAULT 0,
                user_message_count INTEGER NOT NULL DEFAULT 0,
                assistant_message_count INTEGER NOT NULL DEFAULT 0,
                tool_message_count INTEGER NOT NULL DEFAULT 0,
                system_message_count INTEGER NOT NULL DEFAULT 0,
                summary TEXT,
                file_path TEXT NOT NULL,
                size_bytes INTEGER NOT NULL DEFAULT 0,
                indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
                agent_role TEXT,
                parent_session_id TEXT,
                suggested_parent_id TEXT,
                hidden_at TEXT,
                custom_name TEXT,
                tier TEXT,
                generated_title TEXT,
                quality_score INTEGER
            );
            INSERT INTO sessions (
                id, source, start_time, cwd, project, file_path
            ) VALUES
                ('older', 'codex', '2026-05-09T12:00:00Z', '/tmp/older', 'older', '/tmp/older.jsonl'),
                ('newer', 'codex', '2026-05-10T12:00:00Z', '/tmp/newer', 'newer', '/tmp/newer.jsonl');
        """)
    }
}
