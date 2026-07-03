import Foundation

enum SessionTaxonomyTag: String, CaseIterable, Identifiable {
    case subagent
    case workflow
    case side
    case archived
    case orphan
    case suggestedParent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subagent: "Subagent"
        case .workflow: "Workflow"
        case .side: "Side"
        case .archived: "Archived"
        case .orphan: "Orphan"
        case .suggestedParent: "Suggested parent"
        }
    }

    var filterLabel: String {
        isSupported ? label : "\(label) (unsupported)"
    }

    var systemImage: String {
        switch self {
        case .subagent: "arrow.triangle.branch"
        case .workflow: "point.3.connected.trianglepath.dotted"
        case .side: "sidebar.leading"
        case .archived: "archivebox"
        case .orphan: "link.badge.plus"
        case .suggestedParent: "questionmark.folder"
        }
    }

    var isSupported: Bool {
        switch self {
        case .subagent, .workflow, .side, .archived, .orphan, .suggestedParent:
            true
        }
    }

    func matches(
        _ session: Session,
        confirmedChildCount: Int,
        suggestedChildCount: Int
    ) -> Bool {
        switch self {
        case .subagent:
            SessionTaxonomy.isSubagent(session)
        case .workflow:
            confirmedChildCount > 0
        case .side:
            SessionTaxonomy.isSide(session)
        case .archived:
            SessionTaxonomy.isArchived(session)
        case .orphan:
            SessionTaxonomy.isSubagent(session)
                && session.parentSessionId == nil
                && session.suggestedParentId == nil
        case .suggestedParent:
            suggestedChildCount > 0 || session.hasSuggestedParent
        }
    }
}

enum SessionTaxonomy {
    static func tags(
        for session: Session,
        confirmedChildCount: Int,
        suggestedChildCount: Int
    ) -> [SessionTaxonomyTag] {
        SessionTaxonomyTag.allCases.filter {
            $0.isSupported
                && $0.matches(
                    session,
                    confirmedChildCount: confirmedChildCount,
                    suggestedChildCount: suggestedChildCount
                )
        }
    }

    static func isSubagent(_ session: Session) -> Bool {
        session.agentRole != nil || session.effectiveFilePath.contains("/subagents/")
    }

    static func isArchived(_ session: Session) -> Bool {
        isCodexArchivedPath(session.effectiveFilePath)
    }

    static func isSide(_ session: Session) -> Bool {
        session.source == "codex" && isCodexArchivedPath(session.effectiveFilePath)
    }

    private static func isCodexArchivedPath(_ path: String) -> Bool {
        path.contains("/.codex/archived_sessions/")
            || path.hasPrefix("~/.codex/archived_sessions/")
    }
}

enum SessionTaxonomyFilter: String, CaseIterable, Identifiable {
    case all
    case subagent
    case workflow
    case side
    case archived
    case orphan
    case suggestedParent

    var id: String { rawValue }

    var tag: SessionTaxonomyTag? {
        switch self {
        case .all: nil
        case .subagent: .subagent
        case .workflow: .workflow
        case .side: .side
        case .archived: .archived
        case .orphan: .orphan
        case .suggestedParent: .suggestedParent
        }
    }

    var label: String {
        switch self {
        case .all: "All types"
        case .subagent, .workflow, .side, .archived, .orphan, .suggestedParent:
            tag?.filterLabel ?? "All types"
        }
    }

    var systemImage: String {
        tag?.systemImage ?? "tag"
    }

    var isSupported: Bool {
        tag?.isSupported ?? true
    }

    var includeHidden: Bool {
        tag == .archived || tag == .side
    }

    var topLevelOnly: Bool {
        switch self {
        case .subagent, .side, .orphan, .suggestedParent:
            false
        case .all, .workflow, .archived:
            true
        }
    }

    func matches(
        _ session: Session,
        confirmedChildCount: Int,
        suggestedChildCount: Int
    ) -> Bool {
        guard let tag else { return true }
        return tag.matches(
            session,
            confirmedChildCount: confirmedChildCount,
            suggestedChildCount: suggestedChildCount
        )
    }
}
