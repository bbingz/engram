import CryptoKit
import Darwin
import Foundation

final class KimiAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
    private typealias TurnMetadata = (startTime: String, endTime: String?, usage: TokenUsage?)

    let source: SourceName = .kimi
    private let sessionsRoot: URL
    private let kimiJsonPath: URL
    private let limits: ParserLimits
    private let testHooks: JSONLIdentityTestHooks
    private let capturedProjectContext: ArchiveKimiProjectContext?
    private let capturedPrimaryMtimeNs: Int64?

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/sessions")
            .path,
        kimiJsonPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/kimi.json")
            .path,
        limits: ParserLimits = .default,
        testHooks: JSONLIdentityTestHooks = JSONLIdentityTestHooks(),
        capturedProjectContext: ArchiveKimiProjectContext? = nil,
        capturedPrimaryMtimeNs: Int64? = nil
    ) {
        self.sessionsRoot = URL(fileURLWithPath: sessionsRoot)
        self.kimiJsonPath = URL(fileURLWithPath: kimiJsonPath)
        self.limits = limits
        self.testHooks = testHooks
        self.capturedProjectContext = capturedProjectContext
        self.capturedPrimaryMtimeNs = capturedPrimaryMtimeNs
    }

    static func scanCapturedSource(
        physicalLocator: String,
        logicalLocator: String,
        replayLayout: ArchiveReplayLayout,
        capturedModificationNanoseconds: Int64?
    ) async throws -> AdapterParseResult<CapturedSourceScan> {
        try Task.checkCancellation()
        guard let context = replayLayout.kimiProjectContext,
              let entrypoint = replayLayout.entrypointRelativePath else {
            return .failure(.malformedJSON)
        }
        let declared = context.workspaceName + "/" + context.nativeSessionID + "/context.jsonl"
        guard declared.utf8.elementsEqual(entrypoint.utf8),
              hasDeclaredSuffix(physicalLocator, entrypoint),
              hasDeclaredSuffix(logicalLocator, entrypoint) else {
            return .failure(.malformedJSON)
        }
        let adapter = KimiAdapter(
            sessionsRoot: URL(fileURLWithPath: physicalLocator)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,
            kimiJsonPath: physicalLocator + ".no-kimi-registry",
            capturedProjectContext: context,
            capturedPrimaryMtimeNs: capturedModificationNanoseconds
        )
        switch try await adapter.scanForIndexing(locator: physicalLocator) {
        case .failure(let failure):
            return .failure(failure)
        case .success(var scan):
            if let failure = scan.parseFailure { return .failure(failure) }
            guard scan.info.id.utf8.elementsEqual(context.nativeSessionID.utf8) else {
                return .failure(.malformedJSON)
            }
            scan.info.filePath = logicalLocator
            return .success(CapturedSourceScan(scan: scan, rawSourceSessionID: context.nativeSessionID))
        }
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
            compositeModificationDate(locator: locator, fileManager: fileManager)
                .map { $0 >= modifiedSince } ?? false
        }
    }

    func indexingInputIdentity(locator: String) -> IndexingInputIdentity? {
        compositeInputIdentity(locator: locator)
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let contextFiles = Self.contextFiles(for: locator)
            var allObjects: [Phase4AdapterSupport.JSONObject] = []
            var combinedMessageCount = 0
            var totalSize = Int64(0)
            var retainedFailure: ParserFailure?
            for file in contextFiles {
                let (objects, failure) = try JSONLAdapterSupport.readObjects(
                    locator: file,
                    limits: limits,
                    reportFailures: true,
                    countsTowardMessageLimit: Self.isConversation,
                    beforeIdentityValidation: testHooks.beforeFinalIdentityValidation
                )
                if let failure {
                    guard failure == .fileModifiedDuringParse,
                          objects.contains(where: Self.isConversation)
                    else {
                        return .failure(failure)
                    }
                    retainedFailure = failure
                }
                combinedMessageCount += objects.lazy.filter(Self.isConversation).count
                guard combinedMessageCount <= limits.maxMessages else {
                    return .failure(.messageLimitExceeded)
                }
                allObjects.append(contentsOf: objects)
                totalSize += Phase4AdapterSupport.fileSize(file)
                if retainedFailure != nil { break }
            }

            let messages = allObjects.filter(Self.isConversation)
            let userMessages = messages.filter { JSONLAdapterSupport.string($0["role"]) == "user" }
            let assistantMessages = messages.filter { JSONLAdapterSupport.string($0["role"]) == "assistant" }
            let toolMessages = messages.filter { JSONLAdapterSupport.string($0["role"]) == "tool" }
            let timestamps: (startTime: String, endTime: String)
            do {
                timestamps = try Self.readTimestamps(wirePath: URL(fileURLWithPath: locator)
                    .deletingLastPathComponent()
                    .appendingPathComponent("wire.jsonl")
                    .path, limits: limits)
            } catch let failure as ParserFailure {
                guard !messages.isEmpty else { return .failure(failure) }
                timestamps = ("", "")
            }
            let fileDate: Date
            if let capturedPrimaryMtimeNs {
                fileDate = Date(timeIntervalSince1970: TimeInterval(capturedPrimaryMtimeNs) / 1_000_000_000)
            } else {
                fileDate = (try? FileManager.default.attributesOfItem(atPath: locator)[.modificationDate] as? Date)
                    ?? Date(timeIntervalSince1970: 0)
            }
            let fallbackStart = ISO8601DateFormatter().string(from: fileDate.addingTimeInterval(-60))
            let firstUserText = Self.extractContent(userMessages.first?["content"])
            let sessionId = URL(fileURLWithPath: locator).deletingLastPathComponent().lastPathComponent
            // R184-3: wire/context metadata with no visible user/assistant/tool
            // turns must not become a zero-count browsable session.
            guard userMessages.count + assistantMessages.count + toolMessages.count > 0 else {
                return .failure(.noVisibleMessages)
            }

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

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        do {
            guard let before = indexingInputIdentity(locator: locator) else {
                return .failure(.fileMissing)
            }
            let info: NormalizedSessionInfo
            switch try await parseSessionInfo(locator: locator) {
            case .success(let value): info = value
            case .failure(let failure): return .failure(failure)
            }
            let result = try await streamMessagesWithMetadata(
                locator: locator,
                options: StreamMessagesOptions()
            )
            if result.truncatedAt != nil { return .failure(.messageLimitExceeded) }
            var messages: [NormalizedMessage] = []
            for try await message in result.messages { messages.append(message) }
            let identityFailure: ParserFailure? = indexingInputIdentity(locator: locator) == before
                ? nil
                : .fileModifiedDuringParse
            if let failure = result.parseFailure ?? identityFailure {
                guard !messages.isEmpty else {
                    return .failure(failure)
                }
                return .success(IndexingScan(info: info, messages: messages, parseFailure: failure))
            }
            guard result.totalKnownComplete else { return .failure(.messageLimitExceeded) }
            return .success(IndexingScan(info: info, messages: messages))
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
        let turnResult: (turns: [TurnMetadata], parseFailure: ParserFailure?)
        do {
            turnResult = try Self.readTurnMetadata(
                wirePath: URL(fileURLWithPath: locator)
                    .deletingLastPathComponent()
                    .appendingPathComponent("wire.jsonl")
                    .path,
                limits: limits
            )
        } catch let failure as ParserFailure {
            turnResult = ([], failure)
        }
        let turns = turnResult.turns
        var records: [(object: Phase4AdapterSupport.JSONObject, role: String, turnIndex: Int)] = []
        var turnIndex = 0
        var hasMessageInTurn = false
        var hasMoreMessages = false
        var parseFailure = turnResult.parseFailure

        for file in Self.contextFiles(for: locator) {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: file,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: Self.isConversation
            )
            if let failure {
                if failure == .messageLimitExceeded {
                    hasMoreMessages = true
                } else {
                    parseFailure = failure
                }
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
            if failure != nil { break }
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
        if messages.count > limits.maxMessages {
            hasMoreMessages = true
        }
        return JSONLAdapterSupport.boundedWindowWithMetadata(
            messages,
            options: options,
            maxMessages: limits.maxMessages,
            hasMoreMessages: hasMoreMessages,
            parseFailure: parseFailure
        )
    }

    private func resolveCwd(sessionId: String, locator: String) -> String {
        if let capturedProjectContext {
            return capturedProjectContext.cwd
        }
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
            .filter { contextShardIdentity($0.lastPathComponent) != nil }
            .sorted(by: Self.contextShardReplayOrder)
            .map(\.path)
        files.append(contentsOf: subFiles)
        return files
    }

    private func compositeModificationDate(
        locator: String,
        fileManager: FileManager
    ) -> Date? {
        _ = fileManager
        guard let identity = compositeInputIdentity(locator: locator) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(identity.modifiedAtNanos) / 1_000_000_000)
    }

    private func compositeInputPaths(locator: String) -> [String] {
        let wirePath = URL(fileURLWithPath: locator)
            .deletingLastPathComponent()
            .appendingPathComponent("wire.jsonl")
            .path
        var paths = Self.contextFiles(for: locator) + [wirePath]
        if capturedProjectContext == nil {
            paths.append(kimiJsonPath.path)
        }
        return paths
    }

    private static func hasDeclaredSuffix(_ absolute: String, _ relative: String) -> Bool {
        let suffix = "/" + relative
        return absolute.utf8.count > suffix.utf8.count
            && absolute.utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8)
    }

    private func compositeInputIdentity(locator: String) -> IndexingInputIdentity? {
        var totalSize: Int64 = 0
        var newestNanos: Int64 = 0
        var locatorInode: Int64?
        var locatorDevice: Int64?
        var foundLocator = false

        for path in Set(compositeInputPaths(locator: locator)) {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            totalSize += Int64(info.st_size)
            let modifiedNanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(info.st_mtimespec.tv_nsec)
            newestNanos = max(newestNanos, modifiedNanos)
            if path == locator {
                foundLocator = true
                locatorInode = Int64(info.st_ino)
                locatorDevice = Int64(info.st_dev)
            }
        }

        guard foundLocator else { return nil }
        return IndexingInputIdentity(
            sizeBytes: totalSize,
            modifiedAtNanos: newestNanos,
            locatorInode: locatorInode,
            locatorDevice: locatorDevice
        )
    }

    private struct ShardIdentity {
        let family: String
        let index: Int
    }

    /// Primary is prepended by the caller. Shards stay numeric-index order,
    /// then UTF8 filename for equal indexes. This is a stable replay
    /// convention, not wall-clock chronology.
    private static func contextShardReplayOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = contextShardIdentity(lhs.lastPathComponent)?.index ?? 0
        let right = contextShardIdentity(rhs.lastPathComponent)?.index ?? 0
        if left != right { return left < right }
        return lhs.lastPathComponent.utf8.lexicographicallyPrecedes(rhs.lastPathComponent.utf8)
    }

    private static func contextShardIdentity(_ filename: String) -> ShardIdentity? {
        guard filename.hasSuffix(".jsonl") else { return nil }
        let stem = String(filename.dropLast(".jsonl".count))
        if stem.hasPrefix("context_sub_") {
            guard let index = Int(stem.dropFirst("context_sub_".count)) else { return nil }
            return ShardIdentity(family: "context_sub", index: index)
        }
        if stem.hasPrefix("context_") {
            guard let index = Int(stem.dropFirst("context_".count)) else { return nil }
            return ShardIdentity(family: "context", index: index)
        }
        return nil
    }

    private static func readTimestamps(
        wirePath: String,
        limits: ParserLimits
    ) throws -> (startTime: String, endTime: String) {
        let turns = try readTurnMetadata(wirePath: wirePath, limits: limits).turns
        guard let first = turns.first else { return ("", "") }
        let last = turns.last
        return (first.startTime, last?.endTime ?? last?.startTime ?? first.startTime)
    }

    private static func readTurnMetadata(
        wirePath: String,
        limits: ParserLimits
    ) throws -> (turns: [TurnMetadata], parseFailure: ParserFailure?) {
        guard JSONLAdapterSupport.fileExists(wirePath) else { return ([], nil) }
        let (objects, failure) = try JSONLAdapterSupport.readObjects(
            locator: wirePath,
            limits: limits,
            reportFailures: true,
            countsTowardMessageLimit: { _ in false }
        )
        if let failure, objects.isEmpty { throw failure }
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
        return (turns, failure)
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
