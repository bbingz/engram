import Foundation
import CryptoKit
import Darwin
import EngramCoreRead
import EngramCoreWrite

public enum ServiceCapturePublicationConsumerError: Error, Equatable, Sendable {
    case notImplemented
    case invalidCredential
    case invalidResponse
    case responseTooLarge
    case transferBudgetExceeded
    case policyChanged
    case integrityMismatch
    case httpStatus(Int)
    case transportUnavailable
}

public enum ServiceCapturePublicationResult: Equatable, Sendable {
    case idle
    case busy
    case accepted(pages: Int, publications: Int)
}

public struct ServiceCapturePublicationConsumerHooks: Sendable {
    public var afterDownload: (@Sendable () async throws -> Void)?
    public var beforeAcceptance: (@Sendable () throws -> Void)?
    public var afterAcceptance: (@Sendable () throws -> Void)?

    public init(afterDownload: (@Sendable () async throws -> Void)? = nil,
                beforeAcceptance: (@Sendable () throws -> Void)? = nil,
                afterAcceptance: (@Sendable () throws -> Void)? = nil) {
        self.afterDownload = afterDownload
        self.beforeAcceptance = beforeAcceptance
        self.afterAcceptance = afterAcceptance
    }
}

/// Cold, bounded intake. It does not provision sources, parse, or run AI work.
public actor ServiceCapturePublicationConsumer {
    private let gate: ServiceWriterGate
    private let cas: ImmutableArchiveCAS
    private let configuration: @Sendable () -> ServiceCaptureIngestConfiguration?
    private let policy: @Sendable () -> ServiceCaptureIngestParserPolicy?
    private let credential: @Sendable (String) throws -> String?
    private let hooks: ServiceCapturePublicationConsumerHooks
    private var owned: Task<ServiceCapturePublicationResult, Error>?
    private var sealed = false

    public init(gate: ServiceWriterGate, cas: ImmutableArchiveCAS,
                configuration: @escaping @Sendable () -> ServiceCaptureIngestConfiguration?,
                policy: @escaping @Sendable () -> ServiceCaptureIngestParserPolicy?,
                credential: @escaping @Sendable (String) throws -> String?,
                hooks: ServiceCapturePublicationConsumerHooks = .init()) {
        self.gate = gate
        self.cas = cas
        self.configuration = configuration
        self.policy = policy
        self.credential = credential
        self.hooks = hooks
    }

    public func runOnce() async throws -> ServiceCapturePublicationResult {
        try Task.checkCancellation()
        guard !sealed else { return .idle }
        guard owned == nil else { return .busy }
        guard let settings = configuration(), let snapshot = policy(), !snapshot.enabledSources.isEmpty else {
            return .idle
        }
        guard !snapshot.parserRevision.isEmpty, snapshot.parserRevision.utf8.count <= 128,
              snapshot.parserRevision == snapshot.parserRevision.trimmingCharacters(in: .whitespacesAndNewlines),
              !snapshot.parserRevision.utf8.contains(0) else {
            throw ServiceCapturePublicationConsumerError.policyChanged
        }
        let work = PublicationIntakeWork(gate: gate, cas: cas, settings: settings, snapshot: snapshot,
            configuration: configuration, policy: policy, credential: credential, hooks: hooks)
        let task = Task {
            try await ServiceWriterGate.$preserveAcceptedWriteProducer.withValue(false) {
                try await work.run()
            }
        }
        owned = task
        defer { owned = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return result
    }

    public func stop() async {
        sealed = true
        guard let task = owned else { return }
        task.cancel()
        _ = try? await task.value
        owned = nil
    }
}

private struct PublicationIntakeWork: Sendable {
    let gate: ServiceWriterGate
    let cas: ImmutableArchiveCAS
    let settings: ServiceCaptureIngestConfiguration
    let snapshot: ServiceCaptureIngestParserPolicy
    let configuration: @Sendable () -> ServiceCaptureIngestConfiguration?
    let policy: @Sendable () -> ServiceCaptureIngestParserPolicy?
    let credential: @Sendable (String) throws -> String?
    let hooks: ServiceCapturePublicationConsumerHooks

    func run() async throws -> ServiceCapturePublicationResult {
        let token = try currentToken()
        let transport = PublicationHTTPTransport(timeout: settings.requestTimeout)
        defer { transport.stop() }
        var remaining = settings.maxRunBytes
        let capabilityBytes = try await fetch("/v2/archive/publication-capabilities",
            limit: CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes,
            token: token, transport: transport, remaining: &remaining)
        let capability = try ArchiveCanonicalJSON.decode(CollectorPublicationCapabilities.self, from: capabilityBytes)
        guard capability.serverID == settings.serverID else {
            throw ServiceCapturePublicationConsumerError.integrityMismatch
        }
        let loaded = try await gate.performReadCommand(name: "capturePublicationCheckpoint") { writer in
            try checkFences(token: token)
            return try writer.read { try CaptureIngestLedger.checkpoint($0, serverID: settings.serverID) }
        }
        var cursor = loaded.value
        var pageCount = 0
        var publications = 0
        while pageCount < settings.maxPages {
            try checkFences(token: token)
            let query = [URLQueryItem(name: "limit", value: String(settings.pageLimit))]
                + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            let pageBytes = try await fetch("/v2/archive/publications", query: query,
                limit: CollectorPublicationProtocolLimits.maxPageBytes,
                token: token, transport: transport, remaining: &remaining)
            let page = try ArchiveCanonicalJSON.decode(CollectorPublicationPage.self, from: pageBytes)
            try page.validate(after: cursor.map(CollectorPublicationCursor.decode), expectedServerID: settings.serverID)
            guard page.items.count <= settings.pageLimit else {
                throw ServiceCapturePublicationConsumerError.invalidResponse
            }
            var manifests: [ArchiveSourceManifest] = []
            for record in page.items {
                try record.ack.validate(against: record.publication, expectedServerID: settings.serverID)
                let digest = record.publication.manifestSHA256
                let bytes = try await fetch("/v2/archive/manifests/\(digest)", limit: ArchiveV2ProtocolLimits.maxManifestBytes,
                    token: token, transport: transport, remaining: &remaining)
                guard ArchiveV2Hash.sha256(bytes) == digest else {
                    throw ServiceCapturePublicationConsumerError.integrityMismatch
                }
                let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
                guard UUID(uuidString: manifest.machineID)?.uuidString == record.publication.machineID,
                      manifest.sessionID == nil, record.publication.representation == "exact-source-v1" else {
                    throw ServiceCapturePublicationConsumerError.integrityMismatch
                }
                var whole = SHA256()
                for chunk in manifest.chunks {
                    try checkFences(token: token)
                    let raw: Data
                    do {
                        // Durable CAS is the restart checkpoint for a partially
                        // transferred page. A cache hit still verifies bounded
                        // bytes, identity and digest; only absence may download.
                        raw = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
                    } catch ImmutableArchiveCASError.io(_, let code) where code == ENOENT {
                        guard chunk.rawByteCount <= Int64(remaining) else {
                            throw ServiceCapturePublicationConsumerError.transferBudgetExceeded
                        }
                        raw = try await fetch("/v2/archive/objects/\(chunk.rawSHA256)",
                            limit: Int(chunk.rawByteCount), token: token, transport: transport, remaining: &remaining)
                    }
                    guard raw.count == Int(chunk.rawByteCount), ArchiveV2Hash.sha256(raw) == chunk.rawSHA256 else {
                        throw ServiceCapturePublicationConsumerError.integrityMismatch
                    }
                    whole.update(data: raw)
                    try checkFences(token: token)
                    // Reuse the existing durable-publication path even on a
                    // hit: a verified read alone does not prove file/dir fsync.
                    _ = try cas.publishObject(raw: raw, expectedSHA256: chunk.rawSHA256)
                    try checkFences(token: token)
                }
                guard whole.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
                    throw ServiceCapturePublicationConsumerError.integrityMismatch
                }
                try checkFences(token: token)
                _ = try cas.publishManifest(bytes, expectedSHA256: digest)
                manifests.append(manifest)
            }
            try await hooks.afterDownload?()
            try checkFences(token: token)
            let requestedCursor = cursor
            let verifiedManifests = manifests
            _ = try await gate.performWriteCommand(name: "capturePublicationAccept") { writer in
                try checkFences(token: token)
                try writer.write { db in
                    try checkFences(token: token)
                    // Re-read verified CAS through its bounded public API. A
                    // failed fsync/publication or later corruption cannot move
                    // this page's transactional discovery cursor.
                    for (record, manifest) in zip(page.items, verifiedManifests) {
                        let bytes = try cas.readManifest(sha256: record.publication.manifestSHA256,
                            maximumByteCount: Int64(ArchiveV2ProtocolLimits.maxManifestBytes))
                        guard bytes == (try ArchiveCanonicalJSON.encode(manifest)) else {
                            throw ServiceCapturePublicationConsumerError.integrityMismatch
                        }
                        for chunk in manifest.chunks {
                            try checkFences(token: token)
                            let raw = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
                            guard raw.count == Int(chunk.rawByteCount) else {
                                throw ServiceCapturePublicationConsumerError.integrityMismatch
                            }
                        }
                    }
                    try hooks.beforeAcceptance?()
                    try checkFences(token: token)
                    // This only admits durable pending work. Source registry
                    // and epoch approval belong to the existing replay worker.
                    try CaptureIngestLedger.accept(db, page: page, requestedCursor: requestedCursor,
                        serverID: settings.serverID, parserRevision: snapshot.parserRevision)
                    try hooks.afterAcceptance?()
                    try checkFences(token: token)
                }
            }
            pageCount += 1
            publications += page.items.count
            cursor = page.afterCursor
            if !page.hasMore { break }
        }
        return .accepted(pages: pageCount, publications: publications)
    }

    private func currentToken() throws -> String {
        try Task.checkCancellation()
        guard configuration() == settings, let currentPolicy = policy(),
              currentPolicy.parserRevision.utf8.elementsEqual(snapshot.parserRevision.utf8),
              currentPolicy.enabledSources == snapshot.enabledSources else {
            throw ServiceCapturePublicationConsumerError.policyChanged
        }
        let value: String?
        do { value = try credential(settings.credentialID) }
        catch { throw ServiceCapturePublicationConsumerError.invalidCredential }
        guard let value, !value.isEmpty, value.utf8.count <= 4096,
              value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw ServiceCapturePublicationConsumerError.invalidCredential
        }
        return value
    }

    private func checkFences(token: String) throws {
        guard try currentToken() == token else { throw ServiceCapturePublicationConsumerError.policyChanged }
    }

    private func fetch(_ path: String, query: [URLQueryItem] = [], limit: Int, token: String,
                       transport: PublicationHTTPTransport, remaining: inout Int) async throws -> Data {
        try checkFences(token: token)
        guard remaining > 0 else { throw ServiceCapturePublicationConsumerError.transferBudgetExceeded }
        guard var parts = URLComponents(url: settings.baseURL, resolvingAgainstBaseURL: false) else {
            throw ServiceCapturePublicationConsumerError.invalidResponse
        }
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw ServiceCapturePublicationConsumerError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: settings.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        var retries = 0
        while true {
            try checkFences(token: token)
            guard remaining > 0 else { throw ServiceCapturePublicationConsumerError.transferBudgetExceeded }
            var failure = ServiceCapturePublicationConsumerError.transportUnavailable
            do {
                let response = try await transport.get(request, limit: min(limit, remaining))
                remaining -= response.data.count
                try checkFences(token: token)
                if response.status == 200 { return response.data }
                failure = .httpStatus(response.status)
                // Authentication, identity, redirect, content and storage
                // integrity failures are never made retryable here.
                guard [408, 429, 500, 502, 503, 504].contains(response.status) else { throw failure }
            } catch let partial as PublicationHTTPTransportFailure {
                // Failed attempts consume the same run budget: a peer cannot
                // send partial bodies repeatedly and reset the byte allowance.
                remaining -= partial.receivedByteCount
                try checkFences(token: token)
                failure = .transportUnavailable
            }
            guard retries < settings.retryCount else { throw failure }
            try await Task.sleep(nanoseconds: UInt64(100_000_000) << retries)
            retries += 1
        }
    }
}

private struct PublicationHTTPResponse: Sendable {
    let status: Int
    let data: Data
}

private struct PublicationHTTPTransportFailure: Error, Sendable {
    let receivedByteCount: Int
}

/// One bounded request at a time; no shared cookies, credentials, redirects,
/// URL cache, proxy configuration, or unbounded data(for:) buffering.
private final class PublicationHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var state: Pending?
    private var session: URLSession!

    private final class Pending {
        let url: URL?
        let limit: Int
        let completion: CheckedContinuation<PublicationHTTPResponse, Error>
        var response: HTTPURLResponse?
        var data = Data()
        var failure: ServiceCapturePublicationConsumerError?

        init(url: URL?, limit: Int, completion: CheckedContinuation<PublicationHTTPResponse, Error>) {
            self.url = url
            self.limit = limit
            self.completion = completion
        }
    }

    init(timeout: TimeInterval) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func stop() { session.invalidateAndCancel() }

    func get(_ request: URLRequest, limit: Int) async throws -> PublicationHTTPResponse {
        try Task.checkCancellation()
        let cancellation = PublicationRequestCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                state = Pending(url: request.url, limit: limit, completion: continuation)
                lock.unlock()
                // Register continuation before installing the cancellation
                // target, including cancellation that preceded registration.
                cancellation.install(task)
                task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        var cancel = false
        if let state {
            if let http = response as? HTTPURLResponse, http.url == state.url {
                state.response = http
                let limit = http.statusCode == 200 ? state.limit : min(state.limit, ArchiveV2ProtocolLimits.maxErrorBytes)
                if http.expectedContentLength > Int64(limit) {
                    state.failure = .responseTooLarge
                    cancel = true
                }
            } else {
                state.failure = .invalidResponse
                cancel = true
            }
        }
        lock.unlock()
        completionHandler(cancel ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var cancel = false
        if let state, state.failure == nil {
            let limit = state.response?.statusCode == 200 ? state.limit : min(state.limit, ArchiveV2ProtocolLimits.maxErrorBytes)
            if data.count > limit - state.data.count {
                state.failure = .responseTooLarge
                cancel = true
            } else { state.data.append(data) }
        }
        lock.unlock()
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        state?.failure = .invalidResponse
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = state
        state = nil
        lock.unlock()
        guard let pending else { return }
        if let failure = pending.failure { pending.completion.resume(throwing: failure) }
        else if (error as? URLError)?.code == .cancelled { pending.completion.resume(throwing: CancellationError()) }
        else if error != nil {
            pending.completion.resume(throwing: PublicationHTTPTransportFailure(receivedByteCount: pending.data.count))
        }
        else if let response = pending.response {
            pending.completion.resume(returning: .init(status: response.statusCode, data: pending.data))
        } else { pending.completion.resume(throwing: ServiceCapturePublicationConsumerError.invalidResponse) }
    }
}

private final class PublicationRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?

    func install(_ value: URLSessionDataTask) {
        lock.lock()
        task = value
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { value.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
}
