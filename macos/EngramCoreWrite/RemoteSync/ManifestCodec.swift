import Foundation

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

    public init(
        sessionId: String, source: String, project: String?, title: String?,
        startTime: String, endTime: String?, messageCount: Int, userMessageCount: Int,
        assistantMessageCount: Int, systemMessageCount: Int, toolMessageCount: Int,
        summary: String?, summaryMessageCount: Int?, sizeBytes: Int, tier: String?,
        remoteKey: String, contentHash: String
    ) {
        self.sessionId = sessionId; self.source = source; self.project = project
        self.title = title; self.startTime = startTime; self.endTime = endTime
        self.messageCount = messageCount; self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount; self.systemMessageCount = systemMessageCount
        self.toolMessageCount = toolMessageCount; self.summary = summary
        self.summaryMessageCount = summaryMessageCount; self.sizeBytes = sizeBytes
        self.tier = tier; self.remoteKey = remoteKey; self.contentHash = contentHash
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
    /// Storage key for a peer's manifest blob. Sanitized to the BlobStore key
    /// charset so a hostname with odd characters can't produce an invalid key.
    public static func manifestKey(peer: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let safe = String(peer.map { allowed.contains($0) ? $0 : "-" })
        return "catalog.\(safe.isEmpty ? "peer" : safe).manifest"
    }

    public static func encode(_ manifest: SyncManifest) throws -> Data {
        try JSONEncoder().encode(manifest)
    }

    public static func decode(_ data: Data) throws -> SyncManifest {
        try JSONDecoder().decode(SyncManifest.self, from: data)
    }

    /// Parse the aggregated `GET /v1/catalog` document `{schemaVersion, manifests:[...]}`
    /// into manifests, tolerating entries that fail to decode (skipped, not fatal).
    public static func decodeCatalog(_ data: Data) -> [SyncManifest] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["manifests"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let bytes = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? decode(bytes)
        }
    }
}
