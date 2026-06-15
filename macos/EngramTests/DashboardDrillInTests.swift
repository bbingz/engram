// macos/EngramTests/DashboardDrillInTests.swift
import XCTest
import GRDB
@testable import Engram

/// WP10 — covers the two additive read contracts the dashboard drill-in views
/// rely on: db.fileActivity (Activity "Top Files") and db.sessionsForRepo
/// (RepoDetail related sessions, anchored cwd-prefix). SwiftUI body rendering
/// and the .openSession wiring are not unit-testable here; they reuse the
/// verified MainWindowView handler + the in-file TimelinePageView precedent.
final class DashboardDrillInTests: XCTestCase {
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
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
    }

    // MARK: - helpers

    /// Create the service-owned session_files extension table inline (like
    /// insertFavorite for favorites — the app read model never creates it).
    private func createSessionFilesTable() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_files (
                    session_id TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    action TEXT NOT NULL,
                    count INTEGER NOT NULL DEFAULT 1
                )
            """)
        }
    }

    private func insertSessionFile(sessionId: String, filePath: String, action: String, count: Int) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO session_files (session_id, file_path, action, count) VALUES (?, ?, ?, ?)",
                arguments: [sessionId, filePath, action, count]
            )
        }
    }

    /// Raw INSERT supplying every NOT NULL column (id, source, start_time,
    /// file_path; project nullable) so we can vary cwd — insertTestSession
    /// hardcodes cwd and exposes no parameter.
    private func insertSessionWithCwd(
        id: String,
        cwd: String,
        project: String? = nil,
        startTime: String = "2026-03-20T10:00:00Z",
        hiddenAt: String? = nil
    ) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, cwd, project, file_path, hidden_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, "claude-code", startTime, cwd, project, "/tmp/\(id).jsonl", hiddenAt])
        }
    }

    // MARK: - fileActivity

    @MainActor
    func testFileActivityReturnsAggregatedRows() throws {
        try createSessionFilesTable()
        try insertTestSession(at: dbPath, id: "s1")
        try insertSessionFile(sessionId: "s1", filePath: "/a/Main.swift", action: "edit", count: 3)
        try insertSessionFile(sessionId: "s1", filePath: "/a/Main.swift", action: "edit", count: 2)
        try insertSessionFile(sessionId: "s1", filePath: "/a/README.md", action: "read", count: 1)

        let rows = try db.fileActivity(project: nil, since: nil, limit: 10)
        XCTAssertEqual(rows.count, 2)
        // Ordered by total_count DESC — the edited file (SUM 5) comes first.
        XCTAssertEqual(rows[0].filePath, "/a/Main.swift")
        XCTAssertEqual(rows[0].action, "edit")
        XCTAssertEqual(rows[0].totalCount, 5)
        XCTAssertEqual(rows[0].sessionCount, 1)
        XCTAssertEqual(rows[1].filePath, "/a/README.md")
        XCTAssertEqual(rows[1].totalCount, 1)
    }

    @MainActor
    func testFileActivityReturnsEmptyWhenTableAbsent() throws {
        // No session_files table created → tableExists guard returns [].
        let rows = try db.fileActivity(project: nil, since: nil, limit: 10)
        XCTAssertTrue(rows.isEmpty)
    }

    @MainActor
    func testFileActivityProjectAndSinceFilters() throws {
        try createSessionFilesTable()
        try insertTestSession(at: dbPath, id: "old", project: "alpha", startTime: "2026-01-01T10:00:00Z")
        try insertTestSession(at: dbPath, id: "new", project: "beta", startTime: "2026-05-01T10:00:00Z")
        try insertSessionFile(sessionId: "old", filePath: "/x/Old.swift", action: "edit", count: 4)
        try insertSessionFile(sessionId: "new", filePath: "/x/New.swift", action: "edit", count: 7)

        // project filter scopes to beta only.
        let byProject = try db.fileActivity(project: "beta", since: nil, limit: 10)
        XCTAssertEqual(byProject.map(\.filePath), ["/x/New.swift"])

        // since filter excludes the January session.
        let bySince = try db.fileActivity(project: nil, since: "2026-03-01T00:00:00Z", limit: 10)
        XCTAssertEqual(bySince.map(\.filePath), ["/x/New.swift"])
    }

    // MARK: - sessionsForRepo

    @MainActor
    func testSessionsForRepoUsesAnchoredCwdPrefix() throws {
        try insertSessionWithCwd(id: "app", cwd: "/Users/a/app")
        try insertSessionWithCwd(id: "webhook", cwd: "/Users/a/webhook")
        // Trailing-collision row that proves anchoring beats a substring match.
        try insertSessionWithCwd(id: "appv2", cwd: "/Users/a/app-v2")

        let rows = try db.sessionsForRepo(path: "/Users/a/app")
        XCTAssertEqual(rows.map(\.id), ["app"])
    }

    @MainActor
    func testSessionsForRepoExcludesHidden() throws {
        try insertSessionWithCwd(id: "visible", cwd: "/Users/a/app")
        try insertSessionWithCwd(id: "hidden", cwd: "/Users/a/app/sub", hiddenAt: "2026-03-21T10:00:00Z")

        let rows = try db.sessionsForRepo(path: "/Users/a/app")
        XCTAssertEqual(rows.map(\.id), ["visible"])
    }
}
