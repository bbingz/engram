import EngramCoreRead
import Foundation
import XCTest

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class SemanticMemoryUnitTests: XCTestCase {
    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: VectorMath

    func testL2NormalizeProducesUnitVector() {
        let v = VectorMath.l2Normalize([3, 4])
        XCTAssertEqual(VectorMath.dot(v, v), 1, accuracy: 1e-5)
    }

    func testCosineIdentityAndOrthogonality() {
        XCTAssertEqual(VectorMath.cosine([1, 0, 0], [1, 0, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
    }

    func testEncodeDecodeRoundTrip() {
        let v: [Float] = [0.1, -0.5, 0.333, 42, -0.0001]
        let decoded = VectorMath.decode(VectorMath.encode(v))
        XCTAssertEqual(decoded.count, v.count)
        for (a, b) in zip(v, decoded) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    func testDecodeRejectsPartialFloatBlob() {
        var data = VectorMath.encode([1, 2])
        data.append(contentsOf: [0xFF])

        XCTAssertTrue(VectorMath.decode(data).isEmpty)
    }

    func testDecodeExpectedCountRejectsDimensionMismatch() {
        let data = VectorMath.encode([1, 2])

        XCTAssertNil(VectorMath.decode(data, expectedCount: 3))
        XCTAssertEqual(VectorMath.decode(data, expectedCount: 2), [1, 2])
    }

    // MARK: Chunker

    func testChunkerAccumulatesAndSkipsSystem() {
        let chunks = SessionChunker.chunk(
            messages: [
                ("system", "ignore me"),
                ("user", "hello"),
                ("assistant", "hi there"),
            ],
            maxChars: 800
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.contains("[user] hello"))
        XCTAssertTrue(chunks[0].text.contains("[assistant] hi there"))
        XCTAssertFalse(chunks[0].text.contains("ignore me"))
    }

    func testChunkerWindowsOversizedMessage() {
        let big = String(repeating: "x", count: 2000)
        let chunks = SessionChunker.chunk(messages: [("user", big)], maxChars: 800, overlap: 200)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 800 })
        // Indices are contiguous from 0.
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
    }

    // MARK: EmbeddingClient

    func testEmbeddingClientNormalizesAndPreservesOrder() async throws {
        MockURLProtocol.handler = { _ in
            let json = """
            {"data":[
              {"index":1,"embedding":[0,4]},
              {"index":0,"embedding":[3,0]}
            ]}
            """
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/embeddings")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(json.utf8))
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: "k", dimension: 2),
            session: mockSession()
        )
        let vectors = try await client.embed(["a", "b"])
        XCTAssertEqual(vectors.count, 2)
        // Row index 0 = [3,0] → normalized [1,0]; reordered ahead of index 1.
        XCTAssertEqual(vectors[0][0], 1, accuracy: 1e-5)
        XCTAssertEqual(vectors[0][1], 0, accuracy: 1e-5)
        XCTAssertEqual(vectors[1][0], 0, accuracy: 1e-5)
        XCTAssertEqual(vectors[1][1], 1, accuracy: 1e-5)
    }

    func testEmbeddingClientThrowsWhenNotConfigured() async {
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: ""),
            session: mockSession()
        )
        do {
            _ = try await client.embed(["x"])
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .notConfigured)
        }
    }

    // MARK: VectorSearch + RankFusion

    func testKnnRanksByCosineAndCapsTopK() {
        let candidates = [
            VectorSearch.Candidate(id: "north", vector: VectorMath.l2Normalize([1, 0])),
            VectorSearch.Candidate(id: "diag", vector: VectorMath.l2Normalize([1, 1])),
            VectorSearch.Candidate(id: "east", vector: VectorMath.l2Normalize([0, 1])),
        ]
        let hits = VectorSearch.knn(query: VectorMath.l2Normalize([1, 0]), candidates: candidates, topK: 2)
        XCTAssertEqual(hits.map(\.id), ["north", "diag"])
        XCTAssertEqual(hits[0].score, 1, accuracy: 1e-5)
    }

    func testRrfRewardsAgreementAcrossRankings() {
        // k=1: a = 1/2 + 1/4 = 0.75; c = 1/4 + 1/2 = 0.75; b = 1/3 + 1/3 ≈ 0.667.
        // So a and c tie at the top and b (mid in both lists) ends up last.
        let fused = RankFusion.rrf([["a", "b", "c"], ["c", "b", "a"]], k: 1)
        let order = fused.map(\.id)
        XCTAssertEqual(Set(order), ["a", "b", "c"])
        XCTAssertEqual(order.last, "b")
        // Deterministic tie-break: a is seen before c, so a ranks first.
        XCTAssertEqual(order.first, "a")
    }

    func testEmbeddingClientSurfacesHTTPError() async {
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/embeddings")!,
                statusCode: 429, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: "k"),
            session: mockSession()
        )
        do {
            _ = try await client.embed(["x"])
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .http(429))
        }
    }
}
