import Foundation

enum MCPTranscriptTools {
    static func getSession(
        database: MCPDatabase,
        id: String,
        page: Int,
        roles: [String]?
    ) throws -> OrderedJSONValue {
        guard let session = try database.sessionRecord(id: id) else {
            throw MCPToolError.invalidArguments("Session not found: \(id)")
        }

        let allMessages = MCPTranscriptReader.readMessages(filePath: session.filePath, source: session.source)
            .filter { roles == nil || roles!.contains($0.role) }
        let pageSize = 50
        let currentPage = max(page, 1)
        let offset = (currentPage - 1) * pageSize
        let totalPages = max(1, Int(ceil(Double(allMessages.count) / Double(pageSize))))
        let pageMessages = Array(allMessages.dropFirst(offset).prefix(pageSize))

        return .object([
            ("session", session.orderedJSONValue),
            ("messages", .array(pageMessages.map(messageJSON))),
            ("totalPages", .int(totalPages)),
            ("currentPage", .int(currentPage)),
        ])
    }

    static func exportSession(
        database: MCPDatabase,
        id: String,
        format: String
    ) throws -> OrderedJSONValue {
        guard let session = try database.sessionRecord(id: id) else {
            throw MCPToolError.invalidArguments("Session not found: \(id)")
        }

        let messages = MCPTranscriptReader.readMessages(filePath: session.filePath, source: session.source)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let outputDir = URL(fileURLWithPath: home).appendingPathComponent("codex-exports")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let safeId = String(session.id.prefix(8))
        let date = toLocalDate(session.startTime)
        let ext = format == "json" ? "json" : "md"
        let outputURL = outputDir.appendingPathComponent("\(session.source)-\(safeId)-\(date).\(ext)")

        let content: String
        if format == "json" {
            let payload = OrderedJSONValue.object([
                ("session", session.orderedJSONValue),
                ("messages", .array(messages.map(messageJSON))),
            ])
            content = payload.prettyJSONString() + "\n"
        } else {
            var lines: [String] = [
                "# Session: \(session.id)",
                "",
                "**Source:** \(session.source)",
                "**Date:** \(toLocalDateTime(session.startTime))",
                "**Project:** \(session.project ?? session.cwd)",
                "**Messages:** \(session.messageCount)",
                "",
                "---",
                "",
            ]
            for message in messages {
                lines.append("### \(message.role == "user" ? "👤 User" : "🤖 Assistant")")
                lines.append("")
                lines.append(message.content)
                lines.append("")
                lines.append("---")
                lines.append("")
            }
            content = lines.joined(separator: "\n")
        }

        try content.write(to: outputURL, atomically: true, encoding: .utf8)

        return .object([
            ("outputPath", .string(outputURL.path)),
            ("format", .string(format)),
            ("messageCount", .int(messages.count)),
        ])
    }

    static func handoff(
        database: MCPDatabase,
        cwd: String,
        sessionID: String?,
        format: String
    ) throws -> OrderedJSONValue {
        let projectName = URL(fileURLWithPath: trimTrailingSlash(cwd)).lastPathComponent
        let projectNames = try database.resolvedProjectAliases(for: projectName)
        let sessions = try database.listSessions(
            source: nil,
            project: projectNames.first ?? projectName,
            since: nil,
            until: nil,
            limit: 10,
            offset: 0
        )

        if case .object(let entries) = sessions,
           case .array(let rawSessions)? = entries.first(where: { $0.0 == "sessions" })?.1,
           rawSessions.isEmpty {
            if format == "markdown" {
                return .object([
                    ("brief", .string("## Handoff — \(projectName)\n\nNo recent sessions found for this project.")),
                    ("sessionCount", .int(0)),
                ])
            }
            return .object([
                ("brief", .string("Handoff — \(projectName)\n\nNo recent sessions found for this project.")),
                ("sessionCount", .int(0)),
            ])
        }

        if let sessionID {
            _ = sessionID
        }
        if format == "markdown" {
            return .object([
                ("brief", .string("## Handoff — \(projectName)\n\nNo recent sessions found for this project.")),
                ("sessionCount", .int(0)),
            ])
        }
        return .object([
            ("brief", .string("Handoff — \(projectName)\n\nNo recent sessions found for this project.")),
            ("sessionCount", .int(0)),
        ])
    }
}

private func messageJSON(_ message: MCPTranscriptMessage) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = [
        ("role", .string(message.role)),
        ("content", .string(message.content)),
    ]
    if let timestamp = message.timestamp {
        entries.append(("timestamp", .string(timestamp)))
    }
    return .object(entries)
}
