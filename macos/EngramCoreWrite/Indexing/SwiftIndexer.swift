import CryptoKit
import Foundation
import GRDB
import EngramCoreRead

public final class SwiftIndexer {
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
        let snapshots = try await collectSnapshots(sources: sources)
        guard !snapshots.isEmpty else { return 0 }
        _ = try sink.upsertBatch(snapshots, reason: .initialScan)
        if let db {
            _ = try StartupBackfills.backfillSuggestedParents(db)
        }
        return snapshots.count
    }

    public func collectSnapshots(sources: Set<SourceName>? = nil) async throws -> [AuthoritativeSessionSnapshot] {
        var snapshots: [AuthoritativeSessionSnapshot] = []
        for adapter in adapters {
            if let sources, !sources.contains(adapter.source) { continue }
            guard await adapter.detect() else { continue }

            for locator in try await adapter.listSessionLocators() {
                switch try await adapter.parseSessionInfo(locator: locator) {
                case .failure:
                    continue
                case .success(var info):
                    if info.project == nil, !info.cwd.isEmpty {
                        info.project = URL(fileURLWithPath: info.cwd).lastPathComponent
                    }

                    var messages: [NormalizedMessage] = []
                    let stream = try await adapter.streamMessages(locator: locator, options: StreamMessagesOptions())
                    for try await message in stream where !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if message.role == .user || message.role == .assistant {
                            messages.append(message)
                        }
                    }
                    snapshots.append(buildSnapshot(info: info, locator: locator, messages: messages))
                }
            }
        }
        return snapshots
    }

    private func buildSnapshot(
        info: NormalizedSessionInfo,
        locator: String,
        messages: [NormalizedMessage]
    ) -> AuthoritativeSessionSnapshot {
        let assistantCount = messages.filter { $0.role == .assistant }.count
        let toolCount = messages.filter { $0.role == .tool || !($0.toolCalls ?? []).isEmpty }.count
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
                isPreamble: isPreambleOnly(messages.filter { $0.role == .user }.prefix(3).map(\.content)),
                assistantCount: assistantCount,
                toolCount: toolCount
            )
        )
        let summaryMessageCount = messages.count
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
