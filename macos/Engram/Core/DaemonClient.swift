// macos/Engram/Core/DaemonClient.swift
import Foundation
import Observation

@MainActor
@Observable
final class DaemonClient {
    private let core: DaemonHTTPClientCore

    init(port: Int = 3457, session: URLSession = .shared) {
        self.core = DaemonHTTPClientCore(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            session: session,
            bearerTokenProvider: {
                readEngramSettings()?["httpBearerToken"] as? String
            }
        )
    }

    // MARK: - HTTP Methods

    func fetch<T: Decodable>(_ path: String) async throws -> T {
        do {
            return try await core.fetch(path)
        } catch let error as DaemonHTTPError {
            throw DaemonClientError.httpError(error.httpStatus)
        } catch let error as DaemonHTTPTransportError {
            throw mapTransportError(error)
        }
    }

    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        do {
            return try await core.post(path, body: body)
        } catch let error as DaemonHTTPError {
            throw DaemonClientError.httpError(error.httpStatus)
        } catch let error as DaemonHTTPTransportError {
            throw mapTransportError(error)
        }
    }

    func postRaw(_ path: String, body: (any Encodable)? = nil) async throws {
        do {
            try await core.postRaw(path, body: body)
        } catch let error as DaemonHTTPError {
            throw DaemonClientError.httpError(error.httpStatus)
        } catch let error as DaemonHTTPTransportError {
            throw mapTransportError(error)
        }
    }

    func delete(_ path: String) async throws {
        do {
            try await core.delete(path)
        } catch let error as DaemonHTTPError {
            throw DaemonClientError.httpError(error.httpStatus)
        } catch let error as DaemonHTTPTransportError {
            throw mapTransportError(error)
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

    private func mapTransportError(_ error: DaemonHTTPTransportError) -> DaemonClientError {
        switch error {
        case .httpError(let code):
            return .httpError(code)
        case .invalidURL:
            return .httpError(0)
        }
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
        do {
            try await core.delete(
                "/api/sessions/\(sessionId)/suggestion",
                body: Body(suggestedParentId: suggestedParentId)
            )
        } catch let error as DaemonHTTPTransportError {
            throw mapTransportError(error)
        }
    }
}

// MARK: - Hygiene API

extension DaemonClient {
    func fetchHygieneChecks(force: Bool = false) async throws -> EngramServiceHygieneResponse {
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
/// `perSource`, `git`, `renamedDirs`, etc. — add them here later if a
/// view needs them. Decodable is defensive about extras.
///
/// `manifest` is the per-file breakdown (path + occurrence count). On
/// dry-run it's the projected list of files that will be patched; on
/// committed it's the actual list that was patched. Round 4: UI needs
/// this to show users *which* files are impacted before they commit.
struct ProjectMoveResult: Decodable {
    let migrationId: String
    let state: String                  // 'committed' | 'dry-run' | 'failed'
    let ccDirRenamed: Bool
    let totalFilesPatched: Int
    let totalOccurrences: Int
    let sessionsUpdated: Int
    let aliasCreated: Bool
    let review: ReviewBlock
    let manifest: [ManifestEntry]?    // optional — older daemons may omit
    /// Per-source scan breakdown + walk issues (too_large / stat_failed).
    /// Round 4: previously dropped at decode, so EACCES errors during
    /// dry-run scan were invisible — UI showed "executable" with no
    /// hint that some files couldn't be read.
    let perSource: [PerSource]?
    /// Per-source dirs that were intentionally skipped (iFlow lossy
    /// encoding collapsing src == dst, Gemini basename unchanged, etc.).
    /// Round 4 Critical: previously silent in CLI + Swift UI — user
    /// thought migration complete while some sources were no-op.
    let skippedDirs: [SkippedDir]?

    struct ReviewBlock: Decodable {
        let own: [String]
        let other: [String]
    }

    struct ManifestEntry: Decodable, Identifiable {
        let path: String
        let occurrences: Int
        var id: String { path }
    }

    struct PerSource: Decodable, Identifiable {
        let id: String
        let root: String
        let filesPatched: Int
        let occurrences: Int
        let issues: [WalkIssue]?

        struct WalkIssue: Decodable, Identifiable {
            let path: String
            let reason: String  // 'too_large' | 'stat_failed'
            let detail: String?
            var id: String { "\(reason)::\(path)" }
        }
    }

    struct SkippedDir: Decodable, Identifiable {
        let sourceId: String
        let reason: String  // 'encoded_name_unchanged' | 'absent_on_disk' | 'lossy_collapse'
        let dir: String?
        var id: String { "\(sourceId)::\(dir ?? reason)" }
    }
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

    /// Thin wrapper around the shared `post<T>` — kept as a named method so
    /// the project-facing APIs above read naturally. Envelope decoding now
    /// lives in `validateResponse(response, data:)` so every DaemonClient
    /// caller (link, hygiene, etc.) surfaces typed errors.
    private func postProject<T: Decodable>(
        _ path: String,
        body: any Encodable
    ) async throws -> T {
        try await post(path, body: body)
    }
}
