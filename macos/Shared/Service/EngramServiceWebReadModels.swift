import Foundation

enum EngramServiceWebReadLimits {
    static let projection = "redacted-normalized-message-json-v1"
    static let redactionRevision = "transcript-redaction-v2"
    static let maximumFrameBytes = 256 * 1024
    static let maximumPageEnvelopeBytes = maximumFrameBytes - 1024
    static let maximumSessionIDBytes = 4096
    static let maximumCursorBytes = 1024
    static let maximumFragments = 100
    static let maximumMessages = 100_000
    static let maximumFilterListCount = 32
    static let maximumTimelineLimit = 500
    static let defaultTimelineLimit = 100
    static let defaultChildrenLimit = 20
    static let maximumTimelinePreviewCharacters = 100
    static let maximumSessionSummaryBytes = 50_000
}

enum EngramServiceWebReadError: Error, Equatable {
    case invalidField(String)
    case invalidCursor
    case staleCursor
    case responseTooLarge
}

enum EngramServiceWebMessageRole: String, Codable, CaseIterable, Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
}

/// Foundation-only projection of the complete normalized message. This is not
/// a representation of the original log bytes or an HTML/Markdown payload.
struct EngramServiceWebNormalizedMessage: Codable, Equatable, Sendable {
    let role: EngramServiceWebMessageRole
    let content: String
    let timestamp: String?
    let toolCalls: [EngramServiceWebToolCall]?
    let usage: EngramServiceWebTokenUsage?
}

struct EngramServiceWebToolCall: Codable, Equatable, Sendable {
    let name: String
    let input: String?
    let output: String?
}

struct EngramServiceWebTokenUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
}

struct EngramServiceWebMessagesRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let generation: String
    let roles: [EngramServiceWebMessageRole]
    let cursor: String?
    let maxFragments: Int

    init(
        sessionId: String,
        generation: String,
        roles: [EngramServiceWebMessageRole] = EngramServiceWebMessageRole.allCases,
        cursor: String? = nil,
        maxFragments: Int = 50
    ) throws {
        try EngramServiceWebReadValidation.identity(sessionId: sessionId, generation: generation)
        try EngramServiceWebReadValidation.cursor(cursor)
        guard (1...EngramServiceWebReadLimits.maximumFragments).contains(maxFragments) else {
            throw EngramServiceWebReadError.invalidField("maxFragments")
        }
        self.sessionId = sessionId
        self.generation = generation
        self.roles = try EngramServiceWebReadValidation.roles(roles)
        self.cursor = cursor
        self.maxFragments = maxFragments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: c.decode(String.self, forKey: .sessionId),
            generation: c.decode(String.self, forKey: .generation),
            roles: c.decode([EngramServiceWebMessageRole].self, forKey: .roles),
            cursor: c.decodeIfPresent(String.self, forKey: .cursor),
            maxFragments: c.decode(Int.self, forKey: .maxFragments)
        )
    }
}

/// The UTF-8 offsets address canonical JSON, not the original `content` field.
/// Reassemble the complete payload, verify its SHA, then decode JSON once.
struct EngramServiceWebMessageFragment: Codable, Equatable, Sendable {
    let messageOrdinal: Int
    let role: EngramServiceWebMessageRole
    let payloadSHA256: String
    let utf8Offset: Int
    let payloadFragment: String
    let isLastFragment: Bool

    init(
        messageOrdinal: Int,
        role: EngramServiceWebMessageRole,
        payloadSHA256: String,
        utf8Offset: Int,
        payloadFragment: String,
        isLastFragment: Bool
    ) throws {
        guard (0..<EngramServiceWebReadLimits.maximumMessages).contains(messageOrdinal),
              utf8Offset >= 0,
              !payloadFragment.isEmpty,
              payloadFragment.utf8.count <= EngramServiceWebReadLimits.maximumFrameBytes,
              !utf8Offset.addingReportingOverflow(payloadFragment.utf8.count).overflow,
              EngramServiceWebReadValidation.isSHA256(payloadSHA256) else {
            throw EngramServiceWebReadError.invalidField("fragment")
        }
        self.messageOrdinal = messageOrdinal
        self.role = role
        self.payloadSHA256 = payloadSHA256
        self.utf8Offset = utf8Offset
        self.payloadFragment = payloadFragment
        self.isLastFragment = isLastFragment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            messageOrdinal: c.decode(Int.self, forKey: .messageOrdinal),
            role: c.decode(EngramServiceWebMessageRole.self, forKey: .role),
            payloadSHA256: c.decode(String.self, forKey: .payloadSHA256),
            utf8Offset: c.decode(Int.self, forKey: .utf8Offset),
            payloadFragment: c.decode(String.self, forKey: .payloadFragment),
            isLastFragment: c.decode(Bool.self, forKey: .isLastFragment)
        )
    }
}

struct EngramServiceWebMessagesResponse: Codable, Equatable, Sendable {
    let sessionId: String
    let generation: String
    let projection: String
    let redactionRevision: String
    let roles: [EngramServiceWebMessageRole]
    let fragments: [EngramServiceWebMessageFragment]
    let nextCursor: String?
    let totalKnownComplete: Bool
    let truncatedAt: Int?
    let parseFailure: String?

    /// EOF alone is not evidence that the authoritative source was complete.
    var isComplete: Bool {
        nextCursor == nil && totalKnownComplete && truncatedAt == nil && parseFailure == nil
    }

    init(
        sessionId: String,
        generation: String,
        projection: String = EngramServiceWebReadLimits.projection,
        redactionRevision: String = EngramServiceWebReadLimits.redactionRevision,
        roles: [EngramServiceWebMessageRole],
        fragments: [EngramServiceWebMessageFragment],
        nextCursor: String?,
        totalKnownComplete: Bool,
        truncatedAt: Int?,
        parseFailure: String?
    ) throws {
        try EngramServiceWebReadValidation.identity(sessionId: sessionId, generation: generation)
        try EngramServiceWebReadValidation.cursor(nextCursor)
        let canonicalRoles = try EngramServiceWebReadValidation.roles(roles)
        guard projection == EngramServiceWebReadLimits.projection,
              redactionRevision == EngramServiceWebReadLimits.redactionRevision,
              fragments.count <= EngramServiceWebReadLimits.maximumFragments,
              fragments.allSatisfy({ canonicalRoles.contains($0.role) }),
              nextCursor == nil || !fragments.isEmpty,
              nextCursor != nil || fragments.last?.isLastFragment != false,
              truncatedAt.map({ $0 >= 0 }) ?? true,
              parseFailure.map(EngramServiceWebReadValidation.parseFailures.contains) ?? true,
              !totalKnownComplete || (truncatedAt == nil && parseFailure == nil) else {
            throw EngramServiceWebReadError.invalidField("response")
        }
        self.sessionId = sessionId
        self.generation = generation
        self.projection = projection
        self.redactionRevision = redactionRevision
        self.roles = canonicalRoles
        self.fragments = fragments
        self.nextCursor = nextCursor
        self.totalKnownComplete = totalKnownComplete
        self.truncatedAt = truncatedAt
        self.parseFailure = parseFailure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: c.decode(String.self, forKey: .sessionId),
            generation: c.decode(String.self, forKey: .generation),
            projection: c.decode(String.self, forKey: .projection),
            redactionRevision: c.decode(String.self, forKey: .redactionRevision),
            roles: c.decode([EngramServiceWebMessageRole].self, forKey: .roles),
            fragments: c.decode([EngramServiceWebMessageFragment].self, forKey: .fragments),
            nextCursor: c.decodeIfPresent(String.self, forKey: .nextCursor),
            totalKnownComplete: c.decode(Bool.self, forKey: .totalKnownComplete),
            truncatedAt: c.decodeIfPresent(Int.self, forKey: .truncatedAt),
            parseFailure: c.decodeIfPresent(String.self, forKey: .parseFailure)
        )
    }
}

private enum EngramServiceWebReadValidation {
    // Foundation-only mirror of ParserFailure; do not send arbitrary error text.
    static let parseFailures: Set<String> = [
        "fileMissing", "fileTooLarge", "invalidUtf8", "truncatedJSON", "truncatedJSONL",
        "malformedJSON", "malformedToolCall", "deeplyNestedRecord", "messageLimitExceeded",
        "lineTooLarge", "fileModifiedDuringParse", "sqliteUnreadable", "grpcUnavailable",
        "unsupportedVirtualLocator", "noVisibleMessages",
    ]

    static func identity(sessionId: String, generation: String) throws {
        guard !sessionId.isEmpty,
              sessionId.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes,
              !sessionId.utf8.contains(0), isSHA256(generation) else {
            throw EngramServiceWebReadError.invalidField("identity")
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func roles(_ values: [EngramServiceWebMessageRole]) throws -> [EngramServiceWebMessageRole] {
        guard !values.isEmpty, values.count <= EngramServiceWebMessageRole.allCases.count,
              Set(values.map(\.rawValue)).count == values.count else {
            throw EngramServiceWebReadError.invalidField("roles")
        }
        return values.sorted { $0.rawValue < $1.rawValue }
    }

    static func cursor(_ value: String?) throws {
        if let value, value.isEmpty || value.utf8.count > EngramServiceWebReadLimits.maximumCursorBytes {
            throw EngramServiceWebReadError.invalidField("cursor")
        }
    }
}


// Metadata contracts are separate from message-fragment continuations.
// Unknown observations stay nil. These values describe observations, not read
// authority; the service must freshly prove every page and transcript binding.
enum EngramServiceWebAvailability: String, Codable, Equatable, Sendable {
    case unknown, unavailable, available
}

enum EngramServiceWebAIState: String, Codable, Equatable, Sendable {
    case notConfigured, backoff, idle, running, failed
}

enum EngramServiceWebIngestStatus: String, Codable, Equatable, Sendable {
    case pending, processing, parsed, indexReady, retryableFailure, quarantined
}

enum EngramServiceWebAgentFilter: String, Codable, Equatable, Sendable {
    case hide, all, only
}

enum EngramServiceWebToolFilter: String, Codable, Equatable, Sendable {
    case all, hide
}

enum EngramServiceWebFacetKind: String, Codable, Equatable, Sendable {
    case source, project
}

enum EngramServiceWebStatsGroupBy: String, Codable, Equatable, Sendable {
    case source, project, day, week
}

struct EngramServiceWebOverviewRequest: Codable, Equatable, Sendable {
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(limit: Int = 2, snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        self.limit = limit
        self.snapshotId = snapshotId
        self.cursor = cursor
    }
}

struct EngramServiceWebSessionsRequest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case query, source, sources, machineId, sourceInstanceId, projectKey, projectKeys
        case sessionId, agents, since, until, tools, limit, snapshotId, cursor
    }

    let query: String?
    let source: String?
    let sources: [String]?
    let machineId: String?
    let sourceInstanceId: String?
    let projectKey: String?
    let projectKeys: [String]?
    let sessionId: String?
    let agents: EngramServiceWebAgentFilter
    let since: String?
    let until: String?
    let tools: EngramServiceWebToolFilter
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    var resolvedSources: [String]? { sources ?? source.map { [$0] } }
    var resolvedProjectKeys: [String]? { projectKeys ?? projectKey.map { [$0] } }

    init(query: String? = nil, source: String? = nil, sources: [String]? = nil,
         machineId: String? = nil, sourceInstanceId: String? = nil,
         projectKey: String? = nil, projectKeys: [String]? = nil,
         sessionId: String? = nil, agents: EngramServiceWebAgentFilter = .hide,
         since: String? = nil, until: String? = nil,
         tools: EngramServiceWebToolFilter = .all,
         limit: Int = 50, snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        try EngramServiceWebMetadataValidation.dateRange(since: since, until: until)
        if let query { try EngramServiceWebMetadataValidation.trimmed(query, maximumBytes: 1024) }
        if let source { try EngramServiceWebMetadataValidation.source(source) }
        if let machineId { try EngramServiceWebMetadataValidation.uuid(machineId) }
        if let sourceInstanceId { try EngramServiceWebMetadataValidation.uuid(sourceInstanceId) }
        if let projectKey { try EngramServiceWebMetadataValidation.projectIdentity(projectKey) }
        if let sessionId { try EngramServiceWebMetadataValidation.sessionID(sessionId) }
        try EngramServiceWebMetadataValidation.require(sourceInstanceId == nil || machineId != nil)
        try EngramServiceWebMetadataValidation.require(source == nil || sources == nil)
        try EngramServiceWebMetadataValidation.require(projectKey == nil || projectKeys == nil)
        self.query = query
        self.source = source
        self.sources = try sources.map { try EngramServiceWebMetadataValidation.sourceList($0) }
        self.machineId = machineId
        self.sourceInstanceId = sourceInstanceId
        self.projectKey = projectKey
        self.projectKeys = try projectKeys.map { try EngramServiceWebMetadataValidation.projectKeyList($0) }
        self.sessionId = sessionId
        self.agents = agents
        self.since = since
        self.until = until
        self.tools = tools
        self.limit = limit
        self.snapshotId = snapshotId
        self.cursor = cursor
    }
}

struct EngramServiceWebSessionDetailRequest: Codable, Equatable, Sendable {
    let sessionId: String

    init(sessionId: String) throws {
        try EngramServiceWebMetadataValidation.sessionID(sessionId)
        self.sessionId = sessionId
    }
}

struct EngramServiceWebFacetsRequest: Codable, Equatable, Sendable {
    let kind: EngramServiceWebFacetKind
    let query: String?
    let agents: EngramServiceWebAgentFilter
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(kind: EngramServiceWebFacetKind, query: String? = nil,
         agents: EngramServiceWebAgentFilter = .hide, limit: Int = 50,
         snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        if let query { try EngramServiceWebMetadataValidation.trimmed(query, maximumBytes: 1024) }
        self.kind = kind
        self.query = query
        self.agents = agents
        self.limit = limit
        self.snapshotId = snapshotId
        self.cursor = cursor
    }
}

struct EngramServiceWebFacetItem: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let sessionCount: Int64
}

struct EngramServiceWebFacetsResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let items: [EngramServiceWebFacetItem]
    let nextCursor: String?
}

struct EngramServiceWebStatsRequest: Codable, Equatable, Sendable {
    let groupBy: EngramServiceWebStatsGroupBy
    let since: String?
    let until: String?
    let excludeNoise: Bool
    let agents: EngramServiceWebAgentFilter
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(groupBy: EngramServiceWebStatsGroupBy = .source, since: String? = nil, until: String? = nil,
         excludeNoise: Bool = false, agents: EngramServiceWebAgentFilter = .hide, limit: Int = 50,
         snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        try EngramServiceWebMetadataValidation.dateRange(since: since, until: until)
        self.groupBy = groupBy
        self.since = since
        self.until = until
        self.excludeNoise = excludeNoise
        self.agents = agents
        self.limit = limit
        self.snapshotId = snapshotId
        self.cursor = cursor
    }
}

struct EngramServiceWebStatsTotals: Codable, Equatable, Sendable {
    let sessionCount: Int64
    let messageCount: Int64
    let userMessageCount: Int64
    let assistantMessageCount: Int64
    let toolMessageCount: Int64
}

struct EngramServiceWebStatsItem: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let sessionCount: Int64
    let messageCount: Int64
    let userMessageCount: Int64
    let assistantMessageCount: Int64
    let toolMessageCount: Int64
}

struct EngramServiceWebStatsResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let groupBy: EngramServiceWebStatsGroupBy
    let timeZone: String
    let totals: EngramServiceWebStatsTotals
    let items: [EngramServiceWebStatsItem]
    let nextCursor: String?
}

struct EngramServiceWebSettingsRequest: Codable, Equatable, Sendable {
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(limit: Int = 50, snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        self.limit = limit
        self.snapshotId = snapshotId
        self.cursor = cursor
    }
}

struct EngramServiceWebSettingsSource: Codable, Equatable, Sendable {
    let key: String
    let label: String
}

struct EngramServiceWebSettingsAlias: Codable, Equatable, Sendable {
    let alias: String
    let canonical: String
    let aliasLabel: String
    let canonicalLabel: String
}

/// Retired Settings display knobs. Only `unavailable` is legal; no invented value.
struct EngramServiceWebSettingsRetiredField: Codable, Equatable, Sendable {
    let availability: EngramServiceWebAvailability

    init() {
        self.availability = .unavailable
    }
}

struct EngramServiceWebSettingsResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let sources: [EngramServiceWebSettingsSource]
    let totalSessions: Int64
    let aliases: [EngramServiceWebSettingsAlias]
    let nextCursor: String?
    let nodeName: EngramServiceWebSettingsRetiredField
    let peers: EngramServiceWebSettingsRetiredField
    let port: EngramServiceWebSettingsRetiredField
}

struct EngramServiceWebCapabilities: Codable, Equatable, Sendable {
    let keywordSearch: EngramServiceWebAvailability
    let transcriptRead: EngramServiceWebAvailability
}

struct EngramServiceWebSourceBinding: Codable, Equatable, Sendable {
    let source: String
    let approvedEpoch: String
    let authorityGeneration: String
}

struct EngramServiceWebIngestTaskCounts: Codable, Equatable, Sendable {
    let pending: Int64
    let processing: Int64
    let parsed: Int64
    let indexReady: Int64
    let retryableFailure: Int64
    let quarantined: Int64
}

struct EngramServiceWebIngestObservation: Codable, Equatable, Sendable {
    let publicationCount: Int64
    let taskCounts: EngramServiceWebIngestTaskCounts
    let parseFailureTasks: Int64
    let oldestPendingAt: Int64?
}

struct EngramServiceWebCaptureObservation: Codable, Equatable, Sendable {
    let manifestSHA256: String
    let observedAt: Int64
}

struct EngramServiceWebReplicaACKObservation: Codable, Equatable, Sendable {
    let serverId: String
    let publicationSHA256: String
    let observedAt: Int64
    let lagSeconds: Int64?
}

struct EngramServiceWebFTSObservation: Codable, Equatable, Sendable {
    let observedAt: Int64
    let readyLogicalSessions: Int64
}

struct EngramServiceWebAIObservation: Codable, Equatable, Sendable {
    let observedAt: Int64
    let state: EngramServiceWebAIState
}

struct EngramServiceWebStreamOverview: Codable, Equatable, Sendable {
    let machineId: String
    let sourceInstanceId: String
    let registry: EngramServiceWebSourceBinding?
    let ingest: EngramServiceWebIngestObservation?
    let heartbeatAt: Int64?
    let lastCapture: EngramServiceWebCaptureObservation?
    let replicaACKs: [EngramServiceWebReplicaACKObservation]?
    let fts: EngramServiceWebFTSObservation?
    let ai: EngramServiceWebAIObservation?
}

struct EngramServiceWebOverviewResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let capabilities: EngramServiceWebCapabilities
    let streams: [EngramServiceWebStreamOverview]
    let nextCursor: String?
}

struct EngramServiceWebCaptureIdentity: Codable, Equatable, Sendable {
    let machineId: String
    let sourceInstanceId: String
}

struct EngramServiceWebSessionSummary: Codable, Equatable, Sendable {
    let sessionId: String
    let source: String
    let captureIdentity: EngramServiceWebCaptureIdentity?
    let metadataGeneration: String?
    let title: String?
    let projectKey: String?
    let projectLabel: String?
    let startedAt: Int64?
    let isAgent: Bool?
    let userMessageCount: Int?
    let assistantMessageCount: Int?
    let systemMessageCount: Int?
    let nativeId: String?

    init(sessionId: String, source: String, captureIdentity: EngramServiceWebCaptureIdentity?,
         metadataGeneration: String?, title: String?, projectKey: String?, projectLabel: String?,
         startedAt: Int64?, isAgent: Bool? = nil, userMessageCount: Int? = nil,
         assistantMessageCount: Int? = nil, systemMessageCount: Int? = nil,
         nativeId: String? = nil) {
        self.sessionId = sessionId
        self.source = source
        self.captureIdentity = captureIdentity
        self.metadataGeneration = metadataGeneration
        self.title = title
        self.projectKey = projectKey
        self.projectLabel = projectLabel
        self.startedAt = startedAt
        self.isAgent = isAgent
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.systemMessageCount = systemMessageCount
        self.nativeId = nativeId
    }
}

struct EngramServiceWebSessionsResponse: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case snapshotId, observedAt, items, nextCursor, totalCount, warning, warningCode
    }

    let snapshotId: String
    let observedAt: Int64
    let items: [EngramServiceWebSessionSummary]
    let nextCursor: String?
    let totalCount: Int64?
    let warning: String?
    let warningCode: String?

    init(snapshotId: String, observedAt: Int64, items: [EngramServiceWebSessionSummary],
         nextCursor: String?, totalCount: Int64? = nil, warning: String? = nil, warningCode: String? = nil) {
        self.snapshotId = snapshotId
        self.observedAt = observedAt
        self.items = items
        self.nextCursor = nextCursor
        self.totalCount = totalCount
        self.warning = warning
        self.warningCode = warningCode
    }
}

enum EngramServiceWebSearchMode: String, Codable, Equatable, Sendable {
    case keyword, semantic, hybrid
}

struct EngramServiceWebSearchRequest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case query, source, sources, machineId, sourceInstanceId, projectKey, projectKeys
        case sessionId, agents, since, until, tools, mode, limit
    }

    let query: String
    let source: String?
    let sources: [String]?
    let machineId: String?
    let sourceInstanceId: String?
    let projectKey: String?
    let projectKeys: [String]?
    let sessionId: String?
    let agents: EngramServiceWebAgentFilter
    let since: String?
    let until: String?
    let tools: EngramServiceWebToolFilter
    let mode: EngramServiceWebSearchMode
    let limit: Int

    var resolvedSources: [String]? { sources ?? source.map { [$0] } }
    var resolvedProjectKeys: [String]? { projectKeys ?? projectKey.map { [$0] } }

    init(query: String, source: String? = nil, sources: [String]? = nil,
         machineId: String? = nil, sourceInstanceId: String? = nil,
         projectKey: String? = nil, projectKeys: [String]? = nil,
         sessionId: String? = nil, agents: EngramServiceWebAgentFilter = .hide,
         since: String? = nil, until: String? = nil,
         tools: EngramServiceWebToolFilter = .all,
         mode: EngramServiceWebSearchMode = .keyword, limit: Int = 10) throws {
        try EngramServiceWebMetadataValidation.searchLimit(limit)
        try EngramServiceWebMetadataValidation.dateRange(since: since, until: until)
        try EngramServiceWebMetadataValidation.text(query, maximumBytes: 1024)
        if let source { try EngramServiceWebMetadataValidation.source(source) }
        if let machineId { try EngramServiceWebMetadataValidation.uuid(machineId) }
        if let sourceInstanceId { try EngramServiceWebMetadataValidation.uuid(sourceInstanceId) }
        if let projectKey { try EngramServiceWebMetadataValidation.projectIdentity(projectKey) }
        if let sessionId { try EngramServiceWebMetadataValidation.sessionID(sessionId) }
        try EngramServiceWebMetadataValidation.require(sourceInstanceId == nil || machineId != nil)
        try EngramServiceWebMetadataValidation.require(source == nil || sources == nil)
        try EngramServiceWebMetadataValidation.require(projectKey == nil || projectKeys == nil)
        self.query = query
        self.source = source
        self.sources = try sources.map { try EngramServiceWebMetadataValidation.sourceList($0) }
        self.machineId = machineId
        self.sourceInstanceId = sourceInstanceId
        self.projectKey = projectKey
        self.projectKeys = try projectKeys.map { try EngramServiceWebMetadataValidation.projectKeyList($0) }
        self.sessionId = sessionId
        self.agents = agents
        self.since = since
        self.until = until
        self.tools = tools
        self.mode = mode
        self.limit = limit
    }
}

struct EngramServiceWebSearchStatusRequest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case source, sources, machineId, sourceInstanceId, projectKey, projectKeys
        case sessionId, agents, since, until, tools
    }

    let source: String?
    let sources: [String]?
    let machineId: String?
    let sourceInstanceId: String?
    let projectKey: String?
    let projectKeys: [String]?
    let sessionId: String?
    let agents: EngramServiceWebAgentFilter
    let since: String?
    let until: String?
    let tools: EngramServiceWebToolFilter

    var resolvedSources: [String]? { sources ?? source.map { [$0] } }
    var resolvedProjectKeys: [String]? { projectKeys ?? projectKey.map { [$0] } }

    init(source: String? = nil, sources: [String]? = nil,
         machineId: String? = nil, sourceInstanceId: String? = nil,
         projectKey: String? = nil, projectKeys: [String]? = nil,
         sessionId: String? = nil, agents: EngramServiceWebAgentFilter = .hide,
         since: String? = nil, until: String? = nil,
         tools: EngramServiceWebToolFilter = .all) throws {
        try EngramServiceWebMetadataValidation.dateRange(since: since, until: until)
        if let source { try EngramServiceWebMetadataValidation.source(source) }
        if let machineId { try EngramServiceWebMetadataValidation.uuid(machineId) }
        if let sourceInstanceId { try EngramServiceWebMetadataValidation.uuid(sourceInstanceId) }
        if let projectKey { try EngramServiceWebMetadataValidation.projectIdentity(projectKey) }
        if let sessionId { try EngramServiceWebMetadataValidation.sessionID(sessionId) }
        try EngramServiceWebMetadataValidation.require(sourceInstanceId == nil || machineId != nil)
        try EngramServiceWebMetadataValidation.require(source == nil || sources == nil)
        try EngramServiceWebMetadataValidation.require(projectKey == nil || projectKeys == nil)
        self.source = source
        self.sources = try sources.map { try EngramServiceWebMetadataValidation.sourceList($0) }
        self.machineId = machineId
        self.sourceInstanceId = sourceInstanceId
        self.projectKey = projectKey
        self.projectKeys = try projectKeys.map { try EngramServiceWebMetadataValidation.projectKeyList($0) }
        self.sessionId = sessionId
        self.agents = agents
        self.since = since
        self.until = until
        self.tools = tools
    }
}

struct EngramServiceWebSearchHit: Codable, Equatable, Sendable {
    let session: EngramServiceWebSessionSummary
    let snippet: String?
    let matchType: String
    let score: Double?
}

struct EngramServiceWebSearchInsight: Codable, Equatable, Sendable {
    let id: String
    let content: String
    let sourceSessionId: String?
    let matchType: String
    let score: Double?
}

struct EngramServiceWebSearchResponse: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case observedAt, query, items, insightResults, searchModes, warning, warningCode
    }

    let observedAt: Int64
    let query: String
    let items: [EngramServiceWebSearchHit]
    let insightResults: [EngramServiceWebSearchInsight]
    let searchModes: [String]
    let warning: String?
    let warningCode: String?

    init(observedAt: Int64, query: String, items: [EngramServiceWebSearchHit],
         insightResults: [EngramServiceWebSearchInsight] = [], searchModes: [String],
         warning: String?, warningCode: String?) {
        self.observedAt = observedAt
        self.query = query
        self.items = items
        self.insightResults = insightResults
        self.searchModes = searchModes
        self.warning = warning
        self.warningCode = warningCode
    }
}

struct EngramServiceWebInsightDetailRequest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case id, offset, limit, revision
    }

    let id: String
    let offset: Int
    let limit: Int
    let revision: String?

    init(id: String, offset: Int = 0, limit: Int = 8000, revision: String? = nil) throws {
        try EngramServiceWebMetadataValidation.token(id, maximumBytes: 128)
        try EngramServiceWebMetadataValidation.count(Int64(offset))
        try EngramServiceWebMetadataValidation.require((1...8000).contains(limit))
        if let revision { try EngramServiceWebMetadataValidation.hash(revision) }
        try EngramServiceWebMetadataValidation.require(offset == 0 || revision != nil)
        self.id = id
        self.offset = offset
        self.limit = limit
        self.revision = revision
    }
}

struct EngramServiceWebInsightDetailResponse: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case id, revision, offset, totalLength, content, nextOffset, sourceSessionId
    }

    let id: String
    let revision: String
    let offset: Int
    let totalLength: Int
    let content: String
    let nextOffset: Int?
    let sourceSessionId: String?

    init(id: String, revision: String, offset: Int, totalLength: Int, content: String,
         nextOffset: Int?, sourceSessionId: String?) {
        self.id = id
        self.revision = revision
        self.offset = offset
        self.totalLength = totalLength
        self.content = content
        self.nextOffset = nextOffset
        self.sourceSessionId = sourceSessionId
    }
}

struct EngramServiceWebSearchStatusResponse: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case observedAt, keyword, semantic, hybrid, warning, warningCode
        case model, dimension, eligibleSessionCount, embeddedSessionCount, progressPercent
    }

    let observedAt: Int64
    let keyword: EngramServiceWebAvailability
    let semantic: EngramServiceWebAvailability
    let hybrid: EngramServiceWebAvailability
    let warning: String?
    let warningCode: String?
    let model: String?
    let dimension: Int?
    let eligibleSessionCount: Int64?
    let embeddedSessionCount: Int64?
    let progressPercent: Int?
}

enum EngramServiceWebCostsGroupBy: String, Codable, Equatable, Sendable {
    case model, source, project, day
}

struct EngramServiceWebCostsRequest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case source, sources, machineId, sourceInstanceId, projectKey, projectKeys
        case sessionId, agents, since, until, tools, groupBy, limit, snapshotId, cursor
    }

    let source: String?
    let sources: [String]?
    let machineId: String?
    let sourceInstanceId: String?
    let projectKey: String?
    let projectKeys: [String]?
    let sessionId: String?
    let agents: EngramServiceWebAgentFilter
    let since: String?
    let until: String?
    let tools: EngramServiceWebToolFilter
    let groupBy: EngramServiceWebCostsGroupBy
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    var resolvedSources: [String]? { sources ?? source.map { [$0] } }
    var resolvedProjectKeys: [String]? { projectKeys ?? projectKey.map { [$0] } }

    init(source: String? = nil, sources: [String]? = nil,
         machineId: String? = nil, sourceInstanceId: String? = nil,
         projectKey: String? = nil, projectKeys: [String]? = nil,
         sessionId: String? = nil, agents: EngramServiceWebAgentFilter = .hide,
         since: String? = nil, until: String? = nil,
         tools: EngramServiceWebToolFilter = .all,
         groupBy: EngramServiceWebCostsGroupBy = .model, limit: Int = 50,
         snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        try EngramServiceWebMetadataValidation.dateRange(since: since, until: until)
        if let source { try EngramServiceWebMetadataValidation.source(source) }
        if let machineId { try EngramServiceWebMetadataValidation.uuid(machineId) }
        if let sourceInstanceId { try EngramServiceWebMetadataValidation.uuid(sourceInstanceId) }
        if let projectKey { try EngramServiceWebMetadataValidation.projectIdentity(projectKey) }
        if let sessionId { try EngramServiceWebMetadataValidation.sessionID(sessionId) }
        try EngramServiceWebMetadataValidation.require(sourceInstanceId == nil || machineId != nil)
        try EngramServiceWebMetadataValidation.require(source == nil || sources == nil)
        try EngramServiceWebMetadataValidation.require(projectKey == nil || projectKeys == nil)
        self.source = source
        self.sources = try sources.map { try EngramServiceWebMetadataValidation.sourceList($0) }
        self.machineId = machineId
        self.sourceInstanceId = sourceInstanceId
        self.projectKey = projectKey
        self.projectKeys = try projectKeys.map { try EngramServiceWebMetadataValidation.projectKeyList($0) }
        self.sessionId = sessionId
        self.agents = agents
        self.since = since
        self.until = until
        self.tools = tools
        self.groupBy = groupBy
        self.limit = limit
        self.snapshotId = snapshotId
        self.cursor = cursor
    }
}

struct EngramServiceWebCostTotals: Codable, Equatable, Sendable {
    let costUsd: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let sessionCount: Int64
}

struct EngramServiceWebCostItem: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let costUsd: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let sessionCount: Int64
}

struct EngramServiceWebCostsResponse: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case snapshotId, observedAt, groupBy, timeZone, totals, items, nextCursor
        case unpricedUnattributedSessions, unpricedNoPriceSessions
        case unpricedUnattributedTokens, unpricedNoPriceTokens
    }

    let snapshotId: String
    let observedAt: Int64
    let groupBy: EngramServiceWebCostsGroupBy
    let timeZone: String
    let totals: EngramServiceWebCostTotals
    let items: [EngramServiceWebCostItem]
    let nextCursor: String?
    let unpricedUnattributedSessions: Int?
    let unpricedNoPriceSessions: Int?
    let unpricedUnattributedTokens: Int?
    let unpricedNoPriceTokens: Int?
}

struct EngramServiceWebCostSessionsRequest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case source, sources, machineId, sourceInstanceId, projectKey, projectKeys
        case sessionId, agents, since, until, tools, limit
    }

    let source: String?
    let sources: [String]?
    let machineId: String?
    let sourceInstanceId: String?
    let projectKey: String?
    let projectKeys: [String]?
    let sessionId: String?
    let agents: EngramServiceWebAgentFilter
    let since: String?
    let until: String?
    let tools: EngramServiceWebToolFilter
    let limit: Int

    var resolvedSources: [String]? { sources ?? source.map { [$0] } }
    var resolvedProjectKeys: [String]? { projectKeys ?? projectKey.map { [$0] } }

    init(source: String? = nil, sources: [String]? = nil,
         machineId: String? = nil, sourceInstanceId: String? = nil,
         projectKey: String? = nil, projectKeys: [String]? = nil,
         sessionId: String? = nil, agents: EngramServiceWebAgentFilter = .hide,
         since: String? = nil, until: String? = nil,
         tools: EngramServiceWebToolFilter = .all, limit: Int = 20) throws {
        try EngramServiceWebMetadataValidation.costSessionsLimit(limit)
        try EngramServiceWebMetadataValidation.dateRange(since: since, until: until)
        if let source { try EngramServiceWebMetadataValidation.source(source) }
        if let machineId { try EngramServiceWebMetadataValidation.uuid(machineId) }
        if let sourceInstanceId { try EngramServiceWebMetadataValidation.uuid(sourceInstanceId) }
        if let projectKey { try EngramServiceWebMetadataValidation.projectIdentity(projectKey) }
        if let sessionId { try EngramServiceWebMetadataValidation.sessionID(sessionId) }
        try EngramServiceWebMetadataValidation.require(sourceInstanceId == nil || machineId != nil)
        try EngramServiceWebMetadataValidation.require(source == nil || sources == nil)
        try EngramServiceWebMetadataValidation.require(projectKey == nil || projectKeys == nil)
        self.source = source
        self.sources = try sources.map { try EngramServiceWebMetadataValidation.sourceList($0) }
        self.machineId = machineId
        self.sourceInstanceId = sourceInstanceId
        self.projectKey = projectKey
        self.projectKeys = try projectKeys.map { try EngramServiceWebMetadataValidation.projectKeyList($0) }
        self.sessionId = sessionId
        self.agents = agents
        self.since = since
        self.until = until
        self.tools = tools
        self.limit = limit
    }
}

struct EngramServiceWebCostSessionItem: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case session, costUsd, model, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens
    }

    let session: EngramServiceWebSessionSummary
    let costUsd: Double
    let model: String?
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
}

struct EngramServiceWebCostSessionsResponse: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case observedAt, items
    }

    let observedAt: Int64
    let items: [EngramServiceWebCostSessionItem]
}

struct EngramServiceWebGenerationSummary: Codable, Equatable, Sendable {
    let generationId: String
    let publicationSHA256: String
    let parserRevision: String
    let collectorEpoch: String
    let authorityGeneration: String
    let sequence: String
    let committedAt: Int64?
    let normalizedMessageCount: Int
}

struct EngramServiceWebSessionAttempt: Codable, Equatable, Sendable {
    let publicationSHA256: String
    let parserRevision: String
    let collectorEpoch: String
    let sequence: String
    let status: EngramServiceWebIngestStatus
    let failureCode: String?
    let recordedAt: Int64?
}

struct EngramServiceWebSessionDetail: Codable, Equatable, Sendable {
    let session: EngramServiceWebSessionSummary
    let lastParsed: EngramServiceWebGenerationSummary?
    let lastReady: EngramServiceWebGenerationSummary?
    let transcriptAvailability: EngramServiceWebAvailability
    let transcriptGeneration: String?
    let currentAttempt: EngramServiceWebSessionAttempt?
    let summary: String?

    init(
        session: EngramServiceWebSessionSummary,
        lastParsed: EngramServiceWebGenerationSummary?,
        lastReady: EngramServiceWebGenerationSummary?,
        transcriptAvailability: EngramServiceWebAvailability,
        transcriptGeneration: String?,
        currentAttempt: EngramServiceWebSessionAttempt?,
        summary: String? = nil
    ) {
        self.session = session
        self.lastParsed = lastParsed
        self.lastReady = lastReady
        self.transcriptAvailability = transcriptAvailability
        self.transcriptGeneration = transcriptGeneration
        self.currentAttempt = currentAttempt
        self.summary = summary
    }
}

struct EngramServiceWebSessionDetailResponse: Codable, Equatable, Sendable {
    let observedAt: Int64
    let detail: EngramServiceWebSessionDetail?
}

enum EngramServiceWebChildRelationship: String, Codable, Equatable, Sendable {
    case confirmed
    case suggested
}

struct EngramServiceWebChildrenRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(sessionId: String, limit: Int = EngramServiceWebReadLimits.defaultChildrenLimit,
         snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.sessionID(sessionId)
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        self.sessionId = sessionId
        self.limit = limit
        self.snapshotId = snapshotId
        self.cursor = cursor
    }
}

struct EngramServiceWebChildItem: Codable, Equatable, Sendable {
    let relationship: EngramServiceWebChildRelationship
    let session: EngramServiceWebSessionSummary
}

struct EngramServiceWebChildrenResponse: Codable, Equatable, Sendable {
    let sessionId: String
    let snapshotId: String
    let observedAt: Int64
    let items: [EngramServiceWebChildItem]
    let nextCursor: String?

    init(sessionId: String, snapshotId: String, observedAt: Int64,
         items: [EngramServiceWebChildItem], nextCursor: String?) {
        self.sessionId = sessionId
        self.snapshotId = snapshotId
        self.observedAt = observedAt
        self.items = items
        self.nextCursor = nextCursor
    }
}

enum EngramServiceWebTimelineEntryType: String, Codable, Equatable, Sendable {
    case message
    case tool_use
    case tool_result
}

struct EngramServiceWebTimelineTokens: Codable, Equatable, Sendable {
    let input: Int
    let output: Int
}

struct EngramServiceWebTimelineRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let generation: String
    let offset: Int
    let limit: Int

    init(sessionId: String, generation: String, offset: Int = 0,
         limit: Int = EngramServiceWebReadLimits.defaultTimelineLimit) throws {
        try EngramServiceWebReadValidation.identity(sessionId: sessionId, generation: generation)
        try EngramServiceWebMetadataValidation.timelineWindow(offset: offset, limit: limit)
        self.sessionId = sessionId
        self.generation = generation
        self.offset = offset
        self.limit = limit
    }
}

struct EngramServiceWebTimelineEntry: Codable, Equatable, Sendable {
    let index: Int
    let role: EngramServiceWebMessageRole
    let type: EngramServiceWebTimelineEntryType
    let preview: String
    let timestamp: String?
    let toolName: String?
    let tokens: EngramServiceWebTimelineTokens?
    let durationToNextMs: Int?

    init(index: Int, role: EngramServiceWebMessageRole, type: EngramServiceWebTimelineEntryType,
         preview: String, timestamp: String? = nil, toolName: String? = nil,
         tokens: EngramServiceWebTimelineTokens? = nil, durationToNextMs: Int? = nil) {
        self.index = index
        self.role = role
        self.type = type
        self.preview = preview
        self.timestamp = timestamp
        self.toolName = toolName
        self.tokens = tokens
        self.durationToNextMs = durationToNextMs
    }
}

struct EngramServiceWebTimelineResponse: Codable, Equatable, Sendable {
    let sessionId: String
    let generation: String
    let totalEntries: Int
    let entries: [EngramServiceWebTimelineEntry]
    let nextOffset: Int?

    init(sessionId: String, generation: String, totalEntries: Int,
         entries: [EngramServiceWebTimelineEntry], nextOffset: Int?) {
        self.sessionId = sessionId
        self.generation = generation
        self.totalEntries = totalEntries
        self.entries = entries
        self.nextOffset = nextOffset
    }
}

internal enum EngramServiceWebMetadataValidation {
    static let maximumCount: Int64 = 9_007_199_254_740_991
    static let maximumTime: Int64 = 253_402_300_799
    // Closed symbolic vocabulary, never a provider or filesystem diagnostic.
    static let failureCodes = Set(EngramServiceWebReadValidation.parseFailures.map { "parse." + $0 })
        .union(["quarantine.invalid_manifest", "quarantine.unsupported_capture_shape",
                "quarantine.source_integrity_mismatch", "quarantine.binding_mismatch",
                "quarantine.invalid_native_identity", "quarantine.sequence_conflict",
                "retry.cas_unavailable", "retry.staging_unavailable", "retry.interrupted", "sequence_conflict"])

    static func require(_ condition: Bool) throws {
        guard condition else { throw EngramServiceWebReadError.invalidField("metadata") }
    }

    static func uuid(_ value: String) throws {
        try require(UUID(uuidString: value)?.uuidString == value)
    }

    static func hash(_ value: String) throws {
        try require(EngramServiceWebReadValidation.isSHA256(value))
    }

    static func text(_ value: String, maximumBytes: Int, allowEmpty: Bool = true) throws {
        try require((allowEmpty || !value.isEmpty) && value.utf8.count <= maximumBytes && !value.utf8.contains(0))
    }

    static func trimmed(_ value: String, maximumBytes: Int) throws {
        try text(value, maximumBytes: maximumBytes, allowEmpty: false)
        try require(value.utf8.elementsEqual(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    static func sessionID(_ value: String) throws {
        try text(value, maximumBytes: EngramServiceWebReadLimits.maximumSessionIDBytes, allowEmpty: false)
    }

    static func token(_ value: String, maximumBytes: Int, allowDot: Bool = false) throws {
        try text(value, maximumBytes: maximumBytes, allowEmpty: false)
        try require(value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 95 || (allowDot && $0 == 46)
        })
    }

    /// Legacy `[A-Za-z0-9_-]{1,128}` or reserved `p.<sha256>`. The dot keeps
    /// opaque keys outside the token alphabet so a digest cannot collide.
    static func projectIdentity(_ value: String) throws {
        let bytes = Array(value.utf8)
        if bytes.count == 66, bytes[0] == 0x70, bytes[1] == 0x2e {
            try hash(String(decoding: bytes.dropFirst(2), as: UTF8.self))
            return
        }
        try token(value, maximumBytes: 128)
    }

    static func queryMatches(_ value: String, query: String) -> Bool {
        value.range(of: query, options: [.caseInsensitive, .literal]) != nil
    }

    static let unknownProjectKey = "u.project"
    static let unknownDateKey = "u.date"
    static let unknownModelKey = "u.model"

    static func calendarDate(_ value: String) throws {
        let bytes = Array(value.utf8)
        try require(bytes.count == 10 && bytes[4] == 0x2d && bytes[7] == 0x2d)
        try require(bytes.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7 ? byte == 0x2d : (48...57).contains(byte)
        })
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = Int(String(decoding: bytes[0..<4], as: UTF8.self))
        components.month = Int(String(decoding: bytes[5..<7], as: UTF8.self))
        components.day = Int(String(decoding: bytes[8..<10], as: UTF8.self))
        try require(components.isValidDate)
    }

    static func searchLimit(_ limit: Int) throws {
        try require((1...50).contains(limit))
    }

    static func costSessionsLimit(_ limit: Int) throws {
        try require((1...100).contains(limit))
    }

    static func money(_ value: Double) throws {
        try require(value.isFinite && value >= 0 && value <= 1_000_000_000)
    }

    static func moneyCents(_ value: Double) -> Int64 {
        Int64((value * 100).rounded())
    }

    static func dateRange(since: String?, until: String?) throws {
        if let since { try calendarDate(since) }
        if let until { try calendarDate(until) }
        if let since, let until {
            try require(since.utf8.lexicographicallyPrecedes(until.utf8) || since.utf8.elementsEqual(until.utf8))
        }
    }

    static func localCalendarDate(epoch: Int64) throws -> String {
        try time(epoch)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day],
            from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            throw EngramServiceWebReadError.invalidField("metadata")
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func timeZone(_ value: String) throws {
        try text(value, maximumBytes: 64, allowEmpty: false)
        try require(value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 47 || $0 == 95 || $0 == 45 || $0 == 43
        })
    }

    static func statsKey(_ value: String, groupBy: EngramServiceWebStatsGroupBy) throws {
        switch groupBy {
        case .source:
            try source(value)
        case .project:
            if value.utf8.elementsEqual(unknownProjectKey.utf8) { return }
            try projectIdentity(value)
        case .day, .week:
            if value.utf8.elementsEqual(unknownDateKey.utf8) { return }
            try calendarDate(value)
        }
    }

    static func statsCounts(_ totals: EngramServiceWebStatsTotals) throws {
        try count(totals.sessionCount)
        try count(totals.messageCount)
        try count(totals.userMessageCount)
        try count(totals.assistantMessageCount)
        try count(totals.toolMessageCount)
    }

    static func statsCounts(_ item: EngramServiceWebStatsItem) throws {
        try count(item.sessionCount)
        try count(item.messageCount)
        try count(item.userMessageCount)
        try count(item.assistantMessageCount)
        try count(item.toolMessageCount)
    }

    static func costsKey(_ value: String, groupBy: EngramServiceWebCostsGroupBy) throws {
        switch groupBy {
        case .model:
            if value.utf8.elementsEqual(unknownModelKey.utf8) { return }
            try text(value, maximumBytes: 128, allowEmpty: false)
        case .source:
            try source(value)
        case .project:
            if value.utf8.elementsEqual(unknownProjectKey.utf8) { return }
            try projectIdentity(value)
        case .day:
            if value.utf8.elementsEqual(unknownDateKey.utf8) { return }
            try calendarDate(value)
        }
    }

    static func costsCounts(_ totals: EngramServiceWebCostTotals) throws {
        try money(totals.costUsd)
        try count(totals.inputTokens)
        try count(totals.outputTokens)
        try count(totals.cacheReadTokens)
        try count(totals.cacheCreationTokens)
        try count(totals.sessionCount)
    }

    static func costsCounts(_ item: EngramServiceWebCostItem) throws {
        try money(item.costUsd)
        try count(item.inputTokens)
        try count(item.outputTokens)
        try count(item.cacheReadTokens)
        try count(item.cacheCreationTokens)
        try count(item.sessionCount)
    }

    static func costsCover(_ totals: EngramServiceWebCostTotals, items: [EngramServiceWebCostItem]) throws {
        try require(totals.sessionCount >= items.reduce(0) { $0 + $1.sessionCount })
        try require(totals.inputTokens >= items.reduce(0) { $0 + $1.inputTokens })
        try require(totals.outputTokens >= items.reduce(0) { $0 + $1.outputTokens })
        try require(totals.cacheReadTokens >= items.reduce(0) { $0 + $1.cacheReadTokens })
        try require(totals.cacheCreationTokens >= items.reduce(0) { $0 + $1.cacheCreationTokens })
        // Raw USD only. Independently rounded cents can reject a valid full-set
        // total: 0.006 + 0.006 = 0.012 (1¢) while 0.01 + 0.01 is 2¢.
        let pageUsd = items.reduce(0.0) { $0 + $1.costUsd }
        try require(totals.costUsd.isFinite && pageUsd.isFinite)
        try require(totals.costUsd + 1e-6 >= pageUsd)
    }

    static func unpricedCount(_ value: Int?) throws {
        guard let value else { return }
        try count(Int64(value))
    }

    static func totalsCover(_ totals: EngramServiceWebStatsTotals, items: [EngramServiceWebStatsItem]) throws {
        try require(totals.sessionCount >= items.reduce(0) { $0 + $1.sessionCount })
        try require(totals.messageCount >= items.reduce(0) { $0 + $1.messageCount })
        try require(totals.userMessageCount >= items.reduce(0) { $0 + $1.userMessageCount })
        try require(totals.assistantMessageCount >= items.reduce(0) { $0 + $1.assistantMessageCount })
        try require(totals.toolMessageCount >= items.reduce(0) { $0 + $1.toolMessageCount })
    }

    static func settingsSource(_ value: EngramServiceWebSettingsSource) throws {
        try source(value.key)
        try source(value.label)
        try require(value.key.utf8.elementsEqual(value.label.utf8))
    }

    static func settingsAlias(_ value: EngramServiceWebSettingsAlias) throws {
        try projectIdentity(value.alias)
        try projectIdentity(value.canonical)
        try require(!value.alias.utf8.elementsEqual(value.canonical.utf8))
        try text(value.aliasLabel, maximumBytes: 256, allowEmpty: false)
        try text(value.canonicalLabel, maximumBytes: 256, allowEmpty: false)
    }

    static func retiredUnavailable(_ value: EngramServiceWebSettingsRetiredField) throws {
        try require(value.availability == .unavailable)
    }

    static func source(_ value: String) throws {
        try text(value, maximumBytes: 64, allowEmpty: false)
        try require(value.utf8.first.map { (97...122).contains($0) } == true
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
    }

    static func positiveDecimal(_ value: String) throws {
        try require(!value.isEmpty && value.utf8.count <= 19
            && value.utf8.first != 48 && value.utf8.allSatisfy { (48...57).contains($0) }
            && Int64(value).map { $0 > 0 } == true)
    }

    static func utcHour(_ value: String) throws {
        let bytes = Array(value.utf8)
        try require(bytes.count == 16 && bytes[10] == 0x54 && bytes[13] == 0x3a
            && bytes[14] == 0x30 && bytes[15] == 0x30)
        try calendarDate(String(decoding: bytes[0..<10], as: UTF8.self))
        guard let hour = Int(String(decoding: bytes[11..<13], as: UTF8.self)), (0...23).contains(hour) else {
            throw EngramServiceWebReadError.invalidField("metadata")
        }
    }

    static func aiStatsInterval(_ from: String, _ to: String) throws {
        try text(from, maximumBytes: 64, allowEmpty: false)
        try text(to, maximumBytes: 64, allowEmpty: false)
        try require(from.contains("T") && to.contains("T"))
        try require(from.utf8.lexicographicallyPrecedes(to.utf8) || from.utf8.elementsEqual(to.utf8))
    }

    static func optionalCount(_ value: Int64?) throws {
        if let value { try count(value) }
    }

    static func aiAuditItem(_ item: EngramServiceWebAiAuditItem) throws {
        try positiveDecimal(item.id)
        try time(item.at)
        try text(item.caller, maximumBytes: 256, allowEmpty: false)
        try text(item.operation, maximumBytes: 256, allowEmpty: false)
        if let method = item.method { try text(method, maximumBytes: 16, allowEmpty: false) }
        if let url = item.url { try text(url, maximumBytes: 1024, allowEmpty: false) }
        try optionalCount(item.statusCode)
        try optionalCount(item.durationMs)
        if let model = item.model { try text(model, maximumBytes: 256, allowEmpty: false) }
        if let provider = item.provider { try text(provider, maximumBytes: 256, allowEmpty: false) }
        try optionalCount(item.promptTokens)
        try optionalCount(item.completionTokens)
        try optionalCount(item.totalTokens)
        if let error = item.error { try text(error, maximumBytes: 1024, allowEmpty: false) }
        if let sessionId = item.sessionId { try sessionID(sessionId) }
        try require(item.hasError == (item.error != nil))
    }

    static func count(_ value: Int64) throws { try require((0...maximumCount).contains(value)) }
    static func time(_ value: Int64) throws { try require((0...maximumTime).contains(value)) }

    static func pageRequest(limit: Int, snapshotId: String?, cursor: String?) throws {
        try require((1...100).contains(limit) && (snapshotId == nil) == (cursor == nil))
        if let snapshotId { try uuid(snapshotId) }
        if let cursor { try token(cursor, maximumBytes: EngramServiceWebReadLimits.maximumCursorBytes) }
    }

    static func timelineWindow(offset: Int, limit: Int) throws {
        try require((0...EngramServiceWebReadLimits.maximumMessages).contains(offset))
        try require((1...EngramServiceWebReadLimits.maximumTimelineLimit).contains(limit))
    }

    static func page(snapshotId: String, count: Int, nextCursor: String?) throws {
        try uuid(snapshotId)
        try require(count <= 100 && (nextCursor == nil || count > 0))
        if let nextCursor { try token(nextCursor, maximumBytes: EngramServiceWebReadLimits.maximumCursorBytes) }
    }

    static func sourceList(_ values: [String]) throws -> [String] {
        try canonicalize(values, validate: source)
    }

    static func projectKeyList(_ values: [String]) throws -> [String] {
        try canonicalize(values, validate: projectIdentity)
    }

    private static func canonicalize(_ values: [String], validate: (String) throws -> Void) throws -> [String] {
        try require((1...EngramServiceWebReadLimits.maximumFilterListCount).contains(values.count))
        var seen: Set<Data> = []
        seen.reserveCapacity(values.count)
        for value in values {
            try validate(value)
            try require(seen.insert(Data(value.utf8)).inserted)
        }
        return values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}

// Decode at the wire boundary; memberwise construction remains available to
// trusted producers. Request construction validates through its throwing init.
extension EngramServiceWebOverviewRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            limit: try c.decode(Int.self, forKey: .limit),
            snapshotId: try c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor)
        )
    }
}

extension EngramServiceWebSessionsRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            query: try c.decodeIfPresent(String.self, forKey: .query),
            source: try c.decodeIfPresent(String.self, forKey: .source),
            sources: try c.decodeIfPresent([String].self, forKey: .sources),
            machineId: try c.decodeIfPresent(String.self, forKey: .machineId),
            sourceInstanceId: try c.decodeIfPresent(String.self, forKey: .sourceInstanceId),
            projectKey: try c.decodeIfPresent(String.self, forKey: .projectKey),
            projectKeys: try c.decodeIfPresent([String].self, forKey: .projectKeys),
            sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId),
            agents: try c.decodeIfPresent(EngramServiceWebAgentFilter.self, forKey: .agents) ?? .hide,
            since: try c.decodeIfPresent(String.self, forKey: .since),
            until: try c.decodeIfPresent(String.self, forKey: .until),
            tools: try c.decodeIfPresent(EngramServiceWebToolFilter.self, forKey: .tools) ?? .all,
            limit: try c.decode(Int.self, forKey: .limit),
            snapshotId: try c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(query, forKey: .query)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(sources, forKey: .sources)
        try c.encodeIfPresent(machineId, forKey: .machineId)
        try c.encodeIfPresent(sourceInstanceId, forKey: .sourceInstanceId)
        try c.encodeIfPresent(projectKey, forKey: .projectKey)
        try c.encodeIfPresent(projectKeys, forKey: .projectKeys)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(agents, forKey: .agents)
        try c.encodeIfPresent(since, forKey: .since)
        try c.encodeIfPresent(until, forKey: .until)
        if tools != .all { try c.encode(tools, forKey: .tools) }
        try c.encode(limit, forKey: .limit)
        try c.encodeIfPresent(snapshotId, forKey: .snapshotId)
        try c.encodeIfPresent(cursor, forKey: .cursor)
    }
}

extension EngramServiceWebSearchRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            query: try c.decode(String.self, forKey: .query),
            source: try c.decodeIfPresent(String.self, forKey: .source),
            sources: try c.decodeIfPresent([String].self, forKey: .sources),
            machineId: try c.decodeIfPresent(String.self, forKey: .machineId),
            sourceInstanceId: try c.decodeIfPresent(String.self, forKey: .sourceInstanceId),
            projectKey: try c.decodeIfPresent(String.self, forKey: .projectKey),
            projectKeys: try c.decodeIfPresent([String].self, forKey: .projectKeys),
            sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId),
            agents: try c.decodeIfPresent(EngramServiceWebAgentFilter.self, forKey: .agents) ?? .hide,
            since: try c.decodeIfPresent(String.self, forKey: .since),
            until: try c.decodeIfPresent(String.self, forKey: .until),
            tools: try c.decodeIfPresent(EngramServiceWebToolFilter.self, forKey: .tools) ?? .all,
            mode: try c.decodeIfPresent(EngramServiceWebSearchMode.self, forKey: .mode) ?? .keyword,
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 10
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(query, forKey: .query)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(sources, forKey: .sources)
        try c.encodeIfPresent(machineId, forKey: .machineId)
        try c.encodeIfPresent(sourceInstanceId, forKey: .sourceInstanceId)
        try c.encodeIfPresent(projectKey, forKey: .projectKey)
        try c.encodeIfPresent(projectKeys, forKey: .projectKeys)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(agents, forKey: .agents)
        try c.encodeIfPresent(since, forKey: .since)
        try c.encodeIfPresent(until, forKey: .until)
        if tools != .all { try c.encode(tools, forKey: .tools) }
        if mode != .keyword { try c.encode(mode, forKey: .mode) }
        try c.encode(limit, forKey: .limit)
    }
}

extension EngramServiceWebSearchStatusRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: try c.decodeIfPresent(String.self, forKey: .source),
            sources: try c.decodeIfPresent([String].self, forKey: .sources),
            machineId: try c.decodeIfPresent(String.self, forKey: .machineId),
            sourceInstanceId: try c.decodeIfPresent(String.self, forKey: .sourceInstanceId),
            projectKey: try c.decodeIfPresent(String.self, forKey: .projectKey),
            projectKeys: try c.decodeIfPresent([String].self, forKey: .projectKeys),
            sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId),
            agents: try c.decodeIfPresent(EngramServiceWebAgentFilter.self, forKey: .agents) ?? .hide,
            since: try c.decodeIfPresent(String.self, forKey: .since),
            until: try c.decodeIfPresent(String.self, forKey: .until),
            tools: try c.decodeIfPresent(EngramServiceWebToolFilter.self, forKey: .tools) ?? .all
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(sources, forKey: .sources)
        try c.encodeIfPresent(machineId, forKey: .machineId)
        try c.encodeIfPresent(sourceInstanceId, forKey: .sourceInstanceId)
        try c.encodeIfPresent(projectKey, forKey: .projectKey)
        try c.encodeIfPresent(projectKeys, forKey: .projectKeys)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(agents, forKey: .agents)
        try c.encodeIfPresent(since, forKey: .since)
        try c.encodeIfPresent(until, forKey: .until)
        if tools != .all { try c.encode(tools, forKey: .tools) }
    }
}

extension EngramServiceWebSearchResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            query: try c.decode(String.self, forKey: .query),
            items: try c.decode([EngramServiceWebSearchHit].self, forKey: .items),
            insightResults: try c.decodeIfPresent([EngramServiceWebSearchInsight].self, forKey: .insightResults) ?? [],
            searchModes: try c.decode([String].self, forKey: .searchModes),
            warning: try c.decodeIfPresent(String.self, forKey: .warning),
            warningCode: try c.decodeIfPresent(String.self, forKey: .warningCode)
        )
        try V.time(observedAt)
        try V.text(query, maximumBytes: 1024)
        try V.require(items.count <= 50)
        try V.require(Set(items.map { Data($0.session.sessionId.utf8) }).count == items.count)
        for hit in items {
            try V.require(hit.matchType == "keyword" || hit.matchType == "semantic")
        }
        try V.require(insightResults.count <= 5)
        try V.require(Set(insightResults.map { Data($0.id.utf8) }).count == insightResults.count)
        for insight in insightResults {
            try V.token(insight.id, maximumBytes: 128)
            try V.text(insight.content, maximumBytes: 4096, allowEmpty: false)
            try V.require(insight.content.unicodeScalars.count <= 600)
            try V.require(insight.matchType == "keyword" || insight.matchType == "semantic")
            if let sessionId = insight.sourceSessionId { try V.sessionID(sessionId) }
        }
        if let warning { try V.text(warning, maximumBytes: 1024) }
        if let warningCode { try V.token(warningCode, maximumBytes: 64) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(query, forKey: .query)
        try c.encode(items, forKey: .items)
        try c.encode(insightResults, forKey: .insightResults)
        try c.encode(searchModes, forKey: .searchModes)
        try c.encodeIfPresent(warning, forKey: .warning)
        try c.encodeIfPresent(warningCode, forKey: .warningCode)
    }
}

extension EngramServiceWebInsightDetailRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try c.decode(String.self, forKey: .id),
            offset: try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 8000,
            revision: try c.decodeIfPresent(String.self, forKey: .revision)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if offset != 0 { try c.encode(offset, forKey: .offset) }
        if limit != 8000 { try c.encode(limit, forKey: .limit) }
        try c.encodeIfPresent(revision, forKey: .revision)
    }
}

extension EngramServiceWebInsightDetailResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        revision = try c.decode(String.self, forKey: .revision)
        offset = try c.decode(Int.self, forKey: .offset)
        totalLength = try c.decode(Int.self, forKey: .totalLength)
        content = try c.decode(String.self, forKey: .content)
        nextOffset = try c.decodeIfPresent(Int.self, forKey: .nextOffset)
        sourceSessionId = try c.decodeIfPresent(String.self, forKey: .sourceSessionId)
        try V.token(id, maximumBytes: 128)
        try V.hash(revision)
        try V.count(Int64(offset))
        try V.count(Int64(totalLength))
        try V.require(content.unicodeScalars.count <= 8000)
        try V.text(content, maximumBytes: 65_536, allowEmpty: true)
        try V.require(offset <= totalLength)
        try V.require(offset + content.unicodeScalars.count <= totalLength)
        if let nextOffset {
            try V.count(Int64(nextOffset))
            try V.require(nextOffset > offset)
            try V.require(nextOffset <= totalLength)
            try V.require(offset + content.unicodeScalars.count == nextOffset)
        } else {
            try V.require(offset + content.unicodeScalars.count == totalLength)
        }
        if let sourceSessionId { try V.sessionID(sourceSessionId) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(revision, forKey: .revision)
        try c.encode(offset, forKey: .offset)
        try c.encode(totalLength, forKey: .totalLength)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(nextOffset, forKey: .nextOffset)
        try c.encodeIfPresent(sourceSessionId, forKey: .sourceSessionId)
    }
}

extension EngramServiceWebSearchStatusResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            keyword: try c.decode(EngramServiceWebAvailability.self, forKey: .keyword),
            semantic: try c.decode(EngramServiceWebAvailability.self, forKey: .semantic),
            hybrid: try c.decode(EngramServiceWebAvailability.self, forKey: .hybrid),
            warning: try c.decodeIfPresent(String.self, forKey: .warning),
            warningCode: try c.decodeIfPresent(String.self, forKey: .warningCode),
            model: try c.decodeIfPresent(String.self, forKey: .model),
            dimension: try c.decodeIfPresent(Int.self, forKey: .dimension),
            eligibleSessionCount: try c.decodeIfPresent(Int64.self, forKey: .eligibleSessionCount),
            embeddedSessionCount: try c.decodeIfPresent(Int64.self, forKey: .embeddedSessionCount),
            progressPercent: try c.decodeIfPresent(Int.self, forKey: .progressPercent)
        )
        try V.time(observedAt)
        for availability in [keyword, semantic, hybrid] {
            try V.require(availability == .available || availability == .unavailable)
        }
        if let warning { try V.text(warning, maximumBytes: 1024) }
        if let warningCode { try V.token(warningCode, maximumBytes: 64) }
        if let model { try V.text(model, maximumBytes: 256, allowEmpty: false) }
        if let dimension { try V.require(dimension > 0) }
        if let eligibleSessionCount { try V.count(eligibleSessionCount) }
        if let embeddedSessionCount {
            try V.count(embeddedSessionCount)
            if let eligibleSessionCount { try V.require(embeddedSessionCount <= eligibleSessionCount) }
        }
        if let progressPercent { try V.require((0...100).contains(progressPercent)) }
        if progressPercent != nil {
            try V.require(eligibleSessionCount != nil && embeddedSessionCount != nil)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(keyword, forKey: .keyword)
        try c.encode(semantic, forKey: .semantic)
        try c.encode(hybrid, forKey: .hybrid)
        try c.encodeIfPresent(warning, forKey: .warning)
        try c.encodeIfPresent(warningCode, forKey: .warningCode)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(dimension, forKey: .dimension)
        try c.encodeIfPresent(eligibleSessionCount, forKey: .eligibleSessionCount)
        try c.encodeIfPresent(embeddedSessionCount, forKey: .embeddedSessionCount)
        try c.encodeIfPresent(progressPercent, forKey: .progressPercent)
    }
}

extension EngramServiceWebSessionDetailRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try c.decode(String.self, forKey: .sessionId)
        )
    }
}

extension EngramServiceWebFacetsRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: try c.decode(EngramServiceWebFacetKind.self, forKey: .kind),
            query: try c.decodeIfPresent(String.self, forKey: .query),
            agents: try c.decodeIfPresent(EngramServiceWebAgentFilter.self, forKey: .agents) ?? .hide,
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
            snapshotId: try c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor)
        )
    }
}

extension EngramServiceWebFacetItem {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try c.decode(String.self, forKey: .key),
            label: try c.decode(String.self, forKey: .label),
            sessionCount: try c.decode(Int64.self, forKey: .sessionCount)
        )
        try V.projectIdentity(key)
        try V.text(label, maximumBytes: 256, allowEmpty: false)
        try V.count(sessionCount)
    }
}

extension EngramServiceWebFacetsResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            items: try c.decode([EngramServiceWebFacetItem].self, forKey: .items),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor)
        )
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt)
        try V.require(Set(items.map { Data($0.key.utf8) }).count == items.count)
    }
}

extension EngramServiceWebStatsRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            groupBy: try c.decodeIfPresent(EngramServiceWebStatsGroupBy.self, forKey: .groupBy) ?? .source,
            since: try c.decodeIfPresent(String.self, forKey: .since),
            until: try c.decodeIfPresent(String.self, forKey: .until),
            excludeNoise: try c.decodeIfPresent(Bool.self, forKey: .excludeNoise) ?? false,
            agents: try c.decodeIfPresent(EngramServiceWebAgentFilter.self, forKey: .agents) ?? .hide,
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
            snapshotId: try c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor)
        )
    }
}

extension EngramServiceWebStatsTotals {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionCount: try c.decode(Int64.self, forKey: .sessionCount),
            messageCount: try c.decode(Int64.self, forKey: .messageCount),
            userMessageCount: try c.decode(Int64.self, forKey: .userMessageCount),
            assistantMessageCount: try c.decode(Int64.self, forKey: .assistantMessageCount),
            toolMessageCount: try c.decode(Int64.self, forKey: .toolMessageCount)
        )
        try V.statsCounts(self)
    }
}

extension EngramServiceWebStatsItem {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try c.decode(String.self, forKey: .key),
            label: try c.decode(String.self, forKey: .label),
            sessionCount: try c.decode(Int64.self, forKey: .sessionCount),
            messageCount: try c.decode(Int64.self, forKey: .messageCount),
            userMessageCount: try c.decode(Int64.self, forKey: .userMessageCount),
            assistantMessageCount: try c.decode(Int64.self, forKey: .assistantMessageCount),
            toolMessageCount: try c.decode(Int64.self, forKey: .toolMessageCount)
        )
        try V.text(key, maximumBytes: 128, allowEmpty: false)
        try V.text(label, maximumBytes: 256, allowEmpty: false)
        try V.statsCounts(self)
    }
}

extension EngramServiceWebStatsResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            groupBy: try c.decode(EngramServiceWebStatsGroupBy.self, forKey: .groupBy),
            timeZone: try c.decode(String.self, forKey: .timeZone),
            totals: try c.decode(EngramServiceWebStatsTotals.self, forKey: .totals),
            items: try c.decode([EngramServiceWebStatsItem].self, forKey: .items),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor)
        )
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt)
        try V.timeZone(timeZone)
        try V.totalsCover(totals, items: items)
        try V.require(Set(items.map { Data($0.key.utf8) }).count == items.count)
        for item in items { try V.statsKey(item.key, groupBy: groupBy) }
    }
}

extension EngramServiceWebSettingsRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
            snapshotId: try c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor)
        )
    }
}

extension EngramServiceWebSettingsSource {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decode(String.self, forKey: .key), label: try c.decode(String.self, forKey: .label))
        try V.settingsSource(self)
    }
}

extension EngramServiceWebSettingsAlias {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            alias: try c.decode(String.self, forKey: .alias),
            canonical: try c.decode(String.self, forKey: .canonical),
            aliasLabel: try c.decode(String.self, forKey: .aliasLabel),
            canonicalLabel: try c.decode(String.self, forKey: .canonicalLabel)
        )
        try V.settingsAlias(self)
    }
}

extension EngramServiceWebSettingsRetiredField {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: AnyKey.self)
        try V.require(c.allKeys.map(\.stringValue) == ["availability"])
        let availability = try c.decode(EngramServiceWebAvailability.self, forKey: AnyKey("availability"))
        try V.require(availability == .unavailable)
        self.init()
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ string: String) { self.stringValue = string; self.intValue = nil }
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }
}

extension EngramServiceWebSettingsResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            sources: try c.decode([EngramServiceWebSettingsSource].self, forKey: .sources),
            totalSessions: try c.decode(Int64.self, forKey: .totalSessions),
            aliases: try c.decode([EngramServiceWebSettingsAlias].self, forKey: .aliases),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor),
            nodeName: try c.decode(EngramServiceWebSettingsRetiredField.self, forKey: .nodeName),
            peers: try c.decode(EngramServiceWebSettingsRetiredField.self, forKey: .peers),
            port: try c.decode(EngramServiceWebSettingsRetiredField.self, forKey: .port)
        )
        try V.page(snapshotId: snapshotId, count: aliases.count, nextCursor: nextCursor)
        try V.time(observedAt)
        try V.count(totalSessions)
        try V.require(Set(sources.map { Data($0.key.utf8) }).count == sources.count)
        try V.require(Set(aliases.map { Data(($0.canonical + "\u{1E}" + $0.alias).utf8) }).count == aliases.count)
        for source in sources { try V.settingsSource(source) }
        for alias in aliases { try V.settingsAlias(alias) }
        try V.retiredUnavailable(nodeName)
        try V.retiredUnavailable(peers)
        try V.retiredUnavailable(port)
    }
}

extension EngramServiceWebSourceBinding {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try c.decode(String.self, forKey: .source),
            approvedEpoch: try c.decode(String.self, forKey: .approvedEpoch),
            authorityGeneration: try c.decode(String.self, forKey: .authorityGeneration)
        )
        try V.source(source)
        try V.uuid(approvedEpoch)
        try V.positiveDecimal(authorityGeneration)
    }
}

extension EngramServiceWebIngestTaskCounts {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pending: try c.decode(Int64.self, forKey: .pending),
            processing: try c.decode(Int64.self, forKey: .processing),
            parsed: try c.decode(Int64.self, forKey: .parsed),
            indexReady: try c.decode(Int64.self, forKey: .indexReady),
            retryableFailure: try c.decode(Int64.self, forKey: .retryableFailure),
            quarantined: try c.decode(Int64.self, forKey: .quarantined)
        )
        try V.count(pending)
        try V.count(processing)
        try V.count(parsed)
        try V.count(indexReady)
        try V.count(retryableFailure)
        try V.count(quarantined)
    }
}

extension EngramServiceWebIngestObservation {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            publicationCount: try c.decode(Int64.self, forKey: .publicationCount),
            taskCounts: try c.decode(EngramServiceWebIngestTaskCounts.self, forKey: .taskCounts),
            parseFailureTasks: try c.decode(Int64.self, forKey: .parseFailureTasks),
            oldestPendingAt: try c.decodeIfPresent(Int64.self, forKey: .oldestPendingAt)
        )
        try V.count(publicationCount)
        try V.count(parseFailureTasks)
        try V.require(parseFailureTasks <= taskCounts.retryableFailure + taskCounts.quarantined)
        if let oldestPendingAt { try V.time(oldestPendingAt) }
    }
}

extension EngramServiceWebCaptureObservation {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            manifestSHA256: try c.decode(String.self, forKey: .manifestSHA256),
            observedAt: try c.decode(Int64.self, forKey: .observedAt)
        )
        try V.hash(manifestSHA256)
        try V.time(observedAt)
    }
}

extension EngramServiceWebReplicaACKObservation {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            serverId: try c.decode(String.self, forKey: .serverId),
            publicationSHA256: try c.decode(String.self, forKey: .publicationSHA256),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            lagSeconds: try c.decodeIfPresent(Int64.self, forKey: .lagSeconds)
        )
        try V.token(serverId, maximumBytes: 128, allowDot: true)
        try V.hash(publicationSHA256)
        try V.time(observedAt)
        if let lagSeconds { try V.count(lagSeconds) }
    }
}

extension EngramServiceWebFTSObservation {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            readyLogicalSessions: try c.decode(Int64.self, forKey: .readyLogicalSessions)
        )
        try V.time(observedAt)
        try V.count(readyLogicalSessions)
    }
}

extension EngramServiceWebAIObservation {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            state: try c.decode(EngramServiceWebAIState.self, forKey: .state)
        )
        try V.time(observedAt)
    }
}

extension EngramServiceWebStreamOverview {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            machineId: try c.decode(String.self, forKey: .machineId),
            sourceInstanceId: try c.decode(String.self, forKey: .sourceInstanceId),
            registry: try c.decodeIfPresent(EngramServiceWebSourceBinding.self, forKey: .registry),
            ingest: try c.decodeIfPresent(EngramServiceWebIngestObservation.self, forKey: .ingest),
            heartbeatAt: try c.decodeIfPresent(Int64.self, forKey: .heartbeatAt),
            lastCapture: try c.decodeIfPresent(EngramServiceWebCaptureObservation.self, forKey: .lastCapture),
            replicaACKs: try c.decodeIfPresent([EngramServiceWebReplicaACKObservation].self, forKey: .replicaACKs),
            fts: try c.decodeIfPresent(EngramServiceWebFTSObservation.self, forKey: .fts),
            ai: try c.decodeIfPresent(EngramServiceWebAIObservation.self, forKey: .ai)
        )
        try V.uuid(machineId)
        try V.uuid(sourceInstanceId)
        if let heartbeatAt { try V.time(heartbeatAt) }
        if let replicaACKs {
            try V.require(replicaACKs.count <= 16 && Set(replicaACKs.map(\.serverId)).count == replicaACKs.count)
        }
    }
}

extension EngramServiceWebOverviewResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            capabilities: try c.decode(EngramServiceWebCapabilities.self, forKey: .capabilities),
            streams: try c.decode([EngramServiceWebStreamOverview].self, forKey: .streams),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor)
        )
        try V.page(snapshotId: snapshotId, count: streams.count, nextCursor: nextCursor)
        try V.time(observedAt)
        try V.require(Set(streams.map { $0.machineId + "/" + $0.sourceInstanceId }).count == streams.count)
    }
}

extension EngramServiceWebCaptureIdentity {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            machineId: try c.decode(String.self, forKey: .machineId),
            sourceInstanceId: try c.decode(String.self, forKey: .sourceInstanceId)
        )
        try V.uuid(machineId)
        try V.uuid(sourceInstanceId)
    }
}

extension EngramServiceWebSessionSummary {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionId: try c.decode(String.self, forKey: .sessionId),
            source: try c.decode(String.self, forKey: .source),
            captureIdentity: try c.decodeIfPresent(EngramServiceWebCaptureIdentity.self, forKey: .captureIdentity),
            metadataGeneration: try c.decodeIfPresent(String.self, forKey: .metadataGeneration),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            projectKey: try c.decodeIfPresent(String.self, forKey: .projectKey),
            projectLabel: try c.decodeIfPresent(String.self, forKey: .projectLabel),
            startedAt: try c.decodeIfPresent(Int64.self, forKey: .startedAt),
            isAgent: try c.decodeIfPresent(Bool.self, forKey: .isAgent),
            userMessageCount: try c.decodeIfPresent(Int.self, forKey: .userMessageCount),
            assistantMessageCount: try c.decodeIfPresent(Int.self, forKey: .assistantMessageCount),
            systemMessageCount: try c.decodeIfPresent(Int.self, forKey: .systemMessageCount),
            nativeId: try c.decodeIfPresent(String.self, forKey: .nativeId)
        )
        try V.sessionID(sessionId)
        try V.source(source)
        if let metadataGeneration { try V.hash(metadataGeneration) }
        if let title { try V.text(title, maximumBytes: 1024) }
        if let projectKey { try V.projectIdentity(projectKey) }
        if let projectLabel { try V.text(projectLabel, maximumBytes: 256) }
        if let startedAt { try V.time(startedAt) }
        for count in [userMessageCount, assistantMessageCount, systemMessageCount] {
            if let count { try V.require((0...EngramServiceWebReadLimits.maximumMessages).contains(count)) }
        }
        if let nativeId { try V.sessionID(nativeId) }
    }
}

extension EngramServiceWebSessionsResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            items: try c.decode([EngramServiceWebSessionSummary].self, forKey: .items),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor),
            totalCount: try c.decodeIfPresent(Int64.self, forKey: .totalCount),
            warning: try c.decodeIfPresent(String.self, forKey: .warning),
            warningCode: try c.decodeIfPresent(String.self, forKey: .warningCode)
        )
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt)
        if let totalCount {
            try V.count(totalCount)
            try V.require(totalCount >= Int64(items.count))
        }
        try V.require(Set(items.map { Data($0.sessionId.utf8) }).count == items.count)
        if let warning { try V.text(warning, maximumBytes: 1024) }
        if let warningCode { try V.token(warningCode, maximumBytes: 64) }
        try V.require((warning == nil) == (warningCode == nil))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(snapshotId, forKey: .snapshotId)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(nextCursor, forKey: .nextCursor)
        try c.encodeIfPresent(totalCount, forKey: .totalCount)
        try c.encodeIfPresent(warning, forKey: .warning)
        try c.encodeIfPresent(warningCode, forKey: .warningCode)
    }
}

extension EngramServiceWebGenerationSummary {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            generationId: try c.decode(String.self, forKey: .generationId),
            publicationSHA256: try c.decode(String.self, forKey: .publicationSHA256),
            parserRevision: try c.decode(String.self, forKey: .parserRevision),
            collectorEpoch: try c.decode(String.self, forKey: .collectorEpoch),
            authorityGeneration: try c.decode(String.self, forKey: .authorityGeneration),
            sequence: try c.decode(String.self, forKey: .sequence),
            committedAt: try c.decodeIfPresent(Int64.self, forKey: .committedAt),
            normalizedMessageCount: try c.decode(Int.self, forKey: .normalizedMessageCount)
        )
        try V.hash(generationId)
        try V.hash(publicationSHA256)
        try V.trimmed(parserRevision, maximumBytes: 128)
        try V.uuid(collectorEpoch)
        try V.positiveDecimal(authorityGeneration)
        try V.positiveDecimal(sequence)
        if let committedAt { try V.time(committedAt) }
        try V.require((0...EngramServiceWebReadLimits.maximumMessages).contains(normalizedMessageCount))
    }
}

extension EngramServiceWebSessionAttempt {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            publicationSHA256: try c.decode(String.self, forKey: .publicationSHA256),
            parserRevision: try c.decode(String.self, forKey: .parserRevision),
            collectorEpoch: try c.decode(String.self, forKey: .collectorEpoch),
            sequence: try c.decode(String.self, forKey: .sequence),
            status: try c.decode(EngramServiceWebIngestStatus.self, forKey: .status),
            failureCode: try c.decodeIfPresent(String.self, forKey: .failureCode),
            recordedAt: try c.decodeIfPresent(Int64.self, forKey: .recordedAt)
        )
        try V.hash(publicationSHA256)
        try V.trimmed(parserRevision, maximumBytes: 128)
        try V.uuid(collectorEpoch)
        try V.positiveDecimal(sequence)
        if let failureCode { try V.require(V.failureCodes.contains(failureCode)) }
        if let recordedAt { try V.time(recordedAt) }
    }
}

extension EngramServiceWebSessionDetail {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let summary = try c.decodeIfPresent(String.self, forKey: .summary)
        if let summary {
            try V.text(summary, maximumBytes: EngramServiceWebReadLimits.maximumSessionSummaryBytes, allowEmpty: false)
        }
        self.init(
            session: try c.decode(EngramServiceWebSessionSummary.self, forKey: .session),
            lastParsed: try c.decodeIfPresent(EngramServiceWebGenerationSummary.self, forKey: .lastParsed),
            lastReady: try c.decodeIfPresent(EngramServiceWebGenerationSummary.self, forKey: .lastReady),
            transcriptAvailability: try c.decode(EngramServiceWebAvailability.self, forKey: .transcriptAvailability),
            transcriptGeneration: try c.decodeIfPresent(String.self, forKey: .transcriptGeneration),
            currentAttempt: try c.decodeIfPresent(EngramServiceWebSessionAttempt.self, forKey: .currentAttempt),
            summary: summary
        )
        if let transcriptGeneration { try V.hash(transcriptGeneration) }
        if transcriptAvailability == .available {
            guard let parsed = lastParsed, let ready = lastReady, let generation = transcriptGeneration else {
                throw EngramServiceWebReadError.invalidField("metadata")
            }
            try V.require(parsed == ready && parsed.parserRevision.utf8.elementsEqual(ready.parserRevision.utf8)
                && parsed.generationId == generation && session.metadataGeneration == generation)
        } else {
            try V.require(transcriptGeneration == nil)
        }
    }
}

extension EngramServiceWebSessionDetailResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            detail: try c.decodeIfPresent(EngramServiceWebSessionDetail.self, forKey: .detail)
        )
        try V.time(observedAt)
    }
}

extension EngramServiceWebCostsRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: try c.decodeIfPresent(String.self, forKey: .source),
            sources: try c.decodeIfPresent([String].self, forKey: .sources),
            machineId: try c.decodeIfPresent(String.self, forKey: .machineId),
            sourceInstanceId: try c.decodeIfPresent(String.self, forKey: .sourceInstanceId),
            projectKey: try c.decodeIfPresent(String.self, forKey: .projectKey),
            projectKeys: try c.decodeIfPresent([String].self, forKey: .projectKeys),
            sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId),
            agents: try c.decodeIfPresent(EngramServiceWebAgentFilter.self, forKey: .agents) ?? .hide,
            since: try c.decodeIfPresent(String.self, forKey: .since),
            until: try c.decodeIfPresent(String.self, forKey: .until),
            tools: try c.decodeIfPresent(EngramServiceWebToolFilter.self, forKey: .tools) ?? .all,
            groupBy: try c.decodeIfPresent(EngramServiceWebCostsGroupBy.self, forKey: .groupBy) ?? .model,
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
            snapshotId: try c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(sources, forKey: .sources)
        try c.encodeIfPresent(machineId, forKey: .machineId)
        try c.encodeIfPresent(sourceInstanceId, forKey: .sourceInstanceId)
        try c.encodeIfPresent(projectKey, forKey: .projectKey)
        try c.encodeIfPresent(projectKeys, forKey: .projectKeys)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(agents, forKey: .agents)
        try c.encodeIfPresent(since, forKey: .since)
        try c.encodeIfPresent(until, forKey: .until)
        if tools != .all { try c.encode(tools, forKey: .tools) }
        if groupBy != .model { try c.encode(groupBy, forKey: .groupBy) }
        try c.encode(limit, forKey: .limit)
        try c.encodeIfPresent(snapshotId, forKey: .snapshotId)
        try c.encodeIfPresent(cursor, forKey: .cursor)
    }
}

extension EngramServiceWebCostTotals {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            costUsd: try c.decode(Double.self, forKey: .costUsd),
            inputTokens: try c.decode(Int64.self, forKey: .inputTokens),
            outputTokens: try c.decode(Int64.self, forKey: .outputTokens),
            cacheReadTokens: try c.decode(Int64.self, forKey: .cacheReadTokens),
            cacheCreationTokens: try c.decode(Int64.self, forKey: .cacheCreationTokens),
            sessionCount: try c.decode(Int64.self, forKey: .sessionCount)
        )
        try V.costsCounts(self)
    }
}

extension EngramServiceWebCostItem {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try c.decode(String.self, forKey: .key),
            label: try c.decode(String.self, forKey: .label),
            costUsd: try c.decode(Double.self, forKey: .costUsd),
            inputTokens: try c.decode(Int64.self, forKey: .inputTokens),
            outputTokens: try c.decode(Int64.self, forKey: .outputTokens),
            cacheReadTokens: try c.decode(Int64.self, forKey: .cacheReadTokens),
            cacheCreationTokens: try c.decode(Int64.self, forKey: .cacheCreationTokens),
            sessionCount: try c.decode(Int64.self, forKey: .sessionCount)
        )
        try V.text(key, maximumBytes: 128, allowEmpty: false)
        try V.text(label, maximumBytes: 256, allowEmpty: false)
        try V.costsCounts(self)
    }
}

extension EngramServiceWebCostsResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            groupBy: try c.decode(EngramServiceWebCostsGroupBy.self, forKey: .groupBy),
            timeZone: try c.decode(String.self, forKey: .timeZone),
            totals: try c.decode(EngramServiceWebCostTotals.self, forKey: .totals),
            items: try c.decode([EngramServiceWebCostItem].self, forKey: .items),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor),
            unpricedUnattributedSessions: try c.decodeIfPresent(Int.self, forKey: .unpricedUnattributedSessions),
            unpricedNoPriceSessions: try c.decodeIfPresent(Int.self, forKey: .unpricedNoPriceSessions),
            unpricedUnattributedTokens: try c.decodeIfPresent(Int.self, forKey: .unpricedUnattributedTokens),
            unpricedNoPriceTokens: try c.decodeIfPresent(Int.self, forKey: .unpricedNoPriceTokens)
        )
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt)
        try V.timeZone(timeZone)
        try V.costsCover(totals, items: items)
        try V.require(Set(items.map { Data($0.key.utf8) }).count == items.count)
        for item in items { try V.costsKey(item.key, groupBy: groupBy) }
        try V.unpricedCount(unpricedUnattributedSessions)
        try V.unpricedCount(unpricedNoPriceSessions)
        try V.unpricedCount(unpricedUnattributedTokens)
        try V.unpricedCount(unpricedNoPriceTokens)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(snapshotId, forKey: .snapshotId)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(groupBy, forKey: .groupBy)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(totals, forKey: .totals)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(nextCursor, forKey: .nextCursor)
        try c.encodeIfPresent(unpricedUnattributedSessions, forKey: .unpricedUnattributedSessions)
        try c.encodeIfPresent(unpricedNoPriceSessions, forKey: .unpricedNoPriceSessions)
        try c.encodeIfPresent(unpricedUnattributedTokens, forKey: .unpricedUnattributedTokens)
        try c.encodeIfPresent(unpricedNoPriceTokens, forKey: .unpricedNoPriceTokens)
    }
}

extension EngramServiceWebCostSessionsRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: try c.decodeIfPresent(String.self, forKey: .source),
            sources: try c.decodeIfPresent([String].self, forKey: .sources),
            machineId: try c.decodeIfPresent(String.self, forKey: .machineId),
            sourceInstanceId: try c.decodeIfPresent(String.self, forKey: .sourceInstanceId),
            projectKey: try c.decodeIfPresent(String.self, forKey: .projectKey),
            projectKeys: try c.decodeIfPresent([String].self, forKey: .projectKeys),
            sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId),
            agents: try c.decodeIfPresent(EngramServiceWebAgentFilter.self, forKey: .agents) ?? .hide,
            since: try c.decodeIfPresent(String.self, forKey: .since),
            until: try c.decodeIfPresent(String.self, forKey: .until),
            tools: try c.decodeIfPresent(EngramServiceWebToolFilter.self, forKey: .tools) ?? .all,
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 20
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(sources, forKey: .sources)
        try c.encodeIfPresent(machineId, forKey: .machineId)
        try c.encodeIfPresent(sourceInstanceId, forKey: .sourceInstanceId)
        try c.encodeIfPresent(projectKey, forKey: .projectKey)
        try c.encodeIfPresent(projectKeys, forKey: .projectKeys)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(agents, forKey: .agents)
        try c.encodeIfPresent(since, forKey: .since)
        try c.encodeIfPresent(until, forKey: .until)
        if tools != .all { try c.encode(tools, forKey: .tools) }
        try c.encode(limit, forKey: .limit)
    }
}

extension EngramServiceWebCostSessionItem {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            session: try c.decode(EngramServiceWebSessionSummary.self, forKey: .session),
            costUsd: try c.decode(Double.self, forKey: .costUsd),
            model: try c.decodeIfPresent(String.self, forKey: .model),
            inputTokens: try c.decode(Int64.self, forKey: .inputTokens),
            outputTokens: try c.decode(Int64.self, forKey: .outputTokens),
            cacheReadTokens: try c.decode(Int64.self, forKey: .cacheReadTokens),
            cacheCreationTokens: try c.decode(Int64.self, forKey: .cacheCreationTokens)
        )
        try V.money(costUsd)
        if let model { try V.text(model, maximumBytes: 128, allowEmpty: false) }
        try V.count(inputTokens)
        try V.count(outputTokens)
        try V.count(cacheReadTokens)
        try V.count(cacheCreationTokens)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(session, forKey: .session)
        try c.encode(costUsd, forKey: .costUsd)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
    }
}

extension EngramServiceWebCostSessionsResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            items: try c.decode([EngramServiceWebCostSessionItem].self, forKey: .items)
        )
        try V.time(observedAt)
        try V.require(items.count <= 100)
        try V.require(Set(items.map { Data($0.session.sessionId.utf8) }).count == items.count)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(items, forKey: .items)
    }
}

struct EngramServiceWebSourceControl: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let enabled: Bool
}

struct EngramServiceWebSourceSettingsResponse: Codable, Equatable, Sendable {
    let sources: [EngramServiceWebSourceControl]

    init(sources: [EngramServiceWebSourceControl]) throws {
        try EngramServiceWebSourceSettingsValidation.response(sources)
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(sources: try container.decode([EngramServiceWebSourceControl].self, forKey: .sources))
    }
}

enum EngramServiceWebSourceSettingsValidation {
    static let knownKeys: Set<String> = [
        "antigravity", "claude-code", "cline", "codex", "commandcode", "copilot",
        "cursor", "gemini-cli", "grok", "iflow", "kimi", "lobsterai", "minimax",
        "opencode", "pi", "qoder", "qwen", "vscode", "windsurf",
    ]

    static func label(for key: String) -> String {
        switch key {
        case "claude-code": return "Claude Code"
        case "gemini-cli": return "Gemini CLI"
        case "opencode": return "OpenCode"
        case "commandcode": return "Command Code"
        case "lobsterai": return "Lobster AI"
        case "vscode": return "VS Code"
        default:
            return key.split(separator: "-").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: " ")
        }
    }

    static func sourceKey(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try EngramServiceWebMetadataValidation.require(knownKeys.contains(trimmed))
        return trimmed
    }

    static func response(_ sources: [EngramServiceWebSourceControl]) throws {
        try EngramServiceWebMetadataValidation.require(!sources.isEmpty)
        var seen = Set<String>()
        var previous: String?
        for item in sources {
            try EngramServiceWebMetadataValidation.require(knownKeys.contains(item.key))
            try EngramServiceWebMetadataValidation.require(seen.insert(item.key).inserted)
            try EngramServiceWebMetadataValidation.require(item.label == label(for: item.key))
            try EngramServiceWebMetadataValidation.require(!item.label.utf8.contains(0))
            if let previous {
                try EngramServiceWebMetadataValidation.require(previous < item.key)
            }
            previous = item.key
        }
    }

    static func projection(enabledSources: Set<String>) throws -> EngramServiceWebSourceSettingsResponse {
        try EngramServiceWebSourceSettingsResponse(
            sources: knownKeys.sorted().map { key in
                EngramServiceWebSourceControl(
                    key: key, label: label(for: key), enabled: enabledSources.contains(key)
                )
            }
        )
    }
}

extension EngramServiceWebChildrenRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try c.decode(String.self, forKey: .sessionId),
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? EngramServiceWebReadLimits.defaultChildrenLimit,
            snapshotId: try c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor)
        )
    }
}

extension EngramServiceWebChildrenResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionId: try c.decode(String.self, forKey: .sessionId),
            snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            items: try c.decode([EngramServiceWebChildItem].self, forKey: .items),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor)
        )
        try V.sessionID(sessionId)
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt)
        try V.require(Set(items.map { Data($0.session.sessionId.utf8) }).count == items.count)
    }
}

extension EngramServiceWebTimelineRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try c.decode(String.self, forKey: .sessionId),
            generation: try c.decode(String.self, forKey: .generation),
            offset: try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? EngramServiceWebReadLimits.defaultTimelineLimit
        )
    }
}

extension EngramServiceWebTimelineEntry {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            index: try c.decode(Int.self, forKey: .index),
            role: try c.decode(EngramServiceWebMessageRole.self, forKey: .role),
            type: try c.decode(EngramServiceWebTimelineEntryType.self, forKey: .type),
            preview: try c.decode(String.self, forKey: .preview),
            timestamp: try c.decodeIfPresent(String.self, forKey: .timestamp),
            toolName: try c.decodeIfPresent(String.self, forKey: .toolName),
            tokens: try c.decodeIfPresent(EngramServiceWebTimelineTokens.self, forKey: .tokens),
            durationToNextMs: try c.decodeIfPresent(Int.self, forKey: .durationToNextMs)
        )
        try V.require((0..<EngramServiceWebReadLimits.maximumMessages).contains(index))
        try V.text(preview, maximumBytes: 4096)
        try V.require(preview.count <= EngramServiceWebReadLimits.maximumTimelinePreviewCharacters)
        if let timestamp { try V.text(timestamp, maximumBytes: 128, allowEmpty: false) }
        if let toolName { try V.text(toolName, maximumBytes: 256, allowEmpty: false) }
        if let tokens {
            try V.require(tokens.input >= 0 && tokens.output >= 0)
        }
        if let durationToNextMs { try V.require(durationToNextMs >= 0) }
    }
}

extension EngramServiceWebTimelineResponse {
    init(from decoder: Decoder) throws {
        typealias V = EngramServiceWebMetadataValidation
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionId: try c.decode(String.self, forKey: .sessionId),
            generation: try c.decode(String.self, forKey: .generation),
            totalEntries: try c.decode(Int.self, forKey: .totalEntries),
            entries: try c.decode([EngramServiceWebTimelineEntry].self, forKey: .entries),
            nextOffset: try c.decodeIfPresent(Int.self, forKey: .nextOffset)
        )
        try EngramServiceWebReadValidation.identity(sessionId: sessionId, generation: generation)
        try V.require((0...EngramServiceWebReadLimits.maximumMessages).contains(totalEntries))
        try V.require(entries.count <= EngramServiceWebReadLimits.maximumTimelineLimit)
        try V.require(totalEntries >= entries.count)
        if let nextOffset {
            try V.require((0...EngramServiceWebReadLimits.maximumMessages).contains(nextOffset))
            try V.require(!entries.isEmpty)
            try V.require(nextOffset <= totalEntries)
        }
        for (previous, current) in zip(entries, entries.dropFirst()) {
            try V.require(previous.index < current.index)
        }
    }
}

enum EngramServiceWebToolAnalyticsGroupBy: String, Codable, Equatable, Sendable {
    case tool, session, project
}

struct EngramServiceWebToolAnalyticsRequest: Codable, Equatable, Sendable {
    let project: String?
    let since: String?
    let until: String?
    let agents: EngramServiceWebAgentFilter
    let groupBy: EngramServiceWebToolAnalyticsGroupBy
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(project: String? = nil, since: String? = nil, until: String? = nil,
         agents: EngramServiceWebAgentFilter = .hide,
         groupBy: EngramServiceWebToolAnalyticsGroupBy = .tool, limit: Int = 50,
         snapshotId: String? = nil, cursor: String? = nil) throws {
        if let project { try EngramServiceWebMetadataValidation.text(project, maximumBytes: 1024, allowEmpty: false) }
        try EngramServiceWebMetadataValidation.dateRange(since: since, until: until)
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        self.project = project; self.since = since; self.until = until
        self.agents = agents; self.groupBy = groupBy; self.limit = limit
        self.snapshotId = snapshotId; self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(project: c.decodeIfPresent(String.self, forKey: .project),
            since: c.decodeIfPresent(String.self, forKey: .since), until: c.decodeIfPresent(String.self, forKey: .until),
            agents: c.decodeIfPresent(EngramServiceWebAgentFilter.self, forKey: .agents) ?? .hide,
            groupBy: c.decodeIfPresent(EngramServiceWebToolAnalyticsGroupBy.self, forKey: .groupBy) ?? .tool,
            limit: c.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
            snapshotId: c.decodeIfPresent(String.self, forKey: .snapshotId), cursor: c.decodeIfPresent(String.self, forKey: .cursor))
    }
}

struct EngramServiceWebToolAnalyticsItem: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let callCount: Int64
    let sessionCount: Int64
    let toolCount: Int64
    let sessionId: String?
}

struct EngramServiceWebToolAnalyticsResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let groupBy: EngramServiceWebToolAnalyticsGroupBy
    let totalCalls: Int64
    let groupCount: Int
    let items: [EngramServiceWebToolAnalyticsItem]
    let nextCursor: String?

    init(snapshotId: String, observedAt: Int64, groupBy: EngramServiceWebToolAnalyticsGroupBy,
         totalCalls: Int64, groupCount: Int, items: [EngramServiceWebToolAnalyticsItem], nextCursor: String?) {
        self.snapshotId = snapshotId; self.observedAt = observedAt; self.groupBy = groupBy
        self.totalCalls = totalCalls; self.groupCount = groupCount; self.items = items; self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            groupBy: try c.decode(EngramServiceWebToolAnalyticsGroupBy.self, forKey: .groupBy),
            totalCalls: try c.decode(Int64.self, forKey: .totalCalls), groupCount: try c.decode(Int.self, forKey: .groupCount),
            items: try c.decode([EngramServiceWebToolAnalyticsItem].self, forKey: .items),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor))
        typealias V = EngramServiceWebMetadataValidation
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt); try V.count(totalCalls); try V.count(Int64(groupCount))
        try V.require(groupCount >= items.count && Set(items.map { Data($0.key.utf8) }).count == items.count)
        var pageCalls: Int64 = 0
        for item in items {
            try V.text(item.key, maximumBytes: EngramServiceWebReadLimits.maximumSessionIDBytes, allowEmpty: false)
            try V.text(item.label, maximumBytes: 1024, allowEmpty: false)
            try V.count(item.callCount); try V.count(item.sessionCount); try V.count(item.toolCount)
            try V.require(item.callCount > 0 && item.sessionCount > 0 && item.toolCount > 0)
            try V.require(item.callCount <= totalCalls && item.sessionCount <= item.callCount && item.toolCount <= item.callCount)
            if groupBy == .session {
                try V.require(item.sessionId == item.key && item.sessionCount == 1)
                try V.sessionID(item.key)
            } else { try V.require(item.sessionId == nil) }
            if groupBy == .tool { try V.require(item.toolCount == 1) }
            let (sum, overflow) = pageCalls.addingReportingOverflow(item.callCount)
            try V.require(!overflow && sum <= totalCalls); pageCalls = sum
        }
    }
}

struct EngramServiceWebFileActivityRequest: Codable, Equatable, Sendable {
    let project: String?
    let since: String?
    let until: String?
    let agents: EngramServiceWebAgentFilter
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(project: String? = nil, since: String? = nil, until: String? = nil,
         agents: EngramServiceWebAgentFilter = .hide, limit: Int = 100,
         snapshotId: String? = nil, cursor: String? = nil) throws {
        if let project { try EngramServiceWebMetadataValidation.text(project, maximumBytes: 1024, allowEmpty: false) }
        try EngramServiceWebMetadataValidation.dateRange(since: since, until: until)
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        self.project = project; self.since = since; self.until = until
        self.agents = agents; self.limit = limit
        self.snapshotId = snapshotId; self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(project: c.decodeIfPresent(String.self, forKey: .project),
            since: c.decodeIfPresent(String.self, forKey: .since), until: c.decodeIfPresent(String.self, forKey: .until),
            agents: c.decodeIfPresent(EngramServiceWebAgentFilter.self, forKey: .agents) ?? .hide,
            limit: c.decodeIfPresent(Int.self, forKey: .limit) ?? 100,
            snapshotId: c.decodeIfPresent(String.self, forKey: .snapshotId), cursor: c.decodeIfPresent(String.self, forKey: .cursor))
    }
}

struct EngramServiceWebFileActivityItem: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let readCount: Int64
    let editCount: Int64
    let writeCount: Int64
    let sessionCount: Int64
}

struct EngramServiceWebFileActivityResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let totalFiles: Int
    let totalOperations: Int64
    let items: [EngramServiceWebFileActivityItem]
    let nextCursor: String?

    init(snapshotId: String, observedAt: Int64, totalFiles: Int, totalOperations: Int64,
         items: [EngramServiceWebFileActivityItem], nextCursor: String?) {
        self.snapshotId = snapshotId; self.observedAt = observedAt
        self.totalFiles = totalFiles; self.totalOperations = totalOperations
        self.items = items; self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            totalFiles: try c.decode(Int.self, forKey: .totalFiles),
            totalOperations: try c.decode(Int64.self, forKey: .totalOperations),
            items: try c.decode([EngramServiceWebFileActivityItem].self, forKey: .items),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor))
        typealias V = EngramServiceWebMetadataValidation
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt); try V.count(totalOperations); try V.count(Int64(totalFiles))
        try V.require(totalFiles >= items.count && Set(items.map { Data($0.key.utf8) }).count == items.count)
        var pageOperations: Int64 = 0
        for item in items {
            try V.text(item.key, maximumBytes: EngramServiceWebReadLimits.maximumSessionIDBytes, allowEmpty: false)
            try V.text(item.label, maximumBytes: 1024, allowEmpty: false)
            try V.count(item.readCount); try V.count(item.editCount)
            try V.count(item.writeCount); try V.count(item.sessionCount)
            let (partial, overflow) = item.readCount.addingReportingOverflow(item.editCount)
            try V.require(!overflow)
            let (operations, opsOverflow) = partial.addingReportingOverflow(item.writeCount)
            try V.require(!opsOverflow && operations > 0 && item.sessionCount > 0)
            try V.require(item.sessionCount <= operations && operations <= totalOperations)
            let (sum, pageOverflow) = pageOperations.addingReportingOverflow(operations)
            try V.require(!pageOverflow && sum <= totalOperations)
            pageOperations = sum
        }
    }
}

struct EngramServiceWebReposRequest: Codable, Equatable, Sendable {
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(limit: Int = 50, snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        self.limit = limit; self.snapshotId = snapshotId; self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(limit: c.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
            snapshotId: c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: c.decodeIfPresent(String.self, forKey: .cursor))
    }
}

struct EngramServiceWebRepoItem: Codable, Equatable, Sendable {
    let key: String
    let name: String
    let branch: String?
    let dirtyCount: Int64
    let untrackedCount: Int64
    let unpushedCount: Int64
    let lastCommitHash: String?
    let lastCommitMessage: String?
    let lastCommitAt: Int64?
    let sessionCount: Int64
    let probedAt: Int64?
}

struct EngramServiceWebReposResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let scope: String
    let totalRepos: Int
    let items: [EngramServiceWebRepoItem]
    let nextCursor: String?

    init(snapshotId: String, observedAt: Int64, scope: String = "serverFilesystem",
         totalRepos: Int, items: [EngramServiceWebRepoItem], nextCursor: String?) {
        self.snapshotId = snapshotId; self.observedAt = observedAt; self.scope = scope
        self.totalRepos = totalRepos; self.items = items; self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            scope: try c.decode(String.self, forKey: .scope),
            totalRepos: try c.decode(Int.self, forKey: .totalRepos),
            items: try c.decode([EngramServiceWebRepoItem].self, forKey: .items),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor))
        typealias V = EngramServiceWebMetadataValidation
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt); try V.count(Int64(totalRepos))
        try V.require(scope.utf8.elementsEqual("serverFilesystem".utf8))
        try V.require(totalRepos >= items.count && Set(items.map { Data($0.key.utf8) }).count == items.count)
        for item in items {
            try V.text(item.key, maximumBytes: EngramServiceWebReadLimits.maximumSessionIDBytes, allowEmpty: false)
            try V.text(item.name, maximumBytes: 1024, allowEmpty: false)
            try V.count(item.dirtyCount); try V.count(item.untrackedCount)
            try V.count(item.unpushedCount); try V.count(item.sessionCount)
            if let branch = item.branch { try V.text(branch, maximumBytes: 256, allowEmpty: false) }
            if let message = item.lastCommitMessage { try V.text(message, maximumBytes: 1024, allowEmpty: false) }
            if let hash = item.lastCommitHash {
                try V.require((7...64).contains(hash.utf8.count)
                    && hash.utf8.allSatisfy {
                        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                    })
            }
            if let lastCommitAt = item.lastCommitAt { try V.time(lastCommitAt) }
            if let probedAt = item.probedAt { try V.time(probedAt) }
        }
    }
}

struct EngramServiceWebAiAuditRequest: Codable, Equatable, Sendable {
    let caller: String?
    let model: String?
    let sessionId: String?
    let from: String?
    let to: String?
    let hasError: Bool?
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(caller: String? = nil, model: String? = nil, sessionId: String? = nil,
         from: String? = nil, to: String? = nil, hasError: Bool? = nil, limit: Int = 50,
         snapshotId: String? = nil, cursor: String? = nil) throws {
        if let caller { try EngramServiceWebMetadataValidation.text(caller, maximumBytes: 256, allowEmpty: false) }
        if let model { try EngramServiceWebMetadataValidation.text(model, maximumBytes: 256, allowEmpty: false) }
        if let sessionId { try EngramServiceWebMetadataValidation.sessionID(sessionId) }
        try EngramServiceWebMetadataValidation.dateRange(since: from, until: to)
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        self.caller = caller; self.model = model; self.sessionId = sessionId
        self.from = from; self.to = to; self.hasError = hasError; self.limit = limit
        self.snapshotId = snapshotId; self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(caller: c.decodeIfPresent(String.self, forKey: .caller),
            model: c.decodeIfPresent(String.self, forKey: .model),
            sessionId: c.decodeIfPresent(String.self, forKey: .sessionId),
            from: c.decodeIfPresent(String.self, forKey: .from), to: c.decodeIfPresent(String.self, forKey: .to),
            hasError: c.decodeIfPresent(Bool.self, forKey: .hasError),
            limit: c.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
            snapshotId: c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: c.decodeIfPresent(String.self, forKey: .cursor))
    }
}

struct EngramServiceWebAiAuditItem: Codable, Equatable, Sendable {
    let id: String
    let at: Int64
    let caller: String
    let operation: String
    let method: String?
    let url: String?
    let statusCode: Int64?
    let durationMs: Int64?
    let model: String?
    let provider: String?
    let promptTokens: Int64?
    let completionTokens: Int64?
    let totalTokens: Int64?
    let hasError: Bool
    let error: String?
    let sessionId: String?
}

struct EngramServiceWebAiAuditResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let total: Int
    let items: [EngramServiceWebAiAuditItem]
    let nextCursor: String?

    init(snapshotId: String, observedAt: Int64, total: Int,
         items: [EngramServiceWebAiAuditItem], nextCursor: String?) {
        self.snapshotId = snapshotId; self.observedAt = observedAt
        self.total = total; self.items = items; self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(snapshotId: try c.decode(String.self, forKey: .snapshotId),
            observedAt: try c.decode(Int64.self, forKey: .observedAt),
            total: try c.decode(Int.self, forKey: .total),
            items: try c.decode([EngramServiceWebAiAuditItem].self, forKey: .items),
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor))
        typealias V = EngramServiceWebMetadataValidation
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt); try V.count(Int64(total))
        try V.require(total >= items.count && Set(items.map { Data($0.id.utf8) }).count == items.count)
        for item in items { try V.aiAuditItem(item) }
    }
}

struct EngramServiceWebAiAuditDetailRequest: Codable, Equatable, Sendable {
    let id: String

    init(id: String) throws {
        try EngramServiceWebMetadataValidation.positiveDecimal(id)
        self.id = id
    }
}

struct EngramServiceWebAiAuditDetailResponse: Codable, Equatable, Sendable {
    let observedAt: Int64
    let item: EngramServiceWebAiAuditItem
    let hasRequestBody: Bool
    let hasResponseBody: Bool

    init(observedAt: Int64, item: EngramServiceWebAiAuditItem, hasRequestBody: Bool, hasResponseBody: Bool) {
        self.observedAt = observedAt; self.item = item
        self.hasRequestBody = hasRequestBody; self.hasResponseBody = hasResponseBody
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(observedAt: try c.decode(Int64.self, forKey: .observedAt),
            item: try c.decode(EngramServiceWebAiAuditItem.self, forKey: .item),
            hasRequestBody: try c.decode(Bool.self, forKey: .hasRequestBody),
            hasResponseBody: try c.decode(Bool.self, forKey: .hasResponseBody))
        try EngramServiceWebMetadataValidation.time(observedAt)
        try EngramServiceWebMetadataValidation.aiAuditItem(item)
    }
}

struct EngramServiceWebAiStatsRequest: Codable, Equatable, Sendable {
    let from: String?
    let to: String?

    init(from: String? = nil, to: String? = nil) throws {
        try EngramServiceWebMetadataValidation.dateRange(since: from, until: to)
        self.from = from; self.to = to
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(from: c.decodeIfPresent(String.self, forKey: .from),
            to: c.decodeIfPresent(String.self, forKey: .to))
    }
}

struct EngramServiceWebAiStatsTimeRange: Codable, Equatable, Sendable {
    let from: String
    let to: String
}

struct EngramServiceWebAiStatsTotals: Codable, Equatable, Sendable {
    let requests: Int64
    let errors: Int64
    let promptTokens: Int64
    let completionTokens: Int64
    let avgDurationMs: Int64
}

struct EngramServiceWebAiStatsCaller: Codable, Equatable, Sendable {
    let key: String
    let requests: Int64
    let errors: Int64
    let promptTokens: Int64
    let completionTokens: Int64
}

struct EngramServiceWebAiStatsModel: Codable, Equatable, Sendable {
    let key: String
    let requests: Int64
    let promptTokens: Int64
    let completionTokens: Int64
}

struct EngramServiceWebAiStatsHour: Codable, Equatable, Sendable {
    let hour: String
    let requests: Int64
    let tokens: Int64
}

struct EngramServiceWebAiStatsResponse: Codable, Equatable, Sendable {
    let observedAt: Int64
    let timeRange: EngramServiceWebAiStatsTimeRange
    let totals: EngramServiceWebAiStatsTotals
    let byCaller: [EngramServiceWebAiStatsCaller]
    let byModel: [EngramServiceWebAiStatsModel]
    let hourly: [EngramServiceWebAiStatsHour]

    init(observedAt: Int64, timeRange: EngramServiceWebAiStatsTimeRange, totals: EngramServiceWebAiStatsTotals,
         byCaller: [EngramServiceWebAiStatsCaller], byModel: [EngramServiceWebAiStatsModel],
         hourly: [EngramServiceWebAiStatsHour]) {
        self.observedAt = observedAt; self.timeRange = timeRange; self.totals = totals
        self.byCaller = byCaller; self.byModel = byModel; self.hourly = hourly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(observedAt: try c.decode(Int64.self, forKey: .observedAt),
            timeRange: try c.decode(EngramServiceWebAiStatsTimeRange.self, forKey: .timeRange),
            totals: try c.decode(EngramServiceWebAiStatsTotals.self, forKey: .totals),
            byCaller: try c.decode([EngramServiceWebAiStatsCaller].self, forKey: .byCaller),
            byModel: try c.decode([EngramServiceWebAiStatsModel].self, forKey: .byModel),
            hourly: try c.decode([EngramServiceWebAiStatsHour].self, forKey: .hourly))
        typealias V = EngramServiceWebMetadataValidation
        try V.time(observedAt)
        try V.aiStatsInterval(timeRange.from, timeRange.to)
        try V.count(totals.requests); try V.count(totals.errors)
        try V.count(totals.promptTokens); try V.count(totals.completionTokens)
        try V.count(totals.avgDurationMs)
        try V.require(totals.errors <= totals.requests)
        try V.require(Set(byCaller.map { Data($0.key.utf8) }).count == byCaller.count)
        try V.require(Set(byModel.map { Data($0.key.utf8) }).count == byModel.count)
        try V.require(Set(hourly.map { Data($0.hour.utf8) }).count == hourly.count)
        for (previous, current) in zip(byCaller, byCaller.dropFirst()) {
            try V.require(previous.key.utf8.lexicographicallyPrecedes(current.key.utf8))
        }
        for (previous, current) in zip(byModel, byModel.dropFirst()) {
            try V.require(previous.key.utf8.lexicographicallyPrecedes(current.key.utf8))
        }
        for (previous, current) in zip(hourly, hourly.dropFirst()) {
            try V.require(previous.hour.utf8.lexicographicallyPrecedes(current.hour.utf8))
        }
        for row in byCaller {
            try V.text(row.key, maximumBytes: 256, allowEmpty: false)
            try V.count(row.requests); try V.count(row.errors)
            try V.count(row.promptTokens); try V.count(row.completionTokens)
            try V.require(row.errors <= row.requests)
        }
        for row in byModel {
            try V.text(row.key, maximumBytes: 256, allowEmpty: false)
            try V.count(row.requests); try V.count(row.promptTokens); try V.count(row.completionTokens)
        }
        for row in hourly {
            try V.utcHour(row.hour)
            try V.count(row.requests); try V.count(row.tokens)
        }
    }
}
