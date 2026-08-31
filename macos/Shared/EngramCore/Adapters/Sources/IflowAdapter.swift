import Foundation

final class IflowAdapter: SessionAdapter, Sendable {
    let source: SourceName = .iflow
    private let projectsRoot: URL
    private let limits: ParserLimits
    private let testHooks: JSONLIdentityTestHooks

    init(
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iflow/projects")
            .path,
        limits: ParserLimits = .default,
        testHooks: JSONLIdentityTestHooks = JSONLIdentityTestHooks()
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
            for fileURL in JSONLAdapterSupport.directChildren(of: projectURL)
                where fileURL.lastPathComponent.hasPrefix("session-") && fileURL.pathExtension == "jsonl"
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
                      !objects.compactMap(Self.message(from:)).isEmpty
                else {
                    return .failure(failure)
                }
            }

            var sessionId = ""
            var cwd = ""
            var startTime = ""
            var endTime = ""
            var userCount = 0
            var assistantCount = 0
            var systemCount = 0
            var firstUserText = ""
            var detectedModel: String?

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
                if startTime.isEmpty, let value = JSONLAdapterSupport.string(object["timestamp"]) {
                    startTime = value
                }
                if let value = JSONLAdapterSupport.string(object["timestamp"]) {
                    endTime = value
                }

                let message = JSONLAdapterSupport.object(object["message"])
                if detectedModel == nil, let value = JSONLAdapterSupport.string(message?["model"]) {
                    detectedModel = value
                }

                guard !Self.isIgnoredUserSidecar(object) else { continue }

                if type == "assistant" {
                    assistantCount += 1
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
            // R184-3: injection-only / empty Iflow files must not become
            // zero-count browsable sessions. Terminal, same as Qwen.
            guard userCount + assistantCount > 0 else {
                return .failure(.noVisibleMessages)
            }

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .iflow,
                    startTime: startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: cwd,
                    project: nil,
                    model: detectedModel,
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
        if options.limit == nil {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: Self.countsTowardMessageLimit,
                beforeIdentityValidation: testHooks.beforeFinalIdentityValidation
            )
            let messages = objects.compactMap(Self.message(from:))
            if let failure, messages.isEmpty { throw failure }
            return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
        }
        let messages = try JSONLAdapterSupport.windowedMessages(
            locator: locator,
            options: options,
            limits: limits,
            countsTowardMessageLimit: { $0.role != .system },
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
            countsTowardMessageLimit: { $0.role != .system },
            transform: Self.message(from:)
        )
        return JSONLAdapterSupport.stream(result)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user" || type == "assistant",
              !isIgnoredUserSidecar(object)
        else {
            return nil
        }
        let message = JSONLAdapterSupport.object(object["message"])
        let content = extractContent(message?["content"])
        let role: NormalizedMessageRole = type == "assistant"
            ? .assistant
            : (isSystemInjection(content) ? .system : .user)
        return NormalizedMessage(
            role: role,
            content: content,
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: nil,
            usage: type == "assistant" ? usage(from: JSONLAdapterSupport.object(message?["usage"])) : nil
        )
    }

    private static func countsTowardMessageLimit(_ object: JSONLAdapterSupport.JSONObject) -> Bool {
        guard let message = message(from: object) else { return false }
        return message.role != .system
    }

    private static func isIgnoredUserSidecar(_ object: JSONLAdapterSupport.JSONObject) -> Bool {
        guard JSONLAdapterSupport.string(object["type"]) == "user" else { return false }
        if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true {
            return true
        }
        let message = JSONLAdapterSupport.object(object["message"])
        guard let content = JSONLAdapterSupport.array(message?["content"]) else { return false }
        return content.contains { item in
            JSONLAdapterSupport.string(JSONLAdapterSupport.object(item)?["type"]) == "tool_result"
        }
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        SystemMessageClassifier.classify(content: text, source: "iflow") != .none
    }

    private static func extractContent(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let content = JSONLAdapterSupport.array(content) else { return "" }
        var parts: [String] = []
        for item in content {
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "text",
                  let text = JSONLAdapterSupport.string(object["text"])
            else {
                continue
            }
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func usage(from usage: JSONLAdapterSupport.JSONObject?) -> TokenUsage? {
        guard let usage else { return nil }
        let tokenUsage = TokenUsage(
            inputTokens: int(usage["input_tokens"]),
            outputTokens: int(usage["output_tokens"])
        )
        guard tokenUsage.inputTokens > 0 || tokenUsage.outputTokens > 0 else {
            return nil
        }
        return tokenUsage
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }
}
