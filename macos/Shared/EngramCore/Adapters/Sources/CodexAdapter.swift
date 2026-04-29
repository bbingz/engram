import Foundation

enum JSONLAdapterSupport {
    typealias JSONObject = [String: Any]

    static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func directChildren(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.sorted { $0.path < $1.path } ?? []
    }

    static func recursiveFiles(under root: URL, matching predicate: (URL) -> Bool) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [String] = []
        for case let url as URL in enumerator where predicate(url) {
            files.append(url.path)
        }
        return files.sorted()
    }

    static func prepareFile(locator: String, limits: ParserLimits) throws -> (URL, FileIdentity) {
        let url = URL(fileURLWithPath: locator)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParserFailure.fileMissing
        }
        let identity = try limits.fileIdentity(for: url)
        if let failure = limits.validateFileSize(identity) {
            throw failure
        }
        return (url, identity)
    }

    static func readObjects(locator: String, limits: ParserLimits) throws -> ([JSONObject], ParserFailure?) {
        let (url, before) = try prepareFile(locator: locator, limits: limits)
        let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
        var objects: [JSONObject] = []

        for line in try reader.readLines() {
            guard let object = parseObject(line) else { continue }
            objects.append(object)
            if objects.count > limits.maxMessages {
                return (objects, .messageLimitExceeded)
            }
        }

        if let failure = reader.failures.first {
            return (objects, failure)
        }

        let after = try limits.fileIdentity(for: url)
        guard limits.isSameFileIdentity(before, after) else {
            return (objects, .fileModifiedDuringParse)
        }

        return (objects, nil)
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
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        guard let limit else { return string }
        return String(string.prefix(limit))
    }

    static func fileSize(locator: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: locator)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
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

final class CodexAdapter: SessionAdapter {
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
            var systemCount = 0
            var firstUserText = ""
            var lastTimestamp = ""

            for object in objects {
                if JSONLAdapterSupport.string(object["type"]) == "session_meta", meta == nil {
                    meta = JSONLAdapterSupport.object(object["payload"])
                }

                guard JSONLAdapterSupport.string(object["type"]) == "response_item",
                      let payload = JSONLAdapterSupport.object(object["payload"]),
                      JSONLAdapterSupport.string(payload["type"]) == "message"
                else {
                    continue
                }

                let role = JSONLAdapterSupport.string(payload["role"])
                if role == "user" {
                    let text = Self.extractText(JSONLAdapterSupport.array(payload["content"]))
                    if Self.isSystemInjection(text) {
                        systemCount += 1
                    } else {
                        userCount += 1
                        if firstUserText.isEmpty { firstUserText = text }
                    }
                } else if role == "assistant" {
                    assistantCount += 1
                }
                if let timestamp = JSONLAdapterSupport.string(object["timestamp"]) {
                    lastTimestamp = timestamp
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
                    model: JSONLAdapterSupport.string(meta["model_provider"]),
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
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
        let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
        if let failure { throw failure }
        let messages = objects.compactMap(Self.message(from:))
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
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

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard JSONLAdapterSupport.string(object["type"]) == "response_item",
              let payload = JSONLAdapterSupport.object(object["payload"]),
              JSONLAdapterSupport.string(payload["type"]) == "message",
              let rawRole = JSONLAdapterSupport.string(payload["role"]),
              rawRole == "user" || rawRole == "assistant"
        else {
            return nil
        }
        return NormalizedMessage(
            role: rawRole == "user" ? .user : .assistant,
            content: extractText(JSONLAdapterSupport.array(payload["content"])),
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: nil,
            usage: nil
        )
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        text.hasPrefix("# AGENTS.md instructions for ") ||
            text.contains("<INSTRUCTIONS>") ||
            text.hasPrefix("<local-command-caveat>") ||
            text.hasPrefix("<environment_context>")
    }

    private static func extractText(_ content: [Any]?) -> String {
        guard let content else { return "" }
        for item in content {
            guard let object = JSONLAdapterSupport.object(item) else { continue }
            if let text = JSONLAdapterSupport.string(object["text"]) { return text }
            if let inputText = JSONLAdapterSupport.string(object["input_text"]) { return inputText }
        }
        return ""
    }
}
