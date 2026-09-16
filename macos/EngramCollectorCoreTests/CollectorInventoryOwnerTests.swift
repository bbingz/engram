import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorInventoryOwnerTests: XCTestCase {
    func testVSCodeEventsKeepOnlyPrimaryJournalsOutOfSidecarQueue() throws {
        let f = try CollectorOwnerFixture(); defer { f.remove() }
        let configuration = f.configuration(source: .vscode)
        let owner = try XCTUnwrap(f.open()); defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(configuration)
        _ = try owner.applyEvents(configuration: configuration, expectedCheckpoint: nil,
            nextCheckpoint: .init(epoch: "vscode", cursor: "1"),
            dirtyRelativePaths: ["ws/chatSessions/a.jsonl", "ws/workspace.json", "ws/state.vscdb", "ws/cache/other.jsonl"],
            budget: n3Budget())
        XCTAssertEqual(try f.inventoryInteger("SELECT count(*) FROM collector_locators"), 1)
        XCTAssertEqual(try f.inventoryText("SELECT relative_path FROM collector_locators"), "ws/chatSessions/a.jsonl")
    }

    func testExplicitCursorLegacyWALRoutesOnlyToDatabasePrimary() throws {
        let f = try CollectorOwnerFixture(); defer { f.remove() }
        let root = f.sourceRoot.appendingPathComponent("globalStorage")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("main".utf8).write(to: root.appendingPathComponent("state.vscdb"))
        try Data("wal".utf8).write(to: root.appendingPathComponent("state.vscdb-wal"))
        let configuration = CollectorRootConfiguration(rootID: "legacy", source: .cursor,
            rootPath: root.path, revision: 1, cursorLegacy: true)
        let owner = try XCTUnwrap(f.open()); defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(configuration)
        let next = CollectorEventCheckpoint(epoch: "legacy", cursor: "1")
        _ = try owner.applyEvents(configuration: configuration, expectedCheckpoint: nil,
            nextCheckpoint: next, dirtyRelativePaths: ["state.vscdb-wal", "state.vscdb-shm",
                "state.vscdb-journal", "chats/ws/id/store.db"], budget: n3Budget())
        XCTAssertEqual(try f.inventoryInteger("SELECT count(*) FROM collector_locators"), 1)
        XCTAssertEqual(try f.inventoryText("SELECT relative_path FROM collector_locators"), "state.vscdb")
        _ = try owner.applyEvents(configuration: configuration, expectedCheckpoint: next,
            nextCheckpoint: .init(epoch: "legacy", cursor: "2"),
            dirtyRelativePaths: ["state.vscdb-wal", "state.vscdb-shm", "state.vscdb-journal"], budget: n3Budget())
        XCTAssertEqual(try f.inventoryInteger("SELECT dirty_revision FROM collector_locators"), 1)
    }

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

    func testObservationFactoryReturnsRealFiveTupleForSupportedSources() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let descriptors = CollectorOwnerDescriptorObservation()
        for source in [SourceName.codex, .claudeCode, .vscode] {
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
            fixture.configuration(path: "/"),
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

    func testDirectoryEventsEnqueueTargetedScanWithoutRevisionBump() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        try fixture.directory(fixture.sourceRoot.appendingPathComponent("sibling"))
        try fixture.file(fixture.sourceRoot.appendingPathComponent("sibling/rollout-unrelated.jsonl"), bytes: Data("fixture".utf8))
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        for _ in 0..<16 {
            let current = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
            if current.completedRevision >= current.requestedRevision { break }
            _ = try owner.stepRoot(fixture.configuration, budget: fixture.budget)
        }
        let before = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(before.requestedRevision, before.completedRevision)
        XCTAssertNil(before.activeScan)
        try fixture.directory(fixture.sourceRoot.appendingPathComponent("newdir"))
        try fixture.file(fixture.sourceRoot.appendingPathComponent("newdir/rollout-hidden.jsonl"), bytes: Data("fixture".utf8))
        try fixture.file(fixture.sourceRoot.appendingPathComponent("newdir/rollout-visible.jsonl"), bytes: Data("fixture".utf8))
        let checkpoint = CollectorEventCheckpoint(epoch: "epoch", cursor: "dir-1")
        XCTAssertEqual(
            try owner.applyEvents(
                configuration: fixture.configuration, expectedCheckpoint: before.eventCheckpoint,
                nextCheckpoint: checkpoint, dirtyRelativePaths: ["newdir/rollout-visible.jsonl"],
                dirtyRelativeDirectories: ["newdir"], budget: n3Budget()
            ),
            .applied(inputPathCount: 2, checkpoint: checkpoint)
        )
        let after = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(after.requestedRevision, before.requestedRevision)
        XCTAssertEqual(after.completedRevision, before.completedRevision)
        XCTAssertNotNil(after.activeScan)
        for _ in 0..<16 {
            if try owner.rootState(rootID: fixture.configuration.rootID)?.activeScan == nil { break }
            _ = try owner.stepRoot(fixture.configuration, budget: fixture.budget)
        }
        XCTAssertNil(try owner.rootState(rootID: fixture.configuration.rootID)?.activeScan)
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'newdir/rollout-visible.jsonl'"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'newdir/rollout-hidden.jsonl'"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'sibling/rollout-unrelated.jsonl'"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("""
            SELECT COUNT(*) FROM collector_frontier
            WHERE relative_directory = 'sibling' AND scan_id IN (
                SELECT scan_id FROM collector_frontier WHERE relative_directory = 'newdir'
            )
            """), 0)
    }

    func testRepeatedDirectoryEventDuringPendingScanFindsNewChildrenWithoutSiblingWalk() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        try fixture.directory(fixture.sourceRoot.appendingPathComponent("sibling"))
        try fixture.file(fixture.sourceRoot.appendingPathComponent("sibling/rollout-unrelated.jsonl"), bytes: Data("fixture".utf8))
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        for _ in 0..<16 {
            let current = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
            if current.completedRevision >= current.requestedRevision { break }
            _ = try owner.stepRoot(fixture.configuration, budget: fixture.budget)
        }
        let ready = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        try fixture.directory(fixture.sourceRoot.appendingPathComponent("alpha"))
        try fixture.directory(fixture.sourceRoot.appendingPathComponent("zeta"))
        try fixture.file(fixture.sourceRoot.appendingPathComponent("alpha/rollout-old.jsonl"), bytes: Data("fixture".utf8))
        try fixture.file(fixture.sourceRoot.appendingPathComponent("zeta/rollout-keep.jsonl"), bytes: Data("fixture".utf8))
        XCTAssertEqual(
            try owner.applyEvents(
                configuration: fixture.configuration, expectedCheckpoint: ready.eventCheckpoint,
                nextCheckpoint: .init(epoch: "epoch", cursor: "dir-1"),
                dirtyRelativePaths: [], dirtyRelativeDirectories: ["alpha", "zeta"], budget: n3Budget()
            ),
            .applied(inputPathCount: 2, checkpoint: .init(epoch: "epoch", cursor: "dir-1"))
        )
        let scan = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID)?.activeScan)
        let tiny = CollectorBootstrapBudget(
            maxEntriesVisited: 1, maxCandidateFiles: 1, maxDirectoryOpens: 1, maxMetadataBytes: 4096
        )
        var reopened = false
        for _ in 0..<24 {
            let pending = try fixture.inventoryInteger("""
                SELECT COUNT(*) FROM collector_frontier
                WHERE scan_id = '\(scan.scanID)' AND relative_directory = 'alpha' AND completed = 0
                """)
            let zetaPending = try fixture.inventoryInteger("""
                SELECT COUNT(*) FROM collector_frontier
                WHERE scan_id = '\(scan.scanID)' AND relative_directory = 'zeta' AND completed = 0
                """)
            if pending == 0, zetaPending == 1 {
                reopened = true
                break
            }
            _ = try owner.stepRoot(fixture.configuration, budget: tiny)
        }
        XCTAssertTrue(reopened, "alpha must finish while zeta remains pending")
        try fixture.file(fixture.sourceRoot.appendingPathComponent("alpha/rollout-new.jsonl"), bytes: Data("fixture".utf8))
        XCTAssertEqual(
            try owner.applyEvents(
                configuration: fixture.configuration,
                expectedCheckpoint: .init(epoch: "epoch", cursor: "dir-1"),
                nextCheckpoint: .init(epoch: "epoch", cursor: "dir-2"),
                dirtyRelativePaths: [], dirtyRelativeDirectories: ["alpha"], budget: n3Budget()
            ),
            .applied(inputPathCount: 1, checkpoint: .init(epoch: "epoch", cursor: "dir-2"))
        )
        let afterRepeat = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(afterRepeat.requestedRevision, ready.requestedRevision)
        XCTAssertEqual(afterRepeat.activeScan, scan)
        XCTAssertEqual(try fixture.inventoryInteger("""
            SELECT completed FROM collector_frontier
            WHERE scan_id = '\(scan.scanID)' AND relative_directory = 'alpha'
            """), 0)
        for _ in 0..<24 {
            if try owner.rootState(rootID: fixture.configuration.rootID)?.activeScan == nil { break }
            _ = try owner.stepRoot(fixture.configuration, budget: fixture.budget)
        }
        XCTAssertNil(try owner.rootState(rootID: fixture.configuration.rootID)?.activeScan)
        try owner.close()
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'alpha/rollout-old.jsonl'"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'alpha/rollout-new.jsonl'"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'zeta/rollout-keep.jsonl'"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'sibling/rollout-unrelated.jsonl'"), 1)
        XCTAssertEqual(try fixture.inventoryInteger("""
            SELECT COUNT(*) FROM collector_frontier
            WHERE relative_directory = 'sibling' AND scan_id = '\(scan.scanID)'
            """), 0)
    }

    func testUnsafeDirectoryEventRequestsReconciliationWithoutApplyingPrefix() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        let before = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(
            try owner.applyEvents(
                configuration: fixture.configuration, expectedCheckpoint: nil,
                nextCheckpoint: .init(epoch: "epoch", cursor: "dir-1"),
                dirtyRelativePaths: ["safe.jsonl"], dirtyRelativeDirectories: ["../escape"],
                budget: n3Budget()
            ),
            .reconciliationRequested(reason: .continuityLoss, requestedRevision: before.requestedRevision + 1)
        )
        let after = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
        XCTAssertNil(after.eventCheckpoint)
        XCTAssertEqual(after.requestedRevision, before.requestedRevision + 1)
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

    // Cursor modern analogue of OpenCode applyEvents fingerprint skip
    // (`openCodeObservationFingerprint`). Repeated FSEvent batches that do not
    // change the closed file-set (store/WAL/meta/transcript plus declared
    // absences) must advance the event checkpoint without minting another
    // dirty revision on the canonical primary. SHM/journal stay observation-only.
    func testCursorModernUnchangedCompleteSetEventsAdvanceCheckpointWithoutRedirtyingPrimary_repro() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let configuration = fixture.configuration(source: .cursor)
        try writeCursorModernCompleteSet(fixture)
        let payloadBefore = try cursorModernPayloadSnapshot(fixture)
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(configuration)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 0)

        var checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: Self.cursorModernFSEventBatch, cursor: "1", expected: nil
        )
        try assertCursorModernPrimary(fixture, dirty: 1, acknowledged: 0)
        let observed = try fixture.inventoryText(
            "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
        )
        XCTAssertNotNil(observed)
        XCTAssertFalse(observed?.isEmpty ?? true, "complete-set observation must be stored so later identical batches can be skipped")

        for (index, cursor) in ["2", "3", "4"].enumerated() {
            checkpoint = try applyCursorModernEvents(
                owner, configuration, paths: Self.cursorModernFSEventBatch, cursor: cursor, expected: checkpoint
            )
            try assertCursorModernPrimary(fixture, dirty: 1, acknowledged: 0)
            XCTAssertEqual(
                try fixture.inventoryText(
                    "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
                ),
                observed,
                "unchanged complete-set batch \(index + 1) must not rewrite the stored fingerprint"
            )
        }

        try cursorModernWrite(fixture, Self.cursorModernSHM, Data("shm-chatter".utf8))
        try cursorModernWrite(fixture, Self.cursorModernJournal, Data("journal-chatter".utf8))
        checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: Self.cursorModernFSEventBatch, cursor: "5", expected: checkpoint
        )
        try assertCursorModernPrimary(fixture, dirty: 1, acknowledged: 0)
        XCTAssertEqual(
            try fixture.inventoryText(
                "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
            ),
            observed,
            "SHM/journal chatter is not part of the closed dependency set"
        )

        checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: [Self.cursorModernSHM, Self.cursorModernJournal], cursor: "6", expected: checkpoint
        )
        try assertCursorModernPrimary(fixture, dirty: 1, acknowledged: 0)
        n3AssertCheckpoint(try owner.rootState(rootID: configuration.rootID)?.eventCheckpoint, checkpoint)

        try owner.close()
        XCTAssertEqual(try cursorModernPayloadSnapshot(fixture), payloadBefore)
        XCTAssertEqual(try fixture.snapshot(at: fixture.liveRoot), liveBefore)
        XCTAssertEqual(
            try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_publications"), 0
        )
        XCTAssertEqual(
            try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_capture_reservations"), 0
        )
    }

    func testCursorModernWALMetaAndSidecarPresenceChangesStillDirtyWithoutClearingOutstandingWork_repro() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let configuration = fixture.configuration(source: .cursor)
        try writeCursorModernCompleteSet(fixture)
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(configuration)

        var checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: Self.cursorModernFSEventBatch, cursor: "10", expected: nil
        )
        try assertCursorModernPrimary(fixture, dirty: 1, acknowledged: 0)
        var observed = try fixture.inventoryText(
            "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
        )
        XCTAssertNotNil(observed)
        XCTAssertFalse(observed?.isEmpty ?? true)

        checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: Self.cursorModernFSEventBatch, cursor: "11", expected: checkpoint
        )
        try assertCursorModernPrimary(fixture, dirty: 1, acknowledged: 0)
        XCTAssertEqual(
            try fixture.inventoryText(
                "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
            ),
            observed
        )

        try cursorModernWrite(fixture, Self.cursorModernWAL, Data("WAL-only".utf8))
        checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: [Self.cursorModernWAL], cursor: "12", expected: checkpoint
        )
        try assertCursorModernPrimary(fixture, dirty: 2, acknowledged: 0)
        let afterWAL = try fixture.inventoryText(
            "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
        )
        XCTAssertNotEqual(afterWAL, observed, "WAL-only generation change must be visible on the primary fingerprint")
        observed = afterWAL

        checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: Self.cursorModernFSEventBatch, cursor: "13", expected: checkpoint
        )
        try assertCursorModernPrimary(fixture, dirty: 2, acknowledged: 0)
        XCTAssertEqual(
            try fixture.inventoryText(
                "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
            ),
            observed,
            "unchanged events must leave outstanding dirty work in place"
        )

        try cursorModernWrite(fixture, Self.cursorModernMeta, Data("meta-only-change".utf8))
        checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: [Self.cursorModernMeta], cursor: "14", expected: checkpoint
        )
        try assertCursorModernPrimary(fixture, dirty: 3, acknowledged: 0)
        let afterMeta = try fixture.inventoryText(
            "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
        )
        XCTAssertNotEqual(afterMeta, observed)
        observed = afterMeta

        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent(Self.cursorModernWAL))
        checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: [Self.cursorModernWAL], cursor: "15", expected: checkpoint
        )
        try assertCursorModernPrimary(fixture, dirty: 4, acknowledged: 0)
        let afterWALGone = try fixture.inventoryText(
            "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
        )
        XCTAssertNotEqual(afterWALGone, observed)
        observed = afterWALGone

        try cursorModernWrite(fixture, Self.cursorModernWAL, Data("WAL-reappeared".utf8))
        checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: [Self.cursorModernWAL], cursor: "16", expected: checkpoint
        )
        try assertCursorModernPrimary(fixture, dirty: 5, acknowledged: 0)
        let afterWALReturned = try fixture.inventoryText(
            "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
        )
        XCTAssertNotEqual(afterWALReturned, observed)
        observed = afterWALReturned

        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent(Self.cursorModernMeta))
        checkpoint = try applyCursorModernEvents(
            owner, configuration, paths: [Self.cursorModernMeta], cursor: "17", expected: checkpoint
        )
        try assertCursorModernPrimary(fixture, dirty: 6, acknowledged: 0)
        XCTAssertNotEqual(
            try fixture.inventoryText(
                "SELECT observed_generation FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"
            ),
            observed
        )
        n3AssertCheckpoint(try owner.rootState(rootID: configuration.rootID)?.eventCheckpoint, checkpoint)

        try owner.close()
        XCTAssertEqual(try fixture.snapshot(at: fixture.liveRoot), liveBefore)
    }

    func testCursorObservationPagesStayBoundedAndStaleHintsPreserveNewerWork() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let configuration = fixture.configuration(source: .cursor)
        try writeCursorModernCompleteSet(fixture)
        let secondPath = "projects/proj/agent-transcripts/sid2/sid2.jsonl"
        try cursorModernWrite(fixture, secondPath, Data("second".utf8))
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(configuration)
        let checkpoint = try applyCursorModernEvents(owner, configuration,
            paths: [Self.cursorModernPrimary, secondPath], cursor: "20", expected: nil)
        let claim = try n4Claim(owner, configuration, path: Self.cursorModernPrimary)
        XCTAssertEqual(try owner.acknowledge(claim, configuration: configuration, captureID: n4CaptureID), .acknowledged)
        let first = try owner.capturedDependencyObservationPage(configuration: configuration, after: nil, limit: 1)
        XCTAssertEqual(first.count, 1)
        let hint = try XCTUnwrap(first.first)
        XCTAssertEqual(hint.relativePath, Self.cursorModernPrimary)
        XCTAssertEqual(hint.dirtyRevision, hint.acknowledgedRevision)
        let second = try owner.capturedDependencyObservationPage(configuration: configuration, after: hint.relativePath, limit: 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.relativePath, secondPath)
        XCTAssertEqual(second.first?.acknowledgedRevision, 0, "uncaptured/dirty rows consume the page bound")
        XCTAssertTrue(try owner.capturedDependencyObservationPage(configuration: configuration, after: secondPath, limit: 1).isEmpty)
        for limit in [-1, 0, 65] {
            XCTAssertThrowsError(try owner.capturedDependencyObservationPage(configuration: configuration, after: nil, limit: limit))
        }
        XCTAssertThrowsError(try owner.capturedDependencyObservationPage(configuration: configuration, after: "../outside", limit: 1))

        try owner.dirtyCapturedDependencyObservation(configuration: configuration, locator: hint)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT dirty_revision FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"), 2)
        try owner.dirtyCapturedDependencyObservation(configuration: configuration, locator: hint)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT dirty_revision FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"), 2)
        let pending = try n4Claim(owner, configuration, path: secondPath)
        _ = try owner.acknowledge(pending, configuration: configuration, captureID: n4CaptureID)
        let newer = try n4Claim(owner, configuration, path: Self.cursorModernPrimary)
        _ = try owner.acknowledge(newer, configuration: configuration, captureID: String(repeating: "b", count: 64))
        let before = try fixture.inventoryInteger("SELECT dirty_revision FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'")
        try owner.dirtyCapturedDependencyObservation(configuration: configuration, locator: hint)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT dirty_revision FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"), before)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = '\(Self.cursorModernPrimary)'"), before)
        n3AssertCheckpoint(try owner.rootState(rootID: configuration.rootID)?.eventCheckpoint, checkpoint)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT count(*) FROM collector_capture_reservations"), 0)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT count(*) FROM collector_publications"), 0)
    }

    private static let cursorModernStore = "chats/ws/sid/store.db"
    private static let cursorModernWAL = "chats/ws/sid/store.db-wal"
    private static let cursorModernMeta = "chats/ws/sid/meta.json"
    private static let cursorModernSHM = "chats/ws/sid/store.db-shm"
    private static let cursorModernJournal = "chats/ws/sid/store.db-journal"
    private static let cursorModernPrimary = "projects/proj/agent-transcripts/sid/sid.jsonl"
    private static let cursorModernFSEventBatch = [
        cursorModernStore, cursorModernWAL, cursorModernWAL, cursorModernMeta,
        cursorModernPrimary, cursorModernSHM, cursorModernJournal,
    ]

    private func writeCursorModernCompleteSet(_ fixture: CollectorOwnerFixture) throws {
        try cursorModernWrite(fixture, Self.cursorModernStore, Data("STORE".utf8))
        try cursorModernWrite(fixture, Self.cursorModernWAL, Data("WAL".utf8))
        try cursorModernWrite(fixture, Self.cursorModernMeta, Data("meta-old".utf8))
        try cursorModernWrite(fixture, Self.cursorModernPrimary, Data("TRANSCRIPT\n".utf8))
        try cursorModernWrite(fixture, Self.cursorModernSHM, Data([1]))
        try cursorModernWrite(fixture, Self.cursorModernJournal, Data([2]))
    }

    private func cursorModernWrite(_ fixture: CollectorOwnerFixture, _ relative: String, _ bytes: Data) throws {
        var current = fixture.sourceRoot
        for part in relative.split(separator: "/").dropLast() {
            current = current.appendingPathComponent(String(part))
            if !FileManager.default.fileExists(atPath: current.path) {
                try fixture.directory(current)
            }
        }
        try fixture.file(fixture.sourceRoot.appendingPathComponent(relative), bytes: bytes)
    }

    private func cursorModernPayloadSnapshot(_ fixture: CollectorOwnerFixture) throws -> [String: Data] {
        let paths = [Self.cursorModernStore, Self.cursorModernWAL, Self.cursorModernMeta, Self.cursorModernPrimary]
        return try Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, try Data(contentsOf: fixture.sourceRoot.appendingPathComponent(path)))
        })
    }

    @discardableResult
    private func applyCursorModernEvents(
        _ owner: CollectorInventoryOwner, _ configuration: CollectorRootConfiguration,
        paths: [String], cursor: String, expected: CollectorEventCheckpoint?
    ) throws -> CollectorEventCheckpoint {
        let next = CollectorEventCheckpoint(epoch: "cursor-modern", cursor: cursor)
        XCTAssertEqual(
            try owner.applyEvents(
                configuration: configuration, expectedCheckpoint: expected, nextCheckpoint: next,
                dirtyRelativePaths: paths, budget: n3Budget(maxIncomingPaths: max(1, paths.count))
            ),
            .applied(inputPathCount: paths.count, checkpoint: next)
        )
        n3AssertCheckpoint(try owner.rootState(rootID: configuration.rootID)?.eventCheckpoint, next)
        return next
    }

    private func assertCursorModernPrimary(
        _ fixture: CollectorOwnerFixture, dirty: Int64, acknowledged: Int64,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators"), 1,
            "only the canonical transcript primary may be dirtied", file: file, line: line
        )
        XCTAssertEqual(
            try fixture.inventoryText("SELECT relative_path FROM collector_locators"),
            Self.cursorModernPrimary, file: file, line: line
        )
        XCTAssertEqual(
            try fixture.inventoryInteger("SELECT dirty_revision FROM collector_locators"), dirty,
            file: file, line: line
        )
        XCTAssertEqual(
            try fixture.inventoryInteger("SELECT acknowledged_revision FROM collector_locators"), acknowledged,
            file: file, line: line
        )
        for sidecar in [Self.cursorModernSHM, Self.cursorModernJournal, Self.cursorModernWAL, Self.cursorModernMeta] {
            XCTAssertEqual(
                try fixture.inventoryInteger(
                    "SELECT COUNT(*) FROM collector_locators WHERE relative_path = '\(sidecar)'"
                ),
                0, file: file, line: line
            )
        }
    }

    // N4a TEST-DRAFT only. Existing N2/N3 test bodies remain unchanged.
    func testN4ClaimPreservesCandidateLimitIncludingSixtyFourAndEmptyCorpus() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        let paths = (0..<67).map { String(format: "rollout-%03d.jsonl", $0) }
        try n4Mark(owner, fixture.configuration, paths)
        let first = try owner.claimDirty(configuration: fixture.configuration, limit: 64, now: 0)
        XCTAssertEqual(first.map(\.relativePath), Array(paths.prefix(64)))
        XCTAssertTrue(first.allSatisfy { $0.rootRevision == 1 && $0.dirtyRevision == 1 && $0.claimGeneration == 1 && $0.ownerRunID == "owner-one" })
        XCTAssertEqual(try fixture.inventoryText("SELECT claim_cursor FROM collector_roots"), paths[63])
        XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE claimed_dirty_revision = 1"), 64)
        let second = try owner.claimDirty(configuration: fixture.configuration, limit: 1, now: 0)
        XCTAssertEqual(second.map(\.relativePath), [paths[64]])
        let last = try owner.claimDirty(configuration: fixture.configuration, limit: 2, now: 0)
        XCTAssertEqual(last.map(\.relativePath), Array(paths.suffix(2)))
        for claim in first + second + last {
            XCTAssertEqual(try owner.acknowledge(claim, configuration: fixture.configuration, captureID: n4CaptureID), .acknowledged)
        }
        let beforeEmpty = try n4Audit(fixture)
        XCTAssertTrue(try owner.claimDirty(configuration: fixture.configuration, limit: 64, now: 0).isEmpty)
        XCTAssertEqual(try n4Audit(fixture), beforeEmpty, "empty work must not mint a cursor or lease")
    }

    func testN4RoundRobinCountsDeferredAndInflightCandidatesWithoutRefilling() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        try n4Mark(owner, fixture.configuration, ["a.jsonl", "b.jsonl", "c.jsonl"])
        let a = try n4Claim(owner, fixture.configuration, path: "a.jsonl")
        XCTAssertTrue(try owner.deferClaim(a, configuration: fixture.configuration, retryNotBefore: 100, reason: .unavailable))
        _ = try n4Claim(owner, fixture.configuration, path: "b.jsonl")
        _ = try n4Claim(owner, fixture.configuration, path: "c.jsonl")
        for expectedCursor in ["a.jsonl", "b.jsonl", "c.jsonl"] {
            XCTAssertTrue(try owner.claimDirty(configuration: fixture.configuration, limit: 1, now: 99).isEmpty)
            XCTAssertEqual(try fixture.inventoryText("SELECT claim_cursor FROM collector_roots"), expectedCursor)
            XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 3)
            XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM collector_locators WHERE claim_owner_run_id = 'owner-one'"), 2)
        }
        let due = try n4Claim(owner, fixture.configuration, path: "a.jsonl", now: 100)
        XCTAssertEqual(due.claimGeneration, a.claimGeneration + 1)
        XCTAssertEqual(due.dirtyRevision, a.dirtyRevision)
    }

    func testN4TypedDeferralPersistsOnlyFiniteCodesAndHonorsExactDueBoundary() throws {
        let codes: [(CollectorDirtyDeferReason, String)] = [
            (.sourceMissing, "sourceMissing"), (.rootReplaced, "rootReplaced"), (.unavailable, "unavailable"),
        ]
        for (reason, code) in codes {
            XCTAssertEqual(reason.rawValue, code)
            XCTAssertEqual(CollectorDirtyDeferReason(rawValue: code), reason)
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
            defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
            let owner = try XCTUnwrap(fixture.open())
            defer { try? owner.close() }
            _ = try owner.enrollAndActivateRoot(fixture.configuration)
            try n4Mark(owner, fixture.configuration, ["a.jsonl"])
            let claim = try n4Claim(owner, fixture.configuration)
            XCTAssertTrue(try owner.deferClaim(claim, configuration: fixture.configuration, retryNotBefore: 100, reason: reason))
            XCTAssertEqual(try fixture.inventoryText("SELECT last_error FROM collector_locators"), code)
            XCTAssertEqual(try fixture.inventoryInteger("SELECT retry_not_before FROM collector_locators"), 100)
            XCTAssertEqual(try fixture.inventoryInteger("SELECT acknowledged_revision FROM collector_locators"), 0)
            XCTAssertNil(try fixture.inventoryText("SELECT last_capture_id FROM collector_locators"))
            XCTAssertNil(try fixture.inventoryText("SELECT claim_owner_run_id FROM collector_locators"))
            let beforeEarly = try n4Audit(fixture)
            XCTAssertTrue(try owner.claimDirty(configuration: fixture.configuration, limit: 1, now: 99).isEmpty)
            XCTAssertEqual(try n4Audit(fixture), beforeEarly)
            let due = try n4Claim(owner, fixture.configuration, now: 100)
            XCTAssertEqual(due.claimGeneration, claim.claimGeneration + 1)
            XCTAssertNil(try fixture.inventoryInteger("SELECT retry_not_before FROM collector_locators"))
            XCTAssertEqual(try owner.acknowledge(due, configuration: fixture.configuration, captureID: n4CaptureID), .acknowledged)
            XCTAssertNil(try fixture.inventoryText("SELECT last_error FROM collector_locators"))
        }
        for invalid in ["", "/private/source.jsonl", "errno=2", "sourceMissing\0private", "SourceMissing", "uploaded"] {
            XCTAssertNil(CollectorDirtyDeferReason(rawValue: invalid))
        }
    }

    func testN4InvalidBudgetsDoNotEnterStoreOrAdvanceCursor() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
        let probe = N4CommitProbe()
        let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
        defer { try? owner.close() }
        let claim = try n4Prepare(.deferClaim, owner, fixture)
        let before = try n4Audit(fixture)
        probe.arm()
        for limit in [-1, 0, 65, Int.max] {
            XCTAssertThrowsError(try owner.claimDirty(configuration: fixture.configuration, limit: limit, now: 0)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidBudget)
            }
            XCTAssertEqual(try n4Audit(fixture), before)
        }
        XCTAssertThrowsError(try owner.claimDirty(configuration: fixture.configuration, limit: 1, now: -1)) {
            XCTAssertEqual($0 as? CollectorInventoryError, .invalidBudget)
        }
        XCTAssertThrowsError(try owner.deferClaim(claim, configuration: fixture.configuration, retryNotBefore: -1, reason: .unavailable)) {
            XCTAssertEqual($0 as? CollectorInventoryError, .invalidBudget)
        }
        XCTAssertEqual(probe.visits, 0)
        XCTAssertEqual(try n4Audit(fixture), before)
        probe.disarm()
        XCTAssertTrue(try owner.deferClaim(claim, configuration: fixture.configuration, retryNotBefore: 0, reason: .unavailable))
        XCTAssertEqual(try fixture.inventoryInteger("SELECT retry_not_before FROM collector_locators"), 0)
        _ = try n4Claim(owner, fixture.configuration, now: 0)
    }

    func testN4CaptureIDMustBeExactLowercaseSHA256BeforeStoreAccess() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
        let probe = N4CommitProbe()
        let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        try n4Mark(owner, fixture.configuration, ["a.jsonl"])
        let positive = try n4Claim(owner, fixture.configuration)
        XCTAssertEqual(try owner.acknowledge(positive, configuration: fixture.configuration, captureID: n4CaptureID), .acknowledged)
        try n4Mark(owner, fixture.configuration, ["a.jsonl"])
        let claim = try n4Claim(owner, fixture.configuration)
        let before = try n4Audit(fixture)
        probe.arm()
        let invalid = ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                       String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                       String(repeating: "a", count: 63) + "é", n4CaptureID + "\0suffix",
                       String(repeating: "a", count: 31) + "\0" + String(repeating: "a", count: 32),
                       " " + n4CaptureID, n4CaptureID + "\n"]
        for captureID in invalid {
            XCTAssertThrowsError(try owner.acknowledge(claim, configuration: fixture.configuration, captureID: captureID)) {
                XCTAssertEqual($0 as? CollectorInventoryOwnerError, .invalidCaptureID)
            }
            XCTAssertEqual(try n4Audit(fixture), before)
        }
        XCTAssertEqual(probe.visits, 0)
        probe.disarm()
        let valid = String(repeating: "0123456789abcdef", count: 4)
        XCTAssertEqual(try owner.acknowledge(claim, configuration: fixture.configuration, captureID: valid), .acknowledged)
        XCTAssertEqual(try fixture.inventoryText("SELECT last_capture_id FROM collector_locators"), valid)
    }

    func testN4ClaimConfigurationRootIdentityMismatchIsNotAStaleCompletion() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
        let probe = N4CommitProbe()
        let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
        defer { try? owner.close() }
        let configuration = CollectorRootConfiguration(rootID: "root-é", source: .codex, rootPath: fixture.sourceRoot.path, revision: 1)
        let claim = try n4Prepare(.deferClaim, owner, fixture, configuration: configuration)
        let decomposed = "root-e\u{301}"
        XCTAssertEqual(decomposed, configuration.rootID)
        XCTAssertNotEqual(Data(decomposed.utf8), Data(configuration.rootID.utf8))
        let forgeries = [
            n4Copy(claim, rootID: "other-root"),
            n4Copy(claim, rootID: decomposed),
            n4Copy(claim, rootID: configuration.rootID + "\0suffix"),
            n4Copy(claim, rootRevision: 2),
        ]
        let before = try n4Audit(fixture)
        probe.arm()
        for forged in forgeries {
            XCTAssertThrowsError(try owner.acknowledge(forged, configuration: configuration, captureID: n4CaptureID)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
            XCTAssertThrowsError(try owner.deferClaim(forged, configuration: configuration, retryNotBefore: 0, reason: .unavailable)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
            XCTAssertEqual(try n4Audit(fixture), before)
        }
        XCTAssertEqual(probe.visits, 0)
        probe.disarm()
        XCTAssertEqual(try owner.acknowledge(claim, configuration: configuration, captureID: n4CaptureID), .acknowledged)
    }

    func testN4AllEntriesRequireCurrentByteExactSourcePathAndRevision() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
        let nested = fixture.sourceRoot.appendingPathComponent("é")
        try fixture.directory(nested)
        let old = CollectorRootConfiguration(rootID: "root-é", source: .codex, rootPath: fixture.sourceRoot.path + "/é", revision: 1)
        let current = CollectorRootConfiguration(rootID: old.rootID, source: old.source, rootPath: old.rootPath, revision: 2)
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(old)
        _ = try owner.enrollAndActivateRoot(current)
        let claim = try n4Prepare(.deferClaim, owner, fixture, configuration: current)
        let decomposedPath = fixture.sourceRoot.path + "/e\u{301}"
        XCTAssertEqual(decomposedPath, current.rootPath)
        XCTAssertNotEqual(Data(decomposedPath.utf8), Data(current.rootPath.utf8))
        let mismatches = [
            old,
            CollectorRootConfiguration(rootID: current.rootID, source: .claudeCode, rootPath: current.rootPath, revision: 2),
            CollectorRootConfiguration(rootID: current.rootID, source: .codex, rootPath: decomposedPath, revision: 2),
            CollectorRootConfiguration(rootID: "root-e\u{301}", source: .codex, rootPath: current.rootPath, revision: 2),
        ]
        let before = try n4Audit(fixture)
        for configuration in mismatches {
            XCTAssertThrowsError(try owner.claimDirty(configuration: configuration, limit: 1, now: 0)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
            XCTAssertThrowsError(try owner.acknowledge(claim, configuration: configuration, captureID: n4CaptureID)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
            XCTAssertThrowsError(try owner.deferClaim(claim, configuration: configuration, retryNotBefore: 0, reason: .unavailable)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
            XCTAssertEqual(try n4Audit(fixture), before)
        }
        XCTAssertEqual(try owner.acknowledge(claim, configuration: current, captureID: n4CaptureID), .acknowledged)
    }

    func testN4AllEntriesRejectUnknownUnenrolledAndInactiveRoots() throws {
        for variant in 0..<3 {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
            defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
            if variant == 1 { try n3SeedRegisteredUnboundRoot(fixture) }
            if variant == 2 {
                let first = try XCTUnwrap(fixture.open(ownerRunID: "n4-old"))
                _ = try first.enrollAndActivateRoot(fixture.configuration)
                try first.close()
            }
            let owner = try XCTUnwrap(fixture.open(ownerRunID: "n4-current"))
            defer { try? owner.close() }
            let control = CollectorRootConfiguration(rootID: "positive-control", source: .codex, rootPath: fixture.sourceRoot.path, revision: 1)
            _ = try n4Prepare(.deferClaim, owner, fixture, configuration: control)
            let invented = CollectorDirtyClaim(rootID: fixture.configuration.rootID, rootRevision: 1, relativePath: "a.jsonl",
                dirtyRevision: 1, ownerRunID: "n4-current", claimGeneration: 1)
            let before = try n4Audit(fixture)
            for operation in N4Operation.allCases {
                XCTAssertThrowsError(try n4Perform(operation, owner, fixture.configuration, invented)) { error in
                    switch variant {
                    case 1: XCTAssertEqual(error as? CollectorInventoryOwnerError, .rootNotEnrolled)
                    case 2: XCTAssertEqual(error as? CollectorInventoryOwnerError, .rootNotActivated)
                    default: XCTAssertEqual(error as? CollectorInventoryError, .unknownRoot)
                    }
                }
                XCTAssertEqual(try n4Audit(fixture), before)
            }
        }
    }

    func testN4ForgedAndReplayedClaimsKeepStaleNeutralResultsAndAllStoredValues() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
        let owner = try XCTUnwrap(fixture.open(ownerRunID: "run-é"))
        defer { try? owner.close() }
        let claim = try n4Prepare(.deferClaim, owner, fixture)
        let before = try n4Audit(fixture)
        let forgeries = [
            n4Copy(claim, ownerRunID: "other-owner"),
            n4Copy(claim, ownerRunID: "run-e\u{301}"),
            n4Copy(claim, claimGeneration: claim.claimGeneration + 1),
            n4Copy(claim, dirtyRevision: claim.dirtyRevision + 1),
            n4Copy(claim, relativePath: "missing.jsonl"),
            n4Copy(claim, relativePath: claim.relativePath + "\0suffix"),
        ]
        XCTAssertEqual("run-é", "run-e\u{301}")
        XCTAssertNotEqual(Data("run-é".utf8), Data("run-e\u{301}".utf8))
        for forged in forgeries {
            XCTAssertEqual(try owner.acknowledge(forged, configuration: fixture.configuration, captureID: n4CaptureID), .stale)
            XCTAssertFalse(try owner.deferClaim(forged, configuration: fixture.configuration, retryNotBefore: 99, reason: .unavailable))
            XCTAssertEqual(try n4Audit(fixture), before)
        }
        XCTAssertEqual(try owner.acknowledge(claim, configuration: fixture.configuration, captureID: n4CaptureID), .acknowledged)
        let acknowledged = try n4Audit(fixture)
        XCTAssertEqual(try owner.acknowledge(claim, configuration: fixture.configuration, captureID: String(repeating: "b", count: 64)), .stale)
        XCTAssertFalse(try owner.deferClaim(claim, configuration: fixture.configuration, retryNotBefore: 99, reason: .sourceMissing))
        XCTAssertEqual(try n4Audit(fixture), acknowledged)
    }

    func testN4NewDirtyEventSurvivesOlderSuccessfulAcknowledgement() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        try n4Mark(owner, fixture.configuration, ["a.jsonl"])
        let old = try n4Claim(owner, fixture.configuration)
        try n4Mark(owner, fixture.configuration, ["a.jsonl"])
        XCTAssertEqual(try owner.acknowledge(old, configuration: fixture.configuration, captureID: n4CaptureID), .newerWorkPending)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT dirty_revision FROM collector_locators"), old.dirtyRevision + 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT acknowledged_revision FROM collector_locators"), old.dirtyRevision)
        XCTAssertEqual(try fixture.inventoryText("SELECT last_capture_id FROM collector_locators"), n4CaptureID)
        let next = try n4Claim(owner, fixture.configuration)
        XCTAssertEqual(next.dirtyRevision, old.dirtyRevision + 1)
        XCTAssertEqual(next.claimGeneration, old.claimGeneration + 1)
        let beforeStale = try n4Audit(fixture)
        XCTAssertEqual(try owner.acknowledge(old, configuration: fixture.configuration, captureID: String(repeating: "c", count: 64)), .stale)
        XCTAssertFalse(try owner.deferClaim(old, configuration: fixture.configuration, retryNotBefore: 99, reason: .unavailable))
        XCTAssertEqual(try n4Audit(fixture), beforeStale)
    }

    func testN4ReopenTakesOverInflightWorkAndRejectsOldOwnerResults() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
        let first = try XCTUnwrap(fixture.open(ownerRunID: "n4-first"))
        defer { try? first.close() }
        let binding = try first.enrollAndActivateRoot(fixture.configuration)
        try n4Mark(first, fixture.configuration, ["a.jsonl"])
        let old = try n4Claim(first, fixture.configuration)
        try first.close()
        let second = try XCTUnwrap(fixture.open(ownerRunID: "n4-second"))
        defer { try? second.close() }
        XCTAssertEqual(try second.enrollAndActivateRoot(fixture.configuration).expectedIdentity, binding.expectedIdentity)
        let next = try n4Claim(second, fixture.configuration)
        XCTAssertEqual(next.ownerRunID, "n4-second")
        XCTAssertEqual(next.claimGeneration, old.claimGeneration + 1)
        XCTAssertEqual(next.dirtyRevision, old.dirtyRevision)
        let before = try n4Audit(fixture)
        XCTAssertEqual(try second.acknowledge(old, configuration: fixture.configuration, captureID: n4CaptureID), .stale)
        XCTAssertFalse(try second.deferClaim(old, configuration: fixture.configuration, retryNotBefore: 99, reason: .rootReplaced))
        XCTAssertEqual(try n4Audit(fixture), before)
        XCTAssertThrowsError(try first.acknowledge(old, configuration: fixture.configuration, captureID: n4CaptureID)) {
            XCTAssertEqual($0 as? CollectorInventoryOwnerError, .closed)
        }
        XCTAssertEqual(try second.acknowledge(next, configuration: fixture.configuration, captureID: n4CaptureID), .acknowledged)
    }

    func testN4AllEntriesAfterCloseRejectWithoutReopeningAnyFile() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let owner = try XCTUnwrap(fixture.open())
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        try n4Mark(owner, fixture.configuration, ["a.jsonl"])
        let claim = try n4Claim(owner, fixture.configuration)
        try owner.close()
        let before = try fixture.snapshot()
        for operation in N4Operation.allCases {
            XCTAssertThrowsError(try n4Perform(operation, owner, fixture.configuration, claim)) {
                XCTAssertEqual($0 as? CollectorInventoryOwnerError, .closed)
            }
            XCTAssertEqual(try fixture.snapshot(), before)
        }
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
    }

    func testN4ClaimAndAcknowledgementRequireFreshPhysicalRootBeforeStoreAccess() throws {
        for operation: N4Operation in [.claim, .acknowledge] {
            for replacement: N4Replacement in [.missing, .directory] {
                let fixture = try CollectorOwnerFixture()
                defer { fixture.remove() }
                let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
                defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
                let probe = N4CommitProbe()
                let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
                defer { try? owner.close() }
                let claim = try n4Prepare(operation, owner, fixture)
                let before = try n4Audit(fixture)
                let mutation = try N4PathMutation(fixture, target: fixture.sourceRoot)
                defer { try? mutation.restore() }
                try mutation.install(replacement)
                probe.arm()
                XCTAssertThrowsError(try n4Perform(operation, owner, fixture.configuration, claim)) {
                    XCTAssertEqual($0 as? CollectorPOSIXEnumerationError,
                                   replacement == .missing ? .io(.openComponent, ENOENT) : .rootIdentityChanged)
                }
                XCTAssertEqual(probe.visits, 0, "physical validation must precede the Store write")
                XCTAssertEqual(try n4Audit(fixture), before)
                probe.disarm()
                try mutation.restore()
                try n4Perform(operation, owner, fixture.configuration, claim)
            }
        }
    }

    func testN4DeferralMayPersistForMissingOrReplacedRootWithoutRebinding() throws {
        for replacement: N4Replacement in [.missing, .directory] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
            defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
            let owner = try XCTUnwrap(fixture.open())
            defer { try? owner.close() }
            let claim = try n4Prepare(.deferClaim, owner, fixture)
            let before = try n4Audit(fixture)
            let mutation = try N4PathMutation(fixture, target: fixture.sourceRoot)
            defer { try? mutation.restore() }
            try mutation.install(replacement)
            let reason: CollectorDirtyDeferReason = replacement == .missing ? .sourceMissing : .rootReplaced
            XCTAssertTrue(try owner.deferClaim(claim, configuration: fixture.configuration, retryNotBefore: 100, reason: reason))
            let after = try n4Audit(fixture)
            XCTAssertEqual(after.tables["roots"], before.tables["roots"])
            XCTAssertEqual(after.tables["bindings"], before.tables["bindings"])
            XCTAssertEqual(after.tables["metadata"], before.tables["metadata"])
            XCTAssertEqual(try fixture.inventoryText("SELECT last_error FROM collector_locators"), reason.rawValue)
            XCTAssertEqual(try fixture.inventoryInteger("SELECT retry_not_before FROM collector_locators"), 100)
            XCTAssertEqual(try fixture.inventoryInteger("SELECT acknowledged_revision FROM collector_locators"), 1)
            XCTAssertEqual(try fixture.inventoryText("SELECT last_capture_id FROM collector_locators"), n4CaptureID)
            XCTAssertNil(try fixture.inventoryText("SELECT claim_owner_run_id FROM collector_locators"))
            XCTAssertNil(try fixture.inventoryInteger("SELECT claimed_dirty_revision FROM collector_locators"))
            try mutation.restore()
            XCTAssertTrue(try owner.claimDirty(configuration: fixture.configuration, limit: 1, now: 99).isEmpty)
            let due = try n4Claim(owner, fixture.configuration, now: 100)
            XCTAssertEqual(due.dirtyRevision, claim.dirtyRevision)
            XCTAssertEqual(due.claimGeneration, claim.claimGeneration + 1)
        }
    }

    func testN4DeferralDoesNotTolerateSymlinkOrNonDirectoryRoot() throws {
        for replacement: N4Replacement in [.symlink, .file] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
            defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
            let probe = N4CommitProbe()
            let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
            defer { try? owner.close() }
            let claim = try n4Prepare(.deferClaim, owner, fixture)
            let before = try n4Audit(fixture)
            let mutation = try N4PathMutation(fixture, target: fixture.sourceRoot)
            defer { try? mutation.restore() }
            try mutation.install(replacement)
            probe.arm()
            XCTAssertThrowsError(try owner.deferClaim(claim, configuration: fixture.configuration, retryNotBefore: 100, reason: .sourceMissing)) {
                self.n4AssertUnsafeRootError($0)
            }
            XCTAssertEqual(probe.visits, 0)
            XCTAssertEqual(try n4Audit(fixture), before)
        }
    }

    func testN4DeferralRevalidatesAfterAnInitiallyToleratedRootFailure() throws {
        for initial: N4Replacement in [.missing, .directory] {
            for atCommit: N4Replacement in [.symlink, .file] {
                let fixture = try CollectorOwnerFixture()
                defer { fixture.remove() }
                let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
                defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
                let probe = N4CommitProbe()
                let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
                defer { try? owner.close() }
                let claim = try n4Prepare(.deferClaim, owner, fixture)
                let before = try n4Audit(fixture)
                let mutation = try N4PathMutation(fixture, target: fixture.sourceRoot)
                defer { try? mutation.restore() }
                try mutation.install(initial)
                probe.arm { try mutation.replaceCurrent(atCommit) }
                XCTAssertThrowsError(try owner.deferClaim(claim, configuration: fixture.configuration, retryNotBefore: 100, reason: .unavailable)) {
                    self.n4AssertUnsafeRootError($0)
                }
                XCTAssertEqual(probe.visits, 1)
                XCTAssertEqual(probe.returnedNormally, 1, "the test hook must return; production must reject the new unsafe route")
                XCTAssertEqual(try n4Audit(fixture), before)
                probe.disarm()
                try mutation.restore()
                XCTAssertTrue(try owner.deferClaim(claim, configuration: fixture.configuration, retryNotBefore: 0, reason: .unavailable))
            }
        }
    }

    func testN4PrecancelledCallerDoesNotEnterStoreForAnyDirtyOperation() async throws {
        for operation in N4Operation.allCases {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
            defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
            let probe = N4CommitProbe()
            let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
            defer { try? owner.close() }
            let claim = try n4Prepare(operation, owner, fixture)
            let before = try n4Audit(fixture)
            probe.arm()
            let task = Task {
                try withUnsafeCurrentTask { current in
                    XCTAssertNotNil(current)
                    current?.cancel()
                    XCTAssertTrue(current?.isCancelled == true)
                    XCTAssertThrowsError(try self.n4Perform(operation, owner, fixture.configuration, claim)) {
                        XCTAssertTrue($0 is CancellationError)
                    }
                }
            }
            try await task.value
            XCTAssertEqual(probe.visits, 0)
            XCTAssertEqual(try n4Audit(fixture), before)
            probe.disarm()
            try n4Perform(operation, owner, fixture.configuration, claim)
        }
    }

    func testN4CallerCancellationAfterMutationRollsBackAllDirtyOperations() async throws {
        for operation in N4Operation.allCases {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
            defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
            let probe = N4CommitProbe()
            let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
            defer { try? owner.close() }
            let claim = try n4Prepare(operation, owner, fixture)
            let before = try n4Audit(fixture)
            var cancelCaller: (() -> Void)?
            probe.arm { cancelCaller?() }
            let task = Task {
                try withUnsafeCurrentTask { current in
                    XCTAssertNotNil(current)
                    XCTAssertFalse(current?.isCancelled == true)
                    cancelCaller = { current?.cancel() }
                    defer { cancelCaller = nil }
                    XCTAssertThrowsError(try self.n4Perform(operation, owner, fixture.configuration, claim)) {
                        XCTAssertTrue($0 is CancellationError)
                    }
                    XCTAssertTrue(current?.isCancelled == true)
                }
            }
            try await task.value
            XCTAssertNil(cancelCaller, "the borrowed task handle must not escape the synchronous operation")
            XCTAssertEqual(probe.visits, 1)
            XCTAssertEqual(probe.returnedNormally, 1, "throwing CancellationError from the hook would not test the borrowed task fence")
            XCTAssertEqual(try n4Audit(fixture), before, "cursor, lease, acknowledgement, retry and errors must all roll back")
            probe.disarm()
            try n4Perform(operation, owner, fixture.configuration, claim)
        }
    }

    func testN4ClaimRootReplacementAfterMutationRollsBackCursorAndClaim() throws {
        try n4AssertRootCommitRollback(.claim)
    }

    func testN4AcknowledgementRootReplacementAfterMutationRollsBackCaptureAndLease() throws {
        try n4AssertRootCommitRollback(.acknowledge)
    }

    func testN4ClaimStorageReplacementAfterMutationRollsBackCursorAndClaim() throws {
        try n4AssertStorageCommitRollback(.claim)
    }

    func testN4AcknowledgementStorageReplacementAfterMutationRollsBackCaptureAndLease() throws {
        try n4AssertStorageCommitRollback(.acknowledge)
    }

    func testN4DeferralStorageReplacementAfterMutationRollsBackRetryErrorAndLease() throws {
        try n4AssertStorageCommitRollback(.deferClaim)
    }

    func testDeferClaimsBatchOneCommitStaleNewerDirtyAndFenceRollback_repro() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        var commits = 0
        let owner = try XCTUnwrap(fixture.open(hooks: .init(beforeInventoryCommit: { commits += 1 })))
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        try n4Mark(owner, fixture.configuration, ["a.jsonl", "b.jsonl"])
        let claimed = try owner.claimDirty(configuration: fixture.configuration, limit: 8, now: 0)
        XCTAssertEqual(Set(claimed.map(\.relativePath)), ["a.jsonl", "b.jsonl"])
        let afterClaim = commits
        let stale = n4Copy(claimed[0], claimGeneration: claimed[0].claimGeneration + 1)
        let results = try owner.deferClaims(
            [(claim: claimed[0], retryNotBefore: 60), (claim: stale, retryNotBefore: 1),
             (claim: claimed[1], retryNotBefore: 1)],
            configuration: fixture.configuration, reason: .unavailable)
        XCTAssertEqual(results, [true, false, true])
        XCTAssertEqual(commits - afterClaim, 1)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'a.jsonl'"), 60)
        XCTAssertEqual(try fixture.inventoryInteger("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'b.jsonl'"), 1)
        XCTAssertEqual(try fixture.inventoryText("SELECT last_error FROM collector_locators WHERE relative_path = 'a.jsonl'"), "unavailable")
        let due = try owner.claimDirty(configuration: fixture.configuration, limit: 8, now: 60)
        let again = try XCTUnwrap(due.first { $0.relativePath.utf8.elementsEqual("a.jsonl".utf8) })
        try n4Mark(owner, fixture.configuration, ["a.jsonl"])
        let afterNewer = commits
        XCTAssertEqual(try owner.deferClaims(
            [(claim: again, retryNotBefore: 1_000)],
            configuration: fixture.configuration, reason: .unavailable), [true])
        XCTAssertEqual(commits - afterNewer, 1)
        XCTAssertNil(try fixture.inventoryInteger("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'a.jsonl'"))
        XCTAssertNil(try fixture.inventoryText("SELECT last_error FROM collector_locators WHERE relative_path = 'a.jsonl'"))

        let probe = N4CommitProbe()
        try owner.close()
        let fenced = try XCTUnwrap(fixture.open(hooks: probe.hooks))
        defer { try? fenced.close() }
        _ = try fenced.enrollAndActivateRoot(fixture.configuration)
        try n4Mark(fenced, fixture.configuration, ["c.jsonl"])
        let live = try XCTUnwrap(
            try fenced.claimDirty(configuration: fixture.configuration, limit: 8, now: 0)
                .first { $0.relativePath.utf8.elementsEqual("c.jsonl".utf8) })
        let before = try n4Audit(fixture)
        let rootMutation = try N4PathMutation(fixture, target: fixture.sourceRoot)
        defer { try? rootMutation.restore() }
        probe.arm { try rootMutation.install(.symlink) }
        XCTAssertThrowsError(try fenced.deferClaims(
            [(claim: live, retryNotBefore: 99)],
            configuration: fixture.configuration, reason: .unavailable)) {
            self.n4AssertUnsafeRootError($0)
        }
        XCTAssertEqual(probe.visits, 1)
        probe.disarm()
        try rootMutation.restore()
        XCTAssertEqual(try n4Audit(fixture), before)
        let mutation = try N4PathMutation(fixture, target: fixture.inventoryURL)
        defer { try? mutation.restore() }
        probe.arm { try mutation.install(.file) }
        XCTAssertThrowsError(try fenced.deferClaims(
            [(claim: live, retryNotBefore: 99)],
            configuration: fixture.configuration, reason: .unavailable)) {
            XCTAssertEqual($0 as? CollectorInventoryOwnerError, .unsafePath)
        }
        XCTAssertEqual(probe.visits, 1)
        probe.disarm()
        try mutation.restore()
        XCTAssertEqual(try n4Audit(fixture), before)
    }

    func testN4AcknowledgementIsOnlyACallerAssertionAndCreatesNoCaptureOrPublication() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
        let archiveBefore = try fixture.snapshot(at: fixture.shadowCatalog)
        let sourceBefore = try fixture.snapshot(at: fixture.sourceParent)
        let owner = try XCTUnwrap(fixture.open())
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        // There is no source file or CAS artifact for this event-only locator.
        try n4Mark(owner, fixture.configuration, ["not-captured.jsonl"])
        let claim = try n4Claim(owner, fixture.configuration, path: "not-captured.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceRoot.appendingPathComponent(claim.relativePath).path))
        let shadowNames = try FileManager.default.contentsOfDirectory(atPath: fixture.shadowRoot.path).sorted()
        XCTAssertEqual(shadowNames, ["archive.sqlite", "collector-owner.lock", "inventory"])
        let assertedCaptureID = String(repeating: "d", count: 64)
        XCTAssertEqual(try owner.acknowledge(claim, configuration: fixture.configuration, captureID: assertedCaptureID), .acknowledged)
        XCTAssertEqual(try fixture.inventoryText("SELECT last_capture_id FROM collector_locators"), assertedCaptureID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.shadowRoot.path).sorted(), shadowNames)
        // Schema creation is independent of an event-only acknowledgement.
        // No reservation, publication, or upload row may be created by it.
        for table in ["collector_capture_reservations", "collector_publications", "collector_publication_replicas"] {
            XCTAssertEqual(try fixture.inventoryInteger("SELECT COUNT(*) FROM \(table)"), 0)
        }
        try owner.close()
        XCTAssertEqual(try fixture.snapshot(at: fixture.liveRoot), liveBefore)
        XCTAssertEqual(try fixture.snapshot(at: fixture.shadowCatalog), archiveBefore)
        XCTAssertEqual(try fixture.snapshot(at: fixture.sourceParent), sourceBefore)
    }

    private var n4CaptureID: String { String(repeating: "a", count: 64) }
    private enum N4Operation: CaseIterable, Equatable { case claim, acknowledge, deferClaim }
    private enum N4Replacement: Equatable { case missing, directory, file, symlink }
    private enum N4StorageTarget: CaseIterable { case main, lock, wal, inventoryDirectory, shadowDirectory, liveDirectory }

    private func n4Mark(_ owner: CollectorInventoryOwner, _ configuration: CollectorRootConfiguration, _ paths: [String]) throws {
        let expected = try owner.rootState(rootID: configuration.rootID)?.eventCheckpoint
        let next = CollectorEventCheckpoint(epoch: expected?.epoch ?? "n4-events", cursor: UUID().uuidString)
        let result = try owner.applyEvents(configuration: configuration, expectedCheckpoint: expected,
            nextCheckpoint: next, dirtyRelativePaths: paths, budget: n3Budget(maxIncomingPaths: max(1, paths.count)))
        XCTAssertEqual(result, .applied(inputPathCount: paths.count, checkpoint: next))
    }

    private func n4Claim(_ owner: CollectorInventoryOwner, _ configuration: CollectorRootConfiguration,
                         path: String = "a.jsonl", now: Int64 = 0) throws -> CollectorDirtyClaim {
        let claims = try owner.claimDirty(configuration: configuration, limit: 1, now: now)
        XCTAssertEqual(claims.count, 1)
        let claim = try XCTUnwrap(claims.first)
        XCTAssertEqual(Data(claim.rootID.utf8), Data(configuration.rootID.utf8))
        XCTAssertEqual(claim.rootRevision, configuration.revision)
        XCTAssertEqual(Data(claim.relativePath.utf8), Data(path.utf8))
        return claim
    }

    private func n4Copy(_ claim: CollectorDirtyClaim, rootID: String? = nil, rootRevision: Int64? = nil,
                        relativePath: String? = nil, dirtyRevision: Int64? = nil, ownerRunID: String? = nil,
                        claimGeneration: Int64? = nil) -> CollectorDirtyClaim {
        .init(rootID: rootID ?? claim.rootID, rootRevision: rootRevision ?? claim.rootRevision,
              relativePath: relativePath ?? claim.relativePath, dirtyRevision: dirtyRevision ?? claim.dirtyRevision,
              ownerRunID: ownerRunID ?? claim.ownerRunID, claimGeneration: claimGeneration ?? claim.claimGeneration)
    }

    private func n4Prepare(_ operation: N4Operation, _ owner: CollectorInventoryOwner,
                           _ fixture: CollectorOwnerFixture, configuration supplied: CollectorRootConfiguration? = nil) throws -> CollectorDirtyClaim {
        let configuration = supplied ?? fixture.configuration
        _ = try owner.enrollAndActivateRoot(configuration)
        try n4Mark(owner, configuration, ["a.jsonl"])
        let first = try n4Claim(owner, configuration)
        let acknowledged = try owner.acknowledge(first, configuration: configuration, captureID: n4CaptureID)
        XCTAssertEqual(acknowledged, .acknowledged)
        try n4Mark(owner, configuration, ["a.jsonl"])
        var claim = try n4Claim(owner, configuration)
        if operation != .acknowledge {
            let deferred = try owner.deferClaim(claim, configuration: configuration, retryNotBefore: 0, reason: .unavailable)
            XCTAssertTrue(deferred)
            if operation == .deferClaim { claim = try n4Claim(owner, configuration) }
            else {
                // The tested claim must change the cursor from a -> b. A
                // single-locator fixture could not prove cursor rollback.
                try n4Mark(owner, configuration, ["b.jsonl"])
                XCTAssertEqual(try fixture.inventoryText("SELECT claim_cursor FROM collector_roots"), "a.jsonl")
            }
        }
        return claim
    }

    private func n4Perform(_ operation: N4Operation, _ owner: CollectorInventoryOwner,
                           _ configuration: CollectorRootConfiguration, _ claim: CollectorDirtyClaim) throws {
        switch operation {
        case .claim:
            let claims = try owner.claimDirty(configuration: configuration, limit: 1, now: 0)
            XCTAssertEqual(claims.count, 1)
        case .acknowledge:
            let result = try owner.acknowledge(claim, configuration: configuration, captureID: String(repeating: "b", count: 64))
            XCTAssertEqual(result, .acknowledged)
        case .deferClaim:
            let result = try owner.deferClaim(claim, configuration: configuration, retryNotBefore: 99, reason: .sourceMissing)
            XCTAssertTrue(result)
        }
    }

    private func n4AssertUnsafeRootError(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? CollectorPOSIXEnumerationError, case .io(let operation, let code) = error else {
            XCTFail("Expected a non-tolerated POSIX root-open error, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(operation, .openComponent, file: file, line: line)
        XCTAssertTrue(code == ELOOP || code == ENOTDIR, "symlink/non-directory refusal, not ENOENT", file: file, line: line)
    }

    private func n4AssertRootCommitRollback(_ operation: N4Operation) throws {
        for replacement: N4Replacement in [.missing, .directory] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
            defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
            let probe = N4CommitProbe()
            let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
            defer { try? owner.close() }
            let claim = try n4Prepare(operation, owner, fixture)
            let before = try n4Audit(fixture)
            let mutation = try N4PathMutation(fixture, target: fixture.sourceRoot)
            defer { try? mutation.restore() }
            probe.arm { try mutation.install(replacement) }
            XCTAssertThrowsError(try n4Perform(operation, owner, fixture.configuration, claim)) {
                XCTAssertEqual($0 as? CollectorPOSIXEnumerationError,
                               replacement == .missing ? .io(.openComponent, ENOENT) : .rootIdentityChanged)
            }
            XCTAssertEqual(probe.visits, 1)
            XCTAssertEqual(probe.returnedNormally, 1)
            XCTAssertEqual(try n4Audit(fixture), before)
            probe.disarm()
            // An operation-local physical fence must not leak into the old
            // gap-only API, which intentionally accepts a missing/replaced root.
            let state = try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
            XCTAssertEqual(try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .continuityLoss),
                           .reconciliationRequested(reason: .continuityLoss, requestedRevision: state.requestedRevision + 1))
            try mutation.restore()
            try n4Perform(operation, owner, fixture.configuration, claim)
        }
    }

    private func n4AssertStorageCommitRollback(_ operation: N4Operation) throws {
        for target in N4StorageTarget.allCases {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let liveBefore = try fixture.snapshot(at: fixture.liveRoot)
            defer { XCTAssertEqual(try? fixture.snapshot(at: fixture.liveRoot), liveBefore) }
            let probe = N4CommitProbe()
            let owner = try XCTUnwrap(fixture.open(hooks: probe.hooks))
            defer { try? owner.close() }
            let claim = try n4Prepare(operation, owner, fixture)
            let before = try n4Audit(fixture)
            let path: URL
            let replacement: N4Replacement
            switch target {
            case .main: path = fixture.inventoryURL; replacement = .file
            case .lock: path = fixture.lockURL; replacement = .file
            case .wal: path = URL(fileURLWithPath: fixture.inventoryURL.path + "-wal"); replacement = .file
            case .inventoryDirectory: path = fixture.inventoryDirectory; replacement = .directory
            case .shadowDirectory: path = fixture.shadowRoot; replacement = .directory
            case .liveDirectory: path = fixture.liveRoot; replacement = .directory
            }
            let originalIdentity = try fixture.fileIdentity(path)
            let mutation = try N4PathMutation(fixture, target: path)
            defer { try? mutation.restore() }
            var replacementSnapshot: [String: CollectorOwnerFixture.Snapshot]?
            probe.arm {
                try mutation.install(replacement)
                XCTAssertNotEqual(try fixture.fileIdentity(path), originalIdentity)
                replacementSnapshot = try fixture.snapshot(at: path)
            }
            XCTAssertThrowsError(try n4Perform(operation, owner, fixture.configuration, claim)) {
                XCTAssertEqual($0 as? CollectorInventoryOwnerError, .unsafePath, "\(operation) / \(target)")
            }
            XCTAssertEqual(probe.visits, 1, "\(operation) / \(target)")
            XCTAssertEqual(probe.returnedNormally, 1, "the replacement hook must not itself throw")
            XCTAssertEqual(try fixture.snapshot(at: path), try XCTUnwrap(replacementSnapshot), "the replacement target must not receive inventory writes")
            probe.disarm()
            // Restore the ORIGINAL inode and sidecars before independent SQL
            // observation. Reading a fresh replacement DB could fake rollback.
            try mutation.restore()
            XCTAssertEqual(try fixture.fileIdentity(path), originalIdentity)
            XCTAssertEqual(try n4Audit(fixture), before, "post-commit validation would already have persisted \(operation) / \(target)")
            // External SQLite inode replacement need not leave the original
            // connection reusable; rollback and explicit cleanup are required.
            try owner.close()
            XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
        }
    }

    private enum N4SQLCell: Equatable {
        case null
        case integer(Int64)
        case bytes(Data)
    }

    private struct N4InventoryAudit: Equatable {
        let tables: [String: [[N4SQLCell]]]
    }

    private func n4Audit(_ fixture: CollectorOwnerFixture) throws -> N4InventoryAudit {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .immediateError
        let queue = try DatabaseQueue(path: fixture.inventoryURL.path, configuration: configuration)
        defer { try? queue.close() }
        // Byte projections keep the verifier independent of Swift canonical
        // String equality. No test writer, Store, or Owner read helper is used.
        let queries = [
            "metadata": """
                SELECT CAST(key AS BLOB) AS key, CAST(value AS BLOB) AS value
                FROM collector_metadata ORDER BY key COLLATE BINARY
                """,
            "roots": """
                SELECT CAST(root_id AS BLOB) AS root_id, CAST(source AS BLOB) AS source,
                    CAST(root_path AS BLOB) AS root_path, root_revision, requested_revision, completed_revision,
                    CAST(event_epoch AS BLOB) AS event_epoch, CAST(event_cursor AS BLOB) AS event_cursor,
                    CAST(active_scan_id AS BLOB) AS active_scan_id, active_scan_requested_revision,
                    CAST(last_scan_failure AS BLOB) AS last_scan_failure, CAST(claim_cursor AS BLOB) AS claim_cursor
                FROM collector_roots ORDER BY root_id COLLATE BINARY
                """,
            "bindings": """
                SELECT CAST(root_id AS BLOB) AS root_id, root_revision, device, inode, generation, birth_seconds,
                    birth_nanoseconds, CAST(last_activated_owner_run_id AS BLOB) AS last_activated_owner_run_id
                FROM collector_root_bindings ORDER BY root_id COLLATE BINARY, root_revision
                """,
            "locators": """
                SELECT CAST(root_id AS BLOB) AS root_id, root_revision, CAST(relative_path AS BLOB) AS relative_path,
                    CAST(observed_generation AS BLOB) AS observed_generation, CAST(last_seen_scan_id AS BLOB) AS last_seen_scan_id,
                    dirty_revision, acknowledged_revision, CAST(last_capture_id AS BLOB) AS last_capture_id,
                    CAST(claim_owner_run_id AS BLOB) AS claim_owner_run_id, claim_generation, claimed_dirty_revision,
                    retry_not_before, CAST(last_error AS BLOB) AS last_error
                FROM collector_locators ORDER BY root_id COLLATE BINARY, root_revision, relative_path COLLATE BINARY
                """,
            "frontier": """
                SELECT CAST(root_id AS BLOB) AS root_id, root_revision, CAST(scan_id AS BLOB) AS scan_id,
                    CAST(relative_directory AS BLOB) AS relative_directory, completed
                FROM collector_frontier ORDER BY root_id COLLATE BINARY, root_revision, scan_id COLLATE BINARY, relative_directory COLLATE BINARY
                """,
        ]
        return try queue.read { db in
            var tables: [String: [[N4SQLCell]]] = [:]
            for (name, sql) in queries {
                tables[name] = try Row.fetchAll(db, sql: sql).map { row -> [N4SQLCell] in
                    try row.columnNames.map { column -> N4SQLCell in
                        switch (row[column] as DatabaseValue).storage {
                        case .null: return .null
                        case .int64(let value): return .integer(value)
                        case .blob(let value): return .bytes(value)
                        default: throw CollectorOwnerFixture.Failure.injected
                        }
                    }
                }
            }
            return N4InventoryAudit(tables: tables)
        }
    }

    private final class N4CommitProbe {
        private var armed = false
        private var action: (() throws -> Void)?
        private(set) var visits = 0
        private(set) var returnedNormally = 0
        var hooks: CollectorInventoryOwnerTestHooks {
            .init(beforeInventoryCommit: { [weak self] in
                guard let self, self.armed else { return }
                self.visits += 1
                try self.action?()
                self.returnedNormally += 1
            })
        }
        func arm(_ action: (() throws -> Void)? = nil) {
            self.action = action
            visits = 0
            returnedNormally = 0
            armed = true
        }
        func disarm() {
            armed = false
            action = nil
        }
    }

    private final class N4PathMutation {
        private let fixture: CollectorOwnerFixture
        private let target: URL
        private let original: URL
        private var installed = false
        init(_ fixture: CollectorOwnerFixture, target: URL) throws {
            guard target.path.hasPrefix(fixture.base.path + "/") else { throw CollectorOwnerFixture.Failure.injected }
            self.fixture = fixture
            self.target = target
            original = fixture.base.appendingPathComponent("n4-preserved-\(UUID().uuidString)")
        }
        func install(_ replacement: N4Replacement) throws {
            guard !installed else { throw CollectorOwnerFixture.Failure.injected }
            _ = try fixture.fileIdentity(target) // A missing baseline is not a successful fault injection.
            try FileManager.default.moveItem(at: target, to: original)
            installed = true
            try create(replacement)
        }
        func replaceCurrent(_ replacement: N4Replacement) throws {
            guard installed else { throw CollectorOwnerFixture.Failure.injected }
            try removeReplacement()
            try create(replacement)
        }
        func restore() throws {
            guard installed else { return }
            try removeReplacement()
            try FileManager.default.moveItem(at: original, to: target)
            installed = false
        }
        private func create(_ replacement: N4Replacement) throws {
            switch replacement {
            case .missing: break
            case .directory:
                try fixture.directory(target)
                try fixture.file(target.appendingPathComponent("replacement-sentinel"), bytes: Data("do-not-write".utf8))
            case .file:
                try fixture.file(target, bytes: Data("replacement-do-not-write".utf8))
            case .symlink:
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
            }
        }
        private func removeReplacement() throws {
            var info = stat()
            if lstat(target.path, &info) == 0 { try FileManager.default.removeItem(at: target) }
            else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
    // End N4a TEST-DRAFT.

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

extension CollectorInventoryOwnerTests {
    func testStorageValidationUsesOneActualOpenPerRouteAndKeepsBothRootStateFences() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        // Measure an accepted canonical owner; existing alias-refusal tests stay separate.
        XCTAssertEqual(try fixture.mode(fixture.shadowRoot) & S_IFMT, S_IFDIR)
        let probe = StorageValidationDescriptorProbe()
        let owner = try XCTUnwrap(fixture.open(hooks: .init(storageValidationOpenHooks: probe.hooks)))
        defer { try? owner.close() }
        let expected = try [fixture.fileIdentity(fixture.shadowRoot), fixture.fileIdentity(fixture.liveRoot)]
        probe.arm()
        for _ in 0..<2 { XCTAssertNil(try owner.rootState(rootID: "not-enrolled")) }
        XCTAssertEqual(probe.opened, 8, "two real opens per validation, before AND after each rootState read")
        XCTAssertEqual(probe.closed, 8)
        XCTAssertEqual(probe.identities, Array(repeating: expected, count: 4).flatMap { $0 })
        XCTAssertLessThanOrEqual(probe.maximumLive, 2)
        XCTAssertTrue(probe.live.isEmpty)
        XCTAssertTrue(probe.allDirectories && probe.allReadOnly && probe.allCloseOnExec)
        probe.disarm()
        try owner.close()
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
    }

    func testStorageValidationRejectsSameInodeLeafAndAncestorSymlinksAtEntryAndCommit() throws {
        for atCommit in [false, true] {
            for route in ["shadow-leaf", "shadow-parent", "live-leaf", "live-parent"] {
                let fixture = try CollectorOwnerFixture()
                defer { fixture.remove() }
                let live = try storageValidationLiveRoot(fixture)
                let commit = N4CommitProbe()
                let owner = try XCTUnwrap(fixture.open(identityCatalog: live.appendingPathComponent("archive.sqlite"), hooks: commit.hooks))
                defer { try? owner.close() }
                let claim = try n4Prepare(.claim, owner, fixture)
                let before = try n4Audit(fixture)
                let liveBefore = try fixture.snapshot(at: live)
                let target: URL
                switch route {
                case "shadow-leaf": target = fixture.shadowRoot
                case "shadow-parent": target = fixture.shadowRoot.deletingLastPathComponent()
                case "live-leaf": target = live
                default: target = live.deletingLastPathComponent()
                }
                let expected = try fixture.fileIdentity(target)
                let mutation = try N4PathMutation(fixture, target: target)
                defer { try? mutation.restore() }
                let install = {
                    try mutation.install(.symlink)
                    XCTAssertEqual(try fixture.mode(target) & S_IFMT, S_IFLNK)
                    var info = stat()
                    XCTAssertEqual(fstatat(AT_FDCWD, target.path, &info, 0), 0)
                    XCTAssertEqual(CollectorOwnerFixture.Identity(device: info.st_dev, inode: info.st_ino), expected,
                        "the alias must still resolve to the original inode")
                }
                if atCommit { commit.arm(install) } else { try install() }
                XCTAssertThrowsError(try {
                    if atCommit { try self.n4Perform(.claim, owner, fixture.configuration, claim) }
                    else { _ = try owner.rootState(rootID: fixture.configuration.rootID) }
                }()) { self.storageAssertNoFollowError($0) }
                if atCommit {
                    XCTAssertEqual(commit.visits, 1)
                    XCTAssertEqual(commit.returnedNormally, 1, "the real storage fence, not the mutation hook, must reject")
                }
                commit.disarm()
                try mutation.restore()
                XCTAssertEqual(try fixture.fileIdentity(target), expected)
                XCTAssertEqual(try n4Audit(fixture), before, "\(route), commit=\(atCommit)")
                XCTAssertEqual(try fixture.snapshot(at: live), liveBefore)
                try owner.close()
                XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
            }
        }
    }

    func testStorageValidationRejectsSameInodeInventorySymlinkAtEntryAndCommit() throws {
        for atCommit in [false, true] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let commit = N4CommitProbe()
            let owner = try XCTUnwrap(fixture.open(hooks: commit.hooks))
            defer { try? owner.close() }
            let claim = try n4Prepare(.claim, owner, fixture)
            let before = try n4Audit(fixture)
            let target = fixture.inventoryDirectory
            let expected = try fixture.fileIdentity(target)
            let mutation = try N4PathMutation(fixture, target: target)
            defer { try? mutation.restore() }
            let install = {
                try mutation.install(.symlink)
                XCTAssertEqual(try fixture.mode(target) & S_IFMT, S_IFLNK)
                var info = stat()
                XCTAssertEqual(fstatat(AT_FDCWD, target.path, &info, 0), 0)
                XCTAssertEqual(CollectorOwnerFixture.Identity(device: info.st_dev, inode: info.st_ino), expected,
                    "the alias must still resolve to the original inode")
            }
            if atCommit { commit.arm(install) } else { try install() }
            XCTAssertThrowsError(try {
                if atCommit { try self.n4Perform(.claim, owner, fixture.configuration, claim) }
                else { _ = try owner.rootState(rootID: fixture.configuration.rootID) }
            }()) { self.storageAssertNoFollowError($0) }
            if atCommit {
                XCTAssertEqual(commit.visits, 1)
                XCTAssertEqual(commit.returnedNormally, 1, "the real storage fence, not the mutation hook, must reject")
            }
            commit.disarm()
            try mutation.restore()
            XCTAssertEqual(try fixture.fileIdentity(target), expected)
            XCTAssertEqual(try n4Audit(fixture), before, "commit=\(atCommit)")
            try owner.close()
            XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
        }
    }

    func testStorageValidationKeepsAncestorReadPermissionChecksAtEntryAndCommit() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses the owned fixture's DAC read denial")
        for atCommit in [false, true] {
            for shadowRoute in [false, true] {
                let fixture = try CollectorOwnerFixture()
                defer { fixture.remove() }
                let live = try storageValidationLiveRoot(fixture)
                let commit = N4CommitProbe()
                let owner = try XCTUnwrap(fixture.open(identityCatalog: live.appendingPathComponent("archive.sqlite"), hooks: commit.hooks))
                defer { try? owner.close() }
                let claim = try n4Prepare(.claim, owner, fixture)
                let before = try n4Audit(fixture)
                let liveBefore = try fixture.snapshot(at: live)
                let leaf = shadowRoute ? fixture.shadowRoot : live
                let parent = leaf.deletingLastPathComponent()
                let originalMode = try fixture.mode(parent) & 0o7777
                let expected = try fixture.fileIdentity(leaf)
                XCTAssertEqual(originalMode, 0o700)
                defer { XCTAssertEqual(chmod(parent.path, originalMode), 0) }
                let denyRead = {
                    guard chmod(parent.path, 0o300) == 0 else { throw POSIXError(.EACCES) }
                    var info = stat()
                    XCTAssertEqual(fstatat(AT_FDCWD, leaf.path, &info, 0), 0, "search permission must still reach the unchanged leaf")
                    XCTAssertEqual(CollectorOwnerFixture.Identity(device: info.st_dev, inode: info.st_ino), expected)
                    XCTAssertEqual(info.st_mode & 0o7777, 0o700)
                    let descriptor = openat(AT_FDCWD, parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    let code = errno
                    if descriptor >= 0 { _ = Darwin.close(descriptor) }
                    XCTAssertEqual(descriptor, -1, "positive control: this owned ancestor denies O_RDONLY")
                    XCTAssertEqual(code, EACCES)
                    guard descriptor < 0, code == EACCES else { throw CollectorOwnerFixture.Failure.injected }
                }
                if atCommit { commit.arm(denyRead) } else { try denyRead() }
                XCTAssertThrowsError(try {
                    if atCommit { try self.n4Perform(.claim, owner, fixture.configuration, claim) }
                    else { _ = try owner.rootState(rootID: fixture.configuration.rootID) }
                }()) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .io(.openComponent, EACCES)) }
                if atCommit {
                    XCTAssertEqual(commit.visits, 1)
                    XCTAssertEqual(commit.returnedNormally, 1)
                }
                commit.disarm()
                // Restoring the mode precedes every SQL or directory snapshot.
                XCTAssertEqual(chmod(parent.path, originalMode), 0)
                XCTAssertEqual(try fixture.mode(parent) & 0o7777, originalMode)
                XCTAssertEqual(try fixture.fileIdentity(leaf), expected)
                XCTAssertEqual(try n4Audit(fixture), before)
                XCTAssertEqual(try fixture.snapshot(at: live), liveBefore)
                try owner.close()
                XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
            }
        }
    }

    func testStorageValidationPreservesPathLimitsAndRejectsMissingOrNonDirectoryRoutes() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let before = try fixture.snapshot()
        var visits = 0
        let hooks = CollectorInventoryOwnerTestHooks(beforeFilesystemAccess: { visits += 1 })
        let invalid = [
            try XCTUnwrap(URL(string: "https://invalid.example/shadow")),
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/" + Array(repeating: "a", count: 33).joined(separator: "/")),
            URL(fileURLWithPath: "/" + String(repeating: "x", count: Int(MAXPATHLEN))),
        ]
        for path in invalid {
            XCTAssertThrowsError(try fixture.open(shadowRoot: path, hooks: hooks))
            XCTAssertEqual(visits, 0, "invalid supplied path must fail before filesystem access: \(path.path.debugDescription)")
        }
        // Raw-byte primitive regression: Foundation URL.path can preserve %00 literally.
        let nulPath = "/invalid/nul\0name"
        XCTAssertTrue(nulPath.utf8.contains(0))
        XCTAssertThrowsError(try CollectorPOSIXDirectoryAccess.components(nulPath)) {
            XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .invalidBinding)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        for replacement in [N4Replacement.missing, .file] {
            for shadowRoute in [false, true] {
                let owned = try CollectorOwnerFixture()
                defer { owned.remove() }
                let owner = try XCTUnwrap(owned.open())
                defer { try? owner.close() }
                let original = try n4Audit(owned)
                let mutation = try N4PathMutation(owned, target: shadowRoute ? owned.shadowRoot : owned.liveRoot)
                defer { try? mutation.restore() }
                try mutation.install(replacement)
                XCTAssertThrowsError(try owner.rootState(rootID: "not-enrolled")) { error in
                    guard let value = error as? CollectorPOSIXEnumerationError,
                          case .io(.openComponent, let code) = value else {
                        return XCTFail("Expected a real pathname error: \(error)")
                    }
                    XCTAssertEqual(code, replacement == .missing ? ENOENT : ENOTDIR)
                }
                try mutation.restore()
                XCTAssertEqual(try n4Audit(owned), original)
                try owner.close()
                XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: owned.base), [])
            }
        }
    }

    func testStorageValidationPreAndPostOpenCancellationClosesEveryObservedDescriptor() async throws {
        for afterOpen in [false, true] {
            let fixture = try CollectorOwnerFixture()
            defer { fixture.remove() }
            let probe = StorageValidationDescriptorProbe()
            let owner = try XCTUnwrap(fixture.open(hooks: .init(storageValidationOpenHooks: probe.hooks)))
            defer { try? owner.close() }
            let before = try n4Audit(fixture)
            probe.arm()
            let task = Task {
                try withUnsafeCurrentTask { current in
                    XCTAssertNotNil(current)
                    if afterOpen { probe.afterOpen = { current?.cancel() } }
                    else { current?.cancel() }
                    defer { probe.afterOpen = nil }
                    XCTAssertThrowsError(try owner.rootState(rootID: "not-enrolled")) { XCTAssertTrue($0 is CancellationError) }
                    XCTAssertTrue(current?.isCancelled == true)
                }
            }
            try await task.value
            XCTAssertEqual(probe.opened, afterOpen ? 1 : 0)
            XCTAssertEqual(probe.closed, probe.opened)
            XCTAssertTrue(probe.live.isEmpty)
            XCTAssertTrue(probe.allDirectories && probe.allReadOnly && probe.allCloseOnExec)
            probe.disarm()
            XCTAssertEqual(try n4Audit(fixture), before)
            // The joined child owns cancellation; close runs on the uncancelled parent.
            try owner.close()
            XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
        }
    }

    func testStorageValidationOpenHookFailureClosesAnAlreadyAcquiredDescriptor() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        let probe = StorageValidationDescriptorProbe()
        let owner = try XCTUnwrap(fixture.open(hooks: .init(storageValidationOpenHooks: probe.hooks)))
        defer { try? owner.close() }
        let before = try n4Audit(fixture)
        probe.arm()
        probe.beforeOpen = {
            if probe.opened > 0 { throw CollectorOwnerFixture.Failure.injected }
        }
        XCTAssertThrowsError(try owner.rootState(rootID: "not-enrolled")) {
            XCTAssertTrue($0 is CollectorOwnerFixture.Failure)
        }
        XCTAssertGreaterThan(probe.opened, 0, "a real successful open must precede the injected fault")
        XCTAssertEqual(probe.opened, probe.closed)
        XCTAssertTrue(probe.live.isEmpty)
        probe.disarm()
        XCTAssertEqual(try n4Audit(fixture), before)
        try owner.close()
        XCTAssertEqual(try collectorOwnerFixtureDescriptors(under: fixture.base), [])
    }

    func testLiveEnrolledObservationPaysOneStorageFencePairForSixteenRoots_repro() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        var commits = 0
        let probe = StorageValidationDescriptorProbe()
        let owner = try XCTUnwrap(fixture.open(hooks: .init(
            beforeInventoryCommit: { commits += 1 },
            storageValidationOpenHooks: probe.hooks
        )))
        defer { try? owner.close() }
        var configurations: [CollectorRootConfiguration] = []
        for index in 0..<16 {
            let source = fixture.sourceParent.appendingPathComponent("observe-\(index)")
            try fixture.directory(source)
            let configuration = CollectorRootConfiguration(
                rootID: "observe-root-\(index)", source: .codex, rootPath: source.path, revision: 1)
            _ = try owner.enrollAndActivateRoot(configuration)
            configurations.append(configuration)
        }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: configurations[15].rootPath))
        let commitsAfterEnroll = commits
        probe.arm()
        XCTAssertEqual(try owner.observeLiveEnrolledRoots([]), [])
        XCTAssertEqual(probe.opened, 0)
        let observed = try owner.observeLiveEnrolledRoots(configurations)
        XCTAssertEqual(probe.opened, 4, "one publication-store entry/exit pair, not 16 isolated sessions")
        XCTAssertEqual(probe.closed, 4)
        probe.disarm()
        XCTAssertEqual(commits, commitsAfterEnroll)
        XCTAssertEqual(observed.count, 16)
        XCTAssertEqual(observed.filter(\.unavailable).map(\.configuration.rootID), ["observe-root-15"])
        XCTAssertNil(observed[15].state)
        XCTAssertTrue(observed.prefix(15).allSatisfy { !$0.unavailable && $0.state != nil })
        probe.arm()
        probe.beforeOpen = {
            guard probe.opened == 2 else { return }
            try FileManager.default.moveItem(
                at: fixture.inventoryDirectory,
                to: fixture.base.appendingPathComponent("held-inventory"))
        }
        XCTAssertThrowsError(try owner.observeLiveEnrolledRoots(configurations)) {
            XCTAssertFalse(($0 as? CollectorInventoryOwnerError) == .rootNotActivated)
        }
        XCTAssertEqual(commits, commitsAfterEnroll)
        probe.disarm()
    }

    func testUnacknowledgedDirtyOwnerBatchPaysOneStorageFencePair_repro() throws {
        let fixture = try CollectorOwnerFixture()
        defer { fixture.remove() }
        var commits = 0
        let probe = StorageValidationDescriptorProbe()
        let owner = try XCTUnwrap(fixture.open(hooks: .init(
            beforeInventoryCommit: { commits += 1 },
            storageValidationOpenHooks: probe.hooks
        )))
        defer { try? owner.close() }
        var configurations: [CollectorRootConfiguration] = []
        for index in 0..<16 {
            let source = fixture.sourceParent.appendingPathComponent("pending-\(index)")
            try fixture.directory(source)
            let configuration = CollectorRootConfiguration(
                rootID: "pending-root-\(index)", source: .codex, rootPath: source.path, revision: 1)
            _ = try owner.enrollAndActivateRoot(configuration)
            configurations.append(configuration)
        }
        let commitsAfterEnroll = commits
        probe.arm()
        XCTAssertTrue(try owner.rootsWithUnacknowledgedDirty([]).isEmpty)
        XCTAssertEqual(probe.opened, 0)
        let pending = try owner.rootsWithUnacknowledgedDirty(configurations)
        XCTAssertEqual(probe.opened, 4, "one store entry/exit pair for sixteen pending-root probes")
        XCTAssertEqual(probe.closed, 4)
        probe.disarm()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(commits, commitsAfterEnroll)
    }

    private func storageValidationLiveRoot(_ fixture: CollectorOwnerFixture) throws -> URL {
        let parent = fixture.base.appendingPathComponent("storage-validation-live")
        let root = parent.appendingPathComponent("catalog-root")
        try fixture.directory(parent)
        try fixture.directory(root)
        try fixture.catalog(root.appendingPathComponent("archive.sqlite"))
        return root
    }

    private func storageAssertNoFollowError(_ error: Error) {
        guard let value = error as? CollectorPOSIXEnumerationError,
              case .io(.openComponent, let code) = value, code == ELOOP || code == ENOTDIR else {
            return XCTFail("Expected kernel no-follow refusal: \(error)")
        }
    }
}

private final class StorageValidationDescriptorProbe {
    private var armed = false
    private(set) var opened = 0
    private(set) var closed = 0
    private(set) var maximumLive = 0
    private(set) var live: [Int32: CollectorOwnerFixture.Identity] = [:]
    private(set) var identities: [CollectorOwnerFixture.Identity] = []
    private(set) var allDirectories = true
    private(set) var allReadOnly = true
    private(set) var allCloseOnExec = true
    var beforeOpen: (() throws -> Void)?
    var afterOpen: (() -> Void)?

    var hooks: CollectorPOSIXRootEnumeratorTestHooks {
        .init(beforeOpenComponent: { [weak self] _ in
            guard let self, self.armed else { return }
            try self.beforeOpen?()
        }, didOpenDescriptor: { [weak self] descriptor in
            guard let self, self.armed else { return }
            var info = stat()
            XCTAssertEqual(fstat(descriptor, &info), 0)
            let identity = CollectorOwnerFixture.Identity(device: info.st_dev, inode: info.st_ino)
            XCTAssertNil(self.live.updateValue(identity, forKey: descriptor))
            self.identities.append(identity)
            self.opened += 1
            self.maximumLive = max(self.maximumLive, self.live.count)
            self.allDirectories = self.allDirectories && info.st_mode & S_IFMT == S_IFDIR
            let flags = fcntl(descriptor, F_GETFL)
            self.allReadOnly = self.allReadOnly && flags >= 0 && flags & O_ACCMODE == O_RDONLY
            let descriptorFlags = fcntl(descriptor, F_GETFD)
            self.allCloseOnExec = self.allCloseOnExec && descriptorFlags >= 0 && descriptorFlags & FD_CLOEXEC != 0
            self.afterOpen?()
        }, didCloseDescriptor: { [weak self] descriptor, viaStream in
            guard let self, self.armed else { return }
            XCTAssertFalse(viaStream)
            let expected = self.live.removeValue(forKey: descriptor)
            XCTAssertNotNil(expected)
            self.closed += 1
            var info = stat()
            if fstat(descriptor, &info) == 0 {
                XCTAssertNotEqual(CollectorOwnerFixture.Identity(device: info.st_dev, inode: info.st_ino), expected)
            } else { XCTAssertEqual(errno, EBADF) }
        })
    }

    func arm() {
        XCTAssertTrue(live.isEmpty)
        opened = 0; closed = 0; maximumLive = 0; identities = []
        allDirectories = true; allReadOnly = true; allCloseOnExec = true
        beforeOpen = nil; afterOpen = nil; armed = true
    }

    func disarm() {
        XCTAssertTrue(live.isEmpty)
        armed = false; beforeOpen = nil; afterOpen = nil
    }
}
