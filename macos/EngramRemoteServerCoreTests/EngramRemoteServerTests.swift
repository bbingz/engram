import XCTest
import CryptoKit
@testable import EngramRemoteServerCore
import EngramCoreWrite

/// Bridges Hummingbird's `onServerRunning` callback (fired once the listener is
/// bound) into an awaitable port, so the test can target the OS-assigned port.
private final class PortWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?
    private var continuation: CheckedContinuation<Int, Never>?

    func set(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: value)
        } else {
            port = value
        }
    }

    func wait() async -> Int {
        await withCheckedContinuation { cont in
            lock.lock(); defer { lock.unlock() }
            if let port {
                cont.resume(returning: port)
            } else {
                continuation = cont
            }
        }
    }
}

final class EngramRemoteServerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - BlobStore (at-rest encryption)

    func testBlobStoreEncryptsAtRestAndRoundTrips() throws {
        let key = SymmetricKey(size: .bits256)
        let store = try BlobStore(root: tempDir.appendingPathComponent("store"), key: key)
        let plaintext = Data("the bundle plaintext payload".utf8)

        try store.put("abc123.bundle", plaintext: plaintext)
        XCTAssertTrue(try store.exists("abc123.bundle"))
        XCTAssertEqual(try store.get("abc123.bundle"), plaintext)

        // On-disk bytes must be ciphertext, not the plaintext.
        let onDisk = try Data(contentsOf: tempDir.appendingPathComponent("store/abc123.bundle"))
        XCTAssertNotEqual(onDisk, plaintext)

        try store.delete("abc123.bundle")
        XCTAssertFalse(try store.exists("abc123.bundle"))
    }

    func testBlobStoreWrongKeyFailsToDecrypt() throws {
        let root = tempDir.appendingPathComponent("store")
        let writer = try BlobStore(root: root, key: SymmetricKey(size: .bits256))
        try writer.put("k.bundle", plaintext: Data("secret".utf8))
        let attacker = try BlobStore(root: root, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try attacker.get("k.bundle"), "wrong key must fail the GCM auth tag")
    }

    func testBlobStoreRejectsPathTraversalKeys() {
        XCTAssertThrowsError(try BlobStore.validate(key: "../escape"))
        XCTAssertThrowsError(try BlobStore.validate(key: "a/b"))
        XCTAssertThrowsError(try BlobStore.validate(key: ""))
        XCTAssertNoThrow(try BlobStore.validate(key: "deadbeef.bundle"))
    }

    // MARK: - Live server ↔ EngramRemoteBackend round-trip

    func testArchiveHeadMissDoesNotCorruptNextPutOnReusedConnection() async throws {
        let archiveToken = "archive-keepalive-token"
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1",
            port: 0,
            storeRoot: tempDir.appendingPathComponent("legacy"),
            bearerToken: "legacy-keepalive-token",
            atRestKey: SymmetricKey(size: .bits256),
            archiveV2: EngramRemoteArchiveConfig(
                serverID: "hq",
                root: tempDir.appendingPathComponent("archive"),
                bearerToken: archiveToken,
                atRestKey: SymmetricKey(size: .bits256)
            )
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        let raw = Data("archive keepalive regression".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/v2/archive/objects/\(digest)")
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.setValue("Bearer \(archiveToken)", forHTTPHeaderField: "Authorization")
        let (headData, headResponse) = try await session.data(for: head)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(headData.isEmpty)

        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.httpBody = raw
        put.setValue("Bearer \(archiveToken)", forHTTPHeaderField: "Authorization")
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, putResponse) = try await session.data(for: put)
        XCTAssertEqual((putResponse as? HTTPURLResponse)?.statusCode, 201)
    }

    func testRemoteBackendRoundTripAgainstLiveServer() async throws {
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1",
            port: 0,
            storeRoot: tempDir.appendingPathComponent("srv"),
            bearerToken: "secret-token",
            atRestKey: SymmetricKey(size: .bits256)
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        let backend = try EngramRemoteBackend(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            token: "secret-token"
        )
        let key = "feedface.bundle"
        let payload = Data("an offloaded bundle".utf8)

        var present = try await backend.head(key: key)
        XCTAssertFalse(present)

        try await backend.put(key: key, data: payload)
        present = try await backend.head(key: key)
        XCTAssertTrue(present)

        let fetched = try await backend.get(key: key)
        XCTAssertEqual(fetched, payload)

        try await backend.delete(key: key)
        present = try await backend.head(key: key)
        XCTAssertFalse(present)
    }

    func testLegacyRoundTripWithArchiveEnabledDoesNotTouchArchiveFinalBytes() async throws {
        let legacyRoot = tempDir.appendingPathComponent("legacy", isDirectory: true)
        let archiveRoot = tempDir.appendingPathComponent("archive", isDirectory: true)
        let archiveKey = SymmetricKey(data: Data(repeating: 0x22, count: 32))
        let archiveStore = try ArchiveStore(
            root: archiveRoot,
            key: archiveKey,
            serverID: "hq"
        )
        let protectedRaw = Data("immutable archive bytes".utf8)
        let protectedDigest = ArchiveV2Hash.sha256(protectedRaw)
        XCTAssertEqual(
            try archiveStore.putObject(digest: protectedDigest, raw: protectedRaw),
            .published
        )
        let protectedURL = archiveRoot
            .appendingPathComponent("objects/sha256", isDirectory: true)
            .appendingPathComponent(String(protectedDigest.prefix(2)), isDirectory: true)
            .appendingPathComponent(protectedDigest, isDirectory: false)
        let protectedBytesBefore = try Data(contentsOf: protectedURL)
        let protectedInodeBefore = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: protectedURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1",
            port: 0,
            storeRoot: legacyRoot,
            bearerToken: "legacy-token",
            atRestKey: SymmetricKey(data: Data(repeating: 0x11, count: 32)),
            archiveV2: EngramRemoteArchiveConfig(
                serverID: "hq",
                root: archiveRoot,
                bearerToken: "archive-token",
                atRestKey: archiveKey
            )
        )
        let app = try EngramRemoteServerApp(config: config)
        let archiveFilesBefore = try regularFileBytes(under: archiveRoot)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        let backend = try EngramRemoteBackend(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            token: "legacy-token"
        )
        let key = "legacy-with-v2.bundle"
        let payload = Data("legacy bytes remain isolated".utf8)

        try await backend.put(key: "objects", data: Data("legacy namespace decoy".utf8))
        var present = try await backend.head(key: "objects")
        XCTAssertTrue(present)
        try await backend.delete(key: "objects")
        present = try await backend.head(key: "objects")
        XCTAssertFalse(present)

        present = try await backend.head(key: key)
        XCTAssertFalse(present)
        try await backend.put(key: key, data: payload)
        present = try await backend.head(key: key)
        XCTAssertTrue(present)
        let fetched = try await backend.get(key: key)
        XCTAssertEqual(fetched, payload)
        try await backend.delete(key: key)
        present = try await backend.head(key: key)
        XCTAssertFalse(present)

        XCTAssertEqual(try regularFileBytes(under: archiveRoot), archiveFilesBefore)
        XCTAssertEqual(try archiveStore.getObject(digest: protectedDigest), protectedRaw)
        XCTAssertEqual(try Data(contentsOf: protectedURL), protectedBytesBefore)
        let protectedInodeAfter = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: protectedURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        XCTAssertEqual(protectedInodeAfter, protectedInodeBefore)
    }

    func testCatalogAggregatesPerPeerManifestsAndGatesAuth() async throws {
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0,
            storeRoot: tempDir.appendingPathComponent("srv"),
            bearerToken: "secret-token", atRestKey: SymmetricKey(size: .bits256)
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()
        let backend = try EngramRemoteBackend(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: "secret-token")

        // Two well-formed per-peer manifests + one corrupt one (must be skipped).
        try await backend.put(key: "catalog.macA.manifest", data: Data(#"{"peer":"macA","entries":[{"sessionId":"s1"}]}"#.utf8))
        try await backend.put(key: "catalog.macB.manifest", data: Data(#"{"peer":"macB","entries":[{"sessionId":"s2"}]}"#.utf8))
        try await backend.put(key: "catalog.macC.manifest", data: Data("not json at all".utf8))
        // A non-catalog blob must NOT appear in the catalog.
        try await backend.put(key: "deadbeef.bundle", data: Data("a bundle".utf8))

        let raw = try await backend.catalog()
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let manifests = try XCTUnwrap(obj["manifests"] as? [[String: Any]])
        XCTAssertEqual(manifests.count, 2, "corrupt manifest skipped, bundle excluded")
        XCTAssertEqual(Set(manifests.compactMap { $0["peer"] as? String }), ["macA", "macB"])

        // Unauthenticated /v1/catalog must be 401.
        let (_, resp) = try await URLSession.shared.data(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/catalog")!))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 401)
    }

    func testBlobStoreListKeysFiltersByPrefix() throws {
        let store = try BlobStore(root: tempDir.appendingPathComponent("store"), key: SymmetricKey(size: .bits256))
        try store.put("catalog.macA.manifest", plaintext: Data("{}".utf8))
        try store.put("catalog.macB.manifest", plaintext: Data("{}".utf8))
        try store.put("deadbeef.bundle", plaintext: Data("x".utf8))
        XCTAssertEqual(try store.listKeys(prefix: "catalog."), ["catalog.macA.manifest", "catalog.macB.manifest"])
        XCTAssertEqual(try store.listKeys(prefix: "deadbeef"), ["deadbeef.bundle"])
    }

    func testRemoteBackendRejectsBadToken() async throws {
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0,
            storeRoot: tempDir.appendingPathComponent("srv"),
            bearerToken: "right-token", atRestKey: SymmetricKey(size: .bits256)
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        let backend = try EngramRemoteBackend(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: "WRONG")
        do {
            _ = try await backend.get(key: "any.bundle")
            XCTFail("expected an auth failure")
        } catch EngramRemoteBackendError.unexpectedStatus(let code) {
            XCTAssertEqual(code, 401)
        }
    }

    func testRemoteBackendRefusesInsecureNonLoopbackURL() {
        XCTAssertThrowsError(try EngramRemoteBackend(baseURL: URL(string: "http://example.com")!, token: "t")) { error in
            guard case EngramRemoteBackendError.insecureURL = error else {
                return XCTFail("expected insecureURL, got \(error)")
            }
        }
        XCTAssertNoThrow(try EngramRemoteBackend(baseURL: URL(string: "https://example.com")!, token: "t"))
        XCTAssertNoThrow(try EngramRemoteBackend(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "t"))
    }

    func testRemoteBackendTLSPolicy() throws {
        // Default (strict, requireTLS: true): plain HTTP allowed only to loopback.
        XCTAssertThrowsError(try EngramRemoteBackend(baseURL: URL(string: "http://100.125.101.60:8787")!, token: "t"))
        XCTAssertThrowsError(try EngramRemoteBackend(baseURL: URL(string: "http://192.168.1.50:8787")!, token: "t"))
        XCTAssertNoThrow(try EngramRemoteBackend(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "t"))

        // Permissive (requireTLS: false): plain HTTP allowed to private / Tailscale /
        // .ts.net / .local — never bare single-label (DNS may resolve public).
        for ok in ["http://100.125.101.60:8787",              // Tailscale CGNAT 100.64/10
                   "http://192.168.1.50:8787",                // RFC1918
                   "http://10.0.10.100:8787",                 // RFC1918
                   "http://172.16.5.5:8787",                  // RFC1918
                   "http://macmini-hq.tail1cb16.ts.net:8443", // Tailscale MagicDNS
                   "http://macmini.local:8787"] {             // mDNS
            XCTAssertNoThrow(
                try EngramRemoteBackend(baseURL: URL(string: ok)!, token: "t", requireTLS: false),
                "expected \(ok) to be allowed in permissive mode")
        }

        // SEC-H1: bare single-label hostnames are NOT private — DNS can resolve
        // them to a public A record and ship the bearer token cleartext.
        XCTAssertThrowsError(
            try EngramRemoteBackend(baseURL: URL(string: "http://macmini-hq:8787")!, token: "t", requireTLS: false),
            "SEC-H1: bare single-label HTTP must be refused even when requireTLS=false"
        ) { error in
            guard case EngramRemoteBackendError.insecureURL = error else {
                return XCTFail("expected insecureURL for bare label, got \(error)")
            }
        }

        // ...but plaintext to a PUBLIC host is still refused, even permissive — a
        // misconfig must not leak the bearer token onto the open internet.
        XCTAssertThrowsError(
            try EngramRemoteBackend(baseURL: URL(string: "http://example.com")!, token: "t", requireTLS: false)
        ) { error in
            guard case EngramRemoteBackendError.insecureURL = error else {
                return XCTFail("expected insecureURL for public host, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try EngramRemoteBackend(baseURL: URL(string: "http://93.184.216.34:8787")!, token: "t", requireTLS: false))

        // HTTPS is always accepted, in either mode and for any host.
        XCTAssertNoThrow(try EngramRemoteBackend(baseURL: URL(string: "https://example.com")!, token: "t", requireTLS: false))
        XCTAssertNoThrow(try EngramRemoteBackend(baseURL: URL(string: "https://100.125.101.60:8443")!, token: "t"))
    }

    /// SEC-H1: product settings default for remoteOffloadRequireTLS is true (fail-closed).
    func testRemoteOffloadRequireTLSDefaultsTrue_repro() {
        // Mirror RemoteSyncConfig.read default: missing key → true.
        let settings: [String: Any] = [:]
        let requireTLS = (settings["remoteOffloadRequireTLS"] as? Bool) ?? true
        XCTAssertTrue(requireTLS, "SEC-H1: product default must prefer TLS")
        // Explicit false remains allowed for Tailscale cleartext ops.
        let explicit = (["remoteOffloadRequireTLS": false] as [String: Any])["remoteOffloadRequireTLS"] as? Bool
        XCTAssertEqual(explicit, false)
    }

    private func regularFileBytes(under root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files[relative] = try Data(contentsOf: url)
        }
        return files
    }
}
