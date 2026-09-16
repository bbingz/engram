import Foundation
import EngramCoreRead
import GRDB

public enum CaptureIngestReadinessError: Error, Equatable {
    case invalidArgument
    case invalidParserRevision
    case parserRevisionChanged
    case sourceDisabled
    case bindingChanged
    case staleGeneration
    case currentSnapshotMismatch
    case requiredJobChanged
    case invalidStoredRecord
    case normalizedPayloadTooLarge
    case tooManyMessages
    case deadlineExceeded
}

/// Owned normalized values, not a continuing source/readiness authorization.
/// There is deliberately no public initializer. The caller must supply fresh
/// parser and enabled-source authority again when completing the exact job.
public struct CaptureIngestNormalizedSnapshot: Equatable, Sendable {
    public let sessionID: String
    public let generationID: String
    public let publicationSHA256: String
    public let parserRevision: String
    public let nativeIdentity: CaptureIngestIdentity
    public let bindingSnapshot: CaptureIngestSourceBinding
    public let syncVersion: Int
    public let snapshotHash: String
    public let requiredFTSJobID: String?
    public let normalizedMessagesSHA256: String
    public let messages: [NormalizedMessage]
    public let messageStartOrdinal: Int
    public let totalMessageCount: Int
}

struct CaptureIngestNormalizedMessageDigest: Codable, Equatable, Sendable {
    let sha256: String
    let byteSize: Int
    let role: NormalizedMessageRole
}

/// Reads one current parsed artifact without adapters, filesystem replay, writes,
/// or Web admission. Raw normalized fields remain complete and unredacted here.
public enum CaptureIngestNormalizedStore {
    /// Metadata/type/length budgets must pass before fetching the payload BLOB.
    /// Cancellation/deadline checkpoints bound result acceptance at each stage;
    /// synchronous canonical JSON decoding is not interruptible mid-operation.
    /// Actual authority freshness requires the later service/gate integration.
    public static func load(
        _ db: Database,
        sessionID: String,
        generationID: String,
        expectedParserRevision: String,
        enabledSources: Set<SourceName>,
        deadline: ContinuousClock.Instant? = nil,
        messageRange: Range<Int>? = nil
    ) throws -> CaptureIngestNormalizedSnapshot {
        let metadata = try currentMetadata(db, sessionID: sessionID, generationID: generationID,
            expectedParserRevision: expectedParserRevision, enabledSources: enabledSources, deadline: deadline)
        try checkpoint(deadline)
        if let messageRange {
            guard messageRange.lowerBound >= 0, messageRange.upperBound <= metadata.messageCount else {
                throw CaptureIngestReadinessError.invalidArgument
            }
        }
        let bytes = try parentNormalizedBlob(db, generationID: generationID, metadata: metadata)
        try checkpoint(deadline)
        let start = messageRange?.lowerBound ?? 0
        let messages: [NormalizedMessage]
        if metadata.storageVersion == CaptureIngestCommitter.normalizedStorageVersionV2 {
            messages = try loadV2Messages(db, generationID: generationID, manifestBytes: bytes,
                metadata: metadata, messageRange: messageRange, deadline: deadline)
        } else {
            do { messages = try decodeV1Messages(bytes, metadata: metadata, messageRange: messageRange) }
            catch { throw CaptureIngestReadinessError.invalidStoredRecord }
        }
        try checkpoint(deadline)
        return snapshot(sessionID: sessionID, generationID: generationID, metadata: metadata,
            messages: messages, start: start)
    }

    /// Role-filtered page from a verified manifest (v2) or the bounded v1 BLOB.
    /// Selects matching ordinals until `maximumPayloadBytes`, then one lookahead,
    /// never fewer than two when available and never more than `maximumMessages`.
    /// Fetches only those v2 rows. `hasMore` is further matching manifest entries.
    public static func loadPage(
        _ db: Database,
        sessionID: String,
        generationID: String,
        expectedParserRevision: String,
        enabledSources: Set<SourceName>,
        fromOrdinal: Int,
        maximumMessages: Int,
        roles: Set<NormalizedMessageRole>,
        deadline: ContinuousClock.Instant? = nil,
        maximumPayloadBytes: Int = 1024 * 1024
    ) throws -> (snapshot: CaptureIngestNormalizedSnapshot, ordinals: [Int], hasMore: Bool) {
        let metadata = try currentMetadata(db, sessionID: sessionID, generationID: generationID,
            expectedParserRevision: expectedParserRevision, enabledSources: enabledSources, deadline: deadline)
        try checkpoint(deadline)
        guard fromOrdinal >= 0, fromOrdinal <= metadata.messageCount, maximumMessages > 0,
              maximumPayloadBytes > 0 else {
            throw CaptureIngestReadinessError.invalidArgument
        }
        let bytes = try parentNormalizedBlob(db, generationID: generationID, metadata: metadata)
        try checkpoint(deadline)
        let ordinals: [Int]
        let hasMore: Bool
        let messages: [NormalizedMessage]
        if metadata.storageVersion == CaptureIngestCommitter.normalizedStorageVersionV2 {
            let digests = try validatedV2Manifest(bytes, metadata: metadata)
            (ordinals, hasMore) = try selectedPageOrdinals(from: fromOrdinal, maximumMessages: maximumMessages,
                maximumPayloadBytes: maximumPayloadBytes, roles: roles, rolesAt: { digests[$0].role },
                sizeAt: { digests[$0].byteSize }, count: metadata.messageCount)
            messages = ordinals.isEmpty ? [] : try loadV2MessagesAtOrdinals(db, generationID: generationID,
                digests: digests, ordinals: ordinals)
        } else {
            let all: [NormalizedMessage]
            do { all = try decodeV1Messages(bytes, metadata: metadata, messageRange: nil) }
            catch { throw CaptureIngestReadinessError.invalidStoredRecord }
            (ordinals, hasMore) = try selectedPageOrdinals(from: fromOrdinal, maximumMessages: maximumMessages,
                maximumPayloadBytes: maximumPayloadBytes, roles: roles, rolesAt: { all[$0].role },
                sizeAt: { try ArchiveCanonicalJSON.encode(all[$0]).count }, count: metadata.messageCount)
            messages = ordinals.map { all[$0] }
        }
        try checkpoint(deadline)
        return (snapshot(sessionID: sessionID, generationID: generationID, metadata: metadata,
            messages: messages, start: ordinals.first ?? fromOrdinal), ordinals, hasMore)
    }

    // Shared only by the load and readiness transaction in this module. This is
    // current database evidence, not an independently reusable authorization.
    struct Metadata {
        let publicationSHA256: String
        let parserRevision: String
        let nativeIdentity: CaptureIngestIdentity
        let binding: CaptureIngestSourceBinding
        let syncVersion: Int
        let snapshotHash: String
        let requiredFTSJobID: String?
        let normalizedSHA256: String
        let payloadBytes: Int
        let messageCount: Int
        let storageVersion: Int
        let tier: SessionTier
        let summary: String?
        let ledgerStatus: String
        let readyGenerationID: String?
    }

    static func currentMetadata(
        _ db: Database, sessionID: String, generationID: String, expectedParserRevision: String,
        enabledSources: Set<SourceName>, deadline: ContinuousClock.Instant?
    ) throws -> Metadata {
        try checkpoint(deadline)
        guard !sessionID.isEmpty, !sessionID.utf8.contains(0), ArchiveV2Hash.isValidSHA256(generationID) else {
            throw CaptureIngestReadinessError.invalidArgument
        }
        try validateParserRevision(expectedParserRevision)
        // Never SELECT * here. In particular, SQLite can inspect BLOB type and
        // length without delivering the normalized transcript into Swift.
        guard let row = try Row.fetchOne(db, sql: """
            SELECT generation_id, publication_sha256, parser_revision, machine_id, source_instance_id,
                source, parse_format, configured_root, collector_epoch, authority_generation, sequence,
                native_id, stored_session_id, sync_version, snapshot_hash, required_fts_job_id,
                normalized_schema_version, normalized_storage_version, normalized_message_count,
                normalized_total_message_count, normalized_messages_sha256,
                length(normalized_messages_json) AS payload_bytes,
                typeof(normalized_messages_json) AS payload_type,
                length(manifest_json) AS manifest_bytes, typeof(manifest_json) AS manifest_type
            FROM capture_ingest_generations WHERE generation_id = ? AND stored_session_id = ?
            """, arguments: [generationID, sessionID]) else { throw CaptureIngestReadinessError.staleGeneration }
        let payloadBytes = try integer(row, "payload_bytes")
        let storageVersion = try integer(row, "normalized_storage_version")
        let legacyCount = try integer(row, "normalized_message_count")
        let totalCount = try optionalInteger(row, "normalized_total_message_count")
        let messageCount: Int64
        guard payloadBytes >= 0, legacyCount >= 0,
              try string(row, "payload_type") == "blob",
              try integer(row, "normalized_schema_version") == Int64(CaptureIngestCommitter.normalizedSchemaVersion) else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        switch storageVersion {
        case Int64(CaptureIngestCommitter.normalizedStorageVersionV1):
            guard totalCount == nil else { throw CaptureIngestReadinessError.invalidStoredRecord }
            guard legacyCount <= Int64(CaptureIngestCommitter.maximumNormalizedMessages) else {
                throw CaptureIngestReadinessError.tooManyMessages
            }
            messageCount = legacyCount
        case Int64(CaptureIngestCommitter.normalizedStorageVersionV2):
            guard legacyCount == 0, let totalCount, totalCount >= 0 else {
                throw CaptureIngestReadinessError.invalidStoredRecord
            }
            guard totalCount <= Int64(CaptureIngestCommitter.maximumNormalizedStorageMessages) else {
                throw CaptureIngestReadinessError.tooManyMessages
            }
            messageCount = totalCount
        default:
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        guard payloadBytes <= CaptureIngestCommitter.maximumNormalizedPayloadBytes else {
            throw CaptureIngestReadinessError.normalizedPayloadTooLarge
        }
        let parser = try string(row, "parser_revision")
        guard exact(parser, expectedParserRevision) else { throw CaptureIngestReadinessError.parserRevisionChanged }
        let publicationSHA = try string(row, "publication_sha256")
        let normalizedSHA = try string(row, "normalized_messages_sha256")
        let snapshotHash = try string(row, "snapshot_hash")
        guard ArchiveV2Hash.isValidSHA256(publicationSHA), ArchiveV2Hash.isValidSHA256(normalizedSHA),
              ArchiveV2Hash.isValidSHA256(snapshotHash),
              exact(try string(row, "generation_id"), generationID),
              exact(try string(row, "stored_session_id"), sessionID),
              ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode([publicationSHA, parser])) == generationID,
              let source = SourceName(rawValue: try string(row, "source")),
              let format = CaptureIngestParseFormat(rawValue: try string(row, "parse_format")) else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        guard enabledSources.contains(source) else { throw CaptureIngestReadinessError.sourceDisabled }
        let native: CaptureIngestIdentity
        do {
            native = try CaptureIngestIdentity(machineID: string(row, "machine_id"),
                sourceInstanceID: string(row, "source_instance_id"), source: source, nativeID: string(row, "native_id"))
        } catch { throw CaptureIngestReadinessError.invalidStoredRecord }
        let authority = try integer(row, "authority_generation")
        let sequence = try integer(row, "sequence")
        let version = try integer(row, "sync_version")
        let storedEpoch = try string(row, "collector_epoch")
        guard authority > 0, sequence > 0, version > 0, let syncVersion = Int(exactly: version),
              UUID(uuidString: storedEpoch)?.uuidString == storedEpoch else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        let binding = CaptureIngestSourceBinding(machineID: native.machineID, sourceInstanceID: native.sourceInstanceID,
            source: source, parseFormat: format, configuredRoot: try string(row, "configured_root"),
            approvedEpoch: storedEpoch, authorityGeneration: authority)
        try requireBinding(db, row: row, publicationSHA: publicationSHA, binding: binding, sequence: sequence)
        try checkpoint(deadline)
        guard let identity = try Row.fetchOne(db, sql: """
            SELECT machine_id, source_instance_id, source, native_id, stored_session_id,
                last_parsed_generation_id, last_ready_generation_id, last_sync_version
            FROM capture_ingest_identity_bindings WHERE stored_session_id = ?
            """, arguments: [sessionID]),
              exact(try string(identity, "machine_id"), native.machineID),
              exact(try string(identity, "source_instance_id"), native.sourceInstanceID),
              exact(try string(identity, "source"), source.rawValue),
              exact(try string(identity, "native_id"), native.nativeID),
              exact(try string(identity, "stored_session_id"), sessionID) else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        guard let parsedHead = try optionalString(identity, "last_parsed_generation_id"), exact(parsedHead, generationID) else {
            throw CaptureIngestReadinessError.staleGeneration
        }
        guard try integer(identity, "last_sync_version") == version else { throw CaptureIngestReadinessError.invalidStoredRecord }
        let readyHead = try optionalString(identity, "last_ready_generation_id")
        guard readyHead == nil || ArchiveV2Hash.isValidSHA256(readyHead!) else { throw CaptureIngestReadinessError.invalidStoredRecord }
        guard let session = try Row.fetchOne(db, sql: """
            SELECT authoritative_node, source, sync_version, snapshot_hash, tier, summary FROM sessions WHERE id = ?
            """, arguments: [sessionID]),
              case .string(let owner) = (session["authoritative_node"] as DatabaseValue).storage, exact(owner, native.peer),
              case .string(let storedSource) = (session["source"] as DatabaseValue).storage, exact(storedSource, source.rawValue),
              case .int64(let currentVersion) = (session["sync_version"] as DatabaseValue).storage, currentVersion == version,
              case .string(let currentHash) = (session["snapshot_hash"] as DatabaseValue).storage, exact(currentHash, snapshotHash),
              case .string(let rawTier) = (session["tier"] as DatabaseValue).storage, let tier = SessionTier(rawValue: rawTier) else {
            throw CaptureIngestReadinessError.currentSnapshotMismatch
        }
        guard let ledger = try Row.fetchOne(db, sql: """
            SELECT status, failure_code, claim_token, claim_started_at, claim_expires_at, retry_after
            FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?
            """, arguments: [publicationSHA, parser]) else { throw CaptureIngestReadinessError.invalidStoredRecord }
        let status = try string(ledger, "status")
        guard status == "parsed" || (status == "index_ready" && readyHead == generationID),
              ["failure_code", "claim_token", "claim_started_at", "claim_expires_at", "retry_after"].allSatisfy({
                  (ledger[$0] as DatabaseValue).isNull
              }) else { throw CaptureIngestReadinessError.invalidStoredRecord }
        return Metadata(publicationSHA256: publicationSHA, parserRevision: parser, nativeIdentity: native, binding: binding,
            syncVersion: syncVersion, snapshotHash: snapshotHash, requiredFTSJobID: try optionalString(row, "required_fts_job_id"),
            normalizedSHA256: normalizedSHA, payloadBytes: Int(payloadBytes), messageCount: Int(messageCount),
            storageVersion: Int(storageVersion), tier: tier,
            summary: try optionalString(session, "summary"), ledgerStatus: status, readyGenerationID: readyHead)
    }

    private static func snapshot(
        sessionID: String, generationID: String, metadata: Metadata,
        messages: [NormalizedMessage], start: Int
    ) -> CaptureIngestNormalizedSnapshot {
        CaptureIngestNormalizedSnapshot(sessionID: sessionID, generationID: generationID,
            publicationSHA256: metadata.publicationSHA256, parserRevision: metadata.parserRevision,
            nativeIdentity: metadata.nativeIdentity, bindingSnapshot: metadata.binding,
            syncVersion: metadata.syncVersion, snapshotHash: metadata.snapshotHash,
            requiredFTSJobID: metadata.requiredFTSJobID, normalizedMessagesSHA256: metadata.normalizedSHA256,
            messages: messages, messageStartOrdinal: start, totalMessageCount: metadata.messageCount)
    }

    private static func parentNormalizedBlob(
        _ db: Database, generationID: String, metadata: Metadata
    ) throws -> Data {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT normalized_messages_json FROM capture_ingest_generations WHERE generation_id = ?
            """, arguments: [generationID]),
              case .blob(let bytes) = (row["normalized_messages_json"] as DatabaseValue).storage,
              bytes.count == metadata.payloadBytes,
              ArchiveV2Hash.sha256(bytes) == metadata.normalizedSHA256 else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        return bytes
    }

    private static func decodeV1Messages(
        _ bytes: Data, metadata: Metadata, messageRange: Range<Int>?
    ) throws -> [NormalizedMessage] {
        let messages = try ArchiveCanonicalJSON.decode([NormalizedMessage].self, from: bytes)
        guard messages.count == metadata.messageCount else { throw CaptureIngestReadinessError.invalidStoredRecord }
        guard let messageRange else { return messages }
        return Array(messages[messageRange])
    }

    private static func validatedV2Manifest(
        _ manifestBytes: Data, metadata: Metadata
    ) throws -> [CaptureIngestNormalizedMessageDigest] {
        let digests: [CaptureIngestNormalizedMessageDigest]
        do { digests = try ArchiveCanonicalJSON.decode([CaptureIngestNormalizedMessageDigest].self, from: manifestBytes) }
        catch { throw CaptureIngestReadinessError.invalidStoredRecord }
        guard digests.count == metadata.messageCount else { throw CaptureIngestReadinessError.invalidStoredRecord }
        for digest in digests {
            guard ArchiveV2Hash.isValidSHA256(digest.sha256), digest.byteSize >= 0,
                  digest.byteSize <= CaptureIngestCommitter.maximumNormalizedMessageBytes else {
                throw CaptureIngestReadinessError.invalidStoredRecord
            }
        }
        return digests
    }

    private static func selectedPageOrdinals(
        from fromOrdinal: Int, maximumMessages: Int, maximumPayloadBytes: Int,
        roles: Set<NormalizedMessageRole>, rolesAt: (Int) -> NormalizedMessageRole,
        sizeAt: (Int) throws -> Int, count: Int
    ) throws -> (ordinals: [Int], hasMore: Bool) {
        guard fromOrdinal < count else { return ([], false) }
        var ordinals: [Int] = []
        var bytes = 0
        var cursor = fromOrdinal
        while cursor < count {
            guard roles.contains(rolesAt(cursor)) else {
                cursor += 1
                continue
            }
            if ordinals.count >= maximumMessages { break }
            let size = try sizeAt(cursor)
            let (sum, overflow) = bytes.addingReportingOverflow(size)
            if ordinals.count >= 2 && (overflow || sum > maximumPayloadBytes) {
                ordinals.append(cursor)
                cursor += 1
                break
            }
            ordinals.append(cursor)
            bytes = overflow ? Int.max : sum
            cursor += 1
        }
        let hasMore = (cursor..<count).contains { roles.contains(rolesAt($0)) }
        return (ordinals, hasMore)
    }

    private static func loadV2Messages(
        _ db: Database, generationID: String, manifestBytes: Data, metadata: Metadata,
        messageRange: Range<Int>?, deadline: ContinuousClock.Instant?
    ) throws -> [NormalizedMessage] {
        let digests = try validatedV2Manifest(manifestBytes, metadata: metadata)
        try checkpoint(deadline)
        if messageRange == nil {
            guard let countRow = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS row_count FROM capture_ingest_generation_messages WHERE generation_id = ?
                """, arguments: [generationID]),
                  try integer(countRow, "row_count") == Int64(digests.count) else {
                throw CaptureIngestReadinessError.invalidStoredRecord
            }
        }
        let selection = messageRange ?? 0..<metadata.messageCount
        if selection.isEmpty { return [] }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT ordinal, message_json, message_sha256, message_byte_size
            FROM capture_ingest_generation_messages
            WHERE generation_id = ? AND ordinal >= ? AND ordinal < ?
            ORDER BY ordinal
            """, arguments: [generationID, selection.lowerBound, selection.upperBound])
        var messages: [NormalizedMessage] = []
        messages.reserveCapacity(selection.count)
        var offset = 0
        while let row = try rows.next() {
            let ordinal = try integer(row, "ordinal")
            guard ordinal == Int64(selection.lowerBound + offset) else {
                throw CaptureIngestReadinessError.invalidStoredRecord
            }
            messages.append(try decodedV2Message(row, digest: digests[Int(ordinal)]))
            offset += 1
        }
        guard offset == selection.count else { throw CaptureIngestReadinessError.invalidStoredRecord }
        try checkpoint(deadline)
        return messages
    }

    private static func loadV2MessagesAtOrdinals(
        _ db: Database, generationID: String, digests: [CaptureIngestNormalizedMessageDigest],
        ordinals: [Int]
    ) throws -> [NormalizedMessage] {
        if ordinals.isEmpty { return [] }
        let placeholders = Array(repeating: "?", count: ordinals.count).joined(separator: ", ")
        var arguments: [any DatabaseValueConvertible] = [generationID]
        arguments.append(contentsOf: ordinals)
        let rows = try Row.fetchAll(db, sql: """
            SELECT ordinal, message_json, message_sha256, message_byte_size
            FROM capture_ingest_generation_messages
            WHERE generation_id = ? AND ordinal IN (\(placeholders))
            """, arguments: StatementArguments(arguments))
        guard rows.count == ordinals.count else { throw CaptureIngestReadinessError.invalidStoredRecord }
        var decoded: [Int: NormalizedMessage] = [:]
        decoded.reserveCapacity(rows.count)
        for row in rows {
            let ordinal = try integer(row, "ordinal")
            guard ordinal >= 0, ordinal < Int64(digests.count) else {
                throw CaptureIngestReadinessError.invalidStoredRecord
            }
            decoded[Int(ordinal)] = try decodedV2Message(row, digest: digests[Int(ordinal)])
        }
        return try ordinals.map { ordinal in
            guard let message = decoded[ordinal] else { throw CaptureIngestReadinessError.invalidStoredRecord }
            return message
        }
    }

    private static func decodedV2Message(
        _ row: Row, digest: CaptureIngestNormalizedMessageDigest
    ) throws -> NormalizedMessage {
        guard case .blob(let bytes) = (row["message_json"] as DatabaseValue).storage,
              bytes.count == digest.byteSize, try integer(row, "message_byte_size") == Int64(digest.byteSize),
              ArchiveV2Hash.sha256(bytes) == digest.sha256, exact(try string(row, "message_sha256"), digest.sha256) else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        let message: NormalizedMessage
        do { message = try ArchiveCanonicalJSON.decode(NormalizedMessage.self, from: bytes) }
        catch { throw CaptureIngestReadinessError.invalidStoredRecord }
        guard message.role == digest.role else { throw CaptureIngestReadinessError.invalidStoredRecord }
        return message
    }

    private static func requireBinding(
        _ db: Database, row: Row, publicationSHA: String, binding: CaptureIngestSourceBinding, sequence: Int64
    ) throws {
        let manifestBytes = try integer(row, "manifest_bytes")
        guard manifestBytes > 0, manifestBytes <= ArchiveV2ProtocolLimits.maxManifestBytes,
              try string(row, "manifest_type") == "blob",
              let publicationShape = try Row.fetchOne(db, sql: """
                SELECT typeof(canonical_bytes) AS payload_type, length(canonical_bytes) AS payload_bytes
                FROM capture_ingest_publications WHERE publication_sha256 = ?
                """, arguments: [publicationSHA]),
              try string(publicationShape, "payload_type") == "blob",
              try integer(publicationShape, "payload_bytes") > 0,
              try integer(publicationShape, "payload_bytes") <= CollectorPublicationProtocolLimits.maxPublicationBytes else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        let publication: CollectorPublicationEnvelope
        let manifest: ArchiveSourceManifest
        do {
            guard let storedPublication = try CaptureIngestLedger.publication(db, sha256: publicationSHA),
                  let data = try Data.fetchOne(db, sql: "SELECT manifest_json FROM capture_ingest_generations WHERE generation_id = ?",
                    arguments: [try string(row, "generation_id")]),
                  data.count == manifestBytes, ArchiveV2Hash.sha256(data) == storedPublication.manifestSHA256 else {
                throw CaptureIngestReadinessError.invalidStoredRecord
            }
            publication = storedPublication
            manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: data)
        } catch { throw CaptureIngestReadinessError.invalidStoredRecord }
        guard publication.machineID == binding.machineID, publication.sourceInstanceID == binding.sourceInstanceID,
              publication.collectorEpoch == binding.approvedEpoch, publication.sequence == sequence else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        guard let registry = try Row.fetchOne(db, sql: """
            SELECT machine_id, source_instance_id, source, parse_format, configured_root, approved_epoch, authority_generation
            FROM capture_ingest_source_registry WHERE machine_id = ? AND source_instance_id = ?
            """, arguments: [binding.machineID, binding.sourceInstanceID]) else { throw CaptureIngestReadinessError.bindingChanged }
        do {
            for column in ["machine_id", "source_instance_id", "source", "parse_format", "configured_root", "approved_epoch"] {
                _ = try string(registry, column)
            }
            _ = try integer(registry, "authority_generation")
            guard case .eligible(let current) = try CaptureIngestSourceRegistry.eligibility(db,
                publication: publication, verifiedManifest: manifest), current == binding else {
                throw CaptureIngestReadinessError.bindingChanged
            }
        } catch { throw CaptureIngestReadinessError.bindingChanged }
    }

    static func checkpoint(_ deadline: ContinuousClock.Instant?) throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw CaptureIngestReadinessError.deadlineExceeded }
    }

    static func validateParserRevision(_ revision: String) throws {
        guard !revision.isEmpty, revision.utf8.count <= 128, !revision.utf8.contains(0),
              exact(revision, revision.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CaptureIngestReadinessError.invalidParserRevision
        }
    }

    static func string(_ row: Row, _ column: String) throws -> String {
        guard case .string(let value) = (row[column] as DatabaseValue).storage else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        return value
    }

    static func optionalString(_ row: Row, _ column: String) throws -> String? {
        (row[column] as DatabaseValue).isNull ? nil : try string(row, column)
    }

    static func optionalInteger(_ row: Row, _ column: String) throws -> Int64? {
        (row[column] as DatabaseValue).isNull ? nil : try integer(row, column)
    }

    static func integer(_ row: Row, _ column: String) throws -> Int64 {
        guard case .int64(let value) = (row[column] as DatabaseValue).storage else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        return value
    }

    static func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
}
