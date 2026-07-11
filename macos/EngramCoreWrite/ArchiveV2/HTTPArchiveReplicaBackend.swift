import EngramCoreRead
import Foundation

struct ArchiveTransportPolicySnapshot: Equatable {
    let cookiesDisabled: Bool
    let cacheDisabled: Bool
    let credentialStorageDisabled: Bool
    let proxyDictionaryEmpty: Bool
    let waitsForConnectivity: Bool
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let usesEphemeralConfiguration: Bool
}

public final class HTTPArchiveReplicaBackend: ArchiveReplicaBackend, @unchecked Sendable {
    public let replicaID: String

    private static let requestTimeout: TimeInterval = 30
    private static let resourceTimeout: TimeInterval = 120

    private let connection: ArchiveReplicaConnection
    private let transportDelegate: ArchiveBoundedSessionDelegate
    private let session: URLSession
    let transportPolicyForTesting: ArchiveTransportPolicySnapshot

    public convenience init(connection: ArchiveReplicaConnection) {
        self.init(connection: connection, testProtocolClasses: [])
    }

    init(connection: ArchiveReplicaConnection, testProtocolClasses: [AnyClass]) {
        self.connection = connection
        replicaID = connection.replicaID

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        if !testProtocolClasses.isEmpty {
            configuration.protocolClasses = testProtocolClasses
        }

        transportPolicyForTesting = ArchiveTransportPolicySnapshot(
            cookiesDisabled: configuration.httpCookieStorage == nil
                && !configuration.httpShouldSetCookies,
            cacheDisabled: configuration.urlCache == nil,
            credentialStorageDisabled: configuration.urlCredentialStorage == nil,
            proxyDictionaryEmpty: configuration.connectionProxyDictionary?.isEmpty == true,
            waitsForConnectivity: configuration.waitsForConnectivity,
            requestTimeout: configuration.timeoutIntervalForRequest,
            resourceTimeout: configuration.timeoutIntervalForResource,
            usesEphemeralConfiguration: true
        )

        let transportDelegate = ArchiveBoundedSessionDelegate()
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

    public func headObject(digest: String) async throws -> Bool {
        try await head(pathKind: .object, digest: digest)
    }

    public func putObject(digest: String, data: Data) async throws {
        try await put(pathKind: .object, digest: digest, data: data)
    }

    public func getObject(digest: String) async throws -> Data {
        try await get(pathKind: .object, digest: digest)
    }

    public func headManifest(digest: String) async throws -> Bool {
        try await head(pathKind: .manifest, digest: digest)
    }

    public func putManifest(digest: String, data: Data) async throws {
        try await put(pathKind: .manifest, digest: digest, data: data)
    }

    public func getManifest(digest: String) async throws -> Data {
        try await get(pathKind: .manifest, digest: digest)
    }

    public func createReceipt(manifestDigest: String) async throws -> Data {
        let request = try makeDigestRequest(
            method: "PUT",
            pathKind: .receipt,
            digest: manifestDigest,
            body: Data()
        )
        let response = try await execute(request, successLimit: .receipt)
        guard response.statusCode == 200 || response.statusCode == 201 else {
            throw ArchiveReplicaBackendError.unexpectedStatus(response.statusCode)
        }
        return response.data
    }

    public func getReceipt(manifestDigest: String) async throws -> Data {
        let request = try makeDigestRequest(
            method: "GET",
            pathKind: .receipt,
            digest: manifestDigest
        )
        let response = try await execute(request, successLimit: .receipt)
        guard response.statusCode == 200 else {
            throw ArchiveReplicaBackendError.unexpectedStatus(response.statusCode)
        }
        return response.data
    }

    public func listMachines(cursor: String?, limit: Int) async throws -> ArchiveMachinePage {
        let request = try makePageRequest(
            path: "/v2/archive/machines",
            queryItems: pageQueryItems(cursor: cursor, limit: limit)
        )
        let response = try await execute(request, successLimit: .page)
        guard response.statusCode == 200 else {
            throw ArchiveReplicaBackendError.unexpectedStatus(response.statusCode)
        }
        do {
            return try ArchiveCanonicalJSON.decode(ArchiveMachinePage.self, from: response.data)
        } catch {
            throw ArchiveReplicaBackendError.invalidCanonicalResponse
        }
    }

    public func listReceipts(
        machineID: String,
        cursor: String?,
        limit: Int
    ) async throws -> ArchiveReceiptPage {
        guard UUID(uuidString: machineID)?.uuidString == machineID else {
            throw ArchiveReplicaBackendError.invalidRequest
        }
        var items = [URLQueryItem(name: "machine_id", value: machineID)]
        items.append(contentsOf: try pageQueryItems(cursor: cursor, limit: limit))
        let request = try makePageRequest(path: "/v2/archive/receipts", queryItems: items)
        let response = try await execute(request, successLimit: .page)
        guard response.statusCode == 200 else {
            throw ArchiveReplicaBackendError.unexpectedStatus(response.statusCode)
        }
        do {
            return try ArchiveCanonicalJSON.decode(ArchiveReceiptPage.self, from: response.data)
        } catch {
            throw ArchiveReplicaBackendError.invalidCanonicalResponse
        }
    }

    private func head(pathKind: DigestPathKind, digest: String) async throws -> Bool {
        let request = try makeDigestRequest(method: "HEAD", pathKind: pathKind, digest: digest)
        let response = try await execute(request, successLimit: pathKind.responseLimit)
        switch response.statusCode {
        case 200: return true
        case 404: return false
        default: throw ArchiveReplicaBackendError.unexpectedStatus(response.statusCode)
        }
    }

    private func put(pathKind: DigestPathKind, digest: String, data: Data) async throws {
        let request = try makeDigestRequest(
            method: "PUT",
            pathKind: pathKind,
            digest: digest,
            body: data
        )
        let response = try await execute(request, successLimit: pathKind.responseLimit)
        guard response.statusCode == 200 || response.statusCode == 201 else {
            throw ArchiveReplicaBackendError.unexpectedStatus(response.statusCode)
        }
    }

    private func get(pathKind: DigestPathKind, digest: String) async throws -> Data {
        let request = try makeDigestRequest(method: "GET", pathKind: pathKind, digest: digest)
        let response = try await execute(request, successLimit: pathKind.responseLimit)
        guard response.statusCode == 200 else {
            throw ArchiveReplicaBackendError.unexpectedStatus(response.statusCode)
        }
        return response.data
    }

    private func makeDigestRequest(
        method: String,
        pathKind: DigestPathKind,
        digest: String,
        body: Data? = nil
    ) throws -> URLRequest {
        guard ArchiveV2Hash.isValidSHA256(digest) else {
            throw ArchiveReplicaBackendError.invalidDigest
        }
        let url = connection.canonicalOrigin
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent(pathKind.pathComponent, isDirectory: true)
            .appendingPathComponent(digest, isDirectory: false)
        var request = authenticatedRequest(url: url, method: method)
        if let body {
            request.httpBody = body
            switch pathKind {
            case .object:
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            case .manifest:
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            case .receipt:
                break
            }
        }
        return request
    }

    private func makePageRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(
            url: connection.canonicalOrigin,
            resolvingAgainstBaseURL: false
        ) else {
            throw ArchiveReplicaBackendError.invalidRequest
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ArchiveReplicaBackendError.invalidRequest
        }
        return authenticatedRequest(url: url, method: "GET")
    }

    private func pageQueryItems(cursor: String?, limit: Int) throws -> [URLQueryItem] {
        guard (1...ArchiveV2ProtocolLimits.maxPageItems).contains(limit) else {
            throw ArchiveReplicaBackendError.invalidRequest
        }
        do {
            try ArchiveV2ProtocolLimits.validateCursor(cursor)
        } catch {
            throw ArchiveReplicaBackendError.invalidRequest
        }
        var items: [URLQueryItem] = []
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        return items
    }

    private func authenticatedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func execute(
        _ request: URLRequest,
        successLimit: ArchiveResponseLimitKind
    ) async throws -> ArchiveHTTPResponse {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
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
    }
}

private enum DigestPathKind {
    case object
    case manifest
    case receipt

    var pathComponent: String {
        switch self {
        case .object: "objects"
        case .manifest: "manifests"
        case .receipt: "receipts"
        }
    }

    var responseLimit: ArchiveResponseLimitKind {
        switch self {
        case .object: .object
        case .manifest: .manifest
        case .receipt: .receipt
        }
    }
}

private struct ArchiveHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

private final class ArchivePendingRequest: @unchecked Sendable {
    let expectedURL: String
    let method: String
    let successLimit: ArchiveResponseLimitKind
    let continuation: CheckedContinuation<ArchiveHTTPResponse, Error>
    var response: HTTPURLResponse?
    var data = Data()
    var failure: ArchiveReplicaBackendError?
    var redirectRejected = false

    init(
        expectedURL: URL?,
        method: String?,
        successLimit: ArchiveResponseLimitKind,
        continuation: CheckedContinuation<ArchiveHTTPResponse, Error>
    ) {
        self.expectedURL = expectedURL?.absoluteString ?? ""
        self.method = method ?? ""
        self.successLimit = successLimit
        self.continuation = continuation
    }
}

private final class ArchiveBoundedSessionDelegate: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private let lock = NSLock()
    private var pending: [Int: ArchivePendingRequest] = [:]

    func register(
        task: URLSessionDataTask,
        expectedURL: URL?,
        method: String?,
        successLimit: ArchiveResponseLimitKind,
        continuation: CheckedContinuation<ArchiveHTTPResponse, Error>
    ) {
        lock.lock()
        pending[task.taskIdentifier] = ArchivePendingRequest(
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
                let limitKind = (200...299).contains(http.statusCode)
                    ? state.successLimit
                    : ArchiveResponseLimitKind.error
                let limit = limitKind.byteLimit
                if state.method != "HEAD",
                   http.expectedContentLength > Int64(limit) {
                    state.failure = .responseTooLarge(limitKind)
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
            let limitKind = (200...299).contains(statusCode)
                ? state.successLimit
                : ArchiveResponseLimitKind.error
            let limit = limitKind.byteLimit
            if data.count > limit - state.data.count {
                state.failure = .responseTooLarge(limitKind)
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
            state.continuation.resume(throwing: ArchiveReplicaBackendError.redirectRejected)
            return
        }
        if let error {
            state.continuation.resume(throwing: Self.mapTransportError(error))
            return
        }
        guard let response = state.response else {
            state.continuation.resume(throwing: ArchiveReplicaBackendError.notHTTPResponse)
            return
        }
        state.continuation.resume(
            returning: ArchiveHTTPResponse(statusCode: response.statusCode, data: state.data)
        )
    }

    private static func mapTransportError(_ error: Error) -> ArchiveReplicaBackendError {
        let code = (error as? URLError)?.code
        switch code {
        case .cancelled:
            return .transport(.cancelled)
        case .timedOut:
            return .transport(.timedOut)
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .secureConnectionFailed,
             .appTransportSecurityRequiresSecureConnection:
            return .transport(.tls)
        default:
            return .transport(.network)
        }
    }
}

private extension ArchiveResponseLimitKind {
    var byteLimit: Int {
        switch self {
        case .object: ArchiveV2ProtocolLimits.maxObjectRawBytes
        case .manifest: ArchiveV2ProtocolLimits.maxManifestBytes
        case .receipt: ArchiveV2ProtocolLimits.maxReceiptBytes
        case .page: ArchiveV2ProtocolLimits.maxPageBytes
        case .error: ArchiveV2ProtocolLimits.maxErrorBytes
        }
    }
}
