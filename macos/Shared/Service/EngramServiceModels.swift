import Foundation

enum EngramServiceJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: EngramServiceJSONValue])
    case array([EngramServiceJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([EngramServiceJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: EngramServiceJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

enum EngramServiceStatus: Codable, Equatable, Sendable {
    case stopped
    case starting
    case running(total: Int, todayParents: Int)
    case degraded(message: String)
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case state
        case total
        case todayParents
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .state) {
        case "stopped":
            self = .stopped
        case "starting":
            self = .starting
        case "running":
            self = .running(
                total: try container.decode(Int.self, forKey: .total),
                todayParents: try container.decodeIfPresent(Int.self, forKey: .todayParents) ?? 0
            )
        case "degraded":
            self = .degraded(message: try container.decode(String.self, forKey: .message))
        case "error":
            self = .error(message: try container.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Unknown service status state"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stopped:
            try container.encode("stopped", forKey: .state)
        case .starting:
            try container.encode("starting", forKey: .state)
        case .running(let total, let todayParents):
            try container.encode("running", forKey: .state)
            try container.encode(total, forKey: .total)
            try container.encode(todayParents, forKey: .todayParents)
        case .degraded(let message):
            try container.encode("degraded", forKey: .state)
            try container.encode(message, forKey: .message)
        case .error(let message):
            try container.encode("error", forKey: .state)
            try container.encode(message, forKey: .message)
        }
    }
}

struct EngramServiceUsageItem: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(source)_\(metric)" }
    let source: String
    let metric: String
    let value: Double
    let unit: String?
    let limit: Double?
    let resetAt: String?
    let status: String?
}

struct EngramServiceEvent: Codable, Equatable, Sendable {
    let event: String
    let indexed: Int?
    let total: Int?
    let todayParents: Int?
    let message: String?
    /// Failure detail for `index_error` events. The service emits the failure
    /// under the `error` key (see `ServiceIndexErrorEvent`), not `message`, so
    /// without this the detail is dropped.
    let errorDetail: String?
    let sessionId: String?
    let summary: String?
    let port: Int?
    let host: String?
    let action: String?
    let removed: Int?
    let usage: [EngramServiceUsageItem]?

    enum CodingKeys: String, CodingKey {
        case event
        case indexed
        case total
        case todayParents
        case message
        case error
        case sessionId
        case summary
        case port
        case host
        case action
        case removed
        case usage
        case data
    }

    init(
        event: String,
        indexed: Int? = nil,
        total: Int? = nil,
        todayParents: Int? = nil,
        message: String? = nil,
        errorDetail: String? = nil,
        sessionId: String? = nil,
        summary: String? = nil,
        port: Int? = nil,
        host: String? = nil,
        action: String? = nil,
        removed: Int? = nil,
        usage: [EngramServiceUsageItem]? = nil
    ) {
        self.event = event
        self.indexed = indexed
        self.total = total
        self.todayParents = todayParents
        self.message = message
        self.errorDetail = errorDetail
        self.sessionId = sessionId
        self.summary = summary
        self.port = port
        self.host = host
        self.action = action
        self.removed = removed
        self.usage = usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(String.self, forKey: .event)
        indexed = try container.decodeIfPresent(Int.self, forKey: .indexed)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        todayParents = try container.decodeIfPresent(Int.self, forKey: .todayParents)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        errorDetail = try container.decodeIfPresent(String.self, forKey: .error)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        removed = try container.decodeIfPresent(Int.self, forKey: .removed)
        usage = try container.decodeIfPresent([EngramServiceUsageItem].self, forKey: .usage)
            ?? container.decodeIfPresent([EngramServiceUsageItem].self, forKey: .data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(indexed, forKey: .indexed)
        try container.encodeIfPresent(total, forKey: .total)
        try container.encodeIfPresent(todayParents, forKey: .todayParents)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(errorDetail, forKey: .error)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(removed, forKey: .removed)
        try container.encodeIfPresent(usage, forKey: .usage)
    }
}

struct EngramServiceRequestEnvelope: Codable, Equatable, Sendable {
    let requestId: String
    let kind: String
    let command: String
    let payload: Data?
    /// Per-launch capability token authorizing destructive commands. Optional
    /// so non-destructive requests (and older clients) stay compatible.
    let capabilityToken: String?

    init(
        requestId: String = UUID().uuidString,
        kind: String = "request",
        command: String,
        payload: Data? = nil,
        capabilityToken: String? = nil
    ) {
        self.requestId = requestId
        self.kind = kind
        self.command = command
        self.payload = payload
        self.capabilityToken = capabilityToken
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case kind
        case command
        case payload
        case capabilityToken = "capability_token"
    }
}

enum EngramServiceResponseEnvelope: Codable, Equatable, Sendable {
    /// `databaseGeneration` is consumed by the MCP read-consistency path
    /// (EngramMCP); the app `EngramServiceClient` ignores it.
    case success(requestId: String, result: Data, databaseGeneration: Int? = nil)
    case failure(requestId: String, error: EngramServiceErrorEnvelope)

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case kind
        case ok
        case result
        case error
        case databaseGeneration = "database_generation"
    }

    var requestId: String {
        switch self {
        case .success(let requestId, _, _), .failure(let requestId, _):
            return requestId
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requestId = try container.decode(String.self, forKey: .requestId)
        let ok = try container.decode(Bool.self, forKey: .ok)
        if ok {
            self = .success(
                requestId: requestId,
                result: try container.decode(Data.self, forKey: .result),
                databaseGeneration: try container.decodeIfPresent(Int.self, forKey: .databaseGeneration)
            )
        } else {
            self = .failure(
                requestId: requestId,
                error: try container.decode(EngramServiceErrorEnvelope.self, forKey: .error)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let requestId, let result, let databaseGeneration):
            try container.encode(requestId, forKey: .requestId)
            try container.encode("response", forKey: .kind)
            try container.encode(true, forKey: .ok)
            try container.encode(result, forKey: .result)
            try container.encodeIfPresent(databaseGeneration, forKey: .databaseGeneration)
        case .failure(let requestId, let error):
            try container.encode(requestId, forKey: .requestId)
            try container.encode("response", forKey: .kind)
            try container.encode(false, forKey: .ok)
            try container.encode(error, forKey: .error)
        }
    }
}

struct EngramServiceSearchRequest: Codable, Equatable, Sendable {
    let query: String
    let mode: String
    let limit: Int
    let project: String?
    let source: String?
    let since: String?

    init(
        query: String,
        mode: String,
        limit: Int,
        project: String? = nil,
        source: String? = nil,
        since: String? = nil
    ) {
        self.query = query
        self.mode = mode
        self.limit = limit
        self.project = project
        self.source = source
        self.since = since
    }
}

struct EngramServiceSearchResponse: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String?
        let snippet: String?
        let matchType: String?
        let score: Double?
        let source: String?
        let startTime: String?
        let endTime: String?
        let cwd: String?
        let project: String?
        let model: String?
        let messageCount: Int?
        let userMessageCount: Int?
        let assistantMessageCount: Int?
        let systemMessageCount: Int?
        let summary: String?
        let filePath: String?
        let sourceLocator: String?
        let sizeBytes: Int?
        let indexedAt: String?
        let agentRole: String?
        let customName: String?
        let tier: String?
        let toolMessageCount: Int?
        let generatedTitle: String?
        let parentSessionId: String?
        let suggestedParentId: String?
        let linkSource: String?
        let qualityScore: Int?

        init(
            id: String,
            title: String? = nil,
            snippet: String? = nil,
            matchType: String? = nil,
            score: Double? = nil,
            source: String? = nil,
            startTime: String? = nil,
            endTime: String? = nil,
            cwd: String? = nil,
            project: String? = nil,
            model: String? = nil,
            messageCount: Int? = nil,
            userMessageCount: Int? = nil,
            assistantMessageCount: Int? = nil,
            systemMessageCount: Int? = nil,
            summary: String? = nil,
            filePath: String? = nil,
            sourceLocator: String? = nil,
            sizeBytes: Int? = nil,
            indexedAt: String? = nil,
            agentRole: String? = nil,
            customName: String? = nil,
            tier: String? = nil,
            toolMessageCount: Int? = nil,
            generatedTitle: String? = nil,
            parentSessionId: String? = nil,
            suggestedParentId: String? = nil,
            linkSource: String? = nil,
            qualityScore: Int? = nil
        ) {
            self.id = id
            self.title = title
            self.snippet = snippet
            self.matchType = matchType
            self.score = score
            self.source = source
            self.startTime = startTime
            self.endTime = endTime
            self.cwd = cwd
            self.project = project
            self.model = model
            self.messageCount = messageCount
            self.userMessageCount = userMessageCount
            self.assistantMessageCount = assistantMessageCount
            self.systemMessageCount = systemMessageCount
            self.summary = summary
            self.filePath = filePath
            self.sourceLocator = sourceLocator
            self.sizeBytes = sizeBytes
            self.indexedAt = indexedAt
            self.agentRole = agentRole
            self.customName = customName
            self.tier = tier
            self.toolMessageCount = toolMessageCount
            self.generatedTitle = generatedTitle
            self.parentSessionId = parentSessionId
            self.suggestedParentId = suggestedParentId
            self.linkSource = linkSource
            self.qualityScore = qualityScore
        }
    }

    let items: [Item]
    let searchModes: [String]?
    let warning: String?

    init(items: [Item], searchModes: [String]? = nil, warning: String? = nil) {
        self.items = items
        self.searchModes = searchModes
        self.warning = warning
    }
}

struct EngramServiceHealthResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let status: String
    let message: String?
}

struct EngramServiceLiveSessionsResponse: Codable, Equatable, Sendable {
    let sessions: [EngramServiceLiveSessionInfo]
    let count: Int
}

struct EngramServiceLiveSessionInfo: Codable, Equatable, Identifiable, Sendable {
    var id: String { sessionId ?? filePath }
    let source: String
    let sessionId: String?
    let project: String?
    let title: String?
    let cwd: String?
    let filePath: String
    let startedAt: String?
    let model: String?
    let currentActivity: String?
    let lastModifiedAt: String
    let activityLevel: String?
}

struct EngramServiceSourceInfo: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let sessionCount: Int
    let latestIndexed: String?
    let searchableSessionCount: Int
    let searchCoveragePercent: Int
    let failedIndexJobCount: Int
    let tokenSessionCount: Int
    let tokenCoveragePercent: Int
    let costedSessionCount: Int
    let latestUsageMetric: String?
    let latestUsageValue: Double?
    let latestUsageUnit: String?
    let latestUsageLimitValue: Double?
    let latestUsageResetAt: String?
    let latestUsageStatus: String?
    let healthStatus: String
    /// True for cache-only sources (Windsurf/Antigravity) whose adapters run
    /// with live gRPC sync disabled. Defaulted false so all existing callers,
    /// tests, and legacy JSON keep decoding/compiling.
    let liveSyncDisabled: Bool

    init(
        name: String,
        sessionCount: Int,
        latestIndexed: String?,
        searchableSessionCount: Int = 0,
        searchCoveragePercent: Int = 0,
        failedIndexJobCount: Int = 0,
        tokenSessionCount: Int = 0,
        tokenCoveragePercent: Int = 0,
        costedSessionCount: Int = 0,
        latestUsageMetric: String? = nil,
        latestUsageValue: Double? = nil,
        latestUsageUnit: String? = nil,
        latestUsageLimitValue: Double? = nil,
        latestUsageResetAt: String? = nil,
        latestUsageStatus: String? = nil,
        healthStatus: String = "unknown",
        liveSyncDisabled: Bool = false
    ) {
        self.name = name
        self.sessionCount = sessionCount
        self.latestIndexed = latestIndexed
        self.searchableSessionCount = searchableSessionCount
        self.searchCoveragePercent = searchCoveragePercent
        self.failedIndexJobCount = failedIndexJobCount
        self.tokenSessionCount = tokenSessionCount
        self.tokenCoveragePercent = tokenCoveragePercent
        self.costedSessionCount = costedSessionCount
        self.latestUsageMetric = latestUsageMetric
        self.latestUsageValue = latestUsageValue
        self.latestUsageUnit = latestUsageUnit
        self.latestUsageLimitValue = latestUsageLimitValue
        self.latestUsageResetAt = latestUsageResetAt
        self.latestUsageStatus = latestUsageStatus
        self.healthStatus = healthStatus
        self.liveSyncDisabled = liveSyncDisabled
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case sessionCount
        case latestIndexed
        case searchableSessionCount
        case searchCoveragePercent
        case failedIndexJobCount
        case tokenSessionCount
        case tokenCoveragePercent
        case costedSessionCount
        case latestUsageMetric
        case latestUsageValue
        case latestUsageUnit
        case latestUsageLimitValue
        case latestUsageResetAt
        case latestUsageStatus
        case healthStatus
        case liveSyncDisabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        latestIndexed = try container.decodeIfPresent(String.self, forKey: .latestIndexed)
        searchableSessionCount = try container.decodeIfPresent(Int.self, forKey: .searchableSessionCount) ?? 0
        searchCoveragePercent = try container.decodeIfPresent(Int.self, forKey: .searchCoveragePercent) ?? 0
        failedIndexJobCount = try container.decodeIfPresent(Int.self, forKey: .failedIndexJobCount) ?? 0
        tokenSessionCount = try container.decodeIfPresent(Int.self, forKey: .tokenSessionCount) ?? 0
        tokenCoveragePercent = try container.decodeIfPresent(Int.self, forKey: .tokenCoveragePercent) ?? 0
        costedSessionCount = try container.decodeIfPresent(Int.self, forKey: .costedSessionCount) ?? 0
        latestUsageMetric = try container.decodeIfPresent(String.self, forKey: .latestUsageMetric)
        latestUsageValue = try container.decodeIfPresent(Double.self, forKey: .latestUsageValue)
        latestUsageUnit = try container.decodeIfPresent(String.self, forKey: .latestUsageUnit)
        latestUsageLimitValue = try container.decodeIfPresent(Double.self, forKey: .latestUsageLimitValue)
        latestUsageResetAt = try container.decodeIfPresent(String.self, forKey: .latestUsageResetAt)
        latestUsageStatus = try container.decodeIfPresent(String.self, forKey: .latestUsageStatus)
        healthStatus = try container.decodeIfPresent(String.self, forKey: .healthStatus) ?? "unknown"
        liveSyncDisabled = try container.decodeIfPresent(Bool.self, forKey: .liveSyncDisabled) ?? false
    }
}

struct EngramServiceSkillInfo: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(scope)/\(name)" }
    let name: String
    let description: String
    let path: String
    let scope: String
}

struct EngramServiceMemoryFile: Codable, Equatable, Identifiable, Sendable {
    var id: String { path }
    let name: String
    let project: String
    let path: String
    let sizeBytes: Int
    let preview: String
    /// Full file content. Optional so older/leaner service payloads (and the
    /// existing `testStage3` round-trip, which omits it) still decode; the
    /// detail viewer falls back to `preview` when nil.
    let content: String?

    init(
        name: String,
        project: String,
        path: String,
        sizeBytes: Int,
        preview: String,
        content: String? = nil
    ) {
        self.name = name
        self.project = project
        self.path = path
        self.sizeBytes = sizeBytes
        self.preview = preview
        self.content = content
    }
}

struct EngramServiceInsightInfo: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let content: String
    let wing: String?
    let room: String?
    let importance: Int
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case wing
        case room
        case importance
        case createdAt = "created_at"
    }
}

/// Detail-on-demand request for a single insight's full content. List responses
/// return only a truncated preview to stay under the 256 KiB IPC frame; the
/// detail viewer fetches the full row by id.
struct EngramServiceInsightDetailRequest: Codable, Equatable, Sendable {
    let id: String
}

/// Detail-on-demand request for a single memory file's full content. List
/// responses omit `content` to stay under the IPC frame; the detail viewer
/// fetches the full body by path.
struct EngramServiceMemoryFileContentRequest: Codable, Equatable, Sendable {
    let path: String
}

/// Full content of a single memory file, capped service-side at ~200 KiB with
/// a truncation marker appended when the file exceeds the cap.
struct EngramServiceMemoryFileContentResponse: Codable, Equatable, Sendable {
    let path: String
    let content: String
    let truncated: Bool
}

struct EngramServiceHookInfo: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(scope)/\(event)/\(command)" }
    let event: String
    let command: String
    let scope: String
    /// Source settings.json that defines the hook (~-expanded), so the UI can
    /// reveal/open it. Populated by FileSystemEngramServiceReadProvider.hooks();
    /// optional so payloads that predate the field (or omit a known source)
    /// still decode rather than throwing keyNotFound.
    let path: String?
}

struct EngramServiceHygieneRequest: Codable, Equatable, Sendable {
    let force: Bool
}

struct EngramServiceHygieneIssue: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(kind)-\(message.prefix(40))" }
    let kind: String
    let severity: String
    let message: String
    let detail: String?
    let repo: String?
    let action: String?
}

struct EngramServiceHygieneResponse: Codable, Equatable, Sendable {
    let issues: [EngramServiceHygieneIssue]
    let score: Int
    let checkedAt: String
}

struct EngramServiceHandoffRequest: Codable, Equatable, Sendable {
    let cwd: String
    let sessionId: String?
    let format: String?
}

struct EngramServiceHandoffResponse: Codable, Equatable, Sendable {
    let brief: String
    let sessionCount: Int
}

struct EngramServiceReplayTimelineRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let limit: Int?
}

struct EngramServiceReplayTimelineEntry: Codable, Equatable, Identifiable, Sendable {
    struct Tokens: Codable, Equatable, Sendable {
        let input: Int
        let output: Int
    }

    var id: Int { index }
    let index: Int
    let role: String
    let type: String
    let preview: String
    let timestamp: String?
    let toolName: String?
    let tokens: Tokens?
    let durationToNextMs: Int?
}

struct EngramServiceReplayTimelineResponse: Codable, Equatable, Sendable {
    let sessionId: String?
    let source: String?
    let entries: [EngramServiceReplayTimelineEntry]
    let totalEntries: Int
    let hasMore: Bool?
    let offset: Int?
    let limit: Int?
}

struct EngramServiceEmbeddingStatusResponse: Codable, Equatable, Sendable {
    let available: Bool
    let model: String?
    let embeddedCount: Int
    let totalSessions: Int
    let progress: Int
}

struct EngramServiceGenerateSummaryRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct EngramServiceGenerateSummaryResponse: Codable, Equatable, Sendable {
    let summary: String
}

struct EngramServiceSaveInsightRequest: Codable, Equatable, Sendable {
    let content: String
    let wing: String?
    let room: String?
    let importance: Double?
    let sourceSessionId: String?
    let actor: String?

    enum CodingKeys: String, CodingKey {
        case content
        case wing
        case room
        case importance
        case sourceSessionId = "source_session_id"
        case actor
    }
}

struct EngramServiceDeleteInsightRequest: Codable, Equatable, Sendable {
    let id: String
}

struct EngramServiceProjectAliasRequest: Codable, Equatable, Sendable {
    let action: String
    let oldProject: String?
    let newProject: String?
    let actor: String?

    enum CodingKeys: String, CodingKey {
        case action
        case oldProject = "old_project"
        case newProject = "new_project"
        case actor
    }
}

struct EngramServiceProjectMoveBatchRequest: Codable, Equatable, Sendable {
    let yaml: String
    let dryRun: Bool
    let force: Bool
    let actor: String?

    enum CodingKeys: String, CodingKey {
        case yaml
        case dryRun = "dry_run"
        case force
        case actor
    }
}

struct EngramServiceFavoriteRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let favorite: Bool
}

struct EngramServiceSessionHiddenRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let hidden: Bool
}

struct EngramServiceRenameSessionRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let name: String?
}

struct EngramServiceSessionAccessRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct EngramServiceHideEmptySessionsResponse: Codable, Equatable, Sendable {
    let hiddenCount: Int
}

struct EngramServiceLinkSessionsRequest: Codable, Equatable, Sendable {
    let targetDir: String
    let actor: String?

    enum CodingKeys: String, CodingKey {
        case targetDir
        case actor
    }
}

struct EngramServiceLinkSessionsResponse: Codable, Equatable, Sendable {
    let created: Int
    let skipped: Int
    let errors: [String]
    let targetDir: String
    let projectNames: [String]
    let truncated: Bool?
}

struct EngramServiceExportSessionRequest: Codable, Equatable, Sendable {
    let id: String
    let format: String
    let outputHome: String?
    let actor: String?

    enum CodingKeys: String, CodingKey {
        case id
        case format
        case outputHome = "output_home"
        case actor
    }
}

struct EngramServiceExportSessionResponse: Codable, Equatable, Sendable {
    let outputPath: String
    let format: String
    let messageCount: Int
}

struct EngramServiceResumeCommandRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct EngramServiceResumeCommandResponse: Codable, Equatable, Sendable {
    let tool: String?
    let command: String?
    let args: [String]
    let cwd: String?
    let contextPrimer: String?
    let error: String?
    let hint: String?

    init(
        tool: String? = nil,
        command: String? = nil,
        args: [String] = [],
        cwd: String? = nil,
        contextPrimer: String? = nil,
        error: String? = nil,
        hint: String? = nil
    ) {
        self.tool = tool
        self.command = command
        self.args = args
        self.cwd = cwd
        self.contextPrimer = contextPrimer
        self.error = error
        self.hint = hint
    }
}

struct EngramServiceLinkRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let parentId: String
}

struct EngramServiceUnlinkRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct EngramServiceConfirmSuggestionRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct EngramServiceDismissSuggestionRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let suggestedParentId: String
}

struct EngramServiceLinkResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let error: String?
}

struct EngramServiceTriggerSyncRequest: Codable, Equatable, Sendable {
    let peer: String?
}

struct EngramServiceTriggerSyncResponse: Codable, Equatable, Sendable {
    struct ResultItem: Codable, Equatable, Sendable {
        let peer: String?
        let ok: Bool?
        let pulled: Int?
        let pushed: Int?
        let error: String?
    }

    let results: [ResultItem]
}

struct EngramServiceRefreshUsageResponse: Codable, Equatable, Sendable {
    let snapshotCount: Int
    let sources: [String]
    let pressure: [EngramServiceUsageItem]

    init(
        snapshotCount: Int,
        sources: [String],
        pressure: [EngramServiceUsageItem] = []
    ) {
        self.snapshotCount = snapshotCount
        self.sources = sources
        self.pressure = pressure
    }

    private enum CodingKeys: String, CodingKey {
        case snapshotCount
        case sources
        case pressure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshotCount = try container.decode(Int.self, forKey: .snapshotCount)
        sources = try container.decode([String].self, forKey: .sources)
        pressure = try container.decodeIfPresent([EngramServiceUsageItem].self, forKey: .pressure) ?? []
    }
}

struct EngramServiceRegenerateTitlesResponse: Codable, Equatable, Sendable {
    let status: String
    let total: Int?
    let message: String?
}

struct EngramServiceProjectMigrationsRequest: Codable, Equatable, Sendable {
    let state: String?
    let limit: Int
}

struct EngramServiceProjectMigrationsResponse: Codable, Equatable, Sendable {
    let migrations: [EngramServiceMigrationLogEntry]
}

struct EngramServiceMigrationLogEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let oldPath: String
    let newPath: String
    let oldBasename: String
    let newBasename: String
    let state: String
    let startedAt: String
    let finishedAt: String?
    let archived: Bool
    let auditNote: String?
    let actor: String
    let detail: [String: EngramServiceJSONValue]?
}

struct EngramServiceProjectCwdsRequest: Codable, Equatable, Sendable {
    let project: String
}

struct EngramServiceProjectCwdsResponse: Codable, Equatable, Sendable {
    let project: String
    let cwds: [String]
}

struct EngramServiceCostsResponse: Codable, Equatable, Sendable {
    struct SourceRow: Codable, Equatable, Identifiable, Sendable {
        var id: String { key }
        let key: String
        let costUsd: Double
        let sessionCount: Int
    }

    struct DayRow: Codable, Equatable, Identifiable, Sendable {
        var id: String { day }
        let day: String
        let costUsd: Double
    }

    let totalUsd: Double
    let perSource: [SourceRow]
    let perDay: [DayRow]
    let monthToDateUsd: Double
    let todayUsd: Double
}

struct ServiceCommandLatency: Codable, Equatable, Identifiable, Sendable {
    var id: String { command }
    let command: String
    let count: Int
    let p50Ms: Double
    let p95Ms: Double
    let maxMs: Double
    let errorCount: Int
}

struct ServiceSpan: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(command)#\(startedAt)" }
    let command: String
    let startedAt: String
    let durationMs: Double
    let ok: Bool
    let errorName: String?
}

struct ServiceTelemetrySnapshot: Codable, Equatable, Sendable {
    let lastScanDurationMs: Double?
    let lastScanIndexed: Int
    let lastScanTotal: Int
    let scanCount: Int
    let lastScanAt: String?
    let commands: [ServiceCommandLatency]
    let spans: [ServiceSpan]
}

struct EngramServiceProjectMoveRequest: Codable, Equatable, Sendable {
    let src: String
    let dst: String
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
    let actor: String?
}

struct EngramServiceProjectArchiveRequest: Codable, Equatable, Sendable {
    let src: String
    let archiveTo: String?
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
    let actor: String?
}

struct EngramServiceProjectUndoRequest: Codable, Equatable, Sendable {
    let migrationId: String
    let force: Bool
    let actor: String?
}

struct EngramServiceProjectMoveResult: Codable, Equatable, Sendable {
    struct ReviewBlock: Codable, Equatable, Sendable {
        let own: [String]
        let other: [String]
    }

    struct ManifestEntry: Codable, Equatable, Identifiable, Sendable {
        let path: String
        let occurrences: Int
        var id: String { path }
    }

    struct PerSource: Codable, Equatable, Identifiable, Sendable {
        struct WalkIssue: Codable, Equatable, Identifiable, Sendable {
            let path: String
            let reason: String
            let detail: String?
            var id: String { "\(reason)::\(path)" }
        }

        let id: String
        let root: String
        let filesPatched: Int
        let occurrences: Int
        let issues: [WalkIssue]?
    }

    struct SkippedDir: Codable, Equatable, Identifiable, Sendable {
        let sourceId: String
        let reason: String
        let dir: String?
        var id: String { "\(sourceId)::\(dir ?? reason)" }
    }

    struct ArchiveSuggestion: Codable, Equatable, Sendable {
        let category: String?
        let dst: String
        let reason: String
    }

    let migrationId: String
    let state: String
    let moveStrategy: String?
    let ccDirRenamed: Bool
    let renamedDirs: [String]?
    let totalFilesPatched: Int
    let totalOccurrences: Int
    let sessionsUpdated: Int
    let aliasCreated: Bool
    let review: ReviewBlock
    let git: GitStatus?
    let manifest: [ManifestEntry]?
    let perSource: [PerSource]?
    let skippedDirs: [SkippedDir]?
    let suggestion: ArchiveSuggestion?

    private enum CodingKeys: String, CodingKey {
        case migrationId
        case state
        case moveStrategy
        case ccDirRenamed
        case renamedDirs
        case totalFilesPatched
        case totalOccurrences
        case sessionsUpdated
        case aliasCreated
        case review
        case git
        case manifest
        case perSource
        case skippedDirs
        case suggestion
        case archive
    }

    init(
        migrationId: String,
        state: String,
        moveStrategy: String? = nil,
        ccDirRenamed: Bool,
        renamedDirs: [String]? = nil,
        totalFilesPatched: Int,
        totalOccurrences: Int,
        sessionsUpdated: Int,
        aliasCreated: Bool,
        review: ReviewBlock,
        git: GitStatus? = nil,
        manifest: [ManifestEntry]? = nil,
        perSource: [PerSource]? = nil,
        skippedDirs: [SkippedDir]? = nil,
        suggestion: ArchiveSuggestion? = nil
    ) {
        self.migrationId = migrationId
        self.state = state
        self.moveStrategy = moveStrategy
        self.ccDirRenamed = ccDirRenamed
        self.renamedDirs = renamedDirs
        self.totalFilesPatched = totalFilesPatched
        self.totalOccurrences = totalOccurrences
        self.sessionsUpdated = sessionsUpdated
        self.aliasCreated = aliasCreated
        self.review = review
        self.git = git
        self.manifest = manifest
        self.perSource = perSource
        self.skippedDirs = skippedDirs
        self.suggestion = suggestion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        migrationId = try container.decode(String.self, forKey: .migrationId)
        state = try container.decode(String.self, forKey: .state)
        moveStrategy = try container.decodeIfPresent(String.self, forKey: .moveStrategy)
        ccDirRenamed = try container.decode(Bool.self, forKey: .ccDirRenamed)
        renamedDirs = try container.decodeIfPresent([String].self, forKey: .renamedDirs)
        totalFilesPatched = try container.decode(Int.self, forKey: .totalFilesPatched)
        totalOccurrences = try container.decode(Int.self, forKey: .totalOccurrences)
        sessionsUpdated = try container.decode(Int.self, forKey: .sessionsUpdated)
        aliasCreated = try container.decode(Bool.self, forKey: .aliasCreated)
        review = try container.decode(ReviewBlock.self, forKey: .review)
        git = try container.decodeIfPresent(GitStatus.self, forKey: .git)
        manifest = try container.decodeIfPresent([ManifestEntry].self, forKey: .manifest)
        perSource = try container.decodeIfPresent([PerSource].self, forKey: .perSource)
        skippedDirs = try container.decodeIfPresent([SkippedDir].self, forKey: .skippedDirs)
        suggestion = try container.decodeIfPresent(ArchiveSuggestion.self, forKey: .suggestion)
            ?? container.decodeIfPresent(ArchiveSuggestion.self, forKey: .archive)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(migrationId, forKey: .migrationId)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(moveStrategy, forKey: .moveStrategy)
        try container.encode(ccDirRenamed, forKey: .ccDirRenamed)
        try container.encodeIfPresent(renamedDirs, forKey: .renamedDirs)
        try container.encode(totalFilesPatched, forKey: .totalFilesPatched)
        try container.encode(totalOccurrences, forKey: .totalOccurrences)
        try container.encode(sessionsUpdated, forKey: .sessionsUpdated)
        try container.encode(aliasCreated, forKey: .aliasCreated)
        try container.encode(review, forKey: .review)
        try container.encodeIfPresent(git, forKey: .git)
        try container.encodeIfPresent(manifest, forKey: .manifest)
        try container.encodeIfPresent(perSource, forKey: .perSource)
        try container.encodeIfPresent(skippedDirs, forKey: .skippedDirs)
        try container.encodeIfPresent(suggestion, forKey: .suggestion)
    }

    struct GitStatus: Codable, Equatable, Sendable {
        let isGitRepo: Bool
        let dirty: Bool
        let untrackedOnly: Bool
        let porcelain: String
    }
}

// MARK: - Remote per-project session sync (Layer 2)

struct EngramServiceRemoteProjectSyncRequest: Codable, Sendable {
    let project: String
    /// Project working directory, used to scope sessions whose `project` column
    /// is cased inconsistently across adapters. Optional for pull (manifest
    /// entries carry no cwd); push uses it for the case-insensitive project OR
    /// cwd scope. The service uses whatever it is given.
    let cwd: String?
    /// Preview direction: "push" or "pull". Only read by the preview command;
    /// ignored by push/pull. Defaults to "push" when nil.
    let direction: String?

    init(project: String, cwd: String? = nil, direction: String? = nil) {
        self.project = project
        self.cwd = cwd
        self.direction = direction
    }
}

struct EngramServiceRemoteProjectSyncPreviewResponse: Codable, Sendable {
    struct SessionPreview: Codable, Sendable {
        let id: String
        let title: String
        let action: String
    }

    let enabled: Bool
    let direction: String
    let project: String
    let sessions: [SessionPreview]
    let toPush: Int
    let toPull: Int
    let skip: Int
}

struct EngramServiceRemotePushProjectResponse: Codable, Sendable {
    let enabled: Bool
    let uploaded: Int
    let skipped: Int
}

struct EngramServiceRemotePullProjectResponse: Codable, Sendable {
    let enabled: Bool
    let imported: Int
    let skipped: Int
}
