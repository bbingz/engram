import XCTest

/// L30 / MCP-HYBRID-ZIP-001: hybrid fusion must index semantic hits by session id,
/// not zip(ids, items) which mislabels when a session disappears mid-search.
final class MCPSearchResultIndexTests: XCTestCase {
    func testBySessionIdIgnoresPositionalAlignment_repro() {
        // Simulate searchResultItems dropping the middle id (deleted row):
        // ids = [a, b, c] but only items for a and c survive, in that order.
        struct Item: Equatable {
            let id: String
            let matchType: String
        }
        let survivingItems = [
            Item(id: "sess-a", matchType: "semantic"),
            Item(id: "sess-c", matchType: "semantic"),
        ]
        let originalIds = ["sess-a", "sess-b", "sess-c"]

        let byId = Dictionary(uniqueKeysWithValues: survivingItems.map { ($0.id, $0) })
        XCTAssertEqual(Set(byId.keys), Set(["sess-a", "sess-c"]))
        XCTAssertEqual(byId["sess-a"]?.id, "sess-a")
        XCTAssertEqual(byId["sess-c"]?.id, "sess-c")

        // Positional zip against the original id list pairs c with b.
        let zipMisaligned = Dictionary(uniqueKeysWithValues: zip(originalIds, survivingItems))
        XCTAssertEqual(
            zipMisaligned["sess-b"]?.id,
            "sess-c",
            "documents the pre-fix mislabel: zip assigns surviving item C to deleted id B"
        )
        XCTAssertNil(byId["sess-b"], "id-keyed index must not invent a mapping for dropped sessions")
    }

    func testHybridSourceUsesIdKeyedIndexNotZip_repro() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/EngramMCP/Core/MCPDatabase.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("MCPSearchResultIndex.bySessionId(semanticItems)"),
            "hybrid fusion must index semantic items by session id"
        )
        XCTAssertFalse(
            source.contains("zip(semanticSessionIds, semanticItems)"),
            "hybrid fusion must not positionally zip semantic ids to items"
        )
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
