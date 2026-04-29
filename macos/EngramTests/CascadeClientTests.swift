import XCTest
@testable import Engram

final class CascadeClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testConnectRPCListConversationsSendsCSRFAndDecodesWorkspaceFields() async throws {
        let session = createMockSession()
        let baseURL = try XCTUnwrap(URL(string: "http://localhost:34567"))
        let client = CascadeClient(baseURL: baseURL, csrfToken: "token-123", session: session)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-codeium-csrf-token"), "token-123")

            let body = """
            {
              "trajectorySummaries": {
                "cascade-1": {
                  "summary": "Fix parser",
                  "createdTime": "2026-02-20T10:00:00.000Z",
                  "lastModifiedTime": { "seconds": 1771582200 },
                  "workspaces": [
                    { "workspaceFolderAbsoluteUri": "file:///Users/example/-Code-/engram" }
                  ]
                }
              }
            }
            """
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let conversations = try await client.listConversations()
        XCTAssertEqual(conversations, [
            CascadeConversationSummary(
                cascadeId: "cascade-1",
                title: "Fix parser",
                summary: "Fix parser",
                createdAt: "2026-02-20T10:00:00.000Z",
                updatedAt: "2026-02-20T10:10:00.000Z",
                cwd: "/Users/example/-Code-/engram"
            )
        ])
    }

    func testConnectRPCTrajectoryMessagesDecodeSupportedStepTypes() async throws {
        let session = createMockSession()
        let baseURL = try XCTUnwrap(URL(string: "http://localhost:34567"))
        let client = CascadeClient(baseURL: baseURL, csrfToken: "token-123", session: session)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/exa.language_server_pb.LanguageServerService/GetCascadeTrajectory")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-codeium-csrf-token"), "token-123")
            XCTAssertEqual(Self.bodyString(from: request), #"{"cascadeId":"cascade-1"}"#)

            let body = """
            {
              "trajectory": {
                "steps": [
                  { "type": "USER_INPUT", "userInput": { "userResponse": "Please fix auth" } },
                  { "type": "PLANNER_RESPONSE", "plannerResponse": { "response": "I will inspect auth.ts" } },
                  { "type": "NOTIFY_USER", "notifyUser": { "notificationContent": "Patch complete" } }
                ]
              }
            }
            """
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let messages = try await client.getTrajectoryMessages(cascadeId: "cascade-1")
        XCTAssertEqual(messages, [
            CascadeTrajectoryMessage(role: .user, content: "Please fix auth"),
            CascadeTrajectoryMessage(role: .assistant, content: "I will inspect auth.ts"),
            CascadeTrajectoryMessage(role: .assistant, content: "Patch complete")
        ])
    }

    func testConnectRPCMarkdownConversionDecodesMarkdown() async throws {
        let session = createMockSession()
        let baseURL = try XCTUnwrap(URL(string: "http://localhost:34567"))
        let client = CascadeClient(baseURL: baseURL, csrfToken: "token-123", session: session)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/exa.language_server_pb.LanguageServerService/ConvertTrajectoryToMarkdown")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-codeium-csrf-token"), "token-123")
            XCTAssertEqual(Self.bodyString(from: request), #"{"trajectory":{"cascadeId":"cascade-1"}}"#)

            let body = "{\"markdown\":\"## User\\n\\nHello\\n\\n## Cascade\\n\\nHi\"}"
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let markdown = try await client.getMarkdown(cascadeId: "cascade-1")
        XCTAssertEqual(markdown, "## User\n\nHello\n\n## Cascade\n\nHi")
    }

    func testLiveCascadeSmokeIsOptIn() async throws {
        guard ProcessInfo.processInfo.environment["ENGRAM_LIVE_CASCADE_TEST"] == "1" else {
            throw XCTSkip("ENGRAM_LIVE_CASCADE_TEST is not enabled")
        }

        guard let client = await CascadeDiscovery.discoverAntigravityClient() else {
            throw XCTSkip("No live Antigravity Cascade service discovered")
        }
        _ = try await client.listConversations()
    }

    private static func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }
}
