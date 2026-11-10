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

    func testIt9B4ListAdmissionStablePagingAndLiveRevision() async throws {
        let fixture = try seeded(); defer { fixture.remove() }
        try fixture.seedBoundSession(id: "hidden", start: nil, nativeID: "hidden", hidden: true)
        try fixture.seedBoundSession(id: "skip", start: nil, nativeID: "skip", tier: "skip")
        try fixture.seedLocalSession(id: "unbound")
        for (id, source) in [("a", nil), ("b", "one"), ("c", nil), ("h", "hidden"), ("k", "skip"), ("u", "unbound"), ("empty", "")] as [(String, String?)] {
            try insertInsight(fixture, id: id, content: "note " + id + String(repeating: "😀", count: 700), session: source)
        }
        try insertInsight(fixture, id: "old", content: "old note", session: nil, supersededBy: "a")
        try fixture.write { try $0.execute(sql: "UPDATE insights SET created_at = '2026-11-10 10:00:00'") }
        let producer = try fixture.producer(); defer { try? producer.stop() }
        let first = try await producer.insights(.init(limit: 2), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.id), ["a", "b"])
        XCTAssertEqual(first.items[0].content.unicodeScalars.count, 600)
        XCTAssertEqual(first.items[1].sourceSessionId, "one")
        try insertInsight(fixture, id: "new", content: "new note", session: nil)
        let next = try await producer.insights(.init(limit: 2, snapshotId: first.snapshotId, cursor: first.nextCursor), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(next.items.map(\.id), ["c"]); XCTAssertNil(next.nextCursor)
        do { _ = try await producer.insights(.init(limit: 3, snapshotId: first.snapshotId, cursor: first.nextCursor), requestId: requestID, deadline: fixture.deadline()); XCTFail("crosswired limit") } catch { }
        let detail = try await producer.insightDetail(.init(id: "a"), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(first.items[0].revision, detail.revision)
        try fixture.write { try $0.execute(sql: "UPDATE insights SET content = content || 'changed' WHERE id='a'") }
        do { _ = try await producer.insightDetail(.init(id: "a", revision: first.items[0].revision), requestId: requestID, deadline: fixture.deadline()); XCTFail("old revision") } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .stale) }
    }

    func testIt9B4ListLiveRechecksPreviewTailLinkageAndRegistry() async throws {
        for sql in ["UPDATE insights SET content = content || 'tail changed' WHERE id='a'", "UPDATE insights SET superseded_by = 'new' WHERE id='a'", "UPDATE sessions SET hidden_at = 'now' WHERE id='one'", "UPDATE capture_ingest_source_registry SET configured_root = '/invalid-changed-root'"] {
            let fixture = try seeded(); defer { fixture.remove() }
            try insertInsight(fixture, id: "a", content: String(repeating: "x", count: 800), session: "one")
            let producer = try fixture.producer(hooks: .init(afterPreparation: { op in
                if op == .insights { try fixture.write { try $0.execute(sql: sql) } }
            })); defer { try? producer.stop() }
            do { _ = try await producer.insights(.init(), requestId: requestID, deadline: fixture.deadline()); XCTFail("published stale: " + sql) }
            catch { XCTAssertEqual(error as? ServiceWebMetadataError, .stale) }
        }
    }

    func testIt9B4EmptyGlobalRedactionAndPageIDBatchBound() async throws {
        let fixture = try seeded(); defer { fixture.remove() }
        try fixture.seedBoundSession(id: "agent", start: nil, nativeID: "agent")
        try fixture.seedBoundSession(id: "disabled", start: nil, nativeID: "disabled", source: .codex)
        for (id, source) in [("agent-note", "agent"), ("disabled-note", "disabled")] { try insertInsight(fixture, id: id, content: "must be excluded", session: source) }
        try fixture.write { try $0.execute(sql: "UPDATE sessions SET agent_role = 'subagent' WHERE id = 'agent'") }
        let trace = B4ListTrace()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { db in
            db.trace(options: .statement) { if case .statement(let statement) = $0 { trace.record(statement.sql) } }
        }), policy: { .init(parserRevision: "parser-v1", enabledSources: [.claudeCode]) }); defer { try? producer.stop() }
        let empty = try await producer.insights(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertTrue(empty.items.isEmpty); XCTAssertNil(empty.nextCursor)
        for n in 0..<30 { try insertInsight(fixture, id: "note-\(n)", content: "Bearer sk-abcdefghijklmnopqrstuvwxyz1234567890 " + String(repeating: "😀", count: 700), session: n == 0 ? nil : "one") }
        trace.reset()
        let one = try await producer.insights(.init(limit: 5), requestId: requestID, deadline: fixture.deadline())
        let small = trace.count
        trace.reset()
        let many = try await producer.insights(.init(limit: 25), requestId: requestID, deadline: fixture.deadline())
        XCTAssertLessThanOrEqual(trace.count, small + 2, "List/admission must batch page IDs, not read once per note")
        XCTAssertEqual(many.items.count, 25); XCTAssertNotNil(many.nextCursor)
        XCTAssertFalse(one.items[0].content.contains("sk-abcdefghijklmnopqrstuvwxyz1234567890"))
    }

    func testIt9B4NullDatesKeepSQLNullLastOrderAcrossPages() async throws {
        let fixture = try seeded(); defer { fixture.remove() }
        for id in ["a", "b"] { try insertInsight(fixture, id: id, content: "global " + id, session: nil) }
        try fixture.write { try $0.execute(sql: "UPDATE insights SET created_at = CASE id WHEN 'a' THEN NULL ELSE '' END") }
        let producer = try fixture.producer(); defer { try? producer.stop() }
        let first = try await producer.insights(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.id), ["b"]); XCTAssertNil(first.items.first?.createdAt)
        let last = try await producer.insights(.init(limit: 1, snapshotId: first.snapshotId, cursor: first.nextCursor), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(last.items.map(\.id), ["a"]); XCTAssertNil(last.nextCursor)
    }

    func testIt9B4ListNeverTruncatesStoredIdentityAtNUL() async throws {
        let fixture = try seeded(); defer { fixture.remove() }
        try insertInsight(fixture, id: "a", content: "note with invalid identity", session: nil)
        try fixture.write { try $0.execute(sql: "UPDATE insights SET id = CAST(X'610062' AS TEXT)") }
        let producer = try fixture.producer(); defer { try? producer.stop() }
        do { _ = try await producer.insights(.init(), requestId: requestID, deadline: fixture.deadline()); XCTFail("must not publish a truncated identity") } catch { }
    }

    func testIt9B4ListNeverAliasesStoredSourceAtNUL() async throws {
        let fixture = try seeded(); defer { fixture.remove() }
        try fixture.seedBoundSession(id: "malformed", start: nil, nativeID: "malformed")
        try insertInsight(fixture, id: "bad-note", content: "note with corrupt source", session: "malformed")
        try fixture.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for sql in ["UPDATE capture_ingest_generations SET stored_session_id=CAST(X'6f6e650078' AS TEXT) WHERE stored_session_id='malformed'", "UPDATE sessions SET id=CAST(X'6f6e650078' AS TEXT) WHERE id='malformed'", "UPDATE capture_ingest_identity_bindings SET stored_session_id=CAST(X'6f6e650078' AS TEXT) WHERE stored_session_id='malformed'", "UPDATE insights SET source_session_id=CAST(X'6f6e650078' AS TEXT)"] { try db.execute(sql: sql) }
        }
        let producer = try fixture.producer(); defer { try? producer.stop() }
        let list = try await producer.insights(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertTrue(list.items.isEmpty, "Never alias a corrupt source to the unrelated admitted session one")
    }

    func testIt9B4ListBoundsRawContentAndResponseEnvelope() async throws {
        let fixture = try seeded(); defer { fixture.remove() }
        for index in 0..<101 { try insertInsight(fixture, id: String(format: "note-%03d", index), content: String(repeating: "😀", count: 700), session: nil) }
        try fixture.write { try $0.execute(sql: "UPDATE insights SET created_at = '2026-11-10 00:00:00'") }
        let producer = try fixture.producer(); defer { try? producer.stop() }
        var cursor: String?, snapshot: String?, ids: [String] = []
        repeat {
            let page = try await producer.insights(.init(limit: 100, snapshotId: snapshot, cursor: cursor), requestId: requestID, deadline: fixture.deadline())
            let frame = try EngramServiceResponseEnvelope.success(requestId: requestID, result: JSONEncoder().encode(page))
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(frame).count, EngramServiceWebReadLimits.maximumFrameBytes)
            XCTAssertTrue(page.items.allSatisfy { $0.content.unicodeScalars.count == 600 })
            ids += page.items.map(\.id); cursor = page.nextCursor; snapshot = cursor == nil ? nil : page.snapshotId
        } while cursor != nil
        XCTAssertEqual(ids.count, 101); XCTAssertEqual(Set(ids).count, 101)
        try fixture.write { try $0.execute(sql: "UPDATE insights SET content = ? WHERE id='note-000'", arguments: [String(repeating: "x", count: 1_048_577)]) }
        do { _ = try await producer.insights(.init(limit: 1), requestId: requestID, deadline: fixture.deadline()); XCTFail("Oversized raw note must be unavailable, not an unbounded read") }
        catch { XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable) }
    }

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

private final class B4ListTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ sql: String) { lock.lock(); defer { lock.unlock() }; value += 1 }
    func reset() { lock.lock(); defer { lock.unlock() }; value = 0 }
}
