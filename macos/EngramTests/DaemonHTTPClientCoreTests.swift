import XCTest
@testable import Engram

final class DaemonHTTPClientCoreTests: XCTestCase {

    private var mockSession: URLSession!
    private var client: DaemonHTTPClientCore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        mockSession = createMockSession()
        client = DaemonHTTPClientCore(
            baseURL: URL(string: "http://127.0.0.1:3457")!,
            session: mockSession,
            bearerTokenProvider: { "test-token" }
        )
    }

    override func tearDownWithError() throws {
        MockURLProtocol.requestHandler = nil
        client = nil
        mockSession = nil
        try super.tearDownWithError()
    }

    private func makeResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private func requestBodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            throw XCTSkip("Request body was not available on the intercepted URLRequest")
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                throw stream.streamError ?? URLError(.cannotParseResponse)
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }

        return data
    }

    func testFetchAddsAuthorizationAndTraceIDHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Trace-Id"))
            let body = try JSONEncoder().encode(["ok": true])
            return (self.makeResponse(url: request.url!), body)
        }

        struct Response: Decodable { let ok: Bool }
        let response: Response = try await client.fetch("/api/ping")
        XCTAssertTrue(response.ok)
    }

    func testPostEncodesJSONBody() async throws {
        struct Request: Encodable { let actor: String }
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let body = try self.requestBodyData(for: request)
            let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
            XCTAssertEqual(decoded?["actor"], "mcp")
            let responseBody = try JSONEncoder().encode(["saved": true])
            return (self.makeResponse(url: request.url!), responseBody)
        }

        struct Response: Decodable { let saved: Bool }
        let response: Response = try await client.post("/api/insight", body: Request(actor: "mcp"))
        XCTAssertTrue(response.saved)
    }

    func testStructuredErrorEnvelopeMapsToDaemonHTTPError() async throws {
        let responseJSON = """
        {
          "error": {
            "name": "PermissionDeniedError",
            "message": "Daemon token mismatch",
            "retry_policy": "never",
            "details": {
              "migrationId": "mig-123"
            }
          }
        }
        """

        MockURLProtocol.requestHandler = { request in
            (
                self.makeResponse(url: request.url!, statusCode: 401),
                responseJSON.data(using: .utf8)
            )
        }

        struct Response: Decodable { let ok: Bool }

        do {
            let _: Response = try await client.fetch("/api/protected")
            XCTFail("Expected fetch to throw")
        } catch let error as DaemonHTTPError {
            XCTAssertEqual(error.httpStatus, 401)
            XCTAssertEqual(error.name, "PermissionDeniedError")
            XCTAssertEqual(error.message, "Daemon token mismatch")
            XCTAssertEqual(error.retryPolicy, "never")
            XCTAssertEqual(error.details?.migrationId, "mig-123")
        }
    }
}
