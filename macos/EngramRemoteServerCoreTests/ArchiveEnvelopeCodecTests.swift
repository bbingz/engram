import CryptoKit
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class ArchiveEnvelopeCodecTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0x11, count: 32))

    func testEnvelopeCompressesOnlyWhenSmallerAndRoundTripsExactBytes() throws {
        let codec = ArchiveEnvelopeCodec(key: key)
        let compressible = Data(repeating: 0x41, count: 128 * 1024)
        let compressibleDigest = ArchiveV2Hash.sha256(compressible)
        let compressedEnvelope = try codec.encode(
            raw: compressible,
            kind: .object,
            expectedDigest: compressibleDigest
        )

        XCTAssertLessThan(compressedEnvelope.count, compressible.count)
        XCTAssertEqual(
            try codec.decode(
                compressedEnvelope,
                expectedKind: .object,
                expectedDigest: compressibleDigest
            ),
            compressible
        )

        let incompressible = deterministicNoise(byteCount: 64 * 1024)
        let incompressibleDigest = ArchiveV2Hash.sha256(incompressible)
        let rawEnvelope = try codec.encode(
            raw: incompressible,
            kind: .object,
            expectedDigest: incompressibleDigest
        )
        XCTAssertGreaterThan(rawEnvelope.count, incompressible.count)
        XCTAssertEqual(
            try codec.decode(
                rawEnvelope,
                expectedKind: .object,
                expectedDigest: incompressibleDigest
            ),
            incompressible
        )
    }

    func testEnvelopeCiphertextDoesNotContainPlaintextSentinel() throws {
        let codec = ArchiveEnvelopeCodec(key: key)
        let sentinel = Data("ARCHIVE-PLAINTEXT-SENTINEL-DO-NOT-LEAK".utf8)
        var raw = Data()
        for _ in 0..<256 { raw.append(sentinel) }
        let digest = ArchiveV2Hash.sha256(raw)

        let envelope = try codec.encode(raw: raw, kind: .manifest, expectedDigest: digest)

        XCTAssertNil(envelope.range(of: sentinel))
        XCTAssertNotEqual(envelope, raw)
    }

    func testWrongKeyKindDigestAndTamperingFailBeforeReturningPlaintext() throws {
        let codec = ArchiveEnvelopeCodec(key: key)
        let raw = Data("authenticated archive envelope".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let otherDigest = ArchiveV2Hash.sha256(Data("other".utf8))
        let envelope = try codec.encode(raw: raw, kind: .object, expectedDigest: digest)

        let wrongKey = ArchiveEnvelopeCodec(
            key: SymmetricKey(data: Data(repeating: 0x22, count: 32))
        )
        XCTAssertThrowsError(
            try wrongKey.decode(envelope, expectedKind: .object, expectedDigest: digest)
        )
        XCTAssertThrowsError(
            try codec.decode(envelope, expectedKind: .manifest, expectedDigest: digest)
        )
        XCTAssertThrowsError(
            try codec.decode(envelope, expectedKind: .object, expectedDigest: otherDigest)
        )

        var codecTampered = envelope
        codecTampered[ArchiveEnvelopeCodec.codecByteOffset] ^= 0x01
        XCTAssertThrowsError(
            try codec.decode(codecTampered, expectedKind: .object, expectedDigest: digest)
        )

        var lengthTampered = envelope
        lengthTampered[ArchiveEnvelopeCodec.rawLengthOffset] ^= 0x01
        XCTAssertThrowsError(
            try codec.decode(lengthTampered, expectedKind: .object, expectedDigest: digest)
        )

        var ciphertextTampered = envelope
        ciphertextTampered[ciphertextTampered.index(before: ciphertextTampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(
            try codec.decode(ciphertextTampered, expectedKind: .object, expectedDigest: digest)
        )
    }

    func testObjectAndManifestEncodingRequireRawDigestToMatchExpectedPathDigest() throws {
        let codec = ArchiveEnvelopeCodec(key: key)
        let raw = Data("path digest must name these exact bytes".utf8)
        let wrongDigest = ArchiveV2Hash.sha256(Data("different bytes".utf8))

        XCTAssertThrowsError(
            try codec.encode(raw: raw, kind: .object, expectedDigest: wrongDigest)
        ) { error in
            XCTAssertEqual(error as? ArchiveEnvelopeError, .rawDigestMismatch)
        }
        XCTAssertThrowsError(
            try codec.encode(raw: raw, kind: .manifest, expectedDigest: wrongDigest)
        ) { error in
            XCTAssertEqual(error as? ArchiveEnvelopeError, .rawDigestMismatch)
        }
        XCTAssertNoThrow(
            try codec.encode(raw: raw, kind: .receipt, expectedDigest: wrongDigest)
        )
    }

    func testDecodeRejectsAuthenticatedObjectWhoseRawDigestDoesNotMatchExpectedPath() throws {
        let codec = ArchiveEnvelopeCodec(key: key)
        let raw = Data("authenticated but named by the wrong path digest".utf8)
        let wrongPathDigest = ArchiveV2Hash.sha256(Data("different path bytes".utf8))
        let adversarialEnvelope = try makeAuthenticatedRawEnvelope(
            raw: raw,
            kind: .object,
            expectedDigest: wrongPathDigest
        )

        XCTAssertThrowsError(
            try codec.decode(
                adversarialEnvelope,
                expectedKind: .object,
                expectedDigest: wrongPathDigest
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveEnvelopeError, .rawDigestMismatch)
        }
    }

    private func deterministicNoise(byteCount: Int) -> Data {
        var result = Data()
        var counter: UInt64 = 0
        while result.count < byteCount {
            var bigEndian = counter.bigEndian
            withUnsafeBytes(of: &bigEndian) { bytes in
                result.append(contentsOf: SHA256.hash(data: Data(bytes)))
            }
            counter += 1
        }
        return Data(result.prefix(byteCount))
    }

    private func makeAuthenticatedRawEnvelope(
        raw: Data,
        kind: ArchiveEnvelopeKind,
        expectedDigest: String
    ) throws -> Data {
        var header = Data([0x45, 0x41, 0x56, 0x32, 0x01, kind.rawValue, 0x00, 0x00])
        var rawLength = UInt64(raw.count).bigEndian
        withUnsafeBytes(of: &rawLength) { header.append(contentsOf: $0) }
        header.append(Data(SHA256.hash(data: raw)))

        var aad = Data("engram-archive-envelope-aad".utf8)
        aad.append(0)
        aad.append(header)
        aad.append(kind.rawValue)
        aad.append(contentsOf: expectedDigest.utf8)
        let sealed = try AES.GCM.seal(raw, using: key, authenticating: aad)
        var envelope = header
        envelope.append(try XCTUnwrap(sealed.combined))
        return envelope
    }
}
