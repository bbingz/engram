import Darwin
import CSQLite
import EngramCoreRead
@testable import EngramCoreWrite
import GRDB
import XCTest

final class ArchiveCatalogTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-archive-catalog-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testSQLiteHasMovedControlIsAvailableThroughGRDBConnection() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("probe.sqlite").path)
        try queue.read { db in
            var hasMoved: CInt = -1
            let result = withUnsafeMutablePointer(to: &hasMoved) { pointer in
                sqlite3_file_control(
                    db.sqliteConnection,
                    "main",
                    SQLITE_FCNTL_HAS_MOVED,
                    pointer
                )
            }
            XCTAssertEqual(result, SQLITE_OK)
            XCTAssertEqual(hasMoved, 0)
        }
    }

    func testMigrationCreatesOnlyFourArchiveTablesWithFullDurability() throws {
        let catalog = try ArchiveCatalog(root: root, machineID: machineID)
        try catalog.migrate()
        try catalog.migrate()

        let values = try readArchiveDatabase { db -> ([String], String, String) in
            let tables = try String.fetchAll(
                db,
                sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """
            )
            return (
                tables,
                (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "").lowercased(),
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM archive_metadata WHERE key = 'machine_id'"
                ) ?? ""
            )
        }

        XCTAssertEqual(values.0, [
            "archive_captures",
            "archive_metadata",
            "archive_replica_receipts",
            "archive_session_bindings",
        ])
        XCTAssertEqual(values.1, "wal")
        XCTAssertEqual(try catalog.configuredSynchronousMode(), 2)
        XCTAssertEqual(values.2, machineID)
        XCTAssertEqual(try catalog.machineID(), machineID)
        XCTAssertEqual(try permissions(root.path), 0o700)
        XCTAssertEqual(try permissions(root.appendingPathComponent("archive.sqlite").path), 0o600)
    }

    func testGeneratedMachineIDPersistsAcrossCatalogInstances() throws {
        let first = try ArchiveCatalog(root: root)
        try first.migrate()
        let firstID = try first.machineID()
        XCTAssertNotNil(UUID(uuidString: firstID))

        let reopened = try ArchiveCatalog(root: root)
        try reopened.migrate()
        XCTAssertEqual(try reopened.machineID(), firstID)
    }

    func testRecordCaptureRequiresCanonicalUnboundManifestAndIsIdempotent() throws {
        let catalog = try migratedCatalog()
        let unbound = try manifest(captureSeed: "capture-1", sessionID: nil)
        let bytes = try ArchiveCanonicalJSON.encode(unbound)

        let first = try catalog.recordCapture(canonicalManifestBytes: bytes)
        let second = try catalog.recordCapture(canonicalManifestBytes: bytes)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.captureID, unbound.captureID)
        XCTAssertEqual(first.unboundManifestSHA256, ArchiveV2Hash.sha256(bytes))

        let bound = try manifest(captureSeed: "capture-bound", sessionID: "session-1")
        XCTAssertThrowsError(
            try catalog.recordCapture(
                canonicalManifestBytes: ArchiveCanonicalJSON.encode(bound)
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveCatalogError, .captureManifestMustBeUnbound)
        }

        var nonCanonical = Data([0x20])
        nonCanonical.append(bytes)
        XCTAssertThrowsError(try catalog.recordCapture(canonicalManifestBytes: nonCanonical))
    }

    func testRecordCaptureRejectsChangedImmutableFieldsForSameCaptureID() throws {
        let catalog = try migratedCatalog()
        let original = try manifest(captureSeed: "stable-id", sessionID: nil)
        let changed = try manifest(
            captureSeed: "stable-id",
            sessionID: nil,
            locator: "/tmp/changed.jsonl"
        )
        _ = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(original)
        )

        XCTAssertThrowsError(
            try catalog.recordCapture(
                canonicalManifestBytes: ArchiveCanonicalJSON.encode(changed)
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .captureConflict(captureID: original.captureID)
            )
        }
    }

    func testBindRequiresMatchingCaptureAndPreservesHistoricalGenerations() throws {
        let catalog = try migratedCatalog()
        let capture1 = try manifest(captureSeed: "generation-1", sessionID: nil)
        let capture2 = try manifest(
            captureSeed: "generation-2",
            sessionID: nil,
            locator: "/tmp/source-v2.jsonl",
            capturedAt: "2026-07-11T00:02:00.000Z"
        )
        _ = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(capture1)
        )
        _ = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(capture2)
        )

        let bound1 = try manifest(captureSeed: "generation-1", sessionID: "session-1")
        let bound2 = try manifest(
            captureSeed: "generation-2",
            sessionID: "session-1",
            locator: "/tmp/source-v2.jsonl",
            capturedAt: "2026-07-11T00:02:00.000Z"
        )
        let first = try catalog.bind(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(bound1),
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot-1".utf8)),
            boundAt: "2026-07-11T00:03:00.000Z"
        )
        let second = try catalog.bind(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(bound2),
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot-2".utf8)),
            boundAt: "2026-07-11T00:04:00.000Z"
        )

        XCTAssertNotEqual(first.manifestSHA256, second.manifestSHA256)
        XCTAssertEqual(try catalog.latestBinding(sessionID: "session-1"), second)
        let historyCount = try readArchiveDatabase { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM archive_session_bindings WHERE session_id = ?",
                arguments: ["session-1"]
            ) ?? 0
        }
        XCTAssertEqual(historyCount, 2)

        XCTAssertThrowsError(
            try catalog.bind(
                canonicalManifestBytes: ArchiveCanonicalJSON.encode(capture1),
                sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot".utf8))
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveCatalogError, .boundManifestRequiresSessionID)
        }

        let mismatched = try manifest(
            captureSeed: "generation-1",
            sessionID: "session-1",
            locator: "/tmp/not-the-captured-locator.jsonl"
        )
        XCTAssertThrowsError(
            try catalog.bind(
                canonicalManifestBytes: ArchiveCanonicalJSON.encode(mismatched),
                sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot".utf8))
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .boundManifestMismatch(field: "locator")
            )
        }
    }

    func testRepeatIdenticalBindWithoutExplicitTimestampIsIdempotent() throws {
        let catalog = try migratedCatalog()
        let unbound = try manifest(captureSeed: "idempotent-bind", sessionID: nil)
        _ = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(unbound)
        )
        let bound = try manifest(
            captureSeed: "idempotent-bind",
            sessionID: "session-1"
        )
        let bytes = try ArchiveCanonicalJSON.encode(bound)
        let fingerprint = ArchiveV2Hash.sha256(Data("snapshot".utf8))

        let first = try catalog.bind(
            canonicalManifestBytes: bytes,
            sourceSnapshotFingerprint: fingerprint
        )
        Thread.sleep(forTimeInterval: 0.02)
        let second = try catalog.bind(
            canonicalManifestBytes: bytes,
            sourceSnapshotFingerprint: fingerprint
        )

        XCTAssertEqual(second, first)
    }

    func testCaptureCanBindOnlyOnceWhileSessionHistoryRemainsAllowed() throws {
        let catalog = try migratedCatalog()
        let unbound = try manifest(captureSeed: "single-binding", sessionID: nil)
        _ = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(unbound)
        )
        let first = try manifest(
            captureSeed: "single-binding",
            sessionID: "session-1"
        )
        _ = try catalog.bind(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(first),
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot".utf8)),
            boundAt: "2026-07-11T00:03:00.000Z"
        )

        let second = try manifest(
            captureSeed: "single-binding",
            sessionID: "session-2"
        )
        XCTAssertThrowsError(
            try catalog.bind(
                canonicalManifestBytes: ArchiveCanonicalJSON.encode(second),
                sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot".utf8)),
                boundAt: "2026-07-11T00:04:00.000Z"
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .captureAlreadyBound(
                    captureID: unbound.captureID,
                    existingSessionID: "session-1"
                )
            )
        }

        let uniqueIndex = try readArchiveDatabase { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT sql FROM sqlite_master
                WHERE type = 'index'
                  AND name = 'archive_session_bindings_capture_unique'
                """
            )
        }
        XCTAssertTrue(uniqueIndex?.contains("UNIQUE") == true)
    }

    func testReplicaStatesAreIndependentByManifestAndReplica() throws {
        let (catalog, manifestBytes, binding) = try boundCatalog()
        try catalog.upsertReplicaState(
            manifestSHA256: binding.manifestSHA256,
            replicaID: "hq",
            state: .uploadingObjects,
            attempts: 1,
            updatedAt: "2026-07-11T00:00:00.000Z"
        )
        try catalog.upsertReplicaState(
            manifestSHA256: binding.manifestSHA256,
            replicaID: "m1",
            state: .pending,
            updatedAt: "2026-07-11T00:00:00.000Z"
        )

        let receipt = try receiptBytes(
            serverID: "hq",
            manifestBytes: manifestBytes
        )
        try catalog.upsertReplicaState(
            manifestSHA256: binding.manifestSHA256,
            replicaID: "hq",
            state: .verified,
            attempts: 1,
            receipt: ArchiveVerifiedReceipt(
                canonicalBytes: receipt,
                sha256: ArchiveV2Hash.sha256(receipt),
                verifiedAt: "2026-07-11T00:05:00.000Z"
            ),
            updatedAt: "2026-07-11T00:05:00.000Z"
        )

        let pending = try catalog.pendingReplicaWork(
            limit: 10,
            now: "2026-07-11T00:06:00.000Z"
        )
        XCTAssertEqual(pending.map(\.replicaID), ["m1"])
        XCTAssertEqual(pending.first?.manifestSHA256, binding.manifestSHA256)
    }

    func testVerifiedReceiptIsAtomicAndConflictingSecondReceiptIsRejected() throws {
        let (catalog, manifestBytes, binding) = try boundCatalog()
        let firstBytes = try receiptBytes(serverID: "hq", manifestBytes: manifestBytes)
        let first = ArchiveVerifiedReceipt(
            canonicalBytes: firstBytes,
            sha256: ArchiveV2Hash.sha256(firstBytes),
            verifiedAt: "2026-07-11T00:05:00.000Z"
        )
        try catalog.upsertReplicaState(
            manifestSHA256: binding.manifestSHA256,
            replicaID: "hq",
            state: .verified,
            receipt: first,
            updatedAt: "2026-07-11T00:05:00.000Z"
        )
        try catalog.upsertReplicaState(
            manifestSHA256: binding.manifestSHA256,
            replicaID: "hq",
            state: .verified,
            receipt: first,
            updatedAt: "2026-07-11T00:05:00.000Z"
        )

        let conflictingBytes = try receiptBytes(
            serverID: "hq",
            manifestBytes: manifestBytes,
            storedAt: "2026-07-11T00:07:00.000Z"
        )
        XCTAssertThrowsError(
            try catalog.upsertReplicaState(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "hq",
                state: .verified,
                receipt: ArchiveVerifiedReceipt(
                    canonicalBytes: conflictingBytes,
                    sha256: ArchiveV2Hash.sha256(conflictingBytes),
                    verifiedAt: "2026-07-11T00:07:00.000Z"
                ),
                updatedAt: "2026-07-11T00:07:00.000Z"
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .receiptConflict(
                    manifestSHA256: binding.manifestSHA256,
                    replicaID: "hq"
                )
            )
        }

        let stored = try readArchiveDatabase { db -> (Data?, String?, String?) in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT receipt_bytes, receipt_sha256, verified_at
                FROM archive_replica_receipts
                WHERE manifest_sha256 = ? AND replica_id = 'hq'
                """,
                arguments: [binding.manifestSHA256]
            ) else {
                return (nil, nil, nil)
            }
            return (row["receipt_bytes"], row["receipt_sha256"], row["verified_at"])
        }
        XCTAssertEqual(stored.0, first.canonicalBytes)
        XCTAssertEqual(stored.1, first.sha256)
        XCTAssertEqual(stored.2, first.verifiedAt)
    }

    func testReplicaTimestampsMustBeCanonicalBeforePersistence() throws {
        let (catalog, manifestBytes, binding) = try boundCatalog()
        XCTAssertThrowsError(
            try catalog.upsertReplicaState(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "bad-updated",
                state: .pending,
                updatedAt: "not-a-timestamp"
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidTimestamp(field: "updatedAt", value: "not-a-timestamp")
            )
        }
        XCTAssertThrowsError(
            try catalog.upsertReplicaState(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "bad-retry",
                state: .retryWait,
                nextRetryAt: "2026-07-11 00:10:00",
                updatedAt: "2026-07-11T00:00:00.000Z"
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidTimestamp(
                    field: "nextRetryAt",
                    value: "2026-07-11 00:10:00"
                )
            )
        }

        let receipt = try receiptBytes(serverID: "hq", manifestBytes: manifestBytes)
        XCTAssertThrowsError(
            try catalog.upsertReplicaState(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "hq",
                state: .verified,
                receipt: ArchiveVerifiedReceipt(
                    canonicalBytes: receipt,
                    sha256: ArchiveV2Hash.sha256(receipt),
                    verifiedAt: "2026-07-11T00:05:00Z"
                ),
                updatedAt: "2026-07-11T00:05:00.000Z"
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidTimestamp(
                    field: "verifiedAt",
                    value: "2026-07-11T00:05:00Z"
                )
            )
        }

        let count = try readArchiveDatabase { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM archive_replica_receipts") ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    func testStaleInflightRecoveryResetsOnlyWorkOlderThanTenMinutes() throws {
        let (catalog, _, binding) = try boundCatalog()
        try catalog.upsertReplicaState(
            manifestSHA256: binding.manifestSHA256,
            replicaID: "hq",
            state: .uploadingManifest,
            updatedAt: "2026-07-11T00:00:00.000Z"
        )
        try catalog.upsertReplicaState(
            manifestSHA256: binding.manifestSHA256,
            replicaID: "m1",
            state: .requestingReceipt,
            updatedAt: "2026-07-11T00:11:00.000Z"
        )

        XCTAssertEqual(
            try catalog.recoverStaleInflight(
                now: "2026-07-11T00:12:00.000Z",
                olderThanSeconds: 600
            ),
            1
        )
        let states = try readArchiveDatabase { db -> [String: String] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT replica_id, state FROM archive_replica_receipts"
            )
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["replica_id"] as String, $0["state"] as String)
            })
        }
        XCTAssertEqual(states["hq"], ArchiveReplicaState.pending.rawValue)
        XCTAssertEqual(states["m1"], ArchiveReplicaState.requestingReceipt.rawValue)
    }

    func testArchiveMigrationNeverTouchesSeparateIndexDatabase() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let indexPath = root.appendingPathComponent("index.sqlite").path
        let index = try DatabaseQueue(path: indexPath)
        try index.write { db in
            try db.execute(sql: "CREATE TABLE sentinel(id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO sentinel(id) VALUES ('kept')")
        }

        let catalog = try ArchiveCatalog(root: root, machineID: machineID)
        try catalog.migrate()

        let indexTables = try index.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
        XCTAssertTrue(indexTables.contains("sentinel"))
        XCTAssertFalse(indexTables.contains { $0.hasPrefix("archive_") })
        XCTAssertEqual(
            try index.read { db in
                try String.fetchOne(db, sql: "SELECT id FROM sentinel")
            },
            "kept"
        )
    }

    func testCatalogRejectsSymlinkAndNonRegularDatabasePathsBeforeOpening() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let databaseURL = root.appendingPathComponent("archive.sqlite")
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-archive-outside-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        do {
            let outside = try DatabaseQueue(path: outsideURL.path)
            try outside.write { db in
                try db.execute(sql: "CREATE TABLE sentinel(id TEXT PRIMARY KEY)")
            }
        }
        try FileManager.default.createSymbolicLink(
            atPath: databaseURL.path,
            withDestinationPath: outsideURL.path
        )

        XCTAssertThrowsError(try ArchiveCatalog(root: root, machineID: machineID)) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .unsafeDatabasePath(databaseURL.path)
            )
        }

        try FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ArchiveCatalog(root: root, machineID: machineID)) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .unsafeDatabasePath(databaseURL.path)
            )
        }
    }

    func testCatalogRejectsHardLinkedDatabaseAliasBeforeOpening() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let indexURL = root.appendingPathComponent("index.sqlite")
        do {
            let index = try DatabaseQueue(path: indexURL.path)
            try index.write { db in
                try db.execute(sql: "CREATE TABLE sentinel(id TEXT PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO sentinel(id) VALUES ('kept')")
            }
        }
        let archiveURL = root.appendingPathComponent("archive.sqlite")
        XCTAssertEqual(link(indexURL.path, archiveURL.path), 0)

        XCTAssertThrowsError(try ArchiveCatalog(root: root, machineID: machineID)) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .unsafeDatabasePath(archiveURL.path)
            )
        }

        let index = try DatabaseQueue(path: indexURL.path)
        let tables = try index.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
        XCTAssertTrue(tables.contains("sentinel"))
        XCTAssertFalse(tables.contains { $0.hasPrefix("archive_") })
    }

    func testCatalogRejectsSymlinkInsertedBetweenPreflightAndPoolOpen() throws {
        let indexURL = try createProtectedIndexDatabase()
        let beforeBytes = try Data(contentsOf: indexURL)
        let beforeMode = try permissions(indexURL.path)
        let archiveURL = root.appendingPathComponent("archive.sqlite")
        let hooks = ArchiveCatalogTestHooks(
            afterDatabasePreflight: { databaseURL in
                guard unlink(databaseURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try FileManager.default.createSymbolicLink(
                    atPath: databaseURL.path,
                    withDestinationPath: indexURL.path
                )
            }
        )

        XCTAssertThrowsError(
            try ArchiveCatalog(root: root, machineID: machineID, testHooks: hooks)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .unsafeDatabasePath(archiveURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: indexURL), beforeBytes)
        XCTAssertEqual(try permissions(indexURL.path), beforeMode)
        try assertOnlySentinelTable(in: indexURL)
    }

    func testCatalogDetectsSwapBackAfterPoolOpenedDifferentInode() throws {
        let indexURL = try createProtectedIndexDatabase()
        let beforeBytes = try Data(contentsOf: indexURL)
        let beforeMode = try permissions(indexURL.path)
        let archiveURL = root.appendingPathComponent("archive.sqlite")
        let preflightBackup = root.appendingPathComponent("archive-preflight.sqlite")
        let hooks = ArchiveCatalogTestHooks(
            afterDatabasePreflight: { databaseURL in
                try FileManager.default.moveItem(at: databaseURL, to: preflightBackup)
                try FileManager.default.createSymbolicLink(
                    atPath: databaseURL.path,
                    withDestinationPath: indexURL.path
                )
            },
            beforeDatabaseIdentityValidation: { databaseURL in
                try FileManager.default.removeItem(at: databaseURL)
                try FileManager.default.moveItem(at: preflightBackup, to: databaseURL)
            }
        )

        XCTAssertThrowsError(
            try ArchiveCatalog(root: root, machineID: machineID, testHooks: hooks)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .unsafeDatabasePath(archiveURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: indexURL), beforeBytes)
        XCTAssertEqual(try permissions(indexURL.path), beforeMode)
        try assertOnlySentinelTable(in: indexURL)
    }

    private func migratedCatalog() throws -> ArchiveCatalog {
        let catalog = try ArchiveCatalog(root: root, machineID: machineID)
        try catalog.migrate()
        return catalog
    }

    private func boundCatalog() throws -> (
        ArchiveCatalog,
        manifestBytes: Data,
        binding: ArchiveBinding
    ) {
        let catalog = try migratedCatalog()
        let unbound = try manifest(captureSeed: "bound-capture", sessionID: nil)
        _ = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(unbound)
        )
        let bound = try manifest(captureSeed: "bound-capture", sessionID: "session-1")
        let bytes = try ArchiveCanonicalJSON.encode(bound)
        let binding = try catalog.bind(
            canonicalManifestBytes: bytes,
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot".utf8)),
            boundAt: "2026-07-11T00:04:00.000Z"
        )
        return (catalog, bytes, binding)
    }

    private func manifest(
        captureSeed: String,
        sessionID: String?,
        locator: String = "/tmp/source.jsonl",
        capturedAt: String = "2026-07-11T00:00:00.000Z"
    ) throws -> ArchiveSourceManifest {
        let raw = Data("hello".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        return try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data(captureSeed.utf8)),
            machineID: machineID,
            source: "codex",
            locator: locator,
            sessionID: sessionID,
            capturedAt: capturedAt,
            generation: ArchiveSourceGeneration(
                device: 1,
                inode: 2,
                size: Int64(raw.count),
                mtimeNs: 3,
                ctimeNs: 4,
                mode: Int64(S_IFREG | 0o600)
            ),
            wholeSourceSHA256: digest,
            rawByteCount: Int64(raw.count),
            chunks: [
                ArchiveChunkReference(
                    ordinal: 0,
                    rawSHA256: digest,
                    rawByteCount: Int64(raw.count)
                ),
            ],
            replayLayout: ArchiveReplayLayout(
                strategy: .singleFile,
                relativePaths: ["sessions/source.jsonl"]
            )
        )
    }

    private func receiptBytes(
        serverID: String,
        manifestBytes: Data,
        storedAt: String = "2026-07-11T00:05:00.000Z"
    ) throws -> Data {
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: manifestBytes
        )
        let receipt = try ArchiveServerReceipt(
            serverID: serverID,
            machineID: manifest.machineID,
            sessionID: try XCTUnwrap(manifest.sessionID),
            captureID: manifest.captureID,
            manifestSHA256: ArchiveV2Hash.sha256(manifestBytes),
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            objectCount: manifest.chunks.count,
            rawByteCount: manifest.rawByteCount,
            storedAt: storedAt
        )
        return try ArchiveCanonicalJSON.encode(receipt)
    }

    private func readArchiveDatabase<T>(_ body: (Database) throws -> T) throws -> T {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(
            path: root.appendingPathComponent("archive.sqlite").path,
            configuration: configuration
        )
        return try queue.read(body)
    }

    private func createProtectedIndexDatabase() throws -> URL {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let indexURL = root.appendingPathComponent("index.sqlite")
        do {
            let index = try DatabaseQueue(path: indexURL.path)
            try index.write { db in
                try db.execute(sql: "CREATE TABLE sentinel(id TEXT PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO sentinel(id) VALUES ('kept')")
            }
        }
        guard chmod(indexURL.path, 0o640) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return indexURL
    }

    private func assertOnlySentinelTable(in indexURL: URL) throws {
        let index = try DatabaseQueue(path: indexURL.path)
        let tables = try index.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """
            )
        }
        XCTAssertEqual(tables, ["sentinel"])
    }

    private func permissions(_ path: String) throws -> Int {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(info.st_mode & 0o777)
    }
}
