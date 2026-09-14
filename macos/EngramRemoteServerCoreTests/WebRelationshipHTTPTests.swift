import CryptoKit
import Foundation
import XCTest
@testable import EngramRemoteServerCore

final class WebRelationshipHTTPTests: XCTestCase {
    private static let origin = "https://127.0.0.1"
    private static let operations: [(String, String, String, String)] = [
        ("POST", "link", #"{"parentId":"parent"}"#, "link"),
        ("DELETE", "link", "{}", "unlink"),
        ("POST", "confirm-suggestion", #"{"suggestedParentId":"parent"}"#, "confirmSuggestion"),
        ("DELETE", "suggestion", #"{"suggestedParentId":"parent"}"#, "dismissSuggestion"),
    ]

    func testEditorRoutesAllFourTypedRelationshipWrites() async throws {
        try await withServer { server in
            let cookie = try await Self.login(server, credential: "relationship-editor")
            for (method, suffix, body, action) in Self.operations {
                let response = try await server.request(method, "/web/api/sessions/child/" + suffix,
                    headers: Self.headers + [("Cookie", cookie)], body: Data(body.utf8))
                XCTAssertEqual(response.status, 200)
                let result = try JSONDecoder().decode(EngramServiceWebRelationshipMutationResponse.self, from: response.body)
                XCTAssertEqual(result.sessionId, "child")
                XCTAssertEqual(result.action, action)
                XCTAssertTrue(result.ok)
            }
        }
    }

    func testViewerAndMissingOriginCannotReachAnyRelationshipWriter() async throws {
        try await withServer(failOnWrite: true) { server in
            let viewer = try await Self.login(server, credential: "relationship-viewer")
            let editor = try await Self.login(server, credential: "relationship-editor")
            for (method, suffix, body, _) in Self.operations {
                let path = "/web/api/sessions/child/" + suffix
                let denied = try await server.request(method, path,
                    headers: Self.headers + [("Cookie", viewer)], body: Data(body.utf8))
                XCTAssertEqual(denied.status, 403)
                let csrf = try await server.request(method, path,
                    headers: Self.headers.filter { $0.0 != "Origin" } + [("Cookie", editor)], body: Data(body.utf8))
                XCTAssertEqual(csrf.status, 403)
            }
        }
    }

    func testUnlinkRejectsMalformedAndUnknownBodyBeforeWriter() async throws {
        try await withServer(failOnWrite: true) { server in
            let cookie = try await Self.login(server, credential: "relationship-editor")
            for body in ["{}garbage", "{}{}", "[]", #"{"unexpected":true}"#] {
                let response = try await server.request("DELETE", "/web/api/sessions/child/link",
                    headers: Self.headers + [("Cookie", cookie)], body: Data(body.utf8))
                XCTAssertEqual(response.status, 400, body)
            }
        }
    }

    func testStaleSuggestionBecomesConflict() async throws {
        try await withServer(stale: true) { server in
            let cookie = try await Self.login(server, credential: "relationship-editor")
            let response = try await server.request("DELETE", "/web/api/sessions/child/suggestion",
                headers: Self.headers + [("Cookie", cookie)], body: Data(#"{"suggestedParentId":"parent"}"#.utf8))
            XCTAssertEqual(response.status, 409)
        }
    }

    private func withServer(failOnWrite: Bool = false, stale: Bool = false,
                            operation: (D4HTTPServer) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/tmp/eg-d7-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result: @Sendable (String, String) throws -> EngramServiceWebRelationshipMutationResponse = { sessionId, action in
            if failOnWrite { XCTFail("Rejected request reached relationship writer") }
            if stale { throw EngramServiceWebWriteClientError.stale }
            XCTAssertEqual(sessionId, "child")
            return try .init(sessionId: sessionId, action: action, ok: true)
        }
        var writes = WebWriteRoutes.Surface(
            addAlias: { _ in throw EngramServiceWebWriteClientError.unsupported },
            removeAlias: { _ in throw EngramServiceWebWriteClientError.unsupported })
        writes.link = { request in
            XCTAssertEqual(request.parentId, "parent")
            return try result(request.sessionId, "link")
        }
        writes.unlink = { try result($0.sessionId, "unlink") }
        writes.confirmSuggestion = { request in
            XCTAssertEqual(request.suggestedParentId, "parent")
            return try result(request.sessionId, "confirmSuggestion")
        }
        writes.dismissSuggestion = { request in
            XCTAssertEqual(request.suggestedParentId, "parent")
            return try result(request.sessionId, "dismissSuggestion")
        }
        let writeSurface = writes
        let app = try EngramRemoteServerApp(config: EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("store"),
            bearerToken: "relationship-bearer", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
            web: EngramRemoteWebConfig(origin: Self.origin, viewerCredential: "relationship-viewer",
                serverBearerCredentials: ["relationship-bearer"], editorCredential: "relationship-editor"),
            webServiceSocketPath: directory.appendingPathComponent("service.sock").path),
            webReadClientFactory: { _ in WebReadRoutes.messagesOnly({ _ in throw EngramServiceWebReadClientError.unavailable }) },
            webWriteClientFactory: { _ in writeSurface })
        let server = try await D4HTTPServer(app: app)
        do { try await operation(server) } catch {
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
