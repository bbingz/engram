import Foundation
import EngramCoreRead
import GRDB

/// The exact generation accepted by the data-layer readiness transaction.
/// This receipt is not Web visibility or proof of a running production consumer.
public struct CaptureIngestReadyGeneration: Equatable, Sendable {
    public enum Disposition: String, Equatable, Sendable {
        case indexed
        case skipNotApplicable
    }

    public let sessionID: String
    public let generationID: String
    public let syncVersion: Int
    public let snapshotHash: String
    public let requiredFTSJobID: String?
    public let disposition: Disposition
}

public struct CaptureWeakReviewSkipRepairBatch: Equatable, Sendable {
    public var repaired: Int
    public var reviewedUnchanged: Int

    public init(repaired: Int, reviewedUnchanged: Int) {
        self.repaired = repaired
        self.reviewedUnchanged = reviewedUnchanged
    }
}

public enum CaptureIngestReadiness {
    private typealias Store = CaptureIngestNormalizedStore

    private static let reviewedMetadataPrefix = "capture_weak_review_skip_reviewed:"

    /// Bounded one-shot correction for current parsed capture heads that are
    /// skip only because the pre-fix weak review-probe scope matched. Does not
    /// rebuild snapshots, bump parser revision, or mutate stale/disabled heads.
    /// Each call attempts at most `limit` current heads (clamped to 8) and
    /// honors `deadline`; unprocessable heads consume an attempt and stay unmarked.
    public static func repairWeakReviewSkips(
        _ db: Database,
        expectedParserRevision: String,
        enabledSources: Set<SourceName>,
        deadline: ContinuousClock.Instant? = nil,
        limit: Int = 4
    ) throws -> CaptureWeakReviewSkipRepairBatch {
        try Store.checkpoint(deadline)
        try Store.validateParserRevision(expectedParserRevision)
        let batchLimit = min(max(limit, 0), 8)
        let sources = enabledSources.sorted { $0.rawValue < $1.rawValue }
        guard batchLimit > 0, !sources.isEmpty else {
            return CaptureWeakReviewSkipRepairBatch(repaired: 0, reviewedUnchanged: 0)
        }
        let placeholders = sources.map { _ in "?" }.joined(separator: ", ")
        var repaired = 0
        var reviewedUnchanged = 0
        var attempted = 0
        var afterGeneration: String?
        while attempted < batchLimit {
            try Store.checkpoint(deadline)
            var arguments: [any DatabaseValueConvertible] = [expectedParserRevision]
            arguments.append(contentsOf: sources.map(\.rawValue))
            arguments.append(afterGeneration)
            arguments.append(afterGeneration)
            arguments.append(reviewedMetadataPrefix)
            arguments.append(batchLimit - attempted)
            let rows = try Row.fetchAll(db, sql: """
                SELECT g.generation_id, g.stored_session_id, g.sync_version, g.snapshot_hash,
                    s.authoritative_node, s.message_count, s.project, s.summary, s.start_time,
                    s.end_time, s.source, s.assistant_message_count, s.tool_message_count
                FROM capture_ingest_identity_bindings b
                JOIN capture_ingest_generations g
                    ON g.generation_id = b.last_parsed_generation_id
                    AND g.stored_session_id = b.stored_session_id
                    AND g.sync_version = b.last_sync_version
                JOIN sessions s ON s.id = g.stored_session_id
                JOIN capture_ingest_ledger l
                    ON l.publication_sha256 = g.publication_sha256
                    AND l.parser_revision = g.parser_revision
                WHERE l.status = 'parsed'
                    AND s.tier = 'skip'
                    AND s.agent_role IS NULL
                    AND s.message_count > 1
                    AND g.required_fts_job_id IS NULL
                    AND g.parser_revision = ?
                    AND g.source IN (\(placeholders))
                    AND s.sync_version = g.sync_version
                    AND s.snapshot_hash = g.snapshot_hash
                    AND s.authoritative_node IS NOT NULL
                    AND (? IS NULL OR g.generation_id > ?)
                    AND NOT EXISTS (
                        SELECT 1 FROM metadata m
                        WHERE m.key = ? || g.generation_id
                    )
                ORDER BY g.generation_id
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            if rows.isEmpty { break }
            for row in rows {
                try Store.checkpoint(deadline)
                guard let generationID = try? Store.string(row, "generation_id") else { break }
                afterGeneration = generationID
                attempted += 1
                var outcome: RepairOneResult?
                do {
                    try db.inSavepoint {
                        outcome = try repairOne(db, row: row, expectedParserRevision: expectedParserRevision,
                            enabledSources: enabledSources, deadline: deadline)
                        return .commit
                    }
                    switch outcome {
                    case .repaired: repaired += 1
                    case .reviewedUnchanged: reviewedUnchanged += 1
                    case .unprocessed, nil: break
                    }
                } catch let error as CaptureIngestReadinessError where error == .deadlineExceeded {
                    throw error
                } catch {
                    // Disabled, stale, corrupt, and tuple mismatches stay unmarked
                    // so a later start can resume them. They are not repaired.
                    continue
                }
                if attempted >= batchLimit { break }
            }
        }
        return CaptureWeakReviewSkipRepairBatch(repaired: repaired, reviewedUnchanged: reviewedUnchanged)
    }

    private enum RepairOneResult {
        case repaired
        case reviewedUnchanged
        case unprocessed
    }

    private static func repairOne(
        _ db: Database,
        row: Row,
        expectedParserRevision: String,
        enabledSources: Set<SourceName>,
        deadline: ContinuousClock.Instant?
    ) throws -> RepairOneResult {
        let sessionID = try Store.string(row, "stored_session_id")
        let generationID = try Store.string(row, "generation_id")
        let snapshotHash = try Store.string(row, "snapshot_hash")
        let authoritativeNode = try Store.string(row, "authoritative_node")
        let version = try Store.integer(row, "sync_version")
        guard ArchiveV2Hash.isValidSHA256(generationID), ArchiveV2Hash.isValidSHA256(snapshotHash),
              let syncVersion = Int(exactly: version), syncVersion > 0 else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        let texts: [String]
        switch try firstSubstantiveUserEvidence(db, sessionID: sessionID, generationID: generationID,
            expectedParserRevision: expectedParserRevision, enabledSources: enabledSources, deadline: deadline) {
        case .truncated:
            return .unprocessed
        case .window(let window):
            texts = window
        }
        guard AuthoritativeSessionSnapshotBuilder.isLegacyWeakReviewOnlySkip(texts) else {
            try markReviewed(db, generationID: generationID)
            return .reviewedUnchanged
        }
        let nextTier = try recomputedVisibleTier(row, originalLocator: try originalManifestLocator(db, generationID: generationID))
        guard nextTier != .skip else {
            try markReviewed(db, generationID: generationID)
            return .reviewedUnchanged
        }
        _ = try SessionSnapshotWriter(db: db).bindCurrentCaptureSkipReclassification(
            sessionID: sessionID, generationID: generationID, authoritativeNode: authoritativeNode,
            syncVersion: syncVersion, snapshotHash: snapshotHash, nextTier: nextTier)
        return .repaired
    }

    private enum FirstUserEvidence {
        case window([String])
        case truncated
    }

    private static func firstSubstantiveUserEvidence(
        _ db: Database,
        sessionID: String,
        generationID: String,
        expectedParserRevision: String,
        enabledSources: Set<SourceName>,
        deadline: ContinuousClock.Instant?
    ) throws -> FirstUserEvidence {
        var texts: [String] = []
        var from = 0
        var pages = 0
        var hasMore = false
        while texts.count < 3, pages < 3 {
            try Store.checkpoint(deadline)
            let page = try Store.loadPage(db, sessionID: sessionID, generationID: generationID,
                expectedParserRevision: expectedParserRevision, enabledSources: enabledSources,
                fromOrdinal: from, maximumMessages: 16, roles: [.user], deadline: deadline)
            pages += 1
            hasMore = page.hasMore
            texts.append(contentsOf: AuthoritativeSessionSnapshotBuilder.firstSubstantiveUserTexts(
                from: page.snapshot.messages, limit: 3 - texts.count))
            if !page.hasMore { break }
            from = (page.ordinals.last ?? from) + 1
        }
        if texts.count < 3, hasMore { return .truncated }
        return .window(texts)
    }

    private static func originalManifestLocator(_ db: Database, generationID: String) throws -> String {
        guard let bytes = try Data.fetchOne(db, sql: """
            SELECT manifest_json FROM capture_ingest_generations WHERE generation_id = ?
            """, arguments: [generationID]), !bytes.isEmpty else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        let manifest: ArchiveSourceManifest
        do { manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes) }
        catch { throw CaptureIngestReadinessError.invalidStoredRecord }
        guard !manifest.locator.isEmpty else { throw CaptureIngestReadinessError.invalidStoredRecord }
        return manifest.locator
    }

    private static func recomputedVisibleTier(_ row: Row, originalLocator: String) throws -> SessionTier {
        let messageCount = Int(try Store.integer(row, "message_count"))
        return SessionTier.compute(TierInput(
            messageCount: messageCount,
            agentRole: nil,
            filePath: originalLocator,
            project: try Store.optionalString(row, "project"),
            summary: try Store.optionalString(row, "summary"),
            startTime: try Store.string(row, "start_time"),
            endTime: try Store.optionalString(row, "end_time"),
            source: try Store.string(row, "source"),
            isPreamble: false,
            assistantCount: Int(try Store.integer(row, "assistant_message_count")),
            toolCount: Int(try Store.integer(row, "tool_message_count"))
        ))
    }

    private static func markReviewed(_ db: Database, generationID: String) throws {
        guard ArchiveV2Hash.isValidSHA256(generationID) else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        try db.execute(sql: """
            INSERT INTO metadata(key, value) VALUES (?, '1')
            ON CONFLICT(key) DO NOTHING
            """, arguments: [reviewedMetadataPrefix + generationID])
    }

    /// Call in one writer transaction, with no awaits. An internal savepoint
    /// reserves the writer before reads and atomically fences the exact current
    /// binding, identity, parsed head, snapshot, required job, ledger, and ready
    /// head. A stale prepared artifact must never overwrite or purge newer FTS.
    /// Fresh trusted parser/source policy is mandatory and is not inferred from
    /// adapters or retained from the prepared snapshot. No provider is wired here.
    public static func commit(
        _ db: Database,
        snapshot: CaptureIngestNormalizedSnapshot,
        expectedParserRevision: String,
        enabledSources: Set<SourceName>,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> CaptureIngestReadyGeneration {
        try Store.checkpoint(deadline)
        try Store.validateParserRevision(expectedParserRevision)
        guard Store.exact(snapshot.parserRevision, expectedParserRevision) else {
            throw CaptureIngestReadinessError.parserRevisionChanged
        }
        var receipt: CaptureIngestReadyGeneration?
        try db.inSavepoint {
            // A deferred outer transaction must reserve its writer before the
            // first authority read. A stale outer snapshot fails/retries outside.
            try db.execute(sql: "UPDATE capture_ingest_ledger SET attempt_count = attempt_count WHERE 0")
            let current = try Store.currentMetadata(db, sessionID: snapshot.sessionID, generationID: snapshot.generationID,
                expectedParserRevision: expectedParserRevision, enabledSources: enabledSources, deadline: deadline)
            try requirePreparedPayload(snapshot, current: current, deadline: deadline)
            let job = try requiredJob(db, snapshot: snapshot, current: current)
            let skipped = current.tier == .skip
            let result = CaptureIngestReadyGeneration(sessionID: snapshot.sessionID, generationID: snapshot.generationID,
                syncVersion: snapshot.syncVersion, snapshotHash: snapshot.snapshotHash,
                requiredFTSJobID: snapshot.requiredFTSJobID, disposition: skipped ? .skipNotApplicable : .indexed)
            if job.isCompletedReplay {
                try Store.checkpoint(deadline)
                receipt = result
                return .commit
            }
            try Store.checkpoint(deadline)
            if skipped {
                // An explicit exact current skip disposition stays absent from
                // both active and shadow FTS. It is not a visible/searchable row.
                try FTSRebuildPolicy.purgeFtsContent(db, sessionId: snapshot.sessionID)
            } else {
                // Capture-owned FTS is written here; IndexJobRunner skips these
                // sessions. Non-Grok system messages stay excluded. Grok-only
                // labeled compaction archives are admitted so pre-compaction
                // Markdown is searchable after parse-format/registry wiring.
                let admitGrokArchives = current.nativeIdentity.source == .grok
                let messages = snapshot.messages.compactMap { message -> String? in
                    guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    if message.role == .user || message.role == .assistant { return message.content }
                    if admitGrokArchives, message.role == .system,
                       message.content.hasPrefix("Grok compaction archive\n") {
                        return message.content
                    }
                    return nil
                }
                try FTSRebuildPolicy.replaceFtsContent(db, sessionId: snapshot.sessionID,
                    messages: messages, summary: current.summary)
            }
            try Store.checkpoint(deadline)
            if let id = snapshot.requiredFTSJobID {
                try db.execute(sql: """
                    UPDATE session_index_jobs SET status = ?, last_error = NULL, not_before = NULL,
                        updated_at = datetime('now')
                    WHERE id = ? AND session_id = ? AND job_kind = 'fts' AND target_sync_version = ? AND status = ?
                    """, arguments: [skipped ? "not_applicable" : "completed", id, snapshot.sessionID,
                                       snapshot.syncVersion, job.status])
                guard db.changesCount == 1 else { throw CaptureIngestReadinessError.requiredJobChanged }
            }
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET status = 'index_ready', updated_at = datetime('now')
                WHERE publication_sha256 = ? AND parser_revision = ? AND status = ?
                """, arguments: [snapshot.publicationSHA256, snapshot.parserRevision, current.ledgerStatus])
            guard db.changesCount == 1 else { throw CaptureIngestReadinessError.invalidStoredRecord }
            try db.execute(sql: """
                UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = ?
                WHERE stored_session_id = ? AND machine_id = ? AND source_instance_id = ? AND source = ? AND native_id = ?
                    AND last_parsed_generation_id = ? AND last_sync_version = ? AND last_ready_generation_id IS ?
                """, arguments: [snapshot.generationID, snapshot.sessionID, snapshot.nativeIdentity.machineID,
                                   snapshot.nativeIdentity.sourceInstanceID, snapshot.nativeIdentity.source.rawValue,
                                   snapshot.nativeIdentity.nativeID, snapshot.generationID, snapshot.syncVersion, current.readyGenerationID])
            guard db.changesCount == 1 else { throw CaptureIngestReadinessError.staleGeneration }
            try Store.checkpoint(deadline)
            // Re-read the full tuple after writes as well. Trigger-side effects
            // must not escape a caught inner failure as a newly ready generation.
            let completed = try Store.currentMetadata(db, sessionID: snapshot.sessionID, generationID: snapshot.generationID,
                expectedParserRevision: expectedParserRevision, enabledSources: enabledSources, deadline: deadline)
            guard completed.ledgerStatus == "index_ready", completed.readyGenerationID == snapshot.generationID,
                  completed.tier == current.tier else { throw CaptureIngestReadinessError.currentSnapshotMismatch }
            _ = try requiredJob(db, snapshot: snapshot, current: completed)
            receipt = result
            return .commit
        }
        guard let receipt else { throw CaptureIngestReadinessError.invalidStoredRecord }
        return receipt
    }

    private static func requirePreparedPayload(
        _ snapshot: CaptureIngestNormalizedSnapshot, current: Store.Metadata, deadline: ContinuousClock.Instant?
    ) throws {
        guard Store.exact(snapshot.publicationSHA256, current.publicationSHA256),
              Store.exact(snapshot.parserRevision, current.parserRevision), snapshot.nativeIdentity == current.nativeIdentity,
              snapshot.bindingSnapshot == current.binding, snapshot.syncVersion == current.syncVersion,
              Store.exact(snapshot.snapshotHash, current.snapshotHash),
              snapshot.requiredFTSJobID == current.requiredFTSJobID,
              Store.exact(snapshot.normalizedMessagesSHA256, current.normalizedSHA256),
              snapshot.messageStartOrdinal == 0,
              snapshot.totalMessageCount == current.messageCount,
              snapshot.messages.count == current.messageCount else { throw CaptureIngestReadinessError.invalidStoredRecord }
        try Store.checkpoint(deadline)
        // Partial range snapshots are rejected above. v1 still hashes the
        // complete array; v2 hashes the bounded per-message digest manifest.
        switch current.storageVersion {
        case CaptureIngestCommitter.normalizedStorageVersionV1:
            let bytes = try ArchiveCanonicalJSON.encode(snapshot.messages)
            guard bytes.count == current.payloadBytes, ArchiveV2Hash.sha256(bytes) == current.normalizedSHA256 else {
                throw CaptureIngestReadinessError.invalidStoredRecord
            }
        case CaptureIngestCommitter.normalizedStorageVersionV2:
            var digests: [CaptureIngestNormalizedMessageDigest] = []
            digests.reserveCapacity(snapshot.messages.count)
            var totalBytes = 0
            for message in snapshot.messages {
                let bytes = try ArchiveCanonicalJSON.encode(message)
                let (next, overflow) = totalBytes.addingReportingOverflow(bytes.count)
                guard !overflow, bytes.count <= CaptureIngestCommitter.maximumNormalizedMessageBytes,
                      next <= CaptureIngestCommitter.maximumNormalizedStorageBytes else {
                    throw CaptureIngestReadinessError.invalidStoredRecord
                }
                totalBytes = next
                digests.append(CaptureIngestNormalizedMessageDigest(sha256: ArchiveV2Hash.sha256(bytes),
                    byteSize: bytes.count, role: message.role))
            }
            let manifest = try ArchiveCanonicalJSON.encode(digests)
            guard manifest.count == current.payloadBytes, ArchiveV2Hash.sha256(manifest) == current.normalizedSHA256 else {
                throw CaptureIngestReadinessError.invalidStoredRecord
            }
        default:
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        try Store.checkpoint(deadline)
    }

    private struct JobState {
        let status: String?
        let isCompletedReplay: Bool
    }

    private static func requiredJob(
        _ db: Database, snapshot: CaptureIngestNormalizedSnapshot, current: Store.Metadata
    ) throws -> JobState {
        let alreadyReady = current.ledgerStatus == "index_ready" && current.readyGenerationID == snapshot.generationID
        guard let id = current.requiredFTSJobID else {
            guard current.tier == .skip else { throw CaptureIngestReadinessError.requiredJobChanged }
            return JobState(status: nil, isCompletedReplay: alreadyReady)
        }
        let expectedID = "\(snapshot.sessionID):\(snapshot.syncVersion):\(snapshot.snapshotHash):fts"
        guard Store.exact(id, expectedID), let row = try Row.fetchOne(db, sql: """
            SELECT session_id, job_kind, target_sync_version, status, not_before,
                (not_before IS NULL OR not_before <= datetime('now')) AS is_due
            FROM session_index_jobs WHERE id = ?
            """, arguments: [id]),
              case .string(let sessionID) = (row["session_id"] as DatabaseValue).storage, Store.exact(sessionID, snapshot.sessionID),
              case .string(let kind) = (row["job_kind"] as DatabaseValue).storage, kind == "fts",
              case .int64(let version) = (row["target_sync_version"] as DatabaseValue).storage, version == Int64(snapshot.syncVersion),
              case .string(let status) = (row["status"] as DatabaseValue).storage else {
            throw CaptureIngestReadinessError.requiredJobChanged
        }
        if alreadyReady {
            if (current.tier == .skip && status == "not_applicable") || (current.tier != .skip && status == "completed") {
                return JobState(status: status, isCompletedReplay: true)
            }
            // A later manual skip still purges its own formerly indexed content.
            if current.tier == .skip && status == "completed" {
                return JobState(status: status, isCompletedReplay: false)
            }
        }
        guard status == "pending" || status == "failed_retryable",
              case .int64(let due) = (row["is_due"] as DatabaseValue).storage, due == 1 else {
            throw CaptureIngestReadinessError.requiredJobChanged
        }
        switch (row["not_before"] as DatabaseValue).storage {
        case .null, .string: break
        default: throw CaptureIngestReadinessError.requiredJobChanged
        }
        return JobState(status: status, isCompletedReplay: false)
    }
}
