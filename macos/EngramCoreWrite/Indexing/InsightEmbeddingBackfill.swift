import EngramCoreRead
import Foundation
import GRDB

/// Backfills embeddings for insights that don't have one yet. The network call
/// happens outside the writer lock; only the short BLOB write holds it. Opt-in:
/// callers pass a provider only when one is configured. Bounded by `limit` per
/// run so a large backlog is drained across maintenance cycles.
public enum InsightEmbeddingBackfill {
    public struct Result: Equatable {
        public let embedded: Int
        public init(embedded: Int) { self.embedded = embedded }
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

    public static func run(
        writer: EngramDatabaseWriter,
        provider: EmbeddingProvider,
        limit: Int = 64
    ) async throws -> Result {
        let pending = try pendingInsights(writer: writer, limit: limit)
        guard !pending.isEmpty else { return Result(embedded: 0) }

        let vectors = try await provider.embed(pending.map(\.content))
        guard vectors.count == pending.count else { return Result(embedded: 0) }

        let embedded = zip(pending, vectors).map { item, vector in
            EmbeddedInsight(id: item.id, vector: vector)
        }
        return try writeEmbeddings(
            writer: writer,
            embeddings: embedded,
            model: provider.model,
            dimension: provider.dimension
        )
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
                WHERE e.insight_id IS NULL
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
        try writer.write { db in
            for item in embeddings {
                try db.execute(
                    sql: """
                        INSERT INTO insight_embeddings (insight_id, embedding, model, dim)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(insight_id) DO UPDATE SET
                          embedding = excluded.embedding,
                          model = excluded.model,
                          dim = excluded.dim
                    """,
                    arguments: [item.id, VectorMath.encode(item.vector), model, dimension]
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
}

/// Backfills chunk-level embeddings for sessions with pending `embedding` index
/// jobs. Reads pending rows and FTS text under a short writer-gate phase; callers
/// run provider I/O outside the gate, then write chunks and complete jobs in a
/// second short phase.
public enum SessionEmbeddingBackfill {
    public struct Result: Equatable {
        public let completed: Int
        public let notApplicable: Int

        public init(completed: Int, notApplicable: Int) {
            self.completed = completed
            self.notApplicable = notApplicable
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
        provider: any EmbeddingProvider
    ) async throws -> [EmbeddedSession] {
        guard !pending.isEmpty else { return [] }
        var requests: [ChunkRequest] = []
        for session in pending {
            let messages = session.content
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { (role: "assistant", content: String($0)) }
            for chunk in SessionChunker.chunk(messages: messages) {
                requests.append(
                    ChunkRequest(
                        jobId: session.jobId,
                        sessionId: session.sessionId,
                        index: chunk.index,
                        text: chunk.text
                    )
                )
            }
        }

        var chunksByJob: [String: [EmbeddedChunk]] = [:]
        if !requests.isEmpty {
            let vectors = try await provider.embed(requests.map(\.text))
            guard vectors.count == requests.count else {
                throw EmbeddingError.malformedResponse
            }
            for (request, vector) in zip(requests, vectors) {
                chunksByJob[request.jobId, default: []].append(
                    EmbeddedChunk(index: request.index, text: request.text, vector: vector)
                )
            }
        }

        return pending.map { session in
            EmbeddedSession(
                jobId: session.jobId,
                sessionId: session.sessionId,
                chunks: chunksByJob[session.jobId] ?? []
            )
        }
    }

    public static func writeEmbeddings(
        writer: EngramDatabaseWriter,
        sessions: [EmbeddedSession],
        model: String,
        dimension: Int
    ) throws -> Result {
        guard !sessions.isEmpty else { return Result(completed: 0, notApplicable: 0) }
        var completed = 0
        var notApplicable = 0
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
                            dimension,
                        ]
                    )
                }
                try IndexJobRunner.markCompleted(db, id: session.jobId)
                completed += 1
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
        return Result(completed: completed, notApplicable: notApplicable)
    }
}
