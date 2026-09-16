import Foundation
import GRDB
import XCTest
import EngramCoreRead
import EngramCoreWrite
@testable import EngramServiceCore

final class ServiceSearchInsightTests: XCTestCase {
    func testKeywordSearchFallsBackToInsightFTSWhenSessionsAreEmpty() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try insertInsight(fixture, id: "insight-fts", content: "constellation memory library note")
        let provider = try SQLiteEngramServiceReadProvider(databasePath: fixture.path)
        let response = try await provider.search(
            EngramServiceSearchRequest(query: "constellation", mode: "keyword", limit: 10)
        )
        XCTAssertEqual(response.items, [])
        XCTAssertEqual(response.insightResults.map(\.id), ["insight-fts"])
        XCTAssertEqual(response.insightResults.first?.matchType, "keyword")
        XCTAssertEqual(response.insightResults.first?.content.contains("constellation"), true)
    }

    func testSupersededInsightIsHiddenFromFTS() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try insertInsight(fixture, id: "insight-old", content: "constellation superseded",
                          supersededBy: "insight-new")
        try insertInsight(fixture, id: "insight-new", content: "unrelated text")
        let provider = try SQLiteEngramServiceReadProvider(databasePath: fixture.path)
        let response = try await provider.search(
            EngramServiceSearchRequest(query: "constellation", mode: "keyword", limit: 10)
        )
        XCTAssertEqual(response.insightResults, [])
    }

    func testSemanticSearchReusesQueryEmbeddingForInsightVectors() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one")
        try seedOrthogonalSessionVector(fixture)
        try insertInsight(fixture, id: "insight-vec", content: "constellation vector note")
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO embedding_meta(id, provider, model, dimension)
                VALUES (1, 'test', 'probe', 3)
                ON CONFLICT(id) DO UPDATE SET model = excluded.model, dimension = excluded.dimension
                """)
            try db.execute(sql: """
                INSERT INTO insight_embeddings(insight_id, embedding, model, dim)
                VALUES (?, ?, 'probe', 3)
                """, arguments: ["insight-vec", VectorMath.encode(VectorMath.l2Normalize([1, 0, 0]))])
        }
        let embeds = InsightEmbedCallCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: fixture.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
                "ENGRAM_EMBEDDING_BASE_URL": "https://engram-ai.test/v1",
            ],
            embeddingProviderFactory: { _ in
                CountingInsightEmbedder(counter: embeds) { _ in [1, 0, 0] }
            }
        )
        let response = try await provider.search(
            EngramServiceSearchRequest(query: "constellation", mode: "semantic", limit: 10)
        )
        let embedCount = await embeds.count()
        XCTAssertEqual(embedCount, 1, "Insights must reuse the session query embedding")
        XCTAssertEqual(response.insightResults.map(\.id), ["insight-vec"])
        XCTAssertEqual(response.insightResults.first?.matchType, "semantic")
        XCTAssertNotNil(response.insightResults.first?.score)
    }

    func testInsightOnlySemanticCorpusUsesSingleQueryEmbedding() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try insertInsight(fixture, id: "insight-only", content: "constellation insight-only vector note")
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO embedding_meta(id, provider, model, dimension)
                VALUES (1, 'test', 'probe', 3)
                ON CONFLICT(id) DO UPDATE SET model = excluded.model, dimension = excluded.dimension
                """)
            try db.execute(sql: """
                INSERT INTO insight_embeddings(insight_id, embedding, model, dim)
                VALUES (?, ?, 'probe', 3)
                """, arguments: ["insight-only", VectorMath.encode(VectorMath.l2Normalize([1, 0, 0]))])
        }
        let embeds = InsightEmbedCallCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: fixture.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
                "ENGRAM_EMBEDDING_BASE_URL": "https://engram-ai.test/v1",
            ],
            embeddingProviderFactory: { _ in
                CountingInsightEmbedder(counter: embeds) { _ in [1, 0, 0] }
            }
        )
        let response = try await provider.search(
            EngramServiceSearchRequest(query: "constellation", mode: "semantic", limit: 10)
        )
        let embedCount = await embeds.count()
        XCTAssertEqual(embedCount, 1)
        XCTAssertEqual(response.items, [])
        XCTAssertEqual(response.searchModes, ["semantic"])
        XCTAssertEqual(response.insightResults.map(\.id), ["insight-only"])
        XCTAssertEqual(response.insightResults.first?.matchType, "semantic")
        XCTAssertNil(response.warningCode)
    }

    func testRestrictiveSessionScopeStillReturnsSemanticInsights() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one")
        try seedOrthogonalSessionVector(fixture)
        try insertInsight(fixture, id: "insight-global", content: "constellation global library note")
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO insight_embeddings(insight_id, embedding, model, dim)
                VALUES (?, ?, 'probe', 3)
                """, arguments: ["insight-global", VectorMath.encode(VectorMath.l2Normalize([1, 0, 0]))])
        }
        let embeds = InsightEmbedCallCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: fixture.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
                "ENGRAM_EMBEDDING_BASE_URL": "https://engram-ai.test/v1",
            ],
            embeddingProviderFactory: { _ in
                CountingInsightEmbedder(counter: embeds) { _ in [1, 0, 0] }
            }
        )
        let response = try await provider.search(
            EngramServiceSearchRequest(query: "constellation", mode: "semantic", limit: 10),
            scope: EngramServiceSearchScope.none
        )
        let embedCount = await embeds.count()
        XCTAssertEqual(embedCount, 1)
        XCTAssertEqual(response.items, [])
        XCTAssertEqual(response.insightResults.map(\.id), ["insight-global"])
        XCTAssertEqual(response.insightResults.first?.matchType, "semantic")
        XCTAssertNil(response.warningCode)
    }

    func testKeywordDoesNotCallEmbeddingProviderForInsights() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try insertInsight(fixture, id: "insight-fts", content: "constellation keyword only")
        let embeds = InsightEmbedCallCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: fixture.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                CountingInsightEmbedder(counter: embeds) { _ in [1, 0, 0] }
            }
        )
        _ = try await provider.search(
            EngramServiceSearchRequest(query: "constellation", mode: "keyword", limit: 10)
        )
        let embedCount = await embeds.count()
        XCTAssertEqual(embedCount, 0)
    }

    private func insertInsight(
        _ fixture: MetadataSQLFixture, id: String, content: String, supersededBy: String? = nil
    ) throws {
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO insights(id, content, source_session_id, superseded_by, importance)
                VALUES (?, ?, NULL, ?, 5)
                """, arguments: [id, content, supersededBy])
            try db.execute(sql: """
                INSERT INTO insights_fts(insight_id, content) VALUES (?, ?)
                """, arguments: [id, content])
        }
    }

    private func seedOrthogonalSessionVector(_ fixture: MetadataSQLFixture) throws {
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO embedding_meta(id, provider, model, dimension)
                VALUES (1, 'test', 'probe', 3)
                ON CONFLICT(id) DO UPDATE SET model = excluded.model, dimension = excluded.dimension
                """)
            try db.execute(sql: """
                INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding, model, dim)
                VALUES ('one:c0', 'one', 0, 'unrelated session chunk', ?, 'probe', 3)
                """, arguments: [VectorMath.encode(VectorMath.l2Normalize([0, 1, 0]))])
        }
    }
}

actor InsightEmbedCallCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

struct CountingInsightEmbedder: EmbeddingProvider {
    let model = "probe"
    let dimension = 3
    let counter: InsightEmbedCallCounter
    let vector: @Sendable (String) -> [Float]

    func embed(_ texts: [String]) async throws -> [[Float]] {
        await counter.increment()
        return texts.map { VectorMath.l2Normalize(vector($0)) }
    }
}
