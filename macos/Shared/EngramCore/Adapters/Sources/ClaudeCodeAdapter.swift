import Foundation

final class ClaudeCodeAdapter: SessionAdapter {
    let source: SourceName = .claudeCode
    private let projectsRoot: URL
    private let limits: ParserLimits

    init(
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
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
            for entryURL in JSONLAdapterSupport.directChildren(of: projectURL) {
                if entryURL.pathExtension == "jsonl" {
                    locators.append(entryURL.path)
                    continue
                }

                let subagentsURL = entryURL.appendingPathComponent("subagents")
                guard JSONLAdapterSupport.isDirectory(subagentsURL) else { continue }
                for subagentURL in JSONLAdapterSupport.directChildren(of: subagentsURL)
                    where subagentURL.pathExtension == "jsonl"
                {
                    locators.append(subagentURL.path)
                }
            }
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { return .failure(failure) }

            var sessionId = ""
            var agentId = ""
            var cwd = ""
            var startTime = ""
            var endTime = ""
            var userCount = 0
            var assistantCount = 0
            var toolCount = 0
            var systemCount = 0
            var firstUserText = ""
            var detectedModel = ""

            for object in objects {
                guard let type = JSONLAdapterSupport.string(object["type"]),
                      type == "user" || type == "assistant"
                else {
                    continue
                }

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
                if detectedModel.isEmpty, let value = JSONLAdapterSupport.string(message?["model"]) {
                    detectedModel = value
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

            let isSubagent = locator.contains("/subagents/")
            let id = isSubagent && !agentId.isEmpty ? agentId : sessionId
            let source = Self.detectSource(model: detectedModel, filePath: locator)
            let parentSessionId = isSubagent ? Self.parentSessionId(from: locator) : nil

            return .success(
                NormalizedSessionInfo(
                    id: id,
                    source: source,
                    startTime: startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: cwd,
                    project: nil,
                    model: detectedModel.isEmpty ? nil : detectedModel,
                    messageCount: userCount + assistantCount + toolCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: toolCount,
                    systemMessageCount: systemCount,
                    summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                    filePath: locator,
                    sizeBytes: JSONLAdapterSupport.fileSize(locator: locator),
                    indexedAt: nil,
                    agentRole: isSubagent ? "subagent" : nil,
                    originator: nil,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: parentSessionId,
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

    static func detectSource(model: String, filePath: String? = nil) -> SourceName {
        if filePath?.contains("lobsterai") == true { return .lobsterai }
        if model.isEmpty || model.hasPrefix("claude") || model.hasPrefix("<") {
            return .claudeCode
        }

        let lowercased = model.lowercased()
        if lowercased.contains("minimax") { return .minimax }
        // Qwen/Kimi/Gemini models can be routed through Claude-compatible clients,
        // but the session file is still owned by Claude Code's on-disk format.
        return .claudeCode
    }

    static func decodeCwd(_ encoded: String) -> String {
        encoded
            .replacingOccurrences(of: "--", with: "\u{0}")
            .replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "\u{0}", with: "-")
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user" || type == "assistant"
        else {
            return nil
        }

        let message = JSONLAdapterSupport.object(object["message"])
        let rawContent = message?["content"]
        let toolCalls = toolCalls(from: rawContent)
        return NormalizedMessage(
            role: type == "user" ? .user : .assistant,
            content: extractContent(rawContent),
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            usage: JSONLAdapterSupport.usage(from: JSONLAdapterSupport.object(message?["usage"]))
        )
    }

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
            else {
                continue
            }

            if type == "text", let text = JSONLAdapterSupport.string(object["text"]) {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != "Tool loaded." {
                    parts.append(text)
                }
            } else if type == "thinking", thinkingFallback.isEmpty,
                      let thinking = JSONLAdapterSupport.string(object["thinking"]) {
                thinkingFallback = thinking
            } else if type == "tool_use" {
                let formatted = formatToolUse(object)
                if !formatted.isEmpty { parts.append(formatted) }
            } else if type == "tool_result" {
                let formatted = formatToolResult(object)
                if !formatted.isEmpty { parts.append(formatted) }
            } else if type == "image" {
                let source = JSONLAdapterSupport.object(object["source"])
                let mediaType = JSONLAdapterSupport.string(source?["media_type"]) ?? "image/unknown"
                let dataLength = JSONLAdapterSupport.string(source?["data"])?.count ?? 0
                let sizeKB = Int((Double(dataLength) * 0.75 / 1024.0).rounded())
                parts.append("[Image: \(mediaType), ~\(sizeKB) KB]")
            }
        }

        let nonEmpty = parts.filter { !$0.isEmpty }
        if !nonEmpty.isEmpty { return nonEmpty.joined(separator: "\n\n") }
        return thinkingFallback
    }

    private static let noiseTools: Set<String> = [
        "ToolSearch",
        "ExitPlanMode",
        "EnterPlanMode",
        "Skill",
        "TodoWrite",
        "TodoRead",
        "TaskCreate",
        "TaskUpdate",
        "TaskGet",
        "TaskList"
    ]

    private static func toolCalls(from content: Any?) -> [NormalizedToolCall] {
        guard let content = JSONLAdapterSupport.array(content) else { return [] }
        return content.compactMap { item in
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "tool_use",
                  let name = JSONLAdapterSupport.string(object["name"])
            else {
                return nil
            }
            let input = object["input"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) }
            return NormalizedToolCall(name: name, input: input, output: nil)
        }
    }

    private static func formatToolUse(_ object: JSONLAdapterSupport.JSONObject) -> String {
        guard let name = JSONLAdapterSupport.string(object["name"]) else { return "" }
        if noiseTools.contains(name) { return "" }
        guard let input = JSONLAdapterSupport.object(object["input"]) else { return "`\(name)`" }
        if name == "AskUserQuestion",
           let questions = JSONLAdapterSupport.array(input["questions"]) as? [JSONLAdapterSupport.JSONObject] {
            return formatAskUserQuestion(questions)
        }

        let summary = summarizeToolInput(name: name, input: input)
        return summary.isEmpty ? "`\(name)`" : "`\(name)`: \(summary)"
    }

    private static func formatAskUserQuestion(_ questions: [JSONLAdapterSupport.JSONObject]) -> String {
        questions.map { question in
            let header = JSONLAdapterSupport.string(question["header"]).map { "**\($0)**\n" } ?? ""
            let body = JSONLAdapterSupport.string(question["question"]) ?? ""
            guard let options = JSONLAdapterSupport.array(question["options"]) else {
                return header + body
            }
            let optionLines = options.enumerated().compactMap { index, item -> String? in
                guard let option = JSONLAdapterSupport.object(item),
                      let label = JSONLAdapterSupport.string(option["label"])
                else {
                    return nil
                }
                let description = JSONLAdapterSupport.string(option["description"]).map { " - \($0)" } ?? ""
                return "  \(index + 1). \(label)\(description)"
            }
            return header + body + (optionLines.isEmpty ? "" : "\n" + optionLines.joined(separator: "\n"))
        }
        .joined(separator: "\n\n")
    }

    private static func formatToolResult(_ object: JSONLAdapterSupport.JSONObject) -> String {
        let content = object["content"]
        if let string = content as? String {
            return string.hasPrefix("User has answered") ? string : ""
        }
        guard let content = JSONLAdapterSupport.array(content) else { return "" }
        let texts = content.compactMap { item -> String? in
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "text"
            else {
                return nil
            }
            return JSONLAdapterSupport.string(object["text"])
        }
        let joined = texts.joined(separator: "\n")
        return joined.hasPrefix("User has answered") ? joined : ""
    }

    private static func summarizeToolInput(name: String, input: JSONLAdapterSupport.JSONObject) -> String {
        switch name {
        case "Read", "Write", "Edit":
            return JSONLAdapterSupport.string(input["file_path"]) ?? ""
        case "Bash":
            return String((JSONLAdapterSupport.string(input["command"]) ?? "").prefix(120))
        case "Glob", "Grep":
            return JSONLAdapterSupport.string(input["pattern"]) ?? ""
        case "Agent":
            return JSONLAdapterSupport.string(input["description"]) ?? ""
        default:
            return ""
        }
    }

    private static func parentSessionId(from locator: String) -> String? {
        let parts = locator.split(separator: "/").map(String.init)
        guard let subagentsIndex = parts.firstIndex(of: "subagents"),
              subagentsIndex > 0
        else {
            return nil
        }
        return parts[subagentsIndex - 1]
    }
}

final class ClaudeCodeDerivedSourceAdapter: SessionAdapter {
    let source: SourceName
    private let base: ClaudeCodeAdapter

    init(
        source: SourceName,
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .path,
        limits: ParserLimits = .default
    ) {
        precondition(source == .minimax || source == .lobsterai)
        self.source = source
        self.base = ClaudeCodeAdapter(projectsRoot: projectsRoot, limits: limits)
    }

    func detect() async -> Bool {
        await base.detect()
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for locator in try await base.listSessionLocators() {
            switch try await base.parseSessionInfo(locator: locator) {
            case .success(let info) where info.source == source:
                locators.append(locator)
            default:
                continue
            }
        }
        return locators
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        switch try await base.parseSessionInfo(locator: locator) {
        case .success(let info) where info.source == source:
            return .success(info)
        case .success:
            return .failure(.unsupportedVirtualLocator)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        try await base.streamMessages(locator: locator, options: options)
    }

    func isAccessible(locator: String) async -> Bool {
        await base.isAccessible(locator: locator)
    }
}
