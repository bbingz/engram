import Foundation

enum TodayResumeCommand {
    static func copyableCommand(from response: EngramServiceResumeCommandResponse) throws -> String {
        try EngramCLIResumeCommand.render(response: response, json: false)
    }
}

struct TodayHandledFollowUps {
    private static let storageKey = "today.handledFollowUpSessionIds.v1"
    private let defaults: UserDefaults
    private(set) var handledIds: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            handledIds = Set(ids)
        } else {
            handledIds = []
        }
    }

    func isHandled(_ sessionId: String) -> Bool {
        handledIds.contains(sessionId)
    }

    mutating func markHandled(_ sessionId: String) {
        handledIds.insert(sessionId)
        let encoded = (try? JSONEncoder().encode(handledIds.sorted())) ?? Data()
        defaults.set(encoded, forKey: Self.storageKey)
    }
}

enum TodayWorkbenchRanking {
    static func continueSessions(
        from sessions: [Session],
        confirmedCounts: [String: Int],
        suggestedCounts: [String: Int],
        limit: Int
    ) -> [Session] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = score(lhs.element, originalIndex: lhs.offset, confirmedCounts: confirmedCounts, suggestedCounts: suggestedCounts)
                let rhsScore = score(rhs.element, originalIndex: rhs.offset, confirmedCounts: confirmedCounts, suggestedCounts: suggestedCounts)
                if lhsScore == rhsScore {
                    return lhs.element.startTime > rhs.element.startTime
                }
                return lhsScore > rhsScore
            }
            .prefix(limit)
            .map(\.element)
    }

    private static func score(
        _ session: Session,
        originalIndex: Int,
        confirmedCounts: [String: Int],
        suggestedCounts: [String: Int]
    ) -> Int {
        var value = max(0, 100 - originalIndex)
        if sourceHasDirectResume(session.source) { value += 250 }
        if !session.cwd.isEmpty { value += 50 }
        value += (confirmedCounts[session.id] ?? 0) * 40
        value += (suggestedCounts[session.id] ?? 0) * 20
        return value
    }

    private static func sourceHasDirectResume(_ source: String) -> Bool {
        switch source {
        case "claude-code", "codex", "gemini-cli", "cursor":
            return true
        default:
            return false
        }
    }
}

enum TodayProjectWarning {
    static func warning(
        for group: DatabaseManager.ProjectGroup,
        repos: [GitRepo],
        migrations: [EngramServiceMigrationLogEntry]
    ) -> String? {
        if migrations.contains(where: { migrationMatches($0, group: group) }) {
            return String(localized: "Migrated")
        }
        guard let repo = repos.first(where: { repoMatches($0, group: group) }) else {
            return nil
        }
        var parts: [String] = []
        let changed = repo.dirtyCount + repo.untrackedCount
        if changed > 0 {
            parts.append(String.localizedStringWithFormat(String(localized: "%lld changed"), changed))
        }
        if repo.unpushedCount > 0 {
            parts.append(String.localizedStringWithFormat(String(localized: "%lld unpushed"), repo.unpushedCount))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func migrationMatches(
        _ migration: EngramServiceMigrationLogEntry,
        group: DatabaseManager.ProjectGroup
    ) -> Bool {
        let project = group.project
        let name = project.split(separator: "/").last.map(String.init) ?? project
        return migration.oldPath == project
            || migration.newPath == project
            || migration.oldBasename == name
            || migration.newBasename == name
    }

    private static func repoMatches(_ repo: GitRepo, group: DatabaseManager.ProjectGroup) -> Bool {
        let project = group.project
        let name = project.split(separator: "/").last.map(String.init) ?? project
        if repo.path == project || repo.name == name {
            return true
        }
        return group.sessions.contains { session in
            session.cwd == repo.path || session.cwd.hasPrefix(repo.path + "/")
        }
    }
}
