import Foundation
import GRDB
import EngramCoreRead

protocol EngramServiceReadProvider: Sendable {
    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse
    func health() async throws -> EngramServiceHealthResponse
    func liveSessions() async throws -> EngramServiceLiveSessionsResponse
    func sources() async throws -> [EngramServiceSourceInfo]
    func memoryFiles() async throws -> [EngramServiceMemoryFile]
    func memoryFileContent(_ request: EngramServiceMemoryFileContentRequest) async throws -> EngramServiceMemoryFileContentResponse
    func insights() async throws -> [EngramServiceInsightInfo]
    func insightDetail(_ request: EngramServiceInsightDetailRequest) async throws -> EngramServiceInsightInfo?
    func costs() async throws -> EngramServiceCostsResponse
    func replayTimeline(_ request: EngramServiceReplayTimelineRequest) async throws -> EngramServiceReplayTimelineResponse
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

    func memoryFiles() async throws -> [EngramServiceMemoryFile] {
        []
    }

    func memoryFileContent(_ request: EngramServiceMemoryFileContentRequest) async throws -> EngramServiceMemoryFileContentResponse {
        EngramServiceMemoryFileContentResponse(path: request.path, content: "", truncated: false)
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
    private static let liveSessionResultLimit = 100
    static let liveSessionCacheTTL: TimeInterval = 30

    private let homeDirectory: URL
    private let liveSessionCache: LiveSessionScanCache
    private let now: @Sendable () -> Date

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        liveSessionCacheTTL: TimeInterval = FileSystemEngramServiceReadProvider.liveSessionCacheTTL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
        self.liveSessionCache = LiveSessionScanCache(ttl: liveSessionCacheTTL)
    }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: nil)
    }

    func health() async throws -> EngramServiceHealthResponse {
        EngramServiceHealthResponse(ok: true, status: "healthy", message: "Swift service ready")
    }

    func liveSessions() async throws -> EngramServiceLiveSessionsResponse {
        let sessions = try await liveSessionCache.sessions(now: now()) { now in
            try scanLiveSessions(now: now)
        }
        return EngramServiceLiveSessionsResponse(sessions: sessions, count: sessions.count)
    }

    func sources() async throws -> [EngramServiceSourceInfo] {
        []
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

    private func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = homeDirectory.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    private struct LiveSessionRoot {
        var source: String
        var url: URL
        var extensions: Set<String>
    }

    private struct LiveSessionCandidate {
        var source: String
        var file: URL
        var modifiedAt: Date
    }

    private actor LiveSessionScanCache {
        private let ttl: TimeInterval
        private var cachedAt: Date?
        private var cachedSessions: [EngramServiceLiveSessionInfo]?

        init(ttl: TimeInterval) {
            self.ttl = ttl
        }

        func sessions(
            now: Date,
            load: @Sendable (Date) throws -> [EngramServiceLiveSessionInfo]
        ) throws -> [EngramServiceLiveSessionInfo] {
            if let cachedAt, let cachedSessions, now.timeIntervalSince(cachedAt) < ttl {
                return cachedSessions
            }
            let sessions = try load(now)
            cachedAt = now
            cachedSessions = sessions
            return sessions
        }
    }

    private func scanLiveSessions(now: Date) throws -> [EngramServiceLiveSessionInfo] {
        let roots: [LiveSessionRoot] = [
            LiveSessionRoot(source: "codex", url: homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true), extensions: ["jsonl"]),
            LiveSessionRoot(source: "claude-code", url: homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true), extensions: ["jsonl"]),
            LiveSessionRoot(source: "gemini-cli", url: homeDirectory.appendingPathComponent(".gemini/tmp", isDirectory: true), extensions: ["json"]),
            LiveSessionRoot(source: "antigravity", url: homeDirectory.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true), extensions: ["json", "jsonl"]),
            LiveSessionRoot(source: "antigravity", url: homeDirectory.appendingPathComponent(".gemini/antigravity", isDirectory: true), extensions: ["json", "jsonl"]),
            LiveSessionRoot(source: "opencode", url: homeDirectory.appendingPathComponent(".local/share/opencode", isDirectory: true), extensions: ["db"]),
        ]
        let activeWindow: TimeInterval = 2 * 60
        let idleWindow: TimeInterval = 15 * 60
        let recentWindow: TimeInterval = 24 * 60 * 60
        var candidates: [LiveSessionCandidate] = []
        var seen = Set<String>()

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.url.path) else { continue }
            if (try? root.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                try considerLiveSessionCandidate(
                    root.url,
                    root: root,
                    now: now,
                    recentWindow: recentWindow,
                    seen: &seen,
                    candidates: &candidates
                )
            } else {
                let enumerator = FileManager.default.enumerator(
                    at: root.url,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
                if let enumerator {
                    while let file = enumerator.nextObject() as? URL {
                        try considerLiveSessionCandidate(
                            file,
                            root: root,
                            now: now,
                            recentWindow: recentWindow,
                            seen: &seen,
                            candidates: &candidates
                        )
                    }
                }
            }
        }
        // Sort + cap ONCE after the full scan. The per-insert sort+truncate this
        // replaces re-sorted the whole array on every accepted file (O(M·N log N));
        // a single sort is O(M log M) and produces the identical top-N result set.
        candidates.sort {
            if $0.modifiedAt == $1.modifiedAt {
                return $0.file.path < $1.file.path
            }
            return $0.modifiedAt > $1.modifiedAt
        }
        return candidates.prefix(Self.liveSessionResultLimit).map { candidate in
            let metadata = parseLiveMetadata(from: candidate.file)
            let age = now.timeIntervalSince(candidate.modifiedAt)
            let level = age <= activeWindow ? "active" : (age <= idleWindow ? "idle" : "recent")
            return EngramServiceLiveSessionInfo(
                source: candidate.source,
                sessionId: metadata.sessionId,
                project: metadata.project,
                title: metadata.title,
                cwd: metadata.cwd,
                filePath: candidate.file.path,
                startedAt: metadata.startedAt,
                model: metadata.model,
                currentActivity: metadata.activity,
                lastModifiedAt: isoString(candidate.modifiedAt),
                activityLevel: level
            )
        }
    }

    private func considerLiveSessionCandidate(
        _ file: URL,
        root: LiveSessionRoot,
        now: Date,
        recentWindow: TimeInterval,
        seen: inout Set<String>,
        candidates: inout [LiveSessionCandidate]
    ) throws {
        guard root.extensions.contains(file.pathExtension.lowercased()) else { return }
        // Claude Code subagent transcripts live under a `/subagents/` directory
        // and are churn accessed through their parent session, not independent
        // live sessions — keep them out of the live scan.
        guard !file.pathComponents.contains("subagents") else { return }
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else { return }
        let age = now.timeIntervalSince(modifiedAt)
        guard age >= 0, age <= recentWindow else { return }
        guard seen.insert(file.path).inserted else { return }
        candidates.append(LiveSessionCandidate(source: root.source, file: file, modifiedAt: modifiedAt))
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
    private let embeddingEnvironment: [String: String]
    private let embeddingProviderFactory: @Sendable (EmbeddingConfig) -> any EmbeddingProvider

    init(
        databasePath: String,
        fileSystemProvider: FileSystemEngramServiceReadProvider = FileSystemEngramServiceReadProvider(),
        makeDatabaseReader: (String) throws -> any ServiceDatabaseReading = { path in
            try ServiceDatabaseReader(path: path)
        },
        commandLocator: @escaping @Sendable (String) -> String? = { name in
            SQLiteEngramServiceReadProvider.defaultCommandLocator(name)
        },
        embeddingEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        embeddingProviderFactory: @escaping @Sendable (EmbeddingConfig) -> any EmbeddingProvider = {
            EngramServiceRunner.defaultGuardedEmbeddingProvider(config: $0)
        }
    ) throws {
        self.databaseReader = try makeDatabaseReader(databasePath)
        self.fileSystemProvider = fileSystemProvider
        self.commandLocator = commandLocator
        self.embeddingEnvironment = embeddingEnvironment
        self.embeddingProviderFactory = embeddingProviderFactory
    }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedMode = request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let semanticRequested = ["semantic", "hybrid", "both"].contains(requestedMode)
        guard query.count >= 2 else {
            let warning: String? = semanticRequested
                ? "Semantic search is unavailable in the local service; returning keyword results only."
                : nil
            return EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: warning)
        }

        let limit = max(1, min(request.limit, 100))
        if semanticRequested {
            do {
                if let semantic = try await semanticSearch(
                    query: query,
                    request: request,
                    limit: limit,
                    requestedMode: requestedMode
                ) {
                    return semantic
                }
            } catch {
                ServiceLogger.warn(
                    "semantic search failed; falling back to keyword: \(error.localizedDescription)",
                    category: .reader
                )
            }
            ServiceLogger.info(
                "search mode '\(requestedMode)' requested but unavailable; falling back to keyword",
                category: .reader
            )
        }

        let warning: String? = semanticRequested
            ? "Semantic search is unavailable in the local service; returning keyword results only."
            : nil
        return try await keywordSearch(query: query, request: request, limit: limit, warning: warning)
    }

    private func keywordSearch(
        query: String,
        request: EngramServiceSearchRequest,
        limit: Int,
        warning: String?
    ) async throws -> EngramServiceSearchResponse {
        try await read { db in
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
                      AND \(SessionSemanticSearchPolicy.searchableTierSQL)
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
                  AND \(SessionSemanticSearchPolicy.searchableTierSQL)
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

    private struct SemanticChunkCandidate: Sendable {
        let chunkId: String
        let sessionId: String
        let text: String
        let vector: [Float]
    }

    private func semanticSearch(
        query: String,
        request: EngramServiceSearchRequest,
        limit: Int,
        requestedMode: String
    ) async throws -> EngramServiceSearchResponse? {
        guard let config = EmbeddingSettings.load(environment: embeddingEnvironment) else {
            return nil
        }
        let provider = embeddingProviderFactory(config)
        let vectors = try await provider.embed([query])
        guard let queryVector = vectors.first, !queryVector.isEmpty else { return nil }

        let candidates = try await semanticChunkCandidates(for: request, dim: queryVector.count)
        guard !candidates.isEmpty else { return nil }

        let byChunkId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.chunkId, $0) })
        // KNN shortlist size coupled with MCP via SessionSemanticSearchPolicy.
        let hits = VectorSearch.knn(
            query: queryVector,
            candidates: candidates.map { VectorSearch.Candidate(id: $0.chunkId, vector: $0.vector) },
            topK: SessionSemanticSearchPolicy.knnTopK(limit: limit)
        )
        var sessionIds: [String] = []
        var snippetBySession: [String: String] = [:]
        var scoreBySession: [String: Double] = [:]
        for hit in hits {
            guard let candidate = byChunkId[hit.id], !sessionIds.contains(candidate.sessionId) else {
                continue
            }
            sessionIds.append(candidate.sessionId)
            snippetBySession[candidate.sessionId] = candidate.text
            scoreBySession[candidate.sessionId] = Double(hit.score)
            if sessionIds.count >= limit { break }
        }
        guard !sessionIds.isEmpty else { return nil }

        let semanticItems = try await searchItems(
            sessionIds: sessionIds,
            query: nil,
            snippetBySession: snippetBySession,
            matchType: "semantic",
            scoreBySession: scoreBySession
        )

        if requestedMode == "hybrid" || requestedMode == "both" {
            let keyword = try await keywordSearch(query: query, request: request, limit: limit, warning: nil)
            // RRF k coupled with MCP via SessionSemanticSearchPolicy.rrfK.
            let fusedIds = RankFusion.rrf(
                [keyword.items.map(\.id), semanticItems.map(\.id)],
                k: SessionSemanticSearchPolicy.rrfK
            )
                .prefix(limit)
                .map(\.id)
            let keywordById = Dictionary(uniqueKeysWithValues: keyword.items.map { ($0.id, $0) })
            let semanticById = Dictionary(uniqueKeysWithValues: semanticItems.map { ($0.id, $0) })
            let fusedItems = fusedIds.compactMap { id in
                semanticById[id] ?? keywordById[id]
            }
            return EngramServiceSearchResponse(
                items: fusedItems,
                searchModes: ["keyword", "semantic"],
                warning: nil
            )
        }

        return EngramServiceSearchResponse(
            items: semanticItems,
            searchModes: ["semantic"],
            warning: nil
        )
    }

    private func semanticChunkCandidates(
        for request: EngramServiceSearchRequest,
        dim: Int
    ) async throws -> [SemanticChunkCandidate] {
        try await read { db in
            guard try tableExists("semantic_chunks", db: db) else { return [] }
            // Prefer embedding_meta model so we never fuse mixed-model vectors.
            let metaModel: String? = try {
                guard try tableExists("embedding_meta", db: db) else { return nil }
                return try String.fetchOne(
                    db,
                    sql: "SELECT model FROM embedding_meta WHERE id = 1 LIMIT 1"
                )?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            }()
            var parts = ["""
                SELECT sc.id AS chunk_id,
                       sc.session_id AS session_id,
                       sc.text AS text,
                       sc.embedding AS embedding
                FROM semantic_chunks sc
                JOIN sessions s ON s.id = sc.session_id
                WHERE sc.embedding IS NOT NULL
                  AND sc.dim = ?
                  AND s.hidden_at IS NULL
                  AND \(SessionSemanticSearchPolicy.searchableTierSQL)
            """]
            var args: [DatabaseValueConvertible] = [dim]
            if let metaModel, !metaModel.isEmpty {
                parts.append("AND sc.model = ?")
                args.append(metaModel)
            }
            appendSearchFilters(for: request, to: &parts, args: &args)
            parts.append("ORDER BY s.start_time DESC LIMIT ?")
            args.append(SessionSemanticSearchPolicy.candidateCap(requestLimit: request.limit))
            let rows = try Row.fetchAll(
                db,
                sql: parts.joined(separator: " "),
                arguments: StatementArguments(args)
            )
            return rows.compactMap { row in
                guard let chunkId = row["chunk_id"] as String?,
                      let sessionId = row["session_id"] as String?,
                      let text = row["text"] as String?,
                      let data = row["embedding"] as Data? else {
                    return nil
                }
                guard let vector = VectorMath.decode(data, expectedCount: dim) else { return nil }
                return SemanticChunkCandidate(
                    chunkId: chunkId,
                    sessionId: sessionId,
                    text: text,
                    vector: vector
                )
            }
        }
    }

    private func searchItems(
        sessionIds: [String],
        query: String?,
        snippetBySession: [String: String],
        matchType: String,
        scoreBySession: [String: Double]
    ) async throws -> [EngramServiceSearchResponse.Item] {
        guard !sessionIds.isEmpty else { return [] }
        return try await read { db in
            let placeholders = Array(repeating: "?", count: sessionIds.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT s.* FROM sessions s WHERE s.id IN (\(placeholders))",
                arguments: StatementArguments(sessionIds)
            )
            let rowsById = Dictionary(uniqueKeysWithValues: rows.map { (($0["id"] as String), $0) })
            return sessionIds.compactMap { id in
                guard let row = rowsById[id] else { return nil }
                return item(
                    from: row,
                    query: query,
                    snippetOverride: snippetBySession[id],
                    matchType: matchType,
                    score: scoreBySession[id]
                )
            }
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

    func memoryFiles() async throws -> [EngramServiceMemoryFile] {
        try await fileSystemProvider.memoryFiles()
    }

    func memoryFileContent(_ request: EngramServiceMemoryFileContentRequest) async throws -> EngramServiceMemoryFileContentResponse {
        try await fileSystemProvider.memoryFileContent(request)
    }

    /// Preview length for an insight LIST row. Full content is fetched on demand
    /// via `insightDetail` so the list response stays under the IPC frame.
    static let insightListPreviewLength = 280

    func insights() async throws -> [EngramServiceInsightInfo] {
        try await read { db in
            // The `insights` table is created lazily (only on the first
            // save/delete write), so a fresh DB does not have it. Guard the
            // SELECT with tableExists to avoid "no such table".
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
        // Step 1: fetch ONLY the cheap scalar locator — source + the readable
        // locator (same COALESCE as IndexJobRunner.sessionContentSource). The
        // expensive FTS COUNT + content scan is deferred to Step 3 so the common
        // on-disk path never pays for FTS work it would immediately discard
        // (sessions_fts.session_id is UNINDEXED → each lookup is a full scan).
        // The blocking read queue's @Sendable block cannot await the adapter
        // stream, so streaming happens OUTSIDE this block (precedent:
        // resumeTranscriptContextLines).
        let scalar = try await read {
            db -> (source: String?, locator: String) in
            let row = try Row.fetchOne(
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
            return (row?["source"] as String?, (row?["locator"] as String?) ?? "")
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
        if let source = scalar.source,
           let streamed = try? await Self.streamReplayMessages(
               source: source,
               locator: scalar.locator,
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

        // Step 3 (only when streaming yields nothing): synced-only /
        // missing-file / sync:// / adapter unavailable → run the FTS COUNT +
        // content fetch now and return the (role-less) FTS-derived timeline so
        // the view degrades gracefully rather than going blank.
        let fallback = try await read {
            db -> (rows: [ReplayFTSRow], total: Int) in
            guard scalar.source != nil, try tableExists("sessions_fts", db: db) else {
                return ([], 0)
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
            return (rows, total)
        }

        let entries = Self.replayEntries(from: fallback.rows, source: scalar.source, limit: limit)
        return EngramServiceReplayTimelineResponse(
            sessionId: request.sessionId,
            source: scalar.source,
            entries: entries,
            totalEntries: fallback.total,
            hasMore: fallback.total > entries.count,
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
        let failedStatuses = [
            IndexJobStatus.failedRetryable.rawValue,
            IndexJobStatus.failedPermanent.rawValue,
            IndexJobStatus.failedTerminal.rawValue,
            IndexJobStatus.failed.rawValue
        ]
        let placeholders = Array(repeating: "?", count: failedStatuses.count).joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.source AS source, COUNT(*) AS count
            FROM session_index_jobs j
            JOIN sessions s ON s.id = j.session_id
            WHERE s.hidden_at IS NULL
              AND j.status IN (\(placeholders))
            GROUP BY s.source
        """, arguments: StatementArguments(failedStatuses))
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

    private func item(
        from row: Row,
        query: String? = nil,
        snippetOverride: String? = nil,
        matchType: String = "keyword",
        score: Double? = nil
    ) -> EngramServiceSearchResponse.Item {
        // MATCH/LIKE paths return matched content; when a query is supplied,
        // build the match-centered highlight here in Swift.
        let rawSnippet = snippetOverride ?? (row["snippet"] as String?)
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
            matchType: matchType,
            score: score,
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
        // Windowed read: only the first + last-5 visible messages are needed for
        // the primer, so stream them through a bounded buffer instead of parsing
        // the entire transcript into a full message array.
        guard let result = try? await ServiceTranscriptReader.readPrimerMessagesWithMetadata(
            filePath: trimmedPath,
            source: source,
            limit: 6
        ) else {
            return []
        }
        var lines: [String] = result.messages.compactMap { (message: ServiceTranscriptMessage) -> String? in
            let redacted = TranscriptExportService.redactSensitiveContent(message.content)
            guard let content = sanitizedResumeContextExcerpt(redacted) else { return nil }
            let role = message.role == "user" ? "User" : "Assistant"
            return "\(role): \(content)"
        }
        if result.truncated, let truncatedAt = result.truncatedAt {
            lines.append("Transcript truncated at \(decimalString(truncatedAt)) messages; later content is not included.")
        }
        return lines
    }

    private static func decimalString(_ value: Int) -> String {
        let digits = Array(String(value).reversed())
        var grouped: [Character] = []
        for (index, digit) in digits.enumerated() {
            if index > 0, index % 3 == 0 {
                grouped.append(",")
            }
            grouped.append(digit)
        }
        return String(grouped.reversed())
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
