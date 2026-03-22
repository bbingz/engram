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
}
