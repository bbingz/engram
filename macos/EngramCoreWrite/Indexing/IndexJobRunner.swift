import Foundation
import GRDB
import EngramCoreRead

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
    // Capture authority is independent of legacy adapter availability and OFF by default.
    private let capturePolicy: @Sendable () -> CaptureFTSReadinessPolicy?
    var afterCaptureLoadForTesting: (() async throws -> Void)?
    private let log = CoreWriteLogger(category: "index-jobs")

    private var enabledSources: Set<SourceName> { Set(adaptersBySource.keys) }

    public init(
        writer: EngramDatabaseWriter,
        adapters: [any SessionAdapter] = SessionAdapterFactory.defaultAdapters(),
        capturePolicy: @escaping @Sendable () -> CaptureFTSReadinessPolicy? = { nil }
    ) {
        self.writer = writer
        self.capturePolicy = capturePolicy
        self.adaptersBySource = Dictionary(adapters.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private struct PendingJob: Sendable {
        let id: String
        let sessionId: String
        let jobKind: String
        let captureAuthority: FTSRebuildPolicy.CaptureJobAuthority?
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
            let stopCurrentWave = try shouldStopFtsDrainWave()
            let retryDelay = try recommendedFtsRetryDelayNanoseconds()
            if stopCurrentWave, let retryDelay {
                // docs/invariants.md #5: a deferred retry remains part of this
                // bounded recovery wave; wait, then retry without the 15m scan gap.
                try await Task.sleep(nanoseconds: retryDelay)
                continue
            }
            if stopCurrentWave { break }
            if result.completed + result.notApplicable == 0,
               let retryDelay {
                try await Task.sleep(nanoseconds: retryDelay)
            }
        }

        return StartupIndexJobRecoveryResult(completed: totalCompleted, notApplicable: totalNotApplicable)
    }

    /// Process ONE batch of recoverable jobs. Returns the batch result and whether
    /// the backlog is now drained (short batch, or a stuck full batch that made no
    /// terminal progress). The startup drain loop calls this in its own gated
    /// write command per batch so the (potentially 100k+) drain releases the
    /// single write gate between batches and user write commands can interleave.
    public func runRecoverableJobsOnce() async throws -> (result: StartupIndexJobRecoveryResult, drained: Bool) {
        try Task.checkCancellation()
        let batch = try readCheckingCancellation { db in
            try Self.takeRecoverableJobs(
                db,
                limit: Self.drainBatchSize,
                enabledSources: enabledSources,
                capturePolicy: capturePolicy()
            )
        }
        guard !batch.isEmpty else {
            try writeCheckingCancellation { db in
                try FTSRebuildPolicy.finalizeRebuildIfReady(db, enabledSources: enabledSources, capturePolicy: capturePolicy())
            }
            let drained = try readCheckingCancellation { db in
                try FTSRebuildPolicy.recoverableFtsBacklog(
                    db,
                    enabledSources: enabledSources,
                    capturePolicy: capturePolicy()
                ).count == 0
            }
            return (StartupIndexJobRecoveryResult(completed: 0, notApplicable: 0), drained)
        }

        var completed = 0
        var notApplicable = 0
        for job in batch {
            try Task.checkCancellation()
            switch try await process(job) {
            case .completed:
                completed += 1
            case .notApplicable:
                notApplicable += 1
            case .retryable:
                break
            }
        }

        try writeCheckingCancellation { db in
            try FTSRebuildPolicy.finalizeRebuildIfReady(db, enabledSources: enabledSources, capturePolicy: capturePolicy())
        }
        // docs/invariants.md #5: finalization remains due-only, but service
        // scheduling must also see future debounce rows as a live backlog.
        let drained = try readCheckingCancellation { db in
            try FTSRebuildPolicy.recoverableFtsBacklog(
                db,
                enabledSources: enabledSources,
                capturePolicy: capturePolicy()
            ).count == 0
        }
        return (StartupIndexJobRecoveryResult(completed: completed, notApplicable: notApplicable), drained)
    }

    public func recommendedFtsRetryDelayNanoseconds() throws -> UInt64? {
        try readCheckingCancellation { db in
            let backlog = try FTSRebuildPolicy.recoverableFtsBacklog(
                db,
                enabledSources: enabledSources,
                capturePolicy: capturePolicy()
            )
            guard backlog.count > 0 else { return nil }
            // docs/invariants.md #5: due work is an immediate FTS-only cycle,
            // not nil (which the service interprets as its 15m file-scan delay).
            return UInt64(max(backlog.nextDelaySeconds ?? 0, 0)) * 1_000_000_000
        }
    }

    /// A newly retryable failure must yield to a later service cycle instead of
    /// consuming every retry immediately. Future pending debounce rows remain
    /// eligible for the current drain after their bounded wait.
    public func shouldStopFtsDrainWave() throws -> Bool {
        try readCheckingCancellation { db in
            let backlog = try FTSRebuildPolicy.recoverableFtsBacklog(
                db,
                enabledSources: enabledSources,
                capturePolicy: capturePolicy()
            )
            guard backlog.hasDeferredRetryable else { return false }
            // docs/invariants.md #5: a deferred retry stops this retry wave
            // only after all other work that is due now has been drained.
            return try Self.takeRecoverableJobs(
                db,
                limit: 1,
                enabledSources: enabledSources,
                capturePolicy: capturePolicy()
            ).isEmpty
        }
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
            log.error("recoverable index job drain failed: \(String(describing: error))")
        }
    }

    // MARK: - Job processing

    private enum JobOutcome {
        case completed
        case notApplicable
        case retryable
    }

    // Borrow the calling task BEFORE GRDB dispatches the synchronous body onto
    // its queue. The handle remains within this call and is never retained.
    private func readCheckingCancellation<T>(_ body: (Database) throws -> T) throws -> T {
        try withUnsafeCurrentTask { parent in
            try writer.read { db in
                if parent?.isCancelled == true { throw CancellationError() }
                let result = try body(db)
                if parent?.isCancelled == true { throw CancellationError() }
                return result
            }
        }
    }

    private func writeCheckingCancellation<T>(_ body: (Database) throws -> T) throws -> T {
        try withUnsafeCurrentTask { parent in
            try writer.write { db in
                if parent?.isCancelled == true { throw CancellationError() }
                let result = try body(db)
                if parent?.isCancelled == true { throw CancellationError() }
                return result
            }
        }
    }

    private func processCapture(
        _ job: PendingJob, authority: FTSRebuildPolicy.CaptureJobAuthority
    ) async throws -> JobOutcome {
        guard let policy = capturePolicy() else { return .retryable }
        try CaptureIngestNormalizedStore.checkpoint(policy.deadline)
        guard try readCheckingCancellation({ db in
            try FTSRebuildPolicy.captureJobAuthority(db, jobID: job.id, policy: policy)?.matches(authority) == true
        }) else { return .retryable }

        let writer = self.writer
        // One joined read-only task per selected artifact, not a detached writer.
        // Decode is bounded but cannot be hard-interrupted halfway through JSON.
        let loading = Task.detached {
            try withUnsafeCurrentTask { child in
                try writer.read { db in
                    if child?.isCancelled == true { throw CancellationError() }
                    let snapshot = try CaptureIngestNormalizedStore.load(db, sessionID: job.sessionId,
                        generationID: authority.generationID, expectedParserRevision: policy.parserRevision,
                        enabledSources: policy.enabledSources, deadline: policy.deadline)
                    if child?.isCancelled == true { throw CancellationError() }
                    return snapshot
                }
            }
        }
        let attempt: Result<CaptureIngestNormalizedSnapshot, Error>
        do {
            attempt = .success(try await withTaskCancellationHandler {
                try await loading.value
            } onCancel: {
                loading.cancel()
            })
        } catch {
            attempt = .failure(error)
        }
        try Task.checkCancellation()
        // Also runs after a failed load, so a concurrent authority change cannot
        // be mistaken for permission to retry that earlier error.
        try await afterCaptureLoadForTesting?()
        try Task.checkCancellation()
        do {
            return try writeCheckingCancellation { db in
                guard let currentPolicy = capturePolicy() else { return .retryable }
                try CaptureIngestNormalizedStore.checkpoint(currentPolicy.deadline)
                guard try FTSRebuildPolicy.captureJobAuthority(db, jobID: job.id, policy: currentPolicy)?.matches(authority) == true else {
                    return .retryable
                }
                let result: JobOutcome
                switch attempt {
                case .success(let snapshot):
                    let hadContent = try Self.hasNonemptyFtsContent(db, sessionId: job.sessionId)
                    let receipt = try CaptureIngestReadiness.commit(db, snapshot: snapshot,
                        expectedParserRevision: currentPolicy.parserRevision, enabledSources: currentPolicy.enabledSources,
                        deadline: currentPolicy.deadline)
                    try CaptureIngestNormalizedStore.checkpoint(currentPolicy.deadline)
                    if receipt.disposition == .indexed, !hadContent {
                        try Self.reenqueueEmbeddingAfterFirstFtsFill(db, sessionId: job.sessionId)
                    }
                    result = receipt.disposition == .skipNotApplicable ? .notApplicable : .completed
                case .failure(let error):
                    let code: String
                    switch error as? CaptureIngestReadinessError {
                    case .invalidStoredRecord: code = "capture_normalized_invalid"
                    case .normalizedPayloadTooLarge: code = "capture_normalized_too_large"
                    case .tooManyMessages: code = "capture_normalized_too_many_messages"
                    default: throw error
                    }
                    try Self.markRetryable(db, id: job.id, error: code)
                    result = .retryable
                }
                try CaptureIngestNormalizedStore.checkpoint(currentPolicy.deadline)
                let finalPolicy = try freshCapturePolicy(matching: currentPolicy)
                try FTSRebuildPolicy.finalizeRebuildIfReady(db, enabledSources: enabledSources, capturePolicy: finalPolicy)
                try CaptureIngestNormalizedStore.checkpoint(currentPolicy.deadline)
                _ = try freshCapturePolicy(matching: currentPolicy)
                return result
            }
        } catch let error as CaptureIngestReadinessError {
            if error == .deadlineExceeded { throw error }
            // A readiness fence failure rolls back the outer writer transaction;
            // it cannot poison or complete the superseding generation's job.
            return .retryable
        }
    }

    // A source/parser revocation during synchronous readiness or finalization
    // invalidates the entire outer transaction, including embedding requeue.
    private func freshCapturePolicy(matching expected: CaptureFTSReadinessPolicy) throws -> CaptureFTSReadinessPolicy {
        guard let current = capturePolicy(),
              current.parserRevision.utf8.elementsEqual(expected.parserRevision.utf8),
              current.enabledSources == expected.enabledSources else {
            throw CaptureIngestReadinessError.sourceDisabled
        }
        try CaptureIngestNormalizedStore.checkpoint(current.deadline)
        return current
    }

    private func process(_ job: PendingJob) async throws -> JobOutcome {
        if let authority = job.captureAuthority { return try await processCapture(job, authority: authority) }
        guard try readCheckingCancellation({ try !FTSRebuildPolicy.isCaptureOwned($0, sessionID: job.sessionId) }) else {
            return .retryable
        }
        if job.jobKind != IndexJobKind.fts.rawValue {
            // Unknown non-FTS kinds cannot be recovered by the Swift runner.
            return try writeCheckingCancellation { db in
                guard try !FTSRebuildPolicy.isCaptureOwned(db, sessionID: job.sessionId) else { return .retryable }
                try Self.markNotApplicable(db, id: job.id, enabledSources: enabledSources, capturePolicy: capturePolicy())
                return .notApplicable
            }
        }

        // Read the session's source + locator inside a read transaction.
        let contentSource = try readCheckingCancellation { db in
            try Self.sessionContentSource(db, sessionId: job.sessionId)
        }

        guard let contentSource else {
            // No readable session row: FTS content cannot be produced. Mark
            // not_applicable to stop looping.
            return try writeCheckingCancellation { db in
                guard try !FTSRebuildPolicy.isCaptureOwned(db, sessionID: job.sessionId) else { return .retryable }
                try Self.markNotApplicable(db, id: job.id, enabledSources: enabledSources, capturePolicy: capturePolicy())
                return .notApplicable
            }
        }

        if contentSource.tier == SessionTier.skip.rawValue {
            return try writeCheckingCancellation { db in
                guard try !FTSRebuildPolicy.isCaptureOwned(db, sessionID: job.sessionId) else { return .retryable }
                try FTSRebuildPolicy.purgeFtsContent(db, sessionId: job.sessionId)
                try Self.markNotApplicable(db, id: job.id, enabledSources: enabledSources, capturePolicy: capturePolicy())
                return .notApplicable
            }
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
            return try writeCheckingCancellation { db in
                guard try !FTSRebuildPolicy.isCaptureOwned(db, sessionID: job.sessionId) else { return .retryable }
                let outcome: JobOutcome
                if try Self.sessionTier(db, sessionId: job.sessionId) == SessionTier.skip.rawValue {
                    try FTSRebuildPolicy.purgeFtsContent(db, sessionId: job.sessionId)
                    try Self.markNotApplicable(db, id: job.id, enabledSources: enabledSources, capturePolicy: capturePolicy())
                    outcome = .notApplicable
                } else {
                    let hadFtsContent = try Self.hasNonemptyFtsContent(db, sessionId: job.sessionId)
                    try FTSRebuildPolicy.replaceFtsContent(db, sessionId: job.sessionId, contents: [shadow])
                    if !hadFtsContent {
                        try Self.reenqueueEmbeddingAfterFirstFtsFill(db, sessionId: job.sessionId)
                    }
                    try Self.markCompleted(db, id: job.id)
                    outcome = .completed
                }
                try FTSRebuildPolicy.finalizeRebuildIfReady(db, enabledSources: enabledSources, capturePolicy: capturePolicy())
                return outcome
            }
        }

        guard let sourceName = SourceName(rawValue: contentSource.source),
              !contentSource.locator.isEmpty,
              !contentSource.locator.hasPrefix("sync://")
        else {
            // No readable source on disk (e.g. synced-only or unknown source):
            // FTS content cannot be produced. Mark not_applicable to stop looping.
            return try writeCheckingCancellation { db in
                guard try !FTSRebuildPolicy.isCaptureOwned(db, sessionID: job.sessionId) else { return .retryable }
                try Self.markNotApplicable(db, id: job.id, enabledSources: enabledSources, capturePolicy: capturePolicy())
                return .notApplicable
            }
        }

        // A known source with no adapter in this drain may simply be disabled.
        // Keep its FTS job recoverable so re-enabling the source can replay it;
        // not_applicable is terminal and would silently strand stale search data.
        guard let adapter = adaptersBySource[sourceName] else {
            return .retryable
        }

        do {
            guard let messages = try await buildSearchContent(adapter: adapter, source: contentSource, sessionID: job.sessionId) else {
                return .retryable
            }
            return try writeCheckingCancellation { db in
                guard try !FTSRebuildPolicy.isCaptureOwned(db, sessionID: job.sessionId) else { return .retryable }
                let outcome: JobOutcome
                if try Self.sessionTier(db, sessionId: job.sessionId) == SessionTier.skip.rawValue {
                    try FTSRebuildPolicy.purgeFtsContent(db, sessionId: job.sessionId)
                    try Self.markNotApplicable(db, id: job.id, enabledSources: enabledSources, capturePolicy: capturePolicy())
                    outcome = .notApplicable
                } else {
                    let hadFtsContent = try Self.hasNonemptyFtsContent(db, sessionId: job.sessionId)
                    try FTSRebuildPolicy.replaceFtsContent(
                        db,
                        sessionId: job.sessionId,
                        messages: messages,
                        summary: contentSource.summary
                    )
                    if !hadFtsContent {
                        try Self.reenqueueEmbeddingAfterFirstFtsFill(db, sessionId: job.sessionId)
                    }
                    try Self.markCompleted(db, id: job.id)
                    outcome = .completed
                }
                try FTSRebuildPolicy.finalizeRebuildIfReady(db, enabledSources: enabledSources, capturePolicy: capturePolicy())
                return outcome
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Parser failures remain retryable until the bounded retry policy
            // records failed_permanent; not_applicable is reserved for jobs
            // structurally outside this runner's responsibility.
            return try writeCheckingCancellation { db in
                guard try !FTSRebuildPolicy.isCaptureOwned(db, sessionID: job.sessionId) else { return .retryable }
                log.error("fts job failed: session=\(job.sessionId) error=\(String(describing: error))")
                try Self.markRetryable(db, id: job.id, error: "\(error)")
                try FTSRebuildPolicy.finalizeRebuildIfReady(db, enabledSources: enabledSources, capturePolicy: capturePolicy())
                return .retryable
            }
        }
    }

    /// Builds append-stable FTS message lines: one per non-empty user/assistant
    /// message. Mirrors fts-repo.ts `indexSessionContent`. The session summary is
    /// passed to `replaceFtsContent` separately (it is written last and can change
    /// independently), so message appends stay incremental.
    private func buildSearchContent(
        adapter: any SessionAdapter,
        source: SessionContentSource,
        sessionID: String
    ) async throws -> [String]? {
        guard try readCheckingCancellation({ try !FTSRebuildPolicy.isCaptureOwned($0, sessionID: sessionID) }) else { return nil }
        var contents: [String] = []
        // Wave 7A L05: match ParserLimits.default.maxMessages (10_000) so
        // truncate-and-succeed adapters cannot mark FTS completed with incomplete
        // keyword coverage. Keep the constant local — ParserLimits is internal to
        // EngramCore.
        let maxMessages = 10_000
        let result = try await adapter.streamMessagesWithMetadata(
            locator: source.locator,
            options: StreamMessagesOptions()
        )
        // Fail closed when the adapter already marked a whole-transcript cap so
        // FTS cannot complete on a silently truncated prefix (Wave 7A L05).
        let isIntentionalCopilotPrefix = adapter.source == .copilot
            && result.truncatedAt != nil
            && result.parseFailure == nil
        if result.truncated, !isIntentionalCopilotPrefix {
            throw ParserFailure.messageLimitExceeded
        }
        var visibleCount = 0
        for try await message in result.messages {
            guard message.role == .user || message.role == .assistant else { continue }
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            visibleCount += 1
            if visibleCount > maxMessages {
                throw ParserFailure.messageLimitExceeded
            }
            contents.append(message.content)
        }
        return contents
    }

    // MARK: - SQL helpers (static so they run inside writer.read/write blocks)

    private static func hasNonemptyFtsContent(_ db: Database, sessionId: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
              SELECT 1 FROM sessions_fts
              WHERE session_id = ? AND LENGTH(TRIM(content)) > 0
            )
            """,
            arguments: [sessionId]
        ) ?? false
    }

    private static func reenqueueEmbeddingAfterFirstFtsFill(
        _ db: Database,
        sessionId: String
    ) throws {
        let hasEmbeddingJob = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
              SELECT 1 FROM session_index_jobs
              WHERE session_id = ? AND job_kind = 'embedding'
            )
            """,
            arguments: [sessionId]
        ) ?? false
        guard hasEmbeddingJob else { return }

        // A pre-FTS backfill could only have embedded the summary fallback.
        // Remove that vector before making the authoritative FTS job selectable.
        try db.execute(
            sql: "DELETE FROM semantic_chunks WHERE session_id = ?",
            arguments: [sessionId]
        )
        try db.execute(
            sql: """
            UPDATE session_index_jobs
            SET status = 'pending',
                retry_count = 0,
                last_error = NULL,
                not_before = NULL,
                updated_at = datetime('now')
            WHERE session_id = ? AND job_kind = 'embedding'
            """,
            arguments: [sessionId]
        )
    }

    private static func takeRecoverableJobs(
        _ db: Database,
        limit: Int,
        enabledSources: Set<SourceName>,
        capturePolicy: CaptureFTSReadinessPolicy?
    ) throws -> [PendingJob] {
        let eligibility = try FTSRebuildPolicy.recoverableJobEligibility(db,
            enabledSources: enabledSources, capturePolicy: capturePolicy)
        var arguments: StatementArguments = [
            IndexJobStatus.pending.rawValue,
            IndexJobStatus.failedRetryable.rawValue,
            IndexJobKind.embedding.rawValue,
        ]
        arguments += eligibility.arguments
        arguments += [limit]
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT j.id, j.session_id, j.job_kind
            FROM session_index_jobs AS j
            LEFT JOIN sessions AS s ON s.id = j.session_id
            WHERE j.status IN (?, ?)
              AND j.job_kind != ?
              AND (j.not_before IS NULL OR j.not_before <= datetime('now'))
              AND (\(eligibility.sql))
            ORDER BY
              CASE j.status WHEN 'pending' THEN 0 ELSE 1 END,
              CASE j.job_kind WHEN 'fts' THEN 0 ELSE 1 END,
              j.retry_count,
              j.created_at,
              j.id
            LIMIT ?
            """,
            arguments: arguments
        )
        return try rows.map { row in
            PendingJob(id: row["id"], sessionId: row["session_id"], jobKind: row["job_kind"],
                captureAuthority: try FTSRebuildPolicy.captureJobAuthority(db, jobID: row["id"], policy: capturePolicy))
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
            SET status = ?, last_error = NULL, updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [IndexJobStatus.completed.rawValue, id]
        )
    }

    private static func sessionTier(_ db: Database, sessionId: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = ?", arguments: [sessionId])
    }

    static func markNotApplicable(
        _ db: Database,
        id: String,
        enabledSources: Set<SourceName>? = nil,
        capturePolicy: CaptureFTSReadinessPolicy? = nil
    ) throws {
        try db.execute(
            sql: """
            UPDATE session_index_jobs
            SET status = ?, last_error = NULL, updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [IndexJobStatus.notApplicable.rawValue, id]
        )
        // docs/invariants.md #5: every terminal FTS transition must get a
        // chance to finish the versioned shadow-table rebuild.
        try FTSRebuildPolicy.finalizeRebuildIfReady(db, enabledSources: enabledSources, capturePolicy: capturePolicy)
    }

    static func markRetryable(_ db: Database, id: String, error: String) throws {
        // docs/invariants.md #5: a transient source failure must leave the
        // versioned rebuild recoverable without exhausting all retries in one drain.
        try db.execute(
            sql: """
            UPDATE session_index_jobs
            SET status = CASE
                    WHEN retry_count + 1 >= ? THEN ?
                    ELSE ?
                END,
                retry_count = retry_count + 1,
                last_error = ?,
                not_before = CASE
                    WHEN retry_count + 1 >= ? THEN NULL
                    ELSE datetime('now', '+30 seconds')
                END,
                updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [
                Self.maxFtsRetryCount,
                IndexJobStatus.failedPermanent.rawValue,
                IndexJobStatus.failedRetryable.rawValue,
                error,
                Self.maxFtsRetryCount,
                id
            ]
        )
    }
}
