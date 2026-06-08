import CryptoKit
import Foundation
import EngramCoreRead
import os

public final class SwiftIndexer {
    private static let writeBatchSize = 100
    private static let log = os.Logger(subsystem: "com.engram.service", category: "indexer")
    // Shared formatter — allocating one per indexed session is wasteful.
    private static let iso8601 = ISO8601DateFormatter()

    private let sink: any IndexingWriteSink
    private let adapters: [any SessionAdapter]
    private let authoritativeNode: String

    public init(
        sink: any IndexingWriteSink,
        adapters: [any SessionAdapter] = [],
        authoritativeNode: String = "local"
    ) {
        self.sink = sink
        self.adapters = adapters
        self.authoritativeNode = authoritativeNode
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
        var batch: [AuthoritativeSessionSnapshot] = []
        var indexed = 0

        for try await snapshot in streamSnapshots(sources: sources) {
            batch.append(snapshot)
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
    private func writeBatchCountingSuccesses(_ batch: [AuthoritativeSessionSnapshot]) throws -> Int {
        let result = try sink.upsertBatch(batch, reason: .initialScan)
        var failures = 0
        for item in result.results where item.action == .failure {
            failures += 1
            Self.log.error(
                "session upsert failed: session=\(item.sessionId, privacy: .private) error=\(item.error ?? "unknown", privacy: .private)"
            )
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
                    try await scanSnapshots(sources: sources) { snapshot in
                        continuation.yield(snapshot)
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
        yield: (AuthoritativeSessionSnapshot) -> Void
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

            for locator in locators {
                try Task.checkCancellation()
                do {
                    switch try await adapter.parseSessionInfo(locator: locator) {
                    case .failure(let reason):
                        Self.log.error(
                            "session parse failed: source=\(adapter.source.rawValue, privacy: .private) reason=\(reason.rawValue, privacy: .private) locator=\(locator, privacy: .private)"
                        )
                        continue
                    case .success(var info):
                        if info.project == nil, !info.cwd.isEmpty {
                            info.project = URL(fileURLWithPath: info.cwd).lastPathComponent
                        }

                        let stats = try await streamStats(adapter: adapter, locator: locator)
                        yield(buildSnapshot(info: info, locator: locator, stats: stats))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
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

    private struct SessionStreamStats {
        var indexedMessageCount = 0
        var assistantCount = 0
        var toolCount = 0
        var firstUserMessages: [String] = []
        var toolCallCounts: [String: Int] = [:]
        var tokenUsage: TokenUsage?

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

    private func streamStats(adapter: any SessionAdapter, locator: String) async throws -> SessionStreamStats {
        var stats = SessionStreamStats()
        let stream = try await adapter.streamMessages(locator: locator, options: StreamMessagesOptions())
        for try await message in stream {
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

            let hasToolCalls = !(message.toolCalls ?? []).isEmpty
            if message.role == .assistant, !content.isEmpty || hasToolCalls {
                stats.assistantCount += 1
            }
            if hasToolCalls {
                stats.toolCount += 1
            }
            guard !content.isEmpty else { continue }
            stats.indexedMessageCount += 1
            if message.role == .user, stats.firstUserMessages.count < 3 {
                stats.firstUserMessages.append(message.content)
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
        return AuthoritativeSessionSnapshot(
            id: info.id,
            source: info.source,
            authoritativeNode: authoritativeNode,
            syncVersion: 1,
            snapshotHash: snapshotHash(info: info, summaryMessageCount: summaryMessageCount),
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
            origin: authoritativeNode,
            tier: tier,
            agentRole: info.agentRole,
            parentSessionId: info.parentSessionId,
            toolCallCounts: stats.toolCallCounts,
            tokenUsage: stats.tokenUsage
        )
    }

    private func snapshotHash(info: NormalizedSessionInfo, summaryMessageCount: Int) -> String {
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
}
