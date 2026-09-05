import CryptoKit
import Darwin
import Foundation

public struct EngramRemoteArchiveConfig: Sendable {
    public let serverID: String
    public let root: URL
    public let bearerToken: String
    public let atRestKey: SymmetricKey
    public let publicationsEnabled: Bool

    public init(
        serverID: String,
        root: URL,
        bearerToken: String,
        atRestKey: SymmetricKey,
        publicationsEnabled: Bool = false
    ) {
        self.serverID = serverID
        self.root = root
        self.bearerToken = bearerToken
        self.atRestKey = atRestKey
        self.publicationsEnabled = publicationsEnabled
    }
}

/// Configuration for the read-only MCP endpoint served over Streamable HTTP.
/// The endpoint exposes archive v2 data, so it can only be enabled alongside
/// archive v2 and carries its own bearer token, distinct from both existing
/// credentials.
public struct EngramRemoteMCPConfig: Sendable {
    public let bearerToken: String

    public init(bearerToken: String) {
        self.bearerToken = bearerToken
    }
}

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
    public var archiveV2: EngramRemoteArchiveConfig?
    public var mcp: EngramRemoteMCPConfig?
    public let sourceRevision: String

    public init(
        host: String,
        port: Int,
        storeRoot: URL,
        bearerToken: String,
        atRestKey: SymmetricKey,
        maxBundleBytes: Int = 64 * 1024 * 1024,
        archiveV2: EngramRemoteArchiveConfig? = nil,
        mcp: EngramRemoteMCPConfig? = nil,
        sourceRevision: String = "unknown"
    ) {
        self.host = host
        self.port = port
        self.storeRoot = storeRoot
        self.bearerToken = bearerToken
        self.atRestKey = atRestKey
        self.maxBundleBytes = maxBundleBytes
        self.archiveV2 = archiveV2
        self.mcp = mcp
        self.sourceRevision = Self.validatedSourceRevision(sourceRevision)
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case missingToken
        case missingKey
        case badKey
        case invalidArchiveEnabled
        case invalidCollectorPublicationsEnabled
        case collectorPublicationsRequireArchive
        case missingArchiveServerID
        case invalidArchiveServerID
        case missingArchiveRoot
        case archiveRootMustBeAbsolute
        case archiveBindAddressRejected
        case missingArchiveToken
        case missingArchiveKey
        case badArchiveKey
        case archiveCredentialsMustBeDistinct
        case storeRootsMustBeDisjoint
        case invalidMCPEnabled
        case mcpRequiresArchive
        case missingMCPToken
        case mcpTokenMustBeDistinct

        public var description: String {
            switch self {
            case .missingToken:
                return "ENGRAM_REMOTE_TOKEN is required (the bearer token clients must present)."
            case .missingKey:
                return "ENGRAM_REMOTE_AT_REST_KEY is required (base64 of 32 random bytes). Generate one with: EngramRemoteServer keygen"
            case .badKey:
                return "ENGRAM_REMOTE_AT_REST_KEY must be base64 of exactly 32 bytes."
            case .invalidArchiveEnabled:
                return "ENGRAM_REMOTE_ARCHIVE_ENABLED must be 0 or 1."
            case .invalidCollectorPublicationsEnabled:
                return "ENGRAM_REMOTE_COLLECTOR_PUBLICATIONS_ENABLED must be 0 or 1."
            case .collectorPublicationsRequireArchive:
                return "ENGRAM_REMOTE_COLLECTOR_PUBLICATIONS_ENABLED=1 requires archive v2 to be enabled."
            case .missingArchiveServerID:
                return "ENGRAM_REMOTE_ARCHIVE_SERVER_ID is required when archive v2 is enabled."
            case .invalidArchiveServerID:
                return "ENGRAM_REMOTE_ARCHIVE_SERVER_ID is invalid."
            case .missingArchiveRoot:
                return "ENGRAM_REMOTE_ARCHIVE_ROOT is required when archive v2 is enabled."
            case .archiveRootMustBeAbsolute:
                return "ENGRAM_REMOTE_ARCHIVE_ROOT must be an absolute path."
            case .archiveBindAddressRejected:
                return "Archive v2 requires a literal loopback or Tailscale bind address."
            case .missingArchiveToken:
                return "ENGRAM_REMOTE_ARCHIVE_TOKEN is required when archive v2 is enabled."
            case .missingArchiveKey:
                return "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY is required when archive v2 is enabled (base64 of 32 random bytes)."
            case .badArchiveKey:
                return "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY must be base64 of exactly 32 bytes."
            case .archiveCredentialsMustBeDistinct:
                return "Archive v2 token and at-rest key must be distinct from legacy v1 credentials."
            case .storeRootsMustBeDisjoint:
                return "Legacy v1 and archive v2 store roots must be disjoint."
            case .invalidMCPEnabled:
                return "ENGRAM_REMOTE_MCP_ENABLED must be 0 or 1."
            case .mcpRequiresArchive:
                return "ENGRAM_REMOTE_MCP_ENABLED=1 requires archive v2 to be enabled (the MCP endpoint serves archive data)."
            case .missingMCPToken:
                return "ENGRAM_REMOTE_MCP_TOKEN is required when the MCP endpoint is enabled."
            case .mcpTokenMustBeDistinct:
                return "ENGRAM_REMOTE_MCP_TOKEN must be distinct from the legacy v1 and archive v2 bearer tokens."
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

        let archiveEnabled: Bool
        switch env["ENGRAM_REMOTE_ARCHIVE_ENABLED"] {
        case nil, "0":
            archiveEnabled = false
        case "1":
            archiveEnabled = true
        default:
            throw ConfigError.invalidArchiveEnabled
        }

        let publicationsEnabled: Bool
        switch env["ENGRAM_REMOTE_COLLECTOR_PUBLICATIONS_ENABLED"] {
        case nil, "0":
            publicationsEnabled = false
        case "1":
            publicationsEnabled = true
        default:
            throw ConfigError.invalidCollectorPublicationsEnabled
        }
        guard !publicationsEnabled || archiveEnabled else {
            throw ConfigError.collectorPublicationsRequireArchive
        }

        let archiveV2: EngramRemoteArchiveConfig?
        if archiveEnabled {
            guard let serverID = env["ENGRAM_REMOTE_ARCHIVE_SERVER_ID"],
                  !serverID.isEmpty else {
                throw ConfigError.missingArchiveServerID
            }
            guard Self.isCurrentArchiveServerID(serverID) else {
                throw ConfigError.invalidArchiveServerID
            }
            guard let archiveRootPath = env["ENGRAM_REMOTE_ARCHIVE_ROOT"],
                  !archiveRootPath.isEmpty else {
                throw ConfigError.missingArchiveRoot
            }
            guard archiveRootPath.hasPrefix("/"), !archiveRootPath.utf8.contains(0) else {
                throw ConfigError.archiveRootMustBeAbsolute
            }
            guard Self.isAllowedArchiveBindAddress(host) else {
                throw ConfigError.archiveBindAddressRejected
            }
            guard let archiveToken = env["ENGRAM_REMOTE_ARCHIVE_TOKEN"],
                  !archiveToken.isEmpty else {
                throw ConfigError.missingArchiveToken
            }
            guard let archiveKeyB64 = env["ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY"],
                  !archiveKeyB64.isEmpty else {
                throw ConfigError.missingArchiveKey
            }
            guard let archiveKeyData = Data(base64Encoded: archiveKeyB64),
                  archiveKeyData.count == 32 else {
                throw ConfigError.badArchiveKey
            }
            guard archiveToken != token, archiveKeyData != keyData else {
                throw ConfigError.archiveCredentialsMustBeDistinct
            }
            archiveV2 = EngramRemoteArchiveConfig(
                serverID: serverID,
                root: URL(fileURLWithPath: archiveRootPath, isDirectory: true).standardizedFileURL,
                bearerToken: archiveToken,
                atRestKey: SymmetricKey(data: archiveKeyData),
                publicationsEnabled: publicationsEnabled
            )
        } else {
            archiveV2 = nil
        }

        let mcpEnabled: Bool
        switch env["ENGRAM_REMOTE_MCP_ENABLED"] {
        case nil, "0":
            mcpEnabled = false
        case "1":
            mcpEnabled = true
        default:
            throw ConfigError.invalidMCPEnabled
        }

        let mcp: EngramRemoteMCPConfig?
        if mcpEnabled {
            guard let archiveV2 else {
                throw ConfigError.mcpRequiresArchive
            }
            guard let mcpToken = env["ENGRAM_REMOTE_MCP_TOKEN"], !mcpToken.isEmpty else {
                throw ConfigError.missingMCPToken
            }
            guard mcpToken != token, mcpToken != archiveV2.bearerToken else {
                throw ConfigError.mcpTokenMustBeDistinct
            }
            mcp = EngramRemoteMCPConfig(bearerToken: mcpToken)
        } else {
            mcp = nil
        }

        return EngramRemoteServerConfig(
            host: host,
            port: port,
            storeRoot: store,
            bearerToken: token,
            atRestKey: SymmetricKey(data: keyData),
            archiveV2: archiveV2,
            mcp: mcp,
            sourceRevision: env["ENGRAM_REMOTE_SOURCE_REVISION"] ?? "unknown"
        )
    }

    /// Generate a fresh base64 at-rest key for first-time setup.
    public static func generateAtRestKeyBase64() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data(Array($0)).base64EncodedString() }
    }

    static func isCurrentArchiveServerID(_ value: String) -> Bool {
        value == "hq" || value == "m1"
    }

    private static func validatedSourceRevision(_ value: String) -> String {
        guard value.utf8.count == 40,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            return "unknown"
        }
        return value
    }

    private static func isAllowedArchiveBindAddress(_ host: String) -> Bool {
        guard !host.contains("%") else { return false }

        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            return bytes[0] == 127
                || (bytes[0] == 100 && (64...127).contains(bytes[1]))
        }

        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let tailscalePrefix: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
            return loopback || Array(bytes.prefix(tailscalePrefix.count)) == tailscalePrefix
        }

        return false
    }
}
