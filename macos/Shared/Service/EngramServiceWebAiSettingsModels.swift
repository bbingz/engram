import Foundation

enum EngramServiceWebAiSettingsValidation {
    static let patchKeys: Set<String> = [
        "aiProtocol", "aiBaseURL", "aiModel", "summaryLanguage", "summaryMaxSentences",
        "summaryStyle", "summaryPrompt", "summaryMaxTokens", "summaryTemperature",
        "summarySampleFirst", "summarySampleLast", "summaryTruncateChars",
        "titleProvider", "titleBaseUrl", "titleModel",
        "embeddingBaseURL", "embeddingModel", "embeddingDimension", "embeddingIncludeDimensions",
        "aiAudit",
    ]
    static let auditKeys: Set<String> = ["enabled", "logBodies", "maxBodySize"]
    static let maximumURLBytes = 2_048
    static let maximumModelBytes = 256
    static let maximumLanguageBytes = 64
    static let maximumStyleBytes = 512
    static let maximumPromptBytes = 8_000

    static func text(
        _ value: String,
        maxBytes: Int,
        emptyAllowed: Bool,
        allowsMultiline: Bool = false
    ) throws -> String {
        try EngramServiceWebMetadataValidation.require(!value.utf8.contains(0))
        let forbiddenControls = CharacterSet.controlCharacters.subtracting(
            allowsMultiline ? CharacterSet(charactersIn: "\t\n\r") : CharacterSet()
        )
        try EngramServiceWebMetadataValidation.require(
            !value.unicodeScalars.contains(where: { forbiddenControls.contains($0) })
        )
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try EngramServiceWebMetadataValidation.require(emptyAllowed || !trimmed.isEmpty)
        try EngramServiceWebMetadataValidation.require(trimmed.utf8.count <= maxBytes)
        return trimmed
    }

    static func multilineText(_ value: String, maxBytes: Int, emptyAllowed: Bool) throws -> String {
        try text(value, maxBytes: maxBytes, emptyAllowed: emptyAllowed, allowsMultiline: true)
    }

    static func model(_ value: String) throws -> String {
        try text(value, maxBytes: maximumModelBytes, emptyAllowed: false)
    }

    static func language(_ value: String) throws -> String {
        try text(value, maxBytes: maximumLanguageBytes, emptyAllowed: false)
    }

    static func optionalURL(_ value: String) throws -> String {
        let trimmed = try text(value, maxBytes: maximumURLBytes, emptyAllowed: true)
        if trimmed.isEmpty { return "" }
        try EngramServiceWebMetadataValidation.require(
            !trimmed.contains("\\") && !trimmed.contains("?") && !trimmed.contains("#")
        )
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host, !host.isEmpty else {
            throw EngramServiceWebReadError.invalidField("url")
        }
        return trimmed
    }

    static func finiteRange(_ value: Double, min: Double, max: Double) throws -> Double {
        try EngramServiceWebMetadataValidation.require(value.isFinite && value >= min && value <= max)
        return value
    }

    static func intRange(_ value: Int, min: Int, max: Int) throws -> Int {
        try EngramServiceWebMetadataValidation.require((min...max).contains(value))
        return value
    }

    /// `openai` enables native summaries; `disabled` is the stored "summaries
    /// off" state that the service `summaryConfig` treats as no provider.
    /// Legacy Node settings wrote `disabled` and HQ still carries it.
    static let aiProtocols = ["openai", "disabled"]

    static func aiProtocol(_ value: String) throws -> String {
        let trimmed = try text(value, maxBytes: 32, emptyAllowed: false)
        try EngramServiceWebMetadataValidation.require(aiProtocols.contains(trimmed))
        return trimmed
    }

    static func titleProvider(_ value: String) throws -> String {
        let trimmed = try text(value, maxBytes: 32, emptyAllowed: false)
        try EngramServiceWebMetadataValidation.require(
            trimmed == "ollama" || trimmed == "custom" || trimmed == "openai"
        )
        return trimmed
    }

    static func published(_ settings: EngramServiceWebAiSettings) throws {
        _ = try text(settings.aiProtocol, maxBytes: 64, emptyAllowed: false)
        _ = try optionalURL(settings.aiBaseURL)
        _ = try text(settings.aiModel, maxBytes: maximumModelBytes, emptyAllowed: false)
        _ = try text(settings.summaryLanguage, maxBytes: maximumLanguageBytes, emptyAllowed: false)
        _ = try intRange(settings.summaryMaxSentences, min: 1, max: 20)
        _ = try multilineText(settings.summaryStyle, maxBytes: maximumStyleBytes, emptyAllowed: true)
        _ = try multilineText(settings.summaryPrompt, maxBytes: maximumPromptBytes, emptyAllowed: true)
        _ = try intRange(settings.summaryMaxTokens, min: 1, max: 32_768)
        _ = try finiteRange(settings.summaryTemperature, min: 0, max: 2)
        _ = try intRange(settings.summarySampleFirst, min: 0, max: 200)
        _ = try intRange(settings.summarySampleLast, min: 0, max: 200)
        _ = try intRange(settings.summaryTruncateChars, min: 1, max: 10_000)
        _ = try text(settings.summaryPreset, maxBytes: 32, emptyAllowed: false)
        _ = try text(settings.titleProvider, maxBytes: 32, emptyAllowed: false)
        _ = try optionalURL(settings.titleBaseUrl)
        _ = try optionalURL(settings.titleBaseURL)
        _ = try text(settings.titleModel, maxBytes: maximumModelBytes, emptyAllowed: false)
        _ = try optionalURL(settings.embeddingBaseURL)
        _ = try text(settings.embeddingModel, maxBytes: maximumModelBytes, emptyAllowed: false)
        _ = try intRange(settings.embeddingDimension, min: 1, max: 65_536)
        _ = try intRange(settings.aiAudit.maxBodySize, min: 1, max: 1_000_000)
    }
}

struct EngramServiceWebAiSettingsAudit: Codable, Equatable, Sendable {
    let enabled: Bool
    let logBodies: Bool
    let maxBodySize: Int
}

struct EngramServiceWebAiSettings: Codable, Equatable, Sendable {
    let aiProtocol: String
    let aiBaseURL: String
    let aiModel: String
    let summaryLanguage: String
    let summaryMaxSentences: Int
    let summaryStyle: String
    let summaryPrompt: String
    let summaryMaxTokens: Int
    let summaryTemperature: Double
    let summarySampleFirst: Int
    let summarySampleLast: Int
    let summaryTruncateChars: Int
    let summaryPreset: String
    let titleProvider: String
    let titleBaseUrl: String
    let titleBaseURL: String
    let titleModel: String
    let embeddingBaseURL: String
    let embeddingModel: String
    let embeddingDimension: Int
    let embeddingIncludeDimensions: Bool
    let aiAudit: EngramServiceWebAiSettingsAudit

    init(
        aiProtocol: String,
        aiBaseURL: String,
        aiModel: String,
        summaryLanguage: String,
        summaryMaxSentences: Int,
        summaryStyle: String,
        summaryPrompt: String,
        summaryMaxTokens: Int,
        summaryTemperature: Double,
        summarySampleFirst: Int,
        summarySampleLast: Int,
        summaryTruncateChars: Int,
        summaryPreset: String,
        titleProvider: String,
        titleBaseUrl: String,
        titleBaseURL: String,
        titleModel: String,
        embeddingBaseURL: String,
        embeddingModel: String,
        embeddingDimension: Int,
        embeddingIncludeDimensions: Bool,
        aiAudit: EngramServiceWebAiSettingsAudit
    ) throws {
        self.aiProtocol = aiProtocol
        self.aiBaseURL = aiBaseURL
        self.aiModel = aiModel
        self.summaryLanguage = summaryLanguage
        self.summaryMaxSentences = summaryMaxSentences
        self.summaryStyle = summaryStyle
        self.summaryPrompt = summaryPrompt
        self.summaryMaxTokens = summaryMaxTokens
        self.summaryTemperature = summaryTemperature
        self.summarySampleFirst = summarySampleFirst
        self.summarySampleLast = summarySampleLast
        self.summaryTruncateChars = summaryTruncateChars
        self.summaryPreset = summaryPreset
        self.titleProvider = titleProvider
        self.titleBaseUrl = titleBaseUrl
        self.titleBaseURL = titleBaseURL
        self.titleModel = titleModel
        self.embeddingBaseURL = embeddingBaseURL
        self.embeddingModel = embeddingModel
        self.embeddingDimension = embeddingDimension
        self.embeddingIncludeDimensions = embeddingIncludeDimensions
        self.aiAudit = aiAudit
        try EngramServiceWebAiSettingsValidation.published(self)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                aiProtocol: try container.decode(String.self, forKey: .aiProtocol),
                aiBaseURL: try container.decode(String.self, forKey: .aiBaseURL),
                aiModel: try container.decode(String.self, forKey: .aiModel),
                summaryLanguage: try container.decode(String.self, forKey: .summaryLanguage),
                summaryMaxSentences: try container.decode(Int.self, forKey: .summaryMaxSentences),
                summaryStyle: try container.decode(String.self, forKey: .summaryStyle),
                summaryPrompt: try container.decode(String.self, forKey: .summaryPrompt),
                summaryMaxTokens: try container.decode(Int.self, forKey: .summaryMaxTokens),
                summaryTemperature: try container.decode(Double.self, forKey: .summaryTemperature),
                summarySampleFirst: try container.decode(Int.self, forKey: .summarySampleFirst),
                summarySampleLast: try container.decode(Int.self, forKey: .summarySampleLast),
                summaryTruncateChars: try container.decode(Int.self, forKey: .summaryTruncateChars),
                summaryPreset: try container.decode(String.self, forKey: .summaryPreset),
                titleProvider: try container.decode(String.self, forKey: .titleProvider),
                titleBaseUrl: try container.decode(String.self, forKey: .titleBaseUrl),
                titleBaseURL: try container.decode(String.self, forKey: .titleBaseURL),
                titleModel: try container.decode(String.self, forKey: .titleModel),
                embeddingBaseURL: try container.decode(String.self, forKey: .embeddingBaseURL),
                embeddingModel: try container.decode(String.self, forKey: .embeddingModel),
                embeddingDimension: try container.decode(Int.self, forKey: .embeddingDimension),
                embeddingIncludeDimensions: try container.decode(Bool.self, forKey: .embeddingIncludeDimensions),
                aiAudit: try container.decode(EngramServiceWebAiSettingsAudit.self, forKey: .aiAudit)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .aiProtocol, in: container, debugDescription: "invalid")
        }
    }
}

struct EngramServiceWebAiSettingsResponse: Codable, Equatable, Sendable {
    let settings: EngramServiceWebAiSettings
}

struct EngramServiceWebAiSettingsAuditPatch: Equatable, Sendable {
    var enabled: Bool?
    var logBodies: Bool?
    var maxBodySize: Int?
}

struct EngramServiceWebPatchAiSettingsRequest: Equatable, Sendable {
    var aiProtocol: String?
    var aiBaseURL: String?
    var aiModel: String?
    var summaryLanguage: String?
    var summaryMaxSentences: Int?
    var summaryStyle: String?
    var summaryPrompt: String?
    var summaryMaxTokens: Int?
    var summaryTemperature: Double?
    var summarySampleFirst: Int?
    var summarySampleLast: Int?
    var summaryTruncateChars: Int?
    var titleProvider: String?
    var titleBaseUrl: String?
    var titleModel: String?
    var embeddingBaseURL: String?
    var embeddingModel: String?
    var embeddingDimension: Int?
    var embeddingIncludeDimensions: Bool?
    var aiAudit: EngramServiceWebAiSettingsAuditPatch?

    init(
        aiProtocol: String? = nil,
        aiBaseURL: String? = nil,
        aiModel: String? = nil,
        summaryLanguage: String? = nil,
        summaryMaxSentences: Int? = nil,
        summaryStyle: String? = nil,
        summaryPrompt: String? = nil,
        summaryMaxTokens: Int? = nil,
        summaryTemperature: Double? = nil,
        summarySampleFirst: Int? = nil,
        summarySampleLast: Int? = nil,
        summaryTruncateChars: Int? = nil,
        titleProvider: String? = nil,
        titleBaseUrl: String? = nil,
        titleModel: String? = nil,
        embeddingBaseURL: String? = nil,
        embeddingModel: String? = nil,
        embeddingDimension: Int? = nil,
        embeddingIncludeDimensions: Bool? = nil,
        aiAudit: EngramServiceWebAiSettingsAuditPatch? = nil
    ) throws {
        self.aiProtocol = try aiProtocol.map(EngramServiceWebAiSettingsValidation.aiProtocol)
        self.aiBaseURL = try aiBaseURL.map(EngramServiceWebAiSettingsValidation.optionalURL)
        self.aiModel = try aiModel.map(EngramServiceWebAiSettingsValidation.model)
        self.summaryLanguage = try summaryLanguage.map(EngramServiceWebAiSettingsValidation.language)
        self.summaryMaxSentences = try summaryMaxSentences.map {
            try EngramServiceWebAiSettingsValidation.intRange($0, min: 1, max: 20)
        }
        self.summaryStyle = try summaryStyle.map {
            try EngramServiceWebAiSettingsValidation.multilineText(
                $0, maxBytes: EngramServiceWebAiSettingsValidation.maximumStyleBytes, emptyAllowed: true
            )
        }
        self.summaryPrompt = try summaryPrompt.map {
            try EngramServiceWebAiSettingsValidation.multilineText(
                $0, maxBytes: EngramServiceWebAiSettingsValidation.maximumPromptBytes, emptyAllowed: true
            )
        }
        self.summaryMaxTokens = try summaryMaxTokens.map {
            try EngramServiceWebAiSettingsValidation.intRange($0, min: 1, max: 32_768)
        }
        self.summaryTemperature = try summaryTemperature.map {
            try EngramServiceWebAiSettingsValidation.finiteRange($0, min: 0, max: 2)
        }
        self.summarySampleFirst = try summarySampleFirst.map {
            try EngramServiceWebAiSettingsValidation.intRange($0, min: 0, max: 200)
        }
        self.summarySampleLast = try summarySampleLast.map {
            try EngramServiceWebAiSettingsValidation.intRange($0, min: 0, max: 200)
        }
        self.summaryTruncateChars = try summaryTruncateChars.map {
            try EngramServiceWebAiSettingsValidation.intRange($0, min: 1, max: 10_000)
        }
        self.titleProvider = try titleProvider.map(EngramServiceWebAiSettingsValidation.titleProvider)
        self.titleBaseUrl = try titleBaseUrl.map(EngramServiceWebAiSettingsValidation.optionalURL)
        self.titleModel = try titleModel.map(EngramServiceWebAiSettingsValidation.model)
        self.embeddingBaseURL = try embeddingBaseURL.map(EngramServiceWebAiSettingsValidation.optionalURL)
        self.embeddingModel = try embeddingModel.map(EngramServiceWebAiSettingsValidation.model)
        self.embeddingDimension = try embeddingDimension.map {
            try EngramServiceWebAiSettingsValidation.intRange($0, min: 1, max: 65_536)
        }
        self.embeddingIncludeDimensions = embeddingIncludeDimensions
        if let aiAudit {
            try EngramServiceWebMetadataValidation.require(
                aiAudit.enabled != nil || aiAudit.logBodies != nil || aiAudit.maxBodySize != nil
            )
            if let maxBody = aiAudit.maxBodySize {
                _ = try EngramServiceWebAiSettingsValidation.intRange(maxBody, min: 1, max: 1_000_000)
            }
        }
        self.aiAudit = aiAudit
        try EngramServiceWebMetadataValidation.require(hasPatch)
    }

    var hasPatch: Bool {
        aiProtocol != nil || aiBaseURL != nil || aiModel != nil || summaryLanguage != nil
            || summaryMaxSentences != nil || summaryStyle != nil || summaryPrompt != nil
            || summaryMaxTokens != nil || summaryTemperature != nil || summarySampleFirst != nil
            || summarySampleLast != nil || summaryTruncateChars != nil || titleProvider != nil
            || titleBaseUrl != nil || titleModel != nil || embeddingBaseURL != nil
            || embeddingModel != nil || embeddingDimension != nil || embeddingIncludeDimensions != nil
            || aiAudit != nil
    }
}

extension EngramServiceWebPatchAiSettingsRequest: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                aiProtocol: try Self.present(container, .aiProtocol),
                aiBaseURL: try Self.present(container, .aiBaseURL),
                aiModel: try Self.present(container, .aiModel),
                summaryLanguage: try Self.present(container, .summaryLanguage),
                summaryMaxSentences: try Self.present(container, .summaryMaxSentences),
                summaryStyle: try Self.present(container, .summaryStyle),
                summaryPrompt: try Self.present(container, .summaryPrompt),
                summaryMaxTokens: try Self.present(container, .summaryMaxTokens),
                summaryTemperature: try Self.present(container, .summaryTemperature),
                summarySampleFirst: try Self.present(container, .summarySampleFirst),
                summarySampleLast: try Self.present(container, .summarySampleLast),
                summaryTruncateChars: try Self.present(container, .summaryTruncateChars),
                titleProvider: try Self.present(container, .titleProvider),
                titleBaseUrl: try Self.present(container, .titleBaseUrl),
                titleModel: try Self.present(container, .titleModel),
                embeddingBaseURL: try Self.present(container, .embeddingBaseURL),
                embeddingModel: try Self.present(container, .embeddingModel),
                embeddingDimension: try Self.present(container, .embeddingDimension),
                embeddingIncludeDimensions: try Self.present(container, .embeddingIncludeDimensions),
                aiAudit: try Self.presentAudit(container)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .aiProtocol, in: container, debugDescription: "invalid")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(aiProtocol, forKey: .aiProtocol)
        try container.encodeIfPresent(aiBaseURL, forKey: .aiBaseURL)
        try container.encodeIfPresent(aiModel, forKey: .aiModel)
        try container.encodeIfPresent(summaryLanguage, forKey: .summaryLanguage)
        try container.encodeIfPresent(summaryMaxSentences, forKey: .summaryMaxSentences)
        try container.encodeIfPresent(summaryStyle, forKey: .summaryStyle)
        try container.encodeIfPresent(summaryPrompt, forKey: .summaryPrompt)
        try container.encodeIfPresent(summaryMaxTokens, forKey: .summaryMaxTokens)
        try container.encodeIfPresent(summaryTemperature, forKey: .summaryTemperature)
        try container.encodeIfPresent(summarySampleFirst, forKey: .summarySampleFirst)
        try container.encodeIfPresent(summarySampleLast, forKey: .summarySampleLast)
        try container.encodeIfPresent(summaryTruncateChars, forKey: .summaryTruncateChars)
        try container.encodeIfPresent(titleProvider, forKey: .titleProvider)
        try container.encodeIfPresent(titleBaseUrl, forKey: .titleBaseUrl)
        try container.encodeIfPresent(titleModel, forKey: .titleModel)
        try container.encodeIfPresent(embeddingBaseURL, forKey: .embeddingBaseURL)
        try container.encodeIfPresent(embeddingModel, forKey: .embeddingModel)
        try container.encodeIfPresent(embeddingDimension, forKey: .embeddingDimension)
        try container.encodeIfPresent(embeddingIncludeDimensions, forKey: .embeddingIncludeDimensions)
        if let aiAudit {
            var nested = container.nestedContainer(keyedBy: AuditKeys.self, forKey: .aiAudit)
            try nested.encodeIfPresent(aiAudit.enabled, forKey: .enabled)
            try nested.encodeIfPresent(aiAudit.logBodies, forKey: .logBodies)
            try nested.encodeIfPresent(aiAudit.maxBodySize, forKey: .maxBodySize)
        }
    }

    private static func present<T: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> T? {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "invalid")
        }
        return try container.decode(T.self, forKey: key)
    }

    private static func presentAudit(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws -> EngramServiceWebAiSettingsAuditPatch? {
        guard container.contains(.aiAudit) else { return nil }
        if try container.decodeNil(forKey: .aiAudit) {
            throw DecodingError.dataCorruptedError(forKey: .aiAudit, in: container, debugDescription: "invalid")
        }
        let nested = try container.nestedContainer(keyedBy: AuditKeys.self, forKey: .aiAudit)
        let extras = Set(nested.allKeys.map(\.stringValue)).subtracting(EngramServiceWebAiSettingsValidation.auditKeys)
        guard extras.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .aiAudit, in: container, debugDescription: "invalid")
        }
        func present<T: Decodable>(_ key: AuditKeys) throws -> T? {
            guard nested.contains(key) else { return nil }
            if try nested.decodeNil(forKey: key) {
                throw DecodingError.dataCorruptedError(forKey: key, in: nested, debugDescription: "invalid")
            }
            return try nested.decode(T.self, forKey: key)
        }
        return EngramServiceWebAiSettingsAuditPatch(
            enabled: try present(.enabled),
            logBodies: try present(.logBodies),
            maxBodySize: try present(.maxBodySize)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case aiProtocol, aiBaseURL, aiModel, summaryLanguage, summaryMaxSentences
        case summaryStyle, summaryPrompt, summaryMaxTokens, summaryTemperature
        case summarySampleFirst, summarySampleLast, summaryTruncateChars
        case titleProvider, titleBaseUrl, titleModel
        case embeddingBaseURL, embeddingModel, embeddingDimension, embeddingIncludeDimensions
        case aiAudit
    }

    private enum AuditKeys: String, CodingKey {
        case enabled, logBodies, maxBodySize
    }
}
