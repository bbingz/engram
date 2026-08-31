import Foundation
import CryptoKit

public enum BlobStoreError: Error, Equatable {
    case invalidKey(String)
    case notFound(String)
    case sealFailed
    case limitExceeded
}

/// File-backed content-addressed blob store with AES-GCM at-rest encryption.
/// Blobs are keyed by the client's content hash; the on-disk bytes are ciphertext
/// under the server-held key, so a stolen disk image yields no plaintext. The
/// store treats blobs as opaque — it has no knowledge of the bundle format.
public struct BlobStore: Sendable {
    private let root: URL
    private let key: SymmetricKey

    public init(root: URL, key: SymmetricKey) throws {
        self.root = root
        self.key = key
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Reject anything but a flat, safe key so a crafted key cannot escape `root`.
    public static func validate(key: String) throws {
        guard !key.isEmpty, key.count <= 255, !key.contains("..") else {
            throw BlobStoreError.invalidKey(key)
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard key.allSatisfy({ allowed.contains($0) }) else {
            throw BlobStoreError.invalidKey(key)
        }
    }

    private func url(for key: String) throws -> URL {
        try Self.validate(key: key)
        return root.appendingPathComponent(key, isDirectory: false)
    }

    public func exists(_ key: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try url(for: key).path)
    }

    public func put(_ key: String, plaintext: Data) throws {
        let sealed = try AES.GCM.seal(plaintext, using: self.key)
        guard let combined = sealed.combined else { throw BlobStoreError.sealFailed }
        try combined.write(to: try url(for: key), options: .atomic)
    }

    public func get(_ key: String) throws -> Data {
        let target = try url(for: key)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw BlobStoreError.notFound(key)
        }
        let combined = try Data(contentsOf: target)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: self.key)
    }

    /// Reads at most the requested plaintext budget plus a conservative bound
    /// for the AES-GCM combined nonce/tag envelope. This keeps callers from
    /// allocating an entire oversized encrypted blob before rejecting it.
    func get(_ key: String, maximumPlaintextBytes: Int) throws -> Data {
        guard maximumPlaintextBytes >= 0 else { throw BlobStoreError.limitExceeded }
        let target = try url(for: key)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw BlobStoreError.notFound(key)
        }

        let maximumSealOverheadBytes = 64
        let (maximumCombinedBytes, combinedOverflow) = maximumPlaintextBytes
            .addingReportingOverflow(maximumSealOverheadBytes)
        let (readLimit, readOverflow) = maximumCombinedBytes.addingReportingOverflow(1)
        guard !combinedOverflow, !readOverflow else { throw BlobStoreError.limitExceeded }

        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        let combined = try handle.read(upToCount: readLimit) ?? Data()
        guard combined.count <= maximumCombinedBytes else {
            throw BlobStoreError.limitExceeded
        }

        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: self.key)
        guard plaintext.count <= maximumPlaintextBytes else {
            throw BlobStoreError.limitExceeded
        }
        return plaintext
    }

    public func delete(_ key: String) throws {
        let target = try url(for: key)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    /// Flat list of valid blob keys whose name begins with `prefix` (e.g.
    /// "catalog." for per-peer manifests). Names that fail `validate` are skipped
    /// so a stray file can't surface as a key. Still format-agnostic — the store
    /// never decodes the blobs it lists.
    public func listKeys(prefix: String) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return names
            .filter { $0.hasPrefix(prefix) && ((try? Self.validate(key: $0)) != nil) }
            .sorted()
    }

    /// Lazily enumerates a bounded set of flat keys. The suffix belongs here so
    /// unrelated `catalog.*` blobs do not consume a peer slot before filtering.
    func listKeys(prefix: String, suffix: String, maximumCount: Int) throws -> [String] {
        guard maximumCount >= 0 else { throw BlobStoreError.limitExceeded }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw CocoaError(.fileReadUnknown)
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            if let enumerationError { throw enumerationError }
            return []
        }

        var names: [String] = []
        for case let candidate as URL in enumerator {
            let name = candidate.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                  (try? Self.validate(key: name)) != nil else { continue }
            guard names.count < maximumCount else {
                throw BlobStoreError.limitExceeded
            }
            names.append(name)
        }
        if let enumerationError { throw enumerationError }
        return names.sorted()
    }
}
