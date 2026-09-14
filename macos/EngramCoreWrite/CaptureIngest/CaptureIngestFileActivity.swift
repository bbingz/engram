import Foundation
import EngramCoreRead
import GRDB

public struct CaptureIngestFileActivityRepairBatch: Equatable, Sendable {
    public var repaired: Int
    public var attempted: Int
    public var exhausted: Bool

    /// Continue the finite startup loop only while this tick advanced the
    /// scan and has not finished one full traversal. `repaired == 0` is not a
    /// stop: a corrupt first head still counts as `attempted`.
    public var shouldContinueStartup: Bool { !exhausted && attempted > 0 }

    public init(repaired: Int, attempted: Int, exhausted: Bool) {
        self.repaired = repaired
        self.attempted = attempted
        self.exhausted = exhausted
    }
}

/// Derives `session_files` counts from already-normalized capture tool calls.
/// Recognizes the historical indexer file tools and counts by path+action.
public enum CaptureIngestFileActivity {
    public static let repairedMetadataPrefix = "capture_file_activity_repaired:"
    public static let resumeMetadataKey = "capture_file_activity_resume"

    private typealias Store = CaptureIngestNormalizedStore

    private static let tools: [String: String] = [
        "Read": "read",
        "Edit": "edit",
        "Write": "write",
        "read_file": "read",
        "edit_file": "edit",
        "write_file": "write",
    ]

    /// Delete every stored file row for `sessionID`, then insert the current
    /// generation's counts. An empty derivation still clears stale rows.
    static func replace(_ db: Database, sessionID: String, messages: [NormalizedMessage]) throws {
        try db.execute(sql: "DELETE FROM session_files WHERE session_id = ?", arguments: [sessionID])
        for row in counts(from: messages) {
            try db.execute(
                sql: """
                INSERT INTO session_files(session_id, file_path, action, count)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [sessionID, row.path, row.action, row.count]
            )
        }
    }

    /// Bounded correction for current parsed heads whose stored normalized
    /// messages were ingested before the native file-activity writer. Loads the
    /// admitted generation only; does not replay files, bump revision, or
    /// change tier/hidden. Each call attempts at most `limit` heads (clamped
    /// to 8) and honors `deadline`. Unprocessable heads stay unmarked but still
    /// advance the persistent resume cursor so later valid heads are not
    /// starved. An empty tail wraps the cursor and reports `exhausted` so the
    /// startup loop stops after one finite traversal; corrupt heads are not
    /// retried until the next process start. Disabled sources are omitted here
    /// and are considered on the next process start after they are enabled.
    ///
    /// Deadline semantics: the deadline throws only before any head of this
    /// call has been processed. Once a head has completed (repaired or skipped),
    /// a deadline hit ends the batch early and keeps that progress: the cursor
    /// stays after the last completed head so the slow head is retried first
    /// with a fresh budget. A head that alone exhausts the budget is skipped
    /// for this process start (cursor advanced, no mark) so one oversized
    /// generation cannot stall every later head; HQ stores 44 v2 generations
    /// of 5–87 MB normalized JSON. Previously the whole write rolled back and
    /// the startup task ended, so the batch containing such a head never made
    /// progress across restarts.
    public static func repairCurrentGenerations(
        _ db: Database,
        expectedParserRevision: String,
        enabledSources: Set<SourceName>,
        deadline: ContinuousClock.Instant? = nil,
        limit: Int = 4
    ) throws -> CaptureIngestFileActivityRepairBatch {
        try Store.checkpoint(deadline)
        try Store.validateParserRevision(expectedParserRevision)
        let batchLimit = min(max(limit, 0), 8)
        let sources = enabledSources.sorted { $0.rawValue < $1.rawValue }
        guard batchLimit > 0, !sources.isEmpty else {
            return CaptureIngestFileActivityRepairBatch(repaired: 0, attempted: 0, exhausted: true)
        }
        let placeholders = sources.map { _ in "?" }.joined(separator: ", ")
        var repaired = 0
        var attempted = 0
        var exhausted = false
        var afterGeneration = try loadedResume(db)
        batches: while attempted < batchLimit {
            if attempted == 0 {
                try Store.checkpoint(deadline)
            } else if Self.deadlinePassed(deadline) {
                break
            }
            var arguments: [any DatabaseValueConvertible] = [expectedParserRevision]
            arguments.append(contentsOf: sources.map(\.rawValue))
            arguments.append(afterGeneration)
            arguments.append(afterGeneration)
            arguments.append(repairedMetadataPrefix)
            arguments.append(batchLimit - attempted)
            let rows = try Row.fetchAll(db, sql: candidateSQL(sourcePlaceholders: placeholders),
                                        arguments: StatementArguments(arguments))
            if rows.isEmpty {
                if afterGeneration != nil {
                    try storeResume(db, after: nil)
                }
                exhausted = true
                break
            }
            for row in rows {
                if attempted == 0 {
                    try Store.checkpoint(deadline)
                } else if Self.deadlinePassed(deadline) {
                    // Budget spent by earlier heads: keep their commits and the
                    // cursor after them so this head starts the next batch.
                    break batches
                }
                guard let generationID = try? Store.string(row, "generation_id") else { break }
                afterGeneration = generationID
                attempted += 1
                do {
                    try db.inSavepoint {
                        try repairOne(db, row: row, expectedParserRevision: expectedParserRevision,
                                      enabledSources: enabledSources, deadline: deadline)
                        return .commit
                    }
                    repaired += 1
                } catch let error as CaptureIngestReadinessError where error == .deadlineExceeded {
                    if attempted == 1 {
                        // This head alone exhausted the budget: skip it for this
                        // process start so later heads are not starved.
                        try storeResume(db, after: generationID)
                    }
                    break batches
                } catch {
                    try storeResume(db, after: generationID)
                    continue
                }
                try storeResume(db, after: generationID)
                if attempted >= batchLimit { break }
            }
        }
        return CaptureIngestFileActivityRepairBatch(repaired: repaired, attempted: attempted, exhausted: exhausted)
    }

    /// Candidate heads in `generation_id` order after the resume cursor.
    ///
    /// `CROSS JOIN` fixes the join order so SQLite walks
    /// `capture_ingest_generations` through its `generation_id`-leading index
    /// and satisfies `ORDER BY … LIMIT` without a temp B-tree; the binding,
    /// session and ledger checks are then per-row probes. With plain `JOIN`
    /// the planner started from the ledger status index, materialized every
    /// current head (38,780 on HQ) and sorted the lot before applying
    /// `LIMIT 4`: about 15s per batch, so the 2s startup budget threw before
    /// the first head and `session_files` stayed empty. The rewritten
    /// statement returns the same rows in 5ms cold on the same database.
    static func candidateSQL(sourcePlaceholders: String) -> String {
        """
        SELECT g.generation_id, g.stored_session_id
        FROM capture_ingest_generations g
        CROSS JOIN capture_ingest_identity_bindings b
            ON b.stored_session_id = g.stored_session_id
            AND b.last_parsed_generation_id = g.generation_id
            AND b.last_sync_version = g.sync_version
        CROSS JOIN sessions s ON s.id = g.stored_session_id
        CROSS JOIN capture_ingest_ledger l
            ON l.publication_sha256 = g.publication_sha256
            AND l.parser_revision = g.parser_revision
        WHERE g.parser_revision = ?
            AND g.source IN (\(sourcePlaceholders))
            AND (? IS NULL OR g.generation_id > ?)
            AND NOT EXISTS (
                SELECT 1 FROM metadata m
                WHERE m.key = ? || g.generation_id
            )
            AND l.status IN ('parsed', 'index_ready')
            AND s.sync_version = g.sync_version
            AND s.snapshot_hash = g.snapshot_hash
            AND s.authoritative_node IS NOT NULL
        ORDER BY g.generation_id
        LIMIT ?
        """
    }

    private static func deadlinePassed(_ deadline: ContinuousClock.Instant?) -> Bool {
        guard let deadline else { return false }
        return ContinuousClock.now >= deadline
    }

    private static func repairOne(
        _ db: Database,
        row: Row,
        expectedParserRevision: String,
        enabledSources: Set<SourceName>,
        deadline: ContinuousClock.Instant?
    ) throws {
        let sessionID = try Store.string(row, "stored_session_id")
        let generationID = try Store.string(row, "generation_id")
        let snapshot = try CaptureIngestNormalizedStore.load(
            db, sessionID: sessionID, generationID: generationID,
            expectedParserRevision: expectedParserRevision, enabledSources: enabledSources,
            deadline: deadline)
        try replace(db, sessionID: snapshot.sessionID, messages: snapshot.messages)
        try markRepaired(db, generationID: generationID)
    }

    private static func loadedResume(_ db: Database) throws -> String? {
        guard let value = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = ?",
                                              arguments: [resumeMetadataKey]),
              ArchiveV2Hash.isValidSHA256(value) else { return nil }
        return value
    }

    private static func storeResume(_ db: Database, after generationID: String?) throws {
        if let generationID, ArchiveV2Hash.isValidSHA256(generationID) {
            try db.execute(sql: """
                INSERT INTO metadata(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [resumeMetadataKey, generationID])
        } else {
            try db.execute(sql: "DELETE FROM metadata WHERE key = ?", arguments: [resumeMetadataKey])
        }
    }

    private static func markRepaired(_ db: Database, generationID: String) throws {
        guard ArchiveV2Hash.isValidSHA256(generationID) else {
            throw CaptureIngestReadinessError.invalidStoredRecord
        }
        try db.execute(sql: """
            INSERT INTO metadata(key, value) VALUES (?, '1')
            ON CONFLICT(key) DO NOTHING
            """, arguments: [repairedMetadataPrefix + generationID])
    }

    private struct FileCount: Equatable {
        let path: String
        let action: String
        let count: Int
    }

    private static func counts(from messages: [NormalizedMessage]) -> [FileCount] {
        var tallies: [String: FileCount] = [:]
        for message in messages {
            for call in message.toolCalls ?? [] {
                guard let action = tools[call.name], let input = call.input,
                      let path = filePath(from: input) else { continue }
                let key = path + "\0" + action
                if let existing = tallies[key] {
                    tallies[key] = FileCount(path: path, action: action, count: existing.count + 1)
                } else {
                    tallies[key] = FileCount(path: path, action: action, count: 1)
                }
            }
        }
        return tallies.values.sorted {
            $0.path == $1.path ? $0.action < $1.action : $0.path < $1.path
        }
    }

    private static func filePath(from input: String) -> String? {
        guard !input.utf8.contains(0),
              let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["file_path"] as? String,
              path.hasPrefix("/"),
              !path.utf8.contains(0) else { return nil }
        return path
    }
}
