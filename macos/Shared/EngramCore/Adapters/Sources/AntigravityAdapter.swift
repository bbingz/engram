import Foundation

final class AntigravityAdapter: SessionAdapter, Sendable {
    let source: SourceName = .antigravity
    private let daemonDir: URL
    private let cacheDir: URL
    private let conversationsDir: URL
    private let cliBrainDir: URL
    private let limits: ParserLimits
    private let enableLiveSync: Bool

    init(
        daemonDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/daemon")
            .path,
        cacheDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/cache/antigravity")
            .path,
        conversationsDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/conversations")
            .path,
        cliBrainDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/brain")
            .path,
        limits: ParserLimits = .default,
        enableLiveSync: Bool = true
    ) {
        self.daemonDir = URL(fileURLWithPath: daemonDir)
        self.cacheDir = URL(fileURLWithPath: cacheDir)
        self.conversationsDir = URL(fileURLWithPath: conversationsDir)
        self.cliBrainDir = URL(fileURLWithPath: cliBrainDir)
        self.limits = limits
        self.enableLiveSync = enableLiveSync
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(daemonDir) ||
            JSONLAdapterSupport.isDirectory(cacheDir) ||
            JSONLAdapterSupport.isDirectory(cliBrainDir)
    }

    func listSessionLocators() async throws -> [String] {
        await sync()
        return (CascadeCacheSupport.jsonlLocators(cacheDir: cacheDir) + cliTranscriptLocators()).sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        if isCLITranscript(locator) {
            return try parseCLITranscript(locator: locator)
        }
        do {
            let (metadata, rawMessages, failure) = try CascadeCacheSupport.readCache(locator: locator, limits: limits)
            if let failure { return .failure(failure) }
            guard let metadata,
                  let id = JSONLAdapterSupport.string(metadata["id"]),
                  !id.isEmpty,
                  let createdAt = JSONLAdapterSupport.string(metadata["createdAt"])
            else {
                return .failure(.malformedJSON)
            }

            let messages = CascadeCacheSupport.normalizedMessages(from: rawMessages)
            let userCount = messages.filter { $0.role == .user }.count
            let assistantCount = messages.filter { $0.role == .assistant }.count
            let firstUserText = CascadeCacheSupport.firstUserText(in: messages)
            let title = JSONLAdapterSupport.string(metadata["title"]) ?? ""
            let summary = JSONLAdapterSupport.string(metadata["summary"]) ?? ""
            let updatedAt = JSONLAdapterSupport.string(metadata["updatedAt"]) ?? createdAt
            let cwd = inferredCWD(metadata: metadata, locator: locator)

            let summaryText = String((!title.isEmpty ? title : (!summary.isEmpty ? summary : firstUserText)).prefix(200))
            return .success(
                NormalizedSessionInfo(
                    id: id,
                    source: .antigravity,
                    startTime: createdAt,
                    endTime: updatedAt != createdAt ? updatedAt : nil,
                    cwd: cwd,
                    project: nil,
                    model: nil,
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: summaryText.isEmpty ? nil : summaryText,
                    filePath: locator,
                    sizeBytes: sizeBytes(metadata: metadata, id: id, locator: locator),
                    indexedAt: nil,
                    agentRole: nil,
                    originator: nil,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: nil,
                    suggestedParentId: nil
                )
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        if isCLITranscript(locator) {
            let messages = try JSONLAdapterSupport.windowedMessages(
                locator: locator,
                options: options,
                limits: limits,
                transform: Self.cliMessage(from:)
            )
            return JSONLAdapterSupport.stream(messages)
        }
        let (_, rawMessages, failure) = try CascadeCacheSupport.readCache(locator: locator, limits: limits)
        if let failure { throw failure }
        let messages = CascadeCacheSupport.normalizedMessages(from: rawMessages)
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private func sync() async {
        guard enableLiveSync,
              let client = await CascadeDiscovery.discoverAntigravityClient(daemonDir: daemonDir.path),
              let conversations = try? await client.listConversations()
        else {
            return
        }

        var syncedIds = Set<String>()
        for conversation in conversations where !conversation.cascadeId.isEmpty {
            syncedIds.insert(conversation.cascadeId)
            await syncConversation(conversation, client: client)
        }
        await syncFromPbFiles(client: client, syncedIds: syncedIds)
    }

    private func syncConversation(_ conversation: CascadeConversationSummary, client: CascadeClient) async {
        let cacheURL = cacheDir.appendingPathComponent("\(conversation.cascadeId).jsonl")
        let pbURL = conversationsDir.appendingPathComponent("\(conversation.cascadeId).pb")
        if isFresh(cacheURL: cacheURL, pbURL: pbURL, requireContent: true) {
            return
        }

        var messages = (try? await client.getTrajectoryMessages(cascadeId: conversation.cascadeId)) ?? []
        if messages.isEmpty,
           let markdown = try? await client.getMarkdown(cascadeId: conversation.cascadeId)
        {
            messages = CascadeCacheSupport.parseMarkdownToMessages(markdown)
        }
        if messages.isEmpty, !conversation.summary.isEmpty {
            messages = [CascadeTrajectoryMessage(role: .assistant, content: conversation.summary)]
        }

        var metadata: CascadeCacheSupport.JSONObject = [
            "id": conversation.cascadeId,
            "title": conversation.title,
            "summary": conversation.summary,
            "createdAt": conversation.createdAt,
            "updatedAt": conversation.updatedAt
        ]
        if !conversation.cwd.isEmpty {
            metadata["cwd"] = conversation.cwd
        }
        if let pbSize = CascadeCacheSupport.fileSize(pbURL), pbSize > 0 {
            metadata["pbSizeBytes"] = pbSize
        }
        try? CascadeCacheSupport.writeCache(cacheURL: cacheURL, metadata: metadata, messages: messages)
    }

    private func syncFromPbFiles(client: CascadeClient, syncedIds: Set<String>) async {
        let pbFiles = JSONLAdapterSupport.directChildren(of: conversationsDir)
            .filter { $0.pathExtension == "pb" }
            .sorted { $0.path < $1.path }
        for pbURL in pbFiles {
            let cascadeId = pbURL.deletingPathExtension().lastPathComponent
            guard !syncedIds.contains(cascadeId) else { continue }

            let cacheURL = cacheDir.appendingPathComponent("\(cascadeId).jsonl")
            if let cacheSize = CascadeCacheSupport.fileSize(cacheURL), cacheSize > 200 {
                continue
            }

            var messages = (try? await client.getTrajectoryMessages(cascadeId: cascadeId)) ?? []
            if messages.isEmpty,
               let markdown = try? await client.getMarkdown(cascadeId: cascadeId)
            {
                messages = CascadeCacheSupport.parseMarkdownToMessages(markdown)
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: pbURL.path)
            let createdAt = (attributes?[.creationDate] as? Date).map(Self.isoString) ?? ""
            let updatedAt = (attributes?[.modificationDate] as? Date).map(Self.isoString) ?? createdAt
            let metadata: CascadeCacheSupport.JSONObject = [
                "id": cascadeId,
                "title": "",
                "createdAt": createdAt,
                "updatedAt": updatedAt,
                "pbSizeBytes": CascadeCacheSupport.fileSize(pbURL) ?? 0
            ]
            try? CascadeCacheSupport.writeCache(cacheURL: cacheURL, metadata: metadata, messages: messages)
        }
    }

    private func isFresh(cacheURL: URL, pbURL: URL, requireContent: Bool) -> Bool {
        guard let cacheAttributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let cacheModified = cacheAttributes[.modificationDate] as? Date
        else {
            return false
        }
        if requireContent,
           let size = (cacheAttributes[.size] as? NSNumber)?.int64Value,
           size <= 200
        {
            return false
        }
        guard let pbAttributes = try? FileManager.default.attributesOfItem(atPath: pbURL.path),
              let pbModified = pbAttributes[.modificationDate] as? Date
        else {
            return false
        }
        return cacheModified >= pbModified
    }

    private func sizeBytes(metadata: CascadeCacheSupport.JSONObject, id: String, locator: String) -> Int64 {
        if let number = metadata["pbSizeBytes"] as? NSNumber, number.int64Value > 0 {
            return number.int64Value
        }
        if let string = metadata["pbSizeBytes"] as? String,
           let value = Int64(string),
           value > 0
        {
            return value
        }
        let pbURL = conversationsDir.appendingPathComponent("\(id).pb")
        return CascadeCacheSupport.fileSize(pbURL) ?? JSONLAdapterSupport.fileSize(locator: locator)
    }

    private func cliTranscriptLocators() -> [String] {
        guard JSONLAdapterSupport.isDirectory(cliBrainDir) else { return [] }
        var locators: [String] = []
        for sessionURL in JSONLAdapterSupport.directChildren(of: cliBrainDir)
            where JSONLAdapterSupport.isDirectory(sessionURL)
        {
            let transcriptURL = sessionURL
                .appendingPathComponent(".system_generated/logs/transcript.jsonl")
            if JSONLAdapterSupport.fileExists(transcriptURL.path) {
                locators.append(transcriptURL.path)
            }
        }
        return locators
    }

    private func isCLITranscript(_ locator: String) -> Bool {
        let path = URL(fileURLWithPath: locator).standardizedFileURL.path
        let root = cliBrainDir.standardizedFileURL.path
        if path == root || path.hasPrefix(root + "/") {
            return true
        }
        return path.contains("/.gemini/antigravity-cli/brain/") &&
            path.hasSuffix("/.system_generated/logs/transcript.jsonl")
    }

    private func parseCLITranscript(locator: String) throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { return .failure(failure) }

            var startTime = ""
            var endTime = ""
            var userCount = 0
            var assistantCount = 0
            var toolCount = 0
            var firstUserText = ""

            for object in objects {
                guard let message = Self.cliMessage(from: object) else { continue }
                if startTime.isEmpty, let timestamp = message.timestamp {
                    startTime = timestamp
                }
                if let timestamp = message.timestamp {
                    endTime = timestamp
                }
                switch message.role {
                case .user:
                    userCount += 1
                    if firstUserText.isEmpty { firstUserText = message.content }
                case .assistant:
                    assistantCount += 1
                case .tool:
                    toolCount += 1
                case .system:
                    break
                }
            }

            let id = cliSessionId(from: locator)
            guard !id.isEmpty, userCount + assistantCount + toolCount > 0 else {
                return .failure(.malformedJSON)
            }

            return .success(
                NormalizedSessionInfo(
                    id: id,
                    source: .antigravity,
                    startTime: startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: inferredCWD(metadata: [:], locator: locator),
                    project: nil,
                    model: nil,
                    messageCount: userCount + assistantCount + toolCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: toolCount,
                    systemMessageCount: 0,
                    summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                    filePath: locator,
                    sizeBytes: JSONLAdapterSupport.fileSize(locator: locator),
                    indexedAt: nil,
                    agentRole: nil,
                    originator: nil,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: nil,
                    suggestedParentId: nil
                )
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    private static func cliMessage(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]) else { return nil }
        let timestamp = JSONLAdapterSupport.string(object["created_at"])
        let content = JSONLAdapterSupport.string(object["content"]) ?? ""
        switch type {
        case "USER_INPUT":
            return NormalizedMessage(role: .user, content: content, timestamp: timestamp)
        case "PLANNER_RESPONSE":
            let toolCalls = cliToolCalls(from: object["tool_calls"])
            let body = !content.isEmpty ? content : (JSONLAdapterSupport.string(object["thinking"]) ?? "")
            return NormalizedMessage(
                role: .assistant,
                content: body,
                timestamp: timestamp,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                usage: nil
            )
        case "VIEW_FILE", "TOOL_OUTPUT", "COMMAND_OUTPUT", "SHELL_OUTPUT", "APPLY_PATCH":
            guard !content.isEmpty else { return nil }
            return NormalizedMessage(role: .tool, content: content, timestamp: timestamp)
        default:
            return nil
        }
    }

    private static func cliToolCalls(from value: Any?) -> [NormalizedToolCall] {
        guard let calls = JSONLAdapterSupport.array(value) else { return [] }
        return calls.compactMap { item in
            guard let object = JSONLAdapterSupport.object(item),
                  let name = JSONLAdapterSupport.string(object["name"])
            else { return nil }
            return NormalizedToolCall(
                name: name,
                input: object["args"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) },
                output: nil
            )
        }
    }

    private func cliSessionId(from locator: String) -> String {
        let path = URL(fileURLWithPath: locator).standardizedFileURL.path
        let root = cliBrainDir.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            let relative = String(path.dropFirst(root.count + 1))
            let first = relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if !first.hasSuffix(".jsonl") {
                return first
            }
        }

        if path.hasSuffix("/.system_generated/logs/transcript.jsonl") {
            let logs = URL(fileURLWithPath: path).deletingLastPathComponent()
            let systemGenerated = logs.deletingLastPathComponent()
            if systemGenerated.lastPathComponent == ".system_generated" {
                return systemGenerated.deletingLastPathComponent().lastPathComponent
            }
        }

        let parts = path.split(separator: "/").map(String.init)
        guard
            let brainIndex = parts.lastIndex(of: "brain"),
            parts.count > brainIndex + 4,
            parts[brainIndex + 2] == ".system_generated",
            parts[brainIndex + 3] == "logs",
            parts[brainIndex + 4] == "transcript.jsonl"
        else {
            return URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent
        }
        return parts[brainIndex + 1]
    }

    private func inferredCWD(metadata: CascadeCacheSupport.JSONObject, locator: String) -> String {
        if let cwd = JSONLAdapterSupport.string(metadata["cwd"]), !cwd.isEmpty {
            return cwd
        }
        guard let content = try? String(contentsOfFile: locator, encoding: .utf8) else {
            return ""
        }
        return Self.inferCWDFromAbsolutePaths(in: String(content.prefix(50_000)))
    }

    // Derive a working directory from the absolute file paths the transcript
    // references, using a generic most-frequent-directory heuristic. This makes
    // no assumption about the user's name or a personal directory layout — the
    // source session may belong to a different user or directory shape.
    static func inferCWDFromAbsolutePaths(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(/(?:[^/\s"'`]+/)+)[^/\s"'`]+"#) else {
            return ""
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var counts: [String: Int] = [:]
        for match in matches {
            // Capture group 1 is the directory portion (everything up to and
            // including the final slash). Drop the trailing slash so the cwd is
            // returned without it.
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else {
                continue
            }
            var directory = String(text[range])
            if directory.count > 1, directory.hasSuffix("/") {
                directory.removeLast()
            }
            counts[directory, default: 0] += 1
        }
        guard let top = counts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first else {
            return ""
        }
        return top.key
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}
