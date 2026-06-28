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
        try data.write(to: try url(for: key), options: .atomic)
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
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var manifests: [Any] = []
        for name in entries where ManifestCodec.isManifestKey(name) && ((try? RemoteStorageKey.validate(name)) != nil) {
            guard let target = try? url(for: name),
                  let data = try? Data(contentsOf: target),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            manifests.append(obj)
        }
        let payload: [String: Any] = ["schemaVersion": 1, "manifests": manifests]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
