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
    case invalidArchiveCursorPayloadSize(Int)
    case invalidArchiveCursorCheckpoint(String)
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

public enum ArchiveCursorKey: String, CaseIterable, Sendable {
    case captureFull = "archive_cursor_capture_full_v1"
    case captureRecent = "archive_cursor_capture_recent_v1"
    case bindingCycle = "archive_cursor_binding_v1"
    case policyCycle = "archive_cursor_policy_v1"
    case recoveryDrillHQ = "archive_recovery_drill_cursor_hq_v1"
    case recoveryDrillM1 = "archive_recovery_drill_cursor_m1_v1"
    case reclamationCycle = "archive_reclamation_cursor_v1"
}

public struct ArchiveCursorCheckpoint: Equatable, Sendable {
    public let payload: Data
    public let payloadSHA256: String
    public let updatedAt: String

    public init(payload: Data, payloadSHA256: String, updatedAt: String) {
        self.payload = payload
        self.payloadSHA256 = payloadSHA256
        self.updatedAt = updatedAt
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

public enum ArchiveLocalResidency: String, Equatable, Sendable {
    case resident
    case evicted
}

public struct ArchiveLocalObject: Equatable, Sendable {
    public let objectSHA256: String
    public let rawByteCount: Int64
    public let residency: ArchiveLocalResidency
    public let lastError: String?
    public let updatedAt: String
}

public struct ArchiveManifestObject: Equatable, Sendable {
    public let manifestSHA256: String
    public let ordinal: Int
    public let objectSHA256: String
    public let rawByteCount: Int64
    public let residency: ArchiveLocalResidency
}

public struct ArchiveRecoveryLease: Equatable, Sendable {
    public let replicaID: String
    public let manifestSHA256: String
    public let verifiedAt: String
    public let verifiedBytes: Int64

    public init(
        replicaID: String,
        manifestSHA256: String,
        verifiedAt: String,
        verifiedBytes: Int64
    ) {
        self.replicaID = replicaID
        self.manifestSHA256 = manifestSHA256
        self.verifiedAt = verifiedAt
        self.verifiedBytes = verifiedBytes
    }
}

public struct ArchiveRecoveryDrillCandidate: Equatable, Sendable {
    public let binding: ArchiveBinding
    public let rawByteCount: Int64
}

public enum ArchiveReclamationPhase: String, Equatable, Sendable {
    case eligible
    case quarantinePlanned
    case sourceQuarantined
    case sourceDeletePlanned
    case sourceDeleted
    case localContentEvicted
    case paused
}

public struct ArchiveReclamationIntent: Equatable, Sendable {
    public let manifestSHA256: String
    public let captureID: String
    public let sessionID: String
    public let locator: String
    public let phase: ArchiveReclamationPhase
    public let quarantinePath: String?
    public let attempts: Int
    public let releasedSourceBytes: Int64
    public let releasedCASBytes: Int64
    public let lastError: String?
    public let claimGeneration: Int
    public let updatedAt: String
}

public struct ArchiveReclamationCatalogCandidate: Equatable, Sendable {
    public let binding: ArchiveBinding
    public let capture: ArchiveCapture
    public let verifiedReplicaIDs: Set<String>
    public let hasNewerCapture: Bool
    public let hasActiveOperation: Bool
}

public struct ArchiveBindingCursor: Equatable, Sendable {
    public let boundAt: String
    public let manifestSHA256: String

    public init(boundAt: String, manifestSHA256: String) {
        self.boundAt = boundAt
        self.manifestSHA256 = manifestSHA256
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

public struct ArchiveRetryReasonCount: Equatable, Sendable {
    public let symbol: String
    public let count: Int

    public init(symbol: String, count: Int) {
        self.symbol = symbol
        self.count = count
    }
}

public struct ArchiveReplicaStatusCounts: Equatable, Sendable {
    public let pending: Int
    public let inflight: Int
    public let retry: Int
    public let quarantine: Int
    public let verified: Int
    public let oldestOutstandingAt: String?
    public let nextRetryAt: String?
    public let retryReasons: [ArchiveRetryReasonCount]

    public init(
        pending: Int,
        inflight: Int,
        retry: Int,
        quarantine: Int,
        verified: Int,
        oldestOutstandingAt: String? = nil,
        nextRetryAt: String? = nil,
        retryReasons: [ArchiveRetryReasonCount] = []
    ) {
        self.pending = pending
        self.inflight = inflight
        self.retry = retry
        self.quarantine = quarantine
        self.verified = verified
        self.oldestOutstandingAt = oldestOutstandingAt
        self.nextRetryAt = nextRetryAt
        self.retryReasons = Array(retryReasons.prefix(8))
    }
}

public struct ArchiveStatusReceiptSummary: Equatable, Sendable {
    public let replicaID: String
    public let manifestSHA256: String
    public let captureID: String
    public let receiptSHA256: String
    public let storedAt: String
    public let verifiedAt: String

    public init(
        replicaID: String,
        manifestSHA256: String,
        captureID: String,
        receiptSHA256: String,
        storedAt: String,
        verifiedAt: String
    ) {
        self.replicaID = replicaID
        self.manifestSHA256 = manifestSHA256
        self.captureID = captureID
        self.receiptSHA256 = receiptSHA256
        self.storedAt = storedAt
        self.verifiedAt = verifiedAt
    }
}

public struct ArchiveStatusAggregate: Equatable, Sendable {
    public let captured: Int
    public let bound: Int
    public let unbound: Int
    public let ignoredEmpty: Int
    public let unknown: Int
    public let eligible: Int
    public let excluded: Int
    public let hq: ArchiveReplicaStatusCounts
    public let m1: ArchiveReplicaStatusCounts
    public let singleVerified: Int
    public let dualVerified: Int
    public let latestReceipts: [ArchiveStatusReceiptSummary]

    public init(
        captured: Int,
        bound: Int,
        unbound: Int,
        ignoredEmpty: Int = 0,
        unknown: Int,
        eligible: Int,
        excluded: Int,
        hq: ArchiveReplicaStatusCounts,
        m1: ArchiveReplicaStatusCounts,
        singleVerified: Int,
        dualVerified: Int,
        latestReceipts: [ArchiveStatusReceiptSummary]
    ) {
        self.captured = captured
        self.bound = bound
        self.unbound = unbound
        self.ignoredEmpty = ignoredEmpty
        self.unknown = unknown
        self.eligible = eligible
        self.excluded = excluded
        self.hq = hq
        self.m1 = m1
        self.singleVerified = singleVerified
        self.dualVerified = dualVerified
        self.latestReceipts = Array(latestReceipts.prefix(2))
    }
}

private struct ArchiveCursorEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let key: String
    let payload: Data
    let payloadSHA256: String
    let updatedAt: String
}

public struct ArchiveClaudeProfileStatusCounts: Equatable, Sendable {
    public let capturedCount: Int
    public let ignoredEmptyCaptureCount: Int
    public let hqVerifiedCount: Int
    public let m1VerifiedCount: Int

    public init(
        capturedCount: Int,
        ignoredEmptyCaptureCount: Int,
        hqVerifiedCount: Int,
        m1VerifiedCount: Int
    ) {
        self.capturedCount = max(capturedCount, 0)
        self.ignoredEmptyCaptureCount = max(ignoredEmptyCaptureCount, 0)
        self.hqVerifiedCount = max(hqVerifiedCount, 0)
        self.m1VerifiedCount = max(m1VerifiedCount, 0)
    }
}

/// Rebuildable archive metadata isolated from Engram's product index database.
/// The immutable byte authority remains `ImmutableArchiveCAS`.
public final class ArchiveCatalog: @unchecked Sendable {
    public static let currentReplicaIDs = ["hq", "m1"]
    private static let databaseFilename = "archive.sqlite"
    private static let captureStatus = "captured"
    private static let ignoredCaptureStatus = "ignored"
    private static let maximumArchiveCursorPayloadBytes = 16_384

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

    public func archiveCursorCheckpoint(
        for key: ArchiveCursorKey
    ) throws -> ArchiveCursorCheckpoint? {
        try pool.read { db in
            guard let storedValue = try String.fetchOne(
                db,
                sql: "SELECT value FROM archive_metadata WHERE key = ?",
                arguments: [key.rawValue]
            ) else {
                return nil
            }
            return try Self.archiveCursorCheckpoint(
                from: storedValue,
                expectedKey: key
            )
        }
    }

    @discardableResult
    public func storeArchiveCursorCheckpoint(
        _ payload: Data,
        for key: ArchiveCursorKey,
        updatedAt: String? = nil
    ) throws -> Bool {
        let resolvedUpdatedAt = updatedAt ?? Self.currentTimestamp()
        let storedValue = try Self.archiveCursorStoredValue(
            payload: payload,
            key: key,
            updatedAt: resolvedUpdatedAt
        )

        let changed = try pool.write { db in
            try Self.upsertArchiveCursorCheckpoint(
                storedValue: storedValue,
                payload: payload,
                key: key,
                db: db
            )
        }
        if changed { try secureDatabaseFiles() }
        return changed
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
            for chunk in manifest.chunks {
                try db.execute(
                    sql: """
                    INSERT INTO archive_local_objects(
                        object_sha256, raw_byte_count, residency, updated_at
                    ) VALUES (?, ?, 'resident', ?)
                    ON CONFLICT(object_sha256) DO UPDATE SET
                        residency = 'resident',
                        updated_at = excluded.updated_at
                    WHERE archive_local_objects.raw_byte_count = excluded.raw_byte_count
                    """,
                    arguments: [chunk.rawSHA256, chunk.rawByteCount, resolvedBoundAt]
                )
                guard try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM archive_local_objects WHERE object_sha256 = ? AND raw_byte_count = ?",
                    arguments: [chunk.rawSHA256, chunk.rawByteCount]
                ) == 1 else {
                    throw ArchiveCatalogError.boundManifestMismatch(field: "chunks.rawByteCount")
                }
                try db.execute(
                    sql: """
                    INSERT INTO archive_manifest_objects(
                        manifest_sha256, ordinal, object_sha256, raw_byte_count
                    ) VALUES (?, ?, ?, ?)
                    """,
                    arguments: [manifestSHA256, chunk.ordinal, chunk.rawSHA256, chunk.rawByteCount]
                )
            }
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

    public func localObjects(manifestSHA256: String) throws -> [ArchiveManifestObject] {
        guard ArchiveV2Hash.isValidSHA256(manifestSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "manifestSHA256")
        }
        return try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT mo.manifest_sha256, mo.ordinal, mo.object_sha256,
                       mo.raw_byte_count, lo.residency
                FROM archive_manifest_objects AS mo
                JOIN archive_local_objects AS lo
                  ON lo.object_sha256 = mo.object_sha256
                WHERE mo.manifest_sha256 = ?
                ORDER BY mo.ordinal
                """,
                arguments: [manifestSHA256]
            ).map { row in
                ArchiveManifestObject(
                    manifestSHA256: row["manifest_sha256"],
                    ordinal: row["ordinal"],
                    objectSHA256: row["object_sha256"],
                    rawByteCount: row["raw_byte_count"],
                    residency: try Self.localResidency(row["residency"])
                )
            }
        }
    }

    public func localObject(objectSHA256: String) throws -> ArchiveLocalObject? {
        guard ArchiveV2Hash.isValidSHA256(objectSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "objectSHA256")
        }
        return try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_local_objects WHERE object_sha256 = ?",
                arguments: [objectSHA256]
            ).map { row in
                ArchiveLocalObject(
                    objectSHA256: row["object_sha256"],
                    rawByteCount: row["raw_byte_count"],
                    residency: try Self.localResidency(row["residency"]),
                    lastError: row["last_error"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    public func referencingManifests(objectSHA256: String) throws -> [String] {
        guard ArchiveV2Hash.isValidSHA256(objectSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "objectSHA256")
        }
        return try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT manifest_sha256 FROM archive_manifest_objects
                WHERE object_sha256 = ? ORDER BY manifest_sha256
                """,
                arguments: [objectSHA256]
            )
        }
    }

    @discardableResult
    public func markLocalObjectEvicted(
        objectSHA256: String,
        updatedAt: String
    ) throws -> Bool {
        guard ArchiveV2Hash.isValidSHA256(objectSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "objectSHA256")
        }
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        return try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_local_objects
                SET residency = 'evicted', last_error = NULL, updated_at = ?
                WHERE object_sha256 = ? AND residency = 'resident'
                """,
                arguments: [updatedAt, objectSHA256]
            )
            return db.changesCount == 1
        }
    }

    @discardableResult
    public func recordLocalObjectIntegrityFault(
        objectSHA256: String,
        updatedAt: String
    ) throws -> Bool {
        guard ArchiveV2Hash.isValidSHA256(objectSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "objectSHA256")
        }
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        return try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_local_objects
                SET last_error = 'local_integrity_fault', updated_at = ?
                WHERE object_sha256 = ? AND residency = 'resident'
                  AND COALESCE(last_error, '') != 'local_integrity_fault'
                """,
                arguments: [updatedAt, objectSHA256]
            )
            return db.changesCount == 1
        }
    }

    @discardableResult
    public func recordRecoveryLease(
        replicaID: String,
        manifestSHA256: String,
        verifiedAt: String,
        verifiedBytes: Int64
    ) throws -> ArchiveRecoveryLease {
        guard Self.currentReplicaIDs.contains(replicaID) else {
            throw ArchiveCatalogError.invalidReplicaID
        }
        guard ArchiveV2Hash.isValidSHA256(manifestSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "manifestSHA256")
        }
        guard verifiedBytes >= 0 else {
            throw ArchiveCatalogError.invalidLimit(Int(verifiedBytes))
        }
        try Self.validateTimestamp(verifiedAt, field: "verifiedAt")
        let lease = ArchiveRecoveryLease(
            replicaID: replicaID,
            manifestSHA256: manifestSHA256,
            verifiedAt: verifiedAt,
            verifiedBytes: verifiedBytes
        )
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO archive_recovery_leases(
                    replica_id, manifest_sha256, verified_at, verified_bytes, result, error
                ) VALUES (?, ?, ?, ?, 'verified', NULL)
                ON CONFLICT(replica_id) DO UPDATE SET
                    manifest_sha256 = excluded.manifest_sha256,
                    verified_at = excluded.verified_at,
                    verified_bytes = excluded.verified_bytes,
                    result = 'verified', error = NULL
                """,
                arguments: [replicaID, manifestSHA256, verifiedAt, verifiedBytes]
            )
        }
        return lease
    }

    public func recoveryLease(replicaID: String) throws -> ArchiveRecoveryLease? {
        guard Self.currentReplicaIDs.contains(replicaID) else {
            throw ArchiveCatalogError.invalidReplicaID
        }
        return try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_recovery_leases WHERE replica_id = ?",
                arguments: [replicaID]
            ).map { row in
                ArchiveRecoveryLease(
                    replicaID: row["replica_id"],
                    manifestSHA256: row["manifest_sha256"],
                    verifiedAt: row["verified_at"],
                    verifiedBytes: row["verified_bytes"]
                )
            }
        }
    }

    public func recordRecoveryLeaseAndAdvanceCursor(
        replicaID: String,
        manifestSHA256: String,
        verifiedAt: String,
        verifiedBytes: Int64
    ) throws -> ArchiveRecoveryLease {
        let lease = ArchiveRecoveryLease(
            replicaID: replicaID,
            manifestSHA256: manifestSHA256,
            verifiedAt: verifiedAt,
            verifiedBytes: verifiedBytes
        )
        let cursor = try Self.recoveryDrillCursorValue(
            replicaID: replicaID,
            manifestSHA256: manifestSHA256,
            updatedAt: verifiedAt
        )
        guard verifiedBytes >= 0 else {
            throw ArchiveCatalogError.invalidLimit(Int(verifiedBytes))
        }
        try pool.write { db in
            try Self.requireVerifiedRecoveryCandidate(
                db: db,
                replicaID: replicaID,
                manifestSHA256: manifestSHA256
            )
            try db.execute(
                sql: """
                INSERT INTO archive_recovery_leases(
                    replica_id, manifest_sha256, verified_at, verified_bytes, result, error
                ) VALUES (?, ?, ?, ?, 'verified', NULL)
                ON CONFLICT(replica_id) DO UPDATE SET
                    manifest_sha256 = excluded.manifest_sha256,
                    verified_at = excluded.verified_at,
                    verified_bytes = excluded.verified_bytes,
                    result = 'verified', error = NULL
                """,
                arguments: [replicaID, manifestSHA256, verifiedAt, verifiedBytes]
            )
            try Self.storeRecoveryDrillCursor(cursor, db: db)
        }
        try secureDatabaseFiles()
        return lease
    }

    public func expireRecoveryLeaseAndAdvanceCursor(
        replicaID: String,
        manifestSHA256: String,
        failedAt: String
    ) throws {
        let cursor = try Self.recoveryDrillCursorValue(
            replicaID: replicaID,
            manifestSHA256: manifestSHA256,
            updatedAt: failedAt
        )
        try pool.write { db in
            try Self.requireVerifiedRecoveryCandidate(
                db: db,
                replicaID: replicaID,
                manifestSHA256: manifestSHA256
            )
            try db.execute(
                sql: "DELETE FROM archive_recovery_leases WHERE replica_id = ?",
                arguments: [replicaID]
            )
            try Self.storeRecoveryDrillCursor(cursor, db: db)
        }
        try secureDatabaseFiles()
    }

    public func nextRecoveryDrillCandidate(
        replicaID: String,
        maximumBytes: Int64
    ) throws -> ArchiveRecoveryDrillCandidate? {
        let cursorKey = try Self.recoveryDrillCursorKey(replicaID: replicaID)
        guard maximumBytes > 0 else {
            throw ArchiveCatalogError.invalidLimit(Int(maximumBytes))
        }

        return try pool.read { db in
            let cursor: String?
            if let storedValue = try String.fetchOne(
                db,
                sql: "SELECT value FROM archive_metadata WHERE key = ?",
                arguments: [cursorKey.rawValue]
            ) {
                let checkpoint = try Self.archiveCursorCheckpoint(
                    from: storedValue,
                    expectedKey: cursorKey
                )
                guard let decoded = String(data: checkpoint.payload, encoding: .utf8),
                      ArchiveV2Hash.isValidSHA256(decoded) else {
                    throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(cursorKey.rawValue)
                }
                cursor = decoded
            } else {
                cursor = nil
            }

            let baseSQL = """
                SELECT b.*, c.raw_byte_count
                FROM archive_session_bindings AS b
                JOIN archive_captures AS c ON c.capture_id = b.capture_id
                JOIN archive_replica_receipts AS r
                  ON r.manifest_sha256 = b.manifest_sha256
                 AND r.replica_id = ?
                WHERE b.remote_eligibility = 'eligible'
                  AND r.state = 'verified'
                  AND r.receipt_bytes IS NOT NULL
                  AND c.raw_byte_count <= ?
                  AND NOT EXISTS (
                      SELECT 1 FROM archive_session_bindings AS newer
                      WHERE newer.session_id = b.session_id
                        AND (
                            newer.bound_at > b.bound_at
                            OR (
                                newer.bound_at = b.bound_at
                                AND newer.manifest_sha256 > b.manifest_sha256
                            )
                        )
                  )
                """
            let row: Row?
            if let cursor {
                row = try Row.fetchOne(
                    db,
                    sql: baseSQL + " AND b.manifest_sha256 > ? ORDER BY b.manifest_sha256 LIMIT 1",
                    arguments: [replicaID, maximumBytes, cursor]
                ) ?? Row.fetchOne(
                    db,
                    sql: baseSQL + " ORDER BY b.manifest_sha256 LIMIT 1",
                    arguments: [replicaID, maximumBytes]
                )
            } else {
                row = try Row.fetchOne(
                    db,
                    sql: baseSQL + " ORDER BY b.manifest_sha256 LIMIT 1",
                    arguments: [replicaID, maximumBytes]
                )
            }
            return try row.map {
                ArchiveRecoveryDrillCandidate(
                    binding: try Self.binding(from: $0),
                    rawByteCount: $0["raw_byte_count"]
                )
            }
        }
    }

    public func advanceRecoveryDrillCursor(
        replicaID: String,
        manifestSHA256: String,
        updatedAt: String
    ) throws {
        let cursor = try Self.recoveryDrillCursorValue(
            replicaID: replicaID,
            manifestSHA256: manifestSHA256,
            updatedAt: updatedAt
        )

        try pool.write { db in
            try Self.requireVerifiedRecoveryCandidate(
                db: db,
                replicaID: replicaID,
                manifestSHA256: manifestSHA256
            )
            try Self.storeRecoveryDrillCursor(cursor, db: db)
        }
        try secureDatabaseFiles()
    }

    public func upsertReclamationIntent(
        manifestSHA256: String,
        captureID: String,
        sessionID: String,
        locator: String,
        updatedAt: String
    ) throws -> ArchiveReclamationIntent {
        guard ArchiveV2Hash.isValidSHA256(manifestSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "manifestSHA256")
        }
        guard ArchiveV2Hash.isValidSHA256(captureID) else {
            throw ArchiveCatalogError.invalidSHA256(field: "captureID")
        }
        guard !sessionID.isEmpty, !locator.isEmpty else {
            throw ArchiveCatalogError.boundManifestMismatch(field: "reclamationIdentity")
        }
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        try pool.write { db in
            guard let identity = try Row.fetchOne(
                db,
                sql: """
                SELECT b.capture_id, b.session_id, c.locator
                FROM archive_session_bindings AS b
                JOIN archive_captures AS c ON c.capture_id = b.capture_id
                WHERE b.manifest_sha256 = ?
                """,
                arguments: [manifestSHA256]
            ) else {
                throw ArchiveCatalogError.bindingNotFound(manifestSHA256: manifestSHA256)
            }
            let boundCaptureID: String = identity["capture_id"]
            let boundSessionID: String = identity["session_id"]
            let boundLocator: String = identity["locator"]
            guard boundCaptureID == captureID,
                  boundSessionID == sessionID,
                  boundLocator == locator else {
                throw ArchiveCatalogError.bindingConflict(manifestSHA256: manifestSHA256)
            }
            try db.execute(
                sql: """
                INSERT INTO archive_reclamation_intents(
                    manifest_sha256, capture_id, session_id, locator, phase,
                    quarantine_path, attempts, released_source_bytes,
                    released_cas_bytes, last_error, claim_generation, updated_at
                ) VALUES (?, ?, ?, ?, 'eligible', NULL, 0, 0, 0, NULL, 0, ?)
                ON CONFLICT(manifest_sha256) DO NOTHING
                """,
                arguments: [manifestSHA256, captureID, sessionID, locator, updatedAt]
            )
        }
        guard let intent = try reclamationIntent(manifestSHA256: manifestSHA256),
              intent.captureID == captureID,
              intent.sessionID == sessionID,
              intent.locator == locator else {
            throw ArchiveCatalogError.bindingConflict(manifestSHA256: manifestSHA256)
        }
        return intent
    }

    public func reclamationIntent(
        manifestSHA256: String
    ) throws -> ArchiveReclamationIntent? {
        guard ArchiveV2Hash.isValidSHA256(manifestSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "manifestSHA256")
        }
        return try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_reclamation_intents WHERE manifest_sha256 = ?",
                arguments: [manifestSHA256]
            ).map { try Self.reclamationIntent(from: $0) }
        }
    }

    public func reclamationCandidates(
        limit: Int,
        after cursor: ArchiveBindingCursor? = nil
    ) throws -> [ArchiveReclamationCatalogCandidate] {
        guard limit > 0 else { throw ArchiveCatalogError.invalidLimit(limit) }
        if let cursor {
            try Self.validateBindingCursor(cursor, fieldPrefix: "reclamationCursor")
        }
        return try pool.read { db in
            let cursorSQL = cursor == nil ? "" : """
                AND (b.bound_at > ? OR (b.bound_at = ? AND b.manifest_sha256 > ?))
                """
            var arguments = StatementArguments()
            if let cursor {
                arguments += [cursor.boundAt, cursor.boundAt, cursor.manifestSHA256]
            }
            arguments += [limit]
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.*, c.*,
                  EXISTS(
                    SELECT 1 FROM archive_captures newer
                    WHERE newer.locator = c.locator AND newer.captured_at > c.captured_at
                  ) AS has_newer,
                  EXISTS(
                    SELECT 1 FROM archive_replica_receipts r
                    WHERE r.manifest_sha256 = b.manifest_sha256
                      AND r.state IN ('pending', 'uploadingObjects', 'uploadingManifest',
                                      'requestingReceipt', 'verifyingReceipt')
                  ) AS has_active
                FROM archive_session_bindings b
                JOIN archive_captures c ON c.capture_id = b.capture_id
                WHERE b.remote_eligibility = 'eligible'
                  AND (SELECT COUNT(DISTINCT r.replica_id)
                       FROM archive_replica_receipts r
                       WHERE r.manifest_sha256 = b.manifest_sha256
                         AND r.state = 'verified'
                         AND r.receipt_bytes IS NOT NULL
                         AND r.receipt_sha256 IS NOT NULL) = 2
                  AND NOT EXISTS(
                    SELECT 1 FROM archive_replica_receipts active
                    WHERE active.manifest_sha256 = b.manifest_sha256
                      AND active.state IN ('pending', 'uploadingObjects', 'uploadingManifest',
                                           'requestingReceipt', 'verifyingReceipt')
                  )
                \(cursorSQL)
                ORDER BY b.bound_at ASC, b.manifest_sha256 ASC
                LIMIT ?
                """, arguments: arguments)
            return try rows.map { row in
                let binding = try Self.binding(from: row)
                let capture = try Self.capture(from: row)
                let replicaIDs = try String.fetchAll(db, sql: """
                    SELECT replica_id FROM archive_replica_receipts
                    WHERE manifest_sha256 = ? AND state = 'verified'
                      AND receipt_bytes IS NOT NULL AND receipt_sha256 IS NOT NULL
                    """, arguments: [binding.manifestSHA256])
                return ArchiveReclamationCatalogCandidate(
                    binding: binding,
                    capture: capture,
                    verifiedReplicaIDs: Set(replicaIDs),
                    hasNewerCapture: (row["has_newer"] as Int) != 0,
                    hasActiveOperation: (row["has_active"] as Int) != 0
                )
            }
        }
    }

    public func reclamationIntents(
        phases: Set<ArchiveReclamationPhase>,
        limit: Int
    ) throws -> [ArchiveReclamationIntent] {
        guard limit > 0 else { throw ArchiveCatalogError.invalidLimit(limit) }
        guard !phases.isEmpty else { return [] }
        let values = phases.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM archive_reclamation_intents WHERE phase IN (\(placeholders)) ORDER BY updated_at ASC, manifest_sha256 ASC LIMIT ?",
                arguments: StatementArguments(values + [String(limit)])
            )
            return try rows.map { try Self.reclamationIntent(from: $0) }
        }
    }

    @discardableResult
    public func transitionReclamationIntent(
        manifestSHA256: String,
        from: ArchiveReclamationPhase,
        to: ArchiveReclamationPhase,
        expectedClaimGeneration: Int,
        quarantinePath: String?,
        updatedAt: String,
        releasedSourceBytes: Int64? = nil,
        releasedCASBytes: Int64? = nil,
        lastError: String? = nil
    ) throws -> Bool {
        guard Self.isAllowedReclamationTransition(from: from, to: to) else {
            return false
        }
        guard ArchiveV2Hash.isValidSHA256(manifestSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "manifestSHA256")
        }
        guard expectedClaimGeneration >= 0 else {
            throw ArchiveCatalogError.invalidClaimGeneration(expectedClaimGeneration)
        }
        if to == .quarantinePlanned || to == .sourceQuarantined {
            guard let quarantinePath, !quarantinePath.isEmpty else { return false }
        }
        if let releasedSourceBytes, releasedSourceBytes < 0 {
            throw ArchiveCatalogError.invalidLimit(Int(releasedSourceBytes))
        }
        if let releasedCASBytes, releasedCASBytes < 0 {
            throw ArchiveCatalogError.invalidLimit(Int(releasedCASBytes))
        }
        if let lastError { try Self.validateLastError(lastError) }
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        return try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_reclamation_intents
                SET phase = ?,
                    quarantine_path = COALESCE(quarantine_path, ?),
                    released_source_bytes = COALESCE(?, released_source_bytes),
                    released_cas_bytes = COALESCE(?, released_cas_bytes),
                    last_error = ?,
                    attempts = attempts + CASE WHEN ? IS NULL THEN 0 ELSE 1 END,
                    updated_at = ?,
                    claim_generation = claim_generation + 1
                WHERE manifest_sha256 = ? AND phase = ? AND claim_generation = ?
                  AND (? IS NULL OR quarantine_path IS NULL OR quarantine_path = ?)
                """,
                arguments: [
                    to.rawValue,
                    quarantinePath,
                    releasedSourceBytes,
                    releasedCASBytes,
                    lastError,
                    lastError,
                    updatedAt,
                    manifestSHA256,
                    from.rawValue,
                    expectedClaimGeneration,
                    quarantinePath,
                    quarantinePath,
                ]
            )
            return db.changesCount == 1
        }
    }

    public func unknownBindings(
        limit: Int,
        after cursor: ArchiveBindingCursor?
    ) throws -> [ArchiveBinding] {
        try unknownBindings(limit: limit, after: cursor, through: nil)
    }

    /// Stable upper bound for one historical-policy sweep. Rows appended after
    /// this key are intentionally deferred to the next sweep so a continuously
    /// growing tail cannot prevent older `unknown` bindings from being revisited.
    public func unknownBindingBoundary() throws -> ArchiveBindingCursor? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT bound_at, manifest_sha256
                FROM archive_session_bindings
                WHERE remote_eligibility = 'unknown'
                ORDER BY bound_at DESC, manifest_sha256 DESC
                LIMIT 1
                """
            ) else {
                return nil
            }
            let cursor = ArchiveBindingCursor(
                boundAt: row["bound_at"],
                manifestSHA256: row["manifest_sha256"]
            )
            try Self.validateBindingCursor(cursor, fieldPrefix: "boundary")
            return cursor
        }
    }

    public func unknownBindings(
        limit: Int,
        after cursor: ArchiveBindingCursor?,
        through boundary: ArchiveBindingCursor?
    ) throws -> [ArchiveBinding] {
        guard limit > 0 else {
            throw ArchiveCatalogError.invalidLimit(limit)
        }
        if let cursor {
            try Self.validateBindingCursor(cursor, fieldPrefix: "cursor")
        }
        if let boundary {
            try Self.validateBindingCursor(boundary, fieldPrefix: "boundary")
        }
        return try pool.read { db in
            let cursorPredicate: String
            let boundaryPredicate: String
            var arguments = StatementArguments()
            if let cursor {
                cursorPredicate = """
                  AND (bound_at > ? OR (bound_at = ? AND manifest_sha256 > ?))
                """
                arguments += [
                    cursor.boundAt,
                    cursor.boundAt,
                    cursor.manifestSHA256,
                ]
            } else {
                cursorPredicate = ""
            }
            if let boundary {
                boundaryPredicate = """
                  AND (bound_at < ? OR (bound_at = ? AND manifest_sha256 <= ?))
                """
                arguments += [
                    boundary.boundAt,
                    boundary.boundAt,
                    boundary.manifestSHA256,
                ]
            } else {
                boundaryPredicate = ""
            }
            arguments += [limit]
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM archive_session_bindings
                WHERE remote_eligibility = 'unknown'
                \(cursorPredicate)
                \(boundaryPredicate)
                ORDER BY bound_at ASC, manifest_sha256 ASC
                LIMIT ?
                """,
                arguments: arguments
            )
            return try rows.map(Self.binding(from:))
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

    @discardableResult
    public func ignoreUnboundCapture(
        captureID: String,
        reason: String,
        updatedAt: String
    ) throws -> Bool {
        guard ArchiveV2Hash.isValidSHA256(captureID) else {
            throw ArchiveCatalogError.invalidSHA256(field: "captureID")
        }
        try Self.validateLastError(reason)
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        let changed = try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_captures
                SET status = ?, diagnostic = ?, updated_at = ?
                WHERE capture_id = ? AND status = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM archive_session_bindings AS b
                    WHERE b.capture_id = archive_captures.capture_id
                  )
                """,
                arguments: [
                    Self.ignoredCaptureStatus,
                    reason,
                    updatedAt,
                    captureID,
                    Self.captureStatus,
                ]
            )
            return db.changesCount == 1
        }
        if changed { try secureDatabaseFiles() }
        return changed
    }

    @discardableResult
    func ignoreUnboundCaptureAndStoreBindingCursorCheckpoint(
        captureID: String,
        reason: String,
        updatedAt: String,
        bindingCursorPayload: Data
    ) throws -> Bool {
        guard ArchiveV2Hash.isValidSHA256(captureID) else {
            throw ArchiveCatalogError.invalidSHA256(field: "captureID")
        }
        try Self.validateLastError(reason)
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        let storedCursorValue = try Self.archiveCursorStoredValue(
            payload: bindingCursorPayload,
            key: .bindingCycle,
            updatedAt: updatedAt
        )

        let changed = try pool.write { db in
            try db.execute(
                sql: """
                UPDATE archive_captures
                SET status = ?, diagnostic = ?, updated_at = ?
                WHERE capture_id = ? AND status = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM archive_session_bindings AS b
                    WHERE b.capture_id = archive_captures.capture_id
                  )
                """,
                arguments: [
                    Self.ignoredCaptureStatus,
                    reason,
                    updatedAt,
                    captureID,
                    Self.captureStatus,
                ]
            )
            guard db.changesCount == 1 else { return false }
            guard try Self.upsertArchiveCursorCheckpoint(
                storedValue: storedCursorValue,
                payload: bindingCursorPayload,
                key: .bindingCycle,
                db: db
            ) else {
                throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(
                    ArchiveCursorKey.bindingCycle.rawValue
                )
            }
            return true
        }
        if changed { try secureDatabaseFiles() }
        return changed
    }

    public func ignoredCaptureCount(reason: String) throws -> Int {
        try Self.validateLastError(reason)
        return try pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM archive_captures
                WHERE status = ? AND diagnostic = ?
                """,
                arguments: [Self.ignoredCaptureStatus, reason]
            ) ?? 0
        }
    }

    /// Aggregate exact Claude Code captures for one canonical `projects` root.
    /// `substr` plus the explicit slash boundary avoids both SQL wildcard
    /// interpretation and sibling-prefix matches such as `/foo` vs `/foobar`.
    public func claudeProfileStatusCounts(
        canonicalProjectsRoot: String
    ) throws -> ArchiveClaudeProfileStatusCounts {
        let standardized = URL(
            fileURLWithPath: canonicalProjectsRoot,
            isDirectory: true
        ).standardizedFileURL.path
        guard canonicalProjectsRoot.hasPrefix("/"),
              canonicalProjectsRoot != "/",
              canonicalProjectsRoot == standardized
        else {
            throw ArchiveCatalogError.unsafeRoot(canonicalProjectsRoot)
        }

        return try pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                WITH matching_captures AS (
                    SELECT capture_id, status, diagnostic
                    FROM archive_captures
                    WHERE source = 'claude-code'
                      AND (
                        locator = ?
                        OR substr(locator, 1, length(?) + 1) = ? || '/'
                      )
                )
                SELECT
                    COUNT(DISTINCT c.capture_id) AS captured_count,
                    COUNT(DISTINCT CASE
                        WHEN c.status = 'ignored'
                         AND c.diagnostic = 'no_visible_messages'
                        THEN c.capture_id END
                    ) AS ignored_empty_count,
                    COUNT(DISTINCT CASE
                        WHEN r.replica_id = 'hq' AND r.state = 'verified'
                        THEN c.capture_id END
                    ) AS hq_verified_count,
                    COUNT(DISTINCT CASE
                        WHEN r.replica_id = 'm1' AND r.state = 'verified'
                        THEN c.capture_id END
                    ) AS m1_verified_count
                FROM matching_captures AS c
                LEFT JOIN archive_session_bindings AS b
                  ON b.capture_id = c.capture_id
                LEFT JOIN archive_replica_receipts AS r
                  ON r.manifest_sha256 = b.manifest_sha256
                 AND r.capture_id = c.capture_id
                """,
                arguments: [
                    canonicalProjectsRoot,
                    canonicalProjectsRoot,
                    canonicalProjectsRoot,
                ]
            )!
            return ArchiveClaudeProfileStatusCounts(
                capturedCount: row["captured_count"],
                ignoredEmptyCaptureCount: row["ignored_empty_count"],
                hqVerifiedCount: row["hq_verified_count"],
                m1VerifiedCount: row["m1_verified_count"]
            )
        }
    }

    public func replicaReceiptCount(captureID: String) throws -> Int {
        guard ArchiveV2Hash.isValidSHA256(captureID) else {
            throw ArchiveCatalogError.invalidSHA256(field: "captureID")
        }
        return try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM archive_replica_receipts WHERE capture_id = ?",
                arguments: [captureID]
            ) ?? 0
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
                WHERE b.capture_id IS NULL AND c.status = ?
                ORDER BY c.captured_at DESC, c.capture_id DESC
                LIMIT 1
                """,
                arguments: [Self.captureStatus]
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
            var arguments: StatementArguments = [Self.captureStatus]
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
                WHERE b.capture_id IS NULL AND c.status = ?
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

    public func claimReplicaWork(
        replicaID: String,
        limit: Int,
        retryQuota: Int,
        now: String
    ) throws -> [ArchiveReplicaClaim] {
        guard Self.currentReplicaIDs.contains(replicaID) else {
            throw ArchiveCatalogError.invalidReplicaID
        }
        guard limit > 0 else {
            throw ArchiveCatalogError.invalidLimit(limit)
        }
        guard retryQuota >= 0, retryQuota <= limit else {
            throw ArchiveCatalogError.invalidLimit(retryQuota)
        }
        try Self.validateTimestamp(now, field: "now")

        struct Candidate {
            let manifestSHA256: String
            let updatedAt: String
            let isRetry: Bool
        }

        let claims = try pool.write { db in
            func candidates(state: String, limit: Int) throws -> [Candidate] {
                guard limit > 0 else { return [] }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT r.manifest_sha256, r.updated_at
                    FROM archive_replica_receipts AS r
                    JOIN archive_session_bindings AS b
                      ON b.manifest_sha256 = r.manifest_sha256
                    WHERE b.remote_eligibility = 'eligible'
                      AND r.replica_id = ?
                      AND r.state = ?
                      AND (
                          r.state != 'retryWait'
                          OR r.next_retry_at IS NULL
                          OR r.next_retry_at <= ?
                      )
                    ORDER BY r.updated_at ASC, r.manifest_sha256 ASC
                    LIMIT ?
                    """,
                    arguments: [replicaID, state, now, limit]
                )
                return rows.map { row in
                    Candidate(
                        manifestSHA256: row["manifest_sha256"],
                        updatedAt: row["updated_at"],
                        isRetry: state == ArchiveReplicaState.retryWait.rawValue
                    )
                }
            }

            let retryCandidates = try candidates(
                state: ArchiveReplicaState.retryWait.rawValue,
                limit: limit
            )
            let pendingCandidates = try candidates(
                state: ArchiveReplicaState.pending.rawValue,
                limit: limit
            )
            let pendingQuota = limit - retryQuota
            var selected = Array(retryCandidates.prefix(retryQuota))
                + Array(pendingCandidates.prefix(pendingQuota))
            if selected.count < limit {
                let leftovers = (
                    Array(retryCandidates.dropFirst(retryQuota))
                        + Array(pendingCandidates.dropFirst(pendingQuota))
                ).sorted {
                    ($0.updatedAt, $0.manifestSHA256, $0.isRetry ? 0 : 1)
                        < ($1.updatedAt, $1.manifestSHA256, $1.isRetry ? 0 : 1)
                }
                selected.append(contentsOf: leftovers.prefix(limit - selected.count))
            }

            var claims: [ArchiveReplicaClaim] = []
            claims.reserveCapacity(selected.count)
            for candidate in selected {
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    UPDATE archive_replica_receipts
                    SET state = 'uploadingObjects',
                        claim_generation = claim_generation + 1,
                        next_retry_at = NULL,
                        last_error = NULL,
                        updated_at = ?
                    WHERE manifest_sha256 = ? AND replica_id = ?
                      AND (
                          state = 'pending'
                          OR (
                              state = 'retryWait'
                              AND (next_retry_at IS NULL OR next_retry_at <= ?)
                          )
                      )
                    RETURNING capture_id, attempts, claim_generation
                    """,
                    arguments: [now, candidate.manifestSHA256, replicaID, now]
                )
                guard let row else { continue }
                guard let bindingRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM archive_session_bindings
                    WHERE manifest_sha256 = ? AND remote_eligibility = 'eligible'
                    """,
                    arguments: [candidate.manifestSHA256]
                ) else {
                    throw ArchiveCatalogError.bindingNotFound(
                        manifestSHA256: candidate.manifestSHA256
                    )
                }
                let binding = try Self.binding(from: bindingRow)
                let captureID: String = row["capture_id"]
                guard binding.captureID == captureID else {
                    throw ArchiveCatalogError.bindingConflict(
                        manifestSHA256: candidate.manifestSHA256
                    )
                }
                let claim = ArchiveReplicaClaim(
                    manifestSHA256: candidate.manifestSHA256,
                    captureID: captureID,
                    sessionID: binding.sessionID,
                    replicaID: replicaID,
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
            return claims
        }
        if !claims.isEmpty { try secureDatabaseFiles() }
        return claims
    }

    @discardableResult
    public func releaseUnstartedReplicaClaims(
        _ claims: [ArchiveReplicaClaim],
        updatedAt: String
    ) throws -> Int {
        try Self.validateTimestamp(updatedAt, field: "updatedAt")
        guard !claims.isEmpty else { return 0 }
        let released = try pool.write { db in
            var count = 0
            for claim in claims {
                try Self.validateClaim(
                    claim,
                    claimGeneration: claim.claimGeneration
                )
                try db.execute(
                    sql: """
                    UPDATE archive_replica_receipts
                    SET state = 'pending',
                        claim_generation = claim_generation + 1,
                        next_retry_at = NULL,
                        last_error = NULL,
                        updated_at = ?
                    WHERE manifest_sha256 = ?
                      AND capture_id = ?
                      AND replica_id = ?
                      AND state = 'uploadingObjects'
                      AND claim_generation = ?
                    """,
                    arguments: [
                        updatedAt,
                        claim.manifestSHA256,
                        claim.captureID,
                        claim.replicaID,
                        claim.claimGeneration,
                    ]
                )
                count += db.changesCount
            }
            return count
        }
        if released > 0 { try secureDatabaseFiles() }
        return released
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

    public func currentVerifiedReceipt(
        manifestSHA256: String,
        replicaID: String
    ) throws -> ArchiveVerifiedReceipt? {
        try Self.validateManifestSHA256(manifestSHA256)
        guard Self.currentReplicaIDs.contains(replicaID) else {
            throw ArchiveCatalogError.invalidReplicaID
        }
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
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT capture_id, replica_id, receipt_bytes, receipt_sha256, verified_at
                FROM archive_replica_receipts
                WHERE manifest_sha256 = ?
                  AND replica_id = ?
                  AND state = 'verified'
                """,
                arguments: [manifestSHA256, replicaID]
            ) else {
                return nil
            }
            return try Self.verifiedReceipt(
                from: row,
                binding: binding,
                replicaID: replicaID
            )
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
                receipts[replicaID] = try Self.verifiedReceipt(
                    from: row,
                    binding: binding,
                    replicaID: replicaID,
                )
            }
            return receipts
        }
    }

    private static func verifiedReceipt(
        from row: Row,
        binding: ArchiveBinding,
        replicaID: String
    ) throws -> ArchiveVerifiedReceipt {
        let captureID: String = row["capture_id"]
        guard captureID == binding.captureID else {
            throw ArchiveCatalogError.bindingConflict(
                manifestSHA256: binding.manifestSHA256
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
        try validate(
            receipt: receipt,
            replicaID: replicaID,
            boundManifestBytes: binding.canonicalManifestBytes
        )
        return receipt
    }

    public func archiveStatus() throws -> ArchiveStatusAggregate {
        try pool.read { db in
            let captured = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM archive_captures"
            ) ?? 0
            let unbound = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM archive_captures AS c
                LEFT JOIN archive_session_bindings AS b
                  ON b.capture_id = c.capture_id
                WHERE b.capture_id IS NULL AND c.status = ?
                """,
                arguments: [Self.captureStatus]
            ) ?? 0
            let ignoredEmpty = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM archive_captures
                WHERE status = ? AND diagnostic = 'no_visible_messages'
                """,
                arguments: [Self.ignoredCaptureStatus]
            ) ?? 0
            let eligibility = try Row.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) AS bound,
                       COALESCE(SUM(remote_eligibility = 'unknown'), 0) AS unknown_count,
                       COALESCE(SUM(remote_eligibility = 'eligible'), 0) AS eligible_count,
                       COALESCE(SUM(remote_eligibility = 'excluded'), 0) AS excluded_count,
                       COALESCE(SUM(remote_eligibility NOT IN ('unknown', 'eligible', 'excluded')), 0)
                         AS invalid_count
                FROM archive_session_bindings
                """
            )!
            let invalidEligibility: Int = eligibility["invalid_count"]
            guard invalidEligibility == 0 else {
                throw ArchiveCatalogError.invalidRemoteEligibility
            }

            var replicaCounts: [String: ArchiveReplicaStatusCounts] = [:]
            let countRows = try Row.fetchAll(
                db,
                sql: """
                SELECT replica_id,
                       COALESCE(SUM(state = 'pending'), 0) AS pending_count,
                       COALESCE(SUM(state IN ('uploadingObjects', 'uploadingManifest',
                                              'requestingReceipt', 'verifyingReceipt')), 0)
                         AS inflight_count,
                       COALESCE(SUM(state = 'retryWait'), 0) AS retry_count,
                       COALESCE(SUM(state = 'quarantined'), 0) AS quarantine_count,
                       COALESCE(SUM(state = 'verified'), 0) AS verified_count,
                       MIN(CASE WHEN state IN ('pending', 'uploadingObjects',
                                               'uploadingManifest', 'requestingReceipt',
                                               'verifyingReceipt', 'retryWait', 'quarantined')
                                THEN updated_at END) AS oldest_outstanding_at,
                       MIN(CASE WHEN state = 'retryWait'
                                THEN next_retry_at END) AS next_retry_at,
                       COALESCE(SUM(state NOT IN ('pending', 'uploadingObjects',
                                                  'uploadingManifest', 'requestingReceipt',
                                                  'verifyingReceipt', 'verified',
                                                  'retryWait', 'quarantined')), 0)
                         AS invalid_count
                FROM archive_replica_receipts
                WHERE replica_id IN ('hq', 'm1')
                GROUP BY replica_id
                """
            )
            var retryReasons: [String: [ArchiveRetryReasonCount]] = [:]
            let reasonRows = try Row.fetchAll(
                db,
                sql: """
                WITH reasons AS (
                    SELECT replica_id, last_error, COUNT(*) AS reason_count
                    FROM archive_replica_receipts
                    WHERE replica_id IN ('hq', 'm1')
                      AND state IN ('retryWait', 'quarantined')
                      AND last_error IS NOT NULL
                    GROUP BY replica_id, last_error
                ), ranked AS (
                    SELECT replica_id, last_error, reason_count,
                           ROW_NUMBER() OVER (
                               PARTITION BY replica_id
                               ORDER BY reason_count DESC, last_error ASC
                           ) AS reason_rank
                    FROM reasons
                )
                SELECT replica_id, last_error, reason_count
                FROM ranked
                WHERE reason_rank <= 8
                ORDER BY replica_id ASC, reason_count DESC, last_error ASC
                """
            )
            for row in reasonRows {
                let replicaID: String = row["replica_id"]
                let symbol: String = row["last_error"]
                try Self.validateLastError(symbol)
                retryReasons[replicaID, default: []].append(
                    ArchiveRetryReasonCount(
                        symbol: symbol,
                        count: row["reason_count"]
                    )
                )
            }
            for row in countRows {
                let invalidStateCount: Int = row["invalid_count"]
                guard invalidStateCount == 0 else {
                    throw ArchiveCatalogError.invalidReplicaState("catalog")
                }
                let replicaID: String = row["replica_id"]
                let oldestOutstandingAt: String? = row["oldest_outstanding_at"]
                let nextRetryAt: String? = row["next_retry_at"]
                if let oldestOutstandingAt {
                    try Self.validateTimestamp(
                        oldestOutstandingAt,
                        field: "oldestOutstandingAt"
                    )
                }
                if let nextRetryAt {
                    try Self.validateTimestamp(nextRetryAt, field: "nextRetryAt")
                }
                replicaCounts[replicaID] = ArchiveReplicaStatusCounts(
                    pending: row["pending_count"],
                    inflight: row["inflight_count"],
                    retry: row["retry_count"],
                    quarantine: row["quarantine_count"],
                    verified: row["verified_count"],
                    oldestOutstandingAt: oldestOutstandingAt,
                    nextRetryAt: nextRetryAt,
                    retryReasons: retryReasons[replicaID] ?? []
                )
            }

            let durability = try Row.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(verified_count = 1), 0) AS single_count,
                       COALESCE(SUM(verified_count = 2), 0) AS dual_count
                FROM (
                    SELECT manifest_sha256, COUNT(*) AS verified_count
                    FROM archive_replica_receipts
                    WHERE replica_id IN ('hq', 'm1') AND state = 'verified'
                    GROUP BY manifest_sha256
                )
                """
            )!

            var latestReceipts: [ArchiveStatusReceiptSummary] = []
            for replicaID in Self.currentReplicaIDs {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT manifest_sha256, capture_id, receipt_bytes,
                           receipt_sha256, verified_at
                    FROM archive_replica_receipts
                    WHERE replica_id = ? AND state = 'verified'
                    ORDER BY verified_at DESC, manifest_sha256 DESC
                    LIMIT 1
                    """,
                    arguments: [replicaID]
                ) else {
                    continue
                }
                let manifestSHA256: String = row["manifest_sha256"]
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
                let captureID: String = row["capture_id"]
                guard captureID == binding.captureID else {
                    throw ArchiveCatalogError.bindingConflict(
                        manifestSHA256: manifestSHA256
                    )
                }
                guard let bytes: Data = row["receipt_bytes"],
                      let receiptSHA256: String = row["receipt_sha256"],
                      let verifiedAt: String = row["verified_at"] else {
                    throw ArchiveCatalogError.receiptRequired
                }
                let receipt = ArchiveVerifiedReceipt(
                    canonicalBytes: bytes,
                    sha256: receiptSHA256,
                    verifiedAt: verifiedAt
                )
                try Self.validate(
                    receipt: receipt,
                    replicaID: replicaID,
                    boundManifestBytes: binding.canonicalManifestBytes
                )
                let decoded = try ArchiveCanonicalJSON.decode(
                    ArchiveServerReceipt.self,
                    from: bytes
                )
                latestReceipts.append(
                    ArchiveStatusReceiptSummary(
                        replicaID: replicaID,
                        manifestSHA256: manifestSHA256,
                        captureID: captureID,
                        receiptSHA256: receiptSHA256,
                        storedAt: decoded.storedAt,
                        verifiedAt: verifiedAt
                    )
                )
            }
            let zeroCounts = ArchiveReplicaStatusCounts(
                pending: 0,
                inflight: 0,
                retry: 0,
                quarantine: 0,
                verified: 0
            )
            return ArchiveStatusAggregate(
                captured: captured,
                bound: eligibility["bound"],
                unbound: unbound,
                ignoredEmpty: ignoredEmpty,
                unknown: eligibility["unknown_count"],
                eligible: eligibility["eligible_count"],
                excluded: eligibility["excluded_count"],
                hq: replicaCounts["hq"] ?? zeroCounts,
                m1: replicaCounts["m1"] ?? zeroCounts,
                singleVerified: durability["single_count"],
                dualVerified: durability["dual_count"],
                latestReceipts: latestReceipts
            )
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

    private static func localResidency(_ raw: String) throws -> ArchiveLocalResidency {
        guard let value = ArchiveLocalResidency(rawValue: raw) else {
            throw ArchiveCatalogError.boundManifestMismatch(field: "localObject.residency")
        }
        return value
    }

    private static func reclamationIntent(from row: Row) throws -> ArchiveReclamationIntent {
        let rawPhase: String = row["phase"]
        guard let phase = ArchiveReclamationPhase(rawValue: rawPhase) else {
            throw ArchiveCatalogError.boundManifestMismatch(field: "reclamation.phase")
        }
        return ArchiveReclamationIntent(
            manifestSHA256: row["manifest_sha256"],
            captureID: row["capture_id"],
            sessionID: row["session_id"],
            locator: row["locator"],
            phase: phase,
            quarantinePath: row["quarantine_path"],
            attempts: row["attempts"],
            releasedSourceBytes: row["released_source_bytes"],
            releasedCASBytes: row["released_cas_bytes"],
            lastError: row["last_error"],
            claimGeneration: row["claim_generation"],
            updatedAt: row["updated_at"]
        )
    }

    private static func isAllowedReclamationTransition(
        from: ArchiveReclamationPhase,
        to: ArchiveReclamationPhase
    ) -> Bool {
        switch (from, to) {
        case (.eligible, .quarantinePlanned),
             (.quarantinePlanned, .sourceQuarantined),
             (.sourceQuarantined, .sourceDeletePlanned),
             (.sourceDeletePlanned, .sourceDeleted),
             (.sourceDeleted, .localContentEvicted),
             (.eligible, .paused),
             (.quarantinePlanned, .paused),
             (.sourceQuarantined, .paused),
             (.sourceDeletePlanned, .paused),
             (.paused, .eligible):
            true
        default:
            false
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

    private static func archiveCursorCheckpoint(
        from storedValue: String,
        expectedKey: ArchiveCursorKey
    ) throws -> ArchiveCursorCheckpoint {
        do {
            let bytes = Data(storedValue.utf8)
            let envelope = try ArchiveCanonicalJSON.decode(
                ArchiveCursorEnvelope.self,
                from: bytes
            )
            guard envelope.schemaVersion == 1,
                  envelope.key == expectedKey.rawValue,
                  (1 ... maximumArchiveCursorPayloadBytes).contains(envelope.payload.count),
                  ArchiveV2Hash.isValidSHA256(envelope.payloadSHA256),
                  ArchiveV2Hash.sha256(envelope.payload) == envelope.payloadSHA256,
                  try ArchiveCanonicalJSON.encode(envelope) == bytes else {
                throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(
                    expectedKey.rawValue
                )
            }
            try validateTimestamp(
                envelope.updatedAt,
                field: "archiveCursor.updatedAt"
            )
            return ArchiveCursorCheckpoint(
                payload: envelope.payload,
                payloadSHA256: envelope.payloadSHA256,
                updatedAt: envelope.updatedAt
            )
        } catch {
            throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(
                expectedKey.rawValue
            )
        }
    }

    private static func archiveCursorStoredValue(
        payload: Data,
        key: ArchiveCursorKey,
        updatedAt: String
    ) throws -> String {
        guard (1 ... maximumArchiveCursorPayloadBytes).contains(payload.count) else {
            throw ArchiveCatalogError.invalidArchiveCursorPayloadSize(payload.count)
        }
        try validateTimestamp(updatedAt, field: "archiveCursor.updatedAt")
        let envelope = ArchiveCursorEnvelope(
            schemaVersion: 1,
            key: key.rawValue,
            payload: payload,
            payloadSHA256: ArchiveV2Hash.sha256(payload),
            updatedAt: updatedAt
        )
        let canonicalBytes = try ArchiveCanonicalJSON.encode(envelope)
        guard let storedValue = String(data: canonicalBytes, encoding: .utf8) else {
            throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(key.rawValue)
        }
        _ = try archiveCursorCheckpoint(from: storedValue, expectedKey: key)
        return storedValue
    }

    private static func upsertArchiveCursorCheckpoint(
        storedValue: String,
        payload: Data,
        key: ArchiveCursorKey,
        db: Database
    ) throws -> Bool {
        if let existingValue = try String.fetchOne(
            db,
            sql: "SELECT value FROM archive_metadata WHERE key = ?",
            arguments: [key.rawValue]
        ) {
            let existing = try archiveCursorCheckpoint(
                from: existingValue,
                expectedKey: key
            )
            guard existing.payload != payload else { return false }
            guard existingValue != storedValue else { return false }
            try db.execute(
                sql: "UPDATE archive_metadata SET value = ? WHERE key = ?",
                arguments: [storedValue, key.rawValue]
            )
        } else {
            try db.execute(
                sql: "INSERT INTO archive_metadata(key, value) VALUES (?, ?)",
                arguments: [key.rawValue, storedValue]
            )
        }
        return true
    }

    private static func recoveryDrillCursorKey(replicaID: String) throws -> ArchiveCursorKey {
        switch replicaID {
        case "hq": .recoveryDrillHQ
        case "m1": .recoveryDrillM1
        default: throw ArchiveCatalogError.invalidReplicaID
        }
    }

    private static func recoveryDrillCursorValue(
        replicaID: String,
        manifestSHA256: String,
        updatedAt: String
    ) throws -> (key: ArchiveCursorKey, value: String) {
        let key = try recoveryDrillCursorKey(replicaID: replicaID)
        guard ArchiveV2Hash.isValidSHA256(manifestSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "manifestSHA256")
        }
        try validateTimestamp(updatedAt, field: "updatedAt")
        let payload = Data(manifestSHA256.utf8)
        let envelope = ArchiveCursorEnvelope(
            schemaVersion: 1,
            key: key.rawValue,
            payload: payload,
            payloadSHA256: ArchiveV2Hash.sha256(payload),
            updatedAt: updatedAt
        )
        let bytes = try ArchiveCanonicalJSON.encode(envelope)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(key.rawValue)
        }
        return (key, value)
    }

    private static func requireVerifiedRecoveryCandidate(
        db: Database,
        replicaID: String,
        manifestSHA256: String
    ) throws {
        guard try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM archive_session_bindings AS b
                JOIN archive_replica_receipts AS r
                  ON r.manifest_sha256 = b.manifest_sha256
                 AND r.replica_id = ?
                WHERE b.manifest_sha256 = ?
                  AND b.remote_eligibility = 'eligible'
                  AND r.state = 'verified'
                  AND r.receipt_bytes IS NOT NULL
            )
            """,
            arguments: [replicaID, manifestSHA256]
        ) == true else {
            throw ArchiveCatalogError.bindingNotFound(manifestSHA256: manifestSHA256)
        }
    }

    private static func storeRecoveryDrillCursor(
        _ cursor: (key: ArchiveCursorKey, value: String),
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO archive_metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [cursor.key.rawValue, cursor.value]
        )
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

    private static func validateBindingCursor(
        _ cursor: ArchiveBindingCursor,
        fieldPrefix: String
    ) throws {
        try validateTimestamp(
            cursor.boundAt,
            field: "\(fieldPrefix).boundAt"
        )
        guard ArchiveV2Hash.isValidSHA256(cursor.manifestSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(
                field: "\(fieldPrefix).manifestSHA256"
            )
        }
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
