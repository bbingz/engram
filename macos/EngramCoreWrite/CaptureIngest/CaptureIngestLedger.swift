import Foundation
import GRDB
import EngramCoreRead

public enum CaptureIngestLedgerError: Error, Equatable {
    case invalidParserRevision
    case checkpointConflict
    case publicationConflict
    case arrivalConflict
    case invalidStoredRecord
    case invalidPublicationSHA256
    case invalidTime
    case invalidLeaseDuration
    case invalidRetryDelay
    case timeOverflow
    case attemptOverflow
    case claimLost
    case sequenceConflict
}

public enum CaptureIngestStatus: String, Sendable {
    case pending
    case processing
    case parsed
    case indexReady = "index_ready"
    case retryableFailure = "failed_retryable"
    case quarantined
}

public struct CaptureIngestLedgerEntry: Equatable, Sendable {
    public let publicationSHA256: String
    public let parserRevision: String
    public let status: CaptureIngestStatus
    public let failureCode: String?
}

/// A bounded work lease, not source/epoch admission, a parsed result, or readiness.
/// Only the ledger creates tokens. A later transaction must revalidate this lease.
public struct CaptureIngestClaim: Equatable, Sendable {
    public let publicationSHA256: String
    public let parserRevision: String
    public let publication: CollectorPublicationEnvelope
    public let token: String
    public let claimedAt: Int64
    public let expiresAt: Int64
    public let attemptCount: Int64
}

/// Symbolic codes only: callers cannot persist paths, transcript bodies, or logs.
public enum CaptureIngestWorkFailure: Equatable, Sendable {
    public enum QuarantineCode: String, CaseIterable, Sendable {
        case invalidManifest = "invalid_manifest"
        case unsupportedCaptureShape = "unsupported_capture_shape"
        case sourceIntegrityMismatch = "source_integrity_mismatch"
        case bindingMismatch = "binding_mismatch"
        case invalidNativeIdentity = "invalid_native_identity"
        case sequenceConflict = "sequence_conflict"
    }

    public enum RetryCode: String, CaseIterable, Sendable {
        case casUnavailable = "cas_unavailable"
        case stagingUnavailable = "staging_unavailable"
        case interrupted
    }

    case parse(ParserFailure)
    case quarantined(QuarantineCode)
    case retryable(RetryCode)
}

/// Service-owned intake bookkeeping. A pending record is not parsing authority
/// or read readiness: source/epoch/replay checks precede the later parser stage.
public enum CaptureIngestLedger {
    /// Explicit Unix seconds: now >= 0, leaseDuration 1...300, checked addition.
    /// Returns nil for absent, not-yet-due, or terminal work; never creates work.
    public static func claim(
        _ db: Database, publicationSHA256: String, parserRevision: String,
        now: Int64, leaseDuration: Int64
    ) throws -> CaptureIngestClaim? {
        try validateWorkKey(publicationSHA256, parserRevision)
        guard now >= 0 else { throw CaptureIngestLedgerError.invalidTime }
        guard (1...300).contains(leaseDuration) else { throw CaptureIngestLedgerError.invalidLeaseDuration }
        let (expiresAt, timeOverflow) = now.addingReportingOverflow(leaseDuration)
        guard !timeOverflow else { throw CaptureIngestLedgerError.timeOverflow }

        var result: CaptureIngestClaim?
        try db.inSavepoint {
            // Reserve the writer before reading a deferred transaction's snapshot.
            // No rows match, so no row changes or row triggers occur.
            try db.execute(sql: "UPDATE capture_ingest_ledger SET attempt_count = attempt_count WHERE 0")
            guard let row = try workRow(db, publicationSHA256, parserRevision) else { return .commit }
            guard let status = CaptureIngestStatus(rawValue: try storedString(row, "status")) else {
                throw CaptureIngestLedgerError.invalidStoredRecord
            }
            switch status {
            case .parsed, .indexReady, .quarantined: return .commit
            case .pending, .processing, .retryableFailure: break
            }
            let attempt = try storedInteger(row, "attempt_count")
            guard attempt >= 0 else { throw CaptureIngestLedgerError.invalidStoredRecord }
            let eligible: Bool
            switch status {
            case .pending:
                try requireNull(row, ["claim_token", "claim_started_at", "claim_expires_at", "retry_after"])
                eligible = true
            case .retryableFailure:
                try requireNull(row, ["claim_token", "claim_started_at", "claim_expires_at"])
                let retryAfter = try storedInteger(row, "retry_after")
                guard attempt > 0, retryAfter >= 0 else { throw CaptureIngestLedgerError.invalidStoredRecord }
                eligible = now >= retryAfter
            case .processing:
                let lease = try storedLease(row, attempt: attempt)
                eligible = now >= lease.expiresAt
            case .parsed, .indexReady, .quarantined: return .commit
            }
            let publication = try verifiedWorkPublication(db, sha256: publicationSHA256)
            guard eligible else { return .commit }
            let (nextAttempt, attemptOverflow) = attempt.addingReportingOverflow(1)
            guard !attemptOverflow else { throw CaptureIngestLedgerError.attemptOverflow }
            let token = UUID().uuidString
            try db.execute(sql: """
                UPDATE capture_ingest_ledger
                SET status = 'processing', failure_code = NULL, claim_token = ?, claim_started_at = ?,
                    claim_expires_at = ?, attempt_count = ?, retry_after = NULL, updated_at = datetime('now')
                WHERE publication_sha256 = ? AND parser_revision = ? AND status = ?
                    AND claim_token IS ? AND claim_started_at IS ? AND claim_expires_at IS ?
                    AND attempt_count = ? AND retry_after IS ?
                """, arguments: [
                    token, now, expiresAt, nextAttempt, publicationSHA256, parserRevision, status.rawValue,
                    row["claim_token"] as DatabaseValue, row["claim_started_at"] as DatabaseValue,
                    row["claim_expires_at"] as DatabaseValue, attempt, row["retry_after"] as DatabaseValue,
                ])
            guard db.changesCount == 1 else { throw CaptureIngestLedgerError.claimLost }
            result = CaptureIngestClaim(publicationSHA256: publicationSHA256, parserRevision: parserRevision,
                publication: publication, token: token, claimedAt: now, expiresAt: expiresAt, attemptCount: nextAttempt)
            return .commit
        }
        return result
    }

    /// Read-only transaction fence. Rechecks the token, state, lease, canonical
    /// publication, and stream tuple; it does not validate registry or readiness.
    public static func requireCurrentClaim(
        _ db: Database, claim: CaptureIngestClaim, now: Int64
    ) throws {
        try validateWorkKey(claim.publicationSHA256, claim.parserRevision)
        guard now >= 0 else { throw CaptureIngestLedgerError.invalidTime }
        guard let row = try workRow(db, claim.publicationSHA256, claim.parserRevision) else {
            throw CaptureIngestLedgerError.claimLost
        }
        guard let status = CaptureIngestStatus(rawValue: try storedString(row, "status")) else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        guard status == .processing else { throw CaptureIngestLedgerError.claimLost }
        let attempt = try storedInteger(row, "attempt_count")
        let lease = try storedLease(row, attempt: attempt)
        let publication = try verifiedWorkPublication(db, sha256: claim.publicationSHA256)
        guard claim == CaptureIngestClaim(publicationSHA256: claim.publicationSHA256,
            parserRevision: claim.parserRevision, publication: publication, token: lease.token,
            claimedAt: lease.startedAt, expiresAt: lease.expiresAt, attemptCount: attempt) else {
            throw CaptureIngestLedgerError.claimLost
        }
        guard now >= lease.startedAt else { throw CaptureIngestLedgerError.invalidTime }
        guard now < lease.expiresAt else { throw CaptureIngestLedgerError.claimLost }
    }

    /// Failure-only CAS. retryDelay is required only for retryable and is 1...3600.
    /// At now >= expiresAt the old token has no write authority, even if unstolen.
    public static func recordFailure(
        _ db: Database, claim: CaptureIngestClaim, failure: CaptureIngestWorkFailure,
        now: Int64, retryDelay: Int64? = nil
    ) throws {
        guard now >= 0 else { throw CaptureIngestLedgerError.invalidTime }
        let status: CaptureIngestStatus
        let code: String
        let retryAfter: Int64?
        switch failure {
        case .parse(let reason):
            guard retryDelay == nil else { throw CaptureIngestLedgerError.invalidRetryDelay }
            status = .quarantined
            code = "parse.\(reason.rawValue)"
            retryAfter = nil
        case .quarantined(let reason):
            guard retryDelay == nil else { throw CaptureIngestLedgerError.invalidRetryDelay }
            status = .quarantined
            code = "quarantine.\(reason.rawValue)"
            retryAfter = nil
        case .retryable(let reason):
            guard let retryDelay, (1...3_600).contains(retryDelay) else {
                throw CaptureIngestLedgerError.invalidRetryDelay
            }
            let (deadline, overflow) = now.addingReportingOverflow(retryDelay)
            guard !overflow else { throw CaptureIngestLedgerError.timeOverflow }
            status = .retryableFailure
            code = "retry.\(reason.rawValue)"
            retryAfter = deadline
        }
        try db.inSavepoint {
            try requireCurrentClaim(db, claim: claim, now: now)
            try db.execute(sql: """
                UPDATE capture_ingest_ledger
                SET status = ?, failure_code = ?, retry_after = ?, claim_token = NULL,
                    claim_started_at = NULL, claim_expires_at = NULL, updated_at = datetime('now')
                WHERE publication_sha256 = ? AND parser_revision = ? AND status = 'processing'
                    AND claim_token = ? AND claim_started_at = ? AND claim_expires_at = ?
                    AND attempt_count = ? AND claim_started_at <= ? AND claim_expires_at > ?
                """, arguments: [
                    status.rawValue, code, retryAfter, claim.publicationSHA256, claim.parserRevision,
                    claim.token, claim.claimedAt, claim.expiresAt, claim.attemptCount, now, now,
                ])
            guard db.changesCount == 1 else { throw CaptureIngestLedgerError.claimLost }
            return .commit
        }
    }

    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS capture_ingest_publications (
                publication_sha256 TEXT PRIMARY KEY NOT NULL,
                canonical_bytes BLOB NOT NULL,
                machine_id TEXT NOT NULL,
                source_instance_id TEXT NOT NULL,
                collector_epoch TEXT NOT NULL,
                sequence INTEGER NOT NULL CHECK (sequence > 0),
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_capture_ingest_stream_tuple
                ON capture_ingest_publications(machine_id, source_instance_id, collector_epoch, sequence);
            CREATE TABLE IF NOT EXISTS capture_ingest_ledger (
                publication_sha256 TEXT NOT NULL REFERENCES capture_ingest_publications(publication_sha256),
                parser_revision TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN (
                    'pending', 'processing', 'parsed', 'index_ready', 'failed_retryable', 'quarantined'
                )),
                failure_code TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (publication_sha256, parser_revision)
            );
            CREATE INDEX IF NOT EXISTS idx_capture_ingest_pending
                ON capture_ingest_ledger(parser_revision, status, created_at, publication_sha256);
            CREATE TABLE IF NOT EXISTS capture_ingest_arrivals (
                server_id TEXT NOT NULL,
                journal_id TEXT NOT NULL,
                arrival_ordinal INTEGER NOT NULL CHECK (arrival_ordinal > 0),
                publication_sha256 TEXT NOT NULL REFERENCES capture_ingest_publications(publication_sha256),
                PRIMARY KEY (server_id, journal_id, arrival_ordinal),
                UNIQUE (server_id, journal_id, publication_sha256)
            );
            CREATE TABLE IF NOT EXISTS capture_ingest_checkpoints (
                server_id TEXT PRIMARY KEY NOT NULL,
                cursor TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            """)
        // Preserve legacy statuses and timestamps. A legacy processing/retryable
        // row without its required lease/deadline remains fail-closed.
        let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(capture_ingest_ledger)")
            .map { $0["name"] as String })
        for (name, definition) in [
            ("claim_token", "TEXT"), ("claim_started_at", "INTEGER"), ("claim_expires_at", "INTEGER"),
            ("attempt_count", "INTEGER NOT NULL DEFAULT 0"), ("retry_after", "INTEGER"),
        ] where !columns.contains(name) {
            try db.execute(sql: "ALTER TABLE capture_ingest_ledger ADD COLUMN \(name) \(definition)")
        }
    }

    private static func validateWorkKey(_ sha256: String, _ parserRevision: String) throws {
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CaptureIngestLedgerError.invalidPublicationSHA256
        }
        guard !parserRevision.isEmpty, parserRevision.utf8.count <= 128,
              parserRevision == parserRevision.trimmingCharacters(in: .whitespacesAndNewlines),
              !parserRevision.utf8.contains(0) else {
            throw CaptureIngestLedgerError.invalidParserRevision
        }
    }

    private static func workRow(_ db: Database, _ sha256: String, _ parserRevision: String) throws -> Row? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?
            """, arguments: [sha256, parserRevision])
    }

    private static func storedInteger(_ row: Row, _ column: String) throws -> Int64 {
        guard case .int64(let value) = (row[column] as DatabaseValue).storage else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        return value
    }

    private static func storedString(_ row: Row, _ column: String) throws -> String {
        guard case .string(let value) = (row[column] as DatabaseValue).storage else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        return value
    }

    private static func requireNull(_ row: Row, _ columns: [String]) throws {
        guard columns.allSatisfy({ (row[$0] as DatabaseValue).isNull }) else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
    }

    private static func storedLease(_ row: Row, attempt: Int64) throws -> (token: String, startedAt: Int64, expiresAt: Int64) {
        let token = try storedString(row, "claim_token")
        let startedAt = try storedInteger(row, "claim_started_at")
        let expiresAt = try storedInteger(row, "claim_expires_at")
        guard attempt > 0, startedAt >= 0, expiresAt > startedAt, expiresAt - startedAt <= 300,
              let uuid = UUID(uuidString: token), uuid.uuidString.utf8.elementsEqual(token.utf8) else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        try requireNull(row, ["retry_after"])
        return (token, startedAt, expiresAt)
    }

    private static func verifiedWorkPublication(_ db: Database, sha256: String) throws -> CollectorPublicationEnvelope {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM capture_ingest_publications WHERE publication_sha256 = ?",
                                        arguments: [sha256]),
              case .blob(let bytes) = (row["canonical_bytes"] as DatabaseValue).storage,
              bytes.count <= CollectorPublicationProtocolLimits.maxPublicationBytes,
              ArchiveV2Hash.sha256(bytes) == sha256 else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        let publication: CollectorPublicationEnvelope
        do {
            publication = try ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: bytes)
        } catch {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        guard try storedString(row, "machine_id").utf8.elementsEqual(publication.machineID.utf8),
              try storedString(row, "source_instance_id").utf8.elementsEqual(publication.sourceInstanceID.utf8),
              try storedString(row, "collector_epoch").utf8.elementsEqual(publication.collectorEpoch.utf8),
              try storedInteger(row, "sequence") == publication.sequence else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        let conflicts = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM capture_ingest_publications
                WHERE machine_id = ? AND source_instance_id = ? AND collector_epoch = ? AND sequence = ?
                    AND publication_sha256 != ?)
            """, arguments: [publication.machineID, publication.sourceInstanceID,
                             publication.collectorEpoch, publication.sequence, sha256])
        guard conflicts == false else { throw CaptureIngestLedgerError.sequenceConflict }
        return publication
    }

    public static func checkpoint(_ db: Database, serverID: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT cursor FROM capture_ingest_checkpoints WHERE server_id = ?", arguments: [serverID])
    }

    public static func entry(
        _ db: Database, publicationSHA256: String, parserRevision: String
    ) throws -> CaptureIngestLedgerEntry? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT status, failure_code FROM capture_ingest_ledger
            WHERE publication_sha256 = ? AND parser_revision = ?
            """, arguments: [publicationSHA256, parserRevision]) else { return nil }
        guard let status = CaptureIngestStatus(rawValue: row["status"]) else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        return CaptureIngestLedgerEntry(
            publicationSHA256: publicationSHA256, parserRevision: parserRevision,
            status: status, failureCode: row["failure_code"]
        )
    }

    public static func publication(_ db: Database, sha256: String) throws -> CollectorPublicationEnvelope? {
        guard let data = try Data.fetchOne(db, sql: """
            SELECT canonical_bytes FROM capture_ingest_publications WHERE publication_sha256 = ?
            """, arguments: [sha256]) else { return nil }
        guard ArchiveV2Hash.sha256(data) == sha256 else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        return try ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: data)
    }

    public static func accept(
        _ db: Database,
        page: CollectorPublicationPage,
        requestedCursor: String?,
        serverID: String,
        parserRevision: String
    ) throws {
        guard !parserRevision.isEmpty, parserRevision.utf8.count <= 128,
              parserRevision == parserRevision.trimmingCharacters(in: .whitespacesAndNewlines),
              !parserRevision.utf8.contains(0) else {
            throw CaptureIngestLedgerError.invalidParserRevision
        }
        let requested = try requestedCursor.map(CollectorPublicationCursor.decode)
        try page.validate(after: requested, expectedServerID: serverID)

        // The caller's writer transaction may catch an intake error and continue.
        // Keep all arrivals/work rows and the checkpoint in this inner savepoint.
        try db.inSavepoint {
            let current = try checkpoint(db, serverID: serverID)
            let isReplay = current != nil && current == page.afterCursor
            guard current == requestedCursor || isReplay else {
                throw CaptureIngestLedgerError.checkpointConflict
            }
            for record in page.items {
                try acceptRecord(db, record: record, parserRevision: parserRevision, requireExistingArrival: isReplay)
            }
            try db.execute(sql: """
                INSERT INTO capture_ingest_checkpoints(server_id, cursor) VALUES (?, ?)
                ON CONFLICT(server_id) DO UPDATE SET cursor = excluded.cursor, updated_at = datetime('now')
                """, arguments: [serverID, page.afterCursor])
            return .commit
        }
    }

    private static func acceptRecord(
        _ db: Database,
        record: CollectorPublicationAcceptanceRecord,
        parserRevision: String,
        requireExistingArrival: Bool
    ) throws {
        let publication = record.publication
        let ack = record.ack
        let data = try ArchiveCanonicalJSON.encode(publication)
        if let stored = try Data.fetchOne(db, sql: """
            SELECT canonical_bytes FROM capture_ingest_publications WHERE publication_sha256 = ?
            """, arguments: [ack.publicationSHA256]), stored != data {
            throw CaptureIngestLedgerError.publicationConflict
        }
        let arrival = try String.fetchOne(db, sql: """
            SELECT publication_sha256 FROM capture_ingest_arrivals
            WHERE server_id = ? AND journal_id = ? AND arrival_ordinal = ?
            """, arguments: [ack.serverID, ack.journalID, ack.arrivalOrdinal])
        guard arrival == nil || arrival == ack.publicationSHA256,
              !requireExistingArrival || arrival == ack.publicationSHA256 else {
            throw CaptureIngestLedgerError.arrivalConflict
        }
        if let ordinal = try Int64.fetchOne(db, sql: """
            SELECT arrival_ordinal FROM capture_ingest_arrivals
            WHERE server_id = ? AND journal_id = ? AND publication_sha256 = ?
            """, arguments: [ack.serverID, ack.journalID, ack.publicationSHA256]), ordinal != ack.arrivalOrdinal {
            throw CaptureIngestLedgerError.arrivalConflict
        }
        try db.execute(sql: """
            INSERT INTO capture_ingest_publications(
                publication_sha256, canonical_bytes, machine_id, source_instance_id, collector_epoch, sequence
            ) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(publication_sha256) DO NOTHING
            """, arguments: [
                ack.publicationSHA256, data, publication.machineID, publication.sourceInstanceID,
                publication.collectorEpoch, publication.sequence,
            ])
        let tuple: StatementArguments = [
            publication.machineID, publication.sourceInstanceID, publication.collectorEpoch, publication.sequence,
        ]
        let conflicts = try String.fetchAll(db, sql: """
            SELECT publication_sha256 FROM capture_ingest_publications
            WHERE machine_id = ? AND source_instance_id = ? AND collector_epoch = ? AND sequence = ?
            """, arguments: tuple)
        let conflicted = conflicts.contains { $0 != ack.publicationSHA256 }
        try db.execute(sql: """
            INSERT INTO capture_ingest_ledger(publication_sha256, parser_revision, status, failure_code)
            VALUES (?, ?, ?, ?) ON CONFLICT(publication_sha256, parser_revision) DO NOTHING
            """, arguments: [
                ack.publicationSHA256, parserRevision,
                conflicted ? CaptureIngestStatus.quarantined.rawValue : CaptureIngestStatus.pending.rawValue,
                conflicted ? "sequence_conflict" : nil,
            ])
        if conflicted {
            // Neither arrival order nor a new parser revision resolves a stream
            // tuple conflict. Retain already parsed last-good rows; stop pending
            // work from promoting either competing publication automatically.
            for digest in conflicts {
                try db.execute(sql: """
                    UPDATE capture_ingest_ledger
                    SET status = 'quarantined', failure_code = 'sequence_conflict', updated_at = datetime('now')
                    WHERE publication_sha256 = ? AND status IN ('pending', 'processing', 'failed_retryable')
                    """, arguments: [digest])
            }
        }
        try db.execute(sql: """
            INSERT INTO capture_ingest_arrivals(server_id, journal_id, arrival_ordinal, publication_sha256)
            VALUES (?, ?, ?, ?) ON CONFLICT(server_id, journal_id, arrival_ordinal) DO NOTHING
            """, arguments: [ack.serverID, ack.journalID, ack.arrivalOrdinal, ack.publicationSHA256])
    }
}
