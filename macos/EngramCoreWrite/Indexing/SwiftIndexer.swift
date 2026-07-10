import CryptoKit
import Foundation
import EngramCoreRead
import os

public final class SwiftIndexer {
    private static let writeBatchSize = 100
    private static let activeFileGraceInterval: TimeInterval = 120
    private static let log = os.Logger(subsystem: "com.engram.service", category: "indexer")
    // Shared formatter — allocating one per indexed session is wasteful.
    private static let iso8601 = ISO8601DateFormatter()

    private let sink: any IndexingWriteSink
    private let adapters: [any SessionAdapter]
    private let authoritativeNode: String
    private let skipUnchangedFileLocators: Bool
    private let skipKnownFileLocators: Bool

    public init(
        sink: any IndexingWriteSink,
        adapters: [any SessionAdapter] = [],
        authoritativeNode: String = "local",
        skipUnchangedFileLocators: Bool = false,
        skipKnownFileLocators: Bool = false
    ) {
        self.sink = sink
        self.adapters = adapters
        self.authoritativeNode = authoritativeNode
        self.skipUnchangedFileLocators = skipUnchangedFileLocators
        self.skipKnownFileLocators = skipKnownFileLocators
    }

    public func indexSnapshots(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason = .initialScan
    ) throws -> SessionBatchUpsertResult {
        try sink.upsertBatch(snapshots, reason: reason)
    }

    /// Returns the number of snapshots that were actually written (merge/noop),
    /// NOT the number attempted. Per-snapshot failures are subtracted so callers
    /// see a truthful "indexed" count.
    @discardableResult
    public func indexAll(sources: Set<SourceName>? = nil) async throws -> Int {
        var batch: [ScannedSnapshot] = []
        var indexed = 0

        for try await scanned in streamScannedSnapshots(sources: sources) {
            batch.append(scanned)
            if batch.count >= Self.writeBatchSize {
                indexed += try writeBatchCountingSuccesses(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            indexed += try writeBatchCountingSuccesses(batch)
        }

        // Parent-link / suggested-parent backfills run in the writer's own
        // `write { db in ... }` scope (see EngramDatabaseWriter.indexSessions),
        // never against a Database handle held across the await loop above.
        return indexed
    }

    /// Writes one batch and returns the count of rows that did NOT fail.
    /// Logs each per-snapshot failure so a silent fake-success cannot happen.
    private func writeBatchCountingSuccesses(_ batch: [ScannedSnapshot]) throws -> Int {
        let snapshots = batch.map(\.snapshot)
        let statesBySessionId = Dictionary(uniqueKeysWithValues: batch.compactMap { scanned in
            scanned.fileState.map { (scanned.snapshot.id, $0) }
        })
        let result = try sink.upsertBatch(snapshots, reason: .initialScan)
        var failures = 0
        for item in result.results {
            if item.action == .failure {
                failures += 1
                Self.log.error(
                    "session upsert failed: session=\(item.sessionId, privacy: .private) error=\(item.error ?? "unknown", privacy: .private)"
                )
                continue
            }
            if let state = statesBySessionId[item.sessionId] {
                try upsertFileIndexStateIsolated(state, source: state.source, locator: state.locator)
            }
        }
        return batch.count - failures
    }

    public func collectSnapshots(sources: Set<SourceName>? = nil) async throws -> [AuthoritativeSessionSnapshot] {
        var snapshots: [AuthoritativeSessionSnapshot] = []
        for try await snapshot in streamSnapshots(sources: sources) {
            snapshots.append(snapshot)
        }
        return snapshots
    }

    public func streamSnapshots(
        sources: Set<SourceName>? = nil
    ) -> AsyncThrowingStream<AuthoritativeSessionSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let scanTask = Task {
                do {
                    for try await scanned in streamScannedSnapshots(sources: sources) {
                        continuation.yield(scanned.snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                scanTask.cancel()
            }
        }
    }

    private struct ScannedSnapshot {
        var snapshot: AuthoritativeSessionSnapshot
        var fileState: FileIndexState?
    }

    private func streamScannedSnapshots(
        sources: Set<SourceName>? = nil
    ) -> AsyncThrowingStream<ScannedSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let scanTask = Task {
                do {
                    try await scanSnapshots(sources: sources) { snapshot, fileState in
                        continuation.yield(ScannedSnapshot(snapshot: snapshot, fileState: fileState))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                scanTask.cancel()
            }
        }
    }

    private func scanSnapshots(
        sources: Set<SourceName>? = nil,
        yield: (AuthoritativeSessionSnapshot, FileIndexState?) -> Void
    ) async throws {
        for adapter in adapters {
            try Task.checkCancellation()
            if let sources, !sources.contains(adapter.source) { continue }
            guard await adapter.detect() else { continue }

            let locators: [String]
            do {
                locators = try await adapter.listSessionLocators()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Isolate per-adapter failures: one unreadable source must not
                // abort the entire scan across all other adapters.
                Self.log.error(
                    "adapter listSessionLocators failed: source=\(adapter.source.rawValue, privacy: .private) error=\(String(describing: error), privacy: .private)"
                )
                continue
            }

            let knownFileStates = skipUnchangedFileLocators
                ? (try? sink.knownIndexedFileStates(source: adapter.source, locators: locators))
                : nil
            let fileIndexStates = try? sink.knownFileIndexStates(source: adapter.source, locators: locators)
            let tailMergeSnapshots = (adapter as? any TailIndexingSessionAdapter) == nil
                ? nil
                : (try? sink.knownTailMergeSnapshots(source: adapter.source, locators: locators))
            let activeFileCutoff = Date().addingTimeInterval(-Self.activeFileGraceInterval)

            for locator in locators {
                try Task.checkCancellation()
                let currentStat = FileIndexStat.directFileStat(locator: locator)
                let knownIndexedState = knownFileStates?[locator]
                let knownParseState = fileIndexStates?[locator]
                // Historical rows can be known/unchanged but predate instruction extraction.
                let needsInstructionBackfill =
                    knownIndexedState?.needsInstructionBackfill == true
                    && Self.reliableInstructionSources.contains(adapter.source)
                    && (knownParseState?.parseStatus ?? .ok) == .ok
                if let currentStat,
                   !needsInstructionBackfill,
                   FileIndexDecision.decide(
                    stat: currentStat,
                    state: knownParseState,
                    now: Date()
                   ) == .skip {
                    continue
                }
                if !skipKnownFileLocators {
                    switch try await attemptTailIndexing(
                        adapter: adapter,
                        locator: locator,
                        currentStat: currentStat,
                        knownParseState: knownParseState,
                        currentSnapshot: tailMergeSnapshots?[locator]
                    ) {
                    case .yield(let snapshot, let fileState):
                        yield(snapshot, fileState)
                        continue
                    case .recordOnly(let fileState):
                        try upsertFileIndexStateIsolated(fileState, source: fileState.source, locator: fileState.locator)
                        continue
                    case .failure(let failure):
                        // Terminal parser limits stay recorded and skip full reparse.
                        // Retryable tail failures fall through to a full scan in the
                        // same pass (Wave 7A / M04) instead of poisoning the identity.
                        if Self.isTerminalTailFailure(failure) {
                            try recordFileIndexFailure(
                                source: adapter.source,
                                locator: locator,
                                stat: currentStat,
                                failure: failure,
                                previous: knownParseState
                            )
                            Self.log.error(
                                "session tail parse failed: source=\(adapter.source.rawValue, privacy: .private) reason=\(failure.rawValue, privacy: .private) locator=\(locator, privacy: .private)"
                            )
                            continue
                        }
                        Self.log.error(
                            "session tail parse retryable; falling back to full scan: source=\(adapter.source.rawValue, privacy: .private) reason=\(failure.rawValue, privacy: .private) locator=\(locator, privacy: .private)"
                        )
                        break
                    case .fallback:
                        break
                    }
                }
                if (knownParseState == nil || skipKnownFileLocators),
                   let currentFile = currentStat?.legacyState,
                   let indexed = knownIndexedState {
                    if !needsInstructionBackfill {
                        // Wave 7A C01/M03: deferral must NOT stamp file_index_state
                        // success for an unparsed (or actively-writing) identity.
                        // Leaving the prior parse state dirty lets a later recent
                        // scan see the identity mismatch and reparse.
                        if skipKnownFileLocators {
                            continue
                        }
                        if currentFile.modifiedAt > activeFileCutoff {
                            continue
                        }
                        if indexed.sizeBytes == currentFile.sizeBytes,
                           let indexedAt = Self.iso8601.date(from: indexed.indexedAt ?? ""),
                           currentFile.modifiedAt <= indexedAt {
                            try recordFileIndexSuccess(source: adapter.source, locator: locator, stat: currentStat)
                            continue
                        }
                    }
                }
                do {
                    // One read+parse per changed file: `scanForIndexing` yields
                    // both the session info (pass 1) and the messages the stats
                    // pass consumes, instead of parsing the file twice.
                    switch try await adapter.scanForIndexing(locator: locator) {
                    case .failure(let reason):
                        try recordFileIndexFailure(
                            source: adapter.source,
                            locator: locator,
                            stat: currentStat,
                            failure: reason,
                            previous: fileIndexStates?[locator]
                        )
                        Self.log.error(
                            "session parse failed: source=\(adapter.source.rawValue, privacy: .private) reason=\(reason.rawValue, privacy: .private) locator=\(locator, privacy: .private)"
                        )
                        continue
                    case .success(let scan):
                        var info = scan.info
                        if info.project == nil, !info.cwd.isEmpty {
                            info.project = URL(fileURLWithPath: info.cwd).lastPathComponent
                        }

                        // When pass-1 info alone already guarantees tier `.skip`,
                        // skip the implementation-digest accumulation: skip-tier
                        // work beats are excluded from every timeline read and the
                        // beat backfill, so they are never surfaced. All other
                        // stats (usage/tools/counts/instructions) still run so
                        // costs and other read paths stay identical.
                        let provableSkip = Self.isProvableSkip(info: info, locator: locator)
                        let stats = computeStats(messages: scan.messages, provableSkip: provableSkip)
                        let fileState = currentStat.map {
                            FileIndexState.success(
                                source: adapter.source,
                                locator: locator,
                                stat: $0,
                                now: Date(),
                                parsedOffset: scan.checkpointParsedOffset,
                                boundaryHash: scan.checkpointBoundaryHash
                            )
                        }
                        yield(buildSnapshot(info: info, locator: locator, stats: stats), fileState)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if let failure = error as? ParserFailure {
                        try recordFileIndexFailure(
                            source: adapter.source,
                            locator: locator,
                            stat: currentStat,
                            failure: failure,
                            previous: fileIndexStates?[locator]
                        )
                    }
                    // Isolate per-session errors (e.g. transient stream failures)
                    // so a single bad transcript does not abort the whole scan.
                    Self.log.error(
                        "session index error: source=\(adapter.source.rawValue, privacy: .private) locator=\(locator, privacy: .private) error=\(String(describing: error), privacy: .private)"
                    )
                    continue
                }
            }
        }
    }

    private enum TailIndexAttempt {
        case yield(AuthoritativeSessionSnapshot, FileIndexState)
        case recordOnly(FileIndexState)
        case failure(ParserFailure)
        case fallback
    }

    private func attemptTailIndexing(
        adapter: any SessionAdapter,
        locator: String,
        currentStat: FileIndexStat?,
        knownParseState: FileIndexState?,
        currentSnapshot: AuthoritativeSessionSnapshot?
    ) async throws -> TailIndexAttempt {
        guard let tailAdapter = adapter as? any TailIndexingSessionAdapter,
              let currentStat,
              let state = knownParseState,
              let boundaryHash = state.boundaryHash,
              state.schemaVersion == FileIndexState.currentSchemaVersion,
              state.parseStatus == .ok,
              state.parsedOffset >= 0,
              state.parsedOffset <= state.sizeBytes,
              currentStat.sizeBytes > state.sizeBytes,
              currentStat.sizeBytes > state.parsedOffset,
              let storedInode = state.inode,
              let storedDevice = state.device,
              currentStat.inode == storedInode,
              currentStat.device == storedDevice
        else {
            return .fallback
        }

        switch try await tailAdapter.scanTailForIndexing(
            locator: locator,
            from: state.parsedOffset,
            expectedBoundaryHash: boundaryHash
        ) {
        case .fallback:
            return .fallback
        case .failure(let failure):
            return .failure(failure)
        case .success(let tail):
            let fileState = FileIndexState.success(
                source: adapter.source,
                locator: locator,
                stat: currentStat,
                now: Date(),
                parsedOffset: tail.parsedOffset,
                boundaryHash: tail.boundaryHash
            )
            if tail.infoDelta.messageCount == 0,
               tail.infoDelta.systemMessageCount == 0,
               tail.messages.isEmpty {
                guard tail.parsedOffset == state.parsedOffset else {
                    return .fallback
                }
                return .recordOnly(fileState)
            }
            guard let currentSnapshot,
                  let snapshot = mergeTailSnapshot(
                    current: currentSnapshot,
                    tail: tail,
                    locator: locator,
                    stat: currentStat
                  )
            else {
                return .fallback
            }
            return .yield(snapshot, fileState)
        }
    }

    private func mergeTailSnapshot(
        current: AuthoritativeSessionSnapshot,
        tail: IndexingTailScan,
        locator: String,
        stat: FileIndexStat
    ) -> AuthoritativeSessionSnapshot? {
        guard current.authoritativeNode == authoritativeNode else { return nil }
        guard current.tier == .normal || current.tier == .premium else { return nil }
        guard current.userMessageCount >= 3 else { return nil }
        if let id = tail.infoDelta.id, id != current.id { return nil }
        if let source = tail.infoDelta.source, source != current.source { return nil }
        if let firstRole = tail.infoDelta.firstVisibleRole, firstRole != .user { return nil }
        guard let currentSummaryCount = current.summaryMessageCount else { return nil }

        // Wave 7A H10: content fingerprint cannot be extended without re-reading
        // prior messages. Force full reparse so snapshotHash stays parity-stable
        // with a full scan. Tail-path metadata is still validated above.
        _ = currentSummaryCount
        _ = tail
        return nil
    }

    private func mergeInstructionSignals(
        current: AuthoritativeSessionSnapshot,
        tailMessages: [NormalizedMessage]
    ) -> (humanTurnCount: Int, instructions: [String])? {
        guard Self.reliableInstructionSources.contains(current.source) else {
            return (current.humanTurnCount ?? 0, [])
        }
        guard let currentInstructionCount = current.instructionCount,
              let currentHumanTurnCount = current.humanTurnCount
        else {
            return nil
        }

        var instructions = current.instructionSummary?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        if currentInstructionCount < InstructionExtractor.maxInstructions,
           instructions.contains(where: { $0.count >= 200 }) {
            return nil
        }
        if instructions.count != currentInstructionCount {
            return nil
        }

        var seen: Set<String> = []
        for instruction in instructions {
            guard InstructionExtractor.distinctInstruction(from: instruction, seen: &seen) != nil else {
                return nil
            }
        }

        var humanTurnCount = currentHumanTurnCount
        for message in tailMessages where message.role == .user {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, !Self.isSystemInjection(content) else { continue }
            humanTurnCount += 1
            guard instructions.count < InstructionExtractor.maxInstructions else { continue }
            if let instruction = InstructionExtractor.distinctInstruction(from: message.content, seen: &seen) {
                instructions.append(instruction)
            }
        }
        return (humanTurnCount, instructions)
    }

    private func mergedCounts(_ lhs: [String: Int], _ rhs: [String: Int]) -> [String: Int] {
        var output = lhs
        for (key, value) in rhs {
            output[key, default: 0] += value
        }
        return output
    }

    private func mergedUsage(_ lhs: TokenUsage?, _ rhs: TokenUsage?) -> TokenUsage? {
        guard lhs != nil || rhs != nil else { return nil }
        let left = lhs ?? TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        let right = rhs ?? TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        return TokenUsage(
            inputTokens: left.inputTokens + right.inputTokens,
            outputTokens: left.outputTokens + right.outputTokens,
            cacheReadTokens: (left.cacheReadTokens ?? 0) + (right.cacheReadTokens ?? 0),
            cacheCreationTokens: (left.cacheCreationTokens ?? 0) + (right.cacheCreationTokens ?? 0)
        )
    }

    private func recordFileIndexFailure(
        source: SourceName,
        locator: String,
        stat: FileIndexStat?,
        failure: ParserFailure,
        previous: FileIndexState?
    ) throws {
        guard let stat else { return }
        try upsertFileIndexStateIsolated(
            FileIndexState.failure(
                source: source,
                locator: locator,
                stat: stat,
                failure: failure,
                previous: previous,
                now: Date()
            ),
            source: source,
            locator: locator
        )
    }

    private func recordFileIndexSuccess(
        source: SourceName,
        locator: String,
        stat: FileIndexStat?
    ) throws {
        guard let stat else { return }
        try upsertFileIndexStateIsolated(
            FileIndexState.success(source: source, locator: locator, stat: stat, now: Date()),
            source: source,
            locator: locator
        )
    }

    private func upsertFileIndexStateIsolated(
        _ state: FileIndexState,
        source: SourceName,
        locator: String
    ) throws {
        do {
            try sink.upsertFileIndexState(state)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.error(
                "file index state write failed: source=\(source.rawValue, privacy: .private) locator=\(locator, privacy: .private) error=\(String(describing: error), privacy: .private)"
            )
        }
    }

    private struct SessionStreamStats {
        var indexedMessageCount = 0
        var assistantCount = 0
        var toolCount = 0
        var firstUserMessages: [String] = []
        var toolCallCounts: [String: Int] = [:]
        var tokenUsage: TokenUsage?
        // Human-driven signals, computed in the same pass and gated identically.
        var humanTurnCount = 0
        var instructions: [String] = []
        var seenInstructionKeys: Set<String> = []
        var implementationMessages: [NormalizedMessage] = []
        /// Running SHA-256 over role + normalized searchable content (Wave 7A H10).
        var contentDigest = SHA256()

        mutating func absorbSearchableContent(role: NormalizedMessageRole, content: String) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard role == .user || role == .assistant else { return }
            var hasher = contentDigest
            let line = "\(role.rawValue)\n\(trimmed)\n"
            hasher.update(data: Data(line.utf8))
            contentDigest = hasher
        }

        func contentFingerprintHex() -> String {
            var hasher = contentDigest
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        mutating func addUsage(_ usage: TokenUsage) {
            let current = tokenUsage ?? TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
            tokenUsage = TokenUsage(
                inputTokens: current.inputTokens + usage.inputTokens,
                outputTokens: current.outputTokens + usage.outputTokens,
                cacheReadTokens: (current.cacheReadTokens ?? 0) + (usage.cacheReadTokens ?? 0),
                cacheCreationTokens: (current.cacheCreationTokens ?? 0) + (usage.cacheCreationTokens ?? 0)
            )
        }
    }

    /// Terminal tail failures stay recorded; retryable ones fall through to full parse.
    private static func isTerminalTailFailure(_ failure: ParserFailure) -> Bool {
        switch failure {
        case .fileMissing, .fileTooLarge, .unsupportedVirtualLocator,
             .invalidUtf8, .malformedJSON, .messageLimitExceeded, .lineTooLarge, .noVisibleMessages:
            return true
        case .truncatedJSON, .truncatedJSONL, .malformedToolCall, .deeplyNestedRecord,
             .fileModifiedDuringParse, .sqliteUnreadable, .grpcUnavailable:
            return false
        }
    }

    /// Skip conditions that `SessionTier.compute` resolves to `.skip` using only
    /// pass-1 info (independent of the stats pass): each returns `.skip` before
    /// any stats-derived input is consulted, and no later branch can override a
    /// `.skip` verdict — so when this is true the final tier is guaranteed
    /// `.skip`, identical to computing it after the full pass.
    private static func isProvableSkip(info: NormalizedSessionInfo, locator: String) -> Bool {
        locator.contains("/.engram/probes/")
            || info.agentRole != nil
            || locator.contains("/subagents/")
            || info.messageCount <= 1
    }

    private func computeStats(messages: [NormalizedMessage], provableSkip: Bool) -> SessionStreamStats {
        var stats = SessionStreamStats()
        for message in messages {
            if let usage = message.usage {
                stats.addUsage(usage)
            }

            for call in message.toolCalls ?? [] {
                guard !call.name.isEmpty else { continue }
                stats.toolCallCounts[call.name, default: 0] += 1
            }

            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.role == .tool {
                guard !content.isEmpty else { continue }
                stats.toolCount += 1
                continue
            }
            guard message.role == .user || message.role == .assistant else { continue }
            if message.role == .user, Self.isSystemInjection(content) { continue }
            if !content.isEmpty, !provableSkip {
                stats.implementationMessages.append(
                    NormalizedMessage(role: message.role, content: content, timestamp: message.timestamp)
                )
            }

            let hasToolCalls = !(message.toolCalls ?? []).isEmpty
            if message.role == .assistant, !content.isEmpty || hasToolCalls {
                stats.assistantCount += 1
            }
            if hasToolCalls {
                stats.toolCount += 1
            }
            guard !content.isEmpty else { continue }
            stats.absorbSearchableContent(role: message.role, content: content)
            stats.indexedMessageCount += 1
            if message.role == .user {
                // Substantive human turn (passed role/system-injection/non-empty
                // gates above). Counts toward the "dozen-plus messages" signal and
                // feeds distinct-instruction extraction from the SAME gate.
                stats.humanTurnCount += 1
                if stats.firstUserMessages.count < 3 {
                    stats.firstUserMessages.append(message.content)
                }
                if stats.instructions.count < InstructionExtractor.maxInstructions,
                   let instruction = InstructionExtractor.distinctInstruction(
                       from: message.content,
                       seen: &stats.seenInstructionKeys
                   ) {
                    stats.instructions.append(instruction)
                }
            }
        }
        return stats
    }

    private func buildSnapshot(
        info: NormalizedSessionInfo,
        locator: String,
        stats: SessionStreamStats
    ) -> AuthoritativeSessionSnapshot {
        let tier = SessionTier.compute(
            TierInput(
                messageCount: info.messageCount,
                agentRole: info.agentRole,
                filePath: locator,
                project: info.project,
                summary: info.summary,
                startTime: info.startTime,
                endTime: info.endTime,
                source: info.source.rawValue,
                isPreamble: isSkippableFirstUserMessages(stats.firstUserMessages),
                assistantCount: stats.assistantCount,
                toolCount: stats.toolCount
            )
        )
        let summaryMessageCount = stats.indexedMessageCount
        // Instruction signals are only stored for sources whose adapter emits
        // reliable .user roles; others store nil → NULL-tolerant predicate keeps
        // them default-visible (≈ today's behavior).
        let extracted = Self.reliableInstructionSources.contains(info.source)
        let instructionCount = extracted ? stats.instructions.count : nil
        let humanTurnCount = extracted ? stats.humanTurnCount : nil
        let instructionSummary = extracted && !stats.instructions.isEmpty
            ? stats.instructions.joined(separator: "\n")
            : nil
        let implementationBeats = ImplementationDigestExtractor.extract(
            messages: stats.implementationMessages,
            sessionId: info.id,
            sessionTitle: info.summary
        )
        return AuthoritativeSessionSnapshot(
            id: info.id,
            source: info.source,
            authoritativeNode: authoritativeNode,
            syncVersion: 1,
            snapshotHash: snapshotHash(
                info: info,
                summaryMessageCount: summaryMessageCount,
                contentFingerprint: stats.contentFingerprintHex()
            ),
            indexedAt: Self.iso8601.string(from: Date()),
            sourceLocator: locator,
            sizeBytes: info.sizeBytes,
            startTime: info.startTime,
            endTime: info.endTime,
            cwd: info.cwd,
            project: info.project,
            model: info.model,
            messageCount: info.messageCount,
            userMessageCount: info.userMessageCount,
            assistantMessageCount: info.assistantMessageCount,
            toolMessageCount: info.toolMessageCount,
            systemMessageCount: info.systemMessageCount,
            summary: info.summary,
            summaryMessageCount: summaryMessageCount,
            instructionCount: instructionCount,
            humanTurnCount: humanTurnCount,
            instructionSummary: instructionSummary,
            origin: authoritativeNode,
            tier: tier,
            agentRole: info.agentRole,
            parentSessionId: info.parentSessionId,
            toolCallCounts: stats.toolCallCounts,
            tokenUsage: stats.tokenUsage,
            implementationBeats: implementationBeats
        )
    }

    private func snapshotHash(
        info: NormalizedSessionInfo,
        summaryMessageCount: Int,
        contentFingerprint: String
    ) -> String {
        var fields: [(String, String)] = [
            ("cwd", jsonString(info.cwd))
        ]
        if let project = info.project { fields.append(("project", jsonString(project))) }
        if let model = info.model { fields.append(("model", jsonString(model))) }
        fields.append(("messageCount", "\(info.messageCount)"))
        fields.append(("userMessageCount", "\(info.userMessageCount)"))
        fields.append(("assistantMessageCount", "\(info.assistantMessageCount)"))
        fields.append(("toolMessageCount", "\(info.toolMessageCount)"))
        fields.append(("systemMessageCount", "\(info.systemMessageCount)"))
        if let summary = info.summary { fields.append(("summary", jsonString(summary))) }
        fields.append(("summaryMessageCount", "\(summaryMessageCount)"))
        // Wave 7A H10: body rewrites with stable counts must change the hash.
        fields.append(("contentFingerprint", jsonString(contentFingerprint)))

        let json = "{\(fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ","))}"
        let digest = SHA256.hash(data: Data(json.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let encoded = String(data: data, encoding: .utf8)!
        return String(encoded.dropFirst().dropLast())
    }

    private func isSkippableFirstUserMessages(_ userMessages: [String]) -> Bool {
        let combined = userMessages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return false }
        if Self.healthProbePrompts.contains(combined.lowercased()) {
            return true
        }
        // Mirror the documented Polycli probe patterns recognized in
        // StartupBackfills.isPolycliProviderSummary so provider health/launch
        // pings are skipped at index time, not just during the backfill pass.
        if combined.range(of: #"^Reply with POLYCLI_HEALTH_OK only\.?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if combined.range(of: #"^You are acting as [a-z0-9_-]+ inside polycli\."#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if Self.isProviderReviewPrompt(combined) {
            return true
        }
        return combined.hasPrefix("# AGENTS.md instructions for ") ||
            combined.contains("<INSTRUCTIONS>") ||
            combined.hasPrefix("<environment_context>")
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        text.hasPrefix("# AGENTS.md instructions for ") ||
            text.contains("<INSTRUCTIONS>") ||
            text.hasPrefix("<local-command-caveat>") ||
            text.hasPrefix("<environment_context>") ||
            text.hasPrefix("<skills_instructions>") ||
            text.hasPrefix("<plugins_instructions>")
    }

    private static func isProviderReviewPrompt(_ prompt: String) -> Bool {
        let lower = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isStageFactProbe = lower.hasPrefix("no tools.") &&
            lower.contains("stage ") &&
            (lower.contains("facts") || lower.contains("verified") || lower.contains("diff:"))
        let isScopedInput = lower.contains("no tools") ||
            lower.contains("use only") ||
            lower.contains("snippets") ||
            lower.contains("diff:") ||
            lower.contains("tests passed") ||
            lower.contains("tests ") ||
            lower.range(of: #"\bp\d+(\.\d+)?\b"#, options: .regularExpression) != nil ||
            lower.contains("stage ")
        let asksForOnlyFindings = lower.contains("blocking") ||
            lower.contains("correctness") ||
            lower.contains("report only") ||
            lower.contains("any blocking issue")
        let isReviewProbe = lower.contains("review") || lower.contains("re-review")
        return isStageFactProbe || (isReviewProbe && isScopedInput && asksForOnlyFindings)
    }

    private static let healthProbePrompts: Set<String> = [
        "ping"
    ]

    // Sources whose adapter emits reliable .user roles in streamMessages, so
    // instruction extraction can be trusted. Others store NULL instruction signals
    // (default-visible). Graduate a source by adding it here + an adapter-uniformity
    // parity test proving its stream emits non-empty .user content.
    private static let reliableInstructionSources: Set<SourceName> = [.claudeCode, .codex]
}
