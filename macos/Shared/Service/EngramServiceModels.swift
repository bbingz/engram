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

    init(
        requestId: String = UUID().uuidString,
        kind: String = "request",
        command: String,
        payload: Data? = nil
    ) {
        self.requestId = requestId
        self.kind = kind
        self.command = command
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case kind
        case command
        case payload
    }
}

enum EngramServiceResponseEnvelope: Codable, Equatable, Sendable {
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
            linkSource: String? = nil
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
}

struct EngramServiceHookInfo: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(scope)/\(event)/\(command)" }
    let event: String
    let command: String
    let scope: String
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
    let error: String?
    let hint: String?

    init(
        tool: String? = nil,
        command: String? = nil,
        args: [String] = [],
        cwd: String? = nil,
        error: String? = nil,
        hint: String? = nil
    ) {
        self.tool = tool
        self.command = command
        self.args = args
        self.cwd = cwd
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
