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
        XCTAssertEqual(EngramServiceWebReadClient.allowedCommands, ["webMessages"])
        XCTAssertNoThrow(try EngramServiceWebReadClient.validateCommand("webMessages"))
        let server = try WebReadFixture(path: socketPath()) { _, _ in XCTFail("Policy checks must not perform IPC") }
        defer { server.stop() }
        for command in commands.subtracting(["webMessages"]).union(["", "webMessages\0shutdown", "WEBMESSAGES", "futureWrite"]) {
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
