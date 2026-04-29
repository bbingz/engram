import Foundation

enum CascadeCacheSupport {
    typealias JSONObject = JSONLAdapterSupport.JSONObject

    static func jsonlLocators(cacheDir: URL) -> [String] {
        JSONLAdapterSupport.directChildren(of: cacheDir)
            .filter { $0.pathExtension == "jsonl" }
            .map(\.path)
            .sorted()
    }

    static func readCache(locator: String, limits: ParserLimits) throws -> (JSONObject?, [JSONObject], ParserFailure?) {
        let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
        if let failure { return (objects.first, Array(objects.dropFirst()), failure) }
        return (objects.first, Array(objects.dropFirst()), nil)
    }

    static func normalizedMessages(from objects: [JSONObject]) -> [NormalizedMessage] {
        objects.compactMap { object in
            guard let roleValue = JSONLAdapterSupport.string(object["role"]),
                  let role = NormalizedMessageRole(rawValue: roleValue),
                  role == .user || role == .assistant
            else {
                return nil
            }
            return NormalizedMessage(
                role: role,
                content: JSONLAdapterSupport.string(object["content"]) ?? "",
                timestamp: JSONLAdapterSupport.string(object["timestamp"]),
                toolCalls: nil,
                usage: nil
            )
        }
    }

    static func parseMarkdownToMessages(_ markdown: String) -> [CascadeTrajectoryMessage] {
        let marker = "\u{1E}"
        let normalized = markdown.replacingOccurrences(
            of: #"(?m)^##\s+"#,
            with: marker,
            options: .regularExpression
        )
        return normalized
            .components(separatedBy: marker)
            .compactMap { section -> CascadeTrajectoryMessage? in
                guard let newline = section.firstIndex(of: "\n") else { return nil }
                let header = section[..<newline].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let contentStart = section.index(after: newline)
                let content = section[contentStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                if header.hasPrefix("user") {
                    return CascadeTrajectoryMessage(role: .user, content: content)
                }
                if header.hasPrefix("assistant") || header.hasPrefix("cascade") {
                    return CascadeTrajectoryMessage(role: .assistant, content: content)
                }
                return nil
            }
    }

    static func writeCache(
        cacheURL: URL,
        metadata: JSONObject,
        messages: [CascadeTrajectoryMessage]
    ) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let lines = [try jsonLine(metadata)] + messages.map { message in
            let object: JSONObject = [
                "role": message.role.rawValue,
                "content": message.content
            ]
            return (try? jsonLine(object)) ?? "{}"
        }
        try (lines.joined(separator: "\n") + "\n").write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    static func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    static func firstUserText(in messages: [NormalizedMessage]) -> String {
        messages.first { $0.role == .user }?.content ?? ""
    }

    private static func jsonLine(_ object: JSONObject) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

final class WindsurfAdapter: SessionAdapter {
    let source: SourceName = .windsurf
    private let daemonDir: URL
    private let cacheDir: URL
    private let conversationsDir: URL
    private let limits: ParserLimits
    private let enableLiveSync: Bool

    init(
        daemonDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codeium/windsurf/daemon")
            .path,
        cacheDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/cache/windsurf")
            .path,
        conversationsDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codeium/windsurf/cascade")
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
            let updatedAt = JSONLAdapterSupport.string(metadata["updatedAt"]) ?? createdAt

            let summaryText = String((title.isEmpty ? firstUserText : title).prefix(200))
            return .success(
                NormalizedSessionInfo(
                    id: id,
                    source: .windsurf,
                    startTime: createdAt,
                    endTime: updatedAt != createdAt ? updatedAt : nil,
                    cwd: "",
                    project: nil,
                    model: nil,
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: summaryText.isEmpty ? nil : summaryText,
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
              let client = await CascadeDiscovery.discoverWindsurfClient(daemonDir: daemonDir.path)
        else {
            return
        }
        guard let conversations = try? await client.listConversations() else { return }

        for conversation in conversations where !conversation.cascadeId.isEmpty {
            let cacheURL = cacheDir.appendingPathComponent("\(conversation.cascadeId).jsonl")
            let pbURL = conversationsDir.appendingPathComponent("\(conversation.cascadeId).pb")
            if isFresh(cacheURL: cacheURL, pbURL: pbURL, requireContent: false) {
                continue
            }

            guard let markdown = try? await client.getMarkdown(cascadeId: conversation.cascadeId) else {
                continue
            }
            let messages = CascadeCacheSupport.parseMarkdownToMessages(markdown)
            let metadata: CascadeCacheSupport.JSONObject = [
                "id": conversation.cascadeId,
                "title": conversation.title,
                "createdAt": conversation.createdAt,
                "updatedAt": conversation.updatedAt
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
}
