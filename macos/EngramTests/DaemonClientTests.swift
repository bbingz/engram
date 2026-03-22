// macos/EngramTests/DaemonClientTests.swift
import XCTest
@testable import Engram

@MainActor
final class DaemonClientTests: XCTestCase {

    private var mockSession: URLSession!
    private var client: DaemonClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        mockSession = createMockSession()
        client = DaemonClient(port: 9999, session: mockSession)
    }

    override func tearDownWithError() throws {
        MockURLProtocol.requestHandler = nil
        client = nil
        mockSession = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - Tests

    /// 1. fetch sends GET request with X-Trace-Id header
    func testFetchSendsGETWithTraceId() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Trace-Id"))
            let body = try! JSONEncoder().encode(["name": "test"])
            return (self.makeResponse(url: request.url!), body)
        }

        struct Response: Decodable { let name: String }
        let result: Response = try await client.fetch("/api/test")
        XCTAssertEqual(result.name, "test")
    }

    /// 2. post sends correct Content-Type and method
    func testPostSendsCorrectContentType() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Trace-Id"))
            let body = try! JSONEncoder().encode(["ok": true])
            return (self.makeResponse(url: request.url!), body)
        }

        struct Req: Encodable { let data: String }
        struct Resp: Decodable { let ok: Bool }
        let result: Resp = try await client.post("/api/action", body: Req(data: "hello"))
        XCTAssertTrue(result.ok)
    }

    /// 3. HTTP 404 throws DaemonClientError.httpError
    func testHTTP404Throws() async throws {
        MockURLProtocol.requestHandler = { request in
            return (self.makeResponse(url: request.url!, statusCode: 404), nil)
        }

        struct Response: Decodable { let name: String }
        do {
            let _: Response = try await client.fetch("/api/missing")
            XCTFail("Should have thrown")
        } catch let error as DaemonClient.DaemonClientError {
            if case .httpError(let code) = error {
                XCTAssertEqual(code, 404)
            } else {
                XCTFail("Expected httpError")
            }
        }
    }

    /// 4. Network error propagates as thrown error
    func testNetworkErrorThrows() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        struct Response: Decodable { let name: String }
        do {
            let _: Response = try await client.fetch("/api/test")
            XCTFail("Should have thrown")
        } catch {
            // URLError should propagate
            XCTAssertTrue(error is URLError)
        }
    }

    /// 5. Response parsing with nested types
    func testResponseParsing() async throws {
        let responseJSON = """
            {"sessions":[{"source":"claude-code","sessionId":"s1","filePath":"/tmp/s.jsonl","lastModifiedAt":"2026-03-20"}],"count":1}
        """
        MockURLProtocol.requestHandler = { request in
            return (self.makeResponse(url: request.url!), responseJSON.data(using: .utf8))
        }

        let result: LiveSessionsResponse = try await client.fetch("/api/live")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].source, "claude-code")
    }

    /// 6. delete sends DELETE method with X-Trace-Id
    func testDeleteSendsDeleteMethod() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Trace-Id"))
            return (self.makeResponse(url: request.url!), nil)
        }

        try await client.delete("/api/sessions/123")
    }

    /// 7. Custom port appears in URL
    func testCustomPortInURL() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.port, 9999)
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            let body = try! JSONEncoder().encode(["ok": true])
            return (self.makeResponse(url: request.url!), body)
        }

        struct Resp: Decodable { let ok: Bool }
        let _: Resp = try await client.fetch("/api/ping")
    }

    /// 8. Empty response body with postRaw succeeds
    func testEmptyResponseBody() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (self.makeResponse(url: request.url!), nil)
        }

        // postRaw discards response body, should not throw
        try await client.postRaw("/api/action")
    }

    /// 9. HTTP 500 throws httpError
    func testHTTP500Throws() async throws {
        MockURLProtocol.requestHandler = { request in
            return (self.makeResponse(url: request.url!, statusCode: 500), nil)
        }

        do {
            try await client.delete("/api/sessions/456")
            XCTFail("Should have thrown")
        } catch let error as DaemonClient.DaemonClientError {
            if case .httpError(let code) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Expected httpError(500)")
            }
        }
    }

    /// 10. Concurrent requests do not interfere
    func testConcurrentRequests() async throws {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let name = path.split(separator: "/").last.map(String.init) ?? "unknown"
            let body = try! JSONEncoder().encode(["name": name])
            return (self.makeResponse(url: request.url!), body)
        }

        struct Resp: Decodable { let name: String }

        async let r1: Resp = client.fetch("/api/one")
        async let r2: Resp = client.fetch("/api/two")
        async let r3: Resp = client.fetch("/api/three")

        let results = try await [r1, r2, r3]
        let names = Set(results.map(\.name))
        XCTAssertEqual(names, Set(["one", "two", "three"]))
    }
}
