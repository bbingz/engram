// macos/EngramTests/ScreenSectionTests.swift
import XCTest
@testable import Engram

final class ScreenSectionTests: XCTestCase {
    var db: DatabaseManager!
    var dbPath: String!

    @MainActor
    override func setUpWithError() throws {
        let tempDir = FileManager.default.temporaryDirectory
        dbPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sqlite").path
        try createSessionsTable(at: dbPath)
        db = DatabaseManager(path: dbPath)
        try db.open()
    }

    @MainActor
    override func tearDownWithError() throws {
        db = nil
        cleanupTempDatabase(at: dbPath)
    }

    // MARK: - Favorites reachability (WP02)

    func testFavoritesScreenIsReachable() {
        let sidebarScreens = Screen.Section.allCases.flatMap { $0.screens }
        XCTAssertEqual(
            sidebarScreens.filter { $0 == .favorites }.count, 1,
            "Favorites must appear exactly once in the sidebar sections"
        )
        XCTAssertFalse(Screen.favorites.title.isEmpty)
        XCTAssertFalse(Screen.favorites.icon.isEmpty)
    }

    // MARK: - Pagination contract (backs sessions-browse-2, wired by WP01)

    @MainActor
    func testListSessionsPagination() throws {
        // Seed 5 sessions with distinct ids and descending start_times so the
        // createdDesc order is deterministic: s5 (newest) … s1 (oldest).
        for i in 1...5 {
            try insertTestSession(
                at: dbPath,
                id: "page-\(i)",
                startTime: String(format: "2026-03-2%dT10:00:00Z", i),
                generatedTitle: "Session \(i)"
            )
        }

        let page0 = try db.listSessions(sort: .createdDesc, limit: 2, offset: 0).map(\.id)
        let page1 = try db.listSessions(sort: .createdDesc, limit: 2, offset: 2).map(\.id)

        XCTAssertEqual(page0, ["page-5", "page-4"], "First page newest-first")
        XCTAssertEqual(page1, ["page-3", "page-2"], "Second page continues in order")
        XCTAssertTrue(
            Set(page0).isDisjoint(with: Set(page1)),
            "Offset pages must not overlap"
        )
    }
}
