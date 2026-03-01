// macos/Engram/Core/MessageParser.swift
import Foundation
import GRDB

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String    // "user" or "assistant"
    let content: String
    let isSystem: Bool  // system injection — hidden in clean view
}

struct MessageParser {

    static func parse(filePath: String, source: String) -> [ChatMessage] {
        switch source {
        case "claude-code", "qwen", "iflow":
            return parseTypeMessageFormat(filePath: filePath, source: source)
        case "kimi":
            return parseRoleDirectFormat(filePath: filePath, skipFirst: false, source: source)
        case "antigravity", "windsurf":
            return parseRoleDirectFormat(filePath: filePath, skipFirst: true, source: source)
        case "codex":
            return parseCodexFormat(filePath: filePath)
        case "gemini-cli":
            return parseGeminiFormat(filePath: filePath)
        case "cline":
            return parseClineFormat(filePath: filePath)
        case "cursor":
            return parseCursorFormat(filePath: filePath)
        default:
            // opencode / vscode — not yet supported
            return []
        }
    }

    // MARK: - claude-code / qwen / iflow
    // {"type":"user"/"assistant", "message":{"content": string | [{type,text}]}, ...}
    private static func parseTypeMessageFormat(filePath: String, source: String) -> [ChatMessage] {
        guard let lines = readLines(filePath) else { return [] }
        return lines.compactMap { line in
            guard let obj = parseJSON(line),
                  let type_ = obj["type"] as? String,
                  type_ == "user" || type_ == "assistant",
                  let msg = obj["message"] as? [String: Any] else { return nil }
            let content = extractMessageContent(msg["content"])
            guard !content.isEmpty else { return nil }
            let sys = type_ == "user" && isSystemInjection(content: content, source: source)
            return ChatMessage(role: type_, content: content, isSystem: sys)
        }
    }

    // MARK: - kimi / antigravity / windsurf
    // {"role":"user"/"assistant", "content":"..."}  (antigravity/windsurf skip first meta line)
    private static func parseRoleDirectFormat(filePath: String, skipFirst: Bool, source: String) -> [ChatMessage] {
        guard let lines = readLines(filePath) else { return [] }
        return lines.enumerated().compactMap { (i, line) in
            if skipFirst && i == 0 { return nil }
            guard let obj = parseJSON(line),
                  let role = obj["role"] as? String,
                  role == "user" || role == "assistant",
                  let content = obj["content"] as? String,
                  !content.isEmpty else { return nil }
            let sys = role == "user" && isSystemInjection(content: content, source: source)
            return ChatMessage(role: role, content: content, isSystem: sys)
        }
    }

    // MARK: - codex
    // {"type":"response_item","payload":{"type":"message","role":...,"content":[{"text":...}]}}
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
            guard !content.isEmpty else { return nil }
            let sys = role == "user" && isSystemInjection(content: content, source: "codex")
            return ChatMessage(role: role, content: content, isSystem: sys)
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
            let role = type_ == "model" ? "assistant" : "user"
            return ChatMessage(role: role, content: content, isSystem: false)
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
                return content.isEmpty ? nil : ChatMessage(role: "user", content: content, isSystem: false)
            } else if say == "text", !(msg["partial"] as? Bool ?? false) {
                let content = msg["text"] as? String ?? ""
                return content.isEmpty ? nil : ChatMessage(role: "assistant", content: content, isSystem: false)
            }
            return nil
        }
    }

    // MARK: - cursor (SQLite: state.vscdb?composer=<id>)
    // New format: conversation array inside composerData:<id>
    // Old format: separate bubbleId:<composerId>:<msgId> keys
    // Both: {type: 1=user/2=assistant, text/rawText: "..."}
    private static func parseCursorFormat(filePath: String) -> [ChatMessage] {
        guard let qRange = filePath.range(of: "?composer=") else { return [] }
        let dbPath = String(filePath[..<qRange.lowerBound])
        let composerId = String(filePath[qRange.upperBound...])
        guard !composerId.isEmpty else { return [] }

        var config = Configuration()
        config.readonly = true
        guard let queue = try? DatabaseQueue(path: dbPath, configuration: config) else { return [] }

        return (try? queue.read { db in
            // Try new format first: conversation embedded in composerData
            if let row = try Row.fetchOne(db,
                sql: "SELECT value FROM cursorDiskKV WHERE key = ?",
                arguments: ["composerData:\(composerId)"]),
               let jsonStr: String = row["value"],
               let data = jsonStr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let conversation = obj["conversation"] as? [[String: Any]],
               !conversation.isEmpty {
                return parseCursorBubbles(conversation)
            }
            // Fallback: old format with separate bubbleId keys
            let rows = try Row.fetchAll(db,
                sql: "SELECT value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid ASC",
                arguments: ["bubbleId:\(composerId):%"])
            let bubbles: [[String: Any]] = rows.compactMap { row in
                guard let jsonStr: String = row["value"],
                      let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return obj
            }
            return parseCursorBubbles(bubbles)
        }) ?? []
    }

    private static func parseCursorBubbles(_ bubbles: [[String: Any]]) -> [ChatMessage] {
        bubbles.compactMap { obj in
            guard let type = obj["type"] as? Int else { return nil }
            let role: String
            switch type {
            case 1: role = "user"
            case 2: role = "assistant"
            default: return nil
            }
            let content = (obj["text"] as? String) ?? (obj["rawText"] as? String) ?? ""
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return ChatMessage(role: role, content: content, isSystem: false)
        }
    }

    // MARK: - System injection detection

    static func isSystemInjection(content: String, source: String) -> Bool {
        if content.hasPrefix("# AGENTS.md instructions for ")  { return true }
        if content.contains("<INSTRUCTIONS>")                  { return true }
        if content.hasPrefix("<local-command-caveat>")         { return true }
        if content.hasPrefix("<local-command-stdout>")         { return true }
        if content.contains("<command-name>")                  { return true }
        if content.contains("<command-message>")               { return true }
        if content.hasPrefix("Unknown skill: ")                { return true }
        if content.hasPrefix("Invoke the superpowers:")        { return true }
        if content.hasPrefix("Base directory for this skill:") { return true }
        if content.hasPrefix("<system-reminder>")              { return true }
        if content.hasPrefix("<environment_context>")          { return true }
        if content.hasPrefix("<EXTREMELY_IMPORTANT>")          { return true }
        return false
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

    private static func extractMessageContent(_ content: Any?) -> String {
        if let str = content as? String { return str }
        if let arr = content as? [[String: Any]] {
            for item in arr {
                if item["type"] as? String == "text", let text = item["text"] as? String { return text }
            }
        }
        return ""
    }

    private static func extractTextArray(_ content: Any?) -> String {
        guard let arr = content as? [[String: Any]] else { return "" }
        for item in arr {
            if let t = item["text"] as? String { return t }
            if let t = item["input_text"] as? String { return t }
        }
        return ""
    }
}
