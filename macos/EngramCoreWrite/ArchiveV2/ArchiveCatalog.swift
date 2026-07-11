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

public struct ArchiveBinding: Equatable, Sendable {
    public let manifestSHA256: String
    public let sessionID: String
    public let captureID: String
    public let sourceSnapshotFingerprint: String
    public let canonicalManifestBytes: Data
    public let boundAt: String
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
}

/// Rebuildable archive metadata isolated from Engram's product index database.
/// The immutable byte authority remains `ImmutableArchiveCAS`.
public final class ArchiveCatalog: @unchecked Sendable {
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
                let existing = Self.binding(from: existingRow)
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
                let existing = Self.binding(from: existingRow)
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
            ).map(Self.binding(from:))
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

    public func upsertReplicaState(
        manifestSHA256: String,
        replicaID: String,
        state: ArchiveReplicaState,
        attempts: Int = 0,
        nextRetryAt: String? = nil,
        lastError: String? = nil,
        receipt: ArchiveVerifiedReceipt? = nil,
        updatedAt: String? = nil
    ) throws {
        guard ArchiveV2Hash.isValidSHA256(manifestSHA256) else {
            throw ArchiveCatalogError.invalidSHA256(field: "manifestSHA256")
        }
        guard !replicaID.isEmpty else {
            throw ArchiveCatalogError.invalidReplicaID
        }
        guard attempts >= 0 else {
            throw ArchiveCatalogError.invalidAttempts(attempts)
        }
        if state == .verified, receipt == nil {
            throw ArchiveCatalogError.receiptRequired
        }
        if state != .verified, receipt != nil {
            throw ArchiveCatalogError.unexpectedReceipt
        }
        let resolvedUpdatedAt = updatedAt ?? Self.currentTimestamp()
        try Self.validateTimestamp(resolvedUpdatedAt, field: "updatedAt")
        if let nextRetryAt {
            try Self.validateTimestamp(nextRetryAt, field: "nextRetryAt")
        }

        try pool.write { db in
            guard let bindingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM archive_session_bindings WHERE manifest_sha256 = ?",
                arguments: [manifestSHA256]
            ) else {
                throw ArchiveCatalogError.bindingNotFound(
                    manifestSHA256: manifestSHA256
                )
            }
            let binding = Self.binding(from: bindingRow)
            if let receipt {
                try Self.validate(
                    receipt: receipt,
                    replicaID: replicaID,
                    boundManifestBytes: binding.canonicalManifestBytes
                )
            }

            let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT receipt_bytes, receipt_sha256, verified_at
                FROM archive_replica_receipts
                WHERE manifest_sha256 = ? AND replica_id = ?
                """,
                arguments: [manifestSHA256, replicaID]
            )
            let existingReceiptBytes: Data? = existing?["receipt_bytes"]
            let existingReceiptSHA256: String? = existing?["receipt_sha256"]
            let existingVerifiedAt: String? = existing?["verified_at"]

            if let existingReceiptBytes {
                guard let receipt,
                      existingReceiptBytes == receipt.canonicalBytes,
                      existingReceiptSHA256 == receipt.sha256 else {
                    throw ArchiveCatalogError.receiptConflict(
                        manifestSHA256: manifestSHA256,
                        replicaID: replicaID
                    )
                }
            }

            let receiptBytes = existingReceiptBytes ?? receipt?.canonicalBytes
            let receiptSHA256 = existingReceiptSHA256 ?? receipt?.sha256
            let verifiedAt = existingVerifiedAt ?? receipt?.verifiedAt

            try db.execute(
                sql: """
                INSERT INTO archive_replica_receipts(
                    manifest_sha256, capture_id, replica_id, state, attempts,
                    next_retry_at, last_error,
                    receipt_bytes, receipt_sha256, verified_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(manifest_sha256, replica_id) DO UPDATE SET
                    state = excluded.state,
                    attempts = excluded.attempts,
                    next_retry_at = excluded.next_retry_at,
                    last_error = excluded.last_error,
                    receipt_bytes = excluded.receipt_bytes,
                    receipt_sha256 = excluded.receipt_sha256,
                    verified_at = excluded.verified_at,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    manifestSHA256,
                    binding.captureID,
                    replicaID,
                    state.rawValue,
                    attempts,
                    nextRetryAt,
                    lastError,
                    receiptBytes,
                    receiptSHA256,
                    verifiedAt,
                    resolvedUpdatedAt,
                ]
            )
        }
        try secureDatabaseFiles()
    }

    public func pendingReplicaWork(
        limit: Int,
        now: String
    ) throws -> [ArchiveReplicaWork] {
        guard limit > 0 else {
            throw ArchiveCatalogError.invalidLimit(limit)
        }
        try Self.validateTimestamp(now, field: "now")
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT manifest_sha256, capture_id, replica_id, state,
                       attempts, next_retry_at, last_error
                FROM archive_replica_receipts
                WHERE state = 'pending'
                   OR (state = 'retryWait' AND (next_retry_at IS NULL OR next_retry_at <= ?))
                ORDER BY updated_at ASC, manifest_sha256 ASC, replica_id ASC
                LIMIT ?
                """,
                arguments: [now, limit]
            )
            return try rows.map(Self.replicaWork(from:))
        }
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
                SET state = 'pending', next_retry_at = NULL, updated_at = ?
                WHERE state IN (
                    'uploadingObjects',
                    'uploadingManifest',
                    'requestingReceipt',
                    'verifyingReceipt'
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

    private static func binding(from row: Row) -> ArchiveBinding {
        ArchiveBinding(
            manifestSHA256: row["manifest_sha256"],
            sessionID: row["session_id"],
            captureID: row["capture_id"],
            sourceSnapshotFingerprint: row["source_snapshot_fingerprint"],
            canonicalManifestBytes: row["bound_manifest_bytes"],
            boundAt: row["bound_at"]
        )
    }

    private static func replicaWork(from row: Row) throws -> ArchiveReplicaWork {
        let rawState: String = row["state"]
        guard let state = ArchiveReplicaState(rawValue: rawState) else {
            throw ArchiveCatalogError.invalidReplicaState(rawState)
        }
        return ArchiveReplicaWork(
            manifestSHA256: row["manifest_sha256"],
            captureID: row["capture_id"],
            replicaID: row["replica_id"],
            state: state,
            attempts: row["attempts"],
            nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"]
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
