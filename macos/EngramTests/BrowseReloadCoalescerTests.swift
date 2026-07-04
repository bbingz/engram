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
}
