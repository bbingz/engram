import Foundation
import CryptoKit

/// Configuration for the self-hosted remote offload server. All values come from
/// the environment (Linux/headless friendly); secrets are NEVER read from a
/// world-readable settings file. The server holds the at-rest key (the owner's
/// locked decision: server-held key, not zero-knowledge).
public struct EngramRemoteServerConfig: Sendable {
    public var host: String
    public var port: Int
    public var storeRoot: URL
    public var bearerToken: String
    public var atRestKey: SymmetricKey
    public var maxBundleBytes: Int

    public init(
        host: String,
        port: Int,
        storeRoot: URL,
        bearerToken: String,
        atRestKey: SymmetricKey,
        maxBundleBytes: Int = 64 * 1024 * 1024
    ) {
        self.host = host
        self.port = port
        self.storeRoot = storeRoot
        self.bearerToken = bearerToken
        self.atRestKey = atRestKey
        self.maxBundleBytes = maxBundleBytes
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case missingToken
        case missingKey
        case badKey

        public var description: String {
            switch self {
            case .missingToken:
                return "ENGRAM_REMOTE_TOKEN is required (the bearer token clients must present)."
            case .missingKey:
                return "ENGRAM_REMOTE_AT_REST_KEY is required (base64 of 32 random bytes). Generate one with: EngramRemoteServer keygen"
            case .badKey:
                return "ENGRAM_REMOTE_AT_REST_KEY must be base64 of exactly 32 bytes."
            }
        }
    }

    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> EngramRemoteServerConfig {
        guard let token = env["ENGRAM_REMOTE_TOKEN"], !token.isEmpty else { throw ConfigError.missingToken }
        guard let keyB64 = env["ENGRAM_REMOTE_AT_REST_KEY"], !keyB64.isEmpty else { throw ConfigError.missingKey }
        guard let keyData = Data(base64Encoded: keyB64), keyData.count == 32 else { throw ConfigError.badKey }

        let store = env["ENGRAM_REMOTE_STORE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".engram-remote", isDirectory: true)
                .appendingPathComponent("store", isDirectory: true)
        // Default bind is loopback: production deployments terminate TLS at a
        // reverse proxy / run on a private network and forward to localhost.
        let host = env["ENGRAM_REMOTE_HOST"] ?? "127.0.0.1"
        let port = env["ENGRAM_REMOTE_PORT"].flatMap(Int.init) ?? 8787

        return EngramRemoteServerConfig(
            host: host,
            port: port,
            storeRoot: store,
            bearerToken: token,
            atRestKey: SymmetricKey(data: keyData)
        )
    }

    /// Generate a fresh base64 at-rest key for first-time setup.
    public static func generateAtRestKeyBase64() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data(Array($0)).base64EncodedString() }
    }
}
