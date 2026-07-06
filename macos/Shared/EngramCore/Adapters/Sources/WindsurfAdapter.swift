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

    static func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    static func firstUserText(in messages: [NormalizedMessage]) -> String {
        messages.first { $0.role == .user }?.content ?? ""
    }

}

final class WindsurfAdapter: SessionAdapter, Sendable {
    let source: SourceName = .windsurf
    private let cacheDir: URL
    private let limits: ParserLimits

    init(
        cacheDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/cache/windsurf")
            .path,
        limits: ParserLimits = .default
    ) {
        self.cacheDir = URL(fileURLWithPath: cacheDir)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(cacheDir)
    }

    func listSessionLocators() async throws -> [String] {
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
                    cwd: JSONLAdapterSupport.string(metadata["cwd"]) ?? "",
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

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        guard options.limit == nil else {
            return StreamMessagesResult(messages: try await streamMessages(locator: locator, options: options))
        }
        let result = try JSONLAdapterSupport.wholeDocumentMessagesWithMetadata(
            locator: locator,
            options: options,
            limits: limits
        ) { objects in
            CascadeCacheSupport.normalizedMessages(from: Array(objects.dropFirst()))
        }
        return JSONLAdapterSupport.stream(result)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }
}
