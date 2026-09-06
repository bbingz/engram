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

public enum CaptureIngestReadiness {
    private typealias Store = CaptureIngestNormalizedStore

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
                // Match the existing runner: trim only to identify empty lines,
                // preserve nonempty user/assistant bytes and the stored summary.
                let messages = snapshot.messages.compactMap { message -> String? in
                    guard message.role == .user || message.role == .assistant,
                          !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return message.content
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
              snapshot.messages.count == current.messageCount else { throw CaptureIngestReadinessError.invalidStoredRecord }
        try Store.checkpoint(deadline)
        // The public value has no public initializer, but module-internal callers
        // must still not turn a changed payload into an authorized FTS write.
        let bytes = try ArchiveCanonicalJSON.encode(snapshot.messages)
        guard bytes.count == current.payloadBytes, ArchiveV2Hash.sha256(bytes) == current.normalizedSHA256 else {
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
