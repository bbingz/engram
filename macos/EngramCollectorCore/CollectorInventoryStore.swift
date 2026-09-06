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
        try database.write { db in
            try Self.createSchema(db)
            let storedMachineID = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'machine_id'")
            guard storedMachineID == nil || storedMachineID == machineID else {
                throw CollectorInventoryError.machineIDMismatch
            }
            if let version = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'schema_version'"), version != "1" {
                throw CollectorInventoryError.invalidState
            }
            for (key, value) in [("schema_version", "1"), ("machine_id", machineID), ("active_owner_run_id", ownerRunID)] {
                try db.execute(
                    sql: "INSERT INTO collector_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            }
            try testHooks.beforeCommit?()
        }
    }

    func registerRoot(_ configuration: CollectorRootConfiguration) throws {
        guard !configuration.rootID.isEmpty, configuration.revision > 0,
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
                    UPDATE collector_roots SET source = ?, root_path = ?, root_revision = ?,
                        requested_revision = 1, completed_revision = 0, event_epoch = NULL,
                        event_cursor = NULL, active_scan_id = NULL, active_scan_requested_revision = NULL,
                        last_scan_failure = NULL, claim_cursor = NULL WHERE root_id = ?
                    """, arguments: [configuration.source.rawValue, configuration.rootPath, configuration.revision, configuration.rootID])
            } else {
                try db.execute(sql: """
                    INSERT INTO collector_roots(root_id, source, root_path, root_revision, requested_revision, completed_revision)
                    VALUES (?, ?, ?, ?, 1, 0)
                    """, arguments: [configuration.rootID, configuration.source.rawValue, configuration.rootPath, configuration.revision])
            }
        }
    }

    func rootState(rootID: String) throws -> CollectorRootState? {
        try database.read { try Self.rootState($0, rootID: rootID) }
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

    func claimDirty(
        configuration: CollectorRootConfiguration,
        limit: Int,
        now: Int64
    ) throws -> [CollectorDirtyClaim] {
        guard limit >= 0 else { throw CollectorInventoryError.invalidBudget }
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
                guard claimedRevision == nil || claimedOwner != ownerRunID,
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
                    dirtyRevision: dirtyRevision, ownerRunID: ownerRunID, claimGeneration: generation
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
            guard try currentClaimRow(db, claim) != nil else { return false }
            try db.execute(sql: """
                UPDATE collector_locators SET claimed_dirty_revision = NULL, claim_owner_run_id = NULL,
                    retry_not_before = ?, last_error = ?
                WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [retryNotBefore, reason, claim.rootID, claim.rootRevision, claim.relativePath])
            return true
        }
    }

    func beginBootstrap(
        configuration: CollectorRootConfiguration,
        scanID: String
    ) throws -> CollectorScanToken {
        guard !scanID.isEmpty else { throw CollectorInventoryError.invalidState }
        return try write { db in
            let state = try Self.requireRoot(db, configuration)
            if let active = state.activeScan { return active }
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
                if generation == file.observedGeneration, seenScanID == batch.scan.scanID { continue }
                try Self.upsertDirty(db, state.configuration, file.relativePath, observedGeneration: file.observedGeneration, seenScanID: batch.scan.scanID)
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
            try db.execute(sql: """
                UPDATE collector_roots SET completed_revision = ?, active_scan_id = NULL,
                    active_scan_requested_revision = NULL, last_scan_failure = NULL WHERE root_id = ?
                """, arguments: [max(state.completedRevision, scan.requestedRevision), scan.rootID])
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
        requiresReconciliation: Bool
    ) throws {
        try write { db in
            let state = try Self.requireRoot(db, configuration)
            guard state.eventCheckpoint == expectedCheckpoint, !nextCheckpoint.epoch.isEmpty, !nextCheckpoint.cursor.isEmpty,
                  state.eventCheckpoint == nil || state.eventCheckpoint?.epoch == nextCheckpoint.epoch || requiresReconciliation else {
                throw CollectorInventoryError.staleCheckpoint
            }
            for path in dirtyRelativePaths {
                guard Self.isSafeRelativePath(path) else { throw CollectorInventoryError.invalidRelativePath }
                try Self.upsertDirty(db, configuration, path, observedGeneration: nil, seenScanID: nil)
            }
            let requestedRevision = requiresReconciliation ? try Self.increment(state.requestedRevision) : state.requestedRevision
            try db.execute(sql: """
                UPDATE collector_roots SET event_epoch = ?, event_cursor = ?, requested_revision = ? WHERE root_id = ?
                """, arguments: [nextCheckpoint.epoch, nextCheckpoint.cursor, requestedRevision, configuration.rootID])
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

    private func write<T>(_ body: (Database) throws -> T) throws -> T {
        try database.write { db in
            guard try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'active_owner_run_id'") == ownerRunID else {
                throw CollectorInventoryError.staleOwner
            }
            let result = try body(db)
            try testHooks.beforeCommit?()
            return result
        }
    }

    private func currentClaimRow(_ db: Database, _ claim: CollectorDirtyClaim) throws -> Row? {
        guard claim.ownerRunID == ownerRunID,
              let root = try Self.rootState(db, rootID: claim.rootID), root.configuration.revision == claim.rootRevision,
              let row = try Self.locatorRow(db, root.configuration, claim.relativePath) else { return nil }
        let owner: String? = row["claim_owner_run_id"]
        let generation: Int64 = row["claim_generation"]
        let revision: Int64? = row["claimed_dirty_revision"]
        return owner == claim.ownerRunID && generation == claim.claimGeneration && revision == claim.dirtyRevision ? row : nil
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
        let configuration = CollectorRootConfiguration(rootID: rootID, source: source, rootPath: row["root_path"], revision: row["root_revision"])
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

    private static func upsertDirty(
        _ db: Database, _ configuration: CollectorRootConfiguration, _ path: String,
        observedGeneration: String?, seenScanID: String?
    ) throws {
        if let row = try locatorRow(db, configuration, path) {
            let revision = try increment(row["dirty_revision"])
            try db.execute(sql: """
                UPDATE collector_locators SET dirty_revision = ?, observed_generation = COALESCE(?, observed_generation),
                    last_seen_scan_id = COALESCE(?, last_seen_scan_id)
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
                last_scan_failure TEXT CHECK(last_scan_failure IN ('unsafeEntry', 'enumerationUnavailable')),
                CHECK((event_epoch IS NULL) = (event_cursor IS NULL)),
                CHECK((active_scan_id IS NULL) = (active_scan_requested_revision IS NULL))
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
