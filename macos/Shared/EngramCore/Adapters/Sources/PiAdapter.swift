import Foundation

final class PiAdapter: SessionAdapter {
    let source: SourceName = .pi
    private let sessionsRoot: URL
    private let limits: ParserLimits

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions")
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionsRoot = URL(fileURLWithPath: sessionsRoot)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(sessionsRoot)
    }

    func listSessionLocators() async throws -> [String] {
        JSONLAdapterSupport.recursiveFiles(under: sessionsRoot) { $0.pathExtension == "jsonl" }
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
            var toolCount = 0
            var systemCount = 0
            var firstUserText = ""

            for object in objects {
                if let timestamp = JSONLAdapterSupport.string(object["timestamp"]) {
                    if startTime.isEmpty { startTime = timestamp }
                    endTime = timestamp
                }

                guard let type = JSONLAdapterSupport.string(object["type"]) else { continue }
                if type == "session" {
                    sessionId = JSONLAdapterSupport.string(object["id"]) ?? sessionId
                    cwd = JSONLAdapterSupport.string(object["cwd"]) ?? cwd
                    startTime = JSONLAdapterSupport.string(object["timestamp"]) ?? startTime
                    continue
                }
                if type == "model_change" {
                    model = JSONLAdapterSupport.string(object["modelId"]) ?? model
                    continue
                }
                guard type == "message",
                      let message = JSONLAdapterSupport.object(object["message"]),
                      let role = JSONLAdapterSupport.string(message["role"])
                else {
                    continue
                }

                if model == nil, let value = JSONLAdapterSupport.string(message["model"]) {
                    model = value
                }

                switch role {
                case "user":
                    let text = Self.extractText(message["content"])
                    if Self.isSystemInjection(text) {
                        systemCount += 1
                    } else {
                        userCount += 1
                        if firstUserText.isEmpty { firstUserText = text }
                    }
                case "assistant":
                    assistantCount += 1
                case "toolResult":
                    toolCount += 1
                case "system":
                    systemCount += 1
                default:
                    continue
                }
            }

            if sessionId.isEmpty { sessionId = Self.idFromFileName(locator) }
            guard !sessionId.isEmpty, !startTime.isEmpty else { return .failure(.malformedJSON) }

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .pi,
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
        guard JSONLAdapterSupport.string(object["type"]) == "message",
              let message = JSONLAdapterSupport.object(object["message"]),
              let rawRole = JSONLAdapterSupport.string(message["role"])
        else {
            return nil
        }

        let content = extractText(message["content"])
        let timestamp = JSONLAdapterSupport.string(object["timestamp"])
        switch rawRole {
        case "user":
            return NormalizedMessage(
                role: isSystemInjection(content) ? .system : .user,
                content: content,
                timestamp: timestamp
            )
        case "assistant":
            return NormalizedMessage(
                role: .assistant,
                content: content,
                timestamp: timestamp,
                toolCalls: extractToolCalls(message["content"]),
                usage: usage(from: JSONLAdapterSupport.object(message["usage"]))
            )
        case "toolResult":
            return NormalizedMessage(role: .tool, content: content, timestamp: timestamp)
        case "system":
            return NormalizedMessage(role: .system, content: content, timestamp: timestamp)
        default:
            return nil
        }
    }

    private static func idFromFileName(_ locator: String) -> String {
        let name = URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent
        guard let idx = name.firstIndex(of: "_") else { return name }
        return String(name[name.index(after: idx)...])
    }

    private static func extractText(_ value: Any?) -> String {
        guard let parts = JSONLAdapterSupport.array(value) else { return "" }
        return parts.compactMap { part -> String? in
            guard let object = JSONLAdapterSupport.object(part),
                  JSONLAdapterSupport.string(object["type"]) == "text"
            else {
                return nil
            }
            return JSONLAdapterSupport.string(object["text"])
        }.joined(separator: "\n")
    }

    private static func extractToolCalls(_ value: Any?) -> [NormalizedToolCall]? {
        guard let parts = JSONLAdapterSupport.array(value) else { return nil }
        let calls = parts.compactMap { part -> NormalizedToolCall? in
            guard let object = JSONLAdapterSupport.object(part),
                  JSONLAdapterSupport.string(object["type"]) == "toolCall",
                  let name = JSONLAdapterSupport.string(object["name"])
            else {
                return nil
            }
            let input = object["arguments"].flatMap { JSONLAdapterSupport.jsonString($0) }
            return NormalizedToolCall(name: name, input: input, output: nil)
        }
        return calls.isEmpty ? nil : calls
    }

    private static func usage(from rawUsage: JSONLAdapterSupport.JSONObject?) -> TokenUsage? {
        guard let rawUsage else { return nil }
        return TokenUsage(
            inputTokens: rawUsage["input"] as? Int ?? 0,
            outputTokens: rawUsage["output"] as? Int ?? 0,
            cacheReadTokens: rawUsage["cacheRead"] as? Int,
            cacheCreationTokens: rawUsage["cacheWrite"] as? Int
        )
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        text.hasPrefix("# AGENTS.md instructions for ") ||
            text.contains("<INSTRUCTIONS>") ||
            text.hasPrefix("<local-command-caveat>") ||
            text.hasPrefix("<environment_context>")
    }
}
