import Foundation

public enum SourceName: String, CaseIterable, Codable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case copilot
    case pi
    case geminiCli = "gemini-cli"
    case opencode
    case iflow
    case qwen
    case kimi
    case minimax
    case lobsterai
    case cline
    case cursor
    case vscode
    case antigravity
    case windsurf
}

public enum OriginatorClassifier {
    public static func isClaudeCode(_ originator: String?) -> Bool {
        guard let originator else { return false }
        let normalized = originator
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return normalized == "claude-code"
    }
}

public enum NormalizedMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int? = nil, cacheCreationTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }
}

public struct NormalizedToolCall: Codable, Equatable, Sendable {
    public var name: String
    public var input: String?
    public var output: String?

    public init(name: String, input: String? = nil, output: String? = nil) {
        self.name = name
        self.input = input
        self.output = output
    }
}

public struct NormalizedMessage: Codable, Equatable, Sendable {
    public var role: NormalizedMessageRole
    public var content: String
    public var timestamp: String?
    public var toolCalls: [NormalizedToolCall]?
    public var usage: TokenUsage?

    public init(
        role: NormalizedMessageRole,
        content: String,
        timestamp: String? = nil,
        toolCalls: [NormalizedToolCall]? = nil,
        usage: TokenUsage? = nil
    ) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

public struct NormalizedSessionInfo: Codable, Equatable, Sendable {
    public var id: String
    public var source: SourceName
    public var startTime: String
    public var endTime: String?
    public var cwd: String
    public var project: String?
    public var model: String?
    public var messageCount: Int
    public var userMessageCount: Int
    public var assistantMessageCount: Int
    public var toolMessageCount: Int
    public var systemMessageCount: Int
    public var summary: String?
    public var filePath: String
    public var sizeBytes: Int64
    public var indexedAt: String?
    public var agentRole: String?
    public var originator: String?
    public var origin: String?
    public var summaryMessageCount: Int?
    public var tier: String?
    public var qualityScore: Int?
    public var parentSessionId: String?
    public var suggestedParentId: String?

    public init(
        id: String,
        source: SourceName,
        startTime: String,
        endTime: String? = nil,
        cwd: String,
        project: String? = nil,
        model: String? = nil,
        messageCount: Int,
        userMessageCount: Int,
        assistantMessageCount: Int,
        toolMessageCount: Int,
        systemMessageCount: Int,
        summary: String? = nil,
        filePath: String,
        sizeBytes: Int64,
        indexedAt: String? = nil,
        agentRole: String? = nil,
        originator: String? = nil,
        origin: String? = nil,
        summaryMessageCount: Int? = nil,
        tier: String? = nil,
        qualityScore: Int? = nil,
        parentSessionId: String? = nil,
        suggestedParentId: String? = nil
    ) {
        self.id = id
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.cwd = cwd
        self.project = project
        self.model = model
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.toolMessageCount = toolMessageCount
        self.systemMessageCount = systemMessageCount
        self.summary = summary
        self.filePath = filePath
        self.sizeBytes = sizeBytes
        self.indexedAt = indexedAt
        self.agentRole = agentRole
        self.originator = originator
        self.origin = origin
        self.summaryMessageCount = summaryMessageCount
        self.tier = tier
        self.qualityScore = qualityScore
        self.parentSessionId = parentSessionId
        self.suggestedParentId = suggestedParentId
    }
}

public struct StreamMessagesOptions: Equatable, Sendable {
    public var offset: Int?
    public var limit: Int?

    public init(offset: Int? = nil, limit: Int? = nil) {
        self.offset = offset
        self.limit = limit
    }
}

public enum ParserFailure: String, CaseIterable, Error, Codable, Equatable, Sendable {
    case fileMissing
    case fileTooLarge
    case invalidUtf8
    case truncatedJSON
    case truncatedJSONL
    case malformedJSON
    case malformedToolCall
    case deeplyNestedRecord
    case messageLimitExceeded
    case lineTooLarge
    case fileModifiedDuringParse
    case sqliteUnreadable
    case grpcUnavailable
    case unsupportedVirtualLocator
}

public enum AdapterParseResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(ParserFailure)
}

public protocol MessageAdapter {
    var source: SourceName { get }
    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error>
}

public protocol SessionAdapter: MessageAdapter {
    func detect() async -> Bool
    func listSessionLocators() async throws -> [String]
    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo>
    func isAccessible(locator: String) async -> Bool
}

public protocol ProjectAdapter {
    var source: SourceName { get }
    func projectFields(for session: NormalizedSessionInfo) -> [String: JSONValue]
}

public protocol InsightAdapter {
    var source: SourceName { get }
    func insightFields(
        for session: NormalizedSessionInfo,
        messages: [NormalizedMessage]
    ) -> [String: JSONValue]
}

public protocol SearchAdapter {
    var source: SourceName { get }
    func searchIndexFields(
        for session: NormalizedSessionInfo,
        messages: [NormalizedMessage]
    ) -> [String: JSONValue]
}

public protocol StatsAdapter {
    var source: SourceName { get }
    func statsFields(for session: NormalizedSessionInfo) -> [String: JSONValue]
}
