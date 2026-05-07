import CryptoKit
import Foundation

final class OpenClawAdapter: SessionAdapter {
    let source: SourceName = .openclaw
    private let roots: [URL]
    private let limits: ParserLimits

    init(
        roots: [String] = OpenClawAdapter.defaultRoots(),
        limits: ParserLimits = .default
    ) {
        self.roots = roots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        self.limits = limits
    }

    func detect() async -> Bool {
        roots.contains { JSONLAdapterSupport.isDirectory($0) }
    }

    func listSessionLocators() async throws -> [String] {
        roots.flatMap { root in
            let agentsRoot = root.appendingPathComponent("agents")
            return JSONLAdapterSupport.recursiveFiles(under: agentsRoot) { url in
                url.lastPathComponent.contains(".jsonl")
            }
        }
        .sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { return .failure(failure) }

            var sessionId = ""
            var cwd = ""
            var model: String?
            var startTime = ""
            var endTime = ""
            var userCount = 0
            var assistantCount = 0
            var toolCount = 0
            var systemCount = 0
            var firstUserText = ""
            var firstToolName = ""
            var origin: String?
            var sawHeartbeatPrompt = false
            var sawNonHousekeepingUser = false

            for object in objects {
                if let timestamp = Self.isoTimestamp(object["timestamp"]) {
                    if startTime.isEmpty || timestamp < startTime { startTime = timestamp }
                    if endTime.isEmpty || timestamp > endTime { endTime = timestamp }
                }

                switch Self.normalizedKey(object["type"]) {
                case "session":
                    if sessionId.isEmpty, let value = JSONLAdapterSupport.string(object["id"]) { sessionId = value }
                    if cwd.isEmpty, let value = JSONLAdapterSupport.string(object["cwd"]) { cwd = value }
                case "modelchange":
                    if model == nil, let value = JSONLAdapterSupport.string(object["modelId"]) { model = value }
                case "message":
                    guard let message = JSONLAdapterSupport.object(object["message"]) else { continue }
                    let role = Self.normalizedKey(message["role"])
                    if role == "user" {
                        let text = Self.extractText(message["content"])
                        if Self.isHeartbeatPrompt(text) {
                            sawHeartbeatPrompt = true
                            continue
                        }
                        if Self.isNewSessionScaffold(text) { continue }
                        sawNonHousekeepingUser = true
                        if origin == nil { origin = Self.deriveOrigin(text) }
                        if firstUserText.isEmpty { firstUserText = text }
                        userCount += 1
                    } else if role == "assistant" {
                        assistantCount += 1
                        if model == nil, let value = JSONLAdapterSupport.string(message["model"]) { model = value }
                        let toolCalls = Self.toolCalls(from: message["content"])
                        toolCount += toolCalls.count
                        if firstToolName.isEmpty, let first = toolCalls.first?.name { firstToolName = first }
                    } else if role == "toolresult" {
                        toolCount += 1
                        if firstToolName.isEmpty {
                            firstToolName = JSONLAdapterSupport.string(message["toolName"])
                                ?? JSONLAdapterSupport.string(message["tool_name"])
                                ?? ""
                        }
                    } else if !role.isEmpty {
                        systemCount += 1
                    }
                default:
                    continue
                }
            }

            let baseId = sessionId.isEmpty ? Self.baseSessionId(locator) : sessionId
            let mtime = Self.fileModifiedIso(locator)
            let summary = firstUserText.isEmpty ? firstToolName : firstUserText
            let isHousekeeping = !sawNonHousekeepingUser && sawHeartbeatPrompt

            return .success(
                NormalizedSessionInfo(
                    id: "openclaw:\(Self.agentId(locator)):\(baseId)",
                    source: .openclaw,
                    startTime: startTime.isEmpty ? mtime : startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: cwd,
                    project: origin ?? "system",
                    model: model,
                    messageCount: userCount + assistantCount + toolCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: toolCount,
                    systemMessageCount: systemCount,
                    summary: summary.isEmpty ? nil : String(summary.prefix(200)),
                    filePath: locator,
                    sizeBytes: JSONLAdapterSupport.fileSize(locator: locator),
                    indexedAt: nil,
                    agentRole: isHousekeeping ? "housekeeping" : nil,
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

    private static func defaultRoots() -> [String] {
        var roots: [String] = []
        if let override = ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"], !override.isEmpty {
            roots.append(override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".openclaw").path)
        roots.append(home.appendingPathComponent(".clawdbot").path)
        return Array(Set(roots)).sorted()
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard normalizedKey(object["type"]) == "message",
              let message = JSONLAdapterSupport.object(object["message"])
        else {
            return nil
        }
        let roleKey = normalizedKey(message["role"])
        let role: NormalizedMessageRole
        if roleKey == "user" {
            role = .user
        } else if roleKey == "assistant" {
            role = .assistant
        } else if roleKey == "toolresult" {
            role = .tool
        } else {
            return nil
        }
        let content = extractText(message["content"])
        let calls = role == .assistant ? toolCalls(from: message["content"]) : []
        guard !content.isEmpty || !calls.isEmpty else { return nil }
        return NormalizedMessage(
            role: role,
            content: content.isEmpty ? "[tool call]" : content,
            timestamp: isoTimestamp(object["timestamp"]),
            toolCalls: calls.isEmpty ? nil : calls,
            usage: usage(from: JSONLAdapterSupport.object(message["usage"]))
        )
    }

    private static func toolCalls(from content: Any?) -> [NormalizedToolCall] {
        guard let blocks = JSONLAdapterSupport.array(content) else { return [] }
        return blocks.compactMap { item in
            guard let block = JSONLAdapterSupport.object(item),
                  normalizedKey(block["type"]) == "toolcall",
                  let name = JSONLAdapterSupport.string(block["name"]) ?? JSONLAdapterSupport.string(block["tool_name"])
            else {
                return nil
            }
            let input = block["arguments"].flatMap { JSONLAdapterSupport.jsonString($0) }
            return NormalizedToolCall(name: name, input: input)
        }
    }

    private static func usage(from raw: JSONLAdapterSupport.JSONObject?) -> TokenUsage? {
        guard let raw else { return nil }
        return TokenUsage(
            inputTokens: raw["input_tokens"] as? Int ?? raw["inputTokens"] as? Int ?? 0,
            outputTokens: raw["output_tokens"] as? Int ?? raw["outputTokens"] as? Int ?? 0,
            cacheReadTokens: raw["cache_read_input_tokens"] as? Int ?? raw["cacheReadTokens"] as? Int,
            cacheCreationTokens: raw["cache_creation_input_tokens"] as? Int ?? raw["cacheCreationTokens"] as? Int
        )
    }

    private static func extractText(_ content: Any?) -> String {
        if let string = JSONLAdapterSupport.string(content) {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let blocks = JSONLAdapterSupport.array(content) else { return "" }
        let hasImage = blocks.contains { JSONLAdapterSupport.string(JSONLAdapterSupport.object($0)?["type"]) == "image" }
        var texts: [String] = []
        for item in blocks {
            guard let block = JSONLAdapterSupport.object(item),
                  JSONLAdapterSupport.string(block["type"]) == "text",
                  let text = JSONLAdapterSupport.string(block["text"])
            else {
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if hasImage && isRedundantMediaAttachment(trimmed) { continue }
            texts.append(text)
        }
        if !texts.isEmpty { return texts.joined(separator: "\n") }
        return hasImage ? "Image attached" : ""
    }

    private static func isHeartbeatPrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("heartbeat.md") &&
            (lower.contains("read heartbeat.md") || lower.contains("consider outstanding tasks"))
    }

    private static func isNewSessionScaffold(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("a new session was started via /new") || lower.contains("via /new or /reset")
    }

    private static func isRedundantMediaAttachment(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("[media attached:") ||
            (lower.contains("to send an image back") && lower.contains("media:"))
    }

    private static func deriveOrigin(_ text: String) -> String {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("conversation info (untrusted metadata):"),
           lower.contains("\"sender_id\""),
           lower.contains("sender (untrusted metadata):") {
            return "telegram"
        }
        if lower.hasPrefix("[telegram ") || lower.contains("\n[telegram ") { return "telegram" }
        if lower.hasPrefix("[cron:") || lower.hasPrefix("[cron ") || lower.contains("\n[cron:") || lower.contains("\n[cron ") { return "cron" }
        if lower.hasPrefix("[whatsapp ") || lower.contains("\n[whatsapp ") { return "whatsapp" }
        if lower.hasPrefix("[discord ") || lower.contains("\n[discord ") { return "discord" }
        if lower.hasPrefix("[imessage ") || lower.contains("\n[imessage ") { return "imessage" }
        if lower.hasPrefix("[webchat ") || lower.contains("\n[webchat ") { return "webchat" }
        return "tui"
    }

    private static func normalizedKey(_ value: Any?) -> String {
        guard let raw = value as? String else { return "" }
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func isoTimestamp(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        let seconds: Double?
        if let number = value as? NSNumber {
            var raw = number.doubleValue
            if raw > 1e14 { raw /= 1_000_000 }
            else if raw > 1e11 { raw /= 1_000 }
            seconds = raw
        } else {
            seconds = nil
        }
        return seconds.map { Phase4AdapterSupport.isoFromSeconds($0) }
    }

    private static func agentId(_ locator: String) -> String {
        let components = URL(fileURLWithPath: locator).pathComponents
        guard let index = components.lastIndex(of: "agents"), components.indices.contains(index + 1) else {
            return "default"
        }
        return components[index + 1]
    }

    private static func baseSessionId(_ locator: String) -> String {
        let name = URL(fileURLWithPath: locator).lastPathComponent
        let base = name.replacingOccurrences(of: #"\.jsonl(?:\.deleted\..*)?$"#, with: "", options: .regularExpression)
        if !base.isEmpty { return base }
        let digest = SHA256.hash(data: Data(locator.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private static func fileModifiedIso(_ locator: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: locator)
        let date = attrs?[.modificationDate] as? Date ?? Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
