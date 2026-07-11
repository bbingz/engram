import Foundation
import CryptoKit
import Hummingbird
import HTTPTypes
import NIOCore
import Logging

/// The self-hosted remote offload server. Exposes a tiny content-addressed blob
/// API under `/v1/bundles/{key}` (HEAD/GET/PUT/DELETE) plus an unauthenticated
/// `/v1/health`. Every bundle route requires a Bearer token (constant-time
/// compared). Bytes are stored encrypted at rest via `BlobStore`.
///
/// Transport security: the server speaks plain HTTP and is intended to run behind
/// a TLS-terminating reverse proxy or on a private/VPN network — the standard
/// self-hosting pattern. The client refuses non-HTTPS, non-loopback URLs.
public final class EngramRemoteServerApp: Sendable {
    private let config: EngramRemoteServerConfig
    private let store: BlobStore
    private let archiveStore: ArchiveStore?

    public init(config: EngramRemoteServerConfig) throws {
        if let archive = config.archiveV2 {
            guard archive.bearerToken != config.bearerToken,
                  !Self.keysEqual(archive.atRestKey, config.atRestKey) else {
                throw EngramRemoteServerConfig.ConfigError.archiveCredentialsMustBeDistinct
            }
            guard Self.storeRootsAreDisjoint(config.storeRoot, archive.root) else {
                throw EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint
            }
        }
        self.config = config
        self.store = try BlobStore(root: config.storeRoot, key: config.atRestKey)
        if let archive = config.archiveV2 {
            self.archiveStore = try ArchiveStore(
                root: archive.root,
                key: archive.atRestKey,
                serverID: archive.serverID
            )
        } else {
            self.archiveStore = nil
        }
    }

    public func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()
        let token = config.bearerToken
        let store = self.store
        let maxBytes = config.maxBundleBytes

        router.get("/v1/health") { _, _ in
            Self.text("ok\n")
        }

        // Aggregate every per-peer manifest blob (key prefix "catalog.") into one
        // JSON document so a client can DISCOVER sessions on the hub without a
        // local ledger row. Manifests are client-authored JSON, sealed at rest
        // like any blob; the server decrypts and concatenates them but never needs
        // the manifest schema. Undecryptable / unparseable manifests are skipped.
        router.get("/v1/catalog") { request, _ in
            guard Self.authorized(request, token: token) else { return Self.unauthorized() }
            var manifests: [Any] = []
            // Manifests are keyed `catalog.<peer>.manifest`; require the suffix too so
            // this selects the same blobs as LocalDirectoryBackend.catalog() (a stray
            // `catalog.*` non-manifest blob is selected by neither producer).
            let keys = ((try? store.listKeys(prefix: "catalog.")) ?? [])
                .filter { $0.hasSuffix(".manifest") }
            for k in keys {
                guard let data = try? store.get(k),
                      let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
                manifests.append(obj)
            }
            let payload: [String: Any] = ["schemaVersion": 1, "manifests": manifests]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
                return Response(status: .internalServerError)
            }
            return Self.json(body)
        }

        router.head("/v1/bundles/:key") { request, context in
            guard Self.authorized(request, token: token) else { return Self.unauthorized() }
            guard let key = context.parameters.get("key") else { return Self.badRequest("missing key") }
            do {
                return Response(status: try store.exists(key) ? .ok : .notFound)
            } catch BlobStoreError.invalidKey {
                return Self.badRequest("invalid key")
            } catch {
                return Response(status: .internalServerError)
            }
        }

        router.get("/v1/bundles/:key") { request, context in
            guard Self.authorized(request, token: token) else { return Self.unauthorized() }
            guard let key = context.parameters.get("key") else { return Self.badRequest("missing key") }
            do {
                let data = try store.get(key)
                return Self.octetStream(data)
            } catch BlobStoreError.notFound {
                return Response(status: .notFound)
            } catch BlobStoreError.invalidKey {
                return Self.badRequest("invalid key")
            } catch {
                // Decrypt/auth-tag failure or I/O error.
                return Response(status: .internalServerError)
            }
        }

        router.put("/v1/bundles/:key") { request, context in
            guard Self.authorized(request, token: token) else { return Self.unauthorized() }
            guard let key = context.parameters.get("key") else { return Self.badRequest("missing key") }
            var request = request
            let buffer: ByteBuffer
            do {
                buffer = try await request.collectBody(upTo: maxBytes)
            } catch {
                return Response(status: .init(code: 413, reasonPhrase: "Payload Too Large"))
            }
            let data = Data(buffer.readableBytesView)
            do {
                try store.put(key, plaintext: data)
                return Response(status: .created)
            } catch BlobStoreError.invalidKey {
                return Self.badRequest("invalid key")
            } catch {
                return Response(status: .internalServerError)
            }
        }

        router.delete("/v1/bundles/:key") { request, context in
            guard Self.authorized(request, token: token) else { return Self.unauthorized() }
            guard let key = context.parameters.get("key") else { return Self.badRequest("missing key") }
            do {
                try store.delete(key)
                return Response(status: .noContent)
            } catch BlobStoreError.invalidKey {
                return Self.badRequest("invalid key")
            } catch {
                return Response(status: .internalServerError)
            }
        }

        if let archive = config.archiveV2, let archiveStore {
            ArchiveRoutes.mount(
                on: router,
                store: archiveStore,
                token: archive.bearerToken
            )
        }

        return router
    }

    /// Run until cancelled. `onBound` reports the actual listening port (useful
    /// when binding to port 0 in tests).
    public func run(onBound: (@Sendable (Int) -> Void)? = nil) async throws {
        var logger = Logger(label: "engram.remote")
        logger.logLevel = .notice
        let app = Application(
            router: buildRouter(),
            configuration: ApplicationConfiguration(address: .hostname(config.host, port: config.port)),
            onServerRunning: { channel in
                if let port = channel.localAddress?.port { onBound?(port) }
            },
            logger: logger
        )
        try await app.run()
    }

    // MARK: - Auth

    static func authorized(_ request: Request, token: String) -> Bool {
        guard let header = request.headers[.authorization] else { return false }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return false }
        return constantTimeEquals(String(header.dropFirst(prefix.count)), token)
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        // Compare fixed-length SHA-256 digests so neither the length check nor the
        // byte loop leaks the secret's length through timing.
        let a = SHA256.hash(data: Data(lhs.utf8))
        let b = SHA256.hash(data: Data(rhs.utf8))
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    private static func keysEqual(_ lhs: SymmetricKey, _ rhs: SymmetricKey) -> Bool {
        let lhsBytes = lhs.withUnsafeBytes { Data($0) }
        let rhsBytes = rhs.withUnsafeBytes { Data($0) }
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for (left, right) in zip(lhsBytes, rhsBytes) {
            diff |= left ^ right
        }
        return diff == 0
    }

    private static func storeRootsAreDisjoint(_ lhs: URL, _ rhs: URL) -> Bool {
        let standardizedLHS = lhs.standardizedFileURL
        let standardizedRHS = rhs.standardizedFileURL
        let standardizedComparisonIsCaseSensitive = comparisonIsCaseSensitive(
            standardizedLHS,
            standardizedRHS
        )
        guard !pathsOverlap(
            standardizedLHS,
            standardizedRHS,
            caseSensitive: standardizedComparisonIsCaseSensitive
        ) else { return false }

        let resolvedLHS = standardizedLHS.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRHS = standardizedRHS.resolvingSymlinksInPath().standardizedFileURL
        let resolvedComparisonIsCaseSensitive = comparisonIsCaseSensitive(
            resolvedLHS,
            resolvedRHS
        )
        return !pathsOverlap(
            resolvedLHS,
            resolvedRHS,
            caseSensitive: resolvedComparisonIsCaseSensitive
        )
    }

    private static func pathsOverlap(
        _ lhs: URL,
        _ rhs: URL,
        caseSensitive: Bool
    ) -> Bool {
        let lhsComponents = comparablePathComponents(lhs, caseSensitive: caseSensitive)
        let rhsComponents = comparablePathComponents(rhs, caseSensitive: caseSensitive)
        if lhsComponents.count <= rhsComponents.count {
            return Array(rhsComponents.prefix(lhsComponents.count)) == lhsComponents
        }
        return Array(lhsComponents.prefix(rhsComponents.count)) == rhsComponents
    }

    private static func comparablePathComponents(
        _ url: URL,
        caseSensitive: Bool
    ) -> [String] {
        url.pathComponents.map { component in
            let canonical = component.precomposedStringWithCanonicalMapping
            guard !caseSensitive else { return canonical }
            return canonical.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }

    private static func comparisonIsCaseSensitive(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsIsCaseSensitive = volumeSupportsCaseSensitiveNames(at: lhs),
              let rhsIsCaseSensitive = volumeSupportsCaseSensitiveNames(at: rhs) else {
            return false
        }
        return lhsIsCaseSensitive && rhsIsCaseSensitive
    }

    private static func volumeSupportsCaseSensitiveNames(at url: URL) -> Bool? {
        var candidate = url.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: candidate.path),
               let values = try? candidate.resourceValues(
                   forKeys: [.volumeSupportsCaseSensitiveNamesKey]
               ), let supportsCaseSensitiveNames = values.volumeSupportsCaseSensitiveNames {
                return supportsCaseSensitiveNames
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    // MARK: - Responses

    static func unauthorized() -> Response {
        var headers = HTTPFields()
        headers[.wwwAuthenticate] = "Bearer"
        return Response(status: .unauthorized, headers: headers)
    }

    static func badRequest(_ message: String) -> Response {
        text("400 Bad Request: \(message)\n", status: .badRequest)
    }

    static func text(_ body: String, status: HTTPResponse.Status = .ok) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=utf-8"
        let data = Data(body.utf8)
        headers[.contentLength] = "\(data.count)"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
    }

    static func octetStream(_ data: Data) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/octet-stream"
        headers[.contentLength] = "\(data.count)"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
    }

    static func json(_ data: Data) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.contentLength] = "\(data.count)"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
    }
}
