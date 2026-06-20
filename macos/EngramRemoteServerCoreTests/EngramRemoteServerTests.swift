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
}
