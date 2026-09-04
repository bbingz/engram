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

    func testActivitySourceDrillInScopesBeforeItsSingleRowLimit_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/ActivityView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("topLevelOnly: true"))
        XCTAssertTrue(source.contains("humanDriven: true"))
        XCTAssertFalse(source.contains("let session = try? await Task.detached"))
    }

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
        hiddenAt: String? = nil,
        tier: String? = "normal"
    ) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                    id, source, start_time, cwd, project, file_path, hidden_at, tier,
                    instruction_count, human_turn_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 2, 2)
            """, arguments: [id, "claude-code", startTime, cwd, project, "/tmp/\(id).jsonl", hiddenAt, tier])
        }
    }

    private func insertGitRepo(path: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO git_repos (path, name) VALUES (?, ?)",
                arguments: [path, URL(fileURLWithPath: path).lastPathComponent]
            )
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
        try insertTestSession(
            at: dbPath,
            id: "old",
            project: "alpha",
            startTime: "2026-01-01T10:00:00Z",
            endTime: "2026-01-01T11:00:00Z"
        )
        try insertTestSession(
            at: dbPath,
            id: "new",
            project: "beta",
            startTime: "2026-05-01T10:00:00Z",
            endTime: "2026-05-01T11:00:00Z"
        )
        try insertSessionFile(sessionId: "old", filePath: "/x/Old.swift", action: "edit", count: 4)
        try insertSessionFile(sessionId: "new", filePath: "/x/New.swift", action: "edit", count: 7)

        // project filter scopes to beta only.
        let byProject = try db.fileActivity(project: "beta", since: nil, limit: 10)
        XCTAssertEqual(byProject.map(\.filePath), ["/x/New.swift"])

        // since filter excludes the January session.
        let bySince = try db.fileActivity(project: nil, since: "2026-03-01T00:00:00Z", limit: 10)
        XCTAssertEqual(bySince.map(\.filePath), ["/x/New.swift"])
    }

    @MainActor
    func testFileActivitySinceUsesLatestSessionActivity_repro() throws {
        try createSessionFilesTable()
        try insertTestSession(
            at: dbPath,
            id: "active-after-cutoff",
            project: "alpha",
            startTime: "2026-02-28T23:00:00Z"
        )
        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(
                sql: "UPDATE sessions SET end_time = ? WHERE id = ?",
                arguments: ["2026-03-01T01:00:00Z", "active-after-cutoff"]
            )
        }
        try insertSessionFile(
            sessionId: "active-after-cutoff",
            filePath: "/x/Active.swift",
            action: "edit",
            count: 1
        )

        XCTAssertEqual(
            try db.fileActivity(project: nil, since: "2026-03-01T00:00:00Z", limit: 10).map(\.filePath),
            ["/x/Active.swift"]
        )
    }

    // ARCH-001C: file aggregates must use only list-visible sessions.
    @MainActor
    func testFileActivityExcludesHiddenAndSkipSessions_repro() throws {
        try createSessionFilesTable()
        try insertTestSession(at: dbPath, id: "file-visible", tier: "normal")
        try insertTestSession(
            at: dbPath,
            id: "file-hidden",
            tier: "normal",
            hiddenAt: "2026-03-21T10:00:00Z"
        )
        try insertTestSession(at: dbPath, id: "file-skip", tier: "skip")
        try insertSessionFile(sessionId: "file-visible", filePath: "/x/Shared.swift", action: "edit", count: 2)
        try insertSessionFile(sessionId: "file-hidden", filePath: "/x/Shared.swift", action: "edit", count: 100)
        try insertSessionFile(sessionId: "file-skip", filePath: "/x/Shared.swift", action: "edit", count: 50)

        let row = try XCTUnwrap(try db.fileActivity(project: nil, since: nil, limit: 10).first)
        XCTAssertEqual(row.totalCount, 2)
        XCTAssertEqual(row.sessionCount, 1)
    }

    @MainActor
    func testFileActivityExcludesChildAndNonHumanSessions_repro() throws {
        try createSessionFilesTable()
        try insertTestSession(at: dbPath, id: "human-parent")
        try insertTestSession(at: dbPath, id: "confirmed-child")
        try insertTestSession(at: dbPath, id: "single-shot-root")
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(
                sql: "UPDATE sessions SET instruction_count = 2, human_turn_count = 2 WHERE id IN ('human-parent', 'confirmed-child')"
            )
            try database.execute(
                sql: "UPDATE sessions SET instruction_count = 0, human_turn_count = 1, user_message_count = 1 WHERE id = 'single-shot-root'"
            )
            try database.execute(
                sql: "UPDATE sessions SET parent_session_id = 'human-parent' WHERE id = 'confirmed-child'"
            )
        }
        try insertSessionFile(sessionId: "human-parent", filePath: "/x/Parent.swift", action: "edit", count: 2)
        try insertSessionFile(sessionId: "confirmed-child", filePath: "/x/Child.swift", action: "edit", count: 100)
        try insertSessionFile(sessionId: "single-shot-root", filePath: "/x/Noise.swift", action: "edit", count: 200)

        XCTAssertEqual(
            try db.fileActivity(project: nil, since: nil, limit: 10).map(\.filePath),
            ["/x/Parent.swift"]
        )
    }

    // MARK: - sessionsForRepo

    @MainActor
    func testSessionsForRepoUsesAnchoredCwdPrefix() throws {
        try insertGitRepo(path: "/Users/a/app")
        try insertSessionWithCwd(id: "app", cwd: "/Users/a/app")
        try insertSessionWithCwd(id: "webhook", cwd: "/Users/a/webhook")
        // Trailing-collision row that proves anchoring beats a substring match.
        try insertSessionWithCwd(id: "appv2", cwd: "/Users/a/app-v2")

        let rows = try db.sessionsForRepo(path: "/Users/a/app")
        XCTAssertEqual(rows.map(\.id), ["app"])
    }

    @MainActor
    func testSessionsForRepoExcludesHidden() throws {
        try insertGitRepo(path: "/Users/a/app")
        try insertSessionWithCwd(id: "visible", cwd: "/Users/a/app")
        try insertSessionWithCwd(id: "hidden", cwd: "/Users/a/app/sub", hiddenAt: "2026-03-21T10:00:00Z")

        let rows = try db.sessionsForRepo(path: "/Users/a/app")
        XCTAssertEqual(rows.map(\.id), ["visible"])
    }

    // ARCH-001C: repo drill-in is a browse surface and must hide skip-tier rows.
    @MainActor
    func testSessionsForRepoExcludesSkipTier_repro() throws {
        try insertGitRepo(path: "/Users/a/app")
        try insertSessionWithCwd(id: "repo-visible", cwd: "/Users/a/app", tier: "normal")
        try insertSessionWithCwd(id: "repo-skip", cwd: "/Users/a/app/sub", tier: "skip")

        XCTAssertEqual(try db.sessionsForRepo(path: "/Users/a/app").map(\.id), ["repo-visible"])
    }

    @MainActor
    func testSessionsForRepoFiltersChildrenAndSingleShotRowsBeforeLimit_repro() throws {
        try insertGitRepo(path: "/Users/a/app")
        try insertSessionWithCwd(
            id: "human-parent",
            cwd: "/Users/a/app",
            startTime: "2026-03-01T10:00:00Z"
        )
        try insertSessionWithCwd(
            id: "single-shot",
            cwd: "/Users/a/app",
            startTime: "2026-03-31T10:00:00Z"
        )
        for index in 0..<12 {
            try insertSessionWithCwd(
                id: "child-\(index)",
                cwd: "/Users/a/app/sub",
                startTime: String(format: "2026-03-%02dT10:00:00Z", index + 2)
            )
        }
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(
                sql: "UPDATE sessions SET instruction_count = 2, human_turn_count = 2 WHERE id = 'human-parent'"
            )
            try database.execute(
                sql: "UPDATE sessions SET instruction_count = 0, human_turn_count = 1, user_message_count = 1 WHERE id = 'single-shot'"
            )
            try database.execute(
                sql: "UPDATE sessions SET parent_session_id = 'human-parent' WHERE id LIKE 'child-%'"
            )
        }

        XCTAssertEqual(try db.sessionsForRepo(path: "/Users/a/app", limit: 1).map(\.id), ["human-parent"])
    }

    @MainActor
    func testSessionsForRepoPrefersLongestRepoOverStaleAlias_repro() throws {
        try insertGitRepo(path: "/Users/a")
        try insertGitRepo(path: "/Users/a/app")
        try insertSessionWithCwd(id: "nested-stale-alias", cwd: "/Users/a/app")
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { database in
            try database.execute(
                sql: "INSERT INTO git_repo_cwd_aliases(cwd, real_cwd, repo_path) VALUES (?, ?, ?)",
                arguments: ["/Users/a/app", "/Users/a/app", "/Users/a"]
            )
        }

        XCTAssertEqual(try db.sessionsForRepo(path: "/Users/a").map(\.id), [])
        XCTAssertEqual(try db.sessionsForRepo(path: "/Users/a/app").map(\.id), ["nested-stale-alias"])
    }

    @MainActor
    func testSessionsForRepoMatchesRealpathEquivalentWithoutStoredAlias_repro() throws {
        let name = "engram-realpath-\(UUID().uuidString)"
        let storedPath = "/private/tmp/\(name)"
        try insertGitRepo(path: storedPath)
        try insertSessionWithCwd(id: "realpath-equivalent", cwd: "/tmp/\(name)/subdir")

        XCTAssertEqual(try db.sessionsForRepo(path: storedPath).map(\.id), ["realpath-equivalent"])
    }

    @MainActor
    func testSessionsForRepoOrdersByLatestActivity_repro() throws {
        try insertGitRepo(path: "/Users/a/app")
        try insertSessionWithCwd(
            id: "started-newer",
            cwd: "/Users/a/app",
            startTime: "2026-08-24T11:00:00Z"
        )
        try insertSessionWithCwd(
            id: "ended-newer",
            cwd: "/Users/a/app",
            startTime: "2026-08-24T09:00:00Z"
        )
        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(
                sql: "UPDATE sessions SET end_time = ? WHERE id = ?",
                arguments: ["2026-08-24T12:00:00Z", "ended-newer"]
            )
        }

        XCTAssertEqual(
            try db.sessionsForRepo(path: "/Users/a/app").map(\.id),
            ["ended-newer", "started-newer"]
        )
    }

    @MainActor
    func testRepoSparklineMatchesRepoDetailRootPopulation_repro() throws {
        try insertGitRepo(path: "/Users/a/app")
        let now = ISO8601DateFormatter().string(from: Date())
        try insertSessionWithCwd(id: "human-root", cwd: "/Users/a/app", startTime: now)
        try insertSessionWithCwd(id: "confirmed-child", cwd: "/Users/a/app/sub", startTime: now)
        try insertSessionWithCwd(id: "single-shot-root", cwd: "/Users/a/app", startTime: now)
        try DatabaseQueue(path: dbPath).write { database in
            try database.execute(
                sql: "UPDATE sessions SET parent_session_id = 'human-root' WHERE id = 'confirmed-child'"
            )
            try database.execute(
                sql: "UPDATE sessions SET instruction_count = 0, human_turn_count = 1, user_message_count = 1 WHERE id = 'single-shot-root'"
            )
        }

        let detailCount = try db.sessionsForRepo(path: "/Users/a/app").count
        let sparklineCount = try db.sparklineData(for: "/Users/a/app").reduce(0, +)
        XCTAssertEqual(detailCount, 1)
        XCTAssertEqual(sparklineCount, detailCount)
    }
}
