import Foundation

final class ClaudeCodeAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
    let source: SourceName = .claudeCode
    private let projectsRoot: URL
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
        self.projectsRoot = URL(fileURLWithPath: projectsRoot)
        self.limits = limits
        self.sourceHintCache = ClaudeCodeSourceHintCache(directory: sourceHintCacheDirectory)
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(projectsRoot)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for projectURL in JSONLAdapterSupport.directChildren(of: projectsRoot, includingHidden: true)
            where JSONLAdapterSupport.isDirectory(projectURL)
        {
            for entryURL in JSONLAdapterSupport.directChildren(of: projectURL) {
                if entryURL.pathExtension == "jsonl" {
                    locators.append(entryURL.path)
                    continue
                }

                let subagentsURL = entryURL.appendingPathComponent("subagents")
                guard JSONLAdapterSupport.isDirectory(subagentsURL) else { continue }
                for subagentURL in JSONLAdapterSupport.directChildren(of: subagentsURL)
                    where subagentURL.pathExtension == "jsonl"
                {
                    locators.append(subagentURL.path)
                }
            }
        }
        return locators.sorted()
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
        var locators: [String] = []
        for locator in try await listSessionLocators() {
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
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { return .failure(failure) }
            return Self.sessionInfo(from: objects, locator: locator)
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
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true
            )
            if let failure { return .failure(failure) }
            switch Self.sessionInfo(from: objects, locator: locator) {
            case .failure(let reason):
                return .failure(reason)
            case .success(let info):
                return .success(IndexingScan(info: info, messages: objects.compactMap(Self.message(from:))))
            }
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    private static func sessionInfo(
        from objects: [JSONLAdapterSupport.JSONObject],
        locator: String
    ) -> AdapterParseResult<NormalizedSessionInfo> {
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

        for object in objects {
            guard let type = JSONLAdapterSupport.string(object["type"]),
                  type == "user" || type == "assistant"
            else {
                continue
            }

            if sessionId.isEmpty, let value = JSONLAdapterSupport.string(object["sessionId"]) {
                sessionId = value
            }
            if agentId.isEmpty, let value = JSONLAdapterSupport.string(object["agentId"]) {
                agentId = value
            }
            if cwd.isEmpty, let value = JSONLAdapterSupport.string(object["cwd"]) {
                cwd = value
            }
            if startTime.isEmpty, let value = JSONLAdapterSupport.string(object["timestamp"]) {
                startTime = value
            }
            if let value = JSONLAdapterSupport.string(object["timestamp"]) {
                endTime = value
            }

            let message = JSONLAdapterSupport.object(object["message"])
            if detectedModel.isEmpty, let value = JSONLAdapterSupport.string(message?["model"]) {
                detectedModel = value
            }

            if type == "assistant" {
                assistantCount += 1
            } else if Self.isToolResult(message?["content"]) {
                // Count a tool_result user record only when it surfaces
                // non-empty content, matching message(from:) which drops
                // empty tool results from the streamed transcript.
                if !Self.extractContent(message?["content"]).isEmpty {
                    toolCount += 1
                }
            } else {
                let text = Self.extractContent(message?["content"])
                if Self.isSystemInjection(text) {
                    systemCount += 1
                } else {
                    userCount += 1
                    if firstUserText.isEmpty { firstUserText = text }
                }
            }
        }

        guard !sessionId.isEmpty else { return .failure(.malformedJSON) }
        let messageCount = userCount + assistantCount + toolCount
        guard messageCount > 0 else { return .failure(.noVisibleMessages) }

        let isSubagent = locator.contains("/subagents/")
        let id = isSubagent && !agentId.isEmpty ? agentId : sessionId
        let source = Self.detectSource(model: detectedModel, filePath: locator)
        let parentSessionId = isSubagent ? Self.parentSessionId(from: locator) : nil

        return .success(
            NormalizedSessionInfo(
                id: id,
                source: source,
                startTime: startTime,
                endTime: endTime != startTime ? endTime : nil,
                cwd: cwd,
                project: Self.projectName(fromCwd: cwd),
                model: detectedModel.isEmpty ? nil : detectedModel,
                messageCount: messageCount,
                userMessageCount: userCount,
                assistantMessageCount: assistantCount,
                toolMessageCount: toolCount,
                systemMessageCount: systemCount,
                summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                filePath: locator,
                sizeBytes: JSONLAdapterSupport.fileSize(locator: locator),
                indexedAt: nil,
                agentRole: isSubagent ? "subagent" : nil,
                originator: nil,
                origin: nil,
                summaryMessageCount: nil,
                tier: nil,
                qualityScore: nil,
                parentSessionId: parentSessionId,
                suggestedParentId: nil
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
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
        JSONLAdapterSupport.fileExists(locator)
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
