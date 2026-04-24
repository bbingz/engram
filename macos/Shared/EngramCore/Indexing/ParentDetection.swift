import Foundation

public struct ScoredParent: Decodable, Equatable, Sendable {
    public var parentId: String
    public var score: Double

    public init(parentId: String, score: Double) {
        self.parentId = parentId
        self.score = score
    }
}

public enum ParentDetection {
    public static let detectionVersion = 4

    private static let probeMessages: Set<String> = [
        "ping",
        "hello",
        "hi",
        "update",
        "test",
        "what is 2+2?",
        "what is 2+2? reply with just the number.",
        "reply with only the model name you are running as, nothing else",
        "say hi",
        "say hello",
        "exit",
        "q",
        "quit",
        "list-skills",
        "auth login",
        "say: all fixes verified",
        "this prompt will fail"
    ]

    private static let dispatchPatterns = [
        #"(?:^|\n)\s*<task>"#,
        #"(?:^|\n)\s*<user_action>"#,
        #"(?:^|\n)\s*Your task is(?: to)?\b"#,
        #"^You are a\b.*\bagent\b"#,
        #"^You are a\b.*\bassistant\b"#,
        #"^You are (?:implementing|reviewing|debugging|auditing|evaluating|performing)\b"#,
        #"^Review the\b"#,
        #"^Review this\b"#,
        #"(?:^|\n)\s*(?:Review|Re-review|Perform|Evaluate|Investigate|Audit|Inspect|Check|Verify|Implement(?: Task \d+)?:?|Fix(?: Task \d+)?:?|Final (?:code quality|spec compliance) review)\b.*(?:/Users/|git diff|repo|repository|branch|spec|plan|implementation|code|diff|task|files?)"#,
        #"^Analyze (?:the |this |all )"#,
        #"^IMPORTANT:\s*Do NOT"#,
        #"^Generate a file named\b"#,
        #"^(?:Read|Check|Verify|Audit|Inspect) the\b.*(?:code|file|implementation|spec|plan)"#,
        #"^(?:Fix|Debug|Implement|Refactor|Write tests for)\s.*(?:/|\.ts\b|\.js\b|\.py\b|\.swift\b|bug|issue|error|module|component|function)"#,
        #"^(?:Context|Background|Instructions):\s"#,
        #"^The following (?:code|changes|files|implementation)\b"#,
        #"(?:^|\n)\s*<instructions>"#
    ].map { compile($0) }

    private static let probePatterns = [
        #"^what is \d+\s*[+\-*/]\s*\d+\??$"#,
        #"^say (?:hello|hi)\b.{0,20}$"#,
        #"^say exactly:\s*\S.{0,40}$"#,
        #"^echo\b"#,
        #"^(?:reply|respond)\s+with\b"#
    ].map { compile($0) }

    public static func isDispatchPattern(_ firstMessage: String) -> Bool {
        if firstMessage.isEmpty { return true }
        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if probeMessages.contains(trimmed.lowercased()) { return true }
        if probePatterns.contains(where: { matches($0, trimmed) }) { return true }
        if trimmed.count < 10 { return false }
        return dispatchPatterns.contains { matches($0, trimmed) }
    }

    public static func scoreCandidate(
        agentStartTime: String,
        parentStartTime: String,
        parentEndTime: String?,
        agentProject: String?,
        parentProject: String?,
        agentCwd: String? = nil,
        parentCwd: String? = nil
    ) -> Double {
        guard let agentStart = parseDate(agentStartTime),
              let parentStart = parseDate(parentStartTime)
        else {
            return 0
        }

        if agentStart < parentStart { return 0 }

        let cwdRelation = classifyCwdRelation(agentCwd: agentCwd, parentCwd: parentCwd)
        let hasProjectMatch = agentProject != nil && parentProject != nil && agentProject == parentProject

        var endedBeforeAgent = false
        if let parentEndTime, let parentEnd = parseDate(parentEndTime), agentStart > parentEnd {
            let gap = agentStart.timeIntervalSince(parentEnd)
            let maxGap: TimeInterval = 4 * 60 * 60
            if cwdRelation == .unrelated || cwdRelation == .unknown { return 0 }
            if gap > maxGap { return 0 }
            endedBeforeAgent = true
        }

        let diffSeconds = agentStart.timeIntervalSince(parentStart)
        let unrelatedCwdTimePenalty = cwdRelation == .unrelated ? 0.35 : 1
        let timeScore = exp(-diffSeconds / 14_400) * 0.6 * unrelatedCwdTimePenalty

        let projectScore: Double
        if hasProjectMatch {
            projectScore = 0.3
        } else if cwdRelation == .exact {
            projectScore = 0.28
        } else if cwdRelation == .nested {
            projectScore = 0.24
        } else {
            projectScore = 0
        }

        var activeScore: Double
        if parentEndTime == nil {
            activeScore = 0.1
        } else if endedBeforeAgent {
            activeScore = 0.02
        } else {
            activeScore = 0.05
        }
        if !hasProjectMatch && cwdRelation == .unrelated {
            activeScore = parentEndTime == nil ? 0.02 : 0.01
        }

        return timeScore + projectScore + activeScore
    }

    public static func pickBestCandidate(_ scored: [ScoredParent]) -> String? {
        guard let best = scored.sorted(by: { $0.score > $1.score }).first,
              best.score != 0
        else {
            return nil
        }
        return best.parentId
    }

    private enum CwdRelation {
        case exact
        case nested
        case unrelated
        case unknown
    }

    private static func classifyCwdRelation(agentCwd: String?, parentCwd: String?) -> CwdRelation {
        guard let agent = normalizeCwd(agentCwd),
              let parent = normalizeCwd(parentCwd)
        else {
            return .unknown
        }
        if agent == parent { return .exact }
        if agent.hasPrefix("\(parent)/") || parent.hasPrefix("\(agent)/") {
            return .nested
        }
        return .unrelated
    }

    private static func normalizeCwd(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let normalized = cwd.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        return normalized.isEmpty ? nil : normalized
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func compile(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
