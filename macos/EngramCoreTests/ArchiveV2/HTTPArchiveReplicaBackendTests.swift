import EngramCoreRead
@testable import EngramCoreWrite
import Foundation
import Security
import XCTest

final class HTTPArchiveReplicaBackendTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    override func setUp() {
        super.setUp()
        ArchiveURLProtocolStub.reset()
    }

    override func tearDown() {
        ArchiveURLProtocolStub.reset()
        super.tearDown()
    }

    func testReplicaSetRequiresExactlyHQAndM1WithDistinctOriginsAndTokens() throws {
        let loader = StubArchiveTokenLoader(tokens: ["hq": "hq-token", "m1": "m1-token"])
        let set = try ArchiveReplicaSet(
            descriptors: [
                .init(id: "m1", serverURL: "http://100.64.0.2:80/", requireTLS: false),
                .init(id: "hq", serverURL: "HTTPS://HQ.TAILNET.TS.NET:443", requireTLS: true),
            ],
            tokenLoader: loader
        )

        XCTAssertEqual(set.connections.map(\.replicaID), ["hq", "m1"])
        XCTAssertEqual(set.connections.map(\.canonicalOrigin.absoluteString), [
            "https://hq.tailnet.ts.net",
            "http://100.64.0.2",
        ])

        let invalidIDSets: [[ArchiveReplicaDescriptor]] = [
            [.init(id: "hq", serverURL: "https://hq.tailnet.ts.net", requireTLS: true)],
            [
                .init(id: "hq", serverURL: "https://hq.tailnet.ts.net", requireTLS: true),
                .init(id: "backup", serverURL: "https://m1.tailnet.ts.net", requireTLS: true),
            ],
            [
                .init(id: "hq", serverURL: "https://hq.tailnet.ts.net", requireTLS: true),
                .init(id: "m1", serverURL: "https://m1.tailnet.ts.net", requireTLS: true),
                .init(id: "third", serverURL: "https://third.tailnet.ts.net", requireTLS: true),
            ],
        ]
        for descriptors in invalidIDSets {
            XCTAssertThrowsError(
                try ArchiveReplicaSet(descriptors: descriptors, tokenLoader: loader)
            ) { error in
                XCTAssertEqual(error as? ArchiveReplicaConfigurationError, .invalidReplicaSet)
            }
        }

        XCTAssertThrowsError(
            try ArchiveReplicaSet(
                descriptors: [
                    .init(id: "hq", serverURL: "https://same.tailnet.ts.net", requireTLS: true),
                    .init(id: "m1", serverURL: "HTTPS://SAME.TAILNET.TS.NET:443/", requireTLS: true),
                ],
                tokenLoader: loader
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveReplicaConfigurationError, .duplicateOrigin)
        }
        XCTAssertThrowsError(
            try ArchiveReplicaSet(
                descriptors: [
                    .init(
                        id: "hq",
                        serverURL: "https://[fd7a:115c:a1e0::1]:443",
                        requireTLS: true
                    ),
                    .init(
                        id: "m1",
                        serverURL: "https://[fd7a:115c:a1e0:0:0:0:0:1]",
                        requireTLS: true
                    ),
                ],
                tokenLoader: loader
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveReplicaConfigurationError, .duplicateOrigin)
        }

        for tokens in [["hq": "", "m1": "m1"], ["hq": "same", "m1": "same"]] {
            XCTAssertThrowsError(
                try ArchiveReplicaSet(
                    descriptors: validDescriptors,
                    tokenLoader: StubArchiveTokenLoader(tokens: tokens)
                )
            )
        }
        XCTAssertThrowsError(
            try ArchiveReplicaSet(
                descriptors: validDescriptors,
                tokenLoader: StubArchiveTokenLoader(tokens: ["hq": "only-one"])
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveReplicaConfigurationError,
                .missingToken(replicaID: "m1")
            )
        }
    }

    func testOriginPolicyAcceptsOnlyStrictTailscaleOrigins() throws {
        let accepted: [(String, Bool, String)] = [
            ("https://node.tailnet-name.ts.net", true, "https://node.tailnet-name.ts.net"),
            ("https://100.127.255.255:8787", true, "https://100.127.255.255:8787"),
            ("http://100.64.0.1:8787", false, "http://100.64.0.1:8787"),
            ("http://[fd7a:115c:a1e0::1]:8787", false, "http://[fd7a:115c:a1e0::1]:8787"),
            ("https://[fd7a:115c:a1e0:0:0:0:0:1]:443", true, "https://[fd7a:115c:a1e0::1]"),
        ]
        for (raw, requireTLS, expected) in accepted {
            XCTAssertEqual(
                try ArchiveReplicaOrigin.canonicalURL(
                    raw,
                    requireTLS: requireTLS
                ).absoluteString,
                expected,
                raw
            )
        }

        let rejected = [
            "http://node.tailnet.ts.net",
            "https://example.com",
            "https://10.0.0.1",
            "https://172.16.0.1",
            "https://192.168.1.1",
            "https://169.254.1.1",
            "https://100.63.255.255",
            "https://100.128.0.1",
            "https://[fe80::1]",
            "https://[fd7a:115c:a1df:ffff::1]",
            "https://printer.local",
            "https://macmini",
            "https://*.tailnet.ts.net",
            "https://node.tailnet.ts.net.",
            "https://-node.tailnet.ts.net",
            "https://node_.tailnet.ts.net",
            "https://xn--node-9za.tailnet.ts.net",
            "https://nöde.tailnet.ts.net",
            "https://node%2etailnet.ts.net",
            "https://user:pass@node.tailnet.ts.net",
            "https://node.tailnet.ts.net/path",
            "https://node.tailnet.ts.net?query=1",
            "https://node.tailnet.ts.net#fragment",
            "https://[fd7a:115c:a1e0::1%25en0]",
            "ftp://node.tailnet.ts.net",
            "node.tailnet.ts.net",
            " https://node.tailnet.ts.net",
        ]
        for raw in rejected {
            XCTAssertThrowsError(
                try ArchiveReplicaOrigin.canonicalURL(raw, requireTLS: false),
                "Expected rejection for \(raw)"
            )
        }

        XCTAssertThrowsError(
            try ArchiveReplicaOrigin.canonicalURL("http://100.64.0.1", requireTLS: true)
        )
        XCTAssertThrowsError(
            try ArchiveReplicaOrigin.canonicalURL("http://127.0.0.1:8787", requireTLS: false)
        )
        XCTAssertEqual(
            try ArchiveReplicaOrigin.canonicalURL(
                "http://127.0.0.1:8787",
                requireTLS: false,
                allowLoopbackForTests: true
            ).absoluteString,
            "http://127.0.0.1:8787"
        )
    }

    func testBackendOwnsConstrainedEphemeralSession() throws {
        let backend = try makeBackend()
        let policy = backend.transportPolicyForTesting

        XCTAssertTrue(policy.cookiesDisabled)
        XCTAssertTrue(policy.cacheDisabled)
        XCTAssertTrue(policy.credentialStorageDisabled)
        XCTAssertTrue(policy.proxyDictionaryEmpty)
        XCTAssertFalse(policy.waitsForConnectivity)
        XCTAssertEqual(policy.requestTimeout, 30)
        XCTAssertEqual(policy.resourceTimeout, 120)
        XCTAssertTrue(policy.usesEphemeralConfiguration)
    }

    func testHEADIsTypedAndRequestsExactAuthenticatedV2Path() async throws {
        var requests: [URLRequest] = []
        ArchiveURLProtocolStub.handler = { protocolInstance, request in
            requests.append(request)
            protocolInstance.respond(status: request.url?.query == nil ? 200 : 500)
        }
        let backend = try makeBackend()

        let objectExists = try await backend.headObject(digest: digest)
        XCTAssertTrue(objectExists)
        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(status: 404)
        }
        let manifestExists = try await backend.headManifest(digest: digest)
        XCTAssertFalse(manifestExists)

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertEqual(request.url?.absoluteString, "https://hq.tailnet.ts.net/v2/archive/objects/\(digest)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hq-secret")
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testGETAndPUTAcceptOnlyFrozenStatusesAndNeverUseDelete() async throws {
        let payload = Data([0, 1, 2, 0xFF])
        var methods: [String] = []
        ArchiveURLProtocolStub.handler = { protocolInstance, request in
            methods.append(request.httpMethod ?? "")
            switch request.httpMethod {
            case "GET": protocolInstance.respond(status: 200, chunks: [payload])
            case "PUT":
                let putCount = methods.filter { $0 == "PUT" }.count
                protocolInstance.respond(status: putCount == 1 ? 201 : 200)
            default: protocolInstance.respond(status: 405)
            }
        }
        let backend = try makeBackend()

        try await backend.putObject(digest: digest, data: payload)
        let downloadedObject = try await backend.getObject(digest: digest)
        XCTAssertEqual(downloadedObject, payload)
        try await backend.putManifest(digest: digest, data: payload)
        let downloadedManifest = try await backend.getManifest(digest: digest)
        XCTAssertEqual(downloadedManifest, payload)

        XCTAssertFalse(methods.contains("DELETE"))

        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(status: 204)
        }
        await XCTAssertThrowsArchiveError(.unexpectedStatus(204)) {
            try await backend.putObject(digest: self.digest, data: payload)
        }
        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(status: 404)
        }
        await XCTAssertThrowsArchiveError(.unexpectedStatus(404)) {
            _ = try await backend.getObject(digest: self.digest)
        }
    }

    func testResponseStreamingAcceptsExactLimitAndCancelsAtLimitPlusOne() async throws {
        let exact = Data(repeating: 0x41, count: ArchiveV2ProtocolLimits.maxObjectRawBytes)
        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(status: 200, chunks: [exact])
        }
        let backend = try makeBackend()
        let downloaded = try await backend.getObject(digest: digest)
        XCTAssertEqual(downloaded, exact)

        let sentinelWasSent = LockedBox(false)
        let stoppedBeforeSentinel = expectation(description: "transport cancelled before sentinel")
        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.startResponse(status: 200)
            protocolInstance.send(Data(repeating: 0x42, count: ArchiveV2ProtocolLimits.maxObjectRawBytes))
            protocolInstance.send(Data([0x43]))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                if protocolInstance.sendIfActive(Data("SENTINEL".utf8)) {
                    sentinelWasSent.set(true)
                } else {
                    stoppedBeforeSentinel.fulfill()
                }
            }
        }

        await XCTAssertThrowsArchiveError(.responseTooLarge(.object)) {
            _ = try await backend.getObject(digest: self.digest)
        }
        await fulfillment(of: [stoppedBeforeSentinel], timeout: 1)
        XCTAssertFalse(sentinelWasSent.value)
    }

    func testContentLengthPreflightIsBoundedButHEADIgnoresEntityLength() async throws {
        let backend = try makeBackend()
        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(
                status: 200,
                headers: ["Content-Length": "\(ArchiveV2ProtocolLimits.maxManifestBytes + 1)"]
            )
        }
        await XCTAssertThrowsArchiveError(.responseTooLarge(.manifest)) {
            _ = try await backend.getManifest(digest: self.digest)
        }

        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(
                status: 200,
                headers: ["Content-Length": "\(ArchiveV2ProtocolLimits.maxObjectRawBytes)"]
            )
        }
        let exists = try await backend.headObject(digest: digest)
        XCTAssertTrue(exists)
    }

    func testErrorBodiesUseErrorLimitAndErrorsRemainRedacted() async throws {
        let backend = try makeBackend()
        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(
                status: 409,
                chunks: [Data(repeating: 0x41, count: ArchiveV2ProtocolLimits.maxErrorBytes + 1)]
            )
        }
        await XCTAssertThrowsArchiveError(.responseTooLarge(.error)) {
            _ = try await backend.getReceipt(manifestDigest: self.digest)
        }

        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(status: 409, chunks: [Data("TOP-SECRET-BODY".utf8)])
        }
        do {
            _ = try await backend.getReceipt(manifestDigest: digest)
            XCTFail("Expected status failure")
        } catch {
            XCTAssertEqual(error as? ArchiveReplicaBackendError, .unexpectedStatus(409))
            let rendered = String(reflecting: error)
            XCTAssertFalse(rendered.contains("hq-secret"))
            XCTAssertFalse(rendered.contains("TOP-SECRET-BODY"))
            XCTAssertFalse(rendered.contains("tailnet.ts.net"))
        }
    }

    func testRedirectIsRejectedBeforeTargetReceivesRequestOrAuthorization() async throws {
        let targetRequests = LockedBox([URLRequest]())
        ArchiveURLProtocolStub.handler = { protocolInstance, request in
            if request.url?.host == "m1.tailnet.ts.net" {
                targetRequests.withValue { $0.append(request) }
                protocolInstance.respond(status: 200, chunks: [Data("leaked".utf8)])
                return
            }
            protocolInstance.redirect(
                status: 307,
                to: URL(string: "https://m1.tailnet.ts.net/v2/archive/objects/\(self.digest)")!
            )
        }
        let backend = try makeBackend()

        await XCTAssertThrowsArchiveError(.redirectRejected) {
            _ = try await backend.getObject(digest: self.digest)
        }
        XCTAssertTrue(targetRequests.value.isEmpty)
    }

    func testFinalResponseURLMustExactlyMatchRequestedEndpoint() async throws {
        let backend = try makeBackend()
        ArchiveURLProtocolStub.handler = { protocolInstance, request in
            let wrongURL = URL(string: "https://hq.tailnet.ts.net/v2/archive/objects/\(self.digest)?wrong=1")!
            protocolInstance.respond(status: 200, responseURL: wrongURL, chunks: [Data()])
        }

        await XCTAssertThrowsArchiveError(.finalURLMismatch) {
            _ = try await backend.getObject(digest: self.digest)
        }
    }

    func testUnknownCertificateRootIsClassifiedAsTLSTrustFailure() async throws {
        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.fail(URLError(.serverCertificateHasUnknownRoot))
        }
        let backend = try makeBackend()

        await XCTAssertThrowsArchiveError(.transport(.tls)) {
            _ = try await backend.getObject(digest: self.digest)
        }
    }

    func testReceiptAndPagesAreStrictCanonicalAndUseTheirBodyLimits() async throws {
        let backend = try makeBackend()
        let machineID = "123E4567-E89B-12D3-A456-426614174000"
        let receipt = try ArchiveServerReceipt(
            serverID: "hq",
            machineID: machineID,
            sessionID: "session-1",
            captureID: String(repeating: "b", count: 64),
            manifestSHA256: digest,
            wholeSourceSHA256: String(repeating: "c", count: 64),
            objectCount: 1,
            rawByteCount: 1,
            storedAt: "2026-07-11T00:01:00.000Z"
        )
        let receiptBytes = try ArchiveCanonicalJSON.encode(receipt)
        let machinePage = try ArchiveMachinePage(machineIDs: [machineID], nextCursor: nil)
        let machineBytes = try ArchiveCanonicalJSON.encode(machinePage)
        let summary = try ArchiveReceiptSummary(
            manifestSHA256: digest,
            receiptSHA256: ArchiveV2Hash.sha256(receiptBytes)
        )
        let receiptPage = try ArchiveReceiptPage(receipts: [summary], nextCursor: nil)
        let pageBytes = try ArchiveCanonicalJSON.encode(receiptPage)

        ArchiveURLProtocolStub.handler = { protocolInstance, request in
            let path = request.url?.path ?? ""
            if path == "/v2/archive/machines" {
                protocolInstance.respond(status: 200, chunks: [machineBytes])
            } else if path == "/v2/archive/receipts" {
                protocolInstance.respond(status: 200, chunks: [pageBytes])
            } else if request.httpMethod == "PUT" {
                protocolInstance.respond(status: 201)
            } else {
                protocolInstance.respond(status: 200, chunks: [receiptBytes])
            }
        }

        _ = try await backend.createReceipt(manifestDigest: digest)
        let downloadedReceipt = try await backend.getReceipt(manifestDigest: digest)
        XCTAssertEqual(downloadedReceipt, receiptBytes)
        let downloadedMachinePage = try await backend.listMachines(cursor: nil, limit: 50)
        XCTAssertEqual(downloadedMachinePage, machinePage)
        let downloadedReceiptPage = try await backend.listReceipts(
            machineID: machineID,
            cursor: nil,
            limit: 50
        )
        XCTAssertEqual(
            downloadedReceiptPage,
            receiptPage
        )

        var nonCanonical = Data(" ".utf8)
        nonCanonical.append(machineBytes)
        ArchiveURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(status: 200, chunks: [nonCanonical])
        }
        await XCTAssertThrowsArchiveError(.invalidCanonicalResponse) {
            _ = try await backend.listMachines(cursor: nil, limit: 50)
        }
    }

    func testCredentialStoreUsesIsolatedNamespaceAndUpdateFirstWithoutDelete() throws {
        let operations = RecordingArchiveKeychainOperations()
        operations.updateStatuses = [errSecItemNotFound]
        operations.addStatuses = [errSecSuccess]
        let store = ArchiveCredentialStore(operations: operations)

        try store.saveToken("new-token", replicaID: "hq")

        XCTAssertEqual(operations.events, [
            .update(service: "com.engram.remote-archive-v2", account: "replica:hq"),
            .add(service: "com.engram.remote-archive-v2", account: "replica:hq"),
        ])
        XCTAssertFalse(operations.events.contains { event in
            if case .delete = event { return true }
            return false
        })
    }

    func testCredentialStoreRetriesUpdateOnDuplicateAddRaceAndNeverTouchesV1() throws {
        let operations = RecordingArchiveKeychainOperations()
        operations.updateStatuses = [errSecItemNotFound, errSecSuccess]
        operations.addStatuses = [errSecDuplicateItem]
        operations.copyResult = (errSecSuccess, Data("loaded-token".utf8))
        let store = ArchiveCredentialStore(operations: operations)

        try store.saveToken("replacement", replicaID: "m1")
        XCTAssertEqual(try store.loadToken(replicaID: "m1"), "loaded-token")
        XCTAssertEqual(operations.events.map(\.operation), ["update", "add", "update", "copy"])
        XCTAssertTrue(operations.events.allSatisfy { $0.service == "com.engram.remote-archive-v2" })
        XCTAssertTrue(operations.events.allSatisfy { $0.account == "replica:m1" })
    }

    private var validDescriptors: [ArchiveReplicaDescriptor] {
        [
            .init(id: "hq", serverURL: "https://hq.tailnet.ts.net", requireTLS: true),
            .init(id: "m1", serverURL: "https://m1.tailnet.ts.net", requireTLS: true),
        ]
    }

    private func makeBackend() throws -> HTTPArchiveReplicaBackend {
        let set = try ArchiveReplicaSet(
            descriptors: validDescriptors,
            tokenLoader: StubArchiveTokenLoader(tokens: ["hq": "hq-secret", "m1": "m1-secret"])
        )
        return HTTPArchiveReplicaBackend(
            connection: try XCTUnwrap(set.connections.first { $0.replicaID == "hq" }),
            testProtocolClasses: [ArchiveURLProtocolStub.self]
        )
    }

    private func XCTAssertThrowsArchiveError<T>(
        _ expected: ArchiveReplicaBackendError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ArchiveReplicaBackendError, expected, file: file, line: line)
        }
    }
}

private struct StubArchiveTokenLoader: ArchiveReplicaTokenLoading {
    let tokens: [String: String]

    func loadToken(replicaID: String) throws -> String? {
        tokens[replicaID]
    }
}

private final class ArchiveURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (ArchiveURLProtocolStub, URLRequest) -> Void
    static var handler: Handler?
    private static let stateLock = NSLock()
    private static var activeInstances: [ObjectIdentifier: ArchiveURLProtocolStub] = [:]

    private let lock = NSLock()
    private var stopped = false

    static func reset() {
        stateLock.lock()
        let instances = Array(activeInstances.values)
        activeInstances.removeAll()
        handler = nil
        stateLock.unlock()
        for instance in instances { instance.stopLoading() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock()
        Self.activeInstances[ObjectIdentifier(self)] = self
        let handler = Self.handler
        Self.stateLock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        handler(self, request)
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
        Self.stateLock.lock()
        Self.activeInstances.removeValue(forKey: ObjectIdentifier(self))
        Self.stateLock.unlock()
    }

    func startResponse(
        status: Int,
        responseURL: URL? = nil,
        headers: [String: String] = [:]
    ) {
        guard isActive else { return }
        let response = HTTPURLResponse(
            url: responseURL ?? request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(_ data: Data) {
        guard isActive else { return }
        client?.urlProtocol(self, didLoad: data)
    }

    @discardableResult
    func sendIfActive(_ data: Data) -> Bool {
        guard isActive else { return false }
        client?.urlProtocol(self, didLoad: data)
        return true
    }

    func finish() {
        guard isActive else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: Error) {
        guard isActive else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    func respond(
        status: Int,
        responseURL: URL? = nil,
        headers: [String: String] = [:],
        chunks: [Data] = []
    ) {
        startResponse(status: status, responseURL: responseURL, headers: headers)
        for chunk in chunks { send(chunk) }
        finish()
    }

    func redirect(status: Int, to target: URL) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        )!
        var redirected = request
        redirected.url = target
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        client?.urlProtocolDidFinishLoading(self)
    }

    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

private final class RecordingArchiveKeychainOperations: ArchiveCredentialKeychainOperations, @unchecked Sendable {
    enum Event: Equatable {
        case update(service: String, account: String)
        case add(service: String, account: String)
        case copy(service: String, account: String)
        case delete(service: String, account: String)

        var operation: String {
            switch self {
            case .update: "update"
            case .add: "add"
            case .copy: "copy"
            case .delete: "delete"
            }
        }

        var service: String {
            switch self {
            case let .update(service, _), let .add(service, _),
                 let .copy(service, _), let .delete(service, _): service
            }
        }

        var account: String {
            switch self {
            case let .update(_, account), let .add(_, account),
                 let .copy(_, account), let .delete(_, account): account
            }
        }
    }

    var updateStatuses: [OSStatus] = []
    var addStatuses: [OSStatus] = []
    var copyResult: (OSStatus, Data?) = (errSecItemNotFound, nil)
    private(set) var events: [Event] = []

    func update(service: String, account: String, value: Data) -> OSStatus {
        events.append(.update(service: service, account: account))
        return updateStatuses.isEmpty ? errSecSuccess : updateStatuses.removeFirst()
    }

    func add(service: String, account: String, value: Data) -> OSStatus {
        events.append(.add(service: service, account: account))
        return addStatuses.isEmpty ? errSecSuccess : addStatuses.removeFirst()
    }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        events.append(.copy(service: service, account: account))
        return copyResult
    }
}
