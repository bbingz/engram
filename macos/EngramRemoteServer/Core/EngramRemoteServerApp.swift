import CryptoKit
import Darwin
import Foundation
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
    /// Matches the shipped client's catalog response ceiling. The peer bound
    /// independently limits JSON object fan-out for very small manifests.
    static let maximumCatalogBytes = 4 * 1024 * 1024
    static let maximumCatalogPeers = 1_024
    private static let catalogEnvelopeBytes = Data(#"{"schemaVersion":1,"manifests":[]}"#.utf8).count
    static let maximumCatalogManifestBytes = maximumCatalogBytes - catalogEnvelopeBytes

    private let config: EngramRemoteServerConfig
    private let store: BlobStore
    private let archiveStore: ArchiveStore?
    private let archiveTelemetry: ArchiveRemoteTelemetryStore?

    public convenience init(config: EngramRemoteServerConfig) throws {
        try self.init(
            config: config,
            archiveTelemetryNow: { Date() },
            archiveTelemetrySnapshotWriter: { data, url in
                try ArchiveRemoteTelemetryStore.defaultSnapshotWriter(data, url)
            }
        )
    }

    init(
        config: EngramRemoteServerConfig,
        archiveTelemetryNow: @escaping @Sendable () -> Date,
        archiveTelemetrySnapshotWriter: @escaping ArchiveRemoteTelemetryStore.SnapshotWriter
    ) throws {
        if let archive = config.archiveV2 {
            guard EngramRemoteServerConfig.isCurrentArchiveServerID(archive.serverID) else {
                throw EngramRemoteServerConfig.ConfigError.invalidArchiveServerID
            }
            guard archive.bearerToken != config.bearerToken,
                  !Self.keysEqual(archive.atRestKey, config.atRestKey) else {
                throw EngramRemoteServerConfig.ConfigError.archiveCredentialsMustBeDistinct
            }
            guard Self.storeRootsAreDisjoint(config.storeRoot, archive.root) else {
                throw EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint
            }
        }
        if let mcp = config.mcp {
            guard let archive = config.archiveV2 else {
                throw EngramRemoteServerConfig.ConfigError.mcpRequiresArchive
            }
            guard mcp.bearerToken != config.bearerToken,
                  mcp.bearerToken != archive.bearerToken else {
                throw EngramRemoteServerConfig.ConfigError.mcpTokenMustBeDistinct
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
            self.archiveTelemetry = try ArchiveRemoteTelemetryStore(
                archiveRoot: archive.root,
                serverID: archive.serverID,
                sourceRevision: config.sourceRevision,
                now: archiveTelemetryNow,
                snapshotWriter: archiveTelemetrySnapshotWriter
            )
        } else {
            self.archiveStore = nil
            self.archiveTelemetry = nil
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
            var manifests: [[String: Any]] = []
            // Manifests are keyed `catalog.<peer>.manifest`; require the suffix too so
            // this selects the same blobs as LocalDirectoryBackend.catalog() (a stray
            // `catalog.*` non-manifest blob is selected by neither producer).
            let keys: [String]
            do {
                keys = try store.listKeys(
                    prefix: "catalog.",
                    suffix: ".manifest",
                    maximumCount: Self.maximumCatalogPeers
                )
            } catch BlobStoreError.limitExceeded {
                return Self.payloadTooLarge()
            } catch {
                return Response(status: .internalServerError)
            }
            var remainingDecodedBytes = Self.maximumCatalogManifestBytes
            for k in keys {
                let data: Data
                do {
                    data = try store.get(k, maximumPlaintextBytes: Self.maximumCatalogBytes)
                } catch BlobStoreError.limitExceeded {
                    // One legacy/directly-written blob must not starve later
                    // peers. It cannot fit in the bounded response, so skip it
                    // without charging the aggregate catalog budget.
                    continue
                } catch {
                    continue
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                guard data.count <= Self.maximumCatalogManifestBytes else { continue }
                let requiredBytes = data.count + (manifests.isEmpty ? 0 : 1)
                guard requiredBytes <= remainingDecodedBytes else { return Self.payloadTooLarge() }
                remainingDecodedBytes -= requiredBytes
                manifests.append(obj)
            }
            let payload: [String: Any] = ["schemaVersion": 1, "manifests": manifests]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
                return Response(status: .internalServerError)
            }
            guard body.count <= Self.maximumCatalogBytes else {
                return Self.payloadTooLarge()
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
            let uploadLimit = Self.isCatalogManifestKey(key)
                ? min(maxBytes, Self.maximumCatalogManifestBytes)
                : maxBytes
            do {
                buffer = try await request.collectBody(upTo: uploadLimit)
            } catch {
                return Response(status: .init(code: 413, reasonPhrase: "Payload Too Large"))
            }
            let data = Data(buffer.readableBytesView)
            guard !Self.isCatalogManifestKey(key) || data.count <= Self.maximumCatalogManifestBytes else {
                return Self.payloadTooLarge()
            }
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

        if let archive = config.archiveV2, let archiveStore, let archiveTelemetry {
            ArchiveRoutes.mount(
                on: router,
                store: archiveStore,
                token: archive.bearerToken,
                telemetry: archiveTelemetry
            )
        }

        if let mcp = config.mcp, let archiveStore {
            MCPRemoteEndpoint.mount(on: router, store: archiveStore, token: mcp.bearerToken)
        }

        return router
    }

    private static func isCatalogManifestKey(_ key: String) -> Bool {
        key.hasPrefix("catalog.") && key.hasSuffix(".manifest") && !key.contains("..")
    }

    /// Run until cancelled. `onBound` reports the actual listening port (useful
    /// when binding to port 0 in tests).
    public func run(onBound: (@Sendable (Int) -> Void)? = nil) async throws {
        var logger = Logger(label: "engram.remote")
        logger.logLevel = .notice
        // Warm the process-local receipt list index off the accept path so the
        // first archive_list_* / listMachines call is not a multi-second scan.
        // Failures leave the index cold; the next list call rebuilds.
        if let archiveStore {
            let warmLogger = logger
            Task.detached(priority: .utility) {
                do {
                    try archiveStore.warmListIndex()
                    warmLogger.notice("archive list index warm complete")
                } catch {
                    warmLogger.warning(
                        "archive list index warm failed; lists will rebuild on demand",
                        metadata: ["error": "\(error)"]
                    )
                }
            }
        }
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
        guard let standardizedLHS = lexicallyNormalizedRoot(lhs),
              let standardizedRHS = lexicallyNormalizedRoot(rhs) else {
            return false
        }
        let standardizedComparisonIsCaseSensitive = comparisonIsCaseSensitive(
            standardizedLHS,
            standardizedRHS
        )
        guard !pathsOverlap(
            standardizedLHS,
            standardizedRHS,
            caseSensitive: standardizedComparisonIsCaseSensitive
        ) else { return false }

        guard let resolvedLHS = canonicalRootWithoutCreating(standardizedLHS),
              let resolvedRHS = canonicalRootWithoutCreating(standardizedRHS) else {
            return false
        }
        let resolvedComparisonIsCaseSensitive = comparisonIsCaseSensitive(
            resolvedLHS.url,
            resolvedRHS.url
        )
        guard !pathsOverlap(
            resolvedLHS.url,
            resolvedRHS.url,
            caseSensitive: resolvedComparisonIsCaseSensitive
        ) else { return false }
        return !filesystemRootsOverlap(
            resolvedLHS,
            resolvedRHS,
            caseSensitive: resolvedComparisonIsCaseSensitive
        )
    }

    private struct FilesystemIdentity: Hashable {
        let device: UInt64
        let inode: UInt64

        init(_ metadata: stat) {
            self.device = UInt64(truncatingIfNeeded: metadata.st_dev)
            self.inode = UInt64(truncatingIfNeeded: metadata.st_ino)
        }
    }

    private struct ExistingDirectoryNode {
        let identity: FilesystemIdentity
        let component: String?
    }

    private struct CanonicalRootResolution {
        let url: URL
        let existingDirectories: [ExistingDirectoryNode]
        let unresolvedSuffix: [String]
    }

    /// Resolve every existing symlink component while preserving the suffix below
    /// the deepest existing directory. Foundation's whole-path resolver leaves an
    /// existing symlink ancestor unresolved when the final leaf does not exist,
    /// which can make two stores appear disjoint until the first store creates it.
    /// Dangling links, cycles, non-directory components, and inspection failures
    /// are rejected so root validation never creates filesystem state.
    private static func canonicalRootWithoutCreating(_ url: URL) -> CanonicalRootResolution? {
        guard var components = lexicallyNormalizedComponents(url) else { return nil }
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        var index = 0
        var symlinkHops = 0
        var visitedSymlinks = Set<String>()
        var rootMetadata = stat()
        guard resolved.path.withCString({ lstat($0, &rootMetadata) }) == 0,
              rootMetadata.st_mode & S_IFMT == S_IFDIR else {
            return nil
        }
        var existingDirectories = [
            ExistingDirectoryNode(identity: FilesystemIdentity(rootMetadata), component: nil),
        ]

        while index < components.count {
            let component = components[index]
            let candidate = resolved.appendingPathComponent(component, isDirectory: true)
            var metadata = stat()
            let result = candidate.path.withCString { lstat($0, &metadata) }

            if result != 0 {
                guard errno == ENOENT else { return nil }
                let unresolvedSuffix = Array(components[index...])
                for suffix in unresolvedSuffix {
                    resolved.appendPathComponent(suffix, isDirectory: true)
                }
                return CanonicalRootResolution(
                    url: resolved,
                    existingDirectories: existingDirectories,
                    unresolvedSuffix: unresolvedSuffix
                )
            }

            let fileType = metadata.st_mode & S_IFMT
            if fileType == S_IFLNK {
                symlinkHops += 1
                guard symlinkHops <= 40,
                      visitedSymlinks.insert(candidate.path).inserted,
                      let destination = try? FileManager.default.destinationOfSymbolicLink(
                          atPath: candidate.path
                      ) else {
                    return nil
                }

                let destinationURL: URL
                if destination.hasPrefix("/") {
                    destinationURL = URL(fileURLWithPath: destination, isDirectory: true)
                } else {
                    let combinedPath = (resolved.path as NSString)
                        .appendingPathComponent(destination)
                    destinationURL = URL(fileURLWithPath: combinedPath, isDirectory: true)
                }
                guard let destinationComponents = lexicallyNormalizedComponents(destinationURL) else {
                    return nil
                }
                let standardizedDestination = rootURL(components: destinationComponents)

                // A dangling target could become live after BlobStore creates the
                // other root, so it must fail closed instead of being preserved as
                // an unresolved suffix.
                var destinationMetadata = stat()
                let destinationResult = standardizedDestination.path.withCString {
                    stat($0, &destinationMetadata)
                }
                guard destinationResult == 0,
                      destinationMetadata.st_mode & S_IFMT == S_IFDIR else {
                    return nil
                }

                let suffix = Array(components.dropFirst(index + 1))
                components = destinationComponents + suffix
                resolved = URL(fileURLWithPath: "/", isDirectory: true)
                existingDirectories = [
                    ExistingDirectoryNode(identity: FilesystemIdentity(rootMetadata), component: nil),
                ]
                index = 0
                continue
            }

            guard fileType == S_IFDIR else { return nil }
            resolved = candidate
            existingDirectories.append(
                ExistingDirectoryNode(
                    identity: FilesystemIdentity(metadata),
                    component: component
                )
            )
            index += 1
        }

        return CanonicalRootResolution(
            url: resolved,
            existingDirectories: existingDirectories,
            unresolvedSuffix: []
        )
    }

    private static func filesystemRootsOverlap(
        _ lhs: CanonicalRootResolution,
        _ rhs: CanonicalRootResolution,
        caseSensitive: Bool
    ) -> Bool {
        var deepestCommon: (lhs: Int, rhs: Int, score: Int)?
        for lhsIndex in lhs.existingDirectories.indices {
            for rhsIndex in rhs.existingDirectories.indices
                where lhs.existingDirectories[lhsIndex].identity
                    == rhs.existingDirectories[rhsIndex].identity {
                let score = lhsIndex + rhsIndex
                if deepestCommon == nil || score > deepestCommon!.score {
                    deepestCommon = (lhsIndex, rhsIndex, score)
                }
            }
        }
        guard let deepestCommon else { return false }

        let lhsRelative = lhs.existingDirectories.dropFirst(deepestCommon.lhs + 1)
            .compactMap(\.component) + lhs.unresolvedSuffix
        let rhsRelative = rhs.existingDirectories.dropFirst(deepestCommon.rhs + 1)
            .compactMap(\.component) + rhs.unresolvedSuffix
        return componentsOverlap(lhsRelative, rhsRelative, caseSensitive: caseSensitive)
    }

    private static func lexicallyNormalizedRoot(_ url: URL) -> URL? {
        guard let components = lexicallyNormalizedComponents(url) else { return nil }
        return rootURL(components: components)
    }

    private static func lexicallyNormalizedComponents(_ url: URL) -> [String]? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        var result: [String] = []
        for component in url.pathComponents.dropFirst() {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !result.isEmpty else { return nil }
                result.removeLast()
            default:
                result.append(component)
            }
        }
        return result
    }

    private static func rootURL(components: [String]) -> URL {
        let path = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func pathsOverlap(
        _ lhs: URL,
        _ rhs: URL,
        caseSensitive: Bool
    ) -> Bool {
        return componentsOverlap(
            lhs.pathComponents,
            rhs.pathComponents,
            caseSensitive: caseSensitive
        )
    }

    private static func componentsOverlap(
        _ lhs: [String],
        _ rhs: [String],
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
        _ components: [String],
        caseSensitive: Bool
    ) -> [String] {
        components.map { component in
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
        var candidate = url
        while true {
            if FileManager.default.fileExists(atPath: candidate.path),
               let values = try? candidate.resourceValues(
                   forKeys: [.volumeSupportsCaseSensitiveNamesKey]
               ), let supportsCaseSensitiveNames = values.volumeSupportsCaseSensitiveNames {
                return supportsCaseSensitiveNames
            }
            let parent = candidate.deletingLastPathComponent()
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

    static func payloadTooLarge() -> Response {
        Response(status: .init(code: 413, reasonPhrase: "Payload Too Large"))
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

// MARK: - MCP Streamable HTTP endpoint

/// JSON value with insertion-ordered object keys, so MCP responses are emitted
/// deterministically. Deliberately self-contained: this target must stay free
/// of EngramCoreRead/EngramCoreWrite (asserted by
/// `testRemoteServerCoreIncludesOnlyPureArchiveWireSources`), so it cannot
/// share the stdio helper's `OrderedJSONValue`.
indirect enum MCPRemoteWireValue {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([MCPRemoteWireValue])
    case object([(String, MCPRemoteWireValue)])

    func encoded() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .string(let value):
            return Self.quoted(value)
        case .array(let values):
            return "[\(values.map { $0.encoded() }.joined(separator: ","))]"
        case .object(let entries):
            return "{\(entries.map { "\(Self.quoted($0.0)):\($0.1.encoded())" }.joined(separator: ","))}"
        }
    }

    private static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out.append("\\\"")
            case "\\":
                out.append("\\\\")
            case "\n":
                out.append("\\n")
            case "\r":
                out.append("\\r")
            case "\t":
                out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
        return out
    }
}

/// Read-only MCP endpoint over Streamable HTTP, dual-era and stateless in both
/// eras. A request carrying `_meta["io.modelcontextprotocol/protocolVersion"]`
/// is served under MCP revision 2026-07-28 (wrapped results, header
/// validation); a request without it is served under the legacy
/// `initialize`-handshake revisions that shipping HTTP clients still use. No
/// session is ever minted on either path. Serves the archive v2 store — list
/// machines, list captures, read reassembled session transcripts — and is
/// mounted only when `EngramRemoteMCPConfig` is present.
///
/// Documented deviations (see docs/remote-mcp-2026-07-28-design.md):
/// - `DELETE /mcp` stays unrouted (404 instead of the spec's SHOULD 405):
///   the archive v2 safety gate forbids DELETE routes in this target.
/// - `subscriptions/listen` returns -32601: no change notifications are
///   advertised, so there is nothing to opt in to.
enum MCPRemoteEndpoint {
    static let protocolVersion = "2026-07-28"
    /// Legacy (`initialize`-handshake) revisions this endpoint also serves.
    /// Kept because shipping MCP HTTP clients are still legacy-era: Claude Code
    /// 2.1.220 POSTs `initialize` with `protocolVersion: 2025-11-25`, no
    /// per-request `_meta`, and no `Mcp-Method` header. Sessions are a MAY in
    /// those revisions, so the legacy path stays stateless — no
    /// `Mcp-Session-Id` is minted, echoed, or required.
    ///
    /// Narrowed to the two revisions this endpoint can honestly serve over
    /// Streamable HTTP (MCP retro F17/F21, retro PR-4): `2025-03-26` requires
    /// receivers to accept JSON-RPC batches, which this endpoint rejects as
    /// `-32700`, and `2024-11-05` predates Streamable HTTP entirely (it defines
    /// the HTTP+SSE transport, whose GET stream this endpoint refuses). Echoing
    /// either back promised a contract the endpoint does not implement. An
    /// unknown revision still negotiates down instead of failing the
    /// connection, so a client that asks for one is served, not refused. The
    /// stdio helper's version sets are deliberately left broad: it has no batch
    /// or transport contradiction, and local clients on old revisions still use
    /// it.
    static let legacyProtocolVersions: Set<String> = [
        "2025-06-18",
        "2025-11-25",
    ]
    static let latestLegacyProtocolVersion = legacyProtocolVersions.max() ?? "2025-11-25"
    static let serverName = "engram-remote"
    static let serverVersion = "0.1.0"
    static let maxRequestBytes = 1_048_576
    static let maxTranscriptWindowBytes = 1_048_576
    static let defaultTranscriptWindowBytes = 262_144
    static let transcriptRedactionOverlapBytes = 64 * 1_024
    static let maxTranscriptRedactionDecodedBytes =
        maxTranscriptWindowBytes
        + Int(ArchiveSourceManifest.rawChunkSize)
        + 2 * transcriptRedactionOverlapBytes
    static let discoverTTLMs = 3_600_000
    static let toolsListTTLMs = 3_600_000
    static let cacheScope = "private"
    static let instructions = """
    Engram remote archive (read-only). Tools:
    - archive_list_machines: machines that have archived AI sessions here
    - archive_list_captures: captures for one machine (sessionID + manifest digest)
    - archive_get_session: read an archived transcript by manifest digest, \
    windowed by offset/max_bytes
    """

    private static let protocolVersionHeader = HTTPField.Name("MCP-Protocol-Version")!
    private static let mcpMethodHeader = HTTPField.Name("Mcp-Method")!
    private static let mcpNameHeader = HTTPField.Name("Mcp-Name")!
    private static let originHeader = HTTPField.Name("Origin")!
    private static let protocolVersionMetaKey = "io.modelcontextprotocol/protocolVersion"

    static func mount(on router: Router<BasicRequestContext>, store: ArchiveStore, token: String) {
        router.post("/mcp") { request, _ in
            await handle(request: request, store: store, token: token)
        }
        // Pre-2026-07-28 clients may open a standalone GET stream for
        // server-initiated messages. This endpoint never initiates any (no
        // sampling, elicitation, or roots), so refuse the stream; legacy
        // clients treat that as "no server-initiated channel" and continue
        // over POST.
        router.get("/mcp") { request, _ in
            guard EngramRemoteServerApp.authorized(request, token: token) else {
                return EngramRemoteServerApp.unauthorized()
            }
            var headers = HTTPFields()
            headers[HTTPField.Name("Allow")!] = "POST"
            return Response(status: .init(code: 405, reasonPhrase: "Method Not Allowed"), headers: headers)
        }
    }

    private static func handle(request: Request, store: ArchiveStore, token: String) async -> Response {
        guard EngramRemoteServerApp.authorized(request, token: token) else {
            return EngramRemoteServerApp.unauthorized()
        }
        // DNS-rebinding hardening: this endpoint has no browser clients, so any
        // Origin header at all is refused (spec: MUST validate Origin).
        if request.headers[originHeader] != nil {
            return errorResponse(status: .forbidden, id: nil, code: -32600, message: "Origin not allowed")
        }

        var request = request
        let body: Data
        do {
            let buffer = try await request.collectBody(upTo: maxRequestBytes)
            body = Data(buffer.readableBytesView)
        } catch {
            return errorResponse(
                status: .init(code: 413, reasonPhrase: "Payload Too Large"),
                id: nil,
                code: -32600,
                message: "Request body too large"
            )
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: body),
              let message = parsed as? [String: Any] else {
            return errorResponse(status: .badRequest, id: nil, code: -32700, message: "Parse error")
        }
        guard let method = message["method"] as? String else {
            return errorResponse(status: .badRequest, id: nil, code: -32600, message: "Invalid Request: missing method")
        }
        // Notifications are accepted and dropped: the 2026-07-28 core protocol
        // defines no client-to-server notifications over Streamable HTTP.
        guard let id = wireID(of: message["id"]) else {
            return Response(status: .init(code: 202, reasonPhrase: "Accepted"))
        }

        let params = message["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any] ?? [:]

        // Era is decided per request, with no stored connection state: a
        // request carrying `_meta[protocolVersion]` is modern, anything else
        // is served under the legacy handshake semantics that shipping HTTP
        // clients still use.
        guard let rawVersion = meta[protocolVersionMetaKey] else {
            return legacyResponse(method: method, id: id, params: params, store: store)
        }
        // The key is present, so this is a modern-era request whatever its
        // value type. A non-string value names no revision: answer -32022
        // before header validation, which used to mislabel it as a missing
        // body key (MCP retro F16/F22, retro PR-4).
        guard let requestedVersion = rawVersion as? String else {
            return unsupportedProtocolVersion(id: id, requested: invalidVersionDescription(rawVersion))
        }

        if let mismatch = headerMismatch(
            request: request,
            method: method,
            params: params,
            bodyVersion: requestedVersion
        ) {
            return errorResponse(status: .badRequest, id: id, code: -32020, message: mismatch)
        }
        guard requestedVersion == protocolVersion else {
            return unsupportedProtocolVersion(id: id, requested: requestedVersion)
        }

        switch method {
        case "server/discover":
            return resultResponse(id: id, result: discoverResult())
        case "tools/list":
            return resultResponse(id: id, result: toolsListResult())
        case "tools/call":
            guard let name = params["name"] as? String, !name.isEmpty else {
                return errorResponse(status: .badRequest, id: id, code: -32602, message: "Invalid params: missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let body = callTool(name: name, arguments: arguments, store: store)
            return resultResponse(id: id, result: envelope(body))
        default:
            // Includes subscriptions/listen: no notification types are
            // advertised. The spec maps unknown methods to 404 + -32601 so
            // clients can distinguish a modern server from a legacy one.
            return errorResponse(status: .notFound, id: id, code: -32601, message: "Method not found")
        }
    }

    /// The modern-era version rejection. `supported` is the modern set alone:
    /// this fires on the per-request `_meta` channel, through which a legacy
    /// revision can never be selected.
    private static func unsupportedProtocolVersion(
        id: MCPRemoteWireValue,
        requested: String
    ) -> Response {
        errorResponse(
            status: .badRequest,
            id: id,
            code: -32022,
            message: "Unsupported protocol version",
            data: .object([
                ("supported", .array([.string(protocolVersion)])),
                ("requested", .string(requested)),
            ])
        )
    }

    /// Name the JSON type of a `_meta` protocol version that is not a string,
    /// so the -32022 payload describes what arrived rather than an empty
    /// string. Matches `MCPStdioServer.invalidVersionDescription`.
    private static func invalidVersionDescription(_ value: Any) -> String {
        if value is NSNull {
            return "<null>"
        }
        if let number = value as? NSNumber {
            // `is Bool` is unreliable on JSONSerialization output (see
            // `wireID`), so the CoreFoundation type is what separates them.
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "<bool>" : "<number>"
        }
        if value is [Any] {
            return "<array>"
        }
        if value is [String: Any] {
            return "<object>"
        }
        return "<invalid>"
    }

    // MARK: Legacy era (initialize handshake, stateless)

    /// Serve a request that arrived without modern per-request `_meta`.
    /// No session is minted: `Mcp-Session-Id` is never issued or required, so
    /// each POST stands alone exactly as in the modern era. Results carry no
    /// `resultType`/`ttlMs`/`_meta` envelope — legacy clients do not expect it.
    private static func legacyResponse(
        method: String,
        id: MCPRemoteWireValue,
        params: [String: Any],
        store: ArchiveStore
    ) -> Response {
        switch method {
        case "initialize":
            // Echo a supported requested version, else negotiate down to the
            // latest legacy revision rather than failing the connection.
            let requested = params["protocolVersion"] as? String ?? ""
            let negotiated = legacyProtocolVersions.contains(requested)
                ? requested
                : latestLegacyProtocolVersion
            return resultResponse(id: id, result: .object([
                ("protocolVersion", .string(negotiated)),
                ("capabilities", .object([("tools", .object([]))])),
                ("serverInfo", .object([
                    ("name", .string(serverName)),
                    ("version", .string(serverVersion)),
                ])),
                ("instructions", .string(instructions)),
            ]))
        case "ping":
            return resultResponse(id: id, result: .object([]))
        case "tools/list":
            return resultResponse(id: id, result: .object([("tools", .array(toolDefinitions))]))
        case "tools/call":
            guard let name = params["name"] as? String, !name.isEmpty else {
                return errorResponse(status: .badRequest, id: id, code: -32602, message: "Invalid params: missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return resultResponse(
                id: id,
                result: .object(callTool(name: name, arguments: arguments, store: store))
            )
        default:
            // Legacy clients expect an ordinary JSON-RPC error body; the
            // modern era's 404-for-unknown-method rule does not apply here.
            return errorResponse(status: .ok, id: id, code: -32601, message: "Method not found")
        }
    }

    // MARK: Header validation (Streamable HTTP request metadata)

    private static func headerMismatch(
        request: Request,
        method: String,
        params: [String: Any],
        bodyVersion: String
    ) -> String? {
        guard let versionHeader = request.headers[protocolVersionHeader] else {
            return "Header mismatch: MCP-Protocol-Version header is required"
        }
        guard versionHeader == bodyVersion else {
            return "Header mismatch: MCP-Protocol-Version header value '\(versionHeader)' does not match body value '\(bodyVersion)'"
        }
        guard let methodHeader = request.headers[mcpMethodHeader] else {
            return "Header mismatch: Mcp-Method header is required"
        }
        guard methodHeader == method else {
            return "Header mismatch: Mcp-Method header value '\(methodHeader)' does not match body value '\(method)'"
        }
        if method == "tools/call" {
            guard let rawName = request.headers[mcpNameHeader] else {
                return "Header mismatch: Mcp-Name header is required for tools/call"
            }
            guard let decodedName = decodedHeaderValue(rawName) else {
                return "Header mismatch: Mcp-Name header value is not decodable"
            }
            let bodyName = params["name"] as? String ?? ""
            guard decodedName == bodyName else {
                return "Header mismatch: Mcp-Name header value '\(decodedName)' does not match body value '\(bodyName)'"
            }
        }
        return nil
    }

    /// Decode the base64 sentinel form `=?base64?...?=` used when a header
    /// value cannot be carried as plain ASCII. Plain values pass through.
    private static func decodedHeaderValue(_ raw: String) -> String? {
        guard raw.hasPrefix("=?base64?"), raw.hasSuffix("?=") else { return raw }
        let inner = String(raw.dropFirst("=?base64?".count).dropLast("?=".count))
        guard let data = Data(base64Encoded: inner) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Results

    private static var serverInfoMeta: MCPRemoteWireValue {
        .object([
            ("io.modelcontextprotocol/serverInfo", .object([
                ("name", .string(serverName)),
                ("version", .string(serverVersion)),
            ])),
        ])
    }

    /// Wrap a result body in the 2026-07-28 envelope: `resultType` first,
    /// optional CacheableResult fields, server identity in `_meta` last.
    private static func envelope(
        _ body: [(String, MCPRemoteWireValue)],
        ttlMs: Int? = nil
    ) -> MCPRemoteWireValue {
        var entries: [(String, MCPRemoteWireValue)] = [("resultType", .string("complete"))]
        entries.append(contentsOf: body)
        if let ttlMs {
            entries.append(("ttlMs", .int(ttlMs)))
            entries.append(("cacheScope", .string(cacheScope)))
        }
        entries.append(("_meta", serverInfoMeta))
        return .object(entries)
    }

    private static func discoverResult() -> MCPRemoteWireValue {
        envelope(
            [
                ("supportedVersions", .array([.string(protocolVersion)])),
                ("capabilities", .object([("tools", .object([]))])),
                ("instructions", .string(instructions)),
            ],
            ttlMs: discoverTTLMs
        )
    }

    private static func toolsListResult() -> MCPRemoteWireValue {
        envelope([("tools", .array(toolDefinitions))], ttlMs: toolsListTTLMs)
    }

    private static let toolDefinitions: [MCPRemoteWireValue] = [
        toolDefinition(
            name: "archive_list_machines",
            title: "List Archived Machines",
            description: "List machine IDs that have archived AI sessions on this server.",
            properties: [
                ("cursor", .object([("type", .string("string"))])),
                ("limit", .object([
                    ("type", .string("integer")),
                    ("minimum", .int(1)),
                    ("maximum", .int(100)),
                ])),
            ],
            required: []
        ),
        toolDefinition(
            name: "archive_list_captures",
            title: "List Archived Captures",
            description: "List archived session captures for a machine. Each entry carries the sessionID and the manifest digest used by archive_get_session.",
            properties: [
                ("machine_id", .object([("type", .string("string"))])),
                ("cursor", .object([("type", .string("string"))])),
                ("limit", .object([
                    ("type", .string("integer")),
                    ("minimum", .int(1)),
                    ("maximum", .int(100)),
                ])),
            ],
            required: ["machine_id"]
        ),
        toolDefinition(
            name: "archive_get_session",
            title: "Read Archived Session",
            description: "Read an archived session transcript by manifest digest. Returns redacted UTF-8 text, windowed by offset/max_bytes.",
            properties: [
                ("manifest_sha256", .object([("type", .string("string"))])),
                ("offset", .object([
                    ("type", .string("integer")),
                    ("minimum", .int(0)),
                ])),
                ("max_bytes", .object([
                    ("type", .string("integer")),
                    ("minimum", .int(1)),
                    ("maximum", .int(maxTranscriptWindowBytes)),
                ])),
            ],
            required: ["manifest_sha256"]
        ),
    ]

    private static func toolDefinition(
        name: String,
        title: String,
        description: String,
        properties: [(String, MCPRemoteWireValue)],
        required: [String]
    ) -> MCPRemoteWireValue {
        var schema: [(String, MCPRemoteWireValue)] = [
            ("type", .string("object")),
            ("properties", .object(properties)),
        ]
        if !required.isEmpty {
            schema.append(("required", .array(required.map { .string($0) })))
        }
        schema.append(("additionalProperties", .bool(false)))
        return .object([
            ("name", .string(name)),
            ("title", .string(title)),
            ("description", .string(description)),
            ("inputSchema", .object(schema)),
            ("annotations", .object([
                ("title", .string(title)),
                ("readOnlyHint", .bool(true)),
                ("openWorldHint", .bool(false)),
            ])),
        ])
    }

    // MARK: Tool execution

    private static func callTool(
        name: String,
        arguments: [String: Any],
        store: ArchiveStore
    ) -> [(String, MCPRemoteWireValue)] {
        do {
            switch name {
            case "archive_list_machines":
                return try listMachines(arguments: arguments, store: store)
            case "archive_list_captures":
                return try listCaptures(arguments: arguments, store: store)
            case "archive_get_session":
                return try getSession(arguments: arguments, store: store)
            default:
                return toolError("Unknown tool: \(name)", code: "unknownTool")
            }
        } catch let error as MCPRemoteToolError {
            return toolError(error.message, code: error.code)
        } catch let error as ArchiveStoreError {
            let code = error == .notFound ? "notFound" : "archiveStoreError"
            return toolError("Archive store error: \(error)", code: code)
        } catch {
            return toolError("Internal error: \(error.localizedDescription)", code: "internal")
        }
    }

    private struct MCPRemoteToolError: Error {
        let message: String
        let code: String
    }

    private static func listMachines(
        arguments: [String: Any],
        store: ArchiveStore
    ) throws -> [(String, MCPRemoteWireValue)] {
        try validateArgumentKeys(arguments, allowed: ["cursor", "limit"])
        let page = try store.listMachines(
            cursor: try stringArgument(arguments, "cursor"),
            limit: try limitArgument(arguments)
        )
        var body: [(String, MCPRemoteWireValue)] = [
            ("machines", .array(page.machineIDs.map { .string($0) })),
        ]
        if let next = page.nextCursor {
            body.append(("nextCursor", .string(next)))
        }
        return toolSuccess(body)
    }

    private static func listCaptures(
        arguments: [String: Any],
        store: ArchiveStore
    ) throws -> [(String, MCPRemoteWireValue)] {
        try validateArgumentKeys(arguments, allowed: ["machine_id", "cursor", "limit"])
        guard let machineID = try stringArgument(arguments, "machine_id"), !machineID.isEmpty else {
            throw MCPRemoteToolError(message: "machine_id is required", code: "invalidArguments")
        }
        // Every field comes from the process-local index, captured when the
        // receipt was scanned or published (retro PR-3, F07). The page used to
        // call the durable `getReceipt` once per entry — two fsyncs plus a
        // manifest cross-check each — which re-added the per-receipt cost the
        // index exists to remove. A receipt that cannot be read or decoded now
        // fails the whole warm scan closed instead of silently degrading one
        // entry to its two digest fields.
        let page = try store.listCaptures(
            machineID: machineID,
            cursor: try stringArgument(arguments, "cursor"),
            limit: try limitArgument(arguments)
        )
        let captures: [MCPRemoteWireValue] = page.captures.map { capture in
            .object([
                ("manifestSHA256", .string(capture.manifestSHA256)),
                ("receiptSHA256", .string(capture.receiptSHA256)),
                ("sessionID", .string(capture.sessionID)),
                ("captureID", .string(capture.captureID)),
                ("rawByteCount", .int(Int(capture.rawByteCount))),
                ("storedAt", .string(capture.storedAt)),
            ])
        }
        var body: [(String, MCPRemoteWireValue)] = [("captures", .array(captures))]
        if let next = page.nextCursor {
            body.append(("nextCursor", .string(next)))
        }
        return toolSuccess(body)
    }

    private static func getSession(
        arguments: [String: Any],
        store: ArchiveStore
    ) throws -> [(String, MCPRemoteWireValue)] {
        try validateArgumentKeys(arguments, allowed: ["manifest_sha256", "offset", "max_bytes"])
        guard let digest = try stringArgument(arguments, "manifest_sha256"), !digest.isEmpty else {
            throw MCPRemoteToolError(message: "manifest_sha256 is required", code: "invalidArguments")
        }
        let offset = try intArgument(arguments, "offset", minimum: 0) ?? 0
        let maxBytes = try intArgument(
            arguments, "max_bytes", minimum: 1, maximum: maxTranscriptWindowBytes
        ) ?? defaultTranscriptWindowBytes

        // Decode only the requested raw window plus enough overlap to recognize
        // a secret beginning on either side of a page boundary. Search backward
        // and extend a trailing match in bounded increments so every supported
        // credential is replaced atomically; fail closed at the decode ceiling.
        var readStart = max(0, offset - transcriptRedactionOverlapBytes)
        let targetEnd = offset > Int.max - maxBytes ? Int.max : offset + maxBytes
        let initialReadEnd = targetEnd > Int.max - transcriptRedactionOverlapBytes
            ? Int.max
            : targetEnd + transcriptRedactionOverlapBytes
        var decodedLimit = max(1, initialReadEnd - readStart)
        var source = try store.readSourceWindow(
            manifestDigest: digest,
            offset: readStart,
            maxBytes: decodedLimit
        )
        let initialTargetStart = min(source.bytes.count, max(0, offset - readStart))
        var redactionStart = sensitiveRangeStart(
            in: source.bytes,
            crossing: initialTargetStart
        ).map { readStart + $0 }
        var searchEnd = readStart
        var searchedBackwardBytes = initialTargetStart
        while redactionStart == nil, searchEnd > 0 {
            let remainingBudget = maxTranscriptRedactionDecodedBytes - searchedBackwardBytes
            guard remainingBudget > 0 else {
                throw transcriptRedactionLimitError()
            }
            let probeStart = max(0, searchEnd - min(maxTranscriptWindowBytes, remainingBudget))
            let probeLength = searchEnd - probeStart + transcriptRedactionOverlapBytes
            let probe = try store.readSourceWindow(
                manifestDigest: digest,
                offset: probeStart,
                maxBytes: probeLength
            )
            redactionStart = sensitiveRangeStart(
                in: probe.bytes,
                crossing: searchEnd - probeStart
            ).map { probeStart + $0 }
            searchedBackwardBytes += searchEnd - probeStart
            searchEnd = probeStart
        }
        if let redactionStart {
            readStart = redactionStart
            decodedLimit = max(1, initialReadEnd - readStart)
            guard decodedLimit <= maxTranscriptRedactionDecodedBytes else {
                throw transcriptRedactionLimitError()
            }
            source = try store.readSourceWindow(
                manifestDigest: digest,
                offset: readStart,
                maxBytes: decodedLimit
            )
        }
        while hasTrailingSensitiveRange(
            in: source.bytes,
            before: min(source.bytes.count, max(0, targetEnd - readStart))
        ),
              Int64(readStart + source.bytes.count) < source.totalBytes {
            guard decodedLimit < maxTranscriptRedactionDecodedBytes else {
                throw transcriptRedactionLimitError()
            }
            decodedLimit = min(
                maxTranscriptRedactionDecodedBytes,
                decodedLimit + maxTranscriptWindowBytes
            )
            source = try store.readSourceWindow(
                manifestDigest: digest,
                offset: readStart,
                maxBytes: decodedLimit
            )
        }
        if hasTrailingSensitiveRange(
            in: source.bytes,
            before: min(source.bytes.count, max(0, targetEnd - readStart))
        ),
           Int64(readStart + source.bytes.count) < source.totalBytes {
            throw transcriptRedactionLimitError()
        }
        let manifest = source.manifest
        let targetStart = min(source.bytes.count, max(0, offset - readStart))
        let targetUpper = min(source.bytes.count, max(targetStart, targetEnd - readStart))
        let targetRange = targetStart..<targetUpper
        var requestedWindow = Data()
        var rawCursor = targetRange.lowerBound
        var consumedUpper = targetRange.upperBound
        for secret in TranscriptRedactionPolicy.sensitiveUTF8Ranges(inUTF8: source.bytes) {
            guard secret.upperBound > targetRange.lowerBound,
                  secret.lowerBound < targetRange.upperBound
            else {
                continue
            }
            let plainEnd = min(targetRange.upperBound, max(rawCursor, secret.lowerBound))
            if rawCursor < plainEnd {
                requestedWindow.append(source.bytes.subdata(in: rawCursor..<plainEnd))
            }
            requestedWindow.append(Data(TranscriptRedactionPolicy.redactionToken.utf8))
            rawCursor = max(rawCursor, secret.upperBound)
            consumedUpper = max(consumedUpper, secret.upperBound)
        }
        if rawCursor < targetRange.upperBound {
            requestedWindow.append(source.bytes.subdata(in: rawCursor..<targetRange.upperBound))
        }
        let totalBytes = Int(source.totalBytes)

        // A page boundary must not split a multibyte character: the repairing
        // UTF-8 decode below would turn the split scalar into U+FFFD in both
        // pages, and no client could reassemble it (retro PR-2, F18). Snapping
        // the window to scalar boundaries and deriving `nextOffset` from the
        // snapped end keeps paging byte-exact.
        let bounds = utf8ScalarBounds(
            of: requestedWindow,
            snapStart: offset > 0,
            snapEnd: offset + requestedWindow.count < totalBytes
        )
        let window = requestedWindow.subdata(in: bounds)
        let leadingSnap = bounds.lowerBound - requestedWindow.startIndex
        let trailingSnap = requestedWindow.endIndex - bounds.upperBound
        let windowOffset = offset + leadingSnap
        let nextOffset = readStart + consumedUpper - trailingSnap
        var structured: [(String, MCPRemoteWireValue)] = [
            ("sessionID", manifest.sessionID.map { .string($0) } ?? .null),
            ("source", .string(manifest.source)),
            ("locator", .string(manifest.locator)),
            ("machineID", .string(manifest.machineID)),
            ("captureID", .string(manifest.captureID)),
            ("capturedAt", .string(manifest.capturedAt)),
            ("totalBytes", .int(totalBytes)),
            // Effective start of the returned text: equal to the requested
            // offset unless that offset landed inside a multibyte character.
            ("offset", .int(windowOffset)),
            ("byteCount", .int(window.count)),
        ]
        if nextOffset < totalBytes, !window.isEmpty {
            structured.append(("nextOffset", .int(nextOffset)))
        }
        let text = String(decoding: window, as: UTF8.self)
        // The transcript goes in BOTH the content block and `structuredContent`.
        // Clients that receive a structured result may surface only that and
        // drop the content block (Claude Code 2.1.220 does), so a transcript
        // carried solely in `content` would never reach the model.
        structured.append(("text", .string(text)))
        return [
            ("content", .array([
                .object([("type", .string("text")), ("text", .string(text))]),
            ])),
            ("structuredContent", .object(structured)),
        ]
    }

    private static func sensitiveRangeStart(
        in data: Data,
        crossing position: Int
    ) -> Int? {
        let cursor = min(max(position, 0), data.count)
        return TranscriptRedactionPolicy.sensitiveUTF8Ranges(inUTF8: data)
            .last(where: { $0.lowerBound < cursor && $0.upperBound >= cursor })?
            .lowerBound
    }

    private static func hasTrailingSensitiveRange(
        in data: Data,
        before targetUpper: Int
    ) -> Bool {
        TranscriptRedactionPolicy.sensitiveUTF8Ranges(inUTF8: data).contains {
            $0.lowerBound < targetUpper && $0.upperBound == data.count
        }
    }

    private static func transcriptRedactionLimitError() -> MCPRemoteToolError {
        MCPRemoteToolError(
            message: "Transcript redaction window exceeds the safety limit",
            code: "archiveStoreError"
        )
    }

    /// Byte range of `window` that holds only whole UTF-8 scalars.
    ///
    /// `snapStart` skips the continuation bytes of a scalar the window begins
    /// inside; `snapEnd` drops a trailing scalar the window cuts short so the
    /// next page starts on its first byte. A window too small to hold one whole
    /// scalar is returned unchanged, so paging still advances — that page keeps
    /// the pre-fix behavior and repairs to U+FFFD, as do genuinely invalid
    /// stored bytes.
    private static func utf8ScalarBounds(
        of window: Data,
        snapStart: Bool,
        snapEnd: Bool
    ) -> Range<Int> {
        let full = window.startIndex..<window.endIndex
        guard !window.isEmpty else { return full }
        var start = window.startIndex
        if snapStart {
            while start < window.endIndex,
                  isUTF8Continuation(window[start]),
                  start - window.startIndex < 3 {
                start += 1
            }
        }
        var end = window.endIndex
        if snapEnd {
            // A valid scalar carries at most three continuation bytes, so a
            // lead byte further back than that means the bytes are invalid.
            var probe = end - 1
            while probe >= start, end - probe <= 4 {
                let byte = window[probe]
                if !isUTF8Continuation(byte) {
                    if let length = utf8ScalarLength(lead: byte), probe + length > end {
                        end = probe
                    }
                    break
                }
                probe -= 1
            }
        }
        return start < end ? start..<end : full
    }

    private static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    private static func utf8ScalarLength(lead byte: UInt8) -> Int? {
        switch byte {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }

    // MARK: Tool argument validation

    private static func validateArgumentKeys(_ arguments: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(arguments.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw MCPRemoteToolError(
                message: "Unknown arguments: \(unknown.sorted().joined(separator: ", "))",
                code: "invalidArguments"
            )
        }
    }

    private static func stringArgument(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let raw = arguments[key] else { return nil }
        guard let value = raw as? String else {
            throw MCPRemoteToolError(message: "\(key) must be a string", code: "invalidArguments")
        }
        return value
    }

    private static func intArgument(
        _ arguments: [String: Any],
        _ key: String,
        minimum: Int,
        maximum: Int = Int.max
    ) throws -> Int? {
        guard let raw = arguments[key] else { return nil }
        guard let number = raw as? NSNumber,
              number.intValue >= minimum, number.intValue <= maximum else {
            throw MCPRemoteToolError(
                message: "\(key) must be an integer in [\(minimum), \(maximum == Int.max ? "max" : String(maximum))]",
                code: "invalidArguments"
            )
        }
        return number.intValue
    }

    private static func limitArgument(_ arguments: [String: Any]) throws -> Int {
        try intArgument(arguments, "limit", minimum: 1, maximum: 100) ?? 100
    }

    // MARK: Tool result builders

    private static func toolSuccess(
        _ structured: [(String, MCPRemoteWireValue)]
    ) -> [(String, MCPRemoteWireValue)] {
        let structuredValue = MCPRemoteWireValue.object(structured)
        return [
            ("content", .array([
                .object([("type", .string("text")), ("text", .string(structuredValue.encoded()))]),
            ])),
            ("structuredContent", structuredValue),
        ]
    }

    private static func toolError(_ message: String, code: String) -> [(String, MCPRemoteWireValue)] {
        [
            ("content", .array([
                .object([("type", .string("text")), ("text", .string(message))]),
            ])),
            ("isError", .bool(true)),
            ("structuredContent", .object([
                ("code", .string(code)),
                ("message", .string(message)),
            ])),
        ]
    }

    // MARK: JSON-RPC plumbing

    private static func wireID(of raw: Any?) -> MCPRemoteWireValue? {
        // NSNumber's Swift bridging makes `is Bool` unreliable on
        // JSONSerialization output, so numeric ids are accepted as-is; JSON-RPC
        // forbids boolean ids and a client sending one gets it echoed as 1/0.
        switch raw {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            return .int(value.intValue)
        default:
            return nil
        }
    }

    private static func resultResponse(id: MCPRemoteWireValue, result: MCPRemoteWireValue) -> Response {
        let payload = MCPRemoteWireValue.object([
            ("jsonrpc", .string("2.0")),
            ("id", id),
            ("result", result),
        ])
        return EngramRemoteServerApp.json(Data(payload.encoded().utf8))
    }

    private static func errorResponse(
        status: HTTPResponse.Status,
        id: MCPRemoteWireValue?,
        code: Int,
        message: String,
        data: MCPRemoteWireValue? = nil
    ) -> Response {
        var errorEntries: [(String, MCPRemoteWireValue)] = [
            ("code", .int(code)),
            ("message", .string(message)),
        ]
        if let data {
            errorEntries.append(("data", data))
        }
        var entries: [(String, MCPRemoteWireValue)] = [("jsonrpc", .string("2.0"))]
        entries.append(("id", id ?? .null))
        entries.append(("error", .object(errorEntries)))
        let body = Data(MCPRemoteWireValue.object(entries).encoded().utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.contentLength] = "\(body.count)"
        return Response(
            status: status,
            headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(data: body))
        )
    }
}
