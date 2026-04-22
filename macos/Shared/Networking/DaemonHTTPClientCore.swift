import Foundation

final class DaemonHTTPClientCore {
    private let baseURL: URL
    private let session: URLSession
    private let bearerTokenProvider: @Sendable () -> String?

    init(
        baseURL: URL,
        session: URLSession = .shared,
        bearerTokenProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.bearerTokenProvider = bearerTokenProvider
    }

    func fetch<T: Decodable>(_ path: String) async throws -> T {
        let request = try buildRequest(path, method: "GET")
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let request = try buildRequest(path, method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func postRaw(_ path: String, body: (any Encodable)? = nil) async throws {
        let request = try buildRequest(path, method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
    }

    func delete(_ path: String, body: (any Encodable)? = nil) async throws {
        let request = try buildRequest(path, method: "DELETE", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
    }

    func delete<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let request = try buildRequest(path, method: "DELETE", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func buildRequest(
        _ path: String,
        method: String,
        body: (any Encodable)? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try resolveURL(path))
        request.httpMethod = method
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Trace-Id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        if let token = bearerTokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func resolveURL(_ path: String) throws -> URL {
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return absoluteURL
        }
        guard let resolved = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw DaemonHTTPTransportError.invalidURL(path)
        }
        return resolved
    }

    /// Shared non-2xx handler. Decodes the server's error envelope
    /// (structured `{error:{name,message,retry_policy}}` -> legacy
    /// `{error:"string"}` -> plain text) and preserves the human-readable
    /// message for callers that need to surface daemon failures directly.
    private func validateResponse(_ response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return }

        if let env = try? JSONDecoder().decode(_DaemonHTTPErrorEnvelope.self, from: data),
           let inner = env.error {
            throw DaemonHTTPError(
                httpStatus: status,
                name: inner.name ?? "Error",
                message: inner.message ?? "HTTP \(status)",
                retryPolicy: inner.retryPolicy ?? "safe",
                details: inner.details
            )
        }

        if let legacy = try? JSONDecoder().decode(_LegacyStringErrEnvelope.self, from: data),
           let message = legacy.error {
            throw DaemonHTTPError(
                httpStatus: status,
                name: "HTTPError",
                message: message,
                retryPolicy: status == 401 ? "never" : "safe",
                details: nil
            )
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            throw DaemonHTTPError(
                httpStatus: status,
                name: "HTTPError",
                message: text.trimmingCharacters(in: .whitespacesAndNewlines),
                retryPolicy: status == 401 ? "never" : "safe",
                details: nil
            )
        }

        throw DaemonHTTPTransportError.httpError(status)
    }
}

enum DaemonHTTPTransportError: Error, LocalizedError {
    case httpError(Int)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "HTTP \(code)"
        case .invalidURL(let path):
            return "Invalid URL: \(path)"
        }
    }
}

struct DaemonHTTPError: Error, LocalizedError {
    let httpStatus: Int
    let name: String
    let message: String
    let retryPolicy: String
    let details: Details?

    struct Details: Decodable, Equatable {
        let sourceId: String?
        let oldDir: String?
        let newDir: String?
        let sharingCwds: [String]?
        let migrationId: String?
        let state: String?
    }

    var errorDescription: String? { message }
}

typealias ProjectMoveAPIError = DaemonHTTPError

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: any Encodable) {
        encodeImpl = { encoder in
            try wrapped.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private struct _DaemonHTTPErrorEnvelope: Decodable {
    struct Inner: Decodable {
        let name: String?
        let message: String?
        let retryPolicy: String?
        let details: DaemonHTTPError.Details?

        enum CodingKeys: String, CodingKey {
            case name
            case message
            case retryPolicy = "retry_policy"
            case details
        }
    }

    let error: Inner?
}

private struct _LegacyStringErrEnvelope: Decodable {
    let error: String?
}
