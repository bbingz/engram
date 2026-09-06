import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorInventoryOwnerTests: XCTestCase {
    func testRealUsersDataFirmlinkAliasesCannotOverlapLiveCatalogStorage() throws {
        let donor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard donor.path.hasPrefix("/Users/") else {
            XCTFail("the firmlink regression requires its own Users workspace fixture")
            return
        }
        let isolatedHome = donor.appendingPathComponent(".engram-n2-firmlink-test-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: isolatedHome) }
        for variant in 0..<3 {
            let fixture = try CollectorOwnerFixture(parentDirectory: isolatedHome)
            defer { fixture.remove() }
            let physicalShadow: URL
            switch variant {
            case 0: physicalShadow = fixture.liveRoot
            case 1:
                physicalShadow = fixture.liveRoot.appendingPathComponent("nested-shadow")
                try fixture.directory(physicalShadow)
                try fixture.catalog(physicalShadow.appendingPathComponent("archive.sqlite"))
            default:
                physicalShadow = fixture.base
                try fixture.catalog(physicalShadow.appendingPathComponent("archive.sqlite"))
            }
            XCTAssertTrue(physicalShadow.path.hasPrefix("/Users/"), "the fixture must exercise the real Users/Data firmlink")
            let alias = URL(fileURLWithPath: "/System/Volumes/Data" + physicalShadow.path)
            XCTAssertNotEqual(Data(alias.path.utf8), Data(physicalShadow.path.utf8))
            XCTAssertEqual(try fixture.mode(alias) & S_IFMT, S_IFDIR, "positive control: this is not a symbolic link")
            XCTAssertEqual(try fixture.fileIdentity(alias), try fixture.fileIdentity(physicalShadow), "positive control: distinct path bytes reach the same physical directory")
            let before = try fixture.snapshot()
            let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
            assertRejected { _ = try fixture.open(shadowRoot: alias) }
            XCTAssertEqual(try fixture.snapshot(), before, "firmlink overlap variant \(variant)")
            XCTAssertEqual(try fixture.snapshot(at: fixture.liveRoot), liveBefore)
        }
    }

    func testDefaultOffReturnsNilBeforeAnyFilesystemBoundary() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let before = try fixture.snapshot()
        var visits = 0
        var hooks = CollectorInventoryOwnerTestHooks()
        hooks.beforeFilesystemAccess = { visits += 1; throw CollectorOwnerFixture.Failure.injected }
        XCTAssertNil(try CollectorInventoryOwner.open(
            shadowRoot: fixture.base.appendingPathComponent("missing/shadow"),
            identityCatalog: fixture.base.appendingPathComponent("missing/live/archive.sqlite"),
            ownerRunID: "", testHooks: hooks
        ))
        XCTAssertEqual(visits, 0)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testExplicitOffDoesNotValidateInvalidURLsOrCreatePaths() throws {
        var visits = 0
        var hooks = CollectorInventoryOwnerTestHooks()
        hooks.beforeFilesystemAccess = { visits += 1 }
        XCTAssertNil(try CollectorInventoryOwner.open(
            enabled: false, shadowRoot: XCTUnwrap(URL(string: "https://invalid.example/shadow")),
            identityCatalog: XCTUnwrap(URL(string: "https://invalid.example/archive.sqlite")),
            ownerRunID: "", testHooks: hooks
        ))
        XCTAssertEqual(visits, 0)
    }

    func testMissingInvalidOrConflictingIdentityMakesNoFilesystemChanges() throws {
        for variant in 0..<5 {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            switch variant {
            case 0: try FileManager.default.removeItem(at: fixture.liveCatalog)
            case 1: try fixture.setIdentity(at: fixture.liveCatalog, value: "not-a-uuid")
            case 2: try fixture.setIdentity(at: fixture.liveCatalog, value: nil)
            case 3: try fixture.setIdentity(at: fixture.shadowCatalog, value: CollectorOwnerFixture.otherMachineID)
            default: try FileManager.default.removeItem(at: fixture.shadowCatalog)
            }
            let before = try fixture.snapshot()
            assertRejected { _ = try fixture.open() }
            XCTAssertEqual(try fixture.snapshot(), before, "identity variant \(variant)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inventoryDirectory.path))
        }
    }

    func testMissingPreprovisionedShadowIsNotProvisionedByOwner() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.shadowRoot)
        let before = try fixture.snapshot()
        assertRejected { _ = try fixture.open() }
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shadowRoot.path))
    }

    func testShadowCannotEqualContainOrDescendFromLiveCatalogRoot() throws {
        for variant in 0..<3 {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let selected: URL
            switch variant {
            case 0: selected = fixture.liveRoot
            case 1:
                selected = fixture.liveRoot.appendingPathComponent("nested-shadow")
                try fixture.directory(selected)
                try fixture.catalog(selected.appendingPathComponent("archive.sqlite"))
            default:
                selected = fixture.base
                try fixture.catalog(selected.appendingPathComponent("archive.sqlite"))
            }
            let before = try fixture.snapshot()
            assertRejected { _ = try fixture.open(shadowRoot: selected) }
            XCTAssertEqual(try fixture.snapshot(), before, "overlap variant \(variant)")
        }
    }

    func testShadowAndLivePathAncestorSymlinksAreNotCanonicalized() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let alias = fixture.base.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.base)
        let before = try fixture.snapshot()
        assertRejected { _ = try fixture.open(shadowRoot: alias.appendingPathComponent("task/shadow")) }
        assertRejected { _ = try fixture.open(identityCatalog: alias.appendingPathComponent("live/archive.sqlite")) }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testInventoryMainSidecarsAndLockRejectSymlinksWithoutChangingTargets() throws {
        for relative in ["inventory", "inventory/inventory.sqlite", "inventory/inventory.sqlite-wal", "inventory/inventory.sqlite-shm", "collector-owner.lock"] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            try fixture.seedInventory()
            let target = fixture.shadowRoot.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            let victim = relative == "inventory" ? fixture.liveRoot : fixture.liveCatalog
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
            let before = try fixture.snapshot()
            assertRejected { _ = try fixture.open() }
            XCTAssertEqual(try fixture.snapshot(), before, relative)
        }
    }

    func testInventoryMainSidecarsAndLockRejectHardlinksWithoutChangingTargets() throws {
        for relative in ["inventory/inventory.sqlite", "inventory/inventory.sqlite-wal", "inventory/inventory.sqlite-shm", "collector-owner.lock"] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            try fixture.seedInventory()
            let target = fixture.shadowRoot.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            XCTAssertEqual(link(fixture.liveCatalog.path, target.path), 0)
            let before = try fixture.snapshot()
            assertRejected { _ = try fixture.open() }
            XCTAssertEqual(try fixture.snapshot(), before, relative)
        }
    }

    func testUnsafeExistingDirectoryAndFileModesAreRejectedNotRepaired() throws {
        for relative in ["", "inventory", "inventory/inventory.sqlite", "inventory/inventory.sqlite-wal", "inventory/inventory.sqlite-shm", "collector-owner.lock"] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            try fixture.seedInventory()
            let target = relative.isEmpty ? fixture.shadowRoot : fixture.shadowRoot.appendingPathComponent(relative)
            if !FileManager.default.fileExists(atPath: target.path) { try fixture.file(target, bytes: Data()) }
            let isDirectory = relative.isEmpty || relative == "inventory"
            XCTAssertEqual(chmod(target.path, isDirectory ? 0o755 : 0o644), 0)
            let before = try fixture.snapshot()
            assertRejected { _ = try fixture.open() }
            XCTAssertEqual(try fixture.snapshot(), before, relative)
        }
    }

    func testInventoryMainSidecarsAndLockRejectNonRegularFilesWithoutBlocking() throws {
        for relative in ["inventory/inventory.sqlite", "inventory/inventory.sqlite-wal", "inventory/inventory.sqlite-shm", "collector-owner.lock"] {
            for fifo in [false, true] {
                let fixture = try CollectorOwnerFixture()
                defer { fixture.remove() }
                try fixture.seedInventory()
                let target = fixture.shadowRoot.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                if fifo { XCTAssertEqual(mkfifo(target.path, 0o600), 0) }
                else { try fixture.directory(target) }
                let before = try fixture.snapshot()
                assertRejected { _ = try fixture.open() }
                XCTAssertEqual(try fixture.snapshot(), before, "\(relative), fifo=\(fifo)")
                XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
            }
        }
    }

    func testMainFileReplacementBetweenPreparationAndSQLiteOpenIsRejected() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        try fixture.seedInventory()
        let saved = fixture.inventoryDirectory.appendingPathComponent("prepared-original.sqlite")
        var boundaryVisited = false
        var original: Data?
        var databaseOpened = false
        var hooks = CollectorInventoryOwnerTestHooks()
        hooks.afterMainFilePrepared = {
            boundaryVisited = true
            original = try Data(contentsOf: fixture.inventoryURL)
            try FileManager.default.moveItem(at: fixture.inventoryURL, to: saved)
            try fixture.file(fixture.inventoryURL, bytes: XCTUnwrap(original))
        }
        hooks.afterDatabaseOpened = { databaseOpened = true }
        assertRejected { _ = try fixture.open(hooks: hooks) }
        XCTAssertTrue(boundaryVisited)
        XCTAssertFalse(databaseOpened)
        if let original {
            XCTAssertEqual(try Data(contentsOf: saved), original)
            XCTAssertEqual(try Data(contentsOf: fixture.inventoryURL), original)
        }
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
    }

    func testPostOpenMainReplacementIsRejectedBeforeInventoryInitialization() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        try fixture.seedInventory()
        let saved = fixture.inventoryDirectory.appendingPathComponent("opened-original.sqlite")
        var visited = false
        var original: Data?
        var hooks = CollectorInventoryOwnerTestHooks()
        hooks.afterDatabaseOpened = {
            visited = true
            original = try Data(contentsOf: fixture.inventoryURL)
            try FileManager.default.moveItem(at: fixture.inventoryURL, to: saved)
            try fixture.file(fixture.inventoryURL, bytes: XCTUnwrap(original))
        }
        assertRejected { _ = try fixture.open(hooks: hooks) }
        XCTAssertTrue(visited)
        if let original { XCTAssertEqual(try Data(contentsOf: fixture.inventoryURL), original) }
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
    }

    func testShadowReplacementAfterLockDoesNotCreateASecondOwnerLocation() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let moved = fixture.shadowRoot.deletingLastPathComponent().appendingPathComponent("old-shadow")
        var visited = false
        var hooks = CollectorInventoryOwnerTestHooks()
        hooks.afterLockAcquired = {
            visited = true
            try FileManager.default.moveItem(at: fixture.shadowRoot, to: moved)
            try fixture.directory(fixture.shadowRoot)
            try fixture.catalog(fixture.shadowCatalog)
        }
        assertRejected { _ = try fixture.open(hooks: hooks) }
        XCTAssertTrue(visited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inventoryDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("collector-owner.lock").path))
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
    }

    func testPostOpenSidecarSymlinksAreRejectedWithoutMutatingTheirTarget() throws {
        for suffix in ["-wal", "-shm"] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let before = try fixture.snapshot(at: fixture.liveRoot)
            let sidecar = URL(fileURLWithPath: fixture.inventoryURL.path + suffix)
            var visited = false
            var hooks = CollectorInventoryOwnerTestHooks()
            hooks.afterDatabaseOpened = {
                visited = true
                if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
                try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: fixture.liveCatalog)
            }
            assertRejected { _ = try fixture.open(hooks: hooks) }
            XCTAssertTrue(visited, suffix)
            XCTAssertEqual(try fixture.snapshot(at: fixture.liveRoot), before, suffix)
            XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
        }
    }

    func testSuccessfulOwnerUsesOnlyFixedPrivateInventoryAndPreservesCatalogsAndSource() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        let catalogBefore = try fixture.snapshot(at: fixture.shadowCatalog)
        let sourceBefore = try fixture.snapshot(at: fixture.sourceParent)
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        let binding = try owner.enrollAndActivateRoot(fixture.configuration)
        XCTAssertEqual(binding.configuration, fixture.configuration)
        XCTAssertEqual(binding.expectedIdentity, try fixture.physicalIdentity())
        let state = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(state.requestedRevision, 2)
        XCTAssertEqual(state.completedRevision, 0)
        XCTAssertNil(state.eventCheckpoint)
        XCTAssertNil(state.activeScan)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.shadowRoot.path)), ["archive.sqlite", "collector-owner.lock", "inventory"])
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: fixture.inventoryDirectory.path))
        XCTAssertTrue(names.contains("inventory.sqlite"))
        XCTAssertTrue(names.isSubset(of: ["inventory.sqlite", "inventory.sqlite-wal", "inventory.sqlite-shm"]))
        XCTAssertEqual(try fixture.mode(fixture.inventoryDirectory) & 0o777, 0o700)
        for name in names { XCTAssertEqual(try fixture.mode(fixture.inventoryDirectory.appendingPathComponent(name)) & 0o777, 0o600) }
        XCTAssertEqual(try fixture.mode(fixture.lockURL) & 0o777, 0o600)
        try owner.close()
        XCTAssertEqual(try fixture.inventoryText("SELECT value FROM collector_metadata WHERE key = 'machine_id'"), CollectorOwnerFixture.machineID)
        XCTAssertEqual(try fixture.snapshot(at: fixture.liveRoot), liveBefore)
        XCTAssertEqual(try fixture.snapshot(at: fixture.shadowCatalog), catalogBefore)
        XCTAssertEqual(try fixture.snapshot(at: fixture.sourceParent), sourceBefore)
    }

    func testRestartLoadsStoredPhysicalBindingAndActivatesOncePerOwnerRun() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let first = try XCTUnwrap(fixture.open(ownerRunID: "owner-one"))
        defer { try? first.close() }
        let bound = try first.enrollAndActivateRoot(fixture.configuration)
        _ = try first.enrollAndActivateRoot(fixture.configuration)
        XCTAssertEqual(try first.rootState(rootID: fixture.configuration.rootID)?.requestedRevision, 2)
        try first.close()
        let second = try XCTUnwrap(fixture.open(ownerRunID: "owner-two"))
        defer { try? second.close() }
        XCTAssertEqual(try second.rootState(rootID: fixture.configuration.rootID)?.requestedRevision, 2, "opening inventory alone is not root activation")
        XCTAssertEqual(try second.enrollAndActivateRoot(fixture.configuration).expectedIdentity, bound.expectedIdentity)
        XCTAssertEqual(try second.rootState(rootID: fixture.configuration.rootID)?.requestedRevision, 3)
        _ = try second.enrollAndActivateRoot(fixture.configuration)
        XCTAssertEqual(try second.rootState(rootID: fixture.configuration.rootID)?.requestedRevision, 3)
        try second.close()
        XCTAssertEqual(try fixture.inventoryText("SELECT last_activated_owner_run_id FROM collector_root_bindings"), "owner-two")
    }

    func testRestartRootReplacementDoesNotRebindOrActivateNewInode() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let first = try XCTUnwrap(fixture.open(ownerRunID: "owner-one"))
        defer { try? first.close() }
        let binding = try first.enrollAndActivateRoot(fixture.configuration)
        try first.close()
        try fixture.replaceSourceRoot()
        XCTAssertNotEqual(try fixture.physicalIdentity(), binding.expectedIdentity)
        let second = try XCTUnwrap(fixture.open(ownerRunID: "owner-two"))
        defer { try? second.close() }
        assertRejected { _ = try second.enrollAndActivateRoot(fixture.configuration) }
        XCTAssertEqual(try second.rootState(rootID: fixture.configuration.rootID)?.requestedRevision, 2)
        try second.close()
        XCTAssertEqual(try fixture.inventoryText("SELECT last_activated_owner_run_id FROM collector_root_bindings"), "owner-one")
        XCTAssertEqual(try fixture.inventoryInteger("SELECT inode FROM collector_root_bindings"), binding.expectedIdentity.inode)
    }

    func testSourceAncestorSymlinkIsRejectedBeforeFirstEnrollment() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let alias = fixture.base.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.sourceParent)
        let configuration = fixture.configuration(path: alias.appendingPathComponent("sessions").path)
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        assertRejected { _ = try owner.enrollAndActivateRoot(configuration) }
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_root_bindings"), 0)
    }

    func testRestartRejectsNewAncestorSymlinkEvenWhenRootInodeStillMatches() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let first = try XCTUnwrap(fixture.open(ownerRunID: "owner-one"))
        defer { try? first.close() }
        let binding = try first.enrollAndActivateRoot(fixture.configuration)
        try first.close()
        let moved = fixture.base.appendingPathComponent("moved-sources")
        try FileManager.default.moveItem(at: fixture.sourceParent, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.sourceParent, withDestinationURL: moved)
        XCTAssertEqual(try fixture.physicalIdentity(), binding.expectedIdentity, "positive control: only the ancestor route changed")
        let second = try XCTUnwrap(fixture.open(ownerRunID: "owner-two"))
        defer { try? second.close() }
        assertRejected { _ = try second.enrollAndActivateRoot(fixture.configuration) }
        XCTAssertEqual(try second.rootState(rootID: fixture.configuration.rootID)?.requestedRevision, 2)
        try second.close()
        XCTAssertEqual(try fixture.inventoryText("SELECT last_activated_owner_run_id FROM collector_root_bindings"), "owner-one")
    }

    func testSourceChangeImmediatelyBeforeActivationIsRejectedWithoutActivationStamp() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        var visited = false
        var hooks = CollectorInventoryOwnerTestHooks()
        hooks.beforeRootActivation = { visited = true; try fixture.replaceSourceRoot() }
        let owner = try XCTUnwrap(fixture.open(hooks: hooks))
        defer { try? owner.close() }
        assertRejected { _ = try owner.enrollAndActivateRoot(fixture.configuration) }
        XCTAssertTrue(visited)
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_root_bindings WHERE last_activated_owner_run_id IS NOT NULL"), 0)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT requested_revision FROM collector_roots"), 1)
    }

    func testObservationFactoryReturnsRealFiveTupleForBothSupportedSources() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let descriptors = CollectorOwnerDescriptorObservation()
        for source in [SourceName.codex, .claudeCode] {
            let configuration = fixture.configuration(source: source)
            let binding = try CollectorPOSIXRootEnumerator.observeRoot(configuration: configuration, testHooks: descriptors.hooks)
            XCTAssertEqual(binding.configuration, configuration)
            XCTAssertEqual(binding.expectedIdentity, try fixture.physicalIdentity())
            try CollectorPOSIXRootEnumerator.validateRoot(binding: binding, testHooks: descriptors.hooks)
        }
        XCTAssertGreaterThan(descriptors.opened, 0)
        XCTAssertEqual(descriptors.live, [])
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.sourceParent), [])
    }

    func testObservationFactoryRejectsInvalidConfigurationBeforeOpeningDescriptors() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let descriptors = CollectorOwnerDescriptorObservation()
        let configurations = [
            fixture.configuration(source: .cursor), fixture.configuration(path: "/"),
            fixture.configuration(path: "relative/root"), fixture.configuration(path: fixture.sourceRoot.path + "/../sessions"),
            fixture.configuration(path: "/" + Array(repeating: "x", count: 33).joined(separator: "/")),
            fixture.configuration(path: "/" + String(repeating: "x", count: Int(MAXPATHLEN))),
        ]
        for configuration in configurations {
            XCTAssertThrowsError(try CollectorPOSIXRootEnumerator.observeRoot(configuration: configuration, testHooks: descriptors.hooks)) {
                XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .invalidBinding)
            }
        }
        XCTAssertEqual(descriptors.opened, 0)
        XCTAssertEqual(descriptors.live, [])
    }

    func testValidationFactoryRejectsReplacedRootAndClosesEveryDescriptor() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let descriptors = CollectorOwnerDescriptorObservation()
        let binding = try CollectorPOSIXRootEnumerator.observeRoot(configuration: fixture.configuration, testHooks: descriptors.hooks)
        try fixture.replaceSourceRoot()
        for _ in 0..<8 {
            XCTAssertThrowsError(try CollectorPOSIXRootEnumerator.validateRoot(binding: binding, testHooks: descriptors.hooks)) {
                XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .rootIdentityChanged)
            }
            XCTAssertEqual(descriptors.live, [])
            XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.sourceParent), [])
        }
    }

    func testSubsequentCursorOpenRejectsRootReplacementInsteadOfScanningIt() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        try fixture.replaceSourceRoot()
        try fixture.file(fixture.sourceRoot.appendingPathComponent("rollout-replacement.jsonl"), bytes: Data("synthetic".utf8))
        let result = try owner.stepRoot(fixture.configuration, budget: fixture.budget)
        XCTAssertEqual(result.outcome, .blocked(.enumerationUnavailable))
        XCTAssertEqual(result.candidateFiles, 0)
        XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID)?.lastScanFailure, .enumerationUnavailable)
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.sourceParent), [])
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 0)
    }

    func testSameProcessContenderCannotStealLockOrChangeActiveOwnerState() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let owner = try XCTUnwrap(fixture.open(ownerRunID: "first"))
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        let before = try owner.rootState(rootID: fixture.configuration.rootID)
        XCTAssertThrowsError(try fixture.open(ownerRunID: "contender")) {
            XCTAssertEqual($0 as? CollectorInventoryOwnerError, .alreadyOwned)
        }
        XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID), before)
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        try owner.close()
        XCTAssertEqual(try fixture.inventoryText("SELECT value FROM collector_metadata WHERE key = 'active_owner_run_id'"), "first")
        let successor = try XCTUnwrap(fixture.open(ownerRunID: "successor"))
        try successor.close()
    }

    func testIndependentProcessOwnerExclusionAndCloseOnExec() throws {
        let environment = ProcessInfo.processInfo.environment
        if let mode = environment["ENGRAM_N2_OWNER_PROBE_MODE"] {
            XCTAssertNotEqual(environment["ENGRAM_N2_OWNER_PARENT_PID"], String(getpid()))
            let shadow = URL(fileURLWithPath: try XCTUnwrap(environment["ENGRAM_N2_OWNER_SHADOW"]))
            let identity = URL(fileURLWithPath: try XCTUnwrap(environment["ENGRAM_N2_OWNER_CATALOG"]))
            let base = URL(fileURLWithPath: try XCTUnwrap(environment["ENGRAM_N2_OWNER_FIXTURE"]))
            XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: base), [], "exec child must not inherit the parent's owner handles")
            if mode == "blocked" {
                XCTAssertThrowsError(try CollectorInventoryOwner.open(enabled: true, shadowRoot: shadow, identityCatalog: identity, ownerRunID: "child-blocked")) {
                    XCTAssertEqual($0 as? CollectorInventoryOwnerError, .alreadyOwned)
                }
            } else {
                XCTAssertEqual(mode, "open")
                let owner = try XCTUnwrap(CollectorInventoryOwner.open(enabled: true, shadowRoot: shadow, identityCatalog: identity, ownerRunID: "child-open"))
                try owner.close()
            }
            XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: base), [])
            print("N2_OWNER_PROBE_SUCCESS:\(mode);pid=\(getpid())")
            return
        }
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let before = try fixture.snapshot(at: fixture.liveRoot)
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        let descriptors = try collectorOwnerFixtureDescriptors(under: fixture.shadowRoot)
        XCTAssertFalse(descriptors.isEmpty)
        for descriptor in descriptors { XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0) }
        try runOwnerProbe(mode: "blocked", fixture: fixture)
        try owner.close()
        try runOwnerProbe(mode: "open", fixture: fixture)
        XCTAssertEqual(try fixture.snapshot(at: fixture.liveRoot), before)
    }

    func testCloseDrainsActiveCursorAndQueueBeforeReleasingStableLockInode() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        for index in 0..<4 { try fixture.file(fixture.sourceRoot.appendingPathComponent("rollout-\(index).jsonl"), bytes: Data("synthetic".utf8)) }
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        let lockIdentity = try fixture.fileIdentity(fixture.lockURL)
        let budget = CollectorBootstrapBudget(maxEntriesVisited: 1, maxCandidateFiles: 1, maxDirectoryOpens: 1, maxMetadataBytes: 4096)
        XCTAssertEqual(try owner.stepRoot(fixture.configuration, budget: budget).outcome, .paused(.budget))
        XCTAssertFalse(try collectorOwnerFixtureDescriptors(under: fixture.sourceParent).isEmpty, "positive control: an unfinished cursor is retained")
        try owner.close()
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
        XCTAssertEqual(try fixture.fileIdentity(fixture.lockURL), lockIdentity, "close must not unlink or replace the lock file")
        XCTAssertNoThrow(try owner.close())
        XCTAssertThrowsError(try owner.rootState(rootID: fixture.configuration.rootID)) { XCTAssertEqual($0 as? CollectorInventoryOwnerError, .closed) }
        XCTAssertThrowsError(try owner.enrollAndActivateRoot(fixture.configuration)) { XCTAssertEqual($0 as? CollectorInventoryOwnerError, .closed) }
        XCTAssertThrowsError(try owner.stepRoot(fixture.configuration, budget: budget)) { XCTAssertEqual($0 as? CollectorInventoryOwnerError, .closed) }
        let next = try XCTUnwrap(fixture.open(ownerRunID: "next"))
        XCTAssertEqual(try fixture.fileIdentity(fixture.lockURL), lockIdentity)
        try next.close()
    }

    func testInitializationFailuresReleaseLockAndEveryOwnedDescriptor() throws {
        for boundary in 0..<3 {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            var visited = false
            let fail: () throws -> Void = { visited = true; throw CollectorOwnerFixture.Failure.injected }
            var hooks = CollectorInventoryOwnerTestHooks()
            switch boundary {
            case 0: hooks.afterLockAcquired = fail
            case 1: hooks.afterMainFilePrepared = fail
            default: hooks.afterDatabaseOpened = fail
            }
            XCTAssertThrowsError(try fixture.open(hooks: hooks)) { XCTAssertEqual($0 as? CollectorOwnerFixture.Failure, .injected) }
            XCTAssertTrue(visited, "boundary \(boundary)")
            XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
            let retry = try XCTUnwrap(fixture.open(ownerRunID: "retry"))
            try retry.close()
            XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
        }
    }

    func testDeinitializationReleasesOwnerWithoutUnlinkingLock() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        var owner: CollectorInventoryOwner? = try XCTUnwrap(fixture.open())
        _ = try owner!.enrollAndActivateRoot(fixture.configuration)
        let identity = try fixture.fileIdentity(fixture.lockURL)
        owner = nil
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
        XCTAssertEqual(try fixture.fileIdentity(fixture.lockURL), identity)
        let next = try XCTUnwrap(fixture.open(ownerRunID: "after-deinit"))
        try next.close()
    }

    // N3-A event ingress tests. Existing N2 tests and fixture behavior stay frozen.
    func testN3OrdinaryEventsPersistDirtyCheckpointAndExactUTF8BudgetAfterReopen() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let sourceBefore = try fixture.snapshot(at: fixture.sourceRoot)
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        let before = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        let path = "rollout-一.jsonl"
        let checkpoint = CollectorEventCheckpoint(epoch: "流", cursor: "甲")
        let budget = n3Budget(maxIncomingPaths: 2, maxPathUTF8Bytes: path.utf8.count,
                              maxTotalPathUTF8Bytes: 2 * path.utf8.count, maxCheckpointUTF8Bytes: 6)
        XCTAssertGreaterThan(path.utf8.count, path.count)
        XCTAssertEqual(try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                            nextCheckpoint: checkpoint, dirtyRelativePaths: [path, path], budget: budget),
                       .applied(inputPathCount: 2, checkpoint: checkpoint))
        let after = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        n3AssertCheckpoint(after.eventCheckpoint, checkpoint)
        XCTAssertEqual(after.requestedRevision, before.requestedRevision)
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT SUM(dirty_revision) FROM collector_locators"), 2)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE observed_generation IS NULL AND acknowledged_revision = 0"), 1)
        let reopened = try XCTUnwrap(fixture.open(ownerRunID: "n3-reopen"))
        defer { try? reopened.close() }
        let persisted = try XCTUnwrap(reopened.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(persisted, after)
        n3AssertCheckpoint(persisted.eventCheckpoint, checkpoint)
        try reopened.close()
        XCTAssertEqual(try fixture.snapshot(at: fixture.sourceRoot), sourceBefore)
        XCTAssertEqual(try fixture.snapshot(at: fixture.liveRoot), liveBefore)
    }

    func testN3OrdinaryEventsRejectUnknownUnenrolledAndInactiveRoots() throws {
        for variant in 0..<3 {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            if variant == 1 { try n3SeedRegisteredUnboundRoot(fixture) }
            if variant == 2 {
                let first = try XCTUnwrap(fixture.open(ownerRunID: "n3-first"))
                defer { try? first.close() }
                _ = try first.enrollAndActivateRoot(fixture.configuration)
                try first.close()
            }
            let owner = try XCTUnwrap(fixture.open(ownerRunID: "n3-fenced"))
            defer { try? owner.close() }
            let before = try owner.rootState(rootID: fixture.configuration.rootID)
            XCTAssertThrowsError(try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                                       nextCheckpoint: .init(epoch: "epoch", cursor: "opaque/a"),
                                                       dirtyRelativePaths: ["rollout-a.jsonl"], budget: n3Budget())) { error in
                switch variant {
                case 0: XCTAssertEqual(error as? CollectorInventoryError, .unknownRoot)
                case 1: XCTAssertEqual(error as? CollectorInventoryOwnerError, .rootNotEnrolled)
                default: XCTAssertEqual(error as? CollectorInventoryOwnerError, .rootNotActivated)
                }
            }
            if variant < 2 {
                XCTAssertThrowsError(try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .restart)) { error in
                    if variant == 0 { XCTAssertEqual(error as? CollectorInventoryError, .unknownRoot) }
                    else { XCTAssertEqual(error as? CollectorInventoryOwnerError, .rootNotEnrolled) }
                }
            }
            XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID), before)
            try owner.close()
            XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 0)
        }
    }

    func testN3BothEventEntriesRejectWrongSourcePathAndOldRevisionConfiguration() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let nested = fixture.sourceRoot.appendingPathComponent("é")
        try fixture.directory(nested)
        let old = CollectorRootConfiguration(rootID: "root-é", source: .codex, rootPath: fixture.sourceRoot.path + "/é", revision: 1)
        let current = CollectorRootConfiguration(rootID: old.rootID, source: old.source, rootPath: old.rootPath, revision: 2)
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(old)
        _ = try owner.enrollAndActivateRoot(current)
        let before = try owner.rootState(rootID: current.rootID)
        let wrongPath = fixture.sourceRoot.path + "/e\u{301}"
        XCTAssertEqual(wrongPath, current.rootPath, "positive control: Swift canonical equality is insufficient")
        XCTAssertNotEqual(Data(wrongPath.utf8), Data(current.rootPath.utf8))
        let mismatches = [
            old,
            CollectorRootConfiguration(rootID: current.rootID, source: .claudeCode, rootPath: current.rootPath, revision: 2),
            CollectorRootConfiguration(rootID: current.rootID, source: .codex, rootPath: wrongPath, revision: 2),
            CollectorRootConfiguration(rootID: "root-e\u{301}", source: .codex, rootPath: current.rootPath, revision: 2),
        ]
        for configuration in mismatches {
            XCTAssertThrowsError(try owner.applyEvents(configuration: configuration, expectedCheckpoint: nil,
                                                       nextCheckpoint: .init(epoch: "epoch", cursor: "opaque/a"),
                                                       dirtyRelativePaths: ["rollout-a.jsonl"], budget: n3Budget())) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
            XCTAssertThrowsError(try owner.requestEventReconciliation(configuration: configuration, reason: .overflow)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
            XCTAssertEqual(try owner.rootState(rootID: current.rootID), before)
        }
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 0)
    }

    func testN3OrdinaryEventsRejectPhysicalRootReplacementButGapOnlySurvivesMissingRoot() throws {
        for missing in [false, true] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let owner = try XCTUnwrap(fixture.open())
            defer { try? owner.close() }
            _ = try owner.enrollAndActivateRoot(fixture.configuration)
            let before = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
            if missing { try FileManager.default.moveItem(at: fixture.sourceRoot, to: fixture.sourceParent.appendingPathComponent("retired")) }
            else { try fixture.replaceSourceRoot() }
            let expected: CollectorPOSIXEnumerationError = missing ? .io(.openComponent, ENOENT) : .rootIdentityChanged
            XCTAssertThrowsError(try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                                       nextCheckpoint: .init(epoch: "epoch", cursor: "opaque/a"),
                                                       dirtyRelativePaths: ["rollout-a.jsonl"], budget: n3Budget())) {
                XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, expected)
            }
            XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID), before)
            XCTAssertEqual(try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .continuityLoss),
                           .reconciliationRequested(reason: .continuityLoss, requestedRevision: before.requestedRevision + 1))
            let after = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
            XCTAssertNil(after.eventCheckpoint)
            XCTAssertEqual(after.completedRevision, before.completedRevision)
            try owner.close()
            XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 0)
            let reopened = try XCTUnwrap(fixture.open(ownerRunID: "n3-reopen"))
            defer { try? reopened.close() }
            XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID), after)
            XCTAssertThrowsError(try reopened.enrollAndActivateRoot(fixture.configuration)) {
                XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, expected, "event ingress must not replace the persisted binding")
            }
            try reopened.close()
        }
    }

    func testN3AllExplicitGapReasonsPersistWithoutActivationAndNeverAdvanceCheckpoint() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let first = try XCTUnwrap(fixture.open(ownerRunID: "n3-first"))
        defer { try? first.close() }
        _ = try first.enrollAndActivateRoot(fixture.configuration)
        let checkpoint = CollectorEventCheckpoint(epoch: "epoch", cursor: "opaque/a")
        _ = try first.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil, nextCheckpoint: checkpoint,
                                  dirtyRelativePaths: ["rollout-seed.jsonl"], budget: n3Budget())
        try first.close()
        try FileManager.default.moveItem(at: fixture.sourceRoot, to: fixture.sourceParent.appendingPathComponent("retired"))
        let owner = try XCTUnwrap(fixture.open(ownerRunID: "n3-not-activated"))
        defer { try? owner.close() }
        let before = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        var requested = before.requestedRevision
        for reason: CollectorEventGapReason in [.overflow, .continuityLoss, .restart, .budgetExceeded] {
            requested += 1
            XCTAssertEqual(try owner.requestEventReconciliation(configuration: fixture.configuration, reason: reason),
                           .reconciliationRequested(reason: reason, requestedRevision: requested))
            let after = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
            XCTAssertEqual(after.requestedRevision, requested)
            XCTAssertEqual(after.completedRevision, before.completedRevision)
            n3AssertCheckpoint(after.eventCheckpoint, checkpoint)
        }
        let finalState = try owner.rootState(rootID: fixture.configuration.rootID)
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT SUM(dirty_revision) FROM collector_locators"), 1)
        let reopened = try XCTUnwrap(fixture.open(ownerRunID: "n3-gap-reopen"))
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID), finalState)
        try reopened.close()
    }

    func testN3OversizeBatchesPersistOnlyGapForEveryRawInputBudget() throws {
        let path = "rollout-一.jsonl"
        let checkpoint = CollectorEventCheckpoint(epoch: "流", cursor: "甲")
        let next = CollectorEventCheckpoint(epoch: "流", cursor: "乙")
        let budgets = [
            n3Budget(maxIncomingPaths: 1),
            n3Budget(maxPathUTF8Bytes: path.utf8.count - 1),
            n3Budget(maxTotalPathUTF8Bytes: 2 * path.utf8.count - 1),
            n3Budget(maxCheckpointUTF8Bytes: 11), // Expected and next together cost 12, not 6.
        ]
        for missing in [false, true] {
            for budget in budgets {
                let fixture = try CollectorOwnerFixture()
                defer { fixture.remove() }
                let owner = try XCTUnwrap(fixture.open())
                defer { try? owner.close() }
                _ = try owner.enrollAndActivateRoot(fixture.configuration)
                _ = try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                          nextCheckpoint: checkpoint, dirtyRelativePaths: ["rollout-seed.jsonl"], budget: n3Budget())
                let before = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
                if missing { try FileManager.default.moveItem(at: fixture.sourceRoot, to: fixture.sourceParent.appendingPathComponent("retired")) }
                XCTAssertEqual(try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: checkpoint,
                                                    nextCheckpoint: next, dirtyRelativePaths: [path, path], budget: budget),
                               .reconciliationRequested(reason: .budgetExceeded, requestedRevision: before.requestedRevision + 1))
                let after = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
                XCTAssertEqual(after.requestedRevision, before.requestedRevision + 1)
                XCTAssertEqual(after.completedRevision, before.completedRevision)
                n3AssertCheckpoint(after.eventCheckpoint, checkpoint)
                try owner.close()
                XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 1)
                XCTAssertEqual(try fixture.inventoryInteger("SELECT SUM(dirty_revision) FROM collector_locators"), 1)
                let reopened = try XCTUnwrap(fixture.open(ownerRunID: "n3-oversize-reopen"))
                defer { try? reopened.close() }
                XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID), after)
                try reopened.close()
            }
        }
    }

    func testN3OversizeCannotBypassUnknownInactiveOrWrongConfigurationFences() throws {
        for variant in 0..<5 {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            if variant == 1 { try n3SeedRegisteredUnboundRoot(fixture) }
            if variant == 2 {
                let first = try XCTUnwrap(fixture.open(ownerRunID: "n3-first"))
                defer { try? first.close() }
                _ = try first.enrollAndActivateRoot(fixture.configuration)
                try first.close()
            }
            let owner = try XCTUnwrap(fixture.open(ownerRunID: "n3-oversize-fence"))
            defer { try? owner.close() }
            if variant >= 3 { _ = try owner.enrollAndActivateRoot(fixture.configuration) }
            let configuration: CollectorRootConfiguration
            if variant == 3 { configuration = fixture.configuration(source: .claudeCode) }
            else if variant == 4 { configuration = .init(rootID: fixture.configuration.rootID, source: .codex, rootPath: fixture.sourceRoot.path, revision: 0) }
            else { configuration = fixture.configuration }
            let before = try owner.rootState(rootID: fixture.configuration.rootID)
            XCTAssertThrowsError(try owner.applyEvents(configuration: configuration, expectedCheckpoint: nil,
                                                       nextCheckpoint: .init(epoch: "epoch", cursor: "opaque/a"),
                                                       dirtyRelativePaths: ["rollout-a.jsonl", "rollout-a.jsonl"],
                                                       budget: n3Budget(maxIncomingPaths: 1))) { error in
                switch variant {
                case 1: XCTAssertEqual(error as? CollectorInventoryOwnerError, .rootNotEnrolled)
                case 2: XCTAssertEqual(error as? CollectorInventoryOwnerError, .rootNotActivated)
                default: XCTAssertEqual(error as? CollectorInventoryError, .unknownRoot)
                }
            }
            XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID), before)
            try owner.close()
            XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 0)
        }
    }

    func testN3InvalidBudgetsAndPathsRejectEntireBatchWithoutGapOrDirtyPrefix() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        let before = try owner.rootState(rootID: fixture.configuration.rootID)
        for budget in [n3Budget(maxIncomingPaths: -1), n3Budget(maxPathUTF8Bytes: -1),
                       n3Budget(maxTotalPathUTF8Bytes: -1), n3Budget(maxCheckpointUTF8Bytes: -1)] {
            XCTAssertThrowsError(try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                                       nextCheckpoint: .init(epoch: "epoch", cursor: "opaque/a"),
                                                       dirtyRelativePaths: ["rollout-safe.jsonl"], budget: budget)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidBudget)
            }
            XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID), before)
        }
        for path in ["", "/absolute", "../escape", "a/./b", "a//b", "a/../b", "nul\0path"] {
            XCTAssertThrowsError(try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                                       nextCheckpoint: .init(epoch: "epoch", cursor: "opaque/a"),
                                                       dirtyRelativePaths: ["rollout-safe.jsonl", path], budget: n3Budget())) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidRelativePath)
            }
            XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID), before)
        }
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 0)
    }

    func testN3CheckpointTokensAreByteExactBoundedOpaqueValues() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        let checkpoint = CollectorEventCheckpoint(epoch: "é", cursor: "café")
        _ = try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil, nextCheckpoint: checkpoint,
                                  dirtyRelativePaths: ["rollout-seed.jsonl"], budget: n3Budget())
        let before = try owner.rootState(rootID: fixture.configuration.rootID)
        let decomposed = CollectorEventCheckpoint(epoch: "e\u{301}", cursor: "cafe\u{301}")
        XCTAssertEqual(checkpoint, decomposed, "positive control: synthesized Swift equality is not a byte fence")
        XCTAssertNotEqual(Data(checkpoint.epoch.utf8), Data(decomposed.epoch.utf8))
        let invalid: [(CollectorEventCheckpoint?, CollectorEventCheckpoint)] = [
            (nil, checkpoint),
            (.init(epoch: decomposed.epoch, cursor: checkpoint.cursor), checkpoint),
            (.init(epoch: checkpoint.epoch, cursor: decomposed.cursor), checkpoint),
            (checkpoint, .init(epoch: decomposed.epoch, cursor: "opaque/a")),
            (checkpoint, .init(epoch: "other-epoch", cursor: "opaque/a")),
            (.init(epoch: "", cursor: checkpoint.cursor), checkpoint),
            (.init(epoch: checkpoint.epoch, cursor: "bad\0expected"), checkpoint),
            (checkpoint, .init(epoch: "", cursor: "opaque/a")),
            (checkpoint, .init(epoch: checkpoint.epoch, cursor: "")),
            (checkpoint, .init(epoch: "bad\0epoch", cursor: "opaque/a")),
            (checkpoint, .init(epoch: checkpoint.epoch, cursor: "bad\0cursor")),
        ]
        for (expected, next) in invalid {
            XCTAssertThrowsError(try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: expected,
                                                       nextCheckpoint: next, dirtyRelativePaths: ["rollout-rejected.jsonl"], budget: n3Budget())) {
                XCTAssertEqual($0 as? CollectorInventoryError, .staleCheckpoint)
            }
            let state = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
            XCTAssertEqual(state, before)
            n3AssertCheckpoint(state.eventCheckpoint, checkpoint)
        }
        var previous = checkpoint
        for cursor in ["opaque/z", "opaque/a"] {
            let next = CollectorEventCheckpoint(epoch: checkpoint.epoch, cursor: cursor)
            XCTAssertEqual(try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: previous,
                                                nextCheckpoint: next, dirtyRelativePaths: [], budget: n3Budget()),
                           .applied(inputPathCount: 0, checkpoint: next), "no numeric or lexical native event ordering is assumed")
            previous = next
        }
        n3AssertCheckpoint(try owner.rootState(rootID: fixture.configuration.rootID)?.eventCheckpoint, previous)
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT SUM(dirty_revision) FROM collector_locators"), 1)
    }

    func testN3EventAndGapCommitFailuresRollBackIncludingCancellation() throws {
        for gapOnly in [false, true] {
            for cancellation in [false, true] {
                let fixture = try CollectorOwnerFixture()
                defer { fixture.remove() }
                var armed = false
                var visits = 0
                var hooks = CollectorInventoryOwnerTestHooks()
                hooks.beforeInventoryCommit = {
                    guard armed else { return }
                    visits += 1
                    if cancellation { throw CancellationError() }
                    throw CollectorOwnerFixture.Failure.injected
                }
                let owner = try XCTUnwrap(fixture.open(hooks: hooks))
                defer { try? owner.close() }
                _ = try owner.enrollAndActivateRoot(fixture.configuration)
                let before = try owner.rootState(rootID: fixture.configuration.rootID)
                let checkpoint = CollectorEventCheckpoint(epoch: "epoch", cursor: "opaque/a")
                armed = true
                XCTAssertThrowsError(try {
                    if gapOnly { return try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .overflow) }
                    return try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                                 nextCheckpoint: checkpoint, dirtyRelativePaths: ["rollout-a.jsonl", "rollout-b.jsonl"], budget: n3Budget())
                }()) { error in
                    if cancellation { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? CollectorOwnerFixture.Failure, .injected) }
                }
                XCTAssertEqual(visits, 1, "the failure must be inside the inventory transaction")
                XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID), before)
                try owner.close()
                XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 0)
                armed = false
                let retry = try XCTUnwrap(fixture.open(ownerRunID: "n3-retry", hooks: hooks))
                defer { try? retry.close() }
                XCTAssertEqual(try retry.rootState(rootID: fixture.configuration.rootID), before, "rollback must survive close and reopen")
                _ = try retry.enrollAndActivateRoot(fixture.configuration)
                let retryBefore = try XCTUnwrap(retry.rootState(rootID: fixture.configuration.rootID))
                if gapOnly {
                    XCTAssertEqual(try retry.requestEventReconciliation(configuration: fixture.configuration, reason: .overflow),
                                   .reconciliationRequested(reason: .overflow, requestedRevision: retryBefore.requestedRevision + 1))
                } else {
                    XCTAssertEqual(try retry.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                                        nextCheckpoint: checkpoint, dirtyRelativePaths: ["rollout-a.jsonl", "rollout-b.jsonl"], budget: n3Budget()),
                                   .applied(inputPathCount: 2, checkpoint: checkpoint))
                }
                try retry.close()
                XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), gapOnly ? 0 : 2)
            }
        }
    }

    func testN3GapDuringBoundedScanSurvivesOldCompletionAndReopen() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        for index in 0..<2 { try fixture.file(fixture.sourceRoot.appendingPathComponent("rollout-\(index).jsonl"), bytes: Data("synthetic".utf8)) }
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        let budget = CollectorBootstrapBudget(maxEntriesVisited: 1, maxCandidateFiles: 1, maxDirectoryOpens: 1, maxMetadataBytes: 4096)
        XCTAssertEqual(try owner.stepRoot(fixture.configuration, budget: budget).outcome, .paused(.budget))
        let before = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        let oldScan = try XCTUnwrap(before.activeScan)
        XCTAssertEqual(try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .overflow),
                       .reconciliationRequested(reason: .overflow, requestedRevision: before.requestedRevision + 1))
        XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID)?.activeScan, oldScan)
        var finished = false
        for _ in 0..<16 {
            if try owner.stepRoot(fixture.configuration, budget: budget).outcome == .finished { finished = true; break }
        }
        XCTAssertTrue(finished)
        let after = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        XCTAssertNil(after.activeScan)
        XCTAssertEqual(after.completedRevision, oldScan.requestedRevision)
        XCTAssertEqual(after.requestedRevision, before.requestedRevision + 1)
        XCTAssertGreaterThan(after.requestedRevision, after.completedRevision)
        XCTAssertNil(after.eventCheckpoint)
        try owner.close()
        let reopened = try XCTUnwrap(fixture.open(ownerRunID: "n3-scan-reopen"))
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID), after)
        _ = try reopened.enrollAndActivateRoot(fixture.configuration)
        var reconciled = false
        for _ in 0..<16 {
            if try reopened.stepRoot(fixture.configuration, budget: budget).outcome == .finished { reconciled = true; break }
        }
        XCTAssertTrue(reconciled)
        let reconciledState = try XCTUnwrap(reopened.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(reconciledState.completedRevision, reconciledState.requestedRevision)
        try reopened.close()
    }

    func testN3CancellationBeforeAndAtCommitForOrdinaryOversizeAndGapLeavesStateUnchanged() async throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        var commits = 0
        var armed = false
        var cancelCurrentTask: (() -> Void)?
        var hooks = CollectorInventoryOwnerTestHooks()
        hooks.beforeInventoryCommit = {
            guard armed else { return }
            commits += 1
            // Returning normally after cancellation must still roll back.
            cancelCurrentTask?()
        }
        let owner = try XCTUnwrap(fixture.open(hooks: hooks))
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        let before = try owner.rootState(rootID: fixture.configuration.rootID)
        armed = true
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            for variant in 0..<3 {
                XCTAssertThrowsError(try {
                    if variant == 2 { return try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .restart) }
                    let budget = self.n3Budget(maxIncomingPaths: variant == 1 ? 0 : 64)
                    return try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                                 nextCheckpoint: .init(epoch: "epoch", cursor: "opaque/a"),
                                                 dirtyRelativePaths: ["rollout-a.jsonl"], budget: budget)
                }()) { XCTAssertTrue($0 is CancellationError, "entry variant \(variant)") }
            }
        }
        try await task.value
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID), before)
        for variant in 0..<3 {
            let duringCommit = Task {
                try withUnsafeCurrentTask { currentTask in
                    XCTAssertNotNil(currentTask)
                    XCTAssertFalse(Task.isCancelled)
                    cancelCurrentTask = { currentTask?.cancel() }
                    // Never retain the borrowed task handle beyond this scope.
                    defer { cancelCurrentTask = nil }
                    XCTAssertThrowsError(try {
                        if variant == 2 { return try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .restart) }
                        let budget = self.n3Budget(maxIncomingPaths: variant == 1 ? 0 : 64)
                        return try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                                     nextCheckpoint: .init(epoch: "epoch", cursor: "opaque/a"),
                                                     dirtyRelativePaths: ["rollout-a.jsonl"], budget: budget)
                    }()) { XCTAssertTrue($0 is CancellationError, "commit variant \(variant)") }
                    XCTAssertTrue(Task.isCancelled)
                }
            }
            try await duringCommit.value
            XCTAssertEqual(commits, variant + 1)
            XCTAssertEqual(try owner.rootState(rootID: fixture.configuration.rootID), before)
        }
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 0)
    }

    func testN3ClosedOwnerRejectsBothEventEntryPointsWithoutTouchingInventory() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let owner = try XCTUnwrap(fixture.open())
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        try owner.close()
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                                   nextCheckpoint: .init(epoch: "epoch", cursor: "opaque/a"),
                                                   dirtyRelativePaths: ["rollout-a.jsonl"], budget: n3Budget())) {
            XCTAssertEqual($0 as? CollectorInventoryOwnerError, .closed)
        }
        XCTAssertThrowsError(try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .restart)) {
            XCTAssertEqual($0 as? CollectorInventoryOwnerError, .closed)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
    }

    private func n3Budget(
        maxIncomingPaths: Int = 64, maxPathUTF8Bytes: Int = 4096,
        maxTotalPathUTF8Bytes: Int = 65_536, maxCheckpointUTF8Bytes: Int = 4096
    ) -> CollectorEventIngressBudget {
        .init(maxIncomingPaths: maxIncomingPaths, maxPathUTF8Bytes: maxPathUTF8Bytes,
              maxTotalPathUTF8Bytes: maxTotalPathUTF8Bytes, maxCheckpointUTF8Bytes: maxCheckpointUTF8Bytes)
    }

    private func n3AssertCheckpoint(
        _ actual: CollectorEventCheckpoint?, _ expected: CollectorEventCheckpoint,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.map { Data($0.epoch.utf8) }, Data(expected.epoch.utf8), file: file, line: line)
        XCTAssertEqual(actual.map { Data($0.cursor.utf8) }, Data(expected.cursor.utf8), file: file, line: line)
    }

    private func n3SeedRegisteredUnboundRoot(_ fixture: CollectorOwnerFixture) throws {
        try fixture.seedInventory()
        let queue = try DatabaseQueue(path: fixture.inventoryURL.path)
        defer { try? queue.close() }
        let store = try CollectorInventoryStore(database: queue, machineID: CollectorOwnerFixture.machineID, ownerRunID: "n3-unbound-seed")
        try store.registerRoot(fixture.configuration)
        try queue.close()
        guard chmod(fixture.inventoryURL.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
    }
    // End N3-A event ingress tests.

    private func assertRejected(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertNotEqual(error as? CollectorInventoryOwnerError, .notImplemented, "a RED stub is not a security rejection", file: file, line: line)
            XCTAssertNotEqual(error as? CollectorPOSIXEnumerationError, .notImplemented, "a RED stub is not physical validation", file: file, line: line)
        }
    }

    private func runOwnerProbe(mode: String, fixture: CollectorOwnerFixture) throws {
        let bundle = Bundle(for: Self.self).bundleURL
        let products = bundle.deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "EngramCollectorCoreTests.CollectorInventoryOwnerTests/testIndependentProcessOwnerExclusionAndCloseOnExec", bundle.path]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DYLD_FRAMEWORK_PATH": products, "DYLD_LIBRARY_PATH": products,
            "ENGRAM_N2_OWNER_PROBE_MODE": mode, "ENGRAM_N2_OWNER_PARENT_PID": String(getpid()),
            "ENGRAM_N2_OWNER_SHADOW": fixture.shadowRoot.path, "ENGRAM_N2_OWNER_CATALOG": fixture.liveCatalog.path,
            "ENGRAM_N2_OWNER_FIXTURE": fixture.base.path,
        ]
        // Only test-loader necessities are inherited. No credentials or agent state.
        for key in ["DEVELOPER_DIR", "CFFIXED_USER_HOME", "TEST_RUNNER_CFFIXED_USER_HOME", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { process.environment?[key] = value }
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("N2_OWNER_PROBE_SUCCESS:\(mode);pid="), text)
    }
}

private final class CollectorOwnerFixture {
    enum Failure: Error, Equatable { case injected }
    static let machineID = "11111111-2222-3333-4444-555555555555"
    static let otherMachineID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    let base: URL
    let liveRoot: URL
    let shadowRoot: URL
    let sourceParent: URL
    let sourceRoot: URL
    var liveCatalog: URL { liveRoot.appendingPathComponent("archive.sqlite") }
    var shadowCatalog: URL { shadowRoot.appendingPathComponent("archive.sqlite") }
    var inventoryDirectory: URL { shadowRoot.appendingPathComponent("inventory") }
    var inventoryURL: URL { inventoryDirectory.appendingPathComponent("inventory.sqlite") }
    var lockURL: URL { shadowRoot.appendingPathComponent("collector-owner.lock") }
    var configuration: CollectorRootConfiguration { configuration() }
    var budget: CollectorBootstrapBudget { .init(maxEntriesVisited: 16, maxCandidateFiles: 8, maxDirectoryOpens: 2, maxMetadataBytes: 8192) }

    init() throws {
        // Only this test's unique directory inside its checkout is created or removed.
        let donor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard donor.path.hasPrefix("/Users/") else { throw POSIXError(.EINVAL) }
        let directory = donor.appendingPathComponent(".engram-n2-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        base = directory
        liveRoot = base.appendingPathComponent("live")
        shadowRoot = base.appendingPathComponent("task/shadow")
        sourceParent = base.appendingPathComponent("sources")
        sourceRoot = sourceParent.appendingPathComponent("sessions")
        do {
            for url in [liveRoot, base.appendingPathComponent("task"), shadowRoot, sourceParent, sourceRoot] { try self.directory(url) }
            try catalog(liveCatalog)
            try catalog(shadowCatalog)
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
    }

    init(parentDirectory: URL) throws {
        let directory = parentDirectory.appendingPathComponent("engram-n2-owner-firmlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        base = directory.resolvingSymlinksInPath()
        liveRoot = base.appendingPathComponent("live")
        shadowRoot = base.appendingPathComponent("task/shadow")
        sourceParent = base.appendingPathComponent("sources")
        sourceRoot = sourceParent.appendingPathComponent("sessions")
        do {
            for url in [liveRoot, base.appendingPathComponent("task"), shadowRoot, sourceParent, sourceRoot] { try self.directory(url) }
            try catalog(liveCatalog)
            try catalog(shadowCatalog)
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func file(_ url: URL, bytes: Data) throws {
        try bytes.write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
    }

    func catalog(_ url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [Self.machineID])
        }
        try queue.close()
        guard chmod(url.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
    }

    func setIdentity(at url: URL, value: String?) throws {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: "DELETE FROM archive_metadata")
            if let value { try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [value]) }
        }
        try queue.close()
    }

    func seedInventory() throws {
        try directory(inventoryDirectory)
        let queue = try DatabaseQueue(path: inventoryURL.path)
        defer { try? queue.close() }
        _ = try CollectorInventoryStore(database: queue, machineID: Self.machineID, ownerRunID: "fixture-seed")
        try queue.close()
        guard chmod(inventoryURL.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
    }

    func open(
        ownerRunID: String = "owner-one", shadowRoot: URL? = nil, identityCatalog: URL? = nil,
        hooks: CollectorInventoryOwnerTestHooks = .init()
    ) throws -> CollectorInventoryOwner? {
        try CollectorInventoryOwner.open(enabled: true, shadowRoot: shadowRoot ?? self.shadowRoot, identityCatalog: identityCatalog ?? liveCatalog, ownerRunID: ownerRunID, testHooks: hooks)
    }

    func configuration(path: String? = nil, source: SourceName = .codex) -> CollectorRootConfiguration {
        .init(rootID: "synthetic-root", source: source, rootPath: path ?? sourceRoot.path, revision: 1)
    }

    func physicalIdentity() throws -> CollectorPOSIXDirectoryIdentity {
        var info = stat()
        guard lstat(sourceRoot.path, &info) == 0, let inode = Int64(exactly: info.st_ino) else { throw POSIXError(.ENOENT) }
        return .init(device: Int64(info.st_dev), inode: inode, generation: info.st_gen, birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }

    func replaceSourceRoot() throws {
        let moved = sourceParent.appendingPathComponent("original-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: sourceRoot, to: moved)
        try directory(sourceRoot)
    }

    func inventoryText(_ sql: String) throws -> String? {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: inventoryURL.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { try String.fetchOne($0, sql: sql) }
    }

    func inventoryInteger(_ sql: String) throws -> Int64? {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: inventoryURL.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { try Int64.fetchOne($0, sql: sql) }
    }

    func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_mode
    }

    struct Identity: Equatable { let device: dev_t; let inode: ino_t }
    func fileIdentity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return .init(device: info.st_dev, inode: info.st_ino)
    }

    struct Snapshot: Equatable {
        let mode: mode_t
        let owner: uid_t
        let links: nlink_t
        let identity: Identity
        let bytes: Data?
        let symlink: String?
    }

    func snapshot(at selected: URL? = nil) throws -> [String: Snapshot] {
        let selected = selected ?? base
        var paths = [selected]
        if try mode(selected) & S_IFMT == S_IFDIR {
            let entries = try XCTUnwrap(FileManager.default.enumerator(at: selected, includingPropertiesForKeys: nil))
            paths += entries.allObjects.compactMap { $0 as? URL }
        }
        var result: [String: Snapshot] = [:]
        for url in paths {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
            let kind = info.st_mode & S_IFMT
            result[url.path] = Snapshot(
                mode: info.st_mode, owner: info.st_uid, links: info.st_nlink,
                identity: .init(device: info.st_dev, inode: info.st_ino),
                bytes: kind == S_IFREG ? try Data(contentsOf: url) : nil,
                symlink: kind == S_IFLNK ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
            )
        }
        return result
    }
}

private final class CollectorOwnerDescriptorObservation {
    var opened = 0
    var live: Set<Int32> = []
    var hooks: CollectorPOSIXRootEnumeratorTestHooks {
        var hooks = CollectorPOSIXRootEnumeratorTestHooks()
        hooks.didOpenDescriptor = { self.opened += 1; self.live.insert($0) }
        hooks.didCloseDescriptor = { descriptor, _ in self.live.remove(descriptor) }
        return hooks
    }
}

private func collectorOwnerFixtureDescriptors(under root: URL) throws -> [Int32] {
    // Read only this test process's fd numbers, retain matches under its unique
    // synthetic fixture, and never print unrelated paths or inspect other PIDs.
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { name -> Int32? in
        guard let descriptor = Int32(name) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { return nil }
        let path = String(cString: buffer)
        return path == root.path || path.hasPrefix(root.path + "/") ? descriptor : nil
    }.sorted()
}
