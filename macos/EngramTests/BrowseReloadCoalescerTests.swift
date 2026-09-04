import XCTest
@testable import Engram

/// Covers the pure debounce/coalesce + pagination-preservation decision behind
/// the browse-page index-tick fix (#3).
final class BrowseReloadCoalescerTests: XCTestCase {

    func testFirstRunReloadsImmediatelyAndResetsPagination() {
        // No prior key (first appear): load now, page one.
        let plan = BrowseReloadCoalescer.plan(filterKey: ["All Time"], lastFilterKey: nil)
        XCTAssertFalse(plan.debounce)
        XCTAssertFalse(plan.preservePagination)
    }

    func testFilterChangeReloadsImmediatelyAndResetsPagination() {
        let plan = BrowseReloadCoalescer.plan(filterKey: ["Today"], lastFilterKey: ["All Time"])
        XCTAssertFalse(plan.debounce)
        XCTAssertFalse(plan.preservePagination)
    }

    func testIndexTickDebouncesAndPreservesPagination() {
        // Same filters, task re-fired by a totalSessions bump: debounce + keep pages.
        let plan = BrowseReloadCoalescer.plan(filterKey: ["Today"], lastFilterKey: ["Today"])
        XCTAssertTrue(plan.debounce)
        XCTAssertTrue(plan.preservePagination)
    }

    func testEmptyFilterKeyPagesTickAfterFirstRun() {
        // No-filter pages (Projects/Activity): first run immediate, ticks debounced.
        let first = BrowseReloadCoalescer.plan(filterKey: [AnyHashable](), lastFilterKey: nil)
        XCTAssertFalse(first.debounce)
        let tick = BrowseReloadCoalescer.plan(filterKey: [AnyHashable](), lastFilterKey: [AnyHashable]())
        XCTAssertTrue(tick.debounce)
    }

    func testRefreshLimitKeepsSinglePage() {
        XCTAssertEqual(BrowseReloadCoalescer.refreshLimit(loadedCount: 200, pageSize: 200), 200)
        XCTAssertEqual(BrowseReloadCoalescer.refreshLimit(loadedCount: 0, pageSize: 200), 200)
        XCTAssertEqual(BrowseReloadCoalescer.refreshLimit(loadedCount: 150, pageSize: 200), 200)
    }

    func testRefreshLimitRoundsUpToWholePages() {
        // 400 rows on screen -> refetch 400, not 200.
        XCTAssertEqual(BrowseReloadCoalescer.refreshLimit(loadedCount: 400, pageSize: 200), 400)
        // 401 rows (a dedup seam) rounds up to the next whole page.
        XCTAssertEqual(BrowseReloadCoalescer.refreshLimit(loadedCount: 401, pageSize: 200), 600)
    }

    // MARK: - SessionsPage load generation (favorite reload vs filter change)

    func testStaleFavoriteReloadDoesNotOverwriteNewerFilterLoad() {
        // Favorite mutation on filter A starts generation 1; user switches to
        // filter B which advances to generation 2. When A finishes last, drop it.
        XCTAssertTrue(
            SessionsPageView.shouldApplyLoad(resultGeneration: 2, currentGeneration: 2),
            "newest filter-B load must apply"
        )
        XCTAssertFalse(
            SessionsPageView.shouldApplyLoad(resultGeneration: 1, currentGeneration: 2),
            "stale favorite reload for filter A must not overwrite filter B"
        )
    }

    func testCancelledLoadDoesNotApplyEvenWhenGenerationMatches() {
        XCTAssertFalse(
            SessionsPageView.shouldApplyLoad(
                resultGeneration: 3,
                currentGeneration: 3,
                isCancelled: true
            ),
            "cancelled favoriteReloadTask must not publish results"
        )
        XCTAssertTrue(
            SessionsPageView.shouldApplyLoad(
                resultGeneration: 3,
                currentGeneration: 3,
                isCancelled: false
            )
        )
    }

    func testTimelineStaleDetachedLoadDoesNotOverwriteNewerFilterLoad_repro() {
        XCTAssertTrue(TimelinePageView.shouldApplyLoad(resultGeneration: 2, currentGeneration: 2))
        XCTAssertFalse(TimelinePageView.shouldApplyLoad(resultGeneration: 1, currentGeneration: 2))
        XCTAssertFalse(TimelinePageView.shouldApplyLoad(resultGeneration: 2, currentGeneration: 2, isCancelled: true))
    }

    func testTimelineRendersOnlyTheDatabaseScopedSnapshot_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/TimelinePageView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("filteredTimeline"))
        XCTAssertTrue(source.contains("let timelineSnapshot = timeline"))
        XCTAssertTrue(source.contains("ForEach(timelineSnapshot"))
    }

    func testTimelineReconcilesProjectBeforeFetchingAndAppliesOneSnapshot_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/TimelinePageView.swift"),
            encoding: .utf8
        )
        let loadStart = try XCTUnwrap(source.range(of: "private func loadData(preservePagination: Bool = false) async"))
        let loadBody = source[loadStart.lowerBound...]
        let projects = try XCTUnwrap(loadBody.range(of: "let projects ="))
        let reconcile = try XCTUnwrap(loadBody.range(of: "reconciledProjectSelection("))
        let filter = try XCTUnwrap(loadBody.range(of: "let selectedProjectFilter ="))
        XCTAssertLessThan(projects.lowerBound, reconcile.lowerBound)
        XCTAssertLessThan(reconcile.lowerBound, filter.lowerBound)
        XCTAssertFalse(loadBody.contains("selectedProject = reconciledProject\n                return"))
        XCTAssertTrue(loadBody.contains("selectedProject = data.selectedProject"))
    }

    func testTimelineFilterLoadingAndFailureDoNotExposePriorFilterSnapshot_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/TimelinePageView.swift"),
            encoding: .utf8
        )
        let bodyStart = try XCTUnwrap(source.range(of: "var body: some View"))
        let loadStart = try XCTUnwrap(source.range(of: "private func loadData(preservePagination: Bool = false) async"))
        let body = String(source[bodyStart.lowerBound..<loadStart.lowerBound])
        XCTAssertTrue(body.contains("if !isLoading && selectedProject == appliedProject"))
        XCTAssertTrue(body.contains("&& !visibleChartDataSnapshot.isEmpty"))
        XCTAssertTrue(body.contains("if isLoading {"))
        XCTAssertFalse(body.contains("if isLoading && !hasVisibleContentSnapshot {"))

        let loadBody = String(source[loadStart.lowerBound...])
        let detachedStart = try XCTUnwrap(loadBody.range(of: "let data = try await Task.detached"))
        let beforeRead = String(loadBody[..<detachedStart.lowerBound])
        XCTAssertTrue(
            beforeRead.contains("if !preservePagination {\n            isLoading = true\n            clearVisibleSnapshot()"),
            "filter identity changes must clear the old snapshot before the detached read starts"
        )
        let catchStart = try XCTUnwrap(loadBody.range(of: "} catch {"))
        let catchBody = String(loadBody[catchStart.lowerBound...])
        XCTAssertTrue(catchBody.contains("if !preservePagination"))
        XCTAssertTrue(catchBody.contains("clearVisibleSnapshot()"))
    }

    func testTimelineHeaderBadgeUsesOnlyAppliedSnapshot_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/TimelinePageView.swift"),
            encoding: .utf8
        )
        let bodyStart = try XCTUnwrap(source.range(of: "var body: some View"))
        let loadStart = try XCTUnwrap(source.range(of: "private func loadData(preservePagination: Bool = false) async"))
        let body = String(source[bodyStart.lowerBound..<loadStart.lowerBound])

        XCTAssertTrue(source.contains("@State private var appliedRange"))
        XCTAssertTrue(source.contains("@State private var appliedMode"))
        XCTAssertTrue(body.contains("range: appliedRange.badge"))
        XCTAssertFalse(body.contains("range: range.badge"))
        XCTAssertTrue(body.contains("let headerSnapshotMatchesSelection"))
        XCTAssertTrue(source.contains("appliedRange = data.range"))
        XCTAssertTrue(source.contains("appliedMode = data.mode"))
    }

    func testTimelineRenderingUsesTheAppliedModeAndSortSnapshot_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let value = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/TimelinePageView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(value.contains("@State private var appliedSort"))
        XCTAssertTrue(value.contains("let visibleModeSnapshot = appliedMode"))
        XCTAssertTrue(value.contains("sortMode == appliedSort"))
    }

    func testTimelineIndexTickPreservesVisibleSnapshotWithoutFullSpinner_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/TimelinePageView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("await loadData(preservePagination: plan.preservePagination)"))
        XCTAssertTrue(source.contains("private func loadData(preservePagination: Bool = false) async"))
        let loadStart = try XCTUnwrap(source.range(of: "private func loadData(preservePagination: Bool = false) async"))
        let detachedStart = try XCTUnwrap(
            source.range(of: "let data = try await Task.detached", range: loadStart.upperBound..<source.endIndex)
        )
        let beforeRead = String(source[loadStart.lowerBound..<detachedStart.lowerBound])
        XCTAssertTrue(beforeRead.contains("if !preservePagination {\n            isLoading = true"))
        XCTAssertTrue(beforeRead.contains("clearVisibleSnapshot()"))

        let handlersStart = try XCTUnwrap(source.range(of: "private var handlers:"))
        let exportStart = try XCTUnwrap(
            source.range(of: "private func export", range: handlersStart.upperBound..<source.endIndex)
        )
        let handlers = String(source[handlersStart.lowerBound..<exportStart.lowerBound])
        XCTAssertTrue(
            handlers.contains("reload: { await loadData(preservePagination: true) }"),
            "favorite/hide/rename mutations must keep the current snapshot until replacement lands"
        )

        let confirmStart = try XCTUnwrap(source.range(of: "private func confirmSuggestion"))
        let beginRenameStart = try XCTUnwrap(
            source.range(of: "private func beginRename", range: confirmStart.upperBound..<source.endIndex)
        )
        let suggestionMutations = String(source[confirmStart.lowerBound..<beginRenameStart.lowerBound])
        XCTAssertEqual(
            suggestionMutations.components(separatedBy: "await loadData(preservePagination: true)").count - 1,
            2,
            "confirm and dismiss are mutations and must preserve the visible snapshot"
        )
        XCTAssertFalse(suggestionMutations.contains("await loadData()"))
    }

    func testBrowsePagesRejectStaleDetachedLoadsAndSpinnerClears_repro() {
        XCTAssertTrue(
            BrowseReloadCoalescer.shouldApplyLoad(
                resultGeneration: 4,
                currentGeneration: 4
            )
        )
        XCTAssertFalse(
            BrowseReloadCoalescer.shouldApplyLoad(
                resultGeneration: 3,
                currentGeneration: 4
            )
        )
        XCTAssertFalse(
            BrowseReloadCoalescer.shouldApplyLoad(
                resultGeneration: 4,
                currentGeneration: 4,
                isCancelled: true
            )
        )
    }
}
