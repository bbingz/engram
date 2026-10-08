import CryptoKit
import Darwin
import Foundation

/// An explicitly enabled Web viewer, separate from every server bearer credential.
public struct EngramRemoteWebConfig: Sendable {
    /// Where a Web session's viewer/editor authority comes from
    /// (docs/superpowers/specs/2026-10-08-web-tailscale-identity-auth-design.md).
    public enum AuthMode: Sendable, Equatable {
        /// Shared viewer/editor credentials, kept only as SHA-256 digests.
        case credential(viewerDigest: Data, editorDigest: Data?)
        /// The exact `Tailscale-User-Login` the local Tailscale Serve proxy asserts,
        /// matched against explicit allowlists. Editors read implicitly.
        case tailscaleServe(viewers: Set<String>, editors: Set<String>)
    }

    public let origin: String
    public let authority: String
    let mode: AuthMode
    let cookieName: String
    let isSecure: Bool

    var credentialDigest: Data? {
        if case let .credential(viewerDigest, _) = mode { return viewerDigest }
        return nil
    }

    var editorCredentialDigest: Data? {
        if case let .credential(_, editorDigest) = mode { return editorDigest }
        return nil
    }

    var usesTailscaleServeIdentity: Bool {
        if case .tailscaleServe = mode { return true }
        return false
    }

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case invalidEnabled
        case missingOrigin
        case invalidOrigin
        case missingCredential
        case credentialMustBeDistinct
        case invalidEditorCredential
        case invalidAuthMode
        case credentialNotAllowedWithIdentity
        case missingIdentityViewers
        case invalidIdentityLogin
        case identityRequiresLoopbackBind

        public var description: String {
            switch self {
            case .invalidEnabled: "ENGRAM_REMOTE_WEB_ENABLED must be 0 or 1."
            case .missingOrigin: "Web requires an explicit HTTPS origin."
            case .invalidOrigin: "Web origin must be a canonical HTTPS origin."
            case .missingCredential: "Web requires a dedicated viewer credential."
            case .credentialMustBeDistinct: "Web viewer and server bearer credentials must be distinct."
            case .invalidEditorCredential: "Web editor requires a nonempty credential distinct from viewer and server credentials."
            case .invalidAuthMode: "ENGRAM_REMOTE_WEB_AUTH must be credential or tailscale-serve."
            case .credentialNotAllowedWithIdentity:
                "ENGRAM_REMOTE_WEB_AUTH=tailscale-serve forbids ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL and ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL."
            case .missingIdentityViewers: "ENGRAM_REMOTE_WEB_AUTH=tailscale-serve requires a nonempty ENGRAM_REMOTE_WEB_VIEWERS list."
            case .invalidIdentityLogin:
                "Web identity allowlists are comma-separated exact Tailscale logins: nonempty printable ASCII without whitespace, quotes or backslashes, at most 254 bytes, no duplicates."
            case .identityRequiresLoopbackBind: "ENGRAM_REMOTE_WEB_AUTH=tailscale-serve requires ENGRAM_REMOTE_HOST to be a loopback address."
            }
        }
    }

    public init(origin: String, viewerCredential: String, serverBearerCredentials: [String], editorCredential: String? = nil) throws {
        try self.init(
            origin: origin, viewerCredential: viewerCredential,
            serverBearerCredentials: serverBearerCredentials, editorCredential: editorCredential, loopbackHTTPForTesting: false
        )
    }

    private init(
        origin: String,
        viewerCredential: String,
        serverBearerCredentials: [String],
        editorCredential: String?,
        loopbackHTTPForTesting: Bool
    ) throws {
        guard !origin.isEmpty else { throw ConfigError.missingOrigin }
        guard !viewerCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigError.missingCredential
        }
        guard serverBearerCredentials.allSatisfy({ $0 != viewerCredential }) else {
            throw ConfigError.credentialMustBeDistinct
        }
        if let editorCredential {
            guard !editorCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  editorCredential != viewerCredential,
                  !serverBearerCredentials.contains(editorCredential) else { throw ConfigError.invalidEditorCredential }
        }
        self.mode = .credential(
            viewerDigest: Data(SHA256.hash(data: Data(viewerCredential.utf8))),
            editorDigest: editorCredential.map { Data(SHA256.hash(data: Data($0.utf8))) }
        )
        self.authority = try Self.canonicalAuthority(origin, loopbackHTTPForTesting: loopbackHTTPForTesting)
        self.origin = origin
        self.cookieName = loopbackHTTPForTesting ? "engram_web_test" : "__Host-engram_web"
        self.isSecure = !loopbackHTTPForTesting
    }

    /// Identity mode: no shared credential exists; the local Tailscale Serve proxy
    /// asserts the login and these exact allowlists decide the authority.
    public init(origin: String, tailscaleServeViewers: String, editors: String?) throws {
        let viewers = try Self.parseLoginList(tailscaleServeViewers)
        guard !viewers.isEmpty else { throw ConfigError.missingIdentityViewers }
        let editorLogins = try editors.map(Self.parseLoginList) ?? []
        self.mode = .tailscaleServe(viewers: viewers, editors: editorLogins)
        self.authority = try Self.canonicalAuthority(origin, loopbackHTTPForTesting: false)
        self.origin = origin
        self.cookieName = "__Host-engram_web"
        self.isSecure = true
    }

    public static func fromEnvironment(
        _ environment: [String: String],
        serverBearerCredentials: [String]
    ) throws -> Self? {
        switch environment["ENGRAM_REMOTE_WEB_ENABLED"] {
        case nil, "0": return nil
        case "1": break
        default: throw ConfigError.invalidEnabled
        }
        guard let origin = environment["ENGRAM_REMOTE_WEB_ORIGIN"], !origin.isEmpty else {
            throw ConfigError.missingOrigin
        }
        switch environment["ENGRAM_REMOTE_WEB_AUTH"] {
        case nil, "credential":
            guard let credential = environment["ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL"] else {
                throw ConfigError.missingCredential
            }
            return try Self(origin: origin, viewerCredential: credential, serverBearerCredentials: serverBearerCredentials,
                            editorCredential: environment["ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL"])
        case "tailscale-serve":
            guard environment["ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL"] == nil,
                  environment["ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL"] == nil else {
                throw ConfigError.credentialNotAllowedWithIdentity
            }
            guard let viewers = environment["ENGRAM_REMOTE_WEB_VIEWERS"], !viewers.isEmpty else {
                throw ConfigError.missingIdentityViewers
            }
            return try Self(origin: origin, tailscaleServeViewers: viewers, editors: environment["ENGRAM_REMOTE_WEB_EDITORS"])
        default:
            throw ConfigError.invalidAuthMode
        }
    }

    /// Shared by the allowlists and the request header: exact, printable ASCII,
    /// no whitespace, quotes or backslashes, so a login can be echoed in JSON verbatim.
    static func isWellFormedLogin(_ login: String) -> Bool {
        !login.isEmpty && login.utf8.count <= 254
            && login.utf8.allSatisfy { (33...126).contains($0) && $0 != 34 && $0 != 92 }
    }

    private static func parseLoginList(_ text: String) throws -> Set<String> {
        var logins = Set<String>()
        for entry in text.split(separator: ",", omittingEmptySubsequences: false) {
            let login = String(entry)
            guard Self.isWellFormedLogin(login), logins.insert(login).inserted else {
                throw ConfigError.invalidIdentityLogin
            }
        }
        return logins
    }

    /// Internal test-only escape hatch; no environment flag can enable HTTP.
    static func forLoopbackHTTPTesting(
        origin: String,
        viewerCredential: String,
        serverBearerCredentials: [String]
    ) throws -> Self {
        try Self(
            origin: origin, viewerCredential: viewerCredential,
            serverBearerCredentials: serverBearerCredentials, editorCredential: nil, loopbackHTTPForTesting: true
        )
    }

    /// Reject URL normalization instead of silently accepting an origin a browser
    /// would serialize differently. This parses only an authority, never a URL path.
    private static func canonicalAuthority(_ origin: String, loopbackHTTPForTesting: Bool) throws -> String {
        let prefix = loopbackHTTPForTesting ? "http://" : "https://"
        guard origin.hasPrefix(prefix) else { throw ConfigError.invalidOrigin }
        let authority = String(origin.dropFirst(prefix.count))
        let host: String
        let portText: String?
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else { throw ConfigError.invalidOrigin }
            let address = String(authority[authority.index(after: authority.startIndex)..<closing])
            guard isCanonicalIPv6(address) else { throw ConfigError.invalidOrigin }
            host = "[\(address)]"
            let suffix = String(authority[authority.index(after: closing)...])
            guard suffix.isEmpty || suffix.hasPrefix(":") else { throw ConfigError.invalidOrigin }
            portText = suffix.isEmpty ? nil : String(suffix.dropFirst())
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), isCanonicalDNSOrIPv4(String(parts[0])) else {
                throw ConfigError.invalidOrigin
            }
            host = String(parts[0])
            portText = parts.count == 2 ? String(parts[1]) : nil
        }
        if let portText {
            guard let port = Int(portText), (1...65535).contains(port), String(port) == portText,
                  port != (loopbackHTTPForTesting ? 80 : 443) else { throw ConfigError.invalidOrigin }
        }
        if loopbackHTTPForTesting, host != "127.0.0.1", host != "[::1]" {
            throw ConfigError.invalidOrigin
        }
        return authority
    }

    private static func isCanonicalDNSOrIPv4(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" }),
              let last = labels.last else { return false }
        let endsInNumber = last.utf8.allSatisfy { (48...57).contains($0) }
            || (last.hasPrefix("0x") && last.dropFirst(2).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        guard endsInNumber else { return true }
        // Browsers interpret numeric-ending hosts as IPv4; reject short, octal,
        // hexadecimal and leading-zero spellings rather than treating them as DNS.
        return labels.count == 4 && labels.allSatisfy { part in
            guard let value = UInt8(part) else { return false }
            return String(value) == part
        }
    }

    private static func isCanonicalIPv6(_ host: String) -> Bool {
        guard !host.contains("%"), !host.contains(".") else { return false }
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let converted = withUnsafePointer(to: &address) { pointer in
            buffer.withUnsafeMutableBufferPointer {
                inet_ntop(AF_INET6, pointer, $0.baseAddress, socklen_t($0.count))
            }
        }
        return converted != nil && String(cString: buffer) == host
    }
}
