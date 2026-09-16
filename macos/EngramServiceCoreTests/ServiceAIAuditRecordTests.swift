import Foundation
import GRDB
import XCTest
@testable import EngramCoreWrite
@testable import EngramServiceCore

final class ServiceAIAuditRecordTests: XCTestCase {
    func testInjectedSessionSuccessRecordsTokensWithoutLiveNetwork() async throws {
        let env = try AuditRecordEnv()
        defer { env.remove() }
        AuditChatURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "engram-ai.test")
            return (200, Self.successBody(prompt: 120, completion: 30, total: 150))
        }
        let answer = try await EngramServiceCommandHandler.ServiceAIClient.chat(
            purpose: "summary", sessionID: "session-a", config: Self.config,
            messages: [["role": "user", "content": "Summarize"]],
            urlSession: env.session, audit: env.recorder())
        XCTAssertEqual(answer, "Synthetic captured summary")
        let row = try XCTUnwrap(env.rows().first)
        XCTAssertEqual(row.caller, "summary")
        XCTAssertEqual(row.operation, "chat")
        XCTAssertEqual(row.method, "POST")
        XCTAssertEqual(row.model, "demo-chat")
        XCTAssertEqual(row.promptTokens, 120)
        XCTAssertEqual(row.completionTokens, 30)
        XCTAssertEqual(row.totalTokens, 150)
        XCTAssertEqual(row.sessionId, "session-a")
        XCTAssertNil(row.error)
        XCTAssertNil(row.requestBody)
        XCTAssertNil(row.responseBody)
    }

    func testTransportAndHTTPErrorsStillInsert() async throws {
        let env = try AuditRecordEnv()
        defer { env.remove() }
        AuditChatURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await EngramServiceCommandHandler.ServiceAIClient.chat(
                purpose: "summary", sessionID: "session-a", config: Self.config,
                messages: [["role": "user", "content": "hello"]],
                urlSession: env.session, audit: env.recorder())
            XCTFail("Transport failure must still surface")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, _, _, let details) = error else {
                return XCTFail("Expected commandFailed")
            }
            XCTAssertEqual(name, "AIRequestTransportFailed")
            XCTAssertEqual(details?["url"], .string("https://engram-ai.test/v1"))
        }
        XCTAssertEqual(env.rows().count, 1)
        XCTAssertNotNil(env.rows().first?.error)

        AuditChatURLProtocol.handler = { _ in (500, Data("{\"error\":\"no\"}".utf8)) }
        do {
            _ = try await EngramServiceCommandHandler.ServiceAIClient.chat(
                purpose: "title", sessionID: "session-a", config: Self.config,
                messages: [["role": "user", "content": "hello"]],
                urlSession: env.session, audit: env.recorder())
            XCTFail("HTTP failure must still surface")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, _, _, _) = error else {
                return XCTFail("Expected commandFailed")
            }
            XCTAssertEqual(name, "AIRequestFailed")
        }
        XCTAssertEqual(env.rows().count, 2)
    }

    func testMalformedJSONStillRecordsOneFailure() async throws {
        let env = try AuditRecordEnv()
        defer { env.remove() }
        AuditChatURLProtocol.handler = { _ in (200, Data("not-json".utf8)) }
        do {
            _ = try await EngramServiceCommandHandler.ServiceAIClient.chat(
                purpose: "summary", sessionID: "session-a", config: Self.config,
                messages: [["role": "user", "content": "hello"]],
                urlSession: env.session, audit: env.recorder())
            XCTFail("Malformed JSON must not look like a successful chat")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, _, _, _) = error else {
                return XCTFail("Expected commandFailed")
            }
            XCTAssertEqual(name, "AIResponseInvalid")
        }
        XCTAssertEqual(env.rows().count, 1)
        XCTAssertNotNil(env.rows().first?.error)
    }

    func testDisabledAuditConfigInsertsNothing() async throws {
        let env = try AuditRecordEnv()
        defer { env.remove() }
        AuditChatURLProtocol.handler = { _ in (200, Self.successBody()) }
        _ = try await EngramServiceCommandHandler.ServiceAIClient.chat(
            purpose: "summary", sessionID: "session-a", config: Self.config,
            messages: [["role": "user", "content": "hello"]],
            urlSession: env.session,
            audit: env.recorder(enabled: false))
        XCTAssertEqual(env.rows().count, 0)
    }

    func testLogBodiesStoresRedactedTruncatedTextWhileWebKeepsFlagsOnly() async throws {
        let env = try AuditRecordEnv()
        defer { env.remove() }
        let secret = "sk-abcdefghijklmnopqrstuvwxyz"
        AuditChatURLProtocol.handler = { _ in
            (200, Self.successBody(content: "ok \(secret) extra-padding-for-truncation"))
        }
        _ = try await EngramServiceCommandHandler.ServiceAIClient.chat(
            purpose: "summary", sessionID: "session-a",
            config: Self.config,
            messages: [["role": "user", "content": "prompt \(secret)"]],
            urlSession: env.session,
            audit: env.recorder(logBodies: true, maxBodySize: 40))
        let row = try XCTUnwrap(env.rows().first)
        XCTAssertNotNil(row.requestBody)
        XCTAssertNotNil(row.responseBody)
        XCTAssertFalse((row.requestBody ?? "").contains(secret))
        XCTAssertFalse((row.responseBody ?? "").contains(secret))
        XCTAssertTrue((row.requestBody ?? "").contains("[REDACTED]")
                      || (row.responseBody ?? "").contains("[REDACTED]")
                      || (row.requestBody ?? "").contains("truncated")
                      || (row.responseBody ?? "").contains("truncated"))
        let producer = try env.producer()
        defer { try? producer.stop() }
        let detail = try await producer.aiAuditDetail(
            .init(id: String(try XCTUnwrap(row.id))),
            requestId: "AAAAAAAA-0000-4000-8000-000000000192",
            deadline: env.fixture.deadline())
        XCTAssertTrue(detail.hasRequestBody)
        XCTAssertTrue(detail.hasResponseBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        XCTAssertNil(object["requestBody"])
        XCTAssertNil(object["responseBody"])
    }

    func testWorkItemTitleStoresNullSession() async throws {
        let env = try AuditRecordEnv()
        defer { env.remove() }
        AuditChatURLProtocol.handler = { _ in (200, Self.successBody()) }
        _ = try await EngramServiceCommandHandler.ServiceAIClient.workItemTitle(
            intent: "intent", outcome: "outcome", config: Self.config,
            urlSession: env.session, audit: env.recorder())
        XCTAssertEqual(env.rows().count, 1)
        XCTAssertNil(env.rows().first?.sessionId)
        XCTAssertEqual(env.rows().first?.caller, "workItemTitle")
    }

    func testReadAuditConfigDoesNotNeedChatCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-audit-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = EngramServiceCommandHandler.ServiceAISettings.readAuditConfig(
            settingsPath: directory.appendingPathComponent("missing.json"),
            environment: ["CFFIXED_USER_HOME": directory.path, "HOME": directory.path])
        XCTAssertEqual(missing, .default)
        let settings = directory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: [
            "aiApiKey": "@keychain",
            "titleApiKey": "@keychain",
            "aiAudit": ["enabled": true, "logBodies": false, "maxBodySize": 10_000],
        ]).write(to: settings)
        XCTAssertEqual(chmod(settings.path, 0o600), 0)
        let loaded = EngramServiceCommandHandler.ServiceAISettings.readAuditConfig(
            settingsPath: settings,
            environment: ["CFFIXED_USER_HOME": directory.path, "HOME": directory.path])
        XCTAssertEqual(loaded, .default)
        let env = try AuditRecordEnv()
        defer { env.remove() }
        let recorder = ServiceAIAuditRecorder(writerGate: env.gate, auditConfig: {
            EngramServiceCommandHandler.ServiceAISettings.readAuditConfig(settingsPath: settings)
        })
        await recorder.record(ServiceAIAuditEntry(
            caller: "summary", operation: "chat", method: "POST", url: "https://engram-ai.test/v1",
            statusCode: 200, durationMs: 1, model: "demo-chat", provider: "synthetic",
            promptTokens: 1, completionTokens: 1, totalTokens: 2, error: nil,
            sessionId: nil, requestBody: nil, responseBody: nil))
        XCTAssertEqual(env.rows().count, 1)
    }

    func testNonIntegerOrOutOfRangeUsageIsStoredAsUnknown() async throws {
        let env = try AuditRecordEnv()
        defer { env.remove() }
        AuditChatURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1.5,"completion_tokens":-3,"total_tokens":1e308}}"#.utf8))
        }
        _ = try await EngramServiceCommandHandler.ServiceAIClient.chat(
            purpose: "summary", sessionID: "session-a", config: Self.config,
            messages: [["role": "user", "content": "hello"]],
            urlSession: env.session, audit: env.recorder())
        let row = try XCTUnwrap(env.rows().first)
        XCTAssertNil(row.promptTokens)
        XCTAssertNil(row.completionTokens)
        XCTAssertNil(row.totalTokens)
    }

    private static let config = EngramServiceCommandHandler.ServiceAISettings.ChatConfig(
        provider: "synthetic", baseURL: "https://engram-ai.test/v1",
        apiKey: "synthetic-test-key", model: "demo-chat", maxTokens: 100, temperature: 0)

    private static func successBody(
        content: String = "Synthetic captured summary",
        prompt: Int = 120, completion: Int = 30, total: Int = 150
    ) -> Data {
        Data("""
        {"choices":[{"message":{"content":"\(content)"}}],"usage":{"prompt_tokens":\(prompt),"completion_tokens":\(completion),"total_tokens":\(total)}}
        """.utf8)
    }
}

private struct AuditRow {
    let id: Int64
    let caller: String
    let operation: String
    let method: String?
    let model: String?
    let promptTokens: Int64?
    let completionTokens: Int64?
    let totalTokens: Int64?
    let error: String?
    let sessionId: String?
    let requestBody: String?
    let responseBody: String?
}

private final class AuditRecordEnv {
    let fixture: MetadataSQLFixture
    let gate: ServiceWriterGate
    let session: URLSession

    init() throws {
        fixture = try MetadataSQLFixture()
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "session-a", start: "2026-09-01 12:00:00")
        let runtime = fixture.directory.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        gate = try ServiceWriterGate(databasePath: fixture.path, runtimeDirectory: runtime)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditChatURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func remove() {
        session.invalidateAndCancel()
        AuditChatURLProtocol.handler = nil
        fixture.remove()
    }

    func recorder(
        enabled: Bool = true, logBodies: Bool = false, maxBodySize: Int = 10_000
    ) -> ServiceAIAuditRecorder {
        ServiceAIAuditRecorder(writerGate: gate) {
            .init(enabled: enabled, logBodies: logBodies, maxBodySize: maxBodySize)
        }
    }

    func producer() throws -> ServiceWebMetadataProducer { try fixture.producer() }

    func rows() -> [AuditRow] {
        var rows: [AuditRow] = []
        do {
            try fixture.write { db in
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, caller, operation, method, model, prompt_tokens, completion_tokens,
                           total_tokens, error, session_id, request_body, response_body
                    FROM ai_audit_log ORDER BY id
                    """).map { row in
                    AuditRow(id: row["id"], caller: row["caller"], operation: row["operation"],
                             method: row["method"], model: row["model"],
                             promptTokens: row["prompt_tokens"], completionTokens: row["completion_tokens"],
                             totalTokens: row["total_tokens"], error: row["error"],
                             sessionId: row["session_id"], requestBody: row["request_body"],
                             responseBody: row["response_body"])
                }
            }
        } catch {
            XCTFail("audit rows: \(error)")
        }
        return rows
    }
}

private final class AuditChatURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
    private static var storage: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler?(request) ?? (500, Data())
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
