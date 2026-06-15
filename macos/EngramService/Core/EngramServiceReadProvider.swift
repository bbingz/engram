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
    func memoryFileContent(_ request: EngramServiceMemoryFileContentRequest) async throws -> EngramServiceMemoryFileContentResponse
    func hooks() async throws -> [EngramServiceHookInfo]
    func insights() async throws -> [EngramServiceInsightInfo]
    func insightDetail(_ request: EngramServiceInsightDetailRequest) async throws -> EngramServiceInsightInfo?
    func costs() async throws -> EngramServiceCostsResponse
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

    func memoryFileContent(_ request: EngramServiceMemoryFileContentRequest) async throws -> EngramServiceMemoryFileContentResponse {
        EngramServiceMemoryFileContentResponse(path: request.path, content: "", truncated: false)
    }

    func hooks() async throws -> [EngramServiceHookInfo] {
        []
    }

    func insights() async throws -> [EngramServiceInsightInfo] {
        []
    }

    func insightDetail(_ request: EngramServiceInsightDetailRequest) async throws -> EngramServiceInsightInfo? {
        nil
    }

    func costs() async throws -> EngramServiceCostsResponse {
        EngramServiceCostsResponse(totalUsd: 0, perSource: [], perDay: [], monthToDateUsd: 0, todayUsd: 0)
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
                // LIST responses carry only a short preview, never the full body:
                // up to 500 memory files × full content would blow past the
                // 256 KiB IPC frame. The detail viewer fetches the full content
                // on demand via `memoryFileContent`.
                results.append(
                    EngramServiceMemoryFile(
                        name: fileURL.lastPathComponent,
                        project: projectURL.lastPathComponent.replacingOccurrences(of: "-", with: "/"),
                        path: displayPath(fileURL),
                        sizeBytes: values?.fileSize ?? 0,
                        preview: content.prefixString(200),
                        content: nil
                    )
                )
            }
        }
        return results.sorted { lhs, rhs in
            lhs.project == rhs.project ? lhs.name < rhs.name : lhs.project < rhs.project
        }
    }

    static let memoryFileContentCap = 200 * 1024

    func memoryFileContent(_ request: EngramServiceMemoryFileContentRequest) async throws -> EngramServiceMemoryFileContentResponse {
        // Resolve the ~-display path the list emitted back to an absolute path
        // and confine it under ~/.claude/projects/*/memory so a malicious path
        // can't read arbitrary files. Read the full body capped at ~200 KiB,
        // appending a marker when truncated.
        let resolved = resolveDisplayPath(request.path)
        let memoryRoot = homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .standardizedFileURL.path
        let standardized = URL(fileURLWithPath: resolved).standardizedFileURL
        guard standardized.path.hasPrefix(memoryRoot + "/"),
              standardized.pathExtension == "md",
              (try? standardized.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let content = try? String(contentsOf: standardized, encoding: .utf8) else {
            return EngramServiceMemoryFileContentResponse(path: request.path, content: "", truncated: false)
        }
        if content.utf8.count > Self.memoryFileContentCap {
            let capped = String(content.prefix(Self.memoryFileContentCap))
            return EngramServiceMemoryFileContentResponse(
                path: request.path,
                content: capped + "\n\n… (truncated)",
                truncated: true
            )
        }
        return EngramServiceMemoryFileContentResponse(path: request.path, content: content, truncated: false)
    }

    private func resolveDisplayPath(_ path: String) -> String {
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") {
            return homeDirectory.path + String(path.dropFirst(1))
        }
        return path
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
                    results.append(EngramServiceHookInfo(event: event, command: command, scope: scope, path: displayPath(url)))
                }
            }
        }
        return results
    }

    func insights() async throws -> [EngramServiceInsightInfo] {
        []
    }

    func insightDetail(_ request: EngramServiceInsightDetailRequest) async throws -> EngramServiceInsightInfo? {
        nil
    }

    func costs() async throws -> EngramServiceCostsResponse {
        EngramServiceCostsResponse(totalUsd: 0, perSource: [], perDay: [], monthToDateUsd: 0, todayUsd: 0)
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
    // GRDB reads here run synchronous pool.read for FTS/LIKE scans that can
    // touch the whole index. Calling them directly from an async method blocks
    // a Swift cooperative-executor thread for the duration of the scan, which
    // can starve every other concurrent service request. Hop these blocking
    // reads onto a dedicated GCD queue (mirroring the IPC server's
    // readFrameOffCooperativePool) so the cooperative pool stays free.
    private static let blockingReadQueue = DispatchQueue(
        label: "com.engram.service.read.blocking",
        qos: .userInitiated,
        attributes: .concurrent
    )

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
                category: .reader
            )
        }
        guard query.count >= 2 else {
            return EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: warning)
        }

        let limit = max(1, min(request.limit, 100))
        return try await read { db in
            if CJKText.containsCJK(query) || query.count < 3 {
                // CJK uses LIKE because FTS5 trigram MATCH is unreliable for
                // CJK. Two-character Latin abbreviations ("AI", "PR", "UI")
                // also need LIKE because the trigram tokenizer can't MATCH
                // terms shorter than three characters. Escape wildcards so a
                // literal "%"/"_" in the query is matched verbatim.
                let pattern = "%\(CJKText.escapeLikePattern(query))%"
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
                    items: rows.map { item(from: $0, query: query) },
                    searchModes: ["keyword"],
                    warning: warning
                )
            }

            let termMatches = CJKText.ftsMatchTerms(query)
            let snippetMatch = termMatches.first ?? CJKText.ftsMatchQuery(query)
            // Search at session granularity: every query token must exist
            // somewhere in the session, not necessarily in the same FTS row.
            // Drive from FTS MATCH results first, then join sessions. This
            // avoids re-running a MATCH probe once per sessions row.
            var ctes: [String] = []
            var joins: [String] = []
            var args: [DatabaseValueConvertible] = []
            for (index, termMatch) in termMatches.enumerated() {
                let alias = "m\(index)"
                let snippetSQL = index == 0
                    ? ", MIN(content) AS snippet"
                    : ""
                ctes.append("""
                    \(alias) AS (
                        SELECT session_id, MIN(rank) AS rank\(snippetSQL)
                        FROM sessions_fts
                        WHERE sessions_fts MATCH ?
                        GROUP BY session_id
                    )
                """)
                args.append(termMatch)
                if index > 0 {
                    joins.append("JOIN \(alias) ON \(alias).session_id = m0.session_id")
                }
            }
            if ctes.isEmpty {
                ctes.append("""
                    m0 AS (
                        SELECT session_id, MIN(rank) AS rank,
                               MIN(content) AS snippet
                        FROM sessions_fts
                        WHERE sessions_fts MATCH ?
                        GROUP BY session_id
                    )
                """)
                args.append(snippetMatch)
            }
            var parts = ["""
                WITH \(ctes.joined(separator: ", "))
                SELECT s.*, m0.snippet AS snippet
                FROM m0
                \(joins.joined(separator: " "))
                JOIN sessions s ON s.id = m0.session_id
                WHERE s.hidden_at IS NULL
                  AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
            """]
            appendSearchFilters(for: request, to: &parts, args: &args)
            parts.append("""
                ORDER BY m0.rank, s.start_time DESC
                LIMIT ?
            """)
            args.append(limit)
            let rows = try Row.fetchAll(
                db,
                sql: parts.joined(separator: " "),
                arguments: StatementArguments(args)
            )
            return EngramServiceSearchResponse(
                items: rows.map { item(from: $0, query: query) },
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
        try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, COUNT(*) AS session_count, MAX(indexed_at) AS latest_indexed
                FROM sessions
                WHERE hidden_at IS NULL
                GROUP BY source
                ORDER BY source
            """)
            let searchableCounts = try sourceSearchableCounts(db)
            let failedIndexJobCounts = try sourceFailedIndexJobCounts(db)
            let tokenCounts = try sourceTokenCounts(db)
            let costedCounts = try sourceCostedCounts(db)
            let latestUsage = try sourceLatestUsage(db)
            return rows.map { row in
                let source: String = row["source"]
                let sessionCount: Int = row["session_count"]
                let searchable = searchableCounts[source] ?? 0
                let failed = failedIndexJobCounts[source] ?? 0
                let tokenized = tokenCounts[source] ?? 0
                let coverage = sessionCount > 0
                    ? min(100, max(0, Int((Double(searchable) / Double(sessionCount) * 100).rounded())))
                    : 0
                let tokenCoverage = sessionCount > 0
                    ? min(100, max(0, Int((Double(tokenized) / Double(sessionCount) * 100).rounded())))
                    : 0
                let usage = latestUsage[source]
                return EngramServiceSourceInfo(
                    name: source,
                    sessionCount: sessionCount,
                    latestIndexed: row["latest_indexed"] as String?,
                    searchableSessionCount: searchable,
                    searchCoveragePercent: coverage,
                    failedIndexJobCount: failed,
                    tokenSessionCount: tokenized,
                    tokenCoveragePercent: tokenCoverage,
                    costedSessionCount: costedCounts[source] ?? 0,
                    latestUsageMetric: usage?.metric,
                    latestUsageValue: usage?.value,
                    latestUsageUnit: usage?.unit,
                    latestUsageLimitValue: usage?.limitValue,
                    latestUsageResetAt: usage?.resetAt,
                    latestUsageStatus: usage?.status,
                    healthStatus: sourceHealthStatus(
                        sessionCount: sessionCount,
                        searchableSessionCount: searchable,
                        failedIndexJobCount: failed,
                        latestUsageStatus: usage?.status
                    ),
                    liveSyncDisabled: LiveSyncDisabledSources.isLiveSyncDisabled(source)
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

    func memoryFileContent(_ request: EngramServiceMemoryFileContentRequest) async throws -> EngramServiceMemoryFileContentResponse {
        try await fileSystemProvider.memoryFileContent(request)
    }

    func hooks() async throws -> [EngramServiceHookInfo] {
        try await fileSystemProvider.hooks()
    }

    /// Preview length for an insight LIST row. Full content is fetched on demand
    /// via `insightDetail` so the list response stays under the IPC frame.
    static let insightListPreviewLength = 280

    func insights() async throws -> [EngramServiceInsightInfo] {
        try await read { db in
            // The `insights` table is created lazily (only on the first
            // save/delete write), so a fresh DB does not have it. Guard the
            // SELECT to avoid "no such table" — mirrors embeddingStatus's
            // tableExists("session_embeddings") guard.
            guard try tableExists("insights", db: db) else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, content, wing, room, importance, created_at
                FROM insights
                ORDER BY created_at DESC
                LIMIT 500
            """)
            // Map to the Sendable DTO inside the read block — a GRDB Row is not
            // Sendable and cannot cross the blocking-read queue hop. LIST rows
            // carry only a truncated preview (up to 500 insights × full content
            // would exceed the 256 KiB IPC frame); the detail viewer fetches the
            // full body on demand via `insightDetail`.
            return rows.map { row in
                let content = (row["content"] as String?) ?? ""
                return EngramServiceInsightInfo(
                    id: row["id"],
                    content: String(content.prefix(Self.insightListPreviewLength)),
                    wing: row["wing"] as String?,
                    room: row["room"] as String?,
                    importance: (row["importance"] as Int?) ?? 5,
                    createdAt: row["created_at"] as String?
                )
            }
        }
    }

    func insightDetail(_ request: EngramServiceInsightDetailRequest) async throws -> EngramServiceInsightInfo? {
        try await read { db in
            guard try tableExists("insights", db: db) else { return nil }
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, content, wing, room, importance, created_at
                FROM insights
                WHERE id = ?
            """, arguments: [request.id]) else {
                return nil
            }
            return EngramServiceInsightInfo(
                id: row["id"],
                content: (row["content"] as String?) ?? "",
                wing: row["wing"] as String?,
                room: row["room"] as String?,
                importance: (row["importance"] as Int?) ?? 5,
                createdAt: row["created_at"] as String?
            )
        }
    }

    func costs() async throws -> EngramServiceCostsResponse {
        try await read { db in
            guard try tableExists("session_costs", db: db) else {
                return EngramServiceCostsResponse(
                    totalUsd: 0,
                    perSource: [],
                    perDay: [],
                    monthToDateUsd: 0,
                    todayUsd: 0
                )
            }

            let perSourceRows = try Row.fetchAll(db, sql: """
                SELECT s.source AS key,
                       SUM(c.cost_usd) AS cost_usd,
                       COUNT(*) AS session_count
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE s.hidden_at IS NULL
                GROUP BY s.source
                ORDER BY cost_usd DESC
            """)
            let perSource = perSourceRows.map { row in
                EngramServiceCostsResponse.SourceRow(
                    key: (row["key"] as String?) ?? "unknown",
                    costUsd: Self.roundCents((row["cost_usd"] as Double?) ?? 0),
                    sessionCount: (row["session_count"] as Int?) ?? 0
                )
            }

            // Bucket by LOCAL calendar day so today/MTD/per-day match the budget
            // dedup + dashboards (which use local time). Using UTC date() here
            // produced wrong buckets near midnight in non-UTC zones.
            let perDayRows = try Row.fetchAll(db, sql: """
                SELECT date(s.start_time, 'localtime') AS day,
                       SUM(c.cost_usd) AS cost_usd
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE s.hidden_at IS NULL
                  AND s.start_time >= date('now', '-30 days', 'localtime')
                GROUP BY date(s.start_time, 'localtime')
                ORDER BY day ASC
            """)
            let perDay = perDayRows.compactMap { row -> EngramServiceCostsResponse.DayRow? in
                guard let day = row["day"] as String? else { return nil }
                return EngramServiceCostsResponse.DayRow(
                    day: day,
                    costUsd: Self.roundCents((row["cost_usd"] as Double?) ?? 0)
                )
            }

            let totalUsd = perSource.reduce(0.0) { $0 + $1.costUsd }

            let monthToDateUsd = try Double.fetchOne(db, sql: """
                SELECT SUM(c.cost_usd)
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE s.hidden_at IS NULL
                  AND date(s.start_time, 'localtime') >= date('now', 'start of month', 'localtime')
            """) ?? 0

            let todayUsd = try Double.fetchOne(db, sql: """
                SELECT SUM(c.cost_usd)
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE s.hidden_at IS NULL
                  AND date(s.start_time, 'localtime') = date('now', 'localtime')
            """) ?? 0

            return EngramServiceCostsResponse(
                totalUsd: Self.roundCents(totalUsd),
                perSource: perSource,
                perDay: perDay,
                monthToDateUsd: Self.roundCents(monthToDateUsd),
                todayUsd: Self.roundCents(todayUsd)
            )
        }
    }

    private static func roundCents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    func replayTimeline(_ request: EngramServiceReplayTimelineRequest) async throws -> EngramServiceReplayTimelineResponse {
        let limit = max(1, min(request.limit ?? 500, 2_000))
        // Step 1: fetch ONLY Sendable scalars inside read{} — source + the
        // readable locator (same COALESCE as IndexJobRunner.sessionContentSource)
        // + the FTS fallback rows/total so a single read covers both paths.
        // The blocking read queue's @Sendable block cannot await the adapter
        // stream, so streaming happens OUTSIDE this block (precedent:
        // resumeTranscriptContextLines).
        let timeline = try await read {
            db -> (source: String?, locator: String, rows: [ReplayFTSRow], total: Int) in
            let scalar = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.source AS source,
                           COALESCE(
                             NULLIF(ls.local_readable_path, ''),
                             NULLIF(s.file_path, ''),
                             s.source_locator
                           ) AS locator
                    FROM sessions s
                    LEFT JOIN session_local_state ls ON ls.session_id = s.id
                    WHERE s.id = ?
                """,
                arguments: [request.sessionId]
            )
            let source = scalar?["source"] as String?
            let locator = (scalar?["locator"] as String?) ?? ""
            guard source != nil, try tableExists("sessions_fts", db: db) else {
                return (source, locator, [], 0)
            }
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ?",
                arguments: [request.sessionId]
            ) ?? 0
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT rowid, content
                    FROM sessions_fts
                    WHERE session_id = ?
                    ORDER BY rowid
                    LIMIT ?
                """,
                arguments: [request.sessionId, limit]
            ).map {
                ReplayFTSRow(
                    rowid: ($0["rowid"] as Int64?) ?? 0,
                    content: ($0["content"] as String?) ?? ""
                )
            }
            return (source, locator, rows, total)
        }

        // Step 2 (OUTSIDE read{}): source the timeline from the real per-message
        // adapter stream (role incl. .tool, timestamp, token usage, tool calls)
        // when the locator is a readable on-disk transcript. This carries the
        // data the FTS blob lacks (roles/timestamps/tokens/tool entries).
        //
        // Fetch one sentinel row beyond `limit` so we can detect whether the
        // transcript has more entries. `replayEntries(..., limit:)` then drops
        // the sentinel back down to `limit`, so the response still returns at
        // most `limit` entries while reporting `hasMore` truthfully (the old
        // code streamed exactly `limit` rows, so `entries.count > limit` was
        // never true and long transcripts were silently truncated).
        if let source = timeline.source,
           let streamed = try? await Self.streamReplayMessages(
               source: source,
               locator: timeline.locator,
               limit: limit + 1
           ),
           !streamed.isEmpty {
            let entries = Self.replayEntries(from: streamed, limit: limit)
            return EngramServiceReplayTimelineResponse(
                sessionId: request.sessionId,
                source: source,
                entries: entries,
                totalEntries: entries.count,
                hasMore: streamed.count > limit,
                offset: 0,
                limit: limit
            )
        }

        // Fallback: synced-only / missing-file / sync:// / adapter unavailable
        // → return the (role-less) FTS-derived timeline so the view degrades
        // gracefully rather than going blank.
        let entries = Self.replayEntries(from: timeline.rows, source: timeline.source, limit: limit)
        return EngramServiceReplayTimelineResponse(
            sessionId: request.sessionId,
            source: timeline.source,
            entries: entries,
            totalEntries: timeline.total,
            hasMore: timeline.total > entries.count,
            offset: 0,
            limit: limit
        )
    }

    /// Stream the real per-message records for replay from the adapter layer.
    /// Returns nil/empty when the locator is unusable (empty / sync:// /
    /// adapter missing / not a MessageAdapter / stream throws) so the caller
    /// falls back to the FTS-derived timeline. Unlike ServiceTranscriptReader,
    /// this keeps .tool-role records (replay needs them).
    private static func streamReplayMessages(
        source: String,
        locator: String,
        limit: Int
    ) async throws -> [ReplayMessage] {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("sync://") else { return [] }
        let sourceName: SourceName? = source == "antigravity-legacy"
            ? .antigravity
            : SourceName(rawValue: source)
        guard let sourceName,
              let adapter = SessionAdapterFactory.defaultAdapters().first(where: { $0.source == sourceName })
        else {
            return []
        }
        let stream = try await adapter.streamMessages(
            locator: trimmed,
            options: StreamMessagesOptions(limit: limit)
        )
        var messages: [ReplayMessage] = []
        for try await message in stream {
            messages.append(
                ReplayMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    timestamp: message.timestamp,
                    toolName: message.toolCalls?.first?.name,
                    inputTokens: message.usage?.inputTokens,
                    outputTokens: message.usage?.outputTokens
                )
            )
            if messages.count >= limit { break }
        }
        return messages
    }

    func embeddingStatus() async throws -> EngramServiceEmbeddingStatusResponse {
        try await read { db in
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
        // Extract Sendable scalars inside the read block — a GRDB Row is not
        // Sendable and cannot cross the blocking-read queue hop.
        let session = try await read {
            db -> (id: String, source: String, cwd: String, filePath: String, excerptLines: [String], metadataLines: [String])? in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                      id, source, cwd, file_path, project, model, message_count,
                      user_message_count, assistant_message_count, tool_message_count,
                      generated_title, summary
                    FROM sessions
                    WHERE id = ?
                """,
                arguments: [request.sessionId]
            ) else {
                return nil
            }
            let sessionId: String = row["id"]
            let excerpts = try Self.resumeContextExcerpts(db: db, sessionId: sessionId)
            return (
                id: sessionId,
                source: row["source"],
                cwd: (row["cwd"] as String?) ?? "",
                filePath: (row["file_path"] as String?) ?? "",
                excerptLines: excerpts,
                metadataLines: Self.resumeMetadataContextLines(row: row)
            )
        }

        guard let session else {
            return EngramServiceResumeCommandResponse(
                error: "Session not found",
                hint: ""
            )
        }

        let sessionId: String = session.id
        let source: String = session.source
        let cwd: String = session.cwd
        var contextLines = session.excerptLines
        if contextLines.isEmpty {
            contextLines = await Self.resumeTranscriptContextLines(
                filePath: session.filePath,
                source: source
            )
        }
        if contextLines.isEmpty {
            contextLines = session.metadataLines
        }
        let contextPrimer = Self.resumeContextPrimer(
            sessionId: sessionId,
            source: source,
            cwd: cwd,
            contextLines: contextLines
        )
        switch source {
        case "claude-code":
            return resumeCLICommand(
                source: source,
                tool: "claude",
                sessionId: sessionId,
                cwd: cwd,
                contextPrimer: contextPrimer,
                installHint: "Install: npm install -g @anthropic-ai/claude-code"
            )
        case "codex":
            return resumeCLICommand(
                source: source,
                tool: "codex",
                sessionId: sessionId,
                cwd: cwd,
                contextPrimer: contextPrimer,
                installHint: "Install: npm install -g @openai/codex"
            )
        case "gemini-cli":
            return resumeCLICommand(
                source: source,
                tool: "gemini",
                sessionId: sessionId,
                cwd: cwd,
                contextPrimer: contextPrimer,
                installHint: "Install: npm install -g @google/gemini-cli"
            )
        case "cursor":
            return Self.openBasedResumeCommand(source: source, cwd: cwd, contextPrimer: contextPrimer)
        default:
            return Self.openBasedResumeCommand(source: source, cwd: cwd, contextPrimer: contextPrimer)
        }
    }

    static func openBasedResumeCommand(
        source: String,
        cwd: String,
        contextPrimer: String?
    ) -> EngramServiceResumeCommandResponse {
        guard !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return emptyCwdResumeResponse(contextPrimer: contextPrimer)
        }
        if source == "cursor" {
            return EngramServiceResumeCommandResponse(
                tool: "cursor",
                command: "open",
                args: ["-a", "Cursor", cwd],
                cwd: cwd,
                contextPrimer: contextPrimer
            )
        }
        return EngramServiceResumeCommandResponse(
            tool: source,
            command: "open",
            args: [cwd],
            cwd: cwd,
            contextPrimer: contextPrimer
        )
    }

    private static func emptyCwdResumeResponse(contextPrimer: String?) -> EngramServiceResumeCommandResponse {
        EngramServiceResumeCommandResponse(
            cwd: "",
            contextPrimer: contextPrimer,
            error: "No working directory recorded for this session",
            hint: "Open the transcript from Engram and copy the resume context manually."
        )
    }

    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse {
        let limit = max(1, min(request.limit, 200))
        return try await read { db in
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
        try await read { db in
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

    struct ReplayFTSRow: Sendable {
        let rowid: Int64
        let content: String
    }

    /// Sendable mirror of the adapter-stream fields replay needs. Built outside
    /// the GRDB read{} block (a NormalizedMessage is fine to cross actor hops,
    /// but this small struct keeps the pure entry builder DB-free and testable).
    struct ReplayMessage: Sendable {
        let role: String
        let content: String
        let timestamp: String?
        let toolName: String?
        let inputTokens: Int?
        let outputTokens: Int?
    }

    /// Build replay entries from the real per-message adapter stream. Roles are
    /// preserved (user/assistant/tool), toolName is carried through from
    /// whichever record the adapter attached toolCalls to, tokens map to
    /// Tokens(input,output), and durationToNextMs is computed by diffing
    /// consecutive ISO timestamps (ms, clamped >= 0, nil at the tail or when a
    /// neighbor timestamp is missing/unparseable). The session summary is NEVER
    /// appended, so the phantom trailing entry disappears.
    static func replayEntries(
        from messages: [ReplayMessage],
        limit: Int
    ) -> [EngramServiceReplayTimelineEntry] {
        let bounded = Array(messages.prefix(max(0, limit)))
        return bounded.enumerated().map { index, message in
            let durationToNextMs: Int?
            if index + 1 < bounded.count {
                durationToNextMs = replayDurationMs(
                    from: message.timestamp,
                    to: bounded[index + 1].timestamp
                )
            } else {
                durationToNextMs = nil
            }
            let tokens: EngramServiceReplayTimelineEntry.Tokens?
            if message.inputTokens != nil || message.outputTokens != nil {
                tokens = EngramServiceReplayTimelineEntry.Tokens(
                    input: message.inputTokens ?? 0,
                    output: message.outputTokens ?? 0
                )
            } else {
                tokens = nil
            }
            return EngramServiceReplayTimelineEntry(
                index: index,
                role: message.role,
                type: message.role,
                preview: boundedReplayPreview(message.content),
                timestamp: message.timestamp,
                toolName: message.toolName,
                tokens: tokens,
                durationToNextMs: durationToNextMs
            )
        }
    }

    private static let replayISOFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let replayISOPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func replayParseISO(_ value: String?) -> Date? {
        guard let value else { return nil }
        return replayISOFractional.date(from: value) ?? replayISOPlain.date(from: value)
    }

    private static func replayDurationMs(from: String?, to: String?) -> Int? {
        guard let start = replayParseISO(from), let end = replayParseISO(to) else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    static func replayEntries(
        from rows: [ReplayFTSRow],
        source: String?,
        limit: Int
    ) -> [EngramServiceReplayTimelineEntry] {
        rows.prefix(max(0, limit)).enumerated().map { index, row in
            let parsed = replayRoleAndPreview(row.content)
            return EngramServiceReplayTimelineEntry(
                index: index,
                role: parsed.role,
                type: parsed.type,
                preview: parsed.preview,
                timestamp: nil,
                toolName: nil,
                tokens: nil,
                durationToNextMs: nil
            )
        }
    }

    private static func replayRoleAndPreview(_ content: String) -> (role: String, type: String, preview: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, role) in [("User:", "user"), ("Assistant:", "assistant"), ("Tool:", "tool")] {
            if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let preview = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (role, role, boundedReplayPreview(preview))
            }
        }
        return ("unknown", "message", boundedReplayPreview(trimmed))
    }

    private static func boundedReplayPreview(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(2_000))
    }

    private func read<T: Sendable>(_ block: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        let databaseReader = self.databaseReader
        return try await withCheckedThrowingContinuation { continuation in
            Self.blockingReadQueue.async {
                do {
                    continuation.resume(returning: try databaseReader.read(block))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func tableExists(_ table: String, db: GRDB.Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
            arguments: [table]
        ) ?? 0
        return count > 0
    }

    private func tableColumnNames(_ table: String, db: GRDB.Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.map { $0["name"] as String })
    }

    private func sourceSearchableCounts(_ db: GRDB.Database) throws -> [String: Int] {
        guard try tableExists("sessions_fts", db: db) else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.source AS source, COUNT(DISTINCT f.session_id) AS count
            FROM sessions_fts f
            JOIN sessions s ON s.id = f.session_id
            WHERE s.hidden_at IS NULL
            GROUP BY s.source
        """)
        return sourceCountDictionary(rows)
    }

    private func sourceFailedIndexJobCounts(_ db: GRDB.Database) throws -> [String: Int] {
        guard try tableExists("session_index_jobs", db: db) else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.source AS source, COUNT(*) AS count
            FROM session_index_jobs j
            JOIN sessions s ON s.id = j.session_id
            WHERE s.hidden_at IS NULL
              AND j.status IN ('failed_retryable', 'failed_terminal', 'failed')
            GROUP BY s.source
        """)
        return sourceCountDictionary(rows)
    }

    private func sourceTokenCounts(_ db: GRDB.Database) throws -> [String: Int] {
        guard try tableExists("session_costs", db: db) else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.source AS source, COUNT(DISTINCT c.session_id) AS count
            FROM session_costs c
            JOIN sessions s ON s.id = c.session_id
            WHERE s.hidden_at IS NULL
              AND (
                COALESCE(c.input_tokens, 0)
                + COALESCE(c.output_tokens, 0)
                + COALESCE(c.cache_read_tokens, 0)
                + COALESCE(c.cache_creation_tokens, 0)
              ) > 0
            GROUP BY s.source
        """)
        return sourceCountDictionary(rows)
    }

    private func sourceCostedCounts(_ db: GRDB.Database) throws -> [String: Int] {
        guard try tableExists("session_costs", db: db) else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.source AS source, COUNT(DISTINCT c.session_id) AS count
            FROM session_costs c
            JOIN sessions s ON s.id = c.session_id
            WHERE s.hidden_at IS NULL
              AND COALESCE(c.cost_usd, 0) > 0
            GROUP BY s.source
        """)
        return sourceCountDictionary(rows)
    }

    private struct LatestSourceUsage {
        var metric: String
        var value: Double
        var unit: String?
        var limitValue: Double?
        var resetAt: String?
        var status: String
    }

    private func sourceLatestUsage(_ db: GRDB.Database) throws -> [String: LatestSourceUsage] {
        guard try tableExists("usage_snapshots", db: db) else { return [:] }
        let columns = try tableColumnNames("usage_snapshots", db: db)
        let statusExpression = columns.contains("status") ? "u.status" : "NULL"
        let normalizedStatusExpression = "LOWER(TRIM(COALESCE(\(statusExpression), '')))"
        let limitExpression = columns.contains("limit_value") ? "u.limit_value" : "NULL"
        let rows = try Row.fetchAll(db, sql: """
            SELECT u.source AS source,
                   u.metric AS metric,
                   u.value AS value,
                   u.unit AS unit,
                   u.reset_at AS reset_at,
                   \(limitExpression) AS limit_value,
                   \(statusExpression) AS status
            FROM usage_snapshots u
            JOIN (
                SELECT source, MAX(collected_at) AS collected_at
                FROM usage_snapshots
                GROUP BY source
            ) latest
              ON latest.source = u.source
             AND latest.collected_at = u.collected_at
            ORDER BY u.source,
                     CASE
                       WHEN \(normalizedStatusExpression) = 'critical' THEN 0
                       WHEN \(normalizedStatusExpression) = 'attention' THEN 1
                       WHEN LOWER(u.metric) LIKE '%pressure%' THEN 2
                       WHEN LOWER(u.metric) LIKE '%used%'
                         OR LOWER(u.metric) LIKE '%usage%'
                         OR LOWER(u.metric) LIKE '%remaining%' THEN 2
                       WHEN LOWER(u.metric) LIKE '5h%token%share%' THEN 3
                       WHEN LOWER(u.metric) LIKE '7d%token%share%' THEN 4
                       WHEN LOWER(u.metric) LIKE '%cost%share%' THEN 5
                       ELSE 6
                     END,
                     u.metric
        """)
        var result: [String: LatestSourceUsage] = [:]
        for row in rows {
            let source: String = row["source"]
            guard result[source] == nil else { continue }
            result[source] = LatestSourceUsage(
                metric: row["metric"],
                value: row["value"],
                unit: row["unit"] as String?,
                limitValue: row["limit_value"] as Double?,
                resetAt: row["reset_at"] as String?,
                status: sourceUsageStatus(
                    explicitStatus: row["status"] as String?,
                    metric: row["metric"],
                    value: row["value"],
                    unit: row["unit"] as String?
                )
            )
        }
        return result
    }

    private func sourceCountDictionary(_ rows: [Row]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["source"] as String, row["count"] as Int)
        })
    }

    private func sourceHealthStatus(
        sessionCount: Int,
        searchableSessionCount: Int,
        failedIndexJobCount: Int,
        latestUsageStatus: String?
    ) -> String {
        if sessionCount == 0 { return "empty" }
        if latestUsageStatus == "critical" { return "critical" }
        if failedIndexJobCount > 0 { return "attention" }
        if latestUsageStatus == "attention" { return "attention" }
        if searchableSessionCount < sessionCount { return "partial" }
        return "healthy"
    }

    private func sourceUsageStatus(explicitStatus: String?, metric: String, value: Double, unit: String?) -> String {
        if let explicitStatus {
            let normalizedStatus = explicitStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["critical", "attention", "ok", "observed"].contains(normalizedStatus) {
                return normalizedStatus
            }
        }
        guard isPercentUnit(unit) else { return "observed" }
        let normalizedMetric = metric.lowercased()
        let pressure: Double?
        if normalizedMetric.contains("remaining") {
            pressure = 100 - value
        } else if normalizedMetric.contains("used") || normalizedMetric.contains("usage") {
            pressure = value
        } else {
            pressure = nil
        }
        guard let pressure else { return "observed" }
        if pressure >= 90 { return "critical" }
        if pressure >= 70 { return "attention" }
        return "observed"
    }

    private func isPercentUnit(_ unit: String?) -> Bool {
        unit == nil || unit == "%"
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

    /// Upper bound on the search snippet length returned over IPC. `f.content`
    /// in `sessions_fts` holds the full session text, which can be megabytes;
    /// returning it verbatim per result can blow the transport frame cap and
    /// waste bandwidth. Bound it server-side to a preview-sized window.
    static let maxSnippetLength = 600

    private func item(from row: Row, query: String? = nil) -> EngramServiceSearchResponse.Item {
        // MATCH/LIKE paths return matched content; when a query is supplied,
        // build the match-centered highlight here in Swift.
        let rawSnippet = row["snippet"] as String?
        let snippetText: String?
        if let query, let content = rawSnippet,
           let windowed = Self.highlightedSnippet(content: content, query: query) {
            snippetText = windowed
        } else {
            snippetText = rawSnippet
        }
        return EngramServiceSearchResponse.Item(
            id: row["id"],
            title: (row["generated_title"] as String?) ?? (row["summary"] as String?),
            snippet: Self.truncateSnippet(snippetText),
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
            linkSource: row["link_source"] as String?,
            qualityScore: row["quality_score"] as Int?
        )
    }

    private static func highlightedSnippet(content: String, query: String) -> String? {
        if let exact = CJKText.cjkHighlightedSnippet(content: content, query: query) {
            return exact
        }
        for term in query.split(whereSeparator: { $0.isWhitespace }) {
            if let match = CJKText.cjkHighlightedSnippet(content: content, query: String(term)) {
                return match
            }
        }
        return nil
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
        contextPrimer: String?,
        installHint: String
    ) -> EngramServiceResumeCommandResponse {
        guard let path = commandLocator(tool) else {
            return EngramServiceResumeCommandResponse(
                contextPrimer: contextPrimer,
                error: "\(source) CLI not found",
                hint: installHint
            )
        }
        return EngramServiceResumeCommandResponse(
            tool: tool,
            command: path,
            args: Self.resumeArguments(tool: tool, sessionId: sessionId),
            cwd: cwd,
            contextPrimer: contextPrimer
        )
    }

    static func resumeArguments(tool: String, sessionId: String) -> [String] {
        switch tool {
        case "codex":
            return ["resume", sessionId]
        case "gemini":
            return ["--resume", sessionId]
        default:
            return ["--resume", sessionId]
        }
    }

    private static func resumeContextExcerpts(db: GRDB.Database, sessionId: String) throws -> [String] {
        guard try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table', 'view') AND name = 'sessions_fts'"
        ) ?? 0 > 0 else {
            return []
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT content FROM (
                    SELECT rowid, content
                    FROM (
                        SELECT rowid, content
                        FROM sessions_fts
                        WHERE session_id = ?
                        ORDER BY rowid
                        LIMIT 1
                    )
                    UNION
                    SELECT rowid, content
                    FROM (
                        SELECT rowid, content
                        FROM sessions_fts
                        WHERE session_id = ?
                        ORDER BY rowid DESC
                        LIMIT 5
                    )
                )
                ORDER BY rowid
            """,
            arguments: [sessionId, sessionId]
        )
        return rows.compactMap { row in
            let redacted = TranscriptExportService.redactSensitiveContent((row["content"] as String?) ?? "")
            return sanitizedResumeContextExcerpt(redacted)
        }
    }

    private static func resumeContextPrimer(
        sessionId: String,
        source: String,
        cwd: String,
        contextLines: [String]
    ) -> String? {
        guard !contextLines.isEmpty else { return nil }
        var lines = [
            "Resume context from Engram archive:",
            "Session: \(sessionId)",
            "Source: \(source)",
            "CWD: \(cwd)",
            "",
            "Archived context:"
        ]
        lines.append(contentsOf: contextLines.map { "- \($0)" })
        return String(lines.joined(separator: "\n").prefix(4_000))
    }

    private static func resumeTranscriptContextLines(filePath: String, source: String) async -> [String] {
        let trimmedPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return [] }
        guard let messages = try? await ServiceTranscriptReader.readMessages(filePath: trimmedPath, source: source) else {
            return []
        }
        return resumeTranscriptPrimerMessages(messages).compactMap { message in
            let redacted = TranscriptExportService.redactSensitiveContent(message.content)
            guard let content = sanitizedResumeContextExcerpt(redacted) else { return nil }
            let role = message.role == "user" ? "User" : "Assistant"
            return "\(role): \(content)"
        }
    }

    private static func resumeTranscriptPrimerMessages(
        _ messages: [ServiceTranscriptMessage],
        limit: Int = 6
    ) -> [ServiceTranscriptMessage] {
        guard limit > 0 else { return [] }
        guard messages.count > limit else { return Array(messages.prefix(limit)) }
        if limit == 1 {
            return [messages[0]]
        }
        return [messages[0]] + Array(messages.suffix(limit - 1))
    }

    private static func resumeMetadataContextLines(row: Row) -> [String] {
        var lines: [String] = []
        if let title = sanitizedResumeContextExcerpt(row["generated_title"] as String?) {
            lines.append("Title: \(title)")
        }
        if let summary = sanitizedResumeContextExcerpt(row["summary"] as String?) {
            lines.append("Summary: \(summary)")
        }
        if let project = sanitizedResumeContextExcerpt(row["project"] as String?) {
            lines.append("Project: \(project)")
        }
        if let model = sanitizedResumeContextExcerpt(row["model"] as String?) {
            lines.append("Model: \(model)")
        }
        let messageCount: Int = row["message_count"]
        let userMessageCount: Int = row["user_message_count"]
        let assistantMessageCount: Int = row["assistant_message_count"]
        let toolMessageCount: Int = row["tool_message_count"]
        if messageCount > 0 || userMessageCount > 0 || assistantMessageCount > 0 || toolMessageCount > 0 {
            lines.append(
                "Messages: \(messageCount) total, \(userMessageCount) user, \(assistantMessageCount) assistant, \(toolMessageCount) tool"
            )
        }
        return lines
    }

    private static func sanitizedResumeContextExcerpt(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(500))
    }

    nonisolated private static func defaultCommandLocator(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        var seen = Set<String>()
        let searchPaths = ((environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            + [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/opt/homebrew/sbin",
                "/usr/local/sbin",
            ])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
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
