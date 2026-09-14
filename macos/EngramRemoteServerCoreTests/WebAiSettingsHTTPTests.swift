import CryptoKit
import Foundation
import XCTest
@testable import EngramRemoteServerCore

final class WebAiSettingsHTTPTests: XCTestCase {
    private static let origin = "https://127.0.0.1"
    private static let viewer = "ai-settings-viewer"
    private static let editor = "ai-settings-editor"

    func testViewerGetAndEditorPatchReturnTypedBodies() async throws {
        try await withServer { server, recorder in
            recorder.page = try Self.settings(prompt: "", tokens: 200, model: "gpt-4o-mini")
            let viewer = try await Self.login(server, credential: Self.viewer)
            let listed = try await server.request(
                "GET", "/web/api/settings/ai",
                headers: Self.headers + [("Cookie", viewer)]
            )
            XCTAssertEqual(listed.status, 200)
            let page = try JSONDecoder().decode(EngramServiceWebAiSettingsResponse.self, from: listed.body)
            XCTAssertEqual(page.settings.aiModel, "gpt-4o-mini")
            XCTAssertFalse(String(decoding: listed.body, as: UTF8.self).contains("aiApiKey"))
            let denied = try await server.request(
                "POST", "/web/api/settings/ai",
                headers: Self.headers + [("Cookie", viewer)],
                body: Data(#"{"aiModel":"fixture-summary-model"}"#.utf8)
            )
            XCTAssertEqual(denied.status, 403)
            recorder.page = try Self.settings(
                prompt: "Decisions\nNext steps", tokens: 800, model: "fixture-summary-model"
            )
            let editor = try await Self.login(server, credential: Self.editor)
            let changed = try await server.request(
                "POST", "/web/api/settings/ai",
                headers: Self.headers + [("Cookie", editor)],
                body: Data(#"{"aiModel":"fixture-summary-model","summaryMaxTokens":800,"summaryPrompt":"Decisions\nNext steps"}"#.utf8)
            )
            XCTAssertEqual(changed.status, 200, String(decoding: changed.body, as: UTF8.self))
            let saved = try JSONDecoder().decode(EngramServiceWebAiSettingsResponse.self, from: changed.body)
            XCTAssertEqual(saved.settings.aiModel, "fixture-summary-model")
            XCTAssertEqual(saved.settings.summaryMaxTokens, 800)
            XCTAssertEqual(saved.settings.summaryPrompt, "Decisions\nNext steps")
            XCTAssertEqual(recorder.patches.first?.aiModel, "fixture-summary-model")
            XCTAssertEqual(recorder.patches.first?.summaryPrompt, "Decisions\nNext steps")
        }
    }

    func testViewerCsrfAndDisabledEditorNeverReachWriter() async throws {
        try await withServer(failOnWrite: true) { server, _ in
            let viewer = try await Self.login(server, credential: Self.viewer)
            let editor = try await Self.login(server, credential: Self.editor)
            let body = Data(#"{"aiModel":"fixture-summary-model"}"#.utf8)
            let denied = try await server.request(
                "POST", "/web/api/settings/ai",
                headers: Self.headers + [("Cookie", viewer)],
                body: body
            )
            XCTAssertEqual(denied.status, 403)
            let csrf = try await server.request(
                "POST", "/web/api/settings/ai",
                headers: Self.headers.filter { $0.0 != "Origin" } + [("Cookie", editor)],
                body: body
            )
            XCTAssertEqual(csrf.status, 403)
        }
        try await withServer(editorCredential: nil, failOnWrite: true) { server, _ in
            let viewer = try await Self.login(server, credential: Self.viewer)
            let denied = try await server.request(
                "POST", "/web/api/settings/ai",
                headers: Self.headers + [("Cookie", viewer)],
                body: Data(#"{"aiModel":"fixture-summary-model"}"#.utf8)
            )
            XCTAssertEqual(denied.status, 403)
        }
    }

    func testUnknownKeysSecretsAndInvalidURLsAreRejectedBeforeWriter() async throws {
        try await withServer(failOnWrite: true) { server, _ in
            let cookie = try await Self.login(server, credential: Self.editor)
            for body in [
                #"{"aiApiKey":"fixture-only-not-a-real-key"}"#,
                #"{"aiModel":"x","unknown":true}"#,
                #"{"aiBaseURL":"https://user:token@evil.example"}"#,
                #"{"embeddingBaseURL":"https://api.openai.com/v1?api_key=sk-secret"}"#,
                #"{"summaryMaxTokens":0}"#,
                "[]", "{}garbage", "{}",
            ] {
                let response = try await server.request(
                    "POST", "/web/api/settings/ai",
                    headers: Self.headers + [("Cookie", cookie)],
                    body: Data(body.utf8)
                )
                XCTAssertEqual(response.status, 400, body)
                XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("token"))
                XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("sk-secret"))
            }
        }
    }

    func testUnavailableMapsToServiceError() async throws {
        try await withServer { server, recorder in
            recorder.readError = .unavailable
            recorder.writeError = .unavailable
            let viewer = try await Self.login(server, credential: Self.viewer)
            let listed = try await server.request(
                "GET", "/web/api/settings/ai",
                headers: Self.headers + [("Cookie", viewer)]
            )
            XCTAssertEqual(listed.status, 503)
            XCTAssertFalse(String(decoding: listed.body, as: UTF8.self).contains("user:"))
            let editor = try await Self.login(server, credential: Self.editor)
            let changed = try await server.request(
                "POST", "/web/api/settings/ai",
                headers: Self.headers + [("Cookie", editor)],
                body: Data(#"{"aiModel":"fixture-summary-model"}"#.utf8)
            )
            XCTAssertEqual(changed.status, 503)
        }
    }

    func testPublishedSettingsRejectEmbeddedCredentials() throws {
        XCTAssertThrowsError(try Self.settings(aiBaseURL: "https://user:token@evil.example/v1"))
        XCTAssertThrowsError(try Self.settings(embedding: "https://api.openai.com/v1?api_key=sk-secret"))
        let allowed = try Self.settings(prompt: "Decisions\nNext steps")
        XCTAssertEqual(allowed.summaryPrompt, "Decisions\nNext steps")
    }

    private func withServer(
        editorCredential: String? = editor,
        failOnWrite: Bool = false,
        operation: (D4HTTPServer, AiSettingsRecorder) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/eg-d14-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AiSettingsRecorder()
        var reads = WebReadRoutes.messagesOnly({ _ in throw EngramServiceWebReadClientError.unavailable })
        reads.aiSettings = {
            if let error = recorder.readError { throw error }
            return EngramServiceWebAiSettingsResponse(settings: try XCTUnwrap(recorder.page))
        }
        var writes = WebWriteRoutes.Surface(
            addAlias: { _ in throw EngramServiceWebWriteClientError.unsupported },
            removeAlias: { _ in throw EngramServiceWebWriteClientError.unsupported }
        )
        writes.patchAiSettings = { request in
            if failOnWrite { XCTFail("Rejected request reached AI settings writer") }
            recorder.record(request)
            if let error = recorder.writeError { throw error }
            return EngramServiceWebAiSettingsResponse(settings: try XCTUnwrap(recorder.page))
        }
        let readSurface = reads
        let writeSurface = writes
        let app = try EngramRemoteServerApp(
            config: EngramRemoteServerConfig(
                host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("store"),
                bearerToken: "ai-settings-bearer", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
                web: EngramRemoteWebConfig(
                    origin: Self.origin, viewerCredential: Self.viewer,
                    serverBearerCredentials: ["ai-settings-bearer"], editorCredential: editorCredential
                ),
                webServiceSocketPath: directory.appendingPathComponent("service.sock").path
            ),
            webReadClientFactory: { _ in readSurface },
            webWriteClientFactory: { _ in writeSurface }
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

    private static func login(_ server: D4HTTPServer, credential: String) async throws -> String {
        let response = try await server.request(
            "POST", "/web/api/auth", headers: headers,
            body: Data("{\"credential\":\"\(credential)\"}".utf8)
        )
        XCTAssertEqual(response.status, 204)
        return try XCTUnwrap(response.header("set-cookie")?.split(separator: ";").first.map(String.init))
    }

    private static func settings(
        prompt: String = "",
        tokens: Int = 200,
        model: String = "gpt-4o-mini",
        aiBaseURL: String = "https://api.openai.com",
        embedding: String = "https://api.openai.com/v1"
    ) throws -> EngramServiceWebAiSettings {
        try EngramServiceWebAiSettings(
            aiProtocol: "openai",
            aiBaseURL: aiBaseURL,
            aiModel: model,
            summaryLanguage: "中文",
            summaryMaxSentences: 3,
            summaryStyle: "",
            summaryPrompt: prompt,
            summaryMaxTokens: tokens,
            summaryTemperature: 0.3,
            summarySampleFirst: 20,
            summarySampleLast: 30,
            summaryTruncateChars: 500,
            summaryPreset: "standard",
            titleProvider: "ollama",
            titleBaseUrl: "http://localhost:11434",
            titleBaseURL: "http://localhost:11434",
            titleModel: "gpt-4o-mini",
            embeddingBaseURL: embedding,
            embeddingModel: "text-embedding-3-small",
            embeddingDimension: 1536,
            embeddingIncludeDimensions: false,
            aiAudit: EngramServiceWebAiSettingsAudit(enabled: true, logBodies: false, maxBodySize: 10_000)
        )
    }
}

private final class AiSettingsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebPatchAiSettingsRequest] = []
    var page: EngramServiceWebAiSettings?
    var readError: EngramServiceWebReadClientError?
    var writeError: EngramServiceWebWriteClientError?
    var patches: [EngramServiceWebPatchAiSettingsRequest] {
        lock.lock(); defer { lock.unlock() }; return calls
    }

    func record(_ request: EngramServiceWebPatchAiSettingsRequest) {
        lock.lock(); calls.append(request); lock.unlock()
    }
}
