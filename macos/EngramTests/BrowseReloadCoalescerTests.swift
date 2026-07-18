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
}
