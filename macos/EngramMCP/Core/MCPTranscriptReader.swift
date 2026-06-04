import Darwin
import Foundation

struct MCPTranscriptMessage {
    let role: String
    let content: String
    let timestamp: String?
}

struct MCPTranscriptPage {
    let messages: [MCPTranscriptMessage]
    let totalMessages: Int
    let currentPage: Int
    let pageSize: Int

    var totalPages: Int {
        max(1, Int(ceil(Double(totalMessages) / Double(pageSize))))
    }
}

private struct MCPTranscriptPageBuilder {
    private let currentPage: Int
    private let pageSize: Int
    private let offset: Int
    private var messages: [MCPTranscriptMessage] = []
    private var totalMessages = 0

    init(currentPage: Int, pageSize: Int) {
        self.currentPage = currentPage
        self.pageSize = pageSize
        self.offset = (currentPage - 1) * pageSize
    }

    mutating func append(_ message: MCPTranscriptMessage) {
        if totalMessages >= offset && messages.count < pageSize {
            messages.append(message)
        }
        totalMessages += 1
    }

    func build() -> MCPTranscriptPage {
        MCPTranscriptPage(
            messages: messages,
            totalMessages: totalMessages,
            currentPage: currentPage,
            pageSize: pageSize
        )
    }
}

enum MCPTranscriptReader {
    static func readMessagePage(
        filePath: String,
        source: String,
        page: Int,
        pageSize: Int,
        roles: [String]?
    ) async throws -> MCPTranscriptPage {
        let currentPage = max(page, 1)
        let effectivePageSize = max(pageSize, 1)
        let roleFilter = normalizeRoles(roles)
        var builder = MCPTranscriptPageBuilder(
            currentPage: currentPage,
            pageSize: effectivePageSize
        )

        if source == "gemini-cli" {
            try TranscriptSizeGuard.validateFullJSONTranscript(
                filePath: filePath,
                source: source
            )
        }

        if let adapterPage = await readPageWithAdapterRegistry(
            filePath: filePath,
            source: source,
            currentPage: currentPage,
            pageSize: effectivePageSize,
            roles: roleFilter
        ) {
            return adapterPage
        }

        switch source {
        case "claude-code", "qwen", "qoder", "iflow", "lobsterai", "minimax":
            collectJSONLines(filePath: filePath) { obj in
                appendIfVisible(parseTypeMessageObject(obj), to: &builder, source: source, roles: roleFilter)
            }
        case "kimi", "antigravity", "windsurf":
            collectJSONLines(filePath: filePath) { obj in
                appendIfVisible(parseRoleDirectObject(obj), to: &builder, source: source, roles: roleFilter)
            }
        case "commandcode":
            collectJSONLines(filePath: filePath) { obj in
                appendIfVisible(parseCommandCodeObject(obj), to: &builder, source: source, roles: roleFilter)
            }
        case "codex":
            collectJSONLines(filePath: filePath) { obj in
                appendIfVisible(parseCodexObject(obj), to: &builder, source: source, roles: roleFilter)
            }
        case "gemini-cli":
            for message in parseGeminiFormat(filePath: filePath) {
                appendIfVisible(message, to: &builder, source: source, roles: roleFilter)
            }
        default:
            break
        }

        return builder.build()
    }

    static func readMessages(filePath: String, source: String) async throws -> [MCPTranscriptMessage] {
        if source == "gemini-cli" {
            try TranscriptSizeGuard.validateFullJSONTranscript(
                filePath: filePath,
                source: source
            )
        }

        if let adapterMessages = await readWithAdapterRegistry(filePath: filePath, source: source) {
            return adapterMessages
        }

        switch source {
        case "claude-code", "qwen", "qoder", "iflow", "lobsterai", "minimax":
            return visibleMessages(parseTypeMessageFormat(filePath: filePath), source: source)
        case "kimi", "antigravity", "windsurf":
            return visibleMessages(parseRoleDirectFormat(filePath: filePath), source: source)
        case "commandcode":
            return visibleMessages(parseCommandCodeFormat(filePath: filePath), source: source)
        case "codex":
            return visibleMessages(parseCodexFormat(filePath: filePath), source: source)
        case "gemini-cli":
            return visibleMessages(parseGeminiFormat(filePath: filePath), source: source)
        default:
            return []
        }
    }

    private static func normalizeRoles(_ roles: [String]?) -> [String]? {
        let roleFilter = roles?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (roleFilter?.isEmpty == false) ? roleFilter : nil
    }

    private static func appendIfVisible(
        _ message: MCPTranscriptMessage?,
        to builder: inout MCPTranscriptPageBuilder,
        source: String,
        roles: [String]?
    ) {
        guard let message else { return }
        guard roles == nil || roles!.contains(message.role) else { return }
        guard isDefaultVisibleMessage(role: message.role, content: message.content, source: source) else { return }
        builder.append(message)
    }

    // Async by design: the adapter stream is async, so we await it directly
    // instead of bridging back to sync with a DispatchSemaphore. Blocking a
    // cooperative-pool thread on a semaphore can starve/deadlock the pool when
    // several reads run concurrently.
    private static func readWithAdapterRegistry(filePath: String, source: String) async -> [MCPTranscriptMessage]? {
        guard let sourceName = adapterSourceName(for: source),
              let adapter = SessionAdapterFactory.defaultAdapters().first(where: { $0.source == sourceName })
        else {
            return nil
        }

        do {
            let stream = try await adapter.streamMessages(
                locator: filePath,
                options: StreamMessagesOptions()
            )
            var messages: [MCPTranscriptMessage] = []
            for try await message in stream {
                guard isDefaultVisibleMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    source: source
                ) else { continue }
                messages.append(
                    MCPTranscriptMessage(
                        role: message.role.rawValue,
                        content: message.content,
                        timestamp: message.timestamp
                    )
                )
            }
            return messages
        } catch {
            return nil
        }
    }

    private static func readPageWithAdapterRegistry(
        filePath: String,
        source: String,
        currentPage: Int,
        pageSize: Int,
        roles: [String]?
    ) async -> MCPTranscriptPage? {
        guard let sourceName = adapterSourceName(for: source),
              let adapter = SessionAdapterFactory.defaultAdapters().first(where: { $0.source == sourceName })
        else {
            return nil
        }

        do {
            let stream = try await adapter.streamMessages(
                locator: filePath,
                options: StreamMessagesOptions()
            )
            var builder = MCPTranscriptPageBuilder(
                currentPage: currentPage,
                pageSize: pageSize
            )
            for try await message in stream {
                let transcriptMessage = MCPTranscriptMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    timestamp: message.timestamp
                )
                appendIfVisible(transcriptMessage, to: &builder, source: source, roles: roles)
            }
            return builder.build()
        } catch {
            return nil
        }
    }

    private static func adapterSourceName(for source: String) -> SourceName? {
        if source == "antigravity-legacy" { return .antigravity }
        return SourceName(rawValue: source)
    }

    private static func visibleMessages(
        _ messages: [MCPTranscriptMessage],
        source: String
    ) -> [MCPTranscriptMessage] {
        messages.filter { message in
            isDefaultVisibleMessage(role: message.role, content: message.content, source: source)
        }
    }

    private static func isDefaultVisibleMessage(role: String, content: String, source: String) -> Bool {
        guard role == "user" || role == "assistant" else { return false }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if role == "user" {
            return SystemMessageClassifier.classify(content: content, source: source) == .none
        }
        return true
    }

    private static func parseTypeMessageFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap(parseTypeMessageObject)
    }

    private static func parseRoleDirectFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap(parseRoleDirectObject)
    }

    private static func parseCodexFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap(parseCodexObject)
    }

    private static func parseGeminiFormat(filePath: String) -> [MCPTranscriptMessage] {
        guard
            let data = FileManager.default.contents(atPath: filePath),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let messages = root["messages"] as? [[String: Any]]
        else {
            return []
        }

        return messages.compactMap { message in
            guard let type = message["type"] as? String else { return nil }
            let role: String
            switch type {
            case "user":
                role = "user"
            case "gemini", "model":
                role = "assistant"
            default:
                return nil
            }

            let content: String
            if let text = message["content"] as? String {
                content = text
            } else if let parts = message["content"] as? [[String: Any]] {
                content = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                return nil
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return MCPTranscriptMessage(
                role: role,
                content: content,
                timestamp: message["timestamp"] as? String
            )
        }
    }

    private static func parseCommandCodeFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap(parseCommandCodeObject)
    }

    private static func parseTypeMessageObject(_ obj: [String: Any]) -> MCPTranscriptMessage? {
        guard
            let type = obj["type"] as? String,
            type == "user" || type == "assistant",
            let message = obj["message"] as? [String: Any]
        else {
            return nil
        }
        var content = extractMessageContent(message["content"])
        if content.isEmpty {
            content = extractPartsContent(message["parts"])
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MCPTranscriptMessage(
            role: type,
            content: content,
            timestamp: obj["timestamp"] as? String
        )
    }

    private static func parseRoleDirectObject(_ obj: [String: Any]) -> MCPTranscriptMessage? {
        guard
            let role = obj["role"] as? String,
            (role == "user" || role == "assistant"),
            let content = obj["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let timestamp = (obj["timestamp"] as? String)
            ?? (obj["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0).ISO8601Format() }
            ?? (obj["timestamp"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format() }

        return MCPTranscriptMessage(role: role, content: content, timestamp: timestamp)
    }

    private static func parseCodexObject(_ obj: [String: Any]) -> MCPTranscriptMessage? {
        guard
            obj["type"] as? String == "response_item",
            let payload = obj["payload"] as? [String: Any],
            payload["type"] as? String == "message",
            let role = payload["role"] as? String,
            (role == "user" || role == "assistant")
        else {
            return nil
        }

        let content = extractTextArray(payload["content"])
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return MCPTranscriptMessage(
            role: role,
            content: content,
            timestamp: obj["timestamp"] as? String
        )
    }

    private static func parseCommandCodeObject(_ obj: [String: Any]) -> MCPTranscriptMessage? {
        guard
            let role = obj["role"] as? String,
            role == "user" || role == "assistant"
        else {
            return nil
        }
        let content = extractCommandCodeContent(obj["content"])
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let timestamp = (obj["timestamp"] as? String)
            ?? ((obj["metadata"] as? [String: Any])?["timestamp"] as? String)
        return MCPTranscriptMessage(role: role, content: content, timestamp: timestamp)
    }

    private static func readJSONLines(filePath: String) -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
    }

    private static func collectJSONLines(
        filePath: String,
        _ consume: ([String: Any]) -> Void
    ) {
        guard let file = fopen(filePath, "r") else { return }
        defer { fclose(file) }

        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer {
            if let line {
                free(line)
            }
        }

        while true {
            let count = getline(&line, &capacity, file)
            if count <= 0 { break }
            guard let line else { continue }
            let data = Data(bytes: line, count: count)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            consume(obj)
        }
    }

    private static func extractMessageContent(_ content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        guard let items = content as? [[String: Any]] else { return "" }
        var textParts: [String] = []
        var thinkingFallback: String?
        for item in items {
            if item["type"] as? String == "text", let text = item["text"] as? String {
                textParts.append(text)
            } else if item["type"] as? String == "thinking",
                      let thinking = item["thinking"] as? String,
                      thinkingFallback == nil {
                thinkingFallback = thinking
            }
        }
        if !textParts.isEmpty {
            return textParts.joined(separator: "\n")
        }
        return thinkingFallback ?? ""
    }

    private static func extractPartsContent(_ parts: Any?) -> String {
        guard let items = parts as? [[String: Any]] else { return "" }
        return items.compactMap { $0["text"] as? String }.first ?? ""
    }

    private static func extractTextArray(_ content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        for item in items {
            if let text = item["text"] as? String {
                return text
            }
            if let inputText = item["input_text"] as? String {
                return inputText
            }
        }
        return ""
    }

    private static func extractCommandCodeContent(_ content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { item in
            switch item["type"] as? String {
            case "text":
                return item["text"] as? String
            case "tool-call":
                return (item["toolName"] as? String).map { "`\($0)`" }
            case "tool-result":
                if let output = item["output"] as? String {
                    return output
                }
                if let output = item["output"],
                   JSONSerialization.isValidJSONObject(output),
                   let data = try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes]),
                   let text = String(data: data, encoding: .utf8) {
                    return String(text.prefix(2_000))
                }
                return nil
            default:
                return nil
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }
}
