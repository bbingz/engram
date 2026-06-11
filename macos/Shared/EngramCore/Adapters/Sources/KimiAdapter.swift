import Foundation

final class KimiAdapter: SessionAdapter, Sendable {
    private typealias TurnMetadata = (startTime: String, endTime: String?, usage: TokenUsage?)

    let source: SourceName = .kimi
    private let sessionsRoot: URL
    private let kimiJsonPath: URL
    private let limits: ParserLimits

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/sessions")
            .path,
        kimiJsonPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/kimi.json")
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionsRoot = URL(fileURLWithPath: sessionsRoot)
        self.kimiJsonPath = URL(fileURLWithPath: kimiJsonPath)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(sessionsRoot)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for workspaceURL in JSONLAdapterSupport.directChildren(of: sessionsRoot)
            where JSONLAdapterSupport.isDirectory(workspaceURL)
        {
            for sessionURL in JSONLAdapterSupport.directChildren(of: workspaceURL)
                where JSONLAdapterSupport.isDirectory(sessionURL)
            {
                let contextURL = sessionURL.appendingPathComponent("context.jsonl")
                if JSONLAdapterSupport.fileExists(contextURL.path) {
                    locators.append(contextURL.path)
                }
            }
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let contextFiles = Self.contextFiles(for: locator)
            var allObjects: [Phase4AdapterSupport.JSONObject] = []
            var totalSize = Int64(0)
            for file in contextFiles {
                let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: file, limits: limits)
                if let failure { return .failure(failure) }
                allObjects.append(contentsOf: objects)
                totalSize += Phase4AdapterSupport.fileSize(file)
            }

            let messages = allObjects.filter(Self.isConversation)
            let userMessages = messages.filter { JSONLAdapterSupport.string($0["role"]) == "user" }
            let assistantMessages = messages.filter { JSONLAdapterSupport.string($0["role"]) == "assistant" }
            let timestamps = try Self.readTimestamps(wirePath: URL(fileURLWithPath: locator)
                .deletingLastPathComponent()
                .appendingPathComponent("wire.jsonl")
                .path, limits: limits)
            let fileDate = (try? FileManager.default.attributesOfItem(atPath: locator)[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let fallbackStart = ISO8601DateFormatter().string(from: fileDate.addingTimeInterval(-60))
            let firstUserText = JSONLAdapterSupport.string(userMessages.first?["content"]) ?? ""
            let sessionId = URL(fileURLWithPath: locator).deletingLastPathComponent().lastPathComponent

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .kimi,
                    startTime: timestamps.startTime.isEmpty ? fallbackStart : timestamps.startTime,
                    endTime: timestamps.endTime != timestamps.startTime ? timestamps.endTime : nil,
                    cwd: resolveCwd(sessionId: sessionId),
                    project: nil,
                    model: nil,
                    messageCount: userMessages.count + assistantMessages.count,
                    userMessageCount: userMessages.count,
                    assistantMessageCount: assistantMessages.count,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                    filePath: locator,
                    sizeBytes: totalSize,
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
        var messages: [NormalizedMessage] = []
        let turns = try Self.readTurnMetadata(
            wirePath: URL(fileURLWithPath: locator)
                .deletingLastPathComponent()
                .appendingPathComponent("wire.jsonl")
                .path,
            limits: limits
        )
        var turnIndex = 0
        var userBoundInTurn = false
        var assistantBoundInTurn = false

        for file in Self.contextFiles(for: locator) {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: file, limits: limits)
            if let failure { throw failure }
            for object in objects {
                guard let role = JSONLAdapterSupport.string(object["role"]),
                      role == "user" || role == "assistant"
                else { continue }

                let shouldAdvance = role == "user"
                    ? (userBoundInTurn || assistantBoundInTurn)
                    : assistantBoundInTurn
                if shouldAdvance {
                    turnIndex += 1
                    userBoundInTurn = false
                    assistantBoundInTurn = false
                }
                let turn = turnIndex < turns.count ? turns[turnIndex] : nil
                let wireTimestamp = role == "user" ? turn?.startTime : (turn?.endTime ?? turn?.startTime)
                if role == "user" {
                    userBoundInTurn = true
                } else {
                    assistantBoundInTurn = true
                }

                let usage = role == "assistant" ? turn?.usage : nil
                if let message = Self.message(
                    from: object,
                    timestamp: Self.lineTimestamp(from: object) ?? wireTimestamp,
                    usage: usage
                ) {
                    messages.append(message)
                }
            }
        }
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private func resolveCwd(sessionId: String) -> String {
        guard let data = try? Data(contentsOf: kimiJsonPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? Phase4AdapterSupport.JSONObject,
              let workDirs = JSONLAdapterSupport.array(object["work_dirs"])
        else {
            return ""
        }
        for workDir in workDirs.compactMap({ JSONLAdapterSupport.object($0) }) {
            if JSONLAdapterSupport.string(workDir["last_session_id"]) == sessionId {
                return JSONLAdapterSupport.string(workDir["path"]) ?? ""
            }
        }
        return ""
    }

    private static func contextFiles(for locator: String) -> [String] {
        let url = URL(fileURLWithPath: locator)
        let directory = url.deletingLastPathComponent()
        var files = [locator]
        let subFiles = JSONLAdapterSupport.directChildren(of: directory)
            .filter {
                $0.lastPathComponent.hasPrefix("context_sub_") && $0.pathExtension == "jsonl"
            }
            .sorted {
                subContextIndex($0.lastPathComponent) < subContextIndex($1.lastPathComponent)
            }
            .map(\.path)
        files.append(contentsOf: subFiles)
        return files
    }

    private static func subContextIndex(_ filename: String) -> Int {
        let value = filename
            .replacingOccurrences(of: "context_sub_", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        return Int(value) ?? 0
    }

    private static func readTimestamps(
        wirePath: String,
        limits: ParserLimits
    ) throws -> (startTime: String, endTime: String) {
        let turns = try readTurnMetadata(wirePath: wirePath, limits: limits)
        guard let first = turns.first else { return ("", "") }
        let last = turns.last
        return (first.startTime, last?.endTime ?? last?.startTime ?? first.startTime)
    }

    private static func readTurnMetadata(
        wirePath: String,
        limits: ParserLimits
    ) throws -> [TurnMetadata] {
        guard JSONLAdapterSupport.fileExists(wirePath) else { return [] }
        let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: wirePath, limits: limits)
        if let failure { throw failure }
        var turns: [TurnMetadata] = []
        for object in objects {
            guard let timestamp = Phase4AdapterSupport.double(object["timestamp"]) else { continue }
            let iso = Phase4AdapterSupport.isoFromSeconds(timestamp)
            let message = JSONLAdapterSupport.object(object["message"])
            let type = JSONLAdapterSupport.string(message?["type"])
            if type == "TurnBegin" {
                turns.append((startTime: iso, endTime: nil, usage: nil))
            } else if type == "TurnEnd", !turns.isEmpty, turns[turns.count - 1].endTime == nil {
                turns[turns.count - 1].endTime = iso
            } else if type == "StatusUpdate",
                      !turns.isEmpty,
                      let payload = JSONLAdapterSupport.object(message?["payload"]),
                      let usage = usage(from: JSONLAdapterSupport.object(payload["token_usage"]))
            {
                turns[turns.count - 1].usage = accumulatedUsage(
                    turns[turns.count - 1].usage,
                    usage
                )
            }
        }
        return turns
    }

    private static func isConversation(_ object: Phase4AdapterSupport.JSONObject) -> Bool {
        let role = JSONLAdapterSupport.string(object["role"])
        return role == "user" || role == "assistant"
    }

    private static func message(
        from object: Phase4AdapterSupport.JSONObject,
        timestamp: String? = nil,
        usage: TokenUsage? = nil
    ) -> NormalizedMessage? {
        guard isConversation(object),
              let role = JSONLAdapterSupport.string(object["role"])
        else {
            return nil
        }
        return NormalizedMessage(
            role: role == "user" ? .user : .assistant,
            content: JSONLAdapterSupport.string(object["content"]) ?? "",
            timestamp: timestamp,
            toolCalls: nil,
            usage: role == "assistant" ? usage : nil
        )
    }

    private static func usage(from tokenUsage: Phase4AdapterSupport.JSONObject?) -> TokenUsage? {
        guard let tokenUsage else { return nil }
        let usage = TokenUsage(
            inputTokens: int(tokenUsage["input_other"]),
            outputTokens: int(tokenUsage["output"]),
            cacheReadTokens: int(tokenUsage["input_cache_read"]),
            cacheCreationTokens: int(tokenUsage["input_cache_creation"])
        )
        guard usage.inputTokens > 0
            || usage.outputTokens > 0
            || (usage.cacheReadTokens ?? 0) > 0
            || (usage.cacheCreationTokens ?? 0) > 0
        else {
            return nil
        }
        return usage
    }

    private static func accumulatedUsage(_ current: TokenUsage?, _ next: TokenUsage) -> TokenUsage {
        guard let current else { return next }
        return TokenUsage(
            inputTokens: current.inputTokens + next.inputTokens,
            outputTokens: current.outputTokens + next.outputTokens,
            cacheReadTokens: (current.cacheReadTokens ?? 0) + (next.cacheReadTokens ?? 0),
            cacheCreationTokens: (current.cacheCreationTokens ?? 0) + (next.cacheCreationTokens ?? 0)
        )
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func lineTimestamp(from object: Phase4AdapterSupport.JSONObject) -> String? {
        if let timestamp = JSONLAdapterSupport.string(object["timestamp"]) {
            return timestamp
        }
        if let timestamp = Phase4AdapterSupport.double(object["timestamp"]) {
            return Phase4AdapterSupport.isoFromSeconds(timestamp)
        }
        return nil
    }
}
