import Foundation
import CryptoKit

/// Serializes/deserializes `RemoteSessionBundle` and computes its content hash.
/// The hash is over a deterministic payload (field order fixed, list joined with
/// a control separator) so the same content always yields the same key — the
/// basis for idempotent uploads. Server-held-key encryption (the owner's choice)
/// is handled at the transport (TLS) and server (at-rest) layers; the bundle
/// itself still carries an integrity hash so a corrupt download is detectable.
public enum BundleCodec {
    private static let recordSeparator = "\u{1e}"
    private static let lineSeparator = "\u{1f}"

    private static func canonicalPayload(
        sessionId: String,
        ftsContents: [String],
        summary: String?,
        summaryMessageCount: Int?,
        messageCount: Int,
        userMessageCount: Int,
        assistantMessageCount: Int,
        toolMessageCount: Int,
        systemMessageCount: Int
    ) -> Data {
        let fields: [String] = [
            "v\(RemoteSessionBundle.currentSchemaVersion)",
            sessionId,
            summary ?? "",
            summaryMessageCount.map(String.init) ?? "",
            String(messageCount),
            String(userMessageCount),
            String(assistantMessageCount),
            String(toolMessageCount),
            String(systemMessageCount),
            ftsContents.joined(separator: lineSeparator),
        ]
        return Data(fields.joined(separator: recordSeparator).utf8)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func makeBundle(
        sessionId: String,
        ftsContents: [String],
        summary: String?,
        summaryMessageCount: Int?,
        messageCount: Int,
        userMessageCount: Int,
        assistantMessageCount: Int,
        toolMessageCount: Int,
        systemMessageCount: Int
    ) -> RemoteSessionBundle {
        let payload = canonicalPayload(
            sessionId: sessionId,
            ftsContents: ftsContents,
            summary: summary,
            summaryMessageCount: summaryMessageCount,
            messageCount: messageCount,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            toolMessageCount: toolMessageCount,
            systemMessageCount: systemMessageCount
        )
        return RemoteSessionBundle(
            sessionId: sessionId,
            ftsContents: ftsContents,
            summary: summary,
            summaryMessageCount: summaryMessageCount,
            messageCount: messageCount,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            toolMessageCount: toolMessageCount,
            systemMessageCount: systemMessageCount,
            contentHash: hash(payload)
        )
    }

    /// Recompute the hash from the bundle's own fields, independent of the stored
    /// `contentHash`, so a tampered/corrupt bundle is caught on verify.
    public static func recomputeHash(_ bundle: RemoteSessionBundle) -> String {
        hash(canonicalPayload(
            sessionId: bundle.sessionId,
            ftsContents: bundle.ftsContents,
            summary: bundle.summary,
            summaryMessageCount: bundle.summaryMessageCount,
            messageCount: bundle.messageCount,
            userMessageCount: bundle.userMessageCount,
            assistantMessageCount: bundle.assistantMessageCount,
            toolMessageCount: bundle.toolMessageCount,
            systemMessageCount: bundle.systemMessageCount
        ))
    }

    public static func encode(_ bundle: RemoteSessionBundle) throws -> Data {
        try JSONEncoder().encode(bundle)
    }

    /// Decode and verify: supported schema, sessionId match (when expected), and
    /// recomputed content hash equals the stored hash.
    public static func decode(_ data: Data, expectedSessionId: String? = nil) throws -> RemoteSessionBundle {
        let bundle = try JSONDecoder().decode(RemoteSessionBundle.self, from: data)
        guard bundle.schemaVersion == RemoteSessionBundle.currentSchemaVersion else {
            throw RemoteSyncError.schemaVersionUnsupported(bundle.schemaVersion)
        }
        if let expectedSessionId, expectedSessionId != bundle.sessionId {
            throw RemoteSyncError.sessionIdMismatch(expected: expectedSessionId, actual: bundle.sessionId)
        }
        let recomputed = recomputeHash(bundle)
        guard recomputed == bundle.contentHash else {
            throw RemoteSyncError.contentHashMismatch(expected: bundle.contentHash, actual: recomputed)
        }
        return bundle
    }

    /// Filesystem/URL-safe content-addressed storage key.
    public static func contentKey(_ bundle: RemoteSessionBundle) -> String {
        "\(bundle.contentHash).bundle"
    }
}
