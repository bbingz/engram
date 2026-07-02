import Darwin
import Foundation

enum JSONLAdapterSupport {
    typealias JSONObject = [String: Any]

    static func fileExists(_ path: String) -> Bool {
        statMode(path) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        statMode(url.path) == S_IFDIR
    }

    static func directChildren(of url: URL, includingHidden: Bool = false) -> [URL] {
        guard isDirectory(url) else { return [] }
        let root = url.resolvingSymlinksInPath()
        let options: FileManager.DirectoryEnumerationOptions = includingHidden ? [] : [.skipsHiddenFiles]
        return (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ))?
            .filter { !isSymlink($0) }
            .sorted { $0.path < $1.path } ?? []
    }

    static func recursiveFiles(under root: URL, matching predicate: (URL) -> Bool) -> [String] {
        guard isDirectory(root) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath()
        // Deliberately skip hidden files and directories. Real session trees
        // (Codex `rollout-*.jsonl`, Gemini `chats/`, Claude `subagents/`) never
        // store sessions in dotfiles or dotdirs, whereas hidden entries (.git,
        // .DS_Store, editor/VCS caches) are pure noise. NOTE: the TS reference
        // recursion does NOT skip hidden — that is the divergent side and should
        // be brought in line with this behavior, not the reverse.
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [String] = []
        for case let url as URL in enumerator where isRegularFile(url) && predicate(url) {
            files.append(url.path)
        }
        return files.sorted()
    }

    static func prepareFile(locator: String, limits: ParserLimits) throws -> (URL, FileIdentity) {
        let url = URL(fileURLWithPath: locator)
        guard isRegularFile(url) else {
            throw ParserFailure.fileMissing
        }
        let identity = try limits.fileIdentity(for: url)
        if let failure = limits.validateFileSize(identity) {
            throw failure
        }
        return (url, identity)
    }

    static func readString(
        locator: String,
        limits: ParserLimits,
        encoding: String.Encoding = .utf8
    ) throws -> String {
        let (url, before) = try prepareFile(locator: locator, limits: limits)
        let content = try String(contentsOf: url, encoding: encoding)
        let after = try limits.fileIdentity(for: url)
        guard limits.isSameFileIdentity(before, after) else {
            throw ParserFailure.fileModifiedDuringParse
        }
        return content
    }

    static func readObjects(
        locator: String,
        limits: ParserLimits,
        reportFailures: Bool = false
    ) throws -> ([JSONObject], ParserFailure?) {
        try autoreleasepool {
            let (url, before) = try prepareFile(locator: locator, limits: limits)
            let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
            var objects: [JSONObject] = []
            var exceededMessageLimit = false

            for line in try reader.readLines() {
                guard let object = parseObject(line) else { continue }
                guard objects.count < limits.maxMessages else {
                    exceededMessageLimit = true
                    continue
                }
                objects.append(object)
            }

            let after = try limits.fileIdentity(for: url)
            guard limits.isSameFileIdentity(before, after) else {
                return (objects, .fileModifiedDuringParse)
            }
            if reportFailures, let failure = reader.failures.first {
                return (objects, failure)
            }
            if reportFailures, exceededMessageLimit {
                return (objects, .messageLimitExceeded)
            }
            return (objects, nil)
        }
    }

    static func parseObject(_ line: String) -> JSONObject? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSONObject
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func object(_ value: Any?) -> JSONObject? {
        value as? JSONObject
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func jsonString(_ value: Any, limit: Int? = nil) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        guard let limit else { return string }
        return String(string.prefix(limit))
    }

    static func fileSize(locator: String) -> Int64 {
        var info = stat()
        guard lstat(locator, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return 0
        }
        return Int64(info.st_size)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        lstatMode(url.path) == S_IFLNK
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        lstatMode(url.path) == S_IFREG
    }

    private static func lstatMode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private static func statMode(_ path: String) -> mode_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func stream(_ messages: [NormalizedMessage]) -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { continuation in
            for message in messages {
                continuation.yield(message)
            }
            continuation.finish()
        }
    }

    static func applyWindow(
        _ messages: [NormalizedMessage],
        options: StreamMessagesOptions
    ) -> [NormalizedMessage] {
        let offset = max(options.offset ?? 0, 0)
        let suffix = offset >= messages.count ? [] : Array(messages.dropFirst(offset))
        guard let limit = options.limit else { return suffix }
        return Array(suffix.prefix(max(limit, 0)))
    }

    /// Window a per-line JSONL transcript with offset/limit, mapping each line
    /// through `transform`.
    ///
    /// When `options.limit` is set, this reads line by line and STOPS as soon as
    /// it has skipped `offset` produced messages and collected `limit` of them —
    /// so a paged read costs O(offset + limit) parsed lines, not O(file). This is
    /// what makes the Web UI pager O(N) per page instead of O(N) re-parses per
    /// page (O(N²) overall). When `limit` is nil (whole-transcript request) it
    /// falls back to `readObjects` (preserving the message-cap and during-parse
    /// file-identity failure semantics) and windows in memory.
    ///
    /// `offset`/`limit` count PRODUCED messages (post-`transform`, nils skipped),
    /// matching `applyWindow` exactly. `transform` must be a pure per-line mapping
    /// with no cross-line state; adapters that carry state across lines (Kimi) or
    /// parse the whole document at once (VS Code / Gemini / Cline / SQLite) must
    /// not use this helper.
    static func windowedMessages(
        locator: String,
        options: StreamMessagesOptions,
        limits: ParserLimits,
        transform: (JSONObject) -> NormalizedMessage?
    ) throws -> [NormalizedMessage] {
        guard let limit = options.limit else {
            let (objects, failure) = try readObjects(locator: locator, limits: limits, reportFailures: true)
            if let failure { throw failure }
            return applyWindow(objects.compactMap(transform), options: options)
        }

        let cappedLimit = max(limit, 0)
        guard cappedLimit > 0 else { return [] }
        let offset = max(options.offset ?? 0, 0)

        return try autoreleasepool {
            let (url, _) = try prepareFile(locator: locator, limits: limits)
            let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
            var skipped = 0
            var messages: [NormalizedMessage] = []

            for line in try reader.readLines() {
                guard let object = parseObject(line), let message = transform(object) else { continue }
                if skipped < offset {
                    skipped += 1
                    continue
                }
                messages.append(message)
                if messages.count >= cappedLimit { break }
            }

            if let failure = reader.failures.first { throw failure }
            return messages
        }
    }

    static func usage(from rawUsage: JSONObject?) -> TokenUsage? {
        guard let rawUsage else { return nil }
        return TokenUsage(
            inputTokens: rawUsage["input_tokens"] as? Int ?? 0,
            outputTokens: rawUsage["output_tokens"] as? Int ?? 0,
            cacheReadTokens: rawUsage["cache_read_input_tokens"] as? Int,
            cacheCreationTokens: rawUsage["cache_creation_input_tokens"] as? Int
        )
    }
}

final class CodexAdapter: SessionAdapter, Sendable {
    let source: SourceName = .codex
    private let sessionRoots: [URL]
    private let limits: ParserLimits

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionRoots = Self.expandSessionRoots(URL(fileURLWithPath: sessionsRoot))
        self.limits = limits
    }

    func detect() async -> Bool {
        sessionRoots.contains { JSONLAdapterSupport.isDirectory($0) }
    }

    func listSessionLocators() async throws -> [String] {
        sessionRoots
            .flatMap { root in
                JSONLAdapterSupport.recursiveFiles(under: root) { url in
                    url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl"
                }
            }
            .sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { return .failure(failure) }

            var meta: JSONLAdapterSupport.JSONObject?
            var userCount = 0
            var assistantCount = 0
            var toolCount = 0
            var systemCount = 0
            var firstUserText = ""
            var lastTimestamp = ""
            var detectedModel: String?
            var turnContextModel: String?

            for object in objects {
                if let timestamp = JSONLAdapterSupport.string(object["timestamp"]) {
                    lastTimestamp = timestamp
                }

                if JSONLAdapterSupport.string(object["type"]) == "session_meta", meta == nil {
                    meta = JSONLAdapterSupport.object(object["payload"])
                }

                if JSONLAdapterSupport.string(object["type"]) == "turn_context",
                   turnContextModel == nil,
                   let payload = JSONLAdapterSupport.object(object["payload"]),
                   let model = JSONLAdapterSupport.string(payload["model"]) {
                    turnContextModel = model
                }

                guard JSONLAdapterSupport.string(object["type"]) == "response_item",
                      let payload = JSONLAdapterSupport.object(object["payload"])
                else {
                    continue
                }

                if detectedModel == nil, let model = JSONLAdapterSupport.string(payload["model"]) {
                    detectedModel = model
                }

                let payloadType = JSONLAdapterSupport.string(payload["type"])
                if payloadType == "message", JSONLAdapterSupport.string(payload["role"]) == "user" {
                    let rawText = Self.extractText(JSONLAdapterSupport.array(payload["content"]))
                    let normalized = Self.normalizeUserText(rawText)
                    if normalized.strippedSystemContent {
                        systemCount += 1
                    }
                    if let text = normalized.userText {
                        userCount += 1
                        if firstUserText.isEmpty { firstUserText = text }
                    } else if !normalized.strippedSystemContent, Self.isSystemInjection(rawText) {
                        systemCount += 1
                    }
                } else if payloadType == "message", JSONLAdapterSupport.string(payload["role"]) == "assistant" {
                    assistantCount += 1
                } else if payloadType == "function_call" {
                    // Count a tool invocation once. The paired `function_call_output`
                    // is the result of the same call, not a separate tool message.
                    toolCount += 1
                }
            }

            guard let meta,
                  let id = JSONLAdapterSupport.string(meta["id"]),
                  let startTime = JSONLAdapterSupport.string(meta["timestamp"])
            else {
                return .failure(.malformedJSON)
            }

            let explicitRole = JSONLAdapterSupport.string(meta["agent_role"])
            let originator = JSONLAdapterSupport.string(meta["originator"])
            let effectiveRole = explicitRole ?? (OriginatorClassifier.isClaudeCode(originator) ? "dispatched" : nil)
            return .success(
                NormalizedSessionInfo(
                    id: id,
                    source: .codex,
                    startTime: startTime,
                    endTime: lastTimestamp.isEmpty ? nil : lastTimestamp,
                    cwd: JSONLAdapterSupport.string(meta["cwd"]) ?? "",
                    project: nil,
                    model: detectedModel ?? turnContextModel ?? JSONLAdapterSupport.string(meta["model"]),
                    messageCount: userCount + assistantCount + toolCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: toolCount,
                    systemMessageCount: systemCount,
                    summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                    filePath: locator,
                    sizeBytes: JSONLAdapterSupport.fileSize(locator: locator),
                    indexedAt: nil,
                    agentRole: effectiveRole,
                    originator: originator,
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
        let messages = try Self.messages(
            locator: locator,
            options: options,
            limits: limits
        )
        return JSONLAdapterSupport.stream(messages)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func expandSessionRoots(_ root: URL) -> [URL] {
        guard root.lastPathComponent == "sessions" else { return [root] }
        return [
            root,
            root.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)
        ]
    }

    private static func messages(
        locator: String,
        options: StreamMessagesOptions,
        limits: ParserLimits
    ) throws -> [NormalizedMessage] {
        let cappedLimit = options.limit.map { max($0, 0) } ?? Int.max
        guard cappedLimit > 0 else { return [] }
        let offset = max(options.offset ?? 0, 0)

        return try autoreleasepool {
            let (url, before) = try JSONLAdapterSupport.prepareFile(locator: locator, limits: limits)
            let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
            var parsedObjects = 0
            var skipped = 0
            var messages: [NormalizedMessage] = []
            var pendingMessage: NormalizedMessage?
            var pendingUsageCameFromTokenCount = false
            var pendingUsage: TokenUsage?

            func appendWindowed(_ message: NormalizedMessage) -> Bool {
                if skipped < offset {
                    skipped += 1
                    return false
                }
                messages.append(message)
                return messages.count >= cappedLimit
            }

            func flushPendingMessage() -> Bool {
                guard let message = pendingMessage else { return false }
                pendingMessage = nil
                pendingUsageCameFromTokenCount = false
                return appendWindowed(message)
            }

            for line in try reader.readLines() {
                guard let object = JSONLAdapterSupport.parseObject(line) else { continue }
                parsedObjects += 1
                if options.limit == nil, parsedObjects > limits.maxMessages {
                    throw ParserFailure.messageLimitExceeded
                }

                if let tokenUsage = tokenCountUsage(from: object) {
                    if var message = pendingMessage, message.role != .user {
                        if pendingUsageCameFromTokenCount || message.usage == nil {
                            message.usage = mergeUsage(message.usage, tokenUsage)
                            pendingUsageCameFromTokenCount = true
                            pendingMessage = message
                        }
                    } else {
                        pendingUsage = mergeUsage(pendingUsage, tokenUsage)
                    }
                    continue
                }

                guard var message = message(from: object) else { continue }
                if flushPendingMessage() { break }
                if message.role != .user, let usage = pendingUsage {
                    if message.usage == nil {
                        message.usage = usage
                    }
                    pendingUsage = nil
                }
                pendingMessage = message
                pendingUsageCameFromTokenCount = false
            }

            if messages.count < cappedLimit {
                _ = flushPendingMessage()
            }

            if let failure = reader.failures.first { throw failure }
            if options.limit == nil {
                let after = try limits.fileIdentity(for: url)
                guard limits.isSameFileIdentity(before, after) else {
                    throw ParserFailure.fileModifiedDuringParse
                }
            }
            return messages
        }
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard JSONLAdapterSupport.string(object["type"]) == "response_item",
              let payload = JSONLAdapterSupport.object(object["payload"])
        else { return nil }

        let timestamp = JSONLAdapterSupport.string(object["timestamp"])
        switch JSONLAdapterSupport.string(payload["type"]) {
        case "message":
            guard let rawRole = JSONLAdapterSupport.string(payload["role"]),
                  rawRole == "user" || rawRole == "assistant"
            else { return nil }
            let role: NormalizedMessageRole = rawRole == "user" ? .user : .assistant
            let rawText = extractText(JSONLAdapterSupport.array(payload["content"]))
            let content: String
            if role == .user {
                guard let userText = normalizeUserText(rawText).userText else { return nil }
                content = userText
            } else {
                content = rawText
            }
            return NormalizedMessage(
                role: role,
                content: content,
                timestamp: timestamp,
                toolCalls: nil,
                usage: role == .assistant ? JSONLAdapterSupport.usage(from: JSONLAdapterSupport.object(payload["usage"])) : nil
            )
        case "function_call":
            let name = JSONLAdapterSupport.string(payload["name"]) ?? ""
            let arguments = payload["arguments"].flatMap { JSONLAdapterSupport.jsonString($0, limit: 500) } ?? ""
            return NormalizedMessage(
                role: .tool,
                content: arguments.isEmpty ? name : "\(name) \(arguments)",
                timestamp: timestamp,
                toolCalls: [NormalizedToolCall(name: name, input: arguments.isEmpty ? nil : arguments)]
            )
        case "function_call_output":
            let content: String
            if let output = JSONLAdapterSupport.string(payload["output"]) {
                content = output
            } else if let output = payload["output"],
                      let json = JSONLAdapterSupport.jsonString(output, limit: 2000) {
                content = json
            } else {
                content = ""
            }
            return NormalizedMessage(role: .tool, content: content, timestamp: timestamp)
        default:
            return nil
        }
    }

    private static func tokenCountUsage(from object: JSONLAdapterSupport.JSONObject) -> TokenUsage? {
        guard JSONLAdapterSupport.string(object["type"]) == "event_msg",
              let payload = JSONLAdapterSupport.object(object["payload"]),
              JSONLAdapterSupport.string(payload["type"]) == "token_count",
              let info = JSONLAdapterSupport.object(payload["info"]),
              let usage = JSONLAdapterSupport.object(info["last_token_usage"])
        else {
            return nil
        }

        let inputTokens = int(usage["input_tokens"])
        let cachedInputTokens = int(usage["cached_input_tokens"])
        let outputTokens = int(usage["output_tokens"])
        let tokenUsage = TokenUsage(
            inputTokens: max(inputTokens - cachedInputTokens, 0),
            outputTokens: outputTokens,
            cacheReadTokens: cachedInputTokens,
            cacheCreationTokens: 0
        )
        guard tokenUsage.inputTokens > 0
            || tokenUsage.outputTokens > 0
            || (tokenUsage.cacheReadTokens ?? 0) > 0
            || (tokenUsage.cacheCreationTokens ?? 0) > 0
        else {
            return nil
        }
        return tokenUsage
    }

    private static func mergeUsage(_ lhs: TokenUsage?, _ rhs: TokenUsage) -> TokenUsage {
        guard let lhs else { return rhs }
        return TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: (lhs.cacheReadTokens ?? 0) + (rhs.cacheReadTokens ?? 0),
            cacheCreationTokens: (lhs.cacheCreationTokens ?? 0) + (rhs.cacheCreationTokens ?? 0)
        )
    }

    private static func int(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        text.hasPrefix("# AGENTS.md instructions for ") ||
            text.contains("<INSTRUCTIONS>") ||
            text.hasPrefix("<local-command-caveat>") ||
            text.hasPrefix("<environment_context>")
    }

    private static func normalizeUserText(_ text: String) -> (userText: String?, strippedSystemContent: Bool) {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = false

        if remaining.hasPrefix("# AGENTS.md instructions for ") || remaining.hasPrefix("<INSTRUCTIONS>") {
            if let end = remaining.range(of: "</INSTRUCTIONS>") {
                remaining = String(remaining[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
            }
        }

        var removedBlock = true
        while removedBlock {
            removedBlock = false
            for tag in ["local-command-caveat", "environment_context", "skills_instructions", "plugins_instructions"] {
                let open = "<\(tag)>"
                let close = "</\(tag)>"
                if remaining.hasPrefix(open), let end = remaining.range(of: close) {
                    remaining = String(remaining[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    stripped = true
                    removedBlock = true
                }
            }
        }

        guard !remaining.isEmpty else {
            return (nil, stripped || isSystemInjection(text))
        }
        if !stripped, isSystemInjection(remaining) {
            return (nil, true)
        }
        return (remaining, stripped)
    }

    private static func extractText(_ content: [Any]?) -> String {
        guard let content else { return "" }
        var parts: [String] = []
        for item in content {
            guard let object = JSONLAdapterSupport.object(item) else { continue }
            if let text = JSONLAdapterSupport.string(object["text"]), !text.isEmpty {
                parts.append(text)
            } else if let inputText = JSONLAdapterSupport.string(object["input_text"]), !inputText.isEmpty {
                parts.append(inputText)
            } else if let outputText = JSONLAdapterSupport.string(object["output_text"]), !outputText.isEmpty {
                parts.append(outputText)
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
