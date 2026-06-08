import Foundation

final class ClineAdapter: SessionAdapter, Sendable {
    let source: SourceName = .cline
    private let tasksRoot: URL
    private let limits: ParserLimits

    init(
        tasksRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cline/data/tasks")
            .path,
        limits: ParserLimits = .default
    ) {
        self.tasksRoot = URL(fileURLWithPath: tasksRoot)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(tasksRoot)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for taskURL in JSONLAdapterSupport.directChildren(of: tasksRoot)
            where JSONLAdapterSupport.isDirectory(taskURL)
        {
            let messagesURL = taskURL.appendingPathComponent("ui_messages.json")
            if JSONLAdapterSupport.fileExists(messagesURL.path) {
                locators.append(messagesURL.path)
            }
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let messages = try Phase4AdapterSupport.readJSONArray(locator: locator, limits: limits)
            guard let first = messages.first,
                  let firstTimestamp = Phase4AdapterSupport.double(first["ts"])
            else {
                return .failure(.malformedJSON)
            }

            let taskId = URL(fileURLWithPath: locator).deletingLastPathComponent().lastPathComponent
            let lastTimestamp = messages.compactMap { Phase4AdapterSupport.double($0["ts"]) }.last ?? firstTimestamp
            let userMessages = messages.filter { object in
                let say = JSONLAdapterSupport.string(object["say"])
                return say == "task" || say == "user_feedback"
            }
            let assistantMessages = messages.filter { object in
                JSONLAdapterSupport.string(object["say"]) == "text" && !(object["partial"] as? Bool ?? false)
            }
            let summary = JSONLAdapterSupport.string(
                messages.first { JSONLAdapterSupport.string($0["say"]) == "task" }?["text"]
            )
            let model = messages.compactMap { message -> String? in
                let modelInfo = JSONLAdapterSupport.object(message["modelInfo"])
                return JSONLAdapterSupport.string(modelInfo?["modelId"])
            }.first

            return .success(
                NormalizedSessionInfo(
                    id: taskId,
                    source: .cline,
                    startTime: Phase4AdapterSupport.isoFromMilliseconds(firstTimestamp),
                    endTime: lastTimestamp != firstTimestamp ? Phase4AdapterSupport.isoFromMilliseconds(lastTimestamp) : nil,
                    cwd: Self.extractCwd(from: messages),
                    project: nil,
                    model: model,
                    messageCount: userMessages.count + assistantMessages.count,
                    userMessageCount: userMessages.count,
                    assistantMessageCount: assistantMessages.count,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: summary.map { String($0.prefix(200)) },
                    filePath: locator,
                    sizeBytes: Phase4AdapterSupport.fileSize(locator),
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
        let objects = try Phase4AdapterSupport.readJSONArray(locator: locator, limits: limits)
        let messages = Self.messages(from: objects)
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func messages(from objects: [Phase4AdapterSupport.JSONObject]) -> [NormalizedMessage] {
        var messages: [NormalizedMessage] = []
        var pendingUsage = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        var hasPendingUsage = false

        for object in objects {
            if let usage = apiRequestUsage(from: object) {
                pendingUsage.inputTokens += usage.inputTokens
                pendingUsage.outputTokens += usage.outputTokens
                pendingUsage.cacheReadTokens = (pendingUsage.cacheReadTokens ?? 0) + (usage.cacheReadTokens ?? 0)
                pendingUsage.cacheCreationTokens = (pendingUsage.cacheCreationTokens ?? 0) + (usage.cacheCreationTokens ?? 0)
                hasPendingUsage = true
                continue
            }

            guard var message = message(from: object) else { continue }
            if message.role == .assistant, hasPendingUsage {
                message.usage = pendingUsage
                pendingUsage = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
                hasPendingUsage = false
            }
            messages.append(message)
        }

        return messages
    }

    private static func message(from object: Phase4AdapterSupport.JSONObject) -> NormalizedMessage? {
        let say = JSONLAdapterSupport.string(object["say"])
        guard say == "task" || say == "user_feedback" || (say == "text" && !(object["partial"] as? Bool ?? false)) else {
            return nil
        }
        guard let timestamp = Phase4AdapterSupport.double(object["ts"]) else { return nil }
        return NormalizedMessage(
            role: say == "task" || say == "user_feedback" ? .user : .assistant,
            content: JSONLAdapterSupport.string(object["text"]) ?? "",
            timestamp: Phase4AdapterSupport.isoFromMilliseconds(timestamp),
            toolCalls: nil,
            usage: nil
        )
    }

    private static func apiRequestUsage(from object: Phase4AdapterSupport.JSONObject) -> TokenUsage? {
        guard JSONLAdapterSupport.string(object["say"]) == "api_req_started",
              let text = JSONLAdapterSupport.string(object["text"]),
              let payload = Phase4AdapterSupport.jsonObject(from: text)
        else {
            return nil
        }

        let inputTokens = Int(Phase4AdapterSupport.int64(payload["tokensIn"]) ?? 0)
        let outputTokens = Int(Phase4AdapterSupport.int64(payload["tokensOut"]) ?? 0)
        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        return TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: 0,
            cacheCreationTokens: 0
        )
    }

    private static func extractCwd(from messages: [Phase4AdapterSupport.JSONObject]) -> String {
        for message in messages {
            guard JSONLAdapterSupport.string(message["say"]) == "api_req_started",
                  let text = JSONLAdapterSupport.string(message["text"]),
                  let request = JSONLAdapterSupport.string(Phase4AdapterSupport.jsonObject(from: text)?["request"])
            else {
                continue
            }
            // Cline writes "Current Working Directory (<path>) Files ...". A path
            // can itself contain ')', so anchor on the "\) Files" suffix and match
            // the path lazily up to it; fall back to the loose pattern for caches
            // that lack the " Files" trailer.
            if let cwd = Self.captureGroup(
                in: request,
                pattern: #"Current Working Directory \((.+?)\) Files"#
            ) ?? Self.captureGroup(
                in: request,
                pattern: #"Current Working Directory \(([^)]+)\)"#
            ) {
                return cwd
            }
        }
        return ""
    }

    // Returns the first capture group of `pattern` in `text`, or nil. Uses
    // dotMatchesLineSeparators so a path-with-newline edge case still matches
    // (parity with the TS `/s` flag).
    private static func captureGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[groupRange])
    }
}
