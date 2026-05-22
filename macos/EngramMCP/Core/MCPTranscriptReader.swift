import Foundation

struct MCPTranscriptMessage {
    let role: String
    let content: String
    let timestamp: String?
}

enum MCPTranscriptReader {
    static func readMessages(filePath: String, source: String) async -> [MCPTranscriptMessage] {
        if let adapterMessages = await readWithAdapterRegistry(filePath: filePath, source: source) {
            return adapterMessages
        }

        switch source {
        case "claude-code", "qwen", "qoder", "iflow", "lobsterai", "minimax":
            return parseTypeMessageFormat(filePath: filePath)
        case "kimi", "antigravity", "windsurf":
            return parseRoleDirectFormat(filePath: filePath)
        case "commandcode":
            return parseCommandCodeFormat(filePath: filePath)
        case "codex":
            return parseCodexFormat(filePath: filePath)
        case "gemini-cli":
            return parseGeminiFormat(filePath: filePath)
        default:
            return []
        }
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
                guard message.role == .user || message.role == .assistant,
                      !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue
                }
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

    private static func adapterSourceName(for source: String) -> SourceName? {
        if source == "antigravity-legacy" { return .antigravity }
        return SourceName(rawValue: source)
    }

    private static func parseTypeMessageFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap { obj in
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
    }

    private static func parseRoleDirectFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap { obj in
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
    }

    private static func parseCodexFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap { obj in
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
        readJSONLines(filePath: filePath).compactMap { obj in
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
