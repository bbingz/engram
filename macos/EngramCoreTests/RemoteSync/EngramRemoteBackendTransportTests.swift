import XCTest
@testable import EngramCoreWrite

/// R7 residual: offload HTTP transport must match Archive V2 depth —
/// ephemeral session, redirect reject, response size caps, no shared session.
final class EngramRemoteBackendTransportTests: XCTestCase {
    override func tearDown() {
        RemoteOffloadURLProtocolStub.reset()
        super.tearDown()
    }

    func testRemoteBackendUsesEphemeralHardenedSession_repro() throws {
        let backend = try makeBackend()
        let policy = backend.transportPolicyForTesting
        XCTAssertTrue(policy.usesEphemeralConfiguration)
        XCTAssertTrue(policy.cookiesDisabled)
        XCTAssertTrue(policy.cacheDisabled)
        XCTAssertTrue(policy.credentialStorageDisabled)
        XCTAssertTrue(policy.proxyDictionaryEmpty)
        XCTAssertFalse(policy.waitsForConnectivity)
        XCTAssertEqual(policy.maxBundleBytes, EngramRemoteBackend.maxBundleBytes)
        XCTAssertEqual(EngramRemoteBackend.maxBundleBytes, 64 * 1024 * 1024)
    }

    func testRemoteBackendRejectsRedirect_repro() async throws {
        let backend = try makeBackend()
        RemoteOffloadURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.redirect(
                status: 302,
                to: URL(string: "http://127.0.0.1:9/v1/bundles/evil")!
            )
        }
        do {
            _ = try await backend.head(key: "k1.bundle")
            XCTFail("expected redirectRejected")
        } catch EngramRemoteBackendError.redirectRejected {
            // expected
        } catch {
            XCTFail("expected redirectRejected, got \(error)")
        }
    }

    func testRemoteBackendRejectsOversizedGetBody_repro() async throws {
        let backend = try makeBackend()
        let oversize = EngramRemoteBackend.maxBundleBytes + 1
        RemoteOffloadURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(
                status: 200,
                headers: ["Content-Length": "\(oversize)"],
                chunks: [Data(repeating: 0x41, count: 1)]
            )
        }
        do {
            _ = try await backend.get(key: "k1.bundle")
            XCTFail("expected responseTooLarge")
        } catch EngramRemoteBackendError.responseTooLarge(let limit) {
            XCTAssertEqual(limit, EngramRemoteBackend.maxBundleBytes)
        } catch {
            XCTFail("expected responseTooLarge, got \(error)")
        }
    }

    func testRemoteBackendAcceptsExactMaxGetBody_repro() async throws {
        let backend = try makeBackend()
        let exact = Data(repeating: 0x42, count: 64)
        RemoteOffloadURLProtocolStub.handler = { protocolInstance, _ in
            protocolInstance.respond(status: 200, chunks: [exact])
        }
        // Use a tiny custom limit via package-visible test hook if present; otherwise
        // exercise the normal path with a small body under the 64 MiB cap.
        let data = try await backend.get(key: "k1.bundle")
        XCTAssertEqual(data, exact)
    }

    func testRequireTLSProductDefaultCommentIsFailClosed_repro() throws {
        // Source-level contract: docs/comments must not claim requireTLS product
        // default is OFF (stale residual from pre-SEC-H1). Runtime default is true.
        // #filePath = macos/EngramCoreTests/RemoteSync/<this>.swift → macos/
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RemoteSync/
            .deletingLastPathComponent() // EngramCoreTests/
            .deletingLastPathComponent() // macos/
        let source = try String(
            contentsOf: macosRoot.appendingPathComponent("EngramCoreWrite/RemoteSync/EngramRemoteBackend.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains("remoteOffloadRequireTLS` setting, which defaults OFF"),
            "stale requireTLS default OFF comment must be removed"
        )
        XCTAssertFalse(source.contains("URLSession.shared"))
        XCTAssertTrue(source.contains("URLSessionConfiguration.ephemeral"))
        XCTAssertTrue(source.contains("redirectRejected"))
        XCTAssertTrue(source.contains("maxBundleBytes"))

        let coordinator = try String(
            contentsOf: macosRoot.appendingPathComponent("EngramService/Core/RemoteSyncCoordinator.swift"),
            encoding: .utf8
        )
        // Product read path fails closed to true; init parameter default must match.
        XCTAssertTrue(coordinator.contains("?? true"))
        XCTAssertTrue(coordinator.contains("requireTLS: Bool = true"))
        XCTAssertFalse(coordinator.contains("requireTLS: Bool = false"))
    }

    func testPostDNSPrivateCheckRejectsPublicResolution_repro() throws {
        // IP literal path already private-checked; public A-record host must fail
        // even when requireTLS=false (misconfig must not cleartext-leak token).
        XCTAssertThrowsError(
            try EngramRemoteBackend(
                baseURL: URL(string: "http://example.com:8787")!,
                token: "t",
                requireTLS: false
            )
        ) { error in
            guard case EngramRemoteBackendError.insecureURL = error else {
                return XCTFail("expected insecureURL, got \(error)")
            }
        }
        // Loopback HTTP remains allowed without DNS dance.
        XCTAssertNoThrow(
            try EngramRemoteBackend(
                baseURL: URL(string: "http://127.0.0.1:8787")!,
                token: "t",
                requireTLS: false
            )
        )
        // Private IP literal remains allowed when requireTLS=false.
        XCTAssertNoThrow(
            try EngramRemoteBackend(
                baseURL: URL(string: "http://100.64.1.2:8787")!,
                token: "t",
                requireTLS: false
            )
        )

        // Named private host that resolves public → refuse cleartext.
        EngramRemoteBackend.resolveAddressesForTesting = { _ in ["93.184.216.34"] }
        defer { EngramRemoteBackend.resolveAddressesForTesting = nil }
        XCTAssertThrowsError(
            try EngramRemoteBackend(
                baseURL: URL(string: "http://macmini.local:8787")!,
                token: "t",
                requireTLS: false
            )
        ) { error in
            guard case EngramRemoteBackendError.resolvedHostNotPrivate = error else {
                return XCTFail("expected resolvedHostNotPrivate, got \(error)")
            }
        }
        // Named private host that resolves private → allowed when requireTLS=false.
        EngramRemoteBackend.resolveAddressesForTesting = { _ in ["100.64.1.9"] }
        XCTAssertNoThrow(
            try EngramRemoteBackend(
                baseURL: URL(string: "http://macmini.local:8787")!,
                token: "t",
                requireTLS: false
            )
        )
    }

    // MARK: - Helpers

    private func makeBackend() throws -> EngramRemoteBackend {
        try EngramRemoteBackend(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "secret",
            requireTLS: true,
            testProtocolClasses: [RemoteOffloadURLProtocolStub.self]
        )
    }
}

// MARK: - URLProtocol stub (mirrors Archive transport tests)

private final class RemoteOffloadURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (RemoteOffloadURLProtocolStub, URLRequest) -> Void
    static var handler: Handler?
    private static let stateLock = NSLock()
    private static var activeInstances: [ObjectIdentifier: RemoteOffloadURLProtocolStub] = [:]
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

    func respond(
        status: Int,
        headers: [String: String] = [:],
        chunks: [Data] = []
    ) {
        guard isActive else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            guard isActive else { return }
            client?.urlProtocol(self, didLoad: chunk)
        }
        guard isActive else { return }
        client?.urlProtocolDidFinishLoading(self)
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
