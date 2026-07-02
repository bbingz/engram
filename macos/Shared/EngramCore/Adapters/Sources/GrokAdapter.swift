import Foundation

final class GrokAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
    let source: SourceName = .grok

    private let sessionsRoot: URL
    private let limits: ParserLimits

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions", isDirectory: true)
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionsRoot = URL(fileURLWithPath: sessionsRoot, isDirectory: true)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(sessionsRoot)
    }

    func listSessionLocators() async throws -> [String] {
        sessionTranscriptLocators(under: sessionsRoot)
    }

    func listSessionLocators(modifiedSince: Date, fileManager: FileManager) async throws -> [String] {
        try sessionTranscriptLocators(under: sessionsRoot).filter { locator in
            guard let modifiedAt = try fileManager.attributesOfItem(atPath: locator)[.modificationDate] as? Date else {
                return false
            }
            return modifiedAt >= modifiedSince
        }
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let sessionDir = Self.sessionDirectory(for: locator)
            let transcript = Self.primaryTranscriptURL(in: sessionDir, locator: locator)
            let summary = Self.readJSONObject(sessionDir.appendingPathComponent("summary.json"))
            let promptContext = Self.readJSONObject(sessionDir.appendingPathComponent("prompt_context.json"))
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: transcript.path,
                limits: limits,
                reportFailures: true
            )
            if let failure { return .failure(failure) }

            let messages = Self.messages(from: objects)
            let systemCount = Self.systemMessageCount(from: objects)
            let counts = Self.counts(for: messages)
            let info = JSONLAdapterSupport.object(summary?["info"])
            let id = JSONLAdapterSupport.string(info?["id"]) ?? sessionDir.lastPathComponent
            guard !id.isEmpty else { return .failure(.malformedJSON) }

            let fileModifiedAt = Self.fileModifiedAt(transcript) ?? Self.fileModifiedAt(sessionDir)
            let startTime = JSONLAdapterSupport.string(summary?["created_at"])
                ?? Self.firstTimestamp(in: objects)
                ?? fileModifiedAt
                ?? ""
            let endTime = JSONLAdapterSupport.string(summary?["updated_at"])
                ?? Self.lastTimestamp(in: objects)
            let cwd = JSONLAdapterSupport.string(info?["cwd"])
                ?? JSONLAdapterSupport.string(promptContext?["working_directory"])
                ?? Self.decodedProjectDirectory(for: sessionDir)
                ?? ""
            let firstUserText = messages.first { $0.role == .user }?.content
            let summaryText = firstUserText
                ?? JSONLAdapterSupport.string(summary?["session_summary"])
                ?? JSONLAdapterSupport.string(summary?["generated_title"])
            let model = JSONLAdapterSupport.string(summary?["current_model_id"])
                ?? Self.firstModel(in: objects)

            return .success(
                NormalizedSessionInfo(
                    id: id,
                    source: .grok,
                    startTime: startTime,
                    endTime: endTime,
                    cwd: cwd,
                    project: nil,
                    model: model,
                    messageCount: counts.user + counts.assistant + counts.tool,
                    userMessageCount: counts.user,
                    assistantMessageCount: counts.assistant,
                    toolMessageCount: counts.tool,
                    systemMessageCount: systemCount,
                    summary: summaryText.map { String($0.prefix(200)) },
                    filePath: transcript.path,
                    sizeBytes: JSONLAdapterSupport.fileSize(locator: transcript.path)
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
        let transcript = Self.primaryTranscriptURL(in: Self.sessionDirectory(for: locator), locator: locator)
        let messages = try JSONLAdapterSupport.windowedMessages(
            locator: transcript.path,
            options: options,
            limits: limits,
            transform: Self.message(from:)
        )
        return JSONLAdapterSupport.stream(messages)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private func sessionTranscriptLocators(under root: URL) -> [String] {
        JSONLAdapterSupport.directChildren(of: root, includingHidden: true)
            .flatMap { projectDir in
                JSONLAdapterSupport.directChildren(of: projectDir, includingHidden: true)
            }
            .compactMap(Self.preferredLocator(in:))
            .sorted()
    }

    private static func preferredLocator(in sessionDir: URL) -> String? {
        guard JSONLAdapterSupport.isDirectory(sessionDir) else { return nil }
        for name in ["chat_history.jsonl", "updates.jsonl", "summary.json"] {
            let candidate = sessionDir.appendingPathComponent(name)
            if JSONLAdapterSupport.fileExists(candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private static func sessionDirectory(for locator: String) -> URL {
        let url = URL(fileURLWithPath: locator)
        if JSONLAdapterSupport.isDirectory(url) {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private static func primaryTranscriptURL(in sessionDir: URL, locator: String) -> URL {
        let locatorURL = URL(fileURLWithPath: locator)
        if ["chat_history.jsonl", "updates.jsonl"].contains(locatorURL.lastPathComponent) {
            return locatorURL
        }
        for name in ["chat_history.jsonl", "updates.jsonl"] {
            let candidate = sessionDir.appendingPathComponent(name)
            if JSONLAdapterSupport.fileExists(candidate.path) {
                return candidate
            }
        }
        return locatorURL
    }

    private static func readJSONObject(_ url: URL) -> JSONLAdapterSupport.JSONObject? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSONLAdapterSupport.JSONObject
        else {
            return nil
        }
        return object
    }

    private static func messages(from objects: [JSONLAdapterSupport.JSONObject]) -> [NormalizedMessage] {
        objects.compactMap(message(from:))
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        let type = JSONLAdapterSupport.string(object["type"])
        let timestamp = JSONLAdapterSupport.string(object["timestamp"])
            ?? JSONLAdapterSupport.string(object["created_at"])
            ?? JSONLAdapterSupport.string(object["createdAt"])

        switch type {
        case "user":
            let rawText = extractContent(object["content"])
            guard let userText = normalizeUserText(rawText) else { return nil }
            return NormalizedMessage(role: .user, content: userText, timestamp: timestamp)
        case "assistant":
            let content = extractContent(object["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCalls = toolCalls(from: object["tool_calls"])
            guard !content.isEmpty || !toolCalls.isEmpty else { return nil }
            return NormalizedMessage(
                role: .assistant,
                content: content,
                timestamp: timestamp,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                usage: JSONLAdapterSupport.usage(from: JSONLAdapterSupport.object(object["usage"]))
            )
        case "tool_result":
            let content = extractContent(object["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return NormalizedMessage(role: .tool, content: content, timestamp: timestamp)
        default:
            return nil
        }
    }

    private static func counts(for messages: [NormalizedMessage]) -> (user: Int, assistant: Int, tool: Int) {
        var user = 0
        var assistant = 0
        var tool = 0
        for message in messages {
            switch message.role {
            case .user: user += 1
            case .assistant: assistant += 1
            case .tool: tool += 1
            case .system: break
            }
        }
        return (user, assistant, tool)
    }

    private static func systemMessageCount(from objects: [JSONLAdapterSupport.JSONObject]) -> Int {
        var count = 0
        for object in objects {
            switch JSONLAdapterSupport.string(object["type"]) {
            case "system":
                count += 1
            case "user":
                if isSystemInjection(extractContent(object["content"])) {
                    count += 1
                }
            default:
                continue
            }
        }
        return count
    }

    private static func normalizeUserText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSystemInjection(trimmed) else { return nil }
        guard trimmed.hasPrefix("<user_query>") else { return trimmed }
        let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: "<user_query>".count)
        let body = String(trimmed[bodyStart...])
        if let close = body.range(of: "</user_query>", options: .backwards) {
            return String(body[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<user_info>")
            || trimmed.hasPrefix("<system-reminder>")
            || trimmed.hasPrefix("<codex_internal_context")
            || trimmed.hasPrefix("# AGENTS.md instructions for ")
            || trimmed.hasPrefix("<INSTRUCTIONS>")
            || trimmed.hasPrefix("<environment_context>")
    }

    private static func extractContent(_ value: Any?) -> String {
        if let string = JSONLAdapterSupport.string(value) {
            return string
        }
        if let object = JSONLAdapterSupport.object(value) {
            return extractText(from: object)
                ?? JSONLAdapterSupport.jsonString(object, limit: 2_000)
                ?? ""
        }
        guard let array = JSONLAdapterSupport.array(value) else { return "" }
        var parts: [String] = []
        for item in array {
            if let string = JSONLAdapterSupport.string(item), !string.isEmpty {
                parts.append(string)
            } else if let object = JSONLAdapterSupport.object(item),
                      let text = extractText(from: object),
                      !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func extractText(from object: JSONLAdapterSupport.JSONObject) -> String? {
        for key in ["text", "input_text", "output_text", "content", "message"] {
            if let text = JSONLAdapterSupport.string(object[key]), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func toolCalls(from value: Any?) -> [NormalizedToolCall] {
        guard let rawCalls = JSONLAdapterSupport.array(value) else { return [] }
        return rawCalls.compactMap { raw in
            guard let object = JSONLAdapterSupport.object(raw) else { return nil }
            let function = JSONLAdapterSupport.object(object["function"])
            guard let name = JSONLAdapterSupport.string(object["name"])
                    ?? JSONLAdapterSupport.string(function?["name"])
            else {
                return nil
            }
            let input = stringOrJSONString(object["arguments"])
                ?? stringOrJSONString(function?["arguments"])
                ?? stringOrJSONString(object["rawInput"])
                ?? stringOrJSONString(object["input"])
                ?? stringOrJSONString(object["args"])
            return NormalizedToolCall(name: name, input: input)
        }
    }

    private static func stringOrJSONString(_ value: Any?) -> String? {
        if let string = JSONLAdapterSupport.string(value) {
            return string.isEmpty ? nil : String(string.prefix(500))
        }
        guard let value else { return nil }
        return JSONLAdapterSupport.jsonString(value, limit: 500)
    }

    private static func firstTimestamp(in objects: [JSONLAdapterSupport.JSONObject]) -> String? {
        objects.lazy.compactMap { object in
            JSONLAdapterSupport.string(object["timestamp"])
                ?? JSONLAdapterSupport.string(object["created_at"])
                ?? JSONLAdapterSupport.string(object["createdAt"])
        }.first
    }

    private static func lastTimestamp(in objects: [JSONLAdapterSupport.JSONObject]) -> String? {
        objects.reversed().lazy.compactMap { object in
            JSONLAdapterSupport.string(object["timestamp"])
                ?? JSONLAdapterSupport.string(object["created_at"])
                ?? JSONLAdapterSupport.string(object["createdAt"])
        }.first
    }

    private static func firstModel(in objects: [JSONLAdapterSupport.JSONObject]) -> String? {
        objects.lazy.compactMap { object in
            JSONLAdapterSupport.string(object["model_id"])
                ?? JSONLAdapterSupport.string(object["model"])
        }.first
    }

    private static func decodedProjectDirectory(for sessionDir: URL) -> String? {
        let encoded = sessionDir.deletingLastPathComponent().lastPathComponent
        return encoded.removingPercentEncoding
    }

    private static func fileModifiedAt(_ url: URL) -> String? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date else {
            return nil
        }
        return ISO8601DateFormatter().string(from: date)
    }
}
