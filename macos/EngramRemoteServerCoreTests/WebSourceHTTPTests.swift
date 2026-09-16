import CryptoKit
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class WebSourceHTTPTests: XCTestCase {
    private static let viewer = "d5-viewer"
    private static let editor = "d5-editor"
    private static let origin = "https://127.0.0.1"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("eg-d5-http-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testViewerGetReadsSourcesAndPostIsDenied() async throws {
        let recorder = SourceRecorder()
        recorder.page = try EngramServiceWebSourceSettingsValidation.projection(enabledSources: [])
        try await withServer(read: recorder.readSurface(), write: recorder.writeSurface(failOnCall: true)) { server in
            let cookie = try await Self.login(server, credential: Self.viewer)
            let listed = try await server.request(
                "GET", "/web/api/settings/sources",
                headers: Self.headers + [("Cookie", cookie)]
            )
            XCTAssertEqual(listed.status, 200)
            let page = try JSONDecoder().decode(EngramServiceWebSourceSettingsResponse.self, from: listed.body)
            XCTAssertEqual(page.sources.count, EngramServiceWebSourceSettingsValidation.knownKeys.count)
            XCTAssertEqual(Set(page.sources.map(\.enabled)), [false])
            let denied = try await server.request(
                "POST", "/web/api/settings/sources",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data(#"{"source":"codex","enabled":true}"#.utf8)
            )
            XCTAssertEqual(denied.status, 403)
        }
        XCTAssertEqual(recorder.sets.count, 0)
    }

    func testEditorToggleAndUnknownSource() async throws {
        let recorder = SourceRecorder()
        recorder.toggle = try EngramServiceWebSetSourceEnabledResponse(source: "codex", enabled: false)
        try await withServer(read: { throw EngramServiceWebReadClientError.unsupported },
                             write: recorder.writeSurface()) { server in
            let cookie = try await Self.login(server, credential: Self.editor)
            let changed = try await server.request(
                "POST", "/web/api/settings/sources",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data(#"{"source":"codex","enabled":false}"#.utf8)
            )
            XCTAssertEqual(changed.status, 200)
            let body = try JSONDecoder().decode(EngramServiceWebSetSourceEnabledResponse.self, from: changed.body)
            XCTAssertEqual(body.source, "codex")
            XCTAssertEqual(body.enabled, false)
            let unknown = try await server.request(
                "POST", "/web/api/settings/sources",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data(#"{"source":"not-a-source","enabled":true}"#.utf8)
            )
            XCTAssertEqual(unknown.status, 400)
        }
        XCTAssertEqual(recorder.sets.map(\.source), ["codex"])
        XCTAssertEqual(recorder.sets.map(\.enabled), [false])
    }

    private func withServer(
        read: @escaping WebReadRoutes.SourceSettingsReader,
        write: WebWriteRoutes.Surface,
        operation: (D4HTTPServer) async throws -> Void
    ) async throws {
        var surface = WebReadRoutes.messagesOnly({ _ in throw EngramServiceWebReadClientError.unavailable })
        surface.sourceSettings = read
        let app = try EngramRemoteServerApp(
            config: try EngramRemoteServerConfig(
                host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("legacy"),
                bearerToken: "d5-bearer", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
                web: try EngramRemoteWebConfig(
                    origin: Self.origin, viewerCredential: Self.viewer,
                    serverBearerCredentials: ["d5-bearer"], editorCredential: Self.editor
                ),
                webServiceSocketPath: directory.appendingPathComponent("service.sock").path
            ),
            webReadClientFactory: { _ in surface },
            webWriteClientFactory: { _ in write }
        )
        let server = try await D4HTTPServer(app: app)
        do { try await operation(server) } catch {
            do { try await server.stop() } catch { XCTFail("Server cleanup failed: \(error)") }
            throw error
        }
        try await server.stop()
    }

    private static var headers: [(String, String)] {
        [("X-Engram-Web", "1"), ("Origin", origin), ("Content-Type", "application/json")]
    }

    private static func login(_ server: D4HTTPServer, credential: String) async throws -> String {
        let body = Data("{\"credential\":\"\(credential)\"}".utf8)
        let response = try await server.request("POST", "/web/api/auth", headers: headers, body: body)
        XCTAssertEqual(response.status, 204)
        return try XCTUnwrap(response.header("set-cookie")?.split(separator: ";").first.map(String.init))
    }
}

private final class SourceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebSetSourceEnabledRequest] = []
    var page: EngramServiceWebSourceSettingsResponse?
    var toggle: EngramServiceWebSetSourceEnabledResponse?
    var sets: [EngramServiceWebSetSourceEnabledRequest] { lock.lock(); defer { lock.unlock() }; return calls }

    func readSurface() -> WebReadRoutes.SourceSettingsReader {
        { try XCTUnwrap(self.page) }
    }

    func writeSurface(failOnCall: Bool = false) -> WebWriteRoutes.Surface {
        WebWriteRoutes.Surface(
            addAlias: { _ in throw EngramServiceWebWriteClientError.unsupported },
            removeAlias: { _ in throw EngramServiceWebWriteClientError.unsupported },
            setSourceEnabled: { request in
                if failOnCall { XCTFail("Write surface must not run") }
                self.lock.lock(); self.calls.append(request); self.lock.unlock()
                return try XCTUnwrap(self.toggle)
            }
        )
    }
}
