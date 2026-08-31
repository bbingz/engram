import Foundation

final class QoderAdapter: SessionAdapter, Sendable {
    let source: SourceName = .qoder
    private let projectsRoot: URL
    private let limits: ParserLimits
    private let testHooks: JSONLIdentityTestHooks

    init(
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder/projects")
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
            for entryURL in JSONLAdapterSupport.directChildren(of: projectURL) {
                if entryURL.pathExtension == "jsonl" {
                    locators.append(entryURL.path)
                    continue
                }
                locators.append(contentsOf: subagentLocators(in: entryURL))
            }
            locators.append(contentsOf: subagentLocators(in: projectURL))
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: {
                    guard let message = Self.message(from: $0) else { return false }
                    return message.role != .system
                },
                beforeIdentityValidation: testHooks.beforeFinalIdentityValidation
            )
            if let failure,
               failure != .fileModifiedDuringParse || objects.compactMap(Self.message(from:)).isEmpty {
                return .failure(failure)
            }

            var sessionId = ""
            var agentId = ""
            var cwd = ""
            var startTime = ""
            var endTime = ""
            var model: String?
            var userCount = 0
            var assistantCount = 0
            var toolCount = 0
            var systemCount = 0
            var firstUserText = ""

            for object in objects {
                guard let type = JSONLAdapterSupport.string(object["type"]),
                      type == "user" || type == "assistant"
                else { continue }

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
                if model == nil, let value = JSONLAdapterSupport.string(message?["model"]) {
                    model = value
                }

                if type == "assistant" {
                    assistantCount += 1
                } else if Self.isToolResult(message?["content"]) {
                    toolCount += 1
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
            // R184-3: injection-only / empty Qoder files must not become
            // zero-count browsable sessions. Terminal, same as Qwen.
            guard userCount + assistantCount + toolCount > 0 else {
                return .failure(.noVisibleMessages)
            }
            let subagent = subagentLayout(locator: locator, parentSessionId: sessionId)
            // R1.P1.identity-key-collision: match ClaudeCode — never reuse parent
            // sessionId when agentId is missing on a subagent transcript.
            let id: String
            if let subagent {
                if !agentId.isEmpty {
                    id = agentId
                } else {
                    id = "sub:\(sessionId):\(subagent.relativePath)"
                }
            } else {
                id = sessionId
            }

            return .success(
                NormalizedSessionInfo(
                    id: id,
                    source: .qoder,
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
                    summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                    filePath: locator,
                    sizeBytes: JSONLAdapterSupport.fileSize(locator: locator),
                    indexedAt: nil,
                    agentRole: subagent == nil ? nil : "subagent",
                    originator: nil,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: subagent?.parentSessionId,
                    suggestedParentId: nil
                )
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        do {
            let url = URL(fileURLWithPath: locator)
            let before = try limits.fileIdentity(for: url)
            let info: NormalizedSessionInfo
            switch try await parseSessionInfo(locator: locator) {
            case .success(let value): info = value
            case .failure(let failure): return .failure(failure)
            }
            let result = try await streamMessagesWithMetadata(
                locator: locator,
                options: StreamMessagesOptions()
            )
            if result.truncatedAt != nil { return .failure(.messageLimitExceeded) }
            var messages: [NormalizedMessage] = []
            for try await message in result.messages { messages.append(message) }
            let after = try limits.fileIdentity(for: url)
            let identityFailure: ParserFailure? = limits.isSameFileIdentity(before, after)
                ? nil
                : .fileModifiedDuringParse
            if let failure = result.parseFailure ?? identityFailure {
                guard failure == .fileModifiedDuringParse, !messages.isEmpty else {
                    return .failure(failure)
                }
                return .success(IndexingScan(info: info, messages: messages, parseFailure: failure))
            }
            guard result.totalKnownComplete else { return .failure(.messageLimitExceeded) }
            return .success(IndexingScan(info: info, messages: messages))
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
                countsTowardMessageLimit: {
                    guard let message = Self.message(from: $0) else { return false }
                    return message.role != .system
                }
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

    private func subagentLayout(
        locator: String,
        parentSessionId: String
    ) -> SubagentTranscriptLayout? {
        SubagentTranscriptPath.layout(
            locator: locator,
            projectsRoot: projectsRoot.path,
            projectLevelParentSessionId: parentSessionId
        )
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user" || type == "assistant",
              let message = JSONLAdapterSupport.object(object["message"])
        else { return nil }
        let content = message["content"]
        let text = extractContent(content)
        let role: NormalizedMessageRole
        if type == "assistant" {
            role = .assistant
        } else if isToolResult(content) {
            role = .tool
        } else if isSystemInjection(text) {
            role = .system
        } else {
            role = .user
        }
        return NormalizedMessage(
            role: role,
            content: text,
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: nonEmptyToolCalls(from: content),
            usage: JSONLAdapterSupport.usage(from: JSONLAdapterSupport.object(message["usage"]))
        )
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        SystemMessageClassifier.classify(content: text, source: "qoder") != .none
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
            else { continue }
            if type == "text", let text = JSONLAdapterSupport.string(object["text"]), !text.isEmpty {
                parts.append(text)
            } else if type == "thinking", thinkingFallback.isEmpty,
                      let thinking = JSONLAdapterSupport.string(object["thinking"]) {
                thinkingFallback = thinking
            } else if type == "tool_use", let name = JSONLAdapterSupport.string(object["name"]) {
                parts.append("`\(name)`")
            } else if type == "tool_result" {
                if let content = JSONLAdapterSupport.string(object["content"]), !content.isEmpty {
                    parts.append(content)
                } else if let output = object["output"].flatMap({ JSONLAdapterSupport.jsonString($0, limit: 2_000) }), !output.isEmpty {
                    parts.append(output)
                }
            }
        }
        if !parts.isEmpty { return parts.joined(separator: "\n\n") }
        return thinkingFallback
    }

    private static func toolCalls(from content: Any?) -> [NormalizedToolCall] {
        guard let content = JSONLAdapterSupport.array(content) else { return [] }
        return content.compactMap { item in
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "tool_use",
                  let name = JSONLAdapterSupport.string(object["name"])
            else { return nil }
            return NormalizedToolCall(
                name: name,
                input: object["input"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) },
                output: nil
            )
        }
    }

    private static func nonEmptyToolCalls(from content: Any?) -> [NormalizedToolCall]? {
        let calls = toolCalls(from: content)
        return calls.isEmpty ? nil : calls
    }

    private func subagentLocators(in url: URL) -> [String] {
        let subagentsURL = url.appendingPathComponent("subagents")
        guard JSONLAdapterSupport.isDirectory(subagentsURL) else { return [] }
        return JSONLAdapterSupport.directChildren(of: subagentsURL)
            .filter { $0.pathExtension == "jsonl" }
            .map(\.path)
    }
}
