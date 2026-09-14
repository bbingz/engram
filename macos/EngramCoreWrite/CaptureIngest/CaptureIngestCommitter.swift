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
    /// A valid same-authority publication predates the current identity head.
    case obsoleteGeneration
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
    public static let normalizedStorageVersionV1 = 1
    public static let normalizedStorageVersionV2 = 2
    public static let maximumNormalizedStorageMessages = 100_000
    public static let maximumNormalizedStorageBytes = 1024 * 1024 * 1024
    public static let maximumNormalizedMessageBytes = 128 * 1024 * 1024

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
            let stored = try normalizedStorage(replay.scan.messages)
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
            try CaptureIngestFileActivity.replace(db, sessionID: storedID, messages: scan.messages)
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
                    normalized_message_count, normalized_storage_version, normalized_total_message_count,
                    sync_version, snapshot_hash, required_fts_job_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    generationID, claim.publicationSHA256, claim.parserRevision, native.machineID, native.sourceInstanceID,
                    native.source.rawValue, binding.parseFormat.rawValue, binding.configuredRoot, claim.publication.collectorEpoch,
                    binding.authorityGeneration, claim.publication.sequence, native.nativeID, replay.rawSourceSessionID, storedID,
                    replay.parentIdentity?.nativeID, replay.suggestedParentIdentity?.nativeID, manifestBytes, normalizedSchemaVersion,
                    stored.parentBlob, ArchiveV2Hash.sha256(stored.parentBlob), stored.legacyMessageCount,
                    stored.storageVersion, stored.totalMessageCount, version, snapshot.snapshotHash, jobID, indexedAt,
                ])
            for row in stored.rows {
                try db.execute(sql: """
                    INSERT INTO capture_ingest_generation_messages(
                        generation_id, ordinal, message_json, message_sha256, message_byte_size)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [generationID, row.ordinal, row.bytes, row.sha256, row.bytes.count])
            }
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
            CREATE TABLE IF NOT EXISTS capture_ingest_generation_messages (
                generation_id TEXT NOT NULL REFERENCES capture_ingest_generations(generation_id),
                ordinal INTEGER NOT NULL CHECK (ordinal >= 0 AND ordinal < \(maximumNormalizedStorageMessages)),
                message_json BLOB NOT NULL CHECK (length(message_json) <= \(maximumNormalizedMessageBytes)),
                message_sha256 TEXT NOT NULL,
                message_byte_size INTEGER NOT NULL
                    CHECK (message_byte_size >= 0 AND message_byte_size <= \(maximumNormalizedMessageBytes)),
                PRIMARY KEY (generation_id, ordinal)
            );
            """)
        try addNormalizedStorageColumnsIfNeeded(db)
        // Ready-count metadata follows large transcript BLOBs in the table row.
        // Cover every authority scalar so overview reads never visit overflow pages.
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS capture_ingest_generations_ready_metadata
            ON capture_ingest_generations (
                generation_id, authority_generation, collector_epoch, configured_root,
                machine_id, native_id, parse_format, parser_revision, publication_sha256,
                sequence, snapshot_hash, source, source_instance_id, stored_session_id, sync_version
            )
            """)
    }

    static func addNormalizedStorageColumnsIfNeeded(_ db: Database) throws {
        let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(capture_ingest_generations)").map { $0["name"] as String })
        if !columns.contains("normalized_storage_version") {
            try db.execute(sql: """
                ALTER TABLE capture_ingest_generations ADD COLUMN normalized_storage_version
                    INTEGER NOT NULL DEFAULT \(normalizedStorageVersionV1)
                    CHECK (normalized_storage_version IN (\(normalizedStorageVersionV1), \(normalizedStorageVersionV2)))
                """)
        }
        if !columns.contains("normalized_total_message_count") {
            try db.execute(sql: """
                ALTER TABLE capture_ingest_generations ADD COLUMN normalized_total_message_count INTEGER
                    CHECK (normalized_total_message_count IS NULL
                        OR (normalized_total_message_count BETWEEN 0 AND \(maximumNormalizedStorageMessages)))
                """)
        }
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
        let manifest = replay.verifiedManifest
        let nativeSize: Int64
        if scan.info.source == .geminiCli || scan.info.source == .vscode || scan.info.source == .grok {
            // Native Gemini, VSCode, and Grok report transcript size; auxiliary
            // files remain independently verified members of the complete capture.
            guard (scan.info.source == .geminiCli && ArchiveSourceDescriptor.isGeminiFileSet(manifest))
                    || (scan.info.source == .vscode && ArchiveSourceDescriptor.isVSCodeFileSet(manifest))
                    || (scan.info.source == .grok && ArchiveSourceDescriptor.isGrokFileSet(manifest)),
                  let primary = manifest.replayLayout.files?.first(where: {
                      $0.relativePath.utf8.elementsEqual((manifest.replayLayout.entrypointRelativePath ?? "").utf8)
                  }) else { throw CaptureIngestCommitError.invalidReplay }
            nativeSize = primary.rawByteCount
        } else if scan.info.source == .kimi {
            guard ArchiveSourceDescriptor.isKimiFileSet(manifest),
                  let context = manifest.replayLayout.kimiProjectContext,
                  exact(scan.info.id, context.nativeSessionID),
                  exact(replay.rawSourceSessionID, context.nativeSessionID),
                  exact(scan.info.cwd, context.cwd),
                  let files = manifest.replayLayout.files else {
                throw CaptureIngestCommitError.invalidReplay
            }
            // Native Kimi reports context bytes; wire is separately captured
            // timing/usage evidence and must not inflate the session size.
            nativeSize = try files.filter { !$0.relativePath.hasSuffix("/wire.jsonl") }.reduce(Int64(0)) {
                let sum = $0.addingReportingOverflow($1.rawByteCount)
                guard !sum.overflow else { throw CaptureIngestCommitError.invalidReplay }
                return sum.partialValue
            }
        } else if scan.info.source == .cursor, ArchiveSourceDescriptor.isCursorLegacySession(manifest) {
            guard let context = manifest.replayLayout.cursorLegacySession,
                  exact(scan.info.id, context.composerID), exact(replay.rawSourceSessionID, context.composerID),
                  exact(scan.info.cwd, context.cwd) else { throw CaptureIngestCommitError.invalidReplay }
            // Invalid UTF-8 can expand native size beyond both raw row bytes
            // and encoded body length. Replay checked this summary against CAS.
            nativeSize = context.nativePayloadByteCount
        } else if scan.info.source == .cursor {
            guard ArchiveSourceDescriptor.isCursorModernFileSet(manifest),
                  let nativeID = ArchiveSourceDescriptor.cursorModernSessionID(manifest.replayLayout, locator: manifest.locator),
                  exact(scan.info.id, nativeID), exact(replay.rawSourceSessionID, nativeID),
                  let files = manifest.replayLayout.files else {
                throw CaptureIngestCommitError.invalidReplay
            }
            // Native Cursor attributes main database and transcript bytes to
            // the session; captured WAL and metadata remain replay inputs.
            nativeSize = try files.filter {
                $0.relativePath.hasSuffix("/store.db") || $0.relativePath.hasSuffix(".jsonl")
            }.reduce(Int64(0)) {
                let sum = $0.addingReportingOverflow($1.rawByteCount)
                guard !sum.overflow else { throw CaptureIngestCommitError.invalidReplay }
                return sum.partialValue
            }
        } else if scan.info.source == .antigravity {
            guard ArchiveSourceDescriptor.isAntigravityCLITranscript(manifest),
                  let nativeID = manifest.replayLayout.relativePaths[0].split(separator: "/").first,
                  exact(scan.info.id, String(nativeID)),
                  exact(replay.rawSourceSessionID, String(nativeID)) else {
                throw CaptureIngestCommitError.invalidReplay
            }
            nativeSize = manifest.rawByteCount
        } else if scan.info.source == .windsurf {
            guard ArchiveSourceDescriptor.isWindsurfHookTranscript(manifest),
                  let nativeID = ArchiveSourceDescriptor.windsurfHookNativeID(logicalLocator: manifest.locator),
                  exact(scan.info.id, nativeID),
                  exact(replay.rawSourceSessionID, nativeID) else {
                throw CaptureIngestCommitError.invalidReplay
            }
            nativeSize = manifest.rawByteCount
        } else if scan.info.source == .opencode {
            guard ArchiveSourceDescriptor.isOpenCodeSessionImage(manifest),
                  let session = manifest.replayLayout.sqliteSession,
                  exact(scan.info.id, session.nativeSessionID),
                  exact(replay.rawSourceSessionID, session.nativeSessionID) else {
                throw CaptureIngestCommitError.invalidReplay
            }
            nativeSize = session.nativePayloadByteCount
        } else {
            nativeSize = manifest.rawByteCount
        }
        guard scan.parseFailure == nil, scan.info.source == replay.bindingSnapshot.source,
              exact(scan.info.filePath, manifest.locator),
              scan.info.sizeBytes == nativeSize else {
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

    private struct PreparedNormalizedStorage {
        let parentBlob: Data
        let legacyMessageCount: Int
        let storageVersion: Int
        let totalMessageCount: Int?
        let rows: [(ordinal: Int, bytes: Data, sha256: String)]
    }

    private static func normalizedStorage(_ messages: [NormalizedMessage]) throws -> PreparedNormalizedStorage {
        guard messages.count <= maximumNormalizedStorageMessages else { throw CaptureIngestCommitError.tooManyMessages }
        if messages.count <= maximumNormalizedMessages {
            do {
                try rejectIfEncodedArrayWouldExceedLegacyBudget(messages)
                let bytes = try ArchiveCanonicalJSON.encode(messages)
                if bytes.count <= maximumNormalizedPayloadBytes {
                    return PreparedNormalizedStorage(parentBlob: bytes, legacyMessageCount: messages.count,
                        storageVersion: normalizedStorageVersionV1, totalMessageCount: nil, rows: [])
                }
            } catch CaptureIngestCommitError.normalizedPayloadTooLarge {
                // Above the legacy 100MiB array budget: persist v2 rows instead.
            }
        }
        return try preparedV2Storage(messages)
    }

    private static func rejectIfEncodedArrayWouldExceedLegacyBudget(_ messages: [NormalizedMessage]) throws {
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
    }

    private static func rejectIfV2RawBytesExceedStorageBudget(_ messages: [NormalizedMessage]) throws {
        var aggregate = 0
        for message in messages {
            var messageBytes = 0
            func include(_ text: String?) throws {
                guard let text else { return }
                let bytes = text.utf8.count
                let (next, overflow) = messageBytes.addingReportingOverflow(bytes)
                guard !overflow, next <= maximumNormalizedMessageBytes else {
                    throw CaptureIngestCommitError.normalizedPayloadTooLarge
                }
                messageBytes = next
            }
            try include(message.content)
            try include(message.timestamp)
            for tool in message.toolCalls ?? [] {
                try include(tool.name)
                try include(tool.input)
                try include(tool.output)
            }
            let (next, overflow) = aggregate.addingReportingOverflow(messageBytes)
            guard !overflow, next <= maximumNormalizedStorageBytes else {
                throw CaptureIngestCommitError.normalizedPayloadTooLarge
            }
            aggregate = next
        }
    }

    private static func preparedV2Storage(_ messages: [NormalizedMessage]) throws -> PreparedNormalizedStorage {
        try rejectIfV2RawBytesExceedStorageBudget(messages)
        var rows: [(ordinal: Int, bytes: Data, sha256: String)] = []
        rows.reserveCapacity(messages.count)
        var totalBytes = 0
        var digests: [CaptureIngestNormalizedMessageDigest] = []
        digests.reserveCapacity(messages.count)
        for (ordinal, message) in messages.enumerated() {
            let bytes = try ArchiveCanonicalJSON.encode(message)
            guard bytes.count <= maximumNormalizedMessageBytes else {
                throw CaptureIngestCommitError.normalizedPayloadTooLarge
            }
            let (next, overflow) = totalBytes.addingReportingOverflow(bytes.count)
            guard !overflow, next <= maximumNormalizedStorageBytes else {
                throw CaptureIngestCommitError.normalizedPayloadTooLarge
            }
            totalBytes = next
            let digest = ArchiveV2Hash.sha256(bytes)
            rows.append((ordinal, bytes, digest))
            digests.append(CaptureIngestNormalizedMessageDigest(sha256: digest, byteSize: bytes.count, role: message.role))
        }
        let parentBlob = try ArchiveCanonicalJSON.encode(digests)
        guard parentBlob.count <= maximumNormalizedPayloadBytes else {
            throw CaptureIngestCommitError.normalizedPayloadTooLarge
        }
        return PreparedNormalizedStorage(parentBlob: parentBlob, legacyMessageCount: 0,
            storageVersion: normalizedStorageVersionV2, totalMessageCount: messages.count, rows: rows)
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
            guard claim.publication.sequence >= sequence else { throw CaptureIngestCommitError.obsoleteGeneration }
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
