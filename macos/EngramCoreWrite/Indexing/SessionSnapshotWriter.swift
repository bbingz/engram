import Foundation
import GRDB
import EngramCoreRead

public enum SessionSnapshotWriterError: Error, Equatable {
    case conflictingAuthoritativeNode(String)
    case conflictingSnapshotHash(String)
}

public final class SessionSnapshotWriter {
    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func writeAuthoritativeSnapshot(_ snapshot: AuthoritativeSessionSnapshot) throws -> SessionWriteResult {
        let current = try currentSnapshot(id: snapshot.id)
        let merge = try mergeSessionSnapshot(current: current, incoming: snapshot)
        guard merge.action == .merge else {
            try upsertCostRowIfNeededForNoop(snapshot)
            if !snapshot.toolCallCounts.isEmpty {
                try replaceSessionToolsIfDifferent(snapshot)
            }
            if shouldReplaceSessionWorkBeats(snapshot) {
                try replaceSessionWorkBeatsIfDifferent(snapshot)
            }
            try clearRecoveredOrphanStatus(sessionId: snapshot.id)
            return SessionWriteResult(action: .noop, changeSet: merge.changeSet)
        }

        // Apply the snapshot's writes atomically. upsertBatch runs every
        // snapshot inside one outer transaction and, on a per-snapshot failure,
        // records a .failure result and CONTINUES — committing the batch. Without
        // this savepoint, a mid-sequence failure (e.g. the index-job insert)
        // would leave the sessions row already advanced to the new
        // sync_version/snapshot_hash with NO matching pending FTS job, so search
        // content silently stays stale. The savepoint rolls back the partial
        // snapshot while the rest of the batch still commits.
        try db.inSavepoint {
            try upsert(merge.snapshot)
            try clearRecoveredOrphanStatus(sessionId: snapshot.id)
            try upsertCostRow(merge.snapshot)
            try replaceSessionTools(merge.snapshot)
            if shouldReplaceSessionWorkBeats(snapshot) {
                try replaceSessionWorkBeats(snapshot)
            }

            if shouldDeleteIndexArtifacts(current: current, merged: merge.snapshot) {
                try deleteIndexArtifacts(sessionId: snapshot.id)
            }

            let jobs = jobKinds(for: merge.snapshot.tier ?? .normal, changeSet: merge.changeSet)
            if !jobs.isEmpty {
                try insertIndexJobs(
                    sessionId: snapshot.id,
                    targetSyncVersion: snapshot.syncVersion,
                    targetSnapshotHash: merge.snapshot.snapshotHash,
                    jobKinds: jobs
                )
            }
            return .commit
        }

        return SessionWriteResult(action: .merge, changeSet: merge.changeSet)
    }

    public func jobKinds(for result: SessionWriteResult, snapshot: AuthoritativeSessionSnapshot) -> [IndexJobKind] {
        guard result.action == .merge else { return [] }
        return jobKinds(for: snapshot.tier ?? .normal, changeSet: result.changeSet)
    }

    private func mergeSessionSnapshot(
        current: AuthoritativeSessionSnapshot?,
        incoming: AuthoritativeSessionSnapshot
    ) throws -> (action: SessionWriteAction, snapshot: AuthoritativeSessionSnapshot, changeSet: SessionChangeSet) {
        guard let current else {
            return (
                .merge,
                incoming,
                SessionChangeSet(flags: [.syncPayloadChanged, .searchTextChanged, .embeddingTextChanged])
            )
        }

        guard current.authoritativeNode == incoming.authoritativeNode else {
            throw SessionSnapshotWriterError.conflictingAuthoritativeNode(incoming.id)
        }
        if incoming.syncVersion < current.syncVersion {
            return (.noop, current, SessionChangeSet(flags: []))
        }
        if incoming.syncVersion == current.syncVersion,
           incoming.snapshotHash == current.snapshotHash,
           incoming.sizeBytes == current.sizeBytes,
           incoming.sourceLocator == current.sourceLocator {
            let (preservedRole, preservedTier) = preservedClassification(current: current, incoming: incoming)
            let currentTier = current.tier ?? .normal
            let incomingTier = preservedTier ?? .normal
            let instructionSignalsChanged = shouldApplyInstructionSignals(current: current, incoming: incoming)
            guard currentTier != incomingTier || current.agentRole != preservedRole || instructionSignalsChanged else {
                return (.noop, current, SessionChangeSet(flags: []))
            }

            var merged = current
            merged.tier = preservedTier
            merged.agentRole = preservedRole
            merged.indexedAt = incoming.indexedAt
            merged.tokenUsage = incoming.tokenUsage
            if instructionSignalsChanged {
                merged.instructionCount = incoming.instructionCount
                merged.humanTurnCount = incoming.humanTurnCount
                merged.instructionSummary = incoming.instructionSummary
            }

            var flags: Set<ChangeFlag> = [.localStateChanged]
            if currentTier == .skip, incomingTier != .skip {
                flags.insert(.searchTextChanged)
                if incomingTier == .normal || incomingTier == .premium {
                    flags.insert(.embeddingTextChanged)
                }
            }
            return (.merge, merged, SessionChangeSet(flags: flags))
        }
        if incoming.syncVersion == current.syncVersion, incoming.snapshotHash == current.snapshotHash {
            var merged = current
            merged.sizeBytes = incoming.sizeBytes
            merged.indexedAt = incoming.indexedAt
            merged.tokenUsage = incoming.tokenUsage
            return (.merge, merged, SessionChangeSet(flags: [.syncPayloadChanged]))
        }
        var merged = incoming
        merged.endTime = incoming.endTime ?? current.endTime
        merged.cwd = incoming.cwd.isEmpty ? current.cwd : incoming.cwd
        merged.project = incoming.project ?? current.project
        merged.model = incoming.model ?? current.model
        preserveCountsIfIncomingEmpty(current: current, merged: &merged)
        merged.summary = incoming.summary ?? current.summary
        merged.summaryMessageCount = incoming.summaryMessageCount ?? current.summaryMessageCount
        merged.origin = incoming.origin ?? current.origin
        // Re-index must not revert a Layer-2 dispatched/skip classification (see
        // upsert's ON CONFLICT CASE). Keep merge.snapshot consistent with the
        // row the DB will persist so change flags / index jobs agree with it.
        let (preservedRole, preservedTier) = preservedClassification(current: current, incoming: incoming)
        merged.agentRole = preservedRole
        merged.tier = preservedTier

        var flags: Set<ChangeFlag> = [.syncPayloadChanged]
        let currentTier = current.tier ?? .normal
        let incomingTier = preservedTier ?? .normal
        if currentTier != incomingTier || current.agentRole != preservedRole {
            flags.insert(.localStateChanged)
        }
        if currentTier == .skip, incomingTier != .skip {
            flags.insert(.searchTextChanged)
            if incomingTier == .normal || incomingTier == .premium {
                flags.insert(.embeddingTextChanged)
            }
        }
        if searchText(current) != searchText(merged) {
            flags.insert(.searchTextChanged)
        }
        if embeddingText(current) != embeddingText(merged) {
            flags.insert(.embeddingTextChanged)
        }
        return (.merge, merged, SessionChangeSet(flags: flags))
    }

    private func clearRecoveredOrphanStatus(sessionId: String) throws {
        try db.execute(
            sql: """
            UPDATE sessions
            SET orphan_status = NULL,
                orphan_since = NULL,
                orphan_reason = NULL
            WHERE id = ?
              AND orphan_status IS NOT NULL
            """,
            arguments: [sessionId]
        )
    }

    /// Mirrors the ON CONFLICT CASE in `upsert`: preserve a stored agent_role
    /// when the incoming snapshot has none, and keep a 'skip' tier that a
    /// non-null agent_role pins so a content re-index cannot revert a Layer-2
    /// dispatched/skip classification.
    private func preservedClassification(
        current: AuthoritativeSessionSnapshot,
        incoming: AuthoritativeSessionSnapshot
    ) -> (role: String?, tier: SessionTier?) {
        let role = incoming.agentRole ?? current.agentRole
        let tier = (current.tier == .skip && current.agentRole != nil) ? current.tier : incoming.tier
        return (role, tier)
    }

    private func shouldApplyInstructionSignals(
        current: AuthoritativeSessionSnapshot,
        incoming: AuthoritativeSessionSnapshot
    ) -> Bool {
        if incoming.summaryMessageCount == 0, (current.summaryMessageCount ?? 0) > 0 {
            return false
        }
        return current.instructionCount != incoming.instructionCount
            || current.humanTurnCount != incoming.humanTurnCount
            || current.instructionSummary != incoming.instructionSummary
    }

    private func preserveCountsIfIncomingEmpty(
        current: AuthoritativeSessionSnapshot,
        merged: inout AuthoritativeSessionSnapshot
    ) {
        guard merged.messageCount == 0, current.messageCount > 0 else { return }
        merged.messageCount = current.messageCount
        merged.userMessageCount = current.userMessageCount
        merged.assistantMessageCount = current.assistantMessageCount
        merged.toolMessageCount = current.toolMessageCount
        merged.systemMessageCount = current.systemMessageCount
    }

    private func currentSnapshot(id: String) throws -> AuthoritativeSessionSnapshot? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return AuthoritativeSessionSnapshot(
            id: row["id"],
            source: SourceName(rawValue: row["source"]) ?? .codex,
            authoritativeNode: row["authoritative_node"] ?? "",
            syncVersion: row["sync_version"] ?? 0,
            snapshotHash: row["snapshot_hash"] ?? "",
            indexedAt: row["indexed_at"] ?? "",
            sourceLocator: row["source_locator"] ?? row["file_path"] ?? "",
            sizeBytes: row["size_bytes"],
            startTime: row["start_time"],
            endTime: row["end_time"],
            cwd: row["cwd"],
            project: row["project"],
            model: row["model"],
            messageCount: row["message_count"],
            userMessageCount: row["user_message_count"],
            assistantMessageCount: row["assistant_message_count"],
            toolMessageCount: row["tool_message_count"],
            systemMessageCount: row["system_message_count"],
            summary: row["summary"],
            summaryMessageCount: row["summary_message_count"],
            instructionCount: row["instruction_count"],
            humanTurnCount: row["human_turn_count"],
            instructionSummary: row["instruction_summary"],
            origin: row["origin"],
            tier: (row["tier"] as String?).flatMap(SessionTier.init(rawValue:)),
            agentRole: row["agent_role"]
        )
    }

    private func upsert(_ snapshot: AuthoritativeSessionSnapshot) throws {
        let filePath = snapshot.sourceLocator.hasPrefix("sync://") ? "" : snapshot.sourceLocator
        try db.execute(
            sql: """
            INSERT INTO sessions (
              id, source, start_time, end_time, cwd, project, model,
              message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count,
              summary, summary_message_count, instruction_count, human_turn_count, instruction_summary,
              file_path, size_bytes, indexed_at, origin,
              authoritative_node, source_locator, sync_version, snapshot_hash,
              tier, agent_role, quality_score, generated_title,
              parent_session_id, link_source
            ) VALUES (
              ?, ?, ?, ?, ?, ?, ?,
              ?, ?, ?, ?, ?,
              ?, ?, ?, ?, ?,
              ?, ?, ?, ?,
              ?, ?, ?, ?,
              ?, ?, ?, ?,
              ?, CASE WHEN ? IS NOT NULL THEN 'path' ELSE NULL END
            )
            ON CONFLICT(id) DO UPDATE SET
              source = excluded.source,
              start_time = excluded.start_time,
              end_time = excluded.end_time,
              cwd = CASE
                WHEN excluded.cwd IS NULL OR excluded.cwd = '' THEN sessions.cwd
                ELSE excluded.cwd
              END,
              project = COALESCE(excluded.project, sessions.project),
              model = COALESCE(excluded.model, sessions.model),
              message_count = CASE
                WHEN excluded.message_count = 0 AND sessions.message_count > 0 THEN sessions.message_count
                ELSE excluded.message_count
              END,
              user_message_count = CASE
                WHEN excluded.message_count = 0 AND sessions.message_count > 0 THEN sessions.user_message_count
                ELSE excluded.user_message_count
              END,
              assistant_message_count = CASE
                WHEN excluded.message_count = 0 AND sessions.message_count > 0 THEN sessions.assistant_message_count
                ELSE excluded.assistant_message_count
              END,
              tool_message_count = CASE
                WHEN excluded.message_count = 0 AND sessions.message_count > 0 THEN sessions.tool_message_count
                ELSE excluded.tool_message_count
              END,
              system_message_count = CASE
                WHEN excluded.message_count = 0 AND sessions.message_count > 0 THEN sessions.system_message_count
                ELSE excluded.system_message_count
              END,
              summary = CASE
                WHEN sessions.summary_message_count IS NOT NULL
                     AND excluded.summary_message_count IS NOT NULL
                     AND sessions.summary_message_count >= excluded.summary_message_count
                     AND sessions.summary IS NOT NULL
                     AND TRIM(sessions.summary) != ''
                  THEN sessions.summary
                ELSE COALESCE(excluded.summary, sessions.summary)
              END,
              summary_message_count = CASE
                WHEN sessions.summary_message_count IS NOT NULL
                     AND excluded.summary_message_count IS NOT NULL
                     AND sessions.summary_message_count >= excluded.summary_message_count
                     AND sessions.summary IS NOT NULL
                     AND TRIM(sessions.summary) != ''
                  THEN sessions.summary_message_count
                ELSE COALESCE(excluded.summary_message_count, sessions.summary_message_count)
              END,
              -- Instruction signals derive from the streamStats pass, whose
              -- co-varying sentinel is summary_message_count (= indexedMessageCount).
              -- An empty/failed re-stream (summary_message_count = 0 while the prior
              -- row was healthy) preserves all three together; a healthy re-stream
              -- overwrites them fresh.
              instruction_count = CASE
                WHEN excluded.summary_message_count = 0 AND sessions.summary_message_count > 0
                  THEN sessions.instruction_count
                ELSE excluded.instruction_count
              END,
              human_turn_count = CASE
                WHEN excluded.summary_message_count = 0 AND sessions.summary_message_count > 0
                  THEN sessions.human_turn_count
                ELSE excluded.human_turn_count
              END,
              instruction_summary = CASE
                WHEN excluded.summary_message_count = 0 AND sessions.summary_message_count > 0
                  THEN sessions.instruction_summary
                ELSE excluded.instruction_summary
              END,
              size_bytes = excluded.size_bytes,
              indexed_at = excluded.indexed_at,
              origin = excluded.origin,
              authoritative_node = excluded.authoritative_node,
              source_locator = excluded.source_locator,
              file_path = CASE
                WHEN excluded.source_locator NOT LIKE 'sync://%'
                     AND (sessions.source_locator IS NULL OR sessions.source_locator != excluded.source_locator)
                  THEN excluded.source_locator
                WHEN (sessions.file_path IS NULL OR sessions.file_path = '')
                     AND excluded.source_locator NOT LIKE 'sync://%'
                  THEN excluded.source_locator
                ELSE sessions.file_path
              END,
              sync_version = excluded.sync_version,
              snapshot_hash = excluded.snapshot_hash,
              -- Re-index must not revert a Layer-2 dispatched/skip classification:
              -- preserve a stored agent_role when the incoming snapshot has none,
              -- and never downgrade a 'skip' tier that a non-null agent_role pins.
              tier = CASE
                WHEN sessions.tier = 'skip' AND sessions.agent_role IS NOT NULL THEN sessions.tier
                ELSE excluded.tier
              END,
              agent_role = COALESCE(excluded.agent_role, sessions.agent_role),
              quality_score = excluded.quality_score,
              generated_title = COALESCE(NULLIF(TRIM(sessions.generated_title), ''), excluded.generated_title),
              -- Persist a sidecar-derived parent (Layer 1c) but never clobber a
              -- user-confirmed ('manual') link.
              parent_session_id = CASE
                WHEN sessions.link_source = 'manual' THEN sessions.parent_session_id
                WHEN excluded.parent_session_id IS NOT NULL THEN excluded.parent_session_id
                ELSE sessions.parent_session_id
              END,
              link_source = CASE
                WHEN sessions.link_source = 'manual' THEN sessions.link_source
                WHEN excluded.parent_session_id IS NOT NULL THEN 'path'
                ELSE sessions.link_source
              END
            """,
            arguments: [
                snapshot.id,
                snapshot.source.rawValue,
                snapshot.startTime,
                snapshot.endTime,
                snapshot.cwd,
                snapshot.project,
                snapshot.model,
                snapshot.messageCount,
                snapshot.userMessageCount,
                snapshot.assistantMessageCount,
                snapshot.toolMessageCount,
                snapshot.systemMessageCount,
                snapshot.summary,
                snapshot.summaryMessageCount,
                snapshot.instructionCount,
                snapshot.humanTurnCount,
                snapshot.instructionSummary,
                filePath,
                snapshot.sizeBytes ?? 0,
                snapshot.indexedAt,
                snapshot.origin ?? snapshot.authoritativeNode,
                snapshot.authoritativeNode,
                snapshot.sourceLocator,
                snapshot.syncVersion,
                snapshot.snapshotHash,
                (snapshot.tier ?? .normal).rawValue,
                snapshot.agentRole,
                computeQualityScore(snapshot),
                generatedTitle(for: snapshot),
                snapshot.parentSessionId,
                snapshot.parentSessionId
            ]
        )
    }

    /// Derive a display title at index time so freshly indexed sessions are not
    /// left with a NULL `generated_title` (only filled later by the on-demand
    /// regenerate command). Prefers the summary's first line, then
    /// project/cwd + start date, then the id. Never includes a user custom
    /// name (that lives in `custom_name`); the ON CONFLICT COALESCE preserves
    /// any existing generated/custom title.
    private func generatedTitle(for snapshot: AuthoritativeSessionSnapshot) -> String {
        if let summary = snapshot.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            let firstLine = summary.components(separatedBy: .newlines).first ?? summary
            return String(firstLine.prefix(120))
        }
        let project = snapshot.project?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (project?.isEmpty == false)
            ? project!
            : (snapshot.cwd as NSString).lastPathComponent
        if snapshot.startTime.count >= 10 {
            let day = String(snapshot.startTime.prefix(10))
            return base.isEmpty ? day : "\(base) \(day)"
        }
        return base.isEmpty ? snapshot.id : base
    }

    private func upsertCostRow(_ snapshot: AuthoritativeSessionSnapshot) throws {
        if let usage = snapshot.tokenUsage {
            try upsertTokenCostRow(snapshot, usage: usage)
            return
        }

        try db.execute(
            sql: """
            INSERT INTO session_costs(
              session_id, model, input_tokens, output_tokens, cache_read_tokens,
              cache_creation_tokens, cost_usd, computed_at
            ) VALUES (?, NULLIF(?, ''), 0, 0, 0, 0, 0, datetime('now'))
            ON CONFLICT(session_id) DO UPDATE SET
              model = COALESCE(excluded.model, session_costs.model),
              computed_at = CASE
                WHEN excluded.model IS NOT NULL AND session_costs.model IS NOT excluded.model
                THEN excluded.computed_at
                ELSE session_costs.computed_at
              END
            """,
            arguments: [snapshot.id, snapshot.model ?? ""]
        )
    }

    private func upsertTokenCostRow(_ snapshot: AuthoritativeSessionSnapshot, usage: TokenUsage) throws {
        let costUSD = SessionCostPricing.computeCost(model: snapshot.model, usage: usage)
        try db.execute(
            sql: """
            INSERT INTO session_costs(
              session_id, model, input_tokens, output_tokens, cache_read_tokens,
              cache_creation_tokens, cost_usd, computed_at
            ) VALUES (?, NULLIF(?, ''), ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(session_id) DO UPDATE SET
              model = COALESCE(excluded.model, session_costs.model),
              input_tokens = excluded.input_tokens,
              output_tokens = excluded.output_tokens,
              cache_read_tokens = excluded.cache_read_tokens,
              cache_creation_tokens = excluded.cache_creation_tokens,
              cost_usd = excluded.cost_usd,
              computed_at = CASE
                WHEN (excluded.model IS NOT NULL AND session_costs.model IS NOT excluded.model)
                  OR session_costs.input_tokens IS NOT excluded.input_tokens
                  OR session_costs.output_tokens IS NOT excluded.output_tokens
                  OR session_costs.cache_read_tokens IS NOT excluded.cache_read_tokens
                  OR session_costs.cache_creation_tokens IS NOT excluded.cache_creation_tokens
                  OR session_costs.cost_usd IS NOT excluded.cost_usd
                THEN excluded.computed_at
                ELSE session_costs.computed_at
              END
            """,
            arguments: [
                snapshot.id,
                snapshot.model ?? "",
                usage.inputTokens,
                usage.outputTokens,
                usage.cacheReadTokens ?? 0,
                usage.cacheCreationTokens ?? 0,
                costUSD
            ]
        )
    }

    private func upsertCostRowIfNeededForNoop(_ snapshot: AuthoritativeSessionSnapshot) throws {
        if snapshot.tokenUsage != nil {
            try upsertCostRow(snapshot)
            return
        }

        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT model FROM session_costs WHERE session_id = ?",
            arguments: [snapshot.id]
        ) else {
            try upsertCostRow(snapshot)
            return
        }
        let existingModel: String? = row["model"]
        guard let incomingModel = snapshot.model, !incomingModel.isEmpty, existingModel != incomingModel else {
            return
        }
        try upsertCostRow(snapshot)
    }

    private func replaceSessionToolsIfDifferent(_ snapshot: AuthoritativeSessionSnapshot) throws {
        let current = try currentToolCallCounts(sessionId: snapshot.id)
        guard current != snapshot.toolCallCounts else { return }
        try replaceSessionTools(snapshot)
    }

    private func currentToolCallCounts(sessionId: String) throws -> [String: Int] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT tool_name, call_count FROM session_tools WHERE session_id = ?",
            arguments: [sessionId]
        )
        var counts: [String: Int] = [:]
        for row in rows {
            let name: String = row["tool_name"]
            let count: Int = row["call_count"]
            counts[name] = count
        }
        return counts
    }

    private func replaceSessionTools(_ snapshot: AuthoritativeSessionSnapshot) throws {
        try db.execute(sql: "DELETE FROM session_tools WHERE session_id = ?", arguments: [snapshot.id])
        guard !snapshot.toolCallCounts.isEmpty else { return }
        for (name, count) in snapshot.toolCallCounts where count > 0 {
            try db.execute(
                sql: """
                INSERT INTO session_tools(session_id, tool_name, call_count)
                VALUES (?, ?, ?)
                ON CONFLICT(session_id, tool_name) DO UPDATE SET
                  call_count = excluded.call_count
                """,
                arguments: [snapshot.id, name, count]
            )
        }
    }

    private func shouldReplaceSessionWorkBeats(_ snapshot: AuthoritativeSessionSnapshot) -> Bool {
        if !snapshot.implementationBeats.isEmpty { return true }
        return (snapshot.summaryMessageCount ?? 0) > 0
    }

    private func replaceSessionWorkBeatsIfDifferent(_ snapshot: AuthoritativeSessionSnapshot) throws {
        let current = try currentSessionWorkBeats(sessionId: snapshot.id)
        guard current != snapshot.implementationBeats else { return }
        try replaceSessionWorkBeats(snapshot)
    }

    private func currentSessionWorkBeats(sessionId: String) throws -> [SessionImplementationBeat] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT session_id, beat_index, action_date, action_timestamp, work_key, work_title,
                   human_intent, assistant_outcome, kind, status, operation_events, confidence
              FROM session_work_beats
             WHERE session_id = ?
             ORDER BY beat_index ASC
            """,
            arguments: [sessionId]
        )
        return rows.map { row in
            let eventsJSON: String = row["operation_events"] ?? "[]"
            let events = decodeOperationEvents(eventsJSON)
            return SessionImplementationBeat(
                sessionId: row["session_id"],
                beatIndex: row["beat_index"],
                actionDate: row["action_date"],
                actionTimestamp: row["action_timestamp"],
                workKey: row["work_key"],
                workTitle: row["work_title"],
                humanIntent: row["human_intent"],
                assistantOutcome: row["assistant_outcome"],
                kind: SessionImplementationKind(rawValue: row["kind"]) ?? .implementation,
                status: SessionImplementationStatus(rawValue: row["status"]) ?? .partial,
                operationEvents: events,
                confidence: row["confidence"]
            )
        }
    }

    private func replaceSessionWorkBeats(_ snapshot: AuthoritativeSessionSnapshot) throws {
        try db.execute(sql: "DELETE FROM session_work_beats WHERE session_id = ?", arguments: [snapshot.id])
        guard !snapshot.implementationBeats.isEmpty else { return }
        for beat in snapshot.implementationBeats {
            try db.execute(
                sql: """
                INSERT INTO session_work_beats(
                  session_id, beat_index, action_date, action_timestamp, work_key, work_title,
                  human_intent, assistant_outcome, kind, status, operation_events, confidence
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, beat_index) DO UPDATE SET
                  action_date = excluded.action_date,
                  action_timestamp = excluded.action_timestamp,
                  work_key = excluded.work_key,
                  work_title = excluded.work_title,
                  human_intent = excluded.human_intent,
                  assistant_outcome = excluded.assistant_outcome,
                  kind = excluded.kind,
                  status = excluded.status,
                  operation_events = excluded.operation_events,
                  confidence = excluded.confidence
                """,
                arguments: [
                    snapshot.id,
                    beat.beatIndex,
                    beat.actionDate,
                    beat.actionTimestamp,
                    beat.workKey,
                    beat.workTitle,
                    beat.humanIntent,
                    beat.assistantOutcome,
                    beat.kind.rawValue,
                    beat.status.rawValue,
                    operationEventsJSON(beat.operationEvents),
                    beat.confidence,
                ]
            )
        }
    }

    private func operationEventsJSON(_ events: [SessionOperationEvent]) -> String {
        guard let data = try? JSONEncoder().encode(events),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    private func decodeOperationEvents(_ json: String) -> [SessionOperationEvent] {
        guard let data = json.data(using: .utf8),
              let events = try? JSONDecoder().decode([SessionOperationEvent].self, from: data)
        else { return [] }
        return events
    }

    // FTS debounce: while a session keeps appending, coalesce its re-index jobs so
    // the writer does not re-run per append. Defer the pending job by an idle window,
    // clamped so content is searchable within a bounded max delay of the first still-
    // pending enqueue.
    private static let ftsDebounceWindowSeconds = 15
    private static let ftsMaxDeferSeconds = 90

    private func insertIndexJobs(
        sessionId: String,
        targetSyncVersion: Int,
        targetSnapshotHash: String,
        jobKinds: [IndexJobKind]
    ) throws {
        for jobKind in jobKinds {
            let jobId = "\(sessionId):\(targetSyncVersion):\(targetSnapshotHash):\(jobKind.rawValue)"

            // For FTS, capture the earliest still-pending enqueue BEFORE replacing the
            // row so a burst of appends coalesces into one deferred job while honoring
            // a bounded max delay. nil (first enqueue / no backlog) keeps not_before
            // NULL, so a single change is indexed immediately.
            let priorPendingFtsCreatedAt: String? = jobKind == .fts
                ? try String.fetchOne(
                    db,
                    sql: """
                    SELECT MIN(created_at) FROM session_index_jobs
                    WHERE session_id = ? AND job_kind = 'fts'
                      AND status IN ('pending', 'failed_retryable')
                    """,
                    arguments: [sessionId]
                )
                : nil

            try db.execute(
                sql: """
                DELETE FROM session_index_jobs
                WHERE session_id = ?
                  AND job_kind = ?
                  AND id != ?
                  AND status IN ('pending', 'failed_retryable', 'completed', 'not_applicable')
                """,
                arguments: [sessionId, jobKind.rawValue, jobId]
            )
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs (
                  id, session_id, job_kind, target_sync_version, status,
                  retry_count, last_error, created_at, updated_at, not_before
                ) VALUES (
                  ?, ?, ?, ?, 'pending', 0, NULL,
                  COALESCE(?, datetime('now')), datetime('now'),
                  CASE WHEN ? IS NULL THEN NULL
                       ELSE MIN(datetime('now', ?), datetime(?, ?)) END
                )
                ON CONFLICT(id) DO UPDATE SET
                  status = 'pending',
                  last_error = NULL,
                  updated_at = datetime('now'),
                  created_at = COALESCE(?, session_index_jobs.created_at),
                  not_before = CASE WHEN ? IS NULL THEN session_index_jobs.not_before
                                    ELSE MIN(datetime('now', ?), datetime(?, ?)) END
                """,
                arguments: [
                    jobId,
                    sessionId,
                    jobKind.rawValue,
                    targetSyncVersion,
                    priorPendingFtsCreatedAt,
                    priorPendingFtsCreatedAt,
                    "+\(Self.ftsDebounceWindowSeconds) seconds",
                    priorPendingFtsCreatedAt,
                    "+\(Self.ftsMaxDeferSeconds) seconds",
                    priorPendingFtsCreatedAt,
                    priorPendingFtsCreatedAt,
                    "+\(Self.ftsDebounceWindowSeconds) seconds",
                    priorPendingFtsCreatedAt,
                    "+\(Self.ftsMaxDeferSeconds) seconds"
                ]
            )
        }
    }

    private func shouldDeleteIndexArtifacts(
        current: AuthoritativeSessionSnapshot?,
        merged: AuthoritativeSessionSnapshot
    ) -> Bool {
        guard let current else { return false }
        return (current.tier ?? .normal) != .skip && (merged.tier ?? .normal) == .skip
    }

    private func deleteIndexArtifacts(sessionId: String) throws {
        try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = ?", arguments: [sessionId])
        if try tableExists("fts_map") {
            try db.execute(sql: "DELETE FROM fts_map WHERE session_id = ?", arguments: [sessionId])
        }
        if try tableExists("session_embeddings") {
            try db.execute(sql: "DELETE FROM session_embeddings WHERE session_id = ?", arguments: [sessionId])
        }
        try db.execute(
            sql: "DELETE FROM session_index_jobs WHERE session_id = ? AND status IN ('pending', 'failed_retryable')",
            arguments: [sessionId]
        )
    }

    private func tableExists(_ name: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?)",
            arguments: [name]
        ) ?? false
    }

    private func jobKinds(for tier: SessionTier, changeSet: SessionChangeSet) -> [IndexJobKind] {
        var kinds: [IndexJobKind] = []
        if tier != .skip, changeSet.flags.contains(.searchTextChanged) {
            kinds.append(.fts)
        }
        if (tier == .normal || tier == .premium), changeSet.flags.contains(.embeddingTextChanged) {
            kinds.append(.embedding)
        }
        return kinds
    }

    private func computeQualityScore(_ snapshot: AuthoritativeSessionSnapshot) -> Int {
        let total = snapshot.userMessageCount + snapshot.assistantMessageCount + snapshot.toolMessageCount + snapshot.systemMessageCount
        var turnScore = 0.0
        if snapshot.userMessageCount > 0, snapshot.assistantMessageCount > 0, total > 0 {
            let pairs = min(snapshot.userMessageCount, snapshot.assistantMessageCount)
            turnScore = min(30, (Double(pairs) / Double(total)) * 30)
        }

        var toolScore = 0.0
        if snapshot.assistantMessageCount > 0 {
            toolScore = min(25, (Double(snapshot.toolMessageCount) / Double(snapshot.assistantMessageCount)) * 50)
        }

        let duration = durationMinutes(startTime: snapshot.startTime, endTime: snapshot.endTime)
        let densityScore: Double
        if duration < 1 {
            densityScore = 0
        } else if duration <= 5 {
            densityScore = (duration / 5) * 20
        } else if duration <= 60 {
            densityScore = 20
        } else if duration <= 180 {
            densityScore = 20 - ((duration - 60) / 120) * 10
        } else {
            densityScore = 10
        }

        let projectScore = snapshot.project == nil ? 0.0 : 15.0
        let volumeScore = min(10, Double(snapshot.userMessageCount + snapshot.assistantMessageCount + snapshot.toolMessageCount) / 5)
        return max(0, min(100, Int((turnScore + toolScore + densityScore + projectScore + volumeScore).rounded())))
    }

    private func durationMinutes(startTime: String?, endTime: String?) -> Double {
        guard let startTime,
              let endTime,
              let start = parseDate(startTime),
              let end = parseDate(endTime)
        else {
            return 0
        }
        return end.timeIntervalSince(start) / 60
    }

    private func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func searchText(_ snapshot: AuthoritativeSessionSnapshot) -> String {
        [snapshot.snapshotHash, snapshot.summary ?? "", snapshot.project ?? "", snapshot.model ?? ""].joined(separator: "\n")
    }

    private func embeddingText(_ snapshot: AuthoritativeSessionSnapshot) -> String {
        [snapshot.snapshotHash, snapshot.summary ?? "", "\(snapshot.messageCount)"].joined(separator: "\n")
    }
}
