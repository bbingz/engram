import Darwin
import EngramCoreRead
import Foundation

public protocol ArchiveReplicaBackend: Sendable {
    var replicaID: String { get }
    func headObject(digest: String) async throws -> Bool
    func putObject(digest: String, data: Data) async throws
    func getObject(digest: String) async throws -> Data
    func headManifest(digest: String) async throws -> Bool
    func putManifest(digest: String, data: Data) async throws
    func getManifest(digest: String) async throws -> Data
    func createReceipt(manifestDigest: String) async throws -> Data
    func getReceipt(manifestDigest: String) async throws -> Data
    func listMachines(cursor: String?, limit: Int) async throws -> ArchiveMachinePage
    func listReceipts(
        machineID: String,
        cursor: String?,
        limit: Int
    ) async throws -> ArchiveReceiptPage
}

public enum ArchiveReplicaConfigurationError: Error, Equatable, Sendable {
    case invalidReplicaSet
    case invalidOrigin
    case duplicateOrigin
    case missingToken(replicaID: String)
    case emptyToken(replicaID: String)
    case duplicateToken
    case credentialFailure
}

public struct ArchiveReplicaDescriptor: Equatable, Sendable {
    public let id: String
    public let serverURL: String
    public let requireTLS: Bool

    public init(id: String, serverURL: String, requireTLS: Bool) {
        self.id = id
        self.serverURL = serverURL
        self.requireTLS = requireTLS
    }
}

public protocol ArchiveReplicaTokenLoading: Sendable {
    func loadToken(replicaID: String) throws -> String?
}

public struct ArchiveReplicaConnection: Sendable {
    public let replicaID: String
    public let canonicalOrigin: URL
    public let requireTLS: Bool
    let token: String
}

public struct ArchiveReplicaSet: Sendable {
    public let connections: [ArchiveReplicaConnection]

    public init(
        descriptors: [ArchiveReplicaDescriptor],
        tokenLoader: any ArchiveReplicaTokenLoading
    ) throws {
        try self.init(
            descriptors: descriptors,
            tokenLoader: tokenLoader,
            allowLoopbackForTests: false
        )
    }

    init(
        descriptors: [ArchiveReplicaDescriptor],
        tokenLoader: any ArchiveReplicaTokenLoading,
        allowLoopbackForTests: Bool = false
    ) throws {
        guard descriptors.count == 2,
              Set(descriptors.map(\.id)) == Set(["hq", "m1"]) else {
            throw ArchiveReplicaConfigurationError.invalidReplicaSet
        }

        var resolved: [ArchiveReplicaConnection] = []
        for descriptor in descriptors.sorted(by: { $0.id < $1.id }) {
            let origin = try ArchiveReplicaOrigin.canonicalURL(
                descriptor.serverURL,
                requireTLS: descriptor.requireTLS,
                allowLoopbackForTests: allowLoopbackForTests
            )
            let loadedToken: String?
            do {
                loadedToken = try tokenLoader.loadToken(replicaID: descriptor.id)
            } catch {
                throw ArchiveReplicaConfigurationError.credentialFailure
            }
            guard let token = loadedToken else {
                throw ArchiveReplicaConfigurationError.missingToken(
                    replicaID: descriptor.id
                )
            }
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArchiveReplicaConfigurationError.emptyToken(replicaID: descriptor.id)
            }
            resolved.append(
                ArchiveReplicaConnection(
                    replicaID: descriptor.id,
                    canonicalOrigin: origin,
                    requireTLS: descriptor.requireTLS,
                    token: token
                )
            )
        }

        guard Set(resolved.map { $0.canonicalOrigin.absoluteString }).count == 2 else {
            throw ArchiveReplicaConfigurationError.duplicateOrigin
        }
        guard Set(resolved.map(\.token)).count == 2 else {
            throw ArchiveReplicaConfigurationError.duplicateToken
        }
        connections = resolved
    }
}

public enum ArchiveReplicaOrigin {
    public static func canonicalURL(
        _ rawValue: String,
        requireTLS: Bool
    ) throws -> URL {
        try canonicalURL(
            rawValue,
            requireTLS: requireTLS,
            allowLoopbackForTests: false
        )
    }

    static func canonicalURL(
        _ rawValue: String,
        requireTLS: Bool,
        allowLoopbackForTests: Bool = false
    ) throws -> URL {
        guard !rawValue.isEmpty,
              rawValue.unicodeScalars.allSatisfy({ $0.value < 128 }),
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.contains("%"),
              let parsed = URLComponents(string: rawValue),
              let rawScheme = parsed.scheme,
              let parsedHost = parsed.host,
              parsed.user == nil,
              parsed.password == nil,
              parsed.query == nil,
              parsed.fragment == nil,
              parsed.percentEncodedPath.isEmpty || parsed.percentEncodedPath == "/" else {
            throw ArchiveReplicaConfigurationError.invalidOrigin
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw ArchiveReplicaConfigurationError.invalidOrigin
        }
        if let port = parsed.port, !(1...65_535).contains(port) {
            throw ArchiveReplicaConfigurationError.invalidOrigin
        }

        let unbracketedHost: String
        if parsedHost.hasPrefix("[") && parsedHost.hasSuffix("]") {
            unbracketedHost = String(parsedHost.dropFirst().dropLast())
        } else {
            unbracketedHost = parsedHost
        }
        let host = unbracketedHost.lowercased()
        guard !host.isEmpty, host != "0.0.0.0", host != "::" else {
            throw ArchiveReplicaConfigurationError.invalidOrigin
        }

        let canonicalHost: String
        let canonicalHostIsIPv6: Bool
        if let ipv4 = parseIPv4(host) {
            let isTailscale = ipv4.bytes[0] == 100 && (64...127).contains(ipv4.bytes[1])
            let isLoopback = ipv4.canonical == "127.0.0.1"
            guard isTailscale || (allowLoopbackForTests && isLoopback) else {
                throw ArchiveReplicaConfigurationError.invalidOrigin
            }
            canonicalHost = ipv4.canonical
            canonicalHostIsIPv6 = false
        } else if let ipv6 = parseIPv6(host) {
            let isTailscale = ipv6.bytes.prefix(6).elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
            let isLoopback = ipv6.bytes.dropLast().allSatisfy { $0 == 0 }
                && ipv6.bytes.last == 1
            guard isTailscale || (allowLoopbackForTests && isLoopback) else {
                throw ArchiveReplicaConfigurationError.invalidOrigin
            }
            canonicalHost = ipv6.canonical
            canonicalHostIsIPv6 = true
        } else {
            guard isStrictTailnetHostname(host), scheme == "https" else {
                throw ArchiveReplicaConfigurationError.invalidOrigin
            }
            canonicalHost = host
            canonicalHostIsIPv6 = false
        }

        if requireTLS && scheme != "https" {
            throw ArchiveReplicaConfigurationError.invalidOrigin
        }
        if scheme == "http",
           parseIPv4(canonicalHost) == nil,
           parseIPv6(canonicalHost) == nil {
            throw ArchiveReplicaConfigurationError.invalidOrigin
        }

        var canonical = URLComponents()
        canonical.scheme = scheme
        canonical.host = canonicalHostIsIPv6 ? "[\(canonicalHost)]" : canonicalHost
        if let port = parsed.port,
           !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            canonical.port = port
        }
        guard let url = canonical.url else {
            throw ArchiveReplicaConfigurationError.invalidOrigin
        }
        return url
    }

    private static func isStrictTailnetHostname(_ host: String) -> Bool {
        guard host.utf8.count <= 253,
              host.hasSuffix(".ts.net"),
              !host.hasSuffix("."),
              !host.contains("*") else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  !label.lowercased().hasPrefix("xn--"),
                  let first = label.utf8.first,
                  let last = label.utf8.last,
                  isASCIIAlphaNumeric(first),
                  isASCIIAlphaNumeric(last) else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                isASCIIAlphaNumeric(byte) || byte == 45
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }

    private static func parseIPv4(_ value: String) -> (canonical: String, bytes: [UInt8])? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = withUnsafePointer(to: &address) { pointer in
            inet_ntop(AF_INET, UnsafeRawPointer(pointer), &output, socklen_t(output.count))
        }
        guard converted != nil else { return nil }
        return (String(cString: output), withUnsafeBytes(of: address) { Array($0) })
    }

    private static func parseIPv6(_ value: String) -> (canonical: String, bytes: [UInt8])? {
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let converted = withUnsafePointer(to: &address) { pointer in
            inet_ntop(AF_INET6, UnsafeRawPointer(pointer), &output, socklen_t(output.count))
        }
        guard converted != nil else { return nil }
        return (String(cString: output), withUnsafeBytes(of: address) { Array($0) })
    }
}

public enum ArchiveResponseLimitKind: Equatable, Sendable {
    case object
    case manifest
    case receipt
    case page
    case error
}

public enum ArchiveTransportFailure: Equatable, Sendable {
    case cancelled
    case timedOut
    case tls
    case network
}

public enum ArchiveReplicaBackendError: Error, Equatable, Sendable {
    case invalidDigest
    case invalidRequest
    case notHTTPResponse
    case unexpectedStatus(Int)
    case responseTooLarge(ArchiveResponseLimitKind)
    case redirectRejected
    case finalURLMismatch
    case invalidCanonicalResponse
    case transport(ArchiveTransportFailure)
}
