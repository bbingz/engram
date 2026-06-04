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

        let pageSize = 50
        let messagePage: MCPTranscriptPage
        do {
            messagePage = try await MCPTranscriptReader.readMessagePage(
                filePath: session.filePath,
                source: session.source,
                page: page,
                pageSize: pageSize,
                roles: roles
            )
        } catch let error as TranscriptSizeGuardError {
            throw MCPToolError.transcriptTooLarge(error.localizedDescription)
        }

        return .object([
            ("session", session.orderedJSONValue),
            ("messages", .array(messagePage.messages.map(messageJSON))),
            ("totalPages", .int(messagePage.totalPages)),
            ("currentPage", .int(messagePage.currentPage)),
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

        let sessions: [HandoffSession]
        if let sessionID {
            if let record = try database.sessionRecord(id: sessionID) {
                sessions = [
                    HandoffSession(
                        record: record,
                        costUsd: try database.sessionCost(id: record.id)
                    ),
                ]
            } else {
                sessions = []
            }
        } else {
            sessions = try collectRecentSessions(
                database: database,
                project: resolvedProject,
                limit: 10
            )
        }

        if sessions.isEmpty {
            return emptyHandoff(projectName: projectName, format: format)
        }

        let brief = buildBrief(
            projectName: projectName,
            sessions: sessions,
            format: format
        )

        return .object([
            ("brief", .string(brief)),
            ("sessionCount", .int(sessions.count)),
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
        return try rawSessions.compactMap { raw in
            guard var session = HandoffSession(json: raw) else { return nil }
            session.costUsd = try database.sessionCost(id: session.id)
            return session
        }
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
        format: String
    ) -> String {
        let mostRecent = sessions[0]
        let relativeTime = formatRelativeTime(mostRecent.startTime)
        let lastTask = mostRecent.summary
        var lines: [String] = []
        if format == "markdown" {
            lines.append("## Handoff — \(projectName)")
            lines.append("**Last active**: \(relativeTime) via \(mostRecent.source) (\(mostRecent.model ?? "unknown"))")
            lines.append("**Recent sessions** (\(sessions.count)):")
            for (index, session) in sessions.enumerated() {
                lines.append("\(index + 1). \(formatSessionLine(session))")
            }
            if let lastTask, !lastTask.isEmpty {
                lines.append("")
                lines.append("**Last task**: \(String(lastTask.prefix(200)))")
                lines.append("**Suggested prompt**: \"Continue: \(String(lastTask.prefix(60)))\"")
            }
        } else {
            lines.append("Handoff — \(projectName)")
            lines.append("Last active: \(relativeTime) via \(mostRecent.source) (\(mostRecent.model ?? "unknown"))")
            lines.append("Recent sessions (\(sessions.count)):")
            for (index, session) in sessions.enumerated() {
                lines.append("  \(index + 1). \(formatSessionLine(session))")
            }
            if let lastTask, !lastTask.isEmpty {
                lines.append("Last task: \(String(lastTask.prefix(200)))")
            }
        }
        return lines.joined(separator: "\n")
    }

}

private struct HandoffSession {
    let id: String
    let source: String
    let startTime: String
    let endTime: String?
    let summary: String?
    let model: String?
    let messageCount: Int
    var costUsd: Double?

    init(
        id: String,
        source: String,
        startTime: String,
        endTime: String?,
        summary: String?,
        model: String?,
        messageCount: Int,
        costUsd: Double?
    ) {
        self.id = id
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.summary = summary
        self.model = model
        self.messageCount = messageCount
        self.costUsd = costUsd
    }

    init(record: MCPSessionRecord, costUsd: Double?) {
        self.init(
            id: record.id,
            source: record.source,
            startTime: record.startTime,
            endTime: record.endTime,
            summary: record.summary,
            model: record.model,
            messageCount: record.messageCount,
            costUsd: costUsd
        )
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
        let model: String?
        if case .string(let value)? = lookup["model"], !value.isEmpty {
            model = value
        } else {
            model = nil
        }
        self.init(
            id: id,
            source: source,
            startTime: startTime,
            endTime: endTime.isEmpty ? nil : endTime,
            summary: summary,
            model: model,
            messageCount: messageCount,
            costUsd: nil
        )
    }
}

private func formatSessionLine(_ session: HandoffSession) -> String {
    let summary = session.summary?.isEmpty == false ? session.summary! : "No summary"
    let duration = formatDuration(startTime: session.startTime, endTime: session.endTime)
    let durationPart = duration.map { ", \($0)" } ?? ""
    let costPart = session.costUsd.map {
        String(format: ", $%.2f", locale: Locale(identifier: "en_US_POSIX"), $0)
    } ?? ""
    return "[\(session.source)] \(summary) — \(session.messageCount) msgs\(durationPart)\(costPart)"
}

private func formatDuration(startTime: String, endTime: String?) -> String? {
    guard let endTime,
          let startDate = parseHandoffDate(startTime),
          let endDate = parseHandoffDate(endTime)
    else { return nil }
    let diff = endDate.timeIntervalSince(startDate)
    guard diff > 0 else { return nil }
    let totalMinutes = Int(diff / 60)
    if totalMinutes < 1 { return "< 1m" }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "\(minutes)m" }
    if minutes == 0 { return "\(hours)h" }
    return "\(hours)h \(minutes)m"
}

private func formatRelativeTime(_ time: String) -> String {
    guard let date = parseHandoffDate(time) else { return "unknown" }
    let diff = Date().timeIntervalSince(date)
    if diff < 0 { return "just now" }
    let minutes = Int(diff / 60)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return "\(hours / 24)d ago"
}

private func parseHandoffDate(_ value: String) -> Date? {
    if let date = iso8601WithMilliseconds.date(from: value) {
        return date
    }
    if let date = iso8601WithoutMilliseconds.date(from: value) {
        return date
    }
    return localDateTime.date(from: value)
}

private let iso8601WithMilliseconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let iso8601WithoutMilliseconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private let localDateTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

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
