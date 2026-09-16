import Foundation
import GRDB
import XCTest
import EngramCoreRead
import EngramCoreWrite
@testable import EngramServiceCore

final class WebSearchInsightProducerTests: XCTestCase {
    private let requestID = "AAAAAAAA-0000-4000-8000-000000000211"
    private let globalID = "insight-global"
    private let linkedID = "insight-linked"
    private let hiddenID = "insight-hidden"
    private let unboundID = "insight-unbound"
    private let skipID = "insight-skip"
    private let supersededID = "insight-old"

    func testGlobalNoteSurvivesEmptySessionHits() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try insertInsight(fixture, id: globalID, content: "library note about constellation", session: nil)
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let ranked = EngramServiceSearchResponse(
            items: [],
            searchModes: ["keyword"],
            insightResults: [
                .init(id: globalID, content: "stale ranked preview",
                      sourceSessionId: "one", matchType: "keyword"),
            ]
        )
        let page = try await producer.admitSearch(
            try EngramServiceWebSearchRequest(query: "constellation"),
            ranked: ranked, requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.items, [])
        XCTAssertEqual(page.insightResults.map(\.id), [globalID])
        XCTAssertNil(page.insightResults.first?.sourceSessionId)
        XCTAssertEqual(page.insightResults.first?.matchType, "keyword")
        XCTAssertEqual(page.insightResults.first?.content, "library note about constellation")
    }

    func testHiddenSkipUnboundAndDisabledSourceSessionsAreOmitted() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try fixture.seedBoundSession(id: "hidden", start: "2026-09-01 12:00:00",
                                     nativeID: "native-hidden", hidden: true)
        try fixture.seedBoundSession(id: "skip", start: "2026-09-01 12:00:00",
                                     nativeID: "native-skip", tier: "skip")
        try fixture.seedLocalSession(id: "unbound")
        try fixture.seedBoundSession(id: "codex-only", start: "2026-09-01 12:00:00",
                                     nativeID: "native-codex", source: .codex)
        try insertInsight(fixture, id: linkedID, content: "visible constellation note", session: "one")
        try insertInsight(fixture, id: hiddenID, content: "hidden constellation note", session: "hidden")
        try insertInsight(fixture, id: skipID, content: "skip constellation note", session: "skip")
        try insertInsight(fixture, id: unboundID, content: "unbound constellation note", session: "unbound")
        try insertInsight(fixture, id: "insight-disabled", content: "disabled source constellation",
                          session: "codex-only")
        try insertInsight(fixture, id: globalID, content: "global constellation note", session: nil)
        try insertInsight(fixture, id: "insight-empty", content: "empty linkage constellation", session: "")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let ranked = EngramServiceSearchResponse(
            items: [],
            insightResults: [
                .init(id: linkedID, content: "stale visible", sourceSessionId: nil, matchType: "keyword"),
                .init(id: hiddenID, content: "stale hidden", sourceSessionId: nil, matchType: "keyword"),
                .init(id: skipID, content: "stale skip", sourceSessionId: nil, matchType: "keyword"),
                .init(id: unboundID, content: "stale unbound", sourceSessionId: nil, matchType: "keyword"),
                .init(id: "insight-disabled", content: "stale disabled",
                      sourceSessionId: nil, matchType: "keyword"),
                .init(id: globalID, content: "stale global", sourceSessionId: "hidden",
                      matchType: "semantic", score: 0.9),
                .init(id: "insight-empty", content: "stale empty", sourceSessionId: nil, matchType: "keyword"),
            ]
        )
        let page = try await producer.admitSearch(
            try EngramServiceWebSearchRequest(query: "constellation"),
            ranked: ranked, requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(Set(page.insightResults.map(\.id)), [linkedID, globalID])
        XCTAssertEqual(page.insightResults.first { $0.id == linkedID }?.sourceSessionId, "one")
        XCTAssertEqual(page.insightResults.first { $0.id == globalID }?.matchType, "semantic")
    }

    func testPreviewRedactsAndCapsUnicodeScalars() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let long = String(repeating: "é", count: 620) + " Bearer sk-secret"
        try insertInsight(fixture, id: globalID, content: long, session: nil)
        let page = try await producer.admitSearch(
            try EngramServiceWebSearchRequest(query: "constellation"),
            ranked: .init(items: [], insightResults: [
                .init(id: globalID, content: "stale ranked secret Bearer sk-secret", matchType: "keyword"),
            ]),
            requestId: requestID, deadline: fixture.deadline())
        let preview = try XCTUnwrap(page.insightResults.first?.content)
        XCTAssertEqual(preview.unicodeScalars.count, 600)
        XCTAssertFalse(preview.contains("sk-secret"))
    }

    func testInsightDetailPagesLongUnicodeAndRejectsStaleRevision() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        let body = String(repeating: "😀", count: 9000)
        try insertInsight(fixture, id: globalID, content: body, session: nil)
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.insightDetail(
            try EngramServiceWebInsightDetailRequest(id: globalID, limit: 8000),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(first.totalLength, 9000)
        XCTAssertEqual(first.content.unicodeScalars.count, 8000)
        XCTAssertEqual(first.offset, 0)
        XCTAssertEqual(first.nextOffset, 8000)
        XCTAssertNil(first.sourceSessionId)
        let continued = try await producer.insightDetail(
            try EngramServiceWebInsightDetailRequest(
                id: globalID, offset: 8000, limit: 8000, revision: first.revision),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(continued.content.unicodeScalars.count, 1000)
        XCTAssertNil(continued.nextOffset)
        XCTAssertEqual(continued.revision, first.revision)
        try fixture.write { db in
            try db.execute(sql: "UPDATE insights SET content = ? WHERE id = ?",
                           arguments: [body + "changed", globalID])
        }
        do {
            _ = try await producer.insightDetail(
                try EngramServiceWebInsightDetailRequest(
                    id: globalID, offset: 8000, limit: 8000, revision: first.revision),
                requestId: requestID, deadline: fixture.deadline())
            XCTFail("Changed body must reject the previous revision")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .stale)
        }
    }

    func testAdmitSearchRejectsStalePreviewAfterPreparationChange() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try insertInsight(fixture, id: globalID, content: "original constellation preview", session: nil)
        let producer = try fixture.producer(hooks: .init(afterPreparation: { operation in
            guard operation == .search else { return }
            try fixture.write { db in
                try db.execute(sql: """
                    UPDATE insights SET content = ?, superseded_by = ? WHERE id = ?
                    """, arguments: ["changed constellation preview", self.linkedID, self.globalID])
            }
        }))
        defer { try? producer.stop() }
        do {
            _ = try await producer.admitSearch(
                try EngramServiceWebSearchRequest(query: "constellation"),
                ranked: .init(items: [], insightResults: [
                    .init(id: globalID, content: "original constellation preview", matchType: "keyword"),
                ]),
                requestId: requestID, deadline: fixture.deadline())
            XCTFail("Changed or superseded insight must not publish the prepared preview")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .stale)
        }
    }

    func testInsightDetailHiddenSourceIsNotFound() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try insertInsight(fixture, id: linkedID, content: "linked constellation", session: "one")
        let producer = try fixture.producer(hooks: .init(afterPreparation: { operation in
            guard operation == .insightDetail else { return }
            try fixture.hide("one")
        }))
        defer { try? producer.stop() }
        do {
            _ = try await producer.insightDetail(
                try EngramServiceWebInsightDetailRequest(id: linkedID),
                requestId: requestID, deadline: fixture.deadline())
            XCTFail("Revoked source session must not leak the insight")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .notFound)
        }
    }

    func testInsightOnlyStatusAndSearchAdvertiseSemanticCorpus() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try fixture.seedEmbeddingMeta(model: "probe")
        try insertInsight(fixture, id: globalID, content: "constellation insight-only library note", session: nil)
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO insight_embeddings(insight_id, embedding, model, dim)
                VALUES (?, ?, 'probe', 3)
                """, arguments: [globalID, VectorMath.encode(VectorMath.l2Normalize([1, 0, 0]))])
        }
        let env = isolatedEmbeddingEnv(apiKey: "test")
        let producer = try fixture.producer(embeddingEnvironment: env)
        defer { try? producer.stop() }
        let status = try await producer.searchStatus(
            try EngramServiceWebSearchStatusRequest(),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(status.keyword, .available)
        XCTAssertEqual(status.semantic, .available)
        XCTAssertEqual(status.hybrid, .available)
        XCTAssertNil(status.warningCode)
        let embeds = InsightEmbedCallCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: fixture.path, embeddingEnvironment: env,
            embeddingProviderFactory: { _ in
                CountingInsightEmbedder(counter: embeds) { _ in [1, 0, 0] }
            })
        let page = try await performSearch(
            producer: producer, provider: provider, fixture: fixture,
            request: try EngramServiceWebSearchRequest(query: "constellation", mode: .semantic))
        let embedCount = await embeds.count()
        XCTAssertEqual(embedCount, 1)
        XCTAssertEqual(page.items, [])
        XCTAssertEqual(page.insightResults.map(\.id), [globalID])
        XCTAssertEqual(page.insightResults.first?.matchType, "semantic")
        XCTAssertEqual(page.searchModes, ["semantic"])
    }

    func testRestrictiveProjectFilterKeepsAdmittedInsightVectors() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try fixture.seedEmbeddingMeta(model: "probe")
        try fixture.seedSemanticChunk(sessionID: "one", model: "probe", vector: [0, 1, 0],
                                      text: "unrelated session chunk")
        try insertInsight(fixture, id: globalID, content: "constellation global library note", session: nil)
        try insertInsight(fixture, id: hiddenID, content: "hidden constellation note", session: "hidden")
        try fixture.seedBoundSession(id: "hidden", start: "2026-09-01 12:00:00",
                                     nativeID: "native-hidden", hidden: true)
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO insight_embeddings(insight_id, embedding, model, dim)
                VALUES (?, ?, 'probe', 3), (?, ?, 'probe', 3)
                """, arguments: [
                    globalID, VectorMath.encode(VectorMath.l2Normalize([1, 0, 0])),
                    hiddenID, VectorMath.encode(VectorMath.l2Normalize([1, 0, 0])),
                ])
        }
        let env = isolatedEmbeddingEnv(apiKey: "test")
        let producer = try fixture.producer(embeddingEnvironment: env)
        defer { try? producer.stop() }
        let missingProject = "p." + ArchiveV2Hash.sha256(Data("missing-project".utf8))
        let status = try await producer.searchStatus(
            try EngramServiceWebSearchStatusRequest(projectKey: missingProject),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(status.semantic, .available)
        XCTAssertEqual(status.hybrid, .available)
        XCTAssertEqual(status.eligibleSessionCount, 0)
        XCTAssertEqual(status.embeddedSessionCount, 0)
        let embeds = InsightEmbedCallCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: fixture.path, embeddingEnvironment: env,
            embeddingProviderFactory: { _ in
                CountingInsightEmbedder(counter: embeds) { _ in [1, 0, 0] }
            })
        let page = try await performSearch(
            producer: producer, provider: provider, fixture: fixture,
            request: try EngramServiceWebSearchRequest(
                query: "constellation", projectKey: missingProject, mode: .semantic))
        let embedCount = await embeds.count()
        XCTAssertEqual(embedCount, 1)
        XCTAssertEqual(page.items, [])
        XCTAssertEqual(page.insightResults.map(\.id), [globalID])
        XCTAssertNil(page.insightResults.first?.sourceSessionId)
        XCTAssertEqual(page.insightResults.first?.matchType, "semantic")
    }

    func testHiddenSourceInsightVectorsDoNotAdvertiseSemanticCorpus() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try fixture.seedBoundSession(id: "hidden", start: "2026-09-01 12:00:00",
                                     nativeID: "native-hidden", hidden: true)
        try fixture.seedEmbeddingMeta(model: "probe")
        try insertInsight(fixture, id: hiddenID, content: "hidden constellation note", session: "hidden")
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO insight_embeddings(insight_id, embedding, model, dim)
                VALUES (?, ?, 'probe', 3)
                """, arguments: [hiddenID, VectorMath.encode(VectorMath.l2Normalize([1, 0, 0]))])
        }
        let producer = try fixture.producer(embeddingEnvironment: isolatedEmbeddingEnv(apiKey: "test"))
        defer { try? producer.stop() }
        let status = try await producer.searchStatus(
            try EngramServiceWebSearchStatusRequest(),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(status.semantic, .unavailable)
        XCTAssertEqual(status.warningCode, "embeddingCorpusMissing")
    }

    func testMissingAndSupersededInsightsAreNotFound() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try insertInsight(fixture, id: supersededID, content: "old constellation", session: nil,
                          supersededBy: linkedID)
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        do {
            _ = try await producer.insightDetail(
                try EngramServiceWebInsightDetailRequest(id: "missing-insight"),
                requestId: requestID, deadline: fixture.deadline())
            XCTFail("Missing insight must be notFound")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .notFound)
        }
        do {
            _ = try await producer.insightDetail(
                try EngramServiceWebInsightDetailRequest(id: supersededID),
                requestId: requestID, deadline: fixture.deadline())
            XCTFail("Superseded insight must be notFound")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .notFound)
        }
    }

    private func seeded() throws -> MetadataSQLFixture {
        let fixture = try MetadataSQLFixture()
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one")
        return fixture
    }

    private func isolatedEmbeddingEnv(apiKey: String? = nil, model: String = "probe", dim: String = "3") -> [String: String] {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-d11-embed-\(UUID().uuidString)").path
        var env = [
            "HOME": home,
            "CFFIXED_USER_HOME": home,
            "ENGRAM_SETTINGS_PATH": home + "/missing-settings.json",
            "ENGRAM_EMBEDDING_MODEL": model,
            "ENGRAM_EMBEDDING_DIM": dim,
            "ENGRAM_EMBEDDING_BASE_URL": "https://engram-ai.test/v1",
        ]
        if let apiKey { env["ENGRAM_EMBEDDING_API_KEY"] = apiKey }
        return env
    }

    private func performSearch(
        producer: ServiceWebMetadataProducer,
        provider: SQLiteEngramServiceReadProvider,
        fixture: MetadataSQLFixture,
        request: EngramServiceWebSearchRequest
    ) async throws -> EngramServiceWebSearchResponse {
        let deadline = fixture.deadline()
        let scope = try await producer.searchScope(request, requestId: requestID, deadline: deadline)
        let ranked = try await provider.search(
            EngramServiceSearchRequest(query: request.query, mode: request.mode.rawValue, limit: request.limit),
            scope: scope
        )
        return try await producer.admitSearch(request, ranked: ranked, requestId: requestID, deadline: deadline)
    }

    private func insertInsight(
        _ fixture: MetadataSQLFixture, id: String, content: String,
        session: String?, supersededBy: String? = nil
    ) throws {
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO insights(id, content, source_session_id, superseded_by, importance)
                VALUES (?, ?, ?, ?, 5)
                """, arguments: [id, content, session, supersededBy])
            try db.execute(sql: """
                INSERT INTO insights_fts(insight_id, content) VALUES (?, ?)
                """, arguments: [id, content])
        }
    }
}
