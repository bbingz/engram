import XCTest
@testable import Engram

final class SearchModeTests: XCTestCase {
    // No embeddings (sqlite-vec not implemented) -> keyword only, so the UI
    // never advertises semantic/hybrid modes it cannot serve.
    func testKeywordOnlyWhenEmbeddingsUnavailable() {
        XCTAssertEqual(SearchMode.availableModes(embeddingAvailable: false), [.keyword])
    }

    // The current Swift service search path is keyword-only even if old
    // embedding rows exist in the database, so the UI must not advertise richer
    // modes until a real vector query path ships.
    func testKeywordOnlyEvenWhenLegacyEmbeddingRowsExist() {
        XCTAssertEqual(
            SearchMode.availableModes(embeddingAvailable: true),
            [.keyword]
        )
    }
}
