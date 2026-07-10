import XCTest
@testable import Engram

final class SearchModeTests: XCTestCase {
    // App UI is intentionally keyword-only even when embeddings exist for
    // service/MCP semantic search (wave-6). Mode pills are a deliberate non-goal.
    func testKeywordOnlyWhenEmbeddingsUnavailable() {
        XCTAssertEqual(SearchMode.availableModes(embeddingAvailable: false), [.keyword])
    }

    func testAppUIStaysKeywordOnlyWhenEmbeddingsAvailable() {
        XCTAssertEqual(
            SearchMode.availableModes(embeddingAvailable: true),
            [.keyword]
        )
    }
}
