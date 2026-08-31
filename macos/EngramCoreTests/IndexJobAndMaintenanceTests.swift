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

/// Reports truncation metadata while still streaming the full message list,
/// matching adapters that only cap on the metadata path.
private final class TruncatingFTSAdapter: SessionAdapter {
    let source: SourceName
    let messages: [NormalizedMessage]
    let truncatedAt: Int

    init(source: SourceName, messages: [NormalizedMessage], truncatedAt: Int) {
        self.source = source
        self.messages = messages
        self.truncatedAt = truncatedAt
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

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        StreamMessagesResult(
            messages: try await streamMessages(locator: locator, options: options),
            totalKnownComplete: false,
            truncatedAt: truncatedAt
        )
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

private final class AllNoopUpsertSink: IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        SessionBatchUpsertResult(
            reason: reason,
            results: snapshots.map {
                SessionBatchItemResult(sessionId: $0.id, action: .noop, enqueuedJobs: [])
            }
        )
    }
}

private final class FileStateFailingSink: IndexingWriteSink {
    var fileStateAttempts = 0
    var receivedSessionIds: [String] = []
    var receivedFileStateLocators: [String] = []

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        receivedSessionIds.append(contentsOf: snapshots.map(\.id))
        return SessionBatchUpsertResult(
            reason: reason,
            results: snapshots.map {
                SessionBatchItemResult(sessionId: $0.id, action: .merge, enqueuedJobs: [], error: nil)
            }
        )
    }

    func upsertFileIndexState(_ state: FileIndexState) throws {
        fileStateAttempts += 1
        receivedFileStateLocators.append(state.locator)
        throw NSError(domain: "FileStateFailingSink", code: 1)
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

        // The FTS job is marked completed; embedding jobs remain service-owned
        // until a provider-backed backfill runs.
        let remainingFts = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM session_index_jobs
                WHERE job_kind = 'fts'
                  AND status IN ('pending','failed_retryable')
                """
            ) ?? -1
        }
        XCTAssertEqual(remainingFts, 0)
    }

    /// FTS drain used streamMessages, so a truncated-and-marked adapter still
    /// completed the job on a silently incomplete prefix.
    func testFtsJobFailsClosedWhenAdapterReportsTruncation_repro() async throws {
        let locator = FileManager.default.temporaryDirectory
            .appendingPathComponent("fts-truncated-\(UUID().uuidString).jsonl")
        try Data("{}".utf8).write(to: locator)
        defer { try? FileManager.default.removeItem(at: locator) }

        let snapshot = AuthoritativeSessionSnapshot(
            id: "fts-trunc-1",
            source: .claudeCode,
            authoritativeNode: "node-a",
            syncVersion: 1,
            snapshotHash: "h-trunc",
            indexedAt: "2026-08-14T12:00:00Z",
            sourceLocator: locator.path,
            sizeBytes: 128,
            startTime: "2026-08-14T11:00:00Z",
            endTime: nil,
            cwd: "/repo",
            project: "demo",
            model: "claude",
            messageCount: 4,
            userMessageCount: 2,
            assistantMessageCount: 2,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: "truncated session",
            summaryMessageCount: nil,
            origin: nil,
            tier: .normal,
            agentRole: nil,
            toolCallCounts: [:]
        )

        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch([snapshot], reason: .initialScan)
        }

        let adapter = TruncatingFTSAdapter(
            source: .claudeCode,
            messages: [
                NormalizedMessage(role: .user, content: "turn 0"),
                NormalizedMessage(role: .assistant, content: "turn 1"),
                NormalizedMessage(role: .user, content: "turn 2"),
                NormalizedMessage(role: .assistant, content: "turn 3"),
            ],
            truncatedAt: 3
        )
        let runner = IndexJobRunner(writer: writer, adapters: [adapter])
        let (summary, _) = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(summary.completed, 0)
        XCTAssertEqual(summary.notApplicable, 0)

        let status = try writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT status FROM session_index_jobs WHERE session_id = 'fts-trunc-1' AND job_kind = 'fts'"
            )
        }
        XCTAssertEqual(status, "failed_retryable")
        let ftsCount = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'fts-trunc-1'") ?? -1
        }
        XCTAssertEqual(ftsCount, 0)
    }

    func testFtsVersionRebuildSwapsOnlyAfterShadowTableIsComplete() async throws {
        let locator = FileManager.default.temporaryDirectory
            .appendingPathComponent("fts-rebuild-\(UUID().uuidString).jsonl")
        try Data("{}".utf8).write(to: locator)
        defer { try? FileManager.default.removeItem(at: locator) }

        let snapshot = AuthoritativeSessionSnapshot(
            id: "fts-rebuild-1",
            source: .claudeCode,
            authoritativeNode: "node-a",
            syncVersion: 1,
            snapshotHash: "h1",
            indexedAt: "2026-05-30T12:00:00Z",
            sourceLocator: locator.path,
            sizeBytes: 128,
            startTime: "2026-05-30T11:00:00Z",
            endTime: nil,
            cwd: "/repo",
            project: "demo",
            model: "claude",
            messageCount: 1,
            userMessageCount: 1,
            assistantMessageCount: 0,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: nil,
            summaryMessageCount: nil,
            origin: nil,
            tier: .normal,
            agentRole: nil,
            toolCallCounts: [:]
        )

        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch([snapshot], reason: .initialScan)
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE session_id = 'fts-rebuild-1'")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('fts-rebuild-1', 'legacy searchable phrase')")
            try db.execute(sql: """
                INSERT INTO metadata(key, value) VALUES ('fts_version', '2')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """)
            try FTSRebuildPolicy.apply(db)
        }

        try writer.read { db in
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 'fts-rebuild-1'"),
                ["legacy searchable phrase"],
                "active search table must remain live until the rebuild table is complete"
            )
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_rebuild_version'"))
        }

        let adapter = StubFTSAdapter(
            source: .claudeCode,
            messages: [
                NormalizedMessage(role: .user, content: "rebuilt searchable phrase"),
            ]
        )
        let runner = IndexJobRunner(writer: writer, adapters: [adapter])
        let summary = try await runner.runRecoverableJobs()
        XCTAssertEqual(summary.completed, 1)

        try writer.read { db in
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 'fts-rebuild-1'"),
                ["rebuilt searchable phrase"]
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_version'"), "3")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_rebuild_version'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE name = 'sessions_fts_rebuild'"))
        }
    }

    func testFtsRebuildFinalizesAfterNotApplicableOnlyTail_repro() async throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('fts-na-only', 'claude-code', '2026-03-18T11:00:00Z', '/tmp/na.jsonl', 'skip');
                INSERT INTO session_index_jobs (
                  id, session_id, job_kind, target_sync_version, status
                ) VALUES ('fts-na-only:1:h:fts', 'fts-na-only', 'fts', 1, 'completed');
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('fts-na-only', 'legacy skip content');
                INSERT INTO metadata(key, value) VALUES ('fts_version', '2')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """)
            try FTSRebuildPolicy.apply(db)
        }

        let result = try await IndexJobRunner(writer: writer, adapters: []).runRecoverableJobs()

        // The rebuild policy excludes completed skip rows before the drain, so
        // finalization needs no synthetic terminal not_applicable transition.
        XCTAssertEqual(result.notApplicable, 0)
        try writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_version'"), "3")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_rebuild_version'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE name = 'sessions_fts_rebuild'"))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'fts-na-only'"),
                0
            )
        }
    }

    func testFtsRebuildFinalizesWhenRecoverableDrainIsAlreadyEmpty_repro() async throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('fts-empty-tail', 'claude-code', '2026-03-18T11:00:00Z', '/tmp/empty.jsonl', 'normal');
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('fts-empty-tail', 'legacy searchable content');
                INSERT INTO metadata(key, value) VALUES ('fts_version', '2')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """)
            try FTSRebuildPolicy.apply(db)
        }

        let result = try await IndexJobRunner(writer: writer, adapters: []).runRecoverableJobs()

        XCTAssertEqual(result, StartupIndexJobRecoveryResult(completed: 0, notApplicable: 0))
        try writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_version'"), "3")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE name = 'sessions_fts_rebuild'"))
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 'fts-empty-tail'"),
                ["legacy searchable content"]
            )
        }
    }

    func testEmbeddingJobsRemainPendingWithoutProvider() async throws {
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
        XCTAssertEqual(summary.notApplicable, 0)
        XCTAssertEqual(summary.completed, 0)

        let status = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM session_index_jobs WHERE id = 'emb-1:1:h:embedding'")
        }
        XCTAssertEqual(status, "pending")
    }

    func testMissingEnabledAdapterLeavesFtsJobRecoverable_repro() async throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('disabled-source-fts', 'claude-code', '2026-08-21T00:00:00Z', '/tmp/disabled.jsonl', 'normal')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs (id, session_id, job_kind, target_sync_version, status)
                VALUES ('disabled-source-fts:1:h:fts', 'disabled-source-fts', 'fts', 1, 'pending')
                """
            )
        }

        let runner = IndexJobRunner(writer: writer, adapters: [])
        let summary = try await runner.runRecoverableJobs()
        XCTAssertEqual(summary.completed, 0)
        XCTAssertEqual(summary.notApplicable, 0)

        let status = try writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT status FROM session_index_jobs WHERE id = 'disabled-source-fts:1:h:fts'"
            )
        }
        XCTAssertEqual(status, IndexJobStatus.pending.rawValue)
    }

    func testMissingAdapterRowsDoNotStarveEnabledFtsJobs_repro() async throws {
        try writer.write { db in
            for index in 0 ..< IndexJobRunner.drainBatchSize {
                try db.execute(
                    sql: """
                        INSERT INTO sessions (id, source, start_time, file_path, tier)
                        VALUES (?, 'opencode', '2026-03-18T11:00:00Z', '/tmp/missing-\(index).jsonl', 'normal')
                        """,
                    arguments: ["missing-\(index)"]
                )
                try db.execute(
                    sql: """
                        INSERT INTO session_index_jobs (
                          id, session_id, job_kind, target_sync_version, status
                        ) VALUES (?, ?, 'fts', 1, 'pending')
                        """,
                    arguments: ["missing-\(index):1:fts", "missing-\(index)"]
                )
            }
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('enabled-tail', 'claude-code', '2026-03-18T11:00:00Z', '/tmp/enabled.jsonl', 'normal')
                """)
            try db.execute(sql: """
                INSERT INTO session_index_jobs (
                  id, session_id, job_kind, target_sync_version, status
                ) VALUES ('enabled-tail:1:fts', 'enabled-tail', 'fts', 1, 'pending')
                """)
        }

        let runner = IndexJobRunner(
            writer: writer,
            adapters: [StubFTSAdapter(
                source: .claudeCode,
                messages: [NormalizedMessage(role: .user, content: "enabled source")]
            )]
        )
        let summary = try await runner.runRecoverableJobs()

        XCTAssertEqual(summary.completed, 1)
        let statuses = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT session_id, status FROM session_index_jobs ORDER BY session_id"
            ).map { ($0["session_id"] as String, $0["status"] as String) }
        }
        XCTAssertEqual(statuses.first { $0.0 == "enabled-tail" }?.1, "completed")
        XCTAssertEqual(statuses.filter { $0.0.hasPrefix("missing-") && $0.1 == "pending" }.count, IndexJobRunner.drainBatchSize)
    }

    func testFtsRebuildIgnoresJobsForAbsentSources_repro() async throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('archived-tail', 'archived-default-off', '2026-03-18T11:00:00Z', '/tmp/archived.jsonl', 'normal')
                """)
            try db.execute(sql: """
                INSERT INTO session_index_jobs (
                  id, session_id, job_kind, target_sync_version, status
                ) VALUES ('archived-tail:1:fts', 'archived-tail', 'fts', 1, 'pending')
                """)
            try db.execute(sql: """
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('archived-tail', 'legacy archived content')
                """)
            try db.execute(sql: """
                INSERT INTO metadata(key, value) VALUES ('fts_version', '2')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """)
            try FTSRebuildPolicy.apply(db)
        }

        _ = try await IndexJobRunner(writer: writer, adapters: []).runRecoverableJobs()

        try writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_version'"), "3")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_rebuild_version'"))
        }
    }

    func testFtsRebuildIgnoresPendingRealDisabledSourceWhileClaudeEnabled_repro() async throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('cline-disabled-tail', 'cline', '2026-08-22T00:00:00Z', '/tmp/cline.jsonl', 'normal');
                INSERT INTO session_index_jobs (id, session_id, job_kind, target_sync_version, status)
                VALUES ('cline-disabled-tail:1:fts', 'cline-disabled-tail', 'fts', 1, 'pending');
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('cline-disabled-tail', 'live cline keyword row');
                INSERT INTO metadata(key, value) VALUES ('fts_version', '2')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """)
            try FTSRebuildPolicy.apply(db)
        }

        let runner = IndexJobRunner(
            writer: writer,
            adapters: [StubFTSAdapter(source: .claudeCode, messages: [])]
        )
        let result = try await runner.runRecoverableJobsOnce()

        XCTAssertTrue(result.drained)
        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT status FROM session_index_jobs WHERE id='cline-disabled-tail:1:fts'"),
                "pending"
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='fts_version'"), "3")
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id='cline-disabled-tail'"),
                ["live cline keyword row"]
            )
        }
    }

    func testRunOnceDoesNotReportDrainedWhileEligibleRetryableFtsJobRemains_repro() async throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('retryable-drain', 'claude-code', '2026-08-22T00:00:00Z', '/tmp/retryable.jsonl', 'normal');
                INSERT INTO session_index_jobs (id, session_id, job_kind, target_sync_version, status)
                VALUES ('retryable-drain:1:fts', 'retryable-drain', 'fts', 1, 'pending');
                """)
        }
        let runner = IndexJobRunner(
            writer: writer,
            adapters: [ThrowingFTSAdapter(source: .claudeCode, error: ParserFailure.fileMissing)]
        )

        let result = try await runner.runRecoverableJobsOnce()

        XCTAssertFalse(result.drained)
        XCTAssertEqual(result.result.completed, 0)
        XCTAssertEqual(result.result.notApplicable, 0)
    }

    func testRetryableFtsFailureGetsBackoffAndStopsCurrentDrainWave_repro() async throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('retry-wave', 'claude-code', '2026-08-23T00:00:00Z', '/tmp/retry-wave.jsonl', 'normal');
                INSERT INTO session_index_jobs (id, session_id, job_kind, target_sync_version, status)
                VALUES ('retry-wave:1:fts', 'retry-wave', 'fts', 1, 'pending');
                """)
        }
        let runner = IndexJobRunner(
            writer: writer,
            adapters: [ThrowingFTSAdapter(source: .claudeCode, error: ParserFailure.fileMissing)]
        )

        _ = try await runner.runRecoverableJobsOnce()

        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT status, retry_count, not_before,
                           not_before > datetime('now') AS is_deferred
                    FROM session_index_jobs WHERE id = 'retry-wave:1:fts'
                    """
            )
        }
        XCTAssertEqual(row?["status"] as String?, "failed_retryable")
        XCTAssertEqual(row?["retry_count"] as Int?, 1, "one drain wave must spend at most one retry")
        XCTAssertNotNil(row?["not_before"] as String?)
        XCTAssertEqual(row?["is_deferred"] as Int?, 1)
    }

    func testFutureFtsJobDoesNotReportDrainedAndRunsWhenDue_repro() async throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('future-drain', 'claude-code', '2026-08-23T00:00:00Z', '/tmp/future.jsonl', 'normal');
                INSERT INTO session_index_jobs (
                  id, session_id, job_kind, target_sync_version, status, not_before
                ) VALUES (
                  'future-drain:1:fts', 'future-drain', 'fts', 1, 'pending', datetime('now', '+1 second')
                );
                """)
        }
        let runner = IndexJobRunner(
            writer: writer,
            adapters: [StubFTSAdapter(
                source: .claudeCode,
                messages: [NormalizedMessage(role: .user, content: "future searchable content")]
            )]
        )

        let first = try await runner.runRecoverableJobsOnce()
        XCTAssertFalse(first.drained)
        let result = try await runner.runRecoverableJobs()

        XCTAssertEqual(result.completed, 1)
        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT content FROM sessions_fts WHERE session_id = 'future-drain'"
                ),
                "future searchable content"
            )
        }
    }

    func testDeferredRetryDoesNotStopWaveWhileDueFtsWorkRemains_repro() throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier) VALUES
                  ('deferred-wave', 'claude-code', '2026-08-23T00:00:00Z', '/tmp/deferred.jsonl', 'normal'),
                  ('due-wave', 'claude-code', '2026-08-23T00:00:00Z', '/tmp/due.jsonl', 'normal');
                INSERT INTO session_index_jobs (
                  id, session_id, job_kind, target_sync_version, status, not_before
                ) VALUES
                  ('deferred-wave:1:fts', 'deferred-wave', 'fts', 1, 'failed_retryable', datetime('now', '+30 seconds')),
                  ('due-wave:1:fts', 'due-wave', 'fts', 1, 'pending', NULL);
                """)
        }
        let runner = IndexJobRunner(
            writer: writer,
            adapters: [StubFTSAdapter(source: .claudeCode, messages: [])]
        )

        XCTAssertFalse(try runner.shouldStopFtsDrainWave())
        try writer.write { db in
            try db.execute(sql: "DELETE FROM session_index_jobs WHERE session_id = 'due-wave'")
        }
        XCTAssertTrue(try runner.shouldStopFtsDrainWave())
        XCTAssertNotNil(try runner.recommendedFtsRetryDelayNanoseconds())
    }

    func testDeferredRetrySleepsThenCompletesWithinSameDrainWave_repro() async throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, file_path, tier, summary
                ) VALUES (
                  'deferred-retry-drain', 'claude-code', '2026-08-23T00:00:00Z',
                  '/tmp/deferred-retry.jsonl', 'normal', 'retry searchable content'
                );
                INSERT INTO session_index_jobs (
                  id, session_id, job_kind, target_sync_version, status, retry_count, not_before
                ) VALUES (
                  'deferred-retry-drain:1:fts', 'deferred-retry-drain', 'fts', 1,
                  'failed_retryable', 1, datetime('now', '+2 seconds')
                );
                """)
        }
        let runner = IndexJobRunner(
            writer: writer,
            adapters: [StubFTSAdapter(
                source: .claudeCode,
                messages: [NormalizedMessage(role: .user, content: "retry searchable content")]
            )]
        )
        let startedAt = Date()

        let result = try await runner.runRecoverableJobs()

        XCTAssertEqual(result.completed, 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 1.0)
        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT content FROM sessions_fts WHERE session_id = 'deferred-retry-drain'"
                ),
                "retry searchable content"
            )
        }
    }

    func testDueBacklogHasImmediateRetryDelay_repro() throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, source, start_time, file_path, tier)
                VALUES ('due-delay', 'claude-code', '2026-08-23T00:00:00Z', '/tmp/due-delay.jsonl', 'normal');
                INSERT INTO session_index_jobs (
                  id, session_id, job_kind, target_sync_version, status, not_before
                ) VALUES ('due-delay:1:fts', 'due-delay', 'fts', 1, 'pending', NULL);
                """)
        }
        let delay = try IndexJobRunner(
            writer: writer,
            adapters: [StubFTSAdapter(source: .claudeCode, messages: [])]
        ).recommendedFtsRetryDelayNanoseconds()

        XCTAssertEqual(delay, 0)
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
                    VALUES ('s:\(i):h:legacy-vector', 's', 'legacy-vector', \(i), 'pending')
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

    func testMissingFtsSourceRemainsRetryableInsteadOfBecomingTerminal() async throws {
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
        let run = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(run.result.notApplicable, 0)
        XCTAssertFalse(run.drained)

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
        XCTAssertEqual(row?["status"] as String?, "failed_retryable")
        XCTAssertEqual(row?["retry_count"] as Int?, 1)
        XCTAssertNotNil(row?["last_error"] as String?)

        let retryable = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM session_index_jobs WHERE status IN ('pending','failed_retryable')"
            ) ?? -1
        }
        XCTAssertEqual(retryable, 1)
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

    func testCapturedIndexDoesNotRunHistoricalParentBackfills() async throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                    id, source, start_time, cwd, project, summary, file_path,
                    message_count, user_message_count, assistant_message_count,
                    tool_message_count, system_message_count
                )
                VALUES (
                    'captured-child', 'codex', '2026-05-25T10:00:00Z',
                    '/repo', 'repo', 'No tools. Review the implementation.',
                    '/tmp/captured-child.jsonl', 1, 1, 0, 0, 0
                )
                """
            )
        }

        _ = try await writer.indexCapturedSessions(adapters: [])

        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT agent_role, tier, link_checked_at
                FROM sessions
                WHERE id = 'captured-child'
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

    func testIndexAllExcludesNoopRowsFromIndexedCount() async throws {
        let adapter = StubInfoAdapter(count: 4)
        let indexer = SwiftIndexer(sink: AllNoopUpsertSink(), adapters: [adapter])

        let count = try await indexer.indexAll()

        XCTAssertEqual(count, 0, "unchanged snapshots must not keep the adaptive schedule busy")
    }

    func testSwiftIndexerAggregatesStreamedTokenUsageIntoSnapshot() async throws {
        let adapter = StubInfoAdapter(
            count: 1,
            usageMessages: [
                TokenUsage(inputTokens: 10, outputTokens: 3, cacheReadTokens: 5, cacheCreationTokens: 1),
                TokenUsage(inputTokens: 20, outputTokens: 7, cacheReadTokens: 2, cacheCreationTokens: 4),
            ]
        )
        let indexer = SwiftIndexer(sink: HalfFailUpsertSink(), adapters: [adapter])

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(
            snapshots.first?.tokenUsage,
            TokenUsage(inputTokens: 30, outputTokens: 10, cacheReadTokens: 7, cacheCreationTokens: 5)
        )
    }

    func testSwiftIndexerIsolatesFileIndexStateWriteFailures() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-index-file-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let locators = try (0..<3).map { index in
            let url = dir.appendingPathComponent("session-\(index).jsonl")
            try Data("{}".utf8).write(to: url)
            return url.path
        }
        let sink = FileStateFailingSink()
        let indexer = SwiftIndexer(sink: sink, adapters: [StubInfoAdapter(count: locators.count, locators: locators)])

        let count = try await indexer.indexAll()

        XCTAssertEqual(count, locators.count)
        XCTAssertEqual(sink.fileStateAttempts, locators.count)
    }

    /// Production crash: gemini-cli can emit the same sessionId for distinct
    /// chat files (e.g. two `a2a-server` locators). Batch file-state pairing
    /// used Dictionary(uniqueKeysWithValues:) keyed by session id and fatally
    /// trap on the duplicate. Pair by batch index instead.
    func testSwiftIndexerDuplicateSessionIdsInBatchDoNotCrash_repro() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-index-dup-sid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let locators = try (0..<2).map { index in
            let url = dir.appendingPathComponent("session-2026-07-19T01-\(index)-a2a-serv.jsonl")
            try Data("{}".utf8).write(to: url)
            return url.path
        }
        let sink = FileStateFailingSink()
        let adapter = StubInfoAdapter(
            count: locators.count,
            locators: locators,
            fixedSessionId: "a2a-server"
        )
        let indexer = SwiftIndexer(sink: sink, adapters: [adapter])

        let count = try await indexer.indexAll()

        XCTAssertEqual(count, locators.count)
        XCTAssertEqual(
            sink.fileStateAttempts,
            locators.count,
            "each distinct locator must still record file_index_state after a shared session id"
        )
        XCTAssertEqual(Set(sink.receivedSessionIds), ["a2a-server"])
        XCTAssertEqual(Set(sink.receivedFileStateLocators), Set(locators))
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

    func testIndexStatusTodayParentsIncludesOvernightSessionEndingToday_repro() throws {
        let now = Date()
        let oldStart = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7 * 86_400))
        let currentEnd = ISO8601DateFormatter().string(from: now)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, source, start_time, end_time, file_path, tier)
                    VALUES ('overnight-today-parent', 'codex', ?, ?, '/tmp/overnight-today.jsonl', 'normal')
                    """,
                arguments: [oldStart, currentEnd]
            )
        }

        XCTAssertEqual(try writer.indexStatus().todayParents, 1)
    }

    func testStartupReadyTodayParentsIncludesOvernightSessionEndingToday_repro() throws {
        let now = Date()
        let oldStart = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7 * 86_400))
        let currentEnd = ISO8601DateFormatter().string(from: now)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, source, start_time, end_time, file_path, tier)
                    VALUES ('startup-overnight-parent', 'codex', ?, ?, '/tmp/startup-overnight.jsonl', 'normal')
                    """,
                arguments: [oldStart, currentEnd]
            )
        }

        let database = WriterStartupBackfillDatabase(writer: writer)
        XCTAssertEqual(try database.countTodayParentSessions(), 1)
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

    func testReconcileInsightsUsesInsightEmbeddingsAsAuthoritativeFlagSource_repro() throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, has_embedding) VALUES
                  ('embedded', 'has authoritative embedding', 0),
                  ('legacy-only', 'has only legacy memory row', 1)
            """)
            try db.execute(sql: """
                INSERT INTO insight_embeddings (insight_id, embedding, model, dim) VALUES
                  ('embedded', X'00000000', 'test-model', 1)
            """)
            try db.execute(sql: """
                INSERT INTO memory_insights (id, content) VALUES
                  ('legacy-only', 'legacy vector row')
            """)
        }

        let result = try writer.write { db in
            try StartupBackfills.reconcileInsights(db)
        }

        XCTAssertEqual(result.resetEmbedding, 1)
        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT has_embedding FROM insights WHERE id = 'embedded'"),
                1,
                "a matching insight_embeddings row is the authoritative success record"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT has_embedding FROM insights WHERE id = 'legacy-only'"),
                0,
                "a legacy memory_insights row must not preserve the shipped embedding flag"
            )
        }
    }

    func testReconcileInsightsClearsDanglingSupersededPointers_repro() throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, superseded_by) VALUES
                  ('predecessor', 'recover me', 'missing-successor'),
                  ('active', 'keep active', NULL)
            """)
        }

        _ = try writer.write { db in
            try StartupBackfills.reconcileInsights(db)
        }

        try writer.read { db in
            XCTAssertNil(
                try String.fetchOne(
                    db,
                    sql: "SELECT superseded_by FROM insights WHERE id = 'predecessor'"
                )
            )
        }
    }

    func testReconcileInsightsSupersedesExtraActiveNormalizedDuplicates_repro() throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, wing, room, created_at, superseded_by) VALUES
                  ('duplicate-old', 'Keep one active normalized insight', 'engram', 'memory', '2026-01-01T00:00:00Z', NULL),
                  ('duplicate-new', '  KEEP   one active normalized insight  ', 'engram', 'memory', '2026-01-02T00:00:00Z', NULL)
            """)
        }

        _ = try writer.write { db in
            try StartupBackfills.reconcileInsights(db)
        }

        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'duplicate-old'"),
                "duplicate-new"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'duplicate-new'")
            )
        }
    }

    func testReconcileInsightsDeterministicallyCollapsesSameFactDanglingRows_repro() throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, wing, room, created_at, superseded_by) VALUES
                  ('dangling-old', 'Keep one repaired dangling fact', 'engram', 'memory',
                   '2026-01-01T00:00:00Z', 'missing-old'),
                  ('dangling-new', '  KEEP   one repaired dangling fact  ', 'engram', 'memory',
                   '2026-01-02T00:00:00Z', 'missing-new')
                """)
        }

        _ = try writer.write { db in
            try StartupBackfills.reconcileInsights(db)
        }

        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'dangling-old'"),
                "dangling-new"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'dangling-new'")
            )
        }
    }

    func testReconcileInsightsPromotesNewerDanglingCloneOverOlderActiveTip_repro() throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, wing, room, created_at, superseded_by) VALUES
                  ('active-old', 'Promote the newest repaired fact', 'engram', 'memory',
                   '2026-01-01T00:00:00Z', NULL),
                  ('dangling-new', '  PROMOTE  the newest repaired fact  ', 'engram', 'memory',
                   '2026-01-02T00:00:00Z', 'missing-successor')
                """)
        }

        _ = try writer.write { db in
            try StartupBackfills.reconcileInsights(db)
        }

        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'active-old'"),
                "dangling-new"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'dangling-new'")
            )
        }
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
    let usageMessages: [TokenUsage]
    let locators: [String]?
    /// When set, every locator reports this session id (gemini-cli style collision).
    let fixedSessionId: String?

    init(
        count: Int,
        usageMessages: [TokenUsage] = [],
        locators: [String]? = nil,
        fixedSessionId: String? = nil
    ) {
        self.count = count
        self.usageMessages = usageMessages
        self.locators = locators
        self.fixedSessionId = fixedSessionId
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { locators ?? (0..<count).map { "/tmp/loc-\($0).jsonl" } }
    func isAccessible(locator: String) async -> Bool { true }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .success(
            NormalizedSessionInfo(
                id: fixedSessionId ?? "info-\(locator)",
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
        let usageMessages = self.usageMessages
        return AsyncThrowingStream { continuation in
            if usageMessages.isEmpty {
                continuation.yield(NormalizedMessage(role: .user, content: "hi"))
                continuation.yield(NormalizedMessage(role: .assistant, content: "hello"))
            } else {
                for usage in usageMessages {
                    continuation.yield(NormalizedMessage(role: .assistant, content: "usage-bearing message", usage: usage))
                }
            }
            continuation.finish()
        }
    }
}
