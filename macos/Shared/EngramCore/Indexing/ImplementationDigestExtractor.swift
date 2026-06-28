import Foundation

public enum SessionImplementationKind: String, Codable, Equatable, Sendable {
    case implementation
    case fix
    case optimization
    case security
    case research
    case maintenance
    case deployment
    case verification
}

public enum SessionImplementationStatus: String, Codable, Equatable, Sendable {
    case completed
    case partial
    case operationOnly = "operation_only"
}

public enum SessionOperationEvent: String, Codable, Equatable, Sendable {
    case pushed
    case merged
    case ciGreen = "ci_green"
    case committed
    case deployed
    case verified
    case savedMemory = "saved_memory"
    case cleanupOnly = "cleanup_only"
}

public struct SessionImplementationBeat: Codable, Equatable, Sendable {
    public var sessionId: String
    public var beatIndex: Int
    public var actionDate: String
    public var actionTimestamp: String?
    public var workKey: String
    public var workTitle: String
    public var humanIntent: String
    public var assistantOutcome: String
    public var kind: SessionImplementationKind
    public var status: SessionImplementationStatus
    public var operationEvents: [SessionOperationEvent]
    public var confidence: Double

    public init(
        sessionId: String,
        beatIndex: Int,
        actionDate: String,
        actionTimestamp: String? = nil,
        workKey: String,
        workTitle: String,
        humanIntent: String,
        assistantOutcome: String,
        kind: SessionImplementationKind,
        status: SessionImplementationStatus,
        operationEvents: [SessionOperationEvent],
        confidence: Double
    ) {
        self.sessionId = sessionId
        self.beatIndex = beatIndex
        self.actionDate = actionDate
        self.actionTimestamp = actionTimestamp
        self.workKey = workKey
        self.workTitle = workTitle
        self.humanIntent = humanIntent
        self.assistantOutcome = assistantOutcome
        self.kind = kind
        self.status = status
        self.operationEvents = operationEvents
        self.confidence = confidence
    }
}

public struct ImplementationTimelineItem: Equatable, Sendable {
    public var id: String
    public var workKey: String
    public var title: String
    public var startDate: String
    public var endDate: String
    public var batchIndex: Int
    public var kind: SessionImplementationKind
    public var beats: [SessionImplementationBeat]
    public var semanticTitle: String?

    public init(
        id: String,
        workKey: String,
        title: String,
        startDate: String,
        endDate: String,
        batchIndex: Int,
        kind: SessionImplementationKind,
        beats: [SessionImplementationBeat],
        semanticTitle: String? = nil
    ) {
        self.id = id
        self.workKey = workKey
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.batchIndex = batchIndex
        self.kind = kind
        self.beats = beats
        self.semanticTitle = semanticTitle
    }
}

public enum ImplementationDigestExtractor {
    private struct AssistantCandidate {
        var text: String
        var timestamp: String?
        var score: Int
    }

    private struct PendingBeat {
        var humanIntent: String
        var timestamp: String?
        var assistants: [AssistantCandidate] = []
    }

    public static func extract(
        messages: [NormalizedMessage],
        sessionId: String,
        sessionTitle: String? = nil
    ) -> [SessionImplementationBeat] {
        var pending: PendingBeat?
        var beats: [SessionImplementationBeat] = []

        func flush() {
            guard let current = pending else { return }
            guard let beat = buildBeat(
                pending: current,
                sessionId: sessionId,
                beatIndex: beats.count,
                sessionTitle: sessionTitle
            ) else { return }
            beats.append(beat)
        }

        for message in messages {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            switch message.role {
            case .user:
                guard !isMachineUserTurn(content) else { continue }
                flush()
                pending = PendingBeat(humanIntent: content, timestamp: message.timestamp)
            case .assistant:
                guard pending != nil else { continue }
                pending?.assistants.append(
                    AssistantCandidate(
                        text: content,
                        timestamp: message.timestamp,
                        score: completionScore(content)
                    )
                )
            case .system, .tool:
                continue
            }
        }

        flush()
        return beats
    }

    private static func buildBeat(
        pending: PendingBeat,
        sessionId: String,
        beatIndex: Int,
        sessionTitle: String?
    ) -> SessionImplementationBeat? {
        let intent = clean(pending.humanIntent)
        guard !intent.isEmpty else { return nil }

        let selected = pending.assistants.max {
            if $0.score == $1.score {
                return ($0.timestamp ?? "") < ($1.timestamp ?? "")
            }
            return $0.score < $1.score
        }
        let outcome = clean(selected?.text ?? "")
        let combined = "\(intent)\n\(outcome)"
        let events = operationEvents(in: combined)
        var kind = classifyKind(intent: intent, outcome: outcome)
        var status: SessionImplementationStatus = (selected?.score ?? 0) >= 2 ? .completed : .partial

        if isOperationOnlyDirective(intent: intent, outcome: outcome, events: events) {
            status = .operationOnly
            if kind == .implementation {
                kind = .verification
            }
        }

        let actionTimestamp = selected?.timestamp ?? pending.timestamp
        let actionDate = dateKey(from: actionTimestamp) ?? dateKey(from: pending.timestamp) ?? "unknown"
        let title = titleFor(intent: intent, fallback: sessionTitle)
        return SessionImplementationBeat(
            sessionId: sessionId,
            beatIndex: beatIndex,
            actionDate: actionDate,
            actionTimestamp: actionTimestamp,
            workKey: workKey(for: title),
            workTitle: title,
            humanIntent: String(intent.prefix(600)),
            assistantOutcome: String(outcome.prefix(1200)),
            kind: kind,
            status: status,
            operationEvents: events,
            confidence: confidence(status: status, score: selected?.score ?? 0)
        )
    }

    private static func isMachineUserTurn(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        return trimmed.hasPrefix("# AGENTS.md instructions for ")
            || trimmed.contains("<INSTRUCTIONS>")
            || trimmed.hasPrefix("<codex_internal_context")
            || trimmed.hasPrefix("<task-notification>")
            || trimmed.hasPrefix("<local-command")
            || trimmed.hasPrefix("<command-name>")
            || trimmed.hasPrefix("<command-message>")
            || trimmed.hasPrefix("<tool_use_result")
            || trimmed.hasPrefix("<tool_result")
            || trimmed.hasPrefix("<environment_context>")
            || trimmed.hasPrefix("<skills_instructions>")
            || trimmed.hasPrefix("<plugins_instructions>")
            || lower.contains("caveat: the messages below were generated by the user while running local commands")
    }

    private static func completionScore(_ text: String) -> Int {
        let lower = text.lowercased()
        var score = 0
        for marker in ["**结果**", "## 结果", "### 结果", "结果\n", "最终状态", "改了什么", "验证结果", "checks run", "check_run", "checks_run"] {
            if lower.contains(marker.lowercased()) { score += 2 }
        }
        for marker in ["已完成", "完成", "已实现", "已修复", "已提交", "已推送", "已合并", "全绿", "success"] {
            if lower.contains(marker.lowercased()) { score += 1 }
        }
        let prefix = lower.prefix(80)
        for marker in ["我先", "我会", "我再", "正在", "先快速", "后台 watch", "收到，我先"] {
            if prefix.contains(marker.lowercased()) { score -= 1 }
        }
        if lower.contains("要试试吗") || lower.contains("请确认") || lower.contains("是否") {
            score -= 1
        }
        return score
    }

    private static func classifyKind(intent: String, outcome: String) -> SessionImplementationKind {
        let text = "\(intent)\n\(outcome)".lowercased()
        if containsAny(text, ["安全", "security", "cve", "漏洞"]) { return .security }
        if containsAny(text, ["修复", "fix", "bug", "regression", "drift"]) { return .fix }
        if containsAny(text, ["优化", "optimiz", "performance", "refactor", "cleanup"]) { return .optimization }
        if containsAny(text, ["调研", "报告", "review", "audit", "盘点", "梳理"]) { return .research }
        if containsAny(text, ["备份", "归档", "磁盘", "清理", "维护", "maintenance"]) { return .maintenance }
        if containsAny(text, ["部署", "安装", "deploy", "/applications/engram.app"]) { return .deployment }
        if containsAny(text, ["实现", "新增", "功能", "add ", "implement", "feature"]) { return .implementation }
        if containsAny(text, ["验证", "ci", "checks run", "测试", "全绿"]) { return .verification }
        return .implementation
    }

    private static func operationEvents(in text: String) -> [SessionOperationEvent] {
        let lower = text.lowercased()
        var events: [SessionOperationEvent] = []
        func append(_ event: SessionOperationEvent, when condition: Bool) {
            if condition, !events.contains(event) { events.append(event) }
        }
        append(.pushed, when: containsAny(lower, ["已推送", "pushed", "push 到", "push to"]))
        append(.merged, when: containsAny(lower, ["已合并", "合并完成", "squash-merge", "merged"]))
        append(.ciGreen, when: containsAny(lower, ["ci 全绿", "全绿", "all checks", "全部 success", "12/12"]))
        append(.committed, when: containsAny(lower, ["已提交", "commit ", "commit 在"]))
        append(.deployed, when: containsAny(lower, ["已部署", "部署到", "deployed", "/applications/engram.app"]))
        append(.verified, when: containsAny(lower, ["验证结果", "checks run", "测试通过", "0 failures"]))
        append(.savedMemory, when: containsAny(lower, ["memory", "changelog", ".memory"]))
        append(.cleanupOnly, when: containsAny(lower, ["worktree 清理", "删除分支", "分支清理", "branch cleanup"]))
        return events
    }

    private static func isOperationOnlyDirective(
        intent: String,
        outcome: String,
        events: [SessionOperationEvent]
    ) -> Bool {
        let normalized = collapseWhitespace(intent.lowercased())
        if normalized == "合吧" || normalized == "合并吧" || normalized == "merge it" {
            return true
        }
        if normalized.contains("跑完了没") || normalized.contains("ci 绿了就合并") {
            return true
        }
        if events == [.merged] || events == [.merged, .ciGreen] || events == [.ciGreen] {
            return true
        }
        if normalized.contains("清理") && events.contains(.cleanupOnly) && !containsAny(outcome.lowercased(), ["备份", "归档", "磁盘"]) {
            return true
        }
        return false
    }

    private static func titleFor(intent: String, fallback: String?) -> String {
        let firstLine = intent.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? intent
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(90)) }
        return String((fallback ?? "Untitled work").prefix(90))
    }

    private static func confidence(status: SessionImplementationStatus, score: Int) -> Double {
        switch status {
        case .completed:
            return min(0.95, 0.7 + Double(max(0, score)) * 0.03)
        case .partial:
            return 0.45
        case .operationOnly:
            return 0.35
        }
    }

    private static func dateKey(from timestamp: String?) -> String? {
        guard let timestamp, timestamp.count >= 10 else { return nil }
        let key = String(timestamp.prefix(10))
        guard key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return key
    }

    private static func workKey(for title: String) -> String {
        let lower = title.lowercased()
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar.value > 0x2E80 ? Character(scalar) : " "
        }
        let collapsed = collapseWhitespace(String(scalars))
        return String(collapsed.prefix(120))
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0.lowercased()) }
    }
}

public enum ImplementationTimelineBuilder {
    public static func build(beats: [SessionImplementationBeat]) -> [ImplementationTimelineItem] {
        let visible = beats
            .filter { $0.status != .operationOnly }
            .sorted { lhs, rhs in
                if lhs.workKey == rhs.workKey {
                    if lhs.actionDate == rhs.actionDate {
                        return lhs.beatIndex < rhs.beatIndex
                    }
                    return lhs.actionDate < rhs.actionDate
                }
                return lhs.workKey < rhs.workKey
            }

        let grouped = Dictionary(grouping: visible, by: \.workKey)
        var items: [ImplementationTimelineItem] = []
        for (workKey, group) in grouped {
            let ordered = group.sorted { lhs, rhs in
                if lhs.actionDate == rhs.actionDate {
                    return (lhs.actionTimestamp ?? "") < (rhs.actionTimestamp ?? "")
                }
                return lhs.actionDate < rhs.actionDate
            }
            var current: [SessionImplementationBeat] = []
            var batch = 0
            for beat in ordered {
                if let last = current.last, !isAdjacentOrSame(last.actionDate, beat.actionDate) {
                    batch += 1
                    items.append(item(workKey: workKey, beats: current, batchIndex: batch))
                    current = []
                }
                current.append(beat)
            }
            if !current.isEmpty {
                batch += 1
                items.append(item(workKey: workKey, beats: current, batchIndex: batch))
            }
        }

        return items.sorted {
            if $0.startDate == $1.startDate { return $0.title < $1.title }
            return $0.startDate < $1.startDate
        }
    }

    private static func item(
        workKey: String,
        beats: [SessionImplementationBeat],
        batchIndex: Int
    ) -> ImplementationTimelineItem {
        let sortedDates = beats.map(\.actionDate).sorted()
        let title = beats.first?.workTitle ?? "Untitled work"
        let kind = beats.first?.kind ?? .implementation
        return ImplementationTimelineItem(
            id: "\(workKey):\(batchIndex)",
            workKey: workKey,
            title: title,
            startDate: sortedDates.first ?? "unknown",
            endDate: sortedDates.last ?? "unknown",
            batchIndex: batchIndex,
            kind: kind,
            beats: beats
        )
    }

    private static func isAdjacentOrSame(_ lhs: String, _ rhs: String) -> Bool {
        guard let l = date(lhs), let r = date(rhs) else { return lhs == rhs }
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: l, to: r).day ?? Int.max
        return days >= 0 && days <= 1
    }

    private static func date(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}
