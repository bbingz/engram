import Foundation

public enum SessionTier: String, Codable, Equatable, Sendable {
    case skip
    case lite
    case normal
    case premium

    public static func compute(_ input: TierInput) -> SessionTier {
        if input.isPreamble { return .skip }
        if input.filePath.contains("/.engram/probes/") { return .skip }
        // Invariant 2: adapters stamp agentRole only after validating the
        // transcript layout relative to their enumeration root. Absolute path
        // substrings are not proof that a session is a subagent.
        if input.agentRole != nil { return .skip }
        if input.messageCount <= 1 { return .skip }
        if let assistantCount = input.assistantCount,
           assistantCount == 0,
           (input.toolCount ?? 0) == 0
        {
            return .lite
        }

        // Probe sessions with very few messages are likely tooling noise.
        // Mirrors the TypeScript reference (session-tier.ts) for parity.
        if input.messageCount <= 3,
           let summary = input.summary,
           probeFirstLines.contains(
               summary.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
           )
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

    // Kept in parity with the TypeScript reference (session-tier.ts).
    private static let noisePatterns = [
        "/usage",
        "Generate a short, clear title",
        "Reply exactly:",
        "Reply with exactly:",
        "reply with just",
        "/status/exit",
    ]

    // Shared with InstructionExtractor (same module) — keep internal, not private.
    static let probeFirstLines: Set<String> = [
        "ping", "quick ping", "test ping", "quick ping check", "ping-pong test",
        "hi", "hello", "test", "echo", "ok", "hey", "say hello", "reply: t4",
    ]

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

public struct SubagentTranscriptLayout: Equatable, Sendable {
    public let parentSessionId: String
    public let relativePath: String
}

public enum SubagentTranscriptPath {
    public static func layout(locator: String) -> SubagentTranscriptLayout? {
        layout(components: canonicalURL(locator).pathComponents)
    }

    private static func layout(components: [String]) -> SubagentTranscriptLayout? {
        guard let index = components.lastIndex(of: "subagents"),
              index >= 2,
              index + 1 < components.count
        else { return nil }
        let relative = Array(components[(index + 1)...])
        let isDirect = relative.count == 1 && relative[0].hasSuffix(".jsonl")
        let isWorkflow = relative.count >= 3
            && relative[0] == "workflows"
            && relative.last?.hasSuffix(".jsonl") == true
        guard isDirect || isWorkflow else { return nil }
        return SubagentTranscriptLayout(
            parentSessionId: components[index - 1],
            relativePath: relative.joined(separator: "/")
        )
    }

    public static func layout(locator: String, projectsRoot: String) -> SubagentTranscriptLayout? {
        let locatorComponents = canonicalURL(locator).pathComponents
        let rootComponents = canonicalURL(projectsRoot).pathComponents
        guard locatorComponents.count > rootComponents.count,
              Array(locatorComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }
        // docs/invariants.md #2: classify only vendor-stamped subagent layouts;
        // a project directory literally named `subagents` must not become skip.
        return layout(components: Array(locatorComponents.dropFirst(rootComponents.count)))
    }

    /// Qoder also stores project-level `project/subagents/file.jsonl` rows. The
    /// transcript supplies the real parent id, while this helper proves the
    /// path is confined to the same projects root used by the adapter.
    public static func layout(
        locator: String,
        projectsRoot: String,
        projectLevelParentSessionId: String
    ) -> SubagentTranscriptLayout? {
        if let nested = layout(locator: locator, projectsRoot: projectsRoot) {
            return nested
        }
        let normalizedParent = projectLevelParentSessionId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedParent.isEmpty else { return nil }
        let locatorComponents = canonicalURL(locator).pathComponents
        let rootComponents = canonicalURL(projectsRoot).pathComponents
        guard locatorComponents.count == rootComponents.count + 3,
              Array(locatorComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        let relative = Array(locatorComponents.dropFirst(rootComponents.count))
        guard relative[1] == "subagents", relative[2].hasSuffix(".jsonl") else {
            return nil
        }
        return SubagentTranscriptLayout(
            parentSessionId: normalizedParent,
            relativePath: "subagents/\(relative[2])"
        )
    }

    /// Locate a vendor's declared projects root without resolving a symlinked
    /// vendor directory. The later confined layout canonicalizes both the root
    /// and locator together, so `~/.qoder -> /Volumes/...` stays provable.
    public static func projectsRoot(locator: String, vendorDirectory: String) -> String? {
        let urls = [
            URL(fileURLWithPath: locator).standardizedFileURL,
            canonicalURL(locator),
        ]
        for url in urls {
            let components = url.pathComponents
            guard components.count >= 2 else { continue }
            for index in 0..<(components.count - 1)
                where components[index] == vendorDirectory && components[index + 1] == "projects"
            {
                return NSString.path(withComponents: Array(components.prefix(index + 2)))
            }
            if let projectsIndex = components.dropLast().lastIndex(of: "projects") {
                return NSString.path(withComponents: Array(components.prefix(projectsIndex + 1)))
            }
        }
        return nil
    }

    private static func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
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
