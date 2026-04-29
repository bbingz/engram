import Foundation

final class IflowAdapter: SessionAdapter {
    let source: SourceName = .iflow
    private let projectsRoot: URL
    private let limits: ParserLimits

    init(
        projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iflow/projects")
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
                where fileURL.lastPathComponent.hasPrefix("session-") && fileURL.pathExtension == "jsonl"
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

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .iflow,
                    startTime: startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: cwd,
                    project: nil,
                    model: nil,
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
        let messages = objects.compactMap(Self.message(from:))
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
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
        return NormalizedMessage(
            role: type == "user" ? .user : .assistant,
            content: extractContent(message?["content"]),
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: nil,
            usage: nil
        )
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        text.hasPrefix("# AGENTS.md instructions for ") ||
            text.contains("<INSTRUCTIONS>") ||
            text.hasPrefix("<local-command-caveat>")
    }

    private static func extractContent(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let content = JSONLAdapterSupport.array(content) else { return "" }
        for item in content {
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "text",
                  let text = JSONLAdapterSupport.string(object["text"])
            else {
                continue
            }
            return text
        }
        return ""
    }
}
