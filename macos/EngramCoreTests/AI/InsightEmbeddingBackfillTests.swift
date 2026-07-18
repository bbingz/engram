import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

private struct FakeEmbeddingProvider: EmbeddingProvider {
    let model = "fake-model"
    let dimension = 3
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in VectorMath.l2Normalize([Float(text.count), 1, 0]) }
    }
}

private actor BatchRecordingEmbeddingProvider: EmbeddingProvider {
    let model = "batch-model"
    let dimension = 3
    private var recordedBatchSizes: [Int] = []

    func embed(_ texts: [String]) async throws -> [[Float]] {
        recordedBatchSizes.append(texts.count)
        return texts.map { _ in [1, 0, 0] }
    }

    func batchSizes() -> [Int] {
        recordedBatchSizes
    }
}

/// Returns wrong-length vectors for sessions whose content contains "BAD".
private struct SelectiveFailEmbeddingProvider: EmbeddingProvider {
    let model = "selective-model"
    let dimension = 3
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            if text.contains("BAD") {
                // Native length 2 ≠ configured 3 → M16 mismatch / M3 isolation.
                return [1, 0]
            }
            return [1, 0, 0]
        }
    }
}

private struct WrongDimEmbeddingProvider: EmbeddingProvider {
    let model = "wrong-dim-model"
    let dimension = 3
    func embed(_ texts: [String]) async throws -> [[Float]] {
        // Always return native length 2 while advertising configured dim 3.
        texts.map { _ in [1, 0] }
    }
}

private struct ModelBEmbeddingProvider: EmbeddingProvider {
    let model = "model-b"
    let dimension = 4
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [0.5, 0.5, 0.5, 0.5] }
    }
}

final class InsightEmbeddingBackfillTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testBackfillEmbedsPendingInsightsExactlyOnce() async throws {
        let path = tempDir.appendingPathComponent("embed.sqlite").path
        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, importance)
                VALUES ('i1', 'first insight content', 5), ('i2', 'second insight content here', 5)
            """)
        }

        let provider = FakeEmbeddingProvider()
        let first = try await InsightEmbeddingBackfill.run(writer: writer, provider: provider)
        XCTAssertEqual(first, .init(embedded: 2, failed: 0))

        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_embeddings"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dimension FROM embedding_meta WHERE id = 1"), 3)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT model FROM insight_embeddings WHERE insight_id = 'i1'"),
                "fake-model"
            )
            let blob: Data? = try Row.fetchOne(db, sql: "SELECT embedding FROM insight_embeddings WHERE insight_id = 'i1'")?["embedding"]
            XCTAssertEqual(VectorMath.decode(try XCTUnwrap(blob)).count, 3)
        }

        // Nothing pending on the second run.
        let second = try await InsightEmbeddingBackfill.run(writer: writer, provider: provider)
        XCTAssertEqual(second, .init(embedded: 0, failed: 0))
    }

    /// R4: poison insight fails in isolation; permanent terminal stops re-select.
    func testInsightEmbeddingIsolatesPoisonAndTerminates_repro() async throws {
        let path = tempDir.appendingPathComponent("r4-insight.sqlite").path
        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, importance) VALUES
                  ('good', 'good insight content long enough for embed', 5),
                  ('poison', 'BAD poison insight content long enough', 5)
            """)
        }

        let provider = SelectiveFailEmbeddingProvider()
        let first = try await InsightEmbeddingBackfill.run(writer: writer, provider: provider)
        XCTAssertEqual(first.embedded, 1, "R4: good insight must still embed")
        XCTAssertEqual(first.failed, 1, "R4: poison isolated as failure")

        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_embeddings WHERE insight_id = 'good'"),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_embeddings WHERE insight_id = 'poison'"),
                0
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT status FROM insight_embedding_failures WHERE insight_id = 'poison'"
                ),
                "failed_retryable"
            )
        }

        // Exhaust retries → failed_permanent; poison leaves the pending set.
        for _ in 0..<InsightEmbeddingBackfill.maxInsightEmbedRetryCount {
            _ = try await InsightEmbeddingBackfill.run(writer: writer, provider: provider)
        }
        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT status FROM insight_embedding_failures WHERE insight_id = 'poison'"
                ),
                "failed_permanent",
                "R4: terminal after retry budget"
            )
        }
        let stillPending = try InsightEmbeddingBackfill.pendingInsights(writer: writer, limit: 10)
        XCTAssertFalse(
            stillPending.contains(where: { $0.id == "poison" }),
            "R4: permanent failure must not reselect poison forever"
        )
        XCTAssertFalse(stillPending.contains(where: { $0.id == "good" }))
    }

    func testSessionEmbeddingCapsEachProviderRequestBatch() async throws {
        let provider = BatchRecordingEmbeddingProvider()
        let content = (0..<20)
            .map { index in "line-\(index)-" + String(repeating: "x", count: 650) }
            .joined(separator: "\n")
        let pending = [
            SessionEmbeddingBackfill.PendingSession(
                jobId: "job",
                sessionId: "session",
                content: content
            ),
        ]

        let embedded = try await SessionEmbeddingBackfill.embedPendingSessions(
            pending,
            provider: provider,
            maxTextsPerRequest: 4
        )

        XCTAssertEqual(embedded.count, 1)
        XCTAssertEqual(embedded[0].chunks.count, 20)
        let batchSizes = await provider.batchSizes()
        XCTAssertEqual(batchSizes, [4, 4, 4, 4, 4])
    }

    /// M3: one session failure must not abort remaining sessions; failures advance
    /// retry_count and eventually reach failed_permanent.
    func testSessionEmbeddingIsolatesPerSessionFailure_repro() async throws {
        let path = tempDir.appendingPathComponent("m3-embed.sqlite").path
        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()
        try seedEmbeddingSessions(
            writer: writer,
            sessions: [
                ("s-good", "job-good", "good line content long enough"),
                ("s-bad", "job-bad", "BAD line content long enough"),
            ]
        )

        let provider = SelectiveFailEmbeddingProvider()
        let pending = try SessionEmbeddingBackfill.pendingSessions(writer: writer, limit: 10)
        XCTAssertEqual(Set(pending.map(\.sessionId)), ["s-good", "s-bad"])

        let outcome = try await SessionEmbeddingBackfill.embedPendingSessionsIsolated(
            pending,
            provider: provider
        )
        XCTAssertEqual(outcome.embedded.count, 1, "M3: good session must still embed")
        XCTAssertEqual(outcome.embedded.first?.sessionId, "s-good")
        XCTAssertEqual(outcome.failures.count, 1, "M3: bad session isolated as failure")
        XCTAssertEqual(outcome.failures.first?.sessionId, "s-bad")

        let result = try SessionEmbeddingBackfill.writeEmbeddings(
            writer: writer,
            sessions: outcome.embedded,
            model: provider.model,
            dimension: provider.dimension,
            failures: outcome.failures
        )
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(result.failed, 1)

        try writer.read { db in
            let goodStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM session_index_jobs WHERE id = 'job-good'"
            )
            let badStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM session_index_jobs WHERE id = 'job-bad'"
            )
            let badRetries = try Int.fetchOne(
                db,
                sql: "SELECT retry_count FROM session_index_jobs WHERE id = 'job-bad'"
            )
            XCTAssertEqual(goodStatus, "completed")
            XCTAssertEqual(badStatus, "failed_retryable")
            XCTAssertEqual(badRetries, 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 's-good'"),
                1
            )
        }

        // Exhaust retries → failed_permanent so the job stops re-selecting forever.
        for _ in 0..<3 {
            let again = try SessionEmbeddingBackfill.pendingSessions(writer: writer, limit: 10)
            let badOnly = again.filter { $0.sessionId == "s-bad" }
            guard !badOnly.isEmpty else { break }
            let outcome2 = try await SessionEmbeddingBackfill.embedPendingSessionsIsolated(
                badOnly,
                provider: provider
            )
            _ = try SessionEmbeddingBackfill.writeEmbeddings(
                writer: writer,
                sessions: outcome2.embedded,
                model: provider.model,
                dimension: provider.dimension,
                failures: outcome2.failures
            )
        }
        try writer.read { db in
            let finalStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM session_index_jobs WHERE id = 'job-bad'"
            )
            XCTAssertEqual(
                finalStatus,
                "failed_permanent",
                "M3: terminal failure after retry budget, not infinite re-select"
            )
        }
        let stillPending = try SessionEmbeddingBackfill.pendingSessions(writer: writer, limit: 10)
        XCTAssertFalse(
            stillPending.contains(where: { $0.sessionId == "s-bad" }),
            "M3: failed_permanent jobs must leave the pending selection set"
        )
    }

    /// M16: refuse writes when native vector length ≠ configured dimension; store
    /// native count (not configured) when lengths match.
    func testWriteEmbeddingsStoresNativeDimensionAndRefusesMismatch_repro() throws {
        let path = tempDir.appendingPathComponent("m16-embed.sqlite").path
        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()
        try seedEmbeddingSessions(
            writer: writer,
            sessions: [("s1", "job-1", "content line")]
        )

        let mismatch = SessionEmbeddingBackfill.EmbeddedSession(
            jobId: "job-1",
            sessionId: "s1",
            chunks: [
                .init(index: 0, text: "t", vector: [1, 0]), // native 2, configured 3
            ]
        )
        XCTAssertThrowsError(
            try SessionEmbeddingBackfill.writeEmbeddings(
                writer: writer,
                sessions: [mismatch],
                model: "m",
                dimension: 3
            )
        ) { error in
            guard case EmbeddingError.dimensionMismatch(let expected, let actual) = error else {
                return XCTFail("expected dimensionMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 3)
            XCTAssertEqual(actual, 2)
        }

        let ok = SessionEmbeddingBackfill.EmbeddedSession(
            jobId: "job-1",
            sessionId: "s1",
            chunks: [
                .init(index: 0, text: "t", vector: [1, 0, 0]),
            ]
        )
        let written = try SessionEmbeddingBackfill.writeEmbeddings(
            writer: writer,
            sessions: [ok],
            model: "m",
            dimension: 3
        )
        XCTAssertEqual(written.completed, 1)
        try writer.read { db in
            let dim = try Int.fetchOne(
                db,
                sql: "SELECT dim FROM semantic_chunks WHERE session_id = 's1'"
            )
            XCTAssertEqual(dim, 3, "M16: dim column must store native vector count")
            let blob: Data? = try Row.fetchOne(
                db,
                sql: "SELECT embedding FROM semantic_chunks WHERE session_id = 's1'"
            )?["embedding"]
            XCTAssertEqual(VectorMath.decode(try XCTUnwrap(blob)).count, 3)
        }
    }

    /// M17: model/dimension change purges stale vectors and re-enqueues embedding jobs.
    func testModelDimensionChangePurgesAndReenqueues_repro() async throws {
        let path = tempDir.appendingPathComponent("m17-embed.sqlite").path
        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()
        try seedEmbeddingSessions(
            writer: writer,
            sessions: [("s1", "job-1", "content for embedding line")]
        )

        let providerA = FakeEmbeddingProvider()
        let pending = try SessionEmbeddingBackfill.pendingSessions(writer: writer, limit: 5)
        let embedded = try await SessionEmbeddingBackfill.embedPendingSessionsIsolated(
            pending,
            provider: providerA
        )
        _ = try SessionEmbeddingBackfill.writeEmbeddings(
            writer: writer,
            sessions: embedded.embedded,
            model: providerA.model,
            dimension: providerA.dimension,
            failures: embedded.failures
        )
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM embedding_meta WHERE id = 1"), "fake-model")
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT status FROM session_index_jobs WHERE id = 'job-1'"),
                "completed"
            )
        }

        let changed = try InsightEmbeddingBackfill.reconcileModelChangeIfNeeded(
            writer: writer,
            model: "model-b",
            dimension: 4
        )
        XCTAssertTrue(changed)
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_embeddings"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM embedding_meta WHERE id = 1"), "model-b")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dimension FROM embedding_meta WHERE id = 1"), 4)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT status FROM session_index_jobs WHERE id = 'job-1'"),
                "pending",
                "M17: completed embedding jobs must re-enqueue after model change"
            )
        }

        let providerB = ModelBEmbeddingProvider()
        let rePending = try SessionEmbeddingBackfill.pendingSessions(writer: writer, limit: 5)
        XCTAssertEqual(rePending.count, 1)
        let reEmbedded = try await SessionEmbeddingBackfill.embedPendingSessionsIsolated(
            rePending,
            provider: providerB
        )
        _ = try SessionEmbeddingBackfill.writeEmbeddings(
            writer: writer,
            sessions: reEmbedded.embedded,
            model: providerB.model,
            dimension: providerB.dimension,
            failures: reEmbedded.failures
        )
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dim FROM semantic_chunks WHERE session_id = 's1'"), 4)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM semantic_chunks WHERE session_id = 's1'"), "model-b")
        }
    }

    private func seedEmbeddingSessions(
        writer: EngramDatabaseWriter,
        sessions: [(sessionId: String, jobId: String, fts: String)]
    ) throws {
        try writer.write { db in
            for item in sessions {
                try db.execute(
                    sql: """
                    INSERT INTO sessions(
                      id, source, start_time, file_path, project, tier, hidden_at, summary
                    ) VALUES (?, 'codex', datetime('now'), ?, 'p', 'normal', NULL, ?)
                    """,
                    arguments: [item.sessionId, "/tmp/\(item.sessionId).jsonl", item.fts]
                )
                try db.execute(
                    sql: """
                    INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)
                    """,
                    arguments: [item.sessionId, item.fts]
                )
                try db.execute(
                    sql: """
                    INSERT INTO session_index_jobs(
                      id, session_id, job_kind, target_sync_version, status, retry_count, created_at, updated_at
                    ) VALUES (?, ?, 'embedding', 0, 'pending', 0, datetime('now'), datetime('now'))
                    """,
                    arguments: [item.jobId, item.sessionId]
                )
            }
        }
    }
}
