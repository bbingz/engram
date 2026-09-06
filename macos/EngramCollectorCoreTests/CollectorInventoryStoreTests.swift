import Foundation
import Darwin
import CSQLite
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorInventoryStoreTests: XCTestCase {
    func testN1ByteDifferentOwnerCannotAcknowledgeOrDeferOldOrSubstitutedOwnerClaims() throws {
        for owners in [["run-é", "run-e\u{301}"], ["run-e\u{301}", "run-é"]] {
            for substitutesOwner in [false, true] {
                for operation in ["acknowledge", "defer"] {
                    let fixture = try CollectorInventoryTestFixture()
                    defer { fixture.remove() }
                    XCTAssertEqual(owners[0], owners[1])
                    XCTAssertNotEqual(Data(owners[0].utf8), Data(owners[1].utf8))
                    let old = try fixture.openRegistered(owner: owners[0])
                    try old.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
                    let originalClaim = try fixture.claim(old)
                    let current = try fixture.open(owner: owners[1])
                    let submitted = CollectorDirtyClaim(
                        rootID: originalClaim.rootID, rootRevision: originalClaim.rootRevision,
                        relativePath: originalClaim.relativePath, dirtyRevision: originalClaim.dirtyRevision,
                        ownerRunID: substitutesOwner ? owners[1] : originalClaim.ownerRunID,
                        claimGeneration: originalClaim.claimGeneration
                    )
                    let before = try current.locator(configuration: fixture.configuration, relativePath: "one.jsonl")
                    let database = try fixture.openDatabase()
                    let persistedOwner = try database.read {
                        try Data.fetchOne($0, sql: "SELECT CAST(claim_owner_run_id AS BLOB) FROM collector_locators")
                    }
                    XCTAssertEqual(persistedOwner, Data(owners[0].utf8), "exercise the old persisted owner, not a reclaimed token")
                    let label = operation + (substitutesOwner ? "/substituted-current-owner" : "/original-old-owner")
                    // Every combination gets a fresh claim: an incorrect ACK
                    // cannot clear the row and mask a subsequent defer bypass.
                    if operation == "acknowledge" {
                        XCTAssertEqual(try current.acknowledge(submitted, captureID: "must-not-publish"), .stale, label)
                    } else {
                        XCTAssertFalse(try current.deferClaim(submitted, retryNotBefore: 999, reason: "must-not-defer"), label)
                    }
                    XCTAssertEqual(try current.locator(configuration: fixture.configuration, relativePath: "one.jsonl"), before, label)
                    XCTAssertEqual(try database.read {
                        try Data.fetchOne($0, sql: "SELECT CAST(claim_owner_run_id AS BLOB) FROM collector_locators")
                    }, persistedOwner, label)
                    withExtendedLifetime(old) {}
                }
            }
        }
    }

    func testN1ByteDifferentNewOwnerReclaimsOldClaimBeforeAcknowledgement() throws {
        for owners in [["run-é", "run-e\u{301}"], ["run-e\u{301}", "run-é"]] {
            let fixture = try CollectorInventoryTestFixture()
            defer { fixture.remove() }
            let old = try fixture.openRegistered(owner: owners[0])
            try old.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
            let originalClaim = try fixture.claim(old)
            let current = try fixture.open(owner: owners[1])
            let replacements = try current.claimDirty(configuration: fixture.configuration, limit: 1, now: 10)
            XCTAssertEqual(replacements.count, 1, "a byte-different owner must reclaim the old in-flight claim")
            guard let replacement = replacements.first else { continue }
            XCTAssertEqual(Data(replacement.ownerRunID.utf8), Data(owners[1].utf8))
            XCTAssertNotEqual(Data(replacement.ownerRunID.utf8), Data(originalClaim.ownerRunID.utf8))
            XCTAssertEqual(replacement.dirtyRevision, originalClaim.dirtyRevision)
            XCTAssertGreaterThan(replacement.claimGeneration, originalClaim.claimGeneration)
            XCTAssertEqual(try current.acknowledge(originalClaim, captureID: "stale"), .stale)
            XCTAssertFalse(try current.deferClaim(originalClaim, retryNotBefore: 999, reason: "stale"))
            XCTAssertEqual(try current.acknowledge(replacement, captureID: "current"), .acknowledged)
            XCTAssertTrue(try current.pendingLocators(configuration: fixture.configuration, limit: 10).isEmpty)
            withExtendedLifetime(old) {}
        }
    }

    func testN1EnrollmentRequiresExplicitByteExactRegisteredConfiguration() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let configuration = CollectorRootConfiguration(rootID: "root-é", source: .codex, rootPath: fixture.root.path + "/é", revision: 1)
        let identity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19)
        XCTAssertThrowsError(try store.enrollRoot(binding: .init(configuration: configuration, expectedIdentity: identity))) {
            XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
        }
        XCTAssertThrowsError(try store.enrolledRoot(configuration: configuration)) {
            XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
        }
        XCTAssertThrowsError(try store.activateEnrolledRoot(configuration: configuration)) {
            XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
        }
        try store.registerRoot(configuration)
        let before = try store.rootState(rootID: configuration.rootID)
        let mismatches = [
            CollectorRootConfiguration(rootID: "root-e\u{301}", source: .codex, rootPath: configuration.rootPath, revision: 1),
            CollectorRootConfiguration(rootID: configuration.rootID, source: .codex, rootPath: fixture.root.path + "/e\u{301}", revision: 1),
            CollectorRootConfiguration(rootID: configuration.rootID, source: .claudeCode, rootPath: configuration.rootPath, revision: 1),
            CollectorRootConfiguration(rootID: configuration.rootID, source: .codex, rootPath: configuration.rootPath, revision: 2),
        ]
        for other in mismatches {
            XCTAssertThrowsError(try store.enrollRoot(binding: .init(configuration: other, expectedIdentity: identity))) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
            XCTAssertThrowsError(try store.enrolledRoot(configuration: other)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
            XCTAssertThrowsError(try store.activateEnrolledRoot(configuration: other)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
        }
        XCTAssertEqual(try store.rootState(rootID: configuration.rootID), before)
        XCTAssertNil(try store.enrolledRoot(configuration: configuration))
        try store.enrollRoot(binding: .init(configuration: configuration, expectedIdentity: identity))
        XCTAssertEqual(try store.enrolledRoot(configuration: configuration)?.expectedIdentity, identity)
    }

    func testN1UnenrolledActivationDoesNotCreateBindingOrRequestWork() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let before = try store.rootState(rootID: fixture.configuration.rootID)
        XCTAssertNil(try store.enrolledRoot(configuration: fixture.configuration))
        XCTAssertNil(try store.activateEnrolledRoot(configuration: fixture.configuration))
        XCTAssertNil(try store.activateEnrolledRoot(configuration: fixture.configuration))
        XCTAssertEqual(try store.rootState(rootID: fixture.configuration.rootID), before)
        let database = try fixture.openDatabase()
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_root_bindings") }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.rootPath))
    }

    func testN1BindingPersistsExactConfigurationAndTypedIdentityWithoutSourceExistence() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let configurations = [
            CollectorRootConfiguration(rootID: "root-é", source: .codex, rootPath: fixture.root.path + "/é/absent", revision: 1),
            CollectorRootConfiguration(rootID: "root-e\u{301}", source: .claudeCode, rootPath: fixture.root.path + "/e\u{301}/absent", revision: 1),
        ]
        let identity = CollectorPOSIXDirectoryIdentity(
            device: 7, inode: Int64.max - 10, generation: UInt32.max,
            birthSeconds: 1_700_000_001, birthNanoseconds: 999_999_999
        )
        var store: CollectorInventoryStore? = try fixture.open(owner: "run-1")
        for configuration in configurations {
            XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.rootPath))
            try store!.registerRoot(configuration)
            try store!.enrollRoot(binding: .init(configuration: configuration, expectedIdentity: identity))
        }
        store = nil
        let reopened = try fixture.open(owner: "run-2")
        let database = try fixture.openDatabase()
        for configuration in configurations {
            let before = try reopened.rootState(rootID: configuration.rootID)
            let loaded = try XCTUnwrap(reopened.enrolledRoot(configuration: configuration))
            XCTAssertEqual(loaded.configuration, configuration)
            XCTAssertEqual(Data(loaded.configuration.rootID.utf8), Data(configuration.rootID.utf8))
            XCTAssertEqual(Data(loaded.configuration.rootPath.utf8), Data(configuration.rootPath.utf8))
            XCTAssertEqual(loaded.expectedIdentity, identity)
            XCTAssertEqual(try reopened.rootState(rootID: configuration.rootID), before, "load is not activation")
            let row = try database.read { db in
                try XCTUnwrap(Row.fetchOne(db, sql: """
                    SELECT typeof(device) AS device_type, typeof(inode) AS inode_type,
                        typeof(generation) AS generation_type, typeof(birth_seconds) AS seconds_type,
                        typeof(birth_nanoseconds) AS nanoseconds_type, last_activated_owner_run_id
                    FROM collector_root_bindings WHERE root_id = ? AND root_revision = ?
                    """, arguments: [configuration.rootID, configuration.revision]))
            }
            for key in ["device_type", "inode_type", "generation_type", "seconds_type", "nanoseconds_type"] {
                let type: String = row[key]
                XCTAssertEqual(type, "integer", key)
            }
            let stamp: String? = row["last_activated_owner_run_id"]
            XCTAssertNil(stamp, "enrollment and readback do not silently activate a root")
            XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.rootPath))
        }
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_root_bindings") }, 2)
    }

    func testN1EnrollmentIsIdempotentAndRejectsEverySameRevisionIdentityChange() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let identity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19)
        let binding = CollectorPOSIXRootBinding(configuration: fixture.configuration, expectedIdentity: identity)
        try store.enrollRoot(binding: binding)
        let before = try store.rootState(rootID: fixture.configuration.rootID)
        try store.enrollRoot(binding: binding)
        let changes = [
            CollectorPOSIXDirectoryIdentity(device: 8, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19),
            CollectorPOSIXDirectoryIdentity(device: 7, inode: 12, generation: 13, birthSeconds: 17, birthNanoseconds: 19),
            CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 14, birthSeconds: 17, birthNanoseconds: 19),
            CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 18, birthNanoseconds: 19),
            CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 20),
        ]
        for changed in changes {
            XCTAssertThrowsError(try store.enrollRoot(binding: .init(configuration: fixture.configuration, expectedIdentity: changed))) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidRoot)
            }
            XCTAssertEqual(try store.enrolledRoot(configuration: fixture.configuration)?.expectedIdentity, identity)
            XCTAssertEqual(try store.rootState(rootID: fixture.configuration.rootID), before)
        }
        let database = try fixture.openDatabase()
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_root_bindings") }, 1)
    }

    func testN1VersionOneMigrationPreservesInventoryAndLeavesRootsUnenrolled() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var store: CollectorInventoryStore? = try fixture.openRegistered(owner: "run-1")
        try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        XCTAssertEqual(try store!.acknowledge(fixture.claim(store!), captureID: "last-good"), .acknowledged)
        try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        _ = try fixture.claim(store!)
        let checkpoint = CollectorEventCheckpoint(epoch: "epoch-1", cursor: "cursor-1")
        try store!.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil, nextCheckpoint: checkpoint,
            dirtyRelativePaths: [], requiresReconciliation: false
        )
        let scan = try store!.beginBootstrap(configuration: fixture.configuration, scanID: "old-scan")
        try store!.applyBootstrapBatch(fixture.batch(scan: scan, children: ["nested"], finished: true))
        let beforeRoot = try store!.rootState(rootID: fixture.configuration.rootID)
        let beforeLocator = try store!.locator(configuration: fixture.configuration, relativePath: "one.jsonl")
        store = nil
        let database = try fixture.openDatabase()
        // Reconstruct the frozen v1 shape before opening the migration owner.
        try database.write { db in
            try db.execute(sql: """
                DROP TABLE IF EXISTS collector_root_bindings;
                UPDATE collector_metadata SET value = '1' WHERE key = 'schema_version';
                CREATE TRIGGER n1_no_locator_update BEFORE UPDATE ON collector_locators
                BEGIN SELECT RAISE(ABORT, 'migration rewrote locators'); END;
                CREATE TRIGGER n1_no_locator_delete BEFORE DELETE ON collector_locators
                BEGIN SELECT RAISE(ABORT, 'migration deleted locators'); END;
                CREATE TRIGGER n1_no_frontier_update BEFORE UPDATE ON collector_frontier
                BEGIN SELECT RAISE(ABORT, 'migration rewrote frontier'); END;
                CREATE TRIGGER n1_no_frontier_delete BEFORE DELETE ON collector_frontier
                BEGIN SELECT RAISE(ABORT, 'migration deleted frontier'); END;
                """)
        }
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'") }, 4)
        try database.close()
        let reopened = try fixture.open(owner: "run-2")
        XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID), beforeRoot)
        XCTAssertEqual(try reopened.locator(configuration: fixture.configuration, relativePath: "one.jsonl"), beforeLocator)
        XCTAssertEqual(try reopened.pendingDirectories(scan: scan, limit: 10), ["nested"])
        XCTAssertNil(try reopened.enrolledRoot(configuration: fixture.configuration))
        XCTAssertNil(try reopened.activateEnrolledRoot(configuration: fixture.configuration))
        XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID), beforeRoot)
        let check = try fixture.openDatabase()
        XCTAssertEqual(try check.read { try String.fetchOne($0, sql: "SELECT value FROM collector_metadata WHERE key = 'schema_version'") }, "2")
        XCTAssertEqual(try check.read { try String.fetchOne($0, sql: "SELECT claim_owner_run_id FROM collector_locators") }, "run-1")
        XCTAssertEqual(try check.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_root_bindings") }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.rootPath))
    }

    func testN1MigrationCommitFailureRollsBackSchemaVersionAndOwnerTakeover() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var store: CollectorInventoryStore? = try fixture.openRegistered(owner: "run-1")
        try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        store = nil
        let database = try fixture.openDatabase()
        try database.write { db in
            try db.execute(sql: """
                DROP TABLE IF EXISTS collector_root_bindings;
                UPDATE collector_metadata SET value = '1' WHERE key = 'schema_version';
                """)
        }
        XCTAssertThrowsError(try fixture.open(owner: "run-2", hooks: .init(beforeCommit: {
            throw CollectorInventoryInjectedFailure.beforeCommit
        }))) { XCTAssertEqual($0 as? CollectorInventoryInjectedFailure, .beforeCommit) }
        XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT value FROM collector_metadata WHERE key = 'schema_version'") }, "1")
        XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT value FROM collector_metadata WHERE key = 'active_owner_run_id'") }, "run-1")
        XCTAssertNil(try database.read { try String.fetchOne($0, sql: "SELECT name FROM sqlite_master WHERE name = 'collector_root_bindings'") })
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_locators") }, 1)
        let reopened = try fixture.open(owner: "run-2")
        XCTAssertNil(try reopened.enrolledRoot(configuration: fixture.configuration))
        XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT value FROM collector_metadata WHERE key = 'schema_version'") }, "2")
    }

    func testN1UnknownSchemaVersionsFailWithoutAddingBindingsOrTakingOwnership() throws {
        for version in ["0", "3", "not-a-version"] {
            let fixture = try CollectorInventoryTestFixture()
            defer { fixture.remove() }
            var store: CollectorInventoryStore? = try fixture.openRegistered(owner: "run-1")
            try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
            store = nil
            let database = try fixture.openDatabase()
            try database.write { db in
                try db.execute(sql: "DROP TABLE IF EXISTS collector_root_bindings")
                try db.execute(sql: "UPDATE collector_metadata SET value = ? WHERE key = 'schema_version'", arguments: [version])
            }
            XCTAssertThrowsError(try fixture.open(owner: "run-2")) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidState)
            }
            XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT value FROM collector_metadata WHERE key = 'schema_version'") }, version)
            XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT value FROM collector_metadata WHERE key = 'active_owner_run_id'") }, "run-1")
            XCTAssertNil(try database.read { try String.fetchOne($0, sql: "SELECT name FROM sqlite_master WHERE name = 'collector_root_bindings'") })
            XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_locators") }, 1)
        }
    }

    func testN1MissingOrSQLTypeDamagedBindingFieldsFailClosedWithoutActivation() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let database = try fixture.openDatabase()
        let fields = ["device", "inode", "generation", "birth_seconds", "birth_nanoseconds"]
        var corruptions: [(column: String, expression: String?)] = []
        for field in fields {
            for value in ["NULL", "'7'", "7.5", "X'37'"] { corruptions.append((field, value)) }
            corruptions.append((field, nil))
        }
        corruptions += [
            ("generation", "-1"), ("generation", "4294967296"),
            ("birth_nanoseconds", "-1"), ("birth_nanoseconds", "1000000000"),
            ("last_activated_owner_run_id", "42"), ("last_activated_owner_run_id", "X'72756E'"),
        ]
        let validProjection = [
            "7 AS device", "11 AS inode", "13 AS generation",
            "17 AS birth_seconds", "19 AS birth_nanoseconds", "NULL AS last_activated_owner_run_id",
        ]
        for corruption in corruptions {
            // A lax fixture table reproduces damaged on-disk values that must
            // not be coerced by GRDB or hidden by fresh-schema constraints.
            try database.write { db in
                try db.execute(sql: "DROP TABLE IF EXISTS collector_root_bindings")
                try db.execute(sql: """
                    CREATE TABLE collector_root_bindings AS
                    SELECT ? AS root_id, 1 AS root_revision, \(validProjection.joined(separator: ", "))
                    """, arguments: [fixture.configuration.rootID])
            }
            let valid = try XCTUnwrap(store.enrolledRoot(configuration: fixture.configuration))
            XCTAssertEqual(valid.expectedIdentity, .init(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19))
            let before = try store.rootState(rootID: fixture.configuration.rootID)
            try database.write { db in
                if let expression = corruption.expression {
                    try db.execute(sql: "UPDATE collector_root_bindings SET \(corruption.column) = \(expression)")
                } else {
                    let kept = validProjection.filter { !$0.hasSuffix(" AS " + corruption.column) }
                    try db.execute(sql: "DROP TABLE collector_root_bindings")
                    try db.execute(sql: """
                        CREATE TABLE collector_root_bindings AS
                        SELECT ? AS root_id, 1 AS root_revision, \(kept.joined(separator: ", "))
                        """, arguments: [fixture.configuration.rootID])
                }
            }
            let label = corruption.column + "=" + (corruption.expression ?? "<missing column>")
            XCTAssertThrowsError(try store.enrolledRoot(configuration: fixture.configuration), label) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidState, label)
            }
            XCTAssertThrowsError(try store.activateEnrolledRoot(configuration: fixture.configuration), label) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidState, label)
            }
            XCTAssertEqual(try store.rootState(rootID: fixture.configuration.rootID), before, label)
        }
    }

    func testN1NewRootRevisionNeedsExplicitReenrollmentAndRetainsFencedOldRows() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let identity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19)
        try store.enrollRoot(binding: .init(configuration: fixture.configuration, expectedIdentity: identity))
        try store.markDirty(configuration: fixture.configuration, relativePath: "old.jsonl")
        let claim = try fixture.claim(store)
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "old-scan")
        let database = try fixture.openDatabase()
        try database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER n1_no_locator_update BEFORE UPDATE ON collector_locators
                BEGIN SELECT RAISE(ABORT, 'revision rewrote locators'); END;
                CREATE TRIGGER n1_no_locator_delete BEFORE DELETE ON collector_locators
                BEGIN SELECT RAISE(ABORT, 'revision deleted locators'); END;
                CREATE TRIGGER n1_no_frontier_update BEFORE UPDATE ON collector_frontier
                BEGIN SELECT RAISE(ABORT, 'revision rewrote frontier'); END;
                CREATE TRIGGER n1_no_frontier_delete BEFORE DELETE ON collector_frontier
                BEGIN SELECT RAISE(ABORT, 'revision deleted frontier'); END;
                """)
        }
        let replacement = fixture.configuration(revision: 2)
        try store.registerRoot(replacement)
        let before = try store.rootState(rootID: replacement.rootID)
        XCTAssertNil(try store.enrolledRoot(configuration: replacement))
        XCTAssertNil(try store.activateEnrolledRoot(configuration: replacement))
        XCTAssertEqual(try store.rootState(rootID: replacement.rootID), before)
        XCTAssertThrowsError(try store.enrolledRoot(configuration: fixture.configuration)) {
            XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
        }
        XCTAssertThrowsError(try store.enrollRoot(binding: .init(configuration: fixture.configuration, expectedIdentity: identity))) {
            XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
        }
        let changed = CollectorPOSIXDirectoryIdentity(device: 7, inode: 12, generation: 13, birthSeconds: 17, birthNanoseconds: 19)
        try store.enrollRoot(binding: .init(configuration: replacement, expectedIdentity: changed))
        XCTAssertEqual(try store.enrolledRoot(configuration: replacement)?.expectedIdentity, changed)
        XCTAssertEqual(try store.acknowledge(claim, captureID: "stale"), .stale)
        XCTAssertFalse(try store.finishBootstrap(scan))
        XCTAssertThrowsError(try store.applyBootstrapBatch(fixture.batch(scan: scan, finished: true))) {
            XCTAssertEqual($0 as? CollectorInventoryError, .staleScan)
        }
        XCTAssertTrue(try store.pendingLocators(configuration: replacement, limit: 10).isEmpty)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_root_bindings") }, 2)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_locators") }, 1)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_frontier") }, 1)
        XCTAssertEqual(try database.read { try Int64.fetchOne($0, sql: "SELECT inode FROM collector_root_bindings WHERE root_revision = 1") }, identity.inode)
    }

    func testN1ActivationUsesExactOwnerBytesAndIsIdempotentAcrossQueueReopen() throws {
        for owners in [["run-é", "run-e\u{301}"], ["run-e\u{301}", "run-é"]] {
            let fixture = try CollectorInventoryTestFixture()
            defer { fixture.remove() }
            let identity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19)
            var store: CollectorInventoryStore? = try fixture.openRegistered(owner: owners[0])
            try store!.enrollRoot(binding: .init(configuration: fixture.configuration, expectedIdentity: identity))
            let registered = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
            XCTAssertEqual(try store!.activateEnrolledRoot(configuration: fixture.configuration)?.expectedIdentity, identity)
            let activated = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
            XCTAssertEqual(activated.requestedRevision, registered.requestedRevision + 1)
            try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
            XCTAssertEqual(try store!.acknowledge(fixture.claim(store!), captureID: "last-good"), .acknowledged)
            try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
            XCTAssertTrue(try store!.deferClaim(fixture.claim(store!), retryNotBefore: 50, reason: "retry"))
            let checkpoint = CollectorEventCheckpoint(epoch: "epoch-1", cursor: "cursor-1")
            try store!.applyEventBatch(
                configuration: fixture.configuration, expectedCheckpoint: nil, nextCheckpoint: checkpoint,
                dirtyRelativePaths: [], requiresReconciliation: false
            )
            let scan = try store!.beginBootstrap(configuration: fixture.configuration, scanID: "unfinished")
            let beforeRoot = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
            let beforeLocator = try store!.locator(configuration: fixture.configuration, relativePath: "one.jsonl")
            store = nil
            let database = try fixture.openDatabase()
            try database.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER n1_no_locator_update BEFORE UPDATE ON collector_locators
                    BEGIN SELECT RAISE(ABORT, 'activation rewrote locators'); END;
                    CREATE TRIGGER n1_no_locator_delete BEFORE DELETE ON collector_locators
                    BEGIN SELECT RAISE(ABORT, 'activation deleted locators'); END;
                    CREATE TRIGGER n1_no_frontier_update BEFORE UPDATE ON collector_frontier
                    BEGIN SELECT RAISE(ABORT, 'activation rewrote frontier'); END;
                    CREATE TRIGGER n1_no_frontier_delete BEFORE DELETE ON collector_frontier
                    BEGIN SELECT RAISE(ABORT, 'activation deleted frontier'); END;
                    """)
            }
            store = try fixture.open(owner: owners[0])
            XCTAssertEqual(try store!.activateEnrolledRoot(configuration: fixture.configuration)?.expectedIdentity, identity)
            XCTAssertEqual(try store!.rootState(rootID: fixture.configuration.rootID), beforeRoot)
            store = nil
            store = try fixture.open(owner: owners[1])
            XCTAssertNotEqual(Data(owners[0].utf8), Data(owners[1].utf8))
            XCTAssertEqual(try store!.enrolledRoot(configuration: fixture.configuration)?.expectedIdentity, identity)
            XCTAssertEqual(try store!.rootState(rootID: fixture.configuration.rootID), beforeRoot, "readback must not clear or create a gap")
            let oldStamp = try database.read {
                try Data.fetchOne($0, sql: "SELECT CAST(last_activated_owner_run_id AS BLOB) FROM collector_root_bindings")
            }
            XCTAssertEqual(oldStamp, Data(owners[0].utf8))
            XCTAssertEqual(try store!.activateEnrolledRoot(configuration: fixture.configuration)?.expectedIdentity, identity)
            let newRoot = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
            XCTAssertEqual(newRoot.requestedRevision, beforeRoot.requestedRevision + 1)
            XCTAssertEqual(newRoot.completedRevision, beforeRoot.completedRevision)
            XCTAssertEqual(newRoot.eventCheckpoint, checkpoint)
            XCTAssertEqual(newRoot.activeScan, scan)
            XCTAssertEqual(try store!.locator(configuration: fixture.configuration, relativePath: "one.jsonl"), beforeLocator)
            XCTAssertEqual(try store!.pendingDirectories(scan: scan, limit: 10), [""])
            let newStamp = try database.read {
                try Data.fetchOne($0, sql: "SELECT CAST(last_activated_owner_run_id AS BLOB) FROM collector_root_bindings")
            }
            XCTAssertEqual(newStamp, Data(owners[1].utf8))
            _ = try store!.activateEnrolledRoot(configuration: fixture.configuration)
            XCTAssertEqual(try store!.rootState(rootID: fixture.configuration.rootID), newRoot)
        }
    }

    func testN1EnrollmentCommitFailureDoesNotLeaveAPartialBinding() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var shouldFail = false
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: {
            if shouldFail { throw CollectorInventoryInjectedFailure.beforeCommit }
        }))
        let identity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19)
        let binding = CollectorPOSIXRootBinding(configuration: fixture.configuration, expectedIdentity: identity)
        let before = try store.rootState(rootID: fixture.configuration.rootID)
        shouldFail = true
        XCTAssertThrowsError(try store.enrollRoot(binding: binding)) {
            XCTAssertEqual($0 as? CollectorInventoryInjectedFailure, .beforeCommit)
        }
        shouldFail = false
        XCTAssertNil(try store.enrolledRoot(configuration: fixture.configuration))
        XCTAssertEqual(try store.rootState(rootID: fixture.configuration.rootID), before)
        let database = try fixture.openDatabase()
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collector_root_bindings") }, 0)
        try store.enrollRoot(binding: binding)
        XCTAssertEqual(try store.enrolledRoot(configuration: fixture.configuration)?.expectedIdentity, identity)
    }

    func testN1ActivationCommitFailureRollsBackGapAndOwnerStampAcrossRestart() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let identity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19)
        var store: CollectorInventoryStore? = try fixture.openRegistered(owner: "run-1")
        try store!.enrollRoot(binding: .init(configuration: fixture.configuration, expectedIdentity: identity))
        _ = try store!.activateEnrolledRoot(configuration: fixture.configuration)
        try store!.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
        let scan = try store!.beginBootstrap(configuration: fixture.configuration, scanID: "unfinished")
        let beforeRoot = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
        let beforeLocator = try store!.locator(configuration: fixture.configuration, relativePath: "one.jsonl")
        store = nil
        var shouldFail = false
        store = try fixture.open(owner: "run-2", hooks: .init(beforeCommit: {
            if shouldFail { throw CollectorInventoryInjectedFailure.beforeCommit }
        }))
        shouldFail = true
        XCTAssertThrowsError(try store!.activateEnrolledRoot(configuration: fixture.configuration)) {
            XCTAssertEqual($0 as? CollectorInventoryInjectedFailure, .beforeCommit)
        }
        shouldFail = false
        XCTAssertEqual(try store!.rootState(rootID: fixture.configuration.rootID), beforeRoot)
        XCTAssertEqual(try store!.locator(configuration: fixture.configuration, relativePath: "one.jsonl"), beforeLocator)
        XCTAssertEqual(try store!.pendingDirectories(scan: scan, limit: 10), [""])
        let database = try fixture.openDatabase()
        XCTAssertEqual(try database.read { try Data.fetchOne($0, sql: "SELECT CAST(last_activated_owner_run_id AS BLOB) FROM collector_root_bindings") }, Data("run-1".utf8))
        store = nil
        let reopened = try fixture.open(owner: "run-2")
        XCTAssertEqual(try reopened.activateEnrolledRoot(configuration: fixture.configuration)?.expectedIdentity, identity)
        let after = try XCTUnwrap(reopened.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(after.requestedRevision, beforeRoot.requestedRevision + 1)
        XCTAssertEqual(after.completedRevision, beforeRoot.completedRevision)
        XCTAssertEqual(after.activeScan, scan)
        XCTAssertEqual(try database.read { try Data.fetchOne($0, sql: "SELECT CAST(last_activated_owner_run_id AS BLOB) FROM collector_root_bindings") }, Data("run-2".utf8))
        _ = try reopened.activateEnrolledRoot(configuration: fixture.configuration)
        XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID), after)
    }

    func testN1RestartActivationAndMissedEventsSurviveOldScanCompletion() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let identity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19)
        var store: CollectorInventoryStore? = try fixture.openRegistered(owner: "run-1")
        try store!.enrollRoot(binding: .init(configuration: fixture.configuration, expectedIdentity: identity))
        _ = try store!.activateEnrolledRoot(configuration: fixture.configuration)
        let oldScan = try store!.beginBootstrap(configuration: fixture.configuration, scanID: "old-scan")
        try store!.applyBootstrapBatch(fixture.batch(scan: oldScan, files: [fixture.file("one.jsonl")], finished: true))
        store = nil
        store = try fixture.open(owner: "run-2")
        _ = try store!.activateEnrolledRoot(configuration: fixture.configuration)
        let beforeEvent = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
        let checkpoint = CollectorEventCheckpoint(epoch: "new-stream", cursor: "missed-events")
        try store!.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil, nextCheckpoint: checkpoint,
            dirtyRelativePaths: ["event.jsonl"], requiresReconciliation: true
        )
        XCTAssertTrue(try store!.finishBootstrap(oldScan))
        let pending = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(pending.completedRevision, oldScan.requestedRevision)
        XCTAssertEqual(pending.requestedRevision, beforeEvent.requestedRevision + 1)
        XCTAssertEqual(pending.requestedRevision, oldScan.requestedRevision + 2)
        XCTAssertEqual(pending.eventCheckpoint, checkpoint)
        XCTAssertEqual(try store!.pendingLocators(configuration: fixture.configuration, limit: 10).map(\.relativePath), ["event.jsonl", "one.jsonl"])
        store = nil
        let reopened = try fixture.open(owner: "run-2")
        XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID), pending)
        let reconciliation = try reopened.beginBootstrap(configuration: fixture.configuration, scanID: "fresh-scan")
        XCTAssertEqual(reconciliation.requestedRevision, pending.requestedRevision)
        try reopened.applyBootstrapBatch(fixture.batch(scan: reconciliation, finished: true))
        XCTAssertTrue(try reopened.finishBootstrap(reconciliation))
        let completed = try XCTUnwrap(reopened.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(completed.completedRevision, pending.requestedRevision)
        XCTAssertEqual(completed.completedRevision, completed.requestedRevision)
    }

    func testN1OldOwnerCannotEnrollOrActivateAfterTakeover() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let identity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 13, birthSeconds: 17, birthNanoseconds: 19)
        let binding = CollectorPOSIXRootBinding(configuration: fixture.configuration, expectedIdentity: identity)
        let old = try fixture.openRegistered(owner: "run-1")
        try old.enrollRoot(binding: binding)
        _ = try old.activateEnrolledRoot(configuration: fixture.configuration)
        let current = try fixture.open(owner: "run-2")
        let before = try current.rootState(rootID: fixture.configuration.rootID)
        XCTAssertThrowsError(try old.enrollRoot(binding: binding)) {
            XCTAssertEqual($0 as? CollectorInventoryError, .staleOwner)
        }
        XCTAssertThrowsError(try old.activateEnrolledRoot(configuration: fixture.configuration)) {
            XCTAssertEqual($0 as? CollectorInventoryError, .staleOwner)
        }
        XCTAssertEqual(try current.rootState(rootID: fixture.configuration.rootID), before)
        let database = try fixture.openDatabase()
        XCTAssertEqual(try database.read { try Data.fetchOne($0, sql: "SELECT CAST(last_activated_owner_run_id AS BLOB) FROM collector_root_bindings") }, Data("run-1".utf8))
        XCTAssertEqual(try current.enrolledRoot(configuration: fixture.configuration)?.expectedIdentity, identity)
        withExtendedLifetime(old) {}
    }

    func testN1CanonicallyEquivalentByteDifferentOwnerCannotBypassExistingWriteFence() throws {
        for owners in [["run-é", "run-e\u{301}"], ["run-e\u{301}", "run-é"]] {
            let fixture = try CollectorInventoryTestFixture()
            defer { fixture.remove() }
            XCTAssertEqual(owners[0], owners[1], "Swift String equality alone is insufficient for this fence")
            XCTAssertNotEqual(Data(owners[0].utf8), Data(owners[1].utf8))
            let old = try fixture.openRegistered(owner: owners[0])
            try old.markDirty(configuration: fixture.configuration, relativePath: "one.jsonl")
            let current = try fixture.open(owner: owners[1])
            try current.markDirty(configuration: fixture.configuration, relativePath: "current.jsonl")
            let beforeRoot = try current.rootState(rootID: fixture.configuration.rootID)
            let beforeRows = try current.pendingLocators(configuration: fixture.configuration, limit: 10)
            let database = try fixture.openDatabase()
            XCTAssertEqual(try database.read {
                try Data.fetchOne($0, sql: "SELECT CAST(value AS BLOB) FROM collector_metadata WHERE key = 'active_owner_run_id'")
            }, Data(owners[1].utf8))
            // This regression uses only the pre-N1 APIs, so its RED cannot be
            // attributed to the new binding API scaffold or missing schema v2.
            XCTAssertThrowsError(try old.markDirty(configuration: fixture.configuration, relativePath: "stale.jsonl")) {
                XCTAssertEqual($0 as? CollectorInventoryError, .staleOwner)
            }
            XCTAssertThrowsError(try old.requestReconciliation(configuration: fixture.configuration)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .staleOwner)
            }
            XCTAssertThrowsError(try old.registerRoot(fixture.configuration)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .staleOwner)
            }
            XCTAssertEqual(try current.rootState(rootID: fixture.configuration.rootID), beforeRoot)
            XCTAssertEqual(try current.pendingLocators(configuration: fixture.configuration, limit: 10), beforeRows)
            withExtendedLifetime(old) {}
        }
    }

    func testN1PersistedBindingRejectsPhysicalRootReplacementAfterInventoryReopen() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let resolved = try XCTUnwrap(realpath(fixture.root.path, nil))
        defer { free(resolved) }
        let parent = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let source = parent.appendingPathComponent("owned-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let descriptor = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        XCTAssertEqual(fstat(descriptor, &info), 0)
        let identity = CollectorPOSIXDirectoryIdentity(
            device: Int64(info.st_dev), inode: Int64(info.st_ino), generation: info.st_gen,
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
        let configuration = CollectorRootConfiguration(rootID: "owned-root", source: .codex, rootPath: source.path, revision: 1)
        var store: CollectorInventoryStore? = try fixture.open(owner: "run-1")
        try store!.registerRoot(configuration)
        try store!.enrollRoot(binding: .init(configuration: configuration, expectedIdentity: identity))
        let first = try XCTUnwrap(store!.enrolledRoot(configuration: configuration))
        let originalEnumerator = try CollectorPOSIXRootEnumerator(binding: first)
        let originalCursor = try originalEnumerator.open(configuration: configuration, relativeDirectory: "")
        XCTAssertNil(try originalCursor.next(), "a real empty owned root must open before replacement")
        store = nil
        try FileManager.default.moveItem(at: source, to: parent.appendingPathComponent("owned-source-old"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let replacementDescriptor = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(replacementDescriptor, 0)
        guard replacementDescriptor >= 0 else { return }
        defer { close(replacementDescriptor) }
        var replacementInfo = stat()
        XCTAssertEqual(fstat(replacementDescriptor, &replacementInfo), 0)
        XCTAssertNotEqual(replacementInfo.st_ino, info.st_ino, "the old directory and descriptor remain alive")
        let reopened = try fixture.open(owner: "run-2")
        let loaded = try XCTUnwrap(reopened.enrolledRoot(configuration: configuration))
        XCTAssertEqual(loaded.expectedIdentity, identity, "loading is not revalidation or reenrollment")
        let enumerator = try CollectorPOSIXRootEnumerator(binding: loaded)
        XCTAssertThrowsError(try enumerator.open(configuration: configuration, relativeDirectory: "")) {
            XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .rootIdentityChanged)
        }
        XCTAssertEqual(try reopened.enrolledRoot(configuration: configuration)?.expectedIdentity, identity)
        XCTAssertNil(try reopened.rootState(rootID: configuration.rootID)?.activeScan)
        XCTAssertTrue(try reopened.pendingLocators(configuration: configuration, limit: 10).isEmpty)
    }

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
        XCTAssertEqual(Set(tables), ["collector_metadata", "collector_roots", "collector_locators", "collector_frontier", "collector_root_bindings"])
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
