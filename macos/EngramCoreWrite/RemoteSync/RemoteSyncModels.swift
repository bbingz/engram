import Foundation

/// A self-contained, content-addressed snapshot of a session's *regenerable*
/// index artifacts (the FTS search lines + summary + message counts). The
/// original transcript bytes on disk are NEVER part of a bundle — they stay in
/// the tool-owned source directory and are never moved. Offloading a bundle and
/// purging the local FTS rows is what reclaims local disk; rehydrating restores
/// full keyword searchability from the bundle.
public struct RemoteSessionBundle: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionId: String
    /// The full FTS content lines (one per user/assistant message + summary),
    /// exactly as `sessions_fts` stored them, so rehydrate restores them verbatim.
    public let ftsContents: [String]
    public let summary: String?
    public let summaryMessageCount: Int?
    public let messageCount: Int
    public let userMessageCount: Int
    public let assistantMessageCount: Int
    public let toolMessageCount: Int
    public let systemMessageCount: Int
    /// SHA-256 (hex) of the canonical payload, excluding this field. Doubles as
    /// the storage key so identical content is idempotent (HEAD-then-PUT skips).
    public let contentHash: String

    public init(
        schemaVersion: Int = RemoteSessionBundle.currentSchemaVersion,
        sessionId: String,
        ftsContents: [String],
        summary: String?,
        summaryMessageCount: Int?,
        messageCount: Int,
        userMessageCount: Int,
        assistantMessageCount: Int,
        toolMessageCount: Int,
        systemMessageCount: Int,
        contentHash: String
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.ftsContents = ftsContents
        self.summary = summary
        self.summaryMessageCount = summaryMessageCount
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.toolMessageCount = toolMessageCount
        self.systemMessageCount = systemMessageCount
        self.contentHash = contentHash
    }
}

public enum RemoteSyncError: Error, Equatable {
    case schemaVersionUnsupported(Int)
    case contentHashMismatch(expected: String, actual: String)
    case sessionIdMismatch(expected: String, actual: String)
    case bundleNotFound(key: String)
    /// The session was re-indexed (or removed) between capturing its bundle and
    /// committing the offload, so purging now would collapse content that no
    /// longer matches the uploaded bundle. The offload is aborted and re-queued.
    case offloadStale(sessionId: String)
}

/// Builds the single compact FTS line kept for an offloaded session so it stays
/// discoverable by keyword search (design must-fix #8) without re-materializing
/// the full transcript. Without a shadow, an offloaded session would be
/// invisible to keyword search — and you cannot rehydrate what you cannot find.
public enum OffloadShadow {
    public static func line(title: String?, project: String?, summary: String?, sessionId: String) -> String {
        let parts = [title, project, summary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = parts.joined(separator: " — ")
        return joined.isEmpty ? sessionId : joined
    }
}
