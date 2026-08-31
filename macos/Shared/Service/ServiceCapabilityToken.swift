import Foundation
import Security
import Darwin

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
        "liveIngestResetShrinkGuard",
        "archiveV2Retry",
        "archiveV2StoreToken",
        "archiveV2RemoteRecoveryProbe",
        "archiveReclamationUpdateSettings",
        "archiveReclamationRun",
        "archiveV2RecoveryDrill",
        "configureClaudeCodeProfiles",
    ]

    static func requiresToken(_ command: String) -> Bool {
        protectedCommands.contains(command)
    }

    /// Constant-time UTF-8 equality for capability tokens (R1.nit).
    /// Length mismatches still walk `max(count)` bytes so comparison time is not
    /// dominated by an early `count` reject alone.
    static func constantTimeEquals(_ lhs: String?, _ rhs: String) -> Bool {
        let left = Array((lhs ?? "").utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var result: UInt8 = left.count == right.count ? 0 : 1
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            result |= l ^ r
        }
        return result == 0
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

    /// Resolve the token path that pairs with a given socket path. The default
    /// service retains `cmd.token`; custom sockets use a socket-namespaced
    /// sidecar so Engram never claims or overwrites a caller-owned `cmd.token`.
    static func path(forSocketPath socketPath: String) -> String {
        let standardized = URL(fileURLWithPath: socketPath).standardizedFileURL.path
        if standardized == URL(
            fileURLWithPath: UnixSocketEngramServiceTransport.defaultSocketPath()
        ).standardizedFileURL.path {
            return URL(fileURLWithPath: standardized)
                .deletingLastPathComponent()
                .appendingPathComponent("cmd.token")
                .path
        }
        return standardized + ".cmd.token"
    }

    /// Generate a fresh random token and write it atomically with mode 0600.
    /// Returns the generated token. Called by the service when it starts.
    @discardableResult
    static func generateAndWrite(toPath path: String) throws -> String {
        let token = makeRandomToken()
        do {
            try SecureRegularFile.writeAtomically(Data(token.utf8), toPath: path)
        } catch {
            // The path is always derived from the service socket and owned by
            // Engram. Recover an unsafe same-user leaf without touching its
            // referent, then publish a fresh single-link token.
            guard SecureRegularFile.removeOwnerNonDirectory(atPath: path) else {
                throw EngramServiceError.serviceUnavailable(message: "Cannot write capability token")
            }
            do {
                try SecureRegularFile.writeAtomically(Data(token.utf8), toPath: path)
            } catch {
                throw EngramServiceError.serviceUnavailable(message: "Cannot write capability token")
            }
        }
        return token
    }

    /// Load the current token written by the service, or nil if unreadable.
    static func load(fromPath path: String) -> String? {
        guard let data = SecureRegularFile.read(atPath: path) else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Remove the socket-adjacent token through a pinned directory descriptor.
    static func remove(atPath path: String) {
        _ = SecureRegularFile.removeOwnerNonDirectory(atPath: path)
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
