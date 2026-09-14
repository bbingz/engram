import CryptoKit
import Foundation
import XCTest
@testable import EngramRemoteServerCore

final class WebProjectMigrationHTTPTests: XCTestCase {
    private static let origin = "https://127.0.0.1"
    private static let viewer = "project-migration-viewer"
    private static let editor = "project-migration-editor"

    func testViewerCanReadCapturedCwdsButNotMigrationHistory() async throws {
        try await withServer { server, recorder in
            recorder.cwds = try EngramServiceWebProjectCwdsResponse(
                snapshotId: "AAAAAAAA-0000-4000-8000-000000000216",
                observedAt: 1_800_000_000,
                projectKey: "project_1",
                totalCount: 1,
                items: [EngramServiceWebProjectCwdItem(key: "project_1", label: "Code › engram")],
                nextCursor: nil
            )
            recorder.history = try EngramServiceWebProjectMigrationsResponse(migrations: [Self.entry()])
            let viewer = try await Self.login(server, credential: Self.viewer)
            let cwds = try await server.request(
                "GET", "/web/api/projects/cwds?projectKey=project_1",
                headers: Self.getHeaders + [("Cookie", viewer)]
            )
            XCTAssertEqual(cwds.status, 200)
            let page = try JSONDecoder().decode(EngramServiceWebProjectCwdsResponse.self, from: cwds.body)
            XCTAssertEqual(page.scope, "captured")
            XCTAssertFalse(String(decoding: cwds.body, as: UTF8.self).contains("/Users/"))
            let denied = try await server.request(
                "GET", "/web/api/migrations?limit=5",
                headers: Self.getHeaders + [("Cookie", viewer)]
            )
            XCTAssertEqual(denied.status, 403)
            XCTAssertEqual(recorder.historyReads, 0)
            let editor = try await Self.login(server, credential: Self.editor)
            let history = try await server.request(
                "GET", "/web/api/migrations?state=committed&limit=5",
                headers: Self.getHeaders + [("Cookie", editor)]
            )
            XCTAssertEqual(history.status, 200, String(decoding: history.body, as: UTF8.self))
            let listed = try JSONDecoder().decode(EngramServiceWebProjectMigrationsResponse.self, from: history.body)
            XCTAssertEqual(listed.scope, "serverFilesystem")
            XCTAssertEqual(listed.migrations.map(\.id), ["mig-1"])
            XCTAssertEqual(recorder.historyReads, 1)
        }
    }

    func testViewerCsrfAndDisabledEditorNeverReachProjectWriter() async throws {
        try await withServer(failOnWrite: true) { server, recorder in
            let viewer = try await Self.login(server, credential: Self.viewer)
            let editor = try await Self.login(server, credential: Self.editor)
            let body = Data(#"{"src":"/tmp/a","dst":"/tmp/b","dry_run":true,"operation_id":"AAAAAAAA-0000-4000-8000-000000000217"}"#.utf8)
            let denied = try await server.request(
                "POST", "/web/api/projects/move",
                headers: Self.headers + [("Cookie", viewer)],
                body: body
            )
            XCTAssertEqual(denied.status, 403)
            let csrf = try await server.request(
                "POST", "/web/api/projects/move",
                headers: Self.headers.filter { $0.0 != "Origin" } + [("Cookie", editor)],
                body: body
            )
            XCTAssertEqual(csrf.status, 403)
            XCTAssertEqual(recorder.moves.count, 0)
        }
        try await withServer(editorCredential: nil, failOnWrite: true) { server, _ in
            let viewer = try await Self.login(server, credential: Self.viewer)
            let denied = try await server.request(
                "POST", "/web/api/projects/move",
                headers: Self.headers + [("Cookie", viewer)],
                body: Data(#"{"src":"/tmp/a","dst":"/tmp/b","dry_run":true,"operation_id":"AAAAAAAA-0000-4000-8000-000000000218"}"#.utf8)
            )
            XCTAssertEqual(denied.status, 403)
        }
    }

    func testUnknownKeysAndInvalidPathsAreRejectedBeforeWriter() async throws {
        try await withServer(failOnWrite: true) { server, recorder in
            let cookie = try await Self.login(server, credential: Self.editor)
            for body in [
                #"{"src":"/tmp/a","dst":"/tmp/b","dry_run":true,"operation_id":"AAAAAAAA-0000-4000-8000-000000000219","actor":"mcp"}"#,
                #"{"src":"tmp/a","dst":"/tmp/b","dry_run":true,"operation_id":"AAAAAAAA-0000-4000-8000-000000000220"}"#,
                #"{"src":"/tmp/a","dst":"/tmp/b","dry_run":true,"operation_id":"not-a-uuid"}"#,
                #"{"src":"/tmp/a","dst":"/tmp/b","dry_run":true}"#,
                "[]", "{}",
            ] {
                let response = try await server.request(
                    "POST", "/web/api/projects/move",
                    headers: Self.headers + [("Cookie", cookie)],
                    body: Data(body.utf8)
                )
                XCTAssertEqual(response.status, 400, body)
            }
            XCTAssertEqual(recorder.moves.count, 0)
        }
    }

    private func withServer(
        editorCredential: String? = editor,
        failOnWrite: Bool = false,
        operation: (D4HTTPServer, ProjectMigrationRecorder) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/eg-d15-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProjectMigrationRecorder()
        var reads = WebReadRoutes.messagesOnly({ _ in throw EngramServiceWebReadClientError.unavailable })
        reads.projectCwds = { request in
            XCTAssertEqual(request.projectKey, "project_1")
            return try XCTUnwrap(recorder.cwds)
        }
        var writes = WebWriteRoutes.Surface(
            addAlias: { _ in throw EngramServiceWebWriteClientError.unsupported },
            removeAlias: { _ in throw EngramServiceWebWriteClientError.unsupported }
        )
        writes.projectMigrations = { request in
            recorder.historyReads += 1
            XCTAssertEqual(request.limit, 5)
            return try XCTUnwrap(recorder.history)
        }
        writes.projectMove = { request in
            if failOnWrite { XCTFail("Rejected request reached project move writer") }
            recorder.record(request)
            throw EngramServiceWebWriteClientError.unavailable
        }
        let app = try EngramRemoteServerApp(
            config: EngramRemoteServerConfig(
                host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("store"),
                bearerToken: "project-migration-bearer", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
                web: EngramRemoteWebConfig(
                    origin: Self.origin, viewerCredential: Self.viewer,
                    serverBearerCredentials: ["project-migration-bearer"], editorCredential: editorCredential
                ),
                webServiceSocketPath: directory.appendingPathComponent("service.sock").path
            ),
            webReadClientFactory: { _ in reads },
            webWriteClientFactory: { _ in writes }
        )
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

    private static var getHeaders: [(String, String)] {
        [("Origin", origin), ("X-Engram-Web", "1")]
    }

    private static func login(_ server: D4HTTPServer, credential: String) async throws -> String {
        let response = try await server.request(
            "POST", "/web/api/auth", headers: headers,
            body: Data("{\"credential\":\"\(credential)\"}".utf8)
        )
        XCTAssertEqual(response.status, 204)
        return try XCTUnwrap(response.header("set-cookie")?.split(separator: ";").first.map(String.init))
    }

    private static func entry() -> EngramServiceMigrationLogEntry {
        EngramServiceMigrationLogEntry(
            id: "mig-1",
            oldPath: "/old",
            newPath: "/new",
            oldBasename: "old",
            newBasename: "new",
            state: "committed",
            startedAt: "2026-09-13T00:00:00Z",
            finishedAt: "2026-09-13T00:00:01Z",
            archived: false,
            auditNote: nil,
            actor: "mcp",
            detail: nil
        )
    }
}

private final class ProjectMigrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebProjectMoveRequest] = []
    var cwds: EngramServiceWebProjectCwdsResponse?
    var history: EngramServiceWebProjectMigrationsResponse?
    var historyReads = 0
    var moves: [EngramServiceWebProjectMoveRequest] {
        lock.lock(); defer { lock.unlock() }; return calls
    }

    func record(_ request: EngramServiceWebProjectMoveRequest) {
        lock.lock(); calls.append(request); lock.unlock()
    }
}
