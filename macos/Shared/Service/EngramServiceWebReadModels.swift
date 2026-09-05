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
