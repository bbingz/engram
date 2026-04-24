import Foundation

final class CopilotAdapter: SessionAdapter {
    let source: SourceName = .copilot
    private let sessionRoot: URL
    private let limits: ParserLimits

    init(
        sessionRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state")
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionRoot = URL(fileURLWithPath: sessionRoot)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(sessionRoot)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for sessionURL in JSONLAdapterSupport.directChildren(of: sessionRoot)
            where JSONLAdapterSupport.isDirectory(sessionURL)
        {
            let eventsURL = sessionURL.appendingPathComponent("events.jsonl")
            if JSONLAdapterSupport.fileExists(eventsURL.path) {
                locators.append(eventsURL.path)
            }
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { return .failure(failure) }

            let sessionDirectory = URL(fileURLWithPath: locator).deletingLastPathComponent()
            let workspace = Self.readWorkspace(sessionDirectory.appendingPathComponent("workspace.yaml"))
            let sessionId = workspace["id"] ?? sessionDirectory.lastPathComponent
            var startTime = workspace["created_at"] ?? ""
            var endTime = workspace["updated_at"] ?? ""
            var cwd = workspace["cwd"] ?? ""
            var userCount = 0
            var assistantCount = 0
            var firstUserText = ""

            for object in objects {
                guard let type = JSONLAdapterSupport.string(object["type"]) else { continue }
                let data = JSONLAdapterSupport.object(object["data"])
                let timestamp = JSONLAdapterSupport.string(object["timestamp"])

                if type == "session.start" {
                    let context = JSONLAdapterSupport.object(data?["context"])
                    if startTime.isEmpty, let value = JSONLAdapterSupport.string(data?["startTime"]) {
                        startTime = value
                    }
                    if cwd.isEmpty, let value = JSONLAdapterSupport.string(context?["cwd"]) {
                        cwd = value
                    }
                } else if type == "user.message" {
                    userCount += 1
                    if firstUserText.isEmpty, let content = JSONLAdapterSupport.string(data?["content"]) {
                        firstUserText = String(content.prefix(200))
                    }
                    if let timestamp {
                        if startTime.isEmpty || timestamp < startTime { startTime = timestamp }
                        if timestamp > endTime { endTime = timestamp }
                    }
                } else if type == "assistant.message" {
                    assistantCount += 1
                    if let timestamp, timestamp > endTime {
                        endTime = timestamp
                    }
                }
            }

            guard !sessionId.isEmpty, userCount + assistantCount > 0 else {
                return .failure(.malformedJSON)
            }

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .copilot,
                    startTime: startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: cwd,
                    project: nil,
                    model: nil,
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: workspace["summary"] ?? (firstUserText.isEmpty ? nil : firstUserText),
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
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user.message" || type == "assistant.message"
        else {
            return nil
        }
        let data = JSONLAdapterSupport.object(object["data"])
        return NormalizedMessage(
            role: type == "user.message" ? .user : .assistant,
            content: JSONLAdapterSupport.string(data?["content"]) ?? "",
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: nil,
            usage: nil
        )
    }

    private static func readWorkspace(_ url: URL) -> [String: String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var result: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separatorIndex])
            guard key.range(of: #"^\w+$"#, options: .regularExpression) != nil else { continue }
            let valueStart = line.index(after: separatorIndex)
            result[key] = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
