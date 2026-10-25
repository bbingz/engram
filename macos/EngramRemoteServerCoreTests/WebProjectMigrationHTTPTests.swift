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

    func testProjectAuditActorComesFromSessionAndRejectsBrowserOverride_repro() async throws {
        for identityMode in [false, true] {
            try await withServer(identityMode: identityMode) { server, recorder in
                let cookie: String
                if identityMode {
                    let login = try await server.request("POST", "/web/api/auth",
                        headers: Self.headers + [("Tailscale-User-Login", "editor@example.com")],
                        body: Data("{}".utf8))
                    XCTAssertEqual(login.status, 204)
                    cookie = try XCTUnwrap(login.header("set-cookie")?.split(separator: ";").first.map(String.init))
                } else {
                    cookie = try await Self.login(server, credential: Self.editor)
                }
                let cases: [(String, [String: Any])] = [
                    ("move", ["src": "/tmp/a", "dst": "/tmp/b", "dry_run": true]),
                    ("archive", ["src": "/tmp/a", "dry_run": true]),
                    ("undo", ["migration_id": "fixture-migration"]),
                    ("move-batch", ["yaml": "{\"version\":1,\"operations\":[]}", "dry_run": true]),
                ]
                for (route, fields) in cases {
                    var payload = fields
                    payload["operation_id"] = UUID().uuidString
                    let headers = Self.headers + [("Cookie", cookie), ("Tailscale-User-Login", "forged@example.com")]
                    let response = try await server.request("POST", "/web/api/projects/" + route,
                        headers: headers, body: JSONSerialization.data(withJSONObject: payload))
                    XCTAssertEqual(response.status, 503) // recording surface has no backing service
                    XCTAssertEqual(recorder.actors[route], identityMode ? "editor@example.com" : "web-editor", route)
                    payload["actor"] = "forged@example.com"
                    let rejected = try await server.request("POST", "/web/api/projects/" + route,
                        headers: headers, body: JSONSerialization.data(withJSONObject: payload))
                    XCTAssertEqual(rejected.status, 400)
                }
            }
        }
    }

    private func withServer(
        editorCredential: String? = editor,
        failOnWrite: Bool = false,
        identityMode: Bool = false,
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
            try recorder.recordActor("move", request)
            throw EngramServiceWebWriteClientError.unavailable
        }
        writes.projectArchive = { request in
            try recorder.recordActor("archive", request)
            throw EngramServiceWebWriteClientError.unavailable
        }
        writes.projectUndo = { request in
            try recorder.recordActor("undo", request)
            throw EngramServiceWebWriteClientError.unavailable
        }
        writes.projectMoveBatch = { request in
            try recorder.recordActor("move-batch", request)
            throw EngramServiceWebWriteClientError.unavailable
        }
        let web = try identityMode
            ? EngramRemoteWebConfig(origin: Self.origin, tailscaleServeViewers: "reader@example.com", editors: "editor@example.com")
            : EngramRemoteWebConfig(origin: Self.origin, viewerCredential: Self.viewer,
                serverBearerCredentials: ["project-migration-bearer"], editorCredential: editorCredential)
        let app = try EngramRemoteServerApp(
            config: EngramRemoteServerConfig(
                host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("store"),
                bearerToken: "project-migration-bearer", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
                web: web,
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
    private var auditActors: [String: String] = [:]
    var actors: [String: String] {
        lock.lock(); defer { lock.unlock() }; return auditActors
    }
    func recordActor<T: Encodable>(_ route: String, _ request: T) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        lock.lock(); defer { lock.unlock() }
        auditActors[route] = object["actor"] as? String
    }
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
