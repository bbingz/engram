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

    func testMainWindowNavigationIgnoresSupersededLookups() throws {
        let s = try source("macos/Engram/Views/MainWindowView.swift")
        XCTAssertTrue(
            s.contains("@State private var pendingNavigationId: String?"),
            "palette navigation must track the latest requested session id"
        )
        XCTAssertTrue(
            s.contains("guard pendingNavigationId == id else { return }"),
            "a slower session lookup must not overwrite a newer palette navigation"
        )
    }

    func testSearchPageGuardsAgainstStaleResponses() throws {
        let s = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        XCTAssertTrue(
            s.contains("guard !Task.isCancelled"),
            "performSearch must guard against a superseded in-flight response clobbering results (ui-2)"
        )
    }

    func testSearchPageCancelsWorkOnDisappear() throws {
        let s = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        XCTAssertTrue(s.contains("@State private var searchTask: Task<Void, Never>?"))
        XCTAssertTrue(
            s.contains(".onDisappear { searchTask?.cancel(); searchTask = nil }"),
            "SearchPageView must cancel delayed or in-flight search work when the page leaves the hierarchy"
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

    func testTimelinePageReusesDateFormatters() throws {
        let s = try source("macos/Engram/Views/Pages/TimelinePageView.swift")
        let start = try XCTUnwrap(s.range(of: "private func formatDateLabel"))
        let end = try XCTUnwrap(s.range(of: "private func sessionCountLabel"))
        let functionSource = String(s[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(s.contains("private static let inputDateFormatter"))
        XCTAssertTrue(s.contains("private static let outputDateFormatter"))
        XCTAssertFalse(
            functionSource.contains("DateFormatter()"),
            "formatDateLabel runs for every timeline group and must not allocate DateFormatter per call"
        )
    }

    func testSessionListIgnoresSupersededLoads() throws {
        let s = try source("macos/Engram/Views/SessionListView.swift")
        XCTAssertTrue(
            s.contains("@State private var loadGeneration = 0"),
            "SessionListView must track the latest load generation"
        )
        XCTAssertTrue(
            s.contains("guard loadGeneration == generation else { return }"),
            "a slower initial load must not overwrite a newer filtered load"
        )
    }

    func testLogStreamReloadsCancelSupersededWork() throws {
        let s = try source("macos/Engram/Views/Observability/LogStreamView.swift")
        XCTAssertTrue(s.contains("@State private var reloadTask: Task<Void, Never>?"))
        XCTAssertTrue(s.contains("reloadTask?.cancel()"))
        XCTAssertTrue(s.contains(".onDisappear { reloadTask?.cancel(); reloadTask = nil }"))
        XCTAssertFalse(s.contains(".onReceive(timer) { _ in Task { await reload() } }"))
        XCTAssertFalse(s.contains(".onChange(of: selectedLevel) { _, _ in Task { await reload() } }"))
        XCTAssertFalse(s.contains(".onChange(of: selectedModule) { _, _ in Task { await reload() } }"))
    }

    func testSettingsLoadsDoNotImmediatelyWriteBackUnchangedValues() throws {
        let ai = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        XCTAssertTrue(ai.contains("@State private var isLoadingSettings = false"))
        XCTAssertTrue(ai.contains("guard !isLoadingSettings else { return }"))
        XCTAssertTrue(ai.contains("defer { isLoadingSettings = false }"))

        let sources = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")
        XCTAssertTrue(sources.contains("@State private var isLoading = false"))
        XCTAssertTrue(sources.contains("guard !isLoading else { return }"))
        XCTAssertTrue(sources.contains("defer { isLoading = false }"))
    }

    func testDatabaseManagerIsNotGlobalMainActorIsolated() throws {
        let s = try source("macos/Engram/Core/Database.swift")
        XCTAssertFalse(
            s.contains("@MainActor\n@Observable\nfinal class DatabaseManager"),
            "DatabaseManager must not rely on a global MainActor annotation while views capture it into Task.detached"
        )
        XCTAssertTrue(s.contains("final class DatabaseManager: @unchecked Sendable"))
        XCTAssertFalse(s.contains("nonisolated(unsafe)"))
    }
}
