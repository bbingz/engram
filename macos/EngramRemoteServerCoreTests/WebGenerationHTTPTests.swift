import CryptoKit
import Foundation
import XCTest
@testable import EngramRemoteServerCore

final class WebGenerationHTTPTests: XCTestCase {
    private static let origin = "https://127.0.0.1"
    private static let viewer = "generation-viewer"
    private static let editor = "generation-editor"
    private static let generation = String(repeating: "ab", count: 32)
    private static let longSummary = String(repeating: "Generated constellation summary. ", count: 10)

    func testEditorSummaryTitleAndBatchReturnTypedBodies() async throws {
        try await withServer { server, recorder in
            recorder.summary = try EngramServiceWebGenerateSummaryResponse(
                sessionId: "one", generation: Self.generation, summary: Self.longSummary
            )
            recorder.title = try EngramServiceWebGenerateTitleResponse(
                sessionId: "one", generation: Self.generation, title: "Generated title", displayTitle: "Pinned name"
            )
            recorder.batch = try EngramServiceWebRegenerateTitlesResponse(status: "started", total: 2)
            let cookie = try await Self.login(server, credential: Self.editor)
            let summary = try await server.request(
                "POST", "/web/api/sessions/one/summary",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data("{\"generation\":\"\(Self.generation)\"}".utf8)
            )
            XCTAssertEqual(summary.status, 200)
            let saved = try JSONDecoder().decode(EngramServiceWebGenerateSummaryResponse.self, from: summary.body)
            XCTAssertEqual(saved.summary, Self.longSummary)
            XCTAssertGreaterThan(try XCTUnwrap(saved.summary).count, 200)
            XCTAssertEqual(recorder.summaryRequests.first?.sessionId, "one")
            let title = try await server.request(
                "POST", "/web/api/sessions/one/title",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data("{\"generation\":\"\(Self.generation)\"}".utf8)
            )
            XCTAssertEqual(title.status, 200)
            let named = try JSONDecoder().decode(EngramServiceWebGenerateTitleResponse.self, from: title.body)
            XCTAssertEqual(named.title, "Generated title")
            XCTAssertEqual(named.displayTitle, "Pinned name")
            let batch = try await server.request(
                "POST", "/web/api/titles/regenerate",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data("{}".utf8)
            )
            XCTAssertEqual(batch.status, 200)
            let started = try JSONDecoder().decode(EngramServiceWebRegenerateTitlesResponse.self, from: batch.body)
            XCTAssertEqual(started.status, "started")
            XCTAssertEqual(started.total, 2)
        }
    }

    func testViewerCsrfAndDisabledEditorNeverReachWriter() async throws {
        try await withServer(failOnWrite: true) { server, _ in
            let viewer = try await Self.login(server, credential: Self.viewer)
            let editor = try await Self.login(server, credential: Self.editor)
            let body = Data("{\"generation\":\"\(Self.generation)\"}".utf8)
            let denied = try await server.request(
                "POST", "/web/api/sessions/one/summary",
                headers: Self.headers + [("Cookie", viewer)],
                body: body
            )
            XCTAssertEqual(denied.status, 403)
            let csrf = try await server.request(
                "POST", "/web/api/sessions/one/title",
                headers: Self.headers.filter { $0.0 != "Origin" } + [("Cookie", editor)],
                body: body
            )
            XCTAssertEqual(csrf.status, 403)
            let batch = try await server.request(
                "POST", "/web/api/titles/regenerate",
                headers: Self.headers + [("Cookie", viewer)],
                body: Data("{}".utf8)
            )
            XCTAssertEqual(batch.status, 403)
        }
        try await withServer(editorCredential: nil, failOnWrite: true) { server, _ in
            let viewer = try await Self.login(server, credential: Self.viewer)
            let denied = try await server.request(
                "POST", "/web/api/sessions/one/summary",
                headers: Self.headers + [("Cookie", viewer)],
                body: Data("{\"generation\":\"\(Self.generation)\"}".utf8)
            )
            XCTAssertEqual(denied.status, 403)
        }
    }

    func testUnknownKeysAndInvalidBodiesAreRejectedBeforeWriter() async throws {
        try await withServer(failOnWrite: true) { server, _ in
            let cookie = try await Self.login(server, credential: Self.editor)
            for body in [
                "{\"generation\":\"\(Self.generation)\",\"prompt\":\"extra\"}",
                "{\"generation\":\"short\"}",
                "{\"sessionId\":\"one\",\"generation\":\"\(Self.generation)\"}",
                "[]", "{}garbage", "{}",
            ] {
                let response = try await server.request(
                    "POST", "/web/api/sessions/one/summary",
                    headers: Self.headers + [("Cookie", cookie)],
                    body: Data(body.utf8)
                )
                XCTAssertEqual(response.status, 400, body)
            }
            let extraBatch = try await server.request(
                "POST", "/web/api/titles/regenerate",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data("{\"force\":true}".utf8)
            )
            XCTAssertEqual(extraBatch.status, 400)
        }
    }

    func testUnavailableAndStaleMapToServiceAndConflict() async throws {
        try await withServer { server, recorder in
            recorder.error = .unavailable
            let cookie = try await Self.login(server, credential: Self.editor)
            let unavailable = try await server.request(
                "POST", "/web/api/sessions/one/summary",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data("{\"generation\":\"\(Self.generation)\"}".utf8)
            )
            XCTAssertEqual(unavailable.status, 503)
            recorder.error = .stale
            let stale = try await server.request(
                "POST", "/web/api/sessions/one/title",
                headers: Self.headers + [("Cookie", cookie)],
                body: Data("{\"generation\":\"\(Self.generation)\"}".utf8)
            )
            XCTAssertEqual(stale.status, 409)
        }
    }

    func testSessionDetailKeepsOptionalFullSummary() throws {
        var detail: [String: Any] = [
            "session": [
                "sessionId": "one", "source": "claude-code", "captureIdentity": NSNull(),
                "metadataGeneration": NSNull(), "title": "Pinned name", "projectKey": NSNull(),
                "projectLabel": NSNull(), "startedAt": NSNull(),
            ],
            "lastParsed": NSNull(), "lastReady": NSNull(),
            "transcriptAvailability": "unavailable", "transcriptGeneration": NSNull(),
            "summary": Self.longSummary,
        ]
        let decoded = try JSONDecoder().decode(
            EngramServiceWebSessionDetail.self,
            from: try JSONSerialization.data(withJSONObject: detail)
        )
        XCTAssertEqual(decoded.summary, Self.longSummary)
        XCTAssertGreaterThan(try XCTUnwrap(decoded.summary).count, 200)
        detail["summary"] = String(repeating: "x", count: 50_001)
        XCTAssertThrowsError(try JSONDecoder().decode(
            EngramServiceWebSessionDetail.self,
            from: try JSONSerialization.data(withJSONObject: detail)
        ))
    }

    private func withServer(
        editorCredential: String? = editor,
        failOnWrite: Bool = false,
        operation: (D4HTTPServer, GenerationRecorder) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/eg-d13-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = GenerationRecorder()
        var writes = WebWriteRoutes.Surface(
            addAlias: { _ in throw EngramServiceWebWriteClientError.unsupported },
            removeAlias: { _ in throw EngramServiceWebWriteClientError.unsupported }
        )
        writes.generateSummary = { request in
            if failOnWrite { XCTFail("Rejected request reached summary writer") }
            recorder.recordSummary(request)
            if let error = recorder.error { throw error }
            return try XCTUnwrap(recorder.summary)
        }
        writes.generateTitle = { request in
            if failOnWrite { XCTFail("Rejected request reached title writer") }
            recorder.recordTitle(request)
            if let error = recorder.error { throw error }
            return try XCTUnwrap(recorder.title)
        }
        writes.regenerateTitles = { request in
            if failOnWrite { XCTFail("Rejected request reached batch writer") }
            recorder.recordBatch(request)
            if let error = recorder.error { throw error }
            return try XCTUnwrap(recorder.batch)
        }
        let app = try EngramRemoteServerApp(config: EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("store"),
            bearerToken: "generation-bearer", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
            web: EngramRemoteWebConfig(
                origin: Self.origin, viewerCredential: Self.viewer,
                serverBearerCredentials: ["generation-bearer"], editorCredential: editorCredential),
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

private final class GenerationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [EngramServiceWebGenerateSummaryRequest] = []
    private var titles: [EngramServiceWebGenerateTitleRequest] = []
    private var batches: [EngramServiceWebRegenerateTitlesRequest] = []
    var summary: EngramServiceWebGenerateSummaryResponse?
    var title: EngramServiceWebGenerateTitleResponse?
    var batch: EngramServiceWebRegenerateTitlesResponse?
    var error: EngramServiceWebWriteClientError?
    var summaryRequests: [EngramServiceWebGenerateSummaryRequest] {
        lock.lock(); defer { lock.unlock() }; return summaries
    }

    func recordSummary(_ request: EngramServiceWebGenerateSummaryRequest) {
        lock.lock(); defer { lock.unlock() }
        summaries.append(request)
    }

    func recordTitle(_ request: EngramServiceWebGenerateTitleRequest) {
        lock.lock(); defer { lock.unlock() }
        titles.append(request)
    }

    func recordBatch(_ request: EngramServiceWebRegenerateTitlesRequest) {
        lock.lock(); defer { lock.unlock() }
        batches.append(request)
    }
}
