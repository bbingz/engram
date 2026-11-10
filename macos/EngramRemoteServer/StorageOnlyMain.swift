import CryptoKit
import Darwin
import Dispatch
import Foundation

// Storage-only entrypoint for macOS 12+ x86_64/arm64 hosts (e.g. 10.0.0.9).
// Uses the exact same ArchiveStore, BlobStore, ArchiveRemoteTelemetryStore,
// and EngramRemoteServerConfig types without requiring Hummingbird (macOS 14+).

private struct HTTPRequest {
    let method: String
    let path: String
    let rawQuery: String?
    let headers: [String: String]
    let body: Data
}

private struct HTTPResponse {
    let statusCode: Int
    let reasonPhrase: String
    var headers: [(String, String)]
    let body: Data
    let omitBodyOnWire: Bool

    static func empty(
        status: Int,
        reason: String,
        contentType: String? = nil,
        contentLength: Int? = nil,
        authenticate: Bool = false,
        omitBodyOnWire: Bool = false
    ) -> HTTPResponse {
        var headers: [(String, String)] = []
        if let contentType { headers.append(("Content-Type", contentType)) }
        if let contentLength { headers.append(("Content-Length", "\(contentLength)")) }
        else if !omitBodyOnWire { headers.append(("Content-Length", "0")) }
        if authenticate { headers.append(("WWW-Authenticate", "Bearer")) }
        return HTTPResponse(
            statusCode: status,
            reasonPhrase: reason,
            headers: headers,
            body: Data(),
            omitBodyOnWire: omitBodyOnWire
        )
    }

    static func data(
        _ data: Data,
        status: Int = 200,
        reason: String = "OK",
        contentType: String,
        authenticate: Bool = false,
        omitBodyOnWire: Bool = false
    ) -> HTTPResponse {
        var headers: [(String, String)] = [
            ("Content-Type", contentType),
            ("Content-Length", "\(data.count)")
        ]
        if authenticate { headers.append(("WWW-Authenticate", "Bearer")) }
        return HTTPResponse(
            statusCode: status,
            reasonPhrase: reason,
            headers: headers,
            body: data,
            omitBodyOnWire: omitBodyOnWire
        )
    }

    static func headOnly(_ response: HTTPResponse) -> HTTPResponse {
        HTTPResponse(
            statusCode: response.statusCode,
            reasonPhrase: response.reasonPhrase,
            headers: response.headers,
            body: Data(),
            omitBodyOnWire: true
        )
    }
}

private enum BodyReadError: Error {
    case payloadTooLarge
    case malformed
    case io
}

private final class StorageOnlyServer: @unchecked Sendable {
    static let maximumCatalogBytes = 4 * 1024 * 1024
    static let maximumCatalogPeers = 1_024
    private static let catalogEnvelopeBytes = Data(#"{"schemaVersion":1,"manifests":[]}"#.utf8).count
    static let maximumCatalogManifestBytes = maximumCatalogBytes - catalogEnvelopeBytes

    private let config: EngramRemoteServerConfig
    private let store: BlobStore
    private let archiveStore: ArchiveStore?
    private let archiveTelemetry: ArchiveRemoteTelemetryStore?

    init(config: EngramRemoteServerConfig) throws {
        if let archive = config.archiveV2 {
            guard EngramRemoteServerConfig.isCurrentArchiveServerID(archive.serverID) else {
                throw EngramRemoteServerConfig.ConfigError.invalidArchiveServerID
            }
            guard archive.bearerToken != config.bearerToken,
                  !Self.keysEqual(archive.atRestKey, config.atRestKey) else {
                throw EngramRemoteServerConfig.ConfigError.archiveCredentialsMustBeDistinct
            }
        }
        self.config = config
        self.store = try BlobStore(root: config.storeRoot, key: config.atRestKey)
        if let archive = config.archiveV2 {
            self.archiveStore = try ArchiveStore(
                root: archive.root,
                key: archive.atRestKey,
                serverID: archive.serverID,
                publicationsEnabled: archive.publicationsEnabled
            )
            self.archiveTelemetry = try ArchiveRemoteTelemetryStore(
                archiveRoot: archive.root,
                serverID: archive.serverID,
                sourceRevision: config.sourceRevision,
                now: { Date() },
                snapshotWriter: { data, url in
                    try ArchiveRemoteTelemetryStore.defaultSnapshotWriter(data, url)
                }
            )
        } else {
            self.archiveStore = nil
            self.archiveTelemetry = nil
        }
    }

    func warmIndexes() {
        if let archiveStore {
            DispatchQueue.global(qos: .utility).async {
                do {
                    try archiveStore.warmListIndex()
                    Self.stderr("engram-remote: archive list index warm complete")
                } catch {
                    Self.stderr("engram-remote: archive list index warm failed: \(error)")
                }
            }
        }
        if config.archiveV2?.publicationsEnabled == true, let archiveStore {
            DispatchQueue.global(qos: .utility).async {
                do {
                    try archiveStore.warmPublicationIndex()
                    Self.stderr("engram-remote: collector publication index warm complete")
                } catch {
                    Self.stderr("engram-remote: collector publication intake unavailable")
                }
            }
        }
    }

    func run() throws -> Never {
        warmIndexes()
        let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var yes: Int32 = 1
        _ = Darwin.setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(config.port).bigEndian)
        if config.host == "0.0.0.0" || config.host.isEmpty {
            addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        } else {
            guard config.host.withCString({ Darwin.inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
                Darwin.close(listenFD)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = Int(errno)
            Darwin.close(listenFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: err)
        }
        guard Darwin.listen(listenFD, 128) == 0 else {
            let err = Int(errno)
            Darwin.close(listenFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: err)
        }

        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &clientLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                continue
            }
            let server = self
            DispatchQueue.global(qos: .userInitiated).async {
                server.handleConnection(fd: clientFD)
            }
        }
    }

    private func handleConnection(fd: Int32) {
        defer { _ = Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let headerResult = Self.readHeaders(fd: fd) else { return }
        let method = headerResult.method
        let rawTarget = headerResult.target
        let headers = headerResult.headers

        let path: String
        let rawQuery: String?
        if let qIndex = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<qIndex])
            rawQuery = String(rawTarget[rawTarget.index(after: qIndex)...])
        } else {
            path = rawTarget
            rawQuery = nil
        }

        let maxBodyBytes = maximumBodyBytes(method: method, path: path)
        let body: Data
        switch Self.readBody(
            fd: fd,
            headers: headers,
            initialBuffer: headerResult.leftover,
            maxBytes: maxBodyBytes
        ) {
        case .success(let data):
            body = data
        case .failure(.payloadTooLarge):
            let resp = path.hasPrefix("/v2/archive")
                ? Self.archiveError(status: 413, reason: "Payload Too Large", code: "payload_too_large")
                : HTTPResponse.data(Data("payload too large\n".utf8), status: 413, reason: "Payload Too Large", contentType: "text/plain; charset=utf-8")
            Self.writeResponse(fd: fd, response: resp)
            return
        case .failure:
            let resp = path.hasPrefix("/v2/archive")
                ? Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                : HTTPResponse.data(Data("bad request\n".utf8), status: 400, reason: "Bad Request", contentType: "text/plain; charset=utf-8")
            Self.writeResponse(fd: fd, response: resp)
            return
        }

        let req = HTTPRequest(method: method, path: path, rawQuery: rawQuery, headers: headers, body: body)
        let response = route(req)
        Self.writeResponse(fd: fd, response: response)
    }

    private func maximumBodyBytes(method: String, path: String) -> Int {
        guard method == "PUT" else { return 0 }
        if path.hasPrefix("/v1/bundles/") {
            let key = String(path.dropFirst("/v1/bundles/".count))
            let isManifest = key.hasPrefix("catalog.") && key.hasSuffix(".manifest") && !key.contains("..")
            return isManifest ? min(config.maxBundleBytes, Self.maximumCatalogManifestBytes) : config.maxBundleBytes
        }
        if path.hasPrefix("/v2/archive/objects/") {
            return ArchiveV2ProtocolLimits.maxObjectRawBytes
        }
        if path.hasPrefix("/v2/archive/manifests/") {
            return ArchiveV2ProtocolLimits.maxManifestBytes
        }
        if path.hasPrefix("/v2/archive/publications/") {
            return CollectorPublicationProtocolLimits.maxPublicationBytes
        }
        if path.hasPrefix("/v2/archive/receipts/") {
            return 0
        }
        return 64 * 1024
    }

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        if req.method == "GET", req.path == "/v1/health" {
            return HTTPResponse.data(Data("ok\n".utf8), contentType: "text/plain; charset=utf-8")
        }
        if req.path == "/v1/catalog" && req.method == "GET" {
            return handleV1Catalog(req)
        }
        if req.path.hasPrefix("/v1/bundles/") {
            let key = String(req.path.dropFirst("/v1/bundles/".count))
            return handleV1Bundle(req, key: key)
        }
        if req.path == "/v2/archive" || req.path.hasPrefix("/v2/archive/") {
            guard let archive = config.archiveV2, let archiveStore else {
                return HTTPResponse.empty(status: 404, reason: "Not Found")
            }
            return handleArchiveV2(req, archive: archive, store: archiveStore)
        }
        return HTTPResponse.empty(status: 404, reason: "Not Found")
    }

    // MARK: - /v1 routes

    private func handleV1Catalog(_ req: HTTPRequest) -> HTTPResponse {
        guard Self.authorized(req, token: config.bearerToken) else { return Self.v1Unauthorized() }
        var manifests: [[String: Any]] = []
        let keys: [String]
        do {
            keys = try store.listKeys(prefix: "catalog.", suffix: ".manifest", maximumCount: Self.maximumCatalogPeers)
        } catch BlobStoreError.limitExceeded {
            return HTTPResponse.data(Data("payload too large\n".utf8), status: 413, reason: "Payload Too Large", contentType: "text/plain; charset=utf-8")
        } catch {
            return HTTPResponse.empty(status: 500, reason: "Internal Server Error")
        }
        var remainingDecodedBytes = Self.maximumCatalogManifestBytes
        for k in keys {
            guard let data = try? store.get(k, maximumPlaintextBytes: Self.maximumCatalogBytes),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  data.count <= Self.maximumCatalogManifestBytes else {
                continue
            }
            let requiredBytes = data.count + (manifests.isEmpty ? 0 : 1)
            guard requiredBytes <= remainingDecodedBytes else {
                return HTTPResponse.data(Data("payload too large\n".utf8), status: 413, reason: "Payload Too Large", contentType: "text/plain; charset=utf-8")
            }
            remainingDecodedBytes -= requiredBytes
            manifests.append(obj)
        }
        let payload: [String: Any] = ["schemaVersion": 1, "manifests": manifests]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return HTTPResponse.empty(status: 500, reason: "Internal Server Error")
        }
        guard body.count <= Self.maximumCatalogBytes else {
            return HTTPResponse.data(Data("payload too large\n".utf8), status: 413, reason: "Payload Too Large", contentType: "text/plain; charset=utf-8")
        }
        return HTTPResponse.data(body, contentType: "application/json; charset=utf-8")
    }

    private func handleV1Bundle(_ req: HTTPRequest, key: String) -> HTTPResponse {
        guard Self.authorized(req, token: config.bearerToken) else { return Self.v1Unauthorized() }
        guard !key.isEmpty else {
            return HTTPResponse.data(Data("missing key\n".utf8), status: 400, reason: "Bad Request", contentType: "text/plain; charset=utf-8")
        }
        switch req.method {
        case "HEAD":
            do {
                let exists = try store.exists(key)
                return HTTPResponse.empty(status: exists ? 200 : 404, reason: exists ? "OK" : "Not Found", omitBodyOnWire: true)
            } catch BlobStoreError.invalidKey {
                return HTTPResponse.headOnly(HTTPResponse.data(Data("invalid key\n".utf8), status: 400, reason: "Bad Request", contentType: "text/plain; charset=utf-8"))
            } catch {
                return HTTPResponse.empty(status: 500, reason: "Internal Server Error", omitBodyOnWire: true)
            }
        case "GET":
            do {
                let data = try store.get(key, maximumPlaintextBytes: config.maxBundleBytes)
                return HTTPResponse.data(data, contentType: "application/octet-stream")
            } catch BlobStoreError.notFound {
                return HTTPResponse.empty(status: 404, reason: "Not Found")
            } catch BlobStoreError.invalidKey {
                return HTTPResponse.data(Data("invalid key\n".utf8), status: 400, reason: "Bad Request", contentType: "text/plain; charset=utf-8")
            } catch BlobStoreError.limitExceeded {
                return HTTPResponse.data(Data("payload too large\n".utf8), status: 413, reason: "Payload Too Large", contentType: "text/plain; charset=utf-8")
            } catch {
                return HTTPResponse.empty(status: 500, reason: "Internal Server Error")
            }
        case "PUT":
            do {
                try store.put(key, plaintext: req.body)
                return HTTPResponse.empty(status: 201, reason: "Created")
            } catch BlobStoreError.invalidKey {
                return HTTPResponse.data(Data("invalid key\n".utf8), status: 400, reason: "Bad Request", contentType: "text/plain; charset=utf-8")
            } catch {
                return HTTPResponse.empty(status: 500, reason: "Internal Server Error")
            }
        case "DELETE":
            do {
                try store.delete(key)
                return HTTPResponse.empty(status: 204, reason: "No Content")
            } catch BlobStoreError.invalidKey {
                return HTTPResponse.data(Data("invalid key\n".utf8), status: 400, reason: "Bad Request", contentType: "text/plain; charset=utf-8")
            } catch {
                return HTTPResponse.empty(status: 500, reason: "Internal Server Error")
            }
        default:
            return HTTPResponse.empty(status: 405, reason: "Method Not Allowed")
        }
    }

    // MARK: - /v2/archive routes

    private func handleArchiveV2(
        _ req: HTTPRequest,
        archive: EngramRemoteArchiveConfig,
        store: ArchiveStore
    ) -> HTTPResponse {
        let token = archive.bearerToken
        if req.method == "DELETE" {
            let endpoint = Self.deleteEndpointName(path: req.path)
            return observed(req, endpoint: endpoint, archiveMutation: false) {
                guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                return Self.archiveError(status: 405, reason: "Method Not Allowed", code: "method_not_allowed")
            }
        }

        if req.path.hasPrefix("/v2/archive/objects/") {
            let digest = String(req.path.dropFirst("/v2/archive/objects/".count))
            switch req.method {
            case "PUT":
                return observed(req, endpoint: "object", archiveMutation: true) {
                    guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                    guard ArchiveV2Hash.isValidSHA256(digest) else {
                        return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                    }
                    guard Self.hasMediaType(req, expected: "application/octet-stream") else {
                        return Self.archiveError(status: 415, reason: "Unsupported Media Type", code: "unsupported_media_type")
                    }
                    do {
                        let result = try store.putObject(digest: digest, raw: req.body)
                        let status = result == .published ? 201 : 200
                        let reason = result == .published ? "Created" : "OK"
                        return HTTPResponse.empty(status: status, reason: reason)
                    } catch {
                        return Self.archiveStoreErrorResponse(error)
                    }
                }
            case "HEAD":
                return observed(req, endpoint: "object", archiveMutation: false) {
                    guard Self.authorized(req, token: token) else {
                        return HTTPResponse.headOnly(Self.archiveUnauthorized())
                    }
                    guard ArchiveV2Hash.isValidSHA256(digest) else {
                        return HTTPResponse.headOnly(Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request"))
                    }
                    do {
                        guard try store.hasObject(digest: digest) else {
                            return HTTPResponse.empty(status: 404, reason: "Not Found", omitBodyOnWire: true)
                        }
                        return HTTPResponse.empty(status: 200, reason: "OK", contentType: "application/octet-stream", omitBodyOnWire: true)
                    } catch {
                        return HTTPResponse.headOnly(Self.archiveStoreErrorResponse(error))
                    }
                }
            case "GET":
                return observed(req, endpoint: "object", archiveMutation: false) {
                    guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                    guard ArchiveV2Hash.isValidSHA256(digest) else {
                        return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                    }
                    do {
                        return HTTPResponse.data(try store.getObject(digest: digest), contentType: "application/octet-stream")
                    } catch {
                        return Self.archiveStoreErrorResponse(error)
                    }
                }
            default:
                return HTTPResponse.empty(status: 405, reason: "Method Not Allowed")
            }
        }

        if req.path.hasPrefix("/v2/archive/manifests/") {
            let digest = String(req.path.dropFirst("/v2/archive/manifests/".count))
            switch req.method {
            case "PUT":
                return observed(req, endpoint: "manifest", archiveMutation: true) {
                    guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                    guard ArchiveV2Hash.isValidSHA256(digest) else {
                        return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                    }
                    guard Self.hasMediaType(req, expected: "application/json") else {
                        return Self.archiveError(status: 415, reason: "Unsupported Media Type", code: "unsupported_media_type")
                    }
                    do {
                        let result = try store.putManifest(digest: digest, canonicalBytes: req.body)
                        let status = result == .published ? 201 : 200
                        let reason = result == .published ? "Created" : "OK"
                        return HTTPResponse.empty(status: status, reason: reason)
                    } catch {
                        return Self.archiveStoreErrorResponse(error)
                    }
                }
            case "HEAD":
                return observed(req, endpoint: "manifest", archiveMutation: false) {
                    guard Self.authorized(req, token: token) else {
                        return HTTPResponse.headOnly(Self.archiveUnauthorized())
                    }
                    guard ArchiveV2Hash.isValidSHA256(digest) else {
                        return HTTPResponse.headOnly(Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request"))
                    }
                    do {
                        guard try store.hasManifest(digest: digest) else {
                            return HTTPResponse.empty(status: 404, reason: "Not Found", omitBodyOnWire: true)
                        }
                        return HTTPResponse.empty(status: 200, reason: "OK", contentType: "application/json; charset=utf-8", omitBodyOnWire: true)
                    } catch {
                        return HTTPResponse.headOnly(Self.archiveStoreErrorResponse(error))
                    }
                }
            case "GET":
                return observed(req, endpoint: "manifest", archiveMutation: false) {
                    guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                    guard ArchiveV2Hash.isValidSHA256(digest) else {
                        return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                    }
                    do {
                        return HTTPResponse.data(try store.getManifest(digest: digest), contentType: "application/json; charset=utf-8")
                    } catch {
                        return Self.archiveStoreErrorResponse(error)
                    }
                }
            default:
                return HTTPResponse.empty(status: 405, reason: "Method Not Allowed")
            }
        }

        if req.path.hasPrefix("/v2/archive/receipts/") {
            let digest = String(req.path.dropFirst("/v2/archive/receipts/".count))
            switch req.method {
            case "PUT":
                return observed(req, endpoint: "receipt", archiveMutation: true) {
                    guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                    guard ArchiveV2Hash.isValidSHA256(digest), req.body.isEmpty else {
                        return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                    }
                    do {
                        let creation = try store.createReceiptWithResult(manifestDigest: digest)
                        let status = creation.result == .published ? 201 : 200
                        let reason = creation.result == .published ? "Created" : "OK"
                        return HTTPResponse.data(creation.bytes, status: status, reason: reason, contentType: "application/json; charset=utf-8")
                    } catch {
                        return Self.archiveStoreErrorResponse(error)
                    }
                }
            case "GET":
                return observed(req, endpoint: "receipt", archiveMutation: false) {
                    guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                    guard ArchiveV2Hash.isValidSHA256(digest) else {
                        return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                    }
                    do {
                        return HTTPResponse.data(try store.getReceipt(manifestDigest: digest), contentType: "application/json; charset=utf-8")
                    } catch {
                        return Self.archiveStoreErrorResponse(error)
                    }
                }
            default:
                return HTTPResponse.empty(status: 405, reason: "Method Not Allowed")
            }
        }

        if req.path == "/v2/archive/machines" && req.method == "GET" {
            return observed(req, endpoint: "machines", archiveMutation: false) {
                guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                do {
                    let params = try Self.archivePageParameters(rawQuery: req.rawQuery, allowedKeys: ["cursor", "limit"])
                    let page = try store.listMachines(cursor: params.cursor, limit: params.limit)
                    return try Self.archivePageResponse(page)
                } catch is MalformedQueryError {
                    return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                } catch {
                    return Self.archiveStoreErrorResponse(error)
                }
            }
        }

        if req.path == "/v2/archive/receipts" && req.method == "GET" {
            return observed(req, endpoint: "receipts", archiveMutation: false) {
                guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                do {
                    let items = try Self.parseQueryItems(req.rawQuery, allowedKeys: ["machine_id", "cursor", "limit"])
                    let machineValues = items.filter { $0.0 == "machine_id" }.map { $0.1 }
                    guard machineValues.count == 1 else { throw MalformedQueryError() }
                    let params = try Self.archivePageParameters(rawQuery: req.rawQuery, allowedKeys: ["machine_id", "cursor", "limit"])
                    let page = try store.listReceipts(machineID: machineValues[0], cursor: params.cursor, limit: params.limit)
                    return try Self.archivePageResponse(page)
                } catch is MalformedQueryError {
                    return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                } catch {
                    return Self.archiveStoreErrorResponse(error)
                }
            }
        }

        if req.path == "/v2/archive/status" && req.method == "GET", let telemetry = archiveTelemetry {
            return observed(req, endpoint: "status", archiveMutation: false) {
                guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                let sem = DispatchSemaphore(value: 0)
                var snapshotBox: ArchiveRemoteTelemetrySnapshot?
                Task {
                    snapshotBox = await telemetry.status(forcePersist: false)
                    sem.signal()
                }
                sem.wait()
                guard let rawSnapshot = snapshotBox,
                      let snapshot = try? Self.canonicalTelemetrySnapshot(rawSnapshot),
                      let bytes = try? ArchiveCanonicalJSON.encode(snapshot),
                      bytes.count <= ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes else {
                    return Self.archiveError(status: 500, reason: "Internal Server Error", code: "internal_error")
                }
                return HTTPResponse.data(bytes, contentType: "application/json; charset=utf-8")
            }
        }

        if archive.publicationsEnabled {
            if req.path == "/v2/archive/publication-capabilities" && req.method == "GET" {
                guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                guard let bytes = try? ArchiveCanonicalJSON.encode(CollectorPublicationCapabilities(serverID: archive.serverID)),
                      bytes.count <= CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes else {
                    return Self.archiveError(status: 500, reason: "Internal Server Error", code: "internal_error")
                }
                return HTTPResponse.data(bytes, contentType: "application/json; charset=utf-8")
            }

            if req.path.hasPrefix("/v2/archive/publications/") {
                let digest = String(req.path.dropFirst("/v2/archive/publications/".count))
                switch req.method {
                case "PUT":
                    guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                    guard ArchiveV2Hash.isValidSHA256(digest) else {
                        return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                    }
                    guard Self.hasMediaType(req, expected: "application/json") else {
                        return Self.archiveError(status: 415, reason: "Unsupported Media Type", code: "unsupported_media_type")
                    }
                    guard (try? ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: req.body)) != nil,
                          ArchiveV2Hash.sha256(req.body) == digest else {
                        return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                    }
                    do {
                        let acceptance = try store.acceptPublication(digest: digest, canonicalBytes: req.body)
                        let bytes = try ArchiveCanonicalJSON.encode(acceptance.record.ack)
                        guard bytes.count <= CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes else {
                            return Self.archiveError(status: 500, reason: "Internal Server Error", code: "internal_error")
                        }
                        let status = acceptance.result == .published ? 201 : 200
                        let reason = acceptance.result == .published ? "Created" : "OK"
                        return HTTPResponse.data(bytes, status: status, reason: reason, contentType: "application/json; charset=utf-8")
                    } catch {
                        return Self.publicationStoreErrorResponse(error)
                    }
                case "GET":
                    guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                    guard ArchiveV2Hash.isValidSHA256(digest) else {
                        return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                    }
                    do {
                        let record = try store.getPublication(digest: digest)
                        let bytes = try ArchiveCanonicalJSON.encode(record)
                        guard bytes.count <= CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes else {
                            return Self.archiveError(status: 500, reason: "Internal Server Error", code: "internal_error")
                        }
                        return HTTPResponse.data(bytes, contentType: "application/json; charset=utf-8")
                    } catch {
                        return Self.publicationStoreErrorResponse(error)
                    }
                default:
                    return HTTPResponse.empty(status: 405, reason: "Method Not Allowed")
                }
            }

            if req.path == "/v2/archive/publications" && req.method == "GET" {
                guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() }
                do {
                    let params = try Self.publicationPageParameters(rawQuery: req.rawQuery)
                    let page = try store.listPublications(cursor: params.cursor, limit: params.limit)
                    let bytes = try ArchiveCanonicalJSON.encode(page)
                    guard bytes.count <= CollectorPublicationProtocolLimits.maxPageBytes else {
                        return Self.archiveError(status: 500, reason: "Internal Server Error", code: "internal_error")
                    }
                    return HTTPResponse.data(bytes, contentType: "application/json; charset=utf-8")
                } catch is MalformedQueryError {
                    return Self.archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
                } catch {
                    return Self.publicationStoreErrorResponse(error)
                }
            }
        }

        return HTTPResponse.empty(status: 404, reason: "Not Found")
    }

    // MARK: - Helpers

    private struct MalformedQueryError: Error {}

    private static func parseQueryItems(_ rawQuery: String?, allowedKeys: Set<String>) throws -> [(String, String)] {
        guard let rawQuery, !rawQuery.isEmpty else { return [] }
        var items: [(String, String)] = []
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = String(parts[0])
            let rawVal = parts.count > 1 ? String(parts[1]) : ""
            guard let key = rawKey.removingPercentEncoding,
                  let val = rawVal.removingPercentEncoding,
                  allowedKeys.contains(key) else {
                throw MalformedQueryError()
            }
            items.append((key, val))
        }
        return items
    }

    private static func archivePageParameters(rawQuery: String?, allowedKeys: Set<String>) throws -> (cursor: String?, limit: Int) {
        let items = try parseQueryItems(rawQuery, allowedKeys: allowedKeys)
        let cursorValues = items.filter { $0.0 == "cursor" }.map { $0.1 }
        let limitValues = items.filter { $0.0 == "limit" }.map { $0.1 }
        guard cursorValues.count <= 1, limitValues.count <= 1 else { throw MalformedQueryError() }
        let cursor = cursorValues.first
        do {
            try ArchiveV2ProtocolLimits.validateCursor(cursor)
            let limit = try ArchiveV2ProtocolLimits.validatedPageLimit(limitValues.first)
            return (cursor, limit)
        } catch {
            throw MalformedQueryError()
        }
    }

    private static func publicationPageParameters(rawQuery: String?) throws -> (cursor: String?, limit: Int) {
        let items = try parseQueryItems(rawQuery, allowedKeys: ["cursor", "limit"])
        let cursorValues = items.filter { $0.0 == "cursor" }.map { $0.1 }
        let limitValues = items.filter { $0.0 == "limit" }.map { $0.1 }
        guard cursorValues.count <= 1, limitValues.count <= 1 else { throw MalformedQueryError() }
        let cursor = cursorValues.first
        do {
            if let cursor { _ = try CollectorPublicationCursor.decode(cursor) }
            let limit = try CollectorPublicationProtocolLimits.validatedPageLimit(limitValues.first)
            return (cursor, limit)
        } catch {
            throw MalformedQueryError()
        }
    }

    private static func archivePageResponse<T: Encodable>(_ page: T) throws -> HTTPResponse {
        let bytes = try ArchiveCanonicalJSON.encode(page)
        guard bytes.count <= ArchiveV2ProtocolLimits.maxPageBytes else {
            return archiveError(status: 500, reason: "Internal Server Error", code: "internal_error")
        }
        return HTTPResponse.data(bytes, contentType: "application/json; charset=utf-8")
    }

    private static func canonicalTelemetrySnapshot(
        _ snapshot: ArchiveRemoteTelemetrySnapshot
    ) throws -> ArchiveRemoteTelemetrySnapshot {
        let endpoints = try snapshot.endpoints.map { ep in
            let total = ep.totalDurationMs.rounded()
            let maximum = min(ep.maximumDurationMs.rounded(), total)
            return try ArchiveRemoteTelemetryEndpoint(
                endpoint: ep.endpoint,
                requestCount: ep.requestCount,
                errorCount: ep.errorCount,
                totalDurationMs: total,
                maximumDurationMs: maximum,
                requestBytes: ep.requestBytes,
                responseBytes: ep.responseBytes
            )
        }
        return try ArchiveRemoteTelemetrySnapshot(
            schema: snapshot.schema,
            serverID: snapshot.serverID,
            sourceRevision: snapshot.sourceRevision,
            processStartedAt: snapshot.processStartedAt,
            snapshotAt: snapshot.snapshotAt,
            uptimeSeconds: snapshot.uptimeSeconds.rounded(),
            diskAvailableBytes: snapshot.diskAvailableBytes,
            diskTotalBytes: snapshot.diskTotalBytes,
            requestCount: snapshot.requestCount,
            successCount: snapshot.successCount,
            clientErrorCount: snapshot.clientErrorCount,
            serverErrorCount: snapshot.serverErrorCount,
            requestBytes: snapshot.requestBytes,
            responseBytes: snapshot.responseBytes,
            lastArchiveMutationAt: snapshot.lastArchiveMutationAt,
            persistenceError: snapshot.persistenceError,
            endpoints: endpoints,
            recentErrors: snapshot.recentErrors
        )
    }

    private static func deleteEndpointName(path: String) -> String {
        if path.hasPrefix("/v2/archive/objects/") { return "object" }
        if path.hasPrefix("/v2/archive/manifests/") { return "manifest" }
        if path.hasPrefix("/v2/archive/receipts/") { return "receipt" }
        if path == "/v2/archive/receipts" { return "receipts" }
        if path == "/v2/archive/machines" { return "machines" }
        if path == "/v2/archive/status" { return "status" }
        return "unknown"
    }

    private func observed(_ req: HTTPRequest, endpoint: String, archiveMutation: Bool, operation: () -> HTTPResponse) -> HTTPResponse {
        let started = DispatchTime.now().uptimeNanoseconds
        let response = operation()
        if let telemetry = archiveTelemetry {
            let finished = DispatchTime.now().uptimeNanoseconds
            let durationMs = (finished >= started ? Double(finished - started) / 1_000_000 : 0).rounded()
            let reqBytes = Int64(req.body.count)
            let respBytes = Int64(response.body.count)
            Task {
                await telemetry.record(
                    ArchiveRemoteTelemetryObservation(
                        endpoint: endpoint,
                        method: req.method,
                        statusCode: response.statusCode,
                        durationMs: durationMs,
                        requestBytes: reqBytes,
                        responseBytes: respBytes,
                        archiveMutation: archiveMutation && response.statusCode < 300
                    )
                )
            }
        }
        return response
    }

    private static func authorized(_ req: HTTPRequest, token: String) -> Bool {
        guard let header = req.headers["authorization"] else { return false }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return false }
        return constantTimeEquals(String(header.dropFirst(prefix.count)), token)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
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
        for (left, right) in zip(lhsBytes, rhsBytes) { diff |= left ^ right }
        return diff == 0
    }

    private static func hasMediaType(_ req: HTTPRequest, expected: String) -> Bool {
        guard let contentType = req.headers["content-type"] else { return false }
        let base = contentType.split(separator: ";", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces).lowercased()
        return base == expected.lowercased()
    }

    private static func v1Unauthorized() -> HTTPResponse {
        HTTPResponse.data(Data("unauthorized\n".utf8), status: 401, reason: "Unauthorized", contentType: "text/plain; charset=utf-8", authenticate: true)
    }

    private static func archiveUnauthorized() -> HTTPResponse {
        archiveError(status: 401, reason: "Unauthorized", code: "unauthorized", authenticate: true)
    }

    private static func archiveError(status: Int, reason: String, code: String, authenticate: Bool = false) -> HTTPResponse {
        let data = Data("{\"error\":\"\(code)\"}".utf8)
        return HTTPResponse.data(data, status: status, reason: reason, contentType: "application/json; charset=utf-8", authenticate: authenticate)
    }

    private static func archiveStoreErrorResponse(_ error: Error) -> HTTPResponse {
        guard let error = error as? ArchiveStoreError else {
            return archiveError(status: 500, reason: "Internal Server Error", code: "internal_error")
        }
        switch error {
        case .invalidDigest, .invalidMachineID, .invalidPage:
            return archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
        case .notFound:
            return archiveError(status: 404, reason: "Not Found", code: "not_found")
        case .conflict, .missingReference:
            return archiveError(status: 409, reason: "Conflict", code: "conflict")
        case .tooLarge:
            return archiveError(status: 413, reason: "Payload Too Large", code: "payload_too_large")
        case .digestMismatch, .invalidManifest, .invalidReceipt, .unboundManifest:
            return archiveError(status: 422, reason: "Unprocessable Content", code: "invalid_content")
        case .io:
            return archiveError(status: 503, reason: "Service Unavailable", code: "storage_unavailable")
        }
    }

    private static func publicationStoreErrorResponse(_ error: Error) -> HTTPResponse {
        if let error = error as? ArchivePublicationStoreError {
            switch error {
            case .sequenceConflict:
                return archiveError(status: 409, reason: "Conflict", code: "sequence_conflict")
            case .cursorJournalMismatch:
                return archiveError(status: 409, reason: "Conflict", code: "cursor_journal_mismatch")
            case .cursorAheadOfTail:
                return archiveError(status: 409, reason: "Conflict", code: "cursor_ahead_of_tail")
            case .invalidPublication:
                return archiveError(status: 422, reason: "Unprocessable Content", code: "invalid_content")
            case .unavailable, .ordinalOverflow:
                return archiveError(status: 503, reason: "Service Unavailable", code: "storage_unavailable")
            }
        }
        if let error = error as? ArchiveStoreError {
            switch error {
            case .invalidDigest, .invalidMachineID, .invalidPage, .digestMismatch:
                return archiveError(status: 400, reason: "Bad Request", code: "malformed_request")
            case .notFound:
                return archiveError(status: 404, reason: "Not Found", code: "not_found")
            case .tooLarge:
                return archiveError(status: 413, reason: "Payload Too Large", code: "payload_too_large")
            case .invalidManifest, .missingReference, .unboundManifest:
                return archiveError(status: 422, reason: "Unprocessable Content", code: "invalid_content")
            case .conflict, .invalidReceipt, .io:
                return archiveError(status: 503, reason: "Service Unavailable", code: "storage_unavailable")
            }
        }
        return archiveError(status: 500, reason: "Internal Server Error", code: "internal_error")
    }

    // MARK: - Wire I/O

    private struct ParsedHeaders {
        let method: String
        let target: String
        let headers: [String: String]
        let leftover: Data
    }

    private static func readHeaders(fd: Int32) -> ParsedHeaders? {
        var buffer = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        let maxHeaderBytes = 32 * 1024
        var chunk = [UInt8](repeating: 0, count: 4096)

        while buffer.range(of: delimiter) == nil {
            if buffer.count >= maxHeaderBytes { return nil }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }

        guard let range = buffer.range(of: delimiter) else { return nil }
        let headerData = buffer.subdata(in: 0..<range.lowerBound)
        let leftover = buffer.subdata(in: range.upperBound..<buffer.count)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return ParsedHeaders(method: method, target: target, headers: headers, leftover: leftover)
    }

    private static func readBody(
        fd: Int32,
        headers: [String: String],
        initialBuffer: Data,
        maxBytes: Int
    ) -> Result<Data, BodyReadError> {
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else {
                return .failure(.malformed)
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        if contentLength > maxBytes {
            return .failure(.payloadTooLarge)
        }
        if let expect = headers["expect"], expect.lowercased().contains("100-continue") {
            writeAll(fd: fd, data: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        if contentLength == 0 {
            if !initialBuffer.isEmpty {
                return .failure(.payloadTooLarge)
            }
            return .success(Data())
        }
        var body = initialBuffer
        if body.count > contentLength {
            body = body.subdata(in: 0..<contentLength)
            return .success(body)
        }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while body.count < contentLength {
            let needed = min(chunk.count, contentLength - body.count)
            let n = Darwin.read(fd, &chunk, needed)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return .failure(.io) }
            body.append(contentsOf: chunk[0..<n])
        }
        return .success(body)
    }

    private static func writeResponse(fd: Int32, response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n"
        for (k, v) in response.headers {
            head += "\(k): \(v)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        writeAll(fd: fd, data: Data(head.utf8))
        if !response.omitBodyOnWire && !response.body.isEmpty {
            writeAll(fd: fd, data: response.body)
        }
    }

    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

@main
private enum StorageOnlyEntrypoint {
    static func main() {
        if CommandLine.arguments.contains("keygen") {
            print(EngramRemoteServerConfig.generateAtRestKeyBase64())
            exit(0)
        }

        do {
            let config = try EngramRemoteServerConfig.fromEnvironment()
            let server = try StorageOnlyServer(config: config)
            StorageOnlyServer.stderr("engram-remote listening on \(config.host):\(config.port) store=\(config.storeRoot.path)")
            try server.run()
        } catch {
            StorageOnlyServer.stderr("engram-remote fatal: \(error)")
            exit(1)
        }
    }
}
