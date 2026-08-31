import Foundation

struct QwenAdapterTestHooks: Sendable {
    var beforeFinalIdentityValidation: @Sendable () -> Void

    init(beforeFinalIdentityValidation: @escaping @Sendable () -> Void = {}) {
        self.beforeFinalIdentityValidation = beforeFinalIdentityValidation
    }
}

final class QwenAdapter: SessionAdapter, Sendable {
    let source: SourceName = .qwen
    private let projectsRoot: URL
    private let limits: ParserLimits
    private let testHooks: QwenAdapterTestHooks

    init(
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwen/projects")
            .path,
        limits: ParserLimits = .default,
        testHooks: QwenAdapterTestHooks = QwenAdapterTestHooks()
    ) {
        self.projectsRoot = URL(fileURLWithPath: projectsRoot)
        self.limits = limits
        self.testHooks = testHooks
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
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: Self.countsTowardMessageLimit,
                beforeIdentityValidation: testHooks.beforeFinalIdentityValidation
            )
            if let failure {
                guard failure == .fileModifiedDuringParse,
                      !Self.messages(from: objects).isEmpty
                else {
                    return .failure(failure)
                }
            }

            var sessionId = ""
            var cwd = ""
            var model: String?
            var startTime = ""
            var endTime = ""
            var userCount = 0
            var assistantCount = 0
            var toolCount = 0
            var systemCount = 0
            var firstUserText = ""

            for object in objects {
                if sessionId.isEmpty, let value = JSONLAdapterSupport.string(object["sessionId"]) {
                    sessionId = value
                }
                guard let type = JSONLAdapterSupport.string(object["type"]),
                      type == "user" || type == "assistant" || type == "tool_result"
                else {
                    continue
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
                } else if type == "tool_result" {
                    toolCount += 1
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
            guard userCount + assistantCount + toolCount > 0 else { return .failure(.noVisibleMessages) }

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .qwen,
                    startTime: startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: cwd,
                    project: nil,
                    model: model,
                    messageCount: userCount + assistantCount + toolCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: toolCount,
                    systemMessageCount: systemCount,
                    summary: firstUserText.isEmpty ? nil : firstUserText,
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
        let (objects, failure) = try JSONLAdapterSupport.readObjects(
            locator: locator,
            limits: limits,
            reportFailures: true,
            countsTowardMessageLimit: Self.countsTowardMessageLimit,
            beforeIdentityValidation: testHooks.beforeFinalIdentityValidation
        )
        let messages = Self.messages(from: objects)
        if let failure, messages.isEmpty {
            throw failure
        }
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
            transform: Self.messages(from:),
            countsTowardMessageLimit: Self.countsTowardMessageLimit,
            countsProducedMessageTowardLimit: { $0.role != .system },
            beforeIdentityValidation: testHooks.beforeFinalIdentityValidation
        )
        return JSONLAdapterSupport.stream(result)
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
              type == "user" || type == "assistant" || type == "tool_result"
        else {
            return nil
        }

        if type == "tool_result" {
            let content = toolResultContent(from: object)
            return NormalizedMessage(
                role: .tool,
                content: content,
                timestamp: JSONLAdapterSupport.string(object["timestamp"]),
                toolCalls: nil,
                usage: nil
            )
        }

        let message = JSONLAdapterSupport.object(object["message"])
        let content = extractContent(message)
        let metadataUsage = usage(from: JSONLAdapterSupport.object(object["usageMetadata"]))
        let toolCalls = type == "assistant" ? nonEmptyToolCalls(from: message) : nil
        let role: NormalizedMessageRole = type == "assistant"
            ? .assistant
            : (isSystemInjection(content) ? .system : .user)
        return NormalizedMessage(
            role: role,
            content: content,
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: toolCalls,
            usage: type == "assistant" ? (metadataUsage ?? telemetryUsage) : nil
        )
    }

    private static func countsTowardMessageLimit(_ object: JSONLAdapterSupport.JSONObject) -> Bool {
        guard let message = message(from: object, telemetryUsage: nil) else { return false }
        return message.role != .system
    }

    private static func toolCalls(from message: JSONLAdapterSupport.JSONObject?) -> [NormalizedToolCall] {
        guard let parts = JSONLAdapterSupport.array(message?["parts"]) else { return [] }
        var calls: [NormalizedToolCall] = []
        for part in parts {
            guard let object = JSONLAdapterSupport.object(part),
                  let functionCall = JSONLAdapterSupport.object(object["functionCall"]),
                  let name = JSONLAdapterSupport.string(functionCall["name"]),
                  !name.isEmpty
            else {
                continue
            }
            let input = functionCall["args"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) }
            calls.append(NormalizedToolCall(name: name, input: input, output: nil))
        }
        return calls
    }

    private static func nonEmptyToolCalls(
        from message: JSONLAdapterSupport.JSONObject?
    ) -> [NormalizedToolCall]? {
        let calls = toolCalls(from: message)
        return calls.isEmpty ? nil : calls
    }

    private static func toolResultContent(from object: JSONLAdapterSupport.JSONObject) -> String {
        if let toolCallResult = JSONLAdapterSupport.object(object["toolCallResult"]) {
            if let display = JSONLAdapterSupport.string(toolCallResult["resultDisplay"]),
               !display.isEmpty
            {
                return display
            }
            if let error = JSONLAdapterSupport.string(toolCallResult["error"]), !error.isEmpty {
                return error
            }
        }

        guard let parts = JSONLAdapterSupport.array(
            JSONLAdapterSupport.object(object["message"])?["parts"]
        ) else {
            return ""
        }
        var chunks: [String] = []
        for part in parts {
            guard let partObject = JSONLAdapterSupport.object(part),
                  let functionResponse = JSONLAdapterSupport.object(partObject["functionResponse"])
            else {
                continue
            }
            if let response = functionResponse["response"] {
                if let text = JSONLAdapterSupport.string(response), !text.isEmpty {
                    chunks.append(text)
                } else if let objectResponse = JSONLAdapterSupport.object(response) {
                    if let output = JSONLAdapterSupport.string(objectResponse["output"]), !output.isEmpty {
                        chunks.append(output)
                    } else if let json = JSONLAdapterSupport.jsonString(objectResponse, limit: 2_000),
                              !json.isEmpty
                    {
                        chunks.append(json)
                    }
                } else if let json = JSONLAdapterSupport.jsonString(response, limit: 2_000),
                          !json.isEmpty
                {
                    chunks.append(json)
                }
            }
        }
        return chunks.joined(separator: "\n\n")
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
        SystemMessageClassifier.classify(content: text, source: "qwen") != .none
    }

    private static func extractContent(_ message: JSONLAdapterSupport.JSONObject?) -> String {
        guard let parts = JSONLAdapterSupport.array(message?["parts"]) else { return "" }
        var textParts: [String] = []
        for part in parts {
            guard let object = JSONLAdapterSupport.object(part),
                  (object["thought"] as? Bool) != true,
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
