// macos/CodingMemory/Core/MessageParser.swift
import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String   // "user" or "assistant"
    let content: String
}

struct MessageParser {

    static func parse(filePath: String, source: String) -> [ChatMessage] {
        switch source {
        case "claude-code", "qwen", "iflow":
            return parseTypeMessageFormat(filePath: filePath)
        case "kimi":
            return parseRoleDirectFormat(filePath: filePath, skipFirst: false)
        case "antigravity", "windsurf":
            return parseRoleDirectFormat(filePath: filePath, skipFirst: true)
        case "codex":
            return parseCodexFormat(filePath: filePath)
        case "gemini-cli":
            return parseGeminiFormat(filePath: filePath)
        case "cline":
            return parseClineFormat(filePath: filePath)
        default:
            // cursor / opencode / vscode use SQLite virtual paths — not supported here
            return []
        }
    }

    // MARK: - claude-code / qwen / iflow
    // {"type":"user"/"assistant", "message":{"content": string | [{type,text}]}, ...}
    private static func parseTypeMessageFormat(filePath: String) -> [ChatMessage] {
        guard let lines = readLines(filePath) else { return [] }
        return lines.compactMap { line in
            guard let obj = parseJSON(line),
                  let type_ = obj["type"] as? String,
                  type_ == "user" || type_ == "assistant",
                  let msg = obj["message"] as? [String: Any] else { return nil }
            let content = extractMessageContent(msg["content"])
            return content.isEmpty ? nil : ChatMessage(role: type_, content: content)
        }
    }

    // MARK: - kimi / antigravity / windsurf
    // {"role":"user"/"assistant", "content":"..."}  (antigravity/windsurf skip first meta line)
    private static func parseRoleDirectFormat(filePath: String, skipFirst: Bool) -> [ChatMessage] {
        guard let lines = readLines(filePath) else { return [] }
        return lines.enumerated().compactMap { (i, line) in
            if skipFirst && i == 0 { return nil }
            guard let obj = parseJSON(line),
                  let role = obj["role"] as? String,
                  role == "user" || role == "assistant",
                  let content = obj["content"] as? String,
                  !content.isEmpty else { return nil }
            return ChatMessage(role: role, content: content)
        }
    }

    // MARK: - codex
    // {"type":"response_item", "payload":{"type":"message","role":..,"content":[{"text":..}]}}
    private static func parseCodexFormat(filePath: String) -> [ChatMessage] {
        guard let lines = readLines(filePath) else { return [] }
        return lines.compactMap { line in
            guard let obj = parseJSON(line),
                  obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String,
                  role == "user" || role == "assistant" else { return nil }
            let content = extractTextArray(payload["content"])
            return content.isEmpty ? nil : ChatMessage(role: role, content: content)
        }
    }

    // MARK: - gemini-cli
    // Whole file: {"messages":[{"type":"user"/"model","content":"..."}]}
    private static func parseGeminiFormat(filePath: String) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { msg in
            guard let type_ = msg["type"] as? String,
                  type_ == "user" || type_ == "model",
                  let content = msg["content"] as? String,
                  !content.isEmpty else { return nil }
            return ChatMessage(role: type_ == "model" ? "assistant" : "user", content: content)
        }
    }

    // MARK: - cline
    // Whole file: [{say:"task"/"user_feedback"/"text", text:"..", partial:bool}]
    private static func parseClineFormat(filePath: String) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { msg in
            guard let say = msg["say"] as? String else { return nil }
            if say == "task" || say == "user_feedback" {
                let content = msg["text"] as? String ?? ""
                return content.isEmpty ? nil : ChatMessage(role: "user", content: content)
            } else if say == "text", !(msg["partial"] as? Bool ?? false) {
                let content = msg["text"] as? String ?? ""
                return content.isEmpty ? nil : ChatMessage(role: "assistant", content: content)
            }
            return nil
        }
    }

    // MARK: - Helpers

    private static func readLines(_ filePath: String) -> [String]? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        return content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func parseJSON(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // claude-code: message.content is string or [{type:"text", text:"..."}]
    private static func extractMessageContent(_ content: Any?) -> String {
        if let str = content as? String { return str }
        if let arr = content as? [[String: Any]] {
            for item in arr {
                if item["type"] as? String == "text", let text = item["text"] as? String {
                    return text
                }
            }
        }
        return ""
    }

    // codex: content is [{text:"..."} | {input_text:"..."}]
    private static func extractTextArray(_ content: Any?) -> String {
        guard let arr = content as? [[String: Any]] else { return "" }
        for item in arr {
            if let t = item["text"] as? String { return t }
            if let t = item["input_text"] as? String { return t }
        }
        return ""
    }
}
