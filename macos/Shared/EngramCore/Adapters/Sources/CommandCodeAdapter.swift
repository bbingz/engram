import Foundation

final class CommandCodeAdapter: SessionAdapter {
    let source: SourceName = .commandcode
    private let projectsRoot: URL
    private let limits: ParserLimits

    init(
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".commandcode/projects")
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
            for fileURL in JSONLAdapterSupport.directChildren(of: projectURL)
                where fileURL.pathExtension == "jsonl" && !fileURL.lastPathComponent.hasSuffix(".checkpoints.jsonl")
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
            var startTime = ""
            var endTime = ""
            var userCount = 0
            var assistantCount = 0
            var toolCount = 0
            var systemCount = 0
            var firstUserText = ""
            var cwd = ""
            var model: String?

            for object in objects {
                guard let role = JSONLAdapterSupport.string(object["role"]),
                      role == "user" || role == "assistant" || role == "tool"
                else { continue }
                if sessionId.isEmpty, let value = JSONLAdapterSupport.string(object["sessionId"]) {
                    sessionId = value
                }
                if cwd.isEmpty, let value = JSONLAdapterSupport.string(object["cwd"]) {
                    cwd = value
                }
                if model == nil, let value = JSONLAdapterSupport.string(object["model"]) {
                    model = value
                }
                if model == nil, let value = JSONLAdapterSupport.string(JSONLAdapterSupport.object(object["metadata"])?["model"]) {
                    model = value
                }
                let timestamp = Self.timestamp(from: object)
                if startTime.isEmpty, let timestamp { startTime = timestamp }
                if let timestamp { endTime = timestamp }

                switch role {
                case "user":
                    let text = Self.extractContent(object["content"])
                    // Classify Claude-style injected wrappers as system messages
                    // (parity with the TS commandcode adapter); otherwise they
                    // inflate the user message count and pollute the summary.
                    if Self.isSystemInjection(text) {
                        systemCount += 1
                    } else {
                        userCount += 1
                        if firstUserText.isEmpty { firstUserText = text }
                    }
                case "assistant":
                    assistantCount += 1
                case "tool":
                    toolCount += 1
                default:
                    break
                }
            }

            guard !sessionId.isEmpty else { return .failure(.malformedJSON) }
            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .commandcode,
                    startTime: startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: cwd.isEmpty ? Self.decodeCwd(from: locator) : cwd,
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
        let messages = objects.compactMap(Self.message(from:))
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let roleString = JSONLAdapterSupport.string(object["role"]),
              let role = NormalizedMessageRole(rawValue: roleString)
        else { return nil }
        return NormalizedMessage(
            role: role,
            content: extractContent(object["content"]),
            timestamp: timestamp(from: object),
            toolCalls: nonEmptyToolCalls(from: object["content"]),
            usage: nil
        )
    }

    private static func timestamp(from object: JSONLAdapterSupport.JSONObject) -> String? {
        if let timestamp = JSONLAdapterSupport.string(object["timestamp"]) {
            return timestamp
        }
        return JSONLAdapterSupport.string(JSONLAdapterSupport.object(object["metadata"])?["timestamp"])
    }

    /// Detect Claude-style system wrappers injected into user-role messages.
    /// Mirrors the TS commandcode adapter so parity fixtures agree.
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

    private static func extractContent(_ content: Any?) -> String {
        guard let content = JSONLAdapterSupport.array(content) else {
            return JSONLAdapterSupport.string(content) ?? ""
        }
        let parts = content.compactMap { item -> String? in
            guard let object = JSONLAdapterSupport.object(item),
                  let type = JSONLAdapterSupport.string(object["type"])
            else { return nil }
            switch type {
            case "text":
                return JSONLAdapterSupport.string(object["text"])
            case "tool-call":
                guard let name = JSONLAdapterSupport.string(object["toolName"]) else { return nil }
                return "`\(name)`"
            case "tool-result":
                if let output = JSONLAdapterSupport.string(object["output"]) {
                    return output
                }
                return object["output"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 2_000) }
            default:
                return nil
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func toolCalls(from content: Any?) -> [NormalizedToolCall] {
        guard let content = JSONLAdapterSupport.array(content) else { return [] }
        return content.compactMap { item in
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "tool-call",
                  let name = JSONLAdapterSupport.string(object["toolName"])
            else { return nil }
            return NormalizedToolCall(
                name: name,
                input: (object["input"] ?? object["args"]).flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) },
                output: nil
            )
        }
    }

    private static func nonEmptyToolCalls(from content: Any?) -> [NormalizedToolCall]? {
        let calls = toolCalls(from: content)
        return calls.isEmpty ? nil : calls
    }

    private static func decodeCwd(from locator: String) -> String {
        let encoded = URL(fileURLWithPath: locator).deletingLastPathComponent().lastPathComponent
        guard encoded.contains("-") else { return "" }
        return encoded
            .replacingOccurrences(of: "--", with: "\u{0}")
            .replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "\u{0}", with: "-")
    }
}
