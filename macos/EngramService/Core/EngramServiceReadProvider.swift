import Darwin
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
    func readImmediate<T>(_ block: (GRDB.Database) throws -> T) throws -> T
}

extension ServiceDatabaseReading {
    func readImmediate<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try read(block)
    }
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
    private let liveSessionScanCheckpoint: (@Sendable (URL) throws -> Void)?
    private let liveSessionFinalizationCheckpoint: @Sendable () throws -> Void

    // docs/invariants.md #6: a no-argument test provider must not scan real transcripts.
    init(
        homeDirectory: URL = EngramUserDataDirectory.resolvedHomeDirectory(),
        liveSessionCacheTTL: TimeInterval = FileSystemEngramServiceReadProvider.liveSessionCacheTTL,
        now: @escaping @Sendable () -> Date = { Date() },
        liveSessionScanCheckpoint: (@Sendable (URL) throws -> Void)? = nil,
        liveSessionFinalizationCheckpoint: @escaping @Sendable () throws -> Void = {}
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
        self.liveSessionScanCheckpoint = liveSessionScanCheckpoint
        self.liveSessionFinalizationCheckpoint = liveSessionFinalizationCheckpoint
        self.liveSessionCache = LiveSessionScanCache(ttl: liveSessionCacheTTL)
    }

    func claudeSubagentLayout(locator: String) -> SubagentTranscriptLayout? {
        let profiles = ClaudeCodeProfileResolver(
            homeDirectory: homeDirectory,
            settingsURL: homeDirectory.appendingPathComponent(".engram/settings.json")
        ).resolve().profiles
        for profile in profiles where profile.available {
            if let layout = SubagentTranscriptPath.layout(
                locator: locator,
                projectsRoot: profile.projectsRoot
            ) {
                return layout
            }
        }
        return nil
    }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        EngramServiceSearchResponse(items: [], searchModes: ["keyword"], warning: nil)
    }

    func health() async throws -> EngramServiceHealthResponse {
        EngramServiceHealthResponse(ok: true, status: "healthy", message: "Swift service ready")
    }

    func liveSessions() async throws -> EngramServiceLiveSessionsResponse {
        let sessions = try await liveSessionCache.sessions(
            now: now(),
            finishedAt: now
        ) { scanStartedAt in
            try scanLiveSessions(now: scanStartedAt)
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
            guard Self.isDirectoryNoFollow(atPath: projectURL.path) else { continue }
            let memoryURL = projectURL.appendingPathComponent("memory", isDirectory: true)
            guard Self.isDirectoryNoFollow(atPath: memoryURL.path) else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: memoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )) ?? []
            for fileURL in files where fileURL.pathExtension == "md" {
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                ), values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                guard let content = Self.readRegularFileNoFollow(
                    atPath: fileURL.path,
                    maxBytes: 512
                ) else { continue }
                // LIST responses carry only a short preview, never the full body:
                // up to 500 memory files × full content would blow past the
                // 256 KiB IPC frame. The detail viewer fetches the full content
                // on demand via `memoryFileContent`.
                results.append(
                    EngramServiceMemoryFile(
                        name: fileURL.lastPathComponent,
                        project: projectURL.lastPathComponent.replacingOccurrences(of: "-", with: "/"),
                        path: displayPath(fileURL),
                        sizeBytes: values.fileSize ?? 0,
                        preview: content.text.prefixString(200),
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
        // Wave 7D H09 + SEC-M2: confine under ~/.claude/projects/*/memory/*.md.
        // Pin each directory component with openat(O_NOFOLLOW) so an ancestor
        // symlink cannot redirect the leaf open.
        let resolved = resolveDisplayPath(request.path)
        let declaredProjectsRoot = homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .standardizedFileURL
        let canonicalProjectsRoot = declaredProjectsRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: resolved).standardizedFileURL
        // Refuse symlink hops before open: lstat the path itself.
        var isSymlink = false
        if let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            isSymlink = true
        }
        guard !isSymlink else {
            return EngramServiceMemoryFileContentResponse(path: request.path, content: "", truncated: false)
        }
        let candidateComponents = candidate.pathComponents
        let declaredRootComponents = declaredProjectsRoot.pathComponents
        let canonicalRootComponents = canonicalProjectsRoot.pathComponents
        let rootComponentCount: Int
        if candidateComponents.starts(with: declaredRootComponents) {
            rootComponentCount = declaredRootComponents.count
        } else if candidateComponents.starts(with: canonicalRootComponents) {
            rootComponentCount = canonicalRootComponents.count
        } else {
            return EngramServiceMemoryFileContentResponse(path: request.path, content: "", truncated: false)
        }
        let parts = Array(candidateComponents.dropFirst(rootComponentCount))
        // Expect: <projectId>/memory/<file.md>  (projectId may contain path segments
        // only if nested under projects; require a "memory" path component before file).
        guard parts.count >= 3,
              parts[parts.count - 2] == "memory",
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              candidate.pathExtension == "md" else {
            return EngramServiceMemoryFileContentResponse(path: request.path, content: "", truncated: false)
        }
        guard let content = Self.readRegularFileNoFollow(
            relativeComponents: parts,
            rootDirectory: canonicalProjectsRoot,
            maxBytes: Self.memoryFileContentCap
        ) else {
            return EngramServiceMemoryFileContentResponse(path: request.path, content: "", truncated: false)
        }
        if content.truncated {
            return EngramServiceMemoryFileContentResponse(
                path: request.path,
                content: content.text + "\n\n… (truncated)",
                truncated: true
            )
        }
        return EngramServiceMemoryFileContentResponse(path: request.path, content: content.text, truncated: false)
    }

    private static func isDirectoryNoFollow(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// SEC-M2: open with O_NOFOLLOW|O_CLOEXEC, fstat regular file, then read.
    private static func readRegularFileNoFollow(
        atPath path: String,
        maxBytes: Int
    ) -> (text: String, truncated: Bool)? {
        let fd = path.withCString { cPath in
            open(cPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return readRegularFile(fileDescriptor: fd, maxBytes: maxBytes)
    }

    private static func readRegularFileNoFollow(
        relativeComponents: [String],
        rootDirectory: URL,
        maxBytes: Int
    ) -> (text: String, truncated: Bool)? {
        guard let fileName = relativeComponents.last,
              relativeComponents.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
              })
        else {
            return nil
        }
        var directoryFD = rootDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { return nil }
        defer { close(directoryFD) }
        for component in relativeComponents.dropLast() {
            let nextFD = component.withCString {
                openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard nextFD >= 0 else { return nil }
            close(directoryFD)
            directoryFD = nextFD
        }
        let fd = fileName.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return readRegularFile(fileDescriptor: fd, maxBytes: maxBytes)
    }

    private static func readRegularFile(
        fileDescriptor fd: Int32,
        maxBytes: Int
    ) -> (text: String, truncated: Bool)? {
        guard maxBytes >= 0, maxBytes < Int.max else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        guard size >= 0 else { return nil }
        let toRead = min(size, maxBytes + 1)
        var buffer = Data()
        buffer.reserveCapacity(toRead)
        var chunk = [UInt8](repeating: 0, count: min(4096, max(1, toRead)))
        while buffer.count < toRead {
            let readCount = chunk.withUnsafeMutableBytes { raw -> Int in
                Int(read(fd, raw.baseAddress, min(raw.count, toRead - buffer.count)))
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                return nil
            }
            buffer.append(contentsOf: chunk.prefix(readCount))
        }
        let bounded = Data(buffer.prefix(maxBytes))
        let maximumTrim = min(3, bounded.count)
        for trailingBytesToDrop in 0...maximumTrim {
            let end = bounded.count - trailingBytesToDrop
            if let text = String(data: bounded.prefix(end), encoding: .utf8) {
                return (text, size > maxBytes || buffer.count > maxBytes)
            }
        }
        return nil
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
        var locator: String
        var explicitSessionID: String?
        var modifiedAt: Date
        var metadata: LiveMetadata? = nil
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
            finishedAt: @Sendable () -> Date,
            load: @Sendable (Date) async throws -> [EngramServiceLiveSessionInfo]
        ) async throws -> [EngramServiceLiveSessionInfo] {
            try Task.checkCancellation()
            if let cachedAt, let cachedSessions, now.timeIntervalSince(cachedAt) < ttl {
                return cachedSessions
            }
            let sessions = try await load(now)
            try Task.checkCancellation()
            cachedAt = finishedAt()
            cachedSessions = sessions
            return sessions
        }
    }

    private func scanLiveSessions(now: Date) throws -> [EngramServiceLiveSessionInfo] {
        var roots: [LiveSessionRoot] = [
            LiveSessionRoot(source: "codex", url: homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true), extensions: ["jsonl"]),
        ]
        let claudeProfiles = ClaudeCodeProfileResolver(
            homeDirectory: homeDirectory,
            settingsURL: homeDirectory.appendingPathComponent(".engram/settings.json")
        ).resolve().profiles
        roots += claudeProfiles.filter(\.available).map {
            LiveSessionRoot(
                source: "claude-code",
                url: URL(fileURLWithPath: $0.projectsRoot, isDirectory: true),
                extensions: ["jsonl"]
            )
        }
        let activeWindow: TimeInterval = 2 * 60
        let idleWindow: TimeInterval = 15 * 60
        let recentWindow: TimeInterval = 24 * 60 * 60
        var candidates: [LiveSessionCandidate] = []
        var seen = Set<String>()

        for configuredRoot in roots {
            try Task.checkCancellation()
            var root = configuredRoot
            root.url = URL(
                fileURLWithPath: FileSystemPathIdentity.realpathPath(configuredRoot.url.path),
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: root.url.path) else { continue }
            let rootValues = try? root.url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey]
            )
            if rootValues?.isRegularFile == true {
                try considerLiveSessionCandidate(
                    root.url,
                    root: root,
                    now: now,
                    recentWindow: recentWindow,
                    resourceValues: rootValues,
                    seen: &seen,
                    candidates: &candidates
                )
            } else if root.source == "claude-code" {
                try enumerateClaudeLiveFiles(under: root.url) { file, values in
                    try considerLiveSessionCandidate(
                        file,
                        root: root,
                        now: now,
                        recentWindow: recentWindow,
                        resourceValues: values,
                        seen: &seen,
                        candidates: &candidates
                    )
                }
            } else {
                var visitedDirectories = Set<String>()
                try enumerateLiveFiles(
                    under: root.url,
                    visitedDirectories: &visitedDirectories
                ) { file, values in
                    try considerLiveSessionCandidate(
                        file,
                        root: root,
                        now: now,
                        recentWindow: recentWindow,
                        resourceValues: values,
                        seen: &seen,
                        candidates: &candidates
                    )
                }
            }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        try appendGeminiLiveCandidates(
            now: now,
            recentWindow: recentWindow,
            seen: &seen,
            candidates: &candidates
        )
        try Task.checkCancellation()
        try appendAntigravityLiveCandidates(
            now: now,
            recentWindow: recentWindow,
            seen: &seen,
            candidates: &candidates
        )
        try Task.checkCancellation()
        try appendOpenCodeLiveCandidates(
            now: now,
            recentWindow: recentWindow,
            seen: &seen,
            candidates: &candidates
        )
        try liveSessionFinalizationCheckpoint()
        try Task.checkCancellation()
        let disabledSources = EngramServiceRunner.readDisabledSources(
            environment: ProcessInfo.processInfo.environment,
            settingsURL: homeDirectory.appendingPathComponent(".engram/settings.json")
        )
        candidates.removeAll { disabledSources.contains($0.source) }
        // Sort + cap ONCE after the full scan. The per-insert sort+truncate this
        // replaces re-sorted the whole array on every accepted file (O(M·N log N));
        // a single sort is O(M log M) and produces the identical top-N result set.
        candidates.sort {
            if $0.modifiedAt == $1.modifiedAt {
                return $0.file.path < $1.file.path
            }
            return $0.modifiedAt > $1.modifiedAt
        }
        try Task.checkCancellation()
        let sessions = try candidates.prefix(Self.liveSessionResultLimit).map { candidate in
            try Task.checkCancellation()
            let metadata = candidate.metadata ?? parseLiveMetadata(
                from: candidate.file,
                source: candidate.source,
                explicitSessionID: candidate.explicitSessionID
            )
            let age = now.timeIntervalSince(candidate.modifiedAt)
            let level = age <= activeWindow ? "active" : (age <= idleWindow ? "idle" : "recent")
            return EngramServiceLiveSessionInfo(
                source: candidate.source,
                sessionId: metadata.sessionId,
                project: metadata.project,
                title: metadata.title,
                cwd: metadata.cwd,
                filePath: candidate.locator,
                startedAt: metadata.startedAt,
                model: metadata.model,
                currentActivity: metadata.activity,
                lastModifiedAt: isoString(candidate.modifiedAt),
                activityLevel: level
            )
        }
        try Task.checkCancellation()
        return sessions
    }

    private func considerLiveSessionCandidate(
        _ file: URL,
        root: LiveSessionRoot,
        now: Date,
        recentWindow: TimeInterval,
        resourceValues: URLResourceValues? = nil,
        seen: inout Set<String>,
        candidates: inout [LiveSessionCandidate]
    ) throws {
        try Task.checkCancellation()
        guard root.extensions.contains(file.pathExtension.lowercased()) else { return }
        if root.source == "codex", !file.lastPathComponent.hasPrefix("rollout-") {
            return
        }
        let values = resourceValues ?? (try? file.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ))
        guard let values else { return }
        guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else { return }
        let age = now.timeIntervalSince(modifiedAt)
        guard age >= 0, age <= recentWindow else { return }
        guard seen.insert(file.path).inserted else { return }
        let source: String
        if root.source == SourceName.claudeCode.rawValue {
            guard let detected = SessionAdapterFactory.detectClaudeCodeSourceHint(locator: file.path) else { return }
            source = detected.rawValue
        } else {
            source = root.source
        }
        candidates.append(
            LiveSessionCandidate(
                source: source,
                file: file,
                locator: file.path,
                explicitSessionID: nil,
                modifiedAt: modifiedAt
            )
        )
    }

    private func appendGeminiLiveCandidates(
        now: Date,
        recentWindow: TimeInterval,
        seen: inout Set<String>,
        candidates: inout [LiveSessionCandidate]
    ) throws {
        try Task.checkCancellation()
        let projectsRoot = homeDirectory.appendingPathComponent(".gemini/tmp", isDirectory: true)
        let projects = directChildren(of: projectsRoot)
        try Task.checkCancellation()
        for project in projects {
            try Task.checkCancellation()
            guard isDirectory(project) else { continue }
            let chats = project.appendingPathComponent("chats", isDirectory: true)
            let files = directChildren(of: chats)
            try Task.checkCancellation()
            for file in files {
                try Task.checkCancellation()
                let name = file.lastPathComponent
                guard !name.hasSuffix(".engram.json"), name != "logs.json",
                      file.pathExtension == "json" || file.pathExtension == "jsonl" else { continue }
                try appendLiveCandidate(
                    source: "gemini-cli",
                    file: file,
                    locator: file.path,
                    explicitSessionID: nil,
                    now: now,
                    recentWindow: recentWindow,
                    seen: &seen,
                    candidates: &candidates
                )
            }
        }
    }

    private func appendAntigravityLiveCandidates(
        now: Date,
        recentWindow: TimeInterval,
        seen: inout Set<String>,
        candidates: inout [LiveSessionCandidate]
    ) throws {
        try Task.checkCancellation()
        let cache = homeDirectory.appendingPathComponent(".engram/cache/antigravity", isDirectory: true)
        let cachedFiles = directChildren(of: cache)
        try Task.checkCancellation()
        for file in cachedFiles {
            try Task.checkCancellation()
            guard file.pathExtension == "jsonl" else { continue }
            try appendLiveCandidate(
                source: "antigravity",
                file: file,
                locator: file.path,
                explicitSessionID: nil,
                now: now,
                recentWindow: recentWindow,
                seen: &seen,
                candidates: &candidates
            )
        }

        let brainRoots = [
            ".gemini/antigravity-cli/brain",
            ".gemini/antigravity/brain",
            ".gemini/antigravity-ide/brain",
        ]
        for relativeRoot in brainRoots {
            try Task.checkCancellation()
            let brain = homeDirectory.appendingPathComponent(relativeRoot, isDirectory: true)
            let sessions = directChildren(of: brain)
            try Task.checkCancellation()
            for session in sessions {
                try Task.checkCancellation()
                guard isDirectory(session) else { continue }
                let transcript = session.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                guard FileManager.default.fileExists(atPath: transcript.path) else { continue }
                try appendLiveCandidate(
                    source: "antigravity",
                    file: transcript,
                    locator: transcript.path,
                    explicitSessionID: session.lastPathComponent,
                    now: now,
                    recentWindow: recentWindow,
                    seen: &seen,
                    candidates: &candidates
                )
            }
        }
    }

    private func appendOpenCodeLiveCandidates(
        now: Date,
        recentWindow: TimeInterval,
        seen: inout Set<String>,
        candidates: inout [LiveSessionCandidate]
    ) throws {
        try Task.checkCancellation()
        let databaseURL = homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db")
        guard let values = try? databaseURL.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return }

        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(0.1)
        let cutoffMilliseconds = Int64(now.addingTimeInterval(-recentWindow).timeIntervalSince1970 * 1_000)
        guard let database = try? DatabaseQueue(path: databaseURL.path, configuration: configuration),
              let rows = try? database.read({ db in
                  let columns = Set(
                      try Row.fetchAll(db, sql: "PRAGMA table_info(session)")
                          .map { $0["name"] as String }
                  )
                  let roleColumns = ["parent_id", "agent", "slug"]
                      .map { columns.contains($0) ? $0 : "NULL AS \($0)" }
                      .joined(separator: ", ")
                  return try Row.fetchAll(db, sql: """
                      SELECT id, directory, title, time_updated, \(roleColumns)
                      FROM session
                      WHERE time_archived IS NULL
                        AND time_updated >= ?
                      ORDER BY time_updated DESC
                      """, arguments: [cutoffMilliseconds])
              }) else { return }

        for row in rows {
            try Task.checkCancellation()
            let id: String = row["id"]
            let directory: String? = row["directory"]
            let title: String? = row["title"]
            let updatedMilliseconds: Int64 = row["time_updated"]
            guard !id.isEmpty else { continue }
            guard !OpenCodeSessionRoleClassifier.isDispatchedChild(
                parentSessionId: row["parent_id"],
                title: title ?? "",
                agent: row["agent"],
                slug: row["slug"]
            ) else { continue }
            let locator = "\(databaseURL.path)::\(id)"
            guard seen.insert(locator).inserted else { continue }
            candidates.append(
                LiveSessionCandidate(
                    source: "opencode",
                    file: databaseURL,
                    locator: locator,
                    explicitSessionID: id,
                    modifiedAt: Date(timeIntervalSince1970: Double(updatedMilliseconds) / 1_000),
                    metadata: LiveMetadata(
                        sessionId: id,
                        project: nil,
                        title: title,
                        cwd: directory,
                        startedAt: nil,
                        model: nil,
                        activity: nil
                    )
                )
            )
        }
    }

    private func appendLiveCandidate(
        source: String,
        file: URL,
        locator: String,
        explicitSessionID: String?,
        now: Date,
        recentWindow: TimeInterval,
        seen: inout Set<String>,
        candidates: inout [LiveSessionCandidate]
    ) throws {
        try Task.checkCancellation()
        guard let values = try? file.resolvingSymlinksInPath().resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else { return }
        let age = now.timeIntervalSince(modifiedAt)
        guard age >= 0, age <= recentWindow, seen.insert(locator).inserted else { return }
        candidates.append(
            LiveSessionCandidate(
                source: source,
                file: file,
                locator: locator,
                explicitSessionID: explicitSessionID,
                modifiedAt: modifiedAt
            )
        )
    }

    private func directChildren(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func enumerateClaudeLiveFiles(
        under projectsRoot: URL,
        visit: (URL, URLResourceValues) throws -> Void
    ) throws {
        try Task.checkCancellation()
        let projects = directChildren(of: projectsRoot)
        try Task.checkCancellation()
        for project in projects {
            try Task.checkCancellation()
            try liveSessionScanCheckpoint?(project)
            guard let projectValues = try? project.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), projectValues.isSymbolicLink != true, projectValues.isDirectory == true else {
                continue
            }

            let files = directChildren(of: project)
            try Task.checkCancellation()
            for file in files {
                try Task.checkCancellation()
                try liveSessionScanCheckpoint?(file)
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
                ), values.isSymbolicLink != true, values.isRegularFile == true else {
                    continue
                }
                try visit(file, values)
            }
            try Task.checkCancellation()
        }
    }

    private func enumerateLiveFiles(
        under directory: URL,
        visitedDirectories: inout Set<String>,
        visit: (URL, URLResourceValues) throws -> Void
    ) throws {
        try Task.checkCancellation()
        guard visitedDirectories.insert(directory.path).inserted else { return }
        let children = directChildren(of: directory)
        try Task.checkCancellation()
        for child in children {
            try Task.checkCancellation()
            try liveSessionScanCheckpoint?(child)
            guard let values = try? child.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            ), values.isSymbolicLink != true else {
                continue
            }
            if values.isDirectory == true {
                try enumerateLiveFiles(
                    under: child,
                    visitedDirectories: &visitedDirectories,
                    visit: visit
                )
            } else if values.isRegularFile == true {
                try visit(child, values)
            }
        }
        try Task.checkCancellation()
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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

    private func parseLiveMetadata(
        from url: URL,
        source: String,
        explicitSessionID sourceSessionID: String?
    ) -> LiveMetadata {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return LiveMetadata(sessionId: sourceSessionID, title: url.lastPathComponent)
        }
        let prefix = Data(data.prefix(64 * 1024))
        guard let text = String(data: prefix, encoding: .utf8) else {
            return LiveMetadata(sessionId: sourceSessionID, title: url.lastPathComponent)
        }
        if source == "antigravity", let object = firstJSONObject(in: text) {
            return LiveMetadata(
                sessionId: sourceSessionID
                    ?? firstStringValue(keys: ["sessionId", "session_id"], in: object)
                    ?? genericID(from: object),
                project: firstStringValue(keys: ["project"], in: object),
                title: firstStringValue(keys: ["generated_title", "title", "summary"], in: object),
                cwd: firstStringValue(keys: ["cwd", "workspace"], in: object),
                startedAt: firstStringValue(keys: ["timestamp", "start_time", "startedAt"], in: object),
                model: firstStringValue(keys: ["model"], in: object),
                activity: firstStringValue(keys: ["activity", "currentActivity"], in: object)
            )
        }
        let metadataSessionID = firstStringValue(keys: ["sessionId", "session_id"], in: text)
        let sessionID = sourceSessionID ?? metadataSessionID ?? genericIDFromFirstJSONObject(in: text)
        return LiveMetadata(
            sessionId: sessionID,
            project: firstStringValue(keys: ["project"], in: text),
            title: firstStringValue(keys: ["generated_title", "title", "summary"], in: text),
            cwd: firstStringValue(keys: ["cwd", "workspace"], in: text),
            startedAt: firstStringValue(keys: ["timestamp", "start_time", "startedAt"], in: text),
            model: firstStringValue(keys: ["model"], in: text),
            activity: firstStringValue(keys: ["activity", "currentActivity"], in: text)
        )
    }

    private func genericIDFromFirstJSONObject(in text: String) -> String? {
        guard let object = firstJSONObject(in: text) else { return nil }
        return genericID(from: object)
    }

    private func firstJSONObject(in text: String) -> [String: Any]? {
        guard let firstLine = text.split(whereSeparator: \.isNewline).first,
              let data = String(firstLine).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func genericID(from object: [String: Any]) -> String? {
        if let id = object["id"] as? String, !id.isEmpty { return id }
        if let payload = object["payload"] as? [String: Any],
           let id = payload["id"] as? String,
           !id.isEmpty {
            return id
        }
        return nil
    }

    private func firstStringValue(keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
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
    private let sessionAdapterProvider: @Sendable () -> [any SessionAdapter]
    private let transcriptPrimerReader: @Sendable (String, String, Int) async throws -> ServiceTranscriptReader.ReadResult

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
        },
        sessionAdapterProvider: @escaping @Sendable () -> [any SessionAdapter] = {
            SessionAdapterFactory.defaultAdapters()
        },
        transcriptPrimerReader: @escaping @Sendable (String, String, Int) async throws -> ServiceTranscriptReader.ReadResult = {
            filePath, source, limit in
            try await ServiceTranscriptReader.readPrimerMessagesWithMetadata(
                filePath: filePath,
                source: source,
                limit: limit
            )
        }
    ) throws {
        self.databaseReader = try makeDatabaseReader(databasePath)
        self.fileSystemProvider = fileSystemProvider
        self.commandLocator = commandLocator
        self.embeddingEnvironment = embeddingEnvironment
        self.embeddingProviderFactory = embeddingProviderFactory
        self.sessionAdapterProvider = sessionAdapterProvider
        self.transcriptPrimerReader = transcriptPrimerReader
    }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedMode = request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let semanticRequested = ["semantic", "hybrid", "both"].contains(requestedMode)
        guard query.count >= 2 else {
            let emptyModes: [String]
            switch requestedMode {
            case "semantic":
                emptyModes = ["semantic"]
            case "hybrid", "both":
                emptyModes = ["keyword", "semantic"]
            default:
                emptyModes = query.isEmpty ? [] : ["keyword"]
            }
            return EngramServiceSearchResponse(
                items: [],
                searchModes: emptyModes,
                warning: nil,
                warningCode: nil
            )
        }

        let limit = max(1, min(request.limit, 100))
        if semanticRequested {
            do {
                switch try await semanticSearch(
                    query: query,
                    request: request,
                    limit: limit,
                    requestedMode: requestedMode
                ) {
                case .results(let response):
                    return response
                case .degraded(let reason, let detail):
                    ServiceLogger.info(
                        "search mode '\(requestedMode)' degraded (\(reason.rawValue)); falling back to keyword",
                        category: .reader
                    )
                    return try await keywordSearch(
                        query: query,
                        request: request,
                        limit: limit,
                        warning: reason.serviceWarning(detail: detail),
                        warningCode: reason.structuredCode
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DatabaseError
                where Self.isSQLiteBusyOrLocked(error) {
                ServiceLogger.warn(
                    "semantic search database was busy; failing closed without a second read",
                    category: .reader
                )
                return EngramServiceSearchResponse(
                    items: [],
                    searchModes: requestedMode == "semantic"
                        ? ["semantic"]
                        : ["keyword", "semantic"],
                    warning: "Search is temporarily unavailable while the Engram database is busy. Retry shortly.",
                    warningCode: "searchFailed"
                )
            } catch {
                ServiceLogger.warn(
                    "semantic search failed: \(error.localizedDescription)",
                    category: .reader
                )
                throw error
            }
        }

        return try await keywordSearch(
            query: query,
            request: request,
            limit: limit,
            warning: nil,
            warningCode: nil
        )
    }

    private func keywordSearch(
        query: String,
        request: EngramServiceSearchRequest,
        limit: Int,
        warning: String?,
        warningCode: String?,
        immediate: Bool = false
    ) async throws -> EngramServiceSearchResponse {
        let tokens = CJKText.searchableTerms(query)
        guard !tokens.isEmpty else {
            return EngramServiceSearchResponse(
                items: [],
                searchModes: ["keyword"],
                warning: warning,
                warningCode: warningCode
            )
        }
        let search: @Sendable (GRDB.Database) throws -> EngramServiceSearchResponse = { db in
            let termMatches = CJKText.ftsMatchTerms(tokens)
            // Search at session granularity: every query token must exist
            // somewhere in the session, not necessarily in the same FTS row.
            // Short Latin and CJK tokens use LIKE because FTS5 trigram MATCH
            // cannot represent them; longer Latin tokens keep MATCH ranking.
            var ctes: [String] = []
            var joins: [String] = []
            var args: [DatabaseValueConvertible] = []
            for (index, token) in tokens.enumerated() {
                let alias = "m\(index)"
                if CJKText.containsCJK(token) || token.count < 3 {
                    ctes.append("""
                        \(alias)_hits AS (
                            SELECT rowid, session_id, content,
                                   ROW_NUMBER() OVER (
                                       PARTITION BY session_id
                                       ORDER BY instr(lower(content), lower(?)), rowid
                                   ) AS match_position
                            FROM sessions_fts
                            WHERE content LIKE ? ESCAPE '\\'
                        ),
                        \(alias) AS (
                            SELECT session_id, rowid AS matched_rowid, 0.0 AS rank,
                                   substr(content, MAX(1, instr(lower(content), lower(?)) - 200), ?) AS snippet
                            FROM \(alias)_hits
                            WHERE match_position = 1
                        )
                    """)
                    args.append(token)
                    args.append("%\(CJKText.escapeLikePattern(token))%")
                    args.append(token)
                    args.append(Self.maxSnippetLength)
                } else {
                    ctes.append("""
                        \(alias)_hits AS (
                            SELECT rowid, session_id, rank
                            FROM sessions_fts
                            WHERE sessions_fts MATCH ?
                        ),
                        \(alias) AS (
                            SELECT hits.session_id, MIN(hits.rank) AS rank,
                                   (
                                       SELECT rowid
                                       FROM sessions_fts
                                       WHERE sessions_fts MATCH ?
                                         AND sessions_fts.session_id = hits.session_id
                                       ORDER BY rank, rowid
                                       LIMIT 1
                                   ) AS matched_rowid,
                                   (
                                       SELECT snippet(sessions_fts, 1, '<mark>', '</mark>', '…', 64)
                                       FROM sessions_fts
                                       WHERE sessions_fts MATCH ?
                                         AND sessions_fts.session_id = hits.session_id
                                       ORDER BY rank, rowid
                                       LIMIT 1
                                   ) AS snippet
                            FROM \(alias)_hits hits
                            GROUP BY hits.session_id
                        )
                    """)
                    args.append(termMatches[index])
                    args.append(termMatches[index])
                    args.append(termMatches[index])
                }
                if index > 0 {
                    joins.append("JOIN \(alias) ON \(alias).session_id = m0.session_id")
                }
            }
            let snippetExpression = tokens.indices.dropFirst().reduce(
                "COALESCE(m0.snippet, '')"
            ) { expression, index in
                let priorRowIDs = tokens.indices.prefix(index)
                    .map { "m\($0).matched_rowid" }
                    .joined(separator: ", ")
                return """
                    \(expression) || CASE
                      WHEN NULLIF(m\(index).snippet, '') IS NULL THEN ''
                      WHEN m\(index).matched_rowid IN (\(priorRowIDs)) THEN ''
                      ELSE '\n…\n' || m\(index).snippet
                    END
                    """
            }
            var parts = ["""
                WITH \(ctes.joined(separator: ", "))
                SELECT s.*, \(snippetExpression) AS snippet
                FROM m0
                \(joins.joined(separator: " "))
                JOIN sessions s ON s.id = m0.session_id
                WHERE s.hidden_at IS NULL
                  -- docs/invariants.md #3: keyword search excludes skip and lite tiers.
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
                items: rows.map { Self.item(from: $0, query: query) },
                searchModes: ["keyword"],
                warning: warning,
                warningCode: warningCode
            )
        }
        return immediate
            ? try await readImmediate(search)
            : try await read(search)
    }

    private struct SemanticChunkCandidate: Sendable {
        let rowID: Int64
        let chunkId: String
        let sessionId: String
        let text: String
        let vector: [Float]
        let session: EngramServiceSearchResponse.Item
    }

    /// Raw SQL page cursor is independent of successful vector decode.
    private struct SemanticChunkPage: Sendable {
        let candidates: [SemanticChunkCandidate]
        /// Last `sc.rowid` in the raw SQL page; `nil` only when the page is empty.
        let lastRawRowID: Int64?
    }

    private struct SemanticTopKResult: Sendable {
        let hits: [SessionSemanticSearchPolicy.ScoredChunk]
        let fallbackByChunkId: [String: EngramServiceSearchResponse.Item]
    }

    private enum SemanticSearchOutcome {
        case results(EngramServiceSearchResponse)
        case degraded(
            SessionVectorSearchAvailability.SemanticDegradeReason,
            detail: String?
        )
    }

    private func semanticSearch(
        query: String,
        request: EngramServiceSearchRequest,
        limit: Int,
        requestedMode: String
    ) async throws -> SemanticSearchOutcome {
        // Corpus gate first — distinguish missing vectors from missing provider.
        let snapshot = try await readImmediate { db in
            let snapshot = try SessionVectorSearchAvailability.probe(db: db)
            guard snapshot.isUsable,
                  let model = snapshot.model,
                  let dimension = snapshot.dimension else {
                return snapshot
            }
            // docs/invariants.md #3: hidden sessions cannot advertise a semantic corpus.
            let hasVisibleChunk = try Int.fetchOne(
                db,
                sql: """
                    SELECT 1
                    FROM semantic_chunks sc
                    JOIN sessions s ON s.id = sc.session_id
                    WHERE sc.embedding IS NOT NULL
                      AND sc.model = ?
                      AND sc.dim = ?
                      AND s.hidden_at IS NULL
                      AND \(SessionSemanticSearchPolicy.searchableTierSQL)
                    LIMIT 1
                    """,
                arguments: [model, dimension]
            ) != nil
            return hasVisibleChunk
                ? snapshot
                : SessionVectorSearchAvailability.Snapshot(
                    isUsable: false,
                    model: model,
                    dimension: dimension
                )
        }
        guard snapshot.isUsable else {
            return .degraded(.corpusMissing, detail: nil)
        }

        guard let config = EmbeddingSettings.load(environment: embeddingEnvironment) else {
            return .degraded(.providerUnavailable, detail: nil)
        }

        // H07: require exact model+dimension match BEFORE generating a query embedding.
        switch SessionVectorSearchAvailability.queryCompatibility(
            configuredModel: config.model,
            configuredDimension: config.dimension,
            dimensionsWereSent: EmbeddingRequestPolicy.dimensionsWereSentForCompatibility(
                config,
                storedDimension: snapshot.dimension ?? config.dimension
            ),
            snapshot: snapshot
        ) {
        case .compatible(let model, let dimension):
            let provider = embeddingProviderFactory(config)
            let vectors: [[Float]]
            do {
                vectors = try await provider.embed([query])
            } catch EmbeddingError.circuitOpen {
                return .degraded(.breakerOpen, detail: nil)
            } catch EmbeddingError.notConfigured {
                return .degraded(.providerUnavailable, detail: nil)
            } catch {
                return .degraded(.embedFailed, detail: error.localizedDescription)
            }
            guard let queryVector = vectors.first, !queryVector.isEmpty else {
                return .degraded(.embedFailed, detail: "empty query embedding")
            }
            if queryVector.count != dimension {
                return .degraded(
                    .modelMismatch,
                    detail: "query embedding dim \(queryVector.count) vs stored \(dimension)"
                )
            }

            // M09: full eligible corpus in cancellable bounded batches + constant-memory top-K.
            let topK = SessionSemanticSearchPolicy.knnTopK(limit: limit)
            let topKResult = try await semanticChunkTopK(
                for: request,
                queryVector: queryVector,
                model: model,
                dim: dimension,
                topK: topK
            )
            guard !topKResult.hits.isEmpty else {
                if requestedMode == "hybrid" || requestedMode == "both" {
                    let keyword = try await keywordSearch(
                        query: query,
                        request: request,
                        limit: limit,
                        warning: nil,
                        warningCode: nil,
                        immediate: true
                    )
                    return .results(EngramServiceSearchResponse(
                        items: keyword.items,
                        searchModes: ["keyword", "semantic"],
                        warning: nil,
                        warningCode: nil
                    ))
                }
                return .results(EngramServiceSearchResponse(
                    items: [],
                    searchModes: ["semantic"],
                    warning: nil,
                    warningCode: nil
                ))
            }

            var sessionIds: [String] = []
            var snippetBySession: [String: String] = [:]
            var scoreBySession: [String: Double] = [:]
            var fallbackSessionById: [String: EngramServiceSearchResponse.Item] = [:]
            for hit in topKResult.hits {
                guard !sessionIds.contains(hit.sessionId) else { continue }
                sessionIds.append(hit.sessionId)
                snippetBySession[hit.sessionId] = hit.text
                scoreBySession[hit.sessionId] = Double(hit.score)
                fallbackSessionById[hit.sessionId] = topKResult.fallbackByChunkId[hit.id]
                if sessionIds.count >= limit { break }
            }
            guard !sessionIds.isEmpty else {
                return .results(EngramServiceSearchResponse(
                    items: [],
                    searchModes: requestedMode == "semantic"
                        ? ["semantic"]
                        : ["keyword", "semantic"],
                    warning: nil,
                    warningCode: nil
                ))
            }

            let semanticItems = try await searchItems(
                sessionIds: sessionIds,
                query: nil,
                snippetBySession: snippetBySession,
                matchType: "semantic",
                scoreBySession: scoreBySession,
                fallbackSessionById: fallbackSessionById
            )

            if requestedMode == "hybrid" || requestedMode == "both" {
                let keyword: EngramServiceSearchResponse
                do {
                    keyword = try await keywordSearch(
                        query: query,
                        request: request,
                        limit: limit,
                        warning: nil,
                        warningCode: nil,
                        immediate: true
                    )
                } catch let error as DatabaseError where Self.isSQLiteBusyOrLocked(error) {
                    ServiceLogger.warn(
                        "hybrid keyword fusion was skipped because the database is busy",
                        category: .reader
                    )
                    return .results(EngramServiceSearchResponse(
                        items: semanticItems,
                        searchModes: ["semantic"],
                        warning: "Keyword fusion was skipped because the database is busy.",
                        warningCode: nil
                    ))
                }
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
                return .results(EngramServiceSearchResponse(
                    items: fusedItems,
                    searchModes: ["keyword", "semantic"],
                    warning: nil,
                    warningCode: nil
                ))
            }

            return .results(EngramServiceSearchResponse(
                items: semanticItems,
                searchModes: ["semantic"],
                warning: nil,
                warningCode: nil
            ))

        case .corpusUnavailable:
            return .degraded(.corpusMissing, detail: nil)
        case let .modelMismatch(cfgModel, cfgDim, storedModel, storedDim):
            // No cosine ranking and no query embedding on model mismatch.
            return .degraded(
                .modelMismatch,
                detail: "configured \(cfgModel)@\(cfgDim) vs stored \(storedModel)@\(storedDim)"
            )
        }
    }

    /// Stream every eligible semantic chunk in GRDB batches; keep only top-K
    /// scored hits in memory. Checks cancellation between batches.
    ///
    /// Cursor advances from the **raw** SQL page's last rowid, not from
    /// successfully decoded candidates — a full page of malformed BLOBs must
    /// not terminate the scan (M09).
    private func semanticChunkTopK(
        for request: EngramServiceSearchRequest,
        queryVector: [Float],
        model: String,
        dim: Int,
        topK: Int
    ) async throws -> SemanticTopKResult {
        var top: [SessionSemanticSearchPolicy.ScoredChunk] = []
        var fallbackByChunkId: [String: EngramServiceSearchResponse.Item] = [:]
        var afterRowID: Int64 = 0
        let batchSize = SessionSemanticSearchPolicy.candidateBatchSize(requestLimit: request.limit)

        while true {
            try Task.checkCancellation()
            let page = try await fetchSemanticChunkPage(
                for: request,
                model: model,
                dim: dim,
                afterRowID: afterRowID,
                batchSize: batchSize
            )
            guard let lastRaw = page.lastRawRowID else { break }
            afterRowID = lastRaw
            for candidate in page.candidates {
                let score = VectorMath.cosine(queryVector, candidate.vector)
                let scored = SessionSemanticSearchPolicy.ScoredChunk(
                    id: candidate.chunkId,
                    score: score,
                    sessionId: candidate.sessionId,
                    text: candidate.text
                )
                SessionSemanticSearchPolicy.accumulateTopK(
                    &top,
                    incoming: scored,
                    topK: topK
                )
                fallbackByChunkId[candidate.chunkId] = Self.semanticItem(
                    from: candidate.session,
                    snippet: candidate.text,
                    score: Double(score)
                )
                let retained = Set(top.map(\.id))
                fallbackByChunkId = fallbackByChunkId.filter { retained.contains($0.key) }
            }
        }
        return SemanticTopKResult(hits: top, fallbackByChunkId: fallbackByChunkId)
    }

    private func fetchSemanticChunkPage(
        for request: EngramServiceSearchRequest,
        model: String,
        dim: Int,
        afterRowID: Int64,
        batchSize: Int
    ) async throws -> SemanticChunkPage {
        try await readImmediate { db in
            guard try tableExists("semantic_chunks", db: db) else {
                return SemanticChunkPage(candidates: [], lastRawRowID: nil)
            }
            var parts = ["""
                SELECT sc.rowid AS row_id,
                       sc.id AS chunk_id,
                       sc.session_id AS session_id,
                       sc.text AS text,
                       sc.embedding AS embedding,
                       s.*
                FROM semantic_chunks sc
                JOIN sessions s ON s.id = sc.session_id
                WHERE sc.embedding IS NOT NULL
                  AND sc.model = ?
                  AND sc.dim = ?
                  AND sc.rowid > ?
                  AND s.hidden_at IS NULL
                  AND \(SessionSemanticSearchPolicy.searchableTierSQL)
            """]
            var args: [DatabaseValueConvertible] = [model, dim, afterRowID]
            appendSearchFilters(for: request, to: &parts, args: &args)
            // Stable full-corpus order by rowid (not recency). Pagination via rowid cursor.
            parts.append("ORDER BY sc.rowid ASC LIMIT ?")
            args.append(batchSize)
            let rows = try Row.fetchAll(
                db,
                sql: parts.joined(separator: " "),
                arguments: StatementArguments(args)
            )
            guard let lastRow = rows.last else {
                return SemanticChunkPage(candidates: [], lastRawRowID: nil)
            }
            let lastRawRowID: Int64
            if let value = lastRow["row_id"] as Int64? {
                lastRawRowID = value
            } else if let value = lastRow["row_id"] as Int? {
                lastRawRowID = Int64(value)
            } else {
                // Malformed rowid on last row — still must not loop forever; stop.
                return SemanticChunkPage(candidates: [], lastRawRowID: nil)
            }
            let candidates: [SemanticChunkCandidate] = rows.compactMap { row in
                let rowID: Int64
                if let value = row["row_id"] as Int64? {
                    rowID = value
                } else if let value = row["row_id"] as Int? {
                    rowID = Int64(value)
                } else {
                    return nil
                }
                guard let chunkId = row["chunk_id"] as String?,
                      let sessionId = row["session_id"] as String?,
                      let text = row["text"] as String?,
                      let data = row["embedding"] as Data? else {
                    return nil
                }
                guard let vector = VectorMath.decode(data, expectedCount: dim) else { return nil }
                return SemanticChunkCandidate(
                    rowID: rowID,
                    chunkId: chunkId,
                    sessionId: sessionId,
                    text: text,
                    vector: vector,
                    session: Self.item(from: row)
                )
            }
            return SemanticChunkPage(candidates: candidates, lastRawRowID: lastRawRowID)
        }
    }

    private func searchItems(
        sessionIds: [String],
        query: String?,
        snippetBySession: [String: String],
        matchType: String,
        scoreBySession: [String: Double],
        fallbackSessionById: [String: EngramServiceSearchResponse.Item]
    ) async throws -> [EngramServiceSearchResponse.Item] {
        guard !sessionIds.isEmpty else { return [] }
        let hydrate: @Sendable (GRDB.Database) throws -> [EngramServiceSearchResponse.Item] = { db in
            let placeholders = Array(repeating: "?", count: sessionIds.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.*
                    FROM sessions s
                    WHERE s.id IN (\(placeholders))
                      AND s.hidden_at IS NULL
                      AND \(SessionSemanticSearchPolicy.searchableTierSQL)
                    """,
                arguments: StatementArguments(sessionIds)
            )
            let rowsById = Dictionary(uniqueKeysWithValues: rows.map { (($0["id"] as String), $0) })
            return sessionIds.compactMap { id in
                guard let row = rowsById[id] else { return nil }
                return Self.item(
                    from: row,
                    query: query,
                    snippetOverride: snippetBySession[id],
                    matchType: matchType,
                    score: scoreBySession[id]
                )
            }
        }
        do {
            return try await readImmediate(hydrate)
        } catch let error as DatabaseError where Self.isSQLiteBusyOrLocked(error) {
            return sessionIds.compactMap { fallbackSessionById[$0] }
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
            let indexEligibleCounts = try sourceIndexEligibleCounts(db)
            let failedIndexJobCounts = try sourceFailedIndexJobCounts(db)
            let tokenCounts = try sourceTokenCounts(db)
            let costedCounts = try sourceCostedCounts(db)
            let latestUsage = try sourceLatestUsage(db)
            return rows.map { row in
                let source: String = row["source"]
                let sessionCount: Int = row["session_count"]
                let searchable = searchableCounts[source] ?? 0
                // 0 is load-bearing: all-skip sources have no GROUP BY row.
                let indexEligible = indexEligibleCounts[source] ?? 0
                let failed = failedIndexJobCounts[source] ?? 0
                let tokenized = tokenCounts[source] ?? 0
                let coverage = indexEligible > 0
                    ? min(100, max(0, Int((Double(searchable) / Double(indexEligible) * 100).rounded())))
                    : 0
                // Denominator matches searchCoverage: list-visible/index-eligible
                // sessions only. Skip noise must not dilute token KPI percent while
                // raw sessionCount remains diagnostic (includes skip).
                let tokenCoverage = indexEligible > 0
                    ? min(100, max(0, Int((Double(tokenized) / Double(indexEligible) * 100).rounded())))
                    : 0
                let usage = latestUsage[source]
                let health = sourceHealth(
                    sessionCount: sessionCount,
                    indexEligibleCount: indexEligible,
                    searchableSessionCount: searchable,
                    failedIndexJobCount: failed,
                    latestUsageStatus: usage?.status
                )
                return EngramServiceSourceInfo(
                    name: source,
                    sessionCount: sessionCount,
                    latestIndexed: row["latest_indexed"] as String?,
                    listVisibleSessionCount: indexEligible,
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
                    healthStatus: health.status,
                    healthReason: health.reason,
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
                WHERE superseded_by IS NULL
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
                WHERE id = ? AND superseded_by IS NULL
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

            let activityTime = SearchFilterPredicates.activityTimeSQL(alias: "s")

            let perSourceRows = try Row.fetchAll(db, sql: """
                SELECT s.source AS key,
                       SUM(c.cost_usd) AS cost_usd,
                       COUNT(*) AS session_count
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
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
                SELECT date(\(activityTime), 'localtime') AS day,
                       SUM(c.cost_usd) AS cost_usd
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
                  AND date(\(activityTime), 'localtime') >= date('now', 'localtime', '-30 days')
                GROUP BY date(\(activityTime), 'localtime')
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
                WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
                  AND date(\(activityTime), 'localtime') >= date('now', 'localtime', 'start of month')
            """) ?? 0

            let todayUsd = try Double.fetchOne(db, sql: """
                SELECT SUM(c.cost_usd)
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
                  AND date(\(activityTime), 'localtime') = date('now', 'localtime')
            """) ?? 0

            // Row 4: unpriced disclosure split by cause (attribution vs table-gap).
            // Tokens > 0 so legitimately zero-usage $0 sessions are not flagged.
            // Sibling query inside the same read closure (GRDB queue is non-reentrant).
            let unpricedRow = try Row.fetchOne(db, sql: """
                SELECT
                  SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                           AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                           AND (c.model IS NULL OR c.model = '')
                      THEN 1 ELSE 0 END) AS unpriced_unattributed_sessions,
                  SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                           AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                           AND c.model IS NOT NULL AND c.model <> ''
                      THEN 1 ELSE 0 END) AS unpriced_no_price_sessions,
                  SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                           AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                           AND (c.model IS NULL OR c.model = '')
                      THEN (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens)
                      ELSE 0 END) AS unpriced_unattributed_tokens,
                  SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                           AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                           AND c.model IS NOT NULL AND c.model <> ''
                      THEN (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens)
                      ELSE 0 END) AS unpriced_no_price_tokens
                FROM session_costs c
                JOIN sessions s ON c.session_id = s.id
                WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
            """)

            return EngramServiceCostsResponse(
                totalUsd: Self.roundCents(totalUsd),
                perSource: perSource,
                perDay: perDay,
                monthToDateUsd: Self.roundCents(monthToDateUsd),
                todayUsd: Self.roundCents(todayUsd),
                unpricedUnattributedSessions: (unpricedRow?["unpriced_unattributed_sessions"] as Int?) ?? 0,
                unpricedNoPriceSessions: (unpricedRow?["unpriced_no_price_sessions"] as Int?) ?? 0,
                unpricedUnattributedTokens: (unpricedRow?["unpriced_unattributed_tokens"] as Int?) ?? 0,
                unpricedNoPriceTokens: (unpricedRow?["unpriced_no_price_tokens"] as Int?) ?? 0
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
            db -> (source: String?, locator: String, summary: String?) in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.source AS source,
                           s.summary AS summary,
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
            return (
                row?["source"] as String?,
                (row?["locator"] as String?) ?? "",
                row?["summary"] as String?
            )
        }
        let isRemoteSnapshot = scalar.locator
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("remote://")

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
        if let source = scalar.source, !isRemoteSnapshot {
            do {
                let streamed = try await Self.streamReplayMessages(
                    source: source,
                    locator: scalar.locator,
                    limit: limit + 1,
                    adapters: sessionAdapterProvider()
                )
                if !streamed.messages.isEmpty {
                    let entries = Self.replayEntries(from: streamed.messages, limit: limit)
                    return EngramServiceReplayTimelineResponse(
                        sessionId: request.sessionId,
                        source: source,
                        entries: entries,
                        // A stream sentinel or parser failure proves the returned
                        // prefix is incomplete without discarding it for FTS.
                        totalEntries: streamed.messages.count,
                        hasMore: streamed.messages.count > limit || streamed.incomplete,
                        offset: 0,
                        limit: limit
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // No usable prefix: preserve the existing FTS fallback below.
            }
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

        var snapshotPrefix: [ReplayFTSRow] = []
        if isRemoteSnapshot {
            snapshotPrefix.append(
                ReplayFTSRow(rowid: -2, content: "Assistant: HQ 索引快照，不是源文件")
            )
            if let summary = scalar.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                snapshotPrefix.append(
                    ReplayFTSRow(
                        rowid: -1,
                        content: "Assistant: \(TranscriptRedactionPolicy.redact(summary))"
                    )
                )
            }
        }
        let totalEntries = fallback.total + snapshotPrefix.count
        let entries = Self.replayEntries(
            from: snapshotPrefix + fallback.rows,
            source: scalar.source,
            limit: limit
        )
        return EngramServiceReplayTimelineResponse(
            sessionId: request.sessionId,
            source: scalar.source,
            entries: entries,
            totalEntries: totalEntries,
            hasMore: totalEntries > entries.count,
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
        limit: Int,
        adapters: [any SessionAdapter]
    ) async throws -> ReplayStreamResult {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("sync://") else {
            return ReplayStreamResult(messages: [], incomplete: false)
        }
        let sourceName: SourceName? = source == "antigravity-legacy"
            ? .antigravity
            : SourceName(rawValue: source)
        guard let sourceName,
              let adapter = adapters.first(where: { $0.source == sourceName })
        else {
            return ReplayStreamResult(messages: [], incomplete: false)
        }
        let result = try await adapter.streamMessagesWithMetadata(
            locator: trimmed,
            options: StreamMessagesOptions(limit: limit)
        )
        var messages: [ReplayMessage] = []
        for try await message in result.messages {
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
        return ReplayStreamResult(
            messages: messages,
            incomplete: result.parseFailure != nil || result.truncated
        )
    }

    func resumeCommand(_ request: EngramServiceResumeCommandRequest) async throws -> EngramServiceResumeCommandResponse {
        // Extract Sendable scalars inside the read block — a GRDB Row is not
        // Sendable and cannot cross the blocking-read queue hop.
        let session = try await read {
            db -> (id: String, source: String, cwd: String, filePath: String, storedFilePath: String, parentSessionId: String?, agentRole: String?, excerptLines: [String], metadataLines: [String])? in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                      s.id, s.source, s.cwd, s.file_path,
                      COALESCE(
                        NULLIF(ls.local_readable_path, ''),
                        NULLIF(s.file_path, ''),
                        s.source_locator,
                        ''
                      ) AS readable_path,
                      s.project, s.model, s.message_count,
                      s.user_message_count, s.assistant_message_count, s.tool_message_count,
                      s.generated_title, s.summary, s.parent_session_id, s.agent_role
                    FROM sessions s
                    LEFT JOIN session_local_state ls ON ls.session_id = s.id
                    WHERE s.id = ?
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
                filePath: (row["readable_path"] as String?) ?? "",
                storedFilePath: (row["file_path"] as String?) ?? "",
                parentSessionId: row["parent_session_id"] as String?,
                agentRole: row["agent_role"] as String?,
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

        if session.id.hasPrefix("remote:")
            || session.storedFilePath.hasPrefix("remote://")
            || session.filePath.hasPrefix("remote://") {
            return EngramServiceResumeCommandResponse(
                error: "This session lives on HQ and cannot be resumed from this Mac.",
                hint: "Open the HQ index snapshot in Engram instead."
            )
        }

        let sessionId: String = session.id
        let source: String = session.source
        let cwd: String = session.cwd
        var contextLines = session.excerptLines
        if contextLines.isEmpty {
            let transcriptContext = try await Self.resumeTranscriptContextLines(
                filePath: session.filePath,
                source: source,
                reader: transcriptPrimerReader
            )
            contextLines = transcriptContext.lines
            if transcriptContext.readFailed {
                contextLines = session.metadataLines
                contextLines.append("Transcript could not be read; this resume context is incomplete.")
            }
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
        let claudeSubagentLayout = source == "claude-code"
            ? fileSystemProvider.claudeSubagentLayout(locator: session.filePath)
            : nil
        if source == "claude-code",
           claudeSubagentLayout != nil
            || !Self.claudeResumeFileMatchesID(filePath: session.filePath, id: sessionId) {
            let hint = claudeSubagentLayout.map {
                let parentID = $0.parentSessionId
                return "It is a subagent of \(parentID). Resume that session instead."
            } ?? "Its transcript is not stored where claude --resume looks."
            return EngramServiceResumeCommandResponse(
                contextPrimer: contextPrimer,
                error: "This transcript cannot be resumed directly",
                hint: hint
            )
        }
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
                      AND \(SessionVisibilityFilter.listVisibleSQL)
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

    private struct ReplayStreamResult: Sendable {
        let messages: [ReplayMessage]
        let incomplete: Bool
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

    private func readImmediate<T: Sendable>(
        _ block: @escaping @Sendable (GRDB.Database) throws -> T
    ) async throws -> T {
        let databaseReader = self.databaseReader
        return try await withCheckedThrowingContinuation { continuation in
            Self.blockingReadQueue.async {
                do {
                    continuation.resume(returning: try databaseReader.readImmediate(block))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func isSQLiteBusyOrLocked(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED
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

    /// Per-source count of non-hidden, non-`skip` sessions (index-eligible).
    private func sourceIndexEligibleCounts(_ db: GRDB.Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT source AS source, COUNT(*) AS count
            FROM sessions
            WHERE \(SessionVisibilityFilter.listVisibleSQL)
            GROUP BY source
        """)
        return sourceCountDictionary(rows)
    }

    private func sourceSearchableCounts(_ db: GRDB.Database) throws -> [String: Int] {
        guard try tableExists("sessions_fts", db: db) else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.source AS source, COUNT(DISTINCT f.session_id) AS count
            FROM sessions_fts f
            JOIN sessions s ON s.id = f.session_id
            WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
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
            WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
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
            WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
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
            WHERE \(SessionVisibilityFilter.listVisibleSQL(alias: "s"))
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

    private func sourceHealth(
        sessionCount: Int,
        indexEligibleCount: Int,
        searchableSessionCount: Int,
        failedIndexJobCount: Int,
        latestUsageStatus: String?
    ) -> (status: String, reason: String?) {
        if sessionCount == 0 {
            return ("empty", "No sessions indexed for this source yet.")
        }
        if latestUsageStatus == "critical" {
            return ("critical", "Provider usage for this source is at a critical level.")
        }
        if failedIndexJobCount > 0 {
            let jobs = failedIndexJobCount == 1 ? "job" : "jobs"
            return (
                "attention",
                "\(failedIndexJobCount) index \(jobs) failed for this source. They retry on the next indexing pass."
            )
        }
        if latestUsageStatus == "attention" {
            return ("attention", "Provider usage for this source needs attention.")
        }
        if indexEligibleCount == 0 {
            return (
                "empty",
                "All \(sessionCount) sessions are subagent or noise sessions. They are searched through their parent session, not on their own."
            )
        }
        if searchableSessionCount < indexEligibleCount {
            let missing = indexEligibleCount - searchableSessionCount
            return (
                "partial",
                "\(missing) of \(indexEligibleCount) indexable sessions are missing search-index rows."
            )
        }
        return ("healthy", nil)
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
        let clauses = SearchFilterPredicates.clauses(
            sources: request.source.map { [$0] } ?? [],
            projects: request.project.map { [$0] } ?? [],
            origin: request.origin,
            since: request.since
        )
        for clause in clauses {
            parts.append("AND \(clause.sql)")
            for binding in clause.bindings {
                args.append(binding)
            }
        }
    }

    /// Upper bound on the search snippet length returned over IPC. `f.content`
    /// in `sessions_fts` holds the full session text, which can be megabytes;
    /// returning it verbatim per result can blow the transport frame cap and
    /// waste bandwidth. Bound it server-side to a preview-sized window.
    static let maxSnippetLength = 600

    private static func item(
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
           let windowed = CJKText.highlightedSnippet(content: content, query: query) {
            snippetText = windowed
        } else {
            snippetText = rawSnippet.map(CJKText.removingHighlightMarks(from:))
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
            qualityScore: row["quality_score"] as Int?,
            origin: row["origin"] as String?
        )
    }

    private static func semanticItem(
        from item: EngramServiceSearchResponse.Item,
        snippet: String,
        score: Double
    ) -> EngramServiceSearchResponse.Item {
        EngramServiceSearchResponse.Item(
            id: item.id,
            title: item.title,
            snippet: truncateSnippet(snippet),
            matchType: "semantic",
            score: score,
            source: item.source,
            startTime: item.startTime,
            endTime: item.endTime,
            cwd: item.cwd,
            project: item.project,
            model: item.model,
            messageCount: item.messageCount,
            userMessageCount: item.userMessageCount,
            assistantMessageCount: item.assistantMessageCount,
            systemMessageCount: item.systemMessageCount,
            summary: item.summary,
            filePath: item.filePath,
            sourceLocator: item.sourceLocator,
            sizeBytes: item.sizeBytes,
            indexedAt: item.indexedAt,
            agentRole: item.agentRole,
            customName: item.customName,
            tier: item.tier,
            toolMessageCount: item.toolMessageCount,
            generatedTitle: item.generatedTitle,
            parentSessionId: item.parentSessionId,
            suggestedParentId: item.suggestedParentId,
            linkSource: item.linkSource,
            qualityScore: item.qualityScore,
            origin: item.origin
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

    static func claudeResumeFileMatchesID(filePath: String, id: String) -> Bool {
        guard !id.isEmpty else { return false }
        let components = URL(fileURLWithPath: filePath).pathComponents
        return components.last == "\(id).jsonl"
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

    private struct ResumeTranscriptContext: Sendable {
        let lines: [String]
        let readFailed: Bool
    }

    private static func resumeTranscriptContextLines(
        filePath: String,
        source: String,
        reader: @Sendable (String, String, Int) async throws -> ServiceTranscriptReader.ReadResult
    ) async throws -> ResumeTranscriptContext {
        let trimmedPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return ResumeTranscriptContext(lines: [], readFailed: false) }
        // Windowed read: only the first + last-5 visible messages are needed for
        // the primer, so stream them through a bounded buffer instead of parsing
        // the entire transcript into a full message array.
        let result: ServiceTranscriptReader.ReadResult
        do {
            result = try await reader(trimmedPath, source, 6)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ResumeTranscriptContext(lines: [], readFailed: true)
        }
        var lines: [String] = result.messages.compactMap { (message: ServiceTranscriptMessage) -> String? in
            let redacted = TranscriptExportService.redactSensitiveContent(message.content)
            guard let content = sanitizedResumeContextExcerpt(redacted) else { return nil }
            let role = message.role == "user" ? "User" : "Assistant"
            return "\(role): \(content)"
        }
        if result.truncated, let truncatedAt = result.truncatedAt {
            lines.append("Transcript truncated at \(decimalString(truncatedAt)) messages; later content is not included.")
        } else if !result.totalKnownComplete {
            lines.append("Transcript parsing stopped after this prefix; later content may be missing.")
        }
        return ResumeTranscriptContext(lines: lines, readFailed: false)
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

    /// Well-known absolute install locations preferred over PATH (SEC-L5).
    /// A poisoned early PATH entry must not shadow Homebrew/system CLIs used for resume.
    static let preferredCLIDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/opt/homebrew/sbin",
        "/usr/local/sbin",
    ]

    /// Locate a resume CLI binary. Prefers fixed absolute install paths, then PATH.
    nonisolated static func defaultCommandLocator(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var seen = Set<String>()
        let pathDirs = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        // SEC-L5: check curated absolute directories first so PATH poisoning cannot
        // win over a known system/Homebrew install of claude/codex/gemini.
        let searchPaths = (preferredCLIDirectories + pathDirs)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        for directory in searchPaths {
            let path = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .path
            guard isExecutable(path) else { continue }
            return path
        }
        return nil
    }
}

private final class ServiceDatabaseReader: ServiceDatabaseReading, @unchecked Sendable {
    private let reader: EngramDatabaseReader
    private let immediateReader: DatabaseQueue

    init(path: String) throws {
        self.reader = try EngramDatabaseReader(path: path)
        self.immediateReader = try DatabaseQueue(
            path: path,
            configuration: SQLiteConnectionPolicy.immediateReaderConfiguration()
        )
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try reader.read(block)
    }

    func readImmediate<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try immediateReader.read(block)
    }
}

private extension StringProtocol {
    func prefixString(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}
