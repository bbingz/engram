import EngramCoreRead
import XCTest

/// R1: shared list/aggregate visibility predicates stay consistent across surfaces.
final class SessionVisibilityFilterTests: XCTestCase {
    func testNonSkipAndListVisibleSQLShape() {
        let bare = SessionVisibilityFilter.nonSkipTierSQL
        XCTAssertTrue(bare.contains("tier IS NULL"))
        XCTAssertTrue(bare.contains("tier != 'skip'"))
        XCTAssertFalse(bare.contains("lite"), "list surfaces keep lite visible")

        let aliased = SessionVisibilityFilter.nonSkipTierSQL(alias: "s")
        XCTAssertTrue(aliased.contains("s.tier IS NULL"))
        XCTAssertTrue(aliased.contains("s.tier != 'skip'"))
        XCTAssertFalse(aliased.contains("s.s."))

        let list = SessionVisibilityFilter.listVisibleSQL
        XCTAssertTrue(list.contains(SessionVisibilityFilter.notHiddenSQL))
        XCTAssertTrue(list.contains(SessionVisibilityFilter.nonSkipTierSQL))

        let listAliased = SessionVisibilityFilter.listVisibleSQL(alias: "s")
        XCTAssertTrue(listAliased.contains("s.hidden_at IS NULL"))
        XCTAssertTrue(listAliased.contains("s.tier != 'skip'"))
    }

    func testSearchableTierIsStricterThanListVisible() {
        // Search excludes lite; list/KPI does not.
        XCTAssertTrue(SessionSemanticSearchPolicy.searchableTierSQL.contains("'lite'"))
        XCTAssertFalse(SessionVisibilityFilter.nonSkipTierSQL.contains("lite"))
    }
}
