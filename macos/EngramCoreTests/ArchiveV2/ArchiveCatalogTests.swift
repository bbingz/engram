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

        let values = try readArchiveDatabase { db -> (
            tables: [String],
            journalMode: String,
            machineID: String,
            bindingColumns: [String],
            receiptColumns: [String],
            schemaVersion: String
        ) in
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
                ) ?? "",
                try Row.fetchAll(db, sql: "PRAGMA table_info(archive_session_bindings)")
                    .map { $0["name"] as String },
                try Row.fetchAll(db, sql: "PRAGMA table_info(archive_replica_receipts)")
                    .map { $0["name"] as String },
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM archive_metadata WHERE key = 'schema_version'"
                ) ?? ""
            )
        }

        XCTAssertEqual(values.tables, [
            "archive_captures",
            "archive_metadata",
            "archive_replica_receipts",
            "archive_session_bindings",
        ])
        XCTAssertEqual(values.journalMode, "wal")
        XCTAssertEqual(try catalog.configuredSynchronousMode(), 2)
        XCTAssertEqual(values.machineID, machineID)
        XCTAssertTrue(values.bindingColumns.contains("project_root_snapshot"))
        XCTAssertTrue(values.bindingColumns.contains("remote_eligibility"))
        XCTAssertTrue(values.receiptColumns.contains("claim_generation"))
        XCTAssertEqual(values.schemaVersion, "2")
        XCTAssertEqual(try catalog.machineID(), machineID)
        XCTAssertEqual(try permissions(root.path), 0o700)
        XCTAssertEqual(try permissions(root.appendingPathComponent("archive.sqlite").path), 0o600)
    }

    func testVersionOneMigrationAddsPolicyAndLeaseColumnsIdempotentlyAndFailsClosed() throws {
        let migratedManifestBytes = try createVersionOneCatalogWithBinding()
        let catalog = try ArchiveCatalog(root: root, machineID: machineID)

        try catalog.migrate()
        try catalog.migrate()

        let manifestSHA256 = ArchiveV2Hash.sha256(migratedManifestBytes)
        let migrated = try XCTUnwrap(try catalog.latestBinding(sessionID: "migrated-session"))
        XCTAssertEqual(migrated.manifestSHA256, manifestSHA256)
        XCTAssertNil(migrated.projectRootSnapshot)
        XCTAssertEqual(migrated.remoteEligibility, .unknown)
        XCTAssertEqual(
            try catalog.reconcileEligibleReplicaRows(
                updatedAt: "2026-07-11T00:10:00.000Z"
            ),
            0
        )
        XCTAssertEqual(try replicaRowCount(), 1)
        XCTAssertEqual(
            try catalog.claimReplicaWork(
                limit: 10,
                now: "2026-07-11T00:10:01.000Z"
            ),
            []
        )

        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: manifestSHA256,
                projectRootSnapshot: "/tmp/migrated-project",
                eligibility: .eligible
            )
        )
        XCTAssertEqual(
            try catalog.reconcileEligibleReplicaRows(
                updatedAt: "2026-07-11T00:11:00.000Z"
            ),
            1
        )
        XCTAssertEqual(try replicaIDs(manifestSHA256: manifestSHA256), ["hq", "m1"])
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

    func testRemotePolicySnapshotIsFailClosedOneWayAndRequiresNormalizedAbsoluteRoot() throws {
        let (catalog, _, binding) = try boundCatalog()

        XCTAssertNil(binding.projectRootSnapshot)
        XCTAssertEqual(binding.remoteEligibility, .unknown)
        XCTAssertEqual(
            try catalog.reconcileEligibleReplicaRows(
                updatedAt: "2026-07-11T00:05:00.000Z"
            ),
            0
        )
        XCTAssertThrowsError(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: binding.manifestSHA256,
                projectRootSnapshot: nil,
                eligibility: .unknown
            )
        )
        for invalidRoot in [nil, "relative/project", "/tmp/project/../other", "/tmp/a\u{0}b"] {
            XCTAssertThrowsError(
                try catalog.setRemotePolicySnapshot(
                    manifestSHA256: binding.manifestSHA256,
                    projectRootSnapshot: invalidRoot,
                    eligibility: .eligible
                )
            )
        }

        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: binding.manifestSHA256,
                projectRootSnapshot: "/tmp/project",
                eligibility: .eligible
            )
        )
        XCTAssertFalse(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: binding.manifestSHA256,
                projectRootSnapshot: "/tmp/project",
                eligibility: .eligible
            )
        )
        XCTAssertThrowsError(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: binding.manifestSHA256,
                projectRootSnapshot: nil,
                eligibility: .excluded
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .remotePolicyConflict(manifestSHA256: binding.manifestSHA256)
            )
        }

        let resolved = try XCTUnwrap(try catalog.latestBinding(sessionID: binding.sessionID))
        XCTAssertEqual(resolved.projectRootSnapshot, "/tmp/project")
        XCTAssertEqual(resolved.remoteEligibility, .eligible)

        let excluded = try addBinding(
            to: catalog,
            captureSeed: "excluded-policy",
            sessionID: "excluded-session"
        )
        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: excluded.manifestSHA256,
                projectRootSnapshot: nil,
                eligibility: .excluded
            )
        )
    }

    func testReconciliationSeedsOnlyEligibleBindingsForExactCurrentReplicas() throws {
        let (catalog, _, eligible) = try boundCatalog()
        let unknown = try addBinding(
            to: catalog,
            captureSeed: "unknown-binding",
            sessionID: "unknown-session"
        )
        let excluded = try addBinding(
            to: catalog,
            captureSeed: "excluded-binding",
            sessionID: "excluded-session"
        )
        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: eligible.manifestSHA256,
                projectRootSnapshot: "/tmp/eligible",
                eligibility: .eligible
            )
        )
        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: excluded.manifestSHA256,
                projectRootSnapshot: "/tmp/excluded",
                eligibility: .excluded
            )
        )

        XCTAssertEqual(
            try catalog.reconcileEligibleReplicaRows(
                updatedAt: "2026-07-11T00:05:00.000Z"
            ),
            2
        )
        XCTAssertEqual(
            try catalog.reconcileEligibleReplicaRows(
                updatedAt: "2026-07-11T00:06:00.000Z"
            ),
            0
        )
        XCTAssertEqual(try replicaIDs(manifestSHA256: eligible.manifestSHA256), ["hq", "m1"])
        XCTAssertEqual(try replicaIDs(manifestSHA256: unknown.manifestSHA256), [])
        XCTAssertEqual(try replicaIDs(manifestSHA256: excluded.manifestSHA256), [])
    }

    func testAtomicClaimCarriesExactBindingAndTwoCatalogInstancesCannotWinSameRow() async throws {
        let (catalog, manifestBytes, binding) = try eligibleBoundCatalog()
        let first = try XCTUnwrap(
            try catalog.claimReplicaWork(
                limit: 1,
                now: "2026-07-11T00:05:00.000Z"
            ).first
        )
        XCTAssertEqual(first.replicaID, "hq")
        XCTAssertEqual(first.manifestSHA256, binding.manifestSHA256)
        XCTAssertEqual(first.captureID, binding.captureID)
        XCTAssertEqual(first.sessionID, binding.sessionID)
        XCTAssertEqual(first.canonicalManifestBytes, manifestBytes)
        XCTAssertEqual(first.claimGeneration, 1)
        XCTAssertEqual(first.attempts, 0)

        let reopened = try ArchiveCatalog(root: root, machineID: machineID)
        try reopened.migrate()
        async let firstContender = Task.detached(priority: .userInitiated) {
            try catalog.claimReplicaWork(
                limit: 1,
                now: "2026-07-11T00:05:01.000Z"
            )
        }.value
        async let secondContender = Task.detached(priority: .userInitiated) {
            try reopened.claimReplicaWork(
                limit: 1,
                now: "2026-07-11T00:05:01.000Z"
            )
        }.value
        let racedClaims = try await firstContender + secondContender
        XCTAssertEqual(racedClaims.count, 1)
        XCTAssertEqual(racedClaims.first?.replicaID, "m1")
        XCTAssertEqual(racedClaims.first?.claimGeneration, 1)
    }

    func testTransitionsAndHeartbeatRequireExpectedStateAndGeneration() throws {
        let (catalog, _, _) = try eligibleBoundCatalog()
        let claim = try XCTUnwrap(
            try catalog.claimReplicaWork(
                limit: 1,
                now: "2026-07-11T00:00:00.000Z"
            ).first
        )

        XCTAssertFalse(
            try catalog.transitionReplicaClaim(
                claim,
                from: .uploadingObjects,
                to: .uploadingManifest,
                updatedAt: "2026-07-11T00:01:00.000Z",
                usingClaimGeneration: claim.claimGeneration + 1
            )
        )
        XCTAssertFalse(
            try catalog.transitionReplicaClaim(
                claim,
                from: .uploadingManifest,
                to: .requestingReceipt,
                updatedAt: "2026-07-11T00:01:00.000Z"
            )
        )
        XCTAssertThrowsError(
            try catalog.transitionReplicaClaim(
                claim,
                from: .uploadingObjects,
                to: .requestingReceipt,
                updatedAt: "2026-07-11T00:01:00.000Z"
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidReplicaTransition(
                    from: .uploadingObjects,
                    to: .requestingReceipt
                )
            )
        }
        XCTAssertTrue(
            try catalog.transitionReplicaClaim(
                claim,
                from: .uploadingObjects,
                to: .uploadingManifest,
                updatedAt: "2026-07-11T00:01:00.000Z"
            )
        )
        XCTAssertFalse(
            try catalog.heartbeatReplicaClaim(
                claim,
                state: .uploadingObjects,
                at: "2026-07-11T00:02:00.000Z"
            )
        )
        XCTAssertTrue(
            try catalog.heartbeatReplicaClaim(
                claim,
                state: .uploadingManifest,
                at: "2026-07-11T00:02:00.000Z"
            )
        )
        let state = try XCTUnwrap(
            try catalog.replicaWork(
                manifestSHA256: claim.manifestSHA256,
                replicaID: claim.replicaID
            )
        )
        XCTAssertEqual(state.state, .uploadingManifest)
        XCTAssertEqual(state.updatedAt, "2026-07-11T00:02:00.000Z")
        XCTAssertEqual(state.claimGeneration, claim.claimGeneration)
    }

    func testHeartbeatPreventsTenMinuteRecoveryAndRecoveryInvalidatesABAWorker() throws {
        let (catalog, manifestBytes, _) = try eligibleBoundCatalog()
        let claims = try catalog.claimReplicaWork(
            limit: 2,
            now: "2026-07-11T00:00:00.000Z"
        )
        let hq = try XCTUnwrap(claims.first { $0.replicaID == "hq" })
        let m1 = try XCTUnwrap(claims.first { $0.replicaID == "m1" })
        try advanceToVerifying(catalog, claim: hq)
        XCTAssertTrue(
            try catalog.heartbeatReplicaClaim(
                hq,
                state: .verifyingReceipt,
                at: "2026-07-11T00:09:00.000Z"
            )
        )
        XCTAssertTrue(
            try catalog.heartbeatReplicaClaim(
                m1,
                state: .uploadingObjects,
                at: "2026-07-11T00:19:00.000Z"
            )
        )
        XCTAssertEqual(
            try catalog.recoverStaleInflight(
                now: "2026-07-11T00:12:00.000Z",
                olderThanSeconds: 600
            ),
            0
        )
        XCTAssertEqual(
            try catalog.recoverStaleInflight(
                now: "2026-07-11T00:20:00.000Z",
                olderThanSeconds: 600
            ),
            1
        )
        let recovered = try XCTUnwrap(
            try catalog.replicaWork(
                manifestSHA256: hq.manifestSHA256,
                replicaID: "hq"
            )
        )
        XCTAssertEqual(recovered.state, .pending)
        XCTAssertEqual(recovered.claimGeneration, hq.claimGeneration + 1)

        XCTAssertFalse(
            try catalog.heartbeatReplicaClaim(
                hq,
                state: .verifyingReceipt,
                at: "2026-07-11T00:20:01.000Z"
            )
        )
        XCTAssertFalse(
            try catalog.markReplicaQuarantined(
                hq,
                from: .verifyingReceipt,
                lastError: "stale_worker",
                updatedAt: "2026-07-11T00:20:01.000Z"
            )
        )
        let staleReceiptBytes = try receiptBytes(
            serverID: "hq",
            manifestBytes: manifestBytes
        )
        XCTAssertFalse(
            try catalog.recordVerifiedReceipt(
                hq,
                receipt: ArchiveVerifiedReceipt(
                    canonicalBytes: staleReceiptBytes,
                    sha256: ArchiveV2Hash.sha256(staleReceiptBytes),
                    verifiedAt: "2026-07-11T00:20:01.000Z"
                ),
                updatedAt: "2026-07-11T00:20:01.000Z"
            )
        )
        let replacement = try XCTUnwrap(
            try catalog.claimReplicaWork(
                limit: 1,
                now: "2026-07-11T00:20:02.000Z"
            ).first
        )
        XCTAssertEqual(replacement.replicaID, "hq")
        XCTAssertEqual(replacement.claimGeneration, hq.claimGeneration + 2)
        XCTAssertTrue(
            try catalog.transitionReplicaClaim(
                replacement,
                from: .uploadingObjects,
                to: .uploadingManifest,
                updatedAt: "2026-07-11T00:20:03.000Z"
            )
        )
    }

    func testRetryAndQuarantineRequireCASAndBoundedSymbolicErrors() throws {
        let (catalog, _, _) = try eligibleBoundCatalog()
        let claims = try catalog.claimReplicaWork(
            limit: 2,
            now: "2026-07-11T00:00:00.000Z"
        )
        let hq = try XCTUnwrap(claims.first { $0.replicaID == "hq" })
        let m1 = try XCTUnwrap(claims.first { $0.replicaID == "m1" })

        for invalid in ["", "localized timeout", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(
                try catalog.markReplicaRetry(
                    hq,
                    from: .uploadingObjects,
                    nextRetryAt: "2026-07-11T00:02:00.000Z",
                    lastError: invalid,
                    updatedAt: "2026-07-11T00:01:00.000Z"
                )
            )
        }
        XCTAssertFalse(
            try catalog.markReplicaRetry(
                hq,
                from: .uploadingObjects,
                nextRetryAt: "2026-07-11T00:02:00.000Z",
                lastError: "timeout",
                updatedAt: "2026-07-11T00:01:00.000Z",
                usingClaimGeneration: hq.claimGeneration + 1
            )
        )
        XCTAssertTrue(
            try catalog.markReplicaRetry(
                hq,
                from: .uploadingObjects,
                nextRetryAt: "2026-07-11T00:02:00.000Z",
                lastError: "timeout",
                updatedAt: "2026-07-11T00:01:00.000Z"
            )
        )
        XCTAssertTrue(
            try catalog.markReplicaQuarantined(
                m1,
                from: .uploadingObjects,
                lastError: "receipt_conflict",
                updatedAt: "2026-07-11T00:01:00.000Z"
            )
        )

        let hqState = try XCTUnwrap(
            try catalog.replicaWork(
                manifestSHA256: hq.manifestSHA256,
                replicaID: "hq"
            )
        )
        let m1State = try XCTUnwrap(
            try catalog.replicaWork(
                manifestSHA256: m1.manifestSHA256,
                replicaID: "m1"
            )
        )
        XCTAssertEqual(hqState.state, .retryWait)
        XCTAssertEqual(hqState.attempts, 1)
        XCTAssertEqual(hqState.lastError, "timeout")
        XCTAssertEqual(m1State.state, .quarantined)
        XCTAssertEqual(m1State.attempts, 1)
        XCTAssertEqual(m1State.lastError, "receipt_conflict")
    }

    func testRetryAndQuarantineAttemptCountersSaturateAtSQLiteIntegerMax() throws {
        let (catalog, _, _) = try eligibleBoundCatalog()
        let claims = try catalog.claimReplicaWork(
            limit: 2,
            now: "2026-07-11T00:00:00.000Z"
        )
        let hq = try XCTUnwrap(claims.first { $0.replicaID == "hq" })
        let m1 = try XCTUnwrap(claims.first { $0.replicaID == "m1" })
        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET attempts = ?
                WHERE manifest_sha256 = ? AND replica_id IN ('hq', 'm1')
                """,
                arguments: [Int64.max, hq.manifestSHA256]
            )
        }

        XCTAssertTrue(
            try catalog.markReplicaRetry(
                hq,
                from: .uploadingObjects,
                nextRetryAt: "2026-07-11T00:02:00.000Z",
                lastError: "timeout",
                updatedAt: "2026-07-11T00:01:00.000Z"
            )
        )
        XCTAssertTrue(
            try catalog.markReplicaQuarantined(
                m1,
                from: .uploadingObjects,
                lastError: "protocol_contradiction",
                updatedAt: "2026-07-11T00:01:00.000Z"
            )
        )

        let stored = try readArchiveDatabase { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT replica_id, attempts, typeof(attempts) AS storage_type
                FROM archive_replica_receipts
                WHERE manifest_sha256 = ? AND replica_id IN ('hq', 'm1')
                ORDER BY replica_id
                """,
                arguments: [hq.manifestSHA256]
            ).map { row -> (String, String, Int64?) in
                let storageType: String = row["storage_type"]
                let attempts: Int64? = storageType == "integer" ? row["attempts"] : nil
                return (row["replica_id"], storageType, attempts)
            }
        }
        XCTAssertEqual(stored.map(\.0), ["hq", "m1"])
        XCTAssertEqual(stored.map(\.1), ["integer", "integer"])
        XCTAssertEqual(stored.compactMap(\.2), [Int64.max, Int64.max])
    }

    func testManualRetryOnlyTouchesSelectedCurrentQuarantinedRows() throws {
        let (catalog, _, binding) = try eligibleBoundCatalog()
        let claims = try catalog.claimReplicaWork(
            limit: 2,
            now: "2026-07-11T00:00:00.000Z"
        )
        for claim in claims {
            XCTAssertTrue(
                try catalog.markReplicaQuarantined(
                    claim,
                    from: .uploadingObjects,
                    lastError: "protocol_contradiction",
                    updatedAt: "2026-07-11T00:01:00.000Z"
                )
            )
        }
        try insertObsoleteReplicaRow(
            manifestSHA256: binding.manifestSHA256,
            captureID: binding.captureID,
            state: .quarantined,
            attempts: 9,
            claimGeneration: 7
        )

        XCTAssertEqual(
            try catalog.retryQuarantined(
                replicaID: "hq",
                now: "2026-07-11T00:02:00.000Z"
            ),
            1
        )
        let hq = try XCTUnwrap(
            try catalog.replicaWork(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "hq"
            )
        )
        let m1 = try XCTUnwrap(
            try catalog.replicaWork(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "m1"
            )
        )
        XCTAssertEqual(hq.state, .pending)
        XCTAssertEqual(hq.attempts, 0)
        XCTAssertEqual(hq.claimGeneration, 2)
        XCTAssertEqual(m1.state, .quarantined)
        XCTAssertEqual(m1.attempts, 1)
        XCTAssertEqual(m1.claimGeneration, 1)
        XCTAssertEqual(try replicaRow(replicaID: "obsolete").claimGeneration, 7)

        XCTAssertThrowsError(
            try catalog.retryQuarantined(
                replicaID: "obsolete",
                now: "2026-07-11T00:02:30.000Z"
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveCatalogError, .invalidReplicaID)
        }
        XCTAssertEqual(
            try catalog.retryQuarantined(
                replicaID: nil,
                now: "2026-07-11T00:03:00.000Z"
            ),
            1
        )
        let retriedM1 = try XCTUnwrap(
            try catalog.replicaWork(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "m1"
            )
        )
        XCTAssertEqual(retriedM1.state, .pending)
        XCTAssertEqual(retriedM1.attempts, 0)
        XCTAssertEqual(retriedM1.claimGeneration, 2)
        XCTAssertEqual(try replicaRow(replicaID: "obsolete").claimGeneration, 7)
    }

    func testVerifiedReceiptsAreIdempotentConflictSafeCurrentAndRevalidatedOnRead() throws {
        let (catalog, manifestBytes, binding) = try eligibleBoundCatalog()
        let claims = try catalog.claimReplicaWork(
            limit: 2,
            now: "2026-07-11T00:00:00.000Z"
        )
        let hq = try XCTUnwrap(claims.first { $0.replicaID == "hq" })
        let m1 = try XCTUnwrap(claims.first { $0.replicaID == "m1" })
        try advanceToVerifying(catalog, claim: hq)
        try advanceToVerifying(catalog, claim: m1)

        let hqBytes = try receiptBytes(serverID: "hq", manifestBytes: manifestBytes)
        let hqReceipt = ArchiveVerifiedReceipt(
            canonicalBytes: hqBytes,
            sha256: ArchiveV2Hash.sha256(hqBytes),
            verifiedAt: "2026-07-11T00:05:00.000Z"
        )
        XCTAssertTrue(
            try catalog.recordVerifiedReceipt(
                hq,
                receipt: hqReceipt,
                updatedAt: "2026-07-11T00:05:00.000Z"
            )
        )
        XCTAssertFalse(
            try catalog.recordVerifiedReceipt(
                hq,
                receipt: hqReceipt,
                updatedAt: "2026-07-11T00:05:00.000Z"
            )
        )

        let conflictingBytes = try receiptBytes(
            serverID: "hq",
            manifestBytes: manifestBytes,
            storedAt: "2026-07-11T00:07:00.000Z"
        )
        XCTAssertThrowsError(
            try catalog.recordVerifiedReceipt(
                hq,
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

        try insertObsoleteVerifiedReplicaRow(
            manifestSHA256: binding.manifestSHA256,
            captureID: binding.captureID
        )
        XCTAssertEqual(Set(try catalog.currentVerifiedReceipts(
            manifestSHA256: binding.manifestSHA256
        ).keys), ["hq"])
        XCTAssertFalse(try catalog.hasCurrentDualDurability(manifestSHA256: binding.manifestSHA256))

        let m1Bytes = try receiptBytes(serverID: "m1", manifestBytes: manifestBytes)
        XCTAssertTrue(
            try catalog.recordVerifiedReceipt(
                m1,
                receipt: ArchiveVerifiedReceipt(
                    canonicalBytes: m1Bytes,
                    sha256: ArchiveV2Hash.sha256(m1Bytes),
                    verifiedAt: "2026-07-11T00:06:00.000Z"
                ),
                updatedAt: "2026-07-11T00:06:00.000Z"
            )
        )
        XCTAssertTrue(try catalog.hasCurrentDualDurability(manifestSHA256: binding.manifestSHA256))

        XCTAssertFalse(
            try catalog.markReplicaRetry(
                hq,
                from: .verifyingReceipt,
                nextRetryAt: "2026-07-11T00:09:00.000Z",
                lastError: "timeout",
                updatedAt: "2026-07-11T00:08:00.000Z"
            )
        )
        XCTAssertEqual(
            try catalog.retryQuarantined(
                replicaID: "hq",
                now: "2026-07-11T00:08:00.000Z"
            ),
            0
        )
        XCTAssertEqual(
            try catalog.recoverStaleInflight(
                now: "2026-07-11T01:00:00.000Z",
                olderThanSeconds: 600
            ),
            0
        )
        XCTAssertEqual(
            try catalog.replicaWork(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "hq"
            )?.state,
            .verified
        )

        let unrelated = try addBinding(
            to: catalog,
            captureSeed: "unrelated-receipt-capture",
            sessionID: "unrelated-receipt-session"
        )
        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET capture_id = ?
                WHERE manifest_sha256 = ? AND replica_id = 'hq'
                """,
                arguments: [unrelated.captureID, binding.manifestSHA256]
            )
        }
        XCTAssertThrowsError(
            try catalog.currentVerifiedReceipts(manifestSHA256: binding.manifestSHA256)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .bindingConflict(manifestSHA256: binding.manifestSHA256)
            )
        }
        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET capture_id = ?
                WHERE manifest_sha256 = ? AND replica_id = 'hq'
                """,
                arguments: [binding.captureID, binding.manifestSHA256]
            )
        }

        let storedBeforeCorruption = try replicaRow(replicaID: "hq")
        XCTAssertEqual(storedBeforeCorruption.receiptBytes, hqReceipt.canonicalBytes)
        XCTAssertEqual(storedBeforeCorruption.receiptSHA256, hqReceipt.sha256)
        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET receipt_sha256 = ?
                WHERE manifest_sha256 = ? AND replica_id = 'hq'
                """,
                arguments: [String(repeating: "0", count: 64), binding.manifestSHA256]
            )
        }
        XCTAssertThrowsError(
            try catalog.currentVerifiedReceipts(manifestSHA256: binding.manifestSHA256)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .receiptDigestMismatch(
                    expected: String(repeating: "0", count: 64),
                    actual: hqReceipt.sha256
                )
            )
        }
    }

    func testCurrentVerifiedReceiptValidatesOnlyTheRequestedReplica() throws {
        let (catalog, manifestBytes, binding) = try eligibleBoundCatalog()
        let claims = try catalog.claimReplicaWork(
            limit: 2,
            now: "2026-07-11T00:00:00.000Z"
        )
        var expected: [String: ArchiveVerifiedReceipt] = [:]
        for claim in claims {
            try advanceToVerifying(catalog, claim: claim)
            let receiptBytes = try receiptBytes(
                serverID: claim.replicaID,
                manifestBytes: manifestBytes
            )
            let receipt = ArchiveVerifiedReceipt(
                canonicalBytes: receiptBytes,
                sha256: ArchiveV2Hash.sha256(receiptBytes),
                verifiedAt: "2026-07-11T00:05:00.000Z"
            )
            XCTAssertTrue(
                try catalog.recordVerifiedReceipt(
                    claim,
                    receipt: receipt,
                    updatedAt: "2026-07-11T00:05:00.000Z"
                )
            )
            expected[claim.replicaID] = receipt
        }

        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET receipt_sha256 = ?
                WHERE manifest_sha256 = ? AND replica_id = 'hq'
                """,
                arguments: [String(repeating: "0", count: 64), binding.manifestSHA256]
            )
        }

        XCTAssertThrowsError(
            try catalog.currentVerifiedReceipt(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "hq"
            )
        )
        XCTAssertEqual(
            try catalog.currentVerifiedReceipt(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "m1"
            ),
            expected["m1"]
        )
        XCTAssertThrowsError(
            try catalog.currentVerifiedReceipt(
                manifestSHA256: binding.manifestSHA256,
                replicaID: "obsolete"
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveCatalogError, .invalidReplicaID)
        }
    }

    func testReplicaTimestampsMustBeCanonicalBeforePersistence() throws {
        let (catalog, manifestBytes, binding) = try eligibleBoundCatalog()
        XCTAssertThrowsError(
            try catalog.reconcileEligibleReplicaRows(updatedAt: "not-a-timestamp")
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidTimestamp(field: "updatedAt", value: "not-a-timestamp")
            )
        }
        let claim = try XCTUnwrap(
            try catalog.claimReplicaWork(
                limit: 1,
                now: "2026-07-11T00:00:00.000Z"
            ).first
        )
        XCTAssertThrowsError(
            try catalog.markReplicaRetry(
                claim,
                from: .uploadingObjects,
                nextRetryAt: "2026-07-11 00:10:00",
                lastError: "timeout",
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
        try advanceToVerifying(catalog, claim: claim)
        let receipt = try receiptBytes(serverID: "hq", manifestBytes: manifestBytes)
        XCTAssertThrowsError(
            try catalog.recordVerifiedReceipt(
                claim,
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
        XCTAssertFalse(try catalog.hasCurrentDualDurability(manifestSHA256: binding.manifestSHA256))
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

    func testArchiveCursorCheckpointIsBoundedIdempotentAndFailsClosedWhenTampered() throws {
        let catalog = try migratedCatalog()
        let payload = Data(#"{"next":1}"#.utf8)
        let updatedAt = "2026-07-11T00:06:00.000Z"

        XCTAssertTrue(
            try catalog.storeArchiveCursorCheckpoint(
                payload,
                for: .captureFull,
                updatedAt: updatedAt
            )
        )
        XCTAssertFalse(
            try catalog.storeArchiveCursorCheckpoint(
                payload,
                for: .captureFull,
                updatedAt: updatedAt
            )
        )
        XCTAssertFalse(
            try catalog.storeArchiveCursorCheckpoint(
                payload,
                for: .captureFull,
                updatedAt: "2026-07-11T00:07:00.000Z"
            )
        )
        let checkpoint = try XCTUnwrap(
            try catalog.archiveCursorCheckpoint(for: .captureFull)
        )
        XCTAssertEqual(checkpoint.payload, payload)
        XCTAssertEqual(checkpoint.payloadSHA256, ArchiveV2Hash.sha256(payload))
        XCTAssertEqual(checkpoint.updatedAt, updatedAt)

        XCTAssertThrowsError(
            try catalog.storeArchiveCursorCheckpoint(
                Data(),
                for: .captureFull,
                updatedAt: updatedAt
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidArchiveCursorPayloadSize(0)
            )
        }
        XCTAssertThrowsError(
            try catalog.storeArchiveCursorCheckpoint(
                Data(repeating: 0, count: 16_385),
                for: .captureRecent,
                updatedAt: updatedAt
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidArchiveCursorPayloadSize(16_385)
            )
        }
        XCTAssertThrowsError(
            try catalog.storeArchiveCursorCheckpoint(
                payload,
                for: .bindingCycle,
                updatedAt: "2026-07-11T00:06:00Z"
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidTimestamp(
                    field: "archiveCursor.updatedAt",
                    value: "2026-07-11T00:06:00Z"
                )
            )
        }

        try writeArchiveDatabase { db in
            try db.execute(
                sql: "UPDATE archive_metadata SET value = '{}' WHERE key = ?",
                arguments: [ArchiveCursorKey.captureFull.rawValue]
            )
        }
        XCTAssertThrowsError(
            try catalog.archiveCursorCheckpoint(for: .captureFull)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidArchiveCursorCheckpoint(ArchiveCursorKey.captureFull.rawValue)
            )
        }
        XCTAssertThrowsError(
            try catalog.storeArchiveCursorCheckpoint(
                payload,
                for: .captureFull,
                updatedAt: updatedAt
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidArchiveCursorCheckpoint(ArchiveCursorKey.captureFull.rawValue)
            )
        }
    }

    func testRemotePolicyCursorUsesIndependentDigestCheckedMetadataSlot() throws {
        let catalog = try migratedCatalog()
        let policyPayload = Data(#"{"boundAt":"2026-07-11T00:06:00.000Z","manifestSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8)
        let bindingPayload = Data(#"{"after":null}"#.utf8)
        let updatedAt = "2026-07-11T00:08:00.000Z"

        XCTAssertEqual(
            ArchiveCursorKey.policyCycle.rawValue,
            "archive_cursor_policy_v1"
        )
        XCTAssertTrue(
            try catalog.storeArchiveCursorCheckpoint(
                policyPayload,
                for: .policyCycle,
                updatedAt: updatedAt
            )
        )
        XCTAssertTrue(
            try catalog.storeArchiveCursorCheckpoint(
                bindingPayload,
                for: .bindingCycle,
                updatedAt: updatedAt
            )
        )
        XCTAssertEqual(
            try catalog.archiveCursorCheckpoint(for: .policyCycle)?.payload,
            policyPayload
        )
        XCTAssertEqual(
            try catalog.archiveCursorCheckpoint(for: .bindingCycle)?.payload,
            bindingPayload
        )

        try writeArchiveDatabase { db in
            try db.execute(
                sql: "UPDATE archive_metadata SET value = '{}' WHERE key = ?",
                arguments: [ArchiveCursorKey.policyCycle.rawValue]
            )
        }
        XCTAssertThrowsError(
            try catalog.archiveCursorCheckpoint(for: .policyCycle)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidArchiveCursorCheckpoint(ArchiveCursorKey.policyCycle.rawValue)
            )
        }
        XCTAssertEqual(
            try catalog.archiveCursorCheckpoint(for: .bindingCycle)?.payload,
            bindingPayload,
            "tampering with the policy cursor must not affect binding progress"
        )
    }

    func testUnknownBindingsPagesInStableOrderWithoutDuplicatesAndRejectsInvalidCursor() throws {
        let catalog = try migratedCatalog()
        let bindings = try [
            addBinding(to: catalog, captureSeed: "unknown-a", sessionID: "session-a"),
            addBinding(to: catalog, captureSeed: "unknown-b", sessionID: "session-b"),
            addBinding(to: catalog, captureSeed: "unknown-c", sessionID: "session-c"),
        ].sorted {
            ($0.boundAt, $0.manifestSHA256) < ($1.boundAt, $1.manifestSHA256)
        }
        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: bindings[1].manifestSHA256,
                projectRootSnapshot: "/tmp/excluded",
                eligibility: .excluded
            )
        )
        let expected = [bindings[0], bindings[2]]

        let first = try catalog.unknownBindings(limit: 1, after: nil)
        XCTAssertEqual(first, [expected[0]])
        XCTAssertEqual(first[0].remoteEligibility, .unknown)
        XCTAssertNil(first[0].projectRootSnapshot)
        XCTAssertEqual(
            ArchiveV2Hash.sha256(first[0].canonicalManifestBytes),
            first[0].manifestSHA256
        )
        let cursor = ArchiveBindingCursor(
            boundAt: first[0].boundAt,
            manifestSHA256: first[0].manifestSHA256
        )
        let second = try catalog.unknownBindings(limit: 1, after: cursor)
        XCTAssertEqual(second, [expected[1]])
        let exhausted = try catalog.unknownBindings(
            limit: 1,
            after: ArchiveBindingCursor(
                boundAt: second[0].boundAt,
                manifestSHA256: second[0].manifestSHA256
            )
        )
        XCTAssertTrue(exhausted.isEmpty)
        XCTAssertEqual(Set((first + second).map(\.manifestSHA256)).count, 2)

        XCTAssertThrowsError(
            try catalog.unknownBindings(
                limit: 1,
                after: ArchiveBindingCursor(
                    boundAt: "not-a-timestamp",
                    manifestSHA256: first[0].manifestSHA256
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidTimestamp(
                    field: "cursor.boundAt",
                    value: "not-a-timestamp"
                )
            )
        }
        XCTAssertThrowsError(
            try catalog.unknownBindings(
                limit: 1,
                after: ArchiveBindingCursor(
                    boundAt: first[0].boundAt,
                    manifestSHA256: "tampered"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidSHA256(field: "cursor.manifestSHA256")
            )
        }
    }

    func testUnknownBindingBoundaryFreezesOneSweepWhileNewTailRowsArrive() throws {
        let catalog = try migratedCatalog()
        let initial = try [
            addBinding(to: catalog, captureSeed: "sweep-a", sessionID: "sweep-a"),
            addBinding(to: catalog, captureSeed: "sweep-b", sessionID: "sweep-b"),
            addBinding(to: catalog, captureSeed: "sweep-c", sessionID: "sweep-c"),
        ].sorted {
            ($0.boundAt, $0.manifestSHA256) < ($1.boundAt, $1.manifestSHA256)
        }
        let boundary = try XCTUnwrap(catalog.unknownBindingBoundary())
        XCTAssertEqual(boundary.boundAt, initial.last?.boundAt)
        XCTAssertEqual(boundary.manifestSHA256, initial.last?.manifestSHA256)

        let first = try catalog.unknownBindings(
            limit: 1,
            after: nil,
            through: boundary
        )
        XCTAssertEqual(first, [initial[0]])

        let appended = try addBinding(
            to: catalog,
            captureSeed: "sweep-tail",
            sessionID: "sweep-tail",
            boundAt: "2026-07-11T00:05:00.000Z"
        )
        let afterFirst = ArchiveBindingCursor(
            boundAt: initial[0].boundAt,
            manifestSHA256: initial[0].manifestSHA256
        )
        let restOfFrozenSweep = try catalog.unknownBindings(
            limit: 10,
            after: afterFirst,
            through: boundary
        )

        XCTAssertEqual(restOfFrozenSweep, Array(initial.dropFirst()))
        XCTAssertFalse(
            restOfFrozenSweep.contains { $0.manifestSHA256 == appended.manifestSHA256 },
            "new unknown rows belong to the next bounded sweep"
        )
        XCTAssertTrue(
            try catalog.unknownBindings(
                limit: 1,
                after: boundary,
                through: boundary
            ).isEmpty
        )
        XCTAssertEqual(
            try catalog.unknownBindingBoundary()?.manifestSHA256,
            appended.manifestSHA256
        )
    }

    func testArchiveStatusIsFixedSizeCurrentReplicaOnlyAndRevalidatesReceipts() throws {
        let first = try eligibleBoundCatalog()
        let catalog = first.0
        let claims = try catalog.claimReplicaWork(
            limit: 2,
            now: "2026-07-11T00:00:01.000Z"
        )
        XCTAssertEqual(Set(claims.map(\.replicaID)), Set(["hq", "m1"]))
        for (index, claim) in claims.enumerated() {
            try advanceToVerifying(catalog, claim: claim)
            let verifiedAt = "2026-07-11T00:0\(6 + index):00.000Z"
            let bytes = try receiptBytes(
                serverID: claim.replicaID,
                manifestBytes: first.manifestBytes,
                storedAt: verifiedAt
            )
            XCTAssertTrue(
                try catalog.recordVerifiedReceipt(
                    claim,
                    receipt: ArchiveVerifiedReceipt(
                        canonicalBytes: bytes,
                        sha256: ArchiveV2Hash.sha256(bytes),
                        verifiedAt: verifiedAt
                    ),
                    updatedAt: verifiedAt
                )
            )
        }

        let second = try addBinding(
            to: catalog,
            captureSeed: "status-second",
            sessionID: "status-second"
        )
        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: second.manifestSHA256,
                projectRootSnapshot: "/tmp/status-second",
                eligibility: .eligible
            )
        )
        let third = try addBinding(
            to: catalog,
            captureSeed: "status-third",
            sessionID: "status-third"
        )
        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: third.manifestSHA256,
                projectRootSnapshot: "/tmp/status-third",
                eligibility: .eligible
            )
        )
        let excluded = try addBinding(
            to: catalog,
            captureSeed: "status-excluded",
            sessionID: "status-excluded"
        )
        XCTAssertTrue(
            try catalog.setRemotePolicySnapshot(
                manifestSHA256: excluded.manifestSHA256,
                projectRootSnapshot: "/tmp/status-excluded",
                eligibility: .excluded
            )
        )
        _ = try addBinding(
            to: catalog,
            captureSeed: "status-unknown",
            sessionID: "status-unknown"
        )
        let unbound = try manifest(captureSeed: "status-unbound", sessionID: nil)
        _ = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(unbound)
        )
        XCTAssertEqual(
            try catalog.reconcileEligibleReplicaRows(
                updatedAt: "2026-07-11T00:10:00.000Z"
            ),
            4
        )
        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET state = 'uploadingManifest'
                WHERE manifest_sha256 = ? AND replica_id = 'hq';
                UPDATE archive_replica_receipts
                SET state = 'retryWait', next_retry_at = '2026-07-11T01:00:00.000Z'
                WHERE manifest_sha256 = ? AND replica_id = 'm1';
                UPDATE archive_replica_receipts
                SET state = 'quarantined', last_error = 'status_test'
                WHERE manifest_sha256 = ? AND replica_id = 'hq';
                """,
                arguments: [
                    second.manifestSHA256,
                    second.manifestSHA256,
                    third.manifestSHA256,
                ]
            )
        }
        try insertObsoleteVerifiedReplicaRow(
            manifestSHA256: first.binding.manifestSHA256,
            captureID: first.binding.captureID
        )

        let status = try catalog.archiveStatus()

        XCTAssertEqual(status.captured, 6)
        XCTAssertEqual(status.bound, 5)
        XCTAssertEqual(status.unbound, 1)
        XCTAssertEqual(status.unknown, 1)
        XCTAssertEqual(status.eligible, 3)
        XCTAssertEqual(status.excluded, 1)
        XCTAssertEqual(
            status.hq,
            ArchiveReplicaStatusCounts(
                pending: 0,
                inflight: 1,
                retry: 0,
                quarantine: 1,
                verified: 1
            )
        )
        XCTAssertEqual(
            status.m1,
            ArchiveReplicaStatusCounts(
                pending: 1,
                inflight: 0,
                retry: 1,
                quarantine: 0,
                verified: 1
            )
        )
        XCTAssertEqual(status.singleVerified, 0)
        XCTAssertEqual(status.dualVerified, 1)
        XCTAssertEqual(status.latestReceipts.count, 2)
        XCTAssertEqual(Set(status.latestReceipts.map(\.replicaID)), Set(["hq", "m1"]))
        XCTAssertTrue(status.latestReceipts.allSatisfy { summary in
            summary.manifestSHA256 == first.binding.manifestSHA256
                && summary.captureID == first.binding.captureID
                && ArchiveV2Hash.isValidSHA256(summary.receiptSHA256)
                && !summary.verifiedAt.isEmpty
                && !summary.storedAt.isEmpty
        })

        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET receipt_bytes = ?
                WHERE manifest_sha256 = ? AND replica_id = 'hq'
                """,
                arguments: [Data("tampered".utf8), first.binding.manifestSHA256]
            )
        }
        XCTAssertThrowsError(try catalog.archiveStatus())
    }

    func testArchiveStatusReturnsOneLatestValidatedReceiptPerCurrentReplica() throws {
        let first = try eligibleBoundCatalog()
        let catalog = first.0
        let initialClaims = try catalog.claimReplicaWork(
            limit: 2,
            now: "2026-07-11T00:00:01.000Z"
        )
        for claim in initialClaims {
            try advanceToVerifying(catalog, claim: claim)
            let storedAt = claim.replicaID == "hq"
                ? "2026-07-11T00:06:00.000Z"
                : "2026-07-11T00:05:00.000Z"
            let bytes = try receiptBytes(
                serverID: claim.replicaID,
                manifestBytes: first.manifestBytes,
                storedAt: storedAt
            )
            XCTAssertTrue(
                try catalog.recordVerifiedReceipt(
                    claim,
                    receipt: ArchiveVerifiedReceipt(
                        canonicalBytes: bytes,
                        sha256: ArchiveV2Hash.sha256(bytes),
                        verifiedAt: storedAt
                    ),
                    updatedAt: storedAt
                )
            )
        }

        let second = try addBinding(
            to: catalog,
            captureSeed: "latest-hq-second",
            sessionID: "latest-hq-second"
        )
        let third = try addBinding(
            to: catalog,
            captureSeed: "latest-hq-third",
            sessionID: "latest-hq-third"
        )
        for binding in [second, third] {
            XCTAssertTrue(
                try catalog.setRemotePolicySnapshot(
                    manifestSHA256: binding.manifestSHA256,
                    projectRootSnapshot: "/tmp/\(binding.sessionID)",
                    eligibility: .eligible
                )
            )
        }
        XCTAssertEqual(
            try catalog.reconcileEligibleReplicaRows(
                updatedAt: "2026-07-11T00:07:00.000Z"
            ),
            4
        )
        try forceVerifiedReplicaRow(
            binding: second,
            replicaID: "hq",
            verifiedAt: "2026-07-11T00:08:00.000Z"
        )
        try forceVerifiedReplicaRow(
            binding: third,
            replicaID: "hq",
            verifiedAt: "2026-07-11T00:09:00.000Z"
        )

        let status = try catalog.archiveStatus()

        XCTAssertEqual(status.latestReceipts.count, 2)
        XCTAssertEqual(Set(status.latestReceipts.map(\.replicaID)), Set(["hq", "m1"]))
        XCTAssertEqual(
            status.latestReceipts.first { $0.replicaID == "hq" }?.manifestSHA256,
            third.manifestSHA256
        )
        XCTAssertEqual(
            status.latestReceipts.first { $0.replicaID == "m1" }?.manifestSHA256,
            first.binding.manifestSHA256
        )
        XCTAssertTrue(status.latestReceipts.allSatisfy {
            ArchiveV2Hash.isValidSHA256($0.receiptSHA256)
        })
    }

    private struct ReplicaDatabaseRow {
        let state: ArchiveReplicaState
        let attempts: Int
        let claimGeneration: Int
        let receiptBytes: Data?
        let receiptSHA256: String?
    }

    private func eligibleBoundCatalog() throws -> (
        ArchiveCatalog,
        manifestBytes: Data,
        binding: ArchiveBinding
    ) {
        let result = try boundCatalog()
        XCTAssertTrue(
            try result.0.setRemotePolicySnapshot(
                manifestSHA256: result.binding.manifestSHA256,
                projectRootSnapshot: "/tmp/project",
                eligibility: .eligible
            )
        )
        XCTAssertEqual(
            try result.0.reconcileEligibleReplicaRows(
                updatedAt: "2026-07-11T00:00:00.000Z"
            ),
            2
        )
        return (
            result.0,
            result.manifestBytes,
            try XCTUnwrap(try result.0.latestBinding(sessionID: result.binding.sessionID))
        )
    }

    private func addBinding(
        to catalog: ArchiveCatalog,
        captureSeed: String,
        sessionID: String,
        boundAt: String = "2026-07-11T00:04:00.000Z"
    ) throws -> ArchiveBinding {
        let locator = "/tmp/\(captureSeed).jsonl"
        let unbound = try manifest(
            captureSeed: captureSeed,
            sessionID: nil,
            locator: locator
        )
        _ = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(unbound)
        )
        let bound = try manifest(
            captureSeed: captureSeed,
            sessionID: sessionID,
            locator: locator
        )
        return try catalog.bind(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(bound),
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot-\(captureSeed)".utf8)),
            boundAt: boundAt
        )
    }

    private func advanceToVerifying(
        _ catalog: ArchiveCatalog,
        claim: ArchiveReplicaClaim
    ) throws {
        XCTAssertTrue(
            try catalog.transitionReplicaClaim(
                claim,
                from: .uploadingObjects,
                to: .uploadingManifest,
                updatedAt: "2026-07-11T00:01:00.000Z"
            )
        )
        XCTAssertTrue(
            try catalog.transitionReplicaClaim(
                claim,
                from: .uploadingManifest,
                to: .requestingReceipt,
                updatedAt: "2026-07-11T00:02:00.000Z"
            )
        )
        XCTAssertTrue(
            try catalog.transitionReplicaClaim(
                claim,
                from: .requestingReceipt,
                to: .verifyingReceipt,
                updatedAt: "2026-07-11T00:03:00.000Z"
            )
        )
    }

    private func replicaRowCount() throws -> Int {
        try readArchiveDatabase { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM archive_replica_receipts") ?? -1
        }
    }

    private func replicaIDs(manifestSHA256: String) throws -> [String] {
        try readArchiveDatabase { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT replica_id FROM archive_replica_receipts
                WHERE manifest_sha256 = ?
                ORDER BY replica_id
                """,
                arguments: [manifestSHA256]
            )
        }
    }

    private func replicaRow(replicaID: String) throws -> ReplicaDatabaseRow {
        try readArchiveDatabase { db in
            let row = try XCTUnwrap(
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT state, attempts, claim_generation, receipt_bytes, receipt_sha256
                    FROM archive_replica_receipts
                    WHERE replica_id = ?
                    """,
                    arguments: [replicaID]
                )
            )
            let rawState: String = row["state"]
            return ReplicaDatabaseRow(
                state: try XCTUnwrap(ArchiveReplicaState(rawValue: rawState)),
                attempts: row["attempts"],
                claimGeneration: row["claim_generation"],
                receiptBytes: row["receipt_bytes"],
                receiptSHA256: row["receipt_sha256"]
            )
        }
    }

    private func insertObsoleteReplicaRow(
        manifestSHA256: String,
        captureID: String,
        state: ArchiveReplicaState,
        attempts: Int,
        claimGeneration: Int
    ) throws {
        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO archive_replica_receipts(
                    manifest_sha256, capture_id, replica_id, state, attempts,
                    next_retry_at, last_error, receipt_bytes, receipt_sha256,
                    verified_at, updated_at, claim_generation
                ) VALUES (?, ?, 'obsolete', ?, ?, NULL, 'obsolete_protocol',
                          NULL, NULL, NULL, '2026-07-11T00:01:00.000Z', ?)
                """,
                arguments: [
                    manifestSHA256,
                    captureID,
                    state.rawValue,
                    attempts,
                    claimGeneration,
                ]
            )
        }
    }

    private func forceVerifiedReplicaRow(
        binding: ArchiveBinding,
        replicaID: String,
        verifiedAt: String
    ) throws {
        let bytes = try receiptBytes(
            serverID: replicaID,
            manifestBytes: binding.canonicalManifestBytes,
            storedAt: verifiedAt
        )
        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET state = 'verified', receipt_bytes = ?, receipt_sha256 = ?,
                    verified_at = ?, updated_at = ?
                WHERE manifest_sha256 = ? AND replica_id = ?
                """,
                arguments: [
                    bytes,
                    ArchiveV2Hash.sha256(bytes),
                    verifiedAt,
                    verifiedAt,
                    binding.manifestSHA256,
                    replicaID,
                ]
            )
            XCTAssertEqual(db.changesCount, 1)
        }
    }

    private func insertObsoleteVerifiedReplicaRow(
        manifestSHA256: String,
        captureID: String
    ) throws {
        try writeArchiveDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO archive_replica_receipts(
                    manifest_sha256, capture_id, replica_id, state, attempts,
                    next_retry_at, last_error, receipt_bytes, receipt_sha256,
                    verified_at, updated_at, claim_generation
                ) VALUES (?, ?, 'obsolete', 'verified', 0, NULL, NULL,
                          ?, ?, '2026-07-11T00:05:00.000Z',
                          '2026-07-11T00:05:00.000Z', 4)
                """,
                arguments: [
                    manifestSHA256,
                    captureID,
                    Data("not-canonical".utf8),
                    String(repeating: "0", count: 64),
                ]
            )
        }
    }

    private func createVersionOneCatalogWithBinding() throws -> Data {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let databaseURL = root.appendingPathComponent("archive.sqlite")
        let unbound = try manifest(captureSeed: "migrated-capture", sessionID: nil)
        let bound = try manifest(
            captureSeed: "migrated-capture",
            sessionID: "migrated-session"
        )
        let unboundBytes = try ArchiveCanonicalJSON.encode(unbound)
        let boundBytes = try ArchiveCanonicalJSON.encode(bound)
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.execute(sql: """
                CREATE TABLE archive_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                CREATE TABLE archive_captures (
                    capture_id TEXT PRIMARY KEY NOT NULL,
                    machine_id TEXT NOT NULL,
                    source TEXT NOT NULL,
                    locator TEXT NOT NULL,
                    generation_device INTEGER NOT NULL,
                    generation_inode INTEGER NOT NULL,
                    generation_size INTEGER NOT NULL,
                    generation_mtime_ns INTEGER NOT NULL,
                    generation_ctime_ns INTEGER NOT NULL,
                    generation_mode INTEGER NOT NULL,
                    whole_source_sha256 TEXT NOT NULL,
                    raw_byte_count INTEGER NOT NULL,
                    chunk_size INTEGER NOT NULL,
                    unbound_manifest_sha256 TEXT NOT NULL UNIQUE,
                    unbound_manifest_bytes BLOB NOT NULL,
                    status TEXT NOT NULL,
                    diagnostic TEXT,
                    captured_at TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) WITHOUT ROWID;
                CREATE TABLE archive_session_bindings (
                    manifest_sha256 TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL,
                    capture_id TEXT NOT NULL,
                    source_snapshot_fingerprint TEXT NOT NULL,
                    bound_manifest_bytes BLOB NOT NULL,
                    bound_at TEXT NOT NULL
                ) WITHOUT ROWID;
                CREATE TABLE archive_replica_receipts (
                    manifest_sha256 TEXT NOT NULL,
                    capture_id TEXT NOT NULL,
                    replica_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    next_retry_at TEXT,
                    last_error TEXT,
                    receipt_bytes BLOB,
                    receipt_sha256 TEXT,
                    verified_at TEXT,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(manifest_sha256, replica_id)
                ) WITHOUT ROWID
                """)
                try db.execute(
                    sql: "INSERT INTO archive_metadata(key, value) VALUES (?, ?), (?, ?)",
                    arguments: ["schema_version", "1", "machine_id", machineID]
                )
                try db.execute(
                    sql: """
                    INSERT INTO archive_captures(
                        capture_id, machine_id, source, locator,
                        generation_device, generation_inode, generation_size,
                        generation_mtime_ns, generation_ctime_ns, generation_mode,
                        whole_source_sha256, raw_byte_count, chunk_size,
                        unbound_manifest_sha256, unbound_manifest_bytes,
                        status, diagnostic, captured_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                              'captured', NULL, ?, ?, ?)
                    """,
                    arguments: [
                        unbound.captureID,
                        unbound.machineID,
                        unbound.source,
                        unbound.locator,
                        unbound.generation.device,
                        unbound.generation.inode,
                        unbound.generation.size,
                        unbound.generation.mtimeNs,
                        unbound.generation.ctimeNs,
                        unbound.generation.mode,
                        unbound.wholeSourceSHA256,
                        unbound.rawByteCount,
                        unbound.chunkSize,
                        ArchiveV2Hash.sha256(unboundBytes),
                        unboundBytes,
                        unbound.capturedAt,
                        "2026-07-11T00:00:00.000Z",
                        "2026-07-11T00:00:00.000Z",
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO archive_session_bindings(
                        manifest_sha256, session_id, capture_id,
                        source_snapshot_fingerprint, bound_manifest_bytes, bound_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        ArchiveV2Hash.sha256(boundBytes),
                        "migrated-session",
                        unbound.captureID,
                        ArchiveV2Hash.sha256(Data("migrated-snapshot".utf8)),
                        boundBytes,
                        "2026-07-11T00:04:00.000Z",
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO archive_replica_receipts(
                        manifest_sha256, capture_id, replica_id, state,
                        attempts, next_retry_at, last_error,
                        receipt_bytes, receipt_sha256, verified_at, updated_at
                    ) VALUES (?, ?, 'hq', 'pending', 0, NULL, NULL,
                              NULL, NULL, NULL, '2026-07-11T00:04:00.000Z')
                    """,
                    arguments: [ArchiveV2Hash.sha256(boundBytes), unbound.captureID]
                )
            }
        }
        guard chmod(databaseURL.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return boundBytes
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

    private func writeArchiveDatabase<T>(_ body: (Database) throws -> T) throws -> T {
        let queue = try DatabaseQueue(path: root.appendingPathComponent("archive.sqlite").path)
        return try queue.write(body)
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
