import CryptoKit
import Foundation

/// Small pointer blob `live.<peer>.head`. The generation list lives at
/// `manifestKey` so a head write never overwrites previous generation bytes.
public struct LiveIngestHead: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let peer: String
    public let generation: Int
    public let seq: Int
    public let complete: Bool
    public let entryCount: Int
    public let manifestKey: String
    public let contentHash: String
    public let withdrawnCount: Int

    public init(
        peer: String,
        generation: Int,
        seq: Int,
        complete: Bool,
        entryCount: Int,
        manifestKey: String,
        contentHash: String,
        withdrawnCount: Int,
        schemaVersion: Int = LiveIngestHead.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.peer = peer
        self.generation = generation
        self.seq = seq
        self.complete = complete
        self.entryCount = entryCount
        self.manifestKey = manifestKey
        self.contentHash = contentHash
        self.withdrawnCount = withdrawnCount
    }
}

public enum LiveIngestKeys {
    public static func sanitizePeer(_ peer: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let safe = String(peer.map { allowed.contains($0) ? $0 : "-" })
        return safe.isEmpty ? "peer" : safe
    }

    public static func head(peer: String) -> String {
        "live.\(sanitizePeer(peer)).head"
    }

    public static func manifest(peer: String, generation: Int, seq: Int) -> String {
        "live.\(sanitizePeer(peer)).\(generation).\(seq).manifest"
    }
}

/// Per-peer sync manifest: the metadata catalog a Mac publishes to the hub so
/// OTHER Macs can discover its project sessions without a local ledger row. The
/// content-addressed bundle (`RemoteSessionBundle`) carries the searchable FTS +
/// summary, but NOT the session metadata (source/project/title/timestamps), so
/// the manifest carries that — `ImportRepo` reconstructs an imported session row
/// from a manifest entry + its bundle.
///
/// Each Mac owns exactly one blob `catalog.<peer>.manifest` (full-replace on each
/// push, so no cross-Mac write contention). The server aggregates all of them at
/// `GET /v1/catalog`.
public struct SyncManifestEntry: Codable, Sendable, Equatable {
    public let sessionId: String
    public let source: String
    public let project: String?
    public let title: String?
    public let startTime: String
    public let endTime: String?
    public let messageCount: Int
    public let userMessageCount: Int
    public let assistantMessageCount: Int
    public let systemMessageCount: Int
    public let toolMessageCount: Int
    public let summary: String?
    public let summaryMessageCount: Int?
    public let sizeBytes: Int
    public let tier: String?
    public let remoteKey: String
    public let contentHash: String
    public let agentRole: String?
    public let parentSessionId: String?
    public let suggestedParentId: String?

    public init(
        sessionId: String, source: String, project: String?, title: String?,
        startTime: String, endTime: String?, messageCount: Int, userMessageCount: Int,
        assistantMessageCount: Int, systemMessageCount: Int, toolMessageCount: Int,
        summary: String?, summaryMessageCount: Int?, sizeBytes: Int, tier: String?,
        remoteKey: String, contentHash: String, agentRole: String? = nil,
        parentSessionId: String? = nil, suggestedParentId: String? = nil
    ) {
        self.sessionId = sessionId; self.source = source; self.project = project
        self.title = title; self.startTime = startTime; self.endTime = endTime
        self.messageCount = messageCount; self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount; self.systemMessageCount = systemMessageCount
        self.toolMessageCount = toolMessageCount; self.summary = summary
        self.summaryMessageCount = summaryMessageCount; self.sizeBytes = sizeBytes
        self.tier = tier; self.remoteKey = remoteKey; self.contentHash = contentHash
        self.agentRole = agentRole; self.parentSessionId = parentSessionId
        self.suggestedParentId = suggestedParentId
    }
}

public struct SyncManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let peer: String
    public let updatedAt: String
    public let entries: [SyncManifestEntry]

    public init(peer: String, updatedAt: String, entries: [SyncManifestEntry]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.peer = peer
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

public enum ManifestCodec {
    private struct CatalogEnvelopeHeader: Decodable {
        let schemaVersion: Int
    }

    /// Storage key for a peer's manifest blob. Sanitized to the BlobStore key
    /// charset so a hostname with odd characters can't produce an invalid key.
    public static func manifestKey(peer: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let safe = String(peer.map { allowed.contains($0) ? $0 : "-" })
        return "catalog.\(safe.isEmpty ? "peer" : safe).manifest"
    }

    /// True for a per-peer manifest blob key (`catalog.<peer>.manifest`). Both
    /// catalog producers — `LocalDirectoryBackend.catalog()` and the HTTP server's
    /// `GET /v1/catalog` route — must select with this same predicate so they yield
    /// the same document; a stray `catalog.*` non-manifest blob is selected by
    /// neither. The `..` rejection mirrors the server's `BlobStore.validate` (which
    /// rejects any key containing `..`), so a pathological peer name that sanitizes
    /// to `catalog..manifest` is excluded by BOTH producers, not just the server.
    /// (The server, being storage-format-agnostic, mirrors the suffix check inline
    /// rather than depending on this module.)
    public static func isManifestKey(_ key: String) -> Bool {
        key.hasPrefix("catalog.") && key.hasSuffix(".manifest") && !key.contains("..")
    }

    public static func encode(_ manifest: SyncManifest) throws -> Data {
        try JSONEncoder().encode(manifest)
    }

    public static func decode(_ data: Data) throws -> SyncManifest {
        let manifest = try JSONDecoder().decode(SyncManifest.self, from: data)
        guard manifest.schemaVersion == SyncManifest.currentSchemaVersion else {
            throw RemoteSyncError.schemaVersionUnsupported(manifest.schemaVersion)
        }
        return manifest
    }

    /// Parse the aggregated `GET /v1/catalog` document `{schemaVersion, manifests:[...]}`
    /// into manifests. An unsupported envelope fails closed; individual manifests
    /// that fail to decode remain isolated from compatible peers.
    public static func decodeCatalog(_ data: Data) throws -> [SyncManifest] {
        guard let header = try? JSONDecoder().decode(CatalogEnvelopeHeader.self, from: data) else {
            throw RemoteSyncError.invalidCatalog
        }
        guard header.schemaVersion == SyncManifest.currentSchemaVersion else {
            throw RemoteSyncError.schemaVersionUnsupported(header.schemaVersion)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["manifests"] as? [Any]
        else {
            throw RemoteSyncError.invalidCatalog
        }
        let objectEntries = raw.compactMap { $0 as? [String: Any] }
        let manifests = objectEntries.compactMap { entry -> SyncManifest? in
            guard let bytes = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? decode(bytes)
        }
        // Legacy object-shaped catalog entries are isolated just like one bad
        // peer beside a valid peer. A non-object-only payload is still invalid.
        guard raw.isEmpty || !objectEntries.isEmpty else {
            throw RemoteSyncError.invalidCatalog
        }
        return manifests
    }

    /// Live generation blobs are a single object, not the 4 MiB catalog aggregate.
    public static let maxLiveManifestBytes = 16 * 1024 * 1024

    public static func liveManifestContentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func encodeLiveHead(_ head: LiveIngestHead) throws -> Data {
        try encodeLiveBytes(JSONEncoder().encode(head))
    }

    public static func decodeLiveHead(_ data: Data) throws -> LiveIngestHead {
        try rejectLiveOversize(data)
        let head = try JSONDecoder().decode(LiveIngestHead.self, from: data)
        guard head.schemaVersion == LiveIngestHead.currentSchemaVersion else {
            throw RemoteSyncError.schemaVersionUnsupported(head.schemaVersion)
        }
        return head
    }

    public static func encodeLiveManifest(_ manifest: SyncManifest) throws -> Data {
        try encodeLiveBytes(JSONEncoder().encode(manifest))
    }

    public static func decodeLiveManifest(_ data: Data) throws -> SyncManifest {
        try rejectLiveOversize(data)
        return try decode(data)
    }

    private static func encodeLiveBytes(_ data: Data) throws -> Data {
        try rejectLiveOversize(data)
        return data
    }

    private static func rejectLiveOversize(_ data: Data) throws {
        if data.count > maxLiveManifestBytes {
            throw RemoteSyncError.liveManifestTooLarge
        }
    }
}
