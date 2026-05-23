import XCTest
@testable import Engram

final class SearchModeTests: XCTestCase {
    // No embeddings (sqlite-vec not implemented) -> keyword only, so the UI
    // never advertises semantic/hybrid modes it cannot serve.
    func testKeywordOnlyWhenEmbeddingsUnavailable() {
        XCTAssertEqual(SearchMode.availableModes(embeddingAvailable: false), [.keyword])
    }

    // When embeddings become available the richer modes return.
    func testRicherModesWhenEmbeddingsAvailable() {
        XCTAssertEqual(
            SearchMode.availableModes(embeddingAvailable: true),
            [.hybrid, .keyword, .semantic]
        )
    }
}
