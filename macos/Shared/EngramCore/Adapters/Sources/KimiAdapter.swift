import CryptoKit
import Foundation

final class KimiAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
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

    func listSessionLocators(
        modifiedSince: Date,
        fileManager: FileManager
    ) async throws -> [String] {
        try await listSessionLocators().filter { locator in
            Self.compositeModificationDate(locator: locator, fileManager: fileManager)
                .map { $0 >= modifiedSince } ?? false
        }
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
            let toolMessages = messages.filter { JSONLAdapterSupport.string($0["role"]) == "tool" }
            let timestamps = try Self.readTimestamps(wirePath: URL(fileURLWithPath: locator)
                .deletingLastPathComponent()
                .appendingPathComponent("wire.jsonl")
                .path, limits: limits)
            let fileDate = (try? FileManager.default.attributesOfItem(atPath: locator)[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let fallbackStart = ISO8601DateFormatter().string(from: fileDate.addingTimeInterval(-60))
            let firstUserText = Self.extractContent(userMessages.first?["content"])
            let sessionId = URL(fileURLWithPath: locator).deletingLastPathComponent().lastPathComponent

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .kimi,
                    startTime: timestamps.startTime.isEmpty ? fallbackStart : timestamps.startTime,
                    endTime: timestamps.endTime != timestamps.startTime ? timestamps.endTime : nil,
                    cwd: resolveCwd(sessionId: sessionId, locator: locator),
                    project: nil,
                    model: nil,
                    messageCount: messages.count,
                    userMessageCount: userMessages.count,
                    assistantMessageCount: assistantMessages.count,
                    toolMessageCount: toolMessages.count,
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
        let result = try Self.messages(locator: locator, options: options, limits: limits)
        return JSONLAdapterSupport.stream(result.messages)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        let result = try Self.messages(locator: locator, options: options, limits: limits)
        return JSONLAdapterSupport.stream(result)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func messages(
        locator: String,
        options: StreamMessagesOptions,
        limits: ParserLimits
    ) throws -> JSONLAdapterSupport.WindowedMessagesResult {
        var messages: [NormalizedMessage] = []
        let turns = try Self.readTurnMetadata(
            wirePath: URL(fileURLWithPath: locator)
                .deletingLastPathComponent()
                .appendingPathComponent("wire.jsonl")
                .path,
            limits: limits
        )
        var records: [(object: Phase4AdapterSupport.JSONObject, role: String, turnIndex: Int)] = []
        var turnIndex = 0
        var hasMessageInTurn = false
        var truncatedAt: Int?
        let shouldApplyMessageCap = options.limit == nil

        for file in Self.contextFiles(for: locator) {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: file,
                limits: limits,
                reportFailures: shouldApplyMessageCap
            )
            if let failure {
                guard failure == .messageLimitExceeded else { throw failure }
                truncatedAt = limits.maxMessages
            }
            for object in objects {
                guard let role = JSONLAdapterSupport.string(object["role"]),
                      role == "user" || role == "assistant" || role == "tool"
                else { continue }

                if role == "user", hasMessageInTurn {
                    turnIndex += 1
                    hasMessageInTurn = false
                }
                records.append((object: object, role: role, turnIndex: turnIndex))
                hasMessageInTurn = true
            }
        }

        var lastAssistantByTurn: [Int: Int] = [:]
        for (index, record) in records.enumerated() where record.role == "assistant" {
            lastAssistantByTurn[record.turnIndex] = index
        }
        for (index, record) in records.enumerated() {
            let turn = record.turnIndex < turns.count ? turns[record.turnIndex] : nil
            let wireTimestamp = record.role == "user"
                ? turn?.startTime
                : (turn?.endTime ?? turn?.startTime)
            let usage = record.role == "assistant"
                && lastAssistantByTurn[record.turnIndex] == index
                ? turn?.usage
                : nil
            if let message = Self.message(
                from: record.object,
                timestamp: Self.lineTimestamp(from: record.object) ?? wireTimestamp,
                usage: usage
            ) {
                messages.append(message)
            }
        }
        if shouldApplyMessageCap, messages.count > limits.maxMessages {
            truncatedAt = limits.maxMessages
        }
        let boundedMessages = truncatedAt == nil ? messages : Array(messages.prefix(limits.maxMessages))
        return JSONLAdapterSupport.WindowedMessagesResult(
            messages: JSONLAdapterSupport.applyWindow(boundedMessages, options: options),
            totalKnownComplete: truncatedAt == nil,
            truncatedAt: truncatedAt
        )
    }

    private func resolveCwd(sessionId: String, locator: String) -> String {
        guard let data = try? Data(contentsOf: kimiJsonPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? Phase4AdapterSupport.JSONObject,
              let workDirs = JSONLAdapterSupport.array(object["work_dirs"])
        else {
            return ""
        }
        let workspaceName = URL(fileURLWithPath: locator)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
        let objects = workDirs.compactMap { JSONLAdapterSupport.object($0) }
        for workDir in objects {
            guard let path = JSONLAdapterSupport.string(workDir["path"]),
                  Self.workspaceDirectoryName(
                    path: path,
                    kaos: JSONLAdapterSupport.string(workDir["kaos"])
                  ) == workspaceName
            else { continue }
            return path
        }
        for workDir in objects {
            if JSONLAdapterSupport.string(workDir["last_session_id"]) == sessionId {
                return JSONLAdapterSupport.string(workDir["path"]) ?? ""
            }
        }
        return ""
    }

    private static func workspaceDirectoryName(path: String, kaos: String?) -> String {
        let digest = Insecure.MD5.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard let kaos, !kaos.isEmpty, kaos != "local" else { return digest }
        return "\(kaos)_\(digest)"
    }

    private static func contextFiles(for locator: String) -> [String] {
        let url = URL(fileURLWithPath: locator)
        let directory = url.deletingLastPathComponent()
        var files = [locator]
        let subFiles = JSONLAdapterSupport.directChildren(of: directory)
            .filter { contextShardIndex($0.lastPathComponent) != nil }
            .sorted {
                (contextShardIndex($0.lastPathComponent) ?? 0) <
                    (contextShardIndex($1.lastPathComponent) ?? 0)
            }
            .map(\.path)
        files.append(contentsOf: subFiles)
        return files
    }

    private static func compositeModificationDate(
        locator: String,
        fileManager: FileManager
    ) -> Date? {
        let wirePath = URL(fileURLWithPath: locator)
            .deletingLastPathComponent()
            .appendingPathComponent("wire.jsonl")
            .path
        return (contextFiles(for: locator) + [wirePath]).compactMap { path in
            try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
        }
        .max()
    }

    private static func contextShardIndex(_ filename: String) -> Int? {
        guard filename.hasSuffix(".jsonl") else { return nil }
        let stem = String(filename.dropLast(".jsonl".count))
        if stem.hasPrefix("context_sub_") {
            return Int(stem.dropFirst("context_sub_".count))
        }
        if stem.hasPrefix("context_") {
            return Int(stem.dropFirst("context_".count))
        }
        return nil
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
        return role == "user" || role == "assistant" || role == "tool"
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
        let normalizedRole: NormalizedMessageRole = switch role {
        case "user": .user
        case "tool": .tool
        default: .assistant
        }
        let toolCalls = role == "assistant" ? toolCalls(from: object["tool_calls"]) : []
        return NormalizedMessage(
            role: normalizedRole,
            content: extractContent(object["content"]),
            timestamp: timestamp,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            usage: role == "assistant" ? usage : nil
        )
    }

    private static func toolCalls(from value: Any?) -> [NormalizedToolCall] {
        guard let calls = JSONLAdapterSupport.array(value) else { return [] }
        return calls.compactMap { value in
            guard let call = JSONLAdapterSupport.object(value),
                  let function = JSONLAdapterSupport.object(call["function"]),
                  let name = JSONLAdapterSupport.string(function["name"])
            else { return nil }
            let input: String?
            if let string = JSONLAdapterSupport.string(function["arguments"]) {
                input = string
            } else {
                input = function["arguments"].flatMap {
                    JSONLAdapterSupport.jsonString($0, limit: 2_000)
                }
            }
            return NormalizedToolCall(name: name, input: input, output: nil)
        }
    }

    private static func extractContent(_ content: Any?) -> String {
        if let string = JSONLAdapterSupport.string(content) { return string }
        guard let parts = JSONLAdapterSupport.array(content) else { return "" }
        return parts.compactMap { item in
            guard let object = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(object["type"]) == "text",
                  let text = JSONLAdapterSupport.string(object["text"]),
                  !text.isEmpty
            else { return nil }
            return text
        }
        .joined(separator: "\n\n")
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
