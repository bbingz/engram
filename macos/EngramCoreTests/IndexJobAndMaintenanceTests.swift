import GRDB
import Foundation
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

/// Stub adapter that ignores the locator and yields a fixed message list,
/// used to drive the FTS job runner end-to-end without a real on-disk transcript.
private final class StubFTSAdapter: SessionAdapter {
    let source: SourceName
    let messages: [NormalizedMessage]

    init(source: SourceName, messages: [NormalizedMessage]) {
        self.source = source
        self.messages = messages
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [] }
    func isAccessible(locator: String) async -> Bool { true }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.fileMissing)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        let messages = self.messages
        return AsyncThrowingStream { continuation in
            for message in messages {
                continuation.yield(message)
            }
            continuation.finish()
        }
    }
}

private final class ThrowingFTSAdapter: SessionAdapter {
    let source: SourceName
    let error: Error

    init(source: SourceName, error: Error) {
        self.source = source
        self.error = error
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [] }
    func isAccessible(locator: String) async -> Bool { true }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.fileMissing)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        throw error
    }
}

/// Sink that always reports failures, to prove the indexer does not fake-count.
private final class AllFailUpsertSink: IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        SessionBatchUpsertResult(
            reason: reason,
            results: snapshots.map {
                SessionBatchItemResult(sessionId: $0.id, action: .failure, enqueuedJobs: [], error: "boom")
            }
        )
    }
}

/// Sink that streams from another adapter so indexAll has something to write,
/// but fails every other row to verify partial counting.
private final class HalfFailUpsertSink: IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        var results: [SessionBatchItemResult] = []
        for (index, snapshot) in snapshots.enumerated() {
            let action: SessionWriteAction = index.isMultiple(of: 2) ? .merge : .failure
            results.append(
                SessionBatchItemResult(
                    sessionId: snapshot.id,
                    action: action,
                    enqueuedJobs: [],
                    error: action == .failure ? "boom" : nil
                )
            )
        }
        return SessionBatchUpsertResult(reason: reason, results: results)
    }
}

final class IndexJobAndMaintenanceTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-job-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB { try? FileManager.default.removeItem(at: tempDB) }
        tempDB = nil
    }

    // MARK: - V1: FTS content is written end-to-end through the real writer path

    func testIndexJobRunnerWritesSearchableFtsContent() async throws {
        // Real session file on disk so the runner accepts the locator.
        let locator = FileManager.default.temporaryDirectory
            .appendingPathComponent("fts-source-\(UUID().uuidString).jsonl")
        try Data("{}".utf8).write(to: locator)
        defer { try? FileManager.default.removeItem(at: locator) }

        // Insert a real session (tier=normal) via the real writer path, which
        // enqueues a pending FTS job. FTS table starts empty (not pre-seeded).
        let snapshot = AuthoritativeSessionSnapshot(
            id: "fts-sess-1",
            source: .claudeCode,
            authoritativeNode: "node-a",
            syncVersion: 1,
            snapshotHash: "h1",
            indexedAt: "2026-03-18T12:00:00Z",
            sourceLocator: locator.path,
            sizeBytes: 128,
            startTime: "2026-03-18T11:00:00Z",
            endTime: nil,
            cwd: "/repo",
            project: "demo",
            model: "claude",
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: "session summary",
            summaryMessageCount: nil,
            origin: nil,
            tier: .normal,
            agentRole: nil,
            toolCallCounts: [:]
        )

        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch([snapshot], reason: .initialScan)
        }

        // Precondition: FTS empty, FTS job pending.
        let preFtsCount = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts") ?? -1
        }
        XCTAssertEqual(preFtsCount, 0, "FTS must start empty (not pre-seeded)")
        let pendingFts = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM session_index_jobs WHERE job_kind = 'fts' AND status = 'pending'"
            ) ?? 0
        }
        XCTAssertEqual(pendingFts, 1, "an FTS job must have been enqueued")

        // Drain via the real runner with a stub adapter producing known content.
        let adapter = StubFTSAdapter(
            source: .claudeCode,
            messages: [
                NormalizedMessage(role: .user, content: "please refactor the authentication module"),
                NormalizedMessage(role: .assistant, content: "done, the authentication flow now uses tokens"),
                NormalizedMessage(role: .tool, content: "tool output should be skipped"),
            ]
        )
        let runner = IndexJobRunner(writer: writer, adapters: [adapter])
        let summary = try await runner.runRecoverableJobs()
        XCTAssertEqual(summary.completed, 1)

        // FTS content is now keyword-searchable via the read path.
        let hits = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM sessions_fts f
                JOIN sessions s ON s.id = f.session_id
                WHERE sessions_fts MATCH ?
                """,
                arguments: ["authentication"]
            ) ?? 0
        }
        XCTAssertGreaterThan(hits, 0, "indexed content must be keyword-searchable")

        // user + assistant + summary rows present; tool message excluded.
        let rows = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 'fts-sess-1'")
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(rows.contains { $0.contains("tool output") })
        XCTAssertTrue(rows.contains("session summary"))

        // Job is marked completed (no longer pending/retryable).
        let remaining = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM session_index_jobs WHERE status IN ('pending','failed_retryable')"
            ) ?? -1
        }
        XCTAssertEqual(remaining, 0)
    }

    func testEmbeddingJobsAreMarkedNotApplicable() async throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('emb-1', 'claude-code', '2026-03-18T11:00:00Z', '/tmp/x.jsonl', 'normal')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs (id, session_id, job_kind, target_sync_version, status)
                VALUES ('emb-1:1:h:embedding', 'emb-1', 'embedding', 1, 'pending')
                """
            )
        }

        let runner = IndexJobRunner(writer: writer, adapters: [])
        let summary = try await runner.runRecoverableJobs()
        XCTAssertEqual(summary.notApplicable, 1)

        let status = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM session_index_jobs WHERE id = 'emb-1:1:h:embedding'")
        }
        XCTAssertEqual(status, "not_applicable")
    }

    // runRecoverableJobsOnce processes a single batch and reports whether the
    // backlog is drained, so the service can loop it across separate gated write
    // commands instead of holding the write gate for the whole drain.
    func testRunRecoverableJobsOnceProcessesOneBatchAndReportsDrained() async throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('s', 'claude-code', '2026-03-18T11:00:00Z', '/tmp/x.jsonl', 'normal')
                """
            )
            for i in 1...3 {
                try db.execute(
                    sql: """
                    INSERT INTO session_index_jobs (id, session_id, job_kind, target_sync_version, status)
                    VALUES ('s:\(i):h:embedding', 's', 'embedding', \(i), 'pending')
                    """
                )
            }
        }

        let runner = IndexJobRunner(writer: writer, adapters: [])
        // A sub-batch-size backlog is fully processed in one call, reports drained.
        let first = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(first.result.notApplicable, 3)
        XCTAssertTrue(first.drained)

        // A second call finds nothing pending and reports drained immediately.
        let second = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(second.result.completed + second.result.notApplicable, 0)
        XCTAssertTrue(second.drained)
    }

    func testMissingFtsSourceIsMarkedNotApplicableInsteadOfRetryingForever() async throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('missing-fts', 'claude-code', '2026-05-25T11:00:00Z', '/tmp/engram-missing-fts.jsonl', 'normal')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs (id, session_id, job_kind, target_sync_version, status)
                VALUES ('missing-fts:1:h:fts', 'missing-fts', 'fts', 1, 'pending')
                """
            )
        }

        let runner = IndexJobRunner(
            writer: writer,
            adapters: [ThrowingFTSAdapter(source: .claudeCode, error: ParserFailure.fileMissing)]
        )
        let summary = try await runner.runRecoverableJobs()
        XCTAssertEqual(summary.notApplicable, 1)

        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT status, retry_count, last_error
                FROM session_index_jobs
                WHERE id = 'missing-fts:1:h:fts'
                """
            )
        }
        XCTAssertEqual(row?["status"] as String?, "not_applicable")
        XCTAssertEqual(row?["retry_count"] as Int?, 0)
        XCTAssertNil(row?["last_error"] as String?)

        let retryable = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM session_index_jobs WHERE status IN ('pending','failed_retryable')"
            ) ?? -1
        }
        XCTAssertEqual(retryable, 0)
    }

    func testRecentIndexDoesNotRunHistoricalParentBackfills() async throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                    id, source, start_time, cwd, project, summary, file_path,
                    message_count, user_message_count, assistant_message_count,
                    tool_message_count, system_message_count
                )
                VALUES (
                    'periodic-child', 'codex', '2026-05-25T10:00:00Z',
                    '/repo', 'repo', 'No tools. Review the implementation.',
                    '/tmp/periodic-child.jsonl', 1, 1, 0, 0, 0
                )
                """
            )
        }

        _ = try await writer.indexRecentSessions(adapters: [])

        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT agent_role, tier, link_checked_at
                FROM sessions
                WHERE id = 'periodic-child'
                """
            )
        }

        XCTAssertNil(row?["agent_role"] as String?)
        XCTAssertNil(row?["tier"] as String?)
        XCTAssertNil(row?["link_checked_at"] as String?)
    }

    // MARK: - V3: indexAll counts only written rows, not attempts

    func testIndexAllDoesNotFakeCountOnFailure() async throws {
        let snapshots = (0..<5).map { makeMinimalSnapshot(id: "s\($0)") }
        let indexer = SwiftIndexer(sink: AllFailUpsertSink())
        let written = try indexer.indexSnapshots(snapshots)
        XCTAssertTrue(written.results.allSatisfy { $0.action == .failure })

        // indexAll over a stub stream that fails half the rows.
        let adapter = StubInfoAdapter(count: 4)
        let half = SwiftIndexer(sink: HalfFailUpsertSink(), adapters: [adapter])
        let count = try await half.indexAll()
        // 4 snapshots, even indices succeed (0, 2) => 2 written.
        XCTAssertEqual(count, 2, "must count only actually-written rows, not attempts")
    }

    func testIndexStatusThrowsOnMissingSchema() throws {
        // Fresh DB without migration → no sessions table.
        let bareDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("bare-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: bareDB) }
        let bareWriter = try EngramDatabaseWriter(path: bareDB.path)
        // indexStatus tolerates missing schema but marks it (not a silent empty DB).
        let status = try bareWriter.indexStatus()
        XCTAssertFalse(status.schemaPresent)
        XCTAssertEqual(status.total, 0)
        // verifySchemaPresent is the composition-root fail-fast check.
        XCTAssertThrowsError(try bareWriter.verifySchemaPresent()) { error in
            XCTAssertTrue(error is EngramDatabaseIndexStatusError)
        }
    }

    // MARK: - WP-H1: suggested-parent 24h window normalizes both sides

    func testSuggestedParentWindowNormalizesBothSides() throws {
        try writer.write { db in
            // Parent uses fractional-seconds ISO; child uses non-fractional.
            try db.execute(
                sql: """
                INSERT INTO sessions (id, source, start_time, file_path, cwd, project, parent_session_id, tier)
                VALUES ('parent-1', 'claude-code', '2026-03-18T11:00:00.500Z', '/tmp/p.jsonl', '/repo', 'demo', NULL, 'normal')
                """
            )
            // Child 1 hour later, dispatch summary, no fractional seconds.
            try db.execute(
                sql: """
                INSERT INTO sessions (id, source, start_time, file_path, cwd, project, summary, tier)
                VALUES ('child-1', 'codex', '2026-03-18T12:00:00Z', '/tmp/c.jsonl', '/repo', 'demo',
                        'Your task is to investigate the failing build', 'normal')
                """
            )
        }

        let result = try writer.write { db in
            try StartupBackfills.backfillSuggestedParents(db)
        }
        XCTAssertEqual(result.checked, 1)

        let suggested = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'child-1'")
        }
        // The child must find the parent inside the (normalized) 24h window.
        XCTAssertEqual(suggested, "parent-1")
    }

    // MARK: - WP-H3: cascade trigger resets tier for suggested children, preserves skip for subagents

    func testCascadeTriggerResetsSuggestedChildTierPreservingSubagents() throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO sessions (id, source, start_time, file_path, tier) VALUES ('p', 'claude-code', '2026-03-18T11:00:00Z', '/tmp/p.jsonl', 'normal')"
            )
            // Suggested child (non-subagent): tier should reset to NULL on parent delete.
            try db.execute(
                sql: "INSERT INTO sessions (id, source, start_time, file_path, suggested_parent_id, tier, agent_role) VALUES ('sug', 'codex', '2026-03-18T11:00:00Z', '/tmp/s.jsonl', 'p', 'normal', NULL)"
            )
            // Confirmed subagent child: tier must stay 'skip'.
            try db.execute(
                sql: "INSERT INTO sessions (id, source, start_time, file_path, parent_session_id, tier, agent_role) VALUES ('sub', 'codex', '2026-03-18T11:00:00Z', '/tmp/sub.jsonl', 'p', 'skip', 'subagent')"
            )
            try db.execute(sql: "DELETE FROM sessions WHERE id = 'p'")
        }

        let (sugTier, sugSuggested, subTier, subParent): (String?, String?, String?, String?) = try writer.read { db in
            let sug = try Row.fetchOne(db, sql: "SELECT tier, suggested_parent_id FROM sessions WHERE id = 'sug'")
            let sub = try Row.fetchOne(db, sql: "SELECT tier, parent_session_id FROM sessions WHERE id = 'sub'")
            return (sug?["tier"], sug?["suggested_parent_id"], sub?["tier"], sub?["parent_session_id"])
        }
        XCTAssertNil(sugSuggested, "suggested link must be cleared")
        XCTAssertNil(sugTier, "non-subagent suggested child tier must reset to NULL")
        XCTAssertNil(subParent, "subagent parent link must be cleared")
        XCTAssertEqual(subTier, "skip", "true subagent tier must stay 'skip'")
    }

    // The menu-bar "today's parents" badge must match the UI top-level filter:
    // exclude sessions that have a suggested parent and skip-tier noise, not just
    // confirmed children. Future start_time keeps every row inside the badge's
    // `start_time >= startOfToday` window deterministically.
    func testIndexStatusTodayParentsExcludesSuggestedAndSkip() throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO sessions (id, source, start_time, file_path, tier) VALUES ('top', 'claude-code', '2099-01-01T00:00:00Z', '/tmp/top.jsonl', 'normal')")
            try db.execute(sql: "INSERT INTO sessions (id, source, start_time, file_path, suggested_parent_id, tier) VALUES ('sug', 'codex', '2099-01-01T00:00:00Z', '/tmp/sug.jsonl', 'top', 'normal')")
            try db.execute(sql: "INSERT INTO sessions (id, source, start_time, file_path, parent_session_id, tier, agent_role) VALUES ('sub', 'codex', '2099-01-01T00:00:00Z', '/tmp/sub.jsonl', 'top', 'skip', 'subagent')")
            try db.execute(sql: "INSERT INTO sessions (id, source, start_time, file_path, tier) VALUES ('skipTop', 'codex', '2099-01-01T00:00:00Z', '/tmp/skip.jsonl', 'skip')")
        }

        let status = try writer.indexStatus()
        XCTAssertEqual(status.todayParents, 1, "only the genuine top-level normal session counts")
    }

    // MARK: - WP-M1: reconcileInsights does not wipe vector store when insights empty

    func testReconcileInsightsDoesNotWipeVectorStoreWhenInsightsEmpty() throws {
        try writer.write { db in
            // memory_insights has live rows; insights table is empty.
            try db.execute(
                sql: "INSERT INTO memory_insights (id, content) VALUES ('mi-1', 'vector content')"
            )
        }

        let result = try writer.write { db in
            try StartupBackfills.reconcileInsights(db)
        }
        XCTAssertEqual(result.orphanedVector, 0, "empty insights table must not soft-delete vectors")

        let live = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_insights WHERE deleted_at IS NULL") ?? 0
        }
        XCTAssertEqual(live, 1, "vector row must survive")
    }

    func testReconcileInsightsSoftDeletesTrueOrphansWhenInsightsPresent() throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO insights (id, content) VALUES ('keep', 'kept')")
            try db.execute(sql: "INSERT INTO memory_insights (id, content) VALUES ('keep', 'kept vector')")
            try db.execute(sql: "INSERT INTO memory_insights (id, content) VALUES ('orphan', 'orphan vector')")
        }

        let result = try writer.write { db in
            try StartupBackfills.reconcileInsights(db)
        }
        XCTAssertEqual(result.orphanedVector, 1, "true orphan must be soft-deleted")

        let orphanDeleted = try writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT deleted_at IS NOT NULL FROM memory_insights WHERE id = 'orphan'"
            ) ?? false
        }
        XCTAssertTrue(orphanDeleted)
    }

    // MARK: - Helpers

    private func makeMinimalSnapshot(id: String) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id,
            source: .codex,
            authoritativeNode: "node-a",
            syncVersion: 1,
            snapshotHash: "h-\(id)",
            indexedAt: "2026-03-18T12:00:00Z",
            sourceLocator: "/tmp/\(id).jsonl",
            sizeBytes: 1,
            startTime: "2026-03-18T11:00:00Z",
            endTime: nil,
            cwd: "/repo",
            project: nil,
            model: nil,
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: "s",
            summaryMessageCount: nil,
            origin: nil,
            tier: .normal,
            agentRole: nil,
            toolCallCounts: [:]
        )
    }
}

/// Adapter that yields N parseable sessions so SwiftIndexer.indexAll has a stream.
private final class StubInfoAdapter: SessionAdapter {
    let source: SourceName = .codex
    let count: Int

    init(count: Int) { self.count = count }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { (0..<count).map { "/tmp/loc-\($0).jsonl" } }
    func isAccessible(locator: String) async -> Bool { true }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .success(
            NormalizedSessionInfo(
                id: "info-\(locator)",
                source: .codex,
                startTime: "2026-03-18T11:00:00Z",
                cwd: "/repo",
                messageCount: 2,
                userMessageCount: 1,
                assistantMessageCount: 1,
                toolMessageCount: 0,
                systemMessageCount: 0,
                filePath: locator,
                sizeBytes: 1
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(NormalizedMessage(role: .user, content: "hi"))
            continuation.yield(NormalizedMessage(role: .assistant, content: "hello"))
            continuation.finish()
        }
    }
}
