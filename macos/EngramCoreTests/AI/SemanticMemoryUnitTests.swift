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

private func embeddingRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else {
        throw XCTSkip("embedding request body was unavailable")
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
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

    // PR #197 follow-up: only explicit input-scoped HTTP failures are item-local poison.
    func testEmbeddingClientClassifiesInputScopedHTTPError_repro() async {
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/embeddings")!,
                statusCode: 400, httpVersion: nil, headerFields: nil
            )!
            let json = """
            {"error":{"message":"input exceeds context length","param":"input","code":"context_length_exceeded"}}
            """
            return (response, Data(json.utf8))
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: "k"),
            session: mockSession()
        )
        do {
            _ = try await client.embed(["oversized content"])
            XCTFail("expected input rejection")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .inputRejected("input exceeds context length"))
        }
    }

    func testEmbeddingClientClassifiesBodyOnlyInputLimitErrors_repro() async {
        for status in [400, 413, 422] {
            MockURLProtocol.handler = { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.example.com/v1/embeddings")!,
                    statusCode: status, httpVersion: nil, headerFields: nil
                )!
                let json = #"{"error":{"message":"input token length exceeds provider limit"}}"#
                return (response, Data(json.utf8))
            }
            let client = OpenAICompatibleEmbeddingClient(
                config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: "k"),
                session: mockSession()
            )
            do {
                _ = try await client.embed(["oversized content"])
                XCTFail("expected input rejection for HTTP \(status)")
            } catch {
                XCTAssertEqual(
                    error as? EmbeddingError,
                    .inputRejected("input token length exceeds provider limit")
                )
            }
        }
    }

    func testEmbeddingClientRejectsSuccessfulWrongDimensionVector_repro() async {
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/embeddings")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"data":[{"index":0,"embedding":[1,2]}]}"#.utf8))
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                dimension: 3
            ),
            session: mockSession()
        )
        do {
            _ = try await client.embed(["content"])
            XCTFail("expected dimension mismatch")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .dimensionMismatch(expected: 3, actual: 2))
        }
    }

    // PR #197 follow-up: a server failure stays provider-scoped even if its body names input.
    func testEmbeddingClientKeepsInputTaggedHTTP500AtProviderScope_repro() async {
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/embeddings")!,
                statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            let json = """
            {"error":{"message":"input processing failed","param":"input","code":"server_error"}}
            """
            return (response, Data(json.utf8))
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: "k"),
            session: mockSession()
        )
        do {
            _ = try await client.embed(["content"])
            XCTFail("expected HTTP 500")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .http(500))
        }
    }

    // PR #197 follow-up: model/config HTTP 400 remains provider-scoped and recoverable.
    func testEmbeddingClientKeepsGlobalHTTP400AtProviderScope_repro() async {
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/embeddings")!,
                statusCode: 400, httpVersion: nil, headerFields: nil
            )!
            let json = """
            {"error":{"message":"unsupported dimensions","param":"dimensions","code":"invalid_request_error"}}
            """
            return (response, Data(json.utf8))
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: "k"),
            session: mockSession()
        )
        do {
            _ = try await client.embed(["content"])
            XCTFail("expected HTTP 400")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .http(400))
        }
    }

    func testEmbeddingClientClassifiesSiliconFlowAndFastAPIInputErrors_repro() async {
        let cases: [(Int, String, String)] = [
            (400, #"{"code":40003,"message":"input token length exceeds model limit","data":null}"#,
             "input token length exceeds model limit"),
            (413, #"{"error":"input length exceeds provider limit"}"#,
             "input length exceeds provider limit"),
            (422, #"{"detail":[{"loc":["body","input",0],"msg":"String should have at most 512 characters","type":"string_too_long"}]}"#,
             "String should have at most 512 characters"),
        ]

        for (status, body, expectedMessage) in cases {
            MockURLProtocol.handler = { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.example.com/v1/embeddings")!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data(body.utf8))
            }
            let client = OpenAICompatibleEmbeddingClient(
                config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: "k"),
                session: mockSession()
            )
            do {
                _ = try await client.embed(["oversized content"])
                XCTFail("expected input rejection for HTTP \(status)")
            } catch {
                XCTAssertEqual(error as? EmbeddingError, .inputRejected(expectedMessage))
            }
        }
    }

    func testEmbeddingClientOmitsDimensionsForUnsupportedModel_repro() async throws {
        var requestBody: [String: Any] = [:]
        MockURLProtocol.handler = { request in
            requestBody = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: embeddingRequestBody(request)) as? [String: Any]
            )
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/embeddings")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"data":[{"index":0,"embedding":[1,0]}]}"#.utf8))
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "BAAI/bge-m3",
                dimension: 2
            ),
            session: mockSession()
        )

        _ = try await client.embed(["content"])

        XCTAssertNil(requestBody["dimensions"])
    }

    func testEmbeddingClientSplitsProviderBatchSizeRejection_repro() async throws {
        var batchSizes: [Int] = []
        MockURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: embeddingRequestBody(request)) as? [String: Any]
            )
            let inputs = try XCTUnwrap(body["input"] as? [String])
            batchSizes.append(inputs.count)
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            if inputs.count > 10 {
                return (
                    HTTPURLResponse(url: url, statusCode: 413, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"code":400,"message":"batch size must be less than or equal to 10","data":null}"#.utf8)
                )
            }
            let rows = inputs.indices.map { #"{"index":\#($0),"embedding":[1,0]}"# }
                .joined(separator: ",")
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"data\":[\(rows)]}".utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "BAAI/bge-m3",
                dimension: 2
            ),
            session: mockSession()
        )

        let vectors = try await client.embed((0..<11).map { "text-\($0)" })

        XCTAssertEqual(vectors.count, 11)
        XCTAssertEqual(batchSizes, [11, 5, 6])
    }

    func testEmbeddingClientKeepsBareSiliconFlow20015AtProviderScope_repro() async {
        MockURLProtocol.handler = { _ in
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            return (
                HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"code":20015,"message":"request failed","data":"input text rejected"}"#.utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "BAAI/bge-m3"
            ),
            session: mockSession()
        )

        do {
            _ = try await client.embed(["bad input"])
            XCTFail("expected provider HTTP failure")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .http(400))
        }
    }

    func testEmbeddingClientIsolatesSiliconFlow20015WithInputLimitLanguage_repro() async {
        MockURLProtocol.handler = { _ in
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            return (
                HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"code":20015,"message":"request failed","data":"input length exceeds max_seq_len"}"#.utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "BAAI/bge-m3",
                dimension: 1_536,
                dimensionWasExplicit: true
            ),
            session: mockSession()
        )

        do {
            _ = try await client.embed(["bad input"])
            XCTFail("expected item-local input rejection")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .inputRejected("input length exceeds max_seq_len"))
        }
    }

    func testEmbeddingClientIsolatesExplicitQwenDimension20015InputLimit_repro() async {
        MockURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: embeddingRequestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(body["dimensions"] as? Int, 1_024)
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            return (
                HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"code":20015,"message":"input prompt_tokens exceed max_seq_len","data":null}"#.utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "Qwen/Qwen3-Embedding-0.6B",
                dimension: 1_024,
                dimensionWasExplicit: true
            ),
            session: mockSession()
        )

        do {
            _ = try await client.embed(["bad input"])
            XCTFail("expected item-local input rejection")
        } catch {
            XCTAssertEqual(
                error as? EmbeddingError,
                .inputRejected("input prompt_tokens exceed max_seq_len")
            )
        }
    }

    func testEmbeddingClientSplitsBareProviderCodeBeforeClassifyingSingleInput_repro() async {
        var batchSizes: [Int] = []
        MockURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: embeddingRequestBody(request)) as? [String: Any]
            )
            let inputs = try XCTUnwrap(body["input"] as? [String])
            batchSizes.append(inputs.count)
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            return (
                HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"code":20018,"message":"parameter is invalid"}"#.utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: "k", model: "BAAI/bge-m3"),
            session: mockSession()
        )

        do {
            _ = try await client.embed(["one", "two"])
            XCTFail("expected provider HTTP failure")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .http(400))
        }
        XCTAssertEqual(batchSizes, [2, 1])
    }

    func testEmbeddingClientOmitsImplicitDimensionsForQwen3Embedding_repro() async throws {
        var requestBody: [String: Any] = [:]
        MockURLProtocol.handler = { request in
            requestBody = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: embeddingRequestBody(request)) as? [String: Any]
            )
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/embeddings")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"data":[{"index":0,"embedding":[1,0]}]}"#.utf8))
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "Qwen/Qwen3-Embedding-0.6B",
                dimension: 2,
                dimensionWasExplicit: false
            ),
            session: mockSession()
        )

        _ = try await client.embed(["content"])

        XCTAssertNil(requestBody["dimensions"])
        XCTAssertEqual(client.dimension, 2)
    }

    func testEmbeddingClientRetriesWithoutDimensionsAfterFastAPIExtraForbidden_repro() async throws {
        var requestBodies: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: embeddingRequestBody(request)) as? [String: Any]
            )
            requestBodies.append(body)
            let responseURL = URL(string: "https://api.example.com/v1/embeddings")!
            if requestBodies.count == 1 {
                return (
                    HTTPURLResponse(url: responseURL, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"detail":[{"loc":["body","dimensions"],"msg":"Extra inputs are not permitted","type":"extra_forbidden"}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":[{"index":0,"embedding":[1,0,0]}]}"#.utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "Qwen/Qwen3-Embedding-0.6B",
                dimension: 1_024,
                dimensionWasExplicit: true
            ),
            session: mockSession()
        )

        let vectors = try await client.embed(["content"])

        XCTAssertEqual(vectors.first?.count, 3)
        XCTAssertEqual(requestBodies.count, 2)
        XCTAssertEqual(requestBodies[0]["dimensions"] as? Int, 1_024)
        XCTAssertNil(requestBodies[1]["dimensions"])
        XCTAssertEqual(client.dimension, 3)
    }

    func testEmbeddingClientRetriesAndStaysOmittedForLiveDimensionErrors_repro() async throws {
        let failures = [
            #"{"message":"dimensions is currently not supported","param":null}"#,
            #"{"code":20015,"message":"The parameter is invalid.","data":null}"#,
        ]

        for failure in failures {
            var requestBodies: [[String: Any]] = []
            MockURLProtocol.handler = { request in
                let body = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: embeddingRequestBody(request)) as? [String: Any]
                )
                requestBodies.append(body)
                let url = URL(string: "https://api.example.com/v1/embeddings")!
                if requestBodies.count == 1 {
                    return (
                        HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        Data(failure.utf8)
                    )
                }
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":[{"index":0,"embedding":[1,0,0]}]}"#.utf8)
                )
            }
            let client = OpenAICompatibleEmbeddingClient(
                config: EmbeddingConfig(
                    baseURL: "https://api.example.com/v1",
                    apiKey: "k",
                    dimension: 1_024,
                    dimensionWasExplicit: true
                ),
                session: mockSession()
            )

            _ = try await client.embed(["first"])
            _ = try await client.embed(["second"])

            XCTAssertEqual(requestBodies.count, 3)
            XCTAssertEqual(requestBodies[0]["dimensions"] as? Int, 1_024)
            XCTAssertNil(requestBodies[1]["dimensions"])
            XCTAssertNil(requestBodies[2]["dimensions"], "successful omit-retry must stay sticky")
            XCTAssertEqual(client.dimension, 3)
        }
    }

    func testEmbeddingClientPreservesObjectDetailFields_repro() async {
        MockURLProtocol.handler = { _ in
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            return (
                HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(#"{"detail":{"message":"request failed","param":"input","type":"value_error","data":"input length exceeds max_seq_len"}}"#.utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "BAAI/bge-m3"
            ),
            session: mockSession()
        )

        do {
            _ = try await client.embed(["oversized"])
            XCTFail("expected object-detail input rejection")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .inputRejected("input length exceeds max_seq_len"))
        }
    }

    func testEmbeddingClientKeepsObjectDetailDimensionFailureProviderScoped_repro() async {
        var requestBodies: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            requestBodies.append(try XCTUnwrap(
                try JSONSerialization.jsonObject(with: embeddingRequestBody(request)) as? [String: Any]
            ))
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            return (
                HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(#"{"detail":{"message":"invalid request","param":"dimensions","type":"value_error","data":"dimension is invalid"}}"#.utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                dimension: 1_024,
                dimensionWasExplicit: true
            ),
            session: mockSession()
        )

        do {
            _ = try await client.embed(["content"])
            XCTFail("expected provider-scoped failure")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .http(422))
        }
        XCTAssertEqual(requestBodies.count, 2)
        XCTAssertEqual(requestBodies[0]["dimensions"] as? Int, 1_024)
        XCTAssertNil(requestBodies[1]["dimensions"])
    }

    func testEmbeddingClientKeepsFastAPIModelAndDimensionValidationAtProviderScope_repro() async {
        let cases = [
            #"{"detail":[{"loc":["body","dimensions"],"msg":"Input should be a valid integer","type":"int_parsing"}]}"#,
            #"{"detail":[{"loc":["body","model"],"msg":"Input should be a valid string","type":"string_type"}]}"#,
            #"{"detail":[{"loc":["body","unknown"],"msg":"Input should be a valid integer","type":"int_parsing"}]}"#,
        ]

        for body in cases {
            MockURLProtocol.handler = { _ in
                let url = URL(string: "https://api.example.com/v1/embeddings")!
                return (
                    HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8)
                )
            }
            let client = OpenAICompatibleEmbeddingClient(
                config: EmbeddingConfig(
                    baseURL: "https://api.example.com/v1",
                    apiKey: "k",
                    dimension: 1_024,
                    dimensionWasExplicit: true
                ),
                session: mockSession()
            )

            do {
                _ = try await client.embed(["content"])
                XCTFail("expected provider-scoped HTTP 422")
            } catch {
                XCTAssertEqual(error as? EmbeddingError, .http(422))
            }
        }
    }

    func testEmbeddingClientParsesStringDetailInputError_repro() async {
        MockURLProtocol.handler = { _ in
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            return (
                HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"detail":"input text is too long"}"#.utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(baseURL: "https://api.example.com/v1", apiKey: "k"),
            session: mockSession()
        )

        do {
            _ = try await client.embed(["bad input"])
            XCTFail("expected input rejection")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .inputRejected("input text is too long"))
        }
    }

    func testEmbeddingClientSplitsFastAPI422ListCardinality_repro() async throws {
        var batchSizes: [Int] = []
        MockURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: embeddingRequestBody(request)) as? [String: Any]
            )
            let inputs = try XCTUnwrap(body["input"] as? [String])
            batchSizes.append(inputs.count)
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            if inputs.count > 1 {
                return (
                    HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"detail":[{"loc":["body","input"],"msg":"List should have at most 1 item","type":"too_long"}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":[{"index":0,"embedding":[1,0]}]}"#.utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "BAAI/bge-m3",
                dimension: 2
            ),
            session: mockSession()
        )

        let vectors = try await client.embed(["one", "two"])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(batchSizes, [2, 1, 1])
    }

    func testEmbeddingClientAdoptsOmittedDimensionsResponseForBGE_repro() async throws {
        let embedding = Array(repeating: "1", count: 1024).joined(separator: ",")
        MockURLProtocol.handler = { _ in
            let url = URL(string: "https://api.example.com/v1/embeddings")!
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"data\":[{\"index\":0,\"embedding\":[\(embedding)]}]}".utf8)
            )
        }
        let client = OpenAICompatibleEmbeddingClient(
            config: EmbeddingConfig(
                baseURL: "https://api.example.com/v1",
                apiKey: "k",
                model: "BAAI/bge-m3"
            ),
            session: mockSession()
        )

        let vectors = try await client.embed(["content"])
        XCTAssertEqual(vectors.first?.count, 1024)
        XCTAssertEqual(client.dimension, 1024)
    }
}
