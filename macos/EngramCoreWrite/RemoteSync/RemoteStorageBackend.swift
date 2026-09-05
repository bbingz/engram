import Darwin
import Foundation

/// Pluggable blob store for offloaded session bundles, keyed by content hash.
/// v1 ships two conformers: `LocalDirectoryBackend` (a directory / network mount,
/// also the storage the self-hosted server exposes) and the HTTP-based
/// `EngramRemoteBackend` (talks to the self-hosted `engram-remote` server). The
/// protocol is the seam an S3-compatible backend would drop into later.
public protocol RemoteStorageBackend: Sendable {
    /// Cheap existence check so an idempotent upload can skip an already-present blob.
    func head(key: String) async throws -> Bool
    func put(key: String, data: Data) async throws
    func get(key: String) async throws -> Data
    func delete(key: String) async throws
    /// Aggregated per-peer manifests (`{schemaVersion, manifests:[...]}`) for Layer 2
    /// catalog discovery. The HTTP server aggregates them; a directory store
    /// aggregates its own `catalog.*.manifest` blobs.
    func catalog() async throws -> Data
}

public extension RemoteStorageBackend {
    /// Prove that the expected bundle is durable before local searchable content
    /// is collapsed. HEAD is only an optimization: an existing object must still
    /// be fetched, decoded, and matched to the expected content hash.
    func ensureDurable(bundle: RemoteSessionBundle) async throws {
        let encodedBundle = try BundleCodec.encode(bundle)
        // Reuse the canonical decode verifier so callers cannot make a forged
        // schema/hash pair durable under an attacker-controlled content key.
        _ = try BundleCodec.decode(encodedBundle, expectedSessionId: bundle.sessionId)

        let key = BundleCodec.contentKey(bundle)
        let exists = try await head(key: key)
        if !exists {
            try await put(key: key, data: encodedBundle)
        }

        let storedData = try await get(key: key)
        let storedBundle = try BundleCodec.decode(storedData, expectedSessionId: bundle.sessionId)
        guard storedBundle.contentHash == bundle.contentHash else {
            throw RemoteSyncError.contentHashMismatch(
                expected: bundle.contentHash,
                actual: storedBundle.contentHash
            )
        }
    }
}

public enum RemoteStorageKey {
    public static func validate(_ key: String) throws {
        guard !key.isEmpty, key.count <= 255, !key.contains("..") else {
            throw RemoteSyncError.invalidStorageKey(key)
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard key.allSatisfy({ allowed.contains($0) }) else {
            throw RemoteSyncError.invalidStorageKey(key)
        }
    }
}

/// File-backed store. Bundles live as `<root>/<key>`. Works against a local
/// directory or a network/NAS mount; the self-hosted server uses the same layout.
public struct LocalDirectoryBackend: RemoteStorageBackend {
    static let maximumCatalogBytes = 4 * 1024 * 1024
    static let maximumCatalogPeers = 1_024
    private static let catalogEnvelopeBytes = Data(#"{"schemaVersion":1,"manifests":[]}"#.utf8).count
    static let maximumCatalogManifestBytes = maximumCatalogBytes - catalogEnvelopeBytes
    private let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func url(for key: String) throws -> URL {
        try RemoteStorageKey.validate(key)
        return root.appendingPathComponent(key, isDirectory: false)
    }

    public func head(key: String) async throws -> Bool {
        FileManager.default.fileExists(atPath: try url(for: key).path)
    }

    public func put(key: String, data: Data) async throws {
        try Self.durableReplace(data, at: try url(for: key))
    }

    public func get(key: String) async throws -> Data {
        let target = try url(for: key)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw RemoteSyncError.bundleNotFound(key: key)
        }
        return try Data(contentsOf: target)
    }

    public func delete(key: String) async throws {
        let target = try url(for: key)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    /// Aggregate this store's `catalog.*.manifest` blobs into the same document
    /// shape the HTTP server's `GET /v1/catalog` returns, so a directory/NAS-mount
    /// backend supports Layer 2 catalog discovery. Unparseable manifests are skipped.
    public func catalog() async throws -> Data {
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let manifestKeys = entries
            .filter { ManifestCodec.isManifestKey($0) && ((try? RemoteStorageKey.validate($0)) != nil) }
            .sorted()
        var manifests: [[String: Any]] = []
        var remainingBytes = Self.maximumCatalogManifestBytes
        for name in manifestKeys {
            let target = try url(for: name)
            guard let data = Self.readCatalogManifest(at: target) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            // An object that cannot fit an otherwise-empty catalog is unusable,
            // regardless of whether a valid prefix was already accumulated.
            guard data.count <= Self.maximumCatalogManifestBytes else { continue }
            let requiredBytes = data.count + (manifests.isEmpty ? 0 : 1)
            if requiredBytes > remainingBytes {
                throw RemoteSyncError.catalogTooLarge
            }
            guard manifests.count < Self.maximumCatalogPeers else {
                throw RemoteSyncError.catalogTooLarge
            }
            remainingBytes -= requiredBytes
            manifests.append(obj)
        }
        let payload: [String: Any] = ["schemaVersion": 1, "manifests": manifests]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= Self.maximumCatalogBytes else {
            throw RemoteSyncError.catalogTooLarge
        }
        return data
    }

    private static func readCatalogManifest(at target: URL) -> Data? {
        guard let fileSize = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize >= 0,
              fileSize <= Self.maximumCatalogManifestBytes,
              let handle = try? FileHandle(forReadingFrom: target) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumCatalogManifestBytes + 1),
              data.count <= Self.maximumCatalogManifestBytes else {
            return nil
        }
        return data
    }

    private static func durableReplace(_ data: Data, at target: URL) throws {
        let parent = target.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".engram-remote-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let opened = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard opened >= 0 else { throw posixError() }
        var descriptor = opened
        var temporaryExists = true
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if temporaryExists { _ = Darwin.unlink(temporary.path) }
        }

        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw posixError()
        }
        descriptor = -1
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw posixError() }
        temporaryExists = false
        try fsyncDirectory(parent)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
