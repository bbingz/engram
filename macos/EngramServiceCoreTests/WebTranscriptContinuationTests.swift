import CryptoKit
import EngramCoreRead
import Foundation
import XCTest
@testable import EngramServiceCore

final class WebTranscriptContinuationTests: XCTestCase {
    private let generation = String(repeating: "a", count: 64)
    private let sessionID = "central/session"

    func testNecessaryPrefixFilterPreservesEverySecretFamilyAndUnicodeCaseFolding() throws {
        let secrets = [
            "-----BEGIN PRIVATE KEY-----\nbody\n-----END PRIVATE KEY-----",
            "password=Abcd!1234", "PASSWORD: 'Abcd!1234'", "paſſword=abcdefghijk",
            "sudo 密码是Abcd!1234", "口令：Abcd!1234", "api_key=abcdefghijk",
            "api-Key=abcdefghijk", "ſecret=abcdefghijk", "credential=abcdefghijk",
            "token=abcdefghijk", "Bearer=abcdefghijk", "Authorization: Bearer abcdefghijk",
            "sk-abcdefghijk", "ghp_abcdefghijk", "xoxb-abcdefghijk",
            "github_pat_abcdefghijklmnopqrstuv", "gho_abcdefghijklmnopqrstuv",
            "ghu_abcdefghijklmnopqrstuv", "ghs_abcdefghijklmnopqrstuv", "ghr_abcdefghijklmnopqrstuv",
            "AKIA1234567890ABCDEF", "ASIA1234567890ABCDEF", "npm_abcdefghijk", "xoxe-abcdefghijk",
        ]
        for secret in secrets {
            let text = "before " + secret + " after"
            XCTAssertEqual(TranscriptRedactionPolicy.redact(text), "before [REDACTED] after")
            let ranges = TranscriptRedactionPolicy.sensitiveUTF8Ranges(in: text)
            XCTAssertEqual(ranges, [7..<(7 + secret.utf8.count)])
        }
        XCTAssertEqual(TranscriptRedactionPolicy.redact("How do I change my password?"), "How do I change my password?")
    }

    func testNineMiBPlainMessageProjectionLeavesTimeForAuthorityAndIPC_repro() throws {
        let message = NormalizedMessage(role: .assistant,
            content: "The constellation snapshot is ready. " + String(repeating: "x", count: 9 * 1024 * 1024))
        let start = ContinuousClock.now
        let page = try ServiceTranscriptContinuation.page(snapshot: snapshot([message]),
            request: EngramServiceWebMessagesRequest(sessionId: sessionID, generation: generation), requestId: "large-message")
        let elapsed = start.duration(to: .now)
        print("NINE_MIB_FIRST_PAGE elapsed=\(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertFalse(page.isComplete)
        XCTAssertNotNil(page.nextCursor)
        XCTAssertEqual(page.fragments.first?.messageOrdinal, 0)
        XCTAssertEqual(page.fragments.first?.utf8Offset, 0)
    }

    func testCompleteProjectionPreservesEveryNormalizedFieldAndRole() throws {
        let messages = [
            NormalizedMessage(role: .system, content: ""),
            NormalizedMessage(role: .user, content: "<system-reminder>literal user text</system-reminder>"),
            NormalizedMessage(role: .assistant, content: "answer", timestamp: "2026-09-05T00:00:00Z",
                              toolCalls: [.init(name: "tool", input: "input", output: "output")],
                              usage: .init(inputTokens: 12, outputTokens: 34, cacheReadTokens: 5, cacheCreationTokens: 6)),
            NormalizedMessage(role: .tool, content: "result"),
        ]
        let pages = try collect(snapshot(messages), maxFragments: 1)
        XCTAssertEqual(pages.flatMap(\.fragments).map(\.messageOrdinal), [0, 1, 2, 3])
        XCTAssertEqual(pages.flatMap(\.fragments).map(\.role), [.system, .user, .assistant, .tool])
        XCTAssertTrue(try XCTUnwrap(pages.last).isComplete)
        try assertReconstruction(pages, messages: messages)
    }

    func testLargeEscapeHeavyUnicodeAndToolPayloadReconstructWithoutLoss() throws {
        let text = String(repeating: "界👩🏽‍💻e\u{301}\"\\\n\t", count: 11_000)
        let message = NormalizedMessage(
            role: .assistant, content: text, timestamp: "timestamp",
            toolCalls: [.init(name: "large-tool", input: text, output: String(text.reversed()))],
            usage: .init(inputTokens: 0, outputTokens: 100)
        )
        XCTAssertGreaterThan(text.utf8.count, 160 * 1024)
        let pages = try collect(snapshot([message]))
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertTrue(pages.dropLast().allSatisfy { !$0.isComplete && $0.nextCursor != nil })
        try assertReconstruction(pages, messages: [message])
        for page in pages {
            XCTAssertEqual(page.projection, "redacted-normalized-message-json-v1")
            XCTAssertEqual(page.redactionRevision, "transcript-redaction-v2")
        }
    }

    func testRedactsAllStringFieldsBeforeFragmentingIncludingCrossBoundarySecret() throws {
        let privateKey = "-----BEGIN PRIVATE KEY-----\n" + String(repeating: "PRIVATEBODY", count: 4_000)
            + "\n-----END PRIVATE KEY-----"
        let message = NormalizedMessage(
            role: .tool,
            content: String(repeating: "prefix ", count: 300) + privateKey + String(repeating: " suffix", count: 300),
            timestamp: "sk-timestampsecret12345",
            toolCalls: [.init(name: "ghp_toolnamesecret12345", input: "token=toolinputsecret12345",
                              output: "authorization=tooloutputsecret12345")]
        )
        let pages = try collect(snapshot([message]), budget: 2400)
        XCTAssertGreaterThan(pages.count, 1)
        let wire = pages.flatMap(\.fragments).map(\.payloadFragment).joined()
        for forbidden in ["PRIVATEBODY", "BEGIN PRIVATE", "timestampsecret", "toolnamesecret", "toolinputsecret", "tooloutputsecret"] {
            XCTAssertFalse(wire.contains(forbidden), forbidden)
        }
        XCTAssertTrue(wire.contains("[REDACTED]"))
        try assertReconstruction(pages, messages: [message])
    }

    func testNaturalLanguageAndPunctuationPasswordsAreRedactedBeforePaging() throws {
        let text = "说明 sudo 密码是Example#4821，请继续。 password=Example!4821"
        XCTAssertEqual(TranscriptRedactionPolicy.redact(text), "说明 [REDACTED]，请继续。 [REDACTED]")
        let bytes = Array(text.utf8)
        let ranges = TranscriptRedactionPolicy.sensitiveUTF8Ranges(in: text)
        XCTAssertEqual(ranges.map { String(decoding: bytes[$0], as: UTF8.self) },
            ["sudo 密码是Example#4821", "password=Example!4821"])
        XCTAssertEqual(TranscriptRedactionPolicy.redact("无需提供密码；sudo does not require a password."),
            "无需提供密码；sudo does not require a password.")
        let messages = [NormalizedMessage(role: .user, content: String(repeating: "prefix ", count: 300) + text)]
        let pages = try collect(snapshot(messages), budget: 2400)
        let wire = pages.flatMap(\.fragments).map(\.payloadFragment).joined()
        XCTAssertFalse(wire.contains("Example"))
        XCTAssertTrue(wire.contains("[REDACTED]"))
        try assertReconstruction(pages, messages: messages)
    }

    func testRoleFilterKeepsOriginalOrdinalsAndCanonicalOrderAcrossPages() throws {
        let messages = [NormalizedMessage(role: .system, content: "hidden"),
                        NormalizedMessage(role: .tool, content: "one"),
                        NormalizedMessage(role: .user, content: "hidden"),
                        NormalizedMessage(role: .assistant, content: "two")]
        let request = try request(roles: [.tool, .assistant], maxFragments: 1)
        let first = try page(snapshot(messages), request)
        XCTAssertEqual(first.fragments.map(\.messageOrdinal), [1])
        let cursor = try XCTUnwrap(first.nextCursor)
        let next = try page(snapshot(messages), self.request(roles: [.assistant, .tool], cursor: cursor, maxFragments: 1))
        XCTAssertEqual(next.fragments.map(\.messageOrdinal), [3])
        XCTAssertTrue(next.isComplete)
        XCTAssertNil(next.nextCursor)
    }

    func testCursorBindsSessionGenerationProjectionRedactionAndRoles() throws {
        let source = snapshot([.init(role: .assistant, content: String(repeating: "x", count: 4000))])
        let first = try page(source, request(), budget: 2400)
        let cursor = try XCTUnwrap(first.nextCursor)
        let alternate = String(repeating: "b", count: 64)
        assertError(.staleCursor) { try self.page(source, self.request(generation: alternate, cursor: cursor)) }
        assertError(.staleCursor) { try self.page(source, self.request(sessionId: "other", cursor: cursor)) }
        assertError(.staleCursor) { try self.page(source, self.request(roles: [.assistant], cursor: cursor)) }
        for (key, value) in ["sessionSHA256": alternate, "generation": alternate,
                             "projection": "other-projection", "redactionRevision": "other-redaction"] {
            let changed = try mutate(cursor) { $0[key] = value }
            assertError(.staleCursor) { try self.page(source, self.request(cursor: changed)) }
        }
        assertError(.staleCursor) { try self.page(nil, self.request(cursor: cursor)) }
    }

    func testCursorRejectsInvalidUTF8OffsetsOrdinalsAndMalformedEncoding() throws {
        let message = NormalizedMessage(role: .assistant, content: String(repeating: "界👩", count: 1500))
        let source = snapshot([message])
        let first = try page(source, request(), budget: 2400)
        let cursor = try XCTUnwrap(first.nextCursor)
        let bytes = [UInt8](try canonicalExpected(message))
        let insideScalar = try XCTUnwrap(bytes.indices.first { bytes[$0] & 0xC0 == 0x80 })
        for offset in [-1, insideScalar, bytes.count, Int.max] {
            let changed = try mutate(cursor) { $0["utf8Offset"] = offset }
            assertError(.invalidCursor) { try self.page(source, self.request(cursor: changed)) }
        }
        for ordinal in [-1, 1, Int.max] {
            let changed = try mutate(cursor) { $0["messageOrdinal"] = ordinal }
            assertError(.invalidCursor) { try self.page(source, self.request(cursor: changed)) }
        }
        for bad in ["!bad", "e30", cursor + "=", String(repeating: "A", count: 1000)] {
            assertError(.invalidCursor) { try self.page(source, self.request(cursor: bad)) }
        }
    }

    func testNoSourceAndMismatchedSnapshotFailClosedEvenWithoutCursor() throws {
        assertError(.staleCursor) { try self.page(nil, self.request()) }
        var other = snapshot([])
        other = .init(sessionId: sessionID, generation: String(repeating: "b", count: 64), messages: [])
        assertError(.staleCursor) { try self.page(other, self.request()) }
        // Swift String equality normalizes these IDs; cursor identity must not.
        let composed = ServiceTranscriptContinuation.Snapshot(sessionId: "caf\u{e9}", generation: generation, messages: [])
        assertError(.staleCursor) { try self.page(composed, self.request(sessionId: "cafe\u{301}")) }
    }

    func testPartialAndFailedSourcesNeverBecomeCompleteAtEOF() throws {
        var source = snapshot([.init(role: .user, content: "available")])
        source.totalKnownComplete = false
        source.truncatedAt = 123
        source.parseFailure = .messageLimitExceeded
        let final = try XCTUnwrap(collect(source).last)
        XCTAssertFalse(final.isComplete)
        XCTAssertFalse(final.totalKnownComplete)
        XCTAssertEqual(final.truncatedAt, 123)
        XCTAssertEqual(final.parseFailure, "messageLimitExceeded")
        XCTAssertNil(final.nextCursor)
        source.totalKnownComplete = true
        let contradictory = try page(source, request())
        XCTAssertFalse(contradictory.totalKnownComplete)
        XCTAssertFalse(contradictory.isComplete)
        let empty = try page(snapshot([]), request())
        XCTAssertTrue(empty.isComplete)
        XCTAssertTrue(empty.fragments.isEmpty)
    }

    func testTinyEnvelopeBudgetFailsInsteadOfReturningTruncatedOrOversizedSuccess() throws {
        assertError(.responseTooLarge) {
            try self.page(self.snapshot([.init(role: .user, content: "hello")]), self.request(), budget: 64)
        }
    }

    func testLongHistoryCanContinuePastTenThousandWithOriginalOrdinals() throws {
        var messages = Array(repeating: NormalizedMessage(role: .tool, content: "unselected"), count: 10_001)
        messages[0] = .init(role: .user, content: "first visible")
        messages[10_000] = .init(role: .user, content: "last visible")
        let first = try page(snapshot(messages), request(roles: [.user], maxFragments: 1))
        XCTAssertEqual(first.fragments.map(\.messageOrdinal), [0])
        let second = try page(snapshot(messages), request(roles: [.user], cursor: XCTUnwrap(first.nextCursor), maxFragments: 1))
        XCTAssertEqual(second.fragments.map(\.messageOrdinal), [10_000])
        XCTAssertTrue(second.isComplete)
        XCTAssertNil(second.nextCursor)
    }

    func testSparsePageWindowKeepsGlobalCursorAndDoesNotConsumeLookahead() throws {
        let firstMessage = NormalizedMessage(role: .user, content: "first")
        let lastMessage = NormalizedMessage(role: .user, content: "last")
        var window = snapshot([firstMessage, lastMessage])
        window.messageOrdinals = [0, 10_000]
        window.totalMessageCount = 10_001
        window.maximumPageFragments = 1
        let first = try page(window, request(roles: [.user]))
        XCTAssertEqual(first.fragments.map(\.messageOrdinal), [0])
        XCTAssertFalse(first.isComplete)
        let continuation = try request(roles: [.user], cursor: XCTUnwrap(first.nextCursor))
        XCTAssertEqual(try ServiceTranscriptContinuation.startingOrdinal(for: continuation), 10_000)
        var tail = snapshot([lastMessage])
        tail.messageOrdinals = [10_000]
        tail.totalMessageCount = 10_001
        let last = try page(tail, continuation)
        XCTAssertEqual(last.fragments.map(\.messageOrdinal), [10_000])
        XCTAssertTrue(last.isComplete)
    }

    func testSparseLargeMessageFragmentsRetainGlobalOrdinalAndPayloadDigest() throws {
        let messages = [NormalizedMessage(role: .assistant, content: String(repeating: "界🌍", count: 2000)),
                        NormalizedMessage(role: .user, content: "last")]
        var source = snapshot(messages)
        source.messageOrdinals = [400, 99_999]
        source.totalMessageCount = 100_000
        source.maximumPageFragments = 1
        let pages = try collect(source, budget: 2400)
        let fragments = Dictionary(grouping: pages.flatMap(\.fragments), by: \.messageOrdinal)
        XCTAssertEqual(Set(fragments.keys), [400, 99_999])
        for (index, ordinal) in [400, 99_999].enumerated() {
            let pieces = try XCTUnwrap(fragments[ordinal])
            let actual = Data(pieces.map(\.payloadFragment).joined().utf8)
            let expected = try canonicalExpected(messages[index])
            XCTAssertTrue(actual == expected)
            XCTAssertEqual(Set(pieces.map(\.payloadSHA256)).count, 1)
        }
        XCTAssertTrue(try XCTUnwrap(pages.last).isComplete)
    }

    func testSparsePageRejectsInvalidOrdinalMappings() throws {
        for ordinals in [[3, 3], [4, 3], [1], [-1, 3], [3, 5]] {
            var source = snapshot([.init(role: .user, content: "one"), .init(role: .user, content: "two")])
            source.messageOrdinals = ordinals
            source.totalMessageCount = 5
            assertError(.invalidField("messages")) { try self.page(source, self.request()) }
        }
    }

    private func snapshot(_ messages: [NormalizedMessage]) -> ServiceTranscriptContinuation.Snapshot {
        .init(sessionId: sessionID, generation: generation, messages: messages)
    }

    private func request(sessionId: String? = nil, generation: String? = nil,
                         roles: [EngramServiceWebMessageRole] = EngramServiceWebMessageRole.allCases,
                         cursor: String? = nil, maxFragments: Int = 50) throws -> EngramServiceWebMessagesRequest {
        try .init(sessionId: sessionId ?? sessionID, generation: generation ?? self.generation,
                  roles: roles, cursor: cursor, maxFragments: maxFragments)
    }

    private func page(_ source: ServiceTranscriptContinuation.Snapshot?, _ request: EngramServiceWebMessagesRequest,
                      budget: Int = EngramServiceWebReadLimits.maximumPageEnvelopeBytes) throws -> EngramServiceWebMessagesResponse {
        try ServiceTranscriptContinuation.page(snapshot: source, request: request, requestId: "test-request", maximumEnvelopeBytes: budget)
    }

    private func collect(_ source: ServiceTranscriptContinuation.Snapshot, maxFragments: Int = 50,
                         budget: Int = EngramServiceWebReadLimits.maximumPageEnvelopeBytes) throws -> [EngramServiceWebMessagesResponse] {
        var cursor: String?
        var seen = Set<String>()
        var pages: [EngramServiceWebMessagesResponse] = []
        for _ in 0..<1000 {
            let result = try page(source, request(cursor: cursor, maxFragments: maxFragments), budget: budget)
            let inner = try JSONEncoder().encode(result)
            let envelope = try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: "test-request", result: inner))
            XCTAssertLessThanOrEqual(envelope.count, budget)
            XCTAssertLessThan(envelope.count, 256 * 1024)
            pages.append(result)
            guard let next = result.nextCursor else { return pages }
            XCTAssertFalse(result.fragments.isEmpty)
            guard seen.insert(next).inserted else { XCTFail("Non-progressing cursor"); return pages }
            cursor = next
        }
        XCTFail("Too many continuation pages")
        return pages
    }

    private func assertReconstruction(_ pages: [EngramServiceWebMessagesResponse], messages: [NormalizedMessage]) throws {
        let fragments = Dictionary(grouping: pages.flatMap(\.fragments), by: \.messageOrdinal)
        XCTAssertEqual(fragments.count, messages.count)
        for (ordinal, message) in messages.enumerated() {
            let pieces = try XCTUnwrap(fragments[ordinal])
            let expected = try canonicalExpected(message)
            let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
            var assembled = Data()
            for (index, piece) in pieces.enumerated() {
                XCTAssertEqual(piece.utf8Offset, assembled.count)
                XCTAssertEqual(piece.payloadSHA256, digest)
                XCTAssertEqual(piece.isLastFragment, index == pieces.count - 1)
                XCTAssertFalse(piece.payloadFragment.isEmpty)
                assembled.append(contentsOf: piece.payloadFragment.utf8)
            }
            XCTAssertEqual(assembled, expected)
            XCTAssertNoThrow(try JSONDecoder().decode(EngramServiceWebNormalizedMessage.self, from: assembled))
        }
    }

    private func canonicalExpected(_ message: NormalizedMessage) throws -> Data {
        var expected = message
        expected.content = TranscriptRedactionPolicy.redact(message.content)
        expected.timestamp = message.timestamp.map(TranscriptRedactionPolicy.redact)
        expected.toolCalls = message.toolCalls?.map {
            .init(name: TranscriptRedactionPolicy.redact($0.name), input: $0.input.map(TranscriptRedactionPolicy.redact),
                  output: $0.output.map(TranscriptRedactionPolicy.redact))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(expected)
    }

    private func mutate(_ cursor: String, _ change: (inout [String: Any]) -> Void) throws -> String {
        var base64 = cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func assertError(_ expected: EngramServiceWebReadError, _ action: () throws -> Any,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(error as? EngramServiceWebReadError, expected, file: file, line: line)
        }
    }
}
