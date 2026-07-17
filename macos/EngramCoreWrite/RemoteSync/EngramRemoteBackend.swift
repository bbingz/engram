import Foundation

public enum EngramRemoteBackendError: Error, Equatable {
    /// Refused: the bearer token + bundle bytes would travel unencrypted to a host
    /// that is neither loopback nor a trusted private/VPN network. Use an HTTPS URL,
    /// or point at a private/Tailscale host (with `requireTLS` off).
    case insecureURL(String)
    case notHTTPResponse
    case unexpectedStatus(Int)
}

/// `RemoteStorageBackend` that talks to the self-hosted `engram-remote` server
/// over HTTP(S). The bundle bytes travel in the clear over the connection, so the
/// channel must provide confidentiality. Two acceptable channels:
/// - HTTPS (TLS terminated at the server or a reverse proxy), or
/// - plain HTTP over a trusted private network / VPN (LAN, Tailscale `100.64/10`,
///   `.ts.net`, `.local`) — the common self-hosting case, where WireGuard / the
///   LAN already encrypts + authenticates the transport and a separate TLS cert is
///   redundant.
///
/// `requireTLS` (default `true` at this primitive; the product sets it from the
/// `remoteOffloadRequireTLS` setting, which defaults OFF) forces HTTPS for every
/// non-loopback host — the opt-in posture for users who don't trust their network.
/// Plaintext to a PUBLIC host is refused in BOTH modes, so a misconfiguration can't
/// leak the token onto the open internet. At-rest encryption is the server's
/// responsibility (server-held key).
public struct EngramRemoteBackend: RemoteStorageBackend {
    private let baseURL: URL
    private let token: String
    private let timeout: TimeInterval

    public init(baseURL: URL, token: String, requireTLS: Bool = true, timeout: TimeInterval = 60) throws {
        if baseURL.scheme?.lowercased() != "https" {
            let host = baseURL.host ?? ""
            let allowed = Self.isLoopbackHost(host) || (!requireTLS && Self.isPrivateHost(host))
            guard allowed else { throw EngramRemoteBackendError.insecureURL(baseURL.absoluteString) }
        }
        self.baseURL = baseURL
        self.token = token
        self.timeout = timeout
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    /// Hosts on a trusted private network where plaintext HTTP is acceptable when
    /// `requireTLS` is off: RFC1918 / CGNAT(Tailscale `100.64/10`) / link-local
    /// IPv4 literals, plus `.ts.net` (MagicDNS) and `.local` (mDNS) suffixes.
    ///
    /// SEC-H1: bare single-label names are **not** treated as private — DNS may
    /// resolve them to a public address and cleartext would leak the bearer token.
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        guard !h.isEmpty else { return false }
        if h.hasSuffix(".ts.net") || h.hasSuffix(".local") { return true }
        // IPv6 Tailscale ULA prefix fd7a:115c:a1e0::/48 (literal forms only).
        if h.contains(":"),
           h.hasPrefix("fd7a:115c:a1e0") || h.hasPrefix("[fd7a:115c:a1e0") {
            return true
        }
        let octets = h.split(separator: ".").compactMap { UInt8($0) }  // IPv4 literal → 4 in-range octets
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true                 // 10.0.0.0/8
        case (127, _): return true                // 127.0.0.0/8 loopback
        case (169, 254): return true              // 169.254.0.0/16 link-local
        case (172, 16...31): return true          // 172.16.0.0/12
        case (192, 168): return true              // 192.168.0.0/16
        case (100, 64...127): return true         // 100.64.0.0/10 CGNAT / Tailscale
        default: return false
        }
    }

    private func request(_ method: String, key: String) throws -> URLRequest {
        try RemoteStorageKey.validate(key)
        let url = baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("bundles", isDirectory: true)
            .appendingPathComponent(key, isDirectory: false)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func status(_ response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else { throw EngramRemoteBackendError.notHTTPResponse }
        return http.statusCode
    }

    public func head(key: String) async throws -> Bool {
        let (_, response) = try await URLSession.shared.data(for: try request("HEAD", key: key))
        switch try Self.status(response) {
        case 200: return true
        case 404: return false
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    public func put(key: String, data: Data) async throws {
        var req = try request("PUT", key: key)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: req, from: data)
        switch try Self.status(response) {
        case 200, 201, 204: return
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    public func get(key: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: try request("GET", key: key))
        switch try Self.status(response) {
        case 200: return data
        case 404: throw RemoteSyncError.bundleNotFound(key: key)
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    public func delete(key: String) async throws {
        let (_, response) = try await URLSession.shared.data(for: try request("DELETE", key: key))
        switch try Self.status(response) {
        case 200, 204, 404: return
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    /// Fetch the hub catalog (aggregated per-peer manifests) as raw JSON bytes so a
    /// client can discover sessions on the hub without a local ledger row.
    public func catalog() async throws -> Data {
        let url = baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("catalog", isDirectory: false)
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        switch try Self.status(response) {
        case 200: return data
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }
}
