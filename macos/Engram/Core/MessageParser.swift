// macos/Engram/Core/MessageParser.swift
import Foundation
import GRDB

enum SystemCategory: String {
    case none
    case systemPrompt   // CLAUDE.md, AGENTS.md, environment_context, system-reminder, etc.
    case agentComm      // command-name, command-message, skill invocations, local-command-*
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String    // "user" or "assistant"
    let content: String
    let systemCategory: SystemCategory
    /// ISO timestamp when known (adapter path); nil for legacy parsers (row 30).
    var timestamp: String? = nil

    var isSystem: Bool { systemCategory != .none }

    init(role: String, content: String, systemCategory: SystemCategory, timestamp: String? = nil) {
        self.role = role
        self.content = content
        self.systemCategory = systemCategory
        self.timestamp = timestamp
    }
}

struct MessageParser {

    static func parse(
        filePath: String,
        source: String,
        offset: Int? = nil,
        limit: Int? = nil,
        claudeCodeProfileResolver: ClaudeCodeProfileResolver? = nil
    ) async -> [ChatMessage] {
        if let adapterMessages = await parseWithAdapterRegistry(
            filePath: filePath,
            source: source,
            offset: offset,
            limit: limit,
            claudeCodeProfileResolver: claudeCodeProfileResolver
        ),
           !adapterMessages.isEmpty {
            return adapterMessages
        }
        return applyWindow(parseLegacy(filePath: filePath, source: source), offset: offset, limit: limit)
    }

    private static func parseLegacy(filePath: String, source: String) -> [ChatMessage] {
        switch source {
        case "claude-code", "qwen", "iflow", "lobsterai", "minimax":
            return parseTypeMessageFormat(filePath: filePath, source: source)
        case "kimi":
            return parseRoleDirectFormat(filePath: filePath, skipFirst: false, source: source)
        case "antigravity", "windsurf":
            return parseRoleDirectFormat(filePath: filePath, skipFirst: true, source: source)
        case "codex":
            return parseCodexFormat(filePath: filePath)
        case "copilot":
            return parseCopilotFormat(filePath: filePath)
        case "gemini-cli":
            return parseGeminiFormat(filePath: filePath)
        case "cline":
            return parseClineFormat(filePath: filePath)
        case "cursor":
            return parseCursorFormat(filePath: filePath)
        case "opencode":
            return parseOpenCodeFormat(filePath: filePath)
        default:
            // vscode — not yet supported
            return []
        }
    }

    private static func parseWithAdapterRegistry(
        filePath: String,
        source: String,
        offset: Int?,
        limit: Int?,
        claudeCodeProfileResolver: ClaudeCodeProfileResolver?
    ) async -> [ChatMessage]? {
        guard let sourceName = SourceName(rawValue: source),
              let adapter = uiAdapterRegistry(
                claudeCodeProfileResolver: claudeCodeProfileResolver
              ).adapter(for: sourceName)
        else {
            return nil
        }

        return await adapterMessages(
            adapter: adapter,
            locator: filePath,
            source: source,
            options: StreamMessagesOptions(offset: offset, limit: limit)
        )?.messages
    }

    /// Window a transcript in PRODUCED-message space (the unit the adapters'
    /// offset/limit use) and report how many produced messages the window
    /// consumed. The returned `messages` are the displayable (user/assistant)
    /// subset — the same filtering `parse` applies — but `producedCount` counts
    /// PRE-filter messages, so a pager can advance its offset by `producedCount`
    /// (no seam drift from the filtered count) and detect EOF via
    /// `producedCount >= limit`. Falls back to the legacy parser only when the
    /// adapter yields nothing at all.
    static func parseWindowed(
        filePath: String,
        source: String,
        offset: Int,
        limit: Int?,
        claudeCodeProfileResolver: ClaudeCodeProfileResolver? = nil
    ) async -> (messages: [ChatMessage], producedCount: Int) {
        if let sourceName = SourceName(rawValue: source),
           let adapter = uiAdapterRegistry(
               claudeCodeProfileResolver: claudeCodeProfileResolver
           ).adapter(for: sourceName) {
            // Trust the adapter on success, INCLUDING a legitimately empty window
            // (paging past EOF, or a window that is entirely tool messages). Only a
            // nil result — adapter error / no stream — falls back to the legacy
            // parser, which has no offset/limit support and would re-read the whole
            // file just to discard it.
            if let result = await adapterMessages(
                adapter: adapter,
                locator: filePath,
                source: source,
                options: StreamMessagesOptions(offset: offset, limit: limit)
            ) {
                return result
            }
        }
        // No adapter for the source, or the adapter errored: legacy parsers emit
        // displayable messages directly, so produced == displayable here.
        let windowed = applyWindow(parseLegacy(filePath: filePath, source: source), offset: offset, limit: limit)
        return (windowed, windowed.count)
    }

    private static func uiAdapterRegistry(
        claudeCodeProfileResolver: ClaudeCodeProfileResolver?
    ) -> AdapterRegistry {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let resolver = claudeCodeProfileResolver ?? ClaudeCodeProfileResolver(
            homeDirectory: homeDirectory,
            settingsURL: homeDirectory.appendingPathComponent(".engram/settings.json")
        )
        let claudeCode = ClaudeCodeAdapter(profileResolver: resolver)
        return AdapterRegistry(
            adapters: [
                CodexAdapter(),
                claudeCode,
                ClaudeCodeDerivedSourceAdapter(source: .minimax, base: claudeCode),
                ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: claudeCode),
                GeminiCliAdapter(),
                OpenCodeAdapter(),
                IflowAdapter(),
                QwenAdapter(),
                QoderAdapter(),
                KimiAdapter(),
                ClineAdapter(),
                CursorAdapter(),
                VsCodeAdapter(),
                WindsurfAdapter(),
                AntigravityAdapter(),
                CommandCodeAdapter(),
                CopilotAdapter()
            ]
        )
    }

    private static func adapterMessages(
        adapter: any SessionAdapter,
        locator: String,
        source: String,
        options: StreamMessagesOptions
    ) async -> (messages: [ChatMessage], producedCount: Int)? {
        do {
            let stream = try await adapter.streamMessages(locator: locator, options: options)
            var messages: [ChatMessage] = []
            var produced = 0
            for try await message in stream {
                // Count PRE-filter (adapter-produced) messages so a caller paging
                // in produced-message space can advance offset correctly even when
                // role filtering drops tool messages from `messages`.
                produced += 1
                guard message.role == .user || message.role == .assistant,
                      !message.content.isEmpty
                else {
                    continue
                }
                let role = message.role == .user ? "user" : "assistant"
                let category = message.role == .user ? classifySystem(content: message.content, source: source) : .none
                messages.append(ChatMessage(
                    role: role,
                    content: message.content,
                    systemCategory: category,
                    timestamp: message.timestamp
                ))
            }
            return (messages, produced)
        } catch {
            return nil
        }
    }

    private static func applyWindow(_ messages: [ChatMessage], offset: Int?, limit: Int?) -> [ChatMessage] {
        let offset = max(offset ?? 0, 0)
        let suffix = offset >= messages.count ? [] : Array(messages.dropFirst(offset))
        guard let limit else { return suffix }
        return Array(suffix.prefix(max(limit, 0)))
    }

    // MARK: - claude-code / qwen / iflow
    // claude-code/iflow: {"type":"user"/"assistant", "message":{"content": string | [{type,text}]}, ...}
    // qwen:             {"type":"user"/"assistant", "message":{"parts":[{text:"..."}]}, ...}
    private static func parseTypeMessageFormat(filePath: String, source: String) -> [ChatMessage] {
        guard let reader = StreamingJSONLReader(filePath: filePath) else { return [] }
        defer { reader.close() }
        var messages: [ChatMessage] = []
        for line in reader {
            guard let obj = parseJSON(line),
                  let type_ = obj["type"] as? String,
                  type_ == "user" || type_ == "assistant",
                  let msg = obj["message"] as? [String: Any] else { continue }
            var content = extractMessageContent(msg["content"])
            // Qwen uses message.parts[].text instead of message.content
            if content.isEmpty { content = extractPartsContent(msg["parts"]) }
            guard !content.isEmpty else { continue }
            let cat = type_ == "user" ? classifySystem(content: content, source: source) : .none
            messages.append(ChatMessage(role: type_, content: content, systemCategory: cat))
        }
        return messages
    }

    // MARK: - kimi / antigravity / windsurf
    // {"role":"user"/"assistant", "content":"..."}  (antigravity/windsurf skip first meta line)
    private static func parseRoleDirectFormat(filePath: String, skipFirst: Bool, source: String) -> [ChatMessage] {
        guard let reader = StreamingJSONLReader(filePath: filePath) else { return [] }
        defer { reader.close() }
        var messages: [ChatMessage] = []
        var isFirst = true
        for line in reader {
            if skipFirst && isFirst { isFirst = false; continue }
            isFirst = false
            guard let obj = parseJSON(line),
                  let role = obj["role"] as? String,
                  role == "user" || role == "assistant",
                  let content = obj["content"] as? String,
                  !content.isEmpty else { continue }
            let cat = role == "user" ? classifySystem(content: content, source: source) : .none
            messages.append(ChatMessage(role: role, content: content, systemCategory: cat))
        }
        return messages
    }

    // MARK: - copilot
    // {"type":"user.message","data":{"content":"..."}}
    // {"type":"assistant.message","data":{"content":"...","toolRequests":[...]}}
    private static func parseCopilotFormat(filePath: String) -> [ChatMessage] {
        guard let reader = StreamingJSONLReader(filePath: filePath) else { return [] }
        defer { reader.close() }
        var messages: [ChatMessage] = []
        for line in reader {
            guard let obj = parseJSON(line),
                  let type_ = obj["type"] as? String,
                  let data = obj["data"] as? [String: Any] else { continue }
            let role: String
            if type_ == "user.message" {
                role = "user"
            } else if type_ == "assistant.message" {
                role = "assistant"
            } else {
                continue
            }
            let content = (data["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            messages.append(ChatMessage(role: role, content: content, systemCategory: .none))
        }
        return messages
    }

    // MARK: - codex
    // {"type":"response_item","payload":{"type":"message","role":...,"content":[{"text":...}]}}
    private static func parseCodexFormat(filePath: String) -> [ChatMessage] {
        guard let reader = StreamingJSONLReader(filePath: filePath) else { return [] }
        defer { reader.close() }
        var messages: [ChatMessage] = []
        for line in reader {
            guard let obj = parseJSON(line),
                  obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String,
                  role == "user" || role == "assistant" else { continue }
            let content = extractTextArray(payload["content"])
            guard !content.isEmpty else { continue }
            let cat = role == "user" ? classifySystem(content: content, source: "codex") : .none
            messages.append(ChatMessage(role: role, content: content, systemCategory: cat))
        }
        return messages
    }

    // MARK: - gemini-cli
    // Whole file: {"messages":[{"type":"user"/"gemini"/"model","content": string | [{"text":"..."}]}]}
    private static func parseGeminiFormat(filePath: String) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { msg in
            guard let type_ = msg["type"] as? String,
                  type_ == "user" || type_ == "gemini" || type_ == "model" else { return nil }
            // content can be a string or an array of {text: "..."}
            let content: String
            if let str = msg["content"] as? String {
                content = str
            } else if let arr = msg["content"] as? [[String: Any]] {
                content = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                return nil
            }
            guard !content.isEmpty else { return nil }
            let role = type_ == "user" ? "user" : "assistant"
            return ChatMessage(role: role, content: content, systemCategory: .none)
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
                return content.isEmpty ? nil : ChatMessage(role: "user", content: content, systemCategory: .none)
            } else if say == "text", !(msg["partial"] as? Bool ?? false) {
                let content = msg["text"] as? String ?? ""
                return content.isEmpty ? nil : ChatMessage(role: "assistant", content: content, systemCategory: .none)
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
            return ChatMessage(role: role, content: content, systemCategory: .none)
        }
    }

    // MARK: - opencode (SQLite: opencode.db::<sessionId>)
    // Tables: message (role) + part (content, type=text)
    private static func parseOpenCodeFormat(filePath: String) -> [ChatMessage] {
        guard let sepRange = filePath.range(of: "::", options: .backwards) else { return [] }
        let dbPath = String(filePath[..<sepRange.lowerBound])
        let sessionId = String(filePath[sepRange.upperBound...])
        guard !sessionId.isEmpty else { return [] }

        var config = Configuration()
        config.readonly = true
        guard let queue = try? DatabaseQueue(path: dbPath, configuration: config) else { return [] }

        return (try? queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.data AS mdata, p.data AS pdata
                FROM message m
                JOIN part p ON p.message_id = m.id
                WHERE m.session_id = ?
                ORDER BY m.time_created ASC, p.time_created ASC
                """, arguments: [sessionId])
            return rows.compactMap { row -> ChatMessage? in
                guard let mdataStr: String = row["mdata"],
                      let pdataStr: String = row["pdata"],
                      let md = mdataStr.data(using: .utf8),
                      let pd = pdataStr.data(using: .utf8),
                      let mobj = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
                      let pobj = try? JSONSerialization.jsonObject(with: pd) as? [String: Any],
                      let role = mobj["role"] as? String,
                      (role == "user" || role == "assistant"),
                      pobj["type"] as? String == "text"
                else { return nil }
                let content = (pobj["text"] as? String) ?? (pobj["value"] as? String) ?? ""
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return ChatMessage(role: role, content: content, systemCategory: .none)
            }
        }) ?? []
    }

    // MARK: - System injection detection

    static func classifySystem(content: String, source: String) -> SystemCategory {
        switch SystemMessageClassifier.classify(content: content, source: source) {
        case .none:
            return .none
        case .systemPrompt:
            return .systemPrompt
        case .agentComm:
            return .agentComm
        }
    }

    // MARK: - Helpers

    private static func parseJSON(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func extractMessageContent(_ content: Any?) -> String {
        if let str = content as? String { return str }
        if let arr = content as? [[String: Any]] {
            // Collect all text blocks; fall back to thinking content
            var texts: [String] = []
            var thinkingFallback: String?
            for item in arr {
                if item["type"] as? String == "text", let text = item["text"] as? String {
                    texts.append(text)
                } else if item["type"] as? String == "thinking",
                          let thinking = item["thinking"] as? String,
                          thinkingFallback == nil {
                    thinkingFallback = thinking
                }
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
            if let fallback = thinkingFallback { return fallback }
        }
        return ""
    }

    /// Qwen format: message.parts = [{text: "..."}]
    private static func extractPartsContent(_ parts: Any?) -> String {
        guard let arr = parts as? [[String: Any]] else { return "" }
        for item in arr {
            if let text = item["text"] as? String, !text.isEmpty { return text }
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
