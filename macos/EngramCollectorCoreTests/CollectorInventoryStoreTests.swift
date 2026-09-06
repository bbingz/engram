import Foundation
import Darwin
import CSQLite
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorInventoryStoreTests: XCTestCase {
    func testRootConfigurationEqualityUsesExactUTF8ForRootIDAndPath() {
        let first = CollectorRootConfiguration(rootID: "é", source: .codex, rootPath: "/root/é", revision: 1)
        let otherID = CollectorRootConfiguration(rootID: "e\u{301}", source: .codex, rootPath: first.rootPath, revision: 1)
        let otherPath = CollectorRootConfiguration(rootID: first.rootID, source: .codex, rootPath: "/root/e\u{301}", revision: 1)
        XCTAssertNotEqual(Data(first.rootID.utf8), Data(otherID.rootID.utf8))
        XCTAssertNotEqual(Data(first.rootPath.utf8), Data(otherPath.rootPath.utf8))
        XCTAssertNotEqual(first, otherID)
        XCTAssertNotEqual(first, otherPath)
        XCTAssertEqual(first, first)
    }

    func testSameRootRevisionRejectsCanonicallyEquivalentByteDifferentPathBeforeAndAfterReopen() throws {
        for paths in [["/root/é", "/root/e\u{301}"], ["/root/e\u{301}", "/root/é"]] {
            let fixture = try CollectorInventoryTestFixture()
            defer { fixture.remove() }
            let original = CollectorRootConfiguration(rootID: "same-root", source: .codex, rootPath: paths[0], revision: 1)
            let substituted = CollectorRootConfiguration(rootID: original.rootID, source: original.source, rootPath: paths[1], revision: 1)
            var store: CollectorInventoryStore? = try fixture.open(owner: "run-1")
            try store!.registerRoot(original)
            for owner in ["run-1", "run-2"] {
                if owner == "run-2" {
                    store = nil
                    store = try fixture.open(owner: owner)
                }
                XCTAssertThrowsError(try store!.registerRoot(substituted)) {
                    XCTAssertEqual($0 as? CollectorInventoryError, .invalidRoot)
                }
                XCTAssertThrowsError(try store!.markDirty(configuration: substituted, relativePath: "wrong.jsonl")) {
                    XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
                }
                XCTAssertTrue(try store!.pendingLocators(configuration: original, limit: 10).isEmpty)
                XCTAssertEqual(try store!.rootState(rootID: original.rootID)?.configuration.rootPath.utf8.map { $0 }, Array(paths[0].utf8))
            }
        }
    }

    func testByteDifferentRootPathRequiresNewRevisionAndFencesTheOldConfiguration() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.open(owner: "run-1")
        let original = CollectorRootConfiguration(rootID: "same-root", source: .codex, rootPath: "/root/é", revision: 1)
        let replacement = CollectorRootConfiguration(rootID: original.rootID, source: original.source, rootPath: "/root/e\u{301}", revision: 2)
        try store.registerRoot(original)
        try store.markDirty(configuration: original, relativePath: "old.jsonl")
        try store.registerRoot(replacement)
        XCTAssertThrowsError(try store.markDirty(configuration: original, relativePath: "late.jsonl")) {
            XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
        }
        XCTAssertTrue(try store.pendingLocators(configuration: replacement, limit: 10).isEmpty)
        XCTAssertEqual(try store.rootState(rootID: original.rootID)?.configuration.rootPath.utf8.map { $0 }, Array(replacement.rootPath.utf8))
        try store.markDirty(configuration: replacement, relativePath: "new.jsonl")
        XCTAssertEqual(try store.pendingLocators(configuration: replacement, limit: 10).map(\.relativePath), ["new.jsonl"])
    }

    func testLexicallyCanonicalPhysicalRootPersistsWithoutFilesystemCanonicalization() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let resolved = try XCTUnwrap(realpath(fixture.root.path, nil))
        defer { free(resolved) }
        let path = String(cString: resolved)
        let configuration = CollectorRootConfiguration(rootID: "physical-root", source: .codex, rootPath: path, revision: 1)
        var store: CollectorInventoryStore? = try fixture.open(owner: "run-1")
        try store!.registerRoot(configuration)
        XCTAssertEqual(try store!.rootState(rootID: configuration.rootID)?.configuration.rootPath.utf8.map { $0 }, Array(path.utf8))
        store = nil

        let reopened = try fixture.open(owner: "run-2")
        XCTAssertEqual(try reopened.rootState(rootID: configuration.rootID)?.configuration.rootPath.utf8.map { $0 }, Array(path.utf8))
        let database = try fixture.openDatabase()
        let persisted = try database.read {
            try Data.fetchOne($0, sql: "SELECT CAST(root_path AS BLOB) FROM collector_roots WHERE root_id = ?", arguments: [configuration.rootID])
        }
        XCTAssertEqual(persisted, Data(path.utf8))
    }

    func testLexicallyCanonicalUnicodeRootPathsKeepTheirExactUTF8BytesAcrossReopen() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let resolved = try XCTUnwrap(realpath(fixture.root.path, nil))
        defer { free(resolved) }
        let physicalParent = String(cString: resolved)
        // These are domain-only roots. Registration must not require existence
        // or normalize Unicode while preserving a caller-owned binding.
        let paths = [physicalParent + "/é/会话", physicalParent + "/e\u{301}/会话"]
        XCTAssertNotEqual(Data(paths[0].utf8), Data(paths[1].utf8))
        var store: CollectorInventoryStore? = try fixture.open(owner: "run-1")
        for (index, path) in paths.enumerated() {
            let configuration = CollectorRootConfiguration(rootID: "unicode-root-\(index)", source: .codex, rootPath: path, revision: 1)
            try store!.registerRoot(configuration)
        }
        store = nil

        let reopened = try fixture.open(owner: "run-2")
        let database = try fixture.openDatabase()
        for (index, path) in paths.enumerated() {
            let rootID = "unicode-root-\(index)"
            XCTAssertEqual(try reopened.rootState(rootID: rootID)?.configuration.rootPath.utf8.map { $0 }, Array(path.utf8))
            let persisted = try database.read {
                try Data.fetchOne($0, sql: "SELECT CAST(root_path AS BLOB) FROM collector_roots WHERE root_id = ?", arguments: [rootID])
            }
            XCTAssertEqual(persisted, Data(path.utf8))
        }
    }

    func testRootLexicalValidationRejectsUnsafeAbsoluteAndRelativeFormsWithoutPersistence() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let original = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        let invalidPaths = [
            "", "relative", "./relative", "../relative", "/", "/a/./b", "/a/../b",
            "/a//b", "//a", "/a/", "/nul\0path",
        ]
        for (index, path) in invalidPaths.enumerated() {
            let rootID = "invalid-root-\(index)"
            let configuration = CollectorRootConfiguration(rootID: rootID, source: .codex, rootPath: path, revision: 1)
            XCTAssertThrowsError(try store.registerRoot(configuration), path.debugDescription) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidRoot, path.debugDescription)
            }
            XCTAssertNil(try store.rootState(rootID: rootID), path.debugDescription)
        }
        XCTAssertEqual(try store.rootState(rootID: fixture.configuration.rootID), original)
        let database = try fixture.openDatabase()
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_roots") }, 1)
    }

    func testInventoryPersistsCoalescedDirtyRowsAcrossQueueCloseAndReopen() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var store: CollectorInventoryStore? = try fixture.open(owner: "run-1")
        try store!.registerRoot(fixture.configuration)
        try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        XCTAssertEqual(try store!.pendingLocators(configuration: fixture.configuration, limit: 10).count, 1)
        let before = try XCTUnwrap(store!.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        XCTAssertGreaterThan(before.dirtyRevision, before.acknowledgedRevision)
        store = nil

        let reopened = try fixture.open(owner: "run-2")
        XCTAssertEqual(try reopened.locator(configuration: fixture.configuration, relativePath: "one.jsonl"), before)
        XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID)?.configuration, fixture.configuration)
        let database = try fixture.openDatabase()
        let tables = try database.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        XCTAssertEqual(Set(tables), ["collector_metadata", "collector_roots", "collector_locators", "collector_frontier"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("index.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("archive.sqlite").path))
    }

    func testDirtyDuringClaimSurvivesOldSuccessAcknowledgement() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        try store.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        let old = try fixture.claim(store)
        try store.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        XCTAssertEqual(try store.acknowledge(old, captureID: "capture-1"), .newerWorkPending)
        let row = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        XCTAssertEqual(row.acknowledgedRevision, old.dirtyRevision)
        XCTAssertGreaterThan(row.dirtyRevision, row.acknowledgedRevision)
        XCTAssertEqual(row.lastCaptureID, "capture-1")
        let next = try fixture.claim(store)
        XCTAssertGreaterThan(next.dirtyRevision, old.dirtyRevision)
        XCTAssertEqual(try store.acknowledge(next, captureID: "capture-2"), .acknowledged)
        XCTAssertTrue(try store.pendingLocators(configuration: fixture.configuration, limit: 10).isEmpty)
    }

    func testRestartReclaimsPendingWorkAndRejectsOldOwnerCompletion() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var store: CollectorInventoryStore? = try fixture.openRegistered(owner: "run-1")
        try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        let old = try fixture.claim(store!)
        store = nil
        let reopened = try fixture.open(owner: "run-2")
        let replacement = try fixture.claim(reopened)
        XCTAssertEqual(replacement.dirtyRevision, old.dirtyRevision)
        XCTAssertEqual(replacement.ownerRunID, "run-2")
        XCTAssertGreaterThan(replacement.claimGeneration, old.claimGeneration)
        XCTAssertEqual(try reopened.acknowledge(old, captureID: "stale"), .stale)
        XCTAssertFalse(try reopened.deferClaim(old, retryNotBefore: 999, reason: "stale"))
        XCTAssertEqual(try reopened.acknowledge(replacement, captureID: "current"), .acknowledged)
    }

    func testOldClaimGenerationCannotAcknowledgeReclaimedRetry() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        try store.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        let old = try fixture.claim(store)
        XCTAssertTrue(try store.deferClaim(old, retryNotBefore: 20, reason: "temporary"))
        XCTAssertTrue(try store.claimDirty(configuration: fixture.configuration, limit: 1, now: 19).isEmpty)
        let retry = try fixture.claim(store, now: 20)
        XCTAssertGreaterThan(retry.claimGeneration, old.claimGeneration)
        XCTAssertEqual(try store.acknowledge(old, captureID: "old"), .stale)
        XCTAssertEqual(try store.acknowledge(retry, captureID: "retry"), .acknowledged)
    }

    func testRestartAndRootRevisionChangeDoNotBulkRewriteOldInventoryRows() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var store: CollectorInventoryStore? = try fixture.openRegistered(owner: "run-1")
        for path in ["a.jsonl", "b.jsonl", "c.jsonl"] {
            try store!.markDirty(configuration: fixture.configuration, relativePath: path)
        }
        _ = try fixture.claim(store!)
        store = nil
        let database = try fixture.openDatabase()
        try database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER forbid_inventory_rewrite BEFORE UPDATE ON collector_locators
                BEGIN SELECT RAISE(ABORT, 'startup must not rewrite inventory rows'); END;
                CREATE TRIGGER forbid_inventory_delete BEFORE DELETE ON collector_locators
                BEGIN SELECT RAISE(ABORT, 'startup must not delete inventory rows'); END;
                """)
        }
        let reopened = try fixture.open(owner: "run-2")
        let updated = fixture.configuration(revision: 2)
        try reopened.registerRoot(updated)
        XCTAssertEqual(try reopened.rootState(rootID: updated.rootID)?.configuration, updated)
        XCTAssertTrue(try reopened.pendingLocators(configuration: updated, limit: 10).isEmpty)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_locators") }, 3)
    }

    func testRootRevisionFencesOldClaimAndBootstrapWithoutLosingNewWork() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        try store.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        let oldClaim = try fixture.claim(store)
        let oldScan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "old-scan")
        let updated = fixture.configuration(revision: 2)
        try store.registerRoot(updated)
        try store.markDirty(configuration: updated, relativePath: "new.jsonl")
        XCTAssertEqual(try store.acknowledge(oldClaim, captureID: "stale"), .stale)
        XCTAssertFalse(try store.finishBootstrap(oldScan))
        XCTAssertThrowsError(try store.applyBootstrapBatch(fixture.batch(scan: oldScan, finished: true))) {
            XCTAssertEqual($0 as? CollectorInventoryError, .staleScan)
        }
        XCTAssertEqual(try store.pendingLocators(configuration: updated, limit: 10).map(\.relativePath), ["new.jsonl"])
        XCTAssertEqual(try store.rootState(rootID: updated.rootID)?.configuration, updated)
    }

    func testBootstrapBatchCommitsObservationsChildrenAndDirectoryCompletionAtomically() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var shouldFail = false
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: {
            if shouldFail { throw CollectorInventoryInjectedFailure.beforeCommit }
        }))
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let batch = fixture.batch(scan: scan, files: [fixture.file("one.jsonl")], children: ["nested"], finished: true)
        shouldFail = true
        XCTAssertThrowsError(try store.applyBootstrapBatch(batch)) {
            XCTAssertEqual($0 as? CollectorInventoryInjectedFailure, .beforeCommit)
        }
        shouldFail = false
        XCTAssertNil(try store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        try store.applyBootstrapBatch(batch)
        XCTAssertNotNil(try store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), ["nested"])
        XCTAssertFalse(try store.finishBootstrap(scan))
    }

    func testReplayedBootstrapObservationIsIdempotentWithinScan() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let batch = fixture.batch(scan: scan, files: [fixture.file("one.jsonl")], finished: false)
        try store.applyBootstrapBatch(batch)
        let before = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        try store.applyBootstrapBatch(batch)
        XCTAssertEqual(try store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"), before)
        XCTAssertEqual(try store.pendingLocators(configuration: fixture.configuration, limit: 10).count, 1)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
    }

    func testNewGapDuringScanCannotBeClearedByOldCompletionAndSurvivesReopen() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var store: CollectorInventoryStore? = try fixture.openRegistered()
        let scan = try store!.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        try store!.requestReconciliation(configuration: fixture.configuration)
        try store!.applyBootstrapBatch(fixture.batch(scan: scan, finished: true))
        XCTAssertTrue(try store!.finishBootstrap(scan))
        let pending = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(pending.completedRevision, scan.requestedRevision)
        XCTAssertGreaterThan(pending.requestedRevision, pending.completedRevision)
        store = nil
        let reopened = try fixture.open(owner: "run-2")
        XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID), pending)
        let reconciliation = try reopened.beginBootstrap(configuration: fixture.configuration, scanID: "reconcile")
        try reopened.applyBootstrapBatch(fixture.batch(scan: reconciliation, finished: true))
        XCTAssertTrue(try reopened.finishBootstrap(reconciliation))
        let complete = try XCTUnwrap(reopened.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(complete.requestedRevision, complete.completedRevision)
    }

    func testEventCheckpointAdvancesOnlyWithAtomicDirtyOrReconciliationPersistence() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var shouldFail = false
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: {
            if shouldFail { throw CollectorInventoryInjectedFailure.beforeCommit }
        }))
        let checkpoint = CollectorEventCheckpoint(epoch: "epoch-1", cursor: "opaque-1")
        shouldFail = true
        XCTAssertThrowsError(try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil,
            nextCheckpoint: checkpoint, dirtyRelativePaths: ["one.jsonl"], requiresReconciliation: false
        )) { XCTAssertEqual($0 as? CollectorInventoryInjectedFailure, .beforeCommit) }
        shouldFail = false
        XCTAssertNil(try store.rootState(rootID: fixture.configuration.rootID)?.eventCheckpoint)
        XCTAssertNil(try store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil,
            nextCheckpoint: checkpoint, dirtyRelativePaths: ["one.jsonl"], requiresReconciliation: false
        )
        XCTAssertEqual(try store.rootState(rootID: fixture.configuration.rootID)?.eventCheckpoint, checkpoint)
        XCTAssertNotNil(try store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        let beforeGap = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        let afterGap = CollectorEventCheckpoint(epoch: "epoch-2", cursor: "opaque-gap")
        try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: checkpoint,
            nextCheckpoint: afterGap, dirtyRelativePaths: [], requiresReconciliation: true
        )
        let state = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(state.eventCheckpoint, afterGap)
        XCTAssertGreaterThan(state.requestedRevision, beforeGap.requestedRevision)
        XCTAssertThrowsError(try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: checkpoint,
            nextCheckpoint: .init(epoch: "epoch-1", cursor: "stale"),
            dirtyRelativePaths: ["stale.jsonl"], requiresReconciliation: false
        )) { XCTAssertEqual($0 as? CollectorInventoryError, .staleCheckpoint) }
        XCTAssertEqual(try store.rootState(rootID: fixture.configuration.rootID), state)
        XCTAssertThrowsError(try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: afterGap,
            nextCheckpoint: .init(epoch: "epoch-3", cursor: "unreconciled"),
            dirtyRelativePaths: [], requiresReconciliation: false
        )) { XCTAssertEqual($0 as? CollectorInventoryError, .staleCheckpoint) }
        XCTAssertEqual(try store.rootState(rootID: fixture.configuration.rootID), state)
    }

    func testFailureRetainsLastCaptureAndPendingWork() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        try store.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        XCTAssertEqual(try store.acknowledge(fixture.claim(store), captureID: "last-good"), .acknowledged)
        try store.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        XCTAssertTrue(try store.deferClaim(fixture.claim(store), retryNotBefore: 50, reason: "source missing"))
        let pending = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        XCTAssertEqual(pending.lastCaptureID, "last-good")
        XCTAssertGreaterThan(pending.dirtyRevision, pending.acknowledgedRevision)
        XCTAssertEqual(pending.retryNotBefore, 50)
        XCTAssertEqual(pending.lastError, "source missing")
    }

    func testUnknownRootsUnsafePathsAndMismatchedMachineIdentityFailClosed() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        XCTAssertThrowsError(try store.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")) {
            XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
        }
        try store.registerRoot(fixture.configuration)
        for path in ["../escape.jsonl", "/absolute.jsonl", "nested/../../escape", "a/./b", "a//b", "", "nul\0path"] {
            XCTAssertThrowsError(try store.markDirty(configuration: fixture.configuration, relativePath: path)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidRelativePath, path)
            }
        }
        XCTAssertTrue(try store.pendingLocators(configuration: fixture.configuration, limit: 10).isEmpty)
        XCTAssertThrowsError(try fixture.open(machineID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")) {
            XCTAssertEqual($0 as? CollectorInventoryError, .machineIDMismatch)
        }
    }

    func testClaimFileCountBudgetIsIndependentAndRejectsNegativeLimit() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        for path in ["a.jsonl", "b.jsonl", "c.jsonl"] {
            try store.markDirty(configuration: fixture.configuration, relativePath: path)
        }
        XCTAssertTrue(try store.claimDirty(configuration: fixture.configuration, limit: 0, now: 10).isEmpty)
        XCTAssertEqual(try store.claimDirty(configuration: fixture.configuration, limit: 2, now: 10).count, 2)
        XCTAssertEqual(try store.claimDirty(configuration: fixture.configuration, limit: 2, now: 10).count, 1)
        XCTAssertThrowsError(try store.claimDirty(configuration: fixture.configuration, limit: -1, now: 10)) {
            XCTAssertEqual($0 as? CollectorInventoryError, .invalidBudget)
        }
    }
    func testLiveOldStoreRejectsEveryWriteAfterAnotherOwnerTakesOver() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let old = try fixture.openRegistered(owner: "run-1")
        try old.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        let claim = try fixture.claim(old)
        let scan = try old.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let current = try fixture.open(owner: "run-2")
        let beforeRoot = try current.rootState(rootID: fixture.configuration.rootID)
        let beforeRow = try current.locator(configuration: fixture.configuration, relativePath: "one.jsonl")
        let rejectedWrites: [() throws -> Void] = [
            { try old.registerRoot(fixture.configuration(revision: 2)) },
            { try old.markDirty(configuration: fixture.configuration, relativePath: "stale.jsonl") },
            { _ = try old.claimDirty(configuration: fixture.configuration, limit: 1, now: 10) },
            { _ = try old.acknowledge(claim, captureID: "stale") },
            { _ = try old.deferClaim(claim, retryNotBefore: 999, reason: "stale") },
            { _ = try old.beginBootstrap(configuration: fixture.configuration, scanID: "stale") },
            { try old.applyBootstrapBatch(fixture.batch(scan: scan, finished: true)) },
            { _ = try old.finishBootstrap(scan) },
            { try old.recordScanFailure(scan, failure: .enumerationUnavailable) },
            { try old.requestReconciliation(configuration: fixture.configuration) },
            {
                try old.applyEventBatch(
                    configuration: fixture.configuration, expectedCheckpoint: nil,
                    nextCheckpoint: .init(epoch: "stale", cursor: "stale"),
                    dirtyRelativePaths: ["stale.jsonl"], requiresReconciliation: true
                )
            },
        ]
        for (index, write) in rejectedWrites.enumerated() {
            XCTAssertThrowsError(try write(), "old write \(index) was admitted") {
                XCTAssertEqual($0 as? CollectorInventoryError, .staleOwner)
            }
        }
        XCTAssertEqual(try current.rootState(rootID: fixture.configuration.rootID), beforeRoot)
        XCTAssertEqual(try current.locator(configuration: fixture.configuration, relativePath: "one.jsonl"), beforeRow)
        XCTAssertNil(try current.locator(configuration: fixture.configuration, relativePath: "stale.jsonl"))
        XCTAssertEqual(try current.pendingDirectories(scan: scan, limit: 10), [""])
        let replacement = try fixture.claim(current)
        XCTAssertEqual(replacement.ownerRunID, "run-2")
        XCTAssertGreaterThan(replacement.claimGeneration, claim.claimGeneration)
        withExtendedLifetime(old) {}
    }

    func testClaimCandidateWorkStaysBoundedAndReachesReadySuffixPastDeferredAndInFlightPrefix() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let database = try fixture.openDatabase()
        let store = try CollectorInventoryStore(database: database, machineID: fixture.machineID, ownerRunID: "run-1")
        try store.registerRoot(fixture.configuration)
        let prefixCount = 128
        for index in 0..<prefixCount {
            try store.markDirty(configuration: fixture.configuration, relativePath: String(format: "p%03d.jsonl", index))
        }
        let prefix = try store.claimDirty(configuration: fixture.configuration, limit: prefixCount, now: 10)
        XCTAssertEqual(prefix.count, prefixCount)
        for claim in prefix.suffix(prefixCount / 2) {
            XCTAssertTrue(try store.deferClaim(claim, retryNotBefore: 1_000, reason: "deferred"))
        }
        // Advance through the wrap via the public API; never reset the cursor.
        XCTAssertTrue(try store.claimDirty(configuration: fixture.configuration, limit: 1, now: 10).isEmpty)
        try store.markDirty(configuration: fixture.configuration, relativePath: "z-ready.jsonl")

        let trace = CollectorCandidateQueryTrace()
        try database.writeWithoutTransaction { try trace.install(on: $0) }
        defer { database.writeWithoutTransaction { trace.uninstall(from: $0) } }
        let limit = 7
        let maximumCalls = (prefixCount + 1 + limit - 1) / limit + 1
        var ready: CollectorDirtyClaim?
        var emptyCalls = 0
        var sawWrap = false
        for _ in 0..<maximumCalls {
            trace.reset()
            let claims = try store.claimDirty(configuration: fixture.configuration, limit: limit, now: 10)
            let queries = trace.queries
            XCTAssertFalse(queries.isEmpty, "candidate observation must not pass vacuously")
            XCTAssertLessThanOrEqual(queries.count, 2)
            // TRACE_ROW counts materialized candidates, not pre-filter visits.
            // SQL shape and fixed VM/full-scan/sort bounds cover hidden work.
            XCTAssertEqual(queries.reduce(0) { $0 + $1.rows }, limit)
            XCTAssertLessThanOrEqual(queries.reduce(0) { $0 + $1.vmSteps }, 200 + 60 * limit)
            XCTAssertEqual(queries.reduce(0) { $0 + $1.fullScanSteps }, 0)
            XCTAssertEqual(queries.reduce(0) { $0 + $1.sorts }, 0)
            for query in queries {
                XCTAssertTrue(query.profiled)
                XCTAssertTrue(query.sql.contains("order by relative_path limit ?"))
                XCTAssertFalse(query.sql.contains("retry_not_before"))
                XCTAssertFalse(query.sql.contains("claim_owner_run_id"))
                XCTAssertFalse(query.sql.contains("claimed_dirty_revision"))
            }
            sawWrap = sawWrap || queries.count == 2
            if claims.isEmpty { emptyCalls += 1 }
            XCTAssertTrue(claims.allSatisfy { $0.relativePath == "z-ready.jsonl" })
            if let found = claims.first { ready = found; break }
        }
        XCTAssertGreaterThan(emptyCalls, 0, "empty claims are not an empty queue")
        XCTAssertNotNil(ready, "round-robin must reach the suffix within the candidate budget")
        XCTAssertTrue(sawWrap, "the budget must include both SELECTs in a wrapping claim")
        trace.uninstallSafely(database)
        XCTAssertEqual(try store.pendingLocators(configuration: fixture.configuration, limit: prefixCount + 1).count, prefixCount + 1)
        XCTAssertEqual(try store.locator(configuration: fixture.configuration, relativePath: prefix.last!.relativePath)?.retryNotBefore, 1_000)
    }
}

// Installed only on a serial fixture connection, after setup, and removed before
// teardown. Native SQLite counters avoid adding a production observation hook.
private final class CollectorCandidateQueryTrace {
    struct Query {
        let sql: String
        var rows = 0
        var vmSteps = 0
        var fullScanSteps = 0
        var sorts = 0
        var profiled = false
    }
    private(set) var queries: [Query] = []
    private var indexes: [OpaquePointer: Int] = [:]

    func reset() { queries = []; indexes = [:] }

    func install(on db: Database) throws {
        let result = sqlite3_trace_v2(
            db.sqliteConnection, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_ROW | SQLITE_TRACE_PROFILE),
            { mask, context, pointer, _ in
                guard let context, let pointer else { return SQLITE_OK }
                let trace = Unmanaged<CollectorCandidateQueryTrace>.fromOpaque(context).takeUnretainedValue()
                trace.observe(mask: mask, statement: OpaquePointer(pointer))
                return SQLITE_OK
            }, Unmanaged.passUnretained(self).toOpaque()
        )
        guard result == SQLITE_OK else { throw DatabaseError(resultCode: ResultCode(rawValue: result)) }
    }

    func uninstall(from db: Database) { sqlite3_trace_v2(db.sqliteConnection, 0, nil, nil) }

    func uninstallSafely(_ database: DatabaseQueue) {
        database.writeWithoutTransaction { uninstall(from: $0) }
    }

    private func observe(mask: UInt32, statement: OpaquePointer) {
        if mask == UInt32(SQLITE_TRACE_STMT) {
            guard let rawSQL = sqlite3_sql(statement) else { return }
            let sql = String(cString: rawSQL).split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            guard sql.hasPrefix("select * from collector_locators ") else { return }
            indexes[statement] = queries.count
            queries.append(Query(sql: sql))
            for counter in [SQLITE_STMTSTATUS_VM_STEP, SQLITE_STMTSTATUS_FULLSCAN_STEP, SQLITE_STMTSTATUS_SORT] {
                _ = sqlite3_stmt_status(statement, counter, 1)
            }
        } else if let index = indexes[statement] {
            if mask == UInt32(SQLITE_TRACE_ROW) { queries[index].rows += 1 }
            if mask == UInt32(SQLITE_TRACE_PROFILE) {
                queries[index].vmSteps = Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
                queries[index].fullScanSteps = Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
                queries[index].sorts = Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_SORT, 0))
                queries[index].profiled = true
                indexes.removeValue(forKey: statement)
            }
        }
    }
}

enum CollectorInventoryInjectedFailure: Error, Equatable { case beforeCommit }

final class CollectorInventoryTestFixture {
    let root: URL
    let machineID = "11111111-2222-3333-4444-555555555555"
    private var closeQueues: [() throws -> Void] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("collector-inventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    var databaseURL: URL { root.appendingPathComponent("fixture-inventory.sqlite") }
    var configuration: CollectorRootConfiguration { configuration(revision: 1) }

    func configuration(revision: Int64) -> CollectorRootConfiguration {
        CollectorRootConfiguration(rootID: "fixture-root", source: .codex, rootPath: root.appendingPathComponent("synthetic-source").path, revision: revision)
    }

    func openDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue(path: databaseURL.path)
        // Weak capture preserves the close/reopen tests' actual queue lifetime.
        closeQueues.append { [weak database] in try database?.close() }
        return database
    }

    func open(
        owner: String = "run-1",
        machineID: String? = nil,
        hooks: CollectorInventoryStoreTestHooks = .init()
    ) throws -> CollectorInventoryStore {
        try CollectorInventoryStore(
            database: openDatabase(), machineID: machineID ?? self.machineID,
            ownerRunID: owner, testHooks: hooks
        )
    }

    func openRegistered(owner: String = "run-1", hooks: CollectorInventoryStoreTestHooks = .init()) throws -> CollectorInventoryStore {
        let store = try open(owner: owner, hooks: hooks)
        try store.registerRoot(configuration)
        return store
    }

    func claim(_ store: CollectorInventoryStore, now: Int64 = 10) throws -> CollectorDirtyClaim {
        try XCTUnwrap(store.claimDirty(configuration: configuration, limit: 1, now: now).first)
    }

    func file(_ path: String, generation: String = "observed-1") -> CollectorObservedFile {
        CollectorObservedFile(relativePath: path, observedGeneration: generation)
    }

    func batch(
        scan: CollectorScanToken,
        directory: String = "",
        files: [CollectorObservedFile] = [],
        children: [String] = [],
        finished: Bool
    ) -> CollectorBootstrapBatch {
        CollectorBootstrapBatch(scan: scan, relativeDirectory: directory, files: files, childDirectories: children, directoryFinished: finished)
    }

    func remove() {
        do {
            for close in closeQueues { try close() }
            try FileManager.default.removeItem(at: root)
        } catch {
            XCTFail("Could not close fixture queues and remove their directory: \(error)")
        }
    }
}
