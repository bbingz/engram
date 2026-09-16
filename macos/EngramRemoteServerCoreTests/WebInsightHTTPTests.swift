import CryptoKit
import Foundation
import XCTest
@testable import EngramRemoteServerCore

final class WebInsightHTTPTests: XCTestCase {
    private static let origin = "https://127.0.0.1"
    private static let viewer = "insight-viewer"
    private static let editor = "insight-editor"

    func testEditorSaveReturnsTypedIdAndWarning() async throws {
        try await withServer { server, recorder in
            recorder.response = try EngramServiceWebSaveInsightResponse(
                id: "insight-saved", warning: "Saved without embedding; keyword search is available immediately")
            let cookie = try await Self.login(server, credential: Self.editor)
            let response = try await server.request(
                "POST", "/web/api/insights",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data(#"{"content":"library note from web save","importance":4}"#.utf8)
            )
            XCTAssertEqual(response.status, 200)
            let saved = try JSONDecoder().decode(EngramServiceWebSaveInsightResponse.self, from: response.body)
            XCTAssertEqual(saved.id, "insight-saved")
            XCTAssertEqual(recorder.requests.count, 1)
            XCTAssertEqual(recorder.requests.first?.content, "library note from web save")
            XCTAssertEqual(recorder.requests.first?.importance, 4)
            XCTAssertNil(recorder.requests.first?.sourceSessionId)
        }
    }

    func testViewerCsrfAndDisabledEditorNeverReachWriter() async throws {
        try await withServer(failOnWrite: true) { server, _ in
            let viewer = try await Self.login(server, credential: Self.viewer)
            let editor = try await Self.login(server, credential: Self.editor)
            let body = Data(#"{"content":"library note from web save"}"#.utf8)
            let denied = try await server.request(
                "POST", "/web/api/insights",
                headers: Self.headers + [("Cookie", viewer)],
                body: body
            )
            XCTAssertEqual(denied.status, 403)
            let csrf = try await server.request(
                "POST", "/web/api/insights",
                headers: Self.headers.filter { $0.0 != "Origin" } + [("Cookie", editor)],
                body: body
            )
            XCTAssertEqual(csrf.status, 403)
        }
        try await withServer(editorCredential: nil, failOnWrite: true) { server, _ in
            let viewer = try await Self.login(server, credential: Self.viewer)
            let denied = try await server.request(
                "POST", "/web/api/insights",
                headers: Self.headers + [("Cookie", viewer)],
                body: Data(#"{"content":"library note from web save"}"#.utf8)
            )
            XCTAssertEqual(denied.status, 403)
        }
    }

    func testUnknownKeysAndInvalidBodiesAreRejectedBeforeWriter() async throws {
        try await withServer(failOnWrite: true) { server, _ in
            let cookie = try await Self.login(server, credential: Self.editor)
            for body in [
                #"{"content":"library note from web save","type":"semantic"}"#,
                #"{"content":"short"}"#,
                #"{"content":"library note from web save","importance":6}"#,
                #"{"content":"library note from web save","importance":true}"#,
                "[]", "{}garbage", "{}"
            ] {
                let response = try await server.request(
                    "POST", "/web/api/insights",
                    headers: Self.headers + [("Cookie", cookie)],
                    body: Data(body.utf8)
                )
                XCTAssertEqual(response.status, 400, body)
            }
        }
    }

    func testHiddenSourceMapsToNotFound() async throws {
        try await withServer { server, recorder in
            recorder.error = .notFound
            let cookie = try await Self.login(server, credential: Self.editor)
            let response = try await server.request(
                "POST", "/web/api/insights",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data(#"{"content":"hidden source must not receive a new note","sourceSessionId":"manual-hidden"}"#.utf8)
            )
            XCTAssertEqual(response.status, 404)
            XCTAssertEqual(recorder.requests.first?.sourceSessionId, "manual-hidden")
        }
    }

    private func withServer(
        editorCredential: String? = editor,
        failOnWrite: Bool = false,
        operation: (D4HTTPServer, InsightRecorder) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/eg-d12-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = InsightRecorder()
        var writes = WebWriteRoutes.Surface(
            addAlias: { _ in throw EngramServiceWebWriteClientError.unsupported },
            removeAlias: { _ in throw EngramServiceWebWriteClientError.unsupported }
        )
        writes.saveInsight = { request in
            if failOnWrite { XCTFail("Rejected request reached insight writer") }
            recorder.record(request)
            if let error = recorder.error { throw error }
            return try XCTUnwrap(recorder.response)
        }
        let app = try EngramRemoteServerApp(config: EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("store"),
            bearerToken: "insight-bearer", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
            web: EngramRemoteWebConfig(
                origin: Self.origin, viewerCredential: Self.viewer,
                serverBearerCredentials: ["insight-bearer"], editorCredential: editorCredential),
            webServiceSocketPath: directory.appendingPathComponent("service.sock").path),
            webReadClientFactory: { _ in WebReadRoutes.messagesOnly({ _ in throw EngramServiceWebReadClientError.unavailable }) },
            webWriteClientFactory: { _ in writes })
        let server = try await D4HTTPServer(app: app)
        do { try await operation(server, recorder) } catch {
            try await server.stop()
            throw error
        }
        try await server.stop()
    }

    private static var headers: [(String, String)] {
        [("Origin", origin), ("X-Engram-Web", "1"), ("Content-Type", "application/json")]
    }

    private static func login(_ server: D4HTTPServer, credential: String) async throws -> String {
        let response = try await server.request("POST", "/web/api/auth", headers: headers,
            body: Data("{\"credential\":\"\(credential)\"}".utf8))
        XCTAssertEqual(response.status, 204)
        return try XCTUnwrap(response.header("set-cookie")?.split(separator: ";").first.map(String.init))
    }
}

private final class InsightRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebSaveInsightRequest] = []
    var response: EngramServiceWebSaveInsightResponse?
    var error: EngramServiceWebWriteClientError?
    var requests: [EngramServiceWebSaveInsightRequest] {
        lock.lock(); defer { lock.unlock() }; return calls
    }

    func record(_ request: EngramServiceWebSaveInsightRequest) {
        lock.lock(); defer { lock.unlock() }
        calls.append(request)
    }
}
