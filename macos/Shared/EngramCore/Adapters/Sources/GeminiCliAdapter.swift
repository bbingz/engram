import Foundation

enum Phase4AdapterSupport {
    typealias JSONObject = [String: Any]

    static func readJSONObject(locator: String, limits: ParserLimits) throws -> JSONObject {
        let (object, failure) = try readJSONObjectWithMetadata(locator: locator, limits: limits)
        if let failure { throw failure }
        return object
    }

    static func readJSONObjectWithMetadata(
        locator: String,
        limits: ParserLimits,
        beforeIdentityValidation: () -> Void = {}
    ) throws -> (object: JSONObject, parseFailure: ParserFailure?) {
        let (url, before) = try JSONLAdapterSupport.prepareFile(locator: locator, limits: limits)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw ParserFailure.malformedJSON
        }
        beforeIdentityValidation()
        let after: FileIdentity
        do {
            after = try limits.fileIdentity(for: url)
        } catch {
            return (object, .fileModifiedDuringParse)
        }
        let failure: ParserFailure? = limits.isSameFileIdentity(before, after)
            ? nil
            : .fileModifiedDuringParse
        return (object, failure)
    }

    static func readJSONArray(locator: String, limits: ParserLimits) throws -> [JSONObject] {
        let (url, before) = try JSONLAdapterSupport.prepareFile(locator: locator, limits: limits)
        let data = try Data(contentsOf: url)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [JSONObject] else {
            throw ParserFailure.malformedJSON
        }
        let after = try limits.fileIdentity(for: url)
        guard limits.isSameFileIdentity(before, after) else {
            throw ParserFailure.fileModifiedDuringParse
        }
        return array
    }

    static func readJSONArrayPrefix(
        locator: String,
        limits: ParserLimits,
        countsTowardMessageLimit: (JSONObject) -> Bool
    ) throws -> (objects: [JSONObject], exceededMessageLimit: Bool, parseFailure: ParserFailure?) {
        let (url, before) = try JSONLAdapterSupport.prepareFile(locator: locator, limits: limits)
        let bytes = [UInt8](try Data(contentsOf: url))
        guard let arrayStart = bytes.firstIndex(where: { ![9, 10, 13, 32].contains($0) }),
              bytes[arrayStart] == UInt8(ascii: "[")
        else {
            throw ParserFailure.malformedJSON
        }

        var objects: [JSONObject] = []
        var messageCount = 0
        var depth = 1
        var objectStart: Int?
        var inString = false
        var escaped = false
        var closedArray = false
        var exceeded = false

        for index in bytes.indices where index > arrayStart {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            if byte == UInt8(ascii: "\"") {
                inString = true
                continue
            }
            if byte == UInt8(ascii: "{") {
                if depth == 1 { objectStart = index }
                depth += 1
                continue
            }
            if byte == UInt8(ascii: "[") {
                depth += 1
                continue
            }
            if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 1, let start = objectStart {
                    let data = Data(bytes[start...index])
                    let object: JSONObject
                    do {
                        guard let parsed = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
                            throw ParserFailure.malformedJSON
                        }
                        object = parsed
                    } catch {
                        guard !objects.isEmpty else { throw ParserFailure.malformedJSON }
                        return (objects, false, .malformedJSON)
                    }
                    if countsTowardMessageLimit(object) {
                        guard messageCount < limits.maxMessages else {
                            exceeded = true
                            break
                        }
                        messageCount += 1
                    }
                    objects.append(object)
                    objectStart = nil
                }
                continue
            }
            if byte == UInt8(ascii: "]") {
                if depth == 1 {
                    closedArray = true
                    break
                }
                depth -= 1
            }
        }

        let after: FileIdentity
        do {
            after = try limits.fileIdentity(for: url)
        } catch {
            guard !objects.isEmpty else { throw error }
            return (objects, exceeded, .fileModifiedDuringParse)
        }
        if !limits.isSameFileIdentity(before, after) {
            guard !objects.isEmpty else { throw ParserFailure.fileModifiedDuringParse }
            return (objects, exceeded, .fileModifiedDuringParse)
        }
        guard exceeded || closedArray || !objects.isEmpty else { throw ParserFailure.malformedJSON }
        return (objects, exceeded, exceeded || closedArray ? nil : .malformedJSON)
    }

    static func jsonObject(from string: String) -> JSONObject? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSONObject
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func isoFromMilliseconds(_ milliseconds: Double) -> String {
        isoFromSeconds(milliseconds / 1000.0)
    }

    static func isoFromSeconds(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func fileSize(_ path: String) -> Int64 {
        JSONLAdapterSupport.fileSize(locator: path)
    }
}

struct GeminiCliAdapterTestHooks: Sendable {
    var beforeFinalIdentityValidation: @Sendable () -> Void

    init(beforeFinalIdentityValidation: @escaping @Sendable () -> Void = {}) {
        self.beforeFinalIdentityValidation = beforeFinalIdentityValidation
    }
}

final class GeminiCliAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
    private struct MessageLoad: Sendable {
        let messages: [NormalizedMessage]
        let parseFailure: ParserFailure?
        let hasMoreMessages: Bool
    }

    let source: SourceName = .geminiCli
    private let tmpRoot: URL
    private let projectsFile: URL
    private let limits: ParserLimits
    private let messageCache = ParsedTranscriptCache()
    private let testHooks: GeminiCliAdapterTestHooks

    init(
        tmpRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp")
            .path,
        projectsFile: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/projects.json")
            .path,
        limits: ParserLimits = .default,
        testHooks: GeminiCliAdapterTestHooks = GeminiCliAdapterTestHooks()
    ) {
        self.tmpRoot = URL(fileURLWithPath: tmpRoot)
        self.projectsFile = URL(fileURLWithPath: projectsFile)
        self.limits = limits
        self.testHooks = testHooks
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(tmpRoot)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for projectURL in JSONLAdapterSupport.directChildren(of: tmpRoot)
            where JSONLAdapterSupport.isDirectory(projectURL)
        {
            let chatsURL = projectURL.appendingPathComponent("chats")
            guard JSONLAdapterSupport.isDirectory(chatsURL) else { continue }
            for fileURL in JSONLAdapterSupport.directChildren(of: chatsURL)
                where !fileURL.lastPathComponent.hasSuffix(".engram.json") &&
                (fileURL.pathExtension == "json" || fileURL.pathExtension == "jsonl")
            {
                locators.append(fileURL.path)
            }
        }
        return locators.sorted()
    }

    // Audit ADAPTER-GEMINI-001: sidecar-only create/modify must stay in the recent
    // set even when the transcript locator mtime is unchanged.
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
            let (object, failure) = try Self.readSession(
                locator: locator,
                limits: limits,
                beforeIdentityValidation: testHooks.beforeFinalIdentityValidation
            )
            guard let sessionId = JSONLAdapterSupport.string(object["sessionId"]),
                  let startTime = JSONLAdapterSupport.string(object["startTime"]),
                  let messages = JSONLAdapterSupport.array(object["messages"])
            else {
                return .failure(.malformedJSON)
            }

            let normalizedMessages = messages
                .compactMap { JSONLAdapterSupport.object($0) }
                .flatMap(Self.messages(from:))
            if let failure {
                guard failure == .fileModifiedDuringParse, !normalizedMessages.isEmpty else {
                    return .failure(failure)
                }
            }
            let userMessages = normalizedMessages.filter { $0.role == .user }
            let assistantMessages = normalizedMessages.filter { $0.role == .assistant }
            let toolMessages = normalizedMessages.filter { $0.role == .tool }
            let projectName = Self.projectName(from: locator)
            let cwd = resolveProjectRoot(projectName: projectName) ??
                resolveProject(projectName: projectName) ?? ""
            let firstUserText = userMessages.first?.content ?? ""
            let sidecar = Self.readSidecar(locator: locator, sessionId: sessionId, limits: limits)
            let originator = JSONLAdapterSupport.string(sidecar?["originator"])
            // R184-3: metadata-only / empty-content Gemini files must not become
            // zero-count browsable sessions. Terminal, same as Claude/Qwen.
            guard userMessages.count + assistantMessages.count + toolMessages.count > 0 else {
                return .failure(.noVisibleMessages)
            }
            if normalizedMessages.count > limits.maxMessages {
                return .failure(.messageLimitExceeded)
            }

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .geminiCli,
                    startTime: startTime,
                    endTime: JSONLAdapterSupport.string(object["lastUpdated"]),
                    cwd: cwd,
                    project: projectName,
                    model: nil,
                    messageCount: userMessages.count + assistantMessages.count + toolMessages.count,
                    userMessageCount: userMessages.count,
                    assistantMessageCount: assistantMessages.count,
                    toolMessageCount: toolMessages.count,
                    systemMessageCount: 0,
                    summary: firstUserText.isEmpty ? nil : firstUserText,
                    filePath: locator,
                    sizeBytes: Phase4AdapterSupport.fileSize(locator),
                    indexedAt: nil,
                    agentRole: OriginatorClassifier.isClaudeCode(originator) ? "dispatched" : nil,
                    originator: originator,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: Self.validatedSidecarParentSessionId(
                        sessionId: sessionId,
                        raw: JSONLAdapterSupport.string(sidecar?["parentSessionId"])
                    ),
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
        let load = try await loadMessages(locator: locator)
        if options.limit == nil, load.hasMoreMessages || load.messages.count > limits.maxMessages {
            throw ParserFailure.messageLimitExceeded
        }
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(load.messages, options: options))
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        if URL(fileURLWithPath: locator).pathExtension == "jsonl" {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: { _ in false }
            )
            let session = Self.replayJSONLSession(objects)
            let bounded = Self.boundedMessages(
                from: JSONLAdapterSupport.array(session["messages"]) ?? [],
                maxMessages: limits.maxMessages
            )
            return JSONLAdapterSupport.stream(
                JSONLAdapterSupport.boundedWindowWithMetadata(
                    bounded.messages,
                    options: options,
                    maxMessages: limits.maxMessages,
                    hasMoreMessages: bounded.exceededMessageLimit,
                    parseFailure: failure
                )
            )
        }

        let load = try await loadMessages(locator: locator)
        return JSONLAdapterSupport.stream(
            JSONLAdapterSupport.boundedWindowWithMetadata(
                load.messages,
                options: options,
                maxMessages: limits.maxMessages,
                hasMoreMessages: load.hasMoreMessages,
                parseFailure: load.parseFailure == .messageLimitExceeded ? nil : load.parseFailure
            )
        )
    }

    private func loadMessages(locator: String) async throws -> MessageLoad {
        let signature = ParsedTranscriptCache.Signature.forFile(locator)
        if let cached = await messageCache.cached(locator: locator, signature: signature) {
            return MessageLoad(messages: cached, parseFailure: nil, hasMoreMessages: false)
        }
        let (object, parseFailure) = try Self.readSession(
            locator: locator,
            limits: limits,
            beforeIdentityValidation: testHooks.beforeFinalIdentityValidation
        )
        let bounded = Self.boundedMessages(
            from: JSONLAdapterSupport.array(object["messages"]) ?? [],
            maxMessages: limits.maxMessages
        )
        let hasMoreMessages = bounded.exceededMessageLimit || parseFailure == .messageLimitExceeded
        if parseFailure == nil, !hasMoreMessages {
            await messageCache.store(locator: locator, signature: signature, messages: bounded.messages)
        }
        return MessageLoad(
            messages: bounded.messages,
            parseFailure: parseFailure,
            hasMoreMessages: hasMoreMessages
        )
    }

    private static func boundedMessages(
        from objects: [Any],
        maxMessages: Int
    ) -> (messages: [NormalizedMessage], exceededMessageLimit: Bool) {
        let cap = max(maxMessages, 0)
        var messages: [NormalizedMessage] = []
        for object in objects.compactMap({ JSONLAdapterSupport.object($0) }) {
            for message in Self.messages(from: object) {
                guard messages.count < cap else {
                    return (messages, true)
                }
                messages.append(message)
            }
        }
        return (messages, false)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private func resolveProject(projectName: String) -> String? {
        guard let data = try? Data(contentsOf: projectsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? Phase4AdapterSupport.JSONObject
        else {
            return nil
        }
        let rawProjects = JSONLAdapterSupport.object(object["projects"]) ?? object
        let matches = rawProjects.compactMap { cwd, value in
            JSONLAdapterSupport.string(value) == projectName ? cwd : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func resolveProjectRoot(projectName: String) -> String? {
        let rootURL = tmpRoot
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent(".project_root")
        guard let content = try? String(contentsOf: rootURL, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func projectName(from locator: String) -> String {
        let components = URL(fileURLWithPath: locator).pathComponents
        guard let chatsIndex = components.firstIndex(of: "chats"), chatsIndex > 0 else {
            return ""
        }
        return components[chatsIndex - 1]
    }

    private static func readSidecar(
        locator: String,
        sessionId: String,
        limits: ParserLimits
    ) -> Phase4AdapterSupport.JSONObject? {
        let sidecarURL = URL(fileURLWithPath: locator)
            .deletingLastPathComponent()
            .appendingPathComponent("\(sessionId).engram.json")
        return try? Phase4AdapterSupport.readJSONObject(locator: sidecarURL.path, limits: limits)
    }

    /// Sidecar naming matches `readSidecar`: `{sessionId}.engram.json`.
    /// Prefer a cheap peek of the transcript's sessionId so stem≠id files
    /// (e.g. session-sample.json → gemini-session-001.engram.json) still track
    /// sidecar content-only rewrites. Fall back to the transcript stem when
    /// peek fails. Parent directory mtime covers create/delete either way.
    private static func expectedSidecarPath(locator: String) -> String {
        let sessionId = peekSessionId(locator: locator)
            ?? URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent
        return URL(fileURLWithPath: locator)
            .deletingLastPathComponent()
            .appendingPathComponent("\(sessionId).engram.json")
            .path
    }

    /// Read only the leading bytes for `"sessionId"` — enough for composite
    /// mtime without a full message-array parse. An 8 KiB cutoff can land mid
    /// multibyte UTF-8 scalar; drop an incomplete trailing sequence so a
    /// valid leading `sessionId` still peeks when stem≠id.
    private static func peekSessionId(locator: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: locator) else { return nil }
        defer { try? handle.close() }
        var prefix = handle.readData(ofLength: 8_192)
        guard !prefix.isEmpty else { return nil }
        // An 8 KiB cut can land mid multibyte scalar (1–3 trailing bytes
        // incomplete). Strict String(data:) then returns nil for the whole
        // prefix; drop at most three trailing bytes to recover a valid stem.
        for _ in 0..<3 where String(data: prefix, encoding: .utf8) == nil {
            if prefix.isEmpty { break }
            prefix.removeLast()
        }
        guard let text = String(data: prefix, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: #"\"sessionId\"\s*:\s*\"([^\"]+)\""#,
            options: []
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let idRange = Range(match.range(at: 1), in: text)
        else { return nil }
        let sessionId = String(text[idRange])
        return sessionId.isEmpty ? nil : sessionId
    }

    private static func compositeInputPaths(locator: String) -> [String] {
        [
            locator,
            expectedSidecarPath(locator: locator),
            URL(fileURLWithPath: locator).deletingLastPathComponent().path,
        ]
    }

    private static func compositeModificationDate(
        locator: String,
        fileManager: FileManager
    ) -> Date? {
        compositeInputPaths(locator: locator).compactMap { path in
            guard fileManager.fileExists(atPath: path) else { return nil }
            return try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
        }
        .max()
    }

    /// M23: never promote empty/self sidecar parent ids to confirmed links
    /// (would hide the session forever on top-level surfaces).
    static func validatedSidecarParentSessionId(sessionId: String, raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != sessionId else { return nil }
        return trimmed
    }

    private static func readSession(
        locator: String,
        limits: ParserLimits,
        beforeIdentityValidation: () -> Void = {}
    ) throws -> (Phase4AdapterSupport.JSONObject, ParserFailure?) {
        if URL(fileURLWithPath: locator).pathExtension == "jsonl" {
            return try readJSONLSession(locator: locator, limits: limits)
        }
        return try Phase4AdapterSupport.readJSONObjectWithMetadata(
            locator: locator,
            limits: limits,
            beforeIdentityValidation: beforeIdentityValidation
        )
    }

    private static func readJSONLSession(
        locator: String,
        limits: ParserLimits
    ) throws -> (Phase4AdapterSupport.JSONObject, ParserFailure?) {
        let (objects, failure) = try JSONLAdapterSupport.readObjects(
            locator: locator,
            limits: limits,
            reportFailures: true,
            countsTowardMessageLimit: { !Self.messages(from: $0).isEmpty }
        )
        return (replayJSONLSession(objects), failure)
    }

    private static func replayJSONLSession(
        _ objects: [JSONLAdapterSupport.JSONObject]
    ) -> Phase4AdapterSupport.JSONObject {
        var metadata: Phase4AdapterSupport.JSONObject = [:]
        var messages: [Phase4AdapterSupport.JSONObject] = []
        for object in objects {
            if let update = JSONLAdapterSupport.object(object["$set"]) {
                for (key, value) in update { metadata[key] = value }
                if let updatedMessages = JSONLAdapterSupport.array(update["messages"]) {
                    messages = updatedMessages.compactMap { JSONLAdapterSupport.object($0) }
                }
                continue
            }
            if let rewindTo = JSONLAdapterSupport.string(object["$rewindTo"]) {
                if let index = messages.firstIndex(where: { JSONLAdapterSupport.string($0["id"]) == rewindTo }) {
                    messages = Array(messages.prefix(index + 1))
                }
                continue
            }
            if JSONLAdapterSupport.string(object["type"]) != nil {
                messages.append(object)
                continue
            }
            for (key, value) in object { metadata[key] = value }
            if let initialMessages = JSONLAdapterSupport.array(object["messages"]) {
                messages = initialMessages.compactMap { JSONLAdapterSupport.object($0) }
            }
        }
        metadata["messages"] = messages
        return metadata
    }

    private static func messages(from object: Phase4AdapterSupport.JSONObject) -> [NormalizedMessage] {
        var messages: [NormalizedMessage] = []
        if let message = conversationMessage(from: object) {
            messages.append(message)
        }
        messages.append(contentsOf: toolMessages(from: object))
        return messages
    }

    private static func conversationMessage(
        from object: Phase4AdapterSupport.JSONObject
    ) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user" || type == "gemini" || type == "model"
        else {
            return nil
        }
        let content = extractText(object["content"])
        guard !content.isEmpty else { return nil }
        return NormalizedMessage(
            role: type == "user" ? .user : .assistant,
            content: content,
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: nil,
            usage: type == "user" ? nil : usage(from: JSONLAdapterSupport.object(object["tokens"]))
        )
    }

    private static func toolMessages(
        from object: Phase4AdapterSupport.JSONObject
    ) -> [NormalizedMessage] {
        toolEvents(from: object).map { event in
            NormalizedMessage(
                role: .tool,
                content: event.content,
                timestamp: event.timestamp,
                toolCalls: [event.call],
                usage: nil
            )
        }
    }

    private static func toolEvents(
        from object: Phase4AdapterSupport.JSONObject
    ) -> [(call: NormalizedToolCall, content: String, timestamp: String?)] {
        let type = JSONLAdapterSupport.string(object["type"])
        let messageTimestamp = JSONLAdapterSupport.string(object["timestamp"])

        if type == "gemini" || type == "model" {
            let persisted = persistedToolEvents(
                from: object["toolCalls"],
                messageTimestamp: messageTimestamp
            )
            if !persisted.isEmpty { return persisted }

            let inline = inlineFunctionCallEvents(
                from: object["content"],
                timestamp: messageTimestamp
            )
            if !inline.isEmpty { return inline }
        }

        guard type == "info" else { return [] }
        let content = extractText(object["content"])
        let prefix = "Tool call:"
        guard content.hasPrefix(prefix) else { return [] }
        let name = content.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        return [(
            call: NormalizedToolCall(name: name),
            content: content,
            timestamp: messageTimestamp
        )]
    }

    private static func persistedToolEvents(
        from value: Any?,
        messageTimestamp: String?
    ) -> [(call: NormalizedToolCall, content: String, timestamp: String?)] {
        guard let rawCalls = JSONLAdapterSupport.array(value) else { return [] }
        return rawCalls.compactMap { item in
            guard let object = JSONLAdapterSupport.object(item),
                  let name = JSONLAdapterSupport.string(object["name"]),
                  !name.isEmpty
            else {
                return nil
            }
            let output = toolOutput(from: object)
            let content = output ?? "Tool call: \(name)"
            return (
                call: NormalizedToolCall(
                    name: name,
                    input: object["args"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) },
                    output: output
                ),
                content: content,
                timestamp: JSONLAdapterSupport.string(object["timestamp"]) ?? messageTimestamp
            )
        }
    }

    private static func inlineFunctionCallEvents(
        from content: Any?,
        timestamp: String?
    ) -> [(call: NormalizedToolCall, content: String, timestamp: String?)] {
        guard let parts = JSONLAdapterSupport.array(content) else { return [] }
        return parts.compactMap { item in
            guard let part = JSONLAdapterSupport.object(item),
                  let functionCall = JSONLAdapterSupport.object(part["functionCall"]),
                  let name = JSONLAdapterSupport.string(functionCall["name"]),
                  !name.isEmpty
            else {
                return nil
            }
            return (
                call: NormalizedToolCall(
                    name: name,
                    input: functionCall["args"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) }
                ),
                content: "Tool call: \(name)",
                timestamp: timestamp
            )
        }
    }

    private static func toolOutput(from toolCall: Phase4AdapterSupport.JSONObject) -> String? {
        if let display = JSONLAdapterSupport.string(toolCall["resultDisplay"]), !display.isEmpty {
            return display
        }
        guard let results = JSONLAdapterSupport.array(toolCall["result"]) else { return nil }
        for item in results {
            guard let result = JSONLAdapterSupport.object(item),
                  let functionResponse = JSONLAdapterSupport.object(result["functionResponse"]),
                  let response = JSONLAdapterSupport.object(functionResponse["response"])
            else {
                continue
            }
            if let output = JSONLAdapterSupport.string(response["output"]), !output.isEmpty {
                return output
            }
            if let serialized = JSONLAdapterSupport.jsonString(response, limit: 2_000), !serialized.isEmpty {
                return serialized
            }
        }
        return nil
    }

    private static func usage(from tokens: Phase4AdapterSupport.JSONObject?) -> TokenUsage? {
        guard let tokens else { return nil }
        let input = int(tokens["input"])
        let cached = int(tokens["cached"])
        let output = int(tokens["output"]) + int(tokens["thoughts"]) + int(tokens["tool"])
        let usage = TokenUsage(
            inputTokens: max(input - cached, 0),
            outputTokens: output,
            cacheReadTokens: cached,
            cacheCreationTokens: 0
        )
        guard usage.inputTokens > 0
            || usage.outputTokens > 0
            || (usage.cacheReadTokens ?? 0) > 0
        else {
            return nil
        }
        return usage
    }

    private static func int(_ value: Any?) -> Int {
        Int(Phase4AdapterSupport.int64(value) ?? 0)
    }

    private static func extractText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let parts = JSONLAdapterSupport.array(content) else { return "" }
        return parts.compactMap { item in
            JSONLAdapterSupport.string(JSONLAdapterSupport.object(item)?["text"])
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}
