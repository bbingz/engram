import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorSpoolGCTests: XCTestCase {
    func testExplicitInspectionClassifiesLegacyAbsentWithoutBackfill_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.seed.add("head", bytes: "head", latest: true)
        try f.seed.add("old", bytes: "old")
        try f.open()
        try FileManager.default.removeItem(at: f.seed.object("head"))
        try FileManager.default.removeItem(at: f.seed.object("old"))
        let before = try f.seed.snapshot().filter { !$0.key.contains("-shm") }
        let result = try f.session!.recover(now: 1_800_000_000, inspectUntracked: true)
        XCTAssertEqual(result.legacyAbsentObjects, 2)
        XCTAssertEqual(result.legacyAbsentBytes, 7)
        XCTAssertEqual(try f.seed.snapshot().filter { !$0.key.contains("-shm") }, before, "classification has no residency backfill or ACK mutation; existing owned readers may update SHM read marks")
        XCTAssertEqual(try f.session!.residencyCount(), 0)
    }

    func testMissingUntrackedNonDualACKedObjectPreservesBaseAdmission_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.seed.add("head", bytes: "head", latest: true, state: "pending")
        try f.open()
        try FileManager.default.removeItem(at: f.seed.object("head"))
        XCTAssertNoThrow(try f.session!.recover(now: 1_800_000_000))
        XCTAssertNoThrow(try f.owner!.claimPublications(replicaID: "hq", limit: 1, now: 1_800_000_000))
    }

    func testNeverGCStartupAndClaimsDoNotReadUnsupportedCatalog_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.seed.add("head", bytes: "head", latest: true)
        try f.open()
        let db = try DatabaseQueue(path: f.seed.root.appendingPathComponent("capture/archive.sqlite").path)
        try db.write { try $0.execute(sql: "UPDATE archive_metadata SET value='future' WHERE key='schema_version'") }
        try db.close()
        XCTAssertThrowsError(try f.owner!.withSpoolGC { try f.session!.snapshot($0) }, "fixture must reject a full graph read")
        XCTAssertNoThrow(try f.session!.recover(now: 1_800_000_000))
        XCTAssertNoThrow(try f.owner!.claimPublications(replicaID: "hq", limit: 1, now: 1_800_000_000))
        XCTAssertEqual(try f.session!.residencyCount(), 0)
    }

    func testGCRecoveryDoesNotBlockUntrackedMissingPendingHead_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare(); let approval = try f.approval()
        try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        let headID = ArchiveV2Hash.sha256(Data("head".utf8))
        try f.owner!.withSpoolGC { queue in
            try queue.write { try $0.execute(sql: "UPDATE collector_publication_replicas SET state='pending',ack_bytes=NULL WHERE publication_digest IN (SELECT publication_digest FROM collector_publications WHERE capture_id=?)", arguments: [headID]) }
        }
        try FileManager.default.removeItem(at: f.seed.object(GCExecutionFixture.headText))
        XCTAssertNoThrow(try f.session!.recover(now: GCExecutionFixture.clock + 1))
        XCTAssertNoThrow(try f.owner!.claimPublications(replicaID: "hq", limit: 1, now: GCExecutionFixture.clock + 1))
        // Managed bytes retain the integrity boundary even when untracked loss is tolerated.
        try f.session!.restore(runID: approval.runID, now: GCExecutionFixture.clock + 1)
        try FileManager.default.removeItem(at: f.seed.object(GCExecutionFixture.oldText))
        XCTAssertThrowsError(try f.session!.recover(now: GCExecutionFixture.clock + 2)) { error in
            XCTAssertEqual(error as? CollectorSpoolGCError, .spoolIntegrityBlocked)
        }
    }

    func testFreshEmptySpoolAdmissionIsNoOp_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.open()
        XCTAssertEqual(try f.session!.recover(now: 1_800_000_000).legacyAbsentObjects, 0)
        XCTAssertEqual(try f.session!.residencyCount(), 0)
    }

    func testOwnerLockContentionRejectsBeforeGCMutation_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.seed.add("head", bytes: "head", latest: true)
        try f.open()
        let before = try f.seed.snapshot()
        XCTAssertThrowsError(try CollectorInventoryOwner.open(enabled: true, shadowRoot: f.seed.root,
            identityCatalog: f.identity, ownerRunID: "second")) { error in
            XCTAssertEqual(error as? CollectorInventoryOwnerError, .alreadyOwned)
        }
        XCTAssertEqual(try f.seed.snapshot(), before)
    }
}

final class GCExecutionFixture {
    let base: URL
    let seed: GCPreviewFixture
    let identity: URL
    var owner: CollectorInventoryOwner?
    var catalog: ArchiveCatalog?
    var session: CollectorSpoolGCSession?

    init() throws {
        let worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = worktree.appendingPathComponent("output/k5-b2/fixtures")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        base = parent.appendingPathComponent("k5-executor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let native = base.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        seed = try GCPreviewFixture(directory: base.appendingPathComponent("spool"), nativeRoot: native.path)
        identity = base.appendingPathComponent("identity/archive.sqlite")
        for directory in [identity.deletingLastPathComponent(), seed.root] {
            let marker = try ArchiveCatalog(root: directory, machineID: GCPreviewFixture.machine)
            try marker.migrate(); try marker.close()
            let db = try DatabaseQueue(path: directory.appendingPathComponent("archive.sqlite").path)
            try db.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=DELETE") }
            try db.close()
        }
    }

    func open() throws {
        try seed.finish()
        owner = try XCTUnwrap(CollectorInventoryOwner.open(enabled: true, shadowRoot: seed.root,
            identityCatalog: identity, ownerRunID: UUID().uuidString))
        catalog = try ArchiveCatalog(root: seed.root.appendingPathComponent("capture"), machineID: GCPreviewFixture.machine)
        try catalog!.migrate()
        session = try CollectorSpoolGCSession(owner: owner!, catalog: catalog!, spoolRoot: seed.root)
    }

    func reopen() throws {
        session?.transitionHook = nil
        session = nil
        try catalog?.close(); catalog = nil
        try owner?.close(); owner = nil
        owner = try XCTUnwrap(CollectorInventoryOwner.open(enabled: true, shadowRoot: seed.root,
            identityCatalog: identity, ownerRunID: UUID().uuidString))
        catalog = try ArchiveCatalog(root: seed.root.appendingPathComponent("capture"), machineID: GCPreviewFixture.machine)
        try catalog!.migrate()
        session = try CollectorSpoolGCSession(owner: owner!, catalog: catalog!, spoolRoot: seed.root)
    }

    func remove() {
        session = nil
        try? catalog?.close(); catalog = nil
        try? owner?.close(); owner = nil
        seed.remove()
        try? FileManager.default.removeItem(at: base)
    }
}
