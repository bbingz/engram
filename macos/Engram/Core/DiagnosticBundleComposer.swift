import Foundation

struct DiagnosticBundleInput {
    let app: DiagnosticAppInfo
    let service: DiagnosticServiceStatus
    let database: DiagnosticDatabaseStats
    let recentLogs: [DiagnosticLogLine]
    let settings: [String: Any]
}

struct DiagnosticAppInfo: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let macOSVersion: String

    static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> DiagnosticAppInfo {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = processInfo.operatingSystemVersion
        return DiagnosticAppInfo(
            version: version,
            build: build,
            macOSVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        )
    }
}

struct DiagnosticDatabaseStats: Codable, Equatable, Sendable {
    let sessionsBySource: [String: Int]
    let sessionsByTier: [String: Int]
    let indexJobsByStatus: [String: Int]
    let dbFileSizeBytes: Int64
}

struct DiagnosticLogLine: Codable, Equatable, Sendable {
    let timestamp: String
    let level: String
    let category: String
    let message: String

    init(timestamp: String, level: String, category: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }

    init(_ line: ServiceLogLineDTO) {
        self.init(
            timestamp: line.timestamp,
            level: line.level,
            category: line.category,
            message: line.message
        )
    }
}

enum DiagnosticServiceStatus: Codable, Equatable, Sendable {
    case status(EngramServiceStatus)
    case unreachable(message: String)

    private enum CodingKeys: String, CodingKey {
        case state
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .state) == "unreachable" {
            self = .unreachable(message: try container.decode(String.self, forKey: .message))
        } else {
            self = .status(try EngramServiceStatus(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .status(let status):
            try status.encode(to: encoder)
        case .unreachable(let message):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("unreachable", forKey: .state)
            try container.encode(message, forKey: .message)
        }
    }
}

enum DiagnosticBundleComposer {
    /// Normalized (lowercase, non-alphanumerics stripped) sensitive key aliases.
    /// Matching uses the same normalization so `embeddingApiKey`, `embedding_api_key`,
    /// and `Embedding-Api-Key` all redact — there is no exact-key-only bypass.
    static let sensitiveSettingsKeys: Set<String> = [
        "aiapikey",
        "titleapikey",
        "embeddingapikey",
        "remoteoffloadtoken",
        "remoteoffloadbearertoken",
        "remoteoffloadauthtoken",
        "remoteoffloadapikey",
    ]

    static func compose(input: DiagnosticBundleInput) throws -> Data {
        let payload = DiagnosticBundlePayload(
            app: input.app,
            service: input.service,
            database: input.database,
            recentLogs: input.recentLogs,
            settings: redactedSettings(from: input.settings)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    static func redactedSettings(from settings: [String: Any]) -> DiagnosticJSONValue {
        .object(redactObject(settings))
    }

    /// Lowercase + strip non-alphanumeric so aliases collapse to one form.
    static func normalizeSensitiveKey(_ key: String) -> String {
        String(key.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func redactObject(_ object: [String: Any]) -> [String: DiagnosticJSONValue] {
        object.reduce(into: [:]) { result, entry in
            let key = entry.key
            if sensitiveSettingsKeys.contains(normalizeSensitiveKey(key)) {
                result[key] = .string("<redacted>")
            } else {
                result[key] = jsonValue(from: entry.value)
            }
        }
    }

    private static func jsonValue(from value: Any) -> DiagnosticJSONValue {
        if value is NSNull {
            return .null
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        }
        if let value = value as? Bool {
            return .bool(value)
        }
        if let value = value as? String {
            return .string(value)
        }
        if let value = value as? Int {
            return .number(Double(value))
        }
        if let value = value as? Int64 {
            return .number(Double(value))
        }
        if let value = value as? UInt {
            return .number(Double(value))
        }
        if let value = value as? UInt64 {
            return .number(Double(value))
        }
        if let value = value as? Double {
            return .number(value)
        }
        if let value = value as? Float {
            return .number(Double(value))
        }
        if let object = dictionary(from: value) {
            return .object(redactObject(object))
        }
        if let array = array(from: value) {
            return .array(array.map(jsonValue(from:)))
        }
        return .string(String(describing: value))
    }

    private static func dictionary(from value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }
        guard let object = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, value) in object {
            guard let key = key as? String else { continue }
            result[key] = value
        }
        return result
    }

    private static func array(from value: Any) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }
        if let array = value as? NSArray {
            return array as? [Any]
        }
        return nil
    }
}

private struct DiagnosticBundlePayload: Codable {
    let app: DiagnosticAppInfo
    let service: DiagnosticServiceStatus
    let database: DiagnosticDatabaseStats
    let recentLogs: [DiagnosticLogLine]
    let settings: DiagnosticJSONValue
}

enum DiagnosticJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: DiagnosticJSONValue])
    case array([DiagnosticJSONValue])
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
        } else if let value = try? container.decode([DiagnosticJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: DiagnosticJSONValue].self))
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
