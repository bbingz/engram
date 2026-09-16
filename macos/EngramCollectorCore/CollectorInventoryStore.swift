import Foundation
import GRDB

struct CollectorInventoryStoreTestHooks {
    var beforeCommit: (() throws -> Void)?
}

// This domain receives an already-owned queue; it has no
// live-path opener and does not open the product index or an archive catalog.
final class CollectorInventoryStore {
    private let database: DatabaseQueue
    private let machineID: String
    private let ownerRunID: String
    private let testHooks: CollectorInventoryStoreTestHooks
    // Accessed only on the database queue; a scheduling hint, not durable work state.
    private var publicationRootAfter: [String: String] = [:]

    init(
        database: DatabaseQueue,
        machineID: String,
        ownerRunID: String,
        testHooks: CollectorInventoryStoreTestHooks = .init()
    ) throws {
        self.database = database
        self.machineID = machineID
        self.ownerRunID = ownerRunID
        self.testHooks = testHooks
        guard UUID(uuidString: machineID) != nil, !ownerRunID.isEmpty else {
            throw CollectorInventoryError.invalidState
        }
        try database.writeWithoutTransaction { db in
            let needsStreamMigration = try db.tableExists("collector_streams")
                && !db.columns(in: "collector_streams").contains { $0.name == "effective_source" }
            let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0
            if needsStreamMigration { try db.execute(sql: "PRAGMA foreign_keys = OFF") }
            do {
                try db.inTransaction {
                    try Self.createSchema(db)
                    let storedMachineID = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'machine_id'")
                    guard storedMachineID == nil || storedMachineID == machineID else {
                        throw CollectorInventoryError.machineIDMismatch
                    }
                    if let version = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'schema_version'"),
                       version != "1", version != "2" {
                        throw CollectorInventoryError.invalidState
                    }
                    if let version = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'publication_schema_version'"),
                       version != "1", version != "2", version != "3", version != "4", version != "5", version != "6", version != "7", version != "8", version != "9", version != "10", version != "11" {
                        throw CollectorInventoryError.invalidState
                    }
                    try Self.createPublicationSchema(db)
                    try Self.migrateGeminiContextColumns(db)
                    try Self.migrateGeminiRegistryObserverColumns(db)
                    try Self.migrateOpenCodeWalkColumns(db)
                    try Self.migrateKimiContextColumns(db)
                    try Self.migrateVSCodeContextColumns(db)
                    try Self.migrateCursorLegacyColumns(db)
                    if needsStreamMigration { try Self.migrateEffectiveSourceStreams(db) }
                    for (key, value) in [("schema_version", "2"), ("machine_id", machineID), ("active_owner_run_id", ownerRunID)] {
                        try db.execute(
                            sql: "INSERT INTO collector_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                            arguments: [key, value]
                        )
                    }
                    try db.execute(sql: """
                        INSERT INTO collector_metadata(key, value) VALUES ('publication_schema_version', '11')
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """)
                    try testHooks.beforeCommit?()
                    if needsStreamMigration, !(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")).isEmpty {
                        throw CollectorInventoryError.invalidState
                    }
                    return .commit
                }
            } catch {
                if needsStreamMigration { try db.execute(sql: "PRAGMA foreign_keys = \(foreignKeys)") }
                throw error
            }
            if needsStreamMigration { try db.execute(sql: "PRAGMA foreign_keys = \(foreignKeys)") }
        }
    }

    func registerRoot(_ configuration: CollectorRootConfiguration) throws {
        guard !configuration.rootID.isEmpty, configuration.revision > 0, configuration.validCursorLayout,
              configuration.rootPath.hasPrefix("/"),
              Self.isSafeRelativePath(String(configuration.rootPath.dropFirst())) else {
            throw CollectorInventoryError.invalidRoot
        }
        try write { db in
            if let existing = try Self.rootState(db, rootID: configuration.rootID) {
                if existing.configuration == configuration { return }
                guard configuration.revision > existing.configuration.revision else {
                    throw CollectorInventoryError.invalidRoot
                }
                // Old locator/frontier rows remain fenced by their revision.
                // Do not turn a root configuration change into a full-table reset.
                try db.execute(sql: """
                    UPDATE collector_roots SET source = ?, root_path = ?, root_revision = ?, cursor_legacy = ?, cursor_modern_root_id = ?,
                        requested_revision = 1, completed_revision = 0, event_epoch = NULL,
                        event_cursor = NULL, active_scan_id = NULL, active_scan_requested_revision = NULL,
                        last_scan_failure = NULL, claim_cursor = NULL,
                        gemini_registry_locator = NULL, gemini_registry_generation = NULL,
                        gemini_registry_page_after = NULL,
                        opencode_walk_generation = NULL, opencode_walk_wal_generation = NULL,
                        opencode_walk_page_after = NULL,
                        cursor_legacy_walk_generation = NULL, cursor_legacy_walk_wal_generation = NULL,
                        cursor_legacy_walk_page_after = NULL, cursor_legacy_walk_dirty_revision = NULL,
                        cursor_legacy_observer_membership = NULL, cursor_legacy_observer_main = NULL,
                        cursor_legacy_observer_peer = NULL, cursor_legacy_observer_after = NULL,
                        cursor_legacy_observer_error = NULL, cursor_legacy_observer_initialized = 0 WHERE root_id = ?
                    """, arguments: [configuration.source.rawValue, configuration.rootPath, configuration.revision, configuration.cursorLegacy, configuration.cursorModernRootID, configuration.rootID])
            } else {
                try db.execute(sql: """
                    INSERT INTO collector_roots(root_id, source, root_path, root_revision, cursor_legacy, cursor_modern_root_id, requested_revision, completed_revision)
                    VALUES (?, ?, ?, ?, ?, ?, 1, 0)
                    """, arguments: [configuration.rootID, configuration.source.rawValue, configuration.rootPath, configuration.revision, configuration.cursorLegacy, configuration.cursorModernRootID])
            }
        }
    }

    func enrollRoot(binding: CollectorPOSIXRootBinding) throws {
        try write { db in
            try Self.requireRoot(db, binding.configuration)
            let identity = binding.expectedIdentity
            guard (0..<1_000_000_000).contains(identity.birthNanoseconds) else {
                throw CollectorInventoryError.invalidRoot
            }
            if let existing = try Self.rootBinding(db, binding.configuration) {
                guard existing.binding.expectedIdentity == identity else {
                    throw CollectorInventoryError.invalidRoot
                }
                return
            }
            try db.execute(sql: """
                INSERT INTO collector_root_bindings(
                    root_id, root_revision, device, inode, generation, birth_seconds, birth_nanoseconds
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    binding.configuration.rootID, binding.configuration.revision, identity.device, identity.inode,
                    Int64(identity.generation), identity.birthSeconds, identity.birthNanoseconds,
                ])
        }
    }

    func enrolledRoot(configuration: CollectorRootConfiguration) throws -> CollectorPOSIXRootBinding? {
        try database.read { db in
            try Self.requireRoot(db, configuration)
            return try Self.rootBinding(db, configuration)?.binding
        }
    }

    func activateEnrolledRoot(configuration: CollectorRootConfiguration) throws -> CollectorPOSIXRootBinding? {
        try write { db in
            let state = try Self.requireRoot(db, configuration)
            guard let stored = try Self.rootBinding(db, configuration) else { return nil }
            if stored.lastActivatedOwnerRunID?.utf8.elementsEqual(ownerRunID.utf8) == true {
                return stored.binding
            }
            try db.execute(
                sql: "UPDATE collector_roots SET requested_revision = ? WHERE root_id = ?",
                arguments: [Self.increment(state.requestedRevision), configuration.rootID]
            )
            try db.execute(sql: """
                UPDATE collector_root_bindings SET last_activated_owner_run_id = ?
                WHERE root_id = ? AND root_revision = ?
                """, arguments: [ownerRunID, configuration.rootID, configuration.revision])
            return stored.binding
        }
    }

    func rootState(rootID: String) throws -> CollectorRootState? {
        try database.read { try Self.rootState($0, rootID: rootID) }
    }

    func cursorLegacyOwnershipAfter(configuration: CollectorRootConfiguration) throws -> String? {
        try database.read { db in
            try requirePublicationOwner(db)
            try Self.requireRoot(db, configuration)
            guard configuration.cursorLegacy else { throw CollectorInventoryError.invalidState }
            return try String.fetchOne(db, sql: "SELECT cursor_legacy_observer_after FROM collector_roots WHERE root_id = ?",
                arguments: [configuration.rootID])
        }
    }

    func recordCursorLegacyObservationFailure(configuration: CollectorRootConfiguration, fingerprint: String) throws {
        guard ArchiveV2Hash.isValidSHA256(fingerprint) else { throw CollectorInventoryError.invalidState }
        try write { db in
            try Self.requireRoot(db, configuration)
            guard configuration.cursorLegacy else { throw CollectorInventoryError.invalidState }
            let previous = try String.fetchOne(db, sql: "SELECT cursor_legacy_observer_error FROM collector_roots WHERE root_id = ?",
                arguments: [configuration.rootID])
            guard previous != fingerprint else { return }
            try Self.upsertDirty(db, configuration, "state.vscdb", observedGeneration: nil, seenScanID: nil)
            try db.execute(sql: "UPDATE collector_roots SET cursor_legacy_observer_error = ? WHERE root_id = ?",
                arguments: [fingerprint, configuration.rootID])
        }
    }

    @discardableResult
    func applyCursorLegacyObservation(
        configuration: CollectorRootConfiguration, after: String?, membershipFingerprint: String,
        workspaces: [(workspaceID: String, fingerprint: String)], nextAfter: String?,
        mainFingerprint: String, peerFingerprint: String
    ) throws -> Bool {
        func validID(_ value: String) -> Bool {
            Self.isSafeRelativePath(value) && !value.contains("/") && value.utf8.count <= 255 && !value.hasPrefix(".")
        }
        guard [membershipFingerprint, mainFingerprint, peerFingerprint].allSatisfy(ArchiveV2Hash.isValidSHA256),
              workspaces.count <= 64, after.map(validID) ?? true, nextAfter.map(validID) ?? true,
              workspaces.allSatisfy({ validID($0.workspaceID) && ArchiveV2Hash.isValidSHA256($0.fingerprint) }),
              Set(workspaces.map { Data($0.workspaceID.utf8) }).count == workspaces.count,
              zip(workspaces, workspaces.dropFirst()).allSatisfy({
                  Data($0.0.workspaceID.utf8).lexicographicallyPrecedes(Data($0.1.workspaceID.utf8))
              }),
              after.map({ start in workspaces.allSatisfy { Data(start.utf8).lexicographicallyPrecedes(Data($0.workspaceID.utf8)) } }) ?? true,
              nextAfter.map({ next in workspaces.last?.workspaceID.utf8.elementsEqual(next.utf8) == true }) ?? true else {
            throw CollectorInventoryError.invalidState
        }
        return try write { db in
            try Self.requireRoot(db, configuration)
            guard configuration.cursorLegacy,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM collector_roots WHERE root_id = ?",
                    arguments: [configuration.rootID]) else { throw CollectorInventoryError.invalidState }
            let storedAfter: String? = row["cursor_legacy_observer_after"]
            guard storedAfter.map({ Data($0.utf8) }) == after.map({ Data($0.utf8) }) else { return false }
            let oldMembership: String? = row["cursor_legacy_observer_membership"]
            let oldMain: String? = row["cursor_legacy_observer_main"]
            let oldPeer: String? = row["cursor_legacy_observer_peer"]
            let oldError: String? = row["cursor_legacy_observer_error"]
            let oldInitialized: Int = row["cursor_legacy_observer_initialized"]
            let membershipChanged = oldMembership != membershipFingerprint
            var changed = membershipChanged || oldPeer != peerFingerprint || oldError != nil
            var initialized = oldInitialized == 1 && !membershipChanged
            if membershipChanged {
                try db.execute(sql: "DELETE FROM collector_cursor_legacy_workspaces WHERE root_id = ? AND root_revision = ?",
                    arguments: [configuration.rootID, configuration.revision])
            }
            // Membership changes invalidate the old page cursor. Restart at the
            // first ID before declaring a new membership pass initialized.
            let restart = membershipChanged && after != nil
            if !restart {
                for workspace in workspaces {
                    let previous = try String.fetchOne(db, sql: """
                        SELECT fingerprint FROM collector_cursor_legacy_workspaces
                        WHERE root_id = ? AND root_revision = ? AND workspace_id = ?
                        """, arguments: [configuration.rootID, configuration.revision, workspace.workspaceID])
                    if previous != workspace.fingerprint, previous != nil || initialized { changed = true }
                    if previous != workspace.fingerprint {
                        try db.execute(sql: """
                            INSERT INTO collector_cursor_legacy_workspaces(root_id, root_revision, workspace_id, fingerprint)
                            VALUES (?, ?, ?, ?) ON CONFLICT(root_id, root_revision, workspace_id)
                            DO UPDATE SET fingerprint = excluded.fingerprint
                            """, arguments: [configuration.rootID, configuration.revision, workspace.workspaceID, workspace.fingerprint])
                    }
                }
                if nextAfter == nil, !initialized { changed = true; initialized = true }
            }
            if oldMain != mainFingerprint {
                let pending = try Self.locatorRow(db, configuration, "state.vscdb").map { row -> Bool in
                    let dirty: Int64 = row["dirty_revision"], acknowledged: Int64 = row["acknowledged_revision"]
                    return dirty > acknowledged
                } ?? false
                if !pending { changed = true }
            }
            if changed { try Self.upsertDirty(db, configuration, "state.vscdb", observedGeneration: nil, seenScanID: nil) }
            try db.execute(sql: """
                UPDATE collector_roots SET cursor_legacy_observer_membership = ?, cursor_legacy_observer_main = ?,
                    cursor_legacy_observer_peer = ?, cursor_legacy_observer_after = ?,
                    cursor_legacy_observer_error = NULL, cursor_legacy_observer_initialized = ? WHERE root_id = ?
                """, arguments: [membershipFingerprint, mainFingerprint, peerFingerprint,
                    restart ? nil : nextAfter, initialized ? 1 : 0, configuration.rootID])
            return true
        }
    }

    func lastCursorLegacyCapture(configuration: CollectorRootConfiguration, composerID: String) throws -> String? {
        try database.read { db in
            try requirePublicationOwner(db)
            try Self.requireRoot(db, configuration)
            guard configuration.source == .cursor, Self.validCursorComposerID(composerID) else {
                throw CollectorInventoryError.invalidState
            }
            return try String.fetchOne(db, sql: """
                SELECT capture_id FROM collector_cursor_legacy_sessions
                WHERE root_id = ? AND root_revision = ? AND composer_id = ?
                """, arguments: [configuration.rootID, configuration.revision, composerID])
        }
    }

    func advanceCursorLegacySkippedSession(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration,
        generation: ArchiveSourceGeneration, session: ArchiveCursorLegacyContext,
        previousCaptureID: String?
    ) throws {
        try write { db in
            try requirePublicationRoot(db, configuration)
            guard claim.rootID.utf8.elementsEqual(configuration.rootID.utf8),
                  claim.rootRevision == configuration.revision, try currentClaimRow(db, claim) != nil else {
                throw CollectorInventoryError.invalidState
            }
            try Self.requireValidCursorLegacySession(session, configuration: configuration, relativePath: claim.relativePath)
            try Self.requireCursorLegacySessionAfterCursor(db, configuration: configuration,
                generation: generation, session: session, dirtyRevision: claim.dirtyRevision)
            guard try Row.fetchOne(db, sql: "SELECT 1 FROM collector_capture_reservations WHERE root_id = ? AND root_revision = ?",
                arguments: [configuration.rootID, configuration.revision]) == nil else {
                throw CollectorInventoryError.invalidState
            }
            if let previousCaptureID {
                guard ArchiveV2Hash.isValidSHA256(previousCaptureID),
                      try String.fetchOne(db, sql: """
                        SELECT capture_id FROM collector_cursor_legacy_sessions
                        WHERE root_id = ? AND root_revision = ? AND composer_id = ?
                        """, arguments: [configuration.rootID, configuration.revision, session.composerID]) == previousCaptureID else {
                    throw CollectorInventoryError.invalidState
                }
            } else {
                guard configuration.cursorLegacy, configuration.cursorModernRootID != nil else {
                    throw CollectorInventoryError.invalidState
                }
            }
            try Self.saveCursorLegacyWalk(db, rootID: configuration.rootID, generation: generation,
                walGeneration: session.walGeneration, pageAfter: session.composerID, dirtyRevision: claim.dirtyRevision)
        }
    }

    func reconcileCursorLegacyWalk(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration,
        generation: ArchiveSourceGeneration, walGeneration: ArchiveSourceGeneration?
    ) throws -> String? {
        try write { db in
            try Task.checkCancellation()
            try requirePublicationRoot(db, configuration)
            guard configuration.source == .cursor, claim.relativePath == "state.vscdb",
                  claim.rootID.utf8.elementsEqual(configuration.rootID.utf8),
                  claim.rootRevision == configuration.revision,
                  Self.isSafeRelativePath(claim.relativePath),
                  try currentClaimRow(db, claim) != nil else {
                throw CollectorInventoryError.invalidState
            }
            try Self.requireRegularGeneration(generation)
            if let walGeneration { try Self.requireRegularGeneration(walGeneration) }
            let stored = try Self.cursorLegacyWalk(db, rootID: configuration.rootID)
            if stored.generation == generation, stored.walGeneration == walGeneration, stored.dirtyRevision == claim.dirtyRevision {
                return stored.pageAfter
            }
            try Self.saveCursorLegacyWalk(
                db, rootID: configuration.rootID, generation: generation,
                walGeneration: walGeneration, pageAfter: nil, dirtyRevision: claim.dirtyRevision
            )
            return nil
        }
    }

    func finishCursorLegacyWalk(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration,
        generation: ArchiveSourceGeneration, walGeneration: ArchiveSourceGeneration?
    ) throws -> CollectorClaimCompletion {
        try write { db in
            try Task.checkCancellation()
            try requirePublicationRoot(db, configuration)
            guard configuration.source == .cursor, claim.relativePath == "state.vscdb",
                  claim.rootID.utf8.elementsEqual(configuration.rootID.utf8),
                  claim.rootRevision == configuration.revision,
                  Self.isSafeRelativePath(claim.relativePath),
                  let locator = try currentClaimRow(db, claim) else {
                throw CollectorInventoryError.invalidState
            }
            let stored = try Self.cursorLegacyWalk(db, rootID: configuration.rootID)
            guard stored.generation == generation, stored.walGeneration == walGeneration, stored.dirtyRevision == claim.dirtyRevision else {
                throw CollectorInventoryError.invalidState
            }
            if try Row.fetchOne(db, sql: """
                SELECT 1 FROM collector_capture_reservations WHERE root_id = ? AND root_revision = ?
                """, arguments: [configuration.rootID, configuration.revision]) != nil {
                throw CollectorInventoryError.invalidState
            }
            let dirtyRevision: Int64 = locator["dirty_revision"]
            try db.execute(sql: """
                UPDATE collector_locators SET acknowledged_revision = ?,
                    claimed_dirty_revision = NULL, claim_owner_run_id = NULL,
                    retry_not_before = NULL, last_error = NULL
                WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [claim.dirtyRevision, claim.rootID, claim.rootRevision, claim.relativePath])
            return dirtyRevision > claim.dirtyRevision ? .newerWorkPending : .acknowledged
        }
    }

    func reconcileOpenCodeWalk(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration,
        generation: ArchiveSourceGeneration, walGeneration: ArchiveSourceGeneration?
    ) throws -> String? {
        try write { db in
            try Task.checkCancellation()
            try requirePublicationRoot(db, configuration)
            guard configuration.source == .opencode, claim.relativePath == "opencode.db",
                  claim.rootID.utf8.elementsEqual(configuration.rootID.utf8),
                  claim.rootRevision == configuration.revision,
                  Self.isSafeRelativePath(claim.relativePath),
                  try currentClaimRow(db, claim) != nil else {
                throw CollectorInventoryError.invalidState
            }
            try Self.requireRegularGeneration(generation)
            if let walGeneration { try Self.requireRegularGeneration(walGeneration) }
            let stored = try Self.openCodeWalk(db, rootID: configuration.rootID)
            if stored.generation == generation, stored.walGeneration == walGeneration {
                return stored.pageAfter
            }
            try Self.saveOpenCodeWalk(
                db, rootID: configuration.rootID, generation: generation,
                walGeneration: walGeneration, pageAfter: nil
            )
            return nil
        }
    }

    func finishOpenCodeWalk(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration,
        generation: ArchiveSourceGeneration, walGeneration: ArchiveSourceGeneration?
    ) throws -> CollectorClaimCompletion {
        try write { db in
            try Task.checkCancellation()
            try requirePublicationRoot(db, configuration)
            guard configuration.source == .opencode, claim.relativePath == "opencode.db",
                  claim.rootID.utf8.elementsEqual(configuration.rootID.utf8),
                  claim.rootRevision == configuration.revision,
                  Self.isSafeRelativePath(claim.relativePath),
                  let locator = try currentClaimRow(db, claim) else {
                throw CollectorInventoryError.invalidState
            }
            let stored = try Self.openCodeWalk(db, rootID: configuration.rootID)
            guard stored.generation == generation, stored.walGeneration == walGeneration else {
                throw CollectorInventoryError.invalidState
            }
            if try Row.fetchOne(db, sql: """
                SELECT 1 FROM collector_capture_reservations WHERE root_id = ? AND root_revision = ?
                """, arguments: [configuration.rootID, configuration.revision]) != nil {
                throw CollectorInventoryError.invalidState
            }
            let dirtyRevision: Int64 = locator["dirty_revision"]
            try db.execute(sql: """
                UPDATE collector_locators SET acknowledged_revision = ?,
                    claimed_dirty_revision = NULL, claim_owner_run_id = NULL,
                    retry_not_before = NULL, last_error = NULL
                WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [claim.dirtyRevision, claim.rootID, claim.rootRevision, claim.relativePath])
            return dirtyRevision > claim.dirtyRevision ? .newerWorkPending : .acknowledged
        }
    }

    func claimFileSetPrimary(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration, snapshot: CollectorDependencySnapshot
    ) throws -> CollectorDirtyClaim? {
        try write { db in
            try requirePublicationRoot(db, configuration)
            guard claim.rootID.utf8.elementsEqual(configuration.rootID.utf8), claim.rootRevision == configuration.revision else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            if configuration.source == .cline {
                try CollectorClineSource.requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)
                let alias = claim.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                let primary = snapshot.entrypointRelativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard CollectorClineSource.isSelectedPrimary(rootPath: "", components: alias),
                      alias[0].utf8.elementsEqual(primary[0].utf8) else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
            } else if configuration.source == .copilot {
                try CollectorCopilotSource.requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)
                guard let aliasSession = CollectorCopilotSource.sessionName(fromPrimary: claim.relativePath),
                      let primarySession = CollectorCopilotSource.sessionName(fromPrimary: snapshot.entrypointRelativePath),
                      aliasSession.utf8.elementsEqual(primarySession.utf8) else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
            } else {
                guard configuration.source == .cursor,
                      snapshot.present.contains(where: { $0.relativePath.utf8.elementsEqual(claim.relativePath.utf8) }) else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                try CollectorCursorSource.requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)
            }
            guard try currentClaimRow(db, claim) != nil else { return nil }
            let primary = snapshot.entrypointRelativePath
            if primary.utf8.elementsEqual(claim.relativePath.utf8) { return claim }
            if let row = try Self.locatorRow(db, configuration, primary) {
                let owner: String? = row["claim_owner_run_id"]
                let claimed: Int64? = row["claimed_dirty_revision"]
                if claimed != nil, owner?.utf8.elementsEqual(ownerRunID.utf8) == true { return nil }
                let dirty: Int64 = row["dirty_revision"], acknowledged: Int64 = row["acknowledged_revision"]
                if dirty <= acknowledged {
                    try Self.upsertDirty(db, configuration, primary, observedGeneration: nil, seenScanID: nil)
                }
            } else {
                try Self.upsertDirty(db, configuration, primary, observedGeneration: nil, seenScanID: nil)
            }
            guard let row = try Self.locatorRow(db, configuration, primary) else { throw CollectorInventoryError.invalidState }
            let dirty: Int64 = row["dirty_revision"]
            let generation = try Self.increment(row["claim_generation"])
            try db.execute(sql: """
                UPDATE collector_locators SET claim_owner_run_id = ?, claim_generation = ?, claimed_dirty_revision = ?,
                    retry_not_before = NULL WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [ownerRunID, generation, dirty, configuration.rootID, configuration.revision, primary])
            return .init(rootID: configuration.rootID, rootRevision: configuration.revision, relativePath: primary,
                dirtyRevision: dirty, ownerRunID: ownerRunID, claimGeneration: generation)
        }
    }

    func claimClinePendingAlias(
        _ primary: CollectorDirtyClaim, configuration: CollectorRootConfiguration
    ) throws -> CollectorDirtyClaim? {
        try write { db in
            try requirePublicationRoot(db, configuration)
            let parts = primary.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard configuration.source == .cline,
                  primary.rootID.utf8.elementsEqual(configuration.rootID.utf8), primary.rootRevision == configuration.revision,
                  CollectorClineSource.isSelectedPrimary(rootPath: "", components: parts) else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            guard try currentClaimRow(db, primary) != nil else { return nil }
            let path = parts[0] + "/" + (parts[1] == CollectorClineSource.uiName ? CollectorClineSource.legacyName : CollectorClineSource.uiName)
            guard let row = try Self.locatorRow(db, configuration, path) else { return nil }
            let dirty: Int64 = row["dirty_revision"], acknowledged: Int64 = row["acknowledged_revision"]
            let claimed: Int64? = row["claimed_dirty_revision"], owner: String? = row["claim_owner_run_id"]
            guard dirty > acknowledged, claimed == nil || owner?.utf8.elementsEqual(ownerRunID.utf8) != true else { return nil }
            let generation = try Self.increment(row["claim_generation"])
            try db.execute(sql: """
                UPDATE collector_locators SET claim_owner_run_id = ?, claim_generation = ?, claimed_dirty_revision = ?,
                    retry_not_before = NULL WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [ownerRunID, generation, dirty, configuration.rootID, configuration.revision, path])
            return .init(rootID: configuration.rootID, rootRevision: configuration.revision, relativePath: path,
                dirtyRevision: dirty, ownerRunID: ownerRunID, claimGeneration: generation)
        }
    }

    func reserveCapture(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration,
        generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot? = nil,
        sqliteSession: ArchiveSQLiteSessionContext? = nil, cursorLegacySession: ArchiveCursorLegacyContext? = nil, effectiveSource: SourceName? = nil,
        allowExisting: Bool = true
    ) throws -> CollectorCaptureReservation? {
        return try write { db in
            try Task.checkCancellation()
            try requirePublicationRoot(db, configuration)
            let source = effectiveSource ?? configuration.source
            guard snapshot?.vscodeWorkspaceContext == nil || configuration.source == .vscode else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            guard Self.validEffectiveSource(source, configuration: configuration) else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            guard claim.rootID.utf8.elementsEqual(configuration.rootID.utf8),
                  claim.rootRevision == configuration.revision,
                  Self.isSafeRelativePath(claim.relativePath),
                  let locator = try currentClaimRow(db, claim) else { return nil }
            let acknowledged: Int64 = locator["acknowledged_revision"]
            guard claim.dirtyRevision > acknowledged else { return nil }
            let generationBytes = try ArchiveCanonicalJSON.encode(generation)
            guard generationBytes.count <= 2_048, generation.mode & 0o170000 == 0o100000 else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            if let legacy = cursorLegacySession {
                guard snapshot == nil, sqliteSession == nil else { throw CollectorPublicationWorkerError.invalidCapture }
                try Self.requireValidCursorLegacySession(legacy, configuration: configuration, relativePath: claim.relativePath)
                try Self.requireCursorLegacySessionAfterCursor(db, configuration: configuration,
                    generation: generation, session: legacy, dirtyRevision: claim.dirtyRevision)
            } else if configuration.source == .cursor {
                guard let snapshot, sqliteSession == nil else { throw CollectorPublicationWorkerError.invalidCapture }
                try CollectorCursorSource.requireValidSnapshot(snapshot, entrypoint: claim.relativePath)
                guard snapshot.present.contains(where: {
                    $0.relativePath.utf8.elementsEqual(claim.relativePath.utf8) && $0.generation == generation
                }) else { throw CollectorPublicationWorkerError.invalidCapture }
            } else if configuration.source == .copilot || configuration.source == .cline {
                guard let snapshot, sqliteSession == nil, snapshot.kimiProjectContext == nil else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                if configuration.source == .cline {
                    try CollectorClineSource.requireValidSnapshot(snapshot, entrypoint: claim.relativePath)
                } else {
                    try CollectorCopilotSource.requireValidSnapshot(snapshot, entrypoint: claim.relativePath)
                }
                guard snapshot.present.contains(where: {
                    $0.relativePath.utf8.elementsEqual(claim.relativePath.utf8) && $0.generation == generation
                }) else { throw CollectorPublicationWorkerError.invalidCapture }
            } else if configuration.source == .geminiCli {
                guard let snapshot, sqliteSession == nil, snapshot.kimiProjectContext == nil else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                try CollectorGeminiSource.requireValidSnapshot(snapshot, entrypoint: claim.relativePath)
                guard snapshot.present.contains(where: {
                    $0.relativePath.utf8.elementsEqual(claim.relativePath.utf8) && $0.generation == generation
                }) else { throw CollectorPublicationWorkerError.invalidCapture }
            } else if configuration.source == .vscode {
                guard let snapshot, sqliteSession == nil else { throw CollectorPublicationWorkerError.invalidCapture }
                try CollectorVSCodeSource.requireValidSnapshot(snapshot, entrypoint: claim.relativePath)
                guard snapshot.present.contains(where: {
                    $0.relativePath.utf8.elementsEqual(claim.relativePath.utf8) && $0.generation == generation
                }) else { throw CollectorPublicationWorkerError.invalidCapture }
            } else if configuration.source == .kimi {
                guard let snapshot, sqliteSession == nil, snapshot.geminiProjectContext == nil,
                      snapshot.kimiProjectContext != nil else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                try CollectorKimiSource.requireValidSnapshot(snapshot, entrypoint: claim.relativePath)
                guard snapshot.present.contains(where: {
                    $0.relativePath.utf8.elementsEqual(claim.relativePath.utf8) && $0.generation == generation
                }) else { throw CollectorPublicationWorkerError.invalidCapture }
            } else if configuration.source == .grok {
                guard let snapshot, sqliteSession == nil, snapshot.kimiProjectContext == nil,
                      snapshot.geminiProjectContext == nil else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                try CollectorGrokSource.requireValidSnapshot(snapshot, entrypoint: claim.relativePath)
                guard snapshot.present.contains(where: {
                    $0.relativePath.utf8.elementsEqual(claim.relativePath.utf8) && $0.generation == generation
                }) else { throw CollectorPublicationWorkerError.invalidCapture }
            } else if configuration.source == .opencode {
                guard snapshot == nil, let sqliteSession else { throw CollectorPublicationWorkerError.invalidCapture }
                try Self.requireValidSQLiteSession(
                    sqliteSession, configuration: configuration, relativePath: claim.relativePath
                )
                try Self.requireOpenCodeSessionAfterCursor(
                    db, configuration: configuration, generation: generation, session: sqliteSession
                )
            } else if snapshot != nil || sqliteSession != nil {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            if let pending = try Row.fetchOne(db, sql: """
                SELECT * FROM collector_capture_reservations WHERE root_id = ? AND root_revision = ?
                """, arguments: [configuration.rootID, configuration.revision]) {
                guard allowExisting else { return nil }
                let reservation = try Self.reservation(pending, db: db)
                let owner: String = pending["dirty_claim_owner_run_id"]
                let claimGeneration: Int64 = pending["dirty_claim_generation"]
                guard reservation.relativePath.utf8.elementsEqual(claim.relativePath.utf8),
                      reservation.dirtyRevision == claim.dirtyRevision, reservation.generation == generation,
                      reservation.snapshot == snapshot, reservation.sqliteSession == sqliteSession,
                      reservation.cursorLegacySession == cursorLegacySession, reservation.effectiveSource == source,
                      (configuration.source != .cursor || CollectorCursorSource.reservedPathsEqual(reservation.snapshot, snapshot)),
                      owner.utf8.elementsEqual(claim.ownerRunID.utf8), claimGeneration == claim.claimGeneration else { return nil }
                return reservation
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO collector_streams(root_id, root_revision, effective_source, source_instance_id, collector_epoch, last_sequence)
                VALUES (?, ?, ?, ?, ?, 0)
                """, arguments: [configuration.rootID, configuration.revision, source.rawValue, UUID().uuidString, UUID().uuidString])
            guard let stream = try Row.fetchOne(db, sql: "SELECT * FROM collector_streams WHERE root_id = ? AND root_revision = ? AND effective_source = ?",
                arguments: [configuration.rootID, configuration.revision, source.rawValue]) else { throw CollectorInventoryError.invalidState }
            let previous: Int64 = stream["last_sequence"]
            let (sequence, overflow) = previous.addingReportingOverflow(1)
            guard previous >= 0, !overflow, sequence > 0 else { throw CollectorPublicationWorkerError.sequenceExhausted }
            let sourceInstanceID: String = stream["source_instance_id"]
            let collectorEpoch: String = stream["collector_epoch"]
            guard UUID(uuidString: sourceInstanceID) != nil, UUID(uuidString: collectorEpoch) != nil else {
                throw CollectorInventoryError.invalidState
            }
            let reservation = CollectorCaptureReservation(id: UUID().uuidString, rootID: configuration.rootID,
                rootRevision: configuration.revision, relativePath: claim.relativePath, dirtyRevision: claim.dirtyRevision,
                generation: generation, sourceInstanceID: sourceInstanceID, collectorEpoch: collectorEpoch, sequence: sequence, effectiveSource: source)
            try db.execute(sql: "UPDATE collector_streams SET last_sequence = ? WHERE root_id = ? AND root_revision = ? AND effective_source = ?",
                arguments: [sequence, configuration.rootID, configuration.revision, source.rawValue])
            let context = try Self.encodeGeminiContext(snapshot?.geminiProjectContext)
            let kimi = try Self.encodeKimiContext(snapshot?.kimiProjectContext)
            let session = try Self.encodeSQLiteSession(sqliteSession)
            let legacy = try Self.encodeCursorLegacySession(cursorLegacySession)
            try db.execute(sql: """
                INSERT INTO collector_capture_reservations(id, root_id, root_revision, relative_path, dirty_revision,
                    generation_bytes, source_instance_id, collector_epoch, sequence, dirty_claim_owner_run_id, dirty_claim_generation,
                    gemini_context_bytes, gemini_context_sha256, sqlite_session_bytes, sqlite_session_sha256,
                    kimi_context_bytes, kimi_context_sha256, cursor_legacy_bytes, cursor_legacy_sha256)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [reservation.id, reservation.rootID, reservation.rootRevision, reservation.relativePath,
                    reservation.dirtyRevision, generationBytes, sourceInstanceID, collectorEpoch, sequence, ownerRunID, claim.claimGeneration,
                    context.bytes, context.digest, session.bytes, session.digest, kimi.bytes, kimi.digest, legacy.bytes, legacy.digest])
            try Self.replaceReservationSnapshot(db, reservationID: reservation.id, snapshot: snapshot, source: configuration.source)
            return CollectorCaptureReservation(
                id: reservation.id, rootID: reservation.rootID, rootRevision: reservation.rootRevision,
                relativePath: reservation.relativePath, dirtyRevision: reservation.dirtyRevision,
                generation: reservation.generation, sourceInstanceID: reservation.sourceInstanceID,
                collectorEpoch: reservation.collectorEpoch, sequence: reservation.sequence, snapshot: snapshot,
                sqliteSession: sqliteSession, cursorLegacySession: cursorLegacySession, effectiveSource: source
            )
        }
    }

    func captureReservations(limit: Int) throws -> [CollectorCaptureReservation] {
        try Self.validatePublicationLimit(limit)
        return try database.read { db in
            try requirePublicationOwner(db)
            return try Row.fetchAll(db, sql: """
                SELECT reservation.* FROM collector_roots root
                JOIN collector_capture_reservations reservation
                    ON reservation.root_id = root.root_id AND reservation.root_revision = root.root_revision
                ORDER BY reservation.root_id, reservation.root_revision LIMIT ?
                """, arguments: [limit]).map { try Self.reservation($0, db: db) }
        }
    }

    func finishCapture(
        _ reservation: CollectorCaptureReservation, capture: ArchiveCapture
    ) throws -> CollectorPublicationIntent? {
        try write { db in
            try Task.checkCancellation()
            guard let pending = try reservationRow(db, reservation),
                  let root = try Self.rootState(db, rootID: reservation.rootID),
                  root.configuration.revision == reservation.rootRevision else { return nil }
            try requirePublicationRoot(db, root.configuration)
            try validatePublicationCapture(capture, reservation: reservation, configuration: root.configuration)
            guard let locator = try Self.locatorRow(db, root.configuration, reservation.relativePath) else {
                throw CollectorInventoryError.invalidState
            }
            let dirtyRevision: Int64 = locator["dirty_revision"]
            guard dirtyRevision >= reservation.dirtyRevision else { throw CollectorInventoryError.invalidState }
            let intent: CollectorPublicationIntent
            if let existing = try Row.fetchOne(db, sql: """
                SELECT * FROM collector_publications WHERE root_id = ? AND root_revision = ? AND capture_id = ?
                """, arguments: [reservation.rootID, reservation.rootRevision, capture.captureID]) {
                intent = try publicationIntent(existing)
                guard intent.relativePath.utf8.elementsEqual(reservation.relativePath.utf8),
                      intent.publication.manifestSHA256 == capture.unboundManifestSHA256,
                      try Int.fetchOne(db, sql: "SELECT count(*) FROM collector_publication_replicas WHERE publication_digest = ?",
                        arguments: [intent.digest]) == 2 else { throw CollectorInventoryError.invalidState }
            } else {
                let publication = try CollectorPublicationEnvelope(machineID: machineID,
                    sourceInstanceID: reservation.sourceInstanceID, collectorEpoch: reservation.collectorEpoch,
                    sequence: reservation.sequence, manifestSHA256: capture.unboundManifestSHA256)
                let bytes = try ArchiveCanonicalJSON.encode(publication)
                guard bytes.count <= CollectorPublicationProtocolLimits.maxPublicationBytes else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                let digest = ArchiveV2Hash.sha256(bytes)
                intent = CollectorPublicationIntent(captureID: capture.captureID, rootID: reservation.rootID,
                    rootRevision: reservation.rootRevision, relativePath: reservation.relativePath,
                    publication: publication, canonicalBytes: bytes, digest: digest)
                try db.execute(sql: """
                    INSERT INTO collector_publications(publication_digest, capture_id, root_id, root_revision, relative_path,
                        source_instance_id, collector_epoch, sequence, manifest_sha256, canonical_bytes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [digest, capture.captureID, reservation.rootID, reservation.rootRevision,
                        reservation.relativePath, publication.sourceInstanceID, publication.collectorEpoch,
                        publication.sequence, publication.manifestSHA256, bytes])
                for replicaID in ["hq", "m1"] {
                    try db.execute(sql: """
                        INSERT INTO collector_publication_replicas(publication_digest, replica_id, state, claim_generation, attempts)
                        VALUES (?, ?, 'pending', 0, 0)
                        """, arguments: [digest, replicaID])
                }
            }
            if let legacy = reservation.cursorLegacySession {
                try db.execute(sql: """
                    INSERT INTO collector_cursor_legacy_sessions(root_id, root_revision, composer_id, capture_id)
                    VALUES (?, ?, ?, ?) ON CONFLICT(root_id, root_revision, composer_id)
                    DO UPDATE SET capture_id = excluded.capture_id
                    """, arguments: [reservation.rootID, reservation.rootRevision, legacy.composerID, capture.captureID])
                try Self.advanceCursorLegacyWalkIfCurrent(db, reservation: reservation)
                try Self.deleteReservationSnapshot(db, reservation.id)
                try db.execute(sql: "DELETE FROM collector_capture_reservations WHERE id = ?", arguments: [reservation.id])
                return intent
            }
            if reservation.sqliteSession != nil {
                try Self.advanceOpenCodeWalkIfCurrent(db, reservation: reservation)
                try Self.deleteReservationSnapshot(db, reservation.id)
                try db.execute(sql: "DELETE FROM collector_capture_reservations WHERE id = ?", arguments: [reservation.id])
                return intent
            }
            // Completing an older capture never erases a newer dirty event or
            // another claim acquired while this reservation survived a restart.
            try db.execute(sql: """
                UPDATE collector_locators SET acknowledged_revision = MAX(acknowledged_revision, ?),
                    last_capture_id = CASE WHEN acknowledged_revision <= ? THEN ? ELSE last_capture_id END
                WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [reservation.dirtyRevision, reservation.dirtyRevision, capture.captureID,
                    reservation.rootID, reservation.rootRevision, reservation.relativePath])
            try releaseReservedDirtyClaim(db, reservation, stored: pending)
            try Self.deleteReservationSnapshot(db, reservation.id)
            try db.execute(sql: "DELETE FROM collector_capture_reservations WHERE id = ?", arguments: [reservation.id])
            return intent
        }
    }

    func publicationSource(_ intent: CollectorPublicationIntent) throws -> SourceName {
        try database.read { db in
            try requirePublicationOwner(db)
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM collector_publications WHERE publication_digest = ?",
                arguments: [intent.digest]), try publicationIntent(row) == intent else {
                throw CollectorInventoryError.invalidState
            }
            return try Self.streamSource(db, rootID: intent.rootID, revision: intent.rootRevision,
                instance: intent.publication.sourceInstanceID, epoch: intent.publication.collectorEpoch)
        }
    }

    func publicationIntents(limit: Int) throws -> [CollectorPublicationIntent] {
        try Self.validatePublicationLimit(limit)
        return try database.read { db in
            try requirePublicationOwner(db)
            return try Row.fetchAll(db, sql: """
                SELECT * FROM collector_publications ORDER BY root_id, root_revision, sequence LIMIT ?
                """, arguments: [limit]).map(publicationIntent)
        }
    }

    func reconcilePublicationPrivacy(policySHA256: String) throws {
        guard ArchiveV2Hash.isValidSHA256(policySHA256) else { throw CollectorInventoryError.invalidState }
        let key = "publication_privacy_policy_sha256"
        let changed = try database.read { db in
            try requirePublicationOwner(db)
            return try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = ?",
                arguments: [key]) != policySHA256
        }
        guard changed else { return }
        try write { db in
            try requirePublicationOwner(db)
            guard try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = ?",
                arguments: [key]) != policySHA256 else { return }
            // A policy change is a new authorization opportunity, not a network retry.
            // Active claims and transport failures retain their existing fences/deadlines.
            try db.execute(sql: """
                UPDATE collector_publication_replicas SET retry_not_before = NULL, attempts = 0
                WHERE state = 'pending' AND last_error = 'privacyWithheld'
                """)
            try db.execute(sql: """
                INSERT INTO collector_metadata(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [key, policySHA256])
        }
    }

    func claimPublications(replicaID: String, limit: Int, now: Int64) throws -> [CollectorPublicationClaim] {
        try Self.validatePublicationLimit(limit)
        guard ["hq", "m1"].contains(replicaID), now >= 0 else { throw CollectorPublicationWorkerError.invalidBudget }
        try Task.checkCancellation()
        let hasPending = try database.read { db in
            try requirePublicationOwner(db)
            // Only a fully drained replica skips the original selection transaction.
            return try Int.fetchOne(db, sql: """
                SELECT 1 FROM collector_publication_replicas
                WHERE replica_id = ? AND state != 'acknowledged' LIMIT 1
                """, arguments: [replicaID]) != nil
        }
        try Task.checkCancellation()
        guard hasPending else { return [] }
        return try write { db in
            try Task.checkCancellation()
            let staleBefore = now >= 600 ? now - 600 : -1
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.*, r.claim_generation, r.attempts
                FROM collector_publication_replicas r
                JOIN collector_publications p ON p.publication_digest = r.publication_digest
                JOIN collector_roots roots ON roots.root_id = p.root_id AND roots.root_revision = p.root_revision
                WHERE r.replica_id = ? AND r.state != 'acknowledged' AND (
                    (r.state = 'pending' AND (r.retry_not_before IS NULL OR r.retry_not_before <= ?)) OR
                    (r.state = 'inflight' AND (r.claim_owner_run_id != ? OR r.claimed_at <= ?)))
                ORDER BY CASE WHEN p.root_id > ? THEN 0 ELSE 1 END,
                    p.root_id, p.root_revision, r.attempts, p.sequence LIMIT ?
                """, arguments: [replicaID, now, ownerRunID, staleBefore, publicationRootAfter[replicaID] ?? "", limit])
            let claims = try rows.map { row in
                let intent = try publicationIntent(row)
                let generation = try Self.increment(row["claim_generation"])
                let attempts: Int64 = row["attempts"]
                try db.execute(sql: """
                    UPDATE collector_publication_replicas SET state = 'inflight', claim_owner_run_id = ?,
                        claim_generation = ?, claimed_at = ?, retry_not_before = NULL
                    WHERE publication_digest = ? AND replica_id = ?
                    """, arguments: [ownerRunID, generation, now, intent.digest, replicaID])
                return CollectorPublicationClaim(intent: intent, replicaID: replicaID, ownerRunID: ownerRunID,
                    claimGeneration: generation, attempts: attempts)
            }
            if let last = claims.last { publicationRootAfter[replicaID] = last.intent.rootID }
            return claims
        }
    }

    func recordPublicationACK(_ claim: CollectorPublicationClaim, canonicalBytes: Data) throws -> Bool {
        try write { db in
            try Task.checkCancellation()
            guard try currentPublicationClaimRow(db, claim) != nil else { return false }
            guard !canonicalBytes.isEmpty, canonicalBytes.count <= CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes else {
                throw CollectorPublicationWorkerError.invalidACK
            }
            do {
                let ack = try ArchiveCanonicalJSON.decode(CollectorPublicationACK.self, from: canonicalBytes)
                try ack.validate(against: claim.intent.publication, expectedServerID: claim.replicaID)
            } catch { throw CollectorPublicationWorkerError.invalidACK }
            try db.execute(sql: """
                UPDATE collector_publication_replicas SET state = 'acknowledged', ack_bytes = ?,
                    claim_owner_run_id = NULL, claimed_at = NULL, retry_not_before = NULL, last_error = NULL
                WHERE publication_digest = ? AND replica_id = ?
                """, arguments: [canonicalBytes, claim.intent.digest, claim.replicaID])
            return true
        }
    }

    func deferPublication(
        _ claim: CollectorPublicationClaim, now: Int64, reason: CollectorPublicationDeferral
    ) throws -> Bool {
        guard now >= 0 else { throw CollectorPublicationWorkerError.invalidBudget }
        return try write { db in
            try Task.checkCancellation()
            guard let row = try currentPublicationClaimRow(db, claim) else { return false }
            let attempts = try Self.increment(row["attempts"])
            let delay: Int64 = attempts >= 18 ? 86_400 : Int64(1) << Int(attempts - 1)
            let (deadline, overflow) = now.addingReportingOverflow(delay)
            guard !overflow, deadline > now else { throw CollectorPublicationWorkerError.invalidBudget }
            try db.execute(sql: """
                UPDATE collector_publication_replicas SET state = 'pending', attempts = ?, retry_not_before = ?,
                    last_error = ?, claim_owner_run_id = NULL, claimed_at = NULL
                WHERE publication_digest = ? AND replica_id = ?
                """, arguments: [attempts, deadline, reason.rawValue, claim.intent.digest, claim.replicaID])
            return true
        }
    }

    func isPublicationClaimCurrent(_ claim: CollectorPublicationClaim) throws -> Bool {
        try database.read { db in
            try requirePublicationOwner(db)
            return try currentPublicationClaimRow(db, claim) != nil
        }
    }

    func abandonCapture(_ reservation: CollectorCaptureReservation) throws -> Bool {
        try write { db in
            try Task.checkCancellation()
            guard let pending = try reservationRow(db, reservation) else { return false }
            try releaseReservedDirtyClaim(db, reservation, stored: pending)
            try Self.deleteReservationSnapshot(db, reservation.id)
            try db.execute(sql: "DELETE FROM collector_capture_reservations WHERE id = ?", arguments: [reservation.id])
            return true
        }
    }

    func captureRecoveryState(_ reservation: CollectorCaptureReservation) throws -> Data? {
        try database.read { db in
            try requirePublicationOwner(db)
            guard let row = try reservationRow(db, reservation) else { return nil }
            let payload: Data? = row["recovery_state"]
            guard payload == nil || (1...2_048).contains(payload!.count) else { throw CollectorInventoryError.invalidState }
            return payload
        }
    }

    func storeCaptureRecoveryState(_ reservation: CollectorCaptureReservation, payload: Data?) throws -> Bool {
        if let payload, !(1...2_048).contains(payload.count) { throw CollectorPublicationWorkerError.invalidBudget }
        return try write { db in
            try Task.checkCancellation()
            guard try reservationRow(db, reservation) != nil else { return false }
            try db.execute(sql: "UPDATE collector_capture_reservations SET recovery_state = ? WHERE id = ?",
                arguments: [payload, reservation.id])
            return true
        }
    }

    func locator(
        configuration: CollectorRootConfiguration,
        relativePath: String
    ) throws -> CollectorLocatorState? {
        try database.read { db in
            try Self.requireRoot(db, configuration)
            return try Self.locatorRow(db, configuration, relativePath).map(Self.locatorState)
        }
    }

    func capturedDependencyObservationPage(
        configuration: CollectorRootConfiguration, after: String?, limit: Int
    ) throws -> [CollectorLocatorState] {
        guard (configuration.source == .cursor || configuration.source == .vscode), (1...64).contains(limit),
              after.map({ Self.isSafeRelativePath($0) }) ?? true else {
            throw CollectorInventoryError.invalidBudget
        }
        return try database.read { db in
            try requirePublicationOwner(db)
            try requirePublicationRoot(db, configuration)
            // Range-page the primary key before filtering candidates. Dirty or
            // uncaptured rows still consume the bound; never refill this page.
            return try Row.fetchAll(db, sql: """
                SELECT * FROM collector_locators
                WHERE root_id = ? AND root_revision = ? AND relative_path > ?
                ORDER BY relative_path LIMIT ?
                """, arguments: [configuration.rootID, configuration.revision, after ?? "", limit])
                .map(Self.locatorState)
        }
    }

    func dirtyCapturedDependencyObservation(
        configuration: CollectorRootConfiguration, locator: CollectorLocatorState
    ) throws {
        guard (configuration.source == .cursor || configuration.source == .vscode), Self.isSafeRelativePath(locator.relativePath),
              let captureID = locator.lastCaptureID else { throw CollectorInventoryError.invalidState }
        try write { db in
            try requirePublicationOwner(db)
            try requirePublicationRoot(db, configuration)
            guard let current = try Self.locatorRow(db, configuration, locator.relativePath),
                  let currentCapture: String = current["last_capture_id"],
                  currentCapture.utf8.elementsEqual(captureID.utf8),
                  (current["dirty_revision"] as Int64) == locator.dirtyRevision,
                  (current["acknowledged_revision"] as Int64) == locator.dirtyRevision else { return }
            try Self.upsertDirty(db, configuration, locator.relativePath, observedGeneration: nil, seenScanID: nil)
        }
    }

    func pendingLocators(
        configuration: CollectorRootConfiguration,
        limit: Int
    ) throws -> [CollectorLocatorState] {
        guard limit >= 0 else { throw CollectorInventoryError.invalidBudget }
        return try database.read { db in
            try Self.requireRoot(db, configuration)
            return try Row.fetchAll(db, sql: """
                SELECT * FROM collector_locators
                WHERE root_id = ? AND root_revision = ? AND dirty_revision > acknowledged_revision
                ORDER BY relative_path LIMIT ?
                """, arguments: [configuration.rootID, configuration.revision, limit]).map(Self.locatorState)
        }
    }

    func reconcileGeminiRegistry(
        configuration: CollectorRootConfiguration,
        locator: String,
        generation: ArchiveSourceGeneration?,
        limit: Int
    ) throws {
        // gemini_registry_* columns are the durable per-root registry pager
        // for both Gemini and Kimi; names stay for existing migrations.
        guard configuration.source == .geminiCli || configuration.source == .kimi,
              ArchiveSourceDescriptor.fileSetAbsolutePath(locator) == locator else {
            throw CollectorInventoryError.invalidRoot
        }
        guard (1...64).contains(limit) else { throw CollectorInventoryError.invalidBudget }
        try Task.checkCancellation()
        try write { db in
            try Self.requireRoot(db, configuration)
            guard let row = try Row.fetchOne(db, sql: """
                SELECT gemini_registry_locator, gemini_registry_generation, gemini_registry_page_after
                FROM collector_roots WHERE root_id = ?
                """, arguments: [configuration.rootID]) else {
                throw CollectorInventoryError.unknownRoot
            }
            let storedLocator: String? = row["gemini_registry_locator"]
            let storedGenerationText: String? = row["gemini_registry_generation"]
            let storedPage: String? = row["gemini_registry_page_after"]
            try Self.validateRegistryObserver(
                locator: storedLocator, generationText: storedGenerationText, pageAfter: storedPage
            )
            let storedGeneration = try Self.decodeRegistryGeneration(storedGenerationText)
            let locatorChanged = storedLocator.map { !$0.utf8.elementsEqual(locator.utf8) } == true
            if storedLocator == nil {
                try Self.saveRegistryObserver(
                    db, rootID: configuration.rootID, locator: locator, generation: generation, pageAfter: nil
                )
                return
            }
            let changed = locatorChanged || storedGeneration != generation
            var after = storedPage
            if changed {
                after = ""
            } else if after == nil {
                return
            }
            let paths = try String.fetchAll(db, sql: """
                SELECT relative_path FROM collector_locators
                WHERE root_id = ? AND root_revision = ? AND relative_path > ?
                ORDER BY relative_path LIMIT ?
                """, arguments: [configuration.rootID, configuration.revision, after ?? "", limit])
            for path in paths {
                try Task.checkCancellation()
                try Self.upsertDirty(
                    db, configuration, path, observedGeneration: nil, seenScanID: nil
                )
            }
            try Self.saveRegistryObserver(
                db, rootID: configuration.rootID, locator: locator, generation: generation,
                pageAfter: paths.count < limit ? nil : paths.last
            )
        }
    }

    func markDirty(
        configuration: CollectorRootConfiguration,
        relativePath: String,
        observedGeneration: String? = nil
    ) throws {
        guard Self.isSafeRelativePath(relativePath) else { throw CollectorInventoryError.invalidRelativePath }
        try write { db in
            try Self.requireRoot(db, configuration)
            try Self.upsertDirty(db, configuration, relativePath, observedGeneration: observedGeneration, seenScanID: nil)
        }
    }

    func rootsWithUnacknowledgedDirty(
        _ configurations: [CollectorRootConfiguration]
    ) throws -> Set<Data> {
        guard configurations.count <= 64 else { throw CollectorInventoryError.invalidBudget }
        return try database.read { db in
            try requirePublicationOwner(db)
            var pending = Set<Data>()
            for configuration in configurations {
                try Task.checkCancellation()
                try Self.requireRoot(db, configuration)
                if try Self.hasUnacknowledgedDirty(db, configuration) {
                    pending.insert(Data(configuration.rootID.utf8))
                }
            }
            return pending
        }
    }

    func claimDirty(
        configuration: CollectorRootConfiguration,
        limit: Int,
        now: Int64
    ) throws -> [CollectorDirtyClaim] {
        guard limit >= 0 else { throw CollectorInventoryError.invalidBudget }
        try Task.checkCancellation()
        let hasPending = try database.read { db in
            try requirePublicationOwner(db)
            try Self.requireRoot(db, configuration)
            guard limit > 0 else { return false }
            return try Self.hasUnacknowledgedDirty(db, configuration)
        }
        try Task.checkCancellation()
        guard hasPending else { return [] }
        return try write { db in
            try Self.requireRoot(db, configuration)
            guard limit > 0 else { return [] }
            let checkpoint = try String.fetchOne(db, sql: "SELECT claim_cursor FROM collector_roots WHERE root_id = ?", arguments: [configuration.rootID])
            // Bound candidates examined, not only successful claims. Filtering
            // in-flight/retry rows before LIMIT would hide an O(N) queue scan.
            // A persisted round-robin cursor prevents skipped/hot rows starving
            // later paths. An empty result does not imply the queue is empty.
            var rows = try Row.fetchAll(db, sql: """
                SELECT * FROM collector_locators
                WHERE root_id = ? AND root_revision = ? AND dirty_revision > acknowledged_revision
                    AND relative_path > ?
                ORDER BY relative_path LIMIT ?
                """, arguments: [configuration.rootID, configuration.revision, checkpoint ?? "", limit])
            if let checkpoint, rows.count < limit {
                rows += try Row.fetchAll(db, sql: """
                    SELECT * FROM collector_locators
                    WHERE root_id = ? AND root_revision = ? AND dirty_revision > acknowledged_revision
                        AND relative_path <= ?
                    ORDER BY relative_path LIMIT ?
                    """, arguments: [configuration.rootID, configuration.revision, checkpoint, limit - rows.count])
            }
            if let last = rows.last {
                let lastPath: String = last["relative_path"]
                try db.execute(sql: "UPDATE collector_roots SET claim_cursor = ? WHERE root_id = ?", arguments: [lastPath, configuration.rootID])
            }
            return try rows.compactMap { row -> CollectorDirtyClaim? in
                let claimedRevision: Int64? = row["claimed_dirty_revision"]
                let claimedOwner: String? = row["claim_owner_run_id"]
                let retryNotBefore: Int64? = row["retry_not_before"]
                let ownedByCurrentRun = claimedOwner?.utf8.elementsEqual(ownerRunID.utf8) ?? false
                guard claimedRevision == nil || !ownedByCurrentRun,
                      retryNotBefore == nil || retryNotBefore! <= now else { return nil }
                let path: String = row["relative_path"]
                let dirtyRevision: Int64 = row["dirty_revision"]
                let generation = try Self.increment(row["claim_generation"])
                try db.execute(sql: """
                    UPDATE collector_locators SET claim_owner_run_id = ?, claim_generation = ?,
                        claimed_dirty_revision = ?, retry_not_before = NULL
                    WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                    """, arguments: [ownerRunID, generation, dirtyRevision, configuration.rootID, configuration.revision, path])
                return CollectorDirtyClaim(
                    rootID: configuration.rootID, rootRevision: configuration.revision, relativePath: path,
                    dirtyRevision: dirtyRevision, ownerRunID: ownerRunID, claimGeneration: generation,
                    lastCaptureID: row["last_capture_id"]
                )
            }
        }
    }

    func acknowledge(
        _ claim: CollectorDirtyClaim,
        captureID: String
    ) throws -> CollectorClaimCompletion {
        try write { db in
            guard let row = try currentClaimRow(db, claim), !captureID.isEmpty else { return .stale }
            let dirtyRevision: Int64 = row["dirty_revision"]
            try db.execute(sql: """
                UPDATE collector_locators SET acknowledged_revision = ?, last_capture_id = ?,
                    claimed_dirty_revision = NULL, claim_owner_run_id = NULL,
                    retry_not_before = NULL, last_error = NULL
                WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [claim.dirtyRevision, captureID, claim.rootID, claim.rootRevision, claim.relativePath])
            return dirtyRevision > claim.dirtyRevision ? .newerWorkPending : .acknowledged
        }
    }

    func deferClaim(
        _ claim: CollectorDirtyClaim,
        retryNotBefore: Int64,
        reason: String
    ) throws -> Bool {
        try write { db in
            try applyDeferClaim(db, claim, retryNotBefore: retryNotBefore, reason: reason)
        }
    }

    func deferClaims(
        _ items: [(claim: CollectorDirtyClaim, retryNotBefore: Int64, reason: String)]
    ) throws -> [Bool] {
        try write { db in
            try items.map { item in
                try applyDeferClaim(db, item.claim, retryNotBefore: item.retryNotBefore, reason: item.reason)
            }
        }
    }

    func beginBootstrap(
        configuration: CollectorRootConfiguration,
        scanID: String
    ) throws -> CollectorScanToken {
        guard !scanID.isEmpty else { throw CollectorInventoryError.invalidState }
        return try write { db in
            let state = try Self.requireRoot(db, configuration)
            if let active = state.activeScan {
                if state.requestedRevision > state.completedRevision {
                    try db.execute(sql: """
                        INSERT INTO collector_frontier(root_id, root_revision, scan_id, relative_directory, completed)
                        VALUES (?, ?, ?, '', 0) ON CONFLICT DO NOTHING
                        """, arguments: [active.rootID, active.rootRevision, active.scanID])
                }
                return active
            }
            let scan = CollectorScanToken(
                rootID: configuration.rootID, rootRevision: configuration.revision,
                scanID: scanID, requestedRevision: state.requestedRevision
            )
            try db.execute(sql: """
                UPDATE collector_roots SET active_scan_id = ?, active_scan_requested_revision = ?, last_scan_failure = NULL
                WHERE root_id = ?
                """, arguments: [scanID, scan.requestedRevision, configuration.rootID])
            try db.execute(sql: """
                INSERT INTO collector_frontier(root_id, root_revision, scan_id, relative_directory, completed)
                VALUES (?, ?, ?, '', 0)
                """, arguments: [scan.rootID, scan.rootRevision, scan.scanID])
            return scan
        }
    }

    func pendingDirectories(
        scan: CollectorScanToken,
        limit: Int
    ) throws -> [String] {
        guard limit >= 0 else { throw CollectorInventoryError.invalidBudget }
        return try database.read { db in
            guard try Self.rootState(db, rootID: scan.rootID)?.activeScan == scan else { return [] }
            return try String.fetchAll(db, sql: """
                SELECT relative_directory FROM collector_frontier
                WHERE root_id = ? AND root_revision = ? AND scan_id = ? AND completed = 0
                ORDER BY relative_directory LIMIT ?
                """, arguments: [scan.rootID, scan.rootRevision, scan.scanID, limit])
        }
    }

    func applyBootstrapBatch(_ batch: CollectorBootstrapBatch) throws {
        try write { db in
            guard let state = try Self.rootState(db, rootID: batch.scan.rootID), state.activeScan == batch.scan else {
                throw CollectorInventoryError.staleScan
            }
            guard Self.isSafeRelativePath(batch.relativeDirectory, allowRoot: true),
                  batch.files.allSatisfy({ Self.isDirectChild($0.relativePath, of: batch.relativeDirectory) && !$0.observedGeneration.isEmpty }),
                  batch.childDirectories.allSatisfy({ Self.isDirectChild($0, of: batch.relativeDirectory) }) else {
                throw CollectorInventoryError.invalidRelativePath
            }
            guard let completed = try Int.fetchOne(db, sql: """
                SELECT completed FROM collector_frontier
                WHERE root_id = ? AND root_revision = ? AND scan_id = ? AND relative_directory = ?
                """, arguments: [batch.scan.rootID, batch.scan.rootRevision, batch.scan.scanID, batch.relativeDirectory]) else {
                throw CollectorInventoryError.staleScan
            }
            if completed == 1 { return }
            for file in batch.files {
                let previous = try Self.locatorRow(db, state.configuration, file.relativePath)
                let generation: String? = previous?["observed_generation"]
                let seenScanID: String? = previous?["last_seen_scan_id"]
                let observed: String
                if state.configuration.source == .opencode, file.relativePath == "opencode.db" {
                    let pair = try CollectorOpenCodeSource.observe(
                        root: URL(fileURLWithPath: state.configuration.rootPath)
                    )
                    observed = try Self.openCodeObservationFingerprint(
                        databaseGeneration: pair.databaseGeneration, walGeneration: pair.walGeneration
                    )
                    if generation == observed {
                        if seenScanID != batch.scan.scanID {
                            try Self.touchLocatorSeenScan(
                                db, state.configuration, file.relativePath, seenScanID: batch.scan.scanID
                            )
                        }
                        continue
                    }
                } else {
                    observed = file.observedGeneration
                    if generation == observed {
                        if seenScanID != batch.scan.scanID {
                            try Self.touchLocatorSeenScan(
                                db, state.configuration, file.relativePath, seenScanID: batch.scan.scanID
                            )
                        }
                        continue
                    }
                }
                try Self.upsertDirty(
                    db, state.configuration, file.relativePath, observedGeneration: observed,
                    seenScanID: batch.scan.scanID
                )
            }
            for directory in batch.childDirectories {
                try db.execute(sql: """
                    INSERT INTO collector_frontier(root_id, root_revision, scan_id, relative_directory, completed)
                    VALUES (?, ?, ?, ?, 0) ON CONFLICT DO NOTHING
                    """, arguments: [batch.scan.rootID, batch.scan.rootRevision, batch.scan.scanID, directory])
            }
            if batch.directoryFinished {
                try db.execute(sql: """
                    UPDATE collector_frontier SET completed = 1
                    WHERE root_id = ? AND root_revision = ? AND scan_id = ? AND relative_directory = ?
                    """, arguments: [batch.scan.rootID, batch.scan.rootRevision, batch.scan.scanID, batch.relativeDirectory])
            }
        }
    }

    func finishBootstrap(_ scan: CollectorScanToken) throws -> Bool {
        try write { db in
            guard let state = try Self.rootState(db, rootID: scan.rootID), state.activeScan == scan else { return false }
            guard try Int.fetchOne(db, sql: """
                SELECT 1 FROM collector_frontier
                WHERE root_id = ? AND root_revision = ? AND scan_id = ? AND completed = 0 LIMIT 1
                """, arguments: [scan.rootID, scan.rootRevision, scan.scanID]) == nil else { return false }
            let walkedRoot = try Int.fetchOne(db, sql: """
                SELECT completed FROM collector_frontier
                WHERE root_id = ? AND root_revision = ? AND scan_id = ? AND relative_directory = ''
                """, arguments: [scan.rootID, scan.rootRevision, scan.scanID]) == 1
            let completedRevision = walkedRoot
                ? max(state.completedRevision, scan.requestedRevision)
                : state.completedRevision
            try db.execute(sql: """
                UPDATE collector_roots SET completed_revision = ?, active_scan_id = NULL,
                    active_scan_requested_revision = NULL, last_scan_failure = NULL WHERE root_id = ?
                """, arguments: [completedRevision, scan.rootID])
            return true
        }
    }

    func recordScanFailure(
        _ scan: CollectorScanToken,
        failure: CollectorBootstrapFailure
    ) throws {
        try write { db in
            guard try Self.rootState(db, rootID: scan.rootID)?.activeScan == scan else {
                throw CollectorInventoryError.staleScan
            }
            let reason = failure == .unsafeEntry ? "unsafeEntry" : "enumerationUnavailable"
            try db.execute(sql: "UPDATE collector_roots SET last_scan_failure = ? WHERE root_id = ?", arguments: [reason, scan.rootID])
        }
    }

    func requestReconciliation(configuration: CollectorRootConfiguration) throws {
        try write { db in
            let state = try Self.requireRoot(db, configuration)
            try db.execute(sql: "UPDATE collector_roots SET requested_revision = ? WHERE root_id = ?", arguments: [Self.increment(state.requestedRevision), configuration.rootID])
        }
    }

    func applyEventBatch(
        configuration: CollectorRootConfiguration,
        expectedCheckpoint: CollectorEventCheckpoint?,
        nextCheckpoint: CollectorEventCheckpoint,
        dirtyRelativePaths: [String],
        requiresReconciliation: Bool,
        dirtyRelativeDirectories: [String] = [],
        observedGenerations: [String: String] = [:]
    ) throws {
        try write { db in
            let state = try Self.requireRoot(db, configuration)
            guard state.eventCheckpoint == expectedCheckpoint, !nextCheckpoint.epoch.isEmpty, !nextCheckpoint.cursor.isEmpty,
                  state.eventCheckpoint == nil || state.eventCheckpoint?.epoch == nextCheckpoint.epoch || requiresReconciliation else {
                throw CollectorInventoryError.staleCheckpoint
            }
            for path in dirtyRelativePaths {
                guard Self.isSafeRelativePath(path) else { throw CollectorInventoryError.invalidRelativePath }
                if let fingerprint = observedGenerations[path],
                   let previous = try Self.locatorRow(db, configuration, path) {
                    let stored: String? = previous["observed_generation"]
                    if stored == fingerprint { continue }
                }
                try Self.upsertDirty(
                    db, configuration, path, observedGeneration: observedGenerations[path], seenScanID: nil
                )
            }
            for directory in dirtyRelativeDirectories {
                guard Self.isSafeRelativePath(directory) else { throw CollectorInventoryError.invalidRelativePath }
            }
            let requestedRevision = requiresReconciliation ? try Self.increment(state.requestedRevision) : state.requestedRevision
            try db.execute(sql: """
                UPDATE collector_roots SET event_epoch = ?, event_cursor = ?, requested_revision = ? WHERE root_id = ?
                """, arguments: [nextCheckpoint.epoch, nextCheckpoint.cursor, requestedRevision, configuration.rootID])
            if !requiresReconciliation, !dirtyRelativeDirectories.isEmpty {
                try Self.enqueueTargetedDirectories(
                    db, configuration: configuration, state: state, directories: dirtyRelativeDirectories
                )
            }
        }
    }

    private static func enqueueTargetedDirectories(
        _ db: Database,
        configuration: CollectorRootConfiguration,
        state: CollectorRootState,
        directories: [String]
    ) throws {
        let scan: CollectorScanToken
        if let active = state.activeScan {
            scan = active
            if state.requestedRevision > state.completedRevision {
                try db.execute(sql: """
                    INSERT INTO collector_frontier(root_id, root_revision, scan_id, relative_directory, completed)
                    VALUES (?, ?, ?, '', 0) ON CONFLICT DO NOTHING
                    """, arguments: [scan.rootID, scan.rootRevision, scan.scanID])
            }
        } else {
            let scanID = UUID().uuidString
            scan = CollectorScanToken(
                rootID: configuration.rootID, rootRevision: configuration.revision,
                scanID: scanID, requestedRevision: state.requestedRevision
            )
            try db.execute(sql: """
                UPDATE collector_roots SET active_scan_id = ?, active_scan_requested_revision = ?, last_scan_failure = NULL
                WHERE root_id = ?
                """, arguments: [scanID, scan.requestedRevision, configuration.rootID])
            if state.requestedRevision > state.completedRevision {
                try db.execute(sql: """
                    INSERT INTO collector_frontier(root_id, root_revision, scan_id, relative_directory, completed)
                    VALUES (?, ?, ?, '', 0) ON CONFLICT DO NOTHING
                    """, arguments: [scan.rootID, scan.rootRevision, scan.scanID])
            }
        }
        for directory in directories {
            try db.execute(sql: """
                INSERT INTO collector_frontier(root_id, root_revision, scan_id, relative_directory, completed)
                VALUES (?, ?, ?, ?, 0)
                ON CONFLICT(root_id, root_revision, scan_id, relative_directory) DO UPDATE SET completed = 0
                """, arguments: [scan.rootID, scan.rootRevision, scan.scanID, directory])
        }
    }

    static func isSafeRelativePath(_ path: String, allowRoot: Bool = false) -> Bool {
        if path.isEmpty { return allowRoot }
        guard !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isDirectChild(_ path: String, of directory: String) -> Bool {
        guard isSafeRelativePath(path), isSafeRelativePath(directory, allowRoot: true) else { return false }
        return path.split(separator: "/").dropLast().joined(separator: "/") == directory
    }

    private static func validatePublicationLimit(_ limit: Int) throws {
        guard (1...64).contains(limit) else { throw CollectorPublicationWorkerError.invalidBudget }
    }

    private func requirePublicationOwner(_ db: Database) throws {
        guard let active = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'active_owner_run_id'"),
              active.utf8.elementsEqual(ownerRunID.utf8) else { throw CollectorInventoryError.staleOwner }
    }

    private func requirePublicationRoot(_ db: Database, _ configuration: CollectorRootConfiguration) throws {
        try Self.requireRoot(db, configuration)
        guard let binding = try Self.rootBinding(db, configuration),
              binding.lastActivatedOwnerRunID?.utf8.elementsEqual(ownerRunID.utf8) == true else {
            throw CollectorInventoryOwnerError.rootNotActivated
        }
    }

    private static func validEffectiveSource(_ source: SourceName, configuration: CollectorRootConfiguration) -> Bool {
        source == configuration.source || (configuration.source == .claudeCode && (source == .minimax || source == .lobsterai))
    }

    private static func streamSource(_ db: Database, rootID: String, revision: Int64,
        instance: String, epoch: String) throws -> SourceName {
        guard let raw = try String.fetchOne(db, sql: """
            SELECT effective_source FROM collector_streams
            WHERE root_id = ? AND root_revision = ? AND source_instance_id = ? AND collector_epoch = ?
            """, arguments: [rootID, revision, instance, epoch]), let source = SourceName(rawValue: raw) else {
            throw CollectorInventoryError.invalidState
        }
        return source
    }

    private static func reservation(_ row: Row, db: Database) throws -> CollectorCaptureReservation {
        let bytes: Data = row["generation_bytes"]
        guard bytes.count <= 2_048 else { throw CollectorInventoryError.invalidState }
        let generation = try ArchiveCanonicalJSON.decode(ArchiveSourceGeneration.self, from: bytes)
        let id: String = row["id"]
        let relativePath: String = row["relative_path"]
        let files = try reservationSnapshot(db, reservationID: id, entrypoint: relativePath)
        let contextBytes: Data? = row["gemini_context_bytes"]
        let contextDigest: String? = row["gemini_context_sha256"]
        let context = try decodeGeminiContext(bytes: contextBytes, digest: contextDigest)
        let kimiBytes: Data? = row["kimi_context_bytes"]
        let kimiDigest: String? = row["kimi_context_sha256"]
        let kimi = try decodeKimiContext(bytes: kimiBytes, digest: kimiDigest)
        let vscode = try decodeVSCodeContext(bytes: row["vscode_context_bytes"], digest: row["vscode_context_sha256"])
        let sessionBytes: Data? = row["sqlite_session_bytes"]
        let sessionDigest: String? = row["sqlite_session_sha256"]
        let sqliteSession = try decodeSQLiteSession(bytes: sessionBytes, digest: sessionDigest)
        let legacy = try decodeCursorLegacySession(bytes: row["cursor_legacy_bytes"], digest: row["cursor_legacy_sha256"])
        guard legacy == nil || (files == nil && context == nil && kimi == nil && vscode == nil && sqliteSession == nil) else {
            throw CollectorInventoryError.invalidState
        }
        let snapshot: CollectorDependencySnapshot?
        if let files {
            guard sqliteSession == nil, context == nil || kimi == nil,
                  vscode == nil || (context == nil && kimi == nil) else {
                throw CollectorInventoryError.invalidState
            }
            snapshot = CollectorDependencySnapshot(
                entrypointRelativePath: files.entrypointRelativePath,
                present: files.present,
                absentRelativePaths: files.absentRelativePaths,
                vscodeWorkspaceContext: vscode,
                geminiProjectContext: context,
                kimiProjectContext: kimi
            )
        } else if context != nil || kimi != nil || vscode != nil {
            throw CollectorInventoryError.invalidState
        } else {
            snapshot = nil
        }
        let value = CollectorCaptureReservation(id: id, rootID: row["root_id"], rootRevision: row["root_revision"],
            relativePath: relativePath, dirtyRevision: row["dirty_revision"], generation: generation,
            sourceInstanceID: row["source_instance_id"], collectorEpoch: row["collector_epoch"], sequence: row["sequence"],
            snapshot: snapshot, sqliteSession: sqliteSession, cursorLegacySession: legacy,
            effectiveSource: try streamSource(db, rootID: row["root_id"], revision: row["root_revision"],
                instance: row["source_instance_id"], epoch: row["collector_epoch"]))
        guard UUID(uuidString: value.id) != nil, !value.rootID.isEmpty, value.rootRevision > 0,
              isSafeRelativePath(value.relativePath), value.dirtyRevision > 0, value.sequence > 0,
              UUID(uuidString: value.sourceInstanceID) != nil, UUID(uuidString: value.collectorEpoch) != nil else {
            throw CollectorInventoryError.invalidState
        }
        try validateLoadedReservation(db, value)
        return value
    }

    private static func validateLoadedReservation(_ db: Database, _ reservation: CollectorCaptureReservation) throws {
        guard let root = try rootState(db, rootID: reservation.rootID),
              root.configuration.revision == reservation.rootRevision,
              let source = reservation.effectiveSource, validEffectiveSource(source, configuration: root.configuration) else {
            throw CollectorInventoryError.invalidState
        }
        guard reservation.snapshot?.vscodeWorkspaceContext == nil || root.configuration.source == .vscode else {
            throw CollectorInventoryError.invalidState
        }
        if let legacy = reservation.cursorLegacySession {
            guard reservation.snapshot == nil, reservation.sqliteSession == nil else { throw CollectorInventoryError.invalidState }
            try requireValidCursorLegacySession(legacy, configuration: root.configuration, relativePath: reservation.relativePath)
        } else if root.configuration.source == .cursor {
            guard let snapshot = reservation.snapshot, reservation.sqliteSession == nil else {
                throw CollectorInventoryError.invalidState
            }
            try CollectorCursorSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
            guard snapshot.present.contains(where: {
                $0.relativePath.utf8.elementsEqual(reservation.relativePath.utf8) && $0.generation == reservation.generation
            }) else { throw CollectorInventoryError.invalidState }
        } else if root.configuration.source == .copilot || root.configuration.source == .cline {
            guard let snapshot = reservation.snapshot, snapshot.kimiProjectContext == nil else {
                throw CollectorInventoryError.invalidState
            }
            if root.configuration.source == .cline {
                try CollectorClineSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
            } else {
                try CollectorCopilotSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
            }
            guard snapshot.present.contains(where: {
                $0.relativePath.utf8.elementsEqual(reservation.relativePath.utf8)
                    && $0.generation == reservation.generation
            }) else {
                throw CollectorInventoryError.invalidState
            }
        } else if root.configuration.source == .geminiCli {
            guard let snapshot = reservation.snapshot, snapshot.kimiProjectContext == nil else {
                throw CollectorInventoryError.invalidState
            }
            try CollectorGeminiSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
            guard snapshot.present.contains(where: {
                $0.relativePath.utf8.elementsEqual(reservation.relativePath.utf8)
                    && $0.generation == reservation.generation
            }) else {
                throw CollectorInventoryError.invalidState
            }
        } else if root.configuration.source == .vscode {
            guard let snapshot = reservation.snapshot, reservation.sqliteSession == nil else {
                throw CollectorInventoryError.invalidState
            }
            try CollectorVSCodeSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
            guard snapshot.present.contains(where: {
                $0.relativePath.utf8.elementsEqual(reservation.relativePath.utf8) && $0.generation == reservation.generation
            }) else { throw CollectorInventoryError.invalidState }
        } else if root.configuration.source == .kimi {
            guard let snapshot = reservation.snapshot, snapshot.geminiProjectContext == nil,
                  snapshot.kimiProjectContext != nil, reservation.sqliteSession == nil else {
                throw CollectorInventoryError.invalidState
            }
            try CollectorKimiSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
            guard snapshot.present.contains(where: {
                $0.relativePath.utf8.elementsEqual(reservation.relativePath.utf8)
                    && $0.generation == reservation.generation
            }) else {
                throw CollectorInventoryError.invalidState
            }
        } else if root.configuration.source == .grok {
            guard let snapshot = reservation.snapshot, snapshot.geminiProjectContext == nil,
                  snapshot.kimiProjectContext == nil, reservation.sqliteSession == nil else {
                throw CollectorInventoryError.invalidState
            }
            try CollectorGrokSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
            guard snapshot.present.contains(where: {
                $0.relativePath.utf8.elementsEqual(reservation.relativePath.utf8)
                    && $0.generation == reservation.generation
            }) else {
                throw CollectorInventoryError.invalidState
            }
        } else if root.configuration.source == .opencode {
            guard reservation.snapshot == nil, let session = reservation.sqliteSession else {
                throw CollectorInventoryError.invalidState
            }
            try requireValidSQLiteSession(
                session, configuration: root.configuration, relativePath: reservation.relativePath
            )
        } else if reservation.snapshot != nil || reservation.sqliteSession != nil {
            throw CollectorInventoryError.invalidState
        }
    }

    private static func reservationSnapshot(
        _ db: Database, reservationID: String, entrypoint: String
    ) throws -> CollectorDependencySnapshot? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT relative_path, presence, generation_bytes FROM collector_capture_reservation_dependencies
            WHERE reservation_id = ? ORDER BY relative_path
            """, arguments: [reservationID])
        if rows.isEmpty { return nil }
        var present: [CollectorDependencySnapshot.PresentMember] = []
        var absent: [String] = []
        for row in rows {
            let path: String = row["relative_path"]
            let presence: String = row["presence"]
            guard isSafeRelativePath(path) else { throw CollectorInventoryError.invalidState }
            if presence == "absent" {
                let stored: Data? = row["generation_bytes"]
                guard stored == nil else { throw CollectorInventoryError.invalidState }
                absent.append(path)
            } else if presence == "present" {
                let bytes: Data = row["generation_bytes"]
                guard (1...2_048).contains(bytes.count) else { throw CollectorInventoryError.invalidState }
                present.append(
                    .init(
                        relativePath: path,
                        generation: try ArchiveCanonicalJSON.decode(ArchiveSourceGeneration.self, from: bytes)
                    )
                )
            } else {
                throw CollectorInventoryError.invalidState
            }
        }
        return CollectorDependencySnapshot(
            entrypointRelativePath: entrypoint, present: present, absentRelativePaths: absent
        )
    }

    private static func replaceReservationSnapshot(
        _ db: Database, reservationID: String, snapshot: CollectorDependencySnapshot?, source: SourceName
    ) throws {
        let context = try encodeGeminiContext(snapshot?.geminiProjectContext)
        let kimi = try encodeKimiContext(snapshot?.kimiProjectContext)
        let vscode = try encodeVSCodeContext(snapshot?.vscodeWorkspaceContext)
        guard context.bytes == nil || kimi.bytes == nil,
              vscode.bytes == nil || (source == .vscode && context.bytes == nil && kimi.bytes == nil) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        try db.execute(sql: """
            UPDATE collector_capture_reservations
            SET gemini_context_bytes = ?, gemini_context_sha256 = ?,
                kimi_context_bytes = ?, kimi_context_sha256 = ?,
                vscode_context_bytes = ?, vscode_context_sha256 = ?
            WHERE id = ?
            """, arguments: [context.bytes, context.digest, kimi.bytes, kimi.digest, vscode.bytes, vscode.digest, reservationID])
        try deleteReservationSnapshot(db, reservationID)
        guard let snapshot else { return }
        if source == .vscode {
            try CollectorVSCodeSource.requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)
        } else if source == .cline {
            try CollectorClineSource.requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)
        } else if source == .cursor {
            try CollectorCursorSource.requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)
        } else if source == .grok {
            try CollectorGrokSource.requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)
        } else {
            try requireCompositeSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)
        }
        for member in snapshot.present {
            let bytes = try ArchiveCanonicalJSON.encode(member.generation)
            guard bytes.count <= 2_048 else { throw CollectorPublicationWorkerError.invalidCapture }
            try db.execute(sql: """
                INSERT INTO collector_capture_reservation_dependencies(
                    reservation_id, relative_path, presence, generation_bytes)
                VALUES (?, ?, 'present', ?)
                """, arguments: [reservationID, member.relativePath, bytes])
        }
        for path in snapshot.absentRelativePaths {
            try db.execute(sql: """
                INSERT INTO collector_capture_reservation_dependencies(
                    reservation_id, relative_path, presence, generation_bytes)
                VALUES (?, ?, 'absent', NULL)
                """, arguments: [reservationID, path])
        }
    }

    private static func deleteReservationSnapshot(_ db: Database, _ reservationID: String) throws {
        try db.execute(sql: "DELETE FROM collector_capture_reservation_dependencies WHERE reservation_id = ?",
            arguments: [reservationID])
    }

    private func reservationRow(_ db: Database, _ expected: CollectorCaptureReservation) throws -> Row? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM collector_capture_reservations WHERE id = ?",
            arguments: [expected.id]) else { return nil }
        let stored = try Self.reservation(row, db: db)
        guard stored == expected, stored.rootID.utf8.elementsEqual(expected.rootID.utf8),
              stored.relativePath.utf8.elementsEqual(expected.relativePath.utf8) else { return nil }
        if let root = try Self.rootState(db, rootID: stored.rootID), root.configuration.source == .cursor,
           !CollectorCursorSource.reservedPathsEqual(stored.snapshot, expected.snapshot) { return nil }
        return row
    }

    private func releaseReservedDirtyClaim(_ db: Database, _ reservation: CollectorCaptureReservation, stored: Row) throws {
        let originalOwner: String = stored["dirty_claim_owner_run_id"]
        let originalGeneration: Int64 = stored["dirty_claim_generation"]
        try db.execute(sql: """
            UPDATE collector_locators SET claimed_dirty_revision = NULL, claim_owner_run_id = NULL,
                retry_not_before = NULL, last_error = NULL
            WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                AND claim_owner_run_id = ? AND claim_generation = ? AND claimed_dirty_revision = ?
            """, arguments: [reservation.rootID, reservation.rootRevision, reservation.relativePath,
                originalOwner, originalGeneration, reservation.dirtyRevision])
    }

    private func publicationIntent(_ row: Row) throws -> CollectorPublicationIntent {
        let bytes: Data = row["canonical_bytes"]
        let digest: String = row["publication_digest"]
        guard bytes.count <= CollectorPublicationProtocolLimits.maxPublicationBytes,
              ArchiveV2Hash.isValidSHA256(digest), ArchiveV2Hash.sha256(bytes) == digest else {
            throw CollectorInventoryError.invalidState
        }
        let publication = try ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: bytes)
        let sourceInstance: String = row["source_instance_id"]
        let epoch: String = row["collector_epoch"]
        let sequence: Int64 = row["sequence"]
        let manifest: String = row["manifest_sha256"]
        let intent = CollectorPublicationIntent(captureID: row["capture_id"], rootID: row["root_id"],
            rootRevision: row["root_revision"], relativePath: row["relative_path"],
            publication: publication, canonicalBytes: bytes, digest: digest)
        guard publication.machineID == machineID, publication.sourceInstanceID == sourceInstance,
              publication.collectorEpoch == epoch, publication.sequence == sequence,
              publication.manifestSHA256 == manifest, ArchiveV2Hash.isValidSHA256(intent.captureID),
              !intent.rootID.isEmpty, intent.rootRevision > 0, Self.isSafeRelativePath(intent.relativePath) else {
            throw CollectorInventoryError.invalidState
        }
        return intent
    }

    private func currentPublicationClaimRow(_ db: Database, _ claim: CollectorPublicationClaim) throws -> Row? {
        guard claim.ownerRunID.utf8.elementsEqual(ownerRunID.utf8), ["hq", "m1"].contains(claim.replicaID),
              let row = try Row.fetchOne(db, sql: """
                SELECT p.*, r.state, r.claim_owner_run_id, r.claim_generation, r.attempts
                FROM collector_publication_replicas r
                JOIN collector_publications p ON p.publication_digest = r.publication_digest
                JOIN collector_roots roots ON roots.root_id = p.root_id AND roots.root_revision = p.root_revision
                WHERE r.publication_digest = ? AND r.replica_id = ?
                """, arguments: [claim.intent.digest, claim.replicaID]) else { return nil }
        let state: String = row["state"]
        let claimedOwner: String? = row["claim_owner_run_id"]
        let generation: Int64 = row["claim_generation"]
        let attempts: Int64 = row["attempts"]
        guard state == "inflight", claimedOwner?.utf8.elementsEqual(ownerRunID.utf8) == true,
              generation == claim.claimGeneration, attempts == claim.attempts else { return nil }
        let stored = try publicationIntent(row)
        guard stored == claim.intent, stored.rootID.utf8.elementsEqual(claim.intent.rootID.utf8),
              stored.relativePath.utf8.elementsEqual(claim.intent.relativePath.utf8) else { return nil }
        return row
    }

    private func validatePublicationCapture(
        _ capture: ArchiveCapture, reservation: CollectorCaptureReservation, configuration: CollectorRootConfiguration
    ) throws {
        guard capture.unboundManifestBytes.count <= ArchiveV2ProtocolLimits.maxManifestBytes,
              ArchiveV2Hash.sha256(capture.unboundManifestBytes) == capture.unboundManifestSHA256,
              capture.machineID == machineID, capture.source == (reservation.effectiveSource ?? configuration.source).rawValue,
              Self.locatorMatchesReservation(capture.locator, configuration: configuration, reservation: reservation),
              capture.generation == reservation.generation, capture.status == "captured" else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let manifest: ArchiveSourceManifest
        do { manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: capture.unboundManifestBytes) }
        catch { throw CollectorPublicationWorkerError.invalidCapture }
        guard manifest.sessionID == nil, manifest.captureID == capture.captureID,
              manifest.machineID == capture.machineID, manifest.source == capture.source,
              manifest.locator.utf8.elementsEqual(capture.locator.utf8), manifest.generation == capture.generation,
              manifest.wholeSourceSHA256 == capture.wholeSourceSHA256, manifest.rawByteCount == capture.rawByteCount,
              manifest.chunkSize == capture.chunkSize, manifest.capturedAt == capture.capturedAt else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        if let session = reservation.cursorLegacySession {
            guard configuration.source == .cursor, reservation.snapshot == nil, reservation.sqliteSession == nil,
                  ArchiveSourceDescriptor.isCursorLegacySession(manifest),
                  manifest.replayLayout.cursorLegacySession == session,
                  (try ExactSourceCapturer.cursorLegacySessionCaptureID(machineID: capture.machineID,
                    context: session, generation: capture.generation, wholeSourceSHA256: capture.wholeSourceSHA256)) == capture.captureID else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            return
        }
        if let session = reservation.sqliteSession {
            guard configuration.source == .opencode, reservation.snapshot == nil,
                  manifest.schemaVersion == 4, manifest.replayLayout.sqliteSession == session,
                  (try ExactSourceCapturer.sqliteSessionImageCaptureID(
                    machineID: capture.machineID, context: session, generation: capture.generation,
                    wholeSourceSHA256: capture.wholeSourceSHA256)) == capture.captureID else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            return
        }
        if configuration.source == .cline || configuration.source == .copilot || configuration.source == .geminiCli
            || configuration.source == .kimi || configuration.source == .cursor || configuration.source == .vscode
            || configuration.source == .grok {
            guard reservation.sqliteSession == nil,
                  let snapshot = reservation.snapshot,
                  snapshot.present.contains(where: {
                      $0.relativePath.utf8.elementsEqual(reservation.relativePath.utf8)
                          && $0.generation == reservation.generation
                          && $0.generation == capture.generation
                  }),
                  manifest.replayLayout.strategy == .fileSet,
                  (configuration.source == .vscode
                      ? (ArchiveSourceDescriptor.isVSCodeFileSet(manifest)
                          && CollectorVSCodeSource.matchesReservedSnapshot(snapshot, manifest: manifest))
                      : configuration.source == .cline
                      ? (ArchiveSourceDescriptor.isClineFileSet(manifest)
                          && CollectorClineSource.matchesReservedSnapshot(snapshot, manifest: manifest))
                      : configuration.source == .cursor
                      ? (manifest.schemaVersion == 2
                          && ArchiveSourceDescriptor.isCursorModernFileSet(manifest)
                          && CollectorCursorSource.matchesReservedSnapshot(snapshot, manifest: manifest))
                      : configuration.source == .copilot
                      ? (manifest.schemaVersion == 2
                          && snapshot.kimiProjectContext == nil
                          && ArchiveSourceDescriptor.isCopilotFileSet(manifest)
                          && CollectorCopilotSource.matchesReservedSnapshot(snapshot, manifest: manifest))
                      : configuration.source == .geminiCli
                          ? (snapshot.kimiProjectContext == nil
                              && ArchiveSourceDescriptor.isGeminiFileSet(manifest)
                              && CollectorGeminiSource.matchesReservedSnapshot(snapshot, manifest: manifest))
                          : configuration.source == .grok
                          ? (manifest.schemaVersion == 2
                              && snapshot.geminiProjectContext == nil
                              && snapshot.kimiProjectContext == nil
                              && ArchiveSourceDescriptor.isGrokFileSet(manifest)
                              && CollectorGrokSource.matchesReservedSnapshot(snapshot, manifest: manifest))
                          : (manifest.schemaVersion == 5
                              && snapshot.geminiProjectContext == nil
                              && snapshot.kimiProjectContext == manifest.replayLayout.kimiProjectContext
                              && ArchiveSourceDescriptor.isKimiFileSet(manifest)
                              && CollectorKimiSource.matchesReservedSnapshot(snapshot, manifest: manifest))) else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            struct FileSetCaptureIdentity: Encodable {
                let machineID: String
                let source: String
                let locator: String
                let generation: ArchiveSourceGeneration
                let wholeSourceSHA256: String
                let replayLayout: ArchiveReplayLayout
            }
            let identity = FileSetCaptureIdentity(
                machineID: capture.machineID, source: capture.source, locator: capture.locator,
                generation: capture.generation, wholeSourceSHA256: capture.wholeSourceSHA256,
                replayLayout: manifest.replayLayout
            )
            guard ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(identity)) == capture.captureID else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            return
        }
        guard reservation.snapshot == nil else { throw CollectorPublicationWorkerError.invalidCapture }
        // Match ExactSourceCapturer's existing content identity, without opening
        // an ArchiveCatalog or turning index/session bindings into authority.
        struct CaptureIdentity: Encodable {
            let machineID: String
            let source: String
            let locator: String
            let generation: ArchiveSourceGeneration
            let wholeSourceSHA256: String
        }
        let identity = CaptureIdentity(machineID: capture.machineID, source: capture.source, locator: capture.locator,
            generation: capture.generation, wholeSourceSHA256: capture.wholeSourceSHA256)
        guard ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(identity)) == capture.captureID else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
    }

    private static func locatorMatchesReservation(
        _ locator: String, configuration: CollectorRootConfiguration, reservation: CollectorCaptureReservation
    ) -> Bool {
        let bases = locatorBases(configuration: configuration, relativePath: reservation.relativePath)
        if let legacy = reservation.cursorLegacySession {
            return bases.contains { $0.utf8.elementsEqual(legacy.databaseLocator.utf8) }
                && locator.utf8.elementsEqual(legacy.logicalLocator.utf8)
        }
        if let session = reservation.sqliteSession {
            return bases.contains { base in
                session.databaseLocator.utf8.elementsEqual(base.utf8)
                    && locator.utf8.elementsEqual((base + "::" + session.nativeSessionID).utf8)
            }
        }
        return bases.contains { locator.utf8.elementsEqual($0.utf8) }
    }

    private static func locatorBases(configuration: CollectorRootConfiguration, relativePath: String) -> [String] {
        var values = [
            URL(fileURLWithPath: configuration.rootPath).appendingPathComponent(relativePath).path,
            configuration.rootPath + "/" + relativePath,
        ]
        if let root = ArchiveSourceDescriptor.fileSetAbsolutePath(configuration.rootPath) {
            values.append(root + "/" + relativePath)
        }
        return values
    }

    private func write<T>(_ body: (Database) throws -> T) throws -> T {
        try database.write { db in
            guard let activeOwner = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'active_owner_run_id'"),
                  activeOwner.utf8.elementsEqual(ownerRunID.utf8) else {
                throw CollectorInventoryError.staleOwner
            }
            let result = try body(db)
            try testHooks.beforeCommit?()
            return result
        }
    }

    private func applyDeferClaim(
        _ db: Database, _ claim: CollectorDirtyClaim, retryNotBefore: Int64, reason: String
    ) throws -> Bool {
        guard Self.isSafeRelativePath(claim.relativePath),
              let row = try currentClaimRow(db, claim) else { return false }
        let currentDirty: Int64 = row["dirty_revision"]
        if currentDirty > claim.dirtyRevision {
            try db.execute(sql: """
                UPDATE collector_locators SET claimed_dirty_revision = NULL, claim_owner_run_id = NULL,
                    retry_not_before = NULL, last_error = NULL
                WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [claim.rootID, claim.rootRevision, claim.relativePath])
            return true
        }
        try db.execute(sql: """
            UPDATE collector_locators SET claimed_dirty_revision = NULL, claim_owner_run_id = NULL,
                retry_not_before = ?, last_error = ?
            WHERE root_id = ? AND root_revision = ? AND relative_path = ?
            """, arguments: [retryNotBefore, reason, claim.rootID, claim.rootRevision, claim.relativePath])
        return true
    }

    private func currentClaimRow(_ db: Database, _ claim: CollectorDirtyClaim) throws -> Row? {
        guard claim.ownerRunID.utf8.elementsEqual(ownerRunID.utf8),
              let root = try Self.rootState(db, rootID: claim.rootID), root.configuration.revision == claim.rootRevision,
              let row = try Self.locatorRow(db, root.configuration, claim.relativePath) else { return nil }
        let owner: String? = row["claim_owner_run_id"]
        let generation: Int64 = row["claim_generation"]
        let revision: Int64? = row["claimed_dirty_revision"]
        let ownerMatches = owner?.utf8.elementsEqual(claim.ownerRunID.utf8) ?? false
        return ownerMatches && generation == claim.claimGeneration && revision == claim.dirtyRevision ? row : nil
    }

    private static func rootBinding(
        _ db: Database,
        _ configuration: CollectorRootConfiguration
    ) throws -> (binding: CollectorPOSIXRootBinding, lastActivatedOwnerRunID: String?)? {
        let row: Row?
        do {
            row = try Row.fetchOne(db, sql: """
                SELECT device, inode, generation, birth_seconds, birth_nanoseconds, last_activated_owner_run_id
                FROM collector_root_bindings WHERE root_id = ? AND root_revision = ?
                """, arguments: [configuration.rootID, configuration.revision])
        } catch let error as DatabaseError where error.resultCode == .SQLITE_ERROR {
            // Missing binding columns are corrupt state, not an unenrolled root.
            throw CollectorInventoryError.invalidState
        }
        guard let row else { return nil }
        let deviceValue: DatabaseValue = row["device"]
        let inodeValue: DatabaseValue = row["inode"]
        let generationValue: DatabaseValue = row["generation"]
        let secondsValue: DatabaseValue = row["birth_seconds"]
        let nanosecondsValue: DatabaseValue = row["birth_nanoseconds"]
        let ownerValue: DatabaseValue = row["last_activated_owner_run_id"]
        guard case let .int64(device) = deviceValue.storage,
              case let .int64(inode) = inodeValue.storage,
              case let .int64(rawGeneration) = generationValue.storage,
              let generation = UInt32(exactly: rawGeneration),
              case let .int64(seconds) = secondsValue.storage,
              case let .int64(nanoseconds) = nanosecondsValue.storage,
              (0..<1_000_000_000).contains(nanoseconds) else {
            throw CollectorInventoryError.invalidState
        }
        let owner: String?
        switch ownerValue.storage {
        case .null: owner = nil
        case let .string(value) where !value.isEmpty: owner = value
        default: throw CollectorInventoryError.invalidState
        }
        let identity = CollectorPOSIXDirectoryIdentity(
            device: device, inode: inode, generation: generation,
            birthSeconds: seconds, birthNanoseconds: nanoseconds
        )
        return (.init(configuration: configuration, expectedIdentity: identity), owner)
    }

    private static func hasUnacknowledgedDirty(
        _ db: Database, _ configuration: CollectorRootConfiguration
    ) throws -> Bool {
        try Int.fetchOne(db, sql: """
            SELECT 1 FROM collector_locators INDEXED BY collector_pending_locators
            WHERE root_id = ? AND root_revision = ? AND dirty_revision > acknowledged_revision LIMIT 1
            """, arguments: [configuration.rootID, configuration.revision]) != nil
    }

    @discardableResult
    private static func requireRoot(_ db: Database, _ configuration: CollectorRootConfiguration) throws -> CollectorRootState {
        guard let root = try rootState(db, rootID: configuration.rootID), root.configuration == configuration else {
            throw CollectorInventoryError.unknownRoot
        }
        return root
    }

    private static func rootState(_ db: Database, rootID: String) throws -> CollectorRootState? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM collector_roots WHERE root_id = ?", arguments: [rootID]) else { return nil }
        let rawSource: String = row["source"]
        guard let source = SourceName(rawValue: rawSource) else { throw CollectorInventoryError.invalidState }
        let legacy: Int = row["cursor_legacy"]
        guard legacy == 0 || legacy == 1 else { throw CollectorInventoryError.invalidState }
        let configuration = CollectorRootConfiguration(rootID: rootID, source: source, rootPath: row["root_path"],
            revision: row["root_revision"], cursorLegacy: legacy == 1, cursorModernRootID: row["cursor_modern_root_id"])
        guard configuration.validCursorLayout else { throw CollectorInventoryError.invalidState }
        let scanID: String? = row["active_scan_id"]
        let scanRevision: Int64? = row["active_scan_requested_revision"]
        let epoch: String? = row["event_epoch"]
        let cursor: String? = row["event_cursor"]
        let reason: String? = row["last_scan_failure"]
        let failure: CollectorBootstrapFailure?
        switch reason {
        case nil: failure = nil
        case "unsafeEntry": failure = .unsafeEntry
        case "enumerationUnavailable": failure = .enumerationUnavailable
        default: throw CollectorInventoryError.invalidState
        }
        guard (scanID == nil) == (scanRevision == nil), (epoch == nil) == (cursor == nil) else {
            throw CollectorInventoryError.invalidState
        }
        let scan = scanID.flatMap { id in scanRevision.map { CollectorScanToken(rootID: rootID, rootRevision: configuration.revision, scanID: id, requestedRevision: $0) } }
        let checkpoint = epoch.flatMap { epoch in cursor.map { CollectorEventCheckpoint(epoch: epoch, cursor: $0) } }
        return CollectorRootState(
            configuration: configuration, requestedRevision: row["requested_revision"], completedRevision: row["completed_revision"],
            eventCheckpoint: checkpoint, activeScan: scan, lastScanFailure: failure
        )
    }

    private static func locatorRow(_ db: Database, _ configuration: CollectorRootConfiguration, _ path: String) throws -> Row? {
        try Row.fetchOne(db, sql: "SELECT * FROM collector_locators WHERE root_id = ? AND root_revision = ? AND relative_path = ?", arguments: [configuration.rootID, configuration.revision, path])
    }

    private static func locatorState(_ row: Row) -> CollectorLocatorState {
        CollectorLocatorState(
            relativePath: row["relative_path"], observedGeneration: row["observed_generation"],
            dirtyRevision: row["dirty_revision"], acknowledgedRevision: row["acknowledged_revision"],
            lastCaptureID: row["last_capture_id"], retryNotBefore: row["retry_not_before"], lastError: row["last_error"]
        )
    }

    static func openCodeObservationFingerprint(
        databaseGeneration: ArchiveSourceGeneration, walGeneration: ArchiveSourceGeneration?
    ) throws -> String {
        struct Pair: Encodable {
            let databaseGeneration: ArchiveSourceGeneration
            let walGeneration: ArchiveSourceGeneration?
        }
        let encoded = try ArchiveCanonicalJSON.encode(
            Pair(databaseGeneration: databaseGeneration, walGeneration: walGeneration)
        )
        return "opencode-pair-v1:" + String(decoding: encoded, as: UTF8.self)
    }

    private static func touchLocatorSeenScan(
        _ db: Database, _ configuration: CollectorRootConfiguration, _ path: String, seenScanID: String
    ) throws {
        try db.execute(sql: """
            UPDATE collector_locators SET last_seen_scan_id = ?
            WHERE root_id = ? AND root_revision = ? AND relative_path = ?
            """, arguments: [seenScanID, configuration.rootID, configuration.revision, path])
    }

    private static func upsertDirty(
        _ db: Database, _ configuration: CollectorRootConfiguration, _ path: String,
        observedGeneration: String?, seenScanID: String?
    ) throws {
        if let row = try locatorRow(db, configuration, path) {
            let revision = try increment(row["dirty_revision"])
            try db.execute(sql: """
                UPDATE collector_locators SET dirty_revision = ?, observed_generation = COALESCE(?, observed_generation),
                    last_seen_scan_id = COALESCE(?, last_seen_scan_id),
                    retry_not_before = NULL, last_error = NULL
                WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [revision, observedGeneration, seenScanID, configuration.rootID, configuration.revision, path])
        } else {
            try db.execute(sql: """
                INSERT INTO collector_locators(root_id, root_revision, relative_path, observed_generation, last_seen_scan_id,
                    dirty_revision, acknowledged_revision, claim_generation)
                VALUES (?, ?, ?, ?, ?, 1, 0, 0)
                """, arguments: [configuration.rootID, configuration.revision, path, observedGeneration, seenScanID])
        }
    }

    private static func increment(_ revision: Int64) throws -> Int64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow, revision >= 0 else { throw CollectorInventoryError.revisionExhausted }
        return next
    }

    // Rebuild only with foreign keys disabled outside the enclosing transaction.
    // Deferred DROP counters can reject COMMIT even after references are restored.
    private static func migrateEffectiveSourceStreams(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE collector_streams_v10 (
                root_id TEXT NOT NULL, root_revision INTEGER NOT NULL CHECK(root_revision > 0),
                effective_source TEXT NOT NULL,
                source_instance_id TEXT NOT NULL, collector_epoch TEXT NOT NULL,
                last_sequence INTEGER NOT NULL CHECK(typeof(last_sequence) = 'integer' AND last_sequence >= 0),
                PRIMARY KEY(root_id, root_revision, effective_source),
                UNIQUE(root_id, root_revision, source_instance_id, collector_epoch),
                FOREIGN KEY(root_id) REFERENCES collector_roots(root_id)
            ) WITHOUT ROWID;
            INSERT INTO collector_streams_v10
                SELECT stream.root_id, stream.root_revision,
                    CASE WHEN stream.root_revision = root.root_revision THEN root.source ELSE '' END,
                    stream.source_instance_id, stream.collector_epoch, stream.last_sequence
                FROM collector_streams stream JOIN collector_roots root ON root.root_id = stream.root_id;
            """)
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM collector_streams_v10")
            == Int.fetchOne(db, sql: "SELECT count(*) FROM collector_streams") else {
            throw CollectorInventoryError.invalidState
        }
        // Empty source preserves inactive historical rows whose original source
        // cannot be recovered from the current root. Allocation never selects it.
        try db.execute(sql: """
            DROP TABLE collector_streams;
            ALTER TABLE collector_streams_v10 RENAME TO collector_streams;
            """)
    }

    private static func createPublicationSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS collector_streams (
                root_id TEXT NOT NULL, root_revision INTEGER NOT NULL CHECK(root_revision > 0),
                effective_source TEXT NOT NULL,
                source_instance_id TEXT NOT NULL, collector_epoch TEXT NOT NULL,
                last_sequence INTEGER NOT NULL CHECK(typeof(last_sequence) = 'integer' AND last_sequence >= 0),
                PRIMARY KEY(root_id, root_revision, effective_source),
                UNIQUE(root_id, root_revision, source_instance_id, collector_epoch),
                FOREIGN KEY(root_id) REFERENCES collector_roots(root_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS collector_capture_reservations (
                id TEXT PRIMARY KEY NOT NULL, root_id TEXT NOT NULL, root_revision INTEGER NOT NULL,
                relative_path TEXT NOT NULL, dirty_revision INTEGER NOT NULL CHECK(dirty_revision > 0),
                generation_bytes BLOB NOT NULL CHECK(typeof(generation_bytes) = 'blob' AND length(generation_bytes) BETWEEN 1 AND 2048),
                source_instance_id TEXT NOT NULL, collector_epoch TEXT NOT NULL,
                sequence INTEGER NOT NULL CHECK(typeof(sequence) = 'integer' AND sequence > 0),
                dirty_claim_owner_run_id TEXT NOT NULL, dirty_claim_generation INTEGER NOT NULL CHECK(dirty_claim_generation > 0),
                recovery_state BLOB CHECK(recovery_state IS NULL OR (typeof(recovery_state) = 'blob' AND length(recovery_state) BETWEEN 1 AND 2048)),
                gemini_context_bytes BLOB,
                gemini_context_sha256 TEXT,
                sqlite_session_bytes BLOB,
                sqlite_session_sha256 TEXT,
                kimi_context_bytes BLOB,
                kimi_context_sha256 TEXT,
                UNIQUE(root_id, root_revision),
                FOREIGN KEY(root_id, root_revision, source_instance_id, collector_epoch)
                    REFERENCES collector_streams(root_id, root_revision, source_instance_id, collector_epoch),
                FOREIGN KEY(root_id, root_revision, relative_path) REFERENCES collector_locators(root_id, root_revision, relative_path)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS collector_capture_reservation_dependencies (
                reservation_id TEXT NOT NULL, relative_path TEXT NOT NULL,
                presence TEXT NOT NULL CHECK(presence IN ('present', 'absent')),
                generation_bytes BLOB CHECK(
                    (presence = 'present' AND typeof(generation_bytes) = 'blob'
                        AND length(generation_bytes) BETWEEN 1 AND 2048)
                    OR (presence = 'absent' AND generation_bytes IS NULL)
                ),
                PRIMARY KEY(reservation_id, relative_path),
                FOREIGN KEY(reservation_id) REFERENCES collector_capture_reservations(id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS collector_publications (
                publication_digest TEXT PRIMARY KEY NOT NULL, capture_id TEXT NOT NULL,
                root_id TEXT NOT NULL, root_revision INTEGER NOT NULL, relative_path TEXT NOT NULL,
                source_instance_id TEXT NOT NULL, collector_epoch TEXT NOT NULL,
                sequence INTEGER NOT NULL CHECK(typeof(sequence) = 'integer' AND sequence > 0),
                manifest_sha256 TEXT NOT NULL,
                canonical_bytes BLOB NOT NULL CHECK(typeof(canonical_bytes) = 'blob' AND length(canonical_bytes) BETWEEN 1 AND 2048),
                UNIQUE(root_id, root_revision, capture_id), UNIQUE(source_instance_id, collector_epoch, sequence),
                FOREIGN KEY(root_id, root_revision, source_instance_id, collector_epoch)
                    REFERENCES collector_streams(root_id, root_revision, source_instance_id, collector_epoch)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS collector_publication_replicas (
                publication_digest TEXT NOT NULL, replica_id TEXT NOT NULL CHECK(replica_id IN ('hq', 'm1')),
                state TEXT NOT NULL CHECK(state IN ('pending', 'inflight', 'acknowledged')),
                claim_owner_run_id TEXT, claimed_at INTEGER CHECK(claimed_at IS NULL OR (typeof(claimed_at) = 'integer' AND claimed_at >= 0)),
                claim_generation INTEGER NOT NULL CHECK(typeof(claim_generation) = 'integer' AND claim_generation >= 0),
                attempts INTEGER NOT NULL CHECK(typeof(attempts) = 'integer' AND attempts >= 0),
                retry_not_before INTEGER CHECK(retry_not_before IS NULL OR (typeof(retry_not_before) = 'integer' AND retry_not_before > 0)),
                last_error TEXT CHECK(last_error IN ('unavailable', 'unsupportedReplica', 'invalidACK', 'privacyWithheld', 'localContentUnavailable')),
                ack_bytes BLOB CHECK(ack_bytes IS NULL OR (typeof(ack_bytes) = 'blob' AND length(ack_bytes) BETWEEN 1 AND 4096)),
                PRIMARY KEY(publication_digest, replica_id),
                FOREIGN KEY(publication_digest) REFERENCES collector_publications(publication_digest),
                CHECK((state = 'inflight') = (claim_owner_run_id IS NOT NULL)),
                CHECK((state = 'inflight') = (claimed_at IS NOT NULL)),
                CHECK((state = 'acknowledged') = (ack_bytes IS NOT NULL))
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS collector_publication_pending
                ON collector_publication_replicas(replica_id, state, retry_not_before, publication_digest)
                WHERE state != 'acknowledged';
            """)
    }

    private static let maximumGeminiContextBytes = 16_384
    private static let maximumSQLiteSessionBytes = 16_384
    private static let maximumCursorLegacySessionBytes = 16_384
    private static let maximumKimiContextBytes = 16_384

    private static func migrateGeminiRegistryObserverColumns(_ db: Database) throws {
        let columns = try db.columns(in: "collector_roots").map(\.name)
        if !columns.contains("gemini_registry_locator") {
            try db.execute(sql: "ALTER TABLE collector_roots ADD COLUMN gemini_registry_locator TEXT")
        }
        if !columns.contains("gemini_registry_generation") {
            try db.execute(sql: "ALTER TABLE collector_roots ADD COLUMN gemini_registry_generation TEXT")
        }
        if !columns.contains("gemini_registry_page_after") {
            try db.execute(sql: "ALTER TABLE collector_roots ADD COLUMN gemini_registry_page_after TEXT")
        }
    }

    private static func migrateOpenCodeWalkColumns(_ db: Database) throws {
        let roots = try db.columns(in: "collector_roots").map(\.name)
        if !roots.contains("opencode_walk_generation") {
            try db.execute(sql: "ALTER TABLE collector_roots ADD COLUMN opencode_walk_generation TEXT")
        }
        if !roots.contains("opencode_walk_wal_generation") {
            try db.execute(sql: "ALTER TABLE collector_roots ADD COLUMN opencode_walk_wal_generation TEXT")
        }
        if !roots.contains("opencode_walk_page_after") {
            try db.execute(sql: "ALTER TABLE collector_roots ADD COLUMN opencode_walk_page_after TEXT")
        }
        let reservations = try db.columns(in: "collector_capture_reservations").map(\.name)
        if !reservations.contains("sqlite_session_bytes") {
            try db.execute(sql: "ALTER TABLE collector_capture_reservations ADD COLUMN sqlite_session_bytes BLOB")
        }
        if !reservations.contains("sqlite_session_sha256") {
            try db.execute(sql: "ALTER TABLE collector_capture_reservations ADD COLUMN sqlite_session_sha256 TEXT")
        }
    }

    private static func validateRegistryObserver(
        locator: String?, generationText: String?, pageAfter: String?
    ) throws {
        if locator == nil {
            guard generationText == nil, pageAfter == nil else { throw CollectorInventoryError.invalidState }
            return
        }
        guard ArchiveSourceDescriptor.fileSetAbsolutePath(locator!) == locator else {
            throw CollectorInventoryError.invalidState
        }
        if let pageAfter, !pageAfter.isEmpty {
            guard isSafeRelativePath(pageAfter) else { throw CollectorInventoryError.invalidState }
        }
    }

    private static func decodeRegistryGeneration(_ text: String?) throws -> ArchiveSourceGeneration? {
        guard let text else { return nil }
        guard let bytes = text.data(using: .utf8) else { throw CollectorInventoryError.invalidState }
        let generation = try ArchiveCanonicalJSON.decode(ArchiveSourceGeneration.self, from: bytes)
        guard try ArchiveCanonicalJSON.encode(generation) == bytes else {
            throw CollectorInventoryError.invalidState
        }
        return generation
    }

    private static func saveRegistryObserver(
        _ db: Database, rootID: String, locator: String, generation: ArchiveSourceGeneration?, pageAfter: String?
    ) throws {
        let generationText: String?
        if let generation {
            let bytes = try ArchiveCanonicalJSON.encode(generation)
            guard let text = String(data: bytes, encoding: .utf8), !text.isEmpty else {
                throw CollectorInventoryError.invalidState
            }
            generationText = text
        } else {
            generationText = nil
        }
        if let pageAfter {
            guard isSafeRelativePath(pageAfter) else { throw CollectorInventoryError.invalidState }
        }
        try db.execute(sql: """
            UPDATE collector_roots SET gemini_registry_locator = ?, gemini_registry_generation = ?,
                gemini_registry_page_after = ? WHERE root_id = ?
            """, arguments: [locator, generationText, pageAfter, rootID])
    }

    private static func migrateGeminiContextColumns(_ db: Database) throws {
        let columns = try db.columns(in: "collector_capture_reservations").map(\.name)
        if !columns.contains("gemini_context_bytes") {
            try db.execute(sql: "ALTER TABLE collector_capture_reservations ADD COLUMN gemini_context_bytes BLOB")
        }
        if !columns.contains("gemini_context_sha256") {
            try db.execute(sql: "ALTER TABLE collector_capture_reservations ADD COLUMN gemini_context_sha256 TEXT")
        }
    }

    private static func migrateKimiContextColumns(_ db: Database) throws {
        let columns = try db.columns(in: "collector_capture_reservations").map(\.name)
        if !columns.contains("kimi_context_bytes") {
            try db.execute(sql: "ALTER TABLE collector_capture_reservations ADD COLUMN kimi_context_bytes BLOB")
        }
        if !columns.contains("kimi_context_sha256") {
            try db.execute(sql: "ALTER TABLE collector_capture_reservations ADD COLUMN kimi_context_sha256 TEXT")
        }
    }

    private static func requireCompositeSnapshot(_ snapshot: CollectorDependencySnapshot, entrypoint: String) throws {
        guard snapshot.vscodeWorkspaceContext == nil else { throw CollectorPublicationWorkerError.invalidCapture }
        if snapshot.kimiProjectContext != nil {
            guard snapshot.geminiProjectContext == nil else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            try CollectorKimiSource.requireValidSnapshot(snapshot, entrypoint: entrypoint)
            return
        }
        let parts = entrypoint.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if CollectorGrokSource.isPrimaryCandidate(components: parts) {
            try CollectorGrokSource.requireValidSnapshot(snapshot, entrypoint: entrypoint)
            return
        }
        if CollectorGeminiSource.isSelectedPrimary(rootPath: "", components: parts) {
            try CollectorGeminiSource.requireValidSnapshot(snapshot, entrypoint: entrypoint)
        } else {
            try CollectorCopilotSource.requireValidSnapshot(snapshot, entrypoint: entrypoint)
        }
    }

    private static func encodeGeminiContext(
        _ context: ArchiveGeminiProjectContext?
    ) throws -> (bytes: Data?, digest: String?) {
        guard let context else { return (nil, nil) }
        let bytes = try ArchiveCanonicalJSON.encode(context)
        guard (1...maximumGeminiContextBytes).contains(bytes.count) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return (bytes, ArchiveV2Hash.sha256(bytes))
    }

    private static func decodeGeminiContext(bytes: Data?, digest: String?) throws -> ArchiveGeminiProjectContext? {
        switch (bytes, digest) {
        case (nil, nil):
            return nil
        case let (bytes?, digest?):
            guard (1...maximumGeminiContextBytes).contains(bytes.count),
                  ArchiveV2Hash.isValidSHA256(digest),
                  ArchiveV2Hash.sha256(bytes) == digest else {
                throw CollectorInventoryError.invalidState
            }
            let context = try ArchiveCanonicalJSON.decode(ArchiveGeminiProjectContext.self, from: bytes)
            guard try ArchiveCanonicalJSON.encode(context) == bytes else {
                throw CollectorInventoryError.invalidState
            }
            return context
        default:
            throw CollectorInventoryError.invalidState
        }
    }

    // Base64 expansion of a 64 KiB payload plus a bounded locator and generation.
    private static let maximumVSCodeContextBytes = 131_072

    private static func migrateVSCodeContextColumns(_ db: Database) throws {
        let columns = try db.columns(in: "collector_capture_reservations").map(\.name)
        if !columns.contains("vscode_context_bytes") {
            try db.execute(sql: "ALTER TABLE collector_capture_reservations ADD COLUMN vscode_context_bytes BLOB")
        }
        if !columns.contains("vscode_context_sha256") {
            try db.execute(sql: "ALTER TABLE collector_capture_reservations ADD COLUMN vscode_context_sha256 TEXT")
        }
    }

    private static func encodeVSCodeContext(
        _ context: ArchiveVSCodeWorkspaceContext?
    ) throws -> (bytes: Data?, digest: String?) {
        guard let context else { return (nil, nil) }
        let bytes = try ArchiveCanonicalJSON.encode(context)
        guard (1...maximumVSCodeContextBytes).contains(bytes.count) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return (bytes, ArchiveV2Hash.sha256(bytes))
    }

    private static func decodeVSCodeContext(bytes: Data?, digest: String?) throws -> ArchiveVSCodeWorkspaceContext? {
        switch (bytes, digest) {
        case (nil, nil):
            return nil
        case let (bytes?, digest?):
            guard (1...maximumVSCodeContextBytes).contains(bytes.count),
                  ArchiveV2Hash.isValidSHA256(digest),
                  ArchiveV2Hash.sha256(bytes) == digest else {
                throw CollectorInventoryError.invalidState
            }
            let context = try ArchiveCanonicalJSON.decode(ArchiveVSCodeWorkspaceContext.self, from: bytes)
            guard try ArchiveCanonicalJSON.encode(context) == bytes else {
                throw CollectorInventoryError.invalidState
            }
            return context
        default:
            throw CollectorInventoryError.invalidState
        }
    }

    private static func encodeKimiContext(
        _ context: ArchiveKimiProjectContext?
    ) throws -> (bytes: Data?, digest: String?) {
        guard let context else { return (nil, nil) }
        let bytes = try ArchiveCanonicalJSON.encode(context)
        guard (1...maximumKimiContextBytes).contains(bytes.count) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return (bytes, ArchiveV2Hash.sha256(bytes))
    }

    private static func decodeKimiContext(bytes: Data?, digest: String?) throws -> ArchiveKimiProjectContext? {
        switch (bytes, digest) {
        case (nil, nil):
            return nil
        case let (bytes?, digest?):
            guard (1...maximumKimiContextBytes).contains(bytes.count),
                  ArchiveV2Hash.isValidSHA256(digest),
                  ArchiveV2Hash.sha256(bytes) == digest else {
                throw CollectorInventoryError.invalidState
            }
            let context = try ArchiveCanonicalJSON.decode(ArchiveKimiProjectContext.self, from: bytes)
            guard try ArchiveCanonicalJSON.encode(context) == bytes else {
                throw CollectorInventoryError.invalidState
            }
            return context
        default:
            throw CollectorInventoryError.invalidState
        }
    }

    private static func encodeSQLiteSession(
        _ context: ArchiveSQLiteSessionContext?
    ) throws -> (bytes: Data?, digest: String?) {
        guard let context else { return (nil, nil) }
        let bytes = try ArchiveCanonicalJSON.encode(context)
        guard (1...maximumSQLiteSessionBytes).contains(bytes.count) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return (bytes, ArchiveV2Hash.sha256(bytes))
    }

    private static func decodeSQLiteSession(
        bytes: Data?, digest: String?
    ) throws -> ArchiveSQLiteSessionContext? {
        switch (bytes, digest) {
        case (nil, nil):
            return nil
        case let (bytes?, digest?):
            guard (1...maximumSQLiteSessionBytes).contains(bytes.count),
                  ArchiveV2Hash.isValidSHA256(digest),
                  ArchiveV2Hash.sha256(bytes) == digest else {
                throw CollectorInventoryError.invalidState
            }
            let context = try ArchiveCanonicalJSON.decode(ArchiveSQLiteSessionContext.self, from: bytes)
            guard try ArchiveCanonicalJSON.encode(context) == bytes else {
                throw CollectorInventoryError.invalidState
            }
            return context
        default:
            throw CollectorInventoryError.invalidState
        }
    }

    private static func requireRegularGeneration(_ generation: ArchiveSourceGeneration) throws {
        guard generation.mode & 0o170000 == 0o100000 else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let bytes = try ArchiveCanonicalJSON.encode(generation)
        guard bytes.count <= 2_048 else { throw CollectorPublicationWorkerError.invalidCapture }
    }

    private static func requireValidSQLiteSession(
        _ session: ArchiveSQLiteSessionContext, configuration: CollectorRootConfiguration, relativePath: String
    ) throws {
        guard configuration.source == .opencode, relativePath == "opencode.db",
              isSafeRelativePath(session.nativeSessionID),
              locatorBases(configuration: configuration, relativePath: relativePath).contains(where: {
                  session.databaseLocator.utf8.elementsEqual($0.utf8)
              }) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        if let wal = session.walGeneration { try requireRegularGeneration(wal) }
    }

    private static func requireOpenCodeSessionAfterCursor(
        _ db: Database, configuration: CollectorRootConfiguration, generation: ArchiveSourceGeneration,
        session: ArchiveSQLiteSessionContext
    ) throws {
        let stored = try openCodeWalk(db, rootID: configuration.rootID)
        guard stored.generation == generation, stored.walGeneration == session.walGeneration else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        guard let pageAfter = stored.pageAfter else { return }
        guard pageAfter.utf8.lexicographicallyPrecedes(session.nativeSessionID.utf8) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
    }

    private static func openCodeWalk(
        _ db: Database, rootID: String
    ) throws -> (
        generation: ArchiveSourceGeneration?, walGeneration: ArchiveSourceGeneration?, pageAfter: String?
    ) {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT opencode_walk_generation, opencode_walk_wal_generation, opencode_walk_page_after
            FROM collector_roots WHERE root_id = ?
            """, arguments: [rootID]) else {
            throw CollectorInventoryError.unknownRoot
        }
        let generation = try decodeRegistryGeneration(row["opencode_walk_generation"])
        let walGeneration = try decodeRegistryGeneration(row["opencode_walk_wal_generation"])
        let pageAfter: String? = row["opencode_walk_page_after"]
        if generation == nil {
            guard walGeneration == nil, pageAfter == nil else { throw CollectorInventoryError.invalidState }
            return (nil, nil, nil)
        }
        if let pageAfter {
            guard isSafeRelativePath(pageAfter) else { throw CollectorInventoryError.invalidState }
        }
        return (generation, walGeneration, pageAfter)
    }

    private static func saveOpenCodeWalk(
        _ db: Database, rootID: String, generation: ArchiveSourceGeneration,
        walGeneration: ArchiveSourceGeneration?, pageAfter: String?
    ) throws {
        if let pageAfter {
            guard isSafeRelativePath(pageAfter) else { throw CollectorInventoryError.invalidState }
        }
        let generationText = try encodeRegistryGeneration(generation)
        let walText = try walGeneration.map { try encodeRegistryGeneration($0) }
        try db.execute(sql: """
            UPDATE collector_roots SET opencode_walk_generation = ?, opencode_walk_wal_generation = ?,
                opencode_walk_page_after = ? WHERE root_id = ?
            """, arguments: [generationText, walText, pageAfter, rootID])
    }

    private static func encodeRegistryGeneration(_ generation: ArchiveSourceGeneration) throws -> String {
        let bytes = try ArchiveCanonicalJSON.encode(generation)
        guard bytes.count <= 2_048, let text = String(data: bytes, encoding: .utf8), !text.isEmpty else {
            throw CollectorInventoryError.invalidState
        }
        return text
    }

    private static func advanceOpenCodeWalkIfCurrent(_ db: Database, reservation: CollectorCaptureReservation) throws {
        guard let session = reservation.sqliteSession else { return }
        let stored = try openCodeWalk(db, rootID: reservation.rootID)
        guard stored.generation == reservation.generation, stored.walGeneration == session.walGeneration else {
            return
        }
        try saveOpenCodeWalk(
            db, rootID: reservation.rootID, generation: reservation.generation,
            walGeneration: session.walGeneration, pageAfter: session.nativeSessionID
        )
    }

    private static func validCursorComposerID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.utf8.contains(0)
    }

    private static func migrateCursorLegacyColumns(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS collector_cursor_legacy_workspaces (
                root_id TEXT NOT NULL, root_revision INTEGER NOT NULL,
                workspace_id TEXT NOT NULL COLLATE BINARY, fingerprint TEXT NOT NULL,
                PRIMARY KEY(root_id, root_revision, workspace_id),
                FOREIGN KEY(root_id) REFERENCES collector_roots(root_id)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS collector_cursor_legacy_sessions (
                root_id TEXT NOT NULL, root_revision INTEGER NOT NULL,
                composer_id TEXT NOT NULL COLLATE BINARY, capture_id TEXT NOT NULL,
                PRIMARY KEY(root_id, root_revision, composer_id),
                FOREIGN KEY(root_id) REFERENCES collector_roots(root_id)
            ) WITHOUT ROWID
            """)
        let roots = try db.columns(in: "collector_roots").map(\.name)
        for (name, type) in [("cursor_legacy_observer_membership", "TEXT"), ("cursor_legacy_observer_main", "TEXT"),
                             ("cursor_legacy_observer_peer", "TEXT"), ("cursor_legacy_observer_after", "TEXT"),
                             ("cursor_legacy_observer_error", "TEXT"),
                             ("cursor_legacy_observer_initialized", "INTEGER NOT NULL DEFAULT 0 CHECK(cursor_legacy_observer_initialized IN (0, 1))"),
                             ("cursor_legacy", "INTEGER NOT NULL DEFAULT 0 CHECK(cursor_legacy IN (0, 1))"),
                             ("cursor_modern_root_id", "TEXT"), ("cursor_legacy_walk_generation", "TEXT"), ("cursor_legacy_walk_wal_generation", "TEXT"),
                             ("cursor_legacy_walk_page_after", "TEXT"), ("cursor_legacy_walk_dirty_revision", "INTEGER")] {
            if !roots.contains(name) { try db.execute(sql: "ALTER TABLE collector_roots ADD COLUMN \(name) \(type)") }
        }
        let reservations = try db.columns(in: "collector_capture_reservations").map(\.name)
        for (name, type) in [("cursor_legacy_bytes", "BLOB"), ("cursor_legacy_sha256", "TEXT")] {
            if !reservations.contains(name) { try db.execute(sql: "ALTER TABLE collector_capture_reservations ADD COLUMN \(name) \(type)") }
        }
    }

    private static func encodeCursorLegacySession(
        _ context: ArchiveCursorLegacyContext?
    ) throws -> (bytes: Data?, digest: String?) {
        guard let context else { return (nil, nil) }
        let bytes = try ArchiveCanonicalJSON.encode(context)
        guard (1...maximumCursorLegacySessionBytes).contains(bytes.count) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return (bytes, ArchiveV2Hash.sha256(bytes))
    }

    private static func decodeCursorLegacySession(
        bytes: Data?, digest: String?
    ) throws -> ArchiveCursorLegacyContext? {
        switch (bytes, digest) {
        case (nil, nil):
            return nil
        case let (bytes?, digest?):
            guard (1...maximumCursorLegacySessionBytes).contains(bytes.count),
                  ArchiveV2Hash.isValidSHA256(digest),
                  ArchiveV2Hash.sha256(bytes) == digest else {
                throw CollectorInventoryError.invalidState
            }
            let context = try ArchiveCanonicalJSON.decode(ArchiveCursorLegacyContext.self, from: bytes)
            guard try ArchiveCanonicalJSON.encode(context) == bytes else {
                throw CollectorInventoryError.invalidState
            }
            return context
        default:
            throw CollectorInventoryError.invalidState
        }
    }

    private static func requireValidCursorLegacySession(
        _ session: ArchiveCursorLegacyContext, configuration: CollectorRootConfiguration, relativePath: String
    ) throws {
        guard configuration.source == .cursor, relativePath == "state.vscdb",
              validCursorComposerID(session.composerID),
              locatorBases(configuration: configuration, relativePath: relativePath).contains(where: {
                  session.databaseLocator.utf8.elementsEqual($0.utf8)
              }) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        if let wal = session.walGeneration { try requireRegularGeneration(wal) }
    }

    private static func requireCursorLegacySessionAfterCursor(
        _ db: Database, configuration: CollectorRootConfiguration, generation: ArchiveSourceGeneration,
        session: ArchiveCursorLegacyContext, dirtyRevision: Int64
    ) throws {
        let stored = try cursorLegacyWalk(db, rootID: configuration.rootID)
        guard stored.generation == generation, stored.walGeneration == session.walGeneration, stored.dirtyRevision == dirtyRevision else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        guard let pageAfter = stored.pageAfter else { return }
        guard pageAfter.utf8.lexicographicallyPrecedes(session.composerID.utf8) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
    }

    private static func cursorLegacyWalk(
        _ db: Database, rootID: String
    ) throws -> (
        generation: ArchiveSourceGeneration?, walGeneration: ArchiveSourceGeneration?, pageAfter: String?, dirtyRevision: Int64?
    ) {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT cursor_legacy_walk_generation, cursor_legacy_walk_wal_generation, cursor_legacy_walk_page_after, cursor_legacy_walk_dirty_revision
            FROM collector_roots WHERE root_id = ?
            """, arguments: [rootID]) else {
            throw CollectorInventoryError.unknownRoot
        }
        let generation = try decodeRegistryGeneration(row["cursor_legacy_walk_generation"])
        let walGeneration = try decodeRegistryGeneration(row["cursor_legacy_walk_wal_generation"])
        let pageAfter: String? = row["cursor_legacy_walk_page_after"]
        let dirtyRevision: Int64? = row["cursor_legacy_walk_dirty_revision"]
        if generation == nil {
            guard walGeneration == nil, pageAfter == nil, dirtyRevision == nil else { throw CollectorInventoryError.invalidState }
            return (nil, nil, nil, nil)
        }
        if let pageAfter {
            guard validCursorComposerID(pageAfter) else { throw CollectorInventoryError.invalidState }
        }
        guard let dirtyRevision, dirtyRevision > 0 else { throw CollectorInventoryError.invalidState }
        return (generation, walGeneration, pageAfter, dirtyRevision)
    }

    private static func saveCursorLegacyWalk(
        _ db: Database, rootID: String, generation: ArchiveSourceGeneration,
        walGeneration: ArchiveSourceGeneration?, pageAfter: String?, dirtyRevision: Int64
    ) throws {
        if let pageAfter {
            guard validCursorComposerID(pageAfter) else { throw CollectorInventoryError.invalidState }
        }
        let generationText = try encodeRegistryGeneration(generation)
        let walText = try walGeneration.map { try encodeRegistryGeneration($0) }
        try db.execute(sql: """
            UPDATE collector_roots SET cursor_legacy_walk_generation = ?, cursor_legacy_walk_wal_generation = ?,
                cursor_legacy_walk_page_after = ?, cursor_legacy_walk_dirty_revision = ? WHERE root_id = ?
            """, arguments: [generationText, walText, pageAfter, dirtyRevision, rootID])
    }

    private static func advanceCursorLegacyWalkIfCurrent(_ db: Database, reservation: CollectorCaptureReservation) throws {
        guard let session = reservation.cursorLegacySession else { return }
        let stored = try cursorLegacyWalk(db, rootID: reservation.rootID)
        guard stored.generation == reservation.generation, stored.walGeneration == session.walGeneration, stored.dirtyRevision == reservation.dirtyRevision else {
            return
        }
        try saveCursorLegacyWalk(
            db, rootID: reservation.rootID, generation: reservation.generation,
            walGeneration: session.walGeneration, pageAfter: session.composerID, dirtyRevision: reservation.dirtyRevision
        )
    }

    private static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS collector_metadata (
                key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS collector_roots (
                root_id TEXT PRIMARY KEY NOT NULL, source TEXT NOT NULL, root_path TEXT NOT NULL,
                root_revision INTEGER NOT NULL CHECK(root_revision > 0),
                requested_revision INTEGER NOT NULL CHECK(requested_revision > 0),
                completed_revision INTEGER NOT NULL CHECK(completed_revision >= 0 AND completed_revision <= requested_revision),
                event_epoch TEXT, event_cursor TEXT, active_scan_id TEXT, active_scan_requested_revision INTEGER, claim_cursor TEXT,
                gemini_registry_locator TEXT, gemini_registry_generation TEXT, gemini_registry_page_after TEXT,
                opencode_walk_generation TEXT, opencode_walk_wal_generation TEXT, opencode_walk_page_after TEXT,
                last_scan_failure TEXT CHECK(last_scan_failure IN ('unsafeEntry', 'enumerationUnavailable')),
                CHECK((event_epoch IS NULL) = (event_cursor IS NULL)),
                CHECK((active_scan_id IS NULL) = (active_scan_requested_revision IS NULL))
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS collector_root_bindings (
                root_id TEXT NOT NULL, root_revision INTEGER NOT NULL CHECK(root_revision > 0),
                device INTEGER NOT NULL CHECK(typeof(device) = 'integer'),
                inode INTEGER NOT NULL CHECK(typeof(inode) = 'integer'),
                generation INTEGER NOT NULL CHECK(typeof(generation) = 'integer' AND generation BETWEEN 0 AND 4294967295),
                birth_seconds INTEGER NOT NULL CHECK(typeof(birth_seconds) = 'integer'),
                birth_nanoseconds INTEGER NOT NULL CHECK(typeof(birth_nanoseconds) = 'integer' AND birth_nanoseconds BETWEEN 0 AND 999999999),
                last_activated_owner_run_id TEXT CHECK(last_activated_owner_run_id IS NULL OR
                    (typeof(last_activated_owner_run_id) = 'text' AND length(CAST(last_activated_owner_run_id AS BLOB)) > 0)),
                PRIMARY KEY(root_id, root_revision),
                FOREIGN KEY(root_id) REFERENCES collector_roots(root_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS collector_locators (
                root_id TEXT NOT NULL, root_revision INTEGER NOT NULL, relative_path TEXT NOT NULL,
                observed_generation TEXT, last_seen_scan_id TEXT,
                dirty_revision INTEGER NOT NULL CHECK(dirty_revision > 0),
                acknowledged_revision INTEGER NOT NULL CHECK(acknowledged_revision >= 0 AND acknowledged_revision <= dirty_revision),
                last_capture_id TEXT, claim_owner_run_id TEXT,
                claim_generation INTEGER NOT NULL CHECK(claim_generation >= 0), claimed_dirty_revision INTEGER,
                retry_not_before INTEGER, last_error TEXT,
                PRIMARY KEY(root_id, root_revision, relative_path),
                FOREIGN KEY(root_id) REFERENCES collector_roots(root_id),
                CHECK((claim_owner_run_id IS NULL) = (claimed_dirty_revision IS NULL))
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS collector_pending_locators ON collector_locators(root_id, root_revision, relative_path)
                WHERE dirty_revision > acknowledged_revision;
            CREATE TABLE IF NOT EXISTS collector_frontier (
                root_id TEXT NOT NULL, root_revision INTEGER NOT NULL, scan_id TEXT NOT NULL, relative_directory TEXT NOT NULL,
                completed INTEGER NOT NULL CHECK(completed IN (0, 1)),
                PRIMARY KEY(root_id, root_revision, scan_id, relative_directory),
                FOREIGN KEY(root_id) REFERENCES collector_roots(root_id)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS collector_pending_frontier ON collector_frontier(root_id, root_revision, scan_id, relative_directory)
                WHERE completed = 0;
            """)
    }
}
