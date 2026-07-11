import Darwin
import CSQLite
import EngramCoreRead
import Foundation
import GRDB

public enum ArchiveCatalogError: Error, Equatable, Sendable {
    case invalidMachineID(String)
    case databaseJournalModeNotWAL(String)
    case databaseSynchronousNotFull(Int)
    case missingMetadata(String)
    case manifestMachineIDMismatch(expected: String, actual: String)
    case captureManifestMustBeUnbound
    case captureConflict(captureID: String)
    case captureNotFound(captureID: String)
    case captureAlreadyBound(captureID: String, existingSessionID: String)
    case boundManifestRequiresSessionID
    case boundManifestMismatch(field: String)
    case bindingConflict(manifestSHA256: String)
    case bindingNotFound(manifestSHA256: String)
    case invalidSHA256(field: String)
    case invalidReplicaID
    case invalidAttempts(Int)
    case invalidReplicaState(String)
    case receiptRequired
    case unexpectedReceipt
    case receiptDigestMismatch(expected: String, actual: String)
    case receiptReplicaMismatch(expected: String, actual: String)
    case receiptConflict(manifestSHA256: String, replicaID: String)
    case invalidLimit(Int)
    case invalidStaleInterval(TimeInterval)
    case invalidTimestamp(field: String, value: String)
    case invalidRemoteEligibility
    case invalidRemoteEligibilityValue(String)
    case invalidProjectRootSnapshot(String?)
    case remotePolicyConflict(manifestSHA256: String)
    case invalidReplicaTransition(from: ArchiveReplicaState, to: ArchiveReplicaState)
    case invalidClaimGeneration(Int)
    case invalidLastError(String)
    case unsafeRoot(String)
    case unsafeDatabasePath(String)
    case sqliteFileControlFailed(code: Int32)
}

struct ArchiveCatalogTestHooks: Sendable {
    let afterDatabasePreflight: (@Sendable (URL) throws -> Void)?
    let beforeDatabaseIdentityValidation: (@Sendable (URL) throws -> Void)?

    init(
        afterDatabasePreflight: (@Sendable (URL) throws -> Void)? = nil,
        beforeDatabaseIdentityValidation: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.afterDatabasePreflight = afterDatabasePreflight
        self.beforeDatabaseIdentityValidation = beforeDatabaseIdentityValidation
    }
}

private struct ArchiveCatalogFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    func matches(_ info: stat) -> Bool {
        device == info.st_dev && inode == info.st_ino
    }
}

public struct ArchiveCapture: Equatable, Sendable {
    public let captureID: String
    public let machineID: String
    public let source: String
    public let locator: String
    public let generation: ArchiveSourceGeneration
    public let wholeSourceSHA256: String
    public let rawByteCount: Int64
    public let chunkSize: Int64
    public let unboundManifestSHA256: String
    public let unboundManifestBytes: Data
    public let status: String
    public let diagnostic: String?
    public let capturedAt: String
}

public struct ArchiveCaptureCursor: Equatable, Sendable {
    public let capturedAt: String
    public let captureID: String

    public init(capturedAt: String, captureID: String) {
        self.capturedAt = capturedAt
        self.captureID = captureID
    }
}

public enum ArchiveRemoteEligibility: String, CaseIterable, Equatable, Sendable {
    case unknown
    case eligible
    case excluded
}

public struct ArchiveBinding: Equatable, Sendable {
    public let manifestSHA256: String
    public let sessionID: String
    public let captureID: String
    public let sourceSnapshotFingerprint: String
    public let canonicalManifestBytes: Data
    public let boundAt: String
    public let projectRootSnapshot: String?
    public let remoteEligibility: ArchiveRemoteEligibility

    init(
        manifestSHA256: String,
        sessionID: String,
        captureID: String,
        sourceSnapshotFingerprint: String,
        canonicalManifestBytes: Data,
        boundAt: String,
        projectRootSnapshot: String? = nil,
        remoteEligibility: ArchiveRemoteEligibility = .unknown
    ) {
        self.manifestSHA256 = manifestSHA256
        self.sessionID = sessionID
        self.captureID = captureID
        self.sourceSnapshotFingerprint = sourceSnapshotFingerprint
        self.canonicalManifestBytes = canonicalManifestBytes
        self.boundAt = boundAt
        self.projectRootSnapshot = projectRootSnapshot
        self.remoteEligibility = remoteEligibility
    }
}

public enum ArchiveReplicaState: String, CaseIterable, Equatable, Sendable {
    case pending
    case uploadingObjects
    case uploadingManifest
    case requestingReceipt
    case verifyingReceipt
    case verified
    case retryWait
    case quarantined

    fileprivate var isInFlight: Bool {
        switch self {
        case .uploadingObjects, .uploadingManifest, .requestingReceipt, .verifyingReceipt:
            true
        case .pending, .verified, .retryWait, .quarantined:
            false
        }
    }
}

public struct ArchiveVerifiedReceipt: Equatable, Sendable {
    public let canonicalBytes: Data
    public let sha256: String
    public let verifiedAt: String

    public init(canonicalBytes: Data, sha256: String, verifiedAt: String) {
        self.canonicalBytes = canonicalBytes
        self.sha256 = sha256
        self.verifiedAt = verifiedAt
    }
}

public struct ArchiveReplicaWork: Equatable, Sendable {
    public let manifestSHA256: String
    public let captureID: String
    public let replicaID: String
    public let state: ArchiveReplicaState
    public let attempts: Int
    public let nextRetryAt: String?
    public let lastError: String?
    public let claimGeneration: Int
    public let updatedAt: String

    init(
        manifestSHA256: String,
        captureID: String,
        replicaID: String,
        state: ArchiveReplicaState,
        attempts: Int,
        nextRetryAt: String?,
        lastError: String?,
        claimGeneration: Int = 0,
        updatedAt: String = "1970-01-01T00:00:00.000Z"
    ) {
        self.manifestSHA256 = manifestSHA256
        self.captureID = captureID
        self.replicaID = replicaID
        self.state = state
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
        self.claimGeneration = claimGeneration
        self.updatedAt = updatedAt
    }
}

public struct ArchiveReplicaClaim: Equatable, Sendable {
    public let manifestSHA256: String
    public let captureID: String
    public let sessionID: String
    public let replicaID: String
    public let canonicalManifestBytes: Data
    public let claimGeneration: Int
    public let attempts: Int
}

/// Rebuildable archive metadata isolated from Engram's product index database.
/// The immutable byte authority remains `ImmutableArchiveCAS`.
public final class ArchiveCatalog: @unchecked Sendable {
    public static let currentReplicaIDs = ["hq", "m1"]
    private static let databaseFilename = "archive.sqlite"
    private static let captureStatus = "captured"

    private let pool: DatabasePool
    private let root: URL
    private let databasePath: String
    private let databaseIdentity: ArchiveCatalogFileIdentity
    private let machineIDCandidate: String

    public convenience init(root: URL, machineID: String? = nil) throws {
        try self.init(
            root: root,
            machineID: machineID,
            testHooks: ArchiveCatalogTestHooks()
        )
    }

    init(
        root: URL,
        machineID: String? = nil,
        testHooks: ArchiveCatalogTestHooks
    ) throws {
        let root = root.standardizedFileURL
        try Self.prepareRoot(root)

        let candidate = machineID ?? UUID().uuidString
        guard UUID(uuidString: candidate) != nil else {
            throw ArchiveCatalogError.invalidMachineID(candidate)
        }

        let databaseURL = root.appendingPathComponent(Self.databaseFilename)
        let preparedIdentity = try Self.prepareMainDatabaseFile(at: databaseURL)
        let expectedSQLitePath = try Self.canonicalFilesystemPath(databaseURL.path)
        try testHooks.afterDatabasePreflight?(databaseURL)

        self.root = root
        databasePath = databaseURL.path
        databaseIdentity = preparedIdentity
        machineIDCandidate = candidate
        pool = try DatabasePool(
            path: databasePath,
            configuration: Self.databaseConfiguration(
                databaseURL: databaseURL,
                expectedSQLitePath: expectedSQLitePath,
                expectedIdentity: preparedIdentity,
                testHooks: testHooks
            )
        )
        try secureDatabaseFiles()
    }

    public func migrate() throws {
        try pool.write { db in
            try ArchiveCatalogMigrations.migrate(db, machineID: machineIDCandidate)
        }
        try secureDatabaseFiles()
    }

    public func machineID() throws -> String {
        try pool.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: "SELECT value FROM archive_metadata WHERE key = 'machine_id'"
            ) else {
                throw ArchiveCatalogError.missingMetadata("machine_id")
            }
            return value
        }
    }

    // `PRAGMA synchronous` is connection-local. Keep this internal verifier so
    // tests inspect the catalog pool instead of an unrelated SQLite connection.
    func configuredSynchronousMode() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
        }
    }

    @discardableResult
    public func recordCapture(canonicalManifestBytes: Data) throws -> ArchiveCapture {
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: canonicalManifestBytes
        )
        guard manifest.sessionID == nil else {
            throw ArchiveCatalogError.captureManifestMustBeUnbound
        }
        let persistedMachineID = try machineID()
        guard manifest.machineID == persistedMachineID else {
            throw ArchiveCatalogError.manifestMachineIDMismatch(
                expected: persistedMachineID,
                actual: manifest.machineID
            )
        }

        let manifestSHA256 = ArchiveV2Hash.sha256(canonicalManifestBytes)
        let now = Self.currentTimestamp()
        let capture = try pool.write { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_captures WHERE capture_id = ?",
                arguments: [manifest.captureID]
            ) {
                let existing = try Self.capture(from: row)
                guard existing.unboundManifestSHA256 == manifestSHA256,
                      existing.unboundManifestBytes == canonicalManifestBytes else {
                    throw ArchiveCatalogError.captureConflict(captureID: manifest.captureID)
                }
                return existing
            }

            if try String.fetchOne(
                db,
                sql: "SELECT capture_id FROM archive_captures WHERE unbound_manifest_sha256 = ?",
                arguments: [manifestSHA256]
            ) != nil {
                throw ArchiveCatalogError.captureConflict(captureID: manifest.captureID)
            }

            try db.execute(
                sql: """
                INSERT INTO archive_captures(
                    capture_id, machine_id, source, locator,
                    generation_device, generation_inode, generation_size,
                    generation_mtime_ns, generation_ctime_ns, generation_mode,
                    whole_source_sha256, raw_byte_count, chunk_size,
                    unbound_manifest_sha256, unbound_manifest_bytes,
                    status, diagnostic, captured_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
                """,
                arguments: [
                    manifest.captureID,
                    manifest.machineID,
                    manifest.source,
                    manifest.locator,
                    manifest.generation.device,
                    manifest.generation.inode,
                    manifest.generation.size,
                    manifest.generation.mtimeNs,
                    manifest.generation.ctimeNs,
                    manifest.generation.mode,
                    manifest.wholeSourceSHA256,
                    manifest.rawByteCount,
                    manifest.chunkSize,
                    manifestSHA256,
                    canonicalManifestBytes,
                    Self.captureStatus,
                    manifest.capturedAt,
                    now,
                    now,
                ]
            )

            return ArchiveCapture(
                captureID: manifest.captureID,
                machineID: manifest.machineID,
                source: manifest.source,
                locator: manifest.locator,
                generation: manifest.generation,
                wholeSourceSHA256: manifest.wholeSourceSHA256,
                rawByteCount: manifest.rawByteCount,
                chunkSize: manifest.chunkSize,
                unboundManifestSHA256: manifestSHA256,
                unboundManifestBytes: canonicalManifestBytes,
                status: Self.captureStatus,
                diagnostic: nil,
                capturedAt: manifest.capturedAt
            )
        }
        try secureDatabaseFiles()
        return capture
    }

    @discardableResult
    public func bind(
        canonicalManifestBytes: Data,
        sourceSnapshotFingerprint: String,
        boundAt: String? = nil
    ) throws -> ArchiveBinding {
        guard ArchiveV2Hash.isValidSHA256(sourceSnapshotFingerprint) else {
            throw ArchiveCatalogError.invalidSHA256(field: "sourceSnapshotFingerprint")
        }
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: canonicalManifestBytes
        )
        guard let sessionID = manifest.sessionID, !sessionID.isEmpty else {
            throw ArchiveCatalogError.boundManifestRequiresSessionID
        }
        let resolvedBoundAt = boundAt ?? Self.currentTimestamp()
        try Self.validateTimestamp(resolvedBoundAt, field: "boundAt")
        let manifestSHA256 = ArchiveV2Hash.sha256(canonicalManifestBytes)

        let binding = try pool.write { db in
            guard let captureRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_captures WHERE capture_id = ?",
                arguments: [manifest.captureID]
            ) else {
                throw ArchiveCatalogError.captureNotFound(captureID: manifest.captureID)
            }
            let capture = try Self.capture(from: captureRow)
            let unboundManifest = try ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self,
                from: capture.unboundManifestBytes
            )
            if let field = Self.firstBindingMismatch(
                unbound: unboundManifest,
                bound: manifest
            ) {
                throw ArchiveCatalogError.boundManifestMismatch(field: field)
            }

            if let existingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_session_bindings WHERE manifest_sha256 = ?",
                arguments: [manifestSHA256]
            ) {
                let existing = try Self.binding(from: existingRow)
                guard existing.sessionID == sessionID,
                      existing.captureID == manifest.captureID,
                      existing.sourceSnapshotFingerprint == sourceSnapshotFingerprint,
                      existing.canonicalManifestBytes == canonicalManifestBytes else {
                    throw ArchiveCatalogError.bindingConflict(
                        manifestSHA256: manifestSHA256
                    )
                }
                return existing
            }

            if let existingRow = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM archive_session_bindings
                WHERE capture_id = ?
                """,
                arguments: [manifest.captureID]
            ) {
                let existing = try Self.binding(from: existingRow)
                throw ArchiveCatalogError.captureAlreadyBound(
                    captureID: manifest.captureID,
                    existingSessionID: existing.sessionID
                )
            }

            try db.execute(
                sql: """
                INSERT INTO archive_session_bindings(
                    manifest_sha256, session_id, capture_id,
                    source_snapshot_fingerprint, bound_manifest_bytes, bound_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    manifestSHA256,
                    sessionID,
                    manifest.captureID,
                    sourceSnapshotFingerprint,
                    canonicalManifestBytes,
                    resolvedBoundAt,
                ]
            )
            return ArchiveBinding(
                manifestSHA256: manifestSHA256,
                sessionID: sessionID,
                captureID: manifest.captureID,
                sourceSnapshotFingerprint: sourceSnapshotFingerprint,
                canonicalManifestBytes: canonicalManifestBytes,
                boundAt: resolvedBoundAt
            )
        }
        try secureDatabaseFiles()
        return binding
    }

    public func latestBinding(sessionID: String) throws -> ArchiveBinding? {
        guard !sessionID.isEmpty else { return nil }
        return try pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM archive_session_bindings
                WHERE session_id = ?
                ORDER BY bound_at DESC, manifest_sha256 DESC
                LIMIT 1
                """,
                arguments: [sessionID]
            ).map { try Self.binding(from: $0) }
        }
    }

    public func capture(captureID: String) throws -> ArchiveCapture? {
        guard ArchiveV2Hash.isValidSHA256(captureID) else {
            throw ArchiveCatalogError.invalidSHA256(field: "captureID")
        }
        return try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_captures WHERE capture_id = ?",
                arguments: [captureID]
            ).map(Self.capture(from:))
        }
    }

    /// Persisted unbound work is queried from the catalog rather than process
    /// memory so a crash after capture cannot strand a replayable generation.
    public func unboundCaptures(limit: Int) throws -> [ArchiveCapture] {
        guard limit > 0 else {
            throw ArchiveCatalogError.invalidLimit(limit)
        }
        guard let boundary = try unboundCaptureBoundary() else { return [] }
        return try unboundCaptures(limit: limit, after: nil, through: boundary)
    }

    public func unboundCaptureBoundary() throws -> ArchiveCaptureCursor? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT c.captured_at, c.capture_id
                FROM archive_captures AS c
                LEFT JOIN archive_session_bindings AS b
                  ON b.capture_id = c.capture_id
                WHERE b.capture_id IS NULL
                ORDER BY c.captured_at DESC, c.capture_id DESC
                LIMIT 1
                """
            ) else {
                return nil
            }
            return ArchiveCaptureCursor(
                capturedAt: row["captured_at"],
                captureID: row["capture_id"]
            )
        }
    }

    public func unboundCaptures(
        limit: Int,
        after cursor: ArchiveCaptureCursor?,
        through boundary: ArchiveCaptureCursor
    ) throws -> [ArchiveCapture] {
        guard limit > 0 else {
            throw ArchiveCatalogError.invalidLimit(limit)
        }
        try Self.validateTimestamp(boundary.capturedAt, field: "boundary.capturedAt")
        guard ArchiveV2Hash.isValidSHA256(boundary.captureID) else {
            throw ArchiveCatalogError.invalidSHA256(field: "boundary.captureID")
        }
        if let cursor {
            try Self.validateTimestamp(cursor.capturedAt, field: "cursor.capturedAt")
            guard ArchiveV2Hash.isValidSHA256(cursor.captureID) else {
                throw ArchiveCatalogError.invalidSHA256(field: "cursor.captureID")
            }
        }
        return try pool.read { db in
            let lowerBoundSQL: String
            var arguments = StatementArguments()
            if let cursor {
                lowerBoundSQL = """
                  AND (c.captured_at > ? OR (c.captured_at = ? AND c.capture_id > ?))
                """
                arguments += [cursor.capturedAt, cursor.capturedAt, cursor.captureID]
            } else {
                lowerBoundSQL = ""
            }
            arguments += [boundary.capturedAt, boundary.capturedAt, boundary.captureID, limit]
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*
                FROM archive_captures AS c
                LEFT JOIN archive_session_bindings AS b
                  ON b.capture_id = c.capture_id
                WHERE b.capture_id IS NULL
                \(lowerBoundSQL)
                  AND (c.captured_at < ? OR (c.captured_at = ? AND c.capture_id <= ?))
                ORDER BY c.captured_at ASC, c.capture_id ASC
                LIMIT ?
                """, arguments: arguments)
            return try rows.map(Self.capture(from:))
        }
    }

    @discardableResult
    public func setRemotePolicySnapshot(
        manifestSHA256: String,
        projectRootSnapshot: String?,
        eligibility: ArchiveRemoteEligibility
    ) throws -> Bool {
        try Self.validateManifestSHA256(manifestSHA256)
        guard eligibility != .unknown else {
            throw ArchiveCatalogError.invalidRemoteEligibility
        }
        try Self.validateProjectRootSnapshot(
            projectRootSnapshot,
            eligibility: eligibility
        )

        let changed = try pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT project_root_snapshot, remote_eligibility
                FROM archive_session_bindings
                WHERE manifest_sha256 = ?
                """,
                arguments: [manifestSHA256]
            ) else {
                throw ArchiveCatalogError.bindingNotFound(
                    manifestSHA256: manifestSHA256
                )
            }
            let rawEligibility: String = row["remote_eligibility"]
            guard let existingEligibility = ArchiveRemoteEligibility(
                rawValue: rawEligibility
            ) else {
                throw ArchiveCatalogError.invalidRemoteEligibilityValue(rawEligibility)
            }
            let existingRoot: String? = row["project_root_snapshot"]
            if existingEligibility != .unknown {
                guard existingEligibility == eligibility,
                      existingRoot == projectRootSnapshot else {
                    throw ArchiveCatalogError.remotePolicyConflict(
                        manifestSHA256: manifestSHA256
                    )
                }
                return false
            }

            try db.execute(
                sql: """
                UPDATE archive_session_bindings
                SET project_root_snapshot = ?, remote_eligibility = ?
                WHERE manifest_sha256 = ? AND remote_eligibility = 'unknown'
                """,
                arguments: [
                    projectRootSnapshot,
                    eligibility.rawValue,
                    manifestSHA256,
                ]
            )
            guard db.changesCount == 1 else {
                throw ArchiveCatalogError.remotePolicyConflict(
                    manifestSHA256: manifestSHA256
                )
            }
            return true
        }
        if changed { try secureDatabaseFiles() }
        return changed
    }

    @discardableResult
    public func reconcileEligibleReplicaRows(updatedAt: String? = nil) throws -> Int {
        let resolvedUpdatedAt = updatedAt ?? Self.currentTimestamp()
        try Self.validateTimestamp(resolvedUpdatedAt, field: "updatedAt")
        let inserted = try pool.write { db in
            var count = 0
            for replicaID in Self.currentReplicaIDs {
                try db.execute(
                    sql: """
                    INSERT INTO archive_replica_receipts(
                        manifest_sha256, capture_id, replica_id, state,
                        attempts, next_retry_at, last_error,
                        receipt_bytes, receipt_sha256, verified_at,
                        updated_at, claim_generation
                    )
                    SELECT manifest_sha256, capture_id, ?, 'pending',
                           0, NULL, NULL, NULL, NULL, NULL, ?, 0
                    FROM archive_session_bindings
                    WHERE remote_eligibility = 'eligible'
                    ON CONFLICT(manifest_sha256, replica_id) DO NOTHING
                    """,
                    arguments: [replicaID, resolvedUpdatedAt]
                )
                count += db.changesCount
            }
            return count
        }
        if inserted > 0 { try secureDatabaseFiles() }
        return inserted
    }

    public func claimReplicaWork(limit: Int, now: String) throws -> [ArchiveReplicaClaim] {
        guard limit > 0 else {
            throw ArchiveCatalogError.invalidLimit(limit)
        }
        try Self.validateTimestamp(now, field: "now")
        let claims = try pool.write { db in
            let claimedRows = try Row.fetchAll(
                db,
                sql: """
                UPDATE archive_replica_receipts
                SET state = 'uploadingObjects',
                    claim_generation = claim_generation + 1,
                    next_retry_at = NULL,
                    last_error = NULL,
                    updated_at = ?
                WHERE (manifest_sha256, replica_id) IN (
                    SELECT r.manifest_sha256, r.replica_id
                    FROM archive_replica_receipts AS r
                    JOIN archive_session_bindings AS b
                      ON b.manifest_sha256 = r.manifest_sha256
                    WHERE b.remote_eligibility = 'eligible'
                      AND r.replica_id IN ('hq', 'm1')
                      AND (
                          r.state = 'pending'
                          OR (
                              r.state = 'retryWait'
                              AND (r.next_retry_at IS NULL OR r.next_retry_at <= ?)
                          )
                      )
                    ORDER BY r.updated_at ASC,
                             r.manifest_sha256 ASC,
                             r.replica_id ASC
                    LIMIT ?
                )
                  AND (
                      state = 'pending'
                      OR (
                          state = 'retryWait'
                          AND (next_retry_at IS NULL OR next_retry_at <= ?)
                      )
                  )
                RETURNING manifest_sha256, capture_id, replica_id,
                          attempts, claim_generation
                """,
                arguments: [now, now, limit, now]
            )

            var claims: [ArchiveReplicaClaim] = []
            claims.reserveCapacity(claimedRows.count)
            for row in claimedRows {
                let manifestSHA256: String = row["manifest_sha256"]
                guard let bindingRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM archive_session_bindings
                    WHERE manifest_sha256 = ? AND remote_eligibility = 'eligible'
                    """,
                    arguments: [manifestSHA256]
                ) else {
                    throw ArchiveCatalogError.bindingNotFound(
                        manifestSHA256: manifestSHA256
                    )
                }
                let binding = try Self.binding(from: bindingRow)
                let captureID: String = row["capture_id"]
                guard binding.captureID == captureID else {
                    throw ArchiveCatalogError.bindingConflict(
                        manifestSHA256: manifestSHA256
                    )
                }
                let claim = ArchiveReplicaClaim(
                    manifestSHA256: manifestSHA256,
                    captureID: captureID,
                    sessionID: binding.sessionID,
                    replicaID: row["replica_id"],
                    canonicalManifestBytes: binding.canonicalManifestBytes,
                    claimGeneration: row["claim_generation"],
                    attempts: row["attempts"]
                )
                try Self.validateClaim(
                    claim,
                    claimGeneration: claim.claimGeneration
                )
                claims.append(claim)
            }
            return claims.sorted {
                ($0.manifestSHA256, $0.replicaID) < ($1.manifestSHA256, $1.replicaID)
            }
        }
        if !claims.isEmpty { try secureDatabaseFiles() }
        return claims
    }

    @discardableResult
    public func transitionReplicaClaim(
        _ claim: ArchiveReplicaClaim,
        from expectedState: ArchiveReplicaState,
        to newState: ArchiveReplicaState,
        updatedAt: String
    ) throws -> Bool {
        try transitionReplicaClaim(
            claim,
            from: expectedState,
            to: newState,
            updatedAt: updatedAt,
            usingClaimGeneration: claim.claimGeneration
        )
    }

    @discardableResult
    func transitionReplicaClaim(
        _ claim: ArchiveReplicaClaim,
        from expectedState: ArchiveReplicaState,
        to newState: ArchiveReplicaState,
        updatedAt: String,
        usingClaimGeneration claimGeneration: Int
    ) throws -> Bool {
        guard Self.isAllowedTransition(from: expectedState, to: newState) else {
            throw ArchiveCatalogError.invalidReplicaTransition(
                from: expectedState,
                to: newState
            )
        }
        try Self.validateClaim(
            claim,
            claimGeneration: claimGeneration
        )
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        let changed = try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET state = ?, next_retry_at = NULL, last_error = NULL, updated_at = ?
                WHERE manifest_sha256 = ?
                  AND capture_id = ?
                  AND replica_id = ?
                  AND state = ?
                  AND claim_generation = ?
                """,
                arguments: [
                    newState.rawValue,
                    updatedAt,
                    claim.manifestSHA256,
                    claim.captureID,
                    claim.replicaID,
                    expectedState.rawValue,
                    claimGeneration,
                ]
            )
            return db.changesCount == 1
        }
        if changed { try secureDatabaseFiles() }
        return changed
    }

    @discardableResult
    public func heartbeatReplicaClaim(
        _ claim: ArchiveReplicaClaim,
        state: ArchiveReplicaState,
        at: String
    ) throws -> Bool {
        guard state.isInFlight else {
            throw ArchiveCatalogError.invalidReplicaTransition(from: state, to: state)
        }
        try Self.validateClaim(
            claim,
            claimGeneration: claim.claimGeneration
        )
        try Self.validateTimestamp(at, field: "updatedAt")
        let changed = try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET updated_at = ?
                WHERE manifest_sha256 = ?
                  AND capture_id = ?
                  AND replica_id = ?
                  AND state = ?
                  AND claim_generation = ?
                """,
                arguments: [
                    at,
                    claim.manifestSHA256,
                    claim.captureID,
                    claim.replicaID,
                    state.rawValue,
                    claim.claimGeneration,
                ]
            )
            return db.changesCount == 1
        }
        if changed { try secureDatabaseFiles() }
        return changed
    }

    @discardableResult
    public func markReplicaRetry(
        _ claim: ArchiveReplicaClaim,
        from expectedState: ArchiveReplicaState,
        nextRetryAt: String,
        lastError: String,
        updatedAt: String
    ) throws -> Bool {
        try markReplicaRetry(
            claim,
            from: expectedState,
            nextRetryAt: nextRetryAt,
            lastError: lastError,
            updatedAt: updatedAt,
            usingClaimGeneration: claim.claimGeneration
        )
    }

    @discardableResult
    func markReplicaRetry(
        _ claim: ArchiveReplicaClaim,
        from expectedState: ArchiveReplicaState,
        nextRetryAt: String,
        lastError: String,
        updatedAt: String,
        usingClaimGeneration claimGeneration: Int
    ) throws -> Bool {
        guard expectedState.isInFlight else {
            throw ArchiveCatalogError.invalidReplicaTransition(
                from: expectedState,
                to: .retryWait
            )
        }
        try Self.validateClaim(claim, claimGeneration: claimGeneration)
        try Self.validateLastError(lastError)
        try Self.validateTimestamp(nextRetryAt, field: "nextRetryAt")
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        let changed = try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET state = 'retryWait',
                    attempts = CASE
                        WHEN attempts >= ? THEN ?
                        ELSE attempts + 1
                    END,
                    next_retry_at = ?,
                    last_error = ?,
                    updated_at = ?
                WHERE manifest_sha256 = ?
                  AND capture_id = ?
                  AND replica_id = ?
                  AND state = ?
                  AND claim_generation = ?
                """,
                arguments: [
                    Int64.max,
                    Int64.max,
                    nextRetryAt,
                    lastError,
                    updatedAt,
                    claim.manifestSHA256,
                    claim.captureID,
                    claim.replicaID,
                    expectedState.rawValue,
                    claimGeneration,
                ]
            )
            return db.changesCount == 1
        }
        if changed { try secureDatabaseFiles() }
        return changed
    }

    @discardableResult
    public func markReplicaQuarantined(
        _ claim: ArchiveReplicaClaim,
        from expectedState: ArchiveReplicaState,
        lastError: String,
        updatedAt: String
    ) throws -> Bool {
        guard expectedState.isInFlight else {
            throw ArchiveCatalogError.invalidReplicaTransition(
                from: expectedState,
                to: .quarantined
            )
        }
        try Self.validateClaim(
            claim,
            claimGeneration: claim.claimGeneration
        )
        try Self.validateLastError(lastError)
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        let changed = try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET state = 'quarantined',
                    attempts = CASE
                        WHEN attempts >= ? THEN ?
                        ELSE attempts + 1
                    END,
                    next_retry_at = NULL,
                    last_error = ?,
                    updated_at = ?
                WHERE manifest_sha256 = ?
                  AND capture_id = ?
                  AND replica_id = ?
                  AND state = ?
                  AND claim_generation = ?
                """,
                arguments: [
                    Int64.max,
                    Int64.max,
                    lastError,
                    updatedAt,
                    claim.manifestSHA256,
                    claim.captureID,
                    claim.replicaID,
                    expectedState.rawValue,
                    claim.claimGeneration,
                ]
            )
            return db.changesCount == 1
        }
        if changed { try secureDatabaseFiles() }
        return changed
    }

    @discardableResult
    public func recordVerifiedReceipt(
        _ claim: ArchiveReplicaClaim,
        receipt: ArchiveVerifiedReceipt,
        updatedAt: String
    ) throws -> Bool {
        try Self.validateClaim(
            claim,
            claimGeneration: claim.claimGeneration
        )
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        let changed = try pool.write { db in
            guard let bindingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_session_bindings WHERE manifest_sha256 = ?",
                arguments: [claim.manifestSHA256]
            ) else {
                throw ArchiveCatalogError.bindingNotFound(
                    manifestSHA256: claim.manifestSHA256
                )
            }
            let binding = try Self.binding(from: bindingRow)
            guard binding.captureID == claim.captureID,
                  binding.sessionID == claim.sessionID,
                  binding.canonicalManifestBytes == claim.canonicalManifestBytes else {
                throw ArchiveCatalogError.bindingConflict(
                    manifestSHA256: claim.manifestSHA256
                )
            }
            try Self.validate(
                receipt: receipt,
                replicaID: claim.replicaID,
                boundManifestBytes: binding.canonicalManifestBytes
            )

            guard let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT state, claim_generation, receipt_bytes, receipt_sha256
                FROM archive_replica_receipts
                WHERE manifest_sha256 = ? AND replica_id = ?
                """,
                arguments: [claim.manifestSHA256, claim.replicaID]
            ) else {
                return false
            }
            let existingBytes: Data? = existing["receipt_bytes"]
            let existingSHA256: String? = existing["receipt_sha256"]
            if existingBytes != nil || existingSHA256 != nil {
                guard existingBytes == receipt.canonicalBytes,
                      existingSHA256 == receipt.sha256 else {
                    throw ArchiveCatalogError.receiptConflict(
                        manifestSHA256: claim.manifestSHA256,
                        replicaID: claim.replicaID
                    )
                }
                let existingState: String = existing["state"]
                if existingState == ArchiveReplicaState.verified.rawValue {
                    return false
                }
                throw ArchiveCatalogError.receiptConflict(
                    manifestSHA256: claim.manifestSHA256,
                    replicaID: claim.replicaID
                )
            }

            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET state = 'verified',
                    next_retry_at = NULL,
                    last_error = NULL,
                    receipt_bytes = ?,
                    receipt_sha256 = ?,
                    verified_at = ?,
                    updated_at = ?
                WHERE manifest_sha256 = ?
                  AND capture_id = ?
                  AND replica_id = ?
                  AND state = 'verifyingReceipt'
                  AND claim_generation = ?
                """,
                arguments: [
                    receipt.canonicalBytes,
                    receipt.sha256,
                    receipt.verifiedAt,
                    updatedAt,
                    claim.manifestSHA256,
                    claim.captureID,
                    claim.replicaID,
                    claim.claimGeneration,
                ]
            )
            return db.changesCount == 1
        }
        if changed { try secureDatabaseFiles() }
        return changed
    }

    public func replicaWork(
        manifestSHA256: String,
        replicaID: String
    ) throws -> ArchiveReplicaWork? {
        try Self.validateManifestSHA256(manifestSHA256)
        guard !replicaID.isEmpty else {
            throw ArchiveCatalogError.invalidReplicaID
        }
        return try pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT manifest_sha256, capture_id, replica_id, state,
                       attempts, next_retry_at, last_error,
                       claim_generation, updated_at
                FROM archive_replica_receipts
                WHERE manifest_sha256 = ? AND replica_id = ?
                """,
                arguments: [manifestSHA256, replicaID]
            ).map(Self.replicaWork(from:))
        }
    }

    public func currentVerifiedReceipts(
        manifestSHA256: String
    ) throws -> [String: ArchiveVerifiedReceipt] {
        try Self.validateManifestSHA256(manifestSHA256)
        return try pool.read { db in
            guard let bindingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_session_bindings WHERE manifest_sha256 = ?",
                arguments: [manifestSHA256]
            ) else {
                throw ArchiveCatalogError.bindingNotFound(
                    manifestSHA256: manifestSHA256
                )
            }
            let binding = try Self.binding(from: bindingRow)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT capture_id, replica_id, receipt_bytes, receipt_sha256, verified_at
                FROM archive_replica_receipts
                WHERE manifest_sha256 = ?
                  AND replica_id IN ('hq', 'm1')
                  AND state = 'verified'
                ORDER BY replica_id
                """,
                arguments: [manifestSHA256]
            )
            var receipts: [String: ArchiveVerifiedReceipt] = [:]
            for row in rows {
                let replicaID: String = row["replica_id"]
                let captureID: String = row["capture_id"]
                guard captureID == binding.captureID else {
                    throw ArchiveCatalogError.bindingConflict(
                        manifestSHA256: manifestSHA256
                    )
                }
                guard let bytes: Data = row["receipt_bytes"],
                      let sha256: String = row["receipt_sha256"],
                      let verifiedAt: String = row["verified_at"] else {
                    throw ArchiveCatalogError.receiptRequired
                }
                let receipt = ArchiveVerifiedReceipt(
                    canonicalBytes: bytes,
                    sha256: sha256,
                    verifiedAt: verifiedAt
                )
                try Self.validate(
                    receipt: receipt,
                    replicaID: replicaID,
                    boundManifestBytes: binding.canonicalManifestBytes
                )
                receipts[replicaID] = receipt
            }
            return receipts
        }
    }

    public func hasCurrentDualDurability(manifestSHA256: String) throws -> Bool {
        let receipts = try currentVerifiedReceipts(
            manifestSHA256: manifestSHA256
        )
        return Set(receipts.keys) == Set(Self.currentReplicaIDs)
    }

    @discardableResult
    public func retryQuarantined(replicaID: String?, now: String) throws -> Int {
        try Self.validateTimestamp(now, field: "now")
        if let replicaID, !Self.currentReplicaIDs.contains(replicaID) {
            throw ArchiveCatalogError.invalidReplicaID
        }
        let changed = try pool.write { db in
            let replicaPredicate: String
            var arguments: StatementArguments = [now]
            if let replicaID {
                replicaPredicate = "replica_id = ?"
                arguments += [replicaID]
            } else {
                replicaPredicate = "replica_id IN ('hq', 'm1')"
            }
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET state = 'pending',
                    attempts = 0,
                    next_retry_at = NULL,
                    last_error = NULL,
                    updated_at = ?,
                    claim_generation = claim_generation + 1
                WHERE state = 'quarantined'
                  AND \(replicaPredicate)
                  AND EXISTS (
                      SELECT 1 FROM archive_session_bindings AS b
                      WHERE b.manifest_sha256 = archive_replica_receipts.manifest_sha256
                        AND b.remote_eligibility = 'eligible'
                  )
                """,
                arguments: arguments
            )
            return db.changesCount
        }
        if changed > 0 { try secureDatabaseFiles() }
        return changed
    }

    @discardableResult
    public func recoverStaleInflight(
        now: String,
        olderThanSeconds: TimeInterval = 600
    ) throws -> Int {
        guard olderThanSeconds > 0 else {
            throw ArchiveCatalogError.invalidStaleInterval(olderThanSeconds)
        }
        let cutoff = try Self.timestamp(
            subtracting: olderThanSeconds,
            from: now
        )
        let recovered = try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET state = 'pending',
                    next_retry_at = NULL,
                    last_error = NULL,
                    updated_at = ?,
                    claim_generation = claim_generation + 1
                WHERE state IN (
                    'uploadingObjects',
                    'uploadingManifest',
                    'requestingReceipt',
                    'verifyingReceipt'
                )
                  AND replica_id IN ('hq', 'm1')
                  AND EXISTS (
                      SELECT 1 FROM archive_session_bindings AS b
                      WHERE b.manifest_sha256 = archive_replica_receipts.manifest_sha256
                        AND b.remote_eligibility = 'eligible'
                  )
                  AND updated_at < ?
                """,
                arguments: [now, cutoff]
            )
            return db.changesCount
        }
        try secureDatabaseFiles()
        return recovered
    }

    private static func databaseConfiguration(
        databaseURL: URL,
        expectedSQLitePath: String,
        expectedIdentity: ArchiveCatalogFileIdentity,
        testHooks: ArchiveCatalogTestHooks
    ) -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try testHooks.beforeDatabaseIdentityValidation?(databaseURL)
            try validateOpenedDatabase(
                db,
                databaseURL: databaseURL,
                expectedSQLitePath: expectedSQLitePath,
                expectedIdentity: expectedIdentity
            )
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(
                sql: "PRAGMA busy_timeout = \(SQLiteConnectionPolicy.busyTimeoutMilliseconds)"
            )
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(
                sql: "PRAGMA wal_autocheckpoint = \(SQLiteConnectionPolicy.walAutocheckpointPages)"
            )

            let journalMode = (
                try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
            ).lowercased()
            guard journalMode == "wal" else {
                throw ArchiveCatalogError.databaseJournalModeNotWAL(journalMode)
            }
            let synchronous = try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
            guard synchronous == 2 else {
                throw ArchiveCatalogError.databaseSynchronousNotFull(synchronous)
            }
        }
        return configuration
    }

    private static func validateOpenedDatabase(
        _ db: Database,
        databaseURL: URL,
        expectedSQLitePath: String,
        expectedIdentity: ArchiveCatalogFileIdentity
    ) throws {
        guard let filename = sqlite3_db_filename(db.sqliteConnection, "main"),
              String(cString: filename) == expectedSQLitePath else {
            throw ArchiveCatalogError.unsafeDatabasePath(databaseURL.path)
        }
        var hasMoved: CInt = 0
        let result = withUnsafeMutablePointer(to: &hasMoved) { pointer in
            sqlite3_file_control(
                db.sqliteConnection,
                "main",
                SQLITE_FCNTL_HAS_MOVED,
                pointer
            )
        }
        guard result == SQLITE_OK else {
            throw ArchiveCatalogError.sqliteFileControlFailed(code: result)
        }

        var pathInfo = stat()
        guard hasMoved == 0,
              lstat(databaseURL.path, &pathInfo) == 0,
              isSecureDatabaseFile(pathInfo),
              expectedIdentity.matches(pathInfo) else {
            throw ArchiveCatalogError.unsafeDatabasePath(databaseURL.path)
        }
    }

    private static func prepareRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard lstat(root.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw ArchiveCatalogError.unsafeRoot(root.path)
        }
        guard chmod(root.path, S_IRWXU) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func prepareMainDatabaseFile(
        at databaseURL: URL
    ) throws -> ArchiveCatalogFileIdentity {
        let path = databaseURL.path
        let createDescriptor = Darwin.open(
            path,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        if createDescriptor >= 0 {
            let identity = try secureOpenedDatabaseFile(
                createDescriptor,
                path: path,
                expectedIdentity: nil
            )
            try fsyncDirectory(databaseURL.deletingLastPathComponent())
            return identity
        }

        let createError = errno
        guard createError == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: createError) ?? .EIO)
        }
        let descriptor = Darwin.open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let openError = errno
            if openError == ELOOP || openError == EISDIR || openError == ENXIO {
                throw ArchiveCatalogError.unsafeDatabasePath(path)
            }
            throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO)
        }
        return try secureOpenedDatabaseFile(
            descriptor,
            path: path,
            expectedIdentity: nil
        )
    }

    private static func canonicalFilesystemPath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.free(resolved) }
        return String(cString: resolved)
    }

    private func secureDatabaseFiles() throws {
        try Self.secureDatabaseFile(
            at: databasePath,
            expectedIdentity: databaseIdentity,
            required: true
        )
        try Self.secureDatabaseFile(
            at: "\(databasePath)-wal",
            expectedIdentity: nil,
            required: false
        )
        try Self.secureDatabaseFile(
            at: "\(databasePath)-shm",
            expectedIdentity: nil,
            required: false
        )
        try Self.fsyncDirectory(root)
    }

    private static func secureDatabaseFile(
        at path: String,
        expectedIdentity: ArchiveCatalogFileIdentity?,
        required: Bool
    ) throws {
        let descriptor = Darwin.open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let openError = errno
            if !required, openError == ENOENT {
                return
            }
            if openError == ELOOP || openError == EISDIR || openError == ENXIO {
                throw ArchiveCatalogError.unsafeDatabasePath(path)
            }
            throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO)
        }
        _ = try secureOpenedDatabaseFile(
            descriptor,
            path: path,
            expectedIdentity: expectedIdentity
        )
    }

    private static func secureOpenedDatabaseFile(
        _ descriptor: Int32,
        path: String,
        expectedIdentity: ArchiveCatalogFileIdentity?
    ) throws -> ArchiveCatalogFileIdentity {
        defer { _ = Darwin.close(descriptor) }

        var initialInfo = stat()
        guard Darwin.fstat(descriptor, &initialInfo) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let identity = ArchiveCatalogFileIdentity(initialInfo)
        guard isOwnedSingleLinkRegularFile(initialInfo),
              expectedIdentity == nil || expectedIdentity == identity else {
            throw ArchiveCatalogError.unsafeDatabasePath(path)
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var descriptorInfo = stat()
        guard Darwin.fstat(descriptor, &descriptorInfo) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var pathInfo = stat()
        guard Darwin.lstat(path, &pathInfo) == 0,
              isSecureDatabaseFile(descriptorInfo),
              isSecureDatabaseFile(pathInfo),
              identity.matches(descriptorInfo),
              identity.matches(pathInfo) else {
            throw ArchiveCatalogError.unsafeDatabasePath(path)
        }
        return identity
    }

    private static func isOwnedSingleLinkRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == geteuid()
            && info.st_nlink == 1
    }

    private static func isSecureDatabaseFile(_ info: stat) -> Bool {
        isOwnedSingleLinkRegularFile(info)
            && Int(info.st_mode & 0o777) == 0o600
    }

    private static func fsyncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func capture(from row: Row) throws -> ArchiveCapture {
        let generation = try ArchiveSourceGeneration(
            device: row["generation_device"],
            inode: row["generation_inode"],
            size: row["generation_size"],
            mtimeNs: row["generation_mtime_ns"],
            ctimeNs: row["generation_ctime_ns"],
            mode: row["generation_mode"]
        )
        return ArchiveCapture(
            captureID: row["capture_id"],
            machineID: row["machine_id"],
            source: row["source"],
            locator: row["locator"],
            generation: generation,
            wholeSourceSHA256: row["whole_source_sha256"],
            rawByteCount: row["raw_byte_count"],
            chunkSize: row["chunk_size"],
            unboundManifestSHA256: row["unbound_manifest_sha256"],
            unboundManifestBytes: row["unbound_manifest_bytes"],
            status: row["status"],
            diagnostic: row["diagnostic"],
            capturedAt: row["captured_at"]
        )
    }

    private static func binding(from row: Row) throws -> ArchiveBinding {
        let manifestSHA256: String = row["manifest_sha256"]
        try validateManifestSHA256(manifestSHA256)
        let canonicalManifestBytes: Data = row["bound_manifest_bytes"]
        guard ArchiveV2Hash.sha256(canonicalManifestBytes) == manifestSHA256 else {
            throw ArchiveCatalogError.bindingConflict(
                manifestSHA256: manifestSHA256
            )
        }
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: canonicalManifestBytes
        )
        let sessionID: String = row["session_id"]
        let captureID: String = row["capture_id"]
        guard manifest.sessionID == sessionID,
              manifest.captureID == captureID else {
            throw ArchiveCatalogError.bindingConflict(
                manifestSHA256: manifestSHA256
            )
        }
        let sourceSnapshotFingerprint: String = row["source_snapshot_fingerprint"]
        guard ArchiveV2Hash.isValidSHA256(sourceSnapshotFingerprint) else {
            throw ArchiveCatalogError.invalidSHA256(
                field: "sourceSnapshotFingerprint"
            )
        }
        let boundAt: String = row["bound_at"]
        try validateTimestamp(boundAt, field: "boundAt")
        let rawEligibility: String = row["remote_eligibility"]
        guard let eligibility = ArchiveRemoteEligibility(rawValue: rawEligibility) else {
            throw ArchiveCatalogError.invalidRemoteEligibilityValue(rawEligibility)
        }
        let projectRootSnapshot: String? = row["project_root_snapshot"]
        try validateProjectRootSnapshot(
            projectRootSnapshot,
            eligibility: eligibility
        )
        return ArchiveBinding(
            manifestSHA256: manifestSHA256,
            sessionID: sessionID,
            captureID: captureID,
            sourceSnapshotFingerprint: sourceSnapshotFingerprint,
            canonicalManifestBytes: canonicalManifestBytes,
            boundAt: boundAt,
            projectRootSnapshot: projectRootSnapshot,
            remoteEligibility: eligibility
        )
    }

    private static func replicaWork(from row: Row) throws -> ArchiveReplicaWork {
        let rawState: String = row["state"]
        guard let state = ArchiveReplicaState(rawValue: rawState) else {
            throw ArchiveCatalogError.invalidReplicaState(rawState)
        }
        let attempts: Int = row["attempts"]
        guard attempts >= 0 else {
            throw ArchiveCatalogError.invalidAttempts(attempts)
        }
        let claimGeneration: Int = row["claim_generation"]
        guard claimGeneration >= 0 else {
            throw ArchiveCatalogError.invalidClaimGeneration(claimGeneration)
        }
        let nextRetryAt: String? = row["next_retry_at"]
        if let nextRetryAt {
            try validateTimestamp(nextRetryAt, field: "nextRetryAt")
        }
        let lastError: String? = row["last_error"]
        if let lastError {
            try validateLastError(lastError)
        }
        let updatedAt: String = row["updated_at"]
        try validateTimestamp(updatedAt, field: "updatedAt")
        return ArchiveReplicaWork(
            manifestSHA256: row["manifest_sha256"],
            captureID: row["capture_id"],
            replicaID: row["replica_id"],
            state: state,
            attempts: attempts,
            nextRetryAt: nextRetryAt,
            lastError: lastError,
            claimGeneration: claimGeneration,
            updatedAt: updatedAt
        )
    }

    private static func firstBindingMismatch(
        unbound: ArchiveSourceManifest,
        bound: ArchiveSourceManifest
    ) -> String? {
        if unbound.captureID != bound.captureID { return "captureID" }
        if unbound.machineID != bound.machineID { return "machineID" }
        if unbound.source != bound.source { return "source" }
        if unbound.locator != bound.locator { return "locator" }
        if unbound.capturedAt != bound.capturedAt { return "capturedAt" }
        if unbound.generation != bound.generation { return "generation" }
        if unbound.wholeSourceSHA256 != bound.wholeSourceSHA256 {
            return "wholeSourceSHA256"
        }
        if unbound.rawByteCount != bound.rawByteCount { return "rawByteCount" }
        if unbound.chunkSize != bound.chunkSize { return "chunkSize" }
        if unbound.chunks != bound.chunks { return "chunks" }
        if unbound.replayLayout != bound.replayLayout { return "replayLayout" }
        return nil
    }

    private static func validateManifestSHA256(_ value: String) throws {
        guard ArchiveV2Hash.isValidSHA256(value) else {
            throw ArchiveCatalogError.invalidSHA256(field: "manifestSHA256")
        }
    }

    private static func validateClaim(
        _ claim: ArchiveReplicaClaim,
        claimGeneration: Int
    ) throws {
        try validateManifestSHA256(claim.manifestSHA256)
        guard ArchiveV2Hash.isValidSHA256(claim.captureID) else {
            throw ArchiveCatalogError.invalidSHA256(field: "captureID")
        }
        guard !claim.sessionID.isEmpty else {
            throw ArchiveCatalogError.boundManifestRequiresSessionID
        }
        guard currentReplicaIDs.contains(claim.replicaID) else {
            throw ArchiveCatalogError.invalidReplicaID
        }
        guard claimGeneration >= 0 else {
            throw ArchiveCatalogError.invalidClaimGeneration(claimGeneration)
        }
        guard claim.attempts >= 0 else {
            throw ArchiveCatalogError.invalidAttempts(claim.attempts)
        }
        guard ArchiveV2Hash.sha256(claim.canonicalManifestBytes) == claim.manifestSHA256 else {
            throw ArchiveCatalogError.bindingConflict(
                manifestSHA256: claim.manifestSHA256
            )
        }
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: claim.canonicalManifestBytes
        )
        guard manifest.captureID == claim.captureID,
              manifest.sessionID == claim.sessionID else {
            throw ArchiveCatalogError.bindingConflict(
                manifestSHA256: claim.manifestSHA256
            )
        }
    }

    private static func isAllowedTransition(
        from: ArchiveReplicaState,
        to: ArchiveReplicaState
    ) -> Bool {
        switch (from, to) {
        case (.uploadingObjects, .uploadingManifest),
             (.uploadingManifest, .requestingReceipt),
             (.requestingReceipt, .verifyingReceipt):
            true
        default:
            false
        }
    }

    private static func validateLastError(_ value: String) throws {
        guard (1 ... 64).contains(value.utf8.count),
              value.utf8.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122)
                      || (byte >= 48 && byte <= 57)
                      || byte == 95
              }) else {
            throw ArchiveCatalogError.invalidLastError(value)
        }
    }

    private static func validateProjectRootSnapshot(
        _ value: String?,
        eligibility: ArchiveRemoteEligibility
    ) throws {
        switch eligibility {
        case .unknown:
            guard value == nil else {
                throw ArchiveCatalogError.invalidProjectRootSnapshot(value)
            }
            return
        case .eligible:
            guard value != nil else {
                throw ArchiveCatalogError.invalidProjectRootSnapshot(value)
            }
        case .excluded:
            guard value != nil else { return }
        }

        guard let value,
              !value.isEmpty,
              value.hasPrefix("/"),
              !value.utf8.contains(0),
              (value == "/" || !value.hasSuffix("/")),
              URL(fileURLWithPath: value).standardizedFileURL.path == value else {
            throw ArchiveCatalogError.invalidProjectRootSnapshot(value)
        }
    }

    private static func validate(
        receipt: ArchiveVerifiedReceipt,
        replicaID: String,
        boundManifestBytes: Data
    ) throws {
        guard ArchiveV2Hash.isValidSHA256(receipt.sha256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "receipt.sha256")
        }
        let actual = ArchiveV2Hash.sha256(receipt.canonicalBytes)
        guard actual == receipt.sha256 else {
            throw ArchiveCatalogError.receiptDigestMismatch(
                expected: receipt.sha256,
                actual: actual
            )
        }
        let decoded = try ArchiveCanonicalJSON.decode(
            ArchiveServerReceipt.self,
            from: receipt.canonicalBytes
        )
        guard decoded.serverID == replicaID else {
            throw ArchiveCatalogError.receiptReplicaMismatch(
                expected: replicaID,
                actual: decoded.serverID
            )
        }
        try validateTimestamp(receipt.verifiedAt, field: "verifiedAt")
        try decoded.validate(againstCanonicalManifestBytes: boundManifestBytes)
    }

    private static func currentTimestamp() -> String {
        timestampFormatter().string(from: Date())
    }

    private static func timestamp(
        subtracting seconds: TimeInterval,
        from value: String
    ) throws -> String {
        try validateTimestamp(value, field: "now")
        let formatter = timestampFormatter()
        let date = formatter.date(from: value)!
        return formatter.string(from: date.addingTimeInterval(-seconds))
    }

    private static func validateTimestamp(_ value: String, field: String) throws {
        let formatter = timestampFormatter()
        guard let date = formatter.date(from: value),
              formatter.string(from: date) == value else {
            throw ArchiveCatalogError.invalidTimestamp(field: field, value: value)
        }
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }
}
