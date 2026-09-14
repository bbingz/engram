import Foundation

enum CascadeCacheSupport {
    typealias JSONObject = JSONLAdapterSupport.JSONObject

    static func jsonlLocators(cacheDir: URL) -> [String] {
        JSONLAdapterSupport.directChildren(of: cacheDir)
            .filter { $0.pathExtension == "jsonl" }
            .map(\.path)
            .sorted()
    }

    static func readCache(
        locator: String,
        limits: ParserLimits,
        reportFailures: Bool = false,
        countsTowardMessageLimit: ((JSONObject) -> Bool)? = nil
    ) throws -> (JSONObject?, [JSONObject], ParserFailure?) {
        let (objects, failure) = try JSONLAdapterSupport.readObjects(
            locator: locator,
            limits: limits,
            reportFailures: reportFailures,
            countsTowardMessageLimit: countsTowardMessageLimit
        )
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

    static func countsTowardMessageLimit(_ object: JSONObject) -> Bool {
        guard let roleValue = JSONLAdapterSupport.string(object["role"]),
              let role = NormalizedMessageRole(rawValue: roleValue)
        else {
            return false
        }
        return role == .user || role == .assistant
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
            let (metadata, rawMessages, failure) = try CascadeCacheSupport.readCache(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: CascadeCacheSupport.countsTowardMessageLimit
            )
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
            // R184-3: metadata-only Cascade cache files must not become
            // zero-count browsable sessions.
            guard userCount + assistantCount > 0 else {
                return .failure(.noVisibleMessages)
            }
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
        let (_, rawMessages, failure) = try CascadeCacheSupport.readCache(
            locator: locator,
            limits: limits,
            reportFailures: true,
            countsTowardMessageLimit: CascadeCacheSupport.countsTowardMessageLimit
        )
        if let failure { throw failure }
        let messages = CascadeCacheSupport.normalizedMessages(from: rawMessages)
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        let result = try JSONLAdapterSupport.wholeDocumentMessagesWithMetadata(
            locator: locator,
            options: options,
            limits: limits,
            transform: { objects in
                CascadeCacheSupport.normalizedMessages(from: Array(objects.dropFirst()))
            },
            countsTowardMessageLimit: CascadeCacheSupport.countsTowardMessageLimit
        )
        return JSONLAdapterSupport.stream(result)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    /// Replay a frozen official hook JSONL. Identity is the logical
    /// `…/transcripts/{id}.jsonl` stem; the staged filename may differ.
    /// Reads only `physicalLocator` bytes. Does not invent time, model, or cwd.
    static func scanCapturedHookTranscript(
        physicalLocator: String,
        logicalLocator: String,
        limits: ParserLimits = .default
    ) async throws -> AdapterParseResult<CapturedSourceScan> {
        try Task.checkCancellation()
        guard let id = hookNativeID(logicalLocator: logicalLocator) else {
            return .failure(.malformedJSON)
        }
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: physicalLocator,
                limits: limits,
                reportFailures: true,
                strictRecords: true
            )
            if let failure { return .failure(failure) }
            var messages: [NormalizedMessage] = []
            messages.reserveCapacity(objects.count)
            for object in objects {
                switch hookMessage(from: object) {
                case .failure(let reason):
                    return .failure(reason)
                case .success(let message):
                    messages.append(message)
                }
            }
            guard !messages.isEmpty else {
                return .failure(.noVisibleMessages)
            }
            let userCount = messages.filter { $0.role == .user }.count
            let assistantCount = messages.filter { $0.role == .assistant }.count
            let toolCount = messages.filter { $0.role == .tool }.count
            let firstUserText = messages.first { $0.role == .user }?.content ?? ""
            return .success(CapturedSourceScan(
                scan: IndexingScan(
                    info: NormalizedSessionInfo(
                        id: id,
                        source: .windsurf,
                        startTime: "",
                        endTime: nil,
                        cwd: "",
                        project: nil,
                        model: nil,
                        messageCount: messages.count,
                        userMessageCount: userCount,
                        assistantMessageCount: assistantCount,
                        toolMessageCount: toolCount,
                        systemMessageCount: 0,
                        summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                        filePath: logicalLocator,
                        sizeBytes: JSONLAdapterSupport.fileSize(locator: physicalLocator),
                        indexedAt: nil,
                        agentRole: nil,
                        originator: nil,
                        origin: nil,
                        summaryMessageCount: nil,
                        tier: nil,
                        qualityScore: nil,
                        parentSessionId: nil,
                        suggestedParentId: nil
                    ),
                    messages: messages
                ),
                rawSourceSessionID: id
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    /// Logical replay layout only. Does not consult a live transcripts root
    /// or the staged physical name. Hidden stems and non-jsonl names fail.
    private static func hookNativeID(logicalLocator: String) -> String? {
        ArchiveSourceDescriptor.windsurfHookNativeID(logicalLocator: logicalLocator)
    }

    private static func hookTypeAndStatus(_ object: CascadeCacheSupport.JSONObject) -> (type: String, status: String)? {
        guard let type = JSONLAdapterSupport.string(object["type"]), !type.isEmpty,
              let status = JSONLAdapterSupport.string(object["status"]), !status.isEmpty else {
            return nil
        }
        return (type, status)
    }

    private static func hookMessage(
        from object: CascadeCacheSupport.JSONObject
    ) -> Result<NormalizedMessage, ParserFailure> {
        guard let header = hookTypeAndStatus(object) else {
            return .failure(.malformedJSON)
        }
        switch header.type {
        case "user_input":
            guard let payload = JSONLAdapterSupport.object(object["user_input"]),
                  let text = JSONLAdapterSupport.string(payload["user_response"]) else {
                return .failure(.malformedJSON)
            }
            return .success(NormalizedMessage(role: .user, content: text))
        case "planner_response":
            guard let payload = JSONLAdapterSupport.object(object["planner_response"]),
                  let text = JSONLAdapterSupport.string(payload["response"]) else {
                return .failure(.malformedJSON)
            }
            return .success(NormalizedMessage(role: .assistant, content: text))
        case "code_action":
            guard JSONLAdapterSupport.object(object["code_action"]) != nil,
                  let json = JSONLAdapterSupport.jsonString(object) else {
                return .failure(.malformedJSON)
            }
            return .success(NormalizedMessage(role: .tool, content: json))
        default:
            guard let json = JSONLAdapterSupport.jsonString(object) else {
                return .failure(.malformedJSON)
            }
            return .success(NormalizedMessage(role: .tool, content: json))
        }
    }


}
