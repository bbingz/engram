import Foundation
import GRDB
import EngramCoreRead

public enum CaptureIngestLedgerError: Error, Equatable {
    case invalidParserRevision
    case checkpointConflict
    case publicationConflict
    case arrivalConflict
    case invalidStoredRecord
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

/// Service-owned intake bookkeeping. A pending record is not parsing authority
/// or read readiness: source/epoch/replay checks precede the later parser stage.
public enum CaptureIngestLedger {
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
