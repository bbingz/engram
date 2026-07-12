import Compression
import CryptoKit
import Foundation

public enum ArchiveEnvelopeKind: UInt8, Equatable, Sendable {
    case object = 1
    case manifest = 2
    case receipt = 3
}

enum ArchiveEnvelopeCompression: UInt8, Sendable {
    case raw = 0
    case lzfse = 1
}

public enum ArchiveEnvelopeError: Error, Equatable, Sendable {
    case invalidExpectedDigest
    case inputTooLarge
    case malformedEnvelope
    case authenticationFailed
    case unsupportedEnvelope
    case decompressionFailed
    case rawDigestMismatch
}

/// Versioned authenticated envelope for immutable archive bytes.
///
/// The fixed header is authenticated, not trusted. Decode authenticates it
/// before interpreting its codec or allocating its declared raw length.
public struct ArchiveEnvelopeCodec: Sendable {
    static let codecByteOffset = 6
    static let rawLengthOffset = 8

    private static let magic = Data([0x45, 0x41, 0x56, 0x32]) // EAV2
    private static let version: UInt8 = 1
    private static let headerLength = 48
    private static let minimumSealedLength = 12 + 16

    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    public func encode(
        raw: Data,
        kind: ArchiveEnvelopeKind,
        expectedDigest: String
    ) throws -> Data {
        guard ArchiveV2Hash.isValidSHA256(expectedDigest) else {
            throw ArchiveEnvelopeError.invalidExpectedDigest
        }
        guard raw.count <= Self.maxRawBytes(for: kind) else {
            throw ArchiveEnvelopeError.inputTooLarge
        }
        if kind != .receipt, ArchiveV2Hash.sha256(raw) != expectedDigest {
            throw ArchiveEnvelopeError.rawDigestMismatch
        }

        let compressed = Self.lzfseCompressIfSmaller(raw)
        let payload = compressed ?? raw
        let compression: ArchiveEnvelopeCompression = compressed == nil ? .raw : .lzfse
        let rawDigest = Data(SHA256.hash(data: raw))
        let header = Self.makeHeader(
            kind: kind,
            compression: compression,
            rawLength: raw.count,
            rawDigest: rawDigest
        )
        let sealed = try AES.GCM.seal(
            payload,
            using: key,
            authenticating: Self.additionalData(
                header: header,
                expectedKind: kind,
                expectedDigest: expectedDigest
            )
        )
        guard let combined = sealed.combined else {
            throw ArchiveEnvelopeError.malformedEnvelope
        }
        var envelope = header
        envelope.append(combined)
        return envelope
    }

    public func decode(
        _ envelope: Data,
        expectedKind: ArchiveEnvelopeKind,
        expectedDigest: String
    ) throws -> Data {
        guard ArchiveV2Hash.isValidSHA256(expectedDigest) else {
            throw ArchiveEnvelopeError.invalidExpectedDigest
        }
        guard envelope.count >= Self.headerLength + Self.minimumSealedLength else {
            throw ArchiveEnvelopeError.malformedEnvelope
        }

        let header = Data(envelope.prefix(Self.headerLength))
        let sealedBytes = Data(envelope.dropFirst(Self.headerLength))
        let plaintextPayload: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: sealedBytes)
            plaintextPayload = try AES.GCM.open(
                sealed,
                using: key,
                authenticating: Self.additionalData(
                    header: header,
                    expectedKind: expectedKind,
                    expectedDigest: expectedDigest
                )
            )
        } catch {
            throw ArchiveEnvelopeError.authenticationFailed
        }

        guard Data(header.prefix(Self.magic.count)) == Self.magic,
              header[4] == Self.version,
              header[5] == expectedKind.rawValue,
              header[7] == 0,
              let compression = ArchiveEnvelopeCompression(rawValue: header[Self.codecByteOffset]) else {
            throw ArchiveEnvelopeError.unsupportedEnvelope
        }
        let rawLength = try Self.decodeRawLength(header)
        guard rawLength <= Self.maxRawBytes(for: expectedKind) else {
            throw ArchiveEnvelopeError.inputTooLarge
        }
        let authenticatedRawDigest = Data(header[16..<48])

        let raw: Data
        switch compression {
        case .raw:
            guard plaintextPayload.count == rawLength else {
                throw ArchiveEnvelopeError.malformedEnvelope
            }
            raw = plaintextPayload
        case .lzfse:
            raw = try Self.lzfseDecompress(plaintextPayload, rawLength: rawLength)
        }
        let actualRawDigest = Data(SHA256.hash(data: raw))
        guard actualRawDigest == authenticatedRawDigest else {
            throw ArchiveEnvelopeError.rawDigestMismatch
        }
        if expectedKind != .receipt, ArchiveV2Hash.sha256(raw) != expectedDigest {
            throw ArchiveEnvelopeError.rawDigestMismatch
        }
        return raw
    }

    private static func makeHeader(
        kind: ArchiveEnvelopeKind,
        compression: ArchiveEnvelopeCompression,
        rawLength: Int,
        rawDigest: Data
    ) -> Data {
        var header = magic
        header.append(version)
        header.append(kind.rawValue)
        header.append(compression.rawValue)
        header.append(0)
        var length = UInt64(rawLength).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(rawDigest)
        return header
    }

    private static func additionalData(
        header: Data,
        expectedKind: ArchiveEnvelopeKind,
        expectedDigest: String
    ) -> Data {
        var data = Data("engram-archive-envelope-aad".utf8)
        data.append(0)
        data.append(header)
        data.append(expectedKind.rawValue)
        data.append(contentsOf: expectedDigest.utf8)
        return data
    }

    private static func decodeRawLength(_ header: Data) throws -> Int {
        var value: UInt64 = 0
        for byte in header[rawLengthOffset..<(rawLengthOffset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        guard value <= UInt64(Int.max) else {
            throw ArchiveEnvelopeError.inputTooLarge
        }
        return Int(value)
    }

    private static func maxRawBytes(for kind: ArchiveEnvelopeKind) -> Int {
        switch kind {
        case .object:
            ArchiveV2ProtocolLimits.maxObjectRawBytes
        case .manifest:
            ArchiveV2ProtocolLimits.maxManifestBytes
        case .receipt:
            ArchiveV2ProtocolLimits.maxReceiptBytes
        }
    }

    private static func lzfseCompressIfSmaller(_ raw: Data) -> Data? {
        guard !raw.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: raw.count)
        let encodedCount = raw.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard encodedCount > 0, encodedCount < raw.count else { return nil }
        return Data(output.prefix(encodedCount))
    }

    private static func lzfseDecompress(_ payload: Data, rawLength: Int) throws -> Data {
        guard rawLength > 0 else {
            throw ArchiveEnvelopeError.decompressionFailed
        }
        var output = [UInt8](repeating: 0, count: rawLength)
        let decodedCount = payload.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decodedCount == rawLength else {
            throw ArchiveEnvelopeError.decompressionFailed
        }
        return Data(output)
    }
}
