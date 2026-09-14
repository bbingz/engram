import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorKimiPersistenceTests: XCTestCase {
    func testKimiRegistryPagerResumesAfterDatabaseReopenWithoutRepeatingCompletedPages() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        var store: CollectorInventoryStore? = try f.open()
        let old = try XCTUnwrap(f.snapshot().kimiProjectContext).registryGeneration
        let paths = ["workspace/a/context.jsonl", "workspace/b/context.jsonl", "workspace/c/context.jsonl"]
        for path in paths { try store!.markDirty(configuration: f.configuration, relativePath: path) }
        try store!.reconcileGeminiRegistry(configuration: f.configuration, locator: f.registry.path,
            generation: old, limit: 1)
        try f.writeRegistry(cwd: "/repo/updated-kimi")
        let fresh = try XCTUnwrap(f.snapshot().kimiProjectContext).registryGeneration
        XCTAssertNotEqual(fresh, old)
        func revisions() throws -> [Int64] {
            try f.database.read { try Int64.fetchAll($0,
                sql: "SELECT dirty_revision FROM collector_locators ORDER BY relative_path") }
        }
        let baseline = try revisions()
        try store!.reconcileGeminiRegistry(configuration: f.configuration, locator: f.registry.path,
            generation: fresh, limit: 1)
        XCTAssertEqual(try revisions(), [baseline[0] + 1, baseline[1], baseline[2]])
        store = nil
        try f.reopenDatabase()
        let reopened = try f.open(owner: "run-2")
        for _ in 0..<3 {
            try reopened.reconcileGeminiRegistry(configuration: f.configuration, locator: f.registry.path,
                generation: fresh, limit: 1)
        }
        XCTAssertEqual(try revisions(), baseline.map { $0 + 1 })
        try reopened.reconcileGeminiRegistry(configuration: f.configuration, locator: f.registry.path,
            generation: fresh, limit: 1)
        XCTAssertEqual(try revisions(), baseline.map { $0 + 1 }, "a completed registry page must not redirty forever")
    }

    func testKimiPrivacyProofUsesCapturedContextAfterOriginalRegistryAndSourceRemoval() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        let captured = try f.capture(f.snapshot())
        try FileManager.default.removeItem(at: f.source)
        let policy = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.kimi])
        guard case .eligible(let proof) = try CollectorPrivacyProof.assess(capture: captured, cas: f.cas,
            format: .kimi, policy: policy) else { return XCTFail("captured Kimi metadata must authorize without opening original paths") }
        XCTAssertEqual(proof.nativeSessionID, "session-one")
        XCTAssertEqual(proof.source, .kimi)
        XCTAssertEqual(proof.format, .kimi)
        XCTAssertEqual(proof.projectRoot, "/repo/kimi")
        XCTAssertEqual(proof.manifestSHA256, captured.capture.unboundManifestSHA256)
        XCTAssertTrue(proof.isCurrent(for: captured, policy: policy, format: .kimi))
    }

    func testKimiPrivacyHonorsExcludedDirectoryAndSourcePolicy() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        let captured = try f.capture(f.snapshot())
        let excluded = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: ["/repo"], allowedSources: [.kimi])
        XCTAssertEqual(try CollectorPrivacyProof.assess(capture: captured, cas: f.cas, format: .kimi, policy: excluded), .withheld(.excludedProject))
        let wrongSource = try CollectorPrivacyPolicy(revision: 2, excludedProjectRoots: [], allowedSources: [.codex])
        XCTAssertEqual(try CollectorPrivacyProof.assess(capture: captured, cas: f.cas, format: .kimi, policy: wrongSource), .withheld(.unsupportedSource))
    }

    func testKimiPrivacyBudgetsSpanAllCapturedShardsAndRequireConversationEvidence() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        let policy = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.kimi])
        let shard = f.root.appendingPathComponent("legacy-workspace/session-one/context_1.jsonl")
        try Data("{\"role\":\"assistant\",\"content\":\"another turn\"}\n".utf8).write(to: shard)
        let captured = try f.capture(f.snapshot())
        for limits in [CollectorPrivacyLimits(maxRecords: 1), .init(maxLineBytes: 4), .init(maxSourceBytes: 1),
                       .init(maxProjectRoots: 0), .init(maxTotalProjectRootBytes: 1)] {
            XCTAssertEqual(try CollectorPrivacyProof.assess(capture: captured, cas: f.cas, format: .kimi,
                policy: policy, limits: limits), .withheld(.limitsExceeded))
        }
        try FileManager.default.removeItem(at: shard)
        try Data("{\"event\":\"metadata-only\"}\n".utf8).write(to: f.root.appendingPathComponent(f.relative))
        let empty = try f.capture(f.snapshot())
        XCTAssertEqual(try CollectorPrivacyProof.assess(capture: empty, cas: f.cas, format: .kimi, policy: policy), .withheld(.incompleteMetadata))
    }

    func testKimiPrivacyRejectsCorruptedCapturedObject() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        let captured = try f.capture(f.snapshot())
        let hash = try XCTUnwrap(captured.manifest.chunks.first).rawSHA256
        let object = f.base.appendingPathComponent("archive/objects/sha256/\(hash.prefix(2))/\(hash)")
        XCTAssertEqual(chmod(object.path, 0o600), 0)
        try Data("corrupt owned test object".utf8).write(to: object)
        let policy = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.kimi])
        XCTAssertEqual(try CollectorPrivacyProof.assess(capture: captured, cas: f.cas, format: .kimi, policy: policy), .withheld(.invalidCapture))
    }

    func testReservedContextAndCapturedBytesRecoverAfterRestartAndSourceRemoval() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        var store: CollectorInventoryStore? = try f.open()
        let snapshot = try f.snapshot()
        let reservation = try XCTUnwrap(store!.reserveCapture(f.dirtyClaim(store!), configuration: f.configuration,
            generation: snapshot.present[0].generation, snapshot: snapshot))
        let capture = try f.capture(snapshot)
        XCTAssertEqual(capture.manifest.schemaVersion, 5)
        XCTAssertTrue(ArchiveSourceDescriptor.isKimiFileSet(capture.manifest))
        XCTAssertEqual(capture.manifest.replayLayout.kimiProjectContext, snapshot.kimiProjectContext)
        store = nil
        try f.reopenDatabase()
        try FileManager.default.removeItem(at: f.source)
        let reopened = try f.open(owner: "run-2")
        XCTAssertEqual(try reopened.captureReservations(limit: 8), [reservation])
        XCTAssertNotNil(try reopened.finishCapture(reservation, capture: capture.capture))
        XCTAssertTrue(try reopened.captureReservations(limit: 8).isEmpty)
        XCTAssertEqual(try reopened.publicationIntents(limit: 8).count, 1)
        let states = try f.database.read { try String.fetchAll($0, sql: "SELECT state FROM collector_publication_replicas ORDER BY replica_id") }
        XCTAssertEqual(states, ["pending", "pending"], "one immutable publication retains two independent replica obligations")
    }

    func testRegistryOnlyChangeCreatesDistinctCaptureAndCannotReplaceAnOlderReservation() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        let store = try f.open()
        let old = try f.snapshot()
        let claim = try f.dirtyClaim(store)
        let reservation = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
            generation: old.present[0].generation, snapshot: old))
        let capturedOld = try f.capture(old)
        try f.writeRegistry(cwd: "/repo/new-kimi")
        let fresh = try f.snapshot()
        let capturedFresh = try f.capture(fresh)
        XCTAssertEqual(old.present, fresh.present)
        XCTAssertEqual(capturedOld.manifest.wholeSourceSHA256, capturedFresh.manifest.wholeSourceSHA256)
        XCTAssertNotEqual(capturedOld.manifest.captureID, capturedFresh.manifest.captureID)
        XCTAssertThrowsError(try store.finishCapture(reservation, capture: capturedFresh.capture))
        XCTAssertEqual(try store.captureReservations(limit: 8), [reservation])
        XCTAssertNotNil(try store.finishCapture(reservation, capture: capturedOld.capture))
    }

    func testCorruptOrMissingContextDigestFailsClosedWithoutDeletingTheReservation() throws {
        for corruption in ["digest", "missing", "noncanonical"] {
            let f = try KimiPersistenceFixture(); defer { f.close() }
            let store = try f.open()
            let snapshot = try f.snapshot()
            _ = try XCTUnwrap(store.reserveCapture(f.dirtyClaim(store), configuration: f.configuration,
                generation: snapshot.present[0].generation, snapshot: snapshot))
            try f.database.write { db in
                switch corruption {
                case "digest": try db.execute(sql: "UPDATE collector_capture_reservations SET kimi_context_sha256 = ?", arguments: [String(repeating: "0", count: 64)])
                case "missing": try db.execute(sql: "UPDATE collector_capture_reservations SET kimi_context_bytes = NULL")
                default:
                    var bytes = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT kimi_context_bytes FROM collector_capture_reservations"))
                    bytes.append(0x20)
                    try db.execute(sql: "UPDATE collector_capture_reservations SET kimi_context_bytes = ?, kimi_context_sha256 = ?", arguments: [bytes, ArchiveV2Hash.sha256(bytes)])
                }
            }
            XCTAssertThrowsError(try store.captureReservations(limit: 8), corruption)
            XCTAssertEqual(try f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_capture_reservations") }, 1)
        }
    }

    func testPublicationFailureRollsBackContextReservationAndBothReplicaRows() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        var fail = false
        let store = try f.open(hooks: .init(beforeCommit: { if fail { throw KimiPersistenceFailure.injected } }))
        let snapshot = try f.snapshot()
        let reservation = try XCTUnwrap(store.reserveCapture(f.dirtyClaim(store), configuration: f.configuration,
            generation: snapshot.present[0].generation, snapshot: snapshot))
        let capture = try f.capture(snapshot)
        fail = true
        XCTAssertThrowsError(try store.finishCapture(reservation, capture: capture.capture))
        fail = false
        XCTAssertEqual(try store.captureReservations(limit: 8), [reservation])
        XCTAssertTrue(try store.publicationIntents(limit: 8).isEmpty)
        XCTAssertEqual(try f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_publication_replicas") }, 0)
        XCTAssertNotNil(try store.finishCapture(reservation, capture: capture.capture))
    }

    func testSchemaFourMigrationPreservesExistingSingleFileReservation() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        let codex = CollectorRootConfiguration(rootID: "legacy", source: .codex, rootPath: f.root.path, revision: 1)
        var old: CollectorInventoryStore? = try f.open(configuration: codex)
        let claim = try f.dirtyClaim(old!, configuration: codex)
        let generation = try f.snapshot().present[0].generation
        let reserved = try XCTUnwrap(old!.reserveCapture(claim, configuration: codex, generation: generation))
        old = nil
        try f.database.write { db in
            let columns = try db.columns(in: "collector_capture_reservations").map(\.name)
            for name in ["kimi_context_bytes", "kimi_context_sha256"] where columns.contains(name) {
                try db.execute(sql: "ALTER TABLE collector_capture_reservations DROP COLUMN \(name)")
            }
            try db.execute(sql: "UPDATE collector_metadata SET value = '4' WHERE key = 'publication_schema_version'")
        }
        let reopened = try f.open(owner: "run-2", configuration: codex)
        XCTAssertEqual(try reopened.captureReservations(limit: 8), [reserved])
        XCTAssertEqual(try f.database.read { try String.fetchOne($0, sql: "SELECT value FROM collector_metadata WHERE key = 'publication_schema_version'") }, "11")
    }

    func testKimiReservationRequiresOwnContextAndRefusesOtherSourceContext() throws {
        let f = try KimiPersistenceFixture(); defer { f.close() }
        let store = try f.open()
        let snapshot = try f.snapshot()
        let claim = try f.dirtyClaim(store)
        let missing = CollectorDependencySnapshot(entrypointRelativePath: f.relative,
            present: snapshot.present, absentRelativePaths: snapshot.absentRelativePaths)
        XCTAssertThrowsError(try store.reserveCapture(claim, configuration: f.configuration,
            generation: snapshot.present[0].generation, snapshot: missing))
        let foreign = try ArchiveKimiProjectContext(workspaceName: "legacy-workspace", nativeSessionID: "another",
            cwd: "/repo/kimi", registryLocator: f.registry.path,
            registryGeneration: try XCTUnwrap(snapshot.kimiProjectContext).registryGeneration,
            registrySHA256: try XCTUnwrap(snapshot.kimiProjectContext).registrySHA256)
        let altered = CollectorDependencySnapshot(entrypointRelativePath: f.relative,
            present: snapshot.present, absentRelativePaths: snapshot.absentRelativePaths, kimiProjectContext: foreign)
        XCTAssertThrowsError(try store.reserveCapture(claim, configuration: f.configuration,
            generation: snapshot.present[0].generation, snapshot: altered))
        XCTAssertTrue(try store.captureReservations(limit: 8).isEmpty)
    }
}

private enum KimiPersistenceFailure: Error { case injected }

private final class KimiPersistenceFixture {
    let base: URL
    let source: URL
    let root: URL
    let registry: URL
    var database: DatabaseQueue
    let cas: ImmutableArchiveCAS
    let catalog: ArchiveCatalog
    let machineID = "11111111-2222-3333-4444-555555555555"
    let relative = "legacy-workspace/session-one/context.jsonl"
    var configuration: CollectorRootConfiguration { .init(rootID: "kimi", source: .kimi, rootPath: root.path, revision: 1) }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-persist-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil)); defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        source = base.appendingPathComponent("source"); root = source.appendingPathComponent("sessions")
        registry = source.appendingPathComponent("kimi.json")
        let primary = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"role\":\"user\",\"content\":\"kimi persisted input\"}\n".utf8).write(to: primary)
        database = try DatabaseQueue(path: base.appendingPathComponent("inventory.sqlite").path)
        let archive = base.appendingPathComponent("archive")
        cas = try ImmutableArchiveCAS(root: archive)
        catalog = try ArchiveCatalog(root: archive, machineID: machineID)
        try catalog.migrate()
        try writeRegistry(cwd: "/repo/kimi")
    }
    func writeRegistry(cwd: String) throws {
        try JSONSerialization.data(withJSONObject: ["work_dirs": [["path": cwd, "last_session_id": "session-one"]]])
            .write(to: registry, options: .atomic)
    }
    func snapshot() throws -> CollectorDependencySnapshot {
        let observed = try CollectorKimiSource.observe(rootPath: root.path, primaryRelative: relative, registryLocator: registry.path)
        return observed.snapshot
    }
    func open(owner: String = "run-1", configuration override: CollectorRootConfiguration? = nil,
              hooks: CollectorInventoryStoreTestHooks = .init()) throws -> CollectorInventoryStore {
        let config = override ?? configuration
        let store = try CollectorInventoryStore(database: database, machineID: machineID, ownerRunID: owner, testHooks: hooks)
        try store.registerRoot(config)
        try store.enrollRoot(binding: .init(configuration: config,
            expectedIdentity: .init(device: 1, inode: 2, generation: 0, birthSeconds: 1, birthNanoseconds: 0)))
        XCTAssertNotNil(try store.activateEnrolledRoot(configuration: config))
        return store
    }
    func dirtyClaim(_ store: CollectorInventoryStore, configuration override: CollectorRootConfiguration? = nil) throws -> CollectorDirtyClaim {
        let config = override ?? configuration
        try store.markDirty(configuration: config, relativePath: relative)
        return try XCTUnwrap(store.claimDirty(configuration: config, limit: 1, now: 100).first)
    }
    func capture(_ snapshot: CollectorDependencySnapshot) throws -> ArchiveCaptureResult {
        let primary = root.appendingPathComponent(relative)
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: root,
            files: snapshot.present.map { root.appendingPathComponent($0.relativePath) },
            absentFiles: snapshot.absentRelativePaths.map { root.appendingPathComponent($0) },
            kimiProjectContext: snapshot.kimiProjectContext)
        return try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .kimi, locator: primary.path, machineID: machineID)
    }
    func reopenDatabase() throws {
        try database.close()
        database = try DatabaseQueue(path: base.appendingPathComponent("inventory.sqlite").path)
    }
    func close() { try? catalog.close(); try? database.close(); try? FileManager.default.removeItem(at: base) }
}
