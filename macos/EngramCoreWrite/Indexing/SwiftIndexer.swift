import Foundation
import EngramCoreRead

public final class SwiftIndexer {
    private static let writeBatchSize = 100
    private static let activeFileGraceInterval: TimeInterval = 120
    private static let log = CoreWriteLogger(category: "indexer")
    // Shared formatter — allocating one per indexed session is wasteful.
    private static let iso8601 = ISO8601DateFormatter()

    private let sink: any IndexingWriteSink
    private let adapters: [any SessionAdapter]
    private let authoritativeNode: String
    private let skipUnchangedFileLocators: Bool
    private let skipKnownFileLocators: Bool
    private let excludedSnapshotSources: Set<SourceName>
    private let didFinishAdapter: @Sendable (SourceName) -> Void
    private let didExcludeSnapshot: @Sendable (ExcludedSnapshotIndexEvent) -> Void

    public init(
        sink: any IndexingWriteSink,
        adapters: [any SessionAdapter] = [],
        authoritativeNode: String = "local",
        skipUnchangedFileLocators: Bool = false,
        skipKnownFileLocators: Bool = false,
        excludedSnapshotSources: Set<SourceName> = [],
        didFinishAdapter: @escaping @Sendable (SourceName) -> Void = { _ in },
        didExcludeSnapshot: @escaping @Sendable (ExcludedSnapshotIndexEvent) -> Void = { _ in }
    ) {
        self.sink = sink
        self.adapters = adapters
        self.authoritativeNode = authoritativeNode
        self.skipUnchangedFileLocators = skipUnchangedFileLocators
        self.skipKnownFileLocators = skipKnownFileLocators
        self.excludedSnapshotSources = excludedSnapshotSources
        self.didFinishAdapter = didFinishAdapter
        self.didExcludeSnapshot = didExcludeSnapshot
    }

    public func indexSnapshots(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason = .initialScan
    ) throws -> SessionBatchUpsertResult {
        let excluded = snapshots.filter { excludedSnapshotSources.contains($0.source) }
        try sink.suppressExcludedSnapshots(excluded)
        for snapshot in excluded {
            didExcludeSnapshot(
                ExcludedSnapshotIndexEvent(
                    physicalSource: snapshot.source,
                    outputSource: snapshot.source,
                    locator: snapshot.sourceLocator
                )
            )
        }
        return try sink.upsertBatch(
            snapshots.filter { !excludedSnapshotSources.contains($0.source) },
            reason: reason
        )
    }

    /// Returns the number of snapshots that changed durable session state.
    /// No-op, skipped, and failed snapshots are excluded so callers see a
    /// truthful "indexed" count.
    @discardableResult
    public func indexAll(sources: Set<SourceName>? = nil) async throws -> Int {
        var batch: [ScannedSnapshot] = []
        var indexed = 0

        try await scanSnapshots(sources: sources) { snapshot, fileState in
            batch.append(ScannedSnapshot(snapshot: snapshot, fileState: fileState))
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
        // never against a Database handle held across the async scan above.
        return indexed
    }

    /// Writes one batch and returns the count of rows that were merged.
    /// Logs each per-snapshot failure so a silent fake-success cannot happen.
    private func writeBatchCountingSuccesses(_ batch: [ScannedSnapshot]) throws -> Int {
        let snapshots = batch.map(\.snapshot)
        let result = try sink.upsertBatch(
            snapshots,
            fileIndexStates: batch.map(\.fileState),
            reason: .initialScan
        )
        var merged = 0
        for item in result.results {
            if item.action == .failure {
                Self.log.error(
                    "session upsert failed: session=\(item.sessionId) error=\(item.error ?? "unknown")"
                )
                continue
            }
            if item.action == .merge {
                merged += 1
            }
        }
        return merged
    }

    public func collectSnapshots(sources: Set<SourceName>? = nil) async throws -> [AuthoritativeSessionSnapshot] {
        var snapshots: [AuthoritativeSessionSnapshot] = []
        try await scanSnapshots(sources: sources) { snapshot, _ in
            snapshots.append(snapshot)
        }
        return snapshots
    }

    private struct ScannedSnapshot {
        var snapshot: AuthoritativeSessionSnapshot
        var fileState: FileIndexState?
    }

    private func scanSnapshots(
        sources: Set<SourceName>? = nil,
        yield: (AuthoritativeSessionSnapshot, FileIndexState?) async throws -> Void
    ) async throws {
        for adapter in adapters {
            try Task.checkCancellation()
            if let sources, !sources.contains(adapter.source) { continue }
            guard await adapter.detect() else { continue }
            defer { didFinishAdapter(adapter.source) }

            let locators: [String]
            do {
                locators = try await adapter.listSessionLocators()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Isolate per-adapter failures: one unreadable source must not
                // abort the entire scan across all other adapters.
                Self.log.error(
                    "adapter listSessionLocators failed: source=\(adapter.source.rawValue) error=\(String(describing: error))"
                )
                continue
            }

            // Domain-scoped orphan prune. Empty enumerationRoots (default) skips;
            // only opted-in adapters (ClaudeCode) declare roots. A prune failure
            // is observable but cannot abort an otherwise healthy scan.
            let roots = adapter.enumerationRoots
            if !roots.isEmpty {
                do {
                    _ = try sink.pruneOrphanFileIndexStates(
                        source: adapter.source,
                        keeping: locators,
                        under: roots
                    )
                } catch {
                    Self.log.error(
                        "file_index_state prune failed: source=\(adapter.source.rawValue) error=\(String(describing: error))"
                    )
                }
            }

            let knownFileStates = skipUnchangedFileLocators
                ? (try? sink.knownIndexedFileStates(source: adapter.source, locators: locators))
                : nil
            let fileIndexStates = try? sink.knownFileIndexStates(source: adapter.source, locators: locators)
            // Startup scans set `skipKnownFileLocators`: they never enter
            // `attemptTailIndexing` below, so materializing full snapshots for
            // every known locator would be pure overhead. On large Claude
            // histories that also fans out into tools/costs/work-beat reads and
            // creates a multi-gigabyte transient allocation spike.
            let shouldLoadTailMergeSnapshots = !skipKnownFileLocators
                && adapter is any TailIndexingSessionAdapter
            let tailMergeSnapshots = shouldLoadTailMergeSnapshots
                ? (try? sink.knownTailMergeSnapshots(source: adapter.source, locators: locators))
                : nil
            let activeFileCutoff = Date().addingTimeInterval(-Self.activeFileGraceInterval)

            for locator in locators {
                try Task.checkCancellation()
                let currentStat = Self.fileIndexStat(adapter: adapter, locator: locator)
                let knownIndexedState = knownFileStates?[locator]
                let knownParseState = fileIndexStates?[locator]
                // docs/invariants.md #2 and #9: only a current parser state may
                // take the startup known-locator shortcut. A version mismatch
                // must reparse so false legacy subagent roles can heal while
                // genuine relative subagent layouts remain classified as skip.
                let canSkipKnownLocator = skipKnownFileLocators
                    && knownParseState?.schemaVersion == FileIndexState.currentSchemaVersion
                // Historical rows can be known/unchanged but predate instruction extraction.
                let needsInstructionBackfill =
                    knownIndexedState?.needsInstructionBackfill == true
                    && Self.reliableInstructionSources.contains(adapter.source)
                    && (knownParseState?.parseStatus ?? .ok) == .ok
                // Gemini can change without touching the main locator and still
                // reparses here. Copilot and Kimi expose complete composite
                // identities, so unchanged terminal inputs can safely skip.
                if skipUnchangedFileLocators,
                   (!Self.usesCompositeInputs(adapter.source)
                       || adapter.source == .copilot
                       || adapter.source == .kimi),
                   let currentStat,
                   !needsInstructionBackfill,
                   FileIndexDecision.decide(
                    stat: currentStat,
                    state: knownParseState,
                    now: Date()
                   ) == .skip {
                    continue
                }
                if !canSkipKnownLocator {
                    switch try await attemptTailIndexing(
                        adapter: adapter,
                        locator: locator,
                        currentStat: currentStat,
                        knownParseState: knownParseState,
                        currentSnapshot: tailMergeSnapshots?[locator]
                    ) {
                    case .yield(let snapshot, let fileState):
                        if excludedSnapshotSources.contains(snapshot.source) {
                            try suppressExcludedSnapshot(snapshot)
                            didExcludeSnapshot(
                                ExcludedSnapshotIndexEvent(
                                    physicalSource: adapter.source,
                                    outputSource: snapshot.source,
                                    locator: locator
                                )
                            )
                        } else {
                            try await yield(snapshot, fileState)
                        }
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
                            Self.log.notice(
                                "session tail skipped: source=\(adapter.source.rawValue) reason=\(failure.rawValue) locator=\(locator)"
                            )
                            continue
                        }
                        Self.log.error(
                            "session tail parse retryable; falling back to full scan: source=\(adapter.source.rawValue) reason=\(failure.rawValue) locator=\(locator)"
                        )
                        break
                    case .fallback:
                        break
                    }
                }
                if !skipKnownFileLocators,
                   !Self.usesCompositeInputs(adapter.source),
                   knownParseState == nil,
                   knownIndexedState != nil,
                   let currentStat,
                   currentStat.legacyState.modifiedAt > activeFileCutoff {
                    // A recent scan may observe an actively-written transcript
                    // before file_index_state exists. Defer without inventing a
                    // successful parse identity; startup scans still heal missing
                    // state once the transcript has settled. Existing checkpoints
                    // get their safe tail-merge attempt above before this grace.
                    continue
                }
                if !Self.usesCompositeInputs(adapter.source),
                   canSkipKnownLocator,
                   let currentFile = currentStat?.legacyState,
                   let indexed = knownIndexedState {
                    if !needsInstructionBackfill {
                        // Wave 7A C01/M03: deferral must NOT stamp file_index_state
                        // success for an unparsed (or actively-writing) identity.
                        // Leaving the prior parse state dirty lets a later recent
                        // scan see the identity mismatch and reparse.
                        if canSkipKnownLocator {
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
                        if FileIndexState.isTerminalFailure(reason) {
                            Self.log.notice(
                                "session skipped: source=\(adapter.source.rawValue) reason=\(reason.rawValue) locator=\(locator)"
                            )
                        } else {
                            Self.log.error(
                                "session parse failed: source=\(adapter.source.rawValue) reason=\(reason.rawValue) locator=\(locator)"
                            )
                        }
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
                        let fileState: FileIndexState?
                        if scan.parseFailure == nil {
                            fileState = currentStat.map { stat in
                                FileIndexState.success(
                                    source: adapter.source,
                                    locator: locator,
                                    stat: stat,
                                    now: Date(),
                                    parsedOffset: scan.checkpointParsedOffset,
                                    boundaryHash: scan.checkpointBoundaryHash
                                )
                            }
                        } else if let parseFailure = scan.parseFailure {
                            fileState = currentStat.map { stat in
                                FileIndexState.failure(
                                    source: adapter.source,
                                    locator: locator,
                                    stat: stat,
                                    failure: parseFailure,
                                    previous: fileIndexStates?[locator],
                                    now: Date()
                                )
                            }
                        } else {
                            fileState = nil
                        }
                        let snapshot = buildSnapshot(info: info, locator: locator, stats: stats)
                        if excludedSnapshotSources.contains(snapshot.source) {
                            try suppressExcludedSnapshot(snapshot)
                            didExcludeSnapshot(
                                ExcludedSnapshotIndexEvent(
                                    physicalSource: adapter.source,
                                    outputSource: snapshot.source,
                                    locator: locator
                                )
                            )
                        } else {
                            do {
                                try await yield(snapshot, fileState)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                throw SnapshotConsumerError(underlying: error)
                            }
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as SnapshotConsumerError {
                    throw error.underlying
                } catch let error as ExcludedSnapshotSuppressionError {
                    throw error.underlying
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
                        "session index error: source=\(adapter.source.rawValue) locator=\(locator) error=\(String(describing: error))"
                    )
                    continue
                }
            }
        }
    }

    private struct ExcludedSnapshotSuppressionError: Error {
        let underlying: any Error
    }

    private struct SnapshotConsumerError: Error {
        let underlying: any Error
    }

    private func suppressExcludedSnapshot(_ snapshot: AuthoritativeSessionSnapshot) throws {
        do {
            try sink.suppressExcludedSnapshots([snapshot])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExcludedSnapshotSuppressionError(underlying: error)
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
            // Tail adapters cap only the appended segment. Enforce the product
            // transcript cap cumulatively before recording a successful file
            // identity or enqueueing FTS work for an incomplete snapshot.
            let maxMessages = 10_000
            if let currentSnapshot,
               (currentSnapshot.messageCount > maxMessages
                   || tail.infoDelta.messageCount > maxMessages - currentSnapshot.messageCount)
            {
                return .failure(.messageLimitExceeded)
            }
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
        // H10: only merge when the prior full-parse fingerprint is durable.
        // Rows without content_fingerprint fall back so the next full pass
        // seeds the chain; after that pure user-led appends stay incremental.
        guard let priorFingerprint = current.contentFingerprint, !priorFingerprint.isEmpty else {
            return nil
        }

        let tailStats = computeStats(messages: tail.messages, provableSkip: false)
        guard let instructionSignals = mergeInstructionSignals(current: current, tailMessages: tail.messages) else {
            return nil
        }

        var stats = SessionStreamStats()
        stats.indexedMessageCount = currentSummaryCount + tailStats.indexedMessageCount
        stats.assistantCount = current.assistantMessageCount + tailStats.assistantCount
        stats.toolCount = current.toolMessageCount + tailStats.toolCount
        stats.toolCallCounts = mergedCounts(current.toolCallCounts, tailStats.toolCallCounts)
        stats.tokenUsage = mergedUsage(current.tokenUsage, tailStats.tokenUsage)
        stats.humanTurnCount = instructionSignals.humanTurnCount
        stats.instructions = instructionSignals.instructions
        // Extend the durable chain with only the tail's searchable content.
        // Same absorb rule as a full scan, so snapshotHash matches full reparse.
        stats.contentFingerprintState = priorFingerprint
        for message in tail.messages {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            if message.role == .user, Self.isSystemInjection(content) { continue }
            stats.absorbSearchableContent(role: message.role, content: content)
        }

        let info = NormalizedSessionInfo(
            id: current.id,
            source: current.source,
            startTime: current.startTime,
            endTime: tail.infoDelta.endTime ?? current.endTime,
            cwd: current.cwd,
            project: current.project,
            model: current.model ?? tail.infoDelta.model,
            messageCount: current.messageCount + tail.infoDelta.messageCount,
            userMessageCount: current.userMessageCount + tail.infoDelta.userMessageCount,
            assistantMessageCount: current.assistantMessageCount + tail.infoDelta.assistantMessageCount,
            toolMessageCount: current.toolMessageCount + tail.infoDelta.toolMessageCount,
            systemMessageCount: current.systemMessageCount + tail.infoDelta.systemMessageCount,
            summary: current.summary,
            filePath: locator,
            sizeBytes: stat.sizeBytes,
            indexedAt: current.indexedAt,
            agentRole: current.agentRole,
            origin: current.origin,
            parentSessionId: current.parentSessionId
        )
        var snapshot = buildSnapshot(info: info, locator: locator, stats: stats)
        let tailBeats = ImplementationDigestExtractor.extract(
            messages: tailStats.implementationMessages,
            sessionId: current.id,
            sessionTitle: current.summary
        ).enumerated().map { offset, beat in
            var adjusted = beat
            adjusted.beatIndex = current.implementationBeats.count + offset
            return adjusted
        }
        snapshot.implementationBeats = current.implementationBeats + tailBeats
        return snapshot
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
                "file index state write failed: source=\(source.rawValue) locator=\(locator) error=\(String(describing: error))"
            )
        }
    }

    private typealias SessionStreamStats = AuthoritativeSessionSnapshotBuilder.SessionStreamStats

    /// Terminal tail failures stay recorded; retryable ones fall through to full parse.
    /// R184-4: same classifier as the full-parse path so a tail `malformedJSON`
    /// / `invalidUtf8` / `fileMissing` does not skip the full scan.
    private static func isTerminalTailFailure(_ failure: ParserFailure) -> Bool {
        FileIndexState.isTerminalFailure(failure)
    }

    /// Skip conditions remain shared with direct pure snapshot construction.
    private static func isProvableSkip(info: NormalizedSessionInfo, locator: String) -> Bool {
        AuthoritativeSessionSnapshotBuilder.isProvableSkip(info: info, locator: locator)
    }

    private func computeStats(messages: [NormalizedMessage], provableSkip: Bool) -> SessionStreamStats {
        AuthoritativeSessionSnapshotBuilder.computeStats(messages: messages, provableSkip: provableSkip)
    }

    private func buildSnapshot(
        info: NormalizedSessionInfo,
        locator: String,
        stats: SessionStreamStats
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshotBuilder.build(
            info: info,
            stats: stats,
            sessionID: info.id,
            logicalLocator: locator,
            sourceLocator: locator,
            authoritativeNode: authoritativeNode,
            syncVersion: 1,
            indexedAt: Self.iso8601.string(from: Date())
        )
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        AuthoritativeSessionSnapshotBuilder.isSystemInjection(text)
    }

    private static let reliableInstructionSources = AuthoritativeSessionSnapshotBuilder.reliableInstructionSources

    // Composite-input sources read auxiliary files whose mtimes/sizes are not
    // reflected in the main locator. Main-file FileIndexDecision short-circuits
    // would permanently retain stale parent/cwd/content after aux-only rewrites.
    private static func usesCompositeInputs(_ source: SourceName) -> Bool {
        source == .kimi || source == .geminiCli || source == .copilot || source == .cursor
    }

    private static func fileIndexStat(
        adapter: any SessionAdapter,
        locator: String
    ) -> FileIndexStat? {
        if let identity = adapter.indexingInputIdentity(locator: locator) {
            return FileIndexStat(
                sizeBytes: identity.sizeBytes,
                modifiedAtNanos: identity.modifiedAtNanos,
                inode: identity.locatorInode,
                device: identity.locatorDevice
            )
        }
        return FileIndexStat.directFileStat(locator: locator)
    }
}
