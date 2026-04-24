import Foundation

final class ClineAdapter: SessionAdapter {
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

            return .success(
                NormalizedSessionInfo(
                    id: taskId,
                    source: .cline,
                    startTime: Phase4AdapterSupport.isoFromMilliseconds(firstTimestamp),
                    endTime: lastTimestamp != firstTimestamp ? Phase4AdapterSupport.isoFromMilliseconds(lastTimestamp) : nil,
                    cwd: Self.extractCwd(from: messages),
                    project: nil,
                    model: nil,
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
        let messages = try Phase4AdapterSupport.readJSONArray(locator: locator, limits: limits)
            .compactMap(Self.message(from:))
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
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

    private static func extractCwd(from messages: [Phase4AdapterSupport.JSONObject]) -> String {
        for message in messages {
            guard JSONLAdapterSupport.string(message["say"]) == "api_req_started",
                  let text = JSONLAdapterSupport.string(message["text"]),
                  let request = JSONLAdapterSupport.string(Phase4AdapterSupport.jsonObject(from: text)?["request"])
            else {
                continue
            }
            if let match = request.range(
                of: #"Current Working Directory \(([^)]+)\)"#,
                options: .regularExpression
            ) {
                let matched = String(request[match])
                return matched
                    .replacingOccurrences(of: "Current Working Directory (", with: "")
                    .replacingOccurrences(of: ")", with: "")
            }
        }
        return ""
    }
}
