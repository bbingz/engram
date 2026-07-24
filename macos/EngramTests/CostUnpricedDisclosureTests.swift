import XCTest
@testable import Engram

final class CostUnpricedDisclosureTests: XCTestCase {
    func testShowsUnpricedRowWhenAnyCountNonZero() {
        let zero = EngramServiceCostsResponse(
            totalUsd: 1, perSource: [], perDay: [], monthToDateUsd: 0, todayUsd: 0
        )
        XCTAssertFalse(CostSummarySection.showsUnpricedRow(zero))
        XCTAssertFalse(CostSummarySection.showsUnpricedRow(nil))

        let unpriced = EngramServiceCostsResponse(
            totalUsd: 1, perSource: [], perDay: [], monthToDateUsd: 0, todayUsd: 0,
            unpricedUnattributedSessions: 1
        )
        XCTAssertTrue(CostSummarySection.showsUnpricedRow(unpriced))
    }
}
