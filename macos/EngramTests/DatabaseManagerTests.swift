// macos/EngramTests/DatabaseManagerTests.swift
import XCTest
import GRDB
@testable import Engram
@testable import EngramServiceCore

final class DatabaseManagerTests: XCTestCase {
    func testDefaultDatabasePathUsesInjectedFixedHome_repro() throws {
        let fixedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-db-fixed-home-\(UUID().uuidString)", isDirectory: true)
        let oldFixedHome = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        let oldHome = getenv("HOME").map { String(cString: $0) }
        setenv("CFFIXED_USER_HOME", fixedHome.path, 1)
        setenv("HOME", fixedHome.path, 1)
        defer {
            if let oldFixedHome { setenv("CFFIXED_USER_HOME", oldFixedHome, 1) } else { unsetenv("CFFIXED_USER_HOME") }
            if let oldHome { setenv("HOME", oldHome, 1) } else { unsetenv("HOME") }
        }

        XCTAssertEqual(
            DatabaseManager().path,
            fixedHome.appendingPathComponent(".engram/index.sqlite").path
        )
    }
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

        try autoreleasepool {
            let queue = try DatabaseQueue(path: copiedPath)
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                    arguments: ["seed-01", "fixture bridge marker"]
                )
            }
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

    func testBundledFixtureAuthenticationSearch_repro() throws {
        let fixturePath = try XCTUnwrap(Bundle(for: type(of: self)).path(
            forResource: "test-index",
            ofType: "sqlite",
            inDirectory: "test-fixtures"
        ))
        let copiedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-auth-search-\(UUID().uuidString).sqlite")
            .path
        try FileManager.default.copyItem(atPath: fixturePath, toPath: copiedPath)
        var fixtureWriter: DatabaseQueue? = try keepFixtureWALOpen(at: copiedPath)
        var fixtureDb: DatabaseManager? = DatabaseManager(path: copiedPath)
        defer {
            fixtureDb = nil
            fixtureWriter = nil
            cleanupTempDatabase(at: copiedPath)
        }
        try fixtureDb?.open()

        let hits = try XCTUnwrap(fixtureDb).searchWithSnippets(query: "authentication", limit: 30)
        XCTAssertEqual(hits.map(\.session.id), ["seed-02"])
    }

    func testPathReturnsCorrectPath() throws {
        XCTAssertEqual(db.path, dbPath)
    }

    func testRecentSessionsOrdersByLatestActivity_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "recent-started-newer",
            startTime: "2026-08-24T11:00:00Z",
            endTime: nil
        )
        try insertTestSession(
            at: dbPath,
            id: "recent-ended-newer",
            startTime: "2026-08-24T09:00:00Z",
            endTime: "2026-08-24T12:00:00Z"
        )

        XCTAssertEqual(
            try db.recentSessions(limit: 2).map(\.id),
            ["recent-ended-newer", "recent-started-newer"]
        )
    }

    func testPopoverRecentSessionsFetchExecutesWithHumanFilter_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "popover-human",
            startTime: "2026-08-24T11:00:00Z",
            endTime: nil
        )

        XCTAssertEqual(
            try db.recentSessions(limit: 12, humanDriven: true).map(\.id),
            ["popover-human"]
        )
    }

    func testDefaultBrowsePromotesHumanSuggestedChildOverWeakHost_repro() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, instruction_count, human_turn_count, tier,
                  agent_role, parent_session_id, suggested_parent_id, summary
                ) VALUES
                  ('app-weak-host', 'claude-code', '2026-08-24T10:00:00Z', '/tmp/promote',
                   'promote', '/tmp/app-host.jsonl', 1, 1, 1, 1, 'normal', NULL, NULL, NULL,
                   'weak host'),
                  ('app-human-child', 'gemini-cli', '2026-08-24T11:00:00Z', '/tmp/promote',
                   'promote', '/tmp/app-child.jsonl', 4, 4, 4, 4, 'normal', NULL, NULL,
                   'app-weak-host', 'promoted child')
                """)
        }

        XCTAssertEqual(
            try db.recentSessions(limit: 10, humanDriven: true).map(\.id),
            ["app-human-child"]
        )
    }

    func testPopoverLiveClickDoesNotGuessOpenCodeRowFromDatabasePrefix_repro() throws {
        let sourceDatabasePath = "/tmp/opencode-live-click.db"
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, file_path, size_bytes, indexed_at
                    ) VALUES (?, 'opencode', '2026-08-22T00:00:00Z', '/tmp', ?, 1, '2026-08-22T00:00:00Z')
                    """,
                arguments: ["indexed-opencode-session", "\(sourceDatabasePath)::indexed-source-id"]
            )
        }
        let live = Engram.EngramServiceLiveSessionInfo(
            source: "opencode",
            sessionId: nil,
            project: nil,
            title: nil,
            cwd: nil,
            filePath: "\(sourceDatabasePath)::live-source-id",
            startedAt: nil,
            model: nil,
            currentActivity: nil,
            lastModifiedAt: "2026-08-22T00:00:00Z",
            activityLevel: "active"
        )

        let resolved = try PopoverView.resolveLiveSession(live, database: db)

        XCTAssertNil(resolved)
    }

    func testPopoverLiveResolutionRequiresMatchingSourceForIDAndPath_repro() throws {
        let locator = "/tmp/live-source-match.jsonl"
        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(
                sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, file_path, size_bytes, indexed_at
                    ) VALUES ('shared-live-id', 'codex', '2026-08-23T00:00:00Z', '/tmp', ?, 1, '2026-08-23T00:00:00Z')
                    """,
                arguments: [locator]
            )
        }
        let byID = Engram.EngramServiceLiveSessionInfo(
            source: "antigravity", sessionId: "shared-live-id", project: nil, title: nil,
            cwd: nil, filePath: "/tmp/different.jsonl", startedAt: nil, model: nil,
            currentActivity: nil, lastModifiedAt: "2026-08-23T00:00:00Z", activityLevel: "active"
        )
        let byPath = Engram.EngramServiceLiveSessionInfo(
            source: "antigravity", sessionId: nil, project: nil, title: nil,
            cwd: nil, filePath: locator, startedAt: nil, model: nil,
            currentActivity: nil, lastModifiedAt: "2026-08-23T00:00:00Z", activityLevel: "active"
        )

        XCTAssertNil(try PopoverView.resolveLiveSession(byID, database: db))
        XCTAssertNil(try PopoverView.resolveLiveSession(byPath, database: db))
    }

    func testPopoverLiveClickMatchesFullOpenCodeVirtualLocatorFromTheRight_repro() throws {
        let virtualLocator = "/tmp/opencode::data/opencode.db::live-source-id"
        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(
                sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, file_path, size_bytes, indexed_at
                    ) VALUES ('indexed-opencode-live', 'opencode', '2026-08-23T00:00:00Z', '/tmp', ?, 1, '2026-08-23T00:00:00Z')
                    """,
                arguments: [virtualLocator]
            )
        }
        let live = Engram.EngramServiceLiveSessionInfo(
            source: "opencode",
            sessionId: nil,
            project: nil,
            title: nil,
            cwd: nil,
            filePath: virtualLocator,
            startedAt: nil,
            model: nil,
            currentActivity: nil,
            lastModifiedAt: "2026-08-23T00:00:00Z",
            activityLevel: "active"
        )

        XCTAssertEqual(try PopoverView.resolveLiveSession(live, database: db)?.id, "indexed-opencode-live")
    }

    func testPopoverLiveClickResolvesAntigravityBrainLocatorWithoutJSONID_repro() throws {
        let locator = "/tmp/brain/brain-session/.system_generated/logs/transcript.jsonl"
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, file_path, size_bytes, indexed_at
                    ) VALUES (?, 'antigravity', '2026-08-22T00:00:00Z', '/tmp', ?, 1, '2026-08-22T00:00:00Z')
                    """,
                arguments: ["brain-session", locator]
            )
        }
        let live = Engram.EngramServiceLiveSessionInfo(
            source: "antigravity",
            sessionId: nil,
            project: nil,
            title: nil,
            cwd: nil,
            filePath: locator,
            startedAt: nil,
            model: nil,
            currentActivity: nil,
            lastModifiedAt: "2026-08-22T00:00:00Z",
            activityLevel: "active"
        )

        let resolved = try PopoverView.resolveLiveSession(live, database: db)
        XCTAssertEqual(resolved?.id, "brain-session")
    }

    func testPopoverLiveClickNormalizesTheAdapterFileLocator_repro() throws {
        let physicalRoot = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-resolve-\(UUID().uuidString)", isDirectory: true)
        let linkRoot = physicalRoot.deletingLastPathComponent()
            .appendingPathComponent("engram-live-resolve-link-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linkRoot)
            try? FileManager.default.removeItem(at: physicalRoot)
        }
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: physicalRoot)
        let physicalLocator = physicalRoot.appendingPathComponent("rollout-live.jsonl").path
        let linkedLocator = linkRoot.appendingPathComponent("rollout-live.jsonl").path
        try "{}\n".write(toFile: physicalLocator, atomically: true, encoding: .utf8)

        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(
                sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, file_path, size_bytes, indexed_at
                    ) VALUES ('canonical-live', 'codex', '2026-08-23T00:00:00Z', '/tmp', ?, 1, '2026-08-23T00:00:00Z')
                    """,
                arguments: [physicalLocator]
            )
        }
        let live = Engram.EngramServiceLiveSessionInfo(
            source: "codex",
            sessionId: nil,
            project: nil,
            title: nil,
            cwd: nil,
            filePath: linkedLocator,
            startedAt: nil,
            model: nil,
            currentActivity: nil,
            lastModifiedAt: "2026-08-23T00:00:00Z",
            activityLevel: "active"
        )

        XCTAssertEqual(try PopoverView.resolveLiveSession(live, database: db)?.id, "canonical-live")
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

    func testAppReadPoolUsesWalAndThirtySecondBusyTimeout_repro() throws {
        let pragmas = try db.readInBackground { database in
            (
                try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? "",
                try Int.fetchOne(database, sql: "PRAGMA busy_timeout") ?? 0
            )
        }

        XCTAssertEqual(pragmas.0.lowercased(), "wal")
        XCTAssertEqual(pragmas.1, 30_000)
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

    // ARCH-001C: favorites are a browse surface and must hide skip-tier noise.
    @MainActor
    func testListFavoritesExcludesSkipTier_repro() throws {
        try insertTestSession(at: dbPath, id: "favorite-visible", tier: "normal")
        try insertTestSession(at: dbPath, id: "favorite-skip", tier: "skip")
        try insertFavorite(at: dbPath, sessionId: "favorite-visible")
        try insertFavorite(at: dbPath, sessionId: "favorite-skip")

        XCTAssertEqual(try db.listFavorites().map(\.id), ["favorite-visible"])
    }

    func testFavoriteIdsIncludesSkipChildrenForSymmetricToggle_repro() throws {
        try insertTestSession(at: dbPath, id: "favorite-visible", tier: "normal")
        try insertTestSession(at: dbPath, id: "favorite-skip-child", tier: "skip")
        try insertFavorite(at: dbPath, sessionId: "favorite-visible")
        try insertFavorite(at: dbPath, sessionId: "favorite-skip-child")

        XCTAssertEqual(
            try db.favoriteIds(),
            ["favorite-skip-child", "favorite-visible"],
            "child annotation needs raw favorite membership even though Starred hides skip sessions"
        )
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

    // Wave 6C-1 (design §9): "HQ only" toggles an `origin = 'hq'` SQL filter so
    // a paginated Sessions page can exclude remote-ingested rows. Fails on the
    // pre-origin-parameter listSessions (no such parameter / no filtering).
    @MainActor
    func testListSessionsOriginFilter_repro() throws {
        try insertTestSession(at: dbPath, id: "hq-ingested", source: "claude-code")
        try insertTestSession(at: dbPath, id: "local-laptop", source: "claude-code")
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET origin = ? WHERE id = ?",
                arguments: ["hq", "hq-ingested"]
            )
        }

        let all = try db.listSessions(origin: nil, sort: .createdDesc)
        XCTAssertEqual(all.map(\.id).sorted(), ["hq-ingested", "local-laptop"], "nil origin = all machines")

        let hqOnly = try db.listSessions(origin: "hq", sort: .createdDesc)
        XCTAssertEqual(hqOnly.map(\.id), ["hq-ingested"])
        XCTAssertEqual(hqOnly.first?.originBadge, "HQ")
    }

    @MainActor
    func testSessionListStatsOriginFilter_repro() throws {
        try insertTestSession(at: dbPath, id: "hq-ingested", source: "claude-code", messageCount: 5)
        try insertTestSession(at: dbPath, id: "local-laptop", source: "claude-code", messageCount: 7)
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET origin = ? WHERE id = ?",
                arguments: ["hq", "hq-ingested"]
            )
        }

        let stats = try db.sessionListStats(origin: "hq")
        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.totalMessages, 5)
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
    func testListSessionsSinceTreatsEmptyEndTimeAsMissing_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "empty-end-recent-start",
            startTime: "2026-05-10T01:00:00Z",
            endTime: ""
        )

        XCTAssertEqual(
            try db.listSessions(since: "2026-05-10T00:00:00Z").map(\.id),
            ["empty-end-recent-start"]
        )
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

        XCTAssertEqual(byActivity.groups.map(\.date), ["2026-05-09"])
        XCTAssertEqual(
            byActivity.groups.first?.sessions.map(\.id),
            ["started-yesterday-active-today", "created-today"]
        )

        let byCreated = try db.sessionTimeline(days: 10_000, sort: .createdDesc)

        XCTAssertEqual(byCreated.groups.map(\.date), ["2026-05-09", "2026-05-08"])
        XCTAssertEqual(byCreated.groups[0].sessions.map(\.id), ["created-today"])
        XCTAssertEqual(byCreated.groups[1].sessions.map(\.id), ["started-yesterday-active-today"])
    }

    @MainActor
    func testSessionTimelineUsesLocalCalendarWindow_repro() throws {
        let localStart = Calendar.current.startOfDay(for: Date())
        let activeAt = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: 1, to: localStart))
        let timestamp = ISO8601DateFormatter().string(from: activeAt)
        try insertTestSession(
            at: dbPath,
            id: "local-day-boundary",
            startTime: timestamp,
            endTime: timestamp
        )

        let timeline = try db.sessionTimeline(days: 0, sort: .updatedDesc)
        XCTAssertEqual(timeline.groups.flatMap(\.sessions).map(\.id), ["local-day-boundary"])
    }

    @MainActor
    func testSessionTimelineGregorianGroupsMatchSQLiteDaysWithEmptyEndTime_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "empty-end-local-day",
            startTime: "2026-05-08T23:30:00Z",
            endTime: ""
        )
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = .current
        let fixedNow = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-10T00:00:00Z"))

        let timeline = try db.sessionTimeline(
            days: 10,
            sort: .updatedDesc,
            now: fixedNow,
            calendar: buddhist
        )

        XCTAssertEqual(timeline.groups.map(\.date), Array(timeline.dailyCounts.map(\.date).reversed()))
        XCTAssertEqual(timeline.groups.first?.sessions.map(\.id), ["empty-end-local-day"])
    }

    @MainActor
    func testDashboardDateWindowsHonorInjectedClock_repro() throws {
        try seedWorkBeats(at: dbPath)
        let fixedNow = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-06-02T12:00:00Z")
        )

        let activity = try db.dailySourceActivity(days: 2, now: fixedNow)
        XCTAssertEqual(activity.flatMap(\.segments).reduce(0) { $0 + $1.count }, 2)

        let timeline = try db.sessionTimeline(
            days: 2,
            sort: .updatedDesc,
            now: fixedNow
        )
        XCTAssertEqual(Set(timeline.groups.flatMap(\.sessions).map(\.id)), ["s-alpha", "s-beta"])
        XCTAssertEqual(
            try db.sessionTimelineProjects(days: 2, sort: .updatedDesc, now: fixedNow),
            ["alpha", "beta"]
        )

        let work = try db.implementationTimeline(
            days: 2,
            project: nil,
            humanDriven: false,
            now: fixedNow
        )
        XCTAssertEqual(Set(work.flatMap(\.beats).map(\.sessionId)), ["s-alpha", "s-beta"])
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

        XCTAssertEqual(byAccessed.groups.map(\.date), ["2026-05-09"])
        XCTAssertEqual(
            byAccessed.groups.first?.sessions.map(\.id),
            ["started-yesterday-accessed-today", "created-today"]
        )
    }

    @MainActor
    func testSessionTimelineReportsTruncationForTwoThousandAndOneRows_repro() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            for index in 0..<2_001 {
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
        let sessions = byCreated.groups.flatMap(\.sessions)

        XCTAssertEqual(sessions.count, 2_000)
        XCTAssertEqual(sessions.first?.id, "limit-2000")
        XCTAssertEqual(sessions.last?.id, "limit-1")
        XCTAssertEqual(byCreated.totalCount, 2_001)
        XCTAssertTrue(byCreated.hasMore)
    }

    @MainActor
    func testSessionTimelineScopesProjectBeforeLimitAndListsProjectsAcrossWindow_repro() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            for index in 0..<2_001 {
                try db.execute(sql: """
                    INSERT INTO sessions (
                        id, source, start_time, cwd, project, message_count,
                        user_message_count, assistant_message_count, tool_message_count,
                        system_message_count, file_path, indexed_at, tier
                    ) VALUES (?, 'codex', '2099-01-02T00:00:00Z', '/work/alpha',
                              'alpha', 1, 1, 0, 0, 0, ?, datetime('now'), 'normal')
                    """, arguments: ["alpha-\(index)", "/tmp/alpha-\(index).jsonl"])
            }
            try db.execute(sql: """
                INSERT INTO sessions (
                    id, source, start_time, cwd, project, message_count,
                    user_message_count, assistant_message_count, tool_message_count,
                    system_message_count, file_path, indexed_at, tier
                ) VALUES ('beta-only', 'codex', '2099-01-01T00:00:00Z', '/work/beta',
                          'beta', 1, 1, 0, 0, 0, '/tmp/beta.jsonl', datetime('now'), 'normal')
                """)
        }

        let alpha = try db.sessionTimeline(
            days: 100_000,
            sort: .createdDesc,
            project: "alpha"
        )
        XCTAssertEqual(alpha.groups.flatMap(\.sessions).count, 2_000)
        XCTAssertEqual(alpha.totalCount, 2_001)
        XCTAssertTrue(alpha.hasMore)

        let beta = try db.sessionTimeline(
            days: 100_000,
            sort: .createdDesc,
            project: "beta"
        )
        XCTAssertEqual(beta.groups.flatMap(\.sessions).map(\.id), ["beta-only"])
        XCTAssertEqual(
            try db.sessionTimelineProjects(days: 100_000, sort: .createdDesc),
            ["alpha", "beta"]
        )
    }

    @MainActor
    func testSessionTimelineChartCountsEntireFilteredRange_repro() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            for index in 0..<2_001 {
                let day = index < 1_001 ? "08" : "09"
                try database.execute(sql: """
                    INSERT INTO sessions (
                        id, source, start_time, cwd, project, message_count,
                        user_message_count, assistant_message_count, tool_message_count,
                        system_message_count, file_path, indexed_at, tier
                    ) VALUES (?, 'codex', ?, '/work/engram', 'engram', 1,
                              1, 0, 0, 0, ?, datetime('now'), 'normal')
                    """, arguments: [
                        "chart-\(index)",
                        "2026-05-\(day)T12:00:00Z",
                        "/tmp/chart-\(index).jsonl",
                    ])
            }
        }

        let result = try db.sessionTimeline(days: 10_000, sort: .createdDesc)

        XCTAssertEqual(result.groups.flatMap(\.sessions).count, 2_000)
        XCTAssertEqual(result.dailyCounts.reduce(0) { $0 + $1.count }, 2_001)
        XCTAssertEqual(result.dailyCounts.count, 2)
        XCTAssertEqual(
            TimelinePageView.rangeBadge(range: "30d", shown: 2_000, total: 2_001, hasMore: true),
            "30d · 2000 of 2001"
        )
    }

    @MainActor
    func testSessionTimelineRetainsNilProjectRowsWhenProjectExpiresFromShorterRange_repro() throws {
        let formatter = ISO8601DateFormatter()
        let recent = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let expired = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -8, to: Date()))
        try insertTestSession(
            at: dbPath,
            id: "expired-project",
            project: "expired-project",
            startTime: formatter.string(from: expired),
            endTime: formatter.string(from: expired)
        )
        try insertTestSession(
            at: dbPath,
            id: "recent-nil-project",
            project: nil,
            startTime: formatter.string(from: recent),
            endTime: formatter.string(from: recent)
        )

        XCTAssertEqual(
            try db.sessionTimelineProjects(days: 30, sort: .updatedDesc),
            ["expired-project"]
        )
        XCTAssertEqual(try db.sessionTimelineProjects(days: 7, sort: .updatedDesc), [])

        let allProjects = try db.sessionTimeline(days: 7, sort: .updatedDesc)
        XCTAssertEqual(allProjects.groups.flatMap(\.sessions).map(\.id), ["recent-nil-project"])
        XCTAssertEqual(allProjects.totalCount, 1)
        XCTAssertFalse(allProjects.hasMore)
    }

    @MainActor
    func testTimelineProjectSelectionResetsExpiredProjectThenReloadsAll_repro() throws {
        let formatter = ISO8601DateFormatter()
        let recent = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let expired = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -8, to: Date()))
        try insertTestSession(
            at: dbPath,
            id: "expired-project",
            project: "expired-project",
            startTime: formatter.string(from: expired),
            endTime: formatter.string(from: expired)
        )
        try insertTestSession(
            at: dbPath,
            id: "recent-nil-project",
            project: nil,
            startTime: formatter.string(from: recent),
            endTime: formatter.string(from: recent)
        )
        try insertTestSession(
            at: dbPath,
            id: "recent-valid-project",
            project: "valid-project",
            startTime: formatter.string(from: recent),
            endTime: formatter.string(from: recent)
        )

        let projectsAtThirtyDays = try db.sessionTimelineProjects(days: 30, sort: .updatedDesc)
        XCTAssertTrue(projectsAtThirtyDays.contains("expired-project"))
        let projectsAtSevenDays = try db.sessionTimelineProjects(days: 7, sort: .updatedDesc)
        XCTAssertEqual(projectsAtSevenDays, ["valid-project"])

        let reconciled = TimelinePageView.reconciledProjectSelection(
            selectedProject: "expired-project",
            availableProjects: projectsAtSevenDays
        )
        XCTAssertEqual(reconciled, "All Projects")
        let finalProjectFilter = reconciled == "All Projects" ? nil : reconciled
        let finalGroups = try db.sessionTimeline(
            days: 7,
            sort: .updatedDesc,
            project: finalProjectFilter
        ).groups
        XCTAssertEqual(
            Set(finalGroups.flatMap(\.sessions).map(\.id)),
            Set(["recent-nil-project", "recent-valid-project"])
        )

        let valid = TimelinePageView.reconciledProjectSelection(
            selectedProject: "valid-project",
            availableProjects: projectsAtSevenDays
        )
        XCTAssertEqual(valid, "valid-project")
        XCTAssertEqual(
            TimelinePageView.reconciledProjectSelection(
                selectedProject: valid,
                availableProjects: projectsAtSevenDays
            ),
            valid
        )
    }

    @MainActor
    func testTimelineChartCountsEntireFilteredRangeWithSmallPage_repro() throws {
        for (id, start) in [
            ("limited-new-1", "2026-08-24T12:00:00Z"),
            ("limited-new-2", "2026-08-24T11:00:00Z"),
            ("limited-old", "2026-08-23T10:00:00Z"),
        ] {
            try insertTestSession(at: dbPath, id: id, startTime: start, endTime: start)
        }

        let result = try db.sessionTimeline(
            days: 30,
            sort: .updatedDesc,
            humanDriven: false,
            limit: 2,
            now: ISO8601DateFormatter().date(from: "2026-08-24T13:00:00Z")!
        )

        XCTAssertEqual(result.groups.flatMap(\.sessions).count, 2)
        XCTAssertEqual(result.dailyCounts.reduce(0) { $0 + $1.count }, 3)
        XCTAssertEqual(result.totalCount, 3)
        XCTAssertTrue(result.hasMore)
    }

    @MainActor
    func testImplementationTimelineProjectsUseBeatActionDateWindow_repro() throws {
        try seedWorkBeats(at: dbPath)
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO sessions (
                    id, source, start_time, end_time, cwd, project, file_path, tier
                ) VALUES (
                    'old-session-recent-work', 'cursor', '2025-01-01T00:00:00Z', '',
                    '/work/recent-beat', 'recent-beat-project', '/tmp/recent-beat.jsonl', 'normal'
                );
                INSERT INTO session_work_beats (
                    session_id, beat_index, action_date, action_timestamp, work_key,
                    work_title, human_intent, assistant_outcome, kind, status,
                    operation_events, confidence
                ) VALUES (
                    'old-session-recent-work', 0, date('now', 'localtime'), datetime('now'),
                    'recent-beat', 'Recent beat', 'intent', 'outcome', 'implementation',
                    'completed', '[]', 0.9
                );
                """)
        }

        XCTAssertEqual(
            try db.implementationTimelineProjects(days: 7),
            ["recent-beat-project"]
        )
        XCTAssertEqual(
            try db.sessionTimelineProjects(days: 7, sort: .updatedDesc),
            []
        )
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

    /// ARCH-001B: dashboard totals use the same list-visible predicate as browse surfaces.
    @MainActor
    func testStatsExcludesSkipTier_repro() throws {
        try insertTestSession(at: dbPath, id: "normal", source: "codex", messageCount: 10, tier: "normal")
        try insertTestSession(at: dbPath, id: "skip", source: "codex", messageCount: 99, tier: "skip")
        try insertTestSession(at: dbPath, id: "skip-only-source", source: "claude-code", messageCount: 50, tier: "skip")

        let stats = try db.stats()

        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.totalMessages, 10)
        XCTAssertEqual(stats.bySource, ["codex": 1])
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

    // ARCH-001D: pin the first executable keyword-search parity contract across
    // the App, Service, and native MCP readers against one shared fixture DB.
    @MainActor
    func testKeywordSearchSessionIdsMatchAppServiceMCP_repro() async throws {
        let fixturePath = try copyMCPContractFixture()
        var fixtureWriter: DatabaseQueue? = try keepFixtureWALOpen(at: fixturePath)
        defer {
            fixtureWriter = nil
            cleanupTempDatabase(at: fixturePath)
        }

        let query = "  WAL  ".trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 50
        XCTAssertGreaterThanOrEqual(query.count, 2)
        XCTAssertFalse(CJKText.containsCJK(query))

        let appIDs = try appKeywordSearchSessionIDs(
            query: query,
            limit: limit,
            databasePath: fixturePath
        )
        let serviceIDs = try await serviceKeywordSearchSessionIDs(
            query: query,
            limit: limit,
            databasePath: fixturePath
        )
        let mcpIDs = try mcpKeywordSearchSessionIDs(
            query: query,
            limit: limit,
            databasePath: fixturePath
        )

        XCTAssertFalse(appIDs.isEmpty, "fixture query must exercise a non-empty result set")
        XCTAssertEqual(serviceIDs, appIDs)
        XCTAssertEqual(mcpIDs, appIDs)
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
    func testSearchWithSnippetsAppliesOriginBeforeLimit_repro() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            for index in 0 ..< 31 {
                let id = "local-origin-\(index)"
                try database.execute(
                    sql: """
                        INSERT INTO sessions (
                          id, source, start_time, cwd, project, message_count,
                          file_path, size_bytes, indexed_at, tier, origin
                        ) VALUES (?, 'codex', ?, '/tmp/local', 'engram', 2,
                                  ?, 42, ?, 'normal', 'local')
                        """,
                    arguments: [
                        id,
                        String(format: "2026-08-%02dT12:00:00Z", index + 1),
                        "/tmp/\(id).jsonl",
                        String(format: "2026-08-%02dT12:30:00Z", index + 1),
                    ]
                )
                try database.execute(
                    sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, 'originneedle')",
                    arguments: [id]
                )
            }
            try database.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, message_count,
                  file_path, size_bytes, indexed_at, tier, origin
                ) VALUES (
                  'hq-origin-target', 'codex', '2000-01-01T00:00:00Z', '/tmp/hq',
                  'engram', 2, 'remote://hq/hq-origin-target', 42,
                  '2000-01-01T00:00:00Z', 'normal', 'hq'
                );
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('hq-origin-target', 'originneedle');
                """)
        }

        let hqOnly = try db.searchWithSnippets(
            query: "originneedle",
            limit: 30,
            origin: "hq"
        )
        let localOnly = try db.searchWithSnippets(
            query: "originneedle",
            limit: 30,
            origin: "local"
        )
        let all = try db.searchWithSnippets(query: "originneedle", limit: 30)

        XCTAssertEqual(hqOnly.map(\.session.id), ["hq-origin-target"])
        XCTAssertEqual(localOnly.count, 30)
        XCTAssertFalse(localOnly.contains { $0.session.id == "hq-origin-target" })
        XCTAssertEqual(all.count, 30, "nil origin must remain all machines")
    }

    @MainActor
    func testSearchWithSnippetsLocalOriginIncludesLegacyAndNonHQRows_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "legacy-local",
            startTime: "2026-08-01T12:00:00Z"
        )
        try insertTestSession(
            at: dbPath,
            id: "named-local",
            startTime: "2026-08-02T12:00:00Z"
        )
        try insertTestSession(
            at: dbPath,
            id: "hq-ingested",
            startTime: "2026-08-03T12:00:00Z"
        )
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(
                sql: "UPDATE sessions SET origin = 'm1' WHERE id = 'named-local'"
            )
            try database.execute(
                sql: "UPDATE sessions SET origin = 'hq' WHERE id = 'hq-ingested'"
            )
        }
        for id in ["legacy-local", "named-local", "hq-ingested"] {
            try insertFTSContent(at: dbPath, sessionId: id, content: "localoriginneedle")
        }

        let local = try db.searchWithSnippets(
            query: "localoriginneedle",
            limit: 10,
            origin: "local"
        )
        let all = try db.searchWithSnippets(
            query: "localoriginneedle",
            limit: 10,
            origin: nil
        )

        XCTAssertEqual(Set(local.map(\.session.id)), Set(["legacy-local", "named-local"]))
        XCTAssertFalse(local.contains { $0.session.id == "hq-ingested" })
        XCTAssertEqual(
            Set(all.map(\.session.id)),
            Set(["legacy-local", "named-local", "hq-ingested"]),
            "nil origin must preserve all machines"
        )
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
    func testMixedTokenSnippetHighlightsEveryMatchedMessageTerm_repro() throws {
        try insertTestSession(at: dbPath, id: "mixed-highlight-all", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "mixed-highlight-all", content: "alpha planning note")
        try insertFTSContent(at: dbPath, sessionId: "mixed-highlight-all", content: "beta verifier note")

        let snippet = try XCTUnwrap(
            db.searchWithSnippets(query: "alpha beta", limit: 10).first?.snippet
        )

        XCTAssertTrue(snippet.contains("<mark>alpha</mark>"), snippet)
        XCTAssertTrue(snippet.contains("<mark>beta</mark>"), snippet)
    }

    @MainActor
    func testSearchWithSnippetsMixedShortTokenHighlightsWholePhrase_repro() throws {
        try insertTestSession(at: dbPath, id: "s-ai-usage", source: "codex")
        try insertFTSContent(
            at: dbPath,
            sessionId: "s-ai-usage",
            content: "Ship the AI usage monitor before release"
        )

        let hits = try db.searchWithSnippets(query: "AI usage", limit: 10)

        XCTAssertEqual(hits.map(\.session.id), ["s-ai-usage"])
        XCTAssertTrue(
            hits.first?.snippet.contains("<mark>AI usage</mark>") ?? false,
            "got: \(hits.first?.snippet ?? "")"
        )
    }

    @MainActor
    func testSearchWithSnippetsRehighlightsWholeMatchFirstPhrase_repro() throws {
        try insertTestSession(at: dbPath, id: "s-usage-monitor", source: "codex")
        try insertFTSContent(
            at: dbPath,
            sessionId: "s-usage-monitor",
            content: "Deploy the usage monitor before release"
        )

        let hits = try db.searchWithSnippets(query: "usage monitor", limit: 10)

        XCTAssertEqual(hits.map(\.session.id), ["s-usage-monitor"])
        XCTAssertTrue(
            hits.first?.snippet.contains("<mark>usage monitor</mark>") ?? false,
            "got: \(hits.first?.snippet ?? "")"
        )
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

    /// ui-search-settings-4: Search filter counts use the same tier visibility
    /// as keyword results, so list-visible lite rows cannot inflate the facets.
    @MainActor
    func testSearchFilterCountsExcludeLiteAndSkipSessions_repro() throws {
        try insertTestSession(at: dbPath, id: "normal", source: "codex", project: "engram", tier: "normal")
        try insertTestSession(at: dbPath, id: "lite", source: "codex", project: "engram", tier: "lite")
        try insertTestSession(at: dbPath, id: "skip", source: "codex", project: "engram", tier: "skip")
        try insertTestSession(
            at: dbPath,
            id: "hidden",
            source: "codex",
            project: "engram",
            tier: "normal",
            hiddenAt: "2026-08-22T00:00:00Z"
        )

        XCTAssertEqual(try db.countsByProject()["engram"], 1)
        XCTAssertEqual(try db.sourceStats().first(where: { $0.source == "codex" })?.count, 1)
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

    // ARCH-001A: blank UI filter values are equivalent to omitted filters on
    // the shared App/Service/MCP search predicate path.
    @MainActor
    func testSearchIgnoresBlankSourceAndProjectFilters_repro() throws {
        try insertTestSession(at: dbPath, id: "blank-filter-match", source: "codex", project: "engram")
        try insertFTSContent(
            at: dbPath,
            sessionId: "blank-filter-match",
            content: "blank filter parity marker"
        )

        let results = try db.search(
            query: "filter parity",
            sources: Set([" \n"]),
            projects: Set(["\t"])
        )

        XCTAssertEqual(results.map(\.id), ["blank-filter-match"])
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

    // ARCH-001C: project counts are list-visible KPIs, so skip rows cannot inflate them.
    @MainActor
    func testProjectTimelineExcludesSkipTier_repro() throws {
        try insertTestSession(at: dbPath, id: "timeline-visible", project: "engram", tier: "normal")
        try insertTestSession(at: dbPath, id: "timeline-skip", project: "engram", tier: "skip")

        let entry = try XCTUnwrap(try db.projectTimeline(project: "engram").first)
        XCTAssertEqual(entry.project, "engram")
        XCTAssertEqual(entry.sessionCount, 1)
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

    // ARCH-001C: getContext's project/cwd browse fallback must not return skip rows.
    @MainActor
    func testGetContextExcludesSkipTier_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "context-visible",
            project: "engram",
            startTime: "2026-03-20T10:00:00Z",
            tier: "normal"
        )
        try insertTestSession(
            at: dbPath,
            id: "context-skip",
            project: "engram",
            startTime: "2026-03-21T10:00:00Z",
            tier: "skip"
        )

        XCTAssertEqual(
            try db.getContext(cwd: "/Users/test/engram", limit: 10).map(\.id),
            ["context-visible"]
        )

        try insertSessionWithCwd(
            at: dbPath,
            id: "context-cwd-visible",
            cwd: "/Users/test/fallback-repo/sub",
            startTime: "2026-03-20T10:00:00Z",
            tier: "normal"
        )
        try insertSessionWithCwd(
            at: dbPath,
            id: "context-cwd-skip",
            cwd: "/Users/test/fallback-repo/sub",
            startTime: "2026-03-21T10:00:00Z",
            tier: "skip"
        )

        XCTAssertEqual(
            try db.getContext(cwd: "/Users/test/fallback-repo", limit: 10).map(\.id),
            ["context-cwd-visible"]
        )
    }

    // ARCH-001C: navigational relation lists use the same list-visible contract.
    @MainActor
    func testRelatedSessionsExcludesSkipTier_repro() throws {
        try insertTestSession(at: dbPath, id: "relation-anchor", tier: "normal")
        try insertTestSession(
            at: dbPath,
            id: "relation-visible",
            startTime: "2026-03-20T10:00:00Z",
            tier: "normal"
        )
        try insertTestSession(
            at: dbPath,
            id: "relation-skip",
            startTime: "2026-03-21T10:00:00Z",
            tier: "skip"
        )
        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(sql: """
                CREATE TABLE session_relations (a_id TEXT NOT NULL, b_id TEXT NOT NULL)
            """)
            try database.execute(
                sql: "INSERT INTO session_relations (a_id, b_id) VALUES (?, ?), (?, ?)",
                arguments: [
                    "relation-anchor", "relation-visible",
                    "relation-anchor", "relation-skip",
                ]
            )
        }

        XCTAssertEqual(try db.relatedSessions(sessionId: "relation-anchor").map(\.id), ["relation-visible"])
    }

    // Audit #25: the local offline-fallback search must drive from sessions_fts
    // via a CTE (mirroring EngramServiceReadProvider.keywordSearch), NOT probe
    // MATCH once per sessions row (which cost 80-100s vs 81ms on the live DB).
    // (a) result parity with the service-shaped CTE query, and (b) the local
    // plan contains no correlated per-row MATCH.
    @MainActor
    func testSearchFTSFallbackUsesCTEShapeMatchingService_repro() throws {
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
            rawTokens: ["alpha", "beta"],
            termMatches: terms,
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
    func testSearchMixedShortAndLongTokensUsesPerTokenFallback_repro() throws {
        try insertTestSession(at: dbPath, id: "mixed-token-app", source: "claude-code")
        try insertFTSContent(
            at: dbPath,
            sessionId: "mixed-token-app",
            content: "AI planning note"
        )
        try insertFTSContent(at: dbPath, sessionId: "mixed-token-app", content: "usage report")

        let results = try db.search(query: "AI usage")

        XCTAssertEqual(results.map(\.id), ["mixed-token-app"])

        let snippets = try db.searchWithSnippets(query: "AI usage")
        XCTAssertEqual(snippets.map(\.session.id), ["mixed-token-app"])
        XCTAssertTrue(snippets[0].snippet.contains("<mark>AI</mark>"), "got: \(snippets[0].snippet)")
    }

    @MainActor
    func testQuotedShortTokenDoesNotBecomeBroadLIKE_repro() throws {
        try insertTestSession(at: dbPath, id: "quoted-short-app", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "quoted-short-app", content: "I parser")

        // mixed-token-1: classify the original whitespace tokens. Stripping the
        // FTS quoting first would turn `"I"` into a one-character `%I%` LIKE and
        // empty quotes into `%%`, over-recalling unrelated sessions.
        XCTAssertEqual(try db.search(query: #""I" parser"#).map(\.id), [])
        XCTAssertEqual(try db.search(query: #""" parser"#).map(\.id), [])
    }

    @MainActor
    func testSearchSkipsOneCharacterLatinTokenWithoutOverRecall_repro() throws {
        try insertTestSession(at: dbPath, id: "email-parser", source: "claude-code")
        try insertTestSession(at: dbPath, id: "ai-parser", source: "claude-code")
        try insertFTSContent(at: dbPath, sessionId: "email-parser", content: "email parser")
        try insertFTSContent(at: dbPath, sessionId: "ai-parser", content: "AI parser")

        XCTAssertEqual(Set(try db.search(query: "a parser").map(\.id)), Set(["email-parser", "ai-parser"]))
        XCTAssertEqual(Set(try db.search(query: "C parser").map(\.id)), Set(["email-parser", "ai-parser"]))
        XCTAssertEqual(try db.search(query: "I").map(\.id), [])
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

    /// M5: dashboard aggregates must exclude skip-tier (subagent noise).
    @MainActor
    func testDashboardAggregatesExcludeSkipTier_repro() throws {
        let recent = ISO8601DateFormatter().string(from: Date())
        try insertTestSession(
            at: dbPath,
            id: "normal-1",
            source: "codex",
            startTime: recent,
            endTime: recent,
            messageCount: 10,
            tier: "normal"
        )
        try insertTestSession(
            at: dbPath,
            id: "skip-1",
            source: "codex",
            startTime: recent,
            endTime: recent,
            messageCount: 99,
            tier: "skip"
        )
        try insertTestSession(
            at: dbPath,
            id: "skip-2",
            source: "claude-code",
            startTime: recent,
            endTime: recent,
            messageCount: 50,
            tier: "skip"
        )

        let kpi = try db.kpiStats()
        XCTAssertEqual(kpi.sessions, 1, "M5: kpiStats must not count skip-tier")
        XCTAssertEqual(kpi.messages, 10)
        XCTAssertEqual(kpi.sources, 1)

        let bySource = try db.sourceDistribution()
        XCTAssertEqual(bySource.map(\.source), ["codex"])
        XCTAssertEqual(bySource.first?.count, 1)

        let hours = try db.hourlyActivity()
        XCTAssertEqual(hours.reduce(0, +), 1, "M5: hourlyActivity total must exclude skip")

        let daily = try db.dailyActivity(days: 3650)
        XCTAssertEqual(daily.map(\.count).reduce(0, +), 1, "M5: dailyActivity excludes skip")

        let dailySrc = try db.dailySourceActivity(days: 3650)
        let srcTotal = dailySrc.flatMap(\.segments).map(\.count).reduce(0, +)
        XCTAssertEqual(srcTotal, 1, "M5: dailySourceActivity excludes skip")
    }

    /// R3: Activity today/week counters and sourceStats must exclude skip (same as KPI).
    @MainActor
    func testCountSessionsSinceAndSourceStatsExcludeSkipTier_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "normal-r3",
            source: "codex",
            startTime: "2026-07-18T12:00:00Z",
            endTime: "2026-07-18T12:30:00Z",
            messageCount: 5,
            tier: "normal"
        )
        try insertTestSession(
            at: dbPath,
            id: "skip-r3",
            source: "codex",
            startTime: "2026-07-18T13:00:00Z",
            endTime: "2026-07-18T13:30:00Z",
            messageCount: 99,
            tier: "skip"
        )
        try insertTestSession(
            at: dbPath,
            id: "skip-other",
            source: "claude-code",
            startTime: "2026-07-18T14:00:00Z",
            endTime: "2026-07-18T14:30:00Z",
            messageCount: 40,
            tier: "skip"
        )

        let since = try db.countSessionsSince("2026-07-01T00:00:00Z")
        XCTAssertEqual(since, 1, "R3: countSessionsSince must not count skip-tier")

        let stats = try db.sourceStats()
        XCTAssertEqual(stats.map(\.source), ["codex"])
        XCTAssertEqual(stats.first?.count, 1, "R3: sourceStats excludes skip")

        let byProject = try db.countsByProject()
        // insertTestSession may leave project nil — only assert no skip inflation on known project path
        let kpi = try db.kpiStats()
        XCTAssertEqual(kpi.sessions, 1)
        XCTAssertEqual(since, kpi.sessions, "R3: Activity counter must agree with KPI on same window seed")
        _ = byProject

        // VIS-FILTER-ADHOC: compact source counts and project pickers must share
        // listVisibleSQL with sourceStats (skip rows must not inflate them).
        let bySource = try db.countsBySource()
        XCTAssertEqual(bySource, ["codex": 1], "countsBySource must exclude skip-tier")
        let projects = try db.listProjects()
        XCTAssertEqual(projects, ["engram"], "listProjects must exclude skip-only projects")
    }

    func testCountSessionsSinceUsesLatestActivityTimestamp_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "started-before-cutoff-active-after",
            startTime: "2026-06-30T23:00:00Z",
            endTime: "2026-07-01T01:00:00Z"
        )

        XCTAssertEqual(try db.countSessionsSince("2026-07-01T00:00:00Z"), 1)
    }

    /// VIS-FILTER-ADHOC: a project that only has skip-tier sessions must not
    /// appear in the project picker (would surface ghost filters).
    @MainActor
    func testListProjectsExcludesSkipOnlyProjects_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "skip-only-proj",
            source: "codex",
            project: "ghost-skip-project",
            tier: "skip"
        )
        try insertTestSession(
            at: dbPath,
            id: "visible-proj",
            source: "claude-code",
            project: "real-project",
            tier: "normal"
        )

        let projects = try db.listProjects()
        XCTAssertTrue(projects.contains("real-project"))
        XCTAssertFalse(
            projects.contains("ghost-skip-project"),
            "skip-only projects must not appear in listProjects"
        )
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
    func testIncludeHiddenTopLevelDoesNotPromoteSuggestedChildrenWithExistingHosts_repro() throws {
        try insertTestSession(at: dbPath, id: "visible-host")
        try insertTestSession(at: dbPath, id: "visible-child")
        try setParentLinks(at: dbPath, sessionId: "visible-child", suggestedParentId: "visible-host")
        try insertTestSession(at: dbPath, id: "hidden-host", hiddenAt: "2026-09-01T00:00:00Z")
        try insertTestSession(at: dbPath, id: "hidden-child")
        try setParentLinks(at: dbPath, sessionId: "hidden-child", suggestedParentId: "hidden-host")

        let ids = Set(
            try db.listSessions(
                includeHidden: true,
                subAgent: false,
                topLevelOnly: true,
                humanDriven: false
            ).map(\.id)
        )

        XCTAssertEqual(ids, Set(["visible-host", "hidden-host"]))
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

    @MainActor
    func testChildSessionPagesStartWithNewestAndReachOlderRows_repro() throws {
        try insertTestSession(at: dbPath, id: "parent")
        for index in 0..<25 {
            try insertTestSession(
                at: dbPath,
                id: "child-\(index)",
                startTime: String(format: "2026-01-%02dT12:00:00Z", index + 1)
            )
            try setParentLinks(
                at: dbPath,
                sessionId: "child-\(index)",
                parentSessionId: "parent"
            )
        }

        XCTAssertEqual(
            try db.childSessions(parentId: "parent", limit: 20).map(\.id),
            (5..<25).reversed().map { "child-\($0)" }
        )
        XCTAssertEqual(
            try db.childSessions(parentId: "parent", limit: 20, offset: 20).map(\.id),
            (0..<5).reversed().map { "child-\($0)" }
        )
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

    @MainActor
    func testListSessionsByProjectCanExcludeNewerSingleShotRoot_repro() throws {
        try insertTestSession(
            at: dbPath,
            id: "human-project-session",
            project: "engram",
            startTime: "2026-08-22T10:00:00Z"
        )
        try insertTestSession(
            at: dbPath,
            id: "newer-single-shot",
            project: "engram",
            startTime: "2026-08-23T10:00:00Z"
        )
        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(
                sql: "UPDATE sessions SET instruction_count = 2, human_turn_count = 2 WHERE id = 'human-project-session'"
            )
            try database.execute(
                sql: "UPDATE sessions SET instruction_count = 0, human_turn_count = 1, user_message_count = 1 WHERE id = 'newer-single-shot'"
            )
        }

        let group = try XCTUnwrap(
            try db.listSessionsByProject(limit: 5, humanDriven: true).first { $0.project == "engram" }
        )
        XCTAssertEqual(group.sessionCount, 1)
        XCTAssertEqual(group.sessions.map(\.id), ["human-project-session"])
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

    @MainActor
    func testPickerSearchScopesBeforeLimitSoOlderSessionsRemainFindable_repro() throws {
        for index in 0..<205 {
            try insertTestSession(
                at: dbPath,
                id: "newer-\(index)",
                startTime: String(format: "2026-08-23T12:%02d:%02dZ", (index / 60) % 60, index % 60),
                generatedTitle: "Routine \(index)"
            )
        }
        try insertTestSession(
            at: dbPath,
            id: "old-target",
            startTime: "2025-01-01T00:00:00Z",
            generatedTitle: "Needle parent"
        )

        XCTAssertEqual(
            try db.sessionPickerCandidates(
                query: "needle",
                topLevelOnly: true,
                excluding: [],
                limit: 200
            ).map(\.id),
            ["old-target"]
        )
    }

    @MainActor
    func testParentPickerExcludesSuggestedChildrenEvenWhenHostIsUnavailable_repro() throws {
        try insertTestSession(at: dbPath, id: "strict-root")
        try insertTestSession(at: dbPath, id: "suggested-child")
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET suggested_parent_id = 'missing-host' WHERE id = 'suggested-child'"
            )
        }

        XCTAssertEqual(
            Set(try db.sessionPickerCandidates(
                query: "",
                topLevelOnly: true,
                excluding: [],
                limit: 200
            ).map(\.id)),
            ["strict-root"]
        )
    }

    // MARK: - sparklineData date bucketing

    // sparklineData buckets by local calendar day on both the SQL and Swift
    // sides. A session whose UTC start_time falls on a different UTC day than
    // its local day (e.g. late-evening local time) must still land in the
    // local "today" bucket (index 6), not an adjacent one.
    @MainActor
    func testSparklineDataBucketsByLocalDay() throws {
        let repoPath = "/Users/test/repo"
        try insertGitRepo(at: dbPath, path: repoPath)
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
    func testActivityChartsBucketOvernightSessionByEndTime_repro() throws {
        let repoPath = "/Users/test/activity-time"
        try insertGitRepo(at: dbPath, path: repoPath)
        let start = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8 * 86_400))
        let end = ISO8601DateFormatter().string(from: Date())
        try insertSessionWithCwd(
            at: dbPath,
            id: "overnight-activity-chart",
            cwd: repoPath,
            startTime: start
        )
        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(
                sql: "UPDATE sessions SET end_time = ? WHERE id = 'overnight-activity-chart'",
                arguments: [end]
            )
        }

        XCTAssertEqual(try db.dailyActivity(days: 7).reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(
            try db.dailySourceActivity(days: 7).flatMap(\.segments).reduce(0) { $0 + $1.count },
            1
        )
        XCTAssertEqual(try db.sparklineData(for: repoPath)[6], 1)
        let group = try XCTUnwrap(try db.listSessionsByProject().first { $0.project == "engram" })
        XCTAssertEqual(group.lastActive, end)
        XCTAssertEqual(group.sessions.first?.id, "overnight-activity-chart")
        let endHour = Calendar.current.component(.hour, from: Date())
        XCTAssertEqual(try db.hourlyActivity()[endHour], 1)
    }

    func testSparklineParserPinsGregorianPOSIXCalendar_repro() throws {
        let macOSRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Core/Database.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "func sparklineData(for repoPath:"))
        let end = try XCTUnwrap(source.range(of: "func listSessionsByProject(", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("Calendar(identifier: .gregorian)"))
        XCTAssertTrue(body.contains("Locale(identifier: \"en_US_POSIX\")"))
    }

    @MainActor
    func testSparklineDataMatchesCwdPrefixOnly() throws {
        try insertGitRepo(at: dbPath, path: "/Users/test/repo")
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
        try insertGitRepo(at: dbPath, path: "/Users/test/app")
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
    func testSparklineDataPrefersLongestRepoOverStaleAlias_repro() throws {
        try insertGitRepo(at: dbPath, path: "/Users/test")
        try insertGitRepo(at: dbPath, path: "/Users/test/engram")
        let today = ISO8601DateFormatter().string(from: Date())
        try insertSessionWithCwd(
            at: dbPath,
            id: "nested-stale-alias",
            cwd: "/Users/test/engram",
            startTime: today
        )
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(
                sql: "INSERT INTO git_repo_cwd_aliases(cwd, real_cwd, repo_path) VALUES (?, ?, ?)",
                arguments: ["/Users/test/engram", "/Users/test/engram", "/Users/test"]
            )
        }

        XCTAssertEqual(try db.sparklineData(for: "/Users/test").reduce(0, +), 0)
        XCTAssertEqual(try db.sparklineData(for: "/Users/test/engram").reduce(0, +), 1)
    }

    @MainActor
    func testSparklineDataMatchesRealpathEquivalentWithoutStoredAlias_repro() throws {
        let name = "engram-sparkline-realpath-\(UUID().uuidString)"
        let storedPath = "/private/tmp/\(name)"
        try insertGitRepo(at: dbPath, path: storedPath)
        try insertSessionWithCwd(
            at: dbPath,
            id: "sparkline-realpath-equivalent",
            cwd: "/tmp/\(name)/subdir",
            startTime: ISO8601DateFormatter().string(from: Date())
        )

        XCTAssertEqual(try db.sparklineData(for: storedPath).reduce(0, +), 1)
    }

    @MainActor
    func testSparklineDataEscapesLikeWildcards() throws {
        try insertGitRepo(at: dbPath, path: "/Users/test/my_repo")
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
        startTime: String,
        tier: String? = "normal"
    ) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO sessions (
                    id, source, start_time, end_time, cwd, project,
                    message_count, file_path, size_bytes, indexed_at, tier,
                    instruction_count, human_turn_count
                ) VALUES (?, 'claude-code', ?, NULL, ?, 'engram', 1, '/tmp/test.jsonl', 0, datetime('now'), ?, 2, 2)
            """, arguments: [id, startTime, cwd, tier])
        }
    }

    private func insertGitRepo(at databasePath: String, path: String) throws {
        let queue = try DatabaseQueue(path: databasePath)
        try queue.write { database in
            try database.execute(
                sql: "INSERT INTO git_repos (path, name) VALUES (?, ?)",
                arguments: [path, URL(fileURLWithPath: path).lastPathComponent]
            )
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

    func testFiniteWorkTimelineExcludesUnknownActionDates_repro() throws {
        try seedWorkBeats(at: dbPath)
        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(
                sql: """
                    INSERT INTO session_work_beats (
                      session_id, beat_index, action_date, action_timestamp,
                      work_key, work_title, human_intent, assistant_outcome,
                      kind, status, operation_events, confidence
                    ) VALUES ('s-alpha', 1, 'unknown', NULL, 'wk-unknown', 'Unknown date',
                              'intent', 'outcome', 'implementation', 'complete', '[]', 0.5)
                    """
            )
        }

        XCTAssertEqual(
            try db.implementationTimeline(days: 100_000, project: "alpha", humanDriven: false).map(\.workKey),
            ["wk-alpha"]
        )
    }

    func testImplementationTimelinePromotesSuggestedChildOfHiddenHost_repro() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(sql: """
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
                )
                """)
            try database.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, file_path, message_count,
                  user_message_count, instruction_count, human_turn_count, tier,
                  suggested_parent_id, hidden_at
                ) VALUES
                  ('timeline-hidden-host', 'claude-code', '2026-08-24T10:00:00Z', '/tmp/timeline',
                   'timeline-promote', '/tmp/host.jsonl', 1, 1, 1, 1, 'normal', NULL,
                   '2026-08-24T10:30:00Z'),
                  ('timeline-promoted-child', 'gemini-cli', '2026-08-24T11:00:00Z', '/tmp/timeline',
                   'timeline-promote', '/tmp/child.jsonl', 4, 1, NULL, NULL, 'normal',
                   'timeline-hidden-host', NULL)
                """)
            try database.execute(sql: """
                INSERT INTO session_work_beats (
                  session_id, beat_index, action_date, action_timestamp,
                  work_key, work_title, human_intent, assistant_outcome,
                  kind, status, operation_events, confidence
                ) VALUES ('timeline-promoted-child', 0, '2026-08-24', '2026-08-24T11:30:00Z',
                          'wk-promoted-child', 'Promoted work', 'human request', 'completed',
                          'implementation', 'complete', '[]', 0.9)
                """)
        }

        XCTAssertEqual(
            try db.implementationTimeline(days: 100_000, project: "timeline-promote", humanDriven: false)
                .map(\.workKey),
            ["wk-promoted-child"]
        )
        XCTAssertTrue(
            try db.implementationTimelineProjects(days: 100_000, humanDriven: false)
                .contains("timeline-promote")
        )
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

    private func copyMCPContractFixture() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repositoryRoot.appendingPathComponent("tests/fixtures/mcp-contract.sqlite")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("arch-001d-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination.path
    }

    private func keepFixtureWALOpen(at path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path)
        try queue.writeWithoutTransaction { db in
            let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            XCTAssertEqual(mode?.lowercased(), "wal")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "CREATE TABLE arch001d_fixture_keepalive (value INTEGER NOT NULL)")
        }
        return queue
    }

    private func appKeywordSearchSessionIDs(
        query: String,
        limit: Int,
        databasePath: String
    ) throws -> Set<String> {
        let reader = DatabaseManager(path: databasePath)
        try reader.open()
        return Set(try reader.search(query: query, limit: limit).map(\.id))
    }

    private func serviceKeywordSearchSessionIDs(
        query: String,
        limit: Int,
        databasePath: String
    ) async throws -> Set<String> {
        let reader = try EngramServiceCore.SQLiteEngramServiceReadProvider(
            databasePath: databasePath
        )
        let response = try await reader.search(
            EngramServiceCore.EngramServiceSearchRequest(
                query: query,
                mode: "keyword",
                limit: limit
            )
        )
        return Set(response.items.map(\.id))
    }

    private func mcpKeywordSearchSessionIDs(
        query: String,
        limit: Int,
        databasePath: String
    ) throws -> Set<String> {
        let executableURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers/EngramMCP")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: executableURL.path),
            "missing native MCP helper at \(executableURL.path)"
        )

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "search",
                "arguments": [
                    "query": query,
                    "mode": "keyword",
                    "limit": limit,
                ],
            ],
        ]
        var requestData = try JSONSerialization.data(withJSONObject: request)
        requestData.append(0x0A)

        let process = Process()
        process.executableURL = executableURL
        let sandbox = try makeHermeticRPCEnvironment(overrides: [
            "ENGRAM_MCP_DB_PATH": databasePath,
        ])
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        process.environment = sandbox.environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        stdinPipe.fileHandleForWriting.write(requestData)
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)

        let line = try XCTUnwrap(
            String(data: output, encoding: .utf8)?.split(separator: "\n").first
        )
        let responseData = Data(line.utf8)
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let results = try XCTUnwrap(structured["results"] as? [[String: Any]])
        return Set(results.compactMap { result in
            (result["session"] as? [String: Any])?["id"] as? String
        })
    }
}

private func createLegacySessionsTableWithoutAccessMetadata(at path: String) throws {
    let configuration = Configuration()
    let queue = try DatabaseQueue(path: path, configuration: configuration)
    try queue.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA journal_mode = WAL")
    }
    try queue.write { db in
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
