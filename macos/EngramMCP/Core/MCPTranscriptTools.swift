import Foundation

enum MCPTranscriptTools {
    static func getSession(
        database: MCPDatabase,
        id: String,
        page: Int,
        roles: [String]?
    ) async throws -> OrderedJSONValue {
        guard let session = try database.sessionRecord(id: id) else {
            throw MCPToolError.invalidArguments("Session not found: \(id)")
        }

        let allMessages = await MCPTranscriptReader.readMessages(filePath: session.filePath, source: session.source)
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

    static func handoff(
        database: MCPDatabase,
        cwd: String,
        sessionID: String?,
        format: String
    ) throws -> OrderedJSONValue {
        let projectName = URL(fileURLWithPath: trimTrailingSlash(cwd)).lastPathComponent
        let projectNames = try database.resolvedProjectAliases(for: projectName)
        let resolvedProject = projectNames.first ?? projectName

        let rawSessions = try collectRecentSessions(
            database: database,
            project: resolvedProject,
            limit: 10
        )

        if rawSessions.isEmpty {
            return emptyHandoff(projectName: projectName, format: format)
        }

        let focusedSession: HandoffSession?
        if let sessionID,
           let record = try database.sessionRecord(id: sessionID) {
            focusedSession = HandoffSession(
                id: record.id,
                source: record.source,
                startTime: record.startTime,
                endTime: record.endTime ?? "",
                summary: record.summary,
                messageCount: record.messageCount
            )
        } else {
            focusedSession = nil
        }

        let brief = buildBrief(
            projectName: projectName,
            sessions: rawSessions,
            focused: focusedSession,
            format: format
        )

        return .object([
            ("brief", .string(brief)),
            ("sessionCount", .int(rawSessions.count)),
        ])
    }

    private static func collectRecentSessions(
        database: MCPDatabase,
        project: String,
        limit: Int
    ) throws -> [HandoffSession] {
        let value = try database.listSessions(
            source: nil,
            project: project,
            since: nil,
            until: nil,
            limit: limit,
            offset: 0
        )
        guard case .object(let entries) = value,
              case .array(let rawSessions)? = entries.first(where: { $0.0 == "sessions" })?.1
        else { return [] }
        return rawSessions.compactMap(HandoffSession.init(json:))
    }

    private static func emptyHandoff(projectName: String, format: String) -> OrderedJSONValue {
        let prefix = format == "markdown" ? "## Handoff — \(projectName)\n\n" : "Handoff — \(projectName)\n\n"
        return .object([
            ("brief", .string("\(prefix)No recent sessions found for this project.")),
            ("sessionCount", .int(0)),
        ])
    }

    private static func buildBrief(
        projectName: String,
        sessions: [HandoffSession],
        focused: HandoffSession?,
        format: String
    ) -> String {
        var lines: [String] = []
        if format == "markdown" {
            lines.append("## Handoff — \(projectName)")
            lines.append("")
            lines.append("Recent sessions: \(sessions.count)")
            if let focused {
                lines.append("")
                lines.append("### Focused session")
                lines.append("- id: `\(focused.id)`")
                lines.append("- source: \(focused.source)")
                if let summary = focused.summary, !summary.isEmpty {
                    lines.append("- summary: \(summary)")
                }
            }
            lines.append("")
            lines.append("### Sessions")
            for session in sessions {
                let summary = session.summary?.isEmpty == false ? " — \(session.summary!)" : ""
                lines.append("- `\(session.id)` (\(session.source), \(session.startTime))\(summary)")
            }
        } else {
            lines.append("Handoff — \(projectName)")
            lines.append("Recent sessions: \(sessions.count)")
            if let focused {
                lines.append("Focused session: \(focused.id) [\(focused.source)]")
                if let summary = focused.summary, !summary.isEmpty {
                    lines.append("Summary: \(summary)")
                }
            }
            for session in sessions {
                let summary = session.summary?.isEmpty == false ? " — \(session.summary!)" : ""
                lines.append("- \(session.id) (\(session.source), \(session.startTime))\(summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

}

private struct HandoffSession {
    let id: String
    let source: String
    let startTime: String
    let endTime: String
    let summary: String?
    let messageCount: Int

    init(
        id: String,
        source: String,
        startTime: String,
        endTime: String,
        summary: String?,
        messageCount: Int
    ) {
        self.id = id
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.summary = summary
        self.messageCount = messageCount
    }

    init?(json: OrderedJSONValue) {
        guard case .object(let entries) = json else { return nil }
        // Use a loop instead of Dictionary(uniqueKeysWithValues:) so that a
        // (defensive) duplicate key doesn't crash the MCP process — same
        // safety lesson as AdapterRegistry's duplicate-source fix.
        var lookup: [String: OrderedJSONValue] = [:]
        for (key, value) in entries where lookup[key] == nil {
            lookup[key] = value
        }
        guard
            case .string(let id)? = lookup["id"],
            case .string(let source)? = lookup["source"],
            case .string(let startTime)? = lookup["startTime"],
            case .string(let endTime)? = lookup["endTime"]
        else { return nil }
        let messageCount: Int
        if case .int(let count)? = lookup["messageCount"] {
            messageCount = count
        } else {
            messageCount = 0
        }
        let summary: String?
        if case .string(let value)? = lookup["summary"], !value.isEmpty {
            summary = value
        } else {
            summary = nil
        }
        self.init(
            id: id,
            source: source,
            startTime: startTime,
            endTime: endTime,
            summary: summary,
            messageCount: messageCount
        )
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
