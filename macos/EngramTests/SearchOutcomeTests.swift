import XCTest
@testable import Engram

/// Locks the SearchPageView result-state classifier so a backend double-fault
/// stays distinguishable from a genuine no-match (search-2/3, xc-states-4,
/// command-palette-5).
final class SearchOutcomeTests: XCTestCase {
    private func result(_ id: String) -> SearchResult {
        SearchResult(id: id, session: nil, snippet: "", matchType: "keyword", score: 0)
    }

    func testEmptyQueryIsEmpty() {
        XCTAssertEqual(SearchOutcome.classify(query: "", results: [], didFail: false), .empty)
    }

    func testWhitespaceQueryIsEmpty() {
        XCTAssertEqual(SearchOutcome.classify(query: "   \n", results: [], didFail: false), .empty)
    }

    func testNonEmptyQueryWithResultsIsResults() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", results: [result("a")], didFail: false),
            .results
        )
    }

    func testNonEmptyQueryNoResultsNoFailureIsEmpty() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", results: [], didFail: false),
            .empty
        )
    }

    func testDoubleFaultIsFailed() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", results: [], didFail: true),
            .failed
        )
    }

    func testFailureWinsOverStaleResults() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", results: [result("a")], didFail: true),
            .failed
        )
    }

    // MARK: - Bool overload (CommandPaletteView session search)

    func testBoolOverloadEmptyQueryIsEmpty() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "", isEmptyResults: true, didFail: false),
            .empty
        )
    }

    func testBoolOverloadWhitespaceQueryIsEmpty() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "   \n", isEmptyResults: true, didFail: false),
            .empty
        )
    }

    func testBoolOverloadWithResultsIsResults() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: false, didFail: false),
            .results
        )
    }

    func testBoolOverloadNoResultsNoFailureIsEmpty() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: true, didFail: false),
            .empty
        )
    }

    func testBoolOverloadDoubleFaultIsFailed() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: true, didFail: true),
            .failed
        )
    }

    func testBoolOverloadFailureWinsOverStaleResults() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: false, didFail: true),
            .failed
        )
    }
}
