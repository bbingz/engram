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
            if let version = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'schema_version'"),
               version != "1", version != "2" {
                throw CollectorInventoryError.invalidState
            }
            if let version = try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'publication_schema_version'"),
               version != "1" { throw CollectorInventoryError.invalidState }
            try Self.createPublicationSchema(db)
            for (key, value) in [("schema_version", "2"), ("machine_id", machineID), ("active_owner_run_id", ownerRunID)] {
                try db.execute(
                    sql: "INSERT INTO collector_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            }
            try db.execute(sql: "INSERT OR IGNORE INTO collector_metadata(key, value) VALUES ('publication_schema_version', '1')")
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

    func reserveCapture(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration,
        generation: ArchiveSourceGeneration
    ) throws -> CollectorCaptureReservation? {
        try write { db in
            try Task.checkCancellation()
            try requirePublicationRoot(db, configuration)
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
            if let pending = try Row.fetchOne(db, sql: """
                SELECT * FROM collector_capture_reservations WHERE root_id = ? AND root_revision = ?
                """, arguments: [configuration.rootID, configuration.revision]) {
                let reservation = try Self.reservation(pending)
                let owner: String = pending["dirty_claim_owner_run_id"]
                let claimGeneration: Int64 = pending["dirty_claim_generation"]
                guard reservation.relativePath.utf8.elementsEqual(claim.relativePath.utf8),
                      reservation.dirtyRevision == claim.dirtyRevision, reservation.generation == generation,
                      owner.utf8.elementsEqual(claim.ownerRunID.utf8), claimGeneration == claim.claimGeneration else { return nil }
                return reservation
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO collector_streams(root_id, root_revision, source_instance_id, collector_epoch, last_sequence)
                VALUES (?, ?, ?, ?, 0)
                """, arguments: [configuration.rootID, configuration.revision, UUID().uuidString, UUID().uuidString])
            guard let stream = try Row.fetchOne(db, sql: "SELECT * FROM collector_streams WHERE root_id = ? AND root_revision = ?",
                arguments: [configuration.rootID, configuration.revision]) else { throw CollectorInventoryError.invalidState }
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
                generation: generation, sourceInstanceID: sourceInstanceID, collectorEpoch: collectorEpoch, sequence: sequence)
            try db.execute(sql: "UPDATE collector_streams SET last_sequence = ? WHERE root_id = ? AND root_revision = ?",
                arguments: [sequence, configuration.rootID, configuration.revision])
            try db.execute(sql: """
                INSERT INTO collector_capture_reservations(id, root_id, root_revision, relative_path, dirty_revision,
                    generation_bytes, source_instance_id, collector_epoch, sequence, dirty_claim_owner_run_id, dirty_claim_generation)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [reservation.id, reservation.rootID, reservation.rootRevision, reservation.relativePath,
                    reservation.dirtyRevision, generationBytes, sourceInstanceID, collectorEpoch, sequence, ownerRunID, claim.claimGeneration])
            return reservation
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
                """, arguments: [limit]).map(Self.reservation)
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
            // Completing an older capture never erases a newer dirty event or
            // another claim acquired while this reservation survived a restart.
            try db.execute(sql: """
                UPDATE collector_locators SET acknowledged_revision = MAX(acknowledged_revision, ?),
                    last_capture_id = CASE WHEN acknowledged_revision <= ? THEN ? ELSE last_capture_id END
                WHERE root_id = ? AND root_revision = ? AND relative_path = ?
                """, arguments: [reservation.dirtyRevision, reservation.dirtyRevision, capture.captureID,
                    reservation.rootID, reservation.rootRevision, reservation.relativePath])
            try releaseReservedDirtyClaim(db, reservation, stored: pending)
            try db.execute(sql: "DELETE FROM collector_capture_reservations WHERE id = ?", arguments: [reservation.id])
            return intent
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
                WHERE r.replica_id = ? AND (
                    (r.state = 'pending' AND (r.retry_not_before IS NULL OR r.retry_not_before <= ?)) OR
                    (r.state = 'inflight' AND (r.claim_owner_run_id != ? OR r.claimed_at <= ?)))
                ORDER BY p.root_id, p.root_revision, p.sequence LIMIT ?
                """, arguments: [replicaID, now, ownerRunID, staleBefore, limit])
            return try rows.map { row in
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
        try Task.checkCancellation()
        let hasPending = try database.read { db in
            try requirePublicationOwner(db)
            try Self.requireRoot(db, configuration)
            guard limit > 0 else { return false }
            return try Int.fetchOne(db, sql: """
                SELECT 1 FROM collector_locators INDEXED BY collector_pending_locators
                WHERE root_id = ? AND root_revision = ? AND dirty_revision > acknowledged_revision LIMIT 1
                """, arguments: [configuration.rootID, configuration.revision]) != nil
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

    private static func reservation(_ row: Row) throws -> CollectorCaptureReservation {
        let bytes: Data = row["generation_bytes"]
        guard bytes.count <= 2_048 else { throw CollectorInventoryError.invalidState }
        let generation = try ArchiveCanonicalJSON.decode(ArchiveSourceGeneration.self, from: bytes)
        let value = CollectorCaptureReservation(id: row["id"], rootID: row["root_id"], rootRevision: row["root_revision"],
            relativePath: row["relative_path"], dirtyRevision: row["dirty_revision"], generation: generation,
            sourceInstanceID: row["source_instance_id"], collectorEpoch: row["collector_epoch"], sequence: row["sequence"])
        guard UUID(uuidString: value.id) != nil, !value.rootID.isEmpty, value.rootRevision > 0,
              isSafeRelativePath(value.relativePath), value.dirtyRevision > 0, value.sequence > 0,
              UUID(uuidString: value.sourceInstanceID) != nil, UUID(uuidString: value.collectorEpoch) != nil else {
            throw CollectorInventoryError.invalidState
        }
        return value
    }

    private func reservationRow(_ db: Database, _ expected: CollectorCaptureReservation) throws -> Row? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM collector_capture_reservations WHERE id = ?",
            arguments: [expected.id]) else { return nil }
        let stored = try Self.reservation(row)
        guard stored == expected, stored.rootID.utf8.elementsEqual(expected.rootID.utf8),
              stored.relativePath.utf8.elementsEqual(expected.relativePath.utf8) else { return nil }
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
              capture.machineID == machineID, capture.source == configuration.source.rawValue,
              capture.locator.utf8.elementsEqual(URL(fileURLWithPath: configuration.rootPath)
                .appendingPathComponent(reservation.relativePath).path.utf8),
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

    private static func createPublicationSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS collector_streams (
                root_id TEXT NOT NULL, root_revision INTEGER NOT NULL CHECK(root_revision > 0),
                source_instance_id TEXT NOT NULL, collector_epoch TEXT NOT NULL,
                last_sequence INTEGER NOT NULL CHECK(typeof(last_sequence) = 'integer' AND last_sequence >= 0),
                PRIMARY KEY(root_id, root_revision),
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
                UNIQUE(root_id, root_revision),
                FOREIGN KEY(root_id, root_revision, source_instance_id, collector_epoch)
                    REFERENCES collector_streams(root_id, root_revision, source_instance_id, collector_epoch),
                FOREIGN KEY(root_id, root_revision, relative_path) REFERENCES collector_locators(root_id, root_revision, relative_path)
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
