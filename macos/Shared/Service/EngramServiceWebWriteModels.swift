import CryptoKit
import Foundation

enum EngramServiceWebWriteClientError: Error, Equatable, LocalizedError, Sendable {
    case invalid
    case stale
    case unsupported
    case unavailable
    case notFound
    case malformed
    case project(EngramServiceWebProjectFailure)

    var errorDescription: String? {
        switch self {
        case .invalid: return "Web alias request is invalid."
        case .stale: return "Web alias authorization is stale."
        case .unsupported: return "Web alias writes are unsupported."
        case .unavailable: return "Web alias service is unavailable."
        case .notFound: return "Web write target was not found."
        case .malformed: return "Web alias response is invalid."
        case .project(let failure): return failure.message
        }
    }
}

/// ADD body: `canonical` is a published identity; `alias` is raw DB text.
struct EngramServiceWebAddAliasRequest: Codable, Equatable, Sendable {
    let canonical: String
    let alias: String

    init(canonical: String, alias: String) throws {
        try EngramServiceWebMetadataValidation.projectIdentity(canonical)
        let alias = try EngramServiceWebWriteValidation.aliasText(alias)
        let published = try EngramServiceWebWriteValidation.requirePublished(alias)
        try EngramServiceWebMetadataValidation.require(!published.utf8.elementsEqual(canonical.utf8))
        self.canonical = canonical
        self.alias = alias
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                canonical: try container.decode(String.self, forKey: .canonical),
                alias: try container.decode(String.self, forKey: .alias)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .alias, in: container, debugDescription: "invalid")
        }
    }
}

/// DELETE body: both fields are published identities from current Web settings.
struct EngramServiceWebRemoveAliasRequest: Codable, Equatable, Sendable {
    let alias: String
    let canonical: String

    init(alias: String, canonical: String) throws {
        try EngramServiceWebMetadataValidation.projectIdentity(alias)
        try EngramServiceWebMetadataValidation.projectIdentity(canonical)
        try EngramServiceWebMetadataValidation.require(!alias.utf8.elementsEqual(canonical.utf8))
        self.alias = alias
        self.canonical = canonical
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                alias: try container.decode(String.self, forKey: .alias),
                canonical: try container.decode(String.self, forKey: .canonical)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .alias, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebAliasMutationResponse: Codable, Equatable, Sendable {
    let action: String
    let alias: String
    let canonical: String
    let changed: Int

    init(action: String, alias: String, canonical: String, changed: Int) throws {
        try EngramServiceWebWriteValidation.mutation(
            action: action, alias: alias, canonical: canonical, changed: changed
        )
        self.action = action
        self.alias = alias
        self.canonical = canonical
        self.changed = changed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                action: try container.decode(String.self, forKey: .action),
                alias: try container.decode(String.self, forKey: .alias),
                canonical: try container.decode(String.self, forKey: .canonical),
                changed: try container.decode(Int.self, forKey: .changed)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "invalid")
        }
    }
}

enum EngramServiceWebWriteValidation {
    static let maximumAliasCharacters = 1_000

    /// Same published-key rules as `ServiceWebMetadataProducer.publishedProjectKey`.
    /// Token alphabet is redact-stable; other text hashes as `p.` + SHA-256 hex.
    static func publishedProjectKey(_ value: String) -> String? {
        guard !value.isEmpty, !value.utf8.contains(0) else { return nil }
        if value.utf8.count <= 128,
           value.utf8.allSatisfy({
               (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
           }) {
            return value
        }
        return "p." + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func requirePublished(_ value: String) throws -> String {
        guard let published = publishedProjectKey(value) else {
            throw EngramServiceWebReadError.invalidField("alias")
        }
        return published
    }

    static func aliasText(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try EngramServiceWebMetadataValidation.require(
            !trimmed.isEmpty
                && trimmed.count <= maximumAliasCharacters
                && !trimmed.utf8.contains(0)
        )
        return trimmed
    }

    static func mutation(action: String, alias: String, canonical: String, changed: Int) throws {
        try EngramServiceWebMetadataValidation.require(action == "add" || action == "remove")
        try EngramServiceWebMetadataValidation.projectIdentity(alias)
        try EngramServiceWebMetadataValidation.projectIdentity(canonical)
        try EngramServiceWebMetadataValidation.require(!alias.utf8.elementsEqual(canonical.utf8))
        try EngramServiceWebMetadataValidation.require(changed == 0 || changed == 1)
    }

    static let relationshipActions: Set<String> = [
        "link", "unlink", "confirmSuggestion", "dismissSuggestion",
    ]

    static func relationship(sessionId: String, action: String, ok: Bool) throws {
        try EngramServiceWebMetadataValidation.sessionID(sessionId)
        try EngramServiceWebMetadataValidation.require(relationshipActions.contains(action))
        try EngramServiceWebMetadataValidation.require(ok)
    }

    static func displayTitle(customName: String?, generatedTitle: String?) -> String? {
        let custom = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        let generated = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let generated, !generated.isEmpty { return generated }
        return nil
    }

    static func generationIdentity(sessionId: String, generation: String) throws {
        try EngramServiceWebMetadataValidation.sessionID(sessionId)
        try EngramServiceWebMetadataValidation.hash(generation)
    }
}

struct EngramServiceWebSetSourceEnabledRequest: Codable, Equatable, Sendable {
    let source: String
    let enabled: Bool

    init(source: String, enabled: Bool) throws {
        self.source = try EngramServiceWebSourceSettingsValidation.sourceKey(source)
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                source: try container.decode(String.self, forKey: .source),
                enabled: try container.decode(Bool.self, forKey: .enabled)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .source, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebSetSourceEnabledResponse: Codable, Equatable, Sendable {
    let source: String
    let enabled: Bool

    init(source: String, enabled: Bool) throws {
        self.source = try EngramServiceWebSourceSettingsValidation.sourceKey(source)
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                source: try container.decode(String.self, forKey: .source),
                enabled: try container.decode(Bool.self, forKey: .enabled)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .source, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebLinkRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let parentId: String

    init(sessionId: String, parentId: String) throws {
        try EngramServiceWebMetadataValidation.sessionID(sessionId)
        try EngramServiceWebMetadataValidation.sessionID(parentId)
        try EngramServiceWebMetadataValidation.require(!sessionId.utf8.elementsEqual(parentId.utf8))
        self.sessionId = sessionId
        self.parentId = parentId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                parentId: try container.decode(String.self, forKey: .parentId)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .parentId, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebUnlinkRequest: Codable, Equatable, Sendable {
    let sessionId: String

    init(sessionId: String) throws {
        try EngramServiceWebMetadataValidation.sessionID(sessionId)
        self.sessionId = sessionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(sessionId: try container.decode(String.self, forKey: .sessionId))
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .sessionId, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebConfirmSuggestionRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let suggestedParentId: String

    init(sessionId: String, suggestedParentId: String) throws {
        try EngramServiceWebMetadataValidation.sessionID(sessionId)
        try EngramServiceWebMetadataValidation.sessionID(suggestedParentId)
        try EngramServiceWebMetadataValidation.require(!sessionId.utf8.elementsEqual(suggestedParentId.utf8))
        self.sessionId = sessionId
        self.suggestedParentId = suggestedParentId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                suggestedParentId: try container.decode(String.self, forKey: .suggestedParentId)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .suggestedParentId, in: container, debugDescription: "invalid"
            )
        }
    }
}

struct EngramServiceWebDismissSuggestionRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let suggestedParentId: String

    init(sessionId: String, suggestedParentId: String) throws {
        try EngramServiceWebMetadataValidation.sessionID(sessionId)
        try EngramServiceWebMetadataValidation.sessionID(suggestedParentId)
        try EngramServiceWebMetadataValidation.require(!sessionId.utf8.elementsEqual(suggestedParentId.utf8))
        self.sessionId = sessionId
        self.suggestedParentId = suggestedParentId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                suggestedParentId: try container.decode(String.self, forKey: .suggestedParentId)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .suggestedParentId, in: container, debugDescription: "invalid"
            )
        }
    }
}

struct EngramServiceWebSaveInsightRequest: Codable, Equatable, Sendable {
    let content: String
    let wing: String?
    let room: String?
    let importance: Double?
    let sourceSessionId: String?

    init(
        content: String,
        wing: String? = nil,
        room: String? = nil,
        importance: Double? = nil,
        sourceSessionId: String? = nil
    ) throws {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        try EngramServiceWebMetadataValidation.require(content.count >= 10 && content.count <= 50_000)
        if let importance {
            try EngramServiceWebMetadataValidation.require(importance.isFinite && (0...5).contains(importance))
        }
        self.content = content
        self.wing = wing
        self.room = room
        self.importance = importance
        self.sourceSessionId = sourceSessionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                content: try container.decode(String.self, forKey: .content),
                wing: try container.decodeIfPresent(String.self, forKey: .wing),
                room: try container.decodeIfPresent(String.self, forKey: .room),
                importance: try container.decodeIfPresent(Double.self, forKey: .importance),
                sourceSessionId: try container.decodeIfPresent(String.self, forKey: .sourceSessionId)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .content, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebSaveInsightResponse: Codable, Equatable, Sendable {
    let id: String
    let warning: String?

    init(id: String, warning: String? = nil) throws {
        try EngramServiceWebMetadataValidation.require(!id.isEmpty && !id.utf8.contains(0) && id.utf8.count <= 128)
        if let warning {
            try EngramServiceWebMetadataValidation.require(!warning.isEmpty && warning.utf8.count <= 512)
        }
        self.id = id
        self.warning = warning
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                id: try container.decode(String.self, forKey: .id),
                warning: try container.decodeIfPresent(String.self, forKey: .warning)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebGenerateSummaryRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let generation: String

    init(sessionId: String, generation: String) throws {
        try EngramServiceWebWriteValidation.generationIdentity(sessionId: sessionId, generation: generation)
        self.sessionId = sessionId
        self.generation = generation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                generation: try container.decode(String.self, forKey: .generation)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .generation, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebGenerateSummaryResponse: Codable, Equatable, Sendable {
    let sessionId: String
    let generation: String
    let summary: String?

    init(sessionId: String, generation: String, summary: String?) throws {
        try EngramServiceWebWriteValidation.generationIdentity(sessionId: sessionId, generation: generation)
        if let summary {
            try EngramServiceWebMetadataValidation.text(
                summary, maximumBytes: EngramServiceWebReadLimits.maximumSessionSummaryBytes, allowEmpty: false
            )
        }
        self.sessionId = sessionId
        self.generation = generation
        self.summary = summary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                generation: try container.decode(String.self, forKey: .generation),
                summary: try container.decodeIfPresent(String.self, forKey: .summary)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .summary, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebGenerateTitleRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let generation: String

    init(sessionId: String, generation: String) throws {
        try EngramServiceWebWriteValidation.generationIdentity(sessionId: sessionId, generation: generation)
        self.sessionId = sessionId
        self.generation = generation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                generation: try container.decode(String.self, forKey: .generation)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .generation, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebGenerateTitleResponse: Codable, Equatable, Sendable {
    let sessionId: String
    let generation: String
    let title: String?
    let displayTitle: String?

    init(sessionId: String, generation: String, title: String?, displayTitle: String?) throws {
        try EngramServiceWebWriteValidation.generationIdentity(sessionId: sessionId, generation: generation)
        if let title {
            try EngramServiceWebMetadataValidation.text(title, maximumBytes: 120, allowEmpty: false)
        }
        if let displayTitle {
            try EngramServiceWebMetadataValidation.text(displayTitle, maximumBytes: 1024, allowEmpty: false)
        }
        self.sessionId = sessionId
        self.generation = generation
        self.title = title
        self.displayTitle = displayTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                generation: try container.decode(String.self, forKey: .generation),
                title: try container.decodeIfPresent(String.self, forKey: .title),
                displayTitle: try container.decodeIfPresent(String.self, forKey: .displayTitle)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .title, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebRegenerateTitlesRequest: Codable, Equatable, Sendable {}

struct EngramServiceWebRegenerateTitlesResponse: Codable, Equatable, Sendable {
    let status: String
    let total: Int?

    init(status: String, total: Int? = nil) throws {
        try EngramServiceWebMetadataValidation.require(status == "started" || status == "running")
        if let total {
            try EngramServiceWebMetadataValidation.require(total >= 0)
        }
        self.status = status
        self.total = total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                status: try container.decode(String.self, forKey: .status),
                total: try container.decodeIfPresent(Int.self, forKey: .total)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebRelationshipMutationResponse: Codable, Equatable, Sendable {
    let sessionId: String
    let action: String
    let ok: Bool

    init(sessionId: String, action: String, ok: Bool) throws {
        try EngramServiceWebWriteValidation.relationship(sessionId: sessionId, action: action, ok: ok)
        self.sessionId = sessionId
        self.action = action
        self.ok = ok
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                action: try container.decode(String.self, forKey: .action),
                ok: try container.decode(Bool.self, forKey: .ok)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "invalid")
        }
    }
}
