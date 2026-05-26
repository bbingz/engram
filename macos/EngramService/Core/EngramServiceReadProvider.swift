import Foundation
import GRDB
import EngramCoreRead

protocol EngramServiceReadProvider: Sendable {
    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse
    func health() async throws -> EngramServiceHealthResponse
    func liveSessions() async throws -> EngramServiceLiveSessionsResponse
    func sources() async throws -> [EngramServiceSourceInfo]
    func skills() async throws -> [EngramServiceSkillInfo]
    func memoryFiles() async throws -> [EngramServiceMemoryFile]
    func hooks() async throws -> [EngramServiceHookInfo]
    func replayTimeline(_ request: EngramServiceReplayTimelineRequest) async throws -> EngramServiceReplayTimelineResponse
    func embeddingStatus() async throws -> EngramServiceEmbeddingStatusResponse
    func resumeCommand(_ request: EngramServiceResumeCommandRequest) async throws -> EngramServiceResumeCommandResponse
    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse
    func projectCwds(_ request: EngramServiceProjectCwdsRequest) async throws -> EngramServiceProjectCwdsResponse
}

protocol ServiceDatabaseReading: Sendable {
    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T
}

struct EmptyEngramServiceReadProvider: EngramServiceReadProvider {
    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: nil)
    }

    func health() async throws -> EngramServiceHealthResponse {
        EngramServiceHealthResponse(ok: true, status: "healthy", message: "Swift service ready")
    }

    func liveSessions() async throws -> EngramServiceLiveSessionsResponse {
        EngramServiceLiveSessionsResponse(sessions: [], count: 0)
    }

    func sources() async throws -> [EngramServiceSourceInfo] {
        []
    }

    func skills() async throws -> [EngramServiceSkillInfo] {
        []
    }

    func memoryFiles() async throws -> [EngramServiceMemoryFile] {
        []
    }

    func hooks() async throws -> [EngramServiceHookInfo] {
        []
    }

    func replayTimeline(_ request: EngramServiceReplayTimelineRequest) async throws -> EngramServiceReplayTimelineResponse {
        EngramServiceReplayTimelineResponse(
            sessionId: request.sessionId,
            source: nil,
            entries: [],
            totalEntries: 0,
            hasMore: false,
            offset: nil,
            limit: request.limit
        )
    }

    func embeddingStatus() async throws -> EngramServiceEmbeddingStatusResponse {
        EngramServiceEmbeddingStatusResponse(
            available: false,
            model: nil,
            embeddedCount: 0,
            totalSessions: 0,
            progress: 0
        )
    }

    func resumeCommand(_ request: EngramServiceResumeCommandRequest) async throws -> EngramServiceResumeCommandResponse {
        EngramServiceResumeCommandResponse(
            error: "Resume command unavailable",
            hint: "Session resume requires the SQLite-backed service provider."
        )
    }

    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse {
        EngramServiceProjectMigrationsResponse(migrations: [])
    }

    func projectCwds(_ request: EngramServiceProjectCwdsRequest) async throws -> EngramServiceProjectCwdsResponse {
        EngramServiceProjectCwdsResponse(project: request.project, cwds: [])
    }
}

struct FileSystemEngramServiceReadProvider: EngramServiceReadProvider {
    private let homeDirectory: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeDirectory = homeDirectory
    }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: nil)
    }

    func health() async throws -> EngramServiceHealthResponse {
        EngramServiceHealthResponse(ok: true, status: "healthy", message: "Swift service ready")
    }

    func liveSessions() async throws -> EngramServiceLiveSessionsResponse {
        let sessions = try scanLiveSessions(now: Date())
        return EngramServiceLiveSessionsResponse(sessions: sessions, count: sessions.count)
    }

    func sources() async throws -> [EngramServiceSourceInfo] {
        []
    }

    func skills() async throws -> [EngramServiceSkillInfo] {
        var results: [EngramServiceSkillInfo] = []
        let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        if let settings = dictionary(at: settingsURL),
           let customCommands = settings["customCommands"] as? [String: Any] {
            for (name, command) in customCommands.sorted(by: { $0.key < $1.key }) {
                results.append(
                    EngramServiceSkillInfo(
                        name: name,
                        description: String(describing: command).prefixString(100),
                        path: displayPath(settingsURL),
                        scope: "global"
                    )
                )
            }
        }

        let pluginsURL = homeDirectory.appendingPathComponent(".claude/plugins/cache", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: pluginsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "md", !url.path.contains("node_modules") else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  let name = yamlFrontMatterValue("name", in: content) else { continue }
            results.append(
                EngramServiceSkillInfo(
                    name: name,
                    description: yamlFrontMatterValue("description", in: content) ?? "",
                    path: displayPath(url),
                    scope: "plugin"
                )
            )
        }
        return results
    }

    func memoryFiles() async throws -> [EngramServiceMemoryFile] {
        var results: [EngramServiceMemoryFile] = []
        let projectsURL = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        let projects = (try? FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        for projectURL in projects {
            guard (try? projectURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let memoryURL = projectURL.appendingPathComponent("memory", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: memoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            )) ?? []
            for fileURL in files where fileURL.pathExtension == "md" {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                results.append(
                    EngramServiceMemoryFile(
                        name: fileURL.lastPathComponent,
                        project: projectURL.lastPathComponent.replacingOccurrences(of: "-", with: "/"),
                        path: displayPath(fileURL),
                        sizeBytes: values?.fileSize ?? 0,
                        preview: content.prefixString(200)
                    )
                )
            }
        }
        return results.sorted { lhs, rhs in
            lhs.project == rhs.project ? lhs.name < rhs.name : lhs.project < rhs.project
        }
    }

    func hooks() async throws -> [EngramServiceHookInfo] {
        var results: [EngramServiceHookInfo] = []
        for (scope, url) in [
            ("global", homeDirectory.appendingPathComponent(".claude/settings.json")),
            ("project", homeDirectory.appendingPathComponent(".claude/settings.local.json"))
        ] {
            guard let settings = dictionary(at: url),
                  let hooks = settings["hooks"] as? [String: Any] else { continue }
            for (event, handlers) in hooks.sorted(by: { $0.key < $1.key }) {
                for command in hookCommands(from: handlers) {
                    results.append(EngramServiceHookInfo(event: event, command: command, scope: scope))
                }
            }
        }
        return results
    }

    func replayTimeline(_ request: EngramServiceReplayTimelineRequest) async throws -> EngramServiceReplayTimelineResponse {
        EngramServiceReplayTimelineResponse(
            sessionId: request.sessionId,
            source: nil,
            entries: [],
            totalEntries: 0,
            hasMore: false,
            offset: nil,
            limit: request.limit
        )
    }

    func embeddingStatus() async throws -> EngramServiceEmbeddingStatusResponse {
        EngramServiceEmbeddingStatusResponse(
            available: false,
            model: nil,
            embeddedCount: 0,
            totalSessions: 0,
            progress: 0
        )
    }

    func resumeCommand(_ request: EngramServiceResumeCommandRequest) async throws -> EngramServiceResumeCommandResponse {
        EngramServiceResumeCommandResponse(
            error: "Resume command unavailable",
            hint: "Session resume requires the SQLite-backed service provider."
        )
    }

    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse {
        EngramServiceProjectMigrationsResponse(migrations: [])
    }

    func projectCwds(_ request: EngramServiceProjectCwdsRequest) async throws -> EngramServiceProjectCwdsResponse {
        EngramServiceProjectCwdsResponse(project: request.project, cwds: [])
    }

    private func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func yamlFrontMatterValue(_ key: String, in content: String) -> String? {
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func hookCommands(from value: Any) -> [String] {
        guard let handlers = value as? [Any] else { return [] }
        return handlers.map { handler in
            if let command = handler as? String {
                return command
            }
            if let object = handler as? [String: Any],
               let command = object["command"] as? String {
                return command
            }
            if let data = try? JSONSerialization.data(withJSONObject: handler),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return String(describing: handler)
        }
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = homeDirectory.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    private func scanLiveSessions(now: Date) throws -> [EngramServiceLiveSessionInfo] {
        let roots: [(source: String, url: URL, extensions: Set<String>)] = [
            ("codex", homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true), ["jsonl"]),
            ("claude-code", homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true), ["jsonl"]),
            ("gemini-cli", homeDirectory.appendingPathComponent(".gemini/tmp", isDirectory: true), ["json"]),
            ("antigravity", homeDirectory.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true), ["json", "jsonl"]),
            ("antigravity", homeDirectory.appendingPathComponent(".gemini/antigravity", isDirectory: true), ["json", "jsonl"]),
            ("opencode", homeDirectory.appendingPathComponent(".local/share/opencode", isDirectory: true), ["db"]),
        ]
        let activeWindow: TimeInterval = 2 * 60
        let idleWindow: TimeInterval = 15 * 60
        let recentWindow: TimeInterval = 24 * 60 * 60
        var results: [EngramServiceLiveSessionInfo] = []
        var seen = Set<String>()

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.url.path) else { continue }
            let files: [URL]
            if (try? root.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files = [root.url]
            } else {
                let enumerator = FileManager.default.enumerator(
                    at: root.url,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
                files = (enumerator?.compactMap { $0 as? URL } ?? [])
            }

            for file in files {
                guard results.count < 100 else { break }
                guard root.extensions.contains(file.pathExtension.lowercased()) else { continue }
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else { continue }
                let age = now.timeIntervalSince(modifiedAt)
                guard age >= 0, age <= recentWindow else { continue }
                guard seen.insert(file.path).inserted else { continue }
                let metadata = parseLiveMetadata(from: file)
                let level = age <= activeWindow ? "active" : (age <= idleWindow ? "idle" : "recent")
                results.append(
                    EngramServiceLiveSessionInfo(
                        source: root.source,
                        sessionId: metadata.sessionId,
                        project: metadata.project,
                        title: metadata.title,
                        cwd: metadata.cwd,
                        filePath: file.path,
                        startedAt: metadata.startedAt,
                        model: metadata.model,
                        currentActivity: metadata.activity,
                        lastModifiedAt: isoString(modifiedAt),
                        activityLevel: level
                    )
                )
            }
        }
        return results.sorted { $0.lastModifiedAt > $1.lastModifiedAt }
    }

    private struct LiveMetadata {
        var sessionId: String?
        var project: String?
        var title: String?
        var cwd: String?
        var startedAt: String?
        var model: String?
        var activity: String?
    }

    private func parseLiveMetadata(from url: URL) -> LiveMetadata {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return LiveMetadata(title: url.lastPathComponent)
        }
        let prefix = Data(data.prefix(64 * 1024))
        guard let text = String(data: prefix, encoding: .utf8) else {
            return LiveMetadata(title: url.lastPathComponent)
        }
        return LiveMetadata(
            sessionId: firstStringValue(keys: ["id", "session_id", "sessionId"], in: text),
            project: firstStringValue(keys: ["project"], in: text),
            title: firstStringValue(keys: ["generated_title", "title", "summary"], in: text),
            cwd: firstStringValue(keys: ["cwd", "workspace"], in: text),
            startedAt: firstStringValue(keys: ["timestamp", "start_time", "startedAt"], in: text),
            model: firstStringValue(keys: ["model"], in: text),
            activity: firstStringValue(keys: ["activity", "currentActivity"], in: text)
        )
    }

    private func firstStringValue(keys: [String], in text: String) -> String? {
        for key in keys {
            let pattern = #""\#(NSRegularExpression.escapedPattern(for: key))"\s*:\s*"([^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[valueRange])
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct SQLiteEngramServiceReadProvider: EngramServiceReadProvider {
    private let databaseReader: any ServiceDatabaseReading
    private let fileSystemProvider: FileSystemEngramServiceReadProvider
    private let commandLocator: @Sendable (String) -> String?

    init(
        databasePath: String,
        fileSystemProvider: FileSystemEngramServiceReadProvider = FileSystemEngramServiceReadProvider(),
        makeDatabaseReader: (String) throws -> any ServiceDatabaseReading = { path in
            try ServiceDatabaseReader(path: path)
        },
        commandLocator: @escaping @Sendable (String) -> String? = { name in
            SQLiteEngramServiceReadProvider.defaultCommandLocator(name)
        }
    ) throws {
        self.databaseReader = try makeDatabaseReader(databasePath)
        self.fileSystemProvider = fileSystemProvider
        self.commandLocator = commandLocator
    }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The Swift service search path is keyword/FTS-only: it has no vector
        // store or embedding provider wired in. Honor the requested `mode` by
        // either accepting it (keyword) or transparently degrading to keyword
        // and surfacing a warning, instead of silently ignoring it. A blank
        // mode is treated as keyword for backwards compatibility.
        let requestedMode = request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let semanticRequested = ["semantic", "hybrid", "both"].contains(requestedMode)
        let warning: String? = semanticRequested
            ? "Semantic search is unavailable in the local service; returning keyword results only."
            : nil
        if semanticRequested {
            ServiceLogger.info(
                "search mode '\(requestedMode)' requested but unsupported in service path; falling back to keyword",
                category: .runner
            )
        }
        guard query.count >= 2 else {
            return EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: warning)
        }

        let limit = max(1, min(request.limit, 100))
        return try read { db in
            if containsCJK(query) {
                // Escape LIKE wildcards so a literal "%"/"_" in the query is
                // matched verbatim instead of acting as a wildcard.
                let pattern = "%\(escapeLikePattern(query))%"
                var parts = ["""
                    SELECT s.*, f.content AS snippet
                    FROM sessions_fts f
                    JOIN sessions s ON s.id = f.session_id
                    WHERE f.content LIKE ? ESCAPE '\\' AND s.hidden_at IS NULL
                      AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
                """]
                var args: [DatabaseValueConvertible] = [pattern]
                appendSearchFilters(for: request, to: &parts, args: &args)
                parts.append("""
                    GROUP BY s.id
                    ORDER BY s.start_time DESC
                    LIMIT ?
                """)
                args.append(limit)
                let rows = try Row.fetchAll(
                    db,
                    sql: parts.joined(separator: " "),
                    arguments: StatementArguments(args)
                )
                return EngramServiceSearchResponse(
                    items: rows.map { item(from: $0) },
                    searchModes: ["keyword"],
                    warning: warning
                )
            }

            guard query.count >= 3 else {
                return EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: warning)
            }

            var parts = ["""
                SELECT s.*, f.content AS snippet
                FROM sessions_fts f
                JOIN sessions s ON s.id = f.session_id
                WHERE sessions_fts MATCH ? AND s.hidden_at IS NULL
                  AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
            """]
            var args: [DatabaseValueConvertible] = [query]
            appendSearchFilters(for: request, to: &parts, args: &args)
            parts.append("""
                GROUP BY s.id
                ORDER BY rank
                LIMIT ?
            """)
            args.append(limit)
            let rows = try Row.fetchAll(
                db,
                sql: parts.joined(separator: " "),
                arguments: StatementArguments(args)
            )
            return EngramServiceSearchResponse(
                items: rows.map { item(from: $0) },
                searchModes: ["keyword"],
                warning: warning
            )
        }
    }

    func health() async throws -> EngramServiceHealthResponse {
        EngramServiceHealthResponse(ok: true, status: "healthy", message: "Swift service ready")
    }

    func liveSessions() async throws -> EngramServiceLiveSessionsResponse {
        try await fileSystemProvider.liveSessions()
    }

    func sources() async throws -> [EngramServiceSourceInfo] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, COUNT(*) AS session_count, MAX(indexed_at) AS latest_indexed
                FROM sessions
                WHERE hidden_at IS NULL
                GROUP BY source
                ORDER BY source
            """)
            return rows.map { row in
                EngramServiceSourceInfo(
                    name: row["source"],
                    sessionCount: row["session_count"],
                    latestIndexed: row["latest_indexed"] as String?
                )
            }
        }
    }

    func skills() async throws -> [EngramServiceSkillInfo] {
        try await fileSystemProvider.skills()
    }

    func memoryFiles() async throws -> [EngramServiceMemoryFile] {
        try await fileSystemProvider.memoryFiles()
    }

    func hooks() async throws -> [EngramServiceHookInfo] {
        try await fileSystemProvider.hooks()
    }

    func replayTimeline(_ request: EngramServiceReplayTimelineRequest) async throws -> EngramServiceReplayTimelineResponse {
        try await fileSystemProvider.replayTimeline(request)
    }

    func embeddingStatus() async throws -> EngramServiceEmbeddingStatusResponse {
        try read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE hidden_at IS NULL") ?? 0
            guard try tableExists("session_embeddings", db: db) else {
                return EngramServiceEmbeddingStatusResponse(
                    available: false,
                    model: nil,
                    embeddedCount: 0,
                    totalSessions: total,
                    progress: 0
                )
            }
            let embedded = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT e.session_id)
                FROM session_embeddings e
                JOIN sessions s ON s.id = e.session_id
                WHERE s.hidden_at IS NULL
            """) ?? 0
            let progress = total > 0 ? Int((Double(embedded) / Double(total) * 100).rounded()) : 0
            return EngramServiceEmbeddingStatusResponse(
                available: embedded > 0,
                model: nil,
                embeddedCount: embedded,
                totalSessions: total,
                progress: min(100, max(0, progress))
            )
        }
    }

    func resumeCommand(_ request: EngramServiceResumeCommandRequest) async throws -> EngramServiceResumeCommandResponse {
        let session = try read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, source, cwd
                    FROM sessions
                    WHERE id = ?
                """,
                arguments: [request.sessionId]
            )
        }

        guard let session else {
            return EngramServiceResumeCommandResponse(
                error: "Session not found",
                hint: ""
            )
        }

        let sessionId: String = session["id"]
        let source: String = session["source"]
        let cwd: String = (session["cwd"] as String?) ?? ""
        switch source {
        case "claude-code":
            return resumeCLICommand(
                source: source,
                tool: "claude",
                sessionId: sessionId,
                cwd: cwd,
                installHint: "Install: npm install -g @anthropic-ai/claude-code"
            )
        case "codex":
            return resumeCLICommand(
                source: source,
                tool: "codex",
                sessionId: sessionId,
                cwd: cwd,
                installHint: "Install: npm install -g @openai/codex"
            )
        case "gemini-cli":
            return resumeCLICommand(
                source: source,
                tool: "gemini",
                sessionId: sessionId,
                cwd: cwd,
                installHint: "Install: npm install -g @google/gemini-cli"
            )
        case "cursor":
            return EngramServiceResumeCommandResponse(
                tool: "cursor",
                command: "open",
                args: ["-a", "Cursor", cwd],
                cwd: cwd
            )
        default:
            return EngramServiceResumeCommandResponse(
                tool: source,
                command: "open",
                args: [cwd],
                cwd: cwd
            )
        }
    }

    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse {
        let limit = max(1, min(request.limit, 200))
        return try read { db in
            let baseSQL = """
                SELECT id, old_path, new_path, old_basename, new_basename,
                       state, started_at, finished_at, archived, audit_note, actor
                FROM migration_log
            """
            let sql: String
            let arguments: StatementArguments
            if let state = request.state, !state.isEmpty {
                sql = baseSQL + " WHERE state = ? ORDER BY started_at DESC, rowid DESC LIMIT ?"
                arguments = [state, limit]
            } else {
                sql = baseSQL + " ORDER BY started_at DESC, rowid DESC LIMIT ?"
                arguments = [limit]
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return EngramServiceProjectMigrationsResponse(
                migrations: rows.map { row in
                    EngramServiceMigrationLogEntry(
                        id: row["id"],
                        oldPath: row["old_path"],
                        newPath: row["new_path"],
                        oldBasename: row["old_basename"],
                        newBasename: row["new_basename"],
                        state: row["state"],
                        startedAt: row["started_at"],
                        finishedAt: row["finished_at"],
                        archived: ((row["archived"] as Int?) ?? 0) != 0,
                        auditNote: row["audit_note"],
                        actor: row["actor"],
                        detail: nil
                    )
                }
            )
        }
    }

    func projectCwds(_ request: EngramServiceProjectCwdsRequest) async throws -> EngramServiceProjectCwdsResponse {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT cwd
                    FROM sessions
                    WHERE project = ?
                      AND cwd IS NOT NULL
                      AND cwd != ''
                    ORDER BY cwd
                """,
                arguments: [request.project]
            )
            return EngramServiceProjectCwdsResponse(
                project: request.project,
                cwds: rows.compactMap { $0["cwd"] as String? }
            )
        }
    }

    private func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try databaseReader.read(block)
    }

    private func tableExists(_ table: String, db: GRDB.Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
            arguments: [table]
        ) ?? 0
        return count > 0
    }

    private func appendSearchFilters(
        for request: EngramServiceSearchRequest,
        to parts: inout [String],
        args: inout [DatabaseValueConvertible]
    ) {
        if let source = request.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            parts.append("AND s.source = ?")
            args.append(source)
        }
        if let project = request.project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
            parts.append("AND s.project = ?")
            args.append(project)
        }
        if let since = request.since?.trimmingCharacters(in: .whitespacesAndNewlines), !since.isEmpty {
            parts.append("AND COALESCE(s.end_time, s.start_time) >= ?")
            args.append(since)
        }
    }

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value) ||
                (0xF900...0xFAFF).contains(scalar.value) ||
                (0xFE30...0xFE4F).contains(scalar.value)
        }
    }

    /// Escape `\`, `%`, `_` for use with `LIKE ? ESCAPE '\'`.
    private func escapeLikePattern(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            if ch == "\\" || ch == "%" || ch == "_" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
    /// Upper bound on the search snippet length returned over IPC. `f.content`
    /// in `sessions_fts` holds the full session text, which can be megabytes;
    /// returning it verbatim per result can blow the transport frame cap and
    /// waste bandwidth. Bound it server-side to a preview-sized window.
    static let maxSnippetLength = 600

    private func item(from row: Row) -> EngramServiceSearchResponse.Item {
        EngramServiceSearchResponse.Item(
            id: row["id"],
            title: (row["generated_title"] as String?) ?? (row["summary"] as String?),
            snippet: Self.truncateSnippet(row["snippet"] as String?),
            matchType: "keyword",
            score: nil,
            source: row["source"] as String?,
            startTime: row["start_time"] as String?,
            endTime: row["end_time"] as String?,
            cwd: row["cwd"] as String?,
            project: row["project"] as String?,
            model: row["model"] as String?,
            messageCount: row["message_count"] as Int?,
            userMessageCount: row["user_message_count"] as Int?,
            assistantMessageCount: row["assistant_message_count"] as Int?,
            systemMessageCount: row["system_message_count"] as Int?,
            summary: row["summary"] as String?,
            filePath: row["file_path"] as String?,
            sourceLocator: row["source_locator"] as String?,
            sizeBytes: row["size_bytes"] as Int?,
            indexedAt: row["indexed_at"] as String?,
            agentRole: row["agent_role"] as String?,
            customName: row["custom_name"] as String?,
            tier: row["tier"] as String?,
            toolMessageCount: row["tool_message_count"] as Int?,
            generatedTitle: row["generated_title"] as String?,
            parentSessionId: row["parent_session_id"] as String?,
            suggestedParentId: row["suggested_parent_id"] as String?,
            linkSource: row["link_source"] as String?
        )
    }

    static func truncateSnippet(_ snippet: String?) -> String? {
        guard let snippet else { return nil }
        guard snippet.count > maxSnippetLength else { return snippet }
        let prefix = snippet.prefix(maxSnippetLength)
        return String(prefix) + "…"
    }

    private func resumeCLICommand(
        source: String,
        tool: String,
        sessionId: String,
        cwd: String,
        installHint: String
    ) -> EngramServiceResumeCommandResponse {
        guard let path = commandLocator(tool) else {
            return EngramServiceResumeCommandResponse(
                error: "\(source) CLI not found",
                hint: installHint
            )
        }
        return EngramServiceResumeCommandResponse(
            tool: tool,
            command: path,
            args: ["--resume", sessionId],
            cwd: cwd
        )
    }

    nonisolated private static func defaultCommandLocator(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let searchPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        for directory in searchPaths {
            let path = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .path
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            return path
        }
        return nil
    }
}

private final class ServiceDatabaseReader: ServiceDatabaseReading, @unchecked Sendable {
    private let reader: EngramDatabaseReader

    init(path: String) throws {
        self.reader = try EngramDatabaseReader(path: path)
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try reader.read(block)
    }
}

private extension StringProtocol {
    func prefixString(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}
