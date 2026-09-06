import Foundation

enum EngramServiceWebReadLimits {
    static let projection = "redacted-normalized-message-json-v1"
    static let redactionRevision = "transcript-redaction-v1"
    static let maximumFrameBytes = 256 * 1024
    static let maximumPageEnvelopeBytes = maximumFrameBytes - 1024
    static let maximumSessionIDBytes = 4096
    static let maximumCursorBytes = 1024
    static let maximumFragments = 100
    static let maximumMessages = 10_000
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

struct EngramServiceWebOverviewRequest: Codable, Equatable, Sendable {
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

struct EngramServiceWebSessionsRequest: Codable, Equatable, Sendable {
    let query: String?
    let source: String?
    let machineId: String?
    let sourceInstanceId: String?
    let projectKey: String?
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(query: String? = nil, source: String? = nil, machineId: String? = nil,
         sourceInstanceId: String? = nil, projectKey: String? = nil, limit: Int = 50,
         snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.pageRequest(limit: limit, snapshotId: snapshotId, cursor: cursor)
        if let query { try EngramServiceWebMetadataValidation.trimmed(query, maximumBytes: 1024) }
        if let source { try EngramServiceWebMetadataValidation.source(source) }
        if let machineId { try EngramServiceWebMetadataValidation.uuid(machineId) }
        if let sourceInstanceId { try EngramServiceWebMetadataValidation.uuid(sourceInstanceId) }
        if let projectKey { try EngramServiceWebMetadataValidation.token(projectKey, maximumBytes: 128) }
        try EngramServiceWebMetadataValidation.require(sourceInstanceId == nil || machineId != nil)
        self.query = query
        self.source = source
        self.machineId = machineId
        self.sourceInstanceId = sourceInstanceId
        self.projectKey = projectKey
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
}

struct EngramServiceWebSessionsResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let items: [EngramServiceWebSessionSummary]
    let nextCursor: String?
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
}

struct EngramServiceWebSessionDetailResponse: Codable, Equatable, Sendable {
    let observedAt: Int64
    let detail: EngramServiceWebSessionDetail?
}

private enum EngramServiceWebMetadataValidation {
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

    static func count(_ value: Int64) throws { try require((0...maximumCount).contains(value)) }
    static func time(_ value: Int64) throws { try require((0...maximumTime).contains(value)) }

    static func pageRequest(limit: Int, snapshotId: String?, cursor: String?) throws {
        try require((1...100).contains(limit) && (snapshotId == nil) == (cursor == nil))
        if let snapshotId { try uuid(snapshotId) }
        if let cursor { try token(cursor, maximumBytes: EngramServiceWebReadLimits.maximumCursorBytes) }
    }

    static func page(snapshotId: String, count: Int, nextCursor: String?) throws {
        try uuid(snapshotId)
        try require(count <= 100 && (nextCursor == nil || count > 0))
        if let nextCursor { try token(nextCursor, maximumBytes: EngramServiceWebReadLimits.maximumCursorBytes) }
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
            machineId: try c.decodeIfPresent(String.self, forKey: .machineId),
            sourceInstanceId: try c.decodeIfPresent(String.self, forKey: .sourceInstanceId),
            projectKey: try c.decodeIfPresent(String.self, forKey: .projectKey),
            limit: try c.decode(Int.self, forKey: .limit),
            snapshotId: try c.decodeIfPresent(String.self, forKey: .snapshotId),
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor)
        )
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
            startedAt: try c.decodeIfPresent(Int64.self, forKey: .startedAt)
        )
        try V.sessionID(sessionId)
        try V.source(source)
        if let metadataGeneration { try V.hash(metadataGeneration) }
        if let title { try V.text(title, maximumBytes: 1024) }
        if let projectKey { try V.token(projectKey, maximumBytes: 128) }
        if let projectLabel { try V.text(projectLabel, maximumBytes: 256) }
        if let startedAt { try V.time(startedAt) }
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
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor)
        )
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt)
        try V.require(Set(items.map { Data($0.sessionId.utf8) }).count == items.count)
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
        self.init(
            session: try c.decode(EngramServiceWebSessionSummary.self, forKey: .session),
            lastParsed: try c.decodeIfPresent(EngramServiceWebGenerationSummary.self, forKey: .lastParsed),
            lastReady: try c.decodeIfPresent(EngramServiceWebGenerationSummary.self, forKey: .lastReady),
            transcriptAvailability: try c.decode(EngramServiceWebAvailability.self, forKey: .transcriptAvailability),
            transcriptGeneration: try c.decodeIfPresent(String.self, forKey: .transcriptGeneration),
            currentAttempt: try c.decodeIfPresent(EngramServiceWebSessionAttempt.self, forKey: .currentAttempt)
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
