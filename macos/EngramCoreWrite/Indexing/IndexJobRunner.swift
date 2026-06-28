import Foundation
import GRDB
import EngramCoreRead
import os

/// Drains pending/retryable rows from `session_index_jobs`.
///
/// V1 fix: the Swift indexer never wrote FTS content, so `sessions_fts` stayed
/// empty and keyword search returned nothing. This runner re-streams each FTS
/// job's source session via its adapter, builds search content (one line per
/// user/assistant message + summary, mirroring `src/core/db/fts-repo.ts`
/// `indexSessionContent`), and rewrites `sessions_fts` (delete-then-insert).
///
/// `embedding` jobs are excluded from this drain. The service runner drains them
/// through `SessionEmbeddingBackfill`, which keeps provider network I/O outside
/// the single writer gate.
public final class IndexJobRunner: StartupIndexJobRunning {
    /// Batch size for draining the backlog (137k+ rows). Each call to
    /// `runRecoverableJobs` drains up to this many; the periodic loop re-invokes.
    public static let drainBatchSize = 200
    private static let maxFtsRetryCount = 3

    private let writer: EngramDatabaseWriter
    private let adaptersBySource: [SourceName: any SessionAdapter]
    private let log = os.Logger(subsystem: "com.engram.service", category: "index-jobs")

    public init(
        writer: EngramDatabaseWriter,
        adapters: [any SessionAdapter] = SessionAdapterFactory.defaultAdapters()
    ) {
        self.writer = writer
        self.adaptersBySource = Dictionary(adapters.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private struct PendingJob {
        let id: String
        let sessionId: String
        let jobKind: String
    }

    private struct SessionContentSource {
        let source: String
        let tier: String?
        let locator: String
        let summary: String?
        let offloadState: String?
        let generatedTitle: String?
        let project: String?
    }

    // MARK: - StartupIndexJobRunning

    public func runRecoverableJobs() async throws -> StartupIndexJobRecoveryResult {
        var totalCompleted = 0
        var totalNotApplicable = 0

        // Drain in batches so a 137k backlog doesn't load entirely into memory
        // and so each batch commits incrementally.
        while !Task.isCancelled {
            let (result, drained) = try await runRecoverableJobsOnce()
            totalCompleted += result.completed
            totalNotApplicable += result.notApplicable
            if drained { break }
        }

        return StartupIndexJobRecoveryResult(completed: totalCompleted, notApplicable: totalNotApplicable)
    }

    /// Process ONE batch of recoverable jobs. Returns the batch result and whether
    /// the backlog is now drained (short batch, or a stuck full batch that made no
    /// terminal progress). The startup drain loop calls this in its own gated
    /// write command per batch so the (potentially 100k+) drain releases the
    /// single write gate between batches and user write commands can interleave.
    public func runRecoverableJobsOnce() async throws -> (result: StartupIndexJobRecoveryResult, drained: Bool) {
        let batch = try writer.read { db in
            try Self.takeRecoverableJobs(db, limit: Self.drainBatchSize)
        }
        guard !batch.isEmpty else {
            return (StartupIndexJobRecoveryResult(completed: 0, notApplicable: 0), true)
        }

        var completed = 0
        var notApplicable = 0
        var batchProgress = 0
        for job in batch {
            try Task.checkCancellation()
            switch try await process(job) {
            case .completed:
                completed += 1
                batchProgress += 1
            case .notApplicable:
                notApplicable += 1
                batchProgress += 1
            case .retryable:
                break
            }
        }

        // A short batch means we drained everything currently pending. A full
        // batch with zero terminal progress means every job is stuck retryable
        // (e.g. transient I/O); stop to avoid spinning on the same rows.
        let drained = batch.count < Self.drainBatchSize || batchProgress == 0
        return (StartupIndexJobRecoveryResult(completed: completed, notApplicable: notApplicable), drained)
    }

    /// Insight embedding promotion is owned by the service runner so provider
    /// network I/O does not happen inside the writer-gated FTS drain.
    public func backfillInsightEmbeddings() async throws -> Int {
        0
    }

    /// Void-returning drain for callers that don't need the summary (e.g. the
    /// periodic rescan path). Logs and swallows errors so the loop continues.
    public func drainRecoverableJobs() async {
        do {
            _ = try await runRecoverableJobs()
        } catch {
            log.error("recoverable index job drain failed: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - Job processing

    private enum JobOutcome {
        case completed
        case notApplicable
        case retryable
    }

    private func process(_ job: PendingJob) async throws -> JobOutcome {
        if job.jobKind != IndexJobKind.fts.rawValue {
            // Unknown non-FTS kinds cannot be recovered by the Swift runner.
            try writer.write { db in
                try Self.markNotApplicable(db, id: job.id)
            }
            return .notApplicable
        }

        // Read the session's source + locator inside a read transaction.
        let contentSource = try writer.read { db in
            try Self.sessionContentSource(db, sessionId: job.sessionId)
        }

        guard let contentSource else {
            // No readable session row: FTS content cannot be produced. Mark
            // not_applicable to stop looping.
            try writer.write { db in
                try Self.markNotApplicable(db, id: job.id)
            }
            return .notApplicable
        }

        // BLOCKER guard: an offloaded session keeps ONLY a compact keyword shadow
        // in FTS — never re-materialize the full transcript from the still-present
        // source file. This one branch covers both the periodic re-index AND the
        // full FTS rebuild (the rebuild replays completed FTS jobs through this
        // same path); writing via replaceFtsContent updates the rebuild table too,
        // so the shadow survives a table swap. Without this, a routine rescan would
        // silently re-index the offloaded session and the disk win would evaporate.
        if contentSource.offloadState == "offloaded" {
            let shadow = OffloadShadow.line(
                title: contentSource.generatedTitle,
                project: contentSource.project,
                summary: contentSource.summary,
                sessionId: job.sessionId
            )
            try writer.write { db in
                try FTSRebuildPolicy.replaceFtsContent(db, sessionId: job.sessionId, contents: [shadow])
                try Self.markCompleted(db, id: job.id)
                try FTSRebuildPolicy.finalizeRebuildIfReady(db)
            }
            return .completed
        }

        if contentSource.tier == SessionTier.skip.rawValue {
            try writer.write { db in
                try Self.markNotApplicable(db, id: job.id)
            }
            return .notApplicable
        }

        guard let sourceName = SourceName(rawValue: contentSource.source),
              let adapter = adaptersBySource[sourceName],
              !contentSource.locator.isEmpty,
              !contentSource.locator.hasPrefix("sync://")
        else {
            // No readable source on disk (e.g. synced-only or unknown source):
            // FTS content cannot be produced. Mark not_applicable to stop looping.
            try writer.write { db in
                try Self.markNotApplicable(db, id: job.id)
            }
            return .notApplicable
        }

        do {
            let contents = try await buildSearchContent(adapter: adapter, source: contentSource)
            try writer.write { db in
                try FTSRebuildPolicy.replaceFtsContent(db, sessionId: job.sessionId, contents: contents)
                try Self.markCompleted(db, id: job.id)
                try FTSRebuildPolicy.finalizeRebuildIfReady(db)
            }
            return .completed
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ParserFailure where Self.isTerminalFtsFailure(failure) {
            try writer.write { db in
                try Self.markNotApplicable(db, id: job.id)
                try FTSRebuildPolicy.finalizeRebuildIfReady(db)
            }
            return .notApplicable
        } catch {
            // Transient failure (e.g. file changed during parse): leave the job
            // retryable so the next pass picks it up.
            log.error(
                "fts job failed: session=\(job.sessionId, privacy: .private) error=\(String(describing: error), privacy: .private)"
            )
            try writer.write { db in
                try Self.markRetryable(db, id: job.id, error: "\(error)")
                try FTSRebuildPolicy.finalizeRebuildIfReady(db)
            }
            return .retryable
        }
    }

    /// Builds FTS content lines: one per non-empty user/assistant message,
    /// plus the session summary. Mirrors fts-repo.ts `indexSessionContent`.
    private func buildSearchContent(
        adapter: any SessionAdapter,
        source: SessionContentSource
    ) async throws -> [String] {
        var contents: [String] = []
        let stream = try await adapter.streamMessages(locator: source.locator, options: StreamMessagesOptions())
        for try await message in stream {
            guard message.role == .user || message.role == .assistant else { continue }
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            contents.append(message.content)
        }
        if let summary = source.summary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contents.append(summary)
        }
        return contents
    }

    private static func isTerminalFtsFailure(_ failure: ParserFailure) -> Bool {
        switch failure {
        case .fileMissing, .fileTooLarge, .unsupportedVirtualLocator:
            return true
        case .invalidUtf8,
             .malformedJSON,
             .messageLimitExceeded,
             .lineTooLarge:
            return true
        case .truncatedJSON,
             .truncatedJSONL,
             .malformedToolCall,
             .deeplyNestedRecord,
             .fileModifiedDuringParse,
             .sqliteUnreadable,
             .grpcUnavailable:
            return false
        }
    }

    // MARK: - SQL helpers (static so they run inside writer.read/write blocks)

    private static func takeRecoverableJobs(_ db: Database, limit: Int) throws -> [PendingJob] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, session_id, job_kind
            FROM session_index_jobs
            WHERE status IN ('pending', 'failed_retryable')
              AND job_kind != ?
            ORDER BY
              CASE status WHEN 'pending' THEN 0 ELSE 1 END,
              CASE job_kind WHEN 'fts' THEN 0 ELSE 1 END,
              retry_count,
              created_at,
              id
            LIMIT ?
            """,
            arguments: [IndexJobKind.embedding.rawValue, limit]
        )
        return rows.map { row in
            PendingJob(id: row["id"], sessionId: row["session_id"], jobKind: row["job_kind"])
        }
    }

    private static func sessionContentSource(_ db: Database, sessionId: String) throws -> SessionContentSource? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
              s.source AS source,
              s.tier AS tier,
              s.summary AS summary,
              s.offload_state AS offload_state,
              s.generated_title AS generated_title,
              s.project AS project,
              COALESCE(
                NULLIF(ls.local_readable_path, ''),
                NULLIF(s.file_path, ''),
                s.source_locator
              ) AS locator
            FROM sessions s
            LEFT JOIN session_local_state ls ON ls.session_id = s.id
            WHERE s.id = ?
            """,
            arguments: [sessionId]
        ) else {
            return nil
        }
        return SessionContentSource(
            source: row["source"] ?? "",
            tier: row["tier"],
            locator: row["locator"] ?? "",
            summary: row["summary"],
            offloadState: row["offload_state"],
            generatedTitle: row["generated_title"],
            project: row["project"]
        )
    }

    static func markCompleted(_ db: Database, id: String) throws {
        try db.execute(
            sql: """
            UPDATE session_index_jobs
            SET status = 'completed', last_error = NULL, updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [id]
        )
    }

    static func markNotApplicable(_ db: Database, id: String) throws {
        try db.execute(
            sql: """
            UPDATE session_index_jobs
            SET status = 'not_applicable', last_error = NULL, updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [id]
        )
    }

    static func markRetryable(_ db: Database, id: String, error: String) throws {
        try db.execute(
            sql: """
            UPDATE session_index_jobs
            SET status = CASE
                    WHEN retry_count + 1 >= ? THEN 'failed_permanent'
                    ELSE 'failed_retryable'
                END,
                retry_count = retry_count + 1,
                last_error = ?,
                updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [Self.maxFtsRetryCount, error, id]
        )
    }
}
