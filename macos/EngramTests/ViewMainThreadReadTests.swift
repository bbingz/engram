import XCTest

/// Source-inspection guards (mirroring AppSearchServiceCutoverScanTests) that
/// lock the off-main read + async-ordering fixes from audit round 2 (ui-1..7),
/// so these views don't regress to synchronous main-thread DB reads or
/// stale-response clobbering.
final class ViewMainThreadReadTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testTimelineViewReadsOffMainThread() throws {
        let s = try source("macos/Engram/Views/TimelineView.swift")
        XCTAssertTrue(s.contains("Task.detached"), "TimelineView reads must run off the main thread (ui-1)")
        XCTAssertFalse(
            s.contains("sessions = (try? db.listSessionsChronologically("),
            "TimelineView must not read sessions synchronously on the main thread"
        )
    }

    func testFavoritesViewReadsOffMainThread() throws {
        let s = try source("macos/Engram/Views/FavoritesView.swift")
        XCTAssertTrue(s.contains("Task.detached"), "FavoritesView must load favorites off the main thread (ui-5)")
        XCTAssertFalse(s.contains(".task { sessions = (try? db.listFavorites()) ?? [] }"))
    }

    func testAboutSettingsSectionReadsOffMainThread() throws {
        let s = try source("macos/Engram/Views/Settings/AboutSettingsSection.swift")
        XCTAssertTrue(s.contains("Task.detached"), "AboutSettingsSection must stat + count off the main thread (ui-6)")
        XCTAssertFalse(s.contains(".onAppear { loadInfo() }"), "must use .task with an async off-main loadInfo")
    }

    func testMainWindowNavigateReadsOffMainThread() throws {
        let s = try source("macos/Engram/Views/MainWindowView.swift")
        XCTAssertTrue(
            s.contains("Task.detached"),
            "navigateToSession must read the session off the main thread (ui-4)"
        )
    }

    func testSearchPageGuardsAgainstStaleResponses() throws {
        let s = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        XCTAssertTrue(
            s.contains("guard !Task.isCancelled"),
            "performSearch must guard against a superseded in-flight response clobbering results (ui-2)"
        )
    }

    func testExpandableSessionCardInvalidatesOnEitherCount() throws {
        let s = try source("macos/Engram/Components/ExpandableSessionCard.swift")
        XCTAssertTrue(
            s.contains("onChange(of: [confirmedChildCount, suggestedChildCount])"),
            "child cache must invalidate when either count changes, not just the sum (ui-3)"
        )
        XCTAssertFalse(s.contains("onChange(of: confirmedChildCount + suggestedChildCount)"))
    }

    func testFilterChangesUseCancellingTaskId() throws {
        let timeline = try source("macos/Engram/Views/Pages/TimelinePageView.swift")
        XCTAssertTrue(timeline.contains(".task(id: sortMode)"), "TimelinePageView must use a cancelling .task(id:) (ui-7)")
        XCTAssertFalse(timeline.contains("Task { await loadData() } }"))

        let sessions = try source("macos/Engram/Views/Pages/SessionsPageView.swift")
        XCTAssertTrue(sessions.contains(".task(id:"), "SessionsPageView must use a cancelling .task(id:) (ui-7)")
        XCTAssertFalse(sessions.contains(".onChange(of: timeFilter) { _, _ in Task { await loadData() } }"))
    }
}
