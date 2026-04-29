import CryptoKit
import Foundation
import GRDB
import EngramCoreRead

public final class SwiftIndexer {
    private static let writeBatchSize = 100

    private let sink: any IndexingWriteSink
    private let adapters: [any SessionAdapter]
    private let authoritativeNode: String
    private let db: Database?

    public init(
        sink: any IndexingWriteSink,
        adapters: [any SessionAdapter] = [],
        authoritativeNode: String = "local",
        db: Database? = nil
    ) {
        self.sink = sink
        self.adapters = adapters
        self.authoritativeNode = authoritativeNode
        self.db = db
    }

    public func indexSnapshots(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason = .initialScan
    ) throws -> SessionBatchUpsertResult {
        try sink.upsertBatch(snapshots, reason: reason)
    }

    @discardableResult
    public func indexAll(sources: Set<SourceName>? = nil) async throws -> Int {
        var batch: [AuthoritativeSessionSnapshot] = []
        var indexed = 0

        for try await snapshot in streamSnapshots(sources: sources) {
            batch.append(snapshot)
            if batch.count >= Self.writeBatchSize {
                _ = try sink.upsertBatch(batch, reason: .initialScan)
                indexed += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            _ = try sink.upsertBatch(batch, reason: .initialScan)
            indexed += batch.count
        }

        if let db {
            _ = try StartupBackfills.backfillSuggestedParents(db)
        }
        return indexed
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

            for locator in try await adapter.listSessionLocators() {
                try Task.checkCancellation()
                switch try await adapter.parseSessionInfo(locator: locator) {
                case .failure:
                    continue
                case .success(var info):
                    if info.project == nil, !info.cwd.isEmpty {
                        info.project = URL(fileURLWithPath: info.cwd).lastPathComponent
                    }

                    let stats = try await streamStats(adapter: adapter, locator: locator)
                    yield(buildSnapshot(info: info, locator: locator, stats: stats))
                }
            }
        }
    }

    private struct SessionStreamStats {
        var indexedMessageCount = 0
        var assistantCount = 0
        var toolCount = 0
        var firstUserMessages: [String] = []
    }

    private func streamStats(adapter: any SessionAdapter, locator: String) async throws -> SessionStreamStats {
        var stats = SessionStreamStats()
        let stream = try await adapter.streamMessages(locator: locator, options: StreamMessagesOptions())
        for try await message in stream {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            guard message.role == .user || message.role == .assistant else { continue }

            stats.indexedMessageCount += 1
            if message.role == .assistant {
                stats.assistantCount += 1
            }
            if message.role == .tool || !(message.toolCalls ?? []).isEmpty {
                stats.toolCount += 1
            }
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
                isPreamble: isPreambleOnly(stats.firstUserMessages),
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
            indexedAt: ISO8601DateFormatter().string(from: Date()),
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
            agentRole: info.agentRole
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

    private func isPreambleOnly(_ userMessages: [String]) -> Bool {
        let combined = userMessages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return false }
        return combined.hasPrefix("# AGENTS.md instructions for ") ||
            combined.contains("<INSTRUCTIONS>") ||
            combined.hasPrefix("<environment_context>")
    }
}
