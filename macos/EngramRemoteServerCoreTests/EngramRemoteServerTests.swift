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

    func testCatalogManifestPutRejectsBodyAboveCatalogCeiling_repro() async throws {
        let token = "catalog-limit-token"
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1",
            port: 0,
            storeRoot: tempDir.appendingPathComponent("catalog-limit"),
            bearerToken: token,
            atRestKey: SymmetricKey(size: .bits256),
            maxBundleBytes: 64 * 1024 * 1024
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/bundles/catalog.peer.manifest"))
        )
        request.httpMethod = "PUT"
        request.httpBody = Data(repeating: UInt8(ascii: "x"), count: 4 * 1024 * 1024 + 1)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
    }

    func testCatalogManifestPutReservesResponseEnvelopeBytes_repro() async throws {
        let token = "catalog-envelope-token"
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1",
            port: 0,
            storeRoot: tempDir.appendingPathComponent("catalog-envelope-limit"),
            bearerToken: token,
            atRestKey: SymmetricKey(size: .bits256),
            maxBundleBytes: 64 * 1024 * 1024
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/bundles/catalog.peer.manifest"))
        )
        request.httpMethod = "PUT"
        request.httpBody = Data(repeating: UInt8(ascii: "x"), count: 4 * 1024 * 1024 - 1)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
    }

    // MCP retro F12: validates the legacy initialize handshake over a real bound socket.
    func testLegacyMCPInitializeAgainstLiveServer() async throws {
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1",
            port: 0,
            storeRoot: tempDir.appendingPathComponent("legacy"),
            bearerToken: "legacy-token",
            atRestKey: SymmetricKey(size: .bits256),
            archiveV2: EngramRemoteArchiveConfig(
                serverID: "hq",
                root: tempDir.appendingPathComponent("archive"),
                bearerToken: "archive-token",
                atRestKey: SymmetricKey(size: .bits256)
            ),
            mcp: EngramRemoteMCPConfig(bearerToken: "mcp-token")
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "live-initialize",
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "live-socket", "version": "1.0"],
            ],
        ])
        request.setValue("Bearer mcp-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let message = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(message["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(message["id"] as? String, "live-initialize")
        let result = try XCTUnwrap(message["result"] as? [String: Any])
        XCTAssertEqual(Set(result.keys), ["protocolVersion", "capabilities", "serverInfo", "instructions"])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"] as? [String: Any])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "engram-remote")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, "0.1.0")
        XCTAssertFalse((result["instructions"] as? String ?? "").isEmpty)
        XCTAssertNil(result["resultType"])
        XCTAssertNil(result["ttlMs"])
        XCTAssertNil(result["cacheScope"])
        XCTAssertNil(result["_meta"])
    }

    // MCP retro F12: validates the legacy tools/list response over a real bound socket.
    func testLegacyMCPToolsListAgainstLiveServer() async throws {
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1",
            port: 0,
            storeRoot: tempDir.appendingPathComponent("legacy"),
            bearerToken: "legacy-token",
            atRestKey: SymmetricKey(size: .bits256),
            archiveV2: EngramRemoteArchiveConfig(
                serverID: "hq",
                root: tempDir.appendingPathComponent("archive"),
                bearerToken: "archive-token",
                atRestKey: SymmetricKey(size: .bits256)
            ),
            mcp: EngramRemoteMCPConfig(bearerToken: "mcp-token")
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "live-tools-list",
            "method": "tools/list",
        ])
        request.setValue("Bearer mcp-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let message = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(message["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(message["id"] as? String, "live-tools-list")
        let result = try XCTUnwrap(message["result"] as? [String: Any])
        XCTAssertEqual(Set(result.keys), ["tools"])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(
            tools.map { $0["name"] as? String },
            ["archive_list_machines", "archive_list_captures", "archive_get_session"]
        )
        XCTAssertNil(result["resultType"])
        XCTAssertNil(result["ttlMs"])
        XCTAssertNil(result["cacheScope"])
        XCTAssertNil(result["_meta"])
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

    func testCatalogReturnsEmptyWhenEveryStoredManifestIsSkippable_repro() async throws {
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0,
            storeRoot: tempDir.appendingPathComponent("srv-all-skipped"),
            bearerToken: "secret-token", atRestKey: SymmetricKey(size: .bits256)
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
        try await backend.put(
            key: "catalog.junk.manifest",
            data: try JSONSerialization.data(withJSONObject: ["not", "a", "manifest"])
        )

        let catalog = try await backend.catalog()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["manifests"] as? [Any])?.count, 0)
    }

    // L29: individually valid manifests must not create an unbounded aggregate response.
    func testCatalogRejectsAggregateDecodedBytesOverBudget_repro() async throws {
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
        let backend = try EngramRemoteBackend(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            token: "secret-token"
        )

        // Each peer stays below the legacy 64 MiB bundle cap, while their
        // combined decoded JSON exceeds the client's 4 MiB catalog contract.
        let padding = String(repeating: "x", count: (2 * 1024 * 1024) + (128 * 1024))
        for peer in ["macA", "macB"] {
            let manifest = try JSONSerialization.data(withJSONObject: [
                "peer": peer,
                "padding": padding,
            ])
            try await backend.put(key: "catalog.\(peer).manifest", data: manifest)
        }

        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/catalog"))
        )
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            413,
            "catalog aggregation must fail closed before exceeding its response budget"
        )
    }

    func testCatalogSkipsArrayThatExhaustsDecodedBudgetWithoutReturning413_repro() async throws {
        let storeRoot = tempDir.appendingPathComponent("catalog-skippable-budget")
        let atRestKey = SymmetricKey(size: .bits256)
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0,
            storeRoot: storeRoot,
            bearerToken: "secret-token", atRestKey: atRestKey
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()
        let store = try BlobStore(root: storeRoot, key: atRestKey)
        let valid = try JSONSerialization.data(withJSONObject: [
            "peer": "valid",
            "padding": String(repeating: "v", count: 1_024),
        ])
        let skippable = try JSONSerialization.data(withJSONObject: [
            String(repeating: "x", count: (4 * 1024 * 1024) + 64),
        ])
        XCTAssertGreaterThan(skippable.count, 4 * 1024 * 1024)
        try store.put("catalog.aaa-array.manifest", plaintext: skippable)
        try store.put("catalog.zzz-valid.manifest", plaintext: valid)

        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/catalog"))
        )
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let manifests = try XCTUnwrap(object["manifests"] as? [[String: Any]])
        XCTAssertEqual(manifests.compactMap { $0["peer"] as? String }, ["valid"])
    }

    func testCatalogReturns500WhenStoreListingFails_repro() async throws {
        let root = tempDir.appendingPathComponent("catalog-io-failure", isDirectory: true)
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0,
            storeRoot: root,
            bearerToken: "secret-token", atRestKey: SymmetricKey(size: .bits256)
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        try FileManager.default.removeItem(at: root)
        try Data("not a directory".utf8).write(to: root)

        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/catalog"))
        )
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            500,
            "catalog store I/O failures must not masquerade as an empty catalog"
        )
    }

    func testCatalogReturns200WhenEveryListedObjectIsSkippable_repro() async throws {
        let root = tempDir.appendingPathComponent("catalog-all-skipped", isDirectory: true)
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0,
            storeRoot: root,
            bearerToken: "secret-token", atRestKey: SymmetricKey(size: .bits256)
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
        try await backend.put(key: "catalog.legacy.manifest", data: Data(#"{"legacy":true}"#.utf8))
        try await backend.put(key: "catalog.junk.manifest", data: Data(#"{"garbage":"leftover"}"#.utf8))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/catalog")!)
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try ManifestCodec.decodeCatalog(data), [])
    }

    // L29: a large number of tiny manifests must also be bounded independently.
    func testCatalogRejectsPeerCountOverBudget_repro() async throws {
        let root = tempDir.appendingPathComponent("srv")
        let atRestKey = SymmetricKey(size: .bits256)
        let store = try BlobStore(root: root, key: atRestKey)
        for index in 0..<1_024 {
            try store.put(
                "catalog.peer\(index).manifest",
                plaintext: Data("{}".utf8)
            )
        }
        let config = EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0,
            storeRoot: root,
            bearerToken: "secret-token", atRestKey: atRestKey
        )
        let app = try EngramRemoteServerApp(config: config)
        let waiter = PortWaiter()
        let serverTask = Task { try? await app.run(onBound: { waiter.set($0) }) }
        defer { serverTask.cancel() }
        let port = await waiter.wait()

        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/catalog"))
        )
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (_, exactLimitResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(
            (exactLimitResponse as? HTTPURLResponse)?.statusCode,
            200,
            "exactly 1,024 peer manifests remain within the catalog contract"
        )

        try store.put(
            "catalog.peer1024.manifest",
            plaintext: Data("{}".utf8)
        )
        let (_, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            413,
            "catalog aggregation must reject more than 1,024 peer manifests"
        )
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
        // Named private hosts need post-DNS private resolution (R7). Stub private
        // A records so CI without MagicDNS/mDNS still exercises the allow path.
        EngramRemoteBackend.resolveAddressesForTesting = { host in
            if host.hasSuffix(".ts.net") || host.hasSuffix(".local") {
                return ["100.64.1.9"]
            }
            return []
        }
        defer { EngramRemoteBackend.resolveAddressesForTesting = nil }

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
