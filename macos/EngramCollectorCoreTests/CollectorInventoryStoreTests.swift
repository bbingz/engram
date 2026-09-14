import Foundation
import Darwin
import CSQLite
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorInventoryStoreTests: XCTestCase {
    func testSnapshotByteBudgetIncludesFrozenVSCodeConfigurationAndRejectsOverflow() throws {
        let bytes = Data(#"{"folders":[{"path":"project"}]}"#.utf8)
        let configuration = try ArchiveVSCodeWorkspaceContext(
            configurationLocator: "/project.code-workspace",
            configurationGeneration: ArchiveSourceGeneration(device: 1, inode: 2,
                size: Int64(bytes.count), mtimeNs: 1, ctimeNs: 1, mode: 0o100600),
            configurationData: bytes, configurationSHA256: ArchiveV2Hash.sha256(bytes))
        func snapshot(size: Int64, context: ArchiveVSCodeWorkspaceContext?) throws -> CollectorDependencySnapshot {
            CollectorDependencySnapshot(entrypointRelativePath: "ws/chatSessions/chat.jsonl",
                present: [.init(relativePath: "ws/chatSessions/chat.jsonl",
                    generation: try ArchiveSourceGeneration(device: 1, inode: 3,
                        size: size, mtimeNs: 1, ctimeNs: 1, mode: 0o100600))],
                absentRelativePaths: [], vscodeWorkspaceContext: context)
        }
        XCTAssertEqual(try snapshot(size: 42, context: configuration).presentByteCount(), 42 + Int64(bytes.count))
        XCTAssertEqual(try snapshot(size: 42, context: ArchiveVSCodeWorkspaceContext(
            configurationLocator: "/missing.code-workspace")).presentByteCount(), 42)
        XCTAssertEqual(try snapshot(size: 42, context: nil).presentByteCount(), 42)
        XCTAssertThrowsError(try snapshot(size: Int64.max, context: configuration).presentByteCount())
    }

    func testSchemaNineMigrationPreservesPublicationAndACKBytes() throws {
        let f = try CollectorInventoryTestFixture(); defer { f.remove() }
        _ = try f.openRegistered()
        let db = try f.openDatabase()
        try f.seedPublications(in: db, acknowledgedReplicas: ["hq"])
        let before = try db.read { db in
            (try Data.fetchOne(db, sql: "SELECT canonical_bytes FROM collector_publications"),
             try Data.fetchOne(db, sql: "SELECT ack_bytes FROM collector_publication_replicas WHERE replica_id = 'hq'"),
             try String.fetchOne(db, sql: "SELECT source_instance_id FROM collector_streams"),
             try String.fetchOne(db, sql: "SELECT collector_epoch FROM collector_streams"))
        }
        try downgradeStreamsToSchemaNine(db)
        _ = try f.open(owner: "migration-owner")
        try db.read { db in
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT canonical_bytes FROM collector_publications"), before.0)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT ack_bytes FROM collector_publication_replicas WHERE replica_id = 'hq'"), before.1)
            XCTAssertNotNil(before.1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT source_instance_id FROM collector_streams"), before.2)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT collector_epoch FROM collector_streams"), before.3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT last_sequence FROM collector_streams"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT effective_source FROM collector_streams"), f.configuration.source.rawValue)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testSchemaNineHistoricalStreamsRemainUnresolvedAndSeparateFromCurrentSources() throws {
        let f = try CollectorInventoryTestFixture(); defer { f.remove() }
        let store = try f.openRegistered()
        let db = try f.openDatabase()
        try f.seedPublications(in: db)
        let next = CollectorRootConfiguration(rootID: f.configuration.rootID, source: .claudeCode,
            rootPath: f.configuration.rootPath, revision: f.configuration.revision + 1)
        try store.registerRoot(next)
        try downgradeStreamsToSchemaNine(db)
        _ = try f.open(owner: "migration-owner")
        try db.write { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT effective_source FROM collector_streams"), "")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT last_sequence FROM collector_streams"), 1)
            for source in ["claude-code", "minimax", "lobsterai"] {
                try db.execute(sql: """
                    INSERT INTO collector_streams(root_id, root_revision, effective_source,
                        source_instance_id, collector_epoch, last_sequence) VALUES (?, ?, ?, ?, ?, 0)
                    """, arguments: [next.rootID, next.revision, source, UUID().uuidString, UUID().uuidString])
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM collector_streams"), 4)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        _ = try f.open(owner: "second-reopen")
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_streams") }, 4)
    }

    private func downgradeStreamsToSchemaNine(_ database: DatabaseQueue) throws {
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            do {
                try db.inTransaction {
                    try db.execute(sql: """
                        CREATE TABLE collector_streams_v9 (
                            root_id TEXT NOT NULL, root_revision INTEGER NOT NULL,
                            source_instance_id TEXT NOT NULL, collector_epoch TEXT NOT NULL,
                            last_sequence INTEGER NOT NULL,
                            PRIMARY KEY(root_id, root_revision),
                            UNIQUE(root_id, root_revision, source_instance_id, collector_epoch),
                            FOREIGN KEY(root_id) REFERENCES collector_roots(root_id)
                        ) WITHOUT ROWID;
                        INSERT INTO collector_streams_v9 SELECT root_id, root_revision,
                            source_instance_id, collector_epoch, last_sequence FROM collector_streams;
                        DROP TABLE collector_streams;
                        ALTER TABLE collector_streams_v9 RENAME TO collector_streams;
                        UPDATE collector_metadata SET value = '9' WHERE key = 'publication_schema_version';
                        """)
                    XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                    return .commit
                }
            } catch {
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                throw error
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
    }

    func testCursorLayoutAndByteExactPairPersistAndRequireNewRootRevision() throws {
        let f = try CollectorInventoryTestFixture(); defer { f.remove() }
        let store = try f.open()
        let root = CollectorRootConfiguration(rootID: "legacy", source: .cursor,
            rootPath: "/tmp/explicit-cursor/User/globalStorage", revision: 1,
            cursorLegacy: true, cursorModernRootID: "modern-é")
        try store.registerRoot(root)
        let reopened = try f.open(owner: "run-2")
        XCTAssertEqual(try reopened.rootState(rootID: root.rootID)?.configuration, root)
        let changed = CollectorRootConfiguration(rootID: root.rootID, source: root.source,
            rootPath: root.rootPath, revision: 1, cursorLegacy: true, cursorModernRootID: "modern-e\u{301}")
        XCTAssertNotEqual(root, changed)
        XCTAssertThrowsError(try reopened.registerRoot(changed))
        let advanced = CollectorRootConfiguration(rootID: root.rootID, source: root.source,
            rootPath: root.rootPath, revision: 2, cursorLegacy: true, cursorModernRootID: changed.cursorModernRootID)
        try reopened.registerRoot(advanced)
        XCTAssertEqual(try reopened.rootState(rootID: root.rootID)?.configuration, advanced)
        for invalid in [
            CollectorRootConfiguration(rootID: "bad", source: .codex, rootPath: root.rootPath, revision: 1, cursorLegacy: true),
            CollectorRootConfiguration(rootID: "bad", source: .cursor, rootPath: "/tmp/modern", revision: 1, cursorLegacy: true),
            CollectorRootConfiguration(rootID: "bad", source: .cursor, rootPath: root.rootPath, revision: 1, cursorModernRootID: "modern"),
            CollectorRootConfiguration(rootID: "bad", source: .cursor, rootPath: root.rootPath, revision: 1, cursorLegacy: true, cursorModernRootID: "bad")
        ] { XCTAssertThrowsError(try reopened.registerRoot(invalid)) }
    }

    func testCursorSchemaSixMigrationDefaultsExistingRootsWithoutDroppingDirtyWork() throws {
        let f = try CollectorInventoryTestFixture(); defer { f.remove() }
        let old = try f.openRegistered()
        try old.markDirty(configuration: f.configuration, relativePath: "one.jsonl")
        let db = try f.openDatabase()
        try db.write {
            try $0.execute(sql: "ALTER TABLE collector_roots DROP COLUMN cursor_legacy")
            try $0.execute(sql: "ALTER TABLE collector_roots DROP COLUMN cursor_modern_root_id")
            try $0.execute(sql: "UPDATE collector_metadata SET value = '6' WHERE key = 'publication_schema_version'")
        }
        let reopened = try f.open(owner: "run-2")
        XCTAssertEqual(try reopened.rootState(rootID: f.configuration.rootID)?.configuration, f.configuration)
        XCTAssertEqual(try reopened.locator(configuration: f.configuration, relativePath: "one.jsonl")?.dirtyRevision, 1)
    }

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
                DROP TABLE IF EXISTS collector_cursor_legacy_workspaces;
                DROP TABLE IF EXISTS collector_cursor_legacy_sessions;
                DROP TABLE IF EXISTS collector_publication_replicas;
                DROP TABLE IF EXISTS collector_publications;
                DROP TABLE IF EXISTS collector_capture_reservation_dependencies;
                DROP TABLE IF EXISTS collector_capture_reservations;
                DROP TABLE IF EXISTS collector_streams;
                DROP TABLE IF EXISTS collector_root_bindings;
                DELETE FROM collector_metadata WHERE key = 'publication_schema_version';
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
        XCTAssertEqual(Set(tables), ["collector_metadata", "collector_roots", "collector_locators", "collector_frontier", "collector_root_bindings",
            "collector_streams", "collector_capture_reservations", "collector_capture_reservation_dependencies", "collector_publications", "collector_publication_replicas", "collector_cursor_legacy_sessions", "collector_cursor_legacy_workspaces"])
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

    // RED before / GREEN after for applyBootstrapBatch non-OpenCode files:
    // Setup: scan-1 observes one.jsonl generation "observed-1", finish, ACK;
    //        requestReconciliation; scan-2 observes the same path+generation.
    // RED (old): `if generation == observed, seenScanID == batch.scan.scanID`
    //        → scan-2 upserts dirty; after.dirtyRevision == before.dirtyRevision + 1
    //        and pendingLocators == ["one.jsonl"].
    // GREEN (new): `if generation == observed { touch last_seen; continue }`
    //        → dirtyRevision/acknowledgedRevision/observedGeneration unchanged
    //        and pendingLocators is empty.
    func testUnchangedBootstrapGenerationOnNewScanDoesNotRedirty_repro() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let first = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan-1")
        try store.applyBootstrapBatch(fixture.batch(scan: first, files: [fixture.file("one.jsonl")], finished: true))
        XCTAssertTrue(try store.finishBootstrap(first))
        XCTAssertEqual(try store.acknowledge(fixture.claim(store), captureID: "last-good"), .acknowledged)
        XCTAssertTrue(try store.pendingLocators(configuration: fixture.configuration, limit: 10).isEmpty)
        let before = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))

        try store.requestReconciliation(configuration: fixture.configuration)
        let second = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan-2")
        try store.applyBootstrapBatch(fixture.batch(scan: second, files: [fixture.file("one.jsonl")], finished: true))
        let after = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        XCTAssertEqual(after.dirtyRevision, before.dirtyRevision)
        XCTAssertEqual(after.acknowledgedRevision, before.acknowledgedRevision)
        XCTAssertEqual(after.observedGeneration, before.observedGeneration)
        XCTAssertTrue(
            try store.pendingLocators(configuration: fixture.configuration, limit: 10).isEmpty,
            "unchanged generation on a new scan must not enqueue recapture"
        )
        XCTAssertTrue(try store.finishBootstrap(second))
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

    func testDirectoryBatchEnqueuesTargetedScanWithoutRootFrontierOrRevisionBump() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let before = try watchingReady(store, fixture)
        try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil,
            nextCheckpoint: .init(epoch: "epoch-1", cursor: "dir-1"),
            dirtyRelativePaths: ["newdir/visible.jsonl"], requiresReconciliation: false,
            dirtyRelativeDirectories: ["newdir"]
        )
        let state = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(state.requestedRevision, before.requestedRevision)
        XCTAssertEqual(state.completedRevision, before.completedRevision)
        XCTAssertEqual(state.eventCheckpoint, .init(epoch: "epoch-1", cursor: "dir-1"))
        let scan = try XCTUnwrap(state.activeScan)
        XCTAssertEqual(scan.requestedRevision, before.requestedRevision)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 8), ["newdir"])
        XCTAssertEqual(
            try store.locator(configuration: fixture.configuration, relativePath: "newdir/visible.jsonl")?.relativePath,
            "newdir/visible.jsonl"
        )
        let database = try fixture.openDatabase()
        let dirs = try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT relative_directory FROM collector_frontier
                WHERE root_id = ? AND scan_id = ? ORDER BY relative_directory
                """, arguments: [fixture.configuration.rootID, scan.scanID])
        }
        XCTAssertEqual(dirs, ["newdir"])
        XCTAssertFalse(dirs.contains(""))
        XCTAssertFalse(dirs.contains("sibling"))
    }

    func testTargetedDirectoryScanResumesAfterStoreReopen() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var store: CollectorInventoryStore? = try fixture.openRegistered()
        _ = try watchingReady(store!, fixture)
        try store!.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil,
            nextCheckpoint: .init(epoch: "epoch-1", cursor: "dir-1"),
            dirtyRelativePaths: [], requiresReconciliation: false,
            dirtyRelativeDirectories: ["newdir"]
        )
        let pending = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
        let scan = try XCTUnwrap(pending.activeScan)
        store = nil
        store = try fixture.open(owner: "run-1")
        XCTAssertEqual(try store!.rootState(rootID: fixture.configuration.rootID), pending)
        XCTAssertEqual(try store!.beginBootstrap(configuration: fixture.configuration, scanID: "ignored"), scan)
        XCTAssertEqual(try store!.pendingDirectories(scan: scan, limit: 8), ["newdir"])
        try store!.applyBootstrapBatch(fixture.batch(
            scan: scan, directory: "newdir", files: [fixture.file("newdir/hidden.jsonl")], finished: true
        ))
        XCTAssertTrue(try store!.finishBootstrap(scan))
        let completed = try XCTUnwrap(store!.rootState(rootID: fixture.configuration.rootID))
        XCTAssertNil(completed.activeScan)
        XCTAssertEqual(completed.requestedRevision, pending.requestedRevision)
        XCTAssertEqual(completed.completedRevision, pending.completedRevision)
        XCTAssertEqual(
            try store!.locator(configuration: fixture.configuration, relativePath: "newdir/hidden.jsonl")?.relativePath,
            "newdir/hidden.jsonl"
        )
    }

    func testRepeatedDirectoryEventReopensCompletedFrontierDuringPendingScan() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let before = try watchingReady(store, fixture)
        try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil,
            nextCheckpoint: .init(epoch: "epoch-1", cursor: "dir-1"),
            dirtyRelativePaths: [], requiresReconciliation: false,
            dirtyRelativeDirectories: ["alpha", "zeta"]
        )
        let scan = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID)?.activeScan)
        try store.applyBootstrapBatch(fixture.batch(
            scan: scan, directory: "alpha", files: [fixture.file("alpha/old.jsonl")], finished: true
        ))
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 8), ["zeta"])
        XCTAssertEqual(try frontierCompleted(fixture, scan: scan, directory: "alpha"), 1)
        try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: .init(epoch: "epoch-1", cursor: "dir-1"),
            nextCheckpoint: .init(epoch: "epoch-1", cursor: "dir-2"),
            dirtyRelativePaths: [], requiresReconciliation: false,
            dirtyRelativeDirectories: ["alpha"]
        )
        let after = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(after.requestedRevision, before.requestedRevision)
        XCTAssertEqual(after.completedRevision, before.completedRevision)
        XCTAssertEqual(after.activeScan, scan)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 8), ["alpha", "zeta"])
        XCTAssertEqual(try frontierCompleted(fixture, scan: scan, directory: "alpha"), 0)
        XCTAssertEqual(try frontierCompleted(fixture, scan: scan, directory: "zeta"), 0)
        let database = try fixture.openDatabase()
        let dirs = try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT relative_directory FROM collector_frontier
                WHERE root_id = ? AND scan_id = ? ORDER BY relative_directory
                """, arguments: [fixture.configuration.rootID, scan.scanID])
        }
        XCTAssertEqual(dirs, ["alpha", "zeta"])
        XCTAssertFalse(dirs.contains(""))
    }

    func testTargetedDirectorySeedDuringPendingReconciliationDoesNotCompleteRequestedRevision() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let ready = try watchingReady(store, fixture)
        try store.requestReconciliation(configuration: fixture.configuration)
        let gapped = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertGreaterThan(gapped.requestedRevision, ready.completedRevision)
        try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil,
            nextCheckpoint: .init(epoch: "epoch-1", cursor: "dir-1"),
            dirtyRelativePaths: [], requiresReconciliation: false,
            dirtyRelativeDirectories: ["newdir"]
        )
        let scan = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID)?.activeScan)
        XCTAssertEqual(scan.requestedRevision, gapped.requestedRevision)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 8), ["", "newdir"])
        try store.applyBootstrapBatch(fixture.batch(
            scan: scan, directory: "newdir", files: [fixture.file("newdir/hidden.jsonl")], finished: true
        ))
        XCTAssertFalse(try store.finishBootstrap(scan))
        let afterSubtree = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(afterSubtree.completedRevision, ready.completedRevision)
        XCTAssertEqual(afterSubtree.requestedRevision, gapped.requestedRevision)
        XCTAssertEqual(afterSubtree.activeScan, scan)
        try store.applyBootstrapBatch(fixture.batch(scan: scan, finished: true))
        XCTAssertTrue(try store.finishBootstrap(scan))
        let complete = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertNil(complete.activeScan)
        XCTAssertEqual(complete.requestedRevision, complete.completedRevision)
        XCTAssertEqual(complete.completedRevision, gapped.requestedRevision)
    }

    func testTargetedScanFinishAfterLaterGapDoesNotAdvanceCompletedRevision() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let ready = try watchingReady(store, fixture)
        try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil,
            nextCheckpoint: .init(epoch: "epoch-1", cursor: "dir-1"),
            dirtyRelativePaths: [], requiresReconciliation: false,
            dirtyRelativeDirectories: ["newdir"]
        )
        let scan = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID)?.activeScan)
        try store.requestReconciliation(configuration: fixture.configuration)
        try store.applyBootstrapBatch(fixture.batch(
            scan: scan, directory: "newdir", files: [fixture.file("newdir/hidden.jsonl")], finished: true
        ))
        XCTAssertTrue(try store.finishBootstrap(scan))
        let after = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertNil(after.activeScan)
        XCTAssertEqual(after.completedRevision, ready.completedRevision)
        XCTAssertGreaterThan(after.requestedRevision, after.completedRevision)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 8), [])
    }

    func testBeginBootstrapAddsRootFrontierWhenTargetedScanFacesNewGap() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        _ = try watchingReady(store, fixture)
        try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil,
            nextCheckpoint: .init(epoch: "epoch-1", cursor: "dir-1"),
            dirtyRelativePaths: [], requiresReconciliation: false,
            dirtyRelativeDirectories: ["newdir"]
        )
        let scan = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID)?.activeScan)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 8), ["newdir"])
        try store.requestReconciliation(configuration: fixture.configuration)
        XCTAssertEqual(try store.beginBootstrap(configuration: fixture.configuration, scanID: "ignored"), scan)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 8), ["", "newdir"])
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

    func testDirtyEventClearsSamePathUnavailableRetryBeforeDeadlineAndLeavesUnrelatedPrivacyWithheld_repro() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        try store.markDirty(configuration: fixture.configuration, relativePath: "cold.jsonl")
        try store.markDirty(configuration: fixture.configuration, relativePath: "hot.jsonl")
        let claimed = try store.claimDirty(configuration: fixture.configuration, limit: 8, now: 10)
        XCTAssertEqual(Set(claimed.map(\.relativePath)), ["cold.jsonl", "hot.jsonl"])
        for claim in claimed {
            XCTAssertTrue(try store.deferClaim(claim, retryNotBefore: 1_000, reason: "unavailable"))
        }
        let database = try fixture.openDatabase()
        try fixture.seedPublications(in: database)
        try database.write { db in
            try db.execute(sql: """
                UPDATE collector_publication_replicas SET state = 'pending', attempts = 3,
                    last_error = 'privacyWithheld', retry_not_before = 5_000
                """)
        }
        let withheldBefore = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT replica_id, last_error, retry_not_before, attempts, state
                FROM collector_publication_replicas ORDER BY replica_id
                """)
        }
        XCTAssertEqual(withheldBefore.count, 2)
        XCTAssertTrue(withheldBefore.allSatisfy { row in
            let error: String = row["last_error"]
            let retry: Int64 = row["retry_not_before"]
            return error == "privacyWithheld" && retry == 5_000
        })
        try store.applyEventBatch(
            configuration: fixture.configuration, expectedCheckpoint: nil,
            nextCheckpoint: .init(epoch: "wake-hot", cursor: "1"),
            dirtyRelativePaths: ["hot.jsonl"], requiresReconciliation: false
        )
        let hot = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: "hot.jsonl"))
        XCTAssertNil(hot.retryNotBefore)
        XCTAssertNil(hot.lastError)
        XCTAssertGreaterThan(hot.dirtyRevision, hot.acknowledgedRevision)
        let cold = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: "cold.jsonl"))
        XCTAssertEqual(cold.retryNotBefore, 1_000)
        XCTAssertEqual(cold.lastError, "unavailable")
        let woken = try store.claimDirty(configuration: fixture.configuration, limit: 8, now: 0)
        XCTAssertEqual(woken.map(\.relativePath), ["hot.jsonl"])
        let withheldAfter = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT replica_id, last_error, retry_not_before, attempts, state
                FROM collector_publication_replicas ORDER BY replica_id
                """)
        }
        func replicaFields(_ rows: [Row]) -> [(String, String, Int64, Int64, String)] {
            rows.map { row in
                let replica: String = row["replica_id"]
                let error: String = row["last_error"]
                let retry: Int64 = row["retry_not_before"]
                let attempts: Int64 = row["attempts"]
                let state: String = row["state"]
                return (replica, error, retry, attempts, state)
            }
        }
        XCTAssertEqual(replicaFields(withheldAfter).map(\.0), replicaFields(withheldBefore).map(\.0))
        XCTAssertEqual(replicaFields(withheldAfter).map(\.1), replicaFields(withheldBefore).map(\.1))
        XCTAssertEqual(replicaFields(withheldAfter).map(\.2), replicaFields(withheldBefore).map(\.2))
        XCTAssertEqual(replicaFields(withheldAfter).map(\.3), replicaFields(withheldBefore).map(\.3))
        XCTAssertEqual(replicaFields(withheldAfter).map(\.4), replicaFields(withheldBefore).map(\.4))
    }

    func testSamePathDirtyAfterClaimReleasesWithoutRestoringUnavailableRetry_repro() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        try store.markDirty(configuration: fixture.configuration, relativePath: "hot.jsonl")
        let inflight = try fixture.claim(store)
        XCTAssertEqual(inflight.relativePath, "hot.jsonl")
        try store.markDirty(configuration: fixture.configuration, relativePath: "hot.jsonl")
        let afterEvent = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: "hot.jsonl"))
        XCTAssertGreaterThan(afterEvent.dirtyRevision, inflight.dirtyRevision)
        XCTAssertNil(afterEvent.retryNotBefore)
        XCTAssertTrue(try store.deferClaim(inflight, retryNotBefore: 1_000, reason: "unavailable"))
        let released = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: "hot.jsonl"))
        XCTAssertNil(released.retryNotBefore)
        XCTAssertNil(released.lastError)
        XCTAssertGreaterThan(released.dirtyRevision, released.acknowledgedRevision)
        let due = try store.claimDirty(configuration: fixture.configuration, limit: 8, now: 0)
        XCTAssertEqual(due.map(\.relativePath), ["hot.jsonl"])
        XCTAssertEqual(due.first?.dirtyRevision, afterEvent.dirtyRevision)
    }

    func testDeferClaimsBatchOneWriteKeepsPerRowFreshnessAndStale_repro() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var commits = 0
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: { commits += 1 }))
        try store.markDirty(configuration: fixture.configuration, relativePath: "cold.jsonl")
        try store.markDirty(configuration: fixture.configuration, relativePath: "hot.jsonl")
        let claimed = try store.claimDirty(configuration: fixture.configuration, limit: 8, now: 10)
        XCTAssertEqual(Set(claimed.map(\.relativePath)), ["cold.jsonl", "hot.jsonl"])
        commits = 0
        let stale = CollectorDirtyClaim(
            rootID: claimed[0].rootID, rootRevision: claimed[0].rootRevision,
            relativePath: claimed[0].relativePath, dirtyRevision: claimed[0].dirtyRevision,
            ownerRunID: claimed[0].ownerRunID, claimGeneration: claimed[0].claimGeneration + 1)
        let results = try store.deferClaims([
            (claim: claimed[0], retryNotBefore: 60, reason: "unavailable"),
            (claim: stale, retryNotBefore: 1, reason: "unavailable"),
            (claim: claimed[1], retryNotBefore: 1, reason: "unavailable"),
        ])
        XCTAssertEqual(results, [true, false, true])
        XCTAssertEqual(commits, 1)
        let cold = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: claimed[0].relativePath))
        let hot = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: claimed[1].relativePath))
        XCTAssertEqual(cold.retryNotBefore, 60)
        XCTAssertEqual(hot.retryNotBefore, 1)
        let inflight = try XCTUnwrap(
            try store.claimDirty(configuration: fixture.configuration, limit: 8, now: 10)
                .first { $0.relativePath.utf8.elementsEqual(claimed[1].relativePath.utf8) })
        try store.markDirty(configuration: fixture.configuration, relativePath: inflight.relativePath)
        let afterEvent = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: inflight.relativePath))
        XCTAssertGreaterThan(afterEvent.dirtyRevision, inflight.dirtyRevision)
        commits = 0
        XCTAssertEqual(try store.deferClaims([
            (claim: inflight, retryNotBefore: 1_000, reason: "unavailable"),
        ]), [true])
        XCTAssertEqual(commits, 1)
        let woken = try XCTUnwrap(store.locator(configuration: fixture.configuration, relativePath: claimed[1].relativePath))
        XCTAssertNil(woken.retryNotBefore)
        XCTAssertNil(woken.lastError)
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

    private func frontierCompleted(
        _ fixture: CollectorInventoryTestFixture, scan: CollectorScanToken, directory: String
    ) throws -> Int {
        let database = try fixture.openDatabase()
        return try XCTUnwrap(database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT completed FROM collector_frontier
                WHERE root_id = ? AND scan_id = ? AND relative_directory = ?
                """, arguments: [fixture.configuration.rootID, scan.scanID, directory])
        })
    }

    private func watchingReady(
        _ store: CollectorInventoryStore, _ fixture: CollectorInventoryTestFixture
    ) throws -> CollectorRootState {
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "ready")
        try store.applyBootstrapBatch(fixture.batch(scan: scan, finished: true))
        XCTAssertTrue(try store.finishBootstrap(scan))
        let state = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(state.requestedRevision, state.completedRevision)
        XCTAssertNil(state.activeScan)
        return state
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
    private let prefix: String

    init(prefix: String = "select * from collector_locators ") { self.prefix = prefix }

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
            guard sql.hasPrefix(prefix) else { return }
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

extension CollectorInventoryStoreTests {
    func testDrainedClaimQueuesAndZeroDirtyBudgetDoNotCommit() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var commits = 0
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: { commits += 1 }))
        let database = try fixture.openDatabase()
        let before = try fixture.claimSnapshot(in: database)
        commits = 0
        for _ in 0..<5 {
            XCTAssertTrue(try store.claimDirty(configuration: fixture.configuration, limit: 1, now: 10).isEmpty)
            for replica in ["hq", "m1"] {
                XCTAssertTrue(try store.claimPublications(replicaID: replica, limit: 1, now: 10).isEmpty)
            }
        }
        XCTAssertEqual(commits, 0, "fully idle claims must not enter the write transaction fence")
        XCTAssertEqual(try fixture.claimSnapshot(in: database), before)

        try store.markDirty(configuration: fixture.configuration, relativePath: "ready.jsonl")
        let pending = try fixture.claimSnapshot(in: database)
        commits = 0
        XCTAssertTrue(try store.claimDirty(configuration: fixture.configuration, limit: 0, now: 10).isEmpty)
        XCTAssertEqual(commits, 0, "a zero dirty budget validates the root without advancing its cursor")
        XCTAssertEqual(try fixture.claimSnapshot(in: database), pending)
    }

    func testDrainedLargeQueuesUseBoundedNonVacuousAvailabilityQueries() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let database = try fixture.openDatabase()
        var commits = 0
        let store = try CollectorInventoryStore(database: database, machineID: fixture.machineID,
            ownerRunID: "run-1", testHooks: .init(beforeCommit: { commits += 1 }))
        try store.registerRoot(fixture.configuration)
        let count = 2_048
        try fixture.seedPublications(in: database, count: count, acknowledgedReplicas: ["hq", "m1"])
        try database.write { db in
            for index in 0..<count {
                try db.execute(sql: """
                    INSERT INTO collector_locators(root_id, root_revision, relative_path,
                        dirty_revision, acknowledged_revision, claim_generation)
                    VALUES (?, ?, ?, 1, 1, 0)
                    """, arguments: [fixture.configuration.rootID, fixture.configuration.revision, "acked-\(index).jsonl"])
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM collector_locators"), count)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 2 * count)
        }
        let before = try fixture.claimSnapshot(in: database)
        let trace = CollectorCandidateQueryTrace(prefix: "select 1 from collector_")
        try database.writeWithoutTransaction { try trace.install(on: $0) }
        defer { database.writeWithoutTransaction { trace.uninstall(from: $0) } }
        commits = 0
        for _ in 0..<3 {
            trace.reset()
            XCTAssertTrue(try store.claimDirty(configuration: fixture.configuration, limit: 7, now: 10).isEmpty)
            XCTAssertTrue(try store.claimPublications(replicaID: "hq", limit: 7, now: 10).isEmpty)
            XCTAssertTrue(try store.claimPublications(replicaID: "m1", limit: 7, now: 10).isEmpty)
            let queries = trace.queries
            XCTAssertEqual(queries.count, 3, "observe each real probe; absent SQL must not pass vacuously")
            XCTAssertEqual(queries.filter { $0.sql.hasPrefix("select 1 from collector_locators ") }.count, 1)
            XCTAssertEqual(queries.filter { $0.sql.hasPrefix("select 1 from collector_publication_replicas ") }.count, 2)
            for query in queries {
                XCTAssertTrue(query.profiled)
                XCTAssertGreaterThan(query.vmSteps, 0)
                XCTAssertLessThanOrEqual(query.vmSteps, 128, "fixed bound independent of the 2,048-row queue")
                XCTAssertEqual(query.rows, 0)
                XCTAssertEqual(query.fullScanSteps, 0)
                XCTAssertEqual(query.sorts, 0)
                XCTAssertTrue(query.sql.hasSuffix(" limit 1"))
                XCTAssertFalse(query.sql.contains(" join "))
                XCTAssertFalse(query.sql.contains("retry_not_before"))
                XCTAssertFalse(query.sql.contains("claim_owner_run_id"))
                if query.sql.hasPrefix("select 1 from collector_locators ") {
                    XCTAssertTrue(query.sql.contains("root_id = ?"))
                    XCTAssertTrue(query.sql.contains("root_revision = ?"))
                    XCTAssertTrue(query.sql.contains("dirty_revision > acknowledged_revision"))
                } else {
                    XCTAssertTrue(query.sql.contains("replica_id = ?"))
                    XCTAssertTrue(query.sql.contains("state != 'acknowledged'"))
                }
            }
        }
        XCTAssertEqual(commits, 0)
        trace.uninstallSafely(database)
        XCTAssertEqual(try fixture.claimSnapshot(in: database), before)
    }

    func testUnacknowledgedDirtyProbeIncludesDeferredInFlightAndSkipsAckedWithoutCommit_repro() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let database = try fixture.openDatabase()
        var commits = 0
        let store = try CollectorInventoryStore(
            database: database, machineID: fixture.machineID, ownerRunID: "run-1",
            testHooks: .init(beforeCommit: { commits += 1 }))
        func configuration(_ rootID: String) -> CollectorRootConfiguration {
            CollectorRootConfiguration(
                rootID: rootID, source: .codex,
                rootPath: fixture.root.appendingPathComponent(rootID).path, revision: 1)
        }
        let empty = configuration("empty-root")
        let deferred = configuration("deferred-root")
        let inflight = configuration("inflight-root")
        let acked = configuration("acked-root")
        let large = configuration("large-acked-root")
        for root in [empty, deferred, inflight, acked, large] {
            try store.registerRoot(root)
        }
        try store.markDirty(configuration: deferred, relativePath: "deferred.jsonl")
        let deferredClaim = try XCTUnwrap(store.claimDirty(configuration: deferred, limit: 1, now: 10).first)
        XCTAssertTrue(try store.deferClaim(deferredClaim, retryNotBefore: 1_000, reason: "deferred"))
        try store.markDirty(configuration: inflight, relativePath: "inflight.jsonl")
        XCTAssertEqual(try store.claimDirty(configuration: inflight, limit: 1, now: 10).count, 1)
        try store.markDirty(configuration: acked, relativePath: "acked.jsonl")
        try database.write { db in
            try db.execute(sql: """
                UPDATE collector_locators SET acknowledged_revision = dirty_revision WHERE root_id = ?
                """, arguments: [acked.rootID])
            for index in 0..<2_048 {
                try db.execute(sql: """
                    INSERT INTO collector_locators(root_id, root_revision, relative_path,
                        dirty_revision, acknowledged_revision, claim_generation)
                    VALUES (?, ?, ?, 1, 1, 0)
                    """, arguments: [large.rootID, large.revision, String(format: "acked-%04d.jsonl", index)])
            }
        }
        let trace = CollectorCandidateQueryTrace(prefix: "select 1 from collector_locators ")
        try database.writeWithoutTransaction { try trace.install(on: $0) }
        defer { database.writeWithoutTransaction { trace.uninstall(from: $0) } }
        commits = 0
        let pending = try store.rootsWithUnacknowledgedDirty([empty, deferred, inflight, acked, large])
        XCTAssertEqual(pending, Set([Data(deferred.rootID.utf8), Data(inflight.rootID.utf8)]))
        XCTAssertEqual(commits, 0)
        let queries = trace.queries
        XCTAssertEqual(queries.count, 5, "one indexed LIMIT 1 probe per enrolled root")
        for query in queries {
            XCTAssertTrue(query.profiled)
            XCTAssertGreaterThan(query.vmSteps, 0)
            XCTAssertLessThanOrEqual(query.vmSteps, 128)
            XCTAssertEqual(query.fullScanSteps, 0)
            XCTAssertEqual(query.sorts, 0)
            XCTAssertTrue(query.sql.contains("indexed by collector_pending_locators"))
            XCTAssertTrue(query.sql.contains("root_id = ?"))
            XCTAssertTrue(query.sql.contains("root_revision = ?"))
            XCTAssertTrue(query.sql.contains("dirty_revision > acknowledged_revision"))
            XCTAssertTrue(query.sql.hasSuffix(" limit 1"))
            XCTAssertFalse(query.sql.contains("retry_not_before"))
            XCTAssertFalse(query.sql.contains("claim_cursor"))
            XCTAssertFalse(query.sql.contains("claim_owner_run_id"))
        }
        XCTAssertLessThanOrEqual(queries.reduce(0) { $0 + $1.vmSteps }, 128)
        XCTAssertEqual(queries.reduce(0) { $0 + $1.fullScanSteps }, 0)
        trace.uninstallSafely(database)
    }

    func testDirtyAvailabilityProbeKeepsDeferredAndInFlightCursorTransactions() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var commits = 0
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: { commits += 1 }))
        let database = try fixture.openDatabase()
        for path in ["a-busy.jsonl", "b-deferred.jsonl"] {
            try store.markDirty(configuration: fixture.configuration, relativePath: path)
        }
        let claims = try store.claimDirty(configuration: fixture.configuration, limit: 2, now: 10)
        XCTAssertEqual(claims.count, 2)
        let deferred = try XCTUnwrap(claims.last)
        XCTAssertTrue(try store.deferClaim(deferred, retryNotBefore: 1_000, reason: "deferred"))
        let busyBefore = try store.locator(configuration: fixture.configuration, relativePath: "a-busy.jsonl")
        let deferredBefore = try store.locator(configuration: fixture.configuration, relativePath: "b-deferred.jsonl")
        commits = 0
        for (index, expectedCursor) in ["a-busy.jsonl", "b-deferred.jsonl"].enumerated() {
            XCTAssertTrue(try store.claimDirty(configuration: fixture.configuration, limit: 1, now: 10).isEmpty)
            XCTAssertEqual(commits, index + 1, "an empty selection is not an empty dirty queue")
            XCTAssertEqual(try database.read {
                try String.fetchOne($0, sql: "SELECT claim_cursor FROM collector_roots WHERE root_id = ?",
                    arguments: [fixture.configuration.rootID])
            }, expectedCursor)
        }
        XCTAssertEqual(try store.locator(configuration: fixture.configuration, relativePath: "a-busy.jsonl"), busyBefore)
        XCTAssertEqual(try store.locator(configuration: fixture.configuration, relativePath: "b-deferred.jsonl"), deferredBefore)
    }

    func testPublicationAvailabilityProbeKeepsNonAcknowledgedTransactionsAndReplicaIsolation() throws {
        for scenario in ["future-retry", "own-inflight", "old-root-revision"] {
            let fixture = try CollectorInventoryTestFixture()
            defer { fixture.remove() }
            var commits = 0
            let store = try fixture.openRegistered(hooks: .init(beforeCommit: { commits += 1 }))
            let database = try fixture.openDatabase()
            try fixture.seedPublications(in: database)
            if scenario == "old-root-revision" {
                try store.registerRoot(fixture.configuration(revision: 2))
            } else {
                let claim = try XCTUnwrap(store.claimPublications(replicaID: "hq", limit: 1, now: 10).first)
                if scenario == "future-retry" {
                    XCTAssertTrue(try store.deferPublication(claim, now: 10, reason: .unavailable))
                }
            }
            let before = try fixture.claimSnapshot(in: database)
            commits = 0
            XCTAssertTrue(try store.claimPublications(replicaID: "hq", limit: 1, now: 10).isEmpty, scenario)
            XCTAssertEqual(commits, 1, "any non-ACK row must keep the original selection transaction: \(scenario)")
            XCTAssertEqual(try fixture.claimSnapshot(in: database), before, scenario)
        }

        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var commits = 0
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: { commits += 1 }))
        let database = try fixture.openDatabase()
        try fixture.seedPublications(in: database, acknowledgedReplicas: ["hq"])
        commits = 0
        XCTAssertTrue(try store.claimPublications(replicaID: "hq", limit: 1, now: 10).isEmpty)
        XCTAssertEqual(commits, 0, "another replica's pending work cannot force an HQ write")
        XCTAssertEqual(try store.claimPublications(replicaID: "m1", limit: 1, now: 10).count, 1)
        XCTAssertEqual(commits, 1, "M1 must still select its pending publication")
    }

    // Live claimPublications still entered the write transaction for future
    // retries and SCAN'd acknowledged history (collector-claim-partial-predicate-diagnostic.json).
    func testClaimSelectionOverAcknowledgedHistoryPlusFutureRetryStaysBounded_repro() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let database = try fixture.openDatabase()
        let store = try CollectorInventoryStore(database: database, machineID: fixture.machineID, ownerRunID: "run-1")
        try store.registerRoot(fixture.configuration)
        let acknowledged = 2_048
        let futureRetries = 8
        try fixture.seedPublications(in: database, count: acknowledged + futureRetries, acknowledgedReplicas: ["hq"])
        try database.write { db in
            try db.execute(sql: """
                UPDATE collector_publication_replicas SET state = 'pending', ack_bytes = NULL,
                    attempts = 1, last_error = 'unavailable', retry_not_before = 1000
                WHERE replica_id = 'hq' AND publication_digest IN (
                    SELECT publication_digest FROM collector_publications
                    WHERE root_id = ? AND sequence > ?
                )
                """, arguments: [fixture.configuration.rootID, acknowledged])
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM collector_publication_replicas
                WHERE replica_id = 'hq' AND state = 'acknowledged'
                """), acknowledged)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM collector_publication_replicas
                WHERE replica_id = 'hq' AND state = 'pending' AND retry_not_before = 1000
                """), futureRetries)
        }
        let trace = CollectorCandidateQueryTrace(
            prefix: "select p.*, r.claim_generation, r.attempts from collector_publication_replicas r")
        try database.writeWithoutTransaction { try trace.install(on: $0) }
        defer { database.writeWithoutTransaction { trace.uninstall(from: $0) } }
        XCTAssertTrue(try store.claimPublications(replicaID: "hq", limit: 7, now: 10).isEmpty,
            "future retries must not be due before retry_not_before")
        let queries = trace.queries
        XCTAssertEqual(queries.count, 1, "observe the real claim selection; absent SQL must not pass vacuously")
        let query = try XCTUnwrap(queries.first)
        XCTAssertTrue(query.profiled)
        XCTAssertEqual(query.rows, 0)
        XCTAssertGreaterThan(query.vmSteps, 0)
        XCTAssertLessThanOrEqual(query.vmSteps, 1_024, "fixed bound independent of the 2,048 acknowledged rows")
        XCTAssertEqual(query.fullScanSteps, 0)
        XCTAssertTrue(query.sql.contains("r.replica_id = ?"))
        XCTAssertTrue(query.sql.contains("r.state != 'acknowledged'"))
        trace.uninstallSafely(database)
        let retries = try store.claimPublications(replicaID: "hq", limit: futureRetries, now: 1_000)
        XCTAssertEqual(retries.count, futureRetries)
        XCTAssertTrue(retries.allSatisfy { $0.attempts == 1 })
        XCTAssertEqual(retries.map(\.intent.publication.sequence),
            (Int64(acknowledged + 1)...Int64(acknowledged + futureRetries)).map { $0 })
    }

    // Retryable history must leave upload slots for new publications.
    func testNeverAttemptedPublicationsClaimBeforeReadyRetries_repro() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let database = try fixture.openDatabase()
        try fixture.seedPublications(in: database, count: 4)
        try database.write { db in
            try db.execute(sql: """
                UPDATE collector_publication_replicas SET attempts = 1, last_error = 'privacyWithheld', retry_not_before = 1
                WHERE replica_id = 'hq' AND publication_digest IN (
                    SELECT publication_digest FROM collector_publications
                    WHERE root_id = ? AND sequence IN (1, 2)
                )
                """, arguments: [fixture.configuration.rootID])
        }
        let claims = try store.claimPublications(replicaID: "hq", limit: 2, now: 10)
        XCTAssertEqual(claims.map(\.intent.publication.sequence), [3, 4])
        XCTAssertTrue(claims.allSatisfy { $0.attempts == 0 })
        let retries = try store.claimPublications(replicaID: "hq", limit: 2, now: 10)
        XCTAssertEqual(retries.map(\.intent.publication.sequence), [1, 2])
        XCTAssertTrue(retries.allSatisfy { $0.attempts == 1 })
    }

    // A later root's never-attempted backlog must share claimPublications
    // slots while the lexicographic first root still has pending work.
    func testNeverAttemptedRootPublicationsShareClaimBudgetWithoutDrainingFirstRoot_repro() throws {
        for limit in [1, 2] {
            let fixture = try CollectorInventoryTestFixture()
            defer { fixture.remove() }
            let store = try fixture.open()
            let claude = CollectorRootConfiguration(
                rootID: "claude-root", source: .claudeCode,
                rootPath: fixture.root.appendingPathComponent("claude").path, revision: 1)
            let codex = CollectorRootConfiguration(
                rootID: "codex-root", source: .codex,
                rootPath: fixture.root.appendingPathComponent("codex").path, revision: 1)
            XCTAssertLessThan(claude.rootID, codex.rootID)
            try store.registerRoot(codex)
            try store.registerRoot(claude)
            let database = try fixture.openDatabase()
            let perRoot = 6
            try fixture.seedPublications(in: database, configuration: claude, count: perRoot,
                sourceInstanceID: "44444444-5555-6666-7777-888888888888",
                collectorEpoch: "55555555-6666-7777-8888-999999999999")
            try fixture.seedPublications(in: database, configuration: codex, count: perRoot,
                sourceInstanceID: "66666666-7777-8888-9999-000000000000",
                collectorEpoch: "77777777-8888-9999-0000-111111111111")
            var seen = Set<String>()
            var claimedFromFirst = 0
            for _ in 1...2 {
                let claims = try store.claimPublications(replicaID: "hq", limit: limit, now: 10)
                XCTAssertEqual(claims.count, limit, "limit=\(limit) must fill the claim budget")
                XCTAssertTrue(claims.allSatisfy { $0.attempts == 0 }, "limit=\(limit)")
                seen.formUnion(claims.map(\.intent.rootID))
                claimedFromFirst += claims.filter { $0.intent.rootID == claude.rootID }.count
            }
            XCTAssertEqual(seen, Set([claude.rootID, codex.rootID]),
                "limit=\(limit): both roots must appear across two claims")
            XCTAssertLessThan(claimedFromFirst, perRoot,
                "limit=\(limit): first-root backlog must still have unclaimed publications")
            XCTAssertGreaterThan(
                try fixture.pendingPublicationCount(in: database, replicaID: "hq", rootID: claude.rootID), 0,
                "limit=\(limit): Claude remaining pending after mixed claims")
            XCTAssertGreaterThan(
                try fixture.pendingPublicationCount(in: database, replicaID: "hq", rootID: codex.rootID), 0,
                "limit=\(limit): Codex remaining pending after mixed claims")
        }
    }

    func testEmptyClaimFastPathsStillRejectStaleOwnersRootsAndInvalidArguments() throws {
        for owners in [["run-é", "run-e\u{301}"], ["run-e\u{301}", "run-é"]] {
            let fixture = try CollectorInventoryTestFixture()
            defer { fixture.remove() }
            var commits = 0
            let old = try fixture.openRegistered(owner: owners[0], hooks: .init(beforeCommit: { commits += 1 }))
            let current = try fixture.open(owner: owners[1])
            commits = 0
            for limit in [0, 1] {
                XCTAssertThrowsError(try old.claimDirty(configuration: fixture.configuration, limit: limit, now: 10)) {
                    XCTAssertEqual($0 as? CollectorInventoryError, .staleOwner)
                }
            }
            for replica in ["hq", "m1"] {
                XCTAssertThrowsError(try old.claimPublications(replicaID: replica, limit: 1, now: 10)) {
                    XCTAssertEqual($0 as? CollectorInventoryError, .staleOwner)
                }
            }
            XCTAssertEqual(commits, 0)
            withExtendedLifetime(current) {}
        }

        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var commits = 0
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: { commits += 1 }))
        let missing = CollectorRootConfiguration(rootID: "missing", source: .codex, rootPath: fixture.root.path, revision: 1)
        for configuration in [missing, fixture.configuration(revision: 2)] {
            for limit in [0, 1] {
                XCTAssertThrowsError(try store.claimDirty(configuration: configuration, limit: limit, now: 10)) {
                    XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
                }
            }
        }
        try store.registerRoot(fixture.configuration(revision: 2))
        commits = 0
        for limit in [0, 1] {
            XCTAssertThrowsError(try store.claimDirty(configuration: fixture.configuration, limit: limit, now: 10)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .unknownRoot)
            }
        }
        XCTAssertThrowsError(try store.claimDirty(configuration: fixture.configuration(revision: 2), limit: -1, now: 10)) {
            XCTAssertEqual($0 as? CollectorInventoryError, .invalidBudget)
        }
        for limit in [-1, 0, 65] {
            XCTAssertThrowsError(try store.claimPublications(replicaID: "hq", limit: limit, now: 10)) {
                XCTAssertEqual($0 as? CollectorPublicationWorkerError, .invalidBudget)
            }
        }
        for replica in ["HQ", "unknown"] {
            XCTAssertThrowsError(try store.claimPublications(replicaID: replica, limit: 1, now: 10)) {
                XCTAssertEqual($0 as? CollectorPublicationWorkerError, .invalidBudget)
            }
        }
        XCTAssertThrowsError(try store.claimPublications(replicaID: "hq", limit: 1, now: -1)) {
            XCTAssertEqual($0 as? CollectorPublicationWorkerError, .invalidBudget)
        }
        XCTAssertEqual(commits, 0)
    }

    func testCancelledEmptyClaimsNeverCommit() async throws {
        let task = Task {
            let fixture = try CollectorInventoryTestFixture()
            defer { fixture.remove() }
            var commits = 0
            let store = try fixture.openRegistered(hooks: .init(beforeCommit: { commits += 1 }))
            commits = 0
            withUnsafeCurrentTask { $0?.cancel() }
            for limit in [0, 1] {
                XCTAssertThrowsError(try store.claimDirty(configuration: fixture.configuration, limit: limit, now: 10)) {
                    XCTAssertTrue($0 is CancellationError)
                }
            }
            for replica in ["hq", "m1"] {
                XCTAssertThrowsError(try store.claimPublications(replicaID: replica, limit: 1, now: 10)) {
                    XCTAssertTrue($0 is CancellationError)
                }
            }
            XCTAssertEqual(commits, 0)
        }
        try await task.value
    }

    func testNonemptyClaimTransactionsStillRollbackAtCommitFence() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var shouldFail = false
        var commits = 0
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: {
            commits += 1
            if shouldFail { throw CollectorInventoryInjectedFailure.beforeCommit }
        }))
        let database = try fixture.openDatabase()
        try store.markDirty(configuration: fixture.configuration, relativePath: "ready.jsonl")
        try fixture.seedPublications(in: database)
        let before = try fixture.claimSnapshot(in: database)
        commits = 0
        shouldFail = true
        XCTAssertThrowsError(try store.claimDirty(configuration: fixture.configuration, limit: 1, now: 10)) {
            XCTAssertEqual($0 as? CollectorInventoryInjectedFailure, .beforeCommit)
        }
        XCTAssertEqual(try fixture.claimSnapshot(in: database), before)
        for replica in ["hq", "m1"] {
            XCTAssertThrowsError(try store.claimPublications(replicaID: replica, limit: 1, now: 10)) {
                XCTAssertEqual($0 as? CollectorInventoryInjectedFailure, .beforeCommit)
            }
            XCTAssertEqual(try fixture.claimSnapshot(in: database), before)
        }
        XCTAssertEqual(commits, 3, "all nonempty paths must reach the original commit fence")
        shouldFail = false
        XCTAssertEqual(try store.claimDirty(configuration: fixture.configuration, limit: 1, now: 10).count, 1)
        for replica in ["hq", "m1"] {
            XCTAssertEqual(try store.claimPublications(replicaID: replica, limit: 1, now: 10).count, 1)
        }
    }
}

private extension CollectorInventoryTestFixture {
    // Pure Store rows, not capture/replica runtime evidence. Real canonical
    // envelopes and ACKs keep selection and state checks meaningful.
    func seedPublications(
        in database: DatabaseQueue, count: Int = 1, acknowledgedReplicas: Set<String> = []
    ) throws {
        let sourceInstance = "22222222-3333-4444-5555-666666666666"
        let epoch = "33333333-4444-5555-6666-777777777777"
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO collector_streams(root_id, root_revision, effective_source, source_instance_id, collector_epoch, last_sequence)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [configuration.rootID, configuration.revision, configuration.source.rawValue, sourceInstance, epoch, count])
            for index in 1...count {
                let publication = try CollectorPublicationEnvelope(machineID: machineID,
                    sourceInstanceID: sourceInstance, collectorEpoch: epoch, sequence: Int64(index),
                    manifestSHA256: ArchiveV2Hash.sha256(Data("manifest-\(index)".utf8)))
                let bytes = try ArchiveCanonicalJSON.encode(publication)
                let digest = ArchiveV2Hash.sha256(bytes)
                let intent = CollectorPublicationIntent(captureID: ArchiveV2Hash.sha256(Data("capture-\(index)".utf8)),
                    rootID: configuration.rootID, rootRevision: configuration.revision,
                    relativePath: "publication-\(index).jsonl", publication: publication, canonicalBytes: bytes, digest: digest)
                try db.execute(sql: """
                    INSERT INTO collector_publications(publication_digest, capture_id, root_id, root_revision, relative_path,
                        source_instance_id, collector_epoch, sequence, manifest_sha256, canonical_bytes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [digest, intent.captureID, intent.rootID, intent.rootRevision, intent.relativePath,
                        sourceInstance, epoch, publication.sequence, publication.manifestSHA256, bytes])
                for replica in ["hq", "m1"] {
                    var ackBytes: Data?
                    if acknowledgedReplicas.contains(replica) {
                        let ack = try CollectorPublicationACK(serverID: replica,
                            journalID: "44444444-5555-6666-7777-888888888888", arrivalOrdinal: Int64(index),
                            publicationSHA256: digest, manifestSHA256: publication.manifestSHA256,
                            storedAt: "2026-09-07T00:00:00.000Z")
                        try ack.validate(against: publication, expectedServerID: replica)
                        ackBytes = try ArchiveCanonicalJSON.encode(ack)
                    }
                    try db.execute(sql: """
                        INSERT INTO collector_publication_replicas(publication_digest, replica_id, state,
                            claim_generation, attempts, ack_bytes) VALUES (?, ?, ?, 0, 0, ?)
                        """, arguments: [digest, replica, ackBytes == nil ? "pending" : "acknowledged", ackBytes])
                }
            }
        }
    }

    func seedPublications(
        in database: DatabaseQueue,
        configuration: CollectorRootConfiguration,
        count: Int,
        sourceInstanceID: String,
        collectorEpoch: String
    ) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO collector_streams(root_id, root_revision, effective_source, source_instance_id, collector_epoch, last_sequence)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [configuration.rootID, configuration.revision, configuration.source.rawValue,
                    sourceInstanceID, collectorEpoch, count])
            for index in 1...count {
                let publication = try CollectorPublicationEnvelope(machineID: machineID,
                    sourceInstanceID: sourceInstanceID, collectorEpoch: collectorEpoch, sequence: Int64(index),
                    manifestSHA256: ArchiveV2Hash.sha256(Data("manifest-\(configuration.rootID)-\(index)".utf8)))
                let bytes = try ArchiveCanonicalJSON.encode(publication)
                let digest = ArchiveV2Hash.sha256(bytes)
                let intent = CollectorPublicationIntent(
                    captureID: ArchiveV2Hash.sha256(Data("capture-\(configuration.rootID)-\(index)".utf8)),
                    rootID: configuration.rootID, rootRevision: configuration.revision,
                    relativePath: "\(configuration.rootID)-publication-\(index).jsonl",
                    publication: publication, canonicalBytes: bytes, digest: digest)
                try db.execute(sql: """
                    INSERT INTO collector_publications(publication_digest, capture_id, root_id, root_revision, relative_path,
                        source_instance_id, collector_epoch, sequence, manifest_sha256, canonical_bytes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [digest, intent.captureID, intent.rootID, intent.rootRevision, intent.relativePath,
                        sourceInstanceID, collectorEpoch, publication.sequence, publication.manifestSHA256, bytes])
                for replica in ["hq", "m1"] {
                    try db.execute(sql: """
                        INSERT INTO collector_publication_replicas(publication_digest, replica_id, state,
                            claim_generation, attempts, ack_bytes) VALUES (?, ?, ?, 0, 0, NULL)
                        """, arguments: [digest, replica, "pending"])
                }
            }
        }
    }

    func pendingPublicationCount(in database: DatabaseQueue, replicaID: String, rootID: String) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM collector_publication_replicas r
                JOIN collector_publications p ON p.publication_digest = r.publication_digest
                WHERE r.replica_id = ? AND r.state = 'pending' AND p.root_id = ?
                """, arguments: [replicaID, rootID]) ?? 0
        }
    }

    func claimSnapshot(in database: DatabaseQueue) throws -> [[Row]] {
        try database.read { db in
            try [
                Row.fetchAll(db, sql: "SELECT * FROM collector_roots ORDER BY root_id"),
                Row.fetchAll(db, sql: "SELECT * FROM collector_locators ORDER BY root_id, root_revision, relative_path"),
                Row.fetchAll(db, sql: "SELECT * FROM collector_publication_replicas ORDER BY publication_digest, replica_id"),
            ]
        }
    }
}

extension CollectorInventoryStoreTests {
    func testCursorLegacyPublicationAndPageAdvanceRollBackTogether() throws {
        let f = try CursorLegacyWalkTestFixture()
        defer { f.remove() }
        var fail = false
        let store = try f.open(hooks: .init(beforeCommit: {
            if fail { throw CollectorInventoryInjectedFailure.beforeCommit }
        }))
        let claim = try f.dirtyClaim(store)
        _ = try store.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context("ses-A")
        let reservation = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: context))
        let capture = try f.capture(context)
        fail = true
        XCTAssertThrowsError(try store.finishCapture(reservation, capture: capture.capture))
        fail = false
        XCTAssertEqual(try store.captureReservations(limit: 8), [reservation])
        XCTAssertTrue(try store.publicationIntents(limit: 8).isEmpty)
        XCTAssertNil(try store.lastCursorLegacyCapture(configuration: f.configuration, composerID: context.composerID))
        XCTAssertNil(try store.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal))
        _ = try store.finishCapture(reservation, capture: capture.capture)
        XCTAssertEqual(try store.lastCursorLegacyCapture(configuration: f.configuration, composerID: context.composerID), capture.capture.captureID)
        XCTAssertEqual(try store.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), "ses-A")
    }

    func testCursorLegacyObserverPersistsPagesAndDetectsOwnershipOrPeerChanges() throws {
        let f = try CollectorInventoryTestFixture(); defer { f.remove() }
        let root = CollectorRootConfiguration(rootID: "observed", source: .cursor,
            rootPath: "/tmp/observed/User/globalStorage", revision: 1, cursorLegacy: true)
        let member = String(repeating: "a", count: 64), main = String(repeating: "b", count: 64)
        let peer = String(repeating: "c", count: 64), original = String(repeating: "d", count: 64)
        var store = try f.open()
        try store.registerRoot(root)
        func page(_ after: String?, _ id: String, _ fingerprint: String, next: String?, peerHash: String? = nil) throws -> Bool {
            try store.applyCursorLegacyObservation(configuration: root, after: after,
                membershipFingerprint: member, workspaces: [(id, fingerprint)], nextAfter: next,
                mainFingerprint: main, peerFingerprint: peerHash ?? peer)
        }
        XCTAssertTrue(try page(nil, "a", original, next: "a"))
        XCTAssertEqual(try store.cursorLegacyOwnershipAfter(configuration: root), "a")
        XCTAssertFalse(try page(nil, "b", original, next: nil), "stale page must not advance or overwrite the current cursor")
        store = try f.open(owner: "run-2")
        XCTAssertEqual(try store.cursorLegacyOwnershipAfter(configuration: root), "a")
        XCTAssertTrue(try page("a", "b", original, next: nil))
        let first = try XCTUnwrap(store.claimDirty(configuration: root, limit: 1, now: 10).first)
        _ = try store.acknowledge(first, captureID: "fixture-capture")
        let baseline = try XCTUnwrap(store.locator(configuration: root, relativePath: "state.vscdb"))
        XCTAssertTrue(try page(nil, "a", original, next: "a"))
        XCTAssertTrue(try page("a", "b", original, next: nil))
        XCTAssertEqual(try store.locator(configuration: root, relativePath: "state.vscdb")?.dirtyRevision, baseline.dirtyRevision)
        XCTAssertTrue(try page(nil, "a", String(repeating: "e", count: 64), next: "a"))
        XCTAssertEqual(try store.locator(configuration: root, relativePath: "state.vscdb")?.dirtyRevision, baseline.dirtyRevision + 1)
        XCTAssertTrue(try page("a", "b", original, next: nil, peerHash: String(repeating: "f", count: 64)))
        XCTAssertEqual(try store.locator(configuration: root, relativePath: "state.vscdb")?.dirtyRevision, baseline.dirtyRevision + 2)
    }

    func testCursorLegacyObserverMembershipRestartFailureCoalescingAndAtomicRollback() throws {
        let f = try CollectorInventoryTestFixture(); defer { f.remove() }
        let root = CollectorRootConfiguration(rootID: "observed", source: .cursor,
            rootPath: "/tmp/observed/User/globalStorage", revision: 1, cursorLegacy: true)
        let first = String(repeating: "a", count: 64), second = String(repeating: "b", count: 64)
        var fail = false
        let store = try f.open(hooks: .init(beforeCommit: { if fail { throw CollectorInventoryInjectedFailure.beforeCommit } }))
        try store.registerRoot(root)
        XCTAssertTrue(try store.applyCursorLegacyObservation(configuration: root, after: nil,
            membershipFingerprint: first, workspaces: [("m", first)], nextAfter: "m", mainFingerprint: first, peerFingerprint: first))
        let before = try store.locator(configuration: root, relativePath: "state.vscdb")
        fail = true
        XCTAssertThrowsError(try store.applyCursorLegacyObservation(configuration: root, after: "m",
            membershipFingerprint: second, workspaces: [("z", second)], nextAfter: nil, mainFingerprint: first, peerFingerprint: first))
        fail = false
        XCTAssertEqual(try store.cursorLegacyOwnershipAfter(configuration: root), "m")
        XCTAssertEqual(try store.locator(configuration: root, relativePath: "state.vscdb"), before)
        XCTAssertTrue(try store.applyCursorLegacyObservation(configuration: root, after: "m",
            membershipFingerprint: second, workspaces: [("z", second)], nextAfter: nil, mainFingerprint: first, peerFingerprint: first))
        XCTAssertNil(try store.cursorLegacyOwnershipAfter(configuration: root), "changed membership must restart before an earlier inserted ID")
        XCTAssertTrue(try store.applyCursorLegacyObservation(configuration: root, after: nil,
            membershipFingerprint: second, workspaces: [("a", second)], nextAfter: nil, mainFingerprint: first, peerFingerprint: first))
        try store.recordCursorLegacyObservationFailure(configuration: root, fingerprint: first)
        let failed = try store.locator(configuration: root, relativePath: "state.vscdb")
        try store.recordCursorLegacyObservationFailure(configuration: root, fingerprint: first)
        XCTAssertEqual(try store.locator(configuration: root, relativePath: "state.vscdb"), failed)
        XCTAssertTrue(try store.applyCursorLegacyObservation(configuration: root, after: nil,
            membershipFingerprint: second, workspaces: [("a", second)], nextAfter: nil, mainFingerprint: first, peerFingerprint: first))
        XCTAssertEqual(try store.locator(configuration: root, relativePath: "state.vscdb")?.dirtyRevision,
            try XCTUnwrap(failed).dirtyRevision + 1, "recovery must recheck a previously unavailable ownership input")
    }

    func testCursorLegacySchemaEightMigrationPreservesDirtyWorkAndStartsObserverCold() throws {
        let f = try CollectorInventoryTestFixture(); defer { f.remove() }
        let root = CollectorRootConfiguration(rootID: "observed", source: .cursor,
            rootPath: "/tmp/observed/User/globalStorage", revision: 1, cursorLegacy: true)
        let old = try f.open(); try old.registerRoot(root)
        try old.markDirty(configuration: root, relativePath: "state.vscdb")
        let db = try f.openDatabase()
        try db.write { db in
            try db.execute(sql: "DROP TABLE collector_cursor_legacy_workspaces")
            for suffix in ["membership", "main", "peer", "after", "error", "initialized"] {
                try db.execute(sql: "ALTER TABLE collector_roots DROP COLUMN cursor_legacy_observer_\(suffix)")
            }
            try db.execute(sql: "UPDATE collector_metadata SET value = '8' WHERE key = 'publication_schema_version'")
        }
        let reopened = try f.open(owner: "run-2")
        XCTAssertEqual(try reopened.rootState(rootID: root.rootID)?.configuration, root)
        XCTAssertNil(try reopened.cursorLegacyOwnershipAfter(configuration: root))
        XCTAssertEqual(try reopened.pendingLocators(configuration: root, limit: 8).count, 1)
    }

    func testCursorLegacySchemaSevenMigrationCreatesLedgerWithoutDroppingDirtyWork() throws {
        let f = try CursorLegacyWalkTestFixture(); defer { f.remove() }
        let old = try f.open()
        _ = try f.dirtyClaim(old)
        let db = try f.database()
        try db.write { db in
            try db.execute(sql: "DROP TABLE collector_cursor_legacy_sessions")
            try db.execute(sql: "UPDATE collector_metadata SET value = '7' WHERE key = 'publication_schema_version'")
        }
        let reopened = try f.open(owner: "run-2")
        XCTAssertNil(try reopened.lastCursorLegacyCapture(configuration: f.configuration, composerID: "owned"))
        XCTAssertEqual(try reopened.pendingLocators(configuration: f.configuration, limit: 8).count, 1)
        XCTAssertEqual(try db.read { try String.fetchOne($0,
            sql: "SELECT value FROM collector_metadata WHERE key = 'publication_schema_version'") }, "11")
    }

    func testCursorLegacyUnchangedSkipRequiresPublishedSessionAndAdvancesWithoutNewPublication() throws {
        let f = try CursorLegacyWalkTestFixture(); defer { f.remove() }
        let store = try f.open()
        let first = try f.dirtyClaim(store)
        _ = try store.reconcileCursorLegacyWalk(first, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let session = try f.context("a:/%_")
        let reservation = try XCTUnwrap(store.reserveCapture(first, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: session))
        let capture = try f.capture(session)
        _ = try store.finishCapture(reservation, capture: capture.capture)
        _ = try store.finishCursorLegacyWalk(first, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let next = try f.dirtyClaim(store)
        XCTAssertNil(try store.reconcileCursorLegacyWalk(next, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal))
        XCTAssertThrowsError(try store.advanceCursorLegacySkippedSession(next, configuration: f.configuration,
            generation: f.generation, session: session, previousCaptureID: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try store.advanceCursorLegacySkippedSession(next, configuration: f.configuration,
            generation: f.generation, session: session, previousCaptureID: nil))
        try store.advanceCursorLegacySkippedSession(next, configuration: f.configuration,
            generation: f.generation, session: session, previousCaptureID: capture.capture.captureID)
        XCTAssertEqual(try store.reconcileCursorLegacyWalk(next, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), session.composerID)
        XCTAssertEqual(try store.publicationIntents(limit: 8).count, 1)
        XCTAssertEqual(try store.pendingLocators(configuration: f.configuration, limit: 8).count, 1)
        XCTAssertTrue(try store.captureReservations(limit: 8).isEmpty)
        XCTAssertThrowsError(try store.advanceCursorLegacySkippedSession(next, configuration: f.configuration,
            generation: f.generation, session: session, previousCaptureID: capture.capture.captureID))
        XCTAssertEqual(try store.finishCursorLegacyWalk(next, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), .acknowledged)
    }

    func testCursorLegacyOwnershipOnlyDirtyEventRestartsWalkWithSameDatabasePair() throws {
        let f = try CursorLegacyWalkTestFixture(); defer { f.remove() }
        let store = try f.open()
        let claim = try f.dirtyClaim(store)
        _ = try store.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context("owned")
        let reserved = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: context))
        let capture = try f.capture(context)
        _ = try store.finishCapture(reserved, capture: capture.capture)
        _ = try store.finishCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        try store.markDirty(configuration: f.configuration, relativePath: "state.vscdb", observedGeneration: "ownership-changed")
        let next = try f.claim(store)
        XCTAssertGreaterThan(next.dirtyRevision, claim.dirtyRevision)
        XCTAssertNil(try store.reconcileCursorLegacyWalk(next, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal))
        XCTAssertNotNil(try store.reserveCapture(next, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: context))
    }

    func testCursorLegacySchemaFiveMigrationAddsContextColumnsWithoutDroppingDirtyWork() throws {
        let f = try CursorLegacyWalkTestFixture(); defer { f.remove() }
        let old = try f.open()
        _ = try f.dirtyClaim(old)
        let db = try f.database()
        try db.write { db in
            for name in ["cursor_legacy_bytes", "cursor_legacy_sha256"] {
                try db.execute(sql: "ALTER TABLE collector_capture_reservations DROP COLUMN \(name)")
            }
            for name in ["cursor_legacy_walk_generation", "cursor_legacy_walk_wal_generation",
                         "cursor_legacy_walk_page_after", "cursor_legacy_walk_dirty_revision"] {
                try db.execute(sql: "ALTER TABLE collector_roots DROP COLUMN \(name)")
            }
            try db.execute(sql: "UPDATE collector_metadata SET value = '5' WHERE key = 'publication_schema_version'")
        }
        let reopened = try f.open(owner: "run-2")
        XCTAssertEqual(try db.read { try String.fetchOne($0,
            sql: "SELECT value FROM collector_metadata WHERE key = 'publication_schema_version'") }, "11")
        let claim = try f.claim(reopened)
        _ = try reopened.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        XCTAssertNotNil(try reopened.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: f.context("owned")))
    }

    func testCursorLegacyCorruptContextFailsClosedWithoutDeletingReservation() throws {
        let f = try CursorLegacyWalkTestFixture(); defer { f.remove() }
        let store = try f.open()
        let claim = try f.dirtyClaim(store)
        _ = try store.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let reserved = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: f.context("owned")))
        let db = try f.database()
        try db.write { try $0.execute(sql: "UPDATE collector_capture_reservations SET cursor_legacy_bytes = ? WHERE id = ?",
            arguments: [Data([0]), reserved.id]) }
        XCTAssertThrowsError(try store.captureReservations(limit: 8))
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_capture_reservations") }, 1)
        XCTAssertTrue(try store.publicationIntents(limit: 8).isEmpty)
    }

    func testCursorLegacyFirstSessionCannotAcknowledgeDatabaseOrReleaseItsClaim() throws {
        let f = try CursorLegacyWalkTestFixture()
        defer { f.remove() }
        let store = try f.open()
        let claim = try f.dirtyClaim(store)
        let after = try store.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        XCTAssertNil(after)
        for id in ["a:/%_", "b"] {
            let context = try f.context(id)
            let reservation = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
                generation: f.generation, cursorLegacySession: context))
            XCTAssertEqual(reservation.cursorLegacySession, context)
            let capture = try f.capture(context)
            XCTAssertNotNil(try store.finishCapture(reservation, capture: capture.capture))
            XCTAssertEqual(try store.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
                generation: f.generation, walGeneration: f.wal), id)
            XCTAssertEqual(try store.pendingLocators(configuration: f.configuration, limit: 8).count, 1)
        }
        XCTAssertEqual(try store.publicationIntents(limit: 8).count, 2)
        XCTAssertEqual(try store.claimPublications(replicaID: "hq", limit: 8, now: 100).count, 2)
        XCTAssertEqual(try store.claimPublications(replicaID: "m1", limit: 8, now: 100).count, 2)
        XCTAssertEqual(try store.finishCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), .acknowledged)
        XCTAssertTrue(try store.pendingLocators(configuration: f.configuration, limit: 8).isEmpty)
    }

    func testCursorLegacyOldCASRecoveryCannotAdvanceDifferentWALWalk() throws {
        let f = try CursorLegacyWalkTestFixture()
        defer { f.remove() }
        var store: CollectorInventoryStore? = try f.open()
        let claim = try f.dirtyClaim(store!)
        _ = try store!.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context("ses-Z")
        let reservation = try XCTUnwrap(store!.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: context))
        let oldCapture = try f.capture(context)
        store = nil
        let reopened = try f.open(owner: "run-2")
        let resumed = try f.claim(reopened)
        let changed = try f.changedWAL()
        XCTAssertNil(try reopened.reconcileCursorLegacyWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: changed))
        XCTAssertNotNil(try reopened.finishCapture(reservation, capture: oldCapture.capture))
        XCTAssertNil(try reopened.reconcileCursorLegacyWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: changed), "old ses-Z must not skip new ses-A")
        XCTAssertNotNil(try reopened.reserveCapture(resumed, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: f.context("a:/%_", wal: changed)))
        XCTAssertEqual(try reopened.publicationIntents(limit: 8).count, 1)
    }

    func testCursorLegacyReservationPersistsLongNativeIDAndRefusesWrongSessionOrWAL() throws {
        let f = try CursorLegacyWalkTestFixture()
        defer { f.remove() }
        var store: CollectorInventoryStore? = try f.open()
        let claim = try f.dirtyClaim(store!)
        _ = try store!.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context(String(repeating: "s", count: 3_000))
        let reservation = try XCTUnwrap(store!.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: context))
        store = nil
        let reopened = try f.open(owner: "run-2")
        XCTAssertEqual(try reopened.captureReservations(limit: 8), [reservation])
        XCTAssertEqual(try reopened.captureReservations(limit: 8).first?.cursorLegacySession, context)
        for wrong in [try f.context("ses-wrong"), try f.context(context.composerID, wal: f.changedWAL())] {
            XCTAssertThrowsError(try reopened.finishCapture(reservation, capture: f.capture(wrong).capture))
        }
        XCTAssertEqual(try reopened.captureReservations(limit: 8), [reservation])
        XCTAssertTrue(try reopened.publicationIntents(limit: 8).isEmpty)
    }

    func testCursorLegacyPendingReservationPreventsPrematureEOFAndRecoversAfterRestart() throws {
        let f = try CursorLegacyWalkTestFixture()
        defer { f.remove() }
        var store: CollectorInventoryStore? = try f.open()
        let claim = try f.dirtyClaim(store!)
        _ = try store!.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context("ses-A")
        let reservation = try XCTUnwrap(store!.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: context))
        let capture = try f.capture(context)
        XCTAssertThrowsError(try store!.finishCursorLegacyWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal))
        store = nil
        let reopened = try f.open(owner: "run-2")
        let resumed = try f.claim(reopened)
        _ = try reopened.reconcileCursorLegacyWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        XCTAssertNotNil(try reopened.finishCapture(reservation, capture: capture.capture))
        XCTAssertEqual(try reopened.reconcileCursorLegacyWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), "ses-A")
        let next = try f.context("ses-B")
        XCTAssertNotNil(try reopened.reserveCapture(resumed, configuration: f.configuration,
            generation: f.generation, cursorLegacySession: next), "old recovery must preserve the new owner's claim")
    }

    func testOpenCodeFirstSessionCannotAcknowledgeDatabaseOrReleaseItsClaim() throws {
        let f = try OpenCodeWalkTestFixture()
        defer { f.remove() }
        let store = try f.open()
        let claim = try f.dirtyClaim(store)
        let after = try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        XCTAssertNil(after)
        for id in ["ses-A", "ses-B"] {
            let context = try f.context(id)
            let reservation = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
                generation: f.generation, sqliteSession: context))
            XCTAssertEqual(reservation.sqliteSession, context)
            let capture = try f.capture(context)
            XCTAssertNotNil(try store.finishCapture(reservation, capture: capture.capture))
            XCTAssertEqual(try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
                generation: f.generation, walGeneration: f.wal), id)
            XCTAssertEqual(try store.pendingLocators(configuration: f.configuration, limit: 8).count, 1)
        }
        XCTAssertEqual(try store.publicationIntents(limit: 8).count, 2)
        XCTAssertEqual(try store.claimPublications(replicaID: "hq", limit: 8, now: 100).count, 2)
        XCTAssertEqual(try store.claimPublications(replicaID: "m1", limit: 8, now: 100).count, 2)
        XCTAssertEqual(try store.finishOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), .acknowledged)
        XCTAssertTrue(try store.pendingLocators(configuration: f.configuration, limit: 8).isEmpty)
    }

    func testOpenCodeOldCASRecoveryCannotAdvanceDifferentWALWalk() throws {
        let f = try OpenCodeWalkTestFixture()
        defer { f.remove() }
        var store: CollectorInventoryStore? = try f.open()
        let claim = try f.dirtyClaim(store!)
        _ = try store!.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context("ses-Z")
        let reservation = try XCTUnwrap(store!.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, sqliteSession: context))
        let oldCapture = try f.capture(context)
        store = nil
        let reopened = try f.open(owner: "run-2")
        let resumed = try f.claim(reopened)
        let changed = try f.changedWAL()
        XCTAssertNil(try reopened.reconcileOpenCodeWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: changed))
        XCTAssertNotNil(try reopened.finishCapture(reservation, capture: oldCapture.capture))
        XCTAssertNil(try reopened.reconcileOpenCodeWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: changed), "old ses-Z must not skip new ses-A")
        XCTAssertNotNil(try reopened.reserveCapture(resumed, configuration: f.configuration,
            generation: f.generation, sqliteSession: f.context("ses-A", wal: changed)))
        XCTAssertEqual(try reopened.publicationIntents(limit: 8).count, 1)
    }

    func testOpenCodeWalkRefusesOtherPhysicalFilesAndRootRevisionResetsProgress() throws {
        let f = try OpenCodeWalkTestFixture()
        defer { f.remove() }
        let store = try f.open()
        try store.markDirty(configuration: f.configuration, relativePath: "unrelated.jsonl")
        let wrong = try f.claim(store)
        XCTAssertThrowsError(try store.reconcileOpenCodeWalk(wrong, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal))
        XCTAssertTrue(try store.deferClaim(wrong, retryNotBefore: 1000, reason: "not-an-opencode-primary"))
        let claim = try f.dirtyClaim(store)
        _ = try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context("ses-A")
        let reservation = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, sqliteSession: context))
        _ = try store.finishCapture(reservation, capture: f.capture(context).capture)
        let updated = CollectorRootConfiguration(rootID: f.configuration.rootID, source: .opencode,
            rootPath: f.configuration.rootPath + "-remapped", revision: 2)
        try store.registerRoot(updated)
        try store.enrollRoot(binding: .init(configuration: updated,
            expectedIdentity: .init(device: 1, inode: 3, generation: 0, birthSeconds: 1, birthNanoseconds: 0)))
        XCTAssertNotNil(try store.activateEnrolledRoot(configuration: updated))
        XCTAssertThrowsError(try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal))
        try store.markDirty(configuration: updated, relativePath: "opencode.db")
        let current = try XCTUnwrap(store.claimDirty(configuration: updated, limit: 8, now: 100).first)
        XCTAssertNil(try store.reconcileOpenCodeWalk(current, configuration: updated,
            generation: f.generation, walGeneration: f.wal))
    }

    func testOpenCodeReservationRequiresMatchingRootContextAndMonotonicSessionID() throws {
        let f = try OpenCodeWalkTestFixture()
        defer { f.remove() }
        let store = try f.open()
        let claim = try f.dirtyClaim(store)
        _ = try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        XCTAssertThrowsError(try store.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation))
        let wrongRoot = try ArchiveSQLiteSessionContext(databaseLocator: "/another/opencode.db",
            nativeSessionID: "ses-A", nativePayloadByteCount: 0, walGeneration: f.wal)
        XCTAssertThrowsError(try store.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, sqliteSession: wrongRoot))
        let context = try f.context("ses-B")
        let reservation = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, sqliteSession: context))
        _ = try store.finishCapture(reservation, capture: f.capture(context).capture)
        for id in ["ses-A", "ses-B"] {
            XCTAssertThrowsError(try store.reserveCapture(claim, configuration: f.configuration,
                generation: f.generation, sqliteSession: f.context(id)))
        }
    }

    func testOpenCodeReservationRequiresAnEstablishedMatchingSourcePair() throws {
        for establishDifferentPair in [false, true] {
            let f = try OpenCodeWalkTestFixture()
            defer { f.remove() }
            let store = try f.open()
            let claim = try f.dirtyClaim(store)
            if establishDifferentPair {
                _ = try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
                    generation: f.generation, walGeneration: f.changedWAL())
            }
            XCTAssertThrowsError(try store.reserveCapture(claim, configuration: f.configuration,
                generation: f.generation, sqliteSession: f.context("ses-A")))
            XCTAssertTrue(try store.captureReservations(limit: 8).isEmpty)
        }
    }

    func testOpenCodeWalkResumesAfterRestartAndResetsOnlyForDifferentPair() throws {
        let f = try OpenCodeWalkTestFixture()
        defer { f.remove() }
        var store: CollectorInventoryStore? = try f.open()
        let claim = try f.dirtyClaim(store!)
        _ = try store!.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context("ses-A")
        let reservation = try XCTUnwrap(store!.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, sqliteSession: context))
        _ = try store!.finishCapture(reservation, capture: f.capture(context).capture)
        store = nil
        let reopened = try f.open(owner: "run-2")
        let resumed = try f.claim(reopened)
        XCTAssertEqual(try reopened.reconcileOpenCodeWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), "ses-A")
        XCTAssertEqual(try reopened.publicationIntents(limit: 8).count, 1)
        let changed = try f.changedWAL()
        XCTAssertNil(try reopened.reconcileOpenCodeWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: changed))
        XCTAssertThrowsError(try reopened.finishOpenCodeWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal))
        XCTAssertEqual(try reopened.publicationIntents(limit: 8).count, 1,
            "resetting a walk must preserve older immutable publications")
    }

    func testOpenCodePublicationAndPageAdvanceRollBackTogether() throws {
        let f = try OpenCodeWalkTestFixture()
        defer { f.remove() }
        var fail = false
        let store = try f.open(hooks: .init(beforeCommit: {
            if fail { throw CollectorInventoryInjectedFailure.beforeCommit }
        }))
        let claim = try f.dirtyClaim(store)
        _ = try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context("ses-A")
        let reservation = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, sqliteSession: context))
        let capture = try f.capture(context)
        fail = true
        XCTAssertThrowsError(try store.finishCapture(reservation, capture: capture.capture))
        fail = false
        XCTAssertEqual(try store.captureReservations(limit: 8), [reservation])
        XCTAssertTrue(try store.publicationIntents(limit: 8).isEmpty)
        XCTAssertNil(try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal))
        _ = try store.finishCapture(reservation, capture: capture.capture)
        XCTAssertEqual(try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), "ses-A")
    }

    func testOpenCodeReservationPersistsLongNativeIDAndRefusesWrongSessionOrWAL() throws {
        let f = try OpenCodeWalkTestFixture()
        defer { f.remove() }
        var store: CollectorInventoryStore? = try f.open()
        let claim = try f.dirtyClaim(store!)
        _ = try store!.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context(String(repeating: "s", count: 3_000))
        let reservation = try XCTUnwrap(store!.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, sqliteSession: context))
        store = nil
        let reopened = try f.open(owner: "run-2")
        XCTAssertEqual(try reopened.captureReservations(limit: 8), [reservation])
        XCTAssertEqual(try reopened.captureReservations(limit: 8).first?.sqliteSession, context)
        for wrong in [try f.context("ses-wrong"), try f.context(context.nativeSessionID, wal: f.changedWAL())] {
            XCTAssertThrowsError(try reopened.finishCapture(reservation, capture: f.capture(wrong).capture))
        }
        XCTAssertEqual(try reopened.captureReservations(limit: 8), [reservation])
        XCTAssertTrue(try reopened.publicationIntents(limit: 8).isEmpty)
    }

    func testOpenCodePendingReservationPreventsPrematureEOFAndRecoversAfterRestart() throws {
        let f = try OpenCodeWalkTestFixture()
        defer { f.remove() }
        var store: CollectorInventoryStore? = try f.open()
        let claim = try f.dirtyClaim(store!)
        _ = try store!.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        let context = try f.context("ses-A")
        let reservation = try XCTUnwrap(store!.reserveCapture(claim, configuration: f.configuration,
            generation: f.generation, sqliteSession: context))
        let capture = try f.capture(context)
        XCTAssertThrowsError(try store!.finishOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal))
        store = nil
        let reopened = try f.open(owner: "run-2")
        let resumed = try f.claim(reopened)
        _ = try reopened.reconcileOpenCodeWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        XCTAssertNotNil(try reopened.finishCapture(reservation, capture: capture.capture))
        XCTAssertEqual(try reopened.reconcileOpenCodeWalk(resumed, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), "ses-A")
        let next = try f.context("ses-B")
        XCTAssertNotNil(try reopened.reserveCapture(resumed, configuration: f.configuration,
            generation: f.generation, sqliteSession: next), "old recovery must preserve the new owner's claim")
    }

    func testOpenCodeOldWalkCannotEraseNewDirtyAndEmptyWalkNeedsNoFakeCapture() throws {
        let f = try OpenCodeWalkTestFixture()
        defer { f.remove() }
        let store = try f.open()
        let claim = try f.dirtyClaim(store)
        _ = try store.reconcileOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal)
        try store.markDirty(configuration: f.configuration, relativePath: "opencode.db", observedGeneration: "wal-new")
        XCTAssertEqual(try store.finishOpenCodeWalk(claim, configuration: f.configuration,
            generation: f.generation, walGeneration: f.wal), .newerWorkPending)
        XCTAssertEqual(try store.pendingLocators(configuration: f.configuration, limit: 8).count, 1)
        let next = try f.claim(store)
        let changed = try f.changedWAL()
        _ = try store.reconcileOpenCodeWalk(next, configuration: f.configuration,
            generation: f.generation, walGeneration: changed)
        XCTAssertEqual(try store.finishOpenCodeWalk(next, configuration: f.configuration,
            generation: f.generation, walGeneration: changed), .acknowledged)
        XCTAssertNil(try store.locator(configuration: f.configuration, relativePath: "opencode.db")?.lastCaptureID)
        XCTAssertTrue(try store.publicationIntents(limit: 8).isEmpty)
    }
}

extension CollectorInventoryStoreTests {
    func testCursorStoreClaimCanClaimPairedPrimaryWithoutAcknowledgingUncapturedWork() throws {
        let f = try CursorModernReservationFixture(); defer { f.close() }
        let store = try f.open()
        let sealed = try f.persistPaired()
        let alias = try f.dirtyClaim(store, relativePath: f.storeRelative)
        let primary = try XCTUnwrap(store.claimFileSetPrimary(alias, configuration: f.configuration, snapshot: sealed.snapshot))
        XCTAssertEqual(primary.relativePath, f.transcriptRelative)
        XCTAssertEqual(try store.locator(configuration: f.configuration, relativePath: f.storeRelative)?.acknowledgedRevision, 0)
        let reservation = try XCTUnwrap(store.reserveCapture(primary, configuration: f.configuration,
            generation: sealed.primaryGeneration, snapshot: sealed.snapshot))
        XCTAssertNotNil(try store.finishCapture(reservation, capture: sealed.capture.capture))
        try store.markDirty(configuration: f.configuration, relativePath: f.storeRelative)
        XCTAssertEqual(try store.acknowledge(alias, captureID: sealed.capture.capture.captureID), .newerWorkPending)
        let remaining = try XCTUnwrap(store.locator(configuration: f.configuration, relativePath: f.storeRelative))
        XCTAssertGreaterThan(remaining.dirtyRevision, remaining.acknowledgedRevision)
        XCTAssertEqual(try store.publicationIntents(limit: 8).count, 1)
    }

    func testCursorPrimaryClaimDoesNotStealAnAlreadyClaimedPrimary() throws {
        let f = try CursorModernReservationFixture(); defer { f.close() }
        let store = try f.open()
        let sealed = try f.persistPaired()
        let primary = try f.dirtyClaim(store, relativePath: f.transcriptRelative)
        let alias = try f.dirtyClaim(store, relativePath: f.storeRelative)
        XCTAssertNil(try store.claimFileSetPrimary(alias, configuration: f.configuration, snapshot: sealed.snapshot))
        XCTAssertNotNil(try store.reserveCapture(primary, configuration: f.configuration,
            generation: sealed.primaryGeneration, snapshot: sealed.snapshot))
    }

    func testCopilotStoreClaimCanClaimCleanEventsPrimaryWithoutAcknowledgingIndex() throws {
        let f = try CopilotFileSetClaimFixture(); defer { f.close() }
        let store = try f.open()
        let snapshot = try f.observe("session-1/events.jsonl")
        try f.acknowledgeLocator(store, relativePath: "session-1/events.jsonl")
        let alias = try f.dirtyClaim(store, relativePath: "session-1/checkpoints/index.md")
        let primary = try XCTUnwrap(store.claimFileSetPrimary(alias, configuration: f.configuration, snapshot: snapshot))
        XCTAssertEqual(primary.relativePath, "session-1/events.jsonl")
        XCTAssertEqual(
            try store.locator(configuration: f.configuration, relativePath: "session-1/checkpoints/index.md")?.acknowledgedRevision,
            0
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(store.locator(configuration: f.configuration, relativePath: "session-1/events.jsonl")).dirtyRevision,
            try XCTUnwrap(store.locator(configuration: f.configuration, relativePath: "session-1/events.jsonl")).acknowledgedRevision
        )
    }

    func testCopilotPrimaryClaimRejectsAnotherSessionAndStaleOrClaimedPrimary() throws {
        let f = try CopilotFileSetClaimFixture(); defer { f.close() }
        try f.writeSession("session-2")
        let store = try f.open()
        let foreign = try f.observe("session-2/events.jsonl")
        let alias = try f.dirtyClaim(store, relativePath: "session-1/checkpoints/index.md")
        XCTAssertThrowsError(try store.claimFileSetPrimary(alias, configuration: f.configuration, snapshot: foreign))
        let body = try f.dirtyClaim(store, relativePath: "session-1/checkpoints/001.md")
        XCTAssertThrowsError(try store.claimFileSetPrimary(body, configuration: f.configuration, snapshot: try f.observe("session-1/events.jsonl")))
        let stale = try f.open(owner: "run-2")
        XCTAssertNil(try stale.claimFileSetPrimary(alias, configuration: f.configuration, snapshot: try f.observe("session-1/events.jsonl")))
        let owned = try CopilotFileSetClaimFixture(); defer { owned.close() }
        let claimed = try owned.open()
        let snapshot = try owned.observe("session-1/events.jsonl")
        _ = try owned.dirtyClaim(claimed, relativePath: "session-1/events.jsonl")
        let leftover = try owned.dirtyClaim(claimed, relativePath: "session-1/checkpoints/index.md")
        XCTAssertNil(try claimed.claimFileSetPrimary(leftover, configuration: owned.configuration, snapshot: snapshot))
        XCTAssertEqual(
            try claimed.locator(configuration: owned.configuration, relativePath: "session-1/checkpoints/index.md")?.acknowledgedRevision,
            0
        )
    }

    func testCursorModernReservationSurvivesDatabaseCatalogReopenAndSourceRemoval() throws {
        let f = try CursorModernReservationFixture(); defer { f.close() }
        var store: CollectorInventoryStore? = try f.open()
        let sealed = try f.persistPaired()
        XCTAssertEqual(sealed.snapshot.entrypointRelativePath, f.transcriptRelative)
        XCTAssertEqual(sealed.capture.manifest.generation, sealed.primaryGeneration)
        XCTAssertTrue(ArchiveSourceDescriptor.isCursorModernFileSet(sealed.capture.manifest))
        let reservation = try XCTUnwrap(store!.reserveCapture(
            try f.dirtyClaim(store!, relativePath: f.transcriptRelative),
            configuration: f.configuration, generation: sealed.primaryGeneration, snapshot: sealed.snapshot
        ))
        XCTAssertEqual(reservation.generation, sealed.primaryGeneration)
        XCTAssertEqual(reservation.relativePath, f.transcriptRelative)
        let expectedID = sealed.capture.capture.captureID
        store = nil
        try f.reopenDatabase()
        try f.reopenCatalog()
        try FileManager.default.removeItem(at: f.root)
        let loaded = try f.loadPersistedCapture()
        XCTAssertEqual(loaded.capture.captureID, expectedID)
        XCTAssertEqual(
            try f.cas.readManifest(sha256: loaded.capture.unboundManifestSHA256),
            loaded.capture.unboundManifestBytes
        )
        XCTAssertEqual(
            try ArchiveCanonicalJSON.encode(loaded.manifest),
            loaded.capture.unboundManifestBytes
        )
        let reopened = try f.open(owner: "run-2")
        XCTAssertEqual(try reopened.captureReservations(limit: 8), [reservation])
        XCTAssertNotNil(try reopened.finishCapture(reservation, capture: loaded.capture))
        XCTAssertTrue(try reopened.captureReservations(limit: 8).isEmpty)
        XCTAssertEqual(try reopened.publicationIntents(limit: 8).count, 1)
        XCTAssertEqual(try reopened.publicationIntents(limit: 8).first?.captureID, loaded.capture.captureID)
        let states = try f.database.read {
            try String.fetchAll($0, sql: "SELECT state FROM collector_publication_replicas ORDER BY replica_id")
        }
        XCTAssertEqual(states, ["pending", "pending"])
    }

    func testCursorAuxiliaryOnlyCaptureCannotReplaceReservedTranscriptPrimary() throws {
        let f = try CursorModernReservationFixture(); defer { f.close() }
        let store = try f.open()
        let old = try f.persistPaired(meta: Data("meta-old".utf8))
        let reservation = try XCTUnwrap(store.reserveCapture(
            try f.dirtyClaim(store, relativePath: f.transcriptRelative),
            configuration: f.configuration, generation: old.primaryGeneration, snapshot: old.snapshot
        ))
        let next = try f.persistPaired(meta: Data("meta-new-auxiliary".utf8), metaGeneration: f.changedMetaGeneration)
        XCTAssertEqual(next.snapshot.entrypointRelativePath, f.transcriptRelative)
        XCTAssertEqual(next.primaryGeneration, old.primaryGeneration)
        XCTAssertEqual(next.capture.manifest.generation, old.capture.manifest.generation)
        XCTAssertEqual(next.capture.capture.locator, old.capture.capture.locator)
        XCTAssertNotEqual(next.capture.capture.captureID, old.capture.capture.captureID)
        XCTAssertNotEqual(next.snapshot, old.snapshot)
        XCTAssertThrowsError(try store.finishCapture(reservation, capture: next.capture.capture))
        XCTAssertEqual(try store.captureReservations(limit: 8), [reservation])
        XCTAssertNotNil(try store.finishCapture(reservation, capture: old.capture.capture))
        XCTAssertEqual(try store.publicationIntents(limit: 8).first?.captureID, old.capture.capture.captureID)
    }

    func testCursorReservationRetryDistinguishesByteDifferentUnicodeMemberPaths() throws {
        let f = try CursorModernReservationFixture(); defer { f.close() }
        let store = try f.open()
        let sealed = try f.persistPaired()
        func snapshot(workspace: String) -> CollectorDependencySnapshot {
            CollectorDependencySnapshot(entrypointRelativePath: sealed.snapshot.entrypointRelativePath,
                present: sealed.snapshot.present.map { member in
                    .init(relativePath: member.relativePath.replacingOccurrences(of: "chats/ws/", with: "chats/" + workspace + "/"),
                        generation: member.generation)
                }, absentRelativePaths: sealed.snapshot.absentRelativePaths)
        }
        let first = snapshot(workspace: "caf\u{00e9}")
        let second = snapshot(workspace: "cafe\u{0301}")
        XCTAssertEqual(first, second, "Swift String equality folds canonical Unicode equivalence")
        XCTAssertNotEqual(first.present.map { Data($0.relativePath.utf8) }, second.present.map { Data($0.relativePath.utf8) })
        let claim = try f.dirtyClaim(store, relativePath: f.transcriptRelative)
        let reservation = try XCTUnwrap(store.reserveCapture(claim, configuration: f.configuration,
            generation: sealed.primaryGeneration, snapshot: first))
        XCTAssertNil(try store.reserveCapture(claim, configuration: f.configuration,
            generation: sealed.primaryGeneration, snapshot: second), "a byte-distinct dependency set cannot reuse the reserved generation")
        XCTAssertEqual(try store.captureReservations(limit: 8).first?.snapshot?.present.map { Data($0.relativePath.utf8) },
            reservation.snapshot?.present.map { Data($0.relativePath.utf8) })
        let different = CollectorCaptureReservation(id: reservation.id, rootID: reservation.rootID,
            rootRevision: reservation.rootRevision, relativePath: reservation.relativePath,
            dirtyRevision: reservation.dirtyRevision, generation: reservation.generation,
            sourceInstanceID: reservation.sourceInstanceID, collectorEpoch: reservation.collectorEpoch,
            sequence: reservation.sequence, snapshot: second)
        XCTAssertTrue(try store.storeCaptureRecoveryState(reservation, payload: Data("original".utf8)))
        XCTAssertFalse(try store.storeCaptureRecoveryState(different, payload: Data("wrong-generation".utf8)))
        XCTAssertNil(try store.captureRecoveryState(different))
        XCTAssertEqual(try store.captureRecoveryState(reservation), Data("original".utf8))
        XCTAssertFalse(try store.abandonCapture(different))
        XCTAssertEqual(try store.captureReservations(limit: 8).count, 1)
    }

    func testCursorStoreOnlySnapshotShapeAndInvalidReservationMembers() throws {
        let f = try CursorModernReservationFixture(); defer { f.close() }
        let store = try f.open()
        let paired = try f.persistPaired()
        let claim = try f.dirtyClaim(store, relativePath: f.transcriptRelative)
        XCTAssertThrowsError(try store.reserveCapture(
            claim, configuration: f.configuration, generation: paired.primaryGeneration
        ))
        let wrongPrimary = CollectorDependencySnapshot(
            entrypointRelativePath: f.storeRelative, present: paired.snapshot.present,
            absentRelativePaths: paired.snapshot.absentRelativePaths
        )
        XCTAssertThrowsError(try store.reserveCapture(
            claim, configuration: f.configuration, generation: paired.storeGeneration, snapshot: wrongPrimary
        ))
        let missingStore = CollectorDependencySnapshot(
            entrypointRelativePath: f.transcriptRelative,
            present: paired.snapshot.present.filter { $0.relativePath != f.storeRelative },
            absentRelativePaths: paired.snapshot.absentRelativePaths
        )
        XCTAssertThrowsError(try store.reserveCapture(
            claim, configuration: f.configuration, generation: paired.primaryGeneration, snapshot: missingStore
        ))
        let unrelated = CollectorDependencySnapshot(
            entrypointRelativePath: f.transcriptRelative,
            present: paired.snapshot.present + [
                .init(relativePath: f.storeRelative + "-shm", generation: f.noiseGeneration),
            ],
            absentRelativePaths: paired.snapshot.absentRelativePaths
        )
        XCTAssertThrowsError(try store.reserveCapture(
            claim, configuration: f.configuration, generation: paired.primaryGeneration, snapshot: unrelated
        ))
        XCTAssertTrue(try store.captureReservations(limit: 8).isEmpty)

        let valid = try f.persistStoreOnly()
        XCTAssertEqual(valid.snapshot.entrypointRelativePath, f.storeRelative)
        XCTAssertEqual(Set(valid.snapshot.absentRelativePaths), [f.storeRelative + "-wal", f.metaRelative])
        XCTAssertFalse(valid.snapshot.present.contains { $0.relativePath.hasSuffix("-shm") || $0.relativePath.hasSuffix("-journal") })
        let accepted = try XCTUnwrap(store.reserveCapture(
            try f.dirtyClaim(store, relativePath: f.storeRelative),
            configuration: f.configuration, generation: valid.primaryGeneration, snapshot: valid.snapshot
        ))
        XCTAssertEqual(accepted.snapshot, valid.snapshot)
        XCTAssertEqual(try store.captureReservations(limit: 8), [accepted])
    }

    func testCursorReservationReloadsOnPublicationSchemaFiveAndFailsClosedOnCorruptDependency() throws {
        let f = try CursorModernReservationFixture(); defer { f.close() }
        var store: CollectorInventoryStore? = try f.open()
        let sealed = try f.persistPaired()
        let reservation = try XCTUnwrap(store!.reserveCapture(
            try f.dirtyClaim(store!, relativePath: f.transcriptRelative),
            configuration: f.configuration, generation: sealed.primaryGeneration, snapshot: sealed.snapshot
        ))
        XCTAssertEqual(try f.database.read {
            try String.fetchOne($0, sql: "SELECT value FROM collector_metadata WHERE key = 'publication_schema_version'")
        }, "11")
        store = nil
        try f.reopenDatabase()
        let reloaded = try f.open(owner: "run-2")
        XCTAssertEqual(try reloaded.captureReservations(limit: 8), [reservation])
        try f.database.write { db in
            try db.execute(sql: """
                UPDATE collector_capture_reservation_dependencies SET generation_bytes = ?
                WHERE reservation_id = ? AND relative_path = ?
                """, arguments: [Data([0x00]), reservation.id, f.transcriptRelative])
        }
        XCTAssertThrowsError(try reloaded.captureReservations(limit: 8))
        XCTAssertEqual(try f.database.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_capture_reservations")
        }, 1)
    }
}

private final class OpenCodeWalkTestFixture {
    private let base: CollectorInventoryTestFixture
    let configuration: CollectorRootConfiguration
    let generation: ArchiveSourceGeneration
    let wal: ArchiveSourceGeneration
    let cas: ImmutableArchiveCAS
    let catalog: ArchiveCatalog

    init() throws {
        let fixture = try CollectorInventoryTestFixture()
        base = fixture
        let pointer = try XCTUnwrap(realpath(fixture.root.path, nil))
        defer { free(pointer) }
        let physical = URL(fileURLWithPath: String(cString: pointer))
        configuration = .init(rootID: "open-code", source: .opencode,
            rootPath: physical.appendingPathComponent("source").path, revision: 1)
        generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: 819200,
            mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
        wal = try ArchiveSourceGeneration(device: 1, inode: 5, size: 16384,
            mtimeNs: 6, ctimeNs: 7, mode: 0o100600)
        let archive = physical.appendingPathComponent("archive")
        cas = try ImmutableArchiveCAS(root: archive)
        catalog = try ArchiveCatalog(root: archive, machineID: fixture.machineID)
        try catalog.migrate()
    }

    func open(owner: String = "run-1", hooks: CollectorInventoryStoreTestHooks = .init()) throws -> CollectorInventoryStore {
        let store = try base.open(owner: owner, hooks: hooks)
        try store.registerRoot(configuration)
        try store.enrollRoot(binding: .init(configuration: configuration,
            expectedIdentity: .init(device: 1, inode: 2, generation: 0, birthSeconds: 1, birthNanoseconds: 0)))
        XCTAssertNotNil(try store.activateEnrolledRoot(configuration: configuration))
        return store
    }

    func claim(_ store: CollectorInventoryStore) throws -> CollectorDirtyClaim {
        try XCTUnwrap(store.claimDirty(configuration: configuration, limit: 1, now: 100).first)
    }

    func dirtyClaim(_ store: CollectorInventoryStore) throws -> CollectorDirtyClaim {
        try store.markDirty(configuration: configuration, relativePath: "opencode.db", observedGeneration: "wal-initial")
        return try claim(store)
    }

    func changedWAL() throws -> ArchiveSourceGeneration {
        try ArchiveSourceGeneration(device: 1, inode: 5, size: 32768, mtimeNs: 8, ctimeNs: 9, mode: 0o100600)
    }

    func context(_ id: String, wal override: ArchiveSourceGeneration? = nil) throws -> ArchiveSQLiteSessionContext {
        try ArchiveSQLiteSessionContext(databaseLocator: configuration.rootPath + "/opencode.db",
            nativeSessionID: id, nativePayloadByteCount: 0, walGeneration: override ?? wal)
    }

    func capture(_ context: ArchiveSQLiteSessionContext) throws -> ArchiveCaptureResult {
        let file = base.root.appendingPathComponent("image-\(UUID().uuidString).sqlite")
        let db = try DatabaseQueue(path: file.path)
        try db.write {
            try $0.execute(sql: "CREATE TABLE session(id TEXT, directory TEXT); INSERT INTO session VALUES (?, ?)",
                arguments: [context.nativeSessionID, "/fixture/project"])
        }
        try db.close()
        return try ExactSourceCapturer.captureSQLiteSessionImage(Data(contentsOf: file), context: context,
            generation: generation, machineID: base.machineID, cas: cas, catalog: catalog)
    }

    func remove() {
        try? catalog.close()
        base.remove()
    }
}

/// Sealed reservation fixtures only. Planted SHM/journal are excluded members,
/// not a live captureModern proof with a source journal present.
private final class CursorModernReservationFixture {
    let base: URL
    let root: URL
    let archive: URL
    var database: DatabaseQueue
    let cas: ImmutableArchiveCAS
    var catalog: ArchiveCatalog
    let machineID = "11111111-2222-3333-4444-555555555555"
    let storeRelative = "chats/ws/sid/store.db"
    let transcriptRelative = "projects/proj/agent-transcripts/sid/sid.jsonl"
    var metaRelative: String { "chats/ws/sid/meta.json" }
    let storeGeneration: ArchiveSourceGeneration
    let transcriptGeneration: ArchiveSourceGeneration
    let walGeneration: ArchiveSourceGeneration
    let metaGeneration: ArchiveSourceGeneration
    let changedMetaGeneration: ArchiveSourceGeneration
    let noiseGeneration: ArchiveSourceGeneration
    var configuration: CollectorRootConfiguration {
        .init(rootID: "cursor", source: .cursor, rootPath: root.path, revision: 1)
    }

    struct Sealed {
        let snapshot: CollectorDependencySnapshot
        let capture: ArchiveCaptureResult
        let storeGeneration: ArchiveSourceGeneration
        var primaryGeneration: ArchiveSourceGeneration {
            snapshot.present.first { $0.relativePath == snapshot.entrypointRelativePath }!.generation
        }
    }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-reserve-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        root = base.appendingPathComponent("source")
        archive = base.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        database = try DatabaseQueue(path: base.appendingPathComponent("inventory.sqlite").path)
        cas = try ImmutableArchiveCAS(root: archive)
        catalog = try ArchiveCatalog(root: archive, machineID: machineID)
        try catalog.migrate()
        storeGeneration = try ArchiveSourceGeneration(
            device: 1, inode: 2, size: 5, mtimeNs: 10, ctimeNs: 11, mode: 0o100600)
        transcriptGeneration = try ArchiveSourceGeneration(
            device: 1, inode: 3, size: 11, mtimeNs: 12, ctimeNs: 13, mode: 0o100600)
        walGeneration = try ArchiveSourceGeneration(
            device: 1, inode: 4, size: 3, mtimeNs: 14, ctimeNs: 15, mode: 0o100600)
        metaGeneration = try ArchiveSourceGeneration(
            device: 1, inode: 5, size: 8, mtimeNs: 16, ctimeNs: 17, mode: 0o100600)
        changedMetaGeneration = try ArchiveSourceGeneration(
            device: 1, inode: 5, size: 18, mtimeNs: 26, ctimeNs: 27, mode: 0o100600)
        noiseGeneration = try ArchiveSourceGeneration(
            device: 1, inode: 9, size: 1, mtimeNs: 1, ctimeNs: 1, mode: 0o100600)
    }

    func open(owner: String = "run-1") throws -> CollectorInventoryStore {
        let store = try CollectorInventoryStore(database: database, machineID: machineID, ownerRunID: owner)
        try store.registerRoot(configuration)
        try store.enrollRoot(binding: .init(configuration: configuration,
            expectedIdentity: .init(device: 1, inode: 2, generation: 0, birthSeconds: 1, birthNanoseconds: 0)))
        XCTAssertNotNil(try store.activateEnrolledRoot(configuration: configuration))
        return store
    }

    func dirtyClaim(_ store: CollectorInventoryStore, relativePath: String) throws -> CollectorDirtyClaim {
        try store.markDirty(configuration: configuration, relativePath: relativePath)
        let claims = try store.claimDirty(configuration: configuration, limit: 8, now: 100)
        return try XCTUnwrap(claims.first { $0.relativePath == relativePath })
    }

    func persistPaired(
        meta: Data = Data("meta-old".utf8), metaGeneration override: ArchiveSourceGeneration? = nil
    ) throws -> Sealed {
        let store = Data("STORE".utf8)
        let transcript = Data("TRANSCRIPT\n".utf8)
        let wal = Data("WAL".utf8)
        try write(storeRelative, store)
        try write(storeRelative + "-wal", wal)
        try write(metaRelative, meta)
        try write(transcriptRelative, transcript)
        try write(storeRelative + "-shm", Data([1]))
        try write(storeRelative + "-journal", Data([2]))
        return try persist(
            store: store, transcript: transcript, wal: wal, meta: meta,
            metaGeneration: override ?? metaGeneration
        )
    }

    func persistStoreOnly() throws -> Sealed {
        let store = Data("STORE".utf8)
        try write(storeRelative, store)
        try write(storeRelative + "-shm", Data([1]))
        return try persist(store: store, transcript: nil, wal: nil, meta: nil)
    }

    func persist(
        store: Data, transcript: Data?, wal: Data?, meta: Data?,
        metaGeneration: ArchiveSourceGeneration? = nil
    ) throws -> Sealed {
        var files: [CollectorCursorSource.CapturedMember] = [
            .init(relativePath: storeRelative, generation: storeGeneration, bytes: store),
        ]
        if let wal {
            files.append(.init(relativePath: storeRelative + "-wal", generation: walGeneration, bytes: wal))
        }
        if let meta {
            files.append(.init(relativePath: metaRelative, generation: metaGeneration ?? self.metaGeneration, bytes: meta))
        }
        if let transcript {
            files.append(.init(relativePath: transcriptRelative, generation: transcriptGeneration, bytes: transcript))
        }
        files.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        var absent: [String] = []
        if wal == nil { absent.append(storeRelative + "-wal") }
        if meta == nil { absent.append(metaRelative) }
        absent.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let session = CollectorCursorSource.ModernSession(
            nativeSessionID: "sid", storeRelativePath: storeRelative,
            transcriptRelativePath: transcript != nil ? transcriptRelative : nil,
            present: files.map { .init(relativePath: $0.relativePath, generation: $0.generation) },
            absentRelativePaths: absent
        )
        let modern = CollectorCursorSource.ModernCapture(rootPath: root.path, session: session, files: files)
        let capture = try CollectorCursorSource.persistModern(
            modern, machineID: machineID, cas: cas, catalog: catalog
        )
        return Sealed(snapshot: snapshot(from: modern), capture: capture, storeGeneration: storeGeneration)
    }

    func snapshot(from capture: CollectorCursorSource.ModernCapture) -> CollectorDependencySnapshot {
        let primary = capture.session.transcriptRelativePath ?? capture.session.storeRelativePath!
        var slots = Set<Data>()
        if let store = capture.session.storeRelativePath {
            slots.insert(Data((store + "-wal").utf8))
            slots.insert(Data((store.split(separator: "/").dropLast().joined(separator: "/") + "/meta.json").utf8))
        }
        return CollectorDependencySnapshot(
            entrypointRelativePath: primary,
            present: capture.files.map { .init(relativePath: $0.relativePath, generation: $0.generation) }
                .sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) },
            absentRelativePaths: capture.session.absentRelativePaths
                .filter { slots.contains(Data($0.utf8)) }
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        )
    }

    func loadPersistedCapture() throws -> ArchiveCaptureResult {
        let capture = try XCTUnwrap(try catalog.unboundCaptures(limit: 2).first)
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self, from: capture.unboundManifestBytes
        )
        return ArchiveCaptureResult(capture: capture, manifest: manifest)
    }

    func write(_ relative: String, _ bytes: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    func reopenDatabase() throws {
        try database.close()
        database = try DatabaseQueue(path: base.appendingPathComponent("inventory.sqlite").path)
    }

    func reopenCatalog() throws {
        try catalog.close()
        catalog = try ArchiveCatalog(root: archive, machineID: machineID)
        try catalog.migrate()
    }

    func close() {
        try? catalog.close()
        try? database.close()
        try? FileManager.default.removeItem(at: base)
    }
}

private final class CopilotFileSetClaimFixture {
    let base: URL
    let root: URL
    var database: DatabaseQueue
    let machineID = "11111111-2222-3333-4444-555555555555"
    var configuration: CollectorRootConfiguration {
        .init(rootID: "copilot", source: .copilot, rootPath: root.path, revision: 1)
    }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-claim-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        root = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        database = try DatabaseQueue(path: base.appendingPathComponent("inventory.sqlite").path)
        try writeSession("session-1")
    }

    func open(owner: String = "run-1") throws -> CollectorInventoryStore {
        let store = try CollectorInventoryStore(database: database, machineID: machineID, ownerRunID: owner)
        try store.registerRoot(configuration)
        try store.enrollRoot(binding: .init(configuration: configuration,
            expectedIdentity: .init(device: 1, inode: 2, generation: 0, birthSeconds: 1, birthNanoseconds: 0)))
        XCTAssertNotNil(try store.activateEnrolledRoot(configuration: configuration))
        return store
    }

    func writeSession(_ session: String) throws {
        let directory = root.appendingPathComponent(session)
        let checkpoints = directory.appendingPathComponent("checkpoints")
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        try Data("{\"type\":\"user.message\",\"data\":{\"content\":\"hello\"}}\n".utf8)
            .write(to: directory.appendingPathComponent("events.jsonl"))
        try Data("id: \(session)\ncwd: /repo/\(session)\n".utf8)
            .write(to: directory.appendingPathComponent("workspace.yaml"))
        try Data("| 1 | Checkpoint | 001.md |\n".utf8)
            .write(to: checkpoints.appendingPathComponent("index.md"))
        try Data("# body\n".utf8).write(to: checkpoints.appendingPathComponent("001.md"))
    }

    func observe(_ primary: String) throws -> CollectorDependencySnapshot {
        try CollectorCopilotSource.observe(rootPath: root.path, primaryRelative: primary).snapshot
    }

    func dirtyClaim(_ store: CollectorInventoryStore, relativePath: String) throws -> CollectorDirtyClaim {
        try store.markDirty(configuration: configuration, relativePath: relativePath)
        let claims = try store.claimDirty(configuration: configuration, limit: 8, now: 100)
        return try XCTUnwrap(claims.first { $0.relativePath == relativePath })
    }

    func acknowledgeLocator(_ store: CollectorInventoryStore, relativePath: String) throws {
        try store.markDirty(configuration: configuration, relativePath: relativePath)
        try database.write { db in
            try db.execute(sql: """
                UPDATE collector_locators SET acknowledged_revision = dirty_revision
                WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [configuration.rootID, configuration.revision, relativePath])
        }
    }

    func close() {
        try? database.close()
        try? FileManager.default.removeItem(at: base)
    }
}

private final class CursorLegacyWalkTestFixture {
    private let base: CollectorInventoryTestFixture
    let configuration: CollectorRootConfiguration
    let generation: ArchiveSourceGeneration
    let wal: ArchiveSourceGeneration
    let cas: ImmutableArchiveCAS
    let catalog: ArchiveCatalog

    init() throws {
        let fixture = try CollectorInventoryTestFixture()
        base = fixture
        let pointer = try XCTUnwrap(realpath(fixture.root.path, nil))
        defer { free(pointer) }
        let physical = URL(fileURLWithPath: String(cString: pointer))
        configuration = .init(rootID: "cursor-legacy", source: .cursor,
            rootPath: physical.appendingPathComponent("source").path, revision: 1)
        generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: 819200,
            mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
        wal = try ArchiveSourceGeneration(device: 1, inode: 5, size: 16384,
            mtimeNs: 6, ctimeNs: 7, mode: 0o100600)
        let archive = physical.appendingPathComponent("archive")
        cas = try ImmutableArchiveCAS(root: archive)
        catalog = try ArchiveCatalog(root: archive, machineID: fixture.machineID)
        try catalog.migrate()
    }

    func open(owner: String = "run-1", hooks: CollectorInventoryStoreTestHooks = .init()) throws -> CollectorInventoryStore {
        let store = try base.open(owner: owner, hooks: hooks)
        try store.registerRoot(configuration)
        try store.enrollRoot(binding: .init(configuration: configuration,
            expectedIdentity: .init(device: 1, inode: 2, generation: 0, birthSeconds: 1, birthNanoseconds: 0)))
        XCTAssertNotNil(try store.activateEnrolledRoot(configuration: configuration))
        return store
    }

    func claim(_ store: CollectorInventoryStore) throws -> CollectorDirtyClaim {
        try XCTUnwrap(store.claimDirty(configuration: configuration, limit: 1, now: 100).first)
    }

    func dirtyClaim(_ store: CollectorInventoryStore) throws -> CollectorDirtyClaim {
        try store.markDirty(configuration: configuration, relativePath: "state.vscdb", observedGeneration: "wal-initial")
        return try claim(store)
    }

    func changedWAL() throws -> ArchiveSourceGeneration {
        try ArchiveSourceGeneration(device: 1, inode: 5, size: 32768, mtimeNs: 8, ctimeNs: 9, mode: 0o100600)
    }

    func session(_ id: String, wal override: ArchiveSourceGeneration? = nil) throws -> ArchiveCursorLegacySession {
        let bytes = try JSONSerialization.data(withJSONObject: ["composerId": id], options: [.sortedKeys])
        return try ArchiveCursorLegacySession(logicalDatabaseLocator: configuration.rootPath + "/state.vscdb",
            composerID: id, cwd: "/fixture/project", databaseGeneration: generation, walGeneration: override ?? wal,
            composer: .init(rowID: 1, key: "composerData:" + id, value: bytes), bubbles: [])
    }

    func context(_ id: String, wal override: ArchiveSourceGeneration? = nil) throws -> ArchiveCursorLegacyContext {
        try ArchiveCursorLegacyContext(session: session(id, wal: override))
    }

    func capture(_ context: ArchiveCursorLegacyContext) throws -> ArchiveCaptureResult {
        try ExactSourceCapturer.captureCursorLegacySession(session(context.composerID, wal: context.walGeneration),
            machineID: base.machineID, cas: cas, catalog: catalog)
    }

    func database() throws -> DatabaseQueue { try base.openDatabase() }

    func remove() {
        try? catalog.close()
        base.remove()
    }
}

extension CollectorInventoryStoreTests {
    func testVSCodeReservationRecoversFrozenConfigurationAfterDatabaseReopenAndSourceRemoval() throws {
        let f = try VSCodePersistenceFixture(); defer { f.close() }
        var store: CollectorInventoryStore? = try f.open()
        let captured = try f.capture()
        let snapshot = try f.snapshot(captured)
        let reserved = try XCTUnwrap(store!.reserveCapture(f.claim(store!), configuration: f.configuration,
            generation: captured.manifest.generation, snapshot: snapshot))
        store = nil
        try f.reopen()
        try FileManager.default.removeItem(at: f.source)
        let reopened = try f.open(owner: "run-2")
        XCTAssertEqual(try reopened.captureReservations(limit: 8), [reserved])
        XCTAssertEqual(try reopened.captureReservations(limit: 8).first?.snapshot?.vscodeWorkspaceContext, try f.context)
        XCTAssertNotNil(try reopened.finishCapture(reserved, capture: captured.capture))
        XCTAssertTrue(try reopened.captureReservations(limit: 8).isEmpty)
        XCTAssertEqual(try reopened.publicationIntents(limit: 8).count, 1)
        XCTAssertEqual(try f.database.read { try String.fetchAll($0,
            sql: "SELECT state FROM collector_publication_replicas ORDER BY replica_id") }, ["pending", "pending"])
    }

    func testVSCodeReservationRejectsChangedFrozenConfigurationWithoutConsumingReservation() throws {
        let f = try VSCodePersistenceFixture(); defer { f.close() }
        let store = try f.open()
        let captured = try f.capture()
        let snapshot = try f.snapshot(captured)
        let reserved = try XCTUnwrap(store.reserveCapture(f.claim(store), configuration: f.configuration,
            generation: captured.manifest.generation, snapshot: snapshot))
        let changed = try f.capture(context: f.makeContext(Data(#"{"folders":[{"path":"other"}]}"#.utf8)))
        XCTAssertEqual(changed.manifest.wholeSourceSHA256, captured.manifest.wholeSourceSHA256)
        XCTAssertNotEqual(changed.manifest.captureID, captured.manifest.captureID)
        XCTAssertThrowsError(try store.finishCapture(reserved, capture: changed.capture))
        XCTAssertEqual(try store.captureReservations(limit: 8), [reserved])
        XCTAssertTrue(try store.publicationIntents(limit: 8).isEmpty)
        XCTAssertNotNil(try store.finishCapture(reserved, capture: captured.capture))
    }

    func testSchemaTenMigrationPreservesExistingPublicationAndACKBytes() throws {
        let f = try CollectorInventoryTestFixture(); defer { f.remove() }
        _ = try f.openRegistered()
        let db = try f.openDatabase()
        try f.seedPublications(in: db, acknowledgedReplicas: ["hq"])
        let before = try db.read { db in
            (try Data.fetchOne(db, sql: "SELECT canonical_bytes FROM collector_publications"),
             try Data.fetchOne(db, sql: "SELECT ack_bytes FROM collector_publication_replicas WHERE replica_id = 'hq'"))
        }
        try db.write { db in
            try db.execute(sql: "ALTER TABLE collector_capture_reservations DROP COLUMN vscode_context_bytes")
            try db.execute(sql: "ALTER TABLE collector_capture_reservations DROP COLUMN vscode_context_sha256")
            try db.execute(sql: "UPDATE collector_metadata SET value = '10' WHERE key = 'publication_schema_version'")
        }
        _ = try f.open(owner: "migrated")
        try db.read { db in
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT canonical_bytes FROM collector_publications"), before.0)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT ack_bytes FROM collector_publication_replicas WHERE replica_id = 'hq'"), before.1)
            XCTAssertNotNil(before.1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'publication_schema_version'"), "11")
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testVSCodePublicationFailureRollsBackFrozenContextAndReplicaObligations() throws {
        let f = try VSCodePersistenceFixture(); defer { f.close() }
        var fail = false
        let store = try f.open(hooks: .init(beforeCommit: {
            if fail { throw CollectorInventoryInjectedFailure.beforeCommit }
        }))
        let captured = try f.capture()
        let reserved = try XCTUnwrap(store.reserveCapture(f.claim(store), configuration: f.configuration,
            generation: captured.manifest.generation, snapshot: f.snapshot(captured)))
        fail = true
        XCTAssertThrowsError(try store.finishCapture(reserved, capture: captured.capture))
        fail = false
        XCTAssertEqual(try store.captureReservations(limit: 8), [reserved])
        XCTAssertTrue(try store.publicationIntents(limit: 8).isEmpty)
        XCTAssertEqual(try f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_publication_replicas") }, 0)
        XCTAssertNotNil(try store.finishCapture(reserved, capture: captured.capture))
    }

    func testVSCodeReservationPreservesReferencedAbsenceAndMaximumConfigurationBytes() throws {
        for missing in [true, false] {
            let f = try VSCodePersistenceFixture(); defer { f.close() }
            let context = try missing
                ? ArchiveVSCodeWorkspaceContext(configurationLocator: f.source.appendingPathComponent("project.code-workspace").path)
                : f.makeContext(Data(repeating: 32, count: ArchiveVSCodeWorkspaceContext.maximumContextBytes))
            var store: CollectorInventoryStore? = try f.open()
            let captured = try f.capture(context: context)
            let reserved = try XCTUnwrap(store!.reserveCapture(f.claim(store!), configuration: f.configuration,
                generation: captured.manifest.generation, snapshot: f.snapshot(captured)))
            store = nil
            try f.reopen()
            try FileManager.default.removeItem(at: f.source)
            let reopened = try f.open(owner: "run-2")
            XCTAssertEqual(try reopened.captureReservations(limit: 8).first?.snapshot?.vscodeWorkspaceContext, context)
            XCTAssertNotNil(try reopened.finishCapture(reserved, capture: captured.capture))
        }
    }

    func testVSCodeReservationCorruptContextFailsClosedAndPreservesRow() throws {
        for corruption in ["digest", "missing", "noncanonical"] {
            let f = try VSCodePersistenceFixture(); defer { f.close() }
            let store = try f.open()
            let captured = try f.capture()
            _ = try XCTUnwrap(store.reserveCapture(f.claim(store), configuration: f.configuration,
                generation: captured.manifest.generation, snapshot: f.snapshot(captured)))
            try f.database.write { db in
                switch corruption {
                case "digest": try db.execute(sql: "UPDATE collector_capture_reservations SET vscode_context_sha256 = ?",
                    arguments: [String(repeating: "0", count: 64)])
                case "missing": try db.execute(sql: "UPDATE collector_capture_reservations SET vscode_context_bytes = NULL")
                default:
                    var bytes = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT vscode_context_bytes FROM collector_capture_reservations"))
                    bytes.append(32)
                    try db.execute(sql: "UPDATE collector_capture_reservations SET vscode_context_bytes = ?, vscode_context_sha256 = ?",
                        arguments: [bytes, ArchiveV2Hash.sha256(bytes)])
                }
            }
            XCTAssertThrowsError(try store.captureReservations(limit: 8), corruption)
            XCTAssertEqual(try f.database.read { try Int.fetchOne($0,
                sql: "SELECT count(*) FROM collector_capture_reservations") }, 1)
        }
    }
}

private final class VSCodePersistenceFixture {
    let base: URL
    let source: URL
    let root: URL
    let cas: ImmutableArchiveCAS
    let catalog: ArchiveCatalog
    var database: DatabaseQueue
    let machineID = "11111111-2222-3333-4444-555555555555"
    let relative = "ws/chatSessions/chat.jsonl"
    var configuration: CollectorRootConfiguration { .init(rootID: "vscode", source: .vscode, rootPath: root.path, revision: 1) }
    var context: ArchiveVSCodeWorkspaceContext { get throws {
        try makeContext(Data(#"{"folders":[{"path":"project"}]}"#.utf8))
    } }
    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vscode-persist-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil)); defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        source = base.appendingPathComponent("source"); root = source.appendingPathComponent("workspaceStorage")
        let primary = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"kind":0,"v":{"sessionId":"chat","requests":[]}}"# + "\n").utf8).write(to: primary)
        try JSONSerialization.data(withJSONObject: ["configuration": source.appendingPathComponent("project.code-workspace").absoluteString])
            .write(to: root.appendingPathComponent("ws/workspace.json"))
        database = try DatabaseQueue(path: base.appendingPathComponent("inventory.sqlite").path)
        let archive = base.appendingPathComponent("archive")
        cas = try ImmutableArchiveCAS(root: archive)
        catalog = try ArchiveCatalog(root: archive, machineID: machineID)
        try catalog.migrate()
    }
    func makeContext(_ bytes: Data) throws -> ArchiveVSCodeWorkspaceContext {
        try ArchiveVSCodeWorkspaceContext(configurationLocator: source.appendingPathComponent("project.code-workspace").path,
            configurationGeneration: ArchiveSourceGeneration(device: 1, inode: 2, size: Int64(bytes.count),
                mtimeNs: 1, ctimeNs: 1, mode: 0o100600), configurationData: bytes,
            configurationSHA256: ArchiveV2Hash.sha256(bytes))
    }
    func open(owner: String = "run-1", hooks: CollectorInventoryStoreTestHooks = .init()) throws -> CollectorInventoryStore {
        let store = try CollectorInventoryStore(database: database, machineID: machineID, ownerRunID: owner, testHooks: hooks)
        try store.registerRoot(configuration)
        try store.enrollRoot(binding: .init(configuration: configuration,
            expectedIdentity: .init(device: 1, inode: 2, generation: 0, birthSeconds: 1, birthNanoseconds: 0)))
        XCTAssertNotNil(try store.activateEnrolledRoot(configuration: configuration))
        return store
    }
    func claim(_ store: CollectorInventoryStore) throws -> CollectorDirtyClaim {
        try store.markDirty(configuration: configuration, relativePath: relative)
        return try XCTUnwrap(store.claimDirty(configuration: configuration, limit: 1, now: 100).first)
    }
    func capture(context override: ArchiveVSCodeWorkspaceContext? = nil) throws -> ArchiveCaptureResult {
        let primary = root.appendingPathComponent(relative)
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: root,
            files: [primary, root.appendingPathComponent("ws/workspace.json")],
            vscodeWorkspaceContext: override ?? context)
        return try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .vscode, locator: primary.path, machineID: machineID)
    }
    func snapshot(_ capture: ArchiveCaptureResult) throws -> CollectorDependencySnapshot {
        CollectorDependencySnapshot(entrypointRelativePath: relative,
            present: try XCTUnwrap(capture.manifest.replayLayout.files).map { .init(relativePath: $0.relativePath, generation: $0.generation) },
            absentRelativePaths: capture.manifest.replayLayout.absentRelativePaths ?? [],
            vscodeWorkspaceContext: capture.manifest.replayLayout.vscodeWorkspaceContext)
    }
    func reopen() throws {
        try database.close()
        database = try DatabaseQueue(path: base.appendingPathComponent("inventory.sqlite").path)
    }
    func close() { try? catalog.close(); try? database.close(); try? FileManager.default.removeItem(at: base) }
}
