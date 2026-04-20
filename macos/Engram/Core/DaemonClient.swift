// macos/Engram/Core/DaemonClient.swift
import Foundation
import Observation

@MainActor
@Observable
final class DaemonClient {
    private let baseURL: String
    private let bearerToken: String?
    private let session: URLSession

    init(port: Int = 3457, session: URLSession = .shared) {
        self.baseURL = "http://127.0.0.1:\(port)"
        self.session = session
        // Read bearer token from settings for authenticated write requests
        self.bearerToken = (readEngramSettings()?["httpBearerToken"] as? String)
    }

    // MARK: - HTTP Methods

    func fetch<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Trace-Id")
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let request = try buildRequest(path, method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func postRaw(_ path: String, body: (any Encodable)? = nil) async throws {
        let request = try buildRequest(path, method: "POST", body: body)
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func delete(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "DELETE"
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Trace-Id")
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Internal

    private func buildRequest(_ path: String, method: String, body: (any Encodable)?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Trace-Id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        // Attach bearer token for write methods
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
    let title: String?
    let cwd: String?
    let filePath: String
    let startedAt: String?
    let model: String?
    let currentActivity: String?
    let lastModifiedAt: String
    let activityLevel: String?  // "active" | "idle" | "recent"
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

// MARK: - Parent Link Management

extension DaemonClient {
    struct LinkResponse: Decodable {
        let ok: Bool
        let error: String?
    }

    func linkSession(sessionId: String, parentId: String) async throws -> LinkResponse {
        struct Body: Encodable { let parentId: String }
        return try await post("/api/sessions/\(sessionId)/link", body: Body(parentId: parentId))
    }

    func unlinkSession(sessionId: String) async throws {
        try await delete("/api/sessions/\(sessionId)/link")
    }

    func confirmSuggestion(sessionId: String) async throws -> LinkResponse {
        return try await post("/api/sessions/\(sessionId)/confirm-suggestion")
    }

    func dismissSuggestion(sessionId: String, suggestedParentId: String) async throws {
        struct Body: Encodable { let suggestedParentId: String }
        let request = try buildRequest("/api/sessions/\(sessionId)/suggestion", method: "DELETE", body: Body(suggestedParentId: suggestedParentId))
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }
}

// MARK: - Hygiene API

extension DaemonClient {
    func fetchHygieneChecks(force: Bool = false) async throws -> HygieneCheckResult {
        let path = force ? "/api/hygiene?force=true" : "/api/hygiene"
        return try await fetch(path)
    }
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

// MARK: - Project Migration API
//
// Powers the ProjectsView `⋯` menu: rename, archive, undo. Wraps the
// /api/project/* endpoints added alongside the orchestrator. Error bodies
// carry `name` + `message` + `retry_policy` so the UI can decide whether
// to offer a retry button (retry_policy ≠ 'never').

struct MigrationLogEntry: Decodable, Identifiable {
    let id: String
    let oldPath: String
    let newPath: String
    let oldBasename: String
    let newBasename: String
    let state: String           // 'fs_pending' | 'fs_done' | 'committed' | 'failed'
    let startedAt: String
    let finishedAt: String?
    let archived: Bool
    let auditNote: String?
    let actor: String

    enum CodingKeys: String, CodingKey {
        case id
        case oldPath
        case newPath
        case oldBasename
        case newBasename
        case state
        case startedAt
        case finishedAt
        case archived
        case auditNote
        case actor
    }
}

/// Subset of the TS PipelineResult actually used by the UI. We ignore
/// `perSource`, `manifest`, `git`, `renamedDirs`, etc. — add them here
/// later if a view needs them. Decodable is defensive about extras.
struct ProjectMoveResult: Decodable {
    let migrationId: String
    let state: String                  // 'committed' | 'dry-run' | 'failed'
    let ccDirRenamed: Bool
    let totalFilesPatched: Int
    let totalOccurrences: Int
    let sessionsUpdated: Int
    let aliasCreated: Bool
    let review: ReviewBlock

    struct ReviewBlock: Decodable {
        let own: [String]
        let other: [String]
    }
}

struct ProjectMoveAPIError: Error, LocalizedError {
    let httpStatus: Int
    let name: String
    let message: String
    /// 'safe' — retry is OK; 'conditional' — transient, retry after
    /// reading fresh state; 'wait' — another process holds the lock;
    /// 'never' — user intervention required.
    let retryPolicy: String

    var errorDescription: String? { "\(name): \(message)" }
}

/// Error body shape returned by /api/project/* on non-2xx. Declared at
/// file scope because Swift disallows Decodable nested types inside
/// generic functions.
private struct _ProjectErrEnvelope: Decodable {
    struct Inner: Decodable {
        let name: String?
        let message: String?
        let retry_policy: String?
    }
    let error: Inner?
}

extension DaemonClient {
    /// GET /api/project/migrations — recent migrations (default state=committed,
    /// limit 5 is typical for the Undo picker).
    func listProjectMigrations(
        state: String? = "committed",
        limit: Int = 5
    ) async throws -> [MigrationLogEntry] {
        var comps = URLComponents()
        comps.path = "/api/project/migrations"
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        comps.queryItems = items
        struct Resp: Decodable { let migrations: [MigrationLogEntry] }
        let resp: Resp = try await fetch(comps.url!.absoluteString)
        return resp.migrations
    }

    /// GET /api/project/cwds?project=<name> — distinct cwds recorded in
    /// sessions for this project grouping. Drives the Rename flow's
    /// cwd reverse-lookup (single → auto, multi → picker, empty → disable).
    func projectCwds(forProject project: String) async throws -> [String] {
        let encoded = project.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? project
        struct Resp: Decodable {
            let project: String
            let cwds: [String]
        }
        let resp: Resp = try await fetch("/api/project/cwds?project=\(encoded)")
        return resp.cwds
    }

    /// POST /api/project/move — execute or preview a move.
    func projectMove(
        src: String,
        dst: String,
        dryRun: Bool = false,
        force: Bool = false,
        auditNote: String? = nil
    ) async throws -> ProjectMoveResult {
        struct Body: Encodable {
            let src: String
            let dst: String
            let dryRun: Bool
            let force: Bool
            let auditNote: String?
        }
        return try await postProject(
            "/api/project/move",
            body: Body(src: src, dst: dst, dryRun: dryRun, force: force, auditNote: auditNote)
        )
    }

    /// POST /api/project/undo — reverse a committed migration.
    func projectUndo(
        migrationId: String,
        force: Bool = false
    ) async throws -> ProjectMoveResult {
        struct Body: Encodable {
            let migrationId: String
            let force: Bool
        }
        return try await postProject(
            "/api/project/undo",
            body: Body(migrationId: migrationId, force: force)
        )
    }

    /// POST /api/project/archive — auto-category move under _archive/.
    func projectArchive(
        src: String,
        archiveTo: String? = nil,
        dryRun: Bool = false,
        force: Bool = false,
        auditNote: String? = nil
    ) async throws -> ProjectMoveResult {
        struct Body: Encodable {
            let src: String
            let archiveTo: String?
            let dryRun: Bool
            let force: Bool
            let auditNote: String?
        }
        return try await postProject(
            "/api/project/archive",
            body: Body(
                src: src,
                archiveTo: archiveTo,
                dryRun: dryRun,
                force: force,
                auditNote: auditNote
            )
        )
    }

    /// Shared POST helper that decodes either the success type T OR the
    /// `{error: {name, message, retry_policy}}` shape — and re-throws the
    /// latter as `ProjectMoveAPIError` so callers can surface retry_policy
    /// in the UI. The generic `post<T>` loses the body on non-2xx.
    private func postProject<T: Decodable>(
        _ path: String,
        body: any Encodable
    ) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Trace-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        if let token = readEngramSettings()?["httpBearerToken"] as? String {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) {
            return try JSONDecoder().decode(T.self, from: data)
        }
        if let env = try? JSONDecoder().decode(_ProjectErrEnvelope.self, from: data),
           let inner = env.error {
            throw ProjectMoveAPIError(
                httpStatus: status,
                name: inner.name ?? "Error",
                message: inner.message ?? "HTTP \(status)",
                retryPolicy: inner.retry_policy ?? "safe"
            )
        }
        throw DaemonClientError.httpError(status)
    }
}
