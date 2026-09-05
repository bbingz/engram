import EngramCoreRead
import Foundation
import XCTest
@testable import EngramServiceCore

final class WebTranscriptWireTests: XCTestCase {
    private let generation = String(repeating: "a", count: 64)

    func testRequestValidatesBoundedFieldsOnInitAndDecode() throws {
        let valid = try EngramServiceWebMessagesRequest(sessionId: "session", generation: generation, roles: [.tool, .user])
        XCTAssertEqual(valid.roles, [.tool, .user])
        XCTAssertEqual(try JSONDecoder().decode(EngramServiceWebMessagesRequest.self, from: JSONEncoder().encode(valid)), valid)
        for id in ["", "nul\0id", String(repeating: "界", count: 1400)] {
            XCTAssertThrowsError(try EngramServiceWebMessagesRequest(sessionId: id, generation: generation))
        }
        for invalidGeneration in ["", "databaseGeneration:7", String(repeating: "A", count: 64)] {
            XCTAssertThrowsError(try EngramServiceWebMessagesRequest(sessionId: "s", generation: invalidGeneration))
        }
        for roles: [EngramServiceWebMessageRole] in [[], [.user, .user]] {
            XCTAssertThrowsError(try EngramServiceWebMessagesRequest(sessionId: "s", generation: generation, roles: roles))
        }
        for limit in [0, -1, 101, Int.max] {
            XCTAssertThrowsError(try EngramServiceWebMessagesRequest(sessionId: "s", generation: generation, maxFragments: limit))
        }
        XCTAssertThrowsError(try EngramServiceWebMessagesRequest(sessionId: "s", generation: generation, cursor: String(repeating: "a", count: 1025)))
        let encoded = try JSONEncoder().encode(valid)
        for (key, value): (String, Any) in [("maxFragments", 0), ("generation", "invalid"), ("roles", ["futureRole"]), ("sessionId", "")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(EngramServiceWebMessagesRequest.self,
                                                         from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testFragmentRejectsInvalidIdentityBoundsAndEmptyProgress() throws {
        for ordinal in [-1, 10_000, Int.max] {
            XCTAssertThrowsError(try fragment(ordinal: ordinal))
        }
        XCTAssertThrowsError(try fragment(offset: -1))
        XCTAssertThrowsError(try fragment(sha: "invalid"))
        XCTAssertThrowsError(try fragment(payload: ""))
        let valid = try fragment()
        XCTAssertEqual(try JSONDecoder().decode(EngramServiceWebMessageFragment.self, from: JSONEncoder().encode(valid)), valid)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["utf8Offset"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(EngramServiceWebMessageFragment.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testResponseRequiresTruthfulCompletenessAndKnownProjection() throws {
        let complete = try response()
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(try JSONDecoder().decode(EngramServiceWebMessagesResponse.self, from: JSONEncoder().encode(complete)), complete)
        XCTAssertThrowsError(try response(projection: "future"))
        XCTAssertThrowsError(try response(redaction: "future"))
        XCTAssertThrowsError(try response(complete: true, truncatedAt: 4))
        XCTAssertThrowsError(try response(complete: true, parseFailure: "malformedJSON"))
        XCTAssertThrowsError(try response(complete: false, truncatedAt: -1))
        XCTAssertThrowsError(try response(complete: false, parseFailure: "secret arbitrary failure text"))
        XCTAssertFalse(try response(complete: false, parseFailure: "malformedJSON").isComplete)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(complete)) as? [String: Any])
        object.removeValue(forKey: "totalKnownComplete")
        XCTAssertThrowsError(try JSONDecoder().decode(EngramServiceWebMessagesResponse.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testActualSuccessEnvelopeIncludesDataBase64ExpansionAndCurrentRequestID() throws {
        XCTAssertEqual(EngramServiceWebReadLimits.maximumFrameBytes, UnixSocketEngramServiceTransport.maximumFrameLength)
        let requestId = String(repeating: "\"\\界", count: 1800)
        let message = NormalizedMessage(role: .assistant, content: String(repeating: "\"\\\n界", count: 70_000))
        let request = try EngramServiceWebMessagesRequest(sessionId: "session", generation: generation)
        let result = try ServiceTranscriptContinuation.page(
            snapshot: .init(sessionId: "session", generation: generation, messages: [message]), request: request, requestId: requestId
        )
        XCTAssertFalse(result.fragments.isEmpty)
        XCTAssertNotNil(result.nextCursor)
        let inner = try JSONEncoder().encode(result)
        let wire = try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: requestId, result: inner))
        XCTAssertGreaterThan(wire.count, inner.count * 4 / 3)
        XCTAssertLessThanOrEqual(wire.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
        XCTAssertLessThan(wire.count, UnixSocketEngramServiceTransport.maximumFrameLength)
        let decoded = try JSONDecoder().decode(EngramServiceResponseEnvelope.self, from: wire)
        guard case let .success(actualID, payload, databaseGeneration) = decoded else { return XCTFail("Expected success") }
        XCTAssertEqual(actualID, requestId)
        XCTAssertNil(databaseGeneration)
        XCTAssertEqual(try JSONDecoder().decode(EngramServiceWebMessagesResponse.self, from: payload), result)
    }

    func testBudgetReservesForBase64EscapingAcrossCompactJSONReencodings_repro() throws {
        let requestId = "wire-budget-repro"
        let message = NormalizedMessage(role: .assistant, content: String(repeating: "\u{3ffff}??", count: 40_000))
        let request = try EngramServiceWebMessagesRequest(sessionId: "session", generation: generation)
        let result = try ServiceTranscriptContinuation.page(
            snapshot: .init(sessionId: "session", generation: generation, messages: [message]),
            request: request, requestId: requestId
        )
        XCTAssertFalse(result.fragments.isEmpty)
        let fixedOverhead = try JSONEncoder().encode(
            EngramServiceResponseEnvelope.success(requestId: requestId, result: Data())
        ).count
        for formatting: JSONEncoder.OutputFormatting in [[], [.sortedKeys]] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = formatting
            let inner = try encoder.encode(result)
            let base64Bytes = ((inner.count + 2) / 3) * 4
            // Every '/' in base64 must touch an input byte outside safe ASCII
            // (0...126 except '?'); each such byte touches at most two sextets.
            let unsafeASCIIBytes = inner.filter { $0 >= 127 || $0 == 63 }.count
            let escapedBase64UpperBound = base64Bytes + min(base64Bytes, 2 * unsafeASCIIBytes)
            XCTAssertLessThanOrEqual(fixedOverhead + escapedBase64UpperBound,
                                     EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
            let actual = try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: requestId, result: inner))
            XCTAssertLessThanOrEqual(actual.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
        }
    }

    private func fragment(ordinal: Int = 0, offset: Int = 0, sha: String? = nil,
                          payload: String = "{}") throws -> EngramServiceWebMessageFragment {
        try .init(messageOrdinal: ordinal, role: .user, payloadSHA256: sha ?? generation,
                  utf8Offset: offset, payloadFragment: payload, isLastFragment: true)
    }

    private func response(projection: String = EngramServiceWebReadLimits.projection,
                          redaction: String = EngramServiceWebReadLimits.redactionRevision,
                          complete: Bool = true, truncatedAt: Int? = nil, parseFailure: String? = nil) throws -> EngramServiceWebMessagesResponse {
        try .init(sessionId: "session", generation: generation, projection: projection, redactionRevision: redaction,
                  roles: [.user], fragments: [], nextCursor: nil, totalKnownComplete: complete,
                  truncatedAt: truncatedAt, parseFailure: parseFailure)
    }
}
