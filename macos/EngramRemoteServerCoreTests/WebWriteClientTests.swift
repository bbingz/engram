import Darwin
import Foundation
import XCTest
@testable import EngramRemoteServerCore

final class WebWriteClientTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("eg-d4-w-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testAllowlistRejectsUnknownCommandsWithoutIPC() throws {
        XCTAssertEqual(EngramServiceWebWriteClient.allowedCommands,
                       ["webAddProjectAlias", "webRemoveProjectAlias", "webSetSourceEnabled",
                        "webLinkSession", "webUnlinkSession", "webConfirmSuggestion", "webDismissSuggestion",
                        "webSaveInsight", "webGenerateSummary", "webGenerateTitle", "webRegenerateTitles",
                        "webPatchAiSettings", "webProjectMigrations", "webProjectMove", "webProjectArchive",
                        "webProjectUndo", "webProjectMoveBatch", "webCancelProjectMoveBatch"])
        XCTAssertNoThrow(try EngramServiceWebWriteClient.validateCommand("webAddProjectAlias"))
        XCTAssertNoThrow(try EngramServiceWebWriteClient.validateCommand("webRemoveProjectAlias"))
        XCTAssertNoThrow(try EngramServiceWebWriteClient.validateCommand("webSetSourceEnabled"))
        XCTAssertNoThrow(try EngramServiceWebWriteClient.validateCommand("webSaveInsight"))
        XCTAssertNoThrow(try EngramServiceWebWriteClient.validateCommand("webGenerateSummary"))
        XCTAssertNoThrow(try EngramServiceWebWriteClient.validateCommand("webRegenerateTitles"))
        XCTAssertNoThrow(try EngramServiceWebWriteClient.validateCommand("webPatchAiSettings"))
        for command in ["webSettings", "webSourceSettings", "webAiSettings", "manageProjectAlias", "setSourceEnabled", "saveInsight", "generateSummary", "regenerateAllTitles", "webCosts", ""] {
            XCTAssertThrowsError(try EngramServiceWebWriteClient.validateCommand(command)) {
                XCTAssertEqual($0 as? EngramServiceWebWriteClientError, .unsupported)
            }
        }
    }

    func testAddAliasAttachesLocalTokenAndNeverPutsItOnHTTPJSON() async throws {
        let path = directory.appendingPathComponent("service.sock").path
        let token = "d4-capability-token-fixture"
        try writeToken(token, socketPath: path)
        let published = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey("/old/engram"))
        let mutation = try EngramServiceWebAliasMutationResponse(
            action: "add", alias: published, canonical: "project_1", changed: 1
        )
        let server = try WriteSocketFixture(path: path) { fd, bytes in
            let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
            XCTAssertEqual(incoming.command, "webAddProjectAlias")
            XCTAssertEqual(incoming.capabilityToken, token)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(object["capability_token"] as? String, token)
            let payload = try JSONDecoder().decode(
                EngramServiceWebAddAliasRequest.self, from: try XCTUnwrap(incoming.payload)
            )
            XCTAssertEqual(payload.alias, "/old/engram")
            XCTAssertEqual(payload.canonical, "project_1")
            let envelope = EngramServiceResponseEnvelope.success(
                requestId: incoming.requestId, result: try JSONEncoder().encode(mutation)
            )
            try EngramServiceSocketIO.writeFrame(try JSONEncoder().encode(envelope), to: fd, requestTimeout: 1)
        }
        defer { server.stop() }
        let result = try await EngramServiceWebWriteClient(socketPath: path).addAlias(
            EngramServiceWebAddAliasRequest(canonical: "project_1", alias: "/old/engram")
        )
        XCTAssertEqual(result, mutation)
        let http = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: http, as: UTF8.self).contains("capability_token"))
        XCTAssertFalse(String(decoding: http, as: UTF8.self).contains(token))
    }

    func testMissingTokenDoesNotOpenIPC() async throws {
        let path = directory.appendingPathComponent("missing.sock").path
        let server = try WriteSocketFixture(path: path) { _, _ in
            XCTFail("Missing token must not perform IPC")
        }
        defer { server.stop() }
        do {
            _ = try await EngramServiceWebWriteClient(socketPath: path).addAlias(
                EngramServiceWebAddAliasRequest(canonical: "project_1", alias: "/old/engram")
            )
            XCTFail("Expected unavailable")
        } catch {
            XCTAssertEqual(error as? EngramServiceWebWriteClientError, .unavailable)
        }
        XCTAssertEqual(server.requestCount, 0)
    }

    func testRelationshipCommandsCarryCapabilityAndScopedPayload() async throws {
        for (command, action) in [("webLinkSession", "link"), ("webUnlinkSession", "unlink"),
                                  ("webConfirmSuggestion", "confirmSuggestion"), ("webDismissSuggestion", "dismissSuggestion")] {
            XCTAssertTrue(ServiceCapabilityToken.requiresToken(command))
            let path = directory.appendingPathComponent("\(action).sock").path
            try writeToken("relationship-local-capability", socketPath: path)
            let server = try WriteSocketFixture(path: path) { fd, bytes in
                let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
                XCTAssertEqual(incoming.command, command)
                XCTAssertEqual(incoming.capabilityToken, "relationship-local-capability")
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(incoming.payload)) as? [String: Any])
                XCTAssertEqual(payload["sessionId"] as? String, "child")
                if action == "link" { XCTAssertEqual(payload["parentId"] as? String, "parent") }
                if action == "confirmSuggestion" || action == "dismissSuggestion" {
                    XCTAssertEqual(payload["suggestedParentId"] as? String, "parent")
                }
                let response = try EngramServiceWebRelationshipMutationResponse(sessionId: "child", action: action, ok: true)
                let envelope = EngramServiceResponseEnvelope.success(requestId: incoming.requestId, result: try JSONEncoder().encode(response))
                try EngramServiceSocketIO.writeFrame(try JSONEncoder().encode(envelope), to: fd, requestTimeout: 1)
            }
            defer { server.stop() }
            let client = try EngramServiceWebWriteClient(socketPath: path)
            let result: EngramServiceWebRelationshipMutationResponse
            switch action {
            case "link": result = try await client.link(.init(sessionId: "child", parentId: "parent"))
            case "unlink": result = try await client.unlink(.init(sessionId: "child"))
            case "confirmSuggestion": result = try await client.confirmSuggestion(.init(sessionId: "child", suggestedParentId: "parent"))
            default: result = try await client.dismissSuggestion(.init(sessionId: "child", suggestedParentId: "parent"))
            }
            XCTAssertEqual(result.action, action)
            XCTAssertEqual(result.sessionId, "child")
        }
    }

    func testRelationshipReplyCannotClaimAnotherSessionChanged() async throws {
        let path = directory.appendingPathComponent("wrong-session.sock").path
        try writeToken("relationship-local-capability", socketPath: path)
        let server = try WriteSocketFixture(path: path) { fd, bytes in
            let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
            let result = try EngramServiceWebRelationshipMutationResponse(sessionId: "other", action: "unlink", ok: true)
            let envelope = EngramServiceResponseEnvelope.success(requestId: incoming.requestId, result: try JSONEncoder().encode(result))
            try EngramServiceSocketIO.writeFrame(try JSONEncoder().encode(envelope), to: fd, requestTimeout: 1)
        }
        defer { server.stop() }
        do {
            _ = try await EngramServiceWebWriteClient(socketPath: path).unlink(.init(sessionId: "child"))
            XCTFail("Mismatched session must fail")
        } catch {
            XCTAssertEqual(error as? EngramServiceWebWriteClientError, .malformed)
        }
    }

    func testSaveInsightAttachesLocalTokenAndRejectsSaveInsightProxy() async throws {
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("webSaveInsight"))
        XCTAssertFalse(EngramServiceWebWriteClient.allowedCommands.contains("saveInsight"))
        let path = directory.appendingPathComponent("insight.sock").path
        try writeToken("insight-local-capability", socketPath: path)
        let saved = try EngramServiceWebSaveInsightResponse(id: "insight-saved", warning: "Saved without embedding")
        let server = try WriteSocketFixture(path: path) { fd, bytes in
            let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
            XCTAssertEqual(incoming.command, "webSaveInsight")
            XCTAssertEqual(incoming.capabilityToken, "insight-local-capability")
            let payload = try JSONDecoder().decode(
                EngramServiceWebSaveInsightRequest.self, from: try XCTUnwrap(incoming.payload))
            XCTAssertEqual(payload.content, "library note from web save")
            XCTAssertEqual(payload.sourceSessionId, "one")
            let envelope = EngramServiceResponseEnvelope.success(
                requestId: incoming.requestId, result: try JSONEncoder().encode(saved))
            try EngramServiceSocketIO.writeFrame(try JSONEncoder().encode(envelope), to: fd, requestTimeout: 1)
        }
        defer { server.stop() }
        let result = try await EngramServiceWebWriteClient(socketPath: path).saveInsight(
            try EngramServiceWebSaveInsightRequest(
                content: "library note from web save", sourceSessionId: "one")
        )
        XCTAssertEqual(result.id, "insight-saved")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("capability_token"))
    }

    func testGenerateSummaryAttachesLocalTokenAndRejectsNativeProxy() async throws {
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("webGenerateSummary"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("webGenerateTitle"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("webRegenerateTitles"))
        XCTAssertFalse(EngramServiceWebWriteClient.allowedCommands.contains("generateSummary"))
        XCTAssertFalse(EngramServiceWebWriteClient.allowedCommands.contains("regenerateAllTitles"))
        let path = directory.appendingPathComponent("generate.sock").path
        try writeToken("generate-local-capability", socketPath: path)
        let generation = String(repeating: "ab", count: 32)
        let saved = try EngramServiceWebGenerateSummaryResponse(
            sessionId: "one", generation: generation,
            summary: String(repeating: "Generated constellation summary. ", count: 10)
        )
        let server = try WriteSocketFixture(path: path) { fd, bytes in
            let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
            XCTAssertEqual(incoming.command, "webGenerateSummary")
            XCTAssertEqual(incoming.capabilityToken, "generate-local-capability")
            let payload = try JSONDecoder().decode(
                EngramServiceWebGenerateSummaryRequest.self, from: try XCTUnwrap(incoming.payload))
            XCTAssertEqual(payload.sessionId, "one")
            XCTAssertEqual(payload.generation, generation)
            let envelope = EngramServiceResponseEnvelope.success(
                requestId: incoming.requestId, result: try JSONEncoder().encode(saved))
            try EngramServiceSocketIO.writeFrame(try JSONEncoder().encode(envelope), to: fd, requestTimeout: 1)
        }
        defer { server.stop() }
        let result = try await EngramServiceWebWriteClient(socketPath: path).generateSummary(
            try EngramServiceWebGenerateSummaryRequest(sessionId: "one", generation: generation)
        )
        XCTAssertEqual(result.summary, saved.summary)
        XCTAssertGreaterThan(try XCTUnwrap(result.summary).count, 200)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("capability_token"))
    }

    func testPatchAiSettingsAttachesLocalTokenAndRejectsSecretProxy() async throws {
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("webPatchAiSettings"))
        XCTAssertFalse(EngramServiceWebWriteClient.allowedCommands.contains("webAiSettings"))
        let path = directory.appendingPathComponent("ai-settings.sock").path
        try writeToken("ai-settings-local-capability", socketPath: path)
        let saved = try EngramServiceWebAiSettingsResponse(settings: EngramServiceWebAiSettings(
            aiProtocol: "openai",
            aiBaseURL: "https://api.openai.com",
            aiModel: "fixture-summary-model",
            summaryLanguage: "中文",
            summaryMaxSentences: 3,
            summaryStyle: "",
            summaryPrompt: "Decisions\nNext steps",
            summaryMaxTokens: 800,
            summaryTemperature: 0.3,
            summarySampleFirst: 20,
            summarySampleLast: 30,
            summaryTruncateChars: 500,
            summaryPreset: "standard",
            titleProvider: "ollama",
            titleBaseUrl: "http://localhost:11434",
            titleBaseURL: "http://localhost:11434",
            titleModel: "gpt-4o-mini",
            embeddingBaseURL: "https://api.openai.com/v1",
            embeddingModel: "text-embedding-3-small",
            embeddingDimension: 1536,
            embeddingIncludeDimensions: false,
            aiAudit: EngramServiceWebAiSettingsAudit(enabled: true, logBodies: false, maxBodySize: 10_000)
        ))
        let server = try WriteSocketFixture(path: path) { fd, bytes in
            let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
            XCTAssertEqual(incoming.command, "webPatchAiSettings")
            XCTAssertEqual(incoming.capabilityToken, "ai-settings-local-capability")
            let payload = try JSONDecoder().decode(
                EngramServiceWebPatchAiSettingsRequest.self, from: try XCTUnwrap(incoming.payload)
            )
            XCTAssertEqual(payload.aiModel, "fixture-summary-model")
            XCTAssertEqual(payload.summaryPrompt, "Decisions\nNext steps")
            let envelope = EngramServiceResponseEnvelope.success(
                requestId: incoming.requestId, result: try JSONEncoder().encode(saved)
            )
            try EngramServiceSocketIO.writeFrame(try JSONEncoder().encode(envelope), to: fd, requestTimeout: 1)
        }
        defer { server.stop() }
        let result = try await EngramServiceWebWriteClient(socketPath: path).patchAiSettings(
            try EngramServiceWebPatchAiSettingsRequest(
                aiModel: "fixture-summary-model", summaryPrompt: "Decisions\nNext steps"
            )
        )
        XCTAssertEqual(result.settings.aiModel, "fixture-summary-model")
        XCTAssertEqual(result.settings.summaryPrompt, "Decisions\nNext steps")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("capability_token"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("aiApiKey"))
    }

    private func writeToken(_ token: String, socketPath: String) throws {
        let path = ServiceCapabilityToken.path(forSocketPath: socketPath)
        try Data(token.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

private final class WriteSocketFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private let path: String
    private var listener: Int32
    private var peer: Int32?
    private var stopped = false
    private var requests = 0
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }

    init(path: String, handler: @escaping @Sendable (Int32, Data) throws -> Void) throws {
        self.path = path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw WriteFixtureFailure() }
        do {
            try EngramServiceSocketIO.withSockAddr(path: path) {
                guard Darwin.bind(listener, $0, $1) == 0 else { throw WriteFixtureFailure() }
            }
            guard chmod(path, 0o600) == 0, listen(listener, 1) == 0,
                  fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw WriteFixtureFailure() }
        } catch { close(listener); throw error }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer {
                lock.lock()
                if let peer { close(peer); self.peer = nil }
                close(listener)
                listener = -1
                lock.unlock()
                group.leave()
            }
            while true {
                lock.lock()
                let shouldStop = stopped
                lock.unlock()
                if shouldStop { return }
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 50) < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let fd = accept(listener, nil, nil)
                if fd < 0 { continue }
                lock.lock()
                peer = fd
                lock.unlock()
                do {
                    let flags = fcntl(fd, F_GETFL)
                    guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw WriteFixtureFailure() }
                    try EngramServiceSocketIO.disableSigPipe(fd)
                    try EngramServiceSocketIO.setSocketTimeout(fd, seconds: 1)
                    let data = try EngramServiceSocketIO.readFrame(from: fd, requestTimeout: 1)
                    lock.lock(); requests += 1; lock.unlock()
                    try handler(fd, data)
                } catch {}
                return
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        if let peer { _ = shutdown(peer, SHUT_RDWR) }
        if listener >= 0 { _ = shutdown(listener, SHUT_RDWR) }
        lock.unlock()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        try? FileManager.default.removeItem(atPath: path)
    }
}

private struct WriteFixtureFailure: Error {}
