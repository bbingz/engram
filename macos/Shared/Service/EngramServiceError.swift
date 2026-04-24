import Foundation

enum EngramServiceError: Error, Equatable, LocalizedError, Sendable {
    case serviceUnavailable(message: String)
    case transportClosed(message: String)
    case invalidRequest(message: String)
    case unauthorized(message: String)
    case writerBusy(message: String)
    case commandFailed(
        name: String,
        message: String,
        retryPolicy: String,
        details: [String: EngramServiceJSONValue]?
    )
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let message),
             .transportClosed(let message),
             .invalidRequest(let message),
             .unauthorized(let message),
             .writerBusy(let message):
            return message
        case .commandFailed(_, let message, _, _):
            return message
        case .unsupportedProvider(let provider):
            return "Unsupported provider: \(provider)"
        }
    }
}

struct EngramServiceErrorEnvelope: Codable, Equatable, Sendable {
    let name: String
    let message: String
    let retryPolicy: String
    let details: [String: EngramServiceJSONValue]?

    init(
        name: String,
        message: String,
        retryPolicy: String,
        details: [String: EngramServiceJSONValue]? = nil
    ) {
        self.name = name
        self.message = message
        self.retryPolicy = retryPolicy
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case name
        case message
        case retryPolicy = "retry_policy"
        case details
    }

    func asError() -> EngramServiceError {
        switch name {
        case "ServiceUnavailable", "serviceUnavailable":
            return .serviceUnavailable(message: message)
        case "TransportClosed", "transportClosed":
            return .transportClosed(message: message)
        case "InvalidRequest", "invalidRequest":
            return .invalidRequest(message: message)
        case "Unauthorized", "unauthorized":
            return .unauthorized(message: message)
        case "WriterBusy", "writerBusy":
            return .writerBusy(message: message)
        case "UnsupportedProvider", "unsupportedProvider":
            if case .string(let provider)? = details?["provider"] {
                return .unsupportedProvider(provider)
            }
            return .unsupportedProvider(message)
        default:
            return .commandFailed(
                name: name,
                message: message,
                retryPolicy: retryPolicy,
                details: details
            )
        }
    }
}
