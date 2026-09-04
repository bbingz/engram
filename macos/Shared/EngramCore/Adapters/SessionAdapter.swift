import Foundation

public enum SourceName: String, CaseIterable, Codable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case copilot
    case geminiCli = "gemini-cli"
    case opencode
    case iflow
    case qwen
    case qoder
    case kimi
    case minimax
    case lobsterai
    case commandcode
    case cline
    case cursor
    case vscode
    case antigravity
    case windsurf
}

/// Canonical filesystem roots shared by project migration and read-only audit
/// surfaces. Keep storage-only Codex roots here even though they are not
/// independent adapter sources.
public enum SessionStorageRootCatalog {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let relativePath: String

        public init(id: String, relativePath: String) {
            self.id = id
            self.relativePath = relativePath
        }
    }

    public static let entries: [Entry] = [
        Entry(id: "claude-code", relativePath: ".claude/projects"),
        Entry(id: "codex", relativePath: ".codex/sessions"),
        Entry(id: "codex-archived", relativePath: ".codex/archived_sessions"),
        Entry(id: "codex-rollout-summaries", relativePath: ".codex/memories/rollout_summaries"),
        Entry(id: "gemini-cli", relativePath: ".gemini/tmp"),
        Entry(id: "kimi", relativePath: ".kimi/sessions"),
        Entry(id: "iflow", relativePath: ".iflow/projects"),
        Entry(id: "qwen", relativePath: ".qwen/projects"),
        Entry(id: "qoder", relativePath: ".qoder/projects"),
        Entry(id: "opencode", relativePath: ".local/share/opencode"),
        Entry(id: "antigravity", relativePath: ".gemini/antigravity-cli/brain"),
        Entry(id: "antigravity-legacy", relativePath: ".gemini/antigravity"),
        Entry(id: "commandcode", relativePath: ".commandcode/projects"),
        Entry(id: "copilot", relativePath: ".copilot"),
    ]

    public static func paths(homeDirectory: URL) -> [(id: String, path: String)] {
        entries.map { entry in
            (
                id: entry.id,
                path: homeDirectory.appendingPathComponent(entry.relativePath).path
            )
        }
    }
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
    public var displayTitle: String?
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
        displayTitle: String? = nil,
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
        self.displayTitle = displayTitle
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

public struct StreamMessagesResult: Sendable {
    public var messages: AsyncThrowingStream<NormalizedMessage, Error>
    public var totalKnownComplete: Bool
    public var truncatedAt: Int?
    public var maxRawMessages: Int?
    public var parseFailure: ParserFailure?

    public var truncated: Bool { truncatedAt != nil || !totalKnownComplete }

    public init(
        messages: AsyncThrowingStream<NormalizedMessage, Error>,
        totalKnownComplete: Bool = true,
        truncatedAt: Int? = nil,
        maxRawMessages: Int? = nil,
        parseFailure: ParserFailure? = nil
    ) {
        self.messages = messages
        self.totalKnownComplete = totalKnownComplete
        self.truncatedAt = truncatedAt
        self.maxRawMessages = maxRawMessages
        self.parseFailure = parseFailure
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
    // Valid transcript bytes, but no user/assistant/tool messages visible to Engram.
    case noVisibleMessages
}

public enum AdapterParseResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(ParserFailure)
}

/// A session's parse-1 metadata plus its full message list, produced together so
/// the indexer can read+parse a changed transcript exactly once instead of
/// paying a separate `parseSessionInfo` pass and a `streamMessages` pass.
public struct IndexingScan: Sendable {
    public var info: NormalizedSessionInfo
    public var messages: [NormalizedMessage]
    public var parseFailure: ParserFailure?
    public var checkpointParsedOffset: Int64?
    public var checkpointBoundaryHash: String?
    /// Record kinds seen on the parse-once path that the adapter deliberately
    /// drops and that are not on its known-ignored allowlist. Empty for adapters
    /// that do not accumulate (protocol default / non-Claude-Code sources).
    public var unknownRecordKinds: Set<String>

    public init(
        info: NormalizedSessionInfo,
        messages: [NormalizedMessage],
        parseFailure: ParserFailure? = nil,
        checkpointParsedOffset: Int64? = nil,
        checkpointBoundaryHash: String? = nil,
        unknownRecordKinds: Set<String> = []
    ) {
        self.info = info
        self.messages = messages
        self.parseFailure = parseFailure
        self.checkpointParsedOffset = checkpointParsedOffset
        self.checkpointBoundaryHash = checkpointBoundaryHash
        self.unknownRecordKinds = unknownRecordKinds
    }
}

public struct IndexingTailInfoDelta: Sendable {
    public var id: String?
    public var source: SourceName?
    public var endTime: String?
    public var model: String?
    public var messageCount: Int
    public var userMessageCount: Int
    public var assistantMessageCount: Int
    public var toolMessageCount: Int
    public var systemMessageCount: Int
    public var firstVisibleRole: NormalizedMessageRole?

    public init(
        id: String?,
        source: SourceName?,
        endTime: String?,
        model: String?,
        messageCount: Int,
        userMessageCount: Int,
        assistantMessageCount: Int,
        toolMessageCount: Int,
        systemMessageCount: Int,
        firstVisibleRole: NormalizedMessageRole?
    ) {
        self.id = id
        self.source = source
        self.endTime = endTime
        self.model = model
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.toolMessageCount = toolMessageCount
        self.systemMessageCount = systemMessageCount
        self.firstVisibleRole = firstVisibleRole
    }
}

public struct IndexingTailScan: Sendable {
    public var infoDelta: IndexingTailInfoDelta
    public var messages: [NormalizedMessage]
    public var parsedOffset: Int64
    public var boundaryHash: String

    public init(
        infoDelta: IndexingTailInfoDelta,
        messages: [NormalizedMessage],
        parsedOffset: Int64,
        boundaryHash: String
    ) {
        self.infoDelta = infoDelta
        self.messages = messages
        self.parsedOffset = parsedOffset
        self.boundaryHash = boundaryHash
    }
}

public enum IndexingTailScanResult: Sendable {
    case success(IndexingTailScan)
    case fallback
    case failure(ParserFailure)
}

public protocol MessageAdapter {
    var source: SourceName { get }
    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error>
    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult
}

public struct IndexingInputIdentity: Equatable, Sendable {
    public let sizeBytes: Int64
    public let modifiedAtNanos: Int64
    public let locatorInode: Int64?
    public let locatorDevice: Int64?

    public init(
        sizeBytes: Int64,
        modifiedAtNanos: Int64,
        locatorInode: Int64?,
        locatorDevice: Int64?
    ) {
        self.sizeBytes = sizeBytes
        self.modifiedAtNanos = modifiedAtNanos
        self.locatorInode = locatorInode
        self.locatorDevice = locatorDevice
    }
}

public protocol SessionAdapter: MessageAdapter {
    func detect() async -> Bool
    func listSessionLocators() async throws -> [String]
    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo>
    func isAccessible(locator: String) async -> Bool
    /// Absolute path prefixes this adapter enumerates exhaustively. A prune may
    /// delete a `file_index_state` row only when its locator falls under one of
    /// these. Empty — the default — means the adapter declares no domain and is
    /// never pruned. Protocol requirement so it dispatches through `any SessionAdapter`.
    var enumerationRoots: [String] { get }
    /// Physical identity of every input consumed for one locator. Adapters
    /// backed by a single file use the default nil and the indexer stats the
    /// locator directly.
    func indexingInputIdentity(locator: String) -> IndexingInputIdentity?
    /// Parse a session's info and messages together. The default reuses the two
    /// existing entry points (two parses); adapters that can produce both from a
    /// single file read override this to parse once. Declared as a protocol
    /// requirement so overrides dispatch dynamically through `any SessionAdapter`.
    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan>
}

public protocol TailIndexingSessionAdapter: SessionAdapter {
    func scanTailForIndexing(
        locator: String,
        from parsedOffset: Int64,
        expectedBoundaryHash: String
    ) async throws -> IndexingTailScanResult
}

public extension SessionAdapter {
    /// Safe default: no declared domain → orphan prune never runs for this adapter.
    var enumerationRoots: [String] { [] }

    func indexingInputIdentity(locator: String) -> IndexingInputIdentity? { nil }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        StreamMessagesResult(
            messages: try await streamMessages(locator: locator, options: options)
        )
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        switch try await parseSessionInfo(locator: locator) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let info):
            // Use the metadata path so adapter-owned maxMessages caps fail
            // closed instead of indexing a silently truncated prefix.
            let result = try await streamMessagesWithMetadata(
                locator: locator,
                options: StreamMessagesOptions()
            )
            if result.truncatedAt != nil {
                return .failure(.messageLimitExceeded)
            }
            var messages: [NormalizedMessage] = []
            for try await message in result.messages {
                messages.append(message)
            }
            if let failure = result.parseFailure {
                guard failure == .fileModifiedDuringParse, !messages.isEmpty else {
                    return .failure(failure)
                }
                return .success(IndexingScan(
                    info: info,
                    messages: messages,
                    parseFailure: failure
                ))
            }
            if !result.totalKnownComplete {
                return .failure(.messageLimitExceeded)
            }
            return .success(IndexingScan(info: info, messages: messages))
        }
    }
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
