// macos/Engram/Core/DaemonClient.swift
import Foundation

@MainActor
class DaemonClient: ObservableObject {
    private let baseURL: String

    init(port: Int = 3457) {
        self.baseURL = "http://127.0.0.1:\(port)"
    }

    // MARK: - HTTP Methods

    func fetch<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: "\(baseURL)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        try validateResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let request = try buildRequest(path, method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func postRaw(_ path: String, body: (any Encodable)? = nil) async throws {
        let request = try buildRequest(path, method: "POST", body: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
    }

    func delete(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Internal

    private func buildRequest(_ path: String, method: String, body: (any Encodable)?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw DaemonClientError.httpError(
                (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
    }

    enum DaemonClientError: Error, LocalizedError {
        case httpError(Int)
        var errorDescription: String? {
            switch self {
            case .httpError(let code): return "HTTP \(code)"
            }
        }
    }
}

// MARK: - Type-erased Encodable wrapper

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        _encode = { encoder in try wrapped.encode(to: encoder) }
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// MARK: - API Response Types

struct SourceInfo: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let sessionCount: Int
    let latestIndexed: String?
}

struct SkillInfo: Decodable, Identifiable {
    var id: String { "\(scope)/\(name)" }
    let name: String
    let description: String
    let path: String
    let scope: String
}

struct MemoryFile: Decodable, Identifiable {
    var id: String { path }
    let name: String
    let project: String
    let path: String
    let sizeBytes: Int
    let preview: String
}

struct HookInfo: Decodable, Identifiable {
    var id: String { "\(scope)/\(event)/\(command)" }
    let event: String
    let command: String
    let scope: String
}

// MARK: - Live Sessions & Monitor Types

struct LiveSessionsResponse: Decodable {
    let sessions: [LiveSessionInfo]
    let count: Int
}

struct LiveSessionInfo: Decodable, Identifiable {
    var id: String { sessionId ?? filePath }
    let source: String
    let sessionId: String?
    let project: String?
    let cwd: String?
    let filePath: String
    let startedAt: String?
    let model: String?
    let currentActivity: String?
    let lastModifiedAt: String
}

struct MonitorAlert: Decodable, Identifiable {
    let id: String
    let kind: String
    let severity: String
    let message: String
    let sessionId: String?
    let dismissed: Bool
    let createdAt: String
}

// MARK: - Handoff & Timeline Types

struct HandoffResponse: Decodable {
    let brief: String
    let sessionCount: Int
}

struct ReplayTimelineEntry: Decodable, Identifiable {
    var id: Int { index }
    let index: Int
    let role: String
    let type: String
    let preview: String
    let timestamp: String?
    let tokens: Int?
    let durationToNextMs: Int?
}

struct ReplayTimelineResponse: Decodable {
    let entries: [ReplayTimelineEntry]
    let totalEntries: Int
    let hasMore: Bool
}

// MARK: - Lint Types

struct LintIssue: Decodable, Identifiable {
    var id: String { "\(file):\(line):\(message)" }
    let file: String
    let line: Int
    let severity: String
    let message: String
    let suggestion: String?
}

struct LintResult: Decodable {
    let issues: [LintIssue]
    let score: Int
}
