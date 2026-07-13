import Foundation

final class ClaudeCodeAdapter: SessionAdapter, TailIndexingSessionAdapter, ModificationFilteredSessionAdapter, ExactArchiveSourceAdapter, Sendable {
    let source: SourceName = .claudeCode

    private enum ProfileSource: Sendable {
        case resolver(ClaudeCodeProfileResolver)
        case fixed(ClaudeCodeProfile)
    }

    private let profileSource: ProfileSource
    private let limits: ParserLimits
    private let sourceHintCache: ClaudeCodeSourceHintCache
    private static let sourceHintScanByteLimit = 1024 * 1024
    private static let sourceHintMaxLineBytes = 512 * 1024
    private static let sourceHintLineLimit = 64
    private static let sourceHintChunkSize = 64 * 1024

    /// - Parameter sourceHintCacheDirectory: When non-nil, the derived-source
    ///   signature cache is persisted here (keyed on path + mtime + size) so a
    ///   cold process skips head-sniffing every Claude file it has seen before.
    ///   `nil` keeps the cache purely in-memory (used by tests and transient
    ///   registries so they never touch `~/.engram`).
    init(
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .path,
        limits: ParserLimits = .default,
        sourceHintCacheDirectory: URL? = nil
    ) {
        let canonicalRoot = URL(fileURLWithPath: projectsRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        self.profileSource = .fixed(
            ClaudeCodeProfile(
                id: "default-fixed",
                displayName: "Default",
                projectsRoot: canonicalRoot.path,
                origin: .default,
                available: JSONLAdapterSupport.isDirectory(canonicalRoot),
                sourceReclamationAllowed: true
            )
        )
        self.limits = limits
        self.sourceHintCache = ClaudeCodeSourceHintCache(directory: sourceHintCacheDirectory)
    }

    init(
        profileResolver: ClaudeCodeProfileResolver,
        limits: ParserLimits = .default,
        sourceHintCacheDirectory: URL? = nil
    ) {
        self.profileSource = .resolver(profileResolver)
        self.limits = limits
        self.sourceHintCache = ClaudeCodeSourceHintCache(directory: sourceHintCacheDirectory)
    }

    func detect() async -> Bool {
        resolvedProfiles().contains { profile in
            JSONLAdapterSupport.isDirectory(URL(fileURLWithPath: profile.projectsRoot, isDirectory: true))
        }
    }

    func listSessionLocators() async throws -> [String] {
        try await listSessionLocators(profiles: resolvedProfiles())
    }

    private func listSessionLocators(profiles: [ClaudeCodeProfile]) async throws -> [String] {
        try Task.checkCancellation()
        var locators = Set<String>()
        for profile in profiles {
            try Task.checkCancellation()
            let projectsRoot = URL(fileURLWithPath: profile.projectsRoot, isDirectory: true)
            for locator in try await listSessionLocators(projectsRoot: projectsRoot) {
                let canonicalLocator = Self.canonicalURL(path: locator).path
                guard Self.isDescendant(canonicalLocator, of: profile.projectsRoot) else { continue }
                locators.insert(canonicalLocator)
            }
        }
        try Task.checkCancellation()
        return locators.sorted()
    }

    private func listSessionLocators(projectsRoot: URL) async throws -> [String] {
        var locators: [String] = []
        for projectURL in JSONLAdapterSupport.directChildren(of: projectsRoot, includingHidden: true)
            where JSONLAdapterSupport.isDirectory(projectURL)
        {
            try Task.checkCancellation()
            for entryURL in JSONLAdapterSupport.directChildren(of: projectURL) {
                try Task.checkCancellation()
                if entryURL.pathExtension == "jsonl" {
                    locators.append(entryURL.path)
                    continue
                }

                let subagentsURL = entryURL.appendingPathComponent("subagents")
                guard JSONLAdapterSupport.isDirectory(subagentsURL) else { continue }
                for subagentURL in JSONLAdapterSupport.directChildren(of: subagentsURL)
                    where subagentURL.pathExtension == "jsonl"
                {
                    try Task.checkCancellation()
                    locators.append(subagentURL.path)
                }
            }
        }
        return locators
    }

    func profile(for locator: String) -> ClaudeCodeProfile? {
        Self.profile(for: locator, profiles: resolvedProfiles())
    }

    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        guard ArchiveSourceDescriptor.normalizedAbsolutePath(locator) != nil else {
            throw ArchiveSourceDescriptorError.invalidLocator(locator)
        }
        let sourceURL = Self.canonicalURL(path: locator)
        let profiles = resolvedProfiles()
        guard let profile = Self.profile(for: sourceURL.path, profiles: profiles) else {
            throw ArchiveSourceDescriptorError.pathOutsideRoot(
                path: sourceURL.path,
                root: profiles.map(\.projectsRoot).joined(separator: ":")
            )
        }
        let replayRoot = URL(fileURLWithPath: profile.projectsRoot, isDirectory: true)
        let relativePath = try ArchiveSourceDescriptor.relativePath(
            path: sourceURL,
            under: replayRoot
        )
        return try ArchiveSourceDescriptor.singleFile(
            locator: sourceURL.path,
            sourceURL: sourceURL,
            replayRelativePath: relativePath
        )
    }

    func listSessionLocators(modifiedSince: Date, fileManager: FileManager) async throws -> [String] {
        try await listSessionLocators().filter {
            guard let modifiedAt = try? Self.modifiedAt(locator: $0, fileManager: fileManager) else { return false }
            return modifiedAt >= modifiedSince
        }
    }

    func listDerivedSessionLocators(
        source: SourceName,
        modifiedSince: Date? = nil,
        fileManager: FileManager = .default
    ) async throws -> [String] {
        let profiles = resolvedProfiles()
        let defaultProfiles = profiles.filter { $0.origin == .default }
        var locators: [String] = []
        for locator in try await listSessionLocators(profiles: defaultProfiles) {
            try Task.checkCancellation()
            guard Self.profile(for: locator, profiles: profiles)?.origin == .default else {
                continue
            }
            if let modifiedSince {
                guard let modifiedAt = try? Self.modifiedAt(locator: locator, fileManager: fileManager),
                      modifiedAt >= modifiedSince
                else {
                    continue
                }
            }
            let signature = Self.sourceHintSignature(locator: locator, fileManager: fileManager)
            let detected = await sourceHintCache.source(for: locator, signature: signature) {
                Self.detectSourceHint(locator: locator)
            }
            if detected == source {
                locators.append(locator)
            }
        }
        await sourceHintCache.flush()
        return locators
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        guard let profile = profile(for: locator) else {
            return .failure(.unsupportedVirtualLocator)
        }
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { return .failure(failure) }
            return Self.sessionInfo(
                from: objects,
                locator: locator,
                forceClaudeCodeSource: profile.origin != .default
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    /// Parse info and messages from a single file read. Mirrors
    /// `parseSessionInfo` + `streamMessages(options: StreamMessagesOptions())`
    /// exactly (same `sessionInfo(from:)` builder, same `message(from:)`
    /// transform) but reads the transcript once. `readObjects(reportFailures:)`
    /// surfaces the same failures the streamed path throws, so the indexer
    /// records an identical outcome on failure.
    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        guard let profile = profile(for: locator) else {
            return .failure(.unsupportedVirtualLocator)
        }
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true
            )
            if let failure { return .failure(failure) }
            switch Self.sessionInfo(
                from: objects,
                locator: locator,
                forceClaudeCodeSource: profile.origin != .default
            ) {
            case .failure(let reason):
                return .failure(reason)
            case .success(let info):
                let checkpoint = try JSONLAdapterSupport.checkpoint(locator: locator, limits: limits)
                let checkpointBoundaryHash = checkpoint.parsedOffset == info.sizeBytes
                    ? checkpoint.boundaryHash
                    : nil
                return .success(
                    IndexingScan(
                        info: info,
                        messages: objects.compactMap(Self.message(from:)),
                        checkpointParsedOffset: checkpoint.parsedOffset,
                        checkpointBoundaryHash: checkpointBoundaryHash
                    )
                )
            }
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    func scanTailForIndexing(
        locator: String,
        from parsedOffset: Int64,
        expectedBoundaryHash: String
    ) async throws -> IndexingTailScanResult {
        guard let profile = profile(for: locator) else {
            return .failure(.unsupportedVirtualLocator)
        }
        do {
            let result = try JSONLAdapterSupport.readTailObjects(
                locator: locator,
                from: parsedOffset,
                expectedBoundaryHash: expectedBoundaryHash,
                limits: limits
            )
            guard !result.boundaryHash.isEmpty else { return .fallback }
            if let failure = result.failure { return .failure(failure) }
            let messages = result.objects.compactMap(Self.message(from:))
            let aggregate = Self.aggregateSessionInfo(from: result.objects)
            return .success(
                IndexingTailScan(
                    infoDelta: IndexingTailInfoDelta(
                        id: aggregate.id(locator: locator),
                        source: profile.origin == .default
                            ? aggregate.source(locator: locator)
                            : .claudeCode,
                        endTime: aggregate.endTime.isEmpty ? nil : aggregate.endTime,
                        model: aggregate.detectedModel.isEmpty ? nil : aggregate.detectedModel,
                        messageCount: aggregate.messageCount,
                        userMessageCount: aggregate.userCount,
                        assistantMessageCount: aggregate.assistantCount,
                        toolMessageCount: aggregate.toolCount,
                        systemMessageCount: aggregate.systemCount,
                        firstVisibleRole: messages.first?.role
                    ),
                    messages: messages,
                    parsedOffset: result.parsedOffset,
                    boundaryHash: result.boundaryHash
                )
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    private static func sessionInfo(
        from objects: [JSONLAdapterSupport.JSONObject],
        locator: String,
        forceClaudeCodeSource: Bool
    ) -> AdapterParseResult<NormalizedSessionInfo> {
        let aggregate = aggregateSessionInfo(from: objects)
        guard let id = aggregate.id(locator: locator) else { return .failure(.malformedJSON) }
        guard aggregate.messageCount > 0 else { return .failure(.noVisibleMessages) }

        return .success(
            NormalizedSessionInfo(
                id: id,
                source: forceClaudeCodeSource
                    ? .claudeCode
                    : aggregate.source(locator: locator) ?? .claudeCode,
                startTime: aggregate.startTime,
                endTime: aggregate.endTime != aggregate.startTime ? aggregate.endTime : nil,
                cwd: aggregate.cwd,
                project: Self.projectName(fromCwd: aggregate.cwd),
                model: aggregate.detectedModel.isEmpty ? nil : aggregate.detectedModel,
                messageCount: aggregate.messageCount,
                userMessageCount: aggregate.userCount,
                assistantMessageCount: aggregate.assistantCount,
                toolMessageCount: aggregate.toolCount,
                systemMessageCount: aggregate.systemCount,
                summary: aggregate.firstUserText.isEmpty ? nil : String(aggregate.firstUserText.prefix(200)),
                filePath: locator,
                sizeBytes: JSONLAdapterSupport.fileSize(locator: locator),
                indexedAt: nil,
                agentRole: locator.contains("/subagents/") ? "subagent" : nil,
                originator: forceClaudeCodeSource ? "claude-code" : nil,
                origin: nil,
                summaryMessageCount: nil,
                tier: nil,
                qualityScore: nil,
                parentSessionId: locator.contains("/subagents/") ? Self.parentSessionId(from: locator) : nil,
                suggestedParentId: nil
            )
        )
    }

    private struct SessionInfoAggregate {
        var sessionId = ""
        var agentId = ""
        var cwd = ""
        var startTime = ""
        var endTime = ""
        var userCount = 0
        var assistantCount = 0
        var toolCount = 0
        var systemCount = 0
        var firstUserText = ""
        var detectedModel = ""

        var messageCount: Int {
            userCount + assistantCount + toolCount
        }

        func id(locator: String) -> String? {
            guard !sessionId.isEmpty else { return nil }
            let isSubagent = locator.contains("/subagents/")
            return isSubagent && !agentId.isEmpty ? agentId : sessionId
        }

        func source(locator: String) -> SourceName? {
            guard !sessionId.isEmpty else { return nil }
            return ClaudeCodeAdapter.detectSource(model: detectedModel, filePath: locator)
        }
    }

    private static func aggregateSessionInfo(from objects: [JSONLAdapterSupport.JSONObject]) -> SessionInfoAggregate {
        var aggregate = SessionInfoAggregate()
        for object in objects {
            guard let type = JSONLAdapterSupport.string(object["type"]),
                  type == "user" || type == "assistant"
            else {
                continue
            }

            if aggregate.sessionId.isEmpty, let value = JSONLAdapterSupport.string(object["sessionId"]) {
                aggregate.sessionId = value
            }
            if aggregate.agentId.isEmpty, let value = JSONLAdapterSupport.string(object["agentId"]) {
                aggregate.agentId = value
            }
            if aggregate.cwd.isEmpty, let value = JSONLAdapterSupport.string(object["cwd"]) {
                aggregate.cwd = value
            }
            if aggregate.startTime.isEmpty, let value = JSONLAdapterSupport.string(object["timestamp"]) {
                aggregate.startTime = value
            }
            if let value = JSONLAdapterSupport.string(object["timestamp"]) {
                aggregate.endTime = value
            }

            let message = JSONLAdapterSupport.object(object["message"])
            if aggregate.detectedModel.isEmpty, let value = JSONLAdapterSupport.string(message?["model"]) {
                aggregate.detectedModel = value
            }

            if type == "assistant" {
                aggregate.assistantCount += 1
            } else if Self.isToolResult(message?["content"]) {
                // Count a tool_result user record only when it surfaces
                // non-empty content, matching message(from:) which drops
                // empty tool results from the streamed transcript.
                if !Self.extractContent(message?["content"]).isEmpty {
                    aggregate.toolCount += 1
                }
            } else {
                let text = Self.extractContent(message?["content"])
                if Self.isSystemInjection(text) {
                    aggregate.systemCount += 1
                } else {
                    aggregate.userCount += 1
                    if aggregate.firstUserText.isEmpty { aggregate.firstUserText = text }
                }
            }
        }
        return aggregate
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        guard profile(for: locator) != nil else {
            throw ParserFailure.unsupportedVirtualLocator
        }
        let messages = try JSONLAdapterSupport.windowedMessages(
            locator: locator,
            options: options,
            limits: limits,
            transform: Self.message(from:)
        )
        return JSONLAdapterSupport.stream(messages)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        guard profile(for: locator) != nil else {
            throw ParserFailure.unsupportedVirtualLocator
        }
        let result = try JSONLAdapterSupport.windowedMessagesWithMetadata(
            locator: locator,
            options: options,
            limits: limits,
            detectTruncation: options.limit == nil,
            transform: Self.message(from:)
        )
        return StreamMessagesResult(
            messages: JSONLAdapterSupport.stream(result.messages),
            totalKnownComplete: result.totalKnownComplete,
            truncatedAt: result.truncatedAt
        )
    }

    func isAccessible(locator: String) async -> Bool {
        profile(for: locator) != nil && JSONLAdapterSupport.fileExists(locator)
    }

    private func resolvedProfiles() -> [ClaudeCodeProfile] {
        switch profileSource {
        case .resolver(let resolver):
            return resolver.resolve().profiles
        case .fixed(let profile):
            return [profile]
        }
    }

    private static func profile(
        for locator: String,
        profiles: [ClaudeCodeProfile]
    ) -> ClaudeCodeProfile? {
        guard ArchiveSourceDescriptor.normalizedAbsolutePath(locator) != nil else { return nil }
        let canonicalLocator = canonicalURL(path: locator).path
        return profiles
            .filter { isDescendant(canonicalLocator, of: $0.projectsRoot) }
            .max { lhs, rhs in
                let lhsCount = URL(fileURLWithPath: lhs.projectsRoot).pathComponents.count
                let rhsCount = URL(fileURLWithPath: rhs.projectsRoot).pathComponents.count
                if lhsCount != rhsCount { return lhsCount < rhsCount }
                return lhs.projectsRoot < rhs.projectsRoot
            }
    }

    private static func canonicalURL(path: String) -> URL {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let rootComponents = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        return pathComponents.count > rootComponents.count
            && Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func projectName(fromCwd cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    static func detectSource(model: String, filePath: String? = nil) -> SourceName {
        if let filePath, hasLobsterAIPathComponent(filePath) { return .lobsterai }
        if model.isEmpty || model.hasPrefix("claude") || model.hasPrefix("<") {
            return .claudeCode
        }

        let lowercased = model.lowercased()
        if lowercased.contains("minimax") { return .minimax }
        // Qwen/Kimi/Gemini models can be routed through Claude-compatible clients,
        // but the session file is still owned by Claude Code's on-disk format.
        return .claudeCode
    }

    private static func hasLobsterAIPathComponent(_ filePath: String) -> Bool {
        filePath
            .components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .contains { component in
                let lowercased = component.lowercased()
                return lowercased == "lobsterai" ||
                    lowercased == ".lobsterai" ||
                    lowercased.hasPrefix("lobsterai-") ||
                    lowercased.hasPrefix("lobsterai_") ||
                    lowercased.hasPrefix("lobsterai.") ||
                    lowercased.hasPrefix(".lobsterai-") ||
                    lowercased.hasPrefix(".lobsterai_") ||
                    lowercased.hasPrefix(".lobsterai.")
            }
    }

    private static func detectSourceHint(locator: String) -> SourceName {
        if hasLobsterAIPathComponent(locator) { return .lobsterai }
        return detectSource(model: firstModelHint(locator: locator) ?? "")
    }

    private static func sourceHintSignature(
        locator: String,
        fileManager: FileManager
    ) -> ClaudeCodeSourceHintCache.Signature? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: locator)
            let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return ClaudeCodeSourceHintCache.Signature(modifiedAt: modifiedAt, size: size)
        } catch {
            return nil
        }
    }

    private static func firstModelHint(locator: String) -> String? {
        let url = URL(fileURLWithPath: locator)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var scannedBytes = 0
        var scannedLines = 0
        var droppingOversizedLine = false
        var reachedEOF = false

        while scannedBytes < sourceHintScanByteLimit && scannedLines < sourceHintLineLimit {
            let remaining = sourceHintScanByteLimit - scannedBytes
            let chunk = handle.readData(ofLength: min(sourceHintChunkSize, remaining))
            if chunk.isEmpty {
                reachedEOF = true
                break
            }
            scannedBytes += chunk.count

            if droppingOversizedLine {
                guard let newlineIndex = chunk.firstIndex(of: UInt8(ascii: "\n")) else { continue }
                droppingOversizedLine = false
                buffer = Data(chunk[(newlineIndex + 1)...])
            } else {
                buffer.append(chunk)
            }

            while scannedLines < sourceHintLineLimit,
                  let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])
                scannedLines += 1
                if let model = modelHint(inLine: lineData) { return model }
            }

            if buffer.count > sourceHintMaxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                droppingOversizedLine = true
            }
        }

        if reachedEOF,
           !buffer.isEmpty,
           scannedLines < sourceHintLineLimit,
           let model = modelHint(inLine: buffer) {
            return model
        }
        return nil
    }

    private static func modelHint(inLine lineData: Data) -> String? {
        guard lineData.count <= sourceHintMaxLineBytes,
              let text = String(data: lineData, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespaces).isEmpty,
              let object = JSONLAdapterSupport.parseObject(text)
        else {
            return nil
        }
        return modelHint(in: object)
    }

    private static func modelHint(in object: JSONLAdapterSupport.JSONObject) -> String? {
        if let model = JSONLAdapterSupport.string(object["model"]) { return model }
        if let message = JSONLAdapterSupport.object(object["message"]),
           let model = JSONLAdapterSupport.string(message["model"]) {
            return model
        }
        if let payload = JSONLAdapterSupport.object(object["payload"]),
           let model = JSONLAdapterSupport.string(payload["model"]) {
            return model
        }
        return nil
    }

    private static func modifiedAt(locator: String, fileManager: FileManager) throws -> Date {
        let attributes = try fileManager.attributesOfItem(atPath: locator)
        return attributes[.modificationDate] as? Date ?? .distantPast
    }

    static func decodeCwd(_ encoded: String) -> String {
        encoded
            .replacingOccurrences(of: "--", with: "\u{0}")
            .replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "\u{0}", with: "-")
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user" || type == "assistant"
        else {
            return nil
        }

        let message = JSONLAdapterSupport.object(object["message"])
        let rawContent = message?["content"]
        let toolCalls = toolCalls(from: rawContent)
        let content = extractContent(rawContent)
        // A user record that only carries a tool_result is a tool message, not
        // a user turn. Drop it when it surfaces no content so the streamed
        // transcript matches parseSessionInfo's counts.
        let isToolResultRecord = type == "user" && isToolResult(rawContent)
        if type == "user", !isToolResultRecord, isSystemInjection(content) {
            return nil
        }
        if isToolResultRecord, content.isEmpty {
            return nil
        }
        let role: NormalizedMessageRole = isToolResultRecord ? .tool : (type == "user" ? .user : .assistant)
        return NormalizedMessage(
            role: role,
            content: content,
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            usage: JSONLAdapterSupport.usage(from: JSONLAdapterSupport.object(message?["usage"]))
        )
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        text.hasPrefix("# AGENTS.md instructions for ") ||
            text.contains("<INSTRUCTIONS>") ||
            text.hasPrefix("<local-command-caveat>") ||
            text.hasPrefix("<local-command-stdout>") ||
            text.contains("<command-name>") ||
            text.contains("<command-message>") ||
            text.hasPrefix("Unknown skill: ") ||
            text.hasPrefix("Invoke the superpowers:") ||
            text.hasPrefix("Base directory for this skill:")
    }

    private static func isToolResult(_ content: Any?) -> Bool {
        guard let content = JSONLAdapterSupport.array(content) else { return false }
        return content.contains { item in
            JSONLAdapterSupport.string(JSONLAdapterSupport.object(item)?["type"]) == "tool_result"
        }
    }

    private static func extractContent(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let content = JSONLAdapterSupport.array(content) else { return "" }

        var parts: [String] = []
        var thinkingFallback = ""
        for item in content {
            guard let object = JSONLAdapterSupport.object(item),
                  let type = JSONLAdapterSupport.string(object["type"])
            else {
                continue
            }

            if type == "text", let text = JSONLAdapterSupport.string(object["text"]) {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != "Tool loaded." {
                    parts.append(text)
                }
            } else if type == "thinking", thinkingFallback.isEmpty,
                      let thinking = JSONLAdapterSupport.string(object["thinking"]) {
                thinkingFallback = thinking
            } else if type == "tool_use" {
                let formatted = formatToolUse(object)
                if !formatted.isEmpty { parts.append(formatted) }
            } else if type == "tool_result" {
                let formatted = formatToolResult(object)
                if !formatted.isEmpty { parts.append(formatted) }
            } else if type == "image" {
                let source = JSONLAdapterSupport.object(object["source"])
                let mediaType = JSONLAdapterSupport.string(source?["media_type"]) ?? "image/unknown"
                let dataLength = JSONLAdapterSupport.string(source?["data"])?.count ?? 0
                let sizeKB = Int((Double(dataLength) * 0.75 / 1024.0).rounded())
                parts.append("[Image: \(mediaType), ~\(sizeKB) KB]")
            }
        }

        let nonEmpty = parts.filter { !$0.isEmpty }
        if !nonEmpty.isEmpty { return nonEmpty.joined(separator: "\n\n") }
        return thinkingFallback
    }

    private static let noiseTools: Set<String> = [
        "ToolSearch",
        "ExitPlanMode",
        "EnterPlanMode",
        "Skill",
        "TodoWrite",
        "TodoRead",
        "TaskCreate",
        "TaskUpdate",
        "TaskGet",
        "TaskList"
    ]

    private static func toolCalls(from content: Any?) -> [NormalizedToolCall] {
        guard let content = JSONLAdapterSupport.array(content) else { return [] }
        return content.compactMap { item in
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "tool_use",
                  let name = JSONLAdapterSupport.string(object["name"])
            else {
                return nil
            }
            let input = object["input"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) }
            return NormalizedToolCall(name: name, input: input, output: nil)
        }
    }

    private static func formatToolUse(_ object: JSONLAdapterSupport.JSONObject) -> String {
        guard let name = JSONLAdapterSupport.string(object["name"]) else { return "" }
        if noiseTools.contains(name) { return "" }
        guard let input = JSONLAdapterSupport.object(object["input"]) else { return "`\(name)`" }
        if name == "AskUserQuestion",
           let questions = JSONLAdapterSupport.array(input["questions"]) as? [JSONLAdapterSupport.JSONObject] {
            return formatAskUserQuestion(questions)
        }

        let summary = summarizeToolInput(name: name, input: input)
        return summary.isEmpty ? "`\(name)`" : "`\(name)`: \(summary)"
    }

    private static func formatAskUserQuestion(_ questions: [JSONLAdapterSupport.JSONObject]) -> String {
        questions.map { question in
            let header = JSONLAdapterSupport.string(question["header"]).map { "**\($0)**\n" } ?? ""
            let body = JSONLAdapterSupport.string(question["question"]) ?? ""
            guard let options = JSONLAdapterSupport.array(question["options"]) else {
                return header + body
            }
            let optionLines = options.enumerated().compactMap { index, item -> String? in
                guard let option = JSONLAdapterSupport.object(item),
                      let label = JSONLAdapterSupport.string(option["label"])
                else {
                    return nil
                }
                let description = JSONLAdapterSupport.string(option["description"]).map { " - \($0)" } ?? ""
                return "  \(index + 1). \(label)\(description)"
            }
            return header + body + (optionLines.isEmpty ? "" : "\n" + optionLines.joined(separator: "\n"))
        }
        .joined(separator: "\n\n")
    }

    private static func formatToolResult(_ object: JSONLAdapterSupport.JSONObject) -> String {
        let content = object["content"]
        if let string = content as? String {
            return string.hasPrefix("User has answered") ? string : ""
        }
        guard let content = JSONLAdapterSupport.array(content) else { return "" }
        let texts = content.compactMap { item -> String? in
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "text"
            else {
                return nil
            }
            return JSONLAdapterSupport.string(object["text"])
        }
        let joined = texts.joined(separator: "\n")
        return joined.hasPrefix("User has answered") ? joined : ""
    }

    private static func summarizeToolInput(name: String, input: JSONLAdapterSupport.JSONObject) -> String {
        switch name {
        case "Read", "Write", "Edit":
            return JSONLAdapterSupport.string(input["file_path"]) ?? ""
        case "Bash":
            return String((JSONLAdapterSupport.string(input["command"]) ?? "").prefix(120))
        case "Glob", "Grep":
            return JSONLAdapterSupport.string(input["pattern"]) ?? ""
        case "Agent":
            return JSONLAdapterSupport.string(input["description"]) ?? ""
        default:
            return ""
        }
    }

    private static func parentSessionId(from locator: String) -> String? {
        let parts = locator.split(separator: "/").map(String.init)
        guard let subagentsIndex = parts.firstIndex(of: "subagents"),
              subagentsIndex > 0
        else {
            return nil
        }
        return parts[subagentsIndex - 1]
    }
}

private actor ClaudeCodeSourceHintCache {
    struct Signature: Equatable, Sendable {
        let modifiedAt: TimeInterval  // timeIntervalSince1970
        let size: Int64
    }

    private struct Entry: Sendable {
        let signature: Signature
        let source: SourceName
    }

    /// On-disk format. Bump `formatVersion` to invalidate every persisted entry
    /// when the sniffing logic or record shape changes.
    private struct DiskEntry: Codable {
        let modifiedAt: TimeInterval
        let size: Int64
        let source: String
    }

    private struct DiskCache: Codable {
        let version: Int
        let entries: [String: DiskEntry]
    }

    private static let formatVersion = 1

    private let fileURL: URL?
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false

    init(directory: URL?) {
        self.fileURL = directory?.appendingPathComponent("claude-source-hints.json")
    }

    func source(
        for locator: String,
        signature: Signature?,
        resolve: @Sendable () -> SourceName
    ) -> SourceName {
        loadIfNeeded()
        if let signature,
           let entry = entries[locator],
           entry.signature == signature {
            return entry.source
        }

        let source = resolve()
        if let signature {
            entries[locator] = Entry(signature: signature, source: source)
        } else {
            entries.removeValue(forKey: locator)
        }
        dirty = true
        return source
    }

    /// Persist the current entries. No-op when persistence is disabled
    /// (in-memory cache) or nothing changed since the last write.
    func flush() {
        guard let fileURL, dirty else { return }
        let disk = DiskCache(
            version: Self.formatVersion,
            entries: entries.mapValues {
                DiskEntry(modifiedAt: $0.signature.modifiedAt, size: $0.signature.size, source: $0.source.rawValue)
            }
        )
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        dirty = false
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let disk = try? JSONDecoder().decode(DiskCache.self, from: data),
              disk.version == Self.formatVersion
        else {
            return
        }
        for (locator, entry) in disk.entries {
            guard let source = SourceName(rawValue: entry.source) else { continue }
            entries[locator] = Entry(
                signature: Signature(modifiedAt: entry.modifiedAt, size: entry.size),
                source: source
            )
        }
    }
}

final class ClaudeCodeDerivedSourceAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
    let source: SourceName
    private let base: ClaudeCodeAdapter

    init(source: SourceName, base: ClaudeCodeAdapter) {
        precondition(source == .minimax || source == .lobsterai)
        self.source = source
        self.base = base
    }

    convenience init(
        source: SourceName,
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .path,
        limits: ParserLimits = .default,
        sourceHintCacheDirectory: URL? = nil
    ) {
        self.init(
            source: source,
            base: ClaudeCodeAdapter(
                projectsRoot: projectsRoot,
                limits: limits,
                sourceHintCacheDirectory: sourceHintCacheDirectory
            )
        )
    }

    func detect() async -> Bool {
        await base.detect()
    }

    func listSessionLocators() async throws -> [String] {
        try await base.listDerivedSessionLocators(source: source)
    }

    func listSessionLocators(modifiedSince: Date, fileManager: FileManager) async throws -> [String] {
        try await base.listDerivedSessionLocators(
            source: source,
            modifiedSince: modifiedSince,
            fileManager: fileManager
        )
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        switch try await base.parseSessionInfo(locator: locator) {
        case .success(let info) where info.source == source:
            return .success(info)
        case .success:
            return .failure(.unsupportedVirtualLocator)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        try await base.streamMessages(locator: locator, options: options)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        try await base.streamMessagesWithMetadata(locator: locator, options: options)
    }

    func isAccessible(locator: String) async -> Bool {
        await base.isAccessible(locator: locator)
    }
}
