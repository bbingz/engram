import EngramCoreRead
import Foundation
import GRDB

/// Backfills embeddings for insights that don't have one yet. The network call
/// happens outside the writer lock; only the short BLOB write holds it. Opt-in:
/// callers pass a provider only when one is configured. Bounded by `limit` per
/// run so a large backlog is drained across maintenance cycles.
public enum InsightEmbeddingBackfill {
    /// Same terminal budget as session FTS/embedding isolation — poison content
    /// becomes `failed_permanent` and is excluded from pending selection.
    public static let maxInsightEmbedRetryCount = 3

    public struct Result: Equatable {
        public let embedded: Int
        public let failed: Int
        public init(embedded: Int, failed: Int = 0) {
            self.embedded = embedded
            self.failed = failed
        }
    }

    public struct PendingInsight: Equatable, Sendable {
        public let id: String
        public let content: String

        public init(id: String, content: String) {
            self.id = id
            self.content = content
        }
    }

    public struct EmbeddedInsight: Equatable, Sendable {
        public let id: String
        public let vector: [Float]

        public init(id: String, vector: [Float]) {
            self.id = id
            self.vector = vector
        }
    }

    public struct InsightFailure: Equatable, Sendable {
        public let id: String
        public let error: String

        public init(id: String, error: String) {
            self.id = id
            self.error = error
        }
    }

    /// R4: embed each pending insight independently. One poison item does not
    /// abort the rest. Circuit-open / cancellation still propagate so callers
    /// can soft-skip the maintenance phase.
    public static func embedPendingIsolated(
        _ pending: [PendingInsight],
        provider: EmbeddingProvider
    ) async throws -> (successes: [EmbeddedInsight], failures: [InsightFailure]) {
        guard !pending.isEmpty else { return ([], []) }
        var successes: [EmbeddedInsight] = []
        var failures: [InsightFailure] = []
        successes.reserveCapacity(pending.count)

        for item in pending {
            do {
                let vectors = try await provider.embed([item.content])
                guard vectors.count == 1, let vector = vectors.first else {
                    throw EmbeddingError.malformedResponse
                }
                try validateUniformNativeDimension([vector], configured: provider.dimension)
                successes.append(EmbeddedInsight(id: item.id, vector: vector))
            } catch is CancellationError {
                throw CancellationError()
            } catch EmbeddingError.circuitOpen {
                throw EmbeddingError.circuitOpen
            } catch {
                failures.append(InsightFailure(id: item.id, error: "\(error)"))
            }
        }
        return (successes, failures)
    }

    /// Convenience: pending → isolated embed → write successes + record failures.
    /// Prefer the service runner path for product (gate-separated network I/O).
    public static func run(
        writer: EngramDatabaseWriter,
        provider: EmbeddingProvider,
        limit: Int = 64
    ) async throws -> Result {
        try reconcileModelChangeIfNeeded(
            writer: writer,
            model: provider.model,
            dimension: provider.dimension
        )
        let pending = try pendingInsights(writer: writer, limit: limit)
        guard !pending.isEmpty else { return Result(embedded: 0, failed: 0) }

        let outcome = try await embedPendingIsolated(pending, provider: provider)
        if !outcome.successes.isEmpty {
            _ = try writeEmbeddings(
                writer: writer,
                embeddings: outcome.successes,
                model: provider.model,
                dimension: provider.dimension
            )
        }
        if !outcome.failures.isEmpty {
            try recordFailures(writer: writer, failures: outcome.failures)
        }
        return Result(embedded: outcome.successes.count, failed: outcome.failures.count)
    }

    public static func pendingInsights(
        writer: EngramDatabaseWriter,
        limit: Int = 64
    ) throws -> [PendingInsight] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.id AS id, i.content AS content
                FROM insights i
                LEFT JOIN insight_embeddings e ON e.insight_id = i.id
                LEFT JOIN insight_embedding_failures f ON f.insight_id = i.id
                WHERE e.insight_id IS NULL
                  AND (f.insight_id IS NULL OR f.status != 'failed_permanent')
                ORDER BY i.created_at DESC
                LIMIT ?
            """, arguments: [limit])
            return rows.compactMap { row in
                guard let id = row["id"] as String?, let content = row["content"] as String? else {
                    return nil
                }
                return PendingInsight(id: id, content: content)
            }
        }
    }

    public static func writeEmbeddings(
        writer: EngramDatabaseWriter,
        embeddings: [EmbeddedInsight],
        model: String,
        dimension: Int
    ) throws -> Result {
        guard !embeddings.isEmpty else { return Result(embedded: 0) }
        try validateUniformNativeDimension(embeddings.map(\.vector), configured: dimension)
        try reconcileModelChangeIfNeeded(writer: writer, model: model, dimension: dimension)
        try writer.write { db in
            for item in embeddings {
                let nativeDim = item.vector.count
                try db.execute(
                    sql: """
                        INSERT INTO insight_embeddings (insight_id, embedding, model, dim)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(insight_id) DO UPDATE SET
                          embedding = excluded.embedding,
                          model = excluded.model,
                          dim = excluded.dim
                    """,
                    arguments: [item.id, VectorMath.encode(item.vector), model, nativeDim]
                )
                // Successful embed clears any prior failure bookkeeping.
                try db.execute(
                    sql: "DELETE FROM insight_embedding_failures WHERE insight_id = ?",
                    arguments: [item.id]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO embedding_meta (id, provider, model, dimension, updated_at)
                    VALUES (1, 'openai-compatible', ?, ?, datetime('now'))
                    ON CONFLICT(id) DO UPDATE SET
                      model = excluded.model,
                      dimension = excluded.dimension,
                      updated_at = excluded.updated_at
                """,
                arguments: [model, dimension]
            )
        }
        return Result(embedded: embeddings.count)
    }

    public static func recordFailures(
        writer: EngramDatabaseWriter,
        failures: [InsightFailure]
    ) throws {
        guard !failures.isEmpty else { return }
        try writer.write { db in
            for failure in failures {
                try db.execute(
                    sql: """
                    INSERT INTO insight_embedding_failures (
                      insight_id, retry_count, status, last_error, updated_at
                    ) VALUES (?, 1, ?, ?, datetime('now'))
                    ON CONFLICT(insight_id) DO UPDATE SET
                      retry_count = insight_embedding_failures.retry_count + 1,
                      status = CASE
                        WHEN insight_embedding_failures.retry_count + 1 >= ? THEN 'failed_permanent'
                        ELSE 'failed_retryable'
                      END,
                      last_error = excluded.last_error,
                      updated_at = excluded.updated_at
                    """,
                    arguments: [
                        failure.id,
                        "failed_retryable",
                        failure.error,
                        maxInsightEmbedRetryCount,
                    ]
                )
            }
        }
    }

    /// M17: when configured (model, dimension) differs from `embedding_meta`,
    /// purge stored vectors and re-enqueue session embedding jobs so the corpus
    /// is not silently unqueryable after a provider change.
    @discardableResult
    public static func reconcileModelChangeIfNeeded(
        writer: EngramDatabaseWriter,
        model: String,
        dimension: Int
    ) throws -> Bool {
        try writer.write { db in
            try Self.reconcileModelChangeIfNeeded(db, model: model, dimension: dimension)
        }
    }

    static func reconcileModelChangeIfNeeded(
        _ db: Database,
        model: String,
        dimension: Int
    ) throws -> Bool {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT model, dimension FROM embedding_meta WHERE id = 1"
        ) else {
            return false
        }
        let storedModel = row["model"] as String?
        let storedDim = row["dimension"] as Int?
        guard let storedModel, let storedDim else { return false }
        guard storedModel != model || storedDim != dimension else { return false }

        try db.execute(sql: "DELETE FROM semantic_chunks")
        try db.execute(sql: "DELETE FROM insight_embeddings")
        // Model/dim change invalidates prior poison permanent marks so content
        // can be retried under the new embedding space.
        try db.execute(sql: "DELETE FROM insight_embedding_failures")
        try db.execute(
            sql: """
            UPDATE session_index_jobs
            SET status = ?,
                retry_count = 0,
                last_error = NULL,
                updated_at = datetime('now')
            WHERE job_kind = ?
              AND status IN (?, ?, ?, ?)
            """,
            arguments: [
                IndexJobStatus.pending.rawValue,
                IndexJobKind.embedding.rawValue,
                IndexJobStatus.completed.rawValue,
                IndexJobStatus.failedPermanent.rawValue,
                IndexJobStatus.failedRetryable.rawValue,
                IndexJobStatus.notApplicable.rawValue,
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO embedding_meta (id, provider, model, dimension, updated_at)
            VALUES (1, 'openai-compatible', ?, ?, datetime('now'))
            ON CONFLICT(id) DO UPDATE SET
              model = excluded.model,
              dimension = excluded.dimension,
              updated_at = excluded.updated_at
            """,
            arguments: [model, dimension]
        )
        return true
    }

    public static func validateUniformNativeDimension(
        _ vectors: [[Float]],
        configured: Int
    ) throws {
        for vector in vectors {
            let actual = vector.count
            guard actual == configured else {
                throw EmbeddingError.dimensionMismatch(expected: configured, actual: actual)
            }
        }
    }
}

/// Backfills chunk-level embeddings for sessions with pending `embedding` index
/// jobs. Reads pending rows and FTS text under a short writer-gate phase; callers
/// run provider I/O outside the gate, then write chunks and complete jobs in a
/// second short phase.
public enum SessionEmbeddingBackfill {
    public struct Result: Equatable {
        public let completed: Int
        public let notApplicable: Int
        public let failed: Int

        public init(completed: Int, notApplicable: Int, failed: Int = 0) {
            self.completed = completed
            self.notApplicable = notApplicable
            self.failed = failed
        }
    }

    public struct PendingSession: Equatable, Sendable {
        public let jobId: String
        public let sessionId: String
        public let content: String

        public init(jobId: String, sessionId: String, content: String) {
            self.jobId = jobId
            self.sessionId = sessionId
            self.content = content
        }
    }

    public struct EmbeddedChunk: Equatable, Sendable {
        public let index: Int
        public let text: String
        public let vector: [Float]

        public init(index: Int, text: String, vector: [Float]) {
            self.index = index
            self.text = text
            self.vector = vector
        }
    }

    public struct EmbeddedSession: Equatable, Sendable {
        public let jobId: String
        public let sessionId: String
        public let chunks: [EmbeddedChunk]

        public init(jobId: String, sessionId: String, chunks: [EmbeddedChunk]) {
            self.jobId = jobId
            self.sessionId = sessionId
            self.chunks = chunks
        }
    }

    public struct SessionFailure: Equatable, Sendable {
        public let jobId: String
        public let sessionId: String
        public let error: String

        public init(jobId: String, sessionId: String, error: String) {
            self.jobId = jobId
            self.sessionId = sessionId
            self.error = error
        }
    }

    /// M3: successes and per-session failures isolated so one bad session does
    /// not abort the rest of the batch or stall the whole corpus forever.
    public struct EmbedBatchOutcome: Equatable, Sendable {
        public let embedded: [EmbeddedSession]
        public let failures: [SessionFailure]

        public init(embedded: [EmbeddedSession], failures: [SessionFailure]) {
            self.embedded = embedded
            self.failures = failures
        }
    }

    private struct ChunkRequest: Sendable {
        let jobId: String
        let sessionId: String
        let index: Int
        let text: String
    }

    public static func pendingSessions(
        writer: EngramDatabaseWriter,
        limit: Int = 32
    ) throws -> [PendingSession] {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                  j.id AS job_id,
                  j.session_id AS session_id,
                  COALESCE(
                    NULLIF((
                      SELECT GROUP_CONCAT(content, char(10))
                      FROM (
                        SELECT content
                        FROM sessions_fts
                        WHERE session_id = j.session_id
                        ORDER BY rowid
                      )
                    ), ''),
                    s.summary,
                    ''
                  ) AS content
                FROM session_index_jobs j
                JOIN sessions s ON s.id = j.session_id
                WHERE j.job_kind = ?
                  AND j.status IN ('pending', 'failed_retryable')
                  AND s.hidden_at IS NULL
                  AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
                ORDER BY
                  CASE j.status WHEN 'pending' THEN 0 ELSE 1 END,
                  j.retry_count,
                  j.created_at,
                  j.id
                LIMIT ?
                """,
                arguments: [IndexJobKind.embedding.rawValue, limit]
            )
            return rows.compactMap { row in
                guard let jobId = row["job_id"] as String?,
                      let sessionId = row["session_id"] as String? else {
                    return nil
                }
                return PendingSession(
                    jobId: jobId,
                    sessionId: sessionId,
                    content: (row["content"] as String?) ?? ""
                )
            }
        }
    }

    public static func embedPendingSessions(
        _ pending: [PendingSession],
        provider: any EmbeddingProvider,
        maxTextsPerRequest: Int = 16
    ) async throws -> [EmbeddedSession] {
        let outcome = try await embedPendingSessionsIsolated(
            pending,
            provider: provider,
            maxTextsPerRequest: maxTextsPerRequest
        )
        if !outcome.failures.isEmpty, outcome.embedded.isEmpty {
            // Preserve legacy throw semantics for total-batch failure when callers
            // only consume the success array; isolated path is preferred.
            throw EmbeddingError.malformedResponse
        }
        return outcome.embedded
    }

    /// M3: per-session isolation — one deterministically-failing session does
    /// not abort remaining work. Circuit-open still propagates so callers soft-skip.
    public static func embedPendingSessionsIsolated(
        _ pending: [PendingSession],
        provider: any EmbeddingProvider,
        maxTextsPerRequest: Int = 16
    ) async throws -> EmbedBatchOutcome {
        guard !pending.isEmpty else {
            return EmbedBatchOutcome(embedded: [], failures: [])
        }
        let requestLimit = max(1, maxTextsPerRequest)
        var embeddedSessions: [EmbeddedSession] = []
        embeddedSessions.reserveCapacity(pending.count)
        var failures: [SessionFailure] = []

        for session in pending {
            do {
                let messages = session.content
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { (role: "assistant", content: String($0)) }
                let requests = SessionChunker.chunk(messages: messages).map { chunk in
                    ChunkRequest(
                        jobId: session.jobId,
                        sessionId: session.sessionId,
                        index: chunk.index,
                        text: chunk.text
                    )
                }
                var embeddedChunks: [EmbeddedChunk] = []
                embeddedChunks.reserveCapacity(requests.count)
                var batchStart = 0
                while batchStart < requests.count {
                    let batchEnd = min(batchStart + requestLimit, requests.count)
                    let batch = requests[batchStart..<batchEnd]
                    let vectors = try await provider.embed(batch.map(\.text))
                    guard vectors.count == batch.count else {
                        throw EmbeddingError.malformedResponse
                    }
                    try InsightEmbeddingBackfill.validateUniformNativeDimension(
                        vectors,
                        configured: provider.dimension
                    )
                    embeddedChunks.append(contentsOf: zip(batch, vectors).map { request, vector in
                        EmbeddedChunk(
                            index: request.index,
                            text: request.text,
                            vector: vector
                        )
                    })
                    batchStart = batchEnd
                }
                embeddedSessions.append(
                    EmbeddedSession(
                        jobId: session.jobId,
                        sessionId: session.sessionId,
                        chunks: embeddedChunks
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch EmbeddingError.circuitOpen {
                throw EmbeddingError.circuitOpen
            } catch {
                failures.append(
                    SessionFailure(
                        jobId: session.jobId,
                        sessionId: session.sessionId,
                        error: "\(error)"
                    )
                )
            }
        }
        return EmbedBatchOutcome(embedded: embeddedSessions, failures: failures)
    }

    public static func writeEmbeddings(
        writer: EngramDatabaseWriter,
        sessions: [EmbeddedSession],
        model: String,
        dimension: Int,
        failures: [SessionFailure] = []
    ) throws -> Result {
        if sessions.isEmpty, failures.isEmpty {
            return Result(completed: 0, notApplicable: 0, failed: 0)
        }
        for session in sessions {
            try InsightEmbeddingBackfill.validateUniformNativeDimension(
                session.chunks.map(\.vector),
                configured: dimension
            )
        }
        try InsightEmbeddingBackfill.reconcileModelChangeIfNeeded(
            writer: writer,
            model: model,
            dimension: dimension
        )
        var completed = 0
        var notApplicable = 0
        var failed = 0
        try writer.write { db in
            for session in sessions {
                try db.execute(
                    sql: "DELETE FROM semantic_chunks WHERE session_id = ?",
                    arguments: [session.sessionId]
                )
                guard !session.chunks.isEmpty else {
                    try IndexJobRunner.markNotApplicable(db, id: session.jobId)
                    notApplicable += 1
                    continue
                }
                for chunk in session.chunks {
                    let nativeDim = chunk.vector.count
                    try db.execute(
                        sql: """
                        INSERT INTO semantic_chunks (id, session_id, chunk_index, text, embedding, model, dim)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                          text = excluded.text,
                          embedding = excluded.embedding,
                          model = excluded.model,
                          dim = excluded.dim
                        """,
                        arguments: [
                            "\(session.sessionId):c\(chunk.index)",
                            session.sessionId,
                            chunk.index,
                            chunk.text,
                            VectorMath.encode(chunk.vector),
                            model,
                            nativeDim,
                        ]
                    )
                }
                try IndexJobRunner.markCompleted(db, id: session.jobId)
                completed += 1
            }
            for failure in failures {
                try IndexJobRunner.markRetryable(db, id: failure.jobId, error: failure.error)
                failed += 1
            }
            if completed > 0 {
                try db.execute(
                    sql: """
                    INSERT INTO embedding_meta (id, provider, model, dimension, updated_at)
                    VALUES (1, 'openai-compatible', ?, ?, datetime('now'))
                    ON CONFLICT(id) DO UPDATE SET
                      model = excluded.model,
                      dimension = excluded.dimension,
                      updated_at = excluded.updated_at
                    """,
                    arguments: [model, dimension]
                )
            }
        }
        return Result(completed: completed, notApplicable: notApplicable, failed: failed)
    }
}
