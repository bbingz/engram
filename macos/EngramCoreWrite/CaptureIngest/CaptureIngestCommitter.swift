import Foundation
import EngramCoreRead
import GRDB

public enum CaptureIngestCommitError: Error, Equatable {
    case invalidParserRevision
    case parserRevisionChanged
    case bindingChanged
    case invalidReplay
    case identityConflict
    case staleGeneration
    case sequenceConflict
    case syncVersionOverflow
    case invalidStoredRecord
    case normalizedPayloadTooLarge
    case tooManyMessages
    case currentSnapshotMismatch
}

/// A parsed commit receipt, not proof of FTS completion or read readiness.
public struct CaptureIngestCommittedGeneration: Equatable, Sendable {
    public let sessionID: String
    public let generationID: String
    public let syncVersion: Int
    public let snapshotHash: String
    public let requiredFTSJobID: String?
}

/// Service-owned atomic publication of a complete normalized parse artifact.
/// The caller supplies current trusted parser authority inside its writer gate;
/// this API cannot discover whether the caller's expected revision is current.
/// Raw normalized payloads remain internal until a later read/FTS consumer is
/// connected. Never treat storage, a snapshot, or a queued job as index_ready.
public enum CaptureIngestCommitter {
    public static let normalizedSchemaVersion = 1
    public static let maximumNormalizedPayloadBytes = 100 * 1024 * 1024
    public static let maximumNormalizedMessages = 10_000

    /// Call in one writer transaction after replay finishes, with no awaits.
    /// Per-identity order uses authority generation and stream sequence, never
    /// revision-string ordering. Failures must roll back an internal savepoint
    /// even when the outer writer catches the error and continues its transaction.
    public static func commitParsed(
        _ db: Database,
        claim: CaptureIngestClaim,
        replay: CaptureIngestReplayResult,
        expectedParserRevision: String,
        now: Int64,
        indexedAt: String
    ) throws -> CaptureIngestCommittedGeneration {
        try validateParserRevision(expectedParserRevision)
        guard exact(claim.parserRevision, expectedParserRevision) else {
            throw CaptureIngestCommitError.parserRevisionChanged
        }
        var committed: CaptureIngestCommittedGeneration?
        try db.inSavepoint {
            // Reserve before reading a deferred transaction's snapshot. A caller
            // that already read an older snapshot must retry its outer transaction.
            try db.execute(sql: "UPDATE capture_ingest_ledger SET attempt_count = attempt_count WHERE 0")
            try CaptureIngestLedger.requireCurrentClaim(db, claim: claim, now: now)
            let manifestBytes = try ArchiveCanonicalJSON.encode(replay.verifiedManifest)
            guard exact(replay.publicationSHA256, claim.publicationSHA256),
                  exact(ArchiveV2Hash.sha256(manifestBytes), claim.publication.manifestSHA256) else {
                throw CaptureIngestCommitError.invalidReplay
            }
            try requireBinding(db, claim: claim, replay: replay)
            try validateReplay(claim: claim, replay: replay)
            let messages = try normalizedPayload(replay.scan.messages)
            let native = replay.nativeIdentity
            let storedID = try native.proposedSessionID()
            let priorBinding = try identityRow(db, native: native)
            let previousHead = try priorBinding.flatMap { try optionalString($0, "last_parsed_generation_id") }
            let previousVersion = try priorBinding.map { try nonnegativeInteger($0, "last_sync_version") } ?? 0
            let currentSession = try Row.fetchOne(db, sql: "SELECT authoritative_node, source FROM sessions WHERE id = ?",
                                                 arguments: [storedID])
            if let priorBinding {
                guard exact(try string(priorBinding, "stored_session_id"), storedID), let previousHead,
                      let currentSession,
                      exact(try string(currentSession, "authoritative_node"), native.peer),
                      exact(try string(currentSession, "source"), native.source.rawValue) else {
                    throw CaptureIngestCommitError.identityConflict
                }
                try requireOrder(db, previousHead: previousHead, native: native, storedID: storedID,
                                 claim: claim, binding: replay.bindingSnapshot)
            } else {
                // An occupied proposed ID is not proof of an alias, even when
                // its owner string matches. Unrelated local/native IDs coexist.
                guard currentSession == nil else { throw CaptureIngestCommitError.identityConflict }
            }
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM capture_ingest_generations WHERE publication_sha256 = ? AND parser_revision = ?)
                """, arguments: [claim.publicationSHA256, claim.parserRevision]) == false else {
                throw CaptureIngestCommitError.staleGeneration
            }
            let version = try nextSyncVersion(db, native: native, storedID: storedID, previousVersion: previousVersion)
            let generationID = ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode([claim.publicationSHA256, claim.parserRevision]))
            var scan = replay.scan
            scan.info.parentSessionId = try resolvedParent(db, native: replay.parentIdentity)
            scan.info.suggestedParentId = nil
            let snapshot = AuthoritativeSessionSnapshotBuilder.build(from: scan, sessionID: storedID,
                logicalLocator: replay.verifiedManifest.locator, sourceLocator: "capture://\(generationID)",
                authoritativeNode: native.peer, syncVersion: version, indexedAt: indexedAt)
            let writer = SessionSnapshotWriter(db: db)
            _ = try writer.writeAuthoritativeSnapshot(snapshot)
            let jobID = try writer.ensureCurrentCaptureFTSJob(sessionID: storedID, authoritativeNode: native.peer,
                                                            syncVersion: version, snapshotHash: snapshot.snapshotHash)
            if priorBinding == nil {
                try db.execute(sql: """
                    INSERT INTO capture_ingest_identity_bindings(machine_id, source_instance_id, source, native_id, stored_session_id)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [native.machineID, native.sourceInstanceID, native.source.rawValue, native.nativeID, storedID])
            }
            let binding = replay.bindingSnapshot
            try db.execute(sql: """
                INSERT INTO capture_ingest_generations(
                    generation_id, publication_sha256, parser_revision, machine_id, source_instance_id, source,
                    parse_format, configured_root, collector_epoch, authority_generation, sequence, native_id,
                    raw_source_session_id, stored_session_id, parent_native_id, suggested_parent_native_id,
                    manifest_json, normalized_schema_version, normalized_messages_json, normalized_messages_sha256,
                    normalized_message_count, sync_version, snapshot_hash, required_fts_job_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    generationID, claim.publicationSHA256, claim.parserRevision, native.machineID, native.sourceInstanceID,
                    native.source.rawValue, binding.parseFormat.rawValue, binding.configuredRoot, claim.publication.collectorEpoch,
                    binding.authorityGeneration, claim.publication.sequence, native.nativeID, replay.rawSourceSessionID, storedID,
                    replay.parentIdentity?.nativeID, replay.suggestedParentIdentity?.nativeID, manifestBytes, normalizedSchemaVersion,
                    messages, ArchiveV2Hash.sha256(messages), replay.scan.messages.count, version, snapshot.snapshotHash, jobID, indexedAt,
                ])
            try db.execute(sql: """
                UPDATE capture_ingest_identity_bindings SET last_parsed_generation_id = ?, last_sync_version = ?
                WHERE machine_id = ? AND source_instance_id = ? AND source = ? AND native_id = ?
                    AND stored_session_id = ? AND last_parsed_generation_id IS ? AND last_sync_version = ?
                """, arguments: [generationID, version, native.machineID, native.sourceInstanceID, native.source.rawValue,
                                   native.nativeID, storedID, previousHead, previousVersion])
            guard db.changesCount == 1 else { throw CaptureIngestCommitError.staleGeneration }
            try CaptureIngestLedger.requireCurrentClaim(db, claim: claim, now: now)
            try requireBinding(db, claim: claim, replay: replay)
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET status = 'parsed', failure_code = NULL, claim_token = NULL,
                    claim_started_at = NULL, claim_expires_at = NULL, retry_after = NULL, updated_at = datetime('now')
                WHERE publication_sha256 = ? AND parser_revision = ? AND status = 'processing' AND claim_token = ?
                    AND claim_started_at = ? AND claim_expires_at = ? AND attempt_count = ?
                    AND claim_started_at <= ? AND claim_expires_at > ?
                """, arguments: [claim.publicationSHA256, claim.parserRevision, claim.token, claim.claimedAt,
                                   claim.expiresAt, claim.attemptCount, now, now])
            guard db.changesCount == 1 else { throw CaptureIngestLedgerError.claimLost }
            committed = CaptureIngestCommittedGeneration(sessionID: storedID, generationID: generationID, syncVersion: version,
                                                         snapshotHash: snapshot.snapshotHash, requiredFTSJobID: jobID)
            return .commit
        }
        guard let committed else { throw CaptureIngestCommitError.invalidStoredRecord }
        return committed
    }

    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS capture_ingest_identity_bindings (
                machine_id TEXT NOT NULL,
                source_instance_id TEXT NOT NULL,
                source TEXT NOT NULL,
                native_id TEXT NOT NULL COLLATE BINARY,
                stored_session_id TEXT NOT NULL UNIQUE REFERENCES sessions(id),
                last_parsed_generation_id TEXT REFERENCES capture_ingest_generations(generation_id),
                last_ready_generation_id TEXT REFERENCES capture_ingest_generations(generation_id),
                last_sync_version INTEGER NOT NULL DEFAULT 0 CHECK (last_sync_version >= 0),
                PRIMARY KEY (machine_id, source_instance_id, source, native_id)
            );
            CREATE TABLE IF NOT EXISTS capture_ingest_generations (
                generation_id TEXT PRIMARY KEY,
                publication_sha256 TEXT NOT NULL REFERENCES capture_ingest_publications(publication_sha256),
                parser_revision TEXT NOT NULL,
                machine_id TEXT NOT NULL,
                source_instance_id TEXT NOT NULL,
                source TEXT NOT NULL,
                parse_format TEXT NOT NULL,
                configured_root TEXT NOT NULL,
                collector_epoch TEXT NOT NULL,
                authority_generation INTEGER NOT NULL CHECK (authority_generation > 0),
                sequence INTEGER NOT NULL CHECK (sequence > 0),
                native_id TEXT NOT NULL COLLATE BINARY,
                raw_source_session_id TEXT NOT NULL,
                stored_session_id TEXT NOT NULL REFERENCES sessions(id),
                parent_native_id TEXT,
                suggested_parent_native_id TEXT,
                manifest_json BLOB NOT NULL,
                normalized_schema_version INTEGER NOT NULL CHECK (normalized_schema_version = \(normalizedSchemaVersion)),
                normalized_messages_json BLOB NOT NULL CHECK (length(normalized_messages_json) <= \(maximumNormalizedPayloadBytes)),
                normalized_messages_sha256 TEXT NOT NULL,
                normalized_message_count INTEGER NOT NULL CHECK (normalized_message_count BETWEEN 0 AND \(maximumNormalizedMessages)),
                sync_version INTEGER NOT NULL CHECK (sync_version > 0),
                snapshot_hash TEXT NOT NULL,
                required_fts_job_id TEXT,
                created_at TEXT NOT NULL,
                UNIQUE (publication_sha256, parser_revision),
                UNIQUE (stored_session_id, sync_version),
                FOREIGN KEY (machine_id, source_instance_id, source, native_id)
                    REFERENCES capture_ingest_identity_bindings(machine_id, source_instance_id, source, native_id)
            );
            """)
    }

    private static func requireBinding(_ db: Database, claim: CaptureIngestClaim, replay: CaptureIngestReplayResult) throws {
        guard case .eligible(let current) = try CaptureIngestSourceRegistry.eligibility(
            db, publication: claim.publication, verifiedManifest: replay.verifiedManifest),
              current == replay.bindingSnapshot else {
            throw CaptureIngestCommitError.bindingChanged
        }
    }

    private static func validateReplay(claim: CaptureIngestClaim, replay: CaptureIngestReplayResult) throws {
        let scan = replay.scan
        guard scan.parseFailure == nil, scan.info.source == replay.bindingSnapshot.source,
              exact(scan.info.filePath, replay.verifiedManifest.locator),
              scan.info.sizeBytes == replay.verifiedManifest.rawByteCount else {
            throw CaptureIngestCommitError.invalidReplay
        }
        do {
            let identity = try CaptureIngestIdentity(machineID: claim.publication.machineID,
                sourceInstanceID: claim.publication.sourceInstanceID, source: scan.info.source, nativeID: scan.info.id)
            _ = try identity.mapping(nativeID: replay.rawSourceSessionID)
            let parent = try scan.info.parentSessionId.map { try identity.mapping(nativeID: $0) }
            let suggested = try scan.info.suggestedParentId.map { try identity.mapping(nativeID: $0) }
            guard identity == replay.nativeIdentity, parent == replay.parentIdentity,
                  suggested == replay.suggestedParentIdentity else {
                throw CaptureIngestCommitError.invalidReplay
            }
        } catch {
            throw CaptureIngestCommitError.invalidReplay
        }
    }

    private static func normalizedPayload(_ messages: [NormalizedMessage]) throws -> Data {
        guard messages.count <= maximumNormalizedMessages else { throw CaptureIngestCommitError.tooManyMessages }
        // A cheap lower bound avoids encoding an already oversized string. The
        // final canonical byte count still accounts for JSON escape expansion.
        var minimumBytes = 0
        func include(_ text: String?) throws {
            guard let text else { return }
            let bytes = text.utf8.count
            guard bytes <= maximumNormalizedPayloadBytes - minimumBytes else {
                throw CaptureIngestCommitError.normalizedPayloadTooLarge
            }
            minimumBytes += bytes
        }
        for message in messages {
            try include(message.content)
            try include(message.timestamp)
            for tool in message.toolCalls ?? [] {
                try include(tool.name)
                try include(tool.input)
                try include(tool.output)
            }
        }
        let bytes = try ArchiveCanonicalJSON.encode(messages)
        guard bytes.count <= maximumNormalizedPayloadBytes else { throw CaptureIngestCommitError.normalizedPayloadTooLarge }
        return bytes
    }

    private static func identityRow(_ db: Database, native: CaptureIngestIdentity) throws -> Row? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM capture_ingest_identity_bindings
            WHERE machine_id = ? AND source_instance_id = ? AND source = ? AND native_id = ?
            """, arguments: [native.machineID, native.sourceInstanceID, native.source.rawValue, native.nativeID])
    }

    private static func requireOrder(
        _ db: Database, previousHead: String, native: CaptureIngestIdentity, storedID: String,
        claim: CaptureIngestClaim, binding: CaptureIngestSourceBinding
    ) throws {
        // Fetch only ordering/provenance metadata, never an old transcript BLOB.
        guard let previous = try Row.fetchOne(db, sql: """
            SELECT publication_sha256, parser_revision, machine_id, source_instance_id, source, native_id,
                stored_session_id, collector_epoch, authority_generation, sequence, manifest_json, normalized_schema_version
            FROM capture_ingest_generations WHERE generation_id = ?
            """, arguments: [previousHead]) else { throw CaptureIngestCommitError.invalidStoredRecord }
        try requireIdentity(previous, native: native)
        guard exact(try string(previous, "stored_session_id"), storedID),
              try nonnegativeInteger(previous, "normalized_schema_version") == Int64(normalizedSchemaVersion) else {
            throw CaptureIngestCommitError.invalidStoredRecord
        }
        let priorDigest = try string(previous, "publication_sha256")
        let priorRevision = try string(previous, "parser_revision")
        let priorEpoch = try string(previous, "collector_epoch")
        let authority = try nonnegativeInteger(previous, "authority_generation")
        let sequence = try nonnegativeInteger(previous, "sequence")
        guard authority > 0, sequence > 0, case .blob(let manifest) = (previous["manifest_json"] as DatabaseValue).storage,
              let publication = try CaptureIngestLedger.publication(db, sha256: priorDigest),
              exact(publication.machineID, native.machineID), exact(publication.sourceInstanceID, native.sourceInstanceID),
              exact(publication.collectorEpoch, priorEpoch), publication.sequence == sequence,
              exact(ArchiveV2Hash.sha256(manifest), publication.manifestSHA256),
              try CaptureIngestSourceRegistry.history(db, machineID: native.machineID, sourceInstanceID: native.sourceInstanceID)
                .contains(where: { $0.authorityGeneration == authority && exact($0.approvedEpoch, priorEpoch) }) else {
            throw CaptureIngestCommitError.invalidStoredRecord
        }
        do { try validateParserRevision(priorRevision) }
        catch { throw CaptureIngestCommitError.invalidStoredRecord }
        guard binding.authorityGeneration >= authority else { throw CaptureIngestCommitError.staleGeneration }
        if binding.authorityGeneration == authority {
            guard claim.publication.sequence >= sequence else { throw CaptureIngestCommitError.staleGeneration }
            if claim.publication.sequence == sequence {
                guard exact(claim.publicationSHA256, priorDigest) else { throw CaptureIngestCommitError.sequenceConflict }
                guard !exact(claim.parserRevision, priorRevision) else { throw CaptureIngestCommitError.staleGeneration }
            }
        }
    }

    private static func nextSyncVersion(
        _ db: Database, native: CaptureIngestIdentity, storedID: String, previousVersion: Int64
    ) throws -> Int {
        var maximum = previousVersion
        if let session = try Row.fetchOne(db, sql: "SELECT sync_version FROM sessions WHERE id = ?", arguments: [storedID]) {
            maximum = max(maximum, try nonnegativeInteger(session, "sync_version"))
        }
        guard let history = try Row.fetchOne(db, sql: """
            SELECT MAX(sync_version) AS maximum_version,
                COUNT(CASE WHEN typeof(machine_id) != 'text' OR machine_id COLLATE BINARY != ?
                    OR typeof(source_instance_id) != 'text' OR source_instance_id COLLATE BINARY != ?
                    OR typeof(source) != 'text' OR source COLLATE BINARY != ?
                    OR typeof(native_id) != 'text' OR native_id COLLATE BINARY != ?
                    OR typeof(sync_version) != 'integer' OR sync_version <= 0 THEN 1 END) AS invalid_count
            FROM capture_ingest_generations WHERE stored_session_id = ?
            """, arguments: [native.machineID, native.sourceInstanceID, native.source.rawValue, native.nativeID, storedID]),
              try nonnegativeInteger(history, "invalid_count") == 0 else {
            throw CaptureIngestCommitError.invalidStoredRecord
        }
        if !(history["maximum_version"] as DatabaseValue).isNull {
            maximum = max(maximum, try nonnegativeInteger(history, "maximum_version"))
        }
        let (next, overflow) = maximum.addingReportingOverflow(1)
        guard !overflow, let version = Int(exactly: next) else { throw CaptureIngestCommitError.syncVersionOverflow }
        return version
    }

    private static func resolvedParent(_ db: Database, native: CaptureIngestIdentity?) throws -> String? {
        guard let native, let binding = try identityRow(db, native: native) else { return nil }
        let storedID = try string(binding, "stored_session_id")
        guard exact(storedID, try native.proposedSessionID()),
              try optionalString(binding, "last_parsed_generation_id") != nil,
              let parent = try Row.fetchOne(db, sql: "SELECT authoritative_node, source FROM sessions WHERE id = ?",
                                            arguments: [storedID]),
              exact(try string(parent, "authoritative_node"), native.peer),
              exact(try string(parent, "source"), native.source.rawValue) else {
            throw CaptureIngestCommitError.identityConflict
        }
        return storedID
    }

    private static func requireIdentity(_ row: Row, native: CaptureIngestIdentity) throws {
        guard exact(try string(row, "machine_id"), native.machineID),
              exact(try string(row, "source_instance_id"), native.sourceInstanceID),
              exact(try string(row, "source"), native.source.rawValue),
              exact(try string(row, "native_id"), native.nativeID) else {
            throw CaptureIngestCommitError.invalidStoredRecord
        }
    }

    private static func nonnegativeInteger(_ row: Row, _ column: String) throws -> Int64 {
        guard case .int64(let value) = (row[column] as DatabaseValue).storage, value >= 0 else {
            throw CaptureIngestCommitError.invalidStoredRecord
        }
        return value
    }

    private static func string(_ row: Row, _ column: String) throws -> String {
        guard case .string(let value) = (row[column] as DatabaseValue).storage else {
            throw CaptureIngestCommitError.invalidStoredRecord
        }
        return value
    }

    private static func optionalString(_ row: Row, _ column: String) throws -> String? {
        (row[column] as DatabaseValue).isNull ? nil : try string(row, column)
    }

    private static func validateParserRevision(_ revision: String) throws {
        guard !revision.isEmpty, revision.utf8.count <= 128, !revision.utf8.contains(0),
              revision == revision.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw CaptureIngestCommitError.invalidParserRevision
        }
    }

    private static func exact(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
}
