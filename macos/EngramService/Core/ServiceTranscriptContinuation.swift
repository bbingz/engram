import CryptoKit
import EngramCoreRead
import Foundation

enum ServiceTranscriptContinuation {
    /// A caller-owned immutable generation, already confined and selected by
    /// the Service. This pure layer neither proves its binding nor reads files.
    struct Snapshot: Sendable {
        let sessionId: String
        let generation: String
        let messages: [NormalizedMessage]
        var totalKnownComplete: Bool = true
        var truncatedAt: Int?
        var parseFailure: ParserFailure?
    }

    static func redactedPayload(for message: NormalizedMessage) throws -> Data {
        guard let role = EngramServiceWebMessageRole(rawValue: message.role.rawValue) else {
            throw EngramServiceWebReadError.invalidField("role")
        }
        let projected = EngramServiceWebNormalizedMessage(
            role: role,
            content: TranscriptRedactionPolicy.redact(message.content),
            timestamp: message.timestamp.map(TranscriptRedactionPolicy.redact),
            toolCalls: message.toolCalls?.map {
                .init(name: TranscriptRedactionPolicy.redact($0.name),
                      input: $0.input.map(TranscriptRedactionPolicy.redact),
                      output: $0.output.map(TranscriptRedactionPolicy.redact))
            },
            usage: message.usage.map {
                .init(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                      cacheReadTokens: $0.cacheReadTokens, cacheCreationTokens: $0.cacheCreationTokens)
            }
        )
        return try canonicalEncoder().encode(projected)
    }

    static func page(
        snapshot: Snapshot?,
        request: EngramServiceWebMessagesRequest,
        requestId: String,
        maximumEnvelopeBytes: Int = EngramServiceWebReadLimits.maximumPageEnvelopeBytes
    ) throws -> EngramServiceWebMessagesResponse {
        guard let snapshot,
              Data(snapshot.sessionId.utf8) == Data(request.sessionId.utf8),
              snapshot.generation == request.generation else {
            throw EngramServiceWebReadError.staleCursor
        }
        guard snapshot.messages.count <= EngramServiceWebReadLimits.maximumMessages else {
            throw EngramServiceWebReadError.invalidField("messages")
        }
        guard maximumEnvelopeBytes > 0,
              maximumEnvelopeBytes <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
            throw EngramServiceWebReadError.responseTooLarge
        }
        let sessionSHA256 = sha256(Data(request.sessionId.utf8))
        let cursor = try request.cursor.map(Cursor.decode)
        if let cursor {
            guard cursor.version == 1, cursor.sessionSHA256 == sessionSHA256,
                  cursor.generation == request.generation,
                  cursor.projection == EngramServiceWebReadLimits.projection,
                  cursor.redactionRevision == EngramServiceWebReadLimits.redactionRevision,
                  cursor.roles == request.roles else {
                throw EngramServiceWebReadError.staleCursor
            }
            guard snapshot.messages.indices.contains(cursor.messageOrdinal),
                  request.roles.contains(where: { $0.rawValue == snapshot.messages[cursor.messageOrdinal].role.rawValue }),
                  cursor.utf8Offset >= 0 else {
                throw EngramServiceWebReadError.invalidCursor
            }
        }

        func nextOrdinal(from start: Int) -> Int? {
            (start..<snapshot.messages.count).first { index in
                request.roles.contains { $0.rawValue == snapshot.messages[index].role.rawValue }
            }
        }

        func response(_ fragments: [EngramServiceWebMessageFragment], next: Cursor?) throws -> EngramServiceWebMessagesResponse {
            try .init(
                sessionId: request.sessionId, generation: request.generation, roles: request.roles,
                fragments: fragments, nextCursor: try next?.encode(),
                totalKnownComplete: snapshot.totalKnownComplete && snapshot.truncatedAt == nil && snapshot.parseFailure == nil,
                truncatedAt: snapshot.truncatedAt, parseFailure: snapshot.parseFailure?.rawValue
            )
        }

        func fits(_ value: EngramServiceWebMessagesResponse) throws -> Bool {
            let result = try JSONEncoder().encode(value)
            let envelope = EngramServiceResponseEnvelope.success(requestId: requestId, result: result)
            guard try JSONEncoder().encode(envelope).count <= maximumEnvelopeBytes else { return false }
            // Compact JSON key reordering preserves byte count, not base64
            // alignment or slash escaping. Every '/' sextet must touch an input
            // byte outside ASCII 0...126 excluding '?'. Each such byte touches
            // at most two sextets, proving this order-independent escape bound.
            // It is tighter than doubling all base64 bytes for small ASCII pages.
            let unsafeASCIIBytes = result.reduce(0) { $0 + (($1 >= 127 || $1 == 63) ? 1 : 0) }
            let base64Bytes = ((result.count + 2) / 3) * 4
            let escapedBase64UpperBound = base64Bytes + min(base64Bytes, 2 * unsafeASCIIBytes)
            let fixedOverhead = try JSONEncoder().encode(
                EngramServiceResponseEnvelope.success(requestId: requestId, result: Data())
            ).count
            return fixedOverhead + escapedBase64UpperBound <= maximumEnvelopeBytes
        }

        func position(_ ordinal: Int, _ offset: Int, _ digest: String) -> Cursor {
            Cursor(sessionSHA256: sessionSHA256, generation: request.generation, roles: request.roles,
                   messageOrdinal: ordinal, utf8Offset: offset, payloadSHA256: digest)
        }

        var ordinal = cursor?.messageOrdinal ?? nextOrdinal(from: 0)
        var offset = cursor?.utf8Offset ?? 0
        var fragments: [EngramServiceWebMessageFragment] = []
        var accepted: EngramServiceWebMessagesResponse?
        // At most two complete messages are projected at once. The next payload
        // is retained when a page can include another message, not redacted twice.
        var prepared: (ordinal: Int, bytes: [UInt8], digest: String)?

        func prepare(_ index: Int) throws -> (ordinal: Int, bytes: [UInt8], digest: String) {
            let payload = try redactedPayload(for: snapshot.messages[index])
            return (index, [UInt8](payload), sha256(payload))
        }

        while let current = ordinal {
            let payload: (ordinal: Int, bytes: [UInt8], digest: String)
            if let prepared, prepared.ordinal == current {
                payload = prepared
            } else {
                payload = try prepare(current)
            }
            let bytes = payload.bytes
            let digest = payload.digest
            guard offset < bytes.count, isBoundary(offset, in: bytes) else {
                throw EngramServiceWebReadError.invalidCursor
            }
            if let cursor, current == cursor.messageOrdinal, cursor.payloadSHA256 != digest {
                throw EngramServiceWebReadError.staleCursor
            }
            guard let role = EngramServiceWebMessageRole(rawValue: snapshot.messages[current].role.rawValue) else {
                throw EngramServiceWebReadError.invalidField("role")
            }

            func fragment(endingAt end: Int) throws -> EngramServiceWebMessageFragment {
                // Both bounds are scalar boundaries; never replace malformed
                // partial UTF-8 and never JSON-decode individual fragments.
                guard let text = String(bytes: bytes[offset..<end], encoding: .utf8) else {
                    throw EngramServiceWebReadError.invalidCursor
                }
                return try .init(messageOrdinal: current, role: role, payloadSHA256: digest,
                                 utf8Offset: offset, payloadFragment: text, isLastFragment: end == bytes.count)
            }

            if bytes.count - offset <= maximumEnvelopeBytes {
                let following = nextOrdinal(from: current + 1)
                let nextPayload = try following.map(prepare)
                let next = nextPayload.map { position($0.ordinal, 0, $0.digest) }
                let candidate = try response(fragments + [fragment(endingAt: bytes.count)], next: next)
                if try fits(candidate) {
                    fragments = candidate.fragments
                    accepted = candidate
                    if fragments.count == request.maxFragments || following == nil { return candidate }
                    ordinal = following
                    offset = 0
                    prepared = nextPayload
                    continue
                }
            }

            // JSON escaping and the outer Data/base64 envelope make a raw byte
            // estimate insufficient. Binary-search with the real wire encoding.
            var low = offset + 1
            var high = min(bytes.count - 1, offset + min(maximumEnvelopeBytes, bytes.count - offset))
            var best: EngramServiceWebMessagesResponse?
            while low <= high {
                let midpoint = low + (high - low) / 2
                var end = midpoint
                while end > offset && !isBoundary(end, in: bytes) { end -= 1 }
                if end == offset {
                    low = midpoint + 1
                    continue
                }
                let candidate = try response(fragments + [fragment(endingAt: end)], next: position(current, end, digest))
                if try fits(candidate) {
                    best = candidate
                    low = midpoint + 1
                } else {
                    high = end - 1
                }
            }
            if let best { return best }
            if let accepted { return accepted }
            throw EngramServiceWebReadError.responseTooLarge
        }

        let empty = try response([], next: nil)
        guard try fits(empty) else { throw EngramServiceWebReadError.responseTooLarge }
        return empty
    }

    private struct Cursor: Codable {
        var version = 1
        let sessionSHA256: String
        let generation: String
        var projection = EngramServiceWebReadLimits.projection
        var redactionRevision = EngramServiceWebReadLimits.redactionRevision
        let roles: [EngramServiceWebMessageRole]
        let messageOrdinal: Int
        let utf8Offset: Int
        let payloadSHA256: String

        func encode() throws -> String {
            try canonicalEncoder().encode(self).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        static func decode(_ encoded: String) throws -> Cursor {
            guard encoded.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw EngramServiceWebReadError.invalidCursor
            }
            var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let data = Data(base64Encoded: base64),
                  let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
                  let canonical = try? cursor.encode(), canonical == encoded else {
                throw EngramServiceWebReadError.invalidCursor
            }
            return cursor
        }
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isBoundary(_ offset: Int, in bytes: [UInt8]) -> Bool {
        offset == bytes.count || bytes[offset] & 0xC0 != 0x80
    }
}
