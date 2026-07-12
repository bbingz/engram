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
    /// `nextScanIntervalSeconds` is the adaptive S01 target (900/1800/3600), never a fixed 300.
    case running(total: Int, todayParents: Int, nextScanIntervalSeconds: Int? = nil)
    case degraded(message: String)
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case state
        case total
        case todayParents
        case message
        case nextScanIntervalSeconds
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
                todayParents: try container.decodeIfPresent(Int.self, forKey: .todayParents) ?? 0,
                nextScanIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .nextScanIntervalSeconds)
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
        case .running(let total, let todayParents, let nextScanIntervalSeconds):
            try container.encode("running", forKey: .state)
            try container.encode(total, forKey: .total)
            try container.encode(todayParents, forKey: .todayParents)
            try container.encodeIfPresent(nextScanIntervalSeconds, forKey: .nextScanIntervalSeconds)
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
    /// Optional machine-readable degrade code (e.g. `embeddingModelMismatch`).
    /// Additive / optional so older clients ignore the field.
    let warningCode: String?

    init(
        items: [Item],
        searchModes: [String]? = nil,
        warning: String? = nil,
        warningCode: String? = nil
    ) {
        self.items = items
        self.searchModes = searchModes
        self.warning = warning
        self.warningCode = warningCode
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

struct EngramServiceGenerateSummaryRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct EngramServiceGenerateSummaryResponse: Codable, Equatable, Sendable {
    let summary: String
}

struct EngramServiceGenerateProjectWorkTitlesRequest: Codable, Equatable, Sendable {
    let project: String
}

struct EngramServiceWorkItemTitle: Codable, Equatable, Sendable {
    let project: String
    let workKey: String
    let title: String
}

struct EngramServiceGenerateProjectWorkTitlesResponse: Codable, Equatable, Sendable {
    let titles: [EngramServiceWorkItemTitle]
}

struct EngramServiceSaveInsightRequest: Codable, Equatable, Sendable {
    let content: String
    let wing: String?
    let room: String?
    let importance: Double?
    let sourceSessionId: String?
    let actor: String?
    let type: String?

    init(
        content: String,
        wing: String? = nil,
        room: String? = nil,
        importance: Double? = nil,
        sourceSessionId: String? = nil,
        actor: String? = nil,
        type: String? = nil
    ) {
        self.content = content
        self.wing = wing
        self.room = room
        self.importance = importance
        self.sourceSessionId = sourceSessionId
        self.actor = actor
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case content
        case wing
        case room
        case importance
        case sourceSessionId = "source_session_id"
        case actor
        case type
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

/// Batch project move. Optional `operationId` enables cooperative cancel via
/// `cancelProjectMoveBatch` between operations (Wave 7C M05).
struct EngramServiceProjectMoveBatchRequest: Codable, Equatable, Sendable {
    let yaml: String
    let dryRun: Bool
    let force: Bool
    let actor: String?
    let operationId: String?

    init(yaml: String, dryRun: Bool, force: Bool, actor: String?, operationId: String? = nil) {
        self.yaml = yaml
        self.dryRun = dryRun
        self.force = force
        self.actor = actor
        self.operationId = operationId
    }

    enum CodingKeys: String, CodingKey {
        case yaml
        case dryRun = "dry_run"
        case force
        case actor
        case operationId = "operation_id"
    }
}

struct EngramServiceCancelProjectMoveBatchRequest: Codable, Equatable, Sendable {
    let operationId: String

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
    }
}

struct EngramServiceCancelProjectMoveBatchResponse: Codable, Equatable, Sendable {
    let accepted: Bool
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

struct EngramServiceInsightAccessRequest: Codable, Equatable, Sendable {
    let ids: [String]
}

struct EngramServiceHideEmptySessionsResponse: Codable, Equatable, Sendable {
    let hiddenCount: Int
}

/// Feature #2 slice B — per-source ingest control. `enabled == false` adds the
/// source to `disabledSources` (stops ingest + hides its sessions); `true`
/// removes it (resumes ingest on the next scan + unhides its sessions).
struct EngramServiceSetSourceEnabledRequest: Codable, Equatable, Sendable {
    let source: String
    let enabled: Bool
}

/// Current per-source ingest opt-out set, so the UI can render toggle state for
/// every catalog source (including those with zero indexed sessions).
struct EngramServiceDisabledSourcesResponse: Codable, Equatable, Sendable {
    let sources: [String]
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
    /// Wave 7C H03: true when cooperative cancel stopped mid-batch; partial counts remain valid.
    let cancelled: Bool?
    /// Symlink candidates not attempted after cancel (deterministic partial result).
    let remaining: Int?

    init(
        created: Int,
        skipped: Int,
        errors: [String],
        targetDir: String,
        projectNames: [String],
        truncated: Bool? = nil,
        cancelled: Bool? = nil,
        remaining: Int? = nil
    ) {
        self.created = created
        self.skipped = skipped
        self.errors = errors
        self.targetDir = targetDir
        self.projectNames = projectNames
        self.truncated = truncated
        self.cancelled = cancelled
        self.remaining = remaining
    }
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

struct EngramServiceDismissAmbiguousSuggestionRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct EngramServiceLinkResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let error: String?
}

/// Untyped, symmetric "related" association between two sessions (distinct from
/// parent/child). The pair is normalized a_id < b_id on write, so either order
/// resolves to the same row.
struct EngramServiceRelationRequest: Codable, Equatable, Sendable {
    let aId: String
    let bId: String
}

struct EngramServiceRelatedSessionsRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct EngramServiceRelatedSessionsResponse: Codable, Equatable, Sendable {
    let ids: [String]
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

// MARK: - Archive v2 service wire contract

enum EngramServiceArchiveV2WireError: Error, Equatable, Sendable {
    case invalidField(String)
}

private enum EngramServiceArchiveV2WireValidation {
    static let replicaIDs = ["hq", "m1"]
    static let transcriptRoles: Set<String> = ["user", "assistant"]
    static let maximumSessionIDBytes = 512
    static let maximumTranscriptPage = 100_000
    static let maximumTranscriptPageSize = 500
    static let maximumTranscriptTimestampBytes = 128

    static func require(_ condition: @autoclosure () -> Bool, field: String) throws {
        guard condition() else {
            throw EngramServiceArchiveV2WireError.invalidField(field)
        }
    }

    static func validateReplicaID(_ value: String, field: String = "replicaID") throws {
        try require(replicaIDs.contains(value), field: field)
    }

    static func validateNonNegative(_ value: Int, field: String) throws {
        try require(value >= 0, field: field)
    }

    static func validateSymbol(_ value: String?, field: String) throws {
        guard let value else { return }
        let bytes = value.utf8
        try require(!bytes.isEmpty && bytes.count <= 64, field: field)
        try require(
            bytes.allSatisfy { byte in
                byte == 95 || (48...57).contains(byte) || (97...122).contains(byte)
            },
            field: field
        )
    }

    static func validateDigest(_ value: String, field: String) throws {
        let bytes = value.utf8
        try require(bytes.count == 64, field: field)
        try require(
            bytes.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            },
            field: field
        )
    }

    static func validateTimestamp(_ value: String, field: String) throws {
        try require(value.utf8.count == 24, field: field)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value) else {
            throw EngramServiceArchiveV2WireError.invalidField(field)
        }
        try require(formatter.string(from: date) == value, field: field)
    }

    static func validateTranscriptSessionID(_ value: String) throws {
        try require(
            !value.isEmpty
                && value.utf8.count <= maximumSessionIDBytes
                && !value.utf8.contains(0),
            field: "sessionId"
        )
    }

    static func validateTranscriptPage(_ value: Int, field: String) throws {
        try require((1 ... maximumTranscriptPage).contains(value), field: field)
    }

    static func validateTranscriptPageSize(_ value: Int) throws {
        try require(
            (1 ... maximumTranscriptPageSize).contains(value),
            field: "pageSize"
        )
    }

    static func validateTranscriptRoles(_ roles: [String]?) throws {
        guard let roles else { return }
        try require(!roles.isEmpty && roles.count <= transcriptRoles.count, field: "roles")
        try require(Set(roles).count == roles.count, field: "roles")
        try require(roles.allSatisfy(transcriptRoles.contains), field: "roles")
    }

    static func validateTranscriptTimestamp(_ value: String?) throws {
        guard let value else { return }
        try require(
            !value.isEmpty
                && value.utf8.count <= maximumTranscriptTimestampBytes
                && !value.utf8.contains(0),
            field: "timestamp"
        )
    }
}

struct EngramServiceArchiveReadSessionPageRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let page: Int
    let pageSize: Int
    let roles: [String]?

    init(sessionId: String, page: Int, pageSize: Int, roles: [String]?) throws {
        try EngramServiceArchiveV2WireValidation.validateTranscriptSessionID(sessionId)
        try EngramServiceArchiveV2WireValidation.validateTranscriptPage(page, field: "page")
        try EngramServiceArchiveV2WireValidation.validateTranscriptPageSize(pageSize)
        try EngramServiceArchiveV2WireValidation.validateTranscriptRoles(roles)
        self.sessionId = sessionId
        self.page = page
        self.pageSize = pageSize
        self.roles = roles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: container.decode(String.self, forKey: .sessionId),
            page: container.decode(Int.self, forKey: .page),
            pageSize: container.decode(Int.self, forKey: .pageSize),
            roles: container.decodeIfPresent([String].self, forKey: .roles)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case page
        case pageSize
        case roles
    }
}

struct EngramServiceArchiveTranscriptMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
    let timestamp: String?

    init(role: String, content: String, timestamp: String?) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(String.self, forKey: .role)
        let content = try container.decode(String.self, forKey: .content)
        let timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        try EngramServiceArchiveV2WireValidation.require(
            EngramServiceArchiveV2WireValidation.transcriptRoles.contains(role),
            field: "role"
        )
        try EngramServiceArchiveV2WireValidation.validateTranscriptTimestamp(timestamp)
        self.init(role: role, content: content, timestamp: timestamp)
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case timestamp
    }
}

struct EngramServiceArchiveReadSessionPageResponse: Codable, Equatable, Sendable {
    let messages: [EngramServiceArchiveTranscriptMessage]
    let totalPages: Int
    let currentPage: Int
    let totalKnownComplete: Bool
    let truncatedAt: Int?
    let responseBudgetTruncated: Bool

    init(
        messages: [EngramServiceArchiveTranscriptMessage],
        totalPages: Int,
        currentPage: Int,
        totalKnownComplete: Bool,
        truncatedAt: Int?,
        responseBudgetTruncated: Bool
    ) throws {
        try EngramServiceArchiveV2WireValidation.require(
            messages.count <= EngramServiceArchiveV2WireValidation.maximumTranscriptPageSize,
            field: "messages"
        )
        for message in messages {
            try EngramServiceArchiveV2WireValidation.require(
                EngramServiceArchiveV2WireValidation.transcriptRoles.contains(message.role),
                field: "role"
            )
            try EngramServiceArchiveV2WireValidation.validateTranscriptTimestamp(message.timestamp)
        }
        try EngramServiceArchiveV2WireValidation.validateTranscriptPage(
            totalPages,
            field: "totalPages"
        )
        try EngramServiceArchiveV2WireValidation.validateTranscriptPage(
            currentPage,
            field: "currentPage"
        )
        if let truncatedAt {
            try EngramServiceArchiveV2WireValidation.validateNonNegative(
                truncatedAt,
                field: "truncatedAt"
            )
        }
        self.messages = messages
        self.totalPages = totalPages
        self.currentPage = currentPage
        self.totalKnownComplete = totalKnownComplete
        self.truncatedAt = truncatedAt
        self.responseBudgetTruncated = responseBudgetTruncated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            messages: container.decode(
                [EngramServiceArchiveTranscriptMessage].self,
                forKey: .messages
            ),
            totalPages: container.decode(Int.self, forKey: .totalPages),
            currentPage: container.decode(Int.self, forKey: .currentPage),
            totalKnownComplete: container.decode(Bool.self, forKey: .totalKnownComplete),
            truncatedAt: container.decodeIfPresent(Int.self, forKey: .truncatedAt),
            responseBudgetTruncated: container.decode(
                Bool.self,
                forKey: .responseBudgetTruncated
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case messages
        case totalPages
        case currentPage
        case totalKnownComplete
        case truncatedAt
        case responseBudgetTruncated
    }
}

struct EngramServiceArchiveV2RetryRequest: Codable, Equatable, Sendable {
    let replicaID: String?

    init(replicaID: String?) throws {
        if let replicaID {
            try EngramServiceArchiveV2WireValidation.validateReplicaID(replicaID)
        }
        self.replicaID = replicaID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(replicaID: container.decodeIfPresent(String.self, forKey: .replicaID))
    }

    private enum CodingKeys: String, CodingKey {
        case replicaID
    }
}

struct EngramServiceArchiveReclamationStatusResponse: Codable, Equatable, Sendable {
    let enabled: Bool
    let hotWindowDays: Int
    let configurationError: String?
    let recoveryLeaseCurrent: Bool
    let cycleRunning: Bool
    let lastError: String?
}

struct EngramServiceArchiveReclamationPreviewResponse: Codable, Equatable, Sendable {
    let eligibleCount: Int
    let estimatedSourceBytes: Int64
    let blockedCounts: [String: Int]
}

struct EngramServiceArchiveReclamationUpdateSettingsRequest: Codable, Equatable, Sendable {
    let enabled: Bool
    let hotWindowDays: Int
}

struct EngramServiceArchiveReclamationRunResponse: Codable, Equatable, Sendable {
    let accepted: Bool
    let coalesced: Bool
    let sourceFilesReclaimed: Int
    let casObjectsEvicted: Int
    let releasedBytes: Int64
    let error: String?
}

struct EngramServiceArchiveV2RecoveryDrillRequest: Codable, Equatable, Sendable {
    let replicaID: String
}

struct EngramServiceArchiveV2RecoveryDrillResponse: Codable, Equatable, Sendable {
    let replicaID: String
    let manifestSHA256: String
    let verifiedAt: String
    let verifiedBytes: Int64
}

struct EngramServiceArchiveV2StoreTokenRequest: Codable, Equatable, Sendable {
    let replicaID: String
    let token: String
}

struct EngramServiceArchiveV2StoreTokenResponse: Codable, Equatable, Sendable {
    let replicaID: String
    let stored: Bool
    let pairReady: Bool
    let serviceRestartRequired: Bool
}

struct EngramServiceArchiveV2RemoteRecoveryProbeRequest: Codable, Equatable, Sendable {
    let sessionId: String

    init(sessionId: String) throws {
        try EngramServiceArchiveV2WireValidation.validateTranscriptSessionID(sessionId)
        self.sessionId = sessionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sessionId: container.decode(String.self, forKey: .sessionId))
    }

    private enum CodingKeys: String, CodingKey { case sessionId }
}

struct EngramServiceArchiveV2RemoteRecoveryProbeResponse: Codable, Equatable, Sendable {
    let tier: String
    let receiptSHA256: String
    let manifestSHA256: String
    let wholeSourceSHA256: String

    init(
        tier: String,
        receiptSHA256: String,
        manifestSHA256: String,
        wholeSourceSHA256: String
    ) throws {
        try EngramServiceArchiveV2WireValidation.require(
            tier == "hq" || tier == "m1",
            field: "tier"
        )
        try EngramServiceArchiveV2WireValidation.validateDigest(
            receiptSHA256,
            field: "receiptSHA256"
        )
        try EngramServiceArchiveV2WireValidation.validateDigest(
            manifestSHA256,
            field: "manifestSHA256"
        )
        try EngramServiceArchiveV2WireValidation.validateDigest(
            wholeSourceSHA256,
            field: "wholeSourceSHA256"
        )
        self.tier = tier
        self.receiptSHA256 = receiptSHA256
        self.manifestSHA256 = manifestSHA256
        self.wholeSourceSHA256 = wholeSourceSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tier: container.decode(String.self, forKey: .tier),
            receiptSHA256: container.decode(String.self, forKey: .receiptSHA256),
            manifestSHA256: container.decode(String.self, forKey: .manifestSHA256),
            wholeSourceSHA256: container.decode(String.self, forKey: .wholeSourceSHA256)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case tier
        case receiptSHA256
        case manifestSHA256
        case wholeSourceSHA256
    }
}

struct EngramServiceArchiveV2ReplicaStatus: Codable, Equatable, Sendable {
    let replicaID: String
    let queuedCount: Int
    let retryingCount: Int
    let quarantinedCount: Int
    let verifiedCount: Int

    init(
        replicaID: String,
        queuedCount: Int,
        retryingCount: Int,
        quarantinedCount: Int,
        verifiedCount: Int
    ) throws {
        try EngramServiceArchiveV2WireValidation.validateReplicaID(replicaID)
        try EngramServiceArchiveV2WireValidation.validateNonNegative(
            queuedCount,
            field: "queuedCount"
        )
        try EngramServiceArchiveV2WireValidation.validateNonNegative(
            retryingCount,
            field: "retryingCount"
        )
        try EngramServiceArchiveV2WireValidation.validateNonNegative(
            quarantinedCount,
            field: "quarantinedCount"
        )
        try EngramServiceArchiveV2WireValidation.validateNonNegative(
            verifiedCount,
            field: "verifiedCount"
        )
        self.replicaID = replicaID
        self.queuedCount = queuedCount
        self.retryingCount = retryingCount
        self.quarantinedCount = quarantinedCount
        self.verifiedCount = verifiedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            replicaID: container.decode(String.self, forKey: .replicaID),
            queuedCount: container.decode(Int.self, forKey: .queuedCount),
            retryingCount: container.decode(Int.self, forKey: .retryingCount),
            quarantinedCount: container.decode(Int.self, forKey: .quarantinedCount),
            verifiedCount: container.decode(Int.self, forKey: .verifiedCount)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case replicaID
        case queuedCount
        case retryingCount
        case quarantinedCount
        case verifiedCount
    }
}

struct EngramServiceArchiveV2LatestReceipt: Codable, Equatable, Sendable {
    let replicaID: String
    let manifestSHA256: String
    let receiptSHA256: String
    let verifiedAt: String

    init(
        replicaID: String,
        manifestSHA256: String,
        receiptSHA256: String,
        verifiedAt: String
    ) throws {
        try EngramServiceArchiveV2WireValidation.validateReplicaID(replicaID)
        try EngramServiceArchiveV2WireValidation.validateDigest(
            manifestSHA256,
            field: "manifestSHA256"
        )
        try EngramServiceArchiveV2WireValidation.validateDigest(
            receiptSHA256,
            field: "receiptSHA256"
        )
        try EngramServiceArchiveV2WireValidation.validateTimestamp(
            verifiedAt,
            field: "verifiedAt"
        )
        self.replicaID = replicaID
        self.manifestSHA256 = manifestSHA256
        self.receiptSHA256 = receiptSHA256
        self.verifiedAt = verifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            replicaID: container.decode(String.self, forKey: .replicaID),
            manifestSHA256: container.decode(String.self, forKey: .manifestSHA256),
            receiptSHA256: container.decode(String.self, forKey: .receiptSHA256),
            verifiedAt: container.decode(String.self, forKey: .verifiedAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case replicaID
        case manifestSHA256
        case receiptSHA256
        case verifiedAt
    }
}

struct EngramServiceArchiveV2StatusResponse: Codable, Equatable, Sendable {
    let enabled: Bool
    let localCaptureEnabled: Bool
    let remoteReplicationEnabled: Bool
    let configurationError: String?
    let capturedCount: Int
    let boundCount: Int
    let unboundCount: Int
    let remotePolicyUnknownCount: Int
    let remotePolicyEligibleCount: Int
    let remotePolicyExcludedCount: Int
    let unsupportedLocatorCount: Int
    let unsafeLocatorCount: Int
    let replicas: [EngramServiceArchiveV2ReplicaStatus]
    let singleReplicaVerifiedCount: Int
    let dualReplicaVerifiedCount: Int
    let latestReceipts: [EngramServiceArchiveV2LatestReceipt]
    let lastCaptureError: String?
    let lastReplicationError: String?
    let cycleRunning: Bool
    let cycleCoalesced: Bool

    init(
        enabled: Bool,
        localCaptureEnabled: Bool,
        remoteReplicationEnabled: Bool,
        configurationError: String?,
        capturedCount: Int,
        boundCount: Int,
        unboundCount: Int,
        remotePolicyUnknownCount: Int,
        remotePolicyEligibleCount: Int,
        remotePolicyExcludedCount: Int,
        unsupportedLocatorCount: Int,
        unsafeLocatorCount: Int,
        replicas: [EngramServiceArchiveV2ReplicaStatus],
        singleReplicaVerifiedCount: Int,
        dualReplicaVerifiedCount: Int,
        latestReceipts: [EngramServiceArchiveV2LatestReceipt],
        lastCaptureError: String?,
        lastReplicationError: String?,
        cycleRunning: Bool,
        cycleCoalesced: Bool
    ) throws {
        if !enabled {
            try EngramServiceArchiveV2WireValidation.require(
                !localCaptureEnabled && !remoteReplicationEnabled,
                field: "enabled"
            )
        }
        if remoteReplicationEnabled {
            try EngramServiceArchiveV2WireValidation.require(
                enabled && localCaptureEnabled && configurationError == nil,
                field: "remoteReplicationEnabled"
            )
        }
        try EngramServiceArchiveV2WireValidation.validateSymbol(
            configurationError,
            field: "configurationError"
        )
        try EngramServiceArchiveV2WireValidation.validateSymbol(
            lastCaptureError,
            field: "lastCaptureError"
        )
        try EngramServiceArchiveV2WireValidation.validateSymbol(
            lastReplicationError,
            field: "lastReplicationError"
        )

        let counts = [
            ("capturedCount", capturedCount),
            ("boundCount", boundCount),
            ("unboundCount", unboundCount),
            ("remotePolicyUnknownCount", remotePolicyUnknownCount),
            ("remotePolicyEligibleCount", remotePolicyEligibleCount),
            ("remotePolicyExcludedCount", remotePolicyExcludedCount),
            ("unsupportedLocatorCount", unsupportedLocatorCount),
            ("unsafeLocatorCount", unsafeLocatorCount),
            ("singleReplicaVerifiedCount", singleReplicaVerifiedCount),
            ("dualReplicaVerifiedCount", dualReplicaVerifiedCount),
        ]
        for (field, value) in counts {
            try EngramServiceArchiveV2WireValidation.validateNonNegative(value, field: field)
        }

        try EngramServiceArchiveV2WireValidation.require(
            replicas.map(\.replicaID) == EngramServiceArchiveV2WireValidation.replicaIDs,
            field: "replicas"
        )
        let receiptIDs = latestReceipts.map(\.replicaID)
        try EngramServiceArchiveV2WireValidation.require(
            receiptIDs == [] || receiptIDs == ["hq"] || receiptIDs == ["m1"]
                || receiptIDs == EngramServiceArchiveV2WireValidation.replicaIDs,
            field: "latestReceipts"
        )

        self.enabled = enabled
        self.localCaptureEnabled = localCaptureEnabled
        self.remoteReplicationEnabled = remoteReplicationEnabled
        self.configurationError = configurationError
        self.capturedCount = capturedCount
        self.boundCount = boundCount
        self.unboundCount = unboundCount
        self.remotePolicyUnknownCount = remotePolicyUnknownCount
        self.remotePolicyEligibleCount = remotePolicyEligibleCount
        self.remotePolicyExcludedCount = remotePolicyExcludedCount
        self.unsupportedLocatorCount = unsupportedLocatorCount
        self.unsafeLocatorCount = unsafeLocatorCount
        self.replicas = replicas
        self.singleReplicaVerifiedCount = singleReplicaVerifiedCount
        self.dualReplicaVerifiedCount = dualReplicaVerifiedCount
        self.latestReceipts = latestReceipts
        self.lastCaptureError = lastCaptureError
        self.lastReplicationError = lastReplicationError
        self.cycleRunning = cycleRunning
        self.cycleCoalesced = cycleCoalesced
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            enabled: container.decode(Bool.self, forKey: .enabled),
            localCaptureEnabled: container.decode(Bool.self, forKey: .localCaptureEnabled),
            remoteReplicationEnabled: container.decode(Bool.self, forKey: .remoteReplicationEnabled),
            configurationError: container.decodeIfPresent(String.self, forKey: .configurationError),
            capturedCount: container.decode(Int.self, forKey: .capturedCount),
            boundCount: container.decode(Int.self, forKey: .boundCount),
            unboundCount: container.decode(Int.self, forKey: .unboundCount),
            remotePolicyUnknownCount: container.decode(Int.self, forKey: .remotePolicyUnknownCount),
            remotePolicyEligibleCount: container.decode(Int.self, forKey: .remotePolicyEligibleCount),
            remotePolicyExcludedCount: container.decode(Int.self, forKey: .remotePolicyExcludedCount),
            unsupportedLocatorCount: container.decode(Int.self, forKey: .unsupportedLocatorCount),
            unsafeLocatorCount: container.decode(Int.self, forKey: .unsafeLocatorCount),
            replicas: container.decode([EngramServiceArchiveV2ReplicaStatus].self, forKey: .replicas),
            singleReplicaVerifiedCount: container.decode(Int.self, forKey: .singleReplicaVerifiedCount),
            dualReplicaVerifiedCount: container.decode(Int.self, forKey: .dualReplicaVerifiedCount),
            latestReceipts: container.decode([EngramServiceArchiveV2LatestReceipt].self, forKey: .latestReceipts),
            lastCaptureError: container.decodeIfPresent(String.self, forKey: .lastCaptureError),
            lastReplicationError: container.decodeIfPresent(String.self, forKey: .lastReplicationError),
            cycleRunning: container.decode(Bool.self, forKey: .cycleRunning),
            cycleCoalesced: container.decode(Bool.self, forKey: .cycleCoalesced)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case localCaptureEnabled
        case remoteReplicationEnabled
        case configurationError
        case capturedCount
        case boundCount
        case unboundCount
        case remotePolicyUnknownCount
        case remotePolicyEligibleCount
        case remotePolicyExcludedCount
        case unsupportedLocatorCount
        case unsafeLocatorCount
        case replicas
        case singleReplicaVerifiedCount
        case dualReplicaVerifiedCount
        case latestReceipts
        case lastCaptureError
        case lastReplicationError
        case cycleRunning
        case cycleCoalesced
    }
}

struct EngramServiceArchiveV2RetryResponse: Codable, Equatable, Sendable {
    let accepted: Bool
    let resetRows: Int
    let error: String?

    init(accepted: Bool, resetRows: Int, error: String?) throws {
        try EngramServiceArchiveV2WireValidation.validateNonNegative(
            resetRows,
            field: "resetRows"
        )
        try EngramServiceArchiveV2WireValidation.validateSymbol(error, field: "error")
        if accepted {
            try EngramServiceArchiveV2WireValidation.require(error == nil, field: "error")
        } else {
            try EngramServiceArchiveV2WireValidation.require(
                resetRows == 0 && error != nil,
                field: "accepted"
            )
        }
        self.accepted = accepted
        self.resetRows = resetRows
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accepted: container.decode(Bool.self, forKey: .accepted),
            resetRows: container.decode(Int.self, forKey: .resetRows),
            error: container.decodeIfPresent(String.self, forKey: .error)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case accepted
        case resetRows
        case error
    }
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
    /// Ephemeral per-provider embedding circuit-breaker counters (process memory
    /// only; resets on restart). Empty when no embed traffic has run.
    let embeddingBreakers: [EmbeddingBreakerTelemetry]
    /// Wave 7C S01: adaptive schedule visibility for smoke/gates (not fixed 5m).
    let nextScanIntervalSeconds: Int?
    let scheduleTargetIntervalSeconds: Int?
    let scheduleMinIntervalSeconds: Int?
    let scheduleConsecutiveIdleScans: Int?
    let scheduleBackend: String?

    init(
        lastScanDurationMs: Double?,
        lastScanIndexed: Int,
        lastScanTotal: Int,
        scanCount: Int,
        lastScanAt: String?,
        commands: [ServiceCommandLatency],
        spans: [ServiceSpan],
        embeddingBreakers: [EmbeddingBreakerTelemetry] = [],
        nextScanIntervalSeconds: Int? = nil,
        scheduleTargetIntervalSeconds: Int? = nil,
        scheduleMinIntervalSeconds: Int? = nil,
        scheduleConsecutiveIdleScans: Int? = nil,
        scheduleBackend: String? = nil
    ) {
        self.lastScanDurationMs = lastScanDurationMs
        self.lastScanIndexed = lastScanIndexed
        self.lastScanTotal = lastScanTotal
        self.scanCount = scanCount
        self.lastScanAt = lastScanAt
        self.commands = commands
        self.spans = spans
        self.embeddingBreakers = embeddingBreakers
        self.nextScanIntervalSeconds = nextScanIntervalSeconds
        self.scheduleTargetIntervalSeconds = scheduleTargetIntervalSeconds
        self.scheduleMinIntervalSeconds = scheduleMinIntervalSeconds
        self.scheduleConsecutiveIdleScans = scheduleConsecutiveIdleScans
        self.scheduleBackend = scheduleBackend
    }
}

/// In-memory embedding circuit-breaker diagnostics (not persisted; no
/// `ai_audit_log`). Mirrors `EmbeddingCircuitBreaker.ProviderSnapshot`.
struct EmbeddingBreakerTelemetry: Codable, Equatable, Identifiable, Sendable {
    var id: String { providerKey }
    let providerKey: String
    let state: String
    let consecutiveFailures: Int
    let transportFailures: Int
    let successes: Int
    let opens: Int
    let rejections: Int
    let halfOpenProbes: Int
    let cooldownRemainingMs: Double?
}

/// One SANITIZED service log line surfaced through the `serviceLogs` read
/// command. The `message` has already passed through `ServiceLogSanitizer`, so
/// it carries no raw paths/ids/emails/error tails. Mirrors `ServiceSpan` as a
/// flat Codable DTO stored directly in the in-process ring buffer.
struct ServiceLogLineDTO: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(timestamp)#\(category)" }
    let timestamp: String
    let level: String
    let category: String
    let message: String
}

struct ServiceLogSnapshot: Codable, Equatable, Sendable {
    let lines: [ServiceLogLineDTO]
}

struct EngramServiceServiceLogsRequest: Codable, Equatable, Sendable {
    let level: String?
    let category: String?
    let limit: Int?
}

struct EngramServiceProjectMoveRequest: Codable, Equatable, Sendable {
    let src: String
    let dst: String
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
    let actor: String?
    /// Stable client operation id for cancel/reconnect/idempotence (Wave 8 long-ops).
    let operationId: String?

    init(
        src: String,
        dst: String,
        dryRun: Bool,
        force: Bool,
        auditNote: String?,
        actor: String?,
        operationId: String? = nil
    ) {
        self.src = src
        self.dst = dst
        self.dryRun = dryRun
        self.force = force
        self.auditNote = auditNote
        self.actor = actor
        self.operationId = operationId
    }

    enum CodingKeys: String, CodingKey {
        case src, dst, force, actor
        case dryRun = "dry_run"
        case auditNote = "audit_note"
        case operationId = "operation_id"
    }
}

struct EngramServiceProjectArchiveRequest: Codable, Equatable, Sendable {
    let src: String
    let archiveTo: String?
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
    let actor: String?
    /// Stable client operation id for cancel/reconnect/idempotence (Wave 8 long-ops).
    let operationId: String?

    init(
        src: String,
        archiveTo: String?,
        dryRun: Bool,
        force: Bool,
        auditNote: String?,
        actor: String?,
        operationId: String? = nil
    ) {
        self.src = src
        self.archiveTo = archiveTo
        self.dryRun = dryRun
        self.force = force
        self.auditNote = auditNote
        self.actor = actor
        self.operationId = operationId
    }

    enum CodingKeys: String, CodingKey {
        case src, force, actor
        case archiveTo = "archive_to"
        case dryRun = "dry_run"
        case auditNote = "audit_note"
        case operationId = "operation_id"
    }
}

struct EngramServiceProjectUndoRequest: Codable, Equatable, Sendable {
    let migrationId: String
    let force: Bool
    let actor: String?
    /// Stable client operation id for cancel/reconnect/idempotence (Wave 8 long-ops).
    let operationId: String?

    init(
        migrationId: String,
        force: Bool,
        actor: String?,
        operationId: String? = nil
    ) {
        self.migrationId = migrationId
        self.force = force
        self.actor = actor
        self.operationId = operationId
    }

    enum CodingKeys: String, CodingKey {
        case force, actor
        case migrationId = "migration_id"
        case operationId = "operation_id"
    }
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
