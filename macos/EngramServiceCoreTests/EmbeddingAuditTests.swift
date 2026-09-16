import Foundation
import GRDB
import XCTest
import EngramCoreRead
@testable import EngramServiceCore

final class EmbeddingAuditTests: XCTestCase {
    func testServiceFactoryRecordsSuccessfulRequestAndProviderTokens() async throws {
        let capture = EmbeddingAuditCapture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = EngramServiceRunner.defaultGuardedEmbeddingProvider(
            config: config("success"), audit: capture, session: session)
        let vectors = try await provider.embed(["synthetic input"])
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(vectors[0].count, 2)
        let empty = try await provider.embed([])
        XCTAssertTrue(empty.isEmpty)
        let entries = await capture.snapshot()
        XCTAssertEqual(entries.count, 1, "Empty input must not invent a provider attempt")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.caller, "embedding")
        XCTAssertEqual(entry.operation, "embed")
        XCTAssertEqual(entry.statusCode, 200)
        XCTAssertEqual(entry.promptTokens, 42)
        XCTAssertEqual(entry.totalTokens, 42)
        XCTAssertNil(entry.completionTokens)
        XCTAssertNil(entry.error)
        XCTAssertTrue(entry.url?.hasSuffix("/success/embeddings") == true)
        XCTAssertFalse(entry.requestBody?.contains("synthetic-header-key") == true)
    }

    func testCompatibilityRetryRecordsBothActualHTTPAttemptsExactlyOnce() async throws {
        let capture = EmbeddingAuditCapture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = EngramServiceRunner.defaultGuardedEmbeddingProvider(
            config: config("fallback"), audit: capture, session: session)
        _ = try await provider.embed(["synthetic input"])
        let entries = await capture.snapshot()
        XCTAssertEqual(entries.map(\.statusCode), [400, 200])
        XCTAssertNotNil(entries.first?.error)
        XCTAssertNil(entries.last?.error)
        XCTAssertEqual(entries.last?.totalTokens, 42)
    }

    func testMalformedHTTPAndTransportFailuresAreRecorded() async throws {
        for scenario in ["malformed", "http-error", "transport"] {
            let capture = EmbeddingAuditCapture()
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            let provider = EngramServiceRunner.defaultGuardedEmbeddingProvider(
                config: config(scenario), audit: capture, session: session)
            do {
                _ = try await provider.embed(["synthetic input"])
                XCTFail("Expected failure for \(scenario)")
            } catch { /* The actual failure must remain visible to callers. */ }
            let entries = await capture.snapshot()
            XCTAssertEqual(entries.count, 1, scenario)
            XCTAssertNotNil(entries.first?.error, scenario)
            XCTAssertEqual(entries.first?.statusCode, scenario == "transport" ? nil : scenario == "http-error" ? 500 : 200)
        }
    }

    func testInvalidProviderUsageRemainsUnknownWithoutCrashing() async throws {
        let capture = EmbeddingAuditCapture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = EngramServiceRunner.defaultGuardedEmbeddingProvider(
            config: config("bad-usage"), audit: capture, session: session)
        _ = try await provider.embed(["synthetic input"])
        let entries = await capture.snapshot()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertNil(entry.promptTokens)
        XCTAssertNil(entry.totalTokens)
        XCTAssertNil(entry.error)
    }

    func testCircuitRejectionDoesNotInventAnHTTPAuditEntry() async throws {
        let capture = EmbeddingObservationCapture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = GuardedEmbeddingProvider(config: config("http-error"),
            breaker: EmbeddingCircuitBreaker(config: .init(failureThreshold: 1, cooldown: 60)),
            session: session, observeRequest: { await capture.record($0) })
        for _ in 0..<2 {
            do { _ = try await provider.embed(["synthetic input"]); XCTFail("Expected provider or circuit failure") }
            catch { /* expected */ }
        }
        let count = await capture.count()
        XCTAssertEqual(count, 1)
    }

    func testProviderObservationPersistsThroughServiceWriterGateWithoutBodiesByDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eg-embedding-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let gate = try ServiceWriterGate(databasePath: root.appendingPathComponent("engram.sqlite").path,
            runtimeDirectory: runtime)
        _ = try await gate.performWriteCommand(name: "embeddingAuditFixture") { try $0.migrate() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let recorder = ServiceAIAuditRecorder(writerGate: gate, auditConfig: { .default })
        let provider = EngramServiceRunner.defaultGuardedEmbeddingProvider(
            config: config("success"), audit: recorder, session: session)
        _ = try await provider.embed(["synthetic input"])
        let count = try await gate.performReadCommand(name: "embeddingAuditRead") { writer in
            try writer.read { db in
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM ai_audit_log")
                let row = try XCTUnwrap(rows.first)
                XCTAssertEqual(row["caller"] as String?, "embedding")
                XCTAssertEqual(row["operation"] as String?, "embed")
                XCTAssertEqual(row["prompt_tokens"] as Int?, 42)
                XCTAssertEqual(row["total_tokens"] as Int?, 42)
                XCTAssertNil(row["request_body"] as String?)
                XCTAssertNil(row["response_body"] as String?)
                XCTAssertNil(row["session_id"] as String?)
                return rows.count
            }
        }.value
        XCTAssertEqual(count, 1)
    }

    private func config(_ scenario: String) -> EmbeddingConfig {
        EmbeddingConfig(baseURL: "https://embedding-audit.test/\(scenario)",
            apiKey: "synthetic-header-key", model: "fixture-\(UUID().uuidString)",
            dimension: 2, dimensionWasExplicit: true)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmbeddingAuditURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor EmbeddingAuditCapture: ServiceAIAuditRecording {
    private var entries: [ServiceAIAuditEntry] = []
    func record(_ entry: ServiceAIAuditEntry) { entries.append(entry) }
    func snapshot() -> [ServiceAIAuditEntry] { entries }
}

private actor EmbeddingObservationCapture {
    private var observations: [EmbeddingRequestObservation] = []
    func record(_ observation: EmbeddingRequestObservation) { observations.append(observation) }
    func count() -> Int { observations.count }
}

private final class EmbeddingAuditURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "embedding-audit.test" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        if url.path.contains("/transport/") {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let body = (try? JSONSerialization.jsonObject(with: requestBody()) as? [String: Any]) ?? [:]
        let fallback = url.path.contains("/fallback/") && body["dimensions"] != nil
        let status = fallback ? 400 : url.path.contains("/http-error/") ? 500 : 200
        let payload: String
        if fallback { payload = #"{"error":{"message":"dimensions unsupported","param":"dimensions"}}"# }
        else if url.path.contains("/malformed/") { payload = "{" }
        else if url.path.contains("/bad-usage/") { payload = #"{"data":[{"index":0,"embedding":[3,4]}],"usage":{"prompt_tokens":1e99,"total_tokens":true}}"# }
        else { payload = #"{"data":[{"index":0,"embedding":[3,4]}],"usage":{"prompt_tokens":42,"total_tokens":42}}"# }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
