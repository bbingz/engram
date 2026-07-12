import EngramCoreRead
@testable import EngramCoreWrite
import Foundation
import XCTest

final class ArchiveCASEvictorTests: XCTestCase {
    private enum Marker: Error { case stop }
    private let machineID = "11111111-2222-4333-8444-666666666666"
    private let nowString = "2026-07-12T00:00:00.000Z"
    private let now = ISO8601DateFormatter().date(from: "2026-07-12T00:00:00Z")!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cas-evictor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSharedObjectWaitsUntilEveryReferenceIsRemoteSafe() async throws {
        let store = try makeStore(name: "shared")
        let shared = Data("shared chunk".utf8)
        let first = try addBinding(store: store, seed: "first", chunks: [shared])
        let second = try addBinding(store: store, seed: "second", chunks: [shared])
        try markSourceDeleted(first, catalog: store.catalog)
        try await replicate([first, second], store: store)
        try recordCurrentLeases(manifestSHA256: first.binding.manifestSHA256, catalog: store.catalog)
        let evictor = ArchiveCASEvictor(catalog: store.catalog, cas: store.cas)

        let blocked = try evictor.evictEligibleObjects(
            for: first.binding.manifestSHA256,
            now: now
        )
        XCTAssertEqual(blocked.blocker, .unsafeSharedReference)
        XCTAssertEqual(blocked.evictedObjects, 0)
        XCTAssertEqual(try store.catalog.localObject(objectSHA256: first.objectDigests[0])?.residency, .resident)
        XCTAssertEqual(try store.cas.readObject(sha256: first.objectDigests[0]), shared)

        try markSourceDeleted(second, catalog: store.catalog)
        let released = try evictor.evictEligibleObjects(
            for: first.binding.manifestSHA256,
            now: now
        )
        XCTAssertEqual(released.evictedObjects, 1)
        XCTAssertEqual(released.releasedBytes, Int64(shared.count))
        XCTAssertEqual(try store.catalog.localObject(objectSHA256: first.objectDigests[0])?.residency, .evicted)
        XCTAssertThrowsError(try store.cas.readObject(sha256: first.objectDigests[0]))
        XCTAssertEqual(
            try store.catalog.reclamationIntent(manifestSHA256: first.binding.manifestSHA256)?.phase,
            .localContentEvicted
        )

        let sharedFollower = try evictor.evictEligibleObjects(
            for: second.binding.manifestSHA256,
            now: now
        )
        XCTAssertEqual(sharedFollower.releasedBytes, 0)
        XCTAssertEqual(
            try store.catalog.reclamationIntent(manifestSHA256: second.binding.manifestSHA256)?.phase,
            .localContentEvicted
        )
    }

    func testBudgetAndExpiredLeaseFailClosed() async throws {
        let store = try makeStore(name: "budget")
        let fixture = try addBinding(
            store: store,
            seed: "budget",
            chunks: [
                Data(repeating: 0x31, count: Int(ArchiveSourceManifest.rawChunkSize)),
                Data("123456".utf8),
            ]
        )
        try markSourceDeleted(fixture, catalog: store.catalog)
        try await replicate([fixture], store: store)
        try recordCurrentLeases(manifestSHA256: fixture.binding.manifestSHA256, catalog: store.catalog)
        let evictor = ArchiveCASEvictor(catalog: store.catalog, cas: store.cas)

        let bounded = try evictor.evictEligibleObjects(
            for: fixture.binding.manifestSHA256,
            now: now,
            maximumBytes: ArchiveSourceManifest.rawChunkSize + 1
        )
        XCTAssertEqual(bounded.evictedObjects, 1)
        XCTAssertEqual(bounded.releasedBytes, ArchiveSourceManifest.rawChunkSize)
        XCTAssertEqual(bounded.blocker, .byteBudgetExhausted)
        XCTAssertEqual(try store.catalog.localObject(objectSHA256: fixture.objectDigests[1])?.residency, .resident)

        let expiredStore = try makeStore(name: "expired")
        let expired = try addBinding(store: expiredStore, seed: "expired", chunks: [Data("keep".utf8)])
        try markSourceDeleted(expired, catalog: expiredStore.catalog)
        try await replicate([expired], store: expiredStore)
        for replicaID in ArchiveCatalog.currentReplicaIDs {
            _ = try expiredStore.catalog.recordRecoveryLease(
                replicaID: replicaID,
                manifestSHA256: expired.binding.manifestSHA256,
                verifiedAt: "2026-06-11T00:00:00.000Z",
                verifiedBytes: Int64(expired.raw.count)
            )
        }
        let expiredResult = try ArchiveCASEvictor(
            catalog: expiredStore.catalog,
            cas: expiredStore.cas
        ).evictEligibleObjects(for: expired.binding.manifestSHA256, now: now)
        XCTAssertEqual(expiredResult.blocker, .expiredDrill)
        XCTAssertEqual(try expiredStore.cas.readObject(sha256: expired.objectDigests[0]), expired.raw)
    }

    func testRemovalFailureKeepsResidentAndSafeMissingObjectBecomesEvicted() async throws {
        let failingStore = try makeStore(
            name: "failure",
            casHooks: ImmutableArchiveCASTestHooks(beforeObjectUnlink: { _ in throw Marker.stop })
        )
        let failing = try addBinding(store: failingStore, seed: "failure", chunks: [Data("remain".utf8)])
        try markSourceDeleted(failing, catalog: failingStore.catalog)
        try await replicate([failing], store: failingStore)
        try recordCurrentLeases(manifestSHA256: failing.binding.manifestSHA256, catalog: failingStore.catalog)
        XCTAssertThrowsError(
            try ArchiveCASEvictor(catalog: failingStore.catalog, cas: failingStore.cas)
                .evictEligibleObjects(for: failing.binding.manifestSHA256, now: now)
        )
        XCTAssertEqual(
            try failingStore.catalog.localObject(objectSHA256: failing.objectDigests[0])?.residency,
            .resident
        )
        XCTAssertEqual(try failingStore.cas.readObject(sha256: failing.objectDigests[0]), failing.raw)

        let missingStore = try makeStore(name: "missing")
        let missing = try addBinding(store: missingStore, seed: "missing", chunks: [Data("gone".utf8)])
        try markSourceDeleted(missing, catalog: missingStore.catalog)
        try await replicate([missing], store: missingStore)
        try recordCurrentLeases(manifestSHA256: missing.binding.manifestSHA256, catalog: missingStore.catalog)
        let objectURL = objectURL(root: missingStore.root, digest: missing.objectDigests[0])
        try FileManager.default.removeItem(at: objectURL)
        let recovered = try ArchiveCASEvictor(catalog: missingStore.catalog, cas: missingStore.cas)
            .evictEligibleObjects(for: missing.binding.manifestSHA256, now: now)
        XCTAssertEqual(recovered.evictedObjects, 1)
        XCTAssertEqual(recovered.releasedBytes, 0)
        XCTAssertEqual(
            try missingStore.catalog.localObject(objectSHA256: missing.objectDigests[0])?.residency,
            .evicted
        )
    }

    private struct Store {
        let root: URL
        let catalog: ArchiveCatalog
        let cas: ImmutableArchiveCAS
    }

    private struct Fixture {
        let binding: ArchiveBinding
        let capture: ArchiveCapture
        let raw: Data
        let objectDigests: [String]
    }

    private func makeStore(
        name: String,
        casHooks: ImmutableArchiveCASTestHooks = ImmutableArchiveCASTestHooks()
    ) throws -> Store {
        let archiveRoot = root.appendingPathComponent(name, isDirectory: true)
        let catalog = try ArchiveCatalog(root: archiveRoot, machineID: machineID)
        try catalog.migrate()
        return Store(
            root: archiveRoot,
            catalog: catalog,
            cas: try ImmutableArchiveCAS(root: archiveRoot, testHooks: casHooks)
        )
    }

    private func addBinding(store: Store, seed: String, chunks: [Data]) throws -> Fixture {
        let raw = chunks.reduce(into: Data()) { $0.append($1) }
        let digests = chunks.map(ArchiveV2Hash.sha256)
        for (chunk, digest) in zip(chunks, digests) {
            _ = try store.cas.publishObject(raw: chunk, expectedSHA256: digest)
        }
        let captureID = ArchiveV2Hash.sha256(Data("capture-\(seed)".utf8))
        let generation = try ArchiveSourceGeneration(
            device: 1,
            inode: Int64(abs(seed.hashValue % 1_000_000) + 1),
            size: Int64(raw.count),
            mtimeNs: 1,
            ctimeNs: 2,
            mode: Int64(S_IFREG | 0o600)
        )
        let references = try zip(chunks.indices, zip(chunks, digests)).map {
            try ArchiveChunkReference(
                ordinal: $0.0,
                rawSHA256: $0.1.1,
                rawByteCount: Int64($0.1.0.count)
            )
        }
        let locator = "/tmp/engram-eviction-\(seed).jsonl"
        let unbound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: "claude-code",
            locator: locator,
            sessionID: nil,
            capturedAt: "2026-07-01T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: ArchiveV2Hash.sha256(raw),
            rawByteCount: Int64(raw.count),
            chunks: references,
            replayLayout: try ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["session.jsonl"])
        )
        let capture = try store.catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(unbound)
        )
        let bound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: unbound.source,
            locator: locator,
            sessionID: "session-\(seed)",
            capturedAt: unbound.capturedAt,
            generation: generation,
            wholeSourceSHA256: unbound.wholeSourceSHA256,
            rawByteCount: unbound.rawByteCount,
            chunks: references,
            replayLayout: unbound.replayLayout
        )
        let boundBytes = try ArchiveCanonicalJSON.encode(bound)
        let manifestSHA = ArchiveV2Hash.sha256(boundBytes)
        _ = try store.cas.publishManifest(boundBytes, expectedSHA256: manifestSHA)
        let binding = try store.catalog.bind(
            canonicalManifestBytes: boundBytes,
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot-\(seed)".utf8)),
            boundAt: "2026-07-01T00:01:00.000Z"
        )
        _ = try store.catalog.setRemotePolicySnapshot(
            manifestSHA256: binding.manifestSHA256,
            projectRootSnapshot: "/tmp/project",
            eligibility: .eligible
        )
        return Fixture(binding: binding, capture: capture, raw: raw, objectDigests: digests)
    }

    private func replicate(_ fixtures: [Fixture], store: Store) async throws {
        let coordinator = try ArchiveReplicationCoordinator(
            catalog: store.catalog,
            cas: store.cas,
            backends: [EvictionReplicaBackend(replicaID: "hq"), EvictionReplicaBackend(replicaID: "m1")]
        )
        let cycle = await coordinator.runOnce(limit: fixtures.count * 2)
        XCTAssertNil(cycle.cycleError)
        XCTAssertEqual(cycle.verified, fixtures.count * 2)
    }

    private func markSourceDeleted(_ fixture: Fixture, catalog: ArchiveCatalog) throws {
        var intent = try catalog.upsertReclamationIntent(
            manifestSHA256: fixture.binding.manifestSHA256,
            captureID: fixture.binding.captureID,
            sessionID: fixture.binding.sessionID,
            locator: fixture.capture.locator,
            updatedAt: "2026-07-01T00:02:00.000Z"
        )
        for (phase, path) in [
            (ArchiveReclamationPhase.quarantinePlanned, fixture.capture.locator + ".q"),
            (.sourceQuarantined, fixture.capture.locator + ".q"),
            (.sourceDeletePlanned, fixture.capture.locator + ".q"),
            (.sourceDeleted, nil),
        ] {
            XCTAssertTrue(try catalog.transitionReclamationIntent(
                manifestSHA256: intent.manifestSHA256,
                from: intent.phase,
                to: phase,
                expectedClaimGeneration: intent.claimGeneration,
                quarantinePath: path,
                updatedAt: nowString
            ))
            intent = try XCTUnwrap(catalog.reclamationIntent(manifestSHA256: intent.manifestSHA256))
        }
    }

    private func recordCurrentLeases(manifestSHA256: String, catalog: ArchiveCatalog) throws {
        for replicaID in ArchiveCatalog.currentReplicaIDs {
            _ = try catalog.recordRecoveryLease(
                replicaID: replicaID,
                manifestSHA256: manifestSHA256,
                verifiedAt: nowString,
                verifiedBytes: 1
            )
        }
    }

    private func objectURL(root: URL, digest: String) -> URL {
        root.appendingPathComponent("objects/sha256/\(digest.prefix(2))/\(digest)")
    }
}

private final class EvictionReplicaBackend: ArchiveReplicaBackend, @unchecked Sendable {
    let replicaID: String
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var manifests: [String: Data] = [:]
    private var receipts: [String: Data] = [:]

    init(replicaID: String) { self.replicaID = replicaID }

    func headObject(digest: String) async throws -> Bool { locked { objects[digest] != nil } }
    func putObject(digest: String, data: Data) async throws { locked { objects[digest] = data } }
    func getObject(digest: String) async throws -> Data { try locked { try required(objects[digest]) } }
    func headManifest(digest: String) async throws -> Bool { locked { manifests[digest] != nil } }
    func putManifest(digest: String, data: Data) async throws { locked { manifests[digest] = data } }
    func getManifest(digest: String) async throws -> Data { try locked { try required(manifests[digest]) } }

    func createReceipt(manifestDigest: String) async throws -> Data {
        let manifestBytes = try locked { try required(manifests[manifestDigest]) }
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: manifestBytes)
        let receipt = try ArchiveServerReceipt(
            serverID: replicaID,
            machineID: manifest.machineID,
            sessionID: try XCTUnwrap(manifest.sessionID),
            captureID: manifest.captureID,
            manifestSHA256: manifestDigest,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            objectCount: manifest.chunks.count,
            rawByteCount: manifest.rawByteCount,
            storedAt: "2026-07-11T23:59:00.000Z"
        )
        let bytes = try ArchiveCanonicalJSON.encode(receipt)
        locked { receipts[manifestDigest] = bytes }
        return bytes
    }

    func getReceipt(manifestDigest: String) async throws -> Data {
        try locked { try required(receipts[manifestDigest]) }
    }

    func listMachines(cursor: String?, limit: Int) async throws -> ArchiveMachinePage {
        try ArchiveMachinePage(machineIDs: [], nextCursor: nil)
    }

    func listReceipts(machineID: String, cursor: String?, limit: Int) async throws -> ArchiveReceiptPage {
        try ArchiveReceiptPage(receipts: [], nextCursor: nil)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func required<T>(_ value: T?) throws -> T {
        guard let value else { throw ArchiveReplicaBackendError.unexpectedStatus(404) }
        return value
    }
}
