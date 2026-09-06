import Darwin
import Foundation
import XCTest
@testable import EngramRemoteServerCore

final class WebReadClientTests: XCTestCase {
    private var directory: URL!
    private static let generation = String(repeating: "a", count: 64)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("e-web-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testMessagesSendsOnlyHardcodedCommandTypedDataUUIDAndNoCapability() async throws {
        let path = socketPath()
        let sentinel = Data("fixture-secret-never-attach-or-load".utf8)
        let tokenURL = URL(fileURLWithPath: path + ".cmd.token")
        try sentinel.write(to: tokenURL)
        let request = try Self.request()
        let expected = try Self.response(request: request, fragments: [Self.fragment()])
        let server = try WebReadFixture(path: path) { fd, received in
            let envelope = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: received)
            XCTAssertNotNil(UUID(uuidString: envelope.requestId))
            XCTAssertEqual(envelope.kind, "request")
            XCTAssertEqual(envelope.command, "webMessages")
            XCTAssertNil(envelope.capabilityToken)
            XCTAssertEqual(try JSONDecoder().decode(EngramServiceWebMessagesRequest.self,
                                                   from: XCTUnwrap(envelope.payload)), request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: received) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["request_id", "kind", "command", "payload"])
            try Self.send(expected, requestId: envelope.requestId, to: fd)
        }
        defer { server.stop() }
        let actual = try await EngramServiceWebReadClient(socketPath: path).messages(request)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(try Data(contentsOf: tokenURL), sentinel)
    }

    func testAllowlistRejectsExhaustiveLiveHandlerInventoryBeforeAnyIPC() throws {
        let root = Self.repositoryRoot
        let handler = try String(contentsOf: root.appendingPathComponent("macos/EngramService/Core/EngramServiceCommandHandler.swift"), encoding: .utf8)
        let start = try XCTUnwrap(handler.range(of: "switch request.command {"))
        let end = try XCTUnwrap(handler.range(of: "\n            default:", range: start.upperBound..<handler.endIndex))
        let body = String(handler[start.upperBound..<end.lowerBound])
        let branches = try NSRegularExpression(pattern: #"(?m)^            case ([\s\S]*?):"#)
        let quotes = try NSRegularExpression(pattern: #""([^"]+)""#)
        let nsBody = body as NSString
        var commands = Set<String>()
        for branch in branches.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) {
            let cases = nsBody.substring(with: branch.range(at: 1))
            let literalCases = cases as NSString
            let matches = quotes.matches(in: cases, range: NSRange(location: 0, length: literalCases.length))
            XCTAssertFalse(matches.isEmpty, "New nonliteral handler branch needs an inventory decision")
            let remainder = quotes.stringByReplacingMatches(in: cases, range: NSRange(location: 0, length: literalCases.length), withTemplate: "")
            XCTAssertTrue(remainder.allSatisfy { $0.isWhitespace || $0 == "," })
            for match in matches { commands.insert(literalCases.substring(with: match.range(at: 1))) }
        }
        XCTAssertGreaterThan(commands.count, 60)
        XCTAssertTrue(Set(["resumeCommand", "memoryFileContent", "exportSession", "shutdown"]).isSubset(of: commands))
        XCTAssertEqual(EngramServiceWebReadClient.allowedCommands, ["webMessages", "webOverview", "webSessions", "webSessionDetail"])
        XCTAssertNoThrow(try EngramServiceWebReadClient.validateCommand("webMessages"))
        let server = try WebReadFixture(path: socketPath()) { _, _ in XCTFail("Policy checks must not perform IPC") }
        defer { server.stop() }
        for command in commands.subtracting(["webMessages", "webOverview", "webSessions", "webSessionDetail"]).union(["", "webMessages\0shutdown", "WEBMESSAGES", "futureWrite"]) {
            XCTAssertThrowsError(try EngramServiceWebReadClient.validateCommand(command)) {
                XCTAssertEqual($0 as? EngramServiceWebReadClientError, .unsupported)
            }
        }
        XCTAssertEqual(server.requestCount, 0)
        let source = try String(contentsOf: root.appendingPathComponent("macos/Shared/Service/EngramServiceWebReadClient.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("command: \"webMessages\""))
        let guardRange = try XCTUnwrap(source.range(of: "try Self.validateCommand(\"webMessages\")"))
        let exchangeRange = try XCTUnwrap(source.range(of: "EngramServiceSocketIO.exchange("))
        XCTAssertLessThan(guardRange.lowerBound, exchangeRange.lowerBound)
    }

    func testRejectsInvalidTotalDeadlinesAtConstruction() throws {
        XCTAssertEqual(EngramServiceWebReadClient.maximumTotalTimeout, 2)
        for invalid in [0.0, -1, 2.001, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try EngramServiceWebReadClient(socketPath: socketPath(), totalTimeout: invalid)) {
                XCTAssertEqual($0 as? EngramServiceWebReadClientError, .malformed)
            }
        }
        XCTAssertNoThrow(try EngramServiceWebReadClient(socketPath: socketPath(), totalTimeout: 0.05))
        XCTAssertNoThrow(try EngramServiceWebReadClient(socketPath: socketPath(), totalTimeout: 2))
    }

    func testRejectsWrongMissingFrameKindRequestIDAndAmbiguousEnvelope() async throws {
        for mutation in ["wrongKind", "missingKind", "wrongID", "missingID", "wrongOK", "bothBodies", "missingBody"] {
            await expect(.malformed) {
                try await self.exchange { request in
                    let valid = try Self.successBytes(request)
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
                    switch mutation {
                    case "wrongKind": object["kind"] = "event"
                    case "missingKind": object.removeValue(forKey: "kind")
                    case "wrongID": object["request_id"] = "different-request"
                    case "missingID": object.removeValue(forKey: "request_id")
                    case "wrongOK": object["ok"] = "true"
                    case "bothBodies": object["error"] = ["name": "StaleCursor"]
                    default: object.removeValue(forKey: "result")
                    }
                    return try JSONSerialization.data(withJSONObject: object)
                }
            }
        }
    }

    func testRejectsMalformedFrameJSONAndMalformedTypedPayload() async throws {
        for bytes in [Data("not-json".utf8), Data("[]".utf8), Data([0xFF])] {
            await expect(.malformed) { try await self.exchange { _ in bytes } }
        }
        for malformed in [Data("null".utf8), Data("{}".utf8), Data("[]".utf8)] {
            await expect(.malformed) {
                try await self.exchange {
                    try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: $0.requestId, result: malformed))
                }
            }
        }
    }

    func testRejectsResponseIdentityGenerationRolesAndProjectionMismatch() async throws {
        for mutation in ["sessionId", "generation", "roles", "projection", "redactionRevision"] {
            await expect(.malformed) {
                try await self.exchange { envelope in
                    var object = try Self.responseObject(envelope)
                    switch mutation {
                    case "sessionId": object[mutation] = "other-session"
                    case "generation": object[mutation] = String(repeating: "b", count: 64)
                    case "roles": object[mutation] = ["tool"]
                    default: object[mutation] = "unknown-version"
                    }
                    return try Self.wrap(object, requestId: envelope.requestId)
                }
            }
        }
        let request = try Self.request(sessionId: "cafe\u{301}")
        await expect(.malformed) {
            try await self.exchange(request: request) { envelope in
                var object = try Self.responseObject(envelope)
                object["sessionId"] = "caf\u{e9}"
                return try Self.wrap(object, requestId: envelope.requestId)
            }
        }
    }

    func testRejectsFragmentBudgetOrderOffsetsHashRoleAndNoProgress() async throws {
        for mutation in ["overBudget", "descending", "duplicateFinal", "offsetGap", "hashChange", "roleChange", "newOrdinalOffset", "unfinishedPrevious", "firstOffset"] {
            let request = try Self.request(maxFragments: mutation == "overBudget" ? 1 : 10)
            await expect(.malformed) {
                try await self.exchange(request: request) { envelope in
                    var object = try Self.responseObject(envelope)
                    var first = try XCTUnwrap((object["fragments"] as? [[String: Any]])?.first)
                    var second = first
                    let count = try XCTUnwrap(first["payloadFragment"] as? String).utf8.count
                    first["isLastFragment"] = false
                    second["utf8Offset"] = count
                    switch mutation {
                    case "overBudget": break
                    case "descending": first["messageOrdinal"] = 2
                    case "duplicateFinal": first["isLastFragment"] = true
                    case "offsetGap": second["utf8Offset"] = count + 1
                    case "hashChange": second["payloadSHA256"] = String(repeating: "b", count: 64)
                    case "roleChange": second["role"] = "assistant"
                    case "newOrdinalOffset": first["isLastFragment"] = true; second["messageOrdinal"] = 2
                    case "unfinishedPrevious": second["messageOrdinal"] = 2; second["utf8Offset"] = 0
                    default: first["utf8Offset"] = 1
                    }
                    object["fragments"] = [first, second]
                    return try Self.wrap(object, requestId: envelope.requestId)
                }
            }
        }
        let request = try Self.request(cursor: "opaque-cursor")
        await expect(.malformed) {
            try await self.exchange(request: request) { envelope in
                var object = try Self.responseObject(envelope)
                object["nextCursor"] = "opaque-cursor"
                return try Self.wrap(object, requestId: envelope.requestId)
            }
        }
    }

    func testAllowsRoleFilteredOrdinalGapsAndWithinPageContinuation() async throws {
        let request = try Self.request(roles: [.assistant, .user])
        let fragments = [try Self.fragment(ordinal: 2, payload: "one", last: false),
                         try Self.fragment(ordinal: 2, offset: 3, payload: "two", last: true),
                         try Self.fragment(ordinal: 7, role: .assistant, payload: "three", last: true)]
        let actual = try await exchange(request: request) { envelope in
            try JSONEncoder().encode(EngramServiceResponseEnvelope.success(
                requestId: envelope.requestId, result: JSONEncoder().encode(Self.response(request: request, fragments: fragments))
            ))
        }
        XCTAssertEqual(actual.fragments, fragments)
        XCTAssertTrue(actual.isComplete)
    }

    func testAllRolesRequireOrdinalContinuityWithoutInventingOpaqueCursorOrigin_repro() async throws {
        for mutation in ["firstGap", "pageGap", "continuedGap"] {
            let request = try Self.request(cursor: mutation == "continuedGap" ? "opaque-cursor" : nil)
            let fragments: [EngramServiceWebMessageFragment]
            switch mutation {
            case "firstGap": fragments = [try Self.fragment(ordinal: 2)]
            case "pageGap": fragments = [try Self.fragment(ordinal: 0), try Self.fragment(ordinal: 2)]
            default: fragments = [try Self.fragment(ordinal: 4), try Self.fragment(ordinal: 6)]
            }
            await expect(.malformed) {
                try await self.exchange(request: request) { envelope in
                    try JSONEncoder().encode(EngramServiceResponseEnvelope.success(
                        requestId: envelope.requestId, result: JSONEncoder().encode(Self.response(request: request, fragments: fragments))
                    ))
                }
            }
        }
        let continued = try Self.request(cursor: "opaque-cursor")
        let fragments = [try Self.fragment(ordinal: 4), try Self.fragment(ordinal: 5)]
        let actual = try await exchange(request: continued) { envelope in
            try JSONEncoder().encode(EngramServiceResponseEnvelope.success(
                requestId: envelope.requestId, result: JSONEncoder().encode(Self.response(request: continued, fragments: fragments))
            ))
        }
        XCTAssertEqual(actual.fragments, fragments, "Opaque cursors do not reveal the cross-page starting ordinal")
    }

    func testOpaqueCursorAllowsNonzeroInitialOffsetAndPreservesPartialSource() async throws {
        let request = try Self.request(cursor: "opaque-incoming-cursor")
        let fragment = try Self.fragment(offset: 42)
        let expected = try EngramServiceWebMessagesResponse(
            sessionId: request.sessionId, generation: request.generation, roles: request.roles,
            fragments: [fragment], nextCursor: nil, totalKnownComplete: false,
            truncatedAt: 100, parseFailure: "messageLimitExceeded"
        )
        let actual = try await exchange(request: request) { envelope in
            try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: envelope.requestId,
                                                                          result: JSONEncoder().encode(expected), databaseGeneration: 77))
        }
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(actual.isComplete)
    }

    func testServerFailuresExposeOnlyFixedSafeCategoriesAndNeverMessageDetails() async throws {
        let cases: [(String, EngramServiceWebReadClientError)] = [
            ("StaleCursor", .stale), ("staleCursor", .stale),
            ("UnsupportedCommand", .unsupported), ("unsupportedCommand", .unsupported),
            ("ServiceUnavailable", .unavailable), ("serviceUnavailable", .unavailable),
            ("secret-name-/private/fixture", .malformed),
        ]
        for (name, expected) in cases {
            await expect(expected) {
                try await self.exchange { request in
                    try JSONEncoder().encode(EngramServiceResponseEnvelope.failure(
                        requestId: request.requestId,
                        error: .init(name: name, message: "secret-message-/private/fixture", retryPolicy: "secret-retry",
                                     details: ["path": .string("/private/fixture"), "token": .string("secret-token")])
                    ))
                }
            }
        }
    }

    func testKernelFailuresAndOversizeFramesMapToFixedUnavailable() async throws {
        await expect(.unavailable) { try await EngramServiceWebReadClient(socketPath: self.socketPath()).messages(Self.request()) }
        for length in [UInt32(0), UInt32(EngramServiceSocketIO.maximumFrameLength + 1), UInt32.max] {
            let path = socketPath()
            let server = try WebReadFixture(path: path) { fd, _ in
                var prefix = length.bigEndian
                try withUnsafeBytes(of: &prefix) { try WebReadFixture.writeBytes(Data($0), to: fd) }
            }
            defer { server.stop() }
            let started = ContinuousClock.now
            await expect(.unavailable) {
                try await EngramServiceWebReadClient(socketPath: path, totalTimeout: 0.5).messages(Self.request())
            }
            XCTAssertLessThan(Self.elapsed(started), 1)
        }
    }

    func testAcceptsLegalEnvelopeHeadroomAbove255KiBWithDatabaseGeneration_repro() async throws {
        let path = socketPath()
        let request = try Self.request()
        // Construct the large fixture before the client's total deadline starts.
        // UUID wire length is fixed, independent of the actual request identity.
        let fixtureRequestID = UUID().uuidString
        var lower = 1
        var upper = 220 * 1024
        var chosen = Data()
        var originalSize = 0
        while lower <= upper {
            let count = lower + (upper - lower) / 2
            let text = "{\"content\":\"" + String(repeating: "a", count: count) + "\",\"role\":\"user\"}"
            let fragment = try EngramServiceWebMessageFragment(
                messageOrdinal: 0, role: .user, payloadSHA256: ArchiveV2Hash.sha256(Data(text.utf8)),
                utf8Offset: 0, payloadFragment: text, isLastFragment: true
            )
            let payload = try JSONEncoder().encode(Self.response(request: request, fragments: [fragment]))
            let baseline = try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: fixtureRequestID, result: payload))
            if baseline.count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes {
                chosen = payload
                originalSize = baseline.count
                lower = count + 1
            } else {
                upper = count - 1
            }
        }
        let fixturePayload = chosen
        let fixtureOriginalSize = originalSize
        let server = try WebReadFixture(path: path) { fd, received in
            let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: received)
            let final = try JSONEncoder().encode(EngramServiceResponseEnvelope.success(
                requestId: incoming.requestId, result: fixturePayload, databaseGeneration: Int.max
            ))
            XCTAssertFalse(fixturePayload.isEmpty)
            XCTAssertLessThanOrEqual(fixtureOriginalSize, 255 * 1024)
            XCTAssertGreaterThan(final.count, 255 * 1024)
            XCTAssertLessThanOrEqual(final.count, EngramServiceSocketIO.maximumFrameLength)
            print("WEB_READ_HEADROOM_FIXTURE baseline=\(fixtureOriginalSize) final=\(final.count)")
            try EngramServiceSocketIO.writeFrame(final, to: fd, requestTimeout: 1)
        }
        defer { server.stop() }
        do {
            let response = try await EngramServiceWebReadClient(socketPath: path).messages(request)
            XCTAssertEqual(response.fragments.count, 1)
            XCTAssertGreaterThan(try XCTUnwrap(response.fragments.first).payloadFragment.utf8.count, 160 * 1024)
        } catch {
            XCTFail("A legal 255...256 KiB response envelope must not be rejected")
        }
        XCTAssertEqual(server.requestCount, 1)
    }

    func testClientPreservesSocketSafetyWithoutRepairingPaths() async throws {
        let regular = socketPath()
        let sentinel = Data("keep-file-secret".utf8)
        try sentinel.write(to: URL(fileURLWithPath: regular))
        await expect(.unavailable) { try await EngramServiceWebReadClient(socketPath: regular).messages(Self.request()) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: regular)), sentinel)
        let path = socketPath()
        let server = try WebReadFixture(path: path) { _, _ in XCTFail("Unsafe sockets must fail before request") }
        defer { server.stop() }
        let alias = socketPath()
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
        await expect(.unavailable) { try await EngramServiceWebReadClient(socketPath: alias).messages(Self.request()) }
        XCTAssertEqual(chmod(path, 0o666), 0)
        await expect(.unavailable) { try await EngramServiceWebReadClient(socketPath: path).messages(Self.request()) }
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o666)
        XCTAssertEqual(server.requestCount, 0)
    }

    func testTotalDeadlineBoundsAContinuouslyTricklingResponse() async throws {
        let path = socketPath()
        let server = try WebReadFixture(path: path) { fd, _ in
            var length = UInt32(100).bigEndian
            let bytes = withUnsafeBytes(of: &length) { Array($0) } + Array(repeating: UInt8(65), count: 100)
            for byte in bytes {
                try WebReadFixture.writeBytes(Data([byte]), to: fd)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        defer { server.stop() }
        let started = ContinuousClock.now
        await expect(.unavailable) {
            try await EngramServiceWebReadClient(socketPath: path, totalTimeout: 0.15).messages(Self.request())
        }
        XCTAssertLessThan(Self.elapsed(started), 1, "Progress must not renew the total deadline")
    }

    func testCancellationClosesInFlightPeerAndPreservesCancellationError() async throws {
        let path = socketPath()
        let received = expectation(description: "typed request arrived")
        let closed = expectation(description: "cancelled client closed peer")
        let server = try WebReadFixture(path: path) { fd, _ in
            received.fulfill()
            var byte: UInt8 = 0
            while true {
                let count = recv(fd, &byte, 1, 0)
                if count < 0 && errno == EINTR { continue }
                if count == 0 { closed.fulfill() }
                break
            }
        }
        defer { server.stop() }
        let task = Task { try await EngramServiceWebReadClient(socketPath: path).messages(Self.request()) }
        await fulfillment(of: [received], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected CancellationError") }
        catch is CancellationError {}
        catch { XCTFail("Wrong cancellation category") }
        await fulfillment(of: [closed], timeout: 1)
    }

    func testAlreadyCancelledCallPerformsNoIPC() async throws {
        let path = socketPath()
        let server = try WebReadFixture(path: path) { _, _ in XCTFail("Cancelled before dispatch") }
        defer { server.stop() }
        let entered = expectation(description: "task parked")
        let gate = WebReadGate(entered: entered)
        let task = Task {
            await gate.wait()
            return try await EngramServiceWebReadClient(socketPath: path).messages(Self.request())
        }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Expected CancellationError") }
        catch is CancellationError {}
        catch { XCTFail("Wrong cancellation category") }
        XCTAssertEqual(server.requestCount, 0)
    }

    func testRemoteProductLinksOnlyExplicitWireAndKernelSourcesWithoutDatabaseCore() throws {
        let root = Self.repositoryRoot
        let project = try String(contentsOf: root.appendingPathComponent("macos/project.yml"), encoding: .utf8)
        let start = try XCTUnwrap(project.range(of: "  EngramRemoteServerCore:\n"))
        let end = try XCTUnwrap(project.range(of: "\n  EngramRemoteServer:\n", range: start.upperBound..<project.endIndex))
        let target = String(project[start.upperBound..<end.lowerBound])
        let expected = Set(["EngramServiceSocketIO.swift", "EngramServiceWireEnvelopes.swift", "EngramServiceError.swift",
                            "EngramServiceWebReadModels.swift", "EngramServiceWebReadClient.swift"])
        let serviceFiles = target.split(separator: "\n").filter { $0.contains("path: Shared/Service/") }
            .compactMap { $0.split(separator: "/").last.map(String.init) }
        XCTAssertEqual(Set(serviceFiles), expected)
        for forbidden in ["EngramCoreRead", "EngramCoreWrite", "GRDB", "EngramServiceModels.swift",
                          "EngramServiceClient.swift", "UnixSocketEngramServiceTransport.swift", "ServiceCapabilityToken.swift"] {
            XCTAssertFalse(target.contains(forbidden), forbidden)
        }
        let client = try String(contentsOf: root.appendingPathComponent("macos/Shared/Service/EngramServiceWebReadClient.swift"), encoding: .utf8)
        for forbidden in ["import EngramCore", "ServiceCapabilityToken", "UnixSocketEngramServiceTransport",
                          "EngramServiceClient(", ".asError(", "FileManager", "homeDirectoryForCurrentUser"] {
            XCTAssertFalse(client.contains(forbidden), forbidden)
        }
    }

    private func socketPath() -> String { directory.appendingPathComponent("\(UUID().uuidString.prefix(8)).sock").path }

    private func exchange(request: EngramServiceWebMessagesRequest? = nil,
                          response: @escaping @Sendable (EngramServiceRequestEnvelope) throws -> Data) async throws -> EngramServiceWebMessagesResponse {
        let path = socketPath()
        let server = try WebReadFixture(path: path) { fd, bytes in
            let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
            try EngramServiceSocketIO.writeFrame(response(incoming), to: fd, requestTimeout: 1)
        }
        defer { server.stop() }
        return try await EngramServiceWebReadClient(socketPath: path, totalTimeout: 0.5).messages(request ?? Self.request())
    }

    private func expect(_ expected: EngramServiceWebReadClientError, file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () async throws -> EngramServiceWebMessagesResponse) async {
        do { _ = try await operation(); XCTFail("Expected \(expected.rawValue)", file: file, line: line) }
        catch let error as EngramServiceWebReadClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
            for forbidden in ["secret", "/private/fixture", directory.path] {
                XCTAssertFalse(error.localizedDescription.contains(forbidden), file: file, line: line)
                XCTAssertFalse(String(describing: error).contains(forbidden), file: file, line: line)
            }
        } catch { XCTFail("Unexpected error category", file: file, line: line) }
    }

    private static func request(sessionId: String = "session", roles: [EngramServiceWebMessageRole] = EngramServiceWebMessageRole.allCases,
                                cursor: String? = nil, maxFragments: Int = 10) throws -> EngramServiceWebMessagesRequest {
        try .init(sessionId: sessionId, generation: generation, roles: roles, cursor: cursor, maxFragments: maxFragments)
    }

    private static func fragment(ordinal: Int = 0, role: EngramServiceWebMessageRole = .user,
                                 offset: Int = 0, payload: String = "{\"content\":\"hello\",\"role\":\"user\"}",
                                 last: Bool = true) throws -> EngramServiceWebMessageFragment {
        try .init(messageOrdinal: ordinal, role: role, payloadSHA256: generation, utf8Offset: offset,
                  payloadFragment: payload, isLastFragment: last)
    }

    private static func response(request: EngramServiceWebMessagesRequest,
                                  fragments: [EngramServiceWebMessageFragment]) throws -> EngramServiceWebMessagesResponse {
        try .init(sessionId: request.sessionId, generation: request.generation, roles: request.roles,
                  fragments: fragments, nextCursor: nil, totalKnownComplete: true, truncatedAt: nil, parseFailure: nil)
    }

    private static func successBytes(_ request: EngramServiceRequestEnvelope) throws -> Data {
        let input = try JSONDecoder().decode(EngramServiceWebMessagesRequest.self, from: XCTUnwrap(request.payload))
        return try JSONEncoder().encode(EngramServiceResponseEnvelope.success(
            requestId: request.requestId, result: JSONEncoder().encode(response(request: input, fragments: [fragment()]))
        ))
    }

    private static func responseObject(_ request: EngramServiceRequestEnvelope) throws -> [String: Any] {
        let input = try JSONDecoder().decode(EngramServiceWebMessagesRequest.self, from: XCTUnwrap(request.payload))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response(request: input, fragments: [fragment()]))) as? [String: Any])
    }

    private static func wrap(_ object: [String: Any], requestId: String) throws -> Data {
        try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: requestId,
                                                                       result: JSONSerialization.data(withJSONObject: object)))
    }

    private static func send(_ response: EngramServiceWebMessagesResponse, requestId: String, to fd: Int32) throws {
        try EngramServiceSocketIO.writeFrame(JSONEncoder().encode(EngramServiceResponseEnvelope.success(
            requestId: requestId, result: JSONEncoder().encode(response)
        )), to: fd, requestTimeout: 1)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

private final class WebReadFixture: @unchecked Sendable {
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
        guard listener >= 0 else { throw FixtureFailure() }
        do {
            try EngramServiceSocketIO.withSockAddr(path: path) {
                guard Darwin.bind(listener, $0, $1) == 0 else { throw FixtureFailure() }
            }
            guard chmod(path, 0o600) == 0, listen(listener, 1) == 0,
                  fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw FixtureFailure() }
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
                let stoppedAfterAccept = stopped
                lock.unlock()
                if stoppedAfterAccept { return }
                do {
                    let flags = fcntl(fd, F_GETFL)
                    guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw FixtureFailure() }
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

    static func writeBytes(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FixtureFailure() }
                offset += count
            }
        }
    }

    private struct FixtureFailure: Error {}
}

private actor WebReadGate {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(entered: XCTestExpectation) { self.entered = entered }

    func wait() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Contract-only metadata coverage. Socket fixtures do not establish a Service
/// producer, cursor-issuer authority, FTS readiness, or browser acceptance.
final class WebMetadataClientTests: XCTestCase {
    private var directory: URL!
    private static let machine = "AAAAAAAA-0000-4000-8000-000000000001"
    private static let instance = "BBBBBBBB-0000-4000-8000-000000000002"
    private static let epoch = "CCCCCCCC-0000-4000-8000-000000000003"
    private static let snapshot = "DDDDDDDD-0000-4000-8000-000000000004"
    private static let otherSnapshot = "EEEEEEEE-0000-4000-8000-000000000005"
    private static let generation = String(repeating: "a", count: 64)
    private static let newerGeneration = String(repeating: "b", count: 64)
    private static let maximumCount: Int64 = 9_007_199_254_740_991
    private static let maximumTime: Int64 = 253_402_300_799
    private static let now: Int64 = 1_788_660_000

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("e-web-m-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testUnknownObservationsRemainNilWhileMeasuredZerosRemainZero() {
        guard let page = decode(EngramServiceWebOverviewResponse.self, Self.overview()) else { return }
        XCTAssertEqual(page.capabilities.keywordSearch, .unknown)
        XCTAssertEqual(page.capabilities.transcriptRead, .unavailable)
        guard let stream = page.streams.first else { return XCTFail("Expected a registered stream") }
        XCTAssertNil(stream.heartbeatAt)
        XCTAssertNil(stream.lastCapture)
        XCTAssertNil(stream.replicaACKs)
        XCTAssertNil(stream.fts)
        XCTAssertNil(stream.ai)
        XCTAssertEqual(stream.ingest?.publicationCount, 0)
        XCTAssertEqual(stream.ingest?.taskCounts.pending, 0)
        XCTAssertEqual(stream.ingest?.taskCounts.indexReady, 0)
        XCTAssertEqual(stream.ingest?.parseFailureTasks, 0)
        XCTAssertNil(stream.ingest?.oldestPendingAt)
        // A measured zero ledger count is not a measured zero FTS session count.
        XCTAssertNil(stream.fts?.readyLogicalSessions)
    }

    func testNullAndOmittedStagesDoNotBecomeEmptyArraysHealthyOrAvailable() {
        var stream = Self.stream()
        for field in ["registry", "ingest", "heartbeatAt", "lastCapture", "replicaACKs", "fts", "ai"] {
            stream[field] = NSNull()
        }
        guard let unknown = decode(EngramServiceWebStreamOverview.self, stream) else { return }
        XCTAssertNil(unknown.registry)
        XCTAssertNil(unknown.ingest)
        XCTAssertNil(unknown.replicaACKs)
        var measured = Self.stream()
        measured["replicaACKs"] = []
        measured["fts"] = ["observedAt": Self.now, "readyLogicalSessions": 0]
        guard let observed = decode(EngramServiceWebStreamOverview.self, measured) else { return }
        XCTAssertEqual(observed.replicaACKs?.count, 0)
        XCTAssertEqual(observed.fts?.readyLogicalSessions, 0)
        XCTAssertEqual(observed.fts?.observedAt, Self.now)
    }

    func testDefaultRequestConstructorsAndInclusivePageLimits() {
        do {
            let overview = try EngramServiceWebOverviewRequest()
            let sessions = try EngramServiceWebSessionsRequest()
            XCTAssertEqual(overview.limit, 50)
            XCTAssertNil(overview.cursor)
            XCTAssertNil(overview.snapshotId)
            XCTAssertEqual(sessions.limit, 50)
            XCTAssertNil(sessions.query)
            XCTAssertNil(sessions.source)
            XCTAssertNil(sessions.machineId)
            XCTAssertNil(sessions.sourceInstanceId)
            XCTAssertNil(sessions.projectKey)
            XCTAssertNil(sessions.cursor)
            XCTAssertNil(sessions.snapshotId)
            for limit in [1, 100] {
                XCTAssertEqual(try EngramServiceWebOverviewRequest(limit: limit).limit, limit)
                XCTAssertEqual(try EngramServiceWebSessionsRequest(limit: limit).limit, limit)
            }
        } catch { XCTFail("Valid default/boundary requests must be constructible") }
        for limit in [Int.min, -1, 0, 101, Int.max] {
            XCTAssertThrowsError(try EngramServiceWebOverviewRequest(limit: limit))
            XCTAssertThrowsError(try EngramServiceWebSessionsRequest(limit: limit))
        }
        for value: Any in [0, 101, -1, 1.5, true, NSNull()] {
            invalid(EngramServiceWebOverviewRequest.self, ["limit": value])
            invalid(EngramServiceWebSessionsRequest.self, ["limit": value])
        }
    }

    func testPairedCursorSnapshotCanonicalUUIDAndCursorByteBounds() {
        for cursor in ["a", String(repeating: "x", count: 1024), "opaque_-09"] {
            let object: [String: Any] = ["limit": 1, "snapshotId": Self.snapshot, "cursor": cursor]
            _ = decode(EngramServiceWebOverviewRequest.self, object)
            _ = decode(EngramServiceWebSessionsRequest.self, object)
        }
        let invalidPairs: [[String: Any]] = [
            ["cursor": "next"], ["snapshotId": Self.snapshot], ["snapshotId": Self.snapshot, "cursor": NSNull()],
            ["snapshotId": NSNull(), "cursor": "next"],
        ]
        for pair in invalidPairs {
            let object = ["limit": 1].merging(pair) { _, value in value }
            invalid(EngramServiceWebOverviewRequest.self, object)
            invalid(EngramServiceWebSessionsRequest.self, object)
        }
        for cursor in ["", String(repeating: "x", count: 1025), "é", "bad+token", "bad/token", "bad=token", "x\0y", "x y"] {
            let object: [String: Any] = ["limit": 1, "snapshotId": Self.snapshot, "cursor": cursor]
            invalid(EngramServiceWebOverviewRequest.self, object)
            invalid(EngramServiceWebSessionsRequest.self, object)
        }
        for uuid in Self.invalidUUIDs {
            let object: [String: Any] = ["limit": 1, "snapshotId": uuid, "cursor": "next"]
            invalid(EngramServiceWebOverviewRequest.self, object)
            invalid(EngramServiceWebSessionsRequest.self, object)
        }
        XCTAssertThrowsError(try EngramServiceWebOverviewRequest(snapshotId: Self.snapshot))
        XCTAssertThrowsError(try EngramServiceWebSessionsRequest(cursor: "next"))
    }

    func testQueryIsOptionalKeywordTextWithExactUTF8IdentityAndBounds() {
        for query in ["x", "中", "e\u{301}", "é", String(repeating: "中", count: 341) + "a"] {
            guard let input = decode(EngramServiceWebSessionsRequest.self, ["query": query, "limit": 50]) else { continue }
            XCTAssertEqual(Data(input.query?.utf8 ?? "".utf8), Data(query.utf8))
            do {
                let encoded = try JSONEncoder().encode(input)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                XCTAssertEqual(Data((object["query"] as? String ?? "").utf8), Data(query.utf8))
            } catch { XCTFail("Valid query must preserve its original bytes") }
        }
        for query in ["", " ", " x", "x ", "\nx", "x\n", "x\0y", String(repeating: "中", count: 342)] {
            invalid(EngramServiceWebSessionsRequest.self, ["query": query, "limit": 50])
            XCTAssertThrowsError(try EngramServiceWebSessionsRequest(query: query))
        }
        XCTAssertNotEqual(Data("e\u{301}".utf8), Data("é".utf8))
    }

    func testSourceMachineInstanceAndOpaqueProjectFilterBounds() {
        for source in ["a", "claude-code", "source_09", "a" + String(repeating: "x", count: 63)] {
            _ = decode(EngramServiceWebSessionsRequest.self, ["source": source, "limit": 1])
        }
        for source in ["", "Codex", "-codex", "9codex", "a/b", "a.b", "é", "a\0b", String(repeating: "x", count: 65)] {
            invalid(EngramServiceWebSessionsRequest.self, ["source": source, "limit": 1])
            invalid(EngramServiceWebSourceBinding.self, Self.replacing(Self.binding(), "source", source))
            invalid(EngramServiceWebSessionSummary.self, Self.replacing(Self.summary(), "source", source))
        }
        _ = decode(EngramServiceWebSessionsRequest.self, [
            "machineId": Self.machine, "sourceInstanceId": Self.instance, "limit": 1,
        ])
        invalid(EngramServiceWebSessionsRequest.self, ["sourceInstanceId": Self.instance, "limit": 1])
        XCTAssertThrowsError(try EngramServiceWebSessionsRequest(sourceInstanceId: Self.instance))
        for uuid in Self.invalidUUIDs {
            for field in ["machineId", "sourceInstanceId"] {
                invalid(EngramServiceWebSessionsRequest.self,
                        Self.replacing(["machineId": Self.machine, "sourceInstanceId": Self.instance, "limit": 1], field, uuid))
                invalid(EngramServiceWebCaptureIdentity.self,
                        Self.replacing(Self.captureIdentity(), field, uuid))
                invalid(EngramServiceWebStreamOverview.self, Self.replacing(Self.stream(), field, uuid))
            }
        }
        for key in ["p", "opaque_-09", String(repeating: "k", count: 128)] {
            _ = decode(EngramServiceWebSessionsRequest.self, ["projectKey": key, "limit": 1])
        }
        for key in ["", "/private/project", "file:project", "p.q", "é", "a\0b", String(repeating: "k", count: 129)] {
            invalid(EngramServiceWebSessionsRequest.self, ["projectKey": key, "limit": 1])
            invalid(EngramServiceWebSessionSummary.self, Self.replacing(Self.summary(), "projectKey", key))
        }
    }

    func testSessionIdentityBoundsNeverNormalizeOrTrim() {
        for id in ["x", " e\u{301} ", "é", String(repeating: "中", count: 1365) + "a"] {
            guard let input = decode(EngramServiceWebSessionDetailRequest.self, ["sessionId": id]) else { continue }
            XCTAssertEqual(Data(input.sessionId.utf8), Data(id.utf8))
            _ = decode(EngramServiceWebSessionSummary.self, Self.replacing(Self.summary(), "sessionId", id))
        }
        for id in ["", "a\0b", String(repeating: "中", count: 1366)] {
            invalid(EngramServiceWebSessionDetailRequest.self, ["sessionId": id])
            invalid(EngramServiceWebSessionSummary.self, Self.replacing(Self.summary(), "sessionId", id))
            XCTAssertThrowsError(try EngramServiceWebSessionDetailRequest(sessionId: id))
        }
    }

    func testRegistryEpochAndPositiveDecimalCountersPreserveInt64WithoutRounding() {
        for counter in ["1", String(Int64.max)] {
            _ = decode(EngramServiceWebSourceBinding.self, Self.replacing(Self.binding(), "authorityGeneration", counter))
            for field in ["authorityGeneration", "sequence"] {
                _ = decode(EngramServiceWebGenerationSummary.self, Self.replacing(Self.generationSummary(), field, counter))
            }
            _ = decode(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "sequence", counter))
        }
        for counter: Any in ["", "0", "01", "-1", "+1", "1 ", "1.0", "9223372036854775808", "１２", 1, true, NSNull()] {
            invalid(EngramServiceWebSourceBinding.self, Self.replacing(Self.binding(), "authorityGeneration", counter))
            for field in ["authorityGeneration", "sequence"] {
                invalid(EngramServiceWebGenerationSummary.self, Self.replacing(Self.generationSummary(), field, counter))
            }
            invalid(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "sequence", counter))
        }
        for uuid in Self.invalidUUIDs {
            invalid(EngramServiceWebSourceBinding.self, Self.replacing(Self.binding(), "approvedEpoch", uuid))
            invalid(EngramServiceWebGenerationSummary.self, Self.replacing(Self.generationSummary(), "collectorEpoch", uuid))
            invalid(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "collectorEpoch", uuid))
        }
    }

    func testAllCountFieldsRespectSafeIntegerBoundsAndKeepTaskUnitsSeparate() {
        let fields = ["pending", "processing", "parsed", "indexReady", "retryableFailure", "quarantined"]
        for field in fields {
            for count in [Int64(0), Self.maximumCount] {
                _ = decode(EngramServiceWebIngestTaskCounts.self, Self.replacing(Self.taskCounts(), field, count))
            }
            for count: Any in [-1, Self.maximumCount + 1, 1.5, true, NSNull()] {
                invalid(EngramServiceWebIngestTaskCounts.self, Self.replacing(Self.taskCounts(), field, count))
            }
        }
        for count in [Int64(0), Self.maximumCount] {
            _ = decode(EngramServiceWebIngestObservation.self, Self.replacing(Self.ingest(), "publicationCount", count))
            _ = decode(EngramServiceWebFTSObservation.self, ["observedAt": Self.now, "readyLogicalSessions": count])
            _ = decode(EngramServiceWebReplicaACKObservation.self, Self.replacing(Self.ack(), "lagSeconds", count))
        }
        for count: Any in [-1, Self.maximumCount + 1, 1.5, true] {
            invalid(EngramServiceWebIngestObservation.self, Self.replacing(Self.ingest(), "publicationCount", count))
            invalid(EngramServiceWebIngestObservation.self, Self.replacing(Self.ingest(), "parseFailureTasks", count))
            invalid(EngramServiceWebFTSObservation.self, ["observedAt": Self.now, "readyLogicalSessions": count])
            invalid(EngramServiceWebReplicaACKObservation.self, Self.replacing(Self.ack(), "lagSeconds", count))
        }
        invalid(EngramServiceWebIngestObservation.self, Self.replacing(Self.ingest(), "parseFailureTasks", 1))
        var observed = Self.ingest()
        observed["publicationCount"] = 1
        observed["taskCounts"] = Self.replacing(Self.taskCounts(), "quarantined", 2)
        observed["parseFailureTasks"] = 2
        // Two parser-revision tasks for one publication are valid, not two sessions.
        _ = decode(EngramServiceWebIngestObservation.self, observed)
    }

    func testAllTimestampSlotsEnforceUnixSecondsWithoutInventingMissingTimes() {
        for time in [Int64(0), Self.maximumTime] {
            checkTime(time, valid: true)
        }
        for time: Any in [-1, Self.maximumTime + 1, 1.5, true, "2026-09-06T00:00:00Z"] {
            checkTime(time, valid: false)
        }
    }

    func testEveryMetadataEnumRejectsUnknownOrHealthyValues() {
        for value in ["unknown", "unavailable", "available"] {
            _ = decode(EngramServiceWebCapabilities.self, ["keywordSearch": value, "transcriptRead": value])
        }
        for value in ["", "healthy", "ready", "semantic", "hybrid", "UNKNOWN"] {
            for field in ["keywordSearch", "transcriptRead"] {
                invalid(EngramServiceWebCapabilities.self, Self.replacing(Self.capabilities(), field, value))
            }
            invalid(EngramServiceWebSessionDetail.self, Self.replacing(Self.detail(), "transcriptAvailability", value))
        }
        for state in ["notConfigured", "backoff", "idle", "running", "failed"] {
            _ = decode(EngramServiceWebAIObservation.self, ["observedAt": Self.now, "state": state])
        }
        for state in ["", "healthy", "ready", "unknown", "RUNNING"] {
            invalid(EngramServiceWebAIObservation.self, ["observedAt": Self.now, "state": state])
        }
        for status in ["pending", "processing", "parsed", "indexReady", "retryableFailure", "quarantined"] {
            _ = decode(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "status", status))
        }
        for status in ["", "healthy", "index_ready", "failed_retryable", "PARSED", "available"] {
            invalid(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "status", status))
        }
    }

    func testReplicaObservationArraySymbolicServerNamesAndHashesAreBounded() {
        for count in [0, 16] {
            let acks = (0..<count).map { Self.replacing(Self.ack(), "serverId", "replica-\($0)") }
            _ = decode(EngramServiceWebStreamOverview.self, Self.replacing(Self.stream(), "replicaACKs", acks))
        }
        let tooMany = (0..<17).map { Self.replacing(Self.ack(), "serverId", "replica-\($0)") }
        invalid(EngramServiceWebStreamOverview.self, Self.replacing(Self.stream(), "replicaACKs", tooMany))
        invalid(EngramServiceWebStreamOverview.self, Self.replacing(Self.stream(), "replicaACKs", [Self.ack(), Self.ack()]))
        for id in ["h", "HQ-01.a_b", String(repeating: "h", count: 128)] {
            _ = decode(EngramServiceWebReplicaACKObservation.self, Self.replacing(Self.ack(), "serverId", id))
        }
        for id in ["", "/private/hq", "hq:1", "hq token", "é", "h\0q", String(repeating: "h", count: 129)] {
            invalid(EngramServiceWebReplicaACKObservation.self, Self.replacing(Self.ack(), "serverId", id))
        }
        for hash in Self.invalidHashes {
            invalid(EngramServiceWebReplicaACKObservation.self, Self.replacing(Self.ack(), "publicationSHA256", hash))
            invalid(EngramServiceWebCaptureObservation.self, ["manifestSHA256": hash, "observedAt": Self.now])
        }
    }

    func testDisplayTextAndEveryGenerationHashUseUTF8Bounds() {
        for text in ["", String(repeating: "中", count: 341) + "a"] {
            _ = decode(EngramServiceWebSessionSummary.self, Self.replacing(Self.summary(), "title", text))
        }
        invalid(EngramServiceWebSessionSummary.self,
                Self.replacing(Self.summary(), "title", String(repeating: "中", count: 342)))
        _ = decode(EngramServiceWebSessionSummary.self,
                   Self.replacing(Self.summary(), "projectLabel", String(repeating: "中", count: 85) + "a"))
        invalid(EngramServiceWebSessionSummary.self,
                Self.replacing(Self.summary(), "projectLabel", String(repeating: "中", count: 86)))
        for hash in Self.invalidHashes {
            invalid(EngramServiceWebSessionSummary.self, Self.replacing(Self.summary(), "metadataGeneration", hash))
            for field in ["generationId", "publicationSHA256"] {
                invalid(EngramServiceWebGenerationSummary.self, Self.replacing(Self.generationSummary(), field, hash))
            }
            invalid(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "publicationSHA256", hash))
            invalid(EngramServiceWebSessionDetail.self, Self.replacing(Self.detail(), "transcriptGeneration", hash))
        }
        for count in [0, 10_000] {
            _ = decode(EngramServiceWebGenerationSummary.self, Self.replacing(Self.generationSummary(), "normalizedMessageCount", count))
        }
        for count: Any in [-1, 10_001, 1.5, true] {
            invalid(EngramServiceWebGenerationSummary.self, Self.replacing(Self.generationSummary(), "normalizedMessageCount", count))
        }
    }

    func testParserRevisionBoundAndSymbolicFailureAllowlistNeverExposeDiagnostics() {
        for revision in ["r", "r" + String(repeating: "中", count: 42) + "a"] {
            _ = decode(EngramServiceWebGenerationSummary.self, Self.replacing(Self.generationSummary(), "parserRevision", revision))
            _ = decode(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "parserRevision", revision))
        }
        for revision in ["", " r1", "r1 ", "r\0x", String(repeating: "中", count: 43)] {
            invalid(EngramServiceWebGenerationSummary.self, Self.replacing(Self.generationSummary(), "parserRevision", revision))
            invalid(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "parserRevision", revision))
        }
        for code in Self.safeFailureCodes {
            _ = decode(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "failureCode", code))
        }
        for code in ["", "parse.unknown", "retry.future", "quarantine.future", "/private/path", "token=secret", String(repeating: "x", count: 65)] {
            invalid(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "failureCode", code))
        }
    }

    func testDetailPreservesDivergentHeadsButCannotAdvertiseTheirTranscriptAsReady() {
        var detail = Self.detail()
        let parsed = Self.replacing(Self.generationSummary(), "generationId", Self.newerGeneration)
        detail["lastParsed"] = parsed
        detail["session"] = Self.replacing(Self.summary(), "metadataGeneration", Self.newerGeneration)
        detail["transcriptAvailability"] = "unavailable"
        detail["transcriptGeneration"] = NSNull()
        guard let unavailable = decode(EngramServiceWebSessionDetail.self, detail) else { return }
        XCTAssertEqual(unavailable.lastParsed?.generationId, Self.newerGeneration)
        XCTAssertEqual(unavailable.lastReady?.generationId, Self.generation)
        XCTAssertNil(unavailable.transcriptGeneration)
        XCTAssertEqual(unavailable.transcriptAvailability, .unavailable)
        detail["transcriptAvailability"] = "available"
        for generation in [Self.generation, Self.newerGeneration] {
            detail["transcriptGeneration"] = generation
            invalid(EngramServiceWebSessionDetail.self, detail)
        }
    }

    func testAvailableTranscriptRequiresExactEqualHeadsAndCurrentMetadataMarker() {
        _ = decode(EngramServiceWebSessionDetail.self, Self.detail())
        for field in ["lastParsed", "lastReady", "transcriptGeneration"] {
            invalid(EngramServiceWebSessionDetail.self, Self.replacing(Self.detail(), field, NSNull()))
        }
        for state in ["unknown", "unavailable"] {
            invalid(EngramServiceWebSessionDetail.self, Self.replacing(Self.detail(), "transcriptAvailability", state))
            var object = Self.detail()
            object["transcriptAvailability"] = state
            object["transcriptGeneration"] = NSNull()
            _ = decode(EngramServiceWebSessionDetail.self, object)
        }
        invalid(EngramServiceWebSessionDetail.self, Self.replacing(Self.detail(), "transcriptGeneration", Self.newerGeneration))
        for marker: Any in [NSNull(), Self.newerGeneration] {
            invalid(EngramServiceWebSessionDetail.self,
                    Self.replacing(Self.detail(), "session", Self.replacing(Self.summary(), "metadataGeneration", marker)))
        }
    }

    func testAProvenNewParseFailureDoesNotEraseOrPromoteLastGoodHeads() {
        var detail = Self.detail()
        var failed = Self.attempt()
        failed["publicationSHA256"] = Self.newerGeneration
        failed["sequence"] = "2"
        failed["status"] = "quarantined"
        failed["failureCode"] = "parse.truncatedJSONL"
        detail["currentAttempt"] = failed
        guard let response = decode(EngramServiceWebSessionDetail.self, detail) else { return }
        XCTAssertEqual(response.lastParsed?.generationId, Self.generation)
        XCTAssertEqual(response.lastReady?.generationId, Self.generation)
        XCTAssertEqual(response.transcriptGeneration, Self.generation)
        XCTAssertEqual(response.currentAttempt?.failureCode, "parse.truncatedJSONL")
        XCTAssertEqual(response.currentAttempt?.publicationSHA256, Self.newerGeneration)
        // The real producer must prove the failed publication's session binding.
        // This fixture supplies that proof's output; it does not create a producer.
        guard let noAttempt = decode(EngramServiceWebSessionDetail.self, Self.detail()) else { return }
        XCTAssertNil(noAttempt.currentAttempt)
    }

    func testMetadataPageBoundsAndDuplicateKeysUseExactIdentityBytes() {
        for count in [0, 100] {
            let streams = (0..<count).map { _ in Self.replacing(Self.stream(), "sourceInstanceId", UUID().uuidString) }
            _ = decode(EngramServiceWebOverviewResponse.self, Self.replacing(Self.overview(), "streams", streams))
            let items = (0..<count).map { Self.summary(id: "session-\($0)") }
            _ = decode(EngramServiceWebSessionsResponse.self, Self.replacing(Self.sessions(), "items", items))
        }
        invalid(EngramServiceWebOverviewResponse.self,
                Self.replacing(Self.overview(), "streams", (0..<101).map { _ in Self.replacing(Self.stream(), "sourceInstanceId", UUID().uuidString) }))
        invalid(EngramServiceWebSessionsResponse.self,
                Self.replacing(Self.sessions(), "items", (0..<101).map { Self.summary(id: "session-\($0)") }))
        invalid(EngramServiceWebOverviewResponse.self, Self.replacing(Self.overview(), "streams", [Self.stream(), Self.stream()]))
        invalid(EngramServiceWebSessionsResponse.self, Self.replacing(Self.sessions(), "items", [Self.summary(), Self.summary()]))
        let distinct = [Self.summary(id: "cafe\u{301}"), Self.summary(id: "caf\u{e9}")]
        guard let page = decode(EngramServiceWebSessionsResponse.self, Self.replacing(Self.sessions(), "items", distinct)) else { return }
        XCTAssertEqual(page.items.count, 2)
        XCTAssertNotEqual(Data(page.items[0].sessionId.utf8), Data(page.items[1].sessionId.utf8))
    }

    func testResponseSnapshotCursorAndNonemptyContinuationRequirements() {
        for uuid in Self.invalidUUIDs {
            invalid(EngramServiceWebOverviewResponse.self, Self.replacing(Self.overview(), "snapshotId", uuid))
            invalid(EngramServiceWebSessionsResponse.self, Self.replacing(Self.sessions(), "snapshotId", uuid))
        }
        for cursor in ["", "bad/token", "bad+token", "é", String(repeating: "x", count: 1025)] {
            invalid(EngramServiceWebOverviewResponse.self, Self.replacing(Self.overview(), "nextCursor", cursor))
            invalid(EngramServiceWebSessionsResponse.self, Self.replacing(Self.sessions(), "nextCursor", cursor))
        }
        for kind in [MetadataKind.overview, .sessions] {
            var page = Self.page(kind)
            page[kind == .overview ? "streams" : "items"] = []
            page["nextCursor"] = "next"
            if kind == .overview { invalid(EngramServiceWebOverviewResponse.self, page) }
            else { invalid(EngramServiceWebSessionsResponse.self, page) }
        }
    }

    func testMetadataRoundtripHasOnlyExplicitSafeDisplayFields() throws {
        let summary = try XCTUnwrap(decode(EngramServiceWebSessionSummary.self, Self.summary()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sessionId", "source", "captureIdentity", "metadataGeneration", "title", "projectKey", "projectLabel", "startedAt"])
        for forbidden in ["filePath", "cwd", "configuredRoot", "nativeId", "rawSourceSessionID", "resumeCommand", "token"] {
            XCTAssertNil(object[forbidden])
        }
        let missing = try XCTUnwrap(decode(EngramServiceWebSessionDetailResponse.self, ["observedAt": Self.now, "detail": NSNull()]))
        XCTAssertNil(missing.detail, "Only a producer-authorized not-found response may use nil detail")
    }

    func testAllMetadataMethodsSendExactHardcodedTypedRequestsWithoutCapability() async throws {
        for kind in MetadataKind.allCases {
            let path = metadataSocketPath()
            let token = URL(fileURLWithPath: path + ".cmd.token")
            let sentinel = Data("metadata-fixture-secret-never-read-or-send".utf8)
            try sentinel.write(to: token)
            let request = Self.input(kind)
            let server = try WebReadFixture(path: path) { fd, bytes in
                let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
                XCTAssertEqual(incoming.command, kind.rawValue)
                XCTAssertEqual(incoming.kind, "request")
                XCTAssertEqual(UUID(uuidString: incoming.requestId)?.uuidString, incoming.requestId)
                XCTAssertNil(incoming.capabilityToken)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual(Set(object.keys), ["request_id", "kind", "command", "payload"])
                let payload = try XCTUnwrap(incoming.payload)
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? NSDictionary)
                XCTAssertEqual(decoded, request as NSDictionary)
                try EngramServiceSocketIO.writeFrame(Self.metadataEnvelope(Self.page(kind), requestId: incoming.requestId),
                                                      to: fd, requestTimeout: 1)
            }
            defer { server.stop() }
            let bytes = try await Self.invoke(kind, client: EngramServiceWebReadClient(socketPath: path), input: request)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? NSDictionary)
            XCTAssertEqual(response, Self.page(kind) as NSDictionary)
            XCTAssertEqual(server.requestCount, 1)
            XCTAssertEqual(try Data(contentsOf: token), sentinel)
        }
    }

    func testMetadataRejectsEnvelopeIdentityKindAmbiguityAndMalformedPayloads() async throws {
        for kind in MetadataKind.allCases {
            for mutation in ["kind", "request_id", "both", "missing", "nullPayload", "arrayPayload"] {
                await expectMetadata(.malformed) {
                    try await self.metadataExchange(kind) { incoming in
                        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.metadataEnvelope(Self.page(kind), requestId: incoming.requestId)) as? [String: Any])
                        switch mutation {
                        case "kind": object["kind"] = "event"
                        case "request_id": object["request_id"] = incoming.requestId + "-different"
                        case "both": object["error"] = ["name": "StaleCursor"]
                        case "missing": object.removeValue(forKey: "result")
                        case "nullPayload": object["result"] = Data("null".utf8).base64EncodedString()
                        default: object["result"] = Data("[]".utf8).base64EncodedString()
                        }
                        return try JSONSerialization.data(withJSONObject: object)
                    }
                }
            }
        }
    }

    func testMetadataSafeErrorCategoriesDoNotTurnMissingProviderIntoEmptySuccess() async throws {
        let cases: [(String, EngramServiceWebReadClientError)] = [
            ("StaleCursor", .stale), ("staleCursor", .stale), ("UnsupportedCommand", .unsupported),
            ("unsupportedCommand", .unsupported), ("ServiceUnavailable", .unavailable),
            ("serviceUnavailable", .unavailable), ("/private/secret-name", .malformed),
        ]
        for kind in MetadataKind.allCases {
            for (name, expected) in cases {
                await expectMetadata(expected) {
                    try await self.metadataExchange(kind) { incoming in
                        try JSONEncoder().encode(EngramServiceResponseEnvelope.failure(requestId: incoming.requestId,
                            error: .init(name: name, message: "secret token /private/fixture", retryPolicy: "secret-retry",
                                         details: ["token": .string("fixture-secret")])) )
                    }
                }
            }
        }
    }

    func testMetadataContinuationRequiresSameSnapshotNewCursorAndRequestedLimit() async throws {
        for kind in [MetadataKind.overview, .sessions] {
            let request: [String: Any] = ["limit": 1, "snapshotId": Self.snapshot, "cursor": "before"]
            for mutation in ["snapshot", "repeat", "limit"] {
                await expectMetadata(.malformed) {
                    try await self.metadataExchange(kind, input: request) { incoming in
                        var page = Self.page(kind)
                        switch mutation {
                        case "snapshot": page["snapshotId"] = Self.otherSnapshot
                        case "repeat": page["nextCursor"] = "before"
                        default:
                            page[kind == .overview ? "streams" : "items"] = kind == .overview
                                ? [Self.stream(), Self.replacing(Self.stream(), "sourceInstanceId", Self.otherSnapshot)]
                                : [Self.summary(), Self.summary(id: "session-b")]
                        }
                        return try Self.metadataEnvelope(page, requestId: incoming.requestId)
                    }
                }
            }
            let bytes = try await metadataExchange(kind, input: request) { incoming in
                try Self.metadataEnvelope(Self.replacing(Self.page(kind), "nextCursor", "after"), requestId: incoming.requestId)
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(object["snapshotId"] as? String, Self.snapshot)
            XCTAssertEqual(object["nextCursor"] as? String, "after")
        }
    }

    func testSessionListRejectsMismatchedExactFiltersAndDetailUsesByteExactID() async throws {
        let request: [String: Any] = ["limit": 50, "source": "claude-code", "machineId": Self.machine,
                                     "sourceInstanceId": Self.instance, "projectKey": "project_1"]
        for mutation in ["source", "machine", "instance", "missingCapture", "project"] {
            await expectMetadata(.malformed) {
                try await self.metadataExchange(.sessions, input: request) { incoming in
                    var item = Self.summary()
                    switch mutation {
                    case "source": item["source"] = "codex"
                    case "machine": item["captureIdentity"] = Self.replacing(Self.captureIdentity(), "machineId", Self.otherSnapshot)
                    case "instance": item["captureIdentity"] = Self.replacing(Self.captureIdentity(), "sourceInstanceId", Self.otherSnapshot)
                    case "missingCapture": item["captureIdentity"] = NSNull()
                    default: item["projectKey"] = "different_project"
                    }
                    return try Self.metadataEnvelope(Self.replacing(Self.sessions(), "items", [item]), requestId: incoming.requestId)
                }
            }
        }
        for id in ["different", "caf\u{e9}"] {
            await expectMetadata(.malformed) {
                try await self.metadataExchange(.detail, input: ["sessionId": "cafe\u{301}"]) { incoming in
                    let detail = Self.replacing(Self.detail(), "session", Self.summary(id: id))
                    return try Self.metadataEnvelope(["observedAt": Self.now, "detail": detail], requestId: incoming.requestId)
                }
            }
        }
        let id = " cafe\u{301} "
        let bytes = try await metadataExchange(.detail, input: ["sessionId": id]) { incoming in
            try Self.metadataEnvelope(["observedAt": Self.now, "detail": Self.replacing(Self.detail(), "session", Self.summary(id: id))],
                                      requestId: incoming.requestId)
        }
        let result = try JSONDecoder().decode(EngramServiceWebSessionDetailResponse.self, from: bytes)
        XCTAssertEqual(Data(try XCTUnwrap(result.detail?.session.sessionId).utf8), Data(id.utf8))
    }

    func testMetadataClientRejectsOutOfOrderStableListAndOverviewPages() async throws {
        let unordered: [[[String: Any]]] = [
            [Self.summary(id: "b"), Self.summary(id: "a")],
            [Self.summary(id: "a", startedAt: Self.now - 1), Self.summary(id: "b")],
            [Self.summary(id: "a", startedAt: nil), Self.summary(id: "b")],
        ]
        for items in unordered {
            await expectMetadata(.malformed) {
                try await self.metadataExchange(.sessions) { incoming in
                    try Self.metadataEnvelope(Self.replacing(Self.sessions(), "items", items), requestId: incoming.requestId)
                }
            }
        }
        let streams = [Self.replacing(Self.stream(), "machineId", Self.otherSnapshot), Self.stream()]
        await expectMetadata(.malformed) {
            try await self.metadataExchange(.overview) { incoming in
                try Self.metadataEnvelope(Self.replacing(Self.overview(), "streams", streams), requestId: incoming.requestId)
            }
        }
        let ordered = [Self.summary(id: "cafe\u{301}"), Self.summary(id: "caf\u{e9}"), Self.summary(id: "z", startedAt: nil)]
        let bytes = try await metadataExchange(.sessions) { incoming in
            try Self.metadataEnvelope(Self.replacing(Self.sessions(), "items", ordered), requestId: incoming.requestId)
        }
        XCTAssertEqual(try JSONDecoder().decode(EngramServiceWebSessionsResponse.self, from: bytes).items.count, 3)
    }

    func testMetadataFinalEncodedEnvelopeHasItsOwn255KiBBudget() async throws {
        // Extra envelope metadata is legal JSON, but counts toward the entire
        // metadata response frame. Legacy webMessages retains its 256 KiB rule.
        for kind in MetadataKind.allCases {
            for exceedsBudget in [false, true] {
                let operation = {
                    try await self.metadataExchange(kind) { incoming in
                        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.metadataEnvelope(Self.page(kind), requestId: incoming.requestId)) as? [String: Any])
                        object["padding"] = ""
                        let base = try JSONSerialization.data(withJSONObject: object).count
                        let target = EngramServiceWebReadLimits.maximumPageEnvelopeBytes + (exceedsBudget ? 1 : 0)
                        object["padding"] = String(repeating: "x", count: target - base)
                        let bytes = try JSONSerialization.data(withJSONObject: object)
                        XCTAssertEqual(bytes.count, target)
                        XCTAssertLessThanOrEqual(bytes.count, EngramServiceSocketIO.maximumFrameLength)
                        return bytes
                    }
                }
                if exceedsBudget { await expectMetadata(.malformed, operation) }
                else { _ = try await operation() }
            }
        }
    }

    func testMetadataKernelFailuresAndSocketPathSafetyNeverRepairFiles() async throws {
        for kind in MetadataKind.allCases {
            let path = metadataSocketPath()
            let sentinel = Data("keep fixture file".utf8)
            try sentinel.write(to: URL(fileURLWithPath: path))
            await expectMetadata(.unavailable) {
                try await Self.invoke(kind, client: EngramServiceWebReadClient(socketPath: path), input: Self.input(kind))
            }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), sentinel)
        }
    }

    func testMetadataTotalDeadlineIsNotRenewedByTricklingBytes() async throws {
        for kind in MetadataKind.allCases {
            let path = metadataSocketPath()
            let server = try WebReadFixture(path: path) { fd, _ in
                var prefix = UInt32(100).bigEndian
                let bytes = withUnsafeBytes(of: &prefix) { Array($0) } + Array(repeating: UInt8(65), count: 100)
                for byte in bytes {
                    try WebReadFixture.writeBytes(Data([byte]), to: fd)
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            defer { server.stop() }
            let start = ContinuousClock.now
            await expectMetadata(.unavailable) {
                try await Self.invoke(kind, client: EngramServiceWebReadClient(socketPath: path, totalTimeout: 0.15), input: Self.input(kind))
            }
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }

    func testEveryMetadataCallPreservesInFlightCancellationAndClosesPeer() async throws {
        for kind in MetadataKind.allCases {
            let path = metadataSocketPath()
            let arrived = expectation(description: "\(kind) request arrived or call ended")
            // The first observable event wakes this test. A fail-closed scaffold
            // must report its immediate error instead of manufacturing a timeout.
            arrived.assertForOverFulfill = false
            let closed = expectation(description: "\(kind) peer closed")
            let server = try WebReadFixture(path: path) { fd, _ in
                arrived.fulfill()
                var byte: UInt8 = 0
                while true {
                    let count = recv(fd, &byte, 1, 0)
                    if count < 0 && errno == EINTR { continue }
                    if count == 0 { closed.fulfill() }
                    break
                }
            }
            defer { server.stop() }
            let task = Task {
                defer { arrived.fulfill() }
                return try await Self.invoke(kind, client: EngramServiceWebReadClient(socketPath: path), input: Self.input(kind))
            }
            await fulfillment(of: [arrived], timeout: 1)
            guard server.requestCount == 1 else {
                do { _ = try await task.value; XCTFail("Metadata call returned without the required IPC") }
                catch { XCTFail("Metadata call failed before the cancellation fixture received its request") }
                continue
            }
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError {}
            catch { XCTFail("Expected CancellationError, not an ordinary metadata error") }
            await fulfillment(of: [closed], timeout: 1)
        }
    }

    func testEveryAlreadyCancelledMetadataCallPerformsNoIPC() async throws {
        for kind in MetadataKind.allCases {
            let path = metadataSocketPath()
            let server = try WebReadFixture(path: path) { _, _ in XCTFail("Cancelled metadata call performed IPC") }
            defer { server.stop() }
            let parked = expectation(description: "park metadata call")
            let gate = WebReadGate(entered: parked)
            let task = Task {
                await gate.wait()
                return try await Self.invoke(kind, client: EngramServiceWebReadClient(socketPath: path), input: Self.input(kind))
            }
            await fulfillment(of: [parked], timeout: 1)
            task.cancel()
            await gate.release()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError {}
            catch { XCTFail("Expected CancellationError before dispatch") }
            XCTAssertEqual(server.requestCount, 0)
        }
    }

    private enum MetadataKind: String, CaseIterable, Sendable {
        case overview = "webOverview", sessions = "webSessions", detail = "webSessionDetail"
    }

    private static func input(_ kind: MetadataKind) -> [String: Any] {
        kind == .detail ? ["sessionId": "session-a"] : ["limit": 50]
    }

    private static func page(_ kind: MetadataKind) -> [String: Any] {
        switch kind {
        case .overview: overview()
        case .sessions: sessions()
        case .detail: detailResponse()
        }
    }

    private static func invoke(_ kind: MetadataKind, client: EngramServiceWebReadClient,
                               input: [String: Any]) async throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: input)
        switch kind {
        case .overview: return try JSONEncoder().encode(await client.overview(JSONDecoder().decode(EngramServiceWebOverviewRequest.self, from: bytes)))
        case .sessions: return try JSONEncoder().encode(await client.sessions(JSONDecoder().decode(EngramServiceWebSessionsRequest.self, from: bytes)))
        case .detail: return try JSONEncoder().encode(await client.sessionDetail(JSONDecoder().decode(EngramServiceWebSessionDetailRequest.self, from: bytes)))
        }
    }

    private func metadataSocketPath() -> String { directory.appendingPathComponent("\(UUID().uuidString.prefix(8)).sock").path }

    private func metadataExchange(_ kind: MetadataKind, input: [String: Any]? = nil,
                                  response: @escaping @Sendable (EngramServiceRequestEnvelope) throws -> Data) async throws -> Data {
        let path = metadataSocketPath()
        let server = try WebReadFixture(path: path) { fd, bytes in
            let incoming = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
            try EngramServiceSocketIO.writeFrame(response(incoming), to: fd, requestTimeout: 1)
        }
        defer {
            XCTAssertEqual(server.requestCount, 1, "Every protocol result, including unsupported, must originate from actual IPC")
            server.stop()
        }
        return try await Self.invoke(kind, client: EngramServiceWebReadClient(socketPath: path, totalTimeout: 0.5), input: input ?? Self.input(kind))
    }

    private static func metadataEnvelope(_ object: [String: Any], requestId: String) throws -> Data {
        try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: requestId,
            result: JSONSerialization.data(withJSONObject: object)))
    }

    private func expectMetadata(_ expected: EngramServiceWebReadClientError,
                                _ operation: () async throws -> Data,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let safe as EngramServiceWebReadClientError {
            XCTAssertEqual(safe, expected, file: file, line: line)
            for forbidden in ["secret", "/private/fixture", directory.path] {
                XCTAssertFalse(safe.localizedDescription.contains(forbidden), file: file, line: line)
                XCTAssertFalse(String(describing: safe).contains(forbidden), file: file, line: line)
            }
        } catch { XCTFail("Unexpected metadata error category", file: file, line: line) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any],
                                      file: StaticString = #filePath, line: UInt = #line) -> T? {
        do { return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object)) }
        catch { XCTFail("Valid \(type) fixture was rejected: \(Swift.type(of: error))", file: file, line: line); return nil }
    }

    private func invalid<T: Decodable>(_ type: T.Type, _ object: [String: Any],
                                       file: StaticString = #filePath, line: UInt = #line) {
        do {
            let bytes = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(type, from: bytes), "Invalid \(type) accepted", file: file, line: line)
        } catch { XCTFail("The malformed-field fixture itself must remain legal JSON", file: file, line: line) }
    }

    private func checkTime(_ value: Any, valid: Bool, file: StaticString = #filePath, line: UInt = #line) {
        func check<T: Decodable>(_ type: T.Type, _ object: [String: Any]) {
            if valid { _ = decode(type, object, file: file, line: line) }
            else { invalid(type, object, file: file, line: line) }
        }
        check(EngramServiceWebOverviewResponse.self, Self.replacing(Self.overview(), "observedAt", value))
        check(EngramServiceWebSessionsResponse.self, Self.replacing(Self.sessions(), "observedAt", value))
        check(EngramServiceWebSessionDetailResponse.self, ["observedAt": value, "detail": NSNull()])
        check(EngramServiceWebStreamOverview.self, Self.replacing(Self.stream(), "heartbeatAt", value))
        check(EngramServiceWebIngestObservation.self, Self.replacing(Self.ingest(), "oldestPendingAt", value))
        check(EngramServiceWebCaptureObservation.self, ["manifestSHA256": Self.generation, "observedAt": value])
        check(EngramServiceWebReplicaACKObservation.self, Self.replacing(Self.ack(), "observedAt", value))
        check(EngramServiceWebFTSObservation.self, ["observedAt": value, "readyLogicalSessions": 0])
        check(EngramServiceWebAIObservation.self, ["observedAt": value, "state": "idle"])
        check(EngramServiceWebSessionSummary.self, Self.replacing(Self.summary(), "startedAt", value))
        check(EngramServiceWebGenerationSummary.self, Self.replacing(Self.generationSummary(), "committedAt", value))
        check(EngramServiceWebSessionAttempt.self, Self.replacing(Self.attempt(), "recordedAt", value))
    }

    private static var invalidUUIDs: [String] {
        ["", snapshot.lowercased(), "{\(snapshot)}", String(snapshot.dropLast()), snapshot + "0", " " + snapshot, "not-a-uuid"]
    }
    private static var invalidHashes: [String] {
        ["", generation.uppercased(), String(repeating: "a", count: 63), String(repeating: "a", count: 65), "g" + String(repeating: "a", count: 63)]
    }
    private static var safeFailureCodes: [String] {
        ["fileMissing", "fileTooLarge", "invalidUtf8", "truncatedJSON", "truncatedJSONL", "malformedJSON",
         "malformedToolCall", "deeplyNestedRecord", "messageLimitExceeded", "lineTooLarge", "fileModifiedDuringParse",
         "sqliteUnreadable", "grpcUnavailable", "unsupportedVirtualLocator", "noVisibleMessages"].map { "parse." + $0 }
        + ["invalid_manifest", "unsupported_capture_shape", "source_integrity_mismatch", "binding_mismatch",
           "invalid_native_identity", "sequence_conflict"].map { "quarantine." + $0 }
        + ["cas_unavailable", "staging_unavailable", "interrupted"].map { "retry." + $0 }
        + ["sequence_conflict"]
    }
    private static func replacing(_ object: [String: Any], _ field: String, _ value: Any) -> [String: Any] {
        var copy = object
        copy[field] = value
        return copy
    }
    private static func capabilities() -> [String: Any] {
        ["keywordSearch": "unknown", "transcriptRead": "unavailable"]
    }
    private static func binding() -> [String: Any] {
        ["source": "claude-code", "approvedEpoch": epoch, "authorityGeneration": "1"]
    }
    private static func captureIdentity() -> [String: Any] {
        ["machineId": machine, "sourceInstanceId": instance]
    }
    private static func taskCounts() -> [String: Any] {
        ["pending": 0, "processing": 0, "parsed": 0, "indexReady": 0, "retryableFailure": 0, "quarantined": 0]
    }
    private static func ingest() -> [String: Any] {
        ["publicationCount": 0, "taskCounts": taskCounts(), "parseFailureTasks": 0]
    }
    private static func ack() -> [String: Any] {
        ["serverId": "hq", "publicationSHA256": generation, "observedAt": now]
    }
    private static func stream() -> [String: Any] {
        ["machineId": machine, "sourceInstanceId": instance, "registry": binding(), "ingest": ingest()]
    }
    private static func overview() -> [String: Any] {
        ["snapshotId": snapshot, "observedAt": now, "capabilities": capabilities(), "streams": [stream()]]
    }
    private static func summary(id: String = "session-a", startedAt: Int64? = now) -> [String: Any] {
        var object: [String: Any] = [
            "sessionId": id, "source": "claude-code", "captureIdentity": captureIdentity(),
            "metadataGeneration": generation, "title": "A redacted title", "projectKey": "project_1", "projectLabel": "Example",
        ]
        if let startedAt { object["startedAt"] = startedAt }
        return object
    }
    private static func sessions() -> [String: Any] {
        ["snapshotId": snapshot, "observedAt": now, "items": [summary()]]
    }
    private static func generationSummary() -> [String: Any] {
        ["generationId": generation, "publicationSHA256": generation, "parserRevision": "parser-v1",
         "collectorEpoch": epoch, "authorityGeneration": "1", "sequence": "1",
         "committedAt": now, "normalizedMessageCount": 3]
    }
    private static func attempt() -> [String: Any] {
        ["publicationSHA256": generation, "parserRevision": "parser-v1", "collectorEpoch": epoch,
         "sequence": "1", "status": "pending", "recordedAt": now]
    }
    private static func detail() -> [String: Any] {
        ["session": summary(), "lastParsed": generationSummary(), "lastReady": generationSummary(),
         "transcriptAvailability": "available", "transcriptGeneration": generation]
    }
    private static func detailResponse() -> [String: Any] {
        ["observedAt": now, "detail": detail()]
    }
}
