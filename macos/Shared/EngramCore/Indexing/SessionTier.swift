import Foundation

public enum SessionTier: String, Codable, Equatable, Sendable {
    case skip
    case lite
    case normal
    case premium

    public static func compute(_ input: TierInput) -> SessionTier {
        if input.isPreamble { return .skip }
        if input.filePath.contains("/.engram/probes/") { return .skip }
        if input.agentRole != nil { return .skip }
        if input.filePath.contains("/subagents/") { return .skip }
        if input.messageCount <= 1 { return .skip }
        if let assistantCount = input.assistantCount,
           assistantCount == 0,
           (input.toolCount ?? 0) == 0
        {
            return .lite
        }

        if input.messageCount >= 20 { return .premium }
        if input.messageCount >= 10, input.project != nil { return .premium }
        if durationMinutes(startTime: input.startTime, endTime: input.endTime) > 30 {
            return .premium
        }

        if let summary = input.summary,
           noisePatterns.contains(where: { summary.contains($0) })
        {
            return .lite
        }

        return .normal
    }

    private static let noisePatterns = ["/usage", "Generate a short, clear title"]

    private static func durationMinutes(startTime: String?, endTime: String?) -> Double {
        guard let startTime,
              let endTime,
              let start = parseDate(startTime),
              let end = parseDate(endTime)
        else {
            return 0
        }
        return end.timeIntervalSince(start) / 60
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
}

public struct TierInput: Equatable, Sendable {
    public var messageCount: Int
    public var agentRole: String?
    public var filePath: String
    public var project: String?
    public var summary: String?
    public var startTime: String?
    public var endTime: String?
    public var source: String
    public var isPreamble: Bool
    public var assistantCount: Int?
    public var toolCount: Int?

    public init(
        messageCount: Int = 5,
        agentRole: String? = nil,
        filePath: String = "/home/user/.claude/projects/my-project/session.jsonl",
        project: String? = nil,
        summary: String? = nil,
        startTime: String? = nil,
        endTime: String? = nil,
        source: String = "claude-code",
        isPreamble: Bool = false,
        assistantCount: Int? = nil,
        toolCount: Int? = nil
    ) {
        self.messageCount = messageCount
        self.agentRole = agentRole
        self.filePath = filePath
        self.project = project
        self.summary = summary
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.isPreamble = isPreamble
        self.assistantCount = assistantCount
        self.toolCount = toolCount
    }
}
