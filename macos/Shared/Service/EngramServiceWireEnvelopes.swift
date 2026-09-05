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
