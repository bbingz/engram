import CryptoKit
import Darwin
import EngramCoreRead
import EngramCoreWrite
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest

@testable import EngramRemoteServerCore

final class ArchiveRecoveryIntegrationTests: XCTestCase {
    private let hqToken = "hq-clean-recovery-token"
    private let m1Token = "m1-clean-recovery-token"
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "engram-clean-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testCleanMachineRecoversEveryGenerationFromEitherIndependentReplica() async throws {
        let hqRoot = root.appendingPathComponent("hq-store", isDirectory: true)
        let m1Root = root.appendingPathComponent("m1-store", isDirectory: true)
        let clientRoot = root.appendingPathComponent("temporary-client", isDirectory: true)
        let hqRestoreRoot = root.appendingPathComponent("restore-hq", isDirectory: true)
        let hqCollisionRoot = root.appendingPathComponent("restore-hq-collision", isDirectory: true)
        let m1RestoreRoot = root.appendingPathComponent("restore-m1", isDirectory: true)

        let hqKey = SymmetricKey(data: Data(repeating: 0x11, count: 32))
        let m1Key = SymmetricKey(data: Data(repeating: 0x22, count: 32))
        XCTAssertNotEqual(hqRoot, m1Root)
        XCTAssertNotEqual(hqToken, m1Token)

        let hqStore = try ArchiveStore(root: hqRoot, key: hqKey, serverID: "hq")
        let m1Store = try ArchiveStore(root: m1Root, key: m1Key, serverID: "m1")
        let m1Router = Router<BasicRequestContext>()
        ArchiveRoutes.mount(on: m1Router, store: m1Store, token: m1Token)

        let m1App = Application(router: m1Router)
        try await m1App.test(.router) { m1Client in
            let m1Backend = RouterArchiveReplicaBackend(
                replicaID: "m1",
                token: self.m1Token,
                client: m1Client
            )

            let recoveryState = LockedRecoveryState()

            let hqRouter = Router<BasicRequestContext>()
            ArchiveRoutes.mount(on: hqRouter, store: hqStore, token: hqToken)
            let hqApp = Application(router: hqRouter)
            try await hqApp.test(.router) { hqClient in
                let hqBackend = RouterArchiveReplicaBackend(
                    replicaID: "hq",
                    token: self.hqToken,
                    client: hqClient
                )

                try await self.assertCrossReplicaTokensAreRejected(
                    hqClient: hqClient,
                    m1Client: m1Client,
                    hqRoot: hqRoot,
                    m1Root: m1Root
                )

                let fixtures = try await self.replicateThenDestroyLocalState(
                    at: clientRoot,
                    hq: hqBackend,
                    m1: m1Backend
                )
                let expectedByManifest = Dictionary(
                    uniqueKeysWithValues: fixtures.map { ($0.manifestSHA256, $0.raw) }
                )
                XCTAssertFalse(FileManager.default.fileExists(atPath: clientRoot.path))
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: clientRoot.appendingPathComponent("archive.sqlite").path
                    )
                )

                let recovered = try await CleanMachineRecoveryHarness.recover(
                    from: hqBackend,
                    expectedServerID: "hq",
                    into: hqRestoreRoot,
                    machineCursor: nil,
                    receiptCursor: nil
                )
                try self.assertRecovery(
                    recovered,
                    expectedByManifest: expectedByManifest,
                    expectedServerID: "hq"
                )

                let repeated = try await CleanMachineRecoveryHarness.recover(
                    from: hqBackend,
                    expectedServerID: "hq",
                    into: hqRestoreRoot,
                    machineCursor: nil,
                    receiptCursor: nil
                )
                XCTAssertEqual(repeated.restored, recovered.restored)

                let first = try XCTUnwrap(recovered.restored.first)
                let conflictingTarget = Self.restoreURL(
                    root: hqCollisionRoot,
                    machineID: recovered.machineID,
                    manifestSHA256: first.manifestSHA256,
                    replayPath: first.replayPath
                )
                try Self.createOwnerOnlyDirectories(
                    through: conflictingTarget.deletingLastPathComponent()
                )
                XCTAssertTrue(
                    FileManager.default.createFile(
                        atPath: conflictingTarget.path,
                        contents: Data("different bytes".utf8),
                        attributes: [.posixPermissions: 0o600]
                    )
                )
                do {
                    _ = try await CleanMachineRecoveryHarness.recover(
                        from: hqBackend,
                        expectedServerID: "hq",
                        into: hqCollisionRoot,
                        machineCursor: nil,
                        receiptCursor: nil
                    )
                    XCTFail("a conflicting pre-existing target must not be overwritten")
                } catch let error as CleanMachineRecoveryError {
                    XCTAssertEqual(error, .existingTargetConflict)
                }

                recoveryState.store(
                    expectedByManifest: expectedByManifest,
                    hqRecovered: recovered
                )
            }

            // The hq router has stopped with the end of the inner test scope. Recovery
            // deliberately restarts discovery from nil on the still-running m1 router.
            let state = try XCTUnwrap(recoveryState.snapshot())
            let m1Recovered = try await CleanMachineRecoveryHarness.recover(
                from: m1Backend,
                expectedServerID: "m1",
                into: m1RestoreRoot,
                machineCursor: nil,
                receiptCursor: nil
            )
            try self.assertRecovery(
                m1Recovered,
                expectedByManifest: state.expectedByManifest,
                expectedServerID: "m1"
            )
            XCTAssertFalse(m1Recovered.machineCursorsRequested.isEmpty)
            XCTAssertFalse(m1Recovered.receiptCursorsRequested.isEmpty)
            XCTAssertNil(m1Recovered.machineCursorsRequested[0])
            XCTAssertNil(m1Recovered.receiptCursorsRequested[0])
            XCTAssertEqual(m1Recovered.machineID, state.hqRecovered.machineID)
            XCTAssertEqual(
                Set(m1Recovered.restored.map(\.manifestSHA256)),
                Set(state.hqRecovered.restored.map(\.manifestSHA256))
            )
        }
    }

    private func replicateThenDestroyLocalState(
        at clientRoot: URL,
        hq: RouterArchiveReplicaBackend,
        m1: RouterArchiveReplicaBackend
    ) async throws -> [LocalFixture] {
        let fixtures = try await replicateLocalState(
            at: clientRoot,
            hq: hq,
            m1: m1
        )
        // `replicateLocalState` owns the catalog pool and replication actor.
        // Returning from that helper releases every SQLite handle before this
        // clean-machine simulation removes the entire client archive root.
        XCTAssertTrue(FileManager.default.fileExists(atPath: clientRoot.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: clientRoot.appendingPathComponent("archive.sqlite").path
            )
        )
        try FileManager.default.removeItem(at: clientRoot)
        return fixtures
    }

    private func replicateLocalState(
        at clientRoot: URL,
        hq: RouterArchiveReplicaBackend,
        m1: RouterArchiveReplicaBackend
    ) async throws -> [LocalFixture] {
        let machineID = UUID().uuidString
        let cas = try ImmutableArchiveCAS(root: clientRoot)
        let catalog = try ArchiveCatalog(root: clientRoot, machineID: machineID)
        try catalog.migrate()
        XCTAssertEqual(try catalog.machineID(), machineID)

        let multiChunkRaw = Data(
            repeating: 0x5a,
            count: Int(EngramCoreRead.ArchiveSourceManifest.rawChunkSize)
        )
            + Data((0 ..< 257).map { UInt8($0 % 251) })
        let generations = [
            Data("generation one: exact source bytes\n".utf8),
            multiChunkRaw,
            Data("generation three: same replay path, newer bytes\n".utf8),
        ]
        var fixtures: [LocalFixture] = []
        for (index, raw) in generations.enumerated() {
            fixtures.append(
                try makeLocalFixture(
                    raw: raw,
                    index: index,
                    machineID: machineID,
                    cas: cas,
                    catalog: catalog
                )
            )
        }
        XCTAssertEqual(fixtures[1].manifest.chunks.count, 2)
        XCTAssertEqual(
            fixtures[1].manifest.chunks[0].rawByteCount,
            EngramCoreRead.ArchiveSourceManifest.rawChunkSize
        )

        let coordinator = try ArchiveReplicationCoordinator(
            catalog: catalog,
            cas: cas,
            backends: [hq, m1],
            jitter: ArchiveRetryJitter(sampleUnit: { 0 })
        )
        let result = await coordinator.runOnce(limit: fixtures.count * 2)
        XCTAssertNil(result.cycleError)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.claimed, fixtures.count * 2)
        XCTAssertEqual(result.verified, fixtures.count * 2)
        XCTAssertEqual(result.retryScheduled, 0)
        XCTAssertEqual(result.quarantined, 0)

        for fixture in fixtures {
            let hqReceiptBytes = try await hq.getReceipt(
                manifestDigest: fixture.manifestSHA256
            )
            let m1ReceiptBytes = try await m1.getReceipt(
                manifestDigest: fixture.manifestSHA256
            )
            let hqReceipt = try EngramCoreRead.ArchiveCanonicalJSON.decode(
                EngramCoreRead.ArchiveServerReceipt.self,
                from: hqReceiptBytes
            )
            let m1Receipt = try EngramCoreRead.ArchiveCanonicalJSON.decode(
                EngramCoreRead.ArchiveServerReceipt.self,
                from: m1ReceiptBytes
            )
            XCTAssertEqual(hqReceipt.serverID, "hq")
            XCTAssertEqual(m1Receipt.serverID, "m1")
            XCTAssertNotEqual(Self.sha256(hqReceiptBytes), Self.sha256(m1ReceiptBytes))
        }

        return fixtures
    }

    private func makeLocalFixture(
        raw: Data,
        index: Int,
        machineID: String,
        cas: ImmutableArchiveCAS,
        catalog: ArchiveCatalog
    ) throws -> LocalFixture {
        var chunks: [EngramCoreRead.ArchiveChunkReference] = []
        var offset = 0
        var ordinal = 0
        while offset < raw.count {
            let upper = min(
                offset + Int(EngramCoreRead.ArchiveSourceManifest.rawChunkSize),
                raw.count
            )
            let chunk = raw.subdata(in: offset ..< upper)
            let digest = Self.sha256(chunk)
            _ = try cas.publishObject(raw: chunk, expectedSHA256: digest)
            chunks.append(
                try EngramCoreRead.ArchiveChunkReference(
                    ordinal: ordinal,
                    rawSHA256: digest,
                    rawByteCount: Int64(chunk.count)
                )
            )
            offset = upper
            ordinal += 1
        }

        let captureID = Self.sha256(Data("clean-capture-\(index)".utf8))
        let replayLayout = try EngramCoreRead.ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["sessions/2026/07/12/replayed-session.jsonl"]
        )
        let generation = try EngramCoreRead.ArchiveSourceGeneration(
            device: 11,
            inode: Int64(1_000 + index),
            size: Int64(raw.count),
            mtimeNs: Int64(10_000 + index),
            ctimeNs: Int64(20_000 + index),
            mode: Int64(S_IFREG | S_IRUSR | S_IWUSR)
        )
        let capturedAt = "2026-07-12T00:00:0\(index).000Z"
        let common = ManifestFields(
            captureID: captureID,
            machineID: machineID,
            capturedAt: capturedAt,
            generation: generation,
            wholeSourceSHA256: Self.sha256(raw),
            rawByteCount: Int64(raw.count),
            chunks: chunks,
            replayLayout: replayLayout
        )
        let unbound = try common.manifest(sessionID: nil)
        let unboundBytes = try EngramCoreRead.ArchiveCanonicalJSON.encode(unbound)
        _ = try cas.publishManifest(
            unboundBytes,
            expectedSHA256: Self.sha256(unboundBytes)
        )
        _ = try catalog.recordCapture(canonicalManifestBytes: unboundBytes)

        let bound = try common.manifest(sessionID: "clean-recovery-session")
        let boundBytes = try EngramCoreRead.ArchiveCanonicalJSON.encode(bound)
        let manifestSHA256 = Self.sha256(boundBytes)
        _ = try cas.publishManifest(boundBytes, expectedSHA256: manifestSHA256)
        let binding = try catalog.bind(
            canonicalManifestBytes: boundBytes,
            sourceSnapshotFingerprint: Self.sha256(Data("snapshot-\(index)".utf8)),
            boundAt: "2026-07-12T00:00:1\(index).000Z"
        )
        XCTAssertEqual(binding.manifestSHA256, manifestSHA256)
        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: manifestSHA256,
                projectRootSnapshot: "/private/clean-recovery-project",
                eligibility: .eligible
            )
        )
        return LocalFixture(
            raw: raw,
            manifest: bound,
            manifestSHA256: manifestSHA256
        )
    }

    private func assertCrossReplicaTokensAreRejected(
        hqClient: any TestClientProtocol,
        m1Client: any TestClientProtocol,
        hqRoot: URL,
        m1Root: URL
    ) async throws {
        let hqDenied = try await hqClient.execute(
            uri: "/v2/archive/machines?limit=1",
            method: .get,
            headers: Self.headers(token: m1Token)
        )
        let m1Denied = try await m1Client.execute(
            uri: "/v2/archive/machines?limit=1",
            method: .get,
            headers: Self.headers(token: hqToken)
        )
        for response in [hqDenied, m1Denied] {
            XCTAssertEqual(response.status.code, 401)
            let body = String(decoding: Data(response.body.readableBytesView), as: UTF8.self)
            for forbidden in [hqToken, m1Token, hqRoot.path, m1Root.path] {
                XCTAssertFalse(body.contains(forbidden))
            }
        }
    }

    private func assertRecovery(
        _ result: RecoveryResult,
        expectedByManifest: [String: Data],
        expectedServerID: String
    ) throws {
        XCTAssertEqual(result.serverID, expectedServerID)
        XCTAssertFalse(result.machineCursorsRequested.isEmpty)
        XCTAssertFalse(result.receiptCursorsRequested.isEmpty)
        XCTAssertNil(result.machineCursorsRequested[0])
        XCTAssertNil(result.receiptCursorsRequested[0])
        XCTAssertLessThanOrEqual(result.machineCursorsRequested.count, 16)
        XCTAssertLessThanOrEqual(result.receiptCursorsRequested.count, 16)
        XCTAssertEqual(result.machineCursorsRequested.count, 1)
        XCTAssertEqual(result.receiptCursorsRequested.count, expectedByManifest.count)
        XCTAssertEqual(
            Set(result.receiptCursorsRequested.compactMap { $0 }).count,
            result.receiptCursorsRequested.compactMap { $0 }.count,
            "receipt pagination cursors must make strict progress without cycling"
        )
        XCTAssertEqual(Set(result.restored.map(\.manifestSHA256)), Set(expectedByManifest.keys))
        XCTAssertEqual(result.restored.count, expectedByManifest.count)
        XCTAssertEqual(Set(result.restored.map(\.replayPath)).count, 1)
        XCTAssertEqual(Set(result.restored.map(\.targetURL.path)).count, result.restored.count)

        for item in result.restored {
            let expected = try XCTUnwrap(expectedByManifest[item.manifestSHA256])
            XCTAssertEqual(try Data(contentsOf: item.targetURL), expected)
            var info = stat()
            XCTAssertEqual(Darwin.lstat(item.targetURL.path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
            XCTAssertEqual(info.st_uid, geteuid())
        }
    }

    private static func headers(token: String, contentType: String? = nil) -> HTTPFields {
        var headers: HTTPFields = [.authorization: "Bearer \(token)"]
        if let contentType {
            headers[.contentType] = contentType
        }
        return headers
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func restoreURL(
        root: URL,
        machineID: String,
        manifestSHA256: String,
        replayPath: String
    ) -> URL {
        var result = root
            .appendingPathComponent(machineID, isDirectory: true)
            .appendingPathComponent(manifestSHA256, isDirectory: true)
        for component in replayPath.split(separator: "/") {
            result.appendPathComponent(String(component), isDirectory: false)
        }
        return result
    }

    private static func createOwnerOnlyDirectories(through directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var cursor = directory
        while cursor.path.count > FileManager.default.temporaryDirectory.path.count {
            guard Darwin.chmod(cursor.path, S_IRWXU) == 0 else {
                throw CleanMachineRecoveryError.io
            }
            if cursor == directory.deletingLastPathComponent() { break }
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor { break }
            cursor = parent
        }
    }
}

private struct ManifestFields {
    let captureID: String
    let machineID: String
    let capturedAt: String
    let generation: EngramCoreRead.ArchiveSourceGeneration
    let wholeSourceSHA256: String
    let rawByteCount: Int64
    let chunks: [EngramCoreRead.ArchiveChunkReference]
    let replayLayout: EngramCoreRead.ArchiveReplayLayout

    func manifest(sessionID: String?) throws -> EngramCoreRead.ArchiveSourceManifest {
        try EngramCoreRead.ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: "codex",
            locator: "/private/client/sessions/replayed-session.jsonl",
            sessionID: sessionID,
            capturedAt: capturedAt,
            generation: generation,
            wholeSourceSHA256: wholeSourceSHA256,
            rawByteCount: rawByteCount,
            chunks: chunks,
            replayLayout: replayLayout
        )
    }
}

private final class LockedRecoveryState: @unchecked Sendable {
    struct Snapshot {
        let expectedByManifest: [String: Data]
        let hqRecovered: RecoveryResult
    }

    private let lock = NSLock()
    private var value: Snapshot?

    func store(
        expectedByManifest: [String: Data],
        hqRecovered: RecoveryResult
    ) {
        lock.lock()
        value = Snapshot(
            expectedByManifest: expectedByManifest,
            hqRecovered: hqRecovered
        )
        lock.unlock()
    }

    func snapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct LocalFixture {
    let raw: Data
    let manifest: EngramCoreRead.ArchiveSourceManifest
    let manifestSHA256: String
}

private enum RouterArchiveReplicaBackendError: Error, Equatable {
    case unexpectedStatus(Int)
    case responseTooLarge
    case invalidResponse
}

private struct RouterArchiveReplicaBackend: ArchiveReplicaBackend, Sendable {
    let replicaID: String
    private let token: String
    private let client: any TestClientProtocol

    init(replicaID: String, token: String, client: any TestClientProtocol) {
        self.replicaID = replicaID
        self.token = token
        self.client = client
    }

    func headObject(digest: String) async throws -> Bool {
        try await head(kind: "objects", digest: digest)
    }

    func putObject(digest: String, data: Data) async throws {
        try await put(
            kind: "objects",
            digest: digest,
            data: data,
            contentType: "application/octet-stream"
        )
    }

    func getObject(digest: String) async throws -> Data {
        try await get(
            kind: "objects",
            digest: digest,
            maximumBytes: EngramCoreRead.ArchiveV2ProtocolLimits.maxObjectRawBytes
        )
    }

    func headManifest(digest: String) async throws -> Bool {
        try await head(kind: "manifests", digest: digest)
    }

    func putManifest(digest: String, data: Data) async throws {
        try await put(
            kind: "manifests",
            digest: digest,
            data: data,
            contentType: "application/json"
        )
    }

    func getManifest(digest: String) async throws -> Data {
        try await get(
            kind: "manifests",
            digest: digest,
            maximumBytes: EngramCoreRead.ArchiveV2ProtocolLimits.maxManifestBytes
        )
    }

    func createReceipt(manifestDigest: String) async throws -> Data {
        let response = try await client.execute(
            uri: "/v2/archive/receipts/\(manifestDigest)",
            method: .put,
            headers: headers()
        )
        guard response.status.code == 200 || response.status.code == 201 else {
            throw RouterArchiveReplicaBackendError.unexpectedStatus(response.status.code)
        }
        return try boundedData(
            response,
            maximumBytes: EngramCoreRead.ArchiveV2ProtocolLimits.maxReceiptBytes
        )
    }

    func getReceipt(manifestDigest: String) async throws -> Data {
        try await get(
            kind: "receipts",
            digest: manifestDigest,
            maximumBytes: EngramCoreRead.ArchiveV2ProtocolLimits.maxReceiptBytes
        )
    }

    func listMachines(
        cursor: String?,
        limit: Int
    ) async throws -> EngramCoreRead.ArchiveMachinePage {
        var uri = "/v2/archive/machines?limit=\(limit)"
        if let cursor { uri += "&cursor=\(cursor)" }
        let response = try await client.execute(uri: uri, method: .get, headers: headers())
        guard response.status.code == 200 else {
            throw RouterArchiveReplicaBackendError.unexpectedStatus(response.status.code)
        }
        let data = try boundedData(
            response,
            maximumBytes: EngramCoreRead.ArchiveV2ProtocolLimits.maxPageBytes
        )
        do {
            return try EngramCoreRead.ArchiveCanonicalJSON.decode(
                EngramCoreRead.ArchiveMachinePage.self,
                from: data
            )
        } catch {
            throw RouterArchiveReplicaBackendError.invalidResponse
        }
    }

    func listReceipts(
        machineID: String,
        cursor: String?,
        limit: Int
    ) async throws -> EngramCoreRead.ArchiveReceiptPage {
        var uri = "/v2/archive/receipts?machine_id=\(machineID)&limit=\(limit)"
        if let cursor { uri += "&cursor=\(cursor)" }
        let response = try await client.execute(uri: uri, method: .get, headers: headers())
        guard response.status.code == 200 else {
            throw RouterArchiveReplicaBackendError.unexpectedStatus(response.status.code)
        }
        let data = try boundedData(
            response,
            maximumBytes: EngramCoreRead.ArchiveV2ProtocolLimits.maxPageBytes
        )
        do {
            return try EngramCoreRead.ArchiveCanonicalJSON.decode(
                EngramCoreRead.ArchiveReceiptPage.self,
                from: data
            )
        } catch {
            throw RouterArchiveReplicaBackendError.invalidResponse
        }
    }

    private func head(kind: String, digest: String) async throws -> Bool {
        let response = try await client.execute(
            uri: "/v2/archive/\(kind)/\(digest)",
            method: .head,
            headers: headers()
        )
        switch response.status.code {
        case 200: return true
        case 404: return false
        default: throw RouterArchiveReplicaBackendError.unexpectedStatus(response.status.code)
        }
    }

    private func put(
        kind: String,
        digest: String,
        data: Data,
        contentType: String
    ) async throws {
        let response = try await client.execute(
            uri: "/v2/archive/\(kind)/\(digest)",
            method: .put,
            headers: headers(contentType: contentType),
            body: ByteBuffer(data: data)
        )
        guard response.status.code == 200 || response.status.code == 201 else {
            throw RouterArchiveReplicaBackendError.unexpectedStatus(response.status.code)
        }
    }

    private func get(kind: String, digest: String, maximumBytes: Int) async throws -> Data {
        let response = try await client.execute(
            uri: "/v2/archive/\(kind)/\(digest)",
            method: .get,
            headers: headers()
        )
        guard response.status.code == 200 else {
            throw RouterArchiveReplicaBackendError.unexpectedStatus(response.status.code)
        }
        return try boundedData(response, maximumBytes: maximumBytes)
    }

    private func boundedData(_ response: TestResponse, maximumBytes: Int) throws -> Data {
        guard response.body.readableBytes <= maximumBytes else {
            throw RouterArchiveReplicaBackendError.responseTooLarge
        }
        return Data(response.body.readableBytesView)
    }

    private func headers(contentType: String? = nil) -> HTTPFields {
        var fields: HTTPFields = [.authorization: "Bearer \(token)"]
        if let contentType { fields[.contentType] = contentType }
        return fields
    }
}

private enum CleanMachineRecoveryError: Error, Equatable {
    case noMachine
    case ambiguousMachineSelection
    case paginationCycle
    case paginationLimitExceeded
    case duplicateReceipt
    case receiptIntegrity
    case manifestIntegrity
    case objectIntegrity
    case existingTargetConflict
    case io
}

private struct RestoredGeneration: Equatable {
    let manifestSHA256: String
    let replayPath: String
    let targetURL: URL
}

private struct RecoveryResult {
    let serverID: String
    let machineID: String
    let restored: [RestoredGeneration]
    let machineCursorsRequested: [String?]
    let receiptCursorsRequested: [String?]
}

private enum CleanMachineRecoveryHarness {
    private static let pageLimit = 1
    private static let maximumPages = 16

    static func recover(
        from backend: any ArchiveReplicaBackend,
        expectedServerID: String,
        into restoreRoot: URL,
        machineCursor: String?,
        receiptCursor: String?
    ) async throws -> RecoveryResult {
        let machines = try await discoverMachines(
            backend: backend,
            startingCursor: machineCursor
        )
        guard !machines.values.isEmpty else { throw CleanMachineRecoveryError.noMachine }
        guard machines.values.count == 1 else {
            throw CleanMachineRecoveryError.ambiguousMachineSelection
        }
        let machineID = machines.values[0]
        let receipts = try await discoverReceipts(
            backend: backend,
            machineID: machineID,
            startingCursor: receiptCursor
        )

        var restored: [RestoredGeneration] = []
        for summary in receipts.values {
            try Task.checkCancellation()
            let receiptBytes = try await backend.getReceipt(
                manifestDigest: summary.manifestSHA256
            )
            guard Self.sha256(receiptBytes) == summary.receiptSHA256 else {
                throw CleanMachineRecoveryError.receiptIntegrity
            }
            let receipt: EngramCoreRead.ArchiveServerReceipt
            do {
                receipt = try EngramCoreRead.ArchiveCanonicalJSON.decode(
                    EngramCoreRead.ArchiveServerReceipt.self,
                    from: receiptBytes
                )
            } catch {
                throw CleanMachineRecoveryError.receiptIntegrity
            }
            guard receipt.serverID == expectedServerID,
                  receipt.machineID == machineID,
                  receipt.manifestSHA256 == summary.manifestSHA256 else {
                throw CleanMachineRecoveryError.receiptIntegrity
            }

            let manifestBytes = try await backend.getManifest(
                digest: summary.manifestSHA256
            )
            guard Self.sha256(manifestBytes) == summary.manifestSHA256 else {
                throw CleanMachineRecoveryError.manifestIntegrity
            }
            let manifest: EngramCoreRead.ArchiveSourceManifest
            do {
                manifest = try EngramCoreRead.ArchiveCanonicalJSON.decode(
                    EngramCoreRead.ArchiveSourceManifest.self,
                    from: manifestBytes
                )
                try receipt.validate(againstCanonicalManifestBytes: manifestBytes)
            } catch {
                throw CleanMachineRecoveryError.manifestIntegrity
            }
            guard manifest.machineID == machineID,
                  manifest.sessionID != nil,
                  receipt.captureID == manifest.captureID,
                  receipt.wholeSourceSHA256 == manifest.wholeSourceSHA256,
                  receipt.objectCount == manifest.chunks.count,
                  receipt.rawByteCount == manifest.rawByteCount else {
                throw CleanMachineRecoveryError.manifestIntegrity
            }

            let replayPath = manifest.replayLayout.relativePaths[0]
            let target = restoreURL(
                root: restoreRoot,
                machineID: machineID,
                manifestSHA256: summary.manifestSHA256,
                replayPath: replayPath
            )
            try await materialize(
                manifest: manifest,
                from: backend,
                to: target
            )
            restored.append(
                RestoredGeneration(
                    manifestSHA256: summary.manifestSHA256,
                    replayPath: replayPath,
                    targetURL: target
                )
            )
        }

        return RecoveryResult(
            serverID: expectedServerID,
            machineID: machineID,
            restored: restored,
            machineCursorsRequested: machines.cursors,
            receiptCursorsRequested: receipts.cursors
        )
    }

    private static func discoverMachines(
        backend: any ArchiveReplicaBackend,
        startingCursor: String?
    ) async throws -> (values: [String], cursors: [String?]) {
        var values: [String] = []
        var cursors: [String?] = []
        var seenValues = Set<String>()
        var seenCursors = Set<String>()
        var cursor = startingCursor

        while true {
            guard cursors.count < maximumPages else {
                throw CleanMachineRecoveryError.paginationLimitExceeded
            }
            try Task.checkCancellation()
            cursors.append(cursor)
            let page = try await backend.listMachines(cursor: cursor, limit: pageLimit)
            for value in page.machineIDs {
                guard seenValues.insert(value).inserted else {
                    throw CleanMachineRecoveryError.paginationCycle
                }
                values.append(value)
            }
            guard let next = page.nextCursor else { break }
            guard next != cursor, seenCursors.insert(next).inserted else {
                throw CleanMachineRecoveryError.paginationCycle
            }
            cursor = next
        }
        return (values, cursors)
    }

    private static func discoverReceipts(
        backend: any ArchiveReplicaBackend,
        machineID: String,
        startingCursor: String?
    ) async throws -> (
        values: [EngramCoreRead.ArchiveReceiptSummary],
        cursors: [String?]
    ) {
        var values: [EngramCoreRead.ArchiveReceiptSummary] = []
        var cursors: [String?] = []
        var seenManifests = Set<String>()
        var seenCursors = Set<String>()
        var cursor = startingCursor

        while true {
            guard cursors.count < maximumPages else {
                throw CleanMachineRecoveryError.paginationLimitExceeded
            }
            try Task.checkCancellation()
            cursors.append(cursor)
            let page = try await backend.listReceipts(
                machineID: machineID,
                cursor: cursor,
                limit: pageLimit
            )
            for value in page.receipts {
                guard seenManifests.insert(value.manifestSHA256).inserted else {
                    throw CleanMachineRecoveryError.duplicateReceipt
                }
                values.append(value)
            }
            guard let next = page.nextCursor else { break }
            guard next != cursor, seenCursors.insert(next).inserted else {
                throw CleanMachineRecoveryError.paginationCycle
            }
            cursor = next
        }
        return (values, cursors)
    }

    private static func materialize(
        manifest: EngramCoreRead.ArchiveSourceManifest,
        from backend: any ArchiveReplicaBackend,
        to target: URL
    ) async throws {
        let parent = target.deletingLastPathComponent()
        try createOwnerOnlyDirectories(through: parent)
        let temporary = parent.appendingPathComponent(
            ".engram-recovery-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var fd = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else { throw CleanMachineRecoveryError.io }
        var temporaryExists = true
        defer {
            if fd >= 0 { _ = Darwin.close(fd) }
            if temporaryExists { _ = Darwin.unlink(temporary.path) }
        }
        guard Darwin.fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            throw CleanMachineRecoveryError.io
        }

        var wholeHasher = SHA256()
        var total: Int64 = 0
        for chunk in manifest.chunks {
            try Task.checkCancellation()
            let raw = try await backend.getObject(digest: chunk.rawSHA256)
            guard raw.count == chunk.rawByteCount,
                  Self.sha256(raw) == chunk.rawSHA256 else {
                throw CleanMachineRecoveryError.objectIntegrity
            }
            try writeAll(raw, to: fd)
            wholeHasher.update(data: raw)
            let (next, overflow) = total.addingReportingOverflow(Int64(raw.count))
            guard !overflow else { throw CleanMachineRecoveryError.objectIntegrity }
            total = next
        }
        guard total == manifest.rawByteCount,
              hex(wholeHasher.finalize()) == manifest.wholeSourceSHA256 else {
            throw CleanMachineRecoveryError.objectIntegrity
        }
        guard Darwin.fsync(fd) == 0, Darwin.close(fd) == 0 else {
            fd = -1
            throw CleanMachineRecoveryError.io
        }
        fd = -1

        if Darwin.link(temporary.path, target.path) == 0 {
            guard Darwin.unlink(temporary.path) == 0 else {
                throw CleanMachineRecoveryError.io
            }
            temporaryExists = false
            try fsyncDirectory(parent)
            return
        }

        let linkError = errno
        guard Darwin.unlink(temporary.path) == 0 else {
            throw CleanMachineRecoveryError.io
        }
        temporaryExists = false
        guard linkError == EEXIST else { throw CleanMachineRecoveryError.io }
        try verifyExisting(
            target,
            expectedByteCount: manifest.rawByteCount,
            expectedSHA256: manifest.wholeSourceSHA256
        )
    }

    private static func verifyExisting(
        _ target: URL,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) throws {
        let fd = Darwin.open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CleanMachineRecoveryError.existingTargetConflict }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600,
              info.st_uid == geteuid(),
              info.st_size == expectedByteCount else {
            throw CleanMachineRecoveryError.existingTargetConflict
        }

        var hasher = SHA256()
        var remaining = expectedByteCount
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let request = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, request)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw CleanMachineRecoveryError.existingTargetConflict
            }
            hasher.update(data: Data(buffer[0 ..< count]))
            remaining -= Int64(count)
        }
        guard hex(hasher.finalize()) == expectedSHA256 else {
            throw CleanMachineRecoveryError.existingTargetConflict
        }
    }

    private static func createOwnerOnlyDirectories(through directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var cursor = directory
        while true {
            var info = stat()
            guard Darwin.lstat(cursor.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(),
                  Darwin.chmod(cursor.path, S_IRWXU) == 0 else {
                throw CleanMachineRecoveryError.io
            }
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor || parent.path == FileManager.default.temporaryDirectory.path {
                break
            }
            cursor = parent
        }
    }

    private static func restoreURL(
        root: URL,
        machineID: String,
        manifestSHA256: String,
        replayPath: String
    ) -> URL {
        var result = root
            .appendingPathComponent(machineID, isDirectory: true)
            .appendingPathComponent(manifestSHA256, isDirectory: true)
        for component in replayPath.split(separator: "/") {
            result.appendPathComponent(String(component), isDirectory: false)
        }
        return result
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    fd,
                    base.advanced(by: written),
                    rawBuffer.count - written
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CleanMachineRecoveryError.io }
                written += count
            }
        }
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw CleanMachineRecoveryError.io }
        defer { _ = Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw CleanMachineRecoveryError.io }
    }

    private static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
