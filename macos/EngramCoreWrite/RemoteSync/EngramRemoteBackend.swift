import Foundation

public enum EngramRemoteBackendError: Error, Equatable {
    /// Refused: the bearer token + bundle bytes would travel unencrypted to a host
    /// that is neither loopback nor a trusted private/VPN network. Use an HTTPS URL,
    /// or point at a private/Tailscale host (with `requireTLS` off).
    case insecureURL(String)
    /// Hostname looked private (`.ts.net` / `.local`) but DNS resolved to a public
    /// address — refuse cleartext so a misconfigured MagicDNS/mDNS path cannot
    /// leak the bearer token onto the open internet.
    case resolvedHostNotPrivate(String)
    case notHTTPResponse
    case unexpectedStatus(Int)
    case redirectRejected
    case finalURLMismatch
    case responseTooLarge(Int)
    case transport(String)
}

struct RemoteOffloadTransportPolicySnapshot: Equatable {
    let cookiesDisabled: Bool
    let cacheDisabled: Bool
    let credentialStorageDisabled: Bool
    let proxyDictionaryEmpty: Bool
    let waitsForConnectivity: Bool
    let usesEphemeralConfiguration: Bool
    let maxBundleBytes: Int
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
/// `remoteOffloadRequireTLS` setting, which also defaults **true** / fail-closed)
/// forces HTTPS for every non-loopback host. Plaintext to a PUBLIC host is refused
/// in BOTH modes, so a misconfiguration can't leak the token onto the open internet.
/// Named private hosts (`.ts.net` / `.local`) additionally require post-DNS
/// resolution to private addresses before cleartext is allowed.
///
/// Transport matches Archive V2 depth: ephemeral `URLSession` (no cookies/cache/
/// credential storage/proxy), redirect rejection, final-URL match, and response
/// size caps. At-rest encryption remains the server's responsibility.
public final class EngramRemoteBackend: RemoteStorageBackend, @unchecked Sendable {
    /// Matches `EngramRemoteServerConfig.maxBundleBytes` default (64 MiB).
    public static let maxBundleBytes = 64 * 1024 * 1024
    public static let maxCatalogBytes = 4 * 1024 * 1024
    public static let maxErrorBytes = 64 * 1024

    private let baseURL: URL
    private let token: String
    private let timeout: TimeInterval
    private let session: URLSession
    private let transportDelegate: RemoteOffloadSessionDelegate
    let transportPolicyForTesting: RemoteOffloadTransportPolicySnapshot

    public convenience init(
        baseURL: URL,
        token: String,
        requireTLS: Bool = true,
        timeout: TimeInterval = 60
    ) throws {
        try self.init(
            baseURL: baseURL,
            token: token,
            requireTLS: requireTLS,
            timeout: timeout,
            testProtocolClasses: []
        )
    }

    init(
        baseURL: URL,
        token: String,
        requireTLS: Bool = true,
        timeout: TimeInterval = 60,
        testProtocolClasses: [AnyClass]
    ) throws {
        try Self.validateURL(baseURL, requireTLS: requireTLS)
        self.baseURL = baseURL
        self.token = token
        self.timeout = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if !testProtocolClasses.isEmpty {
            configuration.protocolClasses = testProtocolClasses
        }

        transportPolicyForTesting = RemoteOffloadTransportPolicySnapshot(
            cookiesDisabled: configuration.httpCookieStorage == nil
                && !configuration.httpShouldSetCookies,
            cacheDisabled: configuration.urlCache == nil,
            credentialStorageDisabled: configuration.urlCredentialStorage == nil,
            proxyDictionaryEmpty: configuration.connectionProxyDictionary?.isEmpty == true,
            waitsForConnectivity: configuration.waitsForConnectivity,
            usesEphemeralConfiguration: true,
            maxBundleBytes: Self.maxBundleBytes
        )

        let transportDelegate = RemoteOffloadSessionDelegate()
        self.transportDelegate = transportDelegate
        session = URLSession(
            configuration: configuration,
            delegate: transportDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - URL policy

    static func validateURL(_ baseURL: URL, requireTLS: Bool) throws {
        if baseURL.scheme?.lowercased() == "https" {
            return
        }
        let host = baseURL.host ?? ""
        let allowed = isLoopbackHost(host) || (!requireTLS && isPrivateHost(host))
        guard allowed else { throw EngramRemoteBackendError.insecureURL(baseURL.absoluteString) }

        // Post-DNS private check: name-based private hosts (`.ts.net` / `.local`)
        // must actually resolve to private/loopback addresses before cleartext.
        // IP literals are already validated by `isPrivateHost`.
        if !requireTLS, isNamedPrivateHost(host), !isLoopbackHost(host) {
            let addresses = resolveHostAddresses(host)
            guard !addresses.isEmpty else {
                throw EngramRemoteBackendError.resolvedHostNotPrivate(host)
            }
            guard addresses.allSatisfy({ isPrivateHost($0) || isLoopbackHost($0) }) else {
                throw EngramRemoteBackendError.resolvedHostNotPrivate(host)
            }
        }
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
        if isNamedPrivateHost(h) { return true }
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

    static func isNamedPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h.hasSuffix(".ts.net") || h.hasSuffix(".local")
    }

    /// Test hook: when set, replaces getaddrinfo for post-DNS private checks.
    public static var resolveAddressesForTesting: ((String) -> [String])?

    /// Resolve A/AAAA for post-DNS private validation. Empty on failure.
    static func resolveHostAddresses(_ host: String) -> [String] {
        if let override = resolveAddressesForTesting {
            return override(host)
        }
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let info = ptr {
            if let sockaddr = info.pointee.ai_addr {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    sockaddr,
                    socklen_t(info.pointee.ai_addrlen),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let address = String(cString: hostBuffer)
                    if !address.isEmpty {
                        addresses.append(address)
                    }
                }
            }
            ptr = info.pointee.ai_next
        }
        return addresses
    }

    // MARK: - Requests

    private func request(_ method: String, key: String) throws -> URLRequest {
        try RemoteStorageKey.validate(key)
        let url = baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("bundles", isDirectory: true)
            .appendingPathComponent(key, isDirectory: false)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func catalogRequest() -> URLRequest {
        let url = baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("catalog", isDirectory: false)
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func execute(
        _ request: URLRequest,
        successLimit: Int
    ) async throws -> (status: Int, data: Data) {
        let task = session.dataTask(with: request)
        let response: RemoteOffloadHTTPResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transportDelegate.register(
                    task: task,
                    expectedURL: request.url,
                    method: request.httpMethod,
                    successLimit: successLimit,
                    continuation: continuation
                )
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (response.statusCode, response.data)
    }

    // MARK: - RemoteStorageBackend

    public func head(key: String) async throws -> Bool {
        let result = try await execute(try request("HEAD", key: key), successLimit: Self.maxErrorBytes)
        switch result.status {
        case 200: return true
        case 404: return false
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    public func put(key: String, data: Data) async throws {
        var req = try request("PUT", key: key)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // Use dataTask with httpBody so the shared redirect/size delegate applies
        // uniformly (uploadTask would need a parallel registration path).
        req.httpBody = data
        let result = try await execute(req, successLimit: Self.maxErrorBytes)
        switch result.status {
        case 200, 201, 204: return
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    public func get(key: String) async throws -> Data {
        let result = try await execute(try request("GET", key: key), successLimit: Self.maxBundleBytes)
        switch result.status {
        case 200: return result.data
        case 404: throw RemoteSyncError.bundleNotFound(key: key)
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    public func delete(key: String) async throws {
        let result = try await execute(try request("DELETE", key: key), successLimit: Self.maxErrorBytes)
        switch result.status {
        case 200, 204, 404: return
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }

    /// Fetch the hub catalog (aggregated per-peer manifests) as raw JSON bytes so a
    /// client can discover sessions on the hub without a local ledger row.
    public func catalog() async throws -> Data {
        let result = try await execute(catalogRequest(), successLimit: Self.maxCatalogBytes)
        switch result.status {
        case 200: return result.data
        case let code: throw EngramRemoteBackendError.unexpectedStatus(code)
        }
    }
}

// MARK: - Bounded session delegate (Archive V2 parity)

private struct RemoteOffloadHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

private final class RemoteOffloadPendingRequest: @unchecked Sendable {
    let expectedURL: String
    let method: String
    let successLimit: Int
    let continuation: CheckedContinuation<RemoteOffloadHTTPResponse, Error>
    var response: HTTPURLResponse?
    var data = Data()
    var failure: EngramRemoteBackendError?
    var redirectRejected = false

    init(
        expectedURL: URL?,
        method: String?,
        successLimit: Int,
        continuation: CheckedContinuation<RemoteOffloadHTTPResponse, Error>
    ) {
        self.expectedURL = expectedURL?.absoluteString ?? ""
        self.method = method ?? ""
        self.successLimit = successLimit
        self.continuation = continuation
    }
}

private final class RemoteOffloadSessionDelegate: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private let lock = NSLock()
    private var pending: [Int: RemoteOffloadPendingRequest] = [:]

    func register(
        task: URLSessionDataTask,
        expectedURL: URL?,
        method: String?,
        successLimit: Int,
        continuation: CheckedContinuation<RemoteOffloadHTTPResponse, Error>
    ) {
        lock.lock()
        pending[task.taskIdentifier] = RemoteOffloadPendingRequest(
            expectedURL: expectedURL,
            method: method,
            successLimit: successLimit,
            continuation: continuation
        )
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var shouldCancel = false
        lock.lock()
        if let state = pending[dataTask.taskIdentifier] {
            guard let http = response as? HTTPURLResponse else {
                state.failure = .notHTTPResponse
                shouldCancel = true
                lock.unlock()
                completionHandler(.cancel)
                dataTask.cancel()
                return
            }
            state.response = http
            if http.url?.absoluteString != state.expectedURL {
                state.failure = .finalURLMismatch
                shouldCancel = true
            } else {
                let limit = (200...299).contains(http.statusCode)
                    ? state.successLimit
                    : EngramRemoteBackend.maxErrorBytes
                if state.method != "HEAD",
                   http.expectedContentLength > Int64(limit) {
                    state.failure = .responseTooLarge(limit)
                    shouldCancel = true
                }
            }
        }
        lock.unlock()
        completionHandler(shouldCancel ? .cancel : .allow)
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var shouldCancel = false
        lock.lock()
        if let state = pending[dataTask.taskIdentifier], state.failure == nil {
            let statusCode = state.response?.statusCode ?? 0
            let limit = (200...299).contains(statusCode)
                ? state.successLimit
                : EngramRemoteBackend.maxErrorBytes
            if data.count > limit - state.data.count {
                state.failure = .responseTooLarge(limit)
                shouldCancel = true
            } else {
                state.data.append(data)
            }
        }
        lock.unlock()
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        pending[task.taskIdentifier]?.redirectRejected = true
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }

        if let failure = state.failure {
            state.continuation.resume(throwing: failure)
            return
        }
        if state.redirectRejected {
            state.continuation.resume(throwing: EngramRemoteBackendError.redirectRejected)
            return
        }
        if let error {
            if (error as? URLError)?.code == .cancelled,
               state.failure != nil {
                // already handled
            }
            state.continuation.resume(
                throwing: EngramRemoteBackendError.transport(String(describing: error))
            )
            return
        }
        guard let response = state.response else {
            state.continuation.resume(throwing: EngramRemoteBackendError.notHTTPResponse)
            return
        }
        state.continuation.resume(
            returning: RemoteOffloadHTTPResponse(statusCode: response.statusCode, data: state.data)
        )
    }
}
