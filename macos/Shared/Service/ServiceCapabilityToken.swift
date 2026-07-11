import Foundation
import Security

/// Per-launch capability token used to authorize destructive service commands
/// (project moves, insight deletes, hide/rename) over the Unix socket.
///
/// The service process writes a fresh random token to
/// `~/.engram/run/cmd.token` (mode 0600) when it starts listening. Trusted
/// clients running as the same user read that file and attach the value to the
/// request envelope. The service rejects destructive commands whose token does
/// not match the on-disk value with `EngramServiceError.unauthorized`.
///
/// This is defense-in-depth on top of the peer-euid check: a non-privileged
/// process that somehow reaches the socket but cannot read the 0600 token file
/// still cannot mutate state.
enum ServiceCapabilityToken {
    /// Commands that mutate state and therefore require a valid capability token.
    static let protectedCommands: Set<String> = [
        "generateSummary",
        "saveInsight",
        "refreshUsage",
        "test.write_intent",
        "projectMove",
        "projectArchive",
        "projectUndo",
        "projectMoveBatch",
        "cancelProjectMoveBatch",
        "cancelProjectMoveBatch",
        "deleteInsight",
        "manageProjectAlias",
        "setParentSession",
        "clearParentSession",
        "confirmSuggestion",
        "dismissSuggestion",
        "dismissAmbiguousSuggestion",
        "addSessionRelation",
        "removeSessionRelation",
        "regenerateAllTitles",
        "generateProjectWorkTitles",
        "setFavorite",
        "setSessionHidden",
        "setSourceEnabled",
        "renameSession",
        "recordSessionAccess",
        "recordInsightAccess",
        "hideEmptySessions",
        "linkSessions",
        "exportSession",
        "remoteOffload",
        "remoteRehydrate",
        "remotePushProject",
        "remotePullProject",
        "archiveV2Retry",
    ]

    static func requiresToken(_ command: String) -> Bool {
        protectedCommands.contains(command)
    }

    /// Default location of the capability token file.
    static func defaultPath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        homeDirectory
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("cmd.token")
            .path
    }

    /// Resolve the token path that pairs with a given socket path. The token
    /// always lives next to the socket so per-test sockets get their own token.
    static func path(forSocketPath socketPath: String) -> String {
        URL(fileURLWithPath: socketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cmd.token")
            .path
    }

    /// Generate a fresh random token and write it atomically with mode 0600.
    /// Returns the generated token. Called by the service when it starts.
    @discardableResult
    static func generateAndWrite(toPath path: String) throws -> String {
        let token = makeRandomToken()
        let data = Data(token.utf8)
        let fileManager = FileManager.default
        // Remove any stale token so we never inherit looser permissions.
        if fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
        let created = fileManager.createFile(
            atPath: path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot write capability token")
        }
        // Enforce 0600 even if the umask / createFile attributes were ignored.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return token
    }

    /// Load the current token written by the service, or nil if unreadable.
    static func load(fromPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func makeRandomToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // Fallback: still high-entropy via system RNG.
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
