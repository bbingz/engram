import Foundation
import GRDB
import EngramCoreRead

public struct EngramDatabaseIndexStatus: Sendable, Equatable {
    public let total: Int
    public let todayParents: Int
    /// Distinguishes a healthy empty database (`schemaPresent == true, total == 0`)
    /// from a degraded one where the `sessions` table is absent
    /// (`schemaPresent == false`). The read-only status command tolerates the
    /// degraded case (reports total:0); the composition root fails fast via
    /// `verifySchemaPresent()`.
    public let schemaPresent: Bool

    public init(total: Int, todayParents: Int, schemaPresent: Bool = true) {
        self.total = total
        self.todayParents = todayParents
        self.schemaPresent = schemaPresent
    }
}

/// Thrown by `verifySchemaPresent()` when the `sessions` table does not exist.
/// The composition root treats this as fatal — migrations should have created
/// the schema before the service starts serving.
public enum EngramDatabaseIndexStatusError: Error, CustomStringConvertible {
    case missingSchema

    public var description: String {
        switch self {
        case .missingSchema:
            return "sessions table is absent; schema migration has not run"
        }
    }
}

public struct EngramDatabaseIndexResult: Sendable, Equatable {
    public let indexed: Int
    public let total: Int
    public let todayParents: Int
}

private final class EngramDatabaseIndexingSink: IndexingWriteSink {
    private let writer: EngramDatabaseWriter

    init(writer: EngramDatabaseWriter) {
        self.writer = writer
    }

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        try writer.write { db in
            try SessionBatchUpsert(db: db).upsertBatch(snapshots, reason: reason)
        }
    }

    func knownIndexedFileStates(source: SourceName, locators: [String]) throws -> [String: KnownIndexedFileState] {
        guard !locators.isEmpty else { return [:] }
        return try writer.read { db in
            try Self.knownIndexedFileStates(db, source: source, locators: locators)
        }
    }

    func knownFileIndexStates(source: SourceName, locators: [String]) throws -> [String: FileIndexState] {
        try writer.knownFileIndexStates(source: source, locators: locators)
    }

    func upsertFileIndexState(_ state: FileIndexState) throws {
        try writer.upsertFileIndexState(state)
    }

    private static func knownIndexedFileStates(
        _ db: Database,
        source: SourceName,
        locators: [String]
    ) throws -> [String: KnownIndexedFileState] {
        var states: [String: KnownIndexedFileState] = [:]
        for batch in stride(from: 0, to: locators.count, by: 500) {
            let slice = Array(locators[batch..<Swift.min(batch + 500, locators.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            var arguments: StatementArguments = [source.rawValue]
            for locator in slice {
                arguments += [locator]
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT COALESCE(NULLIF(source_locator, ''), NULLIF(file_path, '')) AS locator,
                       size_bytes,
                       indexed_at,
                       instruction_count IS NULL AS needs_instruction_backfill
                FROM sessions
                WHERE source = ?
                  AND COALESCE(NULLIF(source_locator, ''), NULLIF(file_path, '')) IN (\(placeholders))
                """,
                arguments: arguments
            )
            for row in rows {
                let locator = row["locator"] as String? ?? ""
                guard !locator.isEmpty else { continue }
                let needsInstructionBackfill = (row["needs_instruction_backfill"] as Int64? ?? 0) != 0
                if let state = KnownIndexedFileState.fromIndexedSessionRow(
                    sizeBytes: row["size_bytes"] as Int64?,
                    indexedAt: row["indexed_at"],
                    needsInstructionBackfill: needsInstructionBackfill
                ) {
                    states[locator] = state
                }
            }
        }
        return states
    }
}

private struct InstructionBackfillSignal: Sendable {
    let source: SourceName
    let locator: String
    let instructionCount: Int
    let humanTurnCount: Int?
    let instructionSummary: String?
}

private struct ImplementationBeatBackfillCandidate: Sendable {
    let sessionId: String
    let source: SourceName
    let locator: String
    let startTime: String
    let sessionTitle: String?
}

private struct ImplementationBeatBackfillSignal: Sendable {
    let sessionId: String
    let beats: [SessionImplementationBeat]
}

public extension EngramDatabaseWriter {
    func knownFileIndexStates(source: SourceName, locators: [String]) throws -> [String: FileIndexState] {
        guard !locators.isEmpty else { return [:] }
        return try read { db in
            var states: [String: FileIndexState] = [:]
            for batch in stride(from: 0, to: locators.count, by: 500) {
                let slice = Array(locators[batch..<Swift.min(batch + 500, locators.count)])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                var arguments: StatementArguments = [source.rawValue]
                for locator in slice {
                    arguments += [locator]
                }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT source, locator, size_bytes, mtime_ns, inode, device,
                           parsed_offset, boundary_hash, parse_status, failure_kind,
                           retry_after, retry_count, last_error, schema_version, updated_at
                    FROM file_index_state
                    WHERE source = ?
                      AND locator IN (\(placeholders))
                    """,
                    arguments: arguments
                )
                for row in rows {
                    guard let state = Self.fileIndexState(from: row) else { continue }
                    states[state.locator] = state
                }
            }
            return states
        }
    }

    func upsertFileIndexState(_ state: FileIndexState) throws {
        try write { db in
            try db.execute(
                sql: """
                INSERT INTO file_index_state (
                  source, locator, size_bytes, mtime_ns, inode, device,
                  parsed_offset, boundary_hash, parse_status, failure_kind,
                  retry_after, retry_count, last_error, schema_version, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, locator) DO UPDATE SET
                  size_bytes = excluded.size_bytes,
                  mtime_ns = excluded.mtime_ns,
                  inode = excluded.inode,
                  device = excluded.device,
                  parsed_offset = excluded.parsed_offset,
                  boundary_hash = excluded.boundary_hash,
                  parse_status = excluded.parse_status,
                  failure_kind = excluded.failure_kind,
                  retry_after = excluded.retry_after,
                  retry_count = excluded.retry_count,
                  last_error = excluded.last_error,
                  schema_version = excluded.schema_version,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    state.source.rawValue,
                    state.locator,
                    state.sizeBytes,
                    state.modifiedAtNanos,
                    state.inode,
                    state.device,
                    state.parsedOffset,
                    state.boundaryHash,
                    state.parseStatus.rawValue,
                    state.failureKind?.rawValue,
                    state.retryAfterEpochSeconds,
                    state.retryCount,
                    state.lastError,
                    state.schemaVersion,
                    state.updatedAtEpochSeconds
                ]
            )
        }
    }

    private static func fileIndexState(from row: Row) -> FileIndexState? {
        guard let sourceRaw = row["source"] as String?,
              let source = SourceName(rawValue: sourceRaw),
              let locator = row["locator"] as String?,
              let sizeBytes = row["size_bytes"] as Int64?,
              let modifiedAtNanos = row["mtime_ns"] as Int64?,
              let statusRaw = row["parse_status"] as String?,
              let parseStatus = FileIndexParseStatus(rawValue: statusRaw),
              let retryCount = row["retry_count"] as Int?,
              let schemaVersion = row["schema_version"] as Int?,
              let updatedAt = row["updated_at"] as Int64?
        else {
            return nil
        }
        let failureKind = (row["failure_kind"] as String?).flatMap(ParserFailure.init(rawValue:))
        return FileIndexState(
            source: source,
            locator: locator,
            sizeBytes: sizeBytes,
            modifiedAtNanos: modifiedAtNanos,
            inode: row["inode"] as Int64?,
            device: row["device"] as Int64?,
            parsedOffset: row["parsed_offset"] as Int64? ?? 0,
            boundaryHash: row["boundary_hash"],
            parseStatus: parseStatus,
            failureKind: failureKind,
            retryAfterEpochSeconds: row["retry_after"] as Int64?,
            retryCount: retryCount,
            lastError: row["last_error"],
            schemaVersion: schemaVersion,
            updatedAtEpochSeconds: updatedAt
        )
    }

    func indexRecentSessions(
        adapters: [any SessionAdapter] = SessionAdapterFactory.recentActiveAdapters()
    ) async throws -> EngramDatabaseIndexResult {
        try await indexSessions(
            adapters: adapters,
            runParentBackfills: false,
            skipUnchangedFileLocators: true,
            skipKnownFileLocators: false
        )
    }

    func indexAllSessions(
        adapters: [any SessionAdapter] = SessionAdapterFactory.defaultAdapters()
    ) async throws -> EngramDatabaseIndexResult {
        try await indexSessions(
            adapters: adapters,
            runParentBackfills: true,
            skipUnchangedFileLocators: true,
            skipKnownFileLocators: true
        )
    }

    func indexInstructionBackfillSessions(
        adapters: [any SessionAdapter] = SessionAdapterFactory.defaultAdapters()
    ) async throws -> EngramDatabaseIndexResult {
        let candidates = try instructionBackfillCandidateLocators()
        guard !candidates.isEmpty else {
            let status = try indexStatus()
            return EngramDatabaseIndexResult(indexed: 0, total: status.total, todayParents: status.todayParents)
        }

        let adaptersBySource = Dictionary(adapters.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        var batch: [InstructionBackfillSignal] = []
        var updated = 0

        for source in candidates.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let adapter = adaptersBySource[source] else { continue }
            for locator in candidates[source] ?? [] {
                guard FileIndexStat.directFileStat(locator: locator) != nil else { continue }
                do {
                    if let signal = try await instructionBackfillSignal(adapter: adapter, locator: locator) {
                        batch.append(signal)
                    }
                } catch {
                    continue
                }
                if batch.count >= 100 {
                    updated += try writeInstructionBackfillSignals(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        if !batch.isEmpty {
            updated += try writeInstructionBackfillSignals(batch)
        }

        let status = try indexStatus()
        return EngramDatabaseIndexResult(indexed: updated, total: status.total, todayParents: status.todayParents)
    }

    func indexImplementationBeatBackfillSessions(
        adapters: [any SessionAdapter] = SessionAdapterFactory.defaultAdapters()
    ) async throws -> EngramDatabaseIndexResult {
        let candidates = try implementationBeatBackfillCandidates()
        guard !candidates.isEmpty else {
            let status = try indexStatus()
            return EngramDatabaseIndexResult(indexed: 0, total: status.total, todayParents: status.todayParents)
        }

        let adaptersBySource = Dictionary(adapters.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        var batch: [ImplementationBeatBackfillSignal] = []
        var updated = 0

        for source in candidates.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let adapter = adaptersBySource[source] else { continue }
            for candidate in candidates[source] ?? [] {
                guard FileIndexStat.directFileStat(locator: candidate.locator) != nil else { continue }
                do {
                    if let signal = try await implementationBeatBackfillSignal(adapter: adapter, candidate: candidate) {
                        batch.append(signal)
                    }
                } catch {
                    continue
                }
                if batch.count >= 100 {
                    updated += try writeImplementationBeatBackfillSignals(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        if !batch.isEmpty {
            updated += try writeImplementationBeatBackfillSignals(batch)
        }

        let status = try indexStatus()
        return EngramDatabaseIndexResult(indexed: updated, total: status.total, todayParents: status.todayParents)
    }

    /// Run the deterministic parent-link backfills after a periodic scan so
    /// agent/dispatched child sessions created mid-run are grouped under their
    /// parent (and skip-tiered) without waiting for a service restart. The
    /// periodic `indexRecentSessions` path indexes with `runParentBackfills:
    /// false`, so without this the periodic scan leaves new children top-level
    /// until the next restart.
    func runPeriodicParentBackfills() throws {
        try write { db in
            _ = try StartupBackfills.backfillParentLinks(db)
            _ = try StartupBackfills.backfillCodexOriginator(db)
            _ = try StartupBackfills.backfillPolycliProviderParents(db)
            _ = try StartupBackfills.backfillSuggestedParents(db)
        }
    }

    private func indexSessions(
        adapters: [any SessionAdapter],
        runParentBackfills: Bool,
        skipUnchangedFileLocators: Bool,
        skipKnownFileLocators: Bool
    ) async throws -> EngramDatabaseIndexResult {
        let indexer = SwiftIndexer(
            sink: EngramDatabaseIndexingSink(writer: self),
            adapters: adapters,
            skipUnchangedFileLocators: skipUnchangedFileLocators,
            skipKnownFileLocators: skipKnownFileLocators
        )
        let indexed = try await indexer.indexAll()

        if runParentBackfills {
            try write { db in
                _ = try StartupBackfills.backfillPolycliProviderParents(db)
                _ = try StartupBackfills.backfillSuggestedParents(db)
            }
        }

        let status = try indexStatus()
        return EngramDatabaseIndexResult(
            indexed: indexed,
            total: status.total,
            todayParents: status.todayParents
        )
    }

    private func instructionBackfillCandidateLocators() throws -> [SourceName: [String]] {
        let rawSources = HumanDrivenFilter.instructionSignalSources
        guard !rawSources.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: rawSources.count).joined(separator: ",")
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT source,
                       COALESCE(NULLIF(source_locator, ''), NULLIF(file_path, '')) AS locator
                FROM sessions
                WHERE source IN (\(placeholders))
                  AND instruction_count IS NULL
                  AND COALESCE(NULLIF(source_locator, ''), NULLIF(file_path, '')) IS NOT NULL
                  AND (orphan_status IS NULL OR orphan_status != 'confirmed')
                ORDER BY source, start_time DESC
                """,
                arguments: StatementArguments(rawSources)
            )

            var locatorsBySource: [SourceName: [String]] = [:]
            var seen: [SourceName: Set<String>] = [:]
            for row in rows {
                guard let rawSource = row["source"] as String?,
                      let source = SourceName(rawValue: rawSource),
                      let locator = row["locator"] as String?,
                      !locator.isEmpty
                else {
                    continue
                }
                var sourceSeen = seen[source, default: []]
                guard sourceSeen.insert(locator).inserted else {
                    seen[source] = sourceSeen
                    continue
                }
                seen[source] = sourceSeen
                locatorsBySource[source, default: []].append(locator)
            }
            return locatorsBySource
        }
    }

    private func implementationBeatBackfillCandidates() throws -> [SourceName: [ImplementationBeatBackfillCandidate]] {
        let rawSources = HumanDrivenFilter.instructionSignalSources
        guard !rawSources.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: rawSources.count).joined(separator: ",")
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT s.id,
                       s.source,
                       COALESCE(NULLIF(s.source_locator, ''), NULLIF(s.file_path, '')) AS locator,
                       s.start_time,
                       COALESCE(NULLIF(TRIM(s.generated_title), ''), NULLIF(TRIM(s.summary), '')) AS session_title
                FROM sessions s
                WHERE s.source IN (\(placeholders))
                  AND NOT EXISTS (
                    SELECT 1
                    FROM session_work_beats b
                    WHERE b.session_id = s.id
                  )
                  AND COALESCE(NULLIF(s.source_locator, ''), NULLIF(s.file_path, '')) IS NOT NULL
                  AND COALESCE(NULLIF(s.source_locator, ''), NULLIF(s.file_path, '')) NOT LIKE 'sync://%'
                  AND (s.orphan_status IS NULL OR s.orphan_status != 'confirmed')
                  -- Skip-tier work beats are filtered out of every timeline read,
                  -- so never (re)generate them; matches SwiftIndexer's digest skip.
                  AND (s.tier IS NULL OR s.tier != 'skip')
                  AND (
                    COALESCE(s.instruction_count, 0) > 0
                    OR COALESCE(s.human_turn_count, s.user_message_count, 0) > 0
                  )
                ORDER BY s.source, s.start_time DESC
                """,
                arguments: StatementArguments(rawSources)
            )

            var candidatesBySource: [SourceName: [ImplementationBeatBackfillCandidate]] = [:]
            var seen: [SourceName: Set<String>] = [:]
            for row in rows {
                guard let sessionId = row["id"] as String?,
                      let rawSource = row["source"] as String?,
                      let source = SourceName(rawValue: rawSource),
                      let locator = row["locator"] as String?,
                      let startTime = row["start_time"] as String?,
                      !locator.isEmpty
                else {
                    continue
                }
                var sourceSeen = seen[source, default: []]
                guard sourceSeen.insert(sessionId).inserted else {
                    seen[source] = sourceSeen
                    continue
                }
                seen[source] = sourceSeen
                candidatesBySource[source, default: []].append(
                    ImplementationBeatBackfillCandidate(
                        sessionId: sessionId,
                        source: source,
                        locator: locator,
                        startTime: startTime,
                        sessionTitle: row["session_title"]
                    )
                )
            }
            return candidatesBySource
        }
    }

    private func instructionBackfillSignal(
        adapter: any SessionAdapter,
        locator: String
    ) async throws -> InstructionBackfillSignal? {
        var humanTurnCount = 0
        var instructions: [String] = []
        var seenInstructionKeys: Set<String> = []

        do {
            let stream = try await adapter.streamMessages(locator: locator, options: StreamMessagesOptions())
            for try await message in stream {
                guard message.role == .user else { continue }
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty, !Self.isSystemInjection(content) else { continue }
                humanTurnCount += 1
                if instructions.count < InstructionExtractor.maxInstructions,
                   let instruction = InstructionExtractor.distinctInstruction(
                       from: message.content,
                       seen: &seenInstructionKeys
                   ) {
                    instructions.append(instruction)
                }
            }
        } catch let failure as ParserFailure where Self.isTerminalInstructionBackfillFailure(failure) {
            return InstructionBackfillSignal(
                source: adapter.source,
                locator: locator,
                instructionCount: 0,
                humanTurnCount: nil,
                instructionSummary: nil
            )
        }

        return InstructionBackfillSignal(
            source: adapter.source,
            locator: locator,
            instructionCount: instructions.count,
            humanTurnCount: humanTurnCount,
            instructionSummary: instructions.isEmpty ? nil : instructions.joined(separator: "\n")
        )
    }

    private func implementationBeatBackfillSignal(
        adapter: any SessionAdapter,
        candidate: ImplementationBeatBackfillCandidate
    ) async throws -> ImplementationBeatBackfillSignal? {
        var messages: [NormalizedMessage] = []

        do {
            let stream = try await adapter.streamMessages(locator: candidate.locator, options: StreamMessagesOptions())
            for try await message in stream {
                guard message.role == .user || message.role == .assistant else { continue }
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                if message.role == .user, Self.isSystemInjection(content) { continue }
                messages.append(
                    NormalizedMessage(
                        role: message.role,
                        content: content,
                        timestamp: message.timestamp ?? candidate.startTime
                    )
                )
            }
        } catch let failure as ParserFailure where Self.isTerminalInstructionBackfillFailure(failure) {
            return nil
        }

        let beats = ImplementationDigestExtractor.extract(
            messages: messages,
            sessionId: candidate.sessionId,
            sessionTitle: candidate.sessionTitle
        )
        guard !beats.isEmpty else { return nil }
        return ImplementationBeatBackfillSignal(sessionId: candidate.sessionId, beats: beats)
    }

    private func writeInstructionBackfillSignals(_ signals: [InstructionBackfillSignal]) throws -> Int {
        guard !signals.isEmpty else { return 0 }
        return try write { db in
            var updated = 0
            for signal in signals {
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET instruction_count = ?,
                        human_turn_count = ?,
                        instruction_summary = ?
                    WHERE source = ?
                      AND COALESCE(NULLIF(source_locator, ''), NULLIF(file_path, '')) = ?
                      AND instruction_count IS NULL
                    """,
                    arguments: [
                        signal.instructionCount,
                        signal.humanTurnCount,
                        signal.instructionSummary,
                        signal.source.rawValue,
                        signal.locator
                    ]
                )
                updated += db.changesCount
            }
            return updated
        }
    }

    private func writeImplementationBeatBackfillSignals(_ signals: [ImplementationBeatBackfillSignal]) throws -> Int {
        guard !signals.isEmpty else { return 0 }
        return try write { db in
            var updated = 0
            for signal in signals where !signal.beats.isEmpty {
                let existing = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM session_work_beats WHERE session_id = ?",
                    arguments: [signal.sessionId]
                ) ?? 0
                guard existing == 0 else { continue }
                for beat in signal.beats {
                    try db.execute(
                        sql: """
                        INSERT INTO session_work_beats(
                          session_id, beat_index, action_date, action_timestamp, work_key, work_title,
                          human_intent, assistant_outcome, kind, status, operation_events, confidence
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            signal.sessionId,
                            beat.beatIndex,
                            beat.actionDate,
                            beat.actionTimestamp,
                            beat.workKey,
                            beat.workTitle,
                            beat.humanIntent,
                            beat.assistantOutcome,
                            beat.kind.rawValue,
                            beat.status.rawValue,
                            Self.operationEventsJSON(beat.operationEvents),
                            beat.confidence,
                        ]
                    )
                }
                updated += 1
            }
            return updated
        }
    }

    private static func operationEventsJSON(_ events: [SessionOperationEvent]) -> String {
        guard let data = try? JSONEncoder().encode(events),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        text.hasPrefix("# AGENTS.md instructions for ") ||
            text.contains("<INSTRUCTIONS>") ||
            text.hasPrefix("<local-command-caveat>") ||
            text.hasPrefix("<environment_context>") ||
            text.hasPrefix("<skills_instructions>") ||
            text.hasPrefix("<plugins_instructions>")
    }

    private static func isTerminalInstructionBackfillFailure(_ failure: ParserFailure) -> Bool {
        switch failure {
        case .fileMissing, .fileTooLarge, .invalidUtf8, .truncatedJSON, .truncatedJSONL,
             .malformedToolCall, .deeplyNestedRecord, .messageLimitExceeded, .lineTooLarge,
             .unsupportedVirtualLocator:
            return true
        case .malformedJSON, .fileModifiedDuringParse, .sqliteUnreadable, .grpcUnavailable:
            return false
        }
    }

    func indexStatus(now: Date = Date()) throws -> EngramDatabaseIndexStatus {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let since = ISO8601DateFormatter().string(from: startOfToday)
        return try read { db in
            let hasSessions = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sessions')"
            ) ?? false
            guard hasSessions else {
                // Degraded: schema absent. The read-only status path tolerates
                // this (total:0); the composition root rejects it via
                // verifySchemaPresent(). This is NOT a silent empty-DB result —
                // schemaPresent is false so callers can distinguish.
                return EngramDatabaseIndexStatus(total: 0, todayParents: 0, schemaPresent: false)
            }
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions WHERE hidden_at IS NULL"
            ) ?? 0
            let todayParents = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM sessions
                WHERE hidden_at IS NULL
                  AND parent_session_id IS NULL
                  AND suggested_parent_id IS NULL
                  AND (tier IS NULL OR tier != 'skip')
                  AND start_time >= ?
                """,
                arguments: [since]
            ) ?? 0
            return EngramDatabaseIndexStatus(total: total, todayParents: todayParents)
        }
    }

    /// Composition-root fail-fast check: throws `.missingSchema` when the
    /// `sessions` table is absent after migration was supposed to run.
    func verifySchemaPresent() throws {
        let status = try indexStatus()
        guard status.schemaPresent else {
            throw EngramDatabaseIndexStatusError.missingSchema
        }
    }
}
