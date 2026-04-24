import Foundation

final class VsCodeAdapter: SessionAdapter {
    let source: SourceName = .vscode
    private let workspaceStorageDir: URL
    private let limits: ParserLimits

    init(
        workspaceStorageDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/workspaceStorage")
            .path,
        limits: ParserLimits = .default
    ) {
        self.workspaceStorageDir = URL(fileURLWithPath: workspaceStorageDir)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(workspaceStorageDir)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for workspaceURL in JSONLAdapterSupport.directChildren(of: workspaceStorageDir)
            where JSONLAdapterSupport.isDirectory(workspaceURL)
        {
            let chatSessionsURL = workspaceURL.appendingPathComponent("chatSessions")
            guard JSONLAdapterSupport.isDirectory(chatSessionsURL) else { continue }
            for fileURL in JSONLAdapterSupport.directChildren(of: chatSessionsURL)
                where fileURL.pathExtension == "jsonl"
            {
                locators.append(fileURL.path)
            }
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            guard let session = try Self.readSession(locator: locator, limits: limits),
                  let requests = JSONLAdapterSupport.array(session["requests"]),
                  !requests.isEmpty,
                  let creationDate = Phase4AdapterSupport.double(session["creationDate"])
            else {
                return .failure(.malformedJSON)
            }
            let requestObjects = requests.compactMap { JSONLAdapterSupport.object($0) }
            let userTexts = requestObjects.map(Self.extractUserText).filter { !$0.isEmpty }
            let lastTimestamp = Phase4AdapterSupport.double(requestObjects.last?["timestamp"])
            let sessionId = JSONLAdapterSupport.string(session["sessionId"]) ??
                URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .vscode,
                    startTime: Phase4AdapterSupport.isoFromMilliseconds(creationDate),
                    endTime: lastTimestamp != nil && lastTimestamp != creationDate
                        ? Phase4AdapterSupport.isoFromMilliseconds(lastTimestamp!)
                        : nil,
                    cwd: "",
                    project: nil,
                    model: nil,
                    messageCount: requestObjects.count * 2,
                    userMessageCount: requestObjects.count,
                    assistantMessageCount: requestObjects.count,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: userTexts.first.map { String($0.prefix(200)) },
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
        guard let session = try Self.readSession(locator: locator, limits: limits),
              let requests = JSONLAdapterSupport.array(session["requests"])
        else {
            return JSONLAdapterSupport.stream([])
        }

        var messages: [NormalizedMessage] = []
        for request in requests.compactMap({ JSONLAdapterSupport.object($0) }) {
            let timestamp = Phase4AdapterSupport.double(request["timestamp"])
                .map { Phase4AdapterSupport.isoFromMilliseconds($0) }
            let userText = Self.extractUserText(request)
            if !userText.isEmpty {
                messages.append(
                    NormalizedMessage(
                        role: .user,
                        content: userText,
                        timestamp: timestamp,
                        toolCalls: nil,
                        usage: nil
                    )
                )
            }
            let assistantText = Self.extractAssistantText(request)
            if !assistantText.isEmpty {
                messages.append(
                    NormalizedMessage(
                        role: .assistant,
                        content: assistantText,
                        timestamp: timestamp,
                        toolCalls: nil,
                        usage: nil
                    )
                )
            }
        }
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func readSession(
        locator: String,
        limits: ParserLimits
    ) throws -> Phase4AdapterSupport.JSONObject? {
        let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
        if let failure { throw failure }
        guard let line0 = objects.first,
              (line0["kind"] as? NSNumber)?.intValue == 0
        else {
            return nil
        }
        return JSONLAdapterSupport.object(line0["v"])
    }

    private static func extractUserText(_ request: Phase4AdapterSupport.JSONObject) -> String {
        guard let message = JSONLAdapterSupport.object(request["message"]) else { return "" }
        if let text = JSONLAdapterSupport.string(message["text"]), !text.isEmpty {
            return text
        }
        guard let parts = JSONLAdapterSupport.array(message["parts"]) else { return "" }
        for part in parts.compactMap({ JSONLAdapterSupport.object($0) }) {
            if JSONLAdapterSupport.string(part["kind"]) == "text",
               let value = JSONLAdapterSupport.string(part["value"]),
               !value.isEmpty
            {
                return value
            }
        }
        return ""
    }

    private static func extractAssistantText(_ request: Phase4AdapterSupport.JSONObject) -> String {
        guard let responses = JSONLAdapterSupport.array(request["response"]) else { return "" }
        for response in responses.compactMap({ JSONLAdapterSupport.object($0) }) {
            let value = JSONLAdapterSupport.object(response["value"])
            let content = JSONLAdapterSupport.object(value?["content"])
            if JSONLAdapterSupport.string(value?["kind"]) == "markdownContent",
               let text = JSONLAdapterSupport.string(content?["value"]),
               !text.isEmpty
            {
                return text
            }
        }
        return ""
    }
}
