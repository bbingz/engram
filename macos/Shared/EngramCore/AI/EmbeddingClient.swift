import Foundation

public struct EmbeddingConfig: Sendable, Equatable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var dimension: Int
    public var timeout: TimeInterval
    public var includeDimensions: Bool
    public var dimensionWasExplicit: Bool

    public init(
        baseURL: String,
        apiKey: String,
        model: String = "text-embedding-3-small",
        dimension: Int = 1536,
        timeout: TimeInterval = 30,
        includeDimensions: Bool = false,
        dimensionWasExplicit: Bool? = nil
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
        self.dimension = dimension
        self.timeout = timeout
        self.includeDimensions = includeDimensions
        self.dimensionWasExplicit = dimensionWasExplicit ?? (dimension != 1536)
    }
}

public enum EmbeddingRequestPolicy {
    public static func sendsDimensions(for config: EmbeddingConfig) -> Bool {
        !config.model.lowercased().contains("bge")
            && (config.dimensionWasExplicit || config.includeDimensions)
    }

    public static func dimensionsWereSentForCompatibility(
        _ config: EmbeddingConfig,
        storedDimension: Int
    ) -> Bool {
        sendsDimensions(for: config) && config.dimension == storedDimension
    }
}

public enum EmbeddingError: Error, Equatable {
    case notConfigured
    case http(Int)
    /// Provider explicitly rejected this request's input. Callers may isolate
    /// the affected item without treating provider/config failures as poison.
    case inputRejected(String)
    case malformedResponse
    /// Provider returned a vector whose length does not match the configured
    /// dimension. Refuse to store so availability probes and cosine KNN stay
    /// consistent (audit M16).
    case dimensionMismatch(expected: Int, actual: Int)
    /// Breaker is open (or half-open without the probe slot). Callers must
    /// treat this as a soft skip — leave jobs pending/retryable, do not burn
    /// permanent-failure budgets (see embedding-guardrails design).
    case circuitOpen
}

public protocol EmbeddingProvider: Sendable {
    var model: String { get }
    var dimension: Int { get }
    /// One L2-normalized vector per input, in input order. Throws on failure.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// OpenAI-compatible embeddings client (`POST {baseURL}/embeddings`). Works with
/// OpenAI, SiliconFlow, DashScope, DeepSeek, and any compatible endpoint via the
/// configurable `baseURL`. Opt-in: an empty API key throws `notConfigured` so
/// callers degrade to keyword search. `URLSession` is injectable for tests.
public final class OpenAICompatibleEmbeddingClient: EmbeddingProvider, @unchecked Sendable {
    public let config: EmbeddingConfig
    private let session: URLSession
    private let dimensionLock = NSLock()
    private var adoptedDimension: Int?
    private var sendsDimensionsOnNextRequest: Bool

    public init(config: EmbeddingConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        sendsDimensionsOnNextRequest = EmbeddingRequestPolicy.sendsDimensions(for: config)
    }

    public var model: String { config.model }
    public var dimension: Int {
        dimensionLock.lock()
        defer { dimensionLock.unlock() }
        return adoptedDimension ?? config.dimension
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        dimensionLock.lock()
        let sendsDimensions = sendsDimensionsOnNextRequest
        dimensionLock.unlock()
        return try await embed(
            texts,
            sendsDimensions: sendsDimensions,
            allowsDimensionFallback: true
        )
    }

    private func embed(
        _ texts: [String],
        sendsDimensions: Bool,
        allowsDimensionFallback: Bool
    ) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard !config.apiKey.isEmpty else { throw EmbeddingError.notConfigured }
        guard let url = URL(string: config.baseURL + "/embeddings") else {
            throw EmbeddingError.notConfigured
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": config.model,
            "input": texts,
        ]
        if sendsDimensions {
            body["dimensions"] = config.dimension
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let providerError = Self.providerError(from: data)
            if sendsDimensions,
               allowsDimensionFallback,
               providerError?.isDimensionRejection == true {
                let vectors = try await embed(
                    texts,
                    sendsDimensions: false,
                    allowsDimensionFallback: false
                )
                dimensionLock.lock()
                sendsDimensionsOnNextRequest = false
                dimensionLock.unlock()
                return vectors
            }
            if [400, 413, 422].contains(http.statusCode),
               texts.count > 1,
               providerError?.isModelOrDimensionRejection != true {
                let midpoint = texts.count / 2
                let left = try await embed(
                    Array(texts[..<midpoint]),
                    sendsDimensions: sendsDimensions,
                    allowsDimensionFallback: allowsDimensionFallback
                )
                let right = try await embed(
                    Array(texts[midpoint...]),
                    sendsDimensions: sendsDimensions,
                    allowsDimensionFallback: allowsDimensionFallback
                )
                return left + right
            }
            if [400, 413, 422].contains(http.statusCode),
               let message = Self.inputRejectionMessage(
                   providerError,
                   dimensionsWereSent: sendsDimensions
               ) {
                throw EmbeddingError.inputRejected(message)
            }
            throw EmbeddingError.http(http.statusCode)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else {
            throw EmbeddingError.malformedResponse
        }
        // Preserve input order: the API returns an `index` per row.
        let ordered = rows.sorted {
            ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
        }
        var result: [[Float]] = []
        result.reserveCapacity(ordered.count)
        var responseDimension: Int?
        for row in ordered {
            guard let raw = row["embedding"] as? [Any] else {
                throw EmbeddingError.malformedResponse
            }
            let vector = raw.compactMap { ($0 as? NSNumber)?.floatValue }
            guard vector.count == raw.count, !vector.isEmpty else {
                throw EmbeddingError.malformedResponse
            }
            if sendsDimensions {
                guard vector.count == config.dimension else {
                    throw EmbeddingError.dimensionMismatch(
                        expected: config.dimension,
                        actual: vector.count
                    )
                }
            } else if let responseDimension {
                guard vector.count == responseDimension else {
                    throw EmbeddingError.dimensionMismatch(
                        expected: responseDimension,
                        actual: vector.count
                    )
                }
            } else {
                responseDimension = vector.count
            }
            result.append(VectorMath.l2Normalize(vector))
        }
        guard result.count == texts.count else {
            throw EmbeddingError.malformedResponse
        }
        if let responseDimension {
            dimensionLock.lock()
            if let adoptedDimension, adoptedDimension != responseDimension {
                dimensionLock.unlock()
                throw EmbeddingError.dimensionMismatch(
                    expected: adoptedDimension,
                    actual: responseDimension
                )
            }
            adoptedDimension = responseDimension
            dimensionLock.unlock()
        }
        return result
    }

    private struct ProviderError {
        let message: String
        let parameter: String?
        let code: String?

        var isBatchSizeRejection: Bool {
            let value = "\(message) \(code ?? "")".lowercased()
            let cardinality = value.contains("size")
                || value.contains("limit")
                || value.contains("maximum")
                || value.contains("at most")
                || value.contains("too_long")
            return cardinality && (
                value.contains("batch")
                    || value.contains("list")
                    || value.contains("items")
                    || value.contains("item")
            )
        }


        var isModelOrDimensionRejection: Bool {
            let parameter = parameter?.lowercased()
            let value = "\(message) \(code ?? "")".lowercased()
            return parameter == "dimensions"
                || parameter == "model"
                || value.contains("dimension")
                || value.contains("unsupported model")
                || value.contains("invalid model")
                || value.contains("model not found")
        }

        var isDimensionRejection: Bool {
            let parameter = parameter?.lowercased()
            let value = "\(message) \(code ?? "")".lowercased()
            return parameter == "dimensions"
                || (value.contains("dimension")
                    && (value.contains("unsupported")
                        || value.contains("not supported")
                        || value.contains("not permitted")
                        || value.contains("extra_forbidden")
                        || value.contains("unexpected")))
                || (parameter == nil
                    && code == "20015"
                    && value.contains("parameter")
                    && value.contains("invalid"))
        }
    }

    private static func providerError(from data: Data) -> ProviderError? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = nonEmptyString(root["data"]),
           let code = scalarString(root["code"]) {
            return ProviderError(message: message, parameter: nil, code: code)
        }
        if let error = root["error"] as? [String: Any],
           let message = nonEmptyString(error["message"]) {
            return ProviderError(
                message: message,
                parameter: nonEmptyString(error["param"]),
                code: scalarString(error["code"])
            )
        }
        if let message = nonEmptyString(root["error"]) {
            return ProviderError(message: message, parameter: nil, code: scalarString(root["code"]))
        }
        if let message = nonEmptyString(root["message"]) {
            return ProviderError(
                message: message,
                parameter: nonEmptyString(root["param"]),
                code: scalarString(root["code"])
            )
        }
        if let detail = root["detail"] as? [String: Any],
           let parsed = providerError(fromObject: detail, fallbackCode: scalarString(root["code"])) {
            return parsed
        }
        if let message = detailMessage(root["detail"]) {
            return ProviderError(message: message, parameter: nil, code: scalarString(root["code"]))
        }
        if let details = root["detail"] as? [[String: Any]],
           let detail = details.first(where: { nonEmptyString($0["msg"]) != nil }),
           let message = nonEmptyString(detail["msg"]) {
            let location = (detail["loc"] as? [Any])?.compactMap(scalarString)
            let parameter = location?.reversed().first { token in
                token.lowercased() != "body" && Int(token) == nil
            }
            return ProviderError(
                message: message,
                parameter: parameter,
                code: scalarString(detail["type"])
            )
        }
        return nil
    }

    private static func providerError(
        fromObject object: [String: Any],
        fallbackCode: String?
    ) -> ProviderError? {
        let location = (object["loc"] as? [Any])?.compactMap(scalarString)
        let locationParameter = location?.reversed().first { token in
            token.lowercased() != "body" && Int(token) == nil
        }
        let nestedError = object["error"] as? [String: Any]
        let message = nonEmptyString(object["data"])
            ?? nonEmptyString(object["message"])
            ?? nonEmptyString(object["msg"])
            ?? nonEmptyString(nestedError?["data"])
            ?? nonEmptyString(nestedError?["message"])
            ?? nonEmptyString(nestedError?["msg"])
        guard let message else { return nil }
        return ProviderError(
            message: message,
            parameter: nonEmptyString(object["param"])
                ?? nonEmptyString(object["parameter"])
                ?? locationParameter
                ?? nonEmptyString(nestedError?["param"]),
            code: scalarString(object["code"])
                ?? scalarString(object["type"])
                ?? scalarString(nestedError?["code"])
                ?? fallbackCode
        )
    }

    private static func inputRejectionMessage(
        _ error: ProviderError?,
        dimensionsWereSent _: Bool
    ) -> String? {
        guard let error, !error.isBatchSizeRejection else { return nil }
        let parameter = error.parameter?.lowercased()
        let inputScoped = parameter == "input"
            || parameter?.hasPrefix("input.") == true
            || parameter?.hasPrefix("input[") == true
        let signal = "\(error.message) \(error.code ?? "")".lowercased()
        let describesModelOrDimensions = signal.contains("dimension")
            || signal.contains("unsupported model")
            || signal.contains("invalid model")
            || signal.contains("model not found")
            || parameter == "dimensions"
            || parameter == "model"
        guard !describesModelOrDimensions else { return nil }
        let describesInputLimit = signal.contains("token")
            || signal.contains("length")
            || signal.contains("context")
            || signal.contains("too_long")
            || signal.contains("too long")
            || signal.contains("at most")
            || signal.contains("maximum")
        let describesModeration = signal.contains("moderation")
            || signal.contains("safety")
            || signal.contains("content policy")
        if parameter == nil,
           ["20015", "20018"].contains(error.code ?? ""),
           !describesInputLimit && !describesModeration {
            return nil
        }
        return (inputScoped || describesInputLimit || describesModeration)
            ? error.message
            : nil
    }

    private static func detailMessage(_ value: Any?) -> String? {
        if let message = nonEmptyString(value) { return message }
        guard let object = value as? [String: Any] else { return nil }
        if let message = nonEmptyString(object["message"])
            ?? nonEmptyString(object["msg"]) {
            return message
        }
        if let error = object["error"] as? [String: Any] {
            return nonEmptyString(error["message"])
                ?? nonEmptyString(error["msg"])
        }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func scalarString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
