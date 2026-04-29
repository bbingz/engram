import Darwin
import Foundation
import GRDB

enum TranscriptExportService {
    static func exportSession(
        _ request: EngramServiceExportSessionRequest,
        databasePath: String
    ) throws -> EngramServiceExportSessionResponse {
        guard request.format == "markdown" || request.format == "json" else {
            throw EngramServiceError.invalidRequest(message: "Unsupported export format: \(request.format)")
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databasePath, configuration: configuration)
        guard let session = try fetchSession(id: request.id, queue: queue) else {
            throw EngramServiceError.invalidRequest(message: "Session not found: \(request.id)")
        }

        let messages = ServiceTranscriptReader.readMessages(filePath: session.filePath, source: session.source)
        let home = try outputHome(from: request.outputHome)
        let outputDir = URL(fileURLWithPath: home).appendingPathComponent("codex-exports")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let safeId = String(session.id.prefix(8))
        let date = serviceLocalDate(session.startTime)
        let ext = request.format == "json" ? "json" : "md"
        let outputURL = outputDir.appendingPathComponent("\(session.source)-\(safeId)-\(date).\(ext)")
        let content = try exportContent(session: session, messages: messages, format: request.format)
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)

        return EngramServiceExportSessionResponse(
            outputPath: outputURL.path,
            format: request.format,
            messageCount: messages.count
        )
    }

    private static func outputHome(from requestedHome: String?) throws -> String {
        let serviceHome = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
            isDirectory: true
        ).standardizedFileURL
        guard let requestedHome, !requestedHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return serviceHome.path
        }
        let trimmed = requestedHome.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = URL(fileURLWithPath: trimmed, isDirectory: true)
        guard trimmed.hasPrefix("/") else {
            throw EngramServiceError.invalidRequest(message: "output_home must be an absolute path")
        }
        guard !trimmed.split(separator: "/").contains("..") else {
            throw EngramServiceError.invalidRequest(message: "output_home must not contain '..'")
        }
        let outputURL = rawURL.standardizedFileURL
        guard outputURL.path == serviceHome.path || outputURL.path.hasPrefix(serviceHome.path + "/") else {
            throw EngramServiceError.invalidRequest(message: "output_home must be within HOME")
        }
        try rejectSymlinkAncestors(from: outputURL, through: serviceHome)
        return outputURL.path
    }

    private static func rejectSymlinkAncestors(from outputURL: URL, through homeURL: URL) throws {
        var current = outputURL
        while current.path.hasPrefix(homeURL.path) {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else {
                    throw EngramServiceError.invalidRequest(message: "output_home must not traverse symlinks")
                }
            } else if errno != ENOENT {
                throw EngramServiceError.invalidRequest(message: "Cannot inspect output_home")
            }
            if current.path == homeURL.path { break }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
    }

    private static func fetchSession(id: String, queue: DatabaseQueue) throws -> ServiceExportSessionRecord? {
        try queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT s.*, ls.local_readable_path
                FROM sessions s
                LEFT JOIN session_local_state ls ON ls.session_id = s.id
                WHERE s.id = ?
                LIMIT 1
                """,
                arguments: [id]
            ) else {
                return nil
            }
            return ServiceExportSessionRecord(row: row)
        }
    }

    private static func exportContent(
        session: ServiceExportSessionRecord,
        messages: [ServiceTranscriptMessage],
        format: String
    ) throws -> String {
        let redactedMessages = messages.map { message in
            ServiceTranscriptMessage(
                role: message.role,
                content: redactSensitiveContent(message.content),
                timestamp: message.timestamp
            )
        }
        if format == "json" {
            let payload: [String: Any] = [
                "session": session.jsonObject,
                "messages": redactedMessages.map(\.jsonObject),
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        }

        var lines: [String] = [
            "# Session: \(session.id)",
            "",
            "**Source:** \(session.source)",
            "**Date:** \(serviceLocalDateTime(session.startTime))",
            "**Project:** \(session.project ?? session.cwd)",
            "**Messages:** \(session.messageCount)",
            "",
            "---",
            "",
        ]
        for message in redactedMessages {
            lines.append("### \(message.role == "user" ? "👤 User" : "🤖 Assistant")")
            lines.append("")
            lines.append(message.content)
            lines.append("")
            lines.append("---")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func redactSensitiveContent(_ content: String) -> String {
        let patterns = [
            #"(?i)\b(api[_-]?key|authorization|bearer|password|secret|credential|token)\b\s*[:=]\s*["']?[A-Za-z0-9_\-+=/.]{10,}["']?"#,
            #"(?i)\bAuthorization:\s*Bearer\s+[A-Za-z0-9_\-+=/.]{10,}"#,
            #"\b(sk-[A-Za-z0-9_\-]{10,}|ghp_[A-Za-z0-9_]{10,}|xox[baprs]-[A-Za-z0-9-]{10,})\b"#,
        ]
        return patterns.reduce(content) { current, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return current }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
    }
}

private struct ServiceExportSessionRecord {
    let id: String
    let source: String
    let startTime: String
    let endTime: String?
    let cwd: String
    let project: String?
    let model: String?
    let messageCount: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let toolMessageCount: Int
    let systemMessageCount: Int
    let summary: String?
    let filePath: String
    let sizeBytes: Int
    let indexedAt: String?
    let agentRole: String?
    let origin: String?
    let summaryMessageCount: Int?
    let tier: String?
    let qualityScore: Int?
    let parentSessionId: String?
    let suggestedParentId: String?

    init(row: Row) {
        self.id = stringValue(row["id"]) ?? ""
        self.source = stringValue(row["source"]) ?? "unknown"
        self.startTime = stringValue(row["start_time"]) ?? ""
        self.endTime = stringValue(row["end_time"])
        self.cwd = stringValue(row["cwd"]) ?? ""
        self.project = stringValue(row["project"])
        self.model = stringValue(row["model"])
        self.messageCount = intValue(row["message_count"])
        self.userMessageCount = intValue(row["user_message_count"])
        self.assistantMessageCount = intValue(row["assistant_message_count"])
        self.toolMessageCount = intValue(row["tool_message_count"])
        self.systemMessageCount = intValue(row["system_message_count"])
        self.summary = stringValue(row["summary"])
        self.filePath = stringValue(row["local_readable_path"]) ?? stringValue(row["file_path"]) ?? ""
        self.sizeBytes = intValue(row["size_bytes"])
        self.indexedAt = stringValue(row["indexed_at"])
        self.agentRole = stringValue(row["agent_role"])
        self.origin = stringValue(row["origin"])
        self.summaryMessageCount = optionalInt(row["summary_message_count"])
        self.tier = stringValue(row["tier"])
        self.qualityScore = optionalInt(row["quality_score"])
        self.parentSessionId = stringValue(row["parent_session_id"])
        self.suggestedParentId = stringValue(row["suggested_parent_id"])
    }

    var jsonObject: [String: Any] {
        [
            "id": id,
            "source": source,
            "startTime": startTime,
            "endTime": jsonValue(endTime),
            "cwd": cwd,
            "project": jsonValue(project),
            "model": jsonValue(model),
            "messageCount": messageCount,
            "userMessageCount": userMessageCount,
            "assistantMessageCount": assistantMessageCount,
            "toolMessageCount": toolMessageCount,
            "systemMessageCount": systemMessageCount,
            "summary": jsonValue(summary),
            "filePath": filePath,
            "sizeBytes": sizeBytes,
            "indexedAt": jsonValue(indexedAt),
            "agentRole": jsonValue(agentRole),
            "origin": jsonValue(origin),
            "summaryMessageCount": jsonValue(summaryMessageCount),
            "tier": jsonValue(tier),
            "qualityScore": jsonValue(qualityScore),
            "parentSessionId": jsonValue(parentSessionId),
            "suggestedParentId": jsonValue(suggestedParentId),
        ]
    }
}

private func jsonValue(_ value: String?) -> Any {
    value ?? NSNull()
}

private func jsonValue(_ value: Int?) -> Any {
    value ?? NSNull()
}

private struct ServiceTranscriptMessage {
    let role: String
    let content: String
    let timestamp: String?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "role": role,
            "content": content,
        ]
        if let timestamp {
            object["timestamp"] = timestamp
        }
        return object
    }
}

private enum ServiceTranscriptReader {
    static func readMessages(filePath: String, source: String) -> [ServiceTranscriptMessage] {
        switch source {
        case "claude-code", "qwen", "iflow", "lobsterai", "minimax":
            return parseTypeMessageFormat(filePath: filePath)
        case "kimi", "antigravity", "windsurf":
            return parseRoleDirectFormat(filePath: filePath)
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
        case "vscode":
            return parseVSCodeFormat(filePath: filePath)
        default:
            return []
        }
    }

    private static func parseTypeMessageFormat(filePath: String) -> [ServiceTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap { object in
            guard
                let type = object["type"] as? String,
                type == "user" || type == "assistant",
                let message = object["message"] as? [String: Any]
            else {
                return nil
            }
            var content = extractMessageContent(message["content"])
            if content.isEmpty {
                content = extractPartsContent(message["parts"])
            }
            guard !content.isEmpty else { return nil }
            return ServiceTranscriptMessage(role: type, content: content, timestamp: object["timestamp"] as? String)
        }
    }

    private static func parseRoleDirectFormat(filePath: String) -> [ServiceTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap { object in
            guard
                let role = object["role"] as? String,
                (role == "user" || role == "assistant"),
                let content = object["content"] as? String,
                !content.isEmpty
            else {
                return nil
            }
            let timestamp = (object["timestamp"] as? String)
                ?? (object["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0).ISO8601Format() }
                ?? (object["timestamp"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format() }
            return ServiceTranscriptMessage(role: role, content: content, timestamp: timestamp)
        }
    }

    private static func parseCodexFormat(filePath: String) -> [ServiceTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap { object in
            guard
                object["type"] as? String == "response_item",
                let payload = object["payload"] as? [String: Any],
                payload["type"] as? String == "message",
                let role = payload["role"] as? String,
                (role == "user" || role == "assistant")
            else {
                return nil
            }
            let content = extractTextArray(payload["content"])
            guard !content.isEmpty else { return nil }
            return ServiceTranscriptMessage(role: role, content: content, timestamp: object["timestamp"] as? String)
        }
    }

    private static func parseCopilotFormat(filePath: String) -> [ServiceTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap { object in
            guard
                let type = object["type"] as? String,
                type == "user.message" || type == "assistant.message",
                let data = object["data"] as? [String: Any],
                let content = data["content"] as? String,
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return ServiceTranscriptMessage(
                role: type == "user.message" ? "user" : "assistant",
                content: content,
                timestamp: object["timestamp"] as? String
            )
        }
    }

    private static func parseGeminiFormat(filePath: String) -> [ServiceTranscriptMessage] {
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
            guard !content.isEmpty else { return nil }

            return ServiceTranscriptMessage(
                role: role,
                content: content,
                timestamp: message["timestamp"] as? String
            )
        }
    }

    private static func parseClineFormat(filePath: String) -> [ServiceTranscriptMessage] {
        guard
            let data = FileManager.default.contents(atPath: filePath),
            let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }

        return messages.compactMap { object in
            guard let say = object["say"] as? String,
                  say == "task" || say == "user_feedback" || (say == "text" && !(object["partial"] as? Bool ?? false))
            else {
                return nil
            }
            let content = object["text"] as? String ?? ""
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let timestamp = (object["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000).ISO8601Format() }
                ?? (object["ts"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000).ISO8601Format() }
            return ServiceTranscriptMessage(
                role: say == "task" || say == "user_feedback" ? "user" : "assistant",
                content: content,
                timestamp: timestamp
            )
        }
    }

    private static func parseCursorFormat(filePath: String) -> [ServiceTranscriptMessage] {
        guard let queryRange = filePath.range(of: "?composer=") else { return [] }
        let dbPath = String(filePath[..<queryRange.lowerBound])
        let composerId = String(filePath[queryRange.upperBound...])
        guard !composerId.isEmpty else { return [] }

        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: dbPath, configuration: configuration) else { return [] }
        return (try? queue.read { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT value FROM cursorDiskKV WHERE key = ?",
                arguments: ["composerData:\(composerId)"]
            ),
               let jsonString: String = row["value"],
               let data = jsonString.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let conversation = object["conversation"] as? [[String: Any]],
               !conversation.isEmpty {
                return parseCursorBubbles(conversation)
            }

            let rows = try Row.fetchAll(
                db,
                sql: "SELECT value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid ASC",
                arguments: ["bubbleId:\(composerId):%"]
            )
            let bubbles: [[String: Any]] = rows.compactMap { row in
                guard let jsonString: String = row["value"],
                      let data = jsonString.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return object
            }
            return parseCursorBubbles(bubbles)
        }) ?? []
    }

    private static func parseCursorBubbles(_ bubbles: [[String: Any]]) -> [ServiceTranscriptMessage] {
        bubbles.compactMap { object in
            guard let type = object["type"] as? Int else { return nil }
            let role: String
            switch type {
            case 1:
                role = "user"
            case 2:
                role = "assistant"
            default:
                return nil
            }
            let content = (object["text"] as? String) ?? (object["rawText"] as? String) ?? ""
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ServiceTranscriptMessage(role: role, content: content, timestamp: nil)
        }
    }

    private static func parseOpenCodeFormat(filePath: String) -> [ServiceTranscriptMessage] {
        guard let separatorRange = filePath.range(of: "::", options: .backwards) else { return [] }
        let dbPath = String(filePath[..<separatorRange.lowerBound])
        let sessionId = String(filePath[separatorRange.upperBound...])
        guard !sessionId.isEmpty else { return [] }

        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: dbPath, configuration: configuration) else { return [] }
        return (try? queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.data AS mdata, p.data AS pdata, m.time_created
                FROM message m
                JOIN part p ON p.message_id = m.id
                WHERE m.session_id = ?
                ORDER BY m.time_created ASC, p.time_created ASC
                """,
                arguments: [sessionId]
            )
            return rows.compactMap { row -> ServiceTranscriptMessage? in
                guard let rawMessage: String = row["mdata"],
                      let rawPart: String = row["pdata"],
                      let messageData = jsonObject(from: rawMessage),
                      let partData = jsonObject(from: rawPart),
                      let role = messageData["role"] as? String,
                      (role == "user" || role == "assistant"),
                      partData["type"] as? String == "text"
                else {
                    return nil
                }
                let content = (partData["text"] as? String) ?? (partData["value"] as? String) ?? ""
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let timestamp = (row["time_created"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000).ISO8601Format() }
                    ?? (row["time_created"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000).ISO8601Format() }
                return ServiceTranscriptMessage(role: role, content: content, timestamp: timestamp)
            }
        }) ?? []
    }

    private static func parseVSCodeFormat(filePath: String) -> [ServiceTranscriptMessage] {
        guard let firstObject = readJSONLines(filePath: filePath).first,
              (firstObject["kind"] as? Int) == 0 || (firstObject["kind"] as? NSNumber)?.intValue == 0,
              let session = firstObject["v"] as? [String: Any],
              let requests = session["requests"] as? [[String: Any]]
        else {
            return []
        }

        var messages: [ServiceTranscriptMessage] = []
        for request in requests {
            let timestamp = (request["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000).ISO8601Format() }
                ?? (request["timestamp"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000).ISO8601Format() }
            let userText = extractVSCodeUserText(request)
            if !userText.isEmpty {
                messages.append(ServiceTranscriptMessage(role: "user", content: userText, timestamp: timestamp))
            }
            let assistantText = extractVSCodeAssistantText(request)
            if !assistantText.isEmpty {
                messages.append(ServiceTranscriptMessage(role: "assistant", content: assistantText, timestamp: timestamp))
            }
        }
        return messages
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

    private static func extractVSCodeUserText(_ request: [String: Any]) -> String {
        guard let message = request["message"] as? [String: Any] else { return "" }
        if let text = message["text"] as? String, !text.isEmpty {
            return text
        }
        guard let parts = message["parts"] as? [[String: Any]] else { return "" }
        for part in parts {
            if part["kind"] as? String == "text",
               let value = part["value"] as? String,
               !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func extractVSCodeAssistantText(_ request: [String: Any]) -> String {
        guard let responses = request["response"] as? [[String: Any]] else { return "" }
        for response in responses {
            let value = response["value"] as? [String: Any]
            let content = value?["content"] as? [String: Any]
            if value?["kind"] as? String == "markdownContent",
               let text = content?["value"] as? String,
               !text.isEmpty {
                return text
            }
        }
        return ""
    }

    private static func jsonObject(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private func serviceLocalDateTime(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallback = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) ?? fallback.date(from: value) else {
        return value
    }

    let output = DateFormatter()
    output.locale = Locale(identifier: "sv_SE")
    if let configured = ProcessInfo.processInfo.environment["TZ"],
       let timeZone = TimeZone(identifier: configured) {
        output.timeZone = timeZone
    } else {
        output.timeZone = .autoupdatingCurrent
    }
    output.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return output.string(from: date)
}

private func serviceLocalDate(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallback = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) ?? fallback.date(from: value) else {
        return value
    }

    let output = DateFormatter()
    output.locale = Locale(identifier: "sv_SE")
    if let configured = ProcessInfo.processInfo.environment["TZ"],
       let timeZone = TimeZone(identifier: configured) {
        output.timeZone = timeZone
    } else {
        output.timeZone = .autoupdatingCurrent
    }
    output.dateFormat = "yyyy-MM-dd"
    return output.string(from: date)
}

private func stringValue(_ value: DatabaseValueConvertible?) -> String? {
    switch value {
    case let value as String:
        return value
    case let value as NSString:
        return value as String
    default:
        return nil
    }
}

private func intValue(_ value: DatabaseValueConvertible?) -> Int {
    switch value {
    case let value as Int:
        return value
    case let value as Int64:
        return Int(value)
    case let value as Double:
        return Int(value)
    default:
        return 0
    }
}

private func optionalInt(_ value: DatabaseValueConvertible?) -> Int? {
    switch value {
    case let value as Int:
        return value
    case let value as Int64:
        return Int(value)
    case let value as Double:
        return Int(value)
    default:
        return nil
    }
}
