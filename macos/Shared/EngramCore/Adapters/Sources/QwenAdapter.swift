import Foundation

final class QwenAdapter: SessionAdapter, Sendable {
    let source: SourceName = .qwen
    private let projectsRoot: URL
    private let limits: ParserLimits

    init(
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwen/projects")
            .path,
        limits: ParserLimits = .default
    ) {
        self.projectsRoot = URL(fileURLWithPath: projectsRoot)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(projectsRoot)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for projectURL in JSONLAdapterSupport.directChildren(of: projectsRoot)
            where JSONLAdapterSupport.isDirectory(projectURL)
        {
            let chatsURL = projectURL.appendingPathComponent("chats")
            guard JSONLAdapterSupport.isDirectory(chatsURL) else { continue }
            for fileURL in JSONLAdapterSupport.directChildren(of: chatsURL)
                where fileURL.pathExtension == "jsonl"
            {
                locators.append(fileURL.path)
            }
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { return .failure(failure) }

            var sessionId = ""
            var cwd = ""
            var model: String?
            var startTime = ""
            var endTime = ""
            var userCount = 0
            var assistantCount = 0
            var systemCount = 0
            var firstUserText = ""

            for object in objects {
                guard let type = JSONLAdapterSupport.string(object["type"]),
                      type == "user" || type == "assistant"
                else {
                    continue
                }

                if sessionId.isEmpty, let value = JSONLAdapterSupport.string(object["sessionId"]) {
                    sessionId = value
                }
                if cwd.isEmpty, let value = JSONLAdapterSupport.string(object["cwd"]) {
                    cwd = value
                }
                if model == nil, let value = JSONLAdapterSupport.string(object["model"]) {
                    model = value
                }
                if startTime.isEmpty, let value = JSONLAdapterSupport.string(object["timestamp"]) {
                    startTime = value
                }
                if let value = JSONLAdapterSupport.string(object["timestamp"]) {
                    endTime = value
                }

                if type == "assistant" {
                    assistantCount += 1
                } else {
                    let message = JSONLAdapterSupport.object(object["message"])
                    let text = Self.extractContent(message)
                    if Self.isSystemInjection(text) {
                        systemCount += 1
                    } else {
                        userCount += 1
                        if firstUserText.isEmpty { firstUserText = text }
                    }
                }
            }

            guard !sessionId.isEmpty else { return .failure(.malformedJSON) }

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .qwen,
                    startTime: startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: cwd,
                    project: nil,
                    model: model,
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
                    systemMessageCount: systemCount,
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

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
        if let failure { throw failure }
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(Self.messages(from: objects), options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func messages(from objects: [JSONLAdapterSupport.JSONObject]) -> [NormalizedMessage] {
        var pendingTelemetryUsage: TokenUsage?
        return objects.compactMap { object in
            if let telemetryUsage = telemetryUsage(from: object) {
                pendingTelemetryUsage = telemetryUsage
                return nil
            }
            let message = message(from: object, telemetryUsage: pendingTelemetryUsage)
            if message?.role == .assistant {
                pendingTelemetryUsage = nil
            }
            return message
        }
    }

    private static func message(
        from object: JSONLAdapterSupport.JSONObject,
        telemetryUsage: TokenUsage? = nil
    ) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user" || type == "assistant"
        else {
            return nil
        }
        let metadataUsage = usage(from: JSONLAdapterSupport.object(object["usageMetadata"]))
        return NormalizedMessage(
            role: type == "assistant" ? .assistant : .user,
            content: extractContent(JSONLAdapterSupport.object(object["message"])),
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: nil,
            usage: type == "assistant" ? (metadataUsage ?? telemetryUsage) : nil
        )
    }

    private static func telemetryUsage(from object: JSONLAdapterSupport.JSONObject) -> TokenUsage? {
        guard JSONLAdapterSupport.string(object["type"]) == "system",
              JSONLAdapterSupport.string(object["subtype"]) == "ui_telemetry",
              let payload = JSONLAdapterSupport.object(object["systemPayload"]),
              let uiEvent = JSONLAdapterSupport.object(payload["uiEvent"]),
              JSONLAdapterSupport.string(uiEvent["event.name"]) == "qwen-code.api_response"
        else {
            return nil
        }
        let usage = TokenUsage(
            inputTokens: int(uiEvent["input_token_count"]),
            outputTokens: int(uiEvent["output_token_count"]),
            cacheReadTokens: int(uiEvent["cached_content_token_count"]),
            cacheCreationTokens: 0
        )
        guard usage.inputTokens > 0
            || usage.outputTokens > 0
            || (usage.cacheReadTokens ?? 0) > 0
        else {
            return nil
        }
        return usage
    }

    private static func usage(from metadata: JSONLAdapterSupport.JSONObject?) -> TokenUsage? {
        guard let metadata else { return nil }
        let usage = TokenUsage(
            inputTokens: int(metadata["promptTokenCount"]),
            outputTokens: int(metadata["candidatesTokenCount"]),
            cacheReadTokens: int(metadata["cachedContentTokenCount"]),
            cacheCreationTokens: 0
        )
        guard usage.inputTokens > 0
            || usage.outputTokens > 0
            || (usage.cacheReadTokens ?? 0) > 0
        else {
            return nil
        }
        return usage
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        text.hasPrefix("\nYou are Qwen Code") ||
            text.hasPrefix("You are Qwen Code") ||
            text.contains("<INSTRUCTIONS>")
    }

    private static func extractContent(_ message: JSONLAdapterSupport.JSONObject?) -> String {
        guard let parts = JSONLAdapterSupport.array(message?["parts"]) else { return "" }
        var textParts: [String] = []
        for part in parts {
            guard let object = JSONLAdapterSupport.object(part),
                  let text = JSONLAdapterSupport.string(object["text"]),
                  !text.isEmpty
            else {
                continue
            }
            textParts.append(text)
        }
        return textParts.joined(separator: "\n\n")
    }
}
