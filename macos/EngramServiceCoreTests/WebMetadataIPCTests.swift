import Darwin
import EngramCoreRead
import EngramCoreWrite
import Foundation
import XCTest
@testable import EngramServiceCore

// A5d TEST-DRAFT. The production adapter is deliberately unavailable until
// these real-dispatch tests have been independently reviewed and run RED.
final class WebMetadataIPCTests: XCTestCase {
    func testTypedClientRoutesAllThreeCommandsWithoutCapabilityOrWriterMutation() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider)
        let before = await fixture.gate.currentDatabaseGeneration()
        for command in MetadataIPCCommand.allCases {
            try await command.call(fixture.client)
        }
        let calls = provider.observations
        let requests = fixture.trace.requests
        XCTAssertEqual(calls.map(\.command), MetadataIPCCommand.allCases)
        XCTAssertEqual(requests.map(\.command), MetadataIPCCommand.allCases.map(\.rawValue))
        XCTAssertEqual(calls.count, 3)
        for (call, request) in zip(calls, requests) {
            XCTAssertEqual(Data(call.requestID.utf8), Data(request.requestID.utf8))
            XCTAssertNotNil(UUID(uuidString: request.requestID))
            XCTAssertFalse(request.hasCapability)
            XCTAssertGreaterThan(call.deadline, call.enteredAt)
            XCTAssertLessThanOrEqual(call.deadline - call.enteredAt, .seconds(2))
        }
        XCTAssertEqual(provider.stopCount, 0, "Requests do not own or close the shared producer")
        let after = await fixture.gate.currentDatabaseGeneration()
        XCTAssertEqual(after, before)
    }

    func testAllAllowedFiltersAndUnicodeRequestIDsReachTheSameRetainedProducerByteExactly() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider)
        let overview = try EngramServiceWebOverviewRequest(limit: 7, snapshotId: MetadataIPCFacts.snapshot, cursor: "overview_cursor")
        let sessions = try EngramServiceWebSessionsRequest(query: "cafe\u{301} 中文", source: "claude-code",
            machineId: MetadataIPCFacts.machine, sourceInstanceId: MetadataIPCFacts.instance,
            projectKey: "project_1", limit: 9, snapshotId: MetadataIPCFacts.snapshot, cursor: "session_cursor")
        let detail = try EngramServiceWebSessionDetailRequest(sessionId: "capture/cafe\u{301}")
        let payloads: [Data] = [try ArchiveCanonicalJSON.encode(overview),
                                try ArchiveCanonicalJSON.encode(sessions), try ArchiveCanonicalJSON.encode(detail)]
        for (index, command) in MetadataIPCCommand.allCases.enumerated() {
            let requestID = "request/cafe\u{301}/\(index)"
            XCTAssertNotEqual(Data(requestID.utf8), Data("request/caf\u{e9}/\(index)".utf8))
            for _ in 0..<2 {
                let response = try await fixture.raw(command, payload: payloads[index], requestID: requestID)
                guard case .success = response.envelope else { return XCTFail("Expected typed metadata success") }
                XCTAssertEqual(Data(response.envelope.requestId.utf8), Data(requestID.utf8))
                XCTAssertLessThanOrEqual(response.bytes.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
            }
        }
        XCTAssertEqual(provider.observations.count, 6)
        for (index, call) in provider.observations.enumerated() {
            XCTAssertEqual(call.command, MetadataIPCCommand.allCases[index / 2])
            XCTAssertEqual(call.input, payloads[index / 2])
            XCTAssertEqual(Data(call.requestID.utf8), Data("request/cafe\u{301}/\(index / 2)".utf8))
        }
        XCTAssertEqual(provider.stopCount, 0)
    }

    func testDefaultConstructorProviderIsUnavailableForAllThreeRealSocketCommands() async throws {
        let fixture = try makeHarness() // Deliberately omit the constructor injection.
        let before = await fixture.gate.currentDatabaseGeneration()
        for command in MetadataIPCCommand.allCases {
            let raw = try await fixture.raw(command)
            assertFailure(raw.envelope, name: "ServiceUnavailable", retry: "safe")
            await assertClientError(.unavailable) { try await command.call(fixture.client) }
        }
        XCTAssertTrue(fixture.trace.requests.allSatisfy { !$0.hasCapability })
        let after = await fixture.gate.currentDatabaseGeneration()
        XCTAssertEqual(after, before)
    }

    func testActualA5cProducerMeasuresMigratedEmptyCorpusThroughAllThreeTypedEndpoints() async throws {
        let fixture = try makeHarness(realProducer: true)
        let before = await fixture.gate.currentDatabaseGeneration()
        let overview = try await fixture.client.overview(try .init())
        XCTAssertTrue(overview.streams.isEmpty)
        XCTAssertNil(overview.nextCursor)
        XCTAssertEqual(overview.capabilities.transcriptRead, .unavailable)
        XCTAssertEqual(overview.capabilities.keywordSearch, .available)
        let sessions = try await fixture.client.sessions(try .init())
        XCTAssertTrue(sessions.items.isEmpty)
        XCTAssertNil(sessions.nextCursor)
        let detail = try await fixture.client.sessionDetail(try .init(sessionId: "absent-session"))
        XCTAssertNil(detail.detail)
        XCTAssertEqual(fixture.trace.requests.map(\.command), MetadataIPCCommand.allCases.map(\.rawValue))
        XCTAssertTrue(fixture.trace.requests.allSatisfy { !$0.hasCapability })
        let after = await fixture.gate.currentDatabaseGeneration()
        XCTAssertEqual(after, before)
    }

    func testEveryIndependentExtraKeyFailsBeforeProducerForEveryCommand() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider)
        let forbidden = ["command", "locator", "path", "filePath", "root", "cwd", "capabilityToken",
                         "capability_token", "hidden", "includeHidden", "deadline", "budget", "maxBytes"]
        for command in MetadataIPCCommand.allCases {
            for key in forbidden {
                var object = try command.object()
                object[key] = "/private/fixture/secret"
                let raw = try await fixture.raw(command, payload: JSONSerialization.data(withJSONObject: object))
                assertFailure(raw.envelope, name: "InvalidRequest", retry: "never")
                XCTAssertTrue(provider.observations.isEmpty, "\(command)/\(key) entered producer")
            }
            var crossed = try command.object()
            crossed[command == .sessions ? "sessionId" : "query"] = "cross_command_field"
            assertFailure(try await fixture.raw(command, payload: JSONSerialization.data(withJSONObject: crossed)).envelope,
                          name: "InvalidRequest", retry: "never")
        }
        XCTAssertTrue(provider.observations.isEmpty)
    }

    func testMissingMalformedAndNonObjectPayloadsFailBeforeProducerForEveryCommand() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider)
        let invalid: [Data?] = [nil, Data(), Data("not-json".utf8), Data("[]".utf8), Data("null".utf8),
                                Data("1".utf8), Data("true".utf8), Data("\"text\"".utf8), Data([0xff])]
        for command in MetadataIPCCommand.allCases {
            for payload in invalid {
                let raw = try await fixture.raw(command, payload: payload)
                assertFailure(raw.envelope, name: "InvalidRequest", retry: "never")
                XCTAssertTrue(provider.observations.isEmpty)
            }
            assertFailure(try await fixture.raw(command, payload: Data("{}".utf8)).envelope,
                          name: "InvalidRequest", retry: "never")
        }
        XCTAssertTrue(provider.observations.isEmpty)
    }

    func testRequiredAndTypedPageFieldsAreRejectedIndependently() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider)
        for command in [MetadataIPCCommand.overview, .sessions] {
            let invalidLimits: [Any] = [NSNull(), true, "1", 1.5, 0, -1, 101]
            for value in invalidLimits {
                var object = try command.object()
                object["limit"] = value
                assertFailure(try await fixture.raw(command, payload: JSONSerialization.data(withJSONObject: object)).envelope,
                              name: "InvalidRequest", retry: "never")
            }
            let invalidPages: [[String: Any]] = [
                ["snapshotId": MetadataIPCFacts.snapshot], ["cursor": "cursor_only"],
                ["snapshotId": "invalid", "cursor": "cursor"],
                ["snapshotId": MetadataIPCFacts.snapshot, "cursor": "../path"],
                ["snapshotId": MetadataIPCFacts.snapshot, "cursor": 1],
                ["snapshotId": 1, "cursor": "cursor"],
            ]
            for additions in invalidPages {
                var object = try command.object()
                object.merge(additions) { _, new in new }
                assertFailure(try await fixture.raw(command, payload: JSONSerialization.data(withJSONObject: object)).envelope,
                              name: "InvalidRequest", retry: "never")
            }
        }
        XCTAssertTrue(provider.observations.isEmpty)
    }

    func testSessionFiltersAreStrictWithoutProducerEntry() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider)
        let invalid: [(String, Any)] = [
            ("query", 12), ("query", " leading"), ("query", "trailing "), ("query", "safe\u{0}secret"),
            ("query", String(repeating: "x", count: 1025)), ("source", "Claude-Code"), ("source", 1),
            ("machineId", "invalid"), ("sourceInstanceId", MetadataIPCFacts.instance),
            ("projectKey", "project/path"), ("projectKey", String(repeating: "p", count: 129)),
        ]
        for (key, value) in invalid {
            var object = try MetadataIPCCommand.sessions.object()
            object[key] = value
            assertFailure(try await fixture.raw(.sessions, payload: JSONSerialization.data(withJSONObject: object)).envelope,
                          name: "InvalidRequest", retry: "never")
        }
        XCTAssertTrue(provider.observations.isEmpty)
    }

    func testDetailIdentityIsRequiredAndStrictWithoutProducerEntry() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider)
        let invalid: [Any] = [NSNull(), 12, "", "safe\u{0}secret", String(repeating: "s", count: 4097)]
        for value in invalid {
            let payload = try JSONSerialization.data(withJSONObject: ["sessionId": value])
            assertFailure(try await fixture.raw(.detail, payload: payload).envelope,
                          name: "InvalidRequest", retry: "never")
        }
        XCTAssertTrue(provider.observations.isEmpty)
    }

    func testUnknownCommandsKeepExistingUnsupportedContractAndDoNotEnterMetadataProducer() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider)
        for command in ["webOverviewExtra", "WebSessions", "webSessionDetails", "unknown-a5d"] {
            let response = try await fixture.exchange(command: command, payload: Data("{}".utf8))
            guard case .failure(_, let error) = response.envelope else { return XCTFail("Expected UnsupportedCommand") }
            XCTAssertEqual(error.name, "UnsupportedCommand")
            XCTAssertEqual(error.retryPolicy, "none")
            XCTAssertEqual(error.details?["command"], .string(command))
        }
        XCTAssertTrue(provider.observations.isEmpty)
    }

    func testExistingTranscriptCommandStillUsesItsOwnDispatch() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider)
        let input = try EngramServiceWebMessagesRequest(sessionId: "existing", generation: String(repeating: "a", count: 64))
        let response = try await fixture.exchange(command: "webMessages", payload: JSONEncoder().encode(input))
        assertFailure(response.envelope, name: "ServiceUnavailable", retry: "safe")
        XCTAssertTrue(provider.observations.isEmpty)
    }

    func testSafeProviderErrorNamesAndRetryPoliciesForEveryEndpoint() async throws {
        for failure in MetadataIPCProvider.Failure.allCases {
            let provider = MetadataIPCProvider(behavior: .fail(failure))
            let fixture = try makeHarness(provider: provider)
            let before = await fixture.gate.currentDatabaseGeneration()
            for command in MetadataIPCCommand.allCases {
                let response = try await fixture.raw(command)
                assertFailure(response.envelope, name: failure.wireName, retry: failure.retry)
            }
            XCTAssertEqual(provider.observations.count, 3, "A constant unavailable stub is not error-mapping evidence")
            let after = await fixture.gate.currentDatabaseGeneration()
            XCTAssertEqual(after, before)
        }
    }

    func testTypedClientKeepsStaleUnavailableAndServerCancelledCategories() async throws {
        for (failure, expected) in [(MetadataIPCProvider.Failure.stale, EngramServiceWebReadClientError.stale),
                                    (.unavailable, .unavailable), (.cancelled, .malformed)] {
            let provider = MetadataIPCProvider(behavior: .fail(failure))
            let fixture = try makeHarness(provider: provider)
            for command in MetadataIPCCommand.allCases {
                await assertClientError(expected) { try await command.call(fixture.client) }
            }
            XCTAssertEqual(provider.observations.count, 3)
        }
    }

    func testInjectedInvalidOverviewMustFailAtHandlerRatherThanOnlyAtTypedClient() async throws {
        let invalid = EngramServiceWebOverviewResponse(snapshotId: "invalid-snapshot", observedAt: 1,
            capabilities: .init(keywordSearch: .unavailable, transcriptRead: .unavailable), streams: [], nextCursor: nil)
        XCTAssertThrowsError(try JSONDecoder().decode(EngramServiceWebOverviewResponse.self, from: JSONEncoder().encode(invalid)))
        let provider = MetadataIPCProvider(overview: invalid)
        let fixture = try makeHarness(provider: provider)
        assertFailure(try await fixture.raw(.overview).envelope, name: "ServiceUnavailable", retry: "safe")
        XCTAssertEqual(provider.observations.count, 1)
    }

    func testInjectedInvalidSessionsMustFailAtHandlerRatherThanOnlyAtTypedClient() async throws {
        let bad = MetadataIPCFacts.summary(id: "bad", title: "safe\u{0}secret")
        let invalid = EngramServiceWebSessionsResponse(snapshotId: MetadataIPCFacts.snapshot, observedAt: 1,
                                                       items: [bad], nextCursor: nil)
        XCTAssertThrowsError(try JSONDecoder().decode(EngramServiceWebSessionsResponse.self, from: JSONEncoder().encode(invalid)))
        let provider = MetadataIPCProvider(sessions: invalid)
        let fixture = try makeHarness(provider: provider)
        assertFailure(try await fixture.raw(.sessions).envelope, name: "ServiceUnavailable", retry: "safe")
        XCTAssertEqual(provider.observations.count, 1)
    }

    func testInjectedInvalidDetailMustFailAtHandlerRatherThanOnlyAtTypedClient() async throws {
        let invalid = EngramServiceWebSessionDetailResponse(observedAt: 1,
            detail: .init(session: MetadataIPCFacts.summary(), lastParsed: nil, lastReady: nil,
                          transcriptAvailability: .available, transcriptGeneration: nil, currentAttempt: nil))
        XCTAssertThrowsError(try JSONDecoder().decode(EngramServiceWebSessionDetailResponse.self, from: JSONEncoder().encode(invalid)))
        let provider = MetadataIPCProvider(detail: invalid)
        let fixture = try makeHarness(provider: provider)
        assertFailure(try await fixture.raw(.detail).envelope, name: "ServiceUnavailable", retry: "safe")
        XCTAssertEqual(provider.observations.count, 1)
    }

    func testWholeOverviewEnvelopeIncludesRequestIdentityOverhead() async throws {
        let result = EngramServiceWebOverviewResponse(snapshotId: MetadataIPCFacts.snapshot, observedAt: 1,
            capabilities: .init(keywordSearch: .unavailable, transcriptRead: .unavailable),
            streams: (0..<100).map { MetadataIPCFacts.stream(machine: String(format: "%08X-0000-4000-8000-000000000001", $0)) },
            nextCursor: nil)
        let requestID = String(repeating: "r", count: 246_000)
        try assertValidButOversizedFrame(result, requestID: requestID)
        let provider = MetadataIPCProvider(overview: result)
        let fixture = try makeHarness(provider: provider)
        let payload = try JSONEncoder().encode(EngramServiceWebOverviewRequest(limit: 100))
        assertFailure(try await fixture.raw(.overview, payload: payload, requestID: requestID).envelope,
                      name: "ServiceUnavailable", retry: "safe")
        XCTAssertEqual(provider.observations.count, 1)
    }

    func testWholeSessionsEnvelopeIncludesDataBase64RatherThanOnlyResultBytes() async throws {
        let result = EngramServiceWebSessionsResponse(snapshotId: MetadataIPCFacts.snapshot, observedAt: 1,
            items: (0..<70).map { MetadataIPCFacts.summary(id: String(format: "%03d-", $0) + String(repeating: "s", count: 1800),
                                                        title: String(repeating: "t", count: 1024)) }, nextCursor: nil)
        try assertValidButOversizedFrame(result, requestID: MetadataIPCFacts.requestID)
        let provider = MetadataIPCProvider(sessions: result)
        let fixture = try makeHarness(provider: provider)
        let payload = try JSONEncoder().encode(EngramServiceWebSessionsRequest(limit: 100))
        assertFailure(try await fixture.raw(.sessions, payload: payload).envelope, name: "ServiceUnavailable", retry: "safe")
        XCTAssertEqual(provider.observations.count, 1)
    }

    func testWholeDetailEnvelopeCountsEscapedDTOAndRequestIdentity() async throws {
        let id = String(repeating: "s", count: 4096)
        let result = EngramServiceWebSessionDetailResponse(observedAt: 1,
            detail: .init(session: MetadataIPCFacts.summary(id: id, title: String(repeating: "\u{1}", count: 1024),
                                                          projectLabel: String(repeating: "\u{1}", count: 256)),
                          lastParsed: nil, lastReady: nil, transcriptAvailability: .unavailable,
                          transcriptGeneration: nil, currentAttempt: nil))
        let requestID = String(repeating: "r", count: 246_000)
        try assertValidButOversizedFrame(result, requestID: requestID)
        let provider = MetadataIPCProvider(detail: result)
        let fixture = try makeHarness(provider: provider)
        let payload = try JSONEncoder().encode(EngramServiceWebSessionDetailRequest(sessionId: id))
        assertFailure(try await fixture.raw(.detail, payload: payload, requestID: requestID).envelope,
                      name: "ServiceUnavailable", retry: "safe")
        XCTAssertEqual(provider.observations.count, 1)
    }

    func testHandlerEntryCancellationRejectsBeforeEveryProducerMethod() async throws {
        let provider = MetadataIPCProvider()
        let fixture = try makeHarness(provider: provider, cancelAtEntry: true)
        for command in MetadataIPCCommand.allCases {
            let response = try await fixture.raw(command)
            assertFailure(response.envelope, name: "Cancelled", retry: "never")
        }
        XCTAssertTrue(provider.observations.isEmpty)
    }

    func testProducerCannotRenewExpiredHandlerDeadlineForAnyEndpoint() async throws {
        let provider = MetadataIPCProvider(behavior: .returnAfterDeadline)
        let fixture = try makeHarness(provider: provider)
        for command in MetadataIPCCommand.allCases {
            let began = ContinuousClock.now
            let response = try await fixture.raw(command, timeout: 3)
            assertFailure(response.envelope, name: "ServiceUnavailable", retry: "safe")
            let observation = try XCTUnwrap(provider.observations.last)
            XCTAssertEqual(observation.command, command)
            XCTAssertGreaterThan(observation.deadline, observation.enteredAt)
            XCTAssertLessThanOrEqual(observation.deadline - observation.enteredAt, .seconds(2))
            XCTAssertGreaterThan(ContinuousClock.now - began, .milliseconds(1900))
        }
    }

    func testClientCancellationAndServiceProducerJoinAreObservedSeparately() async throws {
        for command in MetadataIPCCommand.allCases {
            let entered = expectation(description: "\(command) producer entered")
            let cancellation = expectation(description: "\(command) producer observed cancellation")
            let exited = expectation(description: "\(command) producer exited")
            let provider = MetadataIPCProvider(behavior: .waitForCancellation,
                entered: entered, cancellation: cancellation, exited: exited)
            let fixture = try makeHarness(provider: provider)
            let before = await fixture.gate.currentDatabaseGeneration()
            let clientTask = Task { try await command.call(fixture.client) }
            defer { clientTask.cancel(); provider.releaseWaits() }
            await fulfillment(of: [entered], timeout: 0.8)
            let didEnter = !provider.observations.isEmpty
            XCTAssertTrue(didEnter)
            clientTask.cancel()
            do { try await clientTask.value; XCTFail("Expected local client cancellation") }
            catch is CancellationError {}
            catch { XCTFail("Client must preserve local CancellationError") }
            if didEnter {
                await fulfillment(of: [cancellation], timeout: 0.8)
                XCTAssertTrue(provider.events.contains("cancelled"))
                XCTAssertFalse(provider.events.contains("exited"), "Cleanup is deliberately held")
                XCTAssertTrue(fixture.trace.responses.isEmpty, "Service handler must still await owned producer cleanup")
            }
            provider.releaseWaits()
            if didEnter { await fulfillment(of: [exited], timeout: 0.8) }
            let drained = await fixture.stopAndDrain()
            XCTAssertTrue(drained)
            if didEnter {
                XCTAssertEqual(provider.events, ["entered", "cancelled", "exited"])
                XCTAssertEqual(fixture.trace.responses.count, 1)
                if let response = fixture.trace.responses.first {
                    assertFailure(response, name: "Cancelled", retry: "never")
                }
            }
            let after = await fixture.gate.currentDatabaseGeneration()
            XCTAssertEqual(after, before)
        }
    }

    func testMetadataCommandsRemainReadOnlyAtTheExistingCapabilityBoundary() {
        for command in MetadataIPCCommand.allCases {
            XCTAssertFalse(ServiceCapabilityToken.requiresToken(command.rawValue))
        }
    }

    private func makeHarness(provider: MetadataIPCProvider? = nil, realProducer: Bool = false,
                             cancelAtEntry: Bool = false) throws -> MetadataIPCHarness {
        let fixture = try MetadataIPCHarness(provider: provider, realProducer: realProducer, cancelAtEntry: cancelAtEntry)
        addTeardownBlock { try await fixture.finish() }
        return fixture
    }

    private func assertFailure(_ response: EngramServiceResponseEnvelope, name: String, retry: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(_, let error) = response else { return XCTFail("Expected \(name)", file: file, line: line) }
        XCTAssertEqual(error.name, name, file: file, line: line)
        XCTAssertEqual(error.retryPolicy, retry, file: file, line: line)
        XCTAssertNil(error.details, "Metadata errors carry no diagnostic payload", file: file, line: line)
        for secret in ["PRIVATE_DIAGNOSTIC", "private/fixture", "secret.sqlite", "SELECT", "SQLITE", "filePath", "locator"] {
            XCTAssertFalse(error.message.contains(secret), file: file, line: line)
        }
    }

    private func assertClientError(_ expected: EngramServiceWebReadClientError,
                                   _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch let error as EngramServiceWebReadClientError { XCTAssertEqual(error, expected) }
        catch { XCTFail("Unexpected typed client error category") }
    }

    private func assertValidButOversizedFrame<Value: Codable>(_ value: Value, requestID: String) throws {
        let payload = try JSONEncoder().encode(value)
        _ = try JSONDecoder().decode(Value.self, from: payload)
        XCTAssertLessThan(payload.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes,
                          "The result alone must fit; this regression concerns the outer frame")
        let frame = try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: requestID, result: payload))
        XCTAssertGreaterThan(frame.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
    }
}

private enum MetadataIPCFacts {
    static let machine = "AAAAAAAA-0000-4000-8000-000000000001"
    static let instance = "BBBBBBBB-0000-4000-8000-000000000002"
    static let snapshot = "CCCCCCCC-0000-4000-8000-000000000003"
    static let requestID = "DDDDDDDD-0000-4000-8000-000000000004"

    static func summary(id: String = "capture/session", source: String = "claude-code", machine: String = MetadataIPCFacts.machine,
                        instance: String = MetadataIPCFacts.instance, title: String = "safe title", projectKey: String = "project_1",
                        projectLabel: String = "safe project") -> EngramServiceWebSessionSummary {
        .init(sessionId: id, source: source, captureIdentity: .init(machineId: machine, sourceInstanceId: instance),
              metadataGeneration: nil, title: title, projectKey: projectKey, projectLabel: projectLabel, startedAt: 1)
    }

    static func stream(machine: String = MetadataIPCFacts.machine) -> EngramServiceWebStreamOverview {
        .init(machineId: machine, sourceInstanceId: instance,
              registry: .init(source: "claude-code", approvedEpoch: snapshot, authorityGeneration: "1"),
              ingest: nil, heartbeatAt: nil, lastCapture: nil, replicaACKs: nil, fts: nil, ai: nil)
    }
}

private enum MetadataIPCCommand: String, CaseIterable, Sendable {
    case overview = "webOverview", sessions = "webSessions", detail = "webSessionDetail"

    func payload() throws -> Data {
        switch self {
        case .overview: return try JSONEncoder().encode(EngramServiceWebOverviewRequest())
        case .sessions: return try JSONEncoder().encode(EngramServiceWebSessionsRequest())
        case .detail: return try JSONEncoder().encode(EngramServiceWebSessionDetailRequest(sessionId: "capture/session"))
        }
    }

    func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: payload()) as? [String: Any])
    }

    func call(_ client: EngramServiceWebReadClient) async throws {
        switch self {
        case .overview: _ = try await client.overview(try .init())
        case .sessions: _ = try await client.sessions(try .init())
        case .detail: _ = try await client.sessionDetail(try .init(sessionId: "capture/session"))
        }
    }
}

private final class MetadataIPCTrace: @unchecked Sendable {
    struct Request: Sendable {
        let command: String
        let requestID: String
        let hasCapability: Bool
    }
    private let lock = NSLock()
    private var storedRequests: [Request] = []
    private var storedResponses: [EngramServiceResponseEnvelope] = []
    var requests: [Request] { lock.withLock { storedRequests } }
    var responses: [EngramServiceResponseEnvelope] { lock.withLock { storedResponses } }
    func entered(_ request: EngramServiceRequestEnvelope) {
        lock.withLock {
            storedRequests.append(.init(command: request.command, requestID: request.requestId,
                                        hasCapability: request.capabilityToken != nil))
        }
    }
    func returned(_ response: EngramServiceResponseEnvelope) { lock.withLock { storedResponses.append(response) } }
}

private final class MetadataIPCProvider: ServiceWebMetadataProviding, @unchecked Sendable {
    enum Failure: CaseIterable, Sendable {
        case stale, unavailable, responseTooLarge, notImplemented, cancelled, privateDiagnostic
        var wireName: String {
            switch self {
            case .stale: return "StaleCursor"
            case .cancelled: return "Cancelled"
            default: return "ServiceUnavailable"
            }
        }
        var retry: String { self == .stale || self == .cancelled ? "never" : "safe" }
    }
    enum Behavior: Sendable { case ready, fail(Failure), returnAfterDeadline, waitForCancellation }
    struct Observation: Sendable {
        let command: MetadataIPCCommand
        let requestID: String
        let input: Data
        let deadline: ContinuousClock.Instant
        let enteredAt: ContinuousClock.Instant
    }
    private let lock = NSLock()
    private var storedObservations: [Observation] = []
    private var storedEvents: [String] = []
    private var stops = 0
    private let behavior: Behavior
    private let overviewValue: EngramServiceWebOverviewResponse?
    private let sessionsValue: EngramServiceWebSessionsResponse?
    private let detailValue: EngramServiceWebSessionDetailResponse?
    private let entered: XCTestExpectation?
    private let cancellation: XCTestExpectation?
    private let exited: XCTestExpectation?
    private let cancellationGate = MetadataIPCBarrier()
    private let cleanupGate = MetadataIPCBarrier()

    var observations: [Observation] { lock.withLock { storedObservations } }
    var events: [String] { lock.withLock { storedEvents } }
    var stopCount: Int { lock.withLock { stops } }

    init(behavior: Behavior = .ready, overview: EngramServiceWebOverviewResponse? = nil,
         sessions: EngramServiceWebSessionsResponse? = nil, detail: EngramServiceWebSessionDetailResponse? = nil,
         entered: XCTestExpectation? = nil, cancellation: XCTestExpectation? = nil, exited: XCTestExpectation? = nil) {
        self.behavior = behavior
        overviewValue = overview
        sessionsValue = sessions
        detailValue = detail
        self.entered = entered
        self.cancellation = cancellation
        self.exited = exited
    }

    func overview(_ request: EngramServiceWebOverviewRequest, requestId: String,
                  deadline: ContinuousClock.Instant) async throws -> EngramServiceWebOverviewResponse {
        try await prepare(.overview, input: request, requestID: requestId, deadline: deadline)
        return overviewValue ?? .init(snapshotId: request.snapshotId ?? MetadataIPCFacts.snapshot, observedAt: 1,
            capabilities: .init(keywordSearch: .unavailable, transcriptRead: .unavailable),
            streams: [MetadataIPCFacts.stream()], nextCursor: nil)
    }

    func sessions(_ request: EngramServiceWebSessionsRequest, requestId: String,
                  deadline: ContinuousClock.Instant) async throws -> EngramServiceWebSessionsResponse {
        try await prepare(.sessions, input: request, requestID: requestId, deadline: deadline)
        return sessionsValue ?? .init(snapshotId: request.snapshotId ?? MetadataIPCFacts.snapshot, observedAt: 1,
            items: [MetadataIPCFacts.summary(source: request.source ?? "claude-code", machine: request.machineId ?? MetadataIPCFacts.machine,
                instance: request.sourceInstanceId ?? MetadataIPCFacts.instance, projectKey: request.projectKey ?? "project_1")], nextCursor: nil)
    }

    func sessionDetail(_ request: EngramServiceWebSessionDetailRequest, requestId: String,
                       deadline: ContinuousClock.Instant) async throws -> EngramServiceWebSessionDetailResponse {
        try await prepare(.detail, input: request, requestID: requestId, deadline: deadline)
        return detailValue ?? .init(observedAt: 1,
            detail: .init(session: MetadataIPCFacts.summary(id: request.sessionId), lastParsed: nil, lastReady: nil,
                          transcriptAvailability: .unavailable, transcriptGeneration: nil, currentAttempt: nil))
    }

    func stop() throws { lock.withLock { stops += 1 }; releaseWaits() }
    func releaseWaits() { cancellationGate.release(); cleanupGate.release() }

    private func prepare(_ command: MetadataIPCCommand, input: some Encodable, requestID: String,
                         deadline: ContinuousClock.Instant) async throws {
        let observation = Observation(command: command, requestID: requestID, input: try ArchiveCanonicalJSON.encode(input),
                                      deadline: deadline, enteredAt: ContinuousClock.now)
        lock.withLock { storedObservations.append(observation) }
        switch behavior {
        case .ready: return
        case .fail(let failure):
            switch failure {
            case .stale: throw ServiceWebMetadataError.stale
            case .unavailable: throw ServiceWebMetadataError.unavailable
            case .responseTooLarge: throw ServiceWebMetadataError.responseTooLarge
            case .notImplemented: throw ServiceWebMetadataError.notImplemented
            case .cancelled: throw CancellationError()
            case .privateDiagnostic:
                throw NSError(domain: "PRIVATE_DIAGNOSTIC", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "SELECT PRIVATE_DIAGNOSTIC FROM /private/fixture/secret.sqlite"])
            }
        case .returnAfterDeadline:
            let remaining = deadline - ContinuousClock.now + .milliseconds(40)
            if remaining > .zero { try await Task.sleep(for: remaining) }
        case .waitForCancellation:
            lock.withLock { storedEvents.append("entered") }
            entered?.fulfill()
            defer { lock.withLock { storedEvents.append("exited") }; exited?.fulfill() }
            do {
                try await cancellationGate.wait()
                throw MetadataIPCTestError.unexpectedBarrierRelease
            } catch is CancellationError {
                lock.withLock { storedEvents.append("cancelled") }
                cancellation?.fulfill()
                // Owned, joined cleanup can outlive caller cancellation. The
                // test holds it until it has observed the handler still waiting.
                let cleanup = Task.detached { [cleanupGate] in try await cleanupGate.wait() }
                try await cleanup.value
                throw CancellationError()
            }
        }
    }
}

private enum MetadataIPCTestError: Error { case barrierTimeout, duplicateWaiter, unexpectedBarrierRelease }

/// Single-use bounded test barrier. A terminal outcome survives cancellation or
/// release before continuation registration. Its watchdog is always joined.
private final class MetadataIPCBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func wait() async throws {
        let watchdog = Task.detached { [self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            resolve(.failure(MetadataIPCTestError.barrierTimeout))
        }
        let result: Result<Void, Error>
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let immediate: Result<Void, Error>? = lock.withLock {
                        if let terminal { return terminal }
                        if Task.isCancelled {
                            let cancelled: Result<Void, Error> = .failure(CancellationError())
                            terminal = cancelled
                            return cancelled
                        }
                        guard waiter == nil else { return .failure(MetadataIPCTestError.duplicateWaiter) }
                        waiter = continuation
                        return nil
                    }
                    if let immediate { continuation.resume(with: immediate) }
                }
            } onCancel: { self.resolve(.failure(CancellationError())) }
            result = .success(())
        } catch { result = .failure(error) }
        watchdog.cancel()
        await watchdog.value
        try result.get()
    }

    func release() { resolve(.success(())) }

    private func resolve(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard terminal == nil else { return nil }
            terminal = result
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class MetadataIPCHarness: @unchecked Sendable {
    struct RawResponse { let envelope: EngramServiceResponseEnvelope; let bytes: Data }
    let root: URL
    let socketPath: String
    let trace: MetadataIPCTrace
    let client: EngramServiceWebReadClient
    private var gateOwner: ServiceWriterGate?
    private var serverOwner: UnixSocketServiceServer?
    private var providerOwner: (any ServiceWebMetadataProviding)?
    private weak var gateProbe: ServiceWriterGate?
    private weak var handlerProbe: EngramServiceCommandHandler?
    private weak var realProviderProbe: ServiceWebMetadataProducer?
    private var finished = false

    var gate: ServiceWriterGate { gateOwner! }

    init(provider: MetadataIPCProvider?, realProducer: Bool, cancelAtEntry: Bool) throws {
        precondition(provider == nil || !realProducer)
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("eg-a5d-\(UUID().uuidString.prefix(8))", isDirectory: true)
        socketPath = root.appendingPathComponent("service.sock").path
        trace = MetadataIPCTrace()
        client = try EngramServiceWebReadClient(socketPath: socketPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("index.sqlite").path
        if realProducer { try EngramDatabaseWriter(path: path).migrate() }
        let gate = try ServiceWriterGate(databasePath: path, runtimeDirectory: root)
        gateOwner = gate
        gateProbe = gate
        let handler: EngramServiceCommandHandler
        if realProducer {
            let actual = try ServiceWebMetadataProducer(databasePath: path,
                policy: { .init(parserRevision: "parser-v1", enabledSources: [.claudeCode, .codex]) })
            providerOwner = actual
            realProviderProbe = actual
            handler = EngramServiceCommandHandler(writerGate: gate, webMetadataProducer: actual)
        } else if let provider {
            providerOwner = provider
            handler = EngramServiceCommandHandler(writerGate: gate, webMetadataProducer: provider)
        } else {
            handler = EngramServiceCommandHandler(writerGate: gate)
        }
        handlerProbe = handler
        let trace = trace
        let server = UnixSocketServiceServer(socketPath: socketPath) { request in
            trace.entered(request)
            if cancelAtEntry { withUnsafeCurrentTask { $0?.cancel() } }
            let response = await handler.handle(request)
            trace.returned(response)
            return response
        }
        serverOwner = server
        try server.start()
    }

    func raw(_ command: MetadataIPCCommand, timeout: TimeInterval = 2) async throws -> RawResponse {
        try await raw(command, payload: command.payload(), timeout: timeout)
    }

    func raw(_ command: MetadataIPCCommand, payload: Data?, requestID: String = MetadataIPCFacts.requestID,
             timeout: TimeInterval = 2) async throws -> RawResponse {
        try await exchange(command: command.rawValue, payload: payload, requestID: requestID, timeout: timeout)
    }

    func exchange(command: String, payload: Data?, requestID: String = MetadataIPCFacts.requestID,
                  timeout: TimeInterval = 2) async throws -> RawResponse {
        let request = EngramServiceRequestEnvelope(requestId: requestID, command: command, payload: payload, capabilityToken: nil)
        let bytes = try JSONEncoder().encode(request)
        XCTAssertLessThanOrEqual(bytes.count, EngramServiceWebReadLimits.maximumFrameBytes, "Request itself must fit transport")
        let response = try await EngramServiceSocketIO.exchange(bytes, socketPath: socketPath, totalTimeout: timeout)
        let decoded = try JSONDecoder().decode(EngramServiceResponseEnvelope.self, from: response)
        XCTAssertEqual(Data(decoded.requestId.utf8), Data(requestID.utf8))
        return RawResponse(envelope: decoded, bytes: response)
    }

    func stopAndDrain() async -> Bool {
        guard let server = serverOwner else { return true }
        server.stop()
        return await server.drainClientHandlers(timeoutNanoseconds: 2_000_000_000)
    }

    func finish() async throws {
        guard !finished else { return }
        (providerOwner as? MetadataIPCProvider)?.releaseWaits()
        let drained = await stopAndDrain()
        XCTAssertTrue(drained, "Preserve storage if any handler remains active")
        guard drained else { return }
        try providerOwner?.stop()
        serverOwner = nil
        providerOwner = nil
        gateOwner = nil
        let deadline = ContinuousClock.now + .seconds(2)
        while (gateProbe != nil || handlerProbe != nil || realProviderProbe != nil), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let released = gateProbe == nil && handlerProbe == nil && realProviderProbe == nil
        XCTAssertTrue(released, "Release Service handler, writer and real reader before removing fixture SQLite files")
        guard released else { return }
        try FileManager.default.removeItem(at: root)
        finished = true
    }
}
