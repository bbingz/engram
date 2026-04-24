import Foundation
import GRDB

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
        EngramServiceLiveSessionsResponse(sessions: [], count: 0)
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
}

struct SQLiteEngramServiceReadProvider: EngramServiceReadProvider {
    private let databasePath: String
    private let fileSystemProvider: FileSystemEngramServiceReadProvider
    private let commandLocator: @Sendable (String) -> String?

    init(
        databasePath: String,
        fileSystemProvider: FileSystemEngramServiceReadProvider = FileSystemEngramServiceReadProvider(),
        commandLocator: @escaping @Sendable (String) -> String? = { name in
            SQLiteEngramServiceReadProvider.defaultCommandLocator(name)
        }
    ) {
        self.databasePath = databasePath
        self.fileSystemProvider = fileSystemProvider
        self.commandLocator = commandLocator
    }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            return EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: nil)
        }

        let limit = max(1, min(request.limit, 100))
        return try read { db in
            if containsCJK(query) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT s.*, f.content AS snippet
                    FROM sessions_fts f
                    JOIN sessions s ON s.id = f.session_id
                    WHERE f.content LIKE ? AND s.hidden_at IS NULL
                    GROUP BY s.id
                    ORDER BY s.start_time DESC
                    LIMIT ?
                """, arguments: ["%\(query)%", limit])
                return EngramServiceSearchResponse(
                    items: rows.map { item(from: $0) },
                    searchModes: ["keyword"],
                    warning: nil
                )
            }

            guard query.count >= 3 else {
                return EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: nil)
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, f.content AS snippet
                FROM sessions_fts f
                JOIN sessions s ON s.id = f.session_id
                WHERE sessions_fts MATCH ? AND s.hidden_at IS NULL
                GROUP BY s.id
                ORDER BY rank
                LIMIT ?
            """, arguments: [query, limit])
            return EngramServiceSearchResponse(
                items: rows.map { item(from: $0) },
                searchModes: ["keyword"],
                warning: nil
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
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = 30000")
        }
        let queue = try DatabaseQueue(
            path: databasePath,
            configuration: configuration
        )
        return try queue.read(block)
    }

    private func tableExists(_ table: String, db: GRDB.Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
            arguments: [table]
        ) ?? 0
        return count > 0
    }

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value) ||
                (0xF900...0xFAFF).contains(scalar.value) ||
                (0xFE30...0xFE4F).contains(scalar.value)
        }
    }

    private func item(from row: Row) -> EngramServiceSearchResponse.Item {
        EngramServiceSearchResponse.Item(
            id: row["id"],
            title: (row["generated_title"] as String?) ?? (row["summary"] as String?),
            snippet: row["snippet"] as String?,
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

private extension StringProtocol {
    func prefixString(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}
