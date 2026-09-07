import CryptoKit
import Darwin
import EngramCoreRead
import EngramCoreWrite
import Foundation
import XCTest
@testable import EngramServiceCore

final class WebTranscriptIPCTests: XCTestCase {
    private static let generation = String(repeating: "a", count: 64)
    private static let sessionID = "central/session"

    func testRealSocketRoutesTypedReadWithoutCapabilityOrWriterMutation() async throws {
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([.init(role: .user, content: "hello")]))
        let fixture = try makeHarness(provider: provider)
        let before = await fixture.gate.currentDatabaseGeneration()
        guard let page = await readPage(fixture, request: try Self.request()) else { return }
        XCTAssertEqual(page.sessionId, Self.sessionID)
        XCTAssertEqual(page.generation, Self.generation)
        XCTAssertTrue(page.isComplete)
        let requests = await fixture.requests.values()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.command, "webMessages")
        XCTAssertNotNil(requests.first.flatMap { UUID(uuidString: $0.requestID) })
        XCTAssertTrue(requests.allSatisfy { !$0.hasCapability })
        let after = await fixture.gate.currentDatabaseGeneration()
        XCTAssertEqual(after, before)
        let observations = await provider.observations()
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.sessionID, Self.sessionID)
        XCTAssertEqual(observations.first?.generation, Self.generation)
        XCTAssertGreaterThan(try XCTUnwrap(observations.first?.remainingSeconds), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(observations.first?.remainingSeconds), 2)
    }

    func testDefaultProviderIsExplicitlyUnavailableThroughRealSocket() async throws {
        let fixture = try makeHarness()
        await expectClientError(.unavailable) { try await fixture.client.messages(Self.request()) }
        let response = try await rawExchange(fixture, payload: JSONEncoder().encode(Self.request()))
        assertFailure(response, name: "ServiceUnavailable")
    }

    func testUnknownLocatorCommandAndBudgetFieldsFailBeforeProvider() async throws {
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([]))
        let fixture = try makeHarness(provider: provider)
        for key in ["locator", "filePath", "command", "capabilityToken", "source", "deadline", "includeHidden"] {
            var object = try Self.requestObject()
            object[key] = "secret-/private/fixture"
            let response = try await rawExchange(fixture, payload: JSONSerialization.data(withJSONObject: object))
            assertFailure(response, name: "InvalidRequest")
        }
        let observations = await provider.observations()
        XCTAssertTrue(observations.isEmpty)
    }

    func testMalformedAndMissingTypedFieldsFailBeforeProvider() async throws {
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([]))
        let fixture = try makeHarness(provider: provider)
        var missing = try Self.requestObject()
        missing.removeValue(forKey: "generation")
        var uppercase = try Self.requestObject()
        uppercase["generation"] = String(repeating: "A", count: 64)
        var duplicateRoles = try Self.requestObject()
        duplicateRoles["roles"] = ["user", "user"]
        let invalid: [Data?] = [nil, Data("not-json".utf8), Data("[]".utf8),
                                try JSONSerialization.data(withJSONObject: missing),
                                try JSONSerialization.data(withJSONObject: uppercase),
                                try JSONSerialization.data(withJSONObject: duplicateRoles)]
        for payload in invalid {
            assertFailure(try await rawExchange(fixture, payload: payload), name: "InvalidRequest")
        }
        let observations = await provider.observations()
        XCTAssertTrue(observations.isEmpty)
    }

    func testRequestIdentityIsPassedByteExactlyAndSnapshotMismatchIsStale() async throws {
        let requestedID = "central/cafe\u{301}"
        let selectedID = "central/caf\u{e9}"
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([], sessionID: selectedID))
        let fixture = try makeHarness(provider: provider)
        await expectClientError(.stale) { try await fixture.client.messages(Self.request(sessionID: requestedID)) }
        let observations = await provider.observations()
        XCTAssertEqual(observations.first.map { Data($0.sessionID.utf8) }, Data(requestedID.utf8))
        XCTAssertNotEqual(Data(requestedID.utf8), Data(selectedID.utf8))
    }

    func testMissingLastGoodAndMismatchedGenerationAreStaleWithoutFallback() async throws {
        let provider = WebIPCSnapshotFixture(snapshot: nil)
        let fixture = try makeHarness(provider: provider)
        await expectClientError(.stale) { try await fixture.client.messages(Self.request()) }
        await provider.replace(Self.snapshot([.init(role: .user, content: "new")], generation: String(repeating: "b", count: 64)))
        await expectClientError(.stale) { try await fixture.client.messages(Self.request()) }
        let observations = await provider.observations()
        XCTAssertEqual(observations.count, 2)
    }

    func testContinuationRevalidatesGenerationInsteadOfReusingOldSnapshot() async throws {
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([
            .init(role: .user, content: "first"), .init(role: .assistant, content: "second"),
        ]))
        let fixture = try makeHarness(provider: provider)
        guard let first = await readPage(fixture, request: try Self.request(maxFragments: 1)),
              let cursor = first.nextCursor else { return XCTFail("Expected a continuation") }
        await provider.replace(Self.snapshot([.init(role: .user, content: "replacement")], generation: String(repeating: "b", count: 64)))
        await expectClientError(.stale) { try await fixture.client.messages(Self.request(cursor: cursor, maxFragments: 1)) }
        let observations = await provider.observations()
        XCTAssertEqual(observations.count, 2)
    }

    func testEveryContinuationRevalidatesHiddenSkipAndPrivacyEligibility() async throws {
        for eligibility in [WebIPCSnapshotFixture.Eligibility.hidden, .skip, .withheld] {
            let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([
                .init(role: .user, content: "first"), .init(role: .assistant, content: "second"),
            ]))
            let fixture = try makeHarness(provider: provider)
            guard let first = await readPage(fixture, request: try Self.request(maxFragments: 1)),
                  let cursor = first.nextCursor else { return XCTFail("Expected a continuation") }
            await provider.setEligibility(eligibility)
            await expectClientError(.unavailable) { try await fixture.client.messages(Self.request(cursor: cursor, maxFragments: 1)) }
            let observations = await provider.observations()
            XCTAssertEqual(observations.count, 2, "Eligibility must be checked even after a successful page")
        }
    }

    func testAllRolesToolsUsageAndLargeUnicodeReconstructAcrossActualFrames() async throws {
        let large = String(repeating: "界👩🏽‍💻e\u{301}\"\\\n", count: 7_000)
        XCTAssertGreaterThan(large.utf8.count, 160 * 1024)
        let messages = [
            NormalizedMessage(role: .system, content: ""),
            NormalizedMessage(role: .user, content: "<system-reminder>literal</system-reminder>"),
            NormalizedMessage(role: .assistant, content: large, timestamp: "2026-09-06T00:00:00Z",
                              toolCalls: [.init(name: "tool", input: large, output: "result")],
                              usage: .init(inputTokens: 11, outputTokens: 22, cacheReadTokens: 3, cacheCreationTokens: 4)),
            NormalizedMessage(role: .tool, content: "tool result"),
        ]
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot(messages))
        let fixture = try makeHarness(provider: provider)
        guard let pages = await collectPages(fixture, maxFragments: 1) else { return }
        XCTAssertGreaterThan(pages.count, messages.count)
        XCTAssertTrue(pages.dropLast().allSatisfy { !$0.isComplete && $0.nextCursor != nil })
        XCTAssertTrue(try XCTUnwrap(pages.last).isComplete)
        try assertReconstruction(pages, messages: messages)
        let records = await fixture.requests.values()
        XCTAssertEqual(records.count, pages.count)
        XCTAssertTrue(records.allSatisfy { !$0.hasCapability })
        let observations = await provider.observations()
        XCTAssertEqual(observations.count, pages.count)
    }

    func testRedactionPrecedesWireFragmentationForEveryStringField() async throws {
        let secret = "-----BEGIN PRIVATE KEY-----\n" + String(repeating: "PRIVATEBODY", count: 4_000)
            + "\n-----END PRIVATE KEY-----"
        let message = NormalizedMessage(
            role: .tool, content: String(repeating: "prefix ", count: 30_000) + secret,
            timestamp: "sk-timestampsecret12345",
            toolCalls: [.init(name: "ghp_toolnamesecret12345", input: "token=toolinputsecret12345", output: secret)]
        )
        let fixture = try makeHarness(provider: WebIPCSnapshotFixture(snapshot: Self.snapshot([message])))
        guard let pages = await collectPages(fixture) else { return }
        XCTAssertGreaterThan(pages.count, 1)
        let wire = pages.flatMap(\.fragments).map(\.payloadFragment).joined()
        for forbidden in ["PRIVATEBODY", "BEGIN PRIVATE", "timestampsecret", "toolnamesecret", "toolinputsecret"] {
            XCTAssertFalse(wire.contains(forbidden), forbidden)
        }
        XCTAssertTrue(wire.contains("[REDACTED]"))
        try assertReconstruction(pages, messages: [message])
    }

    func testRoleFilteredPagesKeepSourceOrdinalsAndRepeatSameCursorContent() async throws {
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([
            .init(role: .user, content: "zero"), .init(role: .assistant, content: "one"),
            .init(role: .system, content: "two"), .init(role: .tool, content: "three"),
        ]))
        let fixture = try makeHarness(provider: provider)
        let roles: [EngramServiceWebMessageRole] = [.assistant, .tool]
        guard let first = await readPage(fixture, request: try Self.request(roles: roles, maxFragments: 1)),
              let cursor = first.nextCursor else { return XCTFail("Expected a continuation") }
        XCTAssertEqual(first.fragments.map(\.messageOrdinal), [1])
        let next = try Self.request(roles: roles, cursor: cursor, maxFragments: 1)
        guard let second = await readPage(fixture, request: next),
              let repeated = await readPage(fixture, request: next) else { return }
        XCTAssertEqual(second.fragments.map(\.messageOrdinal), [3])
        XCTAssertEqual(second, repeated)
        XCTAssertTrue(second.isComplete)
    }

    func testPartialSourceMetadataCannotBecomeCompleteAtPageEOF() async throws {
        var partial = Self.snapshot([.init(role: .assistant, content: "prefix")])
        partial.totalKnownComplete = false
        partial.truncatedAt = 100
        partial.parseFailure = .messageLimitExceeded
        let fixture = try makeHarness(provider: WebIPCSnapshotFixture(snapshot: partial))
        guard let page = await readPage(fixture, request: try Self.request()) else { return }
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.totalKnownComplete)
        XCTAssertFalse(page.isComplete)
        XCTAssertEqual(page.truncatedAt, 100)
        XCTAssertEqual(page.parseFailure, "messageLimitExceeded")
    }

    func testProviderDiagnosticsNeverEscapeTheSafeWireCategory() async throws {
        let provider = WebIPCSnapshotFixture(snapshot: nil, behavior: .failWithPrivateDiagnostic)
        let fixture = try makeHarness(provider: provider)
        let response = try await rawExchange(fixture, payload: JSONEncoder().encode(Self.request()))
        assertFailure(response, name: "ServiceUnavailable")
        await expectClientError(.unavailable) { try await fixture.client.messages(Self.request()) }
    }

    func testProviderDeadlineCannotBeRenewedBeforePaging() async throws {
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([.init(role: .user, content: "late")]), behavior: .returnAfterDeadline)
        let fixture = try makeHarness(provider: provider)
        let started = ContinuousClock.now
        // A diagnostic raw peer waits longer than the fixed Web client so it
        // can observe the handler rejecting a late provider result itself.
        let response = try await rawExchange(fixture, payload: JSONEncoder().encode(Self.request()), timeout: 3)
        assertFailure(response, name: "ServiceUnavailable")
        let observations = await provider.observations()
        XCTAssertEqual(observations.count, 1)
        guard let observation = observations.first else { return XCTFail("Expected provider deadline observation") }
        XCTAssertLessThanOrEqual(observation.remainingSeconds, 2)
        XCTAssertGreaterThan(Self.elapsed(started), 1.9)
        XCTAssertLessThan(Self.elapsed(started), 2.8)
    }

    func testPeerCancellationStopsCooperativeProviderWithoutWriterMutation() async throws {
        let entered = expectation(description: "provider entered")
        let cancelled = expectation(description: "provider cooperatively cancelled")
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([]), behavior: .waitForCancellation,
                                             entered: entered, cancelled: cancelled)
        let fixture = try makeHarness(provider: provider)
        let before = await fixture.gate.currentDatabaseGeneration()
        let task = Task { try await fixture.client.messages(Self.request()) }
        await fulfillment(of: [entered], timeout: 0.8)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected CancellationError") }
        catch is CancellationError {}
        catch { XCTFail("Cancellation must keep its safe category") }
        await fulfillment(of: [cancelled], timeout: 0.8)
        let after = await fixture.gate.currentDatabaseGeneration()
        XCTAssertEqual(after, before)
    }

    func testOwnerOnlySocketBoundaryAndReadCapabilityContractRemainIntact() async throws {
        let provider = WebIPCSnapshotFixture(snapshot: Self.snapshot([]))
        let fixture = try makeHarness(provider: provider)
        var parent = stat()
        var socket = stat()
        XCTAssertEqual(lstat(fixture.root.path, &parent), 0)
        XCTAssertEqual(lstat(fixture.socketPath, &socket), 0)
        XCTAssertEqual(parent.st_uid, geteuid())
        XCTAssertEqual(parent.st_mode & 0o777, 0o700)
        XCTAssertEqual(socket.st_uid, geteuid())
        XCTAssertEqual(socket.st_mode & 0o777, 0o600)
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("webMessages"))
        var peers: [Int32] = [-1, -1]
        XCTAssertEqual(peers.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!) }, 0)
        defer { for fd in peers where fd >= 0 { close(fd) } }
        XCTAssertTrue(UnixSocketServiceServer.peerIsAuthorized(peers[0], serviceEuid: geteuid()))
        XCTAssertFalse(UnixSocketServiceServer.peerIsAuthorized(peers[0], serviceEuid: geteuid() == 0 ? 1 : 0))
        XCTAssertEqual(chmod(fixture.socketPath, 0o666), 0)
        await expectClientError(.unavailable) { try await fixture.client.messages(Self.request()) }
        let observations = await provider.observations()
        XCTAssertTrue(observations.isEmpty, "Unsafe inode must fail before dispatch")
        XCTAssertEqual(lstat(fixture.socketPath, &socket), 0)
        XCTAssertEqual(socket.st_mode & 0o777, 0o666, "Client must not repair socket permissions")
    }

    func testWebSnapshotSurfaceDoesNotReachLegacyReadersPathsOrTokenLoaders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["EngramService/Core/ServiceWebTranscriptSnapshotProvider.swift",
                     "EngramService/Core/EngramServiceCommandHandler+WebTranscript.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for forbidden in ["ServiceCapabilityToken", "EngramServiceClient(", "replayTimeline(",
                              "archiveReadSessionPage", "ParsedTranscriptCache", "filePath:",
                              "Data(contentsOf:", "FileManager", "sessions_fts", "performWriteCommand",
                              "Task.detached", "withTaskGroup", "withThrowingTaskGroup"] {
                XCTAssertFalse(source.contains(forbidden), "\(path): \(forbidden)")
            }
        }
    }

    private func makeHarness(
        provider: any ServiceWebTranscriptSnapshotProviding = UnavailableServiceWebTranscriptSnapshotProvider()
    ) throws -> WebIPCHarness {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-web-ipc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let gate = try ServiceWriterGate(databasePath: root.appendingPathComponent("index.sqlite").path, runtimeDirectory: root)
        let handler = EngramServiceCommandHandler(writerGate: gate, webTranscriptSnapshotProvider: provider)
        let requests = WebIPCRequestLog()
        let socketPath = root.appendingPathComponent("service.sock").path
        let server = UnixSocketServiceServer(socketPath: socketPath) { request in
            await requests.append(request)
            return await handler.handle(request)
        }
        try server.start()
        let fixture = try WebIPCHarness(root: root, socketPath: socketPath, gate: gate, server: server, requests: requests)
        addTeardownBlock { try await fixture.finish() }
        return fixture
    }

    private func readPage(_ fixture: WebIPCHarness, request: EngramServiceWebMessagesRequest,
                          file: StaticString = #filePath, line: UInt = #line) async -> EngramServiceWebMessagesResponse? {
        do { return try await fixture.client.messages(request) }
        catch { XCTFail("Expected a valid typed Web page", file: file, line: line); return nil }
    }

    private func collectPages(_ fixture: WebIPCHarness, maxFragments: Int = 50) async -> [EngramServiceWebMessagesResponse]? {
        var pages: [EngramServiceWebMessagesResponse] = []
        var cursor: String?
        do {
            for _ in 0..<50 {
                guard let page = await readPage(fixture, request: try Self.request(cursor: cursor, maxFragments: maxFragments)) else { return nil }
                pages.append(page)
                guard let next = page.nextCursor else { return pages }
                XCTAssertNotEqual(next, cursor)
                cursor = next
            }
            XCTFail("Continuation failed to make bounded progress")
        } catch { XCTFail("Fixture request was invalid") }
        return nil
    }

    private func rawExchange(_ fixture: WebIPCHarness, payload: Data?, timeout: TimeInterval = 2) async throws -> EngramServiceResponseEnvelope {
        let request = EngramServiceRequestEnvelope(command: "webMessages", payload: payload, capabilityToken: nil)
        let bytes = try await EngramServiceSocketIO.exchange(JSONEncoder().encode(request), socketPath: fixture.socketPath, totalTimeout: timeout)
        let response = try JSONDecoder().decode(EngramServiceResponseEnvelope.self, from: bytes)
        XCTAssertEqual(response.requestId, request.requestId)
        return response
    }

    private func assertFailure(_ response: EngramServiceResponseEnvelope, name: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(_, let error) = response else { return XCTFail("Expected \(name)", file: file, line: line) }
        XCTAssertEqual(error.name, name, file: file, line: line)
        let diagnostics = error.message + String(describing: error.details)
        for forbidden in ["secret", "/private/fixture", "locator", "filePath", "capabilityToken"] {
            XCTAssertFalse(diagnostics.contains(forbidden), file: file, line: line)
        }
    }

    private func expectClientError(_ expected: EngramServiceWebReadClientError,
                                   file: StaticString = #filePath, line: UInt = #line,
                                   _ operation: () async throws -> EngramServiceWebMessagesResponse) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as EngramServiceWebReadClientError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error category", file: file, line: line) }
    }

    private func assertReconstruction(_ pages: [EngramServiceWebMessagesResponse], messages: [NormalizedMessage]) throws {
        let fragments = pages.flatMap(\.fragments)
        for (ordinal, message) in messages.enumerated() {
            let chunks = fragments.filter { $0.messageOrdinal == ordinal }
            let bytes = Data(chunks.map(\.payloadFragment).joined().utf8)
            let expected = try ServiceTranscriptContinuation.redactedPayload(for: message)
            XCTAssertEqual(bytes, expected)
            XCTAssertEqual(chunks.first?.utf8Offset, 0)
            XCTAssertEqual(chunks.last?.isLastFragment, true)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(chunks.allSatisfy { $0.payloadSHA256 == digest })
            let projected = try JSONDecoder().decode(EngramServiceWebNormalizedMessage.self, from: bytes)
            XCTAssertEqual(projected.role.rawValue, message.role.rawValue)
            XCTAssertEqual(projected.toolCalls?.count, message.toolCalls?.count)
            XCTAssertEqual(projected.usage?.inputTokens, message.usage?.inputTokens)
            XCTAssertEqual(projected.usage?.outputTokens, message.usage?.outputTokens)
        }
    }

    private static func snapshot(_ messages: [NormalizedMessage], sessionID: String = WebTranscriptIPCTests.sessionID,
                                 generation: String = WebTranscriptIPCTests.generation) -> ServiceTranscriptContinuation.Snapshot {
        .init(sessionId: sessionID, generation: generation, messages: messages)
    }

    private static func request(sessionID: String = WebTranscriptIPCTests.sessionID, roles: [EngramServiceWebMessageRole] = EngramServiceWebMessageRole.allCases,
                                cursor: String? = nil, maxFragments: Int = 50) throws -> EngramServiceWebMessagesRequest {
        try .init(sessionId: sessionID, generation: generation, roles: roles, cursor: cursor, maxFragments: maxFragments)
    }

    private static func requestObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request())) as? [String: Any])
    }

    private static func elapsed(_ started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

private final class WebIPCHarness: @unchecked Sendable {
    let root: URL
    let socketPath: String
    let requests: WebIPCRequestLog
    let client: EngramServiceWebReadClient
    private var gateOwner: ServiceWriterGate?
    private var serverOwner: UnixSocketServiceServer?
    private weak var gateReleaseProbe: ServiceWriterGate?

    var gate: ServiceWriterGate { gateOwner! }

    init(root: URL, socketPath: String, gate: ServiceWriterGate, server: UnixSocketServiceServer, requests: WebIPCRequestLog) throws {
        self.root = root
        self.socketPath = socketPath
        gateOwner = gate
        serverOwner = server
        gateReleaseProbe = gate
        self.requests = requests
        client = try EngramServiceWebReadClient(socketPath: socketPath)
    }

    func finish() async throws {
        let drained = await stopServer()
        XCTAssertTrue(drained, "Do not remove fixture storage while a handler is still active")
        guard drained else { return }
        // The server owns the handler, which owns the gate/database. Release
        // that chain before unlinking SQLite files; a drained client list alone
        // does not release the server's captured handler or its accept task.
        serverOwner = nil
        gateOwner = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while gateReleaseProbe != nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let released = gateReleaseProbe == nil
        XCTAssertTrue(released, "Preserve fixture storage until its database owner is released")
        if released { try FileManager.default.removeItem(at: root) }
    }

    private func stopServer() async -> Bool {
        guard let server = serverOwner else { return true }
        server.stop()
        return await server.drainClientHandlers(timeoutNanoseconds: 2_000_000_000)
    }
}

private actor WebIPCRequestLog {
    struct Record: Sendable {
        let requestID: String
        let command: String
        let hasCapability: Bool
    }
    private var records: [Record] = []
    func append(_ request: EngramServiceRequestEnvelope) {
        records.append(.init(requestID: request.requestId, command: request.command, hasCapability: request.capabilityToken != nil))
    }
    func values() -> [Record] { records }
}

/// Test authority only: visibility changes model the production provider's
/// required per-call gate. No database/source policy is implemented by A3.
private actor WebIPCSnapshotFixture: ServiceWebTranscriptSnapshotProviding {
    enum Eligibility: Equatable, Sendable { case visible, hidden, skip, withheld }
    enum Behavior: Sendable { case ready, failWithPrivateDiagnostic, returnAfterDeadline, waitForCancellation }
    struct Observation: Sendable {
        let sessionID: String
        let generation: String
        let remainingSeconds: Double
    }

    private var selected: ServiceTranscriptContinuation.Snapshot?
    private var eligibility: Eligibility = .visible
    private var calls: [Observation] = []
    private let behavior: Behavior
    private let entered: XCTestExpectation?
    private let cancelled: XCTestExpectation?

    init(snapshot: ServiceTranscriptContinuation.Snapshot?, behavior: Behavior = .ready,
         entered: XCTestExpectation? = nil, cancelled: XCTestExpectation? = nil) {
        selected = snapshot
        self.behavior = behavior
        self.entered = entered
        self.cancelled = cancelled
    }

    func replace(_ value: ServiceTranscriptContinuation.Snapshot?) { selected = value }
    func setEligibility(_ value: Eligibility) { eligibility = value }
    func observations() -> [Observation] { calls }

    func snapshot(sessionID: String, generation: String, deadline: ContinuousClock.Instant) async throws -> ServiceTranscriptContinuation.Snapshot? {
        let remaining = ContinuousClock.now.duration(to: deadline).components
        calls.append(.init(sessionID: sessionID, generation: generation,
                           remainingSeconds: Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18))
        entered?.fulfill()
        try Task.checkCancellation()
        guard eligibility == .visible else { throw ServiceWebTranscriptSnapshotError.unavailable }
        switch behavior {
        case .ready: return selected
        case .failWithPrivateDiagnostic:
            throw NSError(domain: "secret-/private/fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "token=secret-provider"])
        case .returnAfterDeadline:
            try await ContinuousClock().sleep(until: deadline.advanced(by: .milliseconds(20)))
            return selected
        case .waitForCancellation:
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch is CancellationError { cancelled?.fulfill(); throw CancellationError() }
            return selected
        }
    }
}
