import CryptoKit
import Foundation
import EngramCoreRead

/// Constructs a read-model value from an already parsed scan without source I/O.
/// Construction is NOT replay acceptance, completeness, or readiness authority.
/// The caller owns identity/parent resolution, epoch admission, and a persisted
/// monotonic syncVersion independent of a publication's per-epoch sequence.
public enum AuthoritativeSessionSnapshotBuilder {
    public static func build(
        from scan: IndexingScan,
        sessionID: String,
        logicalLocator: String,
        sourceLocator: String,
        authoritativeNode: String,
        syncVersion: Int,
        indexedAt: String
    ) -> AuthoritativeSessionSnapshot {
        var info = scan.info
        if info.project == nil, !info.cwd.isEmpty {
            info.project = URL(fileURLWithPath: info.cwd).lastPathComponent
        }
        let stats = computeStats(
            messages: scan.messages,
            provableSkip: isProvableSkip(info: info, locator: logicalLocator)
        )
        return build(
            info: info,
            stats: stats,
            sessionID: sessionID,
            logicalLocator: logicalLocator,
            sourceLocator: sourceLocator,
            authoritativeNode: authoritativeNode,
            syncVersion: syncVersion,
            indexedAt: indexedAt
        )
    }

    struct SessionStreamStats {
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
        /// Chained content fingerprint state (Wave 7A H10).
        /// Each absorbed message becomes
        /// `SHA256(hex(prev) || "\\n" || role || "\\n" || trimmed || "\\n")`,
        /// starting from empty `prev`. The chain is durable across appends so
        /// tail merges extend the same fingerprint a full reparse would build.
        var contentFingerprintState = ""

        mutating func absorbSearchableContent(role: NormalizedMessageRole, content: String) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // System content participates in the fingerprint so Copilot checkpoint
            // body rewrites (and similar aux system streams) invalidate even when
            // sizeBytes and user/assistant counts stay equal.
            guard role == .user || role == .assistant || role == .system else { return }
            var hasher = SHA256()
            hasher.update(data: Data(contentFingerprintState.utf8))
            hasher.update(data: Data("\n\(role.rawValue)\n\(trimmed)\n".utf8))
            contentFingerprintState = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        func contentFingerprintHex() -> String {
            contentFingerprintState
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

    /// Skip conditions that `SessionTier.compute` resolves to `.skip` using only
    /// pass-1 info (independent of the stats pass): each returns `.skip` before
    /// any stats-derived input is consulted, and no later branch can override a
    /// `.skip` verdict — so when this is true the final tier is guaranteed
    /// `.skip`, identical to computing it after the full pass.
    static func isProvableSkip(info: NormalizedSessionInfo, locator: String) -> Bool {
        locator.contains("/.engram/probes/")
            || info.agentRole != nil
            || info.messageCount <= 1
    }

    static func computeStats(messages: [NormalizedMessage], provableSkip: Bool) -> SessionStreamStats {
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
            if message.role == .system {
                // Fingerprint only — system turns are not tier/instruction inputs.
                if !content.isEmpty {
                    stats.absorbSearchableContent(role: .system, content: content)
                }
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

    // The legacy tail path already merged its metadata and must not receive
    // the full-scan project fallback.
    static func build(
        info: NormalizedSessionInfo,
        stats: SessionStreamStats,
        sessionID: String,
        logicalLocator: String,
        sourceLocator: String,
        authoritativeNode: String,
        syncVersion: Int,
        indexedAt: String
    ) -> AuthoritativeSessionSnapshot {
        let tier = SessionTier.compute(
            TierInput(
                messageCount: info.messageCount,
                agentRole: info.agentRole,
                filePath: logicalLocator,
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
        // Cursor's compact conversation summary can change without the visible
        // bubble count changing, so that count is not a summary version.
        let summaryMessageCount = info.source == .cursor ? nil : stats.indexedMessageCount
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
            sessionId: sessionID,
            sessionTitle: info.displayTitle ?? info.summary
        )
        return AuthoritativeSessionSnapshot(
            id: sessionID,
            source: info.source,
            authoritativeNode: authoritativeNode,
            syncVersion: syncVersion,
            snapshotHash: snapshotHash(
                info: info,
                summaryMessageCount: summaryMessageCount,
                contentFingerprint: stats.contentFingerprintHex()
            ),
            indexedAt: indexedAt,
            sourceLocator: sourceLocator,
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
            displayTitle: info.displayTitle,
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
            implementationBeats: implementationBeats,
            contentFingerprint: stats.contentFingerprintHex()
        )
    }

    private static func snapshotHash(
        info: NormalizedSessionInfo,
        summaryMessageCount: Int?,
        contentFingerprint: String
    ) -> String {
        var fields: [(String, String)] = [
            ("cwd", jsonString(info.cwd))
        ]
        // Kimi wire/shard timestamps and Copilot workspace.yaml times must
        // invalidate even when locator sizeBytes stay equal.
        if info.source == .kimi || info.source == .copilot {
            fields.append(("startTime", jsonString(info.startTime)))
            if let endTime = info.endTime {
                fields.append(("endTime", jsonString(endTime)))
            }
        }
        if let project = info.project { fields.append(("project", jsonString(project))) }
        if let model = info.model { fields.append(("model", jsonString(model))) }
        fields.append(("messageCount", "\(info.messageCount)"))
        fields.append(("userMessageCount", "\(info.userMessageCount)"))
        fields.append(("assistantMessageCount", "\(info.assistantMessageCount)"))
        fields.append(("toolMessageCount", "\(info.toolMessageCount)"))
        fields.append(("systemMessageCount", "\(info.systemMessageCount)"))
        if let summary = info.summary { fields.append(("summary", jsonString(summary))) }
        if let displayTitle = info.displayTitle { fields.append(("displayTitle", jsonString(displayTitle))) }
        if let summaryMessageCount {
            fields.append(("summaryMessageCount", "\(summaryMessageCount)"))
        }
        // Sidecar/aux metadata (e.g. Gemini parent/role) must invalidate even when
        // transcript body counts are unchanged.
        if let parentSessionId = info.parentSessionId {
            fields.append(("parentSessionId", jsonString(parentSessionId)))
        }
        if let agentRole = info.agentRole {
            fields.append(("agentRole", jsonString(agentRole)))
        }
        // Wave 7A H10: body rewrites with stable counts must change the hash.
        fields.append(("contentFingerprint", jsonString(contentFingerprint)))

        let json = "{\(fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ","))}"
        let digest = SHA256.hash(data: Data(json.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let encoded = String(data: data, encoding: .utf8)!
        return String(encoded.dropFirst().dropLast())
    }

    private static func isSkippableFirstUserMessages(_ userMessages: [String]) -> Bool {
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

    static func isSystemInjection(_ text: String) -> Bool {
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
        "ping", "quick ping", "test ping", "quick ping check", "ping-pong test"
    ]

    // Sources whose adapter emits reliable .user roles in streamMessages, so
    // instruction extraction can be trusted. Others store NULL instruction signals
    // (default-visible). Graduate a source by adding it here + an adapter-uniformity
    // parity test proving its stream emits non-empty .user content.
    static let reliableInstructionSources: Set<SourceName> = [.claudeCode, .codex]

}
