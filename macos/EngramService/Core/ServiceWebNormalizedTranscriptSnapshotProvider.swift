import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

/// Admits only the current, visible, index-ready normalized generation. The
/// normalized store owns payload decoding and complete capture authority checks.
final class ServiceWebNormalizedTranscriptSnapshotProvider: ServiceWebTranscriptSnapshotProviding, @unchecked Sendable {
    private let pool: DatabasePool
    private let policySource: @Sendable () throws -> ServiceWebMetadataPolicy?
    private let queue = DispatchQueue(label: "com.engram.service.web-normalized-transcript", qos: .userInitiated)

    var supportsNormalizedTranscripts: Bool { true }

    init(databasePath: String, policy: @escaping @Sendable () throws -> ServiceWebMetadataPolicy?) throws {
        policySource = policy
        pool = try DatabasePool(path: databasePath, configuration: SQLiteConnectionPolicy.immediateReaderConfiguration())
    }

    deinit { try? stop() }

    func stop() throws { try pool.close() }

    func snapshot(sessionID: String, generation: String,
                  deadline: ContinuousClock.Instant) async throws -> ServiceTranscriptContinuation.Snapshot? {
        do {
            try Self.checkpoint(deadline)
            let policy = try currentPolicy()
            try Self.checkpoint(deadline)
            let prepared = try await read { db in
                try Self.load(db, sessionID: sessionID, generation: generation, policy: policy, deadline: deadline)
            }
            try Self.checkpoint(deadline)
            let current = try currentPolicy()
            guard Self.samePolicy(policy, current) else { throw ServiceWebTranscriptSnapshotError.unavailable }
            try Self.checkpoint(deadline)
            guard let prepared else { return nil }

            // The first read transaction has ended. Re-enter the existing
            // authority reader with fresh policy before releasing its messages;
            // neither a cached readiness scalar nor an earlier page authorizes it.
            let fresh = try await read { db in
                try Self.load(db, sessionID: sessionID, generation: generation, policy: current, deadline: deadline)
            }
            try Self.checkpoint(deadline)
            guard Self.samePolicy(current, try currentPolicy()), let fresh, fresh == prepared else {
                throw ServiceWebTranscriptSnapshotError.unavailable
            }
            try Self.checkpoint(deadline)
            return .init(sessionId: fresh.sessionID, generation: fresh.generationID, messages: fresh.messages)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw ServiceWebTranscriptSnapshotError.unavailable
        }
    }

    private func currentPolicy() throws -> ServiceWebMetadataPolicy {
        guard let policy = try policySource(),
              ServiceWebMetadataProducer.isValidParserRevision(policy.parserRevision),
              !policy.enabledSources.isEmpty else { throw ServiceWebTranscriptSnapshotError.unavailable }
        return policy
    }

    private static func samePolicy(_ lhs: ServiceWebMetadataPolicy, _ rhs: ServiceWebMetadataPolicy) -> Bool {
        lhs.parserRevision.utf8.elementsEqual(rhs.parserRevision.utf8) && lhs.enabledSources == rhs.enabledSources
    }

    private static func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ServiceWebTranscriptSnapshotError.unavailable }
    }

    private static func load(_ db: Database, sessionID: String, generation: String,
                             policy: ServiceWebMetadataPolicy, deadline: ContinuousClock.Instant) throws -> CaptureIngestNormalizedSnapshot? {
        try checkpoint(deadline)
        // Visibility follows the metadata read surface. Ready is stricter:
        // parsed, ready and requested heads must agree with the ready ledger.
        guard try Int.fetchOne(db, sql: """
            SELECT 1
            FROM sessions s
            JOIN capture_ingest_identity_bindings i ON i.stored_session_id = s.id COLLATE BINARY
            JOIN capture_ingest_generations g ON g.stored_session_id = s.id COLLATE BINARY
            JOIN capture_ingest_ledger l ON l.publication_sha256 = g.publication_sha256 COLLATE BINARY
                AND l.parser_revision = g.parser_revision COLLATE BINARY
            WHERE s.id = ? COLLATE BINARY AND g.generation_id = ? COLLATE BINARY
                AND i.last_parsed_generation_id = g.generation_id COLLATE BINARY
                AND i.last_ready_generation_id = g.generation_id COLLATE BINARY
                AND l.status = 'index_ready'
                AND s.hidden_at IS NULL AND s.parent_session_id IS NULL AND s.suggested_parent_id IS NULL
                AND s.tier IN ('lite', 'normal', 'premium')
            """, arguments: [sessionID, generation]) == 1 else { return nil }
        let snapshot = try CaptureIngestNormalizedStore.load(db, sessionID: sessionID, generationID: generation,
            expectedParserRevision: policy.parserRevision, enabledSources: policy.enabledSources, deadline: deadline)
        try checkpoint(deadline)
        // Readiness.commit requires this exact completed FTS job for a visible
        // generation. A later edit of ready scalars cannot replace that proof.
        let expectedJob = "\(snapshot.sessionID):\(snapshot.syncVersion):\(snapshot.snapshotHash):fts"
        guard let jobID = snapshot.requiredFTSJobID, jobID.utf8.elementsEqual(expectedJob.utf8),
              let job = try Row.fetchOne(db, sql: """
                SELECT session_id, job_kind, target_sync_version, status FROM session_index_jobs WHERE id = ?
                """, arguments: [jobID]),
              case .string(let storedID) = (job["session_id"] as DatabaseValue).storage,
              storedID.utf8.elementsEqual(sessionID.utf8),
              case .string("fts") = (job["job_kind"] as DatabaseValue).storage,
              case .int64(let version) = (job["target_sync_version"] as DatabaseValue).storage,
              version == Int64(snapshot.syncVersion),
              case .string("completed") = (job["status"] as DatabaseValue).storage else {
            throw ServiceWebTranscriptSnapshotError.unavailable
        }
        try checkpoint(deadline)
        return snapshot
    }

    /// Like other Service read facades, join the blocking SQLite read before
    /// checking caller cancellation again. No detached timeout work survives it.
    private func read<Value: Sendable>(_ operation: @escaping @Sendable (Database) throws -> Value) async throws -> Value {
        let pool = pool
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try pool.read(operation)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
