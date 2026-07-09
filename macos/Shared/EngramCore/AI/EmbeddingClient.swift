import Foundation

public struct EmbeddingConfig: Sendable, Equatable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var dimension: Int
    public var timeout: TimeInterval

    public init(
        baseURL: String,
        apiKey: String,
        model: String = "text-embedding-3-small",
        dimension: Int = 1536,
        timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
        self.dimension = dimension
        self.timeout = timeout
    }
}

public enum EmbeddingError: Error, Equatable {
    case notConfigured
    case http(Int)
    case malformedResponse
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
public struct OpenAICompatibleEmbeddingClient: EmbeddingProvider {
    public let config: EmbeddingConfig
    private let session: URLSession

    public init(config: EmbeddingConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public var model: String { config.model }
    public var dimension: Int { config.dimension }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard !config.apiKey.isEmpty else { throw EmbeddingError.notConfigured }
        guard let url = URL(string: config.baseURL + "/embeddings") else {
            throw EmbeddingError.notConfigured
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        // `dimensions` is honored by text-embedding-3-* and ignored by providers
        // that don't support it (they return their native dimension instead).
        let body: [String: Any] = [
            "model": config.model,
            "input": texts,
            "dimensions": config.dimension,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
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
        for row in ordered {
            guard let raw = row["embedding"] as? [Any] else {
                throw EmbeddingError.malformedResponse
            }
            let vector = raw.compactMap { ($0 as? NSNumber)?.floatValue }
            guard vector.count == raw.count, !vector.isEmpty else {
                throw EmbeddingError.malformedResponse
            }
            result.append(VectorMath.l2Normalize(vector))
        }
        guard result.count == texts.count else {
            throw EmbeddingError.malformedResponse
        }
        return result
    }
}
