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
            return SessionWriteResult(action: .noop, changeSet: merge.changeSet)
        }

        try upsert(merge.snapshot)
        try upsertZeroCostRow(merge.snapshot)

        let jobs = jobKinds(for: merge.snapshot.tier ?? .normal, changeSet: merge.changeSet)
        if !jobs.isEmpty {
            try insertIndexJobs(sessionId: snapshot.id, targetSyncVersion: snapshot.syncVersion, jobKinds: jobs)
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
        if incoming.syncVersion == current.syncVersion, incoming.snapshotHash == current.snapshotHash {
            return (.noop, current, SessionChangeSet(flags: []))
        }
        if incoming.syncVersion == current.syncVersion, incoming.snapshotHash != current.snapshotHash {
            throw SessionSnapshotWriterError.conflictingSnapshotHash(incoming.id)
        }

        var merged = incoming
        merged.endTime = incoming.endTime ?? current.endTime
        merged.project = incoming.project ?? current.project
        merged.model = incoming.model ?? current.model
        merged.summary = incoming.summary ?? current.summary
        merged.summaryMessageCount = incoming.summaryMessageCount ?? current.summaryMessageCount
        merged.origin = incoming.origin ?? current.origin

        var flags: Set<ChangeFlag> = [.syncPayloadChanged]
        if searchText(current) != searchText(merged) {
            flags.insert(.searchTextChanged)
        }
        if embeddingText(current) != embeddingText(merged) {
            flags.insert(.embeddingTextChanged)
        }
        return (.merge, merged, SessionChangeSet(flags: flags))
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
              summary, summary_message_count, file_path, size_bytes, indexed_at, origin,
              authoritative_node, source_locator, sync_version, snapshot_hash,
              tier, agent_role, quality_score
            ) VALUES (
              ?, ?, ?, ?, ?, ?, ?,
              ?, ?, ?, ?, ?,
              ?, ?, ?, ?, ?, ?,
              ?, ?, ?, ?,
              ?, ?, ?
            )
            ON CONFLICT(id) DO UPDATE SET
              source = excluded.source,
              start_time = excluded.start_time,
              end_time = excluded.end_time,
              cwd = excluded.cwd,
              project = COALESCE(excluded.project, sessions.project),
              model = COALESCE(excluded.model, sessions.model),
              message_count = excluded.message_count,
              user_message_count = excluded.user_message_count,
              assistant_message_count = excluded.assistant_message_count,
              tool_message_count = excluded.tool_message_count,
              system_message_count = excluded.system_message_count,
              summary = COALESCE(excluded.summary, sessions.summary),
              summary_message_count = COALESCE(excluded.summary_message_count, sessions.summary_message_count),
              size_bytes = excluded.size_bytes,
              indexed_at = excluded.indexed_at,
              origin = excluded.origin,
              authoritative_node = excluded.authoritative_node,
              source_locator = excluded.source_locator,
              file_path = CASE
                WHEN (sessions.file_path IS NULL OR sessions.file_path = '')
                     AND excluded.source_locator NOT LIKE 'sync://%'
                  THEN excluded.source_locator
                ELSE sessions.file_path
              END,
              sync_version = excluded.sync_version,
              snapshot_hash = excluded.snapshot_hash,
              tier = excluded.tier,
              agent_role = excluded.agent_role,
              quality_score = excluded.quality_score
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
                computeQualityScore(snapshot)
            ]
        )
    }

    private func upsertZeroCostRow(_ snapshot: AuthoritativeSessionSnapshot) throws {
        try db.execute(
            sql: """
            INSERT INTO session_costs(
              session_id, model, input_tokens, output_tokens, cache_read_tokens,
              cache_creation_tokens, cost_usd, computed_at
            ) VALUES (?, ?, 0, 0, 0, 0, 0, datetime('now'))
            ON CONFLICT(session_id) DO UPDATE SET
              model = excluded.model,
              computed_at = excluded.computed_at
            """,
            arguments: [snapshot.id, snapshot.model]
        )
    }

    private func insertIndexJobs(
        sessionId: String,
        targetSyncVersion: Int,
        jobKinds: [IndexJobKind]
    ) throws {
        for jobKind in jobKinds {
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs (
                  id, session_id, job_kind, target_sync_version, status,
                  retry_count, last_error, created_at, updated_at
                ) VALUES (?, ?, ?, ?, 'pending', 0, NULL, datetime('now'), datetime('now'))
                ON CONFLICT(id) DO UPDATE SET
                  status = 'pending',
                  last_error = NULL,
                  updated_at = datetime('now')
                """,
                arguments: [
                    "\(sessionId):\(targetSyncVersion):\(jobKind.rawValue)",
                    sessionId,
                    jobKind.rawValue,
                    targetSyncVersion
                ]
            )
        }
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
        [snapshot.summary ?? "", snapshot.project ?? "", snapshot.model ?? ""].joined(separator: "\n")
    }

    private func embeddingText(_ snapshot: AuthoritativeSessionSnapshot) -> String {
        [snapshot.summary ?? "", "\(snapshot.messageCount)"].joined(separator: "\n")
    }
}
