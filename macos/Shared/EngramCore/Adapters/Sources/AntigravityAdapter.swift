import Foundation

final class AntigravityAdapter: SessionAdapter {
    let source: SourceName = .antigravity
    private let daemonDir: URL
    private let cacheDir: URL
    private let conversationsDir: URL
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
        limits: ParserLimits = .default,
        enableLiveSync: Bool = true
    ) {
        self.daemonDir = URL(fileURLWithPath: daemonDir)
        self.cacheDir = URL(fileURLWithPath: cacheDir)
        self.conversationsDir = URL(fileURLWithPath: conversationsDir)
        self.limits = limits
        self.enableLiveSync = enableLiveSync
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(daemonDir) || JSONLAdapterSupport.isDirectory(cacheDir)
    }

    func listSessionLocators() async throws -> [String] {
        await sync()
        return CascadeCacheSupport.jsonlLocators(cacheDir: cacheDir)
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
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

    private func inferredCWD(metadata: CascadeCacheSupport.JSONObject, locator: String) -> String {
        if let cwd = JSONLAdapterSupport.string(metadata["cwd"]), !cwd.isEmpty {
            return cwd
        }
        guard let content = try? String(contentsOfFile: locator, encoding: .utf8) else {
            return ""
        }
        let prefix = String(content.prefix(50_000))
        guard let regex = try? NSRegularExpression(pattern: #"/Users/[^/\s"'`]+/-Code-/([^/\s"'`]+)"#) else {
            return ""
        }
        let matches = regex.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
        var counts: [String: Int] = [:]
        for match in matches {
            guard let range = Range(match.range(at: 1), in: prefix) else { continue }
            counts[String(prefix[range]), default: 0] += 1
        }
        guard let top = counts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first else {
            return ""
        }
        let user = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        return "/Users/\(user)/-Code-/\(top.key)"
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}
