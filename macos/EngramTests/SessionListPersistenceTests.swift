import XCTest
@testable import Engram

final class SessionListPersistenceTests: XCTestCase {
    // #6: sort order must round-trip through the persisted (key, ascending)
    // representation so it survives app restarts.
    func testSortKeyRoundTrips() {
        let cases: [(String, Bool)] = [
            ("source", true), ("displayTitle", false),
            ("messageCount", true), ("sizeBytes", false), ("startTime", true)
        ]
        for (key, asc) in cases {
            let comparator = SessionListView.comparator(forKey: key, ascending: asc)
            XCTAssertEqual(SessionListView.sortKey(for: comparator), key)
            XCTAssertEqual(comparator.order, asc ? .forward : .reverse)
        }
    }

    func testUnknownSortKeyFallsBackToStartTime() {
        let comparator = SessionListView.comparator(forKey: "bogus", ascending: false)
        XCTAssertEqual(SessionListView.sortKey(for: comparator), "startTime")
    }
}
